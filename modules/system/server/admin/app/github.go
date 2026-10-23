package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// GitHub : lecture publique de .dotfiles, et un seul droit d'écriture indirect : lancer apps.yml.
type GitHub struct {
	cfg  *Config
	http *http.Client

	mu    sync.Mutex
	raw   map[string][]byte    // fichier par commit (immuable)
	cache map[string]cacheItem // réponses d'API, durée limitée
	head  cacheItem            // dernière tête de main lue (Head)
}

// headTTL : âge maximal de la tête de main pour afficher une page. Les demandes la relisent
// toujours (Head) avant d'agir, et la boucle `warm` la rafraîchit en continu.
const headTTL = 30 * time.Second

type cacheItem struct {
	at  time.Time
	val any
}

func newGitHub(cfg *Config) *GitHub {
	return &GitHub{cfg: cfg, http: &http.Client{Timeout: 20 * time.Second}, raw: map[string][]byte{}, cache: map[string]cacheItem{}}
}

func (g *GitHub) cached(key string, ttl time.Duration, fetch func() (any, error)) (any, error) {
	g.mu.Lock()
	if it, ok := g.cache[key]; ok && time.Since(it.at) < ttl {
		g.mu.Unlock()
		return it.val, nil
	}
	g.mu.Unlock()
	v, err := fetch()
	if err != nil {
		return nil, err
	}
	g.mu.Lock()
	g.cache[key] = cacheItem{time.Now(), v}
	g.mu.Unlock()
	return v, nil
}

// Head : dernier commit de la branche, par git (sans quota d'API).
func (g *GitHub) Head(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "ls-remote", g.cfg.GitURL, "refs/heads/"+g.cfg.Branch).Output()
	if err != nil {
		return "", fmt.Errorf("git ls-remote : %w", err)
	}
	sha, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\t")
	if len(sha) != 40 {
		return "", errors.New("branche introuvable sur GitHub")
	}
	g.mu.Lock()
	g.head = cacheItem{time.Now(), sha}
	g.mu.Unlock()
	return sha, nil
}

// HeadCached : la tête de main lue il y a moins de headTTL, sinon relue (affichage des pages).
func (g *GitHub) HeadCached(ctx context.Context) (string, error) {
	g.mu.Lock()
	it := g.head
	g.mu.Unlock()
	if sha, ok := it.val.(string); ok && time.Since(it.at) < headTTL {
		return sha, nil
	}
	return g.Head(ctx)
}

// File : contenu d'un fichier à un commit donné (raw, sans quota, jamais périmé).
func (g *GitHub) File(ctx context.Context, sha, path string) ([]byte, error) {
	key := sha + ":" + path
	g.mu.Lock()
	if b, ok := g.raw[key]; ok {
		g.mu.Unlock()
		return b, nil
	}
	g.mu.Unlock()
	if !strings.HasPrefix(g.cfg.GitURL, "https://") {
		// Dépôt local (tests) : le fichier tel qu'il est au commit.
		b, err := exec.CommandContext(ctx, "git", "-C", g.cfg.GitURL, "show", sha+":"+path).Output()
		if err != nil {
			return nil, fmt.Errorf("%s à %s introuvable", path, sha[:7])
		}
		return b, nil
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://raw.githubusercontent.com/"+g.cfg.Repo+"/"+sha+"/"+path, nil)
	resp, err := g.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%s à %s : HTTP %d", path, sha[:7], resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	g.mu.Lock()
	g.raw[key] = b
	g.mu.Unlock()
	return b, nil
}

func (g *GitHub) api(ctx context.Context, method, url, token string, body any, out any) (int, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rd)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := g.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode >= 300 {
		var e struct{ Message string }
		_ = json.Unmarshal(b, &e)
		return resp.StatusCode, fmt.Errorf("GitHub %s : HTTP %d %s", strings.TrimPrefix(url, "https://api.github.com"), resp.StatusCode, e.Message)
	}
	if out != nil && len(b) > 0 {
		return resp.StatusCode, json.Unmarshal(b, out)
	}
	return resp.StatusCode, nil
}

// Dispatch lance apps.yml ; les entrées sont revérifiées là-bas.
func (g *GitHub) Dispatch(ctx context.Context, inputs map[string]string) error {
	if g.cfg.DispatchToken == "" {
		return errors.New("jeton github/dispatch_token absent")
	}
	_, err := g.api(ctx, "POST", "https://api.github.com/repos/"+g.cfg.Repo+"/actions/workflows/apps.yml/dispatches",
		g.cfg.DispatchToken, map[string]any{"ref": g.cfg.Branch, "inputs": inputs}, nil)
	return err
}

type Run struct {
	ID         int64     `json:"id"`
	Status     string    `json:"status"`
	Conclusion string    `json:"conclusion"`
	HTMLURL    string    `json:"html_url"`
	CreatedAt  time.Time `json:"created_at"`
}

// Runs récents d'apps.yml lancés par dispatch.
func (g *GitHub) Runs(ctx context.Context) ([]Run, error) {
	var out struct {
		WorkflowRuns []Run `json:"workflow_runs"`
	}
	_, err := g.api(ctx, "GET", "https://api.github.com/repos/"+g.cfg.Repo+"/actions/workflows/apps.yml/runs?event=workflow_dispatch&per_page=10",
		g.cfg.DispatchToken, nil, &out)
	return out.WorkflowRuns, err
}

type Commit struct {
	SHA     string
	Subject string
	Date    time.Time
	Path    string
}

// Commits récents qui touchent un fichier de main.
func (g *GitHub) Commits(ctx context.Context, path string, n int) ([]Commit, error) {
	v, err := g.cached(fmt.Sprintf("commits:%s:%d", path, n), 2*time.Minute, func() (any, error) {
		var raw []struct {
			SHA    string `json:"sha"`
			Commit struct {
				Message string `json:"message"`
				Author  struct {
					Date time.Time `json:"date"`
				} `json:"author"`
			} `json:"commit"`
		}
		_, err := g.api(ctx, "GET", "https://api.github.com/repos/"+g.cfg.Repo+"/commits?sha="+g.cfg.Branch+"&per_page="+strconv.Itoa(n)+"&path="+path, g.cfg.DispatchToken, nil, &raw)
		if err != nil {
			return nil, err
		}
		out := make([]Commit, 0, len(raw))
		for _, c := range raw {
			subject, _, _ := strings.Cut(c.Commit.Message, "\n")
			out = append(out, Commit{SHA: c.SHA, Subject: subject, Date: c.Commit.Author.Date, Path: path})
		}
		return out, nil
	})
	if err != nil {
		return nil, err
	}
	return v.([]Commit), nil
}

type Package struct {
	Name       string `json:"name"`
	Visibility string `json:"visibility"`
	Repository *struct {
		FullName string `json:"full_name"`
		Private  bool   `json:"private"`
	} `json:"repository"`
}

// Packages : les images de l'utilisateur sur ghcr, chacune avec son dépôt (jeton read:packages).
func (g *GitHub) Packages(ctx context.Context) ([]Package, error) {
	v, err := g.cached("packages", 5*time.Minute, func() (any, error) {
		var out []Package
		_, err := g.api(ctx, "GET", "https://api.github.com/user/packages?package_type=container&per_page=100", g.cfg.RegistryToken, nil, &out)
		return out, err
	})
	if err != nil {
		return nil, err
	}
	return v.([]Package), nil
}
