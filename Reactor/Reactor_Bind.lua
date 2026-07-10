-- ============================================================================
-- Reactor - frame binding (fine-grained, no panel rebuilds)
-- ============================================================================
-- Signals bind to INDIVIDUAL frame properties via effects, not whole-panel
-- Update* functions. A bound fontstring updates itself when its computed
-- changes; a bound list reconciles STRUCTURE only when the item set changes,
-- while each row's cells react to their own async resources independently.
-- This is what retires the FullUpdate / repaint-everything class.
--
-- Frame-agnostic on purpose: binds call methods on whatever object is passed
-- (real WoW frame, or a mock in tests). Load AFTER Reactor_Core.
-- ============================================================================

local _, ns = ...
local Reactor = ns.Reactor
local effect = Reactor.effect

-- Generic: obj:method(fn()) whenever fn's deps change. Single return value.
-- Labeled by method so a reactive loop in a bound cell names itself.
local function bindCall(obj, method, fn)
    return effect(function() obj[method](obj, fn()) end, "bind:" .. method)
end
Reactor.bindCall = bindCall

function Reactor.bindText(fs, fn)     return bindCall(fs, "SetText", fn) end
function Reactor.bindShown(frame, fn) return bindCall(frame, "SetShown", fn) end
function Reactor.bindTexture(tex, fn) return bindCall(tex, "SetTexture", fn) end

-- Multi-value bind: fn returns the full argument tuple (e.g. r,g,b,a).
function Reactor.bindColor(fs, fn)
    return effect(function() fs:SetTextColor(fn()) end, "bind:SetTextColor")
end

-- bindList(itemsFn, o) -- keyed reconciliation with row pooling.
-- o = {
--   key(item)             -> unique, stable key
--   create()              -> a new row frame (pool miss)
--   setup(frame, item, i) -- ONCE per (key,row): establish the row's binds in
--                            its own scope; reads resources -> per-cell reactive
--   position(frame, i)    -- place the row (SetPoint etc.)
--   release(frame)        -- (optional) reset a pooled frame (e.g. :Hide())
--   afterUpdate(count)    -- (optional) once per structural change (e.g.
--                            scrollBox:FullUpdate) -- the ONLY place it's called
-- }
-- The list effect depends ONLY on itemsFn (the set/order); per-row setup runs
-- untracked so cell reactivity is the rows' business, not the list's. So a
-- resource resolving repaints one tick, NOT the whole list.
function Reactor.bindList(itemsFn, o)
    local pool = {}     -- free frames
    local active = {}   -- key -> { frame, scope, item }

    local function releaseRec(rec)
        Reactor.dispose(rec.scope)
        if o.release then o.release(rec.frame) end
        pool[#pool + 1] = rec.frame
    end

    effect(function()
        local items = itemsFn() -- tracked: structure reactivity
        Reactor.untrack(function()
            local seen = {}
            for i = 1, #items do
                local item = items[i]
                local key = o.key(item)
                seen[key] = true
                local rec = active[key]
                if not rec then
                    local frame = table.remove(pool) or o.create()
                    local sc
                    Reactor.scope(function(s) sc = s; o.setup(frame, item, i) end)
                    rec = { frame = frame, scope = sc, item = item }
                    active[key] = rec
                end
                o.position(rec.frame, i)
            end
            for key, rec in pairs(active) do
                if not seen[key] then releaseRec(rec); active[key] = nil end
            end
            if o.afterUpdate then o.afterUpdate(#items) end
        end)
    end, "bindList")

    -- Pooled rows aren't effects, so tear them down explicitly with the scope.
    Reactor.onCleanup(function()
        for key, rec in pairs(active) do Reactor.dispose(rec.scope); active[key] = nil end
    end)
end

Reactor.BIND_VERSION = 1
