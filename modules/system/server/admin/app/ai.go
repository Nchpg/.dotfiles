package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
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
	// Fixed : les CVE déjà corrigées dans la branche en service (ses notes de version jusqu'à elle, les
	// avis du dépôt), d'après le code, pas l'IA.
	Fixed []string `json:"fixed,omitempty"`
	// Depth : les numéros qui nomment une branche du projet, à l'analyse (classifyRow).
	Depth int `json:"depth,omitempty"`
	// StuckSource, StuckIn, StuckUnstable : une faille n'est corrigée qu'au-delà du canal (lequel, en
	// quelle version) ; la version de nixpkgs-unstable si elle la corrige.
	StuckSource, StuckIn, StuckUnstable string    `json:"-"`
	Model                               string    `json:"model"`
	At                                  time.Time `json:"at"`
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
func (s *Server) analyses() map[string]Analysis { return s.analysesWith(s.cveInfos()) }

// analysesWith : analyses, avec les notes déjà lues (une seule lecture par page).
func (s *Server) analysesWith(infos map[string]CVEInfo) map[string]Analysis {
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
		loadJSONState(s.aiFile(), &aiCache.m)
	}
	out := make(map[string]Analysis, len(aiCache.m))
	for k, v := range aiCache.m {
		out[k] = v
	}
	return out
}

// loadJSONState : un fichier d'état (ai.json, cves.json) dans `v`. Illisible (écriture coupée d'une
// ancienne version) : mis de côté en .bad, journalisé, et `v` reste vide ; rien n'est écrasé sans trace.
func loadJSONState[T any](path string, v *map[string]T) {
	b, err := os.ReadFile(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("%s : %v", path, err)
		}
		return
	}
	if err := json.Unmarshal(b, v); err != nil {
		log.Printf("%s illisible, mis de côté en .bad : %v", path, err)
		_ = os.Rename(path, path+".bad")
		*v = map[string]T{}
	}
}

// saveJSONState : un fichier d'état, remplacé d'un coup (writeFileAtomic).
func saveJSONState(path string, v any) {
	b, err := json.Marshal(v)
	if err == nil {
		err = writeFileAtomic(path, b, 0o644)
	}
	if err != nil {
		log.Printf("%s : %v", path, err)
	}
}

func (s *Server) saveAnalyses(add map[string]Analysis) {
	s.rawAnalyses()
	aiCache.Lock()
	defer aiCache.Unlock()
	for k, v := range add {
		aiCache.m[k] = v
	}
	saveJSONState(s.aiFile(), aiCache.m)
}

// keepAnalyses : une analyse qui ne sert plus (la version en service ou la plus récente a changé)
// est gardée ce temps-là, puis retirée (une analyse retirée serait refaite si elle resservait).
const keepAnalyses = 90 * 24 * time.Hour

// pruneAnalyses : retire les analyses hors de `keep` plus vieilles que maxAge.
func (s *Server) pruneAnalyses(keep map[string]bool, maxAge time.Duration) {
	s.rawAnalyses()
	aiCache.Lock()
	defer aiCache.Unlock()
	n := len(aiCache.m)
	for k, a := range aiCache.m {
		if !keep[k] && time.Since(a.At) > maxAge {
			delete(aiCache.m, k)
		}
	}
	if len(aiCache.m) != n {
		saveJSONState(s.aiFile(), aiCache.m)
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

// rePre : le début d'une préversion, juste après un chiffre (« 2.0.0-rc1 », « 3.1beta2 », « 1.0~pre »,
// « 2.0.0.dev3 ») ; une lettre de correctif (« 10.6p1 », « 1.1.1w ») n'en est pas une.
var rePre = regexp.MustCompile(`(?i)\d[-._~]?(?:alpha|beta|rc|pre|dev)`)

// splitPre : une version, et sa marque de préversion (« 2.0.0-rc1 » → « 2.0.0 », « -rc1 »).
func splitPre(v string) (core, pre string) {
	if loc := rePre.FindStringIndex(v); loc != nil {
		return v[:loc[0]+1], v[loc[0]+1:]
	}
	return v, ""
}

// isPrerelease : un tag de préversion, même publié comme une release ordinaire.
func isPrerelease(tag string) bool { return rePre.MatchString(tag) }

// versionParts : les nombres d'une version (« v4.39.28 » → 4 39 28), sans ceux d'une préversion
// (« 2.0.0-rc1 » → 2 0 0).
func versionParts(v string) []int {
	core, _ := splitPre(v)
	return numbers(core, 4)
}

func numbers(s string, n int) []int {
	var out []int
	for _, p := range reVersionPart.FindAllString(s, n) {
		k, _ := strconv.Atoi(p)
		out = append(out, k)
	}
	return out
}

// cmpVersions : -1, 0 ou 1. À nombres égaux, une préversion passe avant la version (2.0.0-rc1 <
// 2.0.0), et deux préversions se comparent par leur numéro (rc1 < rc2).
func cmpVersions(a, b string) int {
	if c := cmpParts(versionParts(a), versionParts(b)); c != 0 {
		return c
	}
	_, pa := splitPre(a)
	_, pb := splitPre(b)
	switch {
	case pa == pb:
		return 0
	case pa == "":
		return 1
	case pb == "":
		return -1
	}
	return cmpParts(numbers(pa, 2), numbers(pb, 2))
}

func cmpParts(pa, pb []int) int {
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

// notesMax : texte de notes envoyé à l'IA par paquet (les notes d'une seule version d'OpenSSH
// dépassent 12 000 caractères ; le relevé des CVE par le code, lui, lit tout).
const notesMax = 30000

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "\n[…coupé]"
}

// Release : une release GitHub d'un projet.
type Release struct {
	Tag        string    `json:"tag_name"`
	Body       string    `json:"body"`
	URL        string    `json:"html_url"`
	Prerelease bool      `json:"prerelease"`
	Draft      bool      `json:"draft"`
	Published  time.Time `json:"published_at"`
}

// branchDepth : combien de numéros nomment une branche du projet. 1 (podman 5 / 6, PostgreSQL 17 /
// 18), sauf si une suite au deuxième numéro reçoit encore des versions après la sortie d'une suite
// plus récente de même premier numéro (nginx 1.28 stable à côté de 1.29) : alors 2.
func branchDepth(rels []Release) int {
	type line struct {
		major, minor int
		first, last  time.Time
	}
	lines := map[[2]int]*line{}
	for _, r := range rels {
		p := versionParts(r.Tag)
		if r.Prerelease || r.Draft || len(p) < 2 || r.Published.IsZero() {
			continue
		}
		k := [2]int{p[0], p[1]}
		l := lines[k]
		if l == nil {
			l = &line{major: p[0], minor: p[1], first: r.Published, last: r.Published}
			lines[k] = l
		}
		if r.Published.Before(l.first) {
			l.first = r.Published
		}
		if r.Published.After(l.last) {
			l.last = r.Published
		}
	}
	for _, a := range lines {
		for _, b := range lines {
			if a.major == b.major && a.minor < b.minor && a.last.After(b.first) {
				return 2
			}
		}
	}
	return 1
}

// sameBranch : deux versions de la même branche (leurs `depth` premiers numéros).
func sameBranch(a, b string, depth int) bool {
	pa, pb := versionParts(a), versionParts(b)
	if len(pa) < depth || len(pb) < depth {
		return false
	}
	for i := 0; i < depth; i++ {
		if pa[i] != pb[i] {
			return false
		}
	}
	return true
}

// releasePages : pages de 100 releases lues au plus (un projet actif en publie des centaines ; les
// plus anciennes ne servent qu'à reconnaître ce que la branche en service a déjà corrigé).
const releasePages = 3

// releases : les dernières releases d'un dépôt GitHub, telles quelles (gardées quelques heures : la
// vérification et l'analyse les lisent toutes deux) ; projectReleases les trie.
func (s *Server) releases(ctx context.Context, owner, repo string) ([]Release, error) {
	v, err := s.gh.cached("releases/"+owner+"/"+repo, 6*time.Hour, func() (any, error) {
		var all []Release
		for page := 1; page <= releasePages; page++ {
			var rels []Release
			url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases?per_page=100&page=%d", owner, repo, page)
			if _, err := s.gh.api(ctx, "GET", url, s.cfg.DispatchToken, nil, &rels); err != nil {
				if page == 1 {
					return nil, err
				}
				break
			}
			all = append(all, rels...)
			if len(rels) < 100 {
				break
			}
		}
		return all, nil
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

// splitTag : un tag en préfixe et version (« release-1.2.3 » → « release- », « 1.2.3 ») ; sans
// chiffre, tout le tag (préfixe et version).
func splitTag(tag string) (prefix, version string) {
	if i := strings.IndexFunc(tag, func(r rune) bool { return r >= '0' && r <= '9' }); i >= 0 {
		return tag[:i], tag[i:]
	}
	return tag, tag
}

// tagVersion : la version d'un tag (« v1.2.3 », « release-1.2.3 » → « 1.2.3 »).
func tagVersion(tag string) string { _, v := splitTag(tag); return v }

// major : le premier nombre d'une version (la série : 17 pour 17.11, 2026 pour 2026.10.4).
func major(v string) int {
	if p := versionParts(v); len(p) > 0 {
		return p[0]
	}
	return -1
}

// latestVersions : pour chaque paquet, la version la plus récente publiée, toutes branches
// confondues (endoflife.date, releases GitHub, nixpkgs-unstable) : celle jusqu'où l'analyse lit.
func (s *Server) latestVersions(ctx context.Context, rows []UpdateRow) map[string]LatestInfo {
	out := map[string]LatestInfo{}
	for _, r := range rows {
		if ctx.Err() != nil {
			break // délai de la vérification dépassé : le reste à la suivante
		}
		if r.Current == "" {
			continue
		}
		var rels []Release
		if owner, repo := repoOf(r.Changelog, r.Homepage, r.Src, r.EOL.Repo); owner != "" {
			rels, _ = s.projectReleases(ctx, owner, repo, r.Current, r.Next)
		}
		if l := pickLatest(r.Unstable, rels, r.EOL.Latest); l.Version != "" {
			out[r.Name] = l
		}
	}
	return out
}

// pickLatest : la plus récente parmi la version de nixpkgs-unstable, les releases du projet et la
// dernière de chaque branche (endoflife.date) ; avec sa page quand une source en donne une.
func pickLatest(unstable string, rels []Release, branches []Candidate) LatestInfo {
	cands := []Candidate{{unstable, ""}}
	cands = append(cands, branches...)
	for _, rel := range rels {
		cands = append(cands, Candidate{tagVersion(rel.Tag), rel.URL})
	}
	var l LatestInfo
	for _, c := range cands {
		if c.Version == "" {
			continue
		}
		if l.Version == "" || cmpVersions(c.Version, l.Version) > 0 || (cmpVersions(c.Version, l.Version) == 0 && l.URL == "") {
			l.Version, l.URL = c.Version, c.URL
		}
	}
	return l
}

// releaseLinks : la page de release GitHub de chaque version affichée (en service, après update).
func (s *Server) releaseLinks(ctx context.Context, rows []UpdateRow) map[string]string {
	links := map[string]string{}
	for _, r := range rows {
		owner, repo := repoOf(r.Changelog, r.Homepage, r.Src, r.EOL.Repo)
		if owner == "" || ctx.Err() != nil {
			continue
		}
		rels, err := s.projectReleases(ctx, owner, repo, r.Current, r.Next)
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
		err := fmt.Errorf("%s : HTTP %d %s", model, resp.StatusCode, firstOf(e.Error.Message, resp.Status))
		if resp.StatusCode == http.StatusTooManyRequests || strings.Contains(string(b), "RESOURCE_EXHAUSTED") {
			return nil, quotaError{err}
		}
		return nil, err
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

// quotaError : le quota du modèle est atteint (HTTP 429) : inutile d'envoyer les lots suivants.
type quotaError struct{ error }

func (e quotaError) Unwrap() error { return e.error }

// aiStop : l'analyse s'arrête là (quota atteint, ou délai de la vérification dépassé) ; avec ce
// qu'il faut en dire, une seule fois.
func aiStop(ctx context.Context, err error) (string, bool) {
	if errors.As(err, new(quotaError)) {
		return err.Error() + " (quota atteint, reprise à la prochaine vérification)", true
	}
	if ctx.Err() != nil {
		return "analyse interrompue (délai de la vérification dépassé)", true
	}
	return "", false
}

// aiAnswer : un élément de la réponse du modèle (aiSchema).
type aiAnswer struct {
	ID       string  `json:"id"`
	Urgency  string  `json:"urgency"`
	Summary  string  `json:"summary"`
	CVEs     []AICVE `json:"cves"`
	Breaking bool    `json:"breaking"`
}

// mergeFound : les CVE d'une analyse : celles relevées par le code (avec les versions qui les
// corrigent), et celles de l'IA qui figurent bien dans ce qu'elle a lu (une CVE absente des textes est
// inventée). La version de correction du code prime ; un GHSA dont le numéro CVE est déjà là saute.
func mergeFound(n notesResult, model []AICVE, infos map[string]CVEInfo) []AICVE {
	text := strings.ToUpper(n.Text)
	byID := map[string]*AICVE{}
	var order []string
	add := func(c AICVE) {
		c.ID = cveID(c.ID)
		if old, ok := byID[c.ID]; ok {
			old.Severity = firstOf(old.Severity, c.Severity)
			old.FixedIn = firstOf(old.FixedIn, c.FixedIn)
			return
		}
		byID[c.ID] = &c
		order = append(order, c.ID)
	}
	for id, versions := range n.Found {
		add(AICVE{ID: id, FixedIn: strings.Join(versions, ", ")})
	}
	for _, c := range model {
		id := cveID(c.ID)
		if _, ok := n.Found[id]; ok || strings.Contains(text, strings.ToUpper(id)) || slices.Contains(n.Fixed, id) {
			add(c)
		}
	}
	sort.Strings(order)
	var out []AICVE
	for _, id := range order {
		if alias := infos[id].Alias; strings.HasPrefix(id, "GHSA-") && alias != "" && byID[alias] != nil {
			continue
		}
		out = append(out, *byID[id])
	}
	return out
}

// aiBatch : paquets analysés par requête (quelques requêtes par jour, loin des quotas gratuits).
const aiBatch = 5

// analyze : les montées de version pas encore analysées, par lots ; l'erreur, s'il y en a une. Un
// paquet sans réponse du modèle est signalé (et redemandé à la vérification suivante) ; un quota
// atteint arrête les lots suivants.
func (s *Server) analyze(ctx context.Context, rows []UpdateRow) error {
	if s.cfg.GeminiKey == "" {
		return nil
	}
	done := s.rawAnalyses()
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
	batches := (len(todo) + aiBatch - 1) / aiBatch
	for start := 0; start < len(todo); start += aiBatch {
		if msg, stop := aiStop(ctx, nil); stop {
			errs = append(errs, msg)
			break
		}
		setPhase("analyse par l'IA : paquets, lot %d/%d", start/aiBatch+1, batches)
		batch := todo[start:min(start+aiBatch, len(todo))]
		var p strings.Builder
		p.WriteString(aiPrompt)
		notes := map[string]notesResult{}
		for _, r := range batch {
			n := s.releaseNotes(ctx, r)
			notes[r.ID] = n
			fmt.Fprintf(&p, "\n\n### id: %s — %s : A = %s, B = %s, C = %s\n", r.ID, r.Name, r.Current, firstOf(r.Next, r.Current), r.Upper())
			if n.Text == "" {
				p.WriteString("(aucun texte trouvé)\n")
			} else {
				p.WriteString(n.Text)
			}
			if len(n.Fixed) > 0 {
				// Une branche plus récente recite des failles déjà corrigées dans celle de A.
				fmt.Fprintf(&p, "\nDéjà corrigées dans la version A (n'en parle pas, ni dans le résumé ni dans les CVE) : %s\n", strings.Join(n.Fixed[:min(len(n.Fixed), 80)], ", "))
			}
		}
		raw, err := s.gemini(ctx, p.String())
		if err != nil {
			if msg, stop := aiStop(ctx, err); stop {
				errs = append(errs, msg)
				break
			}
			errs = append(errs, err.Error())
			continue
		}
		var answers []aiAnswer
		if err := json.Unmarshal(raw, &answers); err != nil {
			errs = append(errs, s.cfg.AIModel+" : réponse illisible")
			continue
		}
		infos := s.cveInfos()
		add := map[string]Analysis{}
		var missing []string
		for _, r := range batch {
			found := false
			for _, a := range answers {
				if r.ID != a.ID {
					continue
				}
				found = true
				n := notes[r.ID]
				add[r.analysisKey()] = Analysis{Urgency: a.Urgency, Summary: a.Summary, CVEs: mergeFound(n, a.CVEs, infos),
					Fixed: n.Fixed, Depth: n.Depth, Basis: firstOf(strings.Join(n.Basis, ", "), "rien à lire"), Model: s.cfg.AIModel, At: time.Now()}
			}
			if !found {
				missing = append(missing, r.Name)
			}
		}
		if len(missing) > 0 {
			errs = append(errs, s.cfg.AIModel+" : pas de réponse pour "+strings.Join(missing, ", "))
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
	done := s.rawAnalyses()
	var closure map[string]bool
	var errs []string
	for _, in := range inputs {
		if !in.Changed() || in.Owner == "" {
			continue
		}
		if msg, stop := aiStop(ctx, nil); stop {
			errs = append(errs, msg)
			break
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
		setPhase("analyse par l'IA : source %s", in.Name)
		raw, err := s.gemini(ctx, prompt)
		if err != nil {
			if msg, stop := aiStop(ctx, err); stop {
				errs = append(errs, in.Name+" : "+msg)
				break
			}
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

// titleCVEs : les CVE citées dans les titres, avec le paquet en tête du titre : relevées par le code,
// un petit modèle en oublie.
func titleCVEs(titles []string) []AICVE {
	var out []AICVE
	for _, t := range titles {
		pre, _, found := strings.Cut(t, ": ")
		if !found || strings.Contains(strings.ReplaceAll(pre, ", ", ","), " ") {
			pre = ""
		}
		for _, id := range cveIDsIn(t) {
			out = append(out, AICVE{ID: id, Pkg: pre})
		}
	}
	return out
}

// mergeCVEs : celles relevées dans les titres, avec la gravité que le modèle leur donne. Le modèle
// n'en ajoute pas : il n'a lu que ces titres, une CVE qu'il citerait en plus serait inventée.
func mergeCVEs(found, model []AICVE) []AICVE {
	sev := map[string]string{}
	for _, c := range model {
		sev[cveID(c.ID)] = c.Severity
	}
	seen := map[string]bool{}
	var out []AICVE
	for _, c := range found {
		c.ID = cveID(c.ID)
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
const aiInputVersion = 6

// inputKey : le nom d'une entrée du flake dans le cache des analyses (à part des paquets).
func inputKey(name string) string { return fmt.Sprintf("input.%s@%d", name, aiInputVersion) }

// analysisKey : la clé de l'analyse de ce que update apporterait à cette entrée.
func (r InputRow) analysisKey() string {
	return analysisKey(inputKey(r.Name), firstOf(r.ServiceRev, r.MainRev), r.NextRev)
}
