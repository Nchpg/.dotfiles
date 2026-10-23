package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"
)

// État de think : version qui tourne, décision d'apps-deploy, sondes des sites.

type DeployStatus struct {
	Checked  int64  `json:"checked"`
	Head     string `json:"head"`
	Deployed string `json:"deployed"`
	State    string `json:"state"`
	Pending  []struct {
		SHA     string `json:"sha"`
		Subject string `json:"subject"`
	} `json:"pending"`
	Checkout *struct {
		Branch    string `json:"branch"`
		Modified  int    `json:"modified"`
		Untracked int    `json:"untracked"`
		Ahead     *int   `json:"ahead"`
		Behind    *int   `json:"behind"`
	} `json:"checkout"`
}

func readDeployStatus(path string) (*DeployStatus, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s DeployStatus
	return &s, json.Unmarshal(b, &s)
}

// Fresh : apps-deploy passe chaque minute ; au-delà de 5, son état ne dit plus rien.
func (s *DeployStatus) Fresh() bool {
	return s != nil && time.Since(time.Unix(s.Checked, 0)) < 5*time.Minute
}

// Révision de la génération active : commit, `<commit>-dirty`, ou vide.
func deployedRevision(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/run/current-system/sw/bin/nixos-version", "--configuration-revision").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// deployFailed : la dernière exécution d'apps-deploy a échoué (build refusé, par exemple).
func deployFailed(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "systemctl", "is-failed", "--quiet", "apps-deploy.service").Run() == nil
}

// Probes : succès de chaque sonde blackbox, par nom servi (instance `https://<nom>/<chemin>`).
func probes(ctx context.Context, prom string) map[string]bool {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", prom+"/api/v1/query?query="+url.QueryEscape("probe_success"), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var out struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Value  [2]any            `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if json.NewDecoder(resp.Body).Decode(&out) != nil {
		return nil
	}
	up := map[string]bool{}
	for _, r := range out.Data.Result {
		u, err := url.Parse(r.Metric["instance"])
		if err != nil || u.Host == "" {
			continue
		}
		ok := r.Value[1] == "1"
		// Plusieurs sondes pour un même nom : il faut qu'elles passent toutes.
		if prev, seen := up[u.Host]; seen {
			ok = ok && prev
		}
		up[u.Host] = ok
	}
	return up
}

// answers : le site répond-il en local (port de bouclage), comme le vérifie l'annonce Discord.
func answers(ctx context.Context, port int, path string) (int, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if path == "" {
		path = "/"
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://127.0.0.1:"+itoa(port)+path, nil)
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return 0, false
	}
	resp.Body.Close()
	return resp.StatusCode, resp.StatusCode < 400
}

// probes, avec en plus les domaines qu'une demande vient de voir répondre : la sonde Prometheus
// passe toutes les minutes, elle peut encore porter l'échec d'avant la modification.
func (s *Server) probes(ctx context.Context) map[string]bool {
	up := probes(ctx, s.cfg.Prometheus)
	if up == nil {
		up = map[string]bool{}
	}
	for _, d := range s.jobs.recentlyVerified(3 * time.Minute) {
		up[d] = true
	}
	return up
}
