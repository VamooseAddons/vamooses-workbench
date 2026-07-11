-- ============================================================================
-- VWB Study - reactive MODEL (headless-testable)
-- ============================================================================
-- The acquisition browser's brain: the unlearned universe joined to parsed
-- recipe sources, grouped by acquisition kind -> zone for the nav, narrowed
-- by the nav pick for the list. Injectable deps, same discipline as
-- Showroom_Model:
--   universe = () -> array of { recipeID, itemID?, name, profession, expansion }
--   source   = { peek(recipeID) -> parsed|nil, epoch() }     (RecipeSources shape)
--   known    = { version = fn (subscribing read), isKnown = fn(recipeID) plain }
--   filters  = { search, profession, navKey, collapsed }     (Reactor signals)
-- navKey grammar: nil = everything | "Kind::*" = one kind, all zones |
-- "Kind::Zone" = one kind in one zone. (Item keys always carry "::" so they
-- can never collide with the section header keys the NavTree also tracks.)
-- ============================================================================

local _, ns = ...
local R = ns.Reactor
local Study = ns.Study or {}
ns.Study = Study

Study.NO_ZONE = "(no zone)" -- bucket label for sources without a Zone line

function Study.buildModel(deps)
    local u, src, known, f = deps.universe, deps.source, deps.known, deps.filters

    local function passes(item)
        if f.profession() ~= "all" and item.profession ~= f.profession() then return false end
        local q = f.search()
        if q ~= "" and not (item.name or ""):lower():find(q, 1, true) then return false end
        return true
    end

    -- Unlearned+parsed universe under search/profession -- NOT the nav pick
    -- (sections must keep counting siblings of the current selection; the
    -- Showroom rule). A recipe appears when its source latch lands (src.epoch
    -- dep); learning one drops it on the next known-version bump. isKnown is
    -- a plain cache read on purpose -- known.version() is its reactive edge.
    local unlearned = R.named("study:unlearned", function()
        known.version(); src.epoch()
        local out = {}
        for _, item in ipairs(u()) do
            if not known.isKnown(item.recipeID) and passes(item) then
                local rec = src.peek(item.recipeID)
                if rec then out[#out + 1] = { item = item, source = rec } end
            end
        end
        return out
    end)

    -- The list: unlearned narrowed to the nav pick, name-sorted (fresh table;
    -- never sort the shared computed value in place).
    local rows = R.named("study:rows", function()
        local kind, zone
        local sel = f.navKey()
        if sel then
            kind, zone = sel:match("^(.+)::(.+)$")
            if zone == "*" then zone = nil end
        end
        local out = {}
        for _, e in ipairs(unlearned()) do
            if not kind or (e.source.kindLabel == kind
                and (not zone or (e.source.zone or Study.NO_ZONE) == zone)) then
                out[#out + 1] = e
            end
        end
        table.sort(out, function(a, b) return (a.item.name or "") < (b.item.name or "") end)
        return out
    end)

    -- Nav sections: acquisition kind -> zones with counts, busiest kind first,
    -- "Unspecified" (RecipeSources' no-data label) pinned last. Each section
    -- leads with an "All" item (key "Kind::*") so a whole kind is selectable.
    local sections = R.named("study:sections", function()
        local collapsed = f.collapsed()
        local byKind = {}
        for _, e in ipairs(unlearned()) do
            local k = e.source.kindLabel
            local rec = byKind[k]
            if not rec then rec = { total = 0, zones = {} }; byKind[k] = rec end
            rec.total = rec.total + 1
            local z = e.source.zone or Study.NO_ZONE
            rec.zones[z] = (rec.zones[z] or 0) + 1
        end
        local out = {}
        for k, rec in pairs(byKind) do
            local zoneNames = {}
            for z in pairs(rec.zones) do zoneNames[#zoneNames + 1] = z end
            table.sort(zoneNames)
            local items = { { key = k .. "::*", label = "All", count = rec.total } }
            for _, z in ipairs(zoneNames) do
                items[#items + 1] = { key = k .. "::" .. z, label = z, count = rec.zones[z] }
            end
            out[#out + 1] = { key = k, label = k, itemCount = rec.total,
                collapsed = collapsed[k] or false, items = items }
        end
        table.sort(out, function(a, b)
            local au, bu = a.key == "Unspecified", b.key == "Unspecified"
            if au ~= bu then return bu end
            if a.itemCount ~= b.itemCount then return a.itemCount > b.itemCount end
            return a.key < b.key
        end)
        return out
    end)

    return { unlearned = unlearned, rows = rows, sections = sections }
end

return Study
