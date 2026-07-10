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

-- ============================================================================
-- KIND CLASSIFICATION + UNCOLLECTED COUNT (canonical, shared)
-- ============================================================================
-- ONE home for the decor -> transmog -> mount -> pet chain (was triplicated:
-- Showroom kindRes, Workbench Missing pill, ProjectPlanner). The Showroom's
-- kindRes stays separate on purpose -- it needs async PENDING/ready semantics
-- per row; this is the synchronous memoized flavor for filters/counts/plans.

local kindCache = {} -- itemID -> kind; identity is static, never invalidated
function C:ClassifyKind(itemID)
    if not itemID then return "none" end
    local cached = kindCache[itemID]
    if cached then return cached end
    local k
    if VWB.DecorOwnership:IsDecor(itemID) then k = "decor"
    elseif VWB.Transmog:IsTransmoggable(itemID) then k = "transmog"
    elseif self:IsMount(itemID) then k = "mount"
    elseif self:IsPet(itemID) then k = "pet"
    else k = "none"
    end
    -- Latch positives always. Latch "none" ONLY when both sources that can
    -- produce a false negative are warm: cold item data blanks GetMountFromItem/
    -- GetPetInfoByItemID, a cold housing catalog blanks IsDecor -- memoizing
    -- "none" then would hide a real collectible for the whole session.
    if k ~= "none"
        or (C_Item.IsItemDataCachedByID(itemID) and not VWB.DecorOwnership:IsCatalogCold()) then -- exception(boundary): cold sources; retry next call
        kindCache[itemID] = k
    end
    return k
end

-- true = an uncollected collectible; false = collected, not a collectible,
-- or no definitive answer yet (cold catalog nil fails honest -- callers'
-- empty states surface the "open the housing catalog" message).
function C:IsUncollectedCollectible(itemID)
    local k = self:ClassifyKind(itemID)
    if k == "decor" then return VWB.DecorOwnership:IsUncollected(itemID) == true end -- exception(boundary): nil on cold catalog -> false
    if k == "transmog" then return VWB.Transmog:IsUnknown(itemID) end
    if k == "mount" then return self:IsMountCollected(itemID) == false end
    if k == "pet" then return self:IsPetCollected(itemID) == false end
    return false
end

-- Global uncollected count over the harvested corpus, deduped by output item
-- (rank variants share one itemID). Filter-INDEPENDENT -- this is the nav
-- badge's number, live from window open without mounting the Showroom, and it
-- recomputes only on corpus growth or a collection event (lazy computed).
local collectionEpoch = VWB.Reactor.signal(0)
function C:BumpCollectionEpoch()
    VWB.Reactor.untrack(function() collectionEpoch(collectionEpoch() + 1) end)
end

-- Perf B1 (2026-07-11): the walk used to run synchronously inside this
-- computed on every collect event / harvest batch -- during cache warmup
-- (cold ClassifyKind entries re-query decor/transmog/mount/pet sources) that
-- was an API-call storm inside the reactive flush. The walk is now a
-- budget-ticked recount (RecipeHarvest's token discipline) whose ticks run
-- from the timer driver, OUTSIDE any flush; the finished total lands in a
-- plain signal. Consumers lag one recount (a few frames), never stall a flush.
local uncollectedCount = VWB.Reactor.signal(0)
local walkToken = 0     -- bumped ONLY for corpus restarts (and fresh starts)
local walkRunning = false
local walkDirty = false -- collection event landed mid-walk: rerun after completion
local RECOUNT_CHUNK = 400 -- recipeStore keys per tick (~5k corpus = ~13 frames)

-- Walk lifecycle (regression fix, same day): the first cut restarted the walk
-- on EVERY collection epoch bump. During item-load warmup each transmog settle
-- bumped the epoch every ~0.5s, so walks never got past the first few thousand
-- keys -- the corpus tail was never reached, the badge froze on a stale
-- partial count, and every partial pass pended a few more cold items whose
-- load results fired the NEXT settle: a self-sustaining creep (live: 550
-- settles, 15 fps). Now only CORPUS changes restart (resuming next() across
-- key inserts is undefined behavior); collection events set walkDirty and the
-- running walk COMPLETES -- the tail gets its item requests out early, warmup
-- converges in a few large batches, and the rerun coalesces behind it.
local beginWalk

local function recountTick(token, lastKey, seen, n)
    if token ~= walkToken then return end -- superseded by a corpus restart
    local store = VWB.Store:GetState().recipeStore
    local processed = 0
    local k, recipe = lastKey, nil
    while true do
        k, recipe = next(store, k)
        if k == nil then
            uncollectedCount(n)
            walkRunning = false
            if walkDirty then
                walkDirty = false
                VWB.ReactorWoW.after(0.5, function()
                    if not walkRunning then beginWalk() end
                end)
            end
            return
        end
        local itemID = recipe.itemID
        if itemID and not seen[itemID] then
            seen[itemID] = true
            if C:IsUncollectedCollectible(itemID) then n = n + 1 end
        end
        processed = processed + 1
        if processed >= RECOUNT_CHUNK then
            VWB.ReactorWoW.after(0, function() recountTick(token, k, seen, n) end)
            return
        end
    end
end

beginWalk = function()
    walkToken = walkToken + 1
    walkRunning = true
    local token = walkToken
    VWB.ReactorWoW.after(0, function() recountTick(token, nil, {}, 0) end)
end

C.UncollectedCount = VWB.Reactor.named("collectibles:uncollectedCount", function()
    return uncollectedCount()
end)

-- Collection-event fan-out: ONE owner for the mount/pet/transmog/decor
-- collection triggers (three separate view-owned event frames existed for the
-- same events -- unification pass 2026-07-11). Views register invalidation
-- callbacks here instead of owning raw frames.
local listeners = {}
function C:RegisterCollectionListener(fn)
    listeners[#listeners + 1] = fn
end

-- Reactive read of the collection epoch (subscribes the calling computed/effect).
function C.CollectionEpoch()
    return collectionEpoch()
end

local function onCollectionChanged()
    C:BumpCollectionEpoch()
    for i = 1, #listeners do listeners[i]() end
end

-- Registration only (no scanning): the same collection events the Showroom's
-- resources and ProjectPlanner watch, bumping the count's epoch + fan-out.
function C:Initialize()
    local f = CreateFrame("Frame")
    f:RegisterEvent("NEW_MOUNT_ADDED")
    f:RegisterEvent("NEW_PET_ADDED")
    f:SetScript("OnEvent", onCollectionChanged)
    VWB.EventBus:Register("VWB_TRANSMOG_UPDATED", onCollectionChanged)
    VWB.EventBus:Register("VWB_DECOR_OWNERSHIP_UPDATE", onCollectionChanged)
    -- Recount triggers, SPLIT by restart semantics: corpus changes restart
    -- the walk (fresh next() iteration); collection events let the running
    -- walk finish and rerun behind it. The effects only ARM ticks (no signal
    -- writes, no API calls in the flush); recountCorpus fires at init so the
    -- badge is live from login without mounting the Showroom.
    VWB.Reactor.effect(function()
        VWB.Store:Version("corpus")
        beginWalk()
    end, "collectibles:recountCorpus")
    VWB.Reactor.effect(function()
        collectionEpoch()
        if walkRunning then walkDirty = true else beginWalk() end
    end, "collectibles:recountCollection")
end
