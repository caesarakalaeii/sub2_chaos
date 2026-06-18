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

	it("announces immediately but holds execution until the lead elapses, and freezes it while paused", function()
		mock.with_env(function(env)
			local vote_path = os.tmpname()
			local status_path = os.tmpname()
			-- announceLeadSeconds=5 => announce on sight, execute 5s later.
			write_state(vote_path,
				'{"phase":"apply","winner":{"id":"heal_full","index":1,"label":"Full Heal"},'
				.. '"winnerNonce":"r1","announceLeadSeconds":5}')

			local calls, announced = {}, {}
			local clock = 1000
			local paused = false
			local ctx = {
				cheats = { my_health = function(v) calls[#calls + 1] = v; return true end },
				items = { give = function() return true end },
				aggro = { start = function() end },
				buffs = buffs_mod.new(),
				log = log,
				now = function() return clock end,
				default_swim_speed = 400,
				gameplay_active = function() return true end,
				game_paused = function() return paused end,
			}
			-- Drive the loop off our virtual clock instead of os.time().
			local real_time = os.time
			os.time = function() return clock end

			chaos.install({
				vote_path = vote_path,
				status_path = status_path,
				interval_ms = 300,
				by_id = { heal_full = { id = "heal_full", category = "good", label = "Full Heal" } },
				handlers = events.handlers,
				ctx = ctx,
				buffs = ctx.buffs,
				gates = function() return { master = true, good = true, bad = true, chaos = true, leviathans = true } end,
				status = status_bridge,
				announce = function(label, secs) announced[#announced + 1] = { label, secs } end,
				version = "test",
				log = log,
			})

			env:tick_loops(1) -- t=1000: announce, do NOT execute yet
			assert.are.equal(0, #calls, "must not execute on the announcing tick")
			assert.are.equal(1, #announced)
			assert.are.equal("Full Heal", announced[1][1])
			assert.are.equal(5, announced[1][2])

			clock = clock + 3 -- t=1003: still within the lead
			env:tick_loops(1)
			assert.are.equal(0, #calls)

			-- Pause for 10s of wall time: the countdown must freeze (no execution).
			paused = true
			clock = clock + 10 -- t=1013 but paused
			env:tick_loops(1)
			assert.are.equal(0, #calls, "paused must hold the event")

			-- Unpause; only the remaining ~2s of lead should be left.
			paused = false
			clock = clock + 2 -- t=1015: lead satisfied post-unpause
			env:tick_loops(1)
			assert.are.equal(1, #calls, "event fires once the (unpaused) lead elapses")
			assert.are.equal(100, calls[1])

			env:tick_loops(1) -- no re-execution
			assert.are.equal(1, #calls)

			os.time = real_time
			os.remove(vote_path)
			os.remove(status_path)
		end)
	end)
end)
