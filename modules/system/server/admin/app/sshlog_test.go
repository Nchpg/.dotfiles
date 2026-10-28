package main

import (
	"testing"
	"time"
)

func TestSSHLog(t *testing.T) {
	t0 := time.Date(2026, 10, 28, 8, 18, 43, 0, time.UTC)
	lines := []string{
		"Accepted publickey for nchpg from 10.8.0.3 port 57842 ssh2: ED25519 SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE",
		"Accepted publickey for nchpg from 10.8.0.2 port 40000 ssh2: RSA SHA256:autre",
		"Connection closed by authenticating user nchpg 10.8.0.5 port 51000 [preauth]",
		"Connection closed by invalid user admin 192.168.1.20 port 52000 [preauth]",
		"Disconnected from invalid user root 192.168.1.20 port 52001 [preauth]",
		"Invalid user admin from 192.168.1.20 port 52000",
		"pam_unix(sshd:session): session opened for user nchpg(uid=1000) by (uid=0)",
	}
	var events []sshEvent
	for i, l := range lines {
		if e, ok := parseSSHLine(t0.Add(-time.Duration(i)*time.Hour), l); ok {
			events = append(events, e)
		}
	}
	if len(events) != 5 {
		t.Fatalf("%d événements, attendu 5 (« Invalid user » et pam ne comptent pas) : %+v", len(events), events)
	}
	sessions := []SSHSession{{User: "nchpg", IP: "10.8.0.3", Since: t0.Add(time.Second)}, {User: "nchpg", IP: "10.8.0.9", Since: t0}}
	a := summarize(events, sessions)
	u := a.Uses["SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE"]
	if u == nil || u.Count != 1 || u.LastIP != "10.8.0.3" || !u.Last.Equal(t0) {
		t.Errorf("usage : %+v", u)
	}
	if a.Sessions[0].Fingerprint != "SHA256:S0DdI1dbptXWeKg+yLOpVbtPVyN4LtdHl7zvKOa+LxE" || a.Sessions[1].Fingerprint != "" {
		t.Errorf("sessions : %+v", a.Sessions)
	}
	if len(a.Refusals) != 2 || a.Refusals[0].IP != "10.8.0.5" || a.Refusals[1].Count != 2 || len(a.Refusals[1].Users) != 2 {
		t.Errorf("refus : %+v %+v", a.Refusals[0], a.Refusals[len(a.Refusals)-1])
	}
	for v, want := range map[string]time.Duration{"30d": 30 * 24 * time.Hour, "720h": 720 * time.Hour, "n'importe": 30 * 24 * time.Hour} {
		if got := retention(v); got != want {
			t.Errorf("retention(%s) = %s", v, got)
		}
	}
}
