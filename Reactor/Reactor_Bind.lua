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

function Reactor.bindText(fs, fn)     return bindCall(fs, "SetText", fn) end
function Reactor.bindShown(frame, fn) return bindCall(frame, "SetShown", fn) end

-- Multi-value bind: fn returns the full argument tuple (e.g. r,g,b,a).
function Reactor.bindColor(fs, fn)
    return effect(function() fs:SetTextColor(fn()) end, "bind:SetTextColor")
end

-- (bindTexture, the bindCall export, and bindList -- the keyed row-pooling
-- reconciler -- were deleted unused in the 2026-07-11 hygiene pass. Views
-- pool rows via VWB.UI:CreateVirtualizedList; if fine-grained per-row binds
-- are ever adopted, bindList lives in git history with its test suite.)

Reactor.BIND_VERSION = 2 -- v2: trimmed to the adopted surface (text/shown/color)
