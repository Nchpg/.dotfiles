package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

// Onglet Mises à jour : l'urgence ne vient pas de l'IA mais des CVE elles-mêmes. Le code les relève
// (notes de version, avis de sécurité, titres de commits ; cf. notes.go), l'IA en complète ; le dashboard va chercher la note de chacune (NVD, sinon
// l'avis GitHub pour un GHSA) et si elle est exploitée en pratique (catalogue KEV de la CISA), puis
// rateUrgency classe. Les notes sont gardées sur disque ; une CVE pas encore notée est redemandée.

// CVEInfo : la note d'une CVE.
type CVEInfo struct {
	Score    float64   `json:"score"`              // CVSS de base, 0 si pas encore notée
	Network  bool      `json:"network"`            // attaquable par le réseau (AV:N)
	KEV      bool      `json:"kev"`                // exploitée en pratique (CISA)
	Severity string    `json:"severity,omitempty"` // la gravité donnée par l'avis du projet
	Alias    string    `json:"alias,omitempty"`    // le numéro CVE d'un GHSA
	Rejected bool      `json:"rejected,omitempty"` // rejetée par NVD (doublon, pas une faille)
	At       time.Time `json:"at"`
}

var (
	nvdBase = "https://services.nvd.nist.gov/rest/json/cves/2.0"
	kevURL  = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
	// nvdPause : NVD sans clé accepte 5 demandes par 30 s.
	nvdPause = 6500 * time.Millisecond
)

// cveRetry : une CVE sans note (trop récente) est redemandée au plus une fois par jour ; une note
// est relue au bout d'un mois (le KEV, lui, à chaque vérification).
const cveRetry, cveRefresh = 24 * time.Hour, 30 * 24 * time.Hour

var cveCache struct {
	sync.Mutex
	m map[string]CVEInfo
}

func (s *Server) cveFile() string { return filepath.Join(s.cfg.StateDir, "cves.json") }

func (s *Server) cveInfos() map[string]CVEInfo {
	cveCache.Lock()
	defer cveCache.Unlock()
	if cveCache.m == nil {
		cveCache.m = map[string]CVEInfo{}
		if b, err := os.ReadFile(s.cveFile()); err == nil {
			_ = json.Unmarshal(b, &cveCache.m)
		}
	}
	out := make(map[string]CVEInfo, len(cveCache.m))
	for k, v := range cveCache.m {
		out[k] = v
	}
	return out
}

func (s *Server) saveCVEInfos(m map[string]CVEInfo) {
	cveCache.Lock()
	defer cveCache.Unlock()
	cveCache.m = m
	if b, err := json.Marshal(m); err == nil {
		_ = os.WriteFile(s.cveFile(), b, 0o644)
	}
}

// addCVEInfos : ce que dit l'avis d'un dépôt (note, gravité, numéro CVE), sans écraser une note déjà
// là ni avancer la date de sa prochaine relecture.
func (s *Server) addCVEInfos(add map[string]CVEInfo) {
	if len(add) == 0 {
		return
	}
	infos := s.cveInfos()
	for id, info := range add {
		old, ok := infos[id]
		if !ok {
			infos[id] = info
			continue
		}
		if old.Score == 0 && info.Score > 0 {
			old.Score, old.Network = info.Score, info.Network
		}
		old.Severity, old.Alias = firstOf(info.Severity, old.Severity), firstOf(info.Alias, old.Alias)
		infos[id] = old
	}
	s.saveCVEInfos(infos)
}

// scoreCVEs : la note de chaque CVE des analyses (celles qui manquent ou ont vieilli) et le KEV.
func (s *Server) scoreCVEs(ctx context.Context) error {
	infos := s.cveInfos()
	ids := map[string]bool{}
	for _, a := range s.rawAnalyses() {
		for _, c := range a.CVEs {
			id := cveID(c.ID)
			ids[id] = true
			if alias := infos[id].Alias; alias != "" {
				ids[alias] = true // un GHSA : sa CVE, pour NVD et le KEV
			}
		}
	}
	kev, kevErr := s.kevSet(ctx)
	var errs []string
	asked := 0
	for id := range ids {
		info, ok := infos[id]
		stale := !ok || (info.Score == 0 && time.Since(info.At) > cveRetry) || time.Since(info.At) > cveRefresh
		if stale {
			if asked > 0 && strings.HasPrefix(id, "CVE-") {
				if !sleep(ctx, nvdPause) {
					break
				}
			}
			asked++
			fresh, err := s.fetchCVE(ctx, id)
			if err != nil {
				errs = append(errs, id+" : "+err.Error())
				if !ok {
					continue
				}
			} else {
				// Une note publique remplace celle de l'avis du dépôt ; sans elle, l'avis reste.
				if fresh.Score == 0 && ok {
					fresh.Score, fresh.Network = info.Score, info.Network
				}
				fresh.Severity, fresh.Alias = firstOf(fresh.Severity, info.Severity), firstOf(fresh.Alias, info.Alias)
				info = fresh
			}
		}
		if kevErr == nil {
			info.KEV = kev[id]
		}
		infos[id] = info
	}
	// Un GHSA prend la note et le KEV de sa CVE.
	for id, info := range infos {
		if a, ok := infos[info.Alias]; ok && info.Alias != "" {
			if a.Score > 0 {
				info.Score, info.Network = a.Score, a.Network
			}
			info.KEV, info.Rejected = info.KEV || a.KEV, a.Rejected
			infos[id] = info
		}
	}
	s.saveCVEInfos(infos)
	if kevErr != nil {
		errs = append(errs, "catalogue KEV : "+kevErr.Error())
	}
	if len(errs) > 0 {
		return fmt.Errorf("notes des CVE : %s", strings.Join(errs, " ; "))
	}
	return nil
}

// cveID : un identifiant dans sa forme officielle, la clé des notes : CVE en majuscules ; GHSA avec
// son préfixe en majuscules et le reste en minuscules (l'API GitHub distingue la casse).
func cveID(id string) string {
	id = strings.TrimSpace(id)
	if len(id) > 5 && strings.EqualFold(id[:5], "GHSA-") {
		return "GHSA-" + strings.ToLower(id[5:])
	}
	return strings.ToUpper(id)
}

// fetchCVE : la note d'une CVE (NVD) ou d'un GHSA (avis GitHub).
func (s *Server) fetchCVE(ctx context.Context, id string) (CVEInfo, error) {
	info := CVEInfo{At: time.Now()}
	if strings.HasPrefix(id, "GHSA-") {
		var adv struct {
			CVE      string `json:"cve_id"`
			Severity string `json:"severity"`
			CVSS     struct {
				Score  float64 `json:"score"`
				Vector string  `json:"vector_string"`
			} `json:"cvss"`
		}
		code, err := s.gh.api(ctx, "GET", "https://api.github.com/advisories/"+id, s.cfg.DispatchToken, nil, &adv)
		if code == http.StatusNotFound {
			return info, nil // pas (encore) dans la base publique : pas de note, redemandée plus tard
		}
		if err != nil {
			return info, err
		}
		info.Score, info.Network = adv.CVSS.Score, strings.Contains(adv.CVSS.Vector, "AV:N")
		info.Severity, info.Alias = strings.ToLower(adv.Severity), cveID(adv.CVE)
		return info, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, nvdBase+"?cveId="+id, nil)
	if err != nil {
		return info, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return info, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return info, fmt.Errorf("NVD : %s", resp.Status)
	}
	type metric struct {
		Type string `json:"type"` // Primary : la note de NVD ; Secondary : celle de l'éditeur
		Data struct {
			Score  float64 `json:"baseScore"`
			Vector string  `json:"attackVector"`
			Access string  `json:"accessVector"` // CVSS 2
		} `json:"cvssData"`
	}
	var body struct {
		Vulns []struct {
			CVE struct {
				Status  string `json:"vulnStatus"`
				Metrics struct {
					V40 []metric `json:"cvssMetricV40"`
					V31 []metric `json:"cvssMetricV31"`
					V30 []metric `json:"cvssMetricV30"`
					V2  []metric `json:"cvssMetricV2"`
				} `json:"metrics"`
			} `json:"cve"`
		} `json:"vulnerabilities"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return info, err
	}
	if len(body.Vulns) == 0 {
		return info, nil // inconnue de NVD pour l'instant
	}
	cve := body.Vulns[0].CVE
	if cve.Status == "Rejected" {
		info.Rejected = true
		return info, nil
	}
	m := cve.Metrics
	for _, list := range [][]metric{m.V31, m.V40, m.V30, m.V2} {
		if len(list) == 0 {
			continue
		}
		pick := list[0]
		for _, x := range list {
			if x.Type == "Primary" {
				pick = x
				break
			}
		}
		info.Score, info.Network = pick.Data.Score, pick.Data.Vector == "NETWORK" || pick.Data.Access == "NETWORK"
		break
	}
	return info, nil
}

// kevSet : les CVE exploitées en pratique (catalogue de la CISA, un seul fichier).
func (s *Server) kevSet(ctx context.Context) (map[string]bool, error) {
	v, err := s.gh.cached("kev", 12*time.Hour, func() (any, error) {
		ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, kevURL, nil)
		if err != nil {
			return nil, err
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s", resp.Status)
		}
		var body struct {
			Vulns []struct {
				ID string `json:"cveID"`
			} `json:"vulnerabilities"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return nil, err
		}
		set := map[string]bool{}
		for _, x := range body.Vulns {
			set[cveID(x.ID)] = true
		}
		return set, nil
	})
	if err != nil {
		return nil, err
	}
	return v.(map[string]bool), nil
}

var urgencyRank = map[string]int{"sans": 0, "conseille": 1, "urgent": 2}

// cveUrgency : le niveau d'une CVE. Exploitée en pratique, critique (≥ 9) ou grave (≥ 7) et
// attaquable par le réseau : urgent ; grave en local seulement, ou moyenne (≥ 4) : conseillé ; faible :
// sans. Pas encore notée : la gravité de l'avis du projet (critical : urgent) ; celle que l'IA a lue
// dans les notes ne rend jamais urgent. Rejetée par NVD : sans.
func cveUrgency(c AICVE, info CVEInfo, known bool) string {
	switch {
	case known && info.Rejected:
		return "sans"
	case known && info.KEV:
		return "urgent"
	case known && info.Score > 0:
		switch {
		case info.Score >= 9, info.Score >= 7 && info.Network:
			return "urgent"
		case info.Score >= 4:
			return "conseille"
		}
		return "sans"
	}
	switch strings.ToLower(info.Severity) {
	case "critical":
		return "urgent"
	case "low":
		return "sans"
	case "":
	default:
		return "conseille"
	}
	switch strings.ToLower(c.Severity) {
	case "low", "faible":
		return "sans"
	}
	return "conseille"
}

// rateUrgency : le niveau d'une analyse, d'après ses CVE (la plus grave) ; sans CVE, celui de l'IA,
// jamais au-delà de « conseillé » (des bugs corrigés ne sont pas urgents).
func rateUrgency(model string, cves []AICVE, infos map[string]CVEInfo) string {
	if len(cves) == 0 {
		if model == "urgent" {
			return "conseille"
		}
		return model
	}
	best := "sans"
	for _, c := range cves {
		info, ok := infos[cveID(c.ID)]
		if u := cveUrgency(c, info, ok); urgencyRank[u] > urgencyRank[best] {
			best = u
		}
	}
	return best
}

// fixedFor : une faille aux versions corrigées `versions` est-elle corrigée dans `ref` ? `known` faux
// si on ne peut pas le dire. La branche de `ref` d'abord (une faille corrigée en 5.8.8 et 6.1.3 :
// 5.8.9 l'a, 6.1.2 non) ; sinon des versions toutes plus anciennes la corrigent, toutes plus récentes
// non ; un mélange d'autres branches ne dit rien.
func fixedFor(versions []string, ref string, depth int) (fixed, known bool) {
	if ref == "" || len(versions) == 0 {
		return false, false
	}
	var branch []string
	older, newer := false, false
	for _, v := range versions {
		if sameBranch(v, ref, depth) {
			branch = append(branch, v)
		}
		if cmpVersions(v, ref) <= 0 {
			older = true
		} else {
			newer = true
		}
	}
	if len(branch) > 0 {
		low := branch[0]
		for _, v := range branch {
			if cmpVersions(v, low) < 0 {
				low = v
			}
		}
		return cmpVersions(low, ref) <= 0, true
	}
	if older != newer {
		return older, true
	}
	return false, false
}

// classifyRow : où en est chaque CVE de l'analyse d'un paquet, et le niveau qui en découle :
//   - service : déjà corrigée dans la version en service (patch de nixpkgs, notes ou avis de sa
//     branche, version corrigée atteinte) ; rejected : rejetée par NVD ; duplicate : le GHSA d'une CVE
//     déjà listée. Aucune ne compte ;
//   - update : la mise à jour du canal la corrige (patch, backport cité par les commits du canal,
//     version corrigée atteinte) ;
//   - channel : corrigée dans la branche d'après update, mais plus loin que le canal ;
//   - other : corrigée seulement dans une autre branche (rien ne dit que la tienne le sera) ;
//   - unknown : version de correction inconnue, le canal étant en retard sur le projet.
//
// `backports` : les CVE citées par les commits de l'entrée du flake qui fournit le paquet.
func classifyRow(row *UpdateRow, a Analysis, backports map[string]bool, infos map[string]CVEInfo) Analysis {
	depth := max(a.Depth, 1)
	listed := map[string]bool{}
	for _, c := range a.CVEs {
		listed[cveID(c.ID)] = true
	}
	var counted []AICVE
	cves := make([]AICVE, len(a.CVEs))
	for i, c := range a.CVEs {
		id := cveID(c.ID)
		vs := fixedVersions(c.FixedIn)
		inService, _ := fixedFor(vs, row.Current, depth)
		byUpdate, knownNext := fixedFor(vs, row.Next, depth)
		nextBranch := false
		for _, v := range vs {
			nextBranch = nextBranch || sameBranch(v, row.Next, depth)
		}
		switch {
		case infos[id].Rejected:
			c.Status = "rejected"
		case strings.HasPrefix(id, "GHSA-") && listed[infos[id].Alias]:
			c.Status = "duplicate" // le GHSA d'une CVE déjà listée
		case slices.Contains(row.Patches, id), slices.Contains(a.Fixed, id), inService:
			c.Status = "service"
		case slices.Contains(row.NextPatches, id), backports[id], byUpdate, len(vs) == 0 && !row.Behind():
			c.Status = "update"
		case knownNext && nextBranch:
			c.Status = "channel"
		case len(vs) > 0:
			c.Status = "other"
		default:
			c.Status = "unknown"
		}
		cves[i] = c
		if c.Status == "service" || c.Status == "rejected" || c.Status == "duplicate" {
			continue
		}
		counted = append(counted, c)
		info, ok := infos[id]
		serious := urgencyRank[cveUrgency(c, info, ok)] >= urgencyRank["conseille"]
		if (c.Status == "channel" || c.Status == "other") && serious {
			row.Stuck, row.OtherBranch = row.Stuck || c.Status == "channel", row.OtherBranch || c.Status == "other"
			// La version qui la corrige, la plus proche au-delà du canal.
			for _, v := range vs {
				if cmpVersions(v, row.Next) > 0 && (row.FixIn == "" || cmpVersions(v, row.FixIn) < 0) {
					row.FixIn = v
				}
			}
		}
	}
	a.CVEs = cves
	if len(a.CVEs) > 0 && len(counted) == 0 {
		a.Urgency = "sans" // toutes déjà corrigées en service
	} else {
		a.Urgency = rateUrgency(a.ModelUrgency, counted, infos)
	}
	return a
}

// StatusLabel : où en est la CVE, lisiblement.
func (c AICVE) StatusLabel() string {
	switch c.Status {
	case "service":
		return "déjà corrigée en service"
	case "update":
		return "corrigée par update"
	case "channel":
		return "corrigée en " + c.FixedIn + ", pas dans le canal"
	case "other":
		return "corrigée en " + c.FixedIn + ", pas dans cette branche"
	case "unknown":
		return "version de correction inconnue"
	}
	return ""
}

// ShownCVEs : les CVE qui concernent encore ce serveur (pas celles déjà corrigées en service).
func (a Analysis) ShownCVEs() []AICVE {
	var out []AICVE
	for _, c := range a.CVEs {
		if c.Status != "service" && c.Status != "rejected" && c.Status != "duplicate" {
			out = append(out, c)
		}
	}
	return out
}
