package main

import (
	"context"
	"net/netip"
	"sync"

	"github.com/oschwald/maxminddb-golang/v2"
)

// Localisation d'une IP publique, avec la base de Vector (DB-IP Lite, sur think) : pour les IP que le
// journal des visites ne localise pas (connexions à Authelia et Vaultwarden, appareils du VPN).

type Geo struct {
	City, Country string
	Lat, Lon      float64
	OK            bool
}

var geoDB struct {
	once sync.Once
	db   *maxminddb.Reader
}

func (s *Server) geo(ip string) Geo {
	a, err := netip.ParseAddr(ip)
	if err != nil || !a.IsGlobalUnicast() || a.IsPrivate() || s.cfg.GeoIP == "" {
		return Geo{}
	}
	geoDB.once.Do(func() { geoDB.db, _ = maxminddb.Open(s.cfg.GeoIP) })
	if geoDB.db == nil {
		return Geo{}
	}
	var rec struct {
		City struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"city"`
		Country struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"country"`
		Location struct {
			Latitude  float64 `maxminddb:"latitude"`
			Longitude float64 `maxminddb:"longitude"`
		} `maxminddb:"location"`
	}
	if geoDB.db.Lookup(a).Decode(&rec) != nil {
		return Geo{}
	}
	name := func(n map[string]string) string { return firstOf(n["fr"], n["en"]) }
	return Geo{City: name(rec.City.Names), Country: name(rec.Country.Names), Lat: rec.Location.Latitude, Lon: rec.Location.Longitude,
		OK: rec.Location.Latitude != 0 || rec.Location.Longitude != 0}
}

// vpnEndpoints : l'IP publique d'où chaque appareil du VPN joint le tunnel (dernière poignée de
// main), par adresse dans le tunnel. C'est sa position actuelle, pas forcément celle d'une visite
// passée.
func (s *Server) vpnEndpoints(ctx context.Context) map[string]string {
	remote := s.promLabel(ctx, "wireguard_latest_handshake_seconds", "public_key", "remote_ip")
	out := map[string]string{}
	for _, p := range s.cfg.VPN.Peers {
		if ip := remote[p.PublicKey]; ip != "" {
			out[p.Address] = ip
		}
	}
	return out
}
