package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Registry lit ghcr.io comme scripts/lib/registry.sh : digest d'un tag, port exposé, commit source.
type Registry struct {
	cfg  *Config
	http *http.Client

	mu      sync.Mutex
	tokens  map[string]cacheItem
	inspect map[string]ImageInfo // par digest : immuable
}

type ImageInfo struct {
	Digest   string
	Port     *int
	User     string
	Revision string
	Source   string // dépôt GitHub (Nchpg/RLkart), d'après le label OCI
}

var manifestAccept = []string{
	"application/vnd.oci.image.index.v1+json",
	"application/vnd.docker.distribution.manifest.list.v2+json",
	"application/vnd.oci.image.manifest.v1+json",
	"application/vnd.docker.distribution.manifest.v2+json",
}

func newRegistry(cfg *Config) *Registry {
	return &Registry{cfg: cfg, http: &http.Client{Timeout: 20 * time.Second}, tokens: map[string]cacheItem{}, inspect: map[string]ImageInfo{}}
}

// split : `ghcr.io/nchpg/rlkart-frontend:main` -> ("nchpg/rlkart-frontend", "main").
func splitRef(ref string) (host, repo, tag string, err error) {
	host, rest, ok := strings.Cut(ref, "/")
	if !ok || host != "ghcr.io" {
		return "", "", "", fmt.Errorf("seul ghcr.io est lu ici : %s", ref)
	}
	repo, tag = splitImage(rest)
	if tag == "" {
		return "", "", "", fmt.Errorf("référence sans tag : %s", ref)
	}
	return host, repo, tag, nil
}

func (r *Registry) token(ctx context.Context, repo string) (string, error) {
	r.mu.Lock()
	if it, ok := r.tokens[repo]; ok && time.Since(it.at) < 4*time.Minute {
		r.mu.Unlock()
		return it.val.(string), nil
	}
	r.mu.Unlock()
	u := "https://ghcr.io/token?service=ghcr.io&scope=" + url.QueryEscape("repository:"+repo+":pull")
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	if r.cfg.RegistryToken != "" {
		req.SetBasicAuth(r.cfg.RegistryUser, r.cfg.RegistryToken)
	}
	resp, err := r.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		Token string `json:"token"`
	}
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&out) != nil || out.Token == "" {
		return "", fmt.Errorf("jeton ghcr refusé pour %s (HTTP %d)", repo, resp.StatusCode)
	}
	r.mu.Lock()
	r.tokens[repo] = cacheItem{time.Now(), out.Token}
	r.mu.Unlock()
	return out.Token, nil
}

func (r *Registry) get(ctx context.Context, method, repo, path string, accept []string) (*http.Response, error) {
	tok, err := r.token(ctx, repo)
	if err != nil {
		return nil, err
	}
	req, _ := http.NewRequestWithContext(ctx, method, "https://ghcr.io/v2/"+repo+path, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	for _, a := range accept {
		req.Header.Add("Accept", a)
	}
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != 200 {
		resp.Body.Close()
		return nil, fmt.Errorf("ghcr %s%s : HTTP %d", repo, path, resp.StatusCode)
	}
	return resp, nil
}

// Tags d'une image, donnée sans tag (`ghcr.io/nchpg/rlkart-frontend`).
func (r *Registry) Tags(ctx context.Context, name string) ([]string, error) {
	_, repo, _, err := splitRef(name + ":tag")
	if err != nil {
		return nil, err
	}
	resp, err := r.get(ctx, "GET", repo, "/tags/list?n=1000", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out struct {
		Tags []string `json:"tags"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Tags, nil
}

// Digest d'un tag : ce que podman tire, index multi-architecture compris.
func (r *Registry) Digest(ctx context.Context, ref string) (string, error) {
	_, repo, tag, err := splitRef(ref)
	if err != nil {
		return "", err
	}
	resp, err := r.get(ctx, "HEAD", repo, "/manifests/"+tag, manifestAccept)
	if err != nil {
		return "", err
	}
	resp.Body.Close()
	d := resp.Header.Get("Docker-Content-Digest")
	if !strings.HasPrefix(d, "sha256:") || len(d) != 71 {
		return "", errors.New("digest absent de la réponse du registre")
	}
	return d, nil
}

// Inspect : digest, port exposé, utilisateur et commit source d'un tag.
func (r *Registry) Inspect(ctx context.Context, ref string) (ImageInfo, error) {
	_, repo, _, err := splitRef(ref)
	if err != nil {
		return ImageInfo{}, err
	}
	digest, err := r.Digest(ctx, ref)
	if err != nil {
		return ImageInfo{}, err
	}
	r.mu.Lock()
	if info, ok := r.inspect[repo+"@"+digest]; ok {
		r.mu.Unlock()
		return info, nil
	}
	r.mu.Unlock()

	var manifest struct {
		Manifests []struct {
			Digest   string `json:"digest"`
			Platform struct {
				OS           string `json:"os"`
				Architecture string `json:"architecture"`
			} `json:"platform"`
		} `json:"manifests"`
		Config struct {
			Digest string `json:"digest"`
		} `json:"config"`
	}
	read := func(path string, accept []string, out any) error {
		resp, err := r.get(ctx, "GET", repo, path, accept)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(out)
	}
	if err := read("/manifests/"+digest, manifestAccept, &manifest); err != nil {
		return ImageInfo{}, err
	}
	for _, m := range manifest.Manifests {
		if m.Platform.OS == "linux" && m.Platform.Architecture == "amd64" {
			manifest.Manifests = nil
			if err := read("/manifests/"+m.Digest, manifestAccept, &manifest); err != nil {
				return ImageInfo{}, err
			}
			break
		}
	}
	if manifest.Config.Digest == "" {
		return ImageInfo{}, errors.New("manifeste sans configuration")
	}
	var config struct {
		Config struct {
			User         string              `json:"User"`
			ExposedPorts map[string]struct{} `json:"ExposedPorts"`
			Labels       map[string]string   `json:"Labels"`
		} `json:"config"`
	}
	if err := read("/blobs/"+manifest.Config.Digest, nil, &config); err != nil {
		return ImageInfo{}, err
	}
	info := ImageInfo{Digest: digest, User: config.Config.User, Revision: config.Config.Labels["org.opencontainers.image.revision"]}
	var ports []int
	for p := range config.Config.ExposedPorts {
		if n, ok := strings.CutSuffix(p, "/tcp"); ok {
			if v, err := strconv.Atoi(n); err == nil {
				ports = append(ports, v)
			}
		}
	}
	if len(ports) == 1 {
		info.Port = &ports[0]
	}
	if src := config.Config.Labels["org.opencontainers.image.source"]; strings.HasPrefix(src, "https://github.com/") {
		info.Source = strings.TrimSuffix(strings.TrimPrefix(src, "https://github.com/"), ".git")
	}
	r.mu.Lock()
	r.inspect[repo+"@"+digest] = info
	r.mu.Unlock()
	return info, nil
}

// ShaTags : tags `sha-<commit>` présents pour TOUTES les images données (un retour cohérent).
func (r *Registry) ShaTags(ctx context.Context, refs []string) ([]string, error) {
	var common map[string]bool
	for _, ref := range refs {
		name, _ := splitImage(ref)
		tags, err := r.Tags(ctx, name)
		if err != nil {
			return nil, err
		}
		set := map[string]bool{}
		for _, t := range tags {
			if strings.HasPrefix(t, "sha-") && (common == nil || common[t]) {
				set[t] = true
			}
		}
		common = set
	}
	out := make([]string, 0, len(common))
	for t := range common {
		out = append(out, t)
	}
	sort.Strings(out)
	return out, nil
}
