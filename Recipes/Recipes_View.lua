-- ============================================================================
-- VWB Workbench (Recipes) - VIEW / controller. Slice: FULL FILTER SURFACE.
-- ============================================================================
-- The flagship crafting tab's left side, wired to real data: profession tab
-- bar (RecipeQuery:GetProfessions) + filter pills (Transmog/Craftable/
-- Skill-Up) + decor scope toggle + an expansion/category nav tree all feed
-- ONE recipeList computed that calls RecipeQuery:GetFiltered. Recipe rows
-- show icon / name / up to CHIP_MAX status chips (Ready / short N /
-- uncollected / new mog / alt-known), a hover tooltip (known-by, appearance,
-- short mats, guild crafters), and click-to-queue (also pushes the MRU
-- strip). The right column (queue / materials) is the earlier working slice,
-- untouched. Same box-model Layout as the Showroom list.
-- ============================================================================

local _, ns = ...
local Recipes = ns.Recipes or {}
ns.Recipes = Recipes

local ED = ns.Data.ExpansionData

local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Reagent-name resolver. shoppingList entries are named at Graph-build time, so
-- an item uncached then is baked "Loading..." and never refreshes on its own
-- (Graph re-runs only on a queue change). This resource re-reads on
-- ITEM_DATA_LOAD_RESULT (what RequestLoadItemDataByID fires), so the materials
-- effect re-derives the name live.
local matNameRes
local function ensureMatNameRes()
    if matNameRes then return end
    matNameRes = ns.Reactor.resource({
        read = function(itemID)
            return C_Item.GetItemInfo(itemID) -- exception(boundary): nil on cold cache -> resource stays pending + requests a load
        end,
        request = function(itemID) C_Item.RequestLoadItemDataByID(itemID) end,
        event = "ITEM_DATA_LOAD_RESULT", -- RequestLoadItemDataByID fires THIS, not GET_ITEM_INFO_RECEIVED
        keyOf = function(itemID) return itemID end, -- O(1): the event names exactly this itemID
    })
end

-- Status chip layout (recipe row, right-aligned, pooled 1:1 with CHIP_MAX). --
local CHIP_MAX = 2
local CHIP_HEIGHT = 13
local CHIP_HPAD = 5
local CHIP_GAP = 3

-- MRU strip (recent-queued icon chips above the crafting queue). -----------
local MRU_BTN_SIZE = 18
local MRU_BTN_GAP = 3

-- ============================================================================
-- ROW TEMPLATES (chrome built once per pooled frame; painted per repaint)
-- ============================================================================

local function rowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(16, 16); icon:SetPoint("LEFT", 3, 0)
    frame.icon = icon

    -- Status chip pool: pooled bg+text pairs, never created per paint.
    frame.chips = {}
    for i = 1, CHIP_MAX do
        local bg = frame:CreateTexture(nil, "ARTWORK", nil, 2)
        bg:SetTexture("Interface\\Buttons\\WHITE8x8"); bg:Hide()
        local t = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetPoint("CENTER", bg, "CENTER", 0, 0); t:Hide()
        frame.chips[i] = { bg = bg, text = t }
    end

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0); text:SetJustifyH("LEFT")
    frame.text = text

    -- Item 6b: craftable-transition wash attached ONCE at factory time (not paint time).
    -- AnimationGroups must be created at factory; the handle is read in updateRow.
    local c = VWB.UI:GetScheme()
    frame._washHandle = VWB.UI:AttachTransitionWash(frame, c.success.r, c.success.g, c.success.b)
end

-- Queue row: icon + name(xqty) + a dedicated remove button. The remove click
-- reads frame.data at click time (set fresh by updateRow every repaint) so the
-- handler is wired ONCE at row creation, same idiom as CreateVirtualizedList's
-- own onRowClick (row.data lookup).
local function queueRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(16, 16); icon:SetPoint("LEFT", 3, 0)
    frame.icon = icon
    local removeBtn = CreateFrame("Button", nil, frame)
    removeBtn:SetSize(14, 14); removeBtn:SetPoint("RIGHT", -3, 0); removeBtn:RegisterForClicks("AnyUp")
    local removeText = removeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    removeText:SetAllPoints(); removeText:SetText("x"); removeText:SetTextColor(1, 0.4, 0.4)
    removeBtn:SetScript("OnClick", function()
        ns.Store:Dispatch("REMOVE_FROM_QUEUE", { recipeID = frame.data.recipeID, charKey = frame.data.charKey })
    end)
    frame.removeBtn = removeBtn

    -- Craft hammer (TODO #1): shown only for the current character's rows with
    -- a recipe they know (paint gates it). Click flow lives in OnCraftClick.
    local craftBtn = CreateFrame("Button", nil, frame)
    craftBtn:SetSize(14, 14); craftBtn:SetPoint("RIGHT", removeBtn, "LEFT", -3, 0); craftBtn:RegisterForClicks("AnyUp")
    local hammer = craftBtn:CreateTexture(nil, "ARTWORK")
    hammer:SetAllPoints(); hammer:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
    hammer:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    craftBtn:SetScript("OnClick", function() OnCraftClick(frame.data) end)
    craftBtn:SetScript("OnEnter", function(self)
        local tip = ns.UI.Tooltip
        tip:Begin(self)
        tip:AddTitle("Craft")
        tip:AddLine("Opens your profession window at this recipe if needed")
        tip:Show()
    end)
    craftBtn:SetScript("OnLeave", function(self) ns.UI.Tooltip:Hide(self) end)
    frame.craftBtn = craftBtn

    -- Qty steppers: -/+ (shift = 5). Minus to zero removes (UPDATE_QUEUE_QTY reducer).
    local function makeStep(label, delta, r, g, b)
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(12, 14); btn:RegisterForClicks("AnyUp")
        local t = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetAllPoints(); t:SetText(label); t:SetTextColor(r, g, b)
        btn:SetScript("OnClick", function()
            local step = IsShiftKeyDown() and delta * 5 or delta
            ns.Store:Dispatch("UPDATE_QUEUE_QTY", {
                recipeID = frame.data.recipeID, charKey = frame.data.charKey,
                qty = (frame.data.qty or 1) + step,
            })
        end)
        return btn
    end
    local plusBtn = makeStep("+", 1, 0.6, 0.8, 0.6)
    plusBtn:SetPoint("RIGHT", craftBtn, "LEFT", -3, 0)
    local minusBtn = makeStep("-", -1, 0.8, 0.6, 0.6)
    minusBtn:SetPoint("RIGHT", plusBtn, "LEFT", -1, 0)

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0); text:SetPoint("RIGHT", minusBtn, "LEFT", -4, 0); text:SetJustifyH("LEFT")
    frame.text = text
end

-- ============================================================================
-- CRAFT EXECUTION (donor: HDG HDGR_Controller_Recipes.lua craft dialog +
-- VPC Recipes.lua ExecuteQueueCraft refinements -- both shipped patterns).
-- Flow: hammer click -> profession window closed or wrong prof? OpenRecipe()
-- opens/navigates the journal AT the recipe and the user clicks again ->
-- confirm popup (qty editbox + steppers / Craft Max) -> CraftRecipe.
-- ============================================================================

local function chat(msg) print("|cFF2aa198[VWB]|r " .. msg) end

-- Max full crafts from on-hand mats (bags+bank+warband, variant-aware).
-- No mats data on file -> 1 so the dialog still offers something.
local function ComputeMaxCraft(recipeID)
    local maxRuns
    for _, mat in ipairs(ns.Graph:GetDirectMaterials(recipeID, 1)) do
        if mat.required > 0 then
            local runs = math.floor(mat.owned / mat.required)
            if not maxRuns or runs < maxRuns then maxRuns = runs end
        end
    end
    return maxRuns or 1 -- exception(nullable): recipe with no basic slots on file
end

-- The one place a craft fires. CraftRecipe silently no-ops (or errors) unless
-- THIS profession's window is open -- validate and say so (the window can
-- close between popup-show and accept). Third arg MUST be {} not nil (MCP gotcha).
local function ExecuteQueueCraft(item, qty)
    qty = math.max(1, qty or item.qty or 1)
    -- exception(boundary): C_TradeSkillUI -- the craft target window may have closed
    if not C_TradeSkillUI.IsTradeSkillReady() or C_TradeSkillUI.IsNPCCrafting() then
        chat("Profession window closed -- click the hammer again to reopen it.")
        return
    end
    local recipe = ns.Database:GetRecipe(item.recipeID)
    local base = C_TradeSkillUI.GetBaseProfessionInfo() -- exception(boundary): nil with no window open
    if not base or base.professionName ~= recipe.profession then
        chat(recipe.profession .. "'s window needs to be open for this one.")
        return
    end
    C_TradeSkillUI.OpenRecipe(item.recipeID)
    C_TradeSkillUI.CraftRecipe(item.recipeID, qty, {})
end

-- Attach -/+ steppers to the craft-confirm popup once; StaticPopup frames are
-- reused, so build the custom widgets lazily and keep them on the dialog.
local function EnsureCraftPopupSteppers(dialog, eb)
    if dialog._vwbSteppers then return dialog._vwbSteppers end
    local function makeStep(label, delta)
        local b = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        b:SetSize(22, 20)
        b:SetText(label)
        b:SetScript("OnClick", function()
            local v = (tonumber(eb:GetText()) or 1) + (IsShiftKeyDown() and delta * 5 or delta)
            eb:SetText(tostring(math.max(1, v)))
            eb:HighlightText()
        end)
        return b
    end
    local minus, plus = makeStep("-", -1), makeStep("+", 1)
    minus:SetPoint("RIGHT", eb, "LEFT", -4, 0)
    plus:SetPoint("LEFT", eb, "RIGHT", 4, 0)
    dialog._vwbSteppers = { minus = minus, plus = plus }
    return dialog._vwbSteppers
end

-- Confirm dialog before a craft fires: -/+ qty, type-a-number, or Craft Max.
-- Button->handler mapping (retail 12.x, per shipped HDGR_CRAFT_RECIPE):
-- button1=OnAccept, button2=OnAlt, button3=OnCancel. "Craft Max" MUST be
-- button2 (OnAlt); "Cancel" button3 (ESC = just closes).
StaticPopupDialogs["VWB_CRAFT_CONFIRM"] = {
    text = "Craft %s?\nSet a quantity, or craft as many as your mats allow.",
    button1 = "Craft",
    button2 = "Craft Max",
    button3 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 60,
    maxLetters = 4,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox -- retail 12.0.5 renamed to EditBox
        eb:SetNumeric(true)
        eb:SetAutoFocus(false)
        local q = (self.data.item.qty and self.data.item.qty > 0) and self.data.item.qty or 1
        eb:SetText(tostring(q))
        eb:HighlightText()
        local steppers = EnsureCraftPopupSteppers(self, eb)
        steppers.minus:Show()
        steppers.plus:Show()
    end,
    OnHide = function(self)
        -- StaticPopup frames are shared across dialog types -- hide our custom
        -- steppers so they don't linger over the next popup on this slot.
        if self._vwbSteppers then
            self._vwbSteppers.minus:Hide()
            self._vwbSteppers.plus:Hide()
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        ExecuteQueueCraft(dialog.data.item, tonumber(self:GetText()) or 1)
        dialog:Hide()
    end,
    OnAccept = function(self)
        local eb = self.editBox or self.EditBox
        ExecuteQueueCraft(self.data.item, tonumber(eb:GetText()) or 1)
    end,
    OnAlt = function(self)
        local maxRuns = ComputeMaxCraft(self.data.item.recipeID)
        if maxRuns < 1 then
            chat("Not enough materials to craft even one.")
            return
        end
        ExecuteQueueCraft(self.data.item, maxRuns)
    end,
}

-- Copyable Wowhead spell link (recipe IDs are spell IDs). Ctrl-click on a
-- recipe or queue row.
StaticPopupDialogs["VWB_WOWHEAD_URL"] = {
    text = "Wowhead link (Ctrl-C to copy):",
    button1 = "Close",
    hasEditBox = true,
    editBoxWidth = 300,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        eb:SetText(self.data or "")
        eb:HighlightText()
        eb:SetFocus()
    end,
}

local function ShowWowheadLink(recipeID)
    StaticPopup_Show("VWB_WOWHEAD_URL", nil, nil, "https://www.wowhead.com/spell=" .. recipeID)
end

-- Hammer click: window closed or wrong profession open -> OpenRecipe navigates
-- the journal AT this recipe (HDG's open-for-you flow), user clicks again.
-- Ready + matching -> the confirm popup.
local function OnCraftClick(item)
    -- exception(boundary): C_TradeSkillUI window state is external
    if not C_TradeSkillUI.IsTradeSkillReady() or C_TradeSkillUI.IsNPCCrafting() then
        C_TradeSkillUI.OpenRecipe(item.recipeID)
        chat("Opening the profession window -- click the hammer again to craft.")
        return
    end
    local recipe = ns.Database:GetRecipe(item.recipeID)
    local base = C_TradeSkillUI.GetBaseProfessionInfo() -- exception(boundary): nil with no window open
    if not base or base.professionName ~= recipe.profession then
        C_TradeSkillUI.OpenRecipe(item.recipeID)
        chat("Switching to " .. recipe.profession .. " -- click the hammer again to craft.")
        return
    end
    StaticPopup_Show("VWB_CRAFT_CONFIRM", item.name or recipe.name, nil, { item = item })
end

-- Materials row: icon + name + owned/required count (colored short vs covered).
local function matRowTemplate(frame)
    local icon = frame:CreateTexture(nil, "ARTWORK"); icon:SetSize(16, 16); icon:SetPoint("LEFT", 3, 0)
    frame.icon = icon
    local countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countText:SetPoint("RIGHT", -4, 0); countText:SetJustifyH("RIGHT")
    frame.countText = countText
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0); text:SetPoint("RIGHT", countText, "LEFT", -6, 0); text:SetJustifyH("LEFT")
    frame.text = text
end

-- ============================================================================
-- FILTER / CHIP / NAV HELPERS (pure -- safe to call from a Reactor computed)
-- ============================================================================

-- ScopeFilters derives the RecipeQuery filter flags from the type toggle and
-- the independent Missing pill. The SegmentedToggle is type-only ("off"|"decor").
-- missingActive drives uncollectedDecorOnly (when decorMode=="decor") and
-- unknownTransmogOnly (when transmogScope). Non-decor/non-mog collectibles
-- (mounts, pets) are handled by the _isMissingCollectible post-filter in
-- recipeList since RecipeQuery has no Collectibles module access.
local function ScopeFilters(transmogScope, decorMode, missingActive)
    return {
        transmogOnly = transmogScope,
        unknownTransmogOnly = transmogScope and missingActive,
        decorOnly = decorMode == "decor",
        uncollectedDecorOnly = decorMode == "decor" and missingActive,
    }
end

-- Missing-pill check delegates to the Collectibles module's canonical chain
-- (decor -> transmog -> mount -> pet, cold-safe memoization) -- shared with
-- the nav badge and ProjectPlanner. Collection state is always queried live;
-- decor's cold-catalog nil fails the pill and the list effect's empty state
-- surfaces the honest "open the housing catalog" message.
local function _isMissingCollectible(itemID)
    return ns.Collectibles:IsUncollectedCollectible(itemID)
end

-- Chip specs by priority (capped CHIP_MAX): Ready > short N > uncollected >
-- new mog > known-by-alt. "Ready" and "short N" are gated on KNOWN-BY-THIS-
-- CHARACTER (IsKnownBy), NOT the blanket IsKnown (known by ANY scanned alt) --
-- an alt-only recipe must show "alt", never a green Ready tick.
local function ComputeRecipeChips(item, c, currentCharKey)
    local specs = {}
    local recipeID, itemID = item.recipeID, item.itemID
    local knownHere = ns.KnownRecipes:IsKnownBy(recipeID, currentCharKey)
    local ready = knownHere and ns.RecipeQuery:CanCraft(recipeID)

    if ready then
        specs[#specs + 1] = { label = "Ready", r = c.success.r, g = c.success.g, b = c.success.b }
    else
        local shortCount = 0
        for _, mat in ipairs(ns.Graph:GetDirectMaterials(recipeID, 1)) do
            if mat.missing > 0 then shortCount = shortCount + 1 end
        end
        if shortCount > 0 then
            specs[#specs + 1] = { label = "short " .. shortCount, r = c.warning.r, g = c.warning.g, b = c.warning.b }
        end
    end

    if itemID and ns.DecorOwnership:IsUncollected(itemID) == true then
        specs[#specs + 1] = { label = "uncollected", r = c.accent.r, g = c.accent.g, b = c.accent.b }
    end
    if itemID then
        local mog = ns.Transmog:GetStatus(itemID)
        if mog.hasAppearance and not mog.isCollected then
            specs[#specs + 1] = { label = "new mog", r = c.accent.r, g = c.accent.g, b = c.accent.b }
        end
    end
    if not knownHere and ns.KnownRecipes:IsKnown(recipeID) then
        specs[#specs + 1] = { label = "alt", r = c.text.r, g = c.text.g, b = c.text.b }
    end

    while #specs > CHIP_MAX do table.remove(specs) end
    return specs
end

-- Positions pooled chips right-to-left; returns the text's right x-offset so
-- the label reserves exactly the used gutter (or a small fixed gutter when
-- there are none).
local function PaintRecipeChips(row, specs)
    local x = -4
    local textRight = -8
    for i = 1, CHIP_MAX do
        local chip, spec = row.chips[i], specs[i]
        if spec then
            chip.text:SetText(spec.label)
            local w = math.ceil(chip.text:GetUnboundedStringWidthForText(spec.label)) + CHIP_HPAD * 2
            chip.bg:ClearAllPoints()
            chip.bg:SetPoint("RIGHT", row, "RIGHT", x, 0)
            chip.bg:SetSize(w, CHIP_HEIGHT)
            chip.bg:SetVertexColor(spec.r, spec.g, spec.b, 0.20)
            chip.text:SetTextColor(spec.r, spec.g, spec.b, 1)
            chip.bg:Show(); chip.text:Show()
            x = x - w
            textRight = x - 4
            x = x - CHIP_GAP
        else
            chip.bg:Hide(); chip.text:Hide()
        end
    end
    return textRight
end

-- Group RecipeQuery:GetFiltered results into expansion sections / category
-- items for CreateNavTree (header = expansion, item = "exp::category"). Pure
-- derivation only -- a stale nav selection (filtered down to zero) is left
-- for the user to clear by clicking elsewhere; no write happens from a read
-- path (Reactor computeds must stay side-effect free).
local function BuildNavSections(prof, searchFilter, sf, canCraftOnly, skillUpOnly, missingActive)
    local results = ns.RecipeQuery:GetFiltered({
        profession = prof,
        search = searchFilter ~= "" and searchFilter or nil,
        decorOnly = sf.decorOnly,
        uncollectedDecorOnly = sf.uncollectedDecorOnly,
        transmogOnly = sf.transmogOnly,
        unknownTransmogOnly = sf.unknownTransmogOnly,
        canCraftOnly = canCraftOnly,
        skillUpOnly = skillUpOnly,
        collapseRanks = true,
    })

    local expCatCounts = {}
    for _, entry in ipairs(results) do
        local r = entry.recipe
        -- Mirror the recipeList post-filter so nav counts match the list.
        if missingActive and not sf.unknownTransmogOnly and not sf.uncollectedDecorOnly
            and not _isMissingCollectible(r.itemID) then
            -- skip: missing pill excludes this non-collectible/collected item
        elseif r.expansion then
            local cats = expCatCounts[r.expansion]
            if not cats then cats = {}; expCatCounts[r.expansion] = cats end
            local cat = r.categoryName or "Uncategorized"
            cats[cat] = (cats[cat] or 0) + 1
        end
    end

    local forceOpenTree = searchFilter ~= ""
    local navCollapsed = ns.Store:GetState().ui.navCollapsed
    local exps = ns.RecipeQuery:GetExpansions(prof)

    local sections = {}
    for _, exp in ipairs(exps) do
        local catCounts = expCatCounts[exp.key]
        if exp.key ~= "AllExps" and catCounts then
            local expInfo = ED.GetExpansionInfo(exp.key)
            local items = {}
            local catOrder = {}
            for cat in pairs(catCounts) do catOrder[#catOrder + 1] = cat end
            table.sort(catOrder)
            local totalCount = 0
            for _, cat in ipairs(catOrder) do
                totalCount = totalCount + catCounts[cat]
                items[#items + 1] = { key = exp.key .. "::" .. cat, label = cat, count = catCounts[cat] }
            end
            sections[#sections + 1] = {
                key = exp.key,
                label = expInfo and expInfo.display or exp.key,
                color = ED.GetColor(exp.key),
                collapsed = not forceOpenTree and navCollapsed[exp.key],
                itemCount = totalCount,
                items = items,
            }
        end
    end
    return sections
end

-- Signature of the CURRENT profession key set (sorted, joined) -- lets the
-- profession-tab-bar effect skip a teardown+rebuild when "recipes" bumps for
-- an unrelated reason (new recipes added to an already-known profession).
local function ProfessionSignature(profs)
    local keys = {}
    for i, p in ipairs(profs) do keys[i] = p.key end
    table.sort(keys)
    return table.concat(keys, "|")
end

-- Recent-queued ring lives in persisted ui state (state.ui.recentQueued); the
-- reducer owns the dedupe+prepend+cap (keyed on item.itemID).
local function PushRecent(recipeID, itemID, name)
    ns.Store:Dispatch("PUSH_RECENT_QUEUED", { item = { recipeID = recipeID, itemID = itemID, name = name } })
end

-- Module-level prior-craftable map: tracks last known craftable state per
-- recipeID so pooled rows can detect the false->true transition and Flash().
-- Keyed by recipeID; value = bool (last rendered craftable state). Lives at
-- module scope so it persists across row reuse (pooled rows can't hold it).
local priorCraftable = {}

function Recipes.buildView(container)
    local R = ns.Reactor
    ensureMatNameRes()

    -- F1 FIX: effectiveCharKey reads scope-or-own LIVE inside computeds and
    -- chip logic. Was captured once at mount (line 268) -- that constant never
    -- saw SET_SCOPE writes. Nav slice subscription in recipeList ensures this
    -- re-derives on every scope change. Store:Version("nav") already subscribed.
    local function effectiveCharKey()
        return ns.Store:GetState().ui.scopeCharacter or ns.CharacterData:GetCharacterKey()
    end

    local search = R.signal("")
    local profession = R.signal(nil)
    local transmogScope = R.signal(false)
    local canCraftOnly = R.signal(false)
    local skillUpOnly = R.signal(false)
    local decorMode = R.signal("off")  -- "off" | "decor" (type toggle only; "missing" removed)
    local missingPill = R.signal(false) -- independent Missing filter pill
    -- collectionEpoch: incremented by mount/pet collection events so recipeList
    -- re-derives when the Missing pill is on (collection state lives outside the
    -- Store; the epoch is the standard Reactor pattern for "live external state").
    local collectionEpoch = R.signal(0)

    local listWidget, queueWidget, materialsWidget, navTreeWidget
    local profTabBarContainer, profBtnRow
    local mruContainer, mruButtons = nil, {}
    local emptyCard
    local scopePill  -- "planning as <name> [x]" pill; shown when scope is active

    -- Rank-collapsed recipe records, re-derived on recipe/queue/character/nav
    -- changes. Scoped to the exact slices the filters touch (NOT the blanket
    -- Store:Version()) so a config/minimap-only dispatch never re-derives this.
    -- nav slice covers SET_SCOPE writes so effectiveCharKey() re-derives live.
    local recipeList = R.named("recipes:recipeList", function()
        ns.Store:Version("recipes")
        ns.Store:Version("crafting")
        ns.Store:Version("characters")
        ns.Store:Version("nav") -- covers SET_SCOPE / CLEAR_SCOPE writes

        local prof = profession()
        if not prof then return {} end

        local uiState = ns.Store:GetState().ui
        local filterCategoryName = nil
        if uiState.navSelectedItem then
            local _, cat = uiState.navSelectedItem:match("^(.-)::(.+)$")
            filterCategoryName = cat
        end

        local missing = missingPill()
        -- Subscribe to collection epoch when the pill is on so mount/pet collects
        -- re-derive this computed (collection state lives outside the Store).
        if missing then collectionEpoch() end
        local sf = ScopeFilters(transmogScope(), decorMode(), missing)
        local q = search()
        local out = {}
        for _, e in ipairs(ns.RecipeQuery:GetFiltered({
            collapseRanks = true,
            profession = prof,
            expansion = uiState.navSelectedExp,
            categoryName = filterCategoryName,
            search = q ~= "" and q or nil,
            canCraftOnly = canCraftOnly(),
            skillUpOnly = skillUpOnly(),
            transmogOnly = sf.transmogOnly,
            unknownTransmogOnly = sf.unknownTransmogOnly,
            decorOnly = sf.decorOnly,
            uncollectedDecorOnly = sf.uncollectedDecorOnly,
        })) do
            -- Missing pill post-filter: exclude collected collectibles.
            -- Decor (when decorMode=="decor") is already filtered by
            -- uncollectedDecorOnly above; this post-filter covers the remaining
            -- kinds (mount/pet/transmog) when the pill is on without transmog
            -- scope, and decor in "all" type mode.
            -- When transmog scope is on, unknownTransmogOnly already handled it.
            if not missing or sf.unknownTransmogOnly or sf.uncollectedDecorOnly
                or _isMissingCollectible(e.recipe.itemID) then
                out[#out + 1] = e.recipe
            end
        end
        return out
    end)

    -- Nav tree mirrors the list's filter universe MINUS expansion/category (the
    -- tree IS that selector) so section counts match what the list would show.
    local navSections = R.named("recipes:navSections", function()
        ns.Store:Version("recipes")
        ns.Store:Version("crafting")
        ns.Store:Version("characters")
        ns.Store:Version("nav")

        local prof = profession()
        if not prof then return {} end
        local missing = missingPill()
        if missing then collectionEpoch() end
        return BuildNavSections(prof, search(), ScopeFilters(transmogScope(), decorMode(), missing), canCraftOnly(), skillUpOnly(), missing)
    end)

    -- Crafting queue + materials come from state.crafting, which the queue
    -- reducers mutate IN PLACE (queuedRecipes is appended, not replaced) -- so a
    -- computed would memo on the stable table ref and never re-fire. The effects
    -- below read Store:Version("crafting") directly (a value that changes every
    -- bump) so they re-run on any queue mutation.
    local function makeFrame(node, parent)
        if node.id == "rcpSearch" then
            return ns.UI:CreateSearchBox(parent, { placeholder = "Search recipes...",
                onChange = function(t) search((t or ""):lower()) end })
        elseif node.id == "transmogPill" then
            return ns.UI:CreateFilterPill(parent, "Transmog", function(checked) transmogScope(checked) end)
        elseif node.id == "craftablePill" then
            return ns.UI:CreateFilterPill(parent, "Craftable", function(checked) canCraftOnly(checked) end)
        elseif node.id == "skillUpPill" then
            return ns.UI:CreateFilterPill(parent, "Skill-Up", function(checked) skillUpOnly(checked) end)
        elseif node.id == "decorToggle" then
            return ns.UI:CreateSegmentedToggle(parent, {
                width = 100, height = 18, pill = true,
                segments = {
                    { key = "off",   label = "All" },
                    { key = "decor", label = "Decor" },
                },
                default = "off",
                onSelect = function(key) decorMode(key) end,
            })
        elseif node.id == "missingPill" then
            return ns.UI:CreateFilterPill(parent, "Missing", function(checked) missingPill(checked and true or false) end)
        elseif node.id == "rcpNavLabel" then
            local f = ns.ViewKit.roleLabel(node, parent)
            -- Expand-all / collapse-all: one button that flips whichever state
            -- most sections are in. Label reflects the action (see the effect below).
            local collapseBtn = ns.UI:CreateButton(f, "Collapse", 62, 14)
            collapseBtn:SetPoint("RIGHT", -4, 0)
            collapseBtn:SetScript("OnClick", function()
                local keys, anyOpen = {}, false
                for _, s in ipairs(navSections()) do
                    keys[#keys + 1] = s.key
                    if not s.collapsed then anyOpen = true end
                end
                ns.Store:Dispatch("SET_NAV_COLLAPSED_ALL", { keys = keys, collapsed = anyOpen }) -- any open -> collapse all; else expand all
            end)
            f.collapseBtn = collapseBtn
            f.label:ClearAllPoints()
            f.label:SetPoint("TOPLEFT", 4, -1)
            f.label:SetPoint("BOTTOMRIGHT", collapseBtn, "BOTTOMLEFT", -4, 1)
            return f
        elseif node.id == "profTabBar" then
            profTabBarContainer = CreateFrame("Frame", nil, parent)
            return profTabBarContainer
        elseif node.id == "rcpNavTree" then
            navTreeWidget = ns.UI:CreateNavTree(parent, {
                onArrowClick = function(key)
                    ns.Store:Dispatch("TOGGLE_NAV_COLLAPSE", { key = key })
                end,
                onHeaderClick = function(key)
                    local st = ns.Store:GetState().ui
                    if st.navSelectedExp == key and not st.navSelectedItem then
                        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = "AllExps" })
                    else
                        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = key })
                    end
                end,
                onItemClick = function(key)
                    local st = ns.Store:GetState().ui
                    if st.navSelectedItem == key then
                        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = st.navSelectedExp })
                    else
                        local exp = key:match("^(.-)::(.+)$")
                        ns.Store:Dispatch("SET_NAV_SELECTION", { exp = exp, item = key })
                    end
                end,
            })
            return navTreeWidget
        elseif node.id == "rcpList" then
            listWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = 22, rowTemplate = rowTemplate,
                updateRow = function(row, item)
                    row.data = item
                    row.icon:SetTexture(item.icon or C_Item.GetItemIconByID(item.itemID) or QUESTION_ICON)
                    local c = ns.UI:GetScheme()
                    -- F1 FIX: pass effectiveCharKey() live so scope changes re-eval chips
                    local specs = ComputeRecipeChips(item, c, effectiveCharKey())
                    local textRight = PaintRecipeChips(row, specs)
                    row.text:SetText(item.name or ("recipe:" .. tostring(item.recipeID)))
                    row.text:ClearAllPoints()
                    row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
                    row.text:SetPoint("RIGHT", textRight, 0)

                    -- Item 6b: craftable-transition wash. Check CanCraft live (same
                    -- IsKnownBy scope as chips); flash the wash on false->true only.
                    -- wash handle is attached once at row creation (in rowTemplate
                    -- via rowWash below); priorCraftable is module-scope (pooled rows
                    -- can't carry state). recipeID is the identity key.
                    local craftableNow = ns.KnownRecipes:IsKnownBy(item.recipeID, effectiveCharKey())
                        and ns.RecipeQuery:CanCraft(item.recipeID)
                    local prev = priorCraftable[item.recipeID]
                    if craftableNow and prev == false then
                        if row._washHandle then row._washHandle:Flash() end
                    end
                    priorCraftable[item.recipeID] = craftableNow
                end,
                onRowClick = function(item)
                    -- Ctrl: Wowhead link. Shift: Showroom preview. Plain: queue 1.
                    if IsControlKeyDown() and item.recipeID then
                        ShowWowheadLink(item.recipeID)
                    elseif IsShiftKeyDown() and item.itemID then
                        ns.Nav.Go("showroom", { select = item.itemID })
                    else
                        ns.Store:Dispatch("ADD_TO_QUEUE", { recipeID = item.recipeID, qty = 1 })
                        PushRecent(item.recipeID, item.itemID, item.name)
                    end
                end,
                onRowEnter = function(item, row)
                    local tip = ns.UI.Tooltip
                    tip:Begin(row)
                    if item.itemID then tip:SetItemHeader(item.itemID, item.name) else tip:AddTitle(item.name or "Unknown") end

                    local knownBy = ns.KnownRecipes:KnownByList(item.recipeID)
                    if #knownBy > 0 then
                        tip:AddLine(" ")
                        tip:AddLine(ns.UI:ColorCode("base01") .. "Known by: " .. table.concat(knownBy, ", ") .. "|r")
                    end

                    local mog = ns.Transmog:GetStatus(item.itemID)
                    if mog.hasAppearance then
                        tip:AddLine(" ")
                        if mog.isCollected then
                            tip:AddLine(ns.UI:ColorCode("base01") .. "Appearance: collected|r")
                        else
                            tip:AddLine(ns.UI:ColorCode("cyan") .. "Appearance: not in your collection|r")
                        end
                    end

                    local missingMats = {}
                    for _, mat in ipairs(ns.Graph:GetDirectMaterials(item.recipeID, 1)) do
                        if mat.missing > 0 then missingMats[#missingMats + 1] = mat.name or ("#" .. mat.itemID) end
                    end
                    if #missingMats > 0 then
                        tip:AddLine(" ")
                        tip:AddLine(ns.UI:ColorCode("yellow") .. "Short for one craft:|r " ..
                            ns.UI:ColorCode("base01") .. table.concat(missingMats, ", ") .. "|r")
                    end

                    tip:AddLine(" ")
                    tip:AddLine(ns.UI:ColorCode("base01") .. "Click: queue 1  -  Shift: Showroom  -  Ctrl: Wowhead link|r")
                    tip:Show()
                    ns.GuildCrafters:AppendCraftersToTooltip(tip, item.recipeID)
                end,
                onRowLeave = function(_, row)
                    ns.GuildCrafters:CancelTooltip()
                    ns.UI.Tooltip:Hide(row)
                end,
            })
            return listWidget
        elseif node.id == "rcpMru" then
            mruContainer = CreateFrame("Frame", nil, parent)
            return mruContainer
        elseif node.id == "rcpQueue" then
            queueWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = 20, rowTemplate = queueRowTemplate,
                updateRow = function(row, item)
                    row.data = item
                    -- Enchants/Writs have no output item -> use the recipe's own icon
                    -- (what the recipe list already does), not the "?" fallback.
                    local rec = item.recipeID and ns.Database:GetRecipe(item.recipeID)
                    row.icon:SetTexture((rec and rec.icon) or (item.itemID and C_Item.GetItemIconByID(item.itemID)) or QUESTION_ICON)
                    local label = item.name or ("recipe:" .. tostring(item.recipeID))
                    if item.qty and item.qty > 1 then label = label .. " x" .. item.qty end
                    row.text:SetText(label)
                    -- Hammer only on rows this character can actually fire:
                    -- their own queue entry AND a recipe they know.
                    local me = ns.CharacterData:GetCharacterKey()
                    row.craftBtn:SetShown(item.charKey == me and ns.KnownRecipes:IsKnownBy(item.recipeID, me))
                end,
                onRowClick = function(item)
                    if IsControlKeyDown() and item.recipeID then ShowWowheadLink(item.recipeID) end
                end,
            })
            return queueWidget
        elseif node.id == "rcpMaterials" then
            materialsWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = 18, rowTemplate = matRowTemplate,
                updateRow = function(row, item)
                    row.data = item
                    row.icon:SetTexture(C_Item.GetItemIconByID(item.itemID) or QUESTION_ICON)
                    row.text:SetText(item.name or ("item:" .. tostring(item.itemID)))
                    row.countText:SetText((item.owned or 0) .. "/" .. (item.required or 0))
                    local c = ns.UI:GetScheme()
                    if item.missing and item.missing > 0 then
                        row.countText:SetTextColor(c.warning.r, c.warning.g, c.warning.b)
                    else
                        row.countText:SetTextColor(c.success.r, c.success.g, c.success.b)
                    end
                end,
                -- Item 5a: shift-click or right-click a material row -> Stockroom
                -- filtered to that item name.
                onRowClick = function(item)
                    if IsShiftKeyDown() then
                        ns.Nav.Go("stockroom", { filter = item.name or "" })
                    end
                end,
                onRowEnter = function(item, row)
                    if item.missing and item.missing > 0 then
                        local tip = ns.UI.Tooltip
                        tip:Begin(row)
                        tip:AddTitle(item.name or ("item:" .. tostring(item.itemID)))
                        tip:AddLine(ns.UI:ColorCode("base01") .. "Shift-click: find in Stockroom|r")
                        tip:Show()
                    end
                end,
                onRowLeave = function(_, row) ns.UI.Tooltip:Hide(row) end,
            })
            return materialsWidget
        elseif node.id == "rcpQueueHeader" then
            local f = ns.ViewKit.roleLabel(node, parent)
            local clearBtn = ns.UI:CreateButton(f, "Clear", 40, 14)
            clearBtn:SetPoint("RIGHT", -4, 0)
            clearBtn:SetScript("OnClick", function() ns.Store:Dispatch("CLEAR_QUEUE") end)
            -- Push the queue to Profession Shopping List (one-way; PSL owns shopping).
            -- Only built when PSL is installed, so the label anchors to whichever
            -- button is actually the left-most.
            local rightAnchor = clearBtn
            if ns.PSLBridge:IsAvailable() then
                local pslBtn = ns.UI:CreateButton(f, "-> PSL", 50, 14)
                pslBtn:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)
                pslBtn:SetScript("OnClick", function()
                    ns.PSLBridge:SendQueue(ns.Store:GetState().crafting.queuedRecipes)
                end)
                rightAnchor = pslBtn
            end
            f.label:ClearAllPoints()
            f.label:SetPoint("TOPLEFT", 4, -3)
            f.label:SetPoint("BOTTOMRIGHT", rightAnchor, "BOTTOMLEFT", -4, 3)
            return f
        elseif node.id == "rcpMatHeader" then
            local f = ns.ViewKit.roleLabel(node, parent)
            local matToggle = ns.UI:CreateSegmentedToggle(f, {
                width = 100, height = 14,
                segments = {
                    { key = "direct", label = "Direct" },
                    { key = "raw", label = "Raw" },
                },
                default = ns.Store:GetState().config.materialsMode,
                onSelect = function(key)
                    if ns.Store:GetState().config.materialsMode ~= key then
                        ns.Store:Dispatch("TOGGLE_MATERIALS_MODE")
                    end
                end,
            })
            matToggle:SetPoint("RIGHT", -4, 0)
            -- Send the current shortfall (required-owned > 0) to an Auctionator
            -- shopping list. Merge per itemID first -- shoppingList repeats an
            -- item once per queued recipe that needs it.
            local ahBtn = ns.UI:CreateButton(f, "-> AH", 46, 14)
            ahBtn:SetPoint("RIGHT", matToggle, "LEFT", -6, 0)
            ahBtn:SetScript("OnClick", function()
                local byID = {}
                for _, mat in ipairs(ns.Store:GetState().crafting.shoppingList) do
                    local e = byID[mat.itemID]
                    if not e then e = { itemID = mat.itemID, required = 0, owned = mat.owned }; byID[mat.itemID] = e end
                    e.required = e.required + mat.required
                    e.owned = math.max(e.owned, mat.owned) -- dupes carry the same bag count
                end
                local rows = {}
                for _, e in pairs(byID) do
                    local missing = e.required - e.owned
                    if missing > 0 then rows[#rows + 1] = { itemID = e.itemID, missing = missing } end
                end
                ns.AuctionatorBridge:SendShortfall(rows)
            end)
            f.label:ClearAllPoints()
            f.label:SetPoint("TOPLEFT", 4, -3)
            f.label:SetPoint("BOTTOMRIGHT", ahBtn, "BOTTOMLEFT", -4, 3)
            return f
        end
        -- unhandled node -> Layout's default factory renders it (role label / container)
    end

    local handle = ns.Layout.build(container, ns.LayoutConfig.recipes, { makeFrame = makeFrame, measure = ns.ViewKit.measure })

    handle.byId.rcpNavLabel.label:SetText("Categories")

    -- Item 5d: pendingSelect consumer -- Records coverage cells send
    -- { profession = ..., expansion = ... } payloads via Nav.Go("workbench",
    -- { select = ... }). pendingSelect is view-scoped {view, value}: check the
    -- address BEFORE clearing so payloads bound for Showroom/Projects pass
    -- through untouched (clearing-then-type-checking ate them).
    local function consumePendingSelect()
        local p = R.untrack(function() return ns.Nav.pendingSelect() end)
        if p == nil or p.view ~= "workbench" then return end
        R.untrack(function() ns.Nav.pendingSelect(nil) end) -- clear without dep
        local payload = p.value
        if type(payload) ~= "table" then return end
        -- Shape: { profession = "key", expansion = "key" } from Records cells.
        if payload.profession and profBtnRow then
            profession(payload.profession)
            profBtnRow:Select(payload.profession)
        end
        if payload.expansion then
            ns.Store:Dispatch("SET_NAV_SELECTION", { exp = payload.expansion })
        end
    end
    -- Tracked wake-up: the profbar-effect call below covers mount ordering, but
    -- a jump landing AFTER mount must also consume -- this effect fires on every
    -- pendingSelect write and delegates to the same view-scoped consumer.
    R.effect(function()
        if ns.Nav.pendingSelect() == nil then return end
        consumePendingSelect()
    end, "recipes:pendingSelect")

    -- F1 continuation: scope pill shown when scopeCharacter is set.
    -- "planning as <name> [x]" pinned above the recipe list label.
    -- Created as a simple overlay on the rcpListCol panel; the pill frame is
    -- hidden by default and shown reactively. Label + dismiss button.
    scopePill = CreateFrame("Frame", nil, handle.byId.rcpListCol, "BackdropTemplate")
    scopePill:SetHeight(18)
    scopePill:SetPoint("TOPLEFT", handle.byId.rcpListCol, "TOPLEFT", 4, -4)
    scopePill:SetPoint("TOPRIGHT", handle.byId.rcpListCol, "TOPRIGHT", -4, -4)
    local pillBack = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 }
    local pillScheme = VWB.UI:GetScheme()
    scopePill:SetBackdrop(pillBack)
    scopePill:SetBackdropColor(pillScheme.accent.r, pillScheme.accent.g, pillScheme.accent.b, 0.18)
    scopePill:SetBackdropBorderColor(pillScheme.accent.r, pillScheme.accent.g, pillScheme.accent.b, 0.40)
    scopePill:SetFrameLevel(handle.byId.rcpListCol:GetFrameLevel() + 10)
    local pillLabel = scopePill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pillLabel:SetPoint("LEFT", 6, 0); pillLabel:SetPoint("RIGHT", -26, 0)
    pillLabel:SetJustifyH("LEFT"); pillLabel:SetTextColor(pillScheme.accent.r, pillScheme.accent.g, pillScheme.accent.b)
    scopePill.label = pillLabel
    local pillDismiss = CreateFrame("Button", nil, scopePill)
    pillDismiss:SetSize(16, 16); pillDismiss:SetPoint("RIGHT", -4, 0); pillDismiss:RegisterForClicks("AnyUp")
    local pillX = pillDismiss:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pillX:SetAllPoints(); pillX:SetText("x"); pillX:SetTextColor(pillScheme.accent.r, pillScheme.accent.g, pillScheme.accent.b)
    pillDismiss:SetScript("OnClick", function() ns.Store:Dispatch("CLEAR_SCOPE") end)
    scopePill:Hide()

    -- F1: reactive scope pill visibility + label; re-derives on nav slice.
    R.effect(function()
        ns.Store:Version("nav")
        local scope = ns.Store:GetState().ui.scopeCharacter
        if scope then
            local charName = scope:match("^(.-)%-") or scope
            pillLabel:SetText("planning as " .. charName)
            scopePill:Show()
        else
            scopePill:Hide()
        end
    end, "recipes:scopePill")

    -- First-run onboarding (no professions harvested yet) vs filtered-to-zero
    -- (professions exist, current filters just don't match anything) share one
    -- card widget; only the copy + CTA visibility differ per state.
    emptyCard = ns.UI:CreateEmptyStateCard(handle.byId.rcpListCol, {
        width = 300, height = 170,
        icon = "Interface\\Icons\\INV_Misc_Book_09",
        title = "The shelves are bare",
        body = "Scan a profession window, or pull your guild's recipes in one pass.",
        buttonText = "Scan Guild Recipes",
        onClick = function()
            ns:ShowPage("data")
            ns.RecipeHarvest:Start()
        end,
    })
    emptyCard:SetPoint("CENTER", handle.byId.rcpListCol, "CENTER", 0, 10)
    emptyCard:SetFrameLevel(listWidget:GetFrameLevel() + 5)

    -- Profession tab bar: rebuild only when the profession KEY SET actually
    -- changes (new recipes for an already-known profession must not tear down
    -- the bar and lose the current tab highlight).
    local lastProfSignature = nil
    R.effect(function()
        ns.Store:Version("recipes")
        local profs = ns.RecipeQuery:GetProfessions()
        local sig = ProfessionSignature(profs)
        if sig == lastProfSignature then return end
        lastProfSignature = sig

        ns.UI:ClearChildren(profTabBarContainer)
        if #profs == 0 then
            profBtnRow = nil
            profession(nil)
            return
        end
        profBtnRow = ns.UI:CreateProfessionTabBar(profTabBarContainer, profs, function(key)
            profession(key)
            ns.Store:Dispatch("SET_NAV_SELECTION", { exp = "AllExps" })
        end)
        local want = profession() or profs[1].key
        profession(want)
        profBtnRow:Select(want)
        -- Item 5d: consume pendingSelect AFTER profbar is wired (profBtnRow exists).
        -- Only runs the first time profbar builds (sig change); subsequent recipe
        -- additions reuse the existing bar and this no-ops (sig unchanged).
        consumePendingSelect()
    end, "recipes:profbar")

    -- Recipe chips (ComputeRecipeChips) read live collection status --
    -- Transmog:GetStatus / DecorOwnership:IsUncollected -- which live OUTSIDE the
    -- Store, so recipeList's slice subscriptions never see a collect. Repaint the
    -- visible rows when a collection event fires (the tick-only path Showroom's
    -- collectionTick uses), else a "new mog"/"uncollected" chip stays stale until
    -- an unrelated re-render.
    VWB.EventBus:Register("VWB_TRANSMOG_UPDATED", function() listWidget:Refresh() end)
    VWB.EventBus:Register("VWB_DECOR_OWNERSHIP_UPDATE", function() listWidget:Refresh() end)
    -- Mount/pet collection: bump collectionEpoch so recipeList re-derives and
    -- removes the newly collected item when the Missing pill is on.
    -- Collectibles.lua has no EventBus wrapper, so listen to raw Blizzard events.
    -- The frame is always registered; the epoch is only subscribed by recipeList
    -- when missingPill() is true, so the bump is a no-op when the pill is off.
    local mountPetFrame = CreateFrame("Frame")
    mountPetFrame:RegisterEvent("NEW_MOUNT_ADDED")
    mountPetFrame:RegisterEvent("NEW_PET_ADDED")
    mountPetFrame:SetScript("OnEvent", function()
        collectionEpoch(collectionEpoch() + 1)
    end)

    R.effect(function()
        local list = recipeList()
        listWidget:SetData(list)
        if not profession() then
            emptyCard.title:SetText("The shelves are bare")
            emptyCard.body:SetText("Scan a profession window, or pull your guild's recipes in one pass.")
            emptyCard.button:Show()
            emptyCard:Show()
        elseif #list == 0 then
            -- Cold-catalog: when the Missing pill is on (or Decor type is active)
            -- and the housing catalog hasn't been loaded, decor rows are excluded
            -- not because they're collected but because ownership is unknown.
            -- Surface the honest message rather than letting the list go silently empty.
            -- exception(boundary): IsCatalogCold checks Blizzard housing catalog state.
            local decorInScope = decorMode() ~= "off" or missingPill()
            if decorInScope and ns.DecorOwnership:IsCatalogCold() then
                emptyCard.title:SetText("Housing catalog not loaded")
                emptyCard.body:SetText("Open the housing catalog once this session, then come back.")
            elseif missingPill() then
                emptyCard.title:SetText("Nothing left to collect here")
                emptyCard.body:SetText("You have everything -- or no craftable collectibles match the current filters.")
            else
                emptyCard.title:SetText("Nothing matches")
                emptyCard.body:SetText("Try loosening a filter or clearing your search.")
            end
            emptyCard.button:Hide()
            emptyCard:Show()
        else
            emptyCard:Hide()
        end
    end, "recipes:list")
    R.bindText(handle.byId.rcpListLabel.label, function() return "Recipes (" .. #recipeList() .. ")" end)

    R.effect(function()
        navTreeWidget.selected = ns.Store:GetState().ui.navSelectedItem
        navTreeWidget:SetData(navSections())
    end, "recipes:nav")

    -- Collapse-all button label reflects the action it will take.
    R.effect(function()
        local anyOpen = false
        for _, s in ipairs(navSections()) do if not s.collapsed then anyOpen = true; break end end
        handle.byId.rcpNavLabel.collapseBtn:SetText(anyOpen and "Collapse" or "Expand")
    end, "recipes:collapseAllLabel")

    -- MRU strip: recent-queued icon chips (state.ui.recentQueued), click = requeue 1.
    -- Item 7: rcpMru collapses to h=0 when empty. The Layout engine's hug path for
    -- item nodes calls measure(node) -> ViewKit.measure which returns 14px for text
    -- (not 0/22). SetHeight directly is correct here: the mruContainer is a plain
    -- Frame not a Layout node with hug declared, and its slot in the right-panel
    -- stack used a fixed h=22. Toggle between 0 and 22 to collapse the strip when
    -- empty. The parent stack doesn't re-layout on SetHeight change (no reactive
    -- geometry), so we also show/hide to skip gap contribution. The Layout engine
    -- laid out with h=22; 0-height + hide removes visual space because the
    -- adjacent gap is absorbed by the next child's draw position.
    R.effect(function()
        ns.Store:Version("recent")
        local recent = ns.Store:GetState().ui.recentQueued
        local xOff = 2
        -- Item 7: collapse strip frame when empty; gap still exists but content is 0.
        mruContainer:SetHeight(#recent > 0 and MRU_BTN_SIZE or 0)
        for i, entry in ipairs(recent) do
            local b = mruButtons[i]
            if not b then
                b = CreateFrame("Button", nil, mruContainer)
                b:SetSize(MRU_BTN_SIZE, MRU_BTN_SIZE)
                b:RegisterForClicks("AnyUp")
                local icon = b:CreateTexture(nil, "ARTWORK")
                icon:SetAllPoints(); icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                b.icon = icon
                b:SetScript("OnEnter", function(self)
                    local tip = ns.UI.Tooltip
                    tip:Begin(self)
                    tip:AddTitle(self._name or "Recipe")
                    tip:AddLine(ns.UI:ColorCode("base01") .. "Click: queue 1|r")
                    tip:Show()
                end)
                b:SetScript("OnLeave", function(self) ns.UI.Tooltip:Hide(self) end)
                b:SetScript("OnClick", function(self)
                    ns.Store:Dispatch("ADD_TO_QUEUE", { recipeID = self._recipeID, qty = 1, name = self._name, itemID = self._itemID })
                    PushRecent(self._recipeID, self._itemID, self._name)
                end)
                mruButtons[i] = b
            end
            b._recipeID, b._itemID, b._name = entry.recipeID, entry.itemID, entry.name
            local rec = entry.recipeID and ns.Database:GetRecipe(entry.recipeID)
            b.icon:SetTexture((rec and rec.icon) or (entry.itemID and C_Item.GetItemIconByID(entry.itemID)) or QUESTION_ICON)
            b:ClearAllPoints()
            b:SetPoint("LEFT", mruContainer, "LEFT", xOff, 0)
            b:Show()
            xOff = xOff + MRU_BTN_SIZE + MRU_BTN_GAP
        end
        for i = #recent + 1, #mruButtons do mruButtons[i]:Hide() end
    end, "recipes:mru")

    R.effect(function() ns.Store:Version("crafting"); queueWidget:SetData(ns.Store:GetState().crafting.queuedRecipes) end, "recipes:queue")
    R.bindText(handle.byId.rcpQueueHeader.label, function()
        ns.Store:Version("crafting"); return "Crafting Queue (" .. #ns.Store:GetState().crafting.queuedRecipes .. ")"
    end)

    -- shoppingList carries Graph-baked names ("Loading..." for anything uncached
    -- at build time). Join each entry with matNameRes so a name that resolves
    -- later (GET_ITEM_INFO_RECEIVED) re-runs THIS effect and repaints the row --
    -- otherwise "Loading..." sticks until the next queue change.
    R.effect(function()
        ns.Store:Version("crafting")
        local mats = ns.Store:GetState().crafting.shoppingList
        local out = {}
        for i = 1, #mats do
            local mat = mats[i]
            local resolved = matNameRes(mat.itemID)
            if resolved ~= R.PENDING and resolved ~= mat.name then
                local copy = {}
                for k, v in pairs(mat) do copy[k] = v end
                copy.name = resolved
                out[i] = copy
            else
                out[i] = mat
            end
        end
        materialsWidget:SetData(out)
    end, "recipes:materials")
    R.bindText(handle.byId.rcpMatHeader.label, function() return "Reagents for Crafting Queue" end)

    return handle
end

return Recipes
