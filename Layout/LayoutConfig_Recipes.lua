-- ============================================================================
-- VWB LayoutConfig - Workbench (Recipes) view, as DATA (box model v2)
-- ============================================================================
-- VPC's flagship crafting tab, ported 1:1 from Recipes.lua's region map: a
-- filter bar + profession tab bar over a 3-column body -- category nav | recipe
-- list | (recent / crafting queue / materials). Built as a themed SKELETON for
-- now; the nav + recipe list wire to the same recipeStore signal + RecipeQuery
-- the Showroom uses, and the right column (queue/materials) needs the Graph/
-- Inventory/ReagentSource modules that aren't ported yet -- those panels stay
-- placeholders until they land.
--
--   +----------------------------------------------------------+
--   | filter bar (search | pills | decor toggle)               | 24
--   +----------------------------------------------------------+
--   | profession tab bar                                       | 28
--   +---------+-------------------+----------------------------+
--   | nav 240 | recipe list 360   | recent / queue / materials | body
--   +---------+-------------------+----------------------------+
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

local navPanel = {
    type = "stack", id = "rcpNavCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "rcpNavLabel", role = "section", size = { h = 16 } },
        { type = "item", id = "rcpNavTree", grow = true },
    },
}

local listPanel = {
    type = "stack", id = "rcpListCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "rcpListLabel", role = "section", size = { h = 16 } },
        { type = "item", id = "rcpList", grow = true },
    },
}

-- Right column: recent strip / crafting queue (fixed) / materials (fills). ----
local rightPanel = {
    type = "stack", id = "rcpRightCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "rcpMru", size = { h = 22 } },
        { type = "item", id = "rcpQueueHeader", role = "section", size = { h = 20 } },
        { type = "item", id = "rcpQueue", size = { h = 200 } },
        { type = "item", id = "rcpMatHeader", role = "section", size = { h = 20 } },
        { type = "item", id = "rcpMaterials", grow = true },
    },
}

ns.LayoutConfig.recipes = {
    type = "grid",
    padding = 5,
    gap = 6,
    columns = { "flex" },
    rows    = { 24, 28, "flex" }, -- filter bar | profession bar | body
    cells = {
        { at = { col = 1, row = 1 }, child = {
            type = "stack", dir = "row", gap = "sm", align = "center", children = {
                { type = "item", id = "rcpSearch", grow = true, size = { h = 18 } },
                { type = "item", id = "transmogPill", size = { w = 90, h = 18 } },
                { type = "item", id = "craftablePill", size = { w = 90, h = 18 } },
                { type = "item", id = "skillUpPill", size = { w = 90, h = 18 } },
                { type = "item", id = "decorToggle", size = { w = 150, h = 18 } },
            },
        } },
        { at = { col = 1, row = 2 }, child = { type = "item", id = "profTabBar" } },
        { at = { col = 1, row = 3 }, child = {
            type = "grid", padding = 0, gap = 6,
            columns = { 240, 360, "flex" }, rows = { "flex" },
            cells = {
                { at = { col = 1, row = 1 }, child = navPanel },
                { at = { col = 2, row = 1 }, child = listPanel },
                { at = { col = 3, row = 1 }, child = rightPanel },
            },
        } },
    },
}

return ns.LayoutConfig
