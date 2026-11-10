package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"html/template"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Fichiers réels du dépôt : les tests portent sur les vrais sites.
// Hors du dépôt (build Nix), ces tests se mettent de côté : le paquet ne dépend pas des sites.
const realApps = "../../../../../profiles/server/apps.json"
const realLock = "../../../../../profiles/server/apps.lock.json"

func testServer(t *testing.T) (*Server, *Snapshot) {
	t.Helper()
	appsRaw, err := os.ReadFile(realApps)
	if err != nil {
		t.Skip("apps.json du dépôt absent : ", err)
	}
	lockRaw, err := os.ReadFile(realLock)
	if err != nil {
		t.Fatal(err)
	}
	apps, err := parseApps(appsRaw)
	if err != nil {
		t.Fatal(err)
	}
	lock := map[string]lockEntry{}
	if err := json.Unmarshal(lockRaw, &lock); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{Domain: "nathanchampagne.com", Registry: "ghcr.io/nchpg", Host: "admin.test",
		Peers:      []string{"xiaomi_17t", "gram", "windows_gram", "oppo_a74", "xiaomi_9t", "xiaomi_14tpro", "lenovo_tab_p12"},
		SecretKeys: []string{"stage/gemini_env", "ghcr/token"}}
	tmpl := template.Must(template.New("").Funcs(funcs).ParseFS(assets, "templates/*.html"))
	return &Server{cfg: cfg, tmpl: tmpl}, &Snapshot{Head: "test", Apps: apps, LockRaw: lockRaw, Lock: lock}
}

// Empreintes à comparer avec `jq -cS '.<app>' | sha256sum` (FINGERPRINTS=1 go test -run Finger -v).
func TestFingerprints(t *testing.T) {
	_, snap := testServer(t)
	for _, n := range snap.Apps.Names() {
		t.Logf("%s %s", n, snap.Apps.Fingerprint(n))
	}
}

var (
	reInput    = regexp.MustCompile(`<input\b[^>]*>`)
	reSelect   = regexp.MustCompile(`(?s)<select\b[^>]*>.*?</select>`)
	reOption   = regexp.MustCompile(`<option\b[^>]*>`)
	reAttr     = regexp.MustCompile(`\b([a-z-]+)(?:="([^"]*)")?`)
	reSelTag   = regexp.MustCompile(`^<select\b[^>]*>`)
	reFormAttr = regexp.MustCompile(`\bform="([^"]*)"`)
)

func attrs(tag string) map[string]string {
	m := map[string]string{}
	for _, a := range reAttr.FindAllStringSubmatch(tag, -1) {
		m[a[1]] = html.UnescapeString(a[2])
	}
	return m
}

// formValues : ce que le navigateur enverrait pour le formulaire #site-form tel qu'affiché.
func formValues(page string) url.Values {
	v := url.Values{}
	for _, tag := range reInput.FindAllString(page, -1) {
		a := attrs(tag)
		if f := reFormAttr.FindStringSubmatch(tag); f != nil && f[1] != "site-form" {
			continue
		}
		name := a["name"]
		if name == "" {
			continue
		}
		switch a["type"] {
		case "checkbox", "radio":
			if _, ok := a["checked"]; ok {
				val := a["value"]
				if _, has := a["value"]; !has {
					val = "on"
				}
				v.Add(name, val)
			}
		default:
			v.Add(name, a["value"])
		}
	}
	for _, sel := range reSelect.FindAllString(page, -1) {
		name := attrs(reSelTag.FindString(sel))["name"]
		for _, opt := range reOption.FindAllString(sel, -1) {
			if a := attrs(opt); a["selected"] != "" || strings.Contains(opt, " selected") {
				v.Set(name, a["value"])
			}
		}
	}
	return v
}

// Un site affiché puis soumis sans modification redonne exactement son entrée : aucun faux diff.
func TestFormRoundTrip(t *testing.T) {
	s, snap := testServer(t)
	for _, name := range snap.Apps.Names() {
		e := snap.Apps.Entries[name]
		var images []string
		for _, c := range e.Containers {
			img, _ := splitImage(c.Image)
			images = append(images, img)
		}
		f := s.formVM(context.Background(), name, e, false, "", images, snap)
		var buf bytes.Buffer
		if err := s.tmpl.ExecuteTemplate(&buf, "form", f); err != nil {
			t.Fatal(err)
		}
		vals := formValues(buf.String())
		req := httptest.NewRequest("POST", "/sites/"+name+"/preview", strings.NewReader(vals.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.SetPathValue("app", name)
		if err := req.ParseForm(); err != nil {
			t.Fatal(err)
		}
		got, errs := s.entryFromForm(req, name, e, "", images, "")
		if len(errs) > 0 {
			t.Errorf("%s : erreurs %v", name, errs)
		}
		p := s.previewOf(name, &got, snap, false, "", nil)
		if p.Dirty {
			for _, l := range p.Lines {
				if l.Kind != "same" {
					t.Logf("%s %s %s", name, l.Kind, l.Text)
				}
			}
			t.Errorf("%s : diff alors que rien n'a changé (valeurs %v)", name, vals)
		}
		if errs := validate(s.cfg, name, got, snap.Apps.Entries); len(errs) > 0 {
			t.Errorf("%s : validation %v", name, errs)
		}
	}
}

func TestValidateRejects(t *testing.T) {
	s, snap := testServer(t)
	base := snap.Apps.Entries["mnist"]
	cases := map[string]func(e *Entry){
		"adresse prise": func(e *Entry) { e.Subdomain = "rlkart" },
		"vpn sans appareil": func(e *Entry) {
			e.Expose = "vpn"
			e.Devices = nil
		},
		"appareil inconnu": func(e *Entry) { e.Expose, e.Devices = "vpn", []string{"inconnu"} },
		"secret d'un autre": func(e *Entry) {
			c := e.Containers["web"]
			c.Secrets = []string{"ghcr/token"}
			e.Containers = map[string]Container{"web": c}
		},
		"données hors du site": func(e *Entry) {
			c := e.Containers["web"]
			c.Data = []Data{{Path: "/d", On: "/var/lib/vaultwarden"}}
			e.Containers = map[string]Container{"web": c}
		},
		"chemin avec ..": func(e *Entry) {
			c := e.Containers["web"]
			c.Data = []Data{{Path: "/../etc"}}
			e.Containers = map[string]Container{"web": c}
		},
	}
	for name, mutate := range cases {
		e := base
		e.Containers = map[string]Container{"web": base.Containers["web"]}
		mutate(&e)
		if errs := validate(s.cfg, "mnist", e, snap.Apps.Entries); len(errs) == 0 {
			t.Errorf("%s : accepté", name)
		}
	}
}

func TestHostPortMatchesNix(t *testing.T) {
	// Valeurs évaluées par Nix (hostPortEffective) le 2026-10-22.
	want := map[string]int{}
	if b, err := os.ReadFile(os.Getenv("NIX_PORTS")); err == nil {
		_ = json.Unmarshal(b, &want)
	}
	for name, p := range want {
		if got := hostPort(name); got != p {
			t.Errorf("%s : %d au lieu de %d", name, got, p)
		}
	}
}

func TestCandidateLock(t *testing.T) {
	s, snap := testServer(t)
	e := snap.Apps.Entries["mnist"]
	e.SSO = true
	appsOut, lockOut, images, err := s.candidate(context.Background(), snap.Apps, snap.LockRaw, Request{App: "mnist", Entry: &e})
	if err != nil {
		t.Fatal(err)
	}
	if len(images) != 0 {
		t.Errorf("aucune image nouvelle attendue : %v", images)
	}
	if !bytes.Equal(lockOut, append(bytes.TrimRight(snap.LockRaw, "\n"), '\n')) {
		var a, b any
		_ = json.Unmarshal(lockOut, &a)
		_ = json.Unmarshal(snap.LockRaw, &b)
		ja, _ := json.Marshal(a)
		jb, _ := json.Marshal(b)
		if string(ja) != string(jb) {
			t.Errorf("lock modifié alors que les images sont les mêmes")
		}
	}
	next, err := parseApps(appsOut)
	if err != nil {
		t.Fatal(err)
	}
	if !next.Entries["mnist"].SSO || len(next.Entries) != len(snap.Apps.Entries) {
		t.Errorf("apps.json candidat inattendu")
	}
}

func TestSeveralDataFolders(t *testing.T) {
	s, snap := testServer(t)
	e := snap.Apps.Entries["mnist"]
	vals := url.Values{"containers": {"web"}, "img_web": {"mnist-cnn-cpp"}, "newdata_web": {"/data  /uploads"}}
	req := httptest.NewRequest("POST", "/sites/mnist/preview", strings.NewReader(vals.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetPathValue("app", "mnist")
	_ = req.ParseForm()
	got, errs := s.entryFromForm(req, "mnist", e, "", []string{"mnist-cnn-cpp"}, "")
	if len(errs) > 0 || len(got.Containers["web"].Data) != 2 || got.Containers["web"].Data[1].Path != "/uploads" {
		t.Fatalf("attendu /data et /uploads : %+v %v", got.Containers["web"].Data, errs)
	}
}

func TestNextLink(t *testing.T) {
	for link, want := range map[string]string{
		`</v2/nchpg/app/tags/list?last=sha-9&n=1000>; rel="next"`: "/tags/list?last=sha-9&n=1000",
		`</v2/autre/app/tags/list?last=x>; rel="next"`:            "",
		`</v2/nchpg/app/tags/list?last=x>; rel="prev"`:            "",
		"": "",
	} {
		if got := nextLink(link, "nchpg/app"); got != want {
			t.Errorf("nextLink(%q) = %q, veut %q", link, got, want)
		}
	}
}

func TestSmallHelpers(t *testing.T) {
	for in, want := range map[string]string{"": "?", "abc": "abc", "0123456789": "0123456", "0123456789-dirty": "0123456-dirty"} {
		if got := shortRev(in); got != want {
			t.Errorf("shortRev(%q) = %q, veut %q", in, got, want)
		}
	}
	// Sans point d'entrée déclaré, le choix ne dépend pas de l'ordre de la table.
	for range 20 {
		if got := entryPointOf("", map[string]Container{"web": {}, "api": {}, "db": {}}); got != "api" {
			t.Fatalf("entryPointOf = %q", got)
		}
	}
}

// Une demande interrompue sans étape en échec (délai, arrêt) est close, pas « en cours » à jamais.
func TestJobAbort(t *testing.T) {
	j := &Job{Steps: []Step{{State: "done"}, {State: "active"}, {State: "todo"}}}
	j.abort("interrompu")
	v := j.Snapshot()
	if !v.Done || !v.Failed || v.Steps[1].State != "failed" || v.Steps[1].Detail != "interrompu" || v.Steps[2].State != "todo" {
		t.Errorf("abort : %+v", v)
	}
	done := &Job{Steps: []Step{{State: "done"}}, Done: true}
	done.abort("x")
	if done.Failed {
		t.Error("abort sur une demande terminée")
	}
}

// Message de commit : une ligne, accents compris.
func TestCommitMessage(t *testing.T) {
	for m, want := range map[string]bool{"feat(myetf): préversion publique": true, "a\nb": false, "": false} {
		if reCommitMessage.MatchString(m) != want {
			t.Errorf("%q : %v attendu", m, want)
		}
	}
}

// Bandeau d'état : chaque combinaison (version de think, tête de main, ce qu'a vu apps-deploy).
func TestStateCardOf(t *testing.T) {
	now := time.Now().Unix()
	st := func(head, deployed, state string) *DeployStatus {
		return &DeployStatus{Checked: now, Head: head, Deployed: deployed, State: state}
	}
	stale := &DeployStatus{Checked: now - 600, Head: "B", Deployed: "A", State: "non_pousse"}
	cases := []struct {
		name, think, head string
		st                *DeployStatus
		chip              string
	}{
		{"à jour", "A", "A", st("A", "A", "a_jour"), "à jour"},
		{"à jour, état périmé", "A", "A", stale, "à jour"},
		{"apps-deploy arrêté", "A", "B", stale, "inconnu"},
		{"rebuild pas encore vu", "C", "B", st("B", "A", "a_jour"), "vérification"},
		{"push pas encore vu", "A", "C", st("B", "A", "a_jour"), "nouveau commit"},
		{"think en avance (push suffit)", "C", "B", st("B", "C", "en_avance"), "à pousser"},
		{"think et main ont chacun des commits", "C", "B", st("B", "C", "non_pousse"), "à pousser"},
		{"version locale non commitée", "C-dirty", "B", st("B", "C-dirty", "local"), "modifié"},
		{"rebuild à faire", "A", "B", st("B", "A", "attente"), "en attente"},
		{"déploiement en cours", "A", "B", st("B", "A", "deploiement"), "en cours"},
		{"déploiement en échec", "A", "B", st("B", "A", "echec"), "échec"},
		{"diverge", "A", "B", st("B", "A", "diverge"), "à vérifier"},
		{"GitHub injoignable", "A", "B", st("B", "A", "github"), "GitHub ?"},
		{"état inconnu d'apps-deploy", "A", "B", st("B", "A", "inconnu"), "vérification"},
	}
	for _, c := range cases {
		if got := stateCardOf(c.think, c.head, "main", c.st, nil).Chip; got != c.chip {
			t.Errorf("%s : %q, attendu %q", c.name, got, c.chip)
		}
	}
	if got := stateCardOf("C", "B", "main", st("B", "C", "en_avance"), nil).Text; !strings.Contains(got, "git push suffit") {
		t.Errorf("en avance : %q", got)
	}
	if got := stateCardOf("A", "B", "main", nil, os.ErrNotExist).Chip; got != "inconnu" {
		t.Errorf("sans status.json : %q", got)
	}
}

// Demandes gardées sur disque : relues au démarrage, celles en cours reprennent à leur étape.
func TestJobsPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jobs.json")
	js := &Jobs{m: map[string]*Job{}, path: path}
	steps := func(states ...string) []Step {
		var out []Step
		for _, st := range states {
			out = append(out, Step{Label: "x", State: st})
		}
		return out
	}
	entry := Entry{Containers: map[string]Container{"web": {Image: "x:main"}}}
	js.add(&Job{ID: "fini", App: "a", Steps: steps("done", "done", "done", "done"), Done: true, Finished: time.Now()})
	js.add(&Job{ID: "deploie", App: "b", Steps: steps("done", "done", "active", "todo"), Dispatched: true, Head: "h", Req: Request{App: "b", Entry: &entry, Base: "new"}})
	js.add(&Job{ID: "commit-envoye", App: "c", Steps: steps("done", "active", "todo", "todo"), Dispatched: true})
	js.add(&Job{ID: "commit-pas-envoye", App: "d", Steps: steps("done", "active", "todo", "todo")})
	// Arrêt entre deux étapes (commit noté, étape 3 pas encore active) : reprise à l'étape 3.
	js.add(&Job{ID: "entre-deux", App: "e", Steps: steps("done", "done", "todo", "todo"), Dispatched: true})

	again := &Jobs{m: map[string]*Job{}, path: path}
	running := again.load()
	want := map[string]int{"deploie": 2, "commit-envoye": 1, "commit-pas-envoye": 0, "entre-deux": 2}
	if len(running) != len(want) {
		t.Fatalf("%d demandes à reprendre, attendu %d", len(running), len(want))
	}
	for _, j := range running {
		if got := resumeStep(j); got != want[j.ID] {
			t.Errorf("%s : reprise à l'étape %d, attendu %d", j.ID, got, want[j.ID])
		}
	}
	if b := again.latest("b"); b == nil || b.Req.Entry == nil || b.Req.Entry.Containers["web"].Image != "x:main" || b.Head != "h" {
		t.Errorf("demande relue incomplète : %+v", b)
	}
	if again.latest("a") == nil || !again.latest("a").Snapshot().Done {
		t.Errorf("demande finie perdue")
	}
}

// Une demande en cours n'est jamais oubliée, même vieille ; une finie depuis plus de 2 h, si.
func TestJobsPruneKeepsRunning(t *testing.T) {
	js := &Jobs{m: map[string]*Job{}}
	old := time.Now().Add(-5 * time.Hour)
	js.add(&Job{ID: "longue", App: "a", Created: old, Steps: []Step{{State: "active"}}})
	js.add(&Job{ID: "finie", App: "b", Created: old, Done: true, Finished: old})
	js.add(&Job{ID: "neuve", App: "c", Created: time.Now()})
	if js.get("longue") == nil {
		t.Errorf("demande en cours oubliée")
	}
	if js.get("finie") != nil {
		t.Errorf("demande finie depuis 5 h gardée")
	}
}

// Les pages et fragments des sites se rendent sans erreur (un champ mal nommé dans un template ne
// casse plus une page en silence) : racine, environnement, nouveau site, aperçus, suivi, liste.
func TestSitesTemplates(t *testing.T) {
	s, snap, e := withEnvs(t)
	s.jobs = &Jobs{m: map[string]*Job{}}
	ctx := context.Background()
	render := func(name string, data any) string {
		t.Helper()
		var buf bytes.Buffer
		if err := s.tmpl.ExecuteTemplate(&buf, name, data); err != nil {
			t.Errorf("%s : %v", name, err)
		}
		return buf.String()
	}
	for _, env := range []string{"", "preview", "staging"} {
		f := s.formVMFor(ctx, "myetf", e, env, false, "Nchpg/myetf", []string{"myetf"}, snap)
		f.Preview = s.previewOf("myetf", &e, snap, false, "", nil)
		page := render("editor", map[string]any{"Nav": "sites", "PageTitle": "myetf", "F": f})
		if strings.Count(page, `id="delete-form"`) > 1 || (env == "" && !strings.Contains(page, `id="delete-form"`)) {
			t.Errorf("%q : formulaire de suppression absent ou en double", env)
		}
		// Le formulaire refait (#editor-body) emporte le formulaire de suppression : jamais en double.
		if form := render("form", f); env == "" && !strings.Contains(form, `id="delete-form"`) {
			t.Errorf("formulaire de suppression hors de #editor-body")
		}
	}
	n := e
	n.Environments = nil
	nf := s.formVM(ctx, "nouveau", n, true, "Nchpg/nouveau", []string{"myetf"}, snap)
	nf.Preview = s.previewOf("nouveau", &n, snap, true, "", nil)
	if html := render("newform", map[string]any{"F": nf, "Notes": []string{"une note"}}); !strings.Contains(html, `placeholder="nouveau"`) {
		t.Errorf("nouveau site : sous-domaine pré-rempli au lieu d'être vide")
	}
	render("newform", map[string]any{"Error": "pas d'image"})
	render("new", map[string]any{"Nav": "sites", "PageTitle": "Nouveau site", "Repos": []RepoOpt{{FullName: "Nchpg/myetf", Images: []string{"myetf"}, Private: true, Live: "myetf"}}})
	render("new", map[string]any{"Nav": "sites", "Error": "packages illisibles"})

	changed := cloneEntry(e)
	changed.SSO = !changed.SSO
	dirty := s.previewOf("myetf", &changed, snap, false, "", []string{"une erreur"})
	if !dirty.Auto || !strings.Contains(render("preview", dirty), `name="msg_auto"`) {
		t.Errorf("message proposé sans msg_auto")
	}
	if html := render("preview", PreviewVM{Errors: []string{"main injoignable"}}); strings.Contains(html, "à jour") {
		t.Errorf("une erreur seule montrée « à jour »")
	}

	steps := func(states ...string) []Step {
		var out []Step
		for _, st := range states {
			out = append(out, Step{Label: "x", Sub: "y", State: st, Detail: "d"})
		}
		return out
	}
	for _, j := range []JobView{
		{ID: "a", App: "myetf", Page: "/sites/myetf?env=preview", Steps: steps("done", "active", "todo", "todo")},
		{ID: "b", App: "myetf", Page: "/sites/myetf", Done: true, Failed: true, Steps: steps("done", "failed", "todo", "todo")},
		{ID: "c", App: "myetf", Page: "/sites/myetf", Done: true, Domain: "etf.x", Steps: steps("done", "done", "done", "done")},
		{ID: "d", App: "myetf", Delete: true, Done: true, Steps: steps("done", "done", "done", "done")},
		{ID: "e", App: "neuf", New: true, Done: true, Failed: true, Steps: steps("failed", "todo", "todo", "todo")},
	} {
		html := render("job", j)
		render("job-page", map[string]any{"Nav": "sites", "Job": j})
		if j.ID == "e" && !strings.Contains(html, `href="/sites/new"`) {
			t.Errorf("nouveau site en échec : pas de retour au choix du dépôt")
		}
		if j.ID == "c" && !strings.Contains(html, `data-reload-to="/sites/myetf"`) {
			t.Errorf("fin d'une demande : retour ailleurs que sur la page du site")
		}
	}
	running := JobView{ID: "a", App: "myetf", Steps: steps("done", "active", "todo", "todo")}
	f := s.formVMFor(ctx, "myetf", e, "", false, "", []string{"myetf"}, snap)
	f.Running = &running
	f.Failed = &JobBadge{Detail: "x"}
	render("editor", map[string]any{"Nav": "sites", "F": f})

	for _, st := range []string{"", "running", "busy", "done", "failed"} {
		render("recopy", map[string]any{"URL": "/sites/myetf/env/preview/recopy", "Path": "web:/app/data", "ID": "recopy-web-app-data", "R": &RecopyVM{State: st, Text: "t"}})
	}

	data := s.sitesData(ctx, snap)
	data["State"] = stateCardOf("A", "B", "main", &DeployStatus{Checked: time.Now().Unix(), Head: "B", Deployed: "A", State: "attente"}, nil)
	data["Activity"] = Activity{Days: []ActivityDay{{Label: "hier", Items: []ActivityItem{describeCommit("feat(myetf): make public", true)}}}, More: true}
	render("sites", data)
	data["OOB"] = true
	if html := render("cards-refresh", data); !strings.Contains(html, `id="online" hx-swap-oob="true"`) {
		t.Errorf("cartes sans le compteur « En ligne » à remplacer")
	}
	render("site-status", map[string]any{"App": "myetf", "Env": "preview", "Up": true, "Probed": true})
}

// Le run d'une demande se retrouve par son nom (run-name d'apps.yml), jamais celui d'une autre.
func TestRunFor(t *testing.T) {
	runs := []Run{
		{ID: 1, DisplayTitle: "pin  []"},
		{ID: 2, DisplayTitle: "edit myetf [0123456789abcdef]"},
		{ID: 3, DisplayTitle: "access gram [fedcba9876543210]"},
		{ID: 4, DisplayTitle: "apps"},
	}
	if r := runFor(runs, "fedcba9876543210"); r == nil || r.ID != 3 {
		t.Errorf("runFor : %+v", r)
	}
	if runFor(runs, "") != nil || runFor(runs, "0000000000000000") != nil {
		t.Error("runFor : run d'une autre demande")
	}
	if runs[0].Request() != "" || runs[3].Request() != "" {
		t.Error("Request : identifiant trouvé dans un run qui n'en a pas")
	}
}

// Cache de l'API : une seule lecture pour des demandes simultanées, une erreur gardée un moment, mais
// pas une demande abandonnée.
func TestGitHubCached(t *testing.T) {
	g := newGitHub(&Config{})
	var calls atomic.Int32
	release := make(chan struct{})
	var wg sync.WaitGroup
	for range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v, err := g.cached("k", time.Minute, func() (any, error) {
				calls.Add(1)
				<-release
				return "v", nil
			})
			if err != nil || v != "v" {
				t.Errorf("%v %v", v, err)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if n := calls.Load(); n != 1 {
		t.Errorf("%d lectures pour une clé, attendu 1", n)
	}
	fails := 0
	for range 3 {
		_, _ = g.cached("bad", time.Hour, func() (any, error) { fails++; return nil, errors.New("quota") })
	}
	if fails != 1 {
		t.Errorf("erreur relue %d fois, attendu 1 (gardée errTTL)", fails)
	}
	cancels := 0
	for range 2 {
		_, _ = g.cached("ctx", time.Hour, func() (any, error) { cancels++; return nil, context.Canceled })
	}
	if cancels != 2 {
		t.Errorf("demande abandonnée gardée en cache")
	}
}

// Écritures simultanées du fichier des demandes : toujours un JSON entier, avec le dernier état.
func TestJobsSaveConcurrent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jobs.json")
	js := &Jobs{m: map[string]*Job{}, path: path}
	var jobs []*Job
	for i := range 8 {
		j := &Job{ID: fmt.Sprint(i), App: fmt.Sprint("app", i), Steps: []Step{{State: "active"}, {State: "todo"}}, Dispatched: true}
		js.add(j)
		jobs = append(jobs, j)
	}
	var wg sync.WaitGroup
	for _, j := range jobs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 20 {
				j.set(0, "done", "", "")
			}
			j.set(1, "active", "", "")
		}()
	}
	wg.Wait()
	again := &Jobs{m: map[string]*Job{}, path: path}
	running := again.load()
	if len(running) != len(jobs) {
		t.Fatalf("%d demandes relues, attendu %d", len(running), len(jobs))
	}
	for _, j := range running {
		if resumeStep(j) != 1 {
			t.Errorf("%s : état ancien écrit en dernier (%+v)", j.ID, j.Steps)
		}
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(path), "*.tmp")); len(left) > 0 {
		t.Errorf("fichiers temporaires restés : %v", left)
	}
}
