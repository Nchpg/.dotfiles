package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"runtime/debug"
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
	slow    slowCache  // données lentes des pages (Loki, journal de sshd)
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
		jobs: &Jobs{m: map[string]*Job{}, path: filepath.Join(cfg.StateDir, "jobs.json")}, tmpl: tmpl,
	}
	s.resumeJobs()

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
	mux.HandleFunc("GET /manifest.webmanifest", s.manifest)
	mux.HandleFunc("GET /fonts/{file}", s.font)
	mux.HandleFunc("GET /vpn", s.vpn)
	mux.HandleFunc("GET /vpn/new", s.vpnNew)
	mux.HandleFunc("POST /vpn/new", s.vpnCreate)
	mux.HandleFunc("POST /vpn/{name}/remove", s.vpnRemove)
	mux.HandleFunc("GET /vpn/{name}/access", s.vpnAccess)
	mux.HandleFunc("POST /vpn/{name}/access", s.vpnAccessSave)
	mux.HandleFunc("GET /ssh", s.ssh)
	mux.HandleFunc("GET /ssh/connexions", s.sshLoginsMore)
	mux.HandleFunc("GET /ssh/new", s.sshNew)
	mux.HandleFunc("POST /ssh/new", s.sshAdd)
	mux.HandleFunc("POST /ssh/remove", s.sshRemove)
	mux.HandleFunc("GET /track/{id}", s.trackFragment)
	mux.HandleFunc("GET /traffic", s.traffic)
	mux.HandleFunc("GET /traffic/{domain}", s.trafficSite)
	mux.HandleFunc("GET /traffic/connexions/{service}", s.trafficLogins)
	mux.HandleFunc("GET /updates", s.updates)
	mux.HandleFunc("POST /updates/check", s.updatesCheck)
	mux.HandleFunc("GET /accounts", s.accounts)
	mux.HandleFunc("GET /accounts/new", s.accountNew)
	mux.HandleFunc("POST /accounts/new", s.accountNew)
	mux.HandleFunc("GET /accounts/{name}/access", s.accountAccess)
	mux.HandleFunc("POST /accounts/{name}/access", s.accountAccessSave)
	mux.HandleFunc("POST /accounts/{name}/remove", s.accountRemove)
	if cfg.MetricsURL != "" {
		mux.HandleFunc("GET /metrics", s.metrics)
	} else {
		mux.HandleFunc("GET /metrics", s.soon("metrics"))
	}
	metricsReady = cfg.MetricsURL != ""
	machineName = cfg.Machine
	repoName = cfg.Repo
	if b, err := os.ReadFile(cfg.Htmx); err == nil {
		assetVer["htmx.min.js"] = shortHash(b)
	}

	if s.reg != nil {
		safeGo("warm", func() { s.warm(context.Background()) })
	}
	// Ce que `update` changerait : chaque jour, avec un récapitulatif sur Discord.
	safeGo("updatesLoop", func() { s.updatesLoop(context.Background()) })

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           s.guard(mux),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      60 * time.Second,
	}
	log.Printf("admin sur %s (%s)", cfg.Listen, cfg.Host)
	log.Fatal(srv.ListenAndServe())
}

// guard : un POST ne vient que de la page elle-même (CSRF), et reste petit. Une panique dans un
// handler est rattrapée : journalisée avec sa pile, et montrée comme une erreur (pas une page coupée).
func (s *Server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		w := &watchWriter{ResponseWriter: rw}
		defer func() {
			p := recover()
			if p == nil {
				return
			}
			if p == http.ErrAbortHandler {
				panic(p)
			}
			log.Printf("%s %s : panique : %v\n%s", r.Method, r.URL.Path, p, debug.Stack())
			if !w.wrote {
				s.httpError(w, r, http.StatusInternalServerError, "", "Erreur interne : la demande a échoué (détail dans le journal du dashboard).")
			}
		}()
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
				s.httpError(w, r, http.StatusForbidden, "", "Origine refusée : la demande ne vient pas du dashboard. Recharge la page puis réessaie.")
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		}
		next.ServeHTTP(w, r)
	})
}

// watchWriter : sait si la réponse a commencé (après une panique, on ne peut plus rien envoyer).
type watchWriter struct {
	http.ResponseWriter
	wrote bool
}

func (w *watchWriter) WriteHeader(code int) { w.wrote = true; w.ResponseWriter.WriteHeader(code) }
func (w *watchWriter) Write(b []byte) (int, error) {
	w.wrote = true
	return w.ResponseWriter.Write(b)
}
func (w *watchWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// safeGo : une goroutine de fond qui ne fait pas tomber le serveur en paniquant (journalisée avec sa
// pile). Pour une boucle, rattraper plutôt chaque tour (defer recoverLog) : elle continue ensuite.
func safeGo(name string, fn func()) {
	go func() {
		defer recoverLog(name)
		fn()
	}()
}

// recoverLog : à différer en tête d'une fonction de fond ; journalise une panique au lieu de planter.
func recoverLog(name string) {
	if p := recover(); p != nil {
		log.Printf("%s : panique : %v\n%s", name, p, debug.Stack())
	}
}

// Rendu : le template entier dans un tampon, puis envoyé d'un bloc. Une erreur à mi-chemin ne laisse
// plus partir une page coupée en 200 : la page d'erreur la remplace (500), dans le menu.
var bufPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	s.renderStatus(w, http.StatusOK, name, data)
}

// renderStatus : comme render, avec un autre code (en-têtes posés avant le code, sinon perdus).
func (s *Server) renderStatus(w http.ResponseWriter, code int, name string, data any) {
	buf := bufPool.Get().(*bytes.Buffer)
	buf.Reset()
	defer func() {
		if buf.Cap() <= 1<<20 {
			bufPool.Put(buf)
		}
	}()
	if err := s.tmpl.ExecuteTemplate(buf, name, data); err != nil {
		log.Printf("template %s : %v", name, err)
		buf.Reset()
		code = http.StatusInternalServerError
		msg := "La page n'a pas pu être affichée : " + err.Error()
		page := "error"
		if strings.HasPrefix(name, "error") {
			page = "" // la page d'erreur elle-même : du texte seul
		}
		if page == "" || s.tmpl.ExecuteTemplate(buf, page, map[string]any{"Nav": dataField(data, "Nav"), "PageTitle": "Erreur", "Error": msg, "Code": code}) != nil {
			http.Error(w, msg, code)
			return
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(buf.Len()))
	w.WriteHeader(code)
	_, _ = w.Write(buf.Bytes())
}

// isHtmx : une requête faite par htmx (fragment, navigation hx-boost, HX-Location).
func isHtmx(r *http.Request) bool { return r != nil && r.Header.Get("HX-Request") == "true" }

// isFragment : une requête htmx qui attend un morceau de page, pas une page entière (ni navigation
// hx-boost, ni restauration de l'historique).
func isFragment(r *http.Request) bool {
	return isHtmx(r) && r.Header.Get("HX-Boosted") != "true" && r.Header.Get("HX-History-Restore-Request") != "true"
}

// httpError : une erreur montrée là où on la cherche. Page ou navigation (hx-boost) : la page d'erreur,
// dans le menu (`nav` : l'entrée active, "" pour aucune) ; fragment htmx : un message court, qu'app.js
// affiche en bandeau sans rien remplacer dans la page. `msg` : une phrase en français, pour l'utilisateur.
func (s *Server) httpError(w http.ResponseWriter, r *http.Request, code int, nav, msg string) {
	if isFragment(r) {
		s.renderStatus(w, code, "error-fragment", map[string]any{"Error": msg, "Code": code})
		return
	}
	s.renderStatus(w, code, "error", map[string]any{"Nav": nav, "PageTitle": "Erreur", "Error": msg, "Code": code})
}

// notFound : la ressource n'existe pas (ou plus) ; msg vide : un message générique.
func (s *Server) notFound(w http.ResponseWriter, r *http.Request, nav, msg string) {
	if msg == "" {
		msg = "Cette page n'existe pas (ou plus)."
	}
	s.httpError(w, r, http.StatusNotFound, nav, msg)
}

// badRequest : une demande invalide (paramètre, formulaire), avec ce qui ne va pas.
func (s *Server) badRequest(w http.ResponseWriter, r *http.Request, nav, msg string) {
	s.httpError(w, r, http.StatusBadRequest, nav, msg)
}

// failAt : une source (GitHub, Loki…) n'a pas répondu ; journalisé, et montré en 502.
func (s *Server) failAt(w http.ResponseWriter, r *http.Request, nav string, err error) {
	log.Print(err)
	s.httpError(w, r, http.StatusBadGateway, nav, err.Error())
}

// fail : failAt sans la requête (page entière, menu sur Sites). Préférer failAt.
func (s *Server) fail(w http.ResponseWriter, err error) { s.failAt(w, nil, "sites", err) }

// redirect : après une action. Requête htmx (hx-post) : HX-Location, la page suivante arrive comme une
// navigation du menu (contenu seul, adresse dans l'historique) ; sinon un 303 classique.
func (s *Server) redirect(w http.ResponseWriter, r *http.Request, to string) {
	if isFragment(r) {
		loc, _ := json.Marshal(map[string]string{"path": to, "target": ".content", "select": ".content", "swap": "outerHTML"})
		w.Header().Set("HX-Location", string(loc))
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, to, http.StatusSeeOther)
}

// dataField : le champ `name` des données d'une page (map ou struct), "" sinon.
func dataField(data any, name string) string {
	switch d := data.(type) {
	case map[string]any:
		s, _ := d[name].(string)
		return s
	case nil:
		return ""
	}
	v := reflect.ValueOf(data)
	for v.Kind() == reflect.Pointer {
		if v.IsNil() {
			return ""
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return ""
	}
	if f := v.FieldByName(name); f.IsValid() && f.Kind() == reflect.String {
		return f.String()
	}
	return ""
}

// Titre de l'onglet par entrée du menu, quand la page ne donne pas le sien (PageTitle).
var navTitles = map[string]string{
	"sites": "Sites", "vpn": "VPN", "ssh": "SSH", "accounts": "Authelia", "traffic": "Trafic",
	"updates": "Mises à jour", "metrics": "Métriques",
}

// Fichiers statiques : contenu, type, et empreinte (ETag, et ?v= des adresses versionnées).
type staticFile struct {
	data  []byte
	ctype string
	etag  string
}

var (
	staticFiles = map[string]staticFile{}
	assetVer    = map[string]string{} // fichier → empreinte courte
)

func shortHash(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:6])
}

func init() {
	// Les fonctions communes rejoignent funcs (les tests analysent les templates avec funcs seul).
	for k, v := range uiFuncs {
		funcs[k] = v
	}
	types := map[string]string{
		".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8",
		".png": "image/png", ".svg": "image/svg+xml",
	}
	entries, _ := fs.ReadDir(assets, "static")
	for _, e := range entries {
		b, err := fs.ReadFile(assets, "static/"+e.Name())
		if err != nil {
			continue
		}
		v := shortHash(b)
		staticFiles[e.Name()] = staticFile{data: b, ctype: types[filepath.Ext(e.Name())], etag: `"` + v + `"`}
		assetVer[e.Name()] = v
	}
}

// uiFuncs : fonctions des templates pour la mise en page commune (ajoutées à funcs par init).
var uiFuncs = template.FuncMap{
	// asset : l'adresse versionnée d'un fichier statique (`{{asset "style.css"}}`), gardée en cache
	// tant que le fichier ne change pas.
	"asset": func(file string) string {
		if v := assetVer[file]; v != "" {
			return "/static/" + file + "?v=" + v
		}
		return "/static/" + file
	},
	// pageTitle : le titre de l'onglet (PageTitle des données, sinon l'entrée du menu).
	"pageTitle": func(data any) string {
		if t := dataField(data, "PageTitle"); t != "" {
			return t
		}
		return navTitles[dataField(data, "Nav")]
	},
	// errorLabel : le sous-titre de la page d'erreur, d'après le code HTTP.
	"errorLabel": func(code any) string {
		c, _ := code.(int)
		switch c {
		case 0:
			return ""
		case http.StatusBadRequest:
			return "Demande invalide (400)"
		case http.StatusForbidden:
			return "Refusé (403)"
		case http.StatusNotFound:
			return "Introuvable (404)"
		case http.StatusConflict:
			return "Déjà en cours (409)"
		case http.StatusBadGateway:
			return "Source injoignable (502)"
		case http.StatusInternalServerError:
			return "Erreur interne (500)"
		}
		return "Code " + itoa(c)
	},
	// repo : le dépôt de la configuration (owner/nom), pour les liens GitHub.
	"repo": func() string { return repoName },
	// repoOwner : le propriétaire du dépôt (celui du template d'application, owner/app-template).
	"repoOwner": func() string { o, _, _ := strings.Cut(repoName, "/"); return o },
	// icon : une icône commune (`{{icon "plus"}}`), même trait que les autres.
	"icon": func(name string) template.HTML {
		d, ok := icons[name]
		if !ok {
			return ""
		}
		cls := ""
		if name == "github" {
			cls = ` class="fill"`
		}
		return template.HTML(`<svg viewBox="0 0 24 24" aria-hidden="true"` + cls + `><path d="` + d + `"/></svg>`)
	},
}

// repoName : le dépôt de la configuration (cfg.Repo).
var repoName = ""

// icons : les tracés répétés dans les templates (24×24, trait).
var icons = map[string]string{
	"chevron":      "M9 6l6 6-6 6",
	"chevron-down": "M6 9l6 6 6-6",
	"back":         "M19 12H5M11 6l-6 6 6 6",
	"plus":         "M12 5v14M5 12h14",
	"minus":        "M5 12h14",
	"check":        "M5 12l5 5L20 7",
	"x":            "M6 6l12 12M18 6L6 18",
	"external":     "M14 4h6v6M20 4l-9 9M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5",
	"globe":        "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18",
	"lock":         "M6 11h12a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1zM8 11V7a4 4 0 0 1 8 0v4",
	"user":         "M9 12a4 4 0 1 0 0-8a4 4 0 1 0 0 8M2 21c1-4 3.5-6 7-6s6 2 7 6M16 11l2 2 4-4",
	"shield":       "M12 3l8 3v6c0 5-3.5 8-8 9c-4.5-1-8-4-8-9V6zM9 12l2 2 4-4",
	"key":          "M4 15a4 4 0 1 0 8 0a4 4 0 1 0-8 0M10.8 12.2L20 3M16 7l3 3M14 9l2 2",
	"branch":       "M6 3v12M18 9a3 3 0 1 0 0-6a3 3 0 1 0 0 6M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6M18 9a9 9 0 0 1-9 9",
	"package":      "M21 8l-9-5-9 5 9 5zM3 8v8l9 5 9-5V8M12 13v8",
	"refresh":      "M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8M21 3v5h-5",
	"clock":        "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2",
	"alert":        "M12 3l9.5 17h-19zM12 10v4M12 17h.01",
	"github":       githubPath,
}

const githubPath = "M12 .5C5.7.5.5 5.7.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.3.8-.6v-2c-3.2.7-3.9-1.4-3.9-1.4-.5-1.3-1.3-1.7-1.3-1.7-1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.7-1.5-2.6-.3-5.2-1.3-5.2-5.7 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3 0 0 1-.3 3.2 1.2a11 11 0 0 1 5.8 0c2.2-1.5 3.2-1.2 3.2-1.2.6 1.6.2 2.8.1 3 .7.8 1.2 1.8 1.2 3.1 0 4.4-2.7 5.4-5.3 5.7.4.4.8 1.1.8 2.1v3.2c0 .3.2.7.8.6A11.5 11.5 0 0 0 23.5 12C23.5 5.7 18.3.5 12 .5z"

// static : fichiers embarqués avec ETag (une revalidation coûte un 304). Adresse versionnée (?v= de
// `asset`) : en cache pour de bon, la version suivante a une autre adresse.
func (s *Server) static(w http.ResponseWriter, r *http.Request) {
	file := r.PathValue("file")
	versioned := r.URL.Query().Get("v") != "" && r.URL.Query().Get("v") == assetVer[file]
	if file == "htmx.min.js" && s.cfg.Htmx != "" {
		if versioned {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			w.Header().Set("Cache-Control", "public, max-age=86400")
		}
		http.ServeFile(w, r, s.cfg.Htmx)
		return
	}
	f, ok := staticFiles[file]
	if !ok {
		http.NotFound(w, r)
		return
	}
	if f.ctype != "" {
		w.Header().Set("Content-Type", f.ctype)
	}
	w.Header().Set("ETag", f.etag)
	switch {
	case versioned:
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	case filepath.Ext(file) == ".svg":
		// La carte du Trafic : lourde, et ne change qu'avec une nouvelle version.
		w.Header().Set("Cache-Control", "public, max-age=86400")
	default:
		w.Header().Set("Cache-Control", "no-cache")
	}
	http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(f.data))
}

// manifest : de quoi installer le dashboard comme une application (téléphone, ordinateur). Pas de
// service worker : rien n'est mis en cache, chaque page montre l'état de think tel qu'il est.
func (s *Server) manifest(w http.ResponseWriter, r *http.Request) {
	icon := func(src, size, purpose string) map[string]string {
		return map[string]string{"src": src, "sizes": size, "type": "image/png", "purpose": purpose}
	}
	w.Header().Set("Content-Type", "application/manifest+json")
	w.Header().Set("Cache-Control", "no-cache")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"name": "admin " + s.cfg.Machine, "short_name": s.cfg.Machine, "lang": "fr",
		"start_url": "/sites", "scope": "/", "display": "standalone",
		// Barre du haut : la couleur du menu ; fond au lancement : celle des pages.
		"theme_color": "#0C0F15", "background_color": "#F5F6F8",
		"icons": []map[string]string{
			icon("/static/icon-192.png", "192x192", "any"),
			icon("/static/icon-512.png", "512x512", "any"),
			icon("/static/icon-512.png", "512x512", "maskable"),
		},
	})
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

// machineName : le nom de la machine, pour l'en-tête et l'application installée.
var machineName = "serveur"

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
		s.warmOnce(ctx)
		select {
		case <-ctx.Done():
			return
		case <-time.After(20 * time.Second):
		}
	}
}

// warmOnce : un tour de warm ; une panique (réponse inattendue d'une source) n'arrête pas la boucle.
func (s *Server) warmOnce(ctx context.Context) {
	defer recoverLog("warm")
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
	// Les pages lentes les plus ouvertes, prêtes avant qu'on les demande.
	_ = s.trafficPage("")
	_ = s.sshActivityOf()
}
