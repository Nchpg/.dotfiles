package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Activité SSH de la page SSH, en lecture seule : les connexions acceptées et les tentatives refusées
// viennent du journal de sshd gardé par Loki (sa durée de conservation), les sessions ouvertes de
// logind. sshd note l'empreinte de la clé acceptée, pas celle d'une clé refusée : les refus se
// comptent par IP.

// sshEvent : une ligne utile du journal de sshd.
type sshEvent struct {
	At          time.Time
	Accepted    bool
	User, IP    string
	Fingerprint string // connexions acceptées
}

var (
	reSSHAccepted = regexp.MustCompile(`^Accepted publickey for (\S+) from (\S+) port \d+ ssh2: \S+ (SHA256:\S+)`)
	// Une connexion refusée se termine par une de ces lignes (avant authentification, [preauth]).
	reSSHRefused = regexp.MustCompile(`^(?:Connection closed by|Disconnected from|Connection reset by|Disconnecting) (?:authenticating|invalid) user (\S*) (\S+) port \d+`)
)

// parseSSHLine : l'événement d'une ligne du journal (faux si elle ne dit rien d'utile).
func parseSSHLine(at time.Time, line string) (sshEvent, bool) {
	if m := reSSHAccepted.FindStringSubmatch(line); m != nil {
		return sshEvent{At: at, Accepted: true, User: m[1], IP: m[2], Fingerprint: m[3]}, true
	}
	if m := reSSHRefused.FindStringSubmatch(line); m != nil {
		return sshEvent{At: at, User: m[1], IP: m[2]}, true
	}
	return sshEvent{}, false
}

// SSHUse : l'usage d'une clé sur la fenêtre des journaux.
type SSHUse struct {
	Count  int
	Last   time.Time
	LastIP string
}

// SSHRefusal : les tentatives refusées venues d'une IP.
type SSHRefusal struct {
	IP, Device string
	Users      []string // comptes tentés
	Count      int
	Last       string
	last       time.Time
}

// SSHSession : une session SSH ouverte (logind), et la clé qui l'a ouverte quand le journal la donne.
type SSHSession struct {
	User, IP    string
	Since       time.Time
	Fingerprint string
}

type sshActivity struct {
	Uses      map[string]*SSHUse // par empreinte
	Refusals  []*SSHRefusal
	Sessions  []SSHSession
	Truncated bool // plus de lignes que Loki n'en rend en une fois : comptes minorés
	LogsOK    bool // journal lu (sinon colonnes vides, et la page le dit)
}

// summarize : usages par clé et refus par IP ; une session prend l'empreinte de la connexion
// acceptée de même IP à quelques secondes près (le journal n'a pas son processus).
func summarize(events []sshEvent, sessions []SSHSession) sshActivity {
	a := sshActivity{Uses: map[string]*SSHUse{}}
	refused := map[string]*SSHRefusal{}
	for _, e := range events {
		if e.Accepted {
			u := a.Uses[e.Fingerprint]
			if u == nil {
				u = &SSHUse{}
				a.Uses[e.Fingerprint] = u
			}
			u.Count++
			if e.At.After(u.Last) {
				u.Last, u.LastIP = e.At, e.IP
			}
			continue
		}
		r := refused[e.IP]
		if r == nil {
			r = &SSHRefusal{IP: e.IP}
			refused[e.IP] = r
		}
		r.Count++
		if e.User != "" && !containsStr(r.Users, e.User) {
			r.Users = append(r.Users, e.User)
		}
		if e.At.After(r.last) {
			r.last = e.At
		}
	}
	for _, r := range refused {
		sort.Strings(r.Users)
		a.Refusals = append(a.Refusals, r)
	}
	sort.Slice(a.Refusals, func(i, j int) bool { return a.Refusals[i].last.After(a.Refusals[j].last) })
	for _, s := range sessions {
		for _, e := range events {
			if d := e.At.Sub(s.Since); e.Accepted && e.IP == s.IP && d > -5*time.Second && d < 5*time.Second {
				s.Fingerprint = e.Fingerprint
				break
			}
		}
		a.Sessions = append(a.Sessions, s)
	}
	return a
}

func containsStr(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// lokiLimit : le plafond de lignes d'une requête Loki (max_entries_limit_per_query par défaut).
const lokiLimit = 5000

// sshLog : les lignes utiles du journal de sshd sur la fenêtre de Loki, les plus récentes d'abord.
func (s *Server) sshLog(ctx context.Context) (events []sshEvent, truncated bool, err error) {
	if s.cfg.Loki == "" {
		return nil, false, fmt.Errorf("pas de Loki")
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	now := time.Now()
	q := url.Values{
		"query":     {fmt.Sprintf(`{unit=%q} |~ "Accepted publickey|(authenticating|invalid) user"`, s.cfg.SSHUnit)},
		"start":     {strconv.FormatInt(now.Add(-s.cfg.LogsWindow).UnixNano(), 10)},
		"end":       {strconv.FormatInt(now.UnixNano(), 10)},
		"limit":     {strconv.Itoa(lokiLimit)},
		"direction": {"backward"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.cfg.Loki+"/loki/api/v1/query_range?"+q.Encode(), nil)
	if err != nil {
		return nil, false, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false, fmt.Errorf("loki : %s", resp.Status)
	}
	var body struct {
		Data struct {
			Result []struct {
				Values [][2]string `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, false, err
	}
	n := 0
	for _, r := range body.Data.Result {
		for _, v := range r.Values {
			n++
			ns, err := strconv.ParseInt(v[0], 10, 64)
			if err != nil {
				continue
			}
			if e, ok := parseSSHLine(time.Unix(0, ns), v[1]); ok {
				events = append(events, e)
			}
		}
	}
	sort.Slice(events, func(i, j int) bool { return events[i].At.After(events[j].At) })
	return events, n >= lokiLimit, nil
}

// sshSessions : les sessions SSH ouvertes, d'après logind.
func sshSessions(ctx context.Context) []SSHSession {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "loginctl", "list-sessions", "-j").Output()
	if err != nil {
		return nil
	}
	var list []struct {
		Session string `json:"session"`
	}
	if json.Unmarshal(out, &list) != nil {
		return nil
	}
	var sessions []SSHSession
	for _, l := range list {
		cmd := exec.CommandContext(ctx, "loginctl", "show-session", l.Session, "-p", "Service", "-p", "State", "-p", "Name", "-p", "RemoteHost", "-p", "Timestamp")
		// Date lue en UTC : « Wed 2026-10-28 08:18:43 UTC ».
		cmd.Env = append(os.Environ(), "TZ=UTC")
		out, err := cmd.Output()
		if err != nil {
			continue
		}
		p := map[string]string{}
		for _, line := range strings.Split(string(out), "\n") {
			if k, v, ok := strings.Cut(line, "="); ok {
				p[k] = v
			}
		}
		if p["Service"] != "sshd" || p["State"] == "closing" {
			continue
		}
		since, _ := time.Parse("Mon 2006-01-02 15:04:05 MST", p["Timestamp"])
		sessions = append(sessions, SSHSession{User: p["Name"], IP: p["RemoteHost"], Since: since})
	}
	return sessions
}

var sshCache struct {
	sync.Mutex
	at time.Time
	a  sshActivity
}

// sshActivityOf : l'activité SSH, relue au plus toutes les 30 secondes.
func (s *Server) sshActivityOf(ctx context.Context) sshActivity {
	sshCache.Lock()
	defer sshCache.Unlock()
	if time.Since(sshCache.at) < 30*time.Second {
		return sshCache.a
	}
	events, truncated, err := s.sshLog(ctx)
	a := summarize(events, sshSessions(ctx))
	a.Truncated, a.LogsOK = truncated, err == nil
	sshCache.at, sshCache.a = time.Now(), a
	return a
}

// vpnDevices : le nom de l'appareil VPN de chaque adresse du tunnel (actifs et en attente).
func (s *Server) vpnDevices(ctx context.Context) map[string]string {
	m := map[string]string{}
	for _, p := range s.cfg.VPN.Peers {
		m[p.Address] = p.Name
	}
	for name, p := range s.mainPeers(ctx) {
		if _, ok := m[p.Address]; !ok {
			m[p.Address] = name
		}
	}
	return m
}
