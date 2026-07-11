-- Headless tests for the bind helpers, using mock frames that record calls.
-- Covers the ADOPTED surface only (bindText / bindShown / bindColor) and pins
-- the 2026-07-11 hygiene deletions (bindTexture, bindCall export, bindList)
-- as contract, mirroring reactor_resource_ext_test.lua's invalidateAll pin.

local base = arg[0]:gsub("tests/reactor_bind_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", { Reactor = R })
loadfile(base .. "Reactor/Reactor_Bind.lua")("VWB", { Reactor = R })

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Mock frame: records the last value set + call counts -----------------------
local function mockFrame()
    local f = { _text = nil, _shown = nil, _color = nil, _setTextCalls = 0 }
    function f:SetText(v) self._text = v; self._setTextCalls = self._setTextCalls + 1 end
    function f:SetShown(v) self._shown = v end
    function f:SetTextColor(r, g, b, a) self._color = { r, g, b, a } end
    return f
end

-- 1. bindText / bindShown react ---------------------------------------------
do
    local name = R.signal("Copper")
    local fs = mockFrame()
    R.bindText(fs, function() return name() end)
    check("bindText initial", fs._text == "Copper")
    name("Thorium")
    check("bindText updates", fs._text == "Thorium")

    local vis = R.signal(true)
    local row = mockFrame()
    R.bindShown(row, function() return vis() end)
    check("bindShown initial", row._shown == true)
    vis(false)
    check("bindShown updates", row._shown == false)
end

-- 2. bindColor passes the full tuple through --------------------------------
do
    local hot = R.signal(false)
    local fs = mockFrame()
    R.bindColor(fs, function()
        if hot() then return 1, 0, 0, 1 end
        return 0.5, 0.5, 0.5, 1
    end)
    check("bindColor initial tuple", fs._color[1] == 0.5 and fs._color[2] == 0.5 and fs._color[4] == 1)
    hot(true)
    check("bindColor updates tuple", fs._color[1] == 1 and fs._color[2] == 0 and fs._color[3] == 0)
end

-- 3. FINE-GRAINED: a resource resolving repaints ONE bound cell -------------
do
    -- mock item-name resource
    local handlers, store = {}, {}
    R.setEventSource(function(ev, h) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], h); return function() end end)
    local function fire(ev, ...) for _, h in ipairs(handlers[ev] or {}) do h(...) end end
    local ItemName = R.resource({
        read = function(id) return store[id] end,
        request = function() end, -- request sink; this test only cares about resolution fan-out
        event = "ITEM_LOADED",
        matches = function(k, id) return k == id end,
    })

    local frames = {} -- id -> its cell frame, each bound to the resource for THAT id
    for id = 1, 3 do
        local f = mockFrame()
        frames[id] = f
        R.bindText(f, function()
            local v = ItemName(id)
            return v == R.PENDING and "..." or v
        end)
    end

    check("all cells start pending", frames[1]._text == "..." and frames[2]._text == "..." and frames[3]._text == "...")
    local otherCallsBefore = frames[2]._setTextCalls + frames[3]._setTextCalls

    store[1] = "Iron Ore"
    fire("ITEM_LOADED", 1)                  -- resolve ONLY item 1

    check("resolved cell updated", frames[1]._text == "Iron Ore")
    check("other cells untouched", (frames[2]._setTextCalls + frames[3]._setTextCalls) == otherCallsBefore)
    check("other cells still pending", frames[2]._text == "..." and frames[3]._text == "...")
end

-- 4. scope disposal tears down binds -----------------------------------------
do
    local a = R.signal("x")
    local fs = mockFrame()
    local s = R.scope(function()
        R.bindText(fs, function() return a() end)
    end)
    check("bound before dispose", fs._text == "x")
    a("y")
    check("reacts before dispose", fs._text == "y")
    R.dispose(s)
    a("z")
    check("dead after scope dispose", fs._text == "y")
end

-- 5. hygiene pins: the deleted surface stays deleted --------------------------
do
    check("bindTexture is gone", R.bindTexture == nil)
    check("bindCall export is gone", R.bindCall == nil)
    check("bindList is gone", R.bindList == nil)
    check("BIND_VERSION bumped to 2", R.BIND_VERSION == 2)
end

print(string.format("Reactor bind: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
