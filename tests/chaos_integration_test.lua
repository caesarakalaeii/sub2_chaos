-- End-to-end test of the chaos poll loop against a real bridge file, using the
-- mock UE4SS env (fakes LoopAsync/ExecuteInGameThread/FindFirstOf).

local mock = require("mock_ue4ss")
local chaos = require("chaos")
local events = require("events")
local buffs_mod = require("buffs")
local status_bridge = require("status_bridge")
local log = require("log")

local function write_state(path, body)
	local f = assert(io.open(path, "w"))
	f:write(body)
	f:close()
end

describe("chaos loop integration", function()
	it("executes a winner from the bridge file exactly once", function()
		mock.with_env(function(env)
			local vote_path = os.tmpname()
			local status_path = os.tmpname()
			write_state(vote_path,
				'{"phase":"apply","winner":{"id":"heal_full","index":1,"label":"Full Heal"},"winnerNonce":"r1"}')

			local calls = {}
			local ctx = {
				cheats = { my_health = function(v) calls[#calls + 1] = { "my_health", v }; return true end },
				items = { give = function() return true end },
				aggro = { start = function() end },
				buffs = buffs_mod.new(),
				log = log,
				now = function() return os.time() end,
				default_swim_speed = 400,
				gameplay_active = function() return true end,
			}
			chaos.install({
				vote_path = vote_path,
				status_path = status_path,
				interval_ms = 300,
				by_id = { heal_full = { id = "heal_full", category = "good" } },
				handlers = events.handlers,
				ctx = ctx,
				buffs = ctx.buffs,
				gates = function() return { master = true, good = true, bad = true, chaos = true, leviathans = true } end,
				status = status_bridge,
				version = "test",
				log = log,
			})

			env:tick_loops(1) -- run the loop body once
			assert.are.equal("my_health", calls[1] and calls[1][1])
			assert.are.equal(100, calls[1][2])

			env:tick_loops(1) -- same nonce -> must NOT re-execute
			assert.are.equal(1, #calls)

			-- A new round with a fresh nonce executes again.
			write_state(vote_path,
				'{"phase":"apply","winner":{"id":"heal_full","index":1,"label":"Full Heal"},"winnerNonce":"r2"}')
			env:tick_loops(1)
			assert.are.equal(2, #calls)

			-- The status file was written for the sidecar.
			local sf = io.open(status_path, "r")
			assert.is_truthy(sf, "status file should exist")
			if sf then sf:close() end

			os.remove(vote_path)
			os.remove(status_path)
		end)
	end)
end)
