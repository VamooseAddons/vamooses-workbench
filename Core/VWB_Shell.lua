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

-- VWB.UI.BACKDROP_FLAT (Framework) is the canonical flat backdrop; local was a subset duplicate.
---@type backdropInfo
local FLAT = VWB.UI.BACKDROP_FLAT -- exception(false-positive): indirection loses type; value is backdropInfo

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


-- View registry: id -> label + builder + optional badge + subtitle.
--   badge    : function() -> number  live count; shown as a pill when > 0
--   subtitle : string  one-line descriptor shown in the nav row tooltip
-- Projects is TOP of the rail (the plan board -- the addon's hero surface).
-- Badge: below-par stock count from the projects slice.
local VIEWS = {
    { id = "projects",  text = "Projects",  subtitle = "Pin items and plan your collection",
      build = function(c) return ns.Projects.buildView(c) end,
      -- ACTIVE project count. The first cut counted below-par stock only
      -- ("needs attention" per the spec) -- live verdict 2026-07-11: the owner
      -- read "1" against 4 visible projects as a bug. A badge the owner
      -- misreads is the wrong badge; the needs-attention signal still lives in
      -- the board sort + par gauges.
      badge = function()
          ns.Store:Version("projects")
          local n = 0
          for _, p in ipairs(ns.Store:GetState().projects.items) do
              if not p.completedAt then n = n + 1 end
          end
          return n
      end },
    { id = "showroom",  text = "Showroom",  subtitle = "Browse craftable collectibles",
      build = function(c) return ns.Showroom.buildView(c) end,
      -- Global filter-independent count, live from window open (no mount needed)
      badge = function() return ns.Collectibles.UncollectedCount() end },
    { id = "workbench", text = "Workbench", subtitle = "Recipes, queue and materials",
      build = function(c) return ns.Recipes.buildView(c) end,
      badge = function()
          ns.Store:Version("crafting")
          return #ns.Store:GetState().crafting.queuedRecipes
      end },
    { id = "stockroom", text = "Stockroom", subtitle = "Raw materials ledger",
      build = function(c) return ns.Stockroom.buildView(c) end },
    { id = "ledger",    text = "Ledger",    subtitle = "Profit and AH pricing",
      build = function(c) return ns.Ledger.buildView(c) end },
    { id = "roster",    text = "Roster",    subtitle = "Your characters professions",
      build = function(c) return ns.Roster.buildView(c) end },
    { id = "records",   text = "Records",   subtitle = "Scan coverage and history",
      build = function(c) return ns.Records.buildView(c) end },
    { id = "settings",  text = "Settings",  subtitle = "Options",
      build = function(c) return ns.Settings.buildView(c) end },
    { id = "debug",     text = "Debug",     subtitle = "Developer diagnostics",
      build = function(c) return ns.Debug.buildView(c) end }, -- last: nav row hides when debug off (no gap)
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

-- Nav rows: clickable buttons with an active-highlight wash + label + badge. --
-- badge: right-aligned pill (hidden when count=0); colors match the gold active
-- highlight (warning color at reduced alpha) so it reads as part of the identity
-- system rather than a separate accent. badgeCount and badgePill are the two
-- sub-frames: count is the text; pill is the tinted backdrop behind it.
local function navMakeFrame(node, parent)
    if node.type ~= "item" then return CreateFrame("Frame", nil, parent) end
    local btn = CreateFrame("Button", nil, parent)
    local _d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
    local hl = btn:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(btn); hl:SetColorTexture(_d.selected_bar.r, _d.selected_bar.g, _d.selected_bar.b, 0.18); hl:Hide()
    btn.hl = hl
    btn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    btn:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 10, 0)
    fs:SetText(node.text or node.id)
    btn.label = fs
    -- badge pill: subtle count on the right edge; hidden when count is zero
    local pill = btn:CreateTexture(nil, "BACKGROUND")
    pill:SetSize(30, 14); pill:SetPoint("RIGHT", -4, 0)
    pill:SetColorTexture(_d.selected_bar.r, _d.selected_bar.g, _d.selected_bar.b, 0.22); pill:Hide()
    btn.badgePill = pill
    local bc = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bc:SetPoint("CENTER", pill, "CENTER", 0, 0)
    local _sb = _d.selected_bar
    bc:SetTextColor(_sb.r, _sb.g, _sb.b) -- scheme selection color readable on the pill
    btn.badgeCount = bc
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
    ns.Nav._setView = Shell.setView  -- late-bind Nav's view-switch hook
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
            VWB.Theme.epoch() -- theme epoch: selected_bar derives from scheme.warning which changes per theme
            if activeView() == v.id then
                local d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
                return d.selected_bar.r, d.selected_bar.g, d.selected_bar.b
            else
                return 0.72, 0.72, 0.76
            end
        end)
        -- badge: bind count + pill visibility if the registry entry carries a badge fn
        if v.badge then
            local badgeFn = v.badge
            R.bindText(btn.badgeCount, function()
                local n = badgeFn()
                if n <= 0 then return "" end
                if n >= 1000 then return string.format("%.1fk", n / 1000) end -- four digits burst the pill
                return tostring(n)
            end)
            R.bindShown(btn.badgePill, function() return badgeFn() > 0 end)
        end
        -- subtitle tooltip via the codebase's VWB.UI.Tooltip engine (same surface
        -- used by QueueRow hover -- Begin/AddLine/Show, Hide on leave)
        if v.subtitle then
            local sub = v.subtitle
            btn:SetScript("OnEnter", function(self)
                VWB.UI.Tooltip:Begin(self, "RIGHT")
                VWB.UI.Tooltip:AddTitle(v.text)
                VWB.UI.Tooltip:AddLine(sub)
                VWB.UI.Tooltip:Show()
            end)
            btn:SetScript("OnLeave", function(self)
                VWB.UI.Tooltip:Hide(self)
            end)
        end
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

    -- 5. Status bar -- three reactive segments on the status strip:
    --   [left label]  "N queued | scanned Xh ago"     <- plain text, left-aligned
    --   [mats button] "M mats short"                  <- clickable; navigates to Stockroom
    --   [delta label] "+N craftable since open"        <- shown only when delta > 0, right side
    --
    -- Baseline: the craftable count is captured the FIRST time the window opens
    -- (not at PLAYER_LOGIN -- no-login-work rule). A R.signal(nil) becomes a
    -- number on first Show; subsequent shows leave it in place (session-scoped).
    local craftableBaseline = R.signal(nil) -- exception(nullable): nil until first open; set once

    -- Helper: count how many queued recipes are craftable right now.
    -- ns.RecipeQuery is guaranteed post-init (openWindow only called after ADDON_LOADED).
    local function countCraftable(st)
        local n = 0
        for _, r in ipairs(st.crafting.queuedRecipes) do
            if ns.RecipeQuery:CanCraft(r.recipeID) then n = n + 1 end
        end
        return n
    end

    -- Capture baseline on first window open (this effect runs once; subsequent
    -- opens find baseline already set and return immediately)
    R.effect(function()
        if craftableBaseline() ~= nil then return end
        ns.Store:Version("crafting")
        craftableBaseline(countCraftable(ns.Store:GetState()))
    end, "shell:craftableBaseline")

    -- Left label: queued count + scan age (mats-short moved to its own button)
    R.bindText(status.label, function()
        ns.Store:Version("crafting")
        ns.Store:Version("corpus")
        local st = ns.Store:GetState()
        if not next(st.recipeStore) then return "" end -- nothing harvested yet
        local queued = #st.crafting.queuedRecipes
        local newest
        for _, entry in pairs(st.recipeCoverage) do
            if entry.lastScan and (not newest or entry.lastScan > newest) then newest = entry.lastScan end
        end
        return string.format("%d queued   |   %s", queued, VWB.UI:FormatScannedAgo(newest, time()))
    end)

    -- Mats-short clickable button: text underlines on hover; click = Nav.Go stockroom
    local matsBtn = CreateFrame("Button", nil, status)
    matsBtn:SetHeight(14)
    matsBtn:SetPoint("LEFT", status.label, "RIGHT", 12, 0)
    matsBtn:SetPoint("RIGHT", status, "CENTER", 0, 0) -- cap width at center
    local matsBtnFS = matsBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    matsBtnFS:SetAllPoints(); matsBtnFS:SetJustifyH("LEFT")
    matsBtn.fs = matsBtnFS
    VWB.Theme:Register(matsBtnFS, "DimLabel")

    R.bindText(matsBtnFS, function()
        ns.Store:Version("crafting")
        local st = ns.Store:GetState()
        if not next(st.recipeStore) then return "" end
        local short = 0
        for _, mat in ipairs(st.crafting.shoppingList) do
            if mat.missing > 0 then short = short + 1 end
        end
        if short == 0 then return "" end
        return short .. " mats short"
    end)
    R.bindShown(matsBtn, function()
        ns.Store:Version("crafting")
        local st = ns.Store:GetState()
        if not next(st.recipeStore) then return false end
        for _, mat in ipairs(st.crafting.shoppingList) do
            if mat.missing > 0 then return true end
        end
        return false
    end)
    matsBtn:SetScript("OnEnter", function(self)
        local c = VWB.UI:GetScheme()
        self.fs:SetTextColor(c.warning.r, c.warning.g, c.warning.b, 1) -- brighten to warning gold on hover
    end)
    matsBtn:SetScript("OnLeave", function(self)
        local c = VWB.UI:GetScheme()
        self.fs:SetTextColor(c.text.r, c.text.g, c.text.b, 0.6) -- return to dim
    end)
    matsBtn:SetScript("OnClick", function()
        ns.Nav.Go("stockroom", { filter = "queue" })
    end)

    -- Delta label: "+N craftable since open"; right-aligned; hidden when delta <= 0
    local deltaFS = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deltaFS:SetPoint("RIGHT", -8, 0)
    R.bindText(deltaFS, function()
        ns.Store:Version("crafting")
        local baseline = craftableBaseline()
        if baseline == nil then return "" end
        local current = countCraftable(ns.Store:GetState())
        local delta = current - baseline
        if delta <= 0 then return "" end
        local c = VWB.UI:GetScheme()
        return "|cFF" .. VWB.UI:ToHex(c.success) .. "+" .. delta .. " craftable since open|r"
    end)
    R.bindShown(deltaFS, function()
        ns.Store:Version("crafting")
        local baseline = craftableBaseline()
        if baseline == nil then return false end
        return countCraftable(ns.Store:GetState()) > baseline
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
