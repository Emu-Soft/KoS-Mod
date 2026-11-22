--[[
BH&G Kill List: Commands.lua  (/kos, /bhgkos)

Only the copy that's running owns /kos: it registers the command once it
starts. K-UI's copy, when turned off, keeps a small /kos that only knows
"on" (unless the standalone addon has taken /kos over by then).
--]]

local _, ns = ...

local HELP = {
	"/kos - open the kill list",
	"/kos add - add your target (asks for a reason)",
	"/kos add <name> [reason] - add someone by name (Name, or Name-Realm for someone from elsewhere)",
	"/kos remove <name> - take someone off the list (for everyone)",
	"/kos reason <name> <reason> - change someone's reason",
	"/kos check <name> - is this player (or guild) on the list?",
	"/kos guild - put your target's whole guild on the list (asks for a reason)",
	"/kos guild add <guild>[: reason] - put a whole guild on the list by name",
	"/kos guild remove <guild> - take a guild off the list (for everyone)",
	"/kos guild reason <guild>: <reason> - change a guild's reason",
	"/kos guilds - list the guilds on the kill list",
	"/kos black - put your target on the guild Blacklist (players on our side to keep out of groups)",
	"/kos black <name> [reason] - put someone on the guild Blacklist by name",
	"/kos black remove <name> - take someone off the guild Blacklist (for everyone)",
	"/kos black reason <name> <reason> - change someone's Blacklist reason",
	"/kos blacklist - open the guild Blacklist (/kos black list writes it in chat)",
	"/kos seen - everyone you've come across, with your wins and losses",
	"/kos nearby - show or hide the nearby enemies window",
	"/kos plates - turn on enemy nameplates (spots enemies as soon as they're in range)",
	"/kos options - open the options",
	"/kos sync - compare lists with the guild now",
	"/kos test - show a test warning",
	"/kos move - move the warning",
	"/kos status - what the addon can see (for bug reports)",
	"/kos clicks - write clicks on the nearby window to chat (for bug reports)",
	"/kos on | off - turn K-UI's kill list on or off (K-UI only)",
}

local function SwitchKUI(on)
	local kui = _G.KainUIForeverKoS
	if kui and kui.SetEnabled then
		kui.SetEnabled(on)
	else
		ns.Print("/kos on and /kos off switch K-UI's kill list; K-UI isn't loaded.")
	end
end

local function Status()
	local say = ns.Print
	say((ns.embedded and "K-UI's kill list" or "standalone addon") .. " version " .. ns.VERSION
		.. (_G.BHGKillListStandalone and ns.embedded and " (the standalone addon is installed and asleep)" or "") .. ", " .. ns.Count() .. " players and " .. ns.GuildCount() .. " whole guilds on the list (" .. (function()
		local n = 0
		for _, e in pairs(ns.db.entries) do if e.x then n = n + 1 end end
		return n
	end)() .. " removed ones remembered so removals spread), " .. ns.BlackCount() .. " on the guild Blacklist.")
	say("saved data present at login: " .. (ns.loadedWithData and "yes" or "no (first run, or the client didn't load it; the guild sync fills it back in)"))
	local s = ns.sync
	local peers = 0
	for _, t in pairs(s.peers) do if GetTime() - t < 3600 then peers = peers + 1 end end
	say(string.format("sync: %s | guild %s | sent %d, failed %d, received %d, merged %d | %d queued | %d guildmates heard from in the last hour | last hello %s",
		ns.CommRestricted() and "the game is holding messages right now" or "ok",
		IsInGuild() and "yes" or "NO", s.sent, s.failed or 0, s.received, s.merged, ns.QueueLength(), peers,
		s.lastHello and (math.floor(GetTime() - s.lastHello) .. "s ago") or "not yet"))
	say("last send: " .. (s.lastResult or "none yet") .. " | client checks: " .. ns.CommChecks())
	local digests = {}
	for i, h in ipairs(ns.BucketHashes()) do digests[i] = ns.ToB36(h) end
	local black = {}
	for i, h in ipairs(ns.BlackHashes()) do black[i] = ns.ToB36(h) end
	say("list fingerprint: " .. ns.ToB36(ns.Hash(table.concat(digests, ","))) .. ", guilds " .. ns.ToB36(ns.GuildDigest())
		.. ", Blacklist " .. ns.ToB36(ns.Hash(table.concat(black, ","))) .. " (the same on every guild member's PC once they're in sync)")
	local w, l, seenCount = ns.Totals()
	say("seen " .. seenCount .. " enemy players, record " .. ns.Score({ w = w, l = l }) .. ".")
	local plates = ns.EnemyPlatesOn()
	local range = ns.PlateRange()
	say(string.format("detection: nameplates %s (enemy nameplates %s, range %s), tooltips %s, menus %s, combat log %s",
		(C_NamePlate and C_NamePlate.GetNamePlates) and "yes" or "no",
		plates == true and "on" or (plates == false and "OFF: /kos plates" or "?"),
		range and (range .. " yards") or "?",
		(TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall) and "yes" or "old style",
		(Menu and Menu.ModifyMenu) and "yes" or "no",
		CombatLogGetCurrentEventInfo and "yes" or "no (restricted on Forever)"))
	say("nearby window: " .. (not ns.Setting("nearby") and "off" or ((ns.Setting("hideInDungeons") and ns.InDungeon()) and "hidden in this dungeon" or "on")) .. ".")
	local any = false
	for label, n in pairs(ns.errorCounts) do
		any = true
		say("  caught errors in '" .. label .. "': " .. n)
	end
	if not any then say("no errors caught so far.") end
end

local function ListGuilds()
	local list = ns.GuildList()
	if #list == 0 then
		ns.Print("no guilds on the list. /kos guild adds your target's guild.")
		return
	end
	ns.Print(#list .. " guild" .. (#list == 1 and "" or "s") .. " on the list:")
	for _, g in ipairs(list) do
		print("  |cffffd200<" .. g.n .. ">|r" .. (g.w and (" - " .. g.w) or "") .. " |cff999999(added by " .. ns.SenderName(g.b) .. ", " .. ns.Ago(g.a) .. ")|r")
	end
end

-- "/kos guild ..." (guild names have spaces, so a reason comes after a colon).
local function GuildCommand(rest)
	local sub, arg = rest:match("^(%S*)%s*(.-)$")
	sub = sub:lower()
	local name, reason = arg:match("^([^:]*):%s*(.-)%s*$")
	if not name then name = arg end
	if reason == "" then reason = nil end
	if sub == "" or (sub == "add" and name == "") then
		local guild, why = ns.TargetGuild()
		if not guild then ns.Print(why .. " Or type /kos guild add <guild name>.") return end
		ns.AskGuildReason(guild)
	elseif sub == "add" then
		ns.AddGuildWithMessage(name, reason)
	elseif sub == "remove" or sub == "rem" or sub == "del" then
		if not ns.GetGuild(name) then ns.Print("no guild called \"" .. name .. "\" is on the list.") return end
		ns.RemoveGuildWithMessage(name)
	elseif sub == "reason" then
		if not ns.GetGuild(name) then ns.Print("usage: /kos guild reason <guild>: <reason>") return end
		ns.SetGuildReason(name, reason)
		ns.Print("reason updated.")
	elseif sub == "list" then
		ListGuilds()
	else
		for _, line in ipairs(HELP) do
			if line:find("guild") then print("  " .. line) end
		end
	end
end

-- The key of a listed player typed as arg (get: ns.Get or ns.GetBlack).
local function Find(arg, get)
	get = get or ns.Get
	local name, realm = ns.SplitName(arg)
	if not name then return nil end
	local key = ns.Key(name, realm)
	if get(key) then return key, name, realm end
	-- "/kos remove bob" for a Bob from another realm: match by name if only one.
	local found
	for k, e in pairs(get == ns.Get and ns.db.entries or ns.db.black) do
		if not e.x and e.n:lower() == name:lower() then
			if found then return nil, name, realm end
			found = k
		end
	end
	return found, name, realm
end

local function ListBlack()
	local list = ns.BlackList()
	if #list == 0 then
		ns.Print("nobody on the guild Blacklist. /kos black adds your target.")
		return
	end
	ns.Print(#list .. " player" .. (#list == 1 and "" or "s") .. " on the guild Blacklist:")
	for _, e in ipairs(list) do
		print("  " .. ns.ColorName(e) .. (e.w and (" - " .. e.w) or "") .. " |cff999999(added by " .. ns.SenderName(e.b) .. ", " .. ns.Ago(e.a) .. ")|r")
	end
end

-- "/kos black ..."
local function BlackCommand(rest)
	local sub, arg = rest:match("^(%S*)%s*(.-)$")
	local lower = sub:lower()
	if sub == "" then
		local info = ns.TargetInfo()
		if not info then ns.Print("target a player first, or type /kos black <name> [reason].") return end
		ns.AskBlackReason(info)
	elseif lower == "remove" or lower == "rem" or lower == "del" then
		local key = Find(arg, ns.GetBlack)
		if not key then ns.Print("no one called \"" .. arg .. "\" is on the guild Blacklist.") return end
		ns.RemoveBlackWithMessage(key)
	elseif lower == "reason" then
		local who, reason = arg:match("^(%S+)%s*(.-)$")
		local key = who and Find(who, ns.GetBlack)
		if not key then ns.Print("usage: /kos black reason <name> <reason>") return end
		ns.SetBlackReason(key, reason)
		ns.Print("reason updated.")
	elseif lower == "list" then
		ListBlack()
	else
		local name, realm = ns.SplitName(sub)
		if not name then ns.Print("that isn't a player name.") return end
		ns.AddBlackWithMessage({ name = name, realm = realm }, arg ~= "" and arg or nil)
	end
end

local function Handler(msg)
	if not ns.db then return end
	msg = (msg or ""):match("^%s*(.-)%s*$")
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	cmd = cmd and cmd:lower() or ""

	if cmd == "on" or cmd == "off" then
		SwitchKUI(cmd == "on")
	elseif cmd == "" then
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
		local g = not e and ns.GetGuild(rest)
		local blackKey = Find(rest, ns.GetBlack)
		local b = blackKey and ns.GetBlack(blackKey)
		if e then
			ns.Print(ns.ColorName(e) .. " is on the list" .. (e.w and (": " .. e.w) or "") .. " (added by " .. ns.SenderName(e.b) .. ", " .. ns.Ago(e.a) .. ").")
		elseif g then
			ns.Print("the whole guild <" .. g.n .. "> is on the list" .. (g.w and (": " .. g.w) or "") .. " (added by " .. ns.SenderName(g.b) .. ", " .. ns.Ago(g.a) .. ").")
		end
		if b then
			ns.Print(ns.ColorName(b) .. " is on the guild Blacklist" .. (b.w and (": " .. b.w) or "") .. " (added by " .. ns.SenderName(b.b) .. ", " .. ns.Ago(b.a) .. ").")
		end
		if not e and not g and not b then
			ns.Print((name or rest) .. " isn't on the kill list or the Blacklist.")
		end
	elseif cmd == "guild" then
		GuildCommand(rest)
	elseif cmd == "guilds" then
		ListGuilds()
	elseif cmd == "black" or cmd == "bl" then
		BlackCommand(rest)
	elseif cmd == "blacklist" then
		if rest == "" then ns.ShowPage("black") else BlackCommand(rest) end
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
	elseif cmd == "clicks" then
		ns.clickDebug = not ns.clickDebug
		ns.Print(ns.clickDebug and "clicks on the nearby window are now written to chat. Type /kos clicks again to stop." or "click details off.")
	else
		for _, line in ipairs(HELP) do print("  " .. line) end
	end
end

local function Register(fn)
	_G.SLASH_BHGKILLLIST1 = "/kos"
	_G.SLASH_BHGKILLLIST2 = "/bhgkos"
	SlashCmdList["BHGKILLLIST"] = fn
	if _G.hash_SlashCmdList then -- drop the chat box's cached lookup
		_G.hash_SlashCmdList["/KOS"] = nil
		_G.hash_SlashCmdList["/BHGKOS"] = nil
	end
end

ns.Listen("DB_READY", function() Register(Handler) end)

-- K-UI's copy, turned off: answer /kos on, unless the standalone addon
-- is running and owns /kos.
if ns.embedded then
	local probe = CreateFrame("Frame")
	probe:RegisterEvent("PLAYER_LOGIN")
	probe:SetScript("OnEvent", function()
		C_Timer.After(0, function()
			if not ns.disabled then return end
			local standalone = _G.BHGKillListStandalone
			if standalone and standalone.active then return end
			Register(function(msg)
				local cmd = (msg or ""):match("^%s*(%S*)"):lower()
				if cmd == "on" then
					ns.SetEnabled(true)
				else
					ns.Print("K-UI's kill list is off. Type /kos on and /reload to turn it on.")
				end
			end)
		end)
	end)
end
