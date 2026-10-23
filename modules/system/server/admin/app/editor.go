package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

type Opt struct {
	Value, Label, Note string
	Selected           bool
}

// DD : liste déroulante maison (icône par option) ; la valeur part dans un champ caché `Name`.
type DD struct {
	Name, Value, Aria               string
	Label, Icon, Tint, Ink          string
	Options                         []DDOpt
	Structural, Locked, Placeholder bool
}

type DDOpt struct {
	Value, Label, Sub, SubInk string
	Icon, Tint, Ink           string
	Selected                  bool
}

const (
	icBranch = "M6 3v12M18 9a3 3 0 1 0 0-6a3 3 0 1 0 0 6M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6M18 9a9 9 0 0 1-9 9"
	icEnv    = "M12 3l9 5-9 5-9-5zM3 13l9 5 9-5"
	icCommit = "M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6M3 12h6M15 12h6"
	icFollow = "M21 12a9 9 0 1 1-3-6.7M21 4v5h-5"
	icImage  = "M21 8l-9-5-9 5 9 5zM3 8v8l9 5 9-5V8M12 13v8"
	icMem    = "M7 4h10a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM9 8h6M9 12h6M9 16h3"
)

var (
	colGreen  = [2]string{"#E9F8EF", "#15803D"}
	colAmber  = [2]string{"#FEF3E2", "#9A4A07"}
	colIndigo = [2]string{"#EEF0FD", "#4F5BD5"}
	colGray   = [2]string{"#F1F2F5", "#4A515D"}
	colRed    = [2]string{"#FDECEC", "#B42318"}
)

func ddOpt(value, label, sub, icon string, col [2]string, selected bool) DDOpt {
	return DDOpt{Value: value, Label: label, Sub: sub, Icon: icon, Tint: col[0], Ink: col[1], Selected: selected}
}

// newDD : le bouton montre l'option choisie (ou `placeholder` si aucune).
func newDD(name, aria string, opts []DDOpt, placeholder, icon string) DD {
	d := DD{Name: name, Aria: aria, Options: opts, Label: placeholder, Icon: icon, Tint: colGray[0], Ink: "#8F98A6", Placeholder: true}
	for _, o := range opts {
		if o.Selected {
			d.Value, d.Label, d.Icon, d.Tint, d.Ink, d.Placeholder = o.Value, o.Label, o.Icon, o.Tint, o.Ink, false
		}
	}
	return d
}

type DataVM struct {
	Value, Path, Host string
	Auto              bool
}

type CtrVM struct {
	Name     string
	Entry    bool
	Image    DD
	Memory   DD
	Deps     []Opt
	Data     []DataVM
	Secrets  []Opt
	Info     string
	DataHost string
	Locked   bool // conteneurs hérités : montrés, pas modifiables ici
}

type EnvTab struct {
	ID, Label, Branch, Domain, URL string
	Current, Root, New             bool
}

type RecopyVM struct {
	State, Text string
}

type FormVM struct {
	New, Exists  bool
	Name         string
	Domain       string
	Suffix       string
	SuffixPublic string
	SuffixVPN    string
	Base         string
	PreviewURL   string
	ApplyURL     string
	DeleteURL    string
	FormURL      string
	Repo         string
	Sub          string
	VPN, SSO     bool
	Internet     bool
	RL           bool
	RLPaths      string
	Probe        string
	Peers        []Opt
	Containers   []CtrVM
	CtrList      string
	Multi        bool
	NewImages    []Opt // images du dépôt sans conteneur : à ajouter
	Version      DD
	VersionNote  string
	Branch       DD
	Frozen       bool
	Up, Probed   bool
	Initial      string
	Tint, Ink    string
	Preview      PreviewVM
	// Demande en cours (étapes à la place de l'aperçu, formulaire grisé) ou échec récent.
	Running *JobView
	Failed  *JobBadge

	// Environnements.
	Env, EnvLabel, Label     string // id édité ("" : la racine), nom affiché
	EnvNew, Child            bool
	Tabs                     []EnvTab
	From                     DD
	OwnAccess, OwnContainers bool
	OwnOptions               bool
	AccessFrom, CtrsFrom     string // « Comme preview », « Comme preview (réglé dans production) »
	OptionsFrom              string
	AccessSummary            []string
	OptionsSummary           []string
	DataModes                []DDOpt
	Recopy                   *RecopyVM
	RecopyURL, RemoveEnvURL  string
	Noindex                  bool
	Children                 []string // environnements qui en héritent
	AddBranch, AddFrom       DD
	AddError, AddName        string
}

type PreviewVM struct {
	ApplyURL string
	Lines    []DiffLine
	Adds     int
	Dels     int
	Errors   []string
	Dirty    bool
	Message  string
	New      bool
	// Adresse avant / après, quand elle change (sous-domaine, exposition).
	From, To string
}

var reTag = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

// repoImages : images publiées par un dépôt (nom sans registre ni tag), d'après ghcr.
func (s *Server) repoImages(ctx context.Context, repo string) []string {
	if repo == "" {
		return nil
	}
	pkgs, err := s.gh.Packages(ctx)
	if err != nil {
		return nil
	}
	var out []string
	for _, p := range pkgs {
		if p.Repository != nil && strings.EqualFold(p.Repository.FullName, repo) {
			out = append(out, p.Name)
		}
	}
	sort.Strings(out)
	return out
}

// sourceRepo : dépôt GitHub d'un site (package ghcr de son image, sinon label de l'image), gardé
// 10 minutes : les pages le demandent à chaque rafraîchissement, il ne change pas. Sans dépôt
// trouvé pendant une panne de l'API des packages, la réponse n'est pas gardée.
func (s *Server) sourceRepo(ctx context.Context, e Entry) string {
	if s.gh == nil || s.reg == nil {
		return ""
	}
	c := e.Containers[e.EntryPoint()]
	repo := ""
	v, err := s.gh.cached("repo:"+s.cfg.ref(c.Image), 10*time.Minute, func() (any, error) {
		var err error
		repo, err = s.lookupRepo(ctx, c.Image)
		return repo, err
	})
	if err != nil {
		return repo // panne : valeur du moment, non gardée
	}
	return v.(string)
}

// lookupRepo : l'erreur (liste des packages illisible, dépôt introuvable) dit de ne pas garder le résultat.
func (s *Server) lookupRepo(ctx context.Context, image string) (string, error) {
	// Le package ghcr connaît son dépôt ; le label de l'image vient en second.
	pkgs, perr := s.gh.Packages(ctx)
	for _, p := range pkgs {
		if p.Repository != nil && strings.EqualFold(p.Name, untag(image)) {
			return p.Repository.FullName, nil
		}
	}
	info, err := s.reg.Inspect(ctx, s.cfg.ref(image))
	if err != nil {
		return "", perr // image illisible (absente de ghcr…) : sans dépôt, comme une image de base
	}
	// Une image qui hérite du label de son image de base (nginx…) ne désigne pas le dépôt du site.
	if owner, _, _ := strings.Cut(info.Source, "/"); !strings.EqualFold(owner, s.cfg.RegistryUser) {
		return "", perr
	}
	return info.Source, nil
}

// versionDD : suivre la branche, ou chaque commit dont toutes les images du déploiement ont le tag `sha-…`.
func (s *Server) versionDD(ctx context.Context, d Deploy) (DD, string) {
	if s.reg == nil { // tests : pas de registre
		opts := []DDOpt{ddOpt("", "suivre "+d.Branch, "", icFollow, colGreen, !d.Frozen())}
		if d.Frozen() {
			opts = append(opts, ddOpt(d.Tag, shortTag(d.Tag), "tag actuel", icCommit, colAmber, true))
		}
		return newDD("version", "Images à faire tourner", opts, "", icFollow), ""
	}
	current := ""
	if d.Frozen() {
		current = d.Tag
	}
	var names []string
	for _, c := range d.Ctrs.Containers {
		names = append(names, s.cfg.ref(untag(c.Image)))
	}
	sort.Strings(names)
	opts := []DDOpt{ddOpt("", "suivre "+d.Branch, "la dernière image de la branche", icFollow, colGreen, current == "")}
	note := ""
	tags, err := s.reg.ShaTags(ctx, names)
	if err != nil {
		note = "Versions illisibles sur le registre : " + err.Error()
	}
	// Branche, sujet et date : labels de l'image d'entrée (app-image.yml). Seuls les commits de la
	// branche suivie restent ; une image sans ces labels (construite avant) n'est pas proposée.
	entry := s.cfg.ref(untag(d.Ctrs.Containers[d.EntryPoint()].Image))
	refs := make([]string, len(tags))
	for i, t := range tags {
		refs[i] = entry + ":" + t
	}
	infos := s.reg.InspectAll(ctx, refs)
	type v struct {
		tag, sub string
		date     time.Time
	}
	var vs []v
	unlabeled := 0
	for i, t := range tags {
		info, ok := infos[refs[i]]
		switch {
		case !ok:
		case info.Branch == "":
			unlabeled++
		case info.Branch == d.Branch:
			sub := info.Subject
			if !info.Created.IsZero() {
				sub += " (" + info.Created.Local().Format("02/01") + ")"
			}
			vs = append(vs, v{tag: t, sub: sub, date: info.Created})
		}
	}
	sort.SliceStable(vs, func(i, j int) bool { return vs[i].date.After(vs[j].date) })
	if len(vs) > 20 {
		vs = vs[:20]
	}
	found := current == ""
	for _, x := range vs {
		opts = append(opts, ddOpt(x.tag, shortTag(x.tag), x.sub, icCommit, colAmber, x.tag == current))
		found = found || x.tag == current
	}
	if !found {
		opts = append(opts, ddOpt(current, shortTag(current), "tag actuel", icCommit, colAmber, true))
	}
	if len(vs) == 0 && note == "" {
		note = "Aucune version de " + d.Branch + " à figer pour l'instant."
		if unlabeled > 0 {
			note = "Les images construites avant l'ajout des labels de branche n'apparaissent pas : le prochain push de " + d.Branch + " en publiera une."
		}
	}
	dd := newDD("version", "Images à faire tourner", opts, "", icFollow)
	dd.Structural = true
	return dd, note
}

// Tags de commit : `sha-<commit>` du template, ou le hash nu publié par d'anciens workflows.
var reCommitTag = regexp.MustCompile(`^(sha-)?[0-9a-f]{7,40}$`)

// branchOpts : branches qui publient une image (les tags de l'image, hors tags de commit).
func (s *Server) branchOpts(ctx context.Context, image, current string) []DDOpt {
	var tags []string
	if image != "" && s.reg != nil {
		tags, _ = s.reg.Tags(ctx, s.cfg.ref(untag(image)))
	}
	sort.Strings(tags)
	var opts []DDOpt
	found := false
	for _, t := range tags {
		if reCommitTag.MatchString(t) || t == "latest" {
			continue
		}
		opts = append(opts, ddOpt(t, t, "image "+untag(image)+":"+t+" publiée", icBranch, colGreen, t == current))
		found = found || t == current
	}
	if current != "" && !found {
		o := ddOpt(current, current, "aucune image de cette branche sur ghcr", icBranch, colRed, true)
		o.SubInk = colRed[1]
		opts = append(opts, o)
	}
	return opts
}

func (s *Server) secretsFor(name string) []string {
	var out []string
	for _, k := range s.cfg.SecretKeys {
		if strings.HasPrefix(k, name+"/") {
			out = append(out, k)
		}
	}
	return out
}

var memories = [][2]string{{"", "Sans limite"}, {"128m", "128 Mo"}, {"256m", "256 Mo"}, {"512m", "512 Mo"}, {"1g", "1 Go"}, {"2g", "2 Go"}}

// formVM : le formulaire d'un nouveau site, ou de la racine d'un site.
func (s *Server) formVM(ctx context.Context, name string, e Entry, isNew bool, repo string, images []string, snap *Snapshot) FormVM {
	return s.formVMFor(ctx, name, e, "", isNew, repo, images, snap)
}

// formVMFor : le formulaire pré-rempli pour un déploiement (env vide : la racine).
func (s *Server) formVMFor(ctx context.Context, name string, e Entry, env string, isNew bool, repo string, images []string, snap *Snapshot) FormVM {
	d, err := e.Deploy(name, env)
	if err != nil {
		env = ""
		d, _ = e.Deploy(name, "")
	}
	onMainEnvs := map[string]Env{}
	if snap != nil {
		onMainEnvs = snap.Apps.Entries[name].Environments
	}
	f := FormVM{
		New: isNew, Exists: !isNew, Name: name, Repo: repo, Env: env, Child: d.Child, EnvLabel: d.Label,
		VPN: d.VPN(), SSO: d.Access.SSO, Internet: d.Options.Internet, Probe: d.Options.Probe,
		Multi: len(d.Ctrs.Containers) > 1, Initial: initialOf(name),
		OwnAccess: true, OwnContainers: true, OwnOptions: true,
	}
	f.Tint, f.Ink = colorsOf(name)
	f.Sub = d.Subdomain
	if f.Sub == "" {
		f.Sub = d.App
	}
	f.Label = d.Label
	f.Domain = d.Domain(s.cfg.Domain)
	f.SuffixPublic, f.SuffixVPN = "."+s.cfg.Domain, ".vpn."+s.cfg.Domain
	f.Suffix = f.SuffixPublic
	if d.VPN() {
		f.Suffix = f.SuffixVPN
	}
	f.Noindex = d.Child && !d.VPN()
	if isNew {
		f.Base, f.PreviewURL, f.ApplyURL, f.FormURL = "new", "/sites/new/preview", "/sites/new/apply", "/sites/new/form"
	} else {
		f.Base = snap.Apps.Fingerprint(name)
		f.PreviewURL, f.ApplyURL, f.DeleteURL, f.FormURL = "/sites/"+name+"/preview", "/sites/"+name+"/apply", "/sites/"+name+"/delete", "/sites/"+name+"/form"
	}
	if d.Options.RateLimit != nil {
		f.RL, f.RLPaths = true, strings.Join(*d.Options.RateLimit, " ")
	}
	devices := map[string]bool{}
	for _, dv := range d.Access.Devices {
		devices[dv] = true
	}
	for _, p := range s.cfg.Peers {
		f.Peers = append(f.Peers, Opt{Value: p, Label: p, Selected: devices[p]})
	}

	if d.Child {
		v := e.Environments[env]
		f.OwnAccess, f.OwnContainers, f.OwnOptions = v.OwnAccess(), v.OwnContainers(), v.OwnOptions()
		mv, onMain := onMainEnvs[env]
		f.EnvNew = !onMain
		// « Comme preview », et d'où vient vraiment la valeur quand le parent hérite lui-même.
		origin := func(own func(Env) bool) string {
			p := v.From
			for n := 0; p != "" && n < 17 && !own(e.Environments[p]); n++ {
				p = e.Environments[p].From
			}
			text := "Comme " + e.labelOf(v.From)
			if p != v.From {
				text += " (réglé dans " + e.labelOf(p) + ")"
			}
			return text
		}
		f.AccessFrom = origin(Env.OwnAccess)
		f.CtrsFrom = origin(Env.OwnContainers)
		f.OptionsFrom = origin(Env.OwnOptions)
		f.AccessSummary = []string{"public"}
		if d.VPN() {
			f.AccessSummary = []string{"VPN : " + strings.Join(d.Access.Devices, ", ")}
		}
		if d.Access.SSO {
			f.AccessSummary = append(f.AccessSummary, "Authelia")
		}
		f.OptionsSummary = []string{"internet fermé"}
		if d.Options.Internet {
			f.OptionsSummary = []string{"internet ouvert"}
		}
		if d.Options.RateLimit != nil {
			f.OptionsSummary = append(f.OptionsSummary, "débit limité")
		}
		if p := d.Options.Probe; p != "" && p != "/" {
			f.OptionsSummary = append(f.OptionsSummary, "santé "+p)
		}
		var froms []DDOpt
		for _, id := range append([]string{""}, e.EnvIDs()...) {
			if id == env || (id != "" && e.inherits(id, env)) {
				continue
			}
			pd, err := e.Deploy(name, id)
			if err != nil {
				continue
			}
			col, sub := colAmber, pd.Domain(s.cfg.Domain)
			if id == "" {
				col = colIndigo
			}
			froms = append(froms, ddOpt(id, pd.Label, sub, icEnv, col, id == v.From))
		}
		f.From = newDD("from", "Hérite de", froms, "", icEnv)
		f.From.Structural = true
		parent := e.labelOf(v.From)
		f.DataModes = []DDOpt{
			{Value: "separate", Label: "Séparées", Sub: "Vides au départ.", Selected: v.DataMode() == "separate"},
			{Value: "copy", Label: "Copie de " + parent, Sub: "Copiées au premier démarrage.", Selected: v.DataMode() == "copy"},
			{Value: "shared", Label: "Partagées avec " + parent, Sub: "Les mêmes dossiers.", Selected: v.DataMode() == "shared"},
		}
		if onMain && mv.DataMode() == "copy" && v.DataMode() == "copy" {
			f.Recopy = s.recopyState(d.App, parent)
			f.RecopyURL = "/sites/" + name + "/env/" + env + "/recopy"
		}
		if onMain {
			f.RemoveEnvURL = "/sites/" + name + "/env/" + env + "/delete"
		}
		for _, id := range e.EnvIDs() {
			if e.Environments[id].From == env {
				f.Children = append(f.Children, e.labelOf(id))
			}
		}
	}

	// Onglets : la racine et chaque environnement (le nouveau compris).
	if !isNew {
		for _, dd := range e.Deploys(name) {
			_, onMain := onMainEnvs[dd.ID]
			url := "/sites/" + name
			if dd.ID != "" {
				url += "?env=" + dd.ID
			}
			f.Tabs = append(f.Tabs, EnvTab{ID: dd.ID, Label: dd.Label, Branch: dd.Branch, Domain: dd.Domain(s.cfg.Domain), URL: url,
				Current: dd.ID == env, Root: !dd.Child, New: dd.Child && !onMain})
		}
	}

	secrets := s.secretsFor(name)
	names := d.containerNames()
	f.CtrList = strings.Join(names, ",")
	used := map[string]bool{}
	for _, n := range names {
		c := d.Ctrs.Containers[n]
		img := untag(c.Image)
		used[img] = true
		vm := CtrVM{Name: n, Entry: n == d.EntryPoint(), DataHost: "/var/lib/apps/" + d.App + "/" + n, Locked: !f.OwnContainers}
		choices := append([]string{}, images...)
		if !slices.Contains(choices, img) {
			choices = append(choices, img)
		}
		var io []DDOpt
		for _, i := range choices {
			io = append(io, ddOpt(i, i, s.cfg.Registry+"/"+i, icImage, colIndigo, i == img))
		}
		vm.Image = newDD("img_"+n, "Image de "+n, io, "", icImage)
		vm.Image.Locked = vm.Locked
		var mo []DDOpt
		for _, m := range memories {
			sub := "mémoire maximale"
			if m[0] == "" {
				sub = "aucune limite"
			}
			mo = append(mo, ddOpt(m[0], m[1], sub, icMem, colGray, m[0] == c.Memory))
		}
		vm.Memory = newDD("mem_"+n, "Mémoire de "+n, mo, "", icMem)
		vm.Memory.Locked = vm.Locked
		for _, o := range names {
			if o != n {
				vm.Deps = append(vm.Deps, Opt{Value: o, Label: o, Selected: slices.Contains(c.DependsOn, o)})
			}
		}
		for _, dt := range c.Data {
			host := dt.On
			if host == "" {
				host = e.DataHost(name, env, n, dt.Path)
			}
			vm.Data = append(vm.Data, DataVM{Value: dt.Path + "\t" + dt.On, Path: dt.Path, Host: host, Auto: dt.On == ""})
		}
		opts := map[string]bool{}
		for _, k := range secrets {
			opts[k] = true
			vm.Secrets = append(vm.Secrets, Opt{Value: k, Label: k, Selected: slices.Contains(c.Secrets, k)})
		}
		for _, k := range c.Secrets {
			if !opts[k] {
				vm.Secrets = append(vm.Secrets, Opt{Value: k, Label: k, Selected: true, Note: "absent du dépôt de secrets"})
			}
		}
		if snap != nil {
			if le, ok := snap.Lock[s.cfg.ref(c.Image)]; ok {
				if le.Port != nil {
					vm.Info = fmt.Sprintf("port %d", *le.Port)
				}
			}
		}
		f.Containers = append(f.Containers, vm)
	}
	// Une image publiée par le dépôt sans conteneur : proposée (à la création, toutes y sont).
	if f.OwnContainers {
		for _, i := range images {
			if !used[i] {
				f.NewImages = append(f.NewImages, Opt{Value: i, Label: i, Note: containerName(repo, i, false)})
			}
		}
	}
	f.Frozen = d.Frozen()
	if !isNew {
		f.Version, f.VersionNote = s.versionDD(ctx, d)
		entry := d.Ctrs.Containers[d.EntryPoint()].Image
		f.Branch = newDD("branch", "Branche du dépôt", s.branchOpts(ctx, entry, d.Branch), "choisir une branche…", icBranch)
		f.Branch.Structural = true
		// Ajouter un environnement : une branche qui a une image, un parent.
		f.AddBranch = newDD("branch", "Branche", s.branchOpts(ctx, entry, ""), "choisir une branche…", icBranch)
		var froms []DDOpt
		for _, id := range append([]string{""}, e.EnvIDs()...) {
			if pd, err := e.Deploy(name, id); err == nil {
				col := colAmber
				if id == "" {
					col = colIndigo
				}
				froms = append(froms, ddOpt(id, pd.Label, pd.Domain(s.cfg.Domain), icEnv, col, id == env))
			}
		}
		f.AddFrom = newDD("from", "Hérite de", froms, "", icEnv)
	}
	return f
}

func (d Deploy) containerNames() []string {
	names := make([]string, 0, len(d.Ctrs.Containers))
	for n := range d.Ctrs.Containers {
		names = append(names, n)
	}
	ep := d.EntryPoint()
	sort.Slice(names, func(i, j int) bool {
		if (names[i] == ep) != (names[j] == ep) {
			return names[i] == ep
		}
		return names[i] < names[j]
	})
	return names
}

func (e Entry) labelOf(id string) string {
	if id == "" {
		if e.Name != "" {
			return e.Name
		}
		return "production"
	}
	if v, ok := e.Environments[id]; ok && v.Name != "" {
		return v.Name
	}
	return id
}

// recopyState : dernier résultat d'admin-recopy pour cette app, ou demande en attente.
func (s *Server) recopyState(app, parent string) *RecopyVM {
	vm := &RecopyVM{Text: "Remplace ses données par celles de " + parent + " ; l'environnement est arrêté pendant la copie."}
	var st struct {
		State  string `json:"state"`
		Detail string `json:"detail"`
		At     int64  `json:"at"`
	}
	if b, err := os.ReadFile(filepath.Join(s.cfg.RecopyStatus, app+".json")); err == nil && json.Unmarshal(b, &st) == nil {
		when := time.Unix(st.At, 0).Local().Format("02/01 15:04")
		switch st.State {
		case "running":
			vm.State, vm.Text = "running", "Recopie en cours (depuis "+when+")…"
		case "done":
			vm.State, vm.Text = "done", "Dernière recopie : "+when+"."
		case "failed":
			vm.State, vm.Text = "failed", "La recopie du "+when+" a échoué : "+st.Detail
		}
	}
	if _, err := os.Stat(filepath.Join(s.cfg.StateDir, "recopy", app+".want")); err == nil {
		vm.State, vm.Text = "running", "Recopie demandée…"
	}
	return vm
}

// containersFromForm : conteneurs du formulaire. `tag` vide : images sans tag (environnement).
func (s *Server) containersFromForm(r *http.Request, prev map[string]Container, allowed []string, repo, tag string) (map[string]Container, string, []string) {
	var errs []string
	var names []string
	for _, n := range strings.Split(r.FormValue("containers"), ",") {
		if n = strings.TrimSpace(n); n != "" && n != r.FormValue("rmctr") {
			names = append(names, n)
		}
	}
	added := ""
	if img := r.FormValue("addctr"); img != "" && slices.Contains(allowed, img) {
		stem := containerName(repo, img, false)
		added = stem
		for i := 2; slices.Contains(names, added); i++ {
			added = fmt.Sprintf("%s%d", stem, i)
		}
		names = append(names, added)
	}
	out := map[string]Container{}
	for _, n := range names {
		var c Container
		if p, ok := prev[n]; ok {
			c.Image = p.Image
		}
		img := r.FormValue("img_" + n)
		if n == added {
			img = r.FormValue("addctr")
		}
		if img == "" {
			img = untag(c.Image)
		}
		if !slices.Contains(allowed, img) {
			errs = append(errs, fmt.Sprintf("%s : image %s hors du dépôt du site.", n, img))
		}
		c.Image = img
		if tag != "" {
			c.Image = img + ":" + tag
		}
		c.Memory = r.FormValue("mem_" + n)
		for _, dp := range r.Form["dep_"+n] {
			if slices.Contains(names, dp) && dp != n {
				c.DependsOn = append(c.DependsOn, dp)
			}
		}
		sort.Strings(c.DependsOn)
		for _, v := range r.Form["data_"+n] {
			path, on, _ := strings.Cut(v, "\t")
			c.Data = append(c.Data, Data{Path: path, On: on})
		}
		// Plusieurs dossiers d'un coup, séparés par des espaces.
		for _, p := range strings.Fields(r.FormValue("newdata_" + n)) {
			c.Data = append(c.Data, Data{Path: p})
		}
		c.Secrets = r.Form["sec_"+n]
		sort.Strings(c.Secrets)
		out[n] = c
	}
	entry := ""
	if len(names) > 1 {
		entry = r.FormValue("entry")
		if !slices.Contains(names, entry) {
			entry = names[0]
		}
	}
	return out, entry, errs
}

func accessFromForm(r *http.Request) (expose string, devices []string, sso bool) {
	expose = "public"
	if r.FormValue("expose") == "vpn" {
		expose = "vpn"
		devices = r.Form["dev"]
		sort.Strings(devices)
	}
	return expose, devices, r.FormValue("sso") == "on"
}

func optionsFromForm(r *http.Request) (internet bool, probe string, rl *[]string) {
	internet = r.FormValue("internet") == "on"
	if p := strings.TrimSpace(r.FormValue("probe")); p != "" && p != "/" {
		probe = p
	}
	if r.FormValue("rl") == "on" {
		paths := strings.Fields(r.FormValue("rlpaths"))
		if paths == nil {
			paths = []string{}
		}
		rl = &paths
	}
	return
}

// entryFromForm : l'entrée du site avec le déploiement `env` tel que décrit par le formulaire ;
// les autres déploiements restent ceux de `current`. `allowed` : images permises (celles du dépôt).
func (s *Server) entryFromForm(r *http.Request, name string, current Entry, env string, allowed []string, repo string) (Entry, []string) {
	var errs []string
	e := cloneEntry(current)
	label := strings.TrimSpace(r.FormValue("label"))
	sub := strings.ToLower(strings.TrimSpace(r.FormValue("sub")))
	version := r.FormValue("version")
	if version != "" && !reTag.MatchString(version) {
		errs = append(errs, "Version invalide.")
		version = ""
	}

	if env == "" {
		e.Name = ""
		if label != "" && label != "production" {
			e.Name = label
		}
		e.Subdomain = ""
		if sub != "" && sub != name {
			e.Subdomain = sub
		}
		expose, devices, sso := accessFromForm(r)
		e.Expose, e.Devices, e.SSO = "", nil, sso
		if expose == "vpn" {
			e.Expose, e.Devices = "vpn", devices
		}
		e.InternetAccess, e.Probe, e.RateLimit = optionsFromForm(r)
		branch := r.FormValue("branch")
		if branch == "" || !reTag.MatchString(branch) {
			branch = "main"
			if v := current.Version(); v != "" && !strings.HasPrefix(v, "sha-") {
				branch = v
			}
		}
		tag := branch
		if version != "" {
			tag = version
		}
		var cerrs []string
		e.Containers, e.Entrypoint, cerrs = s.containersFromForm(r, current.Containers, allowed, repo, tag)
		return e, append(errs, cerrs...)
	}

	v := e.Environments[env]
	v.Name = ""
	if label != "" && label != env {
		v.Name = label
	}
	v.Branch = r.FormValue("branch")
	v.From = r.FormValue("from")
	v.Data = r.FormValue("data")
	if v.Data == "separate" {
		v.Data = ""
	}
	v.Pin = version
	v.Subdomain = ""
	if sub != "" && sub != name+"-"+env {
		v.Subdomain = sub
	}
	// Sections du parent : point de départ d'une section qui devient propre.
	tmp := cloneEntry(e)
	tmp.Environments[env] = v
	pa, pc, po, err := tmp.sections(v.From, 0)
	if err != nil {
		errs = append(errs, err.Error())
	}
	if r.FormValue("own_access") == "1" {
		if _, shown := r.Form["expose"]; shown && v.OwnAccess() {
			v.Expose, v.Devices, v.SSO = accessFromForm(r)
		} else if !v.OwnAccess() {
			v.Expose, v.Devices, v.SSO = pa.Expose, pa.Devices, pa.SSO
		}
	} else {
		v.Expose, v.Devices, v.SSO = "", nil, false
	}
	if r.FormValue("own_containers") == "1" {
		if !v.OwnContainers() {
			v.Containers = map[string]Container{}
			for n, c := range pc.Containers {
				c.Image = untag(c.Image)
				v.Containers[n] = c
			}
			v.Entrypoint = pc.Entrypoint
		} else if _, shown := r.Form["containers"]; shown {
			var cerrs []string
			v.Containers, v.Entrypoint, cerrs = s.containersFromForm(r, v.Containers, allowed, repo, "")
			errs = append(errs, cerrs...)
		}
	} else {
		v.Containers, v.Entrypoint = nil, ""
	}
	if r.FormValue("own_options") == "1" {
		if _, shown := r.Form["options_shown"]; shown && v.OwnOptions() {
			internet, probe, rl := optionsFromForm(r)
			v.InternetAccess, v.Probe, v.RateLimit = &internet, probe, rl
		} else if !v.OwnOptions() {
			internet := po.Internet
			v.InternetAccess, v.Probe, v.RateLimit = &internet, po.Probe, po.RateLimit
		}
	} else {
		v.InternetAccess, v.Probe, v.RateLimit = nil, "", nil
	}
	e.Environments[env] = v
	return e, errs
}

// cloneEntry : copie profonde (par JSON) : le formulaire ne touche jamais l'entrée lue sur main.
func cloneEntry(e Entry) Entry {
	var out Entry
	b, _ := json.Marshal(e)
	_ = json.Unmarshal(b, &out)
	if out.Environments == nil {
		out.Environments = map[string]Env{}
	}
	return out
}

// newEnv : un environnement neuf, en VPN et données séparées ; le reste hérite du parent.
func (s *Server) newEnv(e Entry, branch, from string) Env {
	v := Env{Branch: branch, From: from, Expose: "vpn"}
	if pa, _, _, err := e.sections(from, 0); err == nil && pa.Expose == "vpn" {
		v.Devices, v.SSO = pa.Devices, pa.SSO
	} else {
		v.Devices = append([]string(nil), s.cfg.Peers...)
		sort.Strings(v.Devices)
	}
	return v
}

// withoutEnv : l'entrée sans un environnement ; ceux qui en héritaient héritent de son parent.
func withoutEnv(e Entry, id string) Entry {
	out := cloneEntry(e)
	from := out.Environments[id].From
	delete(out.Environments, id)
	for k, v := range out.Environments {
		if v.From == id {
			v.From = from
			out.Environments[k] = v
		}
	}
	return out
}

// previewOf : diff de l'entrée, erreurs et message de commit proposé.
func (s *Server) previewOf(name string, e *Entry, snap *Snapshot, isNew bool, msg string, errs []string) PreviewVM {
	p := PreviewVM{New: isNew, Errors: errs}
	if isNew {
		p.ApplyURL = "/sites/new/apply"
	} else {
		p.ApplyURL = "/sites/" + name + "/apply"
	}
	// L'avant est relu puis réécrit comme le ferait la page : une écriture à la main équivalente
	// (`"sso": false`, ordre des clés) ne compte pas comme un changement.
	var before, after []string
	if old, ok := snap.Apps.Entries[name]; ok && !isNew {
		b, _ := entryJSON(old)
		before = entryLines(name, b)
	}
	if e != nil {
		b, _ := entryJSON(*e)
		after = entryLines(name, b)
	}
	p.Lines, p.Adds, p.Dels = diffLines(before, after)
	if e != nil && !isNew {
		// Adresse qui change, environnements compris.
		old := map[string]string{}
		for _, d := range snap.Apps.Entries[name].Deploys(name) {
			old[d.App] = d.Domain(s.cfg.Domain)
		}
		for _, d := range e.Deploys(name) {
			if o, ok := old[d.App]; ok && o != d.Domain(s.cfg.Domain) {
				p.From, p.To = o, d.Domain(s.cfg.Domain)
			}
		}
	}
	p.Dirty = p.Adds+p.Dels > 0
	p.Message = msg
	if p.Message == "" && p.Dirty {
		p.Message = s.summary(name, snap, e, isNew)
	}
	return p
}

// summary : message de commit proposé, d'après ce qui change.
func (s *Server) summary(name string, snap *Snapshot, e *Entry, isNew bool) string {
	if isNew {
		return "feat(" + name + "): add site"
	}
	if e == nil {
		return "feat(" + name + "): remove site"
	}
	old := snap.Apps.Entries[name]
	var parts, touched []string
	if p := s.deployChanges(name, old, *e, ""); len(p) > 0 {
		parts = append(parts, p...)
		touched = append(touched, old.labelOf(""))
	}
	ids := map[string]bool{}
	for id := range old.Environments {
		ids[id] = true
	}
	for id := range e.Environments {
		ids[id] = true
	}
	var sorted []string
	for id := range ids {
		sorted = append(sorted, id)
	}
	sort.Strings(sorted)
	for _, id := range sorted {
		_, was := old.Environments[id]
		_, is := e.Environments[id]
		switch {
		case !was:
			parts = append(parts, "add "+id+" environment")
		case !is:
			parts = append(parts, "remove "+id+" environment")
		default:
			p := s.deployChanges(name, old, *e, id)
			if len(p) == 0 {
				continue
			}
			parts = append(parts, id+": "+strings.Join(p, ", "))
		}
		touched = append(touched, id)
	}
	if len(parts) == 0 {
		parts = append(parts, "update site")
	}
	msg := "feat(" + name + "): " + strings.Join(parts, ", ")
	if len(msg) > 100 {
		msg = "feat(" + name + "): update " + strings.Join(touched, ", ")
		if len(msg) > 100 {
			msg = "feat(" + name + "): update site"
		}
	}
	return msg
}

// deployChanges : ce qui change pour un déploiement entre deux entrées.
func (s *Server) deployChanges(name string, old, cur Entry, id string) []string {
	a, err1 := old.Deploy(name, id)
	b, err2 := cur.Deploy(name, id)
	if err1 != nil || err2 != nil {
		return nil
	}
	var parts []string
	if id != "" {
		ov, nv := old.Environments[id], cur.Environments[id]
		if ov.Branch != nv.Branch {
			parts = append(parts, "track "+nv.Branch)
		}
		if ov.From != nv.From {
			parts = append(parts, "inherit from "+cur.labelOf(nv.From))
		}
		if ov.Name != nv.Name {
			parts = append(parts, "rename to "+b.Label)
		}
		if ov.DataMode() != nv.DataMode() {
			parts = append(parts, map[string]string{"separate": "separate data", "copy": "copy data", "shared": "share data"}[nv.DataMode()])
		}
		for _, x := range []struct {
			was, is bool
			what    string
		}{{ov.OwnAccess(), nv.OwnAccess(), "access"}, {ov.OwnContainers(), nv.OwnContainers(), "containers"}, {ov.OwnOptions(), nv.OwnOptions(), "options"}} {
			if x.was != x.is {
				if x.is {
					parts = append(parts, "own "+x.what)
				} else {
					parts = append(parts, "inherit "+x.what)
				}
			}
		}
	} else if old.Name != cur.Name {
		parts = append(parts, "rename to "+b.Label)
	}
	if a.Tag != b.Tag {
		switch {
		case b.Frozen():
			parts = append(parts, "roll back to "+shortTag(b.Tag))
		case a.Frozen():
			parts = append(parts, "follow "+b.Branch+" again")
		case id == "":
			parts = append(parts, "track "+b.Branch)
		}
	}
	if a.Domain(s.cfg.Domain) != b.Domain(s.cfg.Domain) && a.Access.Expose == b.Access.Expose {
		parts = append(parts, "move to "+b.Domain(s.cfg.Domain))
	}
	if a.Access.Expose != b.Access.Expose {
		if b.VPN() {
			parts = append(parts, "restrict to vpn")
		} else {
			parts = append(parts, "make public")
		}
	} else if b.VPN() && strings.Join(a.Access.Devices, ",") != strings.Join(b.Access.Devices, ",") {
		parts = append(parts, "update devices")
	}
	if a.Access.SSO != b.Access.SSO {
		if b.Access.SSO {
			parts = append(parts, "require login")
		} else {
			parts = append(parts, "drop login")
		}
	}
	if a.Options.Internet != b.Options.Internet {
		if b.Options.Internet {
			parts = append(parts, "allow internet")
		} else {
			parts = append(parts, "block internet")
		}
	}
	if fmt.Sprint(a.Options.RateLimit) != fmt.Sprint(b.Options.RateLimit) && !(a.Options.RateLimit != nil && b.Options.RateLimit != nil && strings.Join(*a.Options.RateLimit, " ") == strings.Join(*b.Options.RateLimit, " ")) {
		parts = append(parts, "update rate limit")
	}
	if a.Options.Probe != b.Options.Probe {
		parts = append(parts, "change health path")
	}
	ac, _ := json.Marshal(stripTags(a.Ctrs))
	bc, _ := json.Marshal(stripTags(b.Ctrs))
	if string(ac) != string(bc) {
		parts = append(parts, "update containers")
	}
	return parts
}

func stripTags(c Ctrs) Ctrs {
	out := Ctrs{Containers: map[string]Container{}, Entrypoint: c.Entrypoint}
	for n, ct := range c.Containers {
		ct.Image = untag(ct.Image)
		out.Containers[n] = ct
	}
	return out
}

func (s *Server) editor(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := r.PathValue("app")
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	e, ok := snap.Apps.Entries[name]
	if !ok {
		// Site en cours d'ajout : pas encore dans apps.json, on montre sa demande.
		if j := s.jobs.latest(name); j != nil {
			s.render(w, "job-page", map[string]any{"Nav": "sites", "Job": j.Snapshot()})
			return
		}
		http.NotFound(w, r)
		return
	}
	q := r.URL.Query()
	env := q.Get("env")
	addErr := ""
	if q.Get("new") == "1" {
		// Nouvel environnement : un brouillon, rien n'est écrit avant « Appliquer ».
		from := q.Get("from")
		_, exists := e.Environments[env]
		_, parentOK := e.Environments[from]
		switch {
		case !reEnvID.MatchString(env):
			addErr = "Nom : minuscules, chiffres et tirets, 16 caractères au plus, commençant par une lettre."
		case exists:
			addErr = env + " existe déjà."
		case !reTag.MatchString(q.Get("branch")):
			addErr = "Choisis la branche à déployer."
		case from != "" && !parentOK:
			addErr = "Parent inconnu."
		}
		if addErr == "" {
			e = cloneEntry(e)
			e.Environments[env] = s.newEnv(e, q.Get("branch"), from)
		} else {
			env = ""
			if parentOK {
				env = from
			}
		}
	}
	if _, known := e.Environments[env]; env != "" && !known {
		http.Redirect(w, r, "/sites/"+name, http.StatusFound)
		return
	}
	repo := s.sourceRepo(ctx, e)
	f := s.formVMFor(ctx, name, e, env, false, repo, s.repoImages(ctx, repo), snap)
	f.AddError = addErr
	if addErr != "" {
		f.AddName = q.Get("env")
	}
	up := s.probes(ctx)
	f.Up, f.Probed = up[f.Domain]
	f.Preview = s.previewOf(name, &e, snap, false, "", validate(s.cfg, name, e, snap.Apps.Entries))
	if j := s.jobs.latest(name); j != nil {
		snapJob := j.Snapshot()
		if b := badgeOf(snapJob); b != nil {
			switch b.Kind {
			case "running":
				f.Running = &snapJob
			case "failed":
				f.Failed = b
			}
		}
	}
	s.render(w, "editor", map[string]any{"Nav": "sites", "F": f})
}

// formRequest : nom, entrée de départ, images permises et dépôt de la requête.
func (s *Server) formRequest(ctx context.Context, r *http.Request, snap *Snapshot) (name string, current Entry, allowed []string, repo string, isNew bool, err error) {
	name = r.PathValue("app")
	isNew = name == ""
	if isNew {
		name = strings.TrimSpace(r.FormValue("name"))
		repo = r.FormValue("repo")
		allowed = s.repoImages(ctx, repo)
		return name, Entry{}, allowed, repo, true, nil
	}
	e, ok := snap.Apps.Entries[name]
	if !ok {
		return "", Entry{}, nil, "", false, fmt.Errorf("%s n'existe plus sur main", name)
	}
	repo = s.sourceRepo(ctx, e)
	allowed = s.repoImages(ctx, repo)
	for _, c := range e.Containers {
		if img := untag(c.Image); !slices.Contains(allowed, img) {
			allowed = append(allowed, img)
		}
	}
	return name, e, allowed, repo, false, nil
}

// requestEntry : entrée et erreurs d'une soumission du formulaire.
func (s *Server) requestEntry(r *http.Request) (string, string, *Entry, *Snapshot, PreviewVM, bool, error) {
	ctx := r.Context()
	if err := r.ParseForm(); err != nil {
		return "", "", nil, nil, PreviewVM{}, false, err
	}
	snap, err := s.snapshot(ctx)
	if err != nil {
		return "", "", nil, nil, PreviewVM{}, false, err
	}
	name, current, allowed, repo, isNew, err := s.formRequest(ctx, r, snap)
	if err != nil {
		return "", "", nil, nil, PreviewVM{}, false, err
	}
	env := r.FormValue("env")
	if isNew || !reEnvID.MatchString(env) {
		env = ""
	}
	e, errs := s.entryFromForm(r, name, current, env, allowed, repo)
	if isNew {
		if _, exists := snap.Apps.Entries[name]; exists {
			errs = append(errs, "Un site s'appelle déjà "+name+".")
		}
		if len(allowed) == 0 {
			errs = append(errs, "Aucune image trouvée pour ce dépôt.")
		}
	}
	if len(e.Environments) == 0 {
		e.Environments = nil
	}
	errs = append(errs, validate(s.cfg, name, e, snap.Apps.Entries)...)
	p := s.previewOf(name, &e, snap, isNew, strings.TrimSpace(r.FormValue("msg")), errs)
	return name, env, &e, snap, p, isNew, nil
}

func (s *Server) preview(w http.ResponseWriter, r *http.Request) {
	_, _, _, _, p, _, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "preview", p)
}

// reform : le formulaire refait à partir de ce qui est saisi (section propre ou héritée, conteneur
// ajouté ou retiré, parent ou branche changés) : la page ne calcule rien elle-même.
func (s *Server) reform(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name, env, e, snap, p, isNew, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	repo := r.FormValue("repo")
	if !isNew {
		repo = s.sourceRepo(ctx, snap.Apps.Entries[name])
	}
	f := s.formVMFor(ctx, name, *e, env, isNew, repo, s.repoImages(ctx, repo), snap)
	f.Base = r.FormValue("base")
	if isNew {
		f.Base = "new"
	}
	f.Preview = p
	s.render(w, "form", f)
}

func (s *Server) apply(w http.ResponseWriter, r *http.Request) {
	name, _, e, snap, p, isNew, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.startApply(w, r, name, e, snap, p, isNew)
}

var reCommitMessage = regexp.MustCompile(`^[[:print:]]{1,100}$`)

// startApply : lance la demande si l'aperçu est propre et que la page est à jour. Le verrou rend atomique
// « aucune demande en cours » puis « lancer » : deux envois simultanés ne partent pas ensemble.
func (s *Server) startApply(w http.ResponseWriter, r *http.Request, name string, e *Entry, snap *Snapshot, p PreviewVM, isNew bool) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	if j := s.jobs.latest(name); j != nil && !j.Snapshot().Done {
		p.Errors = append(p.Errors, "Une modification de "+name+" est déjà en cours : attends qu'elle se termine.")
	}
	if len(p.Errors) > 0 || !p.Dirty {
		s.render(w, "preview", p)
		return
	}
	base := r.FormValue("base")
	if isNew {
		base = "new"
	}
	if base != snap.Apps.Fingerprint(name) {
		p.Errors = append(p.Errors, name+" a changé sur main depuis l'ouverture de la page. Recharge-la.")
		s.render(w, "preview", p)
		return
	}
	msg := p.Message
	if !reCommitMessage.MatchString(msg) {
		p.Errors = append(p.Errors, "Message de commit : une ligne de 100 caractères au plus.")
		s.render(w, "preview", p)
		return
	}
	var old *Entry
	if o, ok := snap.Apps.Entries[name]; ok {
		old = &o
	}
	j := s.startJob(Request{App: name, Entry: e, Old: old, Base: base, Message: msg})
	if !isNew {
		// La page se recharge : bandeau « en cours », formulaire grisé, suivi à droite.
		w.Header().Set("HX-Refresh", "true")
	}
	s.render(w, "job", j.Snapshot())
}

// removeEnv : retire un environnement (ceux qui en héritaient passent à son parent).
func (s *Server) removeEnv(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name, id := r.PathValue("app"), r.PathValue("env")
	if err := r.ParseForm(); err != nil {
		s.renderError(w, err)
		return
	}
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.renderError(w, err)
		return
	}
	cur, ok := snap.Apps.Entries[name]
	if _, has := cur.Environments[id]; !ok || !has {
		s.renderError(w, fmt.Errorf("%s n'a pas d'environnement %s sur main", name, id))
		return
	}
	e := withoutEnv(cur, id)
	if len(e.Environments) == 0 {
		e.Environments = nil
	}
	p := s.previewOf(name, &e, snap, false, "feat("+name+"): remove "+id+" environment", validate(s.cfg, name, e, snap.Apps.Entries))
	s.startApply(w, r, name, &e, snap, p, false)
}

// recopy : demande à admin-recopy (root) de recopier les données du parent.
func (s *Server) recopy(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name, id := r.PathValue("app"), r.PathValue("env")
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.renderError(w, err)
		return
	}
	e := snap.Apps.Entries[name]
	v, ok := e.Environments[id]
	if !ok || v.DataMode() != "copy" {
		http.Error(w, "environnement inconnu ou sans données « copie »", http.StatusBadRequest)
		return
	}
	dir := filepath.Join(s.cfg.StateDir, "recopy")
	if err = os.MkdirAll(dir, 0o755); err == nil {
		err = os.WriteFile(filepath.Join(dir, name+"-"+id+".want"), nil, 0o644)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.render(w, "recopy", map[string]any{"URL": r.URL.Path, "From": e.labelOf(v.From), "R": s.recopyState(name+"-"+id, e.labelOf(v.From))})
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	ctx := r.Context()
	name := r.PathValue("app")
	if err := r.ParseForm(); err != nil {
		s.renderError(w, err)
		return
	}
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.renderError(w, err)
		return
	}
	e, ok := snap.Apps.Entries[name]
	if !ok {
		s.renderError(w, fmt.Errorf("%s n'existe plus sur main", name))
		return
	}
	if j := s.jobs.latest(name); j != nil && !j.Snapshot().Done {
		s.renderError(w, fmt.Errorf("une modification de %s est déjà en cours : attends qu'elle se termine", name))
		return
	}
	if r.FormValue("confirm") != name {
		s.renderError(w, fmt.Errorf("tape %s pour confirmer la suppression", name))
		return
	}
	base := r.FormValue("base")
	if base != snap.Apps.Fingerprint(name) {
		s.renderError(w, fmt.Errorf("%s a changé sur main depuis l'ouverture de la page : recharge-la", name))
		return
	}
	j := s.startJob(Request{App: name, Entry: nil, Old: &e, Base: base, Message: "feat(" + name + "): remove site"})
	s.render(w, "job", j.Snapshot())
}

func (s *Server) renderError(w http.ResponseWriter, err error) {
	s.render(w, "preview", PreviewVM{Errors: []string{err.Error()}})
}

func (s *Server) job(w http.ResponseWriter, r *http.Request) {
	j := s.jobs.get(r.PathValue("id"))
	if j == nil {
		http.NotFound(w, r)
		return
	}
	s.render(w, "job", j.Snapshot())
}

// recopyStatus : l'état de la recopie, redemandé par la page tant qu'elle tourne.
func (s *Server) recopyStatus(w http.ResponseWriter, r *http.Request) {
	snap, err := s.snapshot(r.Context())
	if err != nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	name, id := r.PathValue("app"), r.PathValue("env")
	e := snap.Apps.Entries[name]
	v, ok := e.Environments[id]
	if !ok {
		http.NotFound(w, r)
		return
	}
	s.render(w, "recopy", map[string]any{"URL": r.URL.Path, "R": s.recopyState(name+"-"+id, e.labelOf(v.From))})
}
