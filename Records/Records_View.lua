-- ============================================================================
-- VWB Records (Data) - VIEW / controller. Toward parity with VPC's Data tab.
-- ============================================================================
-- Six composites, all built inside the FIVE existing LayoutConfig item slots
-- (recStats / recCoverage / recHistory / recRescan / recExport) -- no
-- LayoutConfig node additions were needed; every section is a self-contained
-- frame the makeFrame branch below builds and owns (same technique Ledger's
-- ldgTable uses: a plain wrap frame holding a static header + a
-- CreateVirtualizedList). See the build report for why this fits without a
-- shared-file change, and for the follow-up LayoutConfig resize that would
-- give the rescan status room of its own instead of borrowing recHistory's.
--
-- One computed (coverageData) walks recipeStore ONCE per Store:Version(
-- "recipes") bump and feeds THREE consumers: the Database Statistics summary
-- line (recStats), the coverage grid's rows (recCoverage), and its totals
-- row -- so "Database Statistics" is the grid's own column/row totals plus a
-- one-line overview, not a second redundant per-profession text list (VPC's
-- Data.lua carries both because the grid was added later; here the grid IS
-- the statistics view). Counts are re-derived LIVE from recipeStore, NOT
-- from recipeCoverage's stored count field -- VPC's own comment documents
-- that field drifting from the live DB, so recipeCoverage here supplies only
-- scan status (was this profession scanned + when) for the row tooltip.
--
-- historyRows (Store:Version("history")) builds a FRESH capped array every
-- recompute, which is what makes it safe to route through a computed at all:
-- craftingHistory itself is mutated in place (stable table ref), so a
-- computed that returned THAT table directly would never look "changed" to
-- Reactor's default equals and would silently stop propagating. Building a
-- new out={} sidesteps the trap (matches Stockroom/Ledger's own derived-list
-- computeds) -- the OLD version of this file avoided computed() for history
-- entirely because it passed the raw table straight through; that
-- restriction doesn't apply once the computed returns a copy.
--
-- Guild rescan: CanStart()-gated button (disabled + reason tooltip), fed by
-- RecipeHarvest's "VWB_HARVEST_PROGRESS" EventBus phases. The progress bar +
-- status line render in a strip reserved at the BOTTOM of recHistory's own
-- box (directly above the button, which sits in the row right below) --
-- LayoutConfig's bottom row is a fixed 22px, no room for a bar there; see the
-- build report for the recommended follow-up layout change.
-- ============================================================================

local _, ns = ...
local Records = ns.Records or {}
ns.Records = Records

local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Canonical profession row set for the coverage grid (alphabetical, matches
-- VPC's COVERAGE_PROFESSIONS). Fishing/Runeforging are excluded -- nothing to
-- scan for either. A profession name showing up in recipeStore/recipeCoverage
-- outside this set still gets its own row (appended, sorted) rather than
-- being silently dropped -- that's drift worth seeing, not noise.
local COVERAGE_PROFESSIONS = {
    "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
    "Herbalism", "Inscription", "Jewelcrafting", "Leatherworking",
    "Mining", "Skinning", "Tailoring",
}
local COVERAGE_EXCLUDED = { Fishing = true, Runeforging = true }

local PROF_COL_W, EXP_COL_W, TOTAL_COL_W = 74, 28, 36
local GRID_ROW_H = 18
local HIST_ROW_H = 18
local HIST_ICON_SIZE, HIST_ICON_INSET = 14, 20
local HARVEST_STRIP_H = 32 -- reserved bottom strip of recHistory: progress bar + status line

-- Compact scan age: "2h" / "3d" (a staleness signal, not a stopwatch).
-- Ported from VPC's Data.lua FormatScanAge.
local function FormatScanAge(lastScan)
    local elapsed = time() - lastScan
    if elapsed < 3600 then
        return math.max(1, math.floor(elapsed / 60)) .. "m"
    elseif elapsed < 86400 then
        return math.floor(elapsed / 3600) .. "h"
    else
        return math.floor(elapsed / 86400) .. "d"
    end
end

-- ============================================================================
-- COVERAGE GRID: row factory (profession label | N expansion cells | total)
-- ============================================================================

local function coverageRowTemplate(frame)
    local ED = ns.Data.ExpansionData
    frame.profText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.profText:SetPoint("LEFT", 2, 0)
    frame.profText:SetSize(PROF_COL_W - 2, GRID_ROW_H)
    frame.profText:SetJustifyH("LEFT")

    frame.cells = {}
    for i, expInfo in ipairs(ED.EXPANSION_ORDER) do
        local cell = CreateFrame("Frame", nil, frame)
        cell:SetPoint("LEFT", PROF_COL_W + (i - 1) * EXP_COL_W, 0)
        cell:SetSize(EXP_COL_W, GRID_ROW_H)
        -- EnableMouse so OnEnter/OnLeave/OnMouseUp fire per-cell (edge #7).
        cell:EnableMouse(true)
        cell._expDisplay = expInfo.display -- stable: expInfo is a module-level constant
        cell._expIndex = i
        local heat = cell:CreateTexture(nil, "BACKGROUND")
        heat:SetAllPoints()
        heat:SetColorTexture(1, 1, 1, 1)
        heat:SetVertexColor(1, 1, 1, 0)
        cell.heat = heat
        local text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("CENTER")
        cell.text = text

        -- Hover affordance: brighten text to white when the cell is navigable.
        cell:SetScript("OnEnter", function(self)
            if self._count then -- exception(nullable): unscanned cell has no count, not navigable
                self.text:SetTextColor(1, 1, 1)
            end
        end)
        cell:SetScript("OnLeave", function(self)
            -- Restore the expansion-color the paint pass applied.
            if self._expColor then
                self.text:SetTextColor(self._expColor.r, self._expColor.g, self._expColor.b)
            end
        end)
        cell:SetScript("OnMouseUp", function(self)
            if self._count and self._profName then -- exception(nullable): dash cells have no count
                ns.Nav.Go("workbench", { select = { profession = self._profName, expansion = self._expDisplay } })
            end
        end)

        frame.cells[i] = cell
    end

    frame.totalText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.totalText:SetPoint("LEFT", PROF_COL_W + #ED.EXPANSION_ORDER * EXP_COL_W, 0)
    frame.totalText:SetSize(TOTAL_COL_W - 4, GRID_ROW_H)
    frame.totalText:SetJustifyH("CENTER")
end

local function paintCoverageRow(row, profRow)
    local s = VWB.UI:GetScheme()
    local ED = ns.Data.ExpansionData

    row.profText:SetText(profRow.name)
    row.profText:SetTextColor(s.text.r, s.text.g, s.text.b)

    for i, exp in ipairs(ED.EXPANSION_ORDER) do
        local cell = row.cells[i]
        local n = profRow.counts[i]
        -- Store per-cell nav state for the click/hover scripts wired in coverageRowTemplate.
        cell._profName = profRow.name
        cell._count = n -- nil for unscanned; hover + click guards on this
        if n then
            cell._expColor = exp.color
            cell.text:SetText(tostring(n))
            cell.text:SetTextColor(exp.color.r, exp.color.g, exp.color.b)
            cell.heat:SetVertexColor(s.success.r, s.success.g, s.success.b, 0.04 + 0.14 * (n / profRow.rowMax))
        elseif profRow.scanned then
            cell._expColor = nil
            cell.heat:SetVertexColor(1, 1, 1, 0)
            cell.text:SetText(VWB.UI:ColorCode("base01") .. "0|r")
            cell.text:SetTextColor(1, 1, 1) -- the embedded color code carries the actual color
        else
            cell._expColor = nil
            cell.heat:SetVertexColor(1, 1, 1, 0)
            cell.text:SetText(VWB.UI:ColorCode("base01") .. "-|r")
            cell.text:SetTextColor(1, 1, 1)
        end
    end

    if profRow.total > 0 then
        row.totalText:SetText(VWB.UI:ColorCode("base1") .. profRow.total .. "|r")
    else
        row.totalText:SetText(VWB.UI:ColorCode("base01") .. "-|r")
    end
    row.totalText:SetTextColor(1, 1, 1)
end

-- Row-level tooltip (not per-cell -- CreateVirtualizedList's hover hook is
-- one per row; a per-cell hover would need a lower-level CreateScrollBox
-- factory with hand-wired mouse scripts per cell, which is more machinery
-- than this grid's requirements call for).
local function coverageRowTooltip(profRow, rowFrame)
    local ED = ns.Data.ExpansionData
    GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
    GameTooltip:AddLine(profRow.name, 1, 1, 1)
    if profRow.scanned then
        GameTooltip:AddLine("Last scanned " .. FormatScanAge(profRow.lastScan) .. " ago", 0.7, 0.7, 0.7)
    else
        -- Guildless-friendly order: direct action first, guild path second.
        GameTooltip:AddLine("Open this profession on any character to record it -- or run a guild rescan if you have one.", 0.9, 0.6, 0.2, true)
    end
    for i, exp in ipairs(ED.EXPANSION_ORDER) do
        local n = profRow.counts[i]
        if n then
            GameTooltip:AddDoubleLine(exp.display, tostring(n), 0.9, 0.9, 0.9, exp.color.r, exp.color.g, exp.color.b)
        end
    end
    if profRow.name == "Cooking" then
        GameTooltip:AddLine("Guild data never carries Cooking recipes -- only your own scans fill this row.", 1, 0.6, 0.2, true)
    end
    GameTooltip:Show()
end

-- Static expansion-code column header (built once, not pooled).
local function buildCoverageExpHeader(parent)
    local ED = ns.Data.ExpansionData
    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(GRID_ROW_H - 2)

    local lbl = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", 2, 0)
    lbl:SetSize(PROF_COL_W - 2, GRID_ROW_H - 2)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(VWB.UI:ColorCode("base01") .. "Profession|r")

    for i, exp in ipairs(ED.EXPANSION_ORDER) do
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", PROF_COL_W + (i - 1) * EXP_COL_W, 0)
        fs:SetSize(EXP_COL_W, GRID_ROW_H - 2)
        fs:SetJustifyH("CENTER")
        fs:SetText(exp.short)
        fs:SetTextColor(exp.color.r, exp.color.g, exp.color.b)
    end

    local totalLbl = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    totalLbl:SetPoint("LEFT", PROF_COL_W + #ED.EXPANSION_ORDER * EXP_COL_W, 0)
    totalLbl:SetSize(TOTAL_COL_W, GRID_ROW_H - 2)
    totalLbl:SetJustifyH("CENTER")
    totalLbl:SetText(VWB.UI:ColorCode("base1") .. "Total|r")

    return header
end

-- Static totals row shell (built once; cells repainted reactively).
local function buildCoverageTotalsRow(parent)
    local ED = ns.Data.ExpansionData
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(GRID_ROW_H)

    row.profText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.profText:SetPoint("LEFT", 2, 0)
    row.profText:SetSize(PROF_COL_W - 2, GRID_ROW_H)
    row.profText:SetJustifyH("LEFT")
    row.profText:SetText("Total")

    row.cells = {}
    for i in ipairs(ED.EXPANSION_ORDER) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", PROF_COL_W + (i - 1) * EXP_COL_W, 0)
        fs:SetSize(EXP_COL_W, GRID_ROW_H)
        fs:SetJustifyH("CENTER")
        row.cells[i] = fs
    end

    row.totalText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.totalText:SetPoint("LEFT", PROF_COL_W + #ED.EXPANSION_ORDER * EXP_COL_W, 0)
    row.totalText:SetSize(TOTAL_COL_W, GRID_ROW_H)
    row.totalText:SetJustifyH("CENTER")

    return row
end

-- Live recipeStore walk -> canonical profession rows + column/grand totals.
-- Counts come from recipeStore (authoritative), NOT recipeCoverage's stored
-- count field -- recipeCoverage supplies scan status/timestamp only. The
-- display/api/abbr fallback on the count-key lookup mirrors BuildRecipeRecord's
-- own derivation: expansion strings mostly normalize to exp.display via
-- Constants.ExpansionCategoryAliases, but nothing enforces that as a closed
-- enum, so the fallback catches anything that slipped through un-normalized.
local function buildCoverageData()
    local ED = ns.Data.ExpansionData
    local recipeStore = ns.Database:GetAllRecipes()
    local coverage = ns.Store:GetState().recipeCoverage

    local counts, profTotals = {}, {}
    for _, rec in pairs(recipeStore) do
        local key = rec.profession .. "::" .. (rec.expansion or "Unknown")
        counts[key] = (counts[key] or 0) + 1
        profTotals[rec.profession] = (profTotals[rec.profession] or 0) + 1
    end

    local scannedProf, lastScanByProf, newestScan = {}, {}, nil
    for _, entry in pairs(coverage) do
        scannedProf[entry.professionName] = true
        if not lastScanByProf[entry.professionName] or entry.lastScan > lastScanByProf[entry.professionName] then
            lastScanByProf[entry.professionName] = entry.lastScan
        end
        if not newestScan or entry.lastScan > newestScan then newestScan = entry.lastScan end
    end

    local seen, order = {}, {}
    for _, name in ipairs(COVERAGE_PROFESSIONS) do
        order[#order + 1] = name
        seen[name] = true
    end
    local extras = {}
    for name in pairs(profTotals) do
        if not seen[name] and not COVERAGE_EXCLUDED[name] then
            seen[name] = true
            extras[#extras + 1] = name
        end
    end
    for name in pairs(scannedProf) do
        if not seen[name] and not COVERAGE_EXCLUDED[name] then
            seen[name] = true
            extras[#extras + 1] = name
        end
    end
    table.sort(extras)
    for _, name in ipairs(extras) do order[#order + 1] = name end

    local rows, colTotals, grandTotal = {}, {}, 0
    for _, name in ipairs(order) do
        local rowCounts, rowMax = {}, 0
        for i, exp in ipairs(ED.EXPANSION_ORDER) do
            local n = counts[name .. "::" .. exp.display] or counts[name .. "::" .. exp.api] or counts[name .. "::" .. exp.abbr]
            rowCounts[i] = n
            if n and n > rowMax then rowMax = n end
            if n then colTotals[i] = (colTotals[i] or 0) + n end
        end
        local total = profTotals[name] or 0 -- exception(nullable): a canonical row can be entirely unscanned
        grandTotal = grandTotal + total
        rows[#rows + 1] = {
            name = name, counts = rowCounts, rowMax = rowMax, total = total,
            scanned = scannedProf[name] or false, lastScan = lastScanByProf[name],
        }
    end

    local expansionsRepresented = 0
    for i in ipairs(ED.EXPANSION_ORDER) do
        if colTotals[i] and colTotals[i] > 0 then expansionsRepresented = expansionsRepresented + 1 end
    end

    local totalRecipes = 0
    for _ in pairs(recipeStore) do totalRecipes = totalRecipes + 1 end

    local professionsScanned = 0
    for _, row in ipairs(rows) do
        if row.scanned then professionsScanned = professionsScanned + 1 end
    end

    return {
        rows = rows, colTotals = colTotals, grandTotal = grandTotal,
        totalRecipes = totalRecipes,
        professionsScanned = professionsScanned, totalProfessions = #rows,
        expansionsRepresented = expansionsRepresented, totalExpansions = #ED.EXPANSION_ORDER,
        lastScan = newestScan,
    }
end

-- ============================================================================
-- CRAFTING HISTORY: row factory (Time | icon+Item | Qty | Profession)
-- ============================================================================

local function historyRowTemplate(frame)
    local UI = VWB.Constants.UI
    frame.timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.timeText:SetPoint("LEFT", 4, 0)
    frame.timeText:SetSize(UI.colWidthTime, HIST_ROW_H)
    frame.timeText:SetJustifyH("LEFT")

    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetSize(HIST_ICON_SIZE, HIST_ICON_SIZE)
    frame.icon:SetPoint("LEFT", frame.timeText, "RIGHT", 2, 0)
    frame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- shave the baked-in icon border

    frame.itemText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.itemText:SetPoint("LEFT", frame.timeText, "RIGHT", HIST_ICON_INSET, 0)
    frame.itemText:SetSize(UI.colWidthItem - HIST_ICON_INSET, HIST_ROW_H)
    frame.itemText:SetJustifyH("LEFT")

    frame.qtyText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.qtyText:SetPoint("LEFT", frame.itemText, "RIGHT", 8, 0)
    frame.qtyText:SetSize(UI.colWidthQty, HIST_ROW_H)
    frame.qtyText:SetJustifyH("LEFT")

    frame.profText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.profText:SetPoint("LEFT", frame.qtyText, "RIGHT", 8, 0)
    frame.profText:SetSize(UI.colWidthProfession, HIST_ROW_H)
    frame.profText:SetJustifyH("LEFT")
end

local function paintHistoryRow(row, entry)
    row.timeText:SetText(VWB.UI:ColorCode("base01") .. date("%m/%d %H:%M", entry.timestamp or 0) .. "|r")
    row.timeText:SetTextColor(1, 1, 1)

    if entry.itemID then
        row.icon:SetTexture(C_Item.GetItemIconByID(entry.itemID) or QUESTION_ICON)
        row.icon:Show()
    else
        row.icon:Hide() -- exception(nullable): pre-itemID history rows can exist in older SavedVariables
    end
    row.itemText:SetText(entry.name or "Unknown")

    row.qtyText:SetText(VWB.UI:ColorCode("green") .. (entry.qty or 1) .. "|r")
    row.qtyText:SetTextColor(1, 1, 1)

    row.profText:SetText(entry.profession or "")
end

local function buildHistoryColHeader(parent)
    local UI = VWB.Constants.UI
    local s = VWB.UI:GetScheme()
    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(HIST_ROW_H)

    local function col(anchorTo, offset, width, text)
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if anchorTo then
            fs:SetPoint("LEFT", anchorTo, "RIGHT", offset, 0)
        else
            fs:SetPoint("LEFT", offset, 0)
        end
        fs:SetSize(width, HIST_ROW_H)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(s.text.r, s.text.g, s.text.b)
        VWB.Theme:Register(fs, "DimLabel")
        return fs
    end

    local timeFS = col(nil, 4, UI.colWidthTime, "Time")
    local itemFS = col(timeFS, HIST_ICON_INSET, UI.colWidthItem - HIST_ICON_INSET, "Item")
    local qtyFS = col(itemFS, 8, UI.colWidthQty, "Qty")
    col(qtyFS, 8, UI.colWidthProfession, "Profession")

    return header
end

-- ============================================================================
-- VIEW
-- ============================================================================

function Records.buildView(container)
    local R = ns.Reactor
    local Kit = ns.ViewKit

    -- ONE walk of recipeStore + recipeCoverage, shared by the stats line, the
    -- coverage grid rows, and its totals row. Subscribes BOTH slices: recipeStore
    -- counts grow on "corpus" (ADD_RECIPES), while recipeCoverage scan status/
    -- timestamps update on "coverage" (UPDATE_COVERAGE, every scan). Known-status
    -- changes touch neither, so they don't re-walk this.
    local coverageData = R.named("records:coverageData", function()
        ns.Store:Version("corpus")
        ns.Store:Version("coverage")
        return buildCoverageData()
    end)

    -- Fresh capped array every recompute (see file header for why that's
    -- required here, not optional): newest-first, capped to 50.
    local historyRows = R.named("records:historyRows", function()
        ns.Store:Version("history")
        local raw = ns.Store:GetState().craftingHistory
        local out = {}
        for i = 1, math.min(#raw, 50) do out[i] = raw[i] end
        return out
    end)

    local covList, coverageTotalsRow
    local histList, historyColHeader, emptyCard
    local progressBar, statusText
    local rescanBtn

    local function ExportHistoryToCSV()
        local history = ns.Store:GetState().craftingHistory
        if #history == 0 then
            print("|cFF2aa198[VWB]|r Nothing to export yet -- craft something first.")
            return
        end

        local lines = { "Timestamp,Item,ItemID,Quantity,Profession,Character,Realm" }
        for _, entry in ipairs(history) do
            local timestamp = entry.timestamp and date("%Y-%m-%d %H:%M:%S", entry.timestamp) or ""
            local name = (entry.name or "Unknown"):gsub(",", ";")
            local itemID = entry.itemID or ""
            local qty = entry.qty or 1
            local profession = (entry.profession or ""):gsub(",", ";")
            local character = (entry.character or ""):gsub(",", ";")
            local realm = (entry.realm or ""):gsub(",", ";")
            lines[#lines + 1] = string.format("%s,%s,%s,%d,%s,%s,%s",
                timestamp, name, itemID, qty, profession, character, realm)
        end

        local text = table.concat(lines, "\n")
        VWB.UI:CreateExportDialog():ShowText(text, "Crafting History (CSV)")
        print(string.format("|cFF2aa198[VWB]|r Crafting History (CSV) ready to copy (%d characters).", #text))
    end

    -- ns.RecipeHarvest:CanStart() is the single source of truth for
    -- preconditions -- no duplicated guild/profession-window checks here.
    local function refreshRescanButton()
        local ok, reason = ns.RecipeHarvest:CanStart()
        if ok then
            rescanBtn:Enable()
            rescanBtn._disabledReason = nil
        else
            rescanBtn:Disable()
            rescanBtn._disabledReason = reason
        end
    end

    local function makeFrame(node, parent)
        if node.id == "recStats" then
            local wrap = CreateFrame("Frame", nil, parent)
            local header = VWB.UI:CreateSectionHeader(wrap, { text = "Database Statistics", height = 16 })
            header:SetPoint("TOPLEFT", 0, 0)
            header:SetPoint("TOPRIGHT", 0, 0)

            local line = wrap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            line:SetPoint("TOPLEFT", 4, -18)
            line:SetPoint("TOPRIGHT", -4, -18)
            line:SetJustifyH("LEFT")
            wrap.statsLine = line
            return wrap

        elseif node.id == "recCoverage" then
            local wrap = CreateFrame("Frame", nil, parent)
            local header = VWB.UI:CreateSectionHeader(wrap, { text = "Coverage", height = 16 })
            header:SetPoint("TOPLEFT", 0, 0)
            header:SetPoint("TOPRIGHT", 0, 0)

            local expHeader = buildCoverageExpHeader(wrap)
            expHeader:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
            expHeader:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)

            coverageTotalsRow = buildCoverageTotalsRow(wrap)
            coverageTotalsRow:SetPoint("BOTTOMLEFT", 0, 0)
            coverageTotalsRow:SetPoint("BOTTOMRIGHT", 0, 0)

            covList = VWB.UI:CreateVirtualizedList(wrap, {
                rowHeight = GRID_ROW_H,
                rowTemplate = coverageRowTemplate,
                updateRow = paintCoverageRow,
                onRowEnter = coverageRowTooltip,
            })
            covList:ClearAllPoints()
            covList:SetPoint("TOPLEFT", expHeader, "BOTTOMLEFT", 0, -2)
            covList:SetPoint("BOTTOMRIGHT", coverageTotalsRow, "TOPRIGHT", 0, 2)
            return wrap

        elseif node.id == "recHistory" then
            local wrap = CreateFrame("Frame", nil, parent)

            local clearBtn = VWB.UI:CreateButton(wrap, "Clear", 60, 18)
            clearBtn:SetPoint("TOPRIGHT", 0, 0)
            clearBtn:SetScript("OnClick", function()
                ns.Store:Dispatch("CLEAR_HISTORY")
                print("|cFF2aa198[VWB]|r Crafting history cleared.")
            end)

            local header = VWB.UI:CreateSectionHeader(wrap, { text = "Crafting History", height = 18 })
            header:SetPoint("TOPLEFT", 0, 0)
            header:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)

            -- historyColHeader spans the FULL wrap width -- anchored off wrap's
            -- own RIGHT edge, not header's (header's own right edge stops short
            -- of clearBtn, which would otherwise narrow the column header too).
            historyColHeader = buildHistoryColHeader(wrap)
            historyColHeader:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
            historyColHeader:SetPoint("RIGHT", wrap, "RIGHT", 0, 0)

            histList = VWB.UI:CreateVirtualizedList(wrap, {
                rowHeight = HIST_ROW_H,
                rowTemplate = historyRowTemplate,
                updateRow = paintHistoryRow,
            })
            histList:ClearAllPoints()
            histList:SetPoint("TOPLEFT", historyColHeader, "BOTTOMLEFT", 0, -2)
            histList:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", 0, HARVEST_STRIP_H)

            emptyCard = VWB.UI:CreateEmptyStateCard(wrap, {
                width = 260, height = 90, icon = "Interface\\Icons\\INV_Misc_Note_06",
                title = "No crafts yet", body = "Finish a craft and it will show up here.",
            })
            emptyCard:ClearAllPoints()
            emptyCard:SetPoint("CENTER", histList, "CENTER", 0, 0)

            -- Reserved bottom strip: guild-rescan progress + status. The
            -- rescan button lives in the row directly below this box
            -- (LayoutConfig's fixed 22px bottom row has no room for a bar);
            -- borrowing this strip keeps the feedback directly above the
            -- control that triggers it. See the build report for the
            -- recommended follow-up LayoutConfig change that would give this
            -- its own row instead.
            progressBar = VWB.UI:CreateProgressBar(wrap, { width = 220, height = 12 })
            progressBar:SetPoint("BOTTOMLEFT", 4, 17)
            progressBar:Hide()

            statusText = wrap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            statusText:SetPoint("BOTTOMLEFT", 4, 2)
            statusText:SetPoint("BOTTOMRIGHT", -4, 2)
            statusText:SetJustifyH("LEFT")

            return wrap

        elseif node.id == "recRescan" then
            rescanBtn = VWB.UI:CreateButton(parent, "Rescan Guild", (node.size and node.size.w) or 150, (node.size and node.size.h) or 22)
            rescanBtn:SetScript("OnClick", function() ns.RecipeHarvest:Start() end)
            rescanBtn:HookScript("OnEnter", function(self)
                if self._disabledReason then
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine(self._disabledReason, 1, 0.4, 0.4, true)
                    GameTooltip:Show()
                end
            end)
            rescanBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
            return rescanBtn

        elseif node.id == "recExport" then
            local btn = VWB.UI:CreateButton(parent, "Export CSV", (node.size and node.size.w) or 120, (node.size and node.size.h) or 22)
            btn:SetScript("OnClick", ExportHistoryToCSV)
            return btn
        end
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.records, { makeFrame = makeFrame, measure = Kit.measure })

    R.bindText(handle.byId.recStats.statsLine, function()
        local d = coverageData()
        local scanPart = d.lastScan and ("last scan " .. FormatScanAge(d.lastScan) .. " ago") or "never scanned"
        return string.format(
            "%s%d|r recipes on file   %s%d/%d|r professions scanned   %s%d/%d|r expansions represented   %s%s|r",
            VWB.UI:ColorCode("green"), d.totalRecipes,
            VWB.UI:ColorCode("cyan"), d.professionsScanned, d.totalProfessions,
            VWB.UI:ColorCode("cyan"), d.expansionsRepresented, d.totalExpansions,
            VWB.UI:ColorCode("base01"), scanPart)
    end)

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled coverage rows on switch
        local d = coverageData()
        covList:SetData(d.rows)
        for i in ipairs(ns.Data.ExpansionData.EXPANSION_ORDER) do
            local fs = coverageTotalsRow.cells[i]
            local t = d.colTotals[i]
            if t then
                fs:SetText(VWB.UI:ColorCode("base1") .. t .. "|r")
            else
                fs:SetText(VWB.UI:ColorCode("base01") .. "-|r")
            end
            fs:SetTextColor(1, 1, 1)
        end
        coverageTotalsRow.totalText:SetText(VWB.UI:ColorCode("green") .. d.grandTotal .. "|r")
        coverageTotalsRow.totalText:SetTextColor(1, 1, 1)
    end, "records:coverage")

    R.effect(function()
        local rows = historyRows()
        histList:SetData(rows)
        local empty = #rows == 0
        emptyCard:SetShown(empty)
        historyColHeader:SetShown(not empty)
    end, "records:history")

    -- Progress bar + status text, fed by RecipeHarvest's own phase stream;
    -- every phase also re-checks CanStart() so the button flips the instant
    -- a harvest starts or ends (a finer cadence than VPC's mount+ADD_RECIPES
    -- refresh, since VWB has no action-map dispatcher to hang a refresh off).
    ns.EventBus:Register("VWB_HARVEST_PROGRESS", function(payload)
        payload = payload or {}
        if payload.phase == "headers" then
            progressBar:Show()
            progressBar:SetProgress(0, 1)
            statusText:SetText(VWB.UI:ColorCode("base0") .. "Reading guild profession list...|r")
        elseif payload.phase == "profession" then
            progressBar:SetProgress(payload.done or 0, payload.total or 1)
            statusText:SetText(string.format("%sScanning:|r %s (%d/%d professions)",
                VWB.UI:ColorCode("base0"), payload.name or "?", payload.done or 0, payload.total or 0))
        elseif payload.phase == "scanning" then
            statusText:SetText(string.format("%sScanning:|r %s (%d/%d recipes)",
                VWB.UI:ColorCode("base0"), payload.name or "?", payload.recipeDone or 0, payload.recipeTotal or 0))
        elseif payload.phase == "complete" then
            progressBar:Hide()
            statusText:SetText(string.format("%sDone -|r %s%d|r new, %s%d|r already known (%d seen)",
                VWB.UI:ColorCode("green"), VWB.UI:ColorCode("green"), payload.newCount or 0,
                VWB.UI:ColorCode("green"), payload.alreadyKnownCount or 0, payload.recipesSeen or 0))
        elseif payload.phase == "cancelled" then
            progressBar:Hide()
            statusText:SetText(VWB.UI:ColorCode("base01") .. "Cancelled.|r")
        elseif payload.phase == "error" then
            progressBar:Hide()
            statusText:SetText(VWB.UI:ColorCode("red") .. (payload.reason or "Harvest failed") .. "|r")
        end
        refreshRescanButton()
    end)

    refreshRescanButton()

    return handle
end

return Records
