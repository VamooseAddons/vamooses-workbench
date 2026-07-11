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

---@type fun(event:string, handler:function):function
local eventSubscribe = nil -- fn(event, handler) -> unsubscribe; set by the host bridge
function Reactor.setEventSource(fn) eventSubscribe = fn end

-- Public boundary subscription through the injected event source (WoW frame
-- in production, mock in tests). Handlers are Constitution R2 boundary
-- handlers: they latch and return. Calling before the host installs an event
-- source is a wiring bug -- let it error loud.
function Reactor.subscribeEvent(event, handler)
    return eventSubscribe(event, handler)
end

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
                        Reactor.untrack(function() epoch(epoch() + 1) end) -- no dep edge if inside a computed
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
                if resolved then Reactor.untrack(function() epoch(epoch() + 1) end) end -- no dep edge if inside a computed
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

    -- Callable table: get(key) via __call, plus peek/epoch (see above).
    -- invalidateAll was DELETED here (Constitution migration step 4): its
    -- semantic -- lazy re-read of stored per-key state on a bulk event -- is
    -- the latch-at-boundary violation that fed 2026-07-11's request loops.
    -- Domains latch forward now (latchMap below): scoped events reconcile one
    -- key; genuinely bulk events sweep-and-re-latch eagerly at the boundary,
    -- where equality dedup makes the unchanged majority silent.
    local api = { peek = peek }
    function api.epoch() return epoch() end
    return setmetatable(api, { __call = function(_, key) return get(key) end })
end

-- ============================================================================
-- latchMap (sync keyed latch store) -- Constitution R3's engine half
-- ============================================================================
-- The latch-forward store for BOUNDARY handlers (Constitution R2/R3, see the
-- header of Reactor_Core.lua): an event handler computes a value at the
-- moment of truth and latches it per key. Equality dedup makes an unchanged
-- value produce ZERO propagation, and the aggregate epoch bumps ONLY inside
-- a real change -- "something happened" is inexpressible here, only
-- "something changed" is. Consumers either get(key) (fine-grained edge) or
-- subscribe epoch() and walk via peek() (aggregate consumers, one edge).
-- Portable: no WoW API, no async. Pairs with resource() (async acquisition);
-- addon-layer brokers compose both.
function Reactor.latchMap(name)
    local values = {}  -- key -> last latched value (authoritative, incl. false)
    local has = {}     -- key -> true once latched (false-vs-never distinction)
    local perKey = {}  -- key -> signal, created on first tracked get()
    local epoch = Reactor.signal(0)
    local store = { name = name or "latchMap" }

    -- Boundary-side write. Returns true when the value actually changed.
    function store:latch(key, value)
        if has[key] and values[key] == value then return false end
        has[key] = true
        values[key] = value
        local sig = perKey[key]
        if sig then sig(value) end
        epoch(epoch() + 1) -- engine-owned aggregate: bumps ONLY on real change
        return true
    end

    function store:get(key) -- tracked per-key read
        local sig = perKey[key]
        if not sig then
            sig = Reactor.signal(values[key])
            perKey[key] = sig
        end
        return sig()
    end

    function store:peek(key) return values[key] end
    function store:hasKey(key) return has[key] == true end
    store.epoch = function() return epoch() end

    -- HUMAN escape hatch ONLY (Constitution R5: retry is a human act). The
    -- one legitimate caller class is an explicit user refresh action
    -- (Settings' "Refresh Transmog Cache") that wants walkers to re-derive
    -- from latches. MACHINE paths may never call this -- an event handler
    -- bumping it is the banned changeless-counter pattern (R3).
    function store:forceBump()
        epoch(epoch() + 1)
    end

    return store
end

Reactor.RESOURCE_VERSION = 1
