-- ============================================================================
-- VWB Showroom - reactive MODEL (the controller's brain)
-- ============================================================================
-- The collectible classification, collection state, filtering, and counts as
-- a Reactor graph over injectable RESOURCES. This is the exact surface that
-- was buggy in the imperative VPC Showroom (cold-cache pets/mounts/transmog
-- not showing, manual RequestLoad + GET_ITEM_INFO_RECEIVED + refresh wiring).
-- Here there is NONE of that: a resource resolving auto-recomputes the list.
--
-- Injectable so it's headless-testable with mock resources; the WoW build wires
-- the same shape to real APIs. Deps:
--   recipes  = () -> array of { itemID, name, profession, expansion }
--   kind     = resource(itemID) -> "decor"|"transmog"|"mount"|"pet"|"none"|PENDING
--   collected= resource(itemID) -> true|false|PENDING   (meaningful when kind~="none")
--   filters  = { typeMode, missingMode, search, profession }  (all Reactor signals)
-- ============================================================================

local _, ns = ...
local R = ns.Reactor
local Showroom = ns.Showroom or {}
ns.Showroom = Showroom

function Showroom.buildModel(deps)
    local recipes = deps.recipes
    local kind, collected = deps.kind, deps.collected
    local f = deps.filters

    -- Does an item pass the active filters? true / false / nil (still resolving:
    -- kind or collected pending -- the item simply isn't shown yet, and the
    -- computed re-runs automatically when the resource lands).
    local function passes(item)
        if f.profession() ~= "all" and item.profession ~= f.profession() then return false end
        local q = f.search()
        if q ~= "" and not (item.name or ""):lower():find(q, 1, true) then return false end
        local k = kind.peek(item.itemID) -- untracked; filteredItems depends on kind.epoch() instead
        if k == R.PENDING then return nil end
        if k == "none" then return false end
        if f.typeMode() ~= "all" and k ~= f.typeMode() then return false end
        if f.missingMode() then
            local c = collected.peek(item.itemID)
            if c == R.PENDING then return nil end
            if c ~= false then return false end -- keep only not-collected
        end
        return true
    end

    -- The filtered item list. Reads kind/collected per item, so it re-derives
    -- itself the instant any of those resources resolve -- no manual refresh.
    local filteredItems = R.named("showroom:filteredItems", function()
        -- O(1) dependencies, not one per item: re-run when ANY classification
        -- resolves (kind.epoch), and -- only while the Missing filter is on --
        -- when collection changes. passes() reads the per-item values via peek().
        kind.epoch()
        if f.missingMode() then collected.epoch() end
        local out = {}
        for _, item in ipairs(recipes()) do
            if passes(item) == true then out[#out + 1] = item end
        end
        return out
    end)

    -- "Expansion \ Category \ N items, N known, N uncollected" counts.
    local breadcrumb = R.named("showroom:breadcrumb", function()
        collected.epoch() -- one dep for the whole tally (peek reads below are untracked)
        local total, known, unc = 0, 0, 0
        for _, item in ipairs(filteredItems()) do
            total = total + 1
            local c = collected.peek(item.itemID)
            if c == true then known = known + 1
            elseif c == false then unc = unc + 1 end
        end
        return { total = total, known = known, uncollected = unc }
    end)

    return {
        filteredItems = filteredItems,
        breadcrumb    = breadcrumb,
        kindOf        = kind,       -- resource passthrough for per-row binds
        collectedOf   = collected,
    }
end

return Showroom
