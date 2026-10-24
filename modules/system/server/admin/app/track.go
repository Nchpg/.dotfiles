package main

import (
	"context"
	"net/http"
	"sort"
	"sync"
	"time"
)

// Suivi d'une demande à apps.yml (appareil VPN, accès, compte, clé SSH) : le run GitHub qu'elle a
// lancé est retrouvé, puis suivi jusqu'au commit sur main ; pour ce que think applique seul
// (`Auto`), jusqu'à ce qu'apps-deploy l'ait appliqué. La page affiche un voyant (orange : en
// cours, vert : fait, rouge : refusé) que htmx relit.

type Track struct {
	ID, Label string
	Next      string // ce qui reste à faire une fois commité (sans Auto)
	Auto      bool   // apps-deploy l'applique seul : suivi jusqu'à think
	State     string // running, deploying, done, failed
	Detail    string
	Link      string
	SHA       string
	Reload    bool // page de liste : son contenu est relu à chaque changement d'état
	t0        time.Time
	run       int64
	committed time.Time
}

var tracks = struct {
	sync.Mutex
	m       map[string]*Track
	claimed map[int64]bool // runs déjà attribués à une demande
}{m: map[string]*Track{}, claimed: map[int64]bool{}}

// trackOf : une copie de l'état d'une demande (nil si inconnue, ou trop ancienne).
func trackOf(id string) *Track {
	tracks.Lock()
	defer tracks.Unlock()
	t, ok := tracks.m[id]
	if !ok || time.Since(t.t0) > time.Hour {
		return nil
	}
	c := *t
	return &c
}

func (t *Track) set(state, detail, link, sha string) {
	tracks.Lock()
	defer tracks.Unlock()
	t.State, t.Detail, t.Link, t.SHA = state, detail, link, sha
}

// dispatch : lance apps.yml et suit le run ; l'identifiant sert au voyant de la page (?suivi=).
// `next` vide : think l'applique seul, le voyant suit jusqu'à son application.
func (s *Server) dispatch(ctx context.Context, inputs map[string]string, label, next string) (string, error) {
	t0 := time.Now()
	if err := s.gh.Dispatch(ctx, inputs); err != nil {
		return "", err
	}
	t := &Track{ID: newID(), Label: label, Next: next, Auto: next == "", State: "running", t0: t0}
	tracks.Lock()
	tracks.m[t.ID] = t
	tracks.Unlock()
	go s.follow(t)
	return t.ID, nil
}

// follow : le premier run d'apps.yml créé après la demande et pas encore attribué, jusqu'à sa fin.
func (s *Server) follow(t *Track) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	actions := "https://github.com/" + s.cfg.Repo + "/actions/workflows/apps.yml"
	for sleep(ctx, 3*time.Second) {
		runs, err := s.gh.Runs(ctx)
		if err != nil {
			continue
		}
		sort.Slice(runs, func(i, j int) bool { return runs[i].CreatedAt.Before(runs[j].CreatedAt) })
		tracks.Lock()
		if t.run == 0 {
			for _, r := range runs {
				// Horloges de GitHub et de think : 10 s de marge.
				if !tracks.claimed[r.ID] && !r.CreatedAt.Before(t.t0.Add(-10*time.Second)) {
					t.run, tracks.claimed[r.ID] = r.ID, true
					t.Link = r.HTMLURL
					break
				}
			}
		}
		tracks.Unlock()
		for _, r := range runs {
			if r.ID != t.run || r.Status != "completed" {
				continue
			}
			if r.Conclusion != "success" {
				t.set("failed", "apps.yml a refusé la demande ("+r.Conclusion+") : le détail est dans le run.", r.HTMLURL, "")
				return
			}
			// La tête relue ici rafraîchit aussi le cache des pages : elles montrent le commit.
			head, _ := s.gh.Head(ctx)
			sha := head
			if len(sha) >= 7 {
				sha = sha[:7]
			}
			link := "https://github.com/" + s.cfg.Repo + "/commit/" + head
			if !t.Auto {
				t.set("done", "", link, sha)
				return
			}
			tracks.Lock()
			t.committed = time.Now()
			tracks.Unlock()
			t.set("deploying", "", link, sha)
			s.followDeploy(ctx, t, head)
			return
		}
	}
	t.set("failed", "pas de fin de run après 8 minutes (GitHub Actions en retard ?)", actions, "")
}

// followDeploy : apps-deploy a appliqué le commit (think tourne lui ou un commit après) ; s'il
// attend un rebuild à la main, le voyant le dit et reste orange.
func (s *Server) followDeploy(ctx context.Context, t *Track, head string) {
	waiting := map[string]string{
		"attente":    "think attend un rebuild à la main (main contient aussi d'autres changements).",
		"non_pousse": "think tourne des commits pas encore poussés : git push, puis rebuild.",
		"en_avance":  "think a des commits pas encore poussés : git push.",
		"diverge":    "l'historique de think a divergé de main : à régler dans le terminal.",
		"local":      "think tourne une version locale : rebuild à la main.",
	}
	for sleep(ctx, 3*time.Second) {
		st, err := readDeployStatus(s.cfg.DeployStatus)
		if err != nil || !st.Fresh() || time.Unix(st.Checked, 0).Before(t.committed) {
			continue
		}
		if st.Deployed == head || (st.State == "a_jour" && st.Head == st.Deployed) {
			t.set("done", "", t.Link, t.SHA)
			return
		}
		detail := waiting[st.State]
		tracks.Lock()
		t.Detail = detail
		tracks.Unlock()
	}
	t.set("failed", "pas appliqué après 8 minutes : voir l'état de think sur la page Sites.", t.Link, t.SHA)
}

// trackFragment : le voyant seul, relu par htmx tant que la demande court. Inconnu : le dashboard a
// redémarré entre-temps (think a appliqué une nouvelle version qui le concerne).
func (s *Server) trackFragment(w http.ResponseWriter, r *http.Request) {
	t := trackOf(r.PathValue("id"))
	if t == nil {
		t = &Track{ID: r.PathValue("id"), State: "lost", Label: "Demande", Detail: "le dashboard a redémarré (nouvelle version de think) : la page est relue."}
	}
	t.Reload = r.URL.Query().Has("reload")
	s.render(w, "track", t)
}

// tracked : retour sur une page de liste, avec le voyant de la demande.
func tracked(w http.ResponseWriter, r *http.Request, page, id string) {
	http.Redirect(w, r, page+"?suivi="+id, http.StatusSeeOther)
}

// listTrack : le voyant d'une page de liste (?suivi=), qui relit son contenu à chaque étape.
func listTrack(r *http.Request) *Track {
	t := trackOf(r.URL.Query().Get("suivi"))
	if t != nil {
		t.Reload = true
	}
	return t
}
