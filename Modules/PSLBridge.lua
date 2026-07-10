VWB = VWB or {}
VWB.PSLBridge = {}

-- Send-to-PSL boundary (mirrors AuctionatorBridge). Profession Shopping List is a
-- soft dependency: missing addon -> friendly print, no error. One-way push -- VWB's
-- queue is the SSoT and we mirror it INTO PSL's tracked list; PSL owns the shopping
-- side (reagent aggregation / AH / vendor / cooldowns). See docs/PSL_INTEGRATION_2026-07-08.md.
--
-- PSL's TrackRecipe is ADDITIVE (quantity += n), so we clear each recipe first
-- (UntrackRecipe id, 0 nils the entry) then track the exact qty -- pushing the same
-- queue twice can't double it. We only touch recipes VWB actually sends; the user's
-- own manually-tracked PSL recipes are left alone.

local function getApi()
    if not C_AddOns.IsAddOnLoaded("ProfessionShoppingList") then
        return nil, "Profession Shopping List is not loaded"
    end
    ---@diagnostic disable-next-line: undefined-global
    local PSL = ProfessionShoppingList -- exception(boundary): optional addon (PSL global unknown to WoW-API stubs)
    if not (PSL and PSL.TrackRecipe and PSL.UntrackRecipe) then -- exception(boundary): API surface varies by PSL version
        return nil, "Profession Shopping List API (TrackRecipe/UntrackRecipe) is unavailable"
    end
    return PSL
end

-- True when PSL is installed and exposes the track API -- gates the "-> PSL" button.
function VWB.PSLBridge:IsAvailable()
    return (getApi()) ~= nil
end

-- Push queuedRecipes ({ recipeID, qty, charKey, ... }) into PSL. Merge by recipeID
-- first -- the same recipe queued on two alts is two VWB entries but one PSL entry.
function VWB.PSLBridge:SendQueue(queuedRecipes)
    local api, err = getApi()
    if not api then
        print("|cFF2aa198[VWB]|r " .. err .. ". Install Profession Shopping List to send your queue.")
        return false
    end

    local byID = {}
    for _, q in ipairs(queuedRecipes) do
        byID[q.recipeID] = (byID[q.recipeID] or 0) + q.qty
    end

    if not next(byID) then
        print("|cFF2aa198[VWB]|r Queue is empty -- nothing to send.")
        return false
    end

    local count = 0
    self._pushing = true -- our own UntrackRecipe(id,0) fires PSL's "removed" event; don't echo it back
    for recipeID, qty in pairs(byID) do
        api:UntrackRecipe(recipeID, 0) -- set-semantics: clear so a re-send can't stack the qty
        api:TrackRecipe(recipeID, qty)
        count = count + 1
    end
    self._pushing = false

    print("|cFF2aa198[VWB]|r Sent " .. count .. " recipe(s) to Profession Shopping List.")
    return true, count
end

-- Incoming sync (prototype): mirror PSL tracked-list changes into a VWB EventBus
-- signal so views can react. Requires PSL to fire the proposed
-- "ProfessionShoppingList.OnTrackedRecipesChanged" event (see docs/PSL_CALLBACK_PROPOSAL.md);
-- INERT if PSL lacks it -- an unfired EventRegistry string is simply never called.
VWB.PSLBridge.debug = true -- prototype: print each incoming change (flip false to silence)

function VWB.PSLBridge:Initialize()
    if not self:IsAvailable() then return end
    EventRegistry:RegisterCallback("ProfessionShoppingList.OnTrackedRecipesChanged",
        function(_, recipeID, newQuantity)
            if VWB.PSLBridge._pushing then return end -- our own "-> PSL" push echoing back
            if VWB.PSLBridge.debug then
                print(("|cFF2aa198[VWB]|r PSL tracked change: recipe %s -> qty %s")
                    :format(tostring(recipeID), tostring(newQuantity)))
            end
            VWB.EventBus:Trigger("VWB_PSL_TRACKED_CHANGED", { recipeID = recipeID, quantity = newQuantity })
            -- One-way removal sync (opt-in): PSL removed or finished-crafting a recipe
            -- (qty -> 0) -> prune it from the VWB queue. Adds (qty > 0) are ignored;
            -- order-key strings (non-number recipeID) never match a queue entry.
            if VWB.Store:GetState().config.pslAutoRemove
               and type(recipeID) == "number" and (newQuantity == nil or newQuantity == 0) then
                VWB.Store:Dispatch("REMOVE_FROM_QUEUE", { recipeID = recipeID })
            end
        end, self)
end
