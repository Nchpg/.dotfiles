package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// Page Authelia : les comptes (résumé d'admin-accounts) et leurs accès. Services de think dans
// authelia-accounts.json, sites avec Authelia par leur liste `accounts` d'apps.json, toujours
// nommée : un compte créé plus tard n'entre nulle part seul. Écrits par apps.yml (`account`), en un
// commit qu'apps-deploy applique seul.

// AutheliaInfo : registre des services derrière le portail et ce que la génération active ouvre à
// chaque compte (cf. `autheliaInfo`, ../default.nix).
type AutheliaInfo struct {
	Services []VPNService        `json:"services"`
	Accounts map[string][]string `json:"accounts"`
}

const autheliaAccountsPath = "profiles/server/authelia-accounts.json"

var reAccount = regexp.MustCompile(`^[A-Za-z0-9._@-]{1,64}$`)

// validateAccounts : la liste `accounts` d'une section accès (`w` : préfixe d'un environnement).
func validateAccounts(w string, sso bool, accounts []string) []string {
	msg := func(m string) []string {
		if w == "" {
			return []string{strings.ToUpper(m[:1]) + m[1:]}
		}
		return []string{w + m}
	}
	if !sso {
		if accounts != nil {
			return msg("comptes Authelia : seulement avec la connexion Authelia.")
		}
		return nil
	}
	if len(accounts) == 0 {
		return msg("connexion Authelia : coche au moins un compte.")
	}
	for _, a := range accounts {
		if !reAccount.MatchString(a) {
			return msg("compte Authelia invalide : " + a + ".")
		}
	}
	return nil
}

// readAccounts : le résumé des comptes écrit par admin-accounts (root, toutes les 5 minutes).
func (s *Server) readAccounts() ([]Account, error) {
	var list []Account
	b, err := os.ReadFile(s.cfg.AccountsFile)
	if err == nil {
		err = json.Unmarshal(b, &list)
	}
	return list, err
}

// accountChoices : les comptes à proposer, ceux du résumé et ceux déjà nommés (`extra`), triés.
func (s *Server) accountChoices(extra []string) []string {
	var out []string
	list, _ := s.readAccounts()
	for _, a := range list {
		out = append(out, a.Name)
	}
	for n := range s.cfg.Authelia.Accounts {
		out = append(out, n)
	}
	out = append(out, extra...)
	sort.Strings(out)
	return slices.Compact(out)
}

// accountsFromForm : les comptes cochés parmi ceux proposés ; aucun : liste vide, que la validation refuse.
func accountsFromForm(checked, choices []string) []string {
	out := []string{}
	for _, a := range choices {
		if slices.Contains(checked, a) {
			out = append(out, a)
		}
	}
	return out
}

// accountServices : services de chaque compte sur main (repli : la génération active).
func (s *Server) accountServices(ctx context.Context) map[string][]string {
	if head, err := s.gh.HeadCached(ctx); err == nil {
		if b, err := s.gh.File(ctx, head, autheliaAccountsPath); err == nil {
			var file map[string]struct {
				Services []string `json:"services"`
			}
			if json.Unmarshal(b, &file) == nil {
				out := map[string][]string{}
				for n, a := range file {
					out[n] = a.Services
				}
				return out
			}
		}
	}
	return s.cfg.Authelia.Accounts
}

// ssoSites : les sites (et environnements) avec Authelia sur main, et si le compte y entre.
func (s *Server) ssoSites(ctx context.Context, account string) ([]AccessSite, error) {
	snap, err := s.snapshot(ctx)
	if err != nil {
		return nil, err
	}
	var out []AccessSite
	for _, site := range snap.Apps.Names() {
		e := snap.Apps.Entries[site]
		for _, d := range e.Deploys(site) {
			if !d.Access.SSO {
				continue
			}
			a := AccessSite{Site: site, Env: d.ID, App: d.App, Domain: d.Domain(s.cfg.Domain), On: slices.Contains(d.Access.Accounts, account)}
			if d.ID != "" && !e.Environments[d.ID].OwnAccess() {
				a.Inherited, a.From = true, e.labelOf(e.Environments[d.ID].From)
			}
			out = append(out, a)
		}
	}
	return out, nil
}

// AccountRow : un compte, sa dernière connexion lisible et ses accès.
type AccountRow struct {
	Account
	Last            string
	Services, Sites []string
}

func (s *Server) accounts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	data := map[string]any{"Nav": "accounts", "Error": r.URL.Query().Get("erreur")}
	list, err := s.readAccounts()
	if err != nil {
		data["Error"] = "Résumé des comptes pas encore produit (service admin-accounts, toutes les 5 minutes)."
	}
	if st, e := os.Stat(s.cfg.AccountsFile); e == nil {
		data["Updated"] = ago(time.Since(st.ModTime()))
	}
	services := s.accountServices(ctx)
	sitesOf := map[string][]string{}
	if snap, err := s.snapshot(ctx); err == nil {
		for _, site := range snap.Apps.Names() {
			for _, d := range snap.Apps.Entries[site].Deploys(site) {
				if !d.Access.SSO {
					continue
				}
				for _, a := range d.Access.Accounts {
					sitesOf[a] = append(sitesOf[a], d.App)
				}
			}
		}
	}
	var rows []AccountRow
	for _, a := range list {
		row := AccountRow{Account: a, Last: "jamais", Services: services[a.Name], Sites: sitesOf[a.Name]}
		if a.LastLogin != nil {
			if t, ok := parseSQLiteTime(*a.LastLogin); ok {
				row.Last = ago(time.Since(t))
			}
		}
		rows = append(rows, row)
	}
	data["Rows"] = rows
	s.render(w, "accounts", data)
}

// knownAccount : un compte du résumé (ou déjà nommé dans authelia-accounts.json).
func (s *Server) knownAccount(ctx context.Context, name string) bool {
	if !reAccount.MatchString(name) {
		return false
	}
	_, named := s.accountServices(ctx)[name]
	return named || slices.Contains(s.accountChoices(nil), name)
}

func (s *Server) accountAccess(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := r.PathValue("name")
	if !s.knownAccount(ctx, name) {
		http.NotFound(w, r)
		return
	}
	sites, err := s.ssoSites(ctx, name)
	checked := map[string]bool{}
	for _, sv := range s.accountServices(ctx)[name] {
		checked[sv] = true
	}
	s.render(w, "account-access", map[string]any{"Nav": "accounts", "Name": name, "Services": s.cfg.Authelia.Services,
		"Checked": checked, "Sites": sites, "Error": errString(err), "Self": name == r.Header.Get("Remote-User")})
}

// accountAccessSave : services et sites cochés, en un commit (apps.yml, action `account`).
func (s *Server) accountAccessSave(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := r.PathValue("name")
	if !s.knownAccount(ctx, name) {
		http.NotFound(w, r)
		return
	}
	back := func(msg string) {
		http.Redirect(w, r, "/accounts?erreur="+url.QueryEscape(msg), http.StatusSeeOther)
	}
	_ = r.ParseForm()
	services := []string{}
	for _, sv := range s.cfg.Authelia.Services {
		if slices.Contains(r.Form["service"], sv.Name) {
			services = append(services, sv.Name)
		}
	}
	before := s.accountServices(ctx)
	if slices.Contains(before[name], "admin") && !slices.Contains(services, "admin") {
		if name == r.Header.Get("Remote-User") {
			back("Tu es connecté avec " + name + " : lui retirer le dashboard te fermerait la page. Fais-le avec un autre compte.")
			return
		}
	}
	sites, err := s.ssoSites(ctx, name)
	if err != nil {
		back("Sites illisibles : " + err.Error())
		return
	}
	changes := []siteAccess{}
	for _, a := range sites {
		on := slices.Contains(r.Form["site"], a.App)
		if !a.Inherited && on != a.On {
			changes = append(changes, siteAccess{a.Site, a.Env, on})
		}
	}
	entry, _ := json.Marshal(map[string]any{"services": services, "sites": changes})
	if err := s.gh.Dispatch(ctx, map[string]string{"action": "account", "app": name, "entry": string(entry), "source": "dashboard"}); err != nil {
		back("Changement impossible (apps.yml) : " + err.Error())
		return
	}
	back(name + " : accès enregistrés (commit dans la minute), appliqués seuls ensuite, sauf si un rebuild est déjà en attente.")
}
