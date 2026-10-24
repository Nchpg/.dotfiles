package main

import (
	"os"
	"path/filepath"
	"regexp"
)

// Redémarrage nécessaire : un rebuild a installé un autre noyau (ou initrd, ou modules) que celui
// démarré ; il ne sera chargé qu'au prochain démarrage. Mêmes éléments que ceux que NixOS compare.

type Reboot struct {
	Booted, Current string // versions du noyau (démarré, installé)
}

var reKernelVersion = regexp.MustCompile(`-linux-([0-9][^/-]*)`)

// rebootOf : nil si le système démarré et l'actif ont le même noyau, initrd et modules.
func rebootOf(booted, current string) *Reboot {
	need := false
	for _, part := range []string{"kernel", "initrd", "kernel-modules"} {
		b, err1 := os.Readlink(filepath.Join(booted, part))
		c, err2 := os.Readlink(filepath.Join(current, part))
		if err1 == nil && err2 == nil && b != c {
			need = true
		}
	}
	if !need {
		return nil
	}
	version := func(root string) string {
		p, _ := os.Readlink(filepath.Join(root, "kernel"))
		if m := reKernelVersion.FindStringSubmatch(p); m != nil {
			return m[1]
		}
		return "?"
	}
	return &Reboot{Booted: version(booted), Current: version(current)}
}

func rebootNeeded() *Reboot { return rebootOf("/run/booted-system", "/run/current-system") }
