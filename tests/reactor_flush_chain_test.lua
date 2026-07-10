-- Tests: flush-chain (effect writes signal during flush; later-queued effect observes
-- new value in same flush drain) + resource keyOf-returning-nil path.
-- Run: lua reactor_flush_chain_test.lua

local base = arg[0]:gsub("tests/reactor_flush_chain_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
local ns = { Reactor = R }
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", ns)

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Mock event source for resource tests ----------------------------------------
local handlers = {}
R.setEventSource(function(ev, h) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], h); return function() end end)
local function fire(ev, ...) for _, h in ipairs(handlers[ev] or {}) do h(...) end end

-- 1. FLUSH-CHAIN: effect A writes signal B; effect B (queued later) must observe
--    the new value of B in the SAME flush drain -- the while-loop in runFlush
--    handles newly-appended effects from within a flush run.
-- Contract: pendingEffects is a simple list; the loop runs until #pendingEffects
-- is exhausted each iteration, so B appended by A's signal-write runs before the
-- loop exits. This test pins that guarantee.
do
    local src = R.signal(0)
    local mid = R.signal(0) -- A writes this; B reads it

    local aSeen, bSeen = 0, 0
    -- Effect A: reads src, writes mid. Queued first.
    R.effect(function() aSeen = src(); mid(src() * 100) end, "flush-chain-A")
    -- Effect B: reads mid. Queued AFTER A (registered later -> appended after A in pendingEffects).
    R.effect(function() bSeen = mid() end, "flush-chain-B")

    check("flush-chain: initial A", aSeen == 0)
    check("flush-chain: initial B via mid", bSeen == 0)

    src(3) -- triggers flush: A runs -> writes mid(300) -> B gets queued -> B runs
    check("flush-chain: A saw new src", aSeen == 3)
    check("flush-chain: B observed new mid in same flush drain", bSeen == 300)

    src(7)
    check("flush-chain: second trigger A", aSeen == 7)
    check("flush-chain: second trigger B", bSeen == 700)
end

-- 2. RESOURCE keyOf-returning-nil path: keyOf returning nil must be a NO-OP --
--    (not crash, not resolve a wrong key, not create a nil entry in perKey).
do
    local store2 = {}
    local Res = R.resource({
        read    = function(id) return store2[id] end,
        request = function() end,
        event   = "KEYOF_NIL_EVENT",
        keyOf   = function(payload) return payload.id end, -- returns nil when payload.id is nil
    })
    local seen
    R.effect(function() seen = Res(10) end)
    check("keyOf-nil: starts pending", seen == R.PENDING)

    fire("KEYOF_NIL_EVENT", { id = nil }) -- keyOf returns nil -> must be a no-op
    check("keyOf-nil: nil keyOf is a no-op (still pending)", seen == R.PENDING)

    fire("KEYOF_NIL_EVENT", { id = 999 }) -- unknown key (no entry) -> also no-op
    check("keyOf-nil: unknown key is a no-op", seen == R.PENDING)

    store2[10] = "resolved"
    fire("KEYOF_NIL_EVENT", { id = 10 }) -- correct key -> resolves
    check("keyOf-nil: correct key resolves", seen == "resolved")
end

-- 3. epoch-writes are UNTRACKED inside a computed: a computed that reads the
--    resource epoch must NOT inadvertently acquire a dep on the epoch signal
--    from within the event handler (the untrack fix). Validate via re-run count.
do
    local store3 = {}
    local Res3 = R.resource({
        read    = function(id) return store3[id] end,
        request = function() end,
        event   = "EPOCH_UNTRACK_EVENT",
        keyOf   = function(id) return id end,
    })
    -- A computed reads the epoch (the intended dep) -- it should re-run when the
    -- epoch bumps via event resolution. It should NOT create extra edges from the
    -- untrack path.
    local computedRuns = 0
    local epochC = R.computed(function()
        computedRuns = computedRuns + 1
        Res3.epoch()
        return Res3.peek(50)
    end)
    local effSeen
    R.effect(function() effSeen = epochC() end)
    check("epoch-untrack: initial pending", effSeen == R.PENDING)
    local runsBefore = computedRuns
    store3[50] = "data"
    fire("EPOCH_UNTRACK_EVENT", 50) -- epoch bumps inside untrack; computed re-runs via its epoch dep
    check("epoch-untrack: resolved via epoch dep", effSeen == "data")
    check("epoch-untrack: computed ran exactly once on resolve", computedRuns == runsBefore + 1)
end

print(string.format("Reactor flush-chain: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
