package main

import (
	"context"
	"encoding/json"
	"fmt"
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

// Onglet Trafic, en lecture seule : les visites de chaque site et service (journal `visits` de
// nginx, enrichi par Vector, gardé par Loki), et pour Nextcloud et Vaultwarden les connexions et les
// applis connectées (résumé d'admin-traffic, journal de Vaultwarden).

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
	Site        string `json:"site"`
	IP          string `json:"ip"`
	Via         string `json:"via"`
	UA          string `json:"ua"`
	SSO         string `json:"sso"`
	City        string `json:"city"`
	Country     string `json:"country"`
	CountryName string `json:"country_name"`
	Path        string `json:"path"`
}

// pageLines : les pages vues sur la période (un site, ou tous si `site` est vide).
func (s *Server) pageLines(ctx context.Context, site string, since time.Duration) ([]visitLine, bool, error) {
	sel := `identifier="nginx-visits", kind="page"`
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
		country := l.CountryName
		if country == "" {
			country = l.Country
		}
		out = append(out, Visit{Site: l.Site, IP: l.IP, Via: l.Via, UA: l.UA, SSO: l.SSO, City: l.City, Country: country, Start: l.At, End: l.At, Pages: 1})
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

var viaLabels = map[string]string{"public": "public", "vpn": "VPN", "lan": "local", "machine": "think"}

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

// lokiRangeLit : une durée de LogQL (`[168h]`).
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

// TrafficRow : un site ou un service de la liste.
type TrafficRow struct {
	Name, Env, Domain, Link string
	Visits                  int
	Via                     map[string]int
	Accounts                []string
	Apps                    int
	Last                    string
	last                    time.Time
}

// trafficTargets : les sites et services servis, par domaine (services de think, puis apps.json).
func (s *Server) trafficTargets(ctx context.Context) []TrafficRow {
	var rows []TrafficRow
	for _, sv := range s.cfg.Services {
		rows = append(rows, TrafficRow{Name: sv.Name, Domain: sv.Domain})
	}
	if snap, err := s.snapshot(ctx); err == nil {
		for _, site := range snap.Apps.Names() {
			for _, d := range snap.Apps.Entries[site].Deploys(site) {
				rows = append(rows, TrafficRow{Name: d.Site, Env: d.ID, Domain: d.Domain(s.cfg.Domain)})
			}
		}
	}
	return rows
}

func (s *Server) traffic(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	key, period, periods := s.trafficPeriod(r)
	rows := s.trafficTargets(ctx)
	lines, complete, err := s.pageLines(ctx, "", period)
	visits := visitsOf(lines)
	apps := map[string]int{}
	if res, err := s.lokiMetric(ctx, fmt.Sprintf(`sum by (site) (count_over_time({identifier="nginx-visits", kind="app"}[%s]))`, lokiRangeLit(period))); err == nil {
		for _, p := range res {
			apps[p.Metric["site"]] = int(sampleValue(p))
		}
	}
	sum := s.readTrafficSummary()
	since := time.Now().Add(-period)
	for i := range rows {
		row := &rows[i]
		row.Via, row.Apps, row.Link = map[string]int{}, apps[row.Domain], "/traffic/"+row.Domain+"?p="+key
		accounts := map[string]bool{}
		for _, v := range visits {
			if v.Site != row.Domain {
				continue
			}
			row.Visits++
			row.Via[v.Via]++
			if v.End.After(row.last) {
				row.last = v.End
			}
			if v.SSO != "" {
				accounts[v.SSO] = true
			}
		}
		if nc := sum.Nextcloud; nc != nil && slices.Contains(nc.Domains, row.Domain) {
			for _, t := range nc.Tokens {
				if time.Unix(t.Last, 0).After(since) {
					accounts[t.User] = true
				}
			}
		}
		if vw := sum.Vaultwarden; vw != nil && slices.Contains(vw.Domains, row.Domain) {
			for _, d := range vw.Devices {
				if parseVWTime(d.Updated).After(since) {
					accounts[firstOf(d.User, d.Email)] = true
				}
			}
		}
		for a := range accounts {
			row.Accounts = append(row.Accounts, a)
		}
		sort.Strings(row.Accounts)
		if !row.last.IsZero() {
			row.Last = ago(time.Since(row.last))
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].Visits != rows[j].Visits {
			return rows[i].Visits > rows[j].Visits
		}
		return rows[i].Apps > rows[j].Apps
	})
	total := 0
	for _, v := range visits {
		if slices.ContainsFunc(rows, func(x TrafficRow) bool { return x.Domain == v.Site }) {
			total++
		}
	}
	s.render(w, "traffic", map[string]any{"Nav": "traffic", "Rows": rows, "Period": key, "Periods": periods, "Total": total,
		"LogsOK": err == nil, "Complete": complete})
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

var (
	reVWOK   = regexp.MustCompile(`User (\S+) logged in successfully\. IP: ([0-9A-Fa-f.:]+)`)
	reVWFail = regexp.MustCompile(`Username or password is incorrect\. Try again\. IP: ([0-9A-Fa-f.:]+)\. Username: (\S+?)\.?$`)
)

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
	since := time.Now().Add(-period)
	devices := s.vpnDevices(ctx)
	lines, complete, err := s.pageLines(ctx, domain, period)
	visits := visitsOf(lines)

	// Graphe : une colonne par heure (24 h) ou par jour.
	step, layout := 24*time.Hour, "02/01"
	if period <= 24*time.Hour {
		step, layout = time.Hour, "15h"
	}
	n := int(period / step)
	start := time.Now().Truncate(step).Add(-time.Duration(n-1) * step)
	if step == 24*time.Hour {
		y, m, d := time.Now().Date()
		start = time.Date(y, m, d, 0, 0, 0, 0, time.Local).AddDate(0, 0, -(n - 1))
	}
	// Par jour : des jours du calendrier (AddDate), pas des tranches de 24 h (changement d'heure).
	slot := func(i int) time.Time {
		if step == 24*time.Hour {
			return start.AddDate(0, 0, i)
		}
		return start.Add(time.Duration(i) * step)
	}
	bars := make([]Bar, n)
	for i := range bars {
		bars[i].Label = slot(i).Format(layout)
	}
	slotOf := func(t time.Time) int {
		for i := n - 1; i >= 0; i-- {
			if !t.Before(slot(i)) {
				return i
			}
		}
		return -1
	}
	origins := map[string]*OriginRow{}
	accounts := map[string]*CountRow{}
	byVia := map[string]int{}
	for _, v := range visits {
		if i := slotOf(v.Start); i >= 0 {
			bars[i].Visits++
		}
		byVia[v.Via]++
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
	top := 0
	for _, b := range bars {
		top = max(top, b.Visits)
	}
	for i := range bars {
		if top > 0 {
			bars[i].Height = bars[i].Visits * 100 / top
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

	// Applis : requêtes de synchro par compte, client et IP, et leur dernière (journal des visites).
	syncs := map[string]*CountRow{}
	sel := fmt.Sprintf(`{identifier="nginx-visits", kind="app", site=%q} | json`, domain)
	if res, err := s.lokiMetric(ctx, fmt.Sprintf(`sum by (user, client, ip, via) (count_over_time(%s [%s]))`, sel, lokiRangeLit(period))); err == nil {
		for _, p := range res {
			m := p.Metric
			label, detail := origin(m["via"], m["ip"], "", "", devices)
			k := m["user"] + "|" + m["client"] + "|" + m["ip"]
			syncs[k] = &CountRow{Name: firstOf(m["user"], "—"), Detail: m["client"], Sub: label + " · " + detail, Count: int(sampleValue(p))}
		}
	}
	if res, err := s.lokiMetric(ctx, fmt.Sprintf(`max by (user, client, ip) (max_over_time(%s | unwrap epoch [%s]))`, sel, lokiRangeLit(period))); err == nil {
		for _, p := range res {
			m := p.Metric
			if c := syncs[m["user"]+"|"+m["client"]+"|"+m["ip"]]; c != nil {
				c.last = time.Unix(int64(sampleValue(p)), 0)
			}
		}
	}

	// Connexions et applis connectées : Nextcloud (résumé), Vaultwarden (résumé et journal).
	sum := s.readTrafficSummary()
	var logins, sessions, connected []*CountRow
	var service string
	if nc := sum.Nextcloud; nc != nil && slices.Contains(nc.Domains, domain) {
		service = "nextcloud"
		failed := map[string]*CountRow{}
		for _, f := range nc.Failures {
			at := time.Unix(f.At, 0)
			if at.Before(since) {
				continue
			}
			user, _ := f.Metadata["user"].(string)
			label, detail := origin(viaOf(f.IP, s.cfg.VPN.Subnet), f.IP, "", "", devices)
			k := user + "|" + f.IP
			c := failed[k]
			if c == nil {
				c = &CountRow{Name: firstOf(user, "—"), Sub: label + " · " + detail}
				failed[k] = c
			}
			c.Failed++
			if at.After(c.last) {
				c.last = at
			}
		}
		logins = values(failed)
		for _, t := range nc.Tokens {
			c := &CountRow{Name: t.User, Detail: t.Name, last: time.Unix(t.Last, 0)}
			if t.Type == 0 {
				if c.last.After(since) {
					sessions = append(sessions, c)
				}
			} else {
				connected = append(connected, c)
			}
		}
	}
	if vw := sum.Vaultwarden; vw != nil && slices.Contains(vw.Domains, domain) {
		service = "vaultwarden"
		for _, d := range vw.Devices {
			typ := ""
			if d.Type >= 0 && d.Type < len(bitwardenTypes) {
				typ = bitwardenTypes[d.Type]
			}
			c := &CountRow{Name: firstOf(d.User, d.Email), Detail: firstOf(d.Name, typ), last: parseVWTime(d.Updated)}
			if typ != "" && typ != c.Detail {
				c.Sub = typ
			}
			if t := parseVWTime(d.Created); !t.IsZero() {
				c.Sub = strings.Trim(c.Sub+" · ajouté le "+t.Local().Format("02/01/2006"), " ·")
			}
			connected = append(connected, c)
		}
		if vw.Unit != "" {
			now := time.Now()
			entries, _, _ := s.lokiRange(ctx, fmt.Sprintf(`{unit=%q} |~ "logged in successfully|Username or password is incorrect"`, vw.Unit), since, now)
			byKey := map[string]*CountRow{}
			for _, e := range entries {
				var user, ip string
				ok := false
				if m := reVWOK.FindStringSubmatch(e.Line); m != nil {
					user, ip, ok = m[1], m[2], true
				} else if m := reVWFail.FindStringSubmatch(e.Line); m != nil {
					user, ip = m[2], m[1]
				} else {
					continue
				}
				label, detail := origin(viaOf(ip, s.cfg.VPN.Subnet), ip, "", "", devices)
				k := user + "|" + ip
				c := byKey[k]
				if c == nil {
					c = &CountRow{Name: user, Sub: label + " · " + detail}
					byKey[k] = c
				}
				if ok {
					c.OK++
				} else {
					c.Failed++
				}
				if e.At.After(c.last) {
					c.last = e.At
				}
			}
			logins = values(byKey)
		}
	}

	s.render(w, "traffic-site", map[string]any{"Nav": "traffic", "Target": target, "Period": key, "Periods": periods,
		"Visits": len(visits), "Pages": len(lines), "ByVia": byVia, "Bars": bars,
		"Origins": sortedOrigins(origins), "Accounts": sortedRows(values(accounts), 0), "Paths": sortedRows(values(paths), 10),
		"Syncs": sortedRows(values(syncs), 0), "Logins": sortedRows(logins, 0), "Sessions": sortedRows(sessions, 0),
		"Connected": sortedRows(connected, 0), "Service": service, "LogsOK": err == nil, "Complete": complete})
}

// viaOf : la provenance d'une IP vue par un service (VPN, réseau local ou public).
func viaOf(ip, vpnSubnet string) string {
	switch {
	case ip == "127.0.0.1" || ip == "::1":
		return "machine"
	case inSubnet(ip, vpnSubnet):
		return "vpn"
	case strings.HasPrefix(ip, "10.") || strings.HasPrefix(ip, "192.168.") || strings.HasPrefix(ip, "fe80:") || strings.HasPrefix(ip, "fd"):
		return "lan"
	}
	return "public"
}

func values[T any](m map[string]*T) []*T {
	out := make([]*T, 0, len(m))
	for _, v := range m {
		out = append(out, v)
	}
	return out
}

// sortedRows : par dernière fois (la plus récente d'abord), sinon par nombre ; `limit` > 0 coupe.
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

// inSubnet : l'IP est dans le réseau (`10.8.0.0/24`).
func inSubnet(ip, subnet string) bool {
	p, err := netip.ParsePrefix(subnet)
	if err != nil {
		return false
	}
	a, err := netip.ParseAddr(ip)
	return err == nil && p.Contains(a)
}
