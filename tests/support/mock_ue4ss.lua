-- Mock UE4SS environment for offline unit tests.
--
-- This is a MODEL of UE4SS behavior as understood on 2026-05-29, cited to
-- docs/ue4ss-reference/. It lets the game-touching modules (recipes,
-- base_pieces, spawn_hook) be exercised under plain `lua` with no engine.
--
-- IMPORTANT — what this can and CANNOT do (do not oversell green tests):
--   * It validates Lua control-flow and data transforms only.
--   * It CANNOT reproduce real UE5 memory layout, the documented
--     __newindex silent no-ops on Struct/SoftObject properties, streaming
--     races, or native SpawnActor crashes. Those stay on-device UAT.
--   * TMap/TSet are modelled as OPAQUE (iterating them errors) so a test
--     catches code that violates "TMap/TSet iteration hangs the game" — a
--     model of the hazard, not the real hang.
--
-- Usage:
--   local mock = require("mock_ue4ss")
--   local env = mock.new()
--   env:install()                       -- install fakes into _G + UEHelpers
--   local recipes = mock.fresh_require("recipes")
--   ... build state, drive hooks, assert ...
--   env:uninstall()                     -- restore _G; ALWAYS call this
--
-- mock.with_env(fn) runs fn(env) with install/uninstall bracketed via
-- pcall so a failing assertion can't leak globals into the next test.

local M = {}

-- ── Value wrappers ──────────────────────────────────────────────────────

-- RemoteUnrealParam. Faithfully requires :Get()/:get() to unwrap. We
-- expose ONLY get/set/type — calling :IsValid() on the WRAPPER fails
-- (the docs say never IsValid a wrapper), so code that forgets to unwrap
-- before validating gets caught.
local function wrap_param(value)
    return setmetatable({}, { __index = {
        Get  = function() return value end,
        get  = function() return value end,
        Set  = function(_, v) value = v end,
        set  = function(_, v) value = v end,
        type = function() return "RemoteUnrealParam" end,
    } })
end
M.wrap_param = wrap_param

-- Opaque TMap/TSet: any iteration/length/index errors loudly, turning the
-- "iteration hangs the game" hazard into a catchable test failure.
local function opaque(kind)
    local guard = function() error(kind .. " iteration is forbidden (hangs the game)", 2) end
    return setmetatable({}, {
        __pairs = guard, __index = guard, __len = guard,
        __tostring = function() return "<opaque " .. kind .. ">" end,
    })
end
M.opaque_map = function() return opaque("TMap") end
M.opaque_set = function() return opaque("TSet") end

-- Soft-object-ptr stub. filter.soft_path tries GetAssetPathString /
-- ToSoftObjectPath / ToString; we answer with a /Game/... path so
-- short_item_name_from_path can extract DA_<X>_ItemType.
function M.soft_ptr(path)
    return setmetatable({}, { __index = {
        ToString          = function() return path end,
        GetAssetPathString = function() return path end,
    } })
end

-- Like soft_ptr, but OPAQUE to the string accessors — models this UE4SS
-- build's recipe ItemType soft-ptrs (soft_path returns nil for them). It
-- resolves ONLY via :Get(), returning a uobject whose GetFullName() carries
-- the path, so it exercises filter.resolve_item_short's UObject fallback.
function M.opaque_soft_ptr(path)
    local obj = M.uobject({ full = "UWEItemType " .. path })
    return setmetatable({}, { __index = {
        Get = function() return obj end,
    } })
end

-- A soft-ptr no resolver can crack: soft_path returns nil AND there's no
-- Get/ResolveObject, so filter.resolve_item_short yields nil ("?"). Models a
-- cut/placeholder ItemType — the case that used to leak unnamed items into
-- the shuffle. Still a table so `req.ItemType` access is safe.
function M.unresolvable_soft_ptr()
    return setmetatable({}, { __index = {} })
end

-- TArray<struct> with the :ForEach(idx, elem) + elem:get()/:set(struct)
-- protocol recipes/base_pieces rely on. structs is a list of plain tables.
--   :get() returns the LIVE struct table at this slot (re-reads reflect
--          current memory, like the real wrapper).
--   :set(s) copies s's fields INTO the existing struct table IN PLACE — this
--          is faithful to the engine, whose dest:set(src) does a
--          CopyScriptStruct into the destination element's own memory (it does
--          NOT allocate a fresh element). So a :get() view captured before a
--          :set() OBSERVES the overwrite — the aliasing that a "snapshot then
--          write in slot order" shuffle must account for. (The earlier mock
--          REPLACED the slot table, hiding this aliasing and letting a buggy
--          in-place shuffle look correct — it silently defeated the recipe
--          softlock guard in-game. See permute.lua / ADR-0017 /
--          feedback-apply-shuffle-aliasing.)
function M.tarray(structs)
    local arr = { _structs = structs or {} }
    local function write(idx, s)
        local d = arr._structs[idx]
        if d == s then return end          -- self-copy: nothing to do
        for k in pairs(d) do d[k] = nil end -- whole-struct copy: replace contents
        for k, v in pairs(s) do d[k] = v end
    end
    function arr:_elem(idx)
        return {
            get = function() return arr._structs[idx] end,
            Get = function() return arr._structs[idx] end,
            set = function(_, s) write(idx, s) end,
            Set = function(_, s) write(idx, s) end,
        }
    end
    function arr:ForEach(cb)
        for i = 1, #self._structs do cb(i, self:_elem(i)) end
    end
    return arr
end

-- FProperty stub for ForEachProperty. describe_property() reads
-- prop:GetFName():ToString() (the field name) and
-- prop:GetClass():GetFName():ToString() (the property TYPE, e.g.
-- "ArrayProperty"). No byte offset — that stays a C++-bridge capability.
function M.prop(name, type_name)
    return setmetatable({}, { __index = {
        GetFName = function() return { ToString = function() return name end } end,
        GetClass = function()
            return { GetFName = function()
                return { ToString = function() return type_name end }
            end }
        end,
    } })
end

-- UClass: name + super chain. short_of() does GetFName():ToString() then
-- strips _C; categorize/is_cdo use GetFullName. opts.properties (a list of
-- {name=, type=}) feeds ForEachProperty so dump_class/dump_components can be
-- exercised offline.
function M.uclass(opts)
    opts = opts or {}
    return setmetatable({}, { __index = {
        GetFName        = function() return { ToString = function() return opts.fname end } end,
        GetFullName     = function() return opts.full or opts.fname end,
        GetSuperClass   = function() return opts.super end,
        IsValid         = function() return opts.valid ~= false end,
        ForEachProperty = function(_, cb)
            for _, p in ipairs(opts.properties or {}) do cb(M.prop(p.name, p.type)) end
        end,
    } })
end

-- UObject / AActor. opts.fields are direct data properties (Requirements,
-- ConstructableParams, ConstructableComponent, AssetUserData, ...); methods
-- come from the metatable. opts.components is the plain array returned by
-- K2_GetComponentsByClass (a real TArray, so #/[i] are safe). Destructive
-- actor ops just record the call.
function M.uobject(opts)
    opts = opts or {}
    local methods = {
        GetFullName             = function() return opts.full or opts.fname or "(obj)" end,
        GetFName                = function() return { ToString = function() return opts.fname or opts.full or "?" end } end,
        GetClass                = function() return opts.class end,
        IsValid                 = function() return opts.valid ~= false end,
        K2_GetActorLocation     = function() return opts.location end,
        K2_GetActorRotation     = function() return opts.rotation end,
        GetActorScale3D         = function() return opts.scale end,
        GetController           = function() return opts.controller or opts._controller end,
        -- Runtime spawns have no AIController until SpawnDefaultController is
        -- called (models AutoPossessAI=PlacedInWorld). After the call,
        -- GetController returns the freshly-spawned controller.
        SpawnDefaultController  = function()
            opts._controller = M.uobject({ full = (opts.full or "actor") .. "_AIController" })
            return opts._controller
        end,
        SetActorHiddenInGame    = function(_, v) opts._hidden = v end,
        SetActorEnableCollision = function(_, v) opts._collision = v end,
        SetActorScale3D         = function(_, v) opts._scale = v end,
        SetActorTickEnabled     = function(_, v) opts._tick = v end,
        -- The safe relocate (ADR-0032): no FHitResult out-param. Records the
        -- destination so the banish can be asserted; updates the reported location.
        K2_TeleportTo           = function(_, dest, rot)
            opts._teleport = { dest = dest, rot = rot }
            opts.location  = dest
            return true
        end,
        -- The crashing relocate (FHitResult& out-param passed nil — commit dbeb8f1).
        -- Stubbed only so a test can assert apply_source_hide NEVER calls it.
        K2_SetActorLocation     = function(_, ...) opts._setactorlocation = true; return true end,
        K2_GetComponentsByClass = function() return opts.components or {} end,
        K2_GetRootComponent     = function() return opts.root or (opts.components and opts.components[1]) end,
        -- A destroyed actor is no longer valid (so the lifecycle cull can
        -- assert a substitute was actually torn down, not just dropped).
        K2_DestroyActor         = function() opts._destroyed = true; opts.valid = false end,
    }
    return setmetatable(opts.fields or {}, { __index = methods })
end

-- ── Convenience fixtures ────────────────────────────────────────────────

-- reqs = { { ItemType = soft_ptr_or_nil, NumItems = n }, ... }
function M.make_recipe(full, reqs)
    return M.uobject({ full = full, fields = { Requirements = M.tarray(reqs) } })
end

-- costs = { { ItemType = ..., Cost = n }, ... }
function M.make_constructable(full, costs)
    return M.uobject({
        full = full,
        fields = { ConstructableParams = { ResourceCost = M.tarray(costs) } },
    })
end

-- ── Environment factory ─────────────────────────────────────────────────

function M.new()
    local env = {
        _findall = {},                       -- short -> array of instances
        _byname  = {},                       -- path  -> object (StaticFindObject + LoadAsset)
        _loadonly = {},                      -- path  -> object (LoadAsset ONLY; models a not-yet-streamed class)
        _all     = {},                       -- ForEachUObject sweep set
        hooks    = { begin_play = {}, init_gamestate = {}, notify = {}, loops = {}, fn_hooks = {} },
        saved    = {},
        _world   = nil,
        _player_controller = nil,
        _spawn_class_override = nil,  -- if set, SpawnActor returns this class (models a BP that spawns the wrong actor)
    }
    env.ue_helpers = {
        GetWorld               = function() return env._world end,
        GetPlayerController     = function() return env._player_controller end,
        GetKismetSystemLibrary = function() return nil end,
    }

    -- builders ------------------------------------------------------------
    function env:add_findall(short, list) self._findall[short] = list end
    function env:add_object(path, obj)
        self._byname[path] = obj
        self._all[#self._all + 1] = obj
    end
    -- Register a class so resolve_uclass(short) hits StaticFindObject(path).
    function env:register_class(short, path, uclass)
        self._byname[path] = uclass or M.uclass({ fname = short .. "_C", full = path })
        return self._byname[path]
    end
    -- A class StaticFindObject MISSES but LoadAsset finds, so resolve_uclass
    -- returns fresh_load=true on first contact (then caches it). Models a
    -- not-yet-streamed class (e.g. a leviathan target during streaming).
    function env:make_loadable(short, path, uclass)
        self._loadonly[path] = uclass or M.uclass({ fname = short .. "_C", full = path })
        return self._loadonly[path]
    end
    -- A world whose SpawnActor returns a fresh valid actor each call.
    -- full_name defaults to a gameplay world (not a menu/lobby), so the
    -- spawn_hook InitGameState auto-enable path runs instead of deferring.
    function env:enable_world(full_name)
        full_name = full_name or "World /Game/Maps/Main/L_Main.L_Main"
        local n = 0
        self._world = setmetatable({}, { __index = {
            IsValid     = function() return true end,
            GetFullName = function() return full_name end,
            SpawnActor  = function(_, cls, _loc, _rot)
                n = n + 1
                -- The spawned actor's class is the one we were asked to
                -- spawn — unless _spawn_class_override is set, modeling a
                -- BP whose SpawnActor returns the wrong actor (a base part).
                local actor_cls = self._spawn_class_override or cls
                -- Record the transform args so tests can assert the caller
                -- spawned with the right location/rotation (not identity).
                self._last_spawn = { class = actor_cls, loc = _loc, rot = _rot }
                return M.uobject({ full = "Spawned_" .. n, class = actor_cls })
            end,
        } })
        return self._world
    end

    -- lifecycle drivers ---------------------------------------------------
    function env:fire_begin_play(actor)
        for _, cb in ipairs(self.hooks.begin_play) do cb(wrap_param(actor)) end
    end
    function env:fire_begin_play_raw(actor)   -- unwrapped path (build w/o param wrapping)
        for _, cb in ipairs(self.hooks.begin_play) do cb(actor) end
    end
    function env:fire_init_gamestate(gs)
        for _, cb in ipairs(self.hooks.init_gamestate) do cb(wrap_param(gs)) end
    end
    -- Fire a RegisterHook'd UFunction hook. Args are wrapped as RemoteUnrealParams
    -- (the real RegisterHook hands the callback wrapped params), so the hook must
    -- :Get() to unwrap — same protocol as the BeginPlay probe.
    function env:fire_hook(path, ...)
        local args = { ... }
        for _, cb in ipairs((self.hooks.fn_hooks[path]) or {}) do
            local wrapped = {}
            for i = 1, select("#", ...) do wrapped[i] = wrap_param(args[i]) end
            cb(table.unpack(wrapped, 1, select("#", ...)))
        end
    end
    function env:notify_new(path, obj)
        local keep = {}
        for _, cb in ipairs(self.hooks.notify[path] or {}) do
            if cb(obj) ~= true then keep[#keep + 1] = cb end  -- return true = unregister
        end
        self.hooks.notify[path] = keep
    end
    function env:tick_loops(times)
        for _ = 1, (times or 1) do
            for _, l in ipairs(self.hooks.loops) do l.fn() end  -- return value ignored (faithful)
        end
    end

    -- install / uninstall -------------------------------------------------
    function env:install()
        local function set(name, fn) self.saved[name] = _G[name]; _G[name] = fn end
        set("FindAllOf", function(short)
            local t = self._findall[short]
            return (t and #t > 0) and t or nil   -- nil when empty (faithful)
        end)
        set("FindFirstOf", function(short)
            local t = self._findall[short]; return t and t[1] or nil
        end)
        set("StaticFindObject", function(path) return self._byname[path] end)
        set("LoadAsset", function(path) return self._byname[path] or self._loadonly[path] end)
        set("ForEachUObject", function(cb) for _, o in ipairs(self._all) do cb(o) end end)
        set("ExecuteInGameThread", function(fn) fn() end)   -- synchronous
        set("RegisterBeginPlayPostHook", function(fn) table.insert(self.hooks.begin_play, fn) end)
        set("RegisterInitGameStatePostHook", function(fn) table.insert(self.hooks.init_gamestate, fn) end)
        set("RegisterHook", function(path, fn)
            self.hooks.fn_hooks[path] = self.hooks.fn_hooks[path] or {}
            table.insert(self.hooks.fn_hooks[path], fn)
        end)
        set("NotifyOnNewObject", function(path, fn)
            self.hooks.notify[path] = self.hooks.notify[path] or {}
            table.insert(self.hooks.notify[path], fn)
        end)
        set("LoopAsync", function(ms, fn)
            -- UE4SS's LoopAsync overload is LoopAsync(integer, fn); passing
            -- a float (e.g. an SN2ModSettings slider value * 1000) raises
            -- "No overload found". Reproduce it so tests catch float delays.
            if math.type(ms) ~= "integer" then
                error("No overload found for function 'LoopAsync' "
                    .. "(DelayInMilliseconds must be integer, got " .. tostring(ms) .. ")", 2)
            end
            table.insert(self.hooks.loops, { ms = ms, fn = fn })
        end)
        set("RegisterKeyBind", function() end)
        set("IsKeyBindRegistered", function() return false end)
        set("CreateInvalidObject", function() return { IsValid = function() return false end } end)
        set("Key", setmetatable({}, { __index = function() return 0 end }))
        set("ModifierKey", setmetatable({}, { __index = function() return 0 end }))
        set("ModRef", { GetSharedVariable = function() return nil end, SetSharedVariable = function() end })
        -- UEHelpers is require()'d at module-load by spawn_hook; route it
        -- to this env so GetWorld/GetPlayerController are env-specific.
        self._saved_uehelpers = package.loaded["UEHelpers"]
        package.loaded["UEHelpers"] = self.ue_helpers
        return self
    end
    function env:uninstall()
        for name, v in pairs(self.saved) do _G[name] = v end
        self.saved = {}
        package.loaded["UEHelpers"] = self._saved_uehelpers
    end
    return env
end

-- Re-require a module fresh (clears its module-level state between tests).
function M.fresh_require(name)
    package.loaded[name] = nil
    return require(name)
end

-- Bracket install/uninstall around fn so a thrown assertion can't leak
-- globals into the next test. Re-raises the error after cleanup.
function M.with_env(fn)
    local env = M.new()
    env:install()
    local ok, err = pcall(fn, env)
    env:uninstall()
    if not ok then error(err, 0) end
end

return M
