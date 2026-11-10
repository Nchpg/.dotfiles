package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
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
	"unicode/utf8"
)

// Onglet Mises à jour, en lecture seule : ce que `update` changerait, sans rien modifier. Le
// dashboard calcule un flake.lock à jour dans un fichier à part, évalue l'inventaire de think avec
// (cf. ../inventory.nix), et le compare à celui de la génération active (/etc/dotfiles). Une fois
// par jour, avec un récapitulatif sur Discord.

// updatesHour : l'heure de la vérification quotidienne (et du récapitulatif).
const updatesHour = 7

// updatesRetry : après un échec, la vérification du jour est retentée au plus toutes les heures.
const updatesRetry = time.Hour

// updatesDeadline : la durée d'une vérification complète, au plus (évaluation, versions publiées,
// analyses, notes des CVE) ; au-delà, ce qui manque attend la suivante.
const updatesDeadline = 45 * time.Minute

// InvItem : un paquet de l'inventaire, ou une entrée du flake (kind input : version = révision).
type InvItem struct {
	ID           string   `json:"id"`
	Kind         string   `json:"kind"` // service, base ou input
	LastModified int64    `json:"lastModified"`
	Pname        string   `json:"pname"`
	Version      string   `json:"version"`
	Changelog    string   `json:"changelog"`
	Homepage     string   `json:"homepage"`
	Src          string   `json:"src"`    // d'où vient le code (dépôt, archive)
	Source       string   `json:"source"` // l'entrée du flake qui le fournit (self : ce dépôt)
	Unstable     string   `json:"unstable"`
	CVEPatches   []string `json:"cvePatches"` // CVE corrigées par un patch de nixpkgs, à version égale
}

// InputRow : une entrée du flake : en service, sur main, après update ; les commits d'écart entre
// la révision en service et celle d'après update (GitHub, au moment de la vérification).
type InputRow struct {
	Name, Owner, Repo            string
	ServiceRev, MainRev, NextRev string
	ServiceAt, MainAt, NextAt    int64
	Commits                      int // -1 : inconnu
	CommitsFrom                  string
	CommitsNote                  string    // pourquoi le nombre de commits manque
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
	// Checked : la dernière vérification réussie (les tableaux sont les siens) ; Attempted : la
	// dernière tentative, réussie ou non. Une vérification ratée garde les tableaux d'avant.
	Checked   time.Time  `json:"checked"`
	Attempted time.Time  `json:"attempted"`
	Head      string     `json:"head"`
	Main      []InvItem  `json:"main"`
	Next      []InvItem  `json:"next"`
	Inputs    []InputRow `json:"inputs"`
	Error     string     `json:"error"`
	AIError   string     `json:"aiError"`  // l'analyse par l'IA a échoué (le reste de la vérification tient)
	CVEError  string     `json:"cveError"` // des notes de CVE manquent (NVD, GitHub, KEV)
	// Releases : la page GitHub de chaque version vue (clé releaseKey), trouvée à la vérification.
	Releases map[string]string `json:"releases"`
	// Latest : la dernière version publiée de chaque paquet (par nom), dans sa série.
	Latest map[string]LatestInfo `json:"latest"`
	// EOL : les branches de chaque paquet recensé par endoflife.date (par nom).
	EOL map[string]EOLInfo `json:"eol"`
}

func releaseKey(name, version string) string { return name + "|" + version }

// updatesState : la vérification en cours (une à la fois), depuis quand, et son étape.
var updatesState struct {
	sync.Mutex
	running bool
	started time.Time
	phase   string
}

// tryStartUpdates : marque une vérification en cours ; faux s'il y en a déjà une.
func tryStartUpdates() bool {
	updatesState.Lock()
	defer updatesState.Unlock()
	if updatesState.running {
		return false
	}
	updatesState.running, updatesState.started, updatesState.phase = true, time.Now(), ""
	return true
}

func finishUpdates() {
	updatesState.Lock()
	updatesState.running, updatesState.phase = false, ""
	updatesState.Unlock()
}

// setPhase : l'étape en cours, montrée sur la page.
func setPhase(format string, a ...any) {
	updatesState.Lock()
	if updatesState.running {
		updatesState.phase = fmt.Sprintf(format, a...)
	}
	updatesState.Unlock()
}

func updatesProgress() (running bool, started time.Time, phase string) {
	updatesState.Lock()
	defer updatesState.Unlock()
	return updatesState.running, updatesState.started, updatesState.phase
}

func (s *Server) updatesFile() string { return filepath.Join(s.cfg.StateDir, "updates.json") }

func (s *Server) readUpdates() updatesResult {
	var r updatesResult
	b, err := os.ReadFile(s.updatesFile())
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("mises à jour : %v", err)
		}
		return r
	}
	if err := json.Unmarshal(b, &r); err != nil {
		log.Printf("mises à jour : %s illisible : %v", s.updatesFile(), err)
		return updatesResult{}
	}
	// Un fichier d'avant Attempted : une erreur y effaçait les tableaux, Checked était l'essai.
	if r.Attempted.IsZero() {
		r.Attempted = r.Checked
		if r.Error != "" {
			r.Checked = time.Time{}
		}
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

// Updates : le flake.lock à jour (dans un fichier à part) et l'inventaire de think évalué avec. Dans
// sa propre copie (updatesDir) : seules les deux évaluations prennent le créneau partagé avec la
// vérification des sites ; le clone, nix flake update et les update.sh (réseau) se font sans lui.
// `phase` : l'étape en cours, pour la page.
func (ev *Evaluator) Updates(ctx context.Context, head string, phase func(string)) (oldLock []byte, main, next []InvItem, err error) {
	ev.upMu.Lock()
	defer ev.upMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 12*time.Minute)
	defer cancel()
	tooLong := func(err error) error {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return errors.New("évaluation trop longue (plus de 12 minutes)")
		}
		return err
	}
	phase("copie de main")
	dir := ev.updatesDir()
	if err := ev.checkout(ctx, dir, head); err != nil {
		return nil, nil, nil, tooLong(err)
	}
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
	phase("flake.lock à jour (nix flake update)")
	args := append([]string{"flake", "update"}, names...)
	args = append(args, "--flake", flake, "--output-lock-file", out)
	if _, msgs, err := ev.runJSON(ctx, env, "nix", args...); err != nil {
		if e := tooLong(nil); e != nil {
			return nil, nil, nil, e
		}
		return nil, nil, nil, fmt.Errorf("nix flake update : %s", lastLines(msgs, 3))
	}
	// Sur main (son flake.lock tel quel), puis après update (le lock à jour).
	attr := flake + "#nixosConfigurations." + ev.cfg.Target + ".config.systemSettings.admin.inventory"
	eval := func(label string, inv *[]InvItem, extra ...string) error {
		release, err := ev.acquire(ctx, "la vérification des mises à jour", func(string) {
			phase("en attente : la vérification d'un site évalue la config")
		})
		if err != nil {
			return tooLong(err)
		}
		defer release()
		phase(label)
		o, msgs, err := ev.runJSON(ctx, env, "nix", append(append([]string{"eval", "--json"}, extra...), attr)...)
		if e := tooLong(nil); e != nil {
			return e
		}
		if err != nil {
			return errors.New(evalError(msgs))
		}
		if err := json.Unmarshal(o, inv); err != nil {
			return fmt.Errorf("inventaire illisible : %w", err)
		}
		return nil
	}
	if err := eval("évaluation de main", &main); err != nil {
		return nil, nil, nil, err
	}
	phase("versions épinglées (update.sh)")
	ev.bumpPins(ctx, env, dir)
	if err := eval("évaluation après update", &next, "--reference-lock-file", out); err != nil {
		return nil, nil, nil, err
	}
	return oldLock, main, next, nil
}

// pinsParallel : les update.sh lancés en même temps, au plus (chacun interroge le réseau).
const pinsParallel = 4

// bumpPins : la seconde moitié de `update` (scripts/update.sh), dans la copie d'évaluation : les
// modules qui épinglent une version à côté de nixpkgs (un update.sh et son pinned.json, comme
// cloudflared et ses releases GitHub). Chaque update.sh, en mode vérification (`--check` : la dernière
// version en JSON, sans rien télécharger ni construire), puis cette version dans son pinned.json ;
// l'évaluation d'après update la voit (le hash reste l'ancien : évaluer ne télécharge rien). Un
// script qui échoue garde son épinglage. La copie est remise propre à la vérification suivante.
// Plusieurs scripts à la fois (pinsParallel) : chacun n'écrit que son pinned.json.
func (ev *Evaluator) bumpPins(ctx context.Context, env []string, dir string) {
	env = append(env, "MY_FLAKE="+dir, "GITHUB_TOKEN="+ev.cfg.DispatchToken)
	var scripts []string
	_ = filepath.WalkDir(filepath.Join(dir, "modules"), func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && d.Name() == "update.sh" {
			scripts = append(scripts, path)
		}
		return nil
	})
	var wg sync.WaitGroup
	sem := make(chan struct{}, pinsParallel)
	for _, path := range scripts {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			defer recoverLog("bumpPins")
			ev.bumpPin(ctx, env, path)
		}()
	}
	wg.Wait()
}

// bumpPin : un update.sh et son pinned.json (cf. bumpPins).
func (ev *Evaluator) bumpPin(ctx context.Context, env []string, path string) {
	pinFile := filepath.Join(filepath.Dir(path), "pinned.json")
	raw, err := os.ReadFile(pinFile)
	if err != nil {
		return
	}
	var pin map[string]any
	if json.Unmarshal(raw, &pin) != nil {
		return
	}
	cur, _ := pin["version"].(string)
	if cur == "" {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	out, _, err := ev.runJSON(cctx, env, "bash", path, "--check")
	var check struct {
		Current string `json:"current"`
		Latest  string `json:"latest"`
	}
	if err != nil || json.Unmarshal(out, &check) != nil || check.Current != cur || check.Latest == "" || check.Latest == cur {
		return
	}
	pin["version"] = check.Latest
	if b, err := json.Marshal(pin); err == nil {
		_ = os.WriteFile(pinFile, b, 0o644)
	}
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
// Rien si une vérification est déjà en cours.
func (s *Server) checkUpdates(ctx context.Context, notify bool) {
	if !tryStartUpdates() {
		return
	}
	defer finishUpdates()
	s.runUpdates(ctx, notify)
}

// startUpdates : une vérification en fond, marquée en cours avant de rendre la main (la page qui
// suit la voit) ; faux s'il y en avait déjà une.
func (s *Server) startUpdates(notify bool) bool {
	if !tryStartUpdates() {
		return false
	}
	safeGo("mises à jour", func() {
		defer finishUpdates()
		s.runUpdates(context.Background(), notify)
	})
	return true
}

// runUpdates : le travail de checkUpdates (à appeler marqué en cours). Une vérification ratée garde
// les tableaux de la dernière réussie, avec l'erreur et l'heure de l'essai.
func (s *Server) runUpdates(ctx context.Context, notify bool) {
	ctx, cancel := context.WithTimeout(ctx, updatesDeadline)
	defer cancel()
	now := time.Now()
	prev := s.readUpdates()
	res := updatesResult{Checked: now, Attempted: now}
	setPhase("dernier commit de main")
	head, err := s.gh.Head(ctx)
	if err == nil {
		res.Head = head
		var oldLock []byte
		oldLock, res.Main, res.Next, err = s.eval.Updates(ctx, head, func(p string) { setPhase("%s", p) })
		if err == nil {
			s.completeUpdates(ctx, &res, oldLock)
		}
	}
	if err != nil {
		res = prev
		res.Attempted, res.Error = now, err.Error()
		log.Printf("mises à jour : %v", err)
	}
	if b, err := json.Marshal(res); err == nil {
		if err := writeFileAtomic(s.updatesFile(), b, 0o644); err != nil {
			log.Printf("mises à jour : %v", err)
		}
	}
	// Un échec n'est annoncé qu'une fois (pas à chaque nouvel essai de l'heure).
	if notify && (res.Error == "" || prev.Error == "") {
		s.postUpdates(ctx, res)
	}
}

// completeUpdates : après l'évaluation, les commits des entrées, les versions publiées, l'analyse
// par l'IA et la note des CVE.
func (s *Server) completeUpdates(ctx context.Context, res *updatesResult, oldLock []byte) {
	cur, _ := s.currentInventory()
	res.Inputs = inputRows(cur, res.Main, res.Next, oldLock)
	setPhase("commits des sources")
	for i := range res.Inputs {
		in := &res.Inputs[i]
		if !in.Changed() || in.Owner == "" || ctx.Err() != nil {
			continue
		}
		from := firstOf(in.ServiceRev, in.MainRev)
		n, err := s.gh.CompareCount(ctx, in.Owner, in.Repo, from, in.NextRev)
		if err != nil {
			in.CommitsNote = "GitHub : " + err.Error()
			continue
		}
		in.Commits, in.CommitsFrom = n, from
	}
	rows := updateRows(cur, res.Main, res.Next)
	setPhase("versions publiées (endoflife.date, GitHub)")
	res.EOL = s.eolInfos(ctx, rows)
	applyEOL(rows, res.EOL)
	res.Releases = s.releaseLinks(ctx, rows)
	res.Latest = s.latestVersions(ctx, rows)
	applyLatest(rows, res.Latest)
	var errs []string
	if s.cfg.GeminiKey != "" {
		setPhase("analyse par l'IA")
	}
	for _, e := range []error{s.analyze(ctx, rows), s.analyzeInputs(ctx, res.Inputs, rows)} {
		if e != nil {
			errs = append(errs, e.Error())
		}
	}
	// Les analyses qui ne servent plus (versions dépassées) s'en vont avec l'âge ; les notes de leurs
	// CVE aussi (scoreCVEs ne relit que celles des analyses gardées).
	keep := map[string]bool{}
	for _, r := range rows {
		keep[r.analysisKey()] = true
	}
	for _, in := range res.Inputs {
		keep[in.analysisKey()] = true
	}
	s.pruneAnalyses(keep, keepAnalyses)
	if err := s.scoreCVEs(ctx); err != nil {
		res.CVEError = err.Error()
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		errs = append(errs, fmt.Sprintf("vérification interrompue après %d min : versions publiées, analyses ou notes incomplètes, reprises à la suivante", int(updatesDeadline.Minutes())))
	}
	res.AIError = strings.Join(errs, " ; ")
}

// updatesLoop : la vérification quotidienne, à updatesHour (tout de suite s'il n'y en a jamais eu) ;
// ratée, elle est retentée toutes les heures (updatesRetry) jusqu'à réussir.
func (s *Server) updatesLoop(ctx context.Context) {
	for {
		func() {
			defer recoverLog("updatesLoop")
			res := s.readUpdates()
			now := time.Now()
			due := time.Date(now.Year(), now.Month(), now.Day(), updatesHour, 0, 0, 0, time.Local)
			if now.Before(due) {
				due = due.AddDate(0, 0, -1)
			}
			if res.Checked.Before(due) && now.Sub(res.Attempted) >= updatesRetry {
				s.checkUpdates(ctx, true)
			}
		}()
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
	// La plus récente publiée par le projet, toutes branches (endoflife.date, release GitHub,
	// nixpkgs-unstable), et sa page.
	Latest, LatestURL    string
	Unstable             string
	Patches, NextPatches []string // CVE patchées par nixpkgs : en service, après update
	Stuck                bool     // une faille n'est corrigée qu'au-delà du canal
	EOL                  EOLInfo  // ses branches (endoflife.date)
	OtherBranch          bool     // une faille n'est corrigée que dans une autre branche
	FixIn                string   // la version qui corrige une faille au-delà du canal
}

// EOLAlert : la branche n'est plus maintenue en amont et une faille connue n'y est pas corrigée
// (seule une branche plus récente l'est) : aucun correctif à attendre. Sans faille, la fin de vie
// n'est qu'une mention : nixpkgs-stable garde une version pour toute sa durée et rapporte lui-même
// les correctifs de sécurité (des patches, que la page reconnaît).
func (r UpdateRow) EOLAlert() bool { return r.EOL.Ended && r.OtherBranch }

// NixLatest : la plus récente que Nix donne : après update (le canal du paquet), ou nixpkgs-unstable.
func (r UpdateRow) NixLatest() string {
	if v := firstOf(r.Next, r.Current); r.Unstable == "" || cmpVersions(v, r.Unstable) >= 0 {
		return v
	}
	return r.Unstable
}

// FromUnstable : la plus récente de Nix vient d'unstable (le paquet est pris ailleurs).
func (r UpdateRow) FromUnstable() bool { return r.NixLatest() != firstOf(r.Next, r.Current) }

// ProjectAhead : le projet a publié plus récent que tout ce que Nix donne.
func (r UpdateRow) ProjectAhead() bool {
	return r.Latest != "" && cmpVersions(r.Latest, r.NixLatest()) > 0
}

// Upper : la version la plus récente connue (la dernière publiée si elle dépasse le canal).
func (r UpdateRow) Upper() string {
	if r.Behind() {
		return r.Latest
	}
	return r.Next
}

// Behind : le projet a publié plus récent que ce que le canal donnera.
func (r UpdateRow) Behind() bool {
	return r.Latest != "" && cmpVersions(r.Latest, firstOf(r.Next, r.Current)) > 0
}

// aiPackageVersion : la façon de lire un paquet ; la changer refait ces analyses une fois.
const aiPackageVersion = 7

// analysisKey : la clé de l'analyse de ce paquet (de la version en service à la plus récente).
func (r UpdateRow) analysisKey() string {
	return analysisKey(fmt.Sprintf("%s@%d", r.Name, aiPackageVersion), r.Current, r.Upper())
}

// LatestInfo : la version la plus récente d'un paquet dans sa série.
type LatestInfo struct {
	Version string `json:"version"`
	URL     string `json:"url"`
}

// applyLatest : la dernière version trouvée à la vérification, sur chaque ligne.
func applyLatest(rows []UpdateRow, latest map[string]LatestInfo) {
	for i := range rows {
		if l, ok := latest[rows[i].Name]; ok {
			rows[i].Latest, rows[i].LatestURL = l.Version, l.URL
		}
	}
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
			Source: sourceLabel(firstOf(it.Source, firstOf(mi.Source, ci.Source))), Unstable: it.Unstable,
			Patches: ci.CVEPatches, NextPatches: ni.CVEPatches}
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

func init() {
	// plural : « 1 version », « 3 versions » (`{{plural .N "version" "versions"}}`) ; clipText : un
	// message coupé à n caractères (le reste dans un dépliant).
	funcs["plural"] = plural
	funcs["clipText"] = clipRunes
}

// clipRunes : `s` coupé à `n` caractères (pas au milieu d'un caractère), « … » au bout.
func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return strings.TrimSpace(string([]rune(s)[:n])) + "…"
}

// updatesView : les données de la page. Pendant une vérification, un fragment relu (avancement)
// s'en tient à l'avancement : ni tableaux ni analyses, que la page ne montre pas encore.
func (s *Server) updatesView(r *http.Request) map[string]any {
	res := s.readUpdates()
	running, started, phase := updatesProgress()
	data := map[string]any{"Nav": "updates", "PageTitle": "Mises à jour", "Running": running, "Error": res.Error, "AIError": res.AIError, "CVEError": res.CVEError,
		"AIOn": s.cfg.GeminiKey != "", "AIKey": s.cfg.AIKeyName, "Hour": updatesHour, "Discord": s.cfg.DiscordHook != "", "Counts": map[string]int{}}
	if running {
		data["Started"], data["Phase"] = ago(time.Since(started)), phase
	}
	if !res.Checked.IsZero() {
		data["Checked"] = ago(time.Since(res.Checked))
		data["Head"] = shortRev(res.Head)
	}
	if res.Error != "" && !res.Attempted.IsZero() {
		data["Attempted"] = ago(time.Since(res.Attempted))
	}
	cur, curErr := s.currentInventory()
	if curErr != nil {
		data["CurError"] = "Versions en service illisibles (" + s.cfg.Inventory + ") : la génération active date d'avant cet onglet, un rebuild la crée."
	}
	if running && isFragment(r) {
		return data
	}
	rows := updateRows(cur, res.Main, res.Next)
	// En service : la génération active de maintenant (un rebuild depuis la vérification compte).
	inputs := res.Inputs
	for i := range inputs {
		for _, it := range cur {
			if it.Kind == "input" && it.Pname == inputs[i].Name {
				inputs[i].ServiceRev, inputs[i].ServiceAt = it.Version, it.LastModified
			}
		}
		if inputs[i].Commits >= 0 && inputs[i].CommitsFrom != firstOf(inputs[i].ServiceRev, inputs[i].MainRev) {
			inputs[i].Commits, inputs[i].CommitsNote = -1, "la révision en service a changé depuis la vérification"
		}
	}
	var list []UpdateRow
	counts := map[string]int{}
	infos := s.cveInfos()
	analyses := s.analysesWith(infos)
	for i := range inputs {
		if !inputs[i].Changed() {
			continue
		}
		counts["inputs"]++
		if a, ok := analyses[inputs[i].analysisKey()]; ok {
			inputs[i].AI = &a
			counts[a.Urgency]++
		}
	}
	for _, row := range s.withAnalyses(rows, inputs, res, analyses, infos) {
		if row.AI != nil {
			counts[row.AI.Urgency]++
		}
		if row.Stuck {
			counts["stuck"]++
		}
		if row.EOLAlert() {
			counts["eol"]++
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
	data["Rows"], data["Inputs"], data["Counts"] = list, inputs, counts
	// main a avancé depuis la vérification : ses colonnes « sur main » et « après update » ont vieilli.
	if !running && res.Head != "" && r != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if h, err := s.gh.HeadCached(ctx); err == nil && h != res.Head {
			data["HeadNow"] = shortRev(h)
		}
	}
	return data
}

func (s *Server) updates(w http.ResponseWriter, r *http.Request) {
	if isFragment(r) && r.URL.Query().Has("watch") {
		// Le guet d'une page ouverte : rien tant qu'aucune vérification ne tourne ; sinon le corps de
		// la page, qui se relit ensuite lui-même (vérification lancée par la boucle du jour).
		if running, _, _ := updatesProgress(); !running {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.Header().Set("HX-Retarget", "#updates-body")
		w.Header().Set("HX-Reswap", "outerHTML")
		w.Header().Set("HX-Reselect", "#updates-body")
	}
	data := s.updatesView(r)
	if isFragment(r) {
		data["Frag"] = true
		s.render(w, "updates-body", data)
		return
	}
	s.render(w, "updates", data)
}

// updatesCheck : « Vérifier maintenant » (sans récapitulatif Discord, réservé à la vérification du
// jour). Marquée en cours avant la réponse : la page rendue la suit aussitôt.
func (s *Server) updatesCheck(w http.ResponseWriter, r *http.Request) {
	s.startUpdates(false)
	if isFragment(r) {
		data := s.updatesView(r)
		data["Frag"] = true
		s.render(w, "updates-body", data)
		return
	}
	http.Redirect(w, r, "/updates", http.StatusSeeOther)
}

// urgencyMarks : l'urgence selon l'IA, sur Discord.
var urgencyMarks = map[string]string{"urgent": "🔴", "conseille": "🟠", "sans": "⚪"}

// withAnalyses : chaque ligne avec sa dernière version publiée, son analyse et ses CVE classées
// (classifyRow ; les backports : les CVE citées par les commits de l'entrée qui fournit le paquet).
// `analyses` et `infos` : lus une fois par la page (analysesWith, cveInfos).
func (s *Server) withAnalyses(rows []UpdateRow, inputs []InputRow, res updatesResult, analyses map[string]Analysis, infos map[string]CVEInfo) []UpdateRow {
	backports := map[string]map[string]bool{}
	for _, in := range inputs {
		if a, ok := analyses[in.analysisKey()]; ok {
			set := map[string]bool{}
			for _, c := range a.CVEs {
				set[cveID(c.ID)] = true
			}
			backports[sourceLabel(in.Name)] = set
		}
	}
	applyEOL(rows, res.EOL)
	applyLatest(rows, res.Latest)
	for i := range rows {
		if a, ok := analyses[rows[i].analysisKey()]; ok && rows[i].Upper() != rows[i].Current {
			a = classifyRow(&rows[i], a, backports[rows[i].Source], infos)
			if r := rows[i]; r.Stuck || r.OtherBranch {
				a.StuckSource, a.StuckIn = r.Source, firstOf(r.FixIn, r.Latest)
				if r.Unstable != "" && cmpVersions(r.Unstable, a.StuckIn) >= 0 {
					a.StuckUnstable = r.Unstable
				}
			}
			rows[i].AI = &a
		}
	}
	return rows
}

// postUpdates : le récapitulatif sur Discord (ce qui change, le plus important d'abord).
func (s *Server) postUpdates(ctx context.Context, res updatesResult) {
	if s.cfg.DiscordHook == "" {
		return
	}
	var rows []UpdateRow
	var analyses map[string]Analysis
	if res.Error == "" {
		cur, _ := s.currentInventory()
		infos := s.cveInfos()
		analyses = s.analysesWith(infos)
		rows = s.withAnalyses(updateRows(cur, res.Main, res.Next), res.Inputs, res, analyses, infos)
	}
	msg := recapText(machineName, "https://"+s.cfg.Host+"/updates", res, rows, analyses)
	body, _ := json.Marshal(map[string]any{"content": msg, "flags": 4})
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.DiscordHook, bytes.NewReader(body))
	if err != nil {
		log.Printf("récapitulatif Discord : %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("récapitulatif Discord : %v", err)
		return
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		log.Printf("récapitulatif Discord : %s", resp.Status)
	}
}

// discordMax : la longueur d'un message Discord, de la marge comprise (2000 au plus).
const discordMax = 1900

// recapText : le texte du récapitulatif. Les paquets qui changent (ou en alerte), les plus urgents
// d'abord, puis les sources qui avancent ; trop long, la liste est coupée entre deux lignes, le lien
// du bas toujours gardé.
func recapText(host, link string, res updatesResult, rows []UpdateRow, analyses map[string]Analysis) string {
	if res.Error != "" {
		return fmt.Sprintf("⚠️ **%s** : vérification des mises à jour impossible.\n`%s`\n%s", host, clipRunes(lastLine(res.Error), 300), link)
	}
	var changed []UpdateRow
	versions, alerts := 0, 0
	for _, row := range rows {
		moves := row.Change != "" && row.Change != "same"
		if moves {
			versions++
		}
		if row.Stuck || row.EOLAlert() {
			alerts++
		}
		if moves || row.Stuck || row.EOLAlert() {
			changed = append(changed, row)
		}
	}
	var inputs []InputRow
	for _, in := range res.Inputs {
		if in.Changed() {
			inputs = append(inputs, in)
		}
	}
	if len(changed) == 0 && len(inputs) == 0 {
		return fmt.Sprintf("✅ **%s** est à jour : `update` ne changerait rien.", host)
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

	var head []string
	if versions > 0 {
		head = append(head, plural(versions, "version changerait", "versions changeraient"))
	}
	if len(inputs) > 0 {
		head = append(head, plural(len(inputs), "source avancerait", "sources avanceraient"))
	}
	var b strings.Builder
	if len(head) > 0 {
		fmt.Fprintf(&b, "🔄 **%s** : %s avec `update`", host, strings.Join(head, ", "))
	} else {
		fmt.Fprintf(&b, "⚠️ **%s** : `update` ne changerait aucune version", host)
	}
	if alerts > 0 {
		fmt.Fprintf(&b, " ; %s", plural(alerts, "alerte", "alertes"))
	}
	b.WriteString(".\n")

	// Une entrée par paquet ou par source (avec ses lignes de détail), coupées entières.
	var entries []string
	for i, row := range changed {
		if i == 12 {
			entries = append(entries, fmt.Sprintf("… et %s\n", plural(len(changed)-12, "autre paquet", "autres paquets")))
			break
		}
		var e strings.Builder
		from, to := firstOf(row.Current, "—"), firstOf(row.Next, "—")
		extra := ""
		if row.ID == "boot.kernel" && row.Change != "same" {
			extra = ", redémarrage"
		}
		mark := "•"
		if row.AI != nil {
			mark = urgencyMarks[row.AI.Urgency]
			extra += ", " + row.AI.UrgencyLabel()
		}
		label := row.ChangeLabel
		if row.Change == "same" {
			label = "le canal n'a rien de plus"
		}
		fmt.Fprintf(&e, "%s **%s** %s → %s (%s%s)\n", mark, row.Name, from, to, label, extra)
		if row.EOLAlert() {
			since := ""
			if row.EOL.Since != "" {
				since = " depuis le " + row.EOL.Since
			}
			fmt.Fprintf(&e, "  ⚠️ branche %s plus maintenue%s, et une faille n'est corrigée que dans une plus récente\n", row.EOL.Cycle, since)
		}
		if row.Stuck {
			what := "pas encore dans nixpkgs : attendre"
			if row.AI != nil && row.AI.StuckUnstable != "" {
				what = "nixpkgs-unstable l'a (" + row.AI.StuckUnstable + ") : prendre le paquet dans unstable"
			}
			fmt.Fprintf(&e, "  ⚠️ faille corrigée seulement en %s, pas dans le canal %s ; %s\n", firstOf(row.FixIn, row.Latest), row.Source, what)
		}
		if row.AI != nil && row.AI.Urgency == "urgent" {
			fmt.Fprintf(&e, "  %s\n", row.AI.Summary)
		}
		entries = append(entries, e.String())
	}
	for _, in := range inputs {
		var e strings.Builder
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
		fmt.Fprintf(&e, "%s source `%s` : %s → %s%s\n", mark, in.Name, in.Day(firstOf64(in.ServiceAt, in.MainAt)), in.Day(in.NextAt), commits)
		if ok && (a.Urgency == "urgent" || a.Breaking) {
			fmt.Fprintf(&e, "  %s\n", a.Summary)
		}
		entries = append(entries, e.String())
	}
	footer := fmt.Sprintf("Rien n'est appliqué : sur %s, `update` puis `rebuild`. %s", host, link)
	for i, e := range entries {
		rest := ""
		if i < len(entries)-1 {
			rest = fmt.Sprintf("… et %s\n", plural(len(entries)-i, "autre ligne", "autres lignes"))
		}
		// La place de cette entrée, de l'annonce des suivantes et du lien.
		if b.Len()+len(e)+len(rest)+len(footer) > discordMax {
			fmt.Fprintf(&b, "… et %s\n", plural(len(entries)-i, "autre ligne", "autres lignes"))
			break
		}
		b.WriteString(e)
	}
	b.WriteString(footer)
	return b.String()
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
