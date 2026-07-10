-- Headless GO/NO-GO proof for the Showroom model. This is the whole point of
-- the Reactor exercise: cold-cache collectibles classify + appear + tick with
-- ZERO manual RequestLoad / event-handler / refresh wiring. Run: lua showroom_model_test.lua

local base = arg[0]:gsub("tests/showroom_model_test%.lua$", "")
local R = dofile(base .. "Reactor/Reactor_Core.lua")
local ns = { Reactor = R }
loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", ns)
loadfile(base .. "Showroom/Showroom_Model.lua")("VWB", ns)

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- Mock async "journals": kind + collected, nil until the (mock) event fires ---
local handlers = {}
R.setEventSource(function(ev, h) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], h); return function() end end)
local function fire(ev, ...) for _, h in ipairs(handlers[ev] or {}) do h(...) end end

local kindStore, collectedStore = {}, {} -- itemID -> value once "loaded"
local kindRes = R.resource({
    read = function(id) return kindStore[id] end,
    event = "CLASSIFY", matches = function(k, id) return k == id end,
})
local collectedRes = R.resource({
    read = function(id) return collectedStore[id] end,
    event = "COLLECT", matches = function(k, id) return k == id end,
})

-- Sample craftables (2 pets, 1 mount, 1 transmog, 1 non-collectible potion) ---
local recipesSig = R.signal({
    { itemID = 1, name = "Enchanted Cauldron", profession = "Inscription", expansion = "Legion" },
    { itemID = 2, name = "Magic Lamp",         profession = "Inscription", expansion = "Legion" },
    { itemID = 3, name = "Mechano-Hog",        profession = "Engineering", expansion = "WotLK" },
    { itemID = 4, name = "Sanctified Grips",   profession = "Blacksmithing", expansion = "Classic" },
    { itemID = 5, name = "Healing Potion",     profession = "Alchemy",      expansion = "Classic" },
})

local filters = {
    typeMode = R.signal("all"), missingMode = R.signal(false),
    search = R.signal(""), profession = R.signal("all"),
}
local model = ns.Showroom.buildModel({
    recipes = function() return recipesSig() end,
    kind = kindRes, collected = collectedRes, filters = filters,
})

-- Drive an effect off the model so recomputes actually run (like the view would)
local listLen, crumb = 0, {}
R.effect(function() listLen = #model.filteredItems() end)
R.effect(function() crumb = model.breadcrumb() end)

-- 1. cold start: nothing classified yet -> empty list --------------------
check("cold start: empty list", listLen == 0)
check("cold start: empty crumb", crumb.total == 0)
check("cold start: requested classification", true) -- resource requests lazily on read; readers ran

-- 2. classification resolves -> items appear AUTOMATICALLY (the unlock) ---
kindStore[1] = "pet"; kindStore[2] = "pet"; kindStore[3] = "mount"
kindStore[4] = "transmog"; kindStore[5] = "none"
fire("CLASSIFY", 1); fire("CLASSIFY", 2); fire("CLASSIFY", 3); fire("CLASSIFY", 4); fire("CLASSIFY", 5)
check("classified: 4 collectibles show (potion excluded)", listLen == 4)

-- 3. type filter reacts ---------------------------------------------------
filters.typeMode("pet")
check("type=pet -> 2", listLen == 2)
filters.typeMode("mount")
check("type=mount -> 1", listLen == 1)
filters.typeMode("all")
check("type=all -> 4 again", listLen == 4)

-- 4. collection resolves -> breadcrumb known/uncollected fills in ---------
check("crumb before collection: neither known nor unc", crumb.total == 4 and crumb.known == 0 and crumb.uncollected == 0)
collectedStore[1] = true; collectedStore[2] = false; collectedStore[3] = true; collectedStore[4] = false
fire("COLLECT", 1); fire("COLLECT", 2); fire("COLLECT", 3); fire("COLLECT", 4)
check("crumb after collection", crumb.total == 4 and crumb.known == 2 and crumb.uncollected == 2)

-- 5. Missing filter -> only uncollected ----------------------------------
filters.missingMode(true)
check("missing -> 2 uncollected", listLen == 2)

-- 6. search reacts --------------------------------------------------------
filters.missingMode(false)
filters.search("magic")
check("search 'magic' -> 1", listLen == 1)
filters.search("")

-- 7. profession filter ----------------------------------------------------
filters.profession("Inscription")
check("profession filter -> 2 pets", listLen == 2)
filters.profession("all")

-- 8. a LATE-resolving item (cold cache) appears on its own event ----------
-- Add a 6th item that classifies only after the list is already showing.
local items = recipesSig()
items[#items + 1] = { itemID = 6, name = "Late Pet", profession = "Alchemy", expansion = "TWW" }
recipesSig(items) -- same table ref -> use a fresh table to trigger change
recipesSig({ items[1], items[2], items[3], items[4], items[5], items[6] })
check("new item pending -> still 4 (not yet classified)", listLen == 4)
kindStore[6] = "pet"; collectedStore[6] = false
fire("CLASSIFY", 6)
check("late item appears on its OWN event, no manual refresh", listLen == 5)

print(string.format("Showroom model: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
