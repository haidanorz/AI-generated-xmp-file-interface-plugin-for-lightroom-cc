--[[
    tests/test_Json.lua  —  JSON 编解码器测试

    自动化队列的契约（job.json / result.json）跨语言，JSON 编解码错了会静默传错数据，
    所以这里覆盖得细一些：转义、Unicode、数字、嵌套、以及各种畸形输入。
--]]

local T    = require "framework"
local Json = require "Json"

----------------------------------------------------------------------

T.suite("Json / 编码")

T.case("基本类型", function()
    T.eq(Json.encode(true), "true")
    T.eq(Json.encode(false), "false")
    T.eq(Json.encode(0), "0")
    T.eq(Json.encode(-42), "-42")
    T.eq(Json.encode(3.5), "3.5")
    T.eq(Json.encode("abc"), '"abc"')
end)

T.case("整数值不输出小数点", function()
    T.eq(Json.encode(37), "37", "整数应写成 37 而不是 37.0")
    T.eq(Json.encode(-1), "-1")
end)

T.case("字符串转义", function()
    T.eq(Json.encode('a"b'), '"a\\"b"')
    T.eq(Json.encode("a\\b"), '"a\\\\b"')
    T.eq(Json.encode("a\nb"), '"a\\nb"')
    T.eq(Json.encode("a\tb"), '"a\\tb"')
    T.contains(Json.encode("a\1b"), "\\u0001", "控制字符应转成 \\u 形式")
end)

T.case("UTF-8 原样保留（不转义成 \\u）", function()
    local s = Json.encode("海岸暖调")
    T.eq(s, '"海岸暖调"', "中文应原样输出")
end)

T.case("数组与对象", function()
    T.eq(Json.encode({ 1, 2, 3 }), "[1,2,3]")
    T.eq(Json.encode({}), "{}", "空表按对象处理")
    T.eq(Json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}', "对象键名应排序（稳定输出）")
end)

T.case("嵌套结构", function()
    local s = Json.encode({ id = "x", photos = { "a", "b" }, counts = { ok = 1 } })
    T.eq(s, '{"counts":{"ok":1},"id":"x","photos":["a","b"]}')
end)

T.case("非有限数退化为 null（JSON 无法表示）", function()
    T.eq(Json.encode(0 / 0), "null", "NaN")
    T.eq(Json.encode(1 / 0), "null", "Infinity")
end)

T.case("不支持的类型应明确报错", function()
    local ok, err = pcall(Json.encode, function() end)
    T.falsy(ok, "函数无法编码")
    T.contains(tostring(err), "不支持的类型")
end)

----------------------------------------------------------------------

T.suite("Json / 解码")

T.case("基本类型", function()
    T.eq(Json.decode("true"), true)
    T.eq(Json.decode("false"), false)
    T.eq(Json.decode("123"), 123)
    T.eq(Json.decode("-4.5"), -4.5)
    T.eq(Json.decode("1e3"), 1000)
    T.eq(Json.decode('"abc"'), "abc")
end)

T.case("对象与数组", function()
    local o = Json.decode('{"a":1,"b":[2,3]}')
    T.isTable(o)
    T.eq(o.a, 1)
    T.eq(o.b[1], 2)
    T.eq(o.b[2], 3)

    local arr = Json.decode('[1,[2,3],{"x":4}]')
    T.eq(#arr, 3)
    T.eq(arr[2][2], 3)
    T.eq(arr[3].x, 4)
end)

T.case("空白容错", function()
    local o = Json.decode('  {\n  "a" :  1 ,\t"b": [ 2 ]  }  ')
    T.eq(o.a, 1)
    T.eq(o.b[1], 2)
end)

T.case("转义与 Unicode", function()
    T.eq(Json.decode('"a\\"b"'), 'a"b')
    T.eq(Json.decode('"a\\\\b"'), "a\\b")
    T.eq(Json.decode('"a\\nb"'), "a\nb")
    T.eq(Json.decode('"\\u4e2d\\u6587"'), "中文", "\\u 应还原成 UTF-8")
    T.eq(Json.decode('"\\uD83D\\uDE00"'), Json.codepointToUtf8(0x1F600), "代理对应合成")
end)

T.case("null 解码为 nil（对象里丢键，数组里留空位）", function()
    local o = Json.decode('{"a":null,"b":1}')
    T.eq(o.a, nil, "null 对应 nil")
    T.eq(o.b, 1)
end)

T.case("整数与浮点都还原成 number", function()
    T.eq(type(Json.decode("42")), "number")
    T.eq(type(Json.decode("4.25")), "number")
end)

----------------------------------------------------------------------

T.suite("Json / 往返一致")

T.case("典型 job 结构往返", function()
    local job = {
        id     = "20261017-001",
        xmp    = "D:/xmp/a.xmp",
        photos = { "D:/p/IMG_1.CR3", "D:/p/IMG_2.CR3" },
        options = { dryRun = true, applyExtendedFields = false },
    }
    local back = Json.decode(Json.encode(job))
    T.eq(back.id, job.id)
    T.eq(back.xmp, job.xmp)
    T.eq(#back.photos, 2)
    T.eq(back.photos[2], job.photos[2])
    T.eq(back.options.dryRun, true)
    T.eq(back.options.applyExtendedFields, false)
end)

T.case("含中文与特殊字符的路径往返", function()
    local job = { photo = "D:/照片/海岸 崖顶/IMG_0001.CR3", note = '带"引号"和\\反斜杠' }
    local back = Json.decode(Json.encode(job))
    T.eq(back.photo, job.photo)
    T.eq(back.note, job.note)
end)

T.case("空数组与空对象往返", function()
    T.eq(Json.encode(Json.decode('{"a":[]}')), '{"a":[]}')
    T.eq(Json.encode(Json.decode('{"a":{}}')), '{"a":{}}')
end)

----------------------------------------------------------------------

T.suite("Json / 畸形输入必须明确报错")

T.case("截断 / 未闭合", function()
    local cases = {
        { '{"a":1',     "未正确闭合" },
        { '"abc',       "未闭合" },
        { '[1,2',       "未正确闭合" },
        { '{"a" 1}',    "冒号" },
        { '{a:1}',      "键必须是字符串" },
    }
    for _, c in ipairs(cases) do
        local v, err = Json.decode(c[1])
        T.eq(v, nil, "应解析失败: " .. c[1])
        T.truthy(type(err) == "string" and #err > 0, "应给出错误信息")
        T.contains(err, c[2], c[1] .. " 的错误信息应包含「" .. c[2] .. "」")
    end
end)

T.case("多余内容、非法字面量、空输入", function()
    local v1, e1 = Json.decode("1 2")
    T.eq(v1, nil); T.contains(tostring(e1), "多余内容")

    local v2, e2 = Json.decode("tru")
    T.eq(v2, nil); T.contains(tostring(e2), "true")

    local v3, e3 = Json.decode("")
    T.eq(v3, nil); T.truthy(e3 ~= nil)
end)

T.case("非字符串输入", function()
    local v, err = Json.decode(123)
    T.eq(v, nil)
    T.contains(tostring(err), "不是字符串")
end)

T.case("非法 \\u 转义", function()
    local v, err = Json.decode('"\\uZZZZ"')
    T.eq(v, nil)
    T.contains(tostring(err), "十六进制")
end)

return true
