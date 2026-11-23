// Manette Wii depuis un téléphone : la PWA envoie boutons et capteurs par WebSocket, le serveur
// les rediffuse en DSU (UDP) à Dolphin, qui y voit une manette à gyroscope à mapper sur une Wiimote.
package main

import (
	"embed"
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
)

//go:embed web
var webFiles embed.FS

//go:embed dolphin.html
var setupPage string

// La PWA renvoie son état au moins toutes les 200 ms : au-delà, l'écran est verrouillé ou le réseau perdu.
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

	log.Printf("PWA sur %s, DSU sur UDP %s", listen, dsuPort)
	log.Fatal(http.ListenAndServe(listen, s.routes(dsuHost, dsuPort)))
}

func (s *server) routes(dsuHost, dsuPort string) http.Handler {
	web, _ := fs.Sub(webFiles, "web")
	page := template.Must(template.New("dolphin").Parse(setupPage))

	mux := http.NewServeMux()
	mux.Handle("/", http.FileServerFS(web))
	mux.Handle("/ws", websocket.Server{Handshake: sameOrigin, Handler: s.phone})
	mux.HandleFunc("GET /dolphin", func(w http.ResponseWriter, _ *http.Request) {
		page.Execute(w, map[string]any{"Host": dsuHost, "Port": dsuPort, "Name": dsuName, "Players": []int{1, 2, 3, 4}})
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
	return mux
}

// Une page d'un autre site ouverte sur le même réseau ne doit pas pouvoir piloter la manette.
func sameOrigin(cfg *websocket.Config, r *http.Request) error {
	origin, err := websocket.Origin(cfg, r)
	if err != nil || origin == nil || origin.Host != r.Host {
		return fmt.Errorf("origine refusée")
	}
	return nil
}

func (s *server) phone(ws *websocket.Conn) {
	ws.MaxPayloadBytes = 64
	want, err := strconv.Atoi(ws.Request().URL.Query().Get("slot"))
	if err != nil {
		want = -1
	}
	slot := s.claim(want)
	if slot < 0 {
		websocket.JSON.Send(ws, map[string]string{"error": "Déjà 4 manettes connectées."})
		return
	}
	defer s.release(slot)
	if websocket.JSON.Send(ws, map[string]int{"slot": slot}) != nil {
		return
	}

	var msg []byte
	for {
		ws.SetReadDeadline(time.Now().Add(phoneTimeout))
		if websocket.Message.Receive(ws, &msg) != nil {
			return
		}
		if st, ok := decode(msg); ok {
			s.update(slot, st)
		}
	}
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
	// Pointeur calculé par le téléphone (stick droit). Celui que Dolphin tire du gyroscope s'y ajouterait :
	// il intègre les vitesses reçues, et le moindre à-coup du réseau devient une dérive.
	b.WriteString("IR/Up = `Right Y+`\nIR/Down = `Right Y-`\nIR/Left = `Right X-`\nIR/Right = `Right X+`\n")
	b.WriteString("IMUIR/Enabled = False\n")
	return b.String()
}
