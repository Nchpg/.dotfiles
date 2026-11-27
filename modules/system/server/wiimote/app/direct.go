package main

// Liaison directe des manettes : leurs états en datagrammes UDP (WebTransport sur QUIC), droit sur la box, sans
// le détour par Cloudflare ni TCP, qui retient tous les paquets derrière un seul perdu. Ces à-coups écrasaient la
// forme d'un geste (coup de raquette, secousse). Le WebSocket garde la session (invitation, place, renvoi) et sert
// de repli.

import (
	"crypto/subtle"
	"crypto/tls"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/webtransport-go"
)

// Datagramme : numéro (u32, croissant par session), instant du téléphone (u32, ms), puis l'état, comme par le
// WebSocket.
const directHeader = 4 + 4

func (s *server) serveDirect(conn net.PacketConn, getCert func(*tls.ClientHelloInfo) (*tls.Certificate, error), origin string) error {
	h3 := &http3.Server{
		TLSConfig: http3.ConfigureTLSConfig(&tls.Config{
			// Journal : un téléphone joint la box (sinon, son réseau ou le pare-feu bloquent l'UDP avant).
			GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
				if hello.Conn != nil {
					log.Printf("liaison directe : %s se présente", hello.Conn.RemoteAddr())
				}
				return getCert(hello)
			},
			MinVersion: tls.VersionTLS13,
		}),
		QUICConfig: &quic.Config{
			EnableDatagrams:                  true,
			EnableStreamResetPartialDelivery: true,
			MaxIdleTimeout:                   10 * time.Second,
		},
	}
	webtransport.ConfigureHTTP3Server(h3)
	wt := &webtransport.Server{
		H3: h3,
		// Seule la page de la manette ouvre la liaison (le jeton l'exige déjà).
		CheckOrigin: func(r *http.Request) bool {
			if got := r.Header.Get("Origin"); got != origin {
				log.Printf("liaison directe refusée à %s : origine %q", r.RemoteAddr, got)
				return false
			}
			return true
		},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/wt", func(w http.ResponseWriter, r *http.Request) {
		p := s.byToken(r.URL.Query().Get("t"))
		if p == nil {
			log.Printf("liaison directe refusée à %s : jeton inconnu", r.RemoteAddr)
			http.Error(w, "jeton inconnu", http.StatusForbidden)
			return
		}
		sess, err := wt.Upgrade(w, r)
		if err != nil {
			log.Printf("liaison directe refusée à %s : %v", r.RemoteAddr, err)
			// Sans réponse explicite, HTTP/3 répondrait 200 : le téléphone croirait la liaison ouverte.
			http.Error(w, err.Error(), http.StatusForbidden)
			return
		}
		log.Printf("liaison directe ouverte : %s (%s)", displayName(p.name), r.RemoteAddr)
		s.attachDirect(p, sess)
		defer func() {
			sess.CloseWithError(0, "")
			s.mu.Lock()
			current := p.direct == sess
			if current {
				p.direct = nil
			}
			s.mu.Unlock()
			if current {
				log.Printf("liaison directe fermée : %s, la manette passe par le WebSocket", displayName(p.name))
			}
		}()
		for {
			msg, err := sess.ReceiveDatagram(sess.Context())
			if err != nil {
				return
			}
			if len(msg) == pingSize {
				s.notePing(p, le.Uint32(msg))
				sess.SendDatagram(msg)
				continue
			}
			if len(msg) < directHeader {
				continue
			}
			if st, ok := decode(msg[directHeader:]); ok {
				s.pushDirect(p, le.Uint32(msg), le.Uint32(msg[4:]), st)
			}
		}
	})
	h3.Handler = mux
	return wt.Serve(conn)
}

// byToken retrouve la manette encore connectée dont le jeton est `token`.
func (s *server) byToken(token string) *player {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.seatByTokenLocked(token)
}

func (s *server) seatByTokenLocked(token string) *player {
	if token == "" {
		return nil
	}
	for _, p := range s.seats {
		if p != nil && subtle.ConstantTimeCompare([]byte(p.token), []byte(token)) == 1 {
			return p
		}
	}
	return nil
}

// attachDirect fait de `sess` la liaison directe de `p`, en fermant l'ancienne (téléphone reconnecté).
func (s *server) attachDirect(p *player, sess *webtransport.Session) {
	s.mu.Lock()
	old := p.direct
	p.direct, p.seq = sess, 0
	// Nouvelle liaison : ses numéros repartent de 1.
	p.stats.last = 0
	s.mu.Unlock()
	if old != nil {
		old.CloseWithError(0, "remplacée")
	}
}

// pushDirect applique un état reçu en datagramme, sauf s'il est plus ancien que le dernier : les datagrammes
// peuvent se doubler, et un état périmé relâcherait puis rappuierait un bouton.
func (s *server) pushDirect(p *player, seq, phone uint32, st padState) {
	s.mu.Lock()
	if p.slot < 0 {
		s.mu.Unlock()
		return
	}
	p.seen = time.Now()
	p.stats.datagram(seq, phone, p.seen)
	if seq <= p.seq {
		s.mu.Unlock()
		return
	}
	p.seq = seq
	pkt, targets := s.stateLocked(p.slot, st)
	s.mu.Unlock()
	s.broadcast(pkt, targets)
}

// certReloader relit le certificat quand ACME l'a renouvelé (fichier plus récent) : sans redémarrage, qui
// couperait les manettes.
type certReloader struct {
	certFile, keyFile string

	mu      sync.Mutex
	cert    *tls.Certificate
	modTime time.Time
}

func (c *certReloader) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	info, err := os.Stat(c.certFile)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cert == nil || info.ModTime().After(c.modTime) {
		cert, err := tls.LoadX509KeyPair(c.certFile, c.keyFile)
		if err != nil {
			return nil, err
		}
		c.cert, c.modTime = &cert, info.ModTime()
	}
	return c.cert, nil
}
