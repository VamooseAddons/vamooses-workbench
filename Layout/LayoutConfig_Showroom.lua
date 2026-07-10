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
        { type = "stack", dir = "row", justify = "start", children = {
            { type = "item", id = "missingPill", size = { w = 90, h = 18 } },
        } },
        { type = "item", id = "breadcrumb", role = "section", size = { h = 16 } }, -- Items / N known / N unc
        { type = "item", id = "list", grow = true }, -- CreateVirtualizedList target (bindList)
    },
}

-- Stage column: a top control row / the lit model area / a slim name+details
-- panel. The model area is a `free` region: DressUpModel + PlayerModel +
-- ModelScene all fill and OVERLAP (the view shows whichever fits the collectible
-- kind), with the controls hint spanning the bottom (fill width -> centre text).
-- Add to Queue moved up to the control row (was crammed into the details panel).
-- itemName now takes a FILL width so a long name no longer truncates.
local stagePanel = {
    type = "stack", id = "stageCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "undress", size = { w = 90, h = 20 } },
            { type = "item", id = "recentStrip", grow = true, size = { h = 20 } },
            { type = "item", id = "startProject", size = { w = 110, h = 20 } }, -- Item 4
            { type = "item", id = "addToQueue", size = { w = 110, h = 20 } },
        } },
        { type = "free", id = "modelArea", grow = true, children = {
            { type = "item", id = "modelDress",    size = { w = "fill", h = "fill" } },
            { type = "item", id = "modelCreature", size = { w = "fill", h = "fill" } },
            { type = "item", id = "modelScene",    size = { w = "fill", h = "fill" } },
            { type = "item", id = "controlsHint", size = { w = "fill", h = 14 }, place = { h = "left", v = "bottom", dy = -6 } },
        } },
        { type = "free", id = "detailsPanel", size = { h = 44 }, padding = "sm", children = {
            -- itemName gets an explicit FILL width: it's empty at build time, so
            -- the old intrinsic-width measure clamped it to ~0px and a long name
            -- truncated to "Rhinest...". Fill = the panel width -> no truncation.
            { type = "item", id = "itemName",    role = "title", size = { w = "fill" }, place = { h = "left", v = "top" } },
            { type = "item", id = "itemDetails", role = "body",  anchor = { to = "itemName", from = "TOPLEFT", at = "BOTTOMLEFT", dy = -5 } },
        } },
    },
}

-- Root: profession bar (full width) over nav | list | stage. -------------------
ns.LayoutConfig.showroom = {
    type = "grid",
    padding = 5, -- mirrors Preview.lua profContainer/contentArea 5px inset
    gap = 8,     -- COL_GAP
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
