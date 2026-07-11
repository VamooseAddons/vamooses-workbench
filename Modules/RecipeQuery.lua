-- ============================================================================
-- VamoosesWorkbench - RecipeQuery
-- Centralized recipe filtering & search API (engine decoupled from UI)
-- ============================================================================

VWB = VWB or {}
VWB.RecipeQuery = {}

local ED -- lazy ref to VWB.Data.ExpansionData

local function GetED()
    if not ED then ED = VWB.Data.ExpansionData end
    return ED
end

-- ============================================================================
-- INVENTORY CHECK
-- ============================================================================

function VWB.RecipeQuery:CanCraft(recipeID)
    local recipe = VWB.Database:GetRecipe(recipeID)
    if not recipe or not recipe.slots then return false end
    -- Net of queue commitments: reagents earmarked for queued crafts don't
    -- count toward a new recipe -- the honest "can I cover this on top"
    local queued = VWB.Store:GetState().crafting.queuedByItemID
    for _, slot in ipairs(recipe.slots) do
        if slot.type == "basic" then
            local owned = VWB.Inventory:GetItemCountWithVariants(slot.itemID) or 0
            local committed = queued[slot.itemID] or 0
            if (owned - committed) < slot.qty then return false end
        end
    end
    return true
end

-- ============================================================================
-- SKILL-UP ELIGIBILITY
-- ============================================================================

-- Current character's skill level in a profession/expansion, or nil if that
-- profession/expansion has never been scanned (CharacterData.lua's
-- skillLevels shape: state.account.characters[charKey].professions[prof]
-- .skillLevels[expansion] = { current, max }). Shared by the Skill-Up filter
-- below and Alts.lua's learn-next tooltip.
function VWB.RecipeQuery:GetCurrentCharSkill(profession, expansion)
    local charKey = VWB.CharacterData:GetCharacterKey()
    local charData = VWB.Store:GetState().account.characters[charKey]
    local profData = charData and charData.professions and charData.professions[profession]
    local skillData = profData and profData.skillLevels and profData.skillLevels[expansion]
    return skillData and skillData.current
end

-- ============================================================================
-- QUERY: PROFESSIONS
-- ============================================================================

function VWB.RecipeQuery:GetProfessions()
    local profs = {}
    local seen = {}
    local all = VWB.Database:GetAllRecipes()
    if not all then return profs end
    local profIcons = VWB.Constants.ProfessionIcons
    local gatheringProfs = { Herbalism = true, Mining = true, Skinning = true }
    local ed = GetED()
    for _, recipe in pairs(all) do
        local p = recipe.profession or "Unknown"
        if not seen[p] then
            seen[p] = true
            local profInfo = ed and ed.GetProfessionInfo(p)
            table.insert(profs, {
                key = p,
                label = p,
                abbrev = profInfo and profInfo.code or nil,
                icon = profIcons[p] or "Interface\\Icons\\INV_Misc_QuestionMark",
                isGathering = gatheringProfs[p] or false,
            })
        end
    end
    table.sort(profs, function(a, b)
        if a.isGathering ~= b.isGathering then return not a.isGathering end
        return a.key < b.key
    end)
    return profs
end

-- ============================================================================
-- QUERY: EXPANSIONS FOR PROFESSION
-- ============================================================================

function VWB.RecipeQuery:GetExpansions(profession)
    local exps = {}
    local seen = {}
    local all = VWB.Database:GetAllRecipes()
    local ed = GetED()
    for _, r in pairs(all) do
        if r.profession == profession then
            local e = r.expansion or "Unknown"
            if not seen[e] then
                seen[e] = true
                local info = ed and ed.GetExpansionInfo(e)
                table.insert(exps, {
                    key = e,
                    label = info and info.abbr or e,
                    order = info and info.order or 999,
                })
            end
        end
    end
    table.sort(exps, function(a, b) return a.order < b.order end)
    table.insert(exps, 1, { key = "AllExps", label = "All" })
    return exps
end

-- ============================================================================
-- QUERY: FILTERED RECIPE LIST
-- ============================================================================

-- Collapse recipe RANKS (old-world Rank 1/2/3 recipes -- same name, same output
-- item, different recipeID) to a single representative row. The representative
-- is the best rank the player can actually use: the highest-ID rank the CURRENT
-- character knows, else the highest any character knows, else the highest rank
-- (as a target). Keeps known/craftable chips truthful on the collapsed row.
local function CollapseRanks(results)
    local currentKey = VWB.CharacterData:GetCharacterKey()
    local groups = {}   -- key -> { entry, tier }
    local order = {}    -- preserve first-seen order of keys
    for _, entry in ipairs(results) do
        local r = entry.recipe
        local key = (r.name or "?") .. "::" .. tostring(r.itemID)
        local tier = 0
        if VWB.KnownRecipes:IsKnownBy(entry.recipeID, currentKey) then tier = 2
        elseif VWB.KnownRecipes:IsKnown(entry.recipeID) then tier = 1 end

        local cur = groups[key]
        if not cur then
            groups[key] = { entry = entry, tier = tier }
            order[#order + 1] = key
        elseif tier > cur.tier or (tier == cur.tier and entry.recipeID > cur.entry.recipeID) then
            cur.entry, cur.tier = entry, tier
        end
    end

    local collapsed = {}
    for _, key in ipairs(order) do collapsed[#collapsed + 1] = groups[key].entry end
    return collapsed
end

-- filters = { profession, expansion, search, categoryName, canCraftOnly,
--             skillUpOnly, collapseRanks }
-- Returns array of { recipeID, recipe }
-- Collection-kind scoping (transmog/pet/mount/decor + missing) is NOT a
-- GetFiltered concern: views post-filter via VWB.Collectibles:ClassifyKind /
-- IsUncollectedCollectible (the one canonical chain; refactor 2026-07-11
-- removed the four per-kind flags that duplicated it here).
function VWB.RecipeQuery:GetFiltered(filters)
    filters = filters or {}
    local all = VWB.Database:GetAllRecipes()
    local results = {}

    for recipeID, recipe in pairs(all) do
        local passes = true

        -- Profession filter
        if filters.profession and recipe.profession ~= filters.profession then
            passes = false
        end

        -- Expansion filter
        if passes and filters.expansion and filters.expansion ~= "AllExps" then
            if recipe.expansion ~= filters.expansion then passes = false end
        end

        -- Search filter
        if passes and filters.search and filters.search ~= "" then
            if not (recipe.name and recipe.name:lower():find(filters.search, 1, true)) then
                passes = false
            end
        end

        -- Skill-up only: recipes below THIS character's current skill in that
        -- profession/expansion. maxTrivialLevel is harvested and can be
        -- missing/0 on some records -- treated as "no skill-up info", excluded
        -- rather than assumed true. Missing skill data (never scanned that
        -- profession/expansion) excludes too -- "below" is unknowable without
        -- a number to compare against.
        if passes and filters.skillUpOnly then
            local cap = recipe.maxTrivialLevel
            if not cap or cap == 0 then
                passes = false
            else
                local current = self:GetCurrentCharSkill(recipe.profession, recipe.expansion)
                if not current or current >= cap then passes = false end
            end
        end

        -- Direct category name filter (from nav tree)
        if passes and filters.categoryName and recipe.categoryName ~= filters.categoryName then
            passes = false
        end

        -- Can craft only: runs LAST -- calls GetItemCountWithVariants per slot,
        -- so cheaper filters above must cut the candidate set first (E5).
        if passes and filters.canCraftOnly then
            if not self:CanCraft(recipeID) then passes = false end
        end

        if passes then
            table.insert(results, { recipeID = recipeID, recipe = recipe })
        end
    end

    if filters.collapseRanks then
        results = CollapseRanks(results)
    end

    return results
end
