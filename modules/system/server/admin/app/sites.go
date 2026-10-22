package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"html/template"
	"net/http"
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

type SiteCard struct {
	Name, Domain, URL, Initial, Tint, Ink string
	VPN, SSO, Up, Probed                  bool
	Containers                            string
	Memory                                string
	Rev                                   string
	Frozen                                string
}

type StateCard struct {
	Title, Chip, Text, Tint, Ink, Icon string
	Think, Main                        string
	Pending                            []string
	Checkout                           string
	CheckoutInk                        string
}

type ActivityItem struct {
	Subject, Rev, When, URL string
	Config                  bool
}

func (s *Server) sites(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	up := probes(ctx, s.cfg.Prometheus)
	var cards []SiteCard
	vpn := 0
	for _, name := range snap.Apps.Names() {
		e := snap.Apps.Entries[name]
		cards = append(cards, s.card(name, e, snap, up))
		if e.VPN() {
			vpn++
		}
	}
	online := 0
	for _, c := range cards {
		if c.Up {
			online++
		}
	}
	s.render(w, "sites", map[string]any{
		"Nav": "sites", "Cards": cards, "Total": len(cards), "Online": online, "VPN": vpn, "Public": len(cards) - vpn,
		"State": s.stateCard(ctx, snap.Head), "Activity": s.activity(ctx),
	})
}

func (s *Server) card(name string, e Entry, snap *Snapshot, up map[string]bool) SiteCard {
	domain := domainOf(name, e, s.cfg.Domain)
	tint, ink := colorsOf(name)
	c := SiteCard{
		Name: name, Domain: domain, URL: "https://" + domain, Initial: strings.ToUpper(name[:1]),
		Tint: tint, Ink: ink, VPN: e.VPN(), SSO: e.SSO,
	}
	c.Up, c.Probed = up[domain]
	if n := len(e.Containers); n > 1 {
		c.Containers = fmt.Sprintf("%d conteneurs", n)
	} else {
		c.Containers = "1 conteneur"
	}
	main := e.Containers[e.EntryPoint()]
	c.Memory = memoryLabel(main.Memory)
	img, _ := splitImage(main.Image)
	c.Rev = img
	if le, ok := snap.Lock[s.cfg.ref(main.Image)]; ok && le.Revision != nil && len(*le.Revision) >= 7 {
		c.Rev += " · " + (*le.Revision)[:7]
	}
	if v := e.Version(); v != "" && v != "main" {
		c.Frozen = shortTag(v)
	} else if v == "" {
		c.Frozen = "mixte"
	}
	return c
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
	iconCheck = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M8 12l3 3 5-6"
	iconClock = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2"
	iconWarn  = "M12 3l10 18H2zM12 10v4M12 17h.01"
	iconSync  = "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"
	iconQuest = "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.7M12 17h.01"
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
		set("État d'apps-deploy inconnu", "inconnu", "Aucun passage récent d'apps-deploy : systemctl status apps-deploy.timer.", iconQuest, gray)
	case think == head:
		set("think est à jour", "à jour", "Il tourne exactement le dernier commit de main.", iconCheck, green)
	case st.State == "deploiement":
		set("Changements de sites en cours d'application", "en cours", "apps-deploy active le dernier commit de main.", iconSync, blue)
	case st.State == "attente":
		set("Des commits attendent ton rebuild", "rebuild à faire", "main contient d'autres changements que des sites : think ne les applique pas seul.", iconClock, amber)
	case st.State == "local":
		set("Version locale non commitée", "modifié", "Tu as rebuildé avec des changements non commités : les sites ne se mettent plus à jour seuls jusqu'au prochain rebuild propre.", iconWarn, red)
	case st.State == "non_pousse":
		set("Commits pas encore poussés", "à pousser", "think tourne une version que GitHub ne connaît pas : git push, puis rebuild.", iconWarn, red)
	case st.State == "diverge":
		set("main a divergé", "à vérifier", "main n'est plus dans la lignée de la version de think : rebuild à la main.", iconWarn, red)
	case st.State == "echec":
		set("Le dernier déploiement a échoué", "échec", "La version d'avant tourne toujours : journalctl -u apps-deploy.", iconWarn, red)
	default:
		set("main a avancé", "à appliquer", "apps-deploy le traitera à son prochain passage, dans la minute.", iconSync, blue)
	}
	if st != nil && st.Fresh() && (st.State == "attente" || st.State == "diverge" || st.State == "echec") {
		for _, p := range st.Pending {
			c.Pending = append(c.Pending, shortRev(p.SHA)+" "+p.Subject)
		}
	}
	if st != nil && st.Checkout != nil {
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
			c.Checkout, c.CheckoutInk = "propre, à jour avec main", "#15803D"
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

// activity : derniers commits qui touchent apps.json (réglages) ou le lock (images).
func (s *Server) activity(ctx context.Context) []ActivityItem {
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
	var out []ActivityItem
	for _, c := range all {
		if i, ok := seen[c.SHA]; ok {
			out[i].Config = out[i].Config || c.Path == appsPath
			continue
		}
		out = append(out, ActivityItem{
			Subject: c.Subject, Rev: c.SHA[:7], When: c.Date.Local().Format("02/01 15:04"),
			URL: "https://github.com/" + s.cfg.Repo + "/commit/" + c.SHA, Config: c.Path == appsPath,
		})
		seen[c.SHA] = len(out) - 1
		if len(out) == 10 {
			break
		}
	}
	return out
}

var funcs = template.FuncMap{
	"short": shortRev,
	"lower": strings.ToLower,
	"join":  strings.Join,
	"add":   func(a, b int) int { return a + b },
	// Logo GitHub (Octicons, MIT), en un seul tracé rempli.
	"githubMark": func() string {
		return "M12 .5C5.7.5.5 5.7.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.3.8-.6v-2c-3.2.7-3.9-1.4-3.9-1.4-.5-1.3-1.3-1.7-1.3-1.7-1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.7-1.5-2.6-.3-5.2-1.3-5.2-5.7 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3 0 0 1-.3 3.2 1.2a11 11 0 0 1 5.8 0c2.2-1.5 3.2-1.2 3.2-1.2.6 1.6.2 2.8.1 3 .7.8 1.2 1.8 1.2 3.1 0 4.4-2.7 5.4-5.3 5.7.4.4.8 1.1.8 2.1v3.2c0 .3.2.7.8.6A11.5 11.5 0 0 0 23.5 12C23.5 5.7 18.3.5 12 .5z"
	},
}
