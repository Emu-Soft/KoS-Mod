--[[
BH&G Kill List: Core.lua

The list itself: saved data, names and keys, adding and removing players,
and the merge rule every copy of the list follows so that all guild
members end up with the same list (Sync.lua does the talking).

Each entry is keyed by "name-realm" in lower case. Removing a player keeps
a small "removed" marker instead of deleting the entry, so the removal
spreads to guildmates who were offline at the time instead of the player
coming back from their copy.

Two homes. The same code runs as the standalone BH&G Kill List addon and
as the KoS module inside K-UI: Forever (built from these files into
KoS.lua). Whoever builds it can set ns.embedded, ns.DB_NAME,
ns.SOUND_DIR, ns.FRAME_PREFIX and ns.POPUP_PREFIX before this file runs.
When both are installed, K-UI is in charge: the standalone addon sees
K-UI's KoS module running at login and stays asleep (no events, no
windows, no messages), and K-UI takes over its list and records. If
K-UI's module is turned off (/kos off), the standalone addon runs as
usual. Both speak the same guild protocol, so guild members on either
one share one list.

Forever notes (same as K-Targeter in Kain-UI Forever):
  * Names, flags and GUIDs read from units can be SECRET values in
    restricted situations (mostly instances and some combat). A secret
    can't be compared, indexed or joined, so every unit read goes through
    Plain() and a secret simply counts as "unknown".
  * The client stops showing Lua errors after 100 per session, so every
    event handler runs through Guarded().
--]]

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.DB_NAME = ns.DB_NAME or "BHGKillListDB"
ns.SOUND_DIR = ns.SOUND_DIR or ("Interface\\AddOns\\" .. ADDON_NAME .. "\\Sounds\\")
ns.FRAME_PREFIX = ns.FRAME_PREFIX or "BHGKillList"
ns.POPUP_PREFIX = ns.POPUP_PREFIX or "BHGKOS_"
ns.active = false -- true once this copy is the one running
ns.TITLE = "BH&G Kill List"
ns.PREFIX = "|cffe03c3cBH&G Kill List:|r "
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
	or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or "?"

-----------------------------------------------------------------------
-- Secret-value and error-containment helpers
-----------------------------------------------------------------------

local function IsSecret(v)
	if issecretvalue and issecretvalue(v) then return true end
	if type(v) == "table" and issecrettable and issecrettable(v) then return true end
	return false
end

-- v, or nil when v is secret.
function ns.Plain(v)
	if IsSecret(v) then return nil end
	return v
end
local Plain = ns.Plain

-- A plain, non-empty string or nil.
function ns.PlainText(v)
	v = Plain(v)
	if type(v) == "string" and v ~= "" then return v end
	return nil
end

ns.errorCounts = {}
function ns.Guarded(label, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			local n = (ns.errorCounts[label] or 0) + 1
			ns.errorCounts[label] = n
			if n == 1 then
				print(ns.PREFIX .. "'" .. label .. "' hit an error (further ones are counted, not printed): " .. tostring(err))
			end
		end
	end
end

function ns.Print(msg)
	print(ns.PREFIX .. msg)
end

-- Cut a string to at most n bytes without splitting a UTF-8 letter.
function ns.CutText(s, n)
	if type(s) ~= "string" or #s <= n then return s end
	s = s:sub(1, n)
	local i = #s
	while i > 0 do
		local b = s:byte(i)
		if b < 128 then break end
		if b >= 192 then
			local need = (b >= 240 and 4) or (b >= 224 and 3) or 2
			if #s - i + 1 < need then s = s:sub(1, i - 1) end
			break
		end
		i = i - 1
	end
	return s
end

-- Text that goes into the shared list: no separators the sync uses, no
-- chat escape codes, no line breaks, trimmed and capped.
function ns.Clean(s, maxBytes)
	if type(s) ~= "string" then return nil end
	s = s:gsub("[~%^|%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	s = ns.CutText(s, maxBytes or 80)
	if s == "" then return nil end
	return s
end

function ns.Now()
	return (GetServerTime and GetServerTime()) or time()
end

-----------------------------------------------------------------------
-- Names and keys
-----------------------------------------------------------------------

local function StripRealm(realm)
	if type(realm) ~= "string" then return nil end
	realm = realm:gsub("[%s%-]", "")
	if realm == "" then return nil end
	return realm
end

function ns.MyRealm()
	local r = Plain(GetNormalizedRealmName and GetNormalizedRealmName())
	r = StripRealm(r)
	if not r then r = StripRealm(Plain(GetRealmName and GetRealmName())) end
	return r or "Unknown"
end

function ns.MyName()
	local n = ns.PlainText(UnitName("player"))
	return n or "Unknown"
end

function ns.MyFullName()
	return ns.MyName() .. "-" .. ns.MyRealm()
end

-- "bob" -> "Bob" (first letter up, rest down; letters beyond plain ASCII
-- are left as typed, which matches how the game spells them anyway).
function ns.ProperName(name)
	if type(name) ~= "string" or name == "" then return name end
	local first, rest = name:sub(1, 1), name:sub(2)
	if first:byte() < 128 then
		return first:upper() .. rest:lower()
	end
	return name
end

-- "Name-Realm" or "Name" -> name, realm (realm defaults to ours).
function ns.SplitName(full)
	if type(full) ~= "string" then return nil end
	full = full:gsub("^%s+", ""):gsub("%s+$", "")
	local name, realm = full:match("^([^%-]+)%-(.+)$")
	if not name then name = full end
	name = ns.Clean(name, 48)
	if not name or name:find(" ") then return nil end
	return ns.ProperName(name), StripRealm(realm) or ns.MyRealm()
end

function ns.Key(name, realm)
	return (name .. "-" .. (StripRealm(realm) or ns.MyRealm())):lower()
end

-- How a player is shown: "Name" for our realm, "Name-Realm" otherwise.
function ns.DisplayName(e)
	if not e then return "?" end
	if e.r and e.r:lower() ~= ns.MyRealm():lower() then
		return e.n .. "-" .. e.r
	end
	return e.n
end

-- What /targetexact needs.
function ns.TargetName(e)
	return ns.DisplayName(e)
end

function ns.ClassColor(classFile)
	local c = classFile and ((CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[classFile]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]))
	if c then return c.r, c.g, c.b end
	return 0.85, 0.85, 0.85
end

function ns.ColorName(e)
	local r, g, b = ns.ClassColor(e and e.c)
	return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, ns.DisplayName(e))
end

function ns.ShortSender(sender)
	if type(sender) ~= "string" then return "?" end
	local name, realm = sender:match("^([^%-]+)%-(.+)$")
	if name and StripRealm(realm) and StripRealm(realm):lower() == ns.MyRealm():lower() then return name end
	return sender
end

function ns.Ago(t)
	if not t then return "never" end
	local d = ns.Now() - t
	if d < 0 then d = 0 end
	if d < 60 then return "just now" end
	if d < 3600 then return math.floor(d / 60) .. "m ago" end
	if d < 86400 then return math.floor(d / 3600) .. "h ago" end
	return math.floor(d / 86400) .. "d ago"
end

-----------------------------------------------------------------------
-- Saved data
-----------------------------------------------------------------------

ns.DEFAULTS = {
	sound = true,          -- play a warning when a listed player shows up
	nearbySound = true,    -- play a sound for every new enemy player nearby
	banner = true,         -- big on-screen warning
	chat = true,           -- line in chat
	shareSightings = true, -- tell the guild when you spot a listed player
	guildSightings = true, -- show the guild's sightings in your chat
	nearby = true,         -- show the nearby enemies window
	nearbyAll = true,      -- list every enemy player nearby, not only listed ones
	nearbyTime = 60,       -- seconds an enemy stays in the nearby window
	alertCooldown = 60,    -- seconds before the same player warns again
}

function ns.InitDB()
	if type(_G[ns.DB_NAME]) ~= "table" then _G[ns.DB_NAME] = {} end
	local db = _G[ns.DB_NAME]
	ns.loadedWithData = type(db.entries) == "table" and next(db.entries) ~= nil
	if type(db.entries) ~= "table" then db.entries = {} end
	if type(db.settings) ~= "table" then db.settings = {} end
	if type(db.pos) ~= "table" then db.pos = {} end
	for k, v in pairs(ns.DEFAULTS) do
		if db.settings[k] == nil then db.settings[k] = v end
	end
	db.schema = 1
	ns.db = db
	-- Drop anything that doesn't look like an entry (hand edits, old data).
	for key, e in pairs(db.entries) do
		if type(e) ~= "table" or type(e.n) ~= "string" or type(e.t) ~= "number" then
			db.entries[key] = nil
		end
	end
	ns.InvalidateHashes()
end

function ns.Setting(k)
	local s = ns.db and ns.db.settings
	if s and s[k] ~= nil then return s[k] end
	return ns.DEFAULTS[k]
end

function ns.SetSetting(k, v)
	ns.db.settings[k] = v
	ns.Fire("SETTINGS_CHANGED", k, v)
end

-----------------------------------------------------------------------
-- Tiny internal event bus (UI listens to list changes this way)
-----------------------------------------------------------------------

local listeners = {}
function ns.Listen(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
	for _, fn in ipairs(listeners[name] or {}) do
		local ok, err = pcall(fn, ...)
		if not ok then
			ns.errorCounts["listener " .. name] = (ns.errorCounts["listener " .. name] or 0) + 1
			if ns.errorCounts["listener " .. name] == 1 then ns.Print("error in " .. name .. ": " .. tostring(err)) end
		end
	end
end

-----------------------------------------------------------------------
-- Wire format and the merge rule
--
-- Shared fields, in order: n name, r realm, c class file, g guild,
-- w reason, b added by, a added at, t changed at, x removed ("1"),
-- y removed by. Numbers in base 36 to keep messages short. Everything
-- else on an entry (level, race, last seen...) stays on this PC.
-----------------------------------------------------------------------

local SHARED = { "n", "r", "c", "g", "w", "b", "a", "t", "x", "y" }
local NUMERIC = { a = true, t = true }
ns.SHARED_FIELDS = SHARED

local function ToB36(n)
	n = math.floor(tonumber(n) or 0)
	if n <= 0 then return "0" end
	local digits, s = "0123456789abcdefghijklmnopqrstuvwxyz", ""
	while n > 0 do
		local d = n % 36
		s = digits:sub(d + 1, d + 1) .. s
		n = (n - d) / 36
	end
	return s
end
ns.ToB36 = ToB36

function ns.Serialize(e)
	local parts = {}
	for i, f in ipairs(SHARED) do
		local v = e[f]
		if NUMERIC[f] then
			parts[i] = ToB36(v)
		elseif f == "x" then
			parts[i] = v and "1" or ""
		else
			parts[i] = v or ""
		end
	end
	return table.concat(parts, "~")
end

local LIMITS = { n = 48, r = 64, c = 20, g = 64, w = 80, b = 80, y = 80 }

-- Returns an entry table or nil when the text isn't a valid entry.
function ns.Deserialize(s)
	if type(s) ~= "string" then return nil end
	local parts, i = {}, 1
	for field in (s .. "~"):gmatch("([^~]*)~") do
		parts[i] = field
		i = i + 1
	end
	if #parts ~= #SHARED then return nil end
	local e = {}
	for idx, f in ipairs(SHARED) do
		local v = parts[idx]
		if NUMERIC[f] then
			e[f] = tonumber(v, 36)
			if not e[f] then return nil end
		elseif f == "x" then
			e[f] = (v == "1") or nil
		elseif v ~= "" then
			if #v > LIMITS[f] then return nil end
			e[f] = v
		end
	end
	if not e.n or not e.r or e.n:find("[%s~%^|]") then return nil end
	-- A change stamped more than a day in the future is a broken clock;
	-- accepting it would make that version impossible to change.
	if e.t > ns.Now() + 86400 then return nil end
	return e
end

-- Is a newer than b? Later change wins; a tie is broken the same way on
-- every PC (by the shared text), so everyone settles on the same version.
function ns.IsNewer(a, b)
	if not b then return true end
	if a.t ~= b.t then return a.t > b.t end
	return ns.Serialize(a) > ns.Serialize(b)
end

-----------------------------------------------------------------------
-- Digests. The list is split into 16 buckets by key; each bucket's
-- digest is the sum of its entries' hashes, so the order entries were
-- added in doesn't matter. Two players with the same bucket digest have
-- the same entries in it, and sync only sends buckets that differ.
-----------------------------------------------------------------------

ns.BUCKETS = 16

local function Hash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return h
end
ns.Hash = Hash

function ns.BucketOf(key)
	return (Hash(key) % ns.BUCKETS) + 1
end

local hashCache
function ns.InvalidateHashes()
	hashCache = nil
end

function ns.BucketHashes()
	if hashCache then return hashCache end
	local sums = {}
	for i = 1, ns.BUCKETS do sums[i] = 0 end
	for key, e in pairs(ns.db.entries) do
		local b = ns.BucketOf(key)
		sums[b] = (sums[b] + Hash(key .. "=" .. ns.Serialize(e))) % 4294967296
	end
	hashCache = sums
	return sums
end

function ns.EntriesInBucket(i)
	local list = {}
	for key, e in pairs(ns.db.entries) do
		if ns.BucketOf(key) == i then list[#list + 1] = e end
	end
	table.sort(list, function(a, b) return ns.Key(a.n, a.r) < ns.Key(b.n, b.r) end)
	return list
end

-----------------------------------------------------------------------
-- The list
-----------------------------------------------------------------------

-- The entry for key while it's on the list (not removed), else nil.
function ns.Get(key)
	local e = key and ns.db and ns.db.entries[key]
	if e and not e.x then return e end
	return nil
end

function ns.GetByName(name, realm)
	return ns.Get(ns.Key(name, realm))
end

function ns.Count()
	local n = 0
	for _, e in pairs(ns.db.entries) do
		if not e.x then n = n + 1 end
	end
	return n
end

-- Every listed (not removed) entry, sorted by name.
function ns.List()
	local list = {}
	for _, e in pairs(ns.db.entries) do
		if not e.x then list[#list + 1] = e end
	end
	table.sort(list, function(a, b) return ns.DisplayName(a):lower() < ns.DisplayName(b):lower() end)
	return list
end

-- A new change stamp: now, but always after the entry's last one.
local function Stamp(old)
	local t = ns.Now()
	if old and old.t and t <= old.t then t = old.t + 1 end
	return t
end

local function Commit(key, e, fromSync)
	local old = ns.db.entries[key]
	-- Keep what this PC knows that isn't shared (level, last seen...).
	if old then
		for k, v in pairs(old) do
			if e[k] == nil and not ns.IsSharedField(k) then e[k] = v end
		end
	end
	ns.db.entries[key] = e
	ns.InvalidateHashes()
	ns.Fire("LIST_CHANGED", key, e, fromSync)
	if not fromSync and ns.SendUpdate then ns.SendUpdate(e) end
end

local sharedSet = {}
for _, f in ipairs(SHARED) do sharedSet[f] = true end
function ns.IsSharedField(k) return sharedSet[k] or false end

local function CopyShared(e)
	local c = {}
	for _, f in ipairs(SHARED) do c[f] = e[f] end
	return c
end

-- Same shared fields, apart from the change stamp?
local function SameShared(a, b)
	for _, f in ipairs(SHARED) do
		if f ~= "t" and a[f] ~= b[f] then return false end
	end
	return true
end

-- Adds or updates a player. info: { name, realm, class, guild, level, race }.
-- Returns the entry and whether it was newly added.
function ns.Add(info, reason)
	local name, realm = info.name, info.realm or ns.MyRealm()
	if type(name) ~= "string" or name == "" then return nil end
	local key = ns.Key(name, realm)
	local old = ns.db.entries[key]
	local e = old and CopyShared(old) or {}
	local wasListed = old and not old.x
	e.n = ns.Clean(name, LIMITS.n)
	e.r = StripRealm(realm) or ns.MyRealm()
	e.c = ns.Clean(info.class, LIMITS.c) or e.c
	e.g = ns.Clean(info.guild, LIMITS.g) or e.g
	if reason ~= nil then e.w = ns.Clean(reason, LIMITS.w) end
	if not wasListed then
		e.b = ns.Clean(ns.MyFullName(), LIMITS.b)
		e.a = ns.Now()
	end
	e.x, e.y = nil, nil
	e.t = Stamp(old)
	if wasListed and SameShared(old, e) then
		-- Nothing changed (same reason, class, guild): don't send anything.
		return old, false
	end
	local localInfo = { lv = info.level, race = info.race }
	for k, v in pairs(localInfo) do e[k] = v end
	Commit(key, e)
	return e, not wasListed
end

function ns.SetReason(key, reason)
	local old = ns.Get(key)
	if not old then return end
	local e = CopyShared(old)
	e.w = ns.Clean(reason, LIMITS.w)
	if e.w == old.w then return end
	e.t = Stamp(old)
	Commit(key, e)
end

function ns.Remove(key)
	local old = ns.Get(key)
	if not old then return nil end
	local e = CopyShared(old)
	e.x = true
	e.y = ns.Clean(ns.MyFullName(), LIMITS.y)
	e.t = Stamp(old)
	Commit(key, e)
	return e
end

-- Fill in the class or guild of a listed player once we see them, so a
-- name typed by hand gets its class colour for everyone.
function ns.LearnDetails(key, class, guild)
	local old = ns.Get(key)
	if not old then return end
	class, guild = ns.Clean(class, LIMITS.c), ns.Clean(guild, LIMITS.g)
	local needClass = class and old.c ~= class
	local needGuild = guild and old.g ~= guild
	if not (needClass or needGuild) then return end
	local e = CopyShared(old)
	if needClass then e.c = class end
	if needGuild then e.g = guild end
	e.t = Stamp(old)
	Commit(key, e)
end

-- An entry that came from a guildmate. Returns true when it changed ours.
function ns.MergeIncoming(e)
	local key = ns.Key(e.n, e.r)
	local old = ns.db.entries[key]
	if old and not ns.IsNewer(e, old) then return false end
	local wasListed = old and not old.x
	Commit(key, e, true)
	if not e.x and not wasListed then
		ns.Fire("ADDED_BY_GUILD", key, e)
	elseif e.x and wasListed then
		ns.Fire("REMOVED_BY_GUILD", key, e)
	end
	return true
end

-----------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.frame = frame
local handlers = {}

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		pcall(frame.RegisterEvent, frame, event)
	end
	table.insert(handlers[event], ns.Guarded(event, fn))
end

-- Only ADDON_LOADED and PLAYER_LOGIN reach a copy that isn't running
-- (asleep under K-UI, or K-UI's module turned off).
local STARTUP_EVENTS = { ADDON_LOADED = true, PLAYER_LOGIN = true }
frame:SetScript("OnEvent", function(_, event, ...)
	if not ns.active and not STARTUP_EVENTS[event] then return end
	for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end)

local function Start()
	if ns.active then return end
	ns.InitDB()
	ns.active = true
	ns.Fire("DB_READY")
end

-- K-UI's copy reads its on/off switch from its own saved table.
local function EmbeddedEnabled()
	local saved = _G[ns.DB_NAME]
	return not (type(saved) == "table" and saved.enabled == false)
end

ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON_NAME then return end
	if ns.embedded then
		_G.KainUIForeverKoS = ns
		if EmbeddedEnabled() then Start() else ns.disabled = true end
	end
end)

-- Every addon and its saved data is loaded by PLAYER_LOGIN, so this is
-- where the standalone copy decides whether K-UI is in charge.
ns.On("PLAYER_LOGIN", function()
	if ns.embedded then
		if ns.active then ns.ImportStandalone() end
		ns.Fire("LOGIN")
		return
	end
	_G.BHGKillListStandalone = ns
	local master = _G.KainUIForeverKoS
	if master and master.active then
		ns.slaved = true -- K-UI's KoS module runs the show
		return
	end
	Start()
	ns.Fire("LOGIN")
end)

-- K-UI turns its module on or off for the next session.
function ns.SetEnabled(on)
	if not ns.embedded then return end
	if type(_G[ns.DB_NAME]) ~= "table" then _G[ns.DB_NAME] = {} end
	_G[ns.DB_NAME].enabled = on and true or false
	ns.Print("K-UI's kill list is " .. (on and "on" or "off") .. " from your next /reload or login."
		.. (on and "" or " If the standalone BH&G Kill List addon is installed, it takes over then."))
end

-- K-UI's copy: bring in the standalone addon's list, records and settings
-- (when that addon is installed, its saved data is loaded too). Safe to
-- repeat: the list merges by the usual newest-change rule, records keep
-- the higher counts.
function ns.ImportStandalone()
	local old = _G.BHGKillListDB
	if type(old) ~= "table" or old == ns.db then return end
	local db = ns.db
	if type(old.entries) == "table" then
		ns.syncQuiet = true
		for _, e in pairs(old.entries) do
			local copy = type(e) == "table" and type(e.n) == "string" and type(e.t) == "number"
				and ns.Deserialize(ns.Serialize(e))
			if copy then
				for k, v in pairs(e) do
					if copy[k] == nil and not ns.IsSharedField(k) then copy[k] = v end
				end
				ns.MergeIncoming(copy)
			end
		end
		ns.syncQuiet = false
	end
	if type(old.enemies) == "table" then
		db.enemies = db.enemies or {}
		for key, rec in pairs(old.enemies) do
			if type(rec) == "table" and type(rec.n) == "string" then
				local mine = db.enemies[key]
				if not mine then
					mine = {}
					for k, v in pairs(rec) do mine[k] = v end
					db.enemies[key] = mine
				else
					for _, f in ipairs({ "w", "l", "times", "last", "lastWin", "lastLoss" }) do
						if type(rec[f]) == "number" and (mine[f] or 0) < rec[f] then mine[f] = rec[f] end
					end
					if type(rec.first) == "number" and (not mine.first or rec.first < mine.first) then mine.first = rec.first end
					for _, f in ipairs({ "c", "lv", "race", "g", "zone" }) do
						if mine[f] == nil then mine[f] = rec[f] end
					end
				end
			end
		end
	end
	-- Settings and window spots only the first time.
	if not db.imported then
		db.imported = true
		if type(old.settings) == "table" then
			for k, v in pairs(old.settings) do db.settings[k] = v end
		end
		if type(old.pos) == "table" then
			for k, v in pairs(old.pos) do db.pos[k] = v end
		end
	end
	ns.Fire("LIST_CHANGED")
end
