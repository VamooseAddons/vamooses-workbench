VWB = VWB or {}
VWB.DecorOwnership = {}

-- ============================================================================
-- Housing-decor collection status -- the decor twin of Modules/Transmog.lua.
-- Ownership math is HDGR's production formula: quantity + remainingRedeemable
-- + numPlaced > 0 (the DOCUMENTED numStored/totalNum* fields are always nil
-- at runtime on 12.0.5+). The catalog is COLD until the housing catalog UI or
-- another catalog consumer has loaded it once per session: reads return nil
-- for "no answer yet" and callers MUST treat nil as unknown, never "unowned".
--
-- Constitution migration step 4: the old HOUSING_STORAGE_ENTRY_UPDATED
-- handler WIPED the whole cache for lazy re-read (every consumer re-derived
-- everything per decor move). Now it is HDG's ReconcileEntry shape
-- (HDGR_HousingCatalogObserver, production): the event carries an entryID and
-- Blizzard's own HouseEditorStorageFrame reads GetCatalogEntryInfo(entryID)
-- synchronously inside the handler (verified, wow-api MCP) -- so the boundary
-- handler re-derives ONE item and latches it forward. Equality gates the
-- fan-out: a decor move that doesn't change ownership is total silence.
-- ============================================================================

-- Read-path memo (plain table -- read paths run inside computeds where signal
-- writes are illegal; the latchMap below is written ONLY from boundary
-- handlers and carries the reactive epoch).
local cache = {} -- [itemID] = true (owned) / false (unowned); nil answers never cached
local latch = nil -- Reactor latchMap "decor"; created in Initialize (Reactor loads first)
local catalogWarm = false -- true once ANY catalog read has ever succeeded this session

local function ownedFromInfo(info)
    return ((info.quantity or 0) + (info.remainingRedeemable or 0) + (info.numPlaced or 0)) > 0 -- exception(boundary): per-field nils per HDGR observer
end

-- Returns true (uncollected), false (owned), or nil (not decor / catalog cold)
function VWB.DecorOwnership:IsUncollected(itemID)
    if not itemID or itemID == 0 then return nil end
    local cached = cache[itemID]
    if cached ~= nil then return not cached end

    local info = C_HousingCatalog.GetCatalogEntryInfoByItem(itemID, true) -- exception(boundary): nil for non-decor items AND until catalog warm
    if not info then return nil end
    catalogWarm = true

    local owned = ownedFromInfo(info)
    cache[itemID] = owned
    return not owned
end

-- Session-level: true until the FIRST successful catalog read (proof the
-- housing catalog UI has loaded this session, per the GetCatalogEntryInfoByItem
-- cold-start gotcha above). Never re-cold once warmed. Feeds the Workbench
-- Decor/Missing filter's empty-state affordance -- "zero matches" is expected
-- while cold, not a real answer, and the UI must say so instead of going quiet.
function VWB.DecorOwnership:IsCatalogCold()
    return not catalogWarm
end

-- "Is this even a decor item" (regardless of ownership) -- the live-catalog
-- replacement for the old static-DB decorID field. Same catalog-warm gate as
-- IsUncollected: a definitive true/false answer here IS confirmation the
-- catalog recognizes this itemID as decor; false also covers "catalog cold",
-- which is the accepted tradeoff of having no baked ground truth anymore.
function VWB.DecorOwnership:IsDecor(itemID)
    return self:IsUncollected(itemID) ~= nil
end

-- Reactive aggregate: bumps ONLY when some item's ownership actually changed
-- (or first resolved). Aggregate walkers subscribe this and peek the reads.
function VWB.DecorOwnership.Epoch()
    return latch.epoch()
end

function VWB.DecorOwnership:ClearCache()
    cache = {}
end

-- Boundary reconcile (HDG ReconcileEntry shape): derive ONE entry's ownership
-- at the moment of truth and latch it forward. Equality-gated fan-out.
local function reconcileEntry(entryID)
    local info = C_HousingCatalog.GetCatalogEntryInfo(entryID) -- exception(boundary): entry may have been removed
    if not info or not info.itemID then return end
    catalogWarm = true
    local owned = ownedFromInfo(info)
    if cache[info.itemID] == owned then return end -- no ownership change: total silence
    cache[info.itemID] = owned
    latch:latch(info.itemID, owned)
    VWB.EventBus:Trigger("VWB_DECOR_OWNERSHIP_UPDATE", { itemID = info.itemID })
end

function VWB.DecorOwnership:Initialize()
    latch = VWB.Reactor.latchMap("decor")
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("HOUSING_STORAGE_ENTRY_UPDATED")
    eventFrame:SetScript("OnEvent", function(_, _, entryID)
        if entryID == nil then -- exception(boundary): documented payload absent; fall back to the old full invalidation rather than miss an ownership change
            cache = {}
            latch:forceBump()
            VWB.EventBus:Trigger("VWB_DECOR_OWNERSHIP_UPDATE", {})
            return
        end
        reconcileEntry(entryID)
    end)
end
