-- items.lua — grant the player an item. Two tracks (see docs/ADR + the README's
-- "Real item-grant API" note):
--   1. UWEInventory insert (preferred) — wired once tools/probe.lua confirms the
--      exact component + method in-game. Until then M.inventory_method is nil.
--   2. World-spawn fallback (always works) — spawn the item's BP_ pickup actor at
--      the player's location via the proven World:SpawnActor path (sub2_random
--      spawn_hook / RESEARCH.md "Decision 3"); the player swims into it.

local log = require("log")
local UEHelpers = require("UEHelpers")

local M = {}

-- Set by main.lua after the discovery probe identifies the real inventory
-- insert, e.g. { component = "UWEInventory", method = "AddItem" }. nil => the
-- world-spawn fallback is used.
M.inventory_method = nil

local function player_pawn()
	local pc = UEHelpers.GetPlayerController()
	if not (pc and pc:IsValid()) then return nil end
	local pawn
	pcall(function() pawn = pc.Pawn end)
	if pawn and pawn.IsValid and pawn:IsValid() then return pawn end
	return nil
end

local function load_class(path)
	if not path then return nil end
	local cls
	if StaticFindObject then pcall(function() cls = StaticFindObject(path) end) end
	if not (cls and cls.IsValid and cls:IsValid()) and LoadAsset then
		pcall(function() cls = LoadAsset(path) end)
	end
	return cls
end

-- Track 1: direct inventory insert. Stub until the probe wires M.inventory_method.
local function try_inventory_insert(_params, _count)
	if not M.inventory_method then return false end
	-- Wiring lands here post-probe: resolve the player's inventory component and
	-- the UUWEItemType asset, then call the confirmed UFunction. Returns true on
	-- success so give() skips the world-spawn fallback.
	return false
end

-- Track 2: spawn the item's world pickup near the player.
local function try_world_spawn(params)
	local cls = load_class(params.actorPath)
	if not cls then
		log.warn("items: could not load actor class " .. tostring(params.actorPath))
		return false
	end
	local pawn = player_pawn()
	if not pawn then return false end
	local world = UEHelpers.GetWorld()
	if not (world and world:IsValid()) then return false end
	local loc
	pcall(function() loc = pawn:K2_GetActorLocation() end)
	if not loc then return false end

	local spawned = false
	local function gt()
		pcall(function()
			world:SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 })
			spawned = true
		end)
	end
	if ExecuteInGameThread then ExecuteInGameThread(gt) else gt() end
	return spawned
end

-- give(params): params = { itemType=, actorPath=, count= }. Tries the inventory
-- insert first, then the world-spawn fallback. Returns true on success.
function M.give(params)
	params = params or {}
	local count = params.count or 1
	if try_inventory_insert(params, count) then
		log.event("items.give", { via = "inventory", item = params.itemType, count = count })
		return true
	end
	if try_world_spawn(params) then
		log.event("items.give", { via = "world_spawn", actor = params.actorPath })
		return true
	end
	log.warn("items: give failed for " .. tostring(params.itemType or params.actorPath))
	return false
end

return M
