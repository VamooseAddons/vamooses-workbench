-- Headless tests for Reactor.latchMap (Constitution R3's engine half).
-- Run: lua tests/reactor_latch_test.lua
-- Proves the latch-forward contract: equal-value latches produce ZERO
-- propagation (no per-key run, no epoch bump); changed values propagate to
-- fine-grained readers and aggregate epoch subscribers exactly once.

local base = arg[0]:gsub("tests/reactor_latch_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", { Reactor = R })

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. epoch bumps on first latch, NOT on equal re-latch -----------------------
do
    local m = R.latchMap("t1")
    local runs = 0
    R.effect(function() m.epoch(); runs = runs + 1 end)
    check("effect ran once at creation", runs == 1)
    check("latch reports change", m:latch(10, "alpha") == true)
    check("epoch propagated the change", runs == 2)
    check("equal re-latch reports no change", m:latch(10, "alpha") == false)
    check("equal re-latch did NOT propagate", runs == 2)
    check("changed value propagates again", m:latch(10, "beta") == true and runs == 3)
end

-- 2. false is a real latched value, distinct from never-latched --------------
do
    local m = R.latchMap("t2")
    check("hasKey false before latch", m:hasKey(7) == false)
    m:latch(7, false)
    check("hasKey true after latching false", m:hasKey(7) == true)
    check("peek returns the false", m:peek(7) == false)
    check("re-latching false dedups", m:latch(7, false) == false)
end

-- 3. fine-grained get(key): only the touched key's readers re-run ------------
do
    local m = R.latchMap("t3")
    m:latch("a", 1); m:latch("b", 1)
    local aRuns, bRuns = 0, 0
    R.effect(function() m:get("a"); aRuns = aRuns + 1 end)
    R.effect(function() m:get("b"); bRuns = bRuns + 1 end)
    m:latch("a", 2)
    check("reader of a re-ran", aRuns == 2)
    check("reader of b did not", bRuns == 1)
    m:latch("b", 1) -- equal
    check("equal latch on b did not re-run its reader", bRuns == 1)
end

-- 4. get(key) before any latch reads nil, then resolves on latch -------------
do
    local m = R.latchMap("t4")
    local seen
    R.effect(function() seen = m:get(99) end)
    check("pre-latch read is nil", seen == nil)
    m:latch(99, "resolved")
    check("post-latch read sees the value", seen == "resolved")
end

-- 5. aggregate walker pattern: epoch edge + peek reads (one edge total) ------
do
    local m = R.latchMap("t5")
    for i = 1, 5 do m:latch(i, 0) end
    local walks, total = 0, 0
    R.effect(function()
        m.epoch()
        walks = walks + 1
        total = 0
        for i = 1, 5 do total = total + (m:peek(i) or 0) end
    end)
    check("walker ran once", walks == 1 and total == 0)
    m:latch(3, 10)
    check("walker re-ran on real change", walks == 2 and total == 10)
    m:latch(3, 10)
    check("walker silent on no-op latch", walks == 2)
end

-- 6. scaffolding forceBump still propagates (until migration step 5) ---------
do
    local m = R.latchMap("t6")
    local runs = 0
    R.effect(function() m.epoch(); runs = runs + 1 end)
    m:forceBump()
    check("forceBump propagates (scaffolding)", runs == 2)
end

print(string.format("Reactor latch: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
