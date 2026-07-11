-- Headless tests for the VWB ItemData broker (Constitution R4/R5).
-- Run: lua tests/vwb_itemdata_test.lua
-- Includes the regression that escaped to production 2026-07-11: a client
-- item cache that FORGETS between the load event and a later read. Under the
-- broker, convergence must be independent of cache retention, request count
-- must stay bounded by acquiredKeys * MAX_ATTEMPTS, and terminal states must
-- never re-request on their own.

local base = arg[0]:gsub("tests/vwb_itemdata_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", { Reactor = R })

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Mock event source (failure-path channel) ----------------------------------
local handlers = {}
R.setEventSource(function(event, h)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], h)
    return function() end
end)
local function fireEvent(event, ...)
    for _, h in ipairs(handlers[event] or {}) do h(...) end
end

-- Mock client item cache + ItemEventListener --------------------------------
-- cache[id] = name (readable) | nil (cold). lossyReads[id] = N makes the
-- first N in-callback reads return nil DESPITE the load event firing --
-- the exact lossy-cache anomaly.
local cache, lossyReads = {}, {}
_G.C_Item = {
    GetItemInfo = function(id)
        if (lossyReads[id] or 0) > 0 then
            lossyReads[id] = lossyReads[id] - 1
            return nil
        end
        local name = cache[id]
        if not name then return nil end
        return name, "link:" .. id, 2
    end,
}
local pendingCbs, addCallbackCount = {}, {}
_G.ItemEventListener = {
    AddCallback = function(_, id, cb)
        addCallbackCount[id] = (addCallbackCount[id] or 0) + 1
        pendingCbs[id] = pendingCbs[id] or {}
        table.insert(pendingCbs[id], cb)
    end,
}
-- Blizzard semantics: clear BEFORE firing; failure clears WITHOUT firing.
local function fireLoaded(id)
    local cbs = pendingCbs[id]; pendingCbs[id] = nil
    for _, cb in ipairs(cbs or {}) do cb() end
end
local function fireFailed(id)
    pendingCbs[id] = nil
    fireEvent("ITEM_DATA_LOAD_RESULT", id, false)
end

local ItemData = loadfile(base .. "Core/VWB_ItemData.lua")("VWB", { Reactor = R })

-- 1. acquisition: one AddCallback, PENDING until the event ------------------
do
    local v = ItemData.get(101)
    check("unseen key reads PENDING", v == R.PENDING)
    check("exactly one AddCallback", addCallbackCount[101] == 1)
    ItemData.get(101); ItemData.get(101)
    check("re-reads do not re-request", addCallbackCount[101] == 1)
end

-- 2. ready path: latch at callback, final ------------------------------------
do
    cache[101] = "Ghost Iron Bar"
    fireLoaded(101)
    local v = ItemData.get(101)
    check("record latched at callback", type(v) == "table" and v.name == "Ghost Iron Bar")
    cache[101] = nil -- client evicts AFTER the latch...
    check("eviction is irrelevant post-latch", ItemData.get(101).name == "Ghost Iron Bar")
    check("no further requests", addCallbackCount[101] == 1)
end

-- 3. THE ESCAPED BUG: lossy cache (success event, nil read) -> bounded retry -
do
    cache[202] = "Windwool Cloth"
    lossyReads[202] = 2 -- first two in-callback reads come back nil
    ItemData.get(202)
    fireLoaded(202) -- read nil -> retry 1 (re-AddCallback)
    check("retry re-requested once", addCallbackCount[202] == 2)
    check("still PENDING mid-retry", ItemData.peek(202) == R.PENDING)
    fireLoaded(202) -- read nil -> retry 2
    fireLoaded(202) -- read succeeds
    check("converged despite lossy cache", ItemData.peek(202).name == "Windwool Cloth")
    check("requests bounded at MAX_ATTEMPTS", addCallbackCount[202] == 3)
end

-- 4. lossy exhaustion -> NODATA terminal, silent forever ---------------------
do
    lossyReads[303] = 99 -- never readable
    ItemData.get(303)
    fireLoaded(303); fireLoaded(303); fireLoaded(303)
    check("exhausted to NODATA", ItemData.peek(303) == ItemData.NODATA)
    check("stopped at 3 requests", addCallbackCount[303] == 3)
    ItemData.get(303); ItemData.get(303)
    check("terminal NODATA never re-requests", addCallbackCount[303] == 3)
    check("isTerminal true", ItemData.isTerminal(303))
end

-- 5. dead id: failure event latches DEAD without any callback ---------------
do
    ItemData.get(404)
    fireFailed(404)
    check("failure latched DEAD", ItemData.isDead(404))
    ItemData.get(404)
    check("DEAD never re-requests", addCallbackCount[404] == 1)
end

-- 6. nameFor display semantics ------------------------------------------------
do
    check("nameFor pending = PENDING", ItemData.nameFor(505) == R.PENDING)
    check("nameFor NODATA = id fallback", ItemData.nameFor(303) == "item:303")
    check("nameFor DEAD = id fallback", ItemData.nameFor(404) == "item:404")
    check("nameFor ready = name", ItemData.nameFor(101) == "Ghost Iron Bar")
end

-- 7. onReady one-shot ---------------------------------------------------------
do
    local got, calls = nil, 0
    ItemData.onReady(606, function(rec) got = rec; calls = calls + 1 end)
    cache[606] = "Trillium Ore"
    fireLoaded(606)
    check("onReady fired once with record", calls == 1 and got and got.name == "Trillium Ore")
    fireLoaded(606) -- stray double event: no pending cbs remain
    check("onReady stays one-shot", calls == 1)
    local immediate
    ItemData.onReady(606, function(rec) immediate = rec end)
    check("onReady after terminal fires immediately", immediate and immediate.name == "Trillium Ore")
    local deadGot = "sentinel"
    ItemData.onReady(404, function(rec) deadGot = rec end)
    check("onReady on DEAD fires nil immediately", deadGot == nil)
end

-- 8. refetch is the only way out of NODATA ------------------------------------
do
    cache[303] = "Recovered Item"
    lossyReads[303] = 0
    ItemData.refetch(303)
    check("refetch re-pends", ItemData.peek(303) == R.PENDING)
    fireLoaded(303)
    check("refetch recovered the record", ItemData.peek(303).name == "Recovered Item")
end

-- 9. reactivity: changedEpoch + fine-grained reads ----------------------------
do
    local runs = 0
    R.effect(function() ItemData.changedEpoch(); runs = runs + 1 end)
    local before = runs
    ItemData.get(707) -- acquisition latches PENDING = a real change
    check("acquisition bumps epoch", runs == before + 1)
    ItemData.get(707)
    check("re-read does not bump", runs == before + 1)
    local seen
    R.effect(function() seen = ItemData.nameFor(707) end)
    check("reader sees PENDING", seen == R.PENDING)
    cache[707] = "Living Steel"
    fireLoaded(707)
    check("reader re-ran to the name", seen == "Living Steel")
end

-- 10. acquisition from INSIDE a computed defers its latch write ---------------
-- (live 2026-07-11: projects:plans acquired synchronously and the engine's
-- purity guard threw "a computed wrote a signal". Acquisition now queues via
-- Reactor.defer and executes at top of stack.)
do
    local name = R.named("test:computedAcquire", function()
        return ItemData.nameFor(808)
    end)
    local v = name() -- lazy top-level read: computed evaluates, acquisition deferred to its exit
    check("computed read returns PENDING, no purity error", v == R.PENDING)
    check("deferred acquisition issued after the compute", addCallbackCount[808] == 1)
    name(); name()
    check("re-reads do not re-acquire", addCallbackCount[808] == 1)
    cache[808] = "Deferred Ore"
    fireLoaded(808)
    check("computed re-derives to the latched name", name() == "Deferred Ore")
end

print(string.format("VWB ItemData: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
