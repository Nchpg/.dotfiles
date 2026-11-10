package main

import (
	"context"
	"net"
	"sync"
	"time"
)

// Joignable par le tunnel : un nom servi en VPN doit pointer sur think dans le tunnel (adresse du
// serveur WireGuard, ou une adresse de son réseau), sinon les appareils ne l'atteignent pas par lui.
// Vérifié en résolvant le nom comme le fait think (son résolveur). Une réponse est gardée 10 minutes
// (un échec de résolution, 1 minute) ; passé ce délai, l'ancienne sert encore le temps qu'une
// résolution en fond la remplace : la page n'attend jamais le résolveur, sauf la toute première fois.

const (
	tunnelTTL     = 10 * time.Minute
	tunnelFailTTL = time.Minute
)

type tunnelItem struct {
	at        time.Time
	ok, known bool
}

var tunnelCache = struct {
	sync.Mutex
	m       map[string]tunnelItem
	loading map[string]chan struct{} // résolutions en cours (une seule par nom), fermées à la fin
}{m: map[string]tunnelItem{}, loading: map[string]chan struct{}{}}

// viaTunnel : le nom pointe-t-il sur think dans le tunnel ? `known` faux si on ne sait pas (pas de
// VPN configuré, résolution impossible) : rien n'est alors affirmé.
func (s *Server) viaTunnel(host string) (ok, known bool) {
	network := s.tunnelNet()
	if network == nil || host == "" {
		return false, false
	}
	tunnelCache.Lock()
	it, hit := tunnelCache.m[host]
	if hit {
		if time.Since(it.at) >= it.ttl() {
			s.resolveTunnelLocked(host, network) // en fond : l'ancienne réponse sert en attendant
		}
		tunnelCache.Unlock()
		return it.ok, it.known
	}
	done := s.resolveTunnelLocked(host, network)
	tunnelCache.Unlock()
	<-done
	tunnelCache.Lock()
	it = tunnelCache.m[host]
	tunnelCache.Unlock()
	return it.ok, it.known
}

// prefetchTunnels : résout ensemble, en parallèle, les noms encore jamais vus, avant que la page ne
// les demande un par un (sinon N noms coûtent N fois le délai du résolveur).
func (s *Server) prefetchTunnels(hosts []string) {
	network := s.tunnelNet()
	if network == nil {
		return
	}
	var waits []chan struct{}
	tunnelCache.Lock()
	for _, h := range hosts {
		if _, hit := tunnelCache.m[h]; !hit && h != "" {
			waits = append(waits, s.resolveTunnelLocked(h, network))
		}
	}
	tunnelCache.Unlock()
	for _, w := range waits {
		<-w
	}
}

func (s *Server) tunnelNet() *net.IPNet {
	_, network, err := net.ParseCIDR(s.cfg.VPN.Subnet)
	if err != nil {
		return nil
	}
	return network
}

func (it tunnelItem) ttl() time.Duration {
	if !it.known {
		return tunnelFailTTL
	}
	return tunnelTTL
}

// resolveTunnelLocked : lance la résolution de `host` (sauf si elle tourne déjà) ; le canal rendu
// se ferme quand le cache a la réponse. À appeler verrou tenu.
func (s *Server) resolveTunnelLocked(host string, network *net.IPNet) chan struct{} {
	if ch, busy := tunnelCache.loading[host]; busy {
		return ch
	}
	ch := make(chan struct{})
	tunnelCache.loading[host] = ch
	server := s.cfg.VPN.ServerAddress
	go func() {
		// Une panique laisse la réponse vide (inconnue) : le canal se ferme quand même.
		it := func() (it tunnelItem) {
			defer recoverLog("joignabilité " + host)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			addrs, err := net.DefaultResolver.LookupHost(ctx, host)
			it.known = err == nil
			for _, a := range addrs {
				if ip := net.ParseIP(a); ip != nil && (a == server || network.Contains(ip)) {
					it.ok = true
				}
			}
			return it
		}()
		it.at = time.Now()
		tunnelCache.Lock()
		tunnelCache.m[host] = it
		delete(tunnelCache.loading, host)
		tunnelCache.Unlock()
		close(ch)
	}()
	return ch
}
