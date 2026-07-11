-- Headless tests for the Study model + RecipeSources.Parse. Proves the
-- acquisition browser's reactive contract: rows appear as source latches
-- land, drop out when recipes are learned, and the kind->zone nav sections
-- count the filtered universe (never the nav pick itself).

local base = arg[0]:gsub("tests/study_model_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
local ns = { Reactor = R }
VWB = ns -- RecipeSources reads the global; VWB_Namespace unifies these in-game
VWB_DB = {}
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", ns)
loadfile(base .. "Modules/RecipeSources.lua")("VWB", ns)
loadfile(base .. "Study/Study_Model.lua")("VWB", ns)

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. Parse: labeled lines, zone extraction, color stripping ------------------
do
    local p = ns.RecipeSources.Parse("|cffffd200Drop:|r Heavy Trunk\n|cffffd200Zone:|r Delves")
    check("parse kind from first label", p.kindLabel == "Drop")
    check("parse detail stripped of codes", p.detail == "Heavy Trunk")
    check("parse zone line", p.zone == "Delves")
    check("parse keeps raw lines", #p.lines == 2 and p.lines[1]:find("|cffffd200", 1, true) == 1)

    local v = ns.RecipeSources.Parse("Vendor: Provisioner Mukra")
    check("parse vendor no zone", v.kindLabel == "Vendor" and v.detail == "Provisioner Mukra" and v.zone == nil)

    local o = ns.RecipeSources.Parse("Discovered via experimentation")
    check("parse unlabeled first line -> Other", o.kindLabel == "Other" and o.detail == "Discovered via experimentation")
end

-- Shared model fixture --------------------------------------------------------
local recipes = {
    { recipeID = 1, itemID = 11, name = "Copper Rod",   profession = "Enchanting",  expansion = "Classic" },
    { recipeID = 2, itemID = 12, name = "Amani Enchant", profession = "Enchanting", expansion = "Midnight" },
    { recipeID = 3, itemID = 13, name = "Bear Steak",   profession = "Cooking",     expansion = "Midnight" },
    { recipeID = 4, name = "Zebra Enchant", profession = "Enchanting", expansion = "Midnight" }, -- no itemID (enchant)
}
local src = R.latchMap("testSources")
local knownSet = { [1] = true } -- recipe 1 already learned
local knownV = R.signal(0)
local filters = {
    search = R.signal(""), profession = R.signal("all"),
    navKey = R.signal(nil), collapsed = R.signal({}),
}
local model = ns.Study.buildModel({
    universe = function() return recipes end,
    source = { peek = function(id) return src:peek(id) end, epoch = src.epoch },
    known = { version = function() return knownV() end, isKnown = function(id) return knownSet[id] == true end },
    filters = filters,
})

-- 2. Rows appear only once their source latch lands ---------------------------
do
    check("no latches -> no rows", #model.rows() == 0)
    src:latch(2, ns.RecipeSources.Parse("Vendor: Mukra\nZone: Thunder Bluff"))
    src:latch(3, ns.RecipeSources.Parse("Drop: Heavy Trunk"))
    check("latched unlearned rows appear", #model.rows() == 2)
    check("known recipe excluded even if latched", (function()
        src:latch(1, ns.RecipeSources.Parse("Trainer: Anybody"))
        return #model.rows() == 2
    end)())
    src:latch(4, ns.RecipeSources.Parse("Vendor: Kelsey\nZone: Silvermoon"))
    check("late latch lands reactively", #model.rows() == 3)
end

-- 3. Nav sections: kind -> zone counts, All item first, sorted by count ------
do
    local secs = model.sections()
    check("two kinds", #secs == 2)
    check("busiest kind first", secs[1].key == "Vendor" and secs[1].itemCount == 2)
    check("All item leads with ::* key", secs[1].items[1].key == "Vendor::*" and secs[1].items[1].count == 2)
    check("zones alphabetical after All", secs[1].items[2].label == "Silvermoon" and secs[1].items[3].label == "Thunder Bluff")
    check("no-zone bucket", secs[2].items[2].label == ns.Study.NO_ZONE)
end

-- 4. Nav pick narrows rows but never the sections -----------------------------
do
    filters.navKey("Vendor::*")
    check("kind pick narrows rows", #model.rows() == 2)
    filters.navKey("Vendor::Thunder Bluff")
    check("zone pick narrows to one", #model.rows() == 1 and model.rows()[1].item.recipeID == 2)
    check("sections ignore the nav pick", #model.sections() == 2)
    filters.navKey(nil)
end

-- 5. Search + profession filters scope rows AND sections ----------------------
do
    filters.profession("Cooking")
    check("profession filter", #model.rows() == 1 and model.rows()[1].item.recipeID == 3)
    check("sections follow profession filter", #model.sections() == 1 and model.sections()[1].key == "Drop")
    filters.profession("all")
    filters.search("zebra")
    check("search filter", #model.rows() == 1 and model.rows()[1].item.recipeID == 4)
    filters.search("")
end

-- 6. Learning a recipe drops it on the version bump. The reactive edge is
-- known.version(), NOT the plain isKnown cache -- proven under an observing
-- effect (unobserved computeds re-evaluate lazily, so bare reads can't
-- distinguish the two).
do
    local seen
    R.effect(function() seen = #model.rows() end, "test:rowsWatch")
    check("effect observes 3 rows", seen == 3)
    knownSet[2] = true
    check("plain cache mutation alone does not propagate", seen == 3)
    knownV(knownV() + 1)
    check("version bump drops the learned recipe", seen == 2)
end

-- 7. Collapse state flows into sections ----------------------------------------
do
    check("expanded by default", model.sections()[1].collapsed == false)
    filters.collapsed({ [model.sections()[1].key] = true })
    check("collapsed flag propagates", model.sections()[1].collapsed == true)
end

-- 8. Rows sort by name; export index untouched by model ------------------------
do
    local rows = model.rows()
    check("name sort", rows[1].item.name <= rows[2].item.name)
end

print(string.format("Study model: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
