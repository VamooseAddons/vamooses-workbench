-- ============================================================================
-- VWB LayoutConfig - Records (Data) view skeleton (box model v2)
-- ============================================================================
-- VPC's DB/diagnostics tab: store stats, a profession x expansion coverage grid,
-- the crafting-history log, and a CSV export. Themed skeleton; the coverage grid
-- reads recipeCoverage (already in the store) + history reads craftingHistory
-- (later slice). The guild rescan trigger lives here in VPC.
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

ns.LayoutConfig.records = {
    type = "stack", dir = "col", gap = "sm", padding = 4, align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "recStats", role = "section", size = { h = 40 } },
        -- Tall enough to show ALL 12 professions without scrolling: Coverage header
        -- (16) + expansion header (16) + 12 rows x GRID_ROW_H(18)=216 + totals (18)
        -- + gaps (4) = 270. Crafting History grows, so it absorbs the difference.
        { type = "item", id = "recCoverage", size = { h = 270 } }, -- profession x expansion grid
        { type = "item", id = "recHistory", grow = true },          -- crafting history log
        { type = "stack", dir = "row", gap = "sm", justify = "end", align = "center", children = {
            { type = "item", id = "recRescan", size = { w = 150, h = 22 } },
            { type = "item", id = "recExport", size = { w = 120, h = 22 } },
        } },
    },
}

return ns.LayoutConfig
