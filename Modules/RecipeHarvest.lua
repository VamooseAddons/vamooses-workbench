VWB = VWB or {}
VWB.RecipeHarvest = {}

-- ============================================================================
-- VamoosesWorkbench - RecipeHarvest
-- "Rescan Recipes (Guild)": walks every guild profession via ViewGuildRecipes
-- and upserts full records for any recipeID not already in state.recipeStore
-- (upsert-if-absent -- schematics are static within a patch, so "present"
-- means "done"; no diffing, no overlay). THE recipe database IS the union of
-- everything harvested this way plus Modules/KnownRecipes.lua's own-profession
-- harvest (source="own"). Choreography + traps ported from VamoosesGuildCraft's
-- RecipeSearch.lua and ProfTools' guild-scan pipeline; scan-loop shape from
-- VamoosesThreadcount's CollectionScanner.lua. See docs/
-- VPC_PORTABLE_PATTERNS_2026-07-04.md section 5.1/5.2 for the full trap list.
-- ============================================================================

local Harvest = VWB.RecipeHarvest
local HC = VWB.Constants.Harvest

Harvest.active = false
Harvest.token = 0              -- cancellation token; every deferred closure re-checks this
Harvest.professions = {}       -- header cache: { {id=skillLineID, name=headerName}, ... }
Harvest.queue = {}              -- profession queue for the current run
Harvest.queueIndex = 0
Harvest.professionsTotal = 0
Harvest.loadingProfession = nil
Harvest._openedTradeSkill = false -- true only while WE own the open guild tradeskill window
Harvest._profHooked = false
Harvest.newRecipes = {}         -- accumulator: [recipeID] = record (batch-dispatched at the end)
Harvest.coverage = {}           -- accumulator: ["<profession>::<expansion>"] = coverage record
Harvest.expansionCounts = {}    -- per-profession tally, reset at the start of each profession's scan
Harvest.newCount = 0
Harvest.alreadyKnownCount = 0
Harvest.recipesSeen = 0
Harvest.headersReceived = false -- one-shot per run; ignores a stray GUILD_TRADESKILL_UPDATE fired by something else mid-harvest
Harvest.filterSnapshot = nil    -- saved player filter state, restored when the run ends

local function DebugPrint(msg)
    VWB.Log:Debug("RecipeHarvest: " .. msg)
end

-- ============================================================================
-- RECIPE LIST FILTERS (guild view inherits the player's own profession-window
-- filter state -- Show Unlearned / source-type filters -- which silently
-- truncates GetAllRecipeIDs(). Blizzard's own Professions.ResetFilters() does
-- this same reset before any full-list operation. Snapshot + force-show-all +
-- restore so the harvest sees everything without clobbering the player's
-- preferences in their own profession window.
-- ============================================================================

local function SnapshotRecipeFilters()
    return {
        showLearned = C_TradeSkillUI.GetShowLearned(),
        showUnlearned = C_TradeSkillUI.GetShowUnlearned(),
        onlyMakeable = C_TradeSkillUI.GetOnlyShowMakeableRecipes(),
        onlySkillUp = C_TradeSkillUI.GetOnlyShowSkillUpRecipes(),
        onlyFirstCraft = C_TradeSkillUI.GetOnlyShowFirstCraftRecipes(),
        sourceTypeFilter = C_TradeSkillUI.GetSourceTypeFilter(),
    }
end

local function ForceShowAllRecipes()
    C_TradeSkillUI.SetShowLearned(true)
    C_TradeSkillUI.SetShowUnlearned(true)
    C_TradeSkillUI.SetOnlyShowMakeableRecipes(false)
    C_TradeSkillUI.SetOnlyShowSkillUpRecipes(false)
    C_TradeSkillUI.SetOnlyShowFirstCraftRecipes(false)
    C_TradeSkillUI.ClearRecipeSourceTypeFilter()
end

local function RestoreRecipeFilters(snapshot)
    if not snapshot then return end
    C_TradeSkillUI.SetShowLearned(snapshot.showLearned)
    C_TradeSkillUI.SetShowUnlearned(snapshot.showUnlearned)
    C_TradeSkillUI.SetOnlyShowMakeableRecipes(snapshot.onlyMakeable)
    C_TradeSkillUI.SetOnlyShowSkillUpRecipes(snapshot.onlySkillUp)
    C_TradeSkillUI.SetOnlyShowFirstCraftRecipes(snapshot.onlyFirstCraft)
    C_TradeSkillUI.SetSourceTypeFilter(snapshot.sourceTypeFilter)
end

-- ============================================================================
-- EXPANSION DERIVATION (category-tree walk; matches the recipe store's
-- convention so guild + own-profession harvests agree on expansion strings)
-- ============================================================================

local function NormalizeExpansion(rawName)
    if not rawName then return nil end
    local aliases = VWB.Constants.ExpansionCategoryAliases
    if aliases[rawName] then return aliases[rawName] end
    local firstWord = rawName:match("^(%S+)")
    if firstWord and aliases[firstWord] then return aliases[firstWord] end
    local firstTwo = rawName:match("^(%S+%s+%S+)")
    if firstTwo and aliases[firstTwo] then return aliases[firstTwo] end
    return rawName
end

local function GetExpansionFromCategory(categoryID)
    if not categoryID then return nil end
    local currentCatID = categoryID
    local topLevelName = nil
    local depth = 0
    while currentCatID and depth < HC.MAX_CATEGORY_DEPTH do
        local categoryInfo = C_TradeSkillUI.GetCategoryInfo(currentCatID) -- exception(boundary): categoryID from a live recipe row, tree can be stale
        if not categoryInfo then break end
        if categoryInfo.name then topLevelName = categoryInfo.name end
        if not categoryInfo.parentCategoryID then break end
        currentCatID = categoryInfo.parentCategoryID
        depth = depth + 1
    end
    return NormalizeExpansion(topLevelName)
end

-- ============================================================================
-- RECIPE RECORD BUILDING (schematic -> recipeStore slot schema)
-- ============================================================================

-- Triple fallback for the output itemID (ProfTools :654-669): the direct API,
-- then two schematic shapes, then hyperlink parsing.
local function ResolveOutputItemID(recipeID, recipeInfo, schematic)
    local outputData = C_TradeSkillUI.GetRecipeOutputItemData(recipeID) -- exception(boundary): nil for non-item recipes
    if outputData and outputData.itemID then return outputData.itemID end
    if schematic then
        if schematic.outputItemID then return schematic.outputItemID end
        if schematic.outputInfo and schematic.outputInfo.itemID then return schematic.outputInfo.itemID end
    end
    if recipeInfo.hyperlink then
        local linkItemID = recipeInfo.hyperlink:match("item:(%d+)")
        if linkItemID then return tonumber(linkItemID) end
    end
    return nil
end

-- Returns slots, hasSlots. hasSlots=false means the recipe isn't a
-- slot-based crafting recipe (gathering/no reagents) and must be skipped.
local function BuildSlots(schematic)
    local slots = {}
    if not (schematic and schematic.reagentSlotSchematics) then return slots, false end

    local typeNames = VWB.Constants.ReagentSlotTypeNames
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local typeName = typeNames[slot.reagentType or 1] or "unknown"
        local primary = slot.reagents and slot.reagents[1]

        if primary and primary.itemID then
            local variants = {}
            if #slot.reagents > 1 then
                for j = 2, #slot.reagents do
                    local variant = slot.reagents[j]
                    if variant.itemID then table.insert(variants, variant.itemID) end
                end
            end

            local primaryName = C_Item.GetItemNameByID(primary.itemID) -- exception(boundary): cold item cache returns "" (miss), not nil
            table.insert(slots, {
                type = typeName,
                qty = slot.quantityRequired or 1,
                itemID = primary.itemID,
                variants = variants,
                name = (primaryName ~= "" and primaryName) or nil,
            })
        end
    end

    return slots, #slots > 0
end

-- Returns a recipeStore-shaped record, or nil if the recipe isn't a slot-based
-- crafting recipe (salvage/recraft/gathering/no-reagent). Shared by the guild
-- harvest (source="guild") and Modules/KnownRecipes.lua's own-profession
-- harvest (source="own") via Harvest:BuildRecord -- ONE builder so both paths
-- produce byte-identical record shapes.
local function BuildRecipeRecord(recipeID, recipeInfo, profName)
    if recipeInfo.isSalvageRecipe or recipeInfo.isRecraft then return nil end

    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false) -- exception(boundary): nil if recipe data isn't cached yet

    -- ViewGuildRecipes drops isGatheringRecipe, so gathering professions also
    -- treat a no-reagent recipe as gathering -- unless it turns out to have
    -- real slots (e.g. Mining's "Smelt Copper", which is a true crafting
    -- recipe, not a gathering ability). Harmless no-op for the own-profession
    -- path, where isGatheringRecipe is reliable and already short-circuits.
    local professionIsGathering = VWB.Constants.GatheringProfessions[profName] == true
    local probablyGathering = (not recipeInfo.isGatheringRecipe) and professionIsGathering
    if probablyGathering and schematic and schematic.reagentSlotSchematics and #schematic.reagentSlotSchematics > 0 then
        probablyGathering = false
    end
    if recipeInfo.isGatheringRecipe or probablyGathering then return nil end

    local slots, hasSlots = BuildSlots(schematic)
    if not hasSlots then return nil end

    local categoryID = recipeInfo.categoryID
    local categoryName = nil
    if categoryID then
        local catInfo = C_TradeSkillUI.GetCategoryInfo(categoryID) -- exception(boundary): categoryID may be stale
        categoryName = catInfo and catInfo.name
    end

    return {
        name = recipeInfo.name,
        profession = profName,
        expansion = GetExpansionFromCategory(categoryID),
        recipeID = recipeID,
        itemID = ResolveOutputItemID(recipeID, recipeInfo, schematic),
        categoryID = categoryID,
        categoryName = categoryName,
        outputQtyMin = (schematic and schematic.quantityMin) or 1,
        outputQtyMax = (schematic and schematic.quantityMax) or 1,
        icon = recipeInfo.icon,
        itemLevel = recipeInfo.itemLevel,
        recipeType = schematic and schematic.recipeType,
        maxTrivialLevel = recipeInfo.maxTrivialLevel,
        numSkillUps = recipeInfo.numSkillUps,
        sourceType = recipeInfo.sourceType,
        supportsQualities = recipeInfo.supportsQualities or false,
        maxQuality = recipeInfo.maxQuality,
        isEnchantingRecipe = recipeInfo.isEnchantingRecipe or false,
        slots = slots,
    }
end

-- Exposed for Modules/KnownRecipes.lua's own-profession harvest.
function Harvest:BuildRecord(recipeID, recipeInfo, profName)
    return BuildRecipeRecord(recipeID, recipeInfo, profName)
end

-- ============================================================================
-- PRECONDITIONS
-- ============================================================================

function Harvest:CanStart()
    if self.active then return false, "Harvest already running" end
    if not IsInGuild() then
        return false, "Not in a guild - opening your own profession windows fills the recipe book automatically instead"
    end
    if ProfessionsFrame and ProfessionsFrame:IsShown() then -- exception(boundary): Blizzard_Professions may not be loaded yet
        return false, "Close your profession window first"
    end
    if C_TradeSkillUI.IsNPCCrafting() then
        return false, "Cannot harvest while crafting at an NPC"
    end
    return true
end

-- ============================================================================
-- INITIALIZATION / EVENTS
-- ============================================================================

function Harvest:Initialize()
    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:SetScript("OnEvent", function(_, event, ...) self:OnEvent(event, ...) end)
    self.eventFrame:RegisterEvent("ADDON_LOADED") -- exception(false-positive): catches load-on-demand Blizzard_Professions (filtered arg1 in OnEvent) to hook ProfessionsFrame, NOT addon bootstrap.
    self.eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
    self.eventFrame:RegisterEvent("GUILD_TRADESKILL_UPDATE")

    if ProfessionsFrame then self:HookProfessionsFrame() end
end

function Harvest:OnEvent(event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Blizzard_Professions" then
        self:HookProfessionsFrame()
    elseif event == "GUILD_TRADESKILL_UPDATE" then
        self:OnHeadersUpdate()
    elseif event == "TRADE_SKILL_SHOW" then
        -- Only hook the list-update wait if WE initiated this open, not the player
        if self.loadingProfession and self._openedTradeSkill then
            self.eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
        end
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        if self.loadingProfession then
            self.eventFrame:UnregisterEvent("TRADE_SKILL_LIST_UPDATE")
            self:OnProfessionLoaded()
        end
    end
end

function Harvest:HookProfessionsFrame()
    if not ProfessionsFrame or self._profHooked then return end
    self._profHooked = true
    -- Own-open guard: only hide the window when WE opened it via ViewGuildRecipes,
    -- never the player's own crafting-table session (SetAlpha, never Hide -- Hide
    -- would tear down state the player's own session depends on).
    ProfessionsFrame:HookScript("OnShow", function(f)
        if self._openedTradeSkill then f:SetAlpha(0) end
    end)
end

function Harvest:RestoreProfessionsFrame()
    if self._openedTradeSkill then
        self._openedTradeSkill = false
        C_TradeSkillUI.CloseTradeSkill()
    end
    if ProfessionsFrame then ProfessionsFrame:SetAlpha(1) end -- exception(boundary): frame may not exist if Blizzard_Professions never loaded
end

-- ============================================================================
-- START / CANCEL / FINISH
-- ============================================================================

function Harvest:Start()
    local ok, reason = self:CanStart()
    if not ok then
        VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", { phase = "error", reason = reason })
        return
    end

    if not C_AddOns.IsAddOnLoaded("Blizzard_Communities") then
        C_AddOns.LoadAddOn("Blizzard_Communities")
    end

    self.token = self.token + 1
    local token = self.token
    self.active = true
    self.newRecipes = {}
    self.coverage = {}
    self.expansionCounts = {}
    self.newCount = 0
    self.alreadyKnownCount = 0
    self.recipesSeen = 0
    self.queue = {}
    self.queueIndex = 0
    self.professionsTotal = 0
    self.headersReceived = false
    self.filterSnapshot = SnapshotRecipeFilters()
    ForceShowAllRecipes()

    VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", { phase = "headers", done = 0, total = 0 })

    C_Timer.After(HC.HEADER_TIMEOUT, function()
        if self.token ~= token then return end
        if self.active and #self.queue == 0 and self.professionsTotal == 0 then
            self:Finish(token, "No guild profession data received")
        end
    end)

    QueryGuildRecipes()
end

function Harvest:Cancel()
    if not self.active then return end
    self.token = self.token + 1
    self:RestoreProfessionsFrame()
    RestoreRecipeFilters(self.filterSnapshot)
    self.filterSnapshot = nil
    self.active = false
    self.loadingProfession = nil
    self.newRecipes = {}
    self.coverage = {}
    VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", { phase = "cancelled" })
end

function Harvest:Finish(token, errorReason)
    if token ~= self.token then return end
    self:RestoreProfessionsFrame()
    RestoreRecipeFilters(self.filterSnapshot)
    self.filterSnapshot = nil
    self.active = false
    self.loadingProfession = nil

    if errorReason then
        VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", { phase = "error", reason = errorReason })
        return
    end

    if next(self.newRecipes) then
        VWB.Store:Dispatch("ADD_RECIPES", { records = self.newRecipes }) -- corpus bump ONLY when definitions grew
    end
    if next(self.coverage) then
        VWB.Store:Dispatch("UPDATE_COVERAGE", { coverage = self.coverage }) -- scan status; no reclassify
    end

    VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", {
        phase = "complete",
        done = self.professionsTotal,
        total = self.professionsTotal,
        newCount = self.newCount,
        alreadyKnownCount = self.alreadyKnownCount,
        recipesSeen = self.recipesSeen,
    })

    self.newRecipes = {}
    self.coverage = {}
    DebugPrint(string.format("Harvest complete: %d new recipes on file, %d already known (%d seen)",
        self.newCount, self.alreadyKnownCount, self.recipesSeen))
end

-- ============================================================================
-- PROFESSION HEADERS -> QUEUE
-- ============================================================================

function Harvest:OnHeadersUpdate()
    if not self.active then return end
    if self.headersReceived then return end -- ignore a stray GUILD_TRADESKILL_UPDATE fired by something else mid-harvest
    self.headersReceived = true

    local count = GetNumGuildTradeSkill()
    local queue = {}
    for i = 1, (count or 0) do
        local skillID, _, _, headerName, _, _, numPlayers = GetGuildTradeSkillInfo(i)
        -- Header rows only (GetGuildTradeSkillInfo is gutted to headers-only in
        -- 12.0); numPlayers > 0 filters out expansion sub-skills with no crafters.
        if headerName and headerName ~= "" and numPlayers and numPlayers > 0 then
            table.insert(queue, { id = skillID, name = headerName })
        end
    end
    table.sort(queue, function(a, b) return a.name < b.name end)

    local token = self.token
    self.queue = queue
    self.queueIndex = 0
    self.professionsTotal = #queue

    if #queue == 0 then
        self:Finish(token, "No guild profession data with active crafters")
        return
    end

    self:LoadNextProfession()
end

-- ============================================================================
-- PER-PROFESSION LOAD (ViewGuildRecipes -> harvest -> close, chained)
-- ============================================================================

function Harvest:LoadNextProfession()
    local token = self.token
    self.queueIndex = self.queueIndex + 1
    local prof = self.queue[self.queueIndex]
    if not prof then
        self:Finish(token)
        return
    end

    self.loadingProfession = prof.id
    self._openedTradeSkill = true

    VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", {
        phase = "profession", done = self.queueIndex - 1, total = self.professionsTotal, name = prof.name,
    })

    ViewGuildRecipes(prof.id)

    -- Timeout safety: Mining is the largest profession (every ore node variant
    -- across every expansion), 10s covers it comfortably.
    C_Timer.After(HC.PROFESSION_TIMEOUT, function()
        if self.token ~= token then return end
        if self.loadingProfession == prof.id then
            DebugPrint("Timeout on profession " .. prof.name .. ", skipping...")
            self.loadingProfession = nil
            self:RestoreProfessionsFrame()
            C_Timer.After(HC.INTER_PROFESSION_PAUSE, function()
                if self.token ~= token then return end
                self:LoadNextProfession()
            end)
        end
    end)
end

function Harvest:OnProfessionLoaded()
    if not self.loadingProfession then return end
    local token = self.token
    local prof = self.queue[self.queueIndex]
    self.loadingProfession = nil

    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs() -- exception(boundary): nil if the profession isn't ready yet
    if not recipeIDs then
        self:RestoreProfessionsFrame()
        C_Timer.After(HC.INTER_PROFESSION_PAUSE, function()
            if self.token ~= token then return end
            self:LoadNextProfession()
        end)
        return
    end

    self:ScanCurrentProfession(recipeIDs, prof, token)
end

-- ============================================================================
-- BUDGET-TICKED RECIPE SCAN (VTC CollectionScanner shape)
-- ============================================================================

function Harvest:ScanCurrentProfession(recipeIDs, prof, token)
    local total = #recipeIDs
    local idx = 1
    self.expansionCounts = {}

    local function tick()
        if self.token ~= token then return end -- harvest cancelled/superseded mid-scan

        local tickStart = debugprofilestop and debugprofilestop() or 0
        local sinceCheck = 0

        while idx <= total do
            local recipeID = recipeIDs[idx]
            self:HarvestOneRecipe(recipeID, prof.name)
            idx = idx + 1
            sinceCheck = sinceCheck + 1

            if sinceCheck >= HC.BUDGET_CHECK_INTERVAL then
                sinceCheck = 0
                if debugprofilestop and (debugprofilestop() - tickStart) >= HC.TICK_BUDGET_MS then
                    break
                end
            end
        end

        VWB.EventBus:Trigger("VWB_HARVEST_PROGRESS", {
            phase = "scanning", done = self.queueIndex - 1, total = self.professionsTotal,
            name = prof.name, recipeDone = idx - 1, recipeTotal = total,
        })

        if idx <= total then
            C_Timer.After(0, tick)
            return
        end

        -- Profession scan complete: commit this profession's per-expansion
        -- coverage tally, then close the guild view and chain to the next.
        for expName, count in pairs(self.expansionCounts) do
            self.coverage[prof.name .. "::" .. expName] = {
                professionName = prof.name,
                expansionName = expName,
                count = count,
                lastScan = time(),
                source = "guild",
            }
        end

        self:RestoreProfessionsFrame()
        C_Timer.After(HC.INTER_PROFESSION_PAUSE, function()
            if self.token ~= token then return end
            self:LoadNextProfession()
        end)
    end

    tick()
end

function Harvest:TallyExpansion(expansionName)
    local key = expansionName or "Unknown"
    self.expansionCounts[key] = (self.expansionCounts[key] or 0) + 1
end

-- Upsert-if-absent: a recipeID already in recipeStore is skipped (schematics
-- are static within a patch -- present means done); a missing one gets
-- BuildRecipeRecord and queued for the end-of-run batch dispatch.
function Harvest:HarvestOneRecipe(recipeID, profName)
    self.recipesSeen = self.recipesSeen + 1

    local existing = VWB.Database:GetRecipe(recipeID)
    if existing then
        self.alreadyKnownCount = self.alreadyKnownCount + 1
        self:TallyExpansion(existing.expansion)
        return
    end

    local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID) -- exception(boundary): nil for a stale/removed recipeID
    if not recipeInfo then return end

    local record = BuildRecipeRecord(recipeID, recipeInfo, profName)
    if not record then return end -- gathering/salvage/recraft/no-reagent recipes aren't stored

    self.newRecipes[recipeID] = record
    self.newCount = self.newCount + 1
    self:TallyExpansion(record.expansion)
end
