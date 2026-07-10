-- ============================================================================
-- VamoosesWorkbench - Debug view. A dev-only nav tab (shown only while debug is
-- on). A [Perf | Debug] segmented toggle picks which report VWB.Debug builds;
-- the body is a scrollable read-only text dump. No reactive bindings on the
-- debug data (a signal write from a profiled recompute would be a bug) -- the
-- body re-renders on a throttled OnUpdate that only ticks while the tab is shown.
-- ============================================================================

local _, ns = ...
local Debug = ns.Debug

local REFRESH_INTERVAL = 0.5

function Debug.buildView(container)
    local root = CreateFrame("Frame", nil, container, "BackdropTemplate")
    root:SetAllPoints(container)
    root:SetBackdrop(VWB.Theme.BACKDROP_FLAT) -- so the Panel skinner has a backdrop to colour
    VWB.Theme:Register(root, "Panel")

    local mode = "perf"

    -- Body first, so the toggle's onSelect can close over render() directly.
    local scroll = CreateFrame("ScrollFrame", nil, root, "InputScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -34)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6) -- gap for the scrollbar
    local eb = scroll.EditBox
    eb:SetFontObject(ChatFontNormal) -- exception(boundary): Blizzard global Font object
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0) -- unlimited: a long perf report must not silently truncate
    if scroll.CharCount then scroll.CharCount:Hide() end

    -- toTop: reset scroll (mode switch / reset / first paint). The throttled
    -- auto-refresh PRESERVES the scroll offset -- otherwise reading past the first
    -- screen was yanked back to the top every REFRESH_INTERVAL.
    local function render(toTop)
        local off = toTop and 0 or scroll:GetVerticalScroll()
        eb:SetText(mode == "perf" and Debug:PerfReport() or Debug:DebugReport())
        scroll:SetVerticalScroll(off)
    end

    local toggle = VWB.UI:CreateSegmentedToggle(root, {
        width = 150, height = 22,
        segments = { { key = "perf", label = "Perf" }, { key = "debug", label = "Debug" } },
        default = "perf",
        onSelect = function(key) mode = key; render(true) end,
    })
    toggle:SetPoint("TOPLEFT", 6, -6)

    local resetBtn = VWB.UI:CreateButton(root, "Reset", 60, 20)
    resetBtn:SetPoint("LEFT", toggle, "RIGHT", 12, 0)
    resetBtn:SetScript("OnClick", function() Debug:Reset(); render(true) end)

    local gcBtn = VWB.UI:CreateButton(root, "Force GC", 72, 20)
    gcBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
    gcBtn:SetScript("OnClick", function() collectgarbage("collect"); render() end)

    -- OnUpdate only fires while the frame is shown, so this costs nothing on
    -- other tabs. No C_Timer (UI-timer policy).
    local acc = 0
    root:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < REFRESH_INTERVAL then return end
        acc = 0
        render() -- preserve scroll on the poll
    end)
    render(true) -- first paint: top

    return { root = root }
end
