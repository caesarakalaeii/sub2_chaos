-- events.lua — the chaos event catalog loader + handler table.
--
-- The catalog (events.json) is the SHARED source of truth with the Go
-- vote-engine. This module reads it for the in-game side and maps each event
-- `id` to a handler. Handlers take an injected `ctx` (cheats / items / aggro /
-- buffs / log), so they're unit-testable with no engine: they call the right
-- primitive and, for temporary events, register a revert with ctx.buffs.
--
-- ctx fields used by handlers:
--   ctx.cheats             -- the sub2_random cheat passthrough (god/slomo/...)
--   ctx.items              -- items.give(params)
--   ctx.aggro              -- aggro_loop.start()
--   ctx.buffs              -- a buffs instance (buffs:add(key, dur, now, revert))
--   ctx.now()              -- current time in seconds
--   ctx.default_swim_speed -- the "normal" swim speed to revert super_speed to

local json = require("json")

local M = {}

-- load_catalog(path) -> { list = {...}, by_id = {...} } or (nil, err)
function M.load_catalog(path)
	local f = io.open(path, "r")
	if not f then return nil, "cannot open " .. tostring(path) end
	local body = f:read("*a")
	f:close()
	local data, err = json.decode(body)
	if type(data) ~= "table" or type(data.events) ~= "table" then
		return nil, err or "no events array"
	end
	local by_id = {}
	for _, e in ipairs(data.events) do by_id[e.id] = e end
	return { list = data.events, by_id = by_id }
end

-- Handler table, keyed by event id. Each returns truthy on success.
M.handlers = {
	spawn_leviathan = function(ctx, ev)
		local p = ev.params or {}
		ctx.aggro.start() -- ensure the prey-tag loop runs so it HUNTS
		return ctx.cheats.spawn_creature(p.creature or "CollectorLeviathan")
	end,

	spawn_leviathan_swarm = function(ctx, ev)
		local p = ev.params or {}
		ctx.aggro.start()
		local ok = true
		for _ = 1, (p.count or 3) do
			ok = ctx.cheats.spawn_creature(p.creature or "VoidLeviathanChild") and ok
		end
		return ok
	end,

	god_mode = function(ctx, ev)
		local ok = ctx.cheats.god() -- toggle ON
		ctx.buffs:add(ev.buffKey or "god", ev.durationSeconds or 15, ctx.now(),
			function() ctx.cheats.god() end) -- toggle OFF on expiry
		return ok
	end,

	super_speed = function(ctx, ev)
		local p = ev.params or {}
		local ok = ctx.cheats.swim_speed(p.speed or 1500)
		ctx.buffs:add(ev.buffKey or "swim", ev.durationSeconds or 20, ctx.now(),
			function() ctx.cheats.swim_speed(ctx.default_swim_speed or 400) end)
		return ok
	end,

	slomo_fast = function(ctx, ev)
		local p = ev.params or {}
		local ok = ctx.cheats.slomo(p.rate or 2.5)
		ctx.buffs:add(ev.buffKey or "slomo", ev.durationSeconds or 15, ctx.now(),
			function() ctx.cheats.slomo(1.0) end)
		return ok
	end,

	slomo_slow = function(ctx, ev)
		local p = ev.params or {}
		local ok = ctx.cheats.slomo(p.rate or 0.4)
		ctx.buffs:add(ev.buffKey or "slomo", ev.durationSeconds or 12, ctx.now(),
			function() ctx.cheats.slomo(1.0) end)
		return ok
	end,

	noclip = function(ctx, ev)
		local ok = ctx.cheats.ghost() -- no collision + fly
		ctx.buffs:add(ev.buffKey or "move", ev.durationSeconds or 15, ctx.now(),
			function() ctx.cheats.walk() end) -- restore gravity/collision
		return ok
	end,

	heal_full = function(ctx, _) return ctx.cheats.my_health(100) end,

	hurt_player = function(ctx, ev)
		local p = ev.params or {}
		return ctx.cheats.my_health(p.hp or 25)
	end,

	give_item = function(ctx, ev) return ctx.items.give(ev.params or {}) end,

	unlock_all_recipes = function(ctx, _) return ctx.cheats.unlock_all_recipes() end,

	kill_all_creatures = function(ctx, _) return ctx.cheats.kill_all() end,
}

-- normalize(ctx): clear any temporary effect that could be stuck from a prior
-- session / Ctrl+R reload (the buffs table resets on reload, so a revert may
-- never have fired). Cheap and idempotent; run once at bootstrap.
function M.normalize(ctx)
	pcall(function() ctx.cheats.slomo(1.0) end)
	pcall(function() ctx.cheats.swim_speed(ctx.default_swim_speed or 400) end)
	pcall(function() ctx.cheats.walk() end)
end

return M
