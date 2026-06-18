local vote_bridge = require("vote_bridge")

local function write_file(path, body)
	local f = assert(io.open(path, "w"))
	f:write(body)
	f:close()
end

describe("vote_bridge.read", function()
	local tmp = os.tmpname()

	it("reads a complete JSON document", function()
		write_file(tmp, '{"round":3,"winnerNonce":"abc","winner":{"id":"heal_full","index":1}}')
		local s = assert(vote_bridge.read(tmp))
		assert.are.equal(3, s.round)
		assert.are.equal("abc", s.winnerNonce)
		assert.are.equal("heal_full", s.winner.id)
	end)

	it("returns nil for a missing file (no error)", function()
		assert.is_nil((vote_bridge.read("/no/such/path/chaos_state.json")))
	end)

	it("returns nil for a torn/partial write (no crash)", function()
		write_file(tmp, '{"round":3,"winner')
		local s, e = vote_bridge.read(tmp)
		assert.is_nil(s)
		assert.is_truthy(e)
	end)

	it("returns nil for an empty file", function()
		write_file(tmp, "")
		assert.is_nil((vote_bridge.read(tmp)))
	end)

	os.remove(tmp)
end)
