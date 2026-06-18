// Package bridge defines the JSON contract between the vote-engine and the
// in-game Lua mod, and writes it atomically so the mod never reads a torn file.
package bridge

// SchemaVersion is bumped on a breaking change to the bridge JSON shape.
const SchemaVersion = 1

// Phase names mirror the vote machine's phases.
const (
	PhaseIdle      = "idle"
	PhaseVoting    = "voting"
	PhaseResolving = "resolving"
	PhaseApply     = "apply"
	PhaseCooldown  = "cooldown"
)

// Option is one of the choices shown for a round. Index is 1-based (the number
// viewers type).
type Option struct {
	Index    int    `json:"index"`
	ID       string `json:"id"`
	Label    string `json:"label"`
	Category string `json:"category"`
}

// Winner is the resolved event for a round (nil until the round resolves).
type Winner struct {
	Index int    `json:"index"`
	ID    string `json:"id"`
	Label string `json:"label"`
}

// State is the full document written to chaos_state.json (and pushed to the
// overlay). The mod keys execution off WinnerNonce changing.
type State struct {
	SchemaVersion       int      `json:"schemaVersion"`
	Round               int      `json:"round"`
	Phase               string   `json:"phase"`
	Options             []Option `json:"options"`
	Tallies             []int    `json:"tallies"`
	TotalVotes          int      `json:"totalVotes"`
	SecondsRemaining    float64  `json:"secondsRemaining"`
	VoteDurationSeconds int      `json:"voteDurationSeconds"`
	Winner              *Winner  `json:"winner"`
	WinnerNonce         string   `json:"winnerNonce"`
	ServerTime          string   `json:"serverTime"`
	// ApplyAtServerTime is when the mod should EXECUTE the winner (serverTime +
	// the announce lead). Empty unless a winner is pending. The mod announces the
	// winner on sight but holds execution until this moment so the player gets a
	// heads-up. AnnounceLeadSeconds is that lead, echoed for the overlay/mod.
	ApplyAtServerTime   string `json:"applyAtServerTime,omitempty"`
	AnnounceLeadSeconds int    `json:"announceLeadSeconds"`
}

// Status is the document the mod writes back (chaos_status.json) so the engine
// can pause voting outside gameplay.
type Status struct {
	SchemaVersion    int    `json:"schemaVersion"`
	GameplayActive   bool   `json:"gameplayActive"`
	Paused           bool   `json:"paused"`
	LastAppliedNonce string `json:"lastAppliedNonce"`
	ModVersion       string `json:"modVersion"`
	UpdatedAt        string `json:"updatedAt"`
	// Vote-shaping settings the player set in the in-game menu (0/absent = leave
	// the engine's configured value). The engine applies these at the next round
	// so voting is tuned from the menu, not config.yaml.
	VoteDurationSeconds int `json:"voteDurationSeconds,omitempty"`
	VoteOptions         int `json:"voteOptions,omitempty"`
	VoteCooldownSeconds int `json:"voteCooldownSeconds,omitempty"`
}
