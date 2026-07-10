-- ============================================================================
-- VWB Nav - ephemeral cross-view jump layer.
-- ============================================================================
-- CONSUMPTION CONTRACT:
--   Views read + clear pending signals in their show/mount effect:
--     local payload = VWB.Nav.pendingSearch()
--     if payload ~= nil then VWB.Nav.pendingSearch(nil); -- use payload end
--   Pending signals are NOT Store state, NOT SavedVars -- they live only in
--   this session and evaporate when the target view consumes them or the
--   window closes. Load order: Nav loads BEFORE Shell (see TOC), so Shell
--   is not yet initialized when this file runs. Shell calls:
--     VWB.Nav._setView = function(id) Shell.setView(id) end
--   during openWindow(), providing the late-bound view-switch hook.
-- ============================================================================

local _, ns = ...

local Nav = {}
ns.Nav = Nav
_G.VWB = ns -- mirror for ported modules using bare VWB

-- Pending signals: nil by default; a view consumes + clears on mount.
-- @type annotations declare the signal call shape (read = f(), write = f(v)) --
-- wowlua-ls can't carry Reactor.signal's callable return across module fields.
---@type fun(v?: any): any
Nav.pendingSearch = ns.Reactor.signal(nil)  -- string: filter to apply on arrival
---@type fun(v?: any): any
Nav.pendingScope  = ns.Reactor.signal(nil)  -- charKey: character scope to apply
---@type fun(v?: any): any
Nav.pendingSelect = ns.Reactor.signal(nil)  -- itemID/recipeID: item to select/scroll

-- Late-bound hook: Shell assigns this during openWindow() so Nav can switch
-- the active view without a circular dependency (Nav loads before Shell).
-- Initialized to a loud-error stub so the LSP infers function type AND any
-- call before Shell wires the hook surfaces a clear error (not a nil-call crash).
Nav._setView = function(_viewId) error("VWB.Nav._setView not wired: Shell.openWindow() must run first") end

-- VWB.Nav.Go(viewId, payload)
--   viewId  : string matching a VIEWS registry id in VWB_Shell.lua
--   payload : optional table with any of:
--               filter  = string  -> sets pendingSearch
--               scope   = charKey -> sets pendingScope
--               select  = id      -> sets pendingSelect
-- Sets the relevant pending signals THEN switches the active view.
-- The target view reads + clears the signals in its show effect.
function Nav.Go(viewId, payload)
    if payload then
        if payload.filter  ~= nil then Nav.pendingSearch(payload.filter) end
        if payload.scope   ~= nil then Nav.pendingScope(payload.scope) end
        if payload.select  ~= nil then Nav.pendingSelect(payload.select) end
    end
    Nav._setView(viewId) -- fails loud if Shell hasn't wired the hook yet (load-order bug)
end
