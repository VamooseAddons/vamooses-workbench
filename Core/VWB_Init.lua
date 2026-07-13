-- ============================================================================
-- Vamoose's Workbench - bootstrap. Exposes the VWB global, wires Reactor to the
-- WoW frame loop at ADDON_LOADED, and registers /vwb. No work at PLAYER_LOGIN;
-- the window opens only on the slash command.
-- ============================================================================

local _, ns = ...
-- _G.VWB is the shared namespace established in VWB_Namespace.lua (ns == _G.VWB),
-- so every module -- signals-native or ported from VPC -- lives on this table.

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED") -- exception(false-positive): single bootstrap frame; VWB is Reactor, not Lattice, so there is no BlizzardEvents engine to route through. Filtered to own name + self-unregisters below.
boot:RegisterEvent("PLAYER_LOGIN") -- exception(false-positive): same bootstrap frame; self-unregisters after module registration.
boot:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= "VamoosesWorkbench" then return end
        self:UnregisterEvent("ADDON_LOADED")
        ns.Debug:SetEpoch() -- t-zero for the boot timeline, before anything derives
        VWB_DB = VWB_DB or {}
        -- Signals store FIRST: aliases VWB_DB slices onto state.config. Must precede
        -- Theme:Initialize -- otherwise Theme reads the Store's empty default config
        -- (VWB.Store exists but isn't loaded yet) and reverts to Solarized on every
        -- reload instead of honouring the persisted theme.
        ns.Store:Initialize()
        -- Theme (ported from VPC): derived colors, then the active scheme.
        ns.Constants:ApplyTheme()
        ns.Theme:Initialize()
        -- Chrome ("chrome=Panel" on a LayoutConfig node) is first-class layout
        -- metadata: the Layout engine applies it via this host-injected applier,
        -- so real panels don't route through the unwired-node placeholder.
        ns.Layout.setChromeApplier(VWB.ViewKit.applyChrome)
        -- Default node factory: a view returns nil from makeFrame for what it
        -- doesn't own, and the engine renders it per its role (no placeholder).
        ns.Layout.setDefaultFactory(VWB.ViewKit.makeDefault)
        -- Reactor -> WoW frame loop (scheduler + events + error sink).
        ns.ReactorWoW.install({
            logger = function(_, msg) VWB.Log:Print(tostring(msg)) end,
        })
        -- Re-arm profiling if debug was left on across sessions (Store loaded the
        -- persisted config just above). Cheap no-op when off.
        if VWB_DB.config.debug then ns.Debug:Enable() end
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        -- Data-layer event REGISTRATION only (needs the player logged in for
        -- C_TradeSkillUI). No scanning happens here -- the own-profession
        -- harvest fires when a profession window opens (TRADE_SKILL_LIST_UPDATE).
        ns.CharacterData:Initialize()
        ns.KnownRecipes:Initialize()
        ns.RecipeHarvest:Initialize()
        ns.DecorOwnership:Initialize()
        ns.Transmog:Initialize()
        ns.Collectibles:Initialize() -- collection-event epoch for the global uncollected count (nav badge)
        ns.Minimap:Initialize() -- minimap button -> ns.Shell via VWB:ToggleWindow adapter
        ns.Inventory:Initialize() -- BAG/BANK/warband change -> VWB_INVENTORY_UPDATE so Stockroom owned counts stay live
        ns.GuildCrafters:Initialize() -- guild-crafter roster + "who can craft this" tooltips
        ns.PSLBridge:Initialize() -- listen for PSL tracked-list changes -> VWB_PSL_TRACKED_CHANGED (inert if PSL lacks the event)
        ns.ProjectPlanner:Initialize() -- collect auto-complete + stock refill watchers (registration only)
        -- Graph + ReagentSource are lazy, no init.
        -- Rebuild the crafting queue's derived tables (expandedQueue/shoppingList)
        -- from the persisted queuedRecipes -- the reducer that does this only
        -- runs on queue edits otherwise, so a reloaded queue's Materials list
        -- is blank until the user's next edit. Constitution R6: this is
        -- DERIVATION (graph walk + broker acquisitions for mat names), so it
        -- wakes at first window open, not at login -- nothing reads the
        -- derived tables before a view exists.
        ns.Shell.WhenFirstOpen(function()
            ns.Store:Dispatch("REBUILD_CRAFTING_STATE")
        end)
    end
end)

SLASH_VWB1 = "/vwb"
SlashCmdList["VWB"] = function(msg)
    local cmd = (msg or ""):match("^%s*(%S*)"):lower()
    if cmd == "debug" then
        local on = ns.Debug:Toggle()
        VWB.Log:Print("debug " .. (on and "ON (perf profiling active) -- Debug tab is now in the sidebar" or "OFF"))
    elseif cmd == "reset" then
        ns.Debug:Reset()
        VWB.Log:Print("profiler counters reset")
    elseif cmd == "classify" then
        -- Showroom kind-classification diagnostic: /vwb classify <itemID>
        local itemID = tonumber((msg or ""):match("classify%s+(%d+)"))
        if not itemID then VWB.Log:Print("usage: /vwb classify <itemID>"); return end
        local name = C_Item.GetItemNameByID(itemID)
        local _, _, _, equipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
        print(string.format("|cff2aa198[VWB]|r classify %d (%s): classID=%s subClass=%s equipLoc=%s",
            itemID, tostring(name), tostring(classID), tostring(subClassID), tostring(equipLoc)))
        print(string.format("  IsTransmoggable=%s  IsMount=%s (GetMountFromItem=%s)  IsPet=%s",
            tostring(ns.Transmog:IsTransmoggable(itemID)),
            tostring(ns.Collectibles:IsMount(itemID)),
            tostring(C_MountJournal.GetMountFromItem(itemID)),
            tostring(ns.Collectibles:IsPet(itemID))))
        print(string.format("  recipeByItemID=%s  IsUncollectedDecor=%s  catalogCold=%s",
            tostring(ns.Database:GetRecipeByItemID(itemID)),
            tostring(ns.DecorOwnership:IsUncollected(itemID)),
            tostring(ns.DecorOwnership:IsCatalogCold())))
        -- Is it actually in the Showroom's universe (rank-collapsed GetFiltered)?
        local inUni, uniProf, uniExp
        for _, e in ipairs(ns.RecipeQuery:GetFiltered({ collapseRanks = true })) do
            if e.recipe.itemID == itemID then inUni = e.recipeID; uniProf = e.recipe.profession; uniExp = e.recipe.expansion; break end
        end
        print(string.format("  inCollapsedUniverse=%s (recipeID=%s prof=%s exp=%s)",
            tostring(inUni ~= nil), tostring(inUni), tostring(uniProf), tostring(uniExp)))
        -- And the raw store recipe's own profession/itemID (pre-collapse):
        local rid = ns.Database:GetRecipeByItemID(itemID)
        local raw = rid and ns.Database:GetRecipe(rid)
        if raw then print(string.format("  rawRecipe(%s): prof=%s exp=%s itemID=%s", tostring(rid), tostring(raw.profession), tostring(raw.expansion), tostring(raw.itemID))) end
    else
        ns.Shell.openWindow():Show()
    end
end
