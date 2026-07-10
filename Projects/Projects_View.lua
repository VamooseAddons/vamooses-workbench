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

local CARD_W, CARD_H, CARD_GAP = 210, 64, 6
local STRIP_H = CARD_H + 6
local MATS_W = 380

StaticPopupDialogs["VWB_REMOVE_PROJECT"] = {
    text = "Remove project '%s'?",
    button1 = "Remove", button2 = "Cancel",
    OnAccept = function(self, id) VWB.Store:Dispatch("REMOVE_PROJECT", { id = id }) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ============================================================================
-- Project card (pooled via VWB.UI:AcquireRow on the horizontal strip)
-- ============================================================================

local function bumpPar(card, delta)
    local e = card.entry
    local step = IsShiftKeyDown() and 5 or 1
    VWB.Store:Dispatch("SET_PROJECT_PAR", { id = e.p.id, par = math.max(1, (e.p.par or 1) + delta * step) })
end

local function cardTooltip(card)
    local e = card.entry
    local T = VWB.UI.Tooltip
    T:Begin(card, "RIGHT")
    T:AddTitle(e.p.name)
    if e.p.kind == "stock" then
        T:AddLine(string.format("Stock project -- keep %d on hand (%d now)", e.plan.par, e.plan.level))
        if (e.p.refills or 0) > 0 then T:AddLine("Refilled " .. e.p.refills .. "x") end
    elseif e.plan.status == "complete" then
        T:AddLine("Completed " .. VWB.UI:FormatScannedAgo(e.p.completedAt, time()))
    else
        T:AddLine(string.format("Collect project -- %d of %d steps covered", e.plan.done, e.plan.total))
    end
    if e.plan.unresolved then T:AddLine("Recipe not on file yet -- scan a profession") end
    if e.plan.buyCost > 0 then T:AddLine("Missing mats on the AH: " .. VWB.UI:FormatMoney(e.plan.buyCost)) end
    T:AddLine("Right-click to remove")
    T:Show()
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

    card:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            StaticPopup_Show("VWB_REMOVE_PROJECT", self.entry.p.name, nil, self.entry.p.id)
        else
            onSelect(self.entry.p.id)
        end
    end)
    card:SetScript("OnEnter", cardTooltip)
    card:SetScript("OnLeave", function(self) VWB.UI.Tooltip:Hide(self) end)
    return card
end

local function paintProjectCard(card, entry, isSelected)
    local s = VWB.UI:GetScheme()
    local p, plan = entry.p, entry.plan
    card.entry = entry

    card.icon:SetTexture(C_Item.GetItemIconByID(p.itemID) or ICON_FALLBACK)
    card.name:SetText(p.name)
    local d = VWB.Constants:GetDerivedColors(s)
    card:SetBackdropColor(s.panel.r, s.panel.g, s.panel.b, s.panel.a)
    if isSelected then
        card:SetBackdropBorderColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 1) -- selection identity from scheme
    else
        card:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, s.border.a)
    end

    local showSteppers = p.kind == "stock" and plan.status ~= "complete"
    card.minus:SetShown(showSteppers)
    card.plus:SetShown(showSteppers)

    if p.kind == "stock" then
        card.bar:SetProgress(plan.level, plan.par)
        if plan.status == "dormant" then
            card.sub:SetText(string.format("par %d -- stocked", plan.par))
            card.sub:SetTextColor(s.success.r, s.success.g, s.success.b)
        else
            card.sub:SetText(string.format("par %d -- %d on hand", plan.par, plan.level))
            card.sub:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
        end
    elseif plan.status == "complete" then
        card.bar:SetProgress(1, 1)
        card.sub:SetText("collected " .. VWB.UI:FormatScannedAgo(p.completedAt, time()))
        card.sub:SetTextColor(s.success.r, s.success.g, s.success.b)
    elseif plan.unresolved then
        card.bar:SetProgress(0, 1)
        card.sub:SetText("recipe not scanned yet")
        card.sub:SetTextColor(s.text.r, s.text.g, s.text.b)
    else
        card.bar:SetProgress(plan.done, plan.total)
        card.sub:SetText(string.format("%d/%d steps", plan.done, plan.total))
        card.sub:SetTextColor(s.text.r, s.text.g, s.text.b)
    end

    local dim = plan.status ~= "active"
    card:SetAlpha(dim and 0.5 or 1)
end

-- ============================================================================
-- Steps rows (pooled by CreateVirtualizedList)
-- ============================================================================

local CHIP = { -- text + scheme color key per step kind; CRAFT resolves by readiness
    BUY = { text = "BUY", color = "accent" }, FARM = { text = "FARM", color = "text" },
    STAGE = { text = "STAGE", color = "warning" }, BLOCKED = { text = "NO ALT", color = "error" },
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

    frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.name:SetPoint("LEFT", frame.chip, "RIGHT", 4, 0)
    frame.name:SetPoint("RIGHT", frame.who, "LEFT", -6, 0)
    frame.name:SetJustifyH("LEFT"); frame.name:SetWordWrap(false)
end

local function paintStepRow(row, st)
    local s = VWB.UI:GetScheme()
    local current = VWB.CharacterData:GetCharacterKey()

    if st.kind == "CRAFT" then
        local c = st.done and s.text_header or (st.ready and s.success or s.text)
        row.chip:SetText("CRAFT"); row.chip:SetTextColor(c.r, c.g, c.b)
        row.name:SetText(st.done and (st.name .. "  (done)") or string.format("%dx %s", st.need, st.name))
        row.who:SetText(VWB.ProjectPlanner:DisplayName(st.charKey) .. (st.pinned and " *" or ""))
        row.action:SetText("Queue")
        row.action:SetShown(st.ready and st.charKey == current)
    else
        local chip = CHIP[st.kind]
        local c = s[chip.color]
        row.chip:SetText(chip.text); row.chip:SetTextColor(c.r, c.g, c.b)
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
        T:AddLine("Known by: " .. table.concat(names, ", "))
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

local function matRowTemplate(frame)
    frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.name:SetPoint("LEFT", 4, 0); frame.name:SetWidth(190); frame.name:SetJustifyH("LEFT"); frame.name:SetWordWrap(false)
    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.count:SetPoint("LEFT", frame.name, "RIGHT", 6, 0); frame.count:SetWidth(70); frame.count:SetJustifyH("RIGHT")
    frame.price = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.price:SetPoint("RIGHT", -4, 0); frame.price:SetJustifyH("RIGHT")
end

local function paintMatRow(row, m)
    local s = VWB.UI:GetScheme()
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

local function sortRank(e) -- below-par stock floats, collect by progress, dormant sinks
    if e.plan.status == "active" and e.p.kind == "stock" then return 1 end
    if e.plan.status == "active" then return 2 end
    return 3
end

function Projects.buildView(container)
    local R = ns.Reactor
    local Kit = ns.ViewKit

    local selectedId = R.signal(nil)
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
    local function withLiveName(row)
        local resolved = liveName(row.itemID, row.name)
        if resolved == row.name then return row end
        return setmetatable({ name = resolved }, { __index = row })
    end

    -- goal list -> derived plans, split active/shelf, board-sorted
    local plans = R.named("projects:plans", function()
        ns.Store:Version("projects"); ns.Store:Version("corpus"); ns.Store:Version("characters")
        invEpoch()
        local active, shelf = {}, {}
        for _, p in ipairs(ns.Store:GetState().projects.items) do
            local e = { p = p, plan = VWB.ProjectPlanner:DerivePlan(p) }
            if e.plan.status == "complete" then shelf[#shelf + 1] = e else active[#active + 1] = e end
        end
        table.sort(active, function(a, b)
            local ra, rb = sortRank(a), sortRank(b)
            if ra ~= rb then return ra < rb end
            if a.plan.total ~= 0 and b.plan.total ~= 0 then
                local pa, pb = a.plan.done / a.plan.total, b.plan.done / b.plan.total
                if pa ~= pb then return pa > pb end
            end
            return a.p.id < b.p.id
        end)
        table.sort(shelf, function(a, b) return (a.p.completedAt or 0) > (b.p.completedAt or 0) end)
        return { active = active, shelf = shelf }
    end)

    local selectedEntry = R.named("projects:selected", function()
        local id = selectedId()
        if id == nil then return nil end -- exception(nullable): nothing selected yet
        local ps = plans()
        for _, e in ipairs(ps.active) do if e.p.id == id then return e end end
        for _, e in ipairs(ps.shelf) do if e.p.id == id then return e end end
        return nil -- exception(nullable): selection outlived its project (removed)
    end)

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

    local root, stripScroll, stripContent, emptyCard, detailHost, stepsList, matsList, nsPanel

    local function buildStrip()
        root.stripHost = CreateFrame("Frame", nil, root)
        root.stripHost:SetPoint("TOPLEFT", 0, 0)
        root.stripHost:SetHeight(STRIP_H)
        stripScroll = CreateFrame("Frame", nil, root.stripHost, "WowScrollBox")
        stripScroll:SetAllPoints()
        stripContent = CreateFrame("Frame", nil, stripScroll)
        stripContent.scrollable = true -- WowScrollBox contract: exactly one scrollable child
        stripContent:SetSize(1, STRIP_H)
        local view = CreateScrollBoxLinearView()
        view:SetHorizontal(true)
        view:SetPanExtent(CARD_W + CARD_GAP)
        stripScroll:Init(view)
    end

    local function buildDetail()
        detailHost = CreateFrame("Frame", nil, root)
        detailHost:SetPoint("TOPLEFT", root.stripHost, "BOTTOMLEFT", 0, -8)
        detailHost:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)

        local matsPanel = VWB.UI:CreatePanel(detailHost)
        matsPanel:SetPoint("TOPRIGHT", 0, 0); matsPanel:SetPoint("BOTTOMRIGHT", 0, 0); matsPanel:SetWidth(MATS_W)
        local stepsPanel = VWB.UI:CreatePanel(detailHost)
        stepsPanel:SetPoint("TOPLEFT", 0, 0); stepsPanel:SetPoint("BOTTOMLEFT", 0, 0)
        stepsPanel:SetPoint("RIGHT", matsPanel, "LEFT", -8, 0)

        local stepsHdr = stepsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        stepsHdr:SetPoint("TOPLEFT", 10, -8); stepsHdr:SetText("Plan")
        local btnBuys = VWB.UI:CreateButton(stepsPanel, "Send buys to Auctionator", 180, 20)
        btnBuys:SetPoint("TOPRIGHT", -8, -6)
        local btnQueue = VWB.UI:CreateButton(stepsPanel, "Queue ready (this char)", 170, 20)
        btnQueue:SetPoint("RIGHT", btnBuys, "LEFT", -6, 0)

        btnQueue:SetScript("OnClick", function()
            local e = R.untrack(selectedEntry)
            if not e then return end -- exception(nullable): click raced a removal
            local current, n = VWB.CharacterData:GetCharacterKey(), 0
            for _, st in ipairs(e.plan.steps) do
                if st.kind == "CRAFT" and st.ready and st.charKey == current then
                    VWB.Store:Dispatch("ADD_TO_QUEUE", { recipeID = st.recipeID, qty = st.need, charKey = current })
                    n = n + 1
                end
            end
            VWB.Log:Print(n > 0 and ("Queued " .. n .. " ready step(s)") or "No steps are ready for this character")
        end)
        btnBuys:SetScript("OnClick", function()
            local e = R.untrack(selectedEntry)
            if not e then return end -- exception(nullable): click raced a removal
            local rows = {}
            for _, st in ipairs(e.plan.steps) do
                if st.kind == "BUY" then rows[#rows + 1] = { itemID = st.itemID, missing = st.need } end
            end
            VWB.AuctionatorBridge:SendShortfall(rows)
        end)

        local stepsHost = CreateFrame("Frame", nil, stepsPanel)
        stepsHost:SetPoint("TOPLEFT", 6, -30); stepsHost:SetPoint("BOTTOMRIGHT", -6, 6)
        stepsList = VWB.UI:CreateVirtualizedList(stepsHost, {
            rowHeight = 26, rowTemplate = stepRowTemplate, updateRow = paintStepRow, onRowEnter = onStepRowEnter,
        })

        local matsHdr = matsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        matsHdr:SetPoint("TOPLEFT", 10, -8)
        matsPanel.hdr = matsHdr
        local matsHost = CreateFrame("Frame", nil, matsPanel)
        matsHost:SetPoint("TOPLEFT", 6, -30); matsHost:SetPoint("BOTTOMRIGHT", -6, 6)
        matsList = VWB.UI:CreateVirtualizedList(matsHost, {
            rowHeight = 20, rowTemplate = matRowTemplate, updateRow = paintMatRow,
        })

        R.bindText(matsHdr, function()
            local e = selectedEntry()
            if not e then return "Materials" end -- exception(nullable): no selection
            if e.plan.buyCost > 0 then
                return string.format("Materials  (%d short, %s)", e.plan.matsShort, VWB.UI:FormatMoney(e.plan.buyCost))
            end
            return string.format("Materials  (%d short)", e.plan.matsShort)
        end)
    end

    -- compact picker: search the harvested corpus, click = track at par 20
    local function buildNewStockPanel()
        nsPanel = CreateFrame("Frame", nil, root, "BackdropTemplate")
        nsPanel:SetBackdrop(FLAT)
        local s = VWB.UI:GetScheme()
        nsPanel:SetBackdropColor(s.panel.r, s.panel.g, s.panel.b, 0.98)
        nsPanel:SetBackdropBorderColor(s.border.r, s.border.g, s.border.b, 1)
        nsPanel:SetSize(320, 260)
        nsPanel:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -2)
        nsPanel:SetFrameLevel(root:GetFrameLevel() + 20)
        VWB.Theme:Register(nsPanel, "Panel")

        local search = VWB.UI:CreateSearchBox(nsPanel, {
            width = 300, height = 22, placeholder = "Search a craftable consumable...",
            onChange = function(text) stockSearch(text or "") end,
        })
        search:SetPoint("TOP", 0, -8)

        local hint = nsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOM", 0, 6)
        hint:SetText("Click a recipe to track it (par 20, adjust on the card)")
        VWB.Theme:Register(hint, "DimLabel")

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
                VWB.Store:Dispatch("ADD_PROJECT", {
                    name = r.name, itemID = r.itemID, recipeID = r.recipeID, kind = "stock", par = 20,
                })
                newStockOpen(false)
                selectedId(ns.Store:GetState().projects.nextId - 1) -- the id ADD_PROJECT just assigned
                VWB.Log:Print("Tracking stock: " .. r.name .. " (par 20)")
            end,
        })
        R.effect(function() list:SetData(stockMatches()) end, "projects:stockMatches")
        R.bindShown(nsPanel, newStockOpen)
    end

    local function makeFrame(node, parent)
        if node.id == "prjBody" then
            root = CreateFrame("Frame", nil, parent)
            return root
        elseif node.id == "prjNewStock" then
            local btn = VWB.UI:CreateButton(parent, "New Stock Project", 150, 22)
            btn:SetScript("OnClick", function() newStockOpen(not R.untrack(newStockOpen)) end)
            return btn
        end
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.projects, { makeFrame = makeFrame, measure = Kit.measure })

    root.stripHost = nil -- set in buildStrip; declared for clarity
    buildStrip()
    root.stripHost:SetWidth(root:GetWidth()) -- root already sized by Layout.build (Roster pattern)
    buildDetail()
    buildNewStockPanel()

    emptyCard = VWB.UI:CreateEmptyStateCard(root, {
        title = "Plan your collection",
        body = "Pin an uncollected item from the Showroom and the plan appears here -- mats, prices, and which alt crafts each step. Track it to done.",
        buttonText = "Browse the Showroom",
        onClick = function() ns.Nav.Go("showroom") end,
        width = 420, height = 170,
    })
    emptyCard:SetPoint("CENTER", root, "CENTER", 0, 10)

    -- title carries the board summary; the shelf lives at the end of the strip
    R.bindText(handle.byId.prjTitle.label, function()
        local ps = plans()
        if #ps.shelf > 0 then
            return string.format("Projects  (%d active, %d done)", #ps.active, #ps.shelf)
        end
        return string.format("Projects  (%d active)", #ps.active)
    end)

    local function hasProjects()
        local ps = plans()
        return (#ps.active + #ps.shelf) > 0
    end
    R.bindShown(emptyCard, function() return not hasProjects() end)
    R.bindShown(root.stripHost, hasProjects)
    R.bindShown(detailHost, function() return hasProjects() and selectedEntry() ~= nil end)

    -- keep a valid selection: first board card when none/stale (write-once guard
    -- so the effect converges instead of re-firing on its own signal write)
    R.effect(function()
        local ps = plans()
        if selectedEntry() == nil then
            local first = ps.active[1] or ps.shelf[1]
            if first and selectedId() ~= first.p.id then selectedId(first.p.id) end
        end
    end, "projects:autoselect")

    -- cross-view select handoff (Showroom's Start Project -> Nav.Go("projects", {select=id})).
    -- pendingSelect is view-scoped {view, value}: only consume our own payloads.
    R.effect(function()
        local p = ns.Nav.pendingSelect()
        if p ~= nil and p.view == "projects" then
            ns.Nav.pendingSelect(nil)
            selectedId(p.value)
        end
    end, "projects:pendingSelect")

    -- the card strip: active board first, trophy shelf dimmed at the end
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled card rows on switch
        local ps = plans()
        local sel = selectedId()
        VWB.UI:ResetRows(stripContent)
        local i = 0
        local function place(e)
            i = i + 1
            local card = VWB.UI:AcquireRow(stripContent, "prjcard", function(p) return createProjectCard(p, selectedId) end)
            card:SetPoint("TOPLEFT", stripContent, "TOPLEFT", (i - 1) * (CARD_W + CARD_GAP), 0)
            paintProjectCard(card, e, e.p.id == sel)
        end
        for _, e in ipairs(ps.active) do place(e) end
        for _, e in ipairs(ps.shelf) do place(e) end
        VWB.UI:HideUnusedRows(stripContent)
        stripContent:SetWidth(math.max(1, i * (CARD_W + CARD_GAP)))
        stripScroll:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end, "projects:strip")

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled step/mat rows on switch
        local e = selectedEntry()
        -- Names resolve through nameRes INSIDE this tracked effect: a cold row
        -- subscribes its key, and the load result re-runs the effect with the
        -- real name -- no manual re-derive plumbing.
        local steps, mats = {}, {}
        if e then
            for i, st in ipairs(e.plan.steps) do steps[i] = withLiveName(st) end
            for i, m in ipairs(e.plan.mats) do mats[i] = withLiveName(m) end
        end
        stepsList:SetData(steps)
        matsList:SetData(mats)
    end, "projects:detail")

    return handle
end

return Projects
