# ADR-0005 — In-game menu is the tuning surface (sliders → sidecar)

## Status
Accepted.

## Context
This is a mod for normal players; editing `config.yaml` is not something most
users want to do. Everything a slider can express should be adjustable from the
in-game SN2ModSettings menu. Two kinds of settings exist:

1. **Execution tunables** the mod applies itself (effect durations, super-swim
   speed, slow/fast-world rates, damage severity, leviathan spawn distance, swarm
   size).
2. **Vote-shaping settings** owned by the sidecar (vote duration, options per
   round, cooldown) — the sidecar runs the rounds, not the mod.

## Decision
Expose all of them as SN2ModSettings sliders (`type="slider"` with
`min/max/step/format`, optionally `enabled_by` to gate by a toggle).

- **Execution tunables** are polled live into `ctx.tunables` and read by the
  event handlers each time they fire (with `config.lua` defaults as the headless
  fallback). Changing a slider applies to the next event immediately.
- **Vote-shaping settings** can't be applied by the mod, so the mod writes them
  back to the sidecar through the existing mod→sidecar file (`chaos_status.json`,
  fields `voteDurationSeconds` / `voteOptions` / `voteCooldownSeconds`). The
  sidecar's status poller turns a change into a `vote.Reconfig` and the vote
  machine applies it **at the next round** (the running round is undisturbed).
  Out-of-range/absent values are ignored.

Consequence for `config.yaml`: `vote.*` becomes the headless/`--simulate` default
and the value used until the mod connects. Once the game is running, the in-game
sliders are authoritative for vote timing. The slider defaults equal the config
defaults, so behaviour is unchanged out of the box. The chat **source** (Twitch
channel / all-chat overlay id) stays in `config.yaml` — it's needed at sidecar
startup, before the game/menu exists.

## Consequences
- One tuning surface for players; no YAML editing for day-to-day knobs.
- The mod→sidecar contract (ADR-0002) gains three optional status fields;
  additive, so an older sidecar ignores them.
- LoopAsync delays are NOT exposed as sliders: UE4SS's `LoopAsync` rejects
  non-integer delays, and a slider feeding a float would crash it. Poll/heartbeat
  cadences stay in `config.lua`.
