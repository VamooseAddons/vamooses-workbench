-- Verifies Layout.build's APPLY walk with mock frames: every node gets a frame,
-- byId is populated, rect nodes get TOPLEFT SetPoint + SetSize, sibling-anchor
-- nodes SetPoint to the sibling's frame, and role-default ellipsis calls
-- SetWordWrap(false). Exercises the REAL Showroom config. Run: lua layout_build_test.lua
local base = arg[0]:gsub("tests/layout_build_test%.lua$", "")
local Layout = dofile(base .. "Layout/Layout.lua")
local LC = dofile(base .. "Layout/LayoutConfig_Showroom.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Mock frame recording the calls applyTree/applyOverflow make.
local function mockFrame()
    local f = { points = {}, wordWrap = nil, size = nil }
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(p, rel, rp, x, y) self.points[#self.points + 1] = { p = p, rel = rel, rp = rp, x = x, y = y } end
    function f:SetSize(w, h) self.size = { w = w, h = h } end
    function f:SetWordWrap(v) self.wordWrap = v end
    function f:SetMaxLines(n) self.maxLines = n end
    function f:SetClipsChildren(v) self.clips = v end
    return f
end

local container = { GetWidth = function() return 1000 end, GetHeight = function() return 600 end }
local made = {}
local handle = Layout.build(container, LC.showroom, {
    makeFrame = function(node) local m = mockFrame(); made[#made + 1] = m; return m end,
    measure = function() return { w = 80, h = 12 } end,
})

-- 1. byId covers the whole config (containers with ids + all items) ----------
do
    local want = { "profbar", "navCol", "navTree", "listCol", "search", "typeToggle",
        "missingPill", "breadcrumb", "list", "stageCol", "modelArea", "modelDress",
        "modelCreature", "modelScene", "controlsHint", "detailsPanel", "itemName",
        "itemDetails", "startProject", "addToQueue" }
    local missing = {}
    for _, id in ipairs(want) do if not handle.byId[id] then missing[#missing + 1] = id end end
    check("byId has every id (" .. #want .. ")", #missing == 0)
    if #missing > 0 then print("     missing: " .. table.concat(missing, ", ")) end
end

-- 2. a rect node (profbar) is TOPLEFT-anchored to its parent + sized ----------
do
    local pf = handle.byId["profbar"]
    check("profbar sized", pf.size ~= nil and pf.size.w > 900)
    check("profbar TOPLEFT-anchored", #pf.points == 1 and pf.points[1].p == "TOPLEFT")
end

-- 3. sibling-anchor BUILD mechanism (own fixture -- the live Showroom config
-- no longer uses `anchor` after the 2026-07-11 details-panel restack, and a
-- feature test must not couple to app config shape) --------------------------
do
    local made2 = {}
    local h2 = Layout.build(container, {
        type = "free", id = "fixRoot", size = { h = 60 }, children = {
            { type = "item", id = "fixA", size = { w = 100, h = 16 }, place = { h = "left", v = "top" } },
            { type = "item", id = "fixB", anchor = { to = "fixA", from = "TOPLEFT", at = "BOTTOMLEFT", dy = -5 } },
        },
    }, {
        makeFrame = function() local m = mockFrame(); made2[#made2 + 1] = m; return m end,
        measure = function() return { w = 80, h = 12 } end,
    })
    local b, a = h2.byId["fixB"], h2.byId["fixA"]
    check("anchor node anchored once", #b.points == 1)
    check("anchor node SetPoints to the sibling frame", b.points[1].rel == a)
    check("anchor from/at TOPLEFT->BOTTOMLEFT", b.points[1].p == "TOPLEFT" and b.points[1].rp == "BOTTOMLEFT")
end

-- 4. role-default ellipsis reached the fontstring-bearing item ----------------
do
    check("itemName (role=title) got SetWordWrap(false)", handle.byId["itemName"].wordWrap == false)
    check("breadcrumb (role=section) got SetWordWrap(false)", handle.byId["breadcrumb"].wordWrap == false)
end

-- 5. relayout re-applies without error and keeps the same frames -------------
do
    local before = handle.byId["profbar"]
    handle.relayout()
    check("relayout reuses frames", handle.byId["profbar"] == before)
end

print(string.format("Layout build: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
