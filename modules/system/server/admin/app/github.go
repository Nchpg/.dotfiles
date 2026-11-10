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
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// GitHub : lecture publique de .dotfiles, et un seul droit d'écriture indirect : lancer apps.yml.
type GitHub struct {
	cfg  *Config
	http *http.Client

	mu       sync.Mutex
	raw      map[string][]byte        // fichier par commit (immuable)
	rawKeys  []string                 // ordre d'arrivée dans raw : les plus vieux partent au-delà de rawMax
	cache    map[string]cacheItem     // réponses d'API, durée limitée
	ttls     map[string]time.Duration // durée de chaque entrée du cache (ménage)
	failed   map[string]cacheItem     // dernière erreur par clé (val : l'erreur), gardée errTTL
	inflight map[string]chan struct{} // lectures en cours, partagées par ceux qui attendent la même clé
	swept    time.Time                // dernier ménage du cache
	head     cacheItem                // dernière tête de main lue (Head)
}

// headTTL : âge maximal de la tête de main pour afficher une page. Les demandes la relisent
// toujours (Head) avant d'agir, et la boucle `warm` la rafraîchit en continu.
const headTTL = 30 * time.Second

const (
	errTTL = time.Minute // une erreur (quota, panne) est gardée : pas une requête par page tant qu'elle dure
	rawMax = 300         // fichiers gardés par commit (apps.json, lock, pairs… des derniers commits)
)

type cacheItem struct {
	at  time.Time
	val any
}

func newGitHub(cfg *Config) *GitHub {
	return &GitHub{cfg: cfg, http: &http.Client{Timeout: 20 * time.Second}, raw: map[string][]byte{}, cache: map[string]cacheItem{}}
}

// cached : la valeur de `key`, lue par `fetch` une seule fois à la fois (les autres demandes de la
// même clé attendent cette lecture), gardée `ttl`. Une erreur est gardée errTTL (au plus `ttl`) :
// pendant un quota épuisé, ni chaque page ni chaque tour de warm ne relance l'API. Sauf une
// demande abandonnée (contexte annulé) : la suivante relit.
func (g *GitHub) cached(key string, ttl time.Duration, fetch func() (any, error)) (any, error) {
	for {
		g.mu.Lock()
		if it, ok := g.cache[key]; ok && time.Since(it.at) < ttl {
			g.mu.Unlock()
			return it.val, nil
		}
		if it, ok := g.failed[key]; ok && time.Since(it.at) < min(errTTL, ttl) {
			g.mu.Unlock()
			return nil, it.val.(error)
		}
		if ch, ok := g.inflight[key]; ok {
			g.mu.Unlock()
			<-ch
			continue
		}
		if g.inflight == nil {
			g.inflight, g.ttls, g.failed = map[string]chan struct{}{}, map[string]time.Duration{}, map[string]cacheItem{}
		}
		ch := make(chan struct{})
		g.inflight[key] = ch
		g.sweep()
		g.mu.Unlock()
		return g.fill(key, ttl, ch, fetch)
	}
}

// fill : une lecture de cached ; ceux qui l'attendent sont libérés même si fetch panique.
func (g *GitHub) fill(key string, ttl time.Duration, ch chan struct{}, fetch func() (any, error)) (any, error) {
	defer func() {
		g.mu.Lock()
		delete(g.inflight, key)
		close(ch)
		g.mu.Unlock()
	}()
	v, err := fetch()
	g.mu.Lock()
	defer g.mu.Unlock()
	switch {
	case err == nil:
		g.cache[key], g.ttls[key] = cacheItem{time.Now(), v}, ttl
		delete(g.failed, key)
	case !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded):
		g.failed[key] = cacheItem{time.Now(), err}
	}
	if err != nil {
		return nil, err
	}
	return v, nil
}

// sweep : toutes les 10 minutes, les entrées périmées quittent le cache (sous g.mu).
func (g *GitHub) sweep() {
	if time.Since(g.swept) < 10*time.Minute {
		return
	}
	g.swept = time.Now()
	for k, ttl := range g.ttls {
		if time.Since(g.cache[k].at) >= ttl {
			delete(g.cache, k)
			delete(g.ttls, k)
		}
	}
	for k, it := range g.failed {
		if time.Since(it.at) >= errTTL {
			delete(g.failed, k)
		}
	}
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
	if _, ok := g.raw[key]; !ok {
		g.raw[key] = b
		g.rawKeys = append(g.rawKeys, key)
		// Seuls les commits récents resservent : les plus vieux fichiers partent.
		for len(g.rawKeys) > rawMax {
			delete(g.raw, g.rawKeys[0])
			g.rawKeys = g.rawKeys[1:]
		}
	}
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

// Dispatch lance apps.yml ; les entrées sont revérifiées là-bas. `request` (identifiant de la
// demande) nomme le run (run-name d'apps.yml) : waitCommit et follow le retrouvent par là. Un
// apps.yml plus ancien, sans cette entrée, refuse l'appel (422) : il est refait sans, et le run
// se retrouve alors à l'heure (requested : false).
func (g *GitHub) Dispatch(ctx context.Context, inputs map[string]string, request string) (requested bool, err error) {
	if g.cfg.DispatchToken == "" {
		return false, errors.New("jeton github/dispatch_token absent")
	}
	url := "https://api.github.com/repos/" + g.cfg.Repo + "/actions/workflows/apps.yml/dispatches"
	if request != "" {
		with := map[string]string{"request": request}
		for k, v := range inputs {
			with[k] = v
		}
		code, err := g.api(ctx, "POST", url, g.cfg.DispatchToken, map[string]any{"ref": g.cfg.Branch, "inputs": with}, nil)
		if err == nil || code != http.StatusUnprocessableEntity || !strings.Contains(err.Error(), "request") {
			return err == nil, err
		}
	}
	_, err = g.api(ctx, "POST", url, g.cfg.DispatchToken, map[string]any{"ref": g.cfg.Branch, "inputs": inputs}, nil)
	return false, err
}

type Run struct {
	ID           int64     `json:"id"`
	Status       string    `json:"status"`
	Conclusion   string    `json:"conclusion"`
	HTMLURL      string    `json:"html_url"`
	CreatedAt    time.Time `json:"created_at"`
	DisplayTitle string    `json:"display_title"` // run-name d'apps.yml : « edit myetf [<demande>] »
}

var reRunRequest = regexp.MustCompile(`\[([0-9a-f]{8,32})\]\s*$`)

// Request : l'identifiant de la demande qui a lancé le run ("" : run sans identifiant, apps-watch
// ou apps.yml d'avant run-name).
func (r Run) Request() string {
	if m := reRunRequest.FindStringSubmatch(r.DisplayTitle); m != nil {
		return m[1]
	}
	return ""
}

// runFor : le run de la demande `request` parmi `runs` (nil s'il n'a pas encore paru).
func runFor(runs []Run, request string) *Run {
	for i := range runs {
		if request != "" && runs[i].Request() == request {
			return &runs[i]
		}
	}
	return nil
}

// Runs récents d'apps.yml lancés par dispatch.
func (g *GitHub) Runs(ctx context.Context) ([]Run, error) {
	var out struct {
		WorkflowRuns []Run `json:"workflow_runs"`
	}
	_, err := g.api(ctx, "GET", "https://api.github.com/repos/"+g.cfg.Repo+"/actions/workflows/apps.yml/runs?event=workflow_dispatch&per_page=20",
		g.cfg.DispatchToken, nil, &out)
	return out.WorkflowRuns, err
}

// runFailure : le détail d'un run d'apps.yml qui n'a pas abouti. Annulé : une demande plus récente
// l'a remplacé dans la file d'apps.yml (un seul run en attente à la fois), rien n'a été refusé.
func runFailure(r Run) string {
	if r.Conclusion == "cancelled" {
		return "annulée par une demande plus récente dans la file d'apps.yml : relance-la."
	}
	return "apps.yml a refusé la demande (" + r.Conclusion + ") : le détail est dans le run."
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

// CompareCount : les commits de `base` à `head` d'un dépôt GitHub (public). Le résultat ne change
// jamais pour deux révisions données : gardé en cache longtemps.
func (g *GitHub) CompareCount(ctx context.Context, owner, repo, base, head string) (int, error) {
	v, err := g.cached("compare:"+owner+"/"+repo+":"+base+"..."+head, 30*24*time.Hour, func() (any, error) {
		var out struct {
			AheadBy int `json:"ahead_by"`
		}
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/compare/%s...%s?per_page=1", owner, repo, base, head)
		// Le jeton du dashboard d'abord (plus de requêtes permises) ; sans lui, en anonyme.
		_, err := g.api(ctx, "GET", url, g.cfg.DispatchToken, nil, &out)
		if err != nil && g.cfg.DispatchToken != "" {
			_, err = g.api(ctx, "GET", url, "", nil, &out)
		}
		return out.AheadBy, err
	})
	if err != nil {
		return 0, err
	}
	return v.(int), nil
}

// compareMaxPages : au plus 5000 commits lus (par pages de 100) ; nixpkgs-unstable en fait quelques
// milliers par semaine.
const compareMaxPages = 50

// CompareTitles : le titre de chaque commit de base à head, du plus ancien au plus récent (celui de
// la PR pour un merge de PR ; les merges de branches, sans contenu propre, sautent). Gardés un jour :
// une fois l'analyse enregistrée (ai.json), ils ne servent plus, et chaque mise à jour de nixpkgs
// en apporte de nouveaux (quelques milliers de titres).
func (g *GitHub) CompareTitles(ctx context.Context, owner, repo, base, head string) ([]string, error) {
	v, err := g.cached("titles:"+owner+"/"+repo+":"+base+"..."+head, 24*time.Hour, func() (any, error) {
		var titles []string
		// Comme CompareCount : le jeton d'abord ; refusé, en anonyme pour la suite.
		token := g.cfg.DispatchToken
		for page := 1; page <= compareMaxPages; page++ {
			var out struct {
				Commits []struct {
					Commit struct {
						Message string `json:"message"`
					} `json:"commit"`
				} `json:"commits"`
			}
			url := fmt.Sprintf("https://api.github.com/repos/%s/%s/compare/%s...%s?per_page=100&page=%d", owner, repo, base, head, page)
			_, err := g.api(ctx, "GET", url, token, nil, &out)
			if err != nil && token != "" {
				token = ""
				_, err = g.api(ctx, "GET", url, "", nil, &out)
			}
			if err != nil {
				return nil, err
			}
			for _, c := range out.Commits {
				if t := commitTitle(c.Commit.Message); t != "" {
					titles = append(titles, t)
				}
			}
			if len(out.Commits) < 100 {
				break
			}
		}
		return titles, nil
	})
	if err != nil {
		return nil, err
	}
	return v.([]string), nil
}

// commitTitle : la première ligne d'un message ; pour « Merge pull request #… », le titre de la PR
// (sa ligne suivante) ; rien pour un autre merge.
func commitTitle(msg string) string {
	lines := strings.Split(strings.TrimSpace(msg), "\n")
	first := strings.TrimSpace(lines[0])
	if !strings.HasPrefix(first, "Merge ") {
		return first
	}
	if strings.HasPrefix(first, "Merge pull request ") {
		for _, l := range lines[1:] {
			if l = strings.TrimSpace(l); l != "" {
				return l
			}
		}
	}
	return ""
}
