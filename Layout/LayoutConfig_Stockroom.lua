-- ============================================================================
-- VWB LayoutConfig - Stockroom (Reagents) view, as DATA (box model v2)
-- ============================================================================
-- VPC's lightest tab, ported 1:1 from Reagents.lua: a title, a filter row
-- (search + a 4-way class toggle), a single flat virtualized list of every
-- reagent the recipe store knows about, and a totals footer. Rows are live off
-- ReagentSource (class/evidence/BoP) + Inventory (owned); the filter row adds an
-- expansion multi-select picker, and selecting a reagent drives the right-hand
-- detail panel (which recipes use it, with an add-to-queue button).
--
--   +----------------------------------------------------------+
--   | Stockroom (title)                                        | 24
--   | [search........] [Expansions v] [Sources v] [All|Farm|Q] | 20
--   | <flat reagent list, fills>      | <detail panel: which   | flex
--   |                                 |  recipes use the       |
--   |                                 |  selected reagent>     |
--   | totals footer                                            | 20
--   +----------------------------------------------------------+
-- The list stays wide (fixed-width cells never reflow); the detail panel takes
-- the previously-empty right space. Selecting a row drives the panel.
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

ns.LayoutConfig.stockroom = {
    type = "stack", dir = "col", gap = "sm", padding = 6, align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "stkTitle", role = "title", size = { h = 24 } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "stkSearch", grow = true, size = { h = 20 } },
            { type = "item", id = "stkExpansion", size = { w = 160, h = 22 } }, -- multi-select expansion filter (Blizzard chrome wants ~22px; search grows into the rest)
            { type = "item", id = "stkSource", size = { w = 160, h = 22 } }, -- gather-source multi-select filter
            { type = "item", id = "stkFilter", size = { w = 425, h = 20 } },
        } },
        -- grid (not a row-stack): a grid column sizes to an exact 380px; a stack
        -- child's own size.w isn't honored, which squeezed the panel to min-content.
        { type = "grid", gap = 6, grow = true, columns = { "flex", 380 }, rows = { "flex" }, cells = {
            { at = { col = 1, row = 1 }, child = { type = "item", id = "stkList" } }, -- flex: keeps width, cells never reflow
            { at = { col = 2, row = 1 }, child = {
                type = "stack", id = "stkDetail", dir = "col", gap = "xs", padding = "sm", align = "stretch", chrome = "Panel", children = {
                    { type = "item", id = "stkDetailHeader",  role = "title",   size = { h = 22 } },
                    { type = "item", id = "stkDetailSub",     role = "body",    size = { h = 16 } },
                    { type = "item", id = "stkDetailUsedHdr", role = "section", size = { h = 18 } },
                    { type = "item", id = "stkDetailList",    grow = true },
                    { type = "item", id = "stkDetailAddBtn",  size = { h = 24 } },
                },
            } },
        } },
        { type = "item", id = "stkFooter", role = "label", size = { h = 20 } },
    },
}

return ns.LayoutConfig
