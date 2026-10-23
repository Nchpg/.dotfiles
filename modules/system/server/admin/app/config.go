package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Config vient de l'environnement posé par le module NixOS (modules/system/server/admin).
type Config struct {
	Listen       string // 127.0.0.1:port, derrière nginx
	Host         string // nom servi : seules les requêtes POST venant de lui sont acceptées
	Repo         string // Nchpg/.dotfiles
	GitURL       string // dépôt lu par git (un chemin local pour les tests)
	Branch       string
	Target       string // configuration NixOS évaluée avant chaque modification
	Domain       string // domaine de base des sites
	Registry     string // ghcr.io/nchpg
	RegistryUser string
	Prometheus   string
	DeployStatus string // status.json d'apps-deploy
	StateDir     string
	Htmx         string
	Fonts        string
	Peers        []string
	SecretKeys   []string
	RecopyStatus string // résultats d'admin-recopy (root), lus seulement

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
		Registry:     env("ADMIN_REGISTRY", ""),
		RegistryUser: env("ADMIN_REGISTRY_USER", ""),
		Prometheus:   env("ADMIN_PROMETHEUS", "http://127.0.0.1:9090"),
		DeployStatus: env("ADMIN_DEPLOY_STATUS", "/var/lib/apps-deploy/status.json"),
		StateDir:     env("STATE_DIRECTORY", "/tmp/admin"),
		Htmx:         env("ADMIN_HTMX", ""),
		Fonts:        env("ADMIN_FONTS", ""),
		RecopyStatus: env("ADMIN_RECOPY_STATUS", "/var/lib/admin-recopy"),
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
