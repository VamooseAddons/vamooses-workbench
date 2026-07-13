-- ============================================================================
-- VWB Showroom - VIEW / controller (WoW glue). Slice 3: PARITY PASS.
-- ============================================================================
-- Wires the (headless-tested) Showroom_Model to real data: recipes come from
-- the recipeStore signal via RecipeQuery, classification (kind) + collection
-- (collected) are Reactor RESOURCES over the ported Decor/Transmog/Collectibles
-- modules, and the header widgets drive the filter signals. The item list is a
-- real virtualized scrollbox fed by ONE effect over model.filteredItems -- so
-- collectibles appear as their item data resolves, with zero manual refresh
-- wiring. That is the cold-cache bug (pets-don't-show-till-click-away) deleted
-- structurally.
--
-- This pass brings it toward parity with VPC's Preview.lua: a real profession
-- tab bar, an expansion/category nav tree (Store ui slice owns selection +
-- collapse), row tooltips, alphabetical sort, a working Add to Queue + recent-
-- previews strip, contextual empty-state text, and LIVE collection-update
-- invalidation (decor/transmog/mount/pet collecting something flips its tick
-- immediately -- no more stale-until-reload).
-- ============================================================================

local _, ns = ...
local Showroom = ns.Showroom or {}
ns.Showroom = Showroom

local TICK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- (UncollectedCount export removed 2026-07-11: the nav badge now reads the
-- global filter-independent VWB.Collectibles.UncollectedCount computed, which
-- is live WITHOUT mounting this view -- the old export was nil until first
-- mount and counted only the current filter universe.)
local TYPE_SEGMENTS = {
    { key = "all", label = "All" }, { key = "decor", label = "Decor" },
    { key = "transmog", label = "Transmog" }, { key = "mount", label = "Mount" },
    { key = "pet", label = "Pet" },
}
local DEFAULT_DECOR_SCENE_ID = 859 -- Blizzard housing preview scene; ported from VPC's decor route fallback
local COLLECT_LABEL = { decor = "Decor", transmog = "Appearance", mount = "Mount", pet = "Pet" }
local RECENT_CHIP = 18 -- recent-previews chip size, ported from VPC's Preview.lua

-- Classification + collection, derived over LATCHES (Constitution step 4).
-- The two RESOURCES that lived here owned their own RequestLoad + event
-- re-read wiring -- parallel requesters beside the ItemData broker, and the
-- invalidateAll web that re-read (and on cold keys re-REQUESTED) the universe
-- per settle. Deleted. Classification now derives at read time from
-- eviction-proof sources only: GetItemInfoInstant static data (transmog
-- scope), the static mount map, decor ownership latches, and broker records
-- (which carry latch-time isPet -- pet detection needs full item data, so it
-- is a latch-time fact, not a read-time one). peek() keeps the old resource
-- contract (acquires on first sight, untracked read, kind|PENDING out);
-- epoch() is the composite of every source that can change an answer, so
-- Showroom_Model's one-dep + peek-walk shape is untouched.
local kindRes, collectedRes
local function ensureResources()
    if kindRes then return end
    local PENDING = ns.Reactor.PENDING

    local function deriveKind(itemID)
        -- Cache-FREE checks first (order preserved from the resource era: a
        -- mount/transmog classifies instantly even cold; the JC-mounts lesson).
        -- Transmog: an equippable slot is necessary but NOT sufficient -- the
        -- item must have a real wardrobe APPEARANCE to be a collectible (owner
        -- 2026-07-13). No-appearance crafted gear (occupies a visual slot, but
        -- nothing to collect) was classified "transmog" and counted as
        -- "missing", inflating the breadcrumb above the nav badge -- which
        -- gates on IsUnknown = hasAppearance and not collected. hasAppearance
        -- needs the item record, so this can be PENDING until it lands.
        if ns.Transmog:IsTransmoggable(itemID) then
            if ns.Transmog:GetStatus(itemID).hasAppearance then return "transmog" end
            if VWB.ItemData.query(itemID) == PENDING then return PENDING end -- record still loading; re-derive on landing
            return "none" -- equippable but no collectible appearance
        end
        if ns.Collectibles:IsMount(itemID) then return "mount" end
        local dec = ns.DecorOwnership:IsUncollected(itemID) -- true/false/nil(cold)
        if dec ~= nil then return "decor" end
        local rec = VWB.ItemData.query(itemID) -- acquires once (R4); untracked
        if rec == PENDING then return PENDING end
        if rec ~= VWB.ItemData.DEAD and rec ~= VWB.ItemData.NODATA and rec.isPet then return "pet" end
        if ns.DecorOwnership:IsCatalogCold() then return PENDING end -- might be decor; resolves when the catalog warms
        return "none" -- incl. terminal no-data/dead ids: never classifiable
    end

    local function deriveCollected(itemID)
        local m = ns.Collectibles:IsMountCollected(itemID); if m ~= nil then return m end
        local k = deriveKind(itemID)
        if k == PENDING then return PENDING end
        if k == "pet" then return ns.Collectibles:IsPetCollected(itemID) == true end
        if k == "transmog" then return ns.Transmog:GetStatus(itemID).isCollected end
        if k == "decor" then return not ns.DecorOwnership:IsUncollected(itemID) end
        return false
    end

    -- One subscription covering every input that can flip a derived answer:
    -- broker records landing, mount/pet/transmog collection changes (the
    -- Collectibles store, incl. the batch transmog settle), decor ownership
    -- reconciles. THROTTLED: during item-data warmup a batch of records lands
    -- every frame, and re-deriving filteredItems/nav/list per frame cost
    -- ~70ms flushes for ~100 frames (live 2026-07-11 night). The throttle
    -- effect owns the raw subscription and forwards it into uiEpoch at most
    -- once per window; consumers subscribe uiEpoch. This is a RATE LIMITER on
    -- a genuine change signal, not a changeless counter (R3): every bump has
    -- at least one real underlying change behind it. Post-warmup a lone
    -- change repaints within the window (0.4s).
    local uiEpoch = ns.Reactor.signal(0)
    local epochSettle = nil
    ns.Reactor.effect(function()
        local _ = VWB.ItemData.changedEpoch()
            + ns.Collectibles.CollectionEpoch()
            + ns.DecorOwnership.Epoch()
        if epochSettle then return end
        epochSettle = VWB.ReactorWoW.after(0.4, function()
            epochSettle = nil
            uiEpoch(uiEpoch() + 1) -- boundary write: timer callback latches the coalesced change
        end)
    end, "showroom:epochThrottle")

    local function compositeEpoch() return uiEpoch() end

    -- Callable like the resources they replaced (Showroom_Model passes these
    -- through as kindOf/collectedOf, and the detail pane CALLS them for the
    -- selected item -- live crash 2026-07-11 21:14 when they were plain
    -- tables). A call is a tracked single-key read: it subscribes the
    -- throttled composite so the pane repaints when the answer can change.
    kindRes = setmetatable({ peek = deriveKind, epoch = compositeEpoch },
        { __call = function(_, id) compositeEpoch(); return deriveKind(id) end })
    collectedRes = setmetatable({ peek = deriveCollected, epoch = compositeEpoch },
        { __call = function(_, id) compositeEpoch(); return deriveCollected(id) end })

    -- No invalidateAll, no event registrations, no collection listener: every
    -- live update reaches the view through the composite epoch (decor
    -- reconciles bump DecorOwnership.Epoch; mount/pet/transmog changes bump
    -- Collectibles.CollectionEpoch; record latches bump ItemData.changedEpoch)
    -- and the derive functions read the CURRENT latches on the next walk.
    -- The whole "re-read the right subset per event" problem dissolved with
    -- the stored per-key state it existed to refresh.
end

-- The full craftable universe (rank-collapsed), reshaped to the light record
-- the Showroom needs: name/profession/expansion/categoryName for grouping +
-- filtering, recipeID for Add to Queue / recent-previews. A COMPUTED, not a
-- plain function: it memoizes on Store:Version("corpus") and is shared by
-- recipes()/buildNavSections, so the RecipeQuery:GetFiltered walk runs ONCE per
-- harvest instead of on every reader's recompute (was ~12x/session -- the
-- profiler's top hotspot). corpus (not recipes): the universe is a pure function
-- of recipe DEFINITIONS, so a known-status scan must not re-walk it. Reactor's
-- memoization replaces a hand-rolled cache.
-- Showroom is the ITEM-collection axis (keyed by itemID -- what you want to
-- OWN), distinct from the Workbench's recipe axis (keyed by recipeID -- what
-- you can MAKE). So the universe is UNIQUE ITEMS: an item craftable by two
-- recipes is ONE collectible, counted once (owner 2026-07-13 -- the badge
-- already dedupes by itemID, so the per-recipe list over-counted against it).
-- First recipe seen wins the row's recipeID (rank-collapse already merged
-- rank variants; this collapses cross-recipe itemID dupes). Pure function of
-- definitions -> the "corpus" memoization holds.
local universe = ns.Reactor.named("showroom:universe", function()
    ns.Store:Version("corpus")
    local out, seen = {}, {}
    for _, e in ipairs(ns.RecipeQuery:GetFiltered({ collapseRanks = true })) do
        local r = e.recipe
        if r.itemID and not seen[r.itemID] then -- exception(nullable): enchant recipes have no output item -> nothing to preview/collect, and kind()/collected() would GetItemInfo(nil)
            seen[r.itemID] = true
            out[#out + 1] = { recipeID = e.recipeID, itemID = r.itemID, name = r.name,
                profession = r.profession, expansion = r.expansion, categoryName = r.categoryName }
        end
    end
    return out
end)

-- The model's item universe: universe() narrowed to the nav tree's selected
-- category (Store ui slice, SET_NAV_SELECTION), alphabetically sorted. Also a
-- computed -- memoized per recipes/ui change, shared by the model's filteredItems.
local recipes = ns.Reactor.named("showroom:categoryItems", function()
    ns.Store:Version("nav")
    local navItem = ns.Store:GetState().ui.navSelectedItem
    -- nav keys are "<expansion>::<category>": match BOTH halves. Matching the
    -- category alone showed Devices from every expansion against a per-
    -- expansion tree count (tester 2026-07-12: "Devices says 5, list shows
    -- 28"). "*" is the section's All item (whole expansion); "Uncategorized"
    -- mirrors the tree's nil-category label.
    local exp = navItem and navItem:match("^(.-)::")
    local categoryName = navItem and navItem:match("::(.+)$")
    local out = {}
    for _, item in ipairs(universe()) do
        if not navItem or (item.expansion == exp
            and (categoryName == "*" or (item.categoryName or "Uncategorized") == categoryName)) then
            out[#out + 1] = item
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end)

-- A themed item-list row: icon | name | collected tick. ----------------------
local function listRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(16, 16); icon:SetPoint("LEFT", 3, 0)
    frame.icon = icon
    local tick = frame:CreateTexture(nil, "OVERLAY"); tick:SetSize(14, 14); tick:SetPoint("RIGHT", -4, 0); tick:SetTexture(TICK_TEXTURE); tick:Hide()
    frame.tick = tick
    local text = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0); text:SetPoint("RIGHT", tick, "LEFT", -4, 0); text:SetJustifyH("LEFT")
    frame.text = text
    -- Item 6a: shimmer attached once at factory time (AnimationGroups must not be
    -- created at paint time). Handle set/cleared in the updateRow path.
    frame._shimmerHandle = ns.UI:AttachShimmer(frame)
end

function Showroom.buildView(container)
    ensureResources()
    local R = ns.Reactor
    local filters = {
        typeMode = R.signal("all"), missingMode = R.signal(false),
        search = R.signal(""), profession = R.signal("all"),
    }
    local model = ns.Showroom.buildModel({ recipes = recipes, kind = kindRes, collected = collectedRes, filters = filters })
    local selected = R.signal(nil) -- captured for the model-preview slice
    local undressMode = R.signal(false)
    local listWidget, navTree, recentStripFrame, addToQueueBtn, startProjectBtn
    local modelDressFrame, modelCreatureFrame, modelSceneFrame
    local itemNameFS, itemDetailsFS, undressWidget
    local searchBox, typeToggleWidget, profBar, missingPillWidget

    -- Any category pick or non-default filter (owner 2026-07-13: "All/All"
    -- read as several-thousand but showed 859 -- a category was silently
    -- selected). This drives the Reset button's visibility AND is the honest
    -- answer to "why so few": a category narrows the list, the badge counts
    -- the whole corpus.
    local function anyFilterActive()
        ns.Store:Version("nav")
        return filters.search() ~= "" or filters.profession() ~= "all"
            or filters.typeMode() ~= "all" or filters.missingMode()
            or ns.Store:GetState().ui.navSelectedItem ~= nil
    end
    local function resetFilters()
        filters.profession("all"); filters.typeMode("all"); filters.missingMode(false)
        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = nil, item = nil })
        if searchBox then searchBox:Clear() end -- Clear() also writes filters.search("")
        if profBar then profBar:Select("all") end
        if typeToggleWidget then typeToggleWidget:SetSelected("all") end
        if missingPillWidget then missingPillWidget:SetChecked(false) end
        if navTree then navTree:Select(nil) end
    end

    -- Selecting an item captures it for the model-preview effect AND records
    -- it in the persisted recent-previews ring (Store dedupes+caps; the
    -- reducer owns the mutation, this just hands it a plain record).
    local function selectItem(item)
        selected(item)
        ns.Store:Dispatch("PUSH_RECENT_PREVIEWED", { item = {
            itemID = item.itemID, name = item.name, expansion = item.expansion,
            recipeID = item.recipeID, profession = item.profession,
        } })
    end

    -- Does itemID's kind+collection state pass the active type/missing
    -- filters? (Profession/search are judged over the recipe-level fields in
    -- buildNavSections itself; this only judges the async-resolved half, same
    -- split Showroom_Model.passes uses for the item list.)
    local function passesTypeAndMissing(itemID)
        local k = kindRes.peek(itemID) -- untracked; buildNavSections depends on kindRes.epoch() instead
        if k == R.PENDING or k == "none" then return false end
        if filters.typeMode() ~= "all" and k ~= filters.typeMode() then return false end
        if filters.missingMode() and collectedRes.peek(itemID) ~= false then return false end
        return true
    end

    -- Nav sections: expansion -> category counts over the SAME scope as the
    -- item list (profession/search/type/missing) but WITHOUT the nav's own
    -- category pick -- so choosing a category doesn't collapse its siblings
    -- out from under it. Mirrors VPC Preview.lua's RefreshNavTree.
    local function buildNavSections()
        ns.Store:Version("nav") -- navSelected/navCollapsed slice
        kindRes.epoch() -- O(1) classification dep; passesTypeAndMissing peeks per item
        if filters.missingMode() then collectedRes.epoch() end
        local navCollapsed = ns.Store:GetState().ui.navCollapsed
        local prof, q = filters.profession(), filters.search()
        local expCats = {} -- exp -> { catName -> count }
        for _, item in ipairs(universe()) do
            if (prof == "all" or item.profession == prof)
                and (q == "" or (item.name or ""):lower():find(q, 1, true))
                and passesTypeAndMissing(item.itemID) then
                local cats = expCats[item.expansion]
                if not cats then cats = {}; expCats[item.expansion] = cats end
                local cat = item.categoryName or "Uncategorized"
                cats[cat] = (cats[cat] or 0) + 1
            end
        end

        local ED = ns.Data.ExpansionData
        local sections = {}
        for exp, cats in pairs(expCats) do
            local catOrder = {}
            for cat in pairs(cats) do catOrder[#catOrder + 1] = cat end
            table.sort(catOrder)
            local items, total = {}, 0
            for _, cat in ipairs(catOrder) do
                total = total + cats[cat]
                items[#items + 1] = { key = exp .. "::" .. cat, label = cat, count = cats[cat] }
            end
            -- leading "All" selects the whole expansion (Study's section
            -- pattern; owner 2026-07-12) -- key "<exp>::*"
            table.insert(items, 1, { key = exp .. "::*", label = "All", count = total })
            local info = ED.GetExpansionInfo(exp)
            sections[#sections + 1] = {
                key = exp, label = info and info.display or exp, color = ED.GetColor(exp),
                collapsed = navCollapsed[exp] or false, itemCount = total, items = items,
                order = info and info.order or 999,
            }
        end
        table.sort(sections, function(a, b) return a.order < b.order end)
        return sections
    end
    -- Memoized: the tree effect, the collapse-all button, and its label share one walk.
    local navSections = R.named("showroom:navSections", buildNavSections)

    local function makeFrame(node, parent)
        if node.id == "search" then
            searchBox = ns.UI:CreateSearchBox(parent, { placeholder = "Search items...",
                onChange = function(text) filters.search((text or ""):lower()) end })
            return searchBox
        elseif node.id == "typeToggle" then
            typeToggleWidget = ns.UI:CreateSegmentedToggle(parent, {
                width = (node.size and node.size.w) or 300, height = (node.size and node.size.h) or 18,
                segments = TYPE_SEGMENTS, default = "all", onSelect = function(key) filters.typeMode(key) end })
            return typeToggleWidget
        elseif node.id == "missingPill" then
            missingPillWidget = ns.UI:CreateFilterPill(parent, "Missing", function(checked) filters.missingMode(checked and true or false) end)
            return missingPillWidget
        elseif node.id == "resetFilters" then
            local btn = ns.UI:CreateButton(parent, "Reset filters", 100, 18)
            btn:SetScript("OnClick", resetFilters)
            R.bindShown(btn, anyFilterActive)
            return btn
        elseif node.id == "profbar" then
            local profs = { { key = "all", label = "All Professions", abbrev = "All", icon = "Interface\\Icons\\INV_Misc_Book_09" } }
            for _, p in ipairs(ns.RecipeQuery:GetProfessions()) do profs[#profs + 1] = p end
            profBar = ns.UI:CreateProfessionTabBar(parent, profs, function(key) filters.profession(key) end)
            profBar:Select("all")
            return profBar
        elseif node.id == "navLabel" then
            local f = CreateFrame("Frame", nil, parent)
            local fs = f:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            fs:SetText(ns.UI:ColorCode("cyan") .. "Categories|r")
            fs:SetPoint("LEFT", 4, 0)
            f.collapseBtn = ns.UI:AddCollapseAllButton(f, navSections, { effectName = "showroom:collapseAllLabel" })
            return f
        elseif node.id == "navTree" then
            navTree = ns.UI:CreateNavTree(parent, {
                onHeaderClick = function(key)
                    ns.Store:Dispatch("TOGGLE_NAV_COLLAPSE", { key = key })
                end,
                -- Tester bug (reganart, test1): the +/- arrow has its own hit
                -- area (child Button wins the click), so WITHOUT this handler
                -- the arrow strip ate clicks and did nothing -- worse than
                -- dead. Same toggle as the header.
                onArrowClick = function(key)
                    ns.Store:Dispatch("TOGGLE_NAV_COLLAPSE", { key = key })
                end,
                onItemClick = function(key)
                    if ns.Store:GetState().ui.navSelectedItem == key then
                        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = nil, item = nil })
                        navTree:Select(nil)
                    else
                        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = key:match("^(.-)::"), item = key })
                    end
                end,
            })
            navTree:Select(ns.Store:GetState().ui.navSelectedItem)
            return navTree
        elseif node.id == "list" then
            listWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = 22,
                rowTemplate = listRowTemplate,
                updateRow = function(row, item)
                    row.data = item
                    row.icon:SetTexture(C_Item.GetItemIconByID(item.itemID) or VWB.Constants.ICON_QUESTION)
                    row.text:SetText(item.name or ("item:" .. tostring(item.itemID)))
                    row.tick:SetShown(model.collectedOf.peek(item.itemID) == true) -- peek: untracked, so updateRow doesn't link per-row deps into showroom:list (collectionTick drives repaint)
                    -- Item 6a: shimmer while kind is PENDING (row is in the list but
                    -- still classifying). filteredItems excludes PENDING items by default,
                    -- so this path only fires for rows that JUST resolved and are being
                    -- repainted with their first real kind value (or cold-cache rows that
                    -- passed into the list while pending). Peek is untracked here.
                    local k = kindRes.peek(item.itemID)
                    row._shimmerHandle:SetShimmering(k == R.PENDING)
                end,
                onRowClick = function(item) selectItem(item) end,
                onRowEnter = function(item, rowFrame)
                    local tip = ns.UI.Tooltip
                    tip:Begin(rowFrame)
                    tip:SetItemHeader(item.itemID, item.name)
                    if item.profession then tip:AddLine(ns.UI:ColorCode("base01") .. item.profession .. "|r") end
                    tip:Show()
                end,
                onRowLeave = function(_, rowFrame) ns.UI.Tooltip:Hide(rowFrame) end,
            })
            ns.UI:AddEmptyOverlayText(listWidget)
            return listWidget
        elseif node.id == "modelDress" then
            modelDressFrame = CreateFrame("DressUpModel", nil, parent)
            modelDressFrame:SetFacing(0.5)
            ns.UI:WireModelControls(modelDressFrame)
            return modelDressFrame
        elseif node.id == "modelCreature" then
            modelCreatureFrame = CreateFrame("PlayerModel", nil, parent)
            modelCreatureFrame:SetFacing(0.5)
            modelCreatureFrame:Hide() -- dress route is the default until a mount/pet is selected
            ns.UI:WireModelControls(modelCreatureFrame)
            return modelCreatureFrame
        elseif node.id == "modelScene" then
            modelSceneFrame = CreateFrame("ModelScene", nil, parent, "PanningModelSceneMixinTemplate")
            modelSceneFrame:Hide() -- dress route is the default until a decor item is selected
            return modelSceneFrame
        elseif node.id == "controlsHint" then
            local s = ns.UI:GetScheme()
            local fs = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            fs:SetText("Drag to rotate - scroll to zoom")
            fs:SetJustifyH("CENTER") -- spans the model area (fill width); centre the text within it
            fs:SetTextColor(s.text.r, s.text.g, s.text.b)
            VWB.Theme:Register(fs, "DimLabel")
            return fs
        elseif node.id == "itemName" then
            local s = ns.UI:GetScheme()
            itemNameFS = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalLarge")
            itemNameFS:SetTextColor(s.text_header.r, s.text_header.g, s.text_header.b)
            VWB.Theme:Register(itemNameFS, "HeaderLabel")
            return itemNameFS
        elseif node.id == "itemDetails" then
            local s = ns.UI:GetScheme()
            itemDetailsFS = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            itemDetailsFS:SetTextColor(s.text.r, s.text.g, s.text.b)
            VWB.Theme:Register(itemDetailsFS, "Label")
            return itemDetailsFS
        elseif node.id == "undress" then
            undressWidget = ns.UI:CreateCheckbox(parent, "Undress", function(checked)
                undressMode(checked and true or false)
            end)
            return undressWidget
        elseif node.id == "recentStrip" then
            recentStripFrame = CreateFrame("Frame", nil, parent)
            return recentStripFrame
        elseif node.id == "addToQueue" then
            addToQueueBtn = ns.UI:CreateButton(parent, "Add to Queue", 100, 22)
            addToQueueBtn:SetScript("OnClick", function()
                local item = selected()
                ns.Store:Dispatch("ADD_TO_QUEUE", { recipeID = item.recipeID, qty = 1 })
                -- Item 5b: navigate to Workbench after queueing so the user sees the entry.
                ns.Nav.Go("workbench")
            end)
            addToQueueBtn:Hide()
            return addToQueueBtn
        elseif node.id == "startProject" then
            -- Item 4: Start Project button. Dispatches ADD_PROJECT for the selected item,
            -- then navigates to the Projects view with the new project selected.
            -- THE shared Commission control (lifecycle spec 5): one visible
            -- dropdown replaces Start Project + its hidden right-click menu.
            -- Never navigates (owner: players scan-and-create in bulk).
            startProjectBtn = ns.UI:CreateCommissionDropdown(parent, {
                width = 110,
                context = function()
                    local item = selected()
                    if not item then return nil end -- exception(boundary): SetupMenu pre-generates before any selection
                    return {
                        name = item.name or ("item:" .. tostring(item.itemID)),
                        count = 1,
                        defaultStatus = "bench", -- Showroom default: you're ready to work it
                        source = { type = "showroom" },
                        pieces = function()
                            return { { itemID = item.itemID, recipeID = item.recipeID,
                                kind = "collect", name = item.name } }
                        end,
                    }
                end,
            })
            startProjectBtn:Hide()
            return startProjectBtn
        end
        -- themed placeholder for any node this view hasn't wired real content into
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.showroom, { makeFrame = makeFrame, measure = VWB.ViewKit.measure })
    -- Details gets TWO lines (h=28 in the LayoutConfig): the engine's role
    -- default forces no-wrap ellipsis at build; re-enable wrap here so the
    -- Profession | Expansion | collected line never truncates beside the
    -- button column (live report: "Expansion: Battle for...").
    itemDetailsFS:SetWordWrap(true)
    itemDetailsFS:SetMaxLines(2)
    itemDetailsFS:SetJustifyH("LEFT")
    itemDetailsFS:SetJustifyV("TOP")
    handle.model = model
    handle.selected = selected

    -- THE unlock: one effect pushes the filtered collectibles into the list, so
    -- rows appear as classification resolves -- no click-away, no manual refresh.
    -- Also owns the empty-state caption: a blank list is ambiguous (nothing
    -- here? filters too tight? a bug?) -- name the reason instead of going quiet.
    -- Truly-cold corpus: the text empty-states below explain FILTER misses;
    -- a fresh install needs the one-click fix instead.
    local emptyCard = ns.UI:CreateScanGuildCard(listWidget)

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        local items = model.filteredItems()
        listWidget:SetData(items)
        emptyCard:SetShown(#items == 0 and #universe() == 0)
        if #items > 0 or #universe() == 0 then
            listWidget.emptyText:Hide()
        else
            local msg
            local typeMode = filters.typeMode()
            -- F2 FIX: when the decor catalog is cold, a decor-scoped empty list is NOT
            -- "no results" -- it's "catalog not loaded yet". Show the honest message that
            -- Workbench already uses (ported from Recipes_View.lua's equivalent guard).
            -- Guard fires when: typeMode=="decor" OR (typeMode=="all" and decor catalog cold).
            -- exception(boundary): IsCatalogCold is a Blizzard housing API state check.
            if (typeMode == "decor" or typeMode == "all") and ns.DecorOwnership:IsCatalogCold() then
                msg = "Open the housing catalog once this session, then come back."
            elseif filters.missingMode() then
                msg = "Nothing left to collect here - you've got it all."
            elseif typeMode ~= "all" then
                msg = "No " .. typeMode .. " collectibles match your filters."
            else
                msg = "Nothing matches - try a different category, profession, or search."
            end
            listWidget.emptyText:SetText(msg)
            listWidget.emptyText:Show()
        end
    end, "showroom:list")

    -- Row ticks read collectedOf() at paint time (not reactively), so a collect
    -- event won't flip a visible tick on its own. collectedRes.epoch() bumps when
    -- collection changes -> re-run the row initializer on visible rows. When
    -- missingMode is on the list effect above already re-derives membership; this
    -- is the tick-only path for the far more common missingMode-off case.
    R.effect(function() VWB.Theme.epoch(); collectedRes.epoch(); listWidget:Refresh() end, "showroom:collectionTick") -- theme epoch: repaint on switch

    -- Nav tree data: rebuilds whenever the recipe universe, profession/type/
    -- missing/search scope, classification, or collapse state changes. Memoized:
    -- the tree effect, the collapse-all label, and the button click all share
    -- one walk.
    R.effect(function() VWB.Theme.epoch(); navTree:SetData(navSections()) end, "showroom:nav") -- theme epoch: repaint on switch


    -- Recent-previews strip: persisted ring (Store ui.recentPreviewed), chips
    -- rebuilt whenever it changes. Pooled buttons -- ported from VPC's
    -- Preview.lua MakeRecentChip/UpdateRecentStrip.
    local recentChips = {}
    local function acquireRecentChip()
        local b = CreateFrame("Button", nil, recentStripFrame)
        b:SetSize(RECENT_CHIP, RECENT_CHIP)
        b:RegisterForClicks("AnyUp")
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(); icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.icon = icon
        b:SetScript("OnClick", function(self) selectItem(self._data) end)
        b:SetScript("OnEnter", function(self)
            local tip = ns.UI.Tooltip
            tip:Begin(self); tip:SetItemHeader(self._data.itemID, self._data.name); tip:Show()
        end)
        b:SetScript("OnLeave", function(self) ns.UI.Tooltip:Hide(self) end)
        return b
    end
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint on switch
        ns.Store:Version("recent")
        local ring = ns.Store:GetState().ui.recentPreviewed
        local xOff = 0
        for i, data in ipairs(ring) do
            local chip = recentChips[i] or acquireRecentChip()
            recentChips[i] = chip
            chip._data = data
            chip.icon:SetTexture(data.itemID and C_Item.GetItemIconByID(data.itemID) or VWB.Constants.ICON_QUESTION)
            chip:ClearAllPoints()
            chip:SetPoint("LEFT", recentStripFrame, "LEFT", xOff, 0)
            chip:Show()
            xOff = xOff + RECENT_CHIP + 4
        end
        for i = #ring + 1, #recentChips do recentChips[i]:Hide() end
    end, "showroom:recent")

    -- Breadcrumb: live counts off the model.
    R.bindText(handle.byId.breadcrumb.label, function()
        local c = model.breadcrumb()
        return string.format("%d shown   %d known   %d missing", c.total, c.known, c.uncollected)
    end)

    -- Re-base the dress-up model for a fresh TryOn while PRESERVING the user's
    -- pose: facing and zoom survive item switches (only the model's own
    -- right-click resets them, via WireModelControls). Ported from VPC's
    -- Preview.lua RebaseModel.
    local function rebaseDressModel()
        local facing = modelDressFrame:GetFacing() or 0 -- exception(nullable): unit-less model (first open) has no facing yet
        modelDressFrame:SetUnit("player")
        modelDressFrame:SetPosition(0, 0, 0)
        modelDressFrame:SetFacing(facing)
        if modelDressFrame._zoom then modelDressFrame:SetPortraitZoom(modelDressFrame._zoom) end -- exception(nullable): never-zoomed model has no stored zoom
        if undressMode() then modelDressFrame:Undress() end -- show ONLY the previewed piece
    end

    -- Model preview: rebases the stage to whichever collectible kind is
    -- selected. Only ONE model frame is ever shown -- kind picks the route:
    -- creature (mount/pet display ID), decor (housing ModelScene), or the
    -- dressing room (transmog TryOn). model.kindOf is memoized per itemID and
    -- already resolved by click time (filteredItems excludes PENDING/"none"
    -- kinds), so the branch below is a strict read, not a defensive guard.
    -- Ported from VPC's UpdatePreview/RebaseModel.
    R.effect(function()
        local item = selected()
        if not item then
            modelCreatureFrame:Hide()
            modelSceneFrame:Hide()
            modelDressFrame:Show()
            modelDressFrame:ClearModel()
            undressWidget:Show()
            itemNameFS:SetText("")
            itemDetailsFS:SetText("")
            addToQueueBtn:Hide()
            startProjectBtn:Hide()
            return
        end

        itemNameFS:SetText(item.name or ("item:" .. tostring(item.itemID)))
        -- VPC-parity pretty text: era-colored name, dim labels + colored values
        if item.expansion then
            ns.Data.ExpansionData.SetTextColor(itemNameFS, item.expansion)
        else
            local sc = ns.UI:GetScheme()
            itemNameFS:SetTextColor(sc.text_header.r, sc.text_header.g, sc.text_header.b)
        end
        addToQueueBtn:Show()
        startProjectBtn:Show()
        local kind = model.kindOf(item.itemID)
        local collected = model.collectedOf(item.itemID)
        local dim = ns.UI:ColorCode("base01")
        local details = {}
        if item.profession then details[#details + 1] = dim .. "Profession: |r" .. item.profession end
        if item.expansion then
            local ec = ns.Data.ExpansionData.GetColor(item.expansion)
            if ec then
                details[#details + 1] = dim .. "Expansion: |r|cFF" .. ns.UI:ToHex(ec) .. item.expansion .. "|r"
            else -- exception(nullable): legacy/unaliased expansion label
                details[#details + 1] = dim .. "Expansion: |r" .. item.expansion
            end
        end
        -- ITEM knowledge line (knowledge-domain ruling 2026-07-11): the
        -- collection noun (Appearance/Mount/Pet/Decor) states the item side.
        -- Guard the label: kind can be "none"/PENDING for non-collectibles in
        -- the universe (concat on nil was a latent crash next to the live one).
        if collected ~= R.PENDING and COLLECT_LABEL[kind] then
            details[#details + 1] = dim .. COLLECT_LABEL[kind] .. ": |r"
                .. (collected and (ns.UI:ColorCode("green") .. "collected|r")
                    or (ns.UI:ColorCode("cyan") .. "NOT collected|r"))
        end
        -- RECIPE knowledge line beside it -- the supply-side answer for the
        -- same item, and the cross-domain action hint (who could craft this).
        local knownBy = ns.KnownRecipes:KnownByList(item.recipeID)
        if #knownBy > 0 then
            details[#details + 1] = dim .. "Recipe known by: |r" .. table.concat(knownBy, ", ")
        else
            details[#details + 1] = dim .. "Recipe: |r" .. ns.UI:ColorCode("cyan") .. "unlearned on this account|r"
            -- Acquisition source (prof book's "Recipe Unlearned" hover text);
            -- answers cold, embedded label colors per line. Undocumented API,
            -- verified live 2026-07-11.
            local src = C_TradeSkillUI.GetRecipeSourceText(item.recipeID) -- exception(boundary): nil when the server has no acquisition data for this recipe
            if src then
                for line in src:gmatch("[^\n]+") do
                    details[#details + 1] = line
                end
            end
        end

        if kind == "mount" or kind == "pet" then
            modelSceneFrame:Hide()
            modelDressFrame:Hide()
            undressWidget:Hide()
            modelCreatureFrame:Show()
            local displayID = (kind == "mount") and ns.Collectibles:MountDisplayID(item.itemID)
                or ns.Collectibles:PetDisplayID(item.itemID)
            if displayID and displayID > 0 then
                modelCreatureFrame:SetDisplayInfo(displayID)
            else
                modelCreatureFrame:ClearModel() -- exception(nullable): display id not resolved yet
            end
        elseif kind == "decor" then
            modelCreatureFrame:Hide()
            modelDressFrame:Hide()
            undressWidget:Hide()
            local catInfo = C_HousingCatalog.GetCatalogEntryInfoByItem(item.itemID) -- exception(boundary): nil until the housing catalog UI has loaded once this session
            if catInfo and catInfo.asset then
                modelSceneFrame:TransitionToModelSceneID(
                    catInfo.uiModelSceneID or DEFAULT_DECOR_SCENE_ID,
                    _G.CAMERA_TRANSITION_TYPE_IMMEDIATE, _G.CAMERA_MODIFICATION_TYPE_DISCARD, true)
                local actor = modelSceneFrame:GetActorByTag("decor")
                if actor then -- exception(boundary): a ModelScene may lack the "decor" actor (Blizzard guards the same call)
                    actor:SetPreferModelCollisionBounds(true)
                    actor:SetModelByFileID(catInfo.asset)
                    actor:SetDesaturation(0) -- Blizzard sometimes pre-desaturates scene actors
                end
                modelSceneFrame:Show()
            else
                modelSceneFrame:Hide() -- exception(boundary): catalog entry not resolved for this session
                details[#details + 1] = "Open the housing catalog once to enable decor previews"
            end
        elseif kind == "transmog" then
            modelSceneFrame:Hide()
            modelCreatureFrame:Hide()
            undressWidget:Show()
            modelDressFrame:Show()
            rebaseDressModel()
            local result = modelDressFrame:TryOn("item:" .. item.itemID)
            if result == Enum.ItemTryOnReason.DataPending then
                -- exception(boundary): item record streams async; TryOn is idempotent
                -- and model.kindOf/collectedOf re-derive on GET_ITEM_INFO_RECEIVED, so
                -- a later click or filter change re-applies it -- no C_Timer retry.
                VWB.Log:Debug("Showroom: TryOn DataPending for item " .. item.itemID)
            end
        else
            -- kind is R.PENDING (still classifying) or "none" (no visual). Show no
            -- model rather than defaulting to a transmog TryOn -- TryOn on a
            -- mount/pet/decor itemID renders a broken dressing-room preview. kindOf
            -- re-derives on GET_ITEM_INFO_RECEIVED and this effect re-runs, so the
            -- correct branch takes over once classification lands.
            modelSceneFrame:Hide()
            modelCreatureFrame:Hide()
            modelDressFrame:Hide()
            undressWidget:Hide()
            if kind == R.PENDING then details[#details + 1] = "Identifying item..." end
        end

        itemDetailsFS:SetText(table.concat(details, "  |  "))
    end, "showroom:model")

    -- Item 5c: pendingSelect consumer. When Nav.Go("showroom", { select=itemID })
    -- fires (e.g. from Workbench recipe row shift-click), select + preview that
    -- item. A TRACKED effect (not a run-once mount read): the view mounts lazily
    -- ONCE, so a one-shot read would consume only the first-ever jump and every
    -- later shift-click would land on a stale selection. pendingSelect is
    -- view-scoped {view, value}; only consume payloads addressed to us.
    R.effect(function()
        local p = ns.Nav.pendingSelect()
        if p == nil or p.view ~= "showroom" then return end
        ns.Nav.pendingSelect(nil)
        -- Find the item in the universe (classification may still be pending, but
        -- selecting by itemID works: the model preview effect re-runs when kindOf resolves).
        for _, item in ipairs(R.untrack(universe)) do
            if item.itemID == p.value then
                selectItem(item)
                break
            end
        end
    end, "showroom:pendingSelect")

    -- Item 8: UncollectedCount -- exported as a module function so Shell or any
    -- future nav badge can bind it without a new full-universe walk. Reads the
    -- model's breadcrumb (already computed, memoized). Returns the uncollected
    -- count within the CURRENT filter universe (not the full account set).
    -- Assigned once at buildView; nil until the view is first mounted.
    Showroom.UncollectedCount = function() return model.breadcrumb().uncollected end

    return handle
end

return Showroom
