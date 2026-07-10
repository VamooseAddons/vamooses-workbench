-- Edge-case probes for Reactor. Each encodes a suspicion from the code review.
-- Run: lua reactor_edge_test.lua

local base = arg[0]:gsub("tests/reactor_edge_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. effect writes ANOTHER signal during its run -> chained effect updates,
--    and the writer's own tracking is not corrupted by the re-entrant flush.
do
    local a = R.signal(1)
    local mirror = R.signal(0)
    local aSeen, mirrorSeen
    R.effect(function() aSeen = a(); mirror(a() * 10) end) -- reads a, writes mirror
    R.effect(function() mirrorSeen = mirror() end)
    check("chain: initial", aSeen == 1 and mirrorSeen == 10)
    a(5)
    check("chain: writer re-ran", aSeen == 5)
    check("chain: downstream effect saw new value", mirrorSeen == 50)
    a(7) -- writer's dep on `a` must still be intact after the re-entrant flush
    check("chain: writer still reactive after re-entry", aSeen == 7 and mirrorSeen == 70)
end

-- 2. effect writes a signal it reads, SAME value each time -> equals stops it
do
    local a = R.signal(0)
    local runs = 0
    R.effect(function() runs = runs + 1; a(a()) end) -- write same value back
    check("self-write same value: settled", runs == 1)
    a(3)
    check("self-write same value: one re-run", runs == 2)
end

-- 3a. self-write (effect writes a signal it reads) does NOT loop: the coloring
--     absorbs it (a node mid-recompute is DIRTY, so its own write can't
--     re-schedule it). Settles, bounded runs. (Reviewed: safe by construction.)
do
    local a = R.signal(0)
    local runs = 0
    R.effect(function() runs = runs + 1; a(a() + 1) end)
    check("self-write settles (no loop)", runs == 1)
    a(5)
    check("self-write bounded on external trigger", runs == 2)
end

-- 3b. MUTUAL writes (A writes B's dep, B writes A's dep) DO loop -> the flush
--     cap must ERROR loudly (not hang), NAME the culprit effect, AND log it
--     durably before throwing.
do
    local logged = {}
    R.setLogger(function(level, msg) logged[#logged + 1] = { level = level, msg = msg } end)
    local x, y = R.signal(0), R.signal(100)
    local ok, err = pcall(function()
        R.effect(function() y(x() + 1) end, "A")
        R.effect(function() x(y() + 1) end, "B")
        x(5)
    end)
    check("mutual-write loop errors (no hang)", not ok)
    check("runaway error names the cause", type(err) == "string" and err:find("reactive loop", 1, true) ~= nil)
    check("runaway error names the effect label", err:find("'A'", 1, true) or err:find("'B'", 1, true))
    check("recursion cap logged before throw", #logged == 1 and logged[1].level == "error"
        and logged[1].msg:find("re%-ran"))
    R.setLogger(nil)
end

-- 4. nested batch coalesces to one flush at the outermost end
do
    local a, b = R.signal(1), R.signal(1)
    local runs, sum = 0
    R.effect(function() runs = runs + 1; sum = a() + b() end)
    R.batch(function()
        a(10)
        R.batch(function() b(20) end) -- inner batch must NOT flush early
        check("nested batch: no early flush", runs == 1)
        a(30)
    end)
    check("nested batch: one flush after outer", runs == 2 and sum == 50)
end

-- 5. signal holding nil; writing nil is a no-op; writing non-nil reacts
do
    local a = R.signal(nil)
    local runs, seen = 0
    R.effect(function() runs = runs + 1; seen = a() end)
    check("nil signal initial", seen == nil and runs == 1)
    a(nil)
    check("nil->nil is no-op", runs == 1)
    a(5)
    check("nil->value reacts", seen == 5 and runs == 2)
end

-- 6. computed returning a fresh table invalidates dependents each recompute
--    (default reference-equality) -- and a custom equals can suppress that.
do
    local src = R.signal(1)
    local listRuns = 0
    local list = R.computed(function() src(); return { "x" } end) -- new table each time
    R.effect(function() list(); listRuns = listRuns + 1 end)
    check("table computed: initial", listRuns == 1)
    src(2)
    check("table computed: re-runs on new table (ref-eq)", listRuns == 2)

    local shallowEq = function(a, b)
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
        for i = 1, #a do if a[i] ~= b[i] then return false end end
        return true
    end
    local src2 = R.signal(1)
    local runs2 = 0
    local stable = R.computed(function() src2(); return { "same" } end, shallowEq)
    R.effect(function() stable(); runs2 = runs2 + 1 end)
    src2(2) -- content identical -> shallowEq suppresses invalidation
    check("table computed: custom equals suppresses", runs2 == 1)
end

-- 7. deep chain does not stack-overflow (recursion depth sanity) ------------
do
    local a = R.signal(0)
    local prev = R.computed(function() return a() end)
    for _ = 1, 500 do
        local p = prev
        prev = R.computed(function() return p() + 1 end)
    end
    local out
    R.effect(function() out = prev() end)
    check("deep chain initial", out == 500)
    a(1)
    check("deep chain propagates", out == 501)
end

-- 8. disposing an effect mid-graph stops it; siblings keep working ----------
do
    local a = R.signal(0)
    local r1, r2 = 0, 0
    local d1 = R.effect(function() a(); r1 = r1 + 1 end)
    R.effect(function() a(); r2 = r2 + 1 end)
    a(1); check("both react", r1 == 2 and r2 == 2)
    d1()
    a(2); check("disposed effect dead, sibling alive", r1 == 2 and r2 == 3)
end

-- 9. purity: writing a signal inside a COMPUTED errors (TC39/Vue model).
--    Effects may write; computeds must be read-only. (Kept LAST: the error
--    leaves stale tracking context -- a known limitation, see review notes.)
do
    local a, b = R.signal(0), R.signal(0)
    local bad = R.computed(function() b(1); return a() end) -- writes b inside computed
    local ok, err = pcall(function() return bad() end)
    check("computed write errors", not ok)
    check("purity error names cause", type(err) == "string" and err:find("must be pure", 1, true) ~= nil)
end

print(string.format("Reactor edge: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
