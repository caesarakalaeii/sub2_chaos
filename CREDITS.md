# Credits

**sub2_chaos** reuses proven Lua utilities and patterns from its sibling project
[**sub2_random**](https://github.com/caesarakalaeii/sub2_random) (also by
caesarakalaeii):

- `mod/Scripts/cheats.lua` — SN2CheatManager passthrough (god / slomo / swim
  speed / spawn / health / unlock).
- `mod/Scripts/aggro.lua` — leviathan prey-tag aggro orchestration.
- `mod/Scripts/json.lua` — dependency-free, partial-tolerant JSON codec.
- `mod/Scripts/log.lua` — structured logger.
- `mod/Scripts/settings_bridge.lua` — SN2ModSettings bridge.
- `mod/Scripts/aggro_loop.lua` is a lean extract of sub2_random's
  `spawn_hook.start_static_aggro_loop`.
- `vote-engine/internal/bridge/detect*.go` adapts sub2_random's installer's
  Steam-library detection.

The SN2ModSettings bridge pattern in `settings_bridge.lua` was originally lifted
from **Zeusfail / Too-Many-Divers** (`main.lua`) — see the note at the top of
that file.

Subnautica 2 runtime modding is powered by
[**UE4SS**](https://github.com/UE4SS-RE/RE-UE4SS). Live chat aggregation (the
YouTube-capable path) is provided by
[**all-chat**](https://github.com/caesarakalaeii/all-chat).
