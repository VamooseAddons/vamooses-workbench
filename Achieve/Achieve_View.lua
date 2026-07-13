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
local CRIT_ROW_H = 16

local singleLine = ns.ViewKit.singleLine

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

-- Slim rows (detail-column pass 2026-07-13): Track + Commission moved to the
-- detail panel -- one proper button each instead of a column of identical
-- per-row buttons; rows are icon | name+description | points | progress.
local function listRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(28, 28); icon:SetPoint("LEFT", 4, 0)
    frame.icon = icon
    local right = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall"))
    right:SetWidth(RIGHT_W); right:SetJustifyH("RIGHT"); right:SetPoint("RIGHT", -6, 0)
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
        hideEarned = R.signal(true), collapsed = R.signal({}), -- unearned-only by default (owner 2026-07-13): the work list, not the trophy case
    }
    local model = Achieve.buildModel({
        source = {
            peek = ns.ProfAchievements.peek, epoch = ns.ProfAchievements.epoch,
            ids = ns.ProfAchievements.IDs, categories = ns.ProfAchievements.Categories,
        },
        filters = filters,
    })

    local listWidget, navTree, breadcrumbFS
    local detHeader, detDesc, detProgress, detTrack, detCommission, critList

    -- click-selected achievement id; drives the detail column (sticky --
    -- survives the selection filtering out of the list)
    local selected = R.signal(nil)

    -- Detail rec straight off the latch, NOT model.rows(): epoch-tracked so
    -- live criteria progress repaints the panel, and peek-by-id keeps the
    -- panel up when filters drop the row.
    local detailRec = R.named("achieve:detailRec", function()
        local id = selected()
        if not id then return nil end
        ns.ProfAchievements.epoch()
        return ns.ProfAchievements.peek(id) -- exception(nullable): id can outlive a re-walk
    end)

    local function toggleCollapse(key) VWB.UI.ToggleSetKey(filters.collapsed, key) end

    -- Hover stays a SUMMARY (name/points/desc/reward); the criteria wall that
    -- used to run off-screen lives in the detail column now (owner 2026-07-13).
    local function onRowEnter(rec, rowFrame)
        local tip = ns.UI.Tooltip
        tip:Begin(rowFrame)
        tip:AddTitle(rec.name)
        tip:AddLine(ns.UI:ColorCode("base01") .. rec.points .. " points|r")
        if rec.description and rec.description ~= "" then tip:AddLine(rec.description) end
        if rec.rewardText and rec.rewardText ~= "" then
            tip:AddLine(ns.UI:ColorCode("yellow") .. rec.rewardText .. "|r")
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
            local pill = ns.UI:CreateFilterPill(parent, "Unearned only", function(checked)
                filters.hideEarned(checked and true or false)
            end)
            pill:SetChecked(true) -- matches the signal default (Study's Unlearned-only idiom)
            return pill
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
                    local s = VWB.UI:GetScheme()
                    row.name:SetText(rec.name)
                    if rec.id == selected() then
                        row.name:SetTextColor(s.warning.r, s.warning.g, s.warning.b)
                    elseif rec.completed then
                        row.name:SetTextColor(s.success.r, s.success.g, s.success.b)
                    else
                        row.name:SetTextColor(1, 1, 1)
                    end
                    row.desc:SetText(rec.description or "")
                    row.pts:SetText(rec.points > 0 and (rec.points .. "p") or "")
                    if rec.completed then
                        row.right:SetText(ns.UI:ColorCode("green") .. rec.progressText .. "|r")
                    else
                        row.right:SetText(ns.UI:ColorCode("base01") .. rec.progressText .. "|r")
                    end
                end,
                onRowClick = function(rec)
                    selected(selected() == rec.id and nil or rec.id)
                end,
                onRowEnter = onRowEnter,
                onRowLeave = function(_, rowFrame) ns.UI.Tooltip:Hide(rowFrame) end,
            })
            ns.UI:AddEmptyOverlayText(listWidget)
            return listWidget
        elseif node.id == "detHeader" then
            local f = CreateFrame("Frame", nil, parent)
            f.icon = f:CreateTexture(nil, "ARTWORK")
            f.icon:SetSize(26, 26); f.icon:SetPoint("LEFT", 0, 0)
            f.pts = singleLine(f:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall"))
            f.pts:SetPoint("RIGHT", -2, 0); f.pts:SetJustifyH("RIGHT")
            VWB.Theme:Register(f.pts, "DimLabel")
            f.name = singleLine(f:CreateFontString(nil, "OVERLAY", "VWBFontNormal"))
            f.name:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
            f.name:SetPoint("RIGHT", f.pts, "LEFT", -6, 0)
            f.name:SetJustifyH("LEFT")
            detHeader = f
            return f
        elseif node.id == "detDesc" then
            detDesc = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            detDesc:SetJustifyH("LEFT"); detDesc:SetJustifyV("TOP") -- wraps to the slot's 2 lines
            VWB.Theme:Register(detDesc, "DimLabel")
            return detDesc
        elseif node.id == "detProgress" then
            detProgress = singleLine(parent:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall"))
            detProgress:SetJustifyH("LEFT")
            return detProgress
        elseif node.id == "detTrack" then
            detTrack = VWB.UI:CreateButton(parent, "Track", 70, 20)
            detTrack:SetScript("OnClick", function(self)
                local rec = detailRec()
                if not rec then return end -- exception(nullable): button hidden without a selection; belt for a race
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
            return detTrack
        elseif node.id == "detCommission" then
            detCommission = VWB.UI:CreateCommissionDropdown(parent, {
                width = 104,
                context = function()
                    local rec = detailRec()
                    if not rec then return nil end -- exception(nullable): SetupMenu pre-generates before any selection
                    return {
                        name = rec.name, count = #buildCriteriaPieces(rec),
                        defaultStatus = "backlog", -- an import is an intention; promote when ready
                        source = { type = "achievement", id = rec.id },
                        pieces = function() return buildCriteriaPieces(rec) end,
                    }
                end,
            })
            return detCommission
        elseif node.id == "detCriteria" then
            critList = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = CRIT_ROW_H,
                rowTemplate = function(frame)
                    local cnt = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall"))
                    cnt:SetPoint("RIGHT", -6, 0); cnt:SetWidth(70); cnt:SetJustifyH("RIGHT")
                    frame.cnt = cnt
                    local txt = singleLine(frame:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall"))
                    txt:SetPoint("LEFT", 6, 0); txt:SetPoint("RIGHT", cnt, "LEFT", -6, 0)
                    txt:SetJustifyH("LEFT")
                    frame.txt = txt
                end,
                updateRow = function(row, c)
                    local s = VWB.UI:GetScheme()
                    local col = c.done and s.success or s.text
                    row.txt:SetText(c.text or "")
                    row.txt:SetTextColor(col.r, col.g, col.b)
                    row.cnt:SetText(c.bar and ((c.quantity or 0) .. "/" .. (c.req or 0)) or (c.done and "done" or ""))
                    row.cnt:SetTextColor(col.r, col.g, col.b)
                end,
            })
            ns.UI:AddEmptyOverlayText(critList)
            return critList
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

    -- Detail column: the click-selected achievement's full record. Buttons
    -- hide without a selection (and Commission hides when nothing's plannable
    -- -- the Elusive Beasts rule, same as the old per-row gating).
    R.effect(function()
        VWB.Theme.epoch()
        local s = VWB.UI:GetScheme()
        local d = VWB.Constants:GetDerivedColors(s)
        local rec = detailRec()
        if not rec then
            detHeader.icon:SetTexture(nil)
            detHeader.name:SetText(""); detHeader.pts:SetText("")
            detDesc:SetText(""); detProgress:SetText("")
            detTrack:Hide(); detCommission:Hide()
            critList:SetData({})
            critList.emptyText:SetText("Select an achievement to see its criteria.")
            critList.emptyText:Show()
            return
        end
        detHeader.icon:SetTexture(rec.icon)
        detHeader.name:SetText(rec.name)
        detHeader.name:SetTextColor(d.selected_bar.r, d.selected_bar.g, d.selected_bar.b)
        detHeader.pts:SetText(rec.points > 0 and (rec.points .. " points") or "")
        detDesc:SetText(rec.description or "")
        if rec.rewardText and rec.rewardText ~= "" then
            detDesc:SetText((rec.description or "") .. "  " .. ns.UI:ColorCode("yellow") .. rec.rewardText .. "|r")
        end
        if rec.completed then
            detProgress:SetText(ns.UI:ColorCode("green") .. rec.progressText .. "|r")
        else
            detProgress:SetText(ns.UI:ColorCode("base01") .. rec.progressText .. "|r")
        end
        detTrack:SetShown(not rec.completed)
        if not rec.completed then
            detTrack:SetText(C_ContentTracking.IsTracking(Enum.ContentTrackingType.Achievement, rec.id)
                and "Untrack" or "Track")
        end
        detCommission:SetShown(not rec.completed and #buildCriteriaPieces(rec) > 0)
        critList:SetData(rec.criteria)
        if #rec.criteria == 0 then
            critList.emptyText:SetText("No listed criteria.")
            critList.emptyText:Show()
        else
            critList.emptyText:Hide()
        end
    end, "achieve:detail")

    handle.model = model
    return handle
end

return Achieve
