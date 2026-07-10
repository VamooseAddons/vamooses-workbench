-- ============================================================================
-- VWB Store - a minimal signals-backed state store (replaces VPC's Redux-lite).
-- ============================================================================
-- Sized to the Showroom + Workbench pipelines: recipeStore / knownRecipes /
-- account (populated ONLY by the live harvest -- nothing seeded) plus the
-- crafting queue (queuedRecipes persisted; expandedQueue/shoppingList/
-- queuedByItemID are computed by Graph's RebuildCraftingState) and config
-- (materialsMode). Persisted slices are ALIASED to VWB_DB so writes survive
-- reload for free. A single Reactor version signal, bumped after EVERY dispatch
-- (VPC's blanket VPC_STATE_CHANGED, one signal here), is the reactivity handle.
--
-- Reducers take (state, payload) and mutate in place -- the signature Graph's
-- self-registered queue reducers expect. Ported modules that self-register
-- (Graph) use Store:RegisterReducer; the core recipe reducers are built in.
-- Loaded AFTER Reactor and BEFORE Modules/Graph.lua in the .toc.
-- ============================================================================

VWB = VWB or {}
local Store = {}
VWB.Store = Store

local state = {
    recipeStore = {}, knownRecipes = {}, recipeCoverage = {},
    account = { characters = {} },
    crafting = { queuedRecipes = {}, queuedByItemID = {}, expandedQueue = {}, shoppingList = {} },
    craftingHistory = {},
    minimap = { minimapPos = 220 },
    config = { materialsMode = "raw" },
    ui = {
        navSelectedExp = "AllExps", navSelectedItem = nil, navCollapsed = {},
        scopeCharacter = nil, recentPreviewed = {}, recentQueued = {},
    },
    projects = { items = {}, nextId = 1 },
}

function Store:GetState() return state end

-- Reactivity: a BLANKET signal (Store:Version()) bumped on every dispatch for
-- back-compat, PLUS per-slice signals (Store:Version("recipes") etc.) so a view
-- can subscribe only the slice it cares about -- a config/minimap change then
-- won't re-derive the recipe or reagent lists. Reading either inside a computed
-- subscribes it; Dispatch bumps the blanket + the action's mapped slices.
local version = VWB.Reactor.signal(0)
local slices = {
    recipes = VWB.Reactor.signal(0), crafting = VWB.Reactor.signal(0),
    characters = VWB.Reactor.signal(0), history = VWB.Reactor.signal(0),
    config = VWB.Reactor.signal(0), minimap = VWB.Reactor.signal(0),
    projects = VWB.Reactor.signal(0), -- persisted plan board (items + nextId)
    -- corpus = the recipe DEFINITION set (recipeStore itemID/slots). Bumped ONLY
    -- by ADD_RECIPES (own-profession scan / guild scan) -- NOT by SET_KNOWN_RECIPES,
    -- which only flips known-status. Pure-definition derivations (Stockroom
    -- classification, Showroom universe, Records coverage) subscribe this so a
    -- known-status scan doesn't re-walk ~10k reagents/recipes. See the accurate-
    -- subscriptions note: classification is a function of definitions alone.
    corpus = VWB.Reactor.signal(0),
    -- coverage = per-profession x expansion scan status/timestamp (recipeCoverage).
    -- Split OFF corpus: it updates on EVERY scan (carries lastScan), incl. a craft-
    -- triggered re-harvest that adds no definitions -- riding corpus would re-walk
    -- Stockroom classification + Showroom universe for nothing. Records subscribes
    -- corpus (counts) + coverage (scan status).
    coverage = VWB.Reactor.signal(0),
    -- ui split into two: nav selection/collapse/scope (drives the heavy category
    -- filters) vs the MRU recent-strips. A preview/queue click writes only the
    -- recent rings, so it must NOT bump the nav-dependent universe re-filter.
    nav = VWB.Reactor.signal(0), recent = VWB.Reactor.signal(0),
}
local ACTION_SLICES = {
    ADD_RECIPES = { "recipes", "corpus" }, -- corpus: definitions grew -> reclassify
    UPDATE_COVERAGE = { "coverage" }, -- scan status/timestamp only; NOT corpus (no reclassify on craft)
    SET_KNOWN_RECIPES = { "recipes", "characters" }, -- known-status only; NOT corpus
    SAVE_CHARACTER_PROFESSIONS = { "characters" },
    ADD_CRAFTING_HISTORY = { "history" }, CLEAR_HISTORY = { "history" },
    ADD_TO_QUEUE = { "crafting" }, REMOVE_FROM_QUEUE = { "crafting" },
    UPDATE_QUEUE_QTY = { "crafting" }, CLEAR_QUEUE = { "crafting" },
    TOGGLE_MATERIALS_MODE = { "crafting", "config" }, REBUILD_CRAFTING_STATE = { "crafting" },
    SET_CONFIG = { "config" }, SET_MINIMAP_POS = { "minimap" },
    SET_NAV_SELECTION = { "nav" }, TOGGLE_NAV_COLLAPSE = { "nav" },
    SET_NAV_COLLAPSED_ALL = { "nav" },
    SET_SCOPE = { "nav" }, CLEAR_SCOPE = { "nav" },
    PUSH_RECENT_PREVIEWED = { "recent" }, PUSH_RECENT_QUEUED = { "recent" },
    ADD_PROJECT = { "projects" }, REMOVE_PROJECT = { "projects" },
    SET_PROJECT_PAR = { "projects" }, PIN_PROJECT_STEP = { "projects" },
    UNPIN_PROJECT_STEP = { "projects" }, COMPLETE_PROJECT = { "projects" },
    PROJECT_REFILLED = { "projects" },
}
function Store:Version(slice)
    if slice then return (slices[slice] or error("VWB.Store: unknown slice '" .. tostring(slice) .. "'"))() end
    return version()
end
local function bumpSig(s) s(s() + 1) end
local function bump(action)
    bumpSig(version)
    local touched = ACTION_SLICES[action]
    if touched then
        for i = 1, #touched do bumpSig(slices[touched[i]]) end
    else
        for _, s in pairs(slices) do bumpSig(s) end -- unmapped action -> bump all (safe)
    end
end

-- Alias the persisted slices onto VWB_DB so writes survive reload with no save
-- step. queuedRecipes persists; the 3 computed crafting fields stay in-memory
-- (Graph rebuilds them). config persists (materialsMode).
function Store:LoadFromSavedVariables()
    VWB_DB = VWB_DB or {}
    VWB_DB.recipeStore    = VWB_DB.recipeStore or {}
    VWB_DB.knownRecipes   = VWB_DB.knownRecipes or {}
    VWB_DB.recipeCoverage = VWB_DB.recipeCoverage or {}
    VWB_DB.account        = VWB_DB.account or {}
    VWB_DB.account.characters = VWB_DB.account.characters or {}
    VWB_DB.crafting       = VWB_DB.crafting or {}
    VWB_DB.crafting.queuedRecipes = VWB_DB.crafting.queuedRecipes or {}
    VWB_DB.config         = VWB_DB.config or {}
    if VWB_DB.config.materialsMode == nil then VWB_DB.config.materialsMode = "raw" end
    VWB_DB.craftingHistory = VWB_DB.craftingHistory or {}
    VWB_DB.minimap        = VWB_DB.minimap or { minimapPos = 220 }
    VWB_DB.ui             = VWB_DB.ui or {}
    VWB_DB.ui.navCollapsed = VWB_DB.ui.navCollapsed or {}
    VWB_DB.ui.recentPreviewed = VWB_DB.ui.recentPreviewed or {}
    VWB_DB.ui.recentQueued = VWB_DB.ui.recentQueued or {}
    if VWB_DB.ui.navSelectedExp == nil then VWB_DB.ui.navSelectedExp = "AllExps" end
    state.recipeStore    = VWB_DB.recipeStore
    state.knownRecipes   = VWB_DB.knownRecipes
    state.recipeCoverage = VWB_DB.recipeCoverage
    state.account        = VWB_DB.account
    state.crafting.queuedRecipes = VWB_DB.crafting.queuedRecipes
    state.craftingHistory = VWB_DB.craftingHistory
    state.minimap        = VWB_DB.minimap
    state.config         = VWB_DB.config
    state.ui             = VWB_DB.ui
    state.ui.scopeCharacter = nil -- scope is session-only, never persists
    VWB_DB.projects        = VWB_DB.projects or {}
    VWB_DB.projects.items  = VWB_DB.projects.items or {}
    if VWB_DB.projects.nextId == nil then VWB_DB.projects.nextId = 1 end
    state.projects       = VWB_DB.projects
end

function Store:Initialize()
    self:LoadFromSavedVariables()
end

-- Reducers: (state, payload) -> mutate in place. Core recipe reducers built in;
-- Graph self-registers its queue reducers via RegisterReducer at file load.
local reducers = {}
function Store:RegisterReducer(action, fn) reducers[action] = fn end

reducers.ADD_RECIPES = function(st, p)
    for recipeID, record in pairs(p.records or {}) do
        st.recipeStore[recipeID] = record
    end
    VWB.Database:InvalidateIndexes()
end

-- Coverage (scan status/timestamps) is written here, NOT in ADD_RECIPES, so a
-- re-scan that finds no new definitions doesn't bump corpus. No index invalidate:
-- recipeCoverage isn't part of the itemID->recipe index.
reducers.UPDATE_COVERAGE = function(st, p)
    for k, entry in pairs(p.coverage or {}) do st.recipeCoverage[k] = entry end
end

reducers.SET_KNOWN_RECIPES = function(st, p)
    for recipeID in pairs(p.recipes or {}) do st.knownRecipes[recipeID] = true end
    local charKey = p.charKey
    if charKey then
        local rec = st.account.characters[charKey]
        if not rec then
            rec = { name = charKey:match("^(.-)%-") or charKey, professions = {} }
            st.account.characters[charKey] = rec
        end
        rec.knownRecipes = rec.knownRecipes or {}
        for recipeID in pairs(p.recipes or {}) do rec.knownRecipes[recipeID] = true end
    end
end

reducers.CLEAR_HISTORY = function(st)
    for i = #st.craftingHistory, 1, -1 do st.craftingHistory[i] = nil end
end

reducers.ADD_CRAFTING_HISTORY = function(st, p)
    table.insert(st.craftingHistory, 1, {
        name = p.name, itemID = p.itemID, qty = p.qty, profession = p.profession,
        character = p.character, realm = p.realm, timestamp = p.timestamp or time(),
    })
    while #st.craftingHistory > 200 do table.remove(st.craftingHistory) end
end

reducers.SAVE_CHARACTER_PROFESSIONS = function(st, p)
    local existing = st.account.characters[p.charKey]
    st.account.characters[p.charKey] = {
        name = p.name, realm = p.realm, class = p.class, faction = p.faction,
        lastSeen = time(), professions = p.professions or {},
        knownRecipes = (existing and existing.knownRecipes) or {},
    }
end

-- UI state (nav selection/collapse, character scope, recent strips). ----------
local RECENT_MAX = 10
local function pushRecent(ring, item)
    for i = #ring, 1, -1 do if ring[i].itemID == item.itemID then table.remove(ring, i) end end
    table.insert(ring, 1, item)
    while #ring > RECENT_MAX do table.remove(ring) end
end
reducers.SET_NAV_SELECTION = function(st, p) st.ui.navSelectedExp = p.exp; st.ui.navSelectedItem = p.item end
reducers.TOGGLE_NAV_COLLAPSE = function(st, p) st.ui.navCollapsed[p.key] = (not st.ui.navCollapsed[p.key]) or nil end
-- Expand-all / collapse-all: set every passed section key at once (nil clears).
reducers.SET_NAV_COLLAPSED_ALL = function(st, p)
    for _, key in ipairs(p.keys) do st.ui.navCollapsed[key] = p.collapsed or nil end
end
reducers.SET_SCOPE = function(st, p) st.ui.scopeCharacter = p.charKey end
reducers.CLEAR_SCOPE = function(st) st.ui.scopeCharacter = nil end
reducers.PUSH_RECENT_PREVIEWED = function(st, p) pushRecent(st.ui.recentPreviewed, p.item) end
reducers.PUSH_RECENT_QUEUED = function(st, p) pushRecent(st.ui.recentQueued, p.item) end

-- Flat-config setter: config is a scalar map (materialsMode/priceSource/theme/
-- ambientTooltips/...), so a {key,value} setter is atomic here -- no read-modify-
-- write nesting to race. Anything with structure gets a named reducer instead.
reducers.SET_CONFIG = function(st, p) st.config[p.key] = p.value end
reducers.SET_MINIMAP_POS = function(st, p) st.minimap.minimapPos = p.angle end

-- Projects slice. IDs from a monotonic counter; timestamps from a single time()
-- read at dispatch so createdAt/completedAt are consistent within one action.
-- All mutations in-place (alias contract: st.projects IS VWB_DB.projects). ------
reducers.ADD_PROJECT = function(st, p)
    local now = p._time or time()
    local id = st.projects.nextId
    st.projects.nextId = id + 1
    st.projects.items[#st.projects.items + 1] = {
        id = id, name = p.name, icon = p.icon,
        itemID = p.itemID, recipeID = p.recipeID,
        kind = p.kind or "collect", par = p.par or 20,
        pins = {}, createdAt = now, completedAt = nil, refills = 0,
    }
end

reducers.REMOVE_PROJECT = function(st, p)
    local items = st.projects.items
    for i = #items, 1, -1 do
        if items[i].id == p.id then table.remove(items, i); return end
    end
end

reducers.SET_PROJECT_PAR = function(st, p)
    local items = st.projects.items
    for i = 1, #items do
        if items[i].id == p.id then items[i].par = p.par; return end
    end
end

reducers.PIN_PROJECT_STEP = function(st, p)
    local items = st.projects.items
    for i = 1, #items do
        if items[i].id == p.id then items[i].pins[p.stepKey] = p.charKey; return end
    end
end

reducers.UNPIN_PROJECT_STEP = function(st, p)
    local items = st.projects.items
    for i = 1, #items do
        if items[i].id == p.id then items[i].pins[p.stepKey] = nil; return end
    end
end

reducers.COMPLETE_PROJECT = function(st, p)
    local now = p._time or time()
    local items = st.projects.items
    for i = 1, #items do
        if items[i].id == p.id then items[i].completedAt = now; return end
    end
end

reducers.PROJECT_REFILLED = function(st, p)
    local items = st.projects.items
    for i = 1, #items do
        if items[i].id == p.id then items[i].refills = items[i].refills + 1; return end
    end
end

function Store:Dispatch(action, payload)
    local r = reducers[action] or error("VWB.Store: no reducer for '" .. tostring(action) .. "'")
    r(state, payload or {})
    bump(action) -- blanket + the action's mapped slice signals
    return state
end
