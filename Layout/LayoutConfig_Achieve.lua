-- ============================================================================
-- VWB LayoutConfig - Achieve view, as DATA (box model v2)
-- ============================================================================
-- Profession achievements: professions nav | achievement list | detail.
-- Rows are taller (36px) -- name + description lines, points/date right.
-- Detail column (owner 2026-07-13): click-selected achievement's full
-- criteria live here (the old hover tooltip ran off the screen on long
-- "know each of..." lists); Track + Commission get their proper home too.
--
--   +-----------+------------------------------+----------------+
--   | nav       | list panel                   | detail panel   |
--   | Profs     |  [search......] [Unearned]   | icon name  10p |
--   |  <navTree>|  N earned of M               | description    |
--   |           |  <virtualized list>          | 3/16 [Tk][Cm]  |
--   |           |                              | <criteria well>|
--   +-----------+------------------------------+----------------+
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

local detailPanel = {
    type = "stack", id = "detailCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "detHeader", size = { h = 30 } },
        { type = "item", id = "detDesc", size = { h = 32 } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "detProgress", grow = true, size = { h = 20 } },
            { type = "item", id = "detTrack", size = { w = 70, h = 20 } },
            { type = "item", id = "detCommission", size = { w = 104, h = 20 } },
        } },
        { type = "item", id = "detCriteria", grow = true },
    },
}

ns.LayoutConfig.achieve = {
    type = "grid",
    padding = 4,
    gap = 6,
    columns = { 240, "flex", 360 },
    rows    = { "flex" },
    cells = {
        { at = { col = 1, row = 1 }, child = navPanel },
        { at = { col = 2, row = 1 }, child = listPanel },
        { at = { col = 3, row = 1 }, child = detailPanel },
    },
}

return ns.LayoutConfig
