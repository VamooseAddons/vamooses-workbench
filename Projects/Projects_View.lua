-- ============================================================================
-- VWB Projects - VIEW / controller. The plan board (hero surface).
-- ============================================================================
-- Pin a goal (collect an item / keep a stock par) -> ProjectPlanner derives the
-- live plan (BUY/FARM/STAGE/CRAFT/BLOCKED steps across alts) -> this view renders
-- it: a horizontal card strip (active first, trophy shelf dimmed at the end),
-- a steps panel + materials panel for the selected project, and click-only
-- affordances (Queue / Ask / Auctionator / par steppers). NOTHING auto-queues.
-- Empty state IS the onboarding pitch. Slice subscriptions: projects + corpus +
-- characters + a local inventory epoch (VWB_INVENTORY_UPDATE has no Store slice).
-- Design: docs/PROJECTS_SPEC_2026-07-11.md.
-- ============================================================================

local _, ns = ...
local Projects = ns.Projects or {}
ns.Projects = Projects

-- VWB.UI.BACKDROP_FLAT (Framework) is the canonical flat backdrop; local was a subset duplicate.
---@type backdropInfo
local FLAT = VWB.UI.BACKDROP_FLAT -- exception(false-positive): indirection loses type; value is backdropInfo
local ICON_FALLBACK = 134400 -- INV_Misc_QuestionMark; exception(boundary): GetItemIconByID nil on cold item data

local CARD_W, CARD_H, CARD_GAP = 260, 64, 6 -- rail cards (vertical scroll, left of Plan)
-- The status PIPELINE (stored keys; "bench" displays as Active). The rail
-- shows ONE segment at a time; card arrows move along the pipeline.
local PIPE = { "backlog", "bench", "done" }
local PIPE_POS = { backlog = 1, bench = 2, done = 3 }
local SEGMENTS = { { key = "backlog", label = "Backlog" }, { key = "bench", label = "Active" }, { key = "done", label = "Done" } }
-- Atlases (owner-picked commonicons set). TRASH: stand-in "common-icon-delete"
-- until the trashcan atlas name is confirmed in the in-game atlas viewer.
local ATLAS_BACK, ATLAS_BACK_DIS = "common-icon-backarrow", "common-icon-backarrow-disable"
local ATLAS_FWD, ATLAS_FWD_DIS = "common-icon-forwardarrow", "common-icon-forwardarrow-disable"
local ATLAS_TRASH = "common-icon-delete"

StaticPopupDialogs["VWB_REMOVE_PROJECT"] = {
    text = "Remove commission '%s'?",
    button1 = "Remove", button2 = "Cancel",
    OnAccept = function(self, id) VWB.Store:Dispatch("REMOVE_PROJECT", { id = id }) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["VWB_REMOVE_PIECE"] = {
    text = "Remove piece '%s'?",
    button1 = "Remove", button2 = "Cancel",
    OnAccept = function(self, d) VWB.Store:Dispatch("REMOVE_PIECE", { projectId = d.projectId, pieceId = d.pieceId }) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ============================================================================
-- Project card (pooled via VWB.UI:AcquireRow on the horizontal strip)
-- ============================================================================

-- Par steppers act on the ONE stock piece of a single-piece card (multi-piece
-- projects edit par per piece in the drill-in).
local function bumpPar(card, delta)
    local e = card.entry
    local step = IsShiftKeyDown() and 5 or 1
    local piece = e.p.pieces[1]
    VWB.Store:Dispatch("SET_PIECE_PAR", { id = e.p.id, pieceId = piece.id,
        par = math.max(1, (piece.par or 1) + delta * step) })
end

local TOOLTIP_PIECE_CAP = 8

local function cardTooltip(card)
    local e = card.entry
    local T = VWB.UI.Tooltip
    T:Begin(card, "RIGHT")
    T:AddTitle(e.p.name)
    if e.p.completedAt then
        T:AddLine("Completed " .. VWB.UI:FormatScannedAgo(e.p.completedAt, time()))
    else
        T:AddLine(string.format("Commission -- %d piece(s), %d done", e.plan.total, e.plan.done))
    end
    for i = 1, math.min(#e.p.pieces, TOOLTIP_PIECE_CAP) do
        local pc, pp = e.p.pieces[i], e.plan.pieces[i]
        local name = pc.itemID and (C_Item.GetItemInfo(pc.itemID)) or ("piece " .. i) -- exception(boundary): cold item name; tooltip re-opens warm
        if pp.status == "complete" then
            T:AddLine(name .. "  --  done")
        elseif pc.kind == "stock" then
            T:AddLine(string.format("%s  --  par %d (%d on hand)", name, pp.par or pc.par, pp.level or 0))
        else
            T:AddLine(string.format("%s  --  %d/%d steps", name, pp.done, pp.total))
        end
    end
    if #e.p.pieces > TOOLTIP_PIECE_CAP then
        T:AddLine("... and " .. (#e.p.pieces - TOOLTIP_PIECE_CAP) .. " more")
    end
    if e.plan.buyCost > 0 then T:AddLine("Missing mats on the AH: " .. VWB.UI:FormatMoney(e.plan.buyCost)) end
    T:AddLine("Right-click: move / remove")
    T:Show()
end

-- Right-click board menu: status moves + remove. "Move to Done" is a real
-- move (stamps completion) -- greyed when pieces remain, per the ui ruling.
local function cardMenu(card)
    local e = card.entry
    MenuUtil.CreateContextMenu(card, function(_, root)
        root:CreateTitle(e.p.name)
        for _, status in ipairs({ "backlog", "bench", "done" }) do
            local label = ({ backlog = "Move to Backlog", bench = "Mark Active", done = "Move to Done" })[status]
            local btn = root:CreateButton(label, function()
                VWB.Store:Dispatch("SET_PROJECT_STATUS", { id = e.p.id, status = status })
            end)
            if e.p.status == status then btn:SetEnabled(false) end
            if status == "done" and (e.plan.total == 0 or e.plan.done < e.plan.total) then btn:SetEnabled(false) end
        end
        root:CreateDivider()
        root:CreateButton("Remove...", function()
            StaticPopup_Show("VWB_REMOVE_PROJECT", e.p.name, nil, e.p.id)
        end)
    end)
end

-- Small atlas button for the card's hover controls (arrows + trashcan).
local function atlasButton(parent, size, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetAllPoints()
    b.tooltip = tooltip
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltip, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function createProjectCard(p, onSelect)
    local card = CreateFrame("Button", nil, p, "BackdropTemplate")
    card:SetSize(CARD_W, CARD_H)
    card:SetBackdrop(FLAT)
    card:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28); icon:SetPoint("TOPLEFT", 8, -8)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    card.icon = icon

    card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
    card.name:SetPoint("RIGHT", card, "RIGHT", -8, 0)
    card.name:SetJustifyH("LEFT"); card.name:SetWordWrap(false)

    card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.sub:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -2)
    card.sub:SetPoint("RIGHT", card, "RIGHT", -34, 0)
    card.sub:SetJustifyH("LEFT"); card.sub:SetWordWrap(false)

    card.bar = VWB.UI:CreateProgressBar(card, { width = CARD_W - 16, height = 7 })
    card.bar:SetPoint("BOTTOMLEFT", 8, 7)
    card.bar.text:SetText("") -- gauge only; the sub line carries the numbers
    card.bar.text:Hide()

    -- stock par steppers (shift = x5), shown only on stock cards
    card.minus = VWB.UI:CreateIconButton(card, "Interface\\Buttons\\UI-MinusButton-Up", 14, 14, "Lower par (shift = 5)")
    card.minus:SetPoint("TOPRIGHT", -20, -6)
    card.minus:SetScript("OnClick", function() bumpPar(card, -1) end)
    card.plus = VWB.UI:CreateIconButton(card, "Interface\\Buttons\\UI-PlusButton-Up", 14, 14, "Raise par (shift = 5)")
    card.plus:SetPoint("TOPRIGHT", -4, -6)
    card.plus:SetScript("OnClick", function() bumpPar(card, 1) end)

    -- Hover controls: pipeline arrows + trashcan (owner atlas set; visible
    -- affordance principle -- the right-click menu stays only as a power path)
    card.back = atlasButton(card, 14, "")
    card.back:SetPoint("BOTTOMRIGHT", -40, 5)
    card.back:SetScript("OnClick", function(self)
        local e = card.entry
        if self.enabledMove then
            VWB.Store:Dispatch("SET_PROJECT_STATUS", { id = e.p.id, status = PIPE[PIPE_POS[e.p.status] - 1] })
        end
    end)
    card.fwd = atlasButton(card, 14, "")
    card.fwd:SetPoint("BOTTOMRIGHT", -22, 5)
    card.fwd:SetScript("OnClick", function(self)
        local e = card.entry
        if self.enabledMove then
            VWB.Store:Dispatch("SET_PROJECT_STATUS", { id = e.p.id, status = PIPE[PIPE_POS[e.p.status] + 1] })
        end
    end)
    card.trash = atlasButton(card, 13, "Remove commission")
    card.trash:SetPoint("BOTTOMRIGHT", -4, 5)
    card.trash.tex:SetAtlas(ATLAS_TRASH)
    card.trash:SetScript("OnClick", function()
        StaticPopup_Show("VWB_REMOVE_PROJECT", card.entry.p.name, nil, card.entry.p.id)
    end)
    card.back:Hide(); card.fwd:Hide(); card.trash:Hide()

    local function hoverControls(shown)
        card.back:SetShown(shown); card.fwd:SetShown(shown); card.trash:SetShown(shown)
    end
    card:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            cardMenu(self)
        else
            onSelect(self.entry.p.id)
        end
    end)
    card:SetScript("OnEnter", function(self) hoverControls(true); cardTooltip(self) end)
    card:SetScript("OnLeave", function(self)
        if not self:IsMouseOver() then hoverControls(false) end
        VWB.UI.Tooltip:Hide(self)
    end)
    return card
end

-- Arrow state per the pipeline + the done-entry rule (presentation of the
-- SAME rule the reducer enforces).
local function paintCardControls(card, entry)
    local pos = PIPE_POS[entry.p.status]
    local backOk = pos > 1
    card.back.tex:SetAtlas(backOk and ATLAS_BACK or ATLAS_BACK_DIS)
    card.back.enabledMove = backOk
    card.back.tooltip = pos == 3 and "Reopen (to Active)" or pos == 2 and "Back to Backlog" or "Start of the line"
    local fwdOk
    if pos == 1 then fwdOk = true
    elseif pos == 2 then fwdOk = entry.plan.total > 0 and entry.plan.done >= entry.plan.total
    else fwdOk = false end
    card.fwd.tex:SetAtlas(fwdOk and ATLAS_FWD or ATLAS_FWD_DIS)
    card.fwd.enabledMove = fwdOk
    card.fwd.tooltip = pos == 1 and "Move to Active"
        or pos == 2 and (fwdOk and "Move to Done" or "Pieces remain -- can't complete yet")
        or "Done is done"
end

local function paintProjectCard(card, entry, isSelected)
    local s = VWB.UI:GetScheme()
    local p, plan = entry.p, entry.plan
    card.entry = entry

    local iconPiece = p.pieces[1]
    card.icon:SetTexture(p.icon or (iconPiece and iconPiece.itemID and C_Item.GetItemIconByID(iconPiece.itemID)) or ICON_FALLBACK)
    card.name:SetText(p.name)
    local d = VWB.Constants:GetDerivedColors(s)
    card:SetBackdropColor(s.panel.r, s.panel.g, s.panel.b, s.panel.a)
    if isSelected then
        card:SetBackdropBorderColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 1) -- selection identity from scheme
    else
        card:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, s.border.a)
    end

    -- Single-stock-piece cards keep the v1 par steppers; anything bigger
    -- edits par inside the piece drill-in.
    local solo = #p.pieces == 1 and p.pieces[1]
    local soloPlan = solo and plan.pieces[1]
    local showSteppers = solo and solo.kind == "stock" and p.status ~= "done"
    card.minus:SetShown(showSteppers or false)
    card.plus:SetShown(showSteppers or false)

    if solo and solo.kind == "stock" and soloPlan.status ~= "complete" then
        card.bar:SetProgress(soloPlan.level or 0, soloPlan.par or 1)
        if soloPlan.status == "dormant" then
            card.sub:SetText(string.format("par %d -- stocked", soloPlan.par))
            card.sub:SetTextColor(s.success.r, s.success.g, s.success.b)
        else
            card.sub:SetText(string.format("par %d -- %d on hand", soloPlan.par, soloPlan.level))
            card.sub:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
        end
    elseif p.status == "done" or (plan.total > 0 and plan.done == plan.total) then
        card.bar:SetProgress(1, 1)
        card.sub:SetText(p.completedAt and ("done " .. VWB.UI:FormatScannedAgo(p.completedAt, time())) or "all pieces done")
        card.sub:SetTextColor(s.success.r, s.success.g, s.success.b)
    elseif plan.total == 0 then
        card.bar:SetProgress(0, 1)
        card.sub:SetText("no pieces yet -- use Add piece... in the plan panel")
        card.sub:SetTextColor(s.text.r, s.text.g, s.text.b)
    else
        card.bar:SetProgress(plan.done, plan.total)
        card.sub:SetText(string.format("%d %s  --  %d/%d done",
            plan.total, plan.total == 1 and "piece" or "pieces", plan.done, plan.total))
        card.sub:SetTextColor(s.text.r, s.text.g, s.text.b)
    end

    card:SetAlpha(p.status == "done" and 0.5 or 1)
    paintCardControls(card, entry)
end

-- ============================================================================
-- Steps rows (pooled by CreateVirtualizedList)
-- ============================================================================

local CHIP = { -- text + scheme color key per step kind; CRAFT resolves by readiness
    BUY = { text = "BUY", color = "accent" }, FARM = { text = "FARM", color = "text" },
    STAGE = { text = "STAGE", color = "warning" }, BLOCKED = { text = "NO ALT", color = "error" },
    LEARN = { text = "LEARN", color = "accent" }, -- study pieces: acquisition sources, not crafts
}

local function stepRowTemplate(frame)
    frame.chip = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.chip:SetPoint("LEFT", 4, 0); frame.chip:SetWidth(52); frame.chip:SetJustifyH("LEFT")

    frame.action = VWB.UI:CreateButton(frame, "", 64, 18)
    frame.action:SetPoint("RIGHT", -4, 0)
    frame.action:SetScript("OnClick", function(self)
        local st = self:GetParent().data
        if st.kind == "CRAFT" then
            VWB.Store:Dispatch("ADD_TO_QUEUE", { recipeID = st.recipeID, qty = st.need, charKey = st.charKey })
            VWB.Log:Print(string.format("Queued %dx %s", st.need, st.name))
        elseif st.kind == "BLOCKED" then
            local sent, info = VWB.GuildCrafters:WhisperCrafter(st.recipeID)
            VWB.Log:Print(sent and ("Asked " .. info) or info)
        end
    end)

    frame.who = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.who:SetPoint("RIGHT", frame.action, "LEFT", -6, 0); frame.who:SetWidth(120); frame.who:SetJustifyH("RIGHT")

    -- "queued xN" chip: click feedback for the Queue action (the reducer merges
    -- by recipe+char, so without this a second click silently doubles the order).
    -- Single-point FontString sizes to its text; empty = zero width.
    frame.queued = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.queued:SetPoint("RIGHT", frame.who, "LEFT", -6, 0)

    frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.name:SetPoint("LEFT", frame.chip, "RIGHT", 4, 0)
    frame.name:SetPoint("RIGHT", frame.queued, "LEFT", -4, 0)
    frame.name:SetJustifyH("LEFT"); frame.name:SetWordWrap(false)
end

-- Planned amount already in the crafting queue for this step's assigned crafter.
-- The paint runs inside projects:detail, which subscribes Version("crafting"),
-- so queue edits repaint the chip immediately.
local function queuedQty(recipeID, charKey)
    for _, q in ipairs(VWB.Store:GetState().crafting.queuedRecipes) do
        if q.recipeID == recipeID and q.charKey == charKey then return q.qty end
    end
    return 0
end

local function paintStepRow(row, st)
    local s = VWB.UI:GetScheme()
    local current = VWB.CharacterData:GetCharacterKey()

    if st.kind == "CRAFT" then
        local c = st.done and s.text_header or (st.ready and s.success or s.text)
        row.chip:SetText("CRAFT"); row.chip:SetTextColor(c.r, c.g, c.b)
        row.name:SetText(st.done and (st.name .. "  (done)") or string.format("%dx %s", st.need, st.name))
        row.who:SetText(VWB.ProjectPlanner:DisplayName(st.charKey) .. (st.pinned and " *" or ""))
        local qn = not st.done and queuedQty(st.recipeID, st.charKey) or 0
        row.queued:SetText(qn > 0 and ("queued x" .. qn) or "")
        row.queued:SetTextColor(s.success.r, s.success.g, s.success.b)
        row.action:SetText("Queue")
        row.action:SetShown(st.ready and st.charKey == current)
    else
        local chip = CHIP[st.kind]
        local c = s[chip.color]
        row.chip:SetText(chip.text); row.chip:SetTextColor(c.r, c.g, c.b)
        row.queued:SetText("") -- pooled row may have painted a CRAFT chip last cycle
        if st.kind == "LEARN" then -- a source, not a quantity
            row.name:SetText(st.name)
            row.who:SetText(st.zone or "")
            row.action:SetShown(false)
            row.name:SetTextColor(1, 1, 1)
            return
        end
        row.name:SetText(string.format("%dx %s", st.need, st.name))
        if st.kind == "BUY" then
            row.who:SetText(VWB.UI:FormatMoney(st.unitPrice * st.need))
        elseif st.kind == "FARM" then
            row.who:SetText(st.gatherMethod or "") -- exception(optional): gatherMethod only for known Trade Goods subclasses
        elseif st.kind == "STAGE" then
            row.who:SetText("for " .. VWB.ProjectPlanner:DisplayName(st.charKey))
        else
            row.who:SetText("")
        end
        row.action:SetText("Ask")
        row.action:SetShown(st.kind == "BLOCKED")
    end
    row.name:SetTextColor(1, 1, 1)
    if st.kind == "CRAFT" and st.done then row.name:SetTextColor(s.text_header.r, s.text_header.g, s.text_header.b) end
end

local function onStepRowEnter(st, rowFrame)
    local T = VWB.UI.Tooltip
    T:Begin(rowFrame, "RIGHT")
    if st.kind == "CRAFT" then
        T:AddTitle(st.name)
        T:AddLine(string.format("Need %d (own %d of %d)", st.need, st.owned, st.required))
        local names = VWB.KnownRecipes:KnownByList(st.recipeID)
        T:AddLine("Recipe known by: " .. table.concat(names, ", ")) -- knowledge-domain wording: recipe side, not item collection
        local qn = queuedQty(st.recipeID, st.charKey)
        if qn > 0 then
            T:AddLine(string.format("Queued: x%d for %s -- Queue adds more", qn, VWB.ProjectPlanner:DisplayName(st.charKey)))
        end
        if st.pinned then T:AddLine("* pinned to this character") end
    elseif st.kind == "BLOCKED" then
        T:AddTitle(st.name)
        T:AddLine("No character on this account knows the recipe.")
        local online = VWB.GuildCrafters:GetOnlineCrafters(st.recipeID)
        if #online > 0 then
            T:AddLine(#online .. " guild crafter(s) online -- Ask sends a whisper")
        else
            T:AddLine("No guild crafters online right now")
        end
    elseif st.kind == "LEARN" then
        T:AddTitle(st.name)
        T:AddLine("Learn the recipe to complete this piece.")
        if st.zone then T:AddLine("Zone: " .. st.zone) end
        if st.cost then T:AddLine("Cost: " .. st.cost) end
        if st.faction then T:AddLine("Requires: " .. st.faction) end
    elseif st.kind == "BUY" then
        T:AddTitle(st.name)
        T:AddLine(string.format("%d short -- %s each", st.need, VWB.UI:FormatMoney(st.unitPrice)))
    elseif st.kind == "STAGE" then
        T:AddTitle("Stage materials")
        T:AddLine("These mats are in YOUR bags; the crafter is another character.")
        T:AddLine("Deposit them in the warband bank so the plan can proceed.")
    else
        T:AddTitle(st.name)
        T:AddLine("Farm or gather -- no market price on any source")
    end
    T:Show()
end

-- ============================================================================
-- Materials rows
-- ============================================================================

-- The right panel is SOURCES / MATERIALS (owner 2026-07-12): one mixed list
-- -- mat rows, dim section/piece headers, and full-width acquisition source
-- lines for study pieces (their supporting detail is WHERE, not what-mats).
local function matRowTemplate(frame)
    frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.name:SetPoint("LEFT", 4, 0); frame.name:SetWidth(170); frame.name:SetJustifyH("LEFT"); frame.name:SetWordWrap(false)
    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.count:SetPoint("LEFT", frame.name, "RIGHT", 6, 0); frame.count:SetWidth(70); frame.count:SetJustifyH("RIGHT")
    -- price is CLAMPED between count and the right edge (a five-digit gold
    -- value was overflowing left OVER the count column -- live 2026-07-12)
    frame.price = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.price:SetPoint("LEFT", frame.count, "RIGHT", 4, 0)
    frame.price:SetPoint("RIGHT", -4, 0)
    frame.price:SetJustifyH("RIGHT"); frame.price:SetWordWrap(false); frame.price:SetMaxLines(1)
    -- full-width line for source rows / headers (raw colored sourceText)
    frame.line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.line:SetPoint("LEFT", 4, 0); frame.line:SetPoint("RIGHT", -4, 0)
    frame.line:SetJustifyH("LEFT"); frame.line:SetWordWrap(false); frame.line:SetMaxLines(1)
end

local function paintMatRow(row, m)
    local s = VWB.UI:GetScheme()
    local isLine = m.kind == "hdr" or m.kind == "src"
    row.name:SetShown(not isLine); row.count:SetShown(not isLine); row.price:SetShown(not isLine)
    row.line:SetShown(isLine)
    if m.kind == "hdr" then
        row.line:SetText(m.label)
        row.line:SetTextColor(s.accent.r, s.accent.g, s.accent.b)
        return
    elseif m.kind == "src" then
        row.line:SetText(m.line)
        row.line:SetTextColor(1, 1, 1) -- sourceText carries its own embedded colors
        return
    end
    row.name:SetText(m.name)
    row.count:SetText(m.owned .. "/" .. m.required)
    if m.missing == 0 then
        row.count:SetTextColor(s.success.r, s.success.g, s.success.b)
        row.price:SetText("")
    else
        row.count:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
        local price = VWB.PriceIntegration:GetPrice(m.itemID)
        row.price:SetText(price and VWB.UI:FormatMoney(price * m.missing) or "--")
    end
end

-- ============================================================================
-- BUILD
-- ============================================================================

-- Bench ordering: projects with a below-par stock piece float (actionable
-- now), then by piece progress; everything else by id (stable).
local function benchRank(e)
    for _, pp in ipairs(e.plan.pieces) do
        if pp.status == "active" and pp.par then return 1 end
    end
    return 2
end

function Projects.buildView(container)
    local R = ns.Reactor
    local Kit = ns.ViewKit

    local selectedId = R.signal(nil)
    local railSeg = R.signal("bench") -- the rail's visible segment; Active = the working set (ruling 6B)
    local newStockOpen = R.signal(false)
    local stockSearch = R.signal("")
    local invEpoch = R.signal(0) -- VWB_INVENTORY_UPDATE has no Store slice; local epoch stands in
    VWB.EventBus:Register("VWB_INVENTORY_UPDATE", function()
        R.untrack(function() invEpoch(invEpoch() + 1) end) -- untrack: EventBus callback is not a reactive context
    end)

    -- Name resolver: shared addon-wide resource (VWB.UI:ItemNameResource, Framework.lua).
    -- Resolves async item names reactively on ITEM_DATA_LOAD_RESULT; a name that lands
    -- in Recipes_View is already warm here -- one cache, not two. See Framework.lua for
    -- the resource shape. Async row fields belong in a resource, not imperative epochs.
    local nameRes = VWB.UI:ItemNameResource()
    local function liveName(itemID, baked)
        if baked and baked ~= "Loading..." then return baked end
        if not itemID then return baked or "?" end -- exception(nullable): synthetic steps carry no itemID
        local n = nameRes(itemID)
        if n == nil or R.isPending(n) then return "Loading..." end -- exception(boundary): still cold; resource re-fires the effect on load
        return n
    end
    -- Overlay a resolved name without mutating the derived plan row.
    -- D4: plain shallow copy instead of setmetatable -- avoids a table+metatable
    -- alloc per row per flush; these are small rows (5-8 fields) so pairs-copy is
    -- cheaper than rooting a metatable chain.
    local function withLiveName(row)
        local resolved = liveName(row.itemID, row.name)
        if resolved == row.name then return row end
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.name = resolved
        return copy
    end

    -- goal list -> derived plans, grouped by board status (Commissions v2:
    -- Backlog / On the Bench / Done in ONE rail, dividers not columns)
    local plans = R.named("projects:plans", function()
        ns.Store:Version("projects"); ns.Store:Version("corpus"); ns.Store:Version("characters")
        invEpoch()
        local groups = { backlog = {}, bench = {}, done = {} }
        for _, p in ipairs(ns.Store:GetState().projects.items) do
            local e = { p = p, plan = VWB.ProjectPlanner:DerivePlan(p) }
            local g = groups[p.status]
            g[#g + 1] = e
        end
        table.sort(groups.bench, function(a, b)
            local ra, rb = benchRank(a), benchRank(b)
            if ra ~= rb then return ra < rb end
            if a.plan.total ~= 0 and b.plan.total ~= 0 then
                local pa, pb = a.plan.done / a.plan.total, b.plan.done / b.plan.total
                if pa ~= pb then return pa > pb end
            end
            return a.p.id < b.p.id
        end)
        table.sort(groups.backlog, function(a, b) return a.p.id < b.p.id end)
        table.sort(groups.done, function(a, b) return (a.p.completedAt or 0) > (b.p.completedAt or 0) end)
        return groups
    end)

    local selectedEntry = R.named("projects:selected", function()
        local id = selectedId()
        if id == nil then return nil end -- exception(nullable): nothing selected yet
        local ps = plans()
        for _, group in pairs(ps) do
            for _, e in ipairs(group) do if e.p.id == id then return e end end
        end
        return nil -- exception(nullable): selection outlived its project (removed)
    end)

    -- Universal piece SELECTION (design-lab E): the tree shows everything;
    -- selecting a piece (by stable id -- v3 entities) scopes Materials and
    -- the queue buttons to it. nil = whole commission.
    local selectedPiece = R.signal(nil) -- pieceId or nil
    local function effectivePiece(e)
        if not e then return nil end
        local id = selectedPiece()
        if id == nil then return nil end
        for i, pc in ipairs(e.p.pieces) do
            if pc.id == id then return i end -- plan arrays stay index-parallel to pieces
        end
        return nil
    end
    local expandCollapsed = R.signal({}) -- [pieceId] = true when collapsed (default: expanded)
    local addPieceTarget = R.signal(nil) -- projectId the picker adds pieces to (nil = picker creates new stock projects)

    -- consumables matching the new-stock search (name match over the harvested corpus)
    local stockMatches = R.named("projects:stockMatches", function()
        ns.Store:Version("corpus")
        local q = stockSearch():lower()
        if #q < 2 then return {} end
        local out = {}
        for recipeID, r in pairs(VWB.Database:GetAllRecipes()) do
            if r.itemID and r.name and r.name:lower():find(q, 1, true) then
                out[#out + 1] = { recipeID = recipeID, name = r.name, profession = r.profession, itemID = r.itemID }
                if #out >= 40 then break end
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end)

    -- Board skeleton lives in LayoutConfig_Projects (2026-07-11 -- was hand-
    -- rolled in here, Roster-style, behind a single prjBody leaf). makeFrame
    -- below supplies only the LEAVES: rail scroll host, the lists, the
    -- three buttons. Overlays (empty card, new-stock picker) anchor over the
    -- container -- the only genuinely view-managed chrome left.
    local stripScroll, stripContent, emptyCard, stepsList, matsList, nsPanel

    -- compact picker: search the harvested corpus, click = track at par 20.
    -- Overlay anchored over the container, above the board panels.
    local function buildNewStockPanel(host)
        nsPanel = CreateFrame("Frame", nil, host, "BackdropTemplate")
        nsPanel:SetBackdrop(FLAT)
        local s = VWB.UI:GetScheme()
        nsPanel:SetBackdropColor(s.panel.r, s.panel.g, s.panel.b, 0.98)
        nsPanel:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, 1)
        nsPanel:SetSize(320, 260)
        nsPanel:SetPoint("TOPRIGHT", host, "TOPRIGHT", -6, -34)
        nsPanel:SetFrameLevel(host:GetFrameLevel() + 20)
        VWB.Theme:Register(nsPanel, "Panel")

        local search = VWB.UI:CreateSearchBox(nsPanel, {
            width = 300, height = 22, placeholder = "Search craftable items...",
            onChange = function(text) stockSearch(text or "") end,
        })
        search:SetPoint("TOP", 0, -8)

        local hint = nsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOM", 0, 6)
        VWB.Theme:Register(hint, "DimLabel")
        -- The picker serves TWO flows: new stock project (header button) and
        -- add-piece-to-commission (the pieces list row) -- the hint names which
        R.bindText(hint, function()
            if addPieceTarget() then return "Click a recipe to add it as a piece" end
            return "Click a recipe to track it (par 20, adjust on the card)"
        end)

        local listHost = CreateFrame("Frame", nil, nsPanel)
        listHost:SetPoint("TOPLEFT", 10, -36); listHost:SetPoint("BOTTOMRIGHT", -10, 22)
        local list = VWB.UI:CreateVirtualizedList(listHost, {
            rowHeight = 20,
            rowTemplate = function(f)
                f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                f.name:SetPoint("LEFT", 4, 0); f.name:SetPoint("RIGHT", -80, 0)
                f.name:SetJustifyH("LEFT"); f.name:SetWordWrap(false)
                f.prof = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                f.prof:SetPoint("RIGHT", -4, 0); f.prof:SetJustifyH("RIGHT")
            end,
            updateRow = function(row, r)
                row.name:SetText(r.name)
                row.prof:SetText(r.profession or "")
            end,
            onRowClick = function(r)
                local target = R.untrack(addPieceTarget)
                if target then -- "+ Add piece" opened the picker for an existing commission
                    -- collect, NOT stock: a commission piece is a one-shot goal
                    -- (a stock piece never stamps completedAt and would block
                    -- the commission from ever completing -- UX review M1)
                    VWB.Store:Dispatch("ADD_PIECE", { projectId = target,
                        piece = { itemID = r.itemID, recipeID = r.recipeID, kind = "collect" } })
                    VWB.Log:Print("Added piece: " .. r.name)
                else
                    VWB.Store:Dispatch("ADD_PROJECT", {
                        name = r.name, source = { type = "manual" },
                        pieces = { { itemID = r.itemID, recipeID = r.recipeID, kind = "stock", par = 20 } },
                    })
                    selectedId(ns.Store:GetState().projects.nextId - 1) -- the id ADD_PROJECT just assigned
                    VWB.Log:Print("Tracking stock: " .. r.name .. " (par 20)")
                end
                newStockOpen(false)
            end,
        })
        R.effect(function() list:SetData(stockMatches()) end, "projects:stockMatches")
        R.bindShown(nsPanel, newStockOpen)
    end

    local function makeFrame(node, parent)
        if node.id == "prjNewStock" then
            local btn = VWB.UI:CreateButton(parent, "New Stock Project", 150, 22)
            btn:SetScript("OnClick", function()
                addPieceTarget(nil) -- header button always creates a NEW commission
                newStockOpen(not R.untrack(newStockOpen))
            end)
            return btn
        elseif node.id == "prjRailSeg" then
            return VWB.UI:CreateSegmentedToggle(parent, {
                width = CARD_W, height = 22,
                segments = SEGMENTS, default = "bench",
                onSelect = function(key) railSeg(key) end })
        elseif node.id == "prjRail" then
            -- Vertical card rail (2026-07-11: was a horizontal strip across
            -- the top -- fine at 5 projects, unusable at 20).
            local host = CreateFrame("Frame", nil, parent)
            stripScroll = CreateFrame("Frame", nil, host, "WowScrollBox")
            stripScroll:SetAllPoints()
            stripContent = CreateFrame("Frame", nil, stripScroll)
            stripContent.scrollable = true -- WowScrollBox contract: exactly one scrollable child
            stripContent:SetSize(CARD_W, 1)
            local view = CreateScrollBoxLinearView()
            view:SetPanExtent(CARD_H + CARD_GAP)
            stripScroll:Init(view)
            return host
        elseif node.id == "prjQueueBtn" then
            local btn = VWB.UI:CreateButton(parent, "Queue ready (this char)", 170, 20)
            btn:SetScript("OnClick", function()
                local e = R.untrack(selectedEntry)
                if not e then return end -- exception(nullable): click raced a removal
                local i = effectivePiece(e)
                local piecePlans = i and { e.plan.pieces[i] } or e.plan.pieces
                local current, n = VWB.CharacterData:GetCharacterKey(), 0
                for _, pp in ipairs(piecePlans) do
                    for _, st in ipairs(pp.steps) do
                        if st.kind == "CRAFT" and st.ready and st.charKey == current then
                            VWB.Store:Dispatch("ADD_TO_QUEUE", { recipeID = st.recipeID, qty = st.need, charKey = current })
                            n = n + 1
                        end
                    end
                end
                VWB.Log:Print(n > 0 and ("Queued " .. n .. " ready step(s)") or "No steps are ready for this character")
            end)
            return btn
        elseif node.id == "prjBuysBtn" then
            local btn = VWB.UI:CreateButton(parent, "Send buys to Auctionator", 180, 20)
            btn:SetScript("OnClick", function()
                local e = R.untrack(selectedEntry)
                if not e then return end -- exception(nullable): click raced a removal
                local i = effectivePiece(e)
                local piecePlans = i and { e.plan.pieces[i] } or e.plan.pieces
                local rows = {}
                for _, pp in ipairs(piecePlans) do
                    for _, st in ipairs(pp.steps) do
                        if st.kind == "BUY" then rows[#rows + 1] = { itemID = st.itemID, missing = st.need } end
                    end
                end
                VWB.AuctionatorBridge:SendShortfall(rows)
            end)
            return btn
        elseif node.id == "prjSteps" then
            -- THE TREE (design-lab E): one mixed-row list -- piece headers
            -- with their executable steps beneath. No drill-in, no back
            -- button; the tasks are always visible (owner ruling).
            local host = CreateFrame("Frame", nil, parent)
            stepsList = VWB.UI:CreateVirtualizedList(host, {
                rowHeight = 26,
                rowTemplate = function(f)
                    stepRowTemplate(f) -- the step widgets (chip/name/who/queued/action)
                    -- header widgets overlay the same pooled frame. Expand and
                    -- remove are child BUTTONS: they capture their own clicks
                    -- before the row's select handler.
                    f.hExpand = CreateFrame("Button", nil, f)
                    f.hExpand:SetSize(18, 22); f.hExpand:SetPoint("LEFT", 2, 0)
                    f.hExpand.txt = f.hExpand:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    f.hExpand.txt:SetPoint("CENTER")
                    f.hExpand:SetScript("OnClick", function(self)
                        local r = f.data
                        local nxt = {}
                        for k, v in pairs(expandCollapsed()) do nxt[k] = v end
                        if nxt[r.piece.id] then nxt[r.piece.id] = nil else nxt[r.piece.id] = true end
                        expandCollapsed(nxt)
                    end)
                    f.hIcon = f:CreateTexture(nil, "ARTWORK"); f.hIcon:SetSize(18, 18)
                    f.hIcon:SetPoint("LEFT", 22, 0)
                    f.hStatus = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    f.hStatus:SetPoint("RIGHT", -24, 0); f.hStatus:SetWidth(150); f.hStatus:SetJustifyH("RIGHT")
                    f.hStatus:SetWordWrap(false); f.hStatus:SetMaxLines(1)
                    f.hName = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    f.hName:SetPoint("LEFT", f.hIcon, "RIGHT", 6, 0)
                    f.hName:SetPoint("RIGHT", f.hStatus, "LEFT", -8, 0)
                    f.hName:SetJustifyH("LEFT"); f.hName:SetWordWrap(false); f.hName:SetMaxLines(1)
                    f.hRemove = CreateFrame("Button", nil, f)
                    f.hRemove:SetSize(16, 22); f.hRemove:SetPoint("RIGHT", -4, 0)
                    f.hRemove.txt = f.hRemove:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    f.hRemove.txt:SetPoint("CENTER"); f.hRemove.txt:SetText("x")
                    f.hRemove:SetScript("OnClick", function()
                        local r = f.data
                        StaticPopup_Show("VWB_REMOVE_PIECE", r.name, nil,
                            { projectId = r.projectId, pieceId = r.piece.id })
                    end)
                end,
                updateRow = function(row, r)
                    local s = VWB.UI:GetScheme()
                    local isHdr = r.pieceHdr or r.addRow
                    -- one pooled frame serves three row kinds: hide the other set
                    row.chip:SetShown(not isHdr); row.name:SetShown(not isHdr)
                    row.who:SetShown(not isHdr); row.queued:SetShown(not isHdr)
                    row.action:SetShown(false)
                    row.hExpand:SetShown(r.pieceHdr or false); row.hIcon:SetShown(isHdr or false)
                    row.hName:SetShown(isHdr or false); row.hStatus:SetShown(r.pieceHdr or false)
                    row.hRemove:SetShown((r.pieceHdr and r.removable) or false)
                    if r.addRow then
                        row.hIcon:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
                        row.hName:SetText("Add piece...")
                        row.hName:SetTextColor(s.accent.r, s.accent.g, s.accent.b)
                        return
                    end
                    if r.pieceHdr then
                        row.hExpand.txt:SetText(r.expanded and "-" or "+")
                        row.hExpand.txt:SetTextColor(s.accent.r, s.accent.g, s.accent.b)
                        row.hIcon:SetTexture((r.piece.itemID and C_Item.GetItemIconByID(r.piece.itemID)) or ICON_FALLBACK)
                        row.hName:SetText(r.name)
                        if r.selected then
                            row.hName:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
                        else
                            row.hName:SetTextColor(s.text_header.r, s.text_header.g, s.text_header.b)
                        end
                        row.hRemove.txt:SetTextColor(s.error.r, s.error.g, s.error.b)
                        local pp = r.piecePlan
                        if pp.status == "complete" then
                            row.hStatus:SetText("done"); row.hStatus:SetTextColor(s.success.r, s.success.g, s.success.b)
                        elseif r.piece.kind == "stock" then
                            local c = pp.status == "dormant" and s.success or s.warning
                            row.hStatus:SetText(string.format("par %d -- %d on hand", pp.par or 1, pp.level or 0))
                            row.hStatus:SetTextColor(c.r, c.g, c.b)
                        elseif pp.unresolved then
                            row.hStatus:SetText("recipe not scanned"); row.hStatus:SetTextColor(s.text.r, s.text.g, s.text.b)
                        else
                            row.hStatus:SetText(string.format("%d/%d steps", pp.done, pp.total))
                            row.hStatus:SetTextColor(s.text.r, s.text.g, s.text.b)
                        end
                        row:SetAlpha(1)
                        return
                    end
                    paintStepRow(row, r)
                    if not r._canWork then row.action:SetShown(false) end -- ruling 6A: execution is Active-only
                    row:SetAlpha(r._dim and 0.45 or 1)
                end,
                onRowClick = function(r)
                    if r.addRow then
                        addPieceTarget(r.projectId)
                        newStockOpen(true)
                    elseif r.pieceHdr then
                        -- body click = SELECT toggle (expand/remove are child buttons)
                        selectedPiece(selectedPiece() == r.piece.id and nil or r.piece.id)
                    end
                end,
                onRowEnter = function(r, rowFrame)
                    if not r.pieceHdr and not r.addRow then onStepRowEnter(r, rowFrame) end
                end,
            })
            return host
        elseif node.id == "prjMats" then
            local host = CreateFrame("Frame", nil, parent)
            matsList = VWB.UI:CreateVirtualizedList(host, {
                rowHeight = 20, rowTemplate = matRowTemplate, updateRow = paintMatRow,
            })
            return host
        end
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.projects, { makeFrame = makeFrame, measure = Kit.measure })

    -- Overlays live INSIDE the view tree (the shared shell container renders
    -- across tabs -- same leak class as Study's commission button, 2026-07-12)
    local viewRoot = handle.byId.prjBoard:GetParent()
    buildNewStockPanel(viewRoot)

    emptyCard = VWB.UI:CreateEmptyStateCard(viewRoot, {
        title = "Plan your collection",
        body = "Start a commission from the Showroom (pin an item), the Achieve tab (profession achievements), or Study (a vendor's recipes). Mats, prices, and which alt crafts each step appear here.",
        buttonText = "Showroom",
        onClick = function() ns.Nav.Go("showroom") end,
        width = 420, height = 170,
    })
    emptyCard:SetPoint("CENTER", viewRoot, "CENTER", 0, 10)
    -- all three importers get a quick action (UX review M3: the flagship
    -- Achieve importer was invisible from the board's own onboarding)
    emptyCard.button:SetWidth(110)
    emptyCard.button:ClearAllPoints()
    emptyCard.button:SetPoint("BOTTOMLEFT", 52, 14)
    local achQuick = VWB.UI:CreateButton(emptyCard, "Achievements", 110, 24)
    achQuick:SetPoint("LEFT", emptyCard.button, "RIGHT", 8, 0)
    achQuick:SetScript("OnClick", function() ns.Nav.Go("achieve") end)
    local studyQuick = VWB.UI:CreateButton(emptyCard, "Study", 80, 24)
    studyQuick:SetPoint("LEFT", achQuick, "RIGHT", 8, 0)
    studyQuick:SetScript("OnClick", function() ns.Nav.Go("study") end)

    -- The Plan/Materials scope follows the drill state: State B = the piece's
    -- own plan; State A = the commission aggregate.
    local function currentScope()
        local e = selectedEntry()
        if not e then return nil end
        local i = effectivePiece(e)
        return e, i, i and e.plan.pieces[i] or e.plan
    end

    -- (No separate clear-filter button: clicking the selected piece header
    -- again deselects, and the label's "-- <piece> only" suffix carries the
    -- state. A button here overlapped the label -- live 2026-07-12.)
    R.bindText(handle.byId.prjPlanLabel.label, function()
        local e = selectedEntry()
        if not e then return "Plan" end -- exception(nullable): no selection
        local txt = string.format("%s  (%d/%d done)", e.p.name, e.plan.done, e.plan.total)
        local i = effectivePiece(e)
        if i then
            txt = txt .. "  --  " .. liveName(e.p.pieces[i].itemID, e.p.pieces[i].name) .. " only"
        end
        if e.p.status == "backlog" then
            txt = txt .. "   " .. ns.UI:ColorCode("yellow") .. "Backlog -- move to Active to work it|r"
        elseif e.p.status == "done" then
            txt = txt .. "   " .. ns.UI:ColorCode("green") .. "Done|r"
        end
        return txt
    end)

    -- Ruling 6A: execution is Active-only -- the same rule the reducer
    -- enforces, rendered as disabled bulk buttons.
    R.effect(function()
        local e = selectedEntry()
        local can = (e ~= nil and e.p.status == "bench") or false
        handle.byId.prjQueueBtn:SetEnabled(can)
        handle.byId.prjBuysBtn:SetEnabled(can)
    end, "projects:workGate")

    R.bindText(handle.byId.prjMatsLabel.label, function()
        local e, _, scope = currentScope()
        if not e then return "Sources / Materials" end -- exception(nullable): no selection
        if scope.buyCost > 0 then
            return string.format("Sources / Materials  (%d short, %s)", scope.matsShort, VWB.UI:FormatMoney(scope.buyCost))
        end
        if scope.matsShort > 0 then
            return string.format("Sources / Materials  (%d short)", scope.matsShort)
        end
        return "Sources / Materials"
    end)

    -- title carries the board summary
    R.bindText(handle.byId.prjTitle.label, function()
        local ps = plans()
        return string.format("Projects  (%d active, %d backlog, %d done)",
            #ps.bench, #ps.backlog, #ps.done)
    end)

    local function hasProjects()
        local ps = plans()
        return (#ps.bench + #ps.backlog + #ps.done) > 0
    end
    R.bindShown(emptyCard, function() return not hasProjects() end)
    R.bindShown(handle.byId.prjBoard, hasProjects)

    -- keep a valid selection: first board card when none/stale (write-once guard
    -- so the effect converges instead of re-firing on its own signal write)
    R.effect(function()
        local ps = plans()
        if selectedEntry() == nil then
            local first = ps.bench[1] or ps.backlog[1] or ps.done[1]
            if first and selectedId() ~= first.p.id then selectedId(first.p.id) end
        end
    end, "projects:autoselect")

    -- leaving a project resets the piece drill (converges: writing nil twice
    -- is a value no-op)
    R.effect(function()
        selectedId()
        if R.untrack(selectedPiece) ~= nil then selectedPiece(nil) end -- untracked: subscribing our own write costs a redundant second flush
    end, "projects:pieceReset")

    -- cross-view select handoff (Showroom's Start Project -> Nav.Go("projects", {select=id})).
    -- pendingSelect is view-scoped {view, value}: only consume our own payloads.
    R.effect(function()
        local p = ns.Nav.pendingSelect()
        if p ~= nil and p.view == "projects" then
            ns.Nav.pendingSelect(nil)
            selectedId(p.value)
        end
    end, "projects:pendingSelect")

    -- the card rail: ONE segment at a time (Backlog | Active | Done toggle
    -- above it) -- each status gets the full rail height (design-lab E)
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled card rows on switch
        local ps = plans()
        local sel = selectedId()
        local group = ps[railSeg()]
        VWB.UI:ResetRows(stripContent)
        local y = 0
        for _, e in ipairs(group) do
            local card = VWB.UI:AcquireRow(stripContent, "prjcard", function(p) return createProjectCard(p, selectedId) end)
            card:SetPoint("TOPLEFT", stripContent, "TOPLEFT", 0, -y)
            paintProjectCard(card, e, e.p.id == sel)
            y = y + CARD_H + CARD_GAP
        end
        VWB.UI:HideUnusedRows(stripContent)
        stripContent:SetHeight(math.max(1, y))
        stripScroll:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end, "projects:strip")

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled step/mat rows on switch
        ns.Store:Version("crafting") -- queue edits repaint the "queued xN" step chips
        local e, pieceIdx, scope = currentScope()
        -- Names resolve through nameRes INSIDE this tracked effect: a cold row
        -- subscribes its key, and the load result re-runs the effect with the
        -- real name -- no manual re-derive plumbing.
        -- SOURCES / MATERIALS: mats first (actionable now), then per-piece
        -- acquisition source blocks for the scope's study pieces.
        local mats = {}
        if e then
            for _, m in ipairs(scope.mats) do mats[#mats + 1] = withLiveName(m) end
            local pieceRange = pieceIdx and { e.p.pieces[pieceIdx] } or e.p.pieces
            local blocks = {}
            for _, pc in ipairs(pieceRange) do
                if pc.kind == "study" and not pc.completedAt then
                    local desc = VWB.RecipeSources.Describe(pc.recipeID)
                    if desc and #desc.lines > 0 then
                        blocks[#blocks + 1] = { pc = pc, lines = desc.lines }
                    end
                end
            end
            if #blocks > 0 then
                if #mats > 0 then
                    table.insert(mats, 1, { kind = "hdr", label = "Materials" })
                    mats[#mats + 1] = { kind = "hdr", label = "Sources" }
                end
                for _, b in ipairs(blocks) do
                    if #blocks > 1 then
                        mats[#mats + 1] = { kind = "hdr", label = liveName(b.pc.itemID, b.pc.name) }
                    end
                    for _, ln in ipairs(b.lines) do
                        mats[#mats + 1] = { kind = "src", line = ln }
                    end
                end
            end
        end
        matsList:SetData(mats)

        -- THE TREE: piece headers with their steps beneath, in ONE list.
        -- Step rows are always fresh copies (the derived plan rows are shared
        -- computed values -- never mutate them with row-local flags).
        local rows = {}
        if e then
            local canWork = e.p.status == "bench"
            local collapsed = expandCollapsed()
            local selId = selectedPiece()
            local removable = e.p.status ~= "done" -- sealed
            for i, pc in ipairs(e.p.pieces) do
                local pp = e.plan.pieces[i]
                local expanded = not collapsed[pc.id]
                rows[#rows + 1] = { pieceHdr = true, piece = pc, piecePlan = pp,
                    name = liveName(pc.itemID, pc.name), expanded = expanded,
                    selected = selId == pc.id, removable = removable, projectId = e.p.id }
                if expanded then
                    for _, st in ipairs(pp.steps) do
                        local r = {}
                        for k, v in pairs(st) do r[k] = v end
                        r.name = liveName(st.itemID, st.name)
                        r._canWork = canWork
                        r._dim = selId ~= nil and selId ~= pc.id
                        rows[#rows + 1] = r
                    end
                end
            end
            if #e.p.pieces < VWB.Constants.Projects.MAX_PIECES and e.p.status ~= "done" then
                rows[#rows + 1] = { addRow = true, projectId = e.p.id }
            end
        end
        stepsList:SetData(rows)
    end, "projects:detail")

    return handle
end

return Projects
