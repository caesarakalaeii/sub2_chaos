# ADR-0004 — Announce lead, in-game pause, and leviathan spawn path

## Status
Accepted.

## Context
Three gameplay-feel gaps surfaced in the first live session:

1. Winning events fired with no warning — the player had no idea what was about
   to happen.
2. The in-game pause menu did not pause voting; the mod always reported
   `paused: false` (hardcoded), so a round could resolve and an event could fire
   while the player was in a menu.
3. The `spawn_leviathan` event called the `SpawnCreature` dev cheat. For the
   WorldPop-managed Collector that returns a 0-component shell — the call logs
   `OK` but no huntable creature appears.

## Decision

**Announce lead.** Add `vote.announceLeadSeconds` (default 5). At resolve the
sidecar publishes the winner + nonce immediately (this *is* the announcement)
and sets `applyAtServerTime = serverTime + lead`; the apply phase is extended to
`lead + applyHold` so the winner stays in the bridge through the whole heads-up
window. The mod, on seeing a fresh nonce, shows an on-screen banner and schedules
execution `lead` seconds later **off its own clock** (avoids sidecar↔game clock
skew). `applyAtServerTime` is carried only for the overlay.

The banner uses Subnautica 2's **own** notification system — the one cheats like
God mode pop up. Two earlier attempts failed and inform the current choice:
1. `UKismetSystemLibrary::PrintString` — invisible: shipping builds disable
   on-screen debug messages.
2. `UUWENotificationComponent::ClientNotify(FNotificationData)` — **hard-crashed**
   the game (it's a *Client RPC*; a crash dump landed at the exact ms of an
   announce). pcall cannot catch a native crash, so this is never called.

The working path is `UUWEGameplayMessageBPLibrary::BroadcastStringMessageToAllPlayers
(WorldContext, FString)` (fallback `NotifyAllPlayersString`): a plain
BlueprintFunctionLibrary taking only a world context and a string — no struct, no
gameplay tag, no RPC — which the HUD's notification listener renders. It's gated
by `announce.use_ingame_notification` (an escape hatch) and falls back to
log-only. The heads-up timing is independent of the render path.

Separately, the mod's status **heartbeat** must not call `os.execute` per write:
`status_bridge` spawned `mkdir` on every write, and once the heartbeat made that
every ~2s it caused a periodic game-thread stutter under Proton. `ensure_dir` now
runs at most once per directory per session.

**Pause.** The mod sets `chaos_status.json.paused` from
`UGameplayStatics::IsGamePaused(world)`. The sidecar already treats
`active = gameplayActive && !paused`, so this freezes the vote countdown and
starts no new rounds while the pause menu is open. The mod also freezes the
pending-event lead countdown while paused, so an announced-but-not-yet-fired
event lands *after* the player resumes, not during the menu.

**Leviathan spawn.** Replace the `SpawnCreature` cheat with plain
`UWorld:SpawnActor` of the resolved BP class, forcing `SpawnCollisionHandlingMethod
= AlwaysSpawn` on the class CDO so a spawn overlapping terrain isn't rejected.
The resolve→load→retry logic and the captured class paths are ported from the
sibling `sub2_cheatmenu` repo's `SpawnCollectorLeviathan` mod (see CREDITS.md),
kept as a pure, unit-tested `spawn.lua` with an injected engine adapter. Event
class paths live in `events.json` `params`; a startup timer pre-loads the
Collector class so the first spawn works on a cold save.

## Consequences
- Bridge schema gains `applyAtServerTime` + `announceLeadSeconds` (ADR-0002),
  both additive — older mod builds ignore them and fire instantly.
- The announcement surface is debug-text (`PrintString`); a nicer in-game widget
  can replace `announce.show` later without touching the timing/scheduling.
- Pause detection and the on-screen banner are engine-API-dependent and
  pcall-guarded; they degrade to "never paused" / "no banner" rather than
  crashing, and require on-device UAT to confirm rendering and the pause API.
