-- Headless tests for the projects slice, v2 (Commissions): the v1->v2
-- migration transform, all reducers against the pieces shape, nextId
-- monotonicity, the status<->completedAt invariant, and the alias contract
-- (in-place mutations survive reload via the VWB_DB reference).
-- Run: lua store_projects_test.lua

local base = arg[0]:gsub("tests/store_projects_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
_G.time = os.time
_G.VWB = { Reactor = R, Database = { InvalidateIndexes = function() end } }
-- Constants load real values (MAX_PIECES/DEFAULT_PAR live there now)
loadfile(base .. "Core/Constants.lua")("VWB", _G.VWB)

-- Seed a v1-shaped SavedVariables BEFORE the Store loads: the migration must
-- transform it during LoadFromSavedVariables, before the state alias.
_G.VWB_DB = { projects = { nextId = 3, items = {
    { id = 1, name = "Old Cauldron", icon = 133, itemID = 101, recipeID = 501,
      kind = "collect", par = 20, pins = { ["craft:recipe:501"] = "Aly-Realm" },
      createdAt = 100, completedAt = nil, refills = 0 },
    { id = 2, name = "Old Flask", icon = 134, itemID = 202, recipeID = 502,
      kind = "stock", par = 40, pins = {},
      createdAt = 200, completedAt = 900, refills = 3 },
} } }

dofile(base .. "Core/VWB_Store.lua")
local Store = _G.VWB.Store
Store:LoadFromSavedVariables() -- in-game Initialize() does this; run the migration against the seeded v1 DB

local pass, fail = 0, 0
local function check(n, c) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. n) end end

local st = Store:GetState()

local function dispatch(action, payload)
    payload = payload or {}
    payload._time = payload._time or 1000
    Store:Dispatch(action, payload)
end

-- 1. MIGRATION v1 -> v2: transform in place, pins into pieces[1] --------------
do
    check("migration: version stamped", st.projects.v == 2)
    check("migration: nextId carried", st.projects.nextId == 3)
    local m1 = st.projects.items[1]
    check("migration: identity kept", m1.id == 1 and m1.name == "Old Cauldron" and m1.icon == 133)
    check("migration: incomplete -> bench", m1.status == "bench" and m1.completedAt == nil)
    check("migration: one piece", #m1.pieces == 1)
    local pc = m1.pieces[1]
    check("migration: piece fields", pc.itemID == 101 and pc.recipeID == 501
        and pc.kind == "collect" and pc.par == 20 and pc.refills == 0)
    check("migration: pins moved into pieces[1] verbatim", pc.pins["craft:recipe:501"] == "Aly-Realm")
    check("migration: piece completedAt starts nil", pc.completedAt == nil)
    local m2 = st.projects.items[2]
    check("migration: completed -> done, timestamp on PROJECT", m2.status == "done" and m2.completedAt == 900)
    check("migration: stock piece carries par/refills", m2.pieces[1].par == 40 and m2.pieces[1].refills == 3)
    check("migration: source starts nil", m1.source == nil and m2.source == nil)
end

-- 2. ADD_PROJECT builds the v2 shape ------------------------------------------
dispatch("ADD_PROJECT", { name = "Azure Set", icon = 200, source = { type = "manual" },
    pieces = { { itemID = 301, recipeID = 601, kind = "collect" },
               { itemID = 302, recipeID = 602, kind = "stock", par = 10 } } })
local prj = st.projects.items[3]
check("ADD: id from nextId", prj.id == 3 and st.projects.nextId == 4)
check("ADD: status defaults bench", prj.status == "bench")
check("ADD: two pieces", #prj.pieces == 2)
check("ADD: piece defaults (par/pins/refills)", prj.pieces[1].par == VWB.Constants.Projects.DEFAULT_PAR
    and next(prj.pieces[1].pins) == nil and prj.pieces[1].refills == 0)
check("ADD: explicit piece par", prj.pieces[2].par == 10)
check("ADD: source stored", prj.source.type == "manual")
check("ADD: createdAt stamped, completedAt nil", prj.createdAt == 1000 and prj.completedAt == nil)
dispatch("ADD_PROJECT", { name = "Backlog Idea", status = "backlog", pieces = {} })
check("ADD: explicit backlog status", st.projects.items[4].status == "backlog")

-- 3. nextId monotonicity across removes ---------------------------------------
dispatch("REMOVE_PROJECT", { id = 4 })
dispatch("ADD_PROJECT", { name = "Fifth", pieces = {} })
check("nextId monotonic after remove", st.projects.items[#st.projects.items].id == 5)
dispatch("REMOVE_PROJECT", { id = 5 })
check("REMOVE: unknown id no-op", (function()
    local n = #st.projects.items
    dispatch("REMOVE_PROJECT", { id = 9999 })
    return #st.projects.items == n
end)())

-- 4. ADD_PIECE / REMOVE_PIECE, cap enforced -----------------------------------
dispatch("ADD_PIECE", { projectId = 3, piece = { itemID = 303, recipeID = 603 } })
check("ADD_PIECE appends with defaults", #prj.pieces == 3 and prj.pieces[3].kind == "collect")
dispatch("REMOVE_PIECE", { projectId = 3, index = 3 })
check("REMOVE_PIECE removes by index", #prj.pieces == 2)
for _ = 1, 30 do dispatch("ADD_PIECE", { projectId = 3, piece = { itemID = 999 } }) end
check("ADD_PIECE caps at MAX_PIECES", #prj.pieces == VWB.Constants.Projects.MAX_PIECES)
while #prj.pieces > 2 do dispatch("REMOVE_PIECE", { projectId = 3, index = #prj.pieces }) end

-- 5. SET_PROJECT_STATUS maintains the done<->completedAt invariant ------------
dispatch("SET_PROJECT_STATUS", { id = 3, status = "backlog" })
check("STATUS: to backlog", prj.status == "backlog" and prj.completedAt == nil)
dispatch("SET_PROJECT_STATUS", { id = 3, status = "done", _time = 7000 })
check("STATUS: to done stamps completedAt", prj.status == "done" and prj.completedAt == 7000)
dispatch("SET_PROJECT_STATUS", { id = 3, status = "bench" })
check("STATUS: leaving done clears completedAt", prj.status == "bench" and prj.completedAt == nil)

-- 6. Piece-level actions route by pieceIndex ----------------------------------
dispatch("SET_PIECE_PAR", { id = 3, pieceIndex = 2, par = 99 })
check("SET_PIECE_PAR", prj.pieces[2].par == 99 and prj.pieces[1].par ~= 99)
dispatch("PIN_PROJECT_STEP", { id = 3, pieceIndex = 1, stepKey = "craft:recipe:601", charKey = "Aly-Realm" })
check("PIN routes to the piece", prj.pieces[1].pins["craft:recipe:601"] == "Aly-Realm")
dispatch("UNPIN_PROJECT_STEP", { id = 3, pieceIndex = 1, stepKey = "craft:recipe:601" })
check("UNPIN routes to the piece", prj.pieces[1].pins["craft:recipe:601"] == nil)
dispatch("COMPLETE_PIECE", { projectId = 3, pieceIndex = 1, _time = 8000 })
check("COMPLETE_PIECE stamps the piece", prj.pieces[1].completedAt == 8000 and prj.completedAt == nil)
dispatch("PROJECT_REFILLED", { id = 3, pieceIndex = 2 })
dispatch("PROJECT_REFILLED", { id = 3, pieceIndex = 2 })
check("REFILLED per piece", prj.pieces[2].refills == 2 and prj.pieces[1].refills == 0)

-- 7. COMPLETE_PROJECT stamps both invariant halves ----------------------------
dispatch("COMPLETE_PROJECT", { id = 3, _time = 9000 })
check("COMPLETE_PROJECT: done + timestamp", prj.status == "done" and prj.completedAt == 9000)

-- 8. projects slice signal fires on the new actions ---------------------------
local projVer = 0
R.effect(function() Store:Version("projects"); projVer = projVer + 1 end)
local before = projVer
dispatch("SET_PROJECT_STATUS", { id = 3, status = "bench" })
dispatch("ADD_PIECE", { projectId = 3, piece = { itemID = 304 } })
dispatch("COMPLETE_PIECE", { projectId = 3, pieceIndex = 3 })
check("slice signal: 3 piece-level actions bump 3x", projVer == before + 3)

-- 9. Alias contract: nested piece mutations write through to VWB_DB ----------
_G.VWB_DB = nil
Store:LoadFromSavedVariables() -- fresh VWB_DB (v seeded, migration no-ops)
check("fresh DB seeds v2", _G.VWB_DB.projects.v == 2)
local dbRef = _G.VWB_DB.projects
dispatch("ADD_PROJECT", { name = "Alias Test", pieces = { { itemID = 600 } } })
local aliasPrj = dbRef.items[#dbRef.items]
check("alias: project written through", aliasPrj.name == "Alias Test")
dispatch("COMPLETE_PIECE", { projectId = aliasPrj.id, pieceIndex = 1, _time = 4242 })
check("alias: nested piece mutation written through", aliasPrj.pieces[1].completedAt == 4242)

print(string.format("Store projects: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
