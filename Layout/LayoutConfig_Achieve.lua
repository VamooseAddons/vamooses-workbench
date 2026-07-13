-- ============================================================================
-- VWB LayoutConfig - Achieve view, as DATA (box model v2)
-- ============================================================================
-- Profession achievements: professions nav | achievement list. Rows are
-- taller (36px) -- name + description lines, points/date on the right.
--
--   +-----------+-----------------------------------------+
--   | nav       | list panel                              |
--   | Profs     |  [search...............] [ ]Hide earned |
--   |  <navTree>|  N earned of M                          |
--   |           |  <virtualized achievement list>         |
--   +-----------+-----------------------------------------+
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

local navPanel = {
    type = "stack", id = "navCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "navLabel", role = "section", size = { h = 16 } },
        { type = "item", id = "navTree", grow = true },
    },
}

local listPanel = {
    type = "stack", id = "listCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", children = {
            { type = "item", id = "search", grow = true, size = { h = 22 } },
            { type = "item", id = "hideEarned", size = { w = 120, h = 20 } },
        } },
        { type = "item", id = "breadcrumb", role = "section", size = { h = 16 } },
        { type = "item", id = "list", grow = true },
    },
}

ns.LayoutConfig.achieve = {
    type = "grid",
    padding = 4,
    gap = 6,
    columns = { 240, "flex" },
    rows    = { "flex" },
    cells = {
        { at = { col = 1, row = 1 }, child = navPanel },
        { at = { col = 2, row = 1 }, child = listPanel },
    },
}

return ns.LayoutConfig
