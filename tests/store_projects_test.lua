-- Headless tests for the projects slice: all 7 reducers, nextId monotonicity,
-- alias persistence (in-place mutations survive reload via VWB_DB reference).
-- Run: lua store_projects_test.lua

local base = arg[0]:gsub("tests/store_projects_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
_G.time = os.time
_G.VWB = { Reactor = R, Database = { InvalidateIndexes = function() end } }
dofile(base .. "Core/VWB_Store.lua")
local Store = _G.VWB.Store

local pass, fail = 0, 0
local function check(n, c) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. n) end end

local st = Store:GetState()

-- Helper: dispatch with a pinned timestamp so tests are deterministic ---------
local function dispatch(action, payload)
    payload = payload or {}
    payload._time = payload._time or 1000 -- frozen time for tests
    Store:Dispatch(action, payload)
end

-- 1. ADD_PROJECT inserts a record with correct defaults ----------------------
dispatch("ADD_PROJECT", { name = "Enchanted Cauldron", itemID = 101, kind = "collect" })
check("ADD_PROJECT: items has 1 entry", #st.projects.items == 1)
local p1 = st.projects.items[1]
check("ADD_PROJECT: id = 1", p1.id == 1)
check("ADD_PROJECT: nextId advanced to 2", st.projects.nextId == 2)
check("ADD_PROJECT: name stored", p1.name == "Enchanted Cauldron")
check("ADD_PROJECT: itemID stored", p1.itemID == 101)
check("ADD_PROJECT: kind stored", p1.kind == "collect")
check("ADD_PROJECT: par defaults to 20", p1.par == 20)
check("ADD_PROJECT: pins starts empty", type(p1.pins) == "table" and next(p1.pins) == nil)
check("ADD_PROJECT: createdAt stamped", p1.createdAt == 1000)
check("ADD_PROJECT: completedAt nil", p1.completedAt == nil)
check("ADD_PROJECT: refills starts 0", p1.refills == 0)

-- 2. ADD_PROJECT second item; nextId monotonically increases -----------------
dispatch("ADD_PROJECT", { name = "Raid Flask", itemID = 202, kind = "stock", par = 40, _time = 2000 })
check("ADD_PROJECT: 2 items", #st.projects.items == 2)
local p2 = st.projects.items[2]
check("ADD_PROJECT: second id = 2", p2.id == 2)
check("ADD_PROJECT: nextId = 3", st.projects.nextId == 3)
check("ADD_PROJECT: stock kind", p2.kind == "stock")
check("ADD_PROJECT: custom par", p2.par == 40)
check("ADD_PROJECT: createdAt from timestamp", p2.createdAt == 2000)

-- 3. nextId monotonicity: ids never repeat even after removes ----------------
dispatch("ADD_PROJECT", { name = "Third", itemID = 303 })
dispatch("REMOVE_PROJECT", { id = 3 })
dispatch("ADD_PROJECT", { name = "Fourth", itemID = 404 })
local last = st.projects.items[#st.projects.items]
check("nextId monotonic: fourth project gets id=4, not 3", last.id == 4)

-- 4. REMOVE_PROJECT deletes by id without leaving a hole --------------------
-- At this point: items have id 1, 2, 4 (3 was removed above)
check("before remove: 3 items", #st.projects.items == 3)
dispatch("REMOVE_PROJECT", { id = 2 })
check("REMOVE_PROJECT: count drops to 2", #st.projects.items == 2)
-- remaining ids should be 1 and 4 (2 gone)
local ids = {}
for _, p in ipairs(st.projects.items) do ids[p.id] = true end
check("REMOVE_PROJECT: id 1 remains", ids[1])
check("REMOVE_PROJECT: id 4 remains", ids[4])
check("REMOVE_PROJECT: id 2 gone", ids[2] == nil)

-- 5. REMOVE_PROJECT on unknown id is a safe no-op ----------------------------
local countBefore = #st.projects.items
dispatch("REMOVE_PROJECT", { id = 9999 })
check("REMOVE_PROJECT: unknown id no-op", #st.projects.items == countBefore)

-- 6. SET_PROJECT_PAR changes par on matching id ------------------------------
dispatch("SET_PROJECT_PAR", { id = 1, par = 99 })
check("SET_PROJECT_PAR: par updated", st.projects.items[1].par == 99)

-- 7. PIN_PROJECT_STEP persists step->char mapping ----------------------------
dispatch("PIN_PROJECT_STEP", { id = 1, stepKey = "craft:recipe:500", charKey = "Aly-Realm" })
check("PIN_PROJECT_STEP: pin stored", p1.pins["craft:recipe:500"] == "Aly-Realm")

-- 8. UNPIN_PROJECT_STEP removes the mapping ----------------------------------
dispatch("UNPIN_PROJECT_STEP", { id = 1, stepKey = "craft:recipe:500" })
check("UNPIN_PROJECT_STEP: pin gone", p1.pins["craft:recipe:500"] == nil)

-- 9. COMPLETE_PROJECT stamps completedAt; only once needed -------------------
dispatch("COMPLETE_PROJECT", { id = 1, _time = 5000 })
check("COMPLETE_PROJECT: completedAt set", p1.completedAt == 5000)
check("COMPLETE_PROJECT: kind unchanged", p1.kind == "collect")

-- 10. PROJECT_REFILLED increments refills counter ----------------------------
-- Use id=4 (the stock-like project still alive)
local p4 = nil
for _, p in ipairs(st.projects.items) do if p.id == 4 then p4 = p end end
check("REFILLED: project 4 exists", p4 ~= nil)
check("REFILLED: starts at 0", p4.refills == 0)
dispatch("PROJECT_REFILLED", { id = 4 })
check("PROJECT_REFILLED: refills = 1", p4.refills == 1)
dispatch("PROJECT_REFILLED", { id = 4 })
check("PROJECT_REFILLED: refills = 2", p4.refills == 2)

-- 11. projects slice signal fires on every project action --------------------
local projVer = 0
R.effect(function() Store:Version("projects"); projVer = projVer + 1 end)
local pB = projVer
dispatch("ADD_PROJECT", { name = "Signal Test", itemID = 505 })
check("projects signal: ADD bumps", projVer == pB + 1)
local pB2 = projVer
dispatch("REMOVE_PROJECT", { id = st.projects.items[#st.projects.items].id })
check("projects signal: REMOVE bumps", projVer == pB2 + 1)

-- 12. alias contract: mutations write through to VWB_DB reference -----------
_G.VWB_DB = nil
Store:LoadFromSavedVariables() -- fresh VWB_DB
local dbRef = _G.VWB_DB.projects
dispatch("ADD_PROJECT", { name = "Alias Test", itemID = 600 })
check("alias: item written to VWB_DB.projects.items", #dbRef.items >= 1)
local lastItem = dbRef.items[#dbRef.items]
check("alias: correct item in VWB_DB", lastItem.name == "Alias Test")
check("alias: nextId in VWB_DB advanced", dbRef.nextId > 1)

print(string.format("Store projects: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
