-- The app-shell LayoutConfig resolves: sidebar (fixed 160) | content (flex),
-- status bar full-width along the bottom. Run: lua layout_shell_config_test.lua
local base = arg[0]:gsub("tests/layout_shell_config_test%.lua$", "")
local Layout = dofile(base .. "Layout/Layout.lua")
local LC = dofile(base .. "Layout/LayoutConfig_Shell.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.5 end
local function find(rc, id) for _, c in ipairs(rc.children) do if c.id == id then return c end end end

local root = Layout.resolveNode(LC.shell, 1040, 616, function() return { w = 0, h = 0 } end)
local sidebar, content, status = find(root, "sidebar"), find(root, "content"), find(root, "status")

check("sidebar fixed 160 on the left", near(sidebar.rect.w, 160) and near(sidebar.rect.x, 0))
check("content flexes right of sidebar", near(content.rect.w, 880) and near(content.rect.x, 160))
check("sidebar + content share the body height", near(sidebar.rect.h, 594) and near(content.rect.h, 594))
check("status bar full width along the bottom", near(status.rect.w, 1040) and near(status.rect.y, 594) and near(status.rect.h, 22))

print(string.format("Shell config: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
