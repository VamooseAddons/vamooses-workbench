-- Headless test for VWB.ReagentSource gather-method classification. Stubs
-- C_Item.GetItemInfoInstant (classID/subClassID at positions 6/7) + the recipe
-- topology; asserts (gatherMethod, sourceTier) per Trade Goods subclass, the
-- classID~=7 fallthrough, the farmbuy-gating, and cache-miss. Run:
--   /opt/homebrew/bin/lua tests/reagent_source_gather_test.lua
local base = arg[0]:gsub("tests/reagent_source_gather_test%.lua$", "")

-- recipe 1 CONSUMES 100..108 (raw inputs -> farmbuy) and PRODUCES 900;
-- recipe 2 CONSUMES 900 (so 900 is input+output -> crafted).
local RECIPES = {
    [1] = { itemID = 900, slots = {
        { type = "basic", itemID = 100 }, { type = "basic", itemID = 101 },
        { type = "basic", itemID = 102 }, { type = "basic", itemID = 103 },
        { type = "basic", itemID = 104 }, { type = "basic", itemID = 105 },
        { type = "basic", itemID = 106 }, { type = "basic", itemID = 107 },
        { type = "basic", itemID = 108 } } },
    [2] = { itemID = 950, slots = { { type = "basic", itemID = 900 } } },
}
local ITEM_CLASS = { -- itemID -> {classID, subClassID}
    [100] = {7,9},  [101] = {7,7},  [102] = {7,6},  [103] = {7,12}, [104] = {7,16},
    [105] = {7,4},  [106] = {7,5},  [107] = {7,8},  [108] = {7,11}, [200] = {12,0},
    [900] = {7,7},
}

local ITEM_NAMES = { [300] = "Aetherlume", [301] = "Evercore", [302] = "Core", [303] = "Aetherlume" }
local ITEM_CACHED = { [300] = true, [301] = true, [302] = true } -- 303 starts cold
_G.C_Item = {
    GetItemInfoInstant = function(id)
        local c = ITEM_CLASS[id]
        if not c then return nil end -- cache-miss / unknown item
        return nil, nil, nil, nil, nil, c[1], c[2]
    end,
    IsItemDataCachedByID = function(id) return ITEM_CACHED[id] == true end,
    GetItemInfo = function(id) return ITEM_NAMES[id] end,
}
_G.Enum = { ItemBind = { OnAcquire = 1 } }
local SALVAGE_RECIPES = { -- harvested salvage recipe descriptions (ADD_SALVAGE_RECIPES slice)
    [77] = { name = "Recycling", profession = "Engineering",
        description = "Recycle 5 crafted reagents from a variety of Midnight Professions to salvage necessary components like Aetherlume and Evercores." },
}
_G.VWB = {
    Database = { GetAllRecipes = function() return RECIPES end },
    Store = { GetState = function() return { salvageRecipes = SALVAGE_RECIPES } end },
}

dofile(base .. "Modules/ReagentSource.lua")
local RS = _G.VWB.ReagentSource

local pass, fail = 0, 0
local function check(n, c) if c then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. n) end end
local function expect(id, method, tier)
    local info = RS:GetInfo(id)
    check(id .. " method=" .. tostring(method), info.gatherMethod == method)
    check(id .. " tier=" .. tostring(tier), info.sourceTier == tier)
end

expect(100, "Herbalism",   "gather")
expect(101, "Mining",      "gather")
expect(102, "Skinning",    "gather")
expect(103, "Disenchant",  "refine")
expect(104, "Milling",     "refine")
expect(105, "Prospecting", "refine")
expect(106, "Cloth",       "farm")
expect(107, "Cooking",     "farm")
expect(108, nil, nil) -- subclass 11 Other -> unclassified
expect(200, nil, nil) -- classID 12 (Quest) -> not Trade Goods

local crafted = RS:GetInfo(900)
check("900 is crafted", crafted.class == "crafted")
check("900 gatherMethod nil (farmbuy-gated)", crafted.gatherMethod == nil)
check("900 sourceTier nil (farmbuy-gated)", crafted.sourceTier == nil)

local miss = RS:GetInfo(555)
check("555 farmbuy (no recipe)", miss.class == "farmbuy")
check("555 gatherMethod nil (cache-miss, no error)", miss.gatherMethod == nil)

-- salvage-description tag: word-frontier match against harvested salvage text
expect(300, "Recycling", "salvage") -- exact name in the description
expect(301, "Recycling", "salvage") -- "Evercore" matches the pluralized "Evercores"
expect(302, nil, nil)               -- "Core" must NOT match inside "Evercores" (frontier)
expect(303, nil, nil)               -- item cache cold: no answer, and no NONE poisoning...
ITEM_CACHED[303] = true
expect(303, "Recycling", "salvage") -- ...so the tag appears once the name resolves

print(string.format("ReagentSource gather: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
