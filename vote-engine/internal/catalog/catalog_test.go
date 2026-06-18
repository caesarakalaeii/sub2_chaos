package catalog

import (
	"math/rand"
	"testing"
	"time"
)

func TestParseValidation(t *testing.T) {
	if _, err := Parse([]byte(`{"events":[{"id":"a","label":"A"},{"id":"a","label":"B"}]}`)); err == nil {
		t.Fatal("duplicate id should error")
	}
	if _, err := Parse([]byte(`{"events":[]}`)); err == nil {
		t.Fatal("empty catalog should error")
	}
	if _, err := Parse([]byte(`{"events":[{"id":"a"}]}`)); err == nil {
		t.Fatal("missing label should error")
	}
	c, err := Parse([]byte(`{"events":[{"id":"a","label":"A"}]}`))
	if err != nil {
		t.Fatalf("valid catalog errored: %v", err)
	}
	if c.Events[0].Weight != 1.0 {
		t.Fatalf("default weight = %v; want 1.0", c.Events[0].Weight)
	}
	if c.Events[0].Category != "chaos" {
		t.Fatalf("default category = %q; want chaos", c.Events[0].Category)
	}
}

func mkCatalog(n int) *Catalog {
	ev := make([]Event, n)
	for i := range ev {
		ev[i] = Event{ID: string(rune('a' + i)), Label: "E", Category: "chaos", Weight: 1}
	}
	return &Catalog{Version: 1, Events: ev}
}

func TestPickAvoidsImmediateRepeat(t *testing.T) {
	p := NewPicker(mkCatalog(8))
	rng := rand.New(rand.NewSource(1))
	now := time.Unix(1000, 0)

	first := p.Pick(4, now, true, rng)
	second := p.Pick(4, now, true, rng)
	if len(first) != 4 || len(second) != 4 {
		t.Fatalf("expected 4+4, got %d+%d", len(first), len(second))
	}
	in := map[string]bool{}
	for _, e := range first {
		in[e.ID] = true
	}
	for _, e := range second {
		if in[e.ID] {
			t.Fatalf("event %q repeated immediately despite avoidRepeat", e.ID)
		}
	}
}

func TestFilterCooldown(t *testing.T) {
	c := mkCatalog(3)
	c.Events[0].CooldownSeconds = 100 // event "a"
	p := NewPicker(c)
	now := time.Unix(1000, 0)
	p.lastChosen["a"] = now

	elig := p.filter(now.Add(50*time.Second), false)
	for _, e := range elig {
		if e.ID == "a" {
			t.Fatal("event on cooldown should be excluded")
		}
	}
	elig = p.filter(now.Add(150*time.Second), false)
	found := false
	for _, e := range elig {
		if e.ID == "a" {
			found = true
		}
	}
	if !found {
		t.Fatal("event off cooldown should be eligible")
	}
}

func TestFilterAvoidRepeat(t *testing.T) {
	p := NewPicker(mkCatalog(3))
	p.prevRound = map[string]bool{"b": true}
	for _, e := range p.filter(time.Unix(1000, 0), true) {
		if e.ID == "b" {
			t.Fatal("previous-round event should be excluded when avoidRepeat is set")
		}
	}
}
