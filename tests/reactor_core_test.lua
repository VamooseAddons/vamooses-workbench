-- Headless correctness tests for Reactor_Core. Run: lua reactor_core_test.lua
-- Proves the properties that a naive signal core gets wrong: glitch-free
-- (diamond), laziness, dynamic deps, scope disposal, batching.

local R = dofile((arg[0]:gsub("tests/reactor_core_test%.lua$", "") .. "Reactor/Reactor_Core.lua"))

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. basic: computed + effect react to a signal ----------------------------
do
    local a = R.signal(1)
    local double = R.computed(function() return a() * 2 end)
    local seen
    R.effect(function() seen = double() end)
    check("basic initial", seen == 2)
    a(5)
    check("basic update", seen == 10)
end

-- 2. GLITCH-FREE diamond: a -> (b, c) -> d. Set a. d must recompute ONCE
--    and never see a torn (inconsistent) intermediate. ---------------------
do
    local a = R.signal(1)
    local b = R.computed(function() return a() + 1 end)
    local c = R.computed(function() return a() * 2 end)
    local dRuns = 0
    local dVal
    local d = R.computed(function() dRuns = dRuns + 1; return b() + c() end)
    R.effect(function() dVal = d() end)
    check("diamond initial value", dVal == (2 + 2))   -- (1+1)+(1*2)=4
    local runsBefore = dRuns
    a(10)
    check("diamond updated value", dVal == (11 + 20)) -- (10+1)+(10*2)=31
    check("diamond recomputed once (no glitch)", (dRuns - runsBefore) == 1)
end

-- 3. laziness: an unread computed never recomputes --------------------------
do
    local a = R.signal(1)
    local runs = 0
    local squared = R.computed(function() runs = runs + 1; return a() * a() end)
    check("lazy: not computed until read", runs == 0)
    local _ = squared()
    check("lazy: computed on first read", runs == 1)
    a(2); a(3); a(4)              -- nobody read it between sets
    check("lazy: not recomputed while unread", runs == 1)
    check("lazy: recomputes on next read", squared() == 16 and runs == 2)
end

-- 4. dynamic deps: reading a OR b by a flag; changing the unused one is inert
do
    local flag = R.signal(true)
    local a = R.signal("A")
    local b = R.signal("B")
    local eff = 0
    local out
    R.effect(function() eff = eff + 1; out = flag() and a() or b() end)
    check("dyn initial", out == "A" and eff == 1)
    b("B2")                      -- b not a dep while flag=true
    check("dyn: unused dep inert", eff == 1)
    flag(false)                  -- now depends on b
    check("dyn: switched dep", out == "B2")
    a("A2")                      -- a no longer a dep
    check("dyn: old dep inert after switch", out == "B2")
end

-- 5. scope disposal: effects in a scope stop after dispose ------------------
do
    local a = R.signal(0)
    local runs = 0
    local s = R.scope(function()
        R.effect(function() a(); runs = runs + 1 end)
    end)
    check("scope: effect ran once", runs == 1)
    a(1)
    check("scope: effect reacts before dispose", runs == 2)
    R.dispose(s)
    a(2); a(3)
    check("scope: effect dead after dispose", runs == 2)
end

-- 5b. cleanup fn runs on re-run and on dispose ------------------------------
do
    local a = R.signal(0)
    local cleanups = 0
    local s = R.scope(function()
        R.effect(function() a(); return function() cleanups = cleanups + 1 end end)
    end)
    a(1)                         -- re-run should clean up the previous
    check("cleanup on re-run", cleanups == 1)
    R.dispose(s)
    check("cleanup on dispose", cleanups == 2)
end

-- 6. batch: many writes -> one effect run -----------------------------------
do
    local a = R.signal(1)
    local b = R.signal(1)
    local runs = 0
    local sum
    R.effect(function() runs = runs + 1; sum = a() + b() end)
    check("batch: initial run", runs == 1)
    R.batch(function() a(10); b(20); a(30) end)
    check("batch: coalesced to one run", runs == 2)
    check("batch: final value correct", sum == 50)
end

print(string.format("Reactor core: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
