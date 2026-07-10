VWB = VWB or {}
VWB.PriceIntegration = {}

-- TSM > Auctionator > direct AH-scan price facade. MARKET prices only -- there
-- is deliberately NO vendor fallback: a vendor sell value is not a market price,
-- and silently substituting one produced fantasy Ledger rows (9400% margins on
-- vendor-math both sides). nil from the authoritative source IS the answer.

local PRICE_CACHE_TTL = 300 -- seconds; aligned with the Ledger's profit cache

-- TSM custom-price keys. Verified against the HDGR PriceSource donor, itself
-- checked vs live TSM tooltips. SoldPerDay is multiplied x1000 INSIDE the price
-- string so GetCustomPriceValue's integer rounding does not collapse the sub-1
-- daily velocity of slow-moving decor to zero (we divide back out after).
local TSM_MARKET_KEY   = "DBMarket"
local TSM_REGION_KEY   = "DBRegionSaleAvg"      -- TSM "Region Sale Avg" price source
local TSM_SOLD_PER_DAY = "1000 * DBRegionSoldPerDay"

local function IsTSMAvailable()
    return TSM_API and TSM_API.GetCustomPriceValue
end

local function IsAuctionatorAvailable()
    return Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID
end

function VWB.PriceIntegration:HasTSM() return IsTSMAvailable() and true or false end

-- Session memos: the Ledger's chunked build asks for the same reagent prices
-- thousands of times; TSM/Auctionator lookups are not free.
local priceCache = {}    -- [itemID] = { price, at }
local velocityCache = {} -- [itemID] = { value, at }

local function tsmValue(itemID, key)
    if not IsTSMAvailable() then return nil end
    -- exception(boundary): TSM_API is a third-party addon global; GetCustomPriceValue
    -- returns nil / 0 for items its AuctionDB has never seen
    local p = TSM_API.GetCustomPriceValue(key, "i:" .. itemID)
    if p and p > 0 then return p end
    return nil
end

local function auctionatorValue(itemID)
    if not IsAuctionatorAvailable() then return nil end
    -- exception(boundary): Auctionator is a third-party addon; API returns nil pre-scan
    local p = Auctionator.API.v1.GetAuctionPriceByItemID("VWB", itemID)
    if p and p > 0 then return p end
    return nil
end

-- Resolve the market price honoring the pinned source. A pinned source never
-- falls through to a different one -- an explicit choice is honored, and nil
-- means nil (no cross-source invention). The unpinned/auto path is the ONLY
-- place the direct AH-scan table is consulted, after TSM and Auctionator, and
-- it only ever surfaces real listing prices.
local function resolvePrice(itemID)
    local priceSource = VWB.Store:GetState().config.priceSource
    if priceSource == "TSM" then
        return tsmValue(itemID, TSM_MARKET_KEY)
    elseif priceSource == "TSMRegion" then
        return tsmValue(itemID, TSM_REGION_KEY)
    elseif priceSource == "Auctionator" then
        return auctionatorValue(itemID)
    end

    local p = tsmValue(itemID, TSM_MARKET_KEY)
    if p then return p end
    p = auctionatorValue(itemID)
    if p then return p end
    return VWB.AHScan:GetPrice(itemID)
end

-- Get MARKET price for item (copper), or nil when no source has data.
function VWB.PriceIntegration:GetPrice(itemID)
    if not itemID then return nil end

    local cached = priceCache[itemID]
    if cached and (GetTime() - cached.at) < PRICE_CACHE_TTL then
        return cached.price or nil -- false = cached miss
    end

    local price = resolvePrice(itemID)
    priceCache[itemID] = { price = price or false, at = GetTime() }
    return price
end

-- TSM region units-sold-per-day for an item, or nil (needs the TSM Desktop App
-- exporting AuctionDB). Feeds the Ledger's TSM-gated "Sold/Day" liquidity
-- column -- high-margin-but-nobody-buys is the trap it exposes.
function VWB.PriceIntegration:GetSoldPerDay(itemID)
    if not (itemID and IsTSMAvailable()) then return nil end

    local cached = velocityCache[itemID]
    if cached and (GetTime() - cached.at) < PRICE_CACHE_TTL then
        return cached.value or nil -- false = cached miss
    end

    local raw = tsmValue(itemID, TSM_SOLD_PER_DAY)
    local perDay = raw and raw / 1000 or nil
    velocityCache[itemID] = { value = perDay or false, at = GetTime() }
    return perDay
end

function VWB.PriceIntegration:InvalidateCache()
    priceCache = {}
    velocityCache = {}
end

-- Installed price sources, in preference order. The Settings price-source
-- dropdown is built against this list -- keep the contract (list of INSTALLED
-- sources) stable. TSMRegion is a distinct TSM mode (region sale average),
-- surfaced only when TSM is present.
function VWB.PriceIntegration:GetAvailableSources()
    local sources = {}
    if IsTSMAvailable() then
        table.insert(sources, "TSM")
        table.insert(sources, "TSMRegion")
    end
    if IsAuctionatorAvailable() then
        table.insert(sources, "Auctionator")
    end
    return sources
end
