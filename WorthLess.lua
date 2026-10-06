--[[
	Worth Less
	Scans the player's bags, ranks every sellable non-quest item by total
	vendor value (unit price * stack size), and draws a coloured indicator on
	the N cheapest items in the default Blizzard bag frames.

	Slash commands: /worthless or /wl  (type /wl for help)
]]

local ADDON_NAME, ns = ...
local WorthLess = CreateFrame("Frame", "WorthLessFrame")
_G.WorthLess = WorthLess
ns.WorthLess = WorthLess

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local MAX_COUNT = 5

local DEFAULTS = {
	enabled           = true,
	count             = 1,     -- how many of the cheapest items to flag (1..MAX_COUNT)
	includeNoValue    = false, -- also consider items that cannot be sold to a vendor
	includeReagentBag = true,  -- scan the reagent bag as well as the normal bags
	showPrice         = true,  -- draw the stack's vendor value on the slot
	showRank          = true,  -- draw the rank number on the slot when count > 1
	glow              = true,  -- soft glow around the slot (like the quest/new-item glow)
	border            = true,  -- crisp 2px border on the slot edge
	pulse             = true,  -- gently pulse the glow and border
	tooltip           = true,  -- add a line to the item tooltip
	-- Gradient endpoints: rank 1 uses colorLow, rank `count` uses colorHigh.
	colorLow          = { r = 0.62, g = 0.25, b = 1.00 }, -- purple
	colorHigh         = { r = 1.00, g = 0.45, b = 0.95 }, -- pink
	colorVersion      = 2,
	ignored           = {},    -- [itemID] = item name (or true); never flagged
}

local db -- points at WorthLessDB once ADDON_LOADED has fired

-------------------------------------------------------------------------------
-- API shims / constants
-------------------------------------------------------------------------------

local QUEST_CLASS   = (Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local QUEST_BIND    = (Enum.ItemBind and Enum.ItemBind.Quest) or 4
local BACKPACK      = (Enum.BagIndex and Enum.BagIndex.Backpack) or 0
local LAST_BAG      = NUM_BAG_SLOTS or 4
local REAGENT_BAG   = Enum.BagIndex and Enum.BagIndex.ReagentBag
local HAS_REAGENT   = (NUM_REAGENTBAG_SLOTS or 0) > 0 and REAGENT_BAG ~= nil
local NUM_FRAMES    = NUM_CONTAINER_FRAMES or 13

local GetContainerNumSlots      = C_Container.GetContainerNumSlots
local GetContainerItemInfo      = C_Container.GetContainerItemInfo
local GetContainerItemQuestInfo = C_Container.GetContainerItemQuestInfo
local GetItemInfo               = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant        = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local function Print(fmt, ...)
	if select("#", ...) > 0 then fmt = fmt:format(...) end
	print("|cffffd100Worth Less:|r " .. fmt)
end

-- Compact money string that fits on a 37px bag slot, e.g. "3c", "48s", "2.5g", "120g".
local function FormatMoneyShort(copper)
	copper = copper or 0
	if copper >= 10000 then
		local gold = copper / 10000
		if gold >= 10 then return ("%dg"):format(math.floor(gold)) end
		local s = ("%.1fg"):format(gold)
		s = s:gsub("%.0g$", "g")
		return s
	elseif copper >= 100 then
		return ("%ds"):format(math.floor(copper / 100))
	end
	return ("%dc"):format(copper)
end

local function Key(bag, slot)
	return bag * 1000 + slot
end

-------------------------------------------------------------------------------
-- Scanning
-------------------------------------------------------------------------------

local results         = {} -- sorted ascending by value; every candidate item
local ranked          = {} -- ranked[Key(bag, slot)] = entry (only the top `count`)
local pendingItemInfo = false

local function GetBagIDs()
	local bags = {}
	for bag = BACKPACK, LAST_BAG do bags[#bags + 1] = bag end
	if db.includeReagentBag and HAS_REAGENT then bags[#bags + 1] = REAGENT_BAG end
	return bags
end

local function IsQuestItem(bag, slot, link, classID, bindType)
	if classID == QUEST_CLASS or bindType == QUEST_BIND then return true end
	local q = GetContainerItemQuestInfo(bag, slot)
	if type(q) == "table" then
		if q.isQuestItem or q.questID then return true end
	elseif q then -- pre-10.0 style: isQuestItem, questID, isActive
		return true
	end
	if classID == nil and link then
		local _, _, _, _, _, instantClass = GetItemInfoInstant(link)
		if instantClass == QUEST_CLASS then return true end
	end
	return false
end

local function SortEntries(a, b)
	if a.value ~= b.value then return a.value < b.value end
	if a.unit  ~= b.unit  then return a.unit  < b.unit  end
	if a.count ~= b.count then return a.count < b.count end
	if a.bag   ~= b.bag   then return a.bag   < b.bag   end
	return a.slot < b.slot
end

local function ScanBags()
	wipe(results)
	wipe(ranked)
	pendingItemInfo = false

	for _, bag in ipairs(GetBagIDs()) do
		local numSlots = GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = GetContainerItemInfo(bag, slot)
			if type(info) == "table" and info.hyperlink then
				local link = info.hyperlink
				local name, _, quality, _, _, _, _, _, _, _, sellPrice, classID, _, bindType = GetItemInfo(link)
				if not name then
					-- Item data not cached yet; GET_ITEM_INFO_RECEIVED will trigger a rescan.
					pendingItemInfo = true
				elseif info.itemID and db.ignored[info.itemID] then
					-- On the ignore list (e.g. a mining pick); never flagged.
				elseif not IsQuestItem(bag, slot, link, classID, bindType) then
					sellPrice = sellPrice or 0
					local sellable = sellPrice > 0 and not info.hasNoValue
					if sellable or db.includeNoValue then
						local unit  = sellable and sellPrice or 0
						local count = info.stackCount or 1
						results[#results + 1] = {
							bag = bag, slot = slot, link = link, name = name,
							itemID = info.itemID, icon = info.iconFileID,
							quality = quality, unit = unit, count = count,
							value = unit * count,
						}
					end
				end
			end
		end
	end

	table.sort(results, SortEntries)

	for rank = 1, math.min(db.count, #results) do
		local entry = results[rank]
		entry.rank = rank
		ranked[Key(entry.bag, entry.slot)] = entry
	end
end

-- Linear gradient from colorLow (rank 1) to colorHigh (rank == count).
local function RankColor(rank)
	local lo, hi = db.colorLow, db.colorHigh
	local t = 0
	if db.count > 1 then t = (rank - 1) / (db.count - 1) end
	return lo.r + (hi.r - lo.r) * t,
	       lo.g + (hi.g - lo.g) * t,
	       lo.b + (hi.b - lo.b) * t
end

-------------------------------------------------------------------------------
-- Overlays on bag item buttons
-------------------------------------------------------------------------------

local overlays = setmetatable({}, { __mode = "k" }) -- overlays[itemButton] = overlayFrame

local function CreateOverlay(button)
	local ov = CreateFrame("Frame", nil, button)
	ov:SetAllPoints(button)
	ov:SetFrameLevel(button:GetFrameLevel() + 10)

	-- Glow + border live on their own frame so the pulse does not dim the text.
	local border = CreateFrame("Frame", nil, ov, "BackdropTemplate")
	border:SetAllPoints(ov)
	border:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 2,
	})
	ov.border = border

	-- The action-button border texture, additively blended, gives the classic
	-- "proc" glow that hugs the slot. It has built-in padding, hence the 1.65x size.
	local w, h = button:GetSize()
	if not w or w < 1 then w = 37 end
	if not h or h < 1 then h = 37 end
	local glow = border:CreateTexture(nil, "OVERLAY")
	glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	glow:SetBlendMode("ADD")
	glow:SetPoint("CENTER", ov, "CENTER", 0, 0)
	glow:SetSize(w * 1.65, h * 1.65)
	ov.glow = glow

	local pulse = border:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local alpha = pulse:CreateAnimation("Alpha")
	alpha:SetFromAlpha(1)
	alpha:SetToAlpha(0.35)
	alpha:SetDuration(0.8)
	alpha:SetSmoothing("IN_OUT")
	ov.pulse = pulse

	ov.price = ov:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	ov.price:SetPoint("TOP", ov, "TOP", 0, -2)

	ov.rank = ov:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	ov.rank:SetPoint("TOPRIGHT", ov, "TOPRIGHT", -2, -2)

	ov:Hide()
	overlays[button] = ov
	return ov
end

local function GetButtonBagAndSlot(button)
	local bag
	if button.GetBagID then
		bag = button:GetBagID()
	else
		local parent = button:GetParent()
		bag = parent and parent:GetID()
	end
	return bag, button:GetID()
end

-- Draw (or redraw) the indicator for `entry` on `button`.
local function ApplyOverlay(button, entry)
	if not entry then
		local bag, slot = GetButtonBagAndSlot(button)
		entry = bag and slot and ranked[Key(bag, slot)]
		if not entry then return end
	end
	entry.shown = true

	local ov = overlays[button] or CreateOverlay(button)
	ov.wanted = true

	local r, g, b = RankColor(entry.rank)
	if db.border then
		ov.border:SetBackdropBorderColor(r, g, b, 1)
		ov.border:SetBackdropColor(r, g, b, 0.12)
	else
		ov.border:SetBackdropBorderColor(0, 0, 0, 0)
		ov.border:SetBackdropColor(0, 0, 0, 0)
	end

	if db.glow then
		ov.glow:SetVertexColor(r, g, b, 1)
		ov.glow:Show()
	else
		ov.glow:Hide()
	end

	if db.showPrice then
		ov.price:SetText(FormatMoneyShort(entry.value))
		ov.price:SetTextColor(r, g, b)
		ov.price:Show()
	else
		ov.price:Hide()
	end

	if db.showRank and db.count > 1 then
		ov.rank:SetText(tostring(entry.rank))
		ov.rank:SetTextColor(r, g, b)
		ov.rank:Show()
	else
		ov.rank:Hide()
	end

	ov:Show()
	if db.pulse then
		if not ov.pulse:IsPlaying() then ov.pulse:Play() end
	else
		ov.pulse:Stop()
		ov.border:SetAlpha(1)
	end
end

local function EnumerateItemButtons(frame, fn)
	if not frame or not frame:IsShown() then return end
	if frame.EnumerateValidItems then
		for _, button in frame:EnumerateValidItems() do fn(button) end
	elseif frame.Items then
		for _, button in ipairs(frame.Items) do
			if button:IsShown() then fn(button) end
		end
	else
		local name = frame:GetName()
		for i = 1, (frame.size or 0) do
			local button = _G[name .. "Item" .. i]
			if button then fn(button) end
		end
	end
end

local function ForEachVisibleItemButton(fn)
	EnumerateItemButtons(ContainerFrameCombinedBags, fn)
	for i = 1, NUM_FRAMES do
		EnumerateItemButtons(_G["ContainerFrame" .. i], fn)
	end
end

-- Blizzard's own lookup: returns the item button currently displaying bag/slot,
-- in either the per-bag or the combined view. nil when that bag is not open.
local function FindItemButton(bag, slot)
	if ContainerFrameUtil_GetItemButtonAndContainer then
		local ok, button = pcall(ContainerFrameUtil_GetItemButtonAndContainer, bag, slot)
		if ok and button then return button end
	end
	return nil
end

-- /wl test: paint the indicator on the first visible slot regardless of value,
-- so rendering can be checked independently of the ranking.
local testMode = false
local testEntry = { rank = 1, value = 12345, bag = -1, slot = -1 }

local function RefreshOverlays()
	for _, ov in pairs(overlays) do ov.wanted = false end
	if testMode then
		local first
		ForEachVisibleItemButton(function(button) first = first or button end)
		if first then ApplyOverlay(first, testEntry) end
	end
	if db.enabled then
		-- Primary path: ask Blizzard for the button of each ranked slot.
		for _, entry in pairs(ranked) do
			entry.shown = nil
			local button = FindItemButton(entry.bag, entry.slot)
			if button and button:IsShown() then
				ApplyOverlay(button, entry)
			end
		end
		-- Fallback: walk every visible item button and match bag/slot ourselves.
		ForEachVisibleItemButton(function(button)
			local bag, slot = GetButtonBagAndSlot(button)
			local entry = bag and slot and ranked[Key(bag, slot)]
			if entry and not entry.shown then
				ApplyOverlay(button, entry)
			end
		end)
	end
	for _, ov in pairs(overlays) do
		if not ov.wanted and ov:IsShown() then
			ov.pulse:Stop()
			ov:Hide()
		end
	end
end

-------------------------------------------------------------------------------
-- Throttled refresh
-------------------------------------------------------------------------------

local refreshQueued, scanQueued = false, false
local reportedErrors = {}

-- Errors inside timer callbacks are invisible unless "Display Lua Errors" is on,
-- so print each distinct one to chat once and still pass it to the error handler.
local function ReportError(err)
	err = tostring(err)
	if not reportedErrors[err] then
		reportedErrors[err] = true
		Print("|cffff4040error:|r %s", err)
	end
	local handler = geterrorhandler and geterrorhandler()
	if handler then pcall(handler, err) end
end

local function DoRefresh()
	refreshQueued = false
	if scanQueued then
		scanQueued = false
		ScanBags()
	end
	RefreshOverlays()
	if ns.OnRefresh then ns.OnRefresh() end -- lets the options panel update its lists
end

function WorthLess:RequestRefresh(rescan)
	if rescan then scanQueued = true end
	if refreshQueued then return end
	refreshQueued = true
	C_Timer.After(0.05, function()
		local ok, err = pcall(DoRefresh)
		if not ok then
			refreshQueued = false
			ReportError(err)
		end
	end)
end

-------------------------------------------------------------------------------
-- Hooks into the Blizzard bag frames
-------------------------------------------------------------------------------

local function HookContainerFrame(frame)
	if not frame or frame.WorthLessHooked then return end
	frame.WorthLessHooked = true
	-- UpdateItems redraws icons; UpdateItemSlots re-pools buttons onto new bag/slot
	-- pairs; UpdateItemLayout runs on show and resize. Any of them can move our target.
	for _, method in ipairs({ "UpdateItems", "UpdateItemSlots", "UpdateItemLayout" }) do
		if type(frame[method]) == "function" then
			pcall(hooksecurefunc, frame, method, function() WorthLess:RequestRefresh() end)
		end
	end
	frame:HookScript("OnShow", function() WorthLess:RequestRefresh() end)
end

local function HookContainerFrames()
	HookContainerFrame(ContainerFrameCombinedBags)
	for i = 1, NUM_FRAMES do
		HookContainerFrame(_G["ContainerFrame" .. i])
	end
	-- Pre-10.0 clients update bags through a global function instead.
	if type(ContainerFrame_Update) == "function" then
		hooksecurefunc("ContainerFrame_Update", function() WorthLess:RequestRefresh() end)
	end
end

local function MoneyText(copper)
	if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		return C_CurrencyInfo.GetCoinTextureString(copper)
	end
	return GetMoneyString(copper)
end

local function SetupTooltip()
	if not (GameTooltip and GameTooltip.SetBagItem) then return end
	pcall(hooksecurefunc, GameTooltip, "SetBagItem", function(tooltip, bag, slot)
		if not (db.enabled and db.tooltip) then return end
		local entry = ranked[Key(bag, slot)]
		if not entry then return end
		local r, g, b = RankColor(entry.rank)
		local label
		if db.count > 1 then
			label = ("Worth Less: #%d lowest value in bags (%s)"):format(entry.rank, MoneyText(entry.value))
		else
			label = ("Worth Less: lowest value item in bags (%s)"):format(MoneyText(entry.value))
		end
		tooltip:AddLine(label, r, g, b)
		tooltip:Show()
	end)
end

-------------------------------------------------------------------------------
-- Public helpers
-------------------------------------------------------------------------------

-- Returns the sorted candidate list (cheapest first). Read-only; do not modify.
function WorthLess:GetRankedItems()
	return results
end

function WorthLess:GetEntry(bag, slot)
	return ranked[Key(bag, slot)]
end

-------------------------------------------------------------------------------
-- Ignore list
-------------------------------------------------------------------------------

-- Turns user text into an itemID: an item link, a numeric ID, or the exact
-- name of an item currently in the bags. Returns itemID, name (name may be nil).
function ns.ResolveItem(text)
	text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil end
	local id = tonumber(text:match("|Hitem:(%d+)")) or tonumber(text:match("^item:(%d+)")) or tonumber(text)
	if not id then
		local wanted = text:lower()
		for _, bag in ipairs(GetBagIDs()) do
			for slot = 1, (GetContainerNumSlots(bag) or 0) do
				local info = GetContainerItemInfo(bag, slot)
				if type(info) == "table" and info.hyperlink then
					local name = GetItemInfo(info.hyperlink)
					if name and name:lower() == wanted then
						id = info.itemID
						break
					end
				end
			end
			if id then break end
		end
	end
	if not id then return nil end
	local name = GetItemInfo(id)
	return id, name
end

function ns.IgnoreItem(id, name)
	if not id then return end
	db.ignored[id] = name or db.ignored[id] or true
	local link = select(2, GetItemInfo(id)) or name or ("item " .. id)
	Print("ignoring %s.", link)
	WorthLess:RequestRefresh(true)
end

function ns.UnignoreItem(id)
	if not id or not db.ignored[id] then return false end
	local label = select(2, GetItemInfo(id)) or (type(db.ignored[id]) == "string" and db.ignored[id]) or ("item " .. id)
	db.ignored[id] = nil
	Print("no longer ignoring %s.", label)
	WorthLess:RequestRefresh(true)
	return true
end

-- Sorted list of { id = itemID, name = string } for display.
function ns.GetIgnoredList()
	local list = {}
	for id, stored in pairs(db.ignored) do
		local name, link = GetItemInfo(id)
		list[#list + 1] = {
			id = id,
			name = name or (type(stored) == "string" and stored) or ("Item " .. id),
			link = link,
		}
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function ApplyDefaults()
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then
			db[k] = (type(v) == "table") and CopyTable(v) or v
		end
	end
	db.count = math.max(1, math.min(MAX_COUNT, tonumber(db.count) or 1))
	-- Colour scheme changed from red/yellow to purple/pink; replace saved colours once.
	if db.colorVersion ~= DEFAULTS.colorVersion then
		db.colorLow = CopyTable(DEFAULTS.colorLow)
		db.colorHigh = CopyTable(DEFAULTS.colorHigh)
		db.colorVersion = DEFAULTS.colorVersion
	end
end

WorthLess:RegisterEvent("ADDON_LOADED")
WorthLess:RegisterEvent("PLAYER_LOGIN")
WorthLess:RegisterEvent("BAG_UPDATE_DELAYED")
WorthLess:RegisterEvent("GET_ITEM_INFO_RECEIVED")

WorthLess:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		WorthLessDB = WorthLessDB or {}
		db = WorthLessDB
		ApplyDefaults()
		ns.db = db
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		HookContainerFrames()
		SetupTooltip()
		self:RequestRefresh(true)
	elseif event == "BAG_UPDATE_DELAYED" then
		self:RequestRefresh(true)
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if pendingItemInfo then self:RequestRefresh(true) end
	end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function OnOff(v) return v and "|cff00ff00on|r" or "|cffff4040off|r" end

-------------------------------------------------------------------------------
-- Colours: named, hex (rrggbb), or "r g b" as 0-1 or 0-255
-------------------------------------------------------------------------------

local NAMED_COLORS = {
	purple  = { r = 0.62, g = 0.25, b = 1.00 },
	violet  = { r = 0.55, g = 0.00, b = 1.00 },
	pink    = { r = 1.00, g = 0.45, b = 0.95 },
	magenta = { r = 1.00, g = 0.00, b = 1.00 },
	red     = { r = 1.00, g = 0.20, b = 0.20 },
	orange  = { r = 1.00, g = 0.55, b = 0.10 },
	yellow  = { r = 1.00, g = 0.90, b = 0.20 },
	green   = { r = 0.20, g = 1.00, b = 0.30 },
	cyan    = { r = 0.20, g = 0.90, b = 1.00 },
	blue    = { r = 0.30, g = 0.50, b = 1.00 },
	white   = { r = 1.00, g = 1.00, b = 1.00 },
	gold    = { r = 1.00, g = 0.82, b = 0.00 },
}

local function ParseColor(text)
	text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("^#", "")
	if text == "" then return nil end
	if NAMED_COLORS[text] then
		return CopyTable(NAMED_COLORS[text])
	end
	local hex = text:match("^(%x%x%x%x%x%x)$")
	if hex then
		return {
			r = tonumber(hex:sub(1, 2), 16) / 255,
			g = tonumber(hex:sub(3, 4), 16) / 255,
			b = tonumber(hex:sub(5, 6), 16) / 255,
		}
	end
	local r, g, b = text:match("^([%d%.]+)[%s,]+([%d%.]+)[%s,]+([%d%.]+)$")
	r, g, b = tonumber(r), tonumber(g), tonumber(b)
	if r and g and b then
		if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
		return { r = math.min(1, r), g = math.min(1, g), b = math.min(1, b) }
	end
	return nil
end

local function ColorSwatch(c)
	local hex = ("%02x%02x%02x"):format(
		math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
	return ("|cff%s%s|r"):format(hex, hex)
end

local function PrintColors()
	Print("rank 1 colour: %s   last rank colour: %s", ColorSwatch(db.colorLow), ColorSwatch(db.colorHigh))
	local names = {}
	for name in pairs(NAMED_COLORS) do names[#names + 1] = name end
	table.sort(names)
	local list = {}
	for _, name in ipairs(names) do
		local c = NAMED_COLORS[name]
		list[#list + 1] = ("|cff%02x%02x%02x%s|r"):format(
			math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), name)
	end
	print("  names: " .. table.concat(list, ", "))
	print("  also hex like |cffffd100/wl color 9f40ff|r or |cffffd100/wl color 160 64 255|r")
	print("  |cffffd100/wl color high <colour>|r sets the colour of the last rank when count > 1")
end

local function SetColor(rest)
	local which, spec = "low", rest
	local head, tail = rest:match("^(%S+)%s+(.+)$")
	if head and (head:lower() == "high" or head:lower() == "low") then
		which, spec = head:lower(), tail
	end
	local color = ParseColor(spec)
	if not color then
		Print("could not read colour '%s'.", tostring(spec))
		PrintColors()
		return
	end
	if which == "high" then db.colorHigh = color else db.colorLow = color end
	Print("%s colour set to %s.", which == "high" and "last rank" or "rank 1", ColorSwatch(color))
	WorthLess:RequestRefresh()
end

local function PrintHelp()
	Print("commands (/worthless or /wl):")
	print("  |cffffd100/wl toggle|r      - enable/disable (currently " .. OnOff(db.enabled) .. ")")
	print("  |cffffd100/wl count N|r     - flag the N cheapest items, 1-" .. MAX_COUNT .. " (currently " .. db.count .. ")")
	print("  |cffffd100/wl novalue|r     - include unsellable items (currently " .. OnOff(db.includeNoValue) .. ")")
	print("  |cffffd100/wl reagent|r     - scan the reagent bag (currently " .. OnOff(db.includeReagentBag) .. ")")
	print("  |cffffd100/wl price|r       - show value text on the slot (currently " .. OnOff(db.showPrice) .. ")")
	print("  |cffffd100/wl rank|r        - show rank number when count > 1 (currently " .. OnOff(db.showRank) .. ")")
	print("  |cffffd100/wl glow|r        - soft glow around the slot (currently " .. OnOff(db.glow) .. ")")
	print("  |cffffd100/wl border|r      - crisp border on the slot (currently " .. OnOff(db.border) .. ")")
	print("  |cffffd100/wl pulse|r       - pulse the glow/border (currently " .. OnOff(db.pulse) .. ")")
	print("  |cffffd100/wl tooltip|r     - add a tooltip line (currently " .. OnOff(db.tooltip) .. ")")
	print("  |cffffd100/wl color <c>|r   - set the colour: a name, hex (9f40ff) or r g b. /wl colors lists names")
	print("  |cffffd100/wl ignore <item>|r - never flag this item (link, ID or exact name; blank = current #1)")
	print("  |cffffd100/wl unignore <item>|r - remove an item from the ignore list")
	print("  |cffffd100/wl ignored|r     - list ignored items")
	print("  |cffffd100/wl config|r      - open the options panel")
	print("  |cffffd100/wl list [N]|r    - print the N cheapest items to chat (default 10)")
	print("  |cffffd100/wl test|r        - force the indicator onto the first visible slot (toggle)")
	print("  |cffffd100/wl debug|r       - report which bag frames and slots were found")
	print("  |cffffd100/wl reset|r       - restore default settings")
end

-- Diagnostic dump: which frames are visible, how many buttons were enumerated,
-- and which of them matched a ranked bag/slot. Open your bags first.
local function PrintDebug()
	ScanBags()
	Print("debug: enabled=%s count=%d candidates=%d ranked=%d",
		tostring(db.enabled), db.count, #results, math.min(db.count, #results))
	for rank = 1, math.min(db.count, #results) do
		local e = results[rank]
		local button = FindItemButton(e.bag, e.slot)
		local where = "no button (bag not open?)"
		if button then
			where = ("button found, shown=%s, level %d, size %dx%d"):format(
				tostring(button:IsShown()), button:GetFrameLevel(), button:GetWidth(), button:GetHeight())
		end
		print(("  rank %d -> bag %d slot %d %s | %s"):format(rank, e.bag, e.slot, e.link, where))
	end
	print(("  Blizzard lookup available: %s, combined frame: %s"):format(
		tostring(ContainerFrameUtil_GetItemButtonAndContainer ~= nil),
		ContainerFrameCombinedBags and (ContainerFrameCombinedBags:IsShown() and "shown" or "hidden") or "nil"))

	local function Report(frame, label)
		if not frame then
			print(("  %s: nil"):format(label))
			return
		end
		local method = frame.EnumerateValidItems and "EnumerateValidItems"
			or frame.Items and "Items" or "named buttons"
		if not frame:IsShown() then
			print(("  %s: hidden (bag id %s, %s)"):format(label, tostring(frame:GetID()), method))
			return
		end
		local buttons, matched, sample = 0, 0, nil
		EnumerateItemButtons(frame, function(button)
			buttons = buttons + 1
			local bag, slot = GetButtonBagAndSlot(button)
			if not sample then sample = ("first button bag=%s slot=%s"):format(tostring(bag), tostring(slot)) end
			if bag and slot and ranked[Key(bag, slot)] then matched = matched + 1 end
		end)
		print(("  %s: shown, id %s, %s, %d buttons, %d flagged, %s"):format(
			label, tostring(frame:GetID()), method, buttons, matched, sample or "no buttons"))
	end

	Report(ContainerFrameCombinedBags, "ContainerFrameCombinedBags")
	for i = 1, NUM_FRAMES do
		local frame = _G["ContainerFrame" .. i]
		if frame and frame:IsShown() then Report(frame, "ContainerFrame" .. i) end
	end
	local overlayCount, shownCount = 0, 0
	for _, ov in pairs(overlays) do
		overlayCount = overlayCount + 1
		if ov:IsShown() then shownCount = shownCount + 1 end
	end
	print(("  overlays created: %d, currently shown: %d"):format(overlayCount, shownCount))
end

local function PrintList(n)
	ScanBags()
	if #results == 0 then
		Print("no candidate items found.")
		return
	end
	n = math.max(1, math.min(tonumber(n) or 10, #results))
	Print("%d cheapest item(s) of %d candidates:", n, #results)
	for i = 1, n do
		local e = results[i]
		local stack = e.count > 1 and (" x" .. e.count) or ""
		print(("  %d. %s%s - %s  (bag %d, slot %d)"):format(i, e.link, stack, MoneyText(e.value), e.bag, e.slot))
	end
end

local TOGGLES = {
	toggle  = { key = "enabled",           label = "Worth Less" },
	novalue = { key = "includeNoValue",    label = "include unsellable items", rescan = true },
	reagent = { key = "includeReagentBag", label = "scan reagent bag",         rescan = true },
	price   = { key = "showPrice",         label = "price text" },
	rank    = { key = "showRank",          label = "rank number" },
	glow    = { key = "glow",              label = "glow" },
	border  = { key = "border",            label = "border" },
	pulse   = { key = "pulse",             label = "pulse" },
	tooltip = { key = "tooltip",           label = "tooltip line" },
}

SLASH_WORTHLESS1 = "/worthless"
SLASH_WORTHLESS2 = "/wl"
SlashCmdList.WORTHLESS = function(msg)
	msg = msg or ""
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "" or cmd == "help" then
		PrintHelp()
	elseif TOGGLES[cmd] then
		local t = TOGGLES[cmd]
		db[t.key] = not db[t.key]
		Print("%s %s.", t.label, OnOff(db[t.key]))
		WorthLess:RequestRefresh(t.rescan)
	elseif cmd == "count" then
		local n = tonumber(rest)
		if not n then
			Print("count is %d. Usage: /wl count N  (1-%d)", db.count, MAX_COUNT)
			return
		end
		db.count = math.max(1, math.min(MAX_COUNT, math.floor(n)))
		Print("now flagging the %d cheapest item(s).", db.count)
		WorthLess:RequestRefresh(true)
	elseif cmd == "list" then
		PrintList(rest)
	elseif cmd == "color" or cmd == "colour" then
		if rest == "" then PrintColors() else SetColor(rest) end
	elseif cmd == "colors" or cmd == "colours" then
		PrintColors()
	elseif cmd == "ignore" then
		if rest == "" then
			ScanBags()
			local top = results[1]
			if top then
				ns.IgnoreItem(top.itemID, top.name)
			else
				Print("nothing is flagged right now. Usage: /wl ignore <item link, ID or name>")
			end
		else
			local id, name = ns.ResolveItem(rest)
			if id then
				ns.IgnoreItem(id, name)
			else
				Print("could not find an item for '%s'. Shift-click an item into the command or use its ID.", rest)
			end
		end
	elseif cmd == "unignore" then
		local id = ns.ResolveItem(rest)
		if not id then
			-- Allow matching against stored names of items no longer in the bags.
			local wanted = rest:lower()
			for storedID, stored in pairs(db.ignored) do
				local name = GetItemInfo(storedID) or (type(stored) == "string" and stored)
				if name and name:lower() == wanted then id = storedID break end
			end
		end
		if not id or not ns.UnignoreItem(id) then
			Print("'%s' is not on the ignore list.", rest)
		end
	elseif cmd == "ignored" then
		local list = ns.GetIgnoredList()
		if #list == 0 then
			Print("the ignore list is empty.")
		else
			Print("%d ignored item(s):", #list)
			for _, item in ipairs(list) do
				print(("  %s (%d)"):format(item.link or item.name, item.id))
			end
		end
	elseif cmd == "config" or cmd == "options" or cmd == "ui" then
		if ns.OpenOptions then ns.OpenOptions() else Print("options panel not available.") end
	elseif cmd == "test" then
		testMode = not testMode
		Print("test mode %s. %s", OnOff(testMode),
			testMode and "The first visible bag slot should now show the indicator." or "")
		WorthLess:RequestRefresh()
	elseif cmd == "debug" then
		PrintDebug()
	elseif cmd == "reset" then
		wipe(db)
		ApplyDefaults()
		Print("settings reset to defaults.")
		WorthLess:RequestRefresh(true)
	else
		Print("unknown command '%s'.", cmd)
		PrintHelp()
	end
end

-------------------------------------------------------------------------------
-- Shared with WorthLess_Options.lua through the addon namespace
-------------------------------------------------------------------------------

ns.Print        = Print
ns.MoneyText    = MoneyText
ns.NAMED_COLORS = NAMED_COLORS
ns.ParseColor   = ParseColor
ns.ColorSwatch  = ColorSwatch
ns.MAX_COUNT    = MAX_COUNT
ns.DEFAULTS     = DEFAULTS
ns.results      = results -- same table for the addon's lifetime; wiped, never replaced
ns.ScanBags     = ScanBags
ns.RequestRefresh = function(rescan) WorthLess:RequestRefresh(rescan) end
