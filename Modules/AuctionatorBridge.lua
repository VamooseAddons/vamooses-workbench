VWB = VWB or {}
VWB.AuctionatorBridge = {}

-- Send-to-AH boundary (pattern from VDS). Auctionator is a soft dependency:
-- missing addon -> friendly print, no error. CreateShoppingList with the same
-- listName REPLACES the Auctionator list, so the AH side always mirrors the
-- current shortfall -- no stale-cart management. Newer Auctionator builds
-- carry exact-match + quantity via ConvertToSearchString; legacy builds get
-- plain names.

local CALLER_ID = "VamoosesWorkbench"
local LIST_NAME = "VWB-Materials"

local function getApi()
    if not C_AddOns.IsAddOnLoaded("Auctionator") then
        return nil, "Auctionator is not loaded"
    end
    local A = Auctionator and Auctionator.API and Auctionator.API.v1 -- exception(boundary): optional addon
    if not (A and A.CreateShoppingList) then -- exception(boundary): API surface varies by Auctionator version
        return nil, "Auctionator API v1.CreateShoppingList is not available"
    end
    return A
end

-- "" is a miss: C_Item.GetItemNameByID returns "" for cold items and Lua's ""
-- is truthy -- a naive check would ship broken search strings
local function resolveName(itemID)
    local raw = C_Item.GetItemNameByID(itemID) -- exception(boundary): cold cache
    if raw and raw ~= "" then return raw end
    return nil
end

-- matCounts: merged shopping rows { itemID, name, missing, ... } keyed or arrayed
function VWB.AuctionatorBridge:SendShortfall(matCounts)
    local api, err = getApi()
    if not api then
        print("|cFF2aa198[VWB]|r " .. err .. ". Install Auctionator to send shopping lists.")
        return false
    end

    local hasQty = api.ConvertToSearchString ~= nil
    local searchStrings, missing, totalQty = {}, 0, 0

    for _, mat in pairs(matCounts) do
        if mat.missing and mat.missing > 0 then
            local name = resolveName(mat.itemID)
            if name then
                searchStrings[#searchStrings + 1] = hasQty
                    and api.ConvertToSearchString(CALLER_ID, { searchString = name, isExact = true, quantity = mat.missing })
                    or name
                totalQty = totalQty + mat.missing
            else
                missing = missing + 1
                C_Item.RequestLoadItemDataByID(mat.itemID)
            end
        end
    end

    if #searchStrings == 0 then
        if missing > 0 then
            print("|cFF2aa198[VWB]|r " .. missing .. " item name(s) still loading. Try again in a moment.")
        else
            print("|cFF2aa198[VWB]|r Nothing missing -- Auctionator list unchanged.")
        end
        return false
    end

    api.CreateShoppingList(CALLER_ID, LIST_NAME, searchStrings)

    local missingText = missing > 0 and (" -- " .. missing .. " skipped (name still loading)") or ""
    print("|cFF2aa198[VWB]|r Sent " .. #searchStrings .. " materials (" .. totalQty
        .. " total) to Auctionator list: " .. LIST_NAME .. missingText)
    return true
end
