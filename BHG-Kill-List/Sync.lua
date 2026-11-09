--[[
BH&G Kill List: Sync.lua

Keeps every guild member's list the same, over hidden addon messages on
the GUILD channel. The send queue and the restricted-chat checks come
from K-Targeter in Kain-UI Forever.

Messages (prefix BHGKOS1, one line each, at most 250 bytes):
  U~<entry>            a change someone just made (add, remove, new reason)
  H~<16 digests>       "hello": what my list looks like, bucket by bucket
  B~<i>~<digest>       "here is my bucket i", followed by its D messages
  D~<entry>^<entry>... entries (several per message)
  S~<name>~<realm>~<zone>   "I just spotted this listed player here"

How a login catches up:
  1. A few seconds after logging in you send H with your 16 digests.
  2. Everyone online compares; for each bucket that differs, after a
     short random wait, they send B + D for it. If someone else already
     sent the same bucket with the same digest, the rest stay quiet, so
     a big guild doesn't answer twenty times over.
  3. Everyone merges whatever they hear (the newest change of each
     player wins, see ns.IsNewer). Once the messages stop, anyone whose
     bucket still differs from a B they heard had something the sender
     didn't, and sends theirs back the same way.
After that everyone online has the same list, and new changes go out
as U messages the moment they're made.
--]]

local _, ns = ...
local Plain, PlainText = ns.Plain, ns.PlainText

local COMM_PREFIX = "BHGKOS1"
local CHANNEL = "GUILD"
local MAX_MESSAGE = 250
local SEND_INTERVAL = 0.3     -- seconds between messages (the client drops faster bursts)
local SEND_QUEUE_MAX = 2000
local HELLO_AFTER_LOGIN = 8   -- seconds (plus up to 7 random) before the first hello
local HELLO_EVERY = 20 * 60   -- re-check now and then, in case something was missed
local QUIET_TIME = 4          -- seconds of no sync traffic before checking what to send back
local BUCKET_RESEND = 20      -- never send the same bucket twice within this many seconds

ns.sync = {
	sent = 0, received = 0, merged = 0, queuedPeak = 0,
	lastHello = nil, peers = {},
}
local stats = ns.sync

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
	pcall(C_ChatInfo.RegisterAddonMessagePrefix, COMM_PREFIX)
elseif RegisterAddonMessagePrefix then
	pcall(RegisterAddonMessagePrefix, COMM_PREFIX)
end

-----------------------------------------------------------------------
-- Send queue (from K-Targeter): paced, and a throttled message is kept
-- and tried again instead of being lost.
-----------------------------------------------------------------------

local sendQueue, sendTicker = {}, nil

local function CommRestricted()
	local ci = C_ChatInfo
	if not ci then return true end
	for _, name in ipairs({ "InChatMessagingLockdown", "AreOutgoingAddonChatMessagesRestricted" }) do
		if ci[name] then
			local ok, restricted = pcall(ci[name])
			if ok and Plain(restricted) == true then return true end
		end
	end
	return false
end
ns.CommRestricted = CommRestricted

local function SendFunc()
	return (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
end

local OnQueueDrained -- set below

local function PumpSendQueue()
	if #sendQueue == 0 then
		if sendTicker then sendTicker:Cancel() sendTicker = nil end
		OnQueueDrained()
		return
	end
	if CommRestricted() or not IsInGuild() then return end -- keep the queue; try again next tick
	local item = sendQueue[1]
	local ok, result = pcall(SendFunc(), COMM_PREFIX, item.text, CHANNEL)
	local results = Enum and Enum.SendAddonMessageResult
	if ok and results and result ~= nil
		and (result == results.AddonMessageThrottle or result == results.ChannelThrottle) then
		return -- throttled: keep it at the head and retry next tick
	end
	table.remove(sendQueue, 1)
	stats.sent = stats.sent + 1
end

-- bucket: which list bucket a message belongs to, so the rest of it can
-- be dropped if someone else turns out to be sending the same thing.
local function Send(text, bucket)
	if not SendFunc() or not (C_Timer and C_Timer.NewTicker) then return end
	if #text > MAX_MESSAGE then return end
	if #sendQueue >= SEND_QUEUE_MAX then return end
	sendQueue[#sendQueue + 1] = { text = text, bucket = bucket }
	if #sendQueue > stats.queuedPeak then stats.queuedPeak = #sendQueue end
	if not sendTicker then
		sendTicker = C_Timer.NewTicker(SEND_INTERVAL, PumpSendQueue)
		PumpSendQueue() -- the first one goes straight away
	end
end

local function DropQueuedBucket(i)
	for idx = #sendQueue, 1, -1 do
		if sendQueue[idx].bucket == i then table.remove(sendQueue, idx) end
	end
end

function ns.QueueLength() return #sendQueue end

-----------------------------------------------------------------------
-- Building messages
-----------------------------------------------------------------------

local function HashList()
	local out = {}
	for i, h in ipairs(ns.BucketHashes()) do out[i] = ns.ToB36(h) end
	return table.concat(out, ",")
end

function ns.SendUpdate(e)
	if not IsInGuild() then return end
	Send("U~" .. ns.Serialize(e))
end

function ns.SendHello()
	if not IsInGuild() then return false end
	stats.lastHello = GetTime()
	Send("H~" .. HashList())
	return true
end

local lastBucketSent = {}
local inFlight = {} -- bucket -> the digest I announced for it, while its messages go out

local function SendBucket(i)
	local digest = ns.BucketHashes()[i]
	lastBucketSent[i] = GetTime()
	inFlight[i] = digest
	Send("B~" .. i .. "~" .. ns.ToB36(digest), i)
	local chunk, size = {}, 2
	for _, e in ipairs(ns.EntriesInBucket(i)) do
		local s = ns.Serialize(e)
		if size + #s + 1 > MAX_MESSAGE and #chunk > 0 then
			Send("D~" .. table.concat(chunk, "^"), i)
			chunk, size = {}, 2
		end
		if 2 + #s <= MAX_MESSAGE then
			chunk[#chunk + 1] = s
			size = size + #s + 1
		end
	end
	if #chunk > 0 then Send("D~" .. table.concat(chunk, "^"), i) end
end

function ns.SendSighting(e, zone)
	if not IsInGuild() then return end
	Send("S~" .. e.n .. "~" .. e.r .. "~" .. (ns.Clean(zone, 60) or ""))
end

-----------------------------------------------------------------------
-- Deciding what to send
--
-- offers[i] = set of digests heard for bucket i since I decided to send
-- it. Buckets go out one at a time, each after a random wait; if in the
-- meantime someone announces bucket i with the same digest as mine, they
-- are already sending exactly what I would, and I drop it. That keeps a
-- big guild from answering a login twenty times over.
-----------------------------------------------------------------------

local offers, offerTimer = {}, nil
local announced = {} -- bucket -> digests heard, for the send-back check
local quietTimer = nil

local RunOffer

local function ScheduleOffer()
	if offerTimer or #sendQueue > 0 or not next(offers) or not C_Timer then return end
	offerTimer = C_Timer.NewTimer(1 + math.random() * 5, RunOffer)
end

RunOffer = function()
	offerTimer = nil
	if #sendQueue > 0 then return end -- busy; OnQueueDrained schedules the next one
	local mine = ns.BucketHashes()
	local order = {}
	for i in pairs(offers) do order[#order + 1] = i end
	table.sort(order)
	for _, i in ipairs(order) do
		local heardSame = offers[i][mine[i]]
		local recently = lastBucketSent[i] and (GetTime() - lastBucketSent[i]) < BUCKET_RESEND
		offers[i] = nil
		if not heardSame and not recently then
			SendBucket(i)
			return
		end
	end
end

OnQueueDrained = function()
	inFlight = {}
	ScheduleOffer()
end

local function Offer(i)
	if not offers[i] then offers[i] = {} end
	ScheduleOffer()
end

-- Once things go quiet: anyone who announced a bucket that still differs
-- from mine (after merging what they sent) is missing something of mine.
local function CheckSendBack()
	quietTimer = nil
	local mine = ns.BucketHashes()
	local heard = announced
	announced = {}
	for i, digests in pairs(heard) do
		for digest in pairs(digests) do
			if digest ~= mine[i] then
				Offer(i)
				break
			end
		end
	end
	ns.Fire("SYNC_SETTLED")
end

local function TrafficSeen()
	if quietTimer then quietTimer:Cancel() end
	if C_Timer then quietTimer = C_Timer.NewTimer(QUIET_TIME, CheckSendBack) end
end

-----------------------------------------------------------------------
-- Receiving
-----------------------------------------------------------------------

local function IsMe(sender)
	if type(sender) ~= "string" then return true end
	local me = ns.MyFullName():lower()
	local s = sender:lower()
	if not s:find("-", 1, true) then s = s .. "-" .. ns.MyRealm():lower() end
	return s == me
end

local function Merge(s, sender)
	local e = ns.Deserialize(s)
	if not e then return end
	if ns.MergeIncoming(e) then
		stats.merged = stats.merged + 1
		ns.lastMergeFrom = sender
	end
end

local function OnMessage(text, sender)
	stats.received = stats.received + 1
	local kind, body = text:match("^(%u)~(.*)$")
	if not kind then return end
	stats.peers[sender] = GetTime()

	if kind == "U" then
		Merge(body, sender)

	elseif kind == "D" then
		ns.syncQuiet = true
		for s in (body .. "^"):gmatch("([^%^]*)%^") do
			if s ~= "" then Merge(s, sender) end
		end
		ns.syncQuiet = false
		TrafficSeen()

	elseif kind == "B" then
		local i, digest = body:match("^(%d+)~(%w+)$")
		i, digest = tonumber(i), digest and tonumber(digest, 36)
		if i and digest and i >= 1 and i <= ns.BUCKETS then
			announced[i] = announced[i] or {}
			announced[i][digest] = true
			if offers[i] then offers[i][digest] = true end
			-- Two of us started the same bucket at once: the one whose
			-- name sorts first carries on, the other stops.
			if inFlight[i] == digest and sender:lower() < ns.MyFullName():lower() then
				DropQueuedBucket(i)
				inFlight[i] = nil
			end
			TrafficSeen()
		end

	elseif kind == "H" then
		local theirs, n = {}, 0
		for d in body:gmatch("[^,]+") do
			n = n + 1
			theirs[n] = tonumber(d, 36)
		end
		if n ~= ns.BUCKETS then return end
		local mine = ns.BucketHashes()
		for i = 1, ns.BUCKETS do
			if theirs[i] ~= mine[i] then Offer(i) end
		end

	elseif kind == "S" then
		local name, realm, zone = body:match("^([^~]+)~([^~]+)~(.*)$")
		if name then
			ns.Fire("GUILD_SIGHTING", ns.Key(name, realm), PlainText(zone), sender)
		end
	end
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
	prefix, text, channel, sender = Plain(prefix), Plain(text), Plain(channel), Plain(sender)
	if prefix ~= COMM_PREFIX or type(text) ~= "string" or channel ~= CHANNEL then return end
	if not ns.db or IsMe(sender) then return end
	OnMessage(text, sender)
end)

-----------------------------------------------------------------------
-- Hello on login, and now and then after
-----------------------------------------------------------------------

local helloStarted = false
ns.On("PLAYER_ENTERING_WORLD", function()
	if helloStarted or not C_Timer then return end
	helloStarted = true
	local function TryHello(attempt)
		if ns.SendHello() then return end
		-- The guild roster can take a while to load after login.
		if attempt < 6 then
			C_Timer.After(10, function() TryHello(attempt + 1) end)
		end
	end
	C_Timer.After(HELLO_AFTER_LOGIN + math.random() * 7, function() TryHello(1) end)
	C_Timer.NewTicker(HELLO_EVERY, function() ns.SendHello() end)
end)

-- /kos sync: ask the guild to compare lists now.
function ns.SyncNow()
	return ns.SendHello()
end

-- Exposed for the offline test harness.
ns._sync = { OnMessage = OnMessage, Pump = PumpSendQueue, CheckSendBack = CheckSendBack, queue = sendQueue }
