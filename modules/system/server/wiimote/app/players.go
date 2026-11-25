package main

// Téléphones connectés et leur place : le slot DSU, donc la Wii Remote de Dolphin. L'hôte peut
// les réordonner et en retirer depuis /dolphin.

import (
	"crypto/rand"
	"net"
	"strings"
	"unicode"

	"github.com/quic-go/webtransport-go"
	"golang.org/x/net/websocket"
)

const maxNameLength = 24

type player struct {
	name string
	conn *websocket.Conn
	// Place actuelle, -1 une fois parti. Lue et écrite sous s.mu.
	slot int
	// Liaison directe (direct.go) : jeton qui l'ouvre, session ouverte et dernier numéro de datagramme appliqué,
	// sous s.mu.
	token  string
	direct *webtransport.Session
	seq    uint32
}

// Nom tapé sur le téléphone, affiché sur la page de l'hôte : sans caractères de contrôle, borné.
func cleanName(name string) string {
	name = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, name))
	if r := []rune(name); len(r) > maxNameLength {
		name = string(r[:maxNameLength])
	}
	return name
}

// Toujours la première place libre : Dolphin lit les slots 0, 1… pour les Wii Remote 1, 2…, un trou laisserait
// une manette sans Wii Remote. Un téléphone qui se reconnecte retrouve sa place une fois l'ancienne libérée.
func (s *server) claim(name string, conn *websocket.Conn) *player {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range slots {
		if s.seats[i] == nil {
			p := &player{name: cleanName(name), conn: conn, slot: i, token: rand.Text()}
			s.seats[i] = p
			// Rien du joueur précédent ; pointeur au centre tant que le téléphone n'a rien envoyé.
			s.pads[i] = padState{pointer: [2]uint16{pointerCenter, pointerCenter}}
			return p
		}
	}
	return nil
}

// État reçu du téléphone, rediffusé sur la place qu'il occupe à cet instant (l'hôte a pu la changer).
func (s *server) push(p *player, st padState) {
	s.mu.Lock()
	if p.slot < 0 {
		s.mu.Unlock()
		return
	}
	pkt, targets := s.stateLocked(p.slot, st)
	s.mu.Unlock()
	s.broadcast(pkt, targets)
}

// Libère la place en relâchant ses boutons : sans ça, Dolphin garderait « 2 » enfoncé jusqu'à la
// disparition du périphérique.
func (s *server) release(p *player) {
	s.mu.Lock()
	slot := p.slot
	if slot < 0 {
		s.mu.Unlock()
		return
	}
	p.slot = -1
	s.seats[slot] = nil
	pkt, targets := s.releasedLocked(slot)
	sess := p.direct
	s.mu.Unlock()
	s.broadcast(pkt, targets)
	if sess != nil {
		sess.CloseWithError(0, "manette partie")
	}
}

func (s *server) releasedLocked(slot int) ([]byte, []net.Addr) {
	st := s.pads[slot]
	st.buttons = 0
	return s.stateLocked(slot, st)
}

// Échange deux places, occupées ou non. Chaque téléphone déplacé apprend son nouveau numéro (ses diodes) ;
// une place laissée vide relâche ses boutons.
func (s *server) swap(a, b int) {
	s.mu.Lock()
	s.seats[a], s.seats[b] = s.seats[b], s.seats[a]
	s.pads[a], s.pads[b] = s.pads[b], s.pads[a]
	s.shakeStart[a], s.shakeStart[b] = s.shakeStart[b], s.shakeStart[a]
	var moved []*player
	var packets [][]byte
	var targets [][]net.Addr
	for _, i := range []int{a, b} {
		if p := s.seats[i]; p != nil {
			p.slot = i
			moved = append(moved, p)
			continue
		}
		pkt, t := s.releasedLocked(i)
		packets, targets = append(packets, pkt), append(targets, t)
	}
	notes := make([]map[string]int, len(moved))
	for i, p := range moved {
		notes[i] = map[string]int{"slot": p.slot}
	}
	s.mu.Unlock()

	for i := range packets {
		s.broadcast(packets[i], targets[i])
	}
	for i, p := range moved {
		websocket.JSON.Send(p.conn, notes[i])
	}
}

// Déconnecte le téléphone d'une place. Il ne se reconnecte pas tout seul : il lui faut rescanner le QR code
// (« Nouveau lien » pour l'en empêcher).
func (s *server) kick(slot int) {
	s.mu.Lock()
	p := s.seats[slot]
	s.mu.Unlock()
	if p == nil {
		return
	}
	websocket.JSON.Send(p.conn, map[string]any{"error": "Retiré par l'hôte.", "retry": false})
	// Sa boucle de lecture s'arrête et libère la place.
	p.conn.Close()
}

type seatInfo struct {
	Name string `json:"name"`
}

// Places pour la page de l'hôte : nil pour une place libre.
func (s *server) players() []*seatInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*seatInfo, slots)
	for i, p := range s.seats {
		if p != nil {
			out[i] = &seatInfo{Name: p.name}
		}
	}
	return out
}
