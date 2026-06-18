-- main.lua — Sub2Chaos entry point (UE4SS auto-loads this). Re-runnable: Ctrl+R
-- in the UE4SS console reloads it. The mod is execution-only: it reads the
-- sidecar's chaos_state.json each tick and fires the winning event. All chat,
-- voting, timing and the vote overlay live in the vote-engine sidecar.

local config = require("config")
local log = require("log")
local cheats = require("cheats")
local items = require("items")
local aggro_loop = require("aggro_loop")
local buffs_mod = require("buffs")
local events = require("events")
local chaos = require("chaos")
local status_bridge = require("status_bridge")
local settings_bridge = require("settings_bridge")
local manifest = require("manifest")
local Spawn = require("spawn")
local announce = require("announce")
local UEHelpers = require("UEHelpers")

-- Write the SN2ModSettings registration at MODULE-LOAD time (SN2ModSettings
-- reads registrations ~100ms before our main runs; doing it here lands it for
-- the NEXT launch if we lose the race — harmless because gates are stable).
pcall(settings_bridge.write_manifest, nil, manifest.build())

local GATE_KEYS = {
	enable_chaos = "master",
	enable_good = "good",
	enable_bad = "bad",
	enable_chaotic = "chaos",
	enable_leviathans = "leviathans",
}

local function bootstrap()
	log.info("starting Sub2Chaos " .. manifest.VERSION)
	pcall(settings_bridge.start_loop)

	-- Live gate state, seeded from SN2ModSettings (or config defaults headless).
	local gates = {
		master = settings_bridge.poll("enable_chaos", config.enable_chaos) == true,
		good = settings_bridge.poll("enable_good", config.enable_good) == true,
		bad = settings_bridge.poll("enable_bad", config.enable_bad) == true,
		chaos = settings_bridge.poll("enable_chaotic", config.enable_chaotic) == true,
		leviathans = settings_bridge.poll("enable_leviathans", config.enable_leviathans) == true,
	}
	log.set_level(settings_bridge.poll("log_level", config.log_level) or "info")
	settings_bridge.subscribe("log_level", function(v)
		if type(v) == "string" then pcall(log.set_level, v) end
	end)
	for key, field in pairs(GATE_KEYS) do
		settings_bridge.subscribe(key, function(v)
			gates[field] = v == true
			log.info("gate " .. key .. " -> " .. tostring(v))
		end)
	end

	-- Live player tunables (SN2ModSettings sliders), seeded from config defaults.
	-- Handlers read ctx.tunables each fire, so slider changes apply immediately.
	local TUNABLE_KEYS = {
		"effect_duration_scale", "super_speed", "slomo_fast_rate", "slomo_slow_rate",
		"hurt_player_hp", "leviathan_spawn_distance", "swarm_size",
	}
	local tunables = {}
	for _, key in ipairs(TUNABLE_KEYS) do
		tunables[key] = settings_bridge.poll(key, config[key])
		settings_bridge.subscribe(key, function(v)
			if type(v) == "number" then
				tunables[key] = v
				log.info("tunable " .. key .. " -> " .. tostring(v))
			end
		end)
	end

	-- Vote-shaping sliders are written back to the sidecar (chaos_status.json),
	-- which applies them at the next round — so voting is tuned from the menu, not
	-- config.yaml. slider key -> status JSON field.
	local VOTE_KEYS = {
		vote_duration = "voteDurationSeconds",
		vote_options = "voteOptions",
		vote_cooldown = "voteCooldownSeconds",
	}
	local vote_overrides = {}
	for slider, field in pairs(VOTE_KEYS) do
		vote_overrides[field] = math.floor(settings_bridge.poll(slider, config[slider]))
		settings_bridge.subscribe(slider, function(v)
			if type(v) == "number" then
				vote_overrides[field] = math.floor(v)
				log.info("vote " .. slider .. " -> " .. tostring(v))
			end
		end)
	end

	-- Shared event catalog (installed alongside the mod).
	local cat, err = events.load_catalog(config.catalog_path)
	if not cat then
		log.error("could not load catalog at " .. config.catalog_path .. ": " .. tostring(err))
		cat = { list = {}, by_id = {} }
	else
		log.info("loaded " .. #cat.list .. " events from " .. config.catalog_path)
	end

	-- Temporary-effect timer manager + handler context.
	local buffs = buffs_mod.new()
	local function gameplay_active()
		if not FindFirstOf then return false end
		local pc = FindFirstOf("PlayerController")
		if not pc then return false end
		local ok, valid = pcall(function() return pc:IsValid() end)
		return ok and valid == true
	end

	-- Pause detection: UGameplayStatics::IsGamePaused(world). The sidecar halts
	-- voting whenever this is true (chaos_status.json `paused`), so the pause
	-- menu pauses the vote and queues the next event until the player resumes.
	local function game_paused()
		local ok, w = pcall(function() return UEHelpers.GetWorld() end)
		if not ok or not (w and w.IsValid and w:IsValid()) then return false end
		local gs
		if StaticFindObject then
			pcall(function() gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
		end
		if not (gs and gs.IsValid and gs:IsValid()) and FindFirstOf then
			pcall(function() gs = FindFirstOf("GameplayStatics") end)
		end
		if not gs then return false end
		local ok2, paused = pcall(function() return gs:IsGamePaused(w) end)
		return ok2 and paused == true
	end

	-- Engine adapter for spawn.lua. Every UE4SS global is pcall-wrapped so a bad
	-- call degrades to a no-op rather than crashing the loop. Ported from
	-- sub2_cheatmenu's SpawnCollectorLeviathan (see CREDITS.md).
	local function fallback_player()
		local controllers = FindAllOf and (FindAllOf("PlayerController") or FindAllOf("Controller"))
		if not controllers then return nil end
		for _, c in ipairs(controllers) do
			if c:IsValid() and c.Pawn and c.Pawn:IsValid() then return c.Pawn end
		end
		return nil
	end
	local function read_xyz(v)
		if not v then return nil end
		local function field(name)
			local ok, val = pcall(function() return v[name] end)
			if ok and type(val) == "number" then return val end
			return 0.0
		end
		return { X = field("X"), Y = field("Y"), Z = field("Z") }
	end
	local function get_player_transform()
		local player = (UEHelpers.GetPlayer and UEHelpers.GetPlayer()) or fallback_player()
		if not (player and player.IsValid and player:IsValid()) then return nil end
		local okLoc, loc = pcall(function() return player:K2_GetActorLocation() end)
		if not okLoc or not loc then return nil end
		local location = read_xyz(loc)
		if not location then return nil end
		local forward = { X = 1.0, Y = 0.0, Z = 0.0 }
		local okFwd, fwd = pcall(function() return player:GetActorForwardVector() end)
		if okFwd and fwd then forward = read_xyz(fwd) or forward end
		return { location = location, forward = forward }
	end
	local function get_world()
		local ok, w = pcall(function() return UEHelpers.GetWorld() end)
		if ok and w and w.IsValid and w:IsValid() then return w end
		local player = fallback_player()
		if player then
			local ok2, w2 = pcall(function() return player:GetWorld() end)
			if ok2 and w2 and w2.IsValid and w2:IsValid() then return w2 end
		end
		return nil
	end
	local function set_collision_ignored(cls)
		if not (cls and cls.IsValid and cls:IsValid()) then return end
		local ok, cdo = pcall(function() return cls:GetCDO() end)
		if not ok or not (cdo and cdo.IsValid and cdo:IsValid()) then return end
		pcall(function() cdo.SpawnCollisionHandlingMethod = 1 end) -- AlwaysSpawn
	end
	local spawn_deps = {
		log = function(m) log.info(tostring(m)) end,
		rng = math.random,
		get_world = get_world,
		get_player_transform = get_player_transform,
		set_collision_ignored = set_collision_ignored,
		static_find_object = function(path)
			local ok, o = pcall(StaticFindObject, path); if ok then return o end
		end,
		find_object = function(name)
			local ok, o = pcall(FindObject, nil, name); if ok then return o end
		end,
		find_first_of = function(name)
			local ok, o = pcall(FindFirstOf, name); if ok then return o end
		end,
		load_asset = function(path) if LoadAsset then pcall(LoadAsset, path) end end,
		class_loaded = function(cfg)
			if cfg and cfg.class_path and cfg.class_path ~= "" then
				local ok, o = pcall(StaticFindObject, cfg.class_path)
				if ok and o and o.IsValid and o:IsValid() then return true end
			end
			if cfg and cfg.class_short_name and cfg.class_short_name ~= "" then
				local ok, o = pcall(FindObject, nil, cfg.class_short_name)
				if ok and o and o.IsValid and o:IsValid() then return true end
			end
			return false
		end,
	}

	local ctx = {
		cheats = cheats,
		items = items,
		aggro = aggro_loop,
		buffs = buffs,
		log = log,
		now = function() return os.time() end,
		default_swim_speed = config.default_swim_speed,
		gameplay_active = gameplay_active,
		game_paused = game_paused,
		spawn = function(cfg) return Spawn.spawn(spawn_deps, cfg) end,
		tunables = tunables,
	}

	-- Pre-load the Collector class so the FIRST spawn works on a cold save. A
	-- single LoadAsset of a streamed class can miss, so nudge it on a timer until
	-- the class is in memory, then stop. Idempotent; safe before a save loads.
	announce.configure(function() return UEHelpers.GetWorld() end)
	local collector_cfg = events.spawn_config((cat.by_id["spawn_leviathan"] or {}).params, 1)
	if LoopInGameThreadWithDelay then
		local handle
		handle = LoopInGameThreadWithDelay(1500, function()
			if Spawn.preload(spawn_deps, collector_cfg) then
				log.info("spawn: Collector class loaded — leviathan events ready")
				if CancelDelayedAction and handle then pcall(CancelDelayedAction, handle) end
			end
		end)
	end

	-- Clear any temporary effect left stuck by a prior session / Ctrl+R reload.
	pcall(events.normalize, ctx)

	-- Leviathan aggro loop (idempotent; safe before a save loads).
	aggro_loop.interval_ms = config.aggro_interval_ms or 500
	pcall(aggro_loop.start)

	-- The chaos poll/dispatch loop.
	chaos.install({
		vote_path = config.vote_bridge_path,
		status_path = config.status_bridge_path,
		interval_ms = config.poll_interval_ms,
		by_id = cat.by_id,
		handlers = events.handlers,
		ctx = ctx,
		buffs = buffs,
		gates = function() return gates end,
		status = status_bridge,
		vote_overrides = function() return vote_overrides end,
		announce = function(label, secs) return announce.show(label, secs) end,
		version = manifest.VERSION,
		log = log,
	})

	log.info("ready — polling " .. config.vote_bridge_path)
end

local ok, err = pcall(bootstrap)
if not ok then log.error("bootstrap failed: " .. tostring(err)) end
