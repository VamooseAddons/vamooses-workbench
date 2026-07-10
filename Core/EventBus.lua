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

-- Keyed debounce for internal fan-out. One pending timer per `key`; re-arming
-- cancels the prior timer so only the LAST call within delaySeconds fires, and
-- it fires with the most-recent payload (each call captures the latest closure).
-- Use for bursty triggers (bag churn, roster updates) where the intermediate
-- fan-outs are wasted work. Callers own their key namespace.
local debounceTimers = {}

function VWB.EventBus:DebouncedTrigger(key, delaySeconds, eventName, payload)
    local pending = debounceTimers[key]
    if pending then
        pending:Cancel()
    end
    debounceTimers[key] = C_Timer.NewTimer(delaySeconds, function()
        debounceTimers[key] = nil
        VWB.EventBus:Trigger(eventName, payload)
    end)
end
