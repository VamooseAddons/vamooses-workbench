-- ============================================================================
-- VWB Shell - the app-shell controller: window + sidebar nav + view switching.
-- ============================================================================
-- Builds the shell chrome (LayoutConfig.shell), generates the sidebar nav from
-- the VIEW registry, builds every view ONCE into the content host, and swaps
-- them with a single reactive rule: bindShown(viewRoot, activeView == id). The
-- active view persists across /reload via VWB_DB.activeView (HDG's
-- UI_SET_PERSISTENT pattern, one signal here). Adding a real view later = add a
-- registry entry + its LayoutConfig; the nav row and swap wire up for free.
-- ============================================================================

local _, ns = ...
local R = ns.Reactor
local Shell = {}
ns.Shell = Shell

local FLAT = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }

-- Shared natural-width measure for hug sizing.
local measureFS
local function measure(node)
    if not measureFS then
        local h = CreateFrame("Frame"); h:Hide()
        measureFS = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    end
    measureFS:SetText(node.text or node.id or node.role or "")
    return { w = measureFS:GetUnboundedStringWidth() + 6, h = 14 }
end


-- View registry: id -> label + a builder that mounts the view into a container
-- and returns its Layout.build handle (.root is what we show/hide). Showroom is
-- real; Workbench is a themed layout skeleton (3-panel, ported from VPC Recipes);
-- the rest are stubs until their views land.
local VIEWS = {
    { id = "showroom",  text = "Showroom",  build = function(c) return ns.Showroom.buildView(c) end },
    { id = "workbench", text = "Workbench", build = function(c) return ns.Recipes.buildView(c) end },
    { id = "stockroom", text = "Stockroom", build = function(c) return ns.Stockroom.buildView(c) end },
    { id = "ledger",    text = "Ledger",    build = function(c) return ns.Ledger.buildView(c) end },
    { id = "roster",    text = "Roster",    build = function(c) return ns.Roster.buildView(c) end },
    { id = "records",   text = "Records",   build = function(c) return ns.Records.buildView(c) end },
    { id = "settings",  text = "Settings",  build = function(c) return ns.Settings.buildView(c) end },
    { id = "debug",     text = "Debug",     build = function(c) return ns.Debug.buildView(c) end }, -- last: nav row hides when debug off (no gap)
}

-- Shell chrome frames (sidebar / content / status), themed from the scheme. ---
local function shellMakeFrame(node, parent)
    if node.type ~= "item" then return CreateFrame("Frame", nil, parent) end
    local s = VWB.UI:GetScheme()
    if node.id == "sidebar" then
        local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        f:SetBackdrop(FLAT); f:SetBackdropColor(s.panel.r, s.panel.g, s.panel.b, s.panel.a)
        f:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, s.border.a)
        return f
    elseif node.id == "status" then
        local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        f:SetBackdrop(FLAT); f:SetBackdropColor(s.bg.r, s.bg.g, s.bg.b, s.bg.a)
        f:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, s.border.a)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", 8, 0); fs:SetTextColor(s.text.r, s.text.g, s.text.b)
        f.label = fs
        return f
    end
    return CreateFrame("Frame", nil, parent) -- content
end

-- Nav rows: clickable buttons with an active-highlight wash + label. ---------
local function navMakeFrame(node, parent)
    if node.type ~= "item" then return CreateFrame("Frame", nil, parent) end
    local btn = CreateFrame("Button", nil, parent)
    local hl = btn:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(btn); hl:SetColorTexture(1, 0.82, 0, 0.18); hl:Hide()
    btn.hl = hl
    btn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    btn:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 10, 0)
    fs:SetText(node.text or node.id)
    btn.label = fs
    return btn
end

function Shell.openWindow()
    if Shell._win then Shell._win:Show(); return Shell._win end

    local s = VWB.UI:GetScheme()
    local win = CreateFrame("Frame", "VWB_Main", UIParent, "BackdropTemplate")
    win:SetSize(1340, 740); win:SetPoint("CENTER"); win:SetFrameStrata("HIGH")
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    win:SetBackdropColor(s.bg.r, s.bg.g, s.bg.b, 0.97); win:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, 1)
    win:EnableMouse(true); win:SetMovable(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -9); title:SetText("Vamoose's Workbench")
    title:SetTextColor(s.text_header.r, s.text_header.g, s.text_header.b)
    win.title = title -- so the Frame skinner re-colors the title on a theme switch
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local content = CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", 10, -34); content:SetSize(1320, 700)

    -- 1. shell chrome
    local shell = ns.Layout.build(content, ns.LayoutConfig.shell, { makeFrame = shellMakeFrame, measure = measure })
    local sidebar, contentHost, status = shell.byId.sidebar, shell.byId.content, shell.byId.status

    -- Register the shell chrome with the theme engine. Previously these frames
    -- read GetScheme() ONCE at build time and froze those colors, so Theme:UpdateAll
    -- on a theme switch re-skinned the (registered) view panels but left the shell
    -- behind -- dark chrome around light content. Reusing Frame/Panel/DimLabel means
    -- the shell tracks the exact same scheme the view panels do.
    VWB.Theme:Register(win, "Frame")
    VWB.Theme:Register(sidebar, "Panel")
    VWB.Theme:Register(status, "Panel")
    VWB.Theme:Register(status.label, "DimLabel")

    -- 2. active-view signal, persisted across reloads
    local persisted = VWB_DB and VWB_DB.activeView
    local known = false
    for _, v in ipairs(VIEWS) do if v.id == persisted then known = true break end end
    local activeView = R.signal(known and persisted or VIEWS[1].id) -- fall back if the persisted id was retired
    Shell.setView = function(id) activeView(id) end
    R.effect(function() if VWB_DB then VWB_DB.activeView = activeView() end end)

    -- 3. sidebar nav generated from the registry
    local navChildren = {}
    for _, v in ipairs(VIEWS) do
        navChildren[#navChildren + 1] = { type = "item", id = "nav:" .. v.id, role = "label", text = v.text, size = { h = 30 } }
    end
    local nav = ns.Layout.build(sidebar,
        { type = "stack", dir = "col", gap = "xs", padding = "sm", align = "stretch", children = navChildren },
        { makeFrame = navMakeFrame, measure = measure })
    for _, v in ipairs(VIEWS) do
        local btn = nav.byId["nav:" .. v.id]
        btn:SetScript("OnClick", function() activeView(v.id) end)
        R.bindShown(btn.hl, function() return activeView() == v.id end)
        R.bindColor(btn.label, function()
            if activeView() == v.id then return 1, 0.82, 0 else return 0.72, 0.72, 0.76 end
        end)
    end

    -- The Debug tab is dev-only: its nav row shows only while debug is on. It's
    -- the last row, so hiding it never opens a gap between the others.
    R.bindShown(nav.byId["nav:debug"], function()
        ns.Store:Version("config")
        return ns.Store:GetState().config.debug and true or false
    end)

    -- 4. Views are LAZY-mounted: a view is built into the content host on FIRST
    -- navigation to it (not all 7 at open -> no 7-view cold-cache request storm
    -- at startup), then cached and toggled by visibility. A view the user never
    -- opens never builds. (Full per-dispatch scoping of hidden-but-visited views
    -- rides on the per-slice Store signals -- views subscribe their own slice.)
    local viewById = {}
    for _, v in ipairs(VIEWS) do viewById[v.id] = v end
    local mounted, shownId = {}, nil
    R.effect(function()
        local id = activeView()
        if shownId == id then return end
        if shownId and mounted[shownId] then mounted[shownId]:Hide() end
        if not mounted[id] then mounted[id] = viewById[id].build(contentHost).root end
        mounted[id]:Show()
        shownId = id
    end, "shell:activeView")

    -- 5. Foreman ticker (ported from VPC): "N queued | M mats short | scanned Xh
    -- ago". Reactive on the crafting + corpus slices -- no polling timer; the
    -- next dispatch refreshes it (matching VPC's dispatcher-driven update).
    R.bindText(status.label, function()
        ns.Store:Version("crafting")
        ns.Store:Version("corpus")
        local st = ns.Store:GetState()
        if not next(st.recipeStore) then return "" end -- nothing harvested yet
        local queued = #st.crafting.queuedRecipes
        local short = 0
        for _, mat in ipairs(st.crafting.shoppingList) do
            if mat.missing > 0 then short = short + 1 end
        end
        local newest
        for _, entry in pairs(st.recipeCoverage) do
            if entry.lastScan and (not newest or entry.lastScan > newest) then newest = entry.lastScan end
        end
        return string.format("%d queued   |   %d mats short   |   %s",
            queued, short, VWB.UI:FormatScannedAgo(newest, time()))
    end)

    -- 6. Craft-complete toast (ported from VPC): a brief fading "Crafted Nx <item>"
    -- banner over the content area. KnownRecipes fires VWB_CRAFT_COMPLETE on
    -- TRADE_SKILL_ITEM_CRAFTED_RESULT. No C_Timer -- an Alpha group holds then fades.
    local toast = CreateFrame("Frame", nil, win)
    toast:SetPoint("TOP", contentHost, "TOP", 0, -12)
    toast:SetSize(400, 24)
    toast:Hide()
    local toastFS = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    toastFS:SetAllPoints()
    toastFS:SetJustifyH("CENTER")
    local fade = toast:CreateAnimationGroup()
    local hold = fade:CreateAnimation("Alpha"); hold:SetFromAlpha(1); hold:SetToAlpha(1); hold:SetDuration(2); hold:SetOrder(1)
    local out = fade:CreateAnimation("Alpha"); out:SetFromAlpha(1); out:SetToAlpha(0); out:SetDuration(1); out:SetOrder(2)
    fade:SetScript("OnFinished", function() toast:Hide() end)
    ns.EventBus:Register("VWB_CRAFT_COMPLETE", function(p)
        local qty = (p.qty and p.qty > 1) and (p.qty .. "x ") or ""
        toastFS:SetText(VWB.UI:ColorCode("green") .. "Crafted " .. qty .. (p.name or "item") .. "|r")
        toast:SetAlpha(1); toast:Show()
        fade:Stop(); fade:Play()
    end)

    Shell._win = win
    return win
end

-- Entry-point adapters for ported code that expects VPC's VWB:ToggleWindow /
-- VWB:ShowPage(pageId) (e.g. the minimap button). VPC page ids map to VWB view
-- ids where they differ ("data" -> "records").
function ns:ToggleWindow()
    if Shell._win and Shell._win:IsShown() then Shell._win:Hide(); return end
    Shell.openWindow():Show()
end
function ns:ShowPage(pageId)
    Shell.openWindow():Show()
    if Shell.setView then Shell.setView(pageId == "data" and "records" or pageId) end
end

return Shell
