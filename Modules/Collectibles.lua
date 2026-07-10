VWB = VWB or {}
VWB.Collectibles = {}

-- ============================================================================
-- VamoosesWorkbench - Collectibles
-- Mount + pet identity, collection state, and preview display IDs, resolved
-- from a crafted recipe's OUTPUT itemID. Decor and transmog have their own
-- modules (DecorOwnership / Transmog); this covers the other two craftable
-- collectible kinds the Showroom previews. Identity is static (item -> mount /
-- item -> pet species), so it's memoized; collection state is queried live so
-- collecting something updates it without a cache flush.
-- ============================================================================

local C = VWB.Collectibles

local mountIDCache = {}  -- itemID -> mountID (positives only; nil re-checks so cold item data can resolve)
local petInfoCache = {}  -- itemID -> { speciesID, displayID }

-- ============================================================================
-- MOUNTS
-- ============================================================================

function C:MountID(itemID)
    if not itemID then return nil end
    local cached = mountIDCache[itemID]
    if cached then return cached end
    local mountID = C_MountJournal.GetMountFromItem(itemID) -- exception(boundary): nil for non-mount items / cold item data
    if mountID then mountIDCache[itemID] = mountID end
    return mountID
end

function C:IsMount(itemID)
    return self:MountID(itemID) ~= nil
end

-- true = collected, false = not, nil = not a mount
function C:IsMountCollected(itemID)
    local mountID = self:MountID(itemID)
    if not mountID then return nil end
    local isCollected = select(11, C_MountJournal.GetMountInfoByID(mountID)) -- exception(boundary): Blizzard tuple, isCollected is 11th
    return isCollected == true
end

function C:MountDisplayID(itemID)
    local mountID = self:MountID(itemID)
    if not mountID then return nil end
    return (C_MountJournal.GetMountInfoExtraByID(mountID)) -- creatureDisplayID (first return)
end

-- ============================================================================
-- PETS
-- ============================================================================

-- Returns speciesID, displayID (or nil if the item doesn't teach a pet)
function C:PetInfo(itemID)
    if not itemID then return nil end
    local cached = petInfoCache[itemID]
    if cached then return cached.speciesID, cached.displayID end
    -- GetPetInfoByItemID returns (name, icon, petType, creatureID, sourceText,
    -- description, isWild, canBattle, isTradeable, isUnique, obtainable,
    -- displayID, speciesID) -- verified vs warcraft.wiki 2026-07-06.
    local _, _, _, _, _, _, _, _, _, _, _, displayID, speciesID =
        C_PetJournal.GetPetInfoByItemID(itemID) -- exception(boundary): nil for non-pet items / cold item data
    if not speciesID then return nil end
    petInfoCache[itemID] = { speciesID = speciesID, displayID = displayID }
    return speciesID, displayID
end

function C:IsPet(itemID)
    return (self:PetInfo(itemID)) ~= nil
end

-- true = collected (own >= 1), false = not, nil = not a pet.
-- GetOwnedBattlePetString (nil = owns 0) is FILTER-INDEPENDENT -- GetNumCollectedInfo
-- is not (its count reflects the Pet Journal's active search/filter), so an owned
-- pet filtered out of the journal would read as uncollected. Blizzard's own
-- BattlePetTooltip uses this string. Verified vs wow-api MCP 2026-07-07.
function C:IsPetCollected(itemID)
    local speciesID = self:PetInfo(itemID)
    if not speciesID then return nil end
    return C_PetJournal.GetOwnedBattlePetString(speciesID) ~= nil -- exception(boundary): Blizzard, nil = 0 owned
end

function C:PetDisplayID(itemID)
    local _, displayID = self:PetInfo(itemID)
    return displayID
end
