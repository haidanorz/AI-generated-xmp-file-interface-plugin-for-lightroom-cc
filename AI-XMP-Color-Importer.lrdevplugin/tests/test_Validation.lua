--[[
    tests/test_Validation.lua  —  校验层 / 装配层 / 匹配逻辑测试

    覆盖：非法值 -> validation error；文件名不匹配默认拒绝，
    以及范围收拢、明显非法、读回装配、Preview 渲染。
--]]

local T               = require "framework"
local Utils           = require "Utils"
local XmpParser       = require "XmpParser"
local XmpMapping      = require "XmpMapping"
local Validation      = require "Validation"
local DevelopSettings = require "DevelopSettings"
local PhotoResolver   = require "PhotoResolver"

local FX = T.root .. "/tests/fixtures"

local SilentLogger = {
    info = function() end, warn = function() end,
    error = function() end, debug = function() end,
}

--- 走完整流水线：XML -> parse -> map -> validate
local function pipeline(xml, opts)
    local parsed, err = XmpParser.parseString(xml)
    if not parsed then
        error("解析失败: " .. tostring(err), 0)
    end
    local bundle = XmpMapping.toDevelopSettings(parsed, {
        applyExtendedFields = (opts and opts.applyExtendedFields) or false,
        logger = SilentLogger,
    })
    local result = Validation.validate(bundle, opts or {})
    result.parsed = parsed
    return result
end

local function xmlWith(attrs, elements)
    local head = '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' ..
        '<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" '
    local body = attrs or ""
    local closing = (elements and #elements > 0) and ">" or "/>"
    local tail = ""
    if elements and #elements > 0 then
        for _, e in ipairs(elements) do
            tail = tail .. e
        end
        tail = tail .. "</rdf:Description>"
    end
    return head .. body .. closing .. tail .. "</rdf:RDF>"
end

----------------------------------------------------------------------

T.suite("Validation / 非法值")

T.case("非法值 Exposure2012 = \"abc\" 产生 validation error 且不进入 settings", function()
    local result = pipeline(xmlWith('', { "<crs:Exposure2012>abc</crs:Exposure2012>" }))
    T.truthy(#result.errors >= 1, "应产生至少 1 条错误")
    T.eq(result.settings.Exposure2012, nil, "非法值不应进入 settings")
    T.falsy(result.ok, "存在错误时 ok 必须为 false")
    T.falsy(result.applicable, "没有可应用字段时 applicable 必须为 false")

    local found = false
    for _, e in ipairs(result.errors) do
        if e.field == "Exposure2012" then found = true end
    end
    T.truthy(found, "错误应指向 Exposure2012 字段")
end)

T.case("同类非法值：空串 / NaN / Infinity", function()
    local cases = {
        { "<crs:Exposure2012></crs:Exposure2012>", "空串" },
        { "<crs:Contrast2012>NaN</crs:Contrast2012>", "NaN" },
        { "<crs:Highlights2012>Infinity</crs:Highlights2012>", "Infinity" },
    }
    for _, c in ipairs(cases) do
        local result = pipeline(xmlWith('', { c[1] }))
        T.truthy(#result.errors >= 1, c[2] .. " 应产生错误")
    end
end)

----------------------------------------------------------------------

T.suite("Validation / 范围收拢与明显非法")

T.case("轻微超范围 -> clamp + warning（不报错）", function()
    local result = pipeline(xmlWith('', { "<crs:Contrast2012>150</crs:Contrast2012>" }))
    T.eq(result.settings.Contrast2012, 100, "150 应被收拢到 100")
    T.eq(#result.clamped, 1, "应记录 1 条收拢")
    T.eq(result.clamped[1].field, "Contrast2012")
    T.near(result.clamped[1].rawValue, 150, 1e-9, "收拢记录应保留原值")
    T.eq(#result.errors, 0, "轻微超范围不应报错")
    T.truthy(result.ok, "只有收拢时仍应可应用")
end)

T.case("低于下限同样被收拢", function()
    local result = pipeline(xmlWith('', { "<crs:Shadows2012>-140</crs:Shadows2012>" }))
    T.eq(result.settings.Shadows2012, -100, "-140 应被收拢到 -100")
    T.eq(result.clamped[1].direction, "below", "方向应为 below")
end)

T.case("明显非法（远超区间）-> error 并丢弃", function()
    local result = pipeline(xmlWith('', { "<crs:Contrast2012>5000</crs:Contrast2012>" }))
    T.eq(result.settings.Contrast2012, nil, "5000 应被丢弃")
    T.truthy(#result.errors >= 1, "应报错")
    T.eq(#result.clamped, 0, "不应只收拢了事")
end)

T.case("Exposure 的明显非法值被拒绝", function()
    local result = pipeline(xmlWith('', { "<crs:Exposure2012>100</crs:Exposure2012>" }))
    T.eq(result.settings.Exposure2012, nil, "曝光 100 EV 明显非法")
    T.truthy(#result.errors >= 1, "应报错")
end)

T.case("色温：无静态范围，只做合理性检查", function()
    local ok = pipeline(xmlWith('', { "<crs:Temperature>5600</crs:Temperature>" }))
    T.near(ok.settings.Temperature, 5600, 1e-9, "正常色温应通过")

    local bad = pipeline(xmlWith('', { "<crs:Temperature>999999</crs:Temperature>" }))
    T.eq(bad.settings.Temperature, nil, "离谱色温应被拒绝")
    T.truthy(#bad.errors >= 1, "应报错")
end)

T.case("色相 0..360 与饱和度 0..100 的区间被正确执行", function()
    local r = pipeline(xmlWith('', { "<crs:SplitToningShadowHue>400</crs:SplitToningShadowHue>" }))
    T.eq(r.settings.SplitToningShadowHue, 360, "色相上限 360")

    local r2 = pipeline(xmlWith('', { "<crs:SplitToningShadowSaturation>150</crs:SplitToningShadowSaturation>" }))
    T.eq(r2.settings.SplitToningShadowSaturation, 100, "饱和度上限 100")
end)

T.case("负数色相被收拢到 0", function()
    local r = pipeline(xmlWith('', { "<crs:ColorGradeGlobalHue>-30</crs:ColorGradeGlobalHue>" }))
    T.eq(r.settings.ColorGradeGlobalHue, 0, "色相下限 0")
end)

----------------------------------------------------------------------

T.suite("Validation / 防御性检查")

T.case("NaN 直接注入 settings 也被拦下", function()
    local nan = 0 / 0
    local bundle = {
        settings = { Exposure2012 = nan },
        applied = { { field = "Exposure2012", sdkField = "Exposure2012", value = nan } },
        errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    local result = Validation.validate(bundle)
    T.eq(result.settings.Exposure2012, nil, "NaN 必须被丢弃")
    T.truthy(#result.errors >= 1, "应报错")
end)

T.case("Infinity 直接注入 settings 也被拦下", function()
    local inf = 1 / 0
    local bundle = {
        settings = { Vibrance = inf },
        applied = { { field = "Vibrance", sdkField = "Vibrance", value = inf } },
        errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    local result = Validation.validate(bundle)
    T.eq(result.settings.Vibrance, nil, "Infinity 必须被丢弃")
end)

T.case("字符串混入数值字段 -> 报错而不是悄悄放行", function()
    local bundle = {
        settings = { Saturation = "0.5" },
        applied = { { field = "Saturation", sdkField = "Saturation", value = "0.5" } },
        errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    local result = Validation.validate(bundle)
    T.eq(result.settings.Saturation, nil, "字符串不应被写入")
    T.truthy(#result.errors >= 1, "应报错")
end)

T.case("未登记过的 SDK 键被丢弃并告警", function()
    local bundle = {
        settings = { TotallyMadeUpKey = 1 },
        applied = {}, errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    local result = Validation.validate(bundle)
    T.eq(result.settings.TotallyMadeUpKey, nil, "未登记的键必须被丢弃")
    T.truthy(#result.warnings >= 1, "应告警")
end)

T.case("曲线校验：长度非法 / 含非数字项", function()
    local bundle = {
        settings = { ToneCurvePV2012 = { 0, 0, 255 } },
        applied = {}, errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    local result = Validation.validate(bundle)
    T.eq(result.settings.ToneCurvePV2012, nil, "奇数长度曲线应被丢弃")
    T.truthy(#result.errors >= 1, "应报错")
end)

T.case("空 settings -> applicable = false 并给出提示", function()
    local result = Validation.validate({
        settings = {}, applied = {}, errors = {}, warnings = {},
        clamped = {}, ignored = {}, unsupported = {}, unknown = {}, skipped = {},
    })
    T.falsy(result.applicable, "空 settings 不应可应用")
    T.truthy(#result.warnings >= 1, "应提示没有可应用字段")
end)

T.case("运行期范围可覆盖静态建议区间", function()
    local bundle = {
        settings = { Contrast2012 = 80 },
        applied = { { field = "Contrast2012", sdkField = "Contrast2012", value = 80 } },
        errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    -- 假设 getRange 报告的真实上限是 50
    local result = Validation.validate(bundle, { runtimeRanges = { Contrast2012 = { -50, 50 } } })
    T.eq(result.settings.Contrast2012, 50, "应按运行期真实范围收拢")
    T.eq(result.rangeSource.Contrast2012, "runtime(getRange)", "应记录范围来源")
end)

T.case("Validation 不修改传入的 bundle", function()
    local bundle = {
        settings = { Contrast2012 = 150 },
        applied = {}, errors = {}, warnings = {}, clamped = {}, ignored = {},
        unsupported = {}, unknown = {}, skipped = {},
    }
    Validation.validate(bundle)
    T.eq(bundle.settings.Contrast2012, 150, "原始 bundle 不应被改动")
    T.eq(#bundle.clamped, 0, "原始 bundle 的 clamped 不应被写入")
end)

----------------------------------------------------------------------

T.suite("Validation / 全流程（fixtures）")

T.case("basic.xmp 全流程通过", function()
    local parsed, err = XmpParser.parseFile(FX .. "/basic.xmp")
    T.truthy(parsed ~= nil, "解析失败: " .. tostring(err))
    local bundle = XmpMapping.toDevelopSettings(parsed, { logger = SilentLogger })
    local result = Validation.validate(bundle)
    T.eq(#result.errors, 0, "不应有错误")
    T.truthy(result.ok, "应可应用")
    -- basic.xmp：11 个 Basic 数值 + 1 个布尔 + 24 个 HSL + 1 个白平衡 = 37
    T.eq(result.counts.settings, 37, "可应用字段数")
end)

----------------------------------------------------------------------

T.suite("DevelopSettings / 装配与 Preview")

local basicResult
do
    local parsed = XmpParser.parseFile(FX .. "/basic.xmp")
    local bundle = XmpMapping.toDevelopSettings(parsed, { logger = SilentLogger })
    basicResult = Validation.validate(bundle)
    basicResult.parsed = parsed
end

T.case("toApplyTable 只产出已登记的 SDK 键", function()
    local t = DevelopSettings.toApplyTable(basicResult)
    T.near(t.Exposure2012, 0.35)
    T.near(t.SaturationAdjustmentBlue, -10)
    for k in pairs(t) do
        T.truthy(XmpMapping.FIELDS[k] ~= nil, "出现了未登记的键: " .. tostring(k))
    end
end)

T.case("toApplyTable 会剔除未登记的键", function()
    local dirty = Utils.shallowCopy(basicResult)
    dirty.settings = Utils.shallowCopy(basicResult.settings)
    dirty.settings.BogusKey = 1
    local t = DevelopSettings.toApplyTable(dirty)
    T.eq(t.BogusKey, nil, "未登记的键必须被剔除")
    T.near(t.Exposure2012, 0.35, 1e-9, "正常字段应保留")
end)

T.case("summary 输出各分类计数", function()
    local s = DevelopSettings.summary(basicResult)
    T.near(s.fields, basicResult.counts.settings)
    T.eq(s.errors, 0)
    T.truthy(s.unsupported >= 1, "basic.xmp 含不支持字段")
end)

T.case("Preview 文本包含关键信息与参数行", function()
    local text = DevelopSettings.renderPreview(basicResult, {
        photoName  = "IMG_1023.CR3",
        xmpName    = "IMG_1023__Natural_Warm__AI-v1.xmp",
        sourceFile = "IMG_1023.CR3",
        presetName = "Natural Warm",
    })
    T.contains(text, "AI Color Plan", "标题")
    T.contains(text, "IMG_1023.CR3", "目标照片")
    T.contains(text, "Natural Warm", "预设名")
    T.contains(text, "Exposure", "Basic 字段名")
    T.contains(text, "+0.35", "曝光值")
    T.contains(text, "Blue Saturation", "HSL 字段名")
    T.contains(text, "Fields:", "统计行")
end)

T.case("Preview 默认隐藏零值字段", function()
    local zeroResult = pipeline(xmlWith('crs:Exposure2012="0" crs:Vibrance="5"'))
    local text = DevelopSettings.renderPreview(zeroResult)
    T.contains(text, "Vibrance", "非零字段应显示")
    T.falsy(text:find("Exposure", 1, true) ~= nil, "零值字段默认不显示")
end)

T.case("groupApplied 按 GROUP_ORDER 分组", function()
    local groups = DevelopSettings.groupApplied(basicResult)
    T.truthy(#groups >= 3, "应至少有 basic / whitebalance / hsl 三组")
    T.eq(groups[1].group, "basic", "basic 应排在最前")
end)

T.case("buildReportRecord 产出 Logger 需要的结构", function()
    local rec = DevelopSettings.buildReportRecord(basicResult, {
        operation = "APPLY", photoName = "IMG_1023.CR3",
        xmpName = "IMG_1023__Natural_Warm__AI-v1.xmp",
        presetName = "Natural Warm", sourceFile = "IMG_1023.CR3",
        aiVersion = "portrait-color-v1", result = "SUCCESS",
    })
    T.eq(rec.operation, "APPLY")
    T.eq(rec.photo, "IMG_1023.CR3")
    T.eq(rec.result, "SUCCESS")
    T.truthy(#rec.applied >= 35, "applied 明细应完整，实际 " .. tostring(#rec.applied))
    local one = rec.applied[1]
    T.truthy(one.field ~= nil and one.rawValue ~= nil and one.value ~= nil,
        "每条明细都应含 field / rawValue / value")
end)

T.case("Logger 报告包含 Applied / Ignored / Unsupported / Result 段", function()
    local Logger = require "Logger"
    Logger.configure { level = "error", echo = false }
    Logger.clear()

    local rec = DevelopSettings.buildReportRecord(basicResult, {
        operation = "APPLY", photoName = "IMG_1023.CR3",
        xmpName = "IMG_1023__Natural_Warm__AI-v1.xmp", result = "SUCCESS",
    })
    local text = Logger.buildApplyReport(rec, true)
    T.contains(text, "APPLY", "操作名")
    T.contains(text, "IMG_1023.CR3", "照片")
    T.contains(text, "Applied", "Applied 段")
    T.contains(text, "Ignored", "Ignored 段")
    T.contains(text, "Unknown XMP field", "未知字段段（SomeFutureField 应落在这里）")
    T.contains(text, "Result", "Result 段")
    T.contains(text, "SUCCESS", "结果值")
    T.contains(text, "PresetType", "应列出被忽略的 PresetType")
end)

T.case("日志级别过滤生效（否则字段级 debug 会淹掉日志文件）", function()
    local Logger = require "Logger"

    Logger.configure { level = "error", echo = false }
    T.eq(Logger.debug("d"), nil, "低于阈值的 debug 应被丢弃")
    T.eq(Logger.info("i"), nil, "低于阈值的 info 应被丢弃")
    T.eq(Logger.warn("w"), nil, "低于阈值的 warn 应被丢弃")
    T.truthy(Logger.error("e") ~= nil, "达到阈值的应产出")

    Logger.configure { level = "info" }
    T.eq(Logger.debug("d"), nil, "info 级别下 debug 仍应被丢弃")
    T.truthy(Logger.info("i") ~= nil, "info 级别下 info 应产出")
    T.truthy(Logger.warn("w") ~= nil, "info 级别下 warn 应产出")

    Logger.configure { level = "error", echo = false }
end)

----------------------------------------------------------------------

T.suite("PhotoResolver / 文件名匹配")

T.case("文件名不一致应被判定为 mismatch", function()
    local status, detail = PhotoResolver.compareSourceFile("IMG_1023.CR3",
        { fileName = "IMG_1048.CR3" })
    T.eq(status, "mismatch", "不一致必须被识别出来")
    T.contains(detail, "IMG_1023.CR3", "详情应含 XMP 侧文件名")
    T.contains(detail, "IMG_1048.CR3", "详情应含照片侧文件名")
end)

T.case("完全一致 -> match", function()
    local status = PhotoResolver.compareSourceFile("IMG_1023.CR3", { fileName = "IMG_1023.CR3" })
    T.eq(status, "match")
end)

T.case("大小写差异被容忍 -> match", function()
    local status = PhotoResolver.compareSourceFile("img_1023.cr3", { fileName = "IMG_1023.CR3" })
    T.eq(status, "match")
end)

T.case("同名不同扩展名 -> probable（宽容匹配）", function()
    local status = PhotoResolver.compareSourceFile("IMG_1023.CR3", { fileName = "IMG_1023.DNG" })
    T.eq(status, "probable")
end)

T.case("XMP 未声明来源 -> unknown（不阻断）", function()
    local status = PhotoResolver.compareSourceFile(nil, { fileName = "IMG_1023.CR3" })
    T.eq(status, "unknown")
end)

T.case("看起来是官方随图 sidecar 时给出警示", function()
    local yes, why = PhotoResolver.looksLikeOfficialSidecar(
        "/photos/IMG_1023.xmp", { fileName = "IMG_1023.CR3" })
    T.truthy(yes, "同名 xmp 应被识别为官方 sidecar")
    T.contains(why, "覆写", "提示应说明可能被覆写")

    local no = PhotoResolver.looksLikeOfficialSidecar(
        "/photos/IMG_1023__Natural_Warm__AI-v1.xmp", { fileName = "IMG_1023.CR3" })
    T.falsy(no, "带 AI 后缀的独立文件不应被误判")
end)

T.case("isRawLike 判定", function()
    T.truthy(PhotoResolver.isRawLike("RAW"))
    T.truthy(PhotoResolver.isRawLike("dng"))
    T.falsy(PhotoResolver.isRawLike("JPG"))
    T.falsy(PhotoResolver.isRawLike("TIFF"))
    T.eq(PhotoResolver.isRawLike(nil), nil)
end)

----------------------------------------------------------------------

T.suite("PhotoResolver / 元数据取值 API 的正确性（回归防护）")

-- 官方 LrPhoto API Reference 给出的 getRawMetadata 合法键。
-- ★ 注意这里**没有 fileName** —— fileName 属于 getFormattedMetadata。
-- （曾经踩过：用 getRawMetadata("fileName") 会静默拿到 nil，界面显示「未知」。）
local RAW_METADATA_KEYS = {
    fileSize = true, rating = true, dimensions = true, croppedDimensions = true,
    shutterSpeed = true, aperture = true, exposureBias = true, flash = true,
    isoSpeedRating = true, focalLength = true, focalLength35mm = true,
    dateTimeOriginal = true, dateTimeDigitized = true, dateTime = true,
    gps = true, gpsAltitude = true, countVirtualCopies = true,
    virtualCopies = true, masterPhoto = true, isVirtualCopy = true,
    countStackInFolderMembers = true, stackInFolderMembers = true,
    isInStackInFolder = true, stackInFolderIsCollapsed = true,
    stackPositionInFolder = true, topOfStackInFolderContainingPhoto = true,
    colorNameForLabel = true,
    fileFormat = true, width = true, height = true, aspectRatio = true,
    isCropped = true, dateTimeOriginalISO8601 = true,
    dateTimeDigitizedISO8601 = true, dateTimeISO8601 = true,
    lastEditTime = true, editCount = true, copyrightState = true,
    uuid = true, path = true, isVideo = true, durationInSeconds = true,
    keywords = true, customMetadata = true,
    pickStatus = true, trimmedDurationInSeconds = true, durationRatio = true,
    trimmedDurationRatio = true, locationIsPrivate = true,
    smartPreviewInfo = true, gpsImgDirection = true,
}

-- getFormattedMetadata 的合法键（节选）
local FORMATTED_METADATA_KEYS = {
    keywordTags = true, keywordTagsForExport = true,
    fileName = true, preservedFileName = true, copyName = true,
    folderName = true, fileSize = true, fileType = true, rating = true,
    label = true, title = true, caption = true, dimensions = true,
    croppedDimensions = true, exposure = true, shutterSpeed = true,
    aperture = true, exposureBias = true, flash = true, isoSpeedRating = true,
    focalLength = true, focalLength35mm = true, lens = true, subjectDistance = true,
    dateTimeOriginal = true, dateTime = true,
    cameraMake = true, cameraModel = true, creator = true,
    country = true, city = true, copyright = true, gps = true,
}

--- 造一个「只认官方文档化键」的假照片对象：
--  传错键会直接报错（真实 SDK 是返回 nil，这里更严格，便于把错误提前暴露）
local function fakePhoto(fields)
    return {
        getRawMetadata = function(_, key)
            if not RAW_METADATA_KEYS[key] then
                error("未知的 getRawMetadata 键: " .. tostring(key), 0)
            end
            return fields[key]
        end,
        getFormattedMetadata = function(_, key)
            if not FORMATTED_METADATA_KEYS[key] then
                error("未知的 getFormattedMetadata 键: " .. tostring(key), 0)
            end
            return fields[key]
        end,
    }
end

T.case("describe 只使用文档化的键，且能取到文件名", function()
    local photo = fakePhoto {
        fileName   = "IMG_1023.CR3",
        path       = "/photos/2024/IMG_1023.CR3",
        fileFormat = "RAW",
    }
    local d = PhotoResolver.describe(photo)
    T.eq(d.fileName, "IMG_1023.CR3",
        "文件名必须走 getFormattedMetadata('fileName')；用 getRawMetadata 会拿到 nil")
    T.eq(d.fileNameSource, "getFormattedMetadata", "应记录取值来源")
    T.eq(d.fileFormat, "RAW")
    T.eq(d.isVirtualCopy, false)
    T.eq(d.path, "/photos/2024/IMG_1023.CR3")
    T.eq(d.stem, "img_1023", "主干名应为小写去扩展名")
end)

T.case("describe 在拿不到 fileName 时用 path 兜底", function()
    local photo = fakePhoto {
        -- fileName 缺失（模拟极端情况）
        path = "/photos/2024/IMG_1048.CR3",
    }
    local d = PhotoResolver.describe(photo)
    T.eq(d.fileName, "IMG_1048.CR3", "应从 path 取到叶子名")
    T.eq(d.fileNameSource, "path", "来源应标为 path")
end)

T.case("describe 对 nil 与「所有方法都抛错」的照片对象都不崩溃", function()
    T.eq(PhotoResolver.describe(nil).fileName, nil, "nil 输入应返回空描述")

    local broken = {
        getRawMetadata       = function() error("boom", 0) end,
        getFormattedMetadata = function() error("boom", 0) end,
    }
    local d = PhotoResolver.describe(broken)
    T.eq(d.fileName, nil, "全部取值失败时应安静返回 nil，而不是抛穿")
    T.eq(d.isVirtualCopy, false)
end)

T.case("describe 会把失败原因记进 diagnostics（不再被静默吞掉）", function()
    local broken = {
        getRawMetadata       = function() error("模拟的错误 A", 0) end,
        getFormattedMetadata = function() error("模拟的错误 B", 0) end,
    }
    local d = PhotoResolver.describe(broken)
    T.isTable(d.diagnostics, "diagnostics 应为表")
    T.truthy(#d.diagnostics > 0, "应至少有若干诊断行")
    local joined = table.concat(d.diagnostics, "\n")
    T.contains(joined, "模拟的错误 B", "应记录 getFormattedMetadata 的错误原文")
    T.contains(joined, "模拟的错误 A", "应记录 getRawMetadata 的错误原文")
end)

T.case("fetchMetaViaCatalog 能从目录级批量读取兜底拿到 path", function()
    local fakePhotoObj = { name = "p1" }
    local fakeCatalog = {
        batchGetRawMetadata = function(_, photos, keys)
            T.eq(photos[1], fakePhotoObj, "应传入目标照片")
            T.eq(keys[1], "path", "应请求 path")
            return { [fakePhotoObj] = { path = "/photos/DSC_0001.ARW", fileFormat = "RAW" } }
        end,
    }
    local meta, err = PhotoResolver.fetchMetaViaCatalog(fakePhotoObj, fakeCatalog)
    T.truthy(meta ~= nil, "应取到元数据: " .. tostring(err))
    T.eq(meta.path, "/photos/DSC_0001.ARW")
    T.eq(meta.fileFormat, "RAW")
end)

T.case("fetchMetaViaCatalog 在批量读取失败时返回可读错误", function()
    local fakeCatalog = {
        batchGetRawMetadata = function() error("目录忙", 0) end,
    }
    local meta, err = PhotoResolver.fetchMetaViaCatalog({}, fakeCatalog)
    T.eq(meta, nil, "应返回 nil")
    T.contains(tostring(err), "batchGetRawMetadata", "错误信息应指明失败点")
end)

T.case("diagnose 输出版本可控的诊断行", function()
    local lines = PhotoResolver.diagnose(nil, nil)
    T.isTable(lines, "应返回表")
    T.truthy(#lines > 0, "应至少有一行")
    T.contains(table.concat(lines, "\n"), "photo", "应包含 photo 相关信息")
end)

----------------------------------------------------------------------

T.suite("Utils / 数值与路径")

T.case("parseNumber 严格拒绝十六进制", function()
    local v, err = Utils.parseNumber("0x10")
    T.eq(v, nil, "0x10 不应被当作数字")
    T.truthy(err ~= nil)
end)

T.case("parseNumber 接受常规写法", function()
    T.near(Utils.parseNumber("0.35"), 0.35)
    T.near(Utils.parseNumber("  -25  "), -25, 1e-9, "应容忍前后空白")
    T.near(Utils.parseNumber("+18"), 18)
    T.near(Utils.parseNumber("5600"), 5600)
    T.near(Utils.parseNumber(".5"), 0.5)
    T.near(Utils.parseNumber("5."), 5)
end)

T.case("formatSigned 的显示格式", function()
    T.eq(Utils.formatSigned(0.35), "+0.35")
    T.eq(Utils.formatSigned(-25), "-25")
    T.eq(Utils.formatSigned(0), "0")
    T.eq(Utils.formatPlain(5600), "5600")
end)

T.case("tolerantBaseName 去掉 XMP 的 AI 后缀", function()
    T.eq(Utils.tolerantBaseName("IMG_1023__Natural_Warm__AI-v1.xmp"), "img_1023")
    T.eq(Utils.tolerantBaseName("/a/b/IMG_1023.CR3"), "img_1023")
end)
