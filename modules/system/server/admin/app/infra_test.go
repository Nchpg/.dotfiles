package main

import (
	"bytes"
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
			"Sites": []AccessSite{{Site: "myetf", App: "myetf", Domain: "etf.vpn", On: true}, {Site: "myetf", Env: "staging", App: "myetf-staging", Inherited: true, From: "production"}}, "Self": true},
		"vpn-added":   {"Nav": "vpn", "Name": "pixel", "Address": "10.8.0.9", "Conf": "[Interface]\n", "QR": qrSVG(t.Context(), "x"), "Download": "data:text/plain;base64,eA==", "Secret": "wireguard:\n  pixel_preshared_key: K", "SecretKey": "wireguard/pixel_preshared_key"},
		"ssh":         {"Nav": "ssh", "Rows": []SSHKeyRow{{User: "nchpg", Type: "ed25519", Comment: "nchpg@gram", Fingerprint: "SHA256:x"}}},
		"ssh-new":     {"Nav": "ssh", "User": "nchpg", "Users": []string{"nchpg"}, "Device": "pixel", "Ready": true, "Comment": "nchpg@pixel", "Line": "ssh-ed25519 AAAA nchpg@pixel", "Info": SSHInfo{Port: 3249, Host: "10.8.0.1", Files: []string{"profiles/server/default.nix"}}, "Fingerprint": "SHA256:x", "Added": true},
		"account-new": {"Nav": "accounts", "Name": "marie", "Snippet": "  marie:", "Secret": "authelia/users", "Portal": "auth.x"},
		"accounts":    {"Nav": "accounts", "Rows": []AccountRow{{Account: Account{Name: "nathan", Email: "n@x", Groups: []string{"admins"}, TOTP: true, LastLogin: &last}, Last: "il y a 2 h", Services: []string{"admin"}, Sites: []string{"myetf-preview"}}}},
		"account-access": {"Nav": "accounts", "Name": "olivier", "Services": []VPNService{{Name: "nextcloud", Label: "Nextcloud", Host: "cloud"}}, "Checked": map[string]bool{"nextcloud": true},
			"Sites": []AccessSite{{Site: "myetf", Env: "preview", App: "myetf-preview", Domain: "etf-prev", On: true}}, "Self": true},
	}
	for name, data := range pages {
		var buf bytes.Buffer
		if err := s.tmpl.ExecuteTemplate(&buf, name, data); err != nil {
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
