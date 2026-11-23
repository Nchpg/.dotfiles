package main

import (
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/websocket"
)

// Requête client comme Dolphin la construit (DualShockUDPProto.h), CRC compris.
func request(msgType uint32, body ...byte) []byte {
	buf := make([]byte, 20+len(body))
	copy(buf, "DSUC")
	le.PutUint16(buf[4:], protocolVersion)
	le.PutUint16(buf[6:], uint16(len(buf)-16))
	le.PutUint32(buf[16:], msgType)
	copy(buf[20:], body)
	le.PutUint32(buf[8:], crc32.ChecksumIEEE(buf))
	return buf
}

func checkSealed(t *testing.T, pkt []byte, size int) {
	t.Helper()
	if len(pkt) != size || string(pkt[:4]) != "DSUS" || int(le.Uint16(pkt[6:])) != size-16 {
		t.Fatalf("en-tête invalide : %x", pkt[:16])
	}
	crc := le.Uint32(pkt[8:])
	copied := append([]byte(nil), pkt...)
	le.PutUint32(copied[8:], 0)
	if crc32.ChecksumIEEE(copied) != crc {
		t.Fatal("CRC invalide")
	}
}

func TestPadDataLayout(t *testing.T) {
	s := newServer(nil)
	st := padState{buttons: 1<<0 | 1<<4 | 1<<7, motion: [6]float32{0.5, -1, 0.25, 10, -20, 30}, pointer: [2]byte{200, 30}}
	pkt := s.padData(2, st, 7)
	checkSealed(t, pkt, 100)

	// Offsets de PadDataResponse : A → Cross (49), - → Share (bit 0 de 36), Up → Pad N (47).
	if pkt[20] != 2 || pkt[21] != 2 || pkt[31] != 1 || le.Uint32(pkt[32:]) != 7 {
		t.Fatalf("slot, état ou compteur faux : %v", pkt[20:36])
	}
	if pkt[49] != 255 || pkt[47] != 255 || pkt[36] != 0x11 || pkt[37] != 0x40 || pkt[50] != 0 {
		t.Fatalf("boutons faux : %v", pkt[36:56])
	}
	// Stick gauche au centre, pointeur sur le stick droit.
	if pkt[40] != 128 || pkt[41] != 128 || pkt[42] != 200 || pkt[43] != 30 {
		t.Fatalf("sticks faux : %v", pkt[40:44])
	}
	for i, want := range st.motion {
		if got := math.Float32frombits(le.Uint32(pkt[76+4*i:])); got != want {
			t.Fatalf("mouvement %d : %v au lieu de %v", i, got, want)
		}
	}
}

func TestDecodeRejectsBadInput(t *testing.T) {
	if _, ok := decode(make([]byte, phoneMessageSize+1)); ok {
		t.Fatal("taille fausse acceptée")
	}
	msg := make([]byte, phoneMessageSize)
	binary.LittleEndian.PutUint32(msg[2:], math.Float32bits(float32(math.NaN())))
	if st, ok := decode(msg); !ok || st.motion[0] != 0 {
		t.Fatal("NaN non neutralisé")
	}
}

func TestProfile(t *testing.T) {
	p := profile(1)
	for _, want := range []string{"Device = DSUClient/1/Telephone", "Buttons/2 = `Triangle`", "D-Pad/Up = `Pad N`",
		"IMUAccelerometer/Forward = `Accel Forward`", "IMUGyroscope/Yaw Right = `Gyro Yaw Right`",
		"IR/Up = `Right Y+`", "IR/Left = `Right X-`", "IMUIR/Enabled = False"} {
		if !strings.Contains(p, want) {
			t.Errorf("profil sans %q :\n%s", want, p)
		}
	}
}

func TestHostPages(t *testing.T) {
	s := newServer(nil)
	h := s.routes("10.8.0.1", "26760")
	get := func(path string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", "https://wii.example"+path, nil))
		return w
	}

	if body := get("/dolphin").Body.String(); !strings.Contains(body, "https://wii.example/#"+s.currentInvite()) ||
		!strings.Contains(body, "10.8.0.1") {
		t.Fatal("page de l'hôte sans lien d'invitation ou sans adresse DSU")
	}
	if png := get("/dolphin/qr.png").Body.Bytes(); len(png) < 8 || string(png[1:4]) != "PNG" {
		t.Fatal("QR code absent")
	}

	// Révocation depuis un autre site : refusée ; depuis la page : nouveau jeton.
	old := s.currentInvite()
	forged := httptest.NewRequest("POST", "https://wii.example/dolphin/invite", nil)
	forged.Header.Set("Sec-Fetch-Site", "cross-site")
	h.ServeHTTP(httptest.NewRecorder(), forged)
	if s.currentInvite() != old {
		t.Fatal("lien révoqué par un site tiers")
	}
	own := httptest.NewRequest("POST", "https://wii.example/dolphin/invite", nil)
	own.Header.Set("Sec-Fetch-Site", "same-origin")
	h.ServeHTTP(httptest.NewRecorder(), own)
	if s.currentInvite() == old {
		t.Fatal("lien non renouvelé")
	}
}

// L'hôte voit les joueurs, échange leurs places et en retire depuis /dolphin.
func TestHostManagesPlayers(t *testing.T) {
	s := newServer(nil)
	web := httptest.NewServer(s.routes("10.8.0.1", "26760"))
	defer web.Close()
	wsURL := "ws" + strings.TrimPrefix(web.URL, "http") + "/ws"

	type message struct {
		Slot  int
		Error string
		Retry bool
	}
	next := func(ws *websocket.Conn) message {
		t.Helper()
		var m message
		ws.SetReadDeadline(time.Now().Add(2 * time.Second))
		if err := websocket.JSON.Receive(ws, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	join := func(name string) *websocket.Conn {
		t.Helper()
		ws, err := websocket.Dial(wsURL, "", web.URL)
		if err != nil {
			t.Fatal(err)
		}
		websocket.JSON.Send(ws, hello{Invite: s.currentInvite(), Name: name})
		next(ws)
		return ws
	}
	list := func() []*seatInfo {
		t.Helper()
		resp, err := http.Get(web.URL + "/dolphin/players")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var seats []*seatInfo
		json.NewDecoder(resp.Body).Decode(&seats)
		return seats
	}
	post := func(path, body string) int {
		t.Helper()
		resp, err := http.Post(web.URL+path, "application/x-www-form-urlencoded", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}

	alice := join(" Alice\x07 ")
	bob := join(strings.Repeat("é", 40))
	if seats := list(); seats[0].Name != "Alice" || len([]rune(seats[1].Name)) != maxNameLength || seats[2] != nil {
		t.Fatalf("places : %+v %+v %+v", seats[0], seats[1], seats[2])
	}

	// Échange : chacun apprend son nouveau numéro.
	if code := post("/dolphin/players/swap", "a=0&b=1"); code != http.StatusNoContent {
		t.Fatalf("échange refusé : %d", code)
	}
	if a, b := next(alice), next(bob); a.Slot != 1 || b.Slot != 0 {
		t.Fatalf("après échange : Alice %d, Bob %d", a.Slot, b.Slot)
	}
	if seats := list(); seats[1].Name != "Alice" {
		t.Fatal("liste non mise à jour après l'échange")
	}
	// Vers une place vide.
	post("/dolphin/players/swap", "a=1&b=3")
	if next(alice).Slot != 3 || list()[1] != nil {
		t.Fatal("déplacement vers une place vide raté")
	}

	// Retrait : prévenu, sans reconnexion automatique, place libérée.
	post("/dolphin/players/0/kick", "")
	if m := next(bob); m.Error == "" || m.Retry {
		t.Fatalf("retrait mal signalé : %+v", m)
	}
	time.Sleep(50 * time.Millisecond)
	if list()[0] != nil {
		t.Fatal("place toujours occupée après le retrait")
	}

	for _, bad := range []string{"a=0&b=0", "a=0&b=9", "a=x&b=1"} {
		if code := post("/dolphin/players/swap", bad); code != http.StatusBadRequest {
			t.Fatalf("%s accepté (%d)", bad, code)
		}
	}
}

// Téléphone (WebSocket) → serveur → client DSU (UDP), comme Dolphin.
func TestPhoneToDolphin(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := newServer(conn)
	go s.serveDSU()
	web := httptest.NewServer(s.routes("127.0.0.1", "0"))
	defer web.Close()

	dolphin, err := net.DialUDP("udp", nil, conn.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	read := func(size int) []byte {
		t.Helper()
		dolphin.SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 200)
		n, err := dolphin.Read(buf)
		if err != nil {
			t.Fatal(err)
		}
		checkSealed(t, buf[:n], size)
		return buf[:n]
	}
	listPorts := func() []byte {
		dolphin.Write(request(msgPorts, 2, 0, 0, 0, 0, 1))
		a, b := read(32), read(32)
		return []byte{a[21], b[21]}
	}

	if got := listPorts(); got[0] != 0 || got[1] != 0 {
		t.Fatalf("slots occupés sans téléphone : %v", got)
	}

	wsURL := "ws" + strings.TrimPrefix(web.URL, "http") + "/ws"
	if _, err := websocket.Dial(wsURL, "", "http://ailleurs.example"); err == nil {
		t.Fatal("origine étrangère acceptée")
	}
	var answer struct {
		Slot  int
		Error string
		Retry bool
	}
	connect := func(invite string) *websocket.Conn {
		t.Helper()
		phone, err := websocket.Dial(wsURL, "", web.URL)
		if err != nil {
			t.Fatal(err)
		}
		websocket.JSON.Send(phone, hello{Invite: invite})
		answer.Error = ""
		if err := websocket.JSON.Receive(phone, &answer); err != nil {
			t.Fatal(err)
		}
		return phone
	}

	// Sans le jeton du lien d'invitation : refusé, sans nouvelle tentative.
	connect("devine").Close()
	if answer.Error == "" || answer.Retry {
		t.Fatalf("jeton faux accepté : %+v", answer)
	}
	// Ancien jeton révoqué par un nouveau lien.
	old := s.currentInvite()
	s.newInvite()
	connect(old).Close()
	if answer.Error == "" {
		t.Fatal("jeton révoqué accepté")
	}

	// Deux téléphones : Wii Remote 1 et 2, dans l'ordre.
	first := connect(s.currentInvite())
	if answer.Error != "" || answer.Slot != 0 {
		t.Fatalf("premier téléphone sur le slot %d (%s)", answer.Slot, answer.Error)
	}
	phone := connect(s.currentInvite())
	if answer.Error != "" || answer.Slot != 1 {
		t.Fatalf("second téléphone sur le slot %d (%s)", answer.Slot, answer.Error)
	}
	if got := listPorts(); got[0] != 2 || got[1] != 2 {
		t.Fatalf("états des slots : %v", got)
	}

	// Le premier part puis revient : il reprend le slot 0, sans trou que Dolphin ne lirait pas.
	first.Close()
	time.Sleep(50 * time.Millisecond)
	connect(s.currentInvite())
	if answer.Slot != 0 {
		t.Fatalf("retour sur le slot %d au lieu de 0", answer.Slot)
	}

	// Abonnement au slot 1 (drapeau « par numéro »), puis un état envoyé par le téléphone.
	dolphin.Write(request(msgPadData, 1, 1, 0, 0, 0, 0, 0, 0))
	time.Sleep(50 * time.Millisecond)
	msg := make([]byte, phoneMessageSize)
	le.PutUint16(msg, 1<<3) // 2
	le.PutUint32(msg[2+4*1:], math.Float32bits(-1))
	msg[26], msg[27] = 255, 0 // pointeur en bas à droite
	websocket.Message.Send(phone, msg)
	pkt := read(100)
	if pkt[20] != 1 || pkt[51] != 255 || math.Float32frombits(le.Uint32(pkt[80:])) != -1 || pkt[42] != 255 || pkt[43] != 0 {
		t.Fatalf("état mal relayé : %v", pkt[20:100])
	}

	// Téléphone parti : boutons relâchés, puis slot libéré.
	phone.Close()
	if pkt := read(100); pkt[51] != 0 {
		t.Fatal("bouton resté enfoncé après la déconnexion")
	}
	time.Sleep(50 * time.Millisecond)
	if got := listPorts(); got[1] != 0 {
		t.Fatal("slot toujours occupé après la déconnexion")
	}
}
