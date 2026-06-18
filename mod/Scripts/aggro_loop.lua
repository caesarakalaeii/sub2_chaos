-- aggro_loop.lua — re-assert the player's leviathan prey-tag on a slow loop so
-- spawned leviathans HUNT the player. Lean extract of sub2_random's
-- spawn_hook.start_static_aggro_loop (ADR-0011 there), without the substitution
-- machinery: O(1) per tick, just the player ASC + two tags.

local log = require("log")
local UEHelpers = require("UEHelpers")
local aggro = require("aggro")

local M = {}

M.interval_ms = 500
M.started = false
M._counter = 0
M._scan_every = 4 -- throttle the (unresolved) tag scan to 1 in N ticks
local tag_cache = {}

local function get_player_asc()
	local pc = UEHelpers.GetPlayerController()
	local pawn
	if pc and pc:IsValid() then pcall(function() pawn = pc.Pawn end) end
	if not (pawn and pawn.IsValid and pawn:IsValid()) then return nil end
	for _, getter in ipairs({
		function() return pawn.UWEAbilitySystemComponent end,
		function() return pawn:GetASC() end,
		function() return pawn.AbilitySystemComponent end,
		function() return pawn:GetAbilitySystemComponent() end,
	}) do
		local ok, v = pcall(getter)
		if ok and v and v.IsValid and v:IsValid() then return v end
	end
	return nil
end

local function scan_due()
	if M._scan_every <= 1 then return true end
	return (M._counter % M._scan_every) == 0
end

-- Harvest a live FGameplayTag by name from a loaded volume component (a tag
-- can't be reliably built from a string in Lua). Cached while its source is
-- valid; a freed source would dangle, so re-validate via :IsValid() each read.
local function cached_tag(name)
	local e = tag_cache[name]
	if not e then return nil end
	local ok, valid = pcall(function() return e.src and e.src:IsValid() end)
	if ok and valid then return e.tag end
	tag_cache[name] = nil
	return nil
end

local function harvest_tag(name)
	local live = cached_tag(name)
	if live then return live end
	if not scan_due() then return nil end
	if not FindAllOf then return nil end
	local classes = { "BoxVolumeComponent", "SphereVolumeComponent", "ShapeVolumeComponent",
		"StaticMeshVolumeComponent", "UWEVolumeActorComponent" }
	for _, cls in ipairs(classes) do
		local comps = FindAllOf(cls)
		if comps then
			for _, c in ipairs(comps) do
				local vd; pcall(function() vd = c.VolumeData end)
				if vd then
					for _, field in ipairs({ "GASLooseTags", "TagsToAdd", "VolumeTags" }) do
						local tc; pcall(function() tc = vd[field] end)
						local arr; if tc then pcall(function() arr = tc.GameplayTags end) end
						local n = 0; if arr then pcall(function() n = #arr end) end
						for i = 1, n do
							local t = arr[i]
							local tn; if t then pcall(function() tn = t.TagName:ToString() end) end
							if tn == name then
								tag_cache[name] = { tag = t, src = c }
								return t
							end
						end
					end
				end
			end
		end
	end
	return nil
end

local deps = {
	get_player_asc = get_player_asc,
	find_tag = harvest_tag,
	add_loose_tag = function(asc, tag) return pcall(function() asc:BP_SetLooseGameplayTagCount(tag, 1) end) end,
	remove_loose_tag = function(asc, tag) return pcall(function() asc:BP_SetLooseGameplayTagCount(tag, 0) end) end,
}

-- start(): idempotent; safe to call at the title screen (apply_prey_tags no-ops
-- until the player ASC exists). Driven by LoopAsync (integer ms).
function M.start()
	if M.started then return end
	if not LoopAsync then
		log.warn("aggro_loop: no LoopAsync — leviathan aggro unavailable")
		return
	end
	M.started = true
	local interval = math.floor(tonumber(M.interval_ms) or 500)
	if interval < 100 then interval = 500 end
	local function gt()
		M._counter = M._counter + 1
		local ok, r = pcall(aggro.apply_prey_tags, deps)
		local sig = (ok and type(r) == "table")
			and (tostring(r.asc) .. ":" .. tostring(#(r.applied or {})))
			or ("err:" .. tostring(r))
		if sig ~= M._last_sig then
			M._last_sig = sig
			if ok and type(r) == "table" then
				log.event("aggro.tags", { asc = r.asc, applied = r.applied, missing = r.missing })
			else
				log.event("aggro.error", { err = tostring(r) })
			end
		end
	end
	local function body()
		if ExecuteInGameThread then ExecuteInGameThread(gt) else gt() end
	end
	LoopAsync(interval, body)
	log.event("aggro.loop_started", { interval_ms = interval })
end

return M
