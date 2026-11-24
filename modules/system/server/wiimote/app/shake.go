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

// Vraie secousse, relevée sur le téléphone à plat (haut = −y), celle qui fait voler le casque hélice de Mario :
// accélération (g, repère DSU) au fil des ms. Rejouée avec sa courbe : les mêmes valeurs en paliers plats ne
// suffisaient pas au jeu, qui regarde comment la mesure varie d'une image à l'autre.
var shakeSamples = [...]struct{ ms, x, y, z float64 }{
	{0, -0.29, -1.13, 0.02}, {17, -0.10, -1.43, 0}, {34, -0.02, -1.57, 0.01}, {51, 0.01, -1.96, 0.03},
	{67, -0.04, -2.22, 0.01}, {85, -0.10, -2.17, 0.01}, {99, -0.27, -1.69, 0}, {116, -0.35, -1.35, 0.01},
	{134, -0.47, -0.56, 0.06}, {150, -0.66, 0.28, -0.01}, {167, -0.77, 0.72, -0.04}, {187, -0.92, 1.92, -0.10},
	{199, -1.07, 2.51, -0.17}, {216, -1.12, 2.35, -0.22}, {232, -0.88, 1.84, -0.08}, {249, -0.41, 0.84, 0.19},
	{267, -0.02, 0.13, 0.28}, {281, 0.80, -1.50, 0.23}, {298, 1.17, -2.67, -0.02}, {315, 1.09, -2.81, -0.13},
	{332, 0.64, -2.80, -0.04}, {350, 0.07, -2.65, 0.11}, {365, -0.23, -2.51, 0.12}, {382, -0.62, -2.00, 0.07},
	{400, -0.66, -1.44, 0.12}, {417, -0.56, -1.21, 0.15}, {432, -0.41, -0.87, 0.12},
}

var shakeDuration = time.Duration(shakeSamples[len(shakeSamples)-1].ms) * time.Millisecond

// Rythme d'envoi pendant la secousse : Dolphin lit la Wiimote à 200 Hz.
const shakeTick = 5 * time.Millisecond

// shaken remplace l'accélération mesurée (g) par celle de la secousse, `t` après l'appui, tournée pour que son
// « haut » soit celui de la mesure : la même secousse quelle que soit la tenue. Gyroscope inchangé : les jeux ne
// lisent que l'accéléromètre de la Wiimote.
func shaken(motion [6]float32, t time.Duration) [6]float32 {
	g := [3]float64{float64(motion[0]), float64(motion[1]), float64(motion[2])}
	n := math.Sqrt(dot(g, g))
	ms := float64(t) / float64(time.Millisecond)
	if n == 0 || ms < 0 || ms > shakeSamples[len(shakeSamples)-1].ms {
		return motion
	}
	i := 1
	for shakeSamples[i].ms < ms {
		i++
	}
	a, b := shakeSamples[i-1], shakeSamples[i]
	f := (ms - a.ms) / (b.ms - a.ms)
	v := [3]float64{a.x + (b.x-a.x)*f, a.y + (b.y-a.y)*f, a.z + (b.z-a.z)*f}
	v = rotate(v, [3]float64{0, -1, 0}, [3]float64{g[0] / n, g[1] / n, g[2] / n})
	motion[0], motion[1], motion[2] = float32(v[0]), float32(v[1]), float32(v[2])
	return motion
}

// rotate applique à v la plus petite rotation qui amène le vecteur unitaire `from` sur `to` (Rodrigues).
func rotate(v, from, to [3]float64) [3]float64 {
	c := dot(from, to)
	if c < -0.999999 { // demi-tour : autour d'un axe perpendiculaire à `from` = (0, −1, 0), ici x
		return [3]float64{v[0], -v[1], -v[2]}
	}
	k := cross(from, to)
	kv := cross(k, v)
	f := dot(k, v) / (1 + c)
	return [3]float64{v[0]*c + kv[0] + k[0]*f, v[1]*c + kv[1] + k[1]*f, v[2]*c + kv[2] + k[2]*f}
}

func dot(a, b [3]float64) float64 { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2] }

func cross(a, b [3]float64) [3]float64 {
	return [3]float64{a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]}
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
