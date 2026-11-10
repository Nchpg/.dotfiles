package main

import (
	"context"
	"log"
	"runtime/debug"
	"sync"
	"time"
)

// Les données lentes d'une page (requêtes Loki, journal de sshd) : servies tout de suite depuis la
// dernière lecture ; au-delà de slowFresh, relues en arrière-plan (la page suivante les a à jour) ;
// au-delà de slowMax, attendues (pas de données trop vieilles après une longue absence). Une seule
// lecture à la fois par clé, partagée par les demandes qui l'attendent.
const (
	slowFresh = time.Minute
	slowMax   = 15 * time.Minute
	slowLimit = 30 * time.Second // durée maximale d'une lecture
)

type slowItem struct {
	val     any
	at      time.Time
	loading chan struct{} // non nil pendant une lecture
}

type slowCache struct {
	mu sync.Mutex
	m  map[string]*slowItem
}

// get : la valeur de `key`, construite par `build` (sans le contexte de la demande : une lecture en
// arrière-plan lui survit). Un résultat nil (page introuvable) n'est pas gardé.
func (c *slowCache) get(key string, build func(context.Context) any) any {
	c.mu.Lock()
	if c.m == nil {
		c.m = map[string]*slowItem{}
	}
	it := c.m[key]
	if it == nil {
		it = &slowItem{}
		c.m[key] = it
	}
	if age := time.Since(it.at); it.val != nil && age < slowMax {
		if age >= slowFresh && it.loading == nil {
			c.load(key, it, build)
		}
		v := it.val
		c.mu.Unlock()
		return v
	}
	if it.loading == nil {
		c.load(key, it, build)
	}
	ch := it.loading
	c.mu.Unlock()
	<-ch
	c.mu.Lock()
	defer c.mu.Unlock()
	return it.val
}

// load : une lecture en arrière-plan (sous c.mu). Une panique de `build` (ligne inattendue de Loki…)
// est rattrapée : l'ancienne valeur reste, et ceux qui attendent sont toujours libérés.
func (c *slowCache) load(key string, it *slowItem, build func(context.Context) any) {
	it.loading = make(chan struct{})
	go func() {
		var v any
		defer func() {
			if p := recover(); p != nil {
				log.Printf("lecture %s : panique : %v\n%s", key, p, debug.Stack())
				v = nil
			}
			c.mu.Lock()
			defer c.mu.Unlock()
			if v != nil {
				it.val, it.at = v, time.Now()
			} else if it.val == nil {
				delete(c.m, key)
			}
			close(it.loading)
			it.loading = nil
		}()
		ctx, cancel := context.WithTimeout(context.Background(), slowLimit)
		defer cancel()
		v = build(ctx)
	}()
}
