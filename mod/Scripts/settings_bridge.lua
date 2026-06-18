-- SN2ModSettings bridge.
--
-- Pattern lifted from Zeusfail/Too-Many-Divers's main.lua: write a
-- manifest into <game>/ue4ss/Mods/SN2ModSettings/registrations/<Mod>.lua
-- at boot, then poll ModRef:GetSharedVariable("SN2ModSettings/<Mod>/<key>")
-- in a LoopAsync(1000, ...) and dispatch on every detected change.
--
-- Architecture:
--   * M.serialize_manifest(table) — pure function, testable offline.
--   * M.write_manifest(path, table) — IO wrapper around serialize.
--   * M.poll(key, default) — reads cache; caller passes the default
--     from config.lua so the mod works when SN2ModSettings is absent.
--   * M.subscribe(key, fn) — fn(new_value, old_value) on every change.
--   * M.start_loop() — installs the LoopAsync poller (game-only).
--
-- If SN2ModSettings is not installed, ModRef:GetSharedVariable returns
-- nil for our keys forever and the cache stays seeded with defaults.
-- Mod functions normally, just headless.

local log = require("log")

local M = {}

local MOD_NAME = "Sub2Chaos"
M.MOD_NAME = MOD_NAME
M.MANIFEST_PATH = "./ue4ss/Mods/SN2ModSettings/registrations/" .. MOD_NAME .. ".lua"
M.SHARED_VAR_PREFIX = "SN2ModSettings/" .. MOD_NAME .. "/"
M.POLL_INTERVAL_MS = 1000

local cache = {}
local subscribers = {}
local loop_started = false

-- Optional extra callback driven by the same poll loop (the debug bridge
-- injects its request poll here, avoiding a second LoopAsync). Invoked
-- BEFORE M.tick so it runs even when SN2ModSettings/ModRef is absent
-- (M.tick early-returns without ModRef). Injection keeps settings_bridge
-- free of a require dependency on debug_bridge (no cycle).
local debug_hook = nil
function M.set_debug_hook(fn) debug_hook = fn end

-- ── Serialization ────────────────────────────────────────────────────

local function quote(s)
    return string.format("%q", s)
end

-- A *very* restricted serializer: SN2ModSettings reads the manifest as
-- a normal `return { ... }` Lua file. We don't need general-purpose
-- table-to-Lua here — only strings, numbers, booleans, arrays, and
-- key-value records.
local function dump(v, buf, indent)
    local t = type(v)
    if t == "string" then
        buf[#buf+1] = quote(v)
    elseif t == "number" then
        if v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge then
            buf[#buf+1] = string.format("%d", v)
        else
            buf[#buf+1] = tostring(v)
        end
    elseif t == "boolean" then
        buf[#buf+1] = v and "true" or "false"
    elseif t == "nil" then
        buf[#buf+1] = "nil"
    elseif t == "table" then
        local is_array = (#v > 0) and (next(v, #v) == nil)
        local inner = indent .. "    "
        buf[#buf+1] = "{\n"
        if is_array then
            for i, item in ipairs(v) do
                buf[#buf+1] = inner
                dump(item, buf, inner)
                buf[#buf+1] = i < #v and ",\n" or "\n"
            end
        else
            -- Deterministic key order: sort by key name so test output
            -- is stable. The order of *settings entries* (an array)
            -- inside the manifest is preserved by the is_array branch
            -- above, so the SN2ModSettings UI keeps user-specified
            -- display order.
            local keys = {}
            for k in pairs(v) do keys[#keys+1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for i, k in ipairs(keys) do
                buf[#buf+1] = inner
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    buf[#buf+1] = k
                else
                    buf[#buf+1] = "[" .. quote(tostring(k)) .. "]"
                end
                buf[#buf+1] = " = "
                dump(v[k], buf, inner)
                buf[#buf+1] = i < #keys and ",\n" or "\n"
            end
        end
        buf[#buf+1] = indent .. "}"
    else
        error("settings_bridge: cannot serialize " .. t)
    end
end

function M.serialize_manifest(manifest)
    assert(type(manifest) == "table", "manifest must be a table")
    assert(type(manifest.name) == "string", "manifest.name required")
    assert(type(manifest.settings) == "table", "manifest.settings required")
    -- Validate every setting has at least key + type + default. SN2ModSettings
    -- ignores malformed entries silently, which makes them hard to debug.
    for i, s in ipairs(manifest.settings) do
        assert(type(s.key) == "string",
            string.format("settings[%d].key must be a string", i))
        assert(type(s.type) == "string",
            string.format("settings[%d].type required (toggle|slider|dropdown|keybind|text)", i))
        if s.default == nil then
            error(string.format("settings[%d].default required (key=%s)", i, s.key))
        end
    end
    local buf = { "return " }
    dump(manifest, buf, "")
    buf[#buf+1] = "\n"
    return table.concat(buf)
end

-- ── IO ───────────────────────────────────────────────────────────────

-- POSIX uses "/" as path separator; Windows Lua uses "\". We use this
-- to pick the right mkdir invocation — running `2>nul` on POSIX would
-- create a literal file called `nul` in cwd.
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function ensure_dir(path)
    -- Path arrives as ./ue4ss/Mods/SN2ModSettings/registrations/<X>.lua.
    -- Under UE4SS Lua this is resolved relative to the game's Win64 dir
    -- (Windows path semantics). Under a Linux dev run (lua tests) we
    -- fall through to POSIX mkdir.
    local dir = path:match("^(.*)[/\\][^/\\]+$")
    if not dir then return end
    if IS_WINDOWS then
        pcall(os.execute, 'mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    else
        pcall(os.execute, 'mkdir -p "' .. dir .. '" 2>/dev/null')
    end
end

function M.write_manifest(target_path, manifest)
    target_path = target_path or M.MANIFEST_PATH
    local body = M.serialize_manifest(manifest)
    ensure_dir(target_path)
    local f, err = io.open(target_path, "w")
    if not f then
        log.error("settings_bridge: cannot write manifest to " .. tostring(target_path) ..
            ": " .. tostring(err))
        return nil, err
    end
    f:write(body)
    f:close()
    log.info("settings_bridge: manifest written to " .. target_path)
    return target_path
end

-- ── Pub/sub + polling ────────────────────────────────────────────────

-- Read a single SharedVariable. Falls back to the provided default when
-- ModRef isn't available (running outside UE4SS, e.g. unit tests) or the
-- variable hasn't been populated by SN2ModSettings (mod not installed,
-- or this key was added after the registrations file was last loaded).
function M.poll(key, default)
    local cached = cache[key]
    if cached ~= nil then return cached end
    if not ModRef or not ModRef.GetSharedVariable then
        cache[key] = default
        return default
    end
    local ok, raw = pcall(function()
        return ModRef:GetSharedVariable(M.SHARED_VAR_PREFIX .. key)
    end)
    if ok and raw ~= nil then
        cache[key] = raw
        return raw
    end
    cache[key] = default
    return default
end

-- Push a value FROM the mod back to SN2ModSettings. SN2ModSettings 1.2.1+
-- reflects a setting's SharedVariable onto its widget (toggle values only), so
-- this is how the mod drives the menu — e.g. resetting the "reroll" toggle to
-- false after a reroll so it behaves like a button (click → act → auto-off).
-- We also update our own cache to the pushed value so the write we initiated
-- isn't read back as a fresh user edit on the next tick (which would, for
-- reroll, re-fire). No-op (returns false) when ModRef/SetSharedVariable is
-- absent (headless tests / SN2ModSettings not installed); the cache update
-- still happens so behaviour is consistent.
function M.push(key, value)
    cache[key] = value
    if not ModRef or not ModRef.SetSharedVariable then return false end
    return (pcall(function()
        ModRef:SetSharedVariable(M.SHARED_VAR_PREFIX .. key, value)
    end))
end

function M.subscribe(key, fn)
    assert(type(key) == "string", "subscribe: key must be string")
    assert(type(fn) == "function", "subscribe: fn must be function")
    subscribers[key] = subscribers[key] or {}
    table.insert(subscribers[key], fn)
end

local function notify(key, new_val, old_val)
    local list = subscribers[key]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, new_val, old_val)
        if not ok then
            log.warn(string.format("settings_bridge: subscriber for %s raised: %s",
                key, tostring(err)))
        end
    end
end

-- Single tick of the polling loop. Exposed for tests: a fake ModRef can
-- be installed and tick() can be invoked directly without LoopAsync.
function M.tick()
    if not ModRef or not ModRef.GetSharedVariable then return end
    for key, _ in pairs(subscribers) do
        local ok, raw = pcall(function()
            return ModRef:GetSharedVariable(M.SHARED_VAR_PREFIX .. key)
        end)
        if ok and raw ~= nil then
            local old = cache[key]
            if old ~= raw then
                cache[key] = raw
                notify(key, raw, old)
            end
        end
    end
end

function M.start_loop()
    if loop_started then return end
    if not LoopAsync then
        log.warn("settings_bridge: LoopAsync unavailable — running headless")
        return
    end
    loop_started = true
    LoopAsync(M.POLL_INTERVAL_MS, function()
        if debug_hook then pcall(debug_hook) end
        pcall(M.tick)
    end)
    log.info(string.format("settings_bridge: polling every %dms", M.POLL_INTERVAL_MS))
end

-- ── Test-only helpers ────────────────────────────────────────────────

-- Reset internal state. Tests use this between describe blocks; in
-- production the module is loaded once and lives until Ctrl+R reload
-- (UE4SS scripts re-init from scratch on reload, so no cleanup needed).
function M._reset_for_tests()
    cache = {}
    subscribers = {}
    loop_started = false
end

return M
