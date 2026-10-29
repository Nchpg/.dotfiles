package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// Onglet Mises à jour : les branches d'un logiciel, d'après endoflife.date (sa liste publique des
// branches maintenues, GitHub ou non : noyau, nginx, PostgreSQL, Nextcloud…). Le produit porte le
// nom du paquet ; un paquet absent est simplement ignoré. Il donne :
//   - la forme des branches (« 7.3 », « 17 ») : la branche d'une version, sans la deviner ;
//   - la dernière version de chaque branche (colonne Dernière, même hors GitHub) ;
//   - si une branche est encore maintenue (une branche en fin de vie ne reçoit plus de correctifs) ;
//   - parfois le dépôt GitHub du projet (purl pkg:github/…), quand le paquet ne le donne pas.

var eolBase = "https://endoflife.date/api/v1/products/"

// eolCycle : une branche d'un produit.
type eolCycle struct {
	Name       string `json:"name"`
	Maintained bool   `json:"isMaintained"`
	EOLFrom    string `json:"eolFrom"`
	Latest     struct {
		Name string `json:"name"`
		Link string `json:"link"`
	} `json:"latest"`
}

type eolProduct struct {
	Cycles      []eolCycle `json:"releases"`
	Identifiers []struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	} `json:"identifiers"`
}

// eolProductOf : le produit d'un paquet (nil s'il n'est pas recensé), gardé quelques heures.
func (s *Server) eolProductOf(ctx context.Context, name string) (*eolProduct, error) {
	v, err := s.gh.cached("eol:"+name, 12*time.Hour, func() (any, error) {
		ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, eolBase+name, nil)
		if err != nil {
			return nil, err
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound {
			return (*eolProduct)(nil), nil
		}
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("endoflife.date : %s", resp.Status)
		}
		var body struct {
			Result eolProduct `json:"result"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			return nil, err
		}
		return &body.Result, nil
	})
	if err != nil {
		return nil, err
	}
	return v.(*eolProduct), nil
}

// cycleOf : la branche d'une version (celle dont le nom en est le début : « 7.3 » pour 7.3.2).
func (p *eolProduct) cycleOf(version string) *eolCycle {
	for i := range p.Cycles {
		c := &p.Cycles[i]
		if n := len(versionParts(c.Name)); n > 0 && sameBranch(version, c.Name, n) {
			return c
		}
	}
	return nil
}

// repo : le dépôt GitHub du produit, s'il le donne (« pkg:github/nginx/nginx »).
func (p *eolProduct) repo() string {
	for _, id := range p.Identifiers {
		if rest, ok := strings.CutPrefix(id.ID, "pkg:github/"); ok && id.Type == "purl" {
			return "https://github.com/" + rest
		}
	}
	return ""
}

// EOLInfo : ce qu'endoflife.date dit d'un paquet, gardé à la vérification.
type EOLInfo struct {
	Repo   string      `json:"repo"`   // son dépôt GitHub, s'il est connu
	Depth  int         `json:"depth"`  // les numéros qui nomment une branche (2 pour « 7.3 »)
	Cycle  string      `json:"cycle"`  // la branche de la version d'après update
	Ended  bool        `json:"ended"`  // cette branche n'est plus maintenue
	Since  string      `json:"since"`  // depuis quand
	Latest []Candidate `json:"latest"` // la dernière version de chaque branche
}

// Candidate : une version publiée, et sa page.
type Candidate struct {
	Version string `json:"version"`
	URL     string `json:"url"`
}

// eolInfos : pour chaque paquet recensé par endoflife.date, ses branches.
func (s *Server) eolInfos(ctx context.Context, rows []UpdateRow) map[string]EOLInfo {
	out := map[string]EOLInfo{}
	for _, r := range rows {
		v := firstOf(r.Next, r.Current)
		if v == "" {
			continue
		}
		p, err := s.eolProductOf(ctx, r.Name)
		if err != nil || p == nil {
			continue
		}
		info := EOLInfo{Repo: p.repo()}
		for _, c := range p.Cycles {
			if c.Latest.Name != "" {
				info.Latest = append(info.Latest, Candidate{c.Latest.Name, c.Latest.Link})
			}
		}
		if c := p.cycleOf(v); c != nil {
			info.Depth, info.Cycle, info.Ended, info.Since = len(versionParts(c.Name)), c.Name, !c.Maintained, c.EOLFrom
		}
		out[r.Name] = info
	}
	return out
}

// applyEOL : les branches trouvées à la vérification, sur chaque ligne.
func applyEOL(rows []UpdateRow, infos map[string]EOLInfo) {
	for i := range rows {
		if e, ok := infos[rows[i].Name]; ok {
			rows[i].EOL = e
		}
	}
}
