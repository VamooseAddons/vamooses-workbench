-- ============================================================================
-- VamoosesWorkbench - VWB.UI.Tooltip
-- The addon's own hover surface. Item hovers do NOT go through GameTooltip:
-- SetHyperlink on equippable items spawns Blizzard's "always compare items"
-- ShoppingTooltips (two full equipped-item panels), burying this addon's own
-- data under combat stat blocks. This frame renders only what we choose.
--
-- The append API is GameTooltip-compatible (AddLine / AddDoubleLine / Show /
-- IsShown) so modules like GuildCrafters can write to either surface.
-- Flow: Begin(owner) -> SetItemHeader/AddTitle/AddLine/AddDoubleLine -> Show().
-- Late appends after Show() (guild-crafters fill-in) re-Show() to re-layout.
-- ============================================================================

VWB = VWB or {}
VWB.UI = VWB.UI or {}

local PAD = 10
local LINE_GAP = 2
local MAX_WIDTH = 340
local MIN_WIDTH = 120

local Tooltip = {}
VWB.UI.Tooltip = Tooltip

local frame          -- lazy singleton
local lines = {}     -- [i] = { left = FS, right = FS, hasRight = bool }
local used = 0
local owner = nil

local function EnsureFrame()
    if frame then return end
    frame = CreateFrame("Frame", "VWB_Tooltip", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("TOOLTIP")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(false)
    frame:SetBackdrop(VWB.UI.BACKDROP_PANEL)
    frame:Hide()
    -- Pooled rows can scroll out from under the cursor without OnLeave firing;
    -- watch the owner and drop the tooltip when the cursor is no longer on it.
    frame:SetScript("OnUpdate", function(self, elapsed)
        self._t = (self._t or 0) + elapsed
        if self._t < 0.2 then return end
        self._t = 0
        if not owner or not owner:IsVisible() or not owner:IsMouseOver() then
            Tooltip:Hide()
        end
    end)
end

local function AcquireLine(i)
    local L = lines[i]
    if not L then
        L = {
            left = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall"),
            right = frame:CreateFontString(nil, "OVERLAY", "VWBFontHighlightSmall"),
        }
        L.left:SetJustifyH("LEFT")
        L.right:SetJustifyH("RIGHT")
        lines[i] = L
    end
    L.left:SetFontObject("VWBFontHighlightSmall")
    L.left:SetText("")
    L.right:SetText("")
    L.hasRight = false
    L.left:Show()
    L.right:Hide()
    return L
end

function Tooltip:Begin(ownerFrame, anchor)
    EnsureFrame()
    owner = ownerFrame
    self._anchor = anchor or "RIGHT"
    used = 0
    for i = 1, #lines do
        lines[i].left:Hide()
        lines[i].right:Hide()
    end
end

function Tooltip:IsOwned(f)
    return owner == f
end

function Tooltip:IsShown()
    return frame ~= nil and frame:IsShown()
end

-- GameTooltip-compatible: current line count. Pairs with TruncateTo so an
-- async fill-in can snapshot, then roll back a placeholder block.
function Tooltip:GetNumLines()
    return used
end

-- Roll the tooltip back to n lines (our extension -- GameTooltip can't remove
-- lines). Callers re-Show() after appending the replacement block.
function Tooltip:TruncateTo(n)
    for i = n + 1, used do
        lines[i].left:Hide()
        lines[i].right:Hide()
    end
    if n < used then used = n end
end

-- GameTooltip-compatible: AddLine(text, r, g, b). Text carrying its own |cFF
-- codes wins over the fontstring color, exactly like GameTooltip.
function Tooltip:AddLine(text, r, g, b)
    used = used + 1
    local L = AcquireLine(used)
    L.left:SetText(text or " ")
    if type(r) == "number" then
        L.left:SetTextColor(r, g or 1, b or 1)
    else
        local c = VWB.UI:GetScheme().text
        L.left:SetTextColor(c.r, c.g, c.b)
    end
end

-- GameTooltip-compatible: AddDoubleLine(left, right, lr,lg,lb, rr,rg,rb)
function Tooltip:AddDoubleLine(leftText, rightText, lr, lg, lb, rr, rg, rb)
    used = used + 1
    local L = AcquireLine(used)
    L.hasRight = true
    L.left:SetText(leftText or "")
    L.right:SetText(rightText or "")
    L.right:Show()
    local c = VWB.UI:GetScheme().text
    L.left:SetTextColor(lr or c.r, lg or c.g, lb or c.b)
    L.right:SetTextColor(rr or c.r, rg or c.g, rb or c.b)
end

function Tooltip:AddTitle(text, r, g, b)
    used = used + 1
    local L = AcquireLine(used)
    L.left:SetFontObject("VWBFontNormal")
    L.left:SetText(text or "")
    if type(r) == "number" then
        L.left:SetTextColor(r, g or 1, b or 1)
    else
        local c = VWB.UI:GetScheme().text
        L.left:SetTextColor(c.r, c.g, c.b)
    end
end

-- Icon (inline |T markup) + quality-colored name + dim itemID line. Callers
-- own name resolution -- nil name renders "Loading..." and the caller's next
-- repaint re-hovers with the real one.
function Tooltip:SetItemHeader(itemID, name, quality)
    local icon = C_Item.GetItemIconByID(itemID) or 134400 -- exception(boundary): question-mark icon for uncached/invalid items
    local qr, qg, qb
    if quality then
        qr, qg, qb = C_Item.GetItemQualityColor(quality)
    end
    self:AddTitle("|T" .. icon .. ":18|t " .. (name or "Loading..."), qr, qg, qb)
    if itemID then self:AddLine(VWB.UI:ColorCode("base01") .. "#" .. itemID .. "|r") end -- exception(boundary): recipes with no output item (enchants) have nil itemID
end

function Tooltip:Show()
    if used == 0 or not owner then return end
    local scheme = VWB.UI:GetScheme()
    frame:SetBackdropColor(scheme.bg.r, scheme.bg.g, scheme.bg.b, 0.97)
    frame:SetBackdropBorderColor(scheme.border.r, scheme.border.g, scheme.border.b, 1)

    -- Pass 1: natural widths decide the frame width (clamped)
    local w = MIN_WIDTH
    for i = 1, used do
        local L = lines[i]
        L.left:SetWordWrap(false)
        L.left:SetWidth(0)
        local lw = L.left:GetUnboundedStringWidth()
        if L.hasRight then
            lw = lw + 20 + L.right:GetUnboundedStringWidth()
        end
        if lw > w then w = lw end
    end
    if w > MAX_WIDTH then w = MAX_WIDTH end

    -- Pass 2: stack lines top-down; single-column lines word-wrap into the
    -- clamped width so nothing truncates silently
    local y = -PAD
    for i = 1, used do
        local L = lines[i]
        L.left:ClearAllPoints()
        L.left:SetPoint("TOPLEFT", PAD, y)
        if L.hasRight then
            L.right:ClearAllPoints()
            L.right:SetPoint("TOPRIGHT", -PAD, y)
            L.left:SetWidth(w - 20 - L.right:GetUnboundedStringWidth())
        else
            L.left:SetWordWrap(true)
            L.left:SetWidth(w)
        end
        local h = L.left:GetStringHeight()
        if h < 10 then h = 10 end
        y = y - h - LINE_GAP
    end

    frame:SetSize(w + PAD * 2, -y + PAD - LINE_GAP)
    frame:ClearAllPoints()
    if self._anchor == "BOTTOM" then
        frame:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -4)
    else
        frame:SetPoint("TOPLEFT", owner, "TOPRIGHT", 8, 0)
    end
    frame:Show()
end

-- Hide(ownerFrame): only hides if that frame still owns the tooltip -- a late
-- OnLeave from a row you already left must not kill the tooltip a new row
-- just opened. Hide() with no argument force-hides.
function Tooltip:Hide(ownerFrame)
    if ownerFrame and owner ~= ownerFrame then return end
    owner = nil
    if frame then frame:Hide() end
end
