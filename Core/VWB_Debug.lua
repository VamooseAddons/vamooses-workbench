-- ============================================================================
-- VamoosesWorkbench - VWB.Debug (instrumentation + profiler)
-- ============================================================================
-- One gate (VWB_DB.config.debug). When ON, this installs FOUR probes and
-- accumulates into keyed buckets; when OFF, every probe is uninstalled (the
-- Reactor seams go back to nil, the wrapped functions are restored) so there is
-- literally zero steady-state cost -- not a per-call branch, no hook at all.
--
-- The seams, mapped from HDG's Redux-middleware profiler onto Reactor:
--   * Reactor.setInstrument   -> times every computed/effect recompute, bucketed
--                                by node label  (= HDG's per-selector timing).
--   * Reactor.setFlushObserver-> brackets each scheduler flush: duration +
--                                effects-per-flush  (= HDG's RecordFlush, i.e.
--                                coalescing health).
--   * Store.Dispatch wrap     -> the action log (name + reducer ms). VWB HAS a
--                                single dispatch funnel, unlike a pure signals
--                                model, so this one maps 1:1 to HDG's Logger.
--   * EventBus.Trigger wrap   -> per-event fire counts.
--   * Log.* wrap              -> a ring buffer the Debug view reads.
--
-- Timing is debugprofilestop() (sub-ms). GetTime() is frame-granular and would
-- read 0ms per frame. The clock lives HERE, never in portable Reactor.
-- The Debug view polls these report builders on a throttled OnUpdate; nothing
-- here writes a signal (a signal write from inside a recompute would be a bug).
-- ============================================================================

local _, ns = ...
local Reactor = ns.Reactor
local Debug = {}
VWB.Debug = Debug

local clock = _G.debugprofilestop -- exception(boundary): WoW global; sub-ms wall clock

local NODE_FLOOR_MS = 0.05 -- hide reactive nodes cheaper than this in the report
local HOT_TOP       = 30
local LOG_CAP       = 200
local ACTION_CAP    = 60
local EVENT_TOP     = 20

-- Accumulator buckets ---------------------------------------------------------
-- nodeStats is keyed by the node TABLE (not a string) so the hot path allocates
-- nothing per recompute, and WEAK so a disposed node's stats are collected with
-- it -- the profiler never keeps a torn-down view's nodes alive.
local nodeStats = setmetatable({}, { __mode = "k" }) -- node -> { label, kind, count, total, max }
local flushAccum = { count = 0, effects = 0, total = 0, max = 0 }
local actionLog = {}  -- ring of { action, ms, detail }
local logRing   = {}  -- ring of { level, msg }
local lastSetConfigStack -- debugstack of the most recent SET_CONFIG (loop-source diagnostic)
local eventCounts = {}
local wowEvents = {}  -- wow event name -> { count, total, max } (handler cost, NOT recompute)
local enabled = false

-- Recording (hot path -- keep allocation-free after first sight of a key) ------
local function recordNode(node, ms)
    local s = nodeStats[node]
    if not s then
        s = { label = node.label or node.kind, kind = node.kind, count = 0, total = 0, max = 0 }
        nodeStats[node] = s
    end
    s.count = s.count + 1
    s.total = s.total + ms
    if ms > s.max then s.max = ms end
end

local function instrumentWrap(node, thunk)
    local t0 = clock()
    local r = thunk() -- may throw (fail-loud); recordNode simply won't run for that sample
    recordNode(node, clock() - t0)
    return r
end

local function flushBegin()
    local t0 = clock()
    return function(effects)
        local ms = clock() - t0
        flushAccum.count = flushAccum.count + 1
        flushAccum.effects = flushAccum.effects + effects
        flushAccum.total = flushAccum.total + ms
        if ms > flushAccum.max then flushAccum.max = ms end
    end
end

-- Times a whole WoW-event fan-out (Reactor_WoW seam). This is where resource
-- event handlers run -- work the recompute/flush profiler is blind to.
local function wowEventBegin(event)
    local t0 = clock()
    return function()
        local ms = clock() - t0
        local s = wowEvents[event]
        if not s then s = { count = 0, total = 0, max = 0 }; wowEvents[event] = s end
        s.count = s.count + 1
        s.total = s.total + ms
        if ms > s.max then s.max = ms end
    end
end

local function pushAction(action, ms, detail)
    actionLog[#actionLog + 1] = { action = action, ms = ms, detail = detail }
    while #actionLog > ACTION_CAP do table.remove(actionLog, 1) end
end

local function pushLog(level, msg)
    logRing[#logRing + 1] = { level = level, msg = tostring(msg) }
    while #logRing > LOG_CAP do table.remove(logRing, 1) end
end

-- Install / uninstall ---------------------------------------------------------
local NOISY = { SET_MINIMAP_POS = true } -- drag spam; counted nowhere
local LOG_METHODS = { "Error", "Warn", "Debug", "Info" }
local origDispatch, origTrigger
local origLog = {}

function Debug:Enable()
    if enabled then return end
    enabled = true

    Reactor.setInstrument(instrumentWrap)
    Reactor.setFlushObserver(flushBegin)
    ns.ReactorWoW.setEventProfiler(wowEventBegin)

    origDispatch = ns.Store.Dispatch
    ns.Store.Dispatch = function(store, action, payload)
        local t0 = clock()
        local r = origDispatch(store, action, payload)
        if not NOISY[action] then
            local detail = (type(payload) == "table" and payload.key ~= nil)
                and (tostring(payload.key) .. "=" .. tostring(payload.value)) or nil
            pushAction(action, clock() - t0, detail)
            -- Loop-source diagnostic: capture WHO dispatched the latest SET_CONFIG.
            -- Level 1 is this wrapper closure; level 2 is the direct Dispatch caller,
            -- so start there and walk up the chain (through effects/handlers that
            -- static reading can't see). origDispatch already returned, so it's off
            -- the stack -- no extra frame to skip.
            if action == "SET_CONFIG" then lastSetConfigStack = debugstack(2, 10, 0) end
        end
        return r
    end

    origTrigger = VWB.EventBus.Trigger
    VWB.EventBus.Trigger = function(bus, event, payload)
        -- Count AND time the whole listener fan-out: invalidateAll re-reads,
        -- epoch-bump recomputes etc. run synchronously inside Trigger, and the
        -- reactive hotspot list never sees them (found the hard way: 3k
        -- VWB_TRANSMOG_UPDATED fires whose cost was invisible in perf stats).
        local s = eventCounts[event]
        if not s then s = { n = 0, total = 0, max = 0 }; eventCounts[event] = s end
        local t0 = clock()
        origTrigger(bus, event, payload)
        local dt = clock() - t0
        s.n = s.n + 1
        s.total = s.total + dt
        if dt > s.max then s.max = dt end
    end

    for _, m in ipairs(LOG_METHODS) do
        origLog[m] = VWB.Log[m]
        VWB.Log[m] = function(logSelf, msg) pushLog(m, msg); return origLog[m](logSelf, msg) end
    end
end

function Debug:Disable()
    if not enabled then return end
    enabled = false

    Reactor.setInstrument(nil)
    Reactor.setFlushObserver(nil)
    ns.ReactorWoW.setEventProfiler(nil)

    -- Strict restore (no guards): Enable always populates these when it flips
    -- `enabled`, and Disable only runs when `enabled` -- so a nil here is a real
    -- desync we WANT to error on, not silently skip (which would leak the wrapper).
    ns.Store.Dispatch = origDispatch; origDispatch = nil
    VWB.EventBus.Trigger = origTrigger; origTrigger = nil
    for _, m in ipairs(LOG_METHODS) do
        VWB.Log[m] = origLog[m]; origLog[m] = nil
    end
end

function Debug:IsEnabled() return enabled end

function Debug:Reset()
    for k in pairs(nodeStats) do nodeStats[k] = nil end
    flushAccum.count, flushAccum.effects, flushAccum.total, flushAccum.max = 0, 0, 0, 0
    for k in pairs(eventCounts) do eventCounts[k] = nil end
    for k in pairs(wowEvents) do wowEvents[k] = nil end
    for i = #actionLog, 1, -1 do actionLog[i] = nil end
    for i = #logRing, 1, -1 do logRing[i] = nil end -- clear the log ring too (was asymmetric)
    lastSetConfigStack = nil
end

-- Toggle: the config dispatch (persists + bumps the config slice so the nav's
-- Debug tab shows/hides reactively) AND install/uninstall the probes.
function Debug:SetEnabled(on)
    ns.Store:Dispatch("SET_CONFIG", { key = "debug", value = on or nil })
    if on then self:Enable() else self:Disable() end
end

function Debug:Toggle()
    local on = not (VWB_DB and VWB_DB.config and VWB_DB.config.debug) -- exception(boundary): raw SavedVar
    self:SetEnabled(on)
    return on
end

-- Report builders (the Debug view SetText()s these on a throttled poll) --------
function Debug:PerfReport()
    local lines = { "== REACTIVE HOTSPOTS (top " .. HOT_TOP .. " by total ms; floor " .. NODE_FLOOR_MS .. "ms) ==" }
    local arr = {}
    for _, s in pairs(nodeStats) do arr[#arr + 1] = s end
    table.sort(arr, function(a, b) return a.total > b.total end)
    lines[#lines + 1] = string.format("%-36s %7s %9s %8s", "node", "count", "total", "max")
    local shown = 0
    for _, s in ipairs(arr) do
        if s.total < NODE_FLOOR_MS or shown >= HOT_TOP then break end
        lines[#lines + 1] = string.format("%-36s %7d %8.1f %8.2f", s.label:sub(1, 36), s.count, s.total, s.max)
        shown = shown + 1
    end
    if shown == 0 then lines[#lines + 1] = "  (nothing above the floor yet -- interact with a tab)" end

    local avg = flushAccum.count > 0 and flushAccum.total / flushAccum.count or 0
    local epf = flushAccum.count > 0 and flushAccum.effects / flushAccum.count or 0
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("== FLUSHES ==  %d  |  avg %.2fms  |  max %.2fms  |  %.1f effects/flush",
        flushAccum.count, avg, flushAccum.max, epf)

    -- WoW-event handler cost -- work that runs OUTSIDE any recompute (resource
    -- re-reads on GET_ITEM_INFO_RECEIVED, etc.). This is the profiler's former
    -- blind spot: a slow number here explains a freeze the hotspots table can't.
    local we = {}
    for name, s in pairs(wowEvents) do we[#we + 1] = { name = name, s = s } end
    table.sort(we, function(a, b) return a.s.total > b.s.total end)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== WOW EVENT HANDLERS (by total ms) =="
    lines[#lines + 1] = string.format("%-32s %7s %9s %8s", "event", "count", "total", "max")
    for i = 1, math.min(#we, EVENT_TOP) do
        local e = we[i]
        lines[#lines + 1] = string.format("%-32s %7d %8.1f %8.2f", e.name:sub(1, 32), e.s.count, e.s.total, e.s.max)
    end

    local ev = {}
    for name, s in pairs(eventCounts) do ev[#ev + 1] = { name = name, s = s } end
    table.sort(ev, function(a, b) return a.s.total > b.s.total end) -- by fan-out cost, not count
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== EVENT BUS (top " .. EVENT_TOP .. " by total listener ms) =="
    lines[#lines + 1] = string.format("%-40s %7s %9s %8s", "event", "count", "total", "max")
    for i = 1, math.min(#ev, EVENT_TOP) do
        local e = ev[i]
        lines[#lines + 1] = string.format("%-40s %7d %8.1f %8.2f", e.name:sub(1, 40), e.s.n, e.s.total, e.s.max)
    end
    return table.concat(lines, "\n")
end

function Debug:DebugReport()
    UpdateAddOnMemoryUsage()
    local lines = {
        string.format("== MEMORY ==  %.0f KB Lua heap  |  %.0f KB this addon",
            collectgarbage("count"), GetAddOnMemoryUsage("VamoosesWorkbench")),
        "",
        "== RECENT ACTIONS (newest last) ==",
    }
    for _, a in ipairs(actionLog) do
        lines[#lines + 1] = string.format("  %-24s %6.2fms  %s", a.action, a.ms, a.detail or "")
    end
    if lastSetConfigStack then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "== LAST SET_CONFIG SOURCE (loop diagnostic) =="
        lines[#lines + 1] = lastSetConfigStack
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== LOG (last " .. #logRing .. ") =="
    for _, e in ipairs(logRing) do
        lines[#lines + 1] = string.format("  [%-5s] %s", e.level, e.msg)
    end
    return table.concat(lines, "\n")
end
