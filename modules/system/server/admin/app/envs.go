package main

import (
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Environnements d'un site : le même site sur une autre branche, servi comme l'app
// `<site>-<id>`. Mêmes règles que modules/system/server/app-images/apps-file.nix : un
// environnement hérite de son parent (`from`, la racine par défaut) chaque section qu'il ne
// règle pas ; une section est à lui dès que sa clé repère est là (`expose`, `containers`,
// `internetAccess`).

type Env struct {
	Name           string               `json:"name,omitempty"`
	Branch         string               `json:"branch"`
	From           string               `json:"from,omitempty"`
	Data           string               `json:"data,omitempty"` // separate (défaut), copy, shared
	Pin            string               `json:"pin,omitempty"`  // sha-<commit> : figé
	Subdomain      string               `json:"subdomain,omitempty"`
	Expose         string               `json:"expose,omitempty"`
	Devices        []string             `json:"devices,omitempty"`
	SSO            bool                 `json:"sso,omitempty"`
	Accounts       []string             `json:"accounts,omitempty"` // comptes Authelia admis, avec SSO
	Containers     map[string]Container `json:"containers,omitempty"`
	Entrypoint     string               `json:"entrypoint,omitempty"`
	InternetAccess *bool                `json:"internetAccess,omitempty"`
	Probe          string               `json:"probe,omitempty"`
	RateLimit      *[]string            `json:"rateLimit,omitempty"`
	// Conteneurs hérités : secrets remplacés, retirés ou ajoutés pour cet environnement.
	Secrets *EnvSecrets `json:"secrets,omitempty"`
}

// EnvSecrets : les secrets d'un environnement aux conteneurs hérités, par rapport à son parent.
type EnvSecrets struct {
	Replace map[string]string   `json:"replace,omitempty"` // secret -> remplaçant ("" : retiré)
	Add     map[string][]string `json:"add,omitempty"`     // conteneur -> secrets en plus
}

func (s *EnvSecrets) empty() bool { return s == nil || (len(s.Replace) == 0 && len(s.Add) == 0) }

// apply : les secrets d'un conteneur, remplacés (un remplaçant vide retire), puis ceux ajoutés.
// Même calcul que apps-file.nix.
func (s EnvSecrets) apply(container string, keys []string) []string {
	out := []string{}
	for _, k := range keys {
		if r, ok := s.Replace[k]; ok {
			if r != "" {
				out = append(out, r)
			}
			continue
		}
		out = append(out, k)
	}
	return append(out, s.Add[container]...)
}

func (v Env) OwnAccess() bool     { return v.Expose != "" }
func (v Env) OwnContainers() bool { return len(v.Containers) > 0 }
func (v Env) OwnOptions() bool    { return v.InternetAccess != nil }

func (v Env) DataMode() string {
	if v.Data == "" {
		return "separate"
	}
	return v.Data
}

// Sections effectives d'un déploiement.
type Access struct {
	Expose   string // public ou vpn
	Devices  []string
	SSO      bool
	Accounts []string // comptes Authelia admis, avec SSO
}

type Options struct {
	Internet  bool
	Probe     string
	RateLimit *[]string
}

type Ctrs struct {
	Containers map[string]Container // images avec leur tag effectif
	Entrypoint string
}

// Deploy : la racine (ID vide, app = le site) ou un environnement, résolu.
type Deploy struct {
	Site, ID, App, Label string
	Branch, Tag          string // branche suivie ; tag effectif (la branche, ou sha-… si figé)
	From, Data           string
	Subdomain            string
	Child                bool
	Access               Access
	Ctrs                 Ctrs
	Options              Options
}

func (d Deploy) VPN() bool { return d.Access.Expose == "vpn" }

func (d Deploy) EntryPoint() string { return entryPointOf(d.Ctrs.Entrypoint, d.Ctrs.Containers) }

func (d Deploy) Frozen() bool { return strings.HasPrefix(d.Tag, "sha-") }

// Domain : même règle que modules/system/server/apps/default.nix.
func (d Deploy) Domain(base string) string {
	return servedDomain(d.App, d.Subdomain, d.VPN(), base)
}

var reNotTag = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// tagOf : tag publié par app-image.yml pour une branche (`feat/charts` -> `feat-charts`).
func tagOf(branch string) string { return reNotTag.ReplaceAllString(branch, "-") }

// untag : `myetf:main` -> `myetf`.
func untag(image string) string { name, _ := splitImage(image); return name }

func (e Entry) EnvIDs() []string {
	ids := make([]string, 0, len(e.Environments))
	for id := range e.Environments {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// sections : accès, conteneurs (images sans tag pour un enfant) et options effectifs.
func (e Entry) sections(id string, depth int) (Access, Ctrs, Options, error) {
	if id == "" {
		a := Access{Expose: "public", Devices: e.Devices, SSO: e.SSO, Accounts: e.Accounts}
		if e.VPN() {
			a.Expose = "vpn"
		}
		return a, Ctrs{Containers: e.Containers, Entrypoint: e.Entrypoint}, Options{Internet: e.InternetAccess, Probe: e.Probe, RateLimit: e.RateLimit}, nil
	}
	v, ok := e.Environments[id]
	if !ok {
		return Access{}, Ctrs{}, Options{}, fmt.Errorf("environnement inconnu : %s", id)
	}
	if depth > 16 {
		return Access{}, Ctrs{}, Options{}, fmt.Errorf("boucle d'héritage entre environnements")
	}
	a, c, o, err := e.sections(v.From, depth+1)
	if err != nil {
		return a, c, o, err
	}
	if v.OwnAccess() {
		a = Access{Expose: v.Expose, Devices: v.Devices, SSO: v.SSO, Accounts: v.Accounts}
	}
	if v.OwnContainers() {
		c = Ctrs{Containers: v.Containers, Entrypoint: v.Entrypoint}
	}
	if v.OwnOptions() {
		o = Options{Internet: *v.InternetAccess, Probe: v.Probe, RateLimit: v.RateLimit}
	}
	return a, c, o, nil
}

// Deploy : un déploiement résolu (id vide : la racine).
func (e Entry) Deploy(site, id string) (Deploy, error) {
	a, c, o, err := e.sections(id, 0)
	if err != nil {
		return Deploy{}, err
	}
	d := Deploy{Site: site, ID: id, App: site, Access: a, Options: o}
	if id == "" {
		d.Label = e.Name
		if d.Label == "" {
			d.Label = "production"
		}
		d.Subdomain, d.Tag = e.Subdomain, e.Version()
		d.Branch = d.Tag
		if d.Frozen() || d.Branch == "" {
			d.Branch = "main"
		}
		d.Ctrs = c
		return d, nil
	}
	v := e.Environments[id]
	d.ID, d.App, d.Child = id, site+"-"+id, true
	d.Label = v.Name
	if d.Label == "" {
		d.Label = id
	}
	d.Branch, d.From, d.Data, d.Subdomain = v.Branch, v.From, v.DataMode(), v.Subdomain
	d.Tag = v.Pin
	if d.Tag == "" {
		d.Tag = tagOf(v.Branch)
	}
	d.Ctrs = Ctrs{Containers: map[string]Container{}, Entrypoint: c.Entrypoint}
	ov := e.secretOverrides(id)
	for n, ct := range c.Containers {
		ct.Image = untag(ct.Image) + ":" + d.Tag
		if !ov.empty() {
			ct.Secrets = ov.apply(n, ct.Secrets)
		}
		d.Ctrs.Containers[n] = ct
	}
	return d, nil
}

// secretOverrides : secrets d'un environnement aux conteneurs hérités, les siens puis ceux de ses
// parents jusqu'à celui qui a ses propres conteneurs. Remplacements : le plus proche l'emporte ;
// ajouts : cumulés. Même règle que apps-file.nix (`overridesOf`).
func (e Entry) secretOverrides(id string) *EnvSecrets {
	out := &EnvSecrets{Replace: map[string]string{}, Add: map[string][]string{}}
	for n := 0; id != "" && n < 17; n++ {
		v := e.Environments[id]
		if v.OwnContainers() {
			break
		}
		if v.Secrets != nil {
			for k, r := range v.Secrets.Replace {
				if _, set := out.Replace[k]; !set {
					out.Replace[k] = r
				}
			}
			for c, ks := range v.Secrets.Add {
				for _, k := range ks {
					if !slices.Contains(out.Add[c], k) {
						out.Add[c] = append(out.Add[c], k)
					}
				}
			}
		}
		id = v.From
	}
	return out
}

// inheritedContainers : les conteneurs dont hérite un environnement, secrets d'origine.
func (e Entry) inheritedContainers(id string) map[string]Container {
	_, c, _, err := e.sections(e.Environments[id].From, 0)
	if err != nil {
		return nil
	}
	return c.Containers
}

// inheritedSecrets : les secrets des conteneurs dont hérite un environnement, avant son parent et lui.
func (e Entry) inheritedSecrets(id string) []string {
	var out []string
	for _, ct := range e.inheritedContainers(id) {
		out = append(out, ct.Secrets...)
	}
	sort.Strings(out)
	return slices.Compact(out)
}

// Deploys : la racine puis les environnements ; ceux qui ne se résolvent pas sont omis.
func (e Entry) Deploys(site string) []Deploy {
	var out []Deploy
	for _, id := range append([]string{""}, e.EnvIDs()...) {
		if d, err := e.Deploy(site, id); err == nil {
			out = append(out, d)
		}
	}
	return out
}

// DataHost : dossier hôte d'un chemin de données ; `shared` remonte au parent.
func (e Entry) DataHost(site, id, container, path string) string {
	for depth := 0; depth < 17; depth++ {
		if id == "" {
			for _, d := range e.Containers[container].Data {
				if d.Path == path && d.On != "" {
					return d.On
				}
			}
			return "/var/lib/apps/" + site + "/" + container + path
		}
		v, ok := e.Environments[id]
		if !ok || v.DataMode() != "shared" {
			return "/var/lib/apps/" + site + "-" + id + "/" + container + path
		}
		id = v.From
	}
	return ""
}

// inherits : b hérite-t-il, de près ou de loin, de a ?
func (e Entry) inherits(b, a string) bool {
	for n := 0; b != "" && n < 17; n++ {
		b = e.Environments[b].From
		if b == a {
			return true
		}
	}
	return false
}

var (
	reEnvID  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,15}$`)
	reBranch = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$`)
	rePin    = regexp.MustCompile(`^sha-[0-9a-f]{7,40}$`)
	reUntag  = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]*$`)
)

// validateEnvs : règles des environnements (mêmes qu'apps.sh), plus les adresses et noms pris.
func validateEnvs(cfg *Config, site string, e Entry, others map[string]Entry) []string {
	var errs []string
	add := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }
	if len(e.Environments) > 8 {
		add("8 environnements au plus.")
	}
	known := map[string]bool{}
	for _, p := range cfg.Peers {
		known[p] = true
	}
	for _, id := range e.EnvIDs() {
		v := e.Environments[id]
		w := id + " : "
		if !reEnvID.MatchString(id) {
			add("Environnement « %s » : nom invalide (minuscules, chiffres et tirets, 16 caractères au plus).", id)
			continue
		}
		if len(v.Name) > 32 {
			add("%snom affiché de 32 caractères au plus.", w)
		}
		if !reBranch.MatchString(v.Branch) {
			add("%sbranche invalide.", w)
		}
		if v.From != "" {
			if _, ok := e.Environments[v.From]; !ok || v.From == id {
				add("%shérite d'un environnement inconnu (%s).", w, v.From)
			}
		}
		if _, _, _, err := e.sections(id, 0); err != nil {
			add("%s%s.", w, err)
		}
		if v.Data != "" && v.Data != "copy" && v.Data != "shared" && v.Data != "separate" {
			add("%sdonnées : séparées, copie ou partagées.", w)
		}
		if v.Pin != "" && !rePin.MatchString(v.Pin) {
			add("%sversion figée invalide.", w)
		}
		if v.Subdomain != "" && !reSubdomain.MatchString(v.Subdomain) {
			add("%ssous-domaine invalide.", w)
		}
		// Une section n'est à lui que par sa clé repère : ses autres clés seules feraient échouer l'évaluation.
		if !v.OwnAccess() && (len(v.Devices) > 0 || v.SSO || v.Accounts != nil) {
			add("%s« appareils » et « login » vont avec l'accès propre.", w)
		}
		if v.OwnAccess() {
			errs = append(errs, validateAccounts(w, v.SSO, v.Accounts)...)
		}
		if !v.OwnContainers() && v.Entrypoint != "" {
			add("%sle point d'entrée va avec des conteneurs propres.", w)
		}
		if !v.Secrets.empty() {
			if v.OwnContainers() {
				add("%ssecrets de l'environnement : avec des conteneurs propres, ils se choisissent dans chaque conteneur.", w)
			}
			inherited := e.inheritedSecrets(id)
			for k, r := range v.Secrets.Replace {
				switch {
				case !slices.Contains(inherited, k):
					add("%s%s n'est pas un secret hérité : rien à remplacer.", w, k)
				case r != "" && !strings.HasPrefix(r, site+"/"):
					add("%sle secret %s n'est pas rangé sous %s/.", w, r, site)
				}
			}
			ctrs := e.inheritedContainers(id)
			for c, ks := range v.Secrets.Add {
				ct, ok := ctrs[c]
				if !ok {
					add("%spas de conteneur %s hérité : rien où ajouter %s.", w, c, strings.Join(ks, ", "))
					continue
				}
				for _, k := range ks {
					switch {
					case !strings.HasPrefix(k, site+"/"):
						add("%sle secret %s n'est pas rangé sous %s/.", w, k, site)
					case slices.Contains(ct.Secrets, k):
						add("%s%s le reçoit déjà de son parent.", w, c)
					}
				}
			}
		}
		if !v.OwnOptions() && (v.Probe != "" || v.RateLimit != nil) {
			add("%spage de santé et limite de débit vont avec les options propres.", w)
		}
		if v.OwnAccess() {
			if v.Expose != "public" && v.Expose != "vpn" {
				add("%sexposition inconnue.", w)
			}
			if v.Expose == "vpn" && len(v.Devices) == 0 {
				add("%sen VPN, coche au moins un appareil.", w)
			}
			if v.Expose == "vpn" && v.Subdomain == "@" {
				add("%sle domaine lui-même ne peut pas être réservé au VPN.", w)
			}
			for _, dv := range v.Devices {
				if !known[dv] {
					add("%sappareil inconnu : %s.", w, dv)
				}
			}
		}
		if v.OwnOptions() {
			if v.Probe != "" && !rePath.MatchString(v.Probe) {
				add("%spage de santé : un chemin qui commence par /.", w)
			}
			if v.RateLimit != nil {
				for _, p := range *v.RateLimit {
					if !rePath.MatchString(p) {
						add("%slimite de débit : « %s » n'est pas un chemin.", w, p)
					}
				}
			}
		}
		if v.OwnContainers() {
			errs = append(errs, validateContainers(site, w, v.Containers, v.Entrypoint, true)...)
		}
	}
	// Noms servis : `<site>-<id>` n'est ni un autre site ni un autre environnement ; adresses uniques.
	mine := map[string]string{}
	for _, d := range e.Deploys(site) {
		mine[d.App] = d.Domain(cfg.Domain)
	}
	taken := map[string]string{}
	for other, oe := range others {
		if other == site {
			continue
		}
		for _, d := range oe.Deploys(other) {
			taken[d.App] = d.Domain(cfg.Domain)
		}
	}
	seen := map[string]string{}
	for app, dom := range mine {
		if _, ok := taken[app]; ok && app != site {
			add("%s : ce nom est déjà celui d'un autre site.", app)
		}
		for oapp, odom := range taken {
			if odom == dom {
				add("%s est déjà servi par %s.", dom, oapp)
			}
		}
		if prev, ok := seen[dom]; ok {
			add("%s est servi deux fois (%s et %s).", dom, prev, app)
		}
		seen[dom] = app
	}
	return errs
}

// validateContainers : conteneurs d'une racine ou d'un environnement (`child` : images sans tag).
func validateContainers(site, w string, containers map[string]Container, entrypoint string, child bool) []string {
	var errs []string
	add := func(format string, a ...any) {
		msg := w + fmt.Sprintf(format, a...)
		if w == "" {
			msg = strings.ToUpper(msg[:1]) + msg[1:]
		}
		errs = append(errs, msg)
	}
	if len(containers) == 0 || len(containers) > 5 {
		add("de 1 à 5 conteneurs.")
	}
	if len(containers) > 1 {
		if _, ok := containers[entrypoint]; !ok {
			add("choisis le conteneur qui reçoit le trafic.")
		}
	}
	for cn, c := range containers {
		if !reContainer.MatchString(cn) {
			add("nom de conteneur invalide : %s.", cn)
		}
		if child && !reUntag.MatchString(c.Image) || !child && !reImage.MatchString(c.Image) {
			add("%s : image invalide (%s).", cn, c.Image)
		}
		if c.Memory != "" && !reMemory.MatchString(c.Memory) {
			add("%s : mémoire invalide.", cn)
		}
		for _, d := range c.DependsOn {
			if _, ok := containers[d]; !ok || d == cn {
				add("%s : dépend d'un conteneur inconnu (%s).", cn, d)
			}
		}
		for _, d := range c.Data {
			if !reDataPath.MatchString(d.Path) || strings.Contains(d.Path, "..") {
				add("%s : dossier de données invalide (%s).", cn, d.Path)
			}
			if d.On != "" && (child || !(d.On == "/var/lib/"+site || strings.HasPrefix(d.On, "/var/lib/"+site+"/") || strings.HasPrefix(d.On, site+"-"))) {
				add("%s : emplacement %s hors du site.", cn, d.On)
			}
		}
		for _, s := range c.Secrets {
			if !strings.HasPrefix(s, site+"/") || !reSecret.MatchString(strings.TrimPrefix(s, site+"/")) {
				add("%s : le secret %s n'est pas rangé sous %s/.", cn, s, site)
			}
		}
	}
	return errs
}
