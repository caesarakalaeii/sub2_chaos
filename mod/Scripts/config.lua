-- config.lua — static defaults for the in-game side. The chat/voting/timing
-- config all lives in the sidecar; the mod only needs the execution gates and a
-- few paths. SN2ModSettings (when present) overrides the enable_* / log_level
-- values live via settings_bridge.

return {
	-- Gates (also exposed in the SN2ModSettings UI; see manifest.lua).
	enable_chaos = true,      -- master switch
	enable_good = true,       -- heal / god / speed / items
	enable_bad = true,        -- leviathans / damage
	enable_chaotic = true,    -- slomo / ghost / swarms
	enable_leviathans = true, -- the spiciest events
	enable_hotkeys = false,   -- debug/manual-test keys (off for normal play)
	log_level = "info",

	-- Loop + effect tuning.
	poll_interval_ms = 300,    -- chaos bridge poll cadence (integer; LoopAsync rejects floats)
	aggro_interval_ms = 500,   -- prey-tag re-assert cadence
	default_swim_speed = 400,  -- "normal" swim speed super_speed reverts to (tune in UAT)

	-- Bridge + catalog paths. Resolved relative to the game's working dir
	-- (Binaries/Win64), same as sub2_random's *_enabled.flag / seed.flag writes.
	vote_bridge_path = "./ue4ss/Mods/Sub2Chaos/chaos_state.json",
	status_bridge_path = "./ue4ss/Mods/Sub2Chaos/chaos_status.json",
	catalog_path = "./ue4ss/Mods/Sub2Chaos/events.json",
}
