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
-- ("spellID", recipeSpellID) returns one cached object per source; we walk
-- each object's parent chain (GetRelativeValue traversal) for the ancestor
-- NPC node whose name matches the row's vendor/trainer AND carries coords.
-- Verified in their src/Cache.lua + src/base.lua + src/Classes/NPC.lua
-- (research 2026-07-11; see docs/VWB_STUDY_COORDS_RESEARCH_2026-07-11.md).
-- ============================================================================

local Reactor = VWB.Reactor
local latch = Reactor.latchMap("npccoords") -- ["spellID:npcName"] = pin | PENDING | false (terminal miss)

local function attReady()
    return C_AddOns.IsAddOnLoaded("AllTheThings") and _G.ATTC ~= nil
        and _G.ATTC.SearchForField ~= nil and _G.ATTC.GetRelativeValue ~= nil -- exception(boundary): third-party surface; any piece may vanish in an ATT update
end

-- Static per session (ATT is not load-on-demand): lets views render the
-- capability honestly -- a greyed Map button teaching "install ATT" when
-- absent, vs no button at all when ATT is present but has no pin.
function VWB.NpcCoords.Available()
    return attReady()
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

-- One hop up the uiMap tree, translating the position through world space,
-- or -- for instanced city maps (Northrend Dalaran) that share NO world
-- frame with their parent -- through UI space via the child's drawn rect on
-- the parent (live 2026-07-12: the world hop dies on Dalaran and vendors
-- stayed pinned to the city map). Returns nil at the top of the tree or
-- when neither translation exists.
local function hopToParent(uiMapID, x, y) -- x/y 0-100
    local info = C_Map.GetMapInfo(uiMapID)
    local parent = info and info.parentMapID
    if not parent or parent == 0 then return nil end -- exception(boundary): top of the map tree
    local cont, world = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(x / 100, y / 100))
    if world then
        local _, pos = C_Map.GetMapPosFromWorldPos(cont, world, parent)
        if pos then return parent, pos.x * 100, pos.y * 100 end
    end
    local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(uiMapID, parent)
    if minX and maxX > minX then -- exception(boundary): 0-wide rect = child not drawn on this parent
        return parent, (minX + (x / 100) * (maxX - minX)) * 100, (minY + (y / 100) * (maxY - minY)) * 100
    end
    return nil
end

local MAX_HOPS = 4

-- Prefer the ancestor map whose NAME matches the tooltip's zone: Blizzard's
-- source text names the zone (Crystalsong Forest), ATT pins the precise
-- sub-map (Dalaran City) -- same chain, wrong rung (owner 2026-07-12). The
-- zone map is what the row text says, and it's where waypoints work.
local function zoneNamedAncestor(uiMapID, x, y, zoneName)
    for _ = 1, MAX_HOPS do
        local info = C_Map.GetMapInfo(uiMapID)
        if not info then return nil end -- exception(boundary): ATT can carry stale map ids
        if info.name == zoneName then return uiMapID, x, y end
        uiMapID, x, y = hopToParent(uiMapID, x, y)
        if not uiMapID then return nil end
    end
    return nil
end

-- Fallback normalization when no ancestor matches the zone name: walk up to
-- the first map that accepts user waypoints so supertrack works.
local function waypointableMap(uiMapID, x, y)
    for _ = 1, MAX_HOPS do
        if C_Map.CanSetUserWaypointOnMap(uiMapID) then return uiMapID, x, y end
        local pid, px, py = hopToParent(uiMapID, x, y)
        if not pid then break end
        uiMapID, x, y = pid, px, py
    end
    return uiMapID, x, y -- no waypointable ancestor: keep the precise map; our own pin still renders there
end

local function normalizePin(uiMapID, x, y, zoneName)
    if zoneName then
        local zid, zx, zy = zoneNamedAncestor(uiMapID, x, y, zoneName)
        if zid then return zid, zx, zy end
    end
    return waypointableMap(uiMapID, x, y)
end

-- Walk the ATT parent chain (same traversal as their GetRelativeValue) for
-- the ancestor node that IS the named NPC, then take coords from the nearest
-- coords-bearing node at-or-ABOVE it -- city shop vendors (Dalaran) carry
-- coords on the shop/POI header node, not on the NPC node itself (live
-- 2026-07-12: Kaye Toogie). Name-matching per source exists because a recipe
-- with several sources returns one cached object per source, and first-hit
-- coords pinned the wrong vendor (Kaye's row waypointed Winterspring).
-- Second return is true when a name isn't comparable yet -- ATT NPC names
-- load async via creature-tooltip queries, and 12.0.5 can hand back SECRET
-- names ATT deliberately doesn't cache (Reference/MIDNIGHT_SECRET_VALUES.md).
-- `seen` collects the coord-bearing names so a terminal miss can SAY what
-- ATT offered instead.
local function namedAncestorPin(obj, npcName, zoneName, seen)
    local node, unresolved, matchedNpcID = obj, false, nil
    while node do
        local name = node.name -- exception(boundary): triggers ATT's async name query; nil until the tooltip answers
        local hasCoords = type(node.coords) == "table"
        if name ~= nil and issecretvalue(name) then -- exception(boundary): secret names error on compare; retry, ATT doesn't cache them
            unresolved = true
        elseif name == npcName then
            matchedNpcID = node.npcID -- identity even without coords: enough for a precise Wowhead link
            local c = node
            while c do -- identity found: nearest coords at-or-above places the source
                if type(c.coords) == "table" then
                    local uiMapID, x, y = firstPin(c.coords)
                    if uiMapID then
                        uiMapID, x, y = normalizePin(uiMapID, x, y, zoneName)
                        return { uiMapID = uiMapID, x = x, y = y, npcID = matchedNpcID }, false
                    end
                end
                c = c.sourceParent or c.parent
            end
            seen[#seen + 1] = tostring(name) .. " (no coords in chain)"
        elseif name == nil then
            unresolved = true
            if hasCoords then seen[#seen + 1] = "<name pending>" end
        elseif hasCoords then
            seen[#seen + 1] = tostring(name)
        end
        node = node.sourceParent or node.parent
    end
    return nil, unresolved, matchedNpcID
end

-- Boundary write half (Constitution R2/R4, ItemData shape): acquisition rides
-- Reactor.defer past the current computation; resolution latches at the
-- moment of truth. ATT NPC names arrive via async creature-tooltip queries
-- with NO completion event, so a still-unresolved name gets bounded timed
-- re-checks before latching the terminal miss.
local RETRY_DELAYS = { 0.5, 1, 2 }

local function resolve(key, spellID, npcName, zoneName, attempt)
    -- defer/timer context: latching is legal here, never inside a computed
    local anyUnresolved, seen, namedID = false, {}, nil
    local results = _G.ATTC.SearchForField("spellID", spellID)
    for _, obj in ipairs(results or {}) do -- exception(boundary): ATT returns nil for unknown ids
        local pin, unresolved, npcID = namedAncestorPin(obj, npcName, zoneName, seen)
        if pin then latch:latch(key, pin); return end
        anyUnresolved = anyUnresolved or unresolved
        namedID = namedID or npcID
    end
    if anyUnresolved and RETRY_DELAYS[attempt] then
        VWB.ReactorWoW.after(RETRY_DELAYS[attempt], function() resolve(key, spellID, npcName, zoneName, attempt + 1) end)
        return -- key stays PENDING
    end
    if namedID then -- NPC identified but unpinnable (Underbelly-class vendors): Wowhead link, no Map
        VWB.Log:Debug(string.format("NpcCoords: '%s' matched (npc %d) but no coords in ATT", npcName, namedID))
        latch:latch(key, { npcID = namedID })
        return
    end
    -- terminal miss is never mute: say what ATT offered so a mismatch
    -- (renamed NPC, missing coords, wrong search field) is diagnosable.
    -- Debug-gated -- the UI carries the player-facing state (no Map button).
    VWB.Log:Debug(string.format("NpcCoords: no pin for '%s' (spell %d, %d ATT hits%s)",
        npcName, spellID, results and #results or 0,
        #seen > 0 and (", coord chains: " .. table.concat(seen, " / ")) or ", no coord ancestors"))
    latch:latch(key, false)
end

local acquiring = {} -- keys with a deferred acquisition queued (pre-latch dedupe)
local attAbsentWarned = false
local function acquire(key, spellID, npcName, zoneName)
    if latch:hasKey(key) or acquiring[key] then return end
    acquiring[key] = true
    Reactor.defer(function()
        acquiring[key] = nil
        if latch:hasKey(key) then return end
        if not attReady() then -- ATT loads at login or never: terminal for the session
            if not attAbsentWarned then
                attAbsentWarned = true
                -- debug-gated: the greyed Map button + tooltip carry this to players
                VWB.Log:Debug("NpcCoords: AllTheThings not available -- no source waypoints this session")
            end
            latch:latch(key, false)
            return
        end
        latch:latch(key, Reactor.PENDING)
        resolve(key, spellID, npcName, zoneName, 1)
    end)
end

-- Tracked read: position of a NAMED source NPC for a recipe -- { uiMapID,
-- x, y, npcID } (x/y 0-100, Blizzard C_Map ids), { npcID } alone when ATT
-- knows the NPC but has no coords (Underbelly-class vendors), or nil (no
-- ATT / pending / name mismatch). Acquires on first sight; the caller's
-- effect re-runs when the pin latches. npcName is the source detail from
-- the recipe tooltip parse -- non-NPC sources (quest names) honestly never
-- match. zoneName (optional) is the tooltip's zone: the pin normalizes up
-- to that map so the row text and the opened map agree.
function VWB.NpcCoords.ForRecipe(recipeSpellID, npcName, zoneName)
    if not (recipeSpellID and npcName) then return nil end -- exception(nullable): non-NPC sources (Discovery, quest text) carry no npc detail
    local key = recipeSpellID .. ":" .. npcName
    acquire(key, recipeSpellID, npcName, zoneName)
    local v = latch:get(key)
    if v == nil or v == Reactor.PENDING or v == false then return nil end
    return v
end

local mapOpenHooked, pendingMapID

-- ShowUIPanel dispatches async to a secure delegate, then WorldMapMixin:OnShow
-- clobbers any inline SetMapID. Our HookScript runs AFTER Blizzard's and
-- re-applies the pending map. (Wrong-map fix, pattern from HDG.Waypoints.)
local function hookMapOpen()
    if mapOpenHooked then return end
    mapOpenHooked = true
    WorldMapFrame:HookScript("OnShow", function()
        if pendingMapID and WorldMapFrame:GetMapID() ~= pendingMapID then
            WorldMapFrame:SetMapID(pendingMapID)
        end
        pendingMapID = nil
    end)
end

-- ============================================================================
-- Own map pin (HDG vendor-pin layer pattern, single-pin edition). Some maps
-- refuse C_Map.SetUserWaypoint outright (Ashran cities, Dalaran) -- our own
-- frame on the map canvas renders everywhere, so the Map action always shows
-- the target even when Blizzard's waypoint half is refused.
-- ============================================================================

local overlay, pinFrame
local pinTarget -- { mapID, x, y (0-1), title } -- the ONE current target; each Map click replaces it

local function renderPin()
    if not pinTarget or WorldMapFrame:GetMapID() ~= pinTarget.mapID then
        pinFrame:Hide()
        return
    end
    local w, h = overlay:GetWidth(), overlay:GetHeight()
    local scale = 1 / WorldMapFrame:GetCanvasScale() -- counter-scale: pin stays screen-sized through zoom
    pinFrame:SetScale(scale)
    pinFrame:ClearAllPoints()
    pinFrame:SetPoint("CENTER", overlay, "TOPLEFT", (w * pinTarget.x) / scale, -(h * pinTarget.y) / scale)
    pinFrame:Show()
end

-- MapCanvas.MapSet fires BEFORE canvas geometry settles; poll for non-zero
-- width before rendering (HDG WaitForCanvasReady pattern).
local function renderWhenReady(attempts)
    if not pinTarget then return end
    if overlay:GetWidth() > 0 then
        renderPin()
    elseif (attempts or 0) < 30 then
        VWB.ReactorWoW.after(0.1, function() renderWhenReady((attempts or 0) + 1) end)
    end
end

local function ensurePinLayer()
    if overlay then return end
    -- Inner scaled canvas (zooms/pans); parenting here moves the pin with the map
    local sc = WorldMapFrame.ScrollContainer
    local canvas = sc and sc.Child or WorldMapFrame:GetCanvasContainer() -- exception(boundary): Blizzard canvas internals
    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(canvas:GetFrameLevel() + 10)
    pinFrame = CreateFrame("Frame", nil, overlay)
    pinFrame:SetFrameStrata("HIGH") -- canvas default renders behind Blizzard UI
    pinFrame:SetSize(20, 20)
    pinFrame:EnableMouse(true)
    local icon = pinFrame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetAtlas("Waypoint-MapPin-Untracked")
    pinFrame:SetScript("OnEnter", function(self)
        local T = VWB.UI.Tooltip
        T:Begin(self, "RIGHT")
        T:AddTitle(pinTarget and pinTarget.title or "Workbench target")
        T:Show()
    end)
    pinFrame:SetScript("OnLeave", function(self) VWB.UI.Tooltip:Hide(self) end)
    EventRegistry:RegisterCallback("MapCanvas.MapSet", function() renderWhenReady() end, overlay)
    hooksecurefunc(WorldMapFrame, "OnFrameSizeChanged", renderPin)
    hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", renderPin)
end

-- Show-on-map: our own pin on the map canvas + Blizzard waypoint/supertrack
-- where the map permits, then open the world map focused on the pin's zone
-- (HDG "Map" button behavior).
function VWB.NpcCoords.Waypoint(pin, label)
    if InCombatLockdown() then -- exception(boundary): OpenWorldMap is combat-protected
        VWB.Log:Print("Can't open the map in combat")
        return false
    end
    ensurePinLayer()
    pinTarget = { mapID = pin.uiMapID, x = pin.x / 100, y = pin.y / 100, title = label }
    -- Either way the target lands on the map -- our pin renders everywhere,
    -- the supertrack arrow is a bonus where the map permits it. No chat:
    -- the map opening WITH the pin is the feedback.
    if C_Map.CanSetUserWaypointOnMap(pin.uiMapID) then -- exception(boundary): some maps forbid user pins
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(pin.uiMapID, pin.x / 100, pin.y / 100))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
    hookMapOpen()
    if WorldMapFrame:IsShown() then
        WorldMapFrame:SetMapID(pin.uiMapID) -- same-map SetMapID fires no MapSet, so render directly
        renderWhenReady()
    else
        pendingMapID = pin.uiMapID
        OpenWorldMap(pin.uiMapID) -- MapSet callback renders once the canvas settles
    end
    return true
end

-- Wowhead link for an NPC source: the precise npc= page when ATT matched the
-- NPC (pin carries npcID), a name search otherwise (works with no ATT at
-- all, and for unpinnable vendors where a waypoint can't exist). Shared by
-- Projects and Study.
function VWB.NpcCoords.WowheadURL(npc, pin)
    if pin and pin.npcID then
        return "https://www.wowhead.com/npc=" .. pin.npcID
    end
    local q = (npc or ""):gsub("[^%w%-]", function(c) return string.format("%%%02X", string.byte(c)) end)
    return "https://www.wowhead.com/search?q=" .. q
end

-- Debug dump: ATT's chain for a recipe, so an npcID/name/coord mismatch is
-- inspectable in-game. /run VWB.NpcCoords.DumpATT(spellID) -- prints each ATT
-- hit's parent chain (runtime-resolved name, npcID, mapID, first coords).
-- Names resolve async; run twice if the first pass shows nil names.
function VWB.NpcCoords.DumpATT(spellID)
    if not attReady() then VWB.Log:Print("ATT not available"); return end
    local results = _G.ATTC.SearchForField("spellID", spellID)
    VWB.Log:Print(string.format("|cff2aa198ATT spell %d:|r %d hit(s)", spellID, results and #results or 0))
    for i, obj in ipairs(results or {}) do
        VWB.Log:Print("hit " .. i .. ":")
        local n = obj
        while n do
            local nm = n.name -- exception(boundary): async name query; may be nil/secret
            if nm ~= nil and issecretvalue(nm) then nm = "<secret>" end
            local c = ""
            if type(n.coords) == "table" then
                local m, x, y = firstPin(n.coords)
                c = m and string.format(" @map %s %.1f,%.1f", tostring(m), x, y) or " coords?"
            end
            VWB.Log:Print(string.format("  name=%s npc=%s map=%s%s",
                tostring(nm), tostring(n.npcID), tostring(n.mapID), c))
            n = n.sourceParent or n.parent
        end
    end
end

-- Copy-a-link dialog for the Wowhead buttons (Projects + Study). Registered
-- here, the shared source-link home, so neither view owns the other's popup.
StaticPopupDialogs["VWB_COPY_URL"] = {
    text = "Ctrl+C to copy",
    button1 = "Close",
    hasEditBox = true, editBoxWidth = 340,
    OnShow = function(self, url)
        self.EditBox:SetText(url) -- 12.0.5: editBox renamed EditBox
        self.EditBox:HighlightText()
        self.EditBox:SetFocus()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
