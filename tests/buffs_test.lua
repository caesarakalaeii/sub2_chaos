local buffs = require("buffs")

describe("buffs", function()
	it("fires revert at the deadline, not before", function()
		local b = buffs.new()
		local fired = 0
		b:add("god", 10, 100, function() fired = fired + 1 end)
		assert.are.same({}, b:tick(105))
		assert.are.equal(0, fired)
		local f = b:tick(110)
		assert.are.equal("god", f[1])
		assert.are.equal(1, fired)
		assert.is_false(b:has("god"))
	end)

	it("refreshes the same key without double-reverting", function()
		local b = buffs.new()
		local fired = 0
		b:add("swim", 10, 100, function() fired = fired + 1 end)
		b:add("swim", 10, 105, function() fired = fired + 1 end) -- refresh -> expires 115
		b:tick(112)
		assert.are.equal(0, fired)
		b:tick(116)
		assert.are.equal(1, fired)
	end)

	it("runs distinct keys concurrently", function()
		local b = buffs.new()
		local g, s = 0, 0
		b:add("god", 5, 100, function() g = g + 1 end)
		b:add("swim", 10, 100, function() s = s + 1 end)
		b:tick(106)
		assert.are.equal(1, g)
		assert.are.equal(0, s)
		assert.is_true(b:has("swim"))
		b:tick(111)
		assert.are.equal(1, s)
	end)

	it("clear_all fires every revert immediately", function()
		local b = buffs.new()
		local n = 0
		b:add("a", 10, 100, function() n = n + 1 end)
		b:add("b", 10, 100, function() n = n + 1 end)
		b:clear_all()
		assert.are.equal(2, n)
		assert.are.equal(0, b:active_count())
	end)
end)
