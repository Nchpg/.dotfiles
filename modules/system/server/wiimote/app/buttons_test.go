package main

import (
	"math/rand/v2"
	"net"
	"slices"
	"testing"
	"time"
)

const bitA = 1 << 0

var t0 = time.Unix(1_000_000, 0)

// Message du téléphone : boutons enfoncés et nombre d'appuis de A.
func msgA(pressed bool, presses uint8) padState {
	st := padState{counted: true}
	st.presses[0] = presses
	if pressed {
		st.buttons = bitA
	}
	return st
}

func ms(n int) time.Time { return t0.Add(time.Duration(n) * time.Millisecond) }

func TestHoldTapArrivedInOneBurst(t *testing.T) {
	// Appui et relâché arrivés ensemble : enfoncé tout de suite, relâché 50 ms plus tard (au réveil prévu).
	var h buttonHold
	h.next(msgA(false, 0), ms(0))
	if out, _ := h.next(msgA(true, 1), ms(100)); out != bitA {
		t.Fatal("appui pas rejoué tout de suite")
	}
	out, wake := h.next(msgA(false, 1), ms(101))
	if out != bitA || !wake.Equal(ms(150)) {
		t.Fatalf("relâché trop tôt (%b), réveil %v", out, wake.Sub(t0))
	}
	if out, _ := h.next(msgA(false, 1), ms(150)); out != 0 {
		t.Fatal("pas relâché après 50 ms")
	}
}

func TestHoldPressWhoseMessagesWereLost(t *testing.T) {
	// Aucun message avec A enfoncé n'est arrivé : le compteur suffit.
	var h buttonHold
	h.next(msgA(false, 4), ms(0))
	if out, _ := h.next(msgA(false, 5), ms(200)); out != bitA {
		t.Fatal("appui perdu")
	}
	if out, _ := h.next(msgA(false, 5), ms(250)); out != 0 {
		t.Fatal("pas relâché")
	}
	// Compteur qui repasse par zéro (modulo 256).
	h.next(msgA(false, 255), ms(300))
	h.next(msgA(false, 255), ms(400))
	if out, _ := h.next(msgA(false, 0), ms(500)); out != bitA {
		t.Fatal("appui perdu au passage de 255 à 0")
	}
}

func TestHoldDoubleTapInOneBurst(t *testing.T) {
	// Deux tapotements arrivés d'un coup : deux appuis de 50 ms, séparés de 30 ms.
	var h buttonHold
	h.next(msgA(false, 0), ms(0))
	h.next(msgA(false, 2), ms(100))
	var timeline []string
	for at := 100; at <= 300; at += 5 {
		out, _ := h.next(msgA(false, 2), ms(at))
		state := "relâché"
		if out != 0 {
			state = "enfoncé"
		}
		if len(timeline) == 0 || timeline[len(timeline)-1] != state {
			timeline = append(timeline, state)
		}
	}
	if want := []string{"enfoncé", "relâché", "enfoncé", "relâché"}; !slices.Equal(timeline, want) {
		t.Fatalf("%v au lieu de %v", timeline, want)
	}
}

func TestHoldLongPressUnchanged(t *testing.T) {
	// Un appui normal passe tel quel, sans retard.
	var h buttonHold
	h.next(msgA(false, 0), ms(0))
	if out, _ := h.next(msgA(true, 1), ms(100)); out != bitA {
		t.Fatal("appui retardé")
	}
	if out, _ := h.next(msgA(true, 1), ms(300)); out != bitA {
		t.Fatal("appui tenu interrompu")
	}
	if out, wake := h.next(msgA(false, 1), ms(301)); out != 0 || !wake.IsZero() {
		t.Fatal("relâché retardé")
	}
}

func TestHoldWithoutCounters(t *testing.T) {
	// Page restée en cache, sans compteurs : les fronts, et la même durée minimale.
	var h buttonHold
	h.next(padState{}, ms(0))
	if out, _ := h.next(padState{buttons: bitA}, ms(10)); out != bitA {
		t.Fatal("appui perdu")
	}
	if out, _ := h.next(padState{}, ms(11)); out != bitA {
		t.Fatal("relâché trop tôt")
	}
	if out, _ := h.next(padState{}, ms(60)); out != 0 {
		t.Fatal("pas relâché")
	}
}

func TestHoldQueueIsBounded(t *testing.T) {
	// Réseau coupé longtemps : vingt appuis d'un coup n'en rejouent que huit.
	var h buttonHold
	h.next(msgA(false, 0), ms(0))
	if got := pressesPlayed(&h, msgA(false, 20), ms(1000), ms(3000)); got != maxQueued {
		t.Fatalf("%d appuis rejoués, attendu %d", got, maxQueued)
	}
}

// Rejoue le bouton A de `from` à `to`, aux réveils demandés, et compte les appuis.
func pressesPlayed(h *buttonHold, st padState, from, to time.Time) int {
	count, last := 0, h.out
	for at := from; !at.After(to); {
		out, wake := h.next(st, at)
		if out&bitA != 0 && last&bitA == 0 {
			count++
		}
		last = out
		if wake.IsZero() {
			break
		}
		at = wake
	}
	return count
}

// Simulation de bout en bout : le joueur appuie au hasard, le téléphone envoie son état à 60 Hz et à chaque
// changement, le réseau le malmène, le serveur le rejoue (buttonHold), et le jeu lit la manette une fois par image.

type message struct {
	seq  uint32
	sent time.Duration
	st   padState
}

type arrival struct {
	at  time.Duration
	msg message
}

type change struct {
	at      time.Duration
	pressed bool
}

// Réseaux : instant d'arrivée d'un message (négatif : perdu) ; ordered : TCP (WebSocket), sinon UDP, où le serveur
// jette un message plus ancien que le dernier reçu ; worst : retard le plus long toléré pour un appui.
var networks = []struct {
	name    string
	ordered bool
	deliver func(r *rand.Rand, sent time.Duration) time.Duration
	worst   time.Duration
}{
	{"réseau parfait", false, func(_ *rand.Rand, s time.Duration) time.Duration { return s + 5*time.Millisecond }, 150 * time.Millisecond},
	{"gigue de 0 à 40 ms (désordre)", false, func(r *rand.Rand, s time.Duration) time.Duration {
		return s + time.Duration(5+r.IntN(40))*time.Millisecond
	}, 200 * time.Millisecond},
	{"10 % perdus", false, lossy(0.1), 250 * time.Millisecond},
	{"40 % perdus", false, lossy(0.4), 400 * time.Millisecond},
	{"rafales : Wi-Fi en veille 300 ms", false, burst(300), 600 * time.Millisecond},
	{"WebSocket en rafales", true, burst(150), 400 * time.Millisecond},
}

func lossy(rate float64) func(*rand.Rand, time.Duration) time.Duration {
	return func(r *rand.Rand, sent time.Duration) time.Duration {
		if r.Float64() < rate {
			return -1
		}
		return sent + time.Duration(5+r.IntN(10))*time.Millisecond
	}
}

// Wi-Fi en économie d'énergie : la radio se réveille toutes les `sleep` ms et envoie d'un coup ce qui attendait.
func burst(sleep int) func(*rand.Rand, time.Duration) time.Duration {
	return func(r *rand.Rand, sent time.Duration) time.Duration {
		period := time.Duration(sleep) * time.Millisecond
		return (sent/period+1)*period + time.Duration(r.IntN(3))*time.Millisecond
	}
}

// Ce que voit Dolphin du bouton `b` (bit) quand le joueur l'enfonce pendant `taps` ([début, fin)), sur ce réseau.
func played(r *rand.Rand, taps [][2]time.Duration, b int, ordered bool, deliver func(*rand.Rand, time.Duration) time.Duration) []change {
	bit := uint16(1) << b
	end := taps[len(taps)-1][1] + time.Second
	// Le téléphone : un message à chaque image de 60 Hz et à chaque changement.
	var events []time.Duration
	for _, tp := range taps {
		events = append(events, tp[0], tp[1])
	}
	for at := time.Duration(0); at < end; at += time.Second / 60 {
		events = append(events, at)
	}
	slices.Sort(events)
	var msgs []message
	var presses uint8
	next := 0
	for i, at := range events {
		for next < len(taps) && taps[next][0] <= at {
			presses, next = presses+1, next+1
		}
		st := padState{counted: true}
		st.presses[b] = presses
		if next > 0 && at < taps[next-1][1] {
			st.buttons = bit
		}
		msgs = append(msgs, message{uint32(i + 1), at, st})
	}
	// Le réseau. En TCP, chaque message attend le précédent.
	var arrivals []arrival
	var previous time.Duration
	for _, m := range msgs {
		at := deliver(r, m.sent)
		if at < 0 {
			continue
		}
		if ordered {
			at = max(at, previous)
			previous = at
		}
		arrivals = append(arrivals, arrival{at, m})
	}
	slices.SortStableFunc(arrivals, func(a, b arrival) int { return int(a.at - b.at) })
	// Le serveur, réveils compris.
	var h buttonHold
	var lastSeq uint32
	var timeline []change
	var current padState
	record := func(out uint16, at time.Duration) {
		pressed := out&bit != 0
		if len(timeline) == 0 || timeline[len(timeline)-1].pressed != pressed {
			timeline = append(timeline, change{at, pressed})
		}
	}
	var wake time.Time
	wakeUntil := func(limit time.Time) {
		for !wake.IsZero() && wake.Before(limit) {
			at := wake
			out, w := h.next(current, at)
			record(out, at.Sub(t0))
			wake = w
		}
	}
	for _, a := range arrivals {
		wakeUntil(t0.Add(a.at))
		if a.msg.seq <= lastSeq {
			continue
		}
		lastSeq, current = a.msg.seq, a.msg.st
		out, w := h.next(current, t0.Add(a.at))
		record(out, a.at)
		wake = w
	}
	wakeUntil(t0.Add(end + 10*time.Second))
	return timeline
}

// Le joueur : appuis au hasard, [début, fin), de 15 ms à `longest`, séparés de `gaps` (ms, au moins, en plus).
func human(r *rand.Rand, total time.Duration, longest int, gaps [2]int) [][2]time.Duration {
	var taps [][2]time.Duration
	for at := 200 * time.Millisecond; at < total; {
		var hold, gap int
		switch r.IntN(4) {
		case 0: // tapotement très bref
			hold, gap = 15+r.IntN(25), gaps[0]+r.IntN(200)
		case 1:
			hold, gap = 40+r.IntN(80), gaps[0]+r.IntN(300)
		case 2: // appui tenu
			hold, gap = 120+r.IntN(longest), gaps[1]+r.IntN(400)
		default: // double tapotement : relâché très court
			hold, gap = 20+r.IntN(40), 20+r.IntN(30)
		}
		taps = append(taps, [2]time.Duration{at, at + time.Duration(hold)*time.Millisecond})
		at += time.Duration(hold+gap) * time.Millisecond
	}
	return taps
}

func TestButtonsSurviveNetwork(t *testing.T) {
	// Le jeu doit voir chaque appui, une seule fois, jamais avant qu'il soit fait.
	for _, nw := range networks {
		var delays []time.Duration
		for seed := range uint64(20) {
			r := rand.New(rand.NewPCG(seed, 7))
			taps := human(r, 60*time.Second, 500, [2]int{40, 60})
			timeline := played(r, taps, 0, nw.ordered, nw.deliver)
			phase := time.Duration(r.IntN(16_667)) * time.Microsecond
			var seen []time.Duration
			was := false
			for frame := phase; frame < 62*time.Second; frame += time.Second / 60 {
				// L'état en vigueur à cette image : le dernier changement au plus tard à `frame`.
				i, _ := slices.BinarySearchFunc(timeline, frame, func(c change, at time.Duration) int { return int(c.at - at) })
				if i == len(timeline) || timeline[i].at > frame {
					i--
				}
				pressed := i >= 0 && timeline[i].pressed
				if pressed && !was {
					seen = append(seen, frame)
				}
				was = pressed
			}
			if len(seen) != len(taps) {
				t.Fatalf("%s, graine %d : le jeu a vu %d appuis sur %d", nw.name, seed, len(seen), len(taps))
			}
			for i, tp := range taps {
				if seen[i] < tp[0] {
					t.Fatalf("%s, graine %d : appui %d vu avant d'être fait", nw.name, seed, i)
				}
				delays = append(delays, seen[i]-tp[0])
			}
		}
		slices.Sort(delays)
		p := func(q float64) time.Duration { return delays[int(q*float64(len(delays)-1))].Round(time.Millisecond) }
		t.Logf("%-32s %d appuis, tous vus ; retard médian %v, 99 %% sous %v, pire %v", nw.name, len(delays), p(0.5), p(0.99), p(1))
		if p(1) > nw.worst {
			t.Errorf("%s : un appui vu %v après, au-delà de %v", nw.name, p(1), nw.worst)
		}
	}
}

func TestServerReleasesTapOnTime(t *testing.T) {
	// Le vrai serveur : appui et relâché d'un tapotement reçus coup sur coup ; Dolphin voit A enfoncé, puis relâché
	// 50 ms plus tard sans autre message du téléphone (réveil).
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	dolphin, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dolphin.Close()
	s := newServer(conn)
	p := s.claim("test", nil)
	s.mu.Lock()
	s.subs[dolphin.LocalAddr().String()] = &subscriber{addr: dolphin.LocalAddr(), mask: 1, until: time.Now().Add(time.Minute)}
	s.mu.Unlock()

	start := time.Now()
	s.push(p, msgA(false, 0))
	s.push(p, msgA(true, 1))
	s.push(p, msgA(false, 1))
	buf := make([]byte, 200)
	var states []bool
	var releasedAfter time.Duration
	for len(states) < 4 {
		dolphin.SetReadDeadline(time.Now().Add(time.Second))
		n, _, err := dolphin.ReadFrom(buf)
		if err != nil {
			t.Fatalf("%v après %v", err, states)
		}
		if n == 100 {
			states = append(states, buf[49] == 255)
			if len(states) == 4 {
				releasedAfter = time.Since(start)
			}
		}
	}
	if want := []bool{false, true, true, false}; !slices.Equal(states, want) {
		t.Fatalf("A vu %v, attendu %v", states, want)
	}
	if releasedAfter < 45*time.Millisecond || releasedAfter > 150*time.Millisecond {
		t.Fatalf("relâché après %v, attendu vers 50 ms", releasedAfter)
	}
	s.release(p)
}

func TestDecodeCounts(t *testing.T) {
	// Message de la PWA : les compteurs après les 30 premiers octets.
	msg := make([]byte, phoneMessageSize)
	msg[countsOffset] = 7
	msg[countsOffset+11] = 2
	st, ok := decode(msg)
	if !ok || !st.counted || st.presses[0] != 7 || st.presses[11] != 2 {
		t.Fatalf("compteurs mal lus : %v %v", st.counted, st.presses)
	}
}
