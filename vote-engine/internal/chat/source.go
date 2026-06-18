// Package chat defines the normalized chat-message stream and its sources
// (anonymous Twitch IRC, all-chat WebSocket, and a synthetic fake for testing).
package chat

import (
	"context"
	"time"
)

// Message is the normalized chat line every source produces. The vote tally
// dedupes on (Platform, UserID), so both must be stable per user.
type Message struct {
	Platform string    // "twitch","youtube","kick","tiktok","discord", or "sim"
	UserID   string    // stable per-platform user id (dedupe key component)
	Username string    // login/handle, for display/logging
	Text     string    // raw message text
	TS       time.Time // arrival time (source ts if available, else now)
}

// Source is a chat ingest. Run pushes messages onto out until ctx is cancelled,
// reconnecting internally with backoff. It returns nil on ctx cancel, or a
// non-nil error only for a fatal (non-recoverable) condition.
type Source interface {
	Run(ctx context.Context, out chan<- Message) error
	Name() string
}
