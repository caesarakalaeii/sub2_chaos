package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// AllChatOpts configures the all-chat WebSocket source.
type AllChatOpts struct {
	BaseURL          string // http(s) base; scheme is auto-mapped to ws(s)
	StreamerUsername string // => /ws/chat/{username} (anonymous, recommended)
	OverlayID        string // => /ws/overlay/{id} (needs token, triggers polling)
	Token            string // JWT for the overlay path
	Logf             func(format string, a ...any)
}

type allChat struct{ opts AllChatOpts }

// NewAllChat builds an all-chat WebSocket source.
func NewAllChat(o AllChatOpts) Source {
	if o.Logf == nil {
		o.Logf = func(string, ...any) {}
	}
	return &allChat{opts: o}
}

func (a *allChat) Name() string { return "all-chat" }

// errFatal wraps non-recoverable conditions (bad config, streamer-not-found).
var errFatal = errors.New("fatal")

func (a *allChat) Run(ctx context.Context, out chan<- Message) error {
	// Validate the URL once up front; a bad config is fatal, not retryable.
	if _, err := BuildAllChatURL(a.opts.BaseURL, a.opts.StreamerUsername, a.opts.OverlayID, a.opts.Token, 0); err != nil {
		return err
	}
	backoff := time.Second
	var lastMs int64
	for {
		if ctx.Err() != nil {
			return nil
		}
		start := time.Now()
		ms, err := a.session(ctx, lastMs, out)
		if ms > lastMs {
			lastMs = ms
		}
		if ctx.Err() != nil {
			return nil
		}
		if errors.Is(err, errFatal) {
			return err
		}
		if time.Since(start) > 30*time.Second {
			backoff = time.Second
		}
		a.opts.Logf("all-chat: disconnected (%v); reconnecting in %s", err, backoff)
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

func (a *allChat) session(ctx context.Context, sinceMs int64, out chan<- Message) (int64, error) {
	wsURL, err := BuildAllChatURL(a.opts.BaseURL, a.opts.StreamerUsername, a.opts.OverlayID, a.opts.Token, sinceMs)
	if err != nil {
		return 0, fmt.Errorf("%w: %v", errFatal, err)
	}
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	conn, resp, err := dialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		if resp != nil && resp.StatusCode == 404 {
			return 0, fmt.Errorf("%w: streamer has no public overlay (404) — configure one at all-chat or use the overlay-id path", errFatal)
		}
		return 0, err
	}
	defer conn.Close()
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()

	const pongWait = 70 * time.Second
	_ = conn.SetReadDeadline(time.Now().Add(pongWait))
	conn.SetPongHandler(func(string) error { return conn.SetReadDeadline(time.Now().Add(pongWait)) })
	conn.SetPingHandler(func(appData string) error {
		_ = conn.SetReadDeadline(time.Now().Add(pongWait))
		err := conn.WriteControl(websocket.PongMessage, []byte(appData), time.Now().Add(10*time.Second))
		if errors.Is(err, websocket.ErrCloseSent) {
			return nil
		}
		return err
	})
	a.opts.Logf("all-chat: connected to %s", wsURL)

	lastSeen := sinceMs
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return lastSeen, err
		}
		typ, raw := decodeEnvelope(data)
		switch typ {
		case "chat_message":
			if msg, ok := ParseAllChatData(raw); ok {
				select {
				case out <- msg:
				case <-ctx.Done():
					return lastSeen, nil
				}
				if ms := msg.TS.UnixMilli(); ms > lastSeen {
					lastSeen = ms
				}
			}
		case "ping":
			_ = conn.WriteJSON(map[string]any{"type": "pong", "timestamp": time.Now().UTC().Format(time.RFC3339)})
		case "error":
			a.opts.Logf("all-chat: server error frame: %s", string(raw))
		}
	}
}

// BuildAllChatURL maps the http(s) base + identity to the ws(s) endpoint URL.
// Exactly one of user or overlayID must be set.
func BuildAllChatURL(base, user, overlayID, token string, sinceMs int64) (string, error) {
	if strings.TrimSpace(base) == "" {
		return "", errors.New("all-chat baseURL is empty")
	}
	u, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	case "ws", "wss":
		// already a websocket scheme
	default:
		return "", fmt.Errorf("all-chat baseURL has unsupported scheme %q", u.Scheme)
	}

	q := url.Values{}
	switch {
	case strings.TrimSpace(user) != "":
		u.Path = "/ws/chat/" + url.PathEscape(strings.TrimSpace(user))
	case strings.TrimSpace(overlayID) != "":
		u.Path = "/ws/overlay/" + url.PathEscape(strings.TrimSpace(overlayID))
		if token != "" {
			q.Set("token", token)
		}
	default:
		return "", errors.New("all-chat: set exactly one of streamerUsername or overlayId")
	}
	if sinceMs > 0 {
		q.Set("since", fmt.Sprintf("%d", sinceMs))
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func decodeEnvelope(data []byte) (typ string, raw json.RawMessage) {
	var env struct {
		Type string          `json:"type"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return "", nil
	}
	return env.Type, env.Data
}

// ParseAllChatData converts a chat_message data payload into a Message. ok=false
// when the payload is an event (sub/raid/etc.) rather than plain chat, or when
// it can't be parsed — those never count as votes.
func ParseAllChatData(data []byte) (Message, bool) {
	var d struct {
		ID       string `json:"id"`
		Platform string `json:"platform"`
		User     struct {
			ID          string `json:"id"`
			Username    string `json:"username"`
			DisplayName string `json:"display_name"`
		} `json:"user"`
		Message struct {
			Text string `json:"text"`
		} `json:"message"`
		Timestamp time.Time       `json:"timestamp"`
		Event     json.RawMessage `json:"event,omitempty"`
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return Message{}, false
	}
	if len(d.Event) > 0 && string(d.Event) != "null" {
		return Message{}, false // an event, not a vote
	}
	username := d.User.Username
	if username == "" {
		username = d.User.DisplayName
	}
	ts := d.Timestamp
	if ts.IsZero() {
		ts = time.Now()
	}
	return Message{
		Platform: d.Platform,
		UserID:   d.User.ID,
		Username: username,
		Text:     d.Message.Text,
		TS:       ts,
	}, true
}
