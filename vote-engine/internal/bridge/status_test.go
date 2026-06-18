package bridge

import (
	"testing"
	"time"
)

func TestFreshDetectsRunningGame(t *testing.T) {
	now := time.Date(2026, 6, 18, 20, 0, 0, 0, time.UTC)
	stamp := func(d time.Duration) string { return now.Add(d).UTC().Format(time.RFC3339) }
	maxAge := 6 * time.Second

	cases := []struct {
		name string
		s    *Status
		want bool
	}{
		{"nil status (no file / not running)", nil, false},
		{"blank timestamp", &Status{}, false},
		{"unparseable timestamp", &Status{UpdatedAt: "not-a-time"}, false},
		{"just written", &Status{UpdatedAt: stamp(0)}, true},
		{"within window", &Status{UpdatedAt: stamp(-4 * time.Second)}, true},
		{"stale (game closed)", &Status{UpdatedAt: stamp(-30 * time.Second)}, false},
		{"slightly future (clock skew tolerated)", &Status{UpdatedAt: stamp(2 * time.Second)}, true},
	}
	for _, c := range cases {
		if got := Fresh(c.s, now, maxAge); got != c.want {
			t.Errorf("%s: Fresh=%v want %v", c.name, got, c.want)
		}
	}
}
