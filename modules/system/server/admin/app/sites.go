package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"html/template"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

var palette = [][2]string{
	{"#EEF0FD", "#3B47C4"}, {"#FFF1E7", "#B4440C"}, {"#E9F8EF", "#15803D"}, {"#E8F4FB", "#0B6A9E"},
	{"#FCEEF5", "#B0185A"}, {"#FDF6E3", "#8D5B05"}, {"#F3F0FD", "#5B3DC2"}, {"#EAF7F6", "#0F766E"},
}

func colorsOf(name string) (string, string) {
	sum := sha256.Sum256([]byte(name))
	c := palette[int(sum[0])%len(palette)]
	return c[0], c[1]
}

type StateCard struct {
	Title, Chip, Text, Tint, Ink, Icon string
	Think, Main                        string
	Pending                            []string
	Checkout                           string
	CheckoutInk                        string
}

// ActivityItem : un commit de sites, lu comme une phrase (site, ce qui change, type).
type ActivityItem struct {
	Name, What, Kind, Icon, Ink string
	Rev, Time, URL              string
}

type ActivityDay struct {
	Label string
	Items []ActivityItem
}

// SiteRow : une ligne du tableau, un déploiement (la racine d'abord, puis les environnements).
type SiteRow struct {
	Name, Label, Branch, Domain, URL, EditURL string
	VPN, SSO, Up, Probed                      bool
	Memory, Rev, Frozen                       string
	First                                     bool
	Span                                      int
	Initial, Tint, Ink                        string
	Repo                                      string
	Job                                       *JobBadge
}

// SiteGroup : les lignes d'un site, filtrées ensemble.
type SiteGroup struct {
	Name        string
	Rows        []SiteRow
	Public, VPN bool
}

// sitesData : tableau et compteurs de la page Sites (aussi servis seuls, pour le rafraîchissement).
func (s *Server) sitesData(ctx context.Context, snap *Snapshot) map[string]any {
	up := s.probes(ctx)
	var groups []SiteGroup
	vpn, public, online, total := 0, 0, 0, 0
	running := false
	for _, name := range snap.Apps.Names() {
		e := snap.Apps.Entries[name]
		g := SiteGroup{Name: name}
		var job *JobBadge
		if j := s.jobs.latest(name); j != nil {
			job = badgeOf(j.Snapshot())
		}
		if job != nil && job.Kind == "running" {
			running = true
		}
		deploys := e.Deploys(name)
		for i, d := range deploys {
			r := s.row(name, e, d, snap, up)
			r.Repo = s.repoOf(ctx, e)
			r.First, r.Span = i == 0, len(deploys)
			if i == 0 {
				r.Job = job
			}
			g.Rows = append(g.Rows, r)
			g.VPN = g.VPN || r.VPN
			g.Public = g.Public || !r.VPN
			total++
			if r.Up {
				online++
			}
		}
		if g.VPN {
			vpn++
		}
		if g.Public {
			public++
		}
		groups = append(groups, g)
	}
	// Sites en cours d'ajout : pas encore dans apps.json, montrés à part.
	var adding []JobBadge
	for _, j := range s.jobs.all() {
		if _, ok := snap.Apps.Entries[j.App]; ok || !j.New {
			continue
		}
		if b := badgeOf(j); b != nil {
			adding = append(adding, *b)
			running = running || b.Kind == "running"
		}
	}
	// Une demande en cours : le tableau se rafraîchit plus souvent.
	every := 30
	if running {
		every = 5
	}
	return map[string]any{"Nav": "sites", "Groups": groups, "Adding": adding, "Every": every,
		"Sites": len(groups), "Total": total, "Online": online, "VPN": vpn, "Public": public}
}

func (s *Server) sites(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	data := s.sitesData(ctx, snap)
	data["State"] = s.stateCard(ctx, snap.Head)
	data["Activity"] = s.activity(ctx)
	s.render(w, "sites", data)
}

// fragment : un bloc de la page, rafraîchi par htmx sans recharger le reste.
func (s *Server) fragment(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	snap, err := s.snapshot(ctx)
	if err != nil {
		// Panne passagère (GitHub) : on garde l'affichage en place, nouvel essai au prochain tour.
		w.WriteHeader(http.StatusNoContent)
		return
	}
	switch r.PathValue("name") {
	case "state":
		s.render(w, "state-card", s.stateCard(ctx, snap.Head))
	case "cards":
		s.render(w, "site-cards", s.sitesData(ctx, snap))
	case "online":
		s.render(w, "online", s.sitesData(ctx, snap))
	case "activity":
		s.render(w, "activity", s.activity(ctx))
	case "status":
		name := r.URL.Query().Get("app")
		e, ok := snap.Apps.Entries[name]
		if !ok {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		up := s.probes(ctx)
		domain := domainOf(name, e, s.cfg.Domain)
		on, probed := up[domain]
		s.render(w, "site-status", map[string]any{"App": name, "Up": on, "Probed": probed})
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) row(name string, e Entry, d Deploy, snap *Snapshot, up map[string]bool) SiteRow {
	domain := d.Domain(s.cfg.Domain)
	tint, ink := colorsOf(name)
	r := SiteRow{
		Name: name, Label: d.Label, Branch: d.Branch, Domain: domain, URL: "https://" + domain,
		Initial: strings.ToUpper(name[:1]), Tint: tint, Ink: ink, VPN: d.VPN(), SSO: d.Access.SSO,
		EditURL: "/sites/" + name,
	}
	if d.Child {
		r.EditURL += "?env=" + d.ID
	}
	r.Up, r.Probed = up[domain]
	main := d.Ctrs.Containers[d.EntryPoint()]
	r.Memory = memoryLabel(main.Memory)
	if le, ok := snap.Lock[s.cfg.ref(main.Image)]; ok && le.Revision != nil && len(*le.Revision) >= 7 {
		r.Rev = (*le.Revision)[:7]
	}
	if d.Frozen() {
		r.Frozen = shortTag(d.Tag)
	} else if !d.Child && e.Version() == "" {
		r.Frozen = "mixte"
	}
	return r
}

func memoryLabel(m string) string {
	switch {
	case m == "":
		return "mémoire libre"
	case strings.HasSuffix(m, "m"):
		return strings.TrimSuffix(m, "m") + " Mo"
	case strings.HasSuffix(m, "g"):
		return strings.TrimSuffix(m, "g") + " Go"
	}
	return m
}

func shortTag(t string) string {
	if strings.HasPrefix(t, "sha-") && len(t) >= 11 {
		return t[4:11]
	}
	return t
}

const (
	iconCheck   = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M8 12l3 3 5-6"
	iconClock   = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2"
	iconWarn    = "M12 3l10 18H2zM12 10v4M12 17h.01"
	iconSync    = "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"
	iconImage   = "M21 8l-9-5-9 5 9 5zM3 8v8l9 5 9-5V8M12 13v8"
	iconSliders = "M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M16 4v4M10 10v4M18 16v4"
	iconBranch  = "M6 3v12M18 9a3 3 0 1 0 0-6a3 3 0 1 0 0 6M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6M18 9a9 9 0 0 1-9 9"
	iconQuest   = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.7M12 17h.01"
)

func (s *Server) stateCard(ctx context.Context, head string) StateCard {
	green, amber, red, blue, gray := [2]string{"#E9F8EF", "#15803D"}, [2]string{"#FEF3E2", "#9A4A07"}, [2]string{"#FDECEC", "#B42318"}, [2]string{"#EAEDFD", "#3B47C4"}, [2]string{"#F1F2F5", "#4A515D"}
	think := deployedRevision(ctx)
	c := StateCard{Think: shortRev(think), Main: shortRev(head)}
	set := func(title, chip, text, icon string, col [2]string) {
		c.Title, c.Chip, c.Text, c.Icon, c.Tint, c.Ink = title, chip, text, icon, col[0], col[1]
	}
	st, err := readDeployStatus(s.cfg.DeployStatus)
	switch {
	case err != nil || !st.Fresh():
		set("État inconnu", "inconnu", "apps-deploy ne passe plus : systemctl status apps-deploy.timer", iconQuest, gray)
	case think == head:
		set("think est à jour", "à jour", "", iconCheck, green)
	case st.State == "deploiement":
		set("Application en cours", "en cours", "", iconSync, blue)
	case st.State == "attente":
		set("Rebuild à faire", "en attente", "Pas que des sites sur main : rebuild à la main.", iconClock, amber)
	case st.State == "local":
		set("Version locale non commitée", "modifié", "Les sites attendent un rebuild propre.", iconWarn, red)
	case st.State == "non_pousse":
		set("Commits pas poussés", "à pousser", "git push, puis rebuild.", iconWarn, red)
	case st.State == "diverge":
		set("main a divergé", "à vérifier", "Rebuild à la main.", iconWarn, red)
	case st.State == "echec":
		set("Déploiement en échec", "échec", "L'ancienne version tourne : journalctl -u apps-deploy", iconWarn, red)
	default:
		set("main a avancé", "à appliquer", "Appliqué dans la minute.", iconSync, blue)
	}
	// Ce qui attend, seulement quand quelque chose attend : le dernier commit, et combien d'autres.
	if think != head && st != nil && st.Fresh() && len(st.Pending) > 0 && (st.State == "attente" || st.State == "diverge" || st.State == "echec") {
		last := st.Pending[len(st.Pending)-1]
		c.Pending = append(c.Pending, shortRev(last.SHA)+" "+last.Subject)
		if n := len(st.Pending) - 1; n > 0 {
			c.Pending = append(c.Pending, plural(n, "autre commit", "autres commits"))
		}
	}
	// Ligne calculée par apps-deploy contre un autre main que l'actuel (push dans la dernière minute) :
	// elle serait fausse, on attend son prochain passage.
	if st != nil && st.Checkout != nil && st.Head != head {
		c.Checkout, c.CheckoutInk = "vérification…", "#5D6573"
	} else if st != nil && st.Checkout != nil {
		co := st.Checkout
		var parts []string
		if co.Branch != "" && co.Branch != s.cfg.Branch {
			parts = append(parts, "sur la branche "+co.Branch)
		}
		if co.Modified > 0 {
			parts = append(parts, plural(co.Modified, "fichier modifié", "fichiers modifiés"))
		}
		if co.Untracked > 0 {
			parts = append(parts, plural(co.Untracked, "fichier non suivi", "fichiers non suivis"))
		}
		if co.Ahead != nil && *co.Ahead > 0 {
			parts = append(parts, plural(*co.Ahead, "commit pas poussé", "commits pas poussés"))
		}
		if co.Behind != nil && *co.Behind > 0 {
			parts = append(parts, plural(*co.Behind, "commit en retard", "commits en retard"))
		}
		if len(parts) == 0 {
			c.Checkout, c.CheckoutInk = "propre", "#15803D"
		} else {
			c.Checkout, c.CheckoutInk = strings.Join(parts, ", "), "#9A4A07"
		}
	}
	return c
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}

func shortRev(r string) string {
	if len(r) >= 7 && !strings.HasSuffix(r, "-dirty") {
		return r[:7]
	}
	if strings.HasSuffix(r, "-dirty") && len(r) >= 7 {
		return r[:7] + "-dirty"
	}
	if r == "" {
		return "?"
	}
	return r
}

// activity : derniers commits qui touchent apps.json (réglages) ou le lock (images), par jour.
func (s *Server) activity(ctx context.Context) []ActivityDay {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	seen := map[string]int{}
	var all []Commit
	for _, path := range []string{appsPath, lockPath} {
		commits, err := s.gh.Commits(ctx, path)
		if err != nil {
			continue
		}
		all = append(all, commits...)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].Date.After(all[j].Date) })
	var items []Commit
	for _, c := range all {
		if i, ok := seen[c.SHA]; ok {
			if c.Path == appsPath {
				items[i].Path = appsPath
			}
			continue
		}
		seen[c.SHA] = len(items)
		items = append(items, c)
		if len(items) == 10 {
			break
		}
	}
	var days []ActivityDay
	for _, c := range items {
		date := c.Date.Local()
		label := frenchDay(date)
		if len(days) == 0 || days[len(days)-1].Label != label {
			days = append(days, ActivityDay{Label: label})
		}
		it := describeCommit(c.Subject, c.Path == appsPath)
		it.Rev, it.Time = c.SHA[:7], date.Format("15:04")
		it.URL = "https://github.com/" + s.cfg.Repo + "/commit/" + c.SHA
		d := &days[len(days)-1]
		d.Items = append(d.Items, it)
	}
	return days
}

var reSubject = regexp.MustCompile(`^[a-z]+(?:\(([^)]*)\))?!?: (.+)$`)

// describeCommit : site, description et type d'un commit de sites (`feat(myetf): make public`,
// `chore(apps): bump myetf (481f826)`) ; un message libre reste tel quel.
func describeCommit(subject string, config bool) ActivityItem {
	it := ActivityItem{What: subject, Kind: "nouvelle image", Icon: iconImage, Ink: "#15803D"}
	if config {
		it.Kind, it.Icon, it.Ink = "réglages", iconSliders, "#3B47C4"
	}
	m := reSubject.FindStringSubmatch(subject)
	if m == nil {
		return it
	}
	scope, rest := m[1], m[2]
	if bump, ok := strings.CutPrefix(rest, "bump "); ok && scope == "apps" {
		names, _, _ := strings.Cut(bump, " (")
		it.Name, it.What = names, "mis à jour"
		return it
	}
	if scope != "" && scope != "apps" {
		it.Name, it.What = scope, rest
	}
	if config && strings.Contains(rest, "environment") {
		it.Kind, it.Icon, it.Ink = "environnement", iconBranch, "#9A4A07"
	}
	return it
}

var (
	frDays   = []string{"dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"}
	frMonths = []string{"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"}
)

// frenchDay : « aujourd'hui », « hier », ou « jeudi 22 octobre ».
func frenchDay(t time.Time) string {
	now := time.Now()
	y1, m1, d1 := t.Date()
	y2, m2, d2 := now.Date()
	switch {
	case y1 == y2 && m1 == m2 && d1 == d2:
		return "aujourd'hui"
	case now.AddDate(0, 0, -1).Format("2006-01-02") == t.Format("2006-01-02"):
		return "hier"
	}
	return fmt.Sprintf("%s %d %s", frDays[t.Weekday()], t.Day(), frMonths[t.Month()-1])
}

var funcs = template.FuncMap{
	"short": shortRev,
	"lower": strings.ToLower,
	"join":  strings.Join,
	"add":   func(a, b int) int { return a + b },
	// args : paramètres nommés d'un sous-template (`{{template "dd" (args "D" .Branch "URL" $.FormURL)}}`).
	"args": func(kv ...any) map[string]any {
		m := map[string]any{}
		for i := 0; i+1 < len(kv); i += 2 {
			m[kv[i].(string)] = kv[i+1]
		}
		return m
	},
	"status": func(app string, up, probed bool) map[string]any {
		return map[string]any{"App": app, "Up": up, "Probed": probed}
	},
	// Logo GitHub (Octicons, MIT), en un seul tracé rempli.
	"githubMark": func() string {
		return "M12 .5C5.7.5.5 5.7.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.3.8-.6v-2c-3.2.7-3.9-1.4-3.9-1.4-.5-1.3-1.3-1.7-1.3-1.7-1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.7-1.5-2.6-.3-5.2-1.3-5.2-5.7 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3 0 0 1-.3 3.2 1.2a11 11 0 0 1 5.8 0c2.2-1.5 3.2-1.2 3.2-1.2.6 1.6.2 2.8.1 3 .7.8 1.2 1.8 1.2 3.1 0 4.4-2.7 5.4-5.3 5.7.4.4.8 1.1.8 2.1v3.2c0 .3.2.7.8.6A11.5 11.5 0 0 0 23.5 12C23.5 5.7 18.3.5 12 .5z"
	},
}

// repoOf : dépôt GitHub d'un site (label de son image), gardé 10 minutes : le tableau se
// rafraîchit souvent, le dépôt ne change pas.
func (s *Server) repoOf(ctx context.Context, e Entry) string {
	if s.gh == nil || s.reg == nil {
		return ""
	}
	ref := s.cfg.ref(e.Containers[e.EntryPoint()].Image)
	v, err := s.gh.cached("repo:"+ref, 10*time.Minute, func() (any, error) { return s.sourceRepo(ctx, e), nil })
	if err != nil {
		return ""
	}
	return v.(string)
}
