--[[
BH&G Kill List: Detect.lua

Spotting enemy players, the way Spy does: from nameplates, your target,
focus and mouseover (and the combat log, on a client that lets addons
read it; Forever currently doesn't). Every enemy player seen lands in the
nearby list for a minute; a player on the kill list also sets off the
warning and, if sharing is on, tells the guild where they were seen.

Also adds the list to unit tooltips and to the right-click menu on
players.
--]]

local _, ns = ...
local Plain, PlainText = ns.Plain, ns.PlainText

ns.nearby = {}       -- key -> { name, realm, class, level, guild, race, hostile, seen (GetTime) }
local lastAlert = {}  -- key -> GetTime()
local lastShared = {} -- key -> GetTime()
local lastGuildNote = {} -- key -> GetTime()

-- The Star Trek alerts from Spy.
local SOUNDS = {
	kos = "detected-kos.mp3",         -- someone on the list, near you
	kosaway = "detected-kosaway.mp3", -- someone on the list, spotted by a guildmate
	nearby = "detected-nearby.mp3",   -- any new enemy player nearby
	add = "list-add.mp3",
	remove = "list-remove.mp3",
}
function ns.PlaySound(which)
	local file = SOUNDS[which]
	if not file or not PlaySoundFile then return end
	pcall(PlaySoundFile, ns.SOUND_DIR .. file, "Master")
end

local SHARE_COOLDOWN = 60
local GUILD_NOTE_COOLDOWN = 30

-----------------------------------------------------------------------
-- Reading a unit (everything secret-safe; secret = unknown = skip)
-----------------------------------------------------------------------

local function Call(fn, ...)
	if not fn then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if not ok then return nil end
	return Plain(a), Plain(b), Plain(c)
end

function ns.ReadUnit(unit)
	if not Call(UnitExists, unit) then return nil end
	local isPlayer = Call(UnitIsPlayer, unit)
	if isPlayer == false then return nil end
	if Call(UnitIsUnit, unit, "player") then return nil end
	local name, realm = Call(UnitName, unit)
	-- Not readable yet (a plate that just appeared): the second result
	-- asks the caller to look again.
	if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT or name == UNKNOWN then return nil, true end
	if not isPlayer then return nil, true end
	if type(realm) ~= "string" or realm == "" then realm = nil end
	local _, classFile = Call(UnitClass, unit)
	local level = Call(UnitLevel, unit)
	local race = Call(UnitRace, unit)
	local guild = Call(GetGuildInfo, unit)
	local dead = Call(UnitIsDeadOrGhost, unit)
	local hostile = Call(UnitIsEnemy, "player", unit)
	if hostile == nil then hostile = Call(UnitCanAttack, "player", unit) end
	local theirFaction = Call(UnitFactionGroup, unit)
	local myFaction = Call(UnitFactionGroup, "player")
	if theirFaction and myFaction and theirFaction ~= myFaction and theirFaction ~= "Neutral" then hostile = true end
	return {
		name = name,
		realm = realm or ns.MyRealm(),
		class = type(classFile) == "string" and classFile or nil,
		level = type(level) == "number" and level or nil,
		race = type(race) == "string" and race or nil,
		guild = type(guild) == "string" and guild ~= "" and guild or nil,
		hostile = hostile and true or false,
		dead = dead and true or false,
		unit = unit,
	}
end

-----------------------------------------------------------------------
-- Where am I
-----------------------------------------------------------------------

function ns.WhereAmI()
	local zone = PlainText(GetRealZoneText and GetRealZoneText()) or PlainText(GetZoneText and GetZoneText()) or ""
	local sub = PlainText(GetSubZoneText and GetSubZoneText())
	local text = zone
	if sub and sub ~= zone then text = sub .. ", " .. zone end
	if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
		local ok, pos = pcall(function()
			local mapID = Plain(C_Map.GetBestMapForUnit("player"))
			if not mapID then return nil end
			local p = C_Map.GetPlayerMapPosition(mapID, "player")
			if not p then return nil end
			local x, y = p:GetXY()
			x, y = Plain(x), Plain(y)
			if type(x) == "number" and type(y) == "number" and (x > 0 or y > 0) then
				return string.format(" (%.0f, %.0f)", x * 100, y * 100)
			end
		end)
		if ok and pos then text = text .. pos end
	end
	return text
end

-----------------------------------------------------------------------
-- A sighting
-----------------------------------------------------------------------

function ns.Alert(e, info, test)
	local key = ns.Key(e.n, e.r)
	local now = GetTime()
	if not test and lastAlert[key] and now - lastAlert[key] < (ns.Setting("alertCooldown") or 60) then return end
	lastAlert[key] = now
	local level = (info and info.level) or e.lv
	local levelText = (level and level > 0) and (" (" .. level .. ")") or ""
	if ns.Setting("chat") then
		local why = e.w and (" - " .. e.w) or ""
		ns.Print("|cffff2020KILL ON SIGHT:|r " .. ns.ColorName(e) .. levelText .. why .. " |cff999999(added by " .. ns.ShortSender(e.b) .. ")|r")
	end
	if ns.Setting("sound") then ns.PlaySound("kos") end
	if FlashClientIcon then pcall(FlashClientIcon) end
	if ns.Setting("banner") and ns.ShowBanner then ns.ShowBanner(e, level) end
end

local lastNearbySound = 0
local WHERE_EVERY = 5 -- seconds between "last seen at" updates for a player in view

local function Seen(info, fromCombatLog)
	local key = ns.Key(info.name, info.realm)
	local e = ns.Get(key)
	if not e and not info.hostile then return end

	local n = ns.nearby[key]
	local isNewcomer = not n
	if not n then
		n = {}
		ns.nearby[key] = n
		n.first = GetTime()
		ns.nearbyDirty = true
	end
	if ns.RecordEnemy then ns.RecordEnemy(info, isNewcomer) end
	if isNewcomer and not e and info.hostile and not info.dead and ns.Setting("nearbySound")
		and GetTime() - lastNearbySound > 2 then
		lastNearbySound = GetTime()
		ns.PlaySound("nearby")
	end
	n.name, n.realm = ns.ProperName(info.name), info.realm
	n.class = info.class or n.class
	n.level = info.level or n.level
	n.guild = info.guild or n.guild
	n.race = info.race or n.race
	n.hostile = info.hostile or n.hostile
	n.seen = GetTime()

	if not e then return end
	-- Things only this PC keeps.
	e.lv = info.level or e.lv
	e.race = info.race or e.race
	local fresh = not n.whereAt or GetTime() - n.whereAt > WHERE_EVERY
	if fresh then
		n.whereAt = GetTime()
		n.where = ns.WhereAmI()
		e.seen, e.sz, e.sb = ns.Now(), n.where, ns.MyName()
	end
	if not fromCombatLog then ns.LearnDetails(key, info.class, info.guild) end
	e = ns.Get(key) or e

	if info.dead then return end
	ns.Alert(e, info)
	if ns.Setting("shareSightings") and (not lastShared[key] or GetTime() - lastShared[key] > SHARE_COOLDOWN) then
		lastShared[key] = GetTime()
		if ns.SendSighting then ns.SendSighting(e, n.where or ns.WhereAmI()) end
	end
	if fresh then ns.Fire("SEEN", key) end
end

function ns.CheckUnit(unit)
	local info, retry = ns.ReadUnit(unit)
	if info then Seen(info) end
	return info, retry
end

-- What a nearby row needs to show for key.
function ns.NearbyList()
	local list, now, keep = {}, GetTime(), ns.Setting("nearbyTime") or 60
	for key, n in pairs(ns.nearby) do
		if now - n.seen > keep then
			ns.nearby[key] = nil
			ns.nearbyDirty = true
		else
			local e = ns.Get(key)
			if e or ns.Setting("nearbyAll") then
				list[#list + 1] = { key = key, n = n, e = e }
			end
		end
	end
	table.sort(list, function(a, b)
		if (a.e ~= nil) ~= (b.e ~= nil) then return a.e ~= nil end
		return a.n.seen > b.n.seen
	end)
	return list
end

-----------------------------------------------------------------------
-- Watching
-----------------------------------------------------------------------

-- A plate whose name can't be read the moment it appears is read again
-- every frame (for up to 3 seconds) instead of waiting for the next scan.
local pending = {} -- plate unit -> GetTime() it appeared
local pendingFrame = CreateFrame("Frame")
pendingFrame:Hide()
pendingFrame:SetScript("OnUpdate", ns.Guarded("plates", function(self)
	local now, any = GetTime(), false
	for unit, t in pairs(pending) do
		local info, retry = ns.CheckUnit(unit)
		if info or not retry or now - t > 3 then
			pending[unit] = nil
		else
			any = true
		end
	end
	if not any then self:Hide() end
end))

ns.On("NAME_PLATE_UNIT_ADDED", function(unit)
	local info, retry = ns.CheckUnit(unit)
	if not info and retry and type(unit) == "string" then
		pending[unit] = GetTime()
		pendingFrame:Show()
	end
end)
ns.On("NAME_PLATE_UNIT_REMOVED", function(unit) pending[unit] = nil end)
ns.On("PLAYER_TARGET_CHANGED", function() ns.CheckUnit("target") end)
ns.On("PLAYER_FOCUS_CHANGED", function() ns.CheckUnit("focus") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() ns.CheckUnit("mouseover") end)

-- Names can be secret when a plate first appears, and nameplates only
-- send one "added" event, so the plates and the player's own units are
-- read again five times a second; group members' targets once a second.
-- Re-reading also keeps players who are still around in the nearby list.
local QUICK_UNITS = { "target", "mouseover", "focus", "softenemy", "targettarget" }
local SCAN_EVERY = 0.2

local function ScanPlates()
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
	local ok, plates = pcall(C_NamePlate.GetNamePlates)
	if not ok or type(plates) ~= "table" then return end
	for _, plate in ipairs(plates) do
		local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
		unit = Plain(unit)
		if type(unit) == "string" then ns.CheckUnit(unit) end
	end
end

local function ScanGroupTargets()
	local raid = Plain(IsInRaid and IsInRaid())
	local count = Plain(GetNumGroupMembers and GetNumGroupMembers()) or 0
	if raid then
		for i = 1, math.min(count, 40) do ns.CheckUnit("raid" .. i .. "target") end
	else
		for i = 1, math.min(count, 4) do ns.CheckUnit("party" .. i .. "target") end
	end
	ns.CheckUnit("pettarget")
end

local scanTicker
ns.Listen("DB_READY", function()
	if scanTicker or not C_Timer then return end
	local slow = 0
	scanTicker = C_Timer.NewTicker(SCAN_EVERY, ns.Guarded("scan", function()
		ScanPlates()
		for _, unit in ipairs(QUICK_UNITS) do ns.CheckUnit(unit) end
		slow = slow + SCAN_EVERY
		if slow >= 1 then
			slow = 0
			ScanGroupTargets()
			ns.Fire("TICK")
		end
	end))
end)

-- Nameplates are the quickest way to spot someone (as soon as they're in
-- range, no hovering needed), but only when enemy nameplates are on.
function ns.EnemyPlatesOn()
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	if not get then return nil end
	local ok, v = pcall(get, "nameplateShowEnemies")
	if not ok then return nil end
	return v == "1"
end

local function GetCV(name)
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	if not get then return nil end
	local ok, v = pcall(get, name)
	if ok then return Plain(v) end
end

local function SetCV(name, value)
	local set = (C_CVar and C_CVar.SetCVar) or SetCVar
	if set then pcall(set, name, value) end
end

-- How far away nameplates appear, in yards (nil if the client won't say).
function ns.PlateRange()
	return tonumber(GetCV("nameplateMaxDistance"))
end

-- Nameplates appear only within nameplateMaxDistance, and past that an
-- addon can't see a player until you hover or target them. With "far
-- plates" on, ask for 100 yards; the game lowers it to the most it allows.
-- The player's own value is kept and put back when the option is turned off.
local FAR = "100"
function ns.ApplyPlateRange()
	if not ns.db then return end
	if InCombatLockdown() then
		ns.plateRangePending = true
		return
	end
	ns.plateRangePending = nil
	local now = GetCV("nameplateMaxDistance")
	if now == nil then return end
	if ns.Setting("farPlates") then
		if ns.db.plateRangeWas == nil then ns.db.plateRangeWas = now end
		if now ~= FAR then SetCV("nameplateMaxDistance", FAR) end
	elseif ns.db.plateRangeWas ~= nil then
		SetCV("nameplateMaxDistance", ns.db.plateRangeWas)
		ns.db.plateRangeWas = nil
	end
end

ns.On("PLAYER_ENTERING_WORLD", function() ns.ApplyPlateRange() end)
ns.On("PLAYER_REGEN_ENABLED", function()
	if ns.plateRangePending then ns.ApplyPlateRange() end
end)
ns.Listen("SETTINGS_CHANGED", function(k)
	if k == "farPlates" then ns.ApplyPlateRange() end
end)

function ns.TurnOnEnemyPlates()
	if InCombatLockdown() then
		ns.Print("can't change nameplates in combat; try again after.")
		return
	end
	SetCV("nameplateShowEnemies", "1")
	if ns.Setting("farPlates") then ns.ApplyPlateRange() end
	local range = ns.PlateRange()
	ns.Print(ns.EnemyPlatesOn() and ("enemy nameplates are on: enemies are spotted as soon as they're in range"
		.. (range and (" (" .. range .. " yards)") or "") .. ".") or "couldn't turn enemy nameplates on.")
end

ns.On("PLAYER_ENTERING_WORLD", function()
	if ns.platesTipShown or not C_Timer then return end
	ns.platesTipShown = true
	C_Timer.After(12, function()
		if ns.EnemyPlatesOn() == false then
			ns.Print("enemy nameplates are off, so enemies are only spotted when you target or mouse over them. Type |cffffd200/kos plates|r to turn them on and spot them as soon as they're in range.")
		end
	end)
end)

-- The combat log, where the client allows reading it.
if CombatLogGetCurrentEventInfo then
	local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x400
	local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
	local band = bit and bit.band
	local function FromLog(name, flags)
		name, flags = Plain(name), Plain(flags)
		if type(name) ~= "string" or type(flags) ~= "number" or not band then return end
		if band(flags, TYPE_PLAYER) == 0 or band(flags, HOSTILE) == 0 then return end
		local n, realm = ns.SplitName(name)
		if not n then return end
		Seen({ name = n, realm = realm, hostile = true }, true)
	end
	ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
		local _, _, _, _, srcName, srcFlags, _, _, dstName, dstFlags = CombatLogGetCurrentEventInfo()
		FromLog(srcName, srcFlags)
		FromLog(dstName, dstFlags)
	end)
end

-----------------------------------------------------------------------
-- The guild's sightings and changes, in chat
-----------------------------------------------------------------------

ns.Listen("GUILD_SIGHTING", function(key, zone, sender)
	local e = ns.Get(key)
	if not e then return end
	e.seen, e.sz, e.sb = ns.Now(), zone, ns.ShortSender(sender)
	if not ns.Setting("guildSightings") then return end
	if lastGuildNote[key] and GetTime() - lastGuildNote[key] < GUILD_NOTE_COOLDOWN then return end
	lastGuildNote[key] = GetTime()
	local where = (zone and zone ~= "") and (" in " .. zone) or ""
	ns.Print(ns.ColorName(e) .. " spotted by " .. ns.ShortSender(sender) .. where .. ".")
	if ns.Setting("sound") then ns.PlaySound("kosaway") end
	ns.Fire("SEEN", key)
end)

-- One line per player added live; a catch-up after login is summed up
-- in one line instead.
local caughtUp = 0
ns.Listen("ADDED_BY_GUILD", function(_, e)
	if ns.syncQuiet then
		caughtUp = caughtUp + 1
		return
	end
	ns.Print(ns.ColorName(e) .. " was added by " .. ns.ShortSender(e.b) .. (e.w and (": " .. e.w) or "."))
end)
ns.Listen("SYNC_SETTLED", function()
	if caughtUp > 0 then
		ns.Print("caught up with the guild: " .. caughtUp .. " player" .. (caughtUp == 1 and "" or "s") .. " added to your list (" .. ns.Count() .. " in all).")
		caughtUp = 0
	end
end)

-----------------------------------------------------------------------
-- Tooltips
-----------------------------------------------------------------------

local function OnUnitTooltip(tooltip)
	if not ns.active then return end
	if tooltip ~= GameTooltip or not tooltip.GetUnit then return end
	local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
	unit = ok and Plain(unit) or nil
	if type(unit) ~= "string" then return end
	local info = ns.ReadUnit(unit)
	if not info then return end
	local key = ns.Key(info.name, info.realm)
	local e = ns.Get(key)
	if e then
		tooltip:AddLine("Kill on sight" .. (e.w and (": " .. e.w) or ""), 1, 0.15, 0.15, true)
		tooltip:AddLine("BH&G Kill List, added by " .. ns.ShortSender(e.b), 0.6, 0.6, 0.6)
	end
	local rec = ns.Enemy and ns.Enemy(key)
	if rec and (e or info.hostile) and ((rec.w or 0) + (rec.l or 0)) > 0 then
		tooltip:AddLine("Your record: " .. ns.Score(rec), 1, 1, 1)
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, ns.Guarded("tooltip", OnUnitTooltip))
elseif GameTooltip and GameTooltip.HookScript then
	GameTooltip:HookScript("OnTooltipSetUnit", ns.Guarded("tooltip", OnUnitTooltip))
end

-----------------------------------------------------------------------
-- Right-click menu on players
-----------------------------------------------------------------------

local MENUS = {
	"MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
	"MENU_UNIT_FRIEND", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_CHAT_ROSTER",
	"MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
}

local function MenuTarget(contextData)
	if type(contextData) ~= "table" then return nil end
	local unit = PlainText(contextData.unit)
	if unit then
		if Call(UnitIsUnit, unit, "player") then return nil end
		local info = ns.ReadUnit(unit)
		if info then return info end
	end
	local n, realm = ns.SplitName(PlainText(contextData.name))
	if not n then return nil end
	local server = PlainText(contextData.server)
	if server then realm = server:gsub("[%s%-]", "") end
	if ns.Key(n, realm) == ns.MyFullName():lower() then return nil end
	return { name = n, realm = realm }
end

local function AddMenuButton(_, rootDescription, contextData)
	if not rootDescription or not ns.active then return end
	local info = MenuTarget(contextData)
	if not info then return end
	local key = ns.Key(info.name, info.realm)
	rootDescription:CreateDivider()
	if ns.Get(key) then
		rootDescription:CreateButton("|cffe03c3cRemove from BH&G Kill List|r", function()
			ns.RemoveWithMessage(key)
		end)
	else
		rootDescription:CreateButton("|cffe03c3cAdd to BH&G Kill List|r", function()
			ns.AskReason(info)
		end)
	end
end

if Menu and Menu.ModifyMenu then
	for _, tag in ipairs(MENUS) do
		pcall(Menu.ModifyMenu, tag, ns.Guarded("menu", AddMenuButton))
	end
end

-----------------------------------------------------------------------
-- Adding and removing with feedback (used by the menu, buttons, commands)
-----------------------------------------------------------------------

function ns.AddWithMessage(info, reason)
	local e, isNew = ns.Add(info, reason)
	if not e then
		ns.Print("couldn't add that player.")
		return
	end
	if isNew then
		if ns.Setting("sound") then ns.PlaySound("add") end
		ns.Print("added " .. ns.ColorName(e) .. (e.w and (": " .. e.w) or "") .. ". Guild members with the addon get it too.")
	else
		ns.Print(ns.ColorName(e) .. " is on the list" .. (e.w and (": " .. e.w) or "") .. ".")
	end
	return e
end

function ns.RemoveWithMessage(key)
	local e = ns.Remove(key)
	if e then
		if ns.Setting("sound") then ns.PlaySound("remove") end
		ns.Print("removed " .. ns.ColorName(e) .. " from the list.")
	else
		ns.Print("that player isn't on the list.")
	end
end

function ns.TargetInfo()
	return ns.ReadUnit("target")
end
