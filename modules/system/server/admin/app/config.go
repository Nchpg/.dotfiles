package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// retention : une durée de Loki (`30d`, `720h`) ; 30 jours si illisible.
func retention(v string) time.Duration {
	if n, err := strconv.Atoi(strings.TrimSuffix(v, "d")); err == nil && strings.HasSuffix(v, "d") && n > 0 {
		return time.Duration(n) * 24 * time.Hour
	}
	if d, err := time.ParseDuration(v); err == nil && d > 0 {
		return d
	}
	return 30 * 24 * time.Hour
}

// Config vient de l'environnement posé par le module NixOS (modules/system/server/admin).
type Config struct {
	Listen       string // 127.0.0.1:port, derrière nginx
	Host         string // nom servi : seules les requêtes POST venant de lui sont acceptées
	Repo         string // Nchpg/.dotfiles
	GitURL       string // dépôt lu par git (un chemin local pour les tests)
	Branch       string
	Target       string // configuration NixOS évaluée avant chaque modification
	Domain       string // domaine de base des sites
	Machine      string // nom de la machine (en-tête, application installée)
	Registry     string // ghcr.io/nchpg
	RegistryUser string
	Prometheus   string
	Loki         string // journaux (vide : pas de monitoring, la page SSH s'en passe)
	LogsWindow   time.Duration
	SSHUnit      string
	GeoIP        string // base de localisation des IP (celle de Vector), vide sans monitoring
	DeployStatus string // status.json d'apps-deploy
	StateDir     string
	Htmx         string
	Fonts        string
	Peers        []string
	SecretKeys   []string
	Services     []Service    // services de think hors apps.json (lecture seule)
	VPN          VPNInfo      // tunnel et appareils (page VPN)
	SSH          SSHInfo      // clés autorisées (page SSH)
	AccountsFile string       // résumé des comptes Authelia, écrit par admin-accounts (root)
	TrafficFile  string       // applis et sessions de Nextcloud et Vaultwarden, écrit par admin-traffic (root)
	Authelia     AutheliaInfo // services ouverts compte par compte (page Authelia)
	WGPubkeyFile string       // clé publique du serveur WireGuard, dérivée au démarrage
	RecopyStatus string       // résultats d'admin-recopy (root), lus seulement
	MetricsURL   string       // tableau de bord Grafana de la page Métriques (vide : page « bientôt »)

	DispatchToken string // lance apps.yml, rien d'autre
	RegistryToken string // lit les images et la liste des packages
	NixAccessFile string // jeton du dépôt de secrets, pour l'évaluation
}

func loadConfig() (*Config, error) {
	c := &Config{
		Listen:       env("ADMIN_LISTEN", "127.0.0.1:8090"),
		Host:         env("ADMIN_HOST", ""),
		Repo:         env("ADMIN_REPO", "Nchpg/.dotfiles"),
		GitURL:       env("ADMIN_GIT_URL", ""),
		Branch:       env("ADMIN_BRANCH", "main"),
		Target:       env("ADMIN_TARGET", ""),
		Domain:       env("ADMIN_DOMAIN", ""),
		Machine:      env("ADMIN_MACHINE", "serveur"),
		Registry:     env("ADMIN_REGISTRY", ""),
		RegistryUser: env("ADMIN_REGISTRY_USER", ""),
		Prometheus:   env("ADMIN_PROMETHEUS", "http://127.0.0.1:9090"),
		Loki:         os.Getenv("ADMIN_LOKI"),
		LogsWindow:   retention(env("ADMIN_LOGS_RETENTION", "30d")),
		SSHUnit:      env("ADMIN_SSH_UNIT", "sshd.service"),
		GeoIP:        os.Getenv("ADMIN_GEOIP"),
		DeployStatus: env("ADMIN_DEPLOY_STATUS", "/var/lib/apps-deploy/status.json"),
		StateDir:     env("STATE_DIRECTORY", "/tmp/admin"),
		Htmx:         env("ADMIN_HTMX", ""),
		Fonts:        env("ADMIN_FONTS", ""),
		RecopyStatus: env("ADMIN_RECOPY_STATUS", "/var/lib/admin-recopy"),
		MetricsURL:   os.Getenv("ADMIN_METRICS_URL"),
		AccountsFile: env("ADMIN_ACCOUNTS_FILE", "/var/lib/admin-accounts/accounts.json"),
		TrafficFile:  env("ADMIN_TRAFFIC_FILE", "/var/lib/admin-traffic/traffic.json"),
		WGPubkeyFile: env("ADMIN_WG_PUBKEY", "/run/admin/wg-server.pub"),
	}
	// DynamicUser : /var/lib/admin est un lien vers /var/lib/private/admin, et Nix refuse
	// d'évaluer un dépôt à travers un lien. On travaille sur le chemin réel.
	if real, err := filepath.EvalSymlinks(c.StateDir); err == nil {
		c.StateDir = real
	}
	if c.GitURL == "" {
		c.GitURL = "https://github.com/" + c.Repo + ".git"
	}
	for name, v := range map[string]string{"ADMIN_HOST": c.Host, "ADMIN_TARGET": c.Target, "ADMIN_DOMAIN": c.Domain, "ADMIN_REGISTRY": c.Registry} {
		if v == "" {
			return nil, fmt.Errorf("%s manquant", name)
		}
	}
	if err := readJSON(os.Getenv("ADMIN_PEERS_FILE"), &c.Peers); err != nil {
		return nil, fmt.Errorf("appareils WireGuard : %w", err)
	}
	if err := readJSON(os.Getenv("ADMIN_SECRETS_FILE"), &c.SecretKeys); err != nil {
		return nil, fmt.Errorf("clés de secrets : %w", err)
	}
	if err := readJSON(os.Getenv("ADMIN_SERVICES_FILE"), &c.Services); err != nil {
		return nil, fmt.Errorf("services : %w", err)
	}
	if err := readJSON(os.Getenv("ADMIN_VPN_FILE"), &c.VPN); err != nil {
		return nil, fmt.Errorf("vpn : %w", err)
	}
	if err := readJSON(os.Getenv("ADMIN_SSH_FILE"), &c.SSH); err != nil {
		return nil, fmt.Errorf("ssh : %w", err)
	}
	if err := readJSON(os.Getenv("ADMIN_AUTHELIA_FILE"), &c.Authelia); err != nil {
		return nil, fmt.Errorf("authelia : %w", err)
	}

	// Credentials systemd : jamais dans l'environnement (lisible dans /proc).
	creds := os.Getenv("CREDENTIALS_DIRECTORY")
	c.DispatchToken = readSecret(creds, "dispatch")
	c.RegistryToken = readSecret(creds, "ghcr")
	if creds != "" {
		if _, err := os.Stat(filepath.Join(creds, "nix-access")); err == nil {
			c.NixAccessFile = filepath.Join(creds, "nix-access")
		}
	}
	return c, nil
}

// Service : un nom servi par think hors apps.json (cf. `services` dans ../default.nix).
type Service struct {
	Name     string `json:"name"`
	Domain   string `json:"domain"`
	Public   bool   `json:"public"`
	Authelia bool   `json:"authelia"`
	Probed   bool   `json:"probed"`
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func readJSON(path string, v any) error {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func readSecret(dir, name string) string {
	if dir == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
