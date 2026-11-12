package main

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
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
	Services    []VPNService        `json:"services"`
	Accounts    map[string][]string `json:"accounts"`
	UsersSecret string              `json:"usersSecret"` // clé sops du fichier d'utilisateurs semé
	PortalHost  string              `json:"portalHost"`
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

// readAccounts : le résumé des comptes écrit par admin-accounts (root, toutes les 30 secondes).
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

// accountServicesErr : services de chaque compte sur main ; illisible : ceux de la génération
// active, et pourquoi.
func (s *Server) accountServicesErr(ctx context.Context) (map[string][]string, error) {
	head, err := s.gh.HeadCached(ctx)
	if err != nil {
		return s.cfg.Authelia.Accounts, err
	}
	b, err := s.gh.File(ctx, head, autheliaAccountsPath)
	if err != nil {
		return s.cfg.Authelia.Accounts, err
	}
	var file map[string]struct {
		Services []string `json:"services"`
	}
	if err := json.Unmarshal(b, &file); err != nil {
		return s.cfg.Authelia.Accounts, fmt.Errorf("%s illisible : %w", autheliaAccountsPath, err)
	}
	out := map[string][]string{}
	for n, a := range file {
		out[n] = a.Services
	}
	return out, nil
}

// accountServices : accountServicesErr sans l'erreur.
func (s *Server) accountServices(ctx context.Context) map[string][]string {
	m, _ := s.accountServicesErr(ctx)
	return m
}

// ssoSites : les sites (et environnements) avec Authelia sur main, et si le compte y entre.
func (s *Server) ssoSites(ctx context.Context, account string) ([]AccessSite, error) {
	return s.deploySites(ctx, ssoDeploy, accountsOf, account)
}

// AccountRow : un compte, sa dernière connexion lisible et ses accès.
type AccountRow struct {
	Account
	Last            string
	Services, Sites []string
	Pending         bool // nommé sur main, pas encore dans le résumé (secret + rebuild à faire)
}

func (s *Server) accounts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := r.URL.Query()
	data := map[string]any{"Nav": "accounts", "Error": q.Get("erreur"), "Notice": q.Get("info"), "Track": listTrack(r)}
	list, err := s.readAccounts()
	if err != nil {
		// À part : le message d'une action échouée (?erreur=) reste visible.
		data["SummaryError"] = "Résumé des comptes pas encore produit (service admin-accounts, toutes les 30 secondes)."
	}
	if st, e := os.Stat(s.cfg.AccountsFile); e == nil {
		data["Updated"] = ago(time.Since(st.ModTime()))
	}
	services, servicesErr := s.accountServicesErr(ctx)
	sitesOf := map[string][]string{}
	snap, snapErr := s.snapshot(ctx)
	if snapErr == nil {
		sitesOf = sitesByMember(snap, ssoDeploy, accountsOf)
	}
	data["MainError"] = mainError(firstErr(servicesErr, snapErr))
	var rows []AccountRow
	inSummary := map[string]bool{}
	for _, a := range list {
		inSummary[a.Name] = true
		row := AccountRow{Account: a, Last: "jamais", Services: services[a.Name], Sites: sitesOf[a.Name]}
		if a.LastLogin != nil {
			if t, ok := parseSQLiteTime(*a.LastLogin); ok {
				row.Last = ago(time.Since(t))
			}
		}
		rows = append(rows, row)
	}
	// Comptes créés d'ici (accès sur main) que le résumé ne montre pas encore.
	if err == nil {
		for _, n := range slices.Sorted(maps.Keys(services)) {
			if !inSummary[n] {
				rows = append(rows, AccountRow{Account: Account{Name: n}, Pending: true, Services: services[n], Sites: sitesOf[n]})
			}
		}
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

const unknownAccount = "Compte inconnu : ni dans le résumé d'Authelia, ni dans " + autheliaAccountsPath + "."

// accountAccessPage : la page Accès d'un compte (cases d'après `checked` et `sites`).
func (s *Server) accountAccessPage(w http.ResponseWriter, r *http.Request, name string, checked map[string]bool, sites []AccessSite, mainErr error, msg string) {
	self := name == r.Header.Get("Remote-User")
	lock := ""
	if self && checked["admin"] {
		lock = "admin" // le dashboard ne se retire pas au compte qui s'en sert
	}
	s.render(w, "account-access", map[string]any{"Nav": "accounts", "PageTitle": name, "Name": name, "Services": s.cfg.Authelia.Services,
		"Checked": checked, "Sites": sites, "Error": msg, "MainError": mainError(mainErr), "Self": self, "Lock": lock, "Token": formToken()})
}

func (s *Server) accountAccess(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := r.PathValue("name")
	// Après une suppression (POST, puis cette adresse) : les commandes pour finir.
	if q := r.URL.Query(); q.Has("supprime") && reAccount.MatchString(name) {
		s.render(w, "account-removed", map[string]any{"Nav": "accounts", "PageTitle": name, "Name": name, "Secret": s.cfg.Authelia.UsersSecret, "Track": trackOf(q.Get("supprime"))})
		return
	}
	if !s.knownAccount(ctx, name) {
		s.notFound(w, r, "accounts", unknownAccount)
		return
	}
	sites, err := s.ssoSites(ctx, name)
	services, servicesErr := s.accountServicesErr(ctx)
	s.accountAccessPage(w, r, name, checkedOf(services[name]), sites, firstErr(err, servicesErr), "")
}

// accountAccessSave : services et sites cochés, en un commit (apps.yml, action `account`). Refusé :
// la page revient avec les cases telles qu'envoyées.
func (s *Server) accountAccessSave(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := r.PathValue("name")
	if !s.knownAccount(ctx, name) {
		s.notFound(w, r, "accounts", unknownAccount)
		return
	}
	if s.unreadableForm(w, r, "accounts") {
		return
	}
	token := r.FormValue("token")
	if id, seen := formSeen(token); seen {
		tracked(w, r, "/accounts", id)
		return
	}
	services, checked := checkedServices(r.Form["service"], s.cfg.Authelia.Services)
	before, beforeErr := s.accountServicesErr(ctx)
	sites, sitesErr := s.ssoSites(ctx, name)
	again := func(msg string) {
		s.accountAccessPage(w, r, name, checked, formSites(r, sites), firstErr(sitesErr, beforeErr), msg)
	}
	if slices.Contains(before[name], "admin") && !slices.Contains(services, "admin") && name == r.Header.Get("Remote-User") {
		again("Tu es connecté avec " + name + " : lui retirer le dashboard te fermerait la page. Fais-le avec un autre compte.")
		return
	}
	if sitesErr != nil {
		again("Sites illisibles (" + sitesErr.Error() + ") : rien n'a été changé, réessaie dans un instant.")
		return
	}
	changes := siteChanges(r.Form["site"], sites)
	if beforeErr == nil && sameSet(services, before[name]) && len(changes) == 0 {
		s.listInfo(w, r, "/accounts", "Accès de "+name+" : rien à changer.")
		return
	}
	entry, _ := json.Marshal(map[string]any{"services": services, "sites": changes})
	id, _, err := s.dispatchForm(ctx, token, map[string]string{"action": "account", "app": name, "entry": string(entry), "source": "dashboard"},
		"Accès de "+name, "")
	if err != nil {
		again("Changement impossible (apps.yml) : " + err.Error())
		return
	}
	tracked(w, r, "/accounts", id)
}

// accountRemove : le compte perd tous ses accès (commit, appliqué seul par think) ; la page donne
// ensuite les commandes pour le supprimer lui-même (secret, puis rebuild). Après le POST, une adresse
// à relire (un F5 ne relance rien).
func (s *Server) accountRemove(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := r.PathValue("name")
	if !s.knownAccount(ctx, name) {
		s.notFound(w, r, "accounts", unknownAccount)
		return
	}
	if s.unreadableForm(w, r, "accounts") {
		return
	}
	done := func(id string) {
		s.redirect(w, r, "/accounts/"+url.PathEscape(name)+"/access?supprime="+url.QueryEscape(id))
	}
	token := r.FormValue("token")
	if id, seen := formSeen(token); seen {
		done(id)
		return
	}
	if name == r.Header.Get("Remote-User") {
		s.listError(w, r, "/accounts", "Tu es connecté avec "+name+" : supprime-le avec un autre compte.")
		return
	}
	id, _, err := s.dispatchForm(ctx, token, map[string]string{"action": "account", "app": name, "entry": "null", "source": "dashboard"},
		"Accès de "+name+" retirés", "")
	if err != nil {
		s.listError(w, r, "/accounts", "Suppression impossible (apps.yml) : "+err.Error())
		return
	}
	done(id)
}
