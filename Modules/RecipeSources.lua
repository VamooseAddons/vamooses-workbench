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

-- ============================================================================
-- Parse v3: label tokenizer. Live discoveries that killed v1/v2 (screenshots
-- 2026-07-11): sub-fields pack INLINE on one line ("Vendor: Name Zone: City
-- Cost: 4<gold>"), MULTIPLE sources can share ONE line ("... Cost: 4 Vendor:
-- Arras Zone: ..."), one vendor can carry TWO Zone fields, and Faction is a
-- fourth field. So: scan each line for known "Label:" markers (word-frontier
-- anchored, longest-first so "Profession Trainer" masks "Profession"),
-- values run marker-to-marker; SOURCE labels open a new source, FIELD labels
-- attach to the current one. Labels are LOCALIZED English literals -- on
-- other locales lines fall through to one "Other" source per line (kind
-- grouping degrades, tooltip stays complete). Unknown line-START labels
-- still open a source generically; unknown MID-line labels stay inside the
-- current value (truncated in the row, complete in the tooltip).
-- ============================================================================

local SOURCE_LABELS = { "Profession Trainer", "World Quest", "Vendor", "Trainer",
    "Profession", "Drop", "Discovery", "Quest", "Specialization", "Recipe" }
local FIELD_LABELS = { Zone = "zone", Cost = "cost", Faction = "faction", Requires = "requires" }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- All "Label:" hits in a stripped line, position-sorted, overlaps masked
-- (a "Trainer:" hit inside "Profession Trainer:" is dropped).
local function findMarkers(plain)
    local hits = {}
    local function scan(label)
        local init = 1
        while true do
            local s, e = plain:find(label .. "%s*:", init, false)
            if not s then break end
            local before = s > 1 and plain:sub(s - 1, s - 1) or ""
            if before == "" or not before:match("%a") then -- word frontier: "Icon:" inside |T..|t paths can't hit a label this way either
                hits[#hits + 1] = { s = s, e = e, label = label }
            end
            init = e + 1
        end
    end
    for _, l in ipairs(SOURCE_LABELS) do scan(l) end
    for f in pairs(FIELD_LABELS) do scan(f) end
    table.sort(hits, function(a, b)
        if a.s ~= b.s then return a.s < b.s end
        return a.e > b.e
    end)
    local out, lastEnd = {}, 0
    for _, h in ipairs(hits) do
        if h.s > lastEnd then out[#out + 1] = h; lastEnd = h.e end
    end
    return out
end

-- Parse one sourceText into { lines, sources }. Each source:
-- { kind, detail?, zone?, zones?, cost?, faction?, requires? } -- zones is
-- the FULL list (a vendor can stand in two zones; Study flattens one row per
-- zone), zone is its first entry (export + fallback convenience). lines
-- keeps the raw colored strings for tooltip display.
function VWB.RecipeSources.Parse(text)
    -- THE separator is "|n" -- WoW's escape, which FontStrings RENDER as a
    -- newline but which a \n split never sees (live 2026-07-11: 2184 of 2193
    -- vendors parsed zoneless because "...Mynx|nZone:" reads as the word
    -- "nZone"). Normalize it; blank runs (|n|n between vendor blocks) become
    -- a " " spacer line so the tooltip keeps its visual grouping.
    text = text:gsub("|n", "\n")
    local rec = { lines = {}, sources = {} }
    local current
    local function startSource(kind, detail)
        current = { kind = kind, detail = detail ~= "" and detail or nil }
        rec.sources[#rec.sources + 1] = current
    end
    local function attach(label, value)
        if value == "" then return end
        if not current then startSource(label, value) return end -- field label with no source above (rare)
        local field = FIELD_LABELS[label]
        if field == "zone" then
            current.zones = current.zones or {}
            current.zones[#current.zones + 1] = value
            current.zone = current.zone or value
        elseif current[field] == nil then
            current[field] = value
        end
    end

    local function parseLine(line)
        rec.lines[#rec.lines + 1] = line
        local plain = stripCodes(line)
        local hits = findMarkers(plain)
        -- Head of line before the first known marker: a generic "Label: value"
        -- opens a source (future kinds we haven't seen); bare text is "Other".
        local firstStart = hits[1] and hits[1].s or (#plain + 1)
        local head = trim(plain:sub(1, firstStart - 1))
        if head ~= "" then
            local hl, hv = head:match("^([%u][%a' ]-)%s*:%s*(.*)$")
            if hl then startSource(hl, trim(hv)) else startSource("Other", head) end
        end
        for i, h in ipairs(hits) do
            local valueEnd = hits[i + 1] and hits[i + 1].s - 1 or #plain
            local value = trim(plain:sub(h.e + 1, valueEnd))
            if FIELD_LABELS[h.label] then
                attach(h.label, value)
            else
                startSource(h.label, value)
            end
        end
    end

    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            parseLine(line)
        elseif rec.lines[#rec.lines] and rec.lines[#rec.lines] ~= " " then
            rec.lines[#rec.lines + 1] = " " -- block spacer for the tooltip
        end
    end
    if rec.lines[#rec.lines] == " " then rec.lines[#rec.lines] = nil end -- no trailing spacer
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
