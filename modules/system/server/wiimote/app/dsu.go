package main

// Protocole DSU (cemuhook), côté serveur, tel que Dolphin le lit :
// Source/Core/InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPProto.h.

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"math"
	"math/rand/v2"
	"net"
	"sync"
	"time"
)

const (
	protocolVersion = 1001
	msgPorts        = 0x100001
	msgPadData      = 0x100002
	// (Non officiel) vibration d'un moteur de la manette, envoyée par le Dolphin corrigé (module dolphin-emu).
	msgRumble = 0x110002
	// Dolphin la renvoie toutes les 200 ms : sans nouvelle pendant ce temps (Dolphin fermé, réseau coupé), le
	// téléphone arrête de vibrer.
	rumbleTimeout = time.Second
	slots         = 4
	// Dolphin se réabonne chaque seconde.
	subscriptionTTL = 5 * time.Second
	// Message de la PWA : boutons (u16), 6 float32 déjà dans le repère DSU, pointeur x et y (u16), puis, à partir de
	// countsOffset, le nombre d'appuis de chaque bouton (un octet par bit, modulo 256, cf. buttons.go).
	countsOffset     = 2 + 6*4 + 4
	phoneMessageSize = countsOffset + 16
	// Centre du pointeur sur 16 bits.
	pointerCenter = 1 << 15
	// Nom du serveur saisi dans Dolphin : il fait partie du nom du périphérique (DSUClient/<slot>/<nom>).
	dsuName = "Telephone"
)

var le = binary.LittleEndian

// Bouton de la Wiimote (bit i du message de la PWA) → entrée DSU que lit Dolphin, et contrôle du profil.
// Dolphin lit les faces et la croix en analogique ; les bits numériques servent aux autres clients DSU.
var buttons = [...]struct {
	control, input      string
	analog, digitalByte int
	digitalMask         byte
}{
	{"Buttons/A", "Cross", 49, 37, 0x40},
	{"Buttons/B", "Circle", 50, 37, 0x20},
	{"Buttons/1", "Square", 48, 37, 0x80},
	{"Buttons/2", "Triangle", 51, 37, 0x10},
	{"Buttons/-", "Share", 0, 36, 0x01},
	{"Buttons/+", "Options", 0, 36, 0x08},
	{"Buttons/Home", "PS", 0, 38, 0x01},
	{"D-Pad/Up", "Pad N", 47, 36, 0x10},
	{"D-Pad/Down", "Pad S", 45, 36, 0x40},
	{"D-Pad/Left", "Pad W", 44, 36, 0x80},
	{"D-Pad/Right", "Pad E", 46, 36, 0x20},
}

type padState struct {
	buttons uint16
	// accel x, y, z (g), gyro tangage, lacet, roulis (°/s), dans l'ordre du paquet.
	motion [6]float32
	// Pointeur calculé par le téléphone : x, y (y vers le haut), sur 16 bits, `pointerCenter` au centre.
	pointer [2]uint16
	// Nombre d'appuis de chaque bouton (bit), si le téléphone les compte (counted).
	presses [16]uint8
	counted bool
}

type subscriber struct {
	addr  net.Addr
	mask  uint8
	until time.Time
}

type server struct {
	conn  net.PacketConn
	id    uint32
	start time.Time

	mu sync.Mutex
	// Téléphone de chaque slot (nil : libre), cf. players.go.
	seats   [slots]*player
	pads    [slots]padState
	counter [slots]uint32
	// Appuis rejoués à Dolphin, et le réveil qui relâche un bouton sans attendre de message, cf. buttons.go.
	hold  [slots]buttonHold
	wakes [slots]*time.Timer
	// Arrêt de la vibration de chaque slot si Dolphin se tait, cf. rumble.
	rumbleStop [slots]*time.Timer
	subs       map[string]*subscriber
	// Jeton du lien d'invitation des téléphones, et le fichier qui le garde entre deux redémarrages (keepInvite).
	invite     string
	inviteFile string
	// Adresse de la liaison directe donnée aux téléphones (direct.go), vide sans elle.
	directURL string
}

func newServer(conn net.PacketConn) *server {
	s := &server{conn: conn, id: rand.Uint32(), start: time.Now(), subs: map[string]*subscriber{}}
	s.newInvite()
	return s
}

// Adresse localement administrée, stable par slot : Dolphin compare les MAC pour repérer un changement de manette.
func mac(slot int) []byte { return []byte{0x02, 'W', 'i', 'i', 0, byte(slot)} }

func (s *server) packet(size int, msgType uint32) []byte {
	buf := make([]byte, size)
	copy(buf, "DSUS")
	le.PutUint16(buf[4:], protocolVersion)
	le.PutUint16(buf[6:], uint16(size-16))
	le.PutUint32(buf[12:], s.id)
	le.PutUint32(buf[16:], msgType)
	return buf
}

// CRC32 zlib du paquet entier, champ CRC à zéro.
func seal(buf []byte) []byte {
	le.PutUint32(buf[8:], 0)
	le.PutUint32(buf[8:], crc32.ChecksumIEEE(buf))
	return buf
}

func padInfo(buf []byte, slot int, connected bool) {
	buf[20] = byte(slot)
	if connected {
		buf[21], buf[22], buf[23] = 2, 2, 2 // connecté, gyroscope complet, Bluetooth
	}
	copy(buf[24:30], mac(slot))
}

func (s *server) portInfo(slot int, connected bool) []byte {
	buf := s.packet(32, msgPorts)
	padInfo(buf, slot, connected)
	return seal(buf)
}

func (s *server) padData(slot int, st padState, counter uint32) []byte {
	buf := s.packet(100, msgPadData)
	padInfo(buf, slot, true)
	buf[31] = 1
	le.PutUint32(buf[32:], counter)
	buf[42], buf[40] = pointerBytes(st.pointer[0])
	buf[43], buf[41] = pointerBytes(st.pointer[1])
	for i, b := range buttons {
		if st.buttons&(1<<i) == 0 {
			continue
		}
		if b.analog != 0 {
			buf[b.analog] = 255
		}
		buf[b.digitalByte] |= b.digitalMask
	}
	le.PutUint64(buf[68:], uint64(time.Since(s.start).Microseconds()))
	for i, v := range st.motion {
		le.PutUint32(buf[76+4*i:], math.Float32bits(v))
	}
	return seal(buf)
}

func (s *server) serveDSU() error {
	buf := make([]byte, 1500)
	for {
		n, from, err := s.conn.ReadFrom(buf)
		if err != nil {
			return err
		}
		s.handleRequest(buf[:n], from)
	}
}

func (s *server) handleRequest(pkt []byte, from net.Addr) {
	if len(pkt) < 20 || string(pkt[:4]) != "DSUC" {
		return
	}
	size := 16 + int(le.Uint16(pkt[6:]))
	if size < 20 || size > len(pkt) {
		return
	}
	pkt = pkt[:size]
	crc := le.Uint32(pkt[8:])
	le.PutUint32(pkt[8:], 0)
	if crc32.ChecksumIEEE(pkt) != crc {
		return
	}

	switch le.Uint32(pkt[16:]) {
	case msgPorts:
		if len(pkt) < 24 {
			return
		}
		count := int(int32(le.Uint32(pkt[20:])))
		for i := 0; i < count && 24+i < len(pkt); i++ {
			slot := int(pkt[24+i])
			if slot < slots {
				s.mu.Lock()
				connected := s.seats[slot] != nil
				s.mu.Unlock()
				s.conn.WriteTo(s.portInfo(slot, connected), from)
			}
		}
	case msgPadData:
		if len(pkt) < 28 {
			return
		}
		s.subscribe(from, pkt[20], pkt[21], pkt[22:28])
	case msgRumble:
		// Manette désignée comme pour msgPadData, par son slot (Dolphin), puis moteur (un seul) et intensité.
		if len(pkt) < 30 || pkt[20]&1 == 0 || pkt[21] >= slots || pkt[28] != 0 {
			return
		}
		s.rumble(int(pkt[21]), pkt[29])
	}
}

// flags : 0 tous les slots, bit 0 par numéro de slot, bit 1 par MAC.
func (s *server) subscribe(from net.Addr, flags, slot byte, addr []byte) {
	var mask uint8
	if flags == 0 {
		mask = 1<<slots - 1
	}
	if flags&1 != 0 && slot < slots {
		mask |= 1 << slot
	}
	if flags&2 != 0 {
		for i := range slots {
			if bytes.Equal(addr, mac(i)) {
				mask |= 1 << i
			}
		}
	}

	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	sub := s.subs[from.String()]
	if sub == nil || now.After(sub.until) {
		sub = &subscriber{addr: from}
		s.subs[from.String()] = sub
	}
	sub.mask |= mask
	sub.until = now.Add(subscriptionTTL)
}

// Enregistre l'état d'un slot et prépare son paquet pour les clients abonnés. Sous s.mu ; envoyer ensuite
// avec `broadcast`, hors du verrou.
func (s *server) stateLocked(slot int, st padState) (pkt []byte, targets []net.Addr) {
	now := time.Now()
	s.pads[slot] = st
	buttons, wake := s.hold[slot].next(st, now)
	if !wake.IsZero() {
		if t := s.wakes[slot]; t != nil {
			t.Stop()
		}
		s.wakes[slot] = time.AfterFunc(wake.Sub(now), func() { s.replay(slot) })
	}
	st.buttons = buttons
	s.counter[slot]++
	pkt = s.padData(slot, st, s.counter[slot])
	for key, sub := range s.subs {
		if now.After(sub.until) {
			delete(s.subs, key)
		} else if sub.mask&(1<<slot) != 0 {
			targets = append(targets, sub.addr)
		}
	}
	return pkt, targets
}

// Renvoie l'état du slot tel quel : un bouton à relâcher ou un appui en attente (buttons.go).
func (s *server) replay(slot int) {
	s.mu.Lock()
	if s.seats[slot] == nil {
		s.mu.Unlock()
		return
	}
	pkt, targets := s.stateLocked(slot, s.pads[slot])
	s.mu.Unlock()
	s.broadcast(pkt, targets)
}

func (s *server) broadcast(pkt []byte, targets []net.Addr) {
	for _, addr := range targets {
		s.conn.WriteTo(pkt, addr)
	}
}

// pointerBytes répartit un axe du pointeur (16 bits) sur deux sticks DSU d'un octet : le droit pour le gros, le
// gauche pour le reste, au 254e de pas ; le profil les additionne (`Right X+` + `Left X+` / 254). Dolphin lit un
// octet b comme (b-128)/127 au-dessus du centre, (b-128)/128 en dessous.
func pointerBytes(p uint16) (coarse, fine byte) {
	v := float64(p)/(1<<16-1)*2 - 1
	toByte := func(x float64) byte {
		if x >= 0 {
			return byte(min(255, 128+math.Round(x*127)))
		}
		return byte(max(0, 128+math.Round(x*128)))
	}
	coarse = toByte(v)
	return coarse, toByte((v - stickValue(coarse)) * 254)
}

// stickValue : la valeur que Dolphin lit pour un octet de stick DSU.
func stickValue(b byte) float64 {
	if b >= 128 {
		return float64(b-128) / 127
	}
	return (float64(b) - 128) / 128
}

func decode(msg []byte) (padState, bool) {
	var st padState
	if len(msg) != phoneMessageSize {
		return st, false
	}
	st.buttons = le.Uint16(msg)
	for i := range st.motion {
		v := math.Float32frombits(le.Uint32(msg[2+4*i:]))
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
			v = 0
		}
		st.motion[i] = v
	}
	for i := range st.pointer {
		st.pointer[i] = le.Uint16(msg[2+6*4+2*i:])
	}
	copy(st.presses[:], msg[countsOffset:])
	st.counted = true
	return st, true
}
