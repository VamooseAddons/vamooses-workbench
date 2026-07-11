-- ============================================================================
-- VWB Study - VIEW / controller (WoW glue)
-- ============================================================================
-- The acquisition browser: every unlearned recipe on the account, grouped by
-- HOW you get it (Vendor / Drop / Trainer / Quest / ...) and then by zone --
-- the "I'm heading out, what can I pick up" axis that Workbench (organized by
-- profession/category) structurally can't answer. Data spine is
-- Modules/RecipeSources.lua; the reactive model is Study_Model.lua (headless-
-- tested). First mount wakes the source walk (Constitution R6).
-- ============================================================================

local _, ns = ...
local Study = ns.Study or {}
ns.Study = Study

-- Rank-collapsed corpus as light rows. Unlike Showroom, enchant recipes (no
-- output item) STAY in -- Study browses RECIPES, and "where do I learn
-- Enchant X" is exactly the question. Icons fall back to the profession's.
local universe = ns.Reactor.named("study:universe", function()
    ns.Store:Version("corpus")
    local out = {}
    for _, e in ipairs(ns.RecipeQuery:GetFiltered({ collapseRanks = true })) do
        local r = e.recipe
        out[#out + 1] = { recipeID = e.recipeID, itemID = r.itemID, name = r.name,
            profession = r.profession, expansion = r.expansion }
    end
    return out
end)

-- A themed recipe row: icon | name | zone (right, dim). -----------------------
local function listRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(16, 16); icon:SetPoint("LEFT", 3, 0)
    frame.icon = icon
    local zone = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    zone:SetPoint("RIGHT", -6, 0); zone:SetJustifyH("RIGHT")
    frame.zone = zone
    VWB.Theme:Register(zone, "DimLabel")
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0); text:SetPoint("RIGHT", zone, "LEFT", -8, 0)
    text:SetJustifyH("LEFT")
    frame.text = text
end

function Study.buildView(container)
    local R = ns.Reactor
    ns.RecipeSources:EnsureWalk() -- R6: the consumer surface waking IS the walk trigger

    local filters = {
        search = R.signal(""), profession = R.signal("all"),
        navKey = R.signal(nil), collapsed = R.signal({}),
    }
    local model = Study.buildModel({
        universe = universe,
        source = { peek = ns.RecipeSources.peek, epoch = ns.RecipeSources.epoch },
        known = {
            version = function() return ns.Store:Version("recipes") end, -- SET_KNOWN_RECIPES bumps this slice
            isKnown = function(id) return ns.KnownRecipes:IsKnown(id) end,
        },
        filters = filters,
    })

    local listWidget, navTree, breadcrumbFS

    local function toggleCollapse(key)
        local next = {}
        for k, v in pairs(filters.collapsed()) do next[k] = v end
        next[key] = not next[key]
        filters.collapsed(next) -- fresh table: value inequality propagates (R3)
    end

    local function onRowEnter(e, rowFrame)
        local tip = ns.UI.Tooltip
        tip:Begin(rowFrame)
        local item = e.item
        if item.itemID then
            tip:SetItemHeader(item.itemID, item.name)
        else
            tip:AddTitle(item.name or "Unknown")
            tip:AddLine(ns.UI:ColorCode("base01") .. "#" .. tostring(item.recipeID) .. "|r")
        end
        if item.profession then
            local prof = item.profession .. (item.expansion and (" - " .. item.expansion) or "")
            tip:AddLine(ns.UI:ColorCode("base01") .. prof .. "|r")
        end
        tip:AddLine(" ")
        tip:AddLine(ns.UI:ColorCode("cyan") .. "Recipe: unlearned on this account|r")
        for _, line in ipairs(e.source.lines) do tip:AddLine(line) end
        tip:Show()
    end

    local function makeFrame(node, parent)
        if node.id == "search" then
            return ns.UI:CreateSearchBox(parent, { placeholder = "Search recipes...",
                onChange = function(text) filters.search((text or ""):lower()) end })
        elseif node.id == "profbar" then
            local profs = { { key = "all", label = "All Professions", abbrev = "All", icon = "Interface\\Icons\\INV_Misc_Book_09" } }
            for _, p in ipairs(ns.RecipeQuery:GetProfessions()) do profs[#profs + 1] = p end
            local bar = ns.UI:CreateProfessionTabBar(parent, profs, function(key) filters.profession(key) end)
            bar:Select("all")
            return bar
        elseif node.id == "navLabel" then
            local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetText(ns.UI:ColorCode("cyan") .. "Sources|r")
            return fs
        elseif node.id == "navTree" then
            navTree = ns.UI:CreateNavTree(parent, {
                onHeaderClick = toggleCollapse,
                onArrowClick = toggleCollapse, -- arrow strip has its own hit area (reganart test1 lesson)
                onItemClick = function(key)
                    if filters.navKey() == key then
                        filters.navKey(nil); navTree:Select(nil)
                    else
                        filters.navKey(key)
                    end
                end,
            })
            return navTree
        elseif node.id == "breadcrumb" then
            breadcrumbFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            VWB.Theme:Register(breadcrumbFS, "DimLabel")
            return breadcrumbFS
        elseif node.id == "list" then
            listWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = 22,
                rowTemplate = listRowTemplate,
                updateRow = function(row, e)
                    row.data = e
                    local item = e.item
                    local icon = item.itemID and C_Item.GetItemIconByID(item.itemID) -- exception(boundary): icon can lag a cold item; profession icon stands in
                    row.icon:SetTexture(icon or VWB.Constants.ProfessionIcons[item.profession]
                        or "Interface\\Icons\\INV_Misc_QuestionMark")
                    row.text:SetText(item.name or ("recipe:" .. tostring(item.recipeID)))
                    row.zone:SetText(e.source.zone or "")
                end,
                onRowEnter = onRowEnter,
                onRowLeave = function(_, rowFrame) ns.UI.Tooltip:Hide(rowFrame) end,
            })
            local s = ns.UI:GetScheme()
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
        end
        -- unhandled node -> Layout's default factory renders it
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.study, { makeFrame = makeFrame, measure = VWB.ViewKit.measure })

    -- Rows -> list, with a NAMED empty state (blank lists are ambiguous).
    R.effect(function()
        VWB.Theme.epoch()
        local rows = model.rows()
        listWidget:SetData(rows)
        if #rows > 0 then
            listWidget.emptyText:Hide()
            return
        end
        if #universe() == 0 then
            listWidget.emptyText:SetText("No recipes harvested yet -- open a profession window to get started.")
        elseif ns.RecipeSources.IsWalking() then
            listWidget.emptyText:SetText("Cataloguing recipe sources...")
        elseif filters.search() ~= "" or filters.profession() ~= "all" or filters.navKey() then
            listWidget.emptyText:SetText("No unlearned recipes match these filters.")
        else
            listWidget.emptyText:SetText("Nothing left to learn -- the whole catalogue is yours.")
        end
        listWidget.emptyText:Show()
    end, "study:list")

    R.effect(function() VWB.Theme.epoch(); navTree:SetData(model.sections()) end, "study:nav")

    R.effect(function()
        breadcrumbFS:SetText(string.format("%d recipes to learn  |  %d shown",
            #model.unlearned(), #model.rows()))
    end, "study:breadcrumb")

    handle.model = model
    return handle
end

return Study
