package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Evaluator évalue la config de think avec un apps.json candidat, avant tout envoi : une
// erreur que la config sait détecter (adresse prise, appareil inconnu…) ne part jamais sur main.
type Evaluator struct {
	cfg *Config
	mu  sync.Mutex // une évaluation à la fois : elle coûte de la mémoire
}

func (ev *Evaluator) dir() string { return filepath.Join(ev.cfg.StateDir, "eval") }

func (ev *Evaluator) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = ev.env()
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.Bytes(), err
}

// env : l'environnement de git et nix (jeton du dépôt de secrets, et de GitHub, en config nix).
func (ev *Evaluator) env() []string {
	home := filepath.Join(ev.cfg.StateDir, "home")
	_ = os.MkdirAll(home, 0o700)
	nixConfig := "warn-dirty = false\n"
	if ev.cfg.NixAccessFile != "" {
		nixConfig += "!include " + ev.cfg.NixAccessFile + "\n"
	}
	return append(os.Environ(), "HOME="+home, "XDG_CACHE_HOME="+filepath.Join(ev.cfg.StateDir, "cache"), "NIX_CONFIG="+nixConfig,
		"GIT_TERMINAL_PROMPT=0")
}

// Check : nil si la config de think s'évalue avec ces deux fichiers posés sur `head`.
func (ev *Evaluator) Check(ctx context.Context, head string, apps, lock []byte) error {
	ev.mu.Lock()
	defer ev.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 6*time.Minute)
	defer cancel()

	dir := ev.dir()
	if err := ev.checkout(ctx, head); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "profiles/server/apps.json"), apps, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "profiles/server/apps.lock.json"), lock, 0o644); err != nil {
		return err
	}
	attr := "git+file://" + dir + "#nixosConfigurations." + ev.cfg.Target + ".config.system.build.toplevel.drvPath"
	out, err := ev.run(ctx, "nix", "eval", "--raw", attr)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return errors.New("évaluation trop longue (plus de 6 minutes)")
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		return errors.New(evalError(out))
	}
	return nil
}

// checkout : la copie d'évaluation sur `head`, propre (à appeler sous ev.mu).
func (ev *Evaluator) checkout(ctx context.Context, head string) error {
	dir := ev.dir()
	if _, err := os.Stat(filepath.Join(dir, ".git")); err != nil {
		_ = os.RemoveAll(dir)
		if out, err := ev.run(ctx, "git", "clone", "--quiet", ev.cfg.GitURL, dir); err != nil {
			return fmt.Errorf("clone impossible : %s", lastLines(out, 3))
		}
	}
	for _, args := range [][]string{
		{"-C", dir, "fetch", "--quiet", "origin", ev.cfg.Branch},
		{"-C", dir, "checkout", "--quiet", "--force", "--detach", head},
		{"-C", dir, "clean", "--quiet", "-fdx"},
	} {
		if out, err := ev.run(ctx, "git", args...); err != nil {
			return fmt.Errorf("git %s : %s", args[2], lastLines(out, 3))
		}
	}
	return nil
}

// evalError : le message utile d'une évaluation ratée (assertions, ou dernière erreur).
func evalError(out []byte) string {
	lines := strings.Split(string(out), "\n")
	for i, l := range lines {
		if strings.Contains(l, "Failed assertions:") {
			var msgs []string
			for _, m := range lines[i+1:] {
				m = strings.TrimSpace(m)
				if !strings.HasPrefix(m, "- ") {
					break
				}
				msgs = append(msgs, strings.TrimPrefix(m, "- "))
			}
			if len(msgs) > 0 {
				return strings.Join(msgs, "\n")
			}
		}
	}
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if strings.HasPrefix(l, "error:") && len(l) > len("error:") {
			return strings.TrimSpace(strings.TrimPrefix(l, "error:"))
		}
	}
	return lastLines(out, 4)
}

func lastLines(out []byte, n int) string {
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
