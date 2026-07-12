-- ============================================================================
-- VamoosesWorkbench - Theme Engine
-- Weak-table widget registry with pure-function skinners for live switching
-- ============================================================================

VWB = VWB or {}
VWB.Theme = {}

-- Weak table: widgets auto-removed on garbage collection
VWB.Theme.registry = setmetatable({}, { __mode = "k" })
VWB.Theme.currentScheme = nil

-- ============================================================================
-- CENTRALIZED BACKDROP DEFINITIONS
-- ============================================================================

VWB.Theme.BACKDROP_FLAT = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

VWB.Theme.BACKDROP_BORDERLESS = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = nil,
    tile = false,
}

VWB.Theme.BACKDROP_PANEL = {
    bgFile = "Interface\\FrameGeneral\\UI-Background-Marble",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 64, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

VWB.Theme.BACKDROP_CARD = {
    bgFile = "Interface\\FrameGeneral\\UI-Background-Marble",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 32, edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- ============================================================================
-- FONT OBJECTS -- THE font pipeline (owner 2026-07-13: themes drive fonts).
-- ============================================================================
-- Addon-owned twins of the Blizzard font templates. Every VWB FontString is
-- created with a VWBFont* template, so ONE SetFont here re-fonts the whole
-- addon live (font objects propagate to attached strings). Face comes from
-- config.fontFamily via Constants:GetFontFile; size, color, and shadow
-- inherit from the twin -- sizing is the UI Scale slider's job (owner
-- 2026-07-13: no separate font-scale knob), colors stay paint-managed.

local FONT_TWINS = {
    VWBFontNormal         = "GameFontNormal",
    VWBFontHighlight      = "GameFontHighlight",
    VWBFontNormalSmall    = "GameFontNormalSmall",
    VWBFontHighlightSmall = "GameFontHighlightSmall",
    VWBFontNormalLarge    = "GameFontNormalLarge",
    VWBFontDisableSmall   = "GameFontDisableSmall",
}
local fontBaseSizes = {}
for name, base in pairs(FONT_TWINS) do
    local f = CreateFont(name)
    f:CopyFontObject(base) -- face/size/flags/color/shadow from the Blizzard twin
    local _, size = _G[base]:GetFont()
    fontBaseSizes[name] = size
end

function VWB.Theme:ApplyFontObjects()
    local file = VWB.Constants:GetFontFile()
    for name in pairs(FONT_TWINS) do
        local f = _G[name]
        local _, _, flags = f:GetFont()
        f:SetFont(file, fontBaseSizes[name], flags or "")
    end
end
VWB.Theme:ApplyFontObjects() -- file-load pass: themed face before any view builds

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function VWB.Theme:Initialize()
    self:ApplyFontObjects() -- SavedVariables are live now: persisted family/scale
    -- Store:Initialize ran first (VWB_Init), so state.config aliases the persisted
    -- VWB_DB.config -- read the saved theme strictly.
    local themeKey = VWB.Store:GetState().config.theme or "solarizeddark" -- exception(optional): unset until the user first picks a theme
    local themeName = VWB.Constants.ThemeNames[themeKey] or "SolarizedDark" -- exception(boundary): stale/legacy persisted key -> safe default
    self.currentScheme = VWB.Colors.Schemes[themeName]

    -- Theme epoch (Gap B): registered widgets repaint via UpdateAll, but POOLED
    -- list rows paint their colors in updateRow -- without a reactive nudge they
    -- keep the old theme until the next data-driven repaint (scroll/dispatch).
    -- List-render effects read Theme.epoch() so a switch re-runs them.
    -- Created here, not at file load: Reactor loads after ThemeEngine in the TOC.
    self.epoch = VWB.Reactor.signal(0)

    VWB.EventBus:Register("VWB_THEME_UPDATE", function(payload)
        if payload.themeName then -- font/opacity refreshes fire without themeName; keep current scheme
            self.currentScheme = VWB.Colors.Schemes[payload.themeName]
        end
        self:ApplyFontObjects() -- family/scale config may have changed; propagates to every VWBFont* string
        self:UpdateAll()
        VWB.Reactor.untrack(function() self.epoch(self.epoch() + 1) end) -- after UpdateAll: rows repaint against the NEW scheme
    end)
end

-- ============================================================================
-- REGISTRY API
-- ============================================================================

function VWB.Theme:Register(widget, widgetType)
    self.registry[widget] = widgetType
    if self.Skinners[widgetType] and self.currentScheme then
        self.Skinners[widgetType](widget, self.currentScheme)
    end
end

function VWB.Theme:UpdateAll()
    for widget, widgetType in pairs(self.registry) do
        if self.Skinners[widgetType] then
            self.Skinners[widgetType](widget, self.currentScheme)
        end
    end
end

-- VWB.Theme:GetScheme() removed -- use VWB.UI:GetScheme() (Framework.lua) at all call sites.

-- ============================================================================
-- HELPERS
-- ============================================================================


local function GetBgOpacity()
    if VWB.Store then
        local state = VWB.Store:GetState()
        if state and state.config then return state.config.bgOpacity or 0.9 end
    end
    return 0.9
end
VWB.Theme.GetBgOpacity = GetBgOpacity

local function ApplyFont(fontString, scheme, fontType)
    if not fontString or not fontString.SetFont then return end
    fontType = fontType or "body"
    scheme = scheme or VWB.Theme.currentScheme
    if not scheme or not scheme.fonts then return end
    local f = scheme.fonts[fontType] or scheme.fonts.body
    if f then
        local fontFile = VWB.Constants:GetFontFile()
        fontString:SetFont(fontFile, f.size, f.flags or "")
    end
end
VWB.Theme.ApplyFont = ApplyFont

-- Atlas texture helpers
local function ApplyAtlasBackground(frame, atlasName)
    if not frame or not atlasName then return end
    if not frame._atlasBg then
        frame._atlasBg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        frame._atlasBg:SetAllPoints()
    end
    frame._atlasBg:SetAtlas(atlasName, true)
    frame._atlasBg:Show()
end

local function ApplyAtlasHeader(titleBar, atlasName)
    if not titleBar or not atlasName then return end
    if not titleBar._atlasHeader then
        titleBar._atlasHeader = titleBar:CreateTexture(nil, "BACKGROUND", nil, -8)
        titleBar._atlasHeader:SetAllPoints()
    end
    titleBar._atlasHeader:SetAtlas(atlasName, true)
    titleBar._atlasHeader:Show()
end

local function HideAtlasTextures(frame)
    if frame._atlasBg then frame._atlasBg:Hide() end
    if frame._atlasHeader then frame._atlasHeader:Hide() end
end

VWB.Theme.ApplyAtlasBackground = ApplyAtlasBackground
VWB.Theme.ApplyAtlasHeader = ApplyAtlasHeader
VWB.Theme.HideAtlasTextures = HideAtlasTextures

-- ============================================================================
-- SKINNERS (Pure functions applying colors + fonts to widgets)
-- ============================================================================

VWB.Theme.Skinners = {

    -- Main window frame (Atlas-aware)
    Frame = function(f, c)
        if c.atlas and c.atlas.background then
            ApplyAtlasBackground(f, c.atlas.background)
            if f.SetBackdropColor then
                f:SetBackdropColor(0, 0, 0, 0)
                f:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
            end
        else
            HideAtlasTextures(f)
            if f.SetBackdropColor then
                f:SetBackdropColor(c.bg.r, c.bg.g, c.bg.b, c.bg.a)
                f:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
            end
        end
        if f.title then
            f.title:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b, c.text_header.a)
            ApplyFont(f.title, c, "header")
        end
    end,

    -- Panel (marble tint + tooltip border colors)
    Panel = function(f, c)
        if f.SetBackdropColor then
            local d = VWB.Constants:GetDerivedColors(c)
            f:SetBackdropColor(d.marble_tint.r, d.marble_tint.g, d.marble_tint.b, d.marble_tint.a * GetBgOpacity())
            f:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
        end
    end,


    -- Button
    Button = function(b, c)
        -- Tertiary atlas buttons (the addon-wide standard, unification
        -- 2026-07-11) repaint through their own painter -- re-tints the four
        -- state textures + text for the new scheme, honoring _active.
        if b._tertiary then
            VWB.UI:PaintTertiaryButton(b, c)
            b._scheme = c
            return
        end
        if b.SetBackdropColor then
            b:SetBackdropColor(c.button_normal.r, c.button_normal.g, c.button_normal.b, c.button_normal.a)
            b:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
        end
        local fs = b:GetFontString()
        if fs then
            fs:SetTextColor(c.button_text_norm.r, c.button_text_norm.g, c.button_text_norm.b, c.button_text_norm.a)
            ApplyFont(fs, c)
        end
        b._scheme = c
    end,


    -- Danger button (destructive actions -- Hard Reset etc.). Registered a
    -- second time over CreateButton's own "Button" role so the last-write-wins
    -- registry entry keeps it red across theme switches; OnEnter/OnLeave are
    -- overridden by the caller to match (see Config.lua Danger Zone section).
    DangerButton = function(b, c)
        if b.SetBackdropColor then
            b:SetBackdropColor(c.error.r * 0.55, c.error.g * 0.55, c.error.b * 0.55, c.error.a)
            b:SetBackdropBorderColor(c.error.r, c.error.g, c.error.b, 1)
        end
        local fs = b:GetFontString()
        if fs then
            fs:SetTextColor(c.button_text_norm.r, c.button_text_norm.g, c.button_text_norm.b, c.button_text_norm.a)
            ApplyFont(fs, c)
        end
        b._scheme = c
    end,



    -- Text label (body)
    Label = function(fs, c)
        fs:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
        ApplyFont(fs, c)
    end,

    -- Header label
    HeaderLabel = function(fs, c)
        fs:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b, c.text_header.a)
        ApplyFont(fs, c, "header")
    end,

    -- Dim text label
    DimLabel = function(fs, c)
        fs:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
        ApplyFont(fs, c, "small")
    end,

    -- Search box (EditBox)
    SearchBox = function(f, c)
        if f.placeholder then
            f.placeholder:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
        end
        if f.SetTextColor then
            f:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
        end
        ApplyFont(f, c)
    end,

    -- Checkbox (UICheckButtonTemplate)
    Checkbox = function(f, c)
        if f.label then
            f.label:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
            ApplyFont(f.label, c)
            if f.button then -- container-style checkbox: refit bounds to the re-fonted label
                local w = math.ceil(f.label:GetUnboundedStringWidth())
                f:SetSize(28 + w, 24)
                f.button:SetHitRectInsets(0, -(w + 4), 0, 0)
            end
        end
    end,

    -- Section header with divider
    SectionHeader = function(f, c)
        if f.text then
            f.text:SetTextColor(c.accent.r, c.accent.g, c.accent.b, c.accent.a)
            ApplyFont(f.text, c, "header")
        end
        if f.divider then
            f.divider:SetVertexColor(c.text.r, c.text.g, c.text.b, c.text.a)
        end
    end,

    -- ScrollBox container
    ScrollBox = function(f, c)
        if f.bg and f.bg.SetBackdropColor then
            f.bg:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, c.panel.a)
            f.bg:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a)
        end
    end,







    -- Divider line
    Divider = function(f, c)
        f:SetVertexColor(c.border.r, c.border.g, c.border.b, c.border.a)
    end,

    -- Segmented toggle: segments are tertiary atlas buttons; UpdateAppearance
    -- repaints each through the shared painter with the current scheme
    -- (unification 2026-07-11 -- the per-segment backdrop painting is gone).
    SegmentedToggle = function(f, _c)
        if f.UpdateAppearance then f:UpdateAppearance() end
    end,

    -- Progress bar
    ProgressBar = function(f, c)
        if f.bg and f.bg.SetVertexColor then
            f.bg:SetVertexColor(c.panel.r, c.panel.g, c.panel.b, c.panel.a)
        end
        if f.fill and f.fill.SetVertexColor then
            f.fill:SetVertexColor(c.accent.r, c.accent.g, c.accent.b, c.accent.a)
        end
        if f.text then
            f.text:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
            ApplyFont(f.text, c, "small")
            -- The % sits over the bright accent fill; a light glyph on light gold
            -- washes out. OUTLINE + a dark shadow keep it readable over BOTH the
            -- fill and the dark track (which side the centred text lands on varies).
            local ff, fs = f.text:GetFont() -- exception(boundary): GetFont nil if ApplyFont set no font
            if ff then f.text:SetFont(ff, fs, "OUTLINE") end
            f.text:SetShadowColor(0, 0, 0, 0.9)
            f.text:SetShadowOffset(1, -1)
        end
    end,




    -- Nav header (expansion header in nav tree - marble bg + tooltip border)
    NavHeader = function(f, c)
        if f.SetBackdropColor then
            f:SetBackdropColor(c.panel.r, c.panel.g, c.panel.b, c.panel.a * 0.6)
            f:SetBackdropBorderColor(c.border.r, c.border.g, c.border.b, c.border.a * 0.8)
        end
        if f.arrow then f.arrow:SetTextColor(c.text.r, c.text.g, c.text.b) end
    end,

    -- Nav item (category row - selected bar + fill support)
    NavItem = function(f, c)
        local d = VWB.Constants:GetDerivedColors(c)
        if f._isSelected then
            if f.SetBackdropColor then f:SetBackdropColor(d.selected_fill.r, d.selected_fill.g, d.selected_fill.b, d.selected_fill.a) end
            if f.text then f.text:SetTextColor(c.text_header.r, c.text_header.g, c.text_header.b) end
            if f.selBar then f.selBar:SetVertexColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 1); f.selBar:Show() end
        else
            if f.SetBackdropColor then f:SetBackdropColor(0, 0, 0, 0) end
            if f.text then f.text:SetTextColor(c.text.r, c.text.g, c.text.b) end
            if f.selBar then f.selBar:Hide() end
        end
    end,



    -- Slider
    Slider = function(f, c)
        if f.label then
            f.label:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
            ApplyFont(f.label, c)
        end
        if f.valueText then
            f.valueText:SetTextColor(c.text.r, c.text.g, c.text.b, c.text.a)
            ApplyFont(f.valueText, c, "small")
        end
        local thumb = f.slider:GetThumbTexture() -- CreateSlider registers its container; the Slider widget is f.slider
        if thumb then
            thumb:SetVertexColor(c.accent.r, c.accent.g, c.accent.b, c.accent.a)
        end
    end,
}
