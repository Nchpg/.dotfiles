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
	"sync"
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

// SSHInfo : clés autorisées de chaque compte, et de quoi en ajouter une (cf. `sshInfo`).
type SSHInfo struct {
	Users []SSHUser `json:"users"`
	Port  int       `json:"port"`
	Host  string    `json:"host"`  // think, joint par le tunnel
	Files []string  `json:"files"` // fichiers du dépôt qui déclarent les comptes
	// Clés de ssh-keys.json dans la génération active : celles que le dashboard peut retirer.
	FileKeys map[string][]string `json:"fileKeys"`
}

// SSHUser : clés autorisées d'un compte.
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

func init() {
	// abbrev : le début d'une chaîne, « … » si coupée (clé publique d'un appareil).
	funcs["abbrev"] = abbrev
}

// abbrev : les `n` premiers caractères de `v`, suivis de « … » s'il en reste.
func abbrev(v string, n int) string {
	r := []rune(v)
	if len(r) <= n {
		return v
	}
	return string(r[:n]) + "…"
}

// mainError : le message commun quand main (GitHub) ne se lit pas : ce qui n'y est que (en attente,
// accès changés d'ici) peut manquer, le reste vient de la version active de think.
func mainError(err error) string {
	if err == nil {
		return ""
	}
	return "Branche main illisible sur GitHub (" + err.Error() + ") : accès, appareils et clés en attente peuvent manquer ; le reste est celui de la version active de " + machineName + "."
}

// unreadableForm : le corps d'un formulaire illisible (trop gros, coupé) : 400 et rien de changé.
// Sans ce garde-fou, un formulaire vide décocherait tout (accès retirés).
func (s *Server) unreadableForm(w http.ResponseWriter, r *http.Request, nav string) bool {
	if err := r.ParseForm(); err != nil {
		s.badRequest(w, r, nav, "Formulaire illisible (trop gros ou coupé) : rien n'a été changé.")
		return true
	}
	return false
}

// listError : retour sur une page de liste avec un message (montré une fois : ?erreur=, puis retiré).
func (s *Server) listError(w http.ResponseWriter, r *http.Request, page, msg string) {
	s.redirect(w, r, page+"?erreur="+url.QueryEscape(msg))
}

// listInfo : retour sur une page de liste avec une information (?info=), sans rien avoir lancé.
func (s *Server) listInfo(w http.ResponseWriter, r *http.Request, page, msg string) {
	s.redirect(w, r, page+"?info="+url.QueryEscape(msg))
}

// Envois de formulaire vers apps.yml : un jeton par formulaire affiché (champ caché `token`), pour
// qu'un double clic, un F5 ou un retour arrière ne relance pas la demande ; et une seule demande à la
// fois par cible (action et nom) tant qu'elle n'est pas commitée : avant, main ne la montre pas, et
// deux inscriptions du même nom passeraient toutes les deux.
type formUse struct {
	id string // demande lancée ("" : en cours d'envoi)
	at time.Time
}

var forms = struct {
	sync.Mutex
	used     map[string]formUse
	inflight map[string]string // action:nom → demande ("" : en cours d'envoi)
}{used: map[string]formUse{}, inflight: map[string]string{}}

// formToken : un jeton neuf pour un formulaire qui lance apps.yml.
func formToken() string { return newID() }

// formSeen : le jeton a-t-il déjà servi ? Avec la demande qu'il a lancée ("" : encore en route).
func formSeen(token string) (id string, seen bool) {
	if token == "" {
		return "", false
	}
	forms.Lock()
	defer forms.Unlock()
	u, ok := forms.used[token]
	return u.id, ok
}

// errInflight : une demande pour la même cible n'est pas encore commitée.
type errInflight string

func (e errInflight) Error() string {
	return "une demande pour " + string(e) + " part déjà (commit en cours sur main) : attends son voyant, puis réessaie"
}

// dispatchForm : dispatch, une fois par jeton. `replay` : le jeton avait déjà servi (double envoi),
// rien n'est relancé et `id` est la demande d'alors. Refusé si la même cible a une demande en route.
func (s *Server) dispatchForm(ctx context.Context, token string, inputs map[string]string, label, next string) (id string, replay bool, err error) {
	key := inputs["action"] + ":" + inputs["app"]
	forms.Lock()
	for k, u := range forms.used {
		if time.Since(u.at) > time.Hour {
			delete(forms.used, k)
		}
	}
	if u, ok := forms.used[token]; ok && token != "" {
		forms.Unlock()
		return u.id, true, nil
	}
	if prev, ok := forms.inflight[key]; ok {
		if t := trackOf(prev); prev == "" || (t != nil && t.State == "running") {
			forms.Unlock()
			return "", false, errInflight(inputs["app"])
		}
	}
	if token != "" {
		forms.used[token] = formUse{at: time.Now()}
	}
	forms.inflight[key] = ""
	forms.Unlock()

	id, err = s.dispatch(ctx, inputs, label, next)

	forms.Lock()
	defer forms.Unlock()
	if err != nil {
		delete(forms.used, token) // rien n'est parti : le même formulaire peut être renvoyé
		delete(forms.inflight, key)
		return "", false, err
	}
	if token != "" {
		forms.used[token] = formUse{id: id, at: time.Now()}
	}
	forms.inflight[key] = id
	return id, false, nil
}

// sameSet : mêmes éléments, dans n'importe quel ordre.
func sameSet(a, b []string) bool {
	a, b = slices.Clone(a), slices.Clone(b)
	slices.Sort(a)
	slices.Sort(b)
	return slices.Equal(slices.Compact(a), slices.Compact(b))
}

type promSample struct {
	Metric map[string]string `json:"metric"`
	Value  [2]any            `json:"value"`
}

// promSamples : une requête instantanée à Prometheus ; erreur s'il ne répond pas (ou mal).
func (s *Server) promSamples(ctx context.Context, query string) ([]promSample, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", s.cfg.Prometheus+"/api/v1/query?query="+url.QueryEscape(query), nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("prometheus : %s", resp.Status)
	}
	var out struct {
		Data struct {
			Result []promSample `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("prometheus : %w", err)
	}
	return out.Data.Result, nil
}

// promQuery : promSamples sans l'erreur (rien s'il ne répond pas).
func (s *Server) promQuery(ctx context.Context, query string) []promSample {
	out, _ := s.promSamples(ctx, query)
	return out
}

// promLabel : une requête Prometheus, étiquette `value` par étiquette `key`.
func (s *Server) promLabel(ctx context.Context, query, key, value string) map[string]string {
	m := map[string]string{}
	for _, r := range s.promQuery(ctx, query) {
		m[r.Metric[key]] = r.Metric[value]
	}
	return m
}

// wgMetrics : l'état vivant du tunnel, par clé publique.
type wgMetrics struct {
	Handshake, Received, Sent map[string]float64
	Remote                    map[string]string // IP publique de la dernière poignée de main
}

// wireguard : poignées de main (et IP publiques), octets reçus et envoyés, en une seule requête.
func (s *Server) wireguard(ctx context.Context) (wgMetrics, error) {
	m := wgMetrics{map[string]float64{}, map[string]float64{}, map[string]float64{}, map[string]string{}}
	res, err := s.promSamples(ctx, `{__name__=~"wireguard_(latest_handshake_seconds|received_bytes_total|sent_bytes_total)"}`)
	for _, r := range res {
		v, _ := r.Value[1].(string)
		f, perr := strconv.ParseFloat(v, 64)
		if perr != nil {
			continue
		}
		key := r.Metric["public_key"]
		switch r.Metric["__name__"] {
		case "wireguard_latest_handshake_seconds":
			m.Handshake[key] = f
			if ip := r.Metric["remote_ip"]; ip != "" {
				m.Remote[key] = ip
			}
		case "wireguard_received_bytes_total":
			m.Received[key] = f
		case "wireguard_sent_bytes_total":
			m.Sent[key] = f
		}
	}
	return m, err
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

type peerEntry struct {
	PublicKey string   `json:"publicKey"`
	Address   string   `json:"address"`
	Services  []string `json:"services"`
}

// mainPeersErr : vpn-peers.json sur main. Les accès s'y lisent : un changement se voit dès son
// commit, avant qu'apps-deploy l'applique.
func (s *Server) mainPeersErr(ctx context.Context) (map[string]peerEntry, error) {
	head, err := s.gh.HeadCached(ctx)
	if err != nil {
		return nil, err
	}
	b, err := s.gh.File(ctx, head, peersPath)
	if err != nil {
		return nil, err
	}
	file := map[string]peerEntry{}
	if err := json.Unmarshal(b, &file); err != nil {
		return nil, fmt.Errorf("%s illisible : %w", peersPath, err)
	}
	return file, nil
}

// mainPeers : mainPeersErr sans l'erreur (nil s'il est illisible).
func (s *Server) mainPeers(ctx context.Context) map[string]peerEntry {
	m, _ := s.mainPeersErr(ctx)
	return m
}

// withMainServices : les services d'un appareil tels que main les donne, s'il y est.
func withMainServices(p VPNPeer, main map[string]peerEntry) VPNPeer {
	if e, ok := main[p.Name]; ok {
		p.Services = e.Services
	}
	return p
}

// pendingOf : appareils de vpn-peers.json sur main (`file`) qui ne sont pas dans la génération active.
func (s *Server) pendingOf(file map[string]peerEntry) []VPNPeer {
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

// pendingPeers : les appareils en attente, d'après main (aucun s'il est illisible).
func (s *Server) pendingPeers(ctx context.Context) []VPNPeer { return s.pendingOf(s.mainPeers(ctx)) }

// allPeers : les appareils actifs, puis ceux en attente.
func (s *Server) allPeers(pending []VPNPeer) []VPNPeer {
	return append(append([]VPNPeer(nil), s.cfg.VPN.Peers...), pending...)
}

// Sites en VPN et leurs appareils ; sites avec Authelia et leurs comptes.
var (
	vpnDeploy  = func(d Deploy) bool { return d.VPN() }
	deviceList = func(d Deploy) []string { return d.Access.Devices }
	ssoDeploy  = func(d Deploy) bool { return d.Access.SSO }
	accountsOf = func(d Deploy) []string { return d.Access.Accounts }
)

// sitesByMember : pour chaque membre (appareil, compte), les sites retenus par `pick` qui le listent.
func sitesByMember(snap *Snapshot, pick func(Deploy) bool, members func(Deploy) []string) map[string][]string {
	out := map[string][]string{}
	for _, site := range snap.Apps.Names() {
		for _, d := range snap.Apps.Entries[site].Deploys(site) {
			if pick(d) {
				for _, m := range members(d) {
					out[m] = append(out[m], d.App)
				}
			}
		}
	}
	return out
}

func (s *Server) vpn(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	wg, wgErr := s.wireguard(ctx)
	// Sites en VPN qui listent l'appareil (génération de main, lue en cache).
	sitesOf := map[string][]string{}
	snap, snapErr := s.snapshot(ctx)
	if snapErr == nil {
		sitesOf = sitesByMember(snap, vpnDeploy, deviceList)
	}
	var rows []PeerRow
	connected := 0
	main, mainErr := s.mainPeersErr(ctx)
	for _, p := range s.cfg.VPN.Peers {
		p = withMainServices(p, main)
		row := PeerRow{VPNPeer: p, Received: humanBytes(wg.Received[p.PublicKey]), Sent: humanBytes(wg.Sent[p.PublicKey]), RemoteIP: wg.Remote[p.PublicKey], Services: p.Services, Sites: sitesOf[p.Name]}
		if t := wg.Handshake[p.PublicKey]; t > 0 {
			d := time.Since(time.Unix(int64(t), 0))
			// Un appareil actif refait sa poignée de main toutes les 2 minutes.
			row.Seen, row.Connected, row.LastSeen = true, d < 3*time.Minute, ago(d)
		}
		if row.Connected {
			connected++
		}
		rows = append(rows, row)
	}
	for _, p := range s.pendingOf(main) {
		rows = append(rows, PeerRow{VPNPeer: p, Pending: true, Services: p.Services, Sites: sitesOf[p.Name]})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Connected && !rows[j].Connected })
	q := r.URL.Query()
	s.render(w, "vpn", map[string]any{"Nav": "vpn", "Rows": rows, "Connected": connected, "Total": len(s.cfg.VPN.Peers),
		"Endpoint": s.cfg.VPN.Endpoint, "Subnet": s.cfg.VPN.Subnet, "Error": q.Get("erreur"), "Notice": q.Get("info"), "Track": listTrack(r),
		"MetricsOK": wgErr == nil, "MainError": mainError(firstErr(mainErr, snapErr))})
}

// firstErr : la première erreur non nulle.
func firstErr(errs ...error) error {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}

// nextAddress : la première adresse libre du /24 du tunnel (serveur et appareils exclus, ceux en
// attente compris).
func (s *Server) nextAddress(pending []VPNPeer) (string, error) {
	_, network, err := net.ParseCIDR(s.cfg.VPN.Subnet)
	if err != nil {
		return "", fmt.Errorf("sous-réseau %q illisible", s.cfg.VPN.Subnet)
	}
	used := map[string]bool{s.cfg.VPN.ServerAddress: true}
	for _, p := range s.allPeers(pending) {
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
	main, mainErr := s.mainPeersErr(r.Context())
	addr, err := s.nextAddress(s.pendingOf(main))
	sites, sitesErr := s.accessSites(r.Context(), "")
	s.render(w, "vpn-new", map[string]any{"Nav": "vpn", "PageTitle": "Nouvel appareil", "Address": addr, "Error": errString(err), "Subnet": s.cfg.VPN.Subnet,
		"Services": s.cfg.VPN.Services, "Checked": map[string]bool{}, "Sites": sites, "MainError": mainError(firstErr(mainErr, sitesErr)), "Token": formToken()})
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

// siteChanges : les sites (avec leur propre accès) dont la case cochée (`checked`) diffère de l'état.
func siteChanges(checked []string, sites []AccessSite) []siteAccess {
	changes := []siteAccess{}
	for _, a := range sites {
		on := slices.Contains(checked, a.App)
		if !a.Inherited && on != a.On {
			changes = append(changes, siteAccess{a.Site, a.Env, on})
		}
	}
	return changes
}

// checkedServices : les services cochés (`checked`) parmi ceux connus, jamais nil, et en table.
func checkedServices(checked []string, known []VPNService) ([]string, map[string]bool) {
	out, m := []string{}, map[string]bool{}
	for _, sv := range known {
		if slices.Contains(checked, sv.Name) {
			out = append(out, sv.Name)
			m[sv.Name] = true
		}
	}
	return out, m
}

// checkedOf : une liste de services en table (cases cochées).
func checkedOf(services []string) map[string]bool {
	m := map[string]bool{}
	for _, sv := range services {
		m[sv] = true
	}
	return m
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
	for _, p := range s.allPeers(pending) {
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
	if s.unreadableForm(w, r, "vpn") {
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	token := r.FormValue("token")
	// Renvoi (double clic, F5) : les clés n'étaient montrées qu'une fois, rien n'est relancé.
	replay := func(id string) {
		s.render(w, "vpn-added", map[string]any{"Nav": "vpn", "PageTitle": name, "Name": name, "Replay": true, "Track": trackOf(id)})
	}
	if id, seen := formSeen(token); seen {
		replay(id)
		return
	}
	services, checked := checkedServices(r.Form["service"], s.cfg.VPN.Services)
	all, sitesErr := s.accessSites(ctx, "")
	sites := formSites(r, all)
	main, mainErr := s.mainPeersErr(ctx)
	fail := func(msg string) {
		s.render(w, "vpn-new", map[string]any{"Nav": "vpn", "PageTitle": "Nouvel appareil", "Name": name, "Address": r.FormValue("address"), "Error": msg, "Subnet": s.cfg.VPN.Subnet,
			"Services": s.cfg.VPN.Services, "Checked": checked, "Sites": sites, "MainError": mainError(firstErr(mainErr, sitesErr)), "Token": formToken()})
	}
	if !reDeviceName.MatchString(name) {
		fail("Nom : lettres minuscules, chiffres et _ (24 caractères au plus).")
		return
	}
	pending := s.pendingOf(main)
	for _, p := range s.allPeers(pending) {
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
		fail("Génération des clés : " + err.Error())
		return
	}
	psk := make([]byte, 32)
	if _, err := rand.Read(psk); err != nil {
		fail("Génération de la clé pré-partagée : " + err.Error())
		return
	}
	b64 := base64.StdEncoding.EncodeToString
	pub := b64(priv.PublicKey().Bytes())
	on := []siteAccess{}
	for _, a := range sites {
		if a.On && !a.Inherited {
			on = append(on, siteAccess{a.Site, a.Env, true})
		}
	}
	entry, _ := json.Marshal(map[string]any{"publicKey": pub, "address": addr, "services": services, "sites": on})
	id, again, err := s.dispatchForm(ctx, token, map[string]string{"action": "peer", "app": name, "entry": string(entry), "source": "dashboard"},
		"Appareil "+name, "Il ne s'ouvre qu'avec les étapes ci-dessous (secret, puis rebuild).")
	if err != nil {
		fail("Inscription impossible (apps.yml) : " + err.Error())
		return
	}
	if again {
		replay(id)
		return
	}
	conf := wgClientConf(b64(priv.Bytes()), addr, s.cfg.VPN, strings.TrimSpace(string(serverPub)), b64(psk))
	s.render(w, "vpn-added", map[string]any{
		"Nav": "vpn", "PageTitle": name, "Name": name, "Address": addr, "Conf": conf, "QR": qrSVG(ctx, conf),
		"Download":  "data:text/plain;base64," + b64([]byte(conf)),
		"Secret":    fmt.Sprintf("wireguard:\n  %s_preshared_key: %s", name, b64(psk)),
		"SecretKey": "wireguard/" + name + "_preshared_key",
		"Track":     trackOf(id),
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
		s.badRequest(w, r, "vpn", "Nom d'appareil invalide : "+name+".")
		return
	}
	if s.unreadableForm(w, r, "vpn") {
		return
	}
	token := r.FormValue("token")
	if id, seen := formSeen(token); seen {
		tracked(w, r, "/vpn", id)
		return
	}
	known, active := false, slices.ContainsFunc(s.cfg.VPN.Peers, func(p VPNPeer) bool { return p.Name == name })
	for _, p := range s.allPeers(s.pendingPeers(r.Context())) {
		known = known || (p.Name == name && p.Added)
	}
	if !known {
		s.listError(w, r, "/vpn", name+" n'est pas dans vpn-peers.json : il se retire dans vpn.nix.")
		return
	}
	if name == s.requestDevice(r) {
		s.listError(w, r, "/vpn", "Tu es connecté depuis "+name+" : le retirer te couperait le VPN. Fais-le depuis un autre appareil.")
		return
	}
	next := "Il reste autorisé jusqu'au prochain rebuild : git pull, puis rebuild."
	if !active {
		next = "Il n'avait pas encore été activé : rien d'autre à faire."
	}
	id, _, err := s.dispatchForm(r.Context(), token, map[string]string{"action": "peer", "app": name, "entry": "null", "source": "dashboard"},
		"Retrait de "+name, next)
	if err != nil {
		s.listError(w, r, "/vpn", "Retrait impossible (apps.yml) : "+err.Error())
		return
	}
	tracked(w, r, "/vpn", id)
}

// AccessSite : un site (ou environnement) en VPN dans la page Accès d'un appareil. Inherited : il
// reprend l'accès de son parent, il se règle là-bas.
type AccessSite struct {
	Site, Env, App, Domain, From string
	On, Inherited                bool
}

// deploySites : les sites (et environnements) de main que `pick` retient, et si `member` est dans
// leur liste (`members` : appareils ou comptes).
func (s *Server) deploySites(ctx context.Context, pick func(Deploy) bool, members func(Deploy) []string, member string) ([]AccessSite, error) {
	snap, err := s.snapshot(ctx)
	if err != nil {
		return nil, err
	}
	var out []AccessSite
	for _, site := range snap.Apps.Names() {
		e := snap.Apps.Entries[site]
		for _, d := range e.Deploys(site) {
			if !pick(d) {
				continue
			}
			a := AccessSite{Site: site, Env: d.ID, App: d.App, Domain: d.Domain(s.cfg.Domain), On: slices.Contains(members(d), member)}
			if d.ID != "" && !e.Environments[d.ID].OwnAccess() {
				a.Inherited, a.From = true, e.labelOf(e.Environments[d.ID].From)
			}
			out = append(out, a)
		}
	}
	return out, nil
}

// accessSites : les sites en VPN de main, et si l'appareil y est.
func (s *Server) accessSites(ctx context.Context, device string) ([]AccessSite, error) {
	return s.deploySites(ctx, vpnDeploy, deviceList, device)
}

// peerByName : un appareil actif ou en attente.
func (s *Server) peerByName(ctx context.Context, name string) (VPNPeer, bool) {
	main := s.mainPeers(ctx)
	for _, p := range s.allPeers(s.pendingOf(main)) {
		if p.Name == name {
			return withMainServices(p, main), true
		}
	}
	return VPNPeer{}, false
}

// vpnAccessPage : la page Accès d'un appareil (cases d'après `checked` et `sites`).
func (s *Server) vpnAccessPage(w http.ResponseWriter, r *http.Request, p VPNPeer, checked map[string]bool, sites []AccessSite, sitesErr error, msg string) {
	self := p.Name == s.requestDevice(r)
	lock := ""
	if self && slices.Contains(p.Services, "admin") {
		lock = "admin" // le dashboard ne se retire pas depuis l'appareil qui s'en sert
	}
	s.render(w, "vpn-access", map[string]any{"Nav": "vpn", "PageTitle": p.Name, "Peer": p, "Services": s.cfg.VPN.Services, "Checked": checked,
		"Sites": sites, "Error": msg, "MainError": mainError(sitesErr), "Self": self, "Lock": lock, "Token": formToken(),
		"Pending": !slices.ContainsFunc(s.cfg.VPN.Peers, func(x VPNPeer) bool { return x.Name == p.Name })})
}

func (s *Server) vpnAccess(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	p, ok := s.peerByName(ctx, r.PathValue("name"))
	if !ok || !p.Added {
		s.notFound(w, r, "vpn", "Appareil inconnu, ou déclaré dans vpn.nix (ses accès s'y règlent).")
		return
	}
	sites, err := s.accessSites(ctx, p.Name)
	s.vpnAccessPage(w, r, p, checkedOf(p.Services), sites, err, "")
}

// vpnAccessSave : services cochés et sites cochés (ceux qui ont leur propre accès), en un commit.
// Refusé : la page revient avec les cases telles qu'envoyées.
func (s *Server) vpnAccessSave(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	p, ok := s.peerByName(ctx, r.PathValue("name"))
	if !ok || !p.Added {
		s.notFound(w, r, "vpn", "Appareil inconnu, ou déclaré dans vpn.nix (ses accès s'y règlent).")
		return
	}
	if s.unreadableForm(w, r, "vpn") {
		return
	}
	token := r.FormValue("token")
	if id, seen := formSeen(token); seen {
		tracked(w, r, "/vpn", id)
		return
	}
	services, checked := checkedServices(r.Form["service"], s.cfg.VPN.Services)
	sites, sitesErr := s.accessSites(ctx, p.Name)
	again := func(msg string) { s.vpnAccessPage(w, r, p, checked, formSites(r, sites), sitesErr, msg) }
	if slices.Contains(p.Services, "admin") && !slices.Contains(services, "admin") && p.Name == s.requestDevice(r) {
		again("Tu es connecté depuis " + p.Name + " : lui retirer le dashboard te fermerait la page. Fais-le depuis un autre appareil.")
		return
	}
	if sitesErr != nil {
		again("Sites illisibles (" + sitesErr.Error() + ") : rien n'a été changé, réessaie dans un instant.")
		return
	}
	changes := siteChanges(r.Form["site"], sites)
	if sameSet(services, p.Services) && len(changes) == 0 {
		s.listInfo(w, r, "/vpn", "Accès de "+p.Name+" : rien à changer.")
		return
	}
	entry, _ := json.Marshal(map[string]any{"services": services, "sites": changes})
	id, _, err := s.dispatchForm(ctx, token, map[string]string{"action": "access", "app": p.Name, "entry": string(entry), "source": "dashboard"},
		"Accès de "+p.Name, "")
	if err != nil {
		again("Changement impossible (apps.yml) : " + err.Error())
		return
	}
	tracked(w, r, "/vpn", id)
}

// SSHKeyRow : une clé autorisée, son type, son commentaire et son empreinte (comme ssh-keygen -l).
type SSHKeyRow struct {
	User, Type, Comment, Fingerprint string
	Key                              string // la ligne entière, publique
	// Dans ssh-keys.json sur main (retirable d'ici) ; ajoutée ou retirée sur main, rebuild à faire.
	InFile, Adding, Removing bool
	// Activité (journal de sshd) : session ouverte, dernière connexion, d'où, combien sur la fenêtre.
	Connected      bool
	ConnectedSince string
	LastSeen, From string
	Count          int
	Unknown        bool // connectée sur la fenêtre, mais plus (ou pas) autorisée
}

func sshKeyRow(user, key string) SSHKeyRow {
	f := strings.Fields(key)
	row := SSHKeyRow{User: user, Key: key}
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

// sortKeyRows : ordre stable d'un rendu à l'autre (la page se relit à chaque étape d'une demande) :
// connectées d'abord, hors liste en dernier, puis par compte, commentaire et empreinte.
func sortKeyRows(rows []SSHKeyRow) {
	rank := func(x SSHKeyRow) int {
		switch {
		case x.Connected:
			return 0
		case x.Unknown:
			return 2
		}
		return 1
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if rank(a) != rank(b) {
			return rank(a) < rank(b)
		}
		if a.User != b.User {
			return a.User < b.User
		}
		if a.Comment != b.Comment {
			return a.Comment < b.Comment
		}
		return a.Fingerprint < b.Fingerprint
	})
}

func (s *Server) ssh(w http.ResponseWriter, r *http.Request) {
	onMain, mainErr := s.mainSSHKeysErr(r.Context())
	known := mainErr == nil
	var rows []SSHKeyRow
	for _, u := range s.cfg.SSH.Users {
		for _, k := range u.Keys {
			row := sshKeyRow(u.Name, k)
			if known {
				row.InFile = slices.Contains(onMain[u.Name], k)
				row.Removing = slices.Contains(s.cfg.SSH.FileKeys[u.Name], k) && !row.InFile
			} else {
				// main illisible : la génération active dit d'où vient la clé.
				row.InFile = slices.Contains(s.cfg.SSH.FileKeys[u.Name], k)
			}
			rows = append(rows, row)
		}
	}
	for user, keys := range onMain {
		for _, k := range keys {
			if !slices.ContainsFunc(rows, func(x SSHKeyRow) bool { return x.User == user && x.Key == k }) {
				row := sshKeyRow(user, k)
				row.InFile, row.Adding = true, true
				rows = append(rows, row)
			}
		}
	}
	act := s.sshActivityOf()
	devices := s.vpnDevices(r.Context())
	from := func(ip string) string {
		if d := devices[ip]; d != "" {
			return d + " (" + ip + ")"
		}
		return ip
	}
	// Clés connectées sur la fenêtre sans être dans la liste (retirées depuis, par exemple).
	for fp := range act.Uses {
		if !slices.ContainsFunc(rows, func(x SSHKeyRow) bool { return x.Fingerprint == fp }) {
			rows = append(rows, SSHKeyRow{Fingerprint: fp, Unknown: true})
		}
	}
	for i := range rows {
		row := &rows[i]
		if u := act.Uses[row.Fingerprint]; u != nil {
			row.Count, row.LastSeen, row.From = u.Count, ago(time.Since(u.Last)), from(u.LastIP)
		}
		for _, se := range act.Sessions {
			if se.Fingerprint == row.Fingerprint && row.Fingerprint != "" {
				row.Connected, row.From = true, from(se.IP)
				if !se.Since.IsZero() {
					row.ConnectedSince = se.Since.Local().Format("15:04")
				}
			}
		}
	}
	sortKeyRows(rows)
	// Copies : les refus sont partagés par toutes les requêtes (cache), rien ne s'y écrit.
	refused := 0
	refusals := make([]SSHRefusal, 0, len(act.Refusals))
	for _, x := range act.Refusals {
		c := *x
		c.Device, c.Last = devices[c.IP], ago(time.Since(c.last))
		refused += c.Count
		refusals = append(refusals, c)
	}
	q := r.URL.Query()
	s.render(w, "ssh", map[string]any{"Nav": "ssh", "Rows": rows, "Error": q.Get("erreur"), "Notice": q.Get("info"), "Track": listTrack(r), "Token": formToken(),
		"Sessions": len(act.Sessions), "Logins": s.sshLogins(r.Context(), sshLoginStep), "Accepted": len(act.Logins), "Refusals": refusals, "Refused": refused, "LogsOK": act.LogsOK,
		"Truncated": act.Truncated, "Window": windowLabel(s.cfg.LogsWindow), "MainError": mainError(mainErr)})
}

// SSHLogin : une connexion acceptée, lisiblement.
type SSHLogin struct {
	Time, Device, IP, User, Key string
	Fingerprint                 string
	Unknown                     bool // clé qui n'est plus autorisée
	Open                        bool // sa session est encore ouverte
}

type SSHLoginDay struct {
	Label string
	Items []SSHLogin
}

// SSHLogins : les `N` dernières connexions acceptées, par jour ; `More` s'il en reste.
type SSHLogins struct {
	Days    []SSHLoginDay
	N, Next int
	More    bool
	Window  string
}

const sshLoginStep = 10

// sshLogins : les `n` dernières connexions acceptées (journal de sshd), comme l'historique des sites.
func (s *Server) sshLogins(ctx context.Context, n int) SSHLogins {
	n = max(n, sshLoginStep)
	act := s.sshActivityOf()
	devices := s.vpnDevices(ctx)
	keys := map[string]string{}
	for _, u := range s.cfg.SSH.Users {
		for _, k := range u.Keys {
			row := sshKeyRow(u.Name, k)
			keys[row.Fingerprint] = firstOf(row.Comment, row.Type)
		}
	}
	out := SSHLogins{N: n, Next: n + sshLoginStep, More: len(act.Logins) > n, Window: windowLabel(s.cfg.LogsWindow)}
	for _, e := range act.Logins[:min(n, len(act.Logins))] {
		at := e.At.Local()
		label := frenchDay(at)
		if len(out.Days) == 0 || out.Days[len(out.Days)-1].Label != label {
			out.Days = append(out.Days, SSHLoginDay{Label: label})
		}
		key, known := keys[e.Fingerprint]
		it := SSHLogin{Time: at.Format("15:04"), Device: devices[e.IP], IP: e.IP, User: e.User, Key: key, Fingerprint: e.Fingerprint, Unknown: !known}
		for _, se := range act.Sessions {
			if se.Fingerprint == e.Fingerprint && se.IP == e.IP && !se.Since.IsZero() && se.Since.Sub(e.At).Abs() < 5*time.Second {
				it.Open = true
			}
		}
		d := &out.Days[len(out.Days)-1]
		d.Items = append(d.Items, it)
	}
	return out
}

// sshLoginsMore : « Voir plus » des connexions acceptées.
func (s *Server) sshLoginsMore(w http.ResponseWriter, r *http.Request) {
	n, _ := strconv.Atoi(r.URL.Query().Get("n"))
	s.render(w, "ssh-logins", s.sshLogins(r.Context(), n))
}

// windowLabel : la fenêtre des journaux, lisible (« 30 j »).
func windowLabel(d time.Duration) string {
	if d >= 48*time.Hour {
		return fmt.Sprintf("%d j", int(d.Hours()/24))
	}
	return fmt.Sprintf("%d h", int(d.Hours()))
}

const sshKeysPath = "profiles/server/ssh-keys.json"

// mainSSHKeysErr : ssh-keys.json sur main, ou pourquoi il ne se lit pas.
func (s *Server) mainSSHKeysErr(ctx context.Context) (map[string][]string, error) {
	head, err := s.gh.HeadCached(ctx)
	if err != nil {
		return nil, err
	}
	b, err := s.gh.File(ctx, head, sshKeysPath)
	if err != nil {
		return nil, err
	}
	var keys map[string][]string
	if err := json.Unmarshal(b, &keys); err != nil {
		return nil, fmt.Errorf("%s illisible : %w", sshKeysPath, err)
	}
	return keys, nil
}

// mainSSHKeys : ssh-keys.json sur main ; `known` faux s'il est illisible (rien n'est alors annoncé).
func (s *Server) mainSSHKeys(ctx context.Context) (map[string][]string, bool) {
	keys, err := s.mainSSHKeysErr(ctx)
	return keys, err == nil
}

// sshRemove : retire une clé de ssh-keys.json (commit) ; elle reste active jusqu'au rebuild.
func (s *Server) sshRemove(w http.ResponseWriter, r *http.Request) {
	if s.unreadableForm(w, r, "ssh") {
		return
	}
	user, key, token := r.FormValue("user"), r.FormValue("key"), r.FormValue("token")
	if id, seen := formSeen(token); seen {
		tracked(w, r, "/ssh", id)
		return
	}
	onMain, known := s.mainSSHKeys(r.Context())
	if !known {
		s.listError(w, r, "/ssh", "Branche main illisible sur GitHub : rien n'a été retiré, réessaie dans un instant.")
		return
	}
	if !slices.Contains(onMain[user], key) {
		s.listError(w, r, "/ssh", "Cette clé n'est pas dans "+sshKeysPath+" sur main : elle se retire dans le code Nix.")
		return
	}
	row := sshKeyRow(user, key)
	entry, _ := json.Marshal(map[string]string{"remove": key})
	id, _, err := s.dispatchForm(r.Context(), token, map[string]string{"action": "sshkey", "app": user, "entry": string(entry), "source": "dashboard"},
		"Retrait de la clé "+firstOf(row.Comment, abbrev(row.Fingerprint, 16)), "Elle reste autorisée jusqu'au prochain rebuild : git pull, puis rebuild (qui le montre et demande confirmation).")
	if err != nil {
		s.listError(w, r, "/ssh", "Retrait impossible (apps.yml) : "+err.Error())
		return
	}
	tracked(w, r, "/ssh", id)
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
