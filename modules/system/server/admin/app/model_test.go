package main

import (
	"bytes"
	"context"
	"encoding/json"
	"html"
	"html/template"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
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
	if initialOf("") != "" || initialOf("myetf") != "M" {
		t.Error("initialOf")
	}
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
