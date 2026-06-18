local manifest = require("manifest")
local settings_bridge = require("settings_bridge")

describe("manifest", function()
	it("builds a serializable SN2ModSettings manifest", function()
		local m = manifest.build()
		assert.are.equal("Sub2Chaos", m.name)
		assert.is_true(#m.settings >= 5)
		local serialized = settings_bridge.serialize_manifest(m) -- validates key/type/default
		assert.is_truthy(serialized:find("enable_chaos"))
		assert.is_truthy(serialized:find("enable_leviathans"))
	end)

	it("every setting has key, type and a non-nil default", function()
		for _, s in ipairs(manifest.build().settings) do
			assert.is_truthy(s.key)
			assert.is_truthy(s.type)
			assert.is_true(s.default ~= nil)
		end
	end)

	it("the pre-rendered registration matches manifest.build()", function()
		local rendered = dofile("mod/SN2ModSettings_registration.lua")
		local built = manifest.build()
		-- serialize_manifest sorts keys, so this compares structure not formatting.
		assert.are.equal(
			settings_bridge.serialize_manifest(rendered),
			settings_bridge.serialize_manifest(built),
			"mod/SN2ModSettings_registration.lua is stale — re-render from manifest.build()")
	end)
end)
