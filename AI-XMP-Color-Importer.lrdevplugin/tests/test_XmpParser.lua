--[[
    tests/test_XmpParser.lua  —  解析器测试

    覆盖：命名空间前缀无关性、属性/元素两种写法、rdf:Seq/Alt、
          实体解码、CDATA、BOM、重复字段、多描述块、错误路径。
--]]

local T         = require "framework"
local Utils     = require "Utils"
local XmpParser = require "XmpParser"

local NS_CRS = XmpParser.NS.CRS
local NS_RDF = XmpParser.NS.RDF

local FX = T.root .. "/tests/fixtures"

local function readFixture(name)
    local text, err = Utils.platform.readFile(FX .. "/" .. name)
    if not text then
        error("无法读取 fixture " .. name .. ": " .. tostring(err), 0)
    end
    return text
end

----------------------------------------------------------------------

T.suite("XmpParser / 基础解析（fixtures/basic.xmp）")

local basic = XmpParser.parseFile(FX .. "/basic.xmp")

T.case("basic.xmp 能被解析", function()
    T.isTable(basic, "解析结果为 nil")
    T.isTable(basic.fields, "fields 缺失")
end)

T.case("属性形式的字段被正确读取", function()
    T.eq(basic.fields.Highlights2012, "-25", "Highlights2012 原文")
    T.eq(basic.fields.Shadows2012, "+18", "Shadows2012 原文")
    T.eq(basic.fields.WhiteBalance, "As Shot", "WhiteBalance 原文")
end)

T.case("命名空间前缀无关：CameraRaw:Exposure2012 与 crs: 等价", function()
    -- fixture 里 Exposure2012 故意用另一个前缀 CameraRaw 书写，但绑定同一个 crs URI
    T.eq(basic.fields.Exposure2012, "+0.35", "应该按 namespace URI 而非字面前缀识别")
    T.eq(basic.fieldSources.Exposure2012,
        basic.fieldSources.Exposure2012, "占位")
end)

T.case("元素形式的 HSL 24 项全部被读取", function()
    local colors = { "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta" }
    for _, c in ipairs(colors) do
        T.truthy(basic.fields["HueAdjustment" .. c] ~= nil, "缺少 HueAdjustment" .. c)
        T.truthy(basic.fields["SaturationAdjustment" .. c] ~= nil, "缺少 SaturationAdjustment" .. c)
        T.truthy(basic.fields["LuminanceAdjustment" .. c] ~= nil, "缺少 LuminanceAdjustment" .. c)
    end
    T.eq(basic.fields.SaturationAdjustmentBlue, "-10", "SaturationAdjustmentBlue")
    T.eq(basic.fields.LuminanceAdjustmentOrange, "+8", "LuminanceAdjustmentOrange")
end)

T.case("rdf:Alt（LangAlt）被解析为语言表", function()
    local name = basic.fields.Name
    T.isTable(name, "crs:Name 应为表")
    T.eq(name["x-default"], "Natural Warm", "Name x-default")
    T.eq(basic.metadata.presetName, "Natural Warm", "metadata.presetName")
    T.eq(basic.metadata.presetGroup, "AI Color", "metadata.presetGroup")
end)

T.case("XML 实体被解码（&amp; 与 &#8212;）", function()
    local desc = basic.fields.Description
    T.isTable(desc, "crs:Description 应为表")
    T.contains(desc["x-default"], "natural & warm", "&amp; 应被解码为 &")
    T.contains(desc["x-default"], XmpParser.codepointToUtf8(8212), "&#8212; 应被解码为 U+2014")
end)

T.case("元数据抽取（sourceFile / schema / aiVersion）", function()
    T.eq(basic.metadata.sourceFile, "IMG_1023.CR3", "sourceFile")
    T.eq(basic.metadata.schemaVersion, "1.0", "schemaVersion")
    T.eq(basic.metadata.aiVersion, "portrait-color-v1", "aiVersion")
    T.eq(basic.metadata.processVersion, "15.4", "processVersion")
    T.eq(basic.metadata.crsVersion, "17.5", "crsVersion")
    T.eq(basic.metadata.presetUUID, "0123456789ABCDEF0123456789ABCDEF", "UUID")
end)

T.case("未知字段被原样收集（交给 Mapping 层判定）", function()
    T.eq(basic.fields.SomeFutureField, "123", "SomeFutureField 应被读到")
end)

T.case("命名空间映射被记录", function()
    T.eq(basic.namespaces.crs, NS_CRS, "前缀 crs 应解析到 crs URI")
    T.eq(basic.namespaces.rdf, NS_RDF, "前缀 rdf 应解析到 rdf URI")
    T.eq(basic.namespaces.CameraRaw, NS_CRS, "前缀 CameraRaw 应解析到同一个 crs URI")
end)

----------------------------------------------------------------------

T.suite("XmpParser / 结构变体")

T.case("rdf:Seq 被解析为有序数组（tone_curve.xmp）", function()
    local p = XmpParser.parseFile(FX .. "/tone_curve.xmp")
    T.isTable(p, "解析失败")
    local curve = p.fields.ToneCurvePV2012
    T.isTable(curve, "ToneCurvePV2012 应为表")
    T.eq(#curve, 3, "曲线点数量")
    T.eq(curve[1], "0, 0", "第 1 点")
    T.eq(curve[2], "92, 106", "第 2 点")
    T.eq(curve[3], "255, 255", "第 3 点")

    local red = p.fields.ToneCurvePV2012Red
    T.eq(#red, 2, "红色通道曲线点数量")
end)

T.case("多个 rdf:Description 的字段被合并", function()
    local p = XmpParser.parseFile(FX .. "/white_balance.xmp")
    T.eq(p.fields.Temperature, "5600", "第一段里的 Temperature")
    T.eq(p.fields.Vibrance, "+12", "第二段里的 Vibrance")
    T.eq(p.fields.ShadowTint, "+4", "第二段里的 ShadowTint")
    T.eq(p.fields.ColorGradeMidtoneHue, "323", "第二段里的 ColorGradeMidtoneHue")
end)

T.case("重复字段：保留首次出现，并产生 warning", function()
    local xml = [[
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="1"/>
  <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="2"/>
 </rdf:RDF>
</x:xmpmeta>]]
    local p, err = XmpParser.parseString(xml)
    T.truthy(p ~= nil, "解析失败: " .. tostring(err))
    T.eq(p.fields.Exposure2012, "1", "重复字段应保留首次出现的值")
    local found = false
    for _, w in ipairs(p.warnings) do
        if w:find("Exposure2012", 1, true) and w:find("多次", 1, true) then
            found = true
        end
    end
    T.truthy(found, "应产生「字段出现多次」的 warning")
end)

T.case("UTF-8 BOM 被正确跳过", function()
    local xml = "\239\187\191" ..
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.5"/>' ..
        '</rdf:RDF>'
    local p, err = XmpParser.parseString(xml)
    T.truthy(p ~= nil, "带 BOM 的文档应能解析: " .. tostring(err))
    T.eq(p.fields.Exposure2012, "0.5", "BOM 后字段应正常读取")
end)

T.case("CDATA 内容被当作纯文本", function()
    local xml = '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">' ..
        '<crs:Name><![CDATA[Hello <World> & "quoted"]]></crs:Name>' ..
        '</rdf:Description></rdf:RDF>'
    local p, err = XmpParser.parseString(xml)
    T.truthy(p ~= nil, "解析失败: " .. tostring(err))
    T.eq(p.fields.Name, 'Hello <World> & "quoted"', "CDATA 内容")
end)

T.case("注释与被跳过的处理指令不影响解析", function()
    local xml = '<?xml version="1.0" encoding="UTF-8"?>\n' ..
        '<!-- 这是注释 -->\n' ..
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n' ..
        '<!-- 内部注释 -->\n' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Vibrance="7"/>\n' ..
        '</rdf:RDF>'
    local p, err = XmpParser.parseString(xml)
    T.truthy(p ~= nil, "解析失败: " .. tostring(err))
    T.eq(p.fields.Vibrance, "7", "Vibrance")
end)

T.case("缺少 rdf:Description 时退化为整树扫描并给出 warning", function()
    local xml = '<root xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="1.25"/>'
    local p, err = XmpParser.parseString(xml)
    T.truthy(p ~= nil, "解析失败: " .. tostring(err))
    T.eq(p.fields.Exposure2012, "1.25", "退化扫描应读到字段")
    local warned = false
    for _, w in ipairs(p.warnings) do
        if w:find("rdf:Description", 1, true) then warned = true end
    end
    T.truthy(warned, "应产生退化扫描的 warning")
end)

----------------------------------------------------------------------

T.suite("XmpParser / 错误路径（绝不能抛穿）")

T.case("XML 未闭合 -> 返回可读错误而不是崩溃", function()
    local p, err = XmpParser.parseFile(FX .. "/invalid.xmp")
    T.falsy(p, "非法 XML 不应解析成功")
    T.truthy(type(err) == "string" and #err > 0, "应返回错误字符串")
    T.contains(err, "XMP 解析", "错误信息应可读")
end)

T.case("未声明的命名空间前缀 -> 明确报错", function()
    local xml = '<root><crs:Exposure2012>1</crs:Exposure2012></root>'
    local p, err = XmpParser.parseString(xml)
    T.falsy(p, "应解析失败")
    T.contains(err, "未声明的命名空间前缀", "错误信息应指出前缀未声明")
end)

T.case("多个根元素 -> 明确报错", function()
    local xml = '<a/><b/>'
    local p, err = XmpParser.parseString(xml)
    T.falsy(p, "应解析失败")
    T.contains(err, "多个根元素", "错误信息")
end)

T.case("空内容 -> 明确报错", function()
    local p, err = XmpParser.parseString("")
    T.falsy(p, "空内容不应解析成功")
    T.contains(err, "为空", "错误信息")
end)

T.case("文件不存在 -> 可读错误", function()
    local p, err = XmpParser.parseFile(FX .. "/__not_exist__.xmp")
    T.falsy(p, "不应解析成功")
    T.truthy(err:find("不存在", 1, true) ~= nil or err:find("无法读取", 1, true) ~= nil,
        "错误信息应说明文件不存在或无法读取，实际: " .. tostring(err))
end)

----------------------------------------------------------------------

T.suite("XmpParser / 入口分发")

T.case("XmpParser.parse 能区分 XML 文本与文件路径", function()
    local a = XmpParser.parse('<root xmlns:crs="' .. NS_CRS .. '" crs:Vibrance="3"/>')
    T.truthy(a ~= nil, "XML 文本路径失败")
    T.eq(a.fields.Vibrance, "3", "Vibrance")

    local b = XmpParser.parse(FX .. "/basic.xmp")
    T.truthy(b ~= nil, "文件路径失败")
    T.eq(b.fields.Highlights2012, "-25", "Highlights2012")
end)

T.case("looksLikeXmp 判定", function()
    T.truthy(XmpParser.looksLikeXmp(readFixture("basic.xmp")))
    T.falsy(XmpParser.looksLikeXmp("hello world"))
end)
