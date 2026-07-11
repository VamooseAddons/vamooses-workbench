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
-- Shared ref so a re-latch is an equality no-op. Study_Model maps the empty
-- sources array to its "Unspecified" pseudo-source, pinned last in the nav.
local UNSPECIFIED = { lines = {}, sources = {} }

local function stripCodes(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]+:", ""):gsub("|r", ""))
end

-- Split one source line's remainder into detail / zone / cost. Vendor lines
-- pack the sub-fields INLINE -- "Vendor: Aaron Hollman Zone: Shattrath City
-- Cost: 4<goldicon>" is ONE line that only LOOKS multi-line in a wrapping
-- tooltip (live discovery 2026-07-11: the v1 line-based parser filed 2185 of
-- 2193 vendor recipes under "(no zone)"). "Zone"/"Cost" are LOCALIZED
-- literals: on non-English clients the whole remainder stays in detail --
-- grouping by kind still works per-locale, zone buckets degrade. Cost keeps
-- its |T..|t money textures; a FontString renders them (colons inside |T..|t
-- can't false-match, the labels anchor the patterns).
local function splitFields(remainder)
    local detail, zone, cost = remainder, nil, nil
    local pre, z = detail:match("^(.-)%s*Zone:%s*(.+)$")
    if pre then detail, zone = pre, z end
    local host = zone or detail
    local p2, c = host:match("^(.-)%s*Cost:%s*(.+)$")
    if p2 then
        if zone then zone = p2 else detail = p2 end
        cost = c
    end
    if detail == "" then detail = nil end
    return detail, zone, cost
end

-- Parse one sourceText into { lines, sources }. ONE SOURCE PER LINE ("Label:
-- value ..."), sub-fields split inline; a bare "Zone:"/"Cost:" line (the
-- drop shape: "Drop: Heavy Trunk\nZone: Delves") attaches to the source
-- above it. lines keeps the raw colored strings for tooltip display.
function VWB.RecipeSources.Parse(text)
    local rec = { lines = {}, sources = {} }
    for line in text:gmatch("[^\n]+") do
        rec.lines[#rec.lines + 1] = line
        local plain = stripCodes(line)
        local label, remainder = plain:match("^%s*(.-):%s*(.+)$")
        local prev = rec.sources[#rec.sources]
        if label == "Zone" and prev and not prev.zone then
            local z, c = remainder:match("^(.-)%s*Cost:%s*(.+)$")
            prev.zone = z or remainder
            if c and not prev.cost then prev.cost = c end
        elseif label == "Cost" and prev and not prev.cost then
            prev.cost = remainder
        elseif label and remainder then
            local detail, zone, cost = splitFields(remainder)
            rec.sources[#rec.sources + 1] = { kind = label, detail = detail, zone = zone, cost = cost }
        elseif plain ~= "" then
            rec.sources[#rec.sources + 1] = { kind = "Other", detail = plain } -- unlabeled line ("Discovered via...")
        end
    end
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

-- Offline-pipeline export rows: first sighting of a source name wins (the
-- name->zone pair is what the coords resolver keys on; duplicates carry no
-- new information). Cost is display-only, not exported.
local function exportEntry(rec)
    local index = VWB_DB.recipeSourceIndex
    for _, s in ipairs(rec.sources) do
        if s.detail and index[s.detail] == nil then
            index[s.detail] = { kind = s.kind, zone = s.zone }
        end
    end
end

local function walk()
    if walking then return end
    local ids = pendingIDs()
    if #ids == 0 then return end
    walking = true
    -- v2: the v1 parser baked "Name Zone: X Cost: Y" blobs into the export
    -- keys; a version bump rebuilds the index clean on the next full walk
    -- (the latchMap is session-local, so every session IS a full walk).
    if VWB_DB.recipeSourceIndexV ~= 2 then
        VWB_DB.recipeSourceIndex, VWB_DB.recipeSourceIndexV = {}, 2
    end
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
