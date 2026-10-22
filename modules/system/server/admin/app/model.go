package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Format d'apps.json : le même que modules/system/server/app-images/apps-file.nix et
// .github/scripts/apps.sh (qui revérifie tout, c'est lui la barrière).

type Data struct {
	Path string `json:"path"`
	On   string `json:"on,omitempty"`
}

type Container struct {
	Image     string   `json:"image"`
	Memory    string   `json:"memory,omitempty"`
	DependsOn []string `json:"dependsOn,omitempty"`
	Data      []Data   `json:"data,omitempty"`
	Secrets   []string `json:"secrets,omitempty"`
}

type Entry struct {
	Subdomain      string               `json:"subdomain,omitempty"`
	Expose         string               `json:"expose,omitempty"`
	Devices        []string             `json:"devices,omitempty"`
	SSO            bool                 `json:"sso,omitempty"`
	InternetAccess bool                 `json:"internetAccess,omitempty"`
	Probe          string               `json:"probe,omitempty"`
	Entrypoint     string               `json:"entrypoint,omitempty"`
	RateLimit      *[]string            `json:"rateLimit,omitempty"` // [] : toute l'app
	Containers     map[string]Container `json:"containers"`
}

func (e Entry) VPN() bool { return e.Expose == "vpn" }

// ContainerNames dans l'ordre d'affichage : le point d'entrée d'abord.
func (e Entry) ContainerNames() []string {
	names := make([]string, 0, len(e.Containers))
	for n := range e.Containers {
		names = append(names, n)
	}
	sort.Slice(names, func(i, j int) bool {
		if (names[i] == e.Entrypoint) != (names[j] == e.Entrypoint) {
			return names[i] == e.Entrypoint
		}
		return names[i] < names[j]
	})
	return names
}

// EntryPoint : le conteneur servi par nginx, déclaré ou seul.
func (e Entry) EntryPoint() string {
	if e.Entrypoint != "" {
		return e.Entrypoint
	}
	for n := range e.Containers {
		return n
	}
	return ""
}

// Version commune des images : le tag suivi (`main`, `sha-…`), vide s'ils diffèrent.
func (e Entry) Version() string {
	v := ""
	for _, c := range e.Containers {
		_, tag := splitImage(c.Image)
		if v != "" && v != tag {
			return ""
		}
		v = tag
	}
	return v
}

func splitImage(image string) (name, tag string) {
	i := strings.LastIndex(image, ":")
	if i < 0 || strings.Contains(image[i:], "/") {
		return image, ""
	}
	return image[:i], image[i+1:]
}

// AppsFile : apps.json tel quel (entrées brutes pour l'empreinte) et lu.
type AppsFile struct {
	Raw     map[string]json.RawMessage
	Entries map[string]Entry
}

func parseApps(b []byte) (*AppsFile, error) {
	f := &AppsFile{Raw: map[string]json.RawMessage{}, Entries: map[string]Entry{}}
	if err := json.Unmarshal(b, &f.Raw); err != nil {
		return nil, fmt.Errorf("apps.json illisible : %w", err)
	}
	for name, raw := range f.Raw {
		var e Entry
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&e); err != nil {
			return nil, fmt.Errorf("apps.json : %s : %w", name, err)
		}
		f.Entries[name] = e
	}
	return f, nil
}

func (f *AppsFile) Names() []string {
	names := make([]string, 0, len(f.Entries))
	for n := range f.Entries {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

func marshal(v any, indent bool) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if indent {
		enc.SetIndent("", "  ")
	}
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// canonical : clés triées, sans espace, comme `jq -cS` (base de l'empreinte).
func canonical(raw []byte) (string, error) {
	var v any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		return "", err
	}
	b, err := marshal(v, false)
	return string(b), err
}

// Fingerprint d'une entrée lue sur main ; `new` si le site n'existe pas. apps.sh calcule la même.
func (f *AppsFile) Fingerprint(name string) string {
	raw, ok := f.Raw[name]
	if !ok {
		return "new"
	}
	c, err := canonical(raw)
	if err != nil {
		return "invalide"
	}
	sum := sha256.Sum256([]byte(c))
	return hex.EncodeToString(sum[:])
}

func entryJSON(e Entry) ([]byte, error) { return marshal(e, false) }

// WithEntry : apps.json avec une entrée remplacée (nil : supprimée), au format de `jq -S --indent 2`.
func (f *AppsFile) WithEntry(name string, e *Entry) ([]byte, error) {
	all := map[string]any{}
	for n, raw := range f.Raw {
		var v any
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		all[n] = v
	}
	if e == nil {
		delete(all, name)
	} else {
		b, err := entryJSON(*e)
		if err != nil {
			return nil, err
		}
		var v any
		if err := json.Unmarshal(b, &v); err != nil {
			return nil, err
		}
		all[name] = v
	}
	out, err := marshal(all, true)
	return append(out, '\n'), err
}

// Lignes d'une entrée telle qu'elle apparaît dans apps.json, pour le diff.
func entryLines(name string, raw []byte) []string {
	if raw == nil {
		return nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil
	}
	b, err := marshal(map[string]any{name: v}, true)
	if err != nil {
		return nil
	}
	lines := strings.Split(string(b), "\n")
	out := make([]string, 0, len(lines))
	for _, l := range lines[1 : len(lines)-1] {
		out = append(out, strings.TrimPrefix(l, "  "))
	}
	return out
}

type DiffLine struct {
	Kind string // same, add, del
	Text string
}

func diffLines(a, b []string) (out []DiffLine, adds, dels int) {
	n, m := len(a), len(b)
	t := make([][]int, n+1)
	for i := range t {
		t[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if a[i] == b[j] {
				t[i][j] = t[i+1][j+1] + 1
			} else {
				t[i][j] = max(t[i+1][j], t[i][j+1])
			}
		}
	}
	i, j := 0, 0
	for i < n && j < m {
		switch {
		case a[i] == b[j]:
			out = append(out, DiffLine{"same", a[i]})
			i++
			j++
		case t[i+1][j] >= t[i][j+1]:
			out = append(out, DiffLine{"del", a[i]})
			dels++
			i++
		default:
			out = append(out, DiffLine{"add", b[j]})
			adds++
			j++
		}
	}
	for ; i < n; i++ {
		out = append(out, DiffLine{"del", a[i]})
		dels++
	}
	for ; j < m; j++ {
		out = append(out, DiffLine{"add", b[j]})
		adds++
	}
	return out, adds, dels
}

// Domaine servi : même règle que modules/system/server/apps/default.nix.
func domainOf(name string, e Entry, base string) string {
	parent := base
	if e.VPN() {
		parent = "vpn." + base
	}
	sub := e.Subdomain
	if sub == "" {
		sub = name
	}
	if sub == "@" {
		return parent
	}
	return sub + "." + parent
}

// Port de bouclage dérivé du nom, comme `hashedPort` du module apps.
func hostPort(name string) int {
	sum := sha256.Sum256([]byte(name))
	v, _ := strconv.ParseUint(hex.EncodeToString(sum[:])[:7], 16, 64)
	return 20000 + int(v%10000)
}

func (c *Config) ref(image string) string {
	if strings.Contains(image, "/") {
		return image
	}
	return c.Registry + "/" + image
}

var (
	reName      = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,11}$`)
	reSubdomain = regexp.MustCompile(`^(@|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)$`)
	reDevice    = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)
	rePath      = regexp.MustCompile(`^/[A-Za-z0-9._~/-]*$`)
	reContainer = regexp.MustCompile(`^[a-z][a-z0-9-]{0,15}$`)
	reImage     = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]{1,128}$`)
	reMemory    = regexp.MustCompile(`^[1-9][0-9]{0,4}[mg]$`)
	reDataPath  = regexp.MustCompile(`^/[A-Za-z0-9._/-]+$`)
	reSecret    = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

// validate : mêmes règles qu'apps.sh, plus ce que la page sait de plus (adresses prises, appareils).
func validate(cfg *Config, name string, e Entry, others map[string]Entry) []string {
	var errs []string
	add := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }

	if !reName.MatchString(name) {
		add("Nom : 1 à 12 caractères, minuscules, chiffres et tirets.")
	}
	if e.Subdomain != "" && !reSubdomain.MatchString(e.Subdomain) {
		add("Sous-domaine : minuscules, chiffres et tirets (ou @ pour le domaine lui-même).")
	}
	if e.VPN() && e.Subdomain == "@" {
		add("Le domaine lui-même ne peut pas être réservé au VPN.")
	}
	if e.Expose != "" && e.Expose != "vpn" {
		add("Exposition inconnue : %s.", e.Expose)
	}
	if e.VPN() && len(e.Devices) == 0 {
		add("En VPN, coche au moins un appareil.")
	}
	known := map[string]bool{}
	for _, p := range cfg.Peers {
		known[p] = true
	}
	for _, d := range e.Devices {
		if !reDevice.MatchString(d) || !known[d] {
			add("Appareil inconnu : %s.", d)
		}
	}
	if e.Probe != "" && !rePath.MatchString(e.Probe) {
		add("Page de santé : un chemin qui commence par /.")
	}
	if e.RateLimit != nil {
		for _, p := range *e.RateLimit {
			if !rePath.MatchString(p) {
				add("Limite de débit : « %s » n'est pas un chemin (/…).", p)
			}
		}
	}
	if len(e.Containers) == 0 || len(e.Containers) > 5 {
		add("Un site a de 1 à 5 conteneurs.")
	}
	if len(e.Containers) > 1 {
		if _, ok := e.Containers[e.Entrypoint]; !ok {
			add("Choisis le conteneur qui reçoit le trafic.")
		}
	}
	for cn, c := range e.Containers {
		if !reContainer.MatchString(cn) {
			add("Nom de conteneur invalide : %s.", cn)
		}
		if !reImage.MatchString(c.Image) {
			add("%s : image invalide (%s).", cn, c.Image)
		}
		if c.Memory != "" && !reMemory.MatchString(c.Memory) {
			add("%s : mémoire invalide.", cn)
		}
		for _, d := range c.DependsOn {
			if _, ok := e.Containers[d]; !ok || d == cn {
				add("%s : dépend d'un conteneur inconnu (%s).", cn, d)
			}
		}
		for _, d := range c.Data {
			if !reDataPath.MatchString(d.Path) || strings.Contains(d.Path, "..") {
				add("%s : dossier de données invalide (%s).", cn, d.Path)
			}
			if d.On != "" && !(d.On == "/var/lib/"+name || strings.HasPrefix(d.On, "/var/lib/"+name+"/") || strings.HasPrefix(d.On, name+"-")) {
				add("%s : emplacement %s hors du site.", cn, d.On)
			}
		}
		for _, s := range c.Secrets {
			if !strings.HasPrefix(s, name+"/") || !reSecret.MatchString(strings.TrimPrefix(s, name+"/")) {
				add("%s : le secret %s n'est pas rangé sous %s/.", cn, s, name)
			}
		}
	}
	mine := domainOf(name, e, cfg.Domain)
	for other, oe := range others {
		if other != name && domainOf(other, oe, cfg.Domain) == mine {
			add("%s est déjà servi par %s.", mine, other)
		}
	}
	return errs
}
