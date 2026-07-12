-- ============================================================================
-- VWB Stockroom (Reagents) - VIEW / controller. Slice: real reagent list.
-- ============================================================================
-- Ports VPC's Reagents tab onto the Reactor + box-model pattern: every itemID
-- ReagentSource classifies as a MATERIAL (farm/buy or crafted; end products --
-- recipe outputs -- are excluded, they belong in the Workbench), filtered by
-- search + a 4-way class toggle (All/Farm-Buy/Crafted/Queue) + expansion and
-- gather-source multi-selects, with owned counts off Inventory. Item names
-- resolve async via a Reactor resource (VPC hand-rolled a nameCache/
-- nameRequested/RebuildList loop for this same cold-cache problem; here ONE
-- resource read inside a computed does it structurally -- same unlock as
-- Showroom's kind/collected resources).
--
-- Split into two computeds on purpose: `classified` re-derives only on
-- Store:Version() (harvest / queue changes) and does the ReagentSource walk;
-- `items` re-derives on top of that for search/segment/name-resolve changes
-- without re-walking the classification. A name landing on a cold item only
-- re-runs the cheap join+filter+sort, not GetAllClassified()+GetInfo() over
-- the whole set. See the perf note in the build report for why this still
-- isn't free at ~10k reagents.
--
-- The Queue segment + "needed for queue" line read state.crafting.shoppingList
-- -- empty until the queue is wired, so they just naturally show nothing
-- (empty table, not nil) instead of needing a special-case guard.
-- ============================================================================

local _, ns = ...
local Stockroom = ns.Stockroom or {}
ns.Stockroom = Stockroom

local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local CLASS_LABELS = { farmbuy = "Farm/Buy", crafted = "Crafted", endproduct = "End Product" }
local CLASS_SCHEME_KEY = { farmbuy = "success", crafted = "accent", endproduct = "warning" } -- scheme fields for SetTextColor
local CLASS_COLOR_CODE = { farmbuy = "green", crafted = "cyan", endproduct = "yellow" } -- VWB.UI:ColorCode keys, for inline-colored tooltip text

local TIER_LABEL      = { gather = "Gather", refine = "Refine", farm = "Farm", salvage = "Salvage" }
local TIER_SCHEME_KEY = { gather = "success", refine = "accent", farm = "warning", salvage = "accent" } -- SetTextColor scheme fields
local TIER_COLOR_CODE = { gather = "green",   refine = "cyan",   farm = "yellow", salvage = "cyan" } -- VWB.UI:ColorCode keys

-- Badge label + scheme field for a row: the gather source when a farmbuy reagent
-- has one, else the plain class label. (info.gatherMethod is nil unless farmbuy.)
local function badgeParts(info)
    if info.gatherMethod then
        return TIER_LABEL[info.sourceTier] .. ": " .. info.gatherMethod, TIER_SCHEME_KEY[info.sourceTier]
    end
    return CLASS_LABELS[info.class], CLASS_SCHEME_KEY[info.class]
end

-- Same, for inline-colored tooltip text (ColorCode key + label).
local function badgeCode(info)
    if info.gatherMethod then
        return TIER_COLOR_CODE[info.sourceTier], TIER_LABEL[info.sourceTier] .. ": " .. info.gatherMethod
    end
    return CLASS_COLOR_CODE[info.class], CLASS_LABELS[info.class] or info.class
end

local FILTER_SEGMENTS = {
    { key = "all", label = "All" }, { key = "farmbuy", label = "Farm/Buy" },
    { key = "crafted", label = "Crafted" },
    { key = "queue", label = "Queue" },
}

-- Expansion bucketing: an item belongs to expansion X if any recipe that PRODUCES
-- or CONSUMES it is from X. Recipes with no harvested expansion fold into OTHER_KEY
-- so nothing silently vanishes from a filtered list.
local OTHER_KEY = "__other"
local function expOf(rid)
    local rec = ns.Database:GetRecipe(rid)
    if rec and rec.expansion then return rec.expansion end
    return OTHER_KEY -- exception(nullable): pruned recipe / nil harvested expansion -> Other bucket
end
local function expansionsOf(info)
    local set = {}
    for _, rid in ipairs(info.producedBy) do set[expOf(rid)] = true end
    for _, rid in ipairs(info.usedIn) do set[expOf(rid)] = true end
    return set
end
local function matchesExp(recExpansions, exp) -- any selected expansion touches this item
    for k in pairs(exp) do if recExpansions[k] then return true end end
    return false
end

local UNCLASSIFIED_KEY = "__farmbuy" -- farmbuy reagents with no resolved gather method
-- The filter key for a reagent: its gatherMethod, else the unclassified-farmbuy
-- sentinel, else nil (crafted/endproduct are not source-filterable).
local function sourceKeyOf(info)
    if info.gatherMethod then return info.gatherMethod end
    if info.class == "farmbuy" then return UNCLASSIFIED_KEY end
    return nil
end
local function matchesSource(info, sel)
    local k = sourceKeyOf(info)
    return k ~= nil and sel[k] == true
end
local function labelForKey(key) return key == OTHER_KEY and "Other" or key end

-- Item name/quality/bop over the ItemData broker (Constitution step 4: the
-- private resource here was the LAST parallel item-data requester). Same
-- peek/epoch surface the walker uses -- peek acquires, as the old resource's
-- ensureEntry did. name, quality, and bind were all captured at the broker's
-- load callback, so BoP tags can no longer bounce with client cache eviction
-- (the original VPC Stockroom bug). Mapped rows memoize per RECORD, weak
-- keys: a manual refetch swaps the record and the stale mapping GCs away.
local nameRes
local function ensureNameRes()
    if nameRes then return end
    local mapped = setmetatable({}, { __mode = "k" })
    nameRes = {
        epoch = VWB.ItemData.changedEpoch,
        peek = function(itemID)
            local rec = VWB.ItemData.query(itemID)
            if type(rec) ~= "table" then return ns.Reactor.PENDING end -- pending + terminal no-data: the row keeps its id fallback
            local m = mapped[rec]
            if not m then
                m = { name = rec.name, quality = rec.quality, bop = rec.bind == Enum.ItemBind.OnAcquire }
                mapped[rec] = m
            end
            return m
        end,
    }
end

-- A themed reagent row: icon | name | itemID | class badge | evidence | owned | BoP | queue need.
local function rowTemplate(frame)
    -- persistent selection tint (behind the hover highlight the list factory adds)
    local d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
    local selHL = frame:CreateTexture(nil, "BACKGROUND"); selHL:SetAllPoints(); selHL:SetColorTexture(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 0.12); selHL:Hide()
    frame._selHL = selHL
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(18, 18); icon:SetPoint("LEFT", 4, 0)
    frame.icon = icon
    local name = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0); name:SetWidth(190); name:SetJustifyH("LEFT")
    frame.name = name
    local idText = frame:CreateFontString(nil, "OVERLAY", "VWBFontDisableSmall")
    idText:SetPoint("LEFT", name, "RIGHT", 4, 0); idText:SetWidth(50); idText:SetJustifyH("LEFT")
    frame.idText = idText
    local badge = frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    badge:SetPoint("LEFT", idText, "RIGHT", 10, 0); badge:SetWidth(130); badge:SetJustifyH("LEFT") -- fits "Refine: Prospecting" on one line; evidence+ cascade right into free space
    frame.badge = badge
    -- Evidence: the diagnostic's core "why" -- how many recipes touch this item
    -- on each side of the classification (VPC parity column).
    local evidence = frame:CreateFontString(nil, "OVERLAY", "VWBFontDisableSmall")
    evidence:SetPoint("LEFT", badge, "RIGHT", 8, 0); evidence:SetWidth(120); evidence:SetJustifyH("LEFT")
    frame.evidence = evidence
    local owned = frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    owned:SetPoint("LEFT", evidence, "RIGHT", 8, 0); owned:SetWidth(50); owned:SetJustifyH("LEFT")
    frame.owned = owned
    local bop = frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    bop:SetPoint("LEFT", owned, "RIGHT", 6, 0); bop:SetWidth(35); bop:SetJustifyH("LEFT")
    frame.bop = bop
    local need = frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    need:SetPoint("LEFT", bop, "RIGHT", 8, 0); need:SetPoint("RIGHT", -6, 0); need:SetJustifyH("LEFT")
    frame.need = need
end

-- A recipe row for the detail panel: icon | recipe name | qty | "uses"/"makes".
local function recipeRowTemplate(frame)
    local d = VWB.Constants:GetDerivedColors(VWB.UI:GetScheme())
    local selHL = frame:CreateTexture(nil, "BACKGROUND"); selHL:SetAllPoints(); selHL:SetColorTexture(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b, 0.12); selHL:Hide()
    frame._selHL = selHL
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(16, 16); icon:SetPoint("LEFT", 2, 0)
    frame.icon = icon
    local tag = frame:CreateFontString(nil, "OVERLAY", "VWBFontDisableSmall")
    tag:SetPoint("RIGHT", -4, 0); tag:SetWidth(38); tag:SetJustifyH("RIGHT")
    frame.tag = tag
    local qty = frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
    qty:SetPoint("RIGHT", tag, "LEFT", -4, 0); qty:SetWidth(34); qty:SetJustifyH("RIGHT")
    frame.qty = qty
    local rname = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
    rname:SetPoint("LEFT", icon, "RIGHT", 5, 0); rname:SetPoint("RIGHT", qty, "LEFT", -4, 0); rname:SetJustifyH("LEFT")
    frame.rname = rname
end

function Stockroom.buildView(container)
    ensureNameRes()
    local R = ns.Reactor
    local Kit = ns.ViewKit
    local search = R.signal("")
    local filterMode = R.signal("all")
    local selectedItemID = R.signal(nil) -- which reagent the detail panel is inspecting
    local selectedRecipeID = R.signal(nil) -- which recipe row is picked in the detail panel
    -- Item 6: upvalue slots pre-read once per paint pass (selectionTick / recipePick
    -- effects below), so updateRow never allocates a closure on each row repaint.
    local _stkCurSelectedID = nil
    local _stkCurSelectedRecipeID = nil
    local selectedExpansions = R.signal({}) -- set of expansion display names; empty = "All" (no filter)
    local listWidget, detailListWidget, detailHeader, detailSub, detailUsedHdr, detailAddBtn, expansionDD, sourceDD
    local filterWidget, searchWidget -- forward refs for Nav signal consumption (item 7)

    -- Menu items in EXPANSION_DATA order (Classic -> Midnight), each tinted by its
    -- brand color, plus an "Other" bucket for recipes with no harvested expansion.
    local EXPANSION_ITEMS = {}
    for _, e in ipairs(VWB.Data.ExpansionData.EXPANSION_DATA) do
        EXPANSION_ITEMS[#EXPANSION_ITEMS + 1] = { key = e.display, label = e.display, color = e.color }
    end
    EXPANSION_ITEMS[#EXPANSION_ITEMS + 1] = { key = OTHER_KEY, label = "Other", color = { r = 0.6, g = 0.6, b = 0.6 } }

    -- Immutable toggle: a NEW set each time so the signal sees an identity change
    -- (mutating in place wouldn't re-fire the items() computed).
    local function toggleExpansion(key)
        local nxt = {}
        for k in pairs(selectedExpansions()) do nxt[k] = true end
        if nxt[key] then nxt[key] = nil else nxt[key] = true end
        selectedExpansions(nxt)
    end

    local selectedSources = R.signal({}) -- set of source keys; empty = "All Sources" (no filter)

    -- Static tier tints (dropdown item colors are fixed like expansion brand
    -- colors, not theme scheme fields which resolve reactively).
    local TIER_TINT = {
        gather = { r = 0.55, g = 0.80, b = 0.40 },
        refine = { r = 0.40, g = 0.75, b = 0.85 },
        farm   = { r = 0.85, g = 0.75, b = 0.35 },
    }
    local SOURCE_METHODS = {
        { key = "Herbalism", tier = "gather" }, { key = "Mining", tier = "gather" }, { key = "Skinning", tier = "gather" },
        { key = "Disenchant", tier = "refine" }, { key = "Milling", tier = "refine" }, { key = "Prospecting", tier = "refine" },
        { key = "Cloth", tier = "farm" }, { key = "Cooking", tier = "farm" },
    }
    local SOURCE_ITEMS, SOURCE_LABEL = {}, {}
    for _, m in ipairs(SOURCE_METHODS) do
        local label = TIER_LABEL[m.tier] .. ": " .. m.key
        SOURCE_ITEMS[#SOURCE_ITEMS + 1] = { key = m.key, label = label, color = TIER_TINT[m.tier] }
        SOURCE_LABEL[m.key] = label
    end
    SOURCE_ITEMS[#SOURCE_ITEMS + 1] = { key = UNCLASSIFIED_KEY, label = "Farm/Buy", color = { r = 0.6, g = 0.6, b = 0.6 } }
    SOURCE_LABEL[UNCLASSIFIED_KEY] = "Farm/Buy"

    local function toggleSource(key)
        local nxt = {}
        for k in pairs(selectedSources()) do nxt[k] = true end
        if nxt[key] then nxt[key] = nil else nxt[key] = true end
        selectedSources(nxt)
    end

    -- Queue-need merged across shoppingList entries by itemID (same merge VPC's
    -- RebuildQueueNeed did). Its OWN computed on the crafting slice: a queue edit
    -- re-runs this cheap map build, not the ~10k-reagent classification walk.
    -- (Split out of classified so classified can subscribe corpus alone.)
    local queueNeed = R.named("stockroom:queueNeed", function()
        ns.Store:Version("crafting")
        local out = {}
        for _, mat in ipairs(ns.Store:GetState().crafting.shoppingList) do
            local entry = out[mat.itemID]
            if not entry then
                entry = { required = 0, owned = mat.owned }
                out[mat.itemID] = entry
            end
            entry.required = entry.required + mat.required
            entry.owned = math.max(entry.owned, mat.owned) -- entries repeat the same bag count
        end
        return out
    end)

    -- Every classified itemID + its ReagentSource info + bucket totals. Subscribes
    -- ONLY the corpus signal: classification is a pure function of recipe
    -- DEFINITIONS (recipeStore), so a known-status scan / queue edit / config
    -- change must NOT re-walk the reagent set. Rebuilds only on ADD_RECIPES (own-
    -- profession scan / guild scan) -- the sole source that grows the corpus.
    -- Totals fold into this same walk -- the footer reads classified().totals
    -- instead of re-walking the set just to tally it.
    local classified = R.named("stockroom:classified", function()
        ns.Store:Version("corpus")
        local out = {}
        local totals = { farmbuy = 0, crafted = 0, endproduct = 0 }
        for itemID in pairs(ns.ReagentSource:GetAllClassified()) do
            local info = ns.ReagentSource:GetInfo(itemID)
            out[#out + 1] = { itemID = itemID, info = info, expansions = expansionsOf(info) }
            totals[info.class] = totals[info.class] + 1
        end
        out.totals = totals
        return out
    end)

    -- classified joined with the resolved name, filtered by search + class
    -- segment, sorted by name. Unresolved names sort last on a stable padded-
    -- itemID key so ordering doesn't jitter while names stream in.
    local items = R.named("stockroom:items", function()
        local q = search()
        local mode = filterMode()
        local exp = selectedExpansions()
        local expActive = next(exp) ~= nil
        local src = selectedSources()
        local srcActive = next(src) ~= nil
        nameRes.epoch() -- O(1) dep for up to ~10k reagents; peek() reads below are untracked
        local need = queueNeed() -- crafting-slice join, kept off the corpus-only classified walk
        local out = {}
        for _, rec in ipairs(classified()) do
            local recNeed = need[rec.itemID]
            local passesClass
            if mode == "queue" then
                passesClass = recNeed ~= nil and recNeed.required > 0
            else
                -- Stockroom = materials only: "all" is farm/buy + crafted. End products
                -- (recipe OUTPUTS, not stock) belong in the Workbench, never shown here.
                passesClass = (mode == "all" and rec.info.class ~= "endproduct") or (rec.info.class == mode)
            end
            local passesExp = not expActive
            if passesClass and expActive then passesExp = matchesExp(rec.expansions, exp) end
            local passesSource = not srcActive
            if passesClass and passesExp and srcActive then passesSource = matchesSource(rec.info, src) end
            if passesClass and passesExp and passesSource then
                local resolved = nameRes.peek(rec.itemID)
                local name, quality, bop
                if resolved ~= R.PENDING then name, quality, bop = resolved.name, resolved.quality, resolved.bop end
                local passesSearch = q == ""
                    or (name and name:lower():find(q, 1, true) ~= nil)
                    or tostring(rec.itemID):find(q, 1, true) ~= nil
                if passesSearch then
                    -- Precompute the sort key ONCE (Schwartzian). The old comparator
                    -- recomputed it O(n log n) times, re-allocating the padded-itemID
                    -- fallback string on every compare for the ~7k names still
                    -- unresolved during cold-load streaming. Unresolved sort last.
                    out[#out + 1] = {
                        itemID = rec.itemID, info = rec.info, need = recNeed,
                        name = name, quality = quality, bop = bop,
                        sortKey = name or ("\255\255\255\255" .. string.format("%010d", rec.itemID)),
                    }
                end
            end
        end
        table.sort(out, function(a, b) return a.sortKey < b.sortKey end)
        return out
    end)

    local function makeFrame(node, parent)
        if node.id == "stkSearch" then
            searchWidget = VWB.UI:CreateSearchBox(parent, { placeholder = "Search name or itemID...",
                onChange = function(text) search((text or ""):lower()) end })
            return searchWidget
        elseif node.id == "stkFilter" then
            filterWidget = VWB.UI:CreateSegmentedToggle(parent, {
                width = node.size.w, height = node.size.h, -- strict: LayoutConfig guarantees size (no defensive default)
                segments = FILTER_SEGMENTS, default = "all", onSelect = function(key) filterMode(key) end })
            return filterWidget
        elseif node.id == "stkExpansion" then
            expansionDD = VWB.UI:CreateMultiSelectDropdown(parent, {
                width = node.size.w, height = node.size.h,
                allLabel = "All Expansions", items = EXPANSION_ITEMS,
                isAll = function() return next(selectedExpansions()) == nil end,
                isSelected = function(key) return selectedExpansions()[key] == true end,
                onAll = function() selectedExpansions({}) end,
                onToggle = toggleExpansion })
            return expansionDD
        elseif node.id == "stkSource" then
            sourceDD = VWB.UI:CreateMultiSelectDropdown(parent, {
                width = node.size.w, height = node.size.h,
                allLabel = "All Sources", items = SOURCE_ITEMS,
                isAll = function() return next(selectedSources()) == nil end,
                isSelected = function(key) return selectedSources()[key] == true end,
                onAll = function() selectedSources({}) end,
                onToggle = toggleSource })
            return sourceDD
        elseif node.id == "stkList" then
            listWidget = VWB.UI:CreateVirtualizedList(parent, {
                rowHeight = VWB.Constants.UI.stockroomRowHeight,
                rowTemplate = rowTemplate,
                onRowClick = function(item) selectedItemID(item.itemID); selectedRecipeID(nil) end,
                updateRow = function(row, item)
                    row.data = item
                    row._selHL:SetShown(_stkCurSelectedID == item.itemID)
                    local s = VWB.UI:GetScheme()

                    row.icon:SetTexture(C_Item.GetItemIconByID(item.itemID) or QUESTION_ICON)

                    row.name:SetText(item.name or ("item:" .. tostring(item.itemID)))
                    if item.name and item.quality then
                        local qr, qg, qb = C_Item.GetItemQualityColor(item.quality)
                        row.name:SetTextColor(qr, qg, qb)
                    else
                        row.name:SetTextColor(s.text.r, s.text.g, s.text.b)
                    end

                    row.idText:SetText("#" .. item.itemID)
                    row.idText:SetTextColor(s.text.r, s.text.g, s.text.b)

                    local blabel, bscheme = badgeParts(item.info)
                    row.badge:SetText(blabel)
                    local classColor = s[bscheme]
                    row.badge:SetTextColor(classColor.r, classColor.g, classColor.b)

                    row.evidence:SetText(string.format("used in %d / makes %d", item.info.usedInCount, item.info.producedByCount))
                    row.evidence:SetTextColor(s.text.r, s.text.g, s.text.b)

                    local owned = ns.Inventory:GetItemCount(item.itemID)
                    row.owned:SetText(tostring(owned))
                    if owned > 0 then
                        row.owned:SetTextColor(s.success.r, s.success.g, s.success.b)
                    else
                        row.owned:SetTextColor(s.text.r, s.text.g, s.text.b)
                    end

                    if item.bop == true then
                        row.bop:SetText(VWB.UI:ColorCode("red") .. "BoP|r")
                        row.bop:Show()
                    else
                        row.bop:Hide()
                    end

                    if item.need and item.need.required > 0 then
                        row.need:SetText(string.format("Needed for queue: %d (have %d)", item.need.required, item.need.owned))
                        row.need:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
                        row.need:Show()
                    else
                        row.need:Hide()
                    end
                end,
                -- Per-row tooltip: the tab's core diagnostic surface (why is this
                -- classified this way, and what recipes actually touch it). Uses
                -- the addon's own Tooltip surface, not GameTooltip (SetHyperlink
                -- would bury this under Blizzard's equip-compare panels).
                onRowEnter = function(item, rowFrame)
                    local tip = VWB.UI.Tooltip
                    tip:Begin(rowFrame)
                    tip:SetItemHeader(item.itemID, item.name, item.quality)

                    local info = item.info
                    tip:AddLine(" ")
                    local tcode, tlabel = badgeCode(info)
                    tip:AddLine(string.format("%s%s|r - used in %d, makes %d",
                        VWB.UI:ColorCode(tcode), tlabel,
                        info.usedInCount, info.producedByCount))
                    if item.bop == true then
                        tip:AddLine(VWB.UI:ColorCode("red") .. "Binds on Pickup|r")
                    end
                    tip:AddLine(" ")
                    if #info.producedBy > 0 then
                        tip:AddLine(VWB.UI:ColorCode("cyan") .. "Produced by:|r")
                        local shown = math.min(#info.producedBy, 5)
                        for i = 1, shown do
                            tip:AddLine("  " .. ns.Database:GetRecipe(info.producedBy[i]).name, 0.85, 0.85, 0.85)
                        end
                        if #info.producedBy > shown then
                            tip:AddLine(string.format("  ...and %d more", #info.producedBy - shown), 0.6, 0.6, 0.6)
                        end
                    else
                        tip:AddLine(VWB.UI:ColorCode("base01") .. "Not produced by any known recipe.|r")
                    end

                    local owned = ns.Inventory:GetItemCount(item.itemID)
                    local c = VWB.UI:GetScheme()
                    tip:AddLine(" ")
                    tip:AddDoubleLine("Owned (bags/bank/warband)", tostring(owned), nil, nil, nil, c.success.r, c.success.g, c.success.b)
                    tip:Show()
                end,
                onRowLeave = function(_, rowFrame)
                    VWB.UI.Tooltip:Hide(rowFrame)
                end,
            })

            -- Empty states: bare (nothing harvested at all) vs no-search-results
            -- (harvested, but the filter/search excludes everything) -- shown/
            -- hidden by the R.effect below, same distinction VPC's PaintList drew.
            local emptyText = listWidget:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
            emptyText:SetPoint("CENTER", listWidget, "CENTER", 0, 0)
            emptyText:SetWidth(420)
            emptyText:SetWordWrap(true)
            emptyText:SetJustifyH("CENTER")
            emptyText:Hide()
            listWidget.emptyText = emptyText

            return listWidget
        elseif node.id == "stkDetailHeader" then
            detailHeader = ns.ViewKit.roleLabel(node, parent); return detailHeader
        elseif node.id == "stkDetailSub" then
            detailSub = ns.ViewKit.roleLabel(node, parent); return detailSub
        elseif node.id == "stkDetailUsedHdr" then
            detailUsedHdr = ns.ViewKit.roleLabel(node, parent); return detailUsedHdr
        elseif node.id == "stkDetailList" then
            detailListWidget = VWB.UI:CreateVirtualizedList(parent, {
                rowHeight = 18,
                rowTemplate = recipeRowTemplate,
                onRowClick = function(r) selectedRecipeID(r.recipeID) end,
                updateRow = function(row, r)
                    local s = VWB.UI:GetScheme()
                    row._selHL:SetShown(_stkCurSelectedRecipeID == r.recipeID) -- item 6: upvalue, not per-row closure
                    row.icon:SetTexture(r.icon or QUESTION_ICON)
                    row.rname:SetText(r.name)
                    row.rname:SetTextColor(s.text.r, s.text.g, s.text.b)
                    row.qty:SetText(r.qty and ("x" .. r.qty) or "")
                    row.qty:SetTextColor(s.text.r, s.text.g, s.text.b)
                    row.tag:SetText(r.kind)
                    local tc = (r.kind == "uses") and s.success or s.accent
                    row.tag:SetTextColor(tc.r, tc.g, tc.b)
                end,
            })
            return detailListWidget
        elseif node.id == "stkDetailAddBtn" then
            detailAddBtn = VWB.UI:CreateButton(parent, "Select a recipe to queue", 200, 22)
            -- OnClick is wired below (item 8) after handle build, so Nav.Go is available
            return detailAddBtn
        end
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.stockroom, { makeFrame = makeFrame, measure = Kit.measure })
    handle.byId.stkTitle.label:SetText(VWB.UI:ColorCode("yellow") .. "Stockroom|r")

    -- Item 7: consume VWB.Nav.pendingSearch on show/mount (read + clear contract).
    -- "queue" -> activate the Queue segment; any other non-nil string -> prefill
    -- the search box and clear the segment to "all". Signal always cleared after
    -- consumption regardless of the value.
    R.effect(function()
        local payload = ns.Nav.pendingSearch()
        if payload == nil then return end
        ns.Nav.pendingSearch(nil) -- clear first (read+clear contract)
        if payload == "queue" then
            filterMode("queue")
            filterWidget:SetSelected("queue")
        else
            search(payload:lower())
            searchWidget:SetText(payload)
            filterMode("all")
            filterWidget:SetSelected("all")
        end
    end, "stockroom:pendingNav")

    -- Item 8: "Add to Queue" navigates to Workbench so the queue entry is
    -- immediately visible for confirmation. Dispatch happens first; Nav.Go second
    -- so the Workbench's recipes effect sees the updated state on mount.
    detailAddBtn:SetScript("OnClick", function()
        local rid = _stkCurSelectedRecipeID -- upvalue: already untracked (item 6)
        if rid then
            ns.Store:Dispatch("ADD_TO_QUEUE", { recipeID = rid, qty = 1 })
            ns.Nav.Go("workbench")
        end
    end)

    -- Truly-cold corpus gets the one-click card instead of directions-only
    -- text (Workbench's pattern -- consistency review 2026-07-13).
    local emptyCard = VWB.UI:CreateEmptyStateCard(listWidget, {
        width = 320, height = 170,
        icon = "Interface\\Icons\\INV_Crate_01",
        title = "The stockroom is bare",
        body = "Nobody's catalogued a single reagent yet. Scan a profession window, or pull your guild's recipes in one pass.",
        buttonText = "Scan Guild Recipes",
        onClick = function()
            ns:ShowPage("data")
            ns.RecipeHarvest:Start()
        end,
    })
    emptyCard:SetPoint("CENTER", listWidget, "CENTER", 0, 10)
    emptyCard:SetFrameLevel(listWidget:GetFrameLevel() + 5)
    emptyCard:Hide()

    -- List data + empty states in one effect: bare vs no-search-results get
    -- distinct copy, same distinction VPC's PaintList drew.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        local list = items()
        listWidget:SetData(list)
        emptyCard:SetShown(#classified() == 0)
        if #classified() == 0 then
            listWidget.emptyText:Hide()
        elseif #list == 0 then
            listWidget.emptyText:SetText(VWB.UI:ColorCode("base01") ..
                "Nothing on the shelf matches that. Try a different filter or clear the search.|r")
            listWidget.emptyText:Show()
        else
            listWidget.emptyText:Hide()
        end
    end, "stockroom:list")

    -- Closed-trigger label: "All Expansions" when nothing's picked, the single
    -- expansion's name for one, else a count.
    R.effect(function()
        local sel = selectedExpansions()
        local n, last = 0, nil
        for k in pairs(sel) do n = n + 1; last = k end
        local label = (n == 0 and "All Expansions") or (n == 1 and labelForKey(last)) or (n .. " expansions")
        expansionDD:SetTriggerText(label)
    end, "stockroom:expansionLabel")

    -- Closed-trigger label: "All Sources" / the single method / a count.
    R.effect(function()
        local sel = selectedSources()
        local n, last = 0, nil
        for k in pairs(sel) do n = n + 1; last = k end
        local label = (n == 0 and "All Sources") or (n == 1 and SOURCE_LABEL[last]) or (n .. " sources")
        sourceDD:SetTriggerText(label)
    end, "stockroom:sourceLabel")

    -- Detail panel: the recipes that USE (and produce) the selected reagent -- the
    -- reverse lookup the hover tooltip only hinted at. Reactive on the selection +
    -- the corpus (a rescan can add recipes that touch this reagent).
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        local id = selectedItemID()
        ns.Store:Version("corpus")
        if not id then
            detailHeader.label:SetText(VWB.UI:ColorCode("base01") .. "Select a reagent|r")
            detailSub.label:SetText(VWB.UI:ColorCode("base01") .. "to see which recipes use it.|r")
            detailUsedHdr.label:SetText("")
            detailListWidget:SetData({})
            return
        end
        local info = ns.ReagentSource:GetInfo(id)
        local name = C_Item.GetItemInfo(id) or ("item:" .. id) -- exception(boundary): cold cache -> id fallback
        local owned = ns.Inventory:GetItemCount(id)
        detailHeader.label:SetText(name .. "   " .. VWB.UI:ColorCode("base01") .. "#" .. id .. "|r")
        local dcode, dlabel = badgeCode(info)
        detailSub.label:SetText(string.format("%s%s|r    owned: %s%d|r%s",
            VWB.UI:ColorCode(dcode), dlabel,
            owned > 0 and VWB.UI:ColorCode("green") or VWB.UI:ColorCode("base01"), owned,
            info.bop == true and ("    " .. VWB.UI:ColorCode("red") .. "BoP|r") or ""))
        detailUsedHdr.label:SetText(string.format("%sUsed in %d|r    %sMakes %d|r",
            VWB.UI:ColorCode("cyan"), info.usedInCount, VWB.UI:ColorCode("yellow"), info.producedByCount))
        local rows = {}
        local function addRecipes(ids, kind)
            local group = {}
            for _, rid in ipairs(ids) do
                local rec = ns.Database:GetRecipe(rid)
                if rec then
                    local q -- how many of THIS reagent the recipe consumes (uses side only)
                    if kind == "uses" and rec.slots then
                        q = 0
                        for _, slot in ipairs(rec.slots) do
                            if slot.type == "basic" and slot.itemID == id then q = q + (slot.qty or 0) end
                        end
                    end
                    group[#group + 1] = { recipeID = rid, name = rec.name or ("recipe:" .. rid), kind = kind, qty = q,
                        icon = rec.itemID and C_Item.GetItemIconByID(rec.itemID) }
                end
            end
            table.sort(group, function(a, b) return a.name < b.name end)
            for _, r in ipairs(group) do rows[#rows + 1] = r end
        end
        addRecipes(info.usedIn, "uses")
        addRecipes(info.producedBy, "makes")
        detailListWidget:SetData(rows)
    end, "stockroom:detail")

    -- Selection tint: repaint visible rows when the pick changes. Upvalue is
    -- pre-read ONCE here (item 6) so updateRow reads _stkCurSelectedID directly
    -- with zero per-row allocation (no R.untrack(function()...end) inside the loop).
    -- selectedItemID() is read tracked (establishes the dep); the value is also
    -- stored into the upvalue so the paint loop sees it immediately on this same call.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: row template color baked at pool time, re-pool on switch
        _stkCurSelectedID = selectedItemID() -- tracked + captured into upvalue
        listWidget:Refresh()
    end, "stockroom:selectionTick")

    -- Add-to-queue button reflects the picked recipe; a pick repaints the detail
    -- rows (highlight). Upvalue pre-read (item 6): _stkCurSelectedRecipeID set before
    -- Refresh so updateRow reads it directly without per-row closure allocation.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: recipe row template color baked at pool time
        local rid = selectedRecipeID() -- tracked dep; value also stored in upvalue
        _stkCurSelectedRecipeID = rid
        detailListWidget:Refresh()
        if rid then
            local rec = ns.Database:GetRecipe(rid)
            detailAddBtn:SetText("Add to Queue: " .. ((rec and rec.name) or ("recipe:" .. rid)))
        else
            detailAddBtn:SetText("Select a recipe to queue")
        end
    end, "stockroom:recipePick")

    -- Per-bucket totals over the UNFILTERED classified set -- a stable overview
    -- regardless of the current search/segment filter (same as VPC's footer).
    -- Tally is folded into the classified computed's own walk (see .totals);
    -- this just formats it -- no second walk of the classified set.
    R.bindText(handle.byId.stkFooter.label, function()
        local list = classified()
        local exp = selectedExpansions()
        local src = selectedSources()
        local expA, srcA = next(exp) ~= nil, next(src) ~= nil
        local fb, cr
        if not expA and not srcA then
            local t = list.totals -- unfiltered: use the tally folded into the classified walk
            fb, cr = t.farmbuy, t.crafted
        else
            fb, cr = 0, 0 -- filtered: re-tally over the matching materials
            for _, rec in ipairs(list) do
                if (not expA or matchesExp(rec.expansions, exp)) and (not srcA or matchesSource(rec.info, src)) then
                    local c = rec.info.class
                    if c == "farmbuy" then fb = fb + 1
                    elseif c == "crafted" then cr = cr + 1 end
                end
            end
        end
        return string.format("%s%d|r farm/buy   %s%d|r crafted   %stotal materials:|r %s%d|r",
            VWB.UI:ColorCode("green"), fb, VWB.UI:ColorCode("cyan"), cr,
            VWB.UI:ColorCode("base01"), VWB.UI:ColorCode("base1"), fb + cr)
    end)

    -- Owned counts aren't Reactor-tracked (Inventory sits outside the Store),
    -- so a bag/bank/warband change needs its own repaint hook -- Refresh()
    -- re-realizes the visible rows through the same updateRow path without
    -- re-deriving classified/items (owned isn't part of either).
    ns.EventBus:Register("VWB_INVENTORY_UPDATE", function() listWidget:Refresh() end)

    return handle
end

return Stockroom
