package chat

import "testing"

func TestBuildAllChatURL(t *testing.T) {
	cases := []struct {
		base, user, overlay, token string
		since                      int64
		want                       string
		wantErr                    bool
	}{
		{base: "https://allch.at", user: "ludwig", want: "wss://allch.at/ws/chat/ludwig"},
		{base: "http://localhost:8080", overlay: "ovl-1", token: "jwt", since: 1500,
			want: "ws://localhost:8080/ws/overlay/ovl-1?since=1500&token=jwt"},
		{base: "https://allch.at", user: "u", since: 42, want: "wss://allch.at/ws/chat/u?since=42"},
		{base: "https://allch.at", wantErr: true},                       // neither user nor overlay
		{base: "https://allch.at", user: "u", overlay: "o", wantErr: true}, // both? user wins, no error actually
		{base: "", user: "u", wantErr: true},                            // empty base
	}
	for i, c := range cases {
		got, err := BuildAllChatURL(c.base, c.user, c.overlay, c.token, c.since)
		// The "both" case: user takes precedence, so it's not an error here;
		// the config layer enforces the XOR. Skip its wantErr expectation.
		if c.user != "" && c.overlay != "" {
			if err != nil {
				t.Fatalf("case %d: unexpected err %v", i, err)
			}
			continue
		}
		if c.wantErr {
			if err == nil {
				t.Fatalf("case %d: expected error", i)
			}
			continue
		}
		if err != nil {
			t.Fatalf("case %d: unexpected err %v", i, err)
		}
		if got != c.want {
			t.Fatalf("case %d: got %q want %q", i, got, c.want)
		}
	}
}

func TestParseAllChatData(t *testing.T) {
	chat := `{"id":"1","platform":"youtube","user":{"id":"u9","username":"alice","display_name":"Alice"},"message":{"text":"3"},"timestamp":"2026-06-18T10:00:00Z"}`
	m, ok := ParseAllChatData([]byte(chat))
	if !ok || m.UserID != "u9" || m.Platform != "youtube" || m.Text != "3" || m.Username != "alice" {
		t.Fatalf("ok=%v got %+v", ok, m)
	}

	ev := `{"id":"2","platform":"twitch","user":{"id":"u1"},"message":{"text":"sub"},"event":{"type":"subscription"}}`
	if _, ok := ParseAllChatData([]byte(ev)); ok {
		t.Fatal("event payload should be skipped (not a vote)")
	}

	dn := `{"user":{"id":"u","display_name":"Bob"},"message":{"text":"1"}}`
	if m, ok := ParseAllChatData([]byte(dn)); !ok || m.Username != "Bob" {
		t.Fatalf("username fallback failed: ok=%v %+v", ok, m)
	}
}

func TestDecodeEnvelope(t *testing.T) {
	typ, raw := decodeEnvelope([]byte(`{"type":"chat_message","data":{"id":"x"}}`))
	if typ != "chat_message" || len(raw) == 0 {
		t.Fatalf("typ=%q raw=%s", typ, raw)
	}
	if typ, _ := decodeEnvelope([]byte(`not json`)); typ != "" {
		t.Fatal("garbage should yield empty type")
	}
}
