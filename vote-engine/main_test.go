package main

import (
	"testing"

	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/config"
)

func TestApplyOverridesPublicBind(t *testing.T) {
	c := config.Default()
	if c.Overlay.Bind != "127.0.0.1" {
		t.Fatalf("expected default bind to be loopback, got %q", c.Overlay.Bind)
	}

	applyOverrides(c, overrides{public: true})
	if c.Overlay.Bind != "0.0.0.0" {
		t.Fatalf("--public should bind to 0.0.0.0, got %q", c.Overlay.Bind)
	}

	c2 := config.Default()
	applyOverrides(c2, overrides{})
	if c2.Overlay.Bind != "127.0.0.1" {
		t.Fatalf("without --public bind should stay loopback, got %q", c2.Overlay.Bind)
	}
}
