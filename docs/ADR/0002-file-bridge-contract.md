# ADR-0002 — File bridge contract

## Status
Accepted.

## Context
The Go sidecar and the Lua mod (ADR-0001) run in separate processes and must
exchange the current vote state and the winning event. `sub2_random` already
proves a robust pattern: the Lua side does `io.open` on files under
`./ue4ss/Mods/<Mod>/` (resolved relative to the game cwd `Binaries/Win64`), and
the C++ side reads them. We reuse that channel.

## Decision
Two JSON files in the mod folder:

- **`chaos_state.json`** (sidecar → mod, also the overlay payload). Fields:
  `schemaVersion, round, phase, options[{index,id,label,category}], tallies[],
  totalVotes, secondsRemaining, voteDurationSeconds, winner{index,id,label}|null,
  winnerNonce, serverTime`. The mod executes a winner only when `winnerNonce`
  changes — the idempotency key, so a winner never fires twice across polls.
- **`chaos_status.json`** (mod → sidecar). Fields: `schemaVersion,
  gameplayActive, paused, lastAppliedNonce, modVersion, updatedAt`. The sidecar
  pauses voting (freezes the countdown, starts no new rounds) when gameplay is
  inactive.

**Atomic writes are mandatory on both sides**: write `<file>.tmp` in the SAME
directory, then `rename` over the target. NEVER use the OS temp dir — under
Proton/Wine it is on a different filesystem and the cross-device rename fails
(documented in `sub2_random/debug_bridge.lua`). The reader tolerates a missing,
empty, or half-written file by treating it as a no-op and retrying next tick
(`json.decode` never throws; the atomic rename makes torn reads rare anyway).

## Consequences
- Lossless, language-agnostic, no extra runtime dependency or local port.
- Path resolution: the sidecar takes `--bridge-file` / `--mod-dir` / `--game-dir`
  / `$GAME_DIR` / Steam auto-detect (ADR-0001's Go installer logic) to find the
  same absolute path the mod reads from.
