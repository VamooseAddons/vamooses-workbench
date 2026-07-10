-- Reactor graph-correctness tests -- ported SCENARIOS (not code) from the two
-- suites by the algorithm's own author, Milo Mighdoll:
--   * reactively  packages/test/src/Dynamic.test.ts   (dynamic-dependency cases)
--   * js-reactivity-benchmark  kairo/{avoidable,deep,broad,mux,repeated}
-- Each asserts an exact recompute COUNT -- the language-agnostic core of what a
-- clean/check/dirty signals engine must guarantee (glitch-free + minimal work).
-- These pin down laziness the 3-node diamond in reactor_core_test can't.
-- Run: lua reactor_graph_test.lua
local R = dofile((arg[0]:gsub("tests/reactor_graph_test%.lua$", "") .. "Reactor/Reactor_Core.lua"))

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. dynamic short-circuit: c = a or b. Once a is truthy, b is no longer a dep,
--    so writing b must not re-run c. (reactively "dynamic sources recalculate") -
do
    local a = R.signal(false)
    local b = R.signal(2)
    local count = 0
    local c = R.computed(function() count = count + 1; return a() or b() end)
    c()
    check("shortcircuit: initial compute", count == 1)
    a(true); c()
    check("shortcircuit: recompute on a", count == 2)
    b(4); c()
    check("shortcircuit: dropped branch inert", count == 2)
end

-- 2. THE laziness case: b is dirty (its source s changed) but l did not read it
--    this cycle, so b must NOT recompute. (reactively "don't re-execute a parent
--    unnecessarily" -- the strongest validation of the check/dirty coloring.) ---
do
    local s = R.signal(2)
    local a = R.computed(function() return s() + 1 end)
    local bCount = 0
    local b = R.computed(function() bCount = bCount + 1; return s() + 10 end)
    local l = R.computed(function()
        local result = a()
        if result % 2 == 1 then result = result + b() end -- read b only when a is odd
        return result
    end)
    check("unneeded-parent: initial l", l() == 15)      -- a=3 (odd) -> 3 + b(12)
    check("unneeded-parent: b computed once", bCount == 1)
    s(3)
    check("unneeded-parent: l updates", l() == 4)       -- a=4 (even) -> no b
    check("unneeded-parent: dirty-but-unneeded b NOT recomputed", bCount == 1)
end

-- 3. dependency disappears entirely: once c stops reading s, no s write ever
--    re-runs c again. (reactively "dynamic source disappears entirely") --------
do
    local s = R.signal(1)
    local done = false
    local count = 0
    local c = R.computed(function()
        count = count + 1
        if done then return 0 end
        local v = s()
        if v > 2 then done = true end
        return v
    end)
    check("disappearing: initial", c() == 1 and count == 1)
    s(3)
    check("disappearing: crossed threshold (s still a dep this run)", c() == 3 and count == 2)
    s(1)
    check("disappearing: locked done, drops s", c() == 0 and count == 3)
    s(0)
    check("disappearing: link severed -- never runs again", c() == 0 and count == 3)
end

-- 4. avoidable propagation: a computed that returns a STABLE value (0) cuts the
--    whole downstream chain via the equality check, so the tail effect never
--    re-runs however much head changes. (kairo avoidable) ----------------------
do
    local head = R.signal(0)
    local c1 = R.computed(function() return head() end)
    local c2 = R.computed(function() c1(); return 0 end) -- always 0
    local c3 = R.computed(function() return c2() + 1 end)
    local c4 = R.computed(function() return c3() + 2 end)
    local c5 = R.computed(function() return c4() + 3 end)
    local effRuns = 0
    R.effect(function() effRuns = effRuns + 1; c5() end)
    check("avoidable: initial c5", c5() == 6)
    check("avoidable: effect ran once", effRuns == 1)
    for i = 1, 5 do head(i) end
    check("avoidable: c5 stable", c5() == 6)
    check("avoidable: effect NOT re-run (stable c2 cut the chain)", effRuns == 1)
end

-- 5. single-hop equality: a memoized value that doesn't change must not re-run a
--    dependent effect. (complements avoidable at one hop) ----------------------
do
    local a = R.signal(1)
    local parity = R.computed(function() return a() % 2 end)
    local effRuns = 0
    R.effect(function() effRuns = effRuns + 1; parity() end)
    check("equality-effect: initial", effRuns == 1)
    a(3) -- 3%2 == 1 == old parity
    check("equality-effect: no re-run when derived value unchanged", effRuns == 1)
    a(2) -- 2%2 == 0, changed
    check("equality-effect: re-run when derived value changes", effRuns == 2)
end

-- 6. deep chain: a -> n1 -> ... -> nN. One write must recompute each node EXACTLY
--    once (no node recomputes twice; no node is skipped). (kairo deep) ----------
do
    local a = R.signal(1)
    local N = 20
    local nodes, runs = { a }, {}
    for i = 1, N do
        local prev, idx = nodes[i], i
        runs[idx] = 0
        nodes[i + 1] = R.computed(function() runs[idx] = runs[idx] + 1; return prev() + 1 end)
    end
    local tail = nodes[N + 1]
    check("deep: initial value", tail() == 1 + N)
    for i = 1, N do runs[i] = 0 end
    a(2)
    check("deep: propagated value", tail() == 2 + N)
    local total = 0
    for i = 1, N do total = total + runs[i] end
    check("deep: each node recomputed exactly once", total == N)
end

-- 7. broad fan-out: W computeds share ONE source; a sink reads all W. A source
--    write must recompute the sink ONCE, not W times (glitch-free at width).
--    (kairo broad) -------------------------------------------------------------
do
    local a = R.signal(1)
    local W = 10
    local mids = {}
    for i = 1, W do local k = i; mids[i] = R.computed(function() return a() + k end) end
    local sinkRuns = 0
    local sink = R.computed(function()
        sinkRuns = sinkRuns + 1
        local s = 0
        for i = 1, W do s = s + mids[i]() end
        return s
    end)
    local expect1 = W * 1 + (W * (W + 1)) / 2 -- sum(a + i) = W*a + sum(1..W)
    check("broad: initial value", sink() == expect1)
    local before = sinkRuns
    a(5); sink()
    check("broad: sink recomputed ONCE despite W shared-source parents", sinkRuns - before == 1)
    check("broad: value correct", sink() == W * 5 + (W * (W + 1)) / 2)
end

-- 8. mux: select one of N inputs by an index signal; writing an unselected input
--    is inert, and after switching the previously-selected one goes inert.
--    (kairo mux / reactively dynamic at N) -------------------------------------
do
    local sel = R.signal(1)
    local inputs = { R.signal("a"), R.signal("b"), R.signal("c") }
    local runs = 0
    local out = R.computed(function() runs = runs + 1; return inputs[sel()]() end)
    check("mux: initial selects input 1", out() == "a" and runs == 1)
    inputs[2]("b2")
    check("mux: unselected input inert", out() == "a" and runs == 1)
    sel(2)
    check("mux: switched selection", out() == "b2" and runs == 2)
    inputs[1]("a2")
    check("mux: previously-selected input now inert", out() == "b2" and runs == 2)
end

-- 9. repeated reads of the same source in one computed = ONE dep, ONE recompute
--    per change (link dedup). (kairo repeated) --------------------------------
do
    local a = R.signal(1)
    local runs = 0
    local c = R.computed(function() runs = runs + 1; return a() + a() + a() end)
    check("repeated: initial", c() == 3 and runs == 1)
    a(2)
    check("repeated: one recompute despite 3 reads", c() == 6 and runs == 2)
end

-- 10. untrack: a read inside untrack() creates NO dependency, so that source is
--     inert; tracked sources still drive recompute. ---------------------------
do
    local a = R.signal(1)
    local b = R.signal(10)
    local runs = 0
    local c = R.computed(function() runs = runs + 1; return a() + R.untrack(function() return b() end) end)
    check("untrack: initial", c() == 11 and runs == 1)
    b(20)
    check("untrack: untracked source inert", c() == 11 and runs == 1)
    a(2)
    check("untrack: tracked source reactive, reads live untracked value", c() == 22 and runs == 2)
end

print(string.format("Reactor graph: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
