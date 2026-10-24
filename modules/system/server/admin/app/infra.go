package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Pages VPN, SSH et Comptes : lecture de ce que la config déclare (fichiers JSON du build) et de
// l'état vivant (Prometheus, résumé des comptes écrit par admin-accounts). Écritures par apps.yml :
// inscrire ou retirer un appareil VPN (`peer`, jamais autorisé sans son secret et un rebuild) et
// changer ses accès (`access` : services de think, sites en VPN).

// VPNInfo : paramètres du tunnel et appareils de la génération active (cf. `vpnInfo`, ../default.nix).
type VPNInfo struct {
	Endpoint      string    `json:"endpoint"`
	DNS           []string  `json:"dns"`
	AllowedIPs    []string  `json:"allowedIPs"`
	Subnet        string    `json:"subnet"`
	ServerAddress string    `json:"serverAddress"`
	Peers         []VPNPeer `json:"peers"`
	// Services de think réservés au VPN, ouverts appareil par appareil (admin, vaultwarden).
	Services []VPNService `json:"services"`
}

type VPNService struct {
	Name  string `json:"name"`
	Label string `json:"label"`
	Host  string `json:"host"`
}

type VPNPeer struct {
	Name      string   `json:"name"`
	Address   string   `json:"address"`
	PublicKey string   `json:"publicKey"`
	Services  []string `json:"services"`
	Added     bool     `json:"added"` // dans vpn-peers.json (géré depuis le dashboard)
}

// serviceLabel : le nom lisible d'un service de think (son identifiant s'il est inconnu).
func (v VPNInfo) serviceLabel(name string) string {
	for _, s := range v.Services {
		if s.Name == name {
			return s.Label
		}
	}
	return name
}

// requestDevice : l'appareil VPN d'où vient la requête (X-Real-IP posé par nginx), vide sinon.
func (s *Server) requestDevice(r *http.Request) string {
	ip := r.Header.Get("X-Real-IP")
	for _, p := range s.cfg.VPN.Peers {
		if ip != "" && p.Address == ip {
			return p.Name
		}
	}
	return ""
}

// SSHUser : clés autorisées d'un compte (cf. `sshInfo`).
type SSHUser struct {
	Name string   `json:"name"`
	Keys []string `json:"keys"`
}

// Account : résumé d'un compte Authelia (cf. `admin-accounts`), sans secret.
type Account struct {
	Name         string   `json:"name"`
	DisplayName  string   `json:"displayName"`
	Email        string   `json:"email"`
	Groups       []string `json:"groups"`
	Disabled     bool     `json:"disabled"`
	TOTP         bool     `json:"totp"`
	SecurityKeys int      `json:"securityKeys"`
	LastLogin    *string  `json:"lastLogin"`
	Failures24h  int      `json:"failures24h"`
}

const peersPath = "profiles/server/vpn-peers.json"

var reDeviceName = regexp.MustCompile(`^[a-z0-9_]{1,24}$`)

// promByKey : une requête Prometheus, valeur par étiquette `label`.
func (s *Server) promByKey(ctx context.Context, query, label string) map[string]float64 {
	m := map[string]float64{}
	for _, r := range s.promQuery(ctx, query) {
		if v, ok := r.Value[1].(string); ok {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				m[r.Metric[label]] = f
			}
		}
	}
	return m
}

// promLabel : une requête Prometheus, étiquette `value` par étiquette `key`.
func (s *Server) promLabel(ctx context.Context, query, key, value string) map[string]string {
	m := map[string]string{}
	for _, r := range s.promQuery(ctx, query) {
		m[r.Metric[key]] = r.Metric[value]
	}
	return m
}

type promSample struct {
	Metric map[string]string `json:"metric"`
	Value  [2]any            `json:"value"`
}

func (s *Server) promQuery(ctx context.Context, query string) []promSample {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", s.cfg.Prometheus+"/api/v1/query?query="+url.QueryEscape(query), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var out struct {
		Data struct {
			Result []promSample `json:"result"`
		} `json:"data"`
	}
	if json.NewDecoder(resp.Body).Decode(&out) != nil {
		return nil
	}
	return out.Data.Result
}

// ago : « à l'instant », « il y a 5 min », « il y a 3 h », « il y a 2 j ».
func ago(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "à l'instant"
	case d < time.Hour:
		return fmt.Sprintf("il y a %d min", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("il y a %d h", int(d.Hours()))
	default:
		return fmt.Sprintf("il y a %d j", int(d.Hours()/24))
	}
}

func humanBytes(b float64) string {
	units := []string{"o", "Ko", "Mo", "Go", "To"}
	i := 0
	for b >= 1024 && i < len(units)-1 {
		b /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s", b, units[i])
	}
	return fmt.Sprintf("%.1f %s", b, units[i])
}

// PeerRow : un appareil, son état vivant (poignée de main récente : connecté) et son trafic.
type PeerRow struct {
	VPNPeer
	Connected, Seen bool
	LastSeen        string
	RemoteIP        string   // IP publique d'où il se connecte (exporteur, withRemoteIp)
	Services, Sites []string // services de think et sites en VPN auxquels il a droit
	Received, Sent  string
	Pending         bool // inscrit sur main, pas encore actif (secret + rebuild à faire)
}

// pendingPeers : appareils de vpn-peers.json sur main qui ne sont pas dans la génération active.
func (s *Server) pendingPeers(ctx context.Context) []VPNPeer {
	head, err := s.gh.HeadCached(ctx)
	if err != nil {
		return nil
	}
	b, err := s.gh.File(ctx, head, peersPath)
	if err != nil {
		return nil
	}
	var file map[string]struct {
		PublicKey string   `json:"publicKey"`
		Address   string   `json:"address"`
		Services  []string `json:"services"`
	}
	if json.Unmarshal(b, &file) != nil {
		return nil
	}
	active := map[string]bool{}
	for _, p := range s.cfg.VPN.Peers {
		active[p.Name] = true
	}
	var out []VPNPeer
	for name, p := range file {
		if !active[name] {
			out = append(out, VPNPeer{Name: name, Address: p.Address, PublicKey: p.PublicKey, Services: p.Services, Added: true})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *Server) vpn(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	hs := s.promByKey(ctx, "wireguard_latest_handshake_seconds", "public_key")
	rx := s.promByKey(ctx, "wireguard_received_bytes_total", "public_key")
	tx := s.promByKey(ctx, "wireguard_sent_bytes_total", "public_key")
	remote := s.promLabel(ctx, "wireguard_latest_handshake_seconds", "public_key", "remote_ip")
	// Sites en VPN qui listent l'appareil (génération de main, lue en cache).
	sitesOf := map[string][]string{}
	if snap, err := s.snapshot(ctx); err == nil {
		for _, site := range snap.Apps.Names() {
			for _, d := range snap.Apps.Entries[site].Deploys(site) {
				if d.VPN() {
					for _, dev := range d.Access.Devices {
						sitesOf[dev] = append(sitesOf[dev], d.App)
					}
				}
			}
		}
	}
	var rows []PeerRow
	connected := 0
	for _, p := range s.cfg.VPN.Peers {
		row := PeerRow{VPNPeer: p, Received: humanBytes(rx[p.PublicKey]), Sent: humanBytes(tx[p.PublicKey]), RemoteIP: remote[p.PublicKey], Services: p.Services, Sites: sitesOf[p.Name]}
		if t := hs[p.PublicKey]; t > 0 {
			d := time.Since(time.Unix(int64(t), 0))
			// Un appareil actif refait sa poignée de main toutes les 2 minutes.
			row.Seen, row.Connected, row.LastSeen = true, d < 3*time.Minute, ago(d)
		}
		if row.Connected {
			connected++
		}
		rows = append(rows, row)
	}
	for _, p := range s.pendingPeers(ctx) {
		rows = append(rows, PeerRow{VPNPeer: p, Pending: true, Services: p.Services, Sites: sitesOf[p.Name]})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Connected && !rows[j].Connected })
	s.render(w, "vpn", map[string]any{"Nav": "vpn", "Rows": rows, "Connected": connected, "Total": len(s.cfg.VPN.Peers),
		"Endpoint": s.cfg.VPN.Endpoint, "Subnet": s.cfg.VPN.Subnet, "Error": r.URL.Query().Get("erreur")})
}

// nextAddress : la première adresse libre du /24 du tunnel (serveur et appareils exclus, ceux en
// attente compris).
func (s *Server) nextAddress(pending []VPNPeer) (string, error) {
	_, network, err := net.ParseCIDR(s.cfg.VPN.Subnet)
	if err != nil {
		return "", fmt.Errorf("sous-réseau %q illisible", s.cfg.VPN.Subnet)
	}
	used := map[string]bool{s.cfg.VPN.ServerAddress: true}
	for _, p := range append(append([]VPNPeer(nil), s.cfg.VPN.Peers...), pending...) {
		used[p.Address] = true
	}
	base := network.IP.To4()
	if base == nil {
		return "", fmt.Errorf("sous-réseau %q : IPv4 attendu", s.cfg.VPN.Subnet)
	}
	for i := 2; i < 255; i++ {
		ip := net.IPv4(base[0], base[1], base[2], byte(i)).String()
		if network.Contains(net.ParseIP(ip)) && !used[ip] {
			return ip, nil
		}
	}
	return "", fmt.Errorf("plus d'adresse libre dans %s", s.cfg.VPN.Subnet)
}

func (s *Server) vpnNew(w http.ResponseWriter, r *http.Request) {
	addr, err := s.nextAddress(s.pendingPeers(r.Context()))
	sites, _ := s.accessSites(r.Context(), "")
	s.render(w, "vpn-new", map[string]any{"Nav": "vpn", "Address": addr, "Error": errString(err), "Subnet": s.cfg.VPN.Subnet,
		"Services": s.cfg.VPN.Services, "Checked": map[string]bool{}, "Sites": sites})
}

// siteAccess : un site (ou environnement) où l'appareil entre (`on`) ou d'où il sort.
type siteAccess struct {
	Site string `json:"site"`
	Env  string `json:"env"`
	On   bool   `json:"on"`
}

// formSites : les sites en VPN avec leur propre accès, cochés (`on`) ou non (champ `site`).
func formSites(r *http.Request, sites []AccessSite) []AccessSite {
	out := make([]AccessSite, 0, len(sites))
	for _, a := range sites {
		if !a.Inherited {
			a.On = slices.Contains(r.Form["site"], a.App)
		}
		out = append(out, a)
	}
	return out
}

// formServices : les services cochés (champ `service`), seulement ceux que think connaît.
func (s *Server) formServices(r *http.Request) []string {
	var out []string
	for _, sv := range s.cfg.VPN.Services {
		if slices.Contains(r.Form["service"], sv.Name) {
			out = append(out, sv.Name)
		}
	}
	return out
}

// checkAddress : une adresse IPv4 du réseau du tunnel, ni celle du serveur, ni celle d'un autre
// appareil (en attente compris).
func (s *Server) checkAddress(addr string, pending []VPNPeer) error {
	ip := net.ParseIP(addr)
	_, network, err := net.ParseCIDR(s.cfg.VPN.Subnet)
	if ip == nil || ip.To4() == nil || err != nil || !network.Contains(ip) || addr != ip.String() {
		return fmt.Errorf("Adresse : une IPv4 de %s.", s.cfg.VPN.Subnet)
	}
	if ip.Equal(network.IP) || ip.To4()[3] == 255 {
		return fmt.Errorf("Adresse : %s est réservée (réseau ou diffusion).", addr)
	}
	if addr == s.cfg.VPN.ServerAddress {
		return fmt.Errorf("Adresse : %s est celle du serveur.", addr)
	}
	for _, p := range append(append([]VPNPeer(nil), s.cfg.VPN.Peers...), pending...) {
		if p.Address == addr {
			return fmt.Errorf("Adresse : %s est déjà celle de %s.", addr, p.Name)
		}
	}
	return nil
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// vpnCreate : clés générées ici (jamais écrites nulle part), appareil inscrit par apps.yml, puis
// une seule page qui montre la config (QR, fichier) et ce qu'il reste à faire sur think.
func (s *Server) vpnCreate(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := strings.TrimSpace(r.FormValue("name"))
	_ = r.ParseForm()
	services := s.formServices(r)
	checked := map[string]bool{}
	for _, sv := range services {
		checked[sv] = true
	}
	all, _ := s.accessSites(ctx, "")
	sites := formSites(r, all)
	fail := func(msg string) {
		s.render(w, "vpn-new", map[string]any{"Nav": "vpn", "Name": name, "Address": r.FormValue("address"), "Error": msg, "Subnet": s.cfg.VPN.Subnet,
			"Services": s.cfg.VPN.Services, "Checked": checked, "Sites": sites})
	}
	if !reDeviceName.MatchString(name) {
		fail("Nom : lettres minuscules, chiffres et _ (24 caractères au plus).")
		return
	}
	pending := s.pendingPeers(ctx)
	for _, p := range append(append([]VPNPeer(nil), s.cfg.VPN.Peers...), pending...) {
		if p.Name == name {
			fail("« " + name + " » existe déjà.")
			return
		}
	}
	addr := strings.TrimSpace(r.FormValue("address"))
	if err := s.checkAddress(addr, pending); err != nil {
		fail(err.Error())
		return
	}
	serverPub, err := os.ReadFile(s.cfg.WGPubkeyFile)
	if err != nil || len(bytes.TrimSpace(serverPub)) == 0 {
		fail("Clé publique du serveur illisible (" + s.cfg.WGPubkeyFile + ") : le service admin la dérive au démarrage.")
		return
	}
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		fail("génération des clés : " + err.Error())
		return
	}
	psk := make([]byte, 32)
	if _, err := rand.Read(psk); err != nil {
		fail("génération de la clé pré-partagée : " + err.Error())
		return
	}
	b64 := base64.StdEncoding.EncodeToString
	pub := b64(priv.PublicKey().Bytes())
	if services == nil {
		services = []string{}
	}
	on := []siteAccess{}
	for _, a := range sites {
		if a.On && !a.Inherited {
			on = append(on, siteAccess{a.Site, a.Env, true})
		}
	}
	entry, _ := json.Marshal(map[string]any{"publicKey": pub, "address": addr, "services": services, "sites": on})
	if err := s.gh.Dispatch(ctx, map[string]string{"action": "peer", "app": name, "entry": string(entry), "source": "dashboard"}); err != nil {
		fail("Inscription impossible (apps.yml) : " + err.Error())
		return
	}
	conf := wgClientConf(b64(priv.Bytes()), addr, s.cfg.VPN, strings.TrimSpace(string(serverPub)), b64(psk))
	s.render(w, "vpn-added", map[string]any{
		"Nav": "vpn", "Name": name, "Address": addr, "Conf": conf, "QR": qrSVG(ctx, conf),
		"Download":  "data:text/plain;base64," + b64([]byte(conf)),
		"Secret":    fmt.Sprintf("wireguard:\n  %s_preshared_key: %s", name, b64(psk)),
		"SecretKey": "wireguard/" + name + "_preshared_key",
	})
}

// wgClientConf : la même config que `wg-new-peer` (modules/system/server/vpn/wireguard).
func wgClientConf(private, address string, v VPNInfo, serverPub, psk string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[Interface]\nPrivateKey = %s\nAddress = %s/32\n", private, address)
	if len(v.DNS) > 0 {
		fmt.Fprintf(&b, "DNS = %s\n", strings.Join(v.DNS, ", "))
	}
	fmt.Fprintf(&b, "\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s\nAllowedIPs = %s\n", serverPub, psk, v.Endpoint, strings.Join(v.AllowedIPs, ", "))
	b.WriteString("# NAT opérateur : sans keepalive, le tunnel semble mort jusqu'à ce que l'appareil émette.\nPersistentKeepalive = 25\n")
	return b.String()
}

// qrSVG : le QR code de la config, dessiné par qrencode (vide s'il manque).
func qrSVG(ctx context.Context, text string) template.HTML {
	cmd := exec.CommandContext(ctx, "qrencode", "-t", "SVG", "-m", "1", "-o", "-")
	cmd.Stdin = strings.NewReader(text)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	if i := bytes.Index(out, []byte("<svg")); i >= 0 {
		out = out[i:]
	}
	return template.HTML(out)
}

// vpnRemove : retire un appareil de vpn-peers.json (et des listes des sites), par apps.yml.
func (s *Server) vpnRemove(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !reDeviceName.MatchString(name) {
		http.Error(w, "nom invalide", http.StatusBadRequest)
		return
	}
	known := false
	for _, p := range append(append([]VPNPeer(nil), s.cfg.VPN.Peers...), s.pendingPeers(r.Context())...) {
		known = known || (p.Name == name && p.Added)
	}
	if !known {
		http.Redirect(w, r, "/vpn?erreur="+url.QueryEscape(name+" n'est pas dans vpn-peers.json : il se retire dans vpn.nix."), http.StatusSeeOther)
		return
	}
	if name == s.requestDevice(r) {
		http.Redirect(w, r, "/vpn?erreur="+url.QueryEscape("Tu es connecté depuis "+name+" : le retirer te couperait le VPN. Fais-le depuis un autre appareil."), http.StatusSeeOther)
		return
	}
	if err := s.gh.Dispatch(r.Context(), map[string]string{"action": "peer", "app": name, "entry": "null", "source": "dashboard"}); err != nil {
		http.Redirect(w, r, "/vpn?erreur="+url.QueryEscape("Retrait impossible : "+err.Error()), http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/vpn?erreur="+url.QueryEscape(name+" : retrait demandé. Il reste autorisé jusqu'au prochain rebuild (après git pull)."), http.StatusSeeOther)
}

// AccessSite : un site (ou environnement) en VPN dans la page Accès d'un appareil. Inherited : il
// reprend l'accès de son parent, il se règle là-bas.
type AccessSite struct {
	Site, Env, App, Domain, From string
	On, Inherited                bool
}

// accessSites : les sites en VPN de main, et si l'appareil y est.
func (s *Server) accessSites(ctx context.Context, device string) ([]AccessSite, error) {
	snap, err := s.snapshot(ctx)
	if err != nil {
		return nil, err
	}
	var out []AccessSite
	for _, site := range snap.Apps.Names() {
		e := snap.Apps.Entries[site]
		for _, d := range e.Deploys(site) {
			if !d.VPN() {
				continue
			}
			a := AccessSite{Site: site, Env: d.ID, App: d.App, Domain: d.Domain(s.cfg.Domain), On: slices.Contains(d.Access.Devices, device)}
			if d.ID != "" && !e.Environments[d.ID].OwnAccess() {
				a.Inherited, a.From = true, e.labelOf(e.Environments[d.ID].From)
			}
			out = append(out, a)
		}
	}
	return out, nil
}

// peerByName : un appareil actif ou en attente.
func (s *Server) peerByName(ctx context.Context, name string) (VPNPeer, bool) {
	for _, p := range append(append([]VPNPeer(nil), s.cfg.VPN.Peers...), s.pendingPeers(ctx)...) {
		if p.Name == name {
			return p, true
		}
	}
	return VPNPeer{}, false
}

func (s *Server) vpnAccess(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	p, ok := s.peerByName(ctx, r.PathValue("name"))
	if !ok || !p.Added {
		http.NotFound(w, r)
		return
	}
	sites, err := s.accessSites(ctx, p.Name)
	checked := map[string]bool{}
	for _, sv := range p.Services {
		checked[sv] = true
	}
	s.render(w, "vpn-access", map[string]any{"Nav": "vpn", "Peer": p, "Services": s.cfg.VPN.Services, "Checked": checked,
		"Sites": sites, "Error": errString(err), "Self": p.Name == s.requestDevice(r)})
}

// vpnAccessSave : services cochés et sites cochés (ceux qui ont leur propre accès), en un commit.
func (s *Server) vpnAccessSave(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	p, ok := s.peerByName(ctx, r.PathValue("name"))
	if !ok || !p.Added {
		http.NotFound(w, r)
		return
	}
	back := func(msg string) {
		http.Redirect(w, r, "/vpn?erreur="+url.QueryEscape(msg), http.StatusSeeOther)
	}
	_ = r.ParseForm()
	services := s.formServices(r)
	if slices.Contains(p.Services, "admin") && !slices.Contains(services, "admin") && p.Name == s.requestDevice(r) {
		back("Tu es connecté depuis " + p.Name + " : lui retirer le dashboard te fermerait la page. Fais-le depuis un autre appareil.")
		return
	}
	sites, err := s.accessSites(ctx, p.Name)
	if err != nil {
		back("Sites illisibles : " + err.Error())
		return
	}
	changes := []siteAccess{}
	for _, a := range sites {
		on := slices.Contains(r.Form["site"], a.App)
		if !a.Inherited && on != a.On {
			changes = append(changes, siteAccess{a.Site, a.Env, on})
		}
	}
	if services == nil {
		services = []string{}
	}
	entry, _ := json.Marshal(map[string]any{"services": services, "sites": changes})
	if err := s.gh.Dispatch(ctx, map[string]string{"action": "access", "app": p.Name, "entry": string(entry), "source": "dashboard"}); err != nil {
		back("Changement impossible (apps.yml) : " + err.Error())
		return
	}
	msg := p.Name + " : accès enregistrés (commit dans la minute)."
	if !slices.Equal(sortedCopy(services), sortedCopy(p.Services)) {
		msg += " Services de think : au prochain rebuild (git pull, puis rebuild)."
	}
	if len(changes) > 0 {
		msg += " Sites : appliqués seuls, sauf si un rebuild est en attente."
	}
	back(msg)
}

func sortedCopy(v []string) []string {
	out := append([]string(nil), v...)
	sort.Strings(out)
	return out
}

// SSHKeyRow : une clé autorisée, son type, son commentaire et son empreinte (comme ssh-keygen -l).
type SSHKeyRow struct {
	User, Type, Comment, Fingerprint string
}

func sshKeyRow(user, key string) SSHKeyRow {
	f := strings.Fields(key)
	row := SSHKeyRow{User: user}
	if len(f) >= 1 {
		row.Type = strings.TrimPrefix(f[0], "ssh-")
	}
	if len(f) >= 2 {
		if raw, err := base64.StdEncoding.DecodeString(f[1]); err == nil {
			sum := sha256.Sum256(raw)
			row.Fingerprint = "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
		}
	}
	if len(f) >= 3 {
		row.Comment = strings.Join(f[2:], " ")
	}
	return row
}

func (s *Server) ssh(w http.ResponseWriter, r *http.Request) {
	var rows []SSHKeyRow
	for _, u := range s.cfg.SSH {
		for _, k := range u.Keys {
			rows = append(rows, sshKeyRow(u.Name, k))
		}
	}
	s.render(w, "ssh", map[string]any{"Nav": "ssh", "Rows": rows})
}

// AccountRow : un compte Authelia et sa dernière connexion, lisible.
type AccountRow struct {
	Account
	Last string
}

func (s *Server) accounts(w http.ResponseWriter, r *http.Request) {
	var list []Account
	data := map[string]any{"Nav": "accounts"}
	b, err := os.ReadFile(s.cfg.AccountsFile)
	if err == nil {
		err = json.Unmarshal(b, &list)
	}
	if err != nil {
		data["Error"] = "Résumé des comptes pas encore produit (service admin-accounts, toutes les 5 minutes)."
	}
	if st, e := os.Stat(s.cfg.AccountsFile); e == nil {
		data["Updated"] = ago(time.Since(st.ModTime()))
	}
	var rows []AccountRow
	for _, a := range list {
		row := AccountRow{Account: a, Last: "jamais"}
		if a.LastLogin != nil {
			if t, ok := parseSQLiteTime(*a.LastLogin); ok {
				row.Last = ago(time.Since(t))
			}
		}
		rows = append(rows, row)
	}
	data["Rows"] = rows
	s.render(w, "accounts", data)
}

// parseSQLiteTime : les dates de la base d'Authelia (texte, avec ou sans fuseau ni fraction).
func parseSQLiteTime(v string) (time.Time, bool) {
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02 15:04:05.999999999-07:00", "2006-01-02 15:04:05.999999999", "2006-01-02 15:04:05"} {
		if t, err := time.Parse(layout, v); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}
