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
	request   bool // le run porte l'identifiant de la demande (run-name d'apps.yml)
	committed time.Time
}

var tracks = struct {
	sync.Mutex
	m       map[string]*Track
	claimed map[int64]time.Time // runs déjà attribués à une demande (et quand)
}{m: map[string]*Track{}, claimed: map[int64]time.Time{}}

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

// dispatch : lance apps.yml et suit le run ; l'identifiant sert au voyant de la page (?suivi=) et
// nomme le run (run-name d'apps.yml), qui se retrouve ainsi parmi les autres.
// `next` vide : think l'applique seul, le voyant suit jusqu'à son application.
func (s *Server) dispatch(ctx context.Context, inputs map[string]string, label, next string) (string, error) {
	t0 := time.Now()
	id := newID()
	requested, err := s.gh.Dispatch(ctx, inputs, id)
	if err != nil {
		return "", err
	}
	t := &Track{ID: id, Label: label, Next: next, Auto: next == "", State: "running", t0: t0, request: requested}
	tracks.Lock()
	pruneTracks(t0)
	tracks.m[t.ID] = t
	tracks.Unlock()
	safeGo("suivi "+label, func() { s.follow(t) })
	return t.ID, nil
}

// claimRun : un run sans identifiant (apps.yml d'avant run-name) se retrouve à l'heure : le plus
// ancien lancé depuis `t0` (horloges de GitHub et de think : 10 s de marge), sans identifiant, et
// pas encore attribué à une autre demande ; il lui est attribué.
func claimRun(runs []Run, t0 time.Time) *Run {
	sorted := append([]Run(nil), runs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].CreatedAt.Before(sorted[j].CreatedAt) })
	tracks.Lock()
	defer tracks.Unlock()
	for i := range sorted {
		r := &sorted[i]
		if r.Request() == "" && tracks.claimed[r.ID].IsZero() && !r.CreatedAt.Before(t0.Add(-10*time.Second)) {
			tracks.claimed[r.ID] = time.Now()
			return r
		}
	}
	return nil
}

// runByID : le run `id` parmi `runs` (nil s'il n'y est plus).
func runByID(runs []Run, id int64) *Run {
	for i := range runs {
		if runs[i].ID == id {
			return &runs[i]
		}
	}
	return nil
}

// follow : le run d'apps.yml de la demande (par son nom, sinon à l'heure), jusqu'à sa fin.
func (s *Server) follow(t *Track) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	actions := "https://github.com/" + s.cfg.Repo + "/actions/workflows/apps.yml"
	for sleep(ctx, 3*time.Second) {
		runs, err := s.gh.Runs(ctx)
		if err != nil {
			continue
		}
		tracks.Lock()
		run, request := t.run, t.request
		tracks.Unlock()
		var r *Run
		switch {
		case request:
			r = runFor(runs, t.ID)
		case run == 0:
			r = claimRun(runs, t.t0)
		default:
			r = runByID(runs, run)
		}
		if r == nil {
			continue
		}
		tracks.Lock()
		t.run, t.Link = r.ID, r.HTMLURL
		tracks.Unlock()
		if r.Status != "completed" {
			continue
		}
		if r.Conclusion != "success" {
			t.set("failed", runFailure(*r), r.HTMLURL, "")
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
		s.wakeDeploy()
		s.followDeploy(t, head)
		return
	}
	t.set("failed", "pas de fin de run après 8 minutes (GitHub Actions en retard ?)", actions, "")
}

// followDeploy : apps-deploy a appliqué le commit (think tourne lui ou un commit après). Comme le
// suivi d'un site : son propre délai (10 minutes), qui passe à 2 heures tant que think attend une
// action à la main (rebuild, push : le voyant le dit et reste orange) ; un build en échec, rouge.
func (s *Server) followDeploy(t *Track, head string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour+10*time.Minute)
	defer cancel()
	deadline := time.Now().Add(10 * time.Minute)
	manual := time.Now().Add(2 * time.Hour)
	detail := ""
	for sleep(ctx, 3*time.Second) {
		st, err := readDeployStatus(s.cfg.DeployStatus)
		fresh := err == nil && st.Fresh() && !time.Unix(st.Checked, 0).Before(t.committed)
		if fresh {
			if st.Deployed == head || (st.State == "a_jour" && st.Head == st.Deployed) {
				t.set("done", "", t.Link, t.SHA)
				return
			}
			if st.State == "echec" || (st.State == "deploiement" && deployFailed(ctx)) {
				t.set("failed", deployBuildFailed, t.Link, t.SHA)
				return
			}
			detail = deployWaits[st.State]
			tracks.Lock()
			t.Detail = detail
			tracks.Unlock()
		}
		switch {
		case detail != "" && time.Now().After(manual):
			t.set("failed", detail+" (toujours pas fait après 2 heures)", t.Link, t.SHA)
			return
		case detail == "" && time.Now().After(deadline):
			t.set("failed", "pas appliqué après 10 minutes : voir l'état de think sur la page Sites.", t.Link, t.SHA)
			return
		}
	}
	t.set("failed", "pas appliqué : voir l'état de think sur la page Sites.", t.Link, t.SHA)
}

// trackFragment : le voyant seul, relu par htmx tant que la demande court. Inconnu : le dashboard a
// redémarré entre-temps (think a appliqué une nouvelle version qui le concerne). Sur une page de
// liste, la page est relue (app.js) ; ailleurs (page de résultat, à ne pas recharger), rien ne suit.
func (s *Server) trackFragment(w http.ResponseWriter, r *http.Request) {
	reload := r.URL.Query().Has("reload")
	t := trackOf(r.PathValue("id"))
	if t == nil {
		t = &Track{ID: r.PathValue("id"), State: "lost", Label: "Demande", Detail: "le dashboard a redémarré (nouvelle version de think) : la page est relue."}
		if !reload {
			t.Detail = "le dashboard a redémarré (nouvelle version de think) : suivi perdu. Vérifie le résultat sur la page de liste."
		}
	}
	t.Reload = reload
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

// pruneTracks : oublie les demandes de plus d'une heure (trackOf ne les rend déjà plus) et les runs
// attribués depuis aussi longtemps (claimRun n'en prend pas d'aussi anciens). À appeler verrou tenu.
func pruneTracks(now time.Time) {
	for id, t := range tracks.m {
		if now.Sub(t.t0) > time.Hour {
			delete(tracks.m, id)
		}
	}
	for id, at := range tracks.claimed {
		if now.Sub(at) > time.Hour {
			delete(tracks.claimed, id)
		}
	}
}
