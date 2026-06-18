-- void_aggro.lua — make a spawned Void Leviathan Child HUNT the player.
--
-- The Collector hunts when the player carries the leviathan prey tag
-- (aggro_loop.lua). The Void child hunts by a DIFFERENT gate, reverse-engineered
-- live in the sibling sub2_cheatmenu repo (see CREDITS.md): it attacks iff the
-- player carries the gameplay tag(s) GE_OutOfBounds grants. So we harvest those
-- live tags off the player's OutOfBoundsCheckComponent and re-assert them on a
-- timer (they aren't maintained off a real out-of-bounds region) — making the
-- Void hunt anywhere without the player leaving the map.
--
-- The application + reporting reuse the unit-tested aggro.apply_prey_tags; only
-- the tag SOURCE differs (OOB effect vs leviathan volume). Engine reads are
-- pcall-guarded; absent the component, start() is a harmless no-op loop.

local log = require("log")
local UEHelpers = require("UEHelpers")
local aggro = require("aggro")

local M = {}

M.interval_ms = 500
M.started = false

local function get_player_pawn()
	local pc = UEHelpers.GetPlayerController()
	if not (pc and pc.IsValid and pc:IsValid()) then return nil end
	local pawn
	pcall(function() pawn = pc.Pawn end)
	if pawn and pawn.IsValid and pawn:IsValid() then return pawn end
	return nil
end

local function get_player_asc()
	local pawn = get_player_pawn()
	if not pawn then return nil end
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

-- Read an FGameplayTagContainer's explicit .GameplayTags array (SAFE to index;
-- never iterate the container userdata). Returns { {name, tag}, ... }.
local function read_tag_container(tc)
	local out = {}
	if not tc then return out end
	local arr; pcall(function() arr = tc.GameplayTags end)
	local n = 0; if arr then pcall(function() n = #arr end) end
	for i = 1, n do
		local t = arr[i]
		local nm; if t then pcall(function() nm = t.TagName:ToString() end) end
		if nm then out[#out + 1] = { name = nm, tag = t } end
	end
	return out
end

-- The tag(s) GE_OutOfBounds grants, read off the player's OutOfBoundsCheckComponent
-- (no need to actually be out of bounds), falling back to the GE class by name.
local function harvest_oob(cache)
	local names = {}
	local function ingest(granted)
		for _, e in ipairs(granted or {}) do
			if e.name and e.tag and not cache[e.name] then
				cache[e.name] = e.tag
				names[#names + 1] = e.name
			end
		end
	end

	local pawn = get_player_pawn()
	if pawn then
		local comp; pcall(function() comp = pawn.OutOfBoundsCheckComponent end)
		local geclass; if comp then pcall(function() geclass = comp.OutOfBoundsEffect end) end
		if geclass and geclass.IsValid and geclass:IsValid() then
			local cdo; pcall(function() cdo = geclass:GetCDO() end)
			if cdo and cdo.IsValid and cdo:IsValid() then
				local cont; pcall(function() cont = cdo.InheritableOwnedTagsContainer end)
				local combined; if cont then pcall(function() combined = cont.CombinedTags end) end
				ingest(read_tag_container(combined))
			end
		end
	end

	if #names == 0 and FindObject then
		local ok, geclass = pcall(FindObject, nil, "GE_OutOfBounds_C")
		if ok and geclass and geclass.IsValid and geclass:IsValid() then
			local cdo; pcall(function() cdo = geclass:GetCDO() end)
			if cdo and cdo.IsValid and cdo:IsValid() then
				local cont; pcall(function() cont = cdo.InheritableOwnedTagsContainer end)
				local combined; if cont then pcall(function() combined = cont.CombinedTags end) end
				ingest(read_tag_container(combined))
			end
		end
	end

	return names
end

local tag_cache = {} -- name -> live FGameplayTag userdata
local tag_names = nil -- array; nil until a successful harvest (then cached)

local deps = {
	get_player_asc = get_player_asc,
	find_tag = function(name) return tag_cache[name] end,
	add_loose_tag = function(asc, tag) return pcall(function() asc:BP_SetLooseGameplayTagCount(tag, 1) end) end,
	log = function(m) log.info(tostring(m)) end,
}

-- start(): idempotent; safe before a save loads (harvest no-ops until the player
-- exists). Reuses aggro.apply_prey_tags to assert the harvested OOB tags.
function M.start()
	if M.started then return end
	if not LoopAsync then
		log.warn("void_aggro: no LoopAsync — Void aggro unavailable")
		return
	end
	M.started = true
	local interval = math.floor(tonumber(M.interval_ms) or 500)
	if interval < 100 then interval = 500 end
	local last_sig
	local function gt()
		if not tag_names then
			local names = harvest_oob(tag_cache)
			if #names > 0 then tag_names = names end
		end
		if not tag_names then return end
		local ok, r = pcall(aggro.apply_prey_tags, deps, tag_names)
		local sig = (ok and type(r) == "table")
			and (tostring(r.asc) .. ":" .. tostring(#(r.applied or {})))
			or ("err:" .. tostring(r))
		if sig ~= last_sig then
			last_sig = sig
			if ok and type(r) == "table" then
				log.event("void_aggro.tags", { asc = r.asc, applied = r.applied, missing = r.missing })
			else
				log.event("void_aggro.error", { err = tostring(r) })
			end
		end
	end
	local function body()
		if ExecuteInGameThread then ExecuteInGameThread(gt) else gt() end
	end
	LoopAsync(interval, body)
	log.event("void_aggro.loop_started", { interval_ms = interval })
end

return M
