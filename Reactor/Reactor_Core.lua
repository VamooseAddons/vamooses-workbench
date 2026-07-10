-- ============================================================================
-- Reactor - a portable fine-grained reactivity core (Vamoose's Workbench)
-- ============================================================================
-- Signals + computeds + effects with AUTOMATIC dependency tracking, glitch-free
-- and lazy. Disposal via Fusion-0.3-style scopes. Vendored per-addon (NOT a
-- shared lib): namespace-injected, zero deps, version-stamped for backports.
--
-- Algorithm: the "reactively" clean/check/dirty coloring (Milo Mighdoll), the
-- correct + readable cousin of alien-signals' push-pull. A signal write PUSHES
-- staleness down the graph (direct dependents -> DIRTY, transitive -> CHECK);
-- a read PULLS lazily, only recomputing a CHECK node if a source actually
-- changed. That laziness + coloring is what makes it glitch-free (a shared
-- upstream can't make a downstream recompute twice or see a torn value).
--
-- Constraints kept modest on purpose for a first cut: correctness over the
-- no-alloc/no-recursion micro-optimisations alien-signals uses. Those are a
-- later tuning pass, guarded by the same tests.
-- ============================================================================

local _, ns = ...

local CLEAN, CHECK, DIRTY = 0, 1, 2

-- Execution context (module-locals; single-threaded WoW Lua)
local currentObserver = nil   -- the computed/effect whose fn is running (for tracking)
local currentScope = nil      -- disposal scope collecting nodes created here
local nextToken = 0           -- GLOBAL monotonic compute id; per-pass link dedup
local batchDepth = 0
local pendingEffects = {}      -- effects marked stale, awaiting flush
local flushScheduled = false   -- WoW: coalesce to one frame; headless: immediate
local instrument = nil         -- optional recompute wrapper (profiler); nil = zero overhead
local flushObserver = nil      -- optional flush-boundary hook (profiler); nil = zero overhead

local function defaultEquals(a, b) return a == b end

-- ---------------------------------------------------------------------------
-- Dependency graph plumbing
-- ---------------------------------------------------------------------------

-- Drop every source->observer link for this node (called before a recompute so
-- dynamic dependencies are re-derived fresh each run).
local function unlinkSources(node)
    local srcs = node.sources
    if not srcs then node.sources = {}; return end
    for i = 1, #srcs do
        local obs = srcs[i].observers
        for j = #obs, 1, -1 do
            if obs[j] == node then table.remove(obs, j); break end
        end
    end
    node.sources = {}
end

-- Called by signal/computed reads: link the dep into the running observer.
-- Deduped per-recompute via computeToken so reading a signal twice links once.
local function track(dep)
    local obs = currentObserver
    if not obs then return end
    if dep._linkedAt == obs.computeToken then return end
    dep._linkedAt = obs.computeToken
    local srcs = obs.sources
    srcs[#srcs + 1] = dep
    local dobs = dep.observers
    dobs[#dobs + 1] = obs
end

-- Push staleness. A signal write calls markStale(observer, DIRTY) for each
-- direct dependent; those recurse markStale(theirObserver, CHECK).
local function markStale(node, state)
    if node.state < state then
        local wasClean = node.state == CLEAN
        node.state = state
        if wasClean then
            local obs = node.observers
            for i = 1, #obs do markStale(obs[i], CHECK) end
            if node.kind == "effect" and not node.disposed then
                pendingEffects[#pendingEffects + 1] = node
            end
        end
    end
end

local recompute -- fwd

-- Lazy pull: ensure a node is up to date before its value is read.
local function updateIfNecessary(node)
    if node.state == CHECK then
        local srcs = node.sources
        for i = 1, #srcs do
            updateIfNecessary(srcs[i])
            if node.state == DIRTY then break end -- a source recompute marked us dirty
        end
    end
    if node.state == DIRTY then recompute(node) end
    node.state = CLEAN
end

recompute = function(node)
    if node.cleanup then
        local c = node.cleanup; node.cleanup = nil; c()
    end
    unlinkSources(node)
    nextToken = nextToken + 1        -- globally unique so distinct nodes' tokens
    node.computeToken = nextToken    -- never collide (the per-node-counter bug)

    local prevObserver, prevScope = currentObserver, currentScope
    currentObserver = node
    currentScope = node.scope or currentScope
    -- NO pcall (fail-loud policy; owner ruling 2026-07-06: one pcall exception
    -- metastasizes). A throw in node.fn does NOT restore currentObserver/scope.
    -- ACCEPTED, BOUNDED limitation: the flush's save/restore already isolates
    -- flush execution, so the only residual harm is a slow leak -- a TOP-LEVEL
    -- read (outside any effect/computed) after a throw would link to this now-
    -- dead node. Top-level reads are rare (bindings read inside effects), so
    -- this is accepted; revisit only if profiling shows it bites. The error
    -- itself still surfaces loud, as intended.
    local result
    if instrument then
        result = instrument(node, node.fn) -- profiler wraps + times node.fn; nil path = zero overhead
    else
        result = node.fn()
    end
    currentObserver = prevObserver
    currentScope = prevScope

    if node.kind == "computed" then
        if not node.equals(node.value, result) then
            node.value = result
            local obs = node.observers
            for i = 1, #obs do markStale(obs[i], DIRTY) end
        end
    else -- effect: result may be a cleanup fn
        node.cleanup = (type(result) == "function") and result or nil
    end
end

-- ---------------------------------------------------------------------------
-- Flush (effect scheduler)
-- ---------------------------------------------------------------------------
-- Headless/default: synchronous. WoW installs a frame-driven flusher via
-- Reactor.setScheduler so many events in one frame coalesce to one flush.

-- Public interface. Declared here in ONE place so the type checker resolves the
-- whole surface even though methods are attached across Reactor_Core/_Resource/
-- _Bind -- otherwise every R.bindText / R.resource / R.epoch reads as an
-- undefined field. (Comments only; no runtime effect.)
---@class Reactor
---@field signal fun(initial:any, equals?:function):function
---@field computed fun(fn:function, equals?:function, label?:string):function
---@field named fun(label:string, fn:function, equals?:function):function
---@field effect fun(fn:function, label?:string):function
---@field scope fun(fn:function):table
---@field onCleanup fun(fn:function)
---@field dispose fun(scope:table)
---@field batch fun(fn:function)
---@field untrack fun(fn:function):any
---@field flush fun()
---@field resource fun(opts:table):any
---@field PENDING any
---@field isPending fun(v:any):boolean
---@field bindText fun(fs:any, fn:function):function
---@field bindShown fun(frame:any, fn:function):function
---@field bindColor fun(fs:any, fn:function):function
---@field bindTexture fun(tex:any, fn:function):function
---@field bindCall fun(obj:any, method:string, fn:function):function
---@field bindList fun(itemsFn:function, opts:table)
---@field setLogger fun(fn:function)
---@field setScheduler fun(deferFn:function)
---@field setInstrument fun(fn?:function)
---@field setFlushObserver fun(fn?:function)
---@field setEventSource fun(fn:function)
---@field VERSION integer
---@field RESOURCE_VERSION integer
local Reactor = {}

-- Optional diagnostics sink (set later via Reactor.setLogger). Reactor logs
-- serious events (recursion cap) here BEFORE erroring, so the diagnostic is
-- durable even if the error() is swallowed by an upstream handler.
local logger = nil
local function log(level, msg) if logger then logger(level, msg) end end

local flushing = false
-- Vue-style PER-EFFECT recursion detection: if one effect re-runs more than
-- this many times inside a single flush it's mutating its own dependencies
-- (directly or via a mutual-write loop). Naming the count is more precise than
-- a coarse global iteration cap.
local RECURSION_LIMIT = 100

local function runFlush()
    -- Synchronous-scheduler safety: an effect that writes a signal during its
    -- run must NOT re-enter the flush; the already-running loop drains newly
    -- appended effects. (WoW uses the deferred setScheduler path, the TC39
    -- model where a write only schedules and bodies run at a boundary.)
    if flushing then return end
    flushing = true
    flushScheduled = false
    -- A flush can begin mid-recompute of an EFFECT (effects may write signals).
    -- Save/restore the tracking context so flushed effects track cleanly
    -- without stranding the in-progress recompute.
    local savedObserver, savedScope = currentObserver, currentScope
    currentObserver, currentScope = nil, nil
    local flushDone = flushObserver and flushObserver() or nil -- host brackets flush timing
    local flushCount = 0
    local runCounts = {}
    local i = 1
    while i <= #pendingEffects do
        local e = pendingEffects[i]; i = i + 1
        if not e.disposed then
            local c = (runCounts[e] or 0) + 1
            runCounts[e] = c
            if c > RECURSION_LIMIT then
                for k = #pendingEffects, 1, -1 do pendingEffects[k] = nil end
                currentObserver, currentScope = savedObserver, savedScope
                flushing = false
                local who = e.label and ("effect '" .. e.label .. "'") or "an unlabeled effect"
                local msg = "Reactor: " .. who .. " re-ran >" .. RECURSION_LIMIT ..
                    " times in one flush -- a reactive loop (it mutates a dependency, directly or via a mutual write)"
                log("error", msg) -- durable, before the throw
                error(msg)
            end
            updateIfNecessary(e)
            flushCount = flushCount + 1
        end
    end
    for k = #pendingEffects, 1, -1 do pendingEffects[k] = nil end
    currentObserver, currentScope = savedObserver, savedScope
    flushing = false
    if flushDone then flushDone(flushCount) end
end

local scheduleFlush = runFlush -- default immediate; overridable

-- Host wires this to its Log (e.g. VWB.Log:Error). See `log` above.
function Reactor.setLogger(fn) logger = fn end

-- WoW hooks a deferred flusher here: fn(runFlush) should arrange for runFlush
-- to be called once, later this frame (e.g. C_Timer.After(0, runFlush) or an
-- OnUpdate one-shot). Keeps the core WoW-agnostic + headless-testable.
function Reactor.setScheduler(deferFn)
    scheduleFlush = function()
        if flushScheduled then return end
        flushScheduled = true
        deferFn(runFlush)
    end
end

local function requestFlush()
    if batchDepth > 0 then return end
    if #pendingEffects > 0 then scheduleFlush() end
end

-- Profiler seams (nil = zero overhead; one nil-check when off). setInstrument's
-- fn wraps each recompute: fn(node, thunk) MUST call thunk() and return its
-- result -- the host reads node.kind/node.label and times thunk(). setFlushObserver's
-- fn is called at each flush START and returns a done(count) callback invoked at
-- flush END, so the host can bracket-time the whole flush. debugprofilestop lives
-- in the host, never here (Reactor stays portable + headless-testable).
function Reactor.setInstrument(fn) instrument = fn end
function Reactor.setFlushObserver(fn) flushObserver = fn end

-- ---------------------------------------------------------------------------
-- Public primitives
-- ---------------------------------------------------------------------------

-- signal(v[, equals]) -> callable. s() reads (tracks); s(v) writes.
function Reactor.signal(initial, equals)
    local node = {
        kind = "signal", value = initial, observers = {},
        state = CLEAN, computeToken = 0, equals = equals or defaultEquals,
    }
    return function(...)
        if select("#", ...) == 0 then
            track(node)
            return node.value
        end
        local v = ...
        -- Purity (TC39/Vue model): computeds must be read-only. Writing a
        -- signal while a COMPUTED is evaluating is a bug -- surface it loud.
        -- Effects (side-effect sinks) may write.
        if currentObserver and currentObserver.kind == "computed" then
            error("Reactor: a computed wrote a signal -- computeds must be pure (read-only); use an effect for writes")
        end
        if not node.equals(node.value, v) then
            node.value = v
            local obs = node.observers
            for i = 1, #obs do markStale(obs[i], DIRTY) end
            requestFlush()
        end
    end
end

local function registerDisposable(node)
    if currentScope then
        local d = currentScope.disposables
        d[#d + 1] = function()
            node.disposed = true
            if node.cleanup then local c = node.cleanup; node.cleanup = nil; c() end
            unlinkSources(node)
        end
    end
end

-- computed(fn[, equals[, label]]) -> callable getter. Lazy + memoized. `label`
-- is optional and only names the node for the profiler (nil otherwise).
function Reactor.computed(fn, equals, label)
    local node = {
        kind = "computed", fn = fn, value = nil, observers = {}, sources = {},
        state = DIRTY, computeToken = 0, equals = equals or defaultEquals,
        scope = currentScope, label = label,
    }
    registerDisposable(node)
    return function()
        updateIfNecessary(node)
        track(node)
        return node.value
    end
end

-- named(label, fn[, equals]) -> computed with a profiler label read FIRST -- the
-- same node as computed(fn, equals, label), just easier to read at call sites.
function Reactor.named(label, fn, equals) return Reactor.computed(fn, equals, label) end

-- effect(fn[, label]) -> dispose(). Runs now, re-runs when tracked deps change.
-- fn may return a cleanup fn (run before each re-run and on dispose). `label`
-- names the effect in the recursion-loop diagnostic.
function Reactor.effect(fn, label)
    local node = {
        kind = "effect", fn = fn, observers = {}, sources = {},
        state = DIRTY, computeToken = 0, scope = currentScope, label = label,
    }
    registerDisposable(node)
    updateIfNecessary(node) -- run immediately, establishing deps
    return function()
        node.disposed = true
        if node.cleanup then local c = node.cleanup; node.cleanup = nil; c() end
        unlinkSources(node)
    end
end

-- ---------------------------------------------------------------------------
-- Scopes (Fusion 0.3 style disposal) + batch + untrack
-- ---------------------------------------------------------------------------

-- scope(fn) runs fn(scopeHandle) with a fresh disposal scope; every computed/
-- effect created inside is torn down by Reactor.dispose(scopeHandle). Nest for
-- things that die at different times (e.g. a pooled row's bindings).
function Reactor.scope(fn)
    local s = { disposables = {}, disposed = false }
    local prev = currentScope
    currentScope = s
    fn(s)
    currentScope = prev
    return s
end

-- Register an arbitrary teardown with the current scope (for resources a
-- bind owns that aren't themselves effects -- e.g. bindList's pooled rows).
function Reactor.onCleanup(fn)
    if currentScope then
        local d = currentScope.disposables
        d[#d + 1] = fn
    end
end

function Reactor.dispose(s)
    if s.disposed then return end
    s.disposed = true
    local d = s.disposables
    for i = #d, 1, -1 do d[i]() end
    s.disposables = {}
end

function Reactor.batch(fn)
    batchDepth = batchDepth + 1
    fn()
    batchDepth = batchDepth - 1
    requestFlush()
end

function Reactor.untrack(fn)
    local prev = currentObserver
    currentObserver = nil
    local a, b, c = fn()
    currentObserver = prev
    return a, b, c
end

-- Test/host hook: force a synchronous flush (headless tests; deferred schedulers)
function Reactor.flush() runFlush() end

Reactor.VERSION = 1

if ns then ns.Reactor = Reactor end
return Reactor
