package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Onglet Mises à jour : chaque montée de version lue par Gemini, pour dire si elle est urgente. Le
// dashboard apporte les textes (notes de version des versions sautées, avis de sécurité GitHub du
// projet) ; le modèle n'a pas de recherche web et ne doit rien inventer. Une analyse par paquet et
// par couple de versions, gardée : la même montée de version n'est jamais réanalysée.

// Analysis : ce que l'IA dit d'une montée de version.
type Analysis struct {
	Urgency string  `json:"urgency"` // urgent, conseille, sans
	Summary string  `json:"summary"`
	CVEs    []AICVE `json:"cves"`
	// Breaking : un changement cassant pour la config annoncé (entrées du flake, lues par leurs commits).
	Breaking bool   `json:"breaking,omitempty"`
	Basis    string `json:"basis"` // ce qu'elle a lu
	// ModelUrgency : le niveau donné par l'IA (Urgency, à l'affichage, vient des CVE).
	ModelUrgency string `json:"-"`
	// StuckSource, StuckIn : une faille n'est corrigée qu'au-delà du canal (lequel, en quelle version).
	StuckSource, StuckIn string    `json:"-"`
	Model                string    `json:"model"`
	At                   time.Time `json:"at"`
}

type AICVE struct {
	ID       string `json:"id"`
	Severity string `json:"severity"`
	Pkg      string `json:"pkg,omitempty"`      // le paquet qu'elle touche (relevé dans un titre de commit)
	FixedIn  string `json:"fixed_in,omitempty"` // la première version qui la corrige (notes de version)
	// Status : où elle en est pour ce serveur (classifyRow) : service, update, channel, unknown.
	Status string `json:"-"`
	// Sa note (cves.json), à l'affichage.
	Score   float64 `json:"-"`
	Network bool    `json:"-"`
	KEV     bool    `json:"-"`
}

// Level : la gravité de la note CVSS, lisiblement.
func (c AICVE) Level() string {
	switch {
	case c.Score >= 9:
		return "critique"
	case c.Score >= 7:
		return "élevée"
	case c.Score >= 4:
		return "moyenne"
	}
	return "faible"
}

var urgencyLabels = map[string]string{"urgent": "urgent", "conseille": "conseillé", "sans": "sans urgence"}

// UrgencyLabel, ModelUrgencyLabel : le niveau, et celui que donnait l'IA, lisiblement.
func (a Analysis) UrgencyLabel() string      { return urgencyLabels[a.Urgency] }
func (a Analysis) ModelUrgencyLabel() string { return urgencyLabels[a.ModelUrgency] }

func analysisKey(name, from, to string) string { return name + "|" + from + "|" + to }

var aiCache struct {
	sync.Mutex
	m map[string]Analysis
}

func (s *Server) aiFile() string { return filepath.Join(s.cfg.StateDir, "ai.json") }

// analyses : les analyses, leur niveau recalculé d'après la note de leurs CVE (rateUrgency) ; ce que
// l'IA disait reste dans ModelUrgency.
func (s *Server) analyses() map[string]Analysis {
	infos := s.cveInfos()
	out := s.rawAnalyses()
	for k, a := range out {
		a.ModelUrgency = a.Urgency
		a.Urgency = rateUrgency(a.Urgency, a.CVEs, infos)
		cves := make([]AICVE, len(a.CVEs))
		for i, c := range a.CVEs {
			if info, ok := infos[cveID(c.ID)]; ok {
				c.Score, c.Network, c.KEV = info.Score, info.Network, info.KEV
			}
			cves[i] = c
		}
		a.CVEs = cves
		out[k] = a
	}
	return out
}

// rawAnalyses : les analyses telles que gardées (niveau donné par l'IA).
func (s *Server) rawAnalyses() map[string]Analysis {
	aiCache.Lock()
	defer aiCache.Unlock()
	if aiCache.m == nil {
		aiCache.m = map[string]Analysis{}
		if b, err := os.ReadFile(s.aiFile()); err == nil {
			_ = json.Unmarshal(b, &aiCache.m)
		}
	}
	out := make(map[string]Analysis, len(aiCache.m))
	for k, v := range aiCache.m {
		out[k] = v
	}
	return out
}

func (s *Server) saveAnalyses(add map[string]Analysis) {
	s.rawAnalyses()
	aiCache.Lock()
	defer aiCache.Unlock()
	for k, v := range add {
		aiCache.m[k] = v
	}
	if b, err := json.Marshal(aiCache.m); err == nil {
		_ = os.WriteFile(s.aiFile(), b, 0o644)
	}
}

// reGitHubPage : un dépôt GitHub dans une adresse de notes de version ou de site.
var reGitHubPage = regexp.MustCompile(`^https://(?:raw\.githubusercontent\.com|github\.com)/([^/]+)/([^/#?]+)`)

func repoOf(urls ...string) (string, string) {
	for _, u := range urls {
		if m := reGitHubPage.FindStringSubmatch(u); m != nil {
			return m[1], strings.TrimSuffix(m[2], ".git")
		}
	}
	return "", ""
}

// versionParts : les nombres d'une version (« v4.39.28 » → 4 39 28).
func versionParts(v string) []int {
	var out []int
	for _, p := range reVersionPart.FindAllString(v, 4) {
		n, _ := strconv.Atoi(p)
		out = append(out, n)
	}
	return out
}

func cmpVersions(a, b string) int {
	pa, pb := versionParts(a), versionParts(b)
	for i := 0; i < max(len(pa), len(pb)); i++ {
		x, y := 0, 0
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

const notesMax = 12000

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "\n[…coupé]"
}

// Release : une release GitHub d'un projet.
type Release struct {
	Tag        string `json:"tag_name"`
	Body       string `json:"body"`
	URL        string `json:"html_url"`
	Prerelease bool   `json:"prerelease"`
	Draft      bool   `json:"draft"`
}

// releases : les dernières releases d'un dépôt GitHub (gardées quelques heures : la vérification et
// l'analyse les lisent toutes deux).
func (s *Server) releases(ctx context.Context, owner, repo string) ([]Release, error) {
	v, err := s.gh.cached("releases/"+owner+"/"+repo, 6*time.Hour, func() (any, error) {
		var rels []Release
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases?per_page=40", owner, repo)
		_, err := s.gh.api(ctx, "GET", url, s.cfg.DispatchToken, nil, &rels)
		return rels, err
	})
	if err != nil {
		return nil, err
	}
	return v.([]Release), nil
}

// releaseOf : la page de la release d'une version : son tag exact (« 1.2.3 », « v1.2.3 »), sinon le
// premier tag aux mêmes nombres (« release-1.2.3 »).
func releaseOf(rels []Release, version string) string {
	for _, r := range rels {
		if r.Tag == version || r.Tag == "v"+version {
			return r.URL
		}
	}
	if len(versionParts(version)) < 2 {
		return ""
	}
	for _, r := range rels {
		if len(versionParts(r.Tag)) >= 2 && cmpVersions(r.Tag, version) == 0 {
			return r.URL
		}
	}
	return ""
}

// tagVersion : la version d'un tag (« v1.2.3 », « release-1.2.3 » → « 1.2.3 »).
func tagVersion(tag string) string {
	if i := strings.IndexFunc(tag, func(r rune) bool { return r >= '0' && r <= '9' }); i >= 0 {
		return tag[i:]
	}
	return tag
}

// major : le premier nombre d'une version (la série : 17 pour 17.11, 2026 pour 2026.10.4).
func major(v string) int {
	if p := versionParts(v); len(p) > 0 {
		return p[0]
	}
	return -1
}

// latestVersions : pour chaque paquet, la version la plus récente publiée dans sa série (celle de la
// version d'après update : un projet y corrige ses failles, PostgreSQL 17 comme Nextcloud 33) parmi ses
// releases GitHub et nixpkgs-unstable ; et une version majeure plus récente, à part (une migration se
// choisit dans la config).
func (s *Server) latestVersions(ctx context.Context, rows []UpdateRow) map[string]LatestInfo {
	out := map[string]LatestInfo{}
	for _, r := range rows {
		if r.Current == "" {
			continue
		}
		var rels []Release
		if owner, repo := repoOf(r.Changelog, r.Homepage, r.Src); owner != "" {
			rels, _ = s.releases(ctx, owner, repo)
		}
		l := pickLatest(firstOf(r.Next, r.Current), r.Unstable, rels)
		if l.Version != "" || l.NewMajor != "" {
			out[r.Name] = l
		}
	}
	return out
}

// pickLatest : parmi la version de nixpkgs-unstable et les releases (hors préversions), la plus
// récente de la série de `current` (la version d'après update : celle qu'on aura), et une version
// majeure plus récente.
func pickLatest(current, unstable string, rels []Release) LatestInfo {
	type cand struct{ v, url string }
	var cands []cand
	if unstable != "" {
		cands = append(cands, cand{unstable, ""})
	}
	for _, rel := range rels {
		if !rel.Prerelease && !rel.Draft {
			cands = append(cands, cand{tagVersion(rel.Tag), rel.URL})
		}
	}
	var l LatestInfo
	for _, c := range cands {
		switch {
		case major(c.v) == major(current):
			if l.Version == "" || cmpVersions(c.v, l.Version) > 0 || (cmpVersions(c.v, l.Version) == 0 && l.URL == "") {
				l.Version, l.URL = c.v, c.url
			}
		case major(c.v) > major(current):
			if l.NewMajor == "" || cmpVersions(c.v, l.NewMajor) > 0 {
				l.NewMajor = c.v
			}
		}
	}
	return l
}

// releaseLinks : la page de release GitHub de chaque version affichée (en service, après update).
func (s *Server) releaseLinks(ctx context.Context, rows []UpdateRow) map[string]string {
	links := map[string]string{}
	for _, r := range rows {
		owner, repo := repoOf(r.Changelog, r.Homepage, r.Src)
		if owner == "" {
			continue
		}
		rels, err := s.releases(ctx, owner, repo)
		if err != nil {
			continue
		}
		for _, v := range []string{r.Current, r.Next} {
			if u := releaseOf(rels, v); v != "" && u != "" {
				links[releaseKey(r.Name, v)] = u
			}
		}
	}
	return links
}

// releaseNotes : les notes des versions sautées (releases GitHub entre `from` exclue et `to`
// incluse), sinon la page de notes de version autour de `to` ; et les avis de sécurité du projet.
func (s *Server) releaseNotes(ctx context.Context, row UpdateRow) (text string, basis []string) {
	owner, repo := repoOf(row.Changelog, row.Homepage, row.Src)
	var b strings.Builder
	if owner != "" {
		if rels, err := s.releases(ctx, owner, repo); err == nil {
			n := 0
			for _, r := range rels {
				if cmpVersions(r.Tag, row.Current) > 0 && cmpVersions(r.Tag, row.Upper()) <= 0 {
					fmt.Fprintf(&b, "## %s\n%s\n\n", r.Tag, strings.TrimSpace(r.Body))
					n++
				}
			}
			if n > 0 {
				basis = append(basis, fmt.Sprintf("notes GitHub (%s)", plural(n, "version", "versions")))
			}
		}
	}
	if b.Len() == 0 && row.Changelog != "" {
		if page, err := fetchText(ctx, row.Changelog); err == nil {
			// La page couvre souvent toutes les versions : le texte autour de la nouvelle.
			if i := strings.Index(page, row.Upper()); i >= 0 {
				page = page[max(0, i-300):]
			}
			b.WriteString(clip(page, notesMax))
			basis = append(basis, "page des notes de version")
		}
	}
	text = clip(b.String(), notesMax)
	if owner != "" {
		var advs []struct {
			GHSA     string `json:"ghsa_id"`
			CVE      string `json:"cve_id"`
			Severity string `json:"severity"`
			Summary  string `json:"summary"`
			Vulns    []struct {
				Range   string `json:"vulnerable_version_range"`
				Patched string `json:"patched_versions"`
			} `json:"vulnerabilities"`
			CVSS struct {
				Score  float64 `json:"score"`
				Vector string  `json:"vector_string"`
			} `json:"cvss"`
		}
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/security-advisories?per_page=30&state=published", owner, repo)
		if _, err := s.gh.api(ctx, "GET", url, s.cfg.DispatchToken, nil, &advs); err == nil && len(advs) > 0 {
			// La note d'un avis publié dans le seul dépôt du projet (absent de la base publique de GitHub).
			scored := map[string]CVEInfo{}
			for _, v := range advs {
				if v.CVSS.Score > 0 {
					scored[cveID(v.GHSA)] = CVEInfo{Score: v.CVSS.Score, Network: strings.Contains(v.CVSS.Vector, "AV:N"), At: time.Now()}
				}
			}
			s.addCVEInfos(scored)
			var a strings.Builder
			for _, v := range advs {
				if !advisoryOpen(row.Current, v.Vulns) {
					continue
				}
				var ranges []string
				for _, x := range v.Vulns {
					ranges = append(ranges, fmt.Sprintf("touchées %s, corrigées %s", x.Range, x.Patched))
				}
				fmt.Fprintf(&a, "- %s %s (%s) : %s [%s]\n", firstOf(v.CVE, v.GHSA), v.GHSA, v.Severity, v.Summary, strings.Join(ranges, " ; "))
			}
			if a.Len() > 0 {
				text += "\n\nAvis de sécurité du projet (GitHub), ceux qui touchent encore A :\n" + clip(a.String(), 6000)
				basis = append(basis, "avis de sécurité GitHub")
			}
		}
	}
	return text, basis
}

var reVersion = regexp.MustCompile(`\d+(?:\.\d+)+[0-9A-Za-z.+~-]*`)

// advisoryOpen : un avis touche encore la version `current`. Un projet corrige souvent sur plusieurs
// branches (« corrigées v5.8.8 ; corrigées v6.1.3 ») : une version corrigée de la série de `current`,
// déjà atteinte, le règle ; sinon une version corrigée plus récente le laisse ouvert ; un avis sans
// version corrigée aussi. Les vieux avis d'un projet n'en sont pas : sans ce tri, l'IA les recopie et
// l'urgence gonfle.
func advisoryOpen(current string, vulns []struct {
	Range   string `json:"vulnerable_version_range"`
	Patched string `json:"patched_versions"`
}) bool {
	if current == "" {
		return true
	}
	var patched []string
	for _, v := range vulns {
		patched = append(patched, reVersion.FindAllString(v.Patched, -1)...)
	}
	for _, p := range patched {
		if major(p) == major(current) && cmpVersions(p, current) <= 0 {
			return false
		}
	}
	for _, p := range patched {
		if cmpVersions(p, current) > 0 {
			return true
		}
	}
	return len(patched) == 0
}

var (
	reTags   = regexp.MustCompile(`(?s)<(script|style)[^>]*>.*?</(script|style)>|<[^>]+>`)
	reSpaces = regexp.MustCompile(`[ \t\r]+|\n{3,}`)
)

// fetchText : une page web, en texte (balises retirées).
func fetchText(ctx context.Context, url string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s : %s", url, resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 3<<20))
	if err != nil {
		return "", err
	}
	t := html.UnescapeString(reTags.ReplaceAllString(string(b), " "))
	return strings.TrimSpace(reSpaces.ReplaceAllStringFunc(t, func(m string) string {
		if strings.Contains(m, "\n") {
			return "\n\n"
		}
		return " "
	})), nil
}

const aiPrompt = `Tu aides à administrer un serveur NixOS personnel. Pour chaque paquet ci-dessous : A est la version en service, C la plus récente publiée par le projet dans la même série, et B celle que donnera la mise à jour de son canal (souvent B = C ; B peut être plus ancienne que C, voire égale à A). À partir UNIQUEMENT des textes fournis (notes des versions de A exclue à C incluse, avis de sécurité du projet), dis si passer de A à C est urgent :
- "urgent" : une faille de sécurité sérieuse qui touche la version A est corrigée (exécution de code, contournement d'authentification, fuite de données, CVE de gravité haute ou critique) ;
- "conseille" : une faille mineure, ou des bugs gênants, sont corrigés ;
- "sans" : rien d'important pour un serveur.
"summary" : en français, deux ou trois phrases sur ce qui change d'important (sécurité d'abord). "cves" : les CVE (ou GHSA) corrigées entre A (exclue) et C (incluse), avec leur gravité et "fixed_in" : la première version qui la corrige, telle que les textes la donnent (vide si les textes ne le disent pas). Si les textes ne disent rien d'utile, "urgency" = "sans" et "summary" le dit ("Aucune note de version lisible"). N'invente rien, ne suppose rien au-delà des textes. Réponds pour chaque paquet, avec son "id".`

var aiSchema = map[string]any{
	"type": "ARRAY",
	"items": map[string]any{
		"type": "OBJECT",
		"properties": map[string]any{
			"id":       map[string]any{"type": "STRING"},
			"urgency":  map[string]any{"type": "STRING", "enum": []string{"urgent", "conseille", "sans"}},
			"summary":  map[string]any{"type": "STRING"},
			"breaking": map[string]any{"type": "BOOLEAN"},
			"cves": map[string]any{"type": "ARRAY", "items": map[string]any{"type": "OBJECT", "properties": map[string]any{
				"id": map[string]any{"type": "STRING"}, "severity": map[string]any{"type": "STRING"}, "fixed_in": map[string]any{"type": "STRING"}}}},
		},
		"required": []string{"id", "urgency", "summary"},
	},
}

// geminiBase : l'API Gemini (remplacée dans les tests).
var geminiBase = "https://generativelanguage.googleapis.com/v1beta"

// aiTimeout : l'attente d'une réponse (au-delà, l'analyse est retentée à la vérification suivante).
var aiTimeout = 2 * time.Minute

// generationConfig : réponse en JSON imposé, peu de fantaisie ; et un raisonnement court (`thinking`,
// vide : celui du modèle) : lire des notes de version et classer n'en demande pas plus, et un long
// raisonnement peut faire attendre des minutes sur un modèle gratuit très demandé.
func generationConfig(thinking string) map[string]any {
	c := map[string]any{"temperature": 0.2, "responseMimeType": "application/json", "responseSchema": aiSchema}
	if thinking != "" {
		c["thinkingConfig"] = map[string]any{"thinkingLevel": thinking}
	}
	return c
}

// gemini : une requête, la réponse JSON du modèle.
func (s *Server) gemini(ctx context.Context, prompt string) ([]byte, error) {
	model := s.cfg.AIModel
	body, _ := json.Marshal(map[string]any{
		"contents":         []any{map[string]any{"role": "user", "parts": []any{map[string]any{"text": prompt}}}},
		"generationConfig": generationConfig(s.cfg.AIThinking),
	})
	ctx, cancel := context.WithTimeout(ctx, aiTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		geminiBase+"/models/"+model+":generateContent", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-goog-api-key", s.cfg.GeminiKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, fmt.Errorf("%s : pas de réponse en %s", model, aiTimeout)
		}
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error struct{ Message string } `json:"error"`
		}
		_ = json.Unmarshal(b, &e)
		return nil, fmt.Errorf("%s : HTTP %d %s", model, resp.StatusCode, firstOf(e.Error.Message, resp.Status))
	}
	var out struct {
		Candidates []struct {
			Content struct {
				Parts []struct{ Text string } `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(b, &out); err != nil || len(out.Candidates) == 0 || len(out.Candidates[0].Content.Parts) == 0 {
		return nil, fmt.Errorf("%s : réponse vide", model)
	}
	return []byte(out.Candidates[0].Content.Parts[0].Text), nil
}

// aiAnswer : un élément de la réponse du modèle (aiSchema).
type aiAnswer struct {
	ID       string  `json:"id"`
	Urgency  string  `json:"urgency"`
	Summary  string  `json:"summary"`
	CVEs     []AICVE `json:"cves"`
	Breaking bool    `json:"breaking"`
}

// aiBatch : paquets analysés par requête (quelques requêtes par jour, loin des quotas gratuits).
const aiBatch = 5

// analyze : les montées de version pas encore analysées, par lots ; l'erreur, s'il y en a une.
func (s *Server) analyze(ctx context.Context, rows []UpdateRow) error {
	if s.cfg.GeminiKey == "" {
		return nil
	}
	done := s.analyses()
	var todo []UpdateRow
	for _, r := range rows {
		// Ce que la mise à jour change, ou ce que le projet a publié au-delà du canal.
		if r.Current != "" && r.Upper() != "" && r.Upper() != r.Current && (r.Change != "same" || r.Behind()) {
			if _, ok := done[r.analysisKey()]; !ok {
				todo = append(todo, r)
			}
		}
	}
	var errs []string
	for start := 0; start < len(todo); start += aiBatch {
		batch := todo[start:min(start+aiBatch, len(todo))]
		var p strings.Builder
		p.WriteString(aiPrompt)
		bases := map[string]string{}
		for _, r := range batch {
			text, basis := s.releaseNotes(ctx, r)
			bases[r.ID] = strings.Join(basis, ", ")
			fmt.Fprintf(&p, "\n\n### id: %s — %s : A = %s, B = %s, C = %s\n", r.ID, r.Name, r.Current, firstOf(r.Next, r.Current), r.Upper())
			if text == "" {
				p.WriteString("(aucun texte trouvé)\n")
			} else {
				p.WriteString(text)
			}
		}
		raw, err := s.gemini(ctx, p.String())
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		var answers []aiAnswer
		if err := json.Unmarshal(raw, &answers); err != nil {
			errs = append(errs, s.cfg.AIModel+" : réponse illisible")
			continue
		}
		add := map[string]Analysis{}
		for _, a := range answers {
			for _, r := range batch {
				if r.ID == a.ID {
					add[r.analysisKey()] = Analysis{Urgency: a.Urgency, Summary: a.Summary, CVEs: a.CVEs,
						Basis: firstOf(bases[r.ID], "rien à lire"), Model: s.cfg.AIModel, At: time.Now()}
				}
			}
		}
		s.saveAnalyses(add)
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, " ; "))
	}
	return nil
}

const aiInputPrompt = `Tu aides à administrer un serveur NixOS personnel. Une entrée de son flake, %s (dépôt GitHub %s/%s), avancerait de la révision A à la révision B ; plus bas, le titre des commits entre les deux. Ils sont déjà triés : seuls restent ceux qui touchent un paquet présent sur ce serveur, un module NixOS, ou rien de précis (%d gardés sur %d). Les paquets dont la version change ont leur propre analyse (avec leurs notes de version) et en sont retirés : n'en parle pas.
Paquets de ce serveur qui viennent de cette entrée : %s. Les autres paquets du serveur viennent d'une autre entrée : un commit d'ici qui les touche ne compte pas, sauf une bibliothèque dont dépendent ceux de cette entrée.
À partir UNIQUEMENT de ces titres, dis si la mise à jour est urgente :
- "urgent" : un commit corrige une faille de sécurité sérieuse (CVE de gravité haute ou critique, exécution de code, contournement d'authentification, fuite de données) dans un paquet que ce serveur utilise depuis cette entrée ;
- "conseille" : une faille mineure, ou des bugs gênants, corrigés dans ce que ce serveur utilise depuis cette entrée ;
- "sans" : rien d'important pour ce serveur.
"breaking" : true seulement si un commit annonce un changement cassant pour la config de ce serveur (option renommée ou retirée, comportement par défaut changé, migration à faire à la main) dans un module ou un paquet qu'il utilise.
"summary" : en français, deux ou trois phrases : la sécurité d'abord, puis les changements cassants, puis ce qui compte pour ce serveur, en citant les paquets ; ignore ce que ce serveur n'utilise pas. "cves" : les CVE (ou GHSA) citées dans ces titres, avec leur gravité si elle est dite ; le résumé cite chaque paquet corrigé d'une faille. Un paquet du serveur pris dans une autre entrée est « pris dans une autre entrée », pas « inutilisé ». N'invente rien. Réponds avec un seul élément, d'"id" %q.

Commits :
`

// closureNames : le nom (sans version) de chaque paquet du système actif ; remplacé dans les tests.
var closureNames = func(ctx context.Context) (map[string]bool, error) {
	out, err := exec.CommandContext(ctx, "nix-store", "--query", "--requisites", "/run/current-system").Output()
	if err != nil {
		return nil, fmt.Errorf("paquets du système illisibles : %w", err)
	}
	names := map[string]bool{}
	for _, line := range strings.Fields(string(out)) {
		base := filepath.Base(line)
		if len(base) > 33 {
			base = base[33:] // le hash et son tiret
		}
		names[strings.ToLower(reNameVersion.ReplaceAllString(base, ""))] = true
	}
	return names, nil
}

// reNameVersion : la version au bout d'un nom du store (« openssl-3.5.4-bin » → « openssl »).
var reNameVersion = regexp.MustCompile(`-[0-9].*$`)

var (
	rePRSuffix   = regexp.MustCompile(` \(#\d+\)$`)
	reBackport   = regexp.MustCompile(`^(\[[^\]]*\]\s*)+`) // « [Backport release-26.05] », « [26.05] »
	reAttrSuffix = regexp.MustCompile(`_[0-9].*$`)         // linux_7_3, openssl_3_6…
	// Les types des Conventional Commits : « chore: update claude-code to 2.1.312 » n'a pas de
	// paquet en tête ; ci, docs, test et style ne changent rien de ce qui tourne.
	reCommitType = regexp.MustCompile(`^(feat|fix|chore|refactor|perf|build|revert|security|ci|docs|test|style)(\(.*\))?!?$`)
	reNoOpType   = regexp.MustCompile(`^(ci|docs|test|style)\b`)
)

// relevantTitles : les titres qui comptent pour ce serveur, sans doublon (nixpkgs a souvent le
// même avec et sans « (#PR) ») : ceux sans paquet précis, ceux du module NixOS d'un paquet du serveur
// (changements cassants), et ceux d'un paquet présent sur le serveur, sauf ceux des paquets analysés
// à part (`own` : ceux dont la version change, avec leurs notes de version).
func relevantTitles(titles []string, closure, own map[string]bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, t := range titles {
		t = strings.TrimSpace(rePRSuffix.ReplaceAllString(reBackport.ReplaceAllString(strings.TrimSpace(t), ""), ""))
		if seen[t] {
			continue
		}
		seen[t] = true
		pre, _, found := strings.Cut(t, ": ")
		if found && reCommitType.MatchString(pre) {
			if !reNoOpType.MatchString(pre) {
				out = append(out, t)
			}
			continue
		}
		keep := !found || strings.ContainsAny(strings.TrimSpace(strings.ReplaceAll(pre, ", ", ",")), " \"")
		for _, tok := range strings.Split(pre, ",") {
			if keep {
				break
			}
			tok = strings.ToLower(strings.TrimSpace(tok))
			// Un module NixOS (nixos/virtualisation/podman) : celui d'un paquet du serveur ; pas
			// ses tests, sa doc ni ses profils.
			if mod, ok := strings.CutPrefix(tok, "nixos/"); ok {
				parts := strings.Split(mod, "/")
				last := parts[len(parts)-1]
				keep = !slices.Contains([]string{"tests", "doc", "profiles"}, parts[0]) && (closure[last] || own[last])
				continue
			}
			if k := strings.LastIndex(tok, "."); k >= 0 {
				tok = tok[k+1:] // python3Packages.foo
			}
			base := reAttrSuffix.ReplaceAllString(tok, "")
			if own[tok] || own[base] {
				continue
			}
			keep = closure[tok] || closure[base]
		}
		if keep {
			out = append(out, t)
		}
	}
	return out
}

// analyzeInputs : chaque entrée du flake qui avancerait, lue par les titres de ses commits (sops-nix,
// home-manager… n'ont pas de numéro de version ; pour nixpkgs, ce sont surtout des montées de version
// et des correctifs de sécurité, bibliothèques comprises), triés d'après ce qui tourne. Une analyse
// par couple de révisions.
func (s *Server) analyzeInputs(ctx context.Context, inputs []InputRow, rows []UpdateRow) error {
	if s.cfg.GeminiKey == "" {
		return nil
	}
	// Un paquet dont la version change a sa propre analyse ; pas un paquet corrigé par un patch, à
	// version égale (fréquent sur une branche stable) : ses titres restent ici.
	own := map[string]bool{}
	for _, r := range rows {
		if r.Change != "" && r.Change != "same" {
			own[strings.ToLower(r.Name)] = true
		}
	}
	done := s.analyses()
	var closure map[string]bool
	var errs []string
	for _, in := range inputs {
		if !in.Changed() || in.Owner == "" {
			continue
		}
		from := firstOf(in.ServiceRev, in.MainRev)
		key := analysisKey(inputKey(in.Name), from, in.NextRev)
		if _, ok := done[key]; ok {
			continue
		}
		if closure == nil {
			c, err := closureNames(ctx)
			if err != nil {
				return err
			}
			closure = c
		}
		all, err := s.gh.CompareTitles(ctx, in.Owner, in.Repo, from, in.NextRev)
		if err != nil {
			errs = append(errs, in.Name+" : commits illisibles ("+err.Error()+")")
			continue
		}
		titles := relevantTitles(all, closure, own)
		if len(titles) == 0 {
			continue
		}
		var mine []string
		for _, r := range rows {
			if r.Source == in.Name && r.Current != "" {
				mine = append(mine, r.Name+" "+r.Current)
			}
		}
		prompt := fmt.Sprintf(aiInputPrompt, in.Name, in.Owner, in.Repo, len(titles), len(all), firstOf(strings.Join(mine, ", "), "aucun service suivi à part, mais ce qu'elle fournit (outil, module) est bien installé sur ce serveur"), in.Name) +
			strings.Join(titles, "\n")
		raw, err := s.gemini(ctx, prompt)
		if err != nil {
			errs = append(errs, in.Name+" : "+err.Error())
			continue
		}
		var answers []aiAnswer
		if err := json.Unmarshal(raw, &answers); err != nil || len(answers) == 0 {
			errs = append(errs, in.Name+" : "+s.cfg.AIModel+" : réponse illisible")
			continue
		}
		a := answers[0]
		s.saveAnalyses(map[string]Analysis{key: {Urgency: a.Urgency, Summary: a.Summary, CVEs: mergeCVEs(titleCVEs(titles), a.CVEs), Breaking: a.Breaking,
			Basis: fmt.Sprintf("%s sur %d", plural(len(titles), "titre de commit", "titres de commits"), len(all)), Model: s.cfg.AIModel, At: time.Now()}})
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, " ; "))
	}
	return nil
}

var reCVE = regexp.MustCompile(`\b(CVE-\d{4}-\d{4,}|GHSA(?:-[0-9a-z]{4}){3})\b`)

// titleCVEs : les CVE citées dans les titres, avec le paquet en tête du titre : relevées par le code,
// un petit modèle en oublie.
func titleCVEs(titles []string) []AICVE {
	var out []AICVE
	for _, t := range titles {
		pre, _, found := strings.Cut(t, ": ")
		if !found || strings.Contains(strings.ReplaceAll(pre, ", ", ","), " ") {
			pre = ""
		}
		for _, id := range reCVE.FindAllString(t, -1) {
			out = append(out, AICVE{ID: id, Pkg: pre})
		}
	}
	return out
}

// mergeCVEs : celles des titres, complétées par le modèle (sa gravité ; celles qu'il a vues ailleurs).
func mergeCVEs(found, model []AICVE) []AICVE {
	sev := map[string]string{}
	for _, c := range model {
		sev[c.ID] = c.Severity
	}
	seen := map[string]bool{}
	var out []AICVE
	for _, c := range append(found, model...) {
		if seen[c.ID] {
			continue
		}
		seen[c.ID] = true
		c.Severity = firstOf(c.Severity, sev[c.ID])
		out = append(out, c)
	}
	return out
}

// aiInputVersion : la façon de lire une entrée du flake ; la changer refait ces analyses une fois.
const aiInputVersion = 5

// inputKey : le nom d'une entrée du flake dans le cache des analyses (à part des paquets).
func inputKey(name string) string { return fmt.Sprintf("input.%s@%d", name, aiInputVersion) }

// analysisKey : la clé de l'analyse de ce que update apporterait à cette entrée.
func (r InputRow) analysisKey() string {
	return analysisKey(inputKey(r.Name), firstOf(r.ServiceRev, r.MainRev), r.NextRev)
}
