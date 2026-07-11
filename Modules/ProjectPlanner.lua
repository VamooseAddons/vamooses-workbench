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

-- Canonical chain lives in the Collectibles module (decor -> transmog ->
-- mount -> pet, cold-safe memoization). nil = not classifiable yet (cold
-- item/catalog data) -- caller retries next derive.
function P:ClassifyTarget(itemID)
    local k = VWB.Collectibles:ClassifyKind(itemID)
    if k == "none" then return nil end -- exception(boundary): non-collectible OR cold identity; retried next pass
    return k
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
-- pins is the owning PIECE's pin map (v2).
local function appendCraftSteps(pins, graphSteps, out)
    table.sort(graphSteps, function(a, b) return a.depth > b.depth end)
    for _, s in ipairs(graphSteps) do
        local stepKey = tostring(s.recipeID)
        local pin = pins and pins[stepKey]
        local who = pin or knowerKeys(s.recipeID)[1]
        if not who then
            -- Only when something is actually demanded: a "0x" blocked step
            -- (outputs already owned) asks nobody for nothing -- pure noise.
            if s.missing > 0 then
                out[#out + 1] = { kind = "BLOCKED", recipeID = s.recipeID, name = s.name, need = s.missing, stepKey = stepKey }
            end
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
-- DerivePiecePlan(piece) -> piecePlan  (the v1 per-item plan, per PIECE)
--   { status = "active"|"dormant"|"complete", steps = {stepKind rows...},
--     mats = shoppingList, done, total, matsShort, buyCost,
--     level/par (stock), unresolved (no recipe on file) }
-- Completed pieces short-circuit BEFORE the Graph walk (perf ruling: a
-- 20-piece achievement project in steady state must not re-walk done work).
-- ============================================================================

function P:DerivePiecePlan(piece)
    local plan = { steps = {}, mats = {}, matsShort = 0, buyCost = 0, done = 0, total = 0 }
    if piece.completedAt then plan.status = "complete"; return plan end

    local qty
    if piece.kind == "stock" then
        plan.level = self:StockLevel(piece.itemID)
        plan.par = piece.par or 1
        plan.status = plan.level >= plan.par and "dormant" or "active"
        qty = math.max(0, plan.par - plan.level)
    else
        -- achievement-kind pieces complete via the criteria sweep ONLY (a
        -- collected item does not satisfy a know/craft criterion)
        local collected = piece.kind == "collect" and self:IsCollected(piece.itemID) == true
        plan.status = collected and "complete" or "active"
        qty = 1
    end

    local recipeID = piece.recipeID or VWB.Database:GetRecipeByItemID(piece.itemID, true)
    if not recipeID then
        plan.unresolved = true -- exception(nullable): recipe not harvested yet; plan is goal-only
        return plan
    end
    if plan.status ~= "active" or qty == 0 then return plan end

    local graphSteps = VWB.Graph:CalculateCraftingSteps(recipeID, qty)
    plan.mats = VWB.Graph:CalculateTotalMats(graphSteps)

    local crafts = {}
    appendCraftSteps(piece.pins, graphSteps, crafts)
    appendMatSteps(plan, plan.mats, plan.steps)
    appendStageStep(plan.mats, crafts[#crafts] and crafts[#crafts].charKey, plan.steps)
    for _, s in ipairs(crafts) do plan.steps[#plan.steps + 1] = s end

    planProgress(plan, plan.mats, crafts)
    return plan
end

-- ============================================================================
-- DerivePlan(project) -> project plan (v2: aggregates over piece plans)
--   { status = "active"|"complete", pieces = { piecePlan... },
--     done/total = PIECE counts, matsShort, buyCost, mats = merged list }
-- Aggregate mats sum required/missing per item across pieces. KNOWN
-- LIMITATION: each piece plan reads live owned counts independently, so two
-- pieces sharing a reagent both claim the same stock (aggregate missing
-- UNDER-counts). Self-corrects as crafts consume; per-piece plans (the
-- queueing surface) are always honest.
-- ============================================================================

function P:DerivePlan(project)
    local agg = { pieces = {}, mats = {}, matsShort = 0, buyCost = 0,
        done = 0, total = #project.pieces }
    local matsByItem, matOrder = {}, {}
    for i, piece in ipairs(project.pieces) do
        local pp = self:DerivePiecePlan(piece)
        agg.pieces[i] = pp
        if pp.status == "complete" then agg.done = agg.done + 1 end
        agg.matsShort = agg.matsShort + pp.matsShort
        agg.buyCost = agg.buyCost + pp.buyCost
        for _, m in ipairs(pp.mats) do
            local a = matsByItem[m.itemID]
            if not a then
                a = { itemID = m.itemID, name = m.name, required = 0, missing = 0, owned = m.owned }
                matsByItem[m.itemID] = a
                matOrder[#matOrder + 1] = a
            end
            a.required = a.required + m.required
            a.missing = a.missing + m.missing
        end
    end
    agg.mats = matOrder
    agg.status = (project.completedAt or (agg.total > 0 and agg.done == agg.total)) and "complete" or "active"
    return agg
end

-- ============================================================================
-- Watchers: collect auto-complete + stock refill detection
-- ============================================================================

local prevBelowPar = {} -- ["projectId:pieceIndex"] = true while a stock piece sits below par

-- The ONE promotion rule, shared by every completion sweep: a project with
-- pieces, all stamped, becomes Done. Zero-piece projects never auto-complete.
local function promoteIfAllDone(prj)
    if #prj.pieces == 0 then return end
    for _, pc in ipairs(prj.pieces) do
        if not pc.completedAt then return end
    end
    VWB.Store:Dispatch("COMPLETE_PROJECT", { id = prj.id })
end

-- Collection events sweep incomplete collect PIECES; a collected piece gets
-- COMPLETE_PIECE, and a project whose every piece is now stamped gets
-- COMPLETE_PROJECT (boundary-handler-driven promotion -- the R2/R3 ruling:
-- never from a computed/effect). Stock pieces never stamp completedAt --
-- they are perpetual par-keepers, so a project holding one stays active by
-- design. B3 early-return keeps the no-collect-projects case free.
local function sweepCollectCompletions()
    local items = VWB.Store:GetState().projects.items
    local hasActive = false
    for _, prj in ipairs(items) do
        if not prj.completedAt then
            for _, pc in ipairs(prj.pieces) do
                if pc.kind == "collect" and not pc.completedAt then hasActive = true; break end
            end
        end
        if hasActive then break end
    end
    if not hasActive then return end
    for _, prj in ipairs(items) do
        if not prj.completedAt then
            for _, pc in ipairs(prj.pieces) do
                if pc.kind == "collect" and not pc.completedAt and P:IsCollected(pc.itemID) == true then
                    VWB.Store:Dispatch("COMPLETE_PIECE", { projectId = prj.id, pieceId = pc.id })
                end
            end
            promoteIfAllDone(prj)
        end
    end
end

-- Study-sourced pieces complete when the RECIPE is learned -- their goal is
-- knowledge, not collection (code review F3). Swept on the profession-scan
-- event, which is exactly when the known set can change.
local function sweepStudyLearns()
    for _, prj in ipairs(VWB.Store:GetState().projects.items) do
        if not prj.completedAt then
            local touched = false
            for _, pc in ipairs(prj.pieces) do
                if pc.kind == "study" and not pc.completedAt and VWB.KnownRecipes:IsKnown(pc.recipeID) then
                    VWB.Store:Dispatch("COMPLETE_PIECE", { projectId = prj.id, pieceId = pc.id })
                    touched = true
                end
            end
            if touched then promoteIfAllDone(prj) end
        end
    end
end

local function sweepStockRefills()
    local items = VWB.Store:GetState().projects.items
    local hasStock = false
    for _, prj in ipairs(items) do
        for _, pc in ipairs(prj.pieces) do
            if pc.kind == "stock" then hasStock = true; break end
        end
        if hasStock then break end
    end
    if not hasStock then return end
    for _, prj in ipairs(items) do
        for _, pc in ipairs(prj.pieces) do
            if pc.kind == "stock" then
                local key = prj.id .. ":" .. pc.id -- pieceId key: survives removals mid-session
                local below = P:StockLevel(pc.itemID) < (pc.par or 1)
                if prevBelowPar[key] and not below then
                    VWB.Store:Dispatch("PROJECT_REFILLED", { id = prj.id, pieceId = pc.id })
                end
                prevBelowPar[key] = below or nil
            end
        end
    end
end

-- Achievement-sourced commissions: the trust pipeline (owner review: one
-- stale piece counter and the board loses to the Blizzard UI). Criteria are
-- read LIVE per piece.criteriaIndex -- no dependency on the Achieve view's
-- latch walk. Both handlers are boundary latches: read, compare, dispatch.
local achSettle = nil

-- PIECE-LEVEL identity (v3): criteria tick wherever the piece lives, so one
-- commission can track multiple achievements. The gate is pc.achievementID,
-- never the project's source (that is display provenance only).
local function sweepAchievementCriteria()
    for _, prj in ipairs(VWB.Store:GetState().projects.items) do
        if not prj.completedAt then
            local touched = false
            for _, pc in ipairs(prj.pieces) do
                if not pc.completedAt and pc.achievementID and pc.criteriaIndex then
                    local _, _, done = GetAchievementCriteriaInfo(pc.achievementID, pc.criteriaIndex)
                    if done then
                        VWB.Store:Dispatch("COMPLETE_PIECE", { projectId = prj.id, pieceId = pc.id })
                        touched = true
                    end
                end
            end
            if touched then promoteIfAllDone(prj) end
        end
    end
end

-- Stamps the earned achievement's OWN criteria pieces only (a piece added
-- manually is extra work the earn does not vouch for); promotion then
-- follows the one shared rule.
local function onAchievementEarned(achievementID)
    for _, prj in ipairs(VWB.Store:GetState().projects.items) do
        if not prj.completedAt then
            local touched = false
            for _, pc in ipairs(prj.pieces) do
                if not pc.completedAt and pc.achievementID == achievementID then
                    VWB.Store:Dispatch("COMPLETE_PIECE", { projectId = prj.id, pieceId = pc.id })
                    touched = true
                end
            end
            if touched then promoteIfAllDone(prj) end
        end
    end
end

function P:Initialize()
    -- B2: Replace the duplicate CreateFrame(NEW_MOUNT_ADDED/NEW_PET_ADDED) plus the
    -- direct VWB_TRANSMOG_UPDATED and VWB_DECOR_OWNERSHIP_UPDATE registrations with a
    -- single canonical listener. Collectibles fans out on all four collection events
    -- (NEW_MOUNT_ADDED, NEW_PET_ADDED, VWB_TRANSMOG_UPDATED, VWB_DECOR_OWNERSHIP_UPDATE),
    -- so one registration covers the full collect domain with no duplicate sweeps.
    VWB.Collectibles:RegisterCollectionListener(sweepCollectCompletions)
    VWB.EventBus:Register("VWB_INVENTORY_UPDATE", sweepStockRefills)
    VWB.EventBus:Register("VWB_RECIPES_SCANNED", sweepStudyLearns)
    VWB.Reactor.subscribeEvent("ACHIEVEMENT_EARNED", function(achievementID)
        if achievementID then onAchievementEarned(achievementID) end
    end)
    -- CRITERIA_UPDATE fires per craft action with no payload: coalesce, then
    -- sweep only achievement commissions with unstamped pieces.
    VWB.Reactor.subscribeEvent("CRITERIA_UPDATE", function()
        if achSettle then return end
        achSettle = VWB.ReactorWoW.after(VWB.Constants.Achievements.CRITERIA_SETTLE, function()
            achSettle = nil
            sweepAchievementCriteria()
        end)
    end)
end
