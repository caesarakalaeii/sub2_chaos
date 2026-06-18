# ADR-0003 — Item grant: discovery + two-track implementation

## Status
Accepted (track 2 shipping; track 1 pending an in-game probe run).

## Context
The `give_item` event must put an item in the player's inventory. Mining
`sub2_random`'s research confirmed there is **no** add-to-inventory cheat today
and **no SDK/.usmap on disk** — Subnautica 2 types resolve at runtime via UE4SS
reflection. Known leads: the `UWEInventory` class, `UUWEItemType` assets (items
are `DA_<Name>_ItemType`; 2000+ in `sub2_random/mod/debug/recipe_items.tsv`),
`SN2PickupItem`, and world-spawnable `BP_<item>` actors under
`/Game/Blueprints/Items/Resources`.

## Decision
Two tracks in `mod/Scripts/items.lua`, tried in order by `items.give(params)`:

1. **`UWEInventory` insert (preferred).** Wired into `items.inventory_method`
   once confirmed. To confirm, run `tools/probe.lua` in-game once: it enumerates
   `SN2CheatManager` UFunctions, inventory-class UFunctions
   (AddItem/GiveItem/GrantItem/SpawnItem candidates), the player pawn's
   inventory-looking properties, and sample `UUWEItemType` ids — writing
   `probe_output.txt`. The confirmed method is then wired and `give_item` uses it.
2. **World-spawn fallback (ships now).** Spawn the item's `BP_<item>` pickup at
   the player's location via the proven `World:SpawnActor` path; the player
   collects it. Works with no probe, so `give_item` is functional in v1.

The `events.json` `give_item` params carry both an `itemType` (for the insert)
and an `actorPath` (for the fallback), so neither track is blocked on the other.

## Consequences
- `give_item` works in v1 via world-spawn; it upgrades to a true inventory
  insert with no catalog change once the probe result is wired.
- The default item is configurable in `events.json` and subject to in-game
  confirmation of the exact `actorPath` / `itemType`.
