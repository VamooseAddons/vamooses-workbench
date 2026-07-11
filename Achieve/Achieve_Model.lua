-- ============================================================================
-- VWB Achieve - reactive MODEL (headless-testable)
-- ============================================================================
-- Profession achievements over the ProfAchievements latch surface. Injectable
-- deps, same discipline as Study_Model:
--   source  = { peek(id), epoch(), ids = fn -> ordered id array,
--               categories = fn -> ordered { id, name } }
--   filters = { search, navKey (nil | "*" | categoryID string), hideEarned,
--               collapsed }                                (Reactor signals)
-- ============================================================================

local _, ns = ...
local R = ns.Reactor
local Achieve = ns.Achieve or {}
ns.Achieve = Achieve

function Achieve.buildModel(deps)
    local src, f = deps.source, deps.filters

    local function passes(rec)
        if f.hideEarned() and rec.completed then return false end
        local q = f.search()
        if q ~= "" and not ((rec.name or ""):lower():find(q, 1, true)
            or (rec.description or ""):lower():find(q, 1, true)) then return false end
        return true
    end

    -- Achievements passing search/hideEarned -- NOT the nav pick (sections
    -- keep counting siblings of the current selection, the Showroom rule).
    -- Walk order preserved: it is Blizzard's category order (tiers adjacent).
    local visible = R.named("achieve:visible", function()
        src.epoch()
        local out = {}
        for _, id in ipairs(src.ids()) do
            local rec = src.peek(id)
            if rec and passes(rec) then out[#out + 1] = rec end
        end
        return out
    end)

    local rows = R.named("achieve:rows", function()
        local sel = f.navKey()
        if sel == "*" then sel = nil end
        local out = {}
        for _, rec in ipairs(visible()) do
            if not sel or tostring(rec.categoryID) == sel then out[#out + 1] = rec end
        end
        return out
    end)

    -- ONE section ("Professions") whose items are the live categories, each
    -- counting its currently-visible achievements; "All" leads.
    local sections = R.named("achieve:sections", function()
        local collapsed = f.collapsed()
        local counts, totalShown = {}, 0
        for _, rec in ipairs(visible()) do
            counts[rec.categoryID] = (counts[rec.categoryID] or 0) + 1
            totalShown = totalShown + 1
        end
        local items = { { key = "*", label = "All", count = totalShown } }
        for _, cat in ipairs(src.categories()) do
            if counts[cat.id] then
                items[#items + 1] = { key = tostring(cat.id), label = cat.name, count = counts[cat.id] }
            end
        end
        return { { key = "professions", label = "Professions", itemCount = totalShown,
            collapsed = collapsed.professions or false, items = items } }
    end)

    -- Breadcrumb tallies over the FULL corpus (filter-independent earned/total).
    local tally = R.named("achieve:tally", function()
        src.epoch()
        local earned, total = 0, 0
        for _, id in ipairs(src.ids()) do
            local rec = src.peek(id)
            if rec then
                total = total + 1
                if rec.completed then earned = earned + 1 end
            end
        end
        return { earned = earned, total = total }
    end)

    return { rows = rows, sections = sections, tally = tally }
end

return Achieve
