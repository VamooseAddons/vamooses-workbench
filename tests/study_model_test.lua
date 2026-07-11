-- Headless tests for the Study model + RecipeSources.Parse (v3 tokenizer).
-- The parse cases are LIVE-DATA regressions from 2026-07-11 screenshots:
-- inline sub-fields, multiple sources on ONE line, two-zone vendors,
-- Faction fields, values that legitimately contain colons ("Work Order:
-- Contract: ..."), and unknown line-start labels (Achievement / Quest Giver).

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
local P = ns.RecipeSources.Parse

-- 1. Inline sub-fields on one line (the "(no zone)" bug) ----------------------
do
    local p = P("|cffffd200Vendor:|r Aaron Hollman Zone: Shattrath City Cost: 4|TInterface\\MoneyFrame\\UI-GoldIcon:0|t")
    check("one line -> one source", #p.sources == 1)
    local s = p.sources[1]
    check("inline kind", s.kind == "Vendor")
    check("inline detail stops at Zone", s.detail == "Aaron Hollman")
    check("inline zone stops at Cost", s.zone == "Shattrath City")
    check("inline cost keeps money texture", s.cost == "4|TInterface\\MoneyFrame\\UI-GoldIcon:0|t")
end

-- 2. MULTIPLE sources on ONE line (the cost-blob overflow bug) ----------------
do
    local p = P("Vendor: Aaron Hollman Zone: Shattrath City Cost: 4 Vendor: Arras Zone: The Exodar Zone: Azuremyst Isle Cost: 4")
    check("second Vendor marker opens a new source", #p.sources == 2)
    check("first source clean", p.sources[1].detail == "Aaron Hollman" and p.sources[1].cost == "4")
    local arras = p.sources[2]
    check("two Zone fields -> zones array", arras.zones and #arras.zones == 2
        and arras.zones[1] == "The Exodar" and arras.zones[2] == "Azuremyst Isle")
    check("primary zone is first", arras.zone == "The Exodar")
    check("second cost stays on second source", arras.cost == "4")
end

-- 3. Faction field + values containing colons ---------------------------------
do
    local p = P("Vendor: Fedryen Swiftspear Faction: Cenarion Expedition - Honored Zone: Zangarmarsh Cost: 6")
    local s = p.sources[1]
    check("faction split out of detail", s.detail == "Fedryen Swiftspear" and s.faction == "Cenarion Expedition - Honored")
    check("zone survives after faction", s.zone == "Zangarmarsh")

    local wq = P("World Quest: Work Order: Contract: Order of Embers Zone: Drustvar")
    check("one WQ source (unknown mid-line labels stay in value)", #wq.sources == 1)
    check("WQ kind masks Quest", wq.sources[1].kind == "World Quest")
    check("colon-bearing value intact", wq.sources[1].detail == "Work Order: Contract: Order of Embers")
    check("WQ zone extracted", wq.sources[1].zone == "Drustvar")
end

-- 4. Unknown line-START labels open a source generically ----------------------
do
    check("Achievement kind", P("Achievement: A Time to Reflect").sources[1].kind == "Achievement")
    local qg = P("Quest Giver: Rensar Greathoof Zone: Ardenweald")
    check("two-word unknown label", qg.sources[1].kind == "Quest Giver" and qg.sources[1].zone == "Ardenweald")
    local o = P("Discovered via experimentation")
    check("unlabeled line -> Other", o.sources[1].kind == "Other" and o.sources[1].detail == "Discovered via experimentation")
end

-- 5. Multi-line: bare Zone/Cost lines attach to the source above --------------
do
    local p = P("Drop: Heavy Trunk\nZone: Delves")
    check("drop + zone line -> ONE source", #p.sources == 1 and p.sources[1].zone == "Delves")
    local two = P("Vendor: Mukra Zone: Thunder Bluff Cost: 2\nDrop: World Bosses")
    check("lines fold into the same stream", #two.sources == 2 and two.sources[2].kind == "Drop")
    check("raw lines kept for tooltip", #two.lines == 2)
end

-- 5b. THE live separator is |n (WoW escape, renders as newline but never
-- matches a \n split -- the 2184-zoneless regression). |n|n between vendor
-- blocks becomes a " " spacer line for the tooltip.
do
    local p = P("|cffffd200Vendor:|r Daggle Ironshaper|n|cffffd200Zone:|r Shadowmoon Valley|n|cffffd200Cost:|r 6|n|n|cffffd200Vendor:|r Mixie Farshot|n|cffffd200Zone:|r Hellfire Peninsula|n|cffffd200Cost:|r 6")
    check("|n split -> two sources", #p.sources == 2)
    check("|n zones extracted", p.sources[1].zone == "Shadowmoon Valley" and p.sources[2].zone == "Hellfire Peninsula")
    check("|n costs per source", p.sources[1].cost == "6" and p.sources[2].cost == "6")
    check("|n|n -> spacer line kept for tooltip", (function()
        for _, l in ipairs(p.lines) do if l == " " then return true end end
    end)())
    check("no trailing spacer", p.lines[#p.lines] ~= " ")
end

-- 5c. Block-context folding: location-first blocks are ONE path -------------
do
    local nomi = P("|cFFFFD200Zone:|r Dalaran|n|cFFFFD200NPC:|r Nomi|n|cFFFFD200Discovery:|r Nomi's Test Kitchen")
    check("Zone/NPC/Discovery fold to one source", #nomi.sources == 1)
    check("last real label wins the kind", nomi.sources[1].kind == "Discovery" and nomi.sources[1].detail == "Nomi's Test Kitchen")
    check("intermediary folds into via", nomi.sources[1].via == "Nomi")
    check("leading zone carried", nomi.sources[1].zone == "Dalaran")

    local quest = P("|cFFFFD200Zone:|r Blackrock Depths|n|cFFFFD200Quest:|r A Binding Contract|n")
    check("Zone/Quest fold", #quest.sources == 1 and quest.sources[1].kind == "Quest"
        and quest.sources[1].zone == "Blackrock Depths")

    local prof = P("Profession: Pandaria Jewelcrafting (25)|nTrainer: Mai the Jade Shaper|nZone: The Jade Forest")
    check("Trainer after a source attaches as via", #prof.sources == 1
        and prof.sources[1].kind == "Profession" and prof.sources[1].via == "Mai the Jade Shaper"
        and prof.sources[1].zone == "The Jade Forest")

    local lone = P("Trainer: Deirdre|nZone: Ironforge")
    check("lone Trainer is still its own kind", #lone.sources == 1 and lone.sources[1].kind == "Trainer")

    local blocks = P("Vendor: A|nZone: X|n|nZone: Y|nTreasure: Chest")
    check("blank line closes the block (no folding across)", #blocks.sources == 2
        and blocks.sources[2].kind == "Treasure" and blocks.sources[2].zone == "Y")
end

-- Shared model fixture --------------------------------------------------------
local recipes = {
    { recipeID = 1, itemID = 11, name = "Copper Rod",         profession = "Enchanting",    expansion = "Classic" },
    { recipeID = 2, itemID = 12, name = "Adamantite Cleaver", profession = "Blacksmithing", expansion = "TBC" },
    { recipeID = 3, itemID = 13, name = "Bear Steak",         profession = "Cooking",       expansion = "Midnight" },
    { recipeID = 4, name = "Zebra Enchant", profession = "Enchanting", expansion = "Midnight" }, -- no itemID (enchant)
}
local src = R.latchMap("testSources")
local knownSet = { [1] = true } -- recipe 1 already learned
local knownV = R.signal(0)
local filters = {
    search = R.signal(""), profession = R.signal("all"),
    navKey = R.signal(nil), collapsed = R.signal({}),
    showMissing = R.signal(true),
}
local model = ns.Study.buildModel({
    universe = function() return recipes end,
    source = { peek = function(id) return src:peek(id) end, epoch = src.epoch },
    known = { version = function() return knownV() end, isKnown = function(id) return knownSet[id] == true end },
    filters = filters,
})

-- 6. Flattening: one row per source PER ZONE ----------------------------------
do
    check("no latches -> no rows", #model.rows() == 0)
    -- Arras stands in two zones -> that ONE source is TWO rows
    src:latch(2, P("Vendor: Aaron Hollman Zone: Shattrath City Cost: 4 Vendor: Arras Zone: The Exodar Zone: Azuremyst Isle Cost: 4"))
    src:latch(3, P("Drop: Heavy Trunk\nZone: Delves"))
    check("2 sources / 3 zone-entries -> 4 rows", #model.rows() == 4)
    check("recipeCount counts recipes not rows", model.entries().recipeCount == 2)
    src:latch(1, P("Trainer: Anybody"))
    check("known recipe excluded even if latched", #model.rows() == 4)
    src:latch(4, { lines = {}, sources = {} }) -- walked, no acquisition data
    check("no-data recipe -> one Unspecified row", #model.rows() == 5)
end

-- 7. Ledger continuation over the final adjacency -----------------------------
do
    local rows = model.rows()
    -- name sort: Adamantite Cleaver x3 (Hollman, Arras/Azuremyst, Arras/Exodar), Bear Steak, Zebra
    check("first of run is not continuation", rows[1].continuation == false)
    check("run continues across sources AND zones", rows[2].continuation == true and rows[3].continuation == true)
    check("zone tiebreak inside same source", rows[2].zone == "Azuremyst Isle" and rows[3].zone == "The Exodar")
    check("next recipe resets", rows[4].continuation == false)
end

-- 8. Nav narrowing works at entry level (and re-carries the name) -------------
do
    filters.navKey("Vendor::Azuremyst Isle")
    local rows = model.rows()
    check("zone pick isolates the matching entry", #rows == 1 and rows[1].source.detail == "Arras")
    check("isolated entry is not a continuation", rows[1].continuation == false)
    filters.navKey("Vendor::*")
    check("kind pick keeps all three vendor rows", #model.rows() == 3)
    check("sections ignore the nav pick", #model.sections() == 3)
    filters.navKey(nil)
end

-- 9. Sections: entry counts, All first, zones alphabetical, Unspecified last --
do
    local secs = model.sections()
    check("vendor section counts zone-entries", secs[1].key == "Vendor" and secs[1].itemCount == 3)
    check("All item leads with ::* key", secs[1].items[1].key == "Vendor::*" and secs[1].items[1].count == 3)
    check("zones alphabetical after All", secs[1].items[2].label == "Azuremyst Isle" and secs[1].items[3].label == "Shattrath City")
    check("Unspecified pinned last", secs[#secs].key == "Unspecified")
end

-- 10. Search + profession filters scope rows AND sections ---------------------
do
    filters.profession("Cooking")
    check("profession filter", #model.rows() == 1 and model.rows()[1].item.recipeID == 3)
    filters.profession("all")
    filters.search("zebra")
    check("search filter", #model.rows() == 1 and model.rows()[1].item.recipeID == 4)
    filters.search("")
end

-- 11. Learning a recipe drops ALL its rows on the version bump (the reactive
-- edge is known.version, not the plain cache -- proven under an effect).
do
    local seen
    R.effect(function() seen = #model.rows() end, "test:rowsWatch")
    check("effect observes 5 rows", seen == 5)
    knownSet[2] = true
    check("plain cache mutation alone does not propagate", seen == 5)
    knownV(knownV() + 1)
    check("version bump drops all three vendor rows", seen == 2)
end

-- 12. Missing toggle: no-source recipes gate on showMissing; recipeCount
-- always counts them (they still need learning).
do
    check("missing shown by default", (function()
        for _, r in ipairs(model.rows()) do if r.source.kind == "Unspecified" then return true end end
    end)())
    local before = model.entries().recipeCount
    filters.showMissing(false)
    check("untick hides Unspecified rows", (function()
        for _, r in ipairs(model.rows()) do if r.source.kind == "Unspecified" then return false end end
        return true
    end)())
    check("untick drops the Unspecified section", (function()
        for _, s in ipairs(model.sections()) do if s.key == "Unspecified" then return false end end
        return true
    end)())
    check("recipeCount unchanged by the toggle", model.entries().recipeCount == before)
    filters.showMissing(true)
end

-- 13. Collapse state flows into sections ---------------------------------------
do
    check("expanded by default", model.sections()[1].collapsed == false)
    filters.collapsed({ [model.sections()[1].key] = true })
    check("collapsed flag propagates", model.sections()[1].collapsed == true)
end

print(string.format("Study model: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
