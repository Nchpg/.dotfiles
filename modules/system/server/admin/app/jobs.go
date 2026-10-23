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
	mu       sync.Mutex
	ID       string
	App      string
	Delete   bool
	Message  string
	Steps    []Step
	Done     bool
	Failed   bool
	Created  time.Time
	Finished time.Time
	Domain   string
	New      bool // site ajouté : absent d'apps.json tant que le commit n'est pas fait
}

type Jobs struct {
	mu       sync.Mutex
	m        map[string]*Job
	verified map[string]time.Time // domaine → dernière réponse vue par une demande (étape 4)
}

// markVerified : la demande vient de voir ce domaine répondre.
func (js *Jobs) markVerified(domain string) {
	js.mu.Lock()
	defer js.mu.Unlock()
	if js.verified == nil {
		js.verified = map[string]time.Time{}
	}
	js.verified[domain] = time.Now()
}

// recentlyVerified : domaines vus répondre par une demande depuis moins de `d`.
func (js *Jobs) recentlyVerified(d time.Duration) []string {
	js.mu.Lock()
	defer js.mu.Unlock()
	var out []string
	for dom, t := range js.verified {
		if time.Since(t) < d {
			out = append(out, dom)
		}
	}
	return out
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

// JobView : copie d'une demande, lisible sans verrou (templates, badges).
type JobView struct {
	ID, App, Message, Domain  string
	Delete, New, Done, Failed bool
	Steps                     []Step
	Created, Finished         time.Time
}

// Snapshot : copie lisible par un template sans tenir le verrou.
func (j *Job) Snapshot() JobView {
	j.mu.Lock()
	defer j.mu.Unlock()
	return JobView{ID: j.ID, App: j.App, Delete: j.Delete, Message: j.Message, Steps: append([]Step(nil), j.Steps...), Done: j.Done, Failed: j.Failed, Domain: j.Domain, New: j.New, Created: j.Created, Finished: j.Finished}
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
		j.Finished = time.Now()
	}
}

func (j *Job) finish() {
	j.mu.Lock()
	j.Done = true
	j.Finished = time.Now()
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
	Old     *Entry // entrée lue sur main (nil : nouveau site)
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
	// Images de chaque déploiement : la racine et les environnements (tag de leur branche ou figé).
	used := map[string]bool{}
	for name, e := range next.Entries {
		for _, d := range e.Deploys(name) {
			for _, c := range d.Ctrs.Containers {
				used[s.cfg.ref(c.Image)] = true
			}
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

// Target : un déploiement que le commit change, à voir répondre (ou disparaître).
type Target struct {
	App, Domain, Probe, Entry string
	Port, Code                int
	Remove                    bool
}

// targets : déploiements ajoutés, changés (héritiers compris) ou retirés par la demande.
func (req Request) targets(base string) []Target {
	sig := func(d Deploy) string { b, _ := json.Marshal(d); return string(b) }
	old := map[string]Deploy{}
	if req.Old != nil {
		for _, d := range req.Old.Deploys(req.App) {
			old[d.App] = d
		}
	}
	var out []Target
	seen := map[string]bool{}
	if req.Entry != nil {
		for _, d := range req.Entry.Deploys(req.App) {
			seen[d.App] = true
			if o, ok := old[d.App]; ok && sig(o) == sig(d) {
				continue
			}
			probe := d.Options.Probe
			if probe == "" {
				probe = "/"
			}
			out = append(out, Target{App: d.App, Domain: d.Domain(base), Probe: probe, Entry: d.EntryPoint(), Port: hostPort(d.App)})
		}
	}
	for app, d := range old {
		if !seen[app] {
			out = append(out, Target{App: app, Domain: d.Domain(base), Probe: "/", Port: hostPort(app), Remove: true})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].App < out[j].App })
	return out
}

func (s *Server) startJob(req Request) *Job {
	targets := req.targets(s.cfg.Domain)
	domain := ""
	var doms []string
	for _, t := range targets {
		doms = append(doms, t.Domain)
	}
	if req.Entry != nil {
		if d, err := req.Entry.Deploy(req.App, ""); err == nil {
			domain = d.Domain(s.cfg.Domain)
		}
	} else if len(doms) > 0 {
		domain = doms[0]
	}
	j := &Job{ID: newID(), App: req.App, Delete: req.Entry == nil, Message: req.Message, Created: time.Now(), Domain: domain, New: req.Base == "new"}
	last := Step{Label: "Le site répond", Sub: strings.Join(doms, ", "), State: "todo"}
	switch {
	case j.Delete:
		last.Label = "Le site est retiré"
	case len(targets) > 1:
		last.Label = fmt.Sprintf("Les %d adresses répondent", len(targets))
	case len(targets) == 0:
		last.Sub = "rien à relancer"
	}
	j.Steps = []Step{
		{Label: "Config vérifiée", Sub: "évaluation sur think", State: "active"},
		{Label: "Commit sur main", Sub: "apps.yml", State: "todo"},
		{Label: "think applique", Sub: "apps-deploy, dans la minute", State: "todo"},
		last,
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

	// 4. Les déploiements touchés répondent (ou ne répondent plus, s'ils sont retirés).
	j.set(3, "active", "", "")
	deadline := time.Now().Add(3 * time.Minute)
	pending := append([]Target(nil), req.targets(s.cfg.Domain)...)
	var answered []string
	for len(pending) > 0 {
		var still []Target
		for _, t := range pending {
			code, ok := answers(ctx, t.Port, t.Probe)
			switch {
			case t.Remove && code == 0:
				answered = append(answered, t.Domain+" retiré")
			case !t.Remove && ok:
				s.jobs.markVerified(t.Domain)
				answered = append(answered, fmt.Sprintf("%s · HTTP %d", t.Domain, code))
			default:
				t.Code = code
				still = append(still, t)
			}
		}
		pending = still
		if len(pending) == 0 {
			break
		}
		if time.Now().After(deadline) {
			var why []string
			for _, t := range pending {
				if t.Remove {
					why = append(why, t.Domain+" répond encore")
				} else {
					why = append(why, fmt.Sprintf("%s : pas de réponse correcte (HTTP %d), journalctl -u podman-%s-%s", t.Domain, t.Code, t.App, t.Entry))
				}
			}
			j.set(3, "failed", strings.Join(why, "\n")+"\n(après 3 minutes)", "")
			return errors.New("site")
		}
		if !sleep(ctx, 5*time.Second) {
			return ctx.Err()
		}
	}
	j.set(3, "done", strings.Join(answered, "\n"), "")
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
// Un `rebuild` à faire à la main n'est pas un échec : l'étape attend (2 h au plus) et repart seule
// dès que think tourne une version qui contient l'entrée.
func (s *Server) waitDeployed(ctx context.Context, j *Job, app, want string) error {
	deadline := time.Now().Add(10 * time.Minute)
	manual := time.Now().Add(2 * time.Hour)
	blocked := ""
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
				if msg != blocked {
					j.set(2, "active", msg, "")
					blocked = msg
				}
			} else if blocked != "" {
				j.set(2, "active", "", "")
				blocked = ""
			}
			if st.State == "echec" || (st.State == "deploiement" && deployFailed(ctx)) {
				j.set(2, "failed", "le build a échoué sur think : journalctl -u apps-deploy. La version d'avant tourne toujours.", "")
				return errors.New("echec")
			}
		}
		if blocked != "" && time.Now().After(manual) {
			j.set(2, "failed", blocked+"\n(toujours pas fait après 2 heures)", "")
			return errors.New("rebuild")
		}
		if blocked == "" && time.Now().After(deadline) {
			j.set(2, "failed", "pas appliqué après 10 minutes : systemctl status apps-deploy", "")
			return errors.New("délai")
		}
		if !sleep(ctx, 5*time.Second) {
			return ctx.Err()
		}
	}
}

// JobBadge : la dernière demande d'un site, résumée pour la liste et la page du site.
type JobBadge struct {
	ID, App string
	Kind    string // running, done, failed
	Label   string
	Detail  string
	New     bool
	Delete  bool
}

// latest : la demande la plus récente d'un site, quelle qu'elle soit.
func (js *Jobs) latest(app string) *Job {
	js.mu.Lock()
	defer js.mu.Unlock()
	var last *Job
	for _, j := range js.m {
		if j.App == app && (last == nil || j.Created.After(last.Created)) {
			last = j
		}
	}
	return last
}

// all : copie de toutes les demandes connues.
func (js *Jobs) all() []JobView {
	js.mu.Lock()
	defer js.mu.Unlock()
	out := make([]JobView, 0, len(js.m))
	for _, j := range js.m {
		out = append(out, j.Snapshot())
	}
	return out
}

// badgeOf : en cours, ou terminée depuis peu (réussite 5 min, échec 30 min) ; nil sinon.
func badgeOf(j JobView) *JobBadge {
	b := &JobBadge{ID: j.ID, App: j.App, New: j.New, Delete: j.Delete}
	switch {
	case !j.Done:
		n := 1
		for i, s := range j.Steps {
			if s.State == "active" {
				n = i + 1
				b.Detail = s.Label
				if s.Detail != "" {
					b.Detail = s.Detail // en attente : ce qu'il reste à faire
				}
			}
		}
		b.Kind, b.Label = "running", fmt.Sprintf("en cours · %d/%d", n, len(j.Steps))
	case j.Failed && time.Since(j.Finished) < 30*time.Minute:
		b.Kind, b.Label = "failed", "échec"
		for _, s := range j.Steps {
			if s.State == "failed" {
				b.Detail = s.Label + " : " + s.Detail
			}
		}
	case !j.Failed && time.Since(j.Finished) < 5*time.Minute:
		b.Kind, b.Label = "done", "appliqué"
		if j.Delete {
			b.Label = "supprimé"
		} else if j.New {
			b.Label = "en ligne"
		}
	default:
		return nil
	}
	return b
}
