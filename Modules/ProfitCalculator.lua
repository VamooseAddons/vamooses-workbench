-- ============================================================================
-- VamoosesWorkbench - ProfitCalculator
-- Centralized profit calculation API (engine decoupled from UI)
-- ============================================================================

VWB = VWB or {}
VWB.ProfitCalculator = {}

local AH_CUT = 0.05 -- consignment cut the AH takes from every sale; ignoring it overstates profit

-- ============================================================================
-- SINGLE RECIPE PROFIT
-- ============================================================================

-- Returns { recipeID, name, profession, expansion, itemID, isDecor,
--           sellPrice, materialCost, profit, margin, hasAllPrices }
-- or nil if recipe not found. profit/margin are nil unless BOTH sides have
-- real market prices -- no invented numbers.
function VWB.ProfitCalculator:Calculate(recipeID)
    local recipe = VWB.Database:GetRecipe(recipeID)
    if not recipe then return nil end

    -- Multi-output recipes (milling, feasts) sell the whole batch, not one
    -- unit: expected output = midpoint of the schematic's min/max range
    local unitPrice = VWB.PriceIntegration:GetPrice(recipe.itemID)
    local expectedOutput = ((recipe.outputQtyMin or 1) + (recipe.outputQtyMax or 1)) / 2
    local sellPrice = unitPrice and (unitPrice * expectedOutput) or nil

    local materialCost = 0
    local missingPrices = sellPrice == nil

    -- BoP reagents have no auction price by definition; they contribute time,
    -- not gold, so they're excluded from the gold cost. The Ledger is a
    -- gold-making view -- which mats must be farmed is the Workbench's job.
    local materials = VWB.Graph:GetDirectMaterials(recipeID, 1)
    for _, mat in ipairs(materials or {}) do
        if VWB.ReagentSource:GetInfo(mat.itemID).bop ~= true then
            local matPrice = VWB.PriceIntegration:GetPrice(mat.itemID)
            if matPrice then
                materialCost = materialCost + (matPrice * mat.required)
            else
                missingPrices = true
            end
        end
    end

    -- Honest profit needs a market price on BOTH sides: a row whose entire
    -- cost was skipped as BoP (materialCost 0) would otherwise claim the full
    -- sell price as "profit"
    local profit = nil
    local margin = nil
    local hasAllPrices = not missingPrices and materialCost > 0
    if hasAllPrices then
        local net = sellPrice
        if VWB.Store:GetState().config.applyAHCut then
            net = sellPrice * (1 - AH_CUT)
        end
        profit = net - materialCost
        margin = (profit / materialCost) * 100
    end

    return {
        recipeID = recipeID,
        name = recipe.name,
        profession = recipe.profession,
        expansion = recipe.expansion,
        itemID = recipe.itemID,
        isDecor = VWB.DecorOwnership:IsDecor(recipe.itemID),
        sellPrice = sellPrice,
        materialCost = materialCost,
        profit = profit,
        margin = margin,
        hasAllPrices = hasAllPrices,
    }
end
