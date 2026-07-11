VWB = VWB or {}
VWB.Transmog = {}

-- ============================================================================
-- Appearance collection detection -- broker-backed (Constitution migration
-- step 3, ATOMIC). The old module owned its own pend set, dead set, and
-- ITEM_DATA_LOAD_RESULT frame; a resolved id's pend latch was cleared and its
-- status re-derived from the CLIENT cache on a later read -- when the lossy
-- cache had already evicted the item, the id re-pended, and every settle
-- walked the corpus back into the same hole: the unbounded request loop
-- (108k requests on a tester's session; ~30/s sustained live). All of that
-- machinery is DELETED. Item data now comes from VWB.ItemData latches --
-- captured once, at the load callback, immune to cache eviction (R4) -- and
-- this module derives transmog status from the latched LINK via synchronous
-- wardrobe reads. Zero requests can originate here.
-- ============================================================================

-- status cache: derived once per itemID from latched record + wardrobe reads;
-- collected-status refreshed EAGERLY (latch-forward) by the SOURCE_ADDED
-- settle below. Bounded by the item corpus (~5k).
local cache = {}
local loadSettle = nil -- trailing-edge coalescer for SOURCE_ADDED bursts
local stats = { srcAdded = 0, fires = 0, derived = 0, flips = 0 }

-- Shared immutable default for "no appearance / not collected / not yet
-- derivable". Callers only read fields; nobody mutates a status table.
local NOT_TRANSMOG = { hasAppearance = false, isCollected = false }

-- SOURCE_ADDED settle: the player's wardrobe grew (ATT bursts this during
-- scans). Re-derive collected-status for the previously-uncollected entries
-- from their LATCHED links -- synchronous wardrobe reads, latch-forward,
-- ZERO requests (Constitution R2: a boundary path only re-latches). The old
-- shape wiped those entries for lazy re-read, which re-pended cold items.
local function armSettle()
    if loadSettle then loadSettle:Cancel() end
    loadSettle = VWB.ReactorWoW.after(0.3, function()
        loadSettle = nil
        for itemID, st in pairs(cache) do
            if st.hasAppearance and not st.isCollected then
                local rec = VWB.ItemData.peek(itemID) -- hasAppearance=true implies a ready record latched it
                if C_TransmogCollection.PlayerHasTransmogByItemInfo(rec.link) then
                    cache[itemID] = { hasAppearance = true, isCollected = true }
                    stats.flips = stats.flips + 1
                end
            end
        end
        stats.fires = stats.fires + 1
        VWB.EventBus:Trigger("VWB_TRANSMOG_UPDATED", {})
    end)
end

-- Debug-tab counters. Broker-sourced: the request/latch numbers live in
-- VWB.ItemData.stats() (THE requester); this module adds its derive/settle
-- flow. Field names kept for the Debug tab's TRANSMOG line.
function VWB.Transmog:DebugStats()
    local b = VWB.ItemData.stats()
    local cached = 0
    for _ in pairs(cache) do cached = cached + 1 end
    return {
        pending = b.acquired - b.ready - b.nodata - b.dead,
        dead = b.dead + b.nodata, cached = cached,
        srcAdded = stats.srcAdded, loadResolved = b.ready,
        loadDead = b.dead, pendsCreated = b.requests, fires = stats.fires,
        derived = stats.derived, flips = stats.flips,
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
function VWB.Transmog:IsTransmoggable(itemID)
    if not itemID or itemID == 0 then return false end
    -- exception(boundary): GetItemInfoInstant has cache-miss cases (returns nil
    -- until the client pulls the item); broker acquisition resolves it and the
    -- scope re-filter picks it up on the record latch.
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
    if not classID then
        VWB.ItemData.get(itemID) -- acquire once (R4); no bespoke request path
        return false
    end
    if classID == Enum.ItemClass.Weapon then return true end
    if classID == Enum.ItemClass.Armor then
        return equipLoc ~= nil and equipLoc ~= "" and not NON_VISUAL_SLOTS[equipLoc]
    end
    return false
end

-- Transmog status, derived from the LATCHED item record. PENDING ids answer
-- honest-false and re-derive when the record lands (callers in reactive
-- contexts are subscribed to the key via ItemData.get); terminal ids latch
-- honest-false finally. No path here can touch the client item cache.
function VWB.Transmog:GetStatus(itemID)
    if not itemID then return NOT_TRANSMOG end
    local hit = cache[itemID]
    if hit then return hit end

    local rec = VWB.ItemData.get(itemID)
    if rec == VWB.ItemData.PENDING then return NOT_TRANSMOG end -- not latched yet: no cache write, re-derives on latch
    if rec == VWB.ItemData.DEAD or rec == VWB.ItemData.NODATA then
        cache[itemID] = NOT_TRANSMOG
        return NOT_TRANSMOG
    end

    stats.derived = stats.derived + 1
    -- The latched link is self-contained -- wardrobe reads off it are
    -- synchronous and never touch the item cache.
    local appearanceID = C_TransmogCollection.GetItemInfo(rec.link)
    if not appearanceID then -- exception(false-positive): appearanceID's presence IS the hasAppearance answer, not a readiness proxy
        cache[itemID] = NOT_TRANSMOG
        return NOT_TRANSMOG
    end

    -- APPEARANCE-level collection check: "is this LOOK in the collection from
    -- ANY source" (wardrobe semantics), not "did I collect this exact item's
    -- source" -- the old per-source check read owned-from-elsewhere looks as
    -- uncollected. Armor class is irrelevant to collection membership.
    local isCollected = C_TransmogCollection.PlayerHasTransmogByItemInfo(rec.link) or false -- exception(boundary): Blizzard API bool
    local st = { hasAppearance = true, isCollected = isCollected }
    cache[itemID] = st
    return st
end

-- Check if transmog is unknown (has appearance but not collected)
function VWB.Transmog:IsUnknown(itemID)
    local status = self:GetStatus(itemID)
    return status.hasAppearance and not status.isCollected
end

-- Terminal authority: true when this id can never resolve (server refused it,
-- or the R5 retry budget exhausted on the lossy-cache anomaly). Consumers
-- (Showroom resources) resolve such keys instead of pending forever.
function VWB.Transmog:IsDeadItem(itemID)
    local v = VWB.ItemData.peek(itemID)
    return v == VWB.ItemData.DEAD or v == VWB.ItemData.NODATA
end

-- Clear the derived-status cache (re-derives from latches; zero requests).
function VWB.Transmog:ClearCache()
    cache = {}
end

-- Initialize: ONE boundary registration. ITEM_DATA_LOAD_RESULT belongs to
-- the ItemData broker now; this module's only event is the wardrobe growing.
function VWB.Transmog:Initialize()
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("TRANSMOG_COLLECTION_SOURCE_ADDED")
    eventFrame:SetScript("OnEvent", function()
        stats.srcAdded = stats.srcAdded + 1
        armSettle()
    end)
end
