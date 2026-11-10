--[[
BH&G Kill List: Stats.lua

Your own record of every enemy player you've come across, kept between
sessions and built up over time (like Spy's player list): when and where
you saw them, how often, their class, level, race and guild, and your
wins and losses against them. This stays on your PC; it isn't shared.

Wins and losses. Spy reads them off the combat log, which addons can't
read on Forever, so they're worked out from what can be seen:
  * a win: an enemy player you were fighting dies (they were your target
    while you were in combat, or they were targeting you), or the game
    gives you an honourable kill for them;
  * a loss: you die while an enemy player is targeting you (or you were
    fighting one) in the last few seconds; the one who targeted you last
    gets it.
Each kill counts once, however many of these signals it sets off.
--]]

local _, ns = ...
local Plain = ns.Plain

local ENGAGED_FOR = 30   -- seconds a fight with someone still counts for a win
local KILLED_BY_FOR = 12 -- seconds before your death an attacker still counts
local RECOUNT_AFTER = 60 -- the same player can't be "killed" twice within this
local NEW_ENCOUNTER = 300 -- seconds unseen before seeing them again counts as a new sighting
local MAX_ENEMIES = 5000

local engaged = {}  -- key -> GetTime() of the last sign we were fighting
local attacker = {} -- key -> GetTime() they were last seen targeting us
local lastWin = {}  -- key -> GetTime()

local function Call(fn, ...)
	if not fn then return nil end
	local ok, a, b = pcall(fn, ...)
	if not ok then return nil end
	return Plain(a), Plain(b)
end

function ns.Enemies()
	return ns.db.enemies
end

function ns.Enemy(key)
	return ns.db and ns.db.enemies[key]
end

ns.Listen("DB_READY", function()
	local db = ns.db
	if type(db.enemies) ~= "table" then db.enemies = {} end
	local n, list = 0, {}
	for key, rec in pairs(db.enemies) do
		if type(rec) ~= "table" or type(rec.n) ~= "string" then
			db.enemies[key] = nil
		else
			n = n + 1
			list[n] = key
		end
	end
	-- Keep the database from growing forever: drop the longest-unseen
	-- players you never fought.
	if n > MAX_ENEMIES then
		table.sort(list, function(a, b) return (db.enemies[a].last or 0) < (db.enemies[b].last or 0) end)
		for i = 1, n do
			if n <= MAX_ENEMIES then break end
			local rec = db.enemies[list[i]]
			if (rec.w or 0) + (rec.l or 0) == 0 then
				db.enemies[list[i]] = nil
				n = n - 1
			end
		end
	end
end)

local function Record(key, name, realm)
	local enemies = ns.db.enemies
	local rec = enemies[key]
	if not rec then
		rec = { n = name, r = realm, first = ns.Now(), times = 0, w = 0, l = 0 }
		enemies[key] = rec
	end
	return rec
end

local function Score(rec)
	return "|cff40ff40" .. (rec.w or 0) .. "W|r / |cffff4040" .. (rec.l or 0) .. "L|r"
end
ns.Score = Score

local function Win(key, how)
	local rec = ns.Enemy(key)
	if not rec then return end
	if lastWin[key] and GetTime() - lastWin[key] < RECOUNT_AFTER then return end
	lastWin[key] = GetTime()
	engaged[key], attacker[key] = nil, nil
	rec.w = (rec.w or 0) + 1
	rec.lastWin = ns.Now()
	if ns.Setting("chat") then
		ns.Print("you killed " .. ns.ColorName({ n = rec.n, r = rec.r, c = rec.c }) .. ". Your record against them: " .. Score(rec) .. ".")
	end
	ns.Fire("STATS_CHANGED", key, how)
end

-- Called for every enemy player seen (info from ns.ReadUnit).
function ns.RecordEnemy(info, isNewcomer)
	local key = ns.Key(info.name, info.realm)
	local rec = Record(key, ns.ProperName(info.name), info.realm)
	local now = ns.Now()
	if isNewcomer or not rec.last or now - rec.last > NEW_ENCOUNTER then
		rec.times = (rec.times or 0) + 1
		rec.zone = ns.WhereAmI()
	end
	rec.last = now
	rec.c = info.class or rec.c
	rec.lv = info.level or rec.lv
	rec.race = info.race or rec.race
	rec.g = info.guild or rec.g

	local unit = info.unit
	if not unit then return rec end
	local t = GetTime()
	if Call(UnitIsUnit, unit .. "target", "player") then
		engaged[key], attacker[key] = t, t
	elseif Call(UnitAffectingCombat, "player") and (Call(UnitIsUnit, unit, "target") or Call(UnitIsUnit, unit, "softenemy")) then
		engaged[key] = t
	end
	if info.dead and engaged[key] and t - engaged[key] < ENGAGED_FOR then
		Win(key, "death")
	end
	return rec
end

-- A unit that may have just died (health event, plate going away).
function ns.CheckDeath(unit)
	if not Call(UnitIsPlayer, unit) then return end
	if not Call(UnitIsDeadOrGhost, unit) then return end
	local name, realm = Call(UnitName, unit)
	if type(name) ~= "string" or name == "" then return end
	local key = ns.Key(name, (type(realm) == "string" and realm ~= "") and realm or nil)
	if engaged[key] and GetTime() - engaged[key] < ENGAGED_FOR and ns.Enemy(key) then
		Win(key, "death")
	end
end

local function IsWatchedUnit(unit)
	return type(unit) == "string" and (unit:find("^nameplate%d") or unit == "target" or unit == "focus" or unit == "softenemy")
end

ns.On("UNIT_HEALTH", function(unit)
	unit = Plain(unit)
	if IsWatchedUnit(unit) then ns.CheckDeath(unit) end
end)
ns.On("NAME_PLATE_UNIT_REMOVED", function(unit)
	unit = Plain(unit)
	if IsWatchedUnit(unit) then ns.CheckDeath(unit) end
end)

-- Honourable kills, where the client reports them.
local honorPattern
do
	local fmt = _G.COMBATLOG_HONORGAIN or _G.COMBATLOG_HONORGAIN_NO_RANK
	if type(fmt) == "string" then
		local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
		p = p:gsub("%%%%s", "(.-)"):gsub("%%%%d", "%%d+"):gsub("%%%%%.%%d+f", "[%%d%%.]+")
		honorPattern = "^" .. p
	end
end
ns.On("CHAT_MSG_COMBAT_HONOR_GAIN", function(msg)
	msg = Plain(msg)
	if type(msg) ~= "string" or not honorPattern then return end
	local victim = msg:match(honorPattern)
	local name, realm = ns.SplitName(victim)
	if not name then return end
	local key = ns.Key(name, realm)
	if not ns.Enemy(key) then Record(key, name, realm).last = ns.Now() end
	Win(key, "honor")
end)

ns.On("PLAYER_DEAD", function()
	local t = GetTime()
	local bestKey, bestTime
	for key, at in pairs(attacker) do
		if t - at < KILLED_BY_FOR and (not bestTime or at > bestTime) then bestKey, bestTime = key, at end
	end
	if not bestKey then
		for key, at in pairs(engaged) do
			if t - at < KILLED_BY_FOR and (not bestTime or at > bestTime) then bestKey, bestTime = key, at end
		end
	end
	if not bestKey then return end
	local rec = ns.Enemy(bestKey)
	if not rec then return end
	for k in pairs(engaged) do engaged[k] = nil end
	for k in pairs(attacker) do attacker[k] = nil end
	rec.l = (rec.l or 0) + 1
	rec.lastLoss = ns.Now()
	if ns.Setting("chat") then
		ns.Print("killed by " .. ns.ColorName({ n = rec.n, r = rec.r, c = rec.c }) .. ". Your record against them: " .. Score(rec) .. ".")
	end
	ns.Fire("STATS_CHANGED", bestKey, "loss")
end)

-- Everyone you've seen, most recent first.
function ns.EnemyList()
	local list = {}
	for key, rec in pairs(ns.db.enemies) do
		list[#list + 1] = { key = key, rec = rec }
	end
	table.sort(list, function(a, b) return (a.rec.last or 0) > (b.rec.last or 0) end)
	return list
end

function ns.Totals()
	local w, l, n = 0, 0, 0
	for _, rec in pairs(ns.db.enemies) do
		w, l, n = w + (rec.w or 0), l + (rec.l or 0), n + 1
	end
	return w, l, n
end

-- Lines for a tooltip about key: record, sightings.
function ns.AddStatsLines(tooltip, key)
	local rec = ns.Enemy(key)
	if not rec then return end
	tooltip:AddLine("Your record: " .. Score(rec), 1, 1, 1)
	local seen = "Seen " .. (rec.times or 1) .. " time" .. ((rec.times or 1) == 1 and "" or "s") .. ", first " .. ns.Ago(rec.first)
	tooltip:AddLine(seen, 0.6, 0.6, 0.6)
end

-- Exposed for the offline test.
ns._stats = { engaged = engaged, attacker = attacker }
