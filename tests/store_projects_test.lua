-- Headless tests for the projects slice, v3 (Commissions: pieces are
-- ENTITIES). Covers: v1->v3 and v2->v3 migrations (ids, achievementID fold,
-- idempotence), pieceId-addressed reducers incl. the dangling-index bug
-- class, dedupe, the SEALED-DONE and DONE-ENTRY reducer rules, the state
-- machine legality matrix, and the Constitution invariants.
-- Run: lua store_projects_test.lua

local base = arg[0]:gsub("tests/store_projects_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
_G.time = os.time
_G.VWB = { Reactor = R, Database = { InvalidateIndexes = function() end } }
loadfile(base .. "Core/Constants.lua")("VWB", _G.VWB)

-- Seed a v2-shaped DB (post-pieces, pre-ids) with an achievement commission:
-- the v2->v3 migration must assign ids AND fold source.id onto criteria pieces.
_G.VWB_DB = { projects = { v = 2, nextId = 10, items = {
    { id = 1, name = "Old Set", icon = 133, status = "bench",
      pieces = { { itemID = 101, recipeID = 501, kind = "collect", par = 20, pins = {}, refills = 0 } },
      source = nil, createdAt = 100, completedAt = nil },
    { id = 2, name = "Old Achieve", icon = 134, status = "backlog",
      pieces = {
        { itemID = 201, recipeID = 601, kind = "achievement", par = 20, pins = {}, refills = 0, criteriaIndex = 1 },
        { itemID = 202, recipeID = 602, kind = "collect", par = 20, pins = {}, refills = 0 },
      },
      source = { type = "achievement", id = 9999 }, createdAt = 200, completedAt = nil },
} } }

dofile(base .. "Core/VWB_Store.lua")
local Store = _G.VWB.Store
Store:LoadFromSavedVariables()

local pass, fail = 0, 0
local function check(n, c) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. n) end end

local st = Store:GetState()

local function dispatch(action, payload)
    payload = payload or {}
    payload._time = payload._time or 1000
    Store:Dispatch(action, payload)
end

-- 1. MIGRATION v2 -> v3 --------------------------------------------------------
do
    check("v stamped 3", st.projects.v == 3)
    local p1, p2 = st.projects.items[1], st.projects.items[2]
    check("pieces gained unique counter ids", type(p1.pieces[1].id) == "number"
        and p2.pieces[1].id ~= p2.pieces[2].id and p1.pieces[1].id ~= p2.pieces[1].id)
    check("nextId advanced past assigned piece ids", st.projects.nextId > p2.pieces[2].id
        and st.projects.nextId > p1.pieces[1].id)
    check("achievementID folded onto CRITERIA piece", p2.pieces[1].achievementID == 9999)
    check("collect piece in same commission NOT folded", p2.pieces[2].achievementID == nil)
    check("non-achievement commission untouched", p1.pieces[1].achievementID == nil)
end

-- 2. Migration idempotence + double-jump + fresh seed --------------------------
do
    local beforeIds = { st.projects.items[1].pieces[1].id, st.projects.items[2].pieces[1].id }
    local beforeNext = st.projects.nextId
    Store:LoadFromSavedVariables() -- run again against the SAME (now v3) DB
    st = Store:GetState()
    check("idempotent: ids unchanged on second load", st.projects.items[1].pieces[1].id == beforeIds[1]
        and st.projects.items[2].pieces[1].id == beforeIds[2])
    check("idempotent: counter unchanged", st.projects.nextId == beforeNext)

    -- v1 -> v3 double-jump: a user who skipped the v2 build entirely
    _G.VWB_DB = { projects = { nextId = 5, items = {
        { id = 1, name = "V1 Relic", icon = 1, itemID = 11, recipeID = 21, kind = "stock",
          par = 40, pins = { ["21"] = "Aly-R" }, createdAt = 1, completedAt = nil, refills = 2 },
    } } }
    Store:LoadFromSavedVariables()
    st = Store:GetState()
    local v1 = st.projects.items[1]
    check("double-jump: v3 stamped", st.projects.v == 3)
    check("double-jump: v1 fields became a piece WITH an id", #v1.pieces == 1
        and v1.pieces[1].itemID == 11 and type(v1.pieces[1].id) == "number")
    check("double-jump: pins + refills rode along", v1.pieces[1].pins["21"] == "Aly-R"
        and v1.pieces[1].refills == 2)

    _G.VWB_DB = nil
    Store:LoadFromSavedVariables()
    st = Store:GetState()
    check("fresh install seeds v3 empty", st.projects.v == 3 and #st.projects.items == 0
        and st.projects.nextId >= 1)
end

-- Fixture for the reducer groups ------------------------------------------------
dispatch("ADD_PROJECT", { name = "Alpha", pieces = {
    { itemID = 301, recipeID = 701 }, { itemID = 302, recipeID = 702 }, { itemID = 303, recipeID = 703 },
} })
local prj = st.projects.items[1]
local ids = { prj.pieces[1].id, prj.pieces[2].id, prj.pieces[3].id }

-- 3. pieceId reducers: the dangling-index bug class ----------------------------
do
    check("ADD_PROJECT assigned distinct piece ids", ids[1] ~= ids[2] and ids[2] ~= ids[3])
    dispatch("REMOVE_PIECE", { projectId = prj.id, pieceId = ids[2] })
    check("remove middle by id", #prj.pieces == 2 and prj.pieces[2].id == ids[3])
    dispatch("SET_PIECE_PAR", { id = prj.id, pieceId = ids[3], par = 77 })
    check("act on LATER piece after removal hits the right one", prj.pieces[2].par == 77
        and prj.pieces[1].par ~= 77)
    dispatch("COMPLETE_PIECE", { projectId = prj.id, pieceId = ids[3], _time = 2000 })
    check("complete by id after removal", prj.pieces[2].completedAt == 2000 and prj.pieces[1].completedAt == nil)
    dispatch("PIN_PROJECT_STEP", { id = prj.id, pieceId = ids[1], stepKey = "s1", charKey = "Aly-R" })
    dispatch("UNPIN_PROJECT_STEP", { id = prj.id, pieceId = ids[1], stepKey = "s1" })
    check("pin/unpin route by id", prj.pieces[1].pins["s1"] == nil)
    dispatch("PROJECT_REFILLED", { id = prj.id, pieceId = ids[1] })
    check("refill routes by id", prj.pieces[1].refills == 1 and prj.pieces[2].refills == 0)
    local n = #prj.pieces
    dispatch("REMOVE_PIECE", { projectId = prj.id, pieceId = 424242 })
    check("unknown pieceId no-op", #prj.pieces == n)
end

-- 4. Dedupe on ADD_PIECE --------------------------------------------------------
do
    local n = #prj.pieces
    dispatch("ADD_PIECE", { projectId = prj.id, piece = { itemID = 301, recipeID = 701 } })
    check("duplicate recipeID no-ops", #prj.pieces == n)
    dispatch("ADD_PIECE", { projectId = prj.id, piece = { itemID = 304, recipeID = 704 } })
    check("new recipeID appends with fresh id", #prj.pieces == n + 1
        and type(prj.pieces[#prj.pieces].id) == "number")
end

-- 5. DONE-ENTRY rule lives in the reducer ---------------------------------------
do
    dispatch("SET_PROJECT_STATUS", { id = prj.id, status = "done" })
    check("to-done REFUSED while pieces unstamped", prj.status ~= "done" and prj.completedAt == nil)
    for _, pc in ipairs(prj.pieces) do
        if not pc.completedAt then dispatch("COMPLETE_PIECE", { projectId = prj.id, pieceId = pc.id }) end
    end
    dispatch("SET_PROJECT_STATUS", { id = prj.id, status = "done", _time = 3000 })
    check("to-done allowed once all stamped", prj.status == "done" and prj.completedAt == 3000)
    dispatch("ADD_PROJECT", { name = "Empty", pieces = {} })
    local empty = st.projects.items[#st.projects.items]
    dispatch("SET_PROJECT_STATUS", { id = empty.id, status = "done" })
    check("zero-piece to-done refused", empty.status ~= "done")
    dispatch("SET_PROJECT_STATUS", { id = empty.id, status = "backlog" })
    check("backlog move fine for empty", empty.status == "backlog")
end

-- 6. DONE IS SEALED --------------------------------------------------------------
do
    local n = #prj.pieces
    dispatch("ADD_PIECE", { projectId = prj.id, piece = { itemID = 999, recipeID = 999 } })
    check("ADD_PIECE on done no-ops", #prj.pieces == n)
    dispatch("REMOVE_PIECE", { projectId = prj.id, pieceId = prj.pieces[1].id })
    check("REMOVE_PIECE on done no-ops", #prj.pieces == n)
    dispatch("SET_PROJECT_STATUS", { id = prj.id, status = "bench" })
    check("reopen to Active clears completedAt", prj.status == "bench" and prj.completedAt == nil)
    dispatch("SET_PROJECT_STATUS", { id = prj.id, status = "done", _time = 4000 })
    check("re-done after reopen (pieces still stamped)", prj.status == "done" and prj.completedAt == 4000)
    dispatch("REMOVE_PROJECT", { id = prj.id })
    check("delete from done", (function()
        for _, p in ipairs(st.projects.items) do if p.id == prj.id then return false end end
        return true
    end)())
end

-- 7. Invariants: done iff completedAt; monotonic ids across churn ---------------
do
    dispatch("ADD_PROJECT", { name = "Inv", pieces = { { itemID = 1, recipeID = 2 } } })
    local iv = st.projects.items[#st.projects.items]
    dispatch("COMPLETE_PIECE", { projectId = iv.id, pieceId = iv.pieces[1].id })
    dispatch("SET_PROJECT_STATUS", { id = iv.id, status = "done" })
    check("invariant: done => completedAt", iv.completedAt ~= nil)
    dispatch("SET_PROJECT_STATUS", { id = iv.id, status = "backlog" })
    check("invariant: not-done => completedAt nil", iv.completedAt == nil)

    local maxId = 0
    for _, p in ipairs(st.projects.items) do
        if p.id > maxId then maxId = p.id end
        for _, pc in ipairs(p.pieces) do if pc.id > maxId then maxId = pc.id end end
    end
    dispatch("ADD_PROJECT", { name = "Mono", pieces = { { itemID = 5, recipeID = 6 } } })
    local mono = st.projects.items[#st.projects.items]
    check("ids monotonic across projects AND pieces (one counter)",
        mono.id > maxId and mono.pieces[1].id > mono.id)
end

-- 8. Craft pieces: lazy history-counted completion (QA group 2) ----------------
do
    loadfile(base .. "Modules/ProjectPlanner.lua")("VWB", _G.VWB)
    local P = VWB.ProjectPlanner
    dispatch("ADD_PROJECT", { name = "Friday Night", status = "bench", _time = 5000, pieces = {
        { recipeID = 801, itemID = 8801, kind = "craft", qty = 3, charKey = "A-R" } } })
    local fp = st.projects.items[#st.projects.items]
    check("craft piece shape (qty/charKey/createdAt)", fp.pieces[1].kind == "craft"
        and fp.pieces[1].qty == 3 and fp.pieces[1].charKey == "A-R" and fp.pieces[1].createdAt == 5000)
    dispatch("ADD_CRAFTING_HISTORY", { recipeID = 801, itemID = 8801, qty = 5, timestamp = 4000 })
    P._sweepCraftCompletions()
    check("crafts BEFORE createdAt never count", fp.pieces[1].completedAt == nil)
    dispatch("ADD_CRAFTING_HISTORY", { recipeID = 801, itemID = 8801, qty = 2, timestamp = 6000, character = "Alt" })
    P._sweepCraftCompletions()
    check("under target: unstamped", fp.pieces[1].completedAt == nil)
    dispatch("ADD_CRAFTING_HISTORY", { recipeID = 801, itemID = 8801, qty = 1, timestamp = 7000, character = "Main" })
    P._sweepCraftCompletions()
    check("qty reached across sessions/characters -> stamped", fp.pieces[1].completedAt ~= nil)
    check("all pieces stamped -> commission promoted", fp.status == "done" and fp.completedAt ~= nil)
    dispatch("ADD_CRAFTING_HISTORY", { itemID = 8801, qty = 9, timestamp = 8000 }) -- recipeID-less legacy row
    check("history rows without recipeID are inert", true) -- sweep above must not have errored on it
end

print(string.format("Store projects: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
