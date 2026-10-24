package main

import (
	"encoding/json"
	"net/http"
	"regexp"
	"slices"
	"strings"
)

// Pages « Ajouter » d'Authelia et de SSH : ce qui passe par un commit part d'ici (accès d'un compte,
// clé SSH) ; le reste se donne en commandes à taper (un compte se sème dans les secrets).

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

// accountNew : le formulaire (identité, services et sites cochés). Envoyé (POST), les accès partent
// tout de suite par un commit (apps.yml, `account`) et la page donne les commandes pour le compte.
func (s *Server) accountNew(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	_ = r.ParseForm()
	name, display, email := strings.TrimSpace(r.FormValue("name")), strings.TrimSpace(r.FormValue("displayname")), strings.TrimSpace(r.FormValue("email"))
	sites, err := s.ssoSites(ctx, "")
	services := []string{}
	for _, sv := range s.cfg.Authelia.Services {
		if slices.Contains(r.Form["service"], sv.Name) {
			services = append(services, sv.Name)
		}
	}
	checked := map[string]bool{}
	for _, sv := range services {
		checked[sv] = true
	}
	if r.Method == http.MethodPost {
		sites = formSites(r, sites)
	}
	data := map[string]any{"Nav": "accounts", "Name": name, "DisplayName": display, "Email": email, "Services": s.cfg.Authelia.Services,
		"Checked": checked, "Sites": sites, "SSO": true, "Secret": s.cfg.Authelia.UsersSecret, "Portal": s.cfg.Authelia.PortalHost, "Error": errString(err)}
	if r.Method != http.MethodPost {
		s.render(w, "account-new", data)
		return
	}
	var errs []string
	if !reNewAccount.MatchString(name) {
		errs = append(errs, "Identifiant : minuscules, chiffres, . _ -, 32 caractères au plus.")
	} else if s.knownAccount(ctx, name) {
		errs = append(errs, "Le compte "+name+" existe déjà.")
	}
	if display == "" || len(display) > 64 || strings.ContainsAny(display, "\n\r") {
		errs = append(errs, "Nom affiché : une ligne, 64 caractères au plus.")
	}
	if !reEmail.MatchString(email) {
		errs = append(errs, "Adresse e-mail invalide.")
	}
	if len(errs) > 0 {
		data["Error"] = strings.Join(errs, " ")
		s.render(w, "account-new", data)
		return
	}
	changes := []siteAccess{}
	var opened []string
	for _, a := range sites {
		if a.On && !a.Inherited {
			changes = append(changes, siteAccess{a.Site, a.Env, true})
			opened = append(opened, a.App)
		}
	}
	if len(services) > 0 || len(changes) > 0 {
		entry, _ := json.Marshal(map[string]any{"services": services, "sites": changes})
		id, err := s.dispatch(ctx, map[string]string{"action": "account", "app": name, "entry": string(entry), "source": "dashboard"},
			"Accès de "+name, "Ils s'activent avec le compte, au rebuild ci-dessous.")
		if err != nil {
			data["Error"] = "Accès non enregistrés (apps.yml) : " + err.Error()
			s.render(w, "account-new", data)
			return
		}
		data["Granted"], data["Track"] = true, trackOf(id)
	}
	data["GrantedServices"], data["GrantedSites"] = services, opened
	data["Snippet"] = name + ":\n    displayname: " + yamlString(display) + "\n    email: " + yamlString(email)
	s.render(w, "account-new", data)
}

// sshForm : le formulaire d'ajout de clé (GET ou POST), vérifié ; `line` : la ligne à autoriser,
// prête quand une clé valide a été collée.
func (s *Server) sshForm(r *http.Request) (data map[string]any, line string) {
	var users []string
	for _, u := range s.cfg.SSH.Users {
		users = append(users, u.Name)
	}
	user, device, key := strings.TrimSpace(r.FormValue("user")), strings.TrimSpace(r.FormValue("device")), strings.Join(strings.Fields(r.FormValue("key")), " ")
	if user == "" && len(users) > 0 {
		user = users[0]
	}
	data = map[string]any{"Nav": "ssh", "User": user, "Users": users, "Device": device, "Key": key, "Info": s.cfg.SSH}
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
	if len(errs) > 0 {
		data["Error"] = strings.Join(slices.Compact(errs), " ")
		return data, ""
	}
	data["Ready"] = true
	if line != "" {
		data["Line"], data["Fingerprint"] = line, sshKeyRow(user, line).Fingerprint
	}
	return data, line
}

// sshNew : sans clé, les commandes pour la créer ; avec une clé, son résumé et le bouton d'ajout.
func (s *Server) sshNew(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	data, _ := s.sshForm(r)
	s.render(w, "ssh-new", data)
}

// sshAdd : la clé entre dans ssh-keys.json (commit) ; active au prochain rebuild, qui la montre.
func (s *Server) sshAdd(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	data, line := s.sshForm(r)
	if line == "" {
		s.render(w, "ssh-new", data)
		return
	}
	entry, _ := json.Marshal(map[string]string{"add": line})
	id, err := s.dispatch(r.Context(), map[string]string{"action": "sshkey", "app": data["User"].(string), "entry": string(entry), "source": "dashboard"},
		"Clé "+data["Comment"].(string), "Elle s'active au rebuild ci-dessous.")
	if err != nil {
		data["Error"] = "Ajout impossible (apps.yml) : " + err.Error()
		s.render(w, "ssh-new", data)
		return
	}
	data["Added"], data["Track"] = true, trackOf(id)
	s.render(w, "ssh-new", data)
}
