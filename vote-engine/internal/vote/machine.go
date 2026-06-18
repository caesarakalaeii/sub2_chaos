package vote

import (
	"context"
	"fmt"
	"math"
	"math/rand"
	"time"

	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/bridge"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/catalog"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/chat"
)

// Config tunes the vote machine.
type Config struct {
	OptionsPerRound      int
	VoteDuration         time.Duration
	Cooldown             time.Duration
	ApplyHold            time.Duration
	AvoidImmediateRepeat bool
}

// Machine runs the vote round lifecycle. It is single-goroutine: Offer and
// Advance must be called from the same goroutine (the Run driver guarantees it).
type Machine struct {
	cfg    Config
	picker *catalog.Picker
	rng    *rand.Rand
	token  string // per-run token making winner nonces unique across restarts

	phase       string
	round       int
	phaseEnds   time.Time
	lastAdvance time.Time
	options     []catalog.Event
	cur         *Round
	winner      *bridge.Winner
	winnerNonce string
	active      bool
}

// NewMachine builds a machine over a catalog. seed==0 uses a time-based seed.
func NewMachine(cfg Config, cat *catalog.Catalog, seed int64) *Machine {
	if cfg.OptionsPerRound <= 0 {
		cfg.OptionsPerRound = 4
	}
	if cfg.VoteDuration <= 0 {
		cfg.VoteDuration = 30 * time.Second
	}
	if cfg.ApplyHold <= 0 {
		cfg.ApplyHold = 3 * time.Second
	}
	if seed == 0 {
		seed = time.Now().UnixNano()
	}
	rng := rand.New(rand.NewSource(seed))
	return &Machine{
		cfg:    cfg,
		picker: catalog.NewPicker(cat),
		rng:    rng,
		token:  fmt.Sprintf("%08x", rng.Uint32()),
		phase:  bridge.PhaseIdle,
		active: true,
	}
}

// SetActive pauses/resumes the machine. When inactive it freezes the current
// phase's countdown and starts no new rounds.
func (m *Machine) SetActive(active bool) { m.active = active }

// Phase returns the current phase (for tests/logging).
func (m *Machine) Phase() string { return m.phase }

// Round returns the current round number.
func (m *Machine) Round() int { return m.round }

// Offer feeds a chat message as a potential vote for the current round.
func (m *Machine) Offer(msg chat.Message) {
	if m.phase != bridge.PhaseVoting || m.cur == nil {
		return
	}
	idx, ok := ParseVote(msg.Text, len(m.options))
	if !ok {
		return
	}
	m.cur.Cast(msg.Platform+"\x00"+msg.UserID, idx)
}

func (m *Machine) startRound(now time.Time) {
	m.round++
	m.options = m.picker.Pick(m.cfg.OptionsPerRound, now, m.cfg.AvoidImmediateRepeat, m.rng)
	m.cur = NewRound(len(m.options))
	m.winner = nil
	m.winnerNonce = ""
	m.phase = bridge.PhaseVoting
	m.phaseEnds = now.Add(m.cfg.VoteDuration)
}

func (m *Machine) resolve(now time.Time) {
	idx := Resolve(m.cur.Counts(), m.rng)
	if idx >= 0 && idx < len(m.options) {
		e := m.options[idx]
		m.winner = &bridge.Winner{Index: idx + 1, ID: e.ID, Label: e.Label}
	}
	m.winnerNonce = fmt.Sprintf("%s-r%d", m.token, m.round)
	m.phase = bridge.PhaseApply
	m.phaseEnds = now.Add(m.cfg.ApplyHold)
}

// Advance drives phase transitions for the given time and returns the current
// state snapshot. Safe to call every tick.
func (m *Machine) Advance(now time.Time) bridge.State {
	// While paused, push the active deadline forward so the countdown freezes.
	if !m.lastAdvance.IsZero() && !m.active && !m.phaseEnds.IsZero() {
		if delta := now.Sub(m.lastAdvance); delta > 0 {
			m.phaseEnds = m.phaseEnds.Add(delta)
		}
	}
	m.lastAdvance = now

	if m.active {
		switch m.phase {
		case bridge.PhaseIdle:
			m.startRound(now)
		case bridge.PhaseVoting:
			if !now.Before(m.phaseEnds) {
				m.resolve(now)
			}
		case bridge.PhaseApply:
			if !now.Before(m.phaseEnds) {
				if m.cfg.Cooldown > 0 {
					m.phase = bridge.PhaseCooldown
					m.phaseEnds = now.Add(m.cfg.Cooldown)
				} else {
					m.startRound(now)
				}
			}
		case bridge.PhaseCooldown:
			if !now.Before(m.phaseEnds) {
				m.startRound(now)
			}
		}
	}
	return m.snapshot(now)
}

func (m *Machine) snapshot(now time.Time) bridge.State {
	secs := 0.0
	switch m.phase {
	case bridge.PhaseVoting, bridge.PhaseCooldown, bridge.PhaseApply:
		if d := m.phaseEnds.Sub(now).Seconds(); d > 0 {
			secs = math.Round(d*10) / 10
		}
	}
	opts := make([]bridge.Option, len(m.options))
	for i, e := range m.options {
		opts[i] = bridge.Option{Index: i + 1, ID: e.ID, Label: e.Label, Category: e.Category}
	}
	tallies := make([]int, len(m.options))
	total := 0
	if m.cur != nil {
		tallies = m.cur.Counts()
		total = m.cur.Total()
	}
	return bridge.State{
		SchemaVersion:       bridge.SchemaVersion,
		Round:               m.round,
		Phase:               m.phase,
		Options:             opts,
		Tallies:             tallies,
		TotalVotes:          total,
		SecondsRemaining:    secs,
		VoteDurationSeconds: int(m.cfg.VoteDuration.Seconds()),
		Winner:              m.winner,
		WinnerNonce:         m.winnerNonce,
		ServerTime:          now.UTC().Format(time.RFC3339Nano),
	}
}

// Run drives the machine: it ticks at the given interval, feeds votes from the
// channel, applies active-state changes, and publishes each snapshot. All
// machine mutation happens in this one goroutine, so no locking is needed.
// active may be nil. Returns when ctx is cancelled.
func Run(ctx context.Context, m *Machine, votes <-chan chat.Message, active <-chan bool, tick time.Duration, clock func() time.Time, publish func(bridge.State)) {
	if tick <= 0 {
		tick = 250 * time.Millisecond
	}
	if clock == nil {
		clock = time.Now
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	publish(m.Advance(clock()))
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-votes:
			m.Offer(msg)
		case a := <-active:
			m.SetActive(a)
		case <-t.C:
			publish(m.Advance(clock()))
		}
	}
}
