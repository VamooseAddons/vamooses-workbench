VWB = VWB or {}
VWB.Database = {}

-- Data access layer over state.recipeStore -- the live harvested recipe
-- database (see Modules/RecipeHarvest.lua for guild harvest, Modules/
-- KnownRecipes.lua for the own-profession harvest). There is no static file
-- backing this anymore: recipeStore starts empty and only grows via harvests.
-- Recipe schema: [recipeID] = { name, profession, expansion, itemID, categoryID,
-- categoryName, icon, itemLevel, recipeType, maxTrivialLevel, numSkillUps,
-- sourceType, supportsQualities, maxQuality, isEnchantingRecipe, outputQtyMin,
-- outputQtyMax, slots = { { type, qty, itemID, variants, name } } }
-- Reagent classification (Vendor/Gather/Craft) is derived at read time by
-- Modules/ReagentSource.lua -- nothing is baked into the recipe record.

local itemIDIndex = nil -- Lazy-built index: [itemID] = recipeID (highest priority recipe)

function VWB.Database:GetRecipe(recipeID)
    return VWB.Store:GetState().recipeStore[recipeID]
end

function VWB.Database:GetAllRecipes()
    return VWB.Store:GetState().recipeStore
end

-- Facade over ReagentSource: "Crafted" / "Farm / Buy" / nil (endproduct-only
-- itemIDs have no reagent-source answer -- they should never be queried here).
function VWB.Database:GetReagent(itemID)
    local class = VWB.ReagentSource:GetClass(itemID)
    if class == "crafted" then return "Crafted" end
    if class == "farmbuy" then return "Farm / Buy" end
    return nil -- exception(nullable): endproduct-only itemIDs have no reagent-source answer
end

-- Drop the lazy itemID index. Called by the ADD_RECIPES reducer so a
-- harvest's new records are visible immediately.
-- (ReagentSource/Inventory invalidation calls stripped for the Showroom port
-- -- VWB has no reagent-source or inventory-variants concern.)
function VWB.Database:InvalidateIndexes()
    itemIDIndex = nil
    VWB.ReagentSource:InvalidateIndexes()   -- else Stockroom's reagent index freezes after a harvest
    VWB.Inventory:InvalidateVariantsCache()  -- quality-variant slot lists re-derive too
    VWB.Graph:InvalidateCyclicCache()        -- cyclicity depends on the harvested corpus (perf A2)
end

function VWB.Database:IsCraftedReagent(itemID)
    return VWB.ReagentSource:GetClass(itemID) == "crafted"
end

-- Build itemID -> recipeID index with priority ranking
local function BuildItemIDIndex()
    if itemIDIndex then return end
    itemIDIndex = {}

    -- Priority scores: Mining > other professions > Alchemy Transmute
    local function GetPriority(recipe)
        if recipe.profession == "Mining" then
            return 10
        elseif recipe.profession == "Alchemy" and recipe.name and recipe.name:match("Transmut") then
            return 0
        else
            return 5
        end
    end

    -- First pass: build temporary table of all recipes for each itemID
    local candidates = {} -- [itemID] = { {recipeID, priority}, ... }
    for recipeID, recipe in pairs(VWB.Database:GetAllRecipes()) do
        if recipe.itemID then
            if not candidates[recipe.itemID] then
                candidates[recipe.itemID] = {}
            end
            table.insert(candidates[recipe.itemID], { recipeID = recipeID, priority = GetPriority(recipe) })
        end
    end

    -- Second pass: select highest priority recipe for each itemID
    for itemID, recipeList in pairs(candidates) do
        local best = recipeList[1]
        for i = 2, #recipeList do
            if recipeList[i].priority > best.priority then
                best = recipeList[i]
            end
        end
        itemIDIndex[itemID] = best.recipeID
    end
end

-- Find recipe by output itemID (with priority: Mining > other > Alchemy Transmute)
-- Returns recipeID, recipe (two values) so callers can access the key
function VWB.Database:GetRecipeByItemID(itemID, craftedOnly)
    if craftedOnly and not self:IsCraftedReagent(itemID) then
        return nil, nil
    end

    BuildItemIDIndex()
    local recipeID = itemIDIndex and itemIDIndex[itemID]
    if recipeID then
        return recipeID, self:GetRecipe(recipeID)
    end
    return nil, nil
end
