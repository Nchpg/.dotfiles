package main

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

type Opt struct {
	Value, Label, Note string
	Selected           bool
}

type DataVM struct {
	Value, Path, Host string
	Auto              bool
}

type CtrVM struct {
	Name     string
	Entry    bool
	Images   []Opt
	Memory   []Opt
	Deps     []Opt
	Data     []DataVM
	Secrets  []Opt
	Info     string
	NewInfo  string
	DataHost string
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
	Versions     []Opt
	VersionNote  string
	Frozen       bool
	Up, Probed   bool
	Initial      string
	Tint, Ink    string
	Preview      PreviewVM
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

// sourceRepo : dépôt GitHub d'un site, lu dans le label de son image.
func (s *Server) sourceRepo(ctx context.Context, e Entry) string {
	c := e.Containers[e.EntryPoint()]
	info, err := s.reg.Inspect(ctx, s.cfg.ref(c.Image))
	if err != nil {
		return ""
	}
	return info.Source
}

// versions : `main` et chaque commit dont toutes les images du site ont le tag `sha-…`.
func (s *Server) versions(ctx context.Context, e Entry, repo string) ([]Opt, string) {
	current := e.Version()
	var names []string
	for _, n := range e.ContainerNames() {
		img, _ := splitImage(e.Containers[n].Image)
		names = append(names, s.cfg.ref(img))
	}
	opts := []Opt{{Value: "main", Label: "main · toujours la dernière"}}
	tags, err := s.reg.ShaTags(ctx, names)
	note := ""
	if err != nil {
		note = "Versions illisibles sur le registre : " + err.Error()
	}
	type v struct {
		tag  string
		date time.Time
		text string
	}
	var vs []v
	for _, t := range tags {
		sha := strings.TrimPrefix(t, "sha-")
		item := v{tag: t, text: shortTag(t)}
		if c, ok := s.gh.CommitOf(ctx, repo, sha); ok {
			item.date = c.Date
			item.text = shortTag(t) + " · " + c.Subject
			if !c.Date.IsZero() {
				item.text += " (" + c.Date.Local().Format("02/01") + ")"
			}
		}
		vs = append(vs, item)
	}
	sort.SliceStable(vs, func(i, j int) bool { return vs[i].date.After(vs[j].date) })
	if len(vs) > 20 {
		vs = vs[:20]
	}
	found := current == "main" || current == ""
	for _, x := range vs {
		opts = append(opts, Opt{Value: x.tag, Label: x.text})
		found = found || x.tag == current
	}
	if !found {
		opts = append(opts, Opt{Value: current, Label: current + " (tag actuel)"})
	}
	if current == "" {
		opts = append([]Opt{{Value: "", Label: "tags différents par conteneur"}}, opts...)
	}
	for i := range opts {
		opts[i].Selected = opts[i].Value == current
	}
	if len(vs) == 0 && note == "" {
		note = "Aucun tag sha-… commun à toutes les images : seules les images construites par le template en ont."
	}
	return opts, note
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

// formVM : le formulaire pré-rempli avec une entrée.
func (s *Server) formVM(ctx context.Context, name string, e Entry, isNew bool, repo string, images []string, snap *Snapshot) FormVM {
	f := FormVM{
		New: isNew, Exists: !isNew, Name: name, Repo: repo,
		Sub: e.Subdomain, VPN: e.VPN(), SSO: e.SSO, Internet: e.InternetAccess, Probe: e.Probe,
		Multi: len(e.Containers) > 1, Initial: strings.ToUpper(name[:1]),
	}
	f.Tint, f.Ink = colorsOf(name)
	if f.Sub == "" {
		f.Sub = name
	}
	f.Domain = domainOf(name, e, s.cfg.Domain)
	f.SuffixPublic, f.SuffixVPN = "."+s.cfg.Domain, ".vpn."+s.cfg.Domain
	f.Suffix = f.SuffixPublic
	if e.VPN() {
		f.Suffix = f.SuffixVPN
	}
	if isNew {
		f.Base, f.PreviewURL, f.ApplyURL = "new", "/sites/new/preview", "/sites/new/apply"
	} else {
		f.Base = snap.Apps.Fingerprint(name)
		f.PreviewURL, f.ApplyURL, f.DeleteURL = "/sites/"+name+"/preview", "/sites/"+name+"/apply", "/sites/"+name+"/delete"
	}
	if e.RateLimit != nil {
		f.RL, f.RLPaths = true, strings.Join(*e.RateLimit, " ")
	}
	devices := map[string]bool{}
	for _, d := range e.Devices {
		devices[d] = true
	}
	for _, p := range s.cfg.Peers {
		f.Peers = append(f.Peers, Opt{Value: p, Label: p, Selected: devices[p]})
	}
	secrets := s.secretsFor(name)
	names := e.ContainerNames()
	f.CtrList = strings.Join(names, ",")
	for _, n := range names {
		c := e.Containers[n]
		img, _ := splitImage(c.Image)
		vm := CtrVM{Name: n, Entry: n == e.EntryPoint(), DataHost: "/var/lib/apps/" + name + "/" + n}
		choices := append([]string{}, images...)
		if !contains(choices, img) {
			choices = append(choices, img)
		}
		for _, i := range choices {
			vm.Images = append(vm.Images, Opt{Value: i, Label: i, Selected: i == img})
		}
		for _, m := range memories {
			vm.Memory = append(vm.Memory, Opt{Value: m[0], Label: m[1], Selected: m[0] == c.Memory})
		}
		for _, o := range names {
			if o != n {
				vm.Deps = append(vm.Deps, Opt{Value: o, Label: o, Selected: contains(c.DependsOn, o)})
			}
		}
		for _, d := range c.Data {
			host := d.On
			if host == "" {
				host = vm.DataHost + d.Path
			}
			vm.Data = append(vm.Data, DataVM{Value: d.Path + "\t" + d.On, Path: d.Path, Host: host, Auto: d.On == ""})
		}
		opts := map[string]bool{}
		for _, k := range secrets {
			opts[k] = true
			vm.Secrets = append(vm.Secrets, Opt{Value: k, Label: k, Selected: contains(c.Secrets, k)})
		}
		for _, k := range c.Secrets {
			if !opts[k] {
				vm.Secrets = append(vm.Secrets, Opt{Value: k, Label: k, Selected: true, Note: "absent du dépôt de secrets"})
			}
		}
		if snap != nil {
			if le, ok := snap.Lock[s.cfg.ref(c.Image)]; ok {
				vm.Info = "sha256:" + strings.TrimPrefix(le.Digest, "sha256:")[:12] + "…"
				if le.Port != nil {
					vm.Info += fmt.Sprintf(" · port %d", *le.Port)
				}
			}
		}
		f.Containers = append(f.Containers, vm)
	}
	f.Frozen = e.Version() != "main"
	return f
}

func contains(l []string, v string) bool {
	for _, x := range l {
		if x == v {
			return true
		}
	}
	return false
}

// entryFromForm : l'entrée décrite par le formulaire. `allowed` : images permises (celles du dépôt).
func (s *Server) entryFromForm(r *http.Request, names []string, current *Entry, allowed []string) (Entry, []string) {
	var errs []string
	e := Entry{Containers: map[string]Container{}}
	if sub := strings.TrimSpace(r.FormValue("sub")); sub != "" && sub != r.FormValue("name") && sub != r.PathValue("app") {
		e.Subdomain = strings.ToLower(sub)
	}
	if r.FormValue("expose") == "vpn" {
		e.Expose = "vpn"
		e.Devices = r.Form["dev"]
		sort.Strings(e.Devices)
	}
	e.SSO = r.FormValue("sso") == "on"
	e.InternetAccess = r.FormValue("internet") == "on"
	if p := strings.TrimSpace(r.FormValue("probe")); p != "" && p != "/" {
		e.Probe = p
	}
	if r.FormValue("rl") == "on" {
		paths := strings.Fields(r.FormValue("rlpaths"))
		if paths == nil {
			paths = []string{}
		}
		e.RateLimit = &paths
	}
	version := r.FormValue("version")
	if version != "" && !reTag.MatchString(version) {
		errs = append(errs, "Version invalide.")
		version = ""
	}
	for _, n := range names {
		var c Container
		if current != nil {
			c.Image = current.Containers[n].Image
		}
		img := r.FormValue("img_" + n)
		if img == "" {
			img, _ = splitImage(c.Image)
		}
		if !contains(allowed, img) {
			errs = append(errs, fmt.Sprintf("%s : image %s hors du dépôt du site.", n, img))
		}
		_, tag := splitImage(c.Image)
		if version != "" {
			tag = version
		}
		if tag == "" {
			tag = "main"
		}
		c.Image = img + ":" + tag
		c.Memory = r.FormValue("mem_" + n)
		c.DependsOn = r.Form["dep_"+n]
		sort.Strings(c.DependsOn)
		for _, v := range r.Form["data_"+n] {
			path, on, _ := strings.Cut(v, "\t")
			c.Data = append(c.Data, Data{Path: path, On: on})
		}
		if p := strings.TrimSpace(r.FormValue("newdata_" + n)); p != "" {
			c.Data = append(c.Data, Data{Path: p})
		}
		c.Secrets = r.Form["sec_"+n]
		sort.Strings(c.Secrets)
		e.Containers[n] = c
	}
	if len(names) > 1 {
		e.Entrypoint = r.FormValue("entry")
	}
	return e, errs
}

// previewOf : diff de l'entrée, erreurs et message de commit proposé.
func (s *Server) previewOf(name string, e *Entry, snap *Snapshot, isNew bool, msg string, errs []string) PreviewVM {
	p := PreviewVM{New: isNew, Errors: errs}
	if isNew {
		p.ApplyURL = "/sites/new/apply"
	} else {
		p.ApplyURL = "/sites/" + name + "/apply"
	}
	var before, after []string
	if raw, ok := snap.Apps.Raw[name]; ok && !isNew {
		before = entryLines(name, raw)
	}
	if e != nil {
		b, _ := entryJSON(*e)
		after = entryLines(name, b)
	}
	p.Lines, p.Adds, p.Dels = diffLines(before, after)
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
	var parts []string
	if ov, nv := old.Version(), e.Version(); ov != nv {
		if nv == "main" {
			parts = append(parts, "follow main again")
		} else {
			parts = append(parts, "roll back to "+shortTag(nv))
		}
	}
	if domainOf(name, old, s.cfg.Domain) != domainOf(name, *e, s.cfg.Domain) && old.Expose == e.Expose {
		parts = append(parts, "move to "+domainOf(name, *e, s.cfg.Domain))
	}
	if old.Expose != e.Expose {
		if e.VPN() {
			parts = append(parts, "restrict to vpn")
		} else {
			parts = append(parts, "make public")
		}
	} else if e.VPN() && strings.Join(old.Devices, ",") != strings.Join(e.Devices, ",") {
		parts = append(parts, "update devices")
	}
	if old.SSO != e.SSO {
		if e.SSO {
			parts = append(parts, "require login")
		} else {
			parts = append(parts, "drop login")
		}
	}
	if old.InternetAccess != e.InternetAccess {
		if e.InternetAccess {
			parts = append(parts, "allow internet")
		} else {
			parts = append(parts, "block internet")
		}
	}
	if fmt.Sprint(old.RateLimit) != fmt.Sprint(e.RateLimit) && !(old.RateLimit != nil && e.RateLimit != nil && strings.Join(*old.RateLimit, " ") == strings.Join(*e.RateLimit, " ")) {
		parts = append(parts, "update rate limit")
	}
	if old.Probe != e.Probe {
		parts = append(parts, "change health path")
	}
	if len(parts) == 0 {
		parts = append(parts, "update containers")
	}
	msg := "feat(" + name + "): " + strings.Join(parts, ", ")
	if len(msg) > 100 {
		msg = "feat(" + name + "): update site"
	}
	return msg
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
		http.NotFound(w, r)
		return
	}
	repo := s.sourceRepo(ctx, e)
	f := s.formVM(ctx, name, e, false, repo, s.repoImages(ctx, repo), snap)
	f.Versions, f.VersionNote = s.versions(ctx, e, repo)
	up := probes(ctx, s.cfg.Prometheus)
	f.Up, f.Probed = up[f.Domain]
	f.Preview = s.previewOf(name, &e, snap, false, "", nil)
	s.render(w, "editor", map[string]any{"Nav": "sites", "F": f})
}

// formRequest : nom, conteneurs et images permises de la requête ; vérifie que le site existe (ou pas).
func (s *Server) formRequest(ctx context.Context, r *http.Request, snap *Snapshot) (name string, names []string, current *Entry, allowed []string, isNew bool, err error) {
	name = r.PathValue("app")
	isNew = name == ""
	if isNew {
		name = strings.TrimSpace(r.FormValue("name"))
		names = strings.Split(r.FormValue("containers"), ",")
		repo := r.FormValue("repo")
		allowed = s.repoImages(ctx, repo)
		if !reName.MatchString(name) {
			return name, names, nil, allowed, true, nil
		}
		return name, names, nil, allowed, true, nil
	}
	e, ok := snap.Apps.Entries[name]
	if !ok {
		return "", nil, nil, nil, false, fmt.Errorf("%s n'existe plus sur main", name)
	}
	repo := s.sourceRepo(ctx, e)
	allowed = s.repoImages(ctx, repo)
	for _, c := range e.Containers {
		img, _ := splitImage(c.Image)
		if !contains(allowed, img) {
			allowed = append(allowed, img)
		}
	}
	return name, e.ContainerNames(), &e, allowed, false, nil
}

// requestEntry : entrée et erreurs d'une soumission du formulaire.
func (s *Server) requestEntry(r *http.Request) (string, *Entry, *Snapshot, PreviewVM, bool, error) {
	ctx := r.Context()
	if err := r.ParseForm(); err != nil {
		return "", nil, nil, PreviewVM{}, false, err
	}
	snap, err := s.snapshot(ctx)
	if err != nil {
		return "", nil, nil, PreviewVM{}, false, err
	}
	name, names, current, allowed, isNew, err := s.formRequest(ctx, r, snap)
	if err != nil {
		return "", nil, nil, PreviewVM{}, false, err
	}
	e, errs := s.entryFromForm(r, names, current, allowed)
	if isNew {
		if _, exists := snap.Apps.Entries[name]; exists {
			errs = append(errs, "Un site s'appelle déjà "+name+".")
		}
		if len(allowed) == 0 {
			errs = append(errs, "Aucune image trouvée pour ce dépôt.")
		}
	}
	errs = append(errs, validate(s.cfg, name, e, snap.Apps.Entries)...)
	p := s.previewOf(name, &e, snap, isNew, strings.TrimSpace(r.FormValue("msg")), errs)
	return name, &e, snap, p, isNew, nil
}

func (s *Server) preview(w http.ResponseWriter, r *http.Request) {
	_, _, _, p, _, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
	}
	s.render(w, "preview", p)
}

func (s *Server) apply(w http.ResponseWriter, r *http.Request) {
	name, e, snap, p, isNew, err := s.requestEntry(r)
	if err != nil {
		s.renderError(w, err)
		return
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
	if !regexp.MustCompile(`^[[:print:]]{1,100}$`).MatchString(msg) {
		p.Errors = append(p.Errors, "Message de commit : une ligne de 100 caractères au plus.")
		s.render(w, "preview", p)
		return
	}
	j := s.startJob(Request{App: name, Entry: e, Base: base, Message: msg}, domainOf(name, *e, s.cfg.Domain))
	s.render(w, "job", j.Snapshot())
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request) {
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
	if r.FormValue("confirm") != name {
		s.renderError(w, fmt.Errorf("tape %s pour confirmer la suppression", name))
		return
	}
	base := r.FormValue("base")
	if base != snap.Apps.Fingerprint(name) {
		s.renderError(w, fmt.Errorf("%s a changé sur main depuis l'ouverture de la page : recharge-la", name))
		return
	}
	j := s.startJob(Request{App: name, Entry: nil, Base: base, Message: "feat(" + name + "): remove site"}, domainOf(name, e, s.cfg.Domain))
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
