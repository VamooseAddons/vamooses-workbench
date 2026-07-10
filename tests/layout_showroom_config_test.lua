-- The REAL Showroom LayoutConfig resolves end-to-end through the box model:
-- grid root -> nav/list/stage panels -> stacks, a `free` model area with
-- OVERLAPPING model frames, and a details panel that hand-places name/details/
-- button (place + sibling anchor). Proves the ported config the WoW view will
-- build actually resolves. Run: lua layout_showroom_config_test.lua
local base = arg[0]:gsub("tests/layout_showroom_config_test%.lua$", "")
local Layout = dofile(base .. "Layout/Layout.lua")
local LC = dofile(base .. "Layout/LayoutConfig_Showroom.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.5 end
local function find(rc, id) for _, c in ipairs(rc.children) do if c.id == id then return c end end end
-- deep find (any descendant) for convenience
local function deep(rc, id)
    if rc.id == id then return rc end
    for _, c in ipairs(rc.children) do local f = deep(c, id); if f then return f end end
end

-- every text item without an explicit size hugs -> supply a stub measure
local measure = function(node) return { w = 80, h = 12 } end

local root = Layout.resolveNode(LC.showroom, 1000, 600, measure)

-- 1. top-level 3-column grid under a full-width profession bar ----------------
do
    local profbar = deep(root, "profbar")
    local nav, list, stage = find(root, "navCol"), find(root, "listCol"), find(root, "stageCol")
    check("profbar spans full inner width", near(profbar.rect.w, 990) and near(profbar.rect.h, 22))
    check("nav column fixed 240", near(nav.rect.w, 240))
    check("stage column fixed 380", near(stage.rect.w, 380))
    check("list column flexes", near(list.rect.w, 354)) -- 990 - 240 - 380 - 16
    check("nav/list/stage share body row", near(nav.rect.y, list.rect.y) and near(list.rect.y, stage.rect.y))
    check("body sits below profbar", nav.rect.y > profbar.rect.y)
end

-- 2. list column: search grows, type toggle to its right, list fills ---------
do
    local list = find(root, "listCol")
    local search, toggle = deep(list, "search"), deep(list, "typeToggle")
    local breadcrumb, items = deep(list, "breadcrumb"), deep(list, "list")
    check("search pinned left of header row", near(search.rect.x, 0))
    check("type toggle right of search", toggle.rect.x > search.rect.x)
    check("breadcrumb below header", breadcrumb.rect.y > search.rect.y)
    check("item list is the tallest (fills)", items.rect.h > breadcrumb.rect.h * 3)
end

-- 3. stage column: control row / model area (grows) / details panel (44) -----
do
    local stage = find(root, "stageCol")
    local modelArea, details = find(stage, "modelArea"), find(stage, "detailsPanel")
    check("model area grows tallest", modelArea.rect.h > 300)
    check("details panel fixed 44", near(details.rect.h, 44))
    check("model area sits above details", modelArea.rect.y < details.rect.y)
end

-- 4. THE OVERLAP CASE the old grid could not express: 3 model frames all fill
--    and overlap exactly; the controls hint is pinned centre-bottom over them.
do
    local modelArea = deep(root, "modelArea")
    local d, c, s = find(modelArea, "modelDress"), find(modelArea, "modelCreature"), find(modelArea, "modelScene")
    local same = near(d.rect.x, c.rect.x) and near(c.rect.x, s.rect.x)
        and near(d.rect.w, c.rect.w) and near(c.rect.w, s.rect.w)
        and near(d.rect.h, s.rect.h)
    check("3 model frames overlap exactly (fill)", same and d.rect.w > 300)
    local hint = find(modelArea, "controlsHint")
    -- spans the model region (fill width, centred via JustifyH), pinned near the
    -- bottom (nudged up 6)
    check("controls hint spans bottom", near(hint.rect.x, 0) and near(hint.rect.w, modelArea.rect.w) and hint.rect.y > modelArea.rect.h - 30)
end

-- 5. details panel: name top-left (fill width), details anchored under name.
--    Add to Queue lives in the top control row now, not the details panel.
do
    local details = deep(root, "detailsPanel")
    local name, dtl = find(details, "itemName"), find(details, "itemDetails")
    check("item name placed top-left", near(name.rect.x, 4) and near(name.rect.y, 4)) -- pad "sm"=4
    check("item name fills the panel width", name.rect.w > 300)
    check("details anchored to name (sibling, no rect)", dtl.rect == nil and dtl.anchor.to == "itemName" and dtl.anchor.at == "BOTTOMLEFT")
    check("add-to-queue moved out of details panel", find(details, "addToQueue") == nil)
    check("add-to-queue now in the stage control row", deep(root, "addToQueue") ~= nil)
end

print(string.format("Showroom config: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
