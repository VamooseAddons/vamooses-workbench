-- ============================================================================
-- VWB LayoutConfig - Study view, as DATA (box model v2)
-- ============================================================================
-- The acquisition browser: profession bar over a Sources nav | recipe list.
-- Two columns only -- no stage panel; the row tooltip carries the detail.
--
--   +-----------------------------------------------------+
--   | profbar  (profession icon tabs, full width)   row 1 (22)
--   +-----------+-----------------------------------------+
--   | nav       | list panel                        row 2 |
--   | Sources   |  [search..........................]     |
--   |  <navTree>|  N recipes to learn | N shown           |
--   |           |  <virtualized recipe list>              |
--   +-----------+-----------------------------------------+
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

local navPanel = {
    type = "stack", id = "navCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", align = "center", size = { h = 20 }, children = {
            { type = "item", id = "navLabel", role = "section", grow = true, size = { h = 16 } },
            { type = "item", id = "missingToggle", size = { w = 110, h = 20 } }, -- "Unlearned only" pill
        } },
        { type = "item", id = "navTree", grow = true }, -- CreateNavTree target
    },
}

local listPanel = {
    type = "stack", id = "listCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", children = {
            { type = "item", id = "search", grow = true, size = { h = 22 } },
            { type = "item", id = "expansionDD", size = { w = 170, h = 22 } }, -- multi-select, Stockroom pattern
        } },
        { type = "item", id = "breadcrumb", role = "section", size = { h = 16 } },
        { type = "item", id = "list", grow = true }, -- CreateVirtualizedList target
    },
}

ns.LayoutConfig.study = {
    type = "grid",
    padding = 5,
    gap = 8,
    columns = { 240, "flex" }, -- NAV_PANEL_WIDTH | list
    rows    = { 22, "flex" },  -- profbar height | body
    cells = {
        { at = { col = 1, row = 1, colSpan = 2 }, child = { type = "item", id = "profbar" } },
        { at = { col = 1, row = 2 }, child = navPanel },
        { at = { col = 2, row = 2 }, child = listPanel },
    },
}

return ns.LayoutConfig
