-- ============================================================================
-- VamoosesWorkbench - AHScan
-- Direct Auction House browse-scan price tier for users with NO price addon
-- (no TSM, no Auctionator). A single empty browse query dumps every live
-- listing; we cache the minimum buyout per item into a SESSION-LOCAL table.
--
-- The table is never persisted -- AH prices go stale within minutes, and a
-- saved snapshot would masquerade as fresh next login. PriceIntegration
-- consults this AFTER TSM/Auctionator, so it only ever adds REAL market data,
-- never a vendor floor (the Ledger honesty rule stands).
--
-- Requires the AH window open (C_AuctionHouse.SendBrowseQuery is gated on it).
-- ============================================================================

VWB = VWB or {}
VWB.AHScan = {}

local SCAN_TIMEOUT = 60 -- seconds; a full browse scan pages in well under this

-- Session-local caches. sessionPrices[itemID] = min buyout copper;
-- sessionQty[itemID] = units currently listed. scanCompleted flips true once a
-- full scan finishes -- StartScan(force=false) becomes a no-op after that so we
-- do not re-dump the whole AH on every Ledger open.
local sessionPrices = {}
local sessionQty = {}
local scanCompleted = false

local scan = { active = false, pages = 0, timeoutTimer = nil }
local scanFrame

function VWB.AHScan:IsAHOpen()
    -- exception(boundary): AuctionHouseFrame exists only while Blizzard's AH UI
    -- is open; nil the rest of the time
    return _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() and true or false
end

function VWB.AHScan:IsScanning() return scan.active end
function VWB.AHScan:HasData() return scanCompleted end

function VWB.AHScan:GetResultCount()
    local n = 0
    for _ in pairs(sessionPrices) do n = n + 1 end
    return n
end

-- Session AH price / listed quantity for an item, or nil. GetPrice is the hook
-- PriceIntegration's auto fallback chain calls -- market data only.
function VWB.AHScan:GetPrice(itemID) return sessionPrices[itemID] end
function VWB.AHScan:GetQty(itemID) return sessionQty[itemID] end

-- Fold one page of browse results into the session table. Each result row is a
-- per-itemKey aggregate (totalQuantity/minPrice already summarised), so we take
-- the min price across pages and overwrite the listed quantity.
local function processBatch(results)
    if not results then return end
    for _, info in ipairs(results) do
        local itemID = info.itemKey and info.itemKey.itemID
        if itemID and info.totalQuantity and info.totalQuantity > 0 then
            local existing = sessionPrices[itemID]
            if not existing or (info.minPrice and info.minPrice < existing) then
                sessionPrices[itemID] = info.minPrice
            end
            sessionQty[itemID] = info.totalQuantity
        end
    end
end

function VWB.AHScan:_FinalizeScan()
    if not scan.active then return end
    scan.active = false
    scanCompleted = true
    if scan.timeoutTimer then scan.timeoutTimer:Cancel(); scan.timeoutTimer = nil end
    VWB.EventBus:Trigger("VWB_AH_SCAN_COMPLETE", { results = self:GetResultCount() })
end

-- AH closed mid-scan: keep whatever we already paged (a partial real AH price
-- still beats no price), but flag partial so callers know it is incomplete.
function VWB.AHScan:_AbortScan()
    if not scan.active then return end
    scan.active = false
    if scan.timeoutTimer then scan.timeoutTimer:Cancel(); scan.timeoutTimer = nil end
    if self:GetResultCount() > 0 then scanCompleted = true end
    VWB.EventBus:Trigger("VWB_AH_SCAN_COMPLETE", { results = self:GetResultCount(), partial = true })
end

function VWB.AHScan:_AdvanceOrFinish(CA)
    scan.pages = scan.pages + 1
    VWB.EventBus:Trigger("VWB_AH_SCAN_PROGRESS", { results = self:GetResultCount(), pages = scan.pages })
    if CA.HasFullBrowseResults() then
        self:_FinalizeScan()
    else
        CA.RequestMoreBrowseResults()
    end
end

local function onScanEvent(_, event, ...)
    if not scan.active then return end
    local CA = _G.C_AuctionHouse
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        processBatch(CA.GetBrowseResults())
        VWB.AHScan:_AdvanceOrFinish(CA)
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        processBatch(...)
        VWB.AHScan:_AdvanceOrFinish(CA)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        VWB.AHScan:_AbortScan()
    end
end

-- StartScan(force) -- AH must be open. Returns true if a scan started (or one is
-- already running), false if the AH is closed. Without force, a completed
-- session scan is a no-op (data already cached); the explicit Rescan affordance
-- passes force=true. The archived HDG scan shipped WITHOUT this and a finished
-- scan disabled rescan forever (every id was already non-nil, so the needed set
-- went to zero). Force wipes the session table for a clean re-dump.
function VWB.AHScan:StartScan(force)
    if not self:IsAHOpen() then return false end
    if scan.active then return true end
    if scanCompleted and not force then return true end
    if force then
        sessionPrices = {}
        sessionQty = {}
        scanCompleted = false
    end

    if not scanFrame then
        scanFrame = CreateFrame("Frame")
        scanFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        scanFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
        scanFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
        scanFrame:SetScript("OnEvent", onScanEvent)
    end

    scan.active = true
    scan.pages = 0
    scan.timeoutTimer = C_Timer.NewTimer(SCAN_TIMEOUT, function()
        VWB.AHScan:_FinalizeScan()
    end)
    VWB.EventBus:Trigger("VWB_AH_SCAN_STARTED", {})

    -- Empty query = every live listing; results stream in via the browse events.
    _G.C_AuctionHouse.SendBrowseQuery({
        searchString     = "",
        sorts            = {},
        filters          = {},
        itemClassFilters = {},
    })
    return true
end
