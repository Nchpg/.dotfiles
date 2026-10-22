package main

import (
	"context"
	"net/http"
	"regexp"
	"sort"
	"strings"
)

// Ajouter un site : choisir un dépôt parmi ceux qui publient des images sur ghcr (le jeton
// read:packages suffit, sans connexion GitHub), puis le même formulaire que l'éditeur.

type RepoOpt struct {
	FullName string
	Images   []string
	Private  bool
	Live     string // site qui sert déjà ces images
}

func (s *Server) repos(ctx context.Context, snap *Snapshot) ([]RepoOpt, error) {
	pkgs, err := s.gh.Packages(ctx)
	if err != nil {
		return nil, err
	}
	used := map[string]string{}
	for _, name := range snap.Apps.Names() {
		for _, c := range snap.Apps.Entries[name].Containers {
			img, _ := splitImage(c.Image)
			used[img] = name
		}
	}
	byRepo := map[string]*RepoOpt{}
	for _, p := range pkgs {
		if p.Repository == nil {
			continue
		}
		r := byRepo[p.Repository.FullName]
		if r == nil {
			r = &RepoOpt{FullName: p.Repository.FullName, Private: p.Repository.Private || p.Visibility == "private"}
			byRepo[p.Repository.FullName] = r
		}
		r.Images = append(r.Images, p.Name)
		if site, ok := used[p.Name]; ok {
			r.Live = site
		}
	}
	out := make([]RepoOpt, 0, len(byRepo))
	for _, r := range byRepo {
		sort.Strings(r.Images)
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool {
		if (out[i].Live == "") != (out[j].Live == "") {
			return out[i].Live == ""
		}
		return strings.ToLower(out[i].FullName) < strings.ToLower(out[j].FullName)
	})
	return out, nil
}

func (s *Server) newSite(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	repos, err := s.repos(ctx, snap)
	data := map[string]any{"Nav": "sites", "Repos": repos}
	if err != nil {
		data["Error"] = "Liste des packages ghcr illisible : " + err.Error()
	}
	s.render(w, "new", data)
}

var reNonName = regexp.MustCompile(`[^a-z0-9-]+`)

// defaultName : nom de site tiré du dépôt, dans les 12 caractères permis.
func defaultName(repo string) string {
	_, n, _ := strings.Cut(repo, "/")
	n = strings.Trim(reNonName.ReplaceAllString(strings.ToLower(n), "-"), "-")
	if len(n) > 12 {
		n = strings.TrimRight(n[:12], "-")
	}
	if n == "" {
		n = "site"
	}
	return n
}

// containerName : `rlkart-frontend` dans le dépôt RLkart -> `frontend` ; une seule image -> `web`.
func containerName(repo, image string, single bool) string {
	if single {
		return "web"
	}
	_, n, _ := strings.Cut(repo, "/")
	n = strings.ToLower(n)
	if rest, ok := strings.CutPrefix(image, n+"-"); ok && reContainer.MatchString(rest) {
		return rest
	}
	c := reNonName.ReplaceAllString(image, "-")
	if len(c) > 16 {
		c = c[:16]
	}
	return strings.Trim(c, "-")
}

func (s *Server) newSiteForm(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	repo := r.URL.Query().Get("repo")
	snap, err := s.snapshot(ctx)
	if err != nil {
		s.renderError(w, err)
		return
	}
	images := s.repoImages(ctx, repo)
	if len(images) == 0 {
		s.render(w, "newform", map[string]any{"Error": "Ce dépôt n'a pas d'image sur ghcr : ajoute-lui le workflow du template, puis reviens."})
		return
	}
	e := Entry{Containers: map[string]Container{}}
	var notes []string
	for _, img := range images {
		info, err := s.reg.Inspect(ctx, s.cfg.ref(img+":main"))
		cn := containerName(repo, img, len(images) == 1)
		e.Containers[cn] = Container{Image: img + ":main"}
		switch {
		case err != nil:
			notes = append(notes, img+" : pas de tag main lisible ("+err.Error()+").")
		case info.Port == nil && len(images) == 1:
			notes = append(notes, img+" : l'image n'expose pas un port unique.")
		case info.Port != nil && (e.Entrypoint == "" || cn == "frontend" || cn == "web"):
			e.Entrypoint = cn
		}
	}
	if len(e.Containers) == 1 {
		e.Entrypoint = ""
	}
	name := defaultName(repo)
	f := s.formVM(ctx, name, e, true, repo, images, snap)
	f.Preview = s.previewOf(name, &e, snap, true, "", validate(s.cfg, name, e, snap.Apps.Entries))
	s.render(w, "newform", map[string]any{"F": f, "Notes": notes})
}
