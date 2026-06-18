-- chaos.lua — the dispatch + timer loop that drives chaos in-game.
--
-- Each poll tick: read the sidecar's chaos_state.json, decide whether there's a
-- NEW winner to execute (idempotent via winnerNonce + the enable gates), run its
-- handler, fire any due temporary-effect reverts, and write chaos_status.json
-- back so the sidecar can pause voting outside gameplay.
--
-- decide() is pure (no engine), so the dedupe + gating logic is unit-tested.

local vote_bridge = require("vote_bridge")

local M = {}

-- decide(state, last_nonce, gates, by_id) -> (event_id|nil, nonce|nil)
--   Returns the winning event id to execute, plus the nonce that should now be
--   recorded as "seen". A fresh nonce that's gated off returns (nil, nonce) so it
--   is consumed (never re-evaluated); a stale/absent nonce returns (nil, nil).
function M.decide(state, last_nonce, gates, by_id)
	if type(state) ~= "table" then return nil, nil end
	local w = state.winner
	if type(w) ~= "table" or type(w.id) ~= "string" then return nil, nil end
	local nonce = state.winnerNonce
	if type(nonce) ~= "string" or nonce == "" or nonce == last_nonce then return nil, nil end

	-- From here the nonce is fresh; always return it so it's recorded as seen.
	if not gates.master then return nil, nonce end
	local ev = by_id and by_id[w.id]
	local cat = (ev and ev.category) or "chaos"
	if cat == "good" and not gates.good then return nil, nonce end
	if cat == "bad" and not gates.bad then return nil, nonce end
	if cat == "chaos" and not gates.chaos then return nil, nonce end
	if ev and ev.leviathan and not gates.leviathans then return nil, nonce end
	return w.id, nonce
end

-- install(deps): wire the single LoopAsync poll loop. deps:
--   vote_path, status_path, interval_ms
--   by_id      -- catalog id -> event
--   handlers   -- id -> fn(ctx, ev)
--   ctx        -- handler ctx (also carries ctx.gameplay_active())
--   buffs      -- buffs instance
--   gates()    -- -> { master, good, bad, chaos, leviathans } (read live each tick)
--   status     -- status_bridge module (status.write(path, tbl))
--   version, log
function M.install(deps)
	local log = deps.log
	local interval = math.floor(tonumber(deps.interval_ms) or 300)
	if interval < 100 then interval = 300 end
	local last_nonce = nil
	local last_status = nil

	local function tick_gt()
		local now = os.time()

		local state = vote_bridge.read(deps.vote_path)
		if type(state) == "table" then
			local id, nonce = M.decide(state, last_nonce, deps.gates(), deps.by_id)
			if nonce then last_nonce = nonce end
			if id then
				local h = deps.handlers[id]
				if h then
					local ok, err = pcall(h, deps.ctx, deps.by_id[id])
					log.event("chaos.execute", { id = id, ok = ok and true or false,
						err = (not ok) and tostring(err) or nil })
				else
					log.warn("chaos: no handler for event id " .. tostring(id))
				end
			end
		end

		for _, key in ipairs(deps.buffs:tick(now)) do
			log.event("chaos.revert", { buff = key })
		end

		if deps.status then
			local active = true
			if deps.ctx.gameplay_active then
				local ok, v = pcall(deps.ctx.gameplay_active)
				active = ok and v or false
			end
			-- Only rewrite when something changed (avoid disk churn).
			local sig = tostring(active) .. "|" .. tostring(last_nonce)
			if sig ~= last_status then
				last_status = sig
				pcall(deps.status.write, deps.status_path, {
					gameplayActive = active,
					paused = false,
					lastAppliedNonce = last_nonce,
					modVersion = deps.version,
				})
			end
		end
	end

	local function body()
		if ExecuteInGameThread then ExecuteInGameThread(tick_gt) else tick_gt() end
	end

	if LoopAsync then
		LoopAsync(interval, body)
		log.event("chaos.loop_started", { interval_ms = interval })
	else
		log.warn("chaos: LoopAsync unavailable — chaos loop not started")
	end
end

return M
