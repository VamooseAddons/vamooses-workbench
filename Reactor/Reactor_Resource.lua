-- ============================================================================
-- Reactor - resource primitive (async data as a signal)
-- ============================================================================
-- Extends Reactor with resources: a value that resolves ASYNC via an event,
-- modeled as a reactive signal. This is the WoW cold-cache unlock -- item
-- cache, mount/pet journals, housing catalog all resolve later, and a resource
-- makes "pending -> ready" propagate through the graph automatically, so a
-- computed/effect that reads it re-runs on resolve with ZERO manual
-- RequestLoad + event-handler + refresh wiring.
--
-- request-once + coalesce are baked IN (not hand-rolled per feature): each key
-- requests its load at most once; one event listener resolves all matching
-- pending keys in a single batch.
--
-- Portable: no WoW API here. The host injects an event source via
-- Reactor.setEventSource(subscribe) -- subscribe(event, handler) -> unsub.
-- WoW wraps a frame; tests pass a mock. Load AFTER Reactor_Core.
-- ============================================================================

local _, ns = ...
local Reactor = ns.Reactor
local unpack = table.unpack or unpack -- 5.5 host tests vs 5.1 WoW

-- Unique sentinel returned while a resource key is still loading.
local PENDING = setmetatable({}, { __tostring = function() return "<pending>" end })
Reactor.PENDING = PENDING
function Reactor.isPending(v) return v == PENDING end

local eventSubscribe = nil -- fn(event, handler) -> unsubscribe
function Reactor.setEventSource(fn) eventSubscribe = fn end

-- resource(opts) -> get(key). opts:
--   read(key)      -> value | nil     synchronous best-effort read; nil = not
--                                      ready yet (a real value may be false/0)
--   request(key)                      (optional) kick off the async load; called
--                                      at most once per key
--   event          = "WOW_EVENT"      (optional) fires when data may have arrived
--   matches(key,...) -> bool          does this event payload concern key?
--                                      (omit -> re-check every pending key)
function Reactor.resource(opts)
    local perKey = {}      -- key -> { sig = signal, waiting = bool, value = latched }
    local subscribed = false
    -- Coalesced-dependency signal: bumps ONCE per batch resolution. A consumer
    -- that reads many keys in a loop should depend on epoch() (one edge) and read
    -- the keys via peek() (untracked), instead of get() per key (one edge per key
    -- => O(n) graph churn on every recompute -- the mass-item-resolution trap).
    local epoch = Reactor.signal(0)

    local function ensureSubscribed()
        if subscribed or not opts.event then return end
        if not eventSubscribe then
            error("Reactor.resource: opts.event set but no Reactor.setEventSource")
        end
        subscribed = true
        eventSubscribe(opts.event, function(...)
            -- FAST PATH: keyOf(...) names the ONE key this event concerns (e.g.
            -- the itemID in GET_ITEM_INFO_RECEIVED). Look it up + early-out BEFORE
            -- batching -- O(1), and no arg-table allocation on the (very common)
            -- event for a key we don't hold. This is the difference between cheap
            -- and thousands of O(n) scans (the 9-second freeze) since the game
            -- fires this event constantly for items that aren't ours.
            if opts.keyOf then
                local key = opts.keyOf(...)
                if key == nil then return end
                local entry = perKey[key]
                if not entry or not entry.waiting then return end
                Reactor.batch(function()
                    local v = opts.read(key)
                    if v ~= nil then
                        entry.waiting = false
                        entry.value = v
                        entry.sig(v)
                        epoch(epoch() + 1)
                    end
                end)
                return
            end
            -- FALLBACK: re-check every pending key in one batch (events that touch
            -- an unknown/whole set, e.g. a housing catalog warming). matches filters.
            local args, n = { ... }, select("#", ...)
            Reactor.batch(function()
                local resolved = false
                for key, entry in pairs(perKey) do
                    if entry.waiting and (not opts.matches or opts.matches(key, unpack(args, 1, n))) then
                        local v = opts.read(key)
                        if v ~= nil then
                            entry.waiting = false
                            entry.value = v
                            entry.sig(v) -- propagates to per-key (get) dependents
                            resolved = true
                        end
                    end
                end
                if resolved then epoch(epoch() + 1) end -- one bump for all epoch/peek dependents
            end)
        end)
    end

    local function ensureEntry(key)
        local entry = perKey[key]
        if not entry then
            local v = opts.read(key)
            if v ~= nil then
                entry = { sig = Reactor.signal(v), waiting = false, value = v }
            else
                entry = { sig = Reactor.signal(PENDING), waiting = true, value = PENDING }
                if opts.request then opts.request(key) end -- request-once (guarded by entry)
                ensureSubscribed()
            end
            perKey[key] = entry
        end
        return entry
    end

    -- get(key): reactive read -- links THIS key's signal into the caller.
    -- peek(key): untracked read of the same latched value -- links nothing; pair
    --   it with epoch() so a big per-item loop takes ONE dependency, not N.
    local function get(key) return ensureEntry(key).sig() end
    local function peek(key) return ensureEntry(key).value end

    -- Callable table: get(key) via __call, plus peek/epoch (see above) and
    -- invalidateAll() so a resource can re-resolve when data changes through a
    -- channel its `event` doesn't cover (housing catalog warming, a mount/pet/
    -- appearance collected). Re-reads every known key; a changed value propagates
    -- (signal equals dedups), a resolved key can flip -- fixing the "latched first
    -- value, stale until reload" class. Pending keys that still read nil stay waiting.
    -- CONTRACT: change-detection below is `v ~= entry.value` (reference equality),
    -- so invalidateAll is for SCALAR-returning resources (kind/collected: string/
    -- bool). A resource whose read() returns a fresh TABLE each call (e.g. nameRes
    -- {name,quality,bop}) would treat every key as "changed" every call -- if you
    -- wire such a resource to invalidateAll, give it an `equals` or compare fields.
    local api = { peek = peek }
    function api.epoch() return epoch() end
    function api.invalidateAll()
        Reactor.batch(function()
            local changed = false
            for key, entry in pairs(perKey) do
                local v = opts.read(key)
                if v ~= nil and v ~= entry.value then -- only ACTUAL changes bump the epoch
                    entry.waiting = false
                    entry.value = v
                    entry.sig(v) -- equals dedups; a changed value propagates
                    changed = true
                end
            end
            if changed then epoch(epoch() + 1) end -- wake epoch/peek dependents too
        end)
    end
    return setmetatable(api, { __call = function(_, key) return get(key) end })
end

Reactor.RESOURCE_VERSION = 1
