VWB = VWB or {}
VWB.RecipeSources = {}

-- ============================================================================
-- Recipe acquisition sources -- the Study view's data spine.
-- ============================================================================
-- C_TradeSkillUI.GetRecipeSourceText(recipeID) is the prof book's "Recipe
-- Unlearned" hover text ("Drop: Heavy Trunk\nZone: Delves") -- undocumented,
-- verified live 2026-07-11 to answer COLD (no tradeskill session) with
-- Blizzard label colors embedded per line. This module walks the unlearned
-- corpus (budget-ticked), parses each string, and latches the results into a
-- latchMap. Constitution posture:
--   R2  the walk only reads-and-latches; no path here issues any request
--   R3  every key latches at most once (pendingIDs skips hasKey), and each
--       tick batches its latches -- one epoch movement per frame, not per key
--   R6  DORMANT until the Study view first mounts (EnsureWalk); the corpus
--       re-sweep effect arms only after that first wake
-- The walk also feeds VWB_DB.recipeSourceIndex -- a dedup { [sourceName] =
-- { kind, zone } } SavedVars export for the OFFLINE coords pipeline
-- (TrinityCore TDB name->coords seed; docs/VWB_STUDY_COORDS_RESEARCH_
-- 2026-07-11.md). Direct SavedVar write, badgeSnapshots precedent: an export
-- artifact, not app state.
-- ============================================================================

local sources = VWB.Reactor.latchMap("recipeSources")
local armed = false    -- Study opened this session; corpus re-sweep live
local walking = false
local stats = { walked = 0, none = 0 }

-- Walked-but-no-data marker (server has no acquisition text for the recipe).
-- Shared ref so a re-latch is an equality no-op. The label doubles as the
-- nav group name -- Study_Model pins it last in the section sort.
local UNSPECIFIED = { kindLabel = "Unspecified", lines = {} }

local function stripCodes(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]+:", ""):gsub("|r", ""))
end

-- Parse one sourceText into { kindLabel, detail, zone, lines }. kindLabel/
-- detail come from the FIRST "Label: value" line ("Vendor: Provisioner
-- Mukra"); zone from the first "Zone:" line. Labels are LOCALIZED -- they
-- still group correctly per-locale, but the "Zone" match (and the export's
-- zone field) only lands on English clients. lines keeps the raw colored
-- strings for tooltip display.
function VWB.RecipeSources.Parse(text)
    local rec = { lines = {} }
    for line in text:gmatch("[^\n]+") do
        rec.lines[#rec.lines + 1] = line
        local plain = stripCodes(line)
        local label, value = plain:match("^%s*(.-):%s*(.+)$")
        if label and value then
            if not rec.kindLabel then
                rec.kindLabel, rec.detail = label, value
            elseif label == "Zone" and not rec.zone then
                rec.zone = value
            end
        elseif not rec.kindLabel and plain ~= "" then
            rec.kindLabel, rec.detail = "Other", plain -- unlabeled first line ("Discovered via...")
        end
    end
    rec.kindLabel = rec.kindLabel or "Unspecified"
    return rec
end

-- The walk's work list: not yet latched, not yet learned. Learned recipes are
-- the VIEW's filter concern; skipping them here just scopes the walk (and the
-- export) to what Study can ever show.
local function pendingIDs()
    local ids = {}
    for recipeID in pairs(VWB.Database:GetAllRecipes()) do
        if not VWB.KnownRecipes:IsKnown(recipeID) and not sources:hasKey(recipeID) then
            ids[#ids + 1] = recipeID
        end
    end
    return ids
end

-- Offline-pipeline export row: first sighting of a source name wins (the
-- name->zone pair is what the coords resolver keys on; duplicates carry no
-- new information).
local function exportEntry(rec)
    if not rec.detail then return end
    local index = VWB_DB.recipeSourceIndex
    if index[rec.detail] == nil then
        index[rec.detail] = { kind = rec.kindLabel, zone = rec.zone }
    end
end

local function walk()
    if walking then return end
    local ids = pendingIDs()
    if #ids == 0 then return end
    walking = true
    VWB_DB.recipeSourceIndex = VWB_DB.recipeSourceIndex or {}
    local total, idx = #ids, 1
    local HC = VWB.Constants.Harvest

    local function tick()
        local tickStart = debugprofilestop()
        local batch = {}
        while idx <= total do
            local recipeID = ids[idx]
            idx = idx + 1
            local text = C_TradeSkillUI.GetRecipeSourceText(recipeID) -- exception(boundary): nil when the server has no acquisition data
            local rec = UNSPECIFIED
            if text then
                rec = VWB.RecipeSources.Parse(text)
                exportEntry(rec)
            else
                stats.none = stats.none + 1
            end
            batch[#batch + 1] = { recipeID, rec }
            if #batch % HC.BUDGET_CHECK_INTERVAL == 0
                and (debugprofilestop() - tickStart) >= HC.TICK_BUDGET_MS then break end
        end
        -- One flush per tick, not one per recipe (R3): the batch moves the
        -- aggregate epoch once per frame however many keys latched.
        VWB.Reactor.batch(function()
            for _, e in ipairs(batch) do sources:latch(e[1], e[2]) end
        end)
        stats.walked = stats.walked + #batch
        if idx <= total then
            VWB.ReactorWoW.after(0, tick)
        else
            walking = false
        end
    end
    VWB.ReactorWoW.after(0, tick) -- first tick deferred too: no latch burst inside the caller's frame
end

-- First Study mount (R6: the consumer surface waking IS the trigger). Arms a
-- corpus-version effect so later harvests sweep their NEW ids through the same
-- walk -- pendingIDs is empty when nothing grew, so a known-status-only bump
-- is a no-op. Latch-forward from a real data change; no requests, no loop.
function VWB.RecipeSources:EnsureWalk()
    if armed then walk() return end
    armed = true
    VWB.Reactor.effect(function()
        VWB.Store:Version("corpus")
        walk()
    end, "recipeSources:corpusSweep")
end

function VWB.RecipeSources.epoch() return sources.epoch() end
function VWB.RecipeSources.peek(recipeID) return sources:peek(recipeID) end
function VWB.RecipeSources.IsWalking() return walking end
function VWB.RecipeSources.Stats() return stats end
