-- ============================================================================
-- VWB Layout - a composable box model (grid + flexbox), Reactor-FREE
-- ============================================================================
-- Describes a view's structure as DATA and positions frames from it. It is pure
-- geometry + SetPoint, with NO reactivity and NO widget registry. The VIEW
-- combines this (structure) with Reactor (content binding + resize). Five node
-- types, recursive -- any child can be any type, no fixed window/panel/slot depth:
--
--   grid  { columns, rows, cells = { { at={col,row,colSpan,rowSpan}, child } } }
--   stack { dir="row"|"col", gap, padding, justify, align, wrap, children = { ... } }
--   panel { chrome, headerHeight, header, body, footerHeight, footer }  (sugar)
--   free  { padding, children }  -- each child positioned by its own place/anchor
--   item  { id, role, size, place, anchor, overflow }  -- a leaf the view binds
--
-- Sizing on a child: size = { w = <px|"fill"|"hug">, h = <...> } (or "hug").
--   px    -> fixed.   "fill"/grow -> parent stack splits leftover / stretches.
--   "hug" -> intrinsic; measured via ctx.measure(node) (GetUnboundedStringWidth).
-- Flex on a stack child (main axis, CSS/Taffy semantics -- Layout.resolveFlex):
--   grow   = <n>   weight for leftover space ("fill"/grow=true == 1)
--   shrink = <n>   opt-in shrink weight (default 0 -> never shrinks; 1 == CSS default)
--   min / max = <px>   clamp the resolved main size (grow/shrink freeze at the bound)
-- wrap = true on a stack: children flow onto multiple lines (packed by basis until
--   the next would overflow), each line resolves flex + justify independently, and
--   lines stack along the cross axis. (The container needs enough cross space --
--   auto-height-from-wrapped-content is not computed intrinsically.)
-- Placement: place = { h="left|center|right", v="top|middle|bottom", dx, dy }
--   (9-point + offset, parent-relative) OR anchor = full SetPoint spec (parent
--   or a named sibling; a LIST of points for stretch/fill).
--
-- Geometry is PURE (resolveNode / computeGrid / computeStack / resolvePlace) so
-- it is headless-testable. build() applies the resolved tree to real frames.
-- Coordinate convention: x right-positive, y DOWN-positive (SetPoint negates y).
-- ============================================================================

local _, ns = ...
local Layout = {}

-- Chrome is FIRST-CLASS layout metadata (a node's `chrome = "Panel"`), not a
-- placeholder: the host registers an applier once and Layout calls it for every
-- node that declares chrome. Kept portable via injection (headless tests just
-- don't set it). Host: Layout.setChromeApplier(fn(frame, role)).
local chromeApplier = nil
function Layout.setChromeApplier(fn) chromeApplier = fn end

-- Default factory: what builds a node the view's makeFrame doesn't (returns nil
-- for). Host injects it (role-styled label / bare container). There is no themed
-- "placeholder" -- a view returns nil for what it doesn't own, and this renders
-- it per its role so gaps are visible. Portable via injection.
local defaultFactory = nil
function Layout.setDefaultFactory(fn) defaultFactory = fn end

-- ---------------------------------------------------------------------------
-- Spacing tokens: one scale to tune. A value is a number or a token string.
-- ---------------------------------------------------------------------------
local SPACE = { xs = 2, sm = 4, md = 6, lg = 8, xl = 10 } -- HDG's ramp (spacing pass 2026-07-13: md 8 / lg 12 / xl 16 read airy at panel scale)

local function resolveSpace(v)
    if v == nil then return 0 end -- exception(optional): omitted padding/gap = 0
    if type(v) == "number" then return v end
    return SPACE[v] or error("Layout: unknown spacing token '" .. tostring(v) .. "'")
end

-- pad -> { t, r, b, l }. Scalar = uniform; table = per-edge (omitted edge = 0).
local function padOf(pad)
    if type(pad) == "table" then
        return { t = resolveSpace(pad.top), r = resolveSpace(pad.right),
                 b = resolveSpace(pad.bottom), l = resolveSpace(pad.left) }
    end
    local p = resolveSpace(pad)
    return { t = p, r = p, b = p, l = p }
end

-- ---------------------------------------------------------------------------
-- Track math (grid + panel row split). A track is a number (px), "flex", or a
-- "NN%" string (fraction of the axis total).
-- ---------------------------------------------------------------------------
local function trackPx(t, total)
    if t == "flex" then return nil end
    if type(t) == "string" then
        local pct = t:match("^(%d+%.?%d*)%%$")
        if pct then return tonumber(pct) / 100 * total end
        error("Layout: bad track '" .. tostring(t) .. "'")
    end
    return t
end

local function resolveTracks(tracks, total, gap)
    local gaps = gap * math.max(0, #tracks - 1)
    local avail = total - gaps
    local fixed, flexCount, px = 0, 0, {}
    for i = 1, #tracks do
        px[i] = trackPx(tracks[i], total)
        if px[i] == nil then flexCount = flexCount + 1 else fixed = fixed + px[i] end
    end
    local flexSize = flexCount > 0 and math.max(0, (avail - fixed) / flexCount) or 0
    local sizes, offsets, x = {}, {}, 0
    for i = 1, #tracks do
        offsets[i] = x
        sizes[i] = px[i] or flexSize
        x = x + sizes[i] + gap
    end
    return sizes, offsets
end

local function spanTotal(sizes, from, count, gap)
    local total = 0
    for i = from, from + count - 1 do total = total + (sizes[i] or 0) end
    return total + gap * math.max(0, count - 1)
end

-- computeGrid(config, w, h) -> { name = { x, y, w, h } }. cells is a name->cell
-- map (v1 shape); the box-model grid branch adapts its {at,child} list to this.
function Layout.computeGrid(config, width, height)
    local pad = padOf(config.padding)
    local gap = resolveSpace(config.gap)
    local colSizes, colOff = resolveTracks(config.columns, width - pad.l - pad.r, gap)
    local rowSizes, rowOff = resolveTracks(config.rows, height - pad.t - pad.b, gap)

    local rects = {}
    for name, cell in pairs(config.cells) do
        rects[name] = {
            x = pad.l + colOff[cell.col],
            y = pad.t + rowOff[cell.row],
            w = spanTotal(colSizes, cell.col, cell.colSpan or 1, gap),
            h = spanTotal(rowSizes, cell.row, cell.rowSpan or 1, gap),
        }
    end
    return rects
end

-- ---------------------------------------------------------------------------
-- Intrinsic ("content") size -> { w, h }. Used by stack + free to size children.
--   item : explicit px used as-is; "fill" = 0 (grow/stretch resolves it);
--          "hug" or an OMITTED dim = measure(node) (natural text width/height).
--   stack: measured recursively (main axis = sum + gaps, cross = max child).
--   grid/free/panel: 0 (sized by their container) unless given an explicit px.
-- ---------------------------------------------------------------------------
local intrinsicSize

local function itemSize(node, measure)
    local sz = node.size
    if sz == "hug" then return measure(node) end
    sz = sz or {}
    local m
    if sz.w == nil or sz.w == "hug" or sz.h == nil or sz.h == "hug" then m = measure(node) end
    local function dim(v, mv)
        if type(v) == "number" then return v end
        if v == "fill" then return 0 end
        return mv -- "hug" or omitted -> measured
    end
    return { w = dim(sz.w, m and m.w or 0), h = dim(sz.h, m and m.h or 0) }
end

local function isContainer(t) return t == "stack" or t == "grid" or t == "free" or t == "panel" end

intrinsicSize = function(node, measure)
    if not isContainer(node.type) then return itemSize(node, measure) end
    if node.type == "stack" then
        local isRow = (node.dir or "row") == "row"
        local gap, pad = resolveSpace(node.gap), padOf(node.padding)
        local kids = node.children or {}
        local mainT, crossMax = 0, 0
        for _, c in ipairs(kids) do
            local s = intrinsicSize(c, measure)
            mainT = mainT + (isRow and s.w or s.h)
            crossMax = math.max(crossMax, isRow and s.h or s.w)
        end
        mainT = mainT + gap * math.max(0, #kids - 1)
        if isRow then return { w = mainT + pad.l + pad.r, h = crossMax + pad.t + pad.b } end
        return { w = crossMax + pad.l + pad.r, h = mainT + pad.t + pad.b }
    end
    local sz = type(node.size) == "table" and node.size or {}
    return { w = type(sz.w) == "number" and sz.w or 0, h = type(sz.h) == "number" and sz.h or 0 }
end

local function sizeOf(node, measure) return intrinsicSize(node, measure) end

-- flex-grow FACTOR (weight): numeric `grow`, `grow=true` -> 1, `size == "fill"` -> 1.
local function growFactor(node, isRow)
    if type(node.grow) == "number" then return node.grow end
    if node.grow then return 1 end
    local sz = node.size
    if type(sz) == "table" and (isRow and sz.w or sz.h) == "fill" then return 1 end
    return 0
end

-- CSS/Taffy "resolve flexible lengths" (single-line): distribute the main-axis
-- free space by grow factor (space to spare) or shrink factor x basis (overflow),
-- freezing any child that hits its min/max and redistributing the remainder.
-- Returns per-child resolved main sizes. `shrink` defaults to 0, so a fixed child
-- never shrinks unless it opts in -- existing layouts are unchanged.
local function resolveFlex(n, basis, grow, shrink, minS, maxS, innerMain, gaps)
    local size, frozen, sumBasis = {}, {}, 0
    for i = 1, n do size[i] = basis[i]; frozen[i] = false; sumBasis = sumBasis + basis[i] end
    local growing = (innerMain - gaps - sumBasis) >= 0
    -- A child with no factor in the active direction can't flex -> freeze at its
    -- (clamped) basis. (0 is truthy in Lua, so the active-factor pick is explicit.)
    for i = 1, n do
        local factor = growing and grow[i] or shrink[i]
        if factor == 0 then
            local s = basis[i]
            if minS[i] and s < minS[i] then s = minS[i] end
            if maxS[i] and s > maxS[i] then s = maxS[i] end
            size[i], frozen[i] = s, true
        end
    end
    for _ = 1, n do -- at most n passes: each min/max violation freezes >= 1 child
        local frozenMain, unfrozenBasis, sumFactor = 0, 0, 0
        for i = 1, n do
            if frozen[i] then frozenMain = frozenMain + size[i]
            else
                unfrozenBasis = unfrozenBasis + basis[i]
                sumFactor = sumFactor + (growing and grow[i] or shrink[i] * basis[i])
            end
        end
        if sumFactor <= 0 then break end
        local free = innerMain - gaps - frozenMain - unfrozenBasis
        local violated = false
        for i = 1, n do
            if not frozen[i] then
                local f = growing and grow[i] or shrink[i] * basis[i]
                local s = basis[i] + free * (f / sumFactor)
                if minS[i] and s < minS[i] then s, frozen[i], violated = minS[i], true, true
                elseif maxS[i] and s > maxS[i] then s, frozen[i], violated = maxS[i], true, true end
                size[i] = s
            end
        end
        if not violated then break end
    end
    return size
end

-- ---------------------------------------------------------------------------
-- Stack math (1D flexbox). Returns a per-child rect (container-relative), in
-- child declaration order. justify distributes the MAIN axis, align the CROSS.
-- ---------------------------------------------------------------------------
function Layout.computeStack(config, availW, availH, sizer)
    local isRow = (config.dir or "row") == "row"
    local pad = padOf(config.padding)
    local gap = resolveSpace(config.gap)
    local innerMain = isRow and (availW - pad.l - pad.r) or (availH - pad.t - pad.b)
    local innerCross = isRow and (availH - pad.t - pad.b) or (availW - pad.l - pad.r)
    local kids = config.children or {}
    local n = #kids

    -- Per-child flex inputs, measured once: main-axis basis + grow/shrink + min/max.
    local basis, crossSize, grow, shrink, minS, maxS = {}, {}, {}, {}, {}, {}
    for i = 1, n do
        local kid, s = kids[i], sizer(kids[i])
        basis[i]     = isRow and s.w or s.h
        crossSize[i] = isRow and s.h or s.w
        grow[i]      = growFactor(kid, isRow)
        shrink[i]    = kid.shrink or 0     -- opt-in; 0 = never shrink (preserves fixed layouts)
        minS[i], maxS[i] = kid.min, kid.max -- main-axis px clamps
    end

    -- Break children into lines. Single line unless `wrap` -- then greedily fill a
    -- line by basis until the next child would overflow innerMain, then start a new
    -- one (a child wider than the line still gets its own line).
    local lines = {}
    if config.wrap and n > 0 then
        local line, lineMain = { 1 }, basis[1]
        for i = 2, n do
            local grown = lineMain + gap + basis[i]
            if grown > innerMain and #line > 0 then
                lines[#lines + 1] = line; line, lineMain = { i }, basis[i]
            else
                line[#line + 1] = i; lineMain = grown
            end
        end
        lines[#lines + 1] = line
    else
        local all = {}; for i = 1, n do all[i] = i end
        lines[1] = all
    end

    -- Resolve + position each line independently; lines stack along the CROSS axis.
    local rects, align, crossCursor = {}, config.align or "start", 0
    for _, line in ipairs(lines) do
        local m = #line
        local lb, lg, ls, lmin, lmax, lineCross = {}, {}, {}, {}, {}, 0
        for j = 1, m do
            local idx = line[j]
            lb[j], lg[j], ls[j] = basis[idx], grow[idx], shrink[idx]
            lmin[j], lmax[j] = minS[idx], maxS[idx]
            lineCross = math.max(lineCross, crossSize[idx])
        end
        local gaps = gap * math.max(0, m - 1)
        local ms = resolveFlex(m, lb, lg, ls, lmin, lmax, innerMain, gaps)

        -- justify distributes whatever slack the flex pass left on THIS line.
        local used = gaps
        for j = 1, m do used = used + ms[j] end
        local slack, lead, extra, justify = innerMain - used, 0, 0, config.justify or "start"
        if slack > 0.5 then
            if justify == "center" then lead = slack / 2
            elseif justify == "end" then lead = slack
            elseif justify == "between" and m > 1 then extra = slack / (m - 1)
            elseif justify == "around" and m > 0 then extra = slack / m; lead = extra / 2 end
        end

        -- a wrapped line is only as tall as its own children; a single line fills
        -- the whole cross axis (unchanged single-line behaviour).
        local lineCrossH = config.wrap and lineCross or innerCross
        local cursor = lead
        for j = 1, m do
            local idx, msize, cs, co = line[j], ms[j], crossSize[line[j]], 0
            if cs == 0 or align == "stretch" then cs = lineCrossH -- 0 intrinsic ("fill") stretches cross
            elseif align == "center" then co = (lineCrossH - cs) / 2
            elseif align == "end" then co = lineCrossH - cs end
            local mainStart = (isRow and pad.l or pad.t) + cursor
            local crossStart = (isRow and pad.t or pad.l) + crossCursor + co
            if isRow then
                rects[idx] = { x = mainStart, y = crossStart, w = msize, h = cs }
            else
                rects[idx] = { x = crossStart, y = mainStart, w = cs, h = msize }
            end
            cursor = cursor + msize + gap + extra
        end
        crossCursor = crossCursor + lineCross + gap
    end
    return rects
end

-- ---------------------------------------------------------------------------
-- 9-point place (+ offset) -> a container-relative rect for a sized child.
-- ---------------------------------------------------------------------------
local FRAC_H = { left = 0, center = 0.5, right = 1 }
local FRAC_V = { top = 0, middle = 0.5, bottom = 1 }

function Layout.resolvePlace(place, cw, ch, regionW, regionH)
    place = place or {}
    local fh = FRAC_H[place.h or "left"] or error("Layout: bad place.h '" .. tostring(place.h) .. "'")
    local fv = FRAC_V[place.v or "top"] or error("Layout: bad place.v '" .. tostring(place.v) .. "'")
    return {
        x = fh * (regionW - cw) + (place.dx or 0),
        y = fv * (regionH - ch) + (place.dy or 0),
        w = cw, h = ch,
    }
end

-- ---------------------------------------------------------------------------
-- Recursive resolve. Returns a tree mirroring the config:
--   { node, id, rect = {x,y,w,h} | nil, anchor = spec | nil, size = {w,h} | nil,
--     children = { <resolved child>, ... } }
-- rect is relative to the node's parent frame; anchor nodes carry a SetPoint
-- spec instead (geometry solved by WoW at draw time). measure(node) -> {w,h}.
-- ---------------------------------------------------------------------------
local function resolveNode(node, w, h, measure)
    local t = node.type or error("Layout: node missing type")
    local out = { node = node, id = node.id, children = {} }

    if t == "item" then
        return out -- leaf; parent set rect/anchor

    elseif t == "grid" then
        local cfg = { padding = node.padding, gap = node.gap,
                      columns = node.columns, rows = node.rows, cells = {} }
        local childOf = {}
        for i, cell in ipairs(node.cells) do
            local key = "c" .. i
            cfg.cells[key] = { col = cell.at.col, row = cell.at.row,
                               colSpan = cell.at.colSpan, rowSpan = cell.at.rowSpan }
            childOf[key] = cell.child
        end
        local rects = Layout.computeGrid(cfg, w, h)
        for key, child in pairs(childOf) do
            local r = rects[key]
            local rc = resolveNode(child, r.w, r.h, measure)
            rc.rect = r
            out.children[#out.children + 1] = rc
        end

    elseif t == "stack" then
        local rects = Layout.computeStack(node, w, h, function(c) return sizeOf(c, measure) end)
        for i, child in ipairs(node.children or {}) do
            local rc = resolveNode(child, rects[i].w, rects[i].h, measure)
            rc.rect = rects[i]
            out.children[#out.children + 1] = rc
        end

    elseif t == "panel" then
        -- desugar to a vertical split: header (fixed) / body (flex) / footer (fixed)
        local regions = {}
        if node.header then regions[#regions + 1] = { child = node.header, size = node.headerHeight or 30 } end
        if node.body   then regions[#regions + 1] = { child = node.body,   size = "flex" } end
        if node.footer then regions[#regions + 1] = { child = node.footer, size = node.footerHeight or 22 } end
        local pad = padOf(node.padding)
        local gap = resolveSpace(node.gap)
        local rowTracks = {}
        for i = 1, #regions do rowTracks[i] = regions[i].size end
        local rowSizes, rowOff = resolveTracks(rowTracks, h - pad.t - pad.b, gap)
        local innerW = w - pad.l - pad.r
        for i, reg in ipairs(regions) do
            local rc = resolveNode(reg.child, innerW, rowSizes[i], measure)
            rc.rect = { x = pad.l, y = pad.t + rowOff[i], w = innerW, h = rowSizes[i] }
            out.children[#out.children + 1] = rc
        end

    elseif t == "free" then
        local pad = padOf(node.padding)
        local rw, rh = w - pad.l - pad.r, h - pad.t - pad.b
        for _, child in ipairs(node.children or {}) do
            local s = sizeOf(child, measure)
            local cw = s.w > 0 and s.w or rw -- 0 intrinsic = fill the region
            local ch = s.h > 0 and s.h or rh
            local rc = resolveNode(child, cw, ch, measure)
            rc.size = { w = cw, h = ch }
            if child.anchor then
                rc.anchor = child.anchor
            else
                local r = Layout.resolvePlace(child.place, cw, ch, rw, rh)
                r.x, r.y = r.x + pad.l, r.y + pad.t
                rc.rect = r
            end
            out.children[#out.children + 1] = rc
        end

    else
        error("Layout: unknown node type '" .. tostring(t) .. "'")
    end

    return out
end
Layout.resolveNode = resolveNode

-- ---------------------------------------------------------------------------
-- Frame apply (WoW). ctx = {
--   makeFrame(node, parentFrame, byId) -> frame  (view supplies the widget),
--   measure(node) -> {w,h}   (optional; only needed if any node hugs content),
-- }
-- ---------------------------------------------------------------------------
local ROLE_OVERFLOW = { title = "ellipsis", subtitle = "ellipsis",
                        section = "ellipsis", label = "ellipsis", body = "wrap" }

local function applyOverflow(frame, node)
    if node.type ~= "item" then return end
    local ov = node.overflow or ROLE_OVERFLOW[node.role]
    if not ov then return end
    if ov == "ellipsis" and frame.SetWordWrap then -- exception(boundary): SetWordWrap only on FontString regions
        frame:SetWordWrap(false)
    elseif ov == "wrap" and frame.SetWordWrap then
        frame:SetWordWrap(true)
        if node.maxLines and frame.SetMaxLines then frame:SetMaxLines(node.maxLines) end
    elseif ov == "clip" and frame.SetClipsChildren then
        frame:SetClipsChildren(true)
    end
end

local function applyAnchor(frame, anchor, parentFrame, byId)
    local points = anchor.points or { anchor }
    for _, a in ipairs(points) do
        local target = (a.to == nil or a.to == "parent") and parentFrame
            or byId[a.to] or error("Layout: anchor target '" .. tostring(a.to) .. "' not built yet")
        frame:SetPoint(a.from, target, a.at, a.dx or 0, a.dy or 0)
    end
end

-- build(container, node, ctx) -> { byId, root, relayout }. Frames are created
-- ONCE (cached per config node) and only re-positioned on relayout(), so a
-- resize never leaks frames. relayout() re-resolves geometry at the container's
-- current size (view drives it from OnSizeChanged or a Reactor size signal).
function Layout.build(container, node, ctx)
    local measure = ctx.measure or function() return { w = 0, h = 0 } end
    local byId, frameOf = {}, {}

    local function ensure(cfgNode, parentFrame)
        local f = frameOf[cfgNode]
        if not f then
            f = ctx.makeFrame(cfgNode, parentFrame, byId)
            if not f then -- view doesn't own this node -> engine default (role label / container)
                f = (defaultFactory or error("Layout: makeFrame returned nil and no defaultFactory set"))(cfgNode, parentFrame)
            end
            frameOf[cfgNode] = f
            if cfgNode.id then byId[cfgNode.id] = f end
            applyOverflow(f, cfgNode)
            if cfgNode.chrome and chromeApplier then chromeApplier(f, cfgNode.chrome) end
        end
        return f
    end

    local function apply(rc, parentFrame)
        local frame = ensure(rc.node, parentFrame)
        frame:ClearAllPoints()
        if rc.anchor then
            applyAnchor(frame, rc.anchor, parentFrame, byId)
            if rc.size and not (rc.anchor.points and #rc.anchor.points >= 2) then
                frame:SetSize(rc.size.w, rc.size.h)
            end
        else
            local r = rc.rect
            frame:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", r.x, -r.y)
            frame:SetSize(r.w, r.h)
        end
        for _, child in ipairs(rc.children) do apply(child, frame) end
        return frame
    end

    local root
    local function paint()
        local w, h = container:GetWidth(), container:GetHeight()
        local tree = resolveNode(node, w, h, measure)
        -- the root has no parent to place it; its frame fills the container
        if not tree.rect and not tree.anchor then tree.rect = { x = 0, y = 0, w = w, h = h } end
        root = apply(tree, container)
    end
    paint()
    return { byId = byId, root = root, relayout = paint }
end

Layout.VERSION = 2

if ns then ns.Layout = Layout end
return Layout
