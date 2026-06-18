-- Minimal busted-compatible test runner for the ChaosMod Lua modules.
--   lua tests/run.lua        (run from the repo root)
--
-- Same test files run under real busted too; this shim just provides
-- describe / it / assert.are.equal / assert.is_true etc.

package.path = "mod/Scripts/?.lua;tests/support/?.lua;" .. package.path

local _passed, _failed = 0, 0
local _suite = "?"

function describe(name, fn)
	_suite = name
	fn()
end

function it(name, fn)
	local ok, err = pcall(fn)
	if ok then
		_passed = _passed + 1
		print(string.format("  PASS %s :: %s", _suite, name))
	else
		_failed = _failed + 1
		print(string.format("  FAIL %s :: %s\n        %s", _suite, name, tostring(err)))
	end
end

local _native_assert = assert
local _A = {}
setmetatable(_A, { __call = function(_, v, msg) return _native_assert(v, msg) end })
_A.are = {}

function _A.are.equal(a, b, msg)
	if a ~= b then
		error(string.format("expected %s == %s%s", tostring(a), tostring(b),
			msg and (" : " .. msg) or ""), 2)
	end
end

local function deep_eq(x, y)
	if type(x) ~= type(y) then return false end
	if type(x) ~= "table" then return x == y end
	for k, v in pairs(x) do if not deep_eq(v, y[k]) then return false end end
	for k, v in pairs(y) do if not deep_eq(v, x[k]) then return false end end
	return true
end

function _A.are.same(a, b, msg)
	if not deep_eq(a, b) then
		error("tables not deeply equal" .. (msg and (" : " .. msg) or ""), 2)
	end
end

function _A.is_true(v, msg)
	if v ~= true then error(msg or ("expected true, got " .. tostring(v)), 2) end
end

function _A.is_false(v, msg)
	if v ~= false then error(msg or ("expected false, got " .. tostring(v)), 2) end
end

function _A.is_truthy(v, msg)
	if not v then error(msg or ("expected truthy, got " .. tostring(v)), 2) end
end

function _A.is_nil(v, msg)
	if v ~= nil then error(msg or ("expected nil, got " .. tostring(v)), 2) end
end

assert = _A

local files = {
	"tests/buffs_test.lua",
	"tests/vote_bridge_test.lua",
	"tests/events_test.lua",
	"tests/chaos_test.lua",
	"tests/chaos_integration_test.lua",
	"tests/manifest_test.lua",
}
for _, file in ipairs(files) do
	print("--- " .. file)
	local ok, err = pcall(dofile, file)
	if not ok then
		print("  LOAD ERROR " .. file .. ": " .. tostring(err))
		_failed = _failed + 1
	end
end

print(string.format("\n%d passed, %d failed", _passed, _failed))
os.exit(_failed == 0 and 0 or 1)
