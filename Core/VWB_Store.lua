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
    REMOVE_CHARACTER = { "characters", "nav" }, -- nav: may clear scopeCharacter
    ADD_CRAFTING_HISTORY = { "history" }, CLEAR_HISTORY = { "history" },
    ADD_SALVAGE_RECIPES = { "corpus" }, -- mats may gain a salvage tag -> reclassify
    ADD_TO_QUEUE = { "crafting" }, REMOVE_FROM_QUEUE = { "crafting" },
    UPDATE_QUEUE_QTY = { "crafting" }, CLEAR_QUEUE = { "crafting" },
    TOGGLE_MATERIALS_MODE = { "crafting", "config" }, REBUILD_CRAFTING_STATE = { "crafting" },
    SET_CONFIG = { "config" }, SET_MINIMAP_POS = { "minimap" },
    SET_NAV_SELECTION = { "nav" }, TOGGLE_NAV_COLLAPSE = { "nav" },
    SET_NAV_COLLAPSED_ALL = { "nav" },
    SET_SCOPE = { "nav" }, CLEAR_SCOPE = { "nav" },
    PUSH_RECENT_PREVIEWED = { "recent" }, PUSH_RECENT_QUEUED = { "recent" },
    ADD_PROJECT = { "projects" }, REMOVE_PROJECT = { "projects" },
    ADD_PIECE = { "projects" }, REMOVE_PIECE = { "projects" },
    SET_PROJECT_STATUS = { "projects" }, SET_PIECE_PAR = { "projects" },
    PIN_PROJECT_STEP = { "projects" }, UNPIN_PROJECT_STEP = { "projects" },
    COMPLETE_PIECE = { "projects" }, COMPLETE_PROJECT = { "projects" },
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
    VWB_DB.salvageRecipes = VWB_DB.salvageRecipes or {} -- exception(boundary): SV shape init; [recipeID] = {name, description, profession}
    VWB_DB.crafting       = VWB_DB.crafting or {}
    VWB_DB.crafting.queuedRecipes = VWB_DB.crafting.queuedRecipes or {}
    VWB_DB.config         = VWB_DB.config or {}
    if VWB_DB.config.materialsMode == nil then VWB_DB.config.materialsMode = "raw" end
    if VWB_DB.config.ambientTooltips == nil then VWB_DB.config.ambientTooltips = false end -- opt-in (owner 2026-07-13)
    VWB_DB.craftingHistory = VWB_DB.craftingHistory or {}
    VWB_DB.minimap        = VWB_DB.minimap or { minimapPos = 220 }
    VWB_DB.ui             = VWB_DB.ui or {}
    VWB_DB.ui.navCollapsed = VWB_DB.ui.navCollapsed or {}
    VWB_DB.ui.recentPreviewed = VWB_DB.ui.recentPreviewed or {}
    VWB_DB.ui.recentQueued = VWB_DB.ui.recentQueued or {}
    if VWB_DB.ui.navSelectedExp == nil then VWB_DB.ui.navSelectedExp = "AllExps" end
    state.recipeStore    = VWB_DB.recipeStore
    state.salvageRecipes = VWB_DB.salvageRecipes
    state.knownRecipes   = VWB_DB.knownRecipes
    state.recipeCoverage = VWB_DB.recipeCoverage
    state.account        = VWB_DB.account
    state.crafting.queuedRecipes = VWB_DB.crafting.queuedRecipes
    state.craftingHistory = VWB_DB.craftingHistory
    state.minimap        = VWB_DB.minimap
    state.config         = VWB_DB.config
    state.ui             = VWB_DB.ui
    state.ui.scopeCharacter = nil -- scope is session-only, never persists
    -- Showroom category pick is session-only too (owner 2026-07-13: a
    -- persisted "Classic" narrowed the list to 859 on every fresh login, read
    -- as "All shows too few"). Default = no selection = whole corpus.
    state.ui.navSelectedItem = nil
    state.ui.navSelectedExp = "AllExps"
    VWB_DB.projects        = VWB_DB.projects or {}
    VWB_DB.projects.v      = VWB_DB.projects.v or 1
    VWB_DB.projects.items  = VWB_DB.projects.items or {}
    if VWB_DB.projects.nextId == nil then VWB_DB.projects.nextId = 1 end
    -- v1 -> v2 (Commissions): each flat one-item project becomes a one-PIECE
    -- project. TRANSFORM in place, before the state alias below, so reducers
    -- only ever see the current shape. pins belong to the one piece verbatim;
    -- the completion timestamp stays on the PROJECT (the project was
    -- completed; piece-level completion is a new v2 fact and starts nil).
    -- Invariant from here on: status == "done" iff completedAt ~= nil.
    if VWB_DB.projects.v < 2 then -- ORDERED gate ("~= 2" re-ran this against v3 DBs and shredded pieces -- caught by the idempotence test)
        for i, item in ipairs(VWB_DB.projects.items) do
            VWB_DB.projects.items[i] = {
                id = item.id, name = item.name, icon = item.icon,
                status = item.completedAt and "done" or "bench",
                pieces = { {
                    itemID = item.itemID, recipeID = item.recipeID,
                    kind = item.kind or "collect", par = item.par,
                    pins = item.pins or {}, completedAt = nil,
                    refills = item.refills or 0,
                } },
                source = nil,
                createdAt = item.createdAt, completedAt = item.completedAt,
            }
        end
        VWB_DB.projects.v = 2
    end
    -- v2 -> v3 (Commissions): PIECES BECOME ENTITIES -- stable ids from the
    -- same monotonic counter (array position = display order only), and
    -- achievement identity moves onto the PIECE (achievementID) so criteria
    -- tick wherever a piece lives (multi-achievement commissions). Runs
    -- after v1->v2, so a v1 DB double-jumps in one load.
    if VWB_DB.projects.v < 3 then
        for _, item in ipairs(VWB_DB.projects.items) do
            for _, pc in ipairs(item.pieces) do
                pc.id = VWB_DB.projects.nextId
                VWB_DB.projects.nextId = VWB_DB.projects.nextId + 1
                if item.source and item.source.type == "achievement"
                    and pc.kind == "achievement" and not pc.achievementID then
                    pc.achievementID = item.source.id
                end
            end
        end
        VWB_DB.projects.v = 3
    end
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

-- Salvage recipes (Midnight Recycling) stay OUT of recipeStore -- they craft
-- nothing and would pollute the browser/graph. Their DESCRIPTION is the only
-- cold source naming their outputs ("...like Aetherlume and Evercores");
-- ReagentSource frontier-matches mat names against it (owner 2026-07-12:
-- no capture, no hand-coding; docs/VWB_SALVAGE_SOURCES_RESEARCH_2026-07-12.md).
reducers.ADD_SALVAGE_RECIPES = function(st, p)
    for recipeID, rec in pairs(p.records) do
        st.salvageRecipes[recipeID] = rec
    end
    VWB.Database:InvalidateIndexes() -- ReagentSource's salvage-tag memo depends on this set
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
        -- REPLACE-BY-PROFESSION: a tagged scan is authoritative for that
        -- profession on that character -- prune its stale entries first. This
        -- progressively heals per-char maps polluted by the pre-2026-07-11
        -- whole-cache dispatch (every char credited with the account union).
        if p.profession then
            for recipeID in pairs(rec.knownRecipes) do
                local r = st.recipeStore[recipeID] -- exception(nullable): entry may predate the current recipe store
                if r and r.profession == p.profession and not p.recipes[recipeID] then
                    rec.knownRecipes[recipeID] = nil
                end
            end
        end
        for recipeID in pairs(p.recipes or {}) do rec.knownRecipes[recipeID] = true end
    end
end

reducers.CLEAR_HISTORY = function(st)
    for i = #st.craftingHistory, 1, -1 do st.craftingHistory[i] = nil end
end

reducers.ADD_CRAFTING_HISTORY = function(st, p)
    table.insert(st.craftingHistory, 1, {
        name = p.name, itemID = p.itemID, qty = p.qty, profession = p.profession,
        recipeID = p.recipeID, -- craft-piece completion matches on RECIPE (quality tiers ship different itemIDs)
        character = p.character, realm = p.realm, timestamp = p.timestamp or time(),
    })
    while #st.craftingHistory > 200 do table.remove(st.craftingHistory) end
end

reducers.SAVE_CHARACTER_PROFESSIONS = function(st, p)
    local existing = st.account.characters[p.charKey]
    local known = (existing and existing.knownRecipes) or {}
    -- Prune: a recipe belonging to a profession this character does NOT have
    -- cannot be known by them. Heals the pre-2026-07-11 union pollution for
    -- professions the character never opens (replace-by-profession can't reach those).
    -- Gate: skip the O(~500 x recipeStore) walk when the profession NAME SET is
    -- unchanged -- during Craft All, SKILL_LINES_CHANGED fires repeatedly but the
    -- set of professions the character has never changes mid-session. The prune
    -- only matters after a learn/unlearn event, which DOES change the set.
    local pruneNeeded = false
    if p.professions then
        local existingProfs = existing and existing.professions
        if not existingProfs then
            pruneNeeded = true
        else
            -- Count incoming names and verify each exists in the saved set.
            local incomingCount = 0
            for name in pairs(p.professions) do
                incomingCount = incomingCount + 1
                if existingProfs[name] == nil then pruneNeeded = true; break end
            end
            if not pruneNeeded then
                -- Also check count in reverse (saved set may have names not in incoming).
                local savedCount = 0
                for _ in pairs(existingProfs) do savedCount = savedCount + 1 end
                if savedCount ~= incomingCount then pruneNeeded = true end
            end
        end
    end
    if pruneNeeded and p.professions then
        for recipeID in pairs(known) do
            local r = st.recipeStore[recipeID] -- exception(nullable): entry may predate the current recipe store
            if r and r.profession and p.professions[r.profession] == nil then
                known[recipeID] = nil
            end
        end
    end
    st.account.characters[p.charKey] = {
        name = p.name, realm = p.realm, class = p.class, faction = p.faction,
        lastSeen = time(), professions = p.professions or {},
        knownRecipes = known,
    }
end

-- Tester request 2026-07-11: retire a character from the Roster (and from
-- every known-by tooltip/filter, which read account.characters). A future
-- scan on that character simply re-creates the record.
reducers.REMOVE_CHARACTER = function(st, p)
    st.account.characters[p.charKey] = nil
    if st.ui.scopeCharacter == p.charKey then st.ui.scopeCharacter = nil end
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
-- All mutations in-place (alias contract: st.projects IS VWB_DB.projects).
-- v2 (Commissions): a project CONTAINS pieces -- reducers write
-- pieces[i].field in place and NEVER replace the pieces array (the alias
-- must hold through nesting). Unknown-id dispatches no-op (established v1
-- contract, pinned by store_projects_test). Invariant maintained here:
-- status == "done" iff completedAt ~= nil. ------------------------------------
local function findProject(st, id)
    for _, prj in ipairs(st.projects.items) do
        if prj.id == id then return prj end
    end
end

-- v3: pieces are ENTITIES, addressed by stable id everywhere.
local function findPiece(prj, pieceId)
    for _, pc in ipairs(prj.pieces) do
        if pc.id == pieceId then return pc end
    end
end

-- name: display fallback for pieces whose item is cold/absent (achievement
-- criteria text carries the recipe name). achievementID+criteriaIndex:
-- the criteria sweep addresses the PIECE, wherever it lives. qty/charKey:
-- craft-kind pieces (queue saves) keep their target and crafter.
local function buildPiece(st, pc, now)
    local id = st.projects.nextId
    st.projects.nextId = id + 1
    return { id = id, itemID = pc.itemID, recipeID = pc.recipeID, name = pc.name,
        kind = pc.kind or "collect", par = pc.par or VWB.Constants.Projects.DEFAULT_PAR,
        qty = pc.qty, charKey = pc.charKey,
        achievementID = pc.achievementID, criteriaIndex = pc.criteriaIndex,
        createdAt = now, -- craft pieces count history STRICTLY after this
        pins = {}, completedAt = nil, refills = 0 }
end

reducers.ADD_PROJECT = function(st, p)
    local now = p._time or time()
    local id = st.projects.nextId
    st.projects.nextId = id + 1
    local prj = {
        id = id, name = p.name, icon = p.icon,
        status = p.status or "bench", source = p.source,
        pieces = {}, createdAt = now, completedAt = nil,
    }
    for _, pc in ipairs(p.pieces) do
        prj.pieces[#prj.pieces + 1] = buildPiece(st, pc, now)
    end
    st.projects.items[#st.projects.items + 1] = prj
end

reducers.REMOVE_PROJECT = function(st, p)
    local items = st.projects.items
    for i = #items, 1, -1 do
        if items[i].id == p.id then table.remove(items, i); return end
    end
end

-- Done is SEALED (owner ruling 7b-D): no assembly on a done commission.
-- Duplicate recipes no-op (dedupe by recipeID -- multi-session browsing
-- double-adds were a trust break).
reducers.ADD_PIECE = function(st, p)
    local prj = findProject(st, p.projectId)
    if not prj or prj.status == "done" then return end
    if #prj.pieces >= VWB.Constants.Projects.MAX_PIECES then return end
    for _, pc in ipairs(prj.pieces) do
        if pc.recipeID and pc.recipeID == p.piece.recipeID then return end
    end
    prj.pieces[#prj.pieces + 1] = buildPiece(st, p.piece, p._time or time())
end

reducers.REMOVE_PIECE = function(st, p)
    local prj = findProject(st, p.projectId)
    if not prj or prj.status == "done" then return end -- sealed
    for i, pc in ipairs(prj.pieces) do
        if pc.id == p.pieceId then table.remove(prj.pieces, i); return end
    end
end

-- The board move. DONE-ENTRY RULE lives HERE (owner 7b-B/E): entering
-- "done" requires >=1 piece, all stamped -- the reducer refuses otherwise;
-- UI greying is presentation on this same rule. Leaving "done" clears the
-- timestamp (the invariant, both ways).
reducers.SET_PROJECT_STATUS = function(st, p)
    local prj = findProject(st, p.id)
    if not prj then return end
    if p.status == "done" then
        if #prj.pieces == 0 then return end
        for _, pc in ipairs(prj.pieces) do
            if not pc.completedAt then return end
        end
        prj.completedAt = prj.completedAt or (p._time or time())
    else
        prj.completedAt = nil
    end
    prj.status = p.status
end

reducers.SET_PIECE_PAR = function(st, p)
    local prj = findProject(st, p.id)
    local pc = prj and findPiece(prj, p.pieceId)
    if pc then pc.par = p.par end
end

reducers.COMPLETE_PIECE = function(st, p)
    local prj = findProject(st, p.projectId)
    local pc = prj and findPiece(prj, p.pieceId)
    if pc then pc.completedAt = p._time or time() end
end

reducers.PIN_PROJECT_STEP = function(st, p)
    local prj = findProject(st, p.id)
    local pc = prj and findPiece(prj, p.pieceId)
    if pc then pc.pins[p.stepKey] = p.charKey end
end

reducers.UNPIN_PROJECT_STEP = function(st, p)
    local prj = findProject(st, p.id)
    local pc = prj and findPiece(prj, p.pieceId)
    if pc then pc.pins[p.stepKey] = nil end
end

-- Fired ONLY from boundary handlers (ProjectPlanner sweeps, ACHIEVEMENT_
-- EARNED) or the board menu -- never from a computed/effect (R2/R3).
reducers.COMPLETE_PROJECT = function(st, p)
    local prj = findProject(st, p.id)
    if not prj then return end
    prj.completedAt = p._time or time()
    prj.status = "done"
end

reducers.PROJECT_REFILLED = function(st, p)
    local prj = findProject(st, p.id)
    local pc = prj and findPiece(prj, p.pieceId)
    if pc then pc.refills = pc.refills + 1 end
end

function Store:Dispatch(action, payload)
    local r = reducers[action] or error("VWB.Store: no reducer for '" .. tostring(action) .. "'")
    r(state, payload or {})
    bump(action) -- blanket + the action's mapped slice signals
    return state
end
