-- status_bridge.lua — write chaos_status.json (mod -> sidecar) atomically.
--
-- Atomic write = same-directory temp file + os.rename. NEVER os.tmpname(): under
-- Proton/Wine the temp file lands on another filesystem and the cross-device
-- rename fails (the hazard sub2_random documents in debug_bridge.lua). On
-- Windows a rename over an existing file can fail, so we remove + retry.

local json = require("json")

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function ensure_dir(path)
	local dir = path:match("^(.*)[/\\][^/\\]+$")
	if not dir then return end
	if IS_WINDOWS then
		pcall(os.execute, 'mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
	else
		pcall(os.execute, 'mkdir -p "' .. dir .. '" 2>/dev/null')
	end
end

-- write(path, tbl): adds schemaVersion + updatedAt, then atomically writes.
-- Returns the path on success, or (nil, err).
function M.write(path, tbl)
	tbl.schemaVersion = tbl.schemaVersion or 1
	tbl.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local body = json.encode(tbl)
	ensure_dir(path)
	local tmp = path .. ".tmp"
	local f, err = io.open(tmp, "w")
	if not f then return nil, err end
	f:write(body)
	f:close()
	local ok = os.rename(tmp, path)
	if not ok then
		os.remove(path)
		ok = os.rename(tmp, path)
	end
	if not ok then
		os.remove(tmp)
		return nil, "rename failed"
	end
	return path
end

return M
