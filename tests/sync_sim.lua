-- Offline test of BH&G Kill List: many players running the addon at
-- once on one simulated clock, talking over a simulated guild channel.
-- Checks that everyone's list ends up the same however they log in and
-- out, that a big guild doesn't flood the channel, that spotting a
-- listed player warns you and tells the guild, and that the seen-enemies
-- database counts wins and losses and survives a relog.
--
--   lua5.1 tests/sync_sim.lua BHG-Kill-List [seed] [throttle chance]
--
-- The throttle chance (0 to 1) makes that share of sends come back
-- "throttled", like the real client does under load.
local DIR = arg[1]
THROTTLE = tonumber(arg[3])
local FILES = { "Core.lua", "Sync.lua", "Detect.lua", "Stats.lua", "UI.lua", "Commands.lua" }

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
    CreateFrame = function() local f = NewFrame() frames[#frames+1] = f return f end,
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
      SendAddonMessage = function(prefix, text, channel)
        assert(#text <= 255, "message too long: " .. #text)
        if THROTTLE and math.random() < THROTTLE then return 3 end
        assert(channel == "GUILD")
        totalMessages = totalMessages + 1
        c.sentCount = (c.sentCount or 0) + 1
        bus[#bus+1] = { at = clock + 0.05, from = c, prefix = prefix, text = text }
        return 0
      end,
    },
    Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8 } },
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

local function Login(name, db)
  local c = clients[name] or { name = name }
  clients[name] = c
  c.log = {}
  c.alive = {}
  local env = MakeEnv(c)
  env.BHGKillListDB = db or c.db
  local ns = {}
  for _, file in ipairs(FILES) do
    local chunk = assert(loadfile(DIR .. "/" .. file))
    setfenv(chunk, env)
    chunk("BHG-Kill-List", ns)
  end
  c.env, c.ns = env, ns
  online[name] = c
  Fire(c, "ADDON_LOADED", "BHG-Kill-List")
  c.db = env.BHGKillListDB
  Fire(c, "PLAYER_ENTERING_WORLD")
  return c
end

local function Logout(name)
  local c = online[name]
  online[name] = nil
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

local function Fingerprint(c)
  local ns = c.ns
  local parts = {}
  for i, h in ipairs(ns.BucketHashes()) do parts[i] = h end
  return table.concat(parts, ",")
end

local function AllSame(list)
  local fp
  for _, c in pairs(list or online) do
    local f = Fingerprint(c)
    if fp and f ~= fp then return false end
    fp = f
  end
  return true
end

local function Errors(c)
  local n = 0
  for label, k in pairs(c.ns.errorCounts) do n = n + k print("  ERROR in " .. c.name .. " " .. label .. ": " .. k) end
  for _, l in ipairs(c.log) do if l:find("error") then print("  LOG " .. c.name .. ": " .. l) end end
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
Check(totalMessages - before6 <= 2, "an in-sync login costs just its hello")

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
      if r < 0.5 then Add(c, target, "r" .. math.random(1, 5))
      elseif r < 0.8 then c.ns.Remove(c.ns.Key(target, "Forever"))
      else c.ns.SetReason(c.ns.Key(target, "Forever"), "edit" .. math.random(100)) end
    end
  end
  Run(math.random(1, 40))
end
for _, n in ipairs(pool) do if not online[n] then Login(n) end end
Run(900)
Check(AllSame(), "all 6 in sync after everyone logs in")
local counts = {}
for _, n in ipairs(pool) do counts[#counts+1] = online[n].ns.Count() end
print("     counts: " .. table.concat(counts, " "))

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
S1.log = {} S2.log = {}
Fire(S1, "NAME_PLATE_UNIT_ADDED", "nameplate1") Run(5)
local warned, heard = false, false
for _, l in ipairs(S1.log) do if l:find("KILL ON SIGHT") and l:find("Gankboy") then warned = true end end
for _, l in ipairs(S2.log) do if l:find("Gankboy") and l:find("spotted by P1") and l:find("Goldshire") then heard = true end end
Check(warned, "P1 got the kill-on-sight warning")
Check(heard, "P2 was told where P1 spotted him")
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

local errs = 0
for _, c in pairs(clients) do if c.ns then errs = errs + Errors(c) end end
Check(errs == 0, "no Lua errors caught in any client")
print(("== %d failure(s), %d messages in all"):format(fails, totalMessages))
os.exit(fails == 0 and 0 or 1)
