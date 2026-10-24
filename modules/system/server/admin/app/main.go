package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	appsPath = "profiles/server/apps.json"
	lockPath = "profiles/server/apps.lock.json"
)

//go:embed templates/*.html static/*
var assets embed.FS

type Server struct {
	cfg  *Config
	gh   *GitHub
	reg  *Registry
	eval *Evaluator
	jobs *Jobs
	tmpl *template.Template

	applyMu sync.Mutex // sérialise « aucune demande en cours » puis « lancer »
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	tmpl, err := template.New("").Funcs(funcs).ParseFS(assets, "templates/*.html")
	if err != nil {
		log.Fatal(err)
	}
	s := &Server{
		cfg: cfg, gh: newGitHub(cfg), reg: newRegistry(cfg), eval: &Evaluator{cfg: cfg},
		jobs: &Jobs{m: map[string]*Job{}}, tmpl: tmpl,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/sites", http.StatusFound) })
	mux.HandleFunc("GET /sites", s.sites)
	mux.HandleFunc("GET /sites/new", s.newSite)
	mux.HandleFunc("GET /sites/new/form", s.newSiteForm)
	mux.HandleFunc("POST /sites/new/preview", s.preview)
	mux.HandleFunc("POST /sites/new/apply", s.apply)
	mux.HandleFunc("POST /sites/new/form", s.reform)
	mux.HandleFunc("GET /sites/{app}", s.editor)
	mux.HandleFunc("POST /sites/{app}/preview", s.preview)
	mux.HandleFunc("POST /sites/{app}/apply", s.apply)
	mux.HandleFunc("POST /sites/{app}/delete", s.remove)
	mux.HandleFunc("POST /sites/{app}/form", s.reform)
	mux.HandleFunc("POST /sites/{app}/env/{env}/delete", s.removeEnv)
	mux.HandleFunc("POST /sites/{app}/env/{env}/recopy", s.recopy)
	mux.HandleFunc("GET /sites/{app}/env/{env}/recopy", s.recopyStatus)
	mux.HandleFunc("GET /jobs/{id}", s.job)
	mux.HandleFunc("GET /fragments/{name}", s.fragment)
	mux.HandleFunc("GET /static/{file}", s.static)
	mux.HandleFunc("GET /fonts/{file}", s.font)
	mux.HandleFunc("GET /vpn", s.vpn)
	mux.HandleFunc("GET /vpn/new", s.vpnNew)
	mux.HandleFunc("POST /vpn/new", s.vpnCreate)
	mux.HandleFunc("POST /vpn/{name}/remove", s.vpnRemove)
	mux.HandleFunc("GET /vpn/{name}/access", s.vpnAccess)
	mux.HandleFunc("POST /vpn/{name}/access", s.vpnAccessSave)
	mux.HandleFunc("GET /ssh", s.ssh)
	mux.HandleFunc("GET /accounts", s.accounts)
	if cfg.MetricsURL != "" {
		mux.HandleFunc("GET /metrics", s.metrics)
	} else {
		mux.HandleFunc("GET /metrics", s.soon("metrics"))
	}
	metricsReady = cfg.MetricsURL != ""

	if s.reg != nil {
		go s.warm(context.Background())
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           s.guard(mux),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      60 * time.Second,
	}
	log.Printf("admin sur %s (%s)", cfg.Listen, cfg.Host)
	log.Fatal(srv.ListenAndServe())
}

// guard : un POST ne vient que de la page elle-même (CSRF), et reste petit.
func (s *Server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("X-Frame-Options", "DENY")
		if r.Method == http.MethodPost {
			origin := r.Header.Get("Origin")
			if origin == "" {
				origin = r.Header.Get("Referer")
			}
			u, err := url.Parse(origin)
			if err != nil || u.Host != s.cfg.Host {
				http.Error(w, "origine refusée", http.StatusForbidden)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := s.tmpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("template %s : %v", name, err)
	}
}

func (s *Server) fail(w http.ResponseWriter, err error) {
	log.Print(err)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusBadGateway)
	s.render(w, "error", map[string]any{"Nav": "sites", "Error": err.Error()})
}

func (s *Server) static(w http.ResponseWriter, r *http.Request) {
	file := r.PathValue("file")
	if file == "htmx.min.js" && s.cfg.Htmx != "" {
		w.Header().Set("Cache-Control", "public, max-age=86400")
		http.ServeFile(w, r, s.cfg.Htmx)
		return
	}
	b, err := fs.ReadFile(assets, "static/"+file)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch filepath.Ext(file) {
	case ".css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	case ".js":
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	}
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(b)
}

func (s *Server) font(w http.ResponseWriter, r *http.Request) {
	file := filepath.Base(r.PathValue("file"))
	if s.cfg.Fonts == "" || !strings.HasSuffix(file, ".ttf") {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=604800")
	http.ServeFile(w, r, filepath.Join(s.cfg.Fonts, file))
}

// metricsReady : la page Métriques montre Grafana (le menu n'affiche plus « bientôt »).
var metricsReady bool

// metrics : le tableau de bord Grafana en kiosque, sur toute la page, en thème clair comme le reste.
func (s *Server) metrics(w http.ResponseWriter, r *http.Request) {
	s.render(w, "metrics", map[string]any{"Nav": "metrics", "URL": s.cfg.MetricsURL, "Embed": s.cfg.MetricsURL + "&kiosk&theme=light"})
}

func (s *Server) soon(page string) http.HandlerFunc {
	titles := map[string][2]string{
		"metrics": {"Métriques", "Le tableau de bord Grafana, intégré ici."},
	}
	return func(w http.ResponseWriter, r *http.Request) {
		t := titles[page]
		s.render(w, "soon", map[string]any{"Nav": page, "Title": t[0], "Text": t[1]})
	}
}

// Snapshot : apps.json et lock à la tête de main.
type Snapshot struct {
	Head    string
	Apps    *AppsFile
	LockRaw []byte
	Lock    map[string]lockEntry
}

func (s *Server) snapshot(ctx context.Context) (*Snapshot, error) {
	head, err := s.gh.HeadCached(ctx)
	if err != nil {
		return nil, err
	}
	appsRaw, err1 := s.gh.File(ctx, head, appsPath)
	lockRaw, err2 := s.gh.File(ctx, head, lockPath)
	if err := errors.Join(err1, err2); err != nil {
		return nil, err
	}
	apps, err := parseApps(appsRaw)
	if err != nil {
		return nil, err
	}
	lock := map[string]lockEntry{}
	if err := json.Unmarshal(lockRaw, &lock); err != nil {
		return nil, err
	}
	return &Snapshot{Head: head, Apps: apps, LockRaw: lockRaw, Lock: lock}, nil
}

func itoa(n int) string { return strconv.Itoa(n) }

// warm : garde chauds, en fond, ce que les pages lisent sur le réseau (tête de main, tags des
// images, packages, dépôts des sites, changements) : un clic n'attend plus GitHub ni ghcr.
func (s *Server) warm(ctx context.Context) {
	for {
		if _, err := s.gh.Head(ctx); err == nil {
			if snap, err := s.snapshot(ctx); err == nil {
				seen := map[string]bool{}
				for _, name := range snap.Apps.Names() {
					_ = s.sourceRepo(ctx, snap.Apps.Entries[name])
					for _, d := range snap.Apps.Entries[name].Deploys(name) {
						for _, c := range d.Ctrs.Containers {
							if ref := s.cfg.ref(untag(c.Image)); !seen[ref] {
								seen[ref] = true
								_, _ = s.reg.FetchTags(ctx, ref)
							}
						}
					}
				}
			}
		}
		_, _ = s.gh.Packages(ctx)
		s.activity(ctx, activityStep)
		select {
		case <-ctx.Done():
			return
		case <-time.After(20 * time.Second):
		}
	}
}
