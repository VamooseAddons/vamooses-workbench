-- ============================================================================
-- VWB LayoutConfig - Projects view skeleton (box model v2)
-- ============================================================================
-- The plan board: header row (title + New Stock Project button), then one
-- body leaf. Board internals (card strip / detail panels / empty state / new-
-- stock picker) are dynamic pooled content built Roster-style inside prjBody
-- by Projects_View's makeFrame -- same shape as rosGrid.
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
        { type = "item", id = "prjBody", grow = true }, -- strip + detail + empty state, view-managed
    },
}

return ns.LayoutConfig
