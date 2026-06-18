package chat

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"math/rand"
	"net"
	"strings"
	"time"
)

// TwitchOpts configures the anonymous Twitch IRC source.
type TwitchOpts struct {
	Channel     string // channel login (with or without leading '#')
	Server      string // host:port (default irc.chat.twitch.tv:6697)
	UseTLS      bool
	RequestTags bool                       // request IRCv3 tags for a stable user-id
	Logf        func(format string, a ...any)
}

type twitchIRC struct{ opts TwitchOpts }

// NewTwitchIRC builds an anonymous (read-only, no OAuth) Twitch IRC source.
func NewTwitchIRC(o TwitchOpts) Source {
	if o.Server == "" {
		o.Server = "irc.chat.twitch.tv:6697"
		o.UseTLS = true
	}
	if o.Logf == nil {
		o.Logf = func(string, ...any) {}
	}
	return &twitchIRC{opts: o}
}

func (t *twitchIRC) Name() string { return "twitch-irc" }

func (t *twitchIRC) Run(ctx context.Context, out chan<- Message) error {
	backoff := time.Second
	for {
		if ctx.Err() != nil {
			return nil
		}
		start := time.Now()
		err := t.session(ctx, out)
		if ctx.Err() != nil {
			return nil
		}
		if time.Since(start) > 30*time.Second {
			backoff = time.Second // stable connection — reset backoff
		}
		t.opts.Logf("twitch: disconnected (%v); reconnecting in %s", err, backoff)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > 30*time.Second {
			backoff = 30 * time.Second
		}
	}
}

func (t *twitchIRC) session(ctx context.Context, out chan<- Message) error {
	dialer := net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	var err error
	if t.opts.UseTLS {
		conn, err = tls.DialWithDialer(&dialer, "tcp", t.opts.Server,
			&tls.Config{ServerName: hostOnly(t.opts.Server)})
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", t.opts.Server)
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	// Unblock the read loop when the context is cancelled.
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()

	w := bufio.NewWriter(conn)
	send := func(s string) {
		_, _ = fmt.Fprintf(w, "%s\r\n", s)
		_ = w.Flush()
	}
	nick := fmt.Sprintf("justinfan%d", 10000+rand.Intn(800000))
	send("PASS SCHMOOPIIE")
	send("NICK " + nick)
	if t.opts.RequestTags {
		send("CAP REQ :twitch.tv/tags twitch.tv/commands")
	}
	send("JOIN #" + strings.ToLower(strings.TrimPrefix(t.opts.Channel, "#")))
	t.opts.Logf("twitch: connected to #%s as %s", strings.TrimPrefix(t.opts.Channel, "#"), nick)

	r := bufio.NewReader(conn)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(6 * time.Minute))
		line, err := r.ReadString('\n')
		if err != nil {
			return err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "PING") {
			send("PONG " + strings.TrimPrefix(line, "PING "))
			continue
		}
		if msg, ok := parsePrivmsg(line); ok {
			select {
			case out <- msg:
			case <-ctx.Done():
				return nil
			}
		}
	}
}

// parsePrivmsg parses an IRC line into a Message, returning ok=false for any
// non-PRIVMSG line. Handles the optional IRCv3 @tags prefix and the :nick!.. prefix.
func parsePrivmsg(line string) (Message, bool) {
	rest := line
	tags := map[string]string{}
	if strings.HasPrefix(rest, "@") {
		sp := strings.IndexByte(rest, ' ')
		if sp < 0 {
			return Message{}, false
		}
		for _, kv := range strings.Split(rest[1:sp], ";") {
			if eq := strings.IndexByte(kv, '='); eq >= 0 {
				tags[kv[:eq]] = kv[eq+1:]
			}
		}
		rest = rest[sp+1:]
	}

	var prefix string
	if strings.HasPrefix(rest, ":") {
		sp := strings.IndexByte(rest, ' ')
		if sp < 0 {
			return Message{}, false
		}
		prefix = rest[1:sp]
		rest = rest[sp+1:]
	}

	const cmd = "PRIVMSG "
	if !strings.HasPrefix(rest, cmd) {
		return Message{}, false
	}
	rest = rest[len(cmd):]
	sp := strings.IndexByte(rest, ' ')
	if sp < 0 {
		return Message{}, false
	}
	text := strings.TrimPrefix(rest[sp+1:], ":")

	nick := prefix
	if ex := strings.IndexByte(nick, '!'); ex >= 0 {
		nick = nick[:ex]
	}
	userID := tags["user-id"]
	if userID == "" {
		userID = nick
	}
	username := tags["display-name"]
	if username == "" {
		username = nick
	}
	return Message{
		Platform: "twitch",
		UserID:   userID,
		Username: username,
		Text:     text,
		TS:       time.Now(),
	}, true
}

func hostOnly(hostport string) string {
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		return h
	}
	return hostport
}
