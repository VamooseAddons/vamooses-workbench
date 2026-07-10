-- ============================================================================
-- VamoosesWorkbench - EventBus
-- Internal pub/sub messaging. NO pcall isolation by policy: a listener error
-- must surface raw (Lua error frame + full stack), not become a chat line.
-- ============================================================================
VWB = VWB or {}
VWB.EventBus = { listeners = {} }

function VWB.EventBus:Register(event, callback)
    if not self.listeners[event] then
        self.listeners[event] = {}
    end
    table.insert(self.listeners[event], callback)
end

function VWB.EventBus:Trigger(event, payload)
    if not self.listeners[event] then return end
    for _, cb in ipairs(self.listeners[event]) do
        cb(payload)
    end
end

-- DebouncedTrigger was deleted 2026-07-11: ported from VPC, ZERO callers in
-- VWB (modules that need coalescing debounce at the source via ReactorWoW.after).
