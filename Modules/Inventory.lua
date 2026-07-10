VWB = VWB or {}
VWB.Inventory = {}

-- Bag/bank/warband counting with quality variant support and debounced updates

local variantsCache = nil -- [baseItemID] = { variantID1, variantID2, ... }

-- Build quality variants lookup from the live recipe store
local function BuildVariantsCache()
    if variantsCache then return end
    variantsCache = {}

    for _, recipe in pairs(VWB.Database:GetAllRecipes()) do
        if recipe.slots then
            for _, slot in ipairs(recipe.slots) do
                if slot.itemID and slot.variants and #slot.variants > 0 then
                    if not variantsCache[slot.itemID] or #slot.variants > #variantsCache[slot.itemID] then
                        variantsCache[slot.itemID] = slot.variants
                    end
                end
            end
        end
    end
end

-- The recipe store grows over a session (harvests keep adding recipes), unlike
-- the old static DB which was fixed at load -- called from
-- VWB.Database:InvalidateIndexes() so a harvest's new variant slots are seen.
function VWB.Inventory:InvalidateVariantsCache()
    variantsCache = nil
end

-- Tracked items = shopping-list materials + queued crafted outputs. Counts are
-- snapshotted so the update event only fires when one actually moves --
-- consumers repaint (and will pulse) on it, so no-op fires must not happen.
local lastCounts = nil

local function CollectTrackedCounts()
    local state = VWB.Store:GetState()
    local counts = {}
    for _, item in ipairs(state.crafting.shoppingList or {}) do
        counts[item.itemID] = VWB.Inventory:GetItemCountWithVariants(item.itemID)
    end
    for _, step in ipairs(state.crafting.expandedQueue or {}) do
        local recipe = VWB.Database:GetRecipe(step.recipeID)
        local itemID = recipe.itemID
        if itemID and itemID ~= 0 and counts[itemID] == nil then
            counts[itemID] = VWB.Inventory:GetItemCountWithVariants(itemID)
        end
    end
    return counts
end

-- Initialize event handling. NO debounce timer (deleted 2026-07-11): the old
-- 0.3s coalescer duplicated BAG_UPDATE_DELAYED, which IS Blizzard's own
-- fires-once-after-the-burst event -- so per-bag BAG_UPDATE isn't registered
-- at all. Bank events are singular; same-frame multiples coalesce in the
-- Reactor flush downstream anyway.
function VWB.Inventory:Initialize()
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
    frame:RegisterEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED") -- counts include warband bank
    frame:RegisterEvent("BAG_UPDATE_DELAYED") -- Blizzard-coalesced: once per bag-change burst
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")

    frame:SetScript("OnEvent", function()
        local counts = CollectTrackedCounts()
        local changed = {}
        for id, c in pairs(counts) do
            if not lastCounts or lastCounts[id] ~= c then
                table.insert(changed, id)
            end
        end
        if lastCounts then
            for id in pairs(lastCounts) do
                if counts[id] == nil then table.insert(changed, id) end -- left the tracked set
            end
        end
        lastCounts = counts
        if #changed > 0 then
            VWB.EventBus:Trigger("VWB_INVENTORY_UPDATE", { changed = changed })
        end
    end)
end

-- Get item count including bank, reagent bank, and warband bank
-- C_Item.GetItemCount(item, includeBank, includeUses, includeReagentBank, includeAccountBank)
function VWB.Inventory:GetItemCount(itemID)
    if not itemID then return 0 end
    return C_Item.GetItemCount(itemID, true, false, true, true) or 0
end

-- Get item count including all quality variants (R1 + R2 + R3)
function VWB.Inventory:GetItemCountWithVariants(itemID)
    if not itemID then return 0 end

    local total = C_Item.GetItemCount(itemID, true, false, true, true) or 0

    BuildVariantsCache()

    local variants = variantsCache and variantsCache[itemID]
    if variants then
        for _, variantID in ipairs(variants) do
            total = total + (C_Item.GetItemCount(variantID, true, false, true, true) or 0)
        end
    end

    return total
end
