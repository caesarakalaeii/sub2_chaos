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

-- spawn_config(params, count) -> a spawn.lua config table. Event params from
-- events.json (class_path / asset_path / spawn_distance / ...) override these
-- defaults; `count` is how many to spawn this call. AlwaysSpawn is on by default
-- so a leviathan overlapping terrain isn't rejected.
function M.spawn_config(params, count)
	params = params or {}
	local cfg = {
		spawn_distance = 800.0,
		spawn_vertical_offset = 0.0,
		spawn_jitter = 0.0,
		spawn_jitter_vertical = 0.0,
		ignore_collisions = true,
	}
	for k, v in pairs(params) do cfg[k] = v end
	cfg.spawn_count = count or params.count or 1
	-- Swarms want spread so the bodies don't collide/cull each other at one point.
	if cfg.spawn_count > 1 and (cfg.spawn_jitter or 0) <= 0 then
		cfg.spawn_jitter = 1600.0
	end
	return cfg
end

-- tunable(ctx, key, default): read a live player tunable (an SN2ModSettings
-- slider, seeded from config.lua). Falls back to `default` when ctx carries no
-- tunables (headless / unit tests), so handlers behave identically off-game.
local function tunable(ctx, key, default)
	local t = ctx and ctx.tunables
	local v = t and t[key]
	if type(v) == "number" then return v end
	return default
end

-- scaled_duration(ctx, base): apply the effect-duration multiplier slider to a
-- base duration (seconds), clamped to >= 1s and rounded to a whole second.
local function scaled_duration(ctx, base)
	local d = (base or 0) * tunable(ctx, "effect_duration_scale", 1.0)
	if d < 1 then d = 1 end
	return math.floor(d + 0.5)
end

-- Handler table, keyed by event id. Each returns truthy on success.
M.handlers = {
	spawn_leviathan = function(ctx, ev)
		local p = ev.params or {}
		ctx.aggro.start() -- ensure the prey-tag loop runs so it HUNTS
		-- Spawn via UWorld:SpawnActor (ctx.spawn). The SpawnCreature cheat returns
		-- a non-functional shell for the Collector, so SpawnActor of the resolved
		-- BP class is the working path; fall back to the cheat only if unavailable.
		if ctx.spawn then
			local cfg = M.spawn_config(p, 1)
			cfg.spawn_distance = tunable(ctx, "leviathan_spawn_distance", cfg.spawn_distance)
			local spawned, how = ctx.spawn(cfg)
			if spawned then
				ctx.log.event("chaos.spawn", { id = ev.id, how = how, n = #spawned })
				return true
			end
			ctx.log.warn("chaos: spawn_leviathan failed: " .. tostring(how))
			return false
		end
		return ctx.cheats.spawn_creature(p.creature or "CollectorLeviathan")
	end,

	-- A single Void Leviathan child. The Void hunts via the out-of-bounds tag, not
	-- the Collector prey tag, so it needs ctx.void_aggro (see void_aggro.lua).
	spawn_void_child = function(ctx, ev)
		local p = ev.params or {}
		if ctx.void_aggro then ctx.void_aggro.start() end
		if ctx.spawn then
			local cfg = M.spawn_config(p, 1)
			cfg.spawn_distance = tunable(ctx, "leviathan_spawn_distance", cfg.spawn_distance)
			local spawned, how = ctx.spawn(cfg)
			if spawned then
				ctx.log.event("chaos.spawn", { id = ev.id, how = how, n = #spawned })
				return true
			end
			ctx.log.warn("chaos: spawn_void_child failed: " .. tostring(how))
			return false
		end
		return ctx.cheats.spawn_creature(p.creature or "VoidLeviathanChild")
	end,

	spawn_leviathan_swarm = function(ctx, ev)
		local p = ev.params or {}
		-- Swarm is Void children -> Void aggro (out-of-bounds tag), not Collector.
		if ctx.void_aggro then ctx.void_aggro.start() end
		local count = math.floor(tunable(ctx, "swarm_size", p.count or 3))
		if ctx.spawn then
			local cfg = M.spawn_config(p, count)
			cfg.spawn_distance = tunable(ctx, "leviathan_spawn_distance", cfg.spawn_distance)
			local spawned, how = ctx.spawn(cfg)
			if spawned then
				ctx.log.event("chaos.spawn", { id = ev.id, how = how, n = #spawned })
				return true
			end
			ctx.log.warn("chaos: spawn_leviathan_swarm failed: " .. tostring(how))
			return false
		end
		local ok = true
		for _ = 1, count do
			ok = ctx.cheats.spawn_creature(p.creature or "VoidLeviathanChild") and ok
		end
		return ok
	end,

	god_mode = function(ctx, ev)
		local ok = ctx.cheats.god() -- toggle ON
		ctx.buffs:add(ev.buffKey or "god", scaled_duration(ctx, ev.durationSeconds or 15), ctx.now(),
			function() ctx.cheats.god() end) -- toggle OFF on expiry
		return ok
	end,

	super_speed = function(ctx, ev)
		local p = ev.params or {}
		local ok = ctx.cheats.swim_speed(tunable(ctx, "super_speed", p.speed or 1500))
		ctx.buffs:add(ev.buffKey or "swim", scaled_duration(ctx, ev.durationSeconds or 20), ctx.now(),
			function() ctx.cheats.swim_speed(ctx.default_swim_speed or 400) end)
		return ok
	end,

	slomo_fast = function(ctx, ev)
		local p = ev.params or {}
		local ok = ctx.cheats.slomo(tunable(ctx, "slomo_fast_rate", p.rate or 2.5))
		ctx.buffs:add(ev.buffKey or "slomo", scaled_duration(ctx, ev.durationSeconds or 15), ctx.now(),
			function() ctx.cheats.slomo(1.0) end)
		return ok
	end,

	slomo_slow = function(ctx, ev)
		local p = ev.params or {}
		local ok = ctx.cheats.slomo(tunable(ctx, "slomo_slow_rate", p.rate or 0.4))
		ctx.buffs:add(ev.buffKey or "slomo", scaled_duration(ctx, ev.durationSeconds or 12), ctx.now(),
			function() ctx.cheats.slomo(1.0) end)
		return ok
	end,

	noclip = function(ctx, ev)
		local ok = ctx.cheats.noclip() -- SN2 NoClip toggle (Ghost no-ops on the swim pawn)
		ctx.buffs:add(ev.buffKey or "move", scaled_duration(ctx, ev.durationSeconds or 15), ctx.now(),
			function() ctx.cheats.noclip() end) -- toggle back off on expiry
		return ok
	end,

	heal_full = function(ctx, _) return ctx.cheats.my_health(100) end,

	hurt_player = function(ctx, ev)
		local p = ev.params or {}
		return ctx.cheats.my_health(tunable(ctx, "hurt_player_hp", p.hp or 25))
	end,

	give_item = function(ctx, ev)
		local p = ev.params or {}
		-- Prefer the dev Give cheat (inventory grant, reliable like SpawnCreature).
		-- Fall back to the world-spawn pickup only if the cheat is unavailable.
		if ctx.cheats.give and p.itemName then
			if ctx.cheats.give(p.itemName .. " " .. tostring(p.count or 1)) then return true end
		end
		return ctx.items.give(p)
	end,

	unlock_all_recipes = function(ctx, _) return ctx.cheats.unlock_all_recipes() end,

	-- Despawn creatures only — DestroyCreatures("", 9999) targets AI, NOT the
	-- player. KillAll() would kill the player too (the bug this fixes).
	kill_all_creatures = function(ctx, _) return ctx.cheats.destroy_creatures() end,
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
