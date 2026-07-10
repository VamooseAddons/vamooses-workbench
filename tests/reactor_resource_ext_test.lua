-- Extended resource tests: invalidateAll(filter) partial re-read, and the
-- scalar-contract assert (table return without custom equals -> loud error).
-- Run: lua reactor_resource_ext_test.lua

local base = arg[0]:gsub("tests/reactor_resource_ext_test%.lua$", "")

local function newR()
    local R = dofile(base .. "Reactor/Reactor_Core.lua")
    loadfile(base .. "Reactor/Reactor_Resource.lua")("VWB", { Reactor = R })
    return R
end

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. name) end
end

-- 1. invalidateAll(filter): only matching keys are re-read -------------------
do
    local R = newR()
    local db = { a = "v1", b = "v2", c = "v3" }
    local readCalls = {} -- track which keys were read during invalidateAll
    local Res = R.resource({
        read = function(k)
            readCalls[k] = (readCalls[k] or 0) + 1
            return db[k]
        end,
    })
    -- Prime all three keys into perKey
    local va, vb, vc
    R.effect(function() va = Res("a") end)
    R.effect(function() vb = Res("b") end)
    R.effect(function() vc = Res("c") end)
    check("filter: all primed", va == "v1" and vb == "v2" and vc == "v3")

    -- Update only "b" and "c" in the backing store
    db.b = "v2-new"; db.c = "v3-new"
    local readsBefore = { a = readCalls.a or 0, b = readCalls.b or 0, c = readCalls.c or 0 }
    -- invalidateAll with filter: only re-read "b"
    Res.invalidateAll(function(key) return key == "b" end)
    check("filter: only 'b' re-read", (readCalls.b or 0) == readsBefore.b + 1)
    check("filter: 'a' NOT re-read", (readCalls.a or 0) == readsBefore.a)
    check("filter: 'c' NOT re-read (filtered out)", (readCalls.c or 0) == readsBefore.c)
    check("filter: 'b' value updated", vb == "v2-new")
    check("filter: 'a' value unchanged", va == "v1")
    check("filter: 'c' value unchanged (not re-read)", vc == "v3") -- c was not re-read

    -- Now re-read "c" too
    Res.invalidateAll(function(key) return key == "c" end)
    check("filter: 'c' now updated after second pass", vc == "v3-new")
end

-- 2. invalidateAll no-arg still works (original contract unbroken) -----------
do
    local R = newR()
    local db2 = { x = "x1", y = "y1" }
    local Res2 = R.resource({
        read = function(k) return db2[k] end,
    })
    local vx, vy
    R.effect(function() vx = Res2("x") end)
    R.effect(function() vy = Res2("y") end)
    check("no-arg: initial", vx == "x1" and vy == "y1")
    db2.x = "x2"; db2.y = "y2"
    Res2.invalidateAll() -- no filter -> re-reads all
    check("no-arg: both updated", vx == "x2" and vy == "y2")
end

-- 3. SCALAR CONTRACT: resource without custom equals returns a table ->
--    invalidateAll errors loud (fail-loud house rule). Use a fresh R instance
--    so the pcall's batch-depth leak does NOT bleed into subsequent tests.
do
    local R = newR()
    local tableDb = { k1 = { v = 1 } }
    local TableRes = R.resource({
        read = function(k) return tableDb[k] end,
        -- NO opts.equals -> triggers the scalar-contract assert
    })
    local val
    R.effect(function() val = TableRes("k1") end)
    check("scalar-assert: initial table value readable", type(val) == "table")

    -- Trigger invalidateAll; the read() returns a table, no equals -> must error.
    -- NOTE: the error is thrown inside Reactor.batch, which leaks batchDepth on throw.
    -- Using a fresh R instance above contains the leak to this block only.
    tableDb.k1 = { v = 2 } -- change the table so v ~= entry.value
    local ok, err = pcall(function() TableRes.invalidateAll() end)
    check("scalar-assert: errors without custom equals", not ok)
    check("scalar-assert: error names the contract", type(err) == "string" and
        err:find("custom equals", 1, true) ~= nil)
    check("scalar-assert: error names the key", type(err) == "string" and
        err:find("k1", 1, true) ~= nil)
end

-- 4. SCALAR CONTRACT: resource WITH custom equals returns a table -> NO error --
do
    local R = newR()
    local tableDb2 = { p = { n = 1 } }
    local fieldEq = function(a, b)
        if a == nil or b == nil then return a == b end
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" then return false end
        return a.n == b.n
    end
    local TableRes2 = R.resource({
        read = function(k) return tableDb2[k] end,
        equals = fieldEq, -- custom equals declared -> no assert
    })
    local val2
    R.effect(function() val2 = TableRes2("p") end)
    check("scalar-with-equals: initial readable", val2.n == 1)

    -- Same n -> change-detection uses opts.equals; equal -> no signal propagation
    -- (invalidateAll should honour opts.equals for change-detection when provided)
    tableDb2.p = { n = 1 }
    local ok2, _ = pcall(function() TableRes2.invalidateAll() end)
    check("scalar-with-equals: no error with custom equals", ok2)
    check("scalar-with-equals: equal value does not update", val2.n == 1)

    -- Changed n -> propagates
    tableDb2.p = { n = 99 }
    TableRes2.invalidateAll()
    check("scalar-with-equals: changed value propagates", val2.n == 99)
end

print(string.format("Reactor resource-ext: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
