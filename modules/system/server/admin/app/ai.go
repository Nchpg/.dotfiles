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
	"path/filepath"
	"regexp"
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
	Urgency string    `json:"urgency"` // urgent, conseille, sans
	Summary string    `json:"summary"`
	CVEs    []AICVE   `json:"cves"`
	Basis   string    `json:"basis"` // ce qu'elle a lu
	Model   string    `json:"model"`
	At      time.Time `json:"at"`
	// Faite par le modèle de secours : pourquoi (le refus du principal). Toute analyse d'un autre
	// modèle que le principal est retentée avec lui à la vérification suivante.
	Fallback string `json:"fallback,omitempty"`
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

// releaseNotes : les notes des versions sautées (releases GitHub entre `from` exclue et `to`
// incluse), sinon la page de notes de version autour de `to` ; et les avis de sécurité du projet.
func (s *Server) releaseNotes(ctx context.Context, row UpdateRow) (text string, basis []string) {
	owner, repo := repoOf(row.Changelog, row.Homepage)
	var b strings.Builder
	if owner != "" {
		var rels []struct {
			Tag  string `json:"tag_name"`
			Body string `json:"body"`
		}
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases?per_page=40", owner, repo)
		if _, err := s.gh.api(ctx, "GET", url, s.cfg.DispatchToken, nil, &rels); err == nil {
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
			"id":      map[string]any{"type": "STRING"},
			"urgency": map[string]any{"type": "STRING", "enum": []string{"urgent", "conseille", "sans"}},
			"summary": map[string]any{"type": "STRING"},
			"cves": map[string]any{"type": "ARRAY", "items": map[string]any{"type": "OBJECT", "properties": map[string]any{
				"id": map[string]any{"type": "STRING"}, "severity": map[string]any{"type": "STRING"}}}},
		},
		"required": []string{"id", "urgency", "summary"},
	},
}

// geminiBase : l'API Gemini (remplacée dans les tests).
var geminiBase = "https://generativelanguage.googleapis.com/v1beta"

// aiTimeout : l'attente d'une réponse, au-delà le modèle de secours.
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

// errQuota : le modèle refuse (quota atteint, indisponible, ou inconnu) : on passe au secours.
type errQuota struct{ msg string }

func (e errQuota) Error() string { return e.msg }

// gemini : une requête, la réponse JSON du modèle.
func (s *Server) gemini(ctx context.Context, model, prompt string) ([]byte, error) {
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
		// Pas de réponse à temps (modèle surchargé, ou qui réfléchit trop longtemps) : le secours.
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, errQuota{model + " : pas de réponse en " + aiTimeout.String()}
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
		msg := fmt.Sprintf("%s : HTTP %d %s", model, resp.StatusCode, firstOf(e.Error.Message, resp.Status))
		switch resp.StatusCode {
		case http.StatusTooManyRequests, http.StatusServiceUnavailable:
			return nil, errQuota{msg}
		case http.StatusNotFound:
			return nil, errQuota{msg + s.geminiModels(ctx)}
		}
		return nil, errors.New(msg)
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

// geminiModels : les modèles « flash » que la clé peut appeler (pour corriger le nom dans la config).
func (s *Server) geminiModels(ctx context.Context) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, geminiBase+"/models?pageSize=200", nil)
	if err != nil {
		return ""
	}
	req.Header.Set("x-goog-api-key", s.cfg.GeminiKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	var out struct {
		Models []struct{ Name string } `json:"models"`
	}
	if json.NewDecoder(resp.Body).Decode(&out) != nil {
		return ""
	}
	var names []string
	for _, m := range out.Models {
		if n := strings.TrimPrefix(m.Name, "models/"); strings.Contains(n, "flash") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	return " (modèles disponibles : " + strings.Join(names, ", ") + ")"
}

// aiBatch : paquets analysés par requête (quelques requêtes par jour, loin des quotas gratuits).
const aiBatch = 5

// analyze : les montées de version pas encore analysées ; l'erreur, s'il y en a une.
func (s *Server) analyze(ctx context.Context, rows []UpdateRow) error {
	if s.cfg.GeminiKey == "" {
		return nil
	}
	done := s.analyses()
	var todo, retry []UpdateRow
	for _, r := range rows {
		if r.Change != "" && r.Change != "same" && r.Current != "" && r.Next != "" {
			a, ok := done[analysisKey(r.Name, r.Current, r.Next)]
			switch {
			case !ok:
				todo = append(todo, r)
			case a.Model != s.cfg.AIModel:
				// Faite par le secours (ou par un modèle qu'on a changé depuis) : retentée avec le principal.
				retry = append(retry, r)
			}
		}
	}
	errs := s.analyzeBatches(ctx, todo, true)
	// Faites par le secours : le principal seulement ; s'il refuse encore, on garde ce qu'on a.
	s.analyzeBatches(ctx, retry, false)
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, " ; "))
	}
	return nil
}

// analyzeBatches : les analyses de ces montées de version, par lots ; `fallback` : le modèle de
// secours si le principal refuse. Les erreurs, lot par lot.
func (s *Server) analyzeBatches(ctx context.Context, todo []UpdateRow, fallback bool) []string {
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
		model, why := s.cfg.AIModel, ""
		raw, err := s.gemini(ctx, model, p.String())
		var q errQuota
		if errors.As(err, &q) && fallback && s.cfg.AIFallback != "" {
			model, why = s.cfg.AIFallback, q.msg
			raw, err = s.gemini(ctx, model, p.String())
		}
		if err != nil {
			errs = append(errs, err.Error())
			// Nouvel essai du principal, refusé : la raison sur l'analyse gardée (la page la montre).
			if !fallback {
				done, kept := s.analyses(), map[string]Analysis{}
				for _, r := range batch {
					k := analysisKey(r.Name, r.Current, r.Next)
					if a, ok := done[k]; ok {
						a.Fallback = err.Error()
						kept[k] = a
					}
				}
				s.saveAnalyses(kept)
			}
			continue
		}
		var answers []struct {
			ID      string  `json:"id"`
			Urgency string  `json:"urgency"`
			Summary string  `json:"summary"`
			CVEs    []AICVE `json:"cves"`
		}
		if err := json.Unmarshal(raw, &answers); err != nil {
			errs = append(errs, model+" : réponse illisible")
			continue
		}
		add := map[string]Analysis{}
		for _, a := range answers {
			for _, r := range batch {
				if r.ID == a.ID {
					add[analysisKey(r.Name, r.Current, r.Next)] = Analysis{Urgency: a.Urgency, Summary: a.Summary, CVEs: a.CVEs,
						Basis: firstOf(bases[r.ID], "rien à lire"), Model: model, At: time.Now(), Fallback: why}
				}
			}
		}
		s.saveAnalyses(add)
	}
	return errs
}
