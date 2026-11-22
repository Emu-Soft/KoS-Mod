-- Offline test of BH&G Kill List: many players running the addon at
-- once on one simulated clock, talking over a simulated guild channel.
-- Checks that everyone's list ends up the same however they log in and
-- out, that a big guild doesn't flood the channel, that spotting a
-- listed player warns you and tells the guild, that the seen-enemies
-- database counts wins and losses and survives a relog, and that the
-- guild Blacklist syncs and warns without touching the kill list.
--
--   lua5.1 tests/sync_sim.lua BHG-Kill-List [seed] [throttle chance] [KoS.lua]
--
-- With a K-UI build (python3 tools/build_kui.py KoS.lua) as the last
-- argument it also checks K-UI users and standalone users sharing one
-- list, and a PC with both installed (K-UI in charge).
--
-- The throttle chance (0 to 1) makes that share of sends come back
-- "throttled", like the real client does under load.
--
-- A 5th argument, a folder holding an older version's addon files
-- (e.g. from git archive), also checks that version in a guild with
-- this one.
local DIR = arg[1]
KUI_FILE = arg[4]
THROTTLE = tonumber(arg[3])
local OLD_DIR = arg[5]
-- The addon's files, in the order its toc loads them.
local function TocFiles(dir)
  local files = {}
  for line in io.lines(dir .. "/BHG-Kill-List.toc") do
    local file = line:match("^%s*([%w_]+%.lua)%s*$")
    if file then files[#files+1] = file end
  end
  return files
end

local clock = 0
local timers = {}         -- { at, fn, client, cancelled }
local clients = {}        -- name -> client
local online = {}         -- name -> client
local bus = {}            -- pending deliveries { at, from, text, prefix }
local totalMessages = 0
local seed = tonumber(arg[2]) or 1
math.randomseed(seed)

local function NewFrame()
  local f = { shown = false, scripts = {}, events = {}, attrs = {} }
  local m = {}
  function m.RegisterEvent(self, e) self.events[e] = true end
  function m.SetScript(self, k, fn) self.scripts[k] = fn end
  function m.HookScript(self, k, fn) self.scripts[k] = fn end
  function m.GetScript(self, k) return self.scripts[k] end
  function m.Show(self) self.shown = true end
  function m.Hide(self) self.shown = false end
  function m.SetShown(self, v) self.shown = v and true or false end
  function m.IsShown(self) return self.shown end
  function m.GetText() return "" end
  function m.HasFocus() return false end
  function m.GetChecked() return false end
  function m.SetAttribute(self, k, v) self.attrs[k] = v end
  function m.CreateTexture() return NewFrame() end
  function m.CreateFontString() return NewFrame() end
  function m.GetCenter() return nil end
  function m.GetEditBox() return NewFrame() end
  setmetatable(f, { __index = function(_, k) return m[k] or function() end end })
  return f
end

local function MakeEnv(c)
  local env = {}
  local frames = {}
  c.frames = frames
  local base = {
    print = function(...) local t = {...} for i=1,#t do t[i]=tostring(t[i]) end c.log[#c.log+1] = table.concat(t, " ") end,
    pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber, select = select,
    pcall = pcall, error = error, next = next, setmetatable = setmetatable, unpack = unpack,
    string = string, table = table, math = math, time = os.time, tinsert = table.insert,
    CreateFrame = function(_, name) local f = NewFrame() f.name = name frames[#frames+1] = f return f end,
    UIParent = NewFrame(), GameTooltip = NewFrame(), UISpecialFrames = {},
    StaticPopupDialogs = {}, SlashCmdList = {}, StaticPopup_Show = function() end,
    BackdropTemplateMixin = {}, Mixin = function(t) return t end,
    GetTime = function() return clock end,
    GetServerTime = function() return 1800000000 + math.floor(clock) end,
    GetNormalizedRealmName = function() return "Forever" end,
    GetRealmName = function() return "Forever" end,
    UnitName = function(u) if u == "player" then return c.name end end,
    UnitExists = function() return false end,
    IsInGuild = function() return true end,
    InCombatLockdown = function() return false end,
    PlaySound = function() end,
    COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)",
    PlaySoundFile = function(path) c.sounds = c.sounds or {} c.sounds[#c.sounds+1] = path:match("([%w%-]+)%.mp3$") end,
    C_AddOns = { GetAddOnMetadata = function() return "test" end },
    C_Timer = {
      After = function(s, fn) timers[#timers+1] = { at = clock + s, fn = fn, client = c } end,
      NewTimer = function(s, fn)
        local t = { at = clock + s, fn = fn, client = c }
        t.Cancel = function() t.cancelled = true end
        timers[#timers+1] = t
        return t
      end,
      NewTicker = function(s, fn)
        local t = { at = clock + s, fn = fn, client = c, every = s }
        t.Cancel = function() t.cancelled = true end
        timers[#timers+1] = t
        return t
      end,
    },
    C_ChatInfo = {
      RegisterAddonMessagePrefix = function() end,
      -- Forever's client says "restricted" in the open world while
      -- sending works, so the addon must go by the send result instead.
      AreOutgoingAddonChatMessagesRestricted = function() return true end,
      InChatMessagingLockdown = function() return LOCKDOWN == true end,
      SendAddonMessage = function(prefix, text, channel)
        assert(#text <= 255, "message too long: " .. #text)
        if LOCKDOWN then return 11 end
        if THROTTLE and math.random() < THROTTLE then return 3 end
        assert(channel == "GUILD")
        totalMessages = totalMessages + 1
        c.sentCount = (c.sentCount or 0) + 1
        bus[#bus+1] = { at = clock + 0.05, from = c, prefix = prefix, text = text }
        return 0
      end,
    },
    Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8, AddOnMessageLockdown = 11 } },
  }
  base._G = env
  setmetatable(env, { __index = base })
  return env
end

local function Fire(c, event, ...)
  for _, f in ipairs(c.frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

-- addons: which copies this player runs: "standalone" (default), "kui"
-- (K-UI's KoS.lua, built by tools/build_kui.py) or "both".
local Logout
local function Login(name, db, addons)
  if online[name] then Logout(name) end -- a /reload
  local c = clients[name] or { name = name }
  clients[name] = c
  c.log = {}
  c.alive = {}
  addons = addons or c.addons or "standalone"
  c.addons = addons
  local env = MakeEnv(c)
  c.saved = c.saved or {}
  if db then c.saved.BHGKillListDB = db end
  env.BHGKillListDB = c.saved.BHGKillListDB
  env.KainUIForeverKoSDB = c.saved.KainUIForeverKoSDB
  local standalone, kui
  if addons == "standalone" or addons == "both" or addons == "old" then
    standalone = {}
    local dir = addons == "old" and OLD_DIR or DIR
    for _, file in ipairs(TocFiles(dir)) do
      local chunk = assert(loadfile(dir .. "/" .. file))
      setfenv(chunk, env)
      chunk("BHG-Kill-List", standalone)
    end
  end
  if addons == "kui" or addons == "both" then
    assert(KUI_FILE, "give the built KoS.lua as the 4th argument")
    local chunk = assert(loadfile(KUI_FILE))
    setfenv(chunk, env)
    local KUI = {}
    chunk("Kain-UI-Forever", KUI)
    kui = KUI.KoS
  end
  c.env, c.standalone, c.kui = env, standalone, kui
  online[name] = c
  -- The client loads addons in name order: BHG-Kill-List before Kain-UI-Forever.
  if standalone then Fire(c, "ADDON_LOADED", "BHG-Kill-List") end
  if kui then Fire(c, "ADDON_LOADED", "Kain-UI-Forever") end
  Fire(c, "PLAYER_LOGIN")
  c.ns = (kui and kui.active and kui) or standalone or kui
  c.db = c.ns.db
  Fire(c, "PLAYER_ENTERING_WORLD")
  return c
end

Logout = function(name)
  local c = online[name]
  online[name] = nil
  c.saved.BHGKillListDB = c.env.BHGKillListDB
  c.saved.KainUIForeverKoSDB = c.env.KainUIForeverKoSDB
  c.session = (c.session or 0) + 1
  -- drop its timers
  for _, t in ipairs(timers) do if t.client == c then t.cancelled = true end end
end

local function Run(seconds)
  local stop = clock + seconds
  while true do
    -- next event
    local nextAt, kind, idx = math.huge
    for i, t in ipairs(timers) do if not t.cancelled and t.at < nextAt then nextAt, kind, idx = t.at, "t", i end end
    for i, m in ipairs(bus) do if m.at < nextAt then nextAt, kind, idx = m.at, "m", i end end
    if nextAt > stop then clock = stop return end
    clock = nextAt
    if kind == "t" then
      local t = timers[idx]
      if t.every then t.at = t.at + t.every else table.remove(timers, idx) end
      if online[t.client.name] == t.client then
        local ok, err = pcall(t.fn)
        if not ok then error("timer error in " .. t.client.name .. ": " .. tostring(err)) end
      end
    else
      local m = table.remove(bus, idx)
      for _, c in pairs(online) do
        -- the guild channel echoes to the sender too
        Fire(c, "CHAT_MSG_ADDON", m.prefix, m.text, "GUILD", m.from.name .. "-Forever")
      end
    end
  end
end

-- The player buckets, the guild list and the Blacklist (playersOnly:
-- just the players, to compare with a version from before guilds).
local function Fingerprint(c, playersOnly)
  local ns = c.ns
  local parts = {}
  for i, h in ipairs(ns.BucketHashes()) do parts[i] = h end
  if not playersOnly then
    parts[#parts+1] = ns.GuildDigest()
    for _, h in ipairs(ns.BlackHashes()) do parts[#parts+1] = h end
  end
  return table.concat(parts, ",")
end

local function AllSame(list, playersOnly)
  local fp
  for _, c in pairs(list or online) do
    local f = Fingerprint(c, playersOnly)
    if fp and f ~= fp then return false end
    fp = f
  end
  return true
end

local function Errors(c)
  local n = 0
  for _, space in pairs({ c.standalone or false, c.kui or false }) do
    if space then
      for label, k in pairs(space.errorCounts) do n = n + k print("  ERROR in " .. c.name .. " " .. label .. ": " .. k) end
    end
  end
  for _, l in ipairs(c.log) do if l:find("error") and not l:find("no errors") then print("  LOG " .. c.name .. ": " .. l) end end
  return n
end

local fails = 0
local function Check(cond, msg)
  if cond then print("ok   " .. msg) else print("FAIL " .. msg) fails = fails + 1 end
end

local function Add(c, name, reason) return c.ns.Add({ name = name, realm = "Forever" }, reason) end
local function Has(c, name) return c.ns.Get(c.ns.Key(name, "Forever")) ~= nil end

---------------------------------------------------------------- scenario 1
print("== 1. two players with different offline lists log in")
local A = Login("Alice")
for i = 1, 30 do Add(A, "Horde" .. i, "ganked me " .. i) end
Run(30) Logout("Alice")
local B = Login("Bob")
for i = 25, 50 do Add(B, "Horde" .. i, "camping") end
Run(30) Logout("Bob")
local before = totalMessages
A = Login("Alice") Run(5)
B = Login("Bob") Run(120)
Check(AllSame(), "Alice and Bob end with the same list")
Check(A.ns.Count() == 50 and B.ns.Count() == 50, "both have all 50 (" .. A.ns.Count() .. ", " .. B.ns.Count() .. ")")
print("     messages for the catch-up: " .. (totalMessages - before))

---------------------------------------------------------------- scenario 2
print("== 2. live add and remove reach everyone online")
local C = Login("Carol") Run(120)
Check(C.ns.Count() == 50, "Carol (new, empty) caught up to 50 (" .. C.ns.Count() .. ")")
Add(A, "Livegank", "just now") Run(5)
Check(Has(B, "Livegank") and Has(C, "Livegank"), "a new add reached Bob and Carol")
B.ns.Remove(B.ns.Key("Horde3", "Forever")) Run(5)
Check(not Has(A, "Horde3") and not Has(C, "Horde3"), "a removal reached Alice and Carol")
Check(AllSame(), "all three in sync")

-- The game holding messages (an encounter): nothing is lost.
LOCKDOWN = true
Add(A, "Heldback", "sent during a lockdown") Run(20)
Check(not Has(B, "Heldback"), "while the game holds messages, nothing goes out")
Check(A.ns.QueueLength() > 0, "and the add waits in the queue")
LOCKDOWN = nil
Run(10)
Check(Has(B, "Heldback") and Has(C, "Heldback"), "once it lets go, the add reaches everyone")
Check(AllSame(), "all three in sync again")

---------------------------------------------------------------- scenario 3
print("== 3. a removal made while someone is offline sticks")
Logout("Carol")
A.ns.Remove(A.ns.Key("Horde10", "Forever")) Run(5)
Add(B, "Newwhileaway", "x") Run(5)
C = Login("Carol") Run(120)
Check(not Has(C, "Horde10"), "Carol's old copy of Horde10 didn't come back")
Check(Has(C, "Newwhileaway"), "Carol got the add she missed")
Check(Has(A, "Horde11") and not Has(A, "Horde10"), "Alice still has the removal")
Check(AllSame(), "all three in sync")

---------------------------------------------------------------- scenario 4
print("== 4. same player edited on two offline PCs: everyone settles on one version")
Logout("Alice") Logout("Bob") Logout("Carol")
A = Login("Alice") A.ns.SetReason(A.ns.Key("Horde20", "Forever"), "reason from Alice") Run(10) Logout("Alice")
B = Login("Bob") B.ns.SetReason(B.ns.Key("Horde20", "Forever"), "reason from Bob") Run(10) Logout("Bob")
A = Login("Alice") B = Login("Bob") C = Login("Carol") Run(120)
Check(AllSame(), "all three in sync")
local w = A.ns.Get(A.ns.Key("Horde20", "Forever")).w
Check(w == "reason from Bob", "the later edit won (" .. tostring(w) .. ")")

---------------------------------------------------------------- scenario 5
print("== 5. a big guild: 12 in sync with 300 players, a fresh install logs in")
for _, n in ipairs({ "Alice", "Bob", "Carol" }) do Logout(n) end
local names = {}
for i = 1, 12 do names[i] = "Member" .. i end
local first = Login(names[1])
for i = 1, 300 do Add(first, "Enemy" .. i, "big list entry number " .. i) end
Run(5)
for i = 2, 12 do Login(names[i]) Run(3) end
Run(600)
Check(AllSame(), "all 12 in sync")
Check(online["Member12"].ns.Count() == 300, "member 12 has 300 (" .. online["Member12"].ns.Count() .. ")")
local before5 = totalMessages
local fresh = Login("Newbie") Run(600)
Check(fresh.ns.Count() == 300, "the fresh install caught up (" .. fresh.ns.Count() .. ")")
Check(AllSame(), "all 13 in sync")
local used = totalMessages - before5
print("     messages for the fresh install's catch-up: " .. used)
Check(used < 250, "the guild didn't answer many times over (under 250 messages)")
local before6 = totalMessages
Login("Member1") -- someone reloads while in sync
Run(120)
print("     messages when an in-sync member reloads: " .. (totalMessages - before6))
Check(totalMessages - before6 <= 3, "an in-sync login costs just its hello (players, guilds, Blacklist)")

---------------------------------------------------------------- scenario 6
print("== 6. random fuzz: 6 players, random adds/removes/edits, online and offline")
for n in pairs(online) do Logout(n) end
local pool = { "P1", "P2", "P3", "P4", "P5", "P6" }
for round = 1, 40 do
  local who = pool[math.random(#pool)]
  local c = online[who]
  if c and math.random() < 0.3 then Logout(who)
  elseif not c then Login(who) end
  c = online[who]
  if c then
    for _ = 1, math.random(1, 6) do
      local target = "Foe" .. math.random(1, 60)
      local r = math.random()
      local key = c.ns.Key(target, "Forever")
      if r < 0.4 then Add(c, target, "r" .. math.random(1, 5))
      elseif r < 0.6 then c.ns.Remove(key)
      elseif r < 0.7 then c.ns.SetReason(key, "edit" .. math.random(100))
      elseif r < 0.85 then c.ns.AddBlack({ name = target, realm = "Forever" }, "b" .. math.random(1, 5))
      elseif r < 0.95 then c.ns.RemoveBlack(key)
      else c.ns.SetBlackReason(key, "bedit" .. math.random(100)) end
    end
  end
  Run(math.random(1, 40))
end
for _, n in ipairs(pool) do if not online[n] then Login(n) end end
Run(900)
Check(AllSame(), "all 6 in sync after everyone logs in")
local counts = {}
for _, n in ipairs(pool) do counts[#counts+1] = online[n].ns.Count() .. "/" .. online[n].ns.BlackCount() end
print("     counts (kill list/Blacklist): " .. table.concat(counts, " "))

---------------------------------------------------------------- scenario 7
print("== 7. spotting a listed enemy: warning, and the guild hears where")
local S1, S2 = online["P1"], online["P2"]
Add(S1, "Gankboy", "corpse camps lowbies") Run(5)
local env = S1.env
local units = { nameplate1 = { name = "Gankboy", class = "ROGUE", level = 58, guild = "Red Hand", faction = "Horde" } }
env.UnitExists = function(u) return units[u] ~= nil end
env.UnitIsPlayer = function(u) return units[u] ~= nil end
env.UnitIsUnit = function() return false end
env.UnitName = function(u) if u == "player" then return "P1" end return units[u] and units[u].name end
env.UnitClass = function(u) return "Rogue", units[u] and units[u].class end
env.UnitLevel = function(u) return units[u] and units[u].level end
env.UnitRace = function() return "Orc" end
env.GetGuildInfo = function(u) return units[u] and units[u].guild end
env.UnitIsEnemy = function() return true end
env.UnitFactionGroup = function(u) if u == "player" then return "Alliance" end return "Horde" end
env.GetRealZoneText = function() return "Elwynn Forest" end
env.GetSubZoneText = function() return "Goldshire" end
S1.log = {} S2.log = {} S1.sounds = {} S2.sounds = {}
Fire(S1, "NAME_PLATE_UNIT_ADDED", "nameplate1") Run(5)
local warned, heard = false, false
for _, l in ipairs(S1.log) do if l:find("KILL ON SIGHT") and l:find("Gankboy") then warned = true end end
for _, l in ipairs(S2.log) do if l:find("Gankboy") and l:find("spotted by P1") and l:find("Goldshire") then heard = true end end
Check(warned, "P1 got the kill-on-sight warning")
Check(heard, "P2 was told where P1 spotted him")
local kosSound = false
for _, snd in ipairs(S1.sounds) do if snd == "detected-kos" then kosSound = true end end
Check(kosSound, "P1 heard the kill-on-sight sound")
Check(#S2.sounds == 0, "P2 heard no sound for P1's sighting (" .. table.concat(S2.sounds, " ") .. ")")
Check(S2.ns.Get(S2.ns.Key("Gankboy", "Forever")).c == "ROGUE", "the class P1 saw reached P2's list")
Check(S1.ns.nearby[S1.ns.Key("Gankboy", "Forever")] ~= nil, "he's in P1's nearby list")
S1.log = {}
Fire(S1, "NAME_PLATE_UNIT_ADDED", "nameplate1") Run(5)
local again = false
for _, l in ipairs(S1.log) do if l:find("KILL ON SIGHT") then again = true end end
Check(not again, "no second warning within the cooldown")
units.nameplate2 = { name = "Randomhorde", class = "MAGE", level = 40 }
Fire(S1, "NAME_PLATE_UNIT_ADDED", "nameplate2") Run(1)
local list = S1.ns.NearbyList()
Check(#list == 2 and list[1].e ~= nil, "nearby list shows both, the listed one first")
-- secret names are skipped, not errors
env.issecretvalue = function(v) return v == "Gankboy" end
Fire(S1, "NAME_PLATE_UNIT_ADDED", "nameplate1") Run(1)
env.issecretvalue = nil
local SlashCmd = S1.env.SlashCmdList.BHGKILLLIST
SlashCmd("status") SlashCmd("check Gankboy") SlashCmd("add Someone being rude") SlashCmd("remove Someone") SlashCmd("help")
Run(10)
Check(not Has(S2, "Someone") and S2.db.entries[S2.ns.Key("Someone", "Forever")] ~= nil, "slash add + remove reached P2 as a removal")

---------------------------------------------------------------- scenario 8
print("== 8. seen enemies, wins and losses, kept between sessions")
local W = online["P3"]
local wenv = W.env
local wunits = {
  nameplate1 = { name = "Stabby", class = "ROGUE", level = 60 },
  nameplate2 = { name = "Frosty", class = "MAGE", level = 59 },
}
local dead, targets, inCombat = {}, {}, false
local function U(u) return wunits[u] end
wenv.UnitExists = function(u) return U(u) ~= nil end
wenv.UnitIsPlayer = function(u) return U(u) ~= nil end
wenv.UnitName = function(u) if u == "player" then return "P3" end return U(u) and U(u).name end
wenv.UnitClass = function(u) return "x", U(u) and U(u).class end
wenv.UnitLevel = function(u) return U(u) and U(u).level end
wenv.UnitIsEnemy = function() return true end
wenv.UnitIsDeadOrGhost = function(u) return U(u) and dead[U(u).name] or false end
wenv.UnitAffectingCombat = function() return inCombat end
wenv.UnitIsUnit = function(a, b)
  if b == "player" then local who = a:match("^(.-)target$") return who and targets[who] == "player" or false end
  if b == "target" then return targets.player == a end
  return false
end
wenv.GetRealZoneText = function() return "Stranglethorn Vale" end
wenv.C_NamePlate = { GetNamePlates = function()
  local list = {}
  for u in pairs(wunits) do list[#list+1] = { namePlateUnitToken = u } end
  return list
end }
W.sounds = {}
Run(1)
local sk, fk = W.ns.Key("Stabby", "Forever"), W.ns.Key("Frosty", "Forever")
Check(W.ns.Enemy(sk) and W.ns.Enemy(fk), "both enemies are in the seen database")
Check(W.ns.Enemy(sk).times == 1, "seen once so far (" .. tostring(W.ns.Enemy(sk).times) .. ")")
local nearbySounds = 0
for _, snd in ipairs(W.sounds) do if snd == "detected-nearby" then nearbySounds = nearbySounds + 1 end end
Check(nearbySounds >= 1, "the nearby sound played for new enemies")
-- I fight Frosty and he dies
inCombat = true targets.player = "nameplate2" Run(1)
dead.Frosty = true Run(1)
Check(W.ns.Enemy(fk).w == 1, "killing an enemy I was fighting counts a win (" .. tostring(W.ns.Enemy(fk).w) .. ")")
Run(2)
Check(W.ns.Enemy(fk).w == 1, "the same kill isn't counted twice")
-- Stabby didn't fight me and dies: no win
dead.Stabby = true Run(1)
Check(W.ns.Enemy(sk).w == 0, "an enemy I wasn't fighting dying isn't a win")
dead.Stabby = nil
-- Stabby targets me, I die
targets.nameplate1 = "player" Run(1)
W.log = {}
Fire(W, "PLAYER_DEAD") Run(1)
Check(W.ns.Enemy(sk).l == 1, "dying while Stabby targets me counts a loss")
local said = false
for _, l in ipairs(W.log) do if l:find("killed by") and l:find("Stabby") then said = true end end
Check(said, "chat says who killed me")
local saved = W.db
Logout("P3")
W = Login("P3", saved)
Check(W.ns.Enemy(sk) and W.ns.Enemy(sk).l == 1 and W.ns.Enemy(fk).w == 1, "the record survives logging out and back in")
local w, l, n = W.ns.Totals()
Check(w == 1 and l == 1 and n >= 2, "totals: 1 win, 1 loss (" .. w .. ", " .. l .. ", " .. n .. ")")
Run(61)
Fire(W, "CHAT_MSG_COMBAT_HONOR_GAIN", "Stabby dies, honorable kill Rank: Scout (Estimated Honor Points: 12)")
Check(W.ns.Enemy(sk).w == 1, "an honourable kill counts as a win")
Fire(W, "CHAT_MSG_COMBAT_HONOR_GAIN", "Stabby dies, honorable kill Rank: Scout (Estimated Honor Points: 12)")
Check(W.ns.Enemy(sk).w == 1, "and isn't counted twice")

---------------------------------------------------------------- scenario 8b
print("== 8b. the nearby window steps aside in dungeons and raids")
local D = Login("Delver") Run(2)
local nearbyFrame
for _, f in ipairs(D.frames) do if f.name == "BHGKillListNearby" then nearbyFrame = f end end
local function Enter(kind)
  D.env.IsInInstance = function() return kind ~= "none", kind end
  Fire(D, "PLAYER_ENTERING_WORLD")
  return nearbyFrame.shown
end
Check(nearbyFrame and nearbyFrame.shown, "shown in the open world")
Check(not Enter("party"), "hidden in a dungeon")
Check(Enter("pvp"), "shown in a battleground")
Check(Enter("arena"), "shown in an arena")
Check(not Enter("raid"), "hidden in a raid")
D.ns.SetSetting("hideInDungeons", false)
Check(nearbyFrame.shown, "with the option off, it stays up in a raid")
D.ns.SetSetting("hideInDungeons", true)
Check(not nearbyFrame.shown, "option back on: hidden again")
Check(Enter("none"), "back in the open world it comes back")
D.ns.SetSetting("nearby", false) Enter("party")
Check(not Enter("none"), "if you hid it yourself, leaving a dungeon doesn't bring it back")
D.env.issecretvalue = function(v) return v == "party" end
D.ns.SetSetting("nearby", true)
Check(Enter("party"), "an unreadable instance type counts as the open world")
D.env.issecretvalue = nil
Logout("Delver")

---------------------------------------------------------------- scenario 9
if KUI_FILE then
print("== 9. K-UI's KoS module: mixed guild, and both installed on one PC")
for n in pairs(online) do Logout(n) end
-- Someone used the standalone addon for a while.
local Old = Login("Oldtimer", nil, "standalone")
Add(Old, "Ganker", "old grudge") Add(Old, "Camper", "camps the flight path")
Old.ns.AddBlack({ name = "Leaverguy", realm = "Forever" }, "left mid-run")
Old.ns.db.enemies[Old.ns.Key("Ganker", "Forever")] = { n = "Ganker", r = "Forever", w = 4, l = 2, times = 9, first = 1, last = 2 }
Old.ns.SetSetting("nearbyAll", false)
Run(10) Logout("Oldtimer")
-- A K-UI user and a standalone user in the guild.
local K = Login("Kuser", nil, "kui")
local S = Login("Suser", nil, "standalone")
Run(120)
Check(K.ns.embedded and K.ns.active, "K-UI's module runs for a K-UI-only player")
local tocVersion = io.open(DIR .. "/BHG-Kill-List.toc"):read("*a"):match("## Version:%s*(%S+)")
Check(K.ns.VERSION == tocVersion, "K-UI's copy knows the Kill List's version (" .. tostring(K.ns.VERSION) .. ")")
Add(K, "Fromkui", "added in K-UI") Run(5)
Check(Has(S, "Fromkui"), "a K-UI add reaches a standalone user")
Add(S, "Fromstandalone", "added standalone") Run(5)
Check(Has(K, "Fromstandalone"), "a standalone add reaches a K-UI user")
-- Oldtimer installs K-UI next to the standalone addon.
local hellosBefore = 0
local B = Login("Oldtimer", nil, "both")
Check(B.kui.active and not B.standalone.active and B.standalone.slaved, "with both installed, K-UI runs and the standalone addon sleeps")
Check(B.ns == B.kui and Has(B, "Ganker") and Has(B, "Camper"), "K-UI brought in the standalone addon's list")
Check(B.kui.GetBlack(B.kui.Key("Leaverguy", "Forever")) ~= nil, "and its Blacklist")
local rec = B.kui.Enemy(B.kui.Key("Ganker", "Forever"))
Check(rec and rec.w == 4 and rec.l == 2 and rec.times == 9, "and its wins and losses")
Check(B.kui.Setting("nearbyAll") == false, "and its settings")
B.sentCount = 0
Run(120)
Check(AllSame(), "Oldtimer, Kuser and Suser all have the same list")
Check(Has(B, "Fromkui") and Has(B, "Fromstandalone"), "Oldtimer caught up with both")
-- Its hello (players, guilds, Blacklist) and a bucket each for its
-- players and its Blacklist (B + D, B + F): one copy talking, not two.
Check(B.sentCount <= 7, "only one copy talks for Oldtimer (" .. B.sentCount .. " messages)")
local slash = B.env.SlashCmdList.BHGKILLLIST
B.log = {}
slash("status")
local fromKui = false
for _, l in ipairs(B.log) do if l:find("K-UI's kill list") and l:find("asleep") then fromKui = true end end
Check(fromKui, "/kos is answered by K-UI's module")
slash("off") Run(1)
Logout("Oldtimer")
B = Login("Oldtimer", nil, "both")
Check(B.standalone.active and not B.kui.active, "after /kos off, the standalone addon runs instead")
Run(60)
Check(AllSame(), "and stays in sync with the guild")
B.log = {}
B.env.SlashCmdList.BHGKILLLIST("on") Run(1)
Logout("Oldtimer")
B = Login("Oldtimer", nil, "both")
Check(B.kui.active and not B.standalone.active, "/kos on hands it back to K-UI")
Logout("Oldtimer")
B = Login("Oldtimer", nil, "kui")
B.env.SlashCmdList.BHGKILLLIST("off") Run(1) Logout("Oldtimer")
B = Login("Oldtimer", nil, "kui") Run(1)
B.log = {}
B.env.SlashCmdList.BHGKILLLIST("") Run(1)
local offNote = false
for _, l in ipairs(B.log) do if l:find("/kos on") then offNote = true end end
Check(not B.kui.active and offNote, "K-UI alone, turned off: /kos only offers /kos on")
B.env.SlashCmdList.BHGKILLLIST("on") Run(1) Logout("Oldtimer")
B = Login("Oldtimer", nil, "kui")
Check(B.kui.active, "and /kos on brings it back")
end

---------------------------------------------------------------- scenario 10
print("== 10. whole guilds on the list")
for n in pairs(online) do Logout(n) end
local G1, G2 = Login("Guildy1"), Login("Guildy2")
Run(60)
local function Slash(c, msg) c.env.SlashCmdList.BHGKILLLIST(msg) end
local function Said(c, ...)
  for _, l in ipairs(c.log) do
    local all = true
    for _, bit in ipairs({ ... }) do if not l:find(bit, 1, true) then all = false end end
    if all then return true end
  end
  return false
end
G2.log = {}
Slash(G1, "guild add <red hand>: camps the flight path") Run(5)
local rh = G2.ns.GetGuild("Red Hand")
Check(rh and rh.w == "camps the flight path", "a guild added by slash reached a guildmate with its reason")
Check(Said(G2, "whole guild", "red hand", "Guildy1"), "and they were told in chat")
Check(G1.ns.Count() == G2.ns.Count(), "a guild doesn't count as a player")
local G3 = Login("Guildy3") Run(120)
Check(G3.ns.GetGuild("RED HAND") ~= nil, "a fresh install caught up with the guild list")
Check(AllSame(), "all three in sync, guilds included")
Logout("Guildy2")
Slash(G1, "guild remove Red Hand") Run(5)
Slash(G3, "guild add Blood Pact") Run(5)
G2 = Login("Guildy2") Run(120)
Check(not G2.ns.GetGuild("Red Hand"), "a guild removed while someone was offline stays removed")
Check(G2.ns.GetGuild("Blood Pact") ~= nil, "and the guild added while they were away arrived")
Check(AllSame(), "all three in sync")
Slash(G2, "guild add red hand: back again") Run(5)
Check(G1.ns.GetGuild("Red Hand") and G1.ns.GetGuild("Red Hand").w == "back again", "a guild can go back on the list")
-- Seeing members.
local gunits = {
  nameplate1 = { name = "Grunty", class = "WARRIOR", level = 60, guild = "Red Hand", faction = "Horde" },
  nameplate2 = { name = "Grunta", class = "SHAMAN", level = 58, guild = "Red Hand", faction = "Horde" },
  nameplate3 = { name = "Lostsoul", class = "PRIEST", level = 60, guild = "Red Hand", faction = "Alliance" },
  nameplate4 = { name = "Nobody", class = "MAGE", level = 30, faction = "Horde" },
}
local genv = G1.env
local function GU(u) return gunits[u] end
genv.UnitExists = function(u) return GU(u) ~= nil end
genv.UnitIsPlayer = function(u) return GU(u) ~= nil end
genv.UnitIsUnit = function() return false end
genv.UnitName = function(u) if u == "player" then return "Guildy1" end return GU(u) and GU(u).name end
genv.UnitClass = function(u) return "x", GU(u) and GU(u).class end
genv.UnitLevel = function(u) return GU(u) and GU(u).level end
genv.GetGuildInfo = function(u) if u == "player" then return "Better Homes" end return GU(u) and GU(u).guild end
genv.UnitIsEnemy = function(_, u) return GU(u) and GU(u).faction == "Horde" end
genv.UnitFactionGroup = function(u) if u == "player" then return "Alliance" end return GU(u) and GU(u).faction end
G1.log, G1.sounds, G2.log, G2.sounds = {}, {}, {}, {}
local function KosSounds() local n = 0 for _, x in ipairs(G1.sounds) do if x == "detected-kos" then n = n + 1 end end return n end
Fire(G1, "NAME_PLATE_UNIT_ADDED", "nameplate1") Run(1)
Check(Said(G1, "KILL ON SIGHT", "Grunty", "Red Hand", "back again"), "a member of a listed guild sets off the warning, with the guild's reason")
Check(KosSounds() == 1, "with the warning sound")
Check(G1.ns.Get(G1.ns.Key("Grunty", "Forever")) == nil, "the member isn't added as a player")
Fire(G1, "NAME_PLATE_UNIT_ADDED", "nameplate2") Run(1)
Check(Said(G1, "KILL ON SIGHT", "Grunta"), "a second member gets their own line in chat")
Check(KosSounds() == 1, "but no second sound within a minute (" .. KosSounds() .. ")")
Run(5)
Check(not Said(G2, "spotted"), "members of a listed guild aren't announced to the guild")
Check(G2.ns.db.guilds["red hand"].n == "Red Hand", "the game's spelling of the guild name reached everyone")
Fire(G1, "NAME_PLATE_UNIT_ADDED", "nameplate3") Fire(G1, "NAME_PLATE_UNIT_ADDED", "nameplate4") Run(1)
Check(not Said(G1, "KILL ON SIGHT", "Lostsoul"), "someone on our side in a guild with the same name doesn't warn")
local glist = G1.ns.NearbyList()
local listedRows = 0
for _, item in ipairs(glist) do if item.g then listedRows = listedRows + 1 end end
Check(listedRows == 2 and glist[1].g and glist[2].g and not glist[3].g, "the nearby list marks both members and puts them on top")
G1.log = {}
Slash(G1, "guild add Better Homes")
Check(G1.ns.GetGuild("Better Homes") == nil and Said(G1, "on our side"), "our own guild can't go on the list")
Slash(G1, "guild reason Red Hand: kills herbalists") Run(5)
Check(G3.ns.GetGuild("Red Hand").w == "kills herbalists", "a new reason reached everyone")
Slash(G1, "guilds") Slash(G1, "check Red Hand") Slash(G1, "guild") Slash(G1, "guild help") Slash(G1, "status")
Check(Said(G1, "kills herbalists"), "/kos guilds lists them")
Slash(G1, "guild remove red hand") Run(5)
Check(not G3.ns.GetGuild("Red Hand"), "a guild removed by slash comes off everyone's list")
Check(AllSame(), "all three in sync at the end")

if OLD_DIR then
print("== 10b. an older version in the same guild")
local O = Login("Oldversion", nil, "old")
Run(120)
Add(O, "Fromold", "old add") Run(5)
Check(Has(G1, "Fromold"), "an add from the older version reaches this one")
Add(G1, "Fromnew", "new add") Slash(G1, "guild add Horde Elite") Run(5)
Check(Has(O, "Fromnew"), "an add from this version reaches the older one")
Check(AllSame(nil, true), "everyone has the same players")
Check(G2.ns.GetGuild("Horde Elite") ~= nil, "guilds still spread among the newer ones")
local before10 = totalMessages
Logout("Guildy2") G2 = Login("Guildy2") Run(120)
Check(totalMessages - before10 <= 3, "an in-sync login costs just its hello, older version online (" .. (totalMessages - before10) .. ")")
end

---------------------------------------------------------------- scenario 11
print("== 11. the guild Blacklist")
for n in pairs(online) do Logout(n) end
local L1, L2 = Login("Black1"), Login("Black2")
Run(60)
local function BKey(name) return L1.ns.Key(name, "Forever") end
local function Lines(c, ...)
  local n = 0
  for _, l in ipairs(c.log) do
    local all = true
    for _, bit in ipairs({ ... }) do if not l:find(bit, 1, true) then all = false end end
    if all then n = n + 1 end
  end
  return n
end
local killBefore = L2.ns.Count()
L2.log = {}
Slash(L1, "black Quitter left at the last boss") Run(5)
local q = L2.ns.GetBlack(BKey("Quitter"))
Check(q and q.w == "left at the last boss", "a blacklisted player reached a guildmate with the reason")
Check(Said(L2, "Quitter", "guild Blacklist", "Black1"), "and they were told in chat")
Check(L2.ns.Count() == killBefore and not Has(L2, "Quitter"), "the Blacklist doesn't add to the kill list")
Add(L1, "Bothlists", "kos") L1.ns.AddBlack({ name = "Bothlists", realm = "Forever" }, "also a leaver") Run(5)
L1.ns.RemoveBlack(BKey("Bothlists")) Run(5)
Check(Has(L2, "Bothlists") and not L2.ns.GetBlack(BKey("Bothlists")), "taking someone off the Blacklist leaves them on the kill list")
Slash(L1, "black reason Quitter ninja looted") Run(5)
Check(L2.ns.GetBlack(BKey("Quitter")).w == "ninja looted", "a new reason reached the guildmate")
Logout("Black2")
Slash(L1, "black Ragequit quit after one wipe") Slash(L1, "black remove Quitter") Run(5)
local L3 = Login("Black3")
L2 = Login("Black2") Run(120)
Check(L2.ns.GetBlack(BKey("Ragequit")) and not L2.ns.GetBlack(BKey("Quitter")), "someone offline caught up with an add and a removal")
Check(L3.ns.GetBlack(BKey("Ragequit")) ~= nil, "a fresh install caught up with the Blacklist")
Check(AllSame(), "all three in sync, Blacklist included")

-- Warnings: in your group, an invite, chat.
local env1 = L1.env
local group, inDungeon, popups = {}, false, {}
env1.GetNumGroupMembers = function() return #group > 0 and #group + 1 or 0 end
env1.IsInRaid = function() return false end
env1.UnitName = function(u)
  if u == "player" then return "Black1" end
  local i = u:match("^party(%d)$")
  return i and group[tonumber(i)] or nil
end
env1.UnitClass = function() return "Warrior", "WARRIOR" end
env1.IsInInstance = function() return inDungeon, inDungeon and "party" or "none" end
env1.GetRealZoneText = function() return "The Deadmines" end
env1.StaticPopup_Show = function(which, a, _, data) popups[#popups+1] = { which = which, text = a, data = data } end
local function Group(...)
  group = { ... }
  Fire(L1, "GROUP_ROSTER_UPDATE")
end
L1.log = {}
Group("Ragequit", "Healer")
Check(Said(L1, "BLACKLISTED", "Ragequit", "is in your group", "quit after one wipe"), "a blacklisted player in your group is pointed out, with the reason")
Group("Ragequit", "Healer", "Third")
Check(Lines(L1, "BLACKLISTED", "Ragequit") == 1, "only once while they stay in the group")
Fire(L1, "PARTY_INVITE_REQUEST", "Ragequit")
Check(Said(L1, "BLACKLISTED", "Ragequit", "invited you"), "an invite from them is pointed out")
L1.log = {}
Fire(L1, "CHAT_MSG_CHANNEL", "LFM deadmines", "Ragequit-Forever", "", "4. LookingForGroup", "", "", 0, 4, "LookingForGroup")
Check(Said(L1, "BLACKLISTED", "Ragequit", "LookingForGroup"), "talking in LookingForGroup is pointed out")
Fire(L1, "CHAT_MSG_WHISPER", "inv?", "Ragequit-Forever")
Check(Lines(L1, "BLACKLISTED") == 1, "chat is pointed out at most every ten minutes")
L1.ns.SetSetting("blackWarn", false) L1.log = {}
Fire(L1, "PARTY_INVITE_REQUEST", "Ragequit") Run(40)
Fire(L1, "PARTY_INVITE_REQUEST", "Ragequit")
Check(not Said(L1, "BLACKLISTED"), "the warning can be turned off")
L1.ns.SetSetting("blackWarn", true)

-- Someone leaving your dungeon group.
local function Leaver(name)
  for _, pop in ipairs(popups) do
    if pop.which == "BHGKOS_BLACK_LEAVER" and pop.data.info.name == name then return pop end
  end
end
Group()
inDungeon = true
Group("Tank", "Healer", "Dpsone", "Dpstwo")
Group("Tank", "Healer", "Dpsone")
Fire(L1, "CHAT_MSG_SYSTEM", "Dpstwo leaves the party.")
Run(3)
Check(not Leaver("Dpstwo"), "not asked straight away")
Run(10)
local pop = Leaver("Dpstwo")
Check(pop and #popups == 1, "asked once whether to blacklist someone who left the dungeon group (" .. #popups .. ")")
Check(pop and pop.data.reason == "Left The Deadmines early", "with a reason filled in (" .. tostring(pop and pop.data.reason) .. ")")
Check(not L1.ns.GetBlack(BKey("Dpstwo")), "nobody is added without saying yes")
local dialog = { GetEditBox = function() return { GetText = function() return pop.data.reason end } end }
env1.StaticPopupDialogs.BHGKOS_BLACK_LEAVER.OnAccept(dialog, pop.data) Run(5)
Check(L2.ns.GetBlack(BKey("Dpstwo")) and L2.ns.GetBlack(BKey("Dpstwo")).w == "Left The Deadmines early", "saying yes blacklists them for the guild")
popups = {}
Group("Tank", "Healer") Run(2) Group("Tank") Run(20)
Check(#popups == 0, "two leaving together (the end of a run) asks about no one")
inDungeon = false
Group("Tank", "Healer", "Dpsone") Group("Tank", "Healer") Run(20)
Check(#popups == 0, "someone leaving outside a dungeon isn't asked about")
inDungeon = true
env1.UnitName = function(u) if u == "player" then return "Black1" end end -- names hidden in the instance
Group("Hidden1", "Hidden2", "Hidden3")
Fire(L1, "CHAT_MSG_SYSTEM", "Sneaky leaves the party.") Run(15)
Check(Leaver("Sneaky") ~= nil, "with names hidden, the game's chat line still says who left")
Group() Run(1)

Check(#(L1.sounds or {}) == 0 and #(L2.sounds or {}) == 0, "the Blacklist plays no sounds")

-- Who can't go on it.
popups = {}
env1.GetNumGuildMembers = function() return 1 end
env1.GetGuildRosterInfo = function() return "Black2-Forever" end
Fire(L1, "GUILD_ROSTER_UPDATE")
L1.log = {}
Slash(L1, "black Black2 test")
Check(not L1.ns.GetBlack(BKey("Black2")) and Said(L1, "in our guild"), "a guildmate can't go on it")
L1.ns.AddBlackWithMessage({ name = "Orcy", realm = "Forever", ally = false })
Check(not L1.ns.GetBlack(BKey("Orcy")) and Said(L1, "other side"), "an enemy can't go on it")
Slash(L1, "black") Slash(L1, "black list") Slash(L1, "blacklist") Slash(L1, "check Ragequit") Slash(L1, "status") Slash(L1, "help")
Check(Said(L1, "Ragequit", "on the guild Blacklist"), "/kos check finds a blacklisted player")
local win
for _, f in ipairs(L1.frames) do if f.name == "BHGKillListWindow" then win = f end end
for _, page in ipairs({ "black", "kos", "seen", "black" }) do L1.ns.ShowPage(page) win.scripts.OnShow(win) end
Check(win.shown, "the list window shows the Blacklist page")
Run(10)
Check(AllSame(), "all three in sync at the end")
if OLD_DIR then
  local O = Login("Oldversion", nil, "old")
  Run(120)
  L1.ns.AddBlack({ name = "Lateleaver", realm = "Forever" }, "x") Add(L1, "Lateenemy", "y") Run(10)
  Check(Has(O, "Lateenemy") and AllSame(nil, true), "an older version keeps syncing players next to the Blacklist")
end

local errs = 0
for _, c in pairs(clients) do if c.ns then errs = errs + Errors(c) end end
Check(errs == 0, "no Lua errors caught in any client")
print(("== %d failure(s), %d messages in all"):format(fails, totalMessages))
os.exit(fails == 0 and 0 or 1)
