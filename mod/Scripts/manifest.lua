-- manifest.lua — builds the SN2ModSettings registration table. Only the gates
-- live in-game; all chat/timing config is on the sidecar. SN2ModSettings renders
-- toggle/rotator (text/slider/keybind also exist); we only need toggles + one
-- rotator. main.lua writes this at module-load via settings_bridge.write_manifest.

local M = {}

M.MOD_NAME = "Sub2Chaos"
M.VERSION = "0.1.0"

function M.build()
	return {
		display = "Sub2 Chaos",
		github = "sub2_chaos",
		name = M.MOD_NAME,
		version = M.VERSION,
		settings = {
			{
				key = "enable_chaos",
				title = "Enable chaos events",
				description = "Master switch for chat-voted events.",
				type = "toggle",
				default = true,
			},
			{
				key = "enable_good",
				title = "Allow player-helping events",
				description = "Heal, invincibility, super speed, free items.",
				type = "toggle",
				default = true,
			},
			{
				key = "enable_bad",
				title = "Allow player-harming events",
				description = "Leviathan spawns, taking damage.",
				type = "toggle",
				default = true,
			},
			{
				key = "enable_chaotic",
				title = "Allow chaotic events",
				description = "Slow-motion, ghost mode, leviathan swarms.",
				type = "toggle",
				default = true,
			},
			{
				key = "enable_leviathans",
				title = "Allow leviathan spawns",
				description = "The spiciest events. Turn off to keep them out of the pool.",
				type = "toggle",
				default = true,
			},
			{
				key = "log_level",
				title = "Log verbosity",
				type = "rotator",
				options = { "trace", "info", "warn", "error" },
				default = "info",
			},
			{
				key = "enable_hotkeys",
				title = "Enable debug hotkeys",
				description = "Manual test keys; leave off for normal play.",
				type = "toggle",
				default = false,
			},
		},
	}
end

return M
