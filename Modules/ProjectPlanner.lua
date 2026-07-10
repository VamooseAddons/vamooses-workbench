VWB = VWB or {}
VWB.ProjectPlanner = {}

-- ============================================================================
-- VamoosesWorkbench - ProjectPlanner
-- Derives a live PLAN from a persisted project GOAL (state.projects.items).
-- Persist the goal, derive the plan: steps are recomputed from the Graph walk
-- + owned counts + prices + known-by data every time the view asks, so a plan
-- is never stale. Also owns the two watchers:
--   * collect auto-complete -- collection events sweep active collect projects
--     and dispatch COMPLETE_PROJECT (collection IS completion, no check-off)
--   * stock refill -- inventory updates sweep stock projects; crossing back up
--     to par dispatches PROJECT_REFILLED (the "times refilled" stat)
-- Step kinds: CRAFT / BUY / FARM / STAGE / BLOCKED per the spec table.
-- Design: docs/PROJECTS_SPEC_2026-07-11.md.
-- ============================================================================

local P = VWB.ProjectPlanner

-- ============================================================================
-- Target classification + collection state
-- ============================================================================

-- Same classification order the Showroom uses: decor -> transmog -> mount -> pet.
-- nil = not classifiable yet (cold item/catalog data) -- caller retries next derive.
function P:ClassifyTarget(itemID)
    if VWB.DecorOwnership:IsDecor(itemID) then return "decor" end
    if VWB.Transmog:IsTransmoggable(itemID) then return "transmog" end
    if VWB.Collectibles:IsMount(itemID) then return "mount" end
    if VWB.Collectibles:IsPet(itemID) then return "pet" end
    return nil -- exception(boundary): item data cold; kind unresolvable this pass
end

-- true/false = definitive answer; nil = no answer yet (cold catalog/cache).
function P:IsCollected(itemID)
    local kind = self:ClassifyTarget(itemID)
    if kind == "decor" then
        local un = VWB.DecorOwnership:IsUncollected(itemID)
        if un == nil then return nil end -- exception(boundary): housing catalog cold
        return not un
    elseif kind == "transmog" then
        return VWB.Transmog:GetStatus(itemID).isCollected
    elseif kind == "mount" then
        return VWB.Collectibles:IsMountCollected(itemID)
    elseif kind == "pet" then
        return VWB.Collectibles:IsPetCollected(itemID)
    end
    return nil
end

-- Stock level = current char + warband bank (5-arg GetItemCount path). Honest
-- and live; other alts' bags are NOT counted (no per-alt snapshots exist).
function P:StockLevel(itemID)
    return VWB.Inventory:GetItemCount(itemID)
end

-- ============================================================================
-- Plan derivation helpers
-- ============================================================================

-- charKeys (not display names) of scanned characters knowing the recipe,
-- current character first -- assignment wants keys, tooltips want names.
local function knowerKeys(recipeID)
    local current = VWB.CharacterData:GetCharacterKey()
    local out = {}
    for charKey, rec in pairs(VWB.Store:GetState().account.characters) do
        if rec.knownRecipes and rec.knownRecipes[recipeID] then -- exception(nullable): records saved before this field existed
            if charKey == current then table.insert(out, 1, charKey) else out[#out + 1] = charKey end
        end
    end
    return out
end

function P:DisplayName(charKey)
    local rec = VWB.Store:GetState().account.characters[charKey]
    return (rec and rec.name) or charKey -- exception(nullable): pin may outlive the character record
end

-- CRAFT step readiness: something to craft and every direct material covered.
local function craftReady(recipeID, missing)
    if missing <= 0 then return false end
    for _, m in ipairs(VWB.Graph:GetDirectMaterials(recipeID, missing)) do
        if m.missing > 0 then return false end
    end
    return true
end

-- Craft steps from the Graph walk, deepest-first (= craft order). A recipe
-- nobody on the account knows becomes a BLOCKED step (the Ask affordance).
local function appendCraftSteps(project, graphSteps, out)
    table.sort(graphSteps, function(a, b) return a.depth > b.depth end)
    for _, s in ipairs(graphSteps) do
        local stepKey = tostring(s.recipeID)
        local pin = project.pins and project.pins[stepKey]
        local who = pin or knowerKeys(s.recipeID)[1]
        if not who then
            out[#out + 1] = { kind = "BLOCKED", recipeID = s.recipeID, name = s.name, need = s.missing, stepKey = stepKey }
        else
            out[#out + 1] = {
                kind = "CRAFT", recipeID = s.recipeID, name = s.name, stepKey = stepKey,
                need = s.missing, owned = s.owned, required = s.required,
                charKey = who, pinned = pin ~= nil, depth = s.depth,
                ready = craftReady(s.recipeID, s.missing), done = s.missing == 0,
            }
        end
    end
end

-- Material steps from the fully-expanded shopping list: priced farmbuy -> BUY,
-- unpriced -> FARM (with the gather method when ReagentSource knows one).
local function appendMatSteps(plan, mats, out)
    for _, m in ipairs(mats) do
        if m.missing > 0 then
            plan.matsShort = plan.matsShort + 1
            local price = VWB.PriceIntegration:GetPrice(m.itemID)
            if price then
                out[#out + 1] = { kind = "BUY", itemID = m.itemID, name = m.name,
                    need = m.missing, owned = m.owned, unitPrice = price }
                plan.buyCost = plan.buyCost + price * m.missing
            else
                local info = VWB.ReagentSource:GetInfo(m.itemID)
                out[#out + 1] = { kind = "FARM", itemID = m.itemID, name = m.name,
                    need = m.missing, owned = m.owned, gatherMethod = info.gatherMethod }
            end
        end
    end
end

-- STAGE suggestion: the final craft belongs to another character but some of
-- the required mats sit in THIS character's bags -- unreachable to the crafter
-- until deposited in the warband bank. Bags-only count = plain GetItemCount.
local function appendStageStep(mats, finalWho, out)
    if not finalWho or finalWho == VWB.CharacterData:GetCharacterKey() then return end
    local held = 0
    for _, m in ipairs(mats) do
        held = held + math.min(m.required, C_Item.GetItemCount(m.itemID))
    end
    if held > 0 then
        out[#out + 1] = { kind = "STAGE", name = "Deposit mats to the warband bank",
            need = held, charKey = finalWho }
    end
end

local function planProgress(plan, mats, crafts)
    local total, done = 0, 0
    for _, m in ipairs(mats) do
        total = total + 1
        if m.missing == 0 then done = done + 1 end
    end
    for _, s in ipairs(crafts) do
        total = total + 1
        if s.kind == "CRAFT" and s.done then done = done + 1 end
    end
    plan.total, plan.done = total, done
end

-- ============================================================================
-- DerivePlan(project) -> plan
--   { status = "active"|"dormant"|"complete", steps = {stepKind rows...},
--     mats = shoppingList, done, total, matsShort, buyCost,
--     level/par (stock), unresolved (no recipe on file) }
-- ============================================================================

function P:DerivePlan(project)
    local plan = { steps = {}, mats = {}, matsShort = 0, buyCost = 0, done = 0, total = 0 }

    local qty
    if project.kind == "stock" then
        plan.level = self:StockLevel(project.itemID)
        plan.par = project.par or 1
        plan.status = plan.level >= plan.par and "dormant" or "active"
        qty = math.max(0, plan.par - plan.level)
    else
        local collected = project.completedAt ~= nil or self:IsCollected(project.itemID) == true
        plan.status = collected and "complete" or "active"
        qty = 1
    end

    local recipeID = project.recipeID or VWB.Database:GetRecipeByItemID(project.itemID, true)
    if not recipeID then
        plan.unresolved = true -- exception(nullable): recipe not harvested yet; plan is goal-only
        return plan
    end
    if plan.status ~= "active" or qty == 0 then return plan end

    local graphSteps = VWB.Graph:CalculateCraftingSteps(recipeID, qty)
    plan.mats = VWB.Graph:CalculateTotalMats(graphSteps)

    local crafts = {}
    appendCraftSteps(project, graphSteps, crafts)
    appendMatSteps(plan, plan.mats, plan.steps)
    appendStageStep(plan.mats, crafts[#crafts] and crafts[#crafts].charKey, plan.steps)
    for _, s in ipairs(crafts) do plan.steps[#plan.steps + 1] = s end

    planProgress(plan, plan.mats, crafts)
    return plan
end

-- ============================================================================
-- Watchers: collect auto-complete + stock refill detection
-- ============================================================================

local prevBelowPar = {} -- [projectId] = true while a stock project sits below par

local function sweepCollectCompletions()
    for _, p in ipairs(VWB.Store:GetState().projects.items) do
        if p.kind == "collect" and not p.completedAt and P:IsCollected(p.itemID) == true then
            VWB.Store:Dispatch("COMPLETE_PROJECT", { id = p.id })
        end
    end
end

local function sweepStockRefills()
    for _, p in ipairs(VWB.Store:GetState().projects.items) do
        if p.kind == "stock" then
            local below = P:StockLevel(p.itemID) < (p.par or 1)
            if prevBelowPar[p.id] and not below then
                VWB.Store:Dispatch("PROJECT_REFILLED", { id = p.id })
            end
            prevBelowPar[p.id] = below or nil
        end
    end
end

function P:Initialize()
    local f = CreateFrame("Frame")
    f:RegisterEvent("NEW_MOUNT_ADDED")
    f:RegisterEvent("NEW_PET_ADDED")
    f:SetScript("OnEvent", sweepCollectCompletions)
    VWB.EventBus:Register("VWB_TRANSMOG_UPDATED", sweepCollectCompletions)
    VWB.EventBus:Register("VWB_DECOR_OWNERSHIP_UPDATE", sweepCollectCompletions)
    VWB.EventBus:Register("VWB_INVENTORY_UPDATE", sweepStockRefills)
end
