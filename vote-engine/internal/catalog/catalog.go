// Package catalog loads the shared events.json catalog and selects the
// options for each vote round (weighted, honoring per-event cooldowns).
package catalog

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"time"
)

// Event is one entry in events.json. The vote-engine uses ID/Label/Category/
// Weight/CooldownSeconds; the rest (Kind/DurationSeconds/BuffKey/Params) is
// declarative data the Lua mod reads to execute the event.
type Event struct {
	ID              string         `json:"id"`
	Label           string         `json:"label"`
	Category        string         `json:"category"`
	Weight          float64        `json:"weight"`
	CooldownSeconds int            `json:"cooldownSeconds"`
	Kind            string         `json:"kind,omitempty"`
	DurationSeconds int            `json:"durationSeconds,omitempty"`
	BuffKey         string         `json:"buffKey,omitempty"`
	Params          map[string]any `json:"params,omitempty"`
	Description     string         `json:"description,omitempty"`
}

// Catalog is the parsed events.json file.
type Catalog struct {
	Version int     `json:"version"`
	Events  []Event `json:"events"`
}

// Load reads and validates a catalog from disk.
func Load(path string) (*Catalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("catalog: read %s: %w", path, err)
	}
	return Parse(data)
}

// Parse validates catalog bytes: unique ids, positive weights (default 1).
func Parse(data []byte) (*Catalog, error) {
	var c Catalog
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("catalog: parse: %w", err)
	}
	if len(c.Events) == 0 {
		return nil, fmt.Errorf("catalog: no events")
	}
	seen := make(map[string]bool, len(c.Events))
	for i := range c.Events {
		e := &c.Events[i]
		if e.ID == "" {
			return nil, fmt.Errorf("catalog: events[%d] has empty id", i)
		}
		if seen[e.ID] {
			return nil, fmt.Errorf("catalog: duplicate id %q", e.ID)
		}
		seen[e.ID] = true
		if e.Label == "" {
			return nil, fmt.Errorf("catalog: event %q has empty label", e.ID)
		}
		if e.Weight <= 0 {
			e.Weight = 1.0
		}
		if e.Category == "" {
			e.Category = "chaos"
		}
	}
	return &c, nil
}

// IDs returns every event id (used for cross-checking against the Lua handlers).
func (c *Catalog) IDs() []string {
	ids := make([]string, len(c.Events))
	for i, e := range c.Events {
		ids[i] = e.ID
	}
	return ids
}

// Picker selects rounds from a catalog, tracking cooldowns and the previous
// round so it can avoid immediate repeats. Not safe for concurrent use; the
// vote machine owns one and calls it from a single goroutine.
type Picker struct {
	events     []Event
	lastChosen map[string]time.Time
	prevRound  map[string]bool
}

// NewPicker builds a Picker over a copy of the catalog's events.
func NewPicker(c *Catalog) *Picker {
	ev := make([]Event, len(c.Events))
	copy(ev, c.Events)
	return &Picker{
		events:     ev,
		lastChosen: make(map[string]time.Time),
		prevRound:  make(map[string]bool),
	}
}

// Pick returns n distinct events chosen by weight. Events still on cooldown (or,
// when avoidRepeat is set, in the previous round) are excluded; if too few remain
// the constraints are relaxed in order (repeat guard, then cooldowns) so a round
// can always be formed. It records the choices for future cooldown/repeat checks.
func (p *Picker) Pick(n int, now time.Time, avoidRepeat bool, rng *rand.Rand) []Event {
	if n > len(p.events) {
		n = len(p.events)
	}
	eligible := p.filter(now, avoidRepeat)
	if len(eligible) < n {
		eligible = p.filter(now, false) // relax the immediate-repeat guard
	}
	if len(eligible) < n {
		eligible = append([]Event(nil), p.events...) // relax cooldowns too
	}

	chosen := weightedSampleNoReplace(eligible, n, rng)

	p.prevRound = make(map[string]bool, len(chosen))
	for _, e := range chosen {
		p.lastChosen[e.ID] = now
		p.prevRound[e.ID] = true
	}
	return chosen
}

func (p *Picker) filter(now time.Time, avoidRepeat bool) []Event {
	out := make([]Event, 0, len(p.events))
	for _, e := range p.events {
		if avoidRepeat && p.prevRound[e.ID] {
			continue
		}
		if e.CooldownSeconds > 0 {
			if last, ok := p.lastChosen[e.ID]; ok {
				if now.Sub(last) < time.Duration(e.CooldownSeconds)*time.Second {
					continue
				}
			}
		}
		out = append(out, e)
	}
	return out
}

// weightedSampleNoReplace draws n distinct events from pool with probability
// proportional to Weight, removing each as it's chosen.
func weightedSampleNoReplace(pool []Event, n int, rng *rand.Rand) []Event {
	pool = append([]Event(nil), pool...) // local copy we can mutate
	if n > len(pool) {
		n = len(pool)
	}
	out := make([]Event, 0, n)
	for len(out) < n && len(pool) > 0 {
		total := 0.0
		for _, e := range pool {
			total += e.Weight
		}
		r := rng.Float64() * total
		idx := 0
		for i, e := range pool {
			r -= e.Weight
			if r <= 0 {
				idx = i
				break
			}
		}
		out = append(out, pool[idx])
		pool = append(pool[:idx], pool[idx+1:]...)
	}
	return out
}
