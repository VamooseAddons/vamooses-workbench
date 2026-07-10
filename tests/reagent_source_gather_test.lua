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

_G.C_Item = {
    GetItemInfoInstant = function(id)
        local c = ITEM_CLASS[id]
        if not c then return nil end -- cache-miss / unknown item
        return nil, nil, nil, nil, nil, c[1], c[2]
    end,
    IsItemDataCachedByID = function() return false end,
    GetItemInfo = function() return nil end,
}
_G.Enum = { ItemBind = { OnAcquire = 1 } }
_G.VWB = { Database = { GetAllRecipes = function() return RECIPES end } }

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

print(string.format("ReagentSource gather: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
