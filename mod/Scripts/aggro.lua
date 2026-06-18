-- aggro.lua — make substituted leviathans hunt the player ANYWHERE.
--
-- WHY THIS EXISTS (reverse-engineered live in the sibling sub2_cheatmenu repo,
-- 2026-06-03, and CONFIRMED in-game by the user):
-- The Collector Leviathan's AI is a utility-scored behaviour tree. Its only
-- on-foot attack branch, "Eat Player Short Range", scores > 0 only when the
-- *target* (the player) passes that branch's target-evaluation filter. The
-- filter validates the player as prey IFF the player's UWEAbilitySystemComponent
-- carries the gameplay tag `Volume.Leviathan.GenericPlayer`. In the world, the
-- leviathan biome's box volumes push that tag onto any actor inside them via
-- GASLooseTags, so a player standing in the biome is huntable and one outside it
-- is not — which is exactly why a Collector spawned (or substituted) anywhere
-- else just wandered.
--
-- Proven by live A/B: injecting the tag onto the *creature* did nothing;
-- injecting it onto the *player* flipped "Eat Player Short Range" to
-- UtilityTarget 0.2 and the Collector committed to an attack. So the fix is
-- target-side: keep the player tagged and any leviathan that perceives the
-- player hunts it ANYWHERE.
--
-- The tag isn't maintained outside a real volume, so it must be re-asserted on a
-- timer (spawn_hook.lua drives the loop; this module holds the pure, test-covered
-- orchestration). An FGameplayTag can't be reliably constructed from a string in
-- Lua, so the engine adapter harvests a live one from a loaded volume's
-- GASLooseTags (see spawn_hook.lua / introspect.find_live_tag).
--
-- This SUPERSEDES the long "Collector is WorldPop-walled / needs the
-- SpawnBalancer / spawns a 0-component shell" investigation (ADR-0010 and the
-- WorldPopSpawner spike): the body assembles fine via plain World:SpawnActor once
-- collision rejection is disabled (AlwaysSpawn), and the AI works once the player
-- is prey-tagged. See ADR-0011.

local M = {}

-- Tags that mark the player as valid leviathan prey. `GenericPlayer` is the
-- player-side tag proven to flip the gate; `Generic` is applied too so the
-- player's tag set mirrors an in-biome player's exactly (belt-and-suspenders).
M.PREY_TAGS = { "Volume.Leviathan.GenericPlayer", "Volume.Leviathan.Generic" }

-- apply_prey_tags(deps, tags): ensure the player's ability system carries the
-- prey tags. Pure orchestration over an injected engine adapter so it is
-- unit-testable:
--   deps.get_player_asc()         -> ability-system userdata, or nil if unavailable
--   deps.find_tag(name)           -> live FGameplayTag for `name`, or nil if absent
--   deps.add_loose_tag(asc, tag)  -> apply the tag (count 1); truthy on success
--   deps.log(msg)                 -> optional
-- Returns { asc = bool, applied = {names}, missing = {names} } so the caller (and
-- tests) can see what happened without reading game state back (GAS tag read-back
-- from Lua is unreliable). Never throws: a missing adapter fn degrades to "missing".
function M.apply_prey_tags(deps, tags)
    tags = tags or M.PREY_TAGS
    local res = { asc = false, applied = {}, missing = {} }
    if type(deps) ~= "table" then return res end

    local asc = deps.get_player_asc and deps.get_player_asc() or nil
    if not asc then return res end
    res.asc = true

    for _, name in ipairs(tags) do
        local tag = deps.find_tag and deps.find_tag(name) or nil
        local ok = false
        if tag and deps.add_loose_tag then
            ok = deps.add_loose_tag(asc, tag) and true or false
        end
        if ok then
            res.applied[#res.applied + 1] = name
        else
            res.missing[#res.missing + 1] = name
        end
    end
    return res
end

-- clear_prey_tags(deps, tags): the inverse — remove the prey tags from the
-- player's ability system (used when the user toggles substitution/aggro OFF so
-- leviathans stop hunting the player). Mirrors apply_prey_tags' contract but with
--   deps.remove_loose_tag(asc, tag) -> remove the tag; truthy on success
-- Returns { asc = bool, removed = {names}, missing = {names} } (missing = still
-- present, i.e. the removal call failed/was unavailable). Never throws.
function M.clear_prey_tags(deps, tags)
    tags = tags or M.PREY_TAGS
    local res = { asc = false, removed = {}, missing = {} }
    if type(deps) ~= "table" then return res end

    local asc = deps.get_player_asc and deps.get_player_asc() or nil
    if not asc then return res end
    res.asc = true

    for _, name in ipairs(tags) do
        local tag = deps.find_tag and deps.find_tag(name) or nil
        local ok = false
        if tag and deps.remove_loose_tag then
            ok = deps.remove_loose_tag(asc, tag) and true or false
        end
        if ok then
            res.removed[#res.removed + 1] = name
        else
            res.missing[#res.missing + 1] = name
        end
    end
    return res
end

return M
