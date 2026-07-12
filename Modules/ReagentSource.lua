VWB = VWB or {}
VWB.ReagentSource = {}

-- ============================================================================
-- VamoosesWorkbench - ReagentSource
-- Replaces the static VPC_ReagentsDB (deleted in the dynamic-DB pivot). Every
-- reagent's classification is DERIVED from state.recipeStore itself: two
-- reverse indexes (outputs/inputs) built over the live harvested recipe set.
--
-- Classification:
--   farmbuy    - appears as an input but is NEVER produced by any recipe on
--                file (vendor/gather/AH item; no vendor sub-classification)
--   crafted    - appears as BOTH an input and an output (a craftable
--                intermediate used by other recipes)
--   endproduct - appears ONLY as an output (a final craft, nobody's reagent)
--
-- Indexes are lazy and invalidated by VWB.Database:InvalidateIndexes() (called
-- from the ADD_RECIPES reducer) -- every harvest batch potentially changes
-- classification (a farmbuy item can turn into a crafted item the moment its
-- own recipe gets harvested).
-- ============================================================================

local outputs = nil -- [itemID] = { recipeID, ... } -- recipes that PRODUCE this item
local inputs = nil  -- [itemID] = { recipeID, ... } -- recipes that CONSUME this item (basic slots)
local bindCache = {} -- [itemID] = bindType, latched once the item is cached. Bind
-- data is immutable, so this never invalidates -- and it MUST latch: re-reading
-- GetItemInfo live on every paint made BoP tags flicker as the item cache churned
-- under mass resolution, and each read of an uncached item is a server request.

-- classID 7 (Enum.ItemClass.Tradegoods) subClassID -> {tier, label}. The subclass
-- is the material category; for farmbuy reagents it maps to the acquisition source.
-- Verified in-game 12.0.7 (Midnight) 2026-07-09; subClassID is locale-stable.
local TRADEGOODS_SOURCE = {
    [9]  = { tier = "gather", label = "Herbalism"   },
    [7]  = { tier = "gather", label = "Mining"      },
    [6]  = { tier = "gather", label = "Skinning"    },
    [12] = { tier = "refine", label = "Disenchant"  },
    [16] = { tier = "refine", label = "Milling"     },
    [4]  = { tier = "refine", label = "Prospecting" },
    [5]  = { tier = "farm",   label = "Cloth"       },
    [8]  = { tier = "farm",   label = "Cooking"     },
    -- 11 (Other) + any unlisted subclass -> nil -> generic Farm/Buy
}

-- [itemID] = {tier,label} once classID resolves; NONE = resolved-but-no-method;
-- nil = Item.db2 cold cache, retried next call. Static category, never invalidates
-- (same rationale as bindCache). GetItemInfoInstant fires NO server request.
local gatherCache = {}
local NONE = {}
local function ResolveGather(itemID)
    local cached = gatherCache[itemID]
    if cached ~= nil then
        if cached == NONE then return nil, nil end
        return cached.label, cached.tier
    end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    if classID == nil then return nil, nil end -- exception(boundary): Item.db2 cold cache; retry next paint
    local entry = classID == 7 and TRADEGOODS_SOURCE[subClassID] or nil -- 7 = Enum.ItemClass.Tradegoods
    gatherCache[itemID] = entry or NONE
    if entry then return entry.label, entry.tier end
    return nil, nil
end

-- ============================================================================
-- Salvage-output tag (Midnight Recycling). No client API maps salvage OUTPUTS
-- to their recipe (outputs are server loot; DB2 dead-ends at treasure ids --
-- docs/VWB_SALVAGE_SOURCES_RESEARCH_2026-07-12.md). Blizzard names them in
-- the salvage recipe DESCRIPTION ("...like Aetherlume and Evercores"), so a
-- farmbuy mat's own name is frontier-matched against the handful of stored
-- salvage descriptions (owner 2026-07-12: no capture, no hand-coding).
-- ============================================================================

local salvageTagCache = {} -- [itemID] = {label,tier} | NONE; wiped on InvalidateIndexes (the salvage set grew)

local function isWordChar(c)
    return c ~= "" and c:match("%w") ~= nil
end

-- Plain-find containment with word frontiers; a trailing pluralizing "s" on
-- the text side counts as a frontier ("Evercores" matches item "Evercore",
-- but a hypothetical item "Core" does NOT match inside "Evercores").
local function nameInText(name, text)
    local init = 1
    while true do
        local s, e = text:find(name, init, true)
        if not s then return false end
        local beforeOk = s == 1 or not isWordChar(text:sub(s - 1, s - 1))
        local nxt = text:sub(e + 1, e + 1)
        if (nxt == "s" or nxt == "S") and not isWordChar(text:sub(e + 2, e + 2)) then
            nxt = text:sub(e + 2, e + 2) -- plural frontier
        end
        if beforeOk and not isWordChar(nxt) then return true end
        init = s + 1
    end
end

local function ResolveSalvage(itemID)
    local cached = salvageTagCache[itemID]
    if cached ~= nil then
        if cached == NONE then return nil, nil end
        return cached.label, cached.tier
    end
    if not C_Item.IsItemDataCachedByID(itemID) then return nil, nil end -- exception(boundary): the name needs the item cache; retry next paint, don't poison NONE
    local name = C_Item.GetItemInfo(itemID)
    if not name then return nil, nil end -- exception(boundary): same cold-cache retry
    for _, rec in pairs(VWB.Store:GetState().salvageRecipes) do
        if nameInText(name, rec.description) then
            salvageTagCache[itemID] = { label = rec.name, tier = "salvage" }
            return rec.name, "salvage"
        end
    end
    salvageTagCache[itemID] = NONE
    return nil, nil
end

local function BuildIndexes()
    if outputs then return end
    outputs, inputs = {}, {}

    for recipeID, recipe in pairs(VWB.Database:GetAllRecipes()) do
        if recipe.itemID then
            local list = outputs[recipe.itemID]
            if not list then
                list = {}
                outputs[recipe.itemID] = list
            end
            table.insert(list, recipeID)
        end

        if recipe.slots then
            for _, slot in ipairs(recipe.slots) do
                if slot.type == "basic" and slot.itemID then
                    local list = inputs[slot.itemID]
                    if not list then
                        list = {}
                        inputs[slot.itemID] = list
                    end
                    table.insert(list, recipeID)
                end
            end
        end
    end
end

function VWB.ReagentSource:InvalidateIndexes()
    outputs = nil
    inputs = nil
    for k in pairs(salvageTagCache) do salvageTagCache[k] = nil end -- NONE entries retry against the grown salvage set
end

-- { class = "farmbuy"|"crafted"|"endproduct", usedInCount, producedByCount,
--   producedBy = {recipeIDs}, bop = true|false|nil }
-- itemID nil is a valid input for this public entry point (e.g. a recipe whose
-- output itemID never resolved) -- exception(nullable): answer "farmbuy,
-- unknown bind" rather than erroring, same spirit as GetRecipeByItemID's nil-itemID handling.
function VWB.ReagentSource:GetInfo(itemID)
    if not itemID then
        return { class = "farmbuy", usedInCount = 0, producedByCount = 0, producedBy = {}, usedIn = {}, bop = nil }
    end

    BuildIndexes()

    local producedBy = outputs[itemID] or {}
    local usedIn = inputs[itemID] or {}

    local class
    if #producedBy > 0 and #usedIn > 0 then
        class = "crafted"
    elseif #producedBy > 0 then
        class = "endproduct"
    else
        class = "farmbuy"
    end

    local bop = nil
    local bindType = bindCache[itemID]
    if bindType == nil and C_Item.IsItemDataCachedByID(itemID) then
        -- exception(boundary): read bind only when the item is already cached --
        -- GetItemInfo on an uncached itemID fires a server request, and issuing
        -- thousands per paint sustained a request->event->repaint loop
        bindType = select(14, C_Item.GetItemInfo(itemID))
        bindCache[itemID] = bindType
    end
    if bindType ~= nil then
        bop = bindType == Enum.ItemBind.OnAcquire -- OnAcquire (1) = Bind on Pickup
    end

    local gatherMethod, sourceTier = nil, nil
    if class == "farmbuy" then
        gatherMethod, sourceTier = ResolveGather(itemID)
        if not gatherMethod then
            gatherMethod, sourceTier = ResolveSalvage(itemID) -- "FARM 5x Aetherlume  Recycling"
        end
    end

    return {
        class = class,
        usedInCount = #usedIn,
        producedByCount = #producedBy,
        producedBy = producedBy,
        usedIn = usedIn, -- recipe IDs that CONSUME this reagent (for the Stockroom detail panel)
        bop = bop,
        gatherMethod = gatherMethod, -- nil unless farmbuy with a Trade Goods subclass OR a salvage-description match
        sourceTier = sourceTier,     -- "gather" | "refine" | "farm" | "salvage" | nil
    }
end

function VWB.ReagentSource:GetClass(itemID)
    return self:GetInfo(itemID).class
end

-- Every itemID this module has an opinion on (appears as an input or output
-- somewhere in recipeStore). Feeds the upcoming diagnostic tab; caller pairs()
-- the keys and calls GetInfo(itemID) per entry for details.
function VWB.ReagentSource:GetAllClassified()
    BuildIndexes()
    local seen = {}
    for itemID in pairs(inputs) do seen[itemID] = true end
    for itemID in pairs(outputs) do seen[itemID] = true end
    return seen
end
