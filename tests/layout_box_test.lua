-- Headless tests for the Layout box model (stack / place / panel / free /
-- intrinsic sizing / recursive resolve). Pure geometry, no frames.
-- Run: lua layout_box_test.lua
local base = arg[0]:gsub("tests/layout_box_test%.lua$", "")
local Layout = dofile(base .. "Layout/Layout.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.001 end

-- plain sizer for computeStack tests: read .w/.h off the child (0 if absent)
local function sizer(c) return { w = c.w or 0, h = c.h or 0 } end
-- find a resolved child by id
local function byId(rc, id)
    for _, c in ipairs(rc.children) do if c.id == id then return c end end
end

-- 1. spacing tokens flow through grid (padding "sm"=4, gap "md"=8) -----------
do
    local cfg = { padding = "sm", gap = "md", columns = { 100, "flex" }, rows = { "flex" },
        cells = { a = { col = 1, row = 1 }, b = { col = 2, row = 1 } } }
    local r = Layout.computeGrid(cfg, 400, 100)
    -- innerW = 400-8 = 392; fixed 100, gap 8 -> flex = 284; offsets {0, 108}
    check("token pad offsets cell a", near(r.a.x, 4) and near(r.a.y, 4))
    check("token gap + flex width", near(r.b.w, 284) and near(r.b.x, 4 + 108))
end

-- 2. percent tracks ----------------------------------------------------------
do
    local cfg = { padding = 0, gap = 0, columns = { "50%", "flex" }, rows = { "flex" },
        cells = { l = { col = 1, row = 1 }, r = { col = 2, row = 1 } } }
    local r = Layout.computeGrid(cfg, 400, 100)
    check("50% column = 200", near(r.l.w, 200) and near(r.r.w, 200) and near(r.r.x, 200))
end

-- 3. computeStack row: justify variants --------------------------------------
do
    local cfg = { dir = "row", gap = 10, children = { { w = 100, h = 20 }, { w = 100, h = 20 }, { w = 100, h = 20 } } }
    local s = Layout.computeStack({ dir = "row", gap = 10, justify = "start", children = cfg.children }, 400, 50, sizer)
    check("justify start x", near(s[1].x, 0) and near(s[2].x, 110) and near(s[3].x, 220))
    local c = Layout.computeStack({ dir = "row", gap = 10, justify = "center", children = cfg.children }, 400, 50, sizer)
    check("justify center x", near(c[1].x, 40) and near(c[3].x, 260))
    local e = Layout.computeStack({ dir = "row", gap = 10, justify = "end", children = cfg.children }, 400, 50, sizer)
    check("justify end x", near(e[1].x, 80) and near(e[3].x, 300))
    local b = Layout.computeStack({ dir = "row", gap = 10, justify = "between", children = cfg.children }, 400, 50, sizer)
    check("justify between x", near(b[1].x, 0) and near(b[2].x, 150) and near(b[3].x, 300))
end

-- 4. computeStack row: align variants (cross axis) ---------------------------
do
    local kids = { { w = 100, h = 20 } }
    check("align start y", near(Layout.computeStack({ dir = "row", align = "start", children = kids }, 400, 50, sizer)[1].y, 0))
    check("align center y", near(Layout.computeStack({ dir = "row", align = "center", children = kids }, 400, 50, sizer)[1].y, 15))
    check("align end y", near(Layout.computeStack({ dir = "row", align = "end", children = kids }, 400, 50, sizer)[1].y, 30))
    local st = Layout.computeStack({ dir = "row", align = "stretch", children = kids }, 400, 50, sizer)[1]
    check("align stretch fills cross", near(st.y, 0) and near(st.h, 50))
end

-- 5. computeStack grow splits leftover ---------------------------------------
do
    local kids = { { w = 100, h = 20 }, { grow = true, h = 20 }, { w = 80, h = 20 } }
    local s = Layout.computeStack({ dir = "row", gap = 0, children = kids }, 400, 20, sizer)
    check("grow middle width", near(s[2].w, 220) and near(s[1].w, 100) and near(s[3].w, 80))
    check("grow positions", near(s[1].x, 0) and near(s[2].x, 100) and near(s[3].x, 320))
end

-- 6. computeStack col --------------------------------------------------------
do
    local kids = { { w = 100, h = 20 }, { w = 100, h = 20 }, { w = 100, h = 20 } }
    local s = Layout.computeStack({ dir = "col", gap = 5, children = kids }, 100, 200, sizer)
    check("col stacks y", near(s[1].y, 0) and near(s[2].y, 25) and near(s[3].y, 50))
    check("col child fills cross w", near(s[1].w, 100) and near(s[1].h, 20))
end

-- 7. resolvePlace 9-point + offset -------------------------------------------
do
    local tl = Layout.resolvePlace({ h = "left", v = "top" }, 40, 20, 200, 100)
    check("place top-left", near(tl.x, 0) and near(tl.y, 0))
    local br = Layout.resolvePlace({ h = "right", v = "bottom" }, 40, 20, 200, 100)
    check("place bottom-right", near(br.x, 160) and near(br.y, 80))
    local cm = Layout.resolvePlace({ h = "center", v = "middle" }, 40, 20, 200, 100)
    check("place center-middle", near(cm.x, 80) and near(cm.y, 40))
    local off = Layout.resolvePlace({ h = "right", v = "top", dx = -8, dy = 6 }, 40, 20, 200, 100)
    check("place + offset", near(off.x, 152) and near(off.y, 6))
end

-- 8. resolveNode grid tree keeps ids + child rects ---------------------------
do
    local node = { type = "grid", padding = 0, gap = 0, columns = { 100, "flex" }, rows = { "flex" },
        cells = {
            { at = { col = 1, row = 1 }, child = { type = "item", id = "left" } },
            { at = { col = 2, row = 1 }, child = { type = "item", id = "right" } },
        } }
    local t = Layout.resolveNode(node, 300, 100, sizer)
    local l, r = byId(t, "left"), byId(t, "right")
    check("grid child left", near(l.rect.w, 100) and near(l.rect.x, 0))
    check("grid child right flexes", near(r.rect.x, 100) and near(r.rect.w, 200))
end

-- 9. resolveNode nested grid -> stack ----------------------------------------
do
    local node = { type = "grid", padding = 0, gap = 0, columns = { "flex" }, rows = { "flex" },
        cells = { { at = { col = 1, row = 1 }, child = {
            type = "stack", dir = "row", gap = 0, children = {
                { type = "item", id = "a", size = { w = 50, h = 20 } },
                { type = "item", id = "b", size = { w = 50, h = 20 } },
            } } } } }
    local t = Layout.resolveNode(node, 200, 100, function(c) return { w = 0, h = 0 } end)
    local stack = t.children[1]
    local a, b = byId(stack, "a"), byId(stack, "b")
    check("nested stack child a", near(a.rect.x, 0) and near(a.rect.w, 50))
    check("nested stack child b offset", near(b.rect.x, 50))
end

-- 10. resolveNode panel splits header/body/footer ----------------------------
do
    local node = { type = "panel", padding = 0, gap = 0, headerHeight = 30, footerHeight = 20,
        header = { type = "item", id = "h" }, body = { type = "item", id = "bd" }, footer = { type = "item", id = "ft" } }
    local t = Layout.resolveNode(node, 200, 200, function() return { w = 0, h = 0 } end)
    local h, bd, ft = byId(t, "h"), byId(t, "bd"), byId(t, "ft")
    check("panel header", near(h.rect.y, 0) and near(h.rect.h, 30))
    check("panel body flexes", near(bd.rect.y, 30) and near(bd.rect.h, 150))
    check("panel footer", near(ft.rect.y, 180) and near(ft.rect.h, 20))
end

-- 11. resolveNode free: place (rect) + anchor (spec) -------------------------
do
    local node = { type = "free", padding = 0, children = {
        { type = "item", id = "pin", size = { w = 40, h = 20 }, place = { h = "right", v = "bottom" } },
        { type = "item", id = "badge", size = { w = 16, h = 16 }, anchor = { to = "pin", from = "CENTER", at = "TOPRIGHT" } },
    } }
    local t = Layout.resolveNode(node, 300, 200, function() return { w = 0, h = 0 } end)
    local pin, badge = byId(t, "pin"), byId(t, "badge")
    check("free place pin bottom-right", near(pin.rect.x, 260) and near(pin.rect.y, 180))
    check("free anchor badge carries spec", badge.rect == nil and badge.anchor.to == "pin" and badge.anchor.at == "TOPRIGHT")
end

-- 12. THE MONEY TEST: header with multiple title levels + left/right + centre.
-- title over subtitle (left, hugging their text), controls flush right, both
-- groups vertically centred in the bar. This is the "panel breakdown" the whole
-- redesign is about -- it must resolve with content-driven widths, no clipping.
do
    local measure = function(node)
        if node.id == "title" then return { w = 100, h = 14 } end
        if node.id == "subtitle" then return { w = 80, h = 10 } end
        return { w = 0, h = 0 }
    end
    local header = { type = "stack", dir = "row", justify = "between", align = "center", children = {
        { type = "stack", dir = "col", gap = 0, children = {
            { type = "item", id = "title", role = "title" },       -- no size -> hugs text
            { type = "item", id = "subtitle", role = "subtitle" }, -- no size -> hugs text
        } },
        { type = "stack", dir = "row", gap = 4, children = {
            { type = "item", id = "search", size = { w = 140, h = 20 } },
            { type = "item", id = "close", size = { w = 20, h = 20 } },
        } },
    } }
    local t = Layout.resolveNode(header, 400, 30, measure)
    local left, right = t.children[1], t.children[2]
    check("title group pinned left", near(left.rect.x, 0))
    check("controls group flush right", near(right.rect.x + right.rect.w, 400) and near(right.rect.x, 236))
    check("groups vertically centred", near(left.rect.y, 3) and near(right.rect.y, 5))
    local title, subtitle = byId(left, "title"), byId(left, "subtitle")
    check("subtitle sits below title (2 title levels)", near(title.rect.y, 0) and near(subtitle.rect.y, 14))
    check("title hugged its text width", near(title.rect.w, 100))
    local search, close = byId(right, "search"), byId(right, "close")
    check("search left of close in controls", near(search.rect.x, 0) and near(close.rect.x, 144))
end

-- N. flex: weighted grow (numeric factors, not just boolean) ----------------
do
    local cfg = { dir = "row", gap = 0, children = { { h = 20, grow = 2 }, { h = 20, grow = 1 } } }
    local r = Layout.computeStack(cfg, 120, 20, sizer)
    check("weighted grow 2:1", near(r[1].w, 80) and near(r[2].w, 40))
end

-- N. flex: max clamp on grow freezes + redistributes remainder ---------------
do
    local cfg = { dir = "row", gap = 0, children = { { h = 20, grow = 1, max = 30 }, { h = 20, grow = 1 } } }
    local r = Layout.computeStack(cfg, 120, 20, sizer)
    check("grow clamps to max, remainder to sibling", near(r[1].w, 30) and near(r[2].w, 90))
end

-- N. flex: shrink absorbs overflow, weighted by basis ------------------------
do
    local cfg = { dir = "row", gap = 0, children = { { w = 80, h = 20, shrink = 1 }, { w = 80, h = 20, shrink = 1 } } }
    local r = Layout.computeStack(cfg, 100, 20, sizer)
    check("shrink splits 60px overflow evenly", near(r[1].w, 50) and near(r[2].w, 50))
end

-- N. flex: min clamp on shrink freezes + redistributes -----------------------
do
    local cfg = { dir = "row", gap = 0, children = { { w = 80, h = 20, shrink = 1, min = 70 }, { w = 80, h = 20, shrink = 1 } } }
    local r = Layout.computeStack(cfg, 100, 20, sizer)
    check("shrink clamps to min, extra shrink to sibling", near(r[1].w, 70) and near(r[2].w, 30))
end

-- N. flex: shrink defaults to 0 -> fixed children overflow, never shrink -----
do
    local cfg = { dir = "row", gap = 0, children = { { w = 80, h = 20 }, { w = 80, h = 20 } } }
    local r = Layout.computeStack(cfg, 100, 20, sizer)
    check("no shrink by default (back-compat: fixed children keep size)", near(r[1].w, 80) and near(r[2].w, 80))
end

-- N. wrap: children overflow onto a second line ----------------------------
do
    local cfg = { dir = "row", wrap = true, gap = 10,
        children = { { w = 40, h = 20 }, { w = 40, h = 20 }, { w = 40, h = 20 } } }
    local r = Layout.computeStack(cfg, 100, 100, sizer)
    -- line1 = [1,2] (40+10+40=90 <=100); [3] wraps (90+10+40=140 >100)
    check("wrap line1 packs two", near(r[1].x, 0) and near(r[2].x, 50) and near(r[1].y, 0) and near(r[2].y, 0))
    check("wrap line2 drops below (lineCross 20 + gap 10)", near(r[3].x, 0) and near(r[3].y, 30))
end

-- N. wrap OFF: same children stay on one overflowing line (back-compat) ------
do
    local cfg = { dir = "row", gap = 10,
        children = { { w = 40, h = 20 }, { w = 40, h = 20 }, { w = 40, h = 20 } } }
    local r = Layout.computeStack(cfg, 100, 100, sizer)
    check("no wrap: all three on one line", near(r[1].y, 0) and near(r[2].y, 0) and near(r[3].y, 0))
    check("no wrap: third overflows (x=100)", near(r[3].x, 100))
end

-- N. wrap: grow applies PER LINE (each line fills its own width) -------------
do
    local cfg = { dir = "row", wrap = true, gap = 0,
        children = { { w = 60, h = 20, grow = 1 }, { w = 60, h = 20, grow = 1 } } }
    local r = Layout.computeStack(cfg, 100, 100, sizer)
    -- 60+0+60=120 >100 -> each on its own line, each grows to fill 100
    check("wrap per-line grow fills each line", near(r[1].w, 100) and near(r[2].w, 100))
    check("wrap second grower drops below", near(r[2].y, 20))
end

print(string.format("Layout box: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
