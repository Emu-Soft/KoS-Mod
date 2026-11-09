--[[
BH&G Kill List: UI.lua

  * the warning banner when a listed player shows up
  * the nearby window (enemy players seen in the last minute, listed ones
    on top in red; left-click a row to target, right-click to add or
    remove)
  * the list window (/kos): search, add, edit reasons, remove, options

The nearby rows target with a click, which only secure buttons may do.
Secure buttons can't be shown, hidden, moved or changed in combat, so in
combat the rows keep the players they had and only their text updates;
anyone new is counted at the bottom and gets a row once combat ends.
The kill-on-sight warning itself works in combat either way.
--]]

local _, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ACCENT = { 0.88, 0.24, 0.24 }

local function Backdrop(f, alpha)
	if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
	f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
	f:SetBackdropColor(0.05, 0.05, 0.06, alpha or 0.9)
	f:SetBackdropBorderColor(0.25, 0.25, 0.28, 1)
end

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local function SavePos(f, key)
	local x, y = f:GetCenter()
	if x and y then ns.db.pos[key] = { x = x, y = y } end
end

local function RestorePos(f, key, point, rel, relPoint, dx, dy)
	f:ClearAllPoints()
	local p = ns.db.pos[key]
	if p and p.x and p.y then
		f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", p.x, p.y)
	else
		f:SetPoint(point, rel, relPoint, dx, dy)
	end
end

local function Text(parent, template, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	return fs
end

local function NameColor(classFile, name)
	local r, g, b = ns.ClassColor(classFile)
	return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, name)
end

-----------------------------------------------------------------------
-- Pop-up boxes
-----------------------------------------------------------------------

local function EditBoxOf(dialog)
	return dialog and ((dialog.GetEditBox and dialog:GetEditBox()) or dialog.editBox)
end

StaticPopupDialogs["BHGKOS_ADD_NAME"] = {
	text = "Add a player to the BH&G Kill List.\nName (or Name-Realm):",
	button1 = ACCEPT or "Accept",
	button2 = CANCEL or "Cancel",
	hasEditBox = 1,
	maxLetters = 60,
	timeout = 0, whileDead = 1, hideOnEscape = 1, exclusive = 1,
	OnShow = function(dialog) local eb = EditBoxOf(dialog) if eb then eb:SetText("") eb:SetFocus() end end,
	OnAccept = function(dialog)
		local eb = EditBoxOf(dialog)
		local name, realm = ns.SplitName(eb and eb:GetText() or "")
		if not name then ns.Print("that isn't a player name.") return end
		C_Timer.After(0.05, function() ns.AskReason({ name = name, realm = realm }) end)
	end,
	EditBoxOnEnterPressed = function(eb)
		local dialog = eb:GetParent()
		StaticPopupDialogs["BHGKOS_ADD_NAME"].OnAccept(dialog)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
}

StaticPopupDialogs["BHGKOS_REASON"] = {
	text = "Why is %s kill on sight? (optional)",
	button1 = ACCEPT or "Accept",
	button2 = CANCEL or "Cancel",
	hasEditBox = 1,
	maxLetters = 80,
	editBoxWidth = 300,
	timeout = 0, whileDead = 1, hideOnEscape = 1, exclusive = 1,
	OnShow = function(dialog, data)
		data = data or dialog.data
		local eb = EditBoxOf(dialog)
		if eb then
			local e = data and data.key and ns.Get(data.key)
			eb:SetText(e and e.w or "")
			eb:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		data = data or dialog.data
		local eb = EditBoxOf(dialog)
		local reason = eb and eb:GetText() or ""
		if not data then return end
		if data.edit then
			ns.SetReason(data.key, reason)
		else
			ns.AddWithMessage(data.info, reason)
		end
	end,
	EditBoxOnEnterPressed = function(eb)
		local dialog = eb:GetParent()
		StaticPopupDialogs["BHGKOS_REASON"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
}

StaticPopupDialogs["BHGKOS_REMOVE"] = {
	text = "Remove %s from the BH&G Kill List?\nThis takes them off everyone's list.",
	button1 = YES or "Yes",
	button2 = NO or "No",
	timeout = 0, whileDead = 1, hideOnEscape = 1, exclusive = 1,
	OnAccept = function(dialog, data)
		data = data or dialog.data
		if data and data.key then ns.RemoveWithMessage(data.key) end
	end,
}

function ns.AskReason(info)
	local shown = NameColor(info.class, info.name)
	StaticPopup_Show("BHGKOS_REASON", shown, nil, { info = info })
end

function ns.AskEditReason(key)
	local e = ns.Get(key)
	if not e then return end
	StaticPopup_Show("BHGKOS_REASON", ns.ColorName(e), nil, { key = key, edit = true })
end

function ns.AskRemove(key)
	local e = ns.Get(key)
	if not e then return end
	StaticPopup_Show("BHGKOS_REMOVE", ns.ColorName(e), nil, { key = key })
end

function ns.AskAddName()
	StaticPopup_Show("BHGKOS_ADD_NAME")
end

-----------------------------------------------------------------------
-- Warning banner
-----------------------------------------------------------------------

local banner = CreateFrame("Frame", "BHGKillListBanner", UIParent, BACKDROP_TEMPLATE)
banner:SetSize(420, 74)
banner:SetFrameStrata("HIGH")
banner:Hide()
Backdrop(banner, 0.8)
banner:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
banner.title = Text(banner, "GameFontNormalLarge", "CENTER")
banner.title:SetPoint("TOP", 0, -8)
banner.title:SetTextColor(1, 0.15, 0.15)
banner.title:SetText("KILL ON SIGHT")
banner.name = Text(banner, "GameFontHighlightLarge", "CENTER")
banner.name:SetPoint("TOP", banner.title, "BOTTOM", 0, -4)
banner.why = Text(banner, "GameFontHighlightSmall", "CENTER")
banner.why:SetPoint("TOP", banner.name, "BOTTOM", 0, -4)
banner.why:SetWidth(400)
banner:SetMovable(true)
banner:SetClampedToScreen(true)
banner:RegisterForDrag("LeftButton")
banner:SetScript("OnDragStart", function(self) if self.unlocked then self:StartMoving() end end)
banner:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePos(self, "banner") end)

local BANNER_TIME = 6
banner:SetScript("OnUpdate", function(self, elapsed)
	if self.unlocked then self:SetAlpha(1) return end
	self.left = (self.left or 0) - elapsed
	if self.left <= 0 then self:Hide() return end
	self:SetAlpha(math.min(1, self.left / 1.0))
end)

function ns.ShowBanner(e, level)
	local levelText = (level and level > 0) and ("  |cffcccccc" .. level .. "|r") or ""
	local guild = e.g and ("  |cff999999<" .. e.g .. ">|r") or ""
	banner.name:SetText(ns.ColorName(e) .. levelText .. guild)
	local why = e.w or "No reason given"
	banner.why:SetText(why .. "  |cff999999- added by " .. ns.ShortSender(e.b) .. "|r")
	banner.left = BANNER_TIME
	banner:SetAlpha(1)
	banner:Show()
end

function ns.ToggleBannerMove()
	banner.unlocked = not banner.unlocked
	banner:EnableMouse(banner.unlocked)
	if banner.unlocked then
		banner.name:SetText("Drag me where you want the warning")
		banner.why:SetText("Type /kos move again when you're done")
		banner:Show()
	else
		banner:Hide()
	end
	return banner.unlocked
end

-----------------------------------------------------------------------
-- Nearby window
-----------------------------------------------------------------------

local NEARBY_ROWS = 10
local ROW_H = 16
local NEARBY_W = 210

local nearby = CreateFrame("Frame", "BHGKillListNearby", UIParent, BACKDROP_TEMPLATE)
nearby:SetSize(NEARBY_W, 22)
nearby:SetFrameStrata("MEDIUM")
nearby:SetClampedToScreen(true)
nearby:SetMovable(true)
nearby:EnableMouse(true)
nearby:RegisterForDrag("LeftButton")
nearby:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
nearby:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePos(self, "nearby") end)
Backdrop(nearby, 0.75)
nearby:Hide()

nearby.title = Text(nearby, "GameFontNormalSmall")
nearby.title:SetPoint("TOPLEFT", 6, -5)
nearby.title:SetText("|cffe03c3cBH&G|r Nearby")
nearby.footer = Text(nearby, "GameFontDisableSmall")
nearby.footer:SetPoint("BOTTOMLEFT", 6, 4)

local rows = {}

local function RowMenu(row)
	local key, info = row.key, row.info
	if not key then return end
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(row, function(_, root)
			root:CreateTitle(info and info.name or "?")
			if ns.Get(key) then
				root:CreateButton("Edit reason", function() ns.AskEditReason(key) end)
				root:CreateButton("|cffe03c3cRemove from kill list|r", function() ns.AskRemove(key) end)
			else
				root:CreateButton("|cffe03c3cAdd to kill list|r", function() ns.AskReason(info) end)
			end
		end)
	elseif ns.Get(key) then
		ns.AskRemove(key)
	elseif info then
		ns.AskReason(info)
	end
end

for i = 1, NEARBY_ROWS do
	local row = CreateFrame("Button", "BHGKillListNearbyRow" .. i, nearby, "SecureActionButtonTemplate")
	row:SetSize(NEARBY_W - 8, ROW_H)
	row:SetPoint("TOPLEFT", nearby, "TOPLEFT", 4, -20 - (i - 1) * ROW_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetAttribute("type1", "macro")
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.25)
	row.name = Text(row, "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 3, 0)
	row.name:SetWidth(NEARBY_W - 60)
	row.info = nil
	row.right = Text(row, "GameFontDisableSmall", "RIGHT")
	row.right:SetPoint("RIGHT", -3, 0)
	row:SetScript("PostClick", function(self, button)
		if button == "RightButton" then RowMenu(self) end
	end)
	row:SetScript("OnEnter", function(self)
		if not self.key then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		local n = ns.nearby[self.key]
		local e = ns.Get(self.key)
		GameTooltip:AddLine(e and ns.ColorName(e) or (n and NameColor(n.class, n.name)) or "?")
		if n then
			local bits = {}
			if n.level and n.level > 0 then bits[#bits + 1] = "Level " .. n.level end
			if n.race then bits[#bits + 1] = n.race end
			if #bits > 0 then GameTooltip:AddLine(table.concat(bits, " "), 1, 1, 1) end
			if n.guild then GameTooltip:AddLine("<" .. n.guild .. ">", 0.7, 0.7, 0.7) end
		end
		if e then
			GameTooltip:AddLine("Kill on sight" .. (e.w and (": " .. e.w) or ""), 1, 0.2, 0.2, true)
			GameTooltip:AddLine("Added by " .. ns.ShortSender(e.b) .. ", " .. ns.Ago(e.a), 0.6, 0.6, 0.6)
		end
		GameTooltip:AddLine("Left-click: target   Right-click: kill list", 0.5, 0.8, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row:Hide()
	rows[i] = row
end

local function FillRowText(row, item)
	local n, e = item.n, item.e
	local level = (n.level and n.level > 0) and (" |cffaaaaaa" .. n.level .. "|r") or ""
	row.name:SetText(NameColor(n.class, n.name) .. level)
	local age = math.floor(GetTime() - n.seen)
	row.right:SetText(e and "|cffff3030KOS|r" or (age < 5 and "now" or (age .. "s")))
	row.bg:SetShown(e ~= nil)
end

local layoutPending = false

local function LayoutNearby()
	local list = ns.NearbyList()
	if InCombatLockdown() then
		-- Rows keep their players; just refresh their text.
		layoutPending = true
		local byKey, extra = {}, 0
		for _, item in ipairs(list) do byKey[item.key] = item end
		local shownKeys = {}
		for _, row in ipairs(rows) do
			if row.key then
				shownKeys[row.key] = true
				local item = byKey[row.key]
				if item then FillRowText(row, item) else row.right:SetText("gone") end
			end
		end
		for _, item in ipairs(list) do
			if not shownKeys[item.key] then extra = extra + 1 end
		end
		nearby.footer:SetText(extra > 0 and ("+" .. extra .. " more after combat") or "")
		return
	end
	layoutPending = false
	local count = math.min(#list, NEARBY_ROWS)
	for i, row in ipairs(rows) do
		local item = list[i]
		if item and i <= count then
			row.key = item.key
			row.info = { name = item.n.name, realm = item.n.realm, class = item.n.class, guild = item.n.guild, level = item.n.level }
			row:SetAttribute("macrotext1", "/targetexact " .. ns.TargetName({ n = item.n.name, r = item.n.realm }))
			FillRowText(row, item)
			row:Show()
		else
			row.key, row.info = nil, nil
			row:SetAttribute("macrotext1", nil)
			row:Hide()
		end
	end
	local more = #list - count
	nearby.footer:SetText(more > 0 and ("+" .. more .. " more") or (#list == 0 and "No enemies nearby" or ""))
	nearby:SetHeight(20 + count * ROW_H + 16)
	nearby.title:SetText("|cffe03c3cBH&G|r Nearby" .. (#list > 0 and (" (" .. #list .. ")") or ""))
	local want = ns.Setting("nearby")
	if want and not nearby:IsShown() then nearby:Show() elseif not want and nearby:IsShown() then nearby:Hide() end
end

ns.Listen("TICK", LayoutNearby)
ns.Listen("LIST_CHANGED", function() if nearby:IsShown() then LayoutNearby() end end)
ns.Listen("SETTINGS_CHANGED", function() LayoutNearby() end)
ns.On("PLAYER_REGEN_ENABLED", function() if layoutPending then LayoutNearby() end end)

function ns.ToggleNearby()
	if InCombatLockdown() then
		ns.Print("the nearby window can't be shown or hidden in combat.")
		return
	end
	ns.SetSetting("nearby", not ns.Setting("nearby"))
	ns.Print("nearby window " .. (ns.Setting("nearby") and "on." or "off."))
end

-----------------------------------------------------------------------
-- List window
-----------------------------------------------------------------------

local LIST_ROWS = 10
local LROW_H = 36
local WIN_W, WIN_H = 520, 20 + 34 + LIST_ROWS * LROW_H + 40

local win = CreateFrame("Frame", "BHGKillListWindow", UIParent, BACKDROP_TEMPLATE)
win:SetSize(WIN_W, WIN_H)
win:SetFrameStrata("DIALOG")
win:SetClampedToScreen(true)
win:SetMovable(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePos(self, "window") end)
Backdrop(win, 0.94)
win:Hide()
tinsert(UISpecialFrames, "BHGKillListWindow")

win.title = Text(win, "GameFontNormal")
win.title:SetPoint("TOPLEFT", 10, -8)

local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)

local search = CreateFrame("EditBox", "BHGKillListSearch", win, "InputBoxTemplate")
search:SetSize(160, 20)
search:SetPoint("TOPLEFT", 16, -30)
search:SetAutoFocus(false)
search.hint = Text(search, "GameFontDisableSmall")
search.hint:SetPoint("LEFT", 2, 0)
search.hint:SetText("Search")

local function Button(label, width, onClick)
	local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end

local addTarget = Button("Add target", 90, function()
	local info = ns.TargetInfo()
	if not info then ns.Print("target an enemy player first.") return end
	if ns.GetByName(info.name, info.realm) then ns.AskEditReason(ns.Key(info.name, info.realm)) return end
	ns.AskReason(info)
end)
addTarget:SetPoint("LEFT", search, "RIGHT", 10, 0)
local addName = Button("Add by name", 100, function() ns.AskAddName() end)
addName:SetPoint("LEFT", addTarget, "RIGHT", 4, 0)
local optionsBtn = Button("Options", 80, function() ns.ToggleOptions() end)
optionsBtn:SetPoint("LEFT", addName, "RIGHT", 4, 0)

local listArea = CreateFrame("Frame", nil, win)
listArea:SetPoint("TOPLEFT", 6, -56)
listArea:SetPoint("BOTTOMRIGHT", -6, 34)

local status = Text(win, "GameFontDisableSmall")
status:SetPoint("BOTTOMLEFT", 10, 12)
status:SetWidth(WIN_W - 120)

local syncBtn = Button("Sync now", 90, function()
	if ns.SyncNow() then
		ns.Print("asked the guild to compare lists. Anything missing on either side is sent over in the next few seconds.")
	else
		ns.Print("you need to be in a guild to sync.")
	end
end)
syncBtn:SetPoint("BOTTOMRIGHT", -8, 8)

local offset = 0
local filtered = {}
local lrows = {}

local function Matches(e, q)
	if q == "" then return true end
	for _, f in ipairs({ e.n, e.r, e.g, e.w, e.b, e.c }) do
		if type(f) == "string" and f:lower():find(q, 1, true) then return true end
	end
	return false
end

local RefreshList

for i = 1, LIST_ROWS do
	local row = CreateFrame("Button", nil, listArea)
	row:SetHeight(LROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * LROW_H)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * LROW_H)
	local stripe = row:CreateTexture(nil, "BACKGROUND")
	stripe:SetAllPoints()
	stripe:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)
	row.name = Text(row, "GameFontHighlight")
	row.name:SetPoint("TOPLEFT", 6, -4)
	row.name:SetWidth(250)
	row.why = Text(row, "GameFontHighlightSmall")
	row.why:SetPoint("TOPLEFT", 6, -20)
	row.why:SetWidth(250)
	row.why:SetTextColor(1, 0.75, 0.75)
	row.by = Text(row, "GameFontDisableSmall", "RIGHT")
	row.by:SetPoint("TOPRIGHT", -112, -5)
	row.by:SetWidth(140)
	row.seen = Text(row, "GameFontDisableSmall", "RIGHT")
	row.seen:SetPoint("TOPRIGHT", -112, -21)
	row.seen:SetWidth(140)
	row.edit = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.edit:SetSize(50, 20)
	row.edit:SetPoint("RIGHT", -56, 0)
	row.edit:SetText("Edit")
	row.edit:SetScript("OnClick", function() if row.key then ns.AskEditReason(row.key) end end)
	row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.remove:SetSize(52, 20)
	row.remove:SetPoint("RIGHT", -2, 0)
	row.remove:SetText("Remove")
	row.remove:SetScript("OnClick", function() if row.key then ns.AskRemove(row.key) end end)
	row:SetScript("OnEnter", function(self)
		local e = self.key and ns.Get(self.key)
		if not e then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(ns.ColorName(e))
		if e.g then GameTooltip:AddLine("<" .. e.g .. ">", 0.7, 0.7, 0.7) end
		if e.lv or e.race then GameTooltip:AddLine(((e.lv and ("Level " .. e.lv .. " ")) or "") .. (e.race or ""), 1, 1, 1) end
		GameTooltip:AddLine(e.w or "No reason given", 1, 0.75, 0.75, true)
		GameTooltip:AddLine("Added by " .. ns.ShortSender(e.b) .. ", " .. ns.Ago(e.a), 0.6, 0.6, 0.6)
		if e.seen then
			GameTooltip:AddLine("Last seen " .. ns.Ago(e.seen) .. (e.sz and e.sz ~= "" and (" in " .. e.sz) or "") .. (e.sb and (" by " .. e.sb) or ""), 0.6, 0.6, 0.6, true)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	lrows[i] = row
end

listArea:EnableMouseWheel(true)
listArea:SetScript("OnMouseWheel", function(_, delta)
	local maxOffset = math.max(0, #filtered - LIST_ROWS)
	offset = math.max(0, math.min(maxOffset, offset - delta * 3))
	RefreshList()
end)

local emptyText = Text(listArea, "GameFontDisable", "CENTER")
emptyText:SetPoint("CENTER")
emptyText:SetWidth(400)
emptyText:SetWordWrap(true)

RefreshList = function()
	if not win:IsShown() or not ns.db then return end
	local q = (search:GetText() or ""):lower()
	search.hint:SetShown(q == "" and not search:HasFocus())
	filtered = {}
	for _, e in ipairs(ns.List()) do
		if Matches(e, q) then filtered[#filtered + 1] = e end
	end
	offset = math.max(0, math.min(offset, math.max(0, #filtered - LIST_ROWS)))
	for i, row in ipairs(lrows) do
		local e = filtered[offset + i]
		if e then
			row.key = ns.Key(e.n, e.r)
			local level = e.lv and e.lv > 0 and ("  |cffaaaaaa" .. e.lv .. "|r") or ""
			local guild = e.g and ("  |cff888888<" .. e.g .. ">|r") or ""
			row.name:SetText(ns.ColorName(e) .. level .. guild)
			row.why:SetText(e.w or "|cff777777No reason given|r")
			row.by:SetText("by " .. ns.ShortSender(e.b) .. ", " .. ns.Ago(e.a))
			row.seen:SetText(e.seen and ("seen " .. ns.Ago(e.seen)) or "not seen yet")
			row:Show()
		else
			row.key = nil
			row:Hide()
		end
	end
	local total = ns.Count()
	win.title:SetText("|cffe03c3cBH&G Kill List|r  |cffaaaaaa" .. total .. " player" .. (total == 1 and "" or "s") .. "|r")
	if total == 0 then
		emptyText:SetText("Nobody on the list yet.\nTarget an enemy and click Add target, or right-click a player's name.")
	elseif #filtered == 0 then
		emptyText:SetText("No one matches \"" .. q .. "\".")
	else
		emptyText:SetText("")
	end
	local first, last = math.min(#filtered, offset + 1), math.min(#filtered, offset + LIST_ROWS)
	local range = (#filtered > LIST_ROWS) and (first .. "-" .. last .. " of " .. #filtered .. ", scroll for more.  ") or ""
	local peers = 0
	for _, t in pairs(ns.sync.peers) do if GetTime() - t < 3600 then peers = peers + 1 end end
	status:SetText(range .. (IsInGuild() and ("Shared with the guild" .. (peers > 0 and (" (" .. peers .. " heard from)") or "")) or "Not in a guild: nothing is shared"))
end

search:SetScript("OnTextChanged", function() offset = 0 RefreshList() end)
search:SetScript("OnEditFocusGained", function(self) self.hint:Hide() end)
search:SetScript("OnEditFocusLost", function() RefreshList() end)
search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
win:SetScript("OnShow", function() RefreshList() end)

ns.Listen("LIST_CHANGED", function() RefreshList() end)
ns.Listen("SEEN", function() RefreshList() end)

-----------------------------------------------------------------------
-- Options (inside the list window)
-----------------------------------------------------------------------

local opts = CreateFrame("Frame", nil, win)
opts:SetPoint("TOPLEFT", listArea, "TOPLEFT")
opts:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT")
opts:Hide()

local OPTIONS = {
	{ "banner", "Show a big warning when a listed player shows up" },
	{ "sound", "Play a warning sound" },
	{ "chat", "Write the warning in chat" },
	{ "shareSightings", "Tell the guild when I spot a listed player" },
	{ "guildSightings", "Show the guild's sightings in my chat" },
	{ "nearby", "Show the nearby enemies window" },
	{ "nearbyAll", "List every enemy player nearby, not only listed ones" },
}

local checks = {}
for i, o in ipairs(OPTIONS) do
	local cb = CreateFrame("CheckButton", nil, opts)
	cb:SetSize(24, 24)
	cb:SetPoint("TOPLEFT", 14, -10 - (i - 1) * 28)
	cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
	cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	cb.label = Text(opts, "GameFontHighlight")
	cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	cb.label:SetText(o[2])
	cb:SetScript("OnClick", function(self)
		if o[1] == "nearby" and InCombatLockdown() then
			self:SetChecked(ns.Setting("nearby"))
			ns.Print("the nearby window can't be shown or hidden in combat.")
			return
		end
		ns.SetSetting(o[1], self:GetChecked() and true or false)
	end)
	cb.key = o[1]
	checks[#checks + 1] = cb
end

local testBtn = CreateFrame("Button", nil, opts, "UIPanelButtonTemplate")
testBtn:SetSize(120, 22)
testBtn:SetPoint("TOPLEFT", 16, -10 - #OPTIONS * 28 - 10)
testBtn:SetText("Test warning")
testBtn:SetScript("OnClick", function() ns.TestAlert() end)

local moveBtn = CreateFrame("Button", nil, opts, "UIPanelButtonTemplate")
moveBtn:SetSize(120, 22)
moveBtn:SetPoint("LEFT", testBtn, "RIGHT", 6, 0)
moveBtn:SetText("Move warning")
moveBtn:SetScript("OnClick", function() ns.ToggleBannerMove() end)

local optsNote = Text(opts, "GameFontDisableSmall")
optsNote:SetPoint("TOPLEFT", testBtn, "BOTTOMLEFT", 0, -14)
optsNote:SetWidth(460)
optsNote:SetWordWrap(true)
optsNote:SetText("Drag the nearby window by its edge to move it. Everything on the list is shared with every guild member who has BH&G Kill List; changes reach everyone online right away, and anyone offline catches up when they log in.")

function ns.ToggleOptions()
	local show = not opts:IsShown()
	opts:SetShown(show)
	listArea:SetShown(not show)
	optionsBtn:SetText(show and "List" or "Options")
	for _, cb in ipairs(checks) do cb:SetChecked(ns.Setting(cb.key)) end
	if not win:IsShown() then win:Show() end
end

function ns.ToggleWindow(showOptions)
	if win:IsShown() and not showOptions then
		win:Hide()
		return
	end
	win:Show()
	if showOptions and not opts:IsShown() then ns.ToggleOptions() end
end

function ns.TestAlert()
	ns.Alert({ n = "Testplayer", r = ns.MyRealm(), c = "ROGUE", w = "This is what a warning looks like", b = ns.MyFullName(), g = "Some Horde Guild", lv = 60 }, { level = 60 }, true)
end

-----------------------------------------------------------------------
-- Positions
-----------------------------------------------------------------------

ns.Listen("DB_READY", function()
	RestorePos(banner, "banner", "TOP", UIParent, "TOP", 0, -140)
	RestorePos(nearby, "nearby", "LEFT", UIParent, "LEFT", 20, 120)
	RestorePos(win, "window", "CENTER", UIParent, "CENTER", 0, 40)
	if not InCombatLockdown() then LayoutNearby() end
end)
