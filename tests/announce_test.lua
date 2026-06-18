local announce = require("announce")

describe("announce.format", function()
	it("names the event and the countdown", function()
		assert.are.equal("Chaos incoming: Release a Leviathan  (in 5s)",
			announce.format("Release a Leviathan", 5))
	end)

	it("floors fractional seconds and tolerates a nil label", function()
		assert.are.equal("Chaos incoming: ?  (in 4s)", announce.format(nil, 4.9))
	end)
end)

describe("announce.fields", function()
	it("carries header, formatted text, warning type and a >=1s duration", function()
		local f = announce.fields("Full Heal", 5)
		assert.are.equal("Sub2 Chaos", f.header)
		assert.are.equal("Chaos incoming: Full Heal  (in 5s)", f.text)
		assert.are.equal(announce.TYPE_WARNING, f.type)
		assert.are.equal(5, f.duration)
	end)

	it("clamps the notification duration to at least 1s", function()
		assert.are.equal(1.0, announce.fields("X", 0).duration)
	end)
end)
