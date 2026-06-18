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

	-- Player-facing tunables (also exposed as SN2ModSettings sliders; see
	-- manifest.lua). These are the fallbacks when SN2ModSettings is absent; the
	-- live slider value overrides them at runtime via settings_bridge.
	-- Vote shaping (menu sliders). Written back to the sidecar via
	-- chaos_status.json so the player tunes voting from the in-game menu, not
	-- config.yaml. The sidecar applies them at the next round.
	vote_duration = 30,             -- voting window length (seconds)
	vote_options = 4,               -- options per round (viewers type 1..N)
	vote_cooldown = 20,             -- gap after a winner before the next vote

	effect_duration_scale = 1.0,    -- multiplies timed-effect durations
	super_speed = 1500,             -- swim speed during the Super Swim Speed event
	slomo_fast_rate = 2.5,          -- Fast World time dilation (>1)
	slomo_slow_rate = 0.4,          -- Molasses World time dilation (<1)
	hurt_player_hp = 25,            -- HP the Take Damage event leaves the player at
	leviathan_spawn_distance = 800, -- how far ahead leviathans spawn (UE units)
	swarm_size = 3,                 -- leviathans the swarm event spawns

	-- Bridge + catalog paths. Resolved relative to the game's working dir
	-- (Binaries/Win64), same as sub2_random's *_enabled.flag / seed.flag writes.
	vote_bridge_path = "./ue4ss/Mods/Sub2Chaos/chaos_state.json",
	status_bridge_path = "./ue4ss/Mods/Sub2Chaos/chaos_status.json",
	catalog_path = "./ue4ss/Mods/Sub2Chaos/events.json",
}
