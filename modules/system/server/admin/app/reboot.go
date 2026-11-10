package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Redémarrage nécessaire : un rebuild a installé un autre noyau (ou initrd, ou modules) que celui
// démarré ; il ne sera chargé qu'au prochain démarrage. Mêmes éléments que ceux que NixOS compare.

type Reboot struct {
	Booted, Current string   // versions du noyau (démarré, installé)
	Parts           []string // ce qui diffère, lisiblement (image du noyau, initrd, modules)
}

// Text : la phrase du bandeau. Même version des deux côtés (initrd ou modules seuls changés) :
// « noyau X installé, X encore chargé » ne voudrait rien dire, elle nomme ce qui a changé.
func (r *Reboot) Text() string {
	if r.Booted != r.Current {
		return "noyau " + r.Current + " installé, " + r.Booted + " encore chargé. Il ne s'appliquera qu'au prochain démarrage."
	}
	what := r.Parts[0]
	if n := len(r.Parts); n > 1 {
		what = strings.Join(r.Parts[:n-1], ", ") + " et " + r.Parts[n-1]
	}
	return "même noyau " + r.Current + ", mais " + what + " changés : ils ne s'appliqueront qu'au prochain démarrage."
}

var reKernelVersion = regexp.MustCompile(`-linux-([0-9][^/-]*)`)

// rebootOf : nil si le système démarré et l'actif ont le même noyau, initrd et modules.
func rebootOf(booted, current string) *Reboot {
	labels := map[string]string{"kernel": "image du noyau", "initrd": "initrd", "kernel-modules": "modules"}
	var parts []string
	for _, part := range []string{"kernel", "initrd", "kernel-modules"} {
		b, err1 := os.Readlink(filepath.Join(booted, part))
		c, err2 := os.Readlink(filepath.Join(current, part))
		if err1 == nil && err2 == nil && b != c {
			parts = append(parts, labels[part])
		}
	}
	if len(parts) == 0 {
		return nil
	}
	version := func(root string) string {
		p, _ := os.Readlink(filepath.Join(root, "kernel"))
		if m := reKernelVersion.FindStringSubmatch(p); m != nil {
			return m[1]
		}
		return "?"
	}
	return &Reboot{Booted: version(booted), Current: version(current), Parts: parts}
}

func rebootNeeded() *Reboot { return rebootOf("/run/booted-system", "/run/current-system") }
