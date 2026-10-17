--[[
    src/Json.lua  —  最小但正确的 JSON 编解码器（纯 Lua，无依赖）

    为什么需要它：
        自动化队列的契约（job.json / result.json）要跨语言，JSON 是最合适的格式。
        Lightroom 的 Lua 环境里没有 JSON 库（标准库只有 io / math / string 等子集），
        所以这里自己实现一份。

    取舍：
      · 只支持 JSON 标准本身需要的类型：object / array / string / number / boolean / null
      · 编码时对象按键名排序输出，保证同一份数据每次结果一致（便于比对与测试）
      · 不解码 NaN / Infinity（JSON 标准也没有）
      · **null 解码为 nil**：对象里会丢掉这个键，数组里会留下空位。
        本项目的 job/result 契约不使用 null，因此不影响使用。
      · 不追求 pretty-print：job/result 是给程序读的

    Lua 5.1 兼容（不用 goto、不用 integer 除法）。
--]]

local Json = {}

--- null 哨兵：解析时用来区分「JSON null」与「解析失败」，不会泄漏给调用方
Json.null = setmetatable({}, { __tostring = function() return "json.null" end })

--- 数组标记
--   问题：空表 { } 到底该编码成 [] 还是 {}？
--   仅凭 #t == 0 无法区分，会把空数组写成 {}，丢掉类型。
--   所以：解码出来的数组带上这个元表；手写数据想表达"空数组"用 Json.array{}。
Json.array_mt = { __jsontype = "array" }

--- 把 table 标记为 JSON 数组（返回同一个表）
function Json.array(t)
    return setmetatable(t or {}, Json.array_mt)
end

----------------------------------------------------------------------
-- 编码
----------------------------------------------------------------------

local ESCAPES = {
    ['"']  = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escapeChar(c)
    return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
end

local function encodeString(s)
    -- 控制字符、反斜杠、双引号需要转义；UTF-8 字节原样保留（合法 JSON）
    return '"' .. s:gsub('[%z\1-\31\\"]', escapeChar) .. '"'
end

--- 判断一个 table 该编码成数组还是对象
local function isArrayLike(t)
    if getmetatable(t) == Json.array_mt then
        return true
    end
    local n = #t
    if n == 0 then
        -- 没有标记的空表：按对象处理（{} 比 [] 更保守）
        return false
    end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == n
end

local function encodeValue(v, out)
    local tv = type(v)

    if v == nil then
        out[#out + 1] = "null"

    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"

    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            -- NaN / Infinity 在 JSON 里没有表示
            out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 9007199254740992 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.14g", v)
        end

    elseif tv == "string" then
        out[#out + 1] = encodeString(v)

    elseif tv == "table" then
        if isArrayLike(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encodeValue(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) == "string" then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = encodeString(k)
                out[#out + 1] = ":"
                encodeValue(v[k], out)
            end
            out[#out + 1] = "}"
        end

    else
        error("Json.encode: 不支持的类型 " .. tostring(tv), 0)
    end
end

--- 编码为 JSON 字符串
-- @param value 任意值
-- @return string
function Json.encode(value)
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end

----------------------------------------------------------------------
-- 解码
----------------------------------------------------------------------

local function codepointToUtf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
    else
        return string.char(
            0xF0 + math.floor(code / 0x40000),
            0x80 + (math.floor(code / 0x1000) % 0x40),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
    end
end
Json.codepointToUtf8 = codepointToUtf8

--- 解码 JSON 文本
-- @param text string
-- @return value|nil, errString
function Json.decode(text)
    if type(text) ~= "string" then
        return nil, "Json.decode: 输入不是字符串"
    end

    local pos, len = 1, #text
    local parseValue, parseObject, parseArray, parseString, parseNumber, skipWs

    local function fail(msg)
        return nil, string.format("JSON 解析失败（第 %d 个字符）：%s", pos, msg)
    end

    skipWs = function()
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                return
            end
        end
    end

    parseString = function()
        pos = pos + 1 -- 跳过起始引号
        local buf = {}
        while true do
            if pos > len then
                return fail("字符串未闭合")
            end
            local c = text:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == "\\" then
                local n = text:sub(pos + 1, pos + 1)
                pos = pos + 2
                if n == '"'  then buf[#buf + 1] = '"'
                elseif n == "\\" then buf[#buf + 1] = "\\"
                elseif n == "/"  then buf[#buf + 1] = "/"
                elseif n == "b"  then buf[#buf + 1] = "\b"
                elseif n == "f"  then buf[#buf + 1] = "\f"
                elseif n == "n"  then buf[#buf + 1] = "\n"
                elseif n == "r"  then buf[#buf + 1] = "\r"
                elseif n == "t"  then buf[#buf + 1] = "\t"
                elseif n == "u" then
                    local hex = text:sub(pos, pos + 3)
                    if not hex:match("^%x%x%x%x$") then
                        return fail("\\u 后面需要 4 位十六进制")
                    end
                    pos = pos + 4
                    local cp = tonumber(hex, 16)
                    -- 代理对（高代理 + 低代理）合成一个码点
                    if cp >= 0xD800 and cp <= 0xDBFF then
                        local lo = text:match("^\\u(%x%x%x%x)", pos)
                        if lo then
                            local lcp = tonumber(lo, 16)
                            if lcp >= 0xDC00 and lcp <= 0xDFFF then
                                pos = pos + 6
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (lcp - 0xDC00)
                            end
                        end
                    end
                    buf[#buf + 1] = codepointToUtf8(cp)
                else
                    return fail("未知转义 \\" .. tostring(n))
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
    end

    parseNumber = function()
        local numStr = text:match("^-?%d+%.?%d*[eE][-+]?%d+", pos)
            or text:match("^-?%d+%.%d+", pos)
            or text:match("^-?%d+", pos)
        if not numStr then
            return fail("数字格式非法")
        end
        pos = pos + #numStr
        return tonumber(numStr)
    end

    parseArray = function()
        pos = pos + 1 -- [
        local arr = {}
        local index = 0
        skipWs()
        if text:sub(pos, pos) == "]" then
            pos = pos + 1
            return setmetatable(arr, Json.array_mt)
        end
        while true do
            local v, verr = parseValue()
            if verr then return nil, verr end
            index = index + 1
            if v == Json.null then
                -- 数组里的 null 只能留空位（本项目契约不使用）
                v = nil
            end
            arr[index] = v
            skipWs()
            local c = text:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                return setmetatable(arr, Json.array_mt)
            else
                return fail("数组未正确闭合")
            end
        end
    end

    parseObject = function()
        pos = pos + 1 -- {
        local obj = {}
        skipWs()
        if text:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skipWs()
            if text:sub(pos, pos) ~= '"' then
                return fail("对象的键必须是字符串")
            end
            local k, kerr = parseString()
            if k == nil then return nil, kerr end

            skipWs()
            if text:sub(pos, pos) ~= ":" then
                return fail("键后面缺少冒号")
            end
            pos = pos + 1

            local v, verr = parseValue()
            if verr then return nil, verr end
            if v ~= Json.null then
                obj[k] = v
            end

            skipWs()
            local c = text:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                return obj
            else
                return fail("对象未正确闭合")
            end
        end
    end

    parseValue = function()
        skipWs()
        if pos > len then
            return fail("内容意外结束")
        end
        local c = text:sub(pos, pos)

        if c == "{" then return parseObject() end
        if c == "[" then return parseArray() end
        if c == '"' then return parseString() end
        if c == "t" then
            if text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
            return fail("非法字面量（应为 true）")
        end
        if c == "f" then
            if text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
            return fail("非法字面量（应为 false）")
        end
        if c == "n" then
            if text:sub(pos, pos + 3) == "null" then pos = pos + 4; return Json.null end
            return fail("非法字面量（应为 null）")
        end
        return parseNumber()
    end

    local value, err = parseValue()
    if err then
        return nil, err
    end

    skipWs()
    if pos <= len then
        return fail("JSON 结束后还有多余内容")
    end
    if value == Json.null then
        value = nil
    end
    return value
end

return Json
