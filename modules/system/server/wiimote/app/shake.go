package main

// Secousse jouée par le serveur. Le téléphone ne signale que l'appui sur Secouer : envoyée de là-bas, le wifi et
// le tunnel retenaient puis relâchaient d'un coup ses paquets, et l'aller-retour que demande Mario (casque hélice)
// disparaissait. D'ici, Dolphin la reçoit au rythme voulu, par le VPN.

import (
	"math"
	"time"
)

// Bit du bouton Secouer dans le message du téléphone, juste après ceux de `buttons` : aucune entrée DSU.
const shakeBit = 1 << len(buttons)

// Relevée sur un vrai téléphone, celle qui fait voler le casque hélice de Mario : la mesure vers le haut passe à
// +2,2 g, puis −2,5 g (la main redescend plus vite que la chute), puis +2,8 g.
var shakeSteps = [...]struct {
	end time.Duration
	up  float32
}{
	{90 * time.Millisecond, 2.2},
	{190 * time.Millisecond, -2.5},
	{320 * time.Millisecond, 2.8},
	{380 * time.Millisecond, 1.6},
}

var shakeDuration = shakeSteps[len(shakeSteps)-1].end

// Rythme d'envoi pendant la secousse : Dolphin lit la Wiimote à 200 Hz.
const shakeTick = 5 * time.Millisecond

// shaken remplace l'accélération mesurée (g) par celle de la secousse, `t` après l'appui, dans son sens : le haut
// réel quelle que soit la tenue. Gyroscope inchangé : les jeux ne lisent que l'accéléromètre de la Wiimote.
func shaken(motion [6]float32, t time.Duration) [6]float32 {
	g := float32(math.Sqrt(float64(motion[0]*motion[0] + motion[1]*motion[1] + motion[2]*motion[2])))
	if t < 0 || g == 0 {
		return motion
	}
	for _, step := range shakeSteps {
		if t < step.end {
			k := step.up / g
			motion[0], motion[1], motion[2] = motion[0]*k, motion[1]*k, motion[2]*k
			break
		}
	}
	return motion
}

// playShake renvoie l'état du slot pendant la secousse sans attendre le téléphone, puis une fois après, pour que
// Dolphin retrouve la mesure réelle. S'arrête si le joueur part ou si une autre secousse commence.
func (s *server) playShake(slot int, start time.Time) {
	ticker := time.NewTicker(shakeTick)
	defer ticker.Stop()
	for range ticker.C {
		s.mu.Lock()
		if s.seats[slot] == nil || !s.shakeStart[slot].Equal(start) {
			s.mu.Unlock()
			return
		}
		pkt, targets := s.stateLocked(slot, s.pads[slot])
		done := time.Since(start) > shakeDuration
		s.mu.Unlock()
		s.broadcast(pkt, targets)
		if done {
			return
		}
	}
}
