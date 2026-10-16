--[[
    tests/test_XmpMapping.lua  —  映射层测试

    覆盖 Basic / 白平衡 / HSL / 未知字段等场景，以及：
      * 键名修正验证（Exposure2012 -> Exposure2012，而不是 Exposure）
      * 色调曲线 XMP 字符串序列 -> SDK 扁平数字数组
      * 颜色分级别名转换（ColorGradeShadowHue -> SplitToningShadowHue）
      * 类型转换的非法输入
      * Schema 版本策略
      * tier 门控（扩展字段默认不应用）
--]]

local T          = require "framework"
local Utils      = require "Utils"
local XmpParser  = require "XmpParser"
local XmpMapping = require "XmpMapping"
local Validation = require "Validation"

local FX = T.root .. "/tests/fixtures"

--- 静默 Logger，避免测试输出被业务日志淹没
local SilentLogger = {
    info = function() end,
    warn = function() end,
    error = function() end,
    debug = function() end,
}

local function mapFixture(name)
    local parsed, err = XmpParser.parseFile(FX .. "/" .. name)
    if not parsed then
        error("解析 " .. name .. " 失败: " .. tostring(err), 0)
    end
    return XmpMapping.toDevelopSettings(parsed, { logger = SilentLogger })
end

----------------------------------------------------------------------

T.suite("XmpMapping / Basic 字段")

local basicBundle = mapFixture("basic.xmp")

T.case("Exposure2012 = 0.35", function()
    T.near(basicBundle.settings.Exposure2012, 0.35, 1e-9, "settings.Exposure2012")
end)

T.case("键名验证：不得写入 PV2010 的 Exposure 键", function()
    -- Process Version 2012 之后活动键名带 2012 后缀；不带的是 PV2010 遗留键。
    T.eq(basicBundle.settings.Exposure, nil,
        "不应该写入 Exposure（PV2010 遗留键在 PV2012+ 下无效）")
    T.eq(basicBundle.settings.Contrast, nil, "不应该写入 Contrast")
end)

T.case("Highlights2012 = -25", function()
    T.near(basicBundle.settings.Highlights2012, -25, 1e-9, "settings.Highlights2012")
end)

T.case("Basic 其余字段全部正确映射", function()
    T.near(basicBundle.settings.Contrast2012, 12)
    T.near(basicBundle.settings.Shadows2012, 18)
    T.near(basicBundle.settings.Whites2012, 5)
    T.near(basicBundle.settings.Blacks2012, -8)
    T.near(basicBundle.settings.Texture, 6)
    T.near(basicBundle.settings.Clarity2012, 10)
    T.near(basicBundle.settings.Dehaze, 4)
    T.near(basicBundle.settings.Vibrance, 8)
    T.near(basicBundle.settings.Saturation, -3)
end)

T.case("布尔字段 ConvertToGrayscale = false", function()
    T.eq(basicBundle.settings.ConvertToGrayscale, false, "应为 false 而不是 NaN/nil")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 白平衡")

local wbBundle = mapFixture("white_balance.xmp")

T.case("Temperature / Tint 触发 WhiteBalance = Custom", function()
    T.eq(wbBundle.settings.WhiteBalance, "Custom", "有显式色温时必须写成 Custom")
    T.near(wbBundle.settings.Temperature, 5600, 1e-9, "Temperature")
    T.near(wbBundle.settings.Tint, 7, 1e-9, "Tint")
end)

T.case("mapWhiteBalance：只有预设模式时直通", function()
    local frag, notes = XmpMapping.mapWhiteBalance({ WhiteBalance = "Daylight" })
    T.eq(frag.WhiteBalance, "Daylight", "预设白平衡直通")
    T.eq(frag.Temperature, nil, "不应凭空写入 Temperature")
    T.eq(#notes.errors, 0, "不应有错误")
end)

T.case("mapWhiteBalance：未知白平衡模式 -> 错误", function()
    local frag, notes = XmpMapping.mapWhiteBalance({ WhiteBalance = "Milky Way Mode" })
    T.eq(#notes.errors, 1, "应产生 1 条错误")
    T.eq(notes.errors[1].field, "WhiteBalance", "错误字段名")
end)

T.case("mapWhiteBalance：声明 As Shot 但同时给了色温 -> 按 Custom 并告警", function()
    local frag, notes = XmpMapping.mapWhiteBalance({
        WhiteBalance = "As Shot", Temperature = "5200", Tint = "-3",
    })
    T.eq(frag.WhiteBalance, "Custom", "应强制 Custom")
    T.near(frag.Temperature, 5200)
    T.near(frag.Tint, -3)
    T.truthy(#notes.messages >= 1, "应给出解释性告警")
end)

T.case("mapWhiteBalance：色温非法 -> 错误且不写入该值", function()
    local frag, notes = XmpMapping.mapWhiteBalance({ Temperature = "abc" })
    T.eq(frag.Temperature, nil, "非法色温不应被写入")
    T.eq(#notes.errors, 1, "应产生错误")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / HSL 全通道")

T.case("8 个颜色的 Hue/Saturation/Luminance 全部正确映射", function()
    local expected = {
        Red     = { h = -2,  s = 4,   l = 2  },
        Orange  = { h = -4,  s = -6,  l = 8  },
        Yellow  = { h = 3,   s = -8,  l = 6  },
        Green   = { h = 6,   s = -4,  l = -3 },
        Aqua    = { h = 5,   s = -2,  l = 1  },
        Blue    = { h = 2,   s = -10, l = 7  },
        Purple  = { h = -1,  s = 2,   l = -5 },
        Magenta = { h = -3,  s = 3,   l = -1 },
    }
    local count = 0
    for _, color in ipairs(XmpMapping.COLOR_NAMES) do
        local want = expected[color]
        T.truthy(want ~= nil, "缺少期望值: " .. color)
        T.near(basicBundle.settings["HueAdjustment" .. color], want.h,
            1e-9, "HueAdjustment" .. color)
        T.near(basicBundle.settings["SaturationAdjustment" .. color], want.s,
            1e-9, "SaturationAdjustment" .. color)
        T.near(basicBundle.settings["LuminanceAdjustment" .. color], want.l,
            1e-9, "LuminanceAdjustment" .. color)
        count = count + 3
    end
    T.eq(count, 24, "应共检查 24 个 HSL 字段")
end)

T.case("颜色映射表集中定义且覆盖 8 个通道", function()
    T.eq(#XmpMapping.COLOR_NAMES, 8, "颜色通道数")
    for _, c in ipairs(XmpMapping.COLOR_NAMES) do
        T.eq(XmpMapping.COLOR_MAP[c], c, "COLOR_MAP 恒等映射: " .. c)
    end
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 未知字段")

T.case("SomeFutureField 不崩溃、被忽略并产生 warning", function()
    T.eq(basicBundle.settings.SomeFutureField, nil, "未知字段不应进入 settings")
    T.truthy(T.hasField(basicBundle.unknown, "SomeFutureField"), "应记录为未知字段")
    T.truthy(T.hasField(basicBundle.unsupported, "SomeFutureField"), "应进入 unsupported 清单")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 色调曲线")

local curveBundle = mapFixture("tone_curve.xmp")

T.case("XMP \"x, y\" 序列被转换为 SDK 扁平数字数组", function()
    local c = curveBundle.settings.ToneCurvePV2012
    T.isTable(c, "ToneCurvePV2012 应为表")
    T.eq(#c, 6, "3 个点应展开为 6 个数字")
    local expect = { 0, 0, 92, 106, 255, 255 }
    for i = 1, 6 do
        T.near(c[i], expect[i], 1e-9, "曲线第 " .. i .. " 项")
    end
end)

T.case("写入自定义点后 ToneCurveName2012 被强制为 Custom", function()
    T.eq(curveBundle.settings.ToneCurveName2012, "Custom", "ToneCurveName2012")
end)

T.case("恒等（线性）曲线被跳过，不写入 SDK", function()
    -- tone_curve.xmp 里的 ToneCurvePV2012Red 是 0,0 / 255,255
    T.eq(curveBundle.settings.ToneCurvePV2012Red, nil, "恒等曲线不应被写入")
end)

T.case("mapToneCurvePoints：非法格式 / 越界 / 非单调 都会被拒绝", function()
    local flat, err = XmpMapping.mapToneCurvePoints({ "0, 0", "not-a-point" })
    T.falsy(flat, "非法格式应被拒绝")
    T.contains(err, "格式非法", "错误信息")

    local flat2, err2 = XmpMapping.mapToneCurvePoints({ "0, 0", "300, 100" })
    T.falsy(flat2, "越界点应被拒绝")
    T.contains(err2, "255", "错误信息应提到范围")

    local flat3, err3 = XmpMapping.mapToneCurvePoints({ "0, 0", "200, 10", "100, 20" })
    T.falsy(flat3, "非单调曲线应被拒绝")
    T.contains(err3, "单调", "错误信息")

    local flat4, err4 = XmpMapping.mapToneCurvePoints({ "0, 0" })
    T.falsy(flat4, "少于 2 个点应被拒绝")
    T.contains(err4, "至少", "错误信息")

    local ok = XmpMapping.mapToneCurvePoints({ "0,0", "255,255" })
    T.isTable(ok, "紧凑写法 \"0,0\" 也应被接受")
end)

T.case("参数化曲线 7 个参数正确映射", function()
    T.near(curveBundle.settings.ParametricShadows, -10)
    T.near(curveBundle.settings.ParametricDarks, -5)
    T.near(curveBundle.settings.ParametricLights, 8)
    T.near(curveBundle.settings.ParametricHighlights, -12)
    T.near(curveBundle.settings.ParametricShadowSplit, 25)
    T.near(curveBundle.settings.ParametricMidtoneSplit, 50)
    T.near(curveBundle.settings.ParametricHighlightSplit, 75)
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 颜色分级（含别名转换）")

T.case("规范键名直通：SplitToningHighlightHue / Saturation", function()
    T.near(curveBundle.settings.SplitToningHighlightHue, 48)
    T.near(curveBundle.settings.SplitToningHighlightSaturation, 12)
end)

T.case("别名转换：ColorGradeShadowHue -> SplitToningShadowHue", function()
    T.near(curveBundle.settings.SplitToningShadowHue, 211,
        1e-9, "别名键必须被转换到 SDK 真实键名，否则 Lightroom 会静默丢弃")
    T.near(curveBundle.settings.SplitToningShadowSaturation, 9,
        1e-9, "ColorGradeShadowSat 别名转换")
    T.eq(curveBundle.settings.ColorGradeShadowHue, nil, "不应残留不存在的键名")
end)

T.case("别名转换会记录 warning", function()
    local found = false
    for _, w in ipairs(curveBundle.warnings) do
        if w:find("ColorGradeShadowHue", 1, true) and w:find("别名", 1, true) then
            found = true
        end
    end
    T.truthy(found, "应记录别名转换的 warning")
end)

T.case("ColorGradeBlending / SplitToningBalance / 中间调与亮度键", function()
    T.near(curveBundle.settings.ColorGradeBlending, 50)
    T.near(curveBundle.settings.SplitToningBalance, 10)
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 不支持字段与忽略的元数据")

T.case("遮罩 / Look / 污点修复被标记为不支持", function()
    T.truthy(T.hasField(basicBundle.unsupported, "MaskGroupBasedCorrections"), "遮罩")
    T.truthy(T.hasField(curveBundle.unsupported, "Look"), "Look")
    T.truthy(T.hasField(curveBundle.unsupported, "RetouchInfo"), "RetouchInfo")
    T.truthy(T.hasField(basicBundle.unsupported, "IncrementalTemperature"), "白平衡增量")
    T.eq(basicBundle.settings.MaskGroupBasedCorrections, nil, "遮罩不应进入 settings")
end)

T.case("预设元数据被静默忽略（不进入 unsupported）", function()
    for _, f in ipairs({ "PresetType", "UUID", "Cluster", "HasSettings",
                         "SupportsAmount", "CameraModelRestriction",
                         "Version", "ProcessVersion", "AIColorSchema", "AIVersion" }) do
        T.truthy(T.hasField(basicBundle.ignored, f), "应被忽略: " .. f)
        T.falsy(T.hasField(basicBundle.unsupported, f), "不应被列为不支持: " .. f)
        T.eq(basicBundle.settings[f], nil, "不应进入 settings: " .. f)
    end
end)

T.case("ProcessVersion 刻意不应用（避免改变渲染基准）", function()
    T.eq(basicBundle.settings.ProcessVersion, nil, "ProcessVersion 不应写入")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 扩展字段 tier 门控")

T.case("默认不应用扩展字段，但会记录 skipped", function()
    T.eq(basicBundle.settings.AutoLateralCA, nil, "AutoLateralCA 默认不应用")
    T.eq(basicBundle.settings.PostCropVignetteAmount, nil, "暗角默认不应用")
    T.truthy(T.hasField(basicBundle.skipped, "AutoLateralCA"), "应记录 skipped")
end)

T.case("开启 applyExtendedFields 后扩展字段被应用", function()
    local parsed = XmpParser.parseFile(FX .. "/basic.xmp")
    local bundle = XmpMapping.toDevelopSettings(parsed, {
        applyExtendedFields = true,
        logger = SilentLogger,
    })
    T.near(bundle.settings.AutoLateralCA, 1)
    T.near(bundle.settings.PostCropVignetteAmount, -12)
end)

T.case("white_balance.xmp 里 tier=ext 的 ShadowTint / RedHue 默认被跳过", function()
    T.eq(wbBundle.settings.ShadowTint, nil, "ShadowTint 属于 ext")
    T.eq(wbBundle.settings.RedHue, nil, "RedHue 属于 ext")
    T.truthy(T.hasField(wbBundle.skipped, "ShadowTint"), "应记录 skipped")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / AI Color Schema 版本策略")

local function bundleFromXml(xml, opts)
    local parsed, err = XmpParser.parseString(xml)
    if not parsed then error("解析失败: " .. tostring(err), 0) end
    opts = opts or {}
    opts.logger = SilentLogger
    return XmpMapping.toDevelopSettings(parsed, opts)
end

local function xmlWithSchema(ver)
    local attr = ver and ('crs:AIColorSchema="' .. ver .. '"') or ""
    return '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" ' ..
        attr .. ' crs:Exposure2012="0.5"/></rdf:RDF>'
end

T.case("1.0 -> supported", function()
    local b = bundleFromXml(xmlWithSchema("1.0"))
    T.eq(b.schema.status, "supported")
    T.near(b.settings.Exposure2012, 0.5)
end)

T.case("0.9 -> compatible + warning，仍然应用", function()
    local b = bundleFromXml(xmlWithSchema("0.9"))
    T.eq(b.schema.status, "compatible")
    T.near(b.settings.Exposure2012, 0.5)
    T.truthy(#b.warnings >= 1, "应产生兼容性 warning")
end)

T.case("2.0 -> unsupported，拒绝应用", function()
    local b = bundleFromXml(xmlWithSchema("2.0"))
    T.eq(b.schema.status, "unsupported")
    T.eq(b.settings.Exposure2012, nil, "不受支持的 schema 不应产生任何 settings")
    T.truthy(#b.errors >= 1, "应产生错误")
end)

T.case("缺失 -> assumed（按 1.0 处理）", function()
    local b = bundleFromXml(xmlWithSchema(nil))
    T.eq(b.schema.status, "assumed")
    T.near(b.settings.Exposure2012, 0.5)
end)

----------------------------------------------------------------------

T.suite("XmpMapping / convertValue 类型转换")

T.case("合法数值：字符串 -> number", function()
    local v = XmpMapping.convertValue(XmpMapping.FIELDS.Exposure2012, "0.35")
    T.near(v, 0.35)
    T.eq(type(v), "number", "必须是 number 而不是 string")
end)

T.case("非法数值一律返回 nil + 可读错误", function()
    local def = XmpMapping.FIELDS.Exposure2012
    local bad = { "abc", "", "   ", "0x10", "NaN", "Infinity", "-Infinity", "1,5" }
    for _, raw in ipairs(bad) do
        local v, err = XmpMapping.convertValue(def, raw)
        T.eq(v, nil, "应拒绝: " .. string.format("%q", raw))
        T.truthy(type(err) == "string" and #err > 0, "应给出错误信息: " .. raw)
    end
end)

T.case("科学计数法与符号被接受", function()
    T.near(XmpMapping.convertValue(XmpMapping.FIELDS.Exposure2012, "1e-1"), 0.1)
    T.near(XmpMapping.convertValue(XmpMapping.FIELDS.Highlights2012, "+25"), 25)
    T.near(XmpMapping.convertValue(XmpMapping.FIELDS.Highlights2012, "-25"), -25)
end)

T.case("布尔：true/false/True/False/1/0", function()
    local def = XmpMapping.FIELDS.ConvertToGrayscale
    T.eq(XmpMapping.convertValue(def, "true"), true)
    T.eq(XmpMapping.convertValue(def, "False"), false)
    T.eq(XmpMapping.convertValue(def, "1"), true)
    T.eq(XmpMapping.convertValue(def, "0"), false)
    local v, err = XmpMapping.convertValue(def, "maybe")
    T.eq(v, nil, "非法布尔应被拒绝")
    T.truthy(err ~= nil)
end)

T.case("枚举：合法值通过、非法值报错", function()
    local def = XmpMapping.FIELDS.PostCropVignetteStyle
    T.eq(XmpMapping.convertValue(def, "3"), 3)
    local v, err = XmpMapping.convertValue(def, "9")
    T.eq(v, nil, "非法枚举应被拒绝")
    T.contains(err, "非法枚举", "错误信息")
end)

T.case("容器值误当作标量 -> 明确报错", function()
    local v, err = XmpMapping.convertValue(XmpMapping.FIELDS.Exposure2012, { "1", "2" })
    T.eq(v, nil, "容器不应被接受")
    T.contains(err, "容器", "错误信息")
end)

T.case("字段定义缺失 / 值为 nil -> 明确报错", function()
    local v1, e1 = XmpMapping.convertValue(nil, "1")
    T.eq(v1, nil); T.truthy(e1 ~= nil)
    local v2, e2 = XmpMapping.convertValue(XmpMapping.FIELDS.Exposure2012, nil)
    T.eq(v2, nil); T.truthy(e2 ~= nil)
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 全流程零假错误 + 无重复写入（回归防护）")

--- 走完整 mapping，断言：零错误、applied 无重复键、字段数达标
local function assertClean(name, minSettings)
    local parsed, perr = XmpParser.parseFile(FX .. "/" .. name)
    T.truthy(parsed ~= nil, name .. " 解析失败: " .. tostring(perr))

    local bundle = XmpMapping.toDevelopSettings(parsed, { logger = SilentLogger })

    -- 1) 不允许出现任何错误。
    --    （回归点：色调曲线字段曾同时走「通用转换」与「专用转换」两条路径，
    --      通用路径撞上 type == "toneCurve" 就报错，凭空多出 4 条假错误，
    --      而曲线本身其实转换成功了 —— 测试只看结果，没看错误，所以漏了。）
    if #bundle.errors > 0 then
        local msgs = {}
        for _, e in ipairs(bundle.errors) do
            msgs[#msgs + 1] = string.format("%s: %s",
                tostring(e.field), tostring(e.message))
        end
        error(string.format("%s 产生了 %d 条错误:\n      %s",
            name, #bundle.errors, table.concat(msgs, "\n      ")), 2)
    end

    -- 2) applied 里同一个 SDK 键不得出现两次
    local seen = {}
    for _, item in ipairs(bundle.applied) do
        T.falsy(seen[item.sdkField],
            string.format("%s: SDK 键 %s 在 applied 中重复出现", name, tostring(item.sdkField)))
        seen[item.sdkField] = true
    end

    T.truthy(bundle.counts.settings >= minSettings,
        string.format("%s 可应用字段偏少: %d", name, bundle.counts.settings))

    return bundle
end

T.case("basic.xmp 全流程零错误、无重复键", function()
    assertClean("basic.xmp", 35)
end)

T.case("white_balance.xmp 全流程零错误、无重复键", function()
    assertClean("white_balance.xmp", 12)
end)

T.case("tone_curve.xmp 全流程零错误（回归：曲线字段曾被处理两遍）", function()
    local b = assertClean("tone_curve.xmp", 12)

    -- 曲线必须真的转换成功
    T.isTable(b.settings.ToneCurvePV2012, "点曲线应已转换")
    T.eq(#b.settings.ToneCurvePV2012, 6, "曲线应展开为 6 个数字")
    T.eq(b.settings.ToneCurveName2012, "Custom", "写入自定义点后名字应为 Custom")
end)

T.case("专用转换字段不会走进通用路径", function()
    -- 这 6 个字段必须由 mapWhiteBalance / mapToneCurve 处理，
    -- 通用路径一旦碰到 type == "toneCurve" 就会报错
    local DEDICATED = {
        "WhiteBalance", "ToneCurvePV2012", "ToneCurvePV2012Red",
        "ToneCurvePV2012Green", "ToneCurvePV2012Blue", "ToneCurveName2012",
    }
    for _, f in ipairs(DEDICATED) do
        T.truthy(XmpMapping.FIELDS[f] ~= nil, "字段应已登记: " .. f)
    end
    -- 直接用 convertValue 调 toneCurve 类型本身就该报错（那是设计如此），
    -- 关键是 toDevelopSettings 不能把它当通用字段处理 —— 上面三条用例已覆盖
    local v, err = XmpMapping.convertValue(XmpMapping.FIELDS.ToneCurvePV2012, { "0, 0" })
    T.eq(v, nil, "convertValue 对 toneCurve 类型应明确拒绝")
    T.contains(err, "mapToneCurve", "并提示改用专用函数")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 字段分类：已知 LR 原生键 vs 真正未知（回归防护）")

local function bundleFromAttrs(attrs)
    local xml = '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" ' ..
        attrs .. '/></rdf:RDF>'
    local parsed, err = XmpParser.parseString(xml)
    if not parsed then error("解析失败: " .. tostring(err), 0) end
    return XmpMapping.toDevelopSettings(parsed, { logger = SilentLogger })
end

T.case("OverrideLookVignette 已被识别（扩展字段），不再报「未知」", function()
    local def = XmpMapping.FIELDS.OverrideLookVignette
    T.truthy(def ~= nil, "OverrideLookVignette 应登记进 FIELDS")
    T.eq(def.sdk, "OverrideLookVignette")
    T.eq(def.type, "boolean", "XMP 侧是 boolean")
    T.eq(def.tier, "ext", "属于扩展字段（镜头校正），默认不应用")

    -- 默认（未开扩展）：应进 skipped，而不是 unknown
    local b = bundleFromAttrs('crs:OverrideLookVignette="True" crs:Exposure2012="0.1"')
    T.truthy(T.hasField(b.skipped, "OverrideLookVignette"), "默认应记为 skipped")
    T.eq(#b.unknown, 0, "绝不能再被当成未知字段")
    T.eq(b.settings.OverrideLookVignette, nil, "默认不应用")

    -- 开启扩展：应真的应用
    local parsed = XmpParser.parseString(
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" ' ..
        'crs:OverrideLookVignette="True"/></rdf:RDF>')
    local b2 = XmpMapping.toDevelopSettings(parsed, {
        applyExtendedFields = true, logger = SilentLogger,
    })
    T.eq(b2.settings.OverrideLookVignette, true, "开启扩展后应写入 true")
    T.eq(#b2.errors, 0, "不应有错误")
end)

T.case("已知的 LR 原生键归入 knownNative，而不是 unknown", function()
    local b = bundleFromAttrs(
        'crs:EnableLensCorrections="True" ' ..
        'crs:DefringePurpleAmount="5" ' ..
        'crs:ToneCurve="{}" ' ..
        'crs:Look="{}" ' ..
        'crs:HDREditMode="1" ' ..
        'crs:local_Exposure="-0.5" ' ..
        'crs:PointColorHueShift="10" ' ..
        'crs:DepthSource="1" ' ..
        'crs:EnhanceDenoise="True" ' ..
        'crs:SDRContrast="5" ' ..
        'crs:LensBlurAmount="10" ' ..
        'crs:PerspectiveUpright="1" ' ..
        'crs:CropTop="0.1" ' ..
        'crs:SomeFutureField="123"')

    T.eq(#b.unknown, 1, "只有 SomeFutureField 应算真正未知，实际 " ..
        #b.unknown .. " 个")
    T.truthy(T.hasField(b.unknown, "SomeFutureField"), "SomeFutureField 应在 unknown 里")

    for _, f in ipairs({
        "EnableLensCorrections", "DefringePurpleAmount", "ToneCurve", "Look",
        "HDREditMode", "local_Exposure", "PointColorHueShift", "DepthSource",
        "EnhanceDenoise", "SDRContrast", "LensBlurAmount", "PerspectiveUpright", "CropTop",
    }) do
        T.truthy(T.hasField(b.knownNative, f), "应被识别为已知 LR 键: " .. f)
        T.falsy(T.hasField(b.unknown, f), "不应被当成未知字段: " .. f)
    end
end)

T.case("每个 knownNative 条目都带可读原因", function()
    local b = bundleFromAttrs('crs:EnableLensCorrections="True" crs:local_Exposure="-1"')
    T.truthy(#b.knownNative >= 2, "应至少识别出 2 个")
    for _, it in ipairs(b.knownNative) do
        T.truthy(type(it.reason) == "string" and #it.reason > 1,
            "条目应带原因: " .. tostring(it.field))
    end
end)

T.case("matchKnownNative 覆盖各键族，且不会误伤已支持字段", function()
    local cases = {
        { "local_Exposure", true },
        { "PointColorSatScale", true },
        { "LensBlurBlurAmount", true },
        { "LensProfileName", true },
        { "DefringeGreenHueLo", true },
        { "GrayMixerRed", true },
        { "PerspectiveVertical", true },
        { "CropLeft", true },
        { "EnableDetail", true },
        { "AutoToneDigest", true },
        { "ToneCurveName", true },
        { "MaskGroupBasedCorrections", true },
        -- 已支持字段不应被前缀规则捕获
        { "Exposure2012", false },
        { "Vibrance", false },
        { "HueAdjustmentRed", false },
    }
    for _, c in ipairs(cases) do
        local r = XmpMapping.matchKnownNative(c[1])
        if c[2] then
            T.truthy(r ~= nil, c[1] .. " 应被识别为已知 LR 键")
        else
            T.eq(r, nil, c[1] .. " 不应被前缀规则捕获（它已是支持字段）")
        end
    end
end)

T.case("前缀规则确实不会影响已支持字段的分类结果", function()
    -- AutoLateralCA 以 Auto 开头，但它在 FIELDS 里（ext），必须走 skipped
    local b = bundleFromAttrs('crs:AutoLateralCA="1"')
    T.truthy(T.hasField(b.skipped, "AutoLateralCA"), "应记为 skipped")
    T.eq(#b.knownNative, 0, "不应被前缀规则捕获")
    T.eq(#b.unknown, 0)
end)

T.case("RawFileName 归入 Ignored 元数据（用于来源匹配，不是 Develop 参数）", function()
    local b = bundleFromAttrs('crs:RawFileName="IMG_1023.CR3"')
    T.truthy(T.hasField(b.ignored, "RawFileName"), "应被忽略为元数据")
    T.eq(#b.knownNative, 0)
    T.eq(#b.unknown, 0)
end)

T.case("Validation 会透传 knownNative 与计数", function()
    local b = bundleFromAttrs('crs:EnableDetail="True" crs:SomeFutureField="1"')
    local r = Validation.validate(b)
    T.eq(r.counts.knownNative, 1, "knownNative 计数")
    T.eq(r.counts.unknown, 1, "unknown 计数")
    T.truthy(T.hasField(r.knownNative, "EnableDetail"), "Validation 应透传 knownNative 列表")
end)

----------------------------------------------------------------------

T.suite("XmpMapping / 映射表自身的一致性")

T.case("每个字段定义都具备 sdk / type / group / tier / source", function()
    local n = 0
    for name, def in pairs(XmpMapping.FIELDS) do
        T.truthy(type(def.sdk) == "string" and def.sdk ~= "", name .. " 缺少 sdk")
        T.truthy(type(def.type) == "string", name .. " 缺少 type")
        T.truthy(type(def.group) == "string", name .. " 缺少 group")
        T.truthy(def.tier == "v1" or def.tier == "ext", name .. " tier 非法")
        T.truthy(type(def.source) == "string" and #def.source > 0, name .. " 缺少来源标注")
        n = n + 1
    end
    T.truthy(n > 50, "字段总数应大于 50，实际 " .. n)
end)

T.case("数值字段的范围是 {min, max} 且 min < max", function()
    for name, def in pairs(XmpMapping.FIELDS) do
        if def.type == "number" and def.range ~= nil then
            T.eq(#def.range, 2, name .. " range 长度应为 2")
            T.truthy(def.range[1] < def.range[2], name .. " range 顺序错误")
        end
    end
end)

T.case("别名表中的每个目标都存在于 FIELDS", function()
    for alias, target in pairs(XmpMapping.ALIASES) do
        T.truthy(XmpMapping.FIELDS[target] ~= nil,
            string.format("别名 %s -> %s 的目标不存在", alias, target))
    end
end)

T.case("SUPPORTED 与 UNSUPPORTED 没有重叠", function()
    for name in pairs(XmpMapping.FIELDS) do
        T.falsy(XmpMapping.UNSUPPORTED_FIELDS[name],
            name .. " 同时出现在 FIELDS 与 UNSUPPORTED_FIELDS 中")
    end
end)

return true
