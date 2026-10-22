package main

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Favicons : l'icône que chaque site déclare, lue par think et gardée une heure. Sans icône, la
// page garde l'initiale du site.
type Favicons struct {
	http *http.Client
	mu   sync.Mutex
	m    map[string]favicon
}

type favicon struct {
	at   time.Time
	typ  string
	body []byte
}

func newFavicons() *Favicons {
	return &Favicons{http: &http.Client{Timeout: 6 * time.Second}, m: map[string]favicon{}}
}

var reIconLink = regexp.MustCompile(`(?is)<link\b[^>]*\brel\s*=\s*["'][^"']*\bicon\b[^"']*["'][^>]*>`)
var reHref = regexp.MustCompile(`(?is)\bhref\s*=\s*["']([^"']+)["']`)

func (f *Favicons) fetch(ctx context.Context, u string, limit int64) (string, []byte, bool) {
	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return "", nil, false
	}
	resp, err := f.http.Do(req)
	if err != nil {
		return "", nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", nil, false
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	return resp.Header.Get("Content-Type"), b, err == nil
}

func (f *Favicons) get(ctx context.Context, domain string) favicon {
	f.mu.Lock()
	if v, ok := f.m[domain]; ok && time.Since(v.at) < time.Hour {
		f.mu.Unlock()
		return v
	}
	f.mu.Unlock()
	base := "https://" + domain + "/"
	icon := ""
	if _, page, ok := f.fetch(ctx, base, 512<<10); ok {
		if link := reIconLink.Find(page); link != nil {
			if m := reHref.FindSubmatch(link); m != nil {
				if u, err := url.Parse(string(m[1])); err == nil {
					if b, err := url.Parse(base); err == nil {
						icon = b.ResolveReference(u).String()
					}
				}
			}
		}
	}
	if icon == "" {
		icon = base + "favicon.ico"
	}
	v := favicon{at: time.Now()}
	if typ, body, ok := f.fetch(ctx, icon, 256<<10); ok && strings.HasPrefix(typ, "image/") && !strings.Contains(typ, "svg") {
		v.typ, v.body = typ, body
	}
	f.mu.Lock()
	f.m[domain] = v
	f.mu.Unlock()
	return v
}

func (s *Server) favicon(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	snap, err := s.snapshot(ctx)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	e, ok := snap.Apps.Entries[r.PathValue("app")]
	if !ok {
		http.NotFound(w, r)
		return
	}
	v := s.fav.get(ctx, domainOf(r.PathValue("app"), e, s.cfg.Domain))
	if v.body == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", v.typ)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	_, _ = w.Write(v.body)
}
