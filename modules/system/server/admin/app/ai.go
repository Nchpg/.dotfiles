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
	Breaking bool      `json:"breaking,omitempty"`
	Basis    string    `json:"basis"` // ce qu'elle a lu
	Model    string    `json:"model"`
	At       time.Time `json:"at"`
}

type AICVE struct {
	ID       string `json:"id"`
	Severity string `json:"severity"`
}

// UrgencyLabel : le niveau, lisiblement.
func (a Analysis) UrgencyLabel() string {
	return map[string]string{"urgent": "urgent", "conseille": "conseillé", "sans": "sans urgence"}[a.Urgency]
}

func analysisKey(name, from, to string) string { return name + "|" + from + "|" + to }

var aiCache struct {
	sync.Mutex
	m map[string]Analysis
}

func (s *Server) aiFile() string { return filepath.Join(s.cfg.StateDir, "ai.json") }

func (s *Server) analyses() map[string]Analysis {
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
	s.analyses()
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
	Tag  string `json:"tag_name"`
	Body string `json:"body"`
	URL  string `json:"html_url"`
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
				if cmpVersions(r.Tag, row.Current) > 0 && cmpVersions(r.Tag, row.Next) <= 0 {
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
			if i := strings.Index(page, row.Next); i >= 0 {
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
		}
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/security-advisories?per_page=30&state=published", owner, repo)
		if _, err := s.gh.api(ctx, "GET", url, s.cfg.DispatchToken, nil, &advs); err == nil && len(advs) > 0 {
			var a strings.Builder
			for _, v := range advs {
				var ranges []string
				for _, x := range v.Vulns {
					ranges = append(ranges, fmt.Sprintf("touchées %s, corrigées %s", x.Range, x.Patched))
				}
				fmt.Fprintf(&a, "- %s %s (%s) : %s [%s]\n", firstOf(v.CVE, v.GHSA), v.GHSA, v.Severity, v.Summary, strings.Join(ranges, " ; "))
			}
			text += "\n\nAvis de sécurité du projet (GitHub) :\n" + clip(a.String(), 6000)
			basis = append(basis, "avis de sécurité GitHub")
		}
	}
	return text, basis
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

const aiPrompt = `Tu aides à administrer un serveur NixOS personnel. Pour chaque paquet ci-dessous, une mise à jour est disponible de la version A à la version B. À partir UNIQUEMENT des textes fournis (notes de version, avis de sécurité du projet), dis si elle est urgente :
- "urgent" : elle corrige une faille de sécurité qui touche la version A et qui est sérieuse (exécution de code, contournement d'authentification, fuite de données, CVE de gravité haute ou critique) ;
- "conseille" : elle corrige une faille mineure, ou des bugs gênants ;
- "sans" : rien d'important pour un serveur.
"summary" : en français, deux ou trois phrases sur ce qui change d'important (sécurité d'abord). "cves" : les CVE (ou GHSA) corrigées entre A (exclue) et B (incluse), avec leur gravité. Si les textes ne disent rien d'utile, "urgency" = "sans" et "summary" le dit ("Aucune note de version lisible"). N'invente rien, ne suppose rien au-delà des textes. Réponds pour chaque paquet, avec son "id".`

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
				"id": map[string]any{"type": "STRING"}, "severity": map[string]any{"type": "STRING"}}}},
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
		if r.Change != "" && r.Change != "same" && r.Current != "" && r.Next != "" {
			if _, ok := done[analysisKey(r.Name, r.Current, r.Next)]; !ok {
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
			fmt.Fprintf(&p, "\n\n### id: %s — %s : A = %s, B = %s\n", r.ID, r.Name, r.Current, r.Next)
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
					add[analysisKey(r.Name, r.Current, r.Next)] = Analysis{Urgency: a.Urgency, Summary: a.Summary, CVEs: a.CVEs,
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

const aiInputPrompt = `Tu aides à administrer un serveur NixOS personnel. Une entrée de son flake, %s (dépôt GitHub %s/%s), avancerait de la révision A à la révision B ; plus bas, le titre des commits entre les deux. Ils sont déjà triés : seuls restent ceux qui touchent un paquet présent sur ce serveur, un module NixOS, ou rien de précis (%d gardés sur %d). Les paquets qui ont leur propre analyse (avec leurs notes de version) en sont retirés : n'en parle pas.
Paquets de ce serveur qui viennent de cette entrée : %s. Les autres paquets du serveur viennent d'une autre entrée : un commit d'ici qui les touche ne compte pas, sauf une bibliothèque dont dépendent ceux de cette entrée.
À partir UNIQUEMENT de ces titres, dis si la mise à jour est urgente :
- "urgent" : un commit corrige une faille de sécurité sérieuse (CVE de gravité haute ou critique, exécution de code, contournement d'authentification, fuite de données) dans un paquet que ce serveur utilise depuis cette entrée ;
- "conseille" : une faille mineure, ou des bugs gênants, corrigés dans ce que ce serveur utilise depuis cette entrée ;
- "sans" : rien d'important pour ce serveur.
"breaking" : true seulement si un commit annonce un changement cassant pour la config de ce serveur (option renommée ou retirée, comportement par défaut changé, migration à faire à la main) dans un module ou un paquet qu'il utilise.
"summary" : en français, deux ou trois phrases : la sécurité d'abord, puis les changements cassants, puis ce qui compte pour ce serveur, en citant les paquets ; ignore ce que ce serveur n'utilise pas. "cves" : les CVE (ou GHSA) citées dans les titres, avec leur gravité si elle est dite. N'invente rien. Réponds avec un seul élément, d'"id" %q.

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
	reAttrSuffix = regexp.MustCompile(`_[0-9].*$`) // linux_7_3, openssl_3_6…
)

// relevantTitles : les titres qui comptent pour ce serveur, sans doublon (nixpkgs a souvent le
// même avec et sans « (#PR) ») : ceux sans paquet précis, ceux du module NixOS d'un paquet du serveur
// (changements cassants), et ceux d'un paquet présent sur le serveur, sauf ceux des paquets analysés
// à part (`own`, leur ligne dans Versions).
func relevantTitles(titles []string, closure, own map[string]bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, t := range titles {
		t = strings.TrimSpace(rePRSuffix.ReplaceAllString(strings.TrimSpace(t), ""))
		if seen[t] {
			continue
		}
		seen[t] = true
		pre, _, found := strings.Cut(t, ": ")
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
	own := map[string]bool{}
	for _, r := range rows {
		own[strings.ToLower(r.Name)] = true
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
		prompt := fmt.Sprintf(aiInputPrompt, in.Name, in.Owner, in.Repo, len(titles), len(all), firstOf(strings.Join(mine, ", "), "aucun (module ou outil)"), in.Name) +
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
		s.saveAnalyses(map[string]Analysis{key: {Urgency: a.Urgency, Summary: a.Summary, CVEs: a.CVEs, Breaking: a.Breaking,
			Basis: fmt.Sprintf("%s sur %d", plural(len(titles), "titre de commit", "titres de commits"), len(all)), Model: s.cfg.AIModel, At: time.Now()}})
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, " ; "))
	}
	return nil
}

// aiInputVersion : la façon de lire une entrée du flake ; la changer refait ces analyses une fois.
const aiInputVersion = 2

// inputKey : le nom d'une entrée du flake dans le cache des analyses (à part des paquets).
func inputKey(name string) string { return fmt.Sprintf("input.%s@%d", name, aiInputVersion) }

// analysisKey : la clé de l'analyse de ce que update apporterait à cette entrée.
func (r InputRow) analysisKey() string {
	return analysisKey(inputKey(r.Name), firstOf(r.ServiceRev, r.MainRev), r.NextRev)
}
