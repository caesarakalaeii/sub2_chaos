local Spawn = require("spawn")

describe("spawn.asset_load_paths", function()
	it("expands the package into UBlueprint + generated-class paths", function()
		local paths = Spawn.asset_load_paths({
			asset_path = "/Game/Blueprints/AI/Agents/CollectorLeviathan/BP_CollectorLeviathan",
			class_path = "/Game/Blueprints/AI/Agents/CollectorLeviathan/BP_CollectorLeviathan.BP_CollectorLeviathan_C",
		})
		assert.are.same({
			"/Game/Blueprints/AI/Agents/CollectorLeviathan/BP_CollectorLeviathan",
			"/Game/Blueprints/AI/Agents/CollectorLeviathan/BP_CollectorLeviathan.BP_CollectorLeviathan",
			"/Game/Blueprints/AI/Agents/CollectorLeviathan/BP_CollectorLeviathan.BP_CollectorLeviathan_C",
		}, paths)
	end)

	it("is empty when no paths are configured", function()
		assert.are.equal(0, #Spawn.asset_load_paths({}))
	end)
end)

describe("spawn.compute_spawn_location", function()
	it("places the actor `distance` along the forward vector with no jitter", function()
		local loc = Spawn.compute_spawn_location(
			{ X = 100, Y = 0, Z = 50 }, { X = 1, Y = 0, Z = 0 },
			{ distance = 800, vertical = 0, jitter = 0, jitter_vertical = 0 })
		assert.are.equal(900, loc.X)
		assert.are.equal(0, loc.Y)
		assert.are.equal(50, loc.Z)
	end)

	it("applies a vertical offset and symmetric jitter via the injected rng", function()
		local loc = Spawn.compute_spawn_location(
			{ X = 0, Y = 0, Z = 0 }, { X = 0, Y = 1, Z = 0 },
			{ distance = 0, vertical = -25, jitter = 100, rng = function() return 1.0 end })
		-- rng()=1.0 -> offset = (1*2-1)*100 = +100 on X and Y.
		assert.are.equal(100, loc.X)
		assert.are.equal(100, loc.Y)
		assert.are.equal(-25, loc.Z)
	end)
end)

describe("spawn.compute_yaw", function()
	it("faces +X as yaw 0 and +Y as yaw 90", function()
		assert.are.equal(0, Spawn.compute_yaw({ X = 1, Y = 0 }))
		assert.are.equal(90, Spawn.compute_yaw({ X = 0, Y = 1 }))
	end)
end)

-- A minimal valid-object stub.
local function obj(extra)
	local o = { IsValid = function() return true end }
	for k, v in pairs(extra or {}) do o[k] = v end
	return o
end

describe("spawn.resolve_class", function()
	it("resolves via class_path (StaticFindObject) when present", function()
		local cls = obj()
		local deps = { static_find_object = function() return cls end }
		local got, how = Spawn.resolve_class(deps, { class_path = "/Game/X.X_C" })
		assert.are.equal(cls, got)
		assert.are.equal("class_path", how)
	end)

	it("loads the asset then resolves when not initially in memory", function()
		local loaded = false
		local cls = obj()
		local deps = {
			static_find_object = function() if loaded then return cls end end,
			load_asset = function() loaded = true end,
		}
		local got, how = Spawn.resolve_class(deps, {
			class_path = "/Game/X.X_C", asset_path = "/Game/X",
		})
		assert.are.equal(cls, got)
		assert.is_truthy(how:find("asset"))
	end)

	it("returns nil/unresolved when nothing can be found", function()
		local got, how = Spawn.resolve_class({ static_find_object = function() return nil end },
			{ class_path = "/Game/missing.missing_C" })
		assert.is_nil(got)
		assert.are.equal("unresolved", how)
	end)
end)

describe("spawn.spawn", function()
	local function deps_with(spawn_count_seen)
		local cls = obj()
		return {
			get_world = function()
				return obj({ SpawnActor = function(_, _cls, _loc, _rot)
					spawn_count_seen[#spawn_count_seen + 1] = _loc
					return obj()
				end })
			end,
			get_player_transform = function()
				return { location = { X = 0, Y = 0, Z = 0 }, forward = { X = 1, Y = 0, Z = 0 } }
			end,
			static_find_object = function() return cls end,
			set_collision_ignored = function() end,
			rng = function() return 0.5 end, -- midpoint -> zero offset
		}
	end

	it("spawns `spawn_count` actors and forces AlwaysSpawn", function()
		local locs = {}
		local forced = false
		local deps = deps_with(locs)
		deps.set_collision_ignored = function() forced = true end
		local spawned, how, failed = Spawn.spawn(deps, {
			class_path = "/Game/X.X_C", spawn_count = 3, spawn_distance = 800,
		})
		assert.are.equal(3, #spawned)
		assert.are.equal(0, failed)
		assert.are.equal("class_path", how)
		assert.is_true(forced)
	end)

	it("returns nil/no world when the world is unavailable", function()
		local spawned, why = Spawn.spawn({ get_world = function() return nil end }, {})
		assert.is_nil(spawned)
		assert.are.equal("no world", why)
	end)

	it("returns nil/no player when the transform is unavailable", function()
		local spawned, why = Spawn.spawn({
			get_world = function() return obj({ SpawnActor = function() return obj() end }) end,
			static_find_object = function() return obj() end,
			get_player_transform = function() return nil end,
		}, { class_path = "/Game/X.X_C" })
		assert.is_nil(spawned)
		assert.are.equal("no player", why)
	end)
end)

describe("spawn.count_alive", function()
	it("counts only the still-valid actors", function()
		local alive = { IsValid = function() return true end }
		local dead = { IsValid = function() return false end }
		assert.are.equal(2, Spawn.count_alive({ alive, dead, alive }))
	end)
end)
