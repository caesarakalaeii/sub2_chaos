package bridge

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"time"
)

// ReadStatus reads chaos_status.json. A missing file returns (nil, nil): the
// caller treats "no status yet" as gameplay-active so the engine works headless
// (before the mod has booted, or with no mod installed at all).
func ReadStatus(path string) (*Status, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var s Status
	if err := json.Unmarshal(data, &s); err != nil {
		// A torn/partial read (mod mid-write) — treat as transient, not fatal.
		return nil, nil
	}
	return &s, nil
}

// Active reports whether the engine should run rounds given a status (possibly
// nil). Nil or absent status => active; an explicit pause or inactive gameplay
// => not active.
func Active(s *Status) bool {
	if s == nil {
		return true
	}
	return s.GameplayActive && !s.Paused
}

// Fresh reports whether the mod wrote this status within maxAge of now — i.e.
// the game is actually running. The mod heartbeats chaos_status.json, so a
// missing file, blank/unparseable timestamp, or one older than maxAge means the
// game isn't running (closed, crashed, or not launched yet). Used by the engine
// to pause voting when there's nothing in-game to execute the winners.
func Fresh(s *Status, now time.Time, maxAge time.Duration) bool {
	if s == nil || s.UpdatedAt == "" {
		return false
	}
	t, err := time.Parse(time.RFC3339, s.UpdatedAt)
	if err != nil {
		return false
	}
	d := now.Sub(t)
	if d < 0 {
		d = -d // tolerate small clock skew either direction
	}
	return d <= maxAge
}
