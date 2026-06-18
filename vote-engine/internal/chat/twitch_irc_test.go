package chat

import "testing"

func TestParsePrivmsg(t *testing.T) {
	t.Run("with tags", func(t *testing.T) {
		line := "@badge-info=;user-id=44322889;display-name=Dallas :dallas!dallas@dallas.tmi.twitch.tv PRIVMSG #ch :Hello world"
		m, ok := parsePrivmsg(line)
		if !ok {
			t.Fatal("expected PRIVMSG to parse")
		}
		if m.UserID != "44322889" || m.Username != "Dallas" || m.Text != "Hello world" || m.Platform != "twitch" {
			t.Fatalf("got %+v", m)
		}
	})

	t.Run("without tags falls back to nick", func(t *testing.T) {
		line := ":bob!bob@bob.tmi.twitch.tv PRIVMSG #ch :2"
		m, ok := parsePrivmsg(line)
		if !ok || m.UserID != "bob" || m.Username != "bob" || m.Text != "2" {
			t.Fatalf("ok=%v got %+v", ok, m)
		}
	})

	t.Run("preserves colons in message body", func(t *testing.T) {
		m, ok := parsePrivmsg(":x!x@x.tmi.twitch.tv PRIVMSG #ch :hi :)")
		if !ok || m.Text != "hi :)" {
			t.Fatalf("ok=%v text=%q", ok, m.Text)
		}
	})

	t.Run("non-PRIVMSG rejected", func(t *testing.T) {
		if _, ok := parsePrivmsg(":tmi.twitch.tv 001 justinfan :Welcome"); ok {
			t.Fatal("001 welcome should not parse as a message")
		}
		if _, ok := parsePrivmsg("PING :tmi.twitch.tv"); ok {
			t.Fatal("PING should not parse as a message")
		}
	})
}

func TestHostOnly(t *testing.T) {
	if h := hostOnly("irc.chat.twitch.tv:6697"); h != "irc.chat.twitch.tv" {
		t.Fatalf("hostOnly = %q", h)
	}
}
