-- ============================================================================
-- VamoosesWorkbench - Minimap Button & Addon Compartment
-- ============================================================================

VWB = VWB or {}
VWB.Minimap = {}

local minimapButton = nil
local ICON = "Interface/Icons/Trade_Engineering"

-- ============================================================================
-- MINIMAP SHAPE DETECTION
-- ============================================================================

local function IsMinimapSquare()
    if GetMinimapShape then return GetMinimapShape() == "SQUARE" end
    if SexyMapCustomBackdrop or BasicMinimapSquare then return true end
    return false
end

local function GetPosition(angle, isSquare)
    local rad = math.rad(angle)
    local x, y = math.cos(rad), math.sin(rad)
    if isSquare then
        local half = 80
        local maxC = math.max(math.abs(x), math.abs(y))
        if maxC > 0 then x, y = (x / maxC) * half, (y / maxC) * half end
    else
        x, y = x * 95, y * 95
    end
    return x, y
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function VWB.Minimap:Initialize()
    -- Create minimap button
    minimapButton = CreateFrame("Button", "VamoosesWorkbenchMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Icon
    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(ICON)
    minimapButton.icon = icon

    -- Border
    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(52, 52)
    overlay:SetPoint("TOPLEFT", 0, 0)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Click
    minimapButton:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            VWB:ToggleWindow()
        elseif button == "RightButton" then
            -- Right-click: quick menu via MenuUtil
            if MenuUtil and MenuUtil.CreateContextMenu then
                MenuUtil.CreateContextMenu(minimapButton, function(_, rootDescription)
                    rootDescription:CreateTitle("Vamoose's Workbench")
                    rootDescription:CreateButton("Open Window", function() VWB:ToggleWindow() end)
                    rootDescription:CreateButton("Records", function()
                        if not (VWB.MainFrame and VWB.MainFrame:IsShown()) then VWB:ToggleWindow() end
                        VWB:ShowPage("data")
                    end)
                    rootDescription:CreateButton("Toggle Theme", function()
                        local newTheme = VWB.Constants:ToggleTheme()
                        local themeName = VWB.Constants.ThemeNames[newTheme] or "SolarizedDark"
                        VWB.EventBus:Trigger("VWB_THEME_UPDATE", { themeName = themeName })
                    end)
                    rootDescription:CreateDivider()
                    rootDescription:CreateButton("Hide Button", function()
                        VWB.Store:Dispatch("SET_CONFIG", { key = "showMinimapButton", value = false })
                        VWB.Minimap:UpdateVisibility()
                    end)
                end)
            end
        end
    end)

    -- Drag (only save position on DragStop, not every frame)
    minimapButton:SetScript("OnDragStart", function(self)
        local cfg = VWB.Store:GetState().minimap
        if not (cfg and cfg.lock) then
            self:SetScript("OnUpdate", function()
                VWB.Minimap:OnDragUpdate()
            end)
        end
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        VWB.Minimap:OnDragStop()
    end)

    -- Tooltip
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cFF2aa198Vamoose's Workbench|r", 1, 1, 1)
        GameTooltip:AddLine("|cFFFFFFFFLeft-click:|r Toggle window", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("|cFFFFFFFFRight-click:|r Options", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("|cFFFFFFFFDrag:|r Move button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self:UpdatePosition()
    self:UpdateVisibility()
    self:RegisterLDB()
end

-- ============================================================================
-- POSITION & VISIBILITY
-- ============================================================================

local dragAngle = nil

function VWB.Minimap:OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    dragAngle = math.deg(math.atan2(py - my, px - mx))

    -- Update visual position immediately, but don't dispatch to Store every frame
    if minimapButton then
        minimapButton:ClearAllPoints()
        local x, y = GetPosition(dragAngle, IsMinimapSquare())
        minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
end

function VWB.Minimap:OnDragStop()
    if dragAngle then
        VWB.Store:Dispatch("SET_MINIMAP_POS", { angle = dragAngle })
        dragAngle = nil
    end
end

function VWB.Minimap:UpdatePosition()
    if not minimapButton then return end
    minimapButton:ClearAllPoints()
    local state = VWB.Store:GetState()
    local angle = state and state.minimap and state.minimap.minimapPos or 220 -- matches Store DEFAULT_STATE
    local x, y = GetPosition(angle, IsMinimapSquare())
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function VWB.Minimap:UpdateVisibility()
    if not minimapButton then return end
    local state = VWB.Store:GetState()
    local show = state and state.config and state.config.showMinimapButton
    if show == false then
        minimapButton:Hide()
    else
        minimapButton:Show()
    end
end

function VWB.Minimap:Show()
    VWB.Store:Dispatch("SET_CONFIG", { key = "showMinimapButton", value = true })
    self:UpdateVisibility()
end

function VWB.Minimap:Hide()
    VWB.Store:Dispatch("SET_CONFIG", { key = "showMinimapButton", value = false })
    self:UpdateVisibility()
end

function VWB.Minimap:Toggle()
    if minimapButton and minimapButton:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

-- ============================================================================
-- ADDON COMPARTMENT
-- ============================================================================

-- Registered via TOC AddonCompartmentFunc directives, not Lua RegisterAddon:
-- RegisterAddon is non-idempotent and duplicates entries the day a LibDBIcon-
-- style library reads a show-in-compartment flag (VE's CurseForge bug 8049631)
function VWB_OnAddonCompartmentClick()
    VWB:ToggleWindow()
end

function VWB_OnAddonCompartmentEnter(_, menuItem)
    GameTooltip:SetOwner(menuItem, "ANCHOR_RIGHT")
    GameTooltip:AddLine("|cFF2aa198Vamoose's Workbench|r", 1, 1, 1)
    GameTooltip:AddLine("Plans your crafts, tallies your margins, and keeps every alt's trade skills straight.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cFFFFFFFFClick:|r Toggle window", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function VWB_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- ============================================================================
-- LDB (LibDataBroker) LAUNCHER
-- ============================================================================

function VWB.Minimap:RegisterLDB()
    if not LibStub then return end -- exception(boundary): LibStub only exists when another addon embeds it
    local LDB = LibStub("LibDataBroker-1.1", true) -- silent flag: nil when absent, no error
    if not LDB then return end

    LDB:NewDataObject("VamoosesWorkbench", {
        type = "launcher",
        text = "Workbench",
        icon = ICON,
        OnClick = function(_, button)
            if button == "LeftButton" then
                VWB:ToggleWindow()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("|cFF2aa198Vamoose's Workbench|r")
            tt:AddLine("|cFFFFFFFFClick:|r Toggle window", 0.7, 0.7, 0.7)
        end,
    })
end
