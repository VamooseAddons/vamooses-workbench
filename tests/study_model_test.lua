-- Headless tests for the Study model + RecipeSources.Parse (v2: row unit is
-- the SOURCE). Proves the parser's inline sub-field split (the "(no zone)"
-- bug: vendor lines pack Zone/Cost on ONE line), source flattening, ledger
-- continuation flags, and the reactive contract (latch-in, learn-out).

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

-- 1. Parse: INLINE sub-fields (the one-line vendor shape) ---------------------
do
    local p = ns.RecipeSources.Parse(
        "|cffffd200Vendor:|r Aaron Hollman Zone: Shattrath City Cost: 4|TInterface\\MoneyFrame\\UI-GoldIcon:0|t")
    check("one line -> one source", #p.sources == 1)
    local s = p.sources[1]
    check("inline kind", s.kind == "Vendor")
    check("inline detail stops at Zone", s.detail == "Aaron Hollman")
    check("inline zone stops at Cost", s.zone == "Shattrath City")
    check("inline cost keeps money texture", s.cost == "4|TInterface\\MoneyFrame\\UI-GoldIcon:0|t")
end

-- 2. Parse: one source PER LINE (multi-vendor) --------------------------------
do
    local p = ns.RecipeSources.Parse(
        "Vendor: Aaron Hollman Zone: Shattrath City Cost: 4\nVendor: Arras Zone: Azuremyst Isle Cost: 4")
    check("two vendor lines -> two sources", #p.sources == 2)
    check("second source parsed", p.sources[2].detail == "Arras" and p.sources[2].zone == "Azuremyst Isle")
    check("raw lines kept for tooltip", #p.lines == 2)
end

-- 3. Parse: bare Zone/Cost lines attach to the source above (drop shape) -----
do
    local p = ns.RecipeSources.Parse("Drop: Heavy Trunk\nZone: Delves")
    check("drop + zone line -> ONE source", #p.sources == 1)
    check("zone attached to drop", p.sources[1].kind == "Drop" and p.sources[1].zone == "Delves")

    local q = ns.RecipeSources.Parse("Drop: Boss\nZone: Somewhere\nCost: 10")
    check("cost line attaches too", q.sources[1].cost == "10")

    local o = ns.RecipeSources.Parse("Discovered via experimentation")
    check("unlabeled line -> Other", o.sources[1].kind == "Other" and o.sources[1].detail == "Discovered via experimentation")
end

-- Shared model fixture --------------------------------------------------------
local recipes = {
    { recipeID = 1, itemID = 11, name = "Copper Rod",     profession = "Enchanting", expansion = "Classic" },
    { recipeID = 2, itemID = 12, name = "Adamantite Cleaver", profession = "Blacksmithing", expansion = "TBC" },
    { recipeID = 3, itemID = 13, name = "Bear Steak",     profession = "Cooking",    expansion = "Midnight" },
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

-- 4. Flattening: one row per source, recipeCount rides the entries ------------
do
    check("no latches -> no rows", #model.rows() == 0)
    src:latch(2, ns.RecipeSources.Parse(
        "Vendor: Aaron Hollman Zone: Shattrath City Cost: 4\nVendor: Arras Zone: Azuremyst Isle Cost: 4"))
    src:latch(3, ns.RecipeSources.Parse("Drop: Heavy Trunk\nZone: Delves"))
    check("2-source recipe -> 2 rows", #model.rows() == 3)
    check("recipeCount counts recipes not sources", model.entries().recipeCount == 2)
    src:latch(1, ns.RecipeSources.Parse("Trainer: Anybody"))
    check("known recipe excluded even if latched", #model.rows() == 3)
    src:latch(4, { lines = {}, sources = {} }) -- walked, no acquisition data
    check("no-data recipe -> one Unspecified row", #model.rows() == 4)
end

-- 5. Ledger continuation: name paints once per adjacent run -------------------
do
    local rows = model.rows()
    -- name sort: Adamantite Cleaver (x2), Bear Steak, Zebra Enchant
    check("first of run is not continuation", rows[1].continuation == false)
    check("second of run IS continuation", rows[2].item.recipeID == rows[1].item.recipeID and rows[2].continuation == true)
    check("next recipe resets", rows[3].continuation == false)
    check("sources of a run sorted by detail", rows[1].source.detail == "Aaron Hollman" and rows[2].source.detail == "Arras")
end

-- 6. Nav narrowing works at SOURCE level (and re-carries the name) -----------
do
    filters.navKey("Vendor::Azuremyst Isle")
    local rows = model.rows()
    check("zone pick isolates the matching source", #rows == 1 and rows[1].source.detail == "Arras")
    check("isolated source is not a continuation", rows[1].continuation == false)
    filters.navKey("Vendor::*")
    check("kind pick keeps both vendor rows", #model.rows() == 2)
    check("sections ignore the nav pick", #model.sections() == 3)
    filters.navKey(nil)
end

-- 7. Sections: source counts, All first, zones alphabetical, Unspecified last -
do
    local secs = model.sections()
    check("vendor section counts sources", secs[1].key == "Vendor" and secs[1].itemCount == 2)
    check("All item leads with ::* key", secs[1].items[1].key == "Vendor::*" and secs[1].items[1].count == 2)
    check("zones alphabetical after All", secs[1].items[2].label == "Azuremyst Isle" and secs[1].items[3].label == "Shattrath City")
    check("Unspecified pinned last", secs[#secs].key == "Unspecified")
    check("drop zone bucket", (function()
        for _, s in ipairs(secs) do
            if s.key == "Drop" then return s.items[2].label == "Delves" end
        end
    end)())
end

-- 8. Search + profession filters scope rows AND sections ----------------------
do
    filters.profession("Cooking")
    check("profession filter", #model.rows() == 1 and model.rows()[1].item.recipeID == 3)
    check("sections follow profession filter", #model.sections() == 1 and model.sections()[1].key == "Drop")
    filters.profession("all")
    filters.search("zebra")
    check("search filter", #model.rows() == 1 and model.rows()[1].item.recipeID == 4)
    filters.search("")
end

-- 9. Learning a recipe drops ALL its source rows on the version bump. The
-- reactive edge is known.version(), NOT the plain isKnown cache -- proven
-- under an observing effect (unobserved computeds re-evaluate lazily).
do
    local seen
    R.effect(function() seen = #model.rows() end, "test:rowsWatch")
    check("effect observes 4 rows", seen == 4)
    knownSet[2] = true
    check("plain cache mutation alone does not propagate", seen == 4)
    knownV(knownV() + 1)
    check("version bump drops both vendor rows", seen == 2)
end

-- 10. Collapse state flows into sections ---------------------------------------
do
    check("expanded by default", model.sections()[1].collapsed == false)
    filters.collapsed({ [model.sections()[1].key] = true })
    check("collapsed flag propagates", model.sections()[1].collapsed == true)
end

print(string.format("Study model: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
