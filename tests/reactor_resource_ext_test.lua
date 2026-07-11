-- Extended resource tests. HISTORY: this suite covered invalidateAll(filter)
-- + its scalar-contract assert. invalidateAll was DELETED in the Constitution
-- migration (step 4, 2026-07-11) -- its semantic (lazy re-read of stored
-- per-key state on a bulk event) is the latch-at-boundary violation behind
-- the request loops. Domains latch forward now: scoped events reconcile one
-- key (Reactor.latchMap, covered in reactor_latch_test.lua); bulk events
-- sweep-and-re-latch eagerly at the boundary. This suite now pins the
-- DELETION as a contract plus the surviving resource surface.
-- Run: lua tests/reactor_resource_ext_test.lua

local base = arg[0]:gsub("tests/reactor_resource_ext_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", { Reactor = R })

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. the deletion IS the contract ---------------------------------------------
do
    local Res = R.resource({ read = function() return "x" end })
    check("invalidateAll is gone", Res.invalidateAll == nil)
end

-- 2. surviving surface: __call get / peek / epoch ------------------------------
do
    local db = { a = "v1" }
    local Res = R.resource({ read = function(k) return db[k] end })
    local va
    R.effect(function() va = Res("a") end)
    check("callable get resolves", va == "v1")
    check("peek reads the latched value", Res.peek("a") == "v1")
    check("epoch is readable", type(Res.epoch()) == "number")
end

-- 3. the replacement pattern: boundary re-latch through latchMap --------------
-- (what a bulk-event sweep does now: derive at the boundary, latch forward,
-- equality silences the unchanged majority.)
do
    local m = R.latchMap("ext-replacement")
    m:latch("a", false); m:latch("b", false); m:latch("c", false)
    local walks = 0
    R.effect(function() m.epoch(); walks = walks + 1 end)
    local before = walks
    -- bulk sweep where only "b" actually changed:
    for _, k in ipairs({ "a", "b", "c" }) do
        m:latch(k, k == "b")
    end
    check("sweep with one real change propagated once", walks == before + 1)
    check("changed key reads new value", m:peek("b") == true)
    check("unchanged keys silent + intact", m:peek("a") == false and m:peek("c") == false)
end

print(string.format("Reactor resource-ext: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
