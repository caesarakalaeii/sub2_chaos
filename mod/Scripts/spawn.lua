-- spawn.lua — pure leviathan-spawn logic.
--
-- The SpawnCreature dev cheat returns a 0-component shell for the Collector
-- Leviathan (WorldPop-managed), so it "succeeds" but nothing huntable appears.
-- The working path — proven live in the sibling sub2_cheatmenu repo
-- (Mods/SpawnCollectorLeviathan) — is plain UWorld:SpawnActor of the resolved
-- BP class with AlwaysSpawn forced on the class CDO so an overlap with terrain
-- isn't rejected. This module is the pure orchestration of that, ported from
-- sub2_cheatmenu/Scripts/spawn.lua (see CREDITS.md); every engine call is
-- injected via `deps` so it unit-tests with no engine.
--
-- `deps` contract:
--   static_find_object(fullPath)  -> UObject|nil   (StaticFindObject)
--   find_object(shortName)        -> UObject|nil   (FindObject by short name)
--   find_first_of(shortName)      -> UObject|nil   (FindFirstOf, a live instance)
--   load_asset(packagePath)       -> ()            (LoadAsset; return ignored)
--   class_loaded(cfg)             -> boolean       (is the class in memory?)
--   set_collision_ignored(cls)    -> ()            (force AlwaysSpawn on the CDO)
--   get_world()                   -> UWorld|nil    (has :SpawnActor)
--   get_player_transform()        -> { location={X,Y,Z}, forward={X,Y,Z} } | nil
--   rng()                         -> number in [0,1)  (optional)
--   log(message)                  -> ()            (optional)
--
-- `cfg` fields (sourced from events.json params, merged over defaults):
--   class_path, class_short_name, instance_short_name, asset_path
--   spawn_distance, spawn_vertical_offset, spawn_count
--   spawn_jitter, spawn_jitter_vertical, ignore_collisions

local Spawn = {}

local function is_valid(o)
	return o ~= nil and type(o.IsValid) == "function" and o:IsValid()
end

-- Try every in-memory class lookup once, in order of reliability.
local function try_lookup(deps, cfg)
	if cfg.class_path and cfg.class_path ~= "" then
		local found, o = pcall(deps.static_find_object, cfg.class_path)
		if found and is_valid(o) then return o, "class_path" end
	end
	if cfg.class_short_name and cfg.class_short_name ~= "" and deps.find_object then
		local found, o = pcall(deps.find_object, cfg.class_short_name)
		if found and is_valid(o) then return o, "find_object" end
	end
	if cfg.instance_short_name and cfg.instance_short_name ~= "" and deps.find_first_of then
		local found, inst = pcall(deps.find_first_of, cfg.instance_short_name)
		if found and is_valid(inst) then
			local ok, cls = pcall(function() return inst:GetClass() end)
			if ok and is_valid(cls) then return cls, "instance" end
		end
	end
	return nil
end

-- Asset paths to try loading, most-specific last. Loading just the package
-- sometimes does NOT register the generated `..._C` class on a cold save, so we
-- also try the UBlueprint object and the generated class. Pure (string-only).
function Spawn.asset_load_paths(cfg)
	local out, seen = {}, {}
	local function add(p)
		if p and p ~= "" and not seen[p] then
			seen[p] = true
			out[#out + 1] = p
		end
	end
	add(cfg.asset_path)
	local pkg = cfg.asset_path
	if pkg and pkg ~= "" then
		local name = pkg:match("([^/]+)$")
		if name then
			add(pkg .. "." .. name) -- UBlueprint object
			add(pkg .. "." .. name .. "_C") -- generated class
		end
	end
	add(cfg.class_path)
	return out
end

-- Ensure the class is loaded. Returns true if it is (now) in memory. LoadAsset
-- of cooked/streamed assets can be deferred, so a false return means "retry on a
-- later tick" (main.lua runs a startup timer for exactly this).
function Spawn.preload(deps, cfg)
	if deps.class_loaded and deps.class_loaded(cfg) then return true end
	if deps.load_asset then
		for _, p in ipairs(Spawn.asset_load_paths(cfg)) do
			pcall(deps.load_asset, p)
			if deps.class_loaded and deps.class_loaded(cfg) then return true end
		end
	end
	return deps.class_loaded and deps.class_loaded(cfg) or false
end

-- Resolve the UClass to spawn, loading the asset and retrying if needed.
function Spawn.resolve_class(deps, cfg)
	local cls, how = try_lookup(deps, cfg)
	if cls then return cls, how end
	if (cfg.asset_path and cfg.asset_path ~= "") or (cfg.class_path and cfg.class_path ~= "") then
		for _, p in ipairs(Spawn.asset_load_paths(cfg)) do
			if deps.load_asset then pcall(deps.load_asset, p) end
			cls, how = try_lookup(deps, cfg)
			if cls then return cls, how .. "+asset" end
		end
	end
	return nil, "unresolved"
end

-- Resolve + (unless disabled) force AlwaysSpawn on the CDO so a big creature
-- overlapping terrain isn't rejected at spawn. Returns (UClass, how) or (nil, why).
function Spawn.resolve_for_spawn(deps, cfg)
	local cls, how = Spawn.resolve_class(deps, cfg)
	if not cls then return nil, "could not resolve class" end
	if cfg.ignore_collisions ~= false and deps.set_collision_ignored then
		pcall(deps.set_collision_ignored, cls)
	end
	return cls, how
end

-- World-space spawn point: player location + `distance` along forward, a
-- vertical nudge, and random jitter so repeated spawns don't land on the same
-- point (the collision check rejects an overlap). Pure math, no engine types.
function Spawn.compute_spawn_location(playerLoc, forward, opts)
	opts = opts or {}
	local dist = opts.distance or 0
	local vert = opts.vertical or 0
	local jitter = opts.jitter or 0
	local jitterV = opts.jitter_vertical or 0
	local rng = opts.rng or math.random
	local f = forward or { X = 1, Y = 0, Z = 0 }
	local function offset(range)
		if range <= 0 then return 0 end
		return (rng() * 2 - 1) * range
	end
	return {
		X = playerLoc.X + (f.X or 0) * dist + offset(jitter),
		Y = playerLoc.Y + (f.Y or 0) * dist + offset(jitter),
		Z = playerLoc.Z + (f.Z or 0) * dist + vert + offset(jitterV),
	}
end

-- Yaw (degrees) matching the player's facing on the XY plane.
function Spawn.compute_yaw(forward)
	local f = forward or { X = 1, Y = 0 }
	return math.deg(math.atan(f.Y or 0, f.X or 0))
end

-- How many of the given actors are still valid (alive). SpawnActor returning a
-- valid actor does NOT guarantee the creature persists — it can be culled/killed.
function Spawn.count_alive(actors)
	local n = 0
	for _, a in ipairs(actors or {}) do
		if is_valid(a) then n = n + 1 end
	end
	return n
end

-- Spawn `cls` once at each {X,Y,Z} in `locations`, all sharing `rot`. Returns
-- (spawnedActors, failedCount). Never throws.
function Spawn.spawn_actors(world, cls, locations, rot)
	rot = rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
	local spawned, failed = {}, 0
	for _, L in ipairs(locations or {}) do
		local ok, actor = pcall(function() return world:SpawnActor(cls, L, rot) end)
		if ok and is_valid(actor) then
			spawned[#spawned + 1] = actor
		else
			failed = failed + 1
		end
	end
	return spawned, failed
end

-- Resolve the class, work out where to put the creature(s) (jittered per actor)
-- and ask the world to spawn them. Returns (spawnedActors, how, failedCount), or
-- (nil, reason) on a hard failure. Never throws.
function Spawn.spawn(deps, cfg)
	local world = deps.get_world and deps.get_world() or nil
	if not is_valid(world) then return nil, "no world" end

	local cls, how = Spawn.resolve_for_spawn(deps, cfg)
	if not cls then return nil, how end

	local t = deps.get_player_transform and deps.get_player_transform() or nil
	if not t or not t.location then return nil, "no player" end

	local rot = { Pitch = 0.0, Yaw = Spawn.compute_yaw(t.forward), Roll = 0.0 }
	local rng = deps.rng or math.random
	local count = cfg.spawn_count or 1

	local locations = {}
	for _ = 1, count do
		locations[#locations + 1] = Spawn.compute_spawn_location(t.location, t.forward, {
			distance = cfg.spawn_distance or 0,
			vertical = cfg.spawn_vertical_offset or 0,
			jitter = cfg.spawn_jitter or 0,
			jitter_vertical = cfg.spawn_jitter_vertical or 0,
			rng = rng,
		})
	end

	local spawned, failed = Spawn.spawn_actors(world, cls, locations, rot)
	if #spawned == 0 then return nil, "all spawns rejected (collision at spawn point?)" end
	return spawned, how, failed
end

return Spawn
