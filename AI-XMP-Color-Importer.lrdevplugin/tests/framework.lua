--[[
    tests/framework.lua  —  极简测试框架（纯 Lua，无外部依赖）

    输出两路：
      * stdout  —— 仅 ASCII，避免 Windows 控制台编码问题
      * 文件    —— UTF-8 完整报告（由 run_tests.lua 落盘），便于准确阅读
--]]

local T = {}

T.pass = 0
T.fail = 0
T.failures = {}
T.lines = {}
T.root = "."

function T.setRoot(r)
    T.root = r
end

local function push(line)
    T.lines[#T.lines + 1] = line
end

local function asciiSafe(s)
    s = tostring(s)
    s = s:gsub("[^\32-\126\n\t]", "?")
    return s
end

function T.suite(name)
    push("")
    push("=== " .. name .. " ===")
    print("")
    print("=== " .. asciiSafe(name) .. " ===")
end

function T.case(name, fn)
    local ok, err = pcall(fn)
    if ok then
        T.pass = T.pass + 1
        push("  [ok]   " .. name)
        print("  [ok]   " .. asciiSafe(name))
        return true
    end
    T.fail = T.fail + 1
    local msg = tostring(err)
    T.failures[#T.failures + 1] = { name = name, err = msg }
    push("  [FAIL] " .. name)
    push("         " .. msg:gsub("\n", "\n         "))
    print("  [FAIL] " .. asciiSafe(name))
    print("         " .. asciiSafe(msg))
    return false
end

----------------------------------------------------------------------
-- 断言
----------------------------------------------------------------------

local function describe(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    end
    if t == "table" then
        local parts = {}
        for i, x in ipairs(v) do
            parts[#parts + 1] = tostring(x)
        end
        if #parts == 0 then
            local kv = {}
            for k, x in pairs(v) do
                kv[#kv + 1] = tostring(k) .. "=" .. tostring(x)
            end
            table.sort(kv)
            return "{ " .. table.concat(kv, ", ") .. " }"
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return tostring(v)
end
T.describe = describe

function T.eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s\n      期望: %s\n      实际: %s",
            label or "值不相等", describe(expected), describe(actual)), 2)
    end
end

function T.neq(actual, unexpected, label)
    if actual == unexpected then
        error(string.format("%s\n      不应等于: %s", label or "值不应相等", describe(unexpected)), 2)
    end
end

function T.near(actual, expected, eps, label)
    eps = eps or 1e-6
    if type(actual) ~= "number" or math.abs(actual - expected) > eps then
        error(string.format("%s\n      期望约: %s (±%s)\n      实际  : %s",
            label or "数值不接近", describe(expected), tostring(eps), describe(actual)), 2)
    end
end

function T.truthy(v, label)
    if not v then
        error((label or "期望为真") .. "\n      实际: " .. describe(v), 2)
    end
end

function T.falsy(v, label)
    if v then
        error((label or "期望为假") .. "\n      实际: " .. describe(v), 2)
    end
end

function T.isTable(v, label)
    if type(v) ~= "table" then
        error((label or "期望为表") .. "\n      实际类型: " .. type(v), 2)
    end
end

--- 期望 haystack 中包含子串 needle
function T.contains(haystack, needle, label)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(string.format("%s\n      期望包含: %q\n      实际内容: %s",
            label or "字符串不包含期望子串", tostring(needle), describe(haystack)), 2)
    end
end

--- 在数组中查找满足 predicate 的元素
function T.find(list, predicate, label)
    for _, v in ipairs(list or {}) do
        if predicate(v) then
            return v
        end
    end
    error(string.format("%s\n      在 %d 个元素中未找到", label or "未找到匹配元素", #(list or {})), 2)
end

--- 数组中是否存在 field == name 的条目
function T.hasField(list, name)
    for _, v in ipairs(list or {}) do
        if type(v) == "table" and v.field == name then
            return true
        end
    end
    return false
end

----------------------------------------------------------------------
-- 报告
----------------------------------------------------------------------

function T.report()
    push("")
    push(string.rep("-", 60))
    push(string.format("总计: %d 通过, %d 失败", T.pass, T.fail))
    if T.fail > 0 then
        push("")
        push("失败用例:")
        for _, f in ipairs(T.failures) do
            push("  - " .. f.name)
            push("      " .. f.err:gsub("\n", "\n      "))
        end
    end
    push(string.rep("-", 60))

    print("")
    print(string.rep("-", 60))
    print(string.format("TOTAL: %d passed, %d failed", T.pass, T.fail))
    if T.fail > 0 then
        print("")
        print("FAILED CASES:")
        for _, f in ipairs(T.failures) do
            print("  - " .. asciiSafe(f.name))
            print("      " .. asciiSafe(f.err))
        end
    end
    print(string.rep("-", 60))

    return T.fail == 0
end

function T.writeReport(path)
    local content = table.concat(T.lines, "\n") .. "\n"
    if type(io) == "table" and io.open then
        local f = io.open(path, "wb")
        if f then
            f:write(content)
            f:close()
            return true
        end
    end
    return false
end

return T
