-- Headless tests for the bind helpers, using mock frames that record calls.
-- Proves fine-grained binding: a bound cell updates itself; and a resource
-- resolving repaints ONE row's cell, not the whole list (no rebuild).

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
    local f = { _text = nil, _shown = nil, _pt = nil, _setTextCalls = 0, _hidden = 0 }
    function f:SetText(v) self._text = v; self._setTextCalls = self._setTextCalls + 1 end
    function f:SetShown(v) self._shown = v end
    function f:SetPoint(i) self._pt = i end
    function f:Hide() self._hidden = self._hidden + 1 end
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

-- 2. bindList structure: add / remove / pool reuse --------------------------
do
    local items = R.signal({ {k="a"}, {k="b"}, {k="c"} })
    local created, positioned = 0, {}
    R.bindList(function() return items() end, {
        key = function(it) return it.k end,
        create = function() created = created + 1; return mockFrame() end,
        setup = function() end,
        position = function(frame, i) frame:SetPoint(i) end,
        release = function(frame) frame:Hide() end,
    })
    check("list: created 3 rows", created == 3)
    items({ {k="a"}, {k="c"} })            -- remove b
    check("list: no new rows on removal", created == 3)
    items({ {k="a"}, {k="c"}, {k="d"} })   -- add d -> should reuse b's pooled frame
    check("list: pooled frame reused (no create)", created == 3)
end

-- 3. FINE-GRAINED: a resource resolving repaints ONE row cell, not the list --
do
    -- mock item-name resource
    local handlers, store, req = {}, {}, {}
    R.setEventSource(function(ev, h) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], h); return function() end end)
    local function fire(ev, ...) for _, h in ipairs(handlers[ev] or {}) do h(...) end end
    local ItemName = R.resource({
        read = function(id) return store[id] end,
        request = function(id) req[id] = true end,
        event = "ITEM_LOADED",
        matches = function(k, id) return k == id end,
    })

    local items = R.signal({ {k=1, id=1}, {k=2, id=2}, {k=3, id=3} })
    local rowCreates = 0
    local frames = {}                       -- id -> its cell frame
    local listReconciles = 0
    R.bindList(function() listReconciles = listReconciles + 1; return items() end, {
        key = function(it) return it.k end,
        create = function() rowCreates = rowCreates + 1; return mockFrame() end,
        setup = function(frame, item)
            frames[item.id] = frame
            -- per-row cell bound to the resource for THIS item
            R.bindText(frame, function()
                local v = ItemName(item.id)
                return v == R.PENDING and "..." or v
            end)
        end,
        position = function(frame, i) frame:SetPoint(i) end,
    })

    check("all rows start pending", frames[1]._text == "..." and frames[2]._text == "..." and frames[3]._text == "...")
    local createsBefore = rowCreates
    local reconcilesBefore = listReconciles
    local otherCallsBefore = frames[2]._setTextCalls + frames[3]._setTextCalls

    store[1] = "Iron Ore"
    fire("ITEM_LOADED", 1)                  -- resolve ONLY item 1

    check("resolved row updated", frames[1]._text == "Iron Ore")
    check("list did NOT reconcile", listReconciles == reconcilesBefore)
    check("no rows re-created", rowCreates == createsBefore)
    check("other rows' cells untouched", (frames[2]._setTextCalls + frames[3]._setTextCalls) == otherCallsBefore)
    check("other rows still pending", frames[2]._text == "..." and frames[3]._text == "...")
end

-- 4. scope disposal tears down list + row binds -----------------------------
do
    local handlers = {}
    R.setEventSource(function(ev, h) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], h); return function() end end)
    local a = R.signal("x")
    local frame
    local s = R.scope(function()
        R.bindList(function() return { {k="only"} } end, {
            key = function(it) return it.k end,
            create = function() frame = mockFrame(); return frame end,
            setup = function(f) R.bindText(f, function() return a() end) end,
            position = function() end,
        })
    end)
    check("row bound before dispose", frame._text == "x")
    a("y")
    check("row reacts before dispose", frame._text == "y")
    R.dispose(s)
    a("z")
    check("row dead after scope dispose", frame._text == "y")
end

print(string.format("Reactor bind: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
