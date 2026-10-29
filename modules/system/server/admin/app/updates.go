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

// InvItem : un paquet de l'inventaire, ou une entrée du flake (kind input : version = révision).
type InvItem struct {
	ID           string `json:"id"`
	Kind         string `json:"kind"` // service, base ou input
	LastModified int64  `json:"lastModified"`
	Pname        string `json:"pname"`
	Version      string `json:"version"`
	Changelog    string `json:"changelog"`
	Homepage     string `json:"homepage"`
	Src          string `json:"src"`    // d'où vient le code (dépôt, archive)
	Source       string `json:"source"` // l'entrée du flake qui le fournit (self : ce dépôt)
}

// InputRow : une entrée du flake : en service, sur main, après update ; les commits d'écart entre
// la révision en service et celle d'après update (GitHub, au moment de la vérification).
type InputRow struct {
	Name, Owner, Repo            string
	ServiceRev, MainRev, NextRev string
	ServiceAt, MainAt, NextAt    int64
	Commits                      int // -1 : inconnu
	CommitsFrom                  string
	AI                           *Analysis `json:"-"`
}

// Day : une date de révision (« 25/10/2026 »), ou rien.
func (InputRow) Day(t int64) string {
	if t == 0 {
		return ""
	}
	return time.Unix(t, 0).Local().Format("02/01/2006")
}

// Changed : update change cette entrée par rapport à ce qui tourne.
func (r InputRow) Changed() bool {
	return r.NextRev != "" && r.NextRev != firstOf(r.ServiceRev, r.MainRev)
}

// Pending : main a déjà une autre révision que ce qui tourne (git pull et rebuild suffisent).
func (r InputRow) Pending() bool { return r.ServiceRev != "" && r.MainRev != r.ServiceRev }

// Compare : les changements sur GitHub, de ce qui tourne à après update.
func (r InputRow) Compare() string {
	if r.Owner == "" || !r.Changed() {
		return ""
	}
	return fmt.Sprintf("https://github.com/%s/%s/compare/%s...%s", r.Owner, r.Repo, firstOf(r.ServiceRev, r.MainRev), r.NextRev)
}

type updatesResult struct {
	Checked time.Time  `json:"checked"`
	Head    string     `json:"head"`
	Main    []InvItem  `json:"main"`
	Next    []InvItem  `json:"next"`
	Inputs  []InputRow `json:"inputs"`
	Error   string     `json:"error"`
	AIError string     `json:"aiError"` // l'analyse par l'IA a échoué (le reste de la vérification tient)
	// Releases : la page GitHub de chaque version vue (clé releaseKey), trouvée à la vérification.
	Releases map[string]string `json:"releases"`
}

func releaseKey(name, version string) string { return name + "|" + version }

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
		Type, Owner, Repo, Rev, URL string
		LastModified                int64 `json:"lastModified"`
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
func (ev *Evaluator) Updates(ctx context.Context, head string) (oldLock, newLock []byte, main, next []InvItem, err error) {
	ev.mu.Lock()
	defer ev.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 12*time.Minute)
	defer cancel()
	if err := ev.checkout(ctx, head); err != nil {
		return nil, nil, nil, nil, err
	}
	dir := ev.dir()
	if oldLock, err = os.ReadFile(filepath.Join(dir, "flake.lock")); err != nil {
		return nil, nil, nil, nil, err
	}
	var lock flakeLock
	if err := json.Unmarshal(oldLock, &lock); err != nil {
		return nil, nil, nil, nil, fmt.Errorf("flake.lock illisible : %w", err)
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
		return nil, nil, nil, nil, err
	}
	defer os.RemoveAll(tmp)
	env := append(ev.env(), "XDG_CACHE_HOME="+filepath.Join(tmp, "cache"))
	out := filepath.Join(tmp, "flake.lock")
	flake := "git+file://" + dir
	args := append([]string{"flake", "update"}, names...)
	args = append(args, "--flake", flake, "--output-lock-file", out)
	if _, msgs, err := ev.runJSON(ctx, env, "nix", args...); err != nil {
		return nil, nil, nil, nil, fmt.Errorf("nix flake update : %s", lastLines(msgs, 3))
	}
	if newLock, err = os.ReadFile(out); err != nil {
		return nil, nil, nil, nil, err
	}
	// Sur main (son flake.lock tel quel), puis après update (le lock à jour).
	attr := flake + "#nixosConfigurations." + ev.cfg.Target + ".config.systemSettings.admin.inventory"
	for _, step := range []struct {
		inv  *[]InvItem
		args []string
	}{{&main, nil}, {&next, []string{"--reference-lock-file", out}}} {
		o, msgs, err := ev.runJSON(ctx, env, "nix", append(append([]string{"eval", "--json"}, step.args...), attr)...)
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, nil, nil, nil, errors.New("évaluation trop longue (plus de 12 minutes)")
		}
		if err != nil {
			return nil, nil, nil, nil, errors.New(evalError(msgs))
		}
		if err := json.Unmarshal(o, step.inv); err != nil {
			return nil, nil, nil, nil, fmt.Errorf("inventaire illisible : %w", err)
		}
	}
	return oldLock, newLock, main, next, nil
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

// reGitHubURL : un dépôt GitHub pris par git (`git+https://github.com/<owner>/<repo>`).
var reGitHubURL = regexp.MustCompile(`^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$`)

// githubRepo : le dépôt GitHub d'une entrée (type github, ou git sur github.com), sinon rien.
func githubRepo(typ, owner, repo, url string) (string, string) {
	if typ == "github" {
		return owner, repo
	}
	if m := reGitHubURL.FindStringSubmatch(url); typ == "git" && m != nil {
		return m[1], m[2]
	}
	return "", ""
}

// inputRows : chaque entrée que update met à jour, en service, sur main et après update.
func inputRows(cur, main, next []InvItem, oldLock []byte) []InputRow {
	var lock flakeLock
	_ = json.Unmarshal(oldLock, &lock)
	at := func(inv []InvItem, name string) (string, int64) {
		for _, it := range inv {
			if it.Kind == "input" && it.Pname == name {
				return it.Version, it.LastModified
			}
		}
		return "", 0
	}
	var rows []InputRow
	for name, node := range bumpable(lock) {
		l := lock.Nodes[node].Locked
		row := InputRow{Name: name, Commits: -1}
		row.Owner, row.Repo = githubRepo(l.Type, l.Owner, l.Repo, l.URL)
		row.ServiceRev, row.ServiceAt = at(cur, name)
		row.MainRev, row.MainAt = at(main, name)
		row.NextRev, row.NextAt = at(next, name)
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Changed() != rows[j].Changed() {
			return rows[i].Changed()
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
		var oldLock []byte
		oldLock, _, res.Main, res.Next, err = s.eval.Updates(ctx, head)
		cur, _ := s.currentInventory()
		res.Inputs = inputRows(cur, res.Main, res.Next, oldLock)
		for i := range res.Inputs {
			in := &res.Inputs[i]
			if in.Changed() && in.Owner != "" {
				from := firstOf(in.ServiceRev, in.MainRev)
				if n, err := s.gh.CompareCount(ctx, in.Owner, in.Repo, from, in.NextRev); err == nil {
					in.Commits, in.CommitsFrom = n, from
				}
			}
		}
		if err == nil {
			rows := updateRows(cur, res.Main, res.Next)
			res.Releases = s.releaseLinks(ctx, rows)
			var errs []string
			for _, e := range []error{s.analyze(ctx, rows), s.analyzeInputs(ctx, res.Inputs, rows)} {
				if e != nil {
					errs = append(errs, e.Error())
				}
			}
			res.AIError = strings.Join(errs, " ; ")
		}
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
	Current, Main, Next string // en service, sur main, après update
	Change, ChangeLabel string // major, minor, patch, same, new, gone, other
	Changelog, Homepage string
	Src                 string // d'où vient le code
	Release             string // la release GitHub de la version qui compte (après update, sinon en service)
	Source              string // nixpkgs-stable, nixpkgs-unstable, ce dépôt…
	Running             string // le noyau qui tourne (uname), s'il diffère
	AI                  *Analysis
}

// sourceLabel : l'entrée du flake lisiblement (self : ce dépôt).
func sourceLabel(s string) string {
	if s == "self" {
		return "ce dépôt"
	}
	return s
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

// updateRows : chaque paquet en service, sur main et après update (sans les entrées du flake,
// listées à part) ; le changement compare ce qui tourne à après update. Sans vérification
// (`next` vide), seule la colonne en service est remplie.
func updateRows(cur, main, next []InvItem) []UpdateRow {
	index := func(inv []InvItem) map[string]InvItem {
		m := map[string]InvItem{}
		for _, it := range inv {
			if it.Kind != "input" && it.ID != "nixpkgs" {
				m[it.ID] = it
			}
		}
		return m
	}
	c, m, n := index(cur), index(main), index(next)
	ids := map[string]bool{}
	for _, set := range []map[string]InvItem{c, m, n} {
		for id := range set {
			ids[id] = true
		}
	}
	var rows []UpdateRow
	for id := range ids {
		ci, inCur := c[id]
		mi, inMain := m[id]
		ni, inNext := n[id]
		it := ni
		for _, x := range []struct {
			it InvItem
			ok bool
		}{{ni, inNext}, {mi, inMain}, {ci, inCur}} {
			if x.ok {
				it = x.it
				break
			}
		}
		r := UpdateRow{ID: id, Name: it.Pname, Kind: it.Kind, Changelog: firstOf(it.Changelog, ci.Changelog), Homepage: firstOf(it.Homepage, ci.Homepage),
			Src:    firstOf(it.Src, ci.Src),
			Source: sourceLabel(firstOf(it.Source, firstOf(mi.Source, ci.Source)))}
		if inCur {
			r.Current = ci.Version
		}
		if inMain {
			r.Main = mi.Version
		}
		if inNext {
			r.Next = ni.Version
		}
		switch {
		case next == nil:
		case !inCur:
			r.Change = "new"
		case !inNext:
			r.Change = "gone"
		default:
			r.Change = versionChange(ci.Version, ni.Version)
		}
		r.ChangeLabel = changeLabels[r.Change]
		rows = append(rows, r)
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
	rows := updateRows(cur, res.Main, res.Next)
	// En service : la génération active de maintenant (un rebuild depuis la vérification compte).
	inputs := res.Inputs
	for i := range inputs {
		for _, it := range cur {
			if it.Kind == "input" && it.Pname == inputs[i].Name {
				inputs[i].ServiceRev, inputs[i].ServiceAt = it.Version, it.LastModified
			}
		}
		if inputs[i].CommitsFrom != firstOf(inputs[i].ServiceRev, inputs[i].MainRev) {
			inputs[i].Commits = -1
		}
	}
	var list []UpdateRow
	counts := map[string]int{}
	analyses := s.analyses()
	for i := range inputs {
		if a, ok := analyses[inputs[i].analysisKey()]; ok && inputs[i].Changed() {
			inputs[i].AI = &a
			counts[a.Urgency]++
		}
	}
	for _, row := range rows {
		if a, ok := analyses[analysisKey(row.Name, row.Current, row.Next)]; ok && row.Change != "same" {
			row.AI = &a
			counts[a.Urgency]++
		}
		row.Release = res.Releases[releaseKey(row.Name, firstOf(row.Next, row.Current))]
		if row.ID == "boot.kernel" {
			if k := runningKernel(); k != "" && !strings.HasPrefix(k, row.Current) {
				row.Running = k
			}
		}
		if row.Change != "" && row.Change != "same" {
			counts["changed"]++
			counts[row.Change]++
		}
		list = append(list, row)
	}
	updatesState.Lock()
	running := updatesState.running
	updatesState.Unlock()
	data := map[string]any{"Nav": "updates", "Rows": list, "Inputs": inputs, "Counts": counts,
		"Running": running, "Error": res.Error, "AIOn": s.cfg.GeminiKey != "", "AIKey": s.cfg.AIKeyName, "AIError": res.AIError, "Hour": updatesHour, "Discord": s.cfg.DiscordHook != ""}
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
// urgencyMarks : l'urgence selon l'IA, sur Discord.
var urgencyMarks = map[string]string{"urgent": "🔴", "conseille": "🟠", "sans": "⚪"}

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
		analyses := s.analyses()
		for _, row := range updateRows(cur, res.Main, res.Next) {
			if row.Change != "same" {
				if a, ok := analyses[analysisKey(row.Name, row.Current, row.Next)]; ok {
					row.AI = &a
				}
				changed = append(changed, row)
			}
		}
		rank := map[string]int{"urgent": 0, "conseille": 1}
		urgency := func(r UpdateRow) int {
			if r.AI == nil {
				return 2
			}
			if n, ok := rank[r.AI.Urgency]; ok {
				return n
			}
			return 2
		}
		sort.SliceStable(changed, func(i, j int) bool { return urgency(changed[i]) < urgency(changed[j]) })
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
			mark := "•"
			if row.AI != nil {
				mark = urgencyMarks[row.AI.Urgency]
				extra += ", " + row.AI.UrgencyLabel()
			}
			fmt.Fprintf(&b, "%s **%s** %s → %s (%s%s)\n", mark, row.Name, from, to, row.ChangeLabel, extra)
			if row.AI != nil && row.AI.Urgency == "urgent" {
				fmt.Fprintf(&b, "  %s\n", row.AI.Summary)
			}
		}
		for _, in := range res.Inputs {
			if in.Changed() {
				commits := ""
				if in.Commits >= 0 {
					commits = ", " + plural(in.Commits, "commit", "commits")
				}
				mark := "•"
				a, ok := analyses[in.analysisKey()]
				if ok {
					mark = urgencyMarks[a.Urgency]
					if a.Breaking {
						commits += ", changement cassant"
					}
					commits += ", " + a.UrgencyLabel()
				}
				fmt.Fprintf(&b, "%s source `%s` : %s → %s%s\n", mark, in.Name, in.Day(firstOf64(in.ServiceAt, in.MainAt)), in.Day(in.NextAt), commits)
				if ok && (a.Urgency == "urgent" || a.Breaking) {
					fmt.Fprintf(&b, "  %s\n", a.Summary)
				}
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

func firstOf64(a, b int64) int64 {
	if a != 0 {
		return a
	}
	return b
}
