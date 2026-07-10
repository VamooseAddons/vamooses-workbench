-- ============================================================================
-- VWB LayoutConfig - Projects view skeleton (box model v2)
-- ============================================================================
-- The plan board, DECLARATIVE (2026-07-11: the board skeleton was hand-rolled
-- inside a single prjBody leaf, Roster-style -- wrong shape; the static
-- structure belongs here, Recipes-style, with the view's makeFrame supplying
-- only the leaves):
--   header row: title + New Stock Project button
--   board row:  card rail (vertical scroll) | Plan panel | Materials panel
-- Only the genuinely dynamic overlays (empty-state card, new-stock picker)
-- stay view-managed, anchored over the container.
-- Design: docs/PROJECTS_SPEC_2026-07-11.md.
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

ns.LayoutConfig.projects = {
    type = "stack", dir = "col", gap = "sm", padding = 6, align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "prjTitle", role = "title", grow = true, size = { h = 24 } },
            { type = "item", id = "prjNewStock", size = { w = 150, h = 22 } },
        } },
        { type = "stack", id = "prjBoard", dir = "row", gap = "sm", grow = true, align = "stretch", children = {
            { type = "item", id = "prjRail", size = { w = 210 } }, -- vertical project-card rail
            { type = "stack", id = "prjPlanCol", dir = "col", gap = "sm", padding = "md", align = "stretch", grow = true, chrome = "Panel", children = {
                { type = "stack", dir = "row", gap = "sm", align = "center", children = {
                    { type = "item", id = "prjPlanLabel", role = "section", grow = true, size = { h = 20 } },
                    { type = "item", id = "prjQueueBtn", size = { w = 170, h = 20 } },
                    { type = "item", id = "prjBuysBtn", size = { w = 180, h = 20 } },
                } },
                { type = "item", id = "prjSteps", grow = true },
            } },
            { type = "stack", id = "prjMatsCol", dir = "col", gap = "sm", padding = "md", align = "stretch", size = { w = 380 }, chrome = "Panel", children = {
                { type = "item", id = "prjMatsLabel", role = "section", size = { h = 16 } },
                { type = "item", id = "prjMats", grow = true },
            } },
        } },
    },
}

return ns.LayoutConfig
