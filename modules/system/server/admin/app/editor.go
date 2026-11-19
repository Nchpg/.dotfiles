package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
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
	// Environnement : le mode de ce dossier (champ `dmode_<conteneur>:<chemin>`), et sa recopie
	// quand il est en copie sur main.
	Ctr, Key, ModeField, Mode string
	Recopy                    *RecopyVM
	RecopyURL, RecopyID       string
}

type CtrVM struct {
	Name   string
	Entry  bool
	Image  DD
	Memory DD
	Deps   []Opt
	Data   []DataVM
	// Secrets donnés au conteneur, dans l'ordre (une variable en double : le dernier l'emporte), puis
	// ceux du site qu'on peut ajouter, et le nom proposé pour en créer un.
	Secrets     []SecretVM
	SecretsFree []Opt
	NewSecret   string
	Info        string
	DataHost    string
	Locked      bool // conteneurs hérités : montrés, pas modifiables ici
}

// SecretVM : un secret coché d'un conteneur, à sa place dans la liste.
type SecretVM struct {
	Value, Note string
	First, Last bool
}

type EnvTab struct {
	ID, Label, Branch, Domain, URL string
	Current, Root, New             bool
}

type RecopyVM struct {
	State, Text string // State : running, busy (un autre dossier se recopie), done, failed
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
	Accounts     []Opt // comptes Authelia, cochés s'ils sont admis
	Containers   []CtrVM
	CtrList      string
	Multi        bool
	NewImages    []Opt // images du dépôt sans conteneur : à ajouter
	Version      DD
	VersionNote  string
	Branch       DD
	Frozen       bool
	Up, Probed   bool
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
	DataFrom                 string   // environnement : le parent dont un dossier se copie ou se partage
	DataModes                []DataVM // environnement : section Données, le mode de chaque dossier (toujours le sien)
	RemoveEnvURL             string
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
	Auto     bool // Message proposé par le dashboard (pas écrit à la main) : recalculé à chaque aperçu
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
// trouvé pendant une panne de l'API des packages, la réponse n'est pas gardée (relue après une minute).
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
		return repo // panne : valeur du moment (vide pour ceux qui attendaient la même lecture)
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

var memories = [][2]string{{"", "Sans limite"}, {"64m", "64 Mo"}, {"128m", "128 Mo"}, {"256m", "256 Mo"}, {"512m", "512 Mo"}, {"1g", "1 Go"}, {"2g", "2 Go"}}

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
		Multi: len(d.Ctrs.Containers) > 1, OwnAccess: true, OwnContainers: true, OwnOptions: true,
	}
	// Sous-domaine : vide pour un nouveau site (son nom, même renommé ensuite), sinon celui servi.
	f.Sub = d.Subdomain
	if f.Sub == "" && !isNew {
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
	for _, a := range s.accountChoices(d.Access.Accounts) {
		f.Accounts = append(f.Accounts, Opt{Value: a, Label: a, Selected: slices.Contains(d.Access.Accounts, a)})
	}

	if d.Child {
		v := e.Environments[env]
		f.OwnAccess, f.OwnContainers, f.OwnOptions = v.OwnAccess(), v.OwnContainers(), v.OwnOptions()
		_, onMain := onMainEnvs[env]
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
			if d.Access.Accounts != nil {
				f.AccessSummary[len(f.AccessSummary)-1] += " : " + strings.Join(d.Access.Accounts, ", ")
			}
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
		f.DataFrom = parent
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
			dv := DataVM{Value: dt.Path + "\t" + dt.On, Path: dt.Path, Host: host, Auto: dt.On == ""}
			if env != "" {
				dv.Key = n + ":" + dt.Path
				dv.ModeField, dv.Mode = "dmode_"+dv.Key, e.Environments[env].Data.Mode(n, dt.Path)
				// Recopie : seulement un dossier déjà en copie sur main (celui qui tourne).
				if mv, ok := onMainEnvs[env]; ok && dv.Mode == "copy" && mv.Data.Mode(n, dt.Path) == "copy" {
					dv.Recopy = s.recopyState(d.App, host)
					dv.RecopyURL, dv.RecopyID = "/sites/"+name+"/env/"+env+"/recopy", recopyID(dv.Key)
				}
			}
			vm.Data = append(vm.Data, dv)
			if dv.ModeField != "" {
				dv.Ctr = n
				f.DataModes = append(f.DataModes, dv)
			}
		}
		for i, k := range c.Secrets {
			sv := SecretVM{Value: k, First: i == 0, Last: i == len(c.Secrets)-1}
			if !slices.Contains(secrets, k) {
				sv.Note = "absent du dépôt de secrets"
			}
			vm.Secrets = append(vm.Secrets, sv)
		}
		for _, k := range secrets {
			if !slices.Contains(c.Secrets, k) {
				vm.SecretsFree = append(vm.SecretsFree, Opt{Value: k, Label: k})
			}
		}
		vm.NewSecret = name + "/<nom>"
		if env != "" {
			vm.NewSecret = name + "/" + env + "_<nom>"
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

var reNotAlnum = regexp.MustCompile(`[^A-Za-z0-9]+`)

// recopyID : l'identifiant de la ligne de recopie d'un dossier (`web:/app/data` -> `recopy-web-app-data`).
func recopyID(key string) string {
	return "recopy-" + strings.Trim(reNotAlnum.ReplaceAllString(key, "-"), "-")
}

// Recopie restée sans nouvelles : une demande que personne ne prend (admin-recopy arrêté), ou une
// copie notée « en cours » par un admin-recopy tué en route. Au-delà, elle compte comme échouée (et
// peut être redemandée) au lieu de bloquer le bouton pour toujours.
const (
	recopyPickup = 10 * time.Minute
	recopyMax    = 30 * time.Minute
)

// recopyFiles : la demande déposée pour `app` (dossiers, heure ; nil sans demande) et le dernier
// résultat d'admin-recopy.
type recopyFiles struct {
	Want   []string
	WantAt time.Time
	State  string   `json:"state"`
	Detail string   `json:"detail"`
	At     int64    `json:"at"`
	Paths  []string `json:"paths"`
}

func (s *Server) readRecopy(app string) recopyFiles {
	var st recopyFiles
	want := filepath.Join(s.cfg.StateDir, "recopy", app+".want")
	if b, err := os.ReadFile(want); err == nil {
		st.Want = strings.Fields(string(b))
		if fi, err := os.Stat(want); err == nil {
			st.WantAt = fi.ModTime()
		}
	}
	if b, err := os.ReadFile(filepath.Join(s.cfg.RecopyStatus, app+".json")); err == nil {
		_ = json.Unmarshal(b, &st)
	}
	return st
}

// active : une recopie est demandée ou en cours pour cette app (pas restée sans nouvelles).
func (st recopyFiles) active() bool {
	return (st.Want != nil && time.Since(st.WantAt) < recopyPickup) || (st.State == "running" && time.Since(time.Unix(st.At, 0)) < recopyMax)
}

// recopyState : la recopie d'un dossier (`target`, son emplacement) d'un environnement en copie, d'après
// la demande déposée et le dernier résultat d'admin-recopy (root), qui note les dossiers recopiés.
func (s *Server) recopyState(app, target string) *RecopyVM {
	vm := &RecopyVM{Text: "Remplace ce dossier par celui du parent ; l'environnement est arrêté pendant la copie."}
	st := s.readRecopy(app)
	if st.Want != nil {
		switch {
		case time.Since(st.WantAt) >= recopyPickup:
			vm.State, vm.Text = "failed", "Demande pas prise en charge (admin-recopy arrêté ? journalctl -u admin-recopy) : redemande-la."
		case slices.Contains(st.Want, target):
			vm.State, vm.Text = "running", "Recopie demandée…"
		default:
			vm.State, vm.Text = "busy", "Un autre dossier se recopie : attends la fin."
		}
		return vm
	}
	mine := len(st.Paths) == 0 || slices.Contains(st.Paths, target)
	when := time.Unix(st.At, 0).Local().Format("02/01 15:04")
	stale := time.Since(time.Unix(st.At, 0)) >= recopyMax
	switch {
	case st.State == "running" && stale && mine:
		vm.State, vm.Text = "failed", "La recopie du "+when+" a été interrompue (journalctl -u admin-recopy) : redemande-la."
	case st.State == "running" && stale:
	case st.State == "running" && mine:
		vm.State, vm.Text = "running", "Recopie en cours (depuis "+when+")…"
	case st.State == "running":
		vm.State, vm.Text = "busy", "Un autre dossier se recopie : attends la fin."
	case st.State == "done" && mine:
		vm.State, vm.Text = "done", "Recopié le "+when+"."
	case st.State == "failed" && mine:
		vm.State, vm.Text = "failed", "La recopie du "+when+" a échoué : "+st.Detail
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
			c.Internal, c.ReadOnly = p.Internal, p.ReadOnly // pas dans le formulaire : gardés tels quels
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
		// Dans l'ordre de la page (les cochés à la suite des déjà présents), puis ↑ ↓ ✕.
		for _, k := range r.Form["sec_"+n] {
			if !slices.Contains(c.Secrets, k) {
				c.Secrets = append(c.Secrets, k)
			}
		}
		c.Secrets = reorderSecrets(c.Secrets, n, r.FormValue("secmove"), r.FormValue("secrm"))
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

// dataModesFromForm : le mode de chaque dossier montré dans la page (`dmode_<conteneur>:<chemin>`) ;
// nil si la page n'en montre aucun.
func dataModesFromForm(r *http.Request) map[string]string {
	var out map[string]string
	for k, vals := range r.Form {
		if key, ok := strings.CutPrefix(k, "dmode_"); ok && len(vals) > 0 && slices.Contains(dataModes, vals[0]) {
			if out == nil {
				out = map[string]string{}
			}
			out[key] = vals[0]
		}
	}
	return out
}

// sameJSON : deux valeurs s'écrivent pareil en JSON.
func sameJSON(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

// reorderSecrets : « monter », « descendre » (secmove = `conteneur|secret|up` ou `down`) ou
// retirer (secrm = `conteneur|secret`) un secret du conteneur `ctr`.
func reorderSecrets(keys []string, ctr, move, rm string) []string {
	if c, k, ok := strings.Cut(rm, "|"); ok && c == ctr {
		keys = slices.DeleteFunc(keys, func(x string) bool { return x == k })
	}
	if c, rest, ok := strings.Cut(move, "|"); ok && c == ctr {
		k, dir, _ := strings.Cut(rest, "|")
		if i := slices.Index(keys, k); i >= 0 {
			j := i - 1
			if dir == "down" {
				j = i + 1
			}
			if j >= 0 && j < len(keys) {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	return keys
}

// accessFromForm : la section accès du formulaire. `current` : les comptes avant, gardés si leurs
// cases ne sont pas dans la page.
func (s *Server) accessFromForm(r *http.Request, current []string) (expose string, devices []string, sso bool, accounts []string) {
	expose = "public"
	if r.FormValue("expose") == "vpn" {
		expose = "vpn"
		devices = r.Form["dev"]
		sort.Strings(devices)
	}
	sso = r.FormValue("sso") == "on"
	if sso {
		accounts = current
		if _, shown := r.Form["acct_shown"]; shown {
			accounts = accountsFromForm(r.Form["acct"], s.accountChoices(current))
		}
	}
	return expose, devices, sso, accounts
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
		expose, devices, sso, accounts := s.accessFromForm(r, current.Accounts)
		e.Expose, e.Devices, e.SSO, e.Accounts = "", nil, sso, accounts
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
	if modes := dataModesFromForm(r); modes != nil {
		v.Data = nil
		for k, m := range modes {
			if m != "separate" {
				if v.Data == nil {
					v.Data = DataModes{}
				}
				v.Data[k] = m
			}
		}
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
	// Une section « propre » se lit dans la page dès qu'elle y est affichée comme telle (même si main
	// l'a encore héritée : elle vient d'y passer) ; sinon, elle part des valeurs du parent.
	if r.FormValue("own_access") == "1" {
		if _, shown := r.Form["expose"]; shown {
			v.Expose, v.Devices, v.SSO, v.Accounts = s.accessFromForm(r, v.Accounts)
		} else if !v.OwnAccess() {
			v.Expose, v.Devices, v.SSO, v.Accounts = pa.Expose, pa.Devices, pa.SSO, pa.Accounts
		}
	} else {
		v.Expose, v.Devices, v.SSO, v.Accounts = "", nil, false, nil
	}
	if r.FormValue("own_containers") == "1" {
		// Les conteneurs du parent, sans tag : point de départ, et images de repli du formulaire.
		parentCtrs := map[string]Container{}
		for n, c := range pc.Containers {
			c.Image = untag(c.Image)
			parentCtrs[n] = c
		}
		if _, shown := r.Form["containers"]; shown {
			prev := v.Containers
			if !v.OwnContainers() {
				prev = parentCtrs
			}
			var cerrs []string
			v.Containers, v.Entrypoint, cerrs = s.containersFromForm(r, prev, allowed, repo, "")
			errs = append(errs, cerrs...)
		} else if !v.OwnContainers() {
			v.Containers, v.Entrypoint = parentCtrs, pc.Entrypoint
		}
	} else {
		v.Containers, v.Entrypoint = nil, ""
	}
	if r.FormValue("own_options") == "1" {
		if _, shown := r.Form["options_shown"]; shown {
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
		v.Devices, v.SSO, v.Accounts = pa.Devices, pa.SSO, pa.Accounts
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
		p.Message, p.Auto = s.summary(name, snap, e, isNew), true
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
		if !sameJSON(ov.Data, nv.Data) {
			parts = append(parts, "set data folders")
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
	} else if b.Access.SSO && strings.Join(a.Access.Accounts, ",") != strings.Join(b.Access.Accounts, ",") {
		parts = append(parts, "update accounts")
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
		s.failAt(w, r, "sites", err)
		return
	}
	e, ok := snap.Apps.Entries[name]
	if !ok {
		// Site en cours d'ajout : pas encore dans apps.json, on montre sa demande (en cours, ou finie
		// depuis peu : un échec reste visible 30 minutes, comme dans la liste, puis la page disparaît).
		if j := s.jobs.latest(name); j != nil && badgeOf(j.Snapshot()) != nil {
			s.render(w, "job-page", map[string]any{"Nav": "sites", "PageTitle": name, "Job": j.Snapshot()})
			return
		}
		s.notFound(w, r, "sites", name+" n'existe pas (ou plus) sur main.")
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
	s.render(w, "editor", map[string]any{"Nav": "sites", "PageTitle": name, "F": f})
}

// errSiteGone : le site de la page n'est plus sur main (supprimé d'ailleurs entre-temps).
var errSiteGone = errors.New("n'existe plus sur main")

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
		return "", Entry{}, nil, "", false, fmt.Errorf("%s %w", name, errSiteGone)
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

// errBadForm : le corps de la requête est illisible (trop gros, coupé) : rien n'est fait.
var errBadForm = errors.New("formulaire illisible (trop gros ou coupé) : rien n'a été changé")

// requestEntry : entrée et erreurs d'une soumission du formulaire.
func (s *Server) requestEntry(r *http.Request) (string, string, *Entry, *Snapshot, PreviewVM, bool, error) {
	ctx := r.Context()
	if err := r.ParseForm(); err != nil {
		return "", "", nil, nil, PreviewVM{}, false, errBadForm
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
	// Message proposé (msg_auto) renvoyé tel quel : recalculé d'après ce qui change maintenant ; un
	// message écrit à la main reste.
	msg := strings.TrimSpace(r.FormValue("msg"))
	if msg == r.FormValue("msg_auto") {
		msg = ""
	}
	p := s.previewOf(name, &e, snap, isNew, msg, errs)
	return name, env, &e, snap, p, isNew, nil
}

// busy : une demande court pour ce site (lancée d'un autre onglet, d'un autre appareil) alors que la
// page était ouverte : elle est rechargée, et s'affiche verrouillée avec les étapes de la demande.
func (s *Server) busy(w http.ResponseWriter, name string) bool {
	if j := s.jobs.latest(name); j != nil && !j.Snapshot().Done {
		w.Header().Set("HX-Refresh", "true")
		w.WriteHeader(http.StatusNoContent)
		return true
	}
	return false
}

func (s *Server) preview(w http.ResponseWriter, r *http.Request) {
	name, _, _, _, p, isNew, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	if !isNew && s.busy(w, name) {
		return
	}
	s.render(w, "preview", p)
}

// reform : le formulaire refait à partir de ce qui est saisi (section propre ou héritée, conteneur
// ajouté ou retiré, parent ou branche changés) : la page ne calcule rien elle-même. Une erreur (main
// injoignable, site supprimé) ne remplace pas le formulaire : un bandeau la dit (app.js), et le
// brouillon rejoué au chargement est oublié.
func (s *Server) reform(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name, env, e, snap, p, isNew, err := s.requestEntry(r)
	if err != nil {
		s.reformError(w, r, err)
		return
	}
	if !isNew && s.busy(w, name) {
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

// reformError : l'erreur d'un formulaire à refaire, avec le code qui va (app.js l'affiche en bandeau).
func (s *Server) reformError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, errBadForm):
		s.badRequest(w, r, "sites", "Formulaire illisible (trop gros ou coupé) : rien n'a été changé.")
	case errors.Is(err, errSiteGone):
		s.httpError(w, r, http.StatusConflict, "sites", err.Error()+" : recharge la page.")
	default:
		s.failAt(w, r, "sites", err)
	}
}

func (s *Server) apply(w http.ResponseWriter, r *http.Request) {
	name, env, e, snap, p, isNew, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.startApply(w, r, Request{App: name, Env: env, Entry: e}, snap, p, isNew)
}

// Une ligne de 100 caractères au plus, accents compris ; pas de caractère de contrôle.
var reCommitMessage = regexp.MustCompile(`^[^\p{Cc}\p{Cf}]{1,100}$`)

// startApply : lance la demande si l'aperçu est propre et que la page est à jour. Le verrou rend atomique
// « aucune demande en cours » puis « lancer » : deux envois simultanés ne partent pas ensemble. La
// page suit ensuite la demande : celle du site (ou de l'environnement), formulaire grisé et étapes à
// droite ; pour un nouveau site, sa page de suivi (le formulaire de création ne reste pas modifiable
// sous les étapes).
func (s *Server) startApply(w http.ResponseWriter, r *http.Request, req Request, snap *Snapshot, p PreviewVM, isNew bool) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	name := req.App
	if j := s.jobs.latest(name); j != nil && !j.Snapshot().Done {
		p.Errors = append(p.Errors, "Une modification de "+name+" est déjà en cours : attends qu'elle se termine.")
	} else if !isNew && s.recopyRunning(name, snap) {
		p.Errors = append(p.Errors, "Une recopie de données de "+name+" est en cours : attends qu'elle se termine.")
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
	if !reCommitMessage.MatchString(p.Message) {
		p.Errors = append(p.Errors, "Message de commit : une ligne de 100 caractères au plus.")
		s.render(w, "preview", p)
		return
	}
	if o, ok := snap.Apps.Entries[name]; ok {
		req.Old = &o
	}
	req.Base, req.Message = base, p.Message
	s.startJob(req)
	s.redirect(w, r, req.page())
}

// recopyRunning : une recopie de données est demandée ou en cours pour un environnement du site
// (elle arrête ses conteneurs : pas de modification en même temps).
func (s *Server) recopyRunning(name string, snap *Snapshot) bool {
	for id := range snap.Apps.Entries[name].Environments {
		if s.readRecopy(name + "-" + id).active() {
			return true
		}
	}
	return false
}

// removeEnv : retire un environnement (ceux qui en héritaient passent à son parent).
func (s *Server) removeEnv(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name, id := r.PathValue("app"), r.PathValue("env")
	if err := r.ParseForm(); err != nil {
		s.renderError(w, errBadForm)
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
	s.startApply(w, r, Request{App: name, Entry: &e}, snap, p, false)
}

// recopyTarget : le dossier (`<conteneur>:<chemin>`, champ `path`) d'un environnement, s'il est en copie
// sur main ; son emplacement sur think.
func (s *Server) recopyTarget(r *http.Request) (app, key, target string, ok bool) {
	snap, err := s.snapshot(r.Context())
	if err != nil {
		return "", "", "", false
	}
	name, id := r.PathValue("app"), r.PathValue("env")
	e := snap.Apps.Entries[name]
	v, found := e.Environments[id]
	key = r.FormValue("path")
	ctr, path, _ := strings.Cut(key, ":")
	if !found || v.Data.Mode(ctr, path) != "copy" {
		return "", "", "", false
	}
	return name + "-" + id, key, e.DataHost(name, id, ctr, path), true
}

// recopy : demande la recopie d'un dossier en copie (admin-recopy, root, le fait). Un refus revient
// dans la ligne elle-même (état « échec », texte visible), comme le résultat d'une recopie. Sous le
// verrou des demandes : une modification du site et une recopie ne partent pas ensemble.
func (s *Server) recopy(w http.ResponseWriter, r *http.Request) {
	perr := r.ParseForm()
	key := r.FormValue("path")
	refuse := func(msg string) {
		s.render(w, "recopy", map[string]any{"URL": r.URL.Path, "Path": key, "ID": recopyID(key), "R": &RecopyVM{State: "failed", Text: msg}})
	}
	if perr != nil {
		refuse("Formulaire illisible : rien n'a été demandé.")
		return
	}
	app, _, target, ok := s.recopyTarget(r)
	if !ok {
		refuse("Ce dossier n'est plus en copie sur main (ou main est injoignable) : recharge la page.")
		return
	}
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	// Pas pendant une modification du site : la recopie arrête ses conteneurs et remplace ses données.
	if j := s.jobs.latest(r.PathValue("app")); j != nil && !j.Snapshot().Done {
		refuse("Une modification du site est en cours : recopie une fois finie.")
		return
	}
	if st := s.recopyState(app, target); st.State == "running" || st.State == "busy" {
		s.render(w, "recopy", map[string]any{"URL": r.URL.Path, "Path": key, "ID": recopyID(key), "R": st})
		return
	}
	dir := filepath.Join(s.cfg.StateDir, "recopy")
	err := os.MkdirAll(dir, 0o755)
	if err == nil {
		err = os.WriteFile(filepath.Join(dir, app+".want"), []byte(target+"\n"), 0o644)
	}
	if err != nil {
		log.Printf("recopie %s : %v", app, err)
		refuse("Demande pas déposée : " + err.Error())
		return
	}
	s.render(w, "recopy", map[string]any{"URL": r.URL.Path, "Path": key, "ID": recopyID(key), "R": s.recopyState(app, target)})
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	ctx := r.Context()
	name := r.PathValue("app")
	if err := r.ParseForm(); err != nil {
		s.renderError(w, errBadForm)
		return
	}
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.renderError(w, err)
		return
	}
	e, ok := snap.Apps.Entries[name]
	if !ok {
		s.renderError(w, fmt.Errorf("%s %w", name, errSiteGone))
		return
	}
	if j := s.jobs.latest(name); j != nil && !j.Snapshot().Done {
		s.renderError(w, fmt.Errorf("une modification de %s est déjà en cours : attends qu'elle se termine", name))
		return
	}
	if s.recopyRunning(name, snap) {
		s.renderError(w, fmt.Errorf("une recopie de données de %s est en cours : attends qu'elle se termine", name))
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
	// Comme une modification : la page du site, verrouillée, suit la suppression.
	s.startJob(Request{App: name, Entry: nil, Old: &e, Base: base, Message: "feat(" + name + "): remove site"})
	s.redirect(w, r, "/sites/"+name)
}

// renderError : une erreur de la demande, dans l'aperçu (là où l'on regarde après avoir cliqué).
func (s *Server) renderError(w http.ResponseWriter, err error) {
	s.render(w, "preview", PreviewVM{Errors: []string{err.Error()}})
}

func (s *Server) job(w http.ResponseWriter, r *http.Request) {
	j := s.jobs.get(r.PathValue("id"))
	if j == nil {
		s.notFound(w, r, "sites", "Cette demande n'est plus suivie (terminée depuis longtemps) : recharge la page.")
		return
	}
	s.render(w, "job", j.Snapshot())
}

// recopyStatus : l'état de la recopie, redemandé par la page tant qu'elle tourne.
func (s *Server) recopyStatus(w http.ResponseWriter, r *http.Request) {
	app, key, target, ok := s.recopyTarget(r)
	if !ok {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.render(w, "recopy", map[string]any{"URL": r.URL.Path, "Path": key, "ID": recopyID(key), "R": s.recopyState(app, target)})
}
