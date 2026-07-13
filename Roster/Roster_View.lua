-- ============================================================================
-- VWB Roster (Alts) - VIEW / controller. Slice: characters from account data.
-- ============================================================================
-- VPC Alts-tab parity pass: account.characters (written by the harvest's
-- SAVE_CHARACTER_PROFESSIONS as you open professions on each alt) rendered as
-- three pieces sharing the single "rosGrid" layout node (no new LayoutConfig
-- nodes needed -- see the build report for a proposed future split):
--   1. a horizontal strip of CreateCharStatCard cards (current character
--      sorted first, class-colored, click -> SET_SCOPE), each with a
--      CreateProgressBar "mastery" bar (sum current / sum max across every
--      scanned skill) and a hover tooltip with that character's full
--      profession x expansion skill breakdown.
--   2. an Account Summary grid (CreateVirtualizedList, one row per profession,
--      one column per expansion showing the account-wide BEST current/max);
--      hovering a row paints its per-expansion breakdown (+ who holds each
--      best) into the inspector panel below the grid -- sticky, not a tooltip.
--   3. an empty state when no character has been scanned yet.
-- Both lists re-derive off Store:Version("characters") ONLY -- a queue/config
-- dispatch elsewhere never touches this view.
-- ============================================================================

local _, ns = ...
local Roster = ns.Roster or {}
ns.Roster = Roster

local ED = VWB.Data.ExpansionData

-- ============================================================================
-- StaticPopup: remove a character from the roster (tester request).
-- OnAccept's second arg = StaticPopup_Show's FOURTH arg (the data param).
-- ============================================================================
StaticPopupDialogs["VWB_REMOVE_CHARACTER"] = {
    text = "Remove %s from the roster?\nA profession scan on that character will re-add them.",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self, data)
        ns.Store:Dispatch("REMOVE_CHARACTER", { charKey = data })
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Card strip sizing -- CARD_W/CARD_H must match VWB.UI:CreateCharStatCard's
-- own internal SetSize(220, 58) (kept separate per this addon's factory
-- convention; the card sizes itself, this is just for the wrapper + bar).
local CARD_W, CARD_H = 220, 58
local CARD_GAP = 6
local BAR_H, BAR_GAP = 8, 4
local STRIP_HEIGHT = CARD_H + BAR_GAP + BAR_H + 6

local PROF_COL_WIDTH = 110
local EXP_COL_WIDTH = 55

-- ============================================================================
-- Account Summary row (pooled by CreateVirtualizedList; one row per profession)
-- ============================================================================

local function summaryRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16); icon:SetPoint("LEFT", 4, 0)
    frame.icon = icon

    local name = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 4, 0); name:SetWidth(PROF_COL_WIDTH - 24); name:SetJustifyH("LEFT")
    frame.name = name

    frame.cells = {}
    local x = PROF_COL_WIDTH + 8
    for i = 1, #ED.EXPANSION_ORDER do
        local cell = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
        cell:SetPoint("LEFT", x, 0); cell:SetWidth(EXP_COL_WIDTH); cell:SetJustifyH("CENTER")
        frame.cells[i] = cell
        x = x + EXP_COL_WIDTH
    end
end

-- scopedHasProfession: true when the scoped character holds any expansion slot
-- for this profession row (drives name gold + per-cell gold highlight).
local function scopedHasProfession(item)
    if not item.scopedChar then return false end
    for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local best = item.best[expInfo.display]
        if best and best.charKey == item.scopedChar then return true end
    end
    return false
end

local function paintSummaryRow(row, item)
    row.data = item
    row.icon:SetTexture(item.icon)
    row.name:SetText(item.profName)
    local s = VWB.UI:GetScheme()
    local d = VWB.Constants:GetDerivedColors(s)
    local scopedOwns = scopedHasProfession(item)
    -- Gold name when the scoped character has this profession at any expansion.
    if scopedOwns then
        row.name:SetTextColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b)
    else
        row.name:SetTextColor(s.text_header.r, s.text_header.g, s.text_header.b)
    end
    for i, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local best = item.best[expInfo.display]
        if i == 1 and not best then best = item.best.Overall end -- flat-skill profs (Archaeology): single value, first column
        local cell = row.cells[i]
        if best then
            -- Gold cell when the scoped character holds this expansion's best.
            if item.scopedChar and best.charKey == item.scopedChar then
                cell:SetTextColor(1, 1, 1) -- reset tail color
                cell:SetText(string.format("|cFF%s%d|r/%d", VWB.UI:ToHex(d.selected_bar), best.current, best.max))
            else
                local color = (best.current >= best.max) and s.success or s.accent
                cell:SetTextColor(1, 1, 1) -- reset: the "/max" tail after |r falls back to this, not a stale dim-gray from a prior "-" paint of this pooled cell
                cell:SetText(string.format("|cFF%s%d|r/%d", VWB.UI:ToHex(color), best.current, best.max))
            end
        else
            cell:SetText("-")
            cell:SetTextColor(s.text.r, s.text.g, s.text.b)
        end
    end
end

-- Row-level hover paints the profession's per-expansion breakdown into the
-- inspector panel UNDER the summary grid (owner 2026-07-13: the old row
-- tooltip was a wall of data floating over dead space that could hold it).
-- Sticky: the last-hovered profession stays up for reading; nothing clears
-- on mouse-leave.
local DETAIL_ROW_H = 16

local function createDetailRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(DETAIL_ROW_H)
    row.exp = row:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    row.exp:SetPoint("LEFT", 10, 0); row.exp:SetWidth(170); row.exp:SetJustifyH("LEFT")
    row.val = row:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    row.val:SetPoint("LEFT", 186, 0); row.val:SetWidth(80); row.val:SetJustifyH("LEFT")
    row.who = row:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    row.who:SetPoint("LEFT", 272, 0); row.who:SetPoint("RIGHT", -8, 0); row.who:SetJustifyH("LEFT")
    return row
end

-- Static expansion column header (built once; no per-frame data, never repainted).
local function buildExpansionHeader(parent)
    local hdr = CreateFrame("Frame", nil, parent)
    local profLabel = hdr:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    profLabel:SetPoint("LEFT", 4, 0); profLabel:SetWidth(PROF_COL_WIDTH); profLabel:SetJustifyH("LEFT")
    profLabel:SetText("Profession")

    local x = PROF_COL_WIDTH + 8
    for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local lbl = hdr:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
        lbl:SetPoint("LEFT", x, 0); lbl:SetWidth(EXP_COL_WIDTH); lbl:SetJustifyH("CENTER")
        lbl:SetText(expInfo.abbr)
        lbl:SetTextColor(expInfo.color.r, expInfo.color.g, expInfo.color.b)
        x = x + EXP_COL_WIDTH
    end
    return hdr
end

-- ============================================================================
-- Character strip card (pooled via VWB.UI:AcquireRow; CreateCharStatCard +
-- a mastery CreateProgressBar underneath).
-- ============================================================================

-- Concise per-character summary: one line per profession (name + mastery %),
-- plus a compact "behind:" line naming only the expansions still short of max.
-- The full per-expansion grid lives in the Account Summary below -- the old
-- tooltip duplicated it and ran off the bottom of the screen.
-- Appends a "Scanned <ago>" staleness line so a 3-week-old snapshot is
-- distinguishable from this morning's (playtester request, item 1).
local function characterTooltipBody(entry)
    local _d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
    GameTooltip:AddLine(entry.name, 1, 1, 1)
    GameTooltip:AddLine(" ")
    local any = false
    for _, profInfo in ipairs(ED.PROFESSION_ORDER) do
        local profData = entry.professions[profInfo.name]
        if profData then
            any = true
            local cur, max, behind = 0, 0, {}
            for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
                local sd = profData.skillLevels[expInfo.display]
                if sd then
                    cur, max = cur + sd.current, max + sd.max
                    if sd.current < sd.max then behind[#behind + 1] = expInfo.abbr end
                end
            end
            local flat = profData.skillLevels.Overall -- exception(optional): flat-skill profs (Archaeology) only
            if flat then cur, max = cur + flat.current, max + flat.max end
            local pct = max > 0 and math.floor(cur / max * 100 + 0.5) or 0
            local vr, vg, vb = 0.9, 0.82, 0.3
            if pct >= 100 then vr, vg, vb = 0.3, 0.9, 0.3 end
            GameTooltip:AddDoubleLine(profInfo.name, pct .. "%", _d.selected_bar.r, _d.selected_bar.g, _d.selected_bar.b, vr, vg, vb)
            if #behind > 0 then
                local shown = {}
                for i = 1, math.min(#behind, 6) do shown[i] = behind[i] end
                local txt = "  behind: " .. table.concat(shown, " ")
                if #behind > 6 then txt = txt .. string.format(" +%d", #behind - 6) end
                GameTooltip:AddLine(txt, 0.6, 0.6, 0.6)
            end
        end
    end
    if not any then
        GameTooltip:AddLine("No professions scanned yet.", 0.6, 0.6, 0.6)
    end
    -- Staleness line: entry.lastSeen nil for records created via SET_KNOWN_RECIPES
    -- only (no profession-window open), shown as "not scanned yet".
    -- exception(nullable): SavedVariables record predates lastSeen field
    GameTooltip:AddLine(" ")
    local agoText = entry.lastSeen and VWB.UI:FormatScannedAgo(entry.lastSeen, time()) or "not scanned yet"
    GameTooltip:AddLine(agoText, 0.55, 0.55, 0.6)
end

-- Sum current/max across every scanned skill entry, for the mastery bar.
local function computeMastery(professions)
    local sumCur, sumMax = 0, 0
    for _, profData in pairs(professions) do
        for _, sd in pairs(profData.skillLevels) do
            sumCur = sumCur + sd.current
            sumMax = sumMax + sd.max
        end
    end
    return sumCur, sumMax
end

local function createCharCard(p)
    local wrapper = CreateFrame("Frame", nil, p)
    wrapper:SetSize(CARD_W, STRIP_HEIGHT)

    local card = VWB.UI:CreateCharStatCard(wrapper, {
        -- Card click scopes this character and stays in Roster so the Account
        -- Summary below can highlight that character's holdings (item 1).
        -- "Plan in Workbench" button in the header bar handles the Nav jump.
        onClick = function(charKey)
            ns.Store:Dispatch("SET_SCOPE", { charKey = charKey })
        end,
    })
    card:SetPoint("TOP", 0, 0)
    wrapper.card = card

    -- Gold selection ring: four 2px edge textures anchored to the card frame,
    -- shown in OVERLAY so they sit above the card's own backdrop art but inside
    -- the wrapper. Hidden by default; wrapper:SetSelected(true/false) drives them.
    local function makeRingEdge(anchor1, anchor2, isHoriz)
        local t = card:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 0.9) -- tinted per-select from the live scheme in SetSelected
        t:SetPoint(anchor1, card, anchor1, 0, 0)
        t:SetPoint(anchor2, card, anchor2, 0, 0)
        if isHoriz then t:SetHeight(2) else t:SetWidth(2) end
        t:Hide()
        return t
    end
    wrapper._ring = {
        makeRingEdge("TOPLEFT",    "TOPRIGHT",    true),  -- top edge
        makeRingEdge("BOTTOMLEFT", "BOTTOMRIGHT", true),  -- bottom edge
        makeRingEdge("TOPLEFT",    "BOTTOMLEFT",  false), -- left edge
        makeRingEdge("TOPRIGHT",   "BOTTOMRIGHT", false), -- right edge
    }

    function wrapper:SetSelected(sel)
        local d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
        for _, t in ipairs(self._ring) do
            t:SetVertexColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 0.9)
            t:SetShown(sel)
        end
    end

    local bar = VWB.UI:CreateProgressBar(wrapper, { width = CARD_W - 16, height = BAR_H })
    bar:SetPoint("TOP", card, "BOTTOM", 0, -BAR_GAP)
    wrapper.bar = bar

    -- Visible remove affordance (owner 2026-07-12, replaces the right-click
    -- path -- right-click menus are invisible; ReganB only found Remove via
    -- the tooltip hint). Hover-reveal x, top-right; same confirm popup.
    -- Hidden on the CURRENT character: the next scan re-adds them instantly,
    -- so removal is a no-op there.
    local removeX = CreateFrame("Button", nil, card)
    removeX:SetSize(16, 16)
    removeX:SetPoint("TOPRIGHT", -2, -2)
    removeX.txt = removeX:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    removeX.txt:SetPoint("CENTER")
    removeX.txt:SetText("x")
    local sErr = VWB.UI:GetScheme().error
    removeX.txt:SetTextColor(sErr.r, sErr.g, sErr.b)
    removeX:Hide()
    removeX:SetScript("OnClick", function()
        local displayName = card._entry and card._entry.name or card._charKey
        -- StaticPopup_Show(which, text_arg1, text_arg2, data) -- data is the
        -- FOURTH arg; the old right-click passed charKey third (the unused
        -- text_arg2 slot), so OnAccept dispatched charKey=nil, a silent
        -- no-op (tester ReganB 2026-07-12: "hit Remove, nothing happens")
        StaticPopup_Show("VWB_REMOVE_CHARACTER", displayName, nil, card._charKey)
    end)
    removeX:SetScript("OnLeave", function()
        if not card:IsMouseOver() then removeX:Hide() end
    end)
    card.removeX = removeX -- the strip repaint hides it: pooled cards rebind to
    -- other characters mid-hover (scan re-sorts) and OnLeave alone can't catch that

    -- Wired directly on the card (not through the strip's own scroll frame --
    -- the card is an opaque Button covering the wrapper, so it owns its own
    -- mouse events), mirroring VPC's CreateCharCard row factory.
    card:HookScript("OnEnter", function(self)
        if self._charKey ~= VWB.CharacterData:GetCharacterKey() then removeX:Show() end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        characterTooltipBody(self._entry)
        GameTooltip:Show()
    end)
    card:HookScript("OnLeave", function(self)
        -- moving onto the x fires this (child capture) but the cursor is
        -- still inside the card bounds -- keep the x alive for its click
        if not self:IsMouseOver() then removeX:Hide() end
        GameTooltip:Hide()
    end)

    return wrapper
end

-- ============================================================================
-- BUILD
-- ============================================================================

function Roster.buildView(container)
    local R = ns.Reactor
    local Kit = ns.ViewKit

    local currentCharKey = VWB.CharacterData:GetCharacterKey()

    -- account.characters, sorted current-character-first then by lastSeen desc.
    local chars = R.named("roster:chars", function()
        ns.Store:Version("characters")
        local out = {}
        for charKey, entry in pairs(ns.Store:GetState().account.characters) do
            out[#out + 1] = { charKey = charKey, entry = entry }
        end
        table.sort(out, function(a, b)
            if a.charKey == currentCharKey then return true end
            if b.charKey == currentCharKey then return false end
            -- exception(nullable): records created via SET_KNOWN_RECIPES (not
            -- SAVE_CHARACTER_PROFESSIONS) predate lastSeen
            local la, lb = a.entry.lastSeen, b.entry.lastSeen
            if la and lb and la ~= lb then return la > lb end
            if la and not lb then return true end
            if lb and not la then return false end
            return a.charKey < b.charKey
        end)
        return out
    end)

    -- best[profName][expDisplay] = { current, max, charKey } -- the account-wide
    -- top skill per profession/expansion, and who holds it.
    local function recordIfBest(best, profName, expDisplay, sd, charKey)
        local byProf = best[profName]
        if not byProf then byProf = {}; best[profName] = byProf end
        local cur = byProf[expDisplay]
        if not cur or sd.current > cur.current then
            byProf[expDisplay] = { current = sd.current, max = sd.max, charKey = charKey }
        end
    end

    local accountBest = R.named("roster:accountBest", function()
        ns.Store:Version("characters")
        local best = {}
        for charKey, entry in pairs(ns.Store:GetState().account.characters) do
            for profName, profData in pairs(entry.professions) do
                for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
                    local sd = profData.skillLevels[expInfo.display]
                    if sd then recordIfBest(best, profName, expInfo.display, sd, charKey) end
                end
                local flat = profData.skillLevels.Overall -- exception(optional): flat-skill profs (Archaeology) only
                if flat then recordIfBest(best, profName, "Overall", flat, charKey) end
            end
        end
        return best
    end)

    -- Profession names that are secondary skills with no expansion-variant recipes.
    -- Their summary rows are gated: only shown when at least one character has
    -- the profession scanned (avoids two mostly-empty rows on typical accounts).
    local GATED_PROFS = { Fishing = true, Archaeology = true }

    -- One row per KNOWN profession. Crafting professions always shown; Fishing +
    -- Archaeology gated (shown only when any character has the profession scanned).
    -- Reads nav version so scope changes repaint gold highlights without a full
    -- accountBest recompute.
    local summaryRows = R.named("roster:summaryRows", function()
        ns.Store:Version("nav") -- scope changes drive gold repaint
        local best = accountBest()
        local scopedChar = ns.Store:GetState().ui.scopeCharacter -- exception(nullable): nil when no scope set
        local out = {}
        for _, profInfo in ipairs(ED.PROFESSION_ORDER) do
            local profBest = best[profInfo.name] or {}
            local include = true
            -- Gate secondary profs: skip if nobody on account has it scanned.
            if GATED_PROFS[profInfo.name] then
                local hasAny = false
                for _ in pairs(profBest) do hasAny = true; break end
                include = hasAny
            end
            if include then
                out[#out + 1] = { profName = profInfo.name, icon = profInfo.icon, best = profBest, scopedChar = scopedChar }
            end
        end
        return out
    end)

    local root, stripScroll, stripContent, summaryList, planBtn

    -- last-hovered profession; drives the inspector panel (sticky on leave)
    local hoverProf = R.signal(nil)
    local function onSummaryRowEnter(item) hoverProf(item.profName) end

    local function makeFrame(node, parent)
        if node.id == "rosPlanBtn" then
            planBtn = VWB.UI:CreateButton(parent, "Plan in Workbench", 130, 20)
            planBtn:SetScript("OnClick", function() ns.Nav.Go("workbench") end)
            return planBtn
        end
        if node.id == "rosGrid" then
            root = CreateFrame("Frame", nil, parent)

            -- Cold-state card (consistency review 2026-07-13). Deliberately
            -- BUTTONLESS: the fix is opening profession windows on each alt --
            -- no one-click action exists, and a button here would lie.
            root.empty = VWB.UI:CreateEmptyStateCard(root, {
                width = 380, height = 120,
                icon = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
                title = "No characters scanned yet",
                body = "Open a profession window on each alt to start tracking their skill levels.",
            })
            root.empty:SetPoint("CENTER")

            root.stripHeader = root:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
            root.stripHeader:SetPoint("TOPLEFT", 0, 0)
            root.stripHeader:SetText("Character Roster")

            -- Vertical card rail (2026-07-11: was a horizontal strip across the
            -- top -- fine at 4 alts, unusable at 20). Rail on the left, the
            -- Account Summary fills the remaining width to its right.
            root.stripHost = CreateFrame("Frame", nil, root)
            root.stripHost:SetPoint("TOPLEFT", root.stripHeader, "BOTTOMLEFT", 0, -4)
            root.stripHost:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, 0)
            root.stripHost:SetWidth(CARD_W)

            stripScroll = CreateFrame("Frame", nil, root.stripHost, "WowScrollBox")
            stripScroll:SetAllPoints()
            stripContent = CreateFrame("Frame", nil, stripScroll)
            stripContent.scrollable = true -- WowScrollBox contract: exactly one scrollable child
            stripContent:SetSize(CARD_W, 1)
            local stripView = CreateScrollBoxLinearView()
            stripView:SetPanExtent(STRIP_HEIGHT + CARD_GAP)
            stripScroll:Init(stripView)

            root.summaryHeader = root:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
            root.summaryHeader:SetPoint("TOPLEFT", root, "TOPLEFT", CARD_W + 12, 0)
            root.summaryHeader:SetText("Account Summary")

            root.expHdr = buildExpansionHeader(root)
            root.expHdr:SetPoint("TOPLEFT", root.summaryHeader, "BOTTOMLEFT", 0, -4)
            root.expHdr:SetHeight(16)

            -- Summary well hugs its rows (height set reactively per data);
            -- the inspector panel below takes whatever height remains.
            root.summaryHost = CreateFrame("Frame", nil, root)
            root.summaryHost:SetPoint("TOPLEFT", root.expHdr, "BOTTOMLEFT", 0, -2)
            root.summaryHost:SetPoint("RIGHT", root, "RIGHT", 0, 0)
            root.summaryHost:SetHeight(1)

            root.detail = CreateFrame("Frame", nil, root, "BackdropTemplate")
            root.detail:SetBackdrop(VWB.Theme.BACKDROP_PANEL)
            root.detail:SetPoint("TOPLEFT", root.summaryHost, "BOTTOMLEFT", 0, -8)
            root.detail:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
            root.detail.title = root.detail:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
            root.detail.title:SetPoint("TOPLEFT", 10, -8)
            root.detail.rowHost = CreateFrame("Frame", nil, root.detail)
            root.detail.rowHost:SetPoint("TOPLEFT", 0, -30)
            root.detail.rowHost:SetPoint("BOTTOMRIGHT", 0, 6)
            -- hint lives in the row area, BELOW the title line -- the no-scans
            -- state keeps its icon+name title, so the two must never overlap
            root.detail.hint = root.detail:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            root.detail.hint:SetPoint("TOPLEFT", root.detail.rowHost, "TOPLEFT", 10, -2)

            summaryList = VWB.UI:CreateVirtualizedList(root.summaryHost, {
                rowHeight = 20, rowTemplate = summaryRowTemplate,
                updateRow = paintSummaryRow,
                onRowEnter = onSummaryRowEnter,
            })

            return root
        end
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.roster, { makeFrame = makeFrame, measure = Kit.measure })

    -- `root` is already SetSize'd by Layout.build at this point (rosGrid is a
    -- leaf item; paint() sizes it before build() returns) -- so its final width
    -- is real here. The expansion header spans the summary column (right of
    -- the card rail).
    local rootWidth = root:GetWidth()
    root.expHdr:SetWidth(math.max(1, rootWidth - (CARD_W + 12)))

    R.bindText(handle.byId.rosTitle.label, function() return "Roster  (" .. #chars() .. " characters)" end)

    R.bindText(handle.byId.rosScopeHint.label, function()
        ns.Store:Version("nav")
        local scoped = ns.Store:GetState().ui.scopeCharacter
        if scoped then return "Scoped: " .. scoped end
        return "Scoped: none (yourself)"
    end)
    handle.byId.rosScopeHint:EnableMouse(true)
    handle.byId.rosScopeHint:SetScript("OnMouseUp", function() ns.Store:Dispatch("CLEAR_SCOPE") end)

    -- "Plan in Workbench" button: only visible when a scope is set.
    -- Clicking it navigates to the Workbench with the scoped character already set.
    R.bindShown(planBtn, function()
        ns.Store:Version("nav")
        return ns.Store:GetState().ui.scopeCharacter ~= nil
    end)

    local function hasChars() return #chars() > 0 end
    R.bindShown(root.empty, function() return not hasChars() end)
    R.bindShown(root.stripHeader, hasChars)
    R.bindShown(root.stripHost, hasChars)
    R.bindShown(root.summaryHeader, hasChars)
    R.bindShown(root.expHdr, hasChars)
    R.bindShown(root.summaryHost, hasChars)
    R.bindShown(root.detail, hasChars)

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled card rows on switch
        local list = chars()
        -- Nav version read here so scope changes repaint card selection rings
        -- without a full chars() recompute (chars() only tracks "characters" slice).
        ns.Store:Version("nav")
        local scopedChar = ns.Store:GetState().ui.scopeCharacter -- exception(nullable): nil when no scope
        VWB.UI:ResetRows(stripContent)
        local now = time()
        for i, c in ipairs(list) do
            local wrapper = VWB.UI:AcquireRow(stripContent, "charcard", createCharCard)
            wrapper:SetPoint("TOPLEFT", stripContent, "TOPLEFT", 0, -(i - 1) * (STRIP_HEIGHT + CARD_GAP))
            wrapper.card:SetData(c.charKey, c.entry, c.charKey == currentCharKey, now)
            wrapper.card.removeX:Hide() -- pooled reuse: a hover-revealed x must not carry to the rebound character
            wrapper.bar:SetProgress(computeMastery(c.entry.professions))
            wrapper:SetSelected(c.charKey == scopedChar)
        end
        VWB.UI:HideUnusedRows(stripContent)
        stripContent:SetHeight(math.max(1, #list * (STRIP_HEIGHT + CARD_GAP)))
        stripScroll:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end, "roster:strip")

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled summary rows on switch
        local rows = summaryRows()
        root.summaryHost:SetHeight(#rows * 20 + 6) -- well hugs the table; the inspector below absorbs the rest
        summaryList:SetData(rows)
    end, "roster:summary")

    -- Inspector panel: per-expansion breakdown of the last-hovered profession.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint panel chrome + rows on switch
        local s = VWB.UI:GetScheme()
        local d = VWB.Constants:GetDerivedColors(s)
        root.detail:SetBackdropColor(d.sunken.r, d.sunken.g, d.sunken.b, d.sunken.a)
        root.detail:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, s.border.a)
        root.detail.hint:SetTextColor(s.text.r, s.text.g, s.text.b)
        local prof = hoverProf()
        local item
        for _, r in ipairs(summaryRows()) do
            if r.profName == prof then item = r; break end
        end
        VWB.UI:ResetRows(root.detail.rowHost)
        if not item then
            root.detail.title:SetText("")
            root.detail.hint:SetText("Hover a profession row for its per-expansion breakdown.")
            root.detail.hint:Show()
        else
            root.detail.title:SetText("|T" .. item.icon .. ":16|t  " .. item.profName)
            root.detail.title:SetTextColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b)
            local n = 0
            local function addRow(label, color, best)
                n = n + 1
                local row = VWB.UI:AcquireRow(root.detail.rowHost, "rosdetail", createDetailRow)
                row:SetPoint("TOPLEFT", root.detail.rowHost, "TOPLEFT", 0, -(n - 1) * DETAIL_ROW_H)
                row:SetPoint("RIGHT", root.detail.rowHost, "RIGHT", 0, 0)
                row.exp:SetText(label)
                row.exp:SetTextColor(color.r, color.g, color.b)
                local vc = (best.current >= best.max) and s.success or s.accent
                row.val:SetTextColor(1, 1, 1) -- the "/max" tail after |r renders in this
                row.val:SetText(string.format("|cFF%s%d|r/%d", VWB.UI:ToHex(vc), best.current, best.max))
                row.who:SetText(best.charKey)
                row.who:SetTextColor(s.text.r, s.text.g, s.text.b)
            end
            for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
                local best = item.best[expInfo.display]
                if best then addRow(expInfo.display, expInfo.color, best) end
            end
            local flat = item.best.Overall -- exception(optional): flat-skill profs (Archaeology) only
            if flat then addRow("Overall (no expansion bands)", s.text_header, flat) end
            if n == 0 then
                root.detail.hint:SetText("No characters have scanned this profession yet.")
                root.detail.hint:Show()
            else
                root.detail.hint:Hide()
            end
        end
        VWB.UI:HideUnusedRows(root.detail.rowHost)
    end, "roster:profDetail")

    handle.status = function()
        return string.format("%d characters | %d professions tracked", #chars(), #summaryRows())
    end
    return handle
end

return Roster
