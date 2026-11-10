package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

// Une préversion passe avant sa version, et n'est pas retenue comme release du projet.
func TestPrerelease(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want int
	}{{"2.0.0-rc1", "2.0.0", -1}, {"2.0.0", "2.0.0-rc1", 1}, {"2.0.0-rc1", "2.0.0-rc2", -1}, {"2.0.0-beta2", "1.9.9", 1},
		{"10.6p1", "10.6p1", 0}, {"10.6p2", "10.6p1", 1}, {"1.1.1w", "1.1.1w", 0}, {"v4.40.0", "4.39.28", 1}} {
		if got := cmpVersions(c.a, c.b); got != c.want {
			t.Errorf("cmpVersions(%s, %s) = %d, attendu %d", c.a, c.b, got, c.want)
		}
	}
	rels := []Release{{Tag: "v2.0.0-rc1", URL: "rc"}, {Tag: "v1.9.0", URL: "u19"}, {Tag: "v1.9.1", URL: "u191"}}
	if l := pickLatest("", filterReleases(rels, "1.9.0"), nil); l.Version != "1.9.1" {
		t.Errorf("la dernière ne doit pas être une préversion : %+v", l)
	}
	if p, v := splitTag("helm-loki-6.1.0"); p != "helm-loki-" || v != "6.1.0" {
		t.Errorf("splitTag : %q %q", p, v)
	}
}

func recapRows() []UpdateRow {
	return []UpdateRow{{ID: "services.nginx", Name: "nginx", Current: "1.30.6", Next: "1.30.6", Change: "same"}}
}

// Récapitulatif : des sources qui avancent ne sont pas « à jour » ; les versions comptées sont
// celles qui changent ; trop long, la liste est coupée entre deux lignes et le lien reste.
func TestRecapText(t *testing.T) {
	link := "https://admin.vpn.x/updates"
	res := updatesResult{Inputs: []InputRow{{Name: "nixpkgs-stable", MainRev: "a", NextRev: "b", Commits: 12}}}
	msg := recapText("think", link, res, recapRows(), nil)
	if strings.Contains(msg, "est à jour") || !strings.Contains(msg, "1 source avancerait") || strings.Contains(msg, "version") {
		t.Errorf("sources seules :\n%s", msg)
	}
	if msg := recapText("think", link, updatesResult{}, recapRows(), nil); !strings.Contains(msg, "✅ **think** est à jour") {
		t.Errorf("rien :\n%s", msg)
	}
	// Une alerte à version égale n'est pas une version qui change.
	stuck := []UpdateRow{{Name: "podman", Current: "5.8.9", Next: "5.8.9", Change: "same", Stuck: true, FixIn: "6.1.3", Source: "nixpkgs-stable"},
		{Name: "authelia", Current: "4.39.28", Next: "4.40.1", Change: "minor", ChangeLabel: "mineure"}}
	if msg := recapText("think", link, updatesResult{}, stuck, nil); !strings.Contains(msg, "1 version changerait avec `update` ; 1 alerte") {
		t.Errorf("alerte :\n%s", msg)
	}
	var many []UpdateRow
	for i := 0; i < 11; i++ {
		many = append(many, UpdateRow{Name: "paquet-é", Current: "1", Next: "2", Change: "major", ChangeLabel: "majeure",
			AI: &Analysis{Urgency: "urgent", Summary: strings.Repeat("é", 200)}})
	}
	msg = recapText("think", link, updatesResult{}, many, nil)
	if len(msg) > discordMax || !utf8.ValidString(msg) || !strings.HasSuffix(msg, link) || !strings.Contains(msg, "autres lignes") {
		t.Errorf("message long (%d) :\n%s", len(msg), msg)
	}
	if msg := recapText("think", link, updatesResult{Error: "x\n" + strings.Repeat("é", 1000)}, nil, nil); len(msg) > discordMax || !strings.HasSuffix(msg, link) {
		t.Errorf("erreur longue : %d", len(msg))
	}
}

// Un fichier d'avant Attempted : une vérification ratée n'était pas une réussite.
func TestReadUpdatesLegacy(t *testing.T) {
	dir := t.TempDir()
	s := &Server{cfg: &Config{StateDir: dir}}
	at := time.Date(2026, 11, 1, 7, 0, 0, 0, time.UTC)
	b, _ := json.Marshal(map[string]any{"checked": at, "error": "git ls-remote : exit 128"})
	_ = os.WriteFile(s.updatesFile(), b, 0o644)
	if r := s.readUpdates(); !r.Checked.IsZero() || !r.Attempted.Equal(at) {
		t.Errorf("ancien échec : %+v", r)
	}
	_ = os.WriteFile(s.updatesFile(), []byte(`{"checked":`), 0o644)
	if r := s.readUpdates(); !r.Checked.IsZero() {
		t.Errorf("fichier coupé : %+v", r)
	}
}

// Un fichier d'état illisible est mis de côté, pas écrasé sans trace.
func TestLoadJSONStateBad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ai.json")
	_ = os.WriteFile(path, []byte(`{"a":`), 0o644)
	m := map[string]Analysis{}
	loadJSONState(path, &m)
	if len(m) != 0 {
		t.Errorf("%v", m)
	}
	if _, err := os.Stat(path + ".bad"); err != nil {
		t.Errorf("pas de .bad : %v", err)
	}
}

// Les analyses qui ne servent plus s'en vont avec l'âge ; celles qui servent restent.
func TestPruneAnalyses(t *testing.T) {
	aiCache.m = nil
	s := &Server{cfg: &Config{StateDir: t.TempDir()}}
	old := time.Now().Add(-100 * 24 * time.Hour)
	s.saveAnalyses(map[string]Analysis{"used": {At: old}, "gone": {At: old}, "recent": {At: time.Now()}})
	s.pruneAnalyses(map[string]bool{"used": true}, keepAnalyses)
	got := s.rawAnalyses()
	if _, ok := got["gone"]; ok || len(got) != 2 {
		t.Errorf("%v", got)
	}
	aiCache.m = nil
}

// Un paquet oublié par le modèle est signalé ; un quota atteint arrête les lots suivants.
func TestAnalyzeMissingAndQuota(t *testing.T) {
	var calls atomic.Int32
	var quota atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if quota.Load() {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"error":{"message":"quota","status":"RESOURCE_EXHAUSTED"}}`))
			return
		}
		answer := `[{"id":"a","urgency":"sans","summary":"Rien."}]`
		b, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": answer}}}}}})
		_, _ = w.Write(b)
	}))
	defer srv.Close()
	old := geminiBase
	geminiBase = srv.URL
	defer func() { geminiBase = old }()
	aiCache.m, cveCache.m = nil, nil
	s := &Server{cfg: &Config{GeminiKey: "k", AIModel: "m", StateDir: t.TempDir()}}
	rows := []UpdateRow{{ID: "a", Name: "a", Current: "1", Next: "2", Change: "major"}, {ID: "b", Name: "b", Current: "1", Next: "2", Change: "major"}}
	if err := s.analyze(t.Context(), rows); err == nil || !strings.Contains(err.Error(), "pas de réponse pour b") {
		t.Errorf("oubli : %v", err)
	}
	aiCache.m = nil
	quota.Store(true)
	calls.Store(0)
	var many []UpdateRow
	for _, id := range []string{"c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"} {
		many = append(many, UpdateRow{ID: id, Name: id, Current: "1", Next: "2", Change: "major"})
	}
	s.cfg.StateDir = t.TempDir()
	err := s.analyze(t.Context(), many)
	if calls.Load() != 1 || err == nil || !strings.Contains(err.Error(), "quota atteint") || strings.Count(err.Error(), "HTTP 429") != 1 {
		t.Errorf("quota : %d appels, %v", calls.Load(), err)
	}
	aiCache.m = nil
}

// Une panne de NVD : une ligne pour toutes les CVE, pas une par CVE.
func TestScoreCVEsGrouped(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "kev") {
			_, _ = w.Write([]byte(`{"vulnerabilities":[]}`))
			return
		}
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	oldNVD, oldKEV, oldPause := nvdBase, kevURL, nvdPause
	nvdBase, kevURL, nvdPause = srv.URL+"/nvd", srv.URL+"/kev", 0
	defer func() { nvdBase, kevURL, nvdPause = oldNVD, oldKEV, oldPause }()
	aiCache.m, cveCache.m = nil, nil
	cfg := &Config{StateDir: t.TempDir()}
	s := &Server{cfg: cfg, gh: &GitHub{cfg: cfg, cache: map[string]cacheItem{}}}
	s.saveAnalyses(map[string]Analysis{"x": {CVEs: []AICVE{{ID: "CVE-2026-1"}, {ID: "CVE-2026-2"}, {ID: "CVE-2026-3"}}, At: time.Now()}})
	err := s.scoreCVEs(context.Background())
	if err == nil || strings.Count(err.Error(), "403") != 1 || !strings.Contains(err.Error(), "pour 3 CVE") {
		t.Errorf("%v", err)
	}
	aiCache.m, cveCache.m = nil, nil
}

// Le créneau d'évaluation : une seconde demande attend (et le dit), et abandonne avec son contexte.
func TestEvalSlot(t *testing.T) {
	ev := &Evaluator{cfg: &Config{}}
	release, err := ev.acquire(t.Context(), "la vérification des mises à jour", nil)
	if err != nil || ev.Busy() != "la vérification des mises à jour" {
		t.Fatal(err, ev.Busy())
	}
	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()
	var holder string
	if _, err := ev.acquire(ctx, "un site", func(h string) { holder = h }); err == nil || holder != "la vérification des mises à jour" {
		t.Errorf("attente : %v, %q", err, holder)
	}
	release()
	if r, err := ev.acquire(t.Context(), "un site", nil); err != nil {
		t.Error(err)
	} else {
		r()
	}
	if ev.Busy() != "" {
		t.Errorf("libéré : %q", ev.Busy())
	}
}

// Une seule vérification à la fois, marquée en cours avant de rendre la main.
func TestTryStartUpdates(t *testing.T) {
	if !tryStartUpdates() || tryStartUpdates() {
		t.Fatal("une seule vérification à la fois")
	}
	setPhase("lot %d/%d", 1, 2)
	if running, _, phase := updatesProgress(); !running || phase != "lot 1/2" {
		t.Errorf("%v %q", running, phase)
	}
	finishUpdates()
	if running, _, _ := updatesProgress(); running {
		t.Error("toujours en cours")
	}
	if clipRunes("ééé", 2) != "éé…" || clipRunes("ab", 2) != "ab" {
		t.Error("clipRunes")
	}
}

// La page dans ses états : vérification ratée (tableaux d'avant gardés), main qui a avancé, erreurs
// longues, aucune version connue ; pendant une vérification, l'avancement.
func TestUpdatesTemplateStates(t *testing.T) {
	s, _ := testServer(t)
	base := func() map[string]any {
		return map[string]any{"Nav": "updates", "Hour": 7, "Counts": map[string]int{"changed": 1, "inputs": 2, "major": 1}, "AIOn": true}
	}
	failed := base()
	failed["Error"], failed["Attempted"], failed["Checked"], failed["Head"], failed["HeadNow"] = "git ls-remote : exit 128", "il y a 5 min", "il y a 1 j", "abc1234", "def5678"
	failed["AIError"], failed["CVEError"] = strings.Repeat("m : HTTP 503 ; ", 40), "NVD : 403 Forbidden pour 3 CVE (CVE-1…)"
	failed["Inputs"] = []InputRow{{Name: "home-manager", MainRev: "a", NextRev: "b", Commits: -1}, {Name: "nixpkgs", Owner: "NixOS", Repo: "nixpkgs", MainRev: "a", NextRev: "b", Commits: -1, CommitsNote: "GitHub : 403",
		AI: &Analysis{Urgency: "urgent", Summary: "x"}}}
	empty := base()
	empty["CurError"] = "Versions en service illisibles"
	running := base()
	running["Running"], running["Started"], running["Phase"], running["Frag"] = true, "il y a 3 min", "notes des CVE 2/9", true
	for name, data := range map[string]map[string]any{"failed": failed, "empty": empty, "running": running} {
		var b strings.Builder
		if err := s.tmpl.ExecuteTemplate(&b, "updates", data); err != nil {
			t.Fatalf("%s : %v", name, err)
		}
		out := b.String()
		want := map[string][]string{
			"failed":  {"Vérification impossible", "dernière vérification réussie (il y a 1 j)", "abc1234 → def5678", "<details", "Notes des CVE incomplètes", "1 version changerait, 2 sources avanceraient", `title="dépôt hors GitHub`, `title="GitHub : 403"`, `aria-controls="ai-in-nixpkgs"`, `id="ai-in-nixpkgs"`, "/updates?watch"},
			"empty":   {"Aucune version connue : génération active illisible"},
			"running": {"démarrée il y a 3 min · notes des CVE 2/9", `hx-swap-oob="true"`, `hx-trigger="every 5s"`},
		}[name]
		for _, w := range want {
			if !strings.Contains(out, w) {
				t.Errorf("%s : manque %q", name, w)
			}
		}
		if name == "running" && (strings.Contains(out, "/updates?watch") || strings.Contains(out, "Vérification impossible")) {
			t.Errorf("running : guet ou erreur d'avant affichés")
		}
	}
}

// Mises à jour : le genre de changement, l'ordre (le plus important d'abord), les entrées du flake.
func TestUpdates(t *testing.T) {
	for a, want := range map[[2]string]string{{"4.39.28", "4.40.0"}: "minor", {"31.0.8", "32.0.0"}: "major", {"7.3", "7.3.4"}: "patch",
		{"10.5p1", "10.5p2"}: "patch", {"1.37.4", "1.37.4"}: "same", {"x", "y"}: "other"} {
		if got := versionChange(a[0], a[1]); got != want {
			t.Errorf("%s → %s : %s, attendu %s", a[0], a[1], got, want)
		}
	}
	cur := []InvItem{{ID: "services.nginx", Kind: "service", Pname: "nginx", Version: "1.30.6"}, {ID: "services.authelia.main", Kind: "service", Pname: "authelia", Version: "4.39.28"},
		{ID: "boot.kernel", Kind: "base", Pname: "linux", Version: "7.3"}, {ID: "services.old", Pname: "old", Version: "1"}}
	next := []InvItem{{ID: "services.nginx", Pname: "nginx", Version: "1.30.6"}, {ID: "services.authelia.main", Pname: "authelia", Version: "5.0.0", Changelog: "https://x"},
		{ID: "boot.kernel", Pname: "linux", Version: "7.3.4"}, {ID: "services.new", Pname: "new", Version: "2"}}
	rows := updateRows(cur, nil, next)
	got := []string{}
	for _, r := range rows {
		got = append(got, r.Name+":"+r.Change)
	}
	if strings.Join(got, " ") != "authelia:major linux:patch new:new old:gone nginx:same" || rows[0].Changelog != "https://x" {
		t.Errorf("lignes : %v", got)
	}
	old := []byte(`{"root":"root","nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs","secrets":"secrets","hm":["nixpkgs"]}},
		"nixpkgs":{"locked":{"type":"github","owner":"NixOS","repo":"nixpkgs","rev":"aaa","lastModified":1792800000}},"secrets":{"locked":{"rev":"s"}}}}`)
	neu := []byte(`{"root":"root","nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs","secrets":"secrets","hm":["nixpkgs"]}},
		"nixpkgs":{"locked":{"type":"github","owner":"NixOS","repo":"nixpkgs","rev":"bbb","lastModified":1793232000}},"secrets":{"locked":{"rev":"s"}}}}`)
	cur = append(cur, InvItem{ID: "input.nixpkgs", Kind: "input", Pname: "nixpkgs", Version: "aaa", LastModified: 1792800000})
	main := []InvItem{{ID: "input.nixpkgs", Kind: "input", Pname: "nixpkgs", Version: "aaa", LastModified: 1792800000}}
	next = append(next, InvItem{ID: "input.nixpkgs", Kind: "input", Pname: "nixpkgs", Version: "bbb", LastModified: 1793232000})
	in := inputRows(cur, main, next, old)
	if len(in) != 1 || in[0].Name != "nixpkgs" || !in[0].Changed() || in[0].Pending() || in[0].Compare() != "https://github.com/NixOS/nixpkgs/compare/aaa...bbb" {
		t.Errorf("entrées : %+v", in)
	}
	_ = neu
	if r := updateRows(cur, main, next); len(r) != 5 {
		t.Errorf("les entrées du flake ne sont pas des paquets : %d lignes", len(r))
	}
}

// Récapitulatif Discord : ce qui change, du plus important au moins important, et le lien.
func TestPostUpdates(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _ = json.NewDecoder(r.Body).Decode(&got) }))
	defer srv.Close()
	dir := t.TempDir()
	inv := filepath.Join(dir, "inv.json")
	_ = os.WriteFile(inv, []byte(`[{"id":"services.authelia.main","kind":"service","pname":"authelia","version":"4.39.28"},{"id":"boot.kernel","kind":"base","pname":"linux","version":"7.3"},{"id":"services.nginx","kind":"service","pname":"nginx","version":"1.30.6"}]`), 0o644)
	s := &Server{cfg: &Config{DiscordHook: srv.URL, Inventory: inv, Host: "admin.vpn.x"}}
	machineName = "think"
	s.postUpdates(t.Context(), updatesResult{Next: []InvItem{{ID: "services.authelia.main", Pname: "authelia", Version: "4.40.1"}, {ID: "boot.kernel", Pname: "linux", Version: "7.3.6"},
		{ID: "services.nginx", Pname: "nginx", Version: "1.30.6"}}, Inputs: []InputRow{{Name: "nixpkgs-stable", MainRev: "a", NextRev: "b", MainAt: 1792843200, NextAt: 1793275200, Commits: 412}}})
	msg, _ := got["content"].(string)
	t.Log("\n" + msg)
	for _, want := range []string{"**think** : 2 versions changeraient", "• **authelia** 4.39.28 → 4.40.1 (mineure)", "• **linux** 7.3 → 7.3.6 (correctif, redémarrage)", "source `nixpkgs-stable` : 24/10/2026 → 29/10/2026, 412 commits", "https://admin.vpn.x/updates"} {
		if !strings.Contains(msg, want) {
			t.Errorf("manque %q", want)
		}
	}
	if strings.Contains(msg, "nginx") {
		t.Error("un paquet à jour ne doit pas figurer")
	}
}

// Sans colonne « sur main » (vérification ancienne), la source vient de ce qui tourne.
func TestUpdateRowsSource(t *testing.T) {
	cur := []InvItem{{ID: "services.nginx", Kind: "service", Pname: "nginx", Version: "1.30.6", Source: "nixpkgs-stable"}}
	rows := updateRows(cur, nil, []InvItem{{ID: "services.nginx", Kind: "service", Pname: "nginx", Version: "1.30.6"}})
	if len(rows) != 1 || rows[0].Source != "nixpkgs-stable" || rows[0].Change != "same" {
		t.Errorf("%+v", rows)
	}
}

// Un dépôt GitHub pris par git compte comme GitHub (commits, lien Comparer).
func TestGithubRepo(t *testing.T) {
	for _, c := range []struct{ typ, owner, repo, url, wo, wr string }{
		{"github", "NixOS", "nixpkgs", "", "NixOS", "nixpkgs"},
		{"git", "", "", "https://github.com/sadjow/claude-code-nix", "sadjow", "claude-code-nix"},
		{"git", "", "", "https://github.com/a/b.git", "a", "b"},
		{"git", "", "", "https://gitlab.com/a/b", "", ""},
		{"path", "", "", "", "", ""},
	} {
		if o, r := githubRepo(c.typ, c.owner, c.repo, c.url); o != c.wo || r != c.wr {
			t.Errorf("%s %s : %s/%s", c.typ, c.url, o, r)
		}
	}
}

// Analyse par l'IA : la réponse rangée par paquet et gardée, une montée de version déjà analysée
// n'est plus redemandée ; le raisonnement court est demandé.
func TestAnalyze(t *testing.T) {
	var calls []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.URL.Path)
		var body struct {
			GenerationConfig map[string]any `json:"generationConfig"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if tc, _ := body.GenerationConfig["thinkingConfig"].(map[string]any); tc["thinkingLevel"] != "low" || r.Header.Get("x-goog-api-key") != "k" {
			t.Errorf("requête : %v", body.GenerationConfig)
		}
		answer := `[{"id":"services.openssh","urgency":"urgent","summary":"Corrige une faille.","cves":[{"id":"CVE-2026-1","severity":"high"}]}]`
		b, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": answer}}}}}})
		_, _ = w.Write(b)
	}))
	defer srv.Close()
	geminiBase = srv.URL
	aiCache.m, cveCache.m = nil, nil
	s := &Server{cfg: &Config{GeminiKey: "k", AIModel: "m", AIThinking: "low", StateDir: t.TempDir()}}
	rows := []UpdateRow{{ID: "services.openssh", Name: "openssh", Current: "10.5p1", Next: "10.6p1", Change: "minor"}, {ID: "services.nginx", Name: "nginx", Current: "1", Next: "1", Change: "same"}}
	if err := s.analyze(t.Context(), rows); err != nil {
		t.Fatal(err)
	}
	a, ok := s.analyses()[rows[0].analysisKey()]
	if !ok || a.ModelUrgency != "urgent" || a.Urgency != "conseille" || a.Model != "m" || len(a.CVEs) != 0 || a.Basis != "rien à lire" || len(calls) != 1 || !strings.Contains(calls[0], "/models/m:") {
		t.Errorf("analyse : %+v (appels %v)", a, calls)
	}
	_ = s.analyze(t.Context(), rows)
	if len(calls) != 1 {
		t.Error("une montée de version déjà analysée a été redemandée")
	}
	if o, r := repoOf("https://github.com/authelia/authelia/releases/tag/v4.39.28"); o != "authelia" || r != "authelia" {
		t.Errorf("dépôt : %s/%s", o, r)
	}
	if cmpVersions("v4.40.0", "4.39.28") != 1 || cmpVersions("10.6p1", "10.6p1") != 0 {
		t.Error("cmpVersions")
	}
}

// Un refus, ou pas de réponse à temps : une erreur claire, rien de gardé (retenté à la vérification
// suivante).
func TestAnalyzeErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/models/slow:") {
			time.Sleep(300 * time.Millisecond)
			return
		}
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"message":"quota"}}`))
	}))
	defer srv.Close()
	geminiBase, aiTimeout = srv.URL, 100*time.Millisecond
	defer func() { aiTimeout = 2 * time.Minute }()
	rows := []UpdateRow{{ID: "services.openssh", Name: "openssh", Current: "10.5p1", Next: "10.6p1", Change: "minor"}}
	for model, want := range map[string]string{"slow": "slow : pas de réponse", "busy": "busy : HTTP 429 quota"} {
		aiCache.m, cveCache.m = nil, nil
		s := &Server{cfg: &Config{GeminiKey: "k", AIModel: model, StateDir: t.TempDir()}}
		if err := s.analyze(t.Context(), rows); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s : %v", model, err)
		}
		if len(s.analyses()) != 0 {
			t.Errorf("%s : une analyse gardée malgré l'erreur", model)
		}
	}
}

func TestReleaseOf(t *testing.T) {
	rels := []Release{{Tag: "v5.8.9", URL: "u589"}, {Tag: "release-4.39.28", URL: "u43928"}, {Tag: "5.8", URL: "u58"}}
	for v, want := range map[string]string{"5.8.9": "u589", "4.39.28": "u43928", "5.8": "u58", "5.8.10": "", "5": ""} {
		if got := releaseOf(rels, v); got != want {
			t.Errorf("releaseOf(%q) = %q, want %q", v, got, want)
		}
	}
	if o, r := repoOf("https://www.openssh.com/releasenotes.html", "", "https://github.com/containers/podman/archive/v5.8.9.tar.gz"); o != "containers" || r != "podman" {
		t.Errorf("repoOf src = %s/%s", o, r)
	}
}

// Une entrée du flake : les titres de ses commits envoyés à Gemini (merges de PR par leur titre),
// une analyse gardée par couple de révisions.
func TestAnalyzeInputs(t *testing.T) {
	if commitTitle("Merge pull request #1 from a/b\n\nopenssl: 3.5.4 -> 3.5.5") != "openssl: 3.5.4 -> 3.5.5" ||
		commitTitle("Merge branch 'master' into staging-next") != "" || commitTitle("sops-nix: rename option\n\nbody") != "sops-nix: rename option" {
		t.Error("commitTitle")
	}
	var prompts []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Contents []struct {
				Parts []struct{ Text string } `json:"parts"`
			} `json:"contents"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		prompts = append(prompts, body.Contents[0].Parts[0].Text)
		answer := `[{"id":"sops-nix","urgency":"conseille","summary":"Option renommée.","breaking":true}]`
		b, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": answer}}}}}})
		_, _ = w.Write(b)
	}))
	defer srv.Close()
	geminiBase = srv.URL
	aiCache.m, cveCache.m = nil, nil
	cfg := &Config{GeminiKey: "k", AIModel: "m", StateDir: t.TempDir()}
	gh := &GitHub{cfg: cfg, cache: map[string]cacheItem{
		"titles:Mic92/sops-nix:aaa...bbb": {time.Now(), []string{"sops-install-secrets: rename option", "fix typo", "fix typo (#12)",
			"libsidplayfp: fix CVE-2026-1", "openssh: 10.5p1 -> 10.6p1", "linux_7_3: 7.3.1 -> 7.3.2", "nixos/openssh: new default", "nixos/tests/openssh: x", "nixos/varnish: drop", "openssl_3_6, curl: CVE fixes", "ci: bump",
			"[Backport release-26.05] glibc: patch CVE-2026-2", "[Backport release-26.05] openssh: 10.5p1 -> 10.6p1 (#5)", "chore: update claude-code to 2.1.312", "docs(readme): typo"}}}}
	closureNames = func(context.Context) (map[string]bool, error) {
		return map[string]bool{"sops-install-secrets": true, "openssh": true, "linux": true, "openssl": true, "curl": true, "glibc": true}, nil
	}
	s := &Server{cfg: cfg, gh: gh}
	inputs := []InputRow{{Name: "sops-nix", Owner: "Mic92", Repo: "sops-nix", ServiceRev: "aaa", MainRev: "aaa", NextRev: "bbb"},
		{Name: "stylix", Owner: "nix-community", Repo: "stylix", ServiceRev: "ccc", MainRev: "ccc", NextRev: "ccc"}}
	// openssh et linux changent de version (analysés à part) ; glibc est corrigé à version égale.
	rows := []UpdateRow{{Name: "openssh", Current: "10.5p1", Change: "minor"}, {Name: "linux", Current: "7.3.1", Change: "patch"},
		{Name: "glibc", Current: "2.42", Change: "same"}}
	if err := s.analyzeInputs(t.Context(), inputs, rows); err != nil {
		t.Fatal(err)
	}
	a, ok := s.analyses()[inputs[0].analysisKey()]
	if !ok || !a.Breaking || a.Urgency != "conseille" || a.Basis != "6 titres de commits sur 15" || len(prompts) != 1 ||
		!strings.HasSuffix(prompts[0], "sops-install-secrets: rename option\nfix typo\nnixos/openssh: new default\nopenssl_3_6, curl: CVE fixes\nglibc: patch CVE-2026-2\nchore: update claude-code to 2.1.312") {
		t.Errorf("analyse : %+v, prompts %q", a, prompts)
	}
	_ = s.analyzeInputs(t.Context(), inputs, rows)
	if len(prompts) != 1 {
		t.Error("une entrée déjà analysée a été redemandée")
	}
}

func TestTitleCVEs(t *testing.T) {
	got := mergeCVEs(titleCVEs([]string{"glibc: 2.42-100 -> 2.42-103; fixes CVE-2026-89092, CVE-2026-97399", "zlib: backport fix for CVE-2026-85091", "sqlite, sqlite-analyzer: 3.53.3 (CVE-2026-11822)", "make it CVE-2026-1111 safe"}),
		[]AICVE{{ID: "CVE-2026-89092", Severity: "high"}, {ID: "GHSA-99cj-7hg9-mp4m"}})
	want := []AICVE{{ID: "CVE-2026-89092", Severity: "high", Pkg: "glibc"}, {ID: "CVE-2026-97399", Pkg: "glibc"}, {ID: "CVE-2026-85091", Pkg: "zlib"}, {ID: "CVE-2026-11822", Pkg: "sqlite, sqlite-analyzer"},
		{ID: "CVE-2026-1111"}} // le GHSA du modèle, absent des titres, est inventé
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("CVE : %v", got)
	}
}

// Un module épinglé (update.sh et pinned.json) : sa dernière version, sans toucher au reste ; un
// script en échec, ou un pinned.json sans version, ne change rien.
func TestBumpPins(t *testing.T) {
	dir := t.TempDir()
	write := func(path, content string) {
		_ = os.MkdirAll(filepath.Dir(filepath.Join(dir, path)), 0o755)
		if err := os.WriteFile(filepath.Join(dir, path), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("modules/system/server/cloudflared/pinned.json", `{"version":"2026.10.4","hash":"h","vendorHash":"v"}`)
	write("modules/system/server/cloudflared/update.sh", `[ "$1" = --check ] && [ -n "$MY_FLAKE" ] && echo '{"name":"cloudflared","current":"2026.10.4","latest":"2026.10.5","url":""}'`)
	write("modules/user/broken/pinned.json", `{"version":"1.0"}`)
	write("modules/user/broken/update.sh", `exit 1`)
	write("modules/system/server/apps/update.sh", `echo '{"current":"x","latest":"y"}'`)
	ev := &Evaluator{cfg: &Config{}}
	ev.bumpPins(t.Context(), os.Environ(), dir)
	b, _ := os.ReadFile(filepath.Join(dir, "modules/system/server/cloudflared/pinned.json"))
	if string(b) != `{"hash":"h","vendorHash":"v","version":"2026.10.5"}` {
		t.Errorf("cloudflared : %s", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "modules/user/broken/pinned.json")); string(b) != `{"version":"1.0"}` {
		t.Errorf("en échec : %s", b)
	}
}

// Le niveau vient des CVE : exploitée, critique, ou grave par le réseau : urgent ; grave en local
// ou moyenne : conseillé ; faible : sans ; pas notée : la gravité annoncée. Sans CVE, l'IA au plus
// « conseillé ».
func TestRateUrgency(t *testing.T) {
	infos := map[string]CVEInfo{
		"CVE-1": {Score: 9.8}, "CVE-2": {Score: 7.5, Network: true}, "CVE-3": {Score: 7.8}, "CVE-4": {Score: 5.3, Network: true},
		"CVE-5": {Score: 2.1, Network: true}, "CVE-6": {Score: 3, KEV: true},
		// Pas encore notée, critique d'après l'avis du projet ; rejetée par NVD.
		"CVE-7": {Severity: "critical"}, "CVE-8": {Score: 9.8, Network: true, Rejected: true},
	}
	cve := func(id string) []AICVE { return []AICVE{{ID: id}} }
	for _, c := range []struct {
		model string
		cves  []AICVE
		want  string
	}{
		{"sans", cve("CVE-1"), "urgent"}, {"sans", cve("cve-2"), "urgent"}, {"urgent", cve("CVE-3"), "conseille"},
		{"urgent", cve("CVE-4"), "conseille"}, {"urgent", cve("CVE-5"), "sans"}, {"sans", cve("CVE-6"), "urgent"},
		{"sans", []AICVE{{ID: "CVE-9", Severity: "critical"}}, "conseille"}, {"urgent", []AICVE{{ID: "CVE-9", Severity: "high"}}, "conseille"},
		{"sans", cve("CVE-7"), "urgent"}, {"urgent", []AICVE{{ID: "CVE-9", Severity: "low"}}, "sans"}, {"urgent", cve("CVE-8"), "sans"},
		{"urgent", []AICVE{{ID: "CVE-5"}, {ID: "CVE-2"}}, "urgent"}, {"urgent", nil, "conseille"}, {"sans", nil, "sans"},
	} {
		if got := rateUrgency(c.model, c.cves, infos); got != c.want {
			t.Errorf("%s %v : %s, voulu %s", c.model, c.cves, got, c.want)
		}
	}
}

// La plus récente publiée : toutes sources et toutes branches, avec sa page quand une source la donne.
func TestPickLatest(t *testing.T) {
	rels := []Release{{Tag: "v6.1.4", URL: "u614"}, {Tag: "v5.8.10", URL: "u5810"}, {Tag: "v5.9.0-rc1", URL: "rc", Prerelease: true}, {Tag: "v5.8.9", URL: "u589"}}
	if l := pickLatest("5.8.9", filterReleases(rels, "5.8.8"), nil); l.Version != "6.1.4" || l.URL != "u614" {
		t.Errorf("podman : %+v", l)
	}
	if l := pickLatest("3.15.0", nil, []Candidate{{"3.15.1", "p"}, {"3.5.12", ""}}); l.Version != "3.15.1" || l.URL != "p" {
		t.Errorf("prometheus : %+v", l)
	}
	if l := pickLatest("", nil, nil); l.Version != "" {
		t.Errorf("rien : %+v", l)
	}
}

// La colonne Plus récente : ce que Nix donne de mieux (canal ou unstable), puis le projet s'il va
// plus loin.
func TestNixLatest(t *testing.T) {
	prom := UpdateRow{Current: "3.12.0", Next: "3.12.0", Unstable: "3.15.0", Latest: "3.15.1"}
	if prom.NixLatest() != "3.15.0" || !prom.FromUnstable() || !prom.ProjectAhead() || prom.Upper() != "3.15.1" {
		t.Errorf("prometheus : %s %v %v %s", prom.NixLatest(), prom.FromUnstable(), prom.ProjectAhead(), prom.Upper())
	}
	nix := UpdateRow{Current: "2.34.9", Next: "2.34.9", Unstable: "2.34.9", Latest: "2.35.4"}
	if nix.NixLatest() != "2.34.9" || nix.FromUnstable() || !nix.ProjectAhead() {
		t.Errorf("nix : %+v", nix)
	}
	cloudflared := UpdateRow{Current: "2026.10.4", Next: "2026.10.6", Unstable: "2026.10.1", Latest: "2026.10.6"}
	if cloudflared.NixLatest() != "2026.10.6" || cloudflared.FromUnstable() || cloudflared.ProjectAhead() || cloudflared.Behind() {
		t.Errorf("cloudflared : %+v", cloudflared)
	}
}

// L'état de chaque CVE : patchée en service (ne compte pas), corrigée par update (version,
// patch ou backport), ou seulement au-delà du canal (la ligne le signale).
func TestClassifyRow(t *testing.T) {
	infos := map[string]CVEInfo{"CVE-1": {Score: 9.8, Network: true}, "CVE-2": {Score: 8.1, Network: true}, "CVE-3": {Score: 5}}
	row := UpdateRow{Name: "podman", Current: "5.8.8", Next: "5.8.9", Latest: "5.8.10", Patches: []string{"CVE-1"}, NextPatches: []string{"CVE-4"}}
	a := Analysis{ModelUrgency: "urgent", CVEs: []AICVE{{ID: "CVE-1"}, {ID: "CVE-2", FixedIn: "5.8.10"}, {ID: "CVE-3", FixedIn: "5.8.9"}, {ID: "CVE-4"}, {ID: "CVE-5"}}}
	got := classifyRow(&row, a, map[string]bool{"CVE-5": true}, infos)
	var st []string
	for _, c := range got.CVEs {
		st = append(st, c.Status)
	}
	if strings.Join(st, " ") != "service channel update update update" || !row.Stuck || got.Urgency != "urgent" {
		t.Errorf("états %v, bloquée %v, niveau %s", st, row.Stuck, got.Urgency)
	}
	// Plus rien au-delà du canal : seule la 5.8.9 compte, CVE-1 est déjà patchée.
	row = UpdateRow{Name: "podman", Current: "5.8.8", Next: "5.8.9", Latest: "5.8.9", Patches: []string{"CVE-1"}}
	got = classifyRow(&row, Analysis{ModelUrgency: "urgent", CVEs: []AICVE{{ID: "CVE-1"}, {ID: "CVE-3"}}}, nil, infos)
	if row.Stuck || got.Urgency != "conseille" || got.CVEs[1].Status != "update" {
		t.Errorf("sans retard : %+v", got)
	}
	if !(UpdateRow{Current: "5.8.8", Next: "5.8.9", Latest: "5.8.10"}).Behind() || (UpdateRow{Current: "5.8.8", Next: "5.8.9", Latest: "5.8.9"}).Behind() {
		t.Error("Behind")
	}
}

func TestCVEID(t *testing.T) {
	for in, want := range map[string]string{"GHSA-99CJ-7HG9-MP4M": "GHSA-99cj-7hg9-mp4m", "ghsa-99cj-7hg9-mp4m": "GHSA-99cj-7hg9-mp4m", "cve-2026-1": "CVE-2026-1", " CVE-2026-2 ": "CVE-2026-2"} {
		if got := cveID(in); got != want {
			t.Errorf("cveID(%q) = %q", in, got)
		}
	}
}

// Un avis du dépôt touche encore la version en service : une version corrigée plus récente (ou
// aucune annoncée). Une CVE corrigée avant la version en service ne compte pas.
func TestAdvisoryOpen(t *testing.T) {
	for _, c := range []struct {
		patched string
		want    bool
	}{{"4.0.3, 3.4.7", false}, {"5.8.10", true}, {">= 6.0.1", true}, {"", false}, {"5.8.9", false}} {
		if got := advisoryAffects("5.8.9", 1, []advisoryVuln{{Patched: c.patched}}); got != c.want {
			t.Errorf("corrigée %q : %v", c.patched, got)
		}
	}
	// Corrigée sur deux branches : celle de la version en service est déjà atteinte.
	if advisoryAffects("5.8.9", 1, []advisoryVuln{{Patched: "v5.8.8"}, {Patched: "v6.1.3"}}) || !advisoryAffects("5.8.7", 1, []advisoryVuln{{Patched: "v5.8.8"}, {Patched: "v6.1.3"}}) {
		t.Error("deux branches")
	}
	row := UpdateRow{Current: "5.8.9", Next: "6.1.4"}
	got := classifyRow(&row, Analysis{ModelUrgency: "urgent", CVEs: []AICVE{{ID: "CVE-2022-27649", FixedIn: "4.0.3"}}}, nil, map[string]CVEInfo{"CVE-2022-27649": {Score: 7.5, Network: true}})
	if got.CVEs[0].Status != "service" || got.Urgency != "sans" {
		t.Errorf("vieille CVE : %+v", got)
	}
}

// Une CVE déjà corrigée dans la branche en service (relevée par le code) ne compte pas, même si
// l'IA la dit corrigée dans la version suivante.
func TestClassifyFixedInBranch(t *testing.T) {
	row := UpdateRow{Current: "5.8.9", Next: "6.1.4"}
	a := Analysis{ModelUrgency: "urgent", Fixed: []string{"CVE-2026-94603"}, CVEs: []AICVE{{ID: "cve-2026-94603", FixedIn: "6.1.3"}, {ID: "CVE-2026-5", FixedIn: "6.0.0"}}}
	got := classifyRow(&row, a, nil, map[string]CVEInfo{"CVE-2026-94603": {Score: 10, Network: true}, "CVE-2026-5": {Score: 5}})
	if got.CVEs[0].Status != "service" || got.CVEs[1].Status != "update" || got.Urgency != "conseille" {
		t.Errorf("%+v", got)
	}
}

// Les branches d'un projet : au premier numéro, ou au deuxième quand une suite plus ancienne reçoit
// encore des versions après la sortie d'une plus récente (nginx 1.28 à côté de 1.29).
func TestBranchDepth(t *testing.T) {
	d := func(s string) time.Time { t, _ := time.Parse("2006-01-02", s); return t }
	podman := []Release{{Tag: "v5.8.9", Published: d("2026-10-20")}, {Tag: "v6.1.4", Published: d("2026-10-22")}, {Tag: "v6.0.0", Published: d("2026-08-01")}, {Tag: "v5.8.0", Published: d("2026-06-01")}, {Tag: "v5.7.3", Published: d("2026-05-01")}}
	nginx := []Release{{Tag: "release-1.29.2", Published: d("2026-10-01")}, {Tag: "release-1.28.4", Published: d("2026-10-02")}, {Tag: "release-1.29.0", Published: d("2026-06-01")}, {Tag: "release-1.28.0", Published: d("2026-04-01")}}
	if branchDepth(podman) != 1 || branchDepth(nginx) != 2 {
		t.Errorf("podman %d, nginx %d", branchDepth(podman), branchDepth(nginx))
	}
	// 1.28.3 : corrigée en 1.29.1 et 1.28.4 ; sa branche (1.28) n'a pas encore le correctif.
	if !advisoryAffects("1.28.3", 2, []advisoryVuln{{Patched: "1.29.1"}, {Patched: "1.28.4"}}) || advisoryAffects("1.28.4", 2, []advisoryVuln{{Patched: "1.29.1"}, {Patched: "1.28.4"}}) {
		t.Error("branches au deuxième numéro")
	}
	// Au premier numéro, la 1.28.3 se croirait corrigée par… rien : 1.28.4 > 1.28.3 laisse ouvert,
	// mais une 1.27.9 corrigée la fermerait à tort.
	if advisoryAffects("1.28.3", 1, []advisoryVuln{{Patched: "1.27.9"}, {Patched: "1.28.4"}}) == advisoryAffects("1.28.3", 2, []advisoryVuln{{Patched: "1.27.9"}, {Patched: "1.28.4"}}) {
		t.Error("la profondeur ne change rien")
	}
}

// endoflife.date : la branche d'une version (son nom en est le début), le dépôt GitHub d'un purl.
func TestEOLProduct(t *testing.T) {
	var p eolProduct
	_ = json.Unmarshal([]byte(`{"releases":[{"name":"7.3","isMaintained":true,"latest":{"name":"7.3.4"}},{"name":"7.2","isMaintained":false,"eolFrom":"2026-09-01","latest":{"name":"7.2.13"}},{"name":"17","isMaintained":true}],
		"identifiers":[{"type":"cpe","id":"cpe:x"},{"type":"purl","id":"pkg:github/nginx/nginx"}]}`), &p)
	if c := p.cycleOf("7.2.11"); c == nil || c.Name != "7.2" || c.Maintained {
		t.Errorf("7.2.11 : %+v", c)
	}
	if c := p.cycleOf("7.3"); c == nil || c.Name != "7.3" {
		t.Errorf("7.3 : %+v", c)
	}
	if c := p.cycleOf("17.11"); c == nil || c.Name != "17" {
		t.Errorf("17.11 : %+v", c)
	}
	if p.cycleOf("7.30.1") != nil || p.repo() != "https://github.com/nginx/nginx" {
		t.Errorf("7.30.1, dépôt %s", p.repo())
	}
}

// Les intervalles d'un avis : une faille introduite après la version en service ne la touche pas ;
// un intervalle illisible laisse trancher les versions corrigées.
func TestAdvisoryRanges(t *testing.T) {
	for _, c := range []struct {
		current string
		vulns   []advisoryVuln
		want    bool
	}{
		{"5.8.9", []advisoryVuln{{Range: ">= 6.0.0, < 6.1.3", Patched: "6.1.3"}}, false},
		{"6.1.2", []advisoryVuln{{Range: ">= 6.0.0, < 6.1.3", Patched: "6.1.3"}}, true},
		{"5.8.3", []advisoryVuln{{Range: ">= v1.8.1, <= v5.8.3", Patched: "v5.8.4"}, {Range: "< v6.0.0", Patched: "v6.0.0"}}, true},
		{"5.8.9", []advisoryVuln{{Range: ">= v1.8.1, <= v5.8.3", Patched: "v5.8.4"}, {Range: "< v6.0.0", Patched: "v6.0.0"}}, false},
		{"5.8.9", []advisoryVuln{{Range: "None", Patched: ""}}, false},
		{"1.30.6", []advisoryVuln{{Range: "= 1.30.6", Patched: "1.30.7"}}, true},
		// grafana : plusieurs intervalles sans virgule ; borne basse seule, sans version corrigée ;
		// intervalle trop large, versions corrigées toutes anciennes.
		{"9.3.2", []advisoryVuln{{Range: ">=9.2.0 <9.2.10 >=9.3.0 <9.3.4", Patched: "9.3.4"}}, true},
		{"9.2.12", []advisoryVuln{{Range: ">=9.2.0 <9.2.10 >=9.3.0 <9.3.4", Patched: "9.3.4"}}, false},
		{"13.0.11", []advisoryVuln{{Range: ">=8.1"}}, false},
		{"13.0.11", []advisoryVuln{{Range: ">=v3.0-beta1", Patched: "8.3.5, 7.5.15"}}, false},
	} {
		if got := advisoryAffects(c.current, 1, c.vulns); got != c.want {
			t.Errorf("%s %v : %v", c.current, c.vulns, got)
		}
	}
	if in, ok := inRange(">= 4.4.0, < 5.8.8", "5.8.7"); !in || !ok {
		t.Error("inRange")
	}
	if in, ok := inRange("None", "1.0"); in || ok {
		t.Error("inRange")
	}
}

// Le relevé du code : préversions et tags d'autres choses (chartes Helm) écartés, de la plus ancienne
// à la plus récente ; la page de notes coupée à la version en service.
func TestFilterReleasesAndChangelog(t *testing.T) {
	rels := []Release{{Tag: "v3.7.9"}, {Tag: "helm-loki-6.1.0"}, {Tag: "v3.8.0-rc1", Prerelease: true}, {Tag: "v3.7.8"}, {Tag: "helm-loki-6.0.9"}}
	var got []string
	for _, r := range filterReleases(rels, "3.7.8") {
		got = append(got, r.Tag)
	}
	if strings.Join(got, " ") != "v3.7.8 v3.7.9" {
		t.Errorf("loki : %v", got)
	}
	page := "OpenSSH 10.7 (2026-11-01)\nfixes CVE-2026-0003\nOpenSSH 10.6/10.6p1 (2026-10-01)\nfixes CVE-2026-0002\nOpenSSH 10.5/10.5p1 (2026-04-01)\nfixes cve-2026-0001\n"
	newer, older := changelogSlice(page, "10.5p1", "10.6p1")
	if !strings.Contains(newer, "CVE-2026-0002") || strings.Contains(newer, "0001") || fmt.Sprint(cveIDsIn(older)) != "[CVE-2026-0001]" {
		t.Errorf("page : %q / %q", newer, older)
	}
}

// La fusion : les CVE du code (avec leurs versions), celles de l'IA présentes dans les textes ; une
// inventée saute, un GHSA dont la CVE est là aussi.
func TestMergeFound(t *testing.T) {
	n := notesResult{Text: "## v6.1.3\nfix CVE-2026-0001\nGHSA-aaaa-bbbb-cccc", Found: map[string][]string{"CVE-2026-0001": {"6.1.3"}}}
	model := []AICVE{{ID: "cve-2026-0001", Severity: "high", FixedIn: "6.0"}, {ID: "CVE-2026-9999", Severity: "critical"}, {ID: "GHSA-AAAA-BBBB-CCCC"}}
	got := mergeFound(n, model, map[string]CVEInfo{"GHSA-aaaa-bbbb-cccc": {Alias: "CVE-2026-0001"}})
	if len(got) != 1 || got[0].ID != "CVE-2026-0001" || got[0].FixedIn != "6.1.3" || got[0].Severity != "high" {
		t.Errorf("%+v", got)
	}
}

// Version corrigée par branche : la branche de la version d'abord ; d'autres branches seules ne
// disent rien.
func TestFixedFor(t *testing.T) {
	for _, c := range []struct {
		versions     []string
		ref          string
		depth        int
		fixed, known bool
	}{
		{[]string{"5.8.8", "6.1.3"}, "5.8.9", 1, true, true},
		{[]string{"5.8.8", "6.1.3"}, "6.1.2", 1, false, true},
		{[]string{"1.31.2"}, "1.30.6", 2, false, true},
		{[]string{"1.28.4", "1.31.2"}, "1.30.6", 2, false, false},
		{[]string{"4.0.3"}, "5.8.9", 1, true, true},
		{nil, "5.8.9", 1, false, false},
	} {
		if f, k := fixedFor(c.versions, c.ref, c.depth); f != c.fixed || k != c.known {
			t.Errorf("%v / %s : %v %v", c.versions, c.ref, f, k)
		}
	}
}

// Fin de vie : une mention, sauf si une faille n'est corrigée que dans une autre branche.
func TestEOLAlert(t *testing.T) {
	infos := map[string]CVEInfo{"CVE-1": {Score: 7.5, Network: true}}
	row := UpdateRow{Current: "3.12.0", Next: "3.12.0", EOL: EOLInfo{Ended: true, Cycle: "3.12"}}
	_ = classifyRow(&row, Analysis{}, nil, infos)
	if row.EOLAlert() {
		t.Error("sans faille : pas d'alerte")
	}
	_ = classifyRow(&row, Analysis{Depth: 2, CVEs: []AICVE{{ID: "CVE-1", FixedIn: "3.15.1"}}}, nil, infos)
	if !row.EOLAlert() {
		t.Error("faille corrigée seulement en 3.15 : alerte")
	}
}
