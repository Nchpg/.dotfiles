package main

import (
	"os"
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
