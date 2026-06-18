local M = {}

local PREFIX = "[Sub2Chaos] "
local LEVELS = { trace = 1, info = 2, warn = 3, error = 4 }
local min_level = LEVELS.info

-- UE4SS's print() override does not add a newline (unlike standard Lua
-- print), so consecutive emit() calls collapse onto one log line. Append
-- "\n" ourselves to match the bundled mods.
local function emit(level, ...)
    if LEVELS[level] < min_level then return end
    local parts = { PREFIX, level:upper(), " " }
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = tostring(v)
        parts[#parts + 1] = " "
    end
    parts[#parts + 1] = "\n"
    print(table.concat(parts))
end

function M.set_level(name)
    assert(LEVELS[name], "unknown log level: " .. tostring(name))
    min_level = LEVELS[name]
end

function M.trace(...) emit("trace", ...) end
function M.info(...)  emit("info",  ...) end
function M.warn(...)  emit("warn",  ...) end
function M.error(...) emit("error", ...) end

-- Structured event emitter. One line per call. Format:
--   [RecipeRandomizer] EVENT event=<name> key1=val1 key2=val2 ...
-- event= is always first so `grep "event=spawn.spawn_attempt"` works.
-- See RESEARCH.md "How we'll verify" for the canonical event names and
-- their expected fields.
--
-- Value formatting:
--   number  -> raw (`123` or `1.5`)
--   boolean -> true/false
--   nil     -> nil
--   table   -> (a,b,c) for 3-element numeric (FVector/FRotator), else {k=v,...}
--   string  -> raw if no spaces/quotes, otherwise "..." with " escaped

local function looks_numeric_triple(t)
    if type(t) ~= "table" then return false end
    if t[1] == nil or t[2] == nil or t[3] == nil then return false end
    if t[4] ~= nil then return false end
    return type(t[1]) == "number" and type(t[2]) == "number" and type(t[3]) == "number"
end

local function fmt_number(n)
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return string.format("%.2f", n)
end

local function fmt_value(v)
    local t = type(v)
    if v == nil then return "nil" end
    if t == "number" then return fmt_number(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "table" then
        if looks_numeric_triple(v) then
            return "(" .. fmt_number(v[1]) .. "," .. fmt_number(v[2]) .. "," .. fmt_number(v[3]) .. ")"
        end
        local parts = {}
        for k, vv in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. fmt_value(vv)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    -- string and everything else (userdata stringified)
    local s = tostring(v)
    if s:find("[%s\"=]") then
        return '"' .. s:gsub('"', '\\"') .. '"'
    end
    return s
end

-- Stable ordering: event= first, then alphabetical by key. The "events as
-- a queryable log" model relies on stable line shape across runs.
local function ordered_keys(fields)
    local keys = {}
    for k, _ in pairs(fields or {}) do
        if k ~= "event" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

-- Optional machine-readable sink (set by debug_bridge to tee events into
-- debug/events.jsonl). Tee'd BEFORE the console-level gate so the telemetry
-- stream is complete regardless of the user's display verbosity. Guarded
-- by pcall so a sink fault never disturbs logging. nil in unit tests, so
-- M.event behaves exactly as before when the bridge isn't installed.
function M.set_jsonl_sink(fn) M._jsonl_sink = fn end

function M.event(name, fields)
    fields = fields or {}
    if M._jsonl_sink then pcall(M._jsonl_sink, name, fields) end
    -- Console print is gated by log level. If the user dialed log_level to
    -- warn or error, events are suppressed on-screen alongside info lines
    -- (but still captured in the JSONL sink above).
    if LEVELS.info < min_level then return end
    local parts = { PREFIX, "EVENT event=", name }
    for _, k in ipairs(ordered_keys(fields)) do
        parts[#parts + 1] = " "
        parts[#parts + 1] = k
        parts[#parts + 1] = "="
        parts[#parts + 1] = fmt_value(fields[k])
    end
    parts[#parts + 1] = "\n"
    print(table.concat(parts))
end

return M
