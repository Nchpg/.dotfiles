package main

import (
	"strings"
	"testing"
	"time"
)

func TestLinkStats(t *testing.T) {
	// Un état toutes les 16 ms, horloge du téléphone décalée de 5 s ; les 4e à 6e retenus puis livrés ensemble ;
	// le 7e perdu ; un doublon du 3e en retard. Puis le téléphone mesure 20, 24 et 60 ms d'aller-retour.
	var l linkStats
	start := time.Unix(1000, 0)
	for i, held := range []int{0, 0, 0, 40, 24, 8, -1, 0} {
		if held >= 0 {
			l.datagram(uint32(i+1), uint32(5000+16*i), start.Add(time.Duration(16*i+held)*time.Millisecond))
		}
	}
	l.datagram(3, 5032, start.Add(200*time.Millisecond))
	l.roundTrips = []float64{20, 24, 60}
	got := l.take().summary(time.Second)
	for _, want := range []string{"7 états/s", "écart 16 / 24 / 56 ms", "retard en plus 0 / 24 / 40 ms",
		"aller-retour 24 / 24 / 60 ms", "1 perdus, 1 en retard"} {
		if !strings.Contains(got, want) {
			t.Errorf("%q sans %q", got, want)
		}
	}
	// Fenêtre suivante : repartie de zéro, mais la suite des numéros continue.
	if l.take().summary(time.Second) != "" {
		t.Fatal("fenêtre pas remise à zéro")
	}
	l.datagram(9, 5128, start.Add(time.Second))
	if l.lost != 0 || l.late != 0 {
		t.Fatalf("suite des numéros perdue : %d perdus, %d en retard", l.lost, l.late)
	}
	// Par le WebSocket : cadence et écarts seulement.
	var ws linkStats
	for i := range 5 {
		ws.state(start.Add(time.Duration(20*i) * time.Millisecond))
	}
	if got := ws.summary(time.Second); !strings.Contains(got, "écart 20 / 20 / 20 ms") || strings.Contains(got, "retard") {
		t.Fatalf("WebSocket : %q", got)
	}
}
