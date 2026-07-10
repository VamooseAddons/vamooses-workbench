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

-- Async item-name resolution: ItemEventListener + RequestLoad (BOTH calls are
-- required -- AddCallback only subscribes, RequestLoad initiates the stream).
-- Callback receives the loaded name; pooled-row callers must repaint behind a
-- token check because rows get reused before names arrive.
function VWB.UI.ResolveItemName(itemID, fn)
    ItemEventListener:AddCallback(itemID, function()
        fn(C_Item.GetItemInfo(itemID))
    end)
    C_Item.RequestLoadItemDataByID(itemID)
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

function VWB.UI:ColorCode(colorName)
    local c = GetScheme()
    if not c then return "|cFFffffff" end
    local colorMap = {
        cyan = c.accent, yellow = c.warning, green = c.success, red = c.error,
        blue = c.accent, base0 = c.text, base1 = c.text_header, base01 = c.text,
        base02 = c.panel, base03 = c.bg,
    }
    local color = colorMap[colorName]
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
-- MAIN FRAME (Draggable, UI scale)
-- ============================================================================

function VWB.UI:CreateMainFrame(name, title)
    local frame = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    frame:SetSize(900, 600)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    -- Apply UI scale from config
    local state = VWB.Store and VWB.Store:GetState()
    local uiScale = state and state.config and state.config.uiScale or 1.0
    frame:SetScale(uiScale)

    local BACKDROP_MAIN_FRAME = {
        bgFile = "Interface\\FrameGeneral\\UI-Background-Marble",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 128, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    }
    frame:SetBackdrop(BACKDROP_MAIN_FRAME)
    local scheme = GetScheme()
    local d = VWB.Constants:GetDerivedColors(scheme)
    frame:SetBackdropColor(d.marble_tint.r, d.marble_tint.g, d.marble_tint.b, d.marble_tint.a * 0.8)
    frame:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    -- Subtle background art layer for depth
    local bgArt = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    bgArt:SetAllPoints()
    bgArt:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock")
    bgArt:SetVertexColor(d.marble_tint.r, d.marble_tint.g, d.marble_tint.b, 0.04)
    frame._bgArt = bgArt

    -- Title bar
    local UI = VWB.Constants.UI
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(UI.titleBarHeight)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop(VWB.Theme.BACKDROP_PANEL)
    titleBar:SetBackdropColor(scheme.accent.r, scheme.accent.g, scheme.accent.b, scheme.accent.a * 0.2)
    titleBar:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a * 0.6)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER")
    titleText:SetText(title)
    titleText:SetTextColor(scheme.text_header.r, scheme.text_header.g, scheme.text_header.b)
    titleBar.titleText = titleText

    -- Theme toggle button
    local themeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    themeBtn:SetSize(UI.titleBarHeight, UI.titleBarHeight)
    themeBtn:SetPoint("RIGHT", -26, 0)
    themeBtn:SetBackdrop(BACKDROP_FLAT)
    themeBtn:SetBackdropColor(scheme.button_normal.r, scheme.button_normal.g, scheme.button_normal.b, scheme.button_normal.a)
    themeBtn:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    local themeIcon = themeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    themeIcon:SetPoint("CENTER")
    themeIcon:SetText("T")
    themeIcon:SetTextColor(scheme.accent.r, scheme.accent.g, scheme.accent.b)

    local function UpdateThemeIcon()
        local c = GetScheme()
        themeIcon:SetTextColor(c.accent.r, c.accent.g, c.accent.b)
    end

    local function GetNextThemeDisplayName()
        local currentTheme = VWB.Constants:GetCurrentTheme()
        local currentIndex = 1
        for i, theme in ipairs(VWB.Constants.ThemeOrder) do
            if theme == currentTheme then currentIndex = i; break end
        end
        local nextIndex = (currentIndex % #VWB.Constants.ThemeOrder) + 1
        local nextTheme = VWB.Constants.ThemeOrder[nextIndex]
        return VWB.Constants.ThemeDisplayNames[nextTheme] or VWB.Constants.ThemeNames[nextTheme] or "Dark"
    end

    themeBtn:SetScript("OnClick", function()
        local newTheme = VWB.Constants:ToggleTheme()
        local themeName = VWB.Constants.ThemeNames[newTheme] or "SolarizedDark"
        local displayName = VWB.Constants.ThemeDisplayNames[newTheme] or themeName
        if VWB.EventBus then VWB.EventBus:Trigger("VWB_THEME_UPDATE", { themeName = themeName }) end
        UpdateThemeIcon()
        print("|cFF2aa198[VWB]|r Theme: " .. displayName)
    end)
    themeBtn:SetScript("OnEnter", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Change Theme", 1, 1, 1)
        GameTooltip:AddLine("Next: " .. GetNextThemeDisplayName(), 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    themeBtn:SetScript("OnLeave", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_normal.r, c.button_normal.g, c.button_normal.b, c.button_normal.a)
        GameTooltip:Hide()
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    closeBtn:SetSize(UI.titleBarHeight, UI.titleBarHeight)
    closeBtn:SetPoint("RIGHT", 0, 0)
    closeBtn:SetBackdrop(BACKDROP_FLAT)
    closeBtn:SetBackdropColor(scheme.button_normal.r, scheme.button_normal.g, scheme.button_normal.b, scheme.button_normal.a)
    closeBtn:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    closeText:SetPoint("CENTER")
    closeText:SetText("X")
    closeText:SetTextColor(scheme.error.r, scheme.error.g, scheme.error.b)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)
    closeBtn:SetScript("OnEnter", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.error.r, c.error.g, c.error.b, 0.3)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_normal.r, c.button_normal.g, c.button_normal.b, c.button_normal.a)
    end)

    frame.titleBar = titleBar
    frame.title = titleText
    frame.themeBtn = themeBtn
    frame.closeBtn = closeBtn
    frame.UpdateThemeIcon = UpdateThemeIcon

    -- Register with Theme Engine
    RegisterWidget(frame, "Frame")
    RegisterWidget(titleBar, "TitleBar")
    RegisterWidget(themeBtn, "Button")
    RegisterWidget(closeBtn, "Button")

    return frame
end

-- ============================================================================
-- BUTTON
-- ============================================================================

function VWB.UI:CreateButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 100, height or 24)
    btn:SetNormalFontObject("GameFontHighlight")
    btn:SetText(text)
    btn:SetBackdrop(BACKDROP_FLAT)

    local scheme = GetScheme()
    btn:SetBackdropColor(scheme.button_normal.r, scheme.button_normal.g, scheme.button_normal.b, scheme.button_normal.a)
    btn:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    btn:SetScript("OnEnter", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
    end)
    btn:SetScript("OnLeave", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_normal.r, c.button_normal.g, c.button_normal.b, c.button_normal.a)
    end)

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
-- TAB GROUP
-- ============================================================================

function VWB.UI:CreateTabGroup(parent, tabsDef, onSelect)
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(28)
    container:SetPoint("TOPLEFT", parent.titleBar or parent, "BOTTOMLEFT", 0, 0)
    container:SetPoint("TOPRIGHT", parent.titleBar or parent, "BOTTOMRIGHT", 0, 0)

    local tabs = {}
    local selectedID = nil
    local xOffset = 4

    for _, def in ipairs(tabsDef) do
        local tab = CreateFrame("Button", nil, container, "BackdropTemplate")
        tab:SetSize(def.width or 80, 24)
        tab:SetPoint("LEFT", xOffset, 0)
        tab:SetNormalFontObject("GameFontHighlightSmall")
        tab:SetText(def.text)
        tab:SetBackdrop(BACKDROP_FLAT)
        tab.id = def.id

        -- Bottom accent line (visible when active)
        local accent = tab:CreateTexture(nil, "ARTWORK")
        accent:SetHeight(2)
        accent:SetPoint("BOTTOMLEFT", 1, 0)
        accent:SetPoint("BOTTOMRIGHT", -1, 0)
        accent:SetTexture("Interface\\Buttons\\WHITE8x8")
        accent:Hide()
        tab.accent = accent

        tab:SetScript("OnClick", function()
            container:Select(def.id)
            if onSelect then onSelect(def.id) end
        end)

        tab:SetScript("OnEnter", function(self)
            if selectedID ~= self.id then
                local c = GetScheme()
                self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
            end
        end)
        tab:SetScript("OnLeave", function(self)
            if selectedID ~= self.id then
                local c = GetScheme()
                self:SetBackdropColor(c.button_inactive.r, c.button_inactive.g, c.button_inactive.b, c.button_inactive.a)
            end
        end)

        RegisterWidget(tab, "Tab")
        tabs[def.id] = tab
        xOffset = xOffset + (def.width or 80) + 2
    end

    function container:Select(id)
        selectedID = id
        local c = GetScheme()
        for tabID, tab in pairs(tabs) do
            if tabID == id then
                tab:SetBackdropColor(c.accent.r, c.accent.g, c.accent.b, 0.3)
                tab:SetBackdropBorderColor(c.accent.r, c.accent.g, c.accent.b, 1)
                local fs = tab:GetFontString()
                if fs then fs:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b, 1) end
                tab.accent:SetVertexColor(c.accent.r, c.accent.g, c.accent.b, 1)
                tab.accent:Show()
                -- Re-register as ActiveTab for theme updates
                if VWB.Theme then VWB.Theme.registry[tab] = "ActiveTab" end
            else
                tab:SetBackdropColor(c.button_inactive.r, c.button_inactive.g, c.button_inactive.b, c.button_inactive.a)
                tab:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a * 0.5)
                local fs = tab:GetFontString()
                if fs then fs:SetTextColor(c.button_text_dis.r, c.button_text_dis.g, c.button_text_dis.b, 1) end
                tab.accent:Hide()
                if VWB.Theme then VWB.Theme.registry[tab] = "Tab" end
            end
        end
    end

    function container:GetSelected() return selectedID end
    container.tabs = tabs

    return container
end

-- ============================================================================
-- SCROLL LIST (Classic ScrollFrame + ScrollChild for manual child management)
-- ============================================================================

local scrollListCounter = 0

function VWB.UI:CreateScrollList(parent, name)
    scrollListCounter = scrollListCounter + 1
    name = name or ("VWBScrollList" .. scrollListCounter)

    -- Modern WowScrollBox with a single scrollable content child (heterogeneous
    -- stacked content; uniform-row lists should use CreateScrollBox instead)
    local scrollBox = CreateFrame("Frame", name, parent, "WowScrollBox")
    scrollBox:SetPoint("TOPLEFT", 0, 0)
    scrollBox:SetPoint("BOTTOMRIGHT", -12, 0)

    local scrollBar = CreateFrame("EventFrame", name .. "_Bar", parent, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

    local scrollChild = CreateFrame("Frame", name .. "_Child", scrollBox)
    scrollChild:SetWidth(scrollBox:GetWidth() or 200)
    scrollChild:SetHeight(1)
    scrollChild.scrollable = true -- WowScrollBox contract: exactly one scrollable child

    local view = CreateScrollBoxLinearView()
    view:SetPanExtent(30)
    ScrollUtil.InitScrollBoxWithScrollBar(scrollBox, scrollBar, view)

    scrollBox:SetScript("OnSizeChanged", function(sf, w)
        scrollChild:SetWidth(w)
    end)

    scrollBox.scrollBar = scrollBar
    return scrollBox, scrollChild
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
-- QUEUE ROW (Removable item row for crafting queue)
-- ============================================================================

function VWB.UI:CreateQueueRow(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop(BACKDROP_FLAT)
    row:SetBackdropColor(scheme.panel.r, scheme.panel.g, scheme.panel.b, 0.3)
    row:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)
    row:RegisterForClicks("AnyUp")

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
    -- right now (net of queue commitments) -- same green success signal as
    -- the Workbench craft-heat glow (Recipes.lua row.craftGlow)
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
        if options.onClick then options.onClick(row._item) end
    end)

    -- Quantity steppers: -/+ adjust the planned amount in place (the one
    -- operation a shopping list can't live without). Minus at qty 1 removes
    -- the entry, same as the reducer's qty<=0 contract.
    local function MakeStepper(label, xOff, delta)
        local btn = CreateFrame("Button", nil, row)
        btn:SetSize(14, 16)
        btn:SetPoint("RIGHT", xOff, 0)
        btn:RegisterForClicks("AnyUp")
        local t = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetAllPoints()
        t:SetText(label)
        t:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b)
        btn._label = t
        btn:SetScript("OnEnter", function(self)
            local c = GetScheme()
            self._label:SetTextColor(c.text.r, c.text.g, c.text.b)
        end)
        btn:SetScript("OnLeave", function(self)
            local c = GetScheme()
            self._label:SetTextColor(c.text.r, c.text.g, c.text.b)
        end)
        btn:SetScript("OnClick", function()
            if options.onQtyDelta then
                options.onQtyDelta(row._item, IsShiftKeyDown() and delta * 5 or delta)
            end
        end)
        return btn
    end
    row.plusBtn = MakeStepper("+", -39, 1)
    row.minusBtn = MakeStepper("-", -55, -1)

    -- Craft button (shown for the current character's rows; validated at click)
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
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Craft", 1, 1, 1)
        GameTooltip:AddLine("Requires this profession's window to be open.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    craftBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.craftBtn = craftBtn

    row:SetScript("OnEnter", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a * 0.5)
        if self._item and self._item.itemID then
            local tip = VWB.UI.Tooltip
            tip:Begin(self)
            tip:SetItemHeader(self._item.itemID, self._item.name)
            if self._item.qty and self._item.qty > 1 then
                tip:AddLine(VWB.UI:ColorCode("base01") .. "Queued: x" .. self._item.qty .. "|r")
            end
            tip:Show()
            VWB.GuildCrafters:AppendCraftersToTooltip(tip, self._item.recipeID)
        end
    end)
    row:SetScript("OnLeave", function(self)
        local c = GetScheme()
        self:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, 0.3)
        VWB.GuildCrafters:CancelTooltip()
        VWB.UI.Tooltip:Hide(self)
    end)

    -- Right-click the row body removes the whole entry (the x button is the
    -- discoverable path; right-click is the fast one). Left-click is inert:
    -- the steppers/craft/remove sub-buttons own the row's click affordances.
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and options.onRightClick then
            options.onRightClick(self._item)
        end
    end)

    -- Data is applied via SetData so pooled rows can be repainted without recreation
    function row:SetData(item)
        self._item = item
        local itemIcon = item.itemID and C_Item.GetItemIconByID(item.itemID)
        self.icon:SetTexture(itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local label = item.name or "Unknown"
        if item.qty and item.qty > 1 then label = label .. " x" .. item.qty end
        self.text:SetText(label)
        -- Craft affordance only where it can act: this character's plan (or untagged legacy rows)
        self.craftBtn:SetShown(options.onCraft ~= nil
            and (item.charKey == nil or item.charKey == VWB.CharacterData:GetCharacterKey()))
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

    if options.item then row:SetData(options.item) end

    RegisterWidget(row, "Button")
    return row
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
    local debounceTime = options.debounce or 0.3

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

    -- Debounced onChange
    local timer = nil
    box:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local text2 = self:GetText()
        placeholder:SetShown(text2 == "")
        if timer then timer:Cancel() end
        timer = C_Timer.NewTimer(debounceTime, function()
            if options.onChange then options.onChange(text2) end
        end)
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
-- FILTER BUTTON ROW (Text-based toggle buttons)
-- ============================================================================

local filterRowCounter = 0

function VWB.UI:CreateFilterButtonRow(parent, options)
    options = options or {}
    local items = options.items or {}
    local onSelect = options.onSelect
    local allowMultiple = options.allowMultiple or false
    local buttonHeight = options.buttonHeight or 20
    local buttonPadding = options.buttonPadding or 2

    filterRowCounter = filterRowCounter + 1
    local rowName = "VWBFilterRow" .. filterRowCounter

    local container = CreateFrame("Frame", rowName, parent)
    container:SetAllPoints()

    local buttons = {}
    local selectedKeys = {}
    local suppressCallbacks = false

    local function UpdateButtonAppearance(btn, isActive)
        local c = GetScheme()
        if isActive then
            btn:SetBackdropColor(c.button_active.r, c.button_active.g, c.button_active.b, c.button_active.a)
            btn.text:SetTextColor(1, 1, 1, 1)
        else
            btn:SetBackdropColor(c.button_inactive.r, c.button_inactive.g, c.button_inactive.b, c.button_inactive.a * 0.8)
            btn.text:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
        end
    end

    local xOffset = 0
    for _, item in ipairs(items) do
        local displayText = item.abbrev or item.label or item.key
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")

        local tempText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tempText:SetText(displayText)
        local textWidth = tempText:GetStringWidth()
        local buttonWidth = math.max(textWidth + 12, 30)

        btn:SetSize(buttonWidth, buttonHeight)
        btn:SetPoint("LEFT", xOffset, 0)
        btn:SetBackdrop(BACKDROP_FLAT)

        tempText:ClearAllPoints()
        tempText:SetPoint("CENTER", 0, 0)
        btn.text = tempText
        btn.key = item.key
        btn.itemData = item

        UpdateButtonAppearance(btn, false)

        btn:SetScript("OnClick", function(self)
            if suppressCallbacks then return end
            local wasSelected = selectedKeys[self.key]
            if allowMultiple then
                selectedKeys[self.key] = not selectedKeys[self.key]
                UpdateButtonAppearance(self, selectedKeys[self.key])
                if onSelect and (wasSelected ~= selectedKeys[self.key]) then onSelect(selectedKeys) end
            else
                if wasSelected then return end
                for _, b in ipairs(buttons) do
                    selectedKeys[b.key] = false
                    UpdateButtonAppearance(b, false)
                end
                selectedKeys[self.key] = true
                UpdateButtonAppearance(self, true)
                if onSelect then onSelect(self.key) end
            end
        end)

        btn:SetScript("OnEnter", function(self)
            if not selectedKeys[self.key] then
                local c = GetScheme()
                self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
            end
            if item.label and item.label ~= displayText then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(item.label, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function(self)
            UpdateButtonAppearance(self, selectedKeys[self.key])
            GameTooltip:Hide()
        end)

        table.insert(buttons, btn)
        xOffset = xOffset + buttonWidth + buttonPadding
    end

    container.buttons = buttons
    container.selectedKeys = selectedKeys

    function container:SetSelected(key)
        suppressCallbacks = true
        if type(key) == "table" then
            selectedKeys = {}
            for k, v in pairs(key) do selectedKeys[k] = v end
        else
            for _, b in ipairs(buttons) do selectedKeys[b.key] = false end
            if key then selectedKeys[key] = true end
        end
        for _, btn in ipairs(buttons) do
            UpdateButtonAppearance(btn, selectedKeys[btn.key])
        end
        suppressCallbacks = false
    end

    function container:ClearAll()
        suppressCallbacks = true
        selectedKeys = {}
        container.selectedKeys = selectedKeys
        for _, btn in ipairs(buttons) do
            UpdateButtonAppearance(btn, false)
        end
        suppressCallbacks = false
    end

    function container:GetSelected() return selectedKeys end

    RegisterWidget(container, "FilterButtonRow")
    return container
end

-- ============================================================================
-- ICON FILTER BUTTON ROW (Profession icons)
-- ============================================================================

local iconFilterCounter = 0

function VWB.UI:CreateIconFilterButtonRow(parent, options)
    options = options or {}
    local items = options.items or {}
    local onSelect = options.onSelect
    local allowMultiple = options.allowMultiple or false
    local buttonSize = options.buttonSize or 28
    local buttonPadding = options.buttonPadding or 2
    local iconPadding = options.iconPadding or 4

    iconFilterCounter = iconFilterCounter + 1
    local rowName = "VWBIconFilter" .. iconFilterCounter

    local container = CreateFrame("Frame", rowName, parent)
    container:SetAllPoints()

    local buttons = {}
    local selectedKeys = {}
    local suppressCallbacks = false

    local function UpdateButtonAppearance(btn, isActive)
        local c = GetScheme()
        if isActive then
            btn:SetBackdropColor(c.button_active.r, c.button_active.g, c.button_active.b, c.button_active.a)
            btn:SetBackdropBorderColor(c.accent.r, c.accent.g, c.accent.b, 1)
            if btn.icon then btn.icon:SetDesaturated(false); btn.icon:SetAlpha(1) end
        else
            btn:SetBackdropColor(c.button_inactive.r, c.button_inactive.g, c.button_inactive.b, c.button_inactive.a * 0.5)
            btn:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a * 0.5)
            if btn.icon then btn.icon:SetDesaturated(true); btn.icon:SetAlpha(0.6) end
        end
    end

    local xOffset = 0
    for _, item in ipairs(items) do
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        btn:SetSize(buttonSize, buttonSize)
        btn:SetPoint("LEFT", xOffset, 0)
        btn:SetBackdrop(BACKDROP_FLAT)

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(buttonSize - iconPadding * 2, buttonSize - iconPadding * 2)
        icon:SetPoint("CENTER")
        icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        btn.icon = icon
        btn.key = item.key
        btn.itemData = item

        UpdateButtonAppearance(btn, false)

        btn:SetScript("OnClick", function(self)
            if suppressCallbacks then return end
            local wasSelected = selectedKeys[self.key]
            if allowMultiple then
                selectedKeys[self.key] = not selectedKeys[self.key]
                UpdateButtonAppearance(self, selectedKeys[self.key])
                if onSelect and (wasSelected ~= selectedKeys[self.key]) then onSelect(selectedKeys) end
            else
                if wasSelected then return end
                for _, b in ipairs(buttons) do
                    selectedKeys[b.key] = false
                    UpdateButtonAppearance(b, false)
                end
                selectedKeys[self.key] = true
                UpdateButtonAppearance(self, true)
                if onSelect then onSelect(self.key) end
            end
        end)

        btn:SetScript("OnEnter", function(self)
            if not selectedKeys[self.key] then
                local c = GetScheme()
                self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, c.button_hover.a)
            end
            if item.label then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(item.label, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function(self)
            UpdateButtonAppearance(self, selectedKeys[self.key])
            GameTooltip:Hide()
        end)

        table.insert(buttons, btn)
        xOffset = xOffset + buttonSize + buttonPadding
    end

    container.buttons = buttons
    container.selectedKeys = selectedKeys

    function container:SetSelected(key)
        suppressCallbacks = true
        if type(key) == "table" then
            selectedKeys = {}
            for k, v in pairs(key) do selectedKeys[k] = v end
        else
            for _, b in ipairs(buttons) do selectedKeys[b.key] = false end
            if key then selectedKeys[key] = true end
        end
        for _, btn in ipairs(buttons) do
            UpdateButtonAppearance(btn, selectedKeys[btn.key])
        end
        suppressCallbacks = false
    end

    function container:ClearAll()
        suppressCallbacks = true
        selectedKeys = {}
        container.selectedKeys = selectedKeys
        for _, btn in ipairs(buttons) do
            UpdateButtonAppearance(btn, false)
        end
        suppressCallbacks = false
    end

    function container:GetSelected() return selectedKeys end

    RegisterWidget(container, "IconFilterButtonRow")
    return container
end

-- ============================================================================
-- SEGMENTED TOGGLE (Direct/Raw mode switch)
-- ============================================================================

-- Atlas pill textures (auctionhouse-nav-button family, verified in
-- Reference/ATLAS_REFERENCE.md + texture atlas data). options.pill = true swaps
-- the flat segment fills for these; the container border is dropped so only the
-- pills read. Segments still take the same callbacks -- purely visual.
local PILL_ATLAS_INACTIVE = "auctionhouse-nav-button"
local PILL_ATLAS_ACTIVE = "auctionhouse-nav-button-select"
local PILL_ATLAS_HIGHLIGHT = "auctionhouse-nav-button-highlight"

function VWB.UI:CreateSegmentedToggle(parent, options)
    options = options or {}
    local pill = options.pill
    local scheme = GetScheme()

    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(options.width or 160, options.height or 24)
    -- Pill mode carries its own atlas per segment; deliberately no container
    -- backdrop so no box shows AND the SegmentedToggle theme skinner's
    -- SetBackdropColor is a no-op (no backdrop set) instead of re-boxing it.
    if not pill then
        container:SetBackdrop(BACKDROP_FLAT)
        container:SetBackdropColor(scheme.panel.r, scheme.panel.g, scheme.panel.b, scheme.panel.a)
        container:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)
    end

    local btns = {}
    local selected = options.default or options.segments[1].key

    local segWidth = (options.width or 160) / #options.segments
    for i, seg in ipairs(options.segments) do
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        btn:SetSize(pill and (segWidth - 2) or segWidth, (options.height or 24) - 2)
        btn:SetPoint("LEFT", (i - 1) * segWidth + 1, 0)
        btn.key = seg.key

        if pill then
            local pbg = btn:CreateTexture(nil, "BACKGROUND")
            pbg:SetAllPoints()
            pbg:SetAtlas(PILL_ATLAS_INACTIVE)
            btn.pillBg = pbg
            local phl = btn:CreateTexture(nil, "HIGHLIGHT")
            phl:SetAllPoints()
            phl:SetAtlas(PILL_ATLAS_HIGHLIGHT)
            phl:SetAlpha(0.5)
        else
            btn:SetBackdrop(BACKDROP_BORDERLESS)
        end

        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("CENTER")
        text:SetText(seg.label or seg.key)
        btn.text = text

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
            local isActive = btn.key == selected
            if pill then
                btn.pillBg:SetAtlas(isActive and PILL_ATLAS_ACTIVE or PILL_ATLAS_INACTIVE)
                if isActive then
                    btn.text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b, 1)
                else
                    btn.text:SetTextColor(c.text.r, c.text.g, c.text.b, 1)
                end
            elseif isActive then
                btn:SetBackdropColor(c.button_active.r, c.button_active.g, c.button_active.b, c.button_active.a)
                btn.text:SetTextColor(c.button_text_norm.r, c.button_text_norm.g, c.button_text_norm.b, 1)
            else
                btn:SetBackdropColor(c.button_inactive.r, c.button_inactive.g, c.button_inactive.b, c.button_inactive.a)
                btn.text:SetTextColor(c.button_text_dis.r, c.button_text_dis.g, c.button_text_dis.b, 1)
            end
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
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(FILTER_PILL_HEIGHT)
    btn:RegisterForClicks("AnyUp")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetAtlas(PILL_ATLAS_INACTIVE)
    btn.bg = bg

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetAtlas(PILL_ATLAS_HIGHLIGHT)
    hl:SetAlpha(0.5)

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER", 0, 0)
    text:SetText(label)
    btn.text = text
    btn:SetWidth(math.max(math.ceil(text:GetUnboundedStringWidth()) + FILTER_PILL_HPAD * 2, FILTER_PILL_MIN_WIDTH))

    btn.checked = false
    local function Repaint()
        local c = GetScheme()
        if btn.checked then
            bg:SetAtlas(PILL_ATLAS_ACTIVE)
            text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
        else
            bg:SetAtlas(PILL_ATLAS_INACTIVE)
            text:SetTextColor(c.text.r, c.text.g, c.text.b)
        end
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
-- CATEGORY HEADER (Collapsible section)
-- ============================================================================

function VWB.UI:CreateCategoryHeader(parent, options)
    options = options or {}
    local scheme = GetScheme()

    local header = CreateFrame("Button", nil, parent)
    header:SetHeight(options.height or 20)

    -- Arrow
    local arrow = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arrow:SetPoint("LEFT", 4, 0)
    arrow:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    header.arrow = arrow

    -- Category text
    local text = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
    text:SetTextColor(scheme.accent.r, scheme.accent.g, scheme.accent.b, scheme.accent.a)
    header.text = text

    -- Count text
    local countText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countText:SetPoint("LEFT", text, "RIGHT", 4, 0)
    countText:SetTextColor(scheme.text.r, scheme.text.g, scheme.text.b, scheme.text.a)
    header.countText = countText

    local collapsed = options.collapsed or false
    header.collapsed = collapsed

    local function UpdateArrow()
        arrow:SetText(header.collapsed and "+" or "-")
    end
    UpdateArrow()

    header:SetScript("OnClick", function(self)
        self.collapsed = not self.collapsed
        UpdateArrow()
        if options.onToggle then options.onToggle(self.collapsed, self) end -- header passed for pooled reuse
    end)

    function header:SetCollapsed(state)
        self.collapsed = state
        UpdateArrow()
    end

    function header:SetLabel(label)
        text:SetText(label or "")
    end

    function header:SetCount(count)
        countText:SetText(count and ("(" .. count .. ")") or "")
    end

    RegisterWidget(header, "CategoryHeader")
    return header
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
-- PANEL (Inset background frame)
-- ============================================================================

function VWB.UI:CreatePanel(parent, width, height)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if width and height then panel:SetSize(width, height) end
    panel:SetBackdrop(VWB.Theme.BACKDROP_PANEL)

    local scheme = GetScheme()
    local d = VWB.Constants:GetDerivedColors(scheme)
    panel:SetBackdropColor(d.marble_tint.r, d.marble_tint.g, d.marble_tint.b, d.marble_tint.a)
    panel:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, scheme.border.a)

    RegisterWidget(panel, "Panel")
    return panel
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
local function FormatProfessionSummary(professions)
    local names = {}
    for profName in pairs(professions) do
        table.insert(names, profName)
    end
    if #names == 0 then return "No professions scanned" end
    table.sort(names)
    return table.concat(names, " / ")
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
-- PAGE RAIL (vertical icon strip, DecorDrop style)
-- ============================================================================

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

        -- Gold top accent line (shown when active)
        local topAccent = btn:CreateTexture(nil, "OVERLAY")
        topAccent:SetPoint("TOPLEFT", 1, 0)
        topAccent:SetPoint("TOPRIGHT", -1, 0)
        topAccent:SetHeight(2)
        topAccent:SetColorTexture(1, 0.82, 0.2, 1)
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

-- pages = array of { id, icon, label }
-- onSelect(pageId) called on click
-- Returns rail frame with :Select(id) and :GetSelected()
-- ============================================================================
-- CRAFT TOAST (global craft-complete notification -- window chrome anchored
-- by MainFrame to the main window's top-right, not a per-tab widget; fires
-- regardless of which page is active so crafting away from the Workbench
-- still gets glanceable feedback)
-- ============================================================================
function VWB.UI:CreateCraftToast(parent)
    local toast = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    toast:SetSize(220, 40)
    toast:SetBackdrop(VWB.UI.BACKDROP_CARD)
    toast:SetFrameStrata("HIGH")
    toast:SetAlpha(0)
    toast:Hide()

    local icon = toast:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("LEFT", 6, 0)
    toast.icon = icon

    local text = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    text:SetPoint("RIGHT", -8, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    toast.text = text

    -- Fade in / hold / fade out -- one reusable AnimationGroup built once,
    -- replayed via Stop()+Play() (established pooled-animation pattern, see
    -- Recipes.lua's PlayQueueCraftFlash). The hold is a same-alpha Alpha anim,
    -- not a timer -- no per-notification allocation.
    local ag = toast:CreateAnimationGroup()
    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(0.25); fadeIn:SetOrder(1)
    local hold = ag:CreateAnimation("Alpha")
    hold:SetFromAlpha(1); hold:SetToAlpha(1); hold:SetDuration(2.5); hold:SetOrder(2)
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(0.4); fadeOut:SetOrder(3)
    ag:SetScript("OnFinished", function() toast:Hide() end)
    toast._ag = ag

    function toast:Notify(iconTexture, label)
        icon:SetTexture(iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark") -- exception(boundary): nil item icon on cold cache
        text:SetText(label)
        if ag:IsPlaying() then ag:Stop() end
        toast:SetAlpha(0)
        toast:Show()
        ag:Play()
    end

    RegisterWidget(toast, "CraftToast")
    return toast
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

function VWB.UI:CreatePageRail(parent, pages, onSelect)
    local UI = VWB.Constants.UI
    local RAIL_W = UI.PAGE_RAIL_WIDTH
    local BTN_SIZE = UI.PAGE_BUTTON_SIZE

    local rail = CreateFrame("Frame", nil, parent)
    rail:SetWidth(RAIL_W)

    rail.buttons = {}
    rail.selected = nil

    -- Flyout label plate: fades in beside the hovered rail button (replaces
    -- the bare GameTooltip label; floats above page content)
    local flyout = CreateFrame("Frame", nil, rail, "BackdropTemplate")
    flyout:SetBackdrop(VWB.UI.BACKDROP_CARD)
    flyout:SetFrameStrata("HIGH")
    flyout:Hide()
    local flyoutText = flyout:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    flyoutText:SetPoint("LEFT", 10, 0)
    flyout.text = flyoutText
    local flyoutAnim = flyout:CreateAnimationGroup()
    local flyoutFade = flyoutAnim:CreateAnimation("Alpha")
    flyoutFade:SetFromAlpha(0)
    flyoutFade:SetToAlpha(1)
    flyoutFade:SetDuration(0.1)
    rail.flyout = flyout

    local BACKDROP_RAIL_BTN = {
        bgFile = "Interface\\FrameGeneral\\UI-Background-Marble",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    }

    local yOff = -4
    for _, page in ipairs(pages) do
        local btn = CreateFrame("Button", nil, rail, "BackdropTemplate")
        btn:SetSize(BTN_SIZE, BTN_SIZE)
        btn:SetPoint("TOP", 0, yOff)
        btn:SetBackdrop(BACKDROP_RAIL_BTN)
        btn:SetBackdropColor(0, 0, 0, 0)
        btn:SetBackdropBorderColor(0, 0, 0, 0)
        btn.pageId = page.id

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(BTN_SIZE - 10, BTN_SIZE - 10)
        icon:SetPoint("CENTER")
        icon:SetTexture(page.icon)
        btn.icon = icon

        -- Gold glow for active state (vertex-colored for skinner recoloring)
        local glow = btn:CreateTexture(nil, "BACKGROUND")
        glow:SetSize(BTN_SIZE + 4, BTN_SIZE + 4)
        glow:SetPoint("CENTER")
        glow:SetTexture("Interface\\Buttons\\WHITE8x8")
        glow:SetVertexColor(1, 0.82, 0.2, 0.25)
        glow:Hide()
        btn.glow = glow

        -- Selected highlight overlay (vertex-colored)
        local selected = btn:CreateTexture(nil, "OVERLAY")
        selected:SetAllPoints()
        selected:SetTexture("Interface\\Buttons\\WHITE8x8")
        selected:SetVertexColor(1, 0.82, 0.2, 0.15)
        selected:Hide()
        btn.selectedTex = selected

        btn:SetScript("OnEnter", function(self)
            local c = GetScheme()
            if rail.selected ~= self.pageId then
                self:SetBackdropColor(c.button_hover.r, c.button_hover.g, c.button_hover.b, 0.4)
            end
            if page.hint then
                flyout.text:SetText(page.label .. "  " .. VWB.UI:ColorCode("base01") .. page.hint .. "|r")
            else
                flyout.text:SetText(page.label)
            end
            flyout.text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
            flyout:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, 0.97)
            flyout:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
            flyout:SetSize(flyout.text:GetUnboundedStringWidth() + 20, 26)
            flyout:ClearAllPoints()
            flyout:SetPoint("LEFT", self, "RIGHT", 2, 0)
            flyout:Show()
            flyoutAnim:Stop()
            flyoutAnim:Play()
        end)
        btn:SetScript("OnLeave", function(self)
            if rail.selected ~= self.pageId then
                self:SetBackdropColor(0, 0, 0, 0)
            end
            flyout:Hide()
        end)
        btn:SetScript("OnClick", function(self)
            rail:Select(self.pageId)
            if onSelect then onSelect(self.pageId) end
        end)

        RegisterWidget(btn, "Button")
        rail.buttons[page.id] = btn
        yOff = yOff - (BTN_SIZE + 2)
    end

    function rail:Select(id)
        self.selected = id
        local c = GetScheme()
        local d = VWB.Constants:GetDerivedColors(c)
        for btnId, btn in pairs(self.buttons) do
            if btnId == id then
                btn.glow:SetVertexColor(d.selected_glow.r, d.selected_glow.g, d.selected_glow.b, d.selected_glow.a)
                btn.glow:Show()
                btn.selectedTex:SetVertexColor(d.selected_fill.r, d.selected_fill.g, d.selected_fill.b, d.selected_fill.a)
                btn.selectedTex:Show()
                btn:SetBackdropColor(d.selected_fill.r, d.selected_fill.g, d.selected_fill.b, d.selected_fill.a)
                btn:SetBackdropBorderColor(d.border_glow.r, d.border_glow.g, d.border_glow.b, 1)
                btn.icon:SetDesaturated(false)
                btn.icon:SetAlpha(1)
                VWB.Theme:Register(btn, "ActivePageButton")
            else
                btn.glow:Hide()
                btn.selectedTex:Hide()
                btn:SetBackdropColor(0, 0, 0, 0)
                btn:SetBackdropBorderColor(0, 0, 0, 0)
                btn.icon:SetDesaturated(true)
                btn.icon:SetAlpha(0.5)
                VWB.Theme:Register(btn, "PageButton")
            end
        end
    end

    function rail:GetSelected()
        return self.selected
    end

    return rail
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

    function nav:Refresh()
        VWB.UI:ResetRows(content)
        local c = GetScheme()
        local d = VWB.Constants:GetDerivedColors(c)
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
                header.text:SetText(string.format("|cFF%s%s|r", VWB.UI:ToHex(section.color), section.label))
            else
                header.accentBar:SetColorTexture(c.accent.r, c.accent.g, c.accent.b, 1)
                header.text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b)
                header.text:SetText(section.label)
            end
            header.countText:SetText(section.itemCount and ("|cFF" .. VWB.UI:ToHex(c.text) .. section.itemCount .. "|r") or "")
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
                    row.countText:SetText(item.count and ("|cFF" .. VWB.UI:ToHex(c.text) .. item.count .. "|r") or "")
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
