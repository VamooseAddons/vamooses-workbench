-- ============================================================================
-- VWB LayoutConfig - Roster (Alts) view skeleton (box model v2)
-- ============================================================================
-- VPC's multi-character tab: profession skill levels by expansion across the
-- account as a grid of character cards. Themed skeleton; content needs the
-- account.characters data (populated by the harvest's SAVE_CHARACTER_PROFESSIONS)
-- + a card grid renderer (later slice).
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

ns.LayoutConfig.roster = {
    type = "stack", dir = "col", gap = "sm", padding = 4, align = "stretch", chrome = "Panel",
    children = {
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "rosTitle", role = "title", grow = true, size = { h = 20 } },
            { type = "item", id = "rosScopeHint", role = "label", size = { w = 220, h = 20 } },
            { type = "item", id = "rosPlanBtn", size = { w = 130, h = 20 } },
        } },
        { type = "item", id = "rosGrid", grow = true }, -- grid of per-character profession cards
    },
}

return ns.LayoutConfig
