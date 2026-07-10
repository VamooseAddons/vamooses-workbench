VWB = VWB or {}
VWB.Transmog = {}

-- Appearance collection detection with cache

local cache = {} -- [itemID] = { hasAppearance = bool, isCollected = bool }
local eventFrame = nil
local pendingItemIDs = {} -- [itemID] = true; awaiting ITEM_DATA_LOAD_RESULT to retry GetStatus
local loadSettle = nil -- trailing-edge coalescer for ALL VWB_TRANSMOG_UPDATED fires
local deadItemIDs = {} -- load answered success=false (removed/invalid id): NEVER re-request
local sourceAddedDirty = false -- SOURCE_ADDED burst pending: wipe uncollected cache ONCE at settle
local stats = { srcAdded = 0, loadResolved = 0, loadDead = 0, pendsCreated = 0, fires = 0 } -- Debug tab

-- ONE settle for both fire sources. SOURCE_ADDED used to fire immediately AND
-- wipe every uncollected cache entry per event -- ATT/wardrobe activity bursts
-- it, each wipe re-pends every cold item on the next walk, and the warmup
-- cycle self-sustains (live 2026-07-11: 121 fires over 22min, ~10% cpu).
local function armSettle()
    if loadSettle then loadSettle:Cancel() end
    loadSettle = VWB.ReactorWoW.after(0.3, function()
        loadSettle = nil
        if sourceAddedDirty then
            sourceAddedDirty = false
            -- Invalidate uncollected entries so next GetStatus re-checks the
            -- wardrobe -- ONCE per settle window, not per event.
            for itemID, status in pairs(cache) do
                if status.hasAppearance and not status.isCollected then
                    cache[itemID] = nil
                end
            end
        end
        stats.fires = stats.fires + 1
        VWB.EventBus:Trigger("VWB_TRANSMOG_UPDATED", {})
    end)
end

-- Debug-tab counters: sizes + flow counts to name the loop driver when the
-- update stream misbehaves (pending/dead/cache sizes are computed on demand).
function VWB.Transmog:DebugStats()
    local pend, dead, cached = 0, 0, 0
    for _ in pairs(pendingItemIDs) do pend = pend + 1 end
    for _ in pairs(deadItemIDs) do dead = dead + 1 end
    for _ in pairs(cache) do cached = cached + 1 end
    return {
        pending = pend, dead = dead, cached = cached,
        srcAdded = stats.srcAdded, loadResolved = stats.loadResolved,
        loadDead = stats.loadDead, pendsCreated = stats.pendsCreated, fires = stats.fires,
    }
end

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
        if deadItemIDs[itemID] then
            -- The server refused this id (load result success=false): the honest
            -- answer is final. Latch it so walks stop re-requesting -- retrying
            -- looped forever (live 2026-07-11: 35k load results and climbing,
            -- one full fan-out per settle, sustained ~30ms/s of jank).
            cache[itemID] = { hasAppearance = false, isCollected = false }
            return cache[itemID]
        end
        if not pendingItemIDs[itemID] then
            pendingItemIDs[itemID] = true
            stats.pendsCreated = stats.pendsCreated + 1
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

    eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "TRANSMOG_COLLECTION_SOURCE_ADDED" then
            stats.srcAdded = stats.srcAdded + 1
            sourceAddedDirty = true
            armSettle() -- coalesced: the wipe + fire happen once per settle window
        elseif event == "ITEM_DATA_LOAD_RESULT" then
            -- (itemID, success). keyOf pattern; O(1) vs full scan.
            local itemID, success = arg1, arg2
            if pendingItemIDs[itemID] then
                pendingItemIDs[itemID] = nil
                if not success then
                    -- Dead id: mark it so GetStatus never re-requests. Without
                    -- this, walk -> request -> failure -> settle-fire -> walk
                    -- self-sustained forever (the post-coalescer loop).
                    stats.loadDead = stats.loadDead + 1
                    deadItemIDs[itemID] = true
                    return
                end
                stats.loadResolved = stats.loadResolved + 1
                cache[itemID] = nil -- clear the stub entry so GetStatus re-reads
                armSettle()
            end
        end
    end)
end
