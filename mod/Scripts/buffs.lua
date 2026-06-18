-- buffs.lua — temporary-effect timer manager.
--
-- Pure: effects are deadline-checked each tick against an injected `now` (in
-- seconds), NOT scheduled callbacks — UE4SS's LoopAsync ignores return values,
-- so the chaos loop self-gates by calling tick(os.time()) every poll. Distinct
-- keys run concurrently; re-adding the same key REFRESHES it (one revert, never
-- double-fired); mutually-exclusive effects (e.g. slomo fast/slow) share a key.

local M = {}
M.__index = M

-- new(): a fresh, empty buff set.
function M.new()
	return setmetatable({ active = {} }, M)
end

-- add(key, duration_s, now, revert): arm or refresh a temporary effect. `revert`
-- runs once when the effect expires. Refreshing replaces the deadline + revert,
-- so a re-won effect never stacks two reverts.
function M:add(key, duration_s, now, revert)
	self.active[key] = { expires = now + (duration_s or 0), revert = revert }
end

-- tick(now): fire and remove every effect whose deadline passed. Returns the
-- fired keys. Each revert is pcall-guarded so one failure can't stop the others.
function M:tick(now)
	local fired = {}
	for key, e in pairs(self.active) do
		if now >= e.expires then
			fired[#fired + 1] = key
			self.active[key] = nil
			if type(e.revert) == "function" then pcall(e.revert) end
		end
	end
	return fired
end

-- has(key): is an effect with this key currently live?
function M:has(key) return self.active[key] ~= nil end

-- active_count(): number of live effects.
function M:active_count()
	local n = 0
	for _ in pairs(self.active) do n = n + 1 end
	return n
end

-- clear_all(): immediately fire every revert (bootstrap normalize / shutdown).
function M:clear_all()
	for key, e in pairs(self.active) do
		self.active[key] = nil
		if type(e.revert) == "function" then pcall(e.revert) end
	end
end

return M
