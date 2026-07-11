VWB = VWB or {}
VWB.NpcCoords = {}

-- ============================================================================
-- NpcCoords -- vendor/trainer positions for waypointing, via the ATT bridge.
-- ============================================================================
-- OWNER RULING 2026-07-12: the ATT runtime bridge is the ONLY source -- no
-- static extract (a data hack that goes stale), no organic capture (visiting
-- the vendor completes the piece; nothing left to waypoint). When ATT is
-- absent or has no pin, the answer is honestly nil and the affordance
-- simply does not render.
--
-- AllTheThings is MIT and designed to be queried: _G.ATTC.SearchForField
-- ("spellID", recipeSpellID) returns the recipe's cached objects;
-- GetRelativeValue(obj, "coords") walks .parent up to the NPC node carrying
-- the pins. Verified in their src/Cache.lua + src/base.lua (research
-- 2026-07-11; see docs/VWB_STUDY_COORDS_RESEARCH_2026-07-11.md).
-- ============================================================================

local memo = {} -- [recipeSpellID] = { uiMapID, x, y } | false (session-static: ATT data doesn't move mid-session)

local function attReady()
    return C_AddOns.IsAddOnLoaded("AllTheThings") and _G.ATTC ~= nil
        and _G.ATTC.SearchForField ~= nil and _G.ATTC.GetRelativeValue ~= nil -- exception(boundary): third-party surface; any piece may vanish in an ATT update
end

-- ATT coord entries appear in two shapes across their data era:
-- { x, y, mapID } triplets and { [uiMapID] = { {x,y}, ... } } keyed maps.
-- exception(boundary): third-party data shape; accept both, first pin wins.
local function firstPin(coords)
    for k, v in pairs(coords) do
        if type(k) == "number" and type(v) == "table" then
            if type(v[1]) == "table" then       -- keyed: [uiMapID] = { {x,y}, ... }
                return k, v[1][1], v[1][2]
            elseif type(v[1]) == "number" and v[3] then -- triplet list: { {x, y, mapID}, ... }
                return v[3], v[1], v[2]
            end
        end
    end
end

-- Position for the vendor/trainer of a recipe: { uiMapID, x, y } (x/y 0-100,
-- Blizzard C_Map ids) or nil (no ATT / no pin / not mapped yet).
function VWB.NpcCoords.ForRecipe(recipeSpellID)
    if not recipeSpellID then return nil end
    local hit = memo[recipeSpellID]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    if not attReady() then return nil end
    local results = _G.ATTC.SearchForField("spellID", recipeSpellID)
    for _, obj in ipairs(results or {}) do -- exception(boundary): ATT returns nil for unknown ids
        local coords = _G.ATTC.GetRelativeValue(obj, "coords")
        if type(coords) == "table" then
            local uiMapID, x, y = firstPin(coords)
            if uiMapID and x and y then
                local pin = { uiMapID = uiMapID, x = x, y = y }
                memo[recipeSpellID] = pin
                return pin
            end
        end
    end
    memo[recipeSpellID] = false
    return nil
end

-- Set the user waypoint + supertrack it. Returns true when it stuck.
function VWB.NpcCoords.Waypoint(pin, label)
    if not C_Map.CanSetUserWaypointOnMap(pin.uiMapID) then -- exception(boundary): some maps forbid user pins
        VWB.Log:Print("That map doesn't allow waypoints")
        return false
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(pin.uiMapID, pin.x / 100, pin.y / 100))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    VWB.Log:Print("Waypoint set: " .. (label or "recipe source"))
    return true
end
