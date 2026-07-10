VWB = VWB or {}
VWB.KnownRecipes = {}

-- Track learned recipes via C_TradeSkillUI

local knownCache = {} -- [recipeID] = true/false
local eventFrame = nil

-- ============================================================================
-- OWN-PROFESSION FULL-RECORD HARVEST (source="own")
-- Covers Cooking (absent from guild data), professions no guildmate has, and
-- guildless players. The player's own trade skill window lists unlearned
-- recipes too, so it's a complete source for that profession. Budget-ticked
-- like Modules/RecipeHarvest.lua's guild scan; upsert-if-absent into the same
-- recipeStore via the same ADD_RECIPES action.
-- ============================================================================

local ownHarvestToken = 0
local ownHarvestDebounce = nil

-- Blizzard's own Professions.lua uses this exact pair to detect "this trade
-- skill session isn't mine" (guild recipe view, or another player's linked
-- skill) -- reused here so KnownRecipes never mistakes someone else's recipe
-- list for the player's own known/skill data.
local function IsGuildOrOtherPlayerSession()
    return C_TradeSkillUI.IsTradeSkillGuild() or C_TradeSkillUI.IsTradeSkillGuildMember()
end

local function HarvestOwnProfession(recipeIDs, profName)
    ownHarvestToken = ownHarvestToken + 1
    local token = ownHarvestToken
    local total = #recipeIDs
    local idx = 1
    local newRecipes = {}
    local newCount, alreadyKnownCount = 0, 0
    local expansionCounts = {}
    local HC = VWB.Constants.Harvest

    local function tick()
        if ownHarvestToken ~= token then return end -- superseded by a newer profession-window open

        local tickStart = debugprofilestop and debugprofilestop() or 0
        local sinceCheck = 0

        while idx <= total do
            local recipeID = recipeIDs[idx]
            idx = idx + 1
            sinceCheck = sinceCheck + 1

            local existing = VWB.Database:GetRecipe(recipeID)
            if existing then
                alreadyKnownCount = alreadyKnownCount + 1
                local key = existing.expansion or "Unknown"
                expansionCounts[key] = (expansionCounts[key] or 0) + 1
            else
                local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID) -- exception(boundary): nil for a stale recipeID
                if recipeInfo then
                    local record = VWB.RecipeHarvest:BuildRecord(recipeID, recipeInfo, profName)
                    if record then
                        newRecipes[recipeID] = record
                        newCount = newCount + 1
                        local key = record.expansion or "Unknown"
                        expansionCounts[key] = (expansionCounts[key] or 0) + 1
                    end
                end
            end

            if sinceCheck >= HC.BUDGET_CHECK_INTERVAL then
                sinceCheck = 0
                if debugprofilestop and (debugprofilestop() - tickStart) >= HC.TICK_BUDGET_MS then
                    break
                end
            end
        end

        if idx <= total then
            VWB.ReactorWoW.after(0, tick) -- next frame, same as C_Timer.After(0)
            return
        end

        if next(newRecipes) then
            VWB.Store:Dispatch("ADD_RECIPES", { records = newRecipes }) -- corpus bump ONLY when definitions grew
        end
        if next(expansionCounts) then
            local coverage = {}
            for expName, count in pairs(expansionCounts) do
                coverage[profName .. "::" .. expName] = {
                    professionName = profName,
                    expansionName = expName,
                    count = count,
                    lastScan = time(),
                    source = "own",
                }
            end
            VWB.Store:Dispatch("UPDATE_COVERAGE", { coverage = coverage }) -- scan status; no reclassify
        end
    end

    tick()
end

-- ACCOUNT-UNION semantics: true if ANY scanned character knows the recipe
-- (the cache seeds from state.knownRecipes, the account union). For a
-- per-character answer use IsKnownBy(recipeID, charKey).
function VWB.KnownRecipes:IsKnown(recipeID)
    if not recipeID then return false end
    return knownCache[recipeID] == true
end

-- Scan currently open profession for known recipes
function VWB.KnownRecipes:ScanCurrentProfession()
    if not C_TradeSkillUI or not C_TradeSkillUI.IsTradeSkillReady then return end
    if not C_TradeSkillUI.IsTradeSkillReady() then return end

    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if not recipeIDs then return end

    local count = 0
    local scanned = {} -- THIS scan's learned set only -- see dispatch note below
    for _, recipeID in ipairs(recipeIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        -- Learned-only: persisting [id]=false for thousands of unlearned recipes bloats SavedVars
        if info and info.learned then
            knownCache[recipeID] = true
            scanned[recipeID] = true
            count = count + 1
        end
    end

    -- Dispatch ONLY this scan's learned set, tagged with the profession.
    -- The old code dispatched the whole accumulated knownCache -- which seeds
    -- from the ACCOUNT UNION at Initialize -- so any character who opened any
    -- profession window was credited with every recipe anyone knew (tester
    -- bug 2026-07-11: "tooltip lists all of my characters as knowing it").
    -- The profession tag lets the reducer replace-by-profession, healing
    -- already-polluted per-char maps as windows are opened.
    if VWB.Store then
        local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo()
        VWB.Store:Dispatch("SET_KNOWN_RECIPES", {
            recipes = scanned,
            charKey = VWB.CharacterData:GetCharacterKey(),
            profession = baseInfo and baseInfo.professionName, -- exception(boundary): header may not have loaded; nil = merge-only
        })
    end

    -- Trigger event
    if VWB.EventBus then
        VWB.EventBus:Trigger("VWB_RECIPES_SCANNED", { count = count })
    end

    VWB.Log:Debug("KnownRecipes: scanned " .. #recipeIDs .. " recipes, " .. count .. " known")
end

-- Load known recipes from Store
function VWB.KnownRecipes:LoadFromStore()
    local state = VWB.Store and VWB.Store:GetState()
    if state and state.knownRecipes then
        knownCache = {}
        for k, v in pairs(state.knownRecipes) do knownCache[k] = v end
    end
end

-- Clear cache
function VWB.KnownRecipes:ClearCache()
    knownCache = {}
end

-- Initialize event handling
function VWB.KnownRecipes:Initialize()
    -- No TRADE_SKILL_SHOW handler (deleted 2026-07-11): the delayed SHOW scan
    -- raced the exact same work as the LIST_UPDATE path below -- Blizzard
    -- bursts LIST_UPDATE 3-5x on initial window load, so the debounced scan
    -- always runs anyway. One trigger, one owner.
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    eventFrame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "TRADE_SKILL_LIST_UPDATE" then
            if C_TradeSkillUI.IsTradeSkillReady() then
                if IsGuildOrOtherPlayerSession() then return end -- not the player's own data; don't contaminate known-recipe/skill/harvest caches

                -- Debounced: TRADE_SKILL_LIST_UPDATE bursts 3-5x on initial profession
                -- load AND fires once per craft during Craft All. Coalesce the known-
                -- scan + skill-scan + own-harvest into ONE pass after the burst settles
                -- -- otherwise every craft re-walks the profession + re-dispatches.
                if ownHarvestDebounce then ownHarvestDebounce:Cancel() end
                ownHarvestDebounce = VWB.ReactorWoW.after(VWB.Constants.Harvest.OWN_HARVEST_DEBOUNCE, function()
                    ownHarvestDebounce = nil
                    if IsGuildOrOtherPlayerSession() then return end -- session may have changed during the debounce wait
                    if not C_TradeSkillUI.IsTradeSkillReady() then return end -- exception(boundary): window may have closed during the 0.5s wait
                    VWB.KnownRecipes:ScanCurrentProfession()
                    VWB.CharacterData:ScanCurrentProfessions() -- keeps Alts grid skill data fresh
                    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
                    local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo()
                    local profName = baseInfo and baseInfo.professionName -- exception(boundary): profession header may not have loaded yet
                    if recipeIDs and profName then
                        HarvestOwnProfession(recipeIDs, profName)
                    end
                end)
            end
        elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
            local data = ...
            -- exception(boundary): Blizzard payload; itemID/name absent for enchant/salvage results
            if data and data.itemID then
                local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo()
                local profName = baseInfo and baseInfo.professionName
                local function record(name)
                    VWB.Store:Dispatch("ADD_CRAFTING_HISTORY", {
                        name = name,
                        itemID = data.itemID,
                        qty = data.quantity,
                        profession = profName,
                    })
                    VWB.EventBus:Trigger("VWB_CRAFT_COMPLETE", { name = name, itemID = data.itemID, qty = data.quantity })
                end
                local itemName = C_Item.GetItemInfo(data.itemID)
                if itemName then
                    record(itemName)
                else
                    -- Resolve first rather than baking "Unknown Item" into SavedVariables
                    VWB.UI.ResolveItemName(data.itemID, record)
                end
            end
        end
    end)

    self:LoadFromStore()
end

-- Known by a SPECIFIC character (feeds the craft-now checkmark + craft
-- button; fills in as that character's profession windows are opened)
function VWB.KnownRecipes:IsKnownBy(recipeID, charKey)
    local rec = VWB.Store:GetState().account.characters[charKey]
    return (rec and rec.knownRecipes and rec.knownRecipes[recipeID]) == true -- exception(nullable): unscanned char / pre-field record
end

-- Names of every scanned character that knows the recipe, current char first
function VWB.KnownRecipes:KnownByList(recipeID)
    local names = {}
    local currentKey = VWB.CharacterData:GetCharacterKey()
    for charKey, rec in pairs(VWB.Store:GetState().account.characters) do
        if rec.knownRecipes and rec.knownRecipes[recipeID] then -- exception(nullable): records saved before this field existed
            if charKey == currentKey then
                table.insert(names, 1, rec.name or charKey)
            else
                table.insert(names, rec.name or charKey)
            end
        end
    end
    return names
end

-- SET_KNOWN_RECIPES reducer is registered in Store.lua
