-- announce.lua — on-screen heads-up before a chaos event fires.
--
-- The sidecar resolves a winner and publishes it `announceLeadSeconds` before it
-- should execute (see ADR-0004). The mod shows this the moment it sees the fresh
-- winner so the player knows what's coming, then holds execution until the lead
-- elapses.
--
-- Rendering uses Subnautica 2's OWN notification system (the one cheats like God
-- mode pop up): USN2Statics::GetLocalNotificationComponent(world) ->
-- UUWENotificationComponent::ClientNotify(FNotificationData). FText fields are
-- built via UKismetTextLibrary::Conv_StringToText. Class layout reverse-engineered
-- from the UE4SS CXXHeaderDump (UWENotifications.hpp / Subnautica2.hpp). Plain
-- UKismetSystemLibrary:PrintString is kept as a last-resort fallback. Everything
-- is pcall-guarded and degrades to a log line. format()/fields() are pure so the
-- wording is unit-tested.

local log = require("log")

local M = {}

-- EUWENotificationType (UWENotifications_enums.hpp). Warning stands out without
-- looking like a hard error.
M.TYPE_WARNING = 6

-- format(label, seconds) -> the banner string. Pure.
function M.format(label, seconds)
	local secs = math.floor(tonumber(seconds) or 0)
	return string.format("Chaos incoming: %s  (in %ds)", tostring(label or "?"), secs)
end

-- fields(label, seconds) -> plain notification fields (no engine types). Pure;
-- show() converts header/text to FText and assembles the struct.
function M.fields(label, seconds)
	return {
		header = "Sub2 Chaos",
		text = M.format(label, seconds),
		type = M.TYPE_WARNING,
		duration = math.max(tonumber(seconds) or 0, 1.0),
	}
end

local world_getter

-- configure(get_world): inject the world getter (UEHelpers.GetWorld) once at boot.
function M.configure(get_world)
	world_getter = get_world
end

local function get_world()
	if not world_getter then return nil end
	local ok, w = pcall(world_getter)
	if ok and w and w.IsValid and w:IsValid() then return w end
	return nil
end

-- Resolve a Blueprint-function-library CDO by trying a list of object paths then
-- a FindFirstOf short name. Cached per key once valid.
local cdo_cache = {}
local function resolve_cdo(key, paths, short)
	local c = cdo_cache[key]
	if c and c.IsValid and c:IsValid() then return c end
	for _, p in ipairs(paths) do
		local o
		if StaticFindObject then pcall(function() o = StaticFindObject(p) end) end
		if o and o.IsValid and o:IsValid() then cdo_cache[key] = o; return o end
	end
	if short and FindFirstOf then
		local o
		pcall(function() o = FindFirstOf(short) end)
		if o and o.IsValid and o:IsValid() then cdo_cache[key] = o; return o end
	end
	return nil
end

-- Build an FText from a Lua string via UKismetTextLibrary. Returns the FText
-- In-game notification toggle. The FIRST attempt — UUWENotificationComponent::
-- ClientNotify(FNotificationData) — hard-crashed the game (it's a *Client RPC*;
-- a crash dump landed at the exact millisecond of an announce, 2026-06-18). This
-- path now uses UUWEGameplayMessageBPLibrary instead, which is a plain
-- BlueprintFunctionLibrary taking only (WorldContext, FString) — no struct, no
-- gameplay tag, no RPC — and is the route in-game string notifications use. Set
-- this false to fall back to log-only if anything still misbehaves.
M.use_ingame_notification = true

-- Try the game's notification system via the gameplay-message BP library. Returns
-- true on success. Only simple-typed (string) calls are made — no FNotificationData
-- struct and no Client RPC, which is what crashed the first attempt.
local function notify_ingame(f)
	if not M.use_ingame_notification then return false end
	local world = get_world()
	if not world then return false end
	local lib = resolve_cdo("msglib",
		{ "/Script/UWEGameplayMessageRuntime.Default__UWEGameplayMessageBPLibrary" },
		"UWEGameplayMessageBPLibrary")
	if not lib then return false end
	-- BroadcastStringMessageToAllPlayers(WorldContext, FString) — simplest path.
	local ok = pcall(function() lib:BroadcastStringMessageToAllPlayers(world, f.text) end)
	if ok then return true end
	-- Fallback name: NotifyAllPlayersString(WorldContext, FString, FromPlayerId).
	return pcall(function() lib:NotifyAllPlayersString(world, f.text, -1) end) and true or false
end

-- Last-resort: engine debug text. Only renders if "show debug" overlays are on,
-- so it's the fallback, not the primary path.
local function print_string(text, seconds)
	local ksl = resolve_cdo("ks",
		{ "/Script/Engine.Default__KismetSystemLibrary" }, "KismetSystemLibrary")
	if not ksl then return false end
	local dur = math.max(tonumber(seconds) or 0, 1.0)
	local color = { R = 1.0, G = 0.55, B = 0.0, A = 1.0 }
	return pcall(function()
		ksl:PrintString(get_world(), text, true, false, color, dur, "")
	end) and true or false
end

-- show(label, seconds): display the heads-up. Prefers the game's notification
-- system; falls back to PrintString. Always logs (so headless/log-only is fine).
function M.show(label, seconds)
	local f = M.fields(label, seconds)
	log.info("announce: " .. f.text)
	if notify_ingame(f) then
		log.event("announce.shown", { via = "notification" })
		return true
	end
	if print_string(f.text, seconds) then
		log.event("announce.shown", { via = "printstring" })
		return true
	end
	log.event("announce.shown", { via = "log_only" })
	return false
end

return M
