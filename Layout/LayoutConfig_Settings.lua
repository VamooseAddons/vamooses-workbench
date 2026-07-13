-- ============================================================================
-- VWB LayoutConfig - Settings view, as DATA (box model v2)
-- ============================================================================
-- The 7th nav tab, extended toward parity with VPC's Config tab: theme, price
-- source, materials mode, two appearance sliders (UI scale / transparency),
-- the minimap + ambient-tooltips toggles, two behavior toggles (debug,
-- subtract AH cut), a Data section
-- (Clear Queue + Refresh Transmog Cache), an isolated Danger Zone (Hard
-- Reset), and a version/about line. Both destructive actions (Clear Queue,
-- Hard Reset) are confirm-gated in Settings_View.lua's StaticPopupDialogs.
--
--   +----------------------------------------------------------+
--   | Settings (title)                                         | 24
--   | Appearance ------------------------------------------------ | 16
--   | Theme:            [dropdown]                              | 22
--   | Price Source:      [dropdown]                              | 22
--   | Materials Mode:     [Raw|Direct]                            | 22
--   | UI Scale                                          100%     | 40 (slider)
--   | Transparency                                       90%     | 40 (slider)
--   | Behavior --------------------------------------------------- | 16
--   | [ ] Show Minimap Button                                    | 24
--   | [ ] Ambient Item Tooltips                                  | 24
--   | [ ] Debug Mode                                             | 24
--   | [ ] Subtract Auction House Cut                             | 24
--   | Data ------------------------------------------------------- | 16
--   | [Clear Queue] [Refresh Transmog Cache]                     | 22
--   | -------------------------------------------------------------| 8
--   | Danger Zone (red)                                          | 22
--   | Wipes everything on file, then reloads the UI...           | 34
--   | [Hard Reset]                                               | 26
--   | Vamoose's Workbench vX.Y.Z                                 | 20
--   +----------------------------------------------------------+
-- ============================================================================

local _, ns = ...
ns = ns or {}
ns.LayoutConfig = ns.LayoutConfig or {}

local LABEL_W = 140 -- shared left column so Theme/Price Source/Materials Mode rows line up

ns.LayoutConfig.settings = {
    type = "stack", dir = "col", gap = "sm", padding = 4, align = "stretch", chrome = "Panel",
    children = {
        { type = "item", id = "setTitle", role = "title", size = { h = 20 } },

        { type = "item", id = "setAppearanceHeader", role = "section", size = { h = 16 } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "setThemeLabel", size = { w = LABEL_W, h = 22 } },
            { type = "item", id = "setThemePicker", size = { w = 200, h = 22 } },
        } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "setFontLabel", size = { w = LABEL_W, h = 22 } },
            { type = "item", id = "setFontPicker", size = { w = 200, h = 22 } },
        } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "setPriceLabel", size = { w = LABEL_W, h = 22 } },
            { type = "item", id = "setPricePicker", size = { w = 200, h = 22 } },
        } },
        -- UI Scale / Transparency as compact label + [-] value [+] steppers
        -- (owner 2026-07-13: the full-width slider rails were oversized for a
        -- small range). Same label + control shape as the Theme/Font rows.
        -- (Materials Mode removed -- it's a Workbench-only concept and the
        -- Workbench already carries its own Direct/Raw toggle.)
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "setUiScaleLabel", size = { w = LABEL_W, h = 22 } },
            { type = "item", id = "setUiScaleStepper", size = { w = 120, h = 22 } },
        } },
        { type = "stack", dir = "row", gap = "sm", align = "center", children = {
            { type = "item", id = "setTransparencyLabel", size = { w = LABEL_W, h = 22 } },
            { type = "item", id = "setTransparencyStepper", size = { w = 120, h = 22 } },
        } },

        { type = "item", id = "setBehaviorHeader", role = "section", size = { h = 16 } },
        { type = "item", id = "setMinimapCb", size = { h = 24 } },
        { type = "item", id = "setAmbientCb", size = { h = 24 } },
        { type = "item", id = "setDebugCb", size = { h = 24 } },
        { type = "item", id = "setAhCutCb", size = { h = 24 } },
        { type = "item", id = "setPslRemoveCb", size = { h = 24 } },

        { type = "item", id = "setDataHeader", role = "section", size = { h = 16 } },
        { type = "stack", dir = "row", gap = "sm", justify = "start", align = "center", children = {
            { type = "item", id = "setClearQueueBtn", size = { w = 150, h = 22 } },
            { type = "item", id = "setRefreshTransmogBtn", size = { w = 170, h = 22 } },
        } },

        -- Danger Zone: isolated at the bottom behind its own divider, same as
        -- VPC's Data & Maintenance page.
        { type = "item", id = "setDangerDivider", size = { h = 8 } },
        { type = "item", id = "setDangerHeader", size = { h = 22 } },
        { type = "item", id = "setDangerDesc", role = "body", size = { h = 34 } },
        { type = "stack", dir = "row", gap = "sm", justify = "start", align = "center", children = {
            { type = "item", id = "setDangerBtn", size = { w = 140, h = 26 } },
        } },

        { type = "item", id = "setVersion", role = "label", size = { h = 20 } },
    },
}

return ns.LayoutConfig
