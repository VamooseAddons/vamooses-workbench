-- Headless tests for the Achieve model over a mock ProfAchievements surface.
-- Proves: rows appear as latches land, nav counts follow filters (never the
-- nav pick), hideEarned/search scope, tally is filter-independent, and a
-- progress re-latch flows through reactively.

local base = arg[0]:gsub("tests/achieve_model_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
local ns = { Reactor = R }
VWB = ns
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", ns)
loadfile(base .. "Achieve/Achieve_Model.lua")("VWB", ns)

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

local store = R.latchMap("testAchieves")
local ids = {}
local cats = { { id = 100, name = "Alchemy" }, { id = 200, name = "Cooking" } }
local filters = {
    search = R.signal(""), navKey = R.signal(nil),
    hideEarned = R.signal(false), collapsed = R.signal({}),
}
local model = ns.Achieve.buildModel({
    source = {
        peek = function(id) return store:peek(id) end, epoch = store.epoch,
        ids = function() return ids end, categories = function() return cats end,
    },
    filters = filters,
})

local function mk(id, catID, name, completed, progressText, critDone, critTotal)
    return { id = id, categoryID = catID, name = name, description = name .. " desc",
        points = 5, completed = completed, progressText = progressText,
        critDone = critDone or 0, critTotal = critTotal or 0, criteria = {} }
end

-- 1. Rows appear as latches land (walk order preserved) -----------------------
do
    check("empty before latches", #model.rows() == 0)
    ids = { 1, 2, 3 }
    store:latch(1, mk(1, 100, "A Cure for All Ails", false, "450/1000"))
    store:latch(2, mk(2, 100, "Draconic Phial Cabinet", true, "01/02/24", 8, 8))
    store:latch(3, mk(3, 200, "Iron Chef", false, "2/5", 2, 5))
    check("latched rows appear in walk order", #model.rows() == 3 and model.rows()[1].id == 1)
end

-- 2. Nav pick narrows rows, never the sections --------------------------------
do
    filters.navKey("100")
    check("category pick narrows", #model.rows() == 2)
    check("sections ignore the pick", model.sections()[1].itemCount == 3)
    filters.navKey("*")
    check("All key shows everything", #model.rows() == 3)
    filters.navKey(nil)
end

-- 3. Sections: one Professions section, All first, live category labels -------
do
    local sec = model.sections()[1]
    check("single section", sec.key == "professions" and #model.sections() == 1)
    check("All leads", sec.items[1].key == "*" and sec.items[1].count == 3)
    check("categories with counts", sec.items[2].label == "Alchemy" and sec.items[2].count == 2
        and sec.items[3].label == "Cooking" and sec.items[3].count == 1)
end

-- 4. hideEarned + search scope rows AND section counts ------------------------
do
    filters.hideEarned(true)
    check("hideEarned drops completed", #model.rows() == 2)
    check("section counts follow", model.sections()[1].items[2].count == 1)
    filters.hideEarned(false)
    filters.search("phial")
    check("search matches name", #model.rows() == 1 and model.rows()[1].id == 2)
    filters.search("iron chef desc")
    check("search matches description", #model.rows() == 1 and model.rows()[1].id == 3)
    filters.search("")
end

-- 5. Tally is filter-independent ----------------------------------------------
do
    filters.hideEarned(true)
    local t = model.tally()
    check("tally sees the full corpus", t.total == 3 and t.earned == 1)
    filters.hideEarned(false)
end

-- 6. A progress re-latch flows reactively under an observing effect -----------
do
    local seen
    R.effect(function()
        seen = nil
        for _, rec in ipairs(model.rows()) do if rec.id == 1 then seen = rec.progressText end end
    end, "test:progressWatch")
    check("initial progress", seen == "450/1000")
    store:latch(1, mk(1, 100, "A Cure for All Ails", false, "451/1000"))
    check("re-latch propagates", seen == "451/1000")
end

print(string.format("Achieve model: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
