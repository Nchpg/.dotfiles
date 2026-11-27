// Manette Wii depuis un téléphone : la PWA envoie boutons et capteurs par WebSocket, le serveur
// les rediffuse en DSU (UDP) à Dolphin, qui y voit une manette à gyroscope à mapper sur une Wiimote.
package main

import (
	cryptorand "crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/websocket"
	"rsc.io/qr"
)

//go:embed web
var webFiles embed.FS

//go:embed dolphin.html
var setupPage string

// La PWA renvoie son état au moins toutes les 200 ms : muette plus longtemps sur ses deux liaisons, l'écran est
// verrouillé ou le réseau perdu. C'est aussi le temps qu'un téléphone coupé a pour reprendre sa place.
const phoneTimeout = 2 * time.Second

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	listen := env("WIIMOTE_LISTEN", "127.0.0.1:8097")
	dsuPort := env("WIIMOTE_DSU_PORT", "26760")
	// Adresse à saisir dans Dolphin, affichée sur la page de configuration.
	dsuHost := env("WIIMOTE_DSU_HOST", "IP-du-serveur")

	conn, err := net.ListenPacket("udp", ":"+dsuPort)
	if err != nil {
		log.Fatal(err)
	}
	s := newServer(conn)
	go func() { log.Fatal(s.serveDSU()) }()

	// Liaison directe (direct.go) : facultative, la manette passe sinon par le WebSocket.
	if addr := os.Getenv("WIIMOTE_DIRECT_LISTEN"); addr != "" {
		if udp, err := net.ListenPacket("udp", addr); err != nil {
			log.Printf("liaison directe indisponible : %v", err)
		} else {
			s.directURL = os.Getenv("WIIMOTE_DIRECT_URL")
			certs := &certReloader{certFile: os.Getenv("WIIMOTE_DIRECT_CERT"), keyFile: os.Getenv("WIIMOTE_DIRECT_KEY")}
			go func() {
				log.Printf("liaison directe arrêtée : %v", s.serveDirect(udp, certs.get, os.Getenv("WIIMOTE_ORIGIN")))
			}()
			log.Printf("liaison directe sur UDP %s (%s)", addr, s.directURL)
		}
	}

	log.Printf("PWA sur %s, DSU sur UDP %s", listen, dsuPort)
	log.Fatal(http.ListenAndServe(listen, s.routes(dsuHost, dsuPort)))
}

// /dolphin et ses sous-chemins sont réservés à l'hôte : nginx les place derrière Authelia.
func (s *server) routes(dsuHost, dsuPort string) http.Handler {
	web, _ := fs.Sub(webFiles, "web")
	page := template.Must(template.New("dolphin").Parse(setupPage))
	// Le jeton est après « # » : le navigateur ne l'envoie jamais, il n'apparaît dans aucun journal.
	inviteURL := func(r *http.Request) string { return "https://" + r.Host + "/#" + s.currentInvite() }

	mux := http.NewServeMux()
	// Revalidée à chaque chargement : sans date ni empreinte (fichiers embarqués), Safari gardait l'ancienne page
	// après une mise à jour.
	files := http.FileServerFS(web)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		files.ServeHTTP(w, r)
	})
	mux.Handle("/ws", websocket.Server{Handshake: sameOrigin, Handler: s.phone})
	mux.HandleFunc("GET /dolphin", func(w http.ResponseWriter, r *http.Request) {
		page.Execute(w, map[string]any{"Host": dsuHost, "Port": dsuPort, "Name": dsuName, "Players": []int{1, 2, 3, 4},
			"Invite": inviteURL(r)})
	})
	mux.HandleFunc("GET /dolphin/qr.png", func(w http.ResponseWriter, r *http.Request) {
		code, err := qr.Encode(inviteURL(r), qr.M)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(code.PNG())
	})
	mux.HandleFunc("POST /dolphin/invite", func(w http.ResponseWriter, r *http.Request) {
		s.newInvite()
		http.Redirect(w, r, "/dolphin", http.StatusSeeOther)
	})
	mux.HandleFunc("GET /dolphin/players", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(s.players())
	})
	mux.HandleFunc("POST /dolphin/players/swap", func(w http.ResponseWriter, r *http.Request) {
		a, errA := strconv.Atoi(r.FormValue("a"))
		b, errB := strconv.Atoi(r.FormValue("b"))
		if errA != nil || errB != nil || a < 0 || b < 0 || a >= slots || b >= slots || a == b {
			http.Error(w, "places invalides", http.StatusBadRequest)
			return
		}
		s.swap(a, b)
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /dolphin/players/{slot}/kick", func(w http.ResponseWriter, r *http.Request) {
		slot, err := strconv.Atoi(r.PathValue("slot"))
		if err != nil || slot < 0 || slot >= slots {
			http.Error(w, "place invalide", http.StatusBadRequest)
			return
		}
		s.kick(slot)
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /dolphin/{player}", func(w http.ResponseWriter, r *http.Request) {
		player, err := strconv.Atoi(r.PathValue("player"))
		if err != nil || player < 1 || player > slots {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s J%d.ini"`, dsuName, player))
		fmt.Fprint(w, profile(player-1))
	})
	// Un site tiers ne doit pas pouvoir révoquer le lien d'un formulaire caché.
	return http.NewCrossOriginProtection().Handler(mux)
}

// Une page d'un autre site ouverte sur le même réseau ne doit pas pouvoir piloter la manette.
func sameOrigin(cfg *websocket.Config, r *http.Request) error {
	origin, err := websocket.Origin(cfg, r)
	if err != nil || origin == nil || origin.Host != r.Host {
		return fmt.Errorf("origine refusée")
	}
	return nil
}

// Remplace le jeton : l'ancien lien ne permet plus de se connecter (les manettes déjà là le restent).
func (s *server) newInvite() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.invite = cryptorand.Text()
}

func (s *server) currentInvite() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.invite
}

func (s *server) invited(token string) bool {
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.currentInvite())) == 1
}

// Premier message du téléphone : le jeton d'invitation et le prénom du joueur ; après une coupure, le jeton de sa
// session précédente pour en reprendre la place.
type hello struct {
	Invite string `json:"invite"`
	Name   string `json:"name"`
	Resume string `json:"resume"`
}

func (s *server) phone(ws *websocket.Conn) {
	ws.MaxPayloadBytes = 256
	ws.SetReadDeadline(time.Now().Add(phoneTimeout))
	var h hello
	if websocket.JSON.Receive(ws, &h) != nil {
		return
	}
	ws.SetReadDeadline(time.Time{})
	// Une session encore là se reprend même si l'hôte a changé de lien depuis : le jeton de session suffit.
	p := s.resume(h.Resume, h.Name, ws)
	if p == nil {
		if !s.invited(h.Invite) {
			websocket.JSON.Send(ws, map[string]any{"error": "Lien d'invitation invalide ou remplacé : scanne le QR code de l'hôte.", "retry": false})
			return
		}
		if p = s.claim(h.Name, ws); p == nil {
			websocket.JSON.Send(ws, map[string]any{"error": "Déjà 4 manettes connectées.", "retry": true})
			return
		}
	}
	defer s.release(p)
	s.mu.Lock()
	slot := p.slot
	s.mu.Unlock()
	welcome := map[string]any{"slot": slot, "token": p.token}
	if s.directURL != "" {
		welcome["direct"] = s.directURL + "?t=" + p.token
	}
	if websocket.JSON.Send(ws, welcome) != nil {
		return
	}

	// Pas de délai de lecture sur le WebSocket : un TCP bloqué quelques secondes derrière Cloudflare ne coupe pas
	// une manette dont la liaison directe passe. Muette sur les deux, on la ferme.
	go func() {
		s.linger(p)
		ws.Close()
	}()
	var msg []byte
	for websocket.Message.Receive(ws, &msg) == nil {
		s.heard(p)
		if st, ok := decode(msg); ok {
			s.push(p, st)
		}
	}
	// Coupure : on raccroche (le téléphone le voit et revient aussitôt), boutons relâchés tout de suite, place
	// gardée le temps qu'il la reprenne.
	ws.Close()
	s.letGo(p)
	s.linger(p)
}

// Profil Dolphin d'une Wiimote émulée lisant le téléphone du slot donné.
func profile(slot int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[Profile]\nDevice = DSUClient/%d/%s\n", slot, dsuName)
	for _, btn := range buttons {
		fmt.Fprintf(&b, "%s = `%s`\n", btn.control, btn.input)
	}
	for _, dir := range []string{"Up", "Down", "Left", "Right", "Forward", "Backward"} {
		fmt.Fprintf(&b, "IMUAccelerometer/%s = `Accel %s`\n", dir, dir)
	}
	for _, axis := range []string{"Pitch Up", "Pitch Down", "Roll Left", "Roll Right", "Yaw Left", "Yaw Right"} {
		fmt.Fprintf(&b, "IMUGyroscope/%s = `Gyro %s`\n", axis, axis)
	}
	// Pointeur calculé par le téléphone, sur 16 bits : stick droit pour le gros, gauche pour le reste (cf.
	// pointerBytes). Celui que Dolphin tire du gyroscope s'y ajouterait : il intègre les vitesses reçues, et le
	// moindre à-coup du réseau devient une dérive.
	for _, dir := range [][2]string{{"Up", "Y+"}, {"Down", "Y-"}, {"Left", "X-"}, {"Right", "X+"}} {
		fmt.Fprintf(&b, "IR/%s = `Right %s` + `Left %s` / 254\n", dir[0], dir[1], dir[1])
	}
	b.WriteString("IMUIR/Enabled = False\n")
	return b.String()
}
