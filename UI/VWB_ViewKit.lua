-- ============================================================================
-- VWB ViewKit - shared helpers for view controllers.
-- ============================================================================
-- The measure fn (natural-width for hug sizing) + the themed placeholder box
-- factory, shared so each view controller doesn't re-declare them. Loads after
-- Framework (needs VWB.UI:GetScheme). NOTE: Showroom_View + Recipes_View still
-- carry their own copies -- fold them onto this in a cleanup pass.
-- ============================================================================

VWB = VWB or {}
local Kit = {}
VWB.ViewKit = Kit

-- VWB.UI.BACKDROP_FLAT (Framework) is the canonical flat backdrop; local was a subset duplicate.
---@type backdropInfo
local BACKDROP = VWB.UI.BACKDROP_FLAT -- exception(false-positive): indirection loses type; value is backdropInfo

local measureFS
function Kit.measure(node)
    if not measureFS then local h = CreateFrame("Frame"); h:Hide(); measureFS = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") end
    measureFS:SetText(node.id or node.role or "")
    return { w = measureFS:GetUnboundedStringWidth() + 6, h = 14 }
end

-- Role-aware label widget -- the default renderer for a label-role item node
-- (title / section / label / body). Styled BY ROLE, so a title reads as a title
-- instead of the uniform dim box the old placeholder rendered for everything.
-- Provides `.label` (the view binds text to it after build) and registers with
-- the theme so it repaints on a theme switch.
local ROLE_FONT = { title = "GameFontNormalLarge", section = "GameFontNormal", body = "GameFontHighlightSmall" }
local ROLE_SKIN = { title = "HeaderLabel", section = "HeaderLabel" } -- others -> "Label"
function Kit.roleLabel(node, parent)
    local f = CreateFrame("Frame", nil, parent)
    local fs = f:CreateFontString(nil, "OVERLAY", ROLE_FONT[node.role] or "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 2, 0); fs:SetPoint("BOTTOMRIGHT", -2, 0)
    fs:SetJustifyH("LEFT"); fs:SetJustifyV("MIDDLE")
    fs:SetText(node.text or node.id or "") -- shown until the view binds real text; a genuinely unwired node shows its id
    f.label = fs
    VWB.Theme:Register(fs, ROLE_SKIN[node.role] or "Label")
    return f
end

-- The Layout engine's default factory (wired via Layout.setDefaultFactory), used
-- ONLY when a view's makeFrame returns nil for a node: a role-styled label for an
-- item slot, else a bare positioning frame for a layout container. There is NO
-- generic "placeholder" any more -- an item renders per its declared role, so an
-- unbound/incomplete node is visible (it shows its id) rather than hidden behind
-- a themed box. Chrome is applied separately by Layout (Kit.applyChrome).
function Kit.makeDefault(node, parent)
    if node.type == "item" then return Kit.roleLabel(node, parent) end
    return CreateFrame("Frame", nil, parent)
end

-- The chrome applier (wired via Layout.setChromeApplier). Layout calls this for
-- EVERY node carrying chrome="Role": give it the flat backdrop + register it so
-- the theme skinner colours it and it repaints on a theme switch. Chrome is
-- engine-applied layout metadata -- it never routes through the placeholder.
function Kit.applyChrome(frame, role)
    if not frame.SetBackdrop then -- exception(boundary): plain frames (makeDefault) have no SetBackdrop on 12.0; BackdropTemplateMixin adds it
        Mixin(frame, BackdropTemplateMixin)
        frame:OnBackdropLoaded()
    end
    frame:SetBackdrop(BACKDROP)
    VWB.Theme:Register(frame, role)
end
