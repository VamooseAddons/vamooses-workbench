-- Headless tests for the Layout grid primitives (pure computeGrid). The box
-- model (stack/place/panel/free/resolve) is in layout_box_test.lua; the real
-- Showroom config is in layout_showroom_config_test.lua. Run: lua layout_test.lua
local base = arg[0]:gsub("tests/layout_test%.lua$", "")
local Layout = dofile(base .. "Layout/Layout.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end
local function near(a, b) return math.abs(a - b) < 0.001 end

-- 1. fixed + flex columns, fixed + flex rows, with padding + gap -------------
do
    -- padding 5, gap 10, cols {100,"flex"}, rows {20,"flex"}, container 400x200
    -- innerW = 390; cols: fixed 100, gaps 10 -> flex = 280. offsets {0,110}
    -- innerH = 190; rows: fixed 20, gaps 10 -> flex = 160. offsets {0,30}
    local cfg = {
        padding = 5, gap = 10,
        columns = { 100, "flex" }, rows = { 20, "flex" },
        cells = {
            a = { col = 1, row = 1 },
            b = { col = 2, row = 2 },
            wide = { col = 1, row = 1, colSpan = 2 },
        },
    }
    local r = Layout.computeGrid(cfg, 400, 200)
    check("cell a pos", near(r.a.x, 5) and near(r.a.y, 5))
    check("cell a size", near(r.a.w, 100) and near(r.a.h, 20))
    check("flex cell b pos", near(r.b.x, 115) and near(r.b.y, 35)) -- 5+110, 5+30
    check("flex cell b size", near(r.b.w, 280) and near(r.b.h, 160))
    check("colSpan width includes gap", near(r.wide.w, 100 + 280 + 10)) -- 390
end

-- 2. two flex columns split evenly ------------------------------------------
do
    local cfg = { padding = 0, gap = 0, columns = { "flex", "flex" }, rows = { "flex" },
        cells = { l = { col = 1, row = 1 }, r = { col = 2, row = 1 } } }
    local rects = Layout.computeGrid(cfg, 300, 100)
    check("two flex split evenly", near(rects.l.w, 150) and near(rects.r.w, 150))
    check("second flex offset", near(rects.r.x, 150))
end

print(string.format("Layout: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
