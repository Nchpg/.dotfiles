package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSSHLog(t *testing.T) {
	t0 := time.Date(2026, 10, 28, 8, 18, 43, 0, time.UTC)
	lines := []string{
		"Accepted publickey for nchpg from 10.8.0.3 port 57842 ssh2: ED25519 SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE",
		"Accepted publickey for nchpg from 10.8.0.2 port 40000 ssh2: RSA SHA256:autre",
		"Connection closed by authenticating user nchpg 10.8.0.5 port 51000 [preauth]",
		"Connection closed by invalid user admin 192.168.1.20 port 52000 [preauth]",
		"Disconnected from invalid user root 192.168.1.20 port 52001 [preauth]",
		"Invalid user admin from 192.168.1.20 port 52000",
		"pam_unix(sshd:session): session opened for user nchpg(uid=1000) by (uid=0)",
	}
	var events []sshEvent
	for i, l := range lines {
		if e, ok := parseSSHLine(t0.Add(-time.Duration(i)*time.Hour), l); ok {
			events = append(events, e)
		}
	}
	if len(events) != 5 {
		t.Fatalf("%d événements, attendu 5 (« Invalid user » et pam ne comptent pas) : %+v", len(events), events)
	}
	sessions := []SSHSession{{User: "nchpg", IP: "10.8.0.3", Since: t0.Add(time.Second)}, {User: "nchpg", IP: "10.8.0.9", Since: t0}}
	a := summarize(events, sessions)
	u := a.Uses["SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE"]
	if u == nil || u.Count != 1 || u.LastIP != "10.8.0.3" || !u.Last.Equal(t0) {
		t.Errorf("usage : %+v", u)
	}
	if a.Sessions[0].Fingerprint != "SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE" || a.Sessions[1].Fingerprint != "" {
		t.Errorf("sessions : %+v", a.Sessions)
	}
	if len(a.Refusals) != 2 || a.Refusals[0].IP != "10.8.0.5" || a.Refusals[1].Count != 2 || len(a.Refusals[1].Users) != 2 {
		t.Errorf("refus : %+v %+v", a.Refusals[0], a.Refusals[len(a.Refusals)-1])
	}
	for v, want := range map[string]time.Duration{"30d": 30 * 24 * time.Hour, "720h": 720 * time.Hour, "n'importe": 30 * 24 * time.Hour} {
		if got := retention(v); got != want {
			t.Errorf("retention(%s) = %s", v, got)
		}
	}
}

// Visites : des pages d'affilée (même site, IP et navigateur, moins de 30 min d'écart).
func TestVisitsOf(t *testing.T) {
	t0 := time.Date(2026, 10, 28, 10, 0, 0, 0, time.UTC)
	l := func(min int, ip, ua string) visitLine {
		return visitLine{At: t0.Add(time.Duration(min) * time.Minute), Site: "cloud.x", IP: ip, UA: ua, Via: "vpn"}
	}
	v := visitsOf([]visitLine{l(0, "a", "ff"), l(10, "a", "ff"), l(35, "a", "ff"), l(80, "a", "ff"), l(5, "a", "chrome"), l(5, "b", "ff")})
	if len(v) != 4 {
		t.Fatalf("%d visites, attendu 4 : %+v", len(v), v)
	}
	if label, detail := origin("vpn", "10.8.0.3", "", "", map[string]string{"10.8.0.3": "gram"}); label != "gram" || detail != "VPN · 10.8.0.3" {
		t.Errorf("origine VPN : %s, %s", label, detail)
	}
	if label, _ := origin("public", "1.2.3.4", "Lyon", "France", nil); label != "Lyon, France" {
		t.Errorf("origine publique : %s", label)
	}
	if viaOf("10.8.0.3", "10.8.0.0/24") != "vpn" || viaOf("192.168.1.2", "10.8.0.0/24") != "lan" || viaOf("8.8.8.8", "10.8.0.0/24") != "public" {
		t.Error("viaOf")
	}
	if m := reVWFail.FindStringSubmatch("[2026-10-27][ERROR] Username or password is incorrect. Try again. IP: 10.8.0.3. Username: n@x.fr."); m == nil || m[1] != "10.8.0.3" || m[2] != "n@x.fr" {
		t.Errorf("échec Vaultwarden : %q", m)
	}
}

// Carte : un point par lieu et par sorte ; un appareil du VPN se place par son IP publique.
func TestTrafficMap(t *testing.T) {
	lat, lon := 45.76, 4.83
	g := geoPlaces{s: &Server{cfg: &Config{}}, devices: map[string]string{"10.8.0.3": "gram"}, endpoints: map[string]string{}}
	d := g.visitDots([]Visit{{Via: "public", IP: "1.2.3.4", City: "Lyon", Country: "France", Lat: &lat, Lon: &lon},
		{Via: "public", IP: "1.2.3.5", City: "Lyon", Country: "France", Lat: &lat, Lon: &lon}, {Via: "vpn", IP: "10.8.0.3"}, {Via: "lan", IP: "192.168.1.2"}})
	if len(d) != 1 || d[0].X != 184.8 || d[0].Y != 117.4 || d[0].Kind != "internet" || d[0].Title != "Lyon, France : 2 visites" {
		t.Errorf("carte : %+v", d)
	}
	vpn := mapDots([]mapPoint{{Lat: lat, Lon: lon, Label: "gram (VPN, Lyon)", Kind: "vpn"}}, "visite", "visites")
	if len(vpn) != 1 || vpn[0].Kind != "vpn" || vpn[0].Title != "gram (VPN, Lyon) : 1 visite" {
		t.Errorf("VPN : %+v", vpn)
	}
	if viaOf("172.16.3.4", "10.8.0.0/24") != "lan" || viaOf("::1", "10.8.0.0/24") != "machine" {
		t.Error("viaOf")
	}
}

// Localisation avec la vraie base, si on la donne (ADMIN_GEOIP=…/dbip-city-lite.mmdb go test).
func TestGeo(t *testing.T) {
	path := os.Getenv("ADMIN_GEOIP")
	if path == "" {
		t.Skip("ADMIN_GEOIP absent")
	}
	s := &Server{cfg: &Config{GeoIP: path}}
	if g := s.geo("8.8.8.8"); !g.OK || g.Country == "" {
		t.Errorf("8.8.8.8 : %+v", g)
	}
	if g := s.geo("10.8.0.3"); g.OK {
		t.Errorf("adresse privée localisée : %+v", g)
	}
}

// Trafic par site : les environnements d'un site ensemble, les sites les plus visités d'abord.
func TestGroupTraffic(t *testing.T) {
	g := groupTraffic([]TrafficRow{{Name: "nextcloud", Label: "production", Domain: "cloud.x", Visits: 1}, {Name: "myetf", Label: "production", Domain: "etf.x", Visits: 2},
		{Name: "myetf", Label: "preview", Domain: "etf-prev.x", Visits: 3}, {Name: "grafana", Label: "production", Domain: "metrics.x"}})
	if len(g) != 3 || g[0].Visits != 5 || len(g[0].Rows) != 2 || !g[0].Rows[0].First || g[0].Rows[0].Span != 2 || g[0].Rows[1].First {
		t.Errorf("groupes : %+v", g)
	}
}

// Info-bulle d'un point : les sites visités depuis ce lieu, les plus visités d'abord.
func TestMapDotSites(t *testing.T) {
	p := func(site string) mapPoint {
		return mapPoint{Lat: 45.76, Lon: 4.83, Label: "Lyon, France", Kind: "internet", Site: site}
	}
	d := mapDots([]mapPoint{p("etf.x"), p("cloud.x"), p("cloud.x")}, "visite", "visites")
	if len(d) != 1 || d[0].Count != "3 visites" || len(d[0].Sites) != 2 || d[0].Sites[0] != (SiteHit{"cloud.x", 2}) || d[0].Sites[1] != (SiteHit{"etf.x", 1}) {
		t.Errorf("point : %+v", d)
	}
}

// Une visite listée : quand, combien de temps, avec quel navigateur.
func TestVisitItem(t *testing.T) {
	start := time.Date(2026, 10, 28, 14, 5, 0, 0, time.Local)
	it := visitItem(Visit{Start: start, End: start.Add(27 * time.Minute), Pages: 4, UA: "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"})
	if it.When != "mer. 28/10 · 14:05 → 14:32" || it.Duration != "27 min" || it.Browser != "Firefox, Linux" {
		t.Errorf("visite : %+v", it)
	}
	if b := browserOf("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36"); b != "Chrome, Android" {
		t.Errorf("navigateur : %s", b)
	}
	if one := visitItem(Visit{Start: start, End: start, Pages: 1}); one.When != "mer. 28/10 · 14:05" || one.Duration != "" {
		t.Errorf("une page : %+v", one)
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

// Analyse par l'IA : la réponse rangée par paquet et gardée ; le secours si le modèle refuse ; une
// montée de version déjà analysée n'est plus redemandée.
func TestAnalyze(t *testing.T) {
	var calls []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.URL.Path)
		if strings.Contains(r.URL.Path, "/models/m1:") {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"error":{"message":"quota"}}`))
			return
		}
		if r.Header.Get("x-goog-api-key") != "k" {
			t.Error("clé absente")
		}
		answer := `[{"id":"services.openssh","urgency":"urgent","summary":"Corrige une faille.","cves":[{"id":"CVE-2026-1","severity":"high"}]}]`
		b, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": answer}}}}}})
		_, _ = w.Write(b)
	}))
	defer srv.Close()
	geminiBase = srv.URL
	aiCache.m = nil
	s := &Server{cfg: &Config{GeminiKey: "k", AIModel: "m1", AIFallback: "m2", StateDir: t.TempDir()}}
	rows := []UpdateRow{{ID: "services.openssh", Name: "openssh", Current: "10.5p1", Next: "10.6p1", Change: "minor"}, {ID: "services.nginx", Name: "nginx", Current: "1", Next: "1", Change: "same"}}
	if err := s.analyze(t.Context(), rows); err != nil {
		t.Fatal(err)
	}
	a, ok := s.analyses()[analysisKey("openssh", "10.5p1", "10.6p1")]
	if !ok || a.Urgency != "urgent" || a.Model != "m2" || len(a.CVEs) != 1 || a.Basis != "rien à lire" || !strings.Contains(a.Fallback, "429") {
		t.Errorf("analyse : %+v (appels %v)", a, calls)
	}
	// Faite par le secours : retentée avec le principal seul (qui refuse encore : on la garde).
	n := len(calls)
	_ = s.analyze(t.Context(), rows)
	if len(calls) != n+1 || !strings.Contains(calls[n], "/models/m1:") || s.analyses()[analysisKey("openssh", "10.5p1", "10.6p1")].Model != "m2" {
		t.Errorf("nouvel essai : %v", calls[n:])
	}
	// Son refus est gardé sur l'analyse, pour que la page dise pourquoi.
	if f := s.analyses()[analysisKey("openssh", "10.5p1", "10.6p1")].Fallback; !strings.Contains(f, "m1") || !strings.Contains(f, "429") {
		t.Errorf("raison du refus non gardée : %q", f)
	}
	// Le principal répond : son analyse remplace celle du secours, et plus rien n'est redemandé.
	s.cfg.AIModel = "m3"
	_ = s.analyze(t.Context(), rows)
	if a := s.analyses()[analysisKey("openssh", "10.5p1", "10.6p1")]; a.Model != "m3" || a.Fallback != "" {
		t.Errorf("après le principal : %+v", a)
	}
	n = len(calls)
	_ = s.analyze(t.Context(), rows)
	if len(calls) != n {
		t.Error("une montée de version déjà analysée par le principal a été redemandée")
	}
	if o, r := repoOf("https://github.com/authelia/authelia/releases/tag/v4.39.28"); o != "authelia" || r != "authelia" {
		t.Errorf("dépôt : %s/%s", o, r)
	}
	if cmpVersions("v4.40.0", "4.39.28") != 1 || cmpVersions("10.6p1", "10.6p1") != 0 {
		t.Error("cmpVersions")
	}
}

// Un modèle qui ne répond pas à temps : le secours, en le disant ; et le raisonnement court demandé.
func TestAnalyzeTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			GenerationConfig map[string]any `json:"generationConfig"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if tc, _ := body.GenerationConfig["thinkingConfig"].(map[string]any); tc["thinkingLevel"] != "low" {
			t.Errorf("raisonnement : %v", body.GenerationConfig["thinkingConfig"])
		}
		if strings.Contains(r.URL.Path, "/models/slow:") {
			time.Sleep(300 * time.Millisecond)
			return
		}
		answer := `[{"id":"services.openssh","urgency":"conseille","summary":"Bugs."}]`
		b, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": answer}}}}}})
		_, _ = w.Write(b)
	}))
	defer srv.Close()
	geminiBase, aiTimeout = srv.URL, 100*time.Millisecond
	defer func() { aiTimeout = 2 * time.Minute }()
	aiCache.m = nil
	s := &Server{cfg: &Config{GeminiKey: "k", AIModel: "slow", AIFallback: "fast", AIThinking: "low", StateDir: t.TempDir()}}
	if err := s.analyze(t.Context(), []UpdateRow{{ID: "services.openssh", Name: "openssh", Current: "10.5p1", Next: "10.6p1", Change: "minor"}}); err != nil {
		t.Fatal(err)
	}
	if a := s.analyses()[analysisKey("openssh", "10.5p1", "10.6p1")]; a.Model != "fast" || !strings.Contains(a.Fallback, "slow : pas de réponse") {
		t.Errorf("%+v", a)
	}
}
