-- tools/probe.lua — item-grant discovery probe. RUN IN-GAME under UE4SS.
--
-- Why: sub2_random has no add-to-inventory cheat and Subnautica 2 ships no SDK
-- on disk — all types resolve at runtime via UE4SS reflection. This probe dumps
-- the candidates for a TRUE inventory insert so we can wire items.lua's
-- M.inventory_method:
--   * every UFunction whose signature mentions "inventory" or "cheatmanager"
--     (look for AddItem / GiveItem / GrantItem / AddToContainer / SpawnItem …),
--   * distinct classes whose name contains "Inventory",
--   * the player pawn's properties that look like an inventory reference,
--   * a sample of UUWEItemType assets (the DA_<Name>_ItemType ids).
--
-- How to run (any one):
--   * UE4SS Lua console:  dofile("ue4ss/Mods/Sub2Chaos/tools/probe.lua")
--   * or drop it where UE4SS auto-loads a Lua mod and launch the game.
-- Output: printed to UE4SS.log AND written to
--   <game>/Subnautica2/Binaries/Win64/ue4ss/Mods/Sub2Chaos/probe_output.txt
-- Share probe_output.txt back so items.lua can be wired to the real method.

local OUT_PATH = "./ue4ss/Mods/Sub2Chaos/probe_output.txt"
local MAX_PER_SECTION = 200

local lines = {}
local function emit(s)
	lines[#lines + 1] = s
	print("[Sub2Chaos.probe] " .. tostring(s))
end
local function header(t)
	emit("")
	emit("==== " .. t .. " ====")
end

local function safe(o, m, ...)
	if not o then return nil end
	local args = { ... }
	local ok, v = pcall(function() return o[m](o, table.unpack(args)) end)
	if ok then return v end
	return nil
end
local function fname(o)
	local f = safe(o, "GetFName")
	return f and safe(f, "ToString") or nil
end
local function full(o) return safe(o, "GetFullName") end

local function contains(s, needle)
	return type(s) == "string" and s:lower():find(needle, 1, true) ~= nil
end

local function run()
	emit("Sub2Chaos item-grant discovery probe")
	emit("(share probe_output.txt back to wire items.lua)")

	-- ── Single ForEachUObject sweep ──────────────────────────────────────
	local fn_inventory, fn_cheat = {}, {}
	local cls_inventory = {}
	local seen_cls = {}
	if type(ForEachUObject) == "function" then
		ForEachUObject(function(obj)
			local f = full(obj)
			if not f then return end
			-- UFunctions show up as objects: "Function /Script/Mod.Class:Method"
			if f:sub(1, 9) == "Function " then
				if contains(f, "inventory") then
					fn_inventory[#fn_inventory + 1] = f
				elseif contains(f, "cheatmanager") then
					fn_cheat[#fn_cheat + 1] = f
				end
				return
			end
			-- Instances whose CLASS name mentions inventory -> record the class.
			local cls = safe(obj, "GetClass")
			local cn = cls and fname(cls)
			if cn and contains(cn, "inventory") and not seen_cls[cn] then
				seen_cls[cn] = true
				cls_inventory[#cls_inventory + 1] = (safe(cls, "GetFullName") or cn)
			end
		end)
	else
		emit("!! ForEachUObject unavailable — are you running this in-game under UE4SS?")
	end

	header("Inventory-related UFunctions (look for AddItem/GiveItem/GrantItem/SpawnItem)")
	for i, f in ipairs(fn_inventory) do
		if i > MAX_PER_SECTION then emit("  … (" .. (#fn_inventory - MAX_PER_SECTION) .. " more)"); break end
		emit("  " .. f)
	end
	if #fn_inventory == 0 then emit("  (none found)") end

	header("SN2CheatManager UFunctions (look for a give/add/item cheat)")
	for i, f in ipairs(fn_cheat) do
		if i > MAX_PER_SECTION then emit("  … (" .. (#fn_cheat - MAX_PER_SECTION) .. " more)"); break end
		emit("  " .. f)
	end
	if #fn_cheat == 0 then emit("  (none found)") end

	header("Classes whose name contains 'Inventory'")
	for _, c in ipairs(cls_inventory) do emit("  " .. c) end
	if #cls_inventory == 0 then emit("  (none found)") end

	-- ── FindAllOf candidate inventory component classes ──────────────────
	header("FindAllOf candidate inventory classes (instance counts)")
	for _, short in ipairs({ "UWEInventory", "WEInventory", "InventoryComponent", "UWEInventoryComponent", "SN2Inventory" }) do
		local insts = nil
		if type(FindAllOf) == "function" then pcall(function() insts = FindAllOf(short) end) end
		local n = insts and #insts or 0
		emit(string.format("  FindAllOf(%q) -> %d", short, n))
		if insts and insts[1] then emit("    e.g. " .. tostring(full(insts[1]))) end
	end

	-- ── Player pawn: inventory-looking properties + components ───────────
	header("Player pawn inventory properties / components")
	local pc = (type(FindFirstOf) == "function") and FindFirstOf("PlayerController") or nil
	local pawn
	if pc then pcall(function() pawn = pc.Pawn end) end
	if pawn and safe(pawn, "IsValid") then
		emit("  pawn: " .. tostring(full(pawn)))
		local cls = safe(pawn, "GetClass")
		if cls then
			local ok = pcall(function()
				cls:ForEachProperty(function(prop)
					local pn = fname(prop)
					local pcls = safe(prop, "GetClass")
					local pt = pcls and fname(pcls) or "?"
					if pn and (contains(pn, "inventory") or contains(pn, "container") or contains(pt, "object")) then
						emit(string.format("    prop %s : %s", pn, pt))
					end
				end)
			end)
			if not ok then emit("    (ForEachProperty failed on pawn class)") end
		end
	else
		emit("  (no player pawn — load a save first, then re-run)")
	end

	-- ── Sample item-type assets ──────────────────────────────────────────
	header("Sample UUWEItemType / UWEItemType assets (the DA_<Name>_ItemType ids)")
	for _, short in ipairs({ "UWEItemType", "UUWEItemType" }) do
		local insts = nil
		if type(FindAllOf) == "function" then pcall(function() insts = FindAllOf(short) end) end
		local n = insts and #insts or 0
		emit(string.format("  FindAllOf(%q) -> %d", short, n))
		if insts then
			for i = 1, math.min(10, n) do emit("    " .. tostring(full(insts[i]))) end
		end
	end

	-- ── Write the report ─────────────────────────────────────────────────
	local body = table.concat(lines, "\n") .. "\n"
	local f, err = io.open(OUT_PATH, "w")
	if f then
		f:write(body)
		f:close()
		print("[Sub2Chaos.probe] wrote report to " .. OUT_PATH)
	else
		print("[Sub2Chaos.probe] could NOT write " .. OUT_PATH .. ": " .. tostring(err))
	end
end

local ok, err = pcall(run)
if not ok then print("[Sub2Chaos.probe] FAILED: " .. tostring(err)) end
