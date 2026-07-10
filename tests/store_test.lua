-- Headless test for the signals-backed VWB.Store shim: the 3 reducers mirror
-- VPC's contract (upsert recipes, union known, save-char-preserve-known), the
-- version signal drives a Reactor computed, and state aliases VWB_DB so writes
-- persist. Run: lua store_test.lua
local base = arg[0]:gsub("tests/store_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
_G.time = os.time
_G.VWB = { Reactor = R, Database = { InvalidateIndexes = function() end } }
dofile(base .. "Core/VWB_Store.lua")
local Store = _G.VWB.Store

local pass, fail = 0, 0
local function check(n, c) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. n) end end
local st = Store:GetState()

-- 1. ADD_RECIPES upserts records --------------------------------------------
Store:Dispatch("ADD_RECIPES", { records = { [10] = { itemID = 1, name = "A" }, [11] = { itemID = 2, name = "B" } } })
check("ADD_RECIPES adds 2", st.recipeStore[10] ~= nil and st.recipeStore[11] ~= nil and st.recipeStore[12] == nil)
Store:Dispatch("ADD_RECIPES", { records = { [12] = { itemID = 3, name = "C" } } })
check("ADD_RECIPES adds a 3rd (upsert)", st.recipeStore[12].name == "C")

-- 2. version signal drives a computed ---------------------------------------
local ver = 0
R.effect(function() Store:Version(); ver = ver + 1 end) -- runs once now
local before = ver
Store:Dispatch("ADD_RECIPES", { records = { [13] = { itemID = 4 } } })
check("version bump re-ran the effect", ver == before + 1)

-- 3. SET_KNOWN_RECIPES unions account-wide + per-char -----------------------
Store:Dispatch("SET_KNOWN_RECIPES", { recipes = { [10] = true, [11] = true }, charKey = "Aly-Realm" })
check("known union account-wide", st.knownRecipes[10] and st.knownRecipes[11])
check("known set on the character", st.account.characters["Aly-Realm"].knownRecipes[10])
Store:Dispatch("SET_KNOWN_RECIPES", { recipes = { [12] = true }, charKey = "Aly-Realm" })
check("second scan MERGES (keeps prior)", st.account.characters["Aly-Realm"].knownRecipes[10] and st.account.characters["Aly-Realm"].knownRecipes[12])

-- 3b. corpus signal isolates DEFINITION changes from known-status ------------
-- Stockroom classification / Showroom universe / Records coverage subscribe
-- corpus so a known-status scan doesn't re-walk them. Enforce the contract.
local corpusVer, recipesVer = 0, 0
R.effect(function() Store:Version("corpus"); corpusVer = corpusVer + 1 end)
R.effect(function() Store:Version("recipes"); recipesVer = recipesVer + 1 end)
local cB, rB = corpusVer, recipesVer
Store:Dispatch("SET_KNOWN_RECIPES", { recipes = { [13] = true }, charKey = "Aly-Realm" })
check("SET_KNOWN_RECIPES bumps recipes, NOT corpus", recipesVer == rB + 1 and corpusVer == cB)
local cB2, rB2 = corpusVer, recipesVer
Store:Dispatch("ADD_RECIPES", { records = { [14] = { itemID = 5 } } })
check("ADD_RECIPES bumps BOTH corpus and recipes", corpusVer == cB2 + 1 and recipesVer == rB2 + 1)

-- 3c. coverage slice isolates SCAN-STATUS from definitions. A craft re-harvest
-- writes a fresh lastScan with zero new recipes; it must go to `coverage`, NOT
-- `corpus`, or Stockroom classification + Showroom universe re-walk for nothing.
local coverageVer = 0
R.effect(function() Store:Version("coverage"); coverageVer = coverageVer + 1 end)
local cvB, cpB = coverageVer, corpusVer
Store:Dispatch("UPDATE_COVERAGE", { coverage = { ["Alchemy::Midnight"] = { count = 3, lastScan = 1 } } })
check("UPDATE_COVERAGE bumps coverage, NOT corpus", coverageVer == cvB + 1 and corpusVer == cpB)
check("UPDATE_COVERAGE writes recipeCoverage", st.recipeCoverage["Alchemy::Midnight"].count == 3)
local cvB2, cpB2 = coverageVer, corpusVer
Store:Dispatch("ADD_RECIPES", { records = { [15] = { itemID = 6 } } })
check("ADD_RECIPES (records only) bumps corpus, NOT coverage", corpusVer == cpB2 + 1 and coverageVer == cvB2)

-- 4. SAVE_CHARACTER_PROFESSIONS replaces char but preserves knownRecipes -----
Store:Dispatch("SAVE_CHARACTER_PROFESSIONS", { charKey = "Aly-Realm", name = "Aly", professions = { Alchemy = {} } })
check("professions saved", st.account.characters["Aly-Realm"].professions.Alchemy ~= nil)
check("knownRecipes preserved across profession save", st.account.characters["Aly-Realm"].knownRecipes[10])

-- 5. LoadFromSavedVariables aliases VWB_DB (writes persist) ------------------
_G.VWB_DB = { recipeStore = { [99] = { itemID = 9 } } }
Store:LoadFromSavedVariables()
check("hydrates recipeStore from VWB_DB", Store:GetState().recipeStore[99].itemID == 9)
Store:Dispatch("ADD_RECIPES", { records = { [100] = { itemID = 10 } } })
check("mutation writes through to VWB_DB (alias)", _G.VWB_DB.recipeStore[100].itemID == 10)

-- 6. queue/config slices exist for Graph ------------------------------------
check("config.materialsMode defaults raw", Store:GetState().config.materialsMode == "raw")
check("crafting.queuedRecipes is a table", type(Store:GetState().crafting.queuedRecipes) == "table")

-- 7. RegisterReducer: external reducer gets (state, payload) + central bump --
Store:RegisterReducer("TEST_QUEUE", function(st, p)
    st.crafting.queuedRecipes[#st.crafting.queuedRecipes + 1] = p.recipeID
end)
local qver = 0
R.effect(function() Store:Version(); qver = qver + 1 end)
local qbefore = qver
Store:Dispatch("TEST_QUEUE", { recipeID = 42 })
check("registered reducer ran with payload", Store:GetState().crafting.queuedRecipes[1] == 42)
check("every dispatch bumps version (central)", qver == qbefore + 1)

-- 8. crafting queue persists BY REFERENCE (the CLEAR_QUEUE bug): the clear must be
-- in-place, never `= {}`. A replace detaches state.crafting.queuedRecipes from the
-- VWB_DB alias, so the clear and every later add stop persisting and the queue
-- reverts to its pre-clear state on reload. --------------------------------------
Store:RegisterReducer("TEST_QADD", function(st, p) table.insert(st.crafting.queuedRecipes, p.recipeID) end)
Store:RegisterReducer("TEST_QCLEAR_INPLACE", function(st) local q = st.crafting.queuedRecipes; for i = #q, 1, -1 do q[i] = nil end end)
Store:RegisterReducer("TEST_QCLEAR_REPLACE", function(st) st.crafting.queuedRecipes = {} end) -- the BUG shape
local qref = _G.VWB_DB.crafting.queuedRecipes
Store:Dispatch("TEST_QCLEAR_INPLACE")
Store:Dispatch("TEST_QADD", { recipeID = 7 })
check("queue add reaches SavedVars via the alias", qref[1] == 7)
Store:Dispatch("TEST_QCLEAR_INPLACE")
check("in-place clear empties SavedVars AND keeps the alias", #qref == 0 and Store:GetState().crafting.queuedRecipes == qref)
Store:Dispatch("TEST_QADD", { recipeID = 9 })
check("re-add after in-place clear persists", qref[1] == 9)
-- and prove the replace shape is exactly what breaks it:
Store:Dispatch("TEST_QCLEAR_REPLACE")
check("replace-clear DETACHES the alias (why CLEAR_QUEUE must not do it)",
    Store:GetState().crafting.queuedRecipes ~= qref and qref[1] == 9)

-- 9. SET_KNOWN_RECIPES replace-by-profession (the 2026-07-11 pollution fix):
-- a profession-tagged scan is authoritative for that profession on that char --
-- stale entries prune, other professions' entries survive, and an UNTAGGED
-- dispatch (nil profession, e.g. header not loaded) stays merge-only. ---------
Store:Dispatch("ADD_RECIPES", { records = {
    [201] = { itemID = 21, name = "Ink A", profession = "Inscription" },
    [202] = { itemID = 22, name = "Ink B", profession = "Inscription" },
    [301] = { itemID = 31, name = "Flask", profession = "Alchemy" },
} })
Store:Dispatch("SET_KNOWN_RECIPES", { recipes = { [201] = true, [202] = true, [301] = true }, charKey = "Pox-Realm" }) -- simulate pre-fix pollution (untagged union dump)
local pox = st.account.characters["Pox-Realm"]
check("polluted setup: Pox credited with all 3", pox.knownRecipes[201] and pox.knownRecipes[202] and pox.knownRecipes[301])
Store:Dispatch("SET_KNOWN_RECIPES", { recipes = { [201] = true }, charKey = "Pox-Realm", profession = "Inscription" })
check("tagged scan prunes stale same-profession entries", pox.knownRecipes[201] and pox.knownRecipes[202] == nil)
check("tagged scan leaves OTHER professions untouched", pox.knownRecipes[301])
Store:Dispatch("SET_KNOWN_RECIPES", { recipes = { [202] = true }, charKey = "Pox-Realm" }) -- untagged: merge-only
check("untagged dispatch merges without pruning", pox.knownRecipes[201] and pox.knownRecipes[202] and pox.knownRecipes[301])
check("union table unaffected by per-char pruning", st.knownRecipes[201] and st.knownRecipes[202] and st.knownRecipes[301])

-- 10. SAVE_CHARACTER_PROFESSIONS prunes recipes of professions the char lacks --
Store:Dispatch("SAVE_CHARACTER_PROFESSIONS", { charKey = "Pox-Realm", name = "Pox", professions = { Inscription = {} } })
pox = st.account.characters["Pox-Realm"]
check("save prunes recipes of professions the char lacks", pox.knownRecipes[301] == nil)
check("save keeps recipes of professions the char has", pox.knownRecipes[201] and pox.knownRecipes[202])

-- 11. REMOVE_CHARACTER retires the record + clears a matching scope -----------
Store:Dispatch("SET_SCOPE", { charKey = "Pox-Realm" })
Store:Dispatch("REMOVE_CHARACTER", { charKey = "Pox-Realm" })
check("REMOVE_CHARACTER deletes the record", st.account.characters["Pox-Realm"] == nil)
check("REMOVE_CHARACTER clears a matching scope", st.ui.scopeCharacter == nil)
Store:Dispatch("SET_SCOPE", { charKey = "Aly-Realm" })
Store:Dispatch("REMOVE_CHARACTER", { charKey = "Gone-Realm" })
check("REMOVE_CHARACTER leaves an unrelated scope alone", st.ui.scopeCharacter == "Aly-Realm")

print(string.format("Store: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
