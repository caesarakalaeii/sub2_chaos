package bridge

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
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
