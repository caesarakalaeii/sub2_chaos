-- vote_bridge.lua — read the sidecar's chaos_state.json.
--
-- Tolerant by design: a missing, empty, or half-written file yields (nil, reason)
-- rather than an error (json.decode never throws), so a poll tick is a harmless
-- no-op and the next tick retries. The sidecar writes atomically (tmp + rename),
-- so a complete document is the normal case; this just refuses to crash on the rest.

local json = require("json")

local M = {}

-- read(path): returns the decoded state table, or (nil, reason).
function M.read(path)
	local f = io.open(path, "r")
	if not f then return nil, "missing" end
	local body = f:read("*a")
	f:close()
	if not body or body == "" then return nil, "empty" end
	local data, err = json.decode(body)
	if type(data) ~= "table" then return nil, err or "not an object" end
	return data
end

return M
