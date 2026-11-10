package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
)

// Pages « Ajouter » d'Authelia et de SSH : ce qui passe par un commit part d'ici (accès d'un compte,
// clé SSH) ; le reste se donne en commandes à taper (un compte se sème dans les secrets). Après
// l'envoi, une adresse à relire (GET, rien de secret) : un F5 ne relance pas la demande.

var (
	reNewAccount = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,31}$`)
	reEmail      = regexp.MustCompile(`^[^@\s"]+@[^@\s"]+\.[^@\s"]+$`)
	reLabel      = regexp.MustCompile(`^[A-Za-z0-9._-]{1,32}$`)
	rePubKey     = regexp.MustCompile(`^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [^"\\\x00-\x1f]{0,100})?$`)
)

// yamlString : une chaîne entre guillemets doubles (JSON, valide en YAML).
func yamlString(v string) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// accountIdentity : identifiant, nom affiché et adresse vérifiés ; `exists` : refuser un compte connu.
func (s *Server) accountIdentity(r *http.Request, name, display, email string, exists bool) []string {
	var errs []string
	if !reNewAccount.MatchString(name) {
		errs = append(errs, "Identifiant : minuscules, chiffres, . _ -, 32 caractères au plus.")
	} else if exists && s.knownAccount(r.Context(), name) {
		errs = append(errs, "Le compte "+name+" existe déjà.")
	}
	if display == "" || len(display) > 64 || strings.ContainsAny(display, "\n\r") {
		errs = append(errs, "Nom affiché : une ligne, 64 caractères au plus.")
	}
	if !reEmail.MatchString(email) {
		errs = append(errs, "Adresse e-mail invalide.")
	}
	return errs
}

// accountNew : le formulaire (identité, services et sites cochés). Envoyé (POST), les accès partent
// tout de suite par un commit (apps.yml, `account`), puis la page des commandes (GET, ?fait=1).
func (s *Server) accountNew(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if s.unreadableForm(w, r, "accounts") {
		return
	}
	name, display, email := strings.TrimSpace(r.FormValue("name")), strings.TrimSpace(r.FormValue("displayname")), strings.TrimSpace(r.FormValue("email"))
	services, checked := checkedServices(r.Form["service"], s.cfg.Authelia.Services)
	data := map[string]any{"Nav": "accounts", "PageTitle": "Nouveau compte", "Name": name, "DisplayName": display, "Email": email, "Services": s.cfg.Authelia.Services,
		"Checked": checked, "SSO": true, "Secret": s.cfg.Authelia.UsersSecret, "Portal": s.cfg.Authelia.PortalHost}
	// Page des commandes : l'identité relue de l'adresse, revérifiée (elle finit dans les secrets).
	if r.Method != http.MethodPost && r.URL.Query().Get("fait") != "" {
		if errs := s.accountIdentity(r, name, display, email, false); len(errs) > 0 {
			s.badRequest(w, r, "accounts", strings.Join(errs, " "))
			return
		}
		id := r.URL.Query().Get("suivi")
		data["PageTitle"], data["Granted"], data["Track"] = name, id != "", trackOf(id)
		data["GrantedServices"], data["GrantedSites"] = services, r.Form["site"]
		data["Snippet"] = name + ":\n    displayname: " + yamlString(display) + "\n    email: " + yamlString(email)
		s.render(w, "account-new", data)
		return
	}
	sites, sitesErr := s.ssoSites(ctx, "")
	if r.Method == http.MethodPost {
		sites = formSites(r, sites)
	}
	data["Sites"], data["MainError"], data["Token"] = sites, mainError(sitesErr), formToken()
	if r.Method != http.MethodPost {
		s.render(w, "account-new", data)
		return
	}
	var opened []string
	changes := []siteAccess{}
	for _, a := range sites {
		if a.On && !a.Inherited {
			changes = append(changes, siteAccess{a.Site, a.Env, true})
			opened = append(opened, a.App)
		}
	}
	done := func(id string) {
		q := url.Values{"fait": {"1"}, "name": {name}, "displayname": {display}, "email": {email}, "service": services, "site": opened}
		if id != "" {
			q.Set("suivi", id)
		}
		s.redirect(w, r, "/accounts/new?"+q.Encode())
	}
	token := r.FormValue("token")
	if id, seen := formSeen(token); seen {
		done(id)
		return
	}
	if errs := s.accountIdentity(r, name, display, email, true); len(errs) > 0 {
		data["Error"] = strings.Join(errs, " ")
		s.render(w, "account-new", data)
		return
	}
	if len(services) == 0 && len(changes) == 0 {
		done("")
		return
	}
	entry, _ := json.Marshal(map[string]any{"services": services, "sites": changes})
	id, _, err := s.dispatchForm(ctx, token, map[string]string{"action": "account", "app": name, "entry": string(entry), "source": "dashboard"},
		"Accès de "+name, "Ils s'activent avec le compte, au rebuild ci-dessous.")
	if err != nil {
		data["Error"] = "Accès non enregistrés (apps.yml) : " + err.Error()
		s.render(w, "account-new", data)
		return
	}
	done(id)
}

// sshForm : le formulaire d'ajout de clé (GET ou POST), vérifié ; `line` : la ligne à autoriser,
// prête quand une clé valide a été collée. `added` : la clé vient d'être ajoutée (elle est donc déjà
// sur main, ce n'est pas un doublon).
func (s *Server) sshForm(r *http.Request, added bool) (data map[string]any, line string) {
	var users []string
	for _, u := range s.cfg.SSH.Users {
		users = append(users, u.Name)
	}
	user, device, key := strings.TrimSpace(r.FormValue("user")), strings.TrimSpace(r.FormValue("device")), strings.Join(strings.Fields(r.FormValue("key")), " ")
	if user == "" && len(users) > 0 {
		user = users[0]
	}
	data = map[string]any{"Nav": "ssh", "PageTitle": "Nouvelle clé", "User": user, "Users": users, "Device": device, "Key": key, "Info": s.cfg.SSH}
	if !r.Form.Has("device") {
		return data, ""
	}
	var errs []string
	if !slices.Contains(users, user) {
		errs = append(errs, "Compte inconnu : "+user+".")
	}
	if !reLabel.MatchString(device) {
		errs = append(errs, "Appareil : lettres, chiffres, . _ -, 32 caractères au plus.")
	}
	comment := user + "@" + device
	data["Comment"] = comment
	if key != "" {
		f := strings.Fields(key)
		switch {
		case !rePubKey.MatchString(key):
			errs = append(errs, "Clé publique illisible : colle la ligne entière du fichier .pub.")
		case len(f) == 2:
			line = key + " " + comment
		default:
			line = key
		}
		if !added {
			onMain, _ := s.mainSSHKeys(r.Context())
			all := map[string][]string{}
			for _, u := range s.cfg.SSH.Users {
				all[u.Name] = append(all[u.Name], u.Keys...)
			}
			for u, ks := range onMain {
				all[u] = append(all[u], ks...)
			}
			for u, ks := range all {
				for _, k := range ks {
					if kf := strings.Fields(k); len(f) >= 2 && len(kf) >= 2 && kf[1] == f[1] {
						errs = append(errs, "Cette clé est déjà autorisée pour "+u+".")
					}
				}
			}
		}
	}
	if len(errs) > 0 {
		data["Error"] = strings.Join(slices.Compact(errs), " ")
		return data, ""
	}
	data["Ready"] = true
	if line != "" {
		data["Line"], data["Fingerprint"] = line, sshKeyRow(user, line).Fingerprint
		data["Token"] = formToken()
	}
	return data, line
}

// sshNew : sans clé, les commandes pour la créer ; avec une clé, son résumé et le bouton d'ajout ;
// après l'ajout (?suivi=), les étapes qui restent.
func (s *Server) sshNew(w http.ResponseWriter, r *http.Request) {
	if s.unreadableForm(w, r, "ssh") {
		return
	}
	added := r.URL.Query().Has("suivi")
	data, line := s.sshForm(r, added)
	if added {
		if line == "" {
			msg, _ := data["Error"].(string)
			s.badRequest(w, r, "ssh", firstOf(msg, "Clé absente de l'adresse."))
			return
		}
		data["PageTitle"], data["Added"], data["Track"] = data["Comment"], true, trackOf(r.URL.Query().Get("suivi"))
	}
	s.render(w, "ssh-new", data)
}

// sshAdd : la clé entre dans ssh-keys.json (commit) ; active au prochain rebuild, qui la montre.
func (s *Server) sshAdd(w http.ResponseWriter, r *http.Request) {
	if s.unreadableForm(w, r, "ssh") {
		return
	}
	done := func(id string) {
		q := url.Values{"suivi": {id}, "user": {r.FormValue("user")}, "device": {r.FormValue("device")}, "key": {r.FormValue("key")}}
		s.redirect(w, r, "/ssh/new?"+q.Encode())
	}
	token := r.FormValue("token")
	if id, seen := formSeen(token); seen {
		done(id)
		return
	}
	data, line := s.sshForm(r, false)
	if line == "" {
		s.render(w, "ssh-new", data)
		return
	}
	user, comment := data["User"].(string), data["Comment"].(string)
	entry, _ := json.Marshal(map[string]string{"add": line})
	id, _, err := s.dispatchForm(r.Context(), token, map[string]string{"action": "sshkey", "app": user, "entry": string(entry), "source": "dashboard"},
		"Clé "+comment, "Elle s'active au rebuild ci-dessous.")
	if err != nil {
		data["Error"] = "Ajout impossible (apps.yml) : " + err.Error()
		s.render(w, "ssh-new", data)
		return
	}
	done(id)
}
