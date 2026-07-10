-- Headless tests for the resource primitive. Run: lua reactor_resource_test.lua
-- Proves the async unlock: an effect reading a PENDING resource auto-updates
-- when the (mock) event fires -- no manual load/refresh wiring.

local base = arg[0]:gsub("tests/reactor_resource_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", { Reactor = R })

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Mock event source ---------------------------------------------------------
local handlers = {}
R.setEventSource(function(event, h)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], h)
    return function() end
end)
local function fire(event, ...)
    for _, h in ipairs(handlers[event] or {}) do h(...) end
end

-- Mock async "item cache": nil until "loaded" -------------------------------
local store = {}          -- id -> name
local requests = {}       -- id -> count
local ItemName = R.resource({
    read    = function(id) return store[id] end,
    request = function(id) requests[id] = (requests[id] or 0) + 1 end,
    event   = "ITEM_LOADED",
    matches = function(key, evId) return key == evId end,
})

-- 1. pending -> resolved, effect auto-updates (THE unlock) ------------------
do
    local seen
    R.effect(function() seen = ItemName(42) end)
    check("starts pending", seen == R.PENDING)
    check("requested once", requests[42] == 1)
    store[42] = "Thorium Bar"
    fire("ITEM_LOADED", 42)             -- data arrives
    check("auto-updates on event (no manual refresh)", seen == "Thorium Bar")
end

-- 2. request-once: re-reading a pending key does not re-request -------------
do
    local a, b
    R.effect(function() a = ItemName(99) end)
    R.effect(function() b = ItemName(99) end) -- second reader, same key
    check("second reader also pending", a == R.PENDING and b == R.PENDING)
    check("still requested once total", requests[99] == 1)
    store[99] = "Arcane Crystal"
    fire("ITEM_LOADED", 99)
    check("both readers updated", a == "Arcane Crystal" and b == "Arcane Crystal")
end

-- 3. already-loaded key resolves immediately, no request -------------------
do
    store[7] = "Copper Bar"
    local seen
    R.effect(function() seen = ItemName(7) end)
    check("ready immediately", seen == "Copper Bar")
    check("no request for ready key", requests[7] == nil)
end

-- 4. coalesce: one event resolving 2 keys -> effects run, values correct ---
do
    local runs, x, y = 0
    R.effect(function() runs = runs + 1; x = ItemName(100); y = ItemName(101) end)
    check("both pending", x == R.PENDING and y == R.PENDING)
    local runsBefore = runs
    store[100] = "Fel Iron"; store[101] = "Adamantite"
    fire("ITEM_LOADED", 100)            -- resolves key 100 only (matches by id)
    check("partial resolve updates", x == "Fel Iron" and y == R.PENDING)
    fire("ITEM_LOADED", 101)
    check("second resolve completes", x == "Fel Iron" and y == "Adamantite")
end

-- 5. downstream computed over a resource stays reactive --------------------
do
    local upper = R.computed(function()
        local v = ItemName(200)
        return v == R.PENDING and "..." or v:upper()
    end)
    local out
    R.effect(function() out = upper() end)
    check("computed shows loading", out == "...")
    store[200] = "mithril"
    fire("ITEM_LOADED", 200)
    check("computed reacts through resource", out == "MITHRIL")
end

-- 6. peek() is untracked; epoch() is the single shared dependency -----------
--    This is the mass-item-resolution fix: a big loop peeks N keys but takes
--    ONE dependency (epoch), not N.
do
    local peekRuns, peekVal = 0, nil
    R.effect(function() peekRuns = peekRuns + 1; peekVal = ItemName.peek(300) end)
    check("peek: starts pending + requested", peekVal == R.PENDING and requests[300] == 1)
    store[300] = "Truesilver"
    fire("ITEM_LOADED", 300)             -- resolves 300, but the peeker took no edge
    check("peek does NOT track (effect did not re-run)", peekRuns == 1 and peekVal == R.PENDING)

    local epochRuns, epochVal = 0, nil
    R.effect(function() epochRuns = epochRuns + 1; ItemName.epoch(); epochVal = ItemName.peek(301) end)
    check("epoch: starts pending", epochRuns == 1 and epochVal == R.PENDING)
    store[301] = "Star Ruby"
    fire("ITEM_LOADED", 301)             -- resolves 301 -> one epoch bump
    check("epoch wakes the peeker; peek now latched", epochRuns == 2 and epochVal == "Star Ruby")
end

-- 7. keyOf: O(1) direct-key resolution (the item-cache fast path). The event
--    names exactly one key, so no per-event scan of all pending keys.
do
    local kstore = {}
    local Fast = R.resource({
        read    = function(id) return kstore[id] end,
        request = function() end,
        event   = "FAST_LOADED",
        keyOf   = function(id) return id end,
    })
    local a, b
    R.effect(function() Fast.epoch(); a = Fast.peek(1); b = Fast.peek(2) end)
    check("keyOf: both pending", a == R.PENDING and b == R.PENDING)
    kstore[1] = "one"
    fire("FAST_LOADED", 1)               -- resolves ONLY key 1
    check("keyOf: key 1 resolved via epoch", a == "one" and b == R.PENDING)
    fire("FAST_LOADED", 999)             -- unknown key -> no-op (not in perKey)
    check("keyOf: unknown key is a no-op", a == "one" and b == R.PENDING)
    kstore[2] = "two"
    fire("FAST_LOADED", 2)
    check("keyOf: key 2 resolved", a == "one" and b == "two")
end

print(string.format("Reactor resource: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
