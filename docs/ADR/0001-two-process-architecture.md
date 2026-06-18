# ADR-0001 — Two-process architecture (Go sidecar + UE4SS Lua mod)

## Status
Accepted.

## Context
sub2_chaos must ingest live chat (Twitch/YouTube), run vote rounds, and execute
events inside Subnautica 2. The game is modded with UE4SS (Lua + optional C++).
UE4SS Lua has no networking and no socket library, so it cannot open a Twitch IRC
or WebSocket connection itself. Subnautica-side primitives (spawn, god, speed,
items) are already proven in Lua via `sub2_random`.

## Decision
Split the system in two:

- **`vote-engine` (Go sidecar)** — owns everything networked and reactive:
  chat ingestion (Twitch IRC XOR all-chat WS), the vote state machine, vote
  tallying, and the OBS browser overlay (local HTTP + SSE). One static binary.
- **`ChaosMod` (UE4SS Lua)** — execution only: each game tick it reads the
  winning event from a JSON bridge file and fires it using `sub2_random`'s cheat
  / spawn primitives. No reactive UI in-game.

They communicate through an atomic-write JSON file (see ADR-0002).

## Consequences
- Networking lives in Go, which has first-class TLS/WS/IRC support; the game can
  never be crashed by a chat-library bug.
- The reactive vote UI is an OBS browser source served by the sidecar — exactly
  where stream overlays belong — sidestepping UE4SS's table→struct HUD-draw
  crashes (`sub2_random`'s `notify.lua`).
- The streamer runs two things: the game (with the mod) and the sidecar binary.
- Go was chosen over TypeScript/C++ to match the ecosystem (`all-chat` and
  `sub2_random`'s installer are Go) and to ship a single cross-compiled `.exe`.
