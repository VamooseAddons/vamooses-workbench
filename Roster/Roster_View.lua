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
--      one column per expansion showing the account-wide BEST current/max),
--      with a row hover tooltip naming which character holds the best value
--      per expansion.
--   3. an empty state when no character has been scanned yet.
-- Both lists re-derive off Store:Version("characters") ONLY -- a queue/config
-- dispatch elsewhere never touches this view.
-- ============================================================================

local _, ns = ...
local Roster = ns.Roster or {}
ns.Roster = Roster

local ED = VWB.Data.ExpansionData

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

    local name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 4, 0); name:SetWidth(PROF_COL_WIDTH - 24); name:SetJustifyH("LEFT")
    frame.name = name

    frame.cells = {}
    local x = PROF_COL_WIDTH + 8
    for i = 1, #ED.EXPANSION_ORDER do
        local cell = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("LEFT", x, 0); cell:SetWidth(EXP_COL_WIDTH); cell:SetJustifyH("CENTER")
        frame.cells[i] = cell
        x = x + EXP_COL_WIDTH
    end
end

local function paintSummaryRow(row, item)
    row.data = item
    row.icon:SetTexture(item.icon)
    row.name:SetText(item.profName)
    local s = VWB.UI:GetScheme()
    for i, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local best = item.best[expInfo.display]
        local cell = row.cells[i]
        if best then
            local color = (best.current >= best.max) and s.success or s.accent
            cell:SetTextColor(1, 1, 1) -- reset: the "/max" tail after |r falls back to this, not a stale dim-gray from a prior "-" paint of this pooled cell
            cell:SetText(string.format("|cFF%s%d|r/%d", VWB.UI:ToHex(color), best.current, best.max))
        else
            cell:SetText("-")
            cell:SetTextColor(s.text.r, s.text.g, s.text.b)
        end
    end
end

-- Row-level hover: full per-expansion breakdown + which character holds the
-- account-wide best value there ("auto hover" via CreateVirtualizedList's own
-- OnLeave -> GameTooltip:Hide when the mouse leaves the row).
local function onSummaryRowEnter(item, rowFrame)
    GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
    GameTooltip:AddLine(item.profName, 1, 0.82, 0.3)
    local any = false
    for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local best = item.best[expInfo.display]
        if best then
            any = true
            GameTooltip:AddDoubleLine(expInfo.display,
                string.format("%d/%d  (%s)", best.current, best.max, best.charKey),
                1, 1, 1, 0.7, 0.7, 0.7)
        end
    end
    if not any then
        GameTooltip:AddLine("No characters have scanned this profession yet.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- Static expansion column header (built once; no per-frame data, never repainted).
local function buildExpansionHeader(parent)
    local hdr = CreateFrame("Frame", nil, parent)
    local profLabel = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profLabel:SetPoint("LEFT", 4, 0); profLabel:SetWidth(PROF_COL_WIDTH); profLabel:SetJustifyH("LEFT")
    profLabel:SetText("Profession")

    local x = PROF_COL_WIDTH + 8
    for _, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local lbl = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
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
            local pct = max > 0 and math.floor(cur / max * 100 + 0.5) or 0
            local vr, vg, vb = 0.9, 0.82, 0.3
            if pct >= 100 then vr, vg, vb = 0.3, 0.9, 0.3 end
            GameTooltip:AddDoubleLine(profInfo.name, pct .. "%", 1, 0.82, 0.3, vr, vg, vb)
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
        -- Dispatch scope change then navigate to the Workbench so the user lands
        -- in the recipe list already scoped to the alt they clicked (edge #3).
        onClick = function(charKey)
            ns.Store:Dispatch("SET_SCOPE", { charKey = charKey })
            ns.Nav.Go("workbench")
        end,
    })
    card:SetPoint("TOP", 0, 0)
    wrapper.card = card

    local bar = VWB.UI:CreateProgressBar(wrapper, { width = CARD_W - 16, height = BAR_H })
    bar:SetPoint("TOP", card, "BOTTOM", 0, -BAR_GAP)
    wrapper.bar = bar

    -- Wired directly on the card (not through the strip's own scroll frame --
    -- the card is an opaque Button covering the wrapper, so it owns its own
    -- mouse events), mirroring VPC's CreateCharCard row factory.
    card:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        characterTooltipBody(self._entry)
        GameTooltip:Show()
    end)
    card:HookScript("OnLeave", function() GameTooltip:Hide() end)

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
            end
        end
        return best
    end)

    -- One row per KNOWN profession (all 12, always -- unscanned ones show "-"),
    -- crafting professions first then gathering (ED.PROFESSION_ORDER's own order).
    local summaryRows = R.named("roster:summaryRows", function()
        local best = accountBest()
        local out = {}
        for _, profInfo in ipairs(ED.PROFESSION_ORDER) do
            -- exception(nullable): profession nobody on the account has scanned yet
            out[#out + 1] = { profName = profInfo.name, icon = profInfo.icon, best = best[profInfo.name] or {} }
        end
        return out
    end)

    local root, stripScroll, stripContent, summaryList

    local function makeFrame(node, parent)
        if node.id == "rosGrid" then
            root = CreateFrame("Frame", nil, parent)

            root.empty = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            root.empty:SetPoint("CENTER")
            root.empty:SetJustifyH("CENTER")
            root.empty:SetText("No characters scanned yet.\nOpen a profession window on each alt to start tracking their skill levels.")

            root.stripHeader = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            root.stripHeader:SetPoint("TOPLEFT", 0, 0)
            root.stripHeader:SetText("Character Roster")

            -- Width set explicitly below (after Layout.build sizes `root`) rather
            -- than a second stretch-anchor -- avoids mixing a TOPLEFT anchor with
            -- a cross-family point (RIGHT/TOPRIGHT) that would leave the height
            -- ambiguous alongside the explicit SetHeight.
            root.stripHost = CreateFrame("Frame", nil, root)
            root.stripHost:SetPoint("TOPLEFT", root.stripHeader, "BOTTOMLEFT", 0, -4)
            root.stripHost:SetHeight(STRIP_HEIGHT)

            stripScroll = CreateFrame("Frame", nil, root.stripHost, "WowScrollBox")
            stripScroll:SetAllPoints()
            stripContent = CreateFrame("Frame", nil, stripScroll)
            stripContent.scrollable = true -- WowScrollBox contract: exactly one scrollable child
            stripContent:SetSize(1, STRIP_HEIGHT)
            local stripView = CreateScrollBoxLinearView()
            stripView:SetHorizontal(true)
            stripView:SetPanExtent(CARD_W + CARD_GAP)
            stripScroll:Init(stripView)

            root.summaryHeader = root:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            root.summaryHeader:SetPoint("TOPLEFT", root.stripHost, "BOTTOMLEFT", 0, -10)
            root.summaryHeader:SetText("Account Summary")

            root.expHdr = buildExpansionHeader(root)
            root.expHdr:SetPoint("TOPLEFT", root.summaryHeader, "BOTTOMLEFT", 0, -4)
            root.expHdr:SetHeight(16)

            root.summaryHost = CreateFrame("Frame", nil, root)
            root.summaryHost:SetPoint("TOPLEFT", root.expHdr, "BOTTOMLEFT", 0, -2)
            root.summaryHost:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)

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
    -- is real here. Width-stretch the two full-row headers off of it.
    local rootWidth = root:GetWidth()
    root.stripHost:SetWidth(rootWidth)
    root.expHdr:SetWidth(rootWidth)

    R.bindText(handle.byId.rosTitle.label, function() return "Roster  (" .. #chars() .. " characters)" end)

    R.bindText(handle.byId.rosScopeHint.label, function()
        ns.Store:Version("nav")
        local scoped = ns.Store:GetState().ui.scopeCharacter
        if scoped then return "Scoped: " .. scoped end
        return "Scoped: none (yourself)"
    end)
    handle.byId.rosScopeHint:EnableMouse(true)
    handle.byId.rosScopeHint:SetScript("OnMouseUp", function() ns.Store:Dispatch("CLEAR_SCOPE") end)

    local function hasChars() return #chars() > 0 end
    R.bindShown(root.empty, function() return not hasChars() end)
    R.bindShown(root.stripHeader, hasChars)
    R.bindShown(root.stripHost, hasChars)
    R.bindShown(root.summaryHeader, hasChars)
    R.bindShown(root.expHdr, hasChars)
    R.bindShown(root.summaryHost, hasChars)

    R.effect(function()
        local list = chars()
        VWB.UI:ResetRows(stripContent)
        local now = time()
        for i, c in ipairs(list) do
            local wrapper = VWB.UI:AcquireRow(stripContent, "charcard", createCharCard)
            wrapper:SetPoint("TOPLEFT", stripContent, "TOPLEFT", (i - 1) * (CARD_W + CARD_GAP), 0)
            wrapper.card:SetData(c.charKey, c.entry, c.charKey == currentCharKey, now)
            wrapper.bar:SetProgress(computeMastery(c.entry.professions))
        end
        VWB.UI:HideUnusedRows(stripContent)
        stripContent:SetWidth(math.max(1, #list * (CARD_W + CARD_GAP)))
        stripScroll:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end, "roster:strip")

    R.effect(function() summaryList:SetData(summaryRows()) end, "roster:summary")

    return handle
end

return Roster
