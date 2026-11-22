--[[
BH&G Kill List: Blacklist.lua

The guild Blacklist: players on our own side to keep out of groups
(people who leave dungeons early and the like). It's shared with the
guild like the kill list (Core.lua keeps it, Sync.lua sends it), but
it's a list of its own: it never warns "kill on sight" and the kill
list never looks at it.

Sides are worked out from your own character, so it works the same for
an Alliance or a Horde guild. Enemies can't go on it (they can't join
your group anyway; that's what the kill list is for), and neither can
guildmates.

A blacklisted player is pointed out when they
  * are in your group, or join it (banner, sound, line in chat),
  * invite you to a group (banner, sound, line in chat),
  * whisper you or talk in a chat channel such as LookingForGroup (a
    line in chat, at most every ten minutes per player).
Their tooltip shows it too.

When someone leaves your dungeon group, the addon offers to blacklist
them. The game doesn't say why someone left (or was removed), so this
only ever asks; nobody is added without you saying so. It waits a few
seconds first: if a second player leaves in that time the group is
breaking up (the end of a run), and it asks about no one.
--]]

local _, ns = ...
local Plain, PlainText = ns.Plain, ns.PlainText
local Call = ns.Call

local LEAVE_WAIT = 10        -- seconds after a leave before asking (a second leave in that time cancels)
local GROUP_COOLDOWN = 300   -- seconds before the same player in your group warns again
local INVITE_COOLDOWN = 30
local CHAT_COOLDOWN = 600

-----------------------------------------------------------------------
-- Who can go on it
-----------------------------------------------------------------------

-- Why info can't go on the Blacklist, or nil when it can.
local function WhyNot(info)
	if type(info) ~= "table" or type(info.name) ~= "string" then return "that isn't a player name." end
	local key = ns.Key(info.name, info.realm)
	local name = ns.ProperName(info.name)
	if key == ns.MyFullName():lower() then return "you can't put yourself on the Blacklist." end
	if ns.IsEnemy(info) then
		return name .. " is on the other side. The Blacklist is for players on ours; enemies go on the kill list."
	end
	if ns.IsGuildmate(key) then return name .. " is in our guild, so they can't go on the Blacklist." end
	return nil
end

-- Should the right-click menu offer the Blacklist for this player?
function ns.CanBlacklist(info)
	if type(info) ~= "table" or type(info.name) ~= "string" then return false end
	return ns.GetBlack(ns.Key(info.name, info.realm)) ~= nil or WhyNot(info) == nil
end

function ns.RefuseBlack(info)
	local why = WhyNot(info)
	if why then ns.Print(why) end
	return why ~= nil
end

function ns.AddBlackWithMessage(info, reason)
	if ns.RefuseBlack(info) then return end
	local e, isNew = ns.AddBlack(info, reason)
	if not e then
		ns.Print("couldn't add that player.")
		return
	end
	if isNew then
		if ns.Setting("sound") then ns.PlaySound("add") end
		ns.Print("put " .. ns.ColorName(e) .. " on the guild Blacklist" .. (e.w and (": " .. e.w) or "") .. ". Guild members with the addon get it too.")
	else
		ns.Print(ns.ColorName(e) .. " is on the guild Blacklist" .. (e.w and (": " .. e.w) or "") .. ".")
	end
	return e
end

function ns.RemoveBlackWithMessage(key)
	local e = ns.RemoveBlack(key)
	if e then
		if ns.Setting("sound") then ns.PlaySound("remove") end
		ns.Print("took " .. ns.ColorName(e) .. " off the guild Blacklist.")
	else
		ns.Print("that player isn't on the guild Blacklist.")
	end
end

-- A name as typed or as the game gives it ("Name", "Name-Realm",
-- "Name Realm", or inside a player link) -> the Blacklist key, and info.
local function FromName(text)
	text = PlainText(text)
	if not text then return nil end
	text = text:match("|h%[?(.-)%]?|h") or text
	local name, realm = ns.SplitName(text)
	if not name then return nil end
	return ns.Key(name, realm), { name = name, realm = realm }
end

-----------------------------------------------------------------------
-- Warnings
-----------------------------------------------------------------------

local lastWarn = {} -- key .. kind -> GetTime()

-- loud: banner, sound and flash as well as the line in chat.
local function Warn(e, how, kind, cooldown, loud)
	if not ns.Setting(kind == "chat" and "blackChat" or "blackWarn") then return end
	local id = ns.Key(e.n, e.r) .. "|" .. kind
	if lastWarn[id] and GetTime() - lastWarn[id] < cooldown then return end
	lastWarn[id] = GetTime()
	ns.Print("|cffff9900BLACKLISTED:|r " .. ns.ColorName(e) .. " " .. how .. (e.w and (" - " .. e.w) or "")
		.. " |cff999999(added by " .. ns.ShortSender(e.b) .. ")|r")
	if not loud then return end
	if ns.Setting("sound") and PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
		pcall(PlaySound, SOUNDKIT.RAID_WARNING, "Master")
	end
	if FlashClientIcon then pcall(FlashClientIcon) end
	if ns.Setting("banner") and ns.ShowBanner then ns.ShowBanner(e, nil, "BLACKLISTED", how) end
end

local function InGroup(key)
	local e = ns.GetBlack(key)
	if not e then return end
	e.gs = ns.Now() -- this PC only: when they were last in your group
	Warn(e, "is in your group", "group", GROUP_COOLDOWN, true)
	ns.Fire("LIST_CHANGED")
end

ns.On("PARTY_INVITE_REQUEST", function(inviter)
	local key = FromName(inviter)
	local e = key and ns.GetBlack(key)
	if e then Warn(e, "invited you to a group", "invite", INVITE_COOLDOWN, true) end
end)

local function OnChat(how)
	return function(_, sender, _, _, _, _, _, _, channelName)
		local key = FromName(sender)
		local e = key and ns.GetBlack(key)
		if not e then return end
		local channel = PlainText(channelName)
		Warn(e, how or ("is talking in " .. (channel or "a chat channel")), "chat", CHAT_COOLDOWN, false)
	end
end
ns.On("CHAT_MSG_WHISPER", OnChat("is whispering you"))
ns.On("CHAT_MSG_CHANNEL", OnChat(nil))

-----------------------------------------------------------------------
-- Your group: who joins, who leaves
-----------------------------------------------------------------------

local function InDungeon()
	if not IsInInstance then return false end
	local ok, inside, kind = pcall(IsInInstance)
	return ok and Plain(inside) and Plain(kind) == "party" or false
end

local function Zone()
	return PlainText(GetRealZoneText and GetRealZoneText()) or "a dungeon"
end

local pending, quietUntil = nil, 0

local function Left(key, info)
	if not ns.Setting("leavePrompt") or not InDungeon() then return end
	if ns.GetBlack(key) or ns.IsGuildmate(key) or key == ns.MyFullName():lower() then return end
	if pending and pending.key == key then return end -- the same leave, heard twice
	local now = GetTime()
	if pending or now < quietUntil then
		pending, quietUntil = nil, now + LEAVE_WAIT
		return
	end
	local mine = { key = key, info = info, zone = Zone() }
	pending = mine
	C_Timer.After(LEAVE_WAIT, function()
		if pending ~= mine then return end
		pending = nil
		if not InDungeon() or (Call(GetNumGroupMembers) or 0) < 2 then return end
		if ns.GetBlack(key) then return end
		ns.AskBlackLeaver(mine.info, "Left " .. mine.zone .. " early")
	end)
end

-- Everyone in the group but me, by key, and whether anyone couldn't be
-- read (names can be hidden from addons in instances).
local function ReadGroup()
	local members, unreadable = {}, false
	local count = Call(GetNumGroupMembers) or 0
	if count == 0 then return members, false, 0 end
	local raid = Call(IsInRaid)
	local last, prefix = math.min(count - 1, 4), "party"
	if raid then last, prefix = math.min(count, 40), "raid" end
	local me = ns.MyFullName():lower()
	for i = 1, last do
		local unit = prefix .. i
		local name, realm = Call(UnitName, unit)
		if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT and name ~= UNKNOWN then
			if type(realm) ~= "string" or realm == "" then realm = nil end
			local key = ns.Key(name, realm)
			if key ~= me then
				local _, class = Call(UnitClass, unit)
				members[key] = { name = name, realm = realm or ns.MyRealm(), class = class, guild = Call(GetGuildInfo, unit), ally = true }
			end
		else
			unreadable = true
		end
	end
	return members, unreadable, count
end

local roster = {} -- key -> info: the group as last read

ns.On("GROUP_ROSTER_UPDATE", function()
	local members, unreadable, count = ReadGroup()
	if count == 0 then
		roster = {}
		return
	end
	for key in pairs(members) do
		if not roster[key] then InGroup(key) end
	end
	if unreadable then
		-- Can't tell who left; the game's "leaves the party" line still says.
		for key, info in pairs(members) do roster[key] = info end
		return
	end
	local gone = {}
	for key, info in pairs(roster) do
		if not members[key] then gone[key] = info end
	end
	roster = members
	for key, info in pairs(gone) do Left(key, info) end
end)

-- "%s leaves the party." -> a pattern that captures the name.
local function Pattern(fmt, fallback)
	fmt = type(fmt) == "string" and fmt or fallback
	local escaped = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	return "^" .. escaped:gsub("%%%%s", "(.+)") .. "$"
end

local JOINED = {
	Pattern(_G.ERR_JOINED_GROUP_S, "%s joins the party."),
	Pattern(_G.ERR_RAID_MEMBER_ADDED_S, "%s has joined the raid group."),
}
local LEFT = Pattern(_G.ERR_LEFT_GROUP_S, "%s leaves the party.")

ns.On("CHAT_MSG_SYSTEM", function(text)
	text = PlainText(text)
	if not text then return end
	for _, pattern in ipairs(JOINED) do
		local key = FromName(text:match(pattern))
		if key then InGroup(key) return end
	end
	local key, info = FromName(text:match(LEFT))
	if key then Left(key, info) end
end)

-----------------------------------------------------------------------
-- The guild's changes, in chat
-----------------------------------------------------------------------

local caughtUp = 0
ns.Listen("BLACK_ADDED_BY_GUILD", function(_, e)
	if ns.syncQuiet then
		caughtUp = caughtUp + 1
		return
	end
	ns.Print(ns.ColorName(e) .. " was put on the guild Blacklist by " .. ns.ShortSender(e.b) .. (e.w and (": " .. e.w) or "."))
end)
ns.Listen("BLACK_REMOVED_BY_GUILD", function(_, e)
	if ns.syncQuiet then return end
	ns.Print(ns.ColorName(e) .. " was taken off the guild Blacklist by " .. ns.ShortSender(e.y) .. ".")
end)
ns.Listen("SYNC_SETTLED", function()
	if caughtUp > 0 then
		ns.Print("caught up with the guild: " .. caughtUp .. " player" .. (caughtUp == 1 and "" or "s")
			.. " added to your Blacklist (" .. ns.BlackCount() .. " in all).")
		caughtUp = 0
	end
end)
