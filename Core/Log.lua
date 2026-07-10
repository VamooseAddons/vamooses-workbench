-- ============================================================================
-- VamoosesWorkbench - Log
-- Minimal logging surface. Loads FIRST (before EventBus) so every Core module
-- and every Module/UI file can call VWB.Log from load time onward.
--
-- Zero dependencies BY DESIGN: Debug/Info gate on the RAW SavedVariable
-- (VWB_DB.config.debug) read directly, NOT VWB.Store:GetState().config -- so
-- logging works before, during, and after store load. The store's working copy
-- doesn't exist yet at ADDON_LOADED time when the earliest modules want to log.
--
-- Error/Warn ALWAYS print. pcalls are gone from VWB by policy, so a swallowed
-- failure has no backstop anymore; surfacing it in chat IS the backstop.
-- ============================================================================
VWB = VWB or {}

-- Prefix strings (solarized hexes; module-local so Log stays dependency-free
-- and doesn't wait on Core/Constants to define the palette).
local PREFIX_ERROR = "|cFFdc322f[VWB]|r "   -- red    (solarized red)
local PREFIX_WARN  = "|cFFcb4b16[VWB]|r "   -- orange (solarized orange)
local PREFIX_DEBUG = "|cFF859900[VWB]|r "   -- green  (solarized green -- dev chatter)
local PREFIX_INFO  = "|cFF2aa198[VWB]|r "   -- cyan   (solarized cyan)

VWB.Log = {}

local function DebugEnabled()
    -- exception(boundary): VWB_DB is the raw SavedVariable; it (and .config) is
    -- nil/partial before OnInitialize merges defaults -- logging must survive that.
    return VWB_DB and VWB_DB.config and VWB_DB.config.debug
end

-- Unconditional user-facing chat line (NOT debug-gated like Info/Debug): the
-- canonical home for the "[VWB] ..." prints that were duplicated as local
-- chat() helpers and inline strings across views (unification pass 2026-07-11).
function VWB.Log:Print(msg)
    print(PREFIX_INFO .. tostring(msg))
end

function VWB.Log:Error(msg)
    print(PREFIX_ERROR .. tostring(msg))
end

function VWB.Log:Warn(msg)
    print(PREFIX_WARN .. tostring(msg))
end

function VWB.Log:Debug(msg)
    if DebugEnabled() then
        print(PREFIX_DEBUG .. tostring(msg))
    end
end

function VWB.Log:Info(msg)
    if DebugEnabled() then
        print(PREFIX_INFO .. tostring(msg))
    end
end
