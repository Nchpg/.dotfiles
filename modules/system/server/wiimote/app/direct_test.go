package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"math/big"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/webtransport-go"
)

func selfSigned(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func TestDirectDatagrams(t *testing.T) {
	s := newServer(nil)
	p := s.claim("Test", nil)
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	cert := selfSigned(t)
	const origin = "https://wii.example"
	go s.serveDirect(udp, func(*tls.ClientHelloInfo) (*tls.Certificate, error) { return &cert, nil }, origin)

	tr := &webtransport.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		QUICConfig:      &quic.Config{EnableDatagrams: true, EnableStreamResetPartialDelivery: true},
	}
	defer tr.Close()
	base := "https://" + udp.LocalAddr().String() + "/wt?t="
	dial := func(token, from string) (*webtransport.Session, int) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		rsp, sess, err := tr.Dial(ctx, base+token, http.Header{"Origin": {from}})
		if rsp == nil {
			if err == nil {
				t.Fatal("ni réponse ni erreur")
			}
			return nil, 0
		}
		return sess, rsp.StatusCode
	}

	if sess, code := dial("devine", origin); sess != nil {
		t.Fatalf("jeton inconnu accepté (%d)", code)
	}
	if sess, code := dial(p.token, "https://ailleurs.example"); sess != nil {
		t.Fatalf("autre origine acceptée (%d)", code)
	}
	sess, code := dial(p.token, origin)
	if sess == nil {
		t.Fatalf("liaison refusée (%d)", code)
	}

	datagram := func(seq uint32, buttons uint16) []byte {
		b := make([]byte, directHeader+phoneMessageSize)
		le.PutUint32(b, seq)
		le.PutUint16(b[directHeader:], buttons)
		return b
	}
	buttonsAfter := func(dgrams ...[]byte) uint16 {
		for _, d := range dgrams {
			if err := sess.SendDatagram(d); err != nil {
				t.Fatal(err)
			}
		}
		time.Sleep(100 * time.Millisecond)
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.pads[p.slot].buttons
	}
	// Le numéro 1 arrive après le 2 : périmé, ignoré.
	if got := buttonsAfter(datagram(2, 1), datagram(1, 2)); got != 1 {
		t.Fatalf("boutons %b après un datagramme périmé, attendu 1", got)
	}
	if got := buttonsAfter(datagram(3, 4)); got != 4 {
		t.Fatalf("boutons %b, attendu 100", got)
	}

	// La manette part : la liaison se ferme.
	s.release(p)
	select {
	case <-sess.Context().Done():
	case <-time.After(3 * time.Second):
		t.Fatal("liaison restée ouverte après le départ de la manette")
	}
}
