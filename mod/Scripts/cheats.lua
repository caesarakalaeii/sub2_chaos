-- Cheat passthrough — call SN2CheatManager UFunctions from Lua so we
-- don't depend on the in-game console (which is keyboard-layout-
-- sensitive under Wine/Proton).
--
-- Doubles as the v0.3 escape hatch: Ctrl+End calls UnlockAllRecipes
-- and also tells us whether the unlock UFunctions actually propagate
-- through our story_goals hooks.

local log = require("log")

local M = {}

local function find_cheat_manager()
    -- Most reliable: PlayerController.CheatManager (the bundled
    -- CheatManagerEnablerMod constructs one if missing). Fall back to
    -- direct FindFirstOf if PlayerController isn't around yet.
    local pc = FindFirstOf("PlayerController")
    if pc then
        local ok, cm = pcall(function() return pc.CheatManager end)
        if ok and cm then
            local ok2, valid = pcall(function() return cm:IsValid() end)
            if ok2 and valid then return cm, "PlayerController.CheatManager" end
        end
    end
    local cm = FindFirstOf("SN2CheatManager") or FindFirstOf("CheatManager")
    if cm then return cm, "FindFirstOf" end
    return nil, nil
end

local function call_cheat(method, ...)
    local cm, source = find_cheat_manager()
    if not cm then
        log.error("cheats:", method, "— no CheatManager instance found")
        return false
    end
    log.info(string.format("cheats: calling %s via %s", method, source))
    local fn
    local ok, err = pcall(function() fn = cm[method] end)
    if not ok or not fn then
        log.error("cheats:", method, "— method not found:", err)
        return false
    end
    local ok2, ret = pcall(fn, cm, ...)
    if not ok2 then
        log.error("cheats:", method, "— call raised:", ret)
        return false
    end
    log.info("cheats:", method, "OK")
    return true
end

function M.unlock_all_recipes()
    return call_cheat("UnlockAllRecipes")
end

function M.unlock_all()
    return call_cheat("UnlockAll")
end

function M.unlock(name)
    return call_cheat("Unlock", name)
end

-- Emergency recovery: dislodge the player from stuck-in-geometry /
-- can't-move states. Same as the SN2 console `unstuck` cmd.
function M.unstuck()
    return call_cheat("Unstuck")
end

-- Resurface (handy if drowning underwater while unable to swim).
function M.surface()
    return call_cheat("surface")
end

-- Set player HP. Float in 0..100 range (full HP = 100).
function M.my_health(value)
    return call_cheat("MyHealth", value or 100)
end

-- Destroy creatures matching CreatureName, up to Amount total.
-- Signature confirmed via Ctrl+A dump: (CreatureName: str, Amount: float).
-- Empty name + large amount = destroy all. Used to verify
-- SpawnRandomizer's DA-level shuffle reaches new spawns (live
-- creatures keep their class until killed and respawned).
function M.destroy_creatures(name, amount)
    return call_cheat("DestroyCreatures", name or "", amount or 9999)
end

-- WorldPopRemove targets the UWEWorldPopulation2 subsystem directly.
-- Single ResourceName string arg — empty likely removes everything.
function M.world_pop_remove(resource)
    return call_cheat("WorldPopRemove", resource or "")
end

-- KillAll — parameterless UE5-style "kill every AI". Cleanest call
-- of the bunch; usually the right pick for testing fresh spawn flow.
function M.kill_all()
    return call_cheat("KillAll")
end

-- UnpossessAllCreatures — parameterless, releases AI control of
-- every creature. May not despawn but stops them from re-spawning
-- into the same population on tick.
function M.unpossess_all_creatures()
    return call_cheat("UnpossessAllCreatures")
end

-- Standard UE5 CheatManager methods inherited via PlayerController.
-- Ghost = no collision + fly (true noclip). Fly = fly with collision.
-- Walk = restore gravity. Slomo(N) = time dilation; >1.0 = faster.
-- NOTE: the inherited Ghost/Fly/Walk no-op on SN2's custom swim pawn (they
-- return OK but nothing changes). Use M.noclip() for in-game noclip instead.
function M.ghost()  return call_cheat("Ghost") end
function M.fly()    return call_cheat("Fly") end
function M.walk()   return call_cheat("Walk") end
function M.god()    return call_cheat("God") end
function M.slomo(v) return call_cheat("Slomo", v or 1.0) end

-- SN2's OWN noclip cheat (USN2CheatManager::NoClip, Subnautica2.hpp). Unlike the
-- inherited Ghost, this one actually works on the swim pawn. It's a TOGGLE, so
-- call it again to turn it back off.
function M.noclip() return call_cheat("NoClip") end
function M.teleport() return call_cheat("Teleport") end

-- SwimSpeed(float) — USN2CheatManager absolute swim-speed setter. Player-only
-- (no world time dilation, unlike Slomo) and continuous movement (not teleport),
-- so it's the clean way to cover distance during a young-world gate test without
-- confounding the exe+0x63623dd streaming-race result. NOTE: the dedicated
-- FastSwim toggle is build-disabled ("disabled in this build"); SwimSpeed is a
-- separate parameterized command. Value is absolute in UE units (cm/s) — tune
-- the default if it's too fast/slow. ~300–500 ≈ normal; 1500 ≈ ~5x.
function M.swim_speed(n) return call_cheat("SwimSpeed", n or 1500) end

-- SN2's dev creature-spawn cheat. UAT 2026-05-25 confirmed the
-- UFunction wants exactly 1 parameter — the creature name string.
-- (We initially passed (name, amount); UE4SS responded "expected 1
-- parameters, received 2".) The amount is fixed at 1 per call.
-- Uses the engine's blessed spawn path — same one the dev menu uses
-- — so WorldPop registration / BeginPlay context are wired properly.
--   name: short creature name without BP_ prefix or _C suffix
function M.spawn_creature(name)
    return call_cheat("SpawnCreature", name or "Halfmoon")
end

-- USN2CheatManager::Give(FString ItemNameAndQuantity) — the dev item-grant cheat
-- (same blessed path as SpawnCreature, so it adds to the inventory properly). The
-- arg is "<ItemName> <Quantity>", e.g. "Gold 1". Far more reliable than spawning
-- a BP_ pickup actor by hand (which can fail collision or crash on a bad class).
function M.give(item_and_qty)
    return call_cheat("Give", item_and_qty or "Gold 1")
end

-- Teleport the player pawn N units along the camera's forward vector.
-- UE5 standard rotation conventions: Yaw is around Z (heading), Pitch
-- is up/down. Forward = (cos(yaw)*cos(pitch), sin(yaw)*cos(pitch),
-- sin(pitch)). Z is up in UE5.
function M.teleport_forward(distance)
    distance = distance or 2000
    local pc = FindFirstOf("PlayerController")
    if not pc then
        log.warn("cheats.teleport_forward: no PlayerController")
        return false
    end
    -- Use the controller's view rotation (matches camera direction)
    -- when available so the teleport follows where you're looking
    -- rather than where the pawn faces. Pawn rotation is yaw-only;
    -- camera rotation includes pitch so swimming forward-and-up works.
    local pawn = nil
    pcall(function() pawn = pc.Pawn end)
    if not pawn then
        log.warn("cheats.teleport_forward: no Pawn")
        return false
    end
    local loc, rot
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    -- Camera rotation gives pitch+yaw; the pawn's K2_GetActorRotation
    -- on many UE5 games is yaw-only. GetControlRotation works on PC.
    pcall(function() rot = pc:GetControlRotation() end)
    if not rot then
        pcall(function() rot = pawn:K2_GetActorRotation() end)
    end
    if not loc or not rot then
        log.warn("cheats.teleport_forward: failed to read pawn loc/rot")
        return false
    end
    local yaw   = math.rad(rot.Yaw   or 0)
    local pitch = math.rad(rot.Pitch or 0)
    local fx = math.cos(yaw) * math.cos(pitch)
    local fy = math.sin(yaw) * math.cos(pitch)
    local fz = math.sin(pitch)
    local new_loc = {
        X = loc.X + fx * distance,
        Y = loc.Y + fy * distance,
        Z = loc.Z + fz * distance,
    }
    -- UFunction marshaling in UE4SS rejects nil for FHitResult Out
    -- params. Try K2_TeleportTo first (simpler signature, no out
    -- param), fall back to K2_SetActorLocation with an empty table for
    -- the out hit result.
    local ok, err = pcall(function()
        pawn:K2_TeleportTo(new_loc,
            { Pitch = rot.Pitch or 0, Yaw = rot.Yaw or 0, Roll = rot.Roll or 0 })
    end)
    if not ok then
        local ok2, err2 = pcall(function()
            -- (NewLocation, bSweep, OutSweepHitResult, bTeleport)
            -- Pass empty {} for the FHitResult out so the marshaler
            -- has a table to write into.
            pawn:K2_SetActorLocation(new_loc, false, {}, true)
        end)
        if not ok2 then
            log.warn("cheats.teleport_forward: both teleport calls failed: "
                .. tostring(err) .. " / " .. tostring(err2))
            return false
        end
    end
    log.info(string.format(
        "cheats.teleport_forward: moved %d units to (%.0f,%.0f,%.0f)",
        distance, new_loc.X, new_loc.Y, new_loc.Z))
    return true
end

function M.install_hotkeys()
    if not RegisterKeyBind then
        log.warn("cheats: RegisterKeyBind unavailable")
        return false
    end
    pcall(RegisterKeyBind, Key.END, { ModifierKey.CONTROL }, function()
        M.unlock_all_recipes()
    end)
    pcall(RegisterKeyBind, Key.HOME, { ModifierKey.CONTROL }, function()
        M.unlock_all()
    end)
    -- Emergency recovery bindings on keys present on tenkeyless / German
    -- layouts (Insert is absent on those — we use PageDown instead).
    pcall(RegisterKeyBind, Key.PAGE_DOWN, { ModifierKey.CONTROL }, function()
        M.my_health(100)
    end)
    pcall(RegisterKeyBind, Key.DELETE, { ModifierKey.CONTROL }, function()
        M.unstuck()
    end)
    pcall(RegisterKeyBind, Key.PAGE_UP, { ModifierKey.CONTROL }, function()
        M.surface()
    end)
    -- Ctrl+X = KillAll (the cleanest 0-arg despawn UFunction on
    -- SN2CheatManager). For SpawnRandomizer verification: shuffle
    -- DAs via Ctrl+B then Ctrl+X to despawn and let the WorldPop
    -- subsystem re-spawn. Fresh spawns reflect the new shuffle if
    -- the subsystem reads the DAs live (vs. cached at startup).
    pcall(RegisterKeyBind, Key.X, { ModifierKey.CONTROL }, function()
        M.kill_all()
    end)
    -- Ctrl+Z = DestroyCreatures with wildcard ("" name, 9999 amount).
    -- If Ctrl+X doesn't fire fresh spawns, this targets WorldPop more
    -- directly. Then if still vanilla, the cache invalidation hunt
    -- begins on UWEWorldPopCreaturesSubsystem.
    pcall(RegisterKeyBind, Key.Z, { ModifierKey.CONTROL }, function()
        M.destroy_creatures()
    end)
    -- Movement / utility cheats. Ctrl+1 toggles noclip (Ghost = no
    -- collision + free fly). Ctrl+2 sets 3x time dilation (effectively
    -- 3x player speed). Ctrl+3 restores normal speed. Ctrl+4 toggles
    -- god mode (invulnerability). Useful for moving between biomes
    -- quickly when testing creature spawn shuffles.
    pcall(RegisterKeyBind, Key.ONE,   { ModifierKey.CONTROL }, function() M.ghost() end)
    pcall(RegisterKeyBind, Key.TWO,   { ModifierKey.CONTROL }, function() M.slomo(3.0) end)
    pcall(RegisterKeyBind, Key.THREE, { ModifierKey.CONTROL }, function() M.slomo(1.0) end)
    pcall(RegisterKeyBind, Key.FOUR,  { ModifierKey.CONTROL }, function() M.god() end)
    -- Ctrl+F = SwimSpeed boost (player-only fast swim; FastSwim toggle is
    -- build-disabled). Ctrl+3 (Slomo 1x) does NOT reset this — re-call with the
    -- default value or relaunch to restore normal swim speed.
    pcall(RegisterKeyBind, Key.F, { ModifierKey.CONTROL }, function() M.swim_speed() end)
    -- Ctrl+Arrow keys: teleport 2000 units along the camera's view
    -- direction (UP = forward) or opposite (DOWN = backward). UE4SS
    -- uses Key.UP_ARROW (0x26) / Key.DOWN_ARROW (0x28), NOT Key.UP /
    -- Key.DOWN (those are nil in this build).
    local up_ok = pcall(RegisterKeyBind, Key.UP_ARROW,   { ModifierKey.CONTROL },
        function() M.teleport_forward(2000) end)
    local dn_ok = pcall(RegisterKeyBind, Key.DOWN_ARROW, { ModifierKey.CONTROL },
        function() M.teleport_forward(-2000) end)
    log.info(string.format(
        "cheats: Ctrl+UP_ARROW bind=%s, Ctrl+DOWN_ARROW bind=%s",
        tostring(up_ok), tostring(dn_ok)))
    log.info("cheats: Ctrl+End UnlockAllRecipes / Ctrl+Home UnlockAll / "
        .. "Ctrl+PageDown MyHealth=100 / Ctrl+Delete Unstuck / Ctrl+PageUp surface / "
        .. "Ctrl+X KillAll / Ctrl+Z DestroyCreatures(*,9999) / "
        .. "Ctrl+1 Ghost(noclip) / Ctrl+2 Slomo(3x) / Ctrl+3 Slomo(1x) / Ctrl+4 God / "
        .. "Ctrl+F SwimSpeed(1500) / "
        .. "Ctrl+UP +2000u forward / Ctrl+DOWN -2000u back")
    return true
end

return M
