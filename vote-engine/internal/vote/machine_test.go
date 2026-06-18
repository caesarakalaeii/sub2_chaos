package vote

import (
	"math"
	"testing"
	"time"

	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/bridge"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/catalog"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/chat"
)

func testCatalog() *catalog.Catalog {
	ev := make([]catalog.Event, 8)
	for i := range ev {
		ev[i] = catalog.Event{
			ID:       string(rune('a' + i)),
			Label:    "Event " + string(rune('A'+i)),
			Category: "chaos",
			Weight:   1,
		}
	}
	return &catalog.Catalog{Version: 1, Events: ev}
}

func testCfg() Config {
	return Config{
		OptionsPerRound:      4,
		VoteDuration:         10 * time.Second,
		Cooldown:             5 * time.Second,
		ApplyHold:            2 * time.Second,
		AvoidImmediateRepeat: true,
	}
}

func TestMachineLifecycle(t *testing.T) {
	m := NewMachine(testCfg(), testCatalog(), 42)
	base := time.Unix(1_700_000_000, 0).UTC()

	s := m.Advance(base)
	if s.Phase != bridge.PhaseVoting {
		t.Fatalf("phase = %s; want voting", s.Phase)
	}
	if s.Round != 1 || len(s.Options) != 4 {
		t.Fatalf("round=%d options=%d; want 1 and 4", s.Round, len(s.Options))
	}

	m.Offer(chat.Message{Platform: "t", UserID: "a", Text: "1"})
	m.Offer(chat.Message{Platform: "t", UserID: "b", Text: "1"})
	m.Offer(chat.Message{Platform: "t", UserID: "c", Text: "2"})
	m.Offer(chat.Message{Platform: "t", UserID: "a", Text: "2"}) // dup -> ignored
	s = m.Advance(base.Add(1 * time.Second))
	if s.Tallies[0] != 2 || s.Tallies[1] != 1 || s.TotalVotes != 3 {
		t.Fatalf("tallies=%v total=%d; want [2 1 ..] total 3", s.Tallies, s.TotalVotes)
	}

	// Voting window elapses -> apply, winner is option 1.
	s = m.Advance(base.Add(11 * time.Second))
	if s.Phase != bridge.PhaseApply {
		t.Fatalf("phase = %s; want apply", s.Phase)
	}
	if s.Winner == nil || s.Winner.Index != 1 {
		t.Fatalf("winner = %+v; want index 1", s.Winner)
	}
	nonce1 := s.WinnerNonce
	if nonce1 == "" {
		t.Fatal("winner nonce empty")
	}

	// Apply hold elapses -> cooldown (winner still shown).
	s = m.Advance(base.Add(13*time.Second + 100*time.Millisecond))
	if s.Phase != bridge.PhaseCooldown || s.Winner == nil {
		t.Fatalf("phase=%s winner=%v; want cooldown with winner", s.Phase, s.Winner)
	}

	// Cooldown elapses -> new round.
	s = m.Advance(base.Add(18*time.Second + 200*time.Millisecond))
	if s.Phase != bridge.PhaseVoting || s.Round != 2 {
		t.Fatalf("phase=%s round=%d; want voting round 2", s.Phase, s.Round)
	}
	if s.Winner != nil {
		t.Fatal("winner should clear on a new round")
	}

	// Resolve round 2 and confirm the nonce changed.
	s = m.Advance(base.Add(29 * time.Second))
	if s.WinnerNonce == "" || s.WinnerNonce == nonce1 {
		t.Fatalf("round-2 nonce %q must be non-empty and differ from %q", s.WinnerNonce, nonce1)
	}
}

func TestMachinePauseFreezesCountdown(t *testing.T) {
	m := NewMachine(testCfg(), testCatalog(), 7)
	base := time.Unix(1_700_000_000, 0).UTC()

	m.Advance(base)                      // voting, ends base+10
	m.Advance(base.Add(2 * time.Second)) // remaining ~8

	m.SetActive(false)
	s := m.Advance(base.Add(5 * time.Second)) // paused: end shifts +3 -> remaining stays ~8
	if math.Abs(s.SecondsRemaining-8) > 0.3 {
		t.Fatalf("paused secondsRemaining=%v; want ~8", s.SecondsRemaining)
	}
	s = m.Advance(base.Add(12 * time.Second)) // well past original end, but still frozen
	if s.Phase != bridge.PhaseVoting {
		t.Fatalf("phase=%s; want still voting while paused", s.Phase)
	}

	m.SetActive(true)
	s = m.Advance(base.Add(21 * time.Second)) // resumed; deadline was pushed to base+20
	if s.Phase != bridge.PhaseApply {
		t.Fatalf("phase=%s; want apply after resume+expiry", s.Phase)
	}
}

func TestMachineReconfigureAppliesNextRound(t *testing.T) {
	m := NewMachine(testCfg(), testCatalog(), 42) // vote 10s, cooldown 5s, options 4
	base := time.Unix(1_700_000_000, 0).UTC()

	s := m.Advance(base)
	if len(s.Options) != 4 {
		t.Fatalf("round-1 options=%d; want 4", len(s.Options))
	}

	// Player changes the menu mid-round: longer votes, 6 options, no cooldown.
	m.Reconfigure(Reconfig{VoteDuration: 20 * time.Second, Options: 6, Cooldown: 0, HasCooldown: true})

	// Current round is undisturbed (still 4 options, original 10s window).
	s = m.Advance(base.Add(1 * time.Second))
	if len(s.Options) != 4 {
		t.Fatalf("reconfig must not disturb the running round; options=%d want 4", len(s.Options))
	}

	// Round 1 resolves at +10s (apply hold 2s, no announce lead in testCfg).
	s = m.Advance(base.Add(11 * time.Second))
	if s.Phase != bridge.PhaseApply {
		t.Fatalf("phase=%s; want apply", s.Phase)
	}
	// Cooldown is now 0 -> apply elapses straight into a new round at +13s.
	s = m.Advance(base.Add(13*time.Second + 100*time.Millisecond))
	if s.Phase != bridge.PhaseVoting || s.Round != 2 {
		t.Fatalf("phase=%s round=%d; want voting round 2 (cooldown=0)", s.Phase, s.Round)
	}
	// The new round reflects the menu: 6 options and a 20s window.
	if len(s.Options) != 6 {
		t.Fatalf("round-2 options=%d; want 6 after reconfigure", len(s.Options))
	}
	if s.VoteDurationSeconds != 20 {
		t.Fatalf("round-2 voteDurationSeconds=%d; want 20", s.VoteDurationSeconds)
	}
}

func TestReconfigureIgnoresOutOfRange(t *testing.T) {
	m := NewMachine(testCfg(), testCatalog(), 1)
	m.Reconfigure(Reconfig{VoteDuration: 0, Options: 99}) // both invalid -> ignored
	if m.cfg.OptionsPerRound != 4 || m.cfg.VoteDuration != 10*time.Second {
		t.Fatalf("out-of-range reconfigure changed cfg: opts=%d dur=%v", m.cfg.OptionsPerRound, m.cfg.VoteDuration)
	}
}

func TestMachineAnnounceLead(t *testing.T) {
	cfg := testCfg()
	cfg.AnnounceLead = 5 * time.Second // winner announced 5s before it should execute
	m := NewMachine(cfg, testCatalog(), 42)
	base := time.Unix(1_700_000_000, 0).UTC()

	m.Advance(base)                            // voting, ends base+10
	s := m.Advance(base.Add(11 * time.Second)) // voting elapsed -> resolve
	if s.Phase != bridge.PhaseApply || s.Winner == nil {
		t.Fatalf("phase=%s winner=%v; want apply with a winner", s.Phase, s.Winner)
	}
	if s.AnnounceLeadSeconds != 5 {
		t.Fatalf("announceLeadSeconds=%d; want 5", s.AnnounceLeadSeconds)
	}
	// applyAt must be the lead ahead of serverTime (resolve happened at base+11).
	applyAt, err := time.Parse(time.RFC3339Nano, s.ApplyAtServerTime)
	if err != nil {
		t.Fatalf("applyAtServerTime %q not parseable: %v", s.ApplyAtServerTime, err)
	}
	if want := base.Add(16 * time.Second); !applyAt.Equal(want) {
		t.Fatalf("applyAt=%s; want %s (resolve + 5s lead)", applyAt, want)
	}

	// The apply phase must still be live a hair before applyAt (the winner stays
	// in the bridge through the whole heads-up window, not just ApplyHold).
	s = m.Advance(base.Add(15 * time.Second))
	if s.Phase != bridge.PhaseApply || s.Winner == nil {
		t.Fatalf("phase=%s winner=%v; want still apply during the heads-up", s.Phase, s.Winner)
	}

	// Apply phase = lead(5) + hold(2) = 7s after resolve -> ends at base+18.
	s = m.Advance(base.Add(18*time.Second + 100*time.Millisecond))
	if s.Phase != bridge.PhaseCooldown {
		t.Fatalf("phase=%s; want cooldown after lead+hold", s.Phase)
	}

	// A fresh round clears the pending apply timestamp.
	s = m.Advance(base.Add(40 * time.Second))
	if s.Phase != bridge.PhaseVoting || s.ApplyAtServerTime != "" {
		t.Fatalf("phase=%s applyAt=%q; want voting with cleared applyAt", s.Phase, s.ApplyAtServerTime)
	}
}
