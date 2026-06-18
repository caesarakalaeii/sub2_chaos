-- Pre-rendered SN2ModSettings registration (mirrors mod/Scripts/manifest.lua).
-- SN2ModSettings reads this at its own boot, before our main.lua runs, so the
-- options show correctly on the first launch. main.lua also rewrites it at
-- module-load so edits to manifest.lua propagate on the next launch.
return {
    display = "Sub2 Chaos",
    github = "sub2_chaos",
    name = "Sub2Chaos",
    settings = {
        {
            default = true,
            description = "Master switch for chat-voted events.",
            key = "enable_chaos",
            title = "Enable chaos events",
            type = "toggle"
        },
        {
            default = true,
            description = "Heal, invincibility, super speed, free items.",
            key = "enable_good",
            title = "Allow player-helping events",
            type = "toggle"
        },
        {
            default = true,
            description = "Leviathan spawns, taking damage.",
            key = "enable_bad",
            title = "Allow player-harming events",
            type = "toggle"
        },
        {
            default = true,
            description = "Slow-motion, ghost mode, leviathan swarms.",
            key = "enable_chaotic",
            title = "Allow chaotic events",
            type = "toggle"
        },
        {
            default = true,
            description = "The spiciest events. Turn off to keep them out of the pool.",
            key = "enable_leviathans",
            title = "Allow leviathan spawns",
            type = "toggle"
        },
        {
            default = 30,
            description = "How long each voting window stays open.",
            format = "integer",
            key = "vote_duration",
            max = 120,
            min = 5,
            step = 5,
            title = "Vote duration (seconds)",
            type = "slider"
        },
        {
            default = 4,
            description = "How many events viewers choose between each round (they type 1..N).",
            format = "integer",
            key = "vote_options",
            max = 9,
            min = 2,
            step = 1,
            title = "Options per vote",
            type = "slider"
        },
        {
            default = 20,
            description = "Pause after a winner before the next vote starts. 0 = back-to-back.",
            format = "integer",
            key = "vote_cooldown",
            max = 120,
            min = 0,
            step = 5,
            title = "Cooldown between votes (seconds)",
            type = "slider"
        },
        {
            default = 1,
            description = "Scales how long timed effects last (invincibility, super speed, slow/fast world, ghost mode). 1.0 = catalog default.",
            format = "float",
            key = "effect_duration_scale",
            max = 3,
            min = 0.25,
            step = 0.25,
            title = "Effect duration multiplier",
            type = "slider"
        },
        {
            default = 1500,
            description = "Swim speed during the Super Swim Speed event (UE units/s). ~400 is normal.",
            enabled_by = "enable_good",
            format = "integer",
            key = "super_speed",
            max = 3000,
            min = 400,
            step = 100,
            title = "Super swim speed",
            type = "slider"
        },
        {
            default = 2.5,
            description = "Time dilation for the Fast World event (>1 = faster).",
            enabled_by = "enable_chaotic",
            format = "float",
            key = "slomo_fast_rate",
            max = 5,
            min = 1.5,
            step = 0.5,
            title = "Fast World speed",
            type = "slider"
        },
        {
            default = 0.4,
            description = "Time dilation for the Molasses World event (<1 = slower).",
            enabled_by = "enable_chaotic",
            format = "float",
            key = "slomo_slow_rate",
            max = 0.9,
            min = 0.1,
            step = 0.1,
            title = "Slow World speed",
            type = "slider"
        },
        {
            default = 25,
            description = "Health the Take Damage event drops you to (out of 100). Lower = nastier.",
            enabled_by = "enable_bad",
            format = "integer",
            key = "hurt_player_hp",
            max = 90,
            min = 1,
            step = 1,
            title = "Damage event leaves you at (HP)",
            type = "slider"
        },
        {
            default = 800,
            description = "How far ahead of you leviathans spawn (UE units). 100 ~= 1 metre.",
            enabled_by = "enable_leviathans",
            format = "integer",
            key = "leviathan_spawn_distance",
            max = 3000,
            min = 400,
            step = 100,
            title = "Leviathan spawn distance",
            type = "slider"
        },
        {
            default = 3,
            description = "How many leviathans the swarm event spawns.",
            enabled_by = "enable_leviathans",
            format = "integer",
            key = "swarm_size",
            max = 6,
            min = 2,
            step = 1,
            title = "Leviathan swarm size",
            type = "slider"
        },
        {
            default = "info",
            key = "log_level",
            options = {
                "trace",
                "info",
                "warn",
                "error"
            },
            title = "Log verbosity",
            type = "rotator"
        },
        {
            default = false,
            description = "Manual test keys; leave off for normal play.",
            key = "enable_hotkeys",
            title = "Enable debug hotkeys",
            type = "toggle"
        }
    },
    version = "0.1.0"
}
