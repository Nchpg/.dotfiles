package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// Empreinte d'une clé SSH : la même que `ssh-keygen -lf`.
func TestSSHKeyRow(t *testing.T) {
	key := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtpLQKGuQttRPNQTdMOjLpx1kn5oM94wj97klIh5Upf nchpg@gram"
	row := sshKeyRow("nchpg", key)
	want := SSHKeyRow{User: "nchpg", Type: "ed25519", Comment: "nchpg@gram", Fingerprint: "SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE", Key: key}
	if row != want {
		t.Errorf("%+v, attendu %+v", row, want)
	}
}

// Config cliente : les mêmes lignes que `wg-new-peer` (DNS seulement s'il y en a).
func TestWGClientConf(t *testing.T) {
	v := VPNInfo{Endpoint: "vpn.exemple.fr:51820", AllowedIPs: []string{"10.8.0.0/24"}}
	conf := wgClientConf("PRIV", "10.8.0.9", v, "SERVPUB", "PSK")
	for _, line := range []string{"PrivateKey = PRIV", "Address = 10.8.0.9/32", "PublicKey = SERVPUB", "PresharedKey = PSK", "Endpoint = vpn.exemple.fr:51820", "AllowedIPs = 10.8.0.0/24", "PersistentKeepalive = 25"} {
		if !strings.Contains(conf, line+"\n") {
			t.Errorf("ligne absente : %q\n%s", line, conf)
		}
	}
	if strings.Contains(conf, "DNS") {
		t.Errorf("DNS sans résolveur configuré :\n%s", conf)
	}
	v.DNS = []string{"10.8.0.1"}
	if !strings.Contains(wgClientConf("P", "10.8.0.9", v, "S", "K"), "DNS = 10.8.0.1\n") {
		t.Error("DNS absent")
	}
}

// Prochaine adresse : la première libre, serveur, appareils et appareils en attente exclus.
func TestNextAddress(t *testing.T) {
	s := &Server{cfg: &Config{VPN: VPNInfo{Subnet: "10.8.0.0/24", ServerAddress: "10.8.0.1", Peers: []VPNPeer{{Address: "10.8.0.2"}, {Address: "10.8.0.4"}}}}}
	if got, err := s.nextAddress(nil); err != nil || got != "10.8.0.3" {
		t.Errorf("%q %v, attendu 10.8.0.3", got, err)
	}
	if got, _ := s.nextAddress([]VPNPeer{{Address: "10.8.0.3"}}); got != "10.8.0.5" {
		t.Errorf("%q, attendu 10.8.0.5 (10.8.0.3 en attente)", got)
	}
}

// Les trois pages se rendent avec des données réalistes.
func TestInfraTemplates(t *testing.T) {
	s, _ := testServer(t)
	last := "2026-10-23 21:09:00"
	pages := map[string]map[string]any{
		"vpn": {"Nav": "vpn", "Rows": []PeerRow{{VPNPeer: VPNPeer{Name: "gram", Address: "10.8.0.3", PublicKey: "/gV7axgKpUvtPD/oEnbgC4CFpvRULEMAmGVekD4B/zI=", Services: []string{"admin"}}, Connected: true, Received: "1 Mo", Sent: "2 Mo"},
			{VPNPeer: VPNPeer{Name: "pixel", Address: "10.8.0.9", PublicKey: "AyLyEp/YhPJaLNMwIfyZibWt6XymReCgVUXLLQ6JqXs=", Added: true}, Pending: true}}, "Connected": 1, "Total": 1, "Endpoint": "vpn:51820", "Subnet": "10.8.0.0/24"},
		"vpn-new": {"Nav": "vpn", "Address": "10.8.0.9", "Services": []VPNService{{Name: "admin", Label: "Dashboard admin", Host: "admin.vpn"}}, "Checked": map[string]bool{"admin": true}},
		"vpn-access": {"Nav": "vpn", "Peer": VPNPeer{Name: "gram", Address: "10.8.0.3", Added: true}, "Services": []VPNService{{Name: "vaultwarden", Label: "Vaultwarden", Host: "vault.vpn"}}, "Checked": map[string]bool{},
			"Sites": []AccessSite{{Site: "myetf", App: "myetf", Domain: "etf.vpn", On: true}, {Site: "myetf", Env: "staging", App: "myetf-staging", Inherited: true, From: "production"}}, "Self": true, "Lock": "vaultwarden", "Pending": true, "Token": "t"},
		"vpn-added-replay": {"Nav": "vpn", "Name": "pixel", "Replay": true},
		"vpn-added":        {"Nav": "vpn", "Name": "pixel", "Address": "10.8.0.9", "Conf": "[Interface]\n", "QR": qrSVG(t.Context(), "x"), "Download": "data:text/plain;base64,eA==", "Secret": "wireguard:\n  pixel_preshared_key: K", "SecretKey": "wireguard/pixel_preshared_key"},
		"ssh":              {"Nav": "ssh", "Rows": []SSHKeyRow{{User: "nchpg", Type: "ed25519", Comment: "nchpg@gram", Fingerprint: "SHA256:x"}}},
		"ssh-new":          {"Nav": "ssh", "User": "nchpg", "Users": []string{"nchpg"}, "Device": "pixel", "Ready": true, "Comment": "nchpg@pixel", "Line": "ssh-ed25519 AAAA nchpg@pixel", "Info": SSHInfo{Port: 3249, Host: "10.8.0.1", Files: []string{"profiles/server/default.nix"}}, "Fingerprint": "SHA256:x", "Added": true},
		"account-new":      {"Nav": "accounts", "Name": "marie", "Snippet": "marie:", "Secret": "authelia/users", "Portal": "auth.x", "Granted": true, "GrantedServices": []string{"nextcloud"}, "SSO": true, "Track": &Track{ID: "x", Label: "Accès de marie", State: "running"}},
		"accounts":         {"Nav": "accounts", "Rows": []AccountRow{{Account: Account{Name: "nathan", Email: "n@x", Groups: []string{"admins"}, TOTP: true, LastLogin: &last}, Last: "il y a 2 h", Services: []string{"admin"}, Sites: []string{"myetf-preview"}}, {Account: Account{Name: "marie"}, Pending: true, Services: []string{"nextcloud"}}}, "Notice": "rien à changer", "Error": "x", "MainError": "y", "SummaryError": "z"},
		"account-new-form": {"Nav": "accounts", "Services": []VPNService{{Name: "admin", Label: "A"}}, "Checked": map[string]bool{}, "SSO": true, "MainError": "main", "Token": "t"},
		"account-removed":  {"Nav": "accounts", "Name": "olivier", "Secret": "authelia/users", "Track": &Track{ID: "x", Label: "Accès", State: "done", SHA: "abc1234"}},
		"account-access": {"Nav": "accounts", "Name": "olivier", "Services": []VPNService{{Name: "nextcloud", Label: "Nextcloud", Host: "cloud"}}, "Checked": map[string]bool{"nextcloud": true},
			"Sites": []AccessSite{{Site: "myetf", Env: "preview", App: "myetf-preview", Domain: "etf-prev", On: true}}, "Self": true},
		"traffic": {"Nav": "traffic", "Services": []TrafficRow{{Name: "nextcloud", Domain: "cloud.x", Link: "/traffic/cloud.x?p=7j", Access: "VPN", Visits: 3, Last: "il y a 2 min"}},
			"Groups": []TrafficGroup{{Rows: []TrafficRow{{Name: "myetf", Label: "production", Branch: "main", Repo: "Nchpg/myetf", Domain: "etf.x", Access: "internet", SSO: true, First: true, Span: 2, Probed: true, Up: true}, {Name: "myetf", Env: "preview", Label: "preview", Domain: "etf-prev.x", Access: "internet"}}}}, "Sites": 3,
			"Logins": []*LoginService{{ID: "nextcloud", Name: "Nextcloud", Domains: []string{"cloud.x"}, OK: 2, Failed: 1, Accounts: []string{"bob"}, Last: "hier", Link: "/traffic/connexions/nextcloud?p=7j"}},
			"Period": "7j", "Periods": []Opt{{Value: "7j", Label: "7j", Selected: true}}, "Total": 3, "Visited": 1, "OK": 2, "Failed": 1,
			"Dots": []MapDot{{X: 184.8, Y: 38.2, R: 2.5, Title: "Lyon, France : 1 visite", Kind: "internet"}, {X: 182, Y: 36, R: 3, Title: "gram (VPN, Lyon) : 2 visites", Kind: "vpn"}}, "LogsOK": true, "Complete": true},
		"traffic-site": {"Nav": "traffic", "Target": &TrafficRow{Name: "nextcloud", Domain: "cloud.x", Access: "VPN"}, "Period": "24h", "Periods": []Opt{{Value: "24h", Label: "24h", Selected: true}}, "Visits": 2, "Pages": 5, "Bars": []Bar{{Label: "10h", Visits: 2, Height: 100}},
			"Dots": []MapDot{}, "Origins": []*OriginRow{{Label: "gram", Detail: "VPN · 10.8.0.3", Via: "VPN", Visits: 2, Pages: 5, Last: "il y a 1 h", Items: []VisitItem{{When: "mar. 28/10 · 14:05 → 14:32", Duration: "27 min", Browser: "Firefox, Linux", Pages: 4, SSO: "nathan"}}, More: 3}}, "Accounts": []*CountRow{{Name: "nathan", Count: 2}}, "Paths": []*CountRow{{Name: "/apps/files/", Count: 4}},
			"Login": &LoginService{ID: "nextcloud", Name: "Nextcloud", OK: 1, Link: "/traffic/connexions/nextcloud?p=24h"}, "LogsOK": true, "Complete": false},
		"updates": {"Nav": "updates", "Rows": []UpdateRow{{ID: "boot.kernel", Name: "linux", Kind: "base", Source: "nixpkgs-stable", Current: "7.3", Main: "7.3", Next: "7.3.4", Change: "patch", ChangeLabel: "correctif", Running: "7.2.9",
			AI: &Analysis{Urgency: "urgent", Summary: "Corrige une faille.", CVEs: []AICVE{{ID: "CVE-2026-1", Severity: "high"}}, Basis: "notes GitHub", Model: "m"}},
			{ID: "services.authelia.main", Name: "authelia", Current: "4.39.28", Next: "4.40.0", Change: "minor", ChangeLabel: "mineure", Changelog: "https://x"}, {ID: "services.nginx", Name: "nginx", Current: "1.30.6", Main: "1.30.6", Next: "1.30.6", Change: "same", ChangeLabel: "à jour"}},
			"Inputs": []InputRow{{Name: "nixpkgs-stable", Owner: "NixOS", Repo: "nixpkgs", ServiceRev: "aaaaaaa1", MainRev: "bbbbbbb2", NextRev: "ccccccc3", ServiceAt: 1792800000, MainAt: 1792900000, NextAt: 1793232000, Commits: 412}, {Name: "stylix", ServiceRev: "d", MainRev: "d", NextRev: "d", Commits: -1}}, "Counts": map[string]int{"changed": 2, "minor": 1, "patch": 1},
			"Checked": "il y a 2 h", "Head": "abc1234", "Hour": 7, "Discord": true, "Running": true, "AIOn": false, "AIKey": "admin/gemini_key", "AIError": "m : quota"},
		"traffic-logins": {"Nav": "traffic", "Service": &LoginService{ID: "nextcloud", Name: "Nextcloud", Domains: []string{"cloud.x"}, OK: 1, Failed: 1, Accounts: []string{"bob"}}, "Period": "7j", "Periods": []Opt{{Value: "7j", Label: "7j", Selected: true}},
			"Rows": []*CountRow{{Name: "bob", Detail: "Lyon, France", Sub: "1.2.3.4", Failed: 1, Last: "hier"}}, "Connected": []*CountRow{{Name: "nathan", Detail: "gram (Desktop Client - Linux)"}},
			"Sessions": []*CountRow{}, "Syncs": []*CountRow{{Name: "nathan", Detail: "Nextcloud bureau", Sub: "gram · VPN · 10.8.0.3", Count: 300}}, "Dots": []MapDot{}},
	}
	for name, data := range pages {
		var buf bytes.Buffer
		if err := s.tmpl.ExecuteTemplate(&buf, strings.TrimSuffix(strings.TrimSuffix(name, "-replay"), "-form"), data); err != nil {
			t.Errorf("%s : %v", name, err)
		}
	}
}

// Comptes d'un site : toujours nommés ; aucun coché, liste vide (refusée).
func TestAccountsFromForm(t *testing.T) {
	all := []string{"nathan", "olivier"}
	if got := accountsFromForm([]string{"olivier", "nathan"}, all); !slices.Equal(got, all) {
		t.Errorf("tous cochés : %v, attendu la liste entière", got)
	}
	if got := accountsFromForm([]string{"nathan", "intrus"}, all); !slices.Equal(got, []string{"nathan"}) {
		t.Errorf("un coché : %v", got)
	}
	if got := accountsFromForm(nil, all); got == nil || len(got) != 0 {
		t.Errorf("aucun coché : %v, attendu []", got)
	}
	if errs := validateAccounts("", true, []string{}); len(errs) != 1 {
		t.Errorf("liste vide acceptée")
	}
	if errs := validateAccounts("preview : ", false, []string{"nathan"}); len(errs) != 1 {
		t.Errorf("comptes sans Authelia acceptés")
	}
	if errs := validateAccounts("", true, nil); len(errs) != 1 {
		t.Errorf("Authelia sans liste acceptée")
	}
	if errs := validateAccounts("", false, nil); errs != nil {
		t.Errorf("sans Authelia : %v", errs)
	}
}

func TestParseSQLiteTime(t *testing.T) {
	for _, v := range []string{"2026-10-23 21:09:00", "2026-10-23 21:09:00.123456+02:00", "2026-10-23T21:09:00Z"} {
		if _, ok := parseSQLiteTime(v); !ok {
			t.Errorf("%q illisible", v)
		}
	}
}

// Adresse choisie : dans le réseau, ni serveur, ni réservée, ni déjà prise (en attente compris).
func TestCheckAddress(t *testing.T) {
	s := &Server{cfg: &Config{VPN: VPNInfo{Subnet: "10.8.0.0/24", ServerAddress: "10.8.0.1", Peers: []VPNPeer{{Name: "gram", Address: "10.8.0.3"}}}}}
	pending := []VPNPeer{{Name: "pixel", Address: "10.8.0.9"}}
	for addr, ok := range map[string]bool{"10.8.0.20": true, "10.8.0.1": false, "10.8.0.3": false, "10.8.0.9": false, "10.8.0.0": false, "10.8.0.255": false, "10.9.0.5": false, "10.8.0.020": false, "pixel": false, "": false} {
		if err := s.checkAddress(addr, pending); (err == nil) != ok {
			t.Errorf("%q : %v", addr, err)
		}
	}
}

// Joignable par le tunnel : le nom doit résoudre dans le réseau du VPN.
func TestViaTunnel(t *testing.T) {
	s := &Server{cfg: &Config{VPN: VPNInfo{Subnet: "10.8.0.0/24", ServerAddress: "10.8.0.1"}}}
	if ok, known := s.viaTunnel("localhost"); !known || ok {
		t.Errorf("localhost : ok=%v known=%v, attendu hors tunnel", ok, known)
	}
	s.cfg.VPN.Subnet = "127.0.0.0/8"
	tunnelCache.Lock()
	delete(tunnelCache.m, "localhost")
	tunnelCache.Unlock()
	if ok, _ := s.viaTunnel("localhost"); !ok {
		t.Error("localhost dans 127.0.0.0/8 : attendu joignable")
	}
	if _, known := (&Server{cfg: &Config{}}).viaTunnel("localhost"); known {
		t.Error("sans VPN configuré : rien ne doit être affirmé")
	}
}

// Redémarrage : noyau, initrd ou modules différents entre le système démarré et l'actif.
func TestRebootOf(t *testing.T) {
	dir := t.TempDir()
	mk := func(root, kernel, initrd string) string {
		p := filepath.Join(dir, root)
		_ = os.MkdirAll(p, 0o755)
		_ = os.Symlink("/nix/store/aaa-linux-"+kernel+"/bzImage", filepath.Join(p, "kernel"))
		_ = os.Symlink("/nix/store/bbb-initrd-linux-"+kernel+"/"+initrd, filepath.Join(p, "initrd"))
		_ = os.Symlink("/nix/store/ccc-linux-"+kernel+"-modules", filepath.Join(p, "kernel-modules"))
		return p
	}
	same, other := mk("a", "7.2.7", "initrd"), mk("b", "7.2.7", "initrd")
	if r := rebootOf(same, other); r != nil {
		t.Errorf("même noyau : %+v", r)
	}
	if r := rebootOf(same, mk("c", "7.3.1", "initrd")); r == nil || r.Booted != "7.2.7" || r.Current != "7.3.1" {
		t.Errorf("noyau changé : %+v", r)
	}
	if r := rebootOf(same, mk("c", "7.3.1", "initrd")); r == nil || !strings.HasPrefix(r.Text(), "noyau 7.3.1 installé, 7.2.7") {
		t.Errorf("noyau changé : %v", r)
	}
	if r := rebootOf(same, mk("d", "7.2.7", "initrd2")); r == nil {
		t.Errorf("initrd changé : pas de redémarrage demandé")
	} else if !slices.Equal(r.Parts, []string{"initrd"}) || !strings.Contains(r.Text(), "même noyau 7.2.7, mais initrd changés") {
		t.Errorf("initrd seul : %+v, %q", r, r.Text())
	}
}

// Clés SSH : même ordre d'un rendu à l'autre (connectées, puis par compte, hors liste en dernier).
func TestSortKeyRows(t *testing.T) {
	rows := []SSHKeyRow{{Fingerprint: "z", Unknown: true}, {User: "b", Comment: "x"}, {User: "a", Comment: "y"}, {User: "b", Comment: "a", Connected: true}, {Fingerprint: "c", Unknown: true}}
	sortKeyRows(rows)
	var got []string
	for _, r := range rows {
		got = append(got, r.User+r.Comment+r.Fingerprint)
	}
	if want := []string{"ba", "ay", "bx", "c", "z"}; !slices.Equal(got, want) {
		t.Errorf("%v, attendu %v", got, want)
	}
}

// Accès : seuls les sites avec leur propre accès dont la case change ; services connus seulement.
func TestAccessChanges(t *testing.T) {
	sites := []AccessSite{{Site: "a", App: "a", On: true}, {Site: "b", App: "b"}, {Site: "c", Env: "preview", App: "c-preview", Inherited: true}}
	got := siteChanges([]string{"b", "c-preview"}, sites)
	if want := []siteAccess{{"a", "", false}, {"b", "", true}}; !slices.Equal(got, want) {
		t.Errorf("changements : %v, attendu %v", got, want)
	}
	if got := siteChanges([]string{"a"}, sites); len(got) != 0 {
		t.Errorf("rien de changé : %v", got)
	}
	services, checked := checkedServices([]string{"admin", "intrus"}, []VPNService{{Name: "admin"}, {Name: "vault"}})
	if !slices.Equal(services, []string{"admin"}) || !checked["admin"] || checked["intrus"] {
		t.Errorf("services : %v %v", services, checked)
	}
	if s, _ := checkedServices(nil, nil); s == nil {
		t.Error("aucun service : attendu [] (pas null dans le JSON)")
	}
	if !sameSet([]string{"b", "a"}, []string{"a", "b", "a"}) || sameSet([]string{"a"}, nil) {
		t.Error("sameSet")
	}
}

// Abréviation : coupe sans paniquer, même sur une clé vide ou courte.
func TestAbbrev(t *testing.T) {
	for in, want := range map[string]string{"": "", "abc": "abc", "abcdefghijkl": "abcdefghij…", "éèàçùéèàçùé": "éèàçùéèàçù…"} {
		if got := abbrev(in, 10); got != want {
			t.Errorf("%q : %q, attendu %q", in, got, want)
		}
	}
}

// Jeton de formulaire : vu une fois servi ; inconnu (ou vide) sinon.
func TestFormSeen(t *testing.T) {
	if _, seen := formSeen(""); seen {
		t.Error("jeton vide vu")
	}
	tok := formToken()
	if _, seen := formSeen(tok); seen {
		t.Error("jeton neuf vu")
	}
	forms.Lock()
	forms.used[tok] = formUse{id: "abc"}
	forms.Unlock()
	if id, seen := formSeen(tok); !seen || id != "abc" {
		t.Errorf("jeton servi : %q %v", id, seen)
	}
}

// Page Accès depuis l'appareil qui s'en sert : le dashboard coché, grisé, et envoyé quand même ; deux
// formulaires, deux jetons (un retour arrière ne prend pas l'un pour l'autre).
func TestAccessLockAndTokens(t *testing.T) {
	s, _ := testServer(t)
	var buf bytes.Buffer
	data := map[string]any{"Nav": "vpn", "Peer": VPNPeer{Name: "gram", Address: "10.8.0.3", Added: true}, "Services": []VPNService{{Name: "admin", Label: "Dashboard"}}, "Checked": map[string]bool{}, "Lock": "admin", "Token": "T"}
	if err := s.tmpl.ExecuteTemplate(&buf, "vpn-access", data); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, want := range []string{`<input type="hidden" name="service" value="admin">`, `value="admin" checked disabled`, `name="token" value="T"`, `name="token" value="T-retrait"`} {
		if !strings.Contains(out, want) {
			t.Errorf("absent : %s", want)
		}
	}
}

// État du tunnel lu à l'exportateur : format texte de Prometheus, étiquettes entre guillemets.
func TestWireguardLive(t *testing.T) {
	body := `# HELP wireguard_latest_handshake_seconds Seconds from the last handshake
# TYPE wireguard_latest_handshake_seconds gauge
wireguard_latest_handshake_seconds{interface="wg0",public_key="abc+/=",allowed_ips="10.8.0.2/32",friendly_name="tel \"pro\"",remote_ip="203.0.113.7",remote_port="51820"} 1794470000
wireguard_received_bytes_total{interface="wg0",public_key="abc+/="} 1.5e+06
wireguard_sent_bytes_total{interface="wg0",public_key="abc+/="} 42 1794470000000
go_goroutines 9
cassée{public_key="x
`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
	defer srv.Close()
	s := &Server{cfg: &Config{WGExporter: srv.URL, Prometheus: "http://127.0.0.1:1"}}
	m, err := s.wireguard(context.Background())
	if err != nil || m.Handshake["abc+/="] != 1794470000 || m.Remote["abc+/="] != "203.0.113.7" || m.Received["abc+/="] != 1.5e6 || m.Sent["abc+/="] != 42 {
		t.Errorf("exportateur : %+v, %v", m, err)
	}
	if _, labels, _, ok := parseMetricLine(`m{a="x\"y",b="z"} 1`); !ok || labels["a"] != `x"y` || labels["b"] != "z" {
		t.Errorf("étiquettes : %v", labels)
	}
	// Exportateur muet : Prometheus prend le relais (ici injoignable aussi : l'erreur remonte).
	s.cfg.WGExporter = "http://127.0.0.1:1"
	if _, err := s.wireguard(context.Background()); err == nil {
		t.Error("ni exportateur ni Prometheus : une erreur attendue")
	}
}
