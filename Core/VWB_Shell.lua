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
        measureFS = h:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    end
    measureFS:SetText(node.text or node.id or node.role or "")
    return { w = measureFS:GetUnboundedStringWidth() + 6, h = 14 }
end


-- View registry: id -> label + builder + optional badge + subtitle.
--   badge    : function() -> number  live count; shown as a pill when > 0
--   subtitle : string  one-line descriptor shown in the nav row tooltip
-- Projects is TOP of the rail (the plan board -- the addon's hero surface).
-- Rail order groups by player intent (owner 2026-07-12): the daily loop
-- (plan -> craft -> mats), the three commission FEEDERS (browse -> commission
-- siblings, kept adjacent), passive reference, then meta. { header = "..." }
-- entries render as small-caps section labels over each block (HDG nav
-- treatment, owner 2026-07-13); { divider = true } stays a bare line (the
-- Settings/Debug meta block needs no name). Icons are wrath-era stable paths,
-- same style as Constants' profession icons.
local VIEWS = {
    { header = "Workshop" },
    { id = "projects",  text = "Commissions",  subtitle = "Pin items and plan your collection",
      icon = "Interface\\Icons\\INV_Scroll_03",
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
              if p.status == "bench" then n = n + 1 end -- Commissions v2: the badge is what you're WORKING ON, not the backlog
          end
          return n
      end },
    { id = "workbench", text = "Workbench", subtitle = "Recipes, queue and materials",
      icon = "Interface\\Icons\\Trade_BlackSmithing",
      build = function(c) return ns.Recipes.buildView(c) end,
      badge = function()
          ns.Store:Version("crafting")
          return #ns.Store:GetState().crafting.queuedRecipes
      end },
    { id = "stockroom", text = "Stockroom", subtitle = "Raw materials ledger",
      icon = "Interface\\Icons\\INV_Crate_01",
      build = function(c) return ns.Stockroom.buildView(c) end },
    { header = "Collection" },
    { id = "showroom",  text = "Showroom",  subtitle = "Browse craftable collectibles",
      icon = "Interface\\Icons\\INV_Chest_Cloth_04",
      build = function(c) return ns.Showroom.buildView(c) end,
      -- Global filter-independent count, live from window open (no mount needed)
      badge = function() return ns.Collectibles.UncollectedCount() end },
    { id = "study",     text = "Study",     subtitle = "Unlearned recipes and where to get them",
      icon = "Interface\\Icons\\INV_Misc_Book_09",
      build = function(c) return ns.Study.buildView(c) end },
    { id = "achieve",   text = "Achievements",   subtitle = "Profession achievements and progress",
      icon = "Interface\\Icons\\Achievement_Quests_Completed_08",
      build = function(c) return ns.Achieve.buildView(c) end },
    { header = "Books" },
    { id = "ledger",    text = "Ledger",    subtitle = "Profit and AH pricing",
      icon = "Interface\\Icons\\INV_Misc_Coin_02",
      build = function(c) return ns.Ledger.buildView(c) end },
    { id = "roster",    text = "Roster",    subtitle = "Your characters' professions",
      icon = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
      build = function(c) return ns.Roster.buildView(c) end },
    { id = "records",   text = "Records",   subtitle = "Scan coverage and history",
      icon = "Interface\\Icons\\INV_Misc_Note_02",
      build = function(c) return ns.Records.buildView(c) end },
    { divider = true },
    { id = "settings",  text = "Settings",  subtitle = "Options",
      icon = "Interface\\Icons\\Trade_Engineering",
      build = function(c) return ns.Settings.buildView(c) end },
    { id = "debug",     text = "Debug",     subtitle = "Developer diagnostics",
      icon = "Interface\\Icons\\INV_Misc_Wrench_01",
      build = function(c) return ns.Debug.buildView(c) end }, -- last: nav row hides when debug off (no gap)
}

-- Views only (no divider/header markers): the wiring/mount loops iterate this.
local VIEW_LIST = {}
for _, v in ipairs(VIEWS) do if v.id then VIEW_LIST[#VIEW_LIST + 1] = v end end

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
        local fs = f:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
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
    if node.role == "divider" then -- separator line between nav blocks
        local f = CreateFrame("Frame", nil, parent)
        local s = VWB.UI:GetScheme()
        local line = f:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("LEFT", 8, 0); line:SetPoint("RIGHT", -8, 0)
        line:SetColorTexture(s.border.r, s.border.g, s.border.b, 0.6)
        return f
    end
    if node.role == "navheader" then -- small-caps section label over a block
        local f = CreateFrame("Frame", nil, parent)
        local fs = f:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
        fs:SetPoint("BOTTOMLEFT", 8, 3)
        fs:SetText(string.upper(node.text))
        f.label = fs
        return f
    end
    local btn = CreateFrame("Button", nil, parent)
    local _d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
    local hl = btn:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(btn); hl:SetColorTexture(_d.selected_bar.r, _d.selected_bar.g, _d.selected_bar.b, 0.18); hl:Hide()
    btn.hl = hl
    -- accent spine: 3px selection bar on the left edge (HDG nav treatment)
    local spine = btn:CreateTexture(nil, "ARTWORK")
    spine:SetWidth(3)
    spine:SetPoint("TOPLEFT", 0, 0); spine:SetPoint("BOTTOMLEFT", 0, 0)
    spine:SetColorTexture(_d.selected_bar.r, _d.selected_bar.g, _d.selected_bar.b, 1)
    spine:Hide()
    btn.spine = spine
    btn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    btn:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
    if node.icon then
        local ic = btn:CreateTexture(nil, "ARTWORK")
        ic:SetSize(16, 16); ic:SetPoint("LEFT", 9, 0)
        ic:SetTexture(node.icon)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the baked icon border
        btn.icon = ic
    end
    local fs = btn:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
    fs:SetPoint("LEFT", node.icon and 31 or 10, 0)
    fs:SetText(node.text or node.id)
    btn.label = fs
    -- badge pill: subtle count on the right edge; hidden when count is zero
    local pill = btn:CreateTexture(nil, "BACKGROUND")
    pill:SetSize(30, 14); pill:SetPoint("RIGHT", -4, 0)
    pill:SetColorTexture(_d.selected_bar.r, _d.selected_bar.g, _d.selected_bar.b, 0.22); pill:Hide()
    btn.badgePill = pill
    local bc = btn:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
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
    win:SetSize(1340, 740); win:SetPoint("CENTER")
    -- Window handling, HDG parity (owner 2026-07-13): MEDIUM strata so the
    -- Workbench layers as a PEER to the character sheet / housing editor /
    -- other addon windows instead of covering them (HIGH did); SetToplevel
    -- still pops it to the front of its strata on click. Clamping keeps the
    -- title bar grabbable while allowing drags off the left/right/bottom.
    win:SetFrameStrata("MEDIUM")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetClampRectInsets(500, -500, 0, 500)
    -- Escape closes the window; every other key propagates untouched so
    -- gameplay keybinds and editbox typing are unaffected (a focused EditBox
    -- consumes Escape itself; the New Commission overlay's own handler --
    -- a child at a higher frame level -- eats Escape first while it's open).
    win:EnableKeyboard(true)
    win:SetPropagateKeyboardInput(true)
    win:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    -- Flat 1px edge, same as every inner panel (owner 2026-07-13: the beveled
    -- UI-Tooltip-Border texture has baked highlights, so the identical border
    -- color rendered visibly lighter on the window than on the panels).
    win:SetBackdrop(VWB.Theme.BACKDROP_FLAT)
    win:SetBackdropColor(s.bg.r, s.bg.g, s.bg.b, 0.97); win:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, 1)
    win:EnableMouse(true); win:SetMovable(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)

    -- Title-bar brand, left-justified (owner 2026-07-13): Madailein's logo
    -- leads, Boggle's wordmark follows. Wordmark is 1423x194 art on a
    -- 2048x256 pot canvas, texcoord-cropped, drawn at native aspect. NOT
    -- win.title -- the Frame skinner's title re-color path expects a
    -- FontString; art is theme-independent.
    local brandLogo = win:CreateTexture(nil, "OVERLAY")
    brandLogo:SetTexture("Interface\\AddOns\\VamoosesWorkbench\\textures\\Vamoose_VWB_400")
    brandLogo:SetSize(24, 24)
    brandLogo:SetPoint("TOPLEFT", 8, -4)
    local title = win:CreateTexture(nil, "OVERLAY")
    title:SetTexture("Interface\\AddOns\\VamoosesWorkbench\\textures\\workbench_title")
    title:SetTexCoord(0, 1423 / 2048, 0, 194 / 256)
    title:SetSize(191, 26) -- 1423x194 art at native aspect
    title:SetPoint("LEFT", brandLogo, "RIGHT", 6, 0)
    -- HDG's close treatment (owner 2026-07-13): bare square button with the
    -- XMarksTheSpot atlas, dim at rest / header-bright on hover -- not
    -- Blizzard's red UIPanelCloseButton circle.
    local close = CreateFrame("Button", nil, win)
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -6, -6)
    local closeIcon = close:CreateTexture(nil, "ARTWORK")
    closeIcon:SetSize(14, 14)
    closeIcon:SetPoint("CENTER")
    closeIcon:SetAtlas("XMarksTheSpot")
    close.icon = closeIcon
    close:SetScript("OnClick", function() win:Hide() end)
    close:SetScript("OnEnter", function(self)
        local c = VWB.UI:GetScheme()
        self.icon:SetVertexColor(c.text_header.r, c.text_header.g, c.text_header.b, 1)
    end)
    close:SetScript("OnLeave", function(self)
        local c = VWB.UI:GetScheme()
        self.icon:SetVertexColor(c.text.r, c.text.g, c.text.b, 1)
    end)
    VWB.Theme:Register(close, "CloseX")

    -- HDG launcher (tester request, reganart test1): top right, next to the
    -- close button. Gated on the companion addon being installed AND loaded
    -- -- the logo texture lives in HDG's own folder, so no HDG = no file =
    -- no icon; the button is simply never built.
    if C_AddOns.IsAddOnLoaded("HousingDecorGuide") then -- exception(boundary): optional companion addon
        local hdgBtn = CreateFrame("Button", nil, win)
        hdgBtn:SetSize(20, 20)
        hdgBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
        local logo = hdgBtn:CreateTexture(nil, "ARTWORK")
        logo:SetAllPoints()
        logo:SetTexture("Interface\\AddOns\\HousingDecorGuide\\textures\\Vamoose_HDG_400_trans")
        logo:SetAlpha(0.75)
        hdgBtn:SetScript("OnClick", function()
            _G.HDG:ToggleMainWindow() -- exception(boundary): cross-addon global; existence guaranteed by the gate above
        end)
        hdgBtn:SetScript("OnEnter", function(self)
            logo:SetAlpha(1)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:SetText("Housing Decor Guide")
            GameTooltip:Show()
        end)
        hdgBtn:SetScript("OnLeave", function()
            logo:SetAlpha(0.75)
            GameTooltip:Hide()
        end)
        win.hdgBtn = hdgBtn
    end

    -- 4px window margin + 32px title band (spacing pass 2026-07-13: was
    -- 10/-34 -- double HDG's edge margins; wordmark needs 32, close sits -4)
    local content = CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", 4, -32); content:SetSize(1332, 704)

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
    for _, v in ipairs(VIEW_LIST) do if v.id == persisted then known = true break end end
    local activeView = R.signal(known and persisted or VIEW_LIST[1].id) -- fall back if the persisted id was retired
    Shell.setView = function(id) activeView(id) end
    ns.Nav._setView = Shell.setView  -- late-bind Nav's view-switch hook
    R.effect(function() if VWB_DB then VWB_DB.activeView = activeView() end end)

    -- 3. sidebar nav generated from the registry (headers/dividers between blocks)
    local navChildren = {}
    for i, v in ipairs(VIEWS) do
        if v.header then
            navChildren[#navChildren + 1] = { type = "item", id = "navhdr:" .. i, role = "navheader", text = v.header, size = { h = i == 1 and 16 or 22 } }
        elseif v.divider then
            navChildren[#navChildren + 1] = { type = "item", id = "navdiv:" .. i, role = "divider", size = { h = 7 } }
        else
            navChildren[#navChildren + 1] = { type = "item", id = "nav:" .. v.id, role = "label", text = v.text, icon = v.icon, size = { h = 30 } }
        end
    end
    local nav = ns.Layout.build(sidebar,
        { type = "stack", dir = "col", gap = "xs", padding = "sm", align = "stretch", children = navChildren },
        { makeFrame = navMakeFrame, measure = measure })
    -- section headers: dim theme-tracked labels (same epoch read as the rows)
    for i, v in ipairs(VIEWS) do
        if v.header then
            R.bindColor(nav.byId["navhdr:" .. i].label, function()
                VWB.Theme.epoch()
                local c = VWB.UI:GetScheme().text
                return c.r, c.g, c.b
            end)
        end
    end
    for _, v in ipairs(VIEW_LIST) do
        local btn = nav.byId["nav:" .. v.id]
        btn:SetScript("OnClick", function() activeView(v.id) end)
        R.bindShown(btn.hl, function() return activeView() == v.id end)
        R.bindShown(btn.spine, function() return activeView() == v.id end)
        if btn.icon then
            -- active row's icon in full color; the rest desaturate to keep the
            -- rail quiet (HDG nav treatment)
            R.effect(function()
                local active = activeView() == v.id
                btn.icon:SetDesaturated(not active)
                btn.icon:SetAlpha(active and 1 or 0.65)
            end)
        end
        R.bindColor(btn.label, function()
            VWB.Theme.epoch() -- theme epoch: selected_bar derives from scheme.warning which changes per theme
            if activeView() == v.id then
                local d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
                return d.selected_bar.r, d.selected_bar.g, d.selected_bar.b
            else
                return 0.72, 0.72, 0.76
            end
        end)
        -- badge: bind count + pill visibility if the registry entry carries a badge fn.
        -- Wrap badgeFn in a named computed so a single recompute feeds both bindText
        -- and bindShown (avoids calling badgeFn twice per reactive flush).
        if v.badge then
            local badgeMemo = R.named("shell:badge:" .. v.id, v.badge)
            R.bindText(btn.badgeCount, function()
                local n = badgeMemo()
                if n <= 0 then return "" end
                if n >= 1000 then return string.format("%.1fk", n / 1000) end -- four digits burst the pill
                return tostring(n)
            end)
            R.bindShown(btn.badgePill, function() return badgeMemo() > 0 end)
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
    for _, v in ipairs(VIEW_LIST) do viewById[v.id] = v end
    local mounted, shownId = {}, nil
    -- Per-view status contributors: a view's build() may return handle.status,
    -- a reactive fn -> its bottom-rail summary string. Captured at lazy-mount;
    -- statusEpoch bumps so the status bind re-runs once a newly-mounted view
    -- registers its fn (avoids effect-ordering fragility on first switch).
    local viewStatus = {}
    local statusEpoch = R.signal(0)
    R.effect(function()
        local id = activeView()
        if shownId == id then return end
        if shownId and mounted[shownId] then mounted[shownId]:Hide() end
        if not mounted[id] then
            local h = viewById[id].build(contentHost)
            mounted[id] = h.root
            viewStatus[id] = h.status -- exception(nullable): Settings/Debug carry no status fn
            statusEpoch(statusEpoch() + 1)
        end
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

    -- Named computed: count how many queued recipes are craftable right now.
    -- Subscribes Version("crafting") so it recomputes when the queue changes.
    -- Both the baseline-capture effect and the delta bindText/bindShown read this
    -- single computed, avoiding the double O(queue) CanCraft scan per flush.
    local craftableCount = R.named("shell:craftableCount", function()
        ns.Store:Version("crafting")
        local st = ns.Store:GetState()
        local n = 0
        for _, r in ipairs(st.crafting.queuedRecipes) do
            if ns.RecipeQuery:CanCraft(r.recipeID) then n = n + 1 end
        end
        return n
    end)

    -- Capture baseline on first window open (this effect runs once; subsequent
    -- opens find baseline already set and return immediately)
    R.effect(function()
        if craftableBaseline() ~= nil then return end
        craftableBaseline(craftableCount())
    end, "shell:craftableBaseline")

    -- Transient flash channel: reducers/views fire VWB_STATUS_FLASH { text,
    -- seconds } on notable actions ("Commission added: X", "Scan complete: N
    -- new"); the left label shows it for `seconds`, then reverts to the active
    -- view's summary. Token guards against an older flash clearing a newer one.
    local flashText = R.signal(nil)
    local flashToken = 0
    ns.EventBus:Register("VWB_STATUS_FLASH", function(p)
        if not (p and p.text) then return end -- exception(boundary): malformed payload
        flashToken = flashToken + 1
        local mine = flashToken
        flashText(p.text)
        VWB.ReactorWoW.after(p.seconds or 4, function()
            if flashToken == mine then flashText(nil) end -- boundary write: timer clears its own flash unless superseded
        end)
    end)
    -- Harvest completion is one event carrying the new-recipe count -> one
    -- flash (per-profession VWB_RECIPES_SCANNED would storm during a full scan).
    ns.EventBus:Register("VWB_HARVEST_PROGRESS", function(p)
        if not (p and p.phase == "complete") then return end
        local n = p.newCount or 0
        local text = n > 0 and string.format("Scan complete: %d new recipes", n)
            or string.format("Scan complete: %d recipes seen", p.recipesSeen or 0)
        VWB.EventBus:Trigger("VWB_STATUS_FLASH", { text = text })
    end)

    -- Left label: a transient flash if one is live, else the ACTIVE view's own
    -- summary (handle.status). Settings/Debug carry no status fn -> blank rail.
    R.bindText(status.label, function()
        local flash = flashText()
        if flash then return VWB.UI:ColorCode("cyan") .. flash .. "|r" end
        statusEpoch() -- dep: re-run when a lazy view mounts and registers its fn
        local fn = viewStatus[activeView()]
        return fn and fn() or "" -- fn() reads the view's own signals -> live updates
    end)

    -- Mats-short clickable button: text underlines on hover; click = Nav.Go stockroom
    local matsBtn = CreateFrame("Button", nil, status)
    matsBtn:SetHeight(14)
    matsBtn:SetPoint("LEFT", status.label, "RIGHT", 12, 0)
    matsBtn:SetPoint("RIGHT", status, "CENTER", 0, 0) -- cap width at center
    local matsBtnFS = matsBtn:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
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
        -- mats-short is scoped to the crafting views (owner 2026-07-13): a
        -- shortfall is only actionable from Workbench/Stockroom, so it no
        -- longer competes with other views' per-view summaries.
        local v = activeView()
        if v ~= "workbench" and v ~= "stockroom" then return false end
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

    -- Delta label: "+N craftable since open"; right-aligned; hidden when delta <= 0.
    -- Both effects read craftableCount() (the named computed above) so the O(queue)
    -- CanCraft scan runs once per flush, not twice.
    local deltaFS = status:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    deltaFS:SetPoint("RIGHT", -8, 0)
    R.bindText(deltaFS, function()
        local baseline = craftableBaseline()
        if baseline == nil then return "" end
        local delta = craftableCount() - baseline
        if delta <= 0 then return "" end
        local c = VWB.UI:GetScheme()
        return "|cFF" .. VWB.UI:ToHex(c.success) .. "+" .. delta .. " craftable since open|r"
    end)
    R.bindShown(deltaFS, function()
        local baseline = craftableBaseline()
        if baseline == nil then return false end
        return craftableCount() > baseline
    end)

    -- 6. Craft-complete toast (ported from VPC): a brief fading "Crafted Nx <item>"
    -- banner over the content area. KnownRecipes fires VWB_CRAFT_COMPLETE on
    -- TRADE_SKILL_ITEM_CRAFTED_RESULT. No C_Timer -- an Alpha group holds then fades.
    local toast = CreateFrame("Frame", nil, win)
    toast:SetPoint("TOP", contentHost, "TOP", 0, -12)
    toast:SetSize(400, 24)
    toast:Hide()
    local toastFS = toast:CreateFontString(nil, "OVERLAY", "VWBFontNormalLarge")
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

    -- Option F: pre-build-on-idle. After the window is FIRST shown, schedule
    -- background mounts for the two heaviest cold-start views (Workbench then
    -- Showroom) one frame apart so the open-frame itself isn't burdened.
    -- Guard: runs once per session (Shell._preBuildDone). Reuses the existing
    -- mounted[] table and viewById.build() so it's idempotent: if the user
    -- navigates to either view before the timer fires, mount already happened and
    -- the scheduled callback is a no-op. Pre-built views are left HIDDEN.
    local preBuildDone = false
    local origShow = win.Show
    win.Show = function(self)
        origShow(self)
        if not preBuildDone then
            preBuildDone = true
            Shell.RunFirstOpenHooks() -- Constitution R6: deferred pipeline work wakes HERE
            VWB.ReactorWoW.after(0.05, function()
                if not mounted["workbench"] then
                    mounted["workbench"] = viewById["workbench"].build(contentHost).root
                    -- CreateFrame roots default SHOWN; only the switch effect's
                    -- Show() may reveal a view -- hide the pre-built root or it
                    -- stacks over the active view.
                    mounted["workbench"]:Hide()
                end
                VWB.ReactorWoW.after(0.05, function()
                    if not mounted["showroom"] then
                        mounted["showroom"] = viewById["showroom"].build(contentHost).root
                        mounted["showroom"]:Hide()
                    end
                end)
            end)
        end
    end

    Shell._win = win
    return win
end

-- ============================================================================
-- Constitution R6 wake registry ("all work defers to window open" -- iron,
-- owner ruling 2026-07-11). Modules register their Hydrate under this; login
-- lifecycle does registrations only, and the queued work runs exactly once,
-- at the first win:Show(). Registering after the window already opened runs
-- the hook immediately (idempotent wake).
-- ============================================================================
local firstOpenHooks, firstOpenDone = {}, false
function Shell.WhenFirstOpen(fn)
    if firstOpenDone then fn(); return end
    firstOpenHooks[#firstOpenHooks + 1] = fn
end
function Shell.RunFirstOpenHooks()
    if firstOpenDone then return end
    firstOpenDone = true
    for i = 1, #firstOpenHooks do firstOpenHooks[i]() end
    firstOpenHooks = {}
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
