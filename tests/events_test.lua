local events = require("events")

-- A fake ctx that records every primitive call so handlers can be asserted
-- without an engine.
local function fake_ctx()
	local calls = {}
	local function rec(name)
		return function(...)
			calls[#calls + 1] = { name, ... }
			return true
		end
	end
	local buffs = {
		added = {},
		add = function(self, k, d, now, rev)
			self.added[#self.added + 1] = { k = k, d = d, now = now, rev = rev }
		end,
	}
	return {
		calls = calls,
		buffs = buffs,
		cheats = {
			god = rec("god"), swim_speed = rec("swim_speed"), slomo = rec("slomo"),
			spawn_creature = rec("spawn_creature"), my_health = rec("my_health"),
			ghost = rec("ghost"), walk = rec("walk"), kill_all = rec("kill_all"),
			noclip = rec("noclip"), destroy_creatures = rec("destroy_creatures"),
			give = rec("give_cheat"), unlock_all_recipes = rec("unlock_all_recipes"),
		},
		items = { give = rec("give") },
		aggro = { start = rec("aggro_start") },
		now = function() return 100 end,
		default_swim_speed = 400,
	}
end

describe("events handlers", function()
	it("god_mode toggles on and registers a revert that toggles off", function()
		local ctx = fake_ctx()
		events.handlers.god_mode(ctx, { buffKey = "god", durationSeconds = 15 })
		assert.are.equal("god", ctx.calls[1][1])
		assert.are.equal("god", ctx.buffs.added[1].k)
		assert.are.equal(15, ctx.buffs.added[1].d)
		ctx.buffs.added[1].rev()
		assert.are.equal("god", ctx.calls[2][1])
	end)

	it("super_speed sets high speed and reverts to default", function()
		local ctx = fake_ctx()
		events.handlers.super_speed(ctx, { params = { speed = 1500 }, durationSeconds = 20, buffKey = "swim" })
		assert.are.equal("swim_speed", ctx.calls[1][1])
		assert.are.equal(1500, ctx.calls[1][2])
		ctx.buffs.added[1].rev()
		assert.are.equal("swim_speed", ctx.calls[2][1])
		assert.are.equal(400, ctx.calls[2][2])
	end)

	it("tunables (menu sliders) override durations, speeds and severity", function()
		local ctx = fake_ctx()
		ctx.tunables = {
			effect_duration_scale = 2.0, super_speed = 2200,
			slomo_fast_rate = 4.0, slomo_slow_rate = 0.2, hurt_player_hp = 5,
		}
		-- super_speed uses the slider value and a 2x-scaled duration (20 -> 40).
		events.handlers.super_speed(ctx, { params = { speed = 1500 }, durationSeconds = 20, buffKey = "swim" })
		assert.are.equal(2200, ctx.calls[1][2])
		assert.are.equal(40, ctx.buffs.added[1].d)
		-- slomo rates come from the sliders, not the event params.
		events.handlers.slomo_fast(ctx, { params = { rate = 2.5 }, durationSeconds = 15 })
		assert.are.equal(4.0, ctx.calls[2][2])
		events.handlers.slomo_slow(ctx, { params = { rate = 0.4 }, durationSeconds = 12 })
		assert.are.equal(0.2, ctx.calls[3][2])
		-- hurt severity from the slider.
		events.handlers.hurt_player(ctx, { params = { hp = 25 } })
		assert.are.equal(5, ctx.calls[4][2])
	end)

	it("leviathan tunables override spawn distance and swarm size", function()
		local ctx = fake_ctx()
		local cfgs = {}
		ctx.log = { event = function() end, warn = function() end }
		ctx.tunables = { leviathan_spawn_distance = 2500, swarm_size = 5 }
		ctx.spawn = function(cfg) cfgs[#cfgs + 1] = cfg; return { {} }, "class_path" end
		events.handlers.spawn_leviathan(ctx, { id = "spawn_leviathan", params = { class_path = "/Game/X.X_C" } })
		assert.are.equal(2500, cfgs[1].spawn_distance)
		events.handlers.spawn_leviathan_swarm(ctx, { id = "spawn_leviathan_swarm", params = { class_path = "/Game/V.V_C", count = 3 } })
		assert.are.equal(5, cfgs[2].spawn_count) -- slider overrides params.count
		assert.are.equal(2500, cfgs[2].spawn_distance)
	end)

	it("spawn_leviathan starts aggro then spawns via ctx.spawn (SpawnActor path)", function()
		local ctx = fake_ctx()
		local got_cfg
		ctx.log = { event = function() end, warn = function() end }
		ctx.spawn = function(cfg) got_cfg = cfg; return { {}, {} }, "class_path" end
		local ok = events.handlers.spawn_leviathan(ctx, {
			id = "spawn_leviathan",
			params = { class_path = "/Game/X.X_C", spawn_distance = 800 },
		})
		assert.is_true(ok)
		assert.are.equal("aggro_start", ctx.calls[1][1]) -- aggro started first
		assert.is_nil(ctx.calls[2])                       -- the SpawnCreature cheat was NOT used
		assert.are.equal("/Game/X.X_C", got_cfg.class_path)
		assert.are.equal(1, got_cfg.spawn_count)
		assert.is_true(got_cfg.ignore_collisions)
	end)

	it("spawn_void_child starts the Void (out-of-bounds) aggro and spawns one child", function()
		local ctx = fake_ctx()
		local cfg
		local void_started = false
		ctx.log = { event = function() end, warn = function() end }
		ctx.void_aggro = { start = function() void_started = true end }
		ctx.spawn = function(c) cfg = c; return { {} }, "class_path" end
		assert.is_true(events.handlers.spawn_void_child(ctx, {
			id = "spawn_void_child", params = { class_path = "/Game/V.V_C" },
		}))
		assert.is_true(void_started, "void child must start the Void OOB aggro loop")
		assert.are.equal(1, cfg.spawn_count)
	end)

	it("spawn_leviathan_swarm uses the Void aggro (children are Void), not Collector", function()
		local ctx = fake_ctx()
		local void_started, collector_started = false, false
		ctx.log = { event = function() end, warn = function() end }
		ctx.void_aggro = { start = function() void_started = true end }
		ctx.aggro = { start = function() collector_started = true end }
		ctx.spawn = function() return { {}, {}, {} }, "class_path" end
		events.handlers.spawn_leviathan_swarm(ctx, { id = "spawn_leviathan_swarm", params = { class_path = "/Game/V.V_C", count = 3 } })
		assert.is_true(void_started)
		assert.is_false(collector_started)
	end)

	it("spawn_leviathan reports failure when ctx.spawn cannot resolve a class", function()
		local ctx = fake_ctx()
		ctx.log = { event = function() end, warn = function() end }
		ctx.spawn = function() return nil, "unresolved" end
		assert.is_false(events.handlers.spawn_leviathan(ctx, { id = "spawn_leviathan", params = {} }))
	end)

	it("spawn_leviathan falls back to the SpawnCreature cheat when ctx.spawn is absent", function()
		local ctx = fake_ctx() -- no ctx.spawn
		events.handlers.spawn_leviathan(ctx, { params = { creature = "CollectorLeviathan" } })
		assert.are.equal("aggro_start", ctx.calls[1][1])
		assert.are.equal("spawn_creature", ctx.calls[2][1])
		assert.are.equal("CollectorLeviathan", ctx.calls[2][2])
	end)

	it("spawn_leviathan_swarm spawns p.count creatures with jitter", function()
		local ctx = fake_ctx()
		local got_cfg
		ctx.log = { event = function() end, warn = function() end }
		ctx.spawn = function(cfg) got_cfg = cfg; return { {}, {}, {} }, "class_path" end
		assert.is_true(events.handlers.spawn_leviathan_swarm(ctx, {
			id = "spawn_leviathan_swarm", params = { class_path = "/Game/V.V_C", count = 3 },
		}))
		assert.are.equal(3, got_cfg.spawn_count)
		assert.is_true(got_cfg.spawn_jitter > 0) -- swarm gets spread so bodies don't cull
	end)

	it("noclip toggles SN2 NoClip on, and reverts by toggling it off again", function()
		local ctx = fake_ctx()
		events.handlers.noclip(ctx, { buffKey = "move", durationSeconds = 15 })
		assert.are.equal("noclip", ctx.calls[1][1]) -- enabled via NoClip, NOT Ghost
		ctx.buffs.added[1].rev()
		assert.are.equal("noclip", ctx.calls[2][1]) -- revert toggles NoClip off
	end)

	it("slomo events share the slomo buff key and revert to 1.0", function()
		local ctx = fake_ctx()
		events.handlers.slomo_slow(ctx, { params = { rate = 0.4 }, durationSeconds = 12, buffKey = "slomo" })
		assert.are.equal(0.4, ctx.calls[1][2])
		assert.are.equal("slomo", ctx.buffs.added[1].k)
		ctx.buffs.added[1].rev()
		assert.are.equal(1.0, ctx.calls[2][2])
	end)

	it("give_item uses the Give cheat with '<item> <qty>' when itemName is set", function()
		local ctx = fake_ctx()
		assert.is_true(events.handlers.give_item(ctx, { params = { itemName = "Gold", count = 2 } }))
		assert.are.equal("give_cheat", ctx.calls[1][1])
		assert.are.equal("Gold 2", ctx.calls[1][2])
	end)

	it("give_item falls back to items.give (world spawn) when no itemName", function()
		local ctx = fake_ctx()
		events.handlers.give_item(ctx, { params = { actorPath = "/Game/BP_Gold" } })
		assert.are.equal("give", ctx.calls[1][1]) -- items.give, not the cheat
	end)

	it("heal/hurt/purge/unlock call the right cheat", function()
		local ctx = fake_ctx()
		events.handlers.heal_full(ctx, {})
		assert.are.equal("my_health", ctx.calls[1][1])
		assert.are.equal(100, ctx.calls[1][2])
		events.handlers.hurt_player(ctx, { params = { hp = 25 } })
		assert.are.equal(25, ctx.calls[2][2])
		-- Purge despawns creatures only (DestroyCreatures), never KillAll which
		-- would also kill the player.
		events.handlers.kill_all_creatures(ctx, {})
		assert.are.equal("destroy_creatures", ctx.calls[3][1])
		events.handlers.unlock_all_recipes(ctx, {})
		assert.are.equal("unlock_all_recipes", ctx.calls[4][1])
	end)

	it("every catalog id has a handler (catalog<->handler drift guard)", function()
		local cat = assert(events.load_catalog("events.json"))
		assert.is_true(#cat.list > 0)
		for _, e in ipairs(cat.list) do
			assert.is_truthy(events.handlers[e.id], "missing handler for event id: " .. tostring(e.id))
		end
	end)
end)
