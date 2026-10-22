package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Une demande « Appliquer » suivie de bout en bout : config vérifiée, commit sur main par
// apps.yml, appliqué par think (apps-deploy), site qui répond. Chaque étape est constatée,
// jamais supposée.

type Step struct {
	Label  string
	Sub    string
	State  string // todo, active, done, failed
	Detail string
	Link   string
}

type Job struct {
	mu      sync.Mutex
	ID      string
	App     string
	Delete  bool
	Message string
	Steps   []Step
	Done    bool
	Failed  bool
	Created time.Time
	Domain  string
}

type Jobs struct {
	mu sync.Mutex
	m  map[string]*Job
}

func (js *Jobs) get(id string) *Job {
	js.mu.Lock()
	defer js.mu.Unlock()
	return js.m[id]
}

func (js *Jobs) add(j *Job) {
	js.mu.Lock()
	defer js.mu.Unlock()
	for id, old := range js.m {
		if time.Since(old.Created) > 2*time.Hour {
			delete(js.m, id)
		}
	}
	js.m[j.ID] = j
}

// Snapshot : copie lisible par un template sans tenir le verrou.
func (j *Job) Snapshot() Job {
	j.mu.Lock()
	defer j.mu.Unlock()
	return Job{ID: j.ID, App: j.App, Delete: j.Delete, Message: j.Message, Steps: append([]Step(nil), j.Steps...), Done: j.Done, Failed: j.Failed, Domain: j.Domain}
}

func (j *Job) set(i int, state, detail, link string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.Steps[i].State, j.Steps[i].Detail = state, detail
	if link != "" {
		j.Steps[i].Link = link
	}
	if state == "failed" {
		j.Failed, j.Done = true, true
	}
}

func (j *Job) finish() {
	j.mu.Lock()
	j.Done = true
	j.mu.Unlock()
}

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Request : ce que la page a envoyé, avant toute vérification côté serveur.
type Request struct {
	App     string
	Entry   *Entry // nil : suppression
	Base    string // empreinte lue par la page
	Message string
}

func fingerprintOf(e *Entry) string {
	if e == nil {
		return "new"
	}
	b, err := entryJSON(*e)
	if err != nil {
		return ""
	}
	c, err := canonical(b)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256([]byte(c))
	return hex.EncodeToString(sum[:])
}

type lockEntry struct {
	Digest   string  `json:"digest"`
	Port     *int    `json:"port"`
	Revision *string `json:"revision"`
}

type imageInput struct {
	Ref      string  `json:"ref"`
	Digest   string  `json:"digest"`
	Port     *int    `json:"port"`
	Revision *string `json:"revision"`
}

var reRevision = regexp.MustCompile(`^[0-9a-f]{7,40}$`)

// candidate : apps.json et lock tels qu'apps.sh les écrira, plus les digests des nouvelles images.
func (s *Server) candidate(ctx context.Context, apps *AppsFile, lockRaw []byte, req Request) (appsOut, lockOut []byte, images []imageInput, err error) {
	appsOut, err = apps.WithEntry(req.App, req.Entry)
	if err != nil {
		return nil, nil, nil, err
	}
	next, err := parseApps(appsOut)
	if err != nil {
		return nil, nil, nil, err
	}
	lock := map[string]json.RawMessage{}
	if err := json.Unmarshal(lockRaw, &lock); err != nil {
		return nil, nil, nil, fmt.Errorf("lock illisible : %w", err)
	}
	used := map[string]bool{}
	for _, e := range next.Entries {
		for _, c := range e.Containers {
			used[s.cfg.ref(c.Image)] = true
		}
	}
	refs := make([]string, 0, len(used))
	for r := range used {
		refs = append(refs, r)
	}
	sort.Strings(refs)
	for _, ref := range refs {
		if _, ok := lock[ref]; ok {
			continue
		}
		info, err := s.reg.Inspect(ctx, ref)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("image %s illisible sur le registre : %w", ref, err)
		}
		in := imageInput{Ref: ref, Digest: info.Digest, Port: info.Port}
		if reRevision.MatchString(info.Revision) {
			rev := info.Revision
			in.Revision = &rev
		}
		images = append(images, in)
		b, _ := json.Marshal(lockEntry{Digest: in.Digest, Port: in.Port, Revision: in.Revision})
		lock[ref] = b
	}
	for ref := range lock {
		if !used[ref] {
			delete(lock, ref)
		}
	}
	out := map[string]any{}
	for k, v := range lock {
		var x any
		_ = json.Unmarshal(v, &x)
		out[k] = x
	}
	lockOut, err = marshal(out, true)
	return appsOut, append(lockOut, '\n'), images, err
}

func (s *Server) startJob(req Request, domain string) *Job {
	j := &Job{ID: newID(), App: req.App, Delete: req.Entry == nil, Message: req.Message, Created: time.Now(), Domain: domain}
	j.Steps = []Step{
		{Label: "Config vérifiée", Sub: "évaluation sur think", State: "active"},
		{Label: "Commit sur main", Sub: "apps.yml", State: "todo"},
		{Label: "think applique", Sub: "apps-deploy, sans rebuild", State: "todo"},
		{Label: "Le site répond", Sub: domain, State: "todo"},
	}
	if j.Delete {
		j.Steps[3] = Step{Label: "Le site est retiré", Sub: domain, State: "todo"}
	}
	s.jobs.add(j)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		if err := s.runJob(ctx, j, req); err != nil {
			log.Printf("%s : %v", req.App, err)
		}
	}()
	return j
}

func (s *Server) runJob(ctx context.Context, j *Job, req Request) error {
	want := fingerprintOf(req.Entry)

	// 1. Évaluation, sur la tête actuelle de main.
	head, err := s.gh.Head(ctx)
	if err != nil {
		j.set(0, "failed", err.Error(), "")
		return err
	}
	appsRaw, err1 := s.gh.File(ctx, head, appsPath)
	lockRaw, err2 := s.gh.File(ctx, head, lockPath)
	if err := errors.Join(err1, err2); err != nil {
		j.set(0, "failed", err.Error(), "")
		return err
	}
	apps, err := parseApps(appsRaw)
	if err != nil {
		j.set(0, "failed", err.Error(), "")
		return err
	}
	if got := apps.Fingerprint(req.App); got != req.Base {
		j.set(0, "failed", req.App+" a changé sur main depuis l'ouverture de la page. Recharge-la : tes réglages sont à refaire sur la nouvelle version.", "")
		return errors.New("conflit")
	}
	candApps, candLock, images, err := s.candidate(ctx, apps, lockRaw, req)
	if err != nil {
		j.set(0, "failed", err.Error(), "")
		return err
	}
	if err := s.eval.Check(ctx, head, candApps, candLock); err != nil {
		j.set(0, "failed", err.Error(), "")
		return err
	}
	j.set(0, "done", "", "")

	// 2. Demande à apps.yml, puis attente du commit sur main.
	j.set(1, "active", "", "")
	entry := "null"
	if req.Entry != nil {
		b, _ := entryJSON(*req.Entry)
		entry = string(b)
	}
	imagesJSON, _ := json.Marshal(images)
	if images == nil {
		imagesJSON = []byte("[]")
	}
	t0 := time.Now().Add(-10 * time.Second)
	if err := s.gh.Dispatch(ctx, map[string]string{
		"action": "edit", "app": req.App, "entry": entry, "base": req.Base,
		"images": string(imagesJSON), "message": req.Message, "source": "dashboard",
	}); err != nil {
		j.set(1, "failed", err.Error(), "")
		return err
	}
	commit, err := s.waitCommit(ctx, j, req.App, want, head, t0)
	if err != nil {
		return err
	}
	j.set(1, "done", "commit "+commit[:7], "https://github.com/"+s.cfg.Repo+"/commit/"+commit)

	// 3. think applique (apps-deploy, chaque minute).
	j.set(2, "active", "", "")
	if err := s.waitDeployed(ctx, j, req.App, want); err != nil {
		return err
	}
	j.set(2, "done", "", "")

	// 4. Le site répond (ou ne répond plus, s'il est supprimé).
	j.set(3, "active", "", "")
	port, probe := hostPort(req.App), "/"
	if req.Entry != nil && req.Entry.Probe != "" {
		probe = req.Entry.Probe
	}
	deadline := time.Now().Add(3 * time.Minute)
	for {
		code, ok := answers(ctx, port, probe)
		if req.Entry == nil && code == 0 {
			j.set(3, "done", "", "")
			break
		}
		if req.Entry != nil && ok {
			j.set(3, "done", fmt.Sprintf("HTTP %d", code), "")
			break
		}
		if time.Now().After(deadline) {
			if req.Entry == nil {
				j.set(3, "failed", "le port répond encore après 3 minutes", "")
			} else {
				j.set(3, "failed", fmt.Sprintf("pas de réponse correcte après 3 minutes (HTTP %d) : journalctl -u podman-%s-%s", code, req.App, req.Entry.EntryPoint()), "")
			}
			return errors.New("site")
		}
		if !sleep(ctx, 5*time.Second) {
			return ctx.Err()
		}
	}
	j.finish()
	return nil
}

func sleep(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}

// waitCommit : le premier commit de main où l'entrée est celle demandée ; échec si apps.yml a refusé.
func (s *Server) waitCommit(ctx context.Context, j *Job, app, want, start string, t0 time.Time) (string, error) {
	deadline := time.Now().Add(5 * time.Minute)
	last := start
	for {
		if !sleep(ctx, 4*time.Second) {
			return "", ctx.Err()
		}
		if head, err := s.gh.Head(ctx); err == nil && head != last {
			last = head
			if b, err := s.gh.File(ctx, head, appsPath); err == nil {
				if f, err := parseApps(b); err == nil && f.Fingerprint(app) == want {
					return head, nil
				}
			}
		}
		if runs, err := s.gh.Runs(ctx); err == nil {
			for _, r := range runs {
				if r.CreatedAt.Before(t0) || r.Status != "completed" || r.Conclusion == "success" {
					continue
				}
				j.set(1, "failed", "apps.yml a refusé la demande ("+r.Conclusion+") : le détail est dans le run.", r.HTMLURL)
				return "", errors.New("apps.yml")
			}
		}
		if time.Now().After(deadline) {
			j.set(1, "failed", "aucun commit après 5 minutes (GitHub Actions en retard ?)", "https://github.com/"+s.cfg.Repo+"/actions/workflows/apps.yml")
			return "", errors.New("délai")
		}
	}
}

// waitDeployed : la génération active contient l'entrée demandée ; sinon, pourquoi think attend.
func (s *Server) waitDeployed(ctx context.Context, j *Job, app, want string) error {
	deadline := time.Now().Add(10 * time.Minute)
	reasons := map[string]string{
		"local":      "think tourne une version locale non commitée : il n'applique rien seul. `rebuild` à la main.",
		"non_pousse": "think tourne des commits pas encore poussés : `git push`, puis `rebuild`.",
		"diverge":    "main n'est plus dans la lignée de la version de think : `rebuild` à la main.",
		"attente":    "main contient aussi d'autres changements que des sites : `rebuild` à la main pour tout appliquer.",
	}
	for {
		if rev := deployedRevision(ctx); rev != "" && !strings.HasSuffix(rev, "-dirty") {
			if b, err := s.gh.File(ctx, rev, appsPath); err == nil {
				if f, err := parseApps(b); err == nil && f.Fingerprint(app) == want {
					return nil
				}
			}
		}
		// Une décision ne compte que si apps-deploy a vu la tête actuelle de main (qui contient le commit).
		head, _ := s.gh.Head(ctx)
		if st, err := readDeployStatus(s.cfg.DeployStatus); err == nil && st.Fresh() && head != "" && st.Head == head {
			if msg, ok := reasons[st.State]; ok {
				j.set(2, "failed", msg, "")
				return errors.New(st.State)
			}
			if st.State == "echec" || (st.State == "deploiement" && deployFailed(ctx)) {
				j.set(2, "failed", "le build a échoué sur think : journalctl -u apps-deploy. La version d'avant tourne toujours.", "")
				return errors.New("echec")
			}
		}
		if time.Now().After(deadline) {
			j.set(2, "failed", "pas appliqué après 10 minutes : systemctl status apps-deploy", "")
			return errors.New("délai")
		}
		if !sleep(ctx, 5*time.Second) {
			return ctx.Err()
		}
	}
}
