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
--   ctx        -- handler ctx (also carries ctx.gameplay_active() / ctx.game_paused())
--   buffs      -- buffs instance
--   gates()    -- -> { master, good, bad, chaos, leviathans } (read live each tick)
--   status     -- status_bridge module (status.write(path, tbl))
--   announce   -- optional fn(label, seconds): show the on-screen heads-up
--   version, log
--
-- Execution is delayed by the sidecar's announceLeadSeconds: a fresh winner is
-- announced on sight but only EXECUTED once the lead elapses, so the player gets
-- a heads-up. While the game is paused the lead countdown is frozen (the sidecar
-- already halts voting on `paused`), so the event lands after the player unpauses.
function M.install(deps)
	local log = deps.log
	local interval = math.floor(tonumber(deps.interval_ms) or 300)
	if interval < 100 then interval = 300 end
	local last_nonce = nil
	local last_status = nil
	local last_status_write = nil
	local last_tick = nil
	local pending = nil -- { id, ev, due } a winner announced but not yet executed
	-- Heartbeat: rewrite chaos_status.json at least this often even when nothing
	-- changed, so the sidecar's freshness check sees the game is still running.
	local status_heartbeat_s = tonumber(deps.status_heartbeat_s) or 2

	local function execute(id, ev)
		local h = deps.handlers[id]
		if h then
			local ok, err = pcall(h, deps.ctx, ev)
			log.event("chaos.execute", { id = id, ok = ok and true or false,
				err = (not ok) and tostring(err) or nil })
		else
			log.warn("chaos: no handler for event id " .. tostring(id))
		end
	end

	local function tick_gt()
		local now = os.time()
		local dt = last_tick and (now - last_tick) or 0
		last_tick = now

		local paused = false
		if deps.ctx.game_paused then
			local ok, v = pcall(deps.ctx.game_paused)
			paused = ok and v == true
		end

		local state = vote_bridge.read(deps.vote_path)
		if type(state) == "table" then
			local id, nonce = M.decide(state, last_nonce, deps.gates(), deps.by_id)
			if nonce then last_nonce = nonce end
			if id then
				local ev = deps.by_id[id]
				local lead = tonumber(state.announceLeadSeconds) or 0
				if lead > 0 then
					pending = { id = id, ev = ev, due = now + lead }
					if deps.announce then
						pcall(deps.announce, ev and (ev.label or id) or id, lead)
					end
					log.event("chaos.announce", { id = id, lead = lead })
				else
					execute(id, ev)
				end
			end
		end

		-- Hold the pending event while paused (freeze its countdown), then fire it.
		if pending then
			if paused then
				if dt > 0 then pending.due = pending.due + dt end
			elseif now >= pending.due then
				execute(pending.id, pending.ev)
				pending = nil
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
			-- Player's vote-shaping menu sliders, sent back so the sidecar applies
			-- them at the next round (voting is tuned from the menu, not config.yaml).
			local vo = deps.vote_overrides and deps.vote_overrides() or nil

			-- Rewrite when something changed OR the heartbeat is due (so the
			-- sidecar can tell a running-but-idle game from a closed one). The vote
			-- overrides are in the signature so a slider change propagates at once.
			local sig = tostring(active) .. "|" .. tostring(paused) .. "|" .. tostring(last_nonce)
			if vo then
				sig = sig .. "|" .. tostring(vo.voteDurationSeconds)
					.. "|" .. tostring(vo.voteOptions) .. "|" .. tostring(vo.voteCooldownSeconds)
			end
			local hb_due = (last_status_write == nil) or ((now - last_status_write) >= status_heartbeat_s)
			if sig ~= last_status or hb_due then
				last_status = sig
				last_status_write = now
				local tbl = {
					gameplayActive = active,
					paused = paused,
					lastAppliedNonce = last_nonce,
					modVersion = deps.version,
				}
				if vo then
					tbl.voteDurationSeconds = vo.voteDurationSeconds
					tbl.voteOptions = vo.voteOptions
					tbl.voteCooldownSeconds = vo.voteCooldownSeconds
				end
				pcall(deps.status.write, deps.status_path, tbl)
			end
		end
	end

	-- Guard the whole tick: a Lua error must never escape into the game thread
	-- (it would surface as an engine-level fault). Internals are already pcall'd;
	-- this is belt-and-suspenders insurance for the background loop.
	local function guarded_tick()
		local ok, err = pcall(tick_gt)
		if not ok then log.warn("chaos: tick error: " .. tostring(err)) end
	end

	local function body()
		if ExecuteInGameThread then ExecuteInGameThread(guarded_tick) else guarded_tick() end
	end

	if LoopAsync then
		LoopAsync(interval, body)
		log.event("chaos.loop_started", { interval_ms = interval })
	else
		log.warn("chaos: LoopAsync unavailable — chaos loop not started")
	end
end

return M
