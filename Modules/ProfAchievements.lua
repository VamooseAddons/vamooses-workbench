VWB = VWB or {}
VWB.ProfAchievements = {}

-- ============================================================================
-- Profession achievements -- the Achieve view's data spine. RUNTIME-ONLY
-- (owner ruling 2026-07-12: no shipped data, no curated achievement ids).
-- ============================================================================
-- The Professions category tree is walked LIVE: GetCategoryList() filtered to
-- parent == Constants.Achievements.PROFESSIONS_CATEGORY (the one stable id we
-- carry), then GetAchievementInfo(catID, index) + criteria per achievement.
-- All C-side globals, answer cold, no Blizzard_AchievementUI load needed.
-- Constitution posture:
--   R2  boundary handlers only re-read-and-latch; nothing here requests
--   R3  latches are change-compared (progressText/completed) before writing,
--       and each walk tick batches -- one epoch move per frame
--   R6  DORMANT until the Achieve view first mounts (EnsureWalk);
--       ACHIEVEMENT_EARNED / CRITERIA_UPDATE handlers arm at that wake
-- ============================================================================

local store = VWB.Reactor.latchMap("profAchievements")
local armed = false
local walking = false
local walked = false
local categories = {}   -- ordered { id, name, total } (live category walk)
local orderedIDs = {}   -- achievement ids in category-walk order
local critSettle = nil  -- CRITERIA_UPDATE coalescer

-- One achievement, read fresh from the live API. progressText is the row's
-- right-cell summary: earned date when done, else the first progress-bar
-- criterion's quantity, else "done/total" criteria.
local function readAchievement(achievementID, categoryID)
    local id, name, points, completed, month, day, year, description, _, icon, rewardText =
        GetAchievementInfo(achievementID)
    if not id then return nil end -- exception(boundary): category index walk can outrun the client's achievement data
    local AC = VWB.Constants.Achievements
    local crit, done, total, barText = {}, 0, 0, nil
    for i = 1, GetAchievementNumCriteria(achievementID) do
        local text, ctype, cDone, quantity, req, _, cflags, assetID = GetAchievementCriteriaInfo(achievementID, i)
        total = total + 1
        if cDone then done = done + 1 end
        local bar = bit.band(cflags or 0, AC.PROGRESS_BAR_FLAG) ~= 0 -- exception(boundary): criteriaFlags nil on some legacy rows
        if bar and not barText then barText = (quantity or 0) .. "/" .. (req or 0) end
        crit[i] = { text = text, ctype = ctype, done = cDone, quantity = quantity,
            req = req, assetID = assetID, bar = bar }
    end
    local progressText
    if completed then
        progressText = string.format("%02d/%02d/%02d", day, month, year)
    else
        progressText = barText or (total > 0 and (done .. "/" .. total)) or ""
    end
    return { id = id, name = name, points = points, completed = completed,
        description = description, icon = icon, rewardText = rewardText,
        categoryID = categoryID, criteria = crit, critDone = done, critTotal = total,
        progressText = progressText }
end

-- Re-read one achievement and latch ONLY if its display-relevant state moved
-- (R3: boundary events fire far more often than anything changes).
local function refreshOne(achievementID)
    local old = store:peek(achievementID)
    if not old then return end
    local fresh = readAchievement(achievementID, old.categoryID)
    if fresh and (fresh.completed ~= old.completed or fresh.progressText ~= old.progressText
        or fresh.critDone ~= old.critDone) then
        store:latch(achievementID, fresh)
    end
end

local function walkCategories()
    categories = {}
    local root = VWB.Constants.Achievements.PROFESSIONS_CATEGORY
    for _, catID in ipairs(GetCategoryList()) do
        local name, parent = GetCategoryInfo(catID)
        if parent == root then
            categories[#categories + 1] = { id = catID, name = name,
                total = (GetCategoryNumAchievements(catID)) }
        end
    end
    table.sort(categories, function(a, b) return a.name < b.name end)
    -- The root category can hold DIRECT achievements too (cross-profession
    -- metas live on the parent, not a subcat) -- walk it like a child, first
    -- in the nav. The nav auto-hides it if Blizzard keeps it empty.
    local rootName = GetCategoryInfo(root)
    table.insert(categories, 1, { id = root, name = rootName,
        total = (GetCategoryNumAchievements(root)) })
end

local function walk()
    if walking then return end
    walking = true
    walkCategories()
    -- Work list: (categoryID, index) pairs across all profession categories.
    local work = {}
    for _, cat in ipairs(categories) do
        for i = 1, cat.total do work[#work + 1] = { cat.id, i } end
    end
    orderedIDs = {}
    local total, idx = #work, 1
    local HC = VWB.Constants.Harvest

    local function tick()
        local tickStart = debugprofilestop()
        local batch = {}
        while idx <= total do
            local catID, i = work[idx][1], work[idx][2]
            idx = idx + 1
            local id = GetAchievementInfo(catID, i) -- exception(boundary): index enumeration; nil rows skipped
            if id then
                local rec = readAchievement(id, catID)
                if rec then
                    batch[#batch + 1] = rec
                    orderedIDs[#orderedIDs + 1] = id
                end
            end
            if #batch % HC.BUDGET_CHECK_INTERVAL == 0
                and (debugprofilestop() - tickStart) >= HC.TICK_BUDGET_MS then break end
        end
        VWB.Reactor.batch(function()
            for _, rec in ipairs(batch) do store:latch(rec.id, rec) end
        end)
        if idx <= total then
            VWB.ReactorWoW.after(0, tick)
        else
            walking = false
            walked = true
        end
    end
    VWB.ReactorWoW.after(0, tick)
end

-- CRITERIA_UPDATE fires per craft action with no payload: coalesce, then
-- sweep quantities on INCOMPLETE achievements only (change-compared latches).
local function armEvents()
    VWB.Reactor.subscribeEvent("ACHIEVEMENT_EARNED", function(achievementID)
        if achievementID then refreshOne(achievementID) end
    end)
    VWB.Reactor.subscribeEvent("CRITERIA_UPDATE", function()
        if not walked or critSettle then return end
        critSettle = VWB.ReactorWoW.after(VWB.Constants.Achievements.CRITERIA_SETTLE, function()
            critSettle = nil
            for _, id in ipairs(orderedIDs) do
                local rec = store:peek(id)
                if rec and not rec.completed then refreshOne(id) end
            end
        end)
    end)
end

-- First Achieve mount (R6: the consumer surface waking IS the trigger).
function VWB.ProfAchievements:EnsureWalk()
    if armed then walk() return end
    armed = true
    armEvents()
    walk()
end

function VWB.ProfAchievements.epoch() return store.epoch() end
function VWB.ProfAchievements.peek(id) return store:peek(id) end
function VWB.ProfAchievements.IDs() return orderedIDs end
function VWB.ProfAchievements.Categories() return categories end
function VWB.ProfAchievements.IsWalking() return walking end
