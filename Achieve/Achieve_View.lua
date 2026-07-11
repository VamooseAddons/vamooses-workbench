-- ============================================================================
-- VWB Achieve - VIEW / controller (WoW glue)
-- ============================================================================
-- Profession achievements, enumerated LIVE from the client (no shipped data
-- -- owner ruling 2026-07-12). Data spine Modules/ProfAchievements.lua;
-- reactive model Achieve_Model.lua (headless-tested). First mount wakes the
-- category walk (Constitution R6). Rows: icon | name+description | points |
-- earned date (green) or progress.
-- ============================================================================

local _, ns = ...
local Achieve = ns.Achieve or {}
ns.Achieve = Achieve

local ROW_H = 36
local RIGHT_W, PTS_W = 110, 44
local TOOLTIP_CRITERIA_CAP = 15 -- "know each of..." lists run long; tooltip stays a summary

local function singleLine(fs)
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    return fs
end

-- Recipe criteria (type 34, assetID = recipe spellID) become commission
-- pieces; the criteria text carries the recipe name so pieces render even
-- when the recipe isn't harvested. Backlog by default (owner ruling: a
-- 20-piece import is an intention, promote to the Bench when ready).
local function startCommission(rec)
    local AC = VWB.Constants.Achievements
    local pieces = {}
    for ci, c in ipairs(rec.criteria) do
        if c.ctype == AC.CRITERIA_KNOW_RECIPE and c.assetID and c.assetID > 0 then
            local r = VWB.Database:GetRecipe(c.assetID)
            pieces[#pieces + 1] = { recipeID = c.assetID, itemID = r and r.itemID,
                name = c.text, kind = "achievement", criteriaIndex = ci }
            if #pieces >= VWB.Constants.Projects.MAX_PIECES then break end
        end
    end
    if #pieces == 0 then return end
    VWB.Store:Dispatch("ADD_PROJECT", { name = rec.name, icon = rec.icon, status = "backlog",
        source = { type = "achievement", id = rec.id }, pieces = pieces })
    VWB.Log:Print(string.format("Commission started: %s (%d pieces, in the Backlog)", rec.name, #pieces))
end

local function hasRecipeCriteria(rec)
    local AC = VWB.Constants.Achievements
    for _, c in ipairs(rec.criteria) do
        if c.ctype == AC.CRITERIA_KNOW_RECIPE and c.assetID and c.assetID > 0 then return true end
    end
    return false
end

local function listRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(28, 28); icon:SetPoint("LEFT", 4, 0)
    frame.icon = icon
    frame.track = VWB.UI:CreateButton(frame, "Track", 52, 18)
    frame.track:SetPoint("RIGHT", -6, 0)
    frame.track:SetScript("OnClick", function(self) startCommission(self:GetParent().data) end)
    local right = singleLine(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    right:SetPoint("RIGHT", frame.track, "LEFT", -8, 0); right:SetWidth(RIGHT_W); right:SetJustifyH("RIGHT")
    frame.right = right
    local pts = singleLine(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    pts:SetPoint("RIGHT", right, "LEFT", -6, 0); pts:SetWidth(PTS_W); pts:SetJustifyH("RIGHT")
    frame.pts = pts
    VWB.Theme:Register(pts, "DimLabel")
    local name = singleLine(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -2); name:SetPoint("RIGHT", pts, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    frame.name = name
    local desc = singleLine(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    desc:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 2); desc:SetPoint("RIGHT", pts, "LEFT", -8, 0)
    desc:SetJustifyH("LEFT")
    frame.desc = desc
    VWB.Theme:Register(desc, "DimLabel")
end

function Achieve.buildView(container)
    local R = ns.Reactor
    ns.ProfAchievements:EnsureWalk() -- R6: the consumer surface waking IS the walk trigger

    local filters = {
        search = R.signal(""), navKey = R.signal(nil),
        hideEarned = R.signal(false), collapsed = R.signal({}),
    }
    local model = Achieve.buildModel({
        source = {
            peek = ns.ProfAchievements.peek, epoch = ns.ProfAchievements.epoch,
            ids = ns.ProfAchievements.IDs, categories = ns.ProfAchievements.Categories,
        },
        filters = filters,
    })

    local listWidget, navTree, breadcrumbFS

    local function toggleCollapse(key)
        local next = {}
        for k, v in pairs(filters.collapsed()) do next[k] = v end
        next[key] = not next[key]
        filters.collapsed(next)
    end

    local function onRowEnter(rec, rowFrame)
        local tip = ns.UI.Tooltip
        tip:Begin(rowFrame)
        tip:AddTitle(rec.name)
        tip:AddLine(ns.UI:ColorCode("base01") .. rec.points .. " points|r")
        if rec.description and rec.description ~= "" then tip:AddLine(rec.description) end
        if rec.rewardText and rec.rewardText ~= "" then
            tip:AddLine(ns.UI:ColorCode("yellow") .. rec.rewardText .. "|r")
        end
        if #rec.criteria > 0 then
            tip:AddLine(" ")
            for i = 1, math.min(#rec.criteria, TOOLTIP_CRITERIA_CAP) do
                local c = rec.criteria[i]
                local line = c.text or ""
                if c.bar then line = line .. " " .. (c.quantity or 0) .. "/" .. (c.req or 0) end
                if c.done then
                    tip:AddLine(ns.UI:ColorCode("green") .. line .. "|r")
                else
                    tip:AddLine(ns.UI:ColorCode("base01") .. line .. "|r")
                end
            end
            if #rec.criteria > TOOLTIP_CRITERIA_CAP then
                tip:AddLine(ns.UI:ColorCode("base01") .. "... and "
                    .. (#rec.criteria - TOOLTIP_CRITERIA_CAP) .. " more|r")
            end
        end
        tip:Show()
    end

    local function makeFrame(node, parent)
        if node.id == "search" then
            return ns.UI:CreateSearchBox(parent, { placeholder = "Search achievements...",
                onChange = function(text) filters.search((text or ""):lower()) end })
        elseif node.id == "hideEarned" then
            return ns.UI:CreateCheckbox(parent, "Hide earned", function(checked)
                filters.hideEarned(checked and true or false)
            end)
        elseif node.id == "navLabel" then
            local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetText(ns.UI:ColorCode("cyan") .. "Professions|r")
            return fs
        elseif node.id == "navTree" then
            navTree = ns.UI:CreateNavTree(parent, {
                onHeaderClick = toggleCollapse,
                onArrowClick = toggleCollapse,
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
                rowHeight = ROW_H,
                rowTemplate = listRowTemplate,
                updateRow = function(row, rec)
                    row.data = rec
                    row.icon:SetTexture(rec.icon)
                    row.track:SetShown(not rec.completed and hasRecipeCriteria(rec))
                    local name = rec.name
                    if rec.completed then name = ns.UI:ColorCode("green") .. name .. "|r" end
                    row.name:SetText(name)
                    row.desc:SetText(rec.description or "")
                    row.pts:SetText(rec.points > 0 and (rec.points .. "p") or "")
                    if rec.completed then
                        row.right:SetText(ns.UI:ColorCode("green") .. rec.progressText .. "|r")
                    else
                        row.right:SetText(ns.UI:ColorCode("base01") .. rec.progressText .. "|r")
                    end
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

    local handle = ns.Layout.build(container, ns.LayoutConfig.achieve, { makeFrame = makeFrame, measure = VWB.ViewKit.measure })

    R.effect(function()
        VWB.Theme.epoch()
        local rows = model.rows()
        listWidget:SetData(rows)
        if #rows > 0 then
            listWidget.emptyText:Hide()
            return
        end
        if ns.ProfAchievements.IsWalking() then
            listWidget.emptyText:SetText("Reading the achievement ledger...")
        elseif filters.search() ~= "" or filters.navKey() or filters.hideEarned() then
            listWidget.emptyText:SetText("No achievements match these filters.")
        else
            listWidget.emptyText:SetText("No profession achievements found.")
        end
        listWidget.emptyText:Show()
    end, "achieve:list")

    R.effect(function() VWB.Theme.epoch(); navTree:SetData(model.sections()) end, "achieve:nav")

    R.effect(function()
        local t = model.tally()
        breadcrumbFS:SetText(string.format("%d of %d earned  |  %d shown",
            t.earned, t.total, #model.rows()))
    end, "achieve:breadcrumb")

    handle.model = model
    return handle
end

return Achieve
