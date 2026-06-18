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
	local ctx = {
		cheats = cheats,
		items = items,
		aggro = aggro_loop,
		buffs = buffs,
		log = log,
		now = function() return os.time() end,
		default_swim_speed = config.default_swim_speed,
		gameplay_active = gameplay_active,
	}

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
		version = manifest.VERSION,
		log = log,
	})

	log.info("ready — polling " .. config.vote_bridge_path)
end

local ok, err = pcall(bootstrap)
if not ok then log.error("bootstrap failed: " .. tostring(err)) end
