-- Minimal, dependency-free JSON encode/decode.
--
-- Why this exists: settings_bridge.lua / persist.lua serialize to *Lua*
-- literals, not JSON. The debug bridge needs JSON so a host-side agent can
-- parse responses with `jq` and friends. Runs unchanged under both the
-- tests/run.lua harness and UE4SS Lua (only string/table/math/utf8).
--
-- Contract:
--   M.encode(value)  -> string                 (never errors; defends itself)
--   M.decode(string) -> value | nil, err       (never errors; nil,err on bad input)
--
-- Encoding choices (see tests/json_test.lua for the pinned behavior):
--   * integers -> "%d" (stable, no 1e+15 surprises); floats -> "%.14g".
--   * NaN / +-Inf -> null  (JSON has no representation; emitting inf/nan
--     would silently corrupt the agent's parser).
--   * object keys are sorted, so JSONL diffs are stable across runs.
--   * empty table -> [] by convention (our payloads are never {}-shaped).
--   * cycles / depth > MAX_DEPTH -> a "<cycle>"/"<maxdepth>" sentinel
--     string rather than an infinite loop (a hang here freezes the game).

local M = {}

local MAX_DEPTH = 64

-- ── Encode ─────────────────────────────────────────────────────────────

local ESCAPES = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escape_string(s)
    -- Escape JSON-mandated chars plus any control char (< 0x20 and DEL).
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
    end) .. '"'
end

local function encode_number(v)
    -- math.type distinguishes integer vs float subtypes (Lua 5.3+).
    if math.type(v) == "integer" then
        return string.format("%d", v)
    end
    if v ~= v or v == math.huge or v == -math.huge then
        return "null"   -- NaN / +Inf / -Inf
    end
    return string.format("%.14g", v)
end

local function is_array(t)
    -- Same heuristic as settings_bridge.lua: integer keys 1..#t, nothing after.
    local n = #t
    if n == 0 then return false end
    return next(t, n) == nil
end

local encode_value   -- forward declaration

local function encode_table(t, depth, seen, buf)
    if depth > MAX_DEPTH then buf[#buf + 1] = '"<maxdepth>"'; return end
    if seen[t] then buf[#buf + 1] = '"<cycle>"'; return end
    seen[t] = true
    if next(t) == nil then
        buf[#buf + 1] = "[]"
    elseif is_array(t) then
        buf[#buf + 1] = "["
        for i = 1, #t do
            if i > 1 then buf[#buf + 1] = "," end
            encode_value(t[i], depth + 1, seen, buf)
        end
        buf[#buf + 1] = "]"
    else
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        buf[#buf + 1] = "{"
        for i, k in ipairs(keys) do
            if i > 1 then buf[#buf + 1] = "," end
            buf[#buf + 1] = escape_string(tostring(k))
            buf[#buf + 1] = ":"
            encode_value(t[k], depth + 1, seen, buf)
        end
        buf[#buf + 1] = "}"
    end
    -- Clear on the way out so a table reused in sibling positions (not an
    -- actual ancestor cycle) still encodes fully.
    seen[t] = nil
end

function encode_value(v, depth, seen, buf)
    local tp = type(v)
    if v == nil then buf[#buf + 1] = "null"
    elseif tp == "boolean" then buf[#buf + 1] = v and "true" or "false"
    elseif tp == "number" then buf[#buf + 1] = encode_number(v)
    elseif tp == "string" then buf[#buf + 1] = escape_string(v)
    elseif tp == "table" then encode_table(v, depth, seen, buf)
    else
        -- function / userdata: stringify defensively so one stray field
        -- can't wedge the entire response.
        buf[#buf + 1] = escape_string("<" .. tp .. ">")
    end
end

function M.encode(value)
    local buf = {}
    encode_value(value, 1, {}, buf)
    return table.concat(buf)
end

-- ── Decode ─────────────────────────────────────────────────────────────
--
-- Recursive descent. Malformed input raises a Lua error which M.decode
-- catches via pcall and returns as (nil, err) — a half-written request
-- file is the real-world hazard, and it must never crash the game thread.

local function skip_ws(s, i)
    while i <= #s do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            i = i + 1
        else
            break
        end
    end
    return i
end

local function parse_string(s, i)
    -- caller guarantees s:sub(i,i) == '"'
    local buf = {}
    i = i + 1
    while true do
        if i > #s then error("unterminated string", 0) end
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == '"' then buf[#buf + 1] = '"'
            elseif e == "\\" then buf[#buf + 1] = "\\"
            elseif e == "/" then buf[#buf + 1] = "/"
            elseif e == "b" then buf[#buf + 1] = "\b"
            elseif e == "f" then buf[#buf + 1] = "\f"
            elseif e == "n" then buf[#buf + 1] = "\n"
            elseif e == "r" then buf[#buf + 1] = "\r"
            elseif e == "t" then buf[#buf + 1] = "\t"
            elseif e == "u" then
                local hex = s:sub(i + 2, i + 5)
                if not hex:match("^%x%x%x%x$") then error("bad \\u escape", 0) end
                local cp = tonumber(hex, 16)
                buf[#buf + 1] = cp < 128 and string.char(cp) or utf8.char(cp)
                i = i + 4
            else
                error("bad escape \\" .. tostring(e), 0)
            end
            i = i + 2
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
end

local function parse_number(s, i)
    local _, b = s:find("^%-?%d+%.?%d*", i)
    if not b then error("invalid number", 0) end
    local _, eb = s:find("^[eE][%+%-]?%d+", b + 1)
    local j = eb or b
    local token = s:sub(i, j)
    local n = tonumber(token)
    if not n then error("invalid number: " .. token, 0) end
    return n, j + 1
end

local parse_value, parse_object, parse_array   -- forward declarations

function parse_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)             -- past '{'
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        i = skip_ws(s, i)
        if s:sub(i, i) ~= '"' then error("expected string key", 0) end
        local key, ni = parse_string(s, i)
        i = skip_ws(s, ni)
        if s:sub(i, i) ~= ":" then error("expected ':'", 0) end
        local val, vi = parse_value(s, skip_ws(s, i + 1))
        obj[key] = val               -- nil (JSON null) just leaves key absent
        i = skip_ws(s, vi)
        local c = s:sub(i, i)
        if c == "," then i = i + 1
        elseif c == "}" then return obj, i + 1
        else error("expected ',' or '}'", 0) end
    end
end

function parse_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)             -- past '['
    if s:sub(i, i) == "]" then return arr, i + 1 end
    local idx = 0
    while true do
        local val, vi = parse_value(s, skip_ws(s, i))
        idx = idx + 1
        arr[idx] = val               -- nil (JSON null) leaves a hole; ok for us
        i = skip_ws(s, vi)
        local c = s:sub(i, i)
        if c == "," then i = i + 1
        elseif c == "]" then return arr, i + 1
        else error("expected ',' or ']'", 0) end
    end
end

function parse_value(s, i)
    i = skip_ws(s, i)
    if i > #s then error("unexpected end of input", 0) end
    local c = s:sub(i, i)
    if c == "{" then return parse_object(s, i)
    elseif c == "[" then return parse_array(s, i)
    elseif c == '"' then return parse_string(s, i)
    elseif c == "t" then
        if s:sub(i, i + 3) == "true" then return true, i + 4 end
        error("invalid literal", 0)
    elseif c == "f" then
        if s:sub(i, i + 4) == "false" then return false, i + 5 end
        error("invalid literal", 0)
    elseif c == "n" then
        if s:sub(i, i + 3) == "null" then return nil, i + 4 end
        error("invalid literal", 0)
    elseif c == "-" or c:match("%d") then
        return parse_number(s, i)
    else
        error("unexpected character '" .. c .. "'", 0)
    end
end

function M.decode(str)
    if type(str) ~= "string" then return nil, "json: input is not a string" end
    local ok, val = pcall(function()
        local i = skip_ws(str, 1)
        if i > #str then error("empty input", 0) end
        local v, ni = parse_value(str, i)
        ni = skip_ws(str, ni)
        if ni <= #str then error("trailing junk", 0) end
        return v
    end)
    if not ok then
        return nil, "json: " .. tostring(val)
    end
    return val
end

return M
