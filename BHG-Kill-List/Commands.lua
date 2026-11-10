--[[
BH&G Kill List: Commands.lua  (/kos, /bhgkos)
--]]

local _, ns = ...

local HELP = {
	"/kos - open the kill list",
	"/kos add - add your target (asks for a reason)",
	"/kos add <name> [reason] - add someone by name (Name or Name-Realm)",
	"/kos remove <name> - take someone off the list (for everyone)",
	"/kos reason <name> <reason> - change someone's reason",
	"/kos check <name> - is this player on the list?",
	"/kos seen - everyone you've come across, with your wins and losses",
	"/kos nearby - show or hide the nearby enemies window",
	"/kos plates - turn on enemy nameplates (spots enemies as soon as they're in range)",
	"/kos options - open the options",
	"/kos sync - compare lists with the guild now",
	"/kos test - show a test warning",
	"/kos move - move the warning",
	"/kos status - what the addon can see (for bug reports)",
}

local function Status()
	local say = ns.Print
	say("version " .. ns.VERSION .. ", " .. ns.Count() .. " players on the list (" .. (function()
		local n = 0
		for _, e in pairs(ns.db.entries) do if e.x then n = n + 1 end end
		return n
	end)() .. " removed ones remembered so removals spread).")
	say("saved data present at login: " .. (ns.loadedWithData and "yes" or "no (first run, or the client didn't load it; the guild sync fills it back in)"))
	local s = ns.sync
	local peers = 0
	for _, t in pairs(s.peers) do if GetTime() - t < 3600 then peers = peers + 1 end end
	say(string.format("sync: %s | guild %s | sent %d, received %d, merged %d | %d queued | %d guildmates heard from in the last hour | last hello %s",
		ns.CommRestricted() and "chat RESTRICTED right now" or "ok",
		IsInGuild() and "yes" or "NO", s.sent, s.received, s.merged, ns.QueueLength(), peers,
		s.lastHello and (math.floor(GetTime() - s.lastHello) .. "s ago") or "not yet"))
	local digests = {}
	for i, h in ipairs(ns.BucketHashes()) do digests[i] = ns.ToB36(h) end
	say("list fingerprint: " .. ns.ToB36(ns.Hash(table.concat(digests, ","))) .. " (the same on every guild member's PC once they're in sync)")
	local w, l, seenCount = ns.Totals()
	say("seen " .. seenCount .. " enemy players, record " .. ns.Score({ w = w, l = l }) .. ".")
	local plates = ns.EnemyPlatesOn()
	say(string.format("detection: nameplates %s (enemy nameplates %s), tooltips %s, menus %s, combat log %s",
		(C_NamePlate and C_NamePlate.GetNamePlates) and "yes" or "no",
		plates == true and "on" or (plates == false and "OFF: /kos plates" or "?"),
		(TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall) and "yes" or "old style",
		(Menu and Menu.ModifyMenu) and "yes" or "no",
		CombatLogGetCurrentEventInfo and "yes" or "no (restricted on Forever)"))
	local any = false
	for label, n in pairs(ns.errorCounts) do
		any = true
		say("  caught errors in '" .. label .. "': " .. n)
	end
	if not any then say("no errors caught so far.") end
end

local function Find(arg)
	local name, realm = ns.SplitName(arg)
	if not name then return nil end
	local key = ns.Key(name, realm)
	if ns.Get(key) then return key, name, realm end
	-- "/kos remove bob" for a Bob from another realm: match by name if only one.
	local found
	for k, e in pairs(ns.db.entries) do
		if not e.x and e.n:lower() == name:lower() then
			if found then return nil, name, realm end
			found = k
		end
	end
	return found, name, realm
end

SLASH_BHGKILLLIST1 = "/kos"
SLASH_BHGKILLLIST2 = "/bhgkos"
SlashCmdList["BHGKILLLIST"] = function(msg)
	if not ns.db then return end
	msg = (msg or ""):match("^%s*(.-)%s*$")
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	cmd = cmd and cmd:lower() or ""

	if cmd == "" then
		ns.ToggleWindow()
	elseif cmd == "add" then
		if rest == "" then
			local info = ns.TargetInfo()
			if not info then ns.Print("target a player first, or type /kos add <name>.") return end
			ns.AskReason(info)
			return
		end
		local who, reason = rest:match("^(%S+)%s*(.-)$")
		local name, realm = ns.SplitName(who)
		if not name then ns.Print("that isn't a player name.") return end
		ns.AddWithMessage({ name = name, realm = realm }, reason ~= "" and reason or nil)
	elseif cmd == "remove" or cmd == "rem" or cmd == "del" then
		local key = Find(rest)
		if not key then ns.Print("no one called \"" .. rest .. "\" is on the list.") return end
		ns.RemoveWithMessage(key)
	elseif cmd == "reason" then
		local who, reason = rest:match("^(%S+)%s*(.-)$")
		local key = who and Find(who)
		if not key then ns.Print("usage: /kos reason <name> <reason>") return end
		ns.SetReason(key, reason)
		ns.Print("reason updated.")
	elseif cmd == "check" then
		local key, name = Find(rest)
		local e = key and ns.Get(key)
		if e then
			ns.Print(ns.ColorName(e) .. " is on the list" .. (e.w and (": " .. e.w) or "") .. " (added by " .. ns.ShortSender(e.b) .. ", " .. ns.Ago(e.a) .. ").")
		else
			ns.Print((name or rest) .. " isn't on the list.")
		end
	elseif cmd == "seen" or cmd == "stats" then
		ns.ShowPage("seen")
	elseif cmd == "plates" then
		ns.TurnOnEnemyPlates()
	elseif cmd == "nearby" then
		ns.ToggleNearby()
	elseif cmd == "options" or cmd == "config" then
		ns.ToggleWindow(true)
	elseif cmd == "sync" then
		if ns.SyncNow() then
			ns.Print("asked the guild to compare lists.")
		else
			ns.Print("you need to be in a guild to sync.")
		end
	elseif cmd == "test" then
		ns.TestAlert()
	elseif cmd == "move" then
		ns.Print(ns.ToggleBannerMove() and "drag the warning where you want it, then type /kos move again." or "warning position saved.")
	elseif cmd == "status" or cmd == "probe" then
		Status()
	else
		for _, line in ipairs(HELP) do print("  " .. line) end
	end
end
