-- Headless test for Reactor_WoW glue using MOCK frames: proves the one-shot
-- scheduler coalesces writes into a single deferred flush, and the event bridge
-- registers/dispatches WoW events into resources. No real client needed.
-- Run: lua reactor_wow_test.lua
local base = arg[0]:gsub("tests/reactor_wow_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
local ns = { Reactor = R }
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", ns)
loadfile(base .. "Reactor/Reactor_WoW.lua")("VWB", ns)

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Minimal mock of the WoW frame surface Reactor_WoW touches.
local function mockFrame()
    local f = { _shown = false, _events = {}, _scripts = {} }
    function f:Hide() self._shown = false end
    function f:Show() self._shown = true end
    function f:SetScript(k, fn) self._scripts[k] = fn end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:UnregisterEvent(e) self._events[e] = nil end
    return f
end

local created = {}
ns.ReactorWoW.install({ createFrame = function() local m = mockFrame(); created[#created + 1] = m; return m end })
local driver, eventFrame = created[1], created[2]
local function tick() if driver._scripts.OnUpdate then driver._scripts.OnUpdate(driver) end end

-- 1. deferred + coalesced flush ---------------------------------------------
do
    local s = R.signal(0)
    local runs = 0
    R.effect(function() s(); runs = runs + 1 end) -- runs once synchronously
    check("effect ran once on create", runs == 1)
    s(1); s(2); s(3) -- three writes, one frame
    check("flush deferred (not run yet)", runs == 1)
    check("driver armed for next frame", driver._shown == true)
    tick()
    check("one coalesced flush ran", runs == 2)
    check("driver hid itself after the tick", driver._shown == false)
end

-- 2. event bridge resolves a resource ---------------------------------------
do
    local storeVal = nil
    local res = R.resource({
        read = function(k) return storeVal end,
        event = "VWB_TEST_EVENT",
        matches = function(k, id) return k == id end,
    })
    local got
    R.effect(function() got = res("a") end)
    check("resource read subscribed the WoW event", eventFrame._events["VWB_TEST_EVENT"] == true)
    check("resource pending before event", R.isPending(got))
    -- fire the event through the shared OnEvent handler
    storeVal = 42
    eventFrame._scripts.OnEvent(eventFrame, "VWB_TEST_EVENT", "a")
    check("event armed a flush", driver._shown == true)
    tick()
    check("resource resolved after event + flush", got == 42)
end

print(string.format("Reactor WoW: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
