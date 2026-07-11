VWB = VWB or {}
VWB.UI = {}

-- ============================================================================
-- BACKDROP DEFINITIONS
-- ============================================================================

local BACKDROP_FLAT = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

local BACKDROP_BORDERLESS = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = nil,
    tile = false,
}

VWB.UI.BACKDROP_FLAT = BACKDROP_FLAT
VWB.UI.BACKDROP_BORDERLESS = BACKDROP_BORDERLESS
VWB.UI.BACKDROP_PANEL = VWB.Theme.BACKDROP_PANEL
VWB.UI.BACKDROP_CARD = VWB.Theme.BACKDROP_CARD

-- ============================================================================
-- THEME HELPERS
-- ============================================================================

local function GetScheme()
    if VWB.Theme and VWB.Theme.currentScheme then return VWB.Theme.currentScheme end
    if VWB.Colors and VWB.Colors.Schemes then return VWB.Colors.Schemes.SolarizedDark end
    return nil
end

local function RegisterWidget(widget, widgetType)
    if VWB.Theme and VWB.Theme.Register then VWB.Theme:Register(widget, widgetType) end
end

function VWB.UI:GetScheme() return GetScheme() end

-- Shared item-name reader: a veneer over the ItemData broker (Constitution
-- migration step 2 -- the broker is THE one requester; latch-at-callback
-- means names can never depend on client cache retention). Same callable
-- (key) -> name | PENDING contract the views already use; terminal
-- no-data/dead keys resolve to the honest "item:<id>" fallback so
-- "Loading..." states always end.
local itemNameRes
function VWB.UI:ItemNameResource()
    if not itemNameRes then
        itemNameRes = function(itemID) return VWB.ItemData.nameFor(itemID) end
    end
    return itemNameRes
end
function VWB.UI:RegisterWidget(widget, widgetType) RegisterWidget(widget, widgetType) end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

function VWB.UI:ClearChildren(parent)
    if not parent then return end
    local children = { parent:GetChildren() }
    for i = 1, #children do
        children[i]:Hide()
        children[i]:SetParent(nil)
    end
end

-- ============================================================================
-- ROW CACHE (reuse-by-index)
-- Refresh loops must never recreate frames: frames are cached on the content
-- frame per kind and reused positionally across refreshes.
-- Usage per refresh:
--   VWB.UI:ResetRows(content)
--   local row = VWB.UI:AcquireRow(content, "material", CreateMaterialRow)
--   ... paint row ...
--   VWB.UI:HideUnusedRows(content)
-- ============================================================================

-- Async one-shot item-name resolution, broker-backed (Constitution migration
-- step 2 -- the old direct ItemEventListener wiring here double-requested:
-- AddCallback itself issues the accessor call, verified in Blizzard's
-- AsyncCallbackSystem.lua). fn(name) fires exactly once when the name
-- latches; a terminal no-data/dead id never fires fn -- callers record
-- nothing rather than "Unknown Item".
function VWB.UI.ResolveItemName(itemID, fn)
    VWB.ItemData.onReady(itemID, function(rec)
        if rec then fn(rec.name) end
    end)
end

function VWB.UI:ResetRows(content)
    content._rowCache = content._rowCache or {}
    content._rowCursor = {}
end

function VWB.UI:AcquireRow(content, kind, factory)
    local cache = content._rowCache[kind]
    if not cache then
        cache = {}
        content._rowCache[kind] = cache
    end
    local cursor = (content._rowCursor[kind] or 0) + 1
    content._rowCursor[kind] = cursor
    local row = cache[cursor]
    if not row then
        row = factory(content)
        cache[cursor] = row
    end
    row:ClearAllPoints()
    row:Show()
    return row
end

function VWB.UI:HideUnusedRows(content)
    for kind, cache in pairs(content._rowCache) do
        for i = (content._rowCursor[kind] or 0) + 1, #cache do
            cache[i]:Hide()
        end
    end
end

-- D2: ColorCode cache — rebuilt lazily when the scheme table identity changes
-- (theme switches swap VWB.Theme.currentScheme to a new table). The map is
-- module-scoped so updateRow + tooltip paths share a single allocation per
-- theme lifetime instead of 8-entry table per call.
local _colorCodeScheme = nil  -- scheme table that produced _colorCodeMap
local _colorCodeMap = {}
local function _rebuildColorCodeMap(c)
    _colorCodeScheme = c
    _colorCodeMap = {
        cyan = c.accent, yellow = c.warning, green = c.success, red = c.error,
        blue = c.accent, base0 = c.text, base1 = c.text_header, base01 = c.text,
        base02 = c.panel, base03 = c.bg,
    }
end

function VWB.UI:ColorCode(colorName)
    local c = GetScheme()
    if not c then return "|cFFffffff" end
    if c ~= _colorCodeScheme then _rebuildColorCodeMap(c) end
    local color = _colorCodeMap[colorName]
    if color then
        return string.format("|cFF%02x%02x%02x", math.floor(color.r * 255), math.floor(color.g * 255), math.floor(color.b * 255))
    end
    return "|cFFffffff"
end

function VWB.UI:ToHex(color)
    if not color then return "FFFFFF" end
    return string.format("%02X%02X%02X", math.floor((color.r or 1) * 255), math.floor((color.g or 1) * 255), math.floor((color.b or 1) * 255))
end

-- ============================================================================
-- MONEY FORMATTING (real coin icons via C_CurrencyInfo.GetCoinTextureString)
-- ============================================================================

local MONEY_DEFAULT_FONT_HEIGHT = 12
local MONEY_COMPACT_GOLD_THRESHOLD = 1000000 -- gold (not copper); at/above this, print "X.XXM gold" plain text instead of coin icons

function VWB.UI:FormatMoney(copper, opts)
    if not copper or copper == 0 then return VWB.UI:ColorCode("base01") .. "--|r" end
    opts = opts or {}

    copper = math.floor(copper + 0.5) -- callers pass float averages; GetCoinTextureString needs an integer

    -- Losses: GetCoinTextureString rejects negative amounts, so render the
    -- absolute value behind a red minus (Ledger profits can be negative now
    -- that the AH cut is modeled)
    local sign = ""
    if copper < 0 then
        copper = -copper
        sign = VWB.UI:ColorCode("red") .. "-|r"
    end

    local gold = math.floor(copper / 10000)
    if gold >= MONEY_COMPACT_GOLD_THRESHOLD then
        return sign .. string.format("%.2fM gold", gold / 1000000)
    end

    return sign .. C_CurrencyInfo.GetCoinTextureString(copper, opts.fontHeight or MONEY_DEFAULT_FONT_HEIGHT)
end


-- ============================================================================
-- BUTTON (HDG's common-button-tertiary chrome -- unification 2026-07-11:
-- ONE button look addon-wide, ported from HDGR_Components/_Theme)
-- ============================================================================
-- Fixed dark Blizzard atlas family that vertex-tints cleanly. States: normal
-- tint = scheme border, hover = accent, pushed = darkened accent, active
-- (toggled) = -depressed- atlas variants + accent tint. Text sits on the
-- FIXED DARK atlas in every scheme, so its base tone is a constant light
-- gray, NOT scheme.text (a light scheme's dark text would vanish on it);
-- active text = scheme.text_header (the scheme's header accent).

local TERTIARY_NORMAL        = "common-button-tertiary-normal"
local TERTIARY_HOVER         = "common-button-tertiary-hover"
local TERTIARY_PRESSED       = "common-button-tertiary-pressed"
local TERTIARY_DISABLED      = "common-button-tertiary-disabled"
local TERTIARY_ACTIVE_NORMAL = "common-button-tertiary-depressed-normal"
local TERTIARY_ACTIVE_HOVER  = "common-button-tertiary-depressed-hover"
local TERTIARY_TEXT          = { r = 0.88, g = 0.88, b = 0.88 }

local function ApplyTertiaryChrome(btn)
    btn:SetNormalAtlas(TERTIARY_NORMAL)
    btn:SetHighlightAtlas(TERTIARY_HOVER)
    btn:SetPushedAtlas(TERTIARY_PRESSED)
    btn:SetDisabledAtlas(TERTIARY_DISABLED)
    for _, getter in ipairs({ "GetNormalTexture", "GetHighlightTexture",
                              "GetPushedTexture", "GetDisabledTexture" }) do
        local t = btn[getter](btn)
        t:ClearAllPoints()
        t:SetAllPoints(btn)
    end
    -- y=1: the atlas interior shades upward; nudge text to visual center (HDG).
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER", 0, 1)
    btn:SetFontString(fs)
    btn.text = fs -- legacy alias: pre-unification widgets exposed .text
    btn._tertiary = true
    btn._active = false
    return fs
end

local function TintButtonTextures(btn, normal, hover, pushed, disabled)
    local function paint(getter, c, mult)
        local t = btn[getter](btn)
        t:SetVertexColor(c.r * (mult or 1), c.g * (mult or 1), c.b * (mult or 1), c.a or 1)
    end
    paint("GetNormalTexture", normal)
    paint("GetHighlightTexture", hover)
    paint("GetPushedTexture", pushed, 0.7)
    paint("GetDisabledTexture", disabled)
end

-- Public: the ThemeEngine Button/SegmentedToggle skinners route tertiary
-- widgets here on theme switch; toggles call it on state flips.
function VWB.UI:PaintTertiaryButton(btn, c)
    local fs = btn:GetFontString()
    if btn._active then
        btn:SetNormalAtlas(TERTIARY_ACTIVE_NORMAL)
        btn:SetHighlightAtlas(TERTIARY_ACTIVE_HOVER)
        TintButtonTextures(btn, c.accent, c.accent, c.accent, c.button_inactive)
        fs:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b, 1)
    else
        btn:SetNormalAtlas(TERTIARY_NORMAL)
        btn:SetHighlightAtlas(TERTIARY_HOVER)
        TintButtonTextures(btn, c.border, c.accent, c.accent, c.button_inactive)
        fs:SetTextColor(TERTIARY_TEXT.r, TERTIARY_TEXT.g, TERTIARY_TEXT.b, 1)
    end
end

function VWB.UI:CreateButton(parent, text, width, height, opts)
    if opts and opts.flat then
        -- Legacy flat-backdrop construction, kept ONLY for callers that own
        -- their backdrop painting (Settings' Hard Reset danger button -- the
        -- one deliberate exception to the tertiary unification).
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(width or 100, height or 24)
        btn:SetNormalFontObject("GameFontHighlight")
        btn:SetText(text)
        btn:SetBackdrop(BACKDROP_FLAT)
        local scheme = GetScheme()
        btn:SetBackdropColor(scheme.button_normal.r, scheme.button_normal.g, scheme.button_normal.b, scheme.button_normal.a)
        btn:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)
        RegisterWidget(btn, "Button")
        return btn
    end

    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 100, height or 24)
    ApplyTertiaryChrome(btn)
    btn:SetText(text)
    function btn:SetActive(v)
        self._active = v and true or false
        VWB.UI:PaintTertiaryButton(self, GetScheme())
    end
    VWB.UI:PaintTertiaryButton(btn, GetScheme())
    RegisterWidget(btn, "Button")
    return btn
end

-- ============================================================================
-- ICON BUTTON
-- ============================================================================

function VWB.UI:CreateIconButton(parent, icon, width, height, tooltip)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 24, height or 24)
    btn:SetBackdrop(BACKDROP_FLAT)

    local scheme = GetScheme()
    btn:SetBackdropColor(scheme.button_normal.r, scheme.button_normal.g, scheme.button_normal.b, scheme.button_normal.a)
    btn:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetSize(width and width - 6 or 18, height and height - 6 or 18)
    tex:SetPoint("CENTER")
    tex:SetTexture(icon)
    btn.icon = tex

    btn:SetScript("OnEnter", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(tooltip, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_normal.r, c.button_normal.g, c.button_normal.b, c.button_normal.a)
        GameTooltip:Hide()
    end)

    RegisterWidget(btn, "Button")
    return btn
end



-- ============================================================================
-- VIRTUALIZED LIST (Wrapper: row-pooled list via CreateScrollBox)
-- ============================================================================

function VWB.UI:CreateVirtualizedList(parent, options)
    options = options or {}
    local rowTemplate = options.rowTemplate   -- function(parent) -> frame
    local updateRow   = options.updateRow     -- function(row, data, index)
    local onRowClick  = options.onRowClick    -- function(data, index)
    local onRowEnter  = options.onRowEnter    -- function(data, rowFrame) -- show a tooltip
    local onRowLeave  = options.onRowLeave    -- function(data, rowFrame) -- optional

    return self:CreateScrollBox(parent, {
        rowHeight = options.rowHeight or 20,
        padding   = options.padding or { top = 0, bottom = 0, left = 0, right = 0 },
        spacing   = options.spacing or 0,
        factory   = function(frame)
            if rowTemplate then rowTemplate(frame) end
            -- shared hover highlight, created once per pooled row
            local hl = frame:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.07); hl:Hide()
            frame._hoverHL = hl
        end,
        initializer = function(row, elementData)
            row.data = elementData -- factory's own click/hover handlers read row.data; latch it so callers need not
            if updateRow then updateRow(row, elementData, nil) end
            if not row._rowHooked then
                row:EnableMouse(true)
                row:SetScript("OnMouseUp", function(self)
                    if onRowClick then onRowClick(self.data or elementData, nil) end
                end)
                row:SetScript("OnEnter", function(self)
                    if self._hoverHL then self._hoverHL:Show() end
                    if onRowEnter then onRowEnter(self.data or elementData, self) end
                end)
                row:SetScript("OnLeave", function(self)
                    if self._hoverHL then self._hoverHL:Hide() end
                    if _G.GameTooltip and _G.GameTooltip:IsOwned(self) then _G.GameTooltip:Hide() end
                    if onRowLeave then onRowLeave(self.data or elementData, self) end
                end)
                row._rowHooked = true
            end
        end,
    })
end

-- ============================================================================
-- SCROLLBOX (Modern Blizzard 12.x: WowScrollBoxList + DataProvider)
-- ============================================================================

local scrollBoxCounter = 0

function VWB.UI:CreateScrollBox(parent, options)
    options = options or {}
    local rowHeight = options.rowHeight or VWB.Constants.UI.recipeRowHeight or 22
    local padding = options.padding or { top = 0, bottom = 0, left = 0, right = 0 }
    if type(padding) == "number" then
        padding = { top = padding, bottom = padding, left = padding, right = padding }
    end
    local spacing = options.spacing or 0

    scrollBoxCounter = scrollBoxCounter + 1
    local listName = "VWBScrollBox" .. scrollBoxCounter

    -- Container
    local container = CreateFrame("Frame", listName .. "_Container", parent)
    container:SetAllPoints()

    -- Background panel (marble texture)
    local bg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    bg:SetAllPoints()
    bg:SetBackdrop(VWB.Theme.BACKDROP_PANEL)
    local scheme = GetScheme()
    local dColors = VWB.Constants:GetDerivedColors(scheme)
    bg:SetBackdropColor(dColors.marble_tint.r, dColors.marble_tint.g, dColors.marble_tint.b, dColors.marble_tint.a)
    bg:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)
    bg:SetFrameLevel(container:GetFrameLevel())
    container.bg = bg

    -- ScrollBox
    local scrollBox = CreateFrame("Frame", listName, container, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", padding.left, -padding.top)
    scrollBox:SetPoint("BOTTOMRIGHT", -padding.right - 14, padding.bottom)

    -- ScrollBar
    local scrollBar = CreateFrame("EventFrame", listName .. "_Bar", container, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 2, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 2, 0)

    -- View with padding and spacing
    local view = CreateScrollBoxListLinearView(padding.top, padding.bottom, padding.left, padding.right, spacing)

    -- Element initializer - uses template or custom factory
    if options.template then
        view:SetElementInitializer(options.template, options.initializer or function() end)
    elseif options.factory then
        view:SetElementExtent(rowHeight)
        -- Custom frame factory: factory(parent) returns a frame
        view:SetElementInitializer("Frame", function(frame, elementData)
            if not frame._initialized then
                Mixin(frame, BackdropTemplateMixin)
                frame:OnBackdropLoaded()
                frame:EnableMouse(true) -- plain Frames don't get mouse input; factories wire OnEnter/OnMouseUp
                options.factory(frame)
                frame._initialized = true
            end
            if options.initializer then
                options.initializer(frame, elementData, GetScheme())
            end
        end)
    elseif options.initializer then
        -- Custom initializer only (no factory) -- Button+Backdrop for OnClick support
        view:SetElementExtent(rowHeight)
        view:SetElementInitializer("Button", function(frame, elementData)
            if not frame._initialized then
                Mixin(frame, BackdropTemplateMixin)
                frame:OnBackdropLoaded()
                frame:SetHeight(rowHeight)
                frame:RegisterForClicks("AnyUp")
                frame._initialized = true
            end
            options.initializer(frame, elementData, GetScheme())
        end)
    else
        -- Default: simple text row
        view:SetElementExtent(rowHeight)
        view:SetElementInitializer("Frame", function(frame, elementData)
            if not frame._initialized then
                frame:SetHeight(rowHeight)
                local bg2 = frame:CreateTexture(nil, "BACKGROUND")
                bg2:SetAllPoints()
                bg2:SetTexture("Interface\\Buttons\\WHITE8x8")
                bg2:SetVertexColor(0, 0, 0, 0)
                frame._bg = bg2

                local icon = frame:CreateTexture(nil, "ARTWORK")
                icon:SetSize(rowHeight - 4, rowHeight - 4)
                icon:SetPoint("LEFT", 2, 0)
                frame.icon = icon

                local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
                text:SetPoint("RIGHT", -5, 0)
                text:SetJustifyH("LEFT")
                frame.text = text

                frame:EnableMouse(true)
                frame:SetScript("OnEnter", function(self)
                    local c = GetScheme()
                    self._bg:SetVertexColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
                end)
                frame:SetScript("OnLeave", function(self)
                    self._bg:SetVertexColor(0, 0, 0, 0)
                end)
                frame._initialized = true
            end
            if elementData.name then
                frame.text:SetText(elementData.name)
            end
        end)
    end

    -- Initialize ScrollBox with ScrollBar
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    -- Public API
    container.scrollBox = scrollBox
    container.scrollBar = scrollBar

    function container:SetData(dataArray)
        -- InsertTable bulk-appends in ONE native call. The per-item Insert loop
        -- fired an OnInsert event ~9900x on a full Stockroom paint; no sort
        -- comparator is set here, so InsertTable is a plain append -- same order.
        local dataProvider = CreateDataProvider()
        if dataArray then dataProvider:InsertTable(dataArray) end
        scrollBox:SetDataProvider(dataProvider, ScrollBoxConstants.RetainScrollPosition)
    end

    function container:GetDataProvider()
        return scrollBox:GetDataProvider()
    end

    function container:Refresh()
        local dp = scrollBox:GetDataProvider()
        if dp then
            scrollBox:SetDataProvider(dp, ScrollBoxConstants.RetainScrollPosition)
        end
    end

    function container:ScrollToIndex(index)
        local dp = scrollBox:GetDataProvider()
        if dp then
            local elementData = dp:Find(index)
            if elementData then
                scrollBox:ScrollToElementData(elementData)
            end
        end
    end

    -- Theme update listener
    if VWB.EventBus then
        VWB.EventBus:Register("VWB_THEME_UPDATE", function()
            local c = GetScheme()
            local dc = VWB.Constants:GetDerivedColors(c)
            bg:SetBackdropColor(dc.marble_tint.r, dc.marble_tint.g, dc.marble_tint.b, dc.marble_tint.a)
            bg:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
            container:Refresh()
        end)
    end

    RegisterWidget(container, "ScrollBox")
    return container
end

-- ============================================================================
-- QUEUE ROW (removable ticket row for the crafting queue)
-- ONE canonical implementation (Recipes_View carried a drifted parallel copy;
-- unification 2026-07-11). Entry point:
--   BuildQueueRow(row, opts)   fill an EXISTING frame -- pass as the
--                              rowTemplate body for pooled VirtualizedList rows
--                              (no row-level scripts: the list owns hover/click)
-- (A standalone CreateQueueRow wrapper existed briefly; deleted unused in the
-- 2026-07-11 hygiene pass -- pooled rows are the only consumer.)
-- opts callbacks (all read row._item, wired ONCE at build):
--   onRemove(item)             the "x" button
--   onQtyDelta(item, delta)    -/+ steppers; delta pre-multiplied by shift x5
--   onCraft(item)              hammer click; button hidden when omitted, and
--                              per-row gated in SetData (own char + knows it)
--   craftTooltipLine           hammer hover body copy (default below)
-- ============================================================================

function VWB.UI:BuildQueueRow(row, options)
    options = options or {}
    local scheme = GetScheme()

    -- Work-order ticket accent: 3px expansion-colored stripe on the left edge
    -- (vertex-colored per repaint in SetData; ExpansionData.GetRGB already
    -- supplies a gray fallback for untagged/legacy rows)
    local accentStripe = row:CreateTexture(nil, "ARTWORK", nil, 1)
    accentStripe:SetWidth(3)
    accentStripe:SetPoint("TOPLEFT", 0, 0)
    accentStripe:SetPoint("BOTTOMLEFT", 0, 0)
    accentStripe:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.accentStripe = accentStripe

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 4, 0)
    row.icon = icon

    -- Ready dot: badge on the icon's corner when this recipe can be crafted
    -- right now (net of queue commitments)
    local readyDot = row:CreateTexture(nil, "OVERLAY")
    readyDot:SetSize(7, 7)
    readyDot:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    readyDot:SetTexture("Interface\\Buttons\\WHITE8x8")
    readyDot:Hide()
    row.readyDot = readyDot

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", -72, 0)
    text:SetJustifyH("LEFT")
    row.text = text

    -- Remove button
    local removeBtn = CreateFrame("Button", nil, row)
    removeBtn:SetSize(16, 16)
    removeBtn:SetPoint("RIGHT", -3, 0)
    removeBtn:RegisterForClicks("AnyUp")
    local xText = removeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xText:SetAllPoints()
    xText:SetText("x")
    xText:SetTextColor(scheme.error.r, scheme.error.g, scheme.error.b)
    removeBtn:SetScript("OnClick", function()
        if options.onRemove then options.onRemove(row._item) end
    end)
    row.removeBtn = removeBtn

    -- Quantity steppers: -/+ adjust the planned amount in place. Minus at
    -- qty 1 removes the entry, same as the reducer's qty<=0 contract.
    local function MakeStepper(label, xOff, delta)
        local btn = CreateFrame("Button", nil, row)
        btn:SetSize(14, 16)
        btn:SetPoint("RIGHT", xOff, 0)
        btn:RegisterForClicks("AnyUp")
        local t = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetAllPoints()
        t:SetText(label)
        t:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b)
        btn:SetScript("OnClick", function()
            if options.onQtyDelta then
                options.onQtyDelta(row._item, IsShiftKeyDown() and delta * 5 or delta)
            end
        end)
        return btn
    end
    row.plusBtn = MakeStepper("+", -39, 1)
    row.minusBtn = MakeStepper("-", -55, -1)

    -- Craft hammer (shown per-row via SetData gating; validated at click)
    local craftBtn = CreateFrame("Button", nil, row)
    craftBtn:SetSize(16, 16)
    craftBtn:SetPoint("RIGHT", -21, 0)
    craftBtn:RegisterForClicks("AnyUp")
    local craftIcon = craftBtn:CreateTexture(nil, "ARTWORK")
    craftIcon:SetAllPoints()
    craftIcon:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
    craftIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    craftBtn:SetScript("OnClick", function()
        if options.onCraft then options.onCraft(row._item) end
    end)
    craftBtn:SetScript("OnEnter", function(self)
        local tip = VWB.UI.Tooltip
        tip:Begin(self)
        tip:AddTitle("Craft")
        tip:AddLine(options.craftTooltipLine or "Opens your profession window at this recipe if needed")
        tip:Show()
    end)
    craftBtn:SetScript("OnLeave", function(self) VWB.UI.Tooltip:Hide(self) end)
    row.craftBtn = craftBtn

    -- Data is applied via SetData so pooled rows repaint without recreation
    function row:SetData(item)
        self._item = item
        self.data = item -- VirtualizedList idiom alias: handlers read row.data
        local itemIcon = item.itemID and C_Item.GetItemIconByID(item.itemID)
        self.icon:SetTexture(itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local label = item.name or "Unknown"
        if item.qty and item.qty > 1 then label = label .. " x" .. item.qty end
        self.text:SetText(label)
        -- Craft affordance only where it can act: this character's row (or an
        -- untagged legacy row) AND a recipe this character actually knows.
        local me = VWB.CharacterData:GetCharacterKey()
        self.craftBtn:SetShown(options.onCraft ~= nil and item.recipeID ~= nil
            and (item.charKey == nil or item.charKey == me)
            and VWB.KnownRecipes:IsKnownBy(item.recipeID, me))
        if item.expansion then
            VWB.Data.ExpansionData.SetTextColor(self.text, item.expansion)
        else
            local c = GetScheme()
            self.text:SetTextColor(c.text.r, c.text.g, c.text.b)
        end

        local er, eg, eb = VWB.Data.ExpansionData.GetRGB(item.expansion)
        self.accentStripe:SetVertexColor(er, eg, eb, 1)

        if item.recipeID and VWB.RecipeQuery:CanCraft(item.recipeID) then
            local rc = GetScheme()
            self.readyDot:SetVertexColor(rc.success.r, rc.success.g, rc.success.b, 1)
            self.readyDot:Show()
        else
            self.readyDot:Hide()
        end
    end

    return row
end

-- Queue-row hover body for any VirtualizedList onRowEnter that hosts queue rows.
function VWB.UI:QueueRowTooltip(item, anchor)
    if not (item and item.itemID) then return end -- exception(nullable): enchant/writ rows carry no output item
    local tip = VWB.UI.Tooltip
    tip:Begin(anchor)
    tip:SetItemHeader(item.itemID, item.name)
    if item.qty and item.qty > 1 then
        tip:AddLine(VWB.UI:ColorCode("base01") .. "Queued: x" .. item.qty .. "|r")
    end
    tip:Show()
    VWB.GuildCrafters:AppendCraftersToTooltip(tip, item.recipeID)
end


-- ============================================================================
-- DROPDOWN (Modern: MenuUtil.CreateContextMenu)
-- ============================================================================

function VWB.UI:CreateDropdown(parent, options)
    options = options or {}
    local width = options.width or 150
    local height = options.height or 22
    local scheme = GetScheme()

    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(width, height)
    container:SetBackdrop(BACKDROP_FLAT)
    container:SetBackdropColor(scheme.panel.r, scheme.panel.g, scheme.panel.b, scheme.panel.a)
    container:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    -- Display text
    local text = container:CreateFontString(nil, "OVERLAY")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    text:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    VWB.Theme.ApplyFont(text, scheme)
    container.text = text

    -- Arrow
    local arrow = container:CreateFontString(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -6, 0)
    VWB.Theme.ApplyFont(arrow, scheme, "small")
    arrow:SetText("v")
    arrow:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    container.arrow = arrow

    container.selectedKey = nil
    container.onSelect = options.onSelect
    container.items = options.items or {}

    function container:SetSelected(key, label)
        self.selectedKey = key
        if type(label) == "table" then label = label.label or label.text or key end
        self.text:SetText(label or key or "")
    end

    function container:GetSelected()
        return self.selectedKey
    end

    function container:SetItems(items)
        self.items = items or {}
    end

    -- Click opens MenuUtil context menu
    container:EnableMouse(true)
    container:SetScript("OnMouseDown", function(self)
        MenuUtil.CreateContextMenu(self, function(owner, rootDescription)
            for _, item in ipairs(self.items) do
                local label = item.label or item.key
                rootDescription:CreateButton(label, function()
                    self:SetSelected(item.key, label)
                    if self.onSelect then self.onSelect(item.key, item) end
                end)
            end
        end)
    end)

    -- Hover
    container:SetScript("OnEnter", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a * 0.5)
    end)
    container:SetScript("OnLeave", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, c.panel.a)
    end)

    RegisterWidget(container, "Panel")
    return container
end

-- ============================================================================
-- MULTI-SELECT FILTER DROPDOWN (Blizzard WowStyle1FilterDropdown + "All" toggle)
-- ============================================================================
-- Real Blizzard filter-dropdown chrome (same widget HDG uses), not a hand-rolled
-- backdrop. The menu is a live multi-select checklist: an "All" master row
-- (checked when nothing is picked) + one colored checkbox per item. SetupMenu's
-- generator re-runs each open and polls isSelected live, so the menu stays open on
-- toggle. Driven entirely by caller callbacks -> binds to a Reactor signal with no
-- Store coupling. Caller stamps the closed-trigger label via :SetTriggerText.
--   options = { width, height, allLabel, items = { {key,label,color={r,g,b}} },
--               isAll()->bool, isSelected(key)->bool, onAll(), onToggle(key) }
function VWB.UI:CreateMultiSelectDropdown(parent, options)
    local width  = options.width or 160
    local height = options.height or 22

    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1FilterDropdownTemplate")
    dd:SetText(options.allLabel or "All")
    dd:SetHeight(height)
    -- The filter template resize-to-texts itself down to the label; clamp min=max
    -- to the layout slot so it fills the assigned width instead (HDG's pattern).
    dd.resizeToTextMinWidth = width
    dd.resizeToTextMaxWidth = width
    dd:SetWidth(width)

    function dd:SetTriggerText(str) self:SetText(str or "") end

    dd:SetupMenu(function(_, root)
        root:CreateCheckbox(options.allLabel or "All", options.isAll, options.onAll)
        root:CreateDivider()
        for _, item in ipairs(options.items) do
            local label = item.label
            if item.color then
                label = string.format("|cff%02x%02x%02x%s|r",
                    math.floor(item.color.r * 255 + 0.5), math.floor(item.color.g * 255 + 0.5),
                    math.floor(item.color.b * 255 + 0.5), item.label)
            end
            local key = item.key
            root:CreateCheckbox(label, function() return options.isSelected(key) end,
                function() options.onToggle(key) end)
        end
    end)

    return dd
end

-- ============================================================================
-- SEARCH BOX (Debounced text input with placeholder)
-- ============================================================================

function VWB.UI:CreateSearchBox(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(options.width or 200, options.height or 22)
    box:SetAutoFocus(false)
    box:SetBackdrop(BACKDROP_FLAT)
    box:SetBackdropColor(scheme.panel.r, scheme.panel.g, scheme.panel.b, scheme.panel.a)
    box:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b)
    VWB.Theme.ApplyFont(box, scheme)

    -- Placeholder
    local placeholder = box:CreateFontString(nil, "ARTWORK")
    placeholder:SetPoint("LEFT", 8, 0)
    placeholder:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    VWB.Theme.ApplyFont(placeholder, scheme)
    placeholder:SetText(options.placeholder or "Search...")
    box.placeholder = placeholder

    -- D1: 150ms trailing debounce on onChange. Each keystroke cancels the
    -- pending timer and arms a new one; the signal write fires in the callback.
    -- Placeholder visibility updates immediately (no debounce needed there).
    -- ReactorWoW.after is the addon-wide timer primitive (no C_Timer).
    -- text is re-read from the box inside the callback so it reflects the
    -- actual final content, not the character at schedule time.
    local _searchDebounce = nil
    box:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local text2 = self:GetText()
        placeholder:SetShown(text2 == "")
        if options.onChange then
            if _searchDebounce then _searchDebounce:Cancel() end
            _searchDebounce = VWB.ReactorWoW.after(0.15, function()
                _searchDebounce = nil
                options.onChange(box:GetText())
            end)
        end
    end)

    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    box:SetScript("OnEditFocusGained", function(self)
        placeholder:Hide()
    end)

    box:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then placeholder:Show() end
    end)

    function box:Clear()
        self:SetText("")
        placeholder:Show()
        if options.onChange then options.onChange("") end
    end

    RegisterWidget(box, "SearchBox")
    return box
end


-- ============================================================================
-- SEGMENTED TOGGLE (Direct/Raw mode switch)
-- ============================================================================

function VWB.UI:CreateSegmentedToggle(parent, options)
    -- Tertiary chrome per segment (unification 2026-07-11): a segmented
    -- toggle is a row of CreateButton-style buttons where exactly one is
    -- active (HDG's Grid|List pair). The old flat-backdrop container box and
    -- the pill-atlas variant (whose unselected state read as DISABLED --
    -- "Decor greyed out") are both gone.
    options = options or {}

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(options.width or 160, options.height or 24)

    local btns = {}
    local selected = options.default or options.segments[1].key

    local n = #options.segments
    local gap = 2
    local segWidth = ((options.width or 160) - gap * (n - 1)) / n
    for i, seg in ipairs(options.segments) do
        local btn = CreateFrame("Button", nil, container)
        btn:SetSize(segWidth, options.height or 24)
        btn:SetPoint("LEFT", (i - 1) * (segWidth + gap), 0)
        btn.key = seg.key
        ApplyTertiaryChrome(btn)
        btn:SetText(seg.label or seg.key)

        btn:SetScript("OnClick", function()
            selected = seg.key
            container:UpdateAppearance()
            if options.onSelect then options.onSelect(seg.key) end
        end)

        table.insert(btns, btn)
    end

    container.buttons = btns

    function container:UpdateAppearance()
        local c = GetScheme()
        for _, btn in ipairs(btns) do
            btn._active = btn.key == selected
            VWB.UI:PaintTertiaryButton(btn, c)
        end
    end

    function container:GetSelected() return selected end
    function container:SetSelected(key)
        selected = key
        self:UpdateAppearance()
    end

    container:UpdateAppearance()
    RegisterWidget(container, "SegmentedToggle")
    return container
end

-- ============================================================================
-- CHECKBOX
-- ============================================================================

function VWB.UI:CreateCheckbox(parent, label, onClick)
    local scheme = GetScheme()

    -- Container bounds include the label -- anchoring against the returned
    -- frame must never let the text spill over neighboring widgets
    local container = CreateFrame("Frame", nil, parent)

    local cb = CreateFrame("CheckButton", nil, container, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", 0, 0)
    container.button = cb

    local lbl = cb:CreateFontString(nil, "OVERLAY")
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    VWB.Theme.ApplyFont(lbl, scheme)
    lbl:SetText(label or "")
    container.label = lbl

    local labelWidth = math.ceil(lbl:GetUnboundedStringWidth())
    container:SetSize(28 + labelWidth, 24)
    cb:SetHitRectInsets(0, -(labelWidth + 4), 0, 0) -- clicking the label toggles too

    function container:SetChecked(checked) cb:SetChecked(checked) end
    function container:GetChecked() return cb:GetChecked() end

    if onClick then
        cb:SetScript("OnClick", function(self)
            onClick(self:GetChecked())
        end)
    end

    RegisterWidget(container, "Checkbox")
    return container
end

-- ============================================================================
-- FILTER PILL (atlas-styled on/off toggle -- drop-in for the filter checkboxes)
-- Same contract as CreateCheckbox for the filter row: onClick(checked),
-- :SetChecked(v) / :GetChecked(). Sizes to its label like the profession tabs.
-- ============================================================================

local FILTER_PILL_HEIGHT = 20
local FILTER_PILL_HPAD = 11
local FILTER_PILL_MIN_WIDTH = 34

function VWB.UI:CreateFilterPill(parent, label, onClick)
    -- Tertiary chrome (unification 2026-07-11): same button family as
    -- CreateButton -- checked = the depressed/accent active state. The old
    -- auctionhouse-nav-button pill atlas is gone (its unselected state read
    -- as a DISABLED button).
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(FILTER_PILL_HEIGHT)
    btn:RegisterForClicks("AnyUp")
    local text = ApplyTertiaryChrome(btn)
    btn:SetText(label)
    btn:SetWidth(math.max(math.ceil(text:GetUnboundedStringWidth()) + FILTER_PILL_HPAD * 2, FILTER_PILL_MIN_WIDTH))

    btn.checked = false
    local function Repaint()
        btn._active = btn.checked
        VWB.UI:PaintTertiaryButton(btn, GetScheme())
    end
    Repaint()

    btn:SetScript("OnClick", function(self)
        self.checked = not self.checked
        Repaint()
        if onClick then onClick(self.checked) end
    end)

    function btn:SetChecked(v) self.checked = v and true or false; Repaint() end
    function btn:GetChecked() return self.checked end

    -- No "FilterPill" skinner in the Theme registry, so repaint on theme switch
    -- ourselves (same self-contained pattern as CreateScrollBox).
    if VWB.EventBus then VWB.EventBus:Register("VWB_THEME_UPDATE", Repaint) end

    RegisterWidget(btn, "FilterPill")
    return btn
end

-- ============================================================================
-- SLIDER
-- ============================================================================

function VWB.UI:CreateSlider(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(options.width or 200, 40)

    -- Label
    local label = container:CreateFontString(nil, "OVERLAY")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    VWB.Theme.ApplyFont(label, scheme)
    label:SetText(options.label or "")
    container.label = label

    -- Value display
    local valueText = container:CreateFontString(nil, "OVERLAY")
    valueText:SetPoint("TOPRIGHT", 0, 0)
    valueText:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    VWB.Theme.ApplyFont(valueText, scheme, "small")
    container.valueText = valueText

    -- Slider
    local slider = CreateFrame("Slider", nil, container, "MinimalSliderTemplate")
    slider:SetPoint("TOPLEFT", 0, -16)
    slider:SetPoint("TOPRIGHT", 0, -16)
    slider:SetHeight(16)
    slider:SetMinMaxValues(options.min or 0, options.max or 100)
    slider:SetValueStep(options.step or 1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(options.default or options.min or 0)

    local function FormatValue(val)
        if options.format then return options.format(val) end
        return tostring(val)
    end
    valueText:SetText(FormatValue(slider:GetValue()))

    slider:SetScript("OnValueChanged", function(self, value)
        valueText:SetText(FormatValue(value))
        if options.onChange then options.onChange(value) end
    end)

    container.slider = slider
    function container:GetValue() return slider:GetValue() end
    function container:SetValue(val) slider:SetValue(val); valueText:SetText(FormatValue(val)) end

    RegisterWidget(container, "Slider")
    return container
end


-- ============================================================================
-- DIVIDER
-- ============================================================================

function VWB.UI:CreateDivider(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(options.height or 1)
    divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    divider:SetVertexColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    RegisterWidget(divider, "Divider")
    return divider
end

-- ============================================================================
-- SECTION HEADER (Label + divider line)
-- ============================================================================

function VWB.UI:CreateSectionHeader(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(options.height or 20)

    local text = container:CreateFontString(nil, "OVERLAY")
    text:SetPoint("LEFT", 4, 0)
    text:SetTextColor(scheme.accent.r, scheme.accent.g, scheme.accent.b, scheme.accent.a)
    VWB.Theme.ApplyFont(text, scheme, "header")
    text:SetText(options.text or "")
    container.text = text

    local divider = container:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("LEFT", text, "RIGHT", 6, 0)
    divider:SetPoint("RIGHT", -4, 0)
    divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    divider:SetVertexColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    container.divider = divider

    RegisterWidget(container, "SectionHeader")
    return container
end

-- ============================================================================
-- PROGRESS BAR
-- ============================================================================

function VWB.UI:CreateProgressBar(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(options.width or 200, options.height or 16)

    -- Background track
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(scheme.panel.r, scheme.panel.g, scheme.panel.b, scheme.panel.a)
    bar.bg = bg

    -- Fill
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT")
    fill:SetPoint("BOTTOMLEFT")
    fill:SetWidth(1)
    fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetVertexColor(scheme.accent.r, scheme.accent.g, scheme.accent.b, scheme.accent.a)
    bar.fill = fill

    -- Label
    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetPoint("CENTER")
    text:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    VWB.Theme.ApplyFont(text, scheme, "small")
    bar.text = text

    function bar:SetProgress(current, total)
        if not total or total == 0 then
            fill:SetWidth(1)
            text:SetText("0%")
            return
        end
        local pct = math.min(current / total, 1.0)
        local width = math.max(self:GetWidth() * pct, 1)
        fill:SetWidth(width)
        text:SetText(math.floor(pct * 100) .. "%")
    end

    -- Subtle alpha pulse while a build is actively running (looped; caller
    -- toggles via SetPulsing). Looped, so OnFinished only fires when Stop()
    -- is called explicitly -- OnStop covers it too, belt-and-braces
    -- (donor: VamoosesEndeavors/UI/Framework.lua:678).
    local pulse = bar:CreateAnimationGroup()
    pulse:SetLooping("REPEAT")
    local fadeOut = pulse:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1.0)
    fadeOut:SetToAlpha(0.55)
    fadeOut:SetDuration(0.6)
    fadeOut:SetOrder(1)
    fadeOut:SetSmoothing("IN_OUT")
    local fadeIn = pulse:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.55)
    fadeIn:SetToAlpha(1.0)
    fadeIn:SetDuration(0.6)
    fadeIn:SetOrder(2)
    fadeIn:SetSmoothing("IN_OUT")
    pulse:SetScript("OnFinished", function() bar:SetAlpha(1.0) end)
    pulse:SetScript("OnStop", function() bar:SetAlpha(1.0) end)
    bar.pulse = pulse

    function bar:SetPulsing(active)
        if active then
            if not pulse:IsPlaying() then pulse:Play() end
        else
            pulse:Stop()
        end
    end

    RegisterWidget(bar, "ProgressBar")
    return bar
end


-- ============================================================================
-- EXPORT DIALOG (Copy-paste text window)
-- ============================================================================

local exportDialog = nil

function VWB.UI:CreateExportDialog()
    if exportDialog then return exportDialog end

    local dialog = CreateFrame("Frame", "VWBExportDialog", UIParent, "BackdropTemplate")
    dialog:SetSize(500, 350)
    dialog:SetPoint("CENTER")
    dialog:SetFrameStrata("DIALOG")
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)

    local scheme = GetScheme()
    dialog:SetBackdrop(BACKDROP_FLAT)
    dialog:SetBackdropColor(scheme.bg.r, scheme.bg.g, scheme.bg.b, scheme.bg.a)
    dialog:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -8)
    title:SetText("Export")
    title:SetTextColor(scheme.text_header.r, scheme.text_header.g, scheme.text_header.b)
    dialog.title = title

    -- Close button
    local closeBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetBackdrop(BACKDROP_FLAT)
    closeBtn:SetBackdropColor(scheme.button_normal.r, scheme.button_normal.g, scheme.button_normal.b, scheme.button_normal.a)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    closeTxt:SetPoint("CENTER")
    closeTxt:SetText("X")
    closeTxt:SetTextColor(scheme.error.r, scheme.error.g, scheme.error.b)
    closeBtn:SetScript("OnClick", function() dialog:Hide() end)

    -- ScrollFrame + EditBox
    local sf = CreateFrame("ScrollFrame", "VWBExportScrollFrame", dialog, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -30)
    sf:SetPoint("BOTTOMRIGHT", -30, 10)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetWidth(sf:GetWidth() or 440)
    eb:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b)
    sf:SetScrollChild(eb)

    sf:SetScript("OnSizeChanged", function(self, w)
        eb:SetWidth(w - 10)
    end)

    dialog.editBox = eb
    dialog:Hide()

    function dialog:ShowText(text, titleStr)
        self.title:SetText(titleStr or "Export")
        self.editBox:SetText(text or "")
        self.editBox:HighlightText()
        self:Show()
        self.editBox:SetFocus()
    end

    exportDialog = dialog
    tinsert(UISpecialFrames, "VWBExportDialog")
    return dialog
end

-- ============================================================================
-- CHARACTER STAT CARD (ported from VTC; Roster strip -- one card per alt)
-- ============================================================================

local CHAR_CARD_W, CHAR_CARD_H = 220, 58

-- Faction accent colors for the card's left-edge strip.
-- exception(nullable): SavedVariables record predates the faction field
local FACTION_ACCENT_COLORS = {
    Alliance = { r = 0.25, g = 0.45, b = 0.85 },
    Horde    = { r = 0.80, g = 0.15, b = 0.15 },
}

-- Buckets a lastSeen epoch against `now` into a short "scanned X ago" string.
-- exception(nullable): SavedVariables record predates the lastSeen field
local function FormatScannedAgo(lastSeen, now)
    if not lastSeen then return "not scanned yet" end
    local d = math.max(0, now - lastSeen)
    if d < 60 then
        return "scanned " .. math.floor(d) .. "s ago"
    elseif d < 3600 then
        return "scanned " .. math.floor(d / 60) .. "m ago"
    elseif d < 86400 then
        return "scanned " .. math.floor(d / 3600) .. "h ago"
    else
        return "scanned " .. math.floor(d / 86400) .. "d ago"
    end
end

-- Public wrapper: Alts.lua's per-character "Character Details" header reuses
-- the same bucketing as the Roster strip card below instead of duplicating it.
function VWB.UI:FormatScannedAgo(lastSeen, now)
    return FormatScannedAgo(lastSeen, now)
end

-- Alphabetical profession-name summary line. professions is always a table
-- (SAVE_CHARACTER_PROFESSIONS defaults it to {}) -- strict read.
-- Icon row (2026-07-11): profession NAMES truncated on the narrow rail card
-- ("Archaeology / Cooking / Ench..."); inline |T|t icons fit every profession
-- on one line. The hover tooltip still carries names + per-expansion detail.
local function FormatProfessionSummary(professions)
    local names = {}
    for profName in pairs(professions) do
        table.insert(names, profName)
    end
    if #names == 0 then return "No professions scanned" end
    table.sort(names)
    local out = {}
    for i, profName in ipairs(names) do
        local icon = VWB.Constants.ProfessionIcons[profName]
        out[i] = icon and ("|T" .. icon .. ":12:12|t") or profName -- exception(nullable): unmapped profession falls back to its name
    end
    return table.concat(out, " ")
end

-- Compact per-alt tile for the Roster (Alts tab) character strip. Pooled via
-- VWB.UI:AcquireRow like every other row in this addon -- card:SetData()
-- repaints an existing card, it never recreates one. No progress bar: VWB
-- has no honest per-character completion denominator yet, so don't fabricate
-- one. card._charKey + the onClick option are plumbed for the future
-- alt-aware crafting-queue selection -- unused today, wired in one line later.
function VWB.UI:CreateCharStatCard(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
    card:SetSize(CHAR_CARD_W, CHAR_CARD_H)
    card:SetBackdrop(BACKDROP_FLAT)
    card:SetBackdropColor(scheme.panel.r, scheme.panel.g, scheme.panel.b, 0.4)
    card:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)
    card:RegisterForClicks("AnyUp")

    -- Faction accent: thin strip on the left edge, shown only when known.
    local accent = card:CreateTexture(nil, "ARTWORK")
    accent:SetWidth(3)
    accent:SetPoint("TOPLEFT", 0, 0)
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:Hide()
    card.accent = accent

    -- Class icon
    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("LEFT", card, "LEFT", 8, 2)
    card.icon = icon

    -- Text column right of the icon, stacked top-down so the three lines
    -- never collide: name / professions / scanned-ago.
    local name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("TOPLEFT", card, "TOPLEFT", 44, -7)
    name:SetPoint("RIGHT", card, "RIGHT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    card.name = name

    local sub = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -1)
    sub:SetPoint("TOPRIGHT", name, "BOTTOMRIGHT", 0, -1)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)
    card.sub = sub

    local scanned = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scanned:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -1)
    scanned:SetPoint("TOPRIGHT", sub, "BOTTOMRIGHT", 0, -1)
    scanned:SetJustifyH("LEFT")
    card.scanned = scanned

    -- Selection wiring: no behavior yet (alt-aware queue selection lands
    -- later), but the hook is live -- wiring it up is a one-line options.onClick.
    card.onClick = options.onClick
    card:SetScript("OnClick", function(self)
        if self.onClick then self.onClick(self._charKey, self._entry) end
    end)

    function card:SetActive(active)
        local c = GetScheme()
        if active then
            self:SetBackdropColor(c.accent.r, c.accent.g, c.accent.b, 0.22)
        else
            self:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, 0.4)
        end
        self:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
    end

    function card:SetData(charKey, entry, isActive, now)
        self._charKey = charKey
        self._entry = entry
        self:SetActive(isActive)

        local c = GetScheme()

        -- Class icon atlas format: "classicon-mage" etc. (lowercased).
        -- exception(nullable): SavedVariables record predates the class field
        local classLower = entry.class and entry.class:lower()
        if classLower then
            self.icon:SetAtlas("classicon-" .. classLower, false)
            self.icon:Show()
        else
            self.icon:Hide()
        end

        self.name:SetText(entry.name)
        local classColor = RAID_CLASS_COLORS and entry.class and RAID_CLASS_COLORS[entry.class]
        if classColor then
            self.name:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            self.name:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
        end

        self.sub:SetText(FormatProfessionSummary(entry.professions))
        self.sub:SetTextColor(c.text.r, c.text.g, c.text.b)

        self.scanned:SetText(FormatScannedAgo(entry.lastSeen, now))
        self.scanned:SetTextColor(c.text.r, c.text.g, c.text.b)

        -- exception(nullable): SavedVariables record predates the faction field
        local factionColor = entry.faction and FACTION_ACCENT_COLORS[entry.faction]
        if factionColor then
            self.accent:SetColorTexture(factionColor.r, factionColor.g, factionColor.b)
            self.accent:Show()
        else
            self.accent:Hide()
        end
    end

    RegisterWidget(card, "Button")
    return card
end

-- ============================================================================
-- MODEL CONTROLS (ported from VTC)
-- Wire drag-rotate / wheel-zoom / right-click-reset onto a DressUpModel.
-- Blizzard ModelFrame pattern: per-frame cursor delta x rotation constant;
-- drag right turns the model's face left, like spinning a turntable you're
-- touching the front of. Zoom is camera portrait zoom (0..1), NOT model
-- scale. Right-click resets pose and zoom.
-- ============================================================================
local DRAG_ROTATION_CONSTANT = 0.020 -- 2x Blizzard's default (0.010)

local function ModelRotateOnUpdate(model)
    local x = GetCursorPosition()
    model:SetFacing((model:GetFacing() or 0) + (x - (model._lastCursorX or x)) * DRAG_ROTATION_CONSTANT)
    model._lastCursorX = x
end

function VWB.UI:WireModelControls(model)
    model:EnableMouse(true)
    model:EnableMouseWheel(true)

    model:SetScript("OnMouseDown", function(m, button)
        if button == "LeftButton" then
            m._lastCursorX = GetCursorPosition()
            m:SetScript("OnUpdate", ModelRotateOnUpdate) -- attached only while dragging
        elseif button == "RightButton" then
            m:SetFacing(0)
            m:SetPosition(0, 0, 0)
            m:SetPortraitZoom(0)
            m._zoom = 0
        end
    end)
    model:SetScript("OnMouseUp", function(m, button)
        if button == "LeftButton" then
            m:SetScript("OnUpdate", nil)
        end
    end)
    model:SetScript("OnMouseWheel", function(m, delta)
        local z = math.max(0, math.min(1, (m._zoom or 0) + delta * 0.05))
        m._zoom = z
        m:SetPortraitZoom(z)
    end)
end

-- ============================================================================
-- PROFESSION TAB BAR (DBM-style folder tabs with icon + label)
-- items = array of { key, label, icon, abbrev }
-- onSelect(key) called on click
-- Returns bar frame with :Select(key), :GetSelected(), buttons table
-- ============================================================================

local TAB_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 0 },
}

function VWB.UI:CreateProfessionTabBar(parent, items, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetAllPoints()

    local buttons = {}
    local buttonOrder = {}  -- preserve insertion order
    bar.buttons = buttons
    bar.selected = nil

    local TAB_HEIGHT = 26
    local ICON_SIZE = 18
    local TAB_PAD = 8  -- horizontal padding inside tab

    for i, item in ipairs(items) do
        local btn = CreateFrame("Button", nil, bar, "BackdropTemplate")
        btn:SetHeight(TAB_HEIGHT)
        btn:SetBackdrop(TAB_BACKDROP)
        btn.itemKey = item.key

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPoint("LEFT", TAB_PAD, 0)
        icon:SetTexture(item.icon)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- shave the baked-in icon border
        btn.icon = icon

        -- Short label next to icon
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        local displayText = item.abbrev or item.label or item.key
        label:SetText(displayText)
        btn.label = label

        -- Size tab to fit contents
        local textWidth = label:GetStringWidth() or 40
        btn:SetWidth(ICON_SIZE + textWidth + TAB_PAD * 2 + 4)

        -- Position tabs sequentially
        if i == 1 then
            btn:SetPoint("BOTTOMLEFT", 4, -1)  -- overlap panel top by 1px
        else
            btn:SetPoint("BOTTOMLEFT", buttonOrder[i - 1], "BOTTOMRIGHT", 2, 0)
        end

        -- Selection accent line (shown when active); theme-derived gold --
        -- the raw literal looked broken on light themes (unification #4)
        local selBar = VWB.Constants:GetDerivedColors(GetScheme()).selected_bar
        local topAccent = btn:CreateTexture(nil, "OVERLAY")
        topAccent:SetPoint("TOPLEFT", 1, 0)
        topAccent:SetPoint("TOPRIGHT", -1, 0)
        topAccent:SetHeight(2)
        topAccent:SetColorTexture(selBar.r, selBar.g, selBar.b, 1)
        topAccent:Hide()
        btn.topAccent = topAccent

        btn:SetScript("OnEnter", function(self)
            if bar.selected ~= self.itemKey then
                local c = GetScheme()
                self:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, 0.8)
                self.icon:SetDesaturated(false)
                self.icon:SetAlpha(0.9)
                self.label:SetTextColor(c.text.r, c.text.g, c.text.b)
            end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(item.label, 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            if bar.selected ~= self.itemKey then
                self:SetBackdropColor(0.05, 0.05, 0.05, 0.6)
                self.icon:SetDesaturated(true)
                self.icon:SetAlpha(0.5)
                local c = GetScheme()
                self.label:SetTextColor(c.text.r, c.text.g, c.text.b)
            end
            GameTooltip:Hide()
        end)
        btn:SetScript("OnClick", function(self)
            bar:Select(self.itemKey)
            if onSelect then onSelect(self.itemKey) end
        end)

        buttons[item.key] = btn
        buttonOrder[i] = btn
    end

    function bar:Select(key)
        self.selected = key
        local c = GetScheme()
        for btnKey, btn in pairs(self.buttons) do
            if btnKey == key then
                -- Active: raised tab, panel bg, gold top accent, no bottom border
                btn:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, 1)
                btn:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, 0.8)
                btn.topAccent:Show()
                btn.topAccent:SetColorTexture(c.accent.r, c.accent.g, c.accent.b, 1)
                btn.icon:SetDesaturated(false)
                btn.icon:SetAlpha(1)
                btn.label:SetTextColor(c.text.r, c.text.g, c.text.b)
                btn:SetFrameLevel(bar:GetFrameLevel() + 2)
            else
                -- Inactive: recessed, darker
                btn:SetBackdropColor(0.05, 0.05, 0.05, 0.6)
                btn:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, 0.4)
                btn.topAccent:Hide()
                btn.icon:SetDesaturated(true)
                btn.icon:SetAlpha(0.5)
                btn.label:SetTextColor(c.text.r, c.text.g, c.text.b)
                btn:SetFrameLevel(bar:GetFrameLevel() + 1)
            end
        end
    end

    function bar:GetSelected()
        return self.selected
    end

    return bar
end


-- ============================================================================
-- EMPTY-STATE CARD (icon + title + body + optional CTA button)
-- One visual language for "nothing here yet, and here's what to do about it"
-- ============================================================================
function VWB.UI:CreateEmptyStateCard(parent, opts)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetBackdrop(VWB.UI.BACKDROP_CARD)
    card:SetSize(opts.width or 360, opts.height or 160)
    RegisterWidget(card, "Panel")

    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOP", 0, -16)
    icon:SetTexture(opts.icon or "Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    card.icon = icon

    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", icon, "BOTTOM", 0, -8)
    title:SetText(opts.title or "")
    card.title = title

    local body = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    body:SetPoint("TOP", title, "BOTTOM", 0, -6)
    body:SetPoint("LEFT", card, "LEFT", 16, 0)
    body:SetPoint("RIGHT", card, "RIGHT", -16, 0)
    body:SetJustifyH("CENTER")
    body:SetWordWrap(true)
    body:SetText(opts.body or "")
    card.body = body

    if opts.buttonText then
        local btn = VWB.UI:CreateButton(card, opts.buttonText, 180, 24)
        btn:SetPoint("BOTTOM", 0, 14)
        btn:SetScript("OnClick", opts.onClick)
        card.button = btn
    end

    local c = GetScheme()
    card:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, 0.6)
    card:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
    title:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
    body:SetTextColor(c.text.r, c.text.g, c.text.b)
    card:Hide()
    return card
end


-- ============================================================================
-- NAV TREE (scrollable left panel with collapsible expansion headers)
-- ============================================================================

-- options = { onHeaderClick(key), onItemClick(key, itemData) }
-- Returns nav frame with :SetData(sections), :Select(key)
function VWB.UI:CreateNavTree(parent, options)
    options = options or {}

    local nav = CreateFrame("Frame", nil, parent)
    nav:SetAllPoints()
    nav.sections = {}
    nav.selected = nil

    -- Modern scrollbox with a single scrollable content child
    local scrollBox = CreateFrame("Frame", nil, nav, "WowScrollBox")
    scrollBox:SetPoint("TOPLEFT", 0, 0)
    scrollBox:SetPoint("BOTTOMRIGHT", -14, 0)

    local scrollBar = CreateFrame("EventFrame", nil, nav, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 2, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 2, 0)

    local content = CreateFrame("Frame", nil, scrollBox)
    content:SetWidth(nav:GetWidth() or 220)
    content:SetHeight(1)
    content.scrollable = true -- WowScrollBox contract: exactly one scrollable child

    local view = CreateScrollBoxLinearView()
    view:SetPanExtent(30)
    ScrollUtil.InitScrollBoxWithScrollBar(scrollBox, scrollBar, view)

    nav.content = content
    nav.scrollBox = scrollBox

    scrollBox:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
    end)

    -- sections = array of { key, label, color, collapsed, items = { { key, label, count } } }
    function nav:SetData(sections)
        self.sections = sections
        self:Refresh()
    end

    function nav:Select(key)
        self.selected = key
        self:Refresh()
    end

    -- Pooled factories: frames are created once and repainted on every refresh
    local function CreateNavHeader(parentFrame)
        local header = CreateFrame("Button", nil, parentFrame, "BackdropTemplate")
        header:SetHeight(22)
        header:SetBackdrop(VWB.Theme.BACKDROP_PANEL)

        local arrow = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        arrow:SetPoint("LEFT", 4, 0)
        header.arrow = arrow

        -- The arrow gets its own hit area: clicking it collapses/expands
        -- WITHOUT changing the expansion selection (the rest of the header
        -- selects). A child Button naturally wins the click over its parent.
        local arrowBtn = CreateFrame("Button", nil, header)
        arrowBtn:SetSize(18, 22)
        arrowBtn:SetPoint("LEFT", 0, 0)
        arrowBtn:SetScript("OnClick", function()
            if options.onArrowClick then options.onArrowClick(header._sectionKey) end
        end)
        header.arrowBtn = arrowBtn

        local accent = header:CreateTexture(nil, "ARTWORK")
        accent:SetSize(3, 16)
        accent:SetPoint("LEFT", 14, 0)
        header.accentBar = accent

        local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        headerText:SetPoint("LEFT", 22, 0)
        headerText:SetPoint("RIGHT", -30, 0)
        headerText:SetJustifyH("LEFT")
        header.text = headerText

        local countText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countText:SetPoint("RIGHT", -4, 0)
        header.countText = countText

        header:SetScript("OnClick", function(self)
            if options.onHeaderClick then options.onHeaderClick(self._sectionKey) end
        end)
        header:SetScript("OnEnter", function(self)
            local c = GetScheme()
            self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, 0.4)
        end)
        header:SetScript("OnLeave", function(self)
            local c = GetScheme()
            self:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, c.panel.a * 0.6)
        end)
        RegisterWidget(header, "NavHeader")
        return header
    end

    local function CreateNavItem(parentFrame)
        local row = CreateFrame("Button", nil, parentFrame, "BackdropTemplate")
        row:SetHeight(18)
        row:SetBackdrop(BACKDROP_BORDERLESS)

        -- 3px left selection bar (golden, vertex-colored by NavItem skinner)
        local selBar = row:CreateTexture(nil, "ARTWORK")
        selBar:SetSize(3, 14)
        selBar:SetPoint("LEFT", 0, 0)
        selBar:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.selBar = selBar

        local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        itemText:SetPoint("LEFT", 8, 0)
        itemText:SetPoint("RIGHT", -30, 0)
        itemText:SetJustifyH("LEFT")
        row.text = itemText

        local cntText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cntText:SetPoint("RIGHT", -4, 0)
        row.countText = cntText

        row:SetScript("OnClick", function(self)
            nav.selected = self._itemKey
            if options.onItemClick then options.onItemClick(self._itemKey, self._item) end
            nav:Refresh()
        end)
        row:SetScript("OnEnter", function(self)
            if not self._isSelected then
                local c = GetScheme()
                self:SetBackdropColor(c.warning.r, c.warning.g, c.warning.b, 0.06)
            end
        end)
        row:SetScript("OnLeave", function(self)
            if not self._isSelected then
                self:SetBackdropColor(0, 0, 0, 0)
            end
        end)
        RegisterWidget(row, "NavItem")
        return row
    end

    -- D7: pre-bake theme hex strings per Refresh. c.text and c.text_header are
    -- stable within a theme lifetime; computing them per-section/per-item pays
    -- repeated string.format costs for no reason. Cache keyed by scheme identity.
    local _navHexScheme = nil
    local _navHexText, _navHexHeader = nil, nil
    -- Section colors are session-stable (expansion colors don't change at
    -- runtime); store the pre-baked hex on the section table itself, keyed by
    -- the color table pointer. Invalidated cheaply when color table identity
    -- changes (only on corpus reload -- effectively never at runtime).
    local function _sectionColorHex(section)
        local col = section.color
        if section._hexColor ~= col then
            section._hexColor = col
            section._hexStr = VWB.UI:ToHex(col)
        end
        return section._hexStr
    end

    function nav:Refresh()
        VWB.UI:ResetRows(content)
        local c = GetScheme()
        local d = VWB.Constants:GetDerivedColors(c)
        -- Rebuild theme hex cache when scheme table identity changes (theme switch).
        if c ~= _navHexScheme then
            _navHexScheme = c
            _navHexText   = VWB.UI:ToHex(c.text)
            _navHexHeader = VWB.UI:ToHex(c.text_header)
        end
        local yOff = 0

        for _, section in ipairs(self.sections or {}) do
            local header = VWB.UI:AcquireRow(content, "header", CreateNavHeader)
            header:SetPoint("TOPLEFT", 0, yOff)
            header:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            header._sectionKey = section.key
            header:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, c.panel.a * 0.6)
            header:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a * 0.8)
            header.arrow:SetText(section.collapsed and "+" or "-")
            header.arrow:SetTextColor(c.text.r, c.text.g, c.text.b)
            if section.color then
                header.accentBar:SetColorTexture(section.color.r, section.color.g, section.color.b, 1)
                header.text:SetText(string.format("|cFF%s%s|r", _sectionColorHex(section), section.label))
            else
                header.accentBar:SetColorTexture(c.accent.r, c.accent.g, c.accent.b, 1)
                header.text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
                header.text:SetText(section.label)
            end
            header.countText:SetText(section.itemCount and ("|cFF" .. _navHexText .. section.itemCount .. "|r") or "")
            yOff = yOff - 23

            if not section.collapsed and section.items then
                for _, item in ipairs(section.items) do
                    local row = VWB.UI:AcquireRow(content, "item", CreateNavItem)
                    row:SetPoint("TOPLEFT", 10, yOff)
                    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                    row._itemKey = item.key
                    row._item = item

                    local isSelected = (self.selected == item.key)
                    row._isSelected = isSelected
                    if isSelected then
                        row:SetBackdropColor(d.selected_fill.r, d.selected_fill.g, d.selected_fill.b, d.selected_fill.a)
                        row.selBar:SetVertexColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 1)
                        row.selBar:Show()
                        row.text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
                    else
                        row:SetBackdropColor(0, 0, 0, 0)
                        row.selBar:Hide()
                        row.text:SetTextColor(c.text.r, c.text.g, c.text.b)
                    end
                    row.text:SetText(item.label)
                    row.countText:SetText(item.count and ("|cFF" .. _navHexText .. item.count .. "|r") or "")
                    yOff = yOff - 19
                end
            end
        end

        VWB.UI:HideUnusedRows(content)
        content:SetHeight(math.abs(yOff) + 10)
        -- WowScrollBox only measures the scrollable child at init; a height
        -- change needs an explicit extent recalc or the scroll range is stale
        scrollBox:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end

    return nav
end

-- ============================================================================
-- ROW ANIMATION HELPERS (factory-time; created ONCE per pooled row)
-- ============================================================================
-- Both helpers follow the rule: AnimationGroups are created at factory time
-- (inside the CreateScrollBox factory/rowTemplate fn), NOT inside paint/update
-- callbacks. The returned handle only exposes Stop/Play calls. Views must call
-- :Flash() only on false->true transitions -- they are responsible for tracking
-- prior state, because these helpers are stateless wrappers.
--
-- Texture sublevel -1 sits BELOW the content (icon, text, etc.) which live at
-- ARTWORK/sublevel 0+. BACKGROUND layer at sublevel -1 is behind all ARTWORK.
-- ============================================================================

-- VWB.UI:AttachShimmer(row)
--   Adds a low-alpha full-row shimmer texture that loops 0.04 <-> 0.08 alpha
--   via an AnimationGroup. Used to signal pending/loading state (PENDING rows).
--   Returns a handle:
--     handle:SetShimmering(bool)  show/pause the animation
function VWB.UI:AttachShimmer(row)
    local tex = row:CreateTexture(nil, "BACKGROUND", nil, -1) -- behind content
    tex:SetAllPoints(row)
    tex:SetColorTexture(1, 1, 1, 0)
    tex:Hide()

    local ag = row:CreateAnimationGroup()
    ag:SetLooping("BOUNCE") -- 0.04->0.08->0.04->... natural shimmer pulse
    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.04); fadeIn:SetToAlpha(0.08)
    fadeIn:SetDuration(0.9); fadeIn:SetOrder(1)

    local handle = {}
    function handle:SetShimmering(active)
        if active then
            tex:Show(); ag:Play()
        else
            ag:Stop(); tex:Hide()
        end
    end
    return handle
end

-- VWB.UI:AttachTransitionWash(row, r, g, b)
--   Adds a one-shot alpha wash (0.12 -> settle 0.08) for state-transition
--   celebration (e.g. craftable flipping true). r/g/b set the wash tint;
--   callers typically pass c.success colors for the craftable signal.
--   Returns a handle:
--     handle:Flash()  trigger the one-shot animation (safe to call repeatedly;
--                     each call restarts the sequence from 0.12)
function VWB.UI:AttachTransitionWash(row, r, g, b)
    local tex = row:CreateTexture(nil, "BACKGROUND", nil, -1) -- behind content
    tex:SetAllPoints(row)
    tex:SetColorTexture(r, g, b, 0)
    tex:Hide()

    local ag = row:CreateAnimationGroup()
    ag:SetScript("OnFinished", function() tex:SetAlpha(0.08) end) -- settle at 0.08

    local burst = ag:CreateAnimation("Alpha")
    burst:SetFromAlpha(0.12); burst:SetToAlpha(0.08)
    burst:SetDuration(0.6); burst:SetOrder(1)

    local handle = {}
    function handle:Flash()
        tex:SetAlpha(0.12); tex:Show()
        ag:Stop(); ag:Play()
    end
    return handle
end

-- ============================================================================
