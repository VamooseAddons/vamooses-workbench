VWB = VWB or {}
VWB.Transmog = {}

-- Appearance collection detection with cache

local cache = {} -- [itemID] = { hasAppearance = bool, isCollected = bool }
local eventFrame = nil
local pendingItemIDs = {} -- [itemID] = true; awaiting ITEM_DATA_LOAD_RESULT to retry GetStatus
local loadSettle = nil -- trailing-edge coalescer for the load-burst VWB_TRANSMOG_UPDATED fire

-- Equippable slots that carry NO transmog appearance (nothing to collect)
local NON_VISUAL_SLOTS = {
    INVTYPE_TRINKET = true, INVTYPE_FINGER = true, INVTYPE_NECK = true,
    INVTYPE_BAG = true, INVTYPE_AMMO = true, INVTYPE_QUIVER = true,
    INVTYPE_RELIC = true,
}

-- Is this item transmoggable AT ALL (the SCOPE question)? Keyed on item CLASS
-- (Weapon / Armor), not the equip slot alone -- crafting reagents like TWW
-- "Frameworks" report a bogus equippable slot but are Tradegoods, so a
-- slot-only test leaked them in. Weapons are all transmoggable; Armor is,
-- EXCEPT the appearance-less slots (neck/finger/trinket, which are Armor-class
-- but have no look). All from GetItemInfoInstant (Item.db2 static data, no
-- collection dependency) so the scope doesn't collapse on a cold cache;
-- ownership (Missing / tick / tooltip) stays the async GetStatus question.
local transmoggableRequested = {} -- request-once latch for cache-miss itemIDs
function VWB.Transmog:IsTransmoggable(itemID)
    if not itemID or itemID == 0 then return false end
    -- exception(boundary): GetItemInfoInstant has cache-miss cases (returns nil
    -- until the client pulls the item); request once so it resolves on the next
    -- GET_ITEM_INFO_RECEIVED and the scope re-filter picks it up.
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
    if not classID then
        if not transmoggableRequested[itemID] then
            transmoggableRequested[itemID] = true
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return false
    end
    if classID == Enum.ItemClass.Weapon then return true end
    if classID == Enum.ItemClass.Armor then
        return equipLoc ~= nil and equipLoc ~= "" and not NON_VISUAL_SLOTS[equipLoc]
    end
    return false
end

-- Get transmog status for item
function VWB.Transmog:GetStatus(itemID)
    if not itemID then
        return { hasAppearance = false, isCollected = false }
    end

    -- Return cached result
    if cache[itemID] then return cache[itemID] end

    -- Get item link
    local itemLink = select(2, C_Item.GetItemInfo(itemID))
    if not itemLink then -- exception(boundary): cold item cache; request once and retry on ITEM_DATA_LOAD_RESULT
        if not pendingItemIDs[itemID] then
            pendingItemIDs[itemID] = true
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return { hasAppearance = false, isCollected = false }
    end

    -- Check appearance
    local appearanceID = C_TransmogCollection.GetItemInfo(itemLink)

    if not appearanceID then -- exception(false-positive): appearanceID's presence IS the hasAppearance answer, not a readiness proxy (the collection check below uses itemLink)
        cache[itemID] = { hasAppearance = false, isCollected = false }
        return cache[itemID]
    end

    -- APPEARANCE-level collection check: "is this LOOK in the collection from
    -- ANY source" (wardrobe semantics), not "did I collect this exact item's
    -- source" -- the old per-source check read owned-from-elsewhere looks as
    -- uncollected. Armor class is irrelevant to collection membership.
    local isCollected = C_TransmogCollection.PlayerHasTransmogByItemInfo(itemLink) or false -- exception(boundary): Blizzard API bool

    cache[itemID] = { hasAppearance = true, isCollected = isCollected }
    return cache[itemID]
end

-- Check if transmog is unknown (has appearance but not collected)
function VWB.Transmog:IsUnknown(itemID)
    local status = self:GetStatus(itemID)
    return status.hasAppearance and not status.isCollected
end

-- Clear cache
function VWB.Transmog:ClearCache()
    cache = {}
end

-- Initialize event handling
function VWB.Transmog:Initialize()
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("TRANSMOG_COLLECTION_SOURCE_ADDED")
    eventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT") -- resolves pendingItemIDs from GetStatus cold-cache misses

    eventFrame:SetScript("OnEvent", function(_, event, arg1)
        if event == "TRANSMOG_COLLECTION_SOURCE_ADDED" then
            -- Invalidate uncollected entries so next GetStatus re-checks the wardrobe
            for itemID, status in pairs(cache) do
                if status.hasAppearance and not status.isCollected then
                    cache[itemID] = nil
                end
            end
            VWB.EventBus:Trigger("VWB_TRANSMOG_UPDATED", {})

        elseif event == "ITEM_DATA_LOAD_RESULT" then
            -- arg1 = itemID that just loaded (keyOf pattern; O(1) vs full scan)
            local itemID = arg1
            if pendingItemIDs[itemID] then
                pendingItemIDs[itemID] = nil
                cache[itemID] = nil -- clear the stub entry so GetStatus re-reads
                -- COALESCED fire (perf, observed live 2026-07-11): a cold-start
                -- warmup streams THOUSANDS of loads (10k events -> 3k per-item
                -- fires), and every fire runs the full listener fan-out (badge
                -- corpus walk, Showroom invalidateAll, Workbench re-derive) =
                -- ~10s of jank on view switch. One trailing-edge fire per
                -- settle window carries the same information.
                if loadSettle then loadSettle:Cancel() end
                loadSettle = VWB.ReactorWoW.after(0.3, function()
                    loadSettle = nil
                    VWB.EventBus:Trigger("VWB_TRANSMOG_UPDATED", {})
                end)
            end
        end
    end)
end
