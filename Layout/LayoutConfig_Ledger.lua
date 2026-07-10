-- ============================================================================
-- VWB LayoutConfig - Ledger (Profit) view skeleton (box model v2)
-- ============================================================================
-- VPC's profit/margin tab: a KPI strip (session profit / gold-per-hour / margin
-- / price source) over a searchable, sortable profit table. Themed skeleton;
-- content needs PriceIntegration + ProfitCalculator (not ported).
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

ns.LayoutConfig.ledger = {
    type = "stack", dir = "col", gap = "sm", padding = 6, align = "stretch", chrome = "Panel",
    children = {
        -- KPI hierarchy (item 5): Session Profit is the primary metric (taller h=56,
        -- bigger font via LayoutConfig), Rate + Margin are secondaries at h=44.
        -- All three bind the same "label" slot that ldgKpiProfit/Rate/Margin already wire.
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "ldgKpiProfit", role = "section", size = { w = 200, h = 56 } },
            { type = "item", id = "ldgKpiRate",   size = { w = 170, h = 44 } },
            { type = "item", id = "ldgKpiMargin", size = { w = 170, h = 44 } },
            { type = "item", id = "ldgPriceSource", grow = true, size = { h = 56 } },
        } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "ldgSearch", grow = true, size = { h = 20 } },
            { type = "item", id = "ldgSort", size = { w = 130, h = 20 } },
        } },
        { type = "item", id = "ldgTable", grow = true },
    },
}

return ns.LayoutConfig
