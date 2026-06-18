# sub2_chaos

**Let your Twitch / YouTube chat vote on chaos in Subnautica 2.**

Every round, four events are shown. Chat votes by typing `1`–`4`. When the timer runs out, the
winning event fires in-game — anything from *releasing a leviathan* to *granting an item* to
*temporary god mode / super speed*.

```
 Twitch / YouTube chat ─▶ vote-engine (Go) ─▶ chaos_state.json ─▶ ChaosMod (UE4SS Lua) ─▶ Subnautica 2
                              │
                              └─▶ OBS browser overlay (options + live tallies + countdown)
```

## How it works

sub2_chaos has two parts that talk through a small JSON file:

- **`vote-engine/`** — a single Go binary you run alongside the game. It connects to chat, runs the
  vote rounds, tallies the votes, and writes the result to a bridge file. It also serves a browser
  overlay you can add to OBS.
- **`mod/`** — a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod (`ChaosMod`). UE4SS Lua can't
  open network sockets, so the mod's only job is to read the bridge file each frame and *execute* the
  winning event using Subnautica 2's cheat/spawn primitives. Built on patterns proven in
  [`sub2_random`](../sub2_random).

The two halves agree on one shared catalog, [`events.json`](./events.json) — the single source of
truth for the event id namespace.

## Chat sources (pick one)

Chat ingestion is an **exclusive-or**: you use **either** direct Twitch IRC **or**
[all-chat](../all-chat), never both at once.

- **Twitch** (`source.mode: twitch`) — connects to Twitch IRC anonymously (read-only, **no OAuth /
  no token needed**). Twitch only.
- **all-chat** (`source.mode: allchat`) — connects to an [all-chat](../all-chat) WebSocket, which
  aggregates **Twitch, YouTube, Kick, TikTok and Discord** into one feed. Use this for YouTube.
  all-chat already de-duplicates across platforms, so we never dedupe locally.

## Quick start

### 1. Install the mod

Copy the mod into your Subnautica 2 UE4SS mods folder as `Sub2Chaos`, and copy the
shared catalog in alongside it:

```
<SN2>/Subnautica2/Binaries/Win64/ue4ss/Mods/Sub2Chaos/
    Scripts/...                 # from mod/Scripts/
    enabled.txt                 # from mod/enabled.txt
    events.json                 # from the repo root (the mod reads it at runtime)
```

Enable it in UE4SS `mods.txt`. In-game options live under **SN2ModSettings → Sub2Chaos**
(master switch + per-category gates: good / bad / chaos).

### 2. Run the vote-engine

```sh
cd vote-engine
go build -o vote-engine .
cp ../config.example.yaml ../config.yaml      # then edit config.yaml
./vote-engine --config ../config.yaml --game-dir "<path to your Subnautica2 install>"
```

`--game-dir` (or `bridge.gameDir` in the config) tells the sidecar where to write
`chaos_state.json` so the mod can read it; on a standard Steam install it is also
auto-detected. Add the overlay to OBS as a **Browser Source**:
`http://127.0.0.1:8777/overlay`.

### Try it without the game or a live stream

```sh
cd vote-engine
go run . --simulate --bridge-file /tmp/chaos_state.json
```

This injects synthetic votes through the whole pipeline. Watch `/tmp/chaos_state.json` change and
open `http://127.0.0.1:8777/overlay` in any browser.

## Development

- Go sidecar: `cd vote-engine && go test ./...`
- Lua mod: `lua tests/run.lua`
- Architecture decisions: [`docs/ADR/`](./docs/ADR).

## Status

Working v1: vote-engine (both chat sources + overlay + bridge, headless-testable
via `--simulate`) and the ChaosMod executor are complete and tested.

One follow-up needs an in-game step: `give_item` currently spawns the item as a
world pickup at the player (always works). To upgrade it to a true inventory
insert, run [`tools/probe.lua`](./tools/probe.lua) in-game once (it dumps the
`UWEInventory` / `SN2CheatManager` candidates to `probe_output.txt`), then wire
the confirmed method into `mod/Scripts/items.lua`. See
[`docs/ADR/0003`](./docs/ADR/0003-item-grant-discovery.md).

## Credits

Reuses Lua utilities and patterns from [sub2_random](https://github.com/caesarakalaeii/sub2_random)
and others — see [CREDITS.md](./CREDITS.md).

## License

[GPLv3](./LICENSE).
