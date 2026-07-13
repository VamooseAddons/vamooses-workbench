-- ============================================================================
-- VWB LayoutConfig - Showroom view, as DATA (box model v2)
-- ============================================================================
-- The Showroom's structure described declaratively. Walked by Layout.build;
-- content bound in by the Showroom controller via Reactor. Ported 1:1 from the
-- imperative VPC Preview.lua so it exercises the real layout, including the two
-- shapes the old grid could NOT express: overlapping model frames (a `free`
-- region) and a details panel that hand-places name / details / a button
-- (place + sibling anchor). Dimensions mirror Preview.lua.
--
--   +--------------------------------------------------------------+
--   | profbar  (profession icon tabs, full width)          row 1 (22)
--   +-----------+--------------------------------+-----------------+
--   | nav       | list panel                     | stage panel     | row 2
--   | Categories|  [search........] [type toggle]|  [undress][recent]
--   |  <navTree>|  [missing]                     |   +-----------+  |
--   |           |  Items / N known / N unc       |  | model(x3) |  |
--   |           |  <virtualized item list>       |  | + hint    |  |
--   |           |                                |  +-----------+  |
--   |           |                                |  name / details |
--   |           |                                |  [Add to Queue] |
--   +-----------+--------------------------------+-----------------+
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

-- Nav column: "Categories" section header over the NavTree (fills). ------------
local navPanel = {
    type = "stack", id = "navCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "navLabel", role = "section", size = { h = 16 } },
        { type = "item", id = "navTree", grow = true }, -- CreateNavTree target
    },
}

-- List column: filter header (search grows, type toggle right) / missing pill /
-- breadcrumb counts / the virtualized item list (fills). ----------------------
local listPanel = {
    type = "stack", id = "listCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", children = {
            { type = "item", id = "search", grow = true, size = { h = 20 } },
            { type = "item", id = "typeToggle", size = { w = 300, h = 18 } },
        } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "missingPill", size = { w = 90, h = 18 } },
            { type = "item", id = "filterSpacer", grow = true, size = { h = 18 } },
            { type = "item", id = "resetFilters", size = { w = 100, h = 18 } }, -- shown only when a filter/category is active
        } },
        { type = "item", id = "breadcrumb", role = "section", size = { h = 16 } }, -- Items / N known / N unc
        { type = "item", id = "list", grow = true }, -- CreateVirtualizedList target (bindList)
    },
}

-- Stage column: a top control row / the lit model area / a name+details panel
-- with the ACTION buttons (owner 2026-07-11: Start Project / Add to Queue live
-- at the BOTTOM next to the item identity they act on, not in the top chrome).
-- The model area is a `free` region: DressUpModel + PlayerModel + ModelScene
-- all fill and OVERLAP (the view shows whichever fits the collectible kind),
-- with the controls hint spanning the bottom (fill width -> centre text).
-- itemName/itemDetails take FILL widths: both are empty at build time, so an
-- intrinsic-width measure clamps to ~0px and long text truncates ("Rhinest...",
-- "Profession..."). Fill = the column width -> no truncation.
local stagePanel = {
    type = "stack", id = "stageCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "undress", size = { w = 90, h = 20 } },
            { type = "item", id = "recentStrip", grow = true, size = { h = 20 } },
        } },
        { type = "free", id = "modelArea", grow = true, children = {
            { type = "item", id = "modelDress",    size = { w = "fill", h = "fill" } },
            { type = "item", id = "modelCreature", size = { w = "fill", h = "fill" } },
            { type = "item", id = "modelScene",    size = { w = "fill", h = "fill" } },
            { type = "item", id = "controlsHint", size = { w = "fill", h = 14 }, place = { h = "left", v = "bottom", dy = -6 } },
        } },
        { type = "stack", id = "detailsPanel", dir = "row", gap = "sm", padding = "sm", size = { h = 54 }, align = "center", children = {
            { type = "stack", dir = "col", gap = "xs", grow = true, align = "stretch", children = {
                { type = "item", id = "itemName",    role = "title", size = { w = "fill", h = 16 } },
                { type = "item", id = "itemDetails", role = "body",  size = { w = "fill", h = 28 } }, -- two lines: view re-enables wrap post-build
            } },
            { type = "stack", dir = "col", gap = "xs", children = {
                { type = "item", id = "startProject", size = { w = 110, h = 20 } },
                { type = "item", id = "addToQueue",   size = { w = 110, h = 20 } },
            } },
        } },
    },
}

-- Root: profession bar (full width) over nav | list | stage. -------------------
ns.LayoutConfig.showroom = {
    type = "grid",
    padding = 4,
    gap = 6,     -- COL_GAP
    columns = { 240, "flex", 380 }, -- NAV_PANEL_WIDTH | list | MODEL_AREA_WIDTH_INIT
    rows    = { 22, "flex" },       -- profbar height | body
    cells = {
        { at = { col = 1, row = 1, colSpan = 3 }, child = { type = "item", id = "profbar" } },
        { at = { col = 1, row = 2 }, child = navPanel },
        { at = { col = 2, row = 2 }, child = listPanel },
        { at = { col = 3, row = 2 }, child = stagePanel },
    },
}

return ns.LayoutConfig -- WoW attaches to ns; headless dofile gets the table
