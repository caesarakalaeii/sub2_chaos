package chat

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// TestAllChatSession spins up an in-process WebSocket server that behaves like
// all-chat: it sends a connected frame, a chat_message vote, and an app-level
// ping, then verifies the client emits the vote and replies pong.
func TestAllChatSession(t *testing.T) {
	up := websocket.Upgrader{}
	gotPong := make(chan bool, 1)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()

		_ = c.WriteJSON(map[string]any{"type": "connected", "data": map[string]any{"message": "hi"}})
		_ = c.WriteJSON(map[string]any{
			"type": "chat_message",
			"data": map[string]any{
				"id":        "1",
				"platform":  "twitch",
				"user":      map[string]any{"id": "u1", "username": "alice"},
				"message":   map[string]any{"text": "2"},
				"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
			},
		})
		_ = c.WriteJSON(map[string]any{"type": "ping"})

		var resp map[string]any
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		if err := c.ReadJSON(&resp); err == nil && resp["type"] == "pong" {
			gotPong <- true
		} else {
			gotPong <- false
		}
		for { // keep the connection open until the client disconnects
			if _, _, err := c.ReadMessage(); err != nil {
				return
			}
		}
	}))
	defer srv.Close()

	src := NewAllChat(AllChatOpts{BaseURL: srv.URL, StreamerUsername: "x"})
	out := make(chan Message, 4)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = src.Run(ctx, out) }()

	select {
	case m := <-out:
		if m.UserID != "u1" || m.Text != "2" || m.Platform != "twitch" {
			t.Fatalf("unexpected message %+v", m)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for the vote message")
	}

	select {
	case ok := <-gotPong:
		if !ok {
			t.Fatal("client did not reply pong to the app-level ping")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for pong")
	}
}
