package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Onglet Mises à jour, en lecture seule : ce que `update` changerait, sans rien modifier. Le
// dashboard calcule un flake.lock à jour dans un fichier à part, évalue l'inventaire de think avec
// (cf. ../inventory.nix), et le compare à celui de la génération active (/etc/dotfiles). Une fois
// par jour, avec un récapitulatif sur Discord.

// updatesHour : l'heure de la vérification quotidienne (et du récapitulatif).
const updatesHour = 7

// InvItem : un paquet de l'inventaire.
type InvItem struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"` // service ou base
	Pname     string `json:"pname"`
	Version   string `json:"version"`
	Changelog string `json:"changelog"`
	Homepage  string `json:"homepage"`
}

// InputRow : une entrée du flake, avant et après la mise à jour.
type InputRow struct {
	Name, From, To, Compare string
	Days                    int
	Changed                 bool
}

type updatesResult struct {
	Checked time.Time  `json:"checked"`
	Head    string     `json:"head"`
	Next    []InvItem  `json:"next"`
	Inputs  []InputRow `json:"inputs"`
	Error   string     `json:"error"`
}

var updatesState struct {
	sync.Mutex
	running bool
}

func (s *Server) updatesFile() string { return filepath.Join(s.cfg.StateDir, "updates.json") }

func (s *Server) readUpdates() updatesResult {
	var r updatesResult
	if b, err := os.ReadFile(s.updatesFile()); err == nil {
		_ = json.Unmarshal(b, &r)
	}
	return r
}

func (s *Server) currentInventory() ([]InvItem, error) {
	var inv []InvItem
	b, err := os.ReadFile(s.cfg.Inventory)
	if err != nil {
		return nil, err
	}
	return inv, json.Unmarshal(b, &inv)
}

// lockNode : ce qu'on lit d'un nœud de flake.lock.
type lockNode struct {
	Locked struct {
		Type, Owner, Repo, Rev string
		LastModified           int64 `json:"lastModified"`
	} `json:"locked"`
}

type flakeLock struct {
	Nodes map[string]struct {
		Inputs map[string]json.RawMessage `json:"inputs"`
		lockNode
	} `json:"nodes"`
	Root string `json:"root"`
}

// bumpable : les entrées que `update` met à jour (cf. scripts/lib/flake-lock.sh) : celles de la
// racine qui ne suivent pas une autre, sauf `secrets` (son lock ne bouge que par commit explicite).
func bumpable(lock flakeLock) map[string]string {
	out := map[string]string{}
	for name, raw := range lock.Nodes[lock.Root].Inputs {
		var node string
		if json.Unmarshal(raw, &node) == nil && name != "secrets" {
			out[name] = node
		}
	}
	return out
}

// Updates : le flake.lock à jour (dans un fichier à part) et l'inventaire de think évalué avec.
func (ev *Evaluator) Updates(ctx context.Context, head string) (oldLock, newLock []byte, inv []InvItem, err error) {
	ev.mu.Lock()
	defer ev.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 12*time.Minute)
	defer cancel()
	if err := ev.checkout(ctx, head); err != nil {
		return nil, nil, nil, err
	}
	dir := ev.dir()
	if oldLock, err = os.ReadFile(filepath.Join(dir, "flake.lock")); err != nil {
		return nil, nil, nil, err
	}
	var lock flakeLock
	if err := json.Unmarshal(oldLock, &lock); err != nil {
		return nil, nil, nil, fmt.Errorf("flake.lock illisible : %w", err)
	}
	var names []string
	for name := range bumpable(lock) {
		names = append(names, name)
	}
	sort.Strings(names)
	// Un dossier jetable, supprimé à la fin : le nouveau lock et le cache de téléchargement de nix.
	// Dans /nix/store, seules les sources téléchargées restent, sans racine : le GC hebdomadaire les
	// retire (et un `update` fait entre-temps les réutilise).
	tmp, err := os.MkdirTemp(ev.cfg.StateDir, "updates-")
	if err != nil {
		return nil, nil, nil, err
	}
	defer os.RemoveAll(tmp)
	env := append(ev.env(), "XDG_CACHE_HOME="+filepath.Join(tmp, "cache"))
	out := filepath.Join(tmp, "flake.lock")
	flake := "git+file://" + dir
	args := append([]string{"flake", "update"}, names...)
	args = append(args, "--flake", flake, "--output-lock-file", out)
	if _, msgs, err := ev.runJSON(ctx, env, "nix", args...); err != nil {
		return nil, nil, nil, fmt.Errorf("nix flake update : %s", lastLines(msgs, 3))
	}
	if newLock, err = os.ReadFile(out); err != nil {
		return nil, nil, nil, err
	}
	attr := flake + "#nixosConfigurations." + ev.cfg.Target + ".config.systemSettings.admin.inventory"
	o, msgs, err := ev.runJSON(ctx, env, "nix", "eval", "--json", "--reference-lock-file", out, attr)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil, nil, nil, errors.New("évaluation trop longue (plus de 12 minutes)")
	}
	if err != nil {
		return nil, nil, nil, errors.New(evalError(msgs))
	}
	if err := json.Unmarshal(o, &inv); err != nil {
		return nil, nil, nil, fmt.Errorf("inventaire illisible : %w", err)
	}
	return oldLock, newLock, inv, nil
}

// runJSON : comme run, dans l'environnement donné, la sortie à part des messages (avertissements,
// erreurs).
func (ev *Evaluator) runJSON(ctx context.Context, env []string, name string, args ...string) (stdout, msgs []byte, err error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err = cmd.Run()
	return out.Bytes(), errOut.Bytes(), err
}

// inputRows : l'écart de chaque entrée du flake entre les deux locks.
func inputRows(oldLock, newLock []byte) []InputRow {
	var a, b flakeLock
	if json.Unmarshal(oldLock, &a) != nil || json.Unmarshal(newLock, &b) != nil {
		return nil
	}
	day := func(t int64) string { return time.Unix(t, 0).Local().Format("02/01/2006") }
	var rows []InputRow
	for name, node := range bumpable(a) {
		o, n := a.Nodes[node].Locked, b.Nodes[bumpable(b)[name]].Locked
		row := InputRow{Name: name, From: day(o.LastModified), To: day(n.LastModified), Changed: o.Rev != n.Rev,
			Days: int(time.Unix(n.LastModified, 0).Sub(time.Unix(o.LastModified, 0)).Hours() / 24)}
		if row.Changed && o.Type == "github" {
			row.Compare = fmt.Sprintf("https://github.com/%s/%s/compare/%s...%s", o.Owner, o.Repo, o.Rev, n.Rev)
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Changed != rows[j].Changed {
			return rows[i].Changed
		}
		return rows[i].Name < rows[j].Name
	})
	return rows
}

// checkUpdates : une vérification complète, gardée sur disque ; `notify` : récapitulatif Discord.
func (s *Server) checkUpdates(ctx context.Context, notify bool) {
	updatesState.Lock()
	if updatesState.running {
		updatesState.Unlock()
		return
	}
	updatesState.running = true
	updatesState.Unlock()
	defer func() {
		updatesState.Lock()
		updatesState.running = false
		updatesState.Unlock()
	}()

	res := updatesResult{Checked: time.Now()}
	head, err := s.gh.Head(ctx)
	if err == nil {
		res.Head = head
		var oldLock, newLock []byte
		oldLock, newLock, res.Next, err = s.eval.Updates(ctx, head)
		res.Inputs = inputRows(oldLock, newLock)
	}
	if err != nil {
		res.Error = err.Error()
	}
	if b, err := json.Marshal(res); err == nil {
		_ = os.WriteFile(s.updatesFile(), b, 0o644)
	}
	if notify {
		s.postUpdates(ctx, res)
	}
}

// updatesLoop : la vérification quotidienne, à updatesHour (tout de suite s'il n'y en a jamais eu).
func (s *Server) updatesLoop(ctx context.Context) {
	for {
		last := s.readUpdates().Checked
		now := time.Now()
		due := time.Date(now.Year(), now.Month(), now.Day(), updatesHour, 0, 0, 0, time.Local)
		if now.Before(due) {
			due = due.AddDate(0, 0, -1)
		}
		if last.Before(due) {
			s.checkUpdates(ctx, true)
		}
		if !sleep(ctx, 15*time.Minute) {
			return
		}
	}
}

// UpdateRow : un paquet, en service et après la mise à jour.
type UpdateRow struct {
	ID, Name, Kind      string
	Current, Next       string
	Change, ChangeLabel string // major, minor, patch, same, new, gone, other
	Changelog, Homepage string
	Running             string // le noyau qui tourne (uname), s'il diffère
}

var reVersionPart = regexp.MustCompile(`\d+`)

// versionChange : majeure (premier nombre), mineure (deuxième), correctif (le reste), ou autre.
func versionChange(a, b string) string {
	if a == b {
		return "same"
	}
	pa, pb := reVersionPart.FindAllString(a, 3), reVersionPart.FindAllString(b, 3)
	if len(pa) == 0 || len(pb) == 0 {
		return "other"
	}
	for i := 0; i < 3; i++ {
		x, y := "0", "0"
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		xi, _ := strconv.Atoi(x)
		yi, _ := strconv.Atoi(y)
		if xi != yi {
			return []string{"major", "minor", "patch"}[i]
		}
	}
	return "patch"
}

var changeLabels = map[string]string{"major": "majeure", "minor": "mineure", "patch": "correctif", "same": "à jour",
	"new": "nouveau", "gone": "retiré", "other": "changée"}

// changeOrder : les plus importants d'abord.
var changeOrder = map[string]int{"major": 0, "minor": 1, "patch": 2, "other": 3, "new": 4, "gone": 5, "same": 6}

func updateRows(cur, next []InvItem) []UpdateRow {
	byID := map[string]InvItem{}
	for _, it := range next {
		byID[it.ID] = it
	}
	seen := map[string]bool{}
	var rows []UpdateRow
	add := func(c, n *InvItem) {
		it := c
		if it == nil {
			it = n
		}
		r := UpdateRow{ID: it.ID, Name: it.Pname, Kind: it.Kind, Changelog: it.Changelog, Homepage: it.Homepage}
		switch {
		case c == nil:
			r.Next, r.Change = n.Version, "new"
		case n == nil:
			r.Current, r.Change = c.Version, "gone"
		default:
			r.Current, r.Next, r.Change = c.Version, n.Version, versionChange(c.Version, n.Version)
			r.Changelog, r.Homepage = firstOf(n.Changelog, c.Changelog), firstOf(n.Homepage, c.Homepage)
		}
		if r.ID == "nixpkgs" && r.Change != "same" && r.Change != "new" && r.Change != "gone" {
			r.Change = "other"
		}
		r.ChangeLabel = changeLabels[r.Change]
		rows = append(rows, r)
	}
	for i := range cur {
		c := cur[i]
		seen[c.ID] = true
		if n, ok := byID[c.ID]; ok {
			add(&c, &n)
		} else if next != nil {
			add(&c, nil)
		} else {
			add(&c, &c)
		}
	}
	for i := range next {
		if !seen[next[i].ID] {
			n := next[i]
			add(nil, &n)
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if changeOrder[rows[i].Change] != changeOrder[rows[j].Change] {
			return changeOrder[rows[i].Change] < changeOrder[rows[j].Change]
		}
		return rows[i].Name < rows[j].Name
	})
	return rows
}

// runningKernel : le noyau qui tourne (redémarrage en attente s'il diffère de la génération active).
func runningKernel() string {
	b, _ := os.ReadFile("/proc/sys/kernel/osrelease")
	return strings.TrimSpace(string(b))
}

func (s *Server) updates(w http.ResponseWriter, r *http.Request) {
	res := s.readUpdates()
	cur, curErr := s.currentInventory()
	rows := updateRows(cur, res.Next)
	if res.Next == nil {
		for i := range rows {
			rows[i].Next, rows[i].Change, rows[i].ChangeLabel = "", "", ""
		}
	}
	var services, base []UpdateRow
	counts := map[string]int{}
	for _, row := range rows {
		if row.ID == "boot.kernel" {
			if k := runningKernel(); k != "" && !strings.HasPrefix(k, row.Current) {
				row.Running = k
			}
		}
		if row.Change != "" && row.Change != "same" {
			counts["changed"]++
			counts[row.Change]++
		}
		if row.Kind == "base" {
			base = append(base, row)
		} else {
			services = append(services, row)
		}
	}
	updatesState.Lock()
	running := updatesState.running
	updatesState.Unlock()
	data := map[string]any{"Nav": "updates", "Services": services, "Base": base, "Inputs": res.Inputs, "Counts": counts,
		"Running": running, "Error": res.Error, "Hour": updatesHour, "Discord": s.cfg.DiscordHook != ""}
	if !res.Checked.IsZero() {
		data["Checked"] = ago(time.Since(res.Checked))
		data["Head"] = shortRev(res.Head)
	}
	if curErr != nil {
		data["CurError"] = "Versions en service illisibles (" + s.cfg.Inventory + ") : la génération active date d'avant cet onglet, un rebuild la crée."
	}
	if r.Header.Get("HX-Request") == "true" && r.URL.Query().Has("frag") {
		s.render(w, "updates-body", data)
		return
	}
	s.render(w, "updates", data)
}

// updatesCheck : « Vérifier maintenant » (sans récapitulatif Discord, réservé à la vérification du jour).
func (s *Server) updatesCheck(w http.ResponseWriter, r *http.Request) {
	go s.checkUpdates(context.Background(), false)
	// Le temps que la vérification se marque en cours avant de relire la page.
	time.Sleep(200 * time.Millisecond)
	http.Redirect(w, r, "/updates", http.StatusSeeOther)
}

// postUpdates : le récapitulatif sur Discord (ce qui change, le plus important d'abord).
func (s *Server) postUpdates(ctx context.Context, res updatesResult) {
	if s.cfg.DiscordHook == "" {
		return
	}
	host := machineName
	link := "https://" + s.cfg.Host + "/updates"
	var b strings.Builder
	switch {
	case res.Error != "":
		fmt.Fprintf(&b, "⚠️ **%s** : vérification des mises à jour impossible.\n`%s`\n%s", host, lastLine(res.Error), link)
	default:
		cur, _ := s.currentInventory()
		var changed []UpdateRow
		for _, row := range updateRows(cur, res.Next) {
			if row.Change != "same" {
				changed = append(changed, row)
			}
		}
		if len(changed) == 0 {
			fmt.Fprintf(&b, "✅ **%s** est à jour : `update` ne changerait aucune version.", host)
			break
		}
		fmt.Fprintf(&b, "🔄 **%s** : %s avec `update`.\n", host, plural(len(changed), "version changerait", "versions changeraient"))
		for i, row := range changed {
			if i == 12 {
				fmt.Fprintf(&b, "… et %d autres\n", len(changed)-12)
				break
			}
			from, to := firstOf(row.Current, "—"), firstOf(row.Next, "—")
			extra := ""
			if row.ID == "boot.kernel" {
				extra = ", redémarrage"
			}
			fmt.Fprintf(&b, "• **%s** %s → %s (%s%s)\n", row.Name, from, to, row.ChangeLabel, extra)
		}
		for _, in := range res.Inputs {
			if in.Changed {
				fmt.Fprintf(&b, "• entrée `%s` : %s → %s\n", in.Name, in.From, in.To)
			}
		}
		fmt.Fprintf(&b, "Rien n'est appliqué : sur think, `update` puis `rebuild`. %s", link)
	}
	msg := b.String()
	if len(msg) > 1900 {
		msg = msg[:1900] + "…"
	}
	body, _ := json.Marshal(map[string]any{"content": msg, "flags": 4})
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.DiscordHook, bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	if resp, err := http.DefaultClient.Do(req); err == nil {
		resp.Body.Close()
	}
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}
