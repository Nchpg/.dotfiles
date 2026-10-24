package main

import (
	"context"
	"net/http"
	"sort"
	"sync"
	"time"
)

// Suivi d'une demande à apps.yml (appareil VPN, accès, compte, clé SSH) : le run GitHub qu'elle a
// lancé est retrouvé, puis suivi jusqu'au commit sur main. La page affiche un voyant (orange : en
// cours, vert : commité, rouge : refusé) que htmx rafraîchit.

type Track struct {
	ID, Label string
	Next      string // ce qui reste à faire une fois commité
	State     string // running, done, failed
	Detail    string
	Link      string
	SHA       string
	t0        time.Time
	run       int64
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
func (s *Server) dispatch(ctx context.Context, inputs map[string]string, label, next string) (string, error) {
	t0 := time.Now()
	if err := s.gh.Dispatch(ctx, inputs); err != nil {
		return "", err
	}
	t := &Track{ID: newID(), Label: label, Next: next, State: "running", t0: t0}
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
			sha := ""
			if head, err := s.gh.Head(ctx); err == nil && len(head) >= 7 {
				sha = head[:7]
			}
			t.set("done", "", "https://github.com/"+s.cfg.Repo+"/commit/"+sha, sha)
			return
		}
	}
	t.set("failed", "pas de fin de run après 8 minutes (GitHub Actions en retard ?)", actions, "")
}

// trackFragment : le voyant seul, rafraîchi par htmx tant que la demande court.
func (s *Server) trackFragment(w http.ResponseWriter, r *http.Request) {
	t := trackOf(r.PathValue("id"))
	if t == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.render(w, "track", t)
}

// tracked : retour sur une page de liste, avec le voyant de la demande.
func tracked(w http.ResponseWriter, r *http.Request, page, id string) {
	http.Redirect(w, r, page+"?suivi="+id, http.StatusSeeOther)
}
