package main

// Trajet serveur → Dolphin. Le protocole DSU n'a pas d'écho : le serveur pingue (ICMP) la machine de Dolphin,
// l'adresse de qui s'abonne aux manettes, chaque seconde. La socket « ping » ne demande aucun privilège : le noyau
// l'ouvre aux groupes de net.ipv4.ping_group_range, tous par défaut. La moitié de la médiane des derniers allers-retours
// part aux téléphones avec l'écho de leur propre mesure (pingReply), et dans le journal.

import (
	"log"
	"net"
	"slices"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

// Allers-retours retenus pour la médiane : assez pour écarter un ping retardé, assez peu pour suivre un changement.
const dolphinPings = 5

func (s *server) pingDolphin() {
	conn, err := icmp.ListenPacket("udp4", "0.0.0.0")
	if err != nil {
		log.Printf("trajet vers Dolphin non mesuré : %v", err)
		return
	}
	defer conn.Close()
	var roundTrips []float64
	buf := make([]byte, 1500)
	for seq := 1; ; seq++ {
		time.Sleep(time.Second)
		ip := s.dolphinIP()
		if ip == nil {
			roundTrips = nil
			s.setDolphinDelay(0)
			continue
		}
		echo := icmp.Message{Type: ipv4.ICMPTypeEcho, Body: &icmp.Echo{Seq: seq & 0xffff, Data: []byte("wiimote")}}
		pkt, _ := echo.Marshal(nil)
		start := time.Now()
		if _, err := conn.WriteTo(pkt, &net.UDPAddr{IP: ip}); err != nil {
			continue
		}
		conn.SetReadDeadline(start.Add(time.Second))
		for {
			n, _, err := conn.ReadFrom(buf)
			if err != nil {
				// Perdu ou trop lent : pas de mesure cette fois, la médiane reste.
				break
			}
			reply, err := icmp.ParseMessage(1, buf[:n])
			if err != nil || reply.Type != ipv4.ICMPTypeEchoReply {
				continue
			}
			if e, ok := reply.Body.(*icmp.Echo); !ok || e.Seq != seq&0xffff {
				continue
			}
			roundTrips = append(roundTrips, float64(time.Since(start).Microseconds())/1000)
			if len(roundTrips) > dolphinPings {
				roundTrips = roundTrips[1:]
			}
			sorted := slices.Sorted(slices.Values(roundTrips))
			s.setDolphinDelay(sorted[len(sorted)/2] / 2)
			break
		}
	}
}

// dolphinIP : la machine de Dolphin, d'après son abonnement aux manettes encore valable ; nil sans Dolphin.
func (s *server) dolphinIP() net.IP {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sub := range s.subs {
		if addr, ok := sub.addr.(*net.UDPAddr); ok && time.Now().Before(sub.until) {
			return addr.IP
		}
	}
	return nil
}

// setDolphinDelay retient le trajet serveur → Dolphin (ms, un sens ; 0 : inconnu).
func (s *server) setDolphinDelay(ms float64) {
	s.mu.Lock()
	s.dolphinDelay = ms
	s.mu.Unlock()
}

// pingReply : l'écho de la mesure du téléphone (8 octets), suivi du trajet serveur → Dolphin en µs (u32, 0 :
// inconnu), que la manette affiche à côté du sien.
func (s *server) pingReply(ping []byte) []byte {
	s.mu.Lock()
	us := uint32(s.dolphinDelay * 1000)
	s.mu.Unlock()
	return le.AppendUint32(append([]byte(nil), ping...), us)
}
