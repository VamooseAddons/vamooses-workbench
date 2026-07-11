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
        -- Board = GRID with fixed side tracks (rail 210 | plan flex | mats 380).
        -- NOT a row stack with sized stacks: the engine content-hugs stack
        -- children (intrinsicSize ignores size on containers), so a
        -- size={w=380} column collapsed to its hug width -- fixed columns are
        -- the grid's job, same idiom as LayoutConfig_Recipes' body.
        { type = "grid", id = "prjBoard", grow = true, padding = 0, gap = 6,
          columns = { 260, "flex", 380 }, rows = { "flex" }, -- rail 210->260 (Commissions cards carry pieces info; ui-designer pixel budget 2026-07-12)
          cells = {
            { at = { col = 1, row = 1 }, child = { type = "item", id = "prjRail" } }, -- vertical project-card rail
            { at = { col = 2, row = 1 }, child = {
                type = "stack", id = "prjPlanCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel", children = {
                    { type = "stack", dir = "row", gap = "sm", align = "center", children = {
                        { type = "item", id = "prjPlanLabel", role = "section", grow = true, size = { h = 20 } },
                        { type = "item", id = "prjQueueBtn", size = { w = 170, h = 20 } },
                        { type = "item", id = "prjBuysBtn", size = { w = 180, h = 20 } },
                    } },
                    { type = "item", id = "prjSteps", grow = true },
                },
            } },
            { at = { col = 3, row = 1 }, child = {
                type = "stack", id = "prjMatsCol", dir = "col", gap = "sm", padding = "md", align = "stretch", chrome = "Panel", children = {
                    { type = "item", id = "prjMatsLabel", role = "section", size = { h = 16 } },
                    { type = "item", id = "prjMats", grow = true },
                },
            } },
          },
        },
    },
}

return ns.LayoutConfig
