local chaos = require("chaos")

describe("chaos.decide", function()
	local by_id = {
		heal_full = { id = "heal_full", category = "good" },
		spawn_leviathan = { id = "spawn_leviathan", category = "bad", leviathan = true },
		slomo_fast = { id = "slomo_fast", category = "chaos" },
	}
	local all = { master = true, good = true, bad = true, chaos = true, leviathans = true }
	local function st(id, nonce)
		return { winner = { id = id, index = 1, label = id }, winnerNonce = nonce }
	end

	it("returns the winning id for a fresh nonce", function()
		local id, nonce = chaos.decide(st("heal_full", "n1"), nil, all, by_id)
		assert.are.equal("heal_full", id)
		assert.are.equal("n1", nonce)
	end)

	it("dedupes by nonce (same nonce -> nothing)", function()
		assert.is_nil((chaos.decide(st("heal_full", "n1"), "n1", all, by_id)))
	end)

	it("master gate blocks execution but consumes the nonce", function()
		local id, nonce = chaos.decide(st("heal_full", "n2"), nil, { master = false }, by_id)
		assert.is_nil(id)
		assert.are.equal("n2", nonce)
	end)

	it("category gate blocks a good event", function()
		local gates = { master = true, good = false, bad = true, chaos = true, leviathans = true }
		local id, nonce = chaos.decide(st("heal_full", "n3"), nil, gates, by_id)
		assert.is_nil(id)
		assert.are.equal("n3", nonce)
	end)

	it("leviathan gate blocks a leviathan spawn", function()
		local gates = { master = true, good = true, bad = true, chaos = true, leviathans = false }
		assert.is_nil((chaos.decide(st("spawn_leviathan", "n4"), nil, gates, by_id)))
	end)

	it("returns nil when there is no winner", function()
		assert.is_nil((chaos.decide({}, nil, all, by_id)))
		assert.is_nil((chaos.decide({ winner = {} }, nil, all, by_id)))
		assert.is_nil((chaos.decide({ winner = { id = "heal_full" } }, nil, all, by_id))) -- no nonce
	end)
end)
