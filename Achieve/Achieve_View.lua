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

-- (the old VWB_COMMISSION_ACHIEVE confirm popup is gone: the shared
-- New-Commission dialog IS the confirm now -- lifecycle spec 5)

local ROW_H = 36
local RIGHT_W, PTS_W = 110, 44
local TOOLTIP_CRITERIA_CAP = 15 -- "know each of..." lists run long; tooltip stays a summary

local function singleLine(fs)
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    return fs
end

-- PLANNABLE criteria become commission pieces: know-recipe (type 34,
-- assetID = recipe spellID) and craft-item (type 29, assetID = itemID --
-- "craft each of the following..." maps back to the harvested recipe).
-- The criteria text carries the display name so pieces render even when
-- the recipe is cold. Piece-level achievementID: ticks in ANY commission
-- (v3 multi-achievement ruling). Skill/slay/count criteria stay
-- non-plannable -- the disabled button's tooltip is the explanation.
local function criteriaPiece(rec, ci, c)
    local AC = VWB.Constants.Achievements
    if not c.assetID or c.assetID <= 0 then return nil end -- exception(boundary): progress-bar criteria carry assetID 0
    if c.ctype == AC.CRITERIA_KNOW_RECIPE then
        local r = VWB.Database:GetRecipe(c.assetID)
        return { recipeID = c.assetID, itemID = r and r.itemID, name = c.text,
            kind = "achievement", achievementID = rec.id, criteriaIndex = ci }
    end
    if c.ctype == AC.CRITERIA_CRAFT_ITEM then
        local recipeID = VWB.Database:GetRecipeByItemID(c.assetID, true) -- exception(nullable): item not craftable/harvested -> not plannable
        if recipeID then
            return { recipeID = recipeID, itemID = c.assetID, name = c.text,
                kind = "achievement", achievementID = rec.id, criteriaIndex = ci }
        end
    end
    return nil
end

local function buildCriteriaPieces(rec)
    local pieces = {}
    for ci, c in ipairs(rec.criteria) do
        local pc = criteriaPiece(rec, ci, c)
        if pc then
            pieces[#pieces + 1] = pc
            if #pieces >= VWB.Constants.Projects.MAX_PIECES then break end
        end
    end
    return pieces
end

local function listRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(28, 28); icon:SetPoint("LEFT", 4, 0)
    frame.icon = icon
    -- the shared control, per row; DISABLED explains itself (spec 5b: the
    -- Elusive Beasts case -- no craftable criteria, nothing to plan)
    frame.track = VWB.UI:CreateCommissionDropdown(frame, {
        width = 104,
        context = function()
            local rec = frame.data
            if not rec then return nil end -- exception(boundary): SetupMenu pre-generates at row-template creation, before any data row is bound
            return {
                name = rec.name, count = #buildCriteriaPieces(rec),
                defaultStatus = "backlog", -- an import is an intention; promote when ready
                source = { type = "achievement", id = rec.id },
                pieces = function() return buildCriteriaPieces(rec) end,
            }
        end,
    })
    frame.track:SetPoint("RIGHT", -6, 0)
    -- Blizzard objectives-tracker toggle (owner 2026-07-12): un-earned
    -- achievements get Track/Untrack via C_ContentTracking; anchored
    -- dynamically in updateRow (left of Commission, or the right edge when
    -- the Commission button is hidden).
    frame.trackBliz = VWB.UI:CreateButton(frame, "Track", 62, 20)
    frame.trackBliz:SetScript("OnClick", function(self)
        local rec = frame.data
        local t = Enum.ContentTrackingType.Achievement
        if C_ContentTracking.IsTracking(t, rec.id) then
            C_ContentTracking.StopTracking(t, rec.id, Enum.ContentTrackingStopType.Manual)
            self:SetText("Track")
        else
            local err = C_ContentTracking.StartTracking(t, rec.id)
            if err then -- exception(boundary): Blizzard refuses past the tracking cap
                VWB.Log:Print("Blizzard declined to track this achievement (the tracker caps at 10)")
            else
                self:SetText("Untrack")
            end
        end
    end)
    local right = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall"))
    right:SetWidth(RIGHT_W); right:SetJustifyH("RIGHT") -- anchored in updateRow (leftmost visible control varies)
    frame.right = right
    local pts = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall"))
    pts:SetPoint("RIGHT", right, "LEFT", -6, 0); pts:SetWidth(PTS_W); pts:SetJustifyH("RIGHT")
    frame.pts = pts
    VWB.Theme:Register(pts, "DimLabel")
    local name = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall"))
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -2); name:SetPoint("RIGHT", pts, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    frame.name = name
    local desc = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall"))
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
            -- pill, not checkbox (binary row filters are pills addon-wide);
            -- "Unearned only" says the affirmative direction, matching Study's
            -- "Unlearned only" and Showroom's "Missing" (review 2026-07-13)
            return ns.UI:CreateFilterPill(parent, "Unearned only", function(checked)
                filters.hideEarned(checked and true or false)
            end)
        elseif node.id == "navLabel" then
            local fs = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
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
            breadcrumbFS = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            VWB.Theme:Register(breadcrumbFS, "DimLabel")
            return breadcrumbFS
        elseif node.id == "list" then
            listWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = ROW_H,
                rowTemplate = listRowTemplate,
                updateRow = function(row, rec)
                    row.data = rec
                    row.icon:SetTexture(rec.icon)
                    -- hidden, not greyed: no criteria will EVER be craftable for
                    -- skill/slay achievements, so a permanent grey button is
                    -- noise (owner 2026-07-12; contrast the ATT-absent Map
                    -- button, which greys because installing ATT fixes it)
                    local hasCommission = not rec.completed and #buildCriteriaPieces(rec) > 0
                    row.track:SetShown(hasCommission)
                    row.trackBliz:SetShown(not rec.completed)
                    if not rec.completed then
                        row.trackBliz:SetText(C_ContentTracking.IsTracking(Enum.ContentTrackingType.Achievement, rec.id)
                            and "Untrack" or "Track")
                    end
                    -- right-edge flow: [progress] [Track] [Commission?] -- anchor
                    -- each to the next visible control
                    row.trackBliz:ClearAllPoints()
                    if hasCommission then
                        row.trackBliz:SetPoint("RIGHT", row.track, "LEFT", -6, 0)
                    else
                        row.trackBliz:SetPoint("RIGHT", -6, 0)
                    end
                    row.right:ClearAllPoints()
                    if not rec.completed then
                        row.right:SetPoint("RIGHT", row.trackBliz, "LEFT", -8, 0)
                    else
                        row.right:SetPoint("RIGHT", -6, 0)
                    end
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
            local empty = listWidget:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
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
