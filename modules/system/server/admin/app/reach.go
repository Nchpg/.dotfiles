package main

import (
	"context"
	"net"
	"sync"
	"time"
)

// Joignable par le tunnel : un nom servi en VPN doit pointer sur think dans le tunnel (adresse du
// serveur WireGuard, ou une adresse de son réseau), sinon les appareils ne l'atteignent pas par lui.
// Vérifié en résolvant le nom comme le fait think (son résolveur), gardé 10 minutes.

type tunnelItem struct {
	at        time.Time
	ok, known bool
}

var tunnelCache = struct {
	sync.Mutex
	m map[string]tunnelItem
}{m: map[string]tunnelItem{}}

// viaTunnel : le nom pointe-t-il sur think dans le tunnel ? `known` faux si on ne sait pas (pas de
// VPN configuré, résolution impossible) : rien n'est alors affirmé.
func (s *Server) viaTunnel(host string) (ok, known bool) {
	_, network, err := net.ParseCIDR(s.cfg.VPN.Subnet)
	if err != nil || host == "" {
		return false, false
	}
	tunnelCache.Lock()
	it, hit := tunnelCache.m[host]
	tunnelCache.Unlock()
	if hit && time.Since(it.at) < 10*time.Minute {
		return it.ok, it.known
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupHost(ctx, host)
	it = tunnelItem{at: time.Now(), known: err == nil}
	for _, a := range addrs {
		if ip := net.ParseIP(a); ip != nil && (a == s.cfg.VPN.ServerAddress || network.Contains(ip)) {
			it.ok = true
		}
	}
	tunnelCache.Lock()
	tunnelCache.m[host] = it
	tunnelCache.Unlock()
	return it.ok, it.known
}
