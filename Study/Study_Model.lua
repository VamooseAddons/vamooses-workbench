-- ============================================================================
-- VWB Study - reactive MODEL (headless-testable)
-- ============================================================================
-- The acquisition browser's brain. The row unit is the SOURCE, not the
-- recipe (owner layout ruling 2026-07-11): a recipe sold by two vendors is
-- two rows, ledger-style -- the name paints on the first row of a run and
-- blanks on continuations. Injectable deps, same discipline as Showroom_Model:
--   universe = () -> array of { recipeID, itemID?, name, profession, expansion }
--   source   = { peek(recipeID) -> { lines, sources }|nil, epoch() }  (RecipeSources)
--   known    = { version = fn (subscribing read), isKnown = fn(recipeID) plain }
--   filters  = { search, profession, navKey, collapsed }              (Reactor signals)
-- navKey grammar: nil = everything | "Kind::*" = one kind, all zones |
-- "Kind::Zone" = one kind in one zone. (Item keys always carry "::" so they
-- can never collide with the section header keys the NavTree also tracks.)
-- ============================================================================

local _, ns = ...
local R = ns.Reactor
local Study = ns.Study or {}
ns.Study = Study

Study.NO_ZONE = "(no zone)" -- bucket label for sources without a Zone field

-- Pseudo-source for walked recipes the server has no acquisition text for
-- (RecipeSources latches an empty sources array). Pinned last in the nav.
local UNSPEC_SOURCE = { kind = "Unspecified" }

function Study.buildModel(deps)
    local u, src, known, f = deps.universe, deps.source, deps.known, deps.filters

    local function passes(item)
        if f.profession() ~= "all" and item.profession ~= f.profession() then return false end
        local q = f.search()
        if q ~= "" and not (item.name or ""):lower():find(q, 1, true) then return false end
        return true
    end

    -- SOURCE-level entries: the unlearned universe under search/profession
    -- (NOT the nav pick -- sections must keep counting siblings of the
    -- current selection, the Showroom rule), flattened one entry per parsed
    -- source PER ZONE -- a vendor standing in two zones is two acquisition
    -- opportunities (e.zone carries the entry's zone; source tables are
    -- shared and never mutated). A recipe appears when its latch lands
    -- (src.epoch dep); learning one drops its entries on the next known-
    -- version bump. recipeCount rides the array for the breadcrumb's
    -- "N recipes | M sources" split.
    local entries = R.named("study:entries", function()
        known.version(); src.epoch()
        local out, recipes = {}, 0
        for _, item in ipairs(u()) do
            if not known.isKnown(item.recipeID) and passes(item) then
                local rec = src.peek(item.recipeID)
                if rec then
                    recipes = recipes + 1
                    if #rec.sources == 0 then
                        out[#out + 1] = { item = item, source = UNSPEC_SOURCE, lines = rec.lines }
                    else
                        for _, s in ipairs(rec.sources) do
                            if s.zones and #s.zones > 0 then
                                for _, z in ipairs(s.zones) do
                                    out[#out + 1] = { item = item, source = s, zone = z, lines = rec.lines }
                                end
                            else
                                out[#out + 1] = { item = item, source = s, lines = rec.lines }
                            end
                        end
                    end
                end
            end
        end
        out.recipeCount = recipes
        return out
    end)

    -- The list: entries narrowed to the nav pick, sorted name-then-detail,
    -- ledger continuation flags computed over the FINAL adjacency (a zone
    -- filter that isolates one source of a pair must carry the name again).
    -- Rows are fresh wrappers: entries are shared across recomputes and must
    -- never be mutated from inside a computed.
    local rows = R.named("study:rows", function()
        local kind, zone
        local sel = f.navKey()
        if sel then
            kind, zone = sel:match("^(.+)::(.+)$")
            if not kind then kind = sel end
            if zone == "*" then zone = nil end
        end
        local out = {}
        for _, e in ipairs(entries()) do
            local s = e.source
            if not kind or (s.kind == kind and (not zone or (e.zone or Study.NO_ZONE) == zone)) then
                out[#out + 1] = { item = e.item, source = s, zone = e.zone, lines = e.lines }
            end
        end
        table.sort(out, function(a, b)
            local an, bn = a.item.name or "", b.item.name or ""
            if an ~= bn then return an < bn end
            local ad, bd = a.source.detail or "", b.source.detail or ""
            if ad ~= bd then return ad < bd end
            return (a.zone or "") < (b.zone or "")
        end)
        local prevID
        for _, row in ipairs(out) do
            row.continuation = row.item.recipeID == prevID
            prevID = row.item.recipeID
        end
        return out
    end)

    -- Nav sections: acquisition kind -> zones with SOURCE counts, busiest
    -- kind first, "Unspecified" pinned last. Each section leads with an
    -- "All" item (key "Kind::*") so a whole kind is selectable.
    local sections = R.named("study:sections", function()
        local collapsed = f.collapsed()
        local byKind = {}
        for _, e in ipairs(entries()) do
            local k = e.source.kind
            local rec = byKind[k]
            if not rec then rec = { total = 0, zones = {} }; byKind[k] = rec end
            rec.total = rec.total + 1
            local z = e.zone or Study.NO_ZONE
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

    return { entries = entries, rows = rows, sections = sections }
end

return Study
