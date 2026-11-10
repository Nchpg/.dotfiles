package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"runtime/debug"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Onglet Trafic, en lecture seule. Deux vues :
//   - les visites de chaque site et service (journal `visits` de nginx, enrichi par Vector, gardé
//     par Loki) : qui arrive sur ses pages, d'où ;
//   - les connexions aux services à compte (Authelia, Nextcloud, Vaultwarden) : réussies ou non, par
//     compte et par origine, et les applis connectées (résumé d'admin-traffic, journaux).

// Une visite : les pages vues par une même IP et un même navigateur sur un site, sans pause de plus
// de visitGap.
const visitGap = 30 * time.Minute

// lokiLimit : le plafond de lignes d'une requête Loki (max_entries_limit_per_query par défaut) ;
// lokiRange lit page par page jusqu'à lokiCap.
const lokiLimit = 5000

// lokiCap : au-delà, les lignes les plus anciennes de la période ne sont pas lues (comptes minorés).
const lokiCap = 100000

type lokiEntry struct {
	At   time.Time
	Line string
}

// lokiRange : les lignes d'une requête sur [start, end], les plus récentes d'abord, page par page.
func (s *Server) lokiRange(ctx context.Context, query string, start, end time.Time) (out []lokiEntry, complete bool, err error) {
	if s.cfg.Loki == "" {
		return nil, false, fmt.Errorf("pas de Loki")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	// Les lignes de l'instant `end`, déjà lues par la page précédente : relues par la suivante (pas de
	// trou), elles ne sont pas comptées deux fois.
	var seen map[string]bool
	for len(out) < lokiCap {
		q := url.Values{
			"query":     {query},
			"start":     {strconv.FormatInt(start.UnixNano(), 10)},
			"end":       {strconv.FormatInt(end.UnixNano(), 10)},
			"limit":     {strconv.Itoa(lokiLimit)},
			"direction": {"backward"},
		}
		var body struct {
			Data struct {
				Result []struct {
					Values [][2]string `json:"values"`
				} `json:"result"`
			} `json:"data"`
		}
		if err := s.lokiGet(ctx, "/loki/api/v1/query_range", q, &body); err != nil {
			return out, false, err
		}
		var batch []lokiEntry
		read := 0
		for _, r := range body.Data.Result {
			for _, v := range r.Values {
				ns, err := strconv.ParseInt(v[0], 10, 64)
				if err != nil {
					continue
				}
				read++
				if at := time.Unix(0, ns); !(at.Equal(end) && seen[strconv.FormatInt(ns, 10)+"\x00"+v[1]]) {
					batch = append(batch, lokiEntry{at, v[1]})
				}
			}
		}
		out = append(out, batch...)
		if read < lokiLimit {
			return out, true, nil
		}
		oldest := end
		for _, e := range batch {
			if e.At.Before(oldest) {
				oldest = e.At
			}
		}
		// Les lignes de l'instant le plus ancien sont relues (mieux vaut relire qu'un trou), puis
		// écartées grâce à `seen`.
		if !oldest.Before(end) {
			return out, false, nil
		}
		end = oldest
		seen = map[string]bool{}
		for _, e := range batch {
			if e.At.Equal(oldest) {
				seen[strconv.FormatInt(e.At.UnixNano(), 10)+"\x00"+e.Line] = true
			}
		}
	}
	return out, false, nil
}

// lokiMetric : une requête métrique instantanée (comptes par étiquette).
func (s *Server) lokiMetric(ctx context.Context, query string) ([]promSample, error) {
	if s.cfg.Loki == "" {
		return nil, fmt.Errorf("pas de Loki")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var body struct {
		Data struct {
			Result []promSample `json:"result"`
		} `json:"data"`
	}
	err := s.lokiGet(ctx, "/loki/api/v1/query", url.Values{"query": {query}}, &body)
	return body.Data.Result, err
}

func (s *Server) lokiGet(ctx context.Context, path string, q url.Values, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.cfg.Loki+path+"?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("loki : %s", resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func sampleValue(p promSample) float64 {
	if v, ok := p.Value[1].(string); ok {
		f, _ := strconv.ParseFloat(v, 64)
		return f
	}
	return 0
}

// visitLine : une ligne du journal des visites (cf. monitoring/vector/visits.vrl).
type visitLine struct {
	At          time.Time
	Site        string   `json:"site"`
	IP          string   `json:"ip"`
	Via         string   `json:"via"`
	UA          string   `json:"ua"`
	SSO         string   `json:"sso"`
	City        string   `json:"city"`
	Country     string   `json:"country"`
	CountryName string   `json:"country_name"`
	Lat         *float64 `json:"lat"`
	Lon         *float64 `json:"lon"`
	Path        string   `json:"path"`
	Login       string   `json:"login"`
	LoginUser   string   `json:"login_user"`
	Client      string   `json:"client"`
}

func (l visitLine) place() string {
	return firstOf(l.CountryName, l.Country)
}

// visitLines : les lignes d'un genre sur la période (un site, ou tous si `site` est vide).
func (s *Server) visitLines(ctx context.Context, kind, site string, since time.Duration) ([]visitLine, bool, error) {
	sel := fmt.Sprintf(`identifier="nginx-visits", kind=%q`, kind)
	if site != "" {
		sel += fmt.Sprintf(", site=%q", site)
	}
	now := time.Now()
	entries, complete, err := s.lokiRange(ctx, "{"+sel+"}", now.Add(-since), now)
	var out []visitLine
	for _, e := range entries {
		var l visitLine
		if json.Unmarshal([]byte(e.Line), &l) == nil {
			l.At = e.At
			out = append(out, l)
		}
	}
	return out, complete, err
}

// Visit : des pages vues d'affilée, par une même IP et un même navigateur sur un site.
type Visit struct {
	Site, IP, Via, UA, SSO, City, Country string
	Lat, Lon                              *float64
	Start, End                            time.Time
	Pages                                 int
	Paths                                 []string    // les pages vues, dans l'ordre
	PathsAt                               []time.Time // l'heure de chacune
}

func visitsOf(lines []visitLine) []Visit {
	// Une copie : les lignes d'une période sont partagées par plusieurs pages (periodLines).
	lines = slices.Clone(lines)
	sort.Slice(lines, func(i, j int) bool {
		a, b := lines[i], lines[j]
		if a.Site != b.Site {
			return a.Site < b.Site
		}
		if a.IP != b.IP {
			return a.IP < b.IP
		}
		if a.UA != b.UA {
			return a.UA < b.UA
		}
		return a.At.Before(b.At)
	})
	var out []Visit
	for _, l := range lines {
		if n := len(out); n > 0 {
			v := &out[n-1]
			if v.Site == l.Site && v.IP == l.IP && v.UA == l.UA && l.At.Sub(v.End) <= visitGap {
				v.End, v.Pages = l.At, v.Pages+1
				v.Paths, v.PathsAt = append(v.Paths, l.Path), append(v.PathsAt, l.At)
				if l.SSO != "" {
					v.SSO = l.SSO
				}
				continue
			}
		}
		out = append(out, Visit{Site: l.Site, IP: l.IP, Via: l.Via, UA: l.UA, SSO: l.SSO, City: l.City, Country: l.place(),
			Lat: l.Lat, Lon: l.Lon, Start: l.At, End: l.At, Pages: 1, Paths: []string{l.Path}, PathsAt: []time.Time{l.At}})
	}
	return out
}

// origin : d'où vient une IP, lisiblement (appareil VPN, réseau local, ville).
func origin(via, ip, city, country string, devices map[string]string) (label, detail string) {
	switch via {
	case "vpn":
		if d := devices[ip]; d != "" {
			return d, "VPN · " + ip
		}
		return ip, "VPN"
	case "lan":
		return "Réseau local", ip
	case "machine":
		return machineName, ip
	}
	place := strings.Trim(strings.Join([]string{city, country}, ", "), ", ")
	if place == "" {
		place = "Internet"
	}
	return place, ip
}

// viaLabel : l'étiquette d'une provenance du journal (public, vpn, lan, machine).
func viaLabel(via string) string {
	if via == "machine" {
		return machineName
	}
	return map[string]string{"public": "internet", "vpn": "VPN", "lan": "local"}[via]
}

// mapPoint : un lieu à placer, pour une visite ou une connexion : la ville de l'IP (internet), ou
// pour un appareil du VPN celle de l'IP publique d'où il joint le tunnel.
type mapPoint struct {
	Lat, Lon    float64
	Label, Kind string
	Site        string   // le domaine visité (ou le service où l'on s'est connecté)
	Paths       []string // les pages vues sur ce site
}

// Projection de static/world.svg : Mercator (les pays gardent leur forme ; plus grands près des
// pôles), latitudes bornées à [-58, 84] : x = lon + 180, y = mapTop - mercator(lat), en degrés.
const mapHeight = 240.5

var mapTop = mercator(84)

func mercator(lat float64) float64 {
	lat = math.Max(-58, math.Min(84, lat))
	return math.Log(math.Tan(math.Pi/4+lat*math.Pi/360)) * 180 / math.Pi
}

// MapDot : un lieu sur la carte ; R grandit avec le nombre de visites (la page le garde à peu près
// constant à l'écran quand on zoome).
type MapDot struct {
	X, Y, R      float64
	Title, Kind  string
	Label, Count string    // le lieu, « 7 visites » : l'info-bulle
	Sites        []SiteHit // les sites visités depuis ce lieu, les plus visités d'abord
}

type SiteHit struct {
	Domain string
	N      int
	Paths  []PathHit // les chemins vus, les plus vus d'abord (tipPaths au plus)
	More   int       // chemins de plus, non listés
}

type PathHit struct {
	Path string
	N    int
}

// tipPaths : chemins listés par site dans l'info-bulle.
const tipPaths = 6

// pathHits : des pages vues, comptées par chemin, les plus vues d'abord.
func pathHits(counts map[string]int) []PathHit {
	var out []PathHit
	for p, n := range counts {
		out = append(out, PathHit{p, n})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].N != out[j].N {
			return out[i].N > out[j].N
		}
		return out[i].Path < out[j].Path
	})
	return out
}

func mapDots(points []mapPoint, one, many string) []MapDot {
	type spot struct {
		mapPoint
		n     int
		sites map[string]int
		paths map[string]map[string]int
	}
	spots := map[string]*spot{}
	for _, p := range points {
		k := fmt.Sprintf("%s|%s|%.1f,%.1f", p.Kind, p.Label, p.Lat, p.Lon)
		if spots[k] == nil {
			spots[k] = &spot{mapPoint: p, sites: map[string]int{}, paths: map[string]map[string]int{}}
		}
		sp := spots[k]
		sp.n++
		if p.Site != "" {
			sp.sites[p.Site]++
			if sp.paths[p.Site] == nil {
				sp.paths[p.Site] = map[string]int{}
			}
			for _, path := range p.Paths {
				sp.paths[p.Site][path]++
			}
		}
	}
	var out []MapDot
	for _, sp := range spots {
		d := MapDot{X: math.Round((sp.Lon+180)*10) / 10, Y: math.Round((mapTop-mercator(sp.Lat))*10) / 10,
			R: math.Min(2.2+math.Sqrt(float64(sp.n))*1.1, 9), Kind: sp.Kind, Label: sp.Label, Count: plural(sp.n, one, many)}
		d.Title = d.Label + " : " + d.Count
		for site, n := range sp.sites {
			hit := SiteHit{Domain: site, N: n}
			paths := pathHits(sp.paths[site])
			hit.Paths, hit.More = paths[:min(len(paths), tipPaths)], max(0, len(paths)-tipPaths)
			d.Sites = append(d.Sites, hit)
		}
		sort.Slice(d.Sites, func(i, j int) bool {
			if d.Sites[i].N != d.Sites[j].N {
				return d.Sites[i].N > d.Sites[j].N
			}
			return d.Sites[i].Domain < d.Sites[j].Domain
		})
		out = append(out, d)
	}
	// Les plus gros d'abord : un petit point reste visible par-dessus.
	sort.Slice(out, func(i, j int) bool { return out[i].R > out[j].R })
	return out
}

// geoPlaces : de quoi placer les IP d'une page sur la carte (appareils du VPN par leur IP publique).
type geoPlaces struct {
	s         *Server
	devices   map[string]string // adresse dans le tunnel → nom
	endpoints map[string]string // adresse dans le tunnel → IP publique
}

func (s *Server) places(ctx context.Context) geoPlaces {
	return geoPlaces{s, s.vpnDevices(ctx), s.vpnEndpoints(ctx)}
}

// point : où placer une IP vue par `via` ; faux si elle ne se place pas (réseau local, inconnue).
// `lat` et `lon` : la position déjà connue (journal des visites), sinon cherchée ici.
func (g geoPlaces) point(via, ip string, lat, lon *float64, city, country string) (mapPoint, bool) {
	switch via {
	case "public":
		if lat != nil && lon != nil {
			label, _ := origin("public", ip, city, country, nil)
			return mapPoint{Lat: *lat, Lon: *lon, Label: label, Kind: "internet"}, true
		}
		if geo := g.s.geo(ip); geo.OK {
			label, _ := origin("public", ip, geo.City, geo.Country, nil)
			return mapPoint{Lat: geo.Lat, Lon: geo.Lon, Label: label, Kind: "internet"}, true
		}
	case "vpn":
		if geo := g.s.geo(g.endpoints[ip]); geo.OK {
			name := firstOf(g.devices[ip], ip)
			return mapPoint{Lat: geo.Lat, Lon: geo.Lon, Label: name + " (VPN, " + firstOf(geo.City, geo.Country) + ")", Kind: "vpn"}, true
		}
	}
	return mapPoint{}, false
}

func (g geoPlaces) visitDots(visits []Visit) []MapDot {
	var pts []mapPoint
	for _, v := range visits {
		if p, ok := g.point(v.Via, v.IP, v.Lat, v.Lon, v.City, v.Country); ok {
			p.Site, p.Paths = v.Site, v.Paths
			pts = append(pts, p)
		}
	}
	return mapDots(pts, "visite", "visites")
}

// trafficPeriod : la période choisie (?p=24h, 7j, 30j), bornée par la conservation des journaux.
func (s *Server) trafficPeriod(r *http.Request) (string, time.Duration, []Opt) {
	return s.periodOf(r.URL.Query().Get("p"))
}

// periodOf : la période d'une clé (7j par défaut).
func (s *Server) periodOf(want string) (string, time.Duration, []Opt) {
	periods := []struct {
		Key string
		D   time.Duration
	}{{"24h", 24 * time.Hour}, {"7j", 7 * 24 * time.Hour}, {"30j", 30 * 24 * time.Hour}}
	key, d := "7j", 7*24*time.Hour
	var opts []Opt
	for _, p := range periods {
		if p.D > s.cfg.LogsWindow {
			continue
		}
		if want == p.Key {
			key, d = p.Key, p.D
		}
		opts = append(opts, Opt{Value: p.Key, Label: p.Key})
	}
	for i := range opts {
		opts[i].Selected = opts[i].Value == key
	}
	return key, d, opts
}

// lokiRangeLit : une durée de LogQL (`168h`).
func lokiRangeLit(d time.Duration) string { return fmt.Sprintf("%dh", int(d.Hours())) }

// trafficSummary : le résumé d'admin-traffic (root), sans jeton.
type trafficSummary struct {
	Updated   int64 `json:"updated"`
	Nextcloud *struct {
		Domains []string `json:"domains"`
		Tokens  []struct {
			User string `json:"user"`
			Name string `json:"name"`
			Type int    `json:"type"`
			Last int64  `json:"last"`
		} `json:"tokens"`
		// Essais notés par la protection anti-force brute (31 jours au plus).
		Failures []struct {
			IP       string         `json:"ip"`
			Action   string         `json:"action"`
			At       int64          `json:"at"`
			Metadata map[string]any `json:"metadata"`
		} `json:"failures"`
	} `json:"nextcloud"`
	Vaultwarden *struct {
		Domains []string `json:"domains"`
		Unit    string   `json:"unit"`
		Devices []struct {
			User    string `json:"user"`
			Email   string `json:"email"`
			Name    string `json:"name"`
			Type    int    `json:"type"`
			Created string `json:"created"`
			Updated string `json:"updated"`
		} `json:"devices"`
	} `json:"vaultwarden"`
	Authelia *struct {
		Domains []string `json:"domains"`
		Events  []struct {
			Time string `json:"time"`
			OK   int    `json:"ok"`
			User string `json:"user"`
			IP   string `json:"ip"`
			Type string `json:"type"`
		} `json:"events"`
	} `json:"authelia"`
}

// readTrafficSummary : le résumé ; un fichier absent (admin-traffic pas encore passé) n'est pas une
// erreur.
func (s *Server) readTrafficSummary() (trafficSummary, error) {
	var t trafficSummary
	b, err := os.ReadFile(s.cfg.TrafficFile)
	if errors.Is(err, os.ErrNotExist) {
		return t, nil
	}
	if err == nil {
		err = json.Unmarshal(b, &t)
	}
	return t, err
}

// summaryStale : au-delà, le résumé (écrit toutes les 5 minutes) est en retard.
const summaryStale = 15 * time.Minute

// summaryNote : l'alerte d'un résumé illisible ou en retard, ou rien. Une date, pas « il y a » : la
// page reste en cache quelques minutes.
func summaryNote(sum trafficSummary, err error, now time.Time) string {
	if err != nil {
		return "Relevé d'admin-traffic illisible (" + err.Error() + ") : Authelia, applis connectées et sessions manquent."
	}
	if sum.Updated > 0 {
		if at := time.Unix(sum.Updated, 0); now.Sub(at) > summaryStale {
			return "Relevé d'admin-traffic du " + at.Local().Format("02/01 à 15:04") + " (il passe toutes les 5 minutes) : Authelia, applis connectées et sessions ne sont plus à jour. Le service admin-traffic ne tourne plus ?"
		}
	}
	return ""
}

// Types d'appareil de Bitwarden (DeviceType), pour la liste des applis de Vaultwarden.
var bitwardenTypes = []string{"Android", "iOS", "extension Chrome", "extension Firefox", "extension Opera", "extension Edge",
	"Windows", "macOS", "Linux", "Chrome", "Firefox", "Opera", "Edge", "Internet Explorer", "navigateur", "Android (Amazon)",
	"Windows (UWP)", "Safari", "Vivaldi", "extension Vivaldi", "extension Safari", "SDK", "serveur", "CLI Windows", "CLI macOS", "CLI Linux"}

// parseVWTime : une date de la base de Vaultwarden (UTC, sans fuseau).
func parseVWTime(v string) time.Time {
	t, _ := time.Parse("2006-01-02 15:04:05.999999999", v)
	return t
}

// TrafficRow : un site ou un service, et ses visites.
type TrafficRow struct {
	Name, Env, Domain, Link string
	Label                   string // l'environnement (production, preview…) ; vide pour un service
	Branch, Repo            string // la branche suivie, le dépôt du code (comme la page Sites)
	Access                  string // internet ou VPN : par où le site est servi
	SSO                     bool   // derrière Authelia
	Up, Probed              bool   // la sonde répond (voyant, comme la page Sites)
	First                   bool   // première ligne de son site (tableau groupé, comme la page Sites)
	Span                    int
	Visits                  int
	Manage                  string    // la page du site (apps.json) ; vide pour un service
	LastAt                  time.Time // la dernière visite (« il y a » écrit à l'affichage, seenAgo)
	Last                    string    // texte déjà formé, si LastAt manque
}

// Title : le nom, et l'environnement s'il y en a un (« myetf · preview »).
func (r TrafficRow) Title() string {
	if r.Label == "" {
		return r.Name
	}
	return r.Name + " · " + r.Label
}

// targets : trafficTargets, gardé (slowCache) : la page Trafic et celles des sites le partagent. Une
// copie : chaque page y écrit ses nombres.
func (s *Server) targets() []TrafficRow {
	rows, _ := s.slow.get("traffic-targets", func(ctx context.Context) any { return s.trafficTargets(ctx) }).([]TrafficRow)
	return slices.Clone(rows)
}

// trafficTargets : les sites et services servis, par domaine (services de la machine, puis apps.json).
func (s *Server) trafficTargets(ctx context.Context) []TrafficRow {
	var rows []TrafficRow
	up := s.probes(ctx)
	for _, sv := range s.cfg.Services {
		access := "VPN"
		if sv.Public {
			access = "internet"
		}
		r := TrafficRow{Name: sv.Name, Domain: sv.Domain, Access: access, SSO: sv.Authelia}
		if sv.Probed {
			r.Up, r.Probed = up[sv.Domain]
		}
		rows = append(rows, r)
	}
	if snap, err := s.snapshot(ctx); err == nil {
		for _, site := range snap.Apps.Names() {
			e := snap.Apps.Entries[site]
			repo := s.sourceRepo(ctx, e)
			for _, d := range e.Deploys(site) {
				access := "internet"
				if d.VPN() {
					access = "VPN"
				}
				r := TrafficRow{Name: d.Site, Env: d.ID, Label: d.Label, Branch: d.Branch, Repo: repo,
					Domain: d.Domain(s.cfg.Domain), Access: access, SSO: d.Access.SSO, Manage: "/sites/" + site}
				if d.ID != "" {
					r.Manage += "?env=" + d.ID
				}
				r.Up, r.Probed = up[r.Domain]
				rows = append(rows, r)
			}
		}
	}
	return rows
}

// loginEvent : un essai de connexion à un service à compte.
type loginEvent struct {
	At                         time.Time
	User, IP, Via, City, Place string
	Site                       string // le domaine où l'on s'est connecté
	Lat, Lon                   *float64
	Client                     string
	OK                         bool
}

// LoginService : un service à compte, ses connexions sur la période.
type LoginService struct {
	ID, Name, Link string
	Domains        []string
	OK, Failed     int
	Accounts       []string
	LastAt         time.Time
	Last           string // texte déjà formé, si LastAt manque
	events         []loginEvent
	readErr        error // sa source (journal, résumé) illisible : les nombres manquent
	partial        bool  // trop de lignes : les plus anciennes manquent
}

// alerts : ce qui manque à ses nombres, en phrases (vide si tout a été lu).
func (ls *LoginService) alerts() []string {
	switch {
	case ls.readErr != nil:
		return []string{"Connexions à " + ls.Name + " illisibles (" + ls.readErr.Error() + ") : ses nombres manquent."}
	case ls.partial:
		return []string{"Connexions à " + ls.Name + " : trop de lignes sur la période, les plus anciennes manquent (nombres minorés)."}
	}
	return nil
}

var (
	reVWOK   = regexp.MustCompile(`User (\S+) logged in successfully\. IP: ([0-9A-Fa-f.:]+)`)
	reVWFail = regexp.MustCompile(`Username or password is incorrect\. Try again\. IP: ([0-9A-Fa-f.:]+)\. Username: (\S+?)\.?$`)
)

// mfaWait : un premier facteur réussi attend son second facteur ce temps-là ; sans rien derrière, il
// est la connexion entière (domaine en `one_factor`).
const mfaWait = 5 * time.Minute

// autheliaEvent : une ligne du résumé d'Authelia, l'heure lue.
type autheliaEvent struct {
	At       time.Time
	User, IP string
	OK       bool
	Type     string // 1FA, TOTP, Webauthn, Duo…
}

// autheliaLogins : les connexions à Authelia, dans l'ordre. Une connexion réussit au second facteur ;
// un premier facteur réussi n'en est qu'une étape, sauf si aucun second facteur (réussi ou non) du même
// compte et de la même IP ne suit dans les mfaWait : il est alors la connexion entière.
func autheliaLogins(events []autheliaEvent) []autheliaEvent {
	sort.SliceStable(events, func(i, j int) bool { return events[i].At.Before(events[j].At) })
	var out []autheliaEvent
	for i, e := range events {
		if e.OK && e.Type == "1FA" {
			second := false
			for _, n := range events[i+1:] {
				if n.At.Sub(e.At) > mfaWait {
					break
				}
				if n.Type != "1FA" && n.User == e.User && n.IP == e.IP {
					second = true
					break
				}
			}
			if second {
				continue
			}
		}
		out = append(out, e)
	}
	return out
}

// loginServices : Authelia (sa base), Nextcloud (l'issue de l'envoi du formulaire, notée par nginx),
// Vaultwarden (son journal), ceux qui tournent sur la machine. `sumErr` : le résumé illisible.
func (s *Server) loginServices(ctx context.Context, sum trafficSummary, sumErr error, period time.Duration, key string) []*LoginService {
	since := time.Now().Add(-period)
	var out []*LoginService
	if a := sum.Authelia; a != nil {
		ls := &LoginService{ID: "authelia", Name: "Authelia", Domains: a.Domains, readErr: sumErr}
		var evs []autheliaEvent
		for _, e := range a.Events {
			if t, ok := parseSQLiteTime(e.Time); ok && !t.Before(since) {
				evs = append(evs, autheliaEvent{At: t, User: e.User, IP: e.IP, OK: e.OK == 1, Type: e.Type})
			}
		}
		for _, e := range autheliaLogins(evs) {
			ls.events = append(ls.events, loginEvent{At: e.At, User: e.User, IP: e.IP, Via: viaOf(e.IP, s.cfg.VPN.Subnet), OK: e.OK})
		}
		out = append(out, ls)
	}
	if nc := sum.Nextcloud; nc != nil {
		ls := &LoginService{ID: "nextcloud", Name: "Nextcloud", Domains: nc.Domains}
		lines, complete, err := s.visitLines(ctx, "login", "", period)
		ls.readErr, ls.partial = err, err == nil && !complete
		sort.Slice(lines, func(i, j int) bool { return lines[i].At.Before(lines[j].At) })
		// Avec un second facteur, le compte est tapé à la première étape : il passe à la suivante (même
		// IP, dans les 10 minutes).
		pending := map[string]visitLine{}
		for _, l := range lines {
			if !slices.Contains(nc.Domains, l.Site) {
				continue
			}
			if l.Login == "2fa" {
				pending[l.IP] = l
				continue
			}
			if l.Login != "ok" && l.Login != "failed" {
				continue
			}
			if p, ok := pending[l.IP]; ok && l.LoginUser == "" && l.At.Sub(p.At) < 10*time.Minute {
				l.LoginUser = p.LoginUser
			}
			ls.events = append(ls.events, loginEvent{At: l.At, User: l.LoginUser, IP: l.IP, Via: l.Via, City: l.City, Place: l.place(),
				Site: l.Site, Lat: l.Lat, Lon: l.Lon, Client: l.Client, OK: l.Login == "ok"})
		}
		out = append(out, ls)
	}
	if vw := sum.Vaultwarden; vw != nil && vw.Unit != "" {
		ls := &LoginService{ID: "vaultwarden", Name: "Vaultwarden", Domains: vw.Domains}
		entries, complete, err := s.lokiRange(ctx, fmt.Sprintf(`{unit=%q} |~ "logged in successfully|Username or password is incorrect"`, vw.Unit), since, time.Now())
		ls.readErr, ls.partial = err, err == nil && !complete
		for _, e := range entries {
			if m := reVWOK.FindStringSubmatch(e.Line); m != nil {
				ls.events = append(ls.events, loginEvent{At: e.At, User: m[1], IP: m[2], Via: viaOf(m[2], s.cfg.VPN.Subnet), OK: true})
			} else if m := reVWFail.FindStringSubmatch(e.Line); m != nil {
				ls.events = append(ls.events, loginEvent{At: e.At, User: m[2], IP: m[1], Via: viaOf(m[1], s.cfg.VPN.Subnet)})
			}
		}
		out = append(out, ls)
	}
	for _, ls := range out {
		ls.Link = "/traffic/connexions/" + ls.ID + "?p=" + key
		for i := range ls.events {
			e := &ls.events[i]
			// Authelia, Vaultwarden : une seule adresse, celle du service.
			if e.Site == "" && len(ls.Domains) > 0 {
				e.Site = ls.Domains[0]
			}
			// IP publique que le journal n'a pas localisée : la même base que la carte (ville, pays).
			if e.Via == "public" && e.City == "" && e.Place == "" {
				if g := s.geo(e.IP); g.City != "" || g.Country != "" {
					e.City, e.Place = g.City, g.Country
					if g.OK && e.Lat == nil {
						e.Lat, e.Lon = &g.Lat, &g.Lon
					}
				}
			}
		}
		accounts := map[string]bool{}
		for _, e := range ls.events {
			if e.OK {
				ls.OK++
			} else {
				ls.Failed++
			}
			if e.User != "" {
				accounts[e.User] = true
			}
			if e.At.After(ls.LastAt) {
				ls.LastAt = e.At
			}
		}
		for a := range accounts {
			ls.Accounts = append(ls.Accounts, a)
		}
		sort.Strings(ls.Accounts)
	}
	return out
}

// linesRead : les pages vues d'une période, telles que lues dans Loki.
type linesRead struct {
	lines    []visitLine
	complete bool
	err      error
}

// periodLines : les pages vues de toute une période, tous sites, gardées (slowCache) : la page Trafic
// et celles des sites les partagent (une page de site ne relit plus Loki). Ne pas les modifier.
func (s *Server) periodLines(key string, period time.Duration) *linesRead {
	lr, _ := s.slow.get("traffic-lines|"+key, func(ctx context.Context) any {
		lines, complete, err := s.visitLines(ctx, "page", "", period)
		return &linesRead{lines, complete, err}
	}).(*linesRead)
	if lr == nil {
		return &linesRead{err: errors.New("lecture interrompue")}
	}
	return lr
}

// loginsRead : les services à compte d'une période, et le résumé d'admin-traffic d'où ils viennent.
type loginsRead struct {
	services []*LoginService
	sum      trafficSummary
	note     string // résumé illisible ou en retard (summaryNote)
}

// periodLogins : loginServices d'une période, gardé (slowCache) : partagé par la page Trafic, celles
// des sites (le lien vers les connexions) et celles des connexions. Ne pas les modifier.
func (s *Server) periodLogins(key string, period time.Duration) *loginsRead {
	lg, _ := s.slow.get("traffic-logins-all|"+key, func(ctx context.Context) any {
		sum, err := s.readTrafficSummary()
		return &loginsRead{services: s.loginServices(ctx, sum, err, period, key), sum: sum, note: summaryNote(sum, err, time.Now())}
	}).(*loginsRead)
	if lg == nil {
		return &loginsRead{}
	}
	return lg
}

// together : des lectures indépendantes, en même temps (leurs délais ne s'additionnent plus). Une
// panique de l'une est relancée une fois toutes finies (slowCache garde alors l'ancienne page).
func together(fns ...func()) {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var panicked any
	for _, fn := range fns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() {
				if p := recover(); p != nil {
					mu.Lock()
					panicked = fmt.Sprintf("%v\n%s", p, debug.Stack())
					mu.Unlock()
				}
			}()
			fn()
		}()
	}
	wg.Wait()
	if panicked != nil {
		panic(panicked)
	}
}

func (s *Server) traffic(w http.ResponseWriter, r *http.Request) {
	s.render(w, "traffic", s.trafficPage(r.URL.Query().Get("p")))
}

// trafficPage : les données de la page Trafic d'une période (gardées, cf. slowCache ; préchauffées
// pour la période par défaut).
func (s *Server) trafficPage(p string) any {
	key, period, periods := s.periodOf(p)
	return s.slow.get("traffic|"+key, func(ctx context.Context) any { return s.trafficData(ctx, key, period, periods) })
}

func (s *Server) trafficData(ctx context.Context, key string, period time.Duration, periods []Opt) map[string]any {
	var rows []TrafficRow
	var lr *linesRead
	var lg *loginsRead
	var g geoPlaces
	together(func() { rows = s.targets() }, func() { lr = s.periodLines(key, period) },
		func() { lg = s.periodLogins(key, period) }, func() { g = s.places(ctx) })
	visits := visitsOf(lr.lines)
	var known []Visit
	visited := 0
	for i := range rows {
		row := &rows[i]
		row.Link = "/traffic/" + row.Domain + "?p=" + key
		for _, v := range visits {
			if v.Site != row.Domain {
				continue
			}
			row.Visits++
			known = append(known, v)
			if v.End.After(row.LastAt) {
				row.LastAt = v.End
			}
		}
		if row.Visits > 0 {
			visited++
		}
	}
	// Les sites d'apps.json (par site, avec leurs environnements), puis les services de la machine.
	var siteRows, services []TrafficRow
	for _, r := range rows {
		if r.Label == "" {
			services = append(services, r)
		} else {
			siteRows = append(siteRows, r)
		}
	}
	groups := groupTraffic(siteRows)
	sort.SliceStable(services, func(i, j int) bool { return services[i].Visits > services[j].Visits })
	ok, failed := 0, 0
	var notes []string
	if lg.note != "" {
		notes = append(notes, lg.note)
	}
	for _, ls := range lg.services {
		ok, failed = ok+ls.OK, failed+ls.Failed
		if ls.ID != "authelia" { // Authelia : son résumé, déjà dans lg.note
			notes = append(notes, ls.alerts()...)
		}
	}
	return map[string]any{"Nav": "traffic", "PageTitle": "Trafic", "Groups": groups, "Services": services, "Sites": len(rows), "Logins": lg.services, "Period": key, "Periods": periods,
		"Total": len(known), "Visited": visited, "OK": ok, "Failed": failed, "Dots": g.visitDots(known), "LogsOK": lr.err == nil, "Complete": lr.complete, "Notes": notes}
}

// TrafficGroup : un site et ses environnements, ses visites en tout.
type TrafficGroup struct {
	Rows   []TrafficRow
	Visits int
}

// groupTraffic : les lignes par site, dans l'ordre de la config ; les sites les plus visités d'abord.
func groupTraffic(rows []TrafficRow) []TrafficGroup {
	var groups []TrafficGroup
	at := map[string]int{}
	for _, r := range rows {
		i, ok := at[r.Name]
		if !ok {
			i = len(groups)
			at[r.Name] = i
			groups = append(groups, TrafficGroup{})
		}
		groups[i].Rows = append(groups[i].Rows, r)
		groups[i].Visits += r.Visits
	}
	for i := range groups {
		groups[i].Rows[0].First, groups[i].Rows[0].Span = true, len(groups[i].Rows)
	}
	sort.SliceStable(groups, func(i, j int) bool { return groups[i].Visits > groups[j].Visits })
	return groups
}

// firstOf : la première valeur non vide.
func firstOf(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// OriginRow : d'où viennent des visites (un appareil, une ville, le réseau local).
type OriginRow struct {
	Label, Detail, Via string
	Visits, Pages      int
	LastAt             time.Time
	Last               string      // texte déjà formé, si LastAt manque
	Items              []VisitItem // ses visites les plus récentes (visitShown), dépliées
	Older              []VisitItem // les suivantes (jusqu'à originMax), repliées
	More               int         // les plus anciennes, non listées
	visits             []Visit
}

// VisitItem : une visite d'une origine, lisiblement.
type VisitItem struct {
	When, Duration, Browser string
	Pages                   int
	SSO                     string
	Top                     []PathHit   // les pages les plus vues (visitTop au plus)
	TopMore                 int         // pages différentes de plus
	Route                   []RouteStep // le parcours, dans l'ordre (routeMax étapes au plus)
	RouteMore               int         // étapes de plus, non listées
}

// RouteStep : une étape du parcours : une page, vue N fois d'affilée à partir de Time.
type RouteStep struct {
	Time, Path string
	N          int
}

// visitTop, routeMax : pages résumées sur la ligne d'une visite ; étapes du parcours déplié.
const visitTop, routeMax = 3, 50

// originMax : visites listées sous une origine (les plus récentes) ; visitShown d'entre elles
// dépliées, les autres derrière « plus anciennes ». originsShown : origines listées d'emblée (les
// plus actives ; les autres avec ?origines=all).
const originMax, visitShown, originsShown = 12, 3, 40

var weekdays = []string{"dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."}

func visitItem(v Visit) VisitItem {
	start, end := v.Start.Local(), v.End.Local()
	when := fmt.Sprintf("%s %s · %s", weekdays[start.Weekday()], start.Format("02/01"), start.Format("15:04"))
	if end.Sub(start) >= time.Minute {
		when += " → " + end.Format("15:04")
	}
	d := end.Sub(start)
	// Une seule page : pas de durée.
	dur := ""
	switch {
	case v.Pages > 1 && d < time.Minute:
		dur = "moins d'une minute"
	case d >= time.Hour:
		dur = fmt.Sprintf("%d h %02d", int(d.Hours()), int(d.Minutes())%60)
	case d >= time.Minute:
		dur = fmt.Sprintf("%d min", int(d.Minutes()))
	}
	it := VisitItem{When: when, Duration: dur, Browser: browserOf(v.UA), Pages: v.Pages, SSO: v.SSO}
	counts := map[string]int{}
	for i, p := range v.Paths {
		counts[p]++
		if n := len(it.Route); n > 0 && it.Route[n-1].Path == p {
			it.Route[n-1].N++
			continue
		}
		at := ""
		if i < len(v.PathsAt) {
			at = v.PathsAt[i].Local().Format("15:04")
		}
		it.Route = append(it.Route, RouteStep{at, p, 1})
	}
	top := pathHits(counts)
	it.Top, it.TopMore = top[:min(len(top), visitTop)], max(0, len(top)-visitTop)
	it.RouteMore = max(0, len(it.Route)-routeMax)
	it.Route = it.Route[:len(it.Route)-it.RouteMore]
	return it
}

// browserOf : le navigateur et le système d'un User-Agent (« Firefox, Linux »), ou rien.
func browserOf(ua string) string {
	var b, os string
	for _, c := range []struct{ key, name string }{{"Edg/", "Edge"}, {"OPR/", "Opera"}, {"Firefox/", "Firefox"}, {"Chrome/", "Chrome"}, {"Safari/", "Safari"}} {
		if strings.Contains(ua, c.key) {
			b = c.name
			break
		}
	}
	for _, c := range []struct{ key, name string }{{"Android", "Android"}, {"iPhone", "iPhone"}, {"iPad", "iPad"}, {"Windows", "Windows"}, {"Mac OS X", "macOS"}, {"CrOS", "ChromeOS"}, {"Linux", "Linux"}} {
		if strings.Contains(ua, c.key) {
			os = c.name
			break
		}
	}
	return strings.Trim(b+", "+os, ", ")
}

var reNCClient = regexp.MustCompile(`(mirall|Nextcloud-android|Nextcloud-iOS)/([0-9][0-9.]*)`)

// nextcloudClient : le nom lisible d'un jeton de Nextcloud (souvent le User-Agent de l'appli qui l'a
// demandé) : « Client de bureau 4.0.8 », « Appli Android », le navigateur… `raw` : le nom brut, s'il a
// été remplacé (montré en dessous). Un nom donné à la main reste tel quel.
func nextcloudClient(name string) (label, raw string) {
	if m := reNCClient.FindStringSubmatch(name); m != nil {
		switch m[1] {
		case "mirall":
			return "Client de bureau " + m[2], name
		case "Nextcloud-android":
			return "Appli Android " + m[2], name
		default:
			return "Appli iOS " + m[2], name
		}
	}
	if strings.HasPrefix(name, "Mozilla/") {
		if b := browserOf(name); b != "" {
			return b, name
		}
	}
	return name, ""
}

// Bar : une colonne du graphe des visites (par heure sur 24 h, par jour sinon).
type Bar struct {
	Label  string
	Visits int
	Height int    // en % de la plus haute
	From   string // la première, entamée : l'heure où commence la période
}

// CountRow : un compte, une appli ou un chemin, avec son nombre et sa dernière fois.
type CountRow struct {
	Name, Detail, Sub string
	OK, Failed        int
	Count             int
	LastAt            time.Time
	Last              string // texte déjà formé, si LastAt manque
}

// bars : le graphe des visites sur [now-period, now], une colonne par heure (24 h) ou par jour du
// calendrier (pas des tranches de 24 h : le changement d'heure les décalerait). La première colonne est
// entamée (la période commence en cours d'heure ou de journée) : toutes les visites de la période
// tombent dans une colonne, et le graphe fait le même total que « Visites ».
func bars(visits []Visit, period time.Duration, now time.Time) []Bar {
	from := now.Add(-period)
	var n int
	var slot func(i int) time.Time
	layout, fromLayout := "15h", "15:04"
	if period > 24*time.Hour {
		layout, fromLayout = "02/01", "15:04"
		y, m, d := from.Date()
		start := time.Date(y, m, d, 0, 0, 0, 0, now.Location())
		slot = func(i int) time.Time { return start.AddDate(0, 0, i) }
		for !slot(n).After(now) {
			n++
		}
	} else {
		start := from.Truncate(time.Hour)
		slot = func(i int) time.Time { return start.Add(time.Duration(i) * time.Hour) }
		for !slot(n).After(now) {
			n++
		}
	}
	out := make([]Bar, n)
	for i := range out {
		out[i].Label = slot(i).Format(layout)
	}
	if n > 0 && slot(0).Before(from) {
		out[0].From = from.Format(fromLayout)
	}
	for _, v := range visits {
		i := n - 1
		for i > 0 && v.Start.Before(slot(i)) {
			i--
		}
		if i >= 0 {
			out[i].Visits++
		}
	}
	top := 0
	for _, b := range out {
		top = max(top, b.Visits)
	}
	for i := range out {
		if top > 0 {
			out[i].Height = out[i].Visits * 100 / top
		}
	}
	return out
}

func (s *Server) trafficSite(w http.ResponseWriter, r *http.Request) {
	key, period, periods := s.trafficPeriod(r)
	domain := r.PathValue("domain")
	data := s.slow.get("traffic-site|"+domain+"|"+key, func(ctx context.Context) any {
		if d := s.trafficSiteData(ctx, domain, key, period, periods); d != nil {
			return d
		}
		return nil
	})
	if data == nil {
		s.notFound(w, r, "traffic", "Aucun site ni service servi à l'adresse "+domain+".")
		return
	}
	// Beaucoup d'origines (site public, robots) : les plus actives d'abord, les autres sur demande.
	if d, ok := data.(map[string]any); ok && r.URL.Query().Get("origines") != "all" {
		if o, _ := d["Origins"].([]*OriginRow); len(o) > originsShown {
			page := maps.Clone(d)
			page["Origins"], page["OriginsMore"] = o[:originsShown], len(o)-originsShown
			data = page
		}
	}
	s.render(w, "traffic-site", data)
}

func (s *Server) trafficSiteData(ctx context.Context, domain, key string, period time.Duration, periods []Opt) map[string]any {
	var rows []TrafficRow
	var lr *linesRead
	var lg *loginsRead
	var g geoPlaces
	together(func() { rows = s.targets() }, func() { lr = s.periodLines(key, period) },
		func() { lg = s.periodLogins(key, period) }, func() { g = s.places(ctx) })
	var target *TrafficRow
	for _, t := range rows {
		if t.Domain == domain {
			target = &t
			break
		}
	}
	if target == nil {
		return nil
	}
	// Les lignes de la période, déjà lues pour la page Trafic ; relues pour ce site seul si elles
	// sont incomplètes (trop de lignes en tout : celles d'un site peuvent tenir).
	var lines []visitLine
	complete, err := lr.complete, lr.err
	if err == nil && !complete {
		lines, complete, err = s.visitLines(ctx, "page", domain, period)
	} else {
		for _, l := range lr.lines {
			if l.Site == domain {
				lines = append(lines, l)
			}
		}
	}
	visits := visitsOf(lines)
	origins := map[string]*OriginRow{}
	accounts := map[string]*CountRow{}
	for _, v := range visits {
		label, detail := origin(v.Via, v.IP, v.City, v.Country, g.devices)
		o := origins[label+"|"+detail]
		if o == nil {
			o = &OriginRow{Label: label, Detail: detail, Via: viaLabel(v.Via)}
			origins[label+"|"+detail] = o
		}
		o.Visits++
		o.Pages += v.Pages
		o.visits = append(o.visits, v)
		if v.End.After(o.LastAt) {
			o.LastAt = v.End
		}
		if v.SSO != "" {
			a := accounts[v.SSO]
			if a == nil {
				a = &CountRow{Name: v.SSO}
				accounts[v.SSO] = a
			}
			a.Count++
			if v.End.After(a.LastAt) {
				a.LastAt = v.End
			}
		}
	}
	paths := map[string]*CountRow{}
	for _, l := range lines {
		p := paths[l.Path]
		if p == nil {
			p = &CountRow{Name: l.Path}
			paths[l.Path] = p
		}
		p.Count++
	}
	// Le service à compte servi à cette adresse : lien vers ses connexions.
	var login *LoginService
	for _, ls := range lg.services {
		if slices.Contains(ls.Domains, domain) {
			login = ls
		}
	}
	return map[string]any{"Nav": "traffic", "PageTitle": "Trafic · " + target.Title(), "Target": target, "Period": key, "Periods": periods,
		"Visits": len(visits), "Pages": len(lines), "Bars": bars(visits, period, time.Now()), "Dots": g.visitDots(visits),
		"Origins": sortedOrigins(origins), "Accounts": sortedRows(values(accounts), 0), "Paths": sortedRows(values(paths), 10),
		"Login": login, "LogsOK": err == nil, "Complete": complete}
}

func (s *Server) trafficLogins(w http.ResponseWriter, r *http.Request) {
	key, period, periods := s.trafficPeriod(r)
	id := r.PathValue("service")
	data := s.slow.get("traffic-logins|"+id+"|"+key, func(ctx context.Context) any {
		if d := s.trafficLoginsData(ctx, id, key, period, periods); d != nil {
			return d
		}
		return nil
	})
	if data == nil {
		s.notFound(w, r, "traffic", "Pas de service à compte « "+id+" » sur "+machineName+".")
		return
	}
	s.render(w, "traffic-logins", data)
}

func (s *Server) trafficLoginsData(ctx context.Context, id, key string, period time.Duration, periods []Opt) map[string]any {
	lg := s.periodLogins(key, period)
	sum := lg.sum
	var ls *LoginService
	for _, x := range lg.services {
		if x.ID == id {
			ls = x
		}
	}
	if ls == nil {
		return nil
	}
	since := time.Now().Add(-period)
	var notes []string
	if lg.note != "" {
		notes = append(notes, lg.note)
	}

	// Synchros des applis (journal des visites) : par compte, appli et provenance ; et de quoi placer
	// les IP. Lus en même temps.
	var g geoPlaces
	var counts, lasts []promSample
	var countErr, lastErr error
	syncs := ls.ID != "authelia" && len(ls.Domains) > 0
	var sel string
	if syncs {
		quoted := make([]string, len(ls.Domains))
		for i, d := range ls.Domains {
			quoted[i] = regexp.QuoteMeta(d)
		}
		sel = fmt.Sprintf(`{identifier="nginx-visits", kind="app", site=~%q} | json`, strings.Join(quoted, "|"))
	}
	together(func() { g = s.places(ctx) }, func() {
		if syncs {
			counts, countErr = s.lokiMetric(ctx, fmt.Sprintf(`sum by (user, client, ip, via) (count_over_time(%s [%s]))`, sel, lokiRangeLit(period)))
		}
	}, func() {
		if syncs {
			lasts, lastErr = s.lokiMetric(ctx, fmt.Sprintf(`max by (user, client, ip) (max_over_time(%s | unwrap epoch [%s]))`, sel, lokiRangeLit(period)))
		}
	})

	// Par compte et par origine : réussies, ratées, la dernière.
	byKey := map[string]*CountRow{}
	for _, e := range ls.events {
		label, detail := origin(e.Via, e.IP, e.City, e.Place, g.devices)
		k := e.User + "|" + label + "|" + detail
		c := byKey[k]
		if c == nil {
			c = &CountRow{Name: firstOf(e.User, "—"), Detail: label, Sub: detail}
			byKey[k] = c
		}
		if e.OK {
			c.OK++
		} else {
			c.Failed++
		}
		if e.At.After(c.LastAt) {
			c.LastAt = e.At
		}
	}

	// Applis connectées (jeton gardé) et sessions web, lues dans la base du service ; essais freinés
	// par l'anti-force brute de Nextcloud.
	var connected, sessions, blocked []*CountRow
	switch ls.ID {
	case "nextcloud":
		for _, t := range sum.Nextcloud.Tokens {
			label, raw := nextcloudClient(t.Name)
			c := &CountRow{Name: t.User, Detail: label, Sub: raw}
			if t.Last > 0 {
				c.LastAt = time.Unix(t.Last, 0)
			}
			if t.Type != 0 {
				connected = append(connected, c)
			} else if c.LastAt.After(since) {
				sessions = append(sessions, c)
			}
		}
		for _, f := range sum.Nextcloud.Failures {
			at := time.Unix(f.At, 0)
			if f.At <= 0 || at.Before(since) {
				continue
			}
			via := viaOf(f.IP, s.cfg.VPN.Subnet)
			geo := Geo{}
			if via == "public" {
				geo = s.geo(f.IP)
			}
			label, detail := origin(via, f.IP, geo.City, geo.Country, g.devices)
			action := map[string]string{"login": "connexion", "sudo": "confirmation du mot de passe"}[f.Action]
			action = firstOf(action, f.Action)
			if u, _ := f.Metadata["user"].(string); u != "" {
				action += " · " + u
			}
			blocked = append(blocked, &CountRow{Name: label, Sub: detail, Detail: action, LastAt: at})
		}
	case "vaultwarden":
		for _, d := range sum.Vaultwarden.Devices {
			typ := ""
			if d.Type >= 0 && d.Type < len(bitwardenTypes) {
				typ = bitwardenTypes[d.Type]
			}
			c := &CountRow{Name: firstOf(d.User, d.Email), Detail: firstOf(d.Name, typ), LastAt: parseVWTime(d.Updated)}
			var sub []string
			if typ != "" && typ != c.Detail {
				sub = append(sub, typ)
			}
			if t := parseVWTime(d.Created); !t.IsZero() {
				sub = append(sub, "ajoutée le "+t.Local().Format("02/01/2006"))
			}
			c.Sub = strings.Join(sub, " · ")
			connected = append(connected, c)
		}
	}

	var syncRows []*CountRow
	if syncs {
		byApp := map[string]*CountRow{}
		for _, p := range counts {
			m := p.Metric
			city, country := "", ""
			if m["via"] == "public" {
				geo := s.geo(m["ip"])
				city, country = geo.City, geo.Country
			}
			label, detail := origin(m["via"], m["ip"], city, country, g.devices)
			byApp[m["user"]+"|"+m["client"]+"|"+m["ip"]] = &CountRow{Name: firstOf(m["user"], "—"), Detail: m["client"], Sub: label + " · " + detail, Count: int(sampleValue(p))}
		}
		for _, p := range lasts {
			m := p.Metric
			if c := byApp[m["user"]+"|"+m["client"]+"|"+m["ip"]]; c != nil {
				c.LastAt = time.Unix(int64(sampleValue(p)), 0)
			}
		}
		syncRows = values(byApp)
		if err := errors.Join(countErr, lastErr); err != nil {
			notes = append(notes, "Synchros illisibles ("+err.Error()+") : la liste peut manquer ou être sans dates.")
		}
	}

	// Les nombres du service : sa source lue, en entier ? (Authelia : le résumé, dans `notes`.)
	logsOK, complete := ls.readErr == nil, !ls.partial
	if ls.ID == "authelia" {
		logsOK = true
	}
	var summaryAt time.Time
	if sum.Updated > 0 {
		summaryAt = time.Unix(sum.Updated, 0)
	}
	return map[string]any{"Nav": "traffic", "PageTitle": "Connexions à " + ls.Name, "Service": ls, "Period": key, "Periods": periods,
		"Rows": sortedRows(values(byKey), 0), "Connected": sortedRows(connected, 0), "Sessions": sortedRows(sessions, 0), "Blocked": sortedRows(blocked, 0),
		"Syncs": sortedRows(syncRows, 0), "Dots": loginDots(g, ls.events), "SummaryAt": summaryAt, "Notes": notes,
		"LogsOK": logsOK, "Complete": complete,
		"LogsText":     "Journal des connexions à " + ls.Name + " illisible (Loki absent ou injoignable) : réussies et ratées manquent.",
		"CompleteText": "Trop de lignes sur la période pour tout relire : les connexions les plus anciennes manquent, les nombres sont minorés."}
}

// loginDots : les connexions sur la carte, réussies ou non, par lieu.
func loginDots(g geoPlaces, events []loginEvent) []MapDot {
	var pts []mapPoint
	for _, e := range events {
		if p, ok := g.point(e.Via, e.IP, e.Lat, e.Lon, e.City, e.Place); ok {
			p.Site = e.Site
			pts = append(pts, p)
		}
	}
	return mapDots(pts, "connexion", "connexions")
}

// viaOf : la provenance d'une IP vue par un service (VPN, réseau local ou internet).
func viaOf(ip, vpnSubnet string) string {
	a, err := netip.ParseAddr(ip)
	switch {
	case err != nil:
		return "public"
	case a.IsLoopback():
		return "machine"
	case inSubnet(ip, vpnSubnet):
		return "vpn"
	case a.IsPrivate() || a.IsLinkLocalUnicast():
		return "lan"
	}
	return "public"
}

// inSubnet : l'IP est dans le réseau (`10.8.0.0/24`).
func inSubnet(ip, subnet string) bool {
	p, err := netip.ParsePrefix(subnet)
	if err != nil {
		return false
	}
	a, err := netip.ParseAddr(ip)
	return err == nil && p.Contains(a)
}

func values[T any](m map[string]*T) []*T {
	out := make([]*T, 0, len(m))
	for _, v := range m {
		out = append(out, v)
	}
	return out
}

// sortedRows : par dernière fois (la plus récente d'abord), sinon par nombre ; `limit` > 0 trie par
// nombre et coupe.
func sortedRows(rows []*CountRow, limit int) []*CountRow {
	sort.SliceStable(rows, func(i, j int) bool {
		if !rows[i].LastAt.Equal(rows[j].LastAt) {
			return rows[i].LastAt.After(rows[j].LastAt)
		}
		return rows[i].Count > rows[j].Count
	})
	if limit > 0 {
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].Count > rows[j].Count })
		if len(rows) > limit {
			rows = rows[:limit]
		}
	}
	return rows
}

func sortedOrigins(m map[string]*OriginRow) []*OriginRow {
	rows := values(m)
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].Visits != rows[j].Visits {
			return rows[i].Visits > rows[j].Visits
		}
		return rows[i].LastAt.After(rows[j].LastAt)
	})
	for _, r := range rows {
		sort.Slice(r.visits, func(i, j int) bool { return r.visits[i].Start.After(r.visits[j].Start) })
		for i, v := range r.visits {
			if i == originMax {
				r.More = len(r.visits) - originMax
				break
			}
			if i < visitShown {
				r.Items = append(r.Items, visitItem(v))
			} else {
				r.Older = append(r.Older, visitItem(v))
			}
		}
	}
	return rows
}

func init() {
	// seenAgo : « il y a 3 min », écrit à l'affichage (les pages du Trafic restent en cache quelques
	// minutes : un texte formé à la lecture vieillirait) ; `fallback` si l'heure manque (zéro, absente).
	funcs["seenAgo"] = func(at any, fallback string) string {
		if t, ok := at.(time.Time); ok && !t.IsZero() {
			return ago(time.Since(t))
		}
		return fallback
	}
}
