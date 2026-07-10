VWB = VWB or {}
VWB.AmbientTooltips = {}

-- ============================================================================
-- VamoosesWorkbench - AmbientTooltips
-- Additive GameTooltip lines on item hovers ANYWHERE (bags, bank, AH, chat
-- links) -- the addon's knowledge follows the cursor out of its own window:
--   * reagent the queue still needs  -> "needed for queue: N (have M)"
--   * item craftable per the store   -> "craftable by <chars>" (+ uncollected
--     decor flag when the housing catalog says so)
-- Effect-focused and at most two lines; silent for items VWB knows nothing
-- about. Config-gated on config.ambientTooltips (only an explicit false
-- disables, so the gate works before the Settings toggle writes the key).
-- Our own VWB.UI.Tooltip surface is not GameTooltip, so in-window hovers
-- never double up.
-- ============================================================================

local MAX_NAMED_CRAFTERS = 3
local PREFIX = "|cff2aa198Power Crafter:|r "

-- Shopping-list entries repeat per queued recipe that needs the item; merge
-- to one need/have pair. The list is small -- a per-hover scan is cheap.
local function QueueNeedFor(itemID)
    local required, owned
    for _, item in ipairs(VWB.Store:GetState().crafting.shoppingList) do
        if item.itemID == itemID then
            required = (required or 0) + item.required
            owned = math.max(owned or 0, item.owned)
        end
    end
    return required, owned
end

local function CraftersText(itemID)
    local recipeID = VWB.Database:GetRecipeByItemID(itemID)
    if not recipeID then return nil end -- exception(nullable): most hovered items are not store outputs

    local names = VWB.KnownRecipes:KnownByList(recipeID)
    if #names == 0 then return "in the recipe book (no scanned character knows it)" end

    local shown = {}
    for i = 1, math.min(#names, MAX_NAMED_CRAFTERS) do
        shown[i] = names[i]
    end
    local text = "craftable by " .. table.concat(shown, ", ")
    if #names > MAX_NAMED_CRAFTERS then
        text = text .. string.format(" (+%d more)", #names - MAX_NAMED_CRAFTERS)
    end
    return text
end

local function OnItemTooltip(tooltip, data)
    if tooltip ~= _G.GameTooltip then return end -- exception(boundary): post-call fires for every tooltip frame incl. shopping tooltips
    if VWB.Store:GetState().config.ambientTooltips == false then return end
    local itemID = data and data.id -- exception(boundary): tooltip payload can lack an item id (e.g. currency-ish tooltips)
    if not itemID then return end

    local required, owned = QueueNeedFor(itemID)
    if required then
        local color = (owned >= required) and "|cff859900" or "|cffb58900"
        tooltip:AddLine(PREFIX .. string.format("needed for queue: %s%d|r (have %s%d|r)",
            color, required, color, owned))
    end

    local crafters = CraftersText(itemID)
    if crafters then
        if VWB.DecorOwnership:IsUncollected(itemID) == true then
            crafters = crafters .. " |cffdc322f- uncollected decor|r"
        end
        tooltip:AddLine(PREFIX .. crafters)
    end
end

-- Registered at file load: the hook itself needs no addon state (handlers
-- strict-read at hover time, which cannot precede ADDON_LOADED), and load-time
-- registration keeps this module wiring-free.
_G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Item, OnItemTooltip)
