package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Graphe des visites : toutes les visites de la période tombent dans une colonne (la première est
// entamée), le total est celui de « Visites ».
func TestBarsCoverPeriod(t *testing.T) {
	now := time.Date(2026, 11, 10, 11, 36, 0, 0, time.Local)
	for _, c := range []struct {
		period time.Duration
		n      int
	}{{24 * time.Hour, 25}, {7 * 24 * time.Hour, 8}, {30 * 24 * time.Hour, 31}} {
		from := now.Add(-c.period)
		visits := []Visit{{Start: from}, {Start: from.Add(time.Minute)}, {Start: now.Add(-time.Minute)}, {Start: now}}
		b := bars(visits, c.period, now)
		if len(b) != c.n {
			t.Errorf("%v : %d colonnes, attendu %d", c.period, len(b), c.n)
		}
		total := 0
		for _, x := range b {
			total += x.Visits
		}
		if total != len(visits) || b[0].Visits != 2 || b[len(b)-1].Visits != 2 {
			t.Errorf("%v : %+v", c.period, b)
		}
		if b[0].From != from.Format("15:04") || b[1].From != "" { // 30 j : peut passer un changement d'heure
			t.Errorf("%v : première colonne entamée %q, deuxième %q", c.period, b[0].From, b[1].From)
		}
	}
}

// Loki par pages : les lignes de l'instant où une page s'arrête, relues par la suivante, ne sont
// comptées qu'une fois.
func TestLokiRangeNoDuplicates(t *testing.T) {
	const total = lokiLimit + 2000
	type entry struct {
		ns   int64
		line string
	}
	var all []entry
	for i := range total {
		all = append(all, entry{int64(1_000_000 + i/3), fmt.Sprintf("l%d", i)}) // trois lignes par instant
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start, _ := strconv.ParseInt(r.URL.Query().Get("start"), 10, 64)
		end, _ := strconv.ParseInt(r.URL.Query().Get("end"), 10, 64)
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		var vals [][2]string
		for i := len(all) - 1; i >= 0 && len(vals) < limit; i-- { // les plus récentes d'abord, fin comprise
			if e := all[i]; e.ns >= start && e.ns <= end {
				vals = append(vals, [2]string{strconv.FormatInt(e.ns, 10), e.line})
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"result": []map[string]any{{"values": vals}}}})
	}))
	defer srv.Close()
	s := &Server{cfg: &Config{Loki: srv.URL}}
	out, complete, err := s.lokiRange(t.Context(), "{x=\"y\"}", time.Unix(0, 0), time.Unix(0, 2_000_000))
	if err != nil || !complete {
		t.Fatalf("%v, complet %v", err, complete)
	}
	seen := map[string]int{}
	for _, e := range out {
		seen[e.Line]++
	}
	if len(out) != total || len(seen) != total {
		t.Errorf("%d lignes (%d différentes), attendu %d", len(out), len(seen), total)
	}
}

// Authelia : un premier facteur suivi d'un second n'est pas une connexion de plus ; seul, il en est une.
func TestAutheliaLogins(t *testing.T) {
	t0 := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	ev := func(min int, user, ip, typ string, ok bool) autheliaEvent {
		return autheliaEvent{At: t0.Add(time.Duration(min) * time.Minute), User: user, IP: ip, Type: typ, OK: ok}
	}
	got := autheliaLogins([]autheliaEvent{
		ev(1, "nathan", "1.1.1.1", "TOTP", true), ev(0, "nathan", "1.1.1.1", "1FA", true), // deux facteurs, dans le désordre
		ev(10, "marie", "2.2.2.2", "1FA", true),  // un seul facteur
		ev(20, "bob", "3.3.3.3", "1FA", false),   // raté
		ev(30, "nathan", "1.1.1.1", "1FA", true), // second facteur trop tard
		ev(40, "nathan", "1.1.1.1", "TOTP", false),
	})
	var keys []string
	for _, e := range got {
		keys = append(keys, fmt.Sprintf("%s/%s/%v", e.User, e.Type, e.OK))
	}
	want := "nathan/TOTP/true marie/1FA/true bob/1FA/false nathan/1FA/true nathan/TOTP/false"
	if strings.Join(keys, " ") != want {
		t.Errorf("%v\nattendu %s", keys, want)
	}
}

func TestNextcloudClient(t *testing.T) {
	for name, want := range map[string]string{
		"Mozilla/5.0 (Linux) mirall/4.0.8 (Nextcloud, nixos-7.1.3 ClientArchitecture: x86_64)": "Client de bureau 4.0.8",
		"Mozilla/5.0 (Android) Nextcloud-android/3.30.1":                                       "Appli Android 3.30.1",
		"Mozilla/5.0 (iOS) Nextcloud-iOS/5.5.0":                                                "Appli iOS 5.5.0",
		"Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0":               "Firefox, Linux",
		"gram (Desktop Client - Linux)":                                                        "gram (Desktop Client - Linux)",
	} {
		label, raw := nextcloudClient(name)
		if label != want || (label != name) != (raw == name) {
			t.Errorf("%q : %q / %q, attendu %q", name, label, raw, want)
		}
	}
}

// Relevé d'admin-traffic : illisible ou en retard, une alerte ; à l'heure ou absent, rien.
func TestSummaryNote(t *testing.T) {
	now := time.Now()
	if n := summaryNote(trafficSummary{Updated: now.Add(-2 * time.Minute).Unix()}, nil, now); n != "" {
		t.Errorf("à l'heure : %q", n)
	}
	if n := summaryNote(trafficSummary{Updated: now.Add(-time.Hour).Unix()}, nil, now); !strings.Contains(n, "plus à jour") {
		t.Errorf("en retard : %q", n)
	}
	if n := summaryNote(trafficSummary{}, fmt.Errorf("x"), now); !strings.Contains(n, "illisible") {
		t.Errorf("illisible : %q", n)
	}
}

// visitsOf ne réordonne pas les lignes reçues (partagées par plusieurs pages).
func TestVisitsOfKeepsLines(t *testing.T) {
	t0 := time.Now()
	lines := []visitLine{{At: t0.Add(time.Minute), Site: "b", IP: "1"}, {At: t0, Site: "a", IP: "1"}, {At: t0.Add(2 * time.Minute), Site: "a", IP: "1"}}
	v := visitsOf(lines)
	if lines[0].Site != "b" || len(v) != 2 || v[0].Pages != 2 {
		t.Errorf("lignes %+v, visites %+v", lines, v)
	}
}

// Les pages du Trafic, avec ce que les autres tests ne montrent pas : visites repliées, origines en
// trop, colonne entamée, journaux illisibles, relevé daté.
func TestTrafficTemplatesDetail(t *testing.T) {
	s, _ := testServer(t)
	at := time.Now().Add(-3 * time.Minute)
	items := []VisitItem{{When: "mar. 10/11 · 09:00", Pages: 1, Route: []RouteStep{{Time: "09:00", Path: "/", N: 1}}}}
	pages := map[string]map[string]any{
		"traffic-site": {"Nav": "traffic", "Target": &TrafficRow{Name: "myetf", Label: "preview", Domain: "etf.x", Access: "internet", Manage: "/sites/myetf?env=preview"},
			"Period": "7j", "Periods": []Opt{{Value: "7j", Label: "7j", Selected: true}}, "Visits": 9, "Pages": 12,
			"Bars": []Bar{{Label: "03/11", Visits: 1, Height: 50, From: "11:36"}, {Label: "04/11", Visits: 2, Height: 100}}, "Dots": []MapDot{{Title: "Lyon, France : 1 visite", Kind: "internet"}},
			"Origins": []*OriginRow{{Label: "Lyon, France", Detail: "1.2.3.4", Via: "internet", Visits: 9, LastAt: at, Items: items, Older: items, More: 2}}, "OriginsMore": 5,
			"LogsOK": false, "Complete": true},
		"traffic-logins": {"Nav": "traffic", "Service": &LoginService{ID: "nextcloud", Name: "Nextcloud", Domains: []string{"cloud.x", "cloud.y"}}, "Period": "7j", "Periods": []Opt{},
			"Rows": []*CountRow{}, "Connected": []*CountRow{{Name: "nathan", Detail: "Client de bureau 4.0.8", Sub: "Mozilla/5.0 mirall/4.0.8", LastAt: at}}, "Sessions": []*CountRow{},
			"Blocked": []*CountRow{{Name: "Lyon, France", Sub: "1.2.3.4", Detail: "connexion · bob", LastAt: at}}, "Syncs": []*CountRow{}, "Dots": []MapDot{},
			"SummaryAt": at, "Notes": []string{"Relevé en retard"}, "LogsOK": true, "Complete": false, "CompleteText": "minorés"},
	}
	want := map[string][]string{
		"traffic-site":   {"myetf · preview", "Gérer le site", "/sites/myetf?env=preview", "(depuis 11:36)", "1 visite plus ancienne", "les 5 autres origines", "origines=all", "il y a 3 min", "Journal des visites illisible", "<li>Lyon, France : 1 visite</li>"},
		"traffic-logins": {"Essais freinés", "connexion · bob", "relevé il y a 3 min", "Relevé en retard", "minorés", "Client de bureau 4.0.8", "Mozilla/5.0 mirall/4.0.8"},
	}
	for name, data := range pages {
		var buf bytes.Buffer
		if err := s.tmpl.ExecuteTemplate(&buf, name, data); err != nil {
			t.Fatalf("%s : %v", name, err)
		}
		for _, w := range want[name] {
			if !strings.Contains(buf.String(), w) {
				t.Errorf("%s : %q absent", name, w)
			}
		}
	}
}

// Origines : les plus actives d'abord ; trois visites dépliées, les suivantes repliées.
func TestSortedOriginsSplit(t *testing.T) {
	t0 := time.Now()
	var vs []Visit
	for i := range 15 {
		vs = append(vs, Visit{Start: t0.Add(time.Duration(i) * time.Minute), End: t0.Add(time.Duration(i) * time.Minute), Pages: 1, Paths: []string{"/"}})
	}
	rows := sortedOrigins(map[string]*OriginRow{"a": {Visits: 15, visits: vs}, "b": {Visits: 1}})
	if rows[0].Visits != 15 || len(rows[0].Items) != visitShown || len(rows[0].Items)+len(rows[0].Older) != originMax || rows[0].More != 3 {
		t.Errorf("%d dépliées, %d repliées, %d de plus", len(rows[0].Items), len(rows[0].Older), rows[0].More)
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
	p := func(site string, paths ...string) mapPoint {
		return mapPoint{Lat: 45.76, Lon: 4.83, Label: "Lyon, France", Kind: "internet", Site: site, Paths: paths}
	}
	d := mapDots([]mapPoint{p("etf.x", "/"), p("cloud.x", "/login", "/apps"), p("cloud.x", "/login")}, "visite", "visites")
	if len(d) != 1 || d[0].Count != "3 visites" || len(d[0].Sites) != 2 {
		t.Fatalf("point : %+v", d)
	}
	c, e := d[0].Sites[0], d[0].Sites[1]
	if c.Domain != "cloud.x" || c.N != 2 || fmt.Sprint(c.Paths) != "[{/login 2} {/apps 1}]" || e.Domain != "etf.x" || e.N != 1 {
		t.Errorf("sites : %+v", d[0].Sites)
	}
}

// Une visite : ses pages les plus vues, et son parcours dans l'ordre (une page rechargée d'affilée
// comptée une fois, avec l'heure de la première).
func TestVisitRoute(t *testing.T) {
	t0 := time.Date(2026, 10, 29, 12, 50, 0, 0, time.Local)
	at := []time.Time{t0, t0.Add(time.Minute), t0.Add(2 * time.Minute), t0.Add(3 * time.Minute), t0.Add(4 * time.Minute)}
	it := visitItem(Visit{Start: t0, End: at[4], Pages: 5, Paths: []string{"/", "/cv", "/cv", "/", "/a"}, PathsAt: at})
	if fmt.Sprint(it.Route) != "[{12:50 / 1} {12:51 /cv 2} {12:53 / 1} {12:54 /a 1}]" {
		t.Errorf("parcours : %v", it.Route)
	}
	if fmt.Sprint(it.Top) != "[{/ 2} {/cv 2} {/a 1}]" || it.TopMore != 0 {
		t.Errorf("pages : %v +%d", it.Top, it.TopMore)
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
