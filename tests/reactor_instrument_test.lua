-- Instrumentation seams for the debug/profiler (added 2026-07-07):
-- setInstrument (per-recompute wrap) + setFlushObserver (per-flush bracket).
-- Run: lua reactor_instrument_test.lua

local base = arg[0]:gsub("tests/reactor_instrument_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. setInstrument wraps every recompute; the thunk result must flow through,
--    and node kind/label are visible to the host.
do
    local seen = {}
    R.setInstrument(function(node, thunk)
        seen[#seen + 1] = { kind = node.kind, label = node.label }
        return thunk()
    end)
    local a = R.signal(1)
    local c = R.computed(function() return a() * 2 end, nil, "double")
    local out
    R.effect(function() out = c() end, "sink")
    check("instrument: effect ran (thunk result flows)", out == 2)

    local sawComputed, sawEffect = false, false
    for _, s in ipairs(seen) do
        if s.kind == "computed" and s.label == "double" then sawComputed = true end
        if s.kind == "effect" and s.label == "sink" then sawEffect = true end
    end
    check("instrument: saw labeled computed", sawComputed)
    check("instrument: saw labeled effect", sawEffect)

    local before = #seen
    a(5)
    check("instrument: re-fired on dependency change", #seen > before and out == 10)

    R.setInstrument(nil)
    local afterOff = #seen
    a(6)
    check("instrument: off = no more samples, graph still live", #seen == afterOff and out == 12)
end

-- 2. setFlushObserver brackets each flush and reports the effect count.
do
    local flushes = {}
    R.setFlushObserver(function()
        return function(count) flushes[#flushes + 1] = count end
    end)
    local s = R.signal(0)
    R.effect(function() local _ = s() end, "e1")
    R.effect(function() local _ = s() end, "e2")
    check("flushObserver: creation is not a flush", #flushes == 0)

    s(1) -- dirties both effects -> one flush that runs 2 effects
    check("flushObserver: one flush", #flushes == 1)
    check("flushObserver: counted both effects", flushes[1] == 2)

    R.setFlushObserver(nil)
    s(2)
    check("flushObserver: off = no more brackets", #flushes == 1)
end

print(string.format("Reactor instrument: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
