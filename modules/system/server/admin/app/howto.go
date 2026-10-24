package main

import (
	"encoding/json"
	"net/http"
	"regexp"
	"slices"
	"strings"
)

// Pages « Ajouter » d'Authelia et de SSH : rien n'est écrit d'ici, elles donnent seulement les
// commandes à taper (un compte se sème dans les secrets, une clé se déclare dans le code Nix).

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

func (s *Server) accountNew(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	name, display, email := strings.TrimSpace(q.Get("name")), strings.TrimSpace(q.Get("displayname")), strings.TrimSpace(q.Get("email"))
	data := map[string]any{"Nav": "accounts", "Name": name, "DisplayName": display, "Email": email,
		"Secret": s.cfg.Authelia.UsersSecret, "Portal": s.cfg.Authelia.PortalHost}
	if q.Has("name") {
		var errs []string
		if !reNewAccount.MatchString(name) {
			errs = append(errs, "Identifiant : minuscules, chiffres, . _ -, 32 caractères au plus.")
		} else if slices.Contains(s.accountChoices(nil), name) {
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
		} else {
			data["Snippet"] = name + ":\n    displayname: " + yamlString(display) + "\n    email: " + yamlString(email)
		}
	}
	s.render(w, "account-new", data)
}

func (s *Server) sshNew(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var users []string
	for _, u := range s.cfg.SSH.Users {
		users = append(users, u.Name)
	}
	user, device, key := strings.TrimSpace(q.Get("user")), strings.TrimSpace(q.Get("device")), strings.Join(strings.Fields(q.Get("key")), " ")
	if user == "" && len(users) > 0 {
		user = users[0]
	}
	data := map[string]any{"Nav": "ssh", "User": user, "Users": users, "Device": device, "Key": key, "Info": s.cfg.SSH}
	if q.Has("device") {
		var errs []string
		if !slices.Contains(users, user) {
			errs = append(errs, "Compte inconnu : "+user+".")
		}
		if !reLabel.MatchString(device) {
			errs = append(errs, "Appareil : lettres, chiffres, . _ -, 32 caractères au plus.")
		}
		comment := user + "@" + device
		line := "ssh-ed25519 AAAA… " + comment
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
			for _, u := range s.cfg.SSH.Users {
				for _, k := range u.Keys {
					if len(f) >= 2 && len(strings.Fields(k)) >= 2 && strings.Fields(k)[1] == f[1] {
						errs = append(errs, "Cette clé est déjà autorisée pour "+u.Name+".")
					}
				}
			}
		}
		if len(errs) > 0 {
			data["Error"] = strings.Join(errs, " ")
		} else {
			data["Comment"], data["Line"], data["Ready"] = comment, line, true
		}
	}
	s.render(w, "ssh-new", data)
}
