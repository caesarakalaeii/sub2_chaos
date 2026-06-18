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
			unlock_all_recipes = rec("unlock_all_recipes"),
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

	it("spawn_leviathan starts aggro then spawns the creature", function()
		local ctx = fake_ctx()
		events.handlers.spawn_leviathan(ctx, { params = { creature = "CollectorLeviathan" } })
		assert.are.equal("aggro_start", ctx.calls[1][1])
		assert.are.equal("spawn_creature", ctx.calls[2][1])
		assert.are.equal("CollectorLeviathan", ctx.calls[2][2])
	end)

	it("slomo events share the slomo buff key and revert to 1.0", function()
		local ctx = fake_ctx()
		events.handlers.slomo_slow(ctx, { params = { rate = 0.4 }, durationSeconds = 12, buffKey = "slomo" })
		assert.are.equal(0.4, ctx.calls[1][2])
		assert.are.equal("slomo", ctx.buffs.added[1].k)
		ctx.buffs.added[1].rev()
		assert.are.equal(1.0, ctx.calls[2][2])
	end)

	it("give_item delegates to items.give", function()
		local ctx = fake_ctx()
		events.handlers.give_item(ctx, { params = { itemType = "DA_Gold_ItemType", count = 1 } })
		assert.are.equal("give", ctx.calls[1][1])
	end)

	it("heal/hurt/kill_all/unlock call the right cheat", function()
		local ctx = fake_ctx()
		events.handlers.heal_full(ctx, {})
		assert.are.equal("my_health", ctx.calls[1][1])
		assert.are.equal(100, ctx.calls[1][2])
		events.handlers.hurt_player(ctx, { params = { hp = 25 } })
		assert.are.equal(25, ctx.calls[2][2])
		events.handlers.kill_all_creatures(ctx, {})
		assert.are.equal("kill_all", ctx.calls[3][1])
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
