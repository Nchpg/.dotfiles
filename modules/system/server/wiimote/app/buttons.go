package main

// Appuis joués à Dolphin. Le réseau perd, groupe ou inverse des messages (Wi-Fi en économie d'énergie, rafales) :
// l'appui et le relâché d'un tapotement peuvent arriver ensemble, ou jamais, et le jeu, qui lit la manette une fois
// par image (16 ms), ne verrait pas le bouton enfoncé. Le téléphone compte donc ses appuis (un compteur par bouton,
// dans chaque message) et le serveur rejoue chacun : au moins 50 ms enfoncé, puis 30 ms relâché avant le suivant,
// et tant que le doigt reste dessus. Secouer reste enfoncé le temps de la secousse : chaque appui en joue une
// entière (shake.go).

import "time"

const (
	minPress   = 50 * time.Millisecond
	minRelease = 30 * time.Millisecond
	// Appuis en attente au plus (8 : 0,6 s de rejeu, de quoi tenir des rafales de 300 ms en tapotant vite) : au-delà
	// (réseau coupé plusieurs secondes), les rejouer n'aurait plus de sens. Pour Secouer, un seul : des secousses en
	// file partiraient de plus en plus tard (une figure de Mario Kart hors de propos) ; tapoter plus vite qu'une
	// secousse en joue une, puis la suivante, pas davantage.
	maxQueued      = 8
	maxQueuedShake = 1
)

type buttonHold struct {
	// Boutons et compteurs du dernier message reçu ; started : compteurs déjà reçus une fois.
	in      uint16
	count   [16]uint8
	started bool
	// Boutons envoyés à Dolphin, instant du dernier changement de chacun, appuis reçus pas encore joués.
	out    uint16
	since  [16]time.Time
	queued [16]uint8
}

// next : boutons à envoyer à `now` d'après le message reçu `st` (le même s'il n'y a rien de nouveau), et l'instant
// où ils pourront encore changer sans nouveau message (zéro sinon).
func (h *buttonHold) next(st padState, now time.Time) (uint16, time.Time) {
	for b := range 16 {
		bit := uint16(1) << b
		fresh := 0
		switch {
		case st.counted && h.started:
			fresh = int(st.presses[b] - h.count[b]) // modulo 256
		case st.buttons&bit != 0 && h.in&bit == 0:
			// Premier message, ou page restée en cache sans compteurs : les fronts.
			fresh = 1
		}
		limit := maxQueued
		if bit == shakeBit {
			// Celle qui part tout de suite si aucune ne joue, plus celles en attente.
			limit = maxQueuedShake
			if h.out&bit == 0 {
				limit++
			}
		}
		h.queued[b] = uint8(min(limit, int(h.queued[b])+fresh))
	}
	h.in = st.buttons
	if st.counted {
		h.count, h.started = st.presses, true
	}

	var wake time.Time
	later := func(at time.Time) {
		if wake.IsZero() || at.Before(wake) {
			wake = at
		}
	}
	for b := range 16 {
		bit := uint16(1) << b
		hold := minPress
		if bit == shakeBit {
			hold = shakeDuration
		}
		// Relâcher quand le doigt est parti ou qu'un autre appui attend, l'appui ayant assez duré.
		if h.out&bit != 0 && (h.in&bit == 0 || h.queued[b] > 0) {
			if at := h.since[b].Add(hold); now.Before(at) {
				later(at)
				continue
			}
			h.out &^= bit
			h.since[b] = now
		}
		// Jouer l'appui suivant, le relâché ayant assez duré.
		if h.out&bit == 0 && h.queued[b] > 0 {
			if at := h.since[b].Add(minRelease); now.Before(at) {
				later(at)
				continue
			}
			h.out |= bit
			h.queued[b]--
			h.since[b] = now
			// Le relâcher à temps, sans attendre de message, si le doigt est déjà parti ou qu'un autre appui attend.
			if h.in&bit == 0 || h.queued[b] > 0 {
				later(now.Add(hold))
			}
		}
	}
	return h.out, wake
}
