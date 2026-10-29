package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Onglet Mises à jour : l'urgence ne vient pas de l'IA mais des CVE elles-mêmes. Gemini les relève
// (et le code dans les titres de commits) ; le dashboard va chercher la note de chacune (NVD, sinon
// l'avis GitHub pour un GHSA) et si elle est exploitée en pratique (catalogue KEV de la CISA), puis
// rateUrgency classe. Les notes sont gardées sur disque ; une CVE pas encore notée est redemandée.

// CVEInfo : la note d'une CVE.
type CVEInfo struct {
	Score   float64   `json:"score"`   // CVSS de base, 0 si pas encore notée
	Network bool      `json:"network"` // attaquable par le réseau (AV:N)
	KEV     bool      `json:"kev"`     // exploitée en pratique (CISA)
	At      time.Time `json:"at"`
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

// scoreCVEs : la note de chaque CVE des analyses (celles qui manquent ou ont vieilli) et le KEV.
func (s *Server) scoreCVEs(ctx context.Context) error {
	infos := s.cveInfos()
	ids := map[string]bool{}
	for _, a := range s.rawAnalyses() {
		for _, c := range a.CVEs {
			ids[strings.ToUpper(c.ID)] = true
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
				info = fresh
			}
		}
		if kevErr == nil {
			info.KEV = kev[id]
		}
		infos[id] = info
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

// fetchCVE : la note d'une CVE (NVD) ou d'un GHSA (avis GitHub).
func (s *Server) fetchCVE(ctx context.Context, id string) (CVEInfo, error) {
	info := CVEInfo{At: time.Now()}
	if strings.HasPrefix(id, "GHSA-") {
		var adv struct {
			CVSS struct {
				Score  float64 `json:"score"`
				Vector string  `json:"vector_string"`
			} `json:"cvss"`
		}
		if _, err := s.gh.api(ctx, "GET", "https://api.github.com/advisories/"+id, s.cfg.DispatchToken, nil, &adv); err != nil {
			return info, err
		}
		info.Score, info.Network = adv.CVSS.Score, strings.Contains(adv.CVSS.Vector, "AV:N")
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
		Data struct {
			Score  float64 `json:"baseScore"`
			Vector string  `json:"attackVector"`
			Access string  `json:"accessVector"` // CVSS 2
		} `json:"cvssData"`
	}
	var body struct {
		Vulns []struct {
			CVE struct {
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
	m := body.Vulns[0].CVE.Metrics
	for _, list := range [][]metric{m.V31, m.V40, m.V30, m.V2} {
		if len(list) > 0 {
			d := list[0].Data
			info.Score, info.Network = d.Score, d.Vector == "NETWORK" || d.Access == "NETWORK"
			break
		}
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
			set[strings.ToUpper(x.ID)] = true
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
// sans. Pas encore notée : la gravité annoncée (projet, avis GitHub), sinon conseillé.
func cveUrgency(c AICVE, info CVEInfo, known bool) string {
	switch {
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
	switch strings.ToLower(c.Severity) {
	case "critical", "critique":
		return "urgent"
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
		info, ok := infos[strings.ToUpper(c.ID)]
		if u := cveUrgency(c, info, ok); urgencyRank[u] > urgencyRank[best] {
			best = u
		}
	}
	return best
}
