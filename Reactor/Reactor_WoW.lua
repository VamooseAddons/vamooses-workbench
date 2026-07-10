-- ============================================================================
-- Reactor_WoW - the frame-loop glue (portable). Wires Reactor's pluggable
-- scheduler / event source / logger to WoW so the core stays engine-agnostic
-- and headless-testable. NO C_Timer (UI rule): the flush is a one-shot OnUpdate
-- on a hidden driver frame -- many signal writes in a frame coalesce to ONE
-- flush next frame. install() is called once by the addon at ADDON_LOADED.
-- ============================================================================

local _, ns = ...
local ReactorWoW = {}

-- Optional profiler seam (nil = zero overhead; one nil-check per WoW event).
-- fn(event) -> done() brackets a whole event fan-out so the host can time work
-- that runs in the EVENT HANDLER (e.g. a resource re-reading pending keys) --
-- cost the reactive recompute/flush profiler never sees.
local eventProfiler = nil
function ReactorWoW.setEventProfiler(fn) eventProfiler = fn end

-- install(opts) wires the current ns.Reactor to the WoW frame loop.
--   opts.createFrame : frame factory (defaults to global CreateFrame; injected
--                      in headless tests)
--   opts.logger      : function(level, msg) diagnostics sink (optional)
function ReactorWoW.install(opts)
    opts = opts or {}
    local Reactor = ns.Reactor or error("Reactor_WoW: ns.Reactor missing (load order)")
    local mk = opts.createFrame or CreateFrame

    -- Scheduler: coalesced one-shot flush via a hidden driver's OnUpdate. WoW
    -- does NOT tick OnUpdate on hidden frames, so Show() arms exactly one tick,
    -- then the handler Hide()s again. The core guards re-arm (flushScheduled),
    -- so Show() runs at most once per flush cycle.
    local driver = mk("Frame")
    driver:Hide()
    local pendingRunFlush
    driver:SetScript("OnUpdate", function(self)
        self:Hide()
        local rf = pendingRunFlush
        pendingRunFlush = nil
        if rf then rf() end
    end)
    Reactor.setScheduler(function(runFlush)
        pendingRunFlush = runFlush
        driver:Show()
    end)

    -- Event source: bridge Reactor resources to WoW events. subscribe(event,
    -- handler) -> unsub. One shared frame; handlers[event] is a fan-out list.
    local eventFrame = mk("Frame")
    local handlers = {}
    eventFrame:SetScript("OnEvent", function(self, event, ...)
        local list = handlers[event]
        if not list then return end -- exception(boundary): in-flight event after last unsub
        if eventProfiler then
            local done = eventProfiler(event)
            for i = 1, #list do list[i](...) end
            done()
        else
            for i = 1, #list do list[i](...) end
        end
    end)
    Reactor.setEventSource(function(event, handler)
        local list = handlers[event]
        if not list then
            list = {}; handlers[event] = list
            eventFrame:RegisterEvent(event)
        end
        list[#list + 1] = handler
        return function()
            local l = handlers[event]
            if not l then return end -- exception(boundary): already torn down
            for i = #l, 1, -1 do if l[i] == handler then table.remove(l, i) end end
            if #l == 0 then handlers[event] = nil; eventFrame:UnregisterEvent(event) end
        end
    end)

    if opts.logger then Reactor.setLogger(opts.logger) end

    ReactorWoW.driver = driver
    ReactorWoW.eventFrame = eventFrame
    return ReactorWoW
end

ReactorWoW.VERSION = 1

if ns then ns.ReactorWoW = ReactorWoW end
return ReactorWoW
