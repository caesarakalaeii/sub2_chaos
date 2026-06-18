-- Pre-rendered SN2ModSettings registration (mirrors mod/Scripts/manifest.lua).
-- SN2ModSettings reads this at its own boot, before our main.lua runs, so the
-- options show correctly on the first launch. main.lua also rewrites it at
-- module-load so edits to manifest.lua propagate on the next launch.
return {
	display = "Sub2 Chaos",
	github = "sub2_chaos",
	name = "Sub2Chaos",
	version = "0.1.0",
	settings = {
		{
			default = true,
			description = "Master switch for chat-voted events.",
			key = "enable_chaos",
			title = "Enable chaos events",
			type = "toggle",
		},
		{
			default = true,
			description = "Heal, invincibility, super speed, free items.",
			key = "enable_good",
			title = "Allow player-helping events",
			type = "toggle",
		},
		{
			default = true,
			description = "Leviathan spawns, taking damage.",
			key = "enable_bad",
			title = "Allow player-harming events",
			type = "toggle",
		},
		{
			default = true,
			description = "Slow-motion, ghost mode, leviathan swarms.",
			key = "enable_chaotic",
			title = "Allow chaotic events",
			type = "toggle",
		},
		{
			default = true,
			description = "The spiciest events. Turn off to keep them out of the pool.",
			key = "enable_leviathans",
			title = "Allow leviathan spawns",
			type = "toggle",
		},
		{
			default = "info",
			key = "log_level",
			options = { "trace", "info", "warn", "error" },
			title = "Log verbosity",
			type = "rotator",
		},
		{
			default = false,
			description = "Manual test keys; leave off for normal play.",
			key = "enable_hotkeys",
			title = "Enable debug hotkeys",
			type = "toggle",
		},
	},
}
