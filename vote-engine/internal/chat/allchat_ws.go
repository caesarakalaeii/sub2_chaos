package chat

import (
	"context"
	"errors"
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

// Run is implemented in milestone 3 (the WebSocket client + deserializer).
func (a *allChat) Run(ctx context.Context, out chan<- Message) error {
	return errors.New("all-chat source not yet implemented")
}
