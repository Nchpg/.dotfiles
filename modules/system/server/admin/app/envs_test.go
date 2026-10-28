package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

// myetf avec deux environnements : preview (accès et conteneurs propres, données copiées) et
// staging (hérite de preview, données partagées, figé sur un commit, autre adresse).
func withEnvs(t *testing.T) (*Server, *Snapshot, Entry) {
	t.Helper()
	s, snap := testServer(t)
	e := cloneEntry(snap.Apps.Entries["myetf"])
	e.Environments = map[string]Env{
		"preview": {Branch: "preview", Data: DataModes{"web:/app/data": "copy"}, Expose: "public",
			Containers: map[string]Container{"web": {Image: "myetf", Memory: "256m", Data: []Data{{Path: "/app/data"}}}}},
		"staging": {Name: "Staging", Branch: "preview", From: "preview", Data: DataModes{"web:/app/data": "shared"}, Subdomain: "etf-staging", Pin: "sha-3a91c2e0"},
	}
	raw, err := snap.Apps.WithEntry("myetf", &e)
	if err != nil {
		t.Fatal(err)
	}
	apps, err := parseApps(raw)
	if err != nil {
		t.Fatal(err)
	}
	snap.Apps = apps
	return s, snap, apps.Entries["myetf"]
}

// Mêmes résultats que l'évaluation Nix de cette entrée (modules/system/server/app-images/apps-file.nix).
func TestEnvDeploysMatchNix(t *testing.T) {
	s, _, e := withEnvs(t)
	want := map[string][4]string{
		"myetf":         {"etf.vpn.nathanchampagne.com", "myetf:main", "", "/var/lib/apps/myetf/web/app/data"},
		"myetf-preview": {"myetf-preview.nathanchampagne.com", "myetf:preview", "256m", "/var/lib/apps/myetf-preview/web/app/data"},
		"myetf-staging": {"etf-staging.nathanchampagne.com", "myetf:sha-3a91c2e0", "256m", "/var/lib/apps/myetf-preview/web/app/data"},
	}
	ds := e.Deploys("myetf")
	if len(ds) != 3 {
		t.Fatalf("3 déploiements attendus, %d", len(ds))
	}
	for _, d := range ds {
		w, ok := want[d.App]
		if !ok {
			t.Fatalf("déploiement inattendu %s", d.App)
		}
		c := d.Ctrs.Containers["web"]
		got := [4]string{d.Domain(s.cfg.Domain), c.Image, c.Memory, e.DataHost("myetf", d.ID, "web", "/app/data")}
		if got != w {
			t.Errorf("%s : %v, attendu %v", d.App, got, w)
		}
	}
	if errs := validate(s.cfg, "myetf", e, map[string]Entry{}); len(errs) > 0 {
		t.Errorf("entrée valide refusée : %v", errs)
	}
}

func submit(t *testing.T, s *Server, snap *Snapshot, e Entry, env string, edit func(v map[string][]string)) Entry {
	t.Helper()
	f := s.formVMFor(context.Background(), "myetf", e, env, false, "", []string{"myetf"}, snap)
	var buf bytes.Buffer
	if err := s.tmpl.ExecuteTemplate(&buf, "form", f); err != nil {
		t.Fatal(err)
	}
	vals := formValues(buf.String())
	if edit != nil {
		edit(vals)
	}
	req := httptest.NewRequest("POST", "/sites/myetf/preview", strings.NewReader(vals.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetPathValue("app", "myetf")
	if err := req.ParseForm(); err != nil {
		t.Fatal(err)
	}
	got, errs := s.entryFromForm(req, "myetf", e, env, []string{"myetf"}, "")
	if len(errs) > 0 {
		t.Fatalf("%s : erreurs %v", env, errs)
	}
	return got
}

func jsonOf(e Entry) string {
	if len(e.Environments) == 0 {
		e.Environments = nil
	}
	b, _ := entryJSON(e)
	c, _ := canonical(b)
	return c
}

// Chaque déploiement affiché puis soumis tel quel redonne exactement l'entrée.
func TestEnvFormRoundTrip(t *testing.T) {
	s, snap, e := withEnvs(t)
	for _, env := range []string{"", "preview", "staging"} {
		if got := submit(t, s, snap, e, env, nil); jsonOf(got) != jsonOf(e) {
			t.Errorf("%q : diff alors que rien n'a changé\n%s\n%s", env, jsonOf(e), jsonOf(got))
		}
	}
}

// Passer une section en « propre » part des valeurs du parent ; la repasser en « hérité » les retire.
func TestEnvOwnToggles(t *testing.T) {
	s, snap, e := withEnvs(t)
	got := submit(t, s, snap, e, "staging", func(v map[string][]string) { v["own_containers"] = []string{"1"} })
	st := got.Environments["staging"]
	if c, ok := st.Containers["web"]; !ok || c.Image != "myetf" || c.Memory != "256m" || len(c.Data) != 1 {
		t.Errorf("conteneurs propres copiés du parent attendus : %+v", st.Containers)
	}
	got = submit(t, s, snap, e, "preview", func(v map[string][]string) { v["own_access"] = []string{"0"} })
	pv := got.Environments["preview"]
	if pv.Expose != "" {
		t.Errorf("accès hérité attendu : %+v", pv)
	}
	d, _ := got.Deploy("myetf", "preview")
	if !d.VPN() {
		t.Errorf("preview devrait hériter du VPN de la racine")
	}
	got = submit(t, s, snap, e, "preview", func(v map[string][]string) { v["own_options"] = []string{"1"} })
	if o := got.Environments["preview"].InternetAccess; o == nil || !*o {
		t.Errorf("options propres copiées de la racine (internet ouvert) attendues")
	}
}

// Retirer preview : staging hérite de la racine.
func TestWithoutEnv(t *testing.T) {
	_, _, e := withEnvs(t)
	got := withoutEnv(e, "preview")
	if _, ok := got.Environments["preview"]; ok || got.Environments["staging"].From != "" {
		t.Errorf("staging devrait hériter de la racine : %+v", got.Environments)
	}
}

func TestEnvValidateRejects(t *testing.T) {
	s, _, base := withEnvs(t)
	cases := map[string]func(e *Entry){
		"boucle": func(e *Entry) {
			v := e.Environments["preview"]
			v.From = "staging"
			e.Environments["preview"] = v
		},
		"parent inconnu": func(e *Entry) {
			v := e.Environments["staging"]
			v.From = "nope"
			e.Environments["staging"] = v
		},
		"image avec tag": func(e *Entry) {
			v := e.Environments["preview"]
			v.Containers = map[string]Container{"web": {Image: "myetf:main"}}
			e.Environments["preview"] = v
		},
		"adresse de la racine": func(e *Entry) {
			v := e.Environments["staging"]
			v.Subdomain = "etf"
			v.Expose, v.Devices = "vpn", []string{"gram"}
			e.Environments["staging"] = v
		},
		"pin invalide": func(e *Entry) {
			v := e.Environments["staging"]
			v.Pin = "main"
			e.Environments["staging"] = v
		},
		"nom d'un autre site": func(e *Entry) { e.Environments["x"] = Env{Branch: "main"} },
		"appareils sans accès propre": func(e *Entry) {
			v := e.Environments["staging"]
			v.Devices = []string{"gram"}
			e.Environments["staging"] = v
		},
		"point d'entrée sans conteneurs propres": func(e *Entry) {
			v := e.Environments["staging"]
			v.Entrypoint = "web"
			e.Environments["staging"] = v
		},
		"santé sans options propres": func(e *Entry) {
			v := e.Environments["staging"]
			v.Probe = "/health"
			e.Environments["staging"] = v
		},
	}
	for name, mutate := range cases {
		e := cloneEntry(base)
		mutate(&e)
		others := map[string]Entry{"myetf-x": {Containers: map[string]Container{"web": {Image: "portfolio:main"}}}}
		if errs := validate(s.cfg, "myetf", e, others); len(errs) == 0 {
			t.Errorf("%s : accepté", name)
		}
	}
}

// Le lock candidat garde les images des environnements (aucune n'est élaguée).
func TestCandidateKeepsEnvImages(t *testing.T) {
	s, snap, e := withEnvs(t)
	lock := map[string]any{}
	_ = json.Unmarshal(snap.LockRaw, &lock)
	lock["ghcr.io/nchpg/myetf:preview"] = lock["ghcr.io/nchpg/myetf:main"]
	lock["ghcr.io/nchpg/myetf:sha-3a91c2e0"] = lock["ghcr.io/nchpg/myetf:main"]
	lockRaw, _ := json.Marshal(lock)
	_, lockOut, images, err := s.candidate(context.Background(), snap.Apps, lockRaw, Request{App: "myetf", Entry: &e})
	if err != nil {
		t.Fatal(err)
	}
	if len(images) != 0 {
		t.Errorf("aucune image nouvelle attendue : %v", images)
	}
	for _, ref := range []string{"ghcr.io/nchpg/myetf:preview", "ghcr.io/nchpg/myetf:sha-3a91c2e0", "ghcr.io/nchpg/myetf:main"} {
		if !strings.Contains(string(lockOut), ref) {
			t.Errorf("%s élagué du lock", ref)
		}
	}
}

// Les déploiements que touche une modification : l'environnement changé et ceux qui en héritent.
func TestTargetsFollowInheritance(t *testing.T) {
	s, _, e := withEnvs(t)
	next := cloneEntry(e)
	v := next.Environments["preview"]
	c := v.Containers["web"]
	c.Memory = "512m"
	v.Containers = map[string]Container{"web": c}
	next.Environments["preview"] = v
	var apps []string
	for _, tg := range (Request{App: "myetf", Entry: &next, Old: &e}).targets(s.cfg.Domain) {
		apps = append(apps, tg.App)
	}
	if strings.Join(apps, ",") != "myetf-preview,myetf-staging" {
		t.Errorf("cibles : %v", apps)
	}
}

func TestDescribeCommit(t *testing.T) {
	cases := []struct {
		subject string
		config  bool
		want    [3]string
	}{
		{"feat(myetf): make public", true, [3]string{"myetf", "make public", "réglages"}},
		{"chore(apps): bump rlkart-backend, rlkart-frontend (c2ef74f)", false, [3]string{"rlkart-backend, rlkart-frontend", "mis à jour", "nouvelle image"}},
		{"feat(myetf): add preview environment", true, [3]string{"myetf", "add preview environment", "environnement"}},
		{"chore: tidy apps.json by hand", true, [3]string{"", "chore: tidy apps.json by hand", "réglages"}},
	}
	for _, c := range cases {
		it := describeCommit(c.subject, c.config)
		if got := [3]string{it.Name, it.What, it.Kind}; got != c.want {
			t.Errorf("%q : %v, attendu %v", c.subject, got, c.want)
		}
	}
}

// Comptes d'un site avec Authelia : gardés tels quels, tous cochés tous nommés, aucun refusé.
func TestEnvFormAccounts(t *testing.T) {
	s, snap, e := withEnvs(t)
	s.cfg.AccountsFile = ""
	s.cfg.Authelia.Accounts = map[string][]string{"nathan": {"admin"}, "olivier": {"nextcloud"}}
	pv := e.Environments["preview"]
	pv.Expose, pv.SSO, pv.Accounts = "public", true, []string{"nathan"}
	e.Environments["preview"] = pv
	if got := submit(t, s, snap, e, "preview", nil); !slices.Equal(got.Environments["preview"].Accounts, []string{"nathan"}) {
		t.Errorf("comptes perdus : %+v", got.Environments["preview"])
	}
	got := submit(t, s, snap, e, "preview", func(v map[string][]string) { v["acct"] = []string{"nathan", "olivier"} })
	if a := got.Environments["preview"].Accounts; !slices.Equal(a, []string{"nathan", "olivier"}) {
		t.Errorf("tous cochés : %v", a)
	}
	got = submit(t, s, snap, e, "preview", func(v map[string][]string) { delete(v, "sso") })
	if a := got.Environments["preview"]; a.SSO || a.Accounts != nil {
		t.Errorf("sans Authelia, plus de comptes : %+v", a)
	}
	if errs := validateAccounts("preview : ", true, accountsFromForm(nil, s.accountChoices(nil))); len(errs) != 1 {
		t.Errorf("aucun compte coché accepté")
	}
}

// Secrets d'un conteneur : l'ordre choisi est gardé (le dernier l'emporte pour une variable en double).
func TestSecretOrder(t *testing.T) {
	keys := []string{"s/a", "s/b", "s/c"}
	if got := reorderSecrets(slices.Clone(keys), "web", "web|s/c|up", ""); !slices.Equal(got, []string{"s/a", "s/c", "s/b"}) {
		t.Errorf("monter : %v", got)
	}
	if got := reorderSecrets(slices.Clone(keys), "web", "web|s/a|up", ""); !slices.Equal(got, keys) {
		t.Errorf("monter le premier : %v", got)
	}
	if got := reorderSecrets(slices.Clone(keys), "web", "web|s/a|down", ""); !slices.Equal(got, []string{"s/b", "s/a", "s/c"}) {
		t.Errorf("descendre : %v", got)
	}
	if got := reorderSecrets(slices.Clone(keys), "web", "", "web|s/b"); !slices.Equal(got, []string{"s/a", "s/c"}) {
		t.Errorf("retirer : %v", got)
	}
	if got := reorderSecrets(slices.Clone(keys), "web", "api|s/c|up", "api|s/a"); !slices.Equal(got, keys) {
		t.Errorf("autre conteneur touché : %v", got)
	}

	s, snap, e := withEnvs(t)
	s.cfg.SecretKeys = []string{"myetf/a", "myetf/b", "myetf/c"}
	web := e.Containers["web"]
	web.Secrets = []string{"myetf/c", "myetf/a"} // pas dans l'ordre alphabétique
	e.Containers["web"] = web
	if got := submit(t, s, snap, e, "", nil).Containers["web"].Secrets; !slices.Equal(got, []string{"myetf/c", "myetf/a"}) {
		t.Errorf("ordre perdu au formulaire : %v", got)
	}
	got := submit(t, s, snap, e, "", func(v map[string][]string) { v["sec_web"] = append(v["sec_web"], "myetf/b") }).Containers["web"].Secrets
	if !slices.Equal(got, []string{"myetf/c", "myetf/a", "myetf/b"}) {
		t.Errorf("secret coché : à la fin, %v", got)
	}
	if d, _ := e.Deploy("myetf", ""); !slices.Equal(d.Ctrs.Containers["web"].Secrets, []string{"myetf/c", "myetf/a"}) {
		t.Errorf("ordre perdu au déploiement : %v", d.Ctrs.Containers["web"].Secrets)
	}
}

// Une section que la page vient de passer en « propre » (encore héritée sur main) se lit dans la page :
// une case cochée juste après n'est pas perdue (avant : le parent était recopié à chaque fois).
func TestEnvOwnSectionsReadFromPage(t *testing.T) {
	s, snap, e := withEnvs(t)
	s.cfg.SecretKeys = []string{"myetf/a", "myetf/b"}
	pv := e.Environments["preview"]
	pv.Containers, pv.Entrypoint = nil, ""
	pv.InternetAccess, pv.Probe, pv.RateLimit = nil, "", nil
	e.Environments["preview"] = pv

	// 1. La page passe les conteneurs et les options en propres : copies du parent.
	draft := submit(t, s, snap, e, "preview", func(v map[string][]string) {
		v["own_containers"], v["own_options"] = []string{"1"}, []string{"1"}
	})
	// 2. Puis, page refaite sur ce brouillon (main inchangé), un secret coché et internet fermé.
	f := s.formVMFor(context.Background(), "myetf", draft, "preview", false, "", []string{"myetf"}, snap)
	var buf bytes.Buffer
	if err := s.tmpl.ExecuteTemplate(&buf, "form", f); err != nil {
		t.Fatal(err)
	}
	vals := formValues(buf.String())
	vals["sec_web"] = append(vals["sec_web"], "myetf/b")
	delete(vals, "internet")
	req := httptest.NewRequest("POST", "/sites/myetf/form", strings.NewReader(vals.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if err := req.ParseForm(); err != nil {
		t.Fatal(err)
	}
	got, errs := s.entryFromForm(req, "myetf", e, "preview", []string{"myetf"}, "")
	if len(errs) > 0 {
		t.Fatalf("erreurs : %v", errs)
	}
	g := got.Environments["preview"]
	if !slices.Contains(g.Containers["web"].Secrets, "myetf/b") {
		t.Errorf("secret coché perdu : %v", g.Containers["web"].Secrets)
	}
	if g.InternetAccess == nil || *g.InternetAccess {
		t.Errorf("internet fermé perdu : %v", g.InternetAccess)
	}
}

// Données : un mode par dossier ; chemins et recopie qui suivent ; formulaire qui n'écrit que les
// dossiers non séparés.
func TestEnvDataPerFolder(t *testing.T) {
	s, snap, e := withEnvs(t)
	web := e.Containers["web"]
	web.Data = []Data{{Path: "/app/data"}, {Path: "/app/cache"}}
	e.Containers["web"] = web
	pv := e.Environments["preview"]
	pv.Containers, pv.Entrypoint = nil, ""
	pv.Data = DataModes{"web:/app/data": "copy", "web:/app/cache": "shared"}
	e.Environments["preview"] = pv
	if got := e.DataHost("myetf", "preview", "web", "/app/data"); got != "/var/lib/apps/myetf-preview/web/app/data" {
		t.Errorf("/app/data en copie : %s", got)
	}
	if got := e.DataHost("myetf", "preview", "web", "/app/cache"); got != "/var/lib/apps/myetf/web/app/cache" {
		t.Errorf("/app/cache partagé : %s", got)
	}
	if !pv.Data.AnyCopy() || (DataModes{"web:/app/cache": "shared"}).AnyCopy() {
		t.Errorf("AnyCopy : seulement avec un dossier en copie")
	}
	if errs := validate(s.cfg, "myetf", e, map[string]Entry{}); len(errs) > 0 {
		t.Errorf("modes valides refusés : %v", errs)
	}
	if got := recopyID("web:/app/data"); got != "recopy-web-app-data" {
		t.Errorf("identifiant de recopie : %s", got)
	}

	// Formulaire : rendu puis soumis tel quel, rien ne change ; un dossier repassé en séparé disparaît.
	if got := submit(t, s, snap, e, "preview", nil).Environments["preview"].Data; !sameJSON(got, pv.Data) {
		t.Errorf("modes perdus au formulaire : %+v", got)
	}
	got := submit(t, s, snap, e, "preview", func(v map[string][]string) { v["dmode_web:/app/cache"] = []string{"separate"} }).Environments["preview"].Data
	if !sameJSON(got, DataModes{"web:/app/data": "copy"}) {
		t.Errorf("cache séparé : %+v", got)
	}
	got = submit(t, s, snap, e, "preview", func(v map[string][]string) {
		v["dmode_web:/app/cache"], v["dmode_web:/app/data"] = []string{"separate"}, []string{"separate"}
	}).Environments["preview"].Data
	if got != nil {
		t.Errorf("tous séparés : rien à écrire, %+v", got)
	}

	// Un dossier qui n'existe pas, ou un mode inconnu : refusés.
	for _, bad := range []DataModes{{"web:/inconnu": "copy"}, {"web:/app/data": "clone"}} {
		pv.Data = bad
		e.Environments["preview"] = pv
		if errs := validate(s.cfg, "myetf", e, map[string]Entry{}); len(errs) == 0 {
			t.Errorf("accepté à tort : %v", bad)
		}
	}
}
