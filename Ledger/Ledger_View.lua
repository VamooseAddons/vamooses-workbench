-- ============================================================================
-- VWB Ledger (Profit) - VIEW / controller. Slice: real profit table + KPIs.
-- ============================================================================
-- Ports VPC's Profit tab (VamoosePowerCrafter/UI/Tabs/Profit.lua) onto the
-- Reactor + box-model pattern: a KPI strip (session profit / gold-per-hour /
-- average margin) over structured filters, a searchable/sortable profit
-- table, and a bottom summary bar -- fed by ProfitCalculator:Calculate.
--
-- PERF: Calculate() walks Graph + ReagentSource + PriceIntegration per recipe
-- -- real cost, not a keystroke-safe read. So the base walk is NOT a Reactor
-- computed off Store:Version() (that would re-run the whole recipe universe
-- on every single dispatch, including unrelated ones like a craft log entry
-- or a minimap move). Instead it's a chunked build driven by a hidden
-- OnUpdate frame (same shape as VPC's BuildProfitCache, no C_Timer anywhere
-- in this file -- WoW does not tick OnUpdate on a hidden frame, so Show()/
-- Hide() IS the start/stop switch, the same idiom Reactor_WoW's own flush
-- driver uses) that writes into ONE signal (profitRows) when it completes.
-- Search + sort + the structured filters run over that already-built array
-- as a separate computed, so they're the only thing that reruns per
-- keystroke / filter click -- cheap, and decoupled from the walk entirely.
--
-- Rebuild triggers (per-slice Store signals, NOT the blanket Version() --
-- an unrelated dispatch elsewhere must never re-walk ~8600 recipes): the
-- recipe universe changing (Version("recipes") -- a guild harvest landing
-- new records) and the pricing config changing (Version("config") -- source
-- pin / AH-cut toggle), a completed AH scan (PriceIntegration's own price
-- cache is invalidated first so it doesn't hand back pre-scan misses), and
-- the "Refresh" button for the user to force one on demand. There is
-- deliberately NO periodic safety-net timer -- the explicit triggers above
-- cover every input that can move a price; a timer would just be one more
-- C_Timer this view doesn't need.
--
-- nil prices render "--" (VWB.UI:FormatMoney's own contract, and Calculate
-- already refuses to invent a profit/margin unless BOTH sides are priced) --
-- never a vendor/fake fallback.
-- ============================================================================

local _, ns = ...
local Ledger = ns.Ledger or {}
ns.Ledger = Ledger

local QUESTION_ICON = VWB.Constants.ICON_QUESTION

local CHUNK_SIZE = 250   -- recipes Calculate()'d per rendered frame while building
local SESSION_START = time()
local KPI_MIN_SECONDS = 300 -- gold/hr stays "--" below this session length (a 30s session extrapolates to absurd hourly figures)

local COL_GAP = 6
local COL_W = { sell = 100, cost = 100, profit = 100, margin = 80, sold = 70 }

local SORT_SEGMENTS = {
    { key = "profit", label = "Profit" },
    { key = "margin", label = "Margin" },
    { key = "name",   label = "Name" },
}

-- Compact unit-count formatter for the Sold/Day column (ported from VPC's
-- FormatCount): slow decor sells a fraction a day, brisk consumables sell
-- thousands.
local function formatSoldPerDay(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    if n >= 10 then return string.format("%d", math.floor(n + 0.5)) end
    return string.format("%.2f", n)
end

-- Lays out the fixed-width numeric columns right-to-left, then the flexible
-- name column filling what's left after the icon (or the left edge, for the
-- header strip, which has no icon). Shared by the header and every data row
-- so the two always line up pixel-for-pixel.
local function layoutColumns(f, icon, hasLiquidity)
    local cols = {}
    local point, rel, relPoint, x = "RIGHT", f, "RIGHT", -6
    local function addRight(key, width)
        local fs = f:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
        fs:SetWidth(width)
        fs:SetJustifyH("RIGHT")
        fs:SetPoint(point, rel, relPoint, x, 0)
        point, rel, relPoint, x = "RIGHT", fs, "LEFT", -COL_GAP
        cols[key] = fs
    end
    if hasLiquidity then addRight("sold", COL_W.sold) end
    addRight("margin", COL_W.margin)
    addRight("profit", COL_W.profit)
    addRight("cost", COL_W.cost)
    addRight("sell", COL_W.sell)

    local name = f:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
    if icon then
        name:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    else
        name:SetPoint("LEFT", f, "LEFT", 6, 0)
    end
    name:SetPoint("RIGHT", cols.sell, "LEFT", -COL_GAP, 0)
    name:SetJustifyH("LEFT")
    cols.name = name
    return cols
end

local function buildTableHeader(parent, hasLiquidity)
    local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    header:SetHeight(20)
    -- Theme:Register routes all backdrop + text color through the Skinner;
    -- no inline SetBackdropColor / SetBackdropBorderColor here (item 4 fix).
    VWB.Theme:Register(header, "Panel")

    local cols = layoutColumns(header, nil, hasLiquidity)
    cols.name:SetText("Recipe")
    cols.sell:SetText("Sell")
    cols.cost:SetText("Cost")
    cols.profit:SetText("Profit")
    cols.margin:SetText("Margin")
    if hasLiquidity then cols.sold:SetText("Sold/Day") end
    for _, fs in pairs(cols) do VWB.Theme:Register(fs, "DimLabel") end
    return header
end

local function ledgerRowTemplate(frame, hasLiquidity)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 4, 0)
    frame.icon = icon
    frame.cols = layoutColumns(frame, icon, hasLiquidity)
end

local function paintLedgerRow(row, data, hasLiquidity)
    local s = VWB.UI:GetScheme()
    row.data = data
    row.icon:SetTexture(C_Item.GetItemIconByID(data.itemID) or QUESTION_ICON)

    row.cols.name:SetText(data.name)
    if data.expansion then
        ns.Data.ExpansionData.SetTextColor(row.cols.name, data.expansion)
    else
        row.cols.name:SetTextColor(s.text.r, s.text.g, s.text.b)
    end

    row.cols.sell:SetText(VWB.UI:FormatMoney(data.sellPrice))
    row.cols.cost:SetText(VWB.UI:FormatMoney(data.materialCost))

    row.cols.profit:SetText(VWB.UI:FormatMoney(data.profit))
    if data.profit then
        local c = data.profit >= 0 and s.success or s.error
        row.cols.profit:SetTextColor(c.r, c.g, c.b)
    else
        row.cols.profit:SetTextColor(1, 1, 1) -- "--" already carries its own dim color code
    end

    if data.margin then
        row.cols.margin:SetText(string.format("%.1f%%", data.margin))
        if data.margin >= 50 then
            row.cols.margin:SetTextColor(s.success.r, s.success.g, s.success.b)
        elseif data.margin >= 0 then
            row.cols.margin:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
        else
            row.cols.margin:SetTextColor(s.error.r, s.error.g, s.error.b)
        end
    else
        row.cols.margin:SetText(VWB.UI:ColorCode("base01") .. "--|r")
        row.cols.margin:SetTextColor(1, 1, 1)
    end

    if hasLiquidity then
        local perDay = ns.PriceIntegration:GetSoldPerDay(data.itemID)
        if perDay then
            row.cols.sold:SetText(formatSoldPerDay(perDay))
            row.cols.sold:SetTextColor(s.text.r, s.text.g, s.text.b)
        else
            row.cols.sold:SetText(VWB.UI:ColorCode("base01") .. "--|r")
            row.cols.sold:SetTextColor(1, 1, 1)
        end
    end
end

-- Row hover: the addon's own Tooltip surface (VWB.UI.Tooltip), never
-- GameTooltip -- see UI/Tooltip.lua's header on why (SetHyperlink on an
-- equippable item spawns Blizzard's ShoppingTooltips comparison panels).
-- Every field mirrors the row's own "--"-for-nil contract; nothing here
-- invents a number the table itself wouldn't show.
local function paintRowTooltip(data, rowFrame)
    local tip = VWB.UI.Tooltip
    tip:Begin(rowFrame)
    tip:SetItemHeader(data.itemID, data.name)
    tip:AddDoubleLine("Sell", VWB.UI:FormatMoney(data.sellPrice))
    tip:AddDoubleLine("Cost", VWB.UI:FormatMoney(data.materialCost))
    tip:AddDoubleLine("Profit", VWB.UI:FormatMoney(data.profit))
    tip:AddDoubleLine("Margin", data.margin and string.format("%.1f%%", data.margin)
        or (VWB.UI:ColorCode("base01") .. "--|r"))
    if ns.PriceIntegration:HasTSM() then
        local perDay = ns.PriceIntegration:GetSoldPerDay(data.itemID)
        tip:AddDoubleLine("Sold/Day", perDay and formatSoldPerDay(perDay)
            or (VWB.UI:ColorCode("base01") .. "--|r"))
    end
    -- Alt-crafter hint (item 3): when the recipe is known by alts but not by
    -- this character, name the alts so the user knows who to log on.
    if data.recipeID then
        local crafters = ns.KnownRecipes:KnownByList(data.recipeID)
        if #crafters > 0 and not ns.KnownRecipes:IsKnownBy(data.recipeID, ns.CharacterData:GetCharacterKey()) then
            tip:AddLine(" ")
            tip:AddLine(VWB.UI:ColorCode("base01") .. "Craftable by: " .. table.concat(crafters, ", ") .. "|r")
        end
    end
    tip:Show()
end

-- Build-progress feedback for the chunked OnUpdate walk (ported from VPC's
-- BuildProfitCache): the summary bar's text swaps out for a pulsing progress
-- bar while a rebuild is in flight, then swaps back.
local function showBuildProgress(frame)
    frame.summaryText:Hide()
    frame.progressBar:Show()
    frame.progressBar:SetPulsing(true)
    frame.progressBar:SetProgress(0, 1)
    frame.progressBar.text:SetText("Running the numbers... 0%")
end

local function updateBuildProgress(frame, cursor, total)
    frame.progressBar:SetProgress(cursor, total)
    frame.progressBar.text:SetText(string.format("Running the numbers... %d%%", math.floor(cursor / total * 100)))
end

local function hideBuildProgress(frame)
    frame.progressBar:SetPulsing(false)
    frame.progressBar:Hide()
    frame.summaryText:Show()
end

-- Bottom summary bar: Showing N / Avg Profit / Best over the FILTERED rows
-- (post search/sort/structured-filters), or an empty-state message that
-- tells the truth about WHY nothing is showing (no price data vs. filters
-- too tight) instead of generic "no results".
local function paintSummary(frame, result)
    local s = VWB.UI:GetScheme()
    local rows = result.rows
    if #rows == 0 then
        frame.summaryText:SetTextColor(s.text.r, s.text.g, s.text.b)
        if result.decorColdBlock then
            frame.summaryText:SetText("Open the housing catalog once this session, then come back -- the Decor: Missing filter needs it warm.")
        elseif result.unpricedCount > 0 then
            frame.summaryText:SetText(string.format(
                "%d recipes match but have no price data. Scan the AH (or install TSM/Auctionator) to light this tab up.",
                result.unpricedCount))
        else
            frame.summaryText:SetText("Nothing clears your filters. Loosen one and try again.")
        end
        return
    end

    local total, profCount, best = 0, 0, nil
    for _, d in ipairs(rows) do
        if d.profit then
            total = total + d.profit
            profCount = profCount + 1
            if not best or d.profit > best.profit then best = d end
        end
    end

    local parts = { string.format("Showing %d recipes", #rows) }
    if profCount > 0 then
        parts[#parts + 1] = string.format("Avg Profit: %s", VWB.UI:FormatMoney(total / profCount))
    end
    if best and best.profit > 0 then
        parts[#parts + 1] = string.format("Best: %s (%s)", best.name, VWB.UI:FormatMoney(best.profit))
    end
    frame.summaryText:SetText(table.concat(parts, "  |  "))
    frame.summaryText:SetTextColor(s.text.r, s.text.g, s.text.b)
end

function Ledger.buildView(container)
    local R = ns.Reactor
    local Kit = ns.ViewKit

    local search = R.signal("")
    local sortMode = R.signal("profit")
    local selectedProfessions = R.signal({}) -- set of profession keys; empty = all (Stockroom's multi-select semantics)
    local function toggleProfession(key) VWB.UI.ToggleSetKey(selectedProfessions, key) end
    -- 3-state: "all" / "me" / "account" (item 3)
    local knownMode = R.signal("all")
    local showCraftableOnly = R.signal(false)
    local showDecorMissing = R.signal(false) -- "Decor: Missing" collector filter (item 2)
    local hideUnprofitable = R.signal(true) -- CRITICAL default: open filtered like VPC, don't dump ~8600 rows
    local profitRows = R.signal({}) -- built rows; see rebuildProfitRows below
    local hasLiquidity = ns.PriceIntegration:HasTSM()
    local listWidget, summaryFrame, scanBtn, profDropdown

    -- Profession list from HARVESTED professions only (item 1), SECTIONED
    -- player-first (owner 2026-07-13): the account's own professions lead;
    -- professions that exist only via the guild catalog harvest trail with a
    -- dim (guild) tag -- the player/guild split made visible in the control.
    local accountProfs = {}
    for _, entry in pairs(ns.Store:GetState().account.characters) do
        for profName in pairs(entry.professions) do accountProfs[profName] = true end
    end
    local mineItems, guildItems = {}, {}
    for _, prof in ipairs(VWB.RecipeQuery:GetProfessions()) do
        if accountProfs[prof.key] then
            mineItems[#mineItems + 1] = { key = prof.key, label = prof.label }
        else
            guildItems[#guildItems + 1] = { key = prof.key, label = prof.label .. "  |cff8a8a8e(guild)|r" }
        end
    end
    local professionItems = {}
    if #mineItems > 0 then
        professionItems[#professionItems + 1] = { title = "Your professions" }
        for _, it in ipairs(mineItems) do professionItems[#professionItems + 1] = it end
    end
    if #guildItems > 0 then
        professionItems[#professionItems + 1] = { title = "Guild catalog" }
        for _, it in ipairs(guildItems) do professionItems[#professionItems + 1] = it end
    end

    -- Chunked, cache-until-invalidated build over the whole known-recipe
    -- universe. A synchronous walk would freeze the client for a heavily-
    -- harvested account, so a hidden driver frame Calculate()s CHUNK_SIZE
    -- recipes per rendered frame off a cursor, then Hide()s itself when the
    -- walk completes (one-shot per rebuild; Show() arms the next one). NO
    -- C_Timer -- WoW does not tick OnUpdate on a hidden frame, so Show()/
    -- Hide() IS the start/stop switch. profitRows is written ONCE at
    -- completion -- a mid-build partial swap would show an inconsistent
    -- half-priced table; the previous complete set stays on screen until the
    -- new one is ready.
    local buildDriver = CreateFrame("Frame")
    buildDriver:Hide()
    local buildIDs, buildResults, buildCursor, buildDirty
    local rebuildProfitRows -- forward decl: the OnUpdate re-arms it if a bump was dropped mid-build

    buildDriver:SetScript("OnUpdate", function()
        for _ = 1, CHUNK_SIZE do
            buildCursor = buildCursor + 1
            if buildCursor > #buildIDs then
                buildDriver:Hide()
                profitRows(buildResults)
                hideBuildProgress(summaryFrame)
                -- A Store bump that landed mid-walk was coalesced into buildDirty,
                -- not dropped -- re-arm once so the freshly-priced set reflects it.
                if buildDirty then buildDirty = false; rebuildProfitRows() end
                return
            end
            local data = ns.ProfitCalculator:Calculate(buildIDs[buildCursor])
            if data then buildResults[#buildResults + 1] = data end
        end
        updateBuildProgress(summaryFrame, buildCursor, #buildIDs)
    end)

    rebuildProfitRows = function()
        if buildDriver:IsShown() then buildDirty = true; return end -- build in flight: coalesce, re-run on completion
        buildIDs = {}
        for recipeID in pairs(ns.Database:GetAllRecipes()) do buildIDs[#buildIDs + 1] = recipeID end
        buildResults, buildCursor = {}, 0
        showBuildProgress(summaryFrame)
        buildDriver:Show()
    end

    -- itemID -> per-craft profit, for the session KPIs below. Memoized on
    -- profitRows() only -- NOT on Store:Version() -- so a new craft-log entry
    -- doesn't re-walk the whole priced set to value it.
    local profitByItemID = R.named("ledger:profitByItemID", function()
        local map = {}
        for _, d in ipairs(profitRows()) do
            if d.profit then map[d.itemID] = d.profit end
        end
        return map
    end)

    -- Session profit total. A computed scoped to the "history" slice: it RETURNS
    -- a scalar (not the mutated-in-place craftingHistory table), so there's no
    -- memoization trap -- and both KPI binds share this one walk instead of each
    -- re-walking on every dispatch anywhere in the addon.
    local sessionProfit = R.named("ledger:sessionProfit", function()
        ns.Store:Version("history")
        local byItem = profitByItemID()
        local total, any = 0, false
        for _, entry in ipairs(ns.Store:GetState().craftingHistory) do
            if entry.timestamp >= SESSION_START then
                local unit = byItem[entry.itemID]
                if unit then
                    total = total + unit * (entry.qty or 1)
                    any = true
                end
            end
        end
        return any and total or nil
    end)

    -- Search + structured filters + sort over the already-built rows --
    -- cheap, and the only thing that reruns per keystroke / filter click.
    -- unpricedCount (rows that pass every OTHER filter but have no market
    -- price) feeds the summary bar's empty-state message.
    -- decorMissingCold: true when showDecorMissing is on but the catalog has
    -- not yet been warmed -- the empty-state shows the honest message (item 2).
    local filtered = R.named("ledger:filtered", function()
        local q = search()
        local mode = sortMode()
        local selProfs = selectedProfessions()
        local allProfs = next(selProfs) == nil
        local kMode = knownMode()
        local matsOnly = showCraftableOnly()
        local hideUnp = hideUnprofitable()
        local decorMissing = showDecorMissing()

        local out, unpriced = {}, 0
        local decorColdBlock = decorMissing and ns.DecorOwnership:IsCatalogCold()
        for _, d in ipairs(profitRows()) do
            local passesKnown
            if kMode == "me" then
                -- IsKnown is the ACCOUNT union -- "me" must be per-character
                passesKnown = ns.KnownRecipes:IsKnownBy(d.recipeID, ns.CharacterData:GetCharacterKey())
            elseif kMode == "account" then
                passesKnown = #ns.KnownRecipes:KnownByList(d.recipeID) > 0
            else
                passesKnown = true -- "all"
            end
            -- Decor: Missing filter -- skip when catalog cold to avoid false negatives (item 2)
            local passesDecor = (not decorMissing) or (not decorColdBlock and ns.DecorOwnership:IsUncollected(d.itemID) == true)
            local passes = (q == "" or (d.name and d.name:lower():find(q, 1, true)))
                and (allProfs or selProfs[d.profession] == true)
                and passesKnown
                and (not matsOnly or ns.RecipeQuery:CanCraft(d.recipeID))
                and passesDecor
            if passes then
                if d.profit == nil then unpriced = unpriced + 1 end
                if not hideUnp or (d.profit and d.profit >= 0) then
                    out[#out + 1] = d
                end
            end
        end

        table.sort(out, function(a, b)
            if mode == "margin" then
                return (a.margin or -math.huge) > (b.margin or -math.huge)
            elseif mode == "name" then
                return (a.name or "") < (b.name or "") -- name is nil for cold-cache rows; guard the comparator
            else
                return (a.profit or -math.huge) > (b.profit or -math.huge)
            end
        end)
        return { rows = out, unpricedCount = unpriced, decorColdBlock = decorColdBlock }
    end)

    local function makeFrame(node, parent)
        if node.id == "ldgSearch" then
            return VWB.UI:CreateSearchBox(parent, { placeholder = "Search recipes...",
                onChange = function(text) search((text or ""):lower()) end })
        elseif node.id == "ldgSort" then
            return VWB.UI:CreateSegmentedToggle(parent, {
                width = (node.size and node.size.w) or 130, height = (node.size and node.size.h) or 20,
                segments = SORT_SEGMENTS, default = "profit", onSelect = function(key) sortMode(key) end })
        elseif node.id == "ldgTable" then
            local wrap = CreateFrame("Frame", nil, parent)

            -- Filter strip: profession / known-only / have-mats / hide-
            -- unprofitable, pinned above the column header. Packed into this
            -- node's own frame (same idiom Recipes_View uses to pack a
            -- toggle into rcpMatHeader) rather than new LayoutConfig slots.
            local filterStrip = CreateFrame("Frame", nil, wrap)
            filterStrip:SetHeight(24)
            filterStrip:SetPoint("TOPLEFT", 0, 0)
            filterStrip:SetPoint("TOPRIGHT", 0, 0)

            profDropdown = VWB.UI:CreateMultiSelectDropdown(filterStrip, {
                width = 140, height = 20,
                allLabel = "All Professions", items = professionItems,
                isAll = function() return next(selectedProfessions()) == nil end,
                isSelected = function(key) return selectedProfessions()[key] == true end,
                onAll = function() selectedProfessions({}) end,
                onToggle = toggleProfession,
            })
            profDropdown:SetPoint("LEFT", 0, 0)

            -- 3-state Known control (item 3): All / Me / Account.
            -- "Account" rows show crafter name in tooltip via KnownByList.
            local knownToggle = VWB.UI:CreateSegmentedToggle(filterStrip, {
                width = 165, height = 20,
                segments = {
                    { key = "all",     label = "All" },
                    { key = "me",      label = "Known by Me" },
                    { key = "account", label = "Account" },
                },
                default = "all",
                onSelect = function(key) knownMode(key) end,
            })
            knownToggle:SetPoint("LEFT", profDropdown, "RIGHT", 12, 0)

            -- Binary row filters are PILLS addon-wide (consistency review
            -- 2026-07-13: Workbench/Showroom taught pills; Ledger's checkboxes
            -- for the same concept were drift). Affirmative wording:
            -- "Profitable only" replaces the inverted "Hide Unprofitable".
            local matsCb = VWB.UI:CreateFilterPill(filterStrip, "Have Mats", function(checked)
                showCraftableOnly(checked)
            end)
            matsCb:SetPoint("LEFT", knownToggle, "RIGHT", 12, 0)

            -- Decor: Missing -- collector-profit hero query (item 2)
            local decorCb = VWB.UI:CreateFilterPill(filterStrip, "Decor: Missing", function(checked)
                showDecorMissing(checked)
            end)
            decorCb:SetPoint("LEFT", matsCb, "RIGHT", 12, 0)

            local hideUnpCb = VWB.UI:CreateFilterPill(filterStrip, "Profitable only", function(checked)
                hideUnprofitable(checked)
            end)
            hideUnpCb:SetPoint("LEFT", decorCb, "RIGHT", 12, 0)
            hideUnpCb:SetChecked(true)

            local header = buildTableHeader(wrap, hasLiquidity)
            header:SetPoint("TOPLEFT", filterStrip, "BOTTOMLEFT", 0, -4)
            header:SetPoint("TOPRIGHT", filterStrip, "BOTTOMRIGHT", 0, -4)

            -- Bottom summary bar; also hosts the build-progress bar (they
            -- occupy the same slot, toggled -- see showBuildProgress).
            summaryFrame = CreateFrame("Frame", nil, wrap, "BackdropTemplate")
            summaryFrame:SetHeight(24)
            summaryFrame:SetPoint("BOTTOMLEFT", 0, 0)
            summaryFrame:SetPoint("BOTTOMRIGHT", 0, 0)
            VWB.Theme:Register(summaryFrame, "Panel") -- routes backdrop + colors through Skinner (item 4)
            summaryFrame.summaryText = summaryFrame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
            summaryFrame.summaryText:SetPoint("CENTER")
            summaryFrame.progressBar = VWB.UI:CreateProgressBar(summaryFrame, { width = 300, height = 16 })
            summaryFrame.progressBar:SetPoint("CENTER")
            summaryFrame.progressBar:Hide()

            listWidget = VWB.UI:CreateVirtualizedList(wrap, {
                rowHeight = 22,
                rowTemplate = function(f) ledgerRowTemplate(f, hasLiquidity) end,
                updateRow = function(row, data) paintLedgerRow(row, data, hasLiquidity) end,
                onRowEnter = function(data, rowFrame) paintRowTooltip(data, rowFrame) end,
                onRowLeave = function(_, rowFrame) VWB.UI.Tooltip:Hide(rowFrame) end,
            })
            listWidget:ClearAllPoints()
            listWidget:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
            listWidget:SetPoint("BOTTOMRIGHT", summaryFrame, "TOPRIGHT", 0, 2)
            return wrap
        elseif node.id == "ldgPriceSource" then
            local f = Kit.roleLabel(node, parent)
            local sources = ns.PriceIntegration:GetAvailableSources()
            if #sources > 0 then
                f.label:SetText(VWB.UI:ColorCode("cyan") .. "Price source|n" .. table.concat(sources, ", ") .. "|r")
            else
                f.label:SetText(VWB.UI:ColorCode("yellow") .. "No price source|nInstall TSM or Auctionator|r")
            end

            scanBtn = VWB.UI:CreateButton(f, "Scan AH", 90, 22)
            scanBtn:SetPoint("RIGHT", -6, 0)

            local refreshBtn = VWB.UI:CreateButton(f, "Refresh", 70, 22)
            refreshBtn:SetPoint("RIGHT", scanBtn, "LEFT", -6, 0)
            refreshBtn:SetScript("OnClick", function() rebuildProfitRows() end)

            f.label:ClearAllPoints()
            f.label:SetPoint("TOPLEFT", 4, -3)
            f.label:SetPoint("BOTTOMRIGHT", refreshBtn, "BOTTOMLEFT", -8, 3)
            return f
        end
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.ledger, { makeFrame = makeFrame, measure = Kit.measure })

    -- ------------------------------------------------------------------------
    -- Scan AH button: lifecycle + tooltip. The only price path for a user with
    -- no TSM/Auctionator -- StartScan itself no-ops when the AH is closed or a
    -- scan is already running, so the button just needs to reflect state.
    -- ------------------------------------------------------------------------
    local function updateScanButton()
        local ready = ns.AHScan:IsAHOpen() and not ns.AHScan:IsScanning()
        if ns.AHScan:IsScanning() then
            scanBtn:SetText("Scanning...")
        elseif ns.AHScan:HasData() then
            scanBtn:SetText("Rescan AH")
        else
            scanBtn:SetText("Scan AH")
        end
        -- Dim (not disabled) when it can't act: a disabled Button can swallow
        -- OnEnter, and the tooltip must still explain why it's inert.
        scanBtn:SetAlpha(ready and 1 or 0.5)
    end
    updateScanButton()

    scanBtn:SetScript("OnClick", function()
        ns.AHScan:StartScan(ns.AHScan:HasData()) -- force a fresh dump only on Rescan
    end)
    scanBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Scan the Auction House", 1, 1, 1)
        if ns.AHScan:IsAHOpen() then
            GameTooltip:AddLine("Browse-scans live listings for prices -- no TSM or Auctionator needed.", 0.7, 0.7, 0.7, true)
        else
            GameTooltip:AddLine("Open the Auction House first, then come back to scan.", 0.8, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end)
    scanBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- AH open/close drives the button's enabled state even while the Ledger is
    -- already showing.
    local ahWatch = CreateFrame("Frame")
    ahWatch:RegisterEvent("AUCTION_HOUSE_SHOW")
    ahWatch:RegisterEvent("AUCTION_HOUSE_CLOSED")
    ahWatch:SetScript("OnEvent", updateScanButton)

    ns.EventBus:Register("VWB_AH_SCAN_STARTED", updateScanButton)
    ns.EventBus:Register("VWB_AH_SCAN_PROGRESS", function(p)
        scanBtn:SetText(string.format("Scanning %d", p.results))
    end)
    -- Scan completion refreshes prices (the scan just filled the session table
    -- PriceIntegration reads) and rebuilds the profit cache off the new data --
    -- the other price-changing input Store:Version() can't see (AHScan writes
    -- its results table directly, no dispatch involved).
    ns.EventBus:Register("VWB_AH_SCAN_COMPLETE", function()
        ns.PriceIntegration:InvalidateCache()
        updateScanButton()
        rebuildProfitRows()
    end)

    -- Rebuild triggers: the recipe universe changing (Version("recipes") -- a
    -- guild harvest landing new records) or the pricing config changing
    -- (Version("config") -- source pin / AH-cut toggle). Per-slice signals,
    -- NOT the blanket Store:Version() -- this effect only re-runs when one of
    -- those two slices actually bumps, so an unrelated dispatch elsewhere
    -- never re-walks ~8600 recipes. Also covers the very first mount (the
    -- effect runs once immediately on creation).
    R.effect(function()
        ns.Store:Version("recipes")
        ns.Store:Version("config")
        rebuildProfitRows()
    end, "ledger:rebuildWatch")

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        listWidget:SetData(filtered().rows)
    end, "ledger:list")
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint on switch (summary reads scheme colors)
        paintSummary(summaryFrame, filtered())
    end, "ledger:summary")

    VWB.UI.BindMultiSelectLabel(profDropdown, selectedProfessions,
        { all = "All Professions", noun = "professions", effectName = "ledger:professionLabel" })

    R.bindText(handle.byId.ldgKpiProfit.label, function()
        VWB.Theme.epoch() -- theme epoch: repaint on switch
        local total = sessionProfit() -- tracks the "history" slice via the computed
        local value = total and VWB.UI:FormatMoney(total) or (VWB.UI:ColorCode("base01") .. "--|r")
        return "Session Profit|n" .. value
    end)

    R.bindText(handle.byId.ldgKpiRate.label, function()
        VWB.Theme.epoch() -- theme epoch: repaint on switch
        local total = sessionProfit()
        local elapsed = time() - SESSION_START
        local value
        if not total or elapsed < KPI_MIN_SECONDS then
            value = VWB.UI:ColorCode("base01") .. "--|r"
        else
            value = VWB.UI:FormatMoney(total / (elapsed / 3600)) .. "/hr"
        end
        return "Gold / Hour|n" .. value
    end)

    R.bindText(handle.byId.ldgKpiMargin.label, function()
        VWB.Theme.epoch() -- theme epoch: repaint on switch
        local sum, n = 0, 0
        for _, d in ipairs(profitRows()) do
            if d.margin then
                sum = sum + d.margin
                n = n + 1
            end
        end
        local value
        if n == 0 then
            value = VWB.UI:ColorCode("base01") .. "--|r"
        else
            local avg = sum / n
            local key = avg >= 50 and "green" or (avg >= 0 and "yellow" or "red")
            value = VWB.UI:ColorCode(key) .. string.format("%.1f%%", avg) .. "|r"
        end
        return "Avg Margin|n" .. value
    end)

    return handle
end

return Ledger
