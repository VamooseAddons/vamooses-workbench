-- ============================================================================
-- VWB Workbench (Recipes) - VIEW / controller. Slice: FULL FILTER SURFACE.
-- ============================================================================
-- The flagship crafting tab's left side, wired to real data. This tab is
-- RECIPE knowledge (knowledge-domain ruling 2026-07-11: Workbench = what can
-- I make; Showroom = what do I want to own; Stockroom = what do I hold):
-- profession tab bar + output-type selector (All/Decor/Transmog/Mount/Pet)
-- + recipe-state pills (Craftable / Skill-Up / Unlearned-by-scoped-char) +
-- an expansion/category nav tree all feed ONE shared filteredBase computed. Recipe rows
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

-- Reagent-name resolver: shared addon-wide resource (VWB.UI:ItemNameResource).
-- shoppingList entries are named at Graph-build time, so an item uncached then
-- is baked "Loading..." and never refreshes on its own (Graph re-runs only on a
-- queue change). The shared resource re-reads on ITEM_DATA_LOAD_RESULT so the
-- materials effect re-derives the name live. One resource shared across views
-- (Recipes + Projects) so a name resolved in one is warm in the other.

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
    local c = ns.UI:GetScheme()
    frame._washHandle = ns.UI:AttachTransitionWash(frame, c.success.r, c.success.g, c.success.b)
end

-- Queue rows use the canonical VWB.UI:BuildQueueRow (unification 2026-07-11);
-- the drifted local template that lived here is gone. Wiring is in the
-- rcpQueue makeFrame branch below.

-- ============================================================================
-- CRAFT EXECUTION (donor: HDG HDGR_Controller_Recipes.lua craft dialog +
-- VPC Recipes.lua ExecuteQueueCraft refinements -- both shipped patterns).
-- Flow: hammer click -> profession window closed or wrong prof? OpenRecipe()
-- opens/navigates the journal AT the recipe and the user clicks again ->
-- confirm popup (qty editbox + steppers / Craft Max) -> CraftRecipe.
-- ============================================================================

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
        VWB.Log:Print("Profession window closed -- click the hammer again to reopen it.")
        return
    end
    local recipe = ns.Database:GetRecipe(item.recipeID)
    local base = C_TradeSkillUI.GetBaseProfessionInfo() -- exception(boundary): nil with no window open
    if not base or base.professionName ~= recipe.profession then
        VWB.Log:Print(recipe.profession .. "'s window needs to be open for this one.")
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
            VWB.Log:Print("Not enough materials to craft even one.")
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
        VWB.Log:Print("Opening the profession window -- click the hammer again to craft.")
        return
    end
    local recipe = ns.Database:GetRecipe(item.recipeID)
    local base = C_TradeSkillUI.GetBaseProfessionInfo() -- exception(boundary): nil with no window open
    if not base or base.professionName ~= recipe.profession then
        C_TradeSkillUI.OpenRecipe(item.recipeID)
        VWB.Log:Print("Switching to " .. recipe.profession .. " -- click the hammer again to craft.")
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

-- KNOWLEDGE-DOMAIN split (owner ruling 2026-07-11 night): the Workbench is
-- RECIPE knowledge (what can I make -- known/unlearned/craftable/skill-up,
-- keyed by recipeID, scoped by character); the Showroom is ITEM/collection
-- knowledge (what do I want to own -- collected/missing, keyed by itemID).
-- So this bar's filters are recipe-state filters:
--   kindMode  = the recipe's OUTPUT TYPE (all|decor|transmog|mount|pet) --
--               a recipe attribute, classified through the Collectibles
--               canonical chain; never disabled (cold catalog surfaces the
--               honest empty state instead).
--   Unlearned = recipes the SCOPED character does not know (Blizzard's
--               tradeskill vocabulary). Item-collection "Missing" lives in
--               the Showroom ONLY -- it was briefly here and made the two
--               tabs answer the same question with different numbers.
-- Craftable and Skill-Up remain independent mechanical filters on top.
local KIND_SEGMENTS = {
    { key = "all", label = "All" }, { key = "decor", label = "Decor" },
    { key = "transmog", label = "Transmog" }, { key = "mount", label = "Mount" },
    { key = "pet", label = "Pet" },
}

local function passesKind(itemID, kind)
    if kind == "all" then return true end
    if not itemID then return false end -- no output item (enchants/writs): no output type to match
    return ns.Collectibles:ClassifyKind(itemID) == kind
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
        -- Perf D6: CountShortMaterials is the paint-path variant of
        -- GetDirectMaterials -- no row-table allocs, no name resolution (which
        -- fires requestNameOnce server requests a paint must never trigger).
        local shortCount = ns.Graph:CountShortMaterials(recipeID)
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

-- Group an already-filtered entry array ({recipeID, recipe} from the shared
-- filteredBase computed -- perf A1 2026-07-11: this used to run its own
-- GetFiltered corpus walk) into expansion sections / category items for
-- CreateNavTree (header = expansion, item = "exp::category"). Pure derivation
-- only -- a stale nav selection (filtered down to zero) is left for the user
-- to clear by clicking elsewhere; no write happens from a read path (Reactor
-- computeds must stay side-effect free).
local function BuildNavSections(results, searchFilter, exps)
    local expCatCounts = {}
    for _, entry in ipairs(results) do
        local r = entry.recipe
        if r.expansion then
            local cats = expCatCounts[r.expansion]
            if not cats then cats = {}; expCatCounts[r.expansion] = cats end
            local cat = r.categoryName or "Uncategorized"
            cats[cat] = (cats[cat] or 0) + 1
        end
    end

    local forceOpenTree = searchFilter ~= ""
    local navCollapsed = ns.Store:GetState().ui.navCollapsed

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
-- Perf E3: capped -- wiped past 4096 entries (a wipe only costs the flash
-- baseline; the next paint of each row re-seeds it).
local priorCraftable = {}
local priorCraftableCount = 0

function Recipes.buildView(container)
    local R = ns.Reactor
    local matNameRes = ns.UI:ItemNameResource() -- shared addon-wide resource (see module header comment)

    -- F1 FIX: effectiveCharKey reads scope-or-own LIVE inside computeds and
    -- chip logic. Was captured once at mount (line 268) -- that constant never
    -- saw SET_SCOPE writes. Nav slice subscription in recipeList ensures this
    -- re-derives on every scope change. Store:Version("nav") already subscribed.
    local function effectiveCharKey()
        return ns.Store:GetState().ui.scopeCharacter or ns.CharacterData:GetCharacterKey()
    end

    local search = R.signal("")
    local profession = R.signal(nil)
    local kindMode = R.signal("all") -- category selector: all|transmog|pet|mount|decor (Showroom parity)
    local canCraftOnly = R.signal(false)
    local skillUpOnly = R.signal(false)
    local unlearnedPill = R.signal(false) -- recipe knowledge: not known by the scoped character
    -- Collection events bump VWB.Collectibles.CollectionEpoch() (one owner, Collectibles.lua).
    -- Views read CollectionEpoch() as a reactive signal; no view-local epoch needed.

    local listWidget, queueWidget, materialsWidget, navTreeWidget
    local profTabBarContainer, profBtnRow
    local mruContainer, mruButtons = nil, {}
    local emptyCard
    local scopePill  -- "planning as <name> [x]" pill; shown when scope is active

    -- Perf A1 (2026-07-11): ONE shared corpus walk. filteredBase runs
    -- GetFiltered WITHOUT expansion/category (the nav tree IS that selector);
    -- recipeList post-filters the base array (cheap) and navSections groups it.
    -- Previously recipeList and BuildNavSections each ran their own full
    -- GetFiltered walk, and GetExpansions added a third.
    --
    -- Scoped to the exact slices the filters touch (NOT the blanket
    -- Store:Version()) so a config/minimap-only dispatch never re-derives this.
    -- nav slice covers SET_SCOPE writes so effectiveCharKey() re-derives live.
    -- The crafting slice is subscribed ONLY while the Craftable pill is on
    -- (CanCraft nets out queue commitments) -- with the pill off, a queue
    -- keystroke no longer re-runs any corpus walk.
    local filteredBase = R.named("recipes:filteredBase", function()
        ns.Store:Version("recipes")
        ns.Store:Version("characters")
        ns.Store:Version("nav") -- covers SET_SCOPE / CLEAR_SCOPE writes

        local prof = profession()
        if not prof then return {} end

        local kind = kindMode()
        local unlearned = unlearnedPill()
        -- Output-type classification lives outside the Store: subscribe the
        -- epochs while the type filter is scoped -- a broker record landing
        -- or a decor reconcile can flip an item's classification.
        if kind ~= "all" then
            VWB.Collectibles.CollectionEpoch()
            VWB.ItemData.changedEpoch()
        end
        local cco = canCraftOnly()
        if cco then ns.Store:Version("crafting") end
        local me = effectiveCharKey()
        local q = search()
        local results = ns.RecipeQuery:GetFiltered({
            collapseRanks = true,
            profession = prof,
            search = q ~= "" and q or nil,
            canCraftOnly = cco,
            skillUpOnly = skillUpOnly(),
        })
        if kind == "all" and not unlearned then return results end
        -- Output-type / Unlearned post-filter, applied HERE so list rows and
        -- nav counts stay in step (navSections groups this same array).
        -- Unlearned = recipe knowledge (not known by the SCOPED character;
        -- the "alt" chip still marks known-elsewhere), NOT item collection.
        local out = {}
        for _, e in ipairs(results) do
            if passesKind(e.recipe.itemID, kind)
                and (not unlearned or not ns.KnownRecipes:IsKnownBy(e.recipeID, me)) then
                out[#out + 1] = e
            end
        end
        return out
    end)

    local recipeList = R.named("recipes:recipeList", function()
        ns.Store:Version("nav") -- navSelectedExp / navSelectedItem clicks
        local uiState = ns.Store:GetState().ui
        local exp = uiState.navSelectedExp
        if exp == "AllExps" then exp = nil end -- GetFiltered's "no filter" spelling
        local cat = nil
        if uiState.navSelectedItem then
            local _, c = uiState.navSelectedItem:match("^(.-)::(.+)$")
            cat = c
        end
        local out = {}
        for _, e in ipairs(filteredBase()) do
            local r = e.recipe
            if (not exp or r.expansion == exp) and (not cat or r.categoryName == cat) then
                out[#out + 1] = r
            end
        end
        return out
    end)

    -- Expansion list for the nav tree: corpus + profession only -- a search
    -- keystroke or queue edit must not re-walk the corpus for this.
    local profExpansions = R.named("recipes:profExpansions", function()
        ns.Store:Version("recipes")
        local prof = profession()
        if not prof then return {} end
        return ns.RecipeQuery:GetExpansions(prof)
    end)

    -- Nav tree mirrors the list's filter universe MINUS expansion/category (the
    -- tree IS that selector) so section counts match what the list would show.
    -- No profession guard needed: filteredBase and profExpansions both return
    -- {} pre-profession, and BuildNavSections over empty inputs is {}.
    local navSections = R.named("recipes:navSections", function()
        ns.Store:Version("nav") -- navCollapsed toggles
        return BuildNavSections(filteredBase(), search(), profExpansions())
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
        elseif node.id == "craftablePill" then
            return ns.UI:CreateFilterPill(parent, "Craftable", function(checked) canCraftOnly(checked) end)
        elseif node.id == "skillUpPill" then
            return ns.UI:CreateFilterPill(parent, "Skill-Up", function(checked) skillUpOnly(checked) end)
        elseif node.id == "kindToggle" then
            -- Showroom's exact construction (flat segments, not the pill atlas
            -- variant -- the unselected auctionhouse-nav-button pill reads as
            -- DISABLED, the "Decor greyed out on first open" report).
            return ns.UI:CreateSegmentedToggle(parent, {
                width = (node.size and node.size.w) or 300, height = (node.size and node.size.h) or 18,
                segments = KIND_SEGMENTS, default = "all",
                onSelect = function(key) kindMode(key) end,
            })
        elseif node.id == "unlearnedPill" then
            return ns.UI:CreateFilterPill(parent, "Unlearned", function(checked) unlearnedPill(checked and true or false) end)
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
                    row.icon:SetTexture(item.icon or C_Item.GetItemIconByID(item.itemID) or VWB.Constants.ClassificationIcons.Misc)
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
                    if prev == nil then
                        priorCraftableCount = priorCraftableCount + 1
                        if priorCraftableCount > 4096 then priorCraftable = {}; priorCraftableCount = 1 end
                    end
                    priorCraftable[item.recipeID] = craftableNow
                end,
                onRowClick = function(item)
                    -- Ctrl: Wowhead. Shift: Showroom preview. Alt: queue 5
                    -- (VPC's shift-click-5, remapped -- shift navigates here).
                    -- Plain: queue 1.
                    if IsControlKeyDown() and item.recipeID then
                        ShowWowheadLink(item.recipeID)
                    elseif IsShiftKeyDown() and item.itemID then
                        ns.Nav.Go("showroom", { select = item.itemID })
                    else
                        local qty = IsAltKeyDown() and 5 or 1
                        ns.Store:Dispatch("ADD_TO_QUEUE", { recipeID = item.recipeID, qty = qty })
                        PushRecent(item.recipeID, item.itemID, item.name)
                    end
                end,
                onRowEnter = function(item, row)
                    local tip = ns.UI.Tooltip
                    tip:Begin(row)
                    if item.itemID then
                        tip:SetItemHeader(item.itemID, item.name) -- renders the #id line itself
                    else
                        tip:AddTitle(item.name or "Unknown")
                        tip:AddLine(ns.UI:ColorCode("base01") .. "#" .. tostring(item.recipeID) .. "|r")
                    end

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
                    -- Two lines: four gestures on one line overran the tooltip width
                    tip:AddLine(ns.UI:ColorCode("base01") .. "Click: queue 1  -  Alt-click: queue 5|r")
                    tip:AddLine(ns.UI:ColorCode("base01") .. "Shift: Showroom  -  Ctrl: Wowhead link|r")
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
                rowHeight = 20,
                rowTemplate = function(frame)
                    ns.UI:BuildQueueRow(frame, {
                        onRemove = function(item)
                            ns.Store:Dispatch("REMOVE_FROM_QUEUE", { recipeID = item.recipeID, charKey = item.charKey })
                        end,
                        onQtyDelta = function(item, delta)
                            ns.Store:Dispatch("UPDATE_QUEUE_QTY", {
                                recipeID = item.recipeID, charKey = item.charKey,
                                qty = (item.qty or 1) + delta,
                            })
                        end,
                        onCraft = OnCraftClick,
                    })
                end,
                updateRow = function(row, item)
                    row:SetData(item)
                    -- Enchants/Writs have no output item -> use the recipe's own icon
                    -- (what the recipe list already does), not the "?" fallback.
                    if not item.itemID then
                        local rec = item.recipeID and ns.Database:GetRecipe(item.recipeID) -- exception(nullable): queue can hold recipes gone from the DB
                        if rec and rec.icon then row.icon:SetTexture(rec.icon) end
                    end
                end,
                onRowClick = function(item)
                    if IsControlKeyDown() and item.recipeID then ShowWowheadLink(item.recipeID) end
                end,
                onRowEnter = function(item, row) ns.UI:QueueRowTooltip(item, row) end,
                onRowLeave = function(_, row)
                    ns.GuildCrafters:CancelTooltip()
                    ns.UI.Tooltip:Hide(row)
                end,
            })
            return queueWidget
        elseif node.id == "rcpMaterials" then
            materialsWidget = ns.UI:CreateVirtualizedList(parent, {
                rowHeight = 18, rowTemplate = matRowTemplate,
                updateRow = function(row, item)
                    row.data = item
                    row.icon:SetTexture(C_Item.GetItemIconByID(item.itemID) or VWB.Constants.ClassificationIcons.Misc)
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
    -- "planning as <name> [x]", docked COMPACT at the header row's right end --
    -- the first cut spanned the full column width and sat on top of the
    -- "Recipes (N)" title as an unreadable blue band (live report 2026-07-11).
    scopePill = CreateFrame("Frame", nil, handle.byId.rcpListCol, "BackdropTemplate")
    scopePill:SetSize(180, 18)
    scopePill:SetPoint("TOPRIGHT", handle.byId.rcpListCol, "TOPRIGHT", -4, -4)
    local pillScheme = ns.UI:GetScheme()
    scopePill:SetBackdrop(VWB.UI.BACKDROP_FLAT --[[@as backdropInfo]])
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

    -- Gap A: scope pill chrome was painted once with a stale pillScheme; re-read
    -- on every theme switch so the accent color tracks the live scheme.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint scope-pill chrome on switch
        local c = ns.UI:GetScheme()
        scopePill:SetBackdropColor(c.accent.r, c.accent.g, c.accent.b, 0.18)
        scopePill:SetBackdropBorderColor(c.accent.r, c.accent.g, c.accent.b, 0.40)
        pillLabel:SetTextColor(c.accent.r, c.accent.g, c.accent.b)
        pillX:SetTextColor(c.accent.r, c.accent.g, c.accent.b)
    end, "recipes:scopePillChrome")

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
        VWB.Theme.epoch() -- theme epoch: repaint on switch
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
    -- Transmog:GetStatus / DecorOwnership:IsUncollected -- which live OUTSIDE
    -- the Store, so recipeList's slice subscriptions never see a collect.
    -- ONE listener repaints visible rows: Collectibles' fan-out already fires
    -- for every collection source (mounts/pets raw events + the transmog and
    -- decor change-gated events) -- the direct per-event registrations that
    -- sat here doubled every repaint (step 5 cleanup).
    VWB.Collectibles:RegisterCollectionListener(function() listWidget:Refresh() end)

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        local list = recipeList()
        listWidget:SetData(list)
        if not profession() then
            emptyCard.title:SetText("The shelves are bare")
            emptyCard.body:SetText("Scan a profession window, or pull your guild's recipes in one pass.")
            emptyCard.button:Show()
            emptyCard:Show()
        elseif #list == 0 then
            -- Cold-catalog: when the Decor output type is active and the
            -- housing catalog hasn't been loaded, decor rows are excluded not
            -- because they don't exist but because classification is unknown.
            -- Surface the honest message rather than letting the list go silently empty.
            -- exception(boundary): IsCatalogCold checks Blizzard housing catalog state.
            if kindMode() == "decor" and ns.DecorOwnership:IsCatalogCold() then
                emptyCard.title:SetText("Housing catalog not loaded")
                emptyCard.body:SetText("Open the housing catalog once this session, then come back.")
            elseif unlearnedPill() then
                emptyCard.title:SetText("Nothing left to learn here")
                emptyCard.body:SetText("This character knows every matching recipe -- switch character scope in the Roster to plan an alt.")
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
        VWB.Theme.epoch() -- theme epoch: repaint on switch
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
            b.icon:SetTexture((rec and rec.icon) or (entry.itemID and C_Item.GetItemIconByID(entry.itemID)) or VWB.Constants.ClassificationIcons.Misc)
            b:ClearAllPoints()
            b:SetPoint("LEFT", mruContainer, "LEFT", xOff, 0)
            b:Show()
            xOff = xOff + MRU_BTN_SIZE + MRU_BTN_GAP
        end
        for i = #recent + 1, #mruButtons do mruButtons[i]:Hide() end
    end, "recipes:mru")

    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint on switch
        ns.Store:Version("crafting")
        queueWidget:SetData(ns.Store:GetState().crafting.queuedRecipes)
    end, "recipes:queue")
    R.bindText(handle.byId.rcpQueueHeader.label, function()
        ns.Store:Version("crafting"); return "Crafting Queue (" .. #ns.Store:GetState().crafting.queuedRecipes .. ")"
    end)

    -- shoppingList carries Graph-baked names ("Loading..." for anything uncached
    -- at build time). Join each entry with matNameRes so a name that resolves
    -- later (GET_ITEM_INFO_RECEIVED) re-runs THIS effect and repaints the row --
    -- otherwise "Loading..." sticks until the next queue change.
    R.effect(function()
        VWB.Theme.epoch() -- theme epoch: repaint pooled rows on switch
        ns.Store:Version("crafting")
        local mats = ns.Store:GetState().crafting.shoppingList
        -- Perf A4: allocate the joined array only when some name actually
        -- resolved differently; the common no-mismatch repaint passes the
        -- Graph-built list straight through (SetData never mutates it).
        local out = nil
        for i = 1, #mats do
            local mat = mats[i]
            local resolved = matNameRes(mat.itemID)
            if resolved ~= R.PENDING and resolved ~= mat.name then
                if not out then
                    out = {}
                    for j = 1, i - 1 do out[j] = mats[j] end
                end
                local copy = {}
                for k, v in pairs(mat) do copy[k] = v end
                copy.name = resolved
                out[i] = copy
            elseif out then
                out[i] = mat
            end
        end
        materialsWidget:SetData(out or mats)
    end, "recipes:materials")
    R.bindText(handle.byId.rcpMatHeader.label, function() return "Reagents for Crafting Queue" end)

    return handle
end

return Recipes
