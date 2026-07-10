VWB = VWB or {}
VWB.DecorOwnership = {}

-- Housing-decor collection status -- the decor twin of Modules/Transmog.lua.
-- Ownership math is HDGR's production formula: quantity + remainingRedeemable
-- + numPlaced > 0 (the DOCUMENTED numStored/totalNum* fields are always nil
-- at runtime on 12.0.5+). The catalog is COLD until the housing catalog UI or
-- another catalog consumer has loaded it once per session: reads return nil
-- for "no answer yet" and callers MUST treat nil as unknown, never "unowned".

local cache = {} -- [itemID] = true (owned) / false (unowned); nil answers never cached
local catalogWarm = false -- true once ANY catalog read has ever succeeded this session

local eventFrame

-- Returns true (uncollected), false (owned), or nil (not decor / catalog cold)
function VWB.DecorOwnership:IsUncollected(itemID)
    if not itemID or itemID == 0 then return nil end
    local cached = cache[itemID]
    if cached ~= nil then return not cached end

    local info = C_HousingCatalog.GetCatalogEntryInfoByItem(itemID, true) -- exception(boundary): nil for non-decor items AND until catalog warm
    if not info then return nil end
    catalogWarm = true

    local owned = ((info.quantity or 0) + (info.remainingRedeemable or 0) + (info.numPlaced or 0)) > 0 -- exception(boundary): per-field nils per HDGR observer
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

function VWB.DecorOwnership:ClearCache()
    cache = {}
end

function VWB.DecorOwnership:Initialize()
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("HOUSING_STORAGE_ENTRY_UPDATED")
    eventFrame:SetScript("OnEvent", function()
        cache = {} -- ownership moved; cheap full invalidation, recomputed lazily
        VWB.EventBus:Trigger("VWB_DECOR_OWNERSHIP_UPDATE", {})
    end)
end
