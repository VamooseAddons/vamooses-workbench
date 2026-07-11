-- ============================================================================
-- VWB ItemData -- THE item-data broker (Constitution R4/R5; migration step 2)
-- ============================================================================
-- The ONE requester of item data in the addon (Lattice cookbook ch18 shape:
-- Blizzard's ItemEventListener owns the listen half). Acquisition-driven:
-- the first read of an unseen itemID registers ONE ItemEventListener callback
-- -- which itself issues the ONE RequestLoadItemDataByID (verified against
-- Blizzard AsyncCallbackSystem.lua 2026-07-11: AddCallback calls the accessor
-- when it is the first pending callback for the id; pairing it with an
-- explicit RequestLoad, as older notes suggested, DOUBLE-requests).
--
-- Values latch AT the callback -- the moment of truth -- into a latchMap.
-- No code ever re-reads the client item cache after that: convergence cannot
-- depend on cache retention (the ReganB non-convergence class).
--
-- State machine per key (SolidJS names + the WoW lossy-cache split, R5):
--   (unseen)   acquire -> PENDING latch
--   ready      callback fired, in-callback read non-nil -> record latched, final
--   retrying   callback fired but the SYNCHRONOUS in-callback read was nil
--              (lossy-cache anomaly): re-acquire, at most MAX_ATTEMPTS total.
--              The one machine retry in the addon (Constitution R5 exception).
--   NODATA     attempts exhausted -> terminal; refetch() is the only way out
--   DEAD       ITEM_DATA_LOAD_RESULT success=false. ItemEventListener DROPS
--              callbacks on failure without firing them (verified in source),
--              so the broker subscribes the failure event itself through the
--              Reactor event source; that handler ONLY latches (R2).
--
-- Fail-loud invariant (R4): requests can never exceed
-- acquiredKeys * MAX_ATTEMPTS + manual refetches. If they do, a machine loop
-- exists and we want the error, not a degraded tester session.
-- ============================================================================

local _, ns = ...
local Reactor = ns.Reactor

local MAX_ATTEMPTS = 3 -- 1 initial + 2 lossy-cache retries (R5)

local DEAD   = setmetatable({}, { __tostring = function() return "<dead>" end })
local NODATA = setmetatable({}, { __tostring = function() return "<nodata>" end })

local latch = Reactor.latchMap("itemdata")
local attempts = {}   -- id -> requests made for this id
local onReadyFns = {} -- id -> { fn, ... } one-shot boundary callbacks at latch
local stats = { acquired = 0, requests = 0, ready = 0, retried = 0, nodata = 0, dead = 0, refetches = 0 }

local ItemData = { PENDING = Reactor.PENDING, DEAD = DEAD, NODATA = NODATA }
ns.ItemData = ItemData

local function fireOnReady(id, record)
    local fns = onReadyFns[id]
    if not fns then return end
    onReadyFns[id] = nil
    for i = 1, #fns do fns[i](record) end
end

-- The latch-at-the-moment-of-truth read. Runs INSIDE the ItemEventListener
-- callback (data guaranteed hot per the event's contract; when the lossy
-- cache breaks that contract we see nil here and take the R5 retry).
local function readRecord(id)
    local name, link, quality = C_Item.GetItemInfo(id) -- exception(boundary): inside the load callback; nil = lossy-cache anomaly
    if not name then return nil end
    return { name = name, link = link, quality = quality }
end

local requestKey -- fwd (retry path re-enters under the R5 exception)

local function onLoaded(id)
    local record = readRecord(id)
    if record then
        stats.ready = stats.ready + 1
        latch:latch(id, record)
        fireOnReady(id, record)
        return
    end
    if attempts[id] < MAX_ATTEMPTS then
        stats.retried = stats.retried + 1
        requestKey(id) -- Constitution R5's ONE machine retry: success-reported, nil in-callback read
        return
    end
    stats.nodata = stats.nodata + 1
    latch:latch(id, NODATA)
    fireOnReady(id, nil)
end

requestKey = function(id)
    attempts[id] = (attempts[id] or 0) + 1
    stats.requests = stats.requests + 1
    if stats.requests > stats.acquired * MAX_ATTEMPTS + stats.refetches * MAX_ATTEMPTS then
        error(("VWB.ItemData: request invariant violated (%d requests for %d acquired keys) -- a machine loop exists")
            :format(stats.requests, stats.acquired))
    end
    -- AddCallback subscribes AND issues the accessor call (request-once per
    -- pending-callback set); callbacks self-clear on fire or failure.
    ItemEventListener:AddCallback(id, function() onLoaded(id) end)
end

-- Acquisition WRITES (the PENDING latch) -- and reads legally happen inside
-- computeds, so the write half rides Reactor.defer: queued past the current
-- computed evaluation, inline everywhere else (live 2026-07-11: the purity
-- guard caught projects:plans acquiring synchronously). Until the deferred
-- latch lands, tracked readers see nil, which the API treats as PENDING.
local acquiring = {} -- ids with a deferred acquisition queued (pre-latch dedupe)
local function acquire(id)
    if latch:hasKey(id) or acquiring[id] then return end
    acquiring[id] = true
    Reactor.defer(function()
        acquiring[id] = nil
        if latch:hasKey(id) then return end
        stats.acquired = stats.acquired + 1
        latch:latch(id, Reactor.PENDING)
        requestKey(id)
    end)
end

-- Failure half: ItemEventListener never fires callbacks for success=false
-- (it clears them), so the broker listens for the failure itself. This
-- handler ONLY latches (R2). Subscribed lazily on first acquisition so the
-- module is inert until something actually asks for item data (R6).
local failureSubscribed = false
local function ensureFailureListener()
    if failureSubscribed then return end
    failureSubscribed = true
    Reactor.subscribeEvent("ITEM_DATA_LOAD_RESULT", function(id, success)
        if success or not latch:hasKey(id) or latch:peek(id) ~= Reactor.PENDING then return end
        stats.dead = stats.dead + 1
        latch:latch(id, DEAD)
        fireOnReady(id, nil)
    end)
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

-- Tracked read: record | PENDING | DEAD | NODATA. Acquires on first sight.
-- nil (deferred acquisition not yet latched) normalizes to PENDING so
-- callers see exactly one "not yet" value.
function ItemData.get(id)
    ensureFailureListener()
    acquire(id)
    local v = latch:get(id)
    if v == nil then return Reactor.PENDING end
    return v
end

function ItemData.peek(id) return latch:peek(id) end
function ItemData.isTerminal(id)
    local v = latch:peek(id)
    return v ~= nil and v ~= Reactor.PENDING
end
function ItemData.isDead(id) return latch:peek(id) == DEAD end

-- Display-name convenience, matNameRes-compatible: string | PENDING.
-- Terminal-without-data keys resolve to the honest id fallback so consumers'
-- "Loading..." states end.
function ItemData.nameFor(id)
    local v = ItemData.get(id)
    if v == Reactor.PENDING then return Reactor.PENDING end
    if v == DEAD or v == NODATA then return "item:" .. tostring(id) end
    return v.name
end

-- One-shot boundary callback: fn(record|nil) at latch time (nil = terminal
-- without data). Fires immediately if already terminal. Boundary-side --
-- callers get exactly one call, at the moment the broker latches.
function ItemData.onReady(id, fn)
    ensureFailureListener()
    acquire(id)
    local v = latch:peek(id)
    if v ~= Reactor.PENDING then
        fn((v ~= DEAD and v ~= NODATA) and v or nil)
        return
    end
    local fns = onReadyFns[id]
    if not fns then fns = {}; onReadyFns[id] = fns end
    fns[#fns + 1] = fn
end

-- The only retry path (R5): human-initiated.
function ItemData.refetch(id)
    if not latch:hasKey(id) then return end
    stats.refetches = stats.refetches + 1
    attempts[id] = 0
    latch:latch(id, Reactor.PENDING)
    requestKey(id)
end

-- Aggregate change signal (engine-maintained inside latch writes, R3).
function ItemData.changedEpoch() return latch.epoch() end

function ItemData.stats() return stats end

return ItemData
