package main

// Mesure de la liaison de chaque manette, notée dans le journal toutes les statsEvery : cadence des états reçus,
// écart entre deux, retard qui s'ajoute quand des états sont retenus puis livrés d'un coup (Wi-Fi en économie
// d'énergie, 4G chargée), pertes, et l'aller-retour que mesure le téléphone. Le retard se lit sur l'heure du
// téléphone que porte chaque datagramme : par le WebSocket, qui ne la porte pas, seuls la cadence et les écarts.

import (
	"fmt"
	"log"
	"slices"
	"strings"
	"time"
)

const statsEvery = 10 * time.Second

// Sous s.mu, dans player.
type linkStats struct {
	arrivals []time.Time
	// Arrivée moins heure du téléphone (ms) : l'écart des horloges est inconnu, seules les variations comptent.
	delays []float64
	// Aller-retours mesurés par le téléphone (ms), qu'il glisse dans ses mesures du délai.
	roundTrips []float64
	lost, late int
	// Dernier numéro de datagramme reçu de cette liaison directe (0 : aucun).
	last uint32
}

// state : un état reçu par le WebSocket.
func (l *linkStats) state(at time.Time) {
	l.arrivals = append(l.arrivals, at)
}

// datagram : un état reçu par la liaison directe, numéro `seq`, daté `phone` (ms, horloge du téléphone).
func (l *linkStats) datagram(seq, phone uint32, at time.Time) {
	if l.last != 0 && seq <= l.last {
		l.late++
		return
	}
	if l.last != 0 {
		l.lost += int(seq - l.last - 1)
	}
	l.last = seq
	l.arrivals = append(l.arrivals, at)
	l.delays = append(l.delays, float64(at.UnixMicro())/1000-float64(phone))
}

// take rend la mesure écoulée et repart de zéro, en gardant le dernier numéro.
func (l *linkStats) take() linkStats {
	t := *l
	*l = linkStats{last: l.last}
	return t
}

// summary : la mesure d'une fenêtre de `window`, vide sans au moins deux états.
func (t linkStats) summary(window time.Duration) string {
	if len(t.arrivals) < 2 {
		return ""
	}
	gaps := make([]float64, len(t.arrivals)-1)
	for i := range gaps {
		gaps[i] = float64(t.arrivals[i+1].Sub(t.arrivals[i]).Microseconds()) / 1000
	}
	parts := []string{fmt.Sprintf("%.0f états/s", float64(len(t.arrivals))/window.Seconds()), "écart " + spread(gaps)}
	if len(t.delays) > 1 {
		fastest := slices.Min(t.delays)
		extra := make([]float64, len(t.delays))
		for i, d := range t.delays {
			extra[i] = d - fastest
		}
		parts = append(parts, "retard en plus "+spread(extra))
	}
	if len(t.roundTrips) > 0 {
		parts = append(parts, "aller-retour "+spread(t.roundTrips))
	}
	if t.lost+t.late > 0 {
		parts = append(parts, fmt.Sprintf("%d perdus, %d en retard", t.lost, t.late))
	}
	return strings.Join(parts, " · ")
}

// spread : médiane, 95 % et maximum, en ms.
func spread(values []float64) string {
	sorted := slices.Sorted(slices.Values(values))
	at := func(q float64) float64 { return sorted[int(q*float64(len(sorted)-1))] }
	return fmt.Sprintf("%.0f / %.0f / %.0f ms", at(0.5), at(0.95), sorted[len(sorted)-1])
}

// notePing retient l'aller-retour (ms) que le téléphone a glissé dans sa mesure du délai ; 0 : pas encore mesuré.
func (s *server) notePing(p *player, roundTrip uint32) {
	if roundTrip == 0 {
		return
	}
	s.mu.Lock()
	p.stats.roundTrips = append(p.stats.roundTrips, float64(roundTrip))
	s.mu.Unlock()
}

// reportStats note toutes les `every` la mesure de chaque manette connectée.
func (s *server) reportStats(every time.Duration) {
	type line struct {
		who, link string
		stats     linkStats
	}
	for range time.Tick(every) {
		var lines []line
		s.mu.Lock()
		for i, p := range s.seats {
			if p == nil {
				continue
			}
			link := "WebSocket (Cloudflare)"
			if p.direct != nil {
				link = "directe"
			}
			lines = append(lines, line{fmt.Sprintf("%s, Wii Remote %d", displayName(p.name), i+1), link, p.stats.take()})
		}
		s.mu.Unlock()
		for _, l := range lines {
			if sum := l.stats.summary(every); sum != "" {
				log.Printf("%s, liaison %s : %s", l.who, l.link, sum)
			}
		}
	}
}

// displayName : le prénom du joueur, ou un repère s'il n'en a pas donné.
func displayName(name string) string {
	if name == "" {
		return "(sans prénom)"
	}
	return name
}
