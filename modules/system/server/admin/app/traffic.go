package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
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
		for _, r := range body.Data.Result {
			for _, v := range r.Values {
				if ns, err := strconv.ParseInt(v[0], 10, 64); err == nil {
					batch = append(batch, lokiEntry{time.Unix(0, ns), v[1]})
				}
			}
		}
		out = append(out, batch...)
		if len(batch) < lokiLimit {
			return out, true, nil
		}
		oldest := end
		for _, e := range batch {
			if e.At.Before(oldest) {
				oldest = e.At
			}
		}
		// Les lignes de l'instant le plus ancien sont relues : mieux vaut un doublon qu'un trou.
		if !oldest.Before(end) {
			return out, false, nil
		}
		end = oldest
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
}

func visitsOf(lines []visitLine) []Visit {
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
				if l.SSO != "" {
					v.SSO = l.SSO
				}
				continue
			}
		}
		out = append(out, Visit{Site: l.Site, IP: l.IP, Via: l.Via, UA: l.UA, SSO: l.SSO, City: l.City, Country: l.place(),
			Lat: l.Lat, Lon: l.Lon, Start: l.At, End: l.At, Pages: 1})
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
		return "think", ip
	}
	place := strings.Trim(strings.Join([]string{city, country}, ", "), ", ")
	if place == "" {
		place = "Internet"
	}
	return place, ip
}

var viaLabels = map[string]string{"public": "internet", "vpn": "VPN", "lan": "local", "machine": "think"}

// mapPoint : un lieu à placer, pour une visite ou une connexion : la ville de l'IP (internet), ou
// pour un appareil du VPN celle de l'IP publique d'où il joint le tunnel.
type mapPoint struct {
	Lat, Lon    float64
	Label, Kind string
}

// MapDot : un lieu sur la carte (projection de static/world.svg : x = lon + 180, y = 84 - lat) ; R
// grandit avec le nombre de visites (la page le garde constant à l'écran quand on zoome).
type MapDot struct {
	X, Y, R     float64
	Title, Kind string
}

func mapDots(points []mapPoint, one, many string) []MapDot {
	type spot struct {
		mapPoint
		n int
	}
	spots := map[string]*spot{}
	for _, p := range points {
		k := fmt.Sprintf("%s|%s|%.1f,%.1f", p.Kind, p.Label, p.Lat, p.Lon)
		if spots[k] == nil {
			spots[k] = &spot{mapPoint: p}
		}
		spots[k].n++
	}
	var out []MapDot
	for _, sp := range spots {
		out = append(out, MapDot{X: math.Round((sp.Lon+180)*10) / 10, Y: math.Round((84-sp.Lat)*10) / 10,
			R: math.Min(2.2+math.Sqrt(float64(sp.n))*1.1, 9), Kind: sp.Kind, Title: sp.Label + " : " + plural(sp.n, one, many)})
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
			return mapPoint{*lat, *lon, label, "internet"}, true
		}
		if geo := g.s.geo(ip); geo.OK {
			label, _ := origin("public", ip, geo.City, geo.Country, nil)
			return mapPoint{geo.Lat, geo.Lon, label, "internet"}, true
		}
	case "vpn":
		if geo := g.s.geo(g.endpoints[ip]); geo.OK {
			name := firstOf(g.devices[ip], ip)
			return mapPoint{geo.Lat, geo.Lon, name + " (VPN, " + firstOf(geo.City, geo.Country) + ")", "vpn"}, true
		}
	}
	return mapPoint{}, false
}

func (g geoPlaces) visitDots(visits []Visit) []MapDot {
	var pts []mapPoint
	for _, v := range visits {
		if p, ok := g.point(v.Via, v.IP, v.Lat, v.Lon, v.City, v.Country); ok {
			pts = append(pts, p)
		}
	}
	return mapDots(pts, "visite", "visites")
}

// trafficPeriod : la période choisie (?p=24h, 7j, 30j), bornée par la conservation des journaux.
func (s *Server) trafficPeriod(r *http.Request) (string, time.Duration, []Opt) {
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
		if r.URL.Query().Get("p") == p.Key {
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

func (s *Server) readTrafficSummary() trafficSummary {
	var t trafficSummary
	if b, err := os.ReadFile(s.cfg.TrafficFile); err == nil {
		_ = json.Unmarshal(b, &t)
	}
	return t
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
	Access                  string // internet ou VPN : par où le site est servi
	Visits                  int
	Last                    string
	last                    time.Time
}

// trafficTargets : les sites et services servis, par domaine (services de think, puis apps.json).
func (s *Server) trafficTargets(ctx context.Context) []TrafficRow {
	var rows []TrafficRow
	for _, sv := range s.cfg.Services {
		access := "VPN"
		if sv.Public {
			access = "internet"
		}
		rows = append(rows, TrafficRow{Name: sv.Name, Domain: sv.Domain, Access: access})
	}
	if snap, err := s.snapshot(ctx); err == nil {
		for _, site := range snap.Apps.Names() {
			for _, d := range snap.Apps.Entries[site].Deploys(site) {
				access := "internet"
				if d.VPN() {
					access = "VPN"
				}
				rows = append(rows, TrafficRow{Name: d.Site, Env: d.ID, Domain: d.Domain(s.cfg.Domain), Access: access})
			}
		}
	}
	return rows
}

// loginEvent : un essai de connexion à un service à compte.
type loginEvent struct {
	At                         time.Time
	User, IP, Via, City, Place string
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
	Last           string
	events         []loginEvent
}

var (
	reVWOK   = regexp.MustCompile(`User (\S+) logged in successfully\. IP: ([0-9A-Fa-f.:]+)`)
	reVWFail = regexp.MustCompile(`Username or password is incorrect\. Try again\. IP: ([0-9A-Fa-f.:]+)\. Username: (\S+?)\.?$`)
)

// loginServices : Authelia (sa base), Nextcloud (l'issue de l'envoi du formulaire, notée par nginx),
// Vaultwarden (son journal), ceux qui tournent sur think.
func (s *Server) loginServices(ctx context.Context, sum trafficSummary, period time.Duration, key string) []*LoginService {
	since := time.Now().Add(-period)
	var out []*LoginService
	if a := sum.Authelia; a != nil {
		ls := &LoginService{ID: "authelia", Name: "Authelia", Domains: a.Domains}
		for _, e := range a.Events {
			t, ok := parseSQLiteTime(e.Time)
			// Un premier facteur réussi n'est qu'une étape : la connexion réussit au second.
			if !ok || t.Before(since) || (e.OK == 1 && e.Type == "1FA") {
				continue
			}
			ls.events = append(ls.events, loginEvent{At: t, User: e.User, IP: e.IP, Via: viaOf(e.IP, s.cfg.VPN.Subnet), OK: e.OK == 1})
		}
		out = append(out, ls)
	}
	if nc := sum.Nextcloud; nc != nil {
		ls := &LoginService{ID: "nextcloud", Name: "Nextcloud", Domains: nc.Domains}
		lines, _, _ := s.visitLines(ctx, "login", "", period)
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
				Lat: l.Lat, Lon: l.Lon, Client: l.Client, OK: l.Login == "ok"})
		}
		out = append(out, ls)
	}
	if vw := sum.Vaultwarden; vw != nil && vw.Unit != "" {
		ls := &LoginService{ID: "vaultwarden", Name: "Vaultwarden", Domains: vw.Domains}
		entries, _, _ := s.lokiRange(ctx, fmt.Sprintf(`{unit=%q} |~ "logged in successfully|Username or password is incorrect"`, vw.Unit), since, time.Now())
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
		accounts := map[string]bool{}
		var last time.Time
		for _, e := range ls.events {
			if e.OK {
				ls.OK++
			} else {
				ls.Failed++
			}
			if e.User != "" {
				accounts[e.User] = true
			}
			if e.At.After(last) {
				last = e.At
			}
		}
		for a := range accounts {
			ls.Accounts = append(ls.Accounts, a)
		}
		sort.Strings(ls.Accounts)
		if !last.IsZero() {
			ls.Last = ago(time.Since(last))
		}
	}
	return out
}

func (s *Server) traffic(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	key, period, periods := s.trafficPeriod(r)
	rows := s.trafficTargets(ctx)
	lines, complete, err := s.visitLines(ctx, "page", "", period)
	visits := visitsOf(lines)
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
			if v.End.After(row.last) {
				row.last = v.End
			}
		}
		if !row.last.IsZero() {
			row.Last = ago(time.Since(row.last))
		}
		if row.Visits > 0 {
			visited++
		}
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Visits > rows[j].Visits })
	logins := s.loginServices(ctx, s.readTrafficSummary(), period, key)
	ok, failed := 0, 0
	for _, ls := range logins {
		ok, failed = ok+ls.OK, failed+ls.Failed
	}
	s.render(w, "traffic", map[string]any{"Nav": "traffic", "Rows": rows, "Logins": logins, "Period": key, "Periods": periods,
		"Total": len(known), "Visited": visited, "OK": ok, "Failed": failed, "Dots": s.places(ctx).visitDots(known), "LogsOK": err == nil, "Complete": complete})
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
	Last               string
	last               time.Time
}

// Bar : une colonne du graphe des visites (par heure sur 24 h, par jour sinon).
type Bar struct {
	Label  string
	Visits int
	Height int // en % de la plus haute
}

// CountRow : un compte, une appli ou un chemin, avec son nombre et sa dernière fois.
type CountRow struct {
	Name, Detail, Sub string
	OK, Failed        int
	Count             int
	Last              string
	last              time.Time
}

// bars : le graphe des visites, une colonne par heure (24 h) ou par jour du calendrier (pas des
// tranches de 24 h : le changement d'heure les décalerait).
func bars(visits []Visit, period time.Duration) []Bar {
	daily := period > 24*time.Hour
	var n int
	var slot func(i int) time.Time
	layout := "15h"
	if daily {
		n, layout = int(period/(24*time.Hour)), "02/01"
		y, m, d := time.Now().Date()
		start := time.Date(y, m, d, 0, 0, 0, 0, time.Local).AddDate(0, 0, -(n - 1))
		slot = func(i int) time.Time { return start.AddDate(0, 0, i) }
	} else {
		n = int(period / time.Hour)
		start := time.Now().Truncate(time.Hour).Add(-time.Duration(n-1) * time.Hour)
		slot = func(i int) time.Time { return start.Add(time.Duration(i) * time.Hour) }
	}
	out := make([]Bar, n)
	for i := range out {
		out[i].Label = slot(i).Format(layout)
	}
	for _, v := range visits {
		for i := n - 1; i >= 0; i-- {
			if !v.Start.Before(slot(i)) {
				out[i].Visits++
				break
			}
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
	ctx := r.Context()
	domain := r.PathValue("domain")
	var target *TrafficRow
	for _, t := range s.trafficTargets(ctx) {
		if t.Domain == domain {
			target = &t
			break
		}
	}
	if target == nil {
		http.NotFound(w, r)
		return
	}
	key, period, periods := s.trafficPeriod(r)
	devices := s.vpnDevices(ctx)
	lines, complete, err := s.visitLines(ctx, "page", domain, period)
	visits := visitsOf(lines)
	origins := map[string]*OriginRow{}
	accounts := map[string]*CountRow{}
	for _, v := range visits {
		label, detail := origin(v.Via, v.IP, v.City, v.Country, devices)
		o := origins[label+"|"+detail]
		if o == nil {
			o = &OriginRow{Label: label, Detail: detail, Via: viaLabels[v.Via]}
			origins[label+"|"+detail] = o
		}
		o.Visits++
		o.Pages += v.Pages
		if v.End.After(o.last) {
			o.last = v.End
		}
		if v.SSO != "" {
			a := accounts[v.SSO]
			if a == nil {
				a = &CountRow{Name: v.SSO}
				accounts[v.SSO] = a
			}
			a.Count++
			if v.End.After(a.last) {
				a.last = v.End
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
	for _, ls := range s.loginServices(ctx, s.readTrafficSummary(), period, key) {
		if slices.Contains(ls.Domains, domain) {
			login = ls
		}
	}
	s.render(w, "traffic-site", map[string]any{"Nav": "traffic", "Target": target, "Period": key, "Periods": periods,
		"Visits": len(visits), "Pages": len(lines), "Bars": bars(visits, period), "Dots": s.places(ctx).visitDots(visits),
		"Origins": sortedOrigins(origins), "Accounts": sortedRows(values(accounts), 0), "Paths": sortedRows(values(paths), 10),
		"Login": login, "LogsOK": err == nil, "Complete": complete})
}

func (s *Server) trafficLogins(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	key, period, periods := s.trafficPeriod(r)
	sum := s.readTrafficSummary()
	var ls *LoginService
	for _, x := range s.loginServices(ctx, sum, period, key) {
		if x.ID == r.PathValue("service") {
			ls = x
		}
	}
	if ls == nil {
		http.NotFound(w, r)
		return
	}
	since := time.Now().Add(-period)
	devices := s.vpnDevices(ctx)

	// Par compte et par origine : réussies, ratées, la dernière.
	byKey := map[string]*CountRow{}
	for _, e := range ls.events {
		label, detail := origin(e.Via, e.IP, e.City, e.Place, devices)
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
		if e.At.After(c.last) {
			c.last = e.At
		}
	}

	// Applis connectées (jeton gardé) et sessions web, lues dans la base du service.
	var connected, sessions []*CountRow
	switch ls.ID {
	case "nextcloud":
		for _, t := range sum.Nextcloud.Tokens {
			c := &CountRow{Name: t.User, Detail: t.Name, last: time.Unix(t.Last, 0)}
			if t.Type != 0 {
				connected = append(connected, c)
			} else if c.last.After(since) {
				sessions = append(sessions, c)
			}
		}
	case "vaultwarden":
		for _, d := range sum.Vaultwarden.Devices {
			typ := ""
			if d.Type >= 0 && d.Type < len(bitwardenTypes) {
				typ = bitwardenTypes[d.Type]
			}
			c := &CountRow{Name: firstOf(d.User, d.Email), Detail: firstOf(d.Name, typ), last: parseVWTime(d.Updated)}
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

	// Synchros des applis (journal des visites) : par compte, appli et provenance.
	var syncs []*CountRow
	if ls.ID != "authelia" && len(ls.Domains) > 0 {
		quoted := make([]string, len(ls.Domains))
		for i, d := range ls.Domains {
			quoted[i] = regexp.QuoteMeta(d)
		}
		sel := fmt.Sprintf(`{identifier="nginx-visits", kind="app", site=~%q} | json`, strings.Join(quoted, "|"))
		byApp := map[string]*CountRow{}
		if res, err := s.lokiMetric(ctx, fmt.Sprintf(`sum by (user, client, ip, via) (count_over_time(%s [%s]))`, sel, lokiRangeLit(period))); err == nil {
			for _, p := range res {
				m := p.Metric
				label, detail := origin(m["via"], m["ip"], "", "", devices)
				byApp[m["user"]+"|"+m["client"]+"|"+m["ip"]] = &CountRow{Name: firstOf(m["user"], "—"), Detail: m["client"], Sub: label + " · " + detail, Count: int(sampleValue(p))}
			}
		}
		if res, err := s.lokiMetric(ctx, fmt.Sprintf(`max by (user, client, ip) (max_over_time(%s | unwrap epoch [%s]))`, sel, lokiRangeLit(period))); err == nil {
			for _, p := range res {
				m := p.Metric
				if c := byApp[m["user"]+"|"+m["client"]+"|"+m["ip"]]; c != nil {
					c.last = time.Unix(int64(sampleValue(p)), 0)
				}
			}
		}
		syncs = values(byApp)
	}
	s.render(w, "traffic-logins", map[string]any{"Nav": "traffic", "Service": ls, "Period": key, "Periods": periods,
		"Rows": sortedRows(values(byKey), 0), "Connected": sortedRows(connected, 0), "Sessions": sortedRows(sessions, 0),
		"Syncs": sortedRows(syncs, 0), "Dots": loginDots(s.places(ctx), ls.events)})
}

// loginDots : les connexions sur la carte, réussies ou non, par lieu.
func loginDots(g geoPlaces, events []loginEvent) []MapDot {
	var pts []mapPoint
	for _, e := range events {
		if p, ok := g.point(e.Via, e.IP, e.Lat, e.Lon, e.City, e.Place); ok {
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
		if !rows[i].last.Equal(rows[j].last) {
			return rows[i].last.After(rows[j].last)
		}
		return rows[i].Count > rows[j].Count
	})
	if limit > 0 {
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].Count > rows[j].Count })
		if len(rows) > limit {
			rows = rows[:limit]
		}
	}
	for _, r := range rows {
		if !r.last.IsZero() {
			r.Last = ago(time.Since(r.last))
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
		return rows[i].last.After(rows[j].last)
	})
	for _, r := range rows {
		r.Last = ago(time.Since(r.last))
	}
	return rows
}
