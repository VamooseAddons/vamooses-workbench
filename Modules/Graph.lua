VWB = VWB or {}
VWB.Graph = {}

-- Crafting material expansion + queue state. Live path: GetDirectMaterials,
-- CalculateTotalMats, CalculateCraftingSteps, RebuildCraftingState + queue reducers.

-- Milling/prospecting-style recipes have RNG yields; expanding through them
-- inflates raw-material counts wildly (thousands of herbs for one craft).
-- Their outputs are treated as leaf materials to buy/farm directly.
local RNG_BULK_CATEGORY = {
    ["Mass Milling"] = true,
    ["Mass Prospecting"] = true,
}

-- Name-load latch: request each cold itemID ONCE per session. Dead ids (the
-- server answers success=false) would otherwise be re-requested on EVERY walk,
-- and downstream load-settle listeners re-derive per answer -- a self-
-- sustaining request loop (observed live 2026-07-11).
-- Name resolution rides the ItemData broker (Constitution migration step 2:
-- ONE requester addon-wide; latch-at-callback). Returns a display string
-- always -- the broker's PENDING renders as "Loading...", terminal
-- no-data/dead as "item:<id>", and views repaint via their own broker
-- subscriptions when a pending name latches.
local function displayName(itemID)
    local n = VWB.ItemData.nameFor(itemID)
    if n == VWB.Reactor.PENDING then return "Loading..." end
    return n
end

-- A recipe is CYCLIC if expanding its reagents can loop back to itself --
-- e.g. reversible transmutes (Earth->Life produces the primal that Life->Earth
-- consumes, and vice versa). Chaining these as "craft first" steps is garbage
-- (transmutes are cooldown-gated and reversible; you buy the primal). One-way
-- intermediates (Arcanite Bar: Thorium Bar + Arcane Crystal, never back to
-- Arcanite) are NOT cyclic and still expand. Memoized; cleared on corpus
-- change (Database:InvalidateIndexes) since cyclicity depends on which
-- recipes are currently harvested -- NOT on queue edits (perf A2).
local cyclicCache = {}
local function IsCyclicRecipe(recipeID)
    if cyclicCache[recipeID] ~= nil then return cyclicCache[recipeID] end
    local seen = {}
    local function reaches(rID)
        local rec = VWB.Database:GetRecipe(rID)
        if not (rec and rec.slots) then return false end
        for _, slot in ipairs(rec.slots) do
            if slot.type == "basic" then
                local sub = VWB.Database:GetRecipeByItemID(slot.itemID, true) -- exception(nullable): reagent may not be craftable
                if sub then
                    if sub == recipeID then return true end -- loops back to the start recipe
                    if not seen[sub] then
                        seen[sub] = true
                        if reaches(sub) then return true end
                    end
                end
            end
        end
        return false
    end
    local result = reaches(recipeID)
    cyclicCache[recipeID] = result
    return result
end

-- Called from Database:InvalidateIndexes when the recipe corpus changes
-- (ADD_RECIPES) -- the only event that can alter cyclicity.
function VWB.Graph:InvalidateCyclicCache()
    cyclicCache = {}
end

-- Reagent-conversion recipes churn one material into another (Midnight's
-- per-profession "Sanguinated ..." recipes, enchanting shatters). Chaining a
-- plan through them is the transmute problem in one-way form -- the cycle
-- detector can't catch them -- and the honest step is buy/farm the reagent.
-- Category names probed from the live corpus 2026-07-11; the categories are
-- exact so name-cousins stay expandable ("Sanguinated Feast" is Feasts,
-- "The Shatterer" is Weapons, "Shattered Jade" cuts are Green Gems).
local CONVERSION_CATEGORY = {
    ["Conversions"] = true, -- Sanguinated Dilution/Expulsion/... (all 9 professions)
    ["Disenchant"]  = true, -- Chaos/Ley Shatter
    ["Disenchants"] = true, -- Umbra/Veiled Shatter (later tier, plural category)
}
local function IsConversionRecipe(recipe)
    if CONVERSION_CATEGORY[recipe.categoryName] then return true end
    -- Enchanting's converter/research family lives under era-flavored
    -- "Reagents..." headers: "Reagents" (TBC prismatic shard up/down-converts),
    -- "Reagents and Research" (WoD: Secrets of Draenor, Temporal Crystal,
    -- Luminous Shard -- daily-cooldown research, same buy-dont-chain ruling as
    -- transmutes). Prefix match, profession-qualified so other professions'
    -- Reagents categories stay expandable.
    return recipe.profession == "Enchanting"
        and recipe.categoryName ~= nil
        and recipe.categoryName:find("^Reagents") ~= nil
end

-- Resolve the crafted sub-recipe for a reagent, unless expanding it would
-- route through an RNG-bulk recipe, a reagent conversion, or a reversible/
-- cyclic transmute
local function GetExpandableSubRecipe(itemID)
    local subRecipeID, subRecipe = VWB.Database:GetRecipeByItemID(itemID, true)
    if not subRecipeID or RNG_BULK_CATEGORY[subRecipe.categoryName] or IsConversionRecipe(subRecipe) then
        return nil
    end
    if IsCyclicRecipe(subRecipeID) then return nil end -- reversible transmute etc. -> buy the reagent
    return subRecipeID
end

-- Get direct materials for recipe (no recursive expansion)
function VWB.Graph:GetDirectMaterials(recipeID, qty)
    qty = qty or 1
    local recipe = VWB.Database:GetRecipe(recipeID)
    if not recipe or not recipe.slots then return {} end

    local outputQty = math.max(1, recipe.outputQtyMin or 1)
    local craftRuns = math.ceil(qty / outputQty)

    local list = {}
    for _, slot in ipairs(recipe.slots) do
        if slot.type == "basic" then
            local reqQty = slot.qty * craftRuns
            local owned = (VWB.Inventory and VWB.Inventory:GetItemCountWithVariants(slot.itemID)) or 0
            local missing = math.max(0, reqQty - owned)

            local name = slot.name or displayName(slot.itemID)

            local source = VWB.Database:GetReagent(slot.itemID) or "Unknown"

            table.insert(list, {
                itemID = slot.itemID,
                name = name,
                required = reqQty,
                owned = owned,
                missing = missing,
                source = source
            })
        end
    end

    return list
end

-- Perf D6 (2026-07-11): paint-path variant of GetDirectMaterials for the
-- recipe-row "short N" chip -- counts basic slots short on mats for ONE craft
-- without allocating row tables, resolving names (GetDirectMaterials fires
-- requestNameOnce per unnamed slot; a repaint must never send server
-- requests), or classifying reagent sources.
function VWB.Graph:CountShortMaterials(recipeID)
    local recipe = VWB.Database:GetRecipe(recipeID)
    if not recipe or not recipe.slots then return 0 end -- exception(nullable): chip paint on recipes without slot data on file
    local short = 0
    for _, slot in ipairs(recipe.slots) do
        if slot.type == "basic" and VWB.Inventory:GetItemCountWithVariants(slot.itemID) < slot.qty then
            short = short + 1
        end
    end
    return short
end

-- Calculate total raw materials (fully expanded shopping list)
function VWB.Graph:CalculateTotalMats(input)
    local queue

    if type(input) == "number" then
        queue = self:CalculateCraftingSteps(input)
    elseif type(input) == "table" then
        queue = input
    else
        return {}
    end

    local totals = {} -- [itemID] = qty

    if not queue then return {} end

    for _, step in ipairs(queue) do
        local requiredCrafts = step.missing or 0
        if requiredCrafts > 0 then
            local recipe = VWB.Database:GetRecipe(step.recipeID)
            if recipe and recipe.slots then
                local outputQty = math.max(1, recipe.outputQtyMin or 1)
                local craftRuns = math.ceil(requiredCrafts / outputQty)
                for _, slot in ipairs(recipe.slots) do
                    if slot.type == "basic" then
                        if not GetExpandableSubRecipe(slot.itemID) then
                            local q = slot.qty * craftRuns
                            totals[slot.itemID] = (totals[slot.itemID] or 0) + q
                        end
                    end
                end
            end
        end
    end

    -- Format as shopping list
    local list = {}
    for itemID, reqQty in pairs(totals) do
        local owned = (VWB.Inventory and VWB.Inventory:GetItemCountWithVariants(itemID)) or 0
        local missing = math.max(0, reqQty - owned)

        local name = displayName(itemID)

        local source = VWB.Database:GetReagent(itemID) or "Unknown"

        table.insert(list, {
            itemID = itemID,
            name = name,
            required = reqQty,
            owned = owned,
            missing = missing,
            source = source
        })
    end

    return list
end

-- Calculate intermediate crafting steps with demand propagation
function VWB.Graph:CalculateCraftingSteps(recipeID, qty)
    qty = qty or 1
    local steps = {} -- [recipeID] = { recipe, req, missing, owned, depth, inOrder }

    -- Discovery phase (post-order traversal)
    local stack = {}
    local discoveryOrder = {}

    local function discover(rID, level)
        if stack[rID] then return end
        stack[rID] = true

        local recipe = VWB.Database:GetRecipe(rID)
        if not recipe or not recipe.slots then
            stack[rID] = false
            return
        end

        if not steps[rID] then
            steps[rID] = { recipe = recipe, req = 0, missing = 0, owned = 0, depth = level }
        else
            if level > steps[rID].depth then
                steps[rID].depth = level
            end
        end

        for _, slot in ipairs(recipe.slots) do
            if slot.type == "basic" then
                local subRecipeID = GetExpandableSubRecipe(slot.itemID)
                if subRecipeID and subRecipeID ~= rID then
                    discover(subRecipeID, level + 1)
                end
            end
        end

        if not steps[rID].inOrder then
            table.insert(discoveryOrder, rID)
            steps[rID].inOrder = true
        end

        stack[rID] = false
    end

    discover(recipeID, 0)

    -- exception(boundary): a PERSISTED queue entry can outlive its recipe --
    -- discover() creates no node when the recipeID is absent from the store
    -- (or has no slots), and the root assignment below would crash (found
    -- live in the VPC donor 2026-07-11; identical line here).
    if not steps[recipeID] then return {} end

    -- Demand propagation (reverse order: parents -> children)
    steps[recipeID].req = qty

    local queueResult = {}

    for i = #discoveryOrder, 1, -1 do
        local rID = discoveryOrder[i]
        local node = steps[rID]

        local itemID = node.recipe.itemID
        local owned = (itemID and VWB.Inventory and VWB.Inventory:GetItemCountWithVariants(itemID)) or 0

        local toCraft = math.max(0, node.req - owned)
        node.missing = toCraft
        node.owned = owned

        -- Propagate demand to dependencies (account for batch output)
        if toCraft > 0 and node.recipe.slots then
            local outputQty = math.max(1, node.recipe.outputQtyMin or 1)
            local craftRuns = math.ceil(toCraft / outputQty)
            for _, slot in ipairs(node.recipe.slots) do
                if slot.type == "basic" then
                    local subRecipeID = GetExpandableSubRecipe(slot.itemID)
                    if subRecipeID and steps[subRecipeID] then
                        steps[subRecipeID].req = steps[subRecipeID].req + (craftRuns * slot.qty)
                    end
                end
            end
        end

        table.insert(queueResult, {
            name = node.recipe.name,
            recipeID = rID,
            required = node.req,
            owned = owned,
            missing = toCraft,
            isRecipe = true,
            depth = node.depth
        })
    end

    return queueResult
end

-- Rebuild expanded queue and shopping list from queuedRecipes state
function VWB.Graph:RebuildCraftingState(state)
    -- Perf A2 (2026-07-11): cyclicCache is NOT cleared here. Cyclicity depends
    -- only on the harvested recipe corpus (a reverse transmute arriving in a
    -- later scan), so the cache is invalidated from Database:InvalidateIndexes
    -- on ADD_RECIPES -- clearing it per queue edit re-derived every root's DFS
    -- on each qty-stepper click.

    -- Phase 1: Merge demand from all queued recipes
    local demandByRecipe = {}
    for _, queued in ipairs(state.crafting.queuedRecipes) do
        local id = queued.recipeID
        demandByRecipe[id] = (demandByRecipe[id] or 0) + (queued.qty or 1)
    end

    -- Phase 2: Solve each unique root recipe with its total qty, merge intermediates
    local mergedSteps = {} -- [recipeID] = step
    local directMats = {}

    for rootRecipeID, totalQty in pairs(demandByRecipe) do
        local steps = self:CalculateCraftingSteps(rootRecipeID, totalQty)
        for _, step in ipairs(steps) do
            if mergedSteps[step.recipeID] then
                local existing = mergedSteps[step.recipeID]
                existing.required = existing.required + step.required
                existing.missing = math.max(0, existing.required - existing.owned)
                existing.depth = math.max(existing.depth, step.depth)
            else
                mergedSteps[step.recipeID] = {
                    name = step.name,
                    recipeID = step.recipeID,
                    required = step.required,
                    owned = step.owned,
                    missing = step.missing,
                    isRecipe = true,
                    depth = step.depth
                }
            end
        end

        local mats = self:GetDirectMaterials(rootRecipeID, totalQty)
        for _, mat in ipairs(mats) do
            table.insert(directMats, mat)
        end
    end

    -- Convert merged map to array
    local expandedQueue = {}
    for _, step in pairs(mergedSteps) do
        table.insert(expandedQueue, step)
    end
    state.crafting.expandedQueue = expandedQueue

    if state.config.materialsMode == "direct" then
        state.crafting.shoppingList = directMats
    else
        state.crafting.shoppingList = self:CalculateTotalMats(expandedQueue)
    end

    -- Phase 3: reagent commitments of the queue, keyed by itemID. Consumers
    -- (CanCraft, "ready" tiers) subtract these so materials already earmarked
    -- for queued crafts don't double-count toward new recipes.
    local queuedByItemID = {}
    for _, mat in ipairs(directMats) do
        queuedByItemID[mat.itemID] = (queuedByItemID[mat.itemID] or 0) + mat.required
    end
    state.crafting.queuedByItemID = queuedByItemID
end

-- Store reducers

VWB.Store:RegisterReducer("ADD_TO_QUEUE", function(state, payload)
    local recipeID = payload.recipeID
    local qty = payload.qty or 1
    if not recipeID then return nil end

    local recipe = VWB.Database:GetRecipe(recipeID)
    if not recipe then return nil end

    -- Auto-tag: queue entries belong to the character that queued them
    local charKey = payload.charKey or VWB.CharacterData:GetCharacterKey()

    -- Check if already queued for this character (same recipe on two alts = two plans)
    for _, queued in ipairs(state.crafting.queuedRecipes) do
        if queued.recipeID == recipeID and queued.charKey == charKey then
            queued.qty = queued.qty + qty
            VWB.Graph:RebuildCraftingState(state)
            return state
        end
    end

    -- Add new entry
    table.insert(state.crafting.queuedRecipes, {
        recipeID = recipeID,
        qty = qty,
        name = recipe.name,
        profession = recipe.profession,
        expansion = recipe.expansion,
        itemID = recipe.itemID,
        charKey = charKey
    })

    VWB.Graph:RebuildCraftingState(state)
    return state
end)

VWB.Store:RegisterReducer("REMOVE_FROM_QUEUE", function(state, payload)
    local recipeID = payload.recipeID
    if not recipeID then return nil end

    for i, queued in ipairs(state.crafting.queuedRecipes) do
        -- payload.charKey nil = legacy caller, remove first recipeID match
        if queued.recipeID == recipeID and (payload.charKey == nil or queued.charKey == payload.charKey) then
            table.remove(state.crafting.queuedRecipes, i)
            break
        end
    end

    VWB.Graph:RebuildCraftingState(state)
    return state
end)

VWB.Store:RegisterReducer("CLEAR_QUEUE", function(state, payload)
    -- Clear IN-PLACE, never `= {}`: state.crafting.queuedRecipes is aliased by
    -- reference to VWB_DB.crafting.queuedRecipes (Store:LoadFromSavedVariables).
    -- Replacing the table detaches that alias, so the clear (and every later add)
    -- never reaches SavedVars -- the queue reverts to its pre-clear state on reload.
    local q = state.crafting.queuedRecipes
    for i = #q, 1, -1 do q[i] = nil end
    VWB.Graph:RebuildCraftingState(state) -- clears expandedQueue/shoppingList/queuedByItemID consistently
    return state
end)

VWB.Store:RegisterReducer("UPDATE_QUEUE_QTY", function(state, payload)
    local recipeID = payload.recipeID
    local qty = payload.qty or 1
    if not recipeID then return nil end

    -- Match on (recipeID, charKey) like ADD/REMOVE do -- matching recipeID
    -- alone would edit the wrong alt's row once two characters queue the
    -- same recipe. nil payload.charKey targets the legacy "Unassigned" group.
    for i, queued in ipairs(state.crafting.queuedRecipes) do
        if queued.recipeID == recipeID and queued.charKey == payload.charKey then
            if qty <= 0 then
                table.remove(state.crafting.queuedRecipes, i)
            else
                queued.qty = qty
            end
            break
        end
    end

    VWB.Graph:RebuildCraftingState(state)
    return state
end)

VWB.Store:RegisterReducer("TOGGLE_MATERIALS_MODE", function(state, payload)
    if state.config.materialsMode == "raw" then
        state.config.materialsMode = "direct"
    else
        state.config.materialsMode = "raw"
    end

    VWB.Graph:RebuildCraftingState(state)
    return state
end)

VWB.Store:RegisterReducer("REBUILD_CRAFTING_STATE", function(state)
    VWB.Graph:RebuildCraftingState(state)
    return state
end)
