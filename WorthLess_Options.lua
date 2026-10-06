--[[
	Worth Less options panel
	Registered under Options -> AddOns -> Worth Less. Also opened with /wl config.
	Everything it needs from the core comes through the addon namespace (ns).
]]

local ADDON_NAME, ns = ...

local PANEL_WIDTH, PANEL_HEIGHT = 620, 590
local ROW_HEIGHT = 22
local MAX_ROWS = 5
local QUESTION_MARK_ICON = 134400

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local panel, category
local checkboxes, cheapRows, ignoreRows = {}, {}, {}
local countSlider, swatchLow, swatchHigh
local cheapHeader, ignoreEdit, ignoreScroll, ignoreContent, ignoreEmpty

local function db() return ns.db end

-------------------------------------------------------------------------------
-- Colour picker (new SetupColorPickerAndShow API with fallback to OpenColorPicker)
-------------------------------------------------------------------------------

local function OpenPicker(color, onChange)
	local prev = { r = color.r, g = color.g, b = color.b }
	local function apply()
		local r, g, b = ColorPickerFrame:GetColorRGB()
		color.r, color.g, color.b = r, g, b
		onChange()
	end
	local function cancel()
		color.r, color.g, color.b = prev.r, prev.g, prev.b
		onChange()
	end
	local info = {
		r = color.r, g = color.g, b = color.b,
		hasOpacity = false,
		swatchFunc = apply,
		cancelFunc = cancel,
	}
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow(info)
	else
		info.func = apply
		OpenColorPicker(info)
	end
end

-------------------------------------------------------------------------------
-- Widget builders
-------------------------------------------------------------------------------

local function MakeHeader(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function MakeCheckbox(parent, key, label, tooltip, x, y, rescan)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(26, 26)
	cb:SetPoint("TOPLEFT", x, y)
	local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	text:SetText(label)
	cb.key = key
	cb:SetScript("OnClick", function(self)
		db()[key] = self:GetChecked() and true or false
		ns.RequestRefresh(rescan)
	end)
	cb:SetScript("OnEnter", function(self)
		if not tooltip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(label, 1, 1, 1)
		GameTooltip:AddLine(tooltip, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	checkboxes[#checkboxes + 1] = cb
	return cb
end

local function MakeSlider(parent, x, y)
	local name = "WorthLessCountSlider"
	-- Modern clients ship UISliderTemplateWithLabels; older ones OptionsSliderTemplate.
	local ok, slider = pcall(CreateFrame, "Slider", name, parent, "UISliderTemplateWithLabels")
	if not ok or not slider then
		ok, slider = pcall(CreateFrame, "Slider", name, parent, "OptionsSliderTemplate")
	end
	if not ok or not slider then
		-- Neither template exists: build a plain slider by hand.
		slider = CreateFrame("Slider", name, parent, "BackdropTemplate")
		slider:SetOrientation("HORIZONTAL")
		slider:SetHeight(17)
		slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
		slider:SetBackdrop({
			bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
			edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
			edgeSize = 8, tile = true, tileSize = 8,
			insets = { left = 3, right = 3, top = 6, bottom = 6 },
		})
	end
	slider:SetPoint("TOPLEFT", x, y)
	slider:SetSize(220, 17)
	slider:SetMinMaxValues(1, ns.MAX_COUNT)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)

	local label = slider.Text or _G[name .. "Text"]
	if not label then
		label = slider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		label:SetPoint("BOTTOM", slider, "TOP", 0, 2)
	end
	local low = slider.Low or _G[name .. "Low"]
	if not low then
		low = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 2, 0)
	end
	local high = slider.High or _G[name .. "High"]
	if not high then
		high = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", -2, 0)
	end
	low:SetText("1")
	high:SetText(tostring(ns.MAX_COUNT))
	slider.label = label

	slider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value + 0.5)
		label:SetText(("Items to flag: %d"):format(value))
		if self.updating then return end
		local d = db()
		if d and d.count ~= value then
			d.count = value
			ns.RequestRefresh(true)
		end
	end)
	return slider
end

local function MakeSwatch(parent, key, label, x, y)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(22, 22)
	btn:SetPoint("TOPLEFT", x, y)
	local border = btn:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(0.6, 0.6, 0.6)
	local tex = btn:CreateTexture(nil, "ARTWORK")
	tex:SetPoint("TOPLEFT", 2, -2)
	tex:SetPoint("BOTTOMRIGHT", -2, 2)
	tex:SetColorTexture(1, 1, 1)
	local text = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", btn, "RIGHT", 6, 0)
	text:SetText(label)
	btn.tex = tex
	function btn:Update()
		local c = db() and db()[key]
		if c then self.tex:SetColorTexture(c.r, c.g, c.b) end
	end
	btn:SetScript("OnClick", function(self)
		OpenPicker(db()[key], function()
			self:Update()
			ns.RequestRefresh()
		end)
	end)
	return btn
end

-- A row showing icon, name, optional value, and one action button on the right.
local function MakeItemRow(parent, buttonText, onClick)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:EnableMouse(true)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", 2, 0)

	row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.button:SetSize(64, 20)
	row.button:SetPoint("RIGHT", -2, 0)
	row.button:SetText(buttonText)
	row.button:SetScript("OnClick", function() onClick(row) end)

	row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.value:SetPoint("RIGHT", row.button, "LEFT", -10, 0)
	row.value:SetJustifyH("RIGHT")

	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.text:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)

	row:SetScript("OnEnter", function(self)
		if not self.link then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(self.link)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

-------------------------------------------------------------------------------
-- Refreshing the panel from the saved settings and the latest scan
-------------------------------------------------------------------------------

local function UpdateWidgets()
	local d = db()
	if not d then return end
	for _, cb in ipairs(checkboxes) do
		cb:SetChecked(d[cb.key] and true or false)
	end
	countSlider.updating = true
	countSlider:SetValue(d.count)
	countSlider.updating = false
	countSlider.label:SetText(("Items to flag: %d"):format(d.count))
	swatchLow:Update()
	swatchHigh:Update()
end

local function UpdateCheapList()
	local d = db()
	if not d then return end
	local results = ns.results
	local shown = math.min(d.count, #results)
	for i = 1, MAX_ROWS do
		local row, e = cheapRows[i], results[i]
		if i <= shown and e then
			row.entry = e
			row.link = e.link
			row.icon:SetTexture(e.icon or QUESTION_MARK_ICON)
			local stack = e.count > 1 and (" x" .. e.count) or ""
			row.text:SetText(("%d.  %s%s"):format(i, e.link or e.name, stack))
			row.value:SetText(ns.MoneyText(e.value))
			row:Show()
		else
			row.entry, row.link = nil, nil
			row:Hide()
		end
	end
	if #results == 0 then
		cheapHeader:SetText("Cheapest items right now  (nothing found)")
	else
		cheapHeader:SetText(("Cheapest items right now  (%d flagged of %d candidates)"):format(shown, #results))
	end
end

local function UpdateIgnoredList()
	local list = ns.GetIgnoredList()
	for i, item in ipairs(list) do
		local row = ignoreRows[i]
		if not row then
			row = MakeItemRow(ignoreContent, "Remove", function(r) ns.UnignoreItem(r.itemID) end)
			row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
			row:SetPoint("RIGHT", ignoreContent, "RIGHT", 0, 0)
			ignoreRows[i] = row
		end
		row.itemID = item.id
		row.link = item.link
		local icon = select(5, GetItemInfoInstant(item.id))
		row.icon:SetTexture(icon or QUESTION_MARK_ICON)
		row.text:SetText(item.link or item.name)
		row.value:SetText("")
		row:Show()
	end
	for i = #list + 1, #ignoreRows do
		ignoreRows[i]:Hide()
	end
	ignoreContent:SetHeight(math.max(1, #list * ROW_HEIGHT))
	ignoreEmpty:SetShown(#list == 0)
end

local function RefreshPanel()
	if not (panel and panel:IsShown()) then return end
	UpdateWidgets()
	UpdateCheapList()
	UpdateIgnoredList()
end

-------------------------------------------------------------------------------
-- Ignore list input: typed text, shift-clicked links, dragged items
-------------------------------------------------------------------------------

local function AddFromEditBox()
	local text = ignoreEdit:GetText()
	local id, name = ns.ResolveItem(text)
	if id then
		ns.IgnoreItem(id, name)
		ignoreEdit:SetText("")
	elseif text and text ~= "" then
		ns.Print("could not find an item for '%s'. Shift-click an item into the box or use its ID.", text)
	end
end

local function AcceptDroppedItem()
	local kind, id = GetCursorInfo()
	if kind == "item" and id then
		ns.IgnoreItem(tonumber(id))
		ClearCursor()
		return true
	end
	return false
end

-------------------------------------------------------------------------------
-- Panel layout
-------------------------------------------------------------------------------

local function BuildPanel()
	panel = CreateFrame("Frame", "WorthLessOptionsPanel", UIParent)
	panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
	panel:Hide()
	panel.name = "Worth Less"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Worth Less")

	local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	subtitle:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	subtitle:SetJustifyH("LEFT")
	subtitle:SetText("Flags the lowest-value non-quest items in your bags so you know what to vendor or drop first. Slash command: /wl")

	-- Display -----------------------------------------------------------------
	MakeHeader(panel, "Display", 16, -64)
	local y = -84
	MakeCheckbox(panel, "enabled",   "Enabled",                 nil, 16, y,       true)
	MakeCheckbox(panel, "glow",      "Glow around the slot",    nil, 16, y - 26)
	MakeCheckbox(panel, "border",    "Border on the slot",      nil, 16, y - 52)
	MakeCheckbox(panel, "pulse",     "Pulse the glow/border",   nil, 16, y - 78)
	MakeCheckbox(panel, "showPrice", "Show value on the slot",  nil, 16, y - 104)
	MakeCheckbox(panel, "showRank",  "Show rank number when flagging more than one", nil, 310, y)
	MakeCheckbox(panel, "tooltip",   "Add a line to the item tooltip", nil, 310, y - 26)
	MakeCheckbox(panel, "includeReagentBag", "Scan the reagent bag",
		"The reagent bag does not open with the other bags, so a flagged item in there is easy to miss.",
		310, y - 52, true)
	MakeCheckbox(panel, "includeNoValue", "Include items with no vendor value",
		"Hearthstone, keystones and similar unsellable items are normally skipped.",
		310, y - 78, true)

	-- Count + colours ---------------------------------------------------------
	countSlider = MakeSlider(panel, 24, -238)
	swatchLow  = MakeSwatch(panel, "colorLow",  "Rank 1 colour", 310, -222)
	swatchHigh = MakeSwatch(panel, "colorHigh", "Last rank colour (gradient end)", 310, -250)

	-- Live list of the cheapest items ------------------------------------------
	cheapHeader = MakeHeader(panel, "Cheapest items right now", 16, -290)
	local listTop = -308
	for i = 1, MAX_ROWS do
		local row = MakeItemRow(panel, "Ignore", function(r)
			if r.entry then ns.IgnoreItem(r.entry.itemID, r.entry.name) end
		end)
		row:SetPoint("TOPLEFT", 16, listTop - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
		cheapRows[i] = row
	end

	-- Ignore list ----------------------------------------------------------------
	local ignoreY = listTop - MAX_ROWS * ROW_HEIGHT - 14
	MakeHeader(panel, "Ignored items (never flagged)", 16, ignoreY)

	ignoreEdit = CreateFrame("EditBox", "WorthLessIgnoreEditBox", panel, "InputBoxTemplate")
	ignoreEdit:SetSize(300, 20)
	ignoreEdit:SetAutoFocus(false)
	ignoreEdit:SetPoint("TOPLEFT", 24, ignoreY - 22)
	ignoreEdit:SetScript("OnEnterPressed", function(self) AddFromEditBox(); self:ClearFocus() end)
	ignoreEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	addButton:SetSize(60, 22)
	addButton:SetPoint("LEFT", ignoreEdit, "RIGHT", 8, 0)
	addButton:SetText("Add")
	addButton:SetScript("OnClick", AddFromEditBox)

	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", 16, ignoreY - 48)
	hint:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("Type an item name or ID and press Enter, shift-click an item into the box, or drag an item onto the list below.")

	-- Plain ScrollFrame plus the modern MinimalScrollBar when available; the old
	-- UIPanelScrollFrameTemplate no longer exists on this client. Mouse wheel
	-- scrolling is handled by hand so it works even without a scroll bar.
	ignoreScroll = CreateFrame("ScrollFrame", "WorthLessIgnoreScroll", panel)
	ignoreScroll:SetPoint("TOPLEFT", 16, ignoreY - 68)
	ignoreScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -40, 16)

	ignoreContent = CreateFrame("Frame", nil, ignoreScroll)
	ignoreContent:SetSize(1, 1)
	ignoreScroll:SetScrollChild(ignoreContent)
	ignoreScroll:SetScript("OnSizeChanged", function(self, width) ignoreContent:SetWidth(width) end)
	ignoreContent:SetWidth(ignoreScroll:GetWidth())

	local okBar, scrollBar = pcall(CreateFrame, "EventFrame", nil, panel, "MinimalScrollBar")
	if okBar and scrollBar and ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar then
		scrollBar:SetPoint("TOPLEFT", ignoreScroll, "TOPRIGHT", 6, 0)
		scrollBar:SetPoint("BOTTOMLEFT", ignoreScroll, "BOTTOMRIGHT", 6, 0)
		ScrollUtil.InitScrollFrameWithScrollBar(ignoreScroll, scrollBar)
	else
		ignoreScroll:EnableMouseWheel(true)
		ignoreScroll:SetScript("OnMouseWheel", function(self, delta)
			local maxScroll = math.max(0, ignoreContent:GetHeight() - self:GetHeight())
			local target = self:GetVerticalScroll() - delta * ROW_HEIGHT * 2
			self:SetVerticalScroll(math.max(0, math.min(maxScroll, target)))
		end)
	end

	local backdrop = ignoreScroll:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints()
	backdrop:SetColorTexture(0, 0, 0, 0.25)

	ignoreEmpty = ignoreScroll:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ignoreEmpty:SetPoint("TOPLEFT", 8, -6)
	ignoreEmpty:SetText("No ignored items yet.")

	for _, frame in ipairs({ ignoreScroll, ignoreContent }) do
		frame:EnableMouse(true)
		frame:SetScript("OnReceiveDrag", AcceptDroppedItem)
		frame:SetScript("OnMouseUp", AcceptDroppedItem)
	end

	-- Shift-clicking an item while the edit box has focus pastes its link.
	if ChatEdit_InsertLink then
		hooksecurefunc("ChatEdit_InsertLink", function(link)
			if link and ignoreEdit:HasFocus() then
				ignoreEdit:Insert(link)
			end
		end)
	end

	panel:SetScript("OnShow", function()
		RefreshPanel()
		ns.RequestRefresh(true) -- rescan so the list is current
	end)
end

-------------------------------------------------------------------------------
-- Registration with the Settings UI (new API) or Interface Options (old API)
-------------------------------------------------------------------------------

local function RegisterPanel()
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		category = Settings.RegisterCanvasLayoutCategory(panel, "Worth Less")
		Settings.RegisterAddOnCategory(category)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end

function ns.OpenOptions()
	if not panel then
		ns.Print("options panel is not available on this client.")
		return
	end
	if category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(panel)
		InterfaceOptionsFrame_OpenToCategory(panel) -- twice: the old frame mis-scrolls on first call
	end
end

-- Called by the core after every scan/refresh so the list updates live.
ns.OnRefresh = RefreshPanel

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	local ok, err = pcall(function()
		BuildPanel()
		RegisterPanel()
	end)
	if not ok then
		panel = nil
		ns.Print("options panel failed to load: %s", tostring(err))
	end
end)
