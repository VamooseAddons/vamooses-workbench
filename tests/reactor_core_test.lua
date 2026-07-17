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

-- 7. effect-throw boundary: with a host handler set, one throwing effect must
--    not wedge the flush -- siblings run, flags reset, later writes flush ----
do
    local caught = 0
    R.setEffectErrorHandler(function(err) caught = caught + 1; return err end)
    local a = R.signal(1)
    local goodRuns = 0
    R.effect(function()
        if a() == 2 then error("deliberate effect throw") end
    end, "thrower")
    R.effect(function() a(); goodRuns = goodRuns + 1 end)
    check("boundary: initial runs clean", caught == 0 and goodRuns == 1)
    a(2)  -- thrower errors; sibling + engine must survive
    -- deterministic bug = initial report + ONE capped auto-retry, then quiet
    check("boundary: reported twice (initial + capped retry)", caught == 2)
    check("boundary: sibling effect still ran", goodRuns == 2)
    a(3)  -- the wedge test: a dead flush flag would swallow this write
    check("boundary: flush alive after throw", goodRuns == 3)
    check("boundary: no further reports once sources change", caught == 2)
    R.setEffectErrorHandler(nil)
end

-- 7b. capped retry heals a TRANSIENT error within the same write ------------
do
    local caught = 0
    R.setEffectErrorHandler(function(err) caught = caught + 1; return err end)
    local a = R.signal(1)
    local threwOnce, out = false, nil
    R.effect(function()
        local v = a()
        if v == 2 and not threwOnce then
            threwOnce = true
            error("transient")
        end
        out = v
    end, "transient")
    a(2)  -- first run throws; the auto-retry succeeds immediately
    check("retry: transient healed by auto-retry", out == 2)
    check("retry: one report for a healed transient", caught == 1)
    a(3)
    check("retry: effect fully relinked after heal", out == 3)
    R.setEffectErrorHandler(nil)
end

-- 8. no handler (headless default): effect throws propagate untouched -------
do
    local a = R.signal(1)
    R.effect(function()
        if a() == 2 then error("loud headless throw") end
    end)
    local ok, err = pcall(function() a(2) end)
    check("no-handler: throw propagates", not ok and tostring(err):find("loud headless throw") ~= nil)
end

print(string.format("Reactor core: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
