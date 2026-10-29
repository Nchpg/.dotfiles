package main

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// Onglet Mises à jour : ce qu'on lit d'un paquet pour juger sa mise à jour, de la version en service
// (A) à la plus récente (C). Le code relève lui-même les CVE (dans chaque release, avec la version qui
// la cite ; dans les avis de sécurité, avec leurs versions touchées et corrigées) : l'IA résume et
// complète, elle ne décide pas seule de ce qui existe. Ce que la branche en service a déjà corrigé
// est relevé à part (Fixed).

// reCVE : une CVE ou un avis GitHub dans un texte, quelle que soit la casse.
var reCVE = regexp.MustCompile(`(?i)\b(CVE-\d{4}-\d{4,}|GHSA(?:-[0-9a-z]{4}){3})\b`)

// cveIDsIn : les identifiants cités par un texte, dans leur forme officielle (cveID), sans doublon.
func cveIDsIn(text string) []string {
	var out []string
	for _, m := range reCVE.FindAllString(text, -1) {
		if id := cveID(m); !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	return out
}

// reVersionTok : une version dans un texte libre (« 5.8.8 », « v6.1.3 », « 10.6p1 », « 17 »).
var reVersionTok = regexp.MustCompile(`\d+(?:\.\d+)*(?:[a-z]+\d*)?`)

// fixedVersions : les versions d'une mention « corrigée en » (« 5.8.8, 6.1.3 », « v6.1.3 »).
func fixedVersions(s string) []string {
	return reVersionTok.FindAllString(strings.ToLower(s), -1)
}

// tagPrefix : ce qui précède la version dans un tag (« v », « release- », « helm-loki- », rien).
func tagPrefix(tag string) string {
	if i := strings.IndexFunc(tag, func(r rune) bool { return r >= '0' && r <= '9' }); i >= 0 {
		return tag[:i]
	}
	return tag
}

// filterReleases : les releases qui sont des versions du logiciel, de la plus ancienne à la plus
// récente : ni préversion ni brouillon, et seulement les tags au préfixe de ses versions (un dépôt
// publie aussi d'autres choses : loki ses chartes Helm, « helm-loki-6.1.0 »). Le préfixe : celui du tag
// d'une version connue (`refs`), sinon le plus fréquent.
func filterReleases(rels []Release, refs ...string) []Release {
	prefixes := map[string]bool{}
	for _, ref := range refs {
		for _, r := range rels {
			if ref != "" && len(versionParts(ref)) >= 2 && cmpVersions(tagVersion(r.Tag), ref) == 0 {
				prefixes[tagPrefix(r.Tag)] = true
			}
		}
	}
	if len(prefixes) == 0 {
		count := map[string]int{}
		best := ""
		for _, r := range rels {
			if !r.Prerelease && !r.Draft {
				p := tagPrefix(r.Tag)
				count[p]++
				if count[p] > count[best] {
					best = p
				}
			}
		}
		prefixes[best] = true
	}
	var out []Release
	for _, r := range rels {
		if !r.Prerelease && !r.Draft && prefixes[tagPrefix(r.Tag)] && len(versionParts(r.Tag)) > 0 {
			out = append(out, r)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return cmpVersions(out[i].Tag, out[j].Tag) < 0 })
	return out
}

// projectReleases : les releases GitHub d'un projet qui sont ses versions (filterReleases).
func (s *Server) projectReleases(ctx context.Context, owner, repo string, refs ...string) ([]Release, error) {
	rels, err := s.releases(ctx, owner, repo)
	if err != nil {
		return nil, err
	}
	return filterReleases(rels, refs...), nil
}

// advisoryVuln : un paquet touché d'un avis GitHub, ses versions touchées et corrigées.
type advisoryVuln = struct {
	Range   string `json:"vulnerable_version_range"`
	Patched string `json:"patched_versions"`
}

var reConstraint = regexp.MustCompile(`(>=|<=|>|<|=)?\s*v?(\d[0-9A-Za-z.+~-]*)`)

// inRange : `v` dans les versions touchées d'un avis (« >= 4.4.0, < 5.8.8 », « <= v5.8.3 »,
// « >=9.2.0 <9.2.10 >=9.3.0 <9.3.4 » : plusieurs intervalles) ; `ok` faux s'il est illisible (vide,
// « None »). Une borne basse ouvre un intervalle, une borne haute le ferme.
func inRange(r, v string) (in, ok bool) {
	type bound struct{ op, version string }
	var spans [][]bound
	has := func(span []bound, ops ...string) bool {
		return slices.ContainsFunc(span, func(b bound) bool { return slices.Contains(ops, b.op) })
	}
	for _, m := range reConstraint.FindAllStringSubmatch(r, -1) {
		b := bound{firstOf(m[1], "="), m[2]}
		n := len(spans)
		lower := b.op == ">=" || b.op == ">"
		if n == 0 || b.op == "=" || has(spans[n-1], "=") ||
			lower && has(spans[n-1], ">=", ">") || !lower && has(spans[n-1], "<=", "<") {
			spans = append(spans, nil)
			n++
		}
		spans[n-1] = append(spans[n-1], b)
	}
	for _, span := range spans {
		all := true
		for _, b := range span {
			c := cmpVersions(v, b.version)
			switch b.op {
			case ">=":
				all = all && c >= 0
			case ">":
				all = all && c > 0
			case "<=":
				all = all && c <= 0
			case "<":
				all = all && c < 0
			default:
				all = all && c == 0
			}
		}
		if all {
			return true, true
		}
	}
	return false, len(spans) > 0
}

// advisoryAffects : un avis touche la version `current` et une mise à jour le corrige. Sans version
// corrigée, il ne compte pas (aucune mise à jour ne le règle ; ce sont souvent de vieux avis mal
// remplis, ou une faille de l'outillage du projet). Une version corrigée de la branche de `current`
// déjà atteinte le règle (un projet corrige souvent sur plusieurs branches : « 5.8.8 ; 6.1.3 ») ;
// des versions corrigées toutes plus anciennes aussi (le correctif suit les versions suivantes).
// Sinon, ses intervalles de versions touchées tranchent (une faille introduite en 6.0 ne touche pas
// 5.8), et sans intervalle lisible, la version corrigée plus récente.
func advisoryAffects(current string, depth int, vulns []advisoryVuln) bool {
	var patched []string
	for _, v := range vulns {
		patched = append(patched, fixedVersions(v.Patched)...)
	}
	if len(patched) == 0 {
		return false
	}
	if current == "" {
		return true
	}
	newer := false
	for _, p := range patched {
		if sameBranch(p, current, depth) && cmpVersions(p, current) <= 0 {
			return false
		}
		newer = newer || cmpVersions(p, current) > 0
	}
	if !newer {
		return false
	}
	readable := false
	for _, v := range vulns {
		in, ok := inRange(v.Range, current)
		readable = readable || ok
		if ok && in {
			return true
		}
	}
	return !readable
}

// notesResult : ce qu'on a lu d'un paquet.
type notesResult struct {
	Text  string              // envoyé à l'IA (notes de A exclue à C incluse, avis qui touchent A)
	Basis []string            // ce qui a été lu, lisiblement
	Fixed []string            // CVE déjà corrigées dans la branche en service
	Found map[string][]string // CVE relevées par le code : id → versions qui la corrigent (vide : inconnue)
	Depth int                 // les numéros qui nomment une branche du projet
}

// releaseNotes : les notes des versions sautées (releases GitHub, sinon la page de notes du projet
// coupée à la version en service) et les avis de sécurité du projet ; les CVE relevées par le code.
func (s *Server) releaseNotes(ctx context.Context, row UpdateRow) notesResult {
	res := notesResult{Found: map[string][]string{}, Depth: max(row.EOL.Depth, 1)}
	fixed := map[string]bool{}
	fix := func(ids ...string) {
		for _, id := range ids {
			if id = cveID(id); id != "" && !fixed[id] {
				fixed[id] = true
				res.Fixed = append(res.Fixed, id)
			}
		}
	}
	found := func(id, version string) {
		id = cveID(id)
		if version != "" && !slices.Contains(res.Found[id], version) {
			res.Found[id] = append(res.Found[id], version)
		} else if _, ok := res.Found[id]; !ok {
			res.Found[id] = nil
		}
	}
	owner, repo := repoOf(row.Changelog, row.Homepage, row.Src, row.EOL.Repo)
	var b strings.Builder
	if owner != "" {
		if rels, err := s.projectReleases(ctx, owner, repo, row.Current, row.Next); err == nil {
			if row.EOL.Depth == 0 {
				res.Depth = branchDepth(rels)
			}
			var sections []string
			for _, r := range rels { // de la plus ancienne à la plus récente
				v := tagVersion(r.Tag)
				switch {
				case cmpVersions(v, row.Current) <= 0:
					// La branche en service, jusqu'à sa version : ses CVE y sont déjà corrigées
					// (une 6.0 les recite, corrigées en parallèle en 5.8).
					if sameBranch(v, row.Current, res.Depth) {
						fix(cveIDsIn(r.Body)...)
					}
				case cmpVersions(v, row.Upper()) <= 0:
					for _, id := range cveIDsIn(r.Body) {
						found(id, v)
					}
					sections = append(sections, fmt.Sprintf("## %s\n%s\n\n", r.Tag, strings.TrimSpace(r.Body)))
				}
			}
			// À l'IA, les plus récentes d'abord (le texte est coupé au-delà de notesMax).
			slices.Reverse(sections)
			for _, sec := range sections {
				b.WriteString(sec)
			}
			if len(sections) > 0 {
				res.Basis = append(res.Basis, fmt.Sprintf("notes GitHub (%s)", plural(len(sections), "version", "versions")))
			}
		}
	}
	if b.Len() == 0 && row.Changelog != "" {
		if page, err := fetchText(ctx, row.Changelog); err == nil {
			newer, older := changelogSlice(page, row.Current, row.Upper())
			fix(cveIDsIn(older)...)
			for _, id := range cveIDsIn(newer) {
				found(id, "")
			}
			b.WriteString(clip(newer, notesMax))
			res.Basis = append(res.Basis, "page des notes de version")
		}
	}
	res.Text = clip(b.String(), notesMax)
	if owner != "" {
		s.readAdvisories(ctx, owner, repo, row.Current, &res, fix, found)
	}
	return res
}

// changelogSlice : d'une page de notes (les versions les plus récentes en haut, le cas courant), la
// partie des versions sautées (de `upper` jusqu'avant `current`) et celle des versions déjà en
// service (à partir de `current`). Sans repères dans cet ordre : la page autour de `upper`, rien
// de déjà corrigé.
func changelogSlice(page, current, upper string) (newer, older string) {
	iu := strings.Index(page, upper)
	if iu < 0 {
		return page, ""
	}
	start := max(0, iu-300)
	if ic := strings.Index(page[iu+len(upper):], current); ic >= 0 && current != "" {
		ic += iu + len(upper)
		// Le titre de la version en service commence un peu avant son numéro.
		cut := ic
		if nl := strings.LastIndex(page[:ic], "\n"); nl > iu {
			cut = nl
		}
		return page[start:cut], page[cut:]
	}
	return page[start:], ""
}

// readAdvisories : les avis de sécurité publiés dans le dépôt du projet. Ceux qui ne touchent pas la
// version en service (corrigés dans sa branche, ou faille introduite plus tard) sont déjà réglés ;
// les autres vont à l'IA, et leurs CVE sont relevées avec leurs versions corrigées. Leur note, leur
// gravité et le numéro CVE d'un GHSA sont gardés (cves.json).
func (s *Server) readAdvisories(ctx context.Context, owner, repo, current string, res *notesResult, fix func(...string), found func(string, string)) {
	var advs []struct {
		GHSA     string         `json:"ghsa_id"`
		CVE      string         `json:"cve_id"`
		Severity string         `json:"severity"`
		Summary  string         `json:"summary"`
		Vulns    []advisoryVuln `json:"vulnerabilities"`
		CVSS     struct {
			Score  float64 `json:"score"`
			Vector string  `json:"vector_string"`
		} `json:"cvss"`
	}
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/security-advisories?per_page=100&state=published", owner, repo)
	if _, err := s.gh.api(ctx, "GET", url, s.cfg.DispatchToken, nil, &advs); err != nil || len(advs) == 0 {
		return
	}
	known := map[string]CVEInfo{}
	var a strings.Builder
	for _, v := range advs {
		ghsa, cve := cveID(v.GHSA), cveID(v.CVE)
		known[ghsa] = CVEInfo{Score: v.CVSS.Score, Network: strings.Contains(v.CVSS.Vector, "AV:N"),
			Severity: strings.ToLower(v.Severity), Alias: cve, At: time.Now()}
		if !advisoryAffects(current, res.Depth, v.Vulns) {
			fix(ghsa, cve)
			continue
		}
		var ranges, patched []string
		for _, x := range v.Vulns {
			ranges = append(ranges, fmt.Sprintf("touchées %s, corrigées %s", x.Range, x.Patched))
			patched = append(patched, fixedVersions(x.Patched)...)
		}
		id := firstOf(cve, ghsa)
		if len(patched) == 0 {
			found(id, "")
		}
		for _, p := range patched {
			found(id, p)
		}
		fmt.Fprintf(&a, "- %s %s (%s) : %s [%s]\n", id, ghsa, v.Severity, v.Summary, strings.Join(ranges, " ; "))
	}
	s.addCVEInfos(known)
	if a.Len() > 0 {
		res.Text += "\n\nAvis de sécurité du projet (GitHub), ceux qui touchent encore A :\n" + clip(a.String(), 6000)
		res.Basis = append(res.Basis, "avis de sécurité GitHub")
	}
}
