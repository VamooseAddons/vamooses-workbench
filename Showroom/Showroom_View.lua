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

local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
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

-- Classification + collection resources (singletons; item data resolves async).
-- request = RequestLoadItemDataByID, which fires ITEM_DATA_LOAD_RESULT (NOT the
-- legacy GET_ITEM_INFO_RECEIVED). keyOf = itemID makes each load event an O(1)
-- perKey lookup, not an O(n) scan of all pending keys -- the item cache fires this
-- event constantly, so without keyOf that was an O(n^2) freeze invisible to the
-- reactive profiler (it runs in the event handler, not a recompute). Decor items
-- don't resolve via item-load (they need the housing catalog) -- they resolve via
-- invalidateAll() on VWB_DECOR_OWNERSHIP_UPDATE, so scoping to one item is safe.
local kindRes, collectedRes
local function ensureResources()
    if kindRes then return end
    local R = ns.Reactor
    kindRes = R.resource({
        read = function(itemID)
            -- Cache-FREE checks first. IsMount is a STATIC item->mount map and
            -- IsTransmoggable is GetItemInfoInstant -- both answerable with no full
            -- item cache, so a mount/transmog classifies instantly even cold.
            -- (There used to be an `if not classID then return nil` guard up front.
            -- classID -- which nothing else here reads -- is nil on a cold item, so
            -- that guard PENDed the item BEFORE IsMount ran and stranded cold MOUNTS
            -- forever: no log, no retry -- the silent failure behind "JC mounts
            -- don't show". Removed; IsMount now runs unconditionally.)
            if ns.Transmog:IsTransmoggable(itemID) then return "transmog" end
            if ns.Collectibles:IsMount(itemID) then return "mount" end
            if ns.Collectibles:IsPet(itemID) then return "pet" end
            local dec = ns.DecorOwnership:IsUncollected(itemID) -- true/false/nil(cold)
            if dec ~= nil then return "decor" end
            -- Nothing matched yet. Pet detection (GetPetInfoByItemID) needs the FULL
            -- item cached and decor needs the housing catalog -- if the item isn't
            -- cached we can't honestly rule out pet, so stay PENDING and re-read on
            -- ITEM_DATA_LOAD_RESULT rather than latching a wrong "none".
            if not C_Item.IsItemDataCachedByID(itemID) then return nil end -- exception(boundary): pet lookup needs the item cached; re-read on load
            if ns.DecorOwnership:IsCatalogCold() then return nil end -- might be decor; retry when catalog warms
            return "none"
        end,
        request = function(itemID) C_Item.RequestLoadItemDataByID(itemID) end,
        event = "ITEM_DATA_LOAD_RESULT", -- RequestLoadItemDataByID fires THIS, not GET_ITEM_INFO_RECEIVED
        keyOf = function(itemID) return itemID end, -- O(1): the event names exactly this itemID
    })
    collectedRes = R.resource({
        read = function(itemID)
            -- mount/pet collection is a synchronous journal lookup; only transmog
            -- ownership needs the async item LINK, and decor needs the catalog.
            local m = ns.Collectibles:IsMountCollected(itemID); if m ~= nil then return m end
            local p = ns.Collectibles:IsPetCollected(itemID); if p ~= nil then return p end
            if ns.Transmog:IsTransmoggable(itemID) then
                if not C_Item.GetItemInfo(itemID) then return nil end -- transmog "collected" needs the item link -> pending
                return ns.Transmog:GetStatus(itemID).isCollected
            end
            local dec = ns.DecorOwnership:IsUncollected(itemID); if dec ~= nil then return not dec end
            if ns.DecorOwnership:IsCatalogCold() then return nil end -- decor collection unknown until catalog warms
            return false
        end,
        request = function(itemID) C_Item.RequestLoadItemDataByID(itemID) end,
        event = "ITEM_DATA_LOAD_RESULT", -- RequestLoadItemDataByID fires THIS, not GET_ITEM_INFO_RECEIVED
        keyOf = function(itemID) return itemID end, -- O(1): the event names exactly this itemID
    })

    -- LIVE collection updates: DecorOwnership/Transmog already fire these on
    -- their own Blizzard event (HOUSING_STORAGE_ENTRY_UPDATED /
    -- TRANSMOG_COLLECTION_SOURCE_ADDED). invalidateAll() re-reads every
    -- already-requested key so a collected item's tick/Missing state flips
    -- immediately -- this is what "stale until reload" was missing.
    --
    -- Item 3: scoped filter predicates so each event only re-reads relevant keys,
    -- not the full ~5k universe in one event frame. Decor events re-read keys
    -- whose last latched kind is "decor", PENDING, or nil (might be decor).
    -- Transmog events re-read "transmog"/PENDING. Scalar values are strings/bools
    -- so the table-equals assert in invalidateAll will not fire.
    local function isDecorOrPending(_, entry)
        local v = entry.value
        return v == R.PENDING or v == nil or v == "decor" or v == "none"
    end
    local function isTransmogOrPending(_, entry)
        local v = entry.value
        return v == R.PENDING or v == nil or v == "transmog"
    end

    VWB.EventBus:Register("VWB_DECOR_OWNERSHIP_UPDATE", function()
        kindRes.invalidateAll(isDecorOrPending) -- re-read only decor/PENDING kind keys
        collectedRes.invalidateAll() -- collected: decor IsUncollected; re-read all is cheap (bool)
    end)
    VWB.EventBus:Register("VWB_TRANSMOG_UPDATED", function()
        kindRes.invalidateAll(isTransmogOrPending) -- re-read only transmog/PENDING kind keys
        collectedRes.invalidateAll()
    end)

    -- Mounts/pets have no EventBus signal of their own (Collectibles.lua is a
    -- pure query module, no event frame) -- listen to the raw Blizzard events
    -- directly. TRANSMOG_COLLECTION_SOURCE_ADDED is caught here too
    -- (redundant with VWB_TRANSMOG_UPDATED above, but cheap, and it keeps this
    -- one frame a complete "something got collected" listener on its own).
    local collectionFrame = CreateFrame("Frame")
    collectionFrame:RegisterEvent("NEW_MOUNT_ADDED")
    collectionFrame:RegisterEvent("NEW_PET_ADDED")
    collectionFrame:RegisterEvent("TRANSMOG_COLLECTION_SOURCE_ADDED")
    collectionFrame:SetScript("OnEvent", function() collectedRes.invalidateAll() end)
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
local universe = ns.Reactor.named("showroom:universe", function()
    ns.Store:Version("corpus")
    local out = {}
    for _, e in ipairs(ns.RecipeQuery:GetFiltered({ collapseRanks = true })) do
        local r = e.recipe
        if r.itemID then -- exception(nullable): enchant recipes have no output item -> nothing to preview/collect, and kind()/collected() would GetItemInfo(nil)
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
    local categoryName = navItem and navItem:match("::(.+)$")
    local out = {}
    for _, item in ipairs(universe()) do
        if not categoryName or item.categoryName == categoryName then out[#out + 1] = item end
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
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0); text:SetPoint("RIGHT", tick, "LEFT", -4, 0); text:SetJustifyH("LEFT")
    frame.text = text
    -- Item 6a: shimmer attached once at factory time (AnimationGroups must not be
    -- created at paint time). Handle set/cleared in the updateRow path.
    frame._shimmerHandle = VWB.UI:AttachShimmer(frame)
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

    local function makeFrame(node, parent)
        if node.id == "search" then
            return VWB.UI:CreateSearchBox(parent, { placeholder = "Search items...",
                onChange = function(text) filters.search((text or ""):lower()) end })
        elseif node.id == "typeToggle" then
            return VWB.UI:CreateSegmentedToggle(parent, {
                width = (node.size and node.size.w) or 300, height = (node.size and node.size.h) or 18,
                segments = TYPE_SEGMENTS, default = "all", onSelect = function(key) filters.typeMode(key) end })
        elseif node.id == "missingPill" then
            return VWB.UI:CreateFilterPill(parent, "Missing", function(checked) filters.missingMode(checked and true or false) end)
        elseif node.id == "profbar" then
            local profs = { { key = "all", label = "All Professions", abbrev = "All", icon = "Interface\\Icons\\INV_Misc_Book_09" } }
            for _, p in ipairs(ns.RecipeQuery:GetProfessions()) do profs[#profs + 1] = p end
            local bar = VWB.UI:CreateProfessionTabBar(parent, profs, function(key) filters.profession(key) end)
            bar:Select("all")
            return bar
        elseif node.id == "navLabel" then
            local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetText(VWB.UI:ColorCode("cyan") .. "Categories|r")
            return fs
        elseif node.id == "navTree" then
            navTree = VWB.UI:CreateNavTree(parent, {
                onHeaderClick = function(key)
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
            listWidget = VWB.UI:CreateVirtualizedList(parent, {
                rowHeight = 22,
                rowTemplate = listRowTemplate,
                updateRow = function(row, item)
                    row.data = item
                    row.icon:SetTexture(C_Item.GetItemIconByID(item.itemID) or QUESTION_ICON)
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
                    local tip = VWB.UI.Tooltip
                    tip:Begin(rowFrame)
                    tip:SetItemHeader(item.itemID, item.name)
                    if item.profession then tip:AddLine(VWB.UI:ColorCode("base01") .. item.profession .. "|r") end
                    tip:Show()
                end,
                onRowLeave = function(_, rowFrame) VWB.UI.Tooltip:Hide(rowFrame) end,
            })
            local s = VWB.UI:GetScheme()
            local empty = listWidget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            empty:SetPoint("TOP", 0, -30)
            empty:SetPoint("LEFT", listWidget, "LEFT", 20, 0)
            empty:SetPoint("RIGHT", listWidget, "RIGHT", -20, 0)
            empty:SetJustifyH("CENTER"); empty:SetWordWrap(true)
            empty:SetTextColor(s.text.r, s.text.g, s.text.b)
            empty:Hide()
            listWidget.emptyText = empty
            VWB.Theme:Register(empty, "DimLabel")
            return listWidget
        elseif node.id == "modelDress" then
            modelDressFrame = CreateFrame("DressUpModel", nil, parent)
            modelDressFrame:SetFacing(0.5)
            VWB.UI:WireModelControls(modelDressFrame)
            return modelDressFrame
        elseif node.id == "modelCreature" then
            modelCreatureFrame = CreateFrame("PlayerModel", nil, parent)
            modelCreatureFrame:SetFacing(0.5)
            modelCreatureFrame:Hide() -- dress route is the default until a mount/pet is selected
            VWB.UI:WireModelControls(modelCreatureFrame)
            return modelCreatureFrame
        elseif node.id == "modelScene" then
            modelSceneFrame = CreateFrame("ModelScene", nil, parent, "PanningModelSceneMixinTemplate")
            modelSceneFrame:Hide() -- dress route is the default until a decor item is selected
            return modelSceneFrame
        elseif node.id == "controlsHint" then
            local s = VWB.UI:GetScheme()
            local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetText("Drag to rotate - scroll to zoom")
            fs:SetJustifyH("CENTER") -- spans the model area (fill width); centre the text within it
            fs:SetTextColor(s.text.r, s.text.g, s.text.b)
            VWB.Theme:Register(fs, "DimLabel")
            return fs
        elseif node.id == "itemName" then
            local s = VWB.UI:GetScheme()
            itemNameFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            itemNameFS:SetTextColor(s.text_header.r, s.text_header.g, s.text_header.b)
            VWB.Theme:Register(itemNameFS, "HeaderLabel")
            return itemNameFS
        elseif node.id == "itemDetails" then
            local s = VWB.UI:GetScheme()
            itemDetailsFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            itemDetailsFS:SetTextColor(s.text.r, s.text.g, s.text.b)
            VWB.Theme:Register(itemDetailsFS, "Label")
            return itemDetailsFS
        elseif node.id == "undress" then
            undressWidget = VWB.UI:CreateCheckbox(parent, "Undress", function(checked)
                undressMode(checked and true or false)
            end)
            return undressWidget
        elseif node.id == "recentStrip" then
            recentStripFrame = CreateFrame("Frame", nil, parent)
            return recentStripFrame
        elseif node.id == "addToQueue" then
            addToQueueBtn = VWB.UI:CreateButton(parent, "Add to Queue", 100, 22)
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
            startProjectBtn = VWB.UI:CreateButton(parent, "Start Project", 100, 22)
            startProjectBtn:SetScript("OnClick", function()
                local item = selected()
                local icon = C_Item.GetItemIconByID(item.itemID)
                ns.Store:Dispatch("ADD_PROJECT", {
                    name = item.name or ("item:" .. tostring(item.itemID)),
                    icon = icon,
                    itemID = item.itemID,
                    recipeID = item.recipeID,
                    kind = "collect",
                })
                -- nextId was bumped by the reducer; the new project's id = nextId - 1.
                local newId = ns.Store:GetState().projects.nextId - 1
                ns.Nav.Go("projects", { select = newId })
            end)
            startProjectBtn:Hide()
            return startProjectBtn
        end
        -- themed placeholder for any node this view hasn't wired real content into
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.showroom, { makeFrame = makeFrame, measure = VWB.ViewKit.measure })
    handle.model = model
    handle.selected = selected

    -- THE unlock: one effect pushes the filtered collectibles into the list, so
    -- rows appear as classification resolves -- no click-away, no manual refresh.
    -- Also owns the empty-state caption: a blank list is ambiguous (nothing
    -- here? filters too tight? a bug?) -- name the reason instead of going quiet.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        local items = model.filteredItems()
        listWidget:SetData(items)
        if #items > 0 then
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
    R.effect(function() collectedRes.epoch(); listWidget:Refresh() end, "showroom:collectionTick")

    -- Nav tree data: rebuilds whenever the recipe universe, profession/type/
    -- missing/search scope, classification, or collapse state changes.
    R.effect(function() navTree:SetData(buildNavSections()) end, "showroom:nav")

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
            local tip = VWB.UI.Tooltip
            tip:Begin(self); tip:SetItemHeader(self._data.itemID, self._data.name); tip:Show()
        end)
        b:SetScript("OnLeave", function(self) VWB.UI.Tooltip:Hide(self) end)
        return b
    end
    R.effect(function()
        ns.Store:Version("recent")
        local ring = ns.Store:GetState().ui.recentPreviewed
        local xOff = 0
        for i, data in ipairs(ring) do
            local chip = recentChips[i] or acquireRecentChip()
            recentChips[i] = chip
            chip._data = data
            chip.icon:SetTexture(data.itemID and C_Item.GetItemIconByID(data.itemID) or QUESTION_ICON)
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
        addToQueueBtn:Show()
        startProjectBtn:Show()
        local kind = model.kindOf(item.itemID)
        local collected = model.collectedOf(item.itemID)
        local details = {}
        if item.profession then details[#details + 1] = "Profession: " .. item.profession end
        if item.expansion then details[#details + 1] = "Expansion: " .. item.expansion end
        if collected ~= R.PENDING then
            details[#details + 1] = COLLECT_LABEL[kind] .. (collected and ": collected" or ": NOT collected")
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
            local catInfo = C_HousingCatalog.GetCatalogEntryInfoByItem(item.itemID, true) -- exception(boundary): nil until the housing catalog UI has loaded once this session
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
