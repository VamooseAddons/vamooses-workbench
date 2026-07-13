-- ============================================================================
-- VWB Settings - VIEW / controller. Slice: config (theme / priceSource /
-- materialsMode / showMinimapButton / ambientTooltips / debug / autoExpand /
-- applyAHCut / uiScale / bgOpacity) + Clear Queue / Hard Reset.
-- ============================================================================
-- The 7th nav tab: a port of VPC's Config tab onto VWB's Reactor + box-model
-- pattern (see LayoutConfig_Settings.lua for the row-by-row layout). Every
-- control here is a REAL widget wired straight to the Store. Nodes makeFrame
-- doesn't own return nil and the Layout engine renders them per role (there is
-- no placeholder any more).
--
-- Key-name deviations from VPC's own names, made deliberately to reuse
-- ALREADY-LIVE consumers instead of introducing a second, parallel, untested
-- config surface:
--   (fontScale was cut 2026-07-13: UI Scale already scales text; a second
--   font knob was redundant. The VWBFont* objects size from their Blizzard
--   twins -- see ThemeEngine's FONT OBJECTS block.)
--   * bgOpacity (not "windowAlpha") -- ThemeEngine's "Panel" skinner already
--     multiplies its marble-tint alpha by config.bgOpacity on every Panel-
--     registered widget across the whole addon. Transparency reuses that
--     rather than adding a second, competing window:SetAlpha() mechanism.
--   * uiScale keeps VPC's name for SavedVars continuity. UI Scale is applied
--     directly to the live window here: _G.VWB_Main, the global Shell.lua
--     names its frame, guaranteed to exist by the time Settings itself is
--     visible inside it.
--   * autoExpand -- new key, no consumer yet (inert until wired).
--
-- Reactive re-sync: every effect below subscribes ns.Store:Version("config")
-- (the per-slice signal), NOT the blanket ns.Store:Version() -- so this page
-- doesn't re-run its own widget syncs on unrelated crafting/recipe dispatches.
-- The two appearance sliders are the one exception: VWB.UI:CreateSlider
-- has no suppressCallbacks guard (unlike CreateFilterButtonRow's SetSelected),
-- and WoW's Slider:SetValue() re-fires OnValueChanged even when set
-- programmatically -- wiring a reactive SetValue would re-dispatch SET_CONFIG
-- from inside the effect that just read it. Nothing else writes
-- uiScale/bgOpacity today, so a build-time default (this task's literal
-- ask) is sufficient and safe; a real second writer would need the slider
-- widget itself to grow a suppress guard first.
--
-- Ambient Item Tooltips is fully wired (Modules/AmbientTooltips.lua reads
-- the flag at hover time; opt-in, default off): flipping it takes effect at
-- the next item hover. Auto-expand Sub-recipes still awaits its consumer --
-- the setting is not lost by flipping it early.
-- ============================================================================

local _, ns = ...
local Settings = ns.Settings or {}
ns.Settings = Settings

-- Display label for a price-source key whose own name is terse/internal.
-- Anything not listed renders under its own key ("TSM", "Auctionator").
local PRICE_SOURCE_LABELS = { TSMRegion = "TSM Region Sale Avg" }
local function PriceSourceLabel(key) return PRICE_SOURCE_LABELS[key] or key end

-- Plain themed row-label (Theme: / Price Source: / Materials Mode:) -- static
-- text, so no reactive binding; registering it as "Label" repaints it on a
-- theme switch. Needs a base font object template: RegisterWidget's skinner
-- (which sets the themed font) runs AFTER the SetText below, and SetText on a
-- font-less FontString errors "Font not set".
local function makeLabel(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    VWB.UI:RegisterWidget(fs, "Label")
    return fs
end

-- Clearing the queue kills every alt's plan in one click and has no undo --
-- it gets a confirm, same as any other destroy-everything action. First
-- StaticPopupDialog in VWB (VPC's Config.lua is the reference for both).
StaticPopupDialogs["VWB_CONFIRM_CLEAR_QUEUE"] = {
    text = "Clear the entire crafting queue? Every character's planned crafts go with it.",
    button1 = "Clear Queue",
    button2 = "Cancel",
    OnAccept = function()
        ns.Store:Dispatch("CLEAR_QUEUE")
        VWB.Log:Print("Crafting queue cleared.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Full account-wide reset. VWB.Store has no debounced save/Flush to race
-- (its state tables ARE VWB_DB tables by reference, no separate save timer
-- like VPC's Core/Store.lua) -- so unlike VPC:HardReset(), no suppressSave
-- flag or Store method is needed; wiping the SavedVariable and reloading is
-- self-contained here.
StaticPopupDialogs["VWB_CONFIRM_HARD_RESET"] = {
    text = "This wipes ALL Workbench data - recipes, queue, characters, settings - and reloads the UI. No undo.",
    button1 = "Hard Reset",
    button2 = "Cancel",
    OnAccept = function()
        VWB_DB = {}
        C_UI.Reload()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function Settings.buildView(container)
    local R = ns.Reactor
    local Kit = ns.ViewKit

    local themePicker, fontPicker, pricePicker, minimapCb, ambientCb
    local debugCb, ahCutCb, pslRemoveCb
    local uiScaleStepper, transparencyStepper
    local dangerHeader, dangerDesc

    local function makeFrame(node, parent)
        if node.id == "setThemeLabel" then
            return makeLabel(parent, "Theme:")
        elseif node.id == "setThemePicker" then
            themePicker = VWB.UI:CreateDropdown(parent, {
                width = (node.size and node.size.w) or 200, height = (node.size and node.size.h) or 22,
                onSelect = function(key, data)
                    ns.Store:Dispatch("SET_CONFIG", { key = "theme", value = key })
                    local themeName = VWB.Constants.ThemeNames[key] or "SolarizedDark"
                    VWB.EventBus:Trigger("VWB_THEME_UPDATE", { themeName = themeName })
                    VWB.Log:Print("Theme: " .. (data.label or key))
                end,
            })
            local items = {}
            for _, key in ipairs(VWB.Constants.ThemeOrder) do
                items[#items + 1] = { key = key, label = VWB.Constants.ThemeDisplayNames[key] or key }
            end
            themePicker:SetItems(items)
            return themePicker
        elseif node.id == "setFontLabel" then
            return makeLabel(parent, "Font:")
        elseif node.id == "setFontPicker" then
            fontPicker = VWB.UI:CreateDropdown(parent, {
                width = (node.size and node.size.w) or 200, height = (node.size and node.size.h) or 22,
                onSelect = function(key, data)
                    ns.Store:Dispatch("SET_CONFIG", { key = "fontFamily", value = key })
                    VWB.EventBus:Trigger("VWB_THEME_UPDATE", {}) -- ApplyFontObjects re-fonts every VWBFont* string live
                    VWB.Log:Print("Font: " .. (data.label or key))
                end,
            })
            local items = {}
            for _, key in ipairs(VWB.Constants.FontOrder) do
                items[#items + 1] = { key = key, label = VWB.Constants.FontDisplayNames[key] or key }
            end
            fontPicker:SetItems(items)
            return fontPicker
        elseif node.id == "setPriceLabel" then
            return makeLabel(parent, "Price Source:")
        elseif node.id == "setPricePicker" then
            pricePicker = VWB.UI:CreateDropdown(parent, {
                width = (node.size and node.size.w) or 200, height = (node.size and node.size.h) or 22,
                onSelect = function(key, data)
                    local value = (key ~= "__auto") and key or nil
                    ns.Store:Dispatch("SET_CONFIG", { key = "priceSource", value = value })
                    VWB.PriceIntegration:InvalidateCache() -- old source's cached prices are stale under the new pin
                    VWB.Log:Print("Price source: " .. (data.label or "Auto"))
                end,
            })
            local items = { { key = "__auto", label = "Auto" } }
            for _, src in ipairs(VWB.PriceIntegration:GetAvailableSources()) do
                items[#items + 1] = { key = src, label = PriceSourceLabel(src) }
            end
            pricePicker:SetItems(items)
            return pricePicker
        elseif node.id == "setUiScaleLabel" then
            return makeLabel(parent, "UI Scale:")
        elseif node.id == "setUiScaleStepper" then
            uiScaleStepper = VWB.UI:CreateStepper(parent, {
                width = (node.size and node.size.w) or 120,
                min = 0.8, max = 1.4, step = 0.1,
                default = ns.Store:GetState().config.uiScale or 1.0, -- exception(optional): unset until the user first steps it
                format = function(v) return string.format("%.0f%%", v * 100) end,
                onChange = function(value)
                    ns.Store:Dispatch("SET_CONFIG", { key = "uiScale", value = value })
                    -- Shell.lua names the window frame "VWB_Main" -- the only
                    -- live handle to it, guaranteed to exist here.
                    _G.VWB_Main:SetScale(value)
                end,
            })
            return uiScaleStepper
        elseif node.id == "setTransparencyLabel" then
            return makeLabel(parent, "Transparency:")
        elseif node.id == "setTransparencyStepper" then
            transparencyStepper = VWB.UI:CreateStepper(parent, {
                width = (node.size and node.size.w) or 120,
                min = 0.3, max = 1.0, step = 0.1,
                default = ns.Store:GetState().config.bgOpacity or 0.9, -- exception(optional): unset until the user first steps it
                format = function(v) return string.format("%.0f%%", v * 100) end,
                onChange = function(value)
                    ns.Store:Dispatch("SET_CONFIG", { key = "bgOpacity", value = value })
                    VWB.EventBus:Trigger("VWB_THEME_UPDATE", {}) -- re-skins every Panel-registered widget at the new opacity
                end,
            })
            return transparencyStepper
        elseif node.id == "setMinimapCb" then
            minimapCb = VWB.UI:CreateCheckbox(parent, "Show Minimap Button", function(checked)
                ns.Store:Dispatch("SET_CONFIG", { key = "showMinimapButton", value = checked })
                VWB.Minimap:UpdateVisibility()
            end)
            return minimapCb
        elseif node.id == "setAmbientCb" then
            ambientCb = VWB.UI:CreateCheckbox(parent, "Ambient Item Tooltips", function(checked)
                ns.Store:Dispatch("SET_CONFIG", { key = "ambientTooltips", value = checked })
            end)
            ambientCb.button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Add Workbench lines to item tooltips everywhere -- queue needs on reagents, craftable-by on crafted items.", 1, 1, 1, 1, true)
                GameTooltip:AddLine("Off by default.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            ambientCb.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return ambientCb
        elseif node.id == "setDebugCb" then
            debugCb = VWB.UI:CreateCheckbox(parent, "Debug Mode", function(checked)
                ns.Store:Dispatch("SET_CONFIG", { key = "debug", value = checked })
            end)
            debugCb.button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Enable verbose logging to chat for troubleshooting.", 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            debugCb.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return debugCb
        elseif node.id == "setAhCutCb" then
            ahCutCb = VWB.UI:CreateCheckbox(parent, "Subtract Auction House Cut", function(checked)
                ns.Store:Dispatch("SET_CONFIG", { key = "applyAHCut", value = checked })
            end)
            ahCutCb.button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Ledger profits subtract the 5% AH consignment cut. Turn off to see gross sale value instead.", 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            ahCutCb.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return ahCutCb
        elseif node.id == "setPslRemoveCb" then
            pslRemoveCb = VWB.UI:CreateCheckbox(parent, "Remove from queue when removed in PSL", function(checked)
                ns.Store:Dispatch("SET_CONFIG", { key = "pslAutoRemove", value = checked })
            end)
            pslRemoveCb.button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("When you remove or finish crafting a recipe in Profession Shopping List, drop it from the Workbench queue too.", 1, 1, 1, 1, true)
                GameTooltip:AddLine("One-way: adding/tracking in PSL does not add here. Needs Profession Shopping List installed.", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            pslRemoveCb.button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return pslRemoveCb
        elseif node.id == "setClearQueueBtn" then
            local btn = VWB.UI:CreateButton(parent, "Clear Queue", (node.size and node.size.w) or 150, (node.size and node.size.h) or 22)
            btn:SetScript("OnClick", function()
                if #ns.Store:GetState().crafting.queuedRecipes == 0 then
                    VWB.Log:Print("The queue is already empty.")
                    return
                end
                StaticPopup_Show("VWB_CONFIRM_CLEAR_QUEUE")
            end)
            return btn
        elseif node.id == "setRefreshTransmogBtn" then
            local btn = VWB.UI:CreateButton(parent, "Refresh Transmog Cache", (node.size and node.size.w) or 170, (node.size and node.size.h) or 22)
            btn:SetScript("OnClick", function()
                -- Constitution R5 human escape hatch: drops derived statuses
                -- and nudges the epoch so every walker re-derives from latches.
                VWB.Transmog:RefreshAll()
                VWB.Log:Print("Transmog cache cleared.")
            end)
            return btn
        elseif node.id == "setDangerDivider" then
            return VWB.UI:CreateDivider(parent)
        elseif node.id == "setDangerHeader" then
            dangerHeader = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalLarge")
            dangerHeader:SetJustifyH("LEFT")
            dangerHeader:SetText(VWB.UI:ColorCode("red") .. "Danger Zone|r")
            return dangerHeader
        elseif node.id == "setDangerDesc" then
            dangerDesc = parent:CreateFontString(nil, "OVERLAY", "VWBFontNormalSmall")
            dangerDesc:SetJustifyH("LEFT")
            dangerDesc:SetText(VWB.UI:ColorCode("base01") ..
                "Wipes every recipe, queue, character, and setting the Workbench has on file, then reloads the UI. There is no undo.|r")
            return dangerDesc
        elseif node.id == "setDangerBtn" then
            -- Styled as destructive via the DangerButton skinner (already in
            -- UI/ThemeEngine.lua, ported from VPC); OnEnter/OnLeave overridden
            -- so CreateButton's own hover handlers don't flip it back to
            -- normal button colors. flat: the ONE exception to the tertiary
            -- button unification -- the danger treatment owns its backdrop.
            local btn = VWB.UI:CreateButton(parent, "Hard Reset", (node.size and node.size.w) or 140, (node.size and node.size.h) or 26, { flat = true })
            btn:SetScript("OnEnter", function(self)
                local c = VWB.UI:GetScheme()
                self:SetBackdropColor(c.error.r, c.error.g, c.error.b, c.error.a)
            end)
            btn:SetScript("OnLeave", function(self)
                local c = VWB.UI:GetScheme()
                self:SetBackdropColor(c.error.r * 0.55, c.error.g * 0.55, c.error.b * 0.55, c.error.a)
            end)
            btn:SetScript("OnClick", function() StaticPopup_Show("VWB_CONFIRM_HARD_RESET") end)
            VWB.Theme:Register(btn, "DangerButton")
            return btn
        elseif node.id == "setVersion" then
            local fs = parent:CreateFontString(nil, "OVERLAY", "VWBFontDisableSmall") -- base font: SetText below precedes the DimLabel skinner
            fs:SetJustifyH("LEFT")
            local version = C_AddOns.GetAddOnMetadata("VamoosesWorkbench", "Version") or "Dev"
            fs:SetText("Vamoose's Workbench  v" .. version)
            VWB.UI:RegisterWidget(fs, "DimLabel")
            return fs
        elseif node.id == "setAppearanceHeader" then
            return VWB.UI:CreateSectionHeader(parent, { text = "Appearance", height = (node.size and node.size.h) or 16 })
        elseif node.id == "setBehaviorHeader" then
            return VWB.UI:CreateSectionHeader(parent, { text = "Behavior", height = (node.size and node.size.h) or 16 })
        elseif node.id == "setDataHeader" then
            return VWB.UI:CreateSectionHeader(parent, { text = "Data", height = (node.size and node.size.h) or 16 })
        end
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.settings, { makeFrame = makeFrame, measure = Kit.measure })

    -- setTitle is a genuinely static string -- set once, not wrapped in a
    -- Reactor binding that would never re-fire.
    handle.byId.setTitle.label:SetText("Settings")

    -- Every effect below reads only state.config, so each subscribes the
    -- "config" slice signal, not the blanket one -- an unrelated crafting/
    -- recipe dispatch elsewhere in the addon no longer re-runs this page's
    -- widget syncs.
    R.effect(function()
        ns.Store:Version("config")
        local key = ns.Store:GetState().config.theme or "solarizeddark" -- exception(optional): unset until the user first picks/toggles a theme
        themePicker:SetSelected(key, { label = VWB.Constants.ThemeDisplayNames[key] or key })
    end, "settings:theme")

    R.effect(function()
        ns.Store:Version("config")
        local key = ns.Store:GetState().config.fontFamily or "FRIZQT__" -- exception(optional): unset until the user first picks a font
        fontPicker:SetSelected(key, { label = VWB.Constants.FontDisplayNames[key] or key })
    end, "settings:font")

    R.effect(function()
        ns.Store:Version("config")
        local key = ns.Store:GetState().config.priceSource -- exception(nullable): nil IS "Auto" (unpinned), not drift
        pricePicker:SetSelected(key or "__auto", { label = key and PriceSourceLabel(key) or "Auto" })
    end, "settings:priceSource")

    R.effect(function()
        ns.Store:Version("config")
        minimapCb:SetChecked(ns.Store:GetState().config.showMinimapButton ~= false) -- exception(optional): unset means shown, mirrors UI/Minimap.lua's own gate
    end, "settings:minimap")

    R.effect(function()
        ns.Store:Version("config")
        ambientCb:SetChecked(ns.Store:GetState().config.ambientTooltips) -- opt-in: Store seeds false, mirrors AmbientTooltips.lua gate
    end, "settings:ambient")

    R.effect(function()
        ns.Store:Version("config")
        debugCb:SetChecked(ns.Store:GetState().config.debug) -- nil IS the off default, not drift
    end, "settings:debug")

    R.effect(function()
        ns.Store:Version("config")
        ahCutCb:SetChecked(ns.Store:GetState().config.applyAHCut) -- nil IS the off default, not drift
    end, "settings:ahCut")

    R.effect(function()
        ns.Store:Version("config")
        pslRemoveCb:SetChecked(ns.Store:GetState().config.pslAutoRemove) -- nil IS the off default, not drift
    end, "settings:pslRemove")

    -- No reactive re-sync for the UI Scale / Transparency steppers: nothing
    -- else writes uiScale/bgOpacity today, so the build-time default passed to
    -- CreateStepper is sufficient. (CreateStepper:SetValue doesn't re-fire
    -- onChange, so a re-sync would be safe here if a second writer ever lands.)

    -- ColorCode() bakes a hex value into the string at call time, so unlike
    -- the registry-skinned widgets above, these two need a manual repaint on
    -- theme switch (same reason VPC's Config.lua carries the same handler).
    VWB.EventBus:Register("VWB_THEME_UPDATE", function()
        dangerHeader:SetText(VWB.UI:ColorCode("red") .. "Danger Zone|r")
        dangerDesc:SetText(VWB.UI:ColorCode("base01") ..
            "Wipes every recipe, queue, character, and setting the Workbench has on file, then reloads the UI. There is no undo.|r")
    end)

    return handle
end

return Settings
