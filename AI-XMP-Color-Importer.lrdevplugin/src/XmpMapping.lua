--[[
    src/XmpMapping.lua  —  XMP -> Lightroom SDK Develop Settings 映射层（纯 Lua）

    ★ 唯一事实来源 ★
       本文件集中承载所有字段映射、类型、范围、颜色名、白平衡转换、色调曲线转换。
       业务代码（UI / Apply / Preview）不得再出现零散的字段名字符串。

    ★ 键名可信度 ★
       每一项都带 source 字段，标明依据。经核实的来源：
         [A] Adobe Lightroom Classic SDK API Reference - Namespace LrDevelopController
             参数分组表（adjustPanel / tonePanel / mixerPanel / splitToningPanel /
             detailPanel / effectsPanel / lensCorrectionsPanel / calibratePanel）
         [B] Adobe SDK API Reference - LrPhoto:getDevelopSettings 返回值成员表
             （其中「The following items are first provided in version 4.0」一节给出 2012 系列键名）
         [C] 真实开源插件 develop-keeper-lrplugin 的 sidecar 样例，
             为 getDevelopSettings() 真实输出（含 ToneCurvePV2012 扁平数组、ColorGrade* 键）
             https://github.com/grubyak/develop-keeper-lrplugin
         [D] 真实开源插件 lightroom-ai-bridge 的文档：apply 使用 getDevelopSettings 的 raw 键
             （明确举例 Exposure2012）
             https://github.com/aslanoov/lightroom-ai-bridge

    ★ 键名说明（易错）★
       有一种写法是把 Exposure2012 映射到 sdk "Exposure"。这是 **错误的**：
       Process Version 2012 之后，活动键名就是带 2012 后缀的一组
       （Exposure2012 / Contrast2012 / Highlights2012 / ... ），
       不带的 Exposure / Brightness / Contrast / Shadows 是 PV2010 遗留键，
       在 PV2012+ 下不生效。详见 README「支持的字段」。

    Lua 5.1 兼容。
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径，
-- 详见 src/Loader.lua 顶部引用的官方原文）
local Utils    = AI_COLOR_IMPORTER.load("src/Utils.lua")
local Logger   = AI_COLOR_IMPORTER.load("src/Logger.lua")
local Manifest = AI_COLOR_IMPORTER.load("manifest.lua")

local XmpMapping = {}

----------------------------------------------------------------------
-- 来源标注
----------------------------------------------------------------------
local SRC = {
    ADJUST    = "[A] LrDevelopController 参数表 / adjustPanel",
    TONE      = "[A] LrDevelopController 参数表 / tonePanel",
    MIXER     = "[A] LrDevelopController 参数表 / mixerPanel (HSL)",
    SPLIT     = "[A] LrDevelopController 参数表 / splitToningPanel",
    DETAIL    = "[A] LrDevelopController 参数表 / detailPanel",
    EFFECTS   = "[A] LrDevelopController 参数表 / effectsPanel",
    LENS      = "[A] LrDevelopController 参数表 / lensCorrectionsPanel",
    CALIB     = "[A] LrDevelopController 参数表 / calibratePanel",
    GETDEV    = "[B] LrPhoto:getDevelopSettings 2012 系列成员表 (SDK 4.0+)",
    CURVE     = "[C] getDevelopSettings 真实输出：ToneCurvePV2012 为扁平数字数组",
    GRADING   = "[C] getDevelopSettings 真实输出：ColorGrade* / SplitToning* 键名",
}
XmpMapping.SOURCES = SRC

----------------------------------------------------------------------
-- 颜色名
-- 八个颜色通道集中定义，HSL 的 24 个字段由它生成，业务代码不再出现颜色字符串。
----------------------------------------------------------------------
XmpMapping.COLOR_NAMES = {
    "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta",
}

XmpMapping.COLOR_MAP = {
    Red     = "Red",
    Orange  = "Orange",
    Yellow  = "Yellow",
    Green   = "Green",
    Aqua    = "Aqua",
    Blue    = "Blue",
    Purple  = "Purple",
    Magenta = "Magenta",
}

XmpMapping.COLOR_LABEL_ZH = {
    Red = "红", Orange = "橙", Yellow = "黄", Green = "绿",
    Aqua = "浅绿", Blue = "蓝", Purple = "紫", Magenta = "品红",
}

--- 用于 Preview 的分组顺序
XmpMapping.GROUP_ORDER = {
    "basic", "whitebalance", "tonecurve", "parametric",
    "hsl", "colorgrading", "extDetail", "extEffects", "extLens", "extCalibrate",
}

XmpMapping.GROUP_LABEL = {
    basic        = "Basic",
    whitebalance = "White Balance",
    tonecurve    = "Tone Curve",
    parametric   = "Parametric Tone Curve",
    hsl          = "Color Mixer / HSL",
    colorgrading = "Color Grading",
    extDetail    = "Detail",
    extEffects   = "Effects",
    extLens      = "Lens Corrections",
    extCalibrate = "Calibration",
}

----------------------------------------------------------------------
-- 字段映射表
--   key   = XMP 中的 localName（命名空间必须是 crs URI）
--   value = {
--     sdk     : 写入 applyDevelopSettings 的键名
--     type    : "number" | "boolean" | "string" | "enum" | "toneCurve"
--     group   : 预览分组
--     tier    : "v1" 默认范围 | "ext" 已核实键名但属扩展范围
--     range   : {min, max} 仅作「建议区间」，运行时会优先用
--               LrDevelopController.getRange(param) 的真实范围覆盖
--     display : 预览显示名
--     source  : 依据
--   }
----------------------------------------------------------------------
local FIELDS = {}

----------------------------------------------------------------------
-- 1) Basic
----------------------------------------------------------------------
FIELDS.Exposure2012 = {
    sdk = "Exposure2012", type = "number", group = "basic", tier = "v1",
    range = { -5, 5 }, display = "Exposure", source = SRC.GETDEV .. " ; " .. SRC.ADJUST,
}
FIELDS.Contrast2012 = {
    sdk = "Contrast2012", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Contrast", source = SRC.GETDEV,
}
FIELDS.Highlights2012 = {
    sdk = "Highlights2012", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Highlights", source = SRC.GETDEV,
}
FIELDS.Shadows2012 = {
    sdk = "Shadows2012", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Shadows", source = SRC.GETDEV,
}
FIELDS.Whites2012 = {
    sdk = "Whites2012", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Whites", source = SRC.GETDEV,
}
FIELDS.Blacks2012 = {
    sdk = "Blacks2012", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Blacks", source = SRC.GETDEV,
}
FIELDS.Texture = {
    sdk = "Texture", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Texture", source = SRC.ADJUST,
}
FIELDS.Clarity2012 = {
    sdk = "Clarity2012", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Clarity", source = SRC.GETDEV,
}
FIELDS.Dehaze = {
    sdk = "Dehaze", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Dehaze", source = SRC.GETDEV,
}
FIELDS.Vibrance = {
    sdk = "Vibrance", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Vibrance", source = SRC.GETDEV,
}
FIELDS.Saturation = {
    sdk = "Saturation", type = "number", group = "basic", tier = "v1",
    range = { -100, 100 }, display = "Saturation", source = SRC.GETDEV,
}
FIELDS.ConvertToGrayscale = {
    sdk = "ConvertToGrayscale", type = "boolean", group = "basic", tier = "v1",
    display = "Convert to B&W", source = SRC.GETDEV,
}

----------------------------------------------------------------------
-- 2) White Balance
--    Temperature / Tint 的真实合法区间随相机与文件格式变化，
--    因此这里不写死范围（range = nil），由 Validation 走「无范围」分支，
--    运行期若可用则用 LrDevelopController.getRange("Temperature") 覆盖。
----------------------------------------------------------------------
FIELDS.WhiteBalance = {
    sdk = "WhiteBalance", type = "enum", group = "whitebalance", tier = "v1",
    display = "White Balance",
    values = {}, -- 见下方 WB_PRESETS，mapWhiteBalance 负责
    source = SRC.GETDEV .. " ; LrPhoto:getDevelopSettings 返回 WhiteBalance(string)",
}
FIELDS.Temperature = {
    sdk = "Temperature", type = "number", group = "whitebalance", tier = "v1",
    range = nil, -- 随相机变化，见上方注释
    display = "Temperature (K)", source = SRC.ADJUST,
}
FIELDS.Tint = {
    sdk = "Tint", type = "number", group = "whitebalance", tier = "v1",
    range = { -150, 150 }, display = "Tint", source = SRC.ADJUST,
}

----------------------------------------------------------------------
-- 3) Tone Curve
----------------------------------------------------------------------
FIELDS.ToneCurvePV2012 = {
    sdk = "ToneCurvePV2012", type = "toneCurve", group = "tonecurve", tier = "v1",
    display = "Point Curve", source = SRC.CURVE,
}
FIELDS.ToneCurvePV2012Red = {
    sdk = "ToneCurvePV2012Red", type = "toneCurve", group = "tonecurve", tier = "v1",
    display = "Point Curve (Red)", source = SRC.CURVE,
}
FIELDS.ToneCurvePV2012Green = {
    sdk = "ToneCurvePV2012Green", type = "toneCurve", group = "tonecurve", tier = "v1",
    display = "Point Curve (Green)", source = SRC.CURVE,
}
FIELDS.ToneCurvePV2012Blue = {
    sdk = "ToneCurvePV2012Blue", type = "toneCurve", group = "tonecurve", tier = "v1",
    display = "Point Curve (Blue)", source = SRC.CURVE,
}
FIELDS.ToneCurveName2012 = {
    sdk = "ToneCurveName2012", type = "enum", group = "tonecurve", tier = "v1",
    display = "Tone Curve Name",
    values = { Linear = true, ["Medium Contrast"] = true, ["Strong Contrast"] = true, Custom = true },
    strictEnum = false,
    source = SRC.GETDEV,
}

-- 参数化曲线（7 个）
FIELDS.ParametricShadows = {
    sdk = "ParametricShadows", type = "number", group = "parametric", tier = "v1",
    range = { -100, 100 }, display = "Parametric Shadows", source = SRC.TONE,
}
FIELDS.ParametricDarks = {
    sdk = "ParametricDarks", type = "number", group = "parametric", tier = "v1",
    range = { -100, 100 }, display = "Parametric Darks", source = SRC.TONE,
}
FIELDS.ParametricLights = {
    sdk = "ParametricLights", type = "number", group = "parametric", tier = "v1",
    range = { -100, 100 }, display = "Parametric Lights", source = SRC.TONE,
}
FIELDS.ParametricHighlights = {
    sdk = "ParametricHighlights", type = "number", group = "parametric", tier = "v1",
    range = { -100, 100 }, display = "Parametric Highlights", source = SRC.TONE,
}
FIELDS.ParametricShadowSplit = {
    sdk = "ParametricShadowSplit", type = "number", group = "parametric", tier = "v1",
    range = { 0, 100 }, display = "Shadow Split", source = SRC.TONE,
}
FIELDS.ParametricMidtoneSplit = {
    sdk = "ParametricMidtoneSplit", type = "number", group = "parametric", tier = "v1",
    range = { 0, 100 }, display = "Midtone Split", source = SRC.TONE,
}
FIELDS.ParametricHighlightSplit = {
    sdk = "ParametricHighlightSplit", type = "number", group = "parametric", tier = "v1",
    range = { 0, 100 }, display = "Highlight Split", source = SRC.TONE,
}

----------------------------------------------------------------------
-- 4) HSL / Color Mixer —— 由 COLOR_NAMES 生成 24 个字段
--    注意：SDK 里就是 HueAdjustment<Color> / SaturationAdjustment<Color> /
--          LuminanceAdjustment<Color>，与 XMP 同名同义，属直通。
----------------------------------------------------------------------
for _, c in ipairs(XmpMapping.COLOR_NAMES) do
    local zh = XmpMapping.COLOR_LABEL_ZH[c]
    FIELDS["HueAdjustment" .. c] = {
        sdk = "HueAdjustment" .. c, type = "number", group = "hsl", tier = "v1",
        range = { -100, 100 }, display = c .. " Hue",
        displayZh = zh .. " 色相", colorChannel = c, source = SRC.MIXER,
    }
    FIELDS["SaturationAdjustment" .. c] = {
        sdk = "SaturationAdjustment" .. c, type = "number", group = "hsl", tier = "v1",
        range = { -100, 100 }, display = c .. " Saturation",
        displayZh = zh .. " 饱和度", colorChannel = c, source = SRC.MIXER,
    }
    FIELDS["LuminanceAdjustment" .. c] = {
        sdk = "LuminanceAdjustment" .. c, type = "number", group = "hsl", tier = "v1",
        range = { -100, 100 }, display = c .. " Luminance",
        displayZh = zh .. " 明度", colorChannel = c, source = SRC.MIXER,
    }
end

----------------------------------------------------------------------
-- 5) Color Grading
--    ★ 关键转换点 ★
--      阴影轮 / 高光轮的 色相+饱和度 在 SDK 与 XMP 里都叫 SplitToning*；
--      中间调 / 全局 的色相、饱和度，以及四个轮的 Lum，叫 ColorGrade*。
--      部分 AI 会写 ColorGradeShadowHue / ColorGradeHighlightSat 这类
--      「看起来更一致」的名字 —— 这些键在 SDK 中并 **不存在**，
--      必须经 ALIASES 转到 SplitToning*，否则 Lightroom 会静默丢弃。
----------------------------------------------------------------------
FIELDS.SplitToningShadowHue = {
    sdk = "SplitToningShadowHue", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 360 }, display = "Shadows Hue", source = SRC.GRADING,
}
FIELDS.SplitToningShadowSaturation = {
    sdk = "SplitToningShadowSaturation", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 100 }, display = "Shadows Saturation", source = SRC.GRADING,
}
FIELDS.ColorGradeShadowLum = {
    sdk = "ColorGradeShadowLum", type = "number", group = "colorgrading", tier = "v1",
    range = { -100, 100 }, display = "Shadows Luminance", source = SRC.GRADING,
}
FIELDS.ColorGradeMidtoneHue = {
    sdk = "ColorGradeMidtoneHue", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 360 }, display = "Midtones Hue", source = SRC.GRADING,
}
FIELDS.ColorGradeMidtoneSat = {
    sdk = "ColorGradeMidtoneSat", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 100 }, display = "Midtones Saturation", source = SRC.GRADING,
}
FIELDS.ColorGradeMidtoneLum = {
    sdk = "ColorGradeMidtoneLum", type = "number", group = "colorgrading", tier = "v1",
    range = { -100, 100 }, display = "Midtones Luminance", source = SRC.GRADING,
}
FIELDS.SplitToningHighlightHue = {
    sdk = "SplitToningHighlightHue", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 360 }, display = "Highlights Hue", source = SRC.GRADING,
}
FIELDS.SplitToningHighlightSaturation = {
    sdk = "SplitToningHighlightSaturation", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 100 }, display = "Highlights Saturation", source = SRC.GRADING,
}
FIELDS.ColorGradeHighlightLum = {
    sdk = "ColorGradeHighlightLum", type = "number", group = "colorgrading", tier = "v1",
    range = { -100, 100 }, display = "Highlights Luminance", source = SRC.GRADING,
}
FIELDS.ColorGradeGlobalHue = {
    sdk = "ColorGradeGlobalHue", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 360 }, display = "Global Hue", source = SRC.GRADING,
}
FIELDS.ColorGradeGlobalSat = {
    sdk = "ColorGradeGlobalSat", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 100 }, display = "Global Saturation", source = SRC.GRADING,
}
FIELDS.ColorGradeGlobalLum = {
    sdk = "ColorGradeGlobalLum", type = "number", group = "colorgrading", tier = "v1",
    range = { -100, 100 }, display = "Global Luminance", source = SRC.GRADING,
}
FIELDS.ColorGradeBlending = {
    sdk = "ColorGradeBlending", type = "number", group = "colorgrading", tier = "v1",
    range = { 0, 100 }, display = "Blending", source = SRC.GRADING,
}
FIELDS.SplitToningBalance = {
    sdk = "SplitToningBalance", type = "number", group = "colorgrading", tier = "v1",
    range = { -100, 100 }, display = "Balance", source = SRC.GRADING,
}

----------------------------------------------------------------------
-- 6) 扩展字段（tier = "ext"）
--    这些键名同样经过核实（见 SRC），但不在 V1 范围内。
--    默认不应用；由 manifest.defaults.applyExtendedFields 控制。
----------------------------------------------------------------------
-- Detail
FIELDS.Sharpness = {
    sdk = "Sharpness", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 150 }, display = "Sharpening Amount", source = SRC.DETAIL,
}
FIELDS.SharpenRadius = {
    sdk = "SharpenRadius", type = "number", group = "extDetail", tier = "ext",
    range = { 0.5, 3.0 }, display = "Sharpen Radius", source = SRC.DETAIL,
}
FIELDS.SharpenDetail = {
    sdk = "SharpenDetail", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Sharpen Detail", source = SRC.DETAIL,
}
FIELDS.SharpenEdgeMasking = {
    sdk = "SharpenEdgeMasking", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Sharpen Edge Masking", source = SRC.DETAIL,
}
FIELDS.LuminanceSmoothing = {
    sdk = "LuminanceSmoothing", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Luminance Noise Reduction", source = SRC.DETAIL,
}
FIELDS.LuminanceNoiseReductionDetail = {
    sdk = "LuminanceNoiseReductionDetail", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Luminance NR Detail", source = SRC.DETAIL,
}
FIELDS.LuminanceNoiseReductionContrast = {
    sdk = "LuminanceNoiseReductionContrast", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Luminance NR Contrast", source = SRC.DETAIL,
}
FIELDS.ColorNoiseReduction = {
    sdk = "ColorNoiseReduction", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Color Noise Reduction", source = SRC.DETAIL,
}
FIELDS.ColorNoiseReductionDetail = {
    sdk = "ColorNoiseReductionDetail", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Color NR Detail", source = SRC.DETAIL,
}
FIELDS.ColorNoiseReductionSmoothness = {
    sdk = "ColorNoiseReductionSmoothness", type = "number", group = "extDetail", tier = "ext",
    range = { 0, 100 }, display = "Color NR Smoothness", source = SRC.DETAIL,
}
-- Effects
FIELDS.PostCropVignetteAmount = {
    sdk = "PostCropVignetteAmount", type = "number", group = "extEffects", tier = "ext",
    range = { -100, 100 }, display = "Post-Crop Vignette Amount", source = SRC.EFFECTS,
}
FIELDS.PostCropVignetteMidpoint = {
    sdk = "PostCropVignetteMidpoint", type = "number", group = "extEffects", tier = "ext",
    range = { 0, 100 }, display = "Vignette Midpoint", source = SRC.EFFECTS,
}
FIELDS.PostCropVignetteFeather = {
    sdk = "PostCropVignetteFeather", type = "number", group = "extEffects", tier = "ext",
    range = { 0, 100 }, display = "Vignette Feather", source = SRC.EFFECTS,
}
FIELDS.PostCropVignetteRoundness = {
    sdk = "PostCropVignetteRoundness", type = "number", group = "extEffects", tier = "ext",
    range = { -100, 100 }, display = "Vignette Roundness", source = SRC.EFFECTS,
}
FIELDS.PostCropVignetteStyle = {
    sdk = "PostCropVignetteStyle", type = "enum", group = "extEffects", tier = "ext",
    display = "Vignette Style", strictEnum = true,
    values = { ["0"] = 0, ["1"] = 1, ["2"] = 2, ["3"] = 3 },
    source = SRC.EFFECTS,
}
FIELDS.PostCropVignetteHighlightContrast = {
    sdk = "PostCropVignetteHighlightContrast", type = "number", group = "extEffects", tier = "ext",
    range = { 0, 100 }, display = "Vignette Highlight Contrast", source = SRC.EFFECTS,
}
FIELDS.GrainAmount = {
    sdk = "GrainAmount", type = "number", group = "extEffects", tier = "ext",
    range = { 0, 100 }, display = "Grain Amount", source = SRC.EFFECTS,
}
FIELDS.GrainSize = {
    sdk = "GrainSize", type = "number", group = "extEffects", tier = "ext",
    range = { 0, 100 }, display = "Grain Size", source = SRC.EFFECTS,
}
FIELDS.GrainFrequency = {
    sdk = "GrainFrequency", type = "number", group = "extEffects", tier = "ext",
    range = { 0, 100 }, display = "Grain Frequency", source = SRC.EFFECTS,
}
-- Lens Corrections
FIELDS.AutoLateralCA = {
    sdk = "AutoLateralCA", type = "number", group = "extLens", tier = "ext",
    range = { 0, 1 }, display = "Remove Chromatic Aberration", source = SRC.LENS,
}
-- OverrideLookVignette：镜头配置文件里的「覆盖 Look 暗角」开关。
-- 官方 LrDevelopController 参数表里没有它，但 Lightroom External Controller API 的
-- adjustable parameters 清单明确列出；XMP crs: 侧的类型是 boolean。
FIELDS.OverrideLookVignette = {
    sdk = "OverrideLookVignette", type = "boolean", group = "extLens", tier = "ext",
    display = "Override Look Vignette",
    source = "Lightroom External Controller API 参数清单 + XMP crs: 侧为 boolean",
}
-- Calibration
FIELDS.ShadowTint = {
    sdk = "ShadowTint", type = "number", group = "extCalibrate", tier = "ext",
    range = { -100, 100 }, display = "Shadow Tint", source = SRC.CALIB,
}
for _, c in ipairs({ "Red", "Green", "Blue" }) do
    FIELDS[c .. "Hue"] = {
        sdk = c .. "Hue", type = "number", group = "extCalibrate", tier = "ext",
        range = { -100, 100 }, display = c .. " Primary Hue", source = SRC.CALIB,
    }
    FIELDS[c .. "Saturation"] = {
        sdk = c .. "Saturation", type = "number", group = "extCalibrate", tier = "ext",
        range = { -100, 100 }, display = c .. " Primary Saturation", source = SRC.CALIB,
    }
end

XmpMapping.FIELDS = FIELDS

----------------------------------------------------------------------
-- 别名表：AI 可能写出的「合理但 SDK 不存在」的键名
--   key -> 规范字段名（必须存在于 FIELDS）
-- 颜色分级的阴影/高光轮 色相+饱和度 是唯一已知的真实错名点。
----------------------------------------------------------------------
XmpMapping.ALIASES = {
    ColorGradeShadowHue       = "SplitToningShadowHue",
    ColorGradeShadowSat       = "SplitToningShadowSaturation",
    ColorGradeShadowSaturation = "SplitToningShadowSaturation",
    ColorGradeHighlightHue    = "SplitToningHighlightHue",
    ColorGradeHighlightSat    = "SplitToningHighlightSaturation",
    ColorGradeHighlightSaturation = "SplitToningHighlightSaturation",
    ColorGradeMidtoneSaturation   = "ColorGradeMidtoneSat",
    ColorGradeGlobalSaturation    = "ColorGradeGlobalSat",
}

----------------------------------------------------------------------
-- 预设元数据（不是 Develop 参数，静默忽略 + 记日志）
----------------------------------------------------------------------
XmpMapping.IGNORED_METADATA = {
    PresetType = true, UUID = true, Cluster = true, Group = true,
    Name = true, ShortName = true, SortName = true, Description = true,
    Copyright = true, ContactInfo = true, Version = true,
    ProcessVersion = true,               -- 见 README：刻意不应用，避免改动渲染基准
    CameraModelRestriction = true,
    HasSettings = true, AlreadyApplied = true,
    AIColorSchema = true, AIVersion = true, AIColorVersion = true, AIModel = true,
    Creator = true, CreatorTool = true, Title = true,
    -- XMP 的源文件名（用于来源照片匹配），不是 Develop 参数
    RawFileName = true,
}

-- 前缀规则：Supports* / crs:SupportsAmount 等
XmpMapping.IGNORED_METADATA_PREFIX = { "Supports", "Preset" }

----------------------------------------------------------------------
-- 明确不支持（V1）：是真正的 Develop 功能，但本版不处理 → 必须 warning
----------------------------------------------------------------------
XmpMapping.UNSUPPORTED_FIELDS = {
    -- 遮罩与局部调整：SDK 限制严重（见 README）
    MaskGroupBasedCorrections = "遮罩 / 蒙版（Lightroom 会整体替换遮罩数组，V1 不做）",
    Masking = "遮罩 / 蒙版",
    RetouchInfo = "污点修复",
    RedEyeInfo = "红眼修正",
    -- 相机配置文件 / Look
    CameraProfile = "相机配置文件（按名称应用存在安装差异，V1 不做）",
    CameraProfileDigest = "相机配置文件摘要",
    AutoToneDigest = "Auto Tone 摘要",
    AutoToneDigestNoSat = "Auto Tone 摘要（无饱和）",
    Look = "Look 表 / 配置文件参数",
    -- Point Color
    PointColors = "Point Color（单点颜色）",
    -- HDR 编辑模式
    HDREditMode = "HDR 编辑模式",
    -- 裁剪与几何
    CropTop = "裁剪", CropLeft = "裁剪", CropRight = "裁剪", CropBottom = "裁剪",
    CropAngle = "裁剪角度", CropConstrainToWarp = "裁剪", CropConstrainToUnitSquare = "裁剪",
    HasCrop = "裁剪标志", Orientation = "方向",
    PerspectiveVertical = "透视校正", PerspectiveHorizontal = "透视校正",
    PerspectiveRotate = "透视校正", PerspectiveScale = "透视校正",
    PerspectiveAspect = "透视校正", PerspectiveX = "透视校正",
    PerspectiveY = "透视校正", PerspectiveUpright = "透视校正",
    straightenAngle = "拉直角度",
    -- 镜头配置文件具体项（只保留 AutoLateralCA 数值开关）
    LensProfileEnable = "镜头配置文件",
    LensProfileSetup = "镜头配置文件",
    LensProfileName = "镜头配置文件",
    LensProfileFilename = "镜头配置文件",
    LensProfileDigest = "镜头配置文件",
    LensProfileIsEmbedded = "镜头配置文件",
    LensProfileDistortionScale = "镜头配置文件",
    LensProfileVignettingScale = "镜头配置文件",
    LensProfileChromaticAberrationScale = "镜头配置文件",
    LensManualDistortionAmount = "镜头手动畸变",
    -- 旧版反眩光 / 暗角（PV2010 遗留）
    VignetteAmount = "旧版暗角（PV2010）",
    VignetteMidpoint = "旧版暗角（PV2010）",
    -- 灰阶混合（黑白模式下的 HSL）
    GrayMixerRed = "黑白混合", GrayMixerOrange = "黑白混合", GrayMixerYellow = "黑白混合",
    GrayMixerGreen = "黑白混合", GrayMixerAqua = "黑白混合", GrayMixerBlue = "黑白混合",
    GrayMixerPurple = "黑白混合", GrayMixerMagenta = "黑白混合",
    -- 白平衡增量（As Shot 偏移），语义与 Temperature/Tint 不同
    IncrementalTemperature = "白平衡增量（语义不同于 Temperature，V1 不处理）",
    IncrementalTint = "白平衡增量",
    -- Auto 系列（SDK 中无对应写法，需 UI 自动化，明确禁止）
    AutoBrightness = "Auto 设置", AutoContrast = "Auto 设置",
    AutoExposure = "Auto 设置", AutoShadows = "Auto 设置",
    AutoWhiteVersion = "Auto 白平衡版本",
    -- PV2010 遗留基本面板键
    Brightness = "PV2010 遗留键（PV2012+ 无效）",
    HighlightRecovery = "PV2010 遗留键（PV2012+ 无效）",
    FillLight = "PV2010 遗留键（PV2012+ 无效）",
    -- 视频
    TrimStart = "视频剪辑", TrimEnd = "视频剪辑",
}

-- PV2010 遗留键（同样是「不该应用」的，但单独列出便于日志区分）
XmpMapping.LEGACY_PV2010 = {
    Exposure = true, Contrast = true, Shadows = true, Blacks = true,
    Clarity = true, Whites = true, Vibrance = true, Saturation = true,
}
-- 注意：Exposure / Contrast / Saturation / Vibrance 在 PV2010 与 PV2012 里同名，
-- 因此 **不能** 一律判为遗留键。只有无 2012 后缀且不在 FIELDS 中的才视为遗留。

----------------------------------------------------------------------
-- 把「已知的 Lightroom 原生键」补全
--
-- 目的：让日志里的「未知字段」重新成为一个有意义的信号。
--   AI 生成的 XMP 会带一些 Lightroom 原生但我们不处理的键（Defringe、Enable*、
--   PV2010 遗留曲线、Lens Blur、Point Color、局部调整 local_* ...）。
--   如果它们统统落到「未知字段」，日志就会一直喊狼来了，
--   真正需要警惕的新字段反而被淹没。
--
-- 键名来源：LrDevelopController 参数表 / LrPhoto:getDevelopSettings 成员表 /
--           Lightroom External Controller API 的 adjustable parameters 清单。
----------------------------------------------------------------------
do
    local EXTRA_KNOWN_UNSUPPORTED = {
        -- 去边（Defringe）：官方 lensCorrectionsPanel 参数
        DefringePurpleAmount = "去边（Defringe）—— V1 不处理",
        DefringePurpleHueLo  = "去边（Defringe）—— V1 不处理",
        DefringePurpleHueHi  = "去边（Defringe）—— V1 不处理",
        DefringeGreenAmount  = "去边（Defringe）—— V1 不处理",
        DefringeGreenHueLo   = "去边（Defringe）—— V1 不处理",
        DefringeGreenHueHi   = "去边（Defringe）—— V1 不处理",
        Defringe             = "去边（PV2010 遗留键）",
        LensProfileChromaticAberrationScale = "镜头配置文件 —— V1 不处理",
        CorrectionAmount     = "镜头校正量 —— V1 不处理",
        -- PV2010 遗留
        ChromaticAberrationR = "PV2010 遗留键（色差）",
        ChromaticAberrationB = "PV2010 遗留键（色差）",
        AutoWhiteVersion     = "Auto 白平衡版本缓存键，不是可直接写入的参数",
        AutoGrayscaleMix     = "Auto 灰度混合开关",
        -- PV2010 色调曲线
        ToneCurve            = "PV2010 遗留色调曲线（PV2012 请用 ToneCurvePV2012*）",
        ToneCurveRed         = "PV2010 遗留色调曲线",
        ToneCurveGreen       = "PV2010 遗留色调曲线",
        ToneCurveBlue        = "PV2010 遗留色调曲线",
        ToneCurveName        = "PV2010 遗留色调曲线名（PV2012 请用 ToneCurveName2012）",
        -- 面板启用开关（不是可调参数）
        EnableCalibration              = "面板启用开关，不是可调参数",
        EnableColorAdjustments         = "面板启用开关，不是可调参数",
        EnableDetail                   = "面板启用开关，不是可调参数",
        EnableEffects                  = "面板启用开关，不是可调参数",
        EnableGradientBasedCorrections = "面板启用开关，不是可调参数",
        EnableGrayscaleMix             = "面板启用开关，不是可调参数",
        EnableLensCorrections          = "面板启用开关，不是可调参数",
        EnableTransform                = "面板启用开关，不是可调参数",
        EnablePaintBasedCorrections    = "面板启用开关，不是可调参数",
        EnableRedEye                   = "面板启用开关，不是可调参数",
        EnableRetouch                  = "面板启用开关，不是可调参数",
        EnableSplitToning              = "面板启用开关，不是可调参数",
        -- 较新的 Lightroom 功能
        HDREditMode            = "HDR 编辑模式 —— V1 不处理",
        HDRMaxValue            = "HDR 相关 —— V1 不处理",
        HDRBlend               = "HDR 相关 —— V1 不处理",
        PreviewForSDRDisplay   = "SDR 显示参数 —— V1 不处理",
        VisualizeHDRRanges     = "SDR 显示参数 —— V1 不处理",
        SDRBlend               = "SDR 显示参数 —— V1 不处理",
        SDRBrightness          = "SDR 显示参数 —— V1 不处理",
        SDRClarity             = "SDR 显示参数 —— V1 不处理",
        SDRContrast            = "SDR 显示参数 —— V1 不处理",
        SDRHighlights          = "SDR 显示参数 —— V1 不处理",
        SDRShadows             = "SDR 显示参数 —— V1 不处理",
        SDRWhites              = "SDR 显示参数 —— V1 不处理",
        EnhanceDenoise         = "Enhance（AI 去噪 / 增强细节 / 超分辨率）—— V1 不处理",
        EnhanceDenoiseAmount   = "Enhance —— V1 不处理",
        EnhanceRawDetails      = "Enhance —— V1 不处理",
        EnhanceSuperResolution = "Enhance —— V1 不处理",
        DepthSource            = "深度相关校正 —— V1 不处理",
        DepthCorrectionAmount  = "深度相关校正 —— V1 不处理",
        Look                   = "Look 表 / 配置文件参数 —— V1 不处理",
        LookTable              = "Look 表 —— V1 不处理",
        LookAmount             = "Look 强度 —— V1 不处理",
        CurveRefineSaturation  = "曲线微调饱和度 —— V1 不处理",
    }
    for k, v in pairs(EXTRA_KNOWN_UNSUPPORTED) do
        XmpMapping.UNSUPPORTED_FIELDS[k] = v
    end
end

----------------------------------------------------------------------
-- 按前缀识别的「已知 Lightroom 键族」
--   只对不在 FIELDS / UNSUPPORTED_FIELDS 里的键生效（查找顺序在最后），
--   因此不会误伤 AutoLateralCA 这类已支持字段。
----------------------------------------------------------------------
XmpMapping.KNOWN_NATIVE_PREFIXES = {
    { prefix = "local_",     reason = "局部调整（local_*）—— V1 只处理全局参数" },
    { prefix = "PointColor", reason = "Point Color（单点颜色）—— V1 不处理" },
    { prefix = "LensBlur",   reason = "Lens Blur（镜头模糊）—— V1 不处理" },
    { prefix = "Lens",       reason = "镜头相关参数 —— V1 不处理" },
    { prefix = "Defringe",   reason = "去边（Defringe）—— V1 不处理" },
    { prefix = "GrayMixer",  reason = "黑白混合（V1 只支持 ConvertToGrayscale 开关）" },
    { prefix = "Perspective",reason = "透视校正 —— V1 不处理" },
    { prefix = "Crop",       reason = "裁剪 —— V1 不处理" },
    { prefix = "Enable",     reason = "面板启用开关，不是可调参数" },
    { prefix = "Auto",       reason = "Auto 系列 / 自动设置缓存键，不是可直接写入的参数" },
    { prefix = "ToneCurve",  reason = "色调曲线相关（PV2010 键或未识别写法）" },
    { prefix = "Mask",       reason = "遮罩 / 蒙版 —— V1 不处理" },
}

--- 该字段是否是「已知的 Lightroom 原生键但我们不处理」
-- @return reason string|nil
function XmpMapping.matchKnownNative(localName)
    if type(localName) ~= "string" then
        return nil
    end
    for _, rule in ipairs(XmpMapping.KNOWN_NATIVE_PREFIXES) do
        if localName:sub(1, #rule.prefix) == rule.prefix then
            return rule.reason
        end
    end
    return nil
end

----------------------------------------------------------------------
-- 白平衡（独立转换函数）
----------------------------------------------------------------------
XmpMapping.WB_PRESETS = {
    ["As Shot"]     = "As Shot",
    ["Auto"]        = "Auto",
    ["Daylight"]    = "Daylight",
    ["Cloudy"]      = "Cloudy",
    ["Shade"]       = "Shade",
    ["Tungsten"]    = "Tungsten",
    ["Fluorescent"] = "Fluorescent",
    ["Flash"]       = "Flash",
    ["Custom"]      = "Custom",
}

----------------------------------------------------------------------
-- 类型转换
----------------------------------------------------------------------

--- 统一值转换
-- @param def table  FIELDS 中的字段定义
-- @param raw any    来自 XMP 的原始值（通常是字符串）
-- @return value | nil, errString
function XmpMapping.convertValue(def, raw)
    if def == nil then
        return nil, "字段定义缺失"
    end
    if raw == nil then
        return nil, "字段缺失"
    end

    local t = def.type

    if t == "boolean" then
        return Utils.parseBoolean(raw)

    elseif t == "string" then
        if type(raw) ~= "string" then
            return nil, "期望字符串，实际为 " .. type(raw)
        end
        return raw

    elseif t == "enum" then
        local key = Utils.trim(tostring(raw))
        if key == "" then
            return nil, "空字符串不是合法枚举值"
        end
        local values = def.values or {}
        local v = values[key]
        if v == nil then
            -- 大小写不敏感的二次尝试
            for k, vv in pairs(values) do
                if type(k) == "string" and k:lower() == key:lower() then
                    return vv
                end
            end
            return nil, string.format("非法枚举值 \"%s\"", key)
        end
        return v

    elseif t == "number" then
        if Utils.isBlank(raw) then
            return nil, "空字符串不是合法数值"
        end
        if type(raw) == "table" then
            return nil, "期望单个数值，实际收到容器（rdf:Seq/Bag/Alt）"
        end
        local n, err = Utils.parseNumber(raw)
        if n == nil then
            return nil, err
        end
        if def.integer or def.range == nil then
            -- 不强制取整，但去掉浮点噪声
            return n
        end
        return n

    elseif t == "toneCurve" then
        return nil, "色调曲线请使用 XmpMapping.mapToneCurve()"

    else
        return nil, "未知字段类型: " .. tostring(t)
    end
end

----------------------------------------------------------------------
-- 色调曲线
----------------------------------------------------------------------

--- 解析 XMP 里的曲线容器。XMP 写成 rdf:Seq，元素形如 "0, 0" / "92, 106"；
--  SDK 要求扁平数字数组 { 0, 0, 92, 106, 255, 255 }。
-- @param items table|string 容器内容
-- @return flatNumbers | nil, err
function XmpMapping.mapToneCurvePoints(items)
    if type(items) == "string" then
        items = { items }
    end
    if type(items) ~= "table" then
        return nil, "色调曲线不是序列（rdf:Seq）"
    end
    if #items == 0 then
        return nil, "色调曲线为空序列"
    end

    local flat = {}
    for idx, item in ipairs(items) do
        if type(item) ~= "string" then
            return nil, string.format("第 %d 个曲线点不是字符串", idx)
        end
        local xStr, yStr = item:match("^%s*([^,]+),%s*([^,]+)%s*$")
        if not xStr then
            return nil, string.format("第 %d 个曲线点格式非法（应为 \"x, y\"）: \"%s\"", idx, item)
        end
        local x, ex = Utils.parseNumber(xStr)
        local y, ey = Utils.parseNumber(yStr)
        if not x then return nil, string.format("第 %d 个曲线点 X 非法: %s", idx, tostring(ex)) end
        if not y then return nil, string.format("第 %d 个曲线点 Y 非法: %s", idx, tostring(ey)) end
        if x < 0 or x > 255 or y < 0 or y > 255 then
            return nil, string.format("第 %d 个曲线点超出 0..255: (%s, %s)", idx, tostring(x), tostring(y))
        end
        -- 曲线要求 X 单调不减
        local prevX = flat[#flat - 1]
        if prevX and x < prevX then
            return nil, string.format("第 %d 个曲线点的 X (%s) 小于前一个点 (%s)，曲线必须单调不减", idx, tostring(x), tostring(prevX))
        end
        flat[#flat + 1] = x
        flat[#flat + 1] = y
    end

    if #flat < 4 then
        return nil, "色调曲线至少需要 2 个点"
    end
    return flat
end

--- 判断扁平曲线是否等价于恒等（线性）
function XmpMapping.isIdentityCurve(flat)
    return #flat == 4 and flat[1] == 0 and flat[2] == 0 and flat[3] == 255 and flat[4] == 255
end

----------------------------------------------------------------------
-- 主映射入口
----------------------------------------------------------------------

local function classifyUnknown(localName)
    for _, p in ipairs(XmpMapping.IGNORED_METADATA_PREFIX) do
        if localName:sub(1, #p) == p then
            return "ignored", "预设元数据（前缀 " .. p .. "*）"
        end
    end
    return nil
end

-- 只做类型转换与分类；范围校验交给 Validation
--- @param parsed table XmpParser 的输出
--- @param opts table|nil { applyExtendedFields = boolean, onLog = function(level,msg,ctx) }
-- @return bundle table
function XmpMapping.toDevelopSettings(parsed, opts)
    opts = opts or {}
    local applyExt = opts.applyExtendedFields and true or false

    -- 允许调用方（测试 / UI）注入日志器；默认使用本插件的 Logger
    local log = opts.logger or Logger

    local bundle = {
        settings    = {},   -- SDK 键 -> 已转换的值
        applied     = {},   -- { field, sdkField, rawValue, value, group, display, aliasedFrom }
        clamped     = {},
        ignored     = {},
        unsupported = {},
        knownNative = {},   -- 已知的 LR 原生键但 V1 不处理
        unknown     = {},   -- 真正不认识的键
        errors      = {},
        warnings    = {},
        skipped     = {},   -- tier 被跳过的扩展字段
        schema      = nil,
        meta        = {},
    }

    if type(parsed) ~= "table" or type(parsed.fields) ~= "table" then
        bundle.errors[#bundle.errors + 1] = { field = "-", message = "解析结果为空或结构非法" }
        return bundle
    end

    local fields = parsed.fields
    local meta = parsed.metadata or {}
    bundle.meta = meta

    -- 解析器自身的告警透传
    for _, w in ipairs(parsed.warnings or {}) do
        bundle.warnings[#bundle.warnings + 1] = w
    end

    ----------------------------------------------------------------
    -- AI Color Schema 版本策略
    ----------------------------------------------------------------
    local schemaVersion = meta.schemaVersion
    local policy = {
        supported   = Manifest.schemaPolicy.supported,
        compatible  = Manifest.schemaPolicy.compatible,
        unsupported = Manifest.schemaPolicy.unsupported,
    }
    bundle.schema = { version = schemaVersion }
    if schemaVersion == nil then
        bundle.schema.status = "assumed"
        bundle.warnings[#bundle.warnings + 1] =
            "XMP 未声明 AIColorSchema，按 " .. Manifest.schemaVersion .. " 处理"
    elseif schemaVersion:sub(1, #policy.supported) == policy.supported then
        bundle.schema.status = "supported"
    elseif schemaVersion:sub(1, #policy.compatible) == policy.compatible then
        bundle.schema.status = "compatible"
        bundle.warnings[#bundle.warnings + 1] =
            "AIColorSchema=" .. schemaVersion .. " 属于兼容范围（0.x），字段含义可能与当前版本有差异"
    elseif schemaVersion:sub(1, #policy.unsupported) == policy.unsupported then
        bundle.schema.status = "unsupported"
        bundle.errors[#bundle.errors + 1] = {
            field = "AIColorSchema",
            message = "AIColorSchema=" .. schemaVersion .. " 不受本插件版本支持，已拒绝应用",
        }
        return bundle
    else
        bundle.schema.status = "unknown"
        bundle.warnings[#bundle.warnings + 1] =
            "无法识别的 AIColorSchema=" .. tostring(schemaVersion) .. "，按兼容模式继续"
    end

    ----------------------------------------------------------------
    -- 由「专用转换函数」处理的字段
    --   这些字段绝不能走下面的通用转换路径，否则会被处理两遍：
    --     WhiteBalance       -> mapWhiteBalance（必须与 Temperature/Tint 联合决策）
    --     ToneCurvePV2012*   -> mapToneCurve（XMP 是 "x, y" 字符串序列，
    --                                        SDK 要的是扁平数字数组）
    --     ToneCurveName2012  -> mapToneCurve（要与点曲线保持一致的 Custom 语义）
    --   （曾经踩过：曲线字段走了通用路径，撞上 type == "toneCurve" 就报
    --     「色调曲线请使用 XmpMapping.mapToneCurve()」，凭空多出 4 条假错误。）
    ----------------------------------------------------------------
    local HANDLED_BY_DEDICATED_MAPPER = {
        WhiteBalance         = true,
        ToneCurvePV2012      = true,
        ToneCurvePV2012Red   = true,
        ToneCurvePV2012Green = true,
        ToneCurvePV2012Blue  = true,
        ToneCurveName2012    = true,
    }

    ----------------------------------------------------------------
    -- 按字段处理
    ----------------------------------------------------------------
    for _, rawName in ipairs(Utils.sortedKeys(fields)) do
        local localName = rawName
        local rawValue = fields[localName]

        local def = FIELDS[localName]
        local aliasedFrom = nil
        if def == nil and XmpMapping.ALIASES[localName] then
            local canonical = XmpMapping.ALIASES[localName]
            def = FIELDS[canonical]
            aliasedFrom = localName
        end

        if def then
            -- 层级过滤
            if def.tier == "ext" and not applyExt then
                bundle.skipped[#bundle.skipped + 1] = {
                    field = localName,
                    reason = "扩展字段，当前未启用（applyExtendedFields = false）",
                }
            else
                -- 白平衡与色调曲线交给各自的专用转换函数处理，这里跳过
                if HANDLED_BY_DEDICATED_MAPPER[localName] then
                    -- 由 mapWhiteBalance / mapToneCurve 统一处理，避免重复与误报
                else
                    local converted, err = XmpMapping.convertValue(def, rawValue)
                    if converted == nil then
                        bundle.errors[#bundle.errors + 1] = {
                            field = localName,
                            sdkField = def.sdk,
                            rawValue = rawValue,
                            message = tostring(err),
                        }
                    else
                        local sdkKey = def.sdk
                        if bundle.settings[sdkKey] ~= nil then
                            bundle.warnings[#bundle.warnings + 1] = string.format(
                                "SDK 键 %s 被多个 XMP 字段写入（当前 %s），后写入者被忽略",
                                sdkKey, localName)
                        else
                            if def.type == "number" and def.integer then
                                converted = math.floor(converted + 0.5)
                            end
                            -- 数值型做一次「整数化」以减少浮点噪声（0.35000000000000003）
                            if def.type == "number" and not def.keepFloat then
                                converted = tonumber(string.format("%.6f", converted))
                            end
                            bundle.settings[sdkKey] = converted
                            bundle.applied[#bundle.applied + 1] = {
                                field    = localName,
                                sdkField = sdkKey,
                                rawValue = rawValue,
                                value    = converted,
                                group    = def.group,
                                display  = def.display or localName,
                                aliasedFrom = aliasedFrom,
                                tier     = def.tier,
                            }
                            -- 字段级日志：记录
                            -- field / rawValue / convertedValue / result
                            -- （默认日志级别为 info，这些 debug 行只在排错时打开）
                            if log and type(log.debug) == "function" then
                                log.debug(string.format("字段映射 %s -> %s", localName, sdkKey), {
                                    operation      = "MAP",
                                    field          = localName,
                                    sdkField       = sdkKey,
                                    rawValue       = rawValue,
                                    convertedValue = converted,
                                    result         = "OK",
                                })
                            end
                            if aliasedFrom then
                                bundle.warnings[#bundle.warnings + 1] = string.format(
                                    "字段 %s 不是 SDK 键名，已按别名规则写入 %s",
                                    aliasedFrom, sdkKey)
                            end
                        end
                    end
                end
            end

        elseif XmpMapping.UNSUPPORTED_FIELDS[localName] then
            -- 显式登记的「已知 Lightroom 键但 V1 不处理」
            local reason = XmpMapping.UNSUPPORTED_FIELDS[localName]
            bundle.knownNative[#bundle.knownNative + 1] = {
                field = localName, reason = reason,
            }
            bundle.unsupported[#bundle.unsupported + 1] = {
                field = localName, reason = reason, kind = "knownNative",
            }

        elseif XmpMapping.IGNORED_METADATA[localName] then
            bundle.ignored[#bundle.ignored + 1] = {
                field = localName,
                reason = "预设元数据，不参与 Develop",
            }

        else
            local kind, reason = classifyUnknown(localName)
            local nativeReason = XmpMapping.matchKnownNative(localName)

            if kind == "ignored" then
                bundle.ignored[#bundle.ignored + 1] = { field = localName, reason = reason }

            elseif nativeReason then
                -- 已知的 Lightroom 原生键，但 V1 不处理（附明确原因）
                bundle.knownNative[#bundle.knownNative + 1] = {
                    field = localName, reason = nativeReason,
                }
                bundle.unsupported[#bundle.unsupported + 1] = {
                    field = localName, reason = nativeReason, kind = "knownNative",
                }

            else
                -- 真正不认识的字段：warning，绝不崩溃
                bundle.unknown[#bundle.unknown + 1] = { field = localName, value = rawValue }
                bundle.unsupported[#bundle.unsupported + 1] = {
                    field = localName,
                    reason = "未知字段（不是已知的 Lightroom Develop 键），已忽略",
                    kind = "unknown",
                }
            end
        end
    end

    ----------------------------------------------------------------
    -- 白平衡（独立转换）
    ----------------------------------------------------------------
    local wbFragment, wbNotes = XmpMapping.mapWhiteBalance(fields)
    for sdkKey, value in pairs(wbFragment) do
        if bundle.settings[sdkKey] ~= nil then
            -- 常规字段循环里已写过（例如 WhiteBalance 直通路径），保持首次
        else
            bundle.settings[sdkKey] = value
            local def = FIELDS[sdkKey]
            bundle.applied[#bundle.applied + 1] = {
                field    = sdkKey,
                sdkField = sdkKey,
                rawValue = wbNotes.raw and wbNotes.raw[sdkKey] or value,
                value    = value,
                group    = def and def.group or "whitebalance",
                display  = def and def.display or sdkKey,
                tier     = def and def.tier or "v1",
            }
        end
    end
    for _, n in ipairs(wbNotes.messages or {}) do
        bundle.warnings[#bundle.warnings + 1] = n
    end
    for _, e in ipairs(wbNotes.errors or {}) do
        bundle.errors[#bundle.errors + 1] = e
    end

    ----------------------------------------------------------------
    -- 色调曲线（独立转换）
    ----------------------------------------------------------------
    local curveFragment, curveNotes = XmpMapping.mapToneCurve(fields)
    -- 用 sortedKeys 保证顺序确定（便于测试与日志对比）
    for _, sdkKey in ipairs(Utils.sortedKeys(curveFragment)) do
        local value = curveFragment[sdkKey]
        if bundle.settings[sdkKey] ~= nil then
            -- 防御：同一 SDK 键只允许写入一次，避免 applied 里出现重复条目
            bundle.warnings[#bundle.warnings + 1] = string.format(
                "SDK 键 %s 被重复写入，已保留先写入的值", sdkKey)
        else
            bundle.settings[sdkKey] = value
            local def = FIELDS[sdkKey]
            bundle.applied[#bundle.applied + 1] = {
                field    = sdkKey,
                sdkField = sdkKey,
                rawValue = curveNotes.raw and curveNotes.raw[sdkKey] or value,
                value    = value,
                group    = def and def.group or "tonecurve",
                display  = def and def.display or sdkKey,
                tier     = "v1",
            }
        end
    end
    for _, n in ipairs(curveNotes.messages or {}) do
        bundle.warnings[#bundle.warnings + 1] = n
    end
    for _, e in ipairs(curveNotes.errors or {}) do
        bundle.errors[#bundle.errors + 1] = e
    end

    ----------------------------------------------------------------
    -- 统计
    ----------------------------------------------------------------
    bundle.counts = {
        applied     = #bundle.applied,
        clamped     = #bundle.clamped,
        ignored     = #bundle.ignored + #bundle.skipped,
        unsupported = #bundle.unsupported,
        knownNative = #bundle.knownNative,
        unknown     = #bundle.unknown,
        errors      = #bundle.errors,
        warnings    = #bundle.warnings,
        settings    = Utils.tcount(bundle.settings),
    }

    return bundle
end

----------------------------------------------------------------------
-- mapWhiteBalance
----------------------------------------------------------------------

--- XMP 白平衡 -> SDK 白平衡片段
-- @param fields table
-- @return fragment table, notes table
function XmpMapping.mapWhiteBalance(fields)
    local fragment = {}
    local raw = {}
    local notes = { messages = {}, errors = {} }

    local wbRaw  = fields.WhiteBalance
    local temp   = fields.Temperature
    local tint   = fields.Tint

    local hasTemp = (temp ~= nil and not Utils.isBlank(temp))
    local hasTint = (tint ~= nil and not Utils.isBlank(tint))

    if hasTemp or hasTint then
        -- 有明确的 Kelvin / Tint 值 => 必须是 Custom，否则 Lightroom 会忽略这两个值
        fragment.WhiteBalance = "Custom"
        raw.WhiteBalance = wbRaw or "(未声明，按 Custom 处理)"

        if hasTemp then
            local n, err = Utils.parseNumber(temp)
            if n == nil then
                notes.errors[#notes.errors + 1] = {
                    field = "Temperature", rawValue = temp,
                    message = "白平衡色温非法：" .. tostring(err),
                }
            else
                fragment.Temperature = tonumber(string.format("%.6f", n))
                raw.Temperature = temp
            end
        end

        if hasTint then
            local n, err = Utils.parseNumber(tint)
            if n == nil then
                notes.errors[#notes.errors + 1] = {
                    field = "Tint", rawValue = tint,
                    message = "白平衡色调非法：" .. tostring(err),
                }
            else
                fragment.Tint = tonumber(string.format("%.6f", n))
                raw.Tint = tint
            end
        end

        if wbRaw ~= nil and not Utils.isBlank(wbRaw) then
            local wbTrim = Utils.trim(tostring(wbRaw))
            if wbTrim ~= "Custom" then
                notes.messages[#notes.messages + 1] = string.format(
                    "XMP 声明 WhiteBalance=\"%s\"，但同时提供了 Temperature/Tint；" ..
                    "已按 Custom 处理（否则 Lightroom 会丢弃显式色温值）", wbTrim)
            end
        end

    elseif wbRaw ~= nil and not Utils.isBlank(wbRaw) then
        local key = Utils.trim(tostring(wbRaw))
        local mapped = XmpMapping.WB_PRESETS[key]
        if mapped then
            fragment.WhiteBalance = mapped
            raw.WhiteBalance = wbRaw
        else
            notes.errors[#notes.errors + 1] = {
                field = "WhiteBalance", rawValue = wbRaw,
                message = string.format(
                    "未知白平衡模式 \"%s\"（已知：As Shot / Auto / Daylight / Cloudy / Shade / Tungsten / Fluorescent / Flash / Custom）",
                    key),
            }
        end
    end

    return fragment, notes
end

----------------------------------------------------------------------
-- mapToneCurve
----------------------------------------------------------------------

--- XMP 色调曲线 -> SDK 片段
-- @param fields table
-- @return fragment table, notes table
function XmpMapping.mapToneCurve(fields)
    local fragment = {}
    local raw = {}
    local notes = { messages = {}, errors = {} }

    local CURVES = {
        { xmp = "ToneCurvePV2012",      sdk = "ToneCurvePV2012"      },
        { xmp = "ToneCurvePV2012Red",   sdk = "ToneCurvePV2012Red"   },
        { xmp = "ToneCurvePV2012Green", sdk = "ToneCurvePV2012Green" },
        { xmp = "ToneCurvePV2012Blue",  sdk = "ToneCurvePV2012Blue"  },
    }

    local anyCurveEmitted = false

    for _, c in ipairs(CURVES) do
        local v = fields[c.xmp]
        if v ~= nil then
            local flat, err = XmpMapping.mapToneCurvePoints(v)
            if flat == nil then
                notes.errors[#notes.errors + 1] = {
                    field = c.xmp, rawValue = v,
                    message = "色调曲线转换失败：" .. tostring(err) .. "（该曲线已跳过）",
                }
            elseif XmpMapping.isIdentityCurve(flat) then
                -- 恒等曲线不需要写（写进去反而会强制 ToneCurveName2012 = Custom）
                notes.messages[#notes.messages + 1] =
                    c.xmp .. " 为恒等（线性）曲线，已跳过，不写入"
            else
                fragment[c.sdk] = flat
                raw[c.sdk] = table.concat(flat, ", ")
                anyCurveEmitted = true
            end
        end
    end

    ----------------------------------------------------------------
    -- ToneCurveName2012
    ----------------------------------------------------------------
    local nameRaw = fields.ToneCurveName2012
    local nameTrim = (nameRaw ~= nil and not Utils.isBlank(nameRaw))
        and Utils.trim(tostring(nameRaw)) or nil

    if anyCurveEmitted then
        -- 一旦写入自定义点，名字必须是 Custom，否则 Lightroom 会用预设曲线覆盖
        fragment.ToneCurveName2012 = "Custom"
        raw.ToneCurveName2012 = nameTrim or "(未声明)"
        if nameTrim and nameTrim ~= "" and nameTrim ~= "Custom" then
            notes.messages[#notes.messages + 1] = string.format(
                "已写入自定义点曲线，ToneCurveName2012 由 \"%s\" 强制改为 \"Custom\"", nameTrim)
        end
    elseif nameTrim and nameTrim ~= "" then
        local known = { ["Linear"] = true, ["Medium Contrast"] = true, ["Strong Contrast"] = true, ["Custom"] = true }
        if known[nameTrim] then
            fragment.ToneCurveName2012 = nameTrim
            raw.ToneCurveName2012 = nameRaw
        else
            notes.messages[#notes.messages + 1] = string.format(
                "未知的 ToneCurveName2012=\"%s\"，已忽略", nameTrim)
        end
    end

    return fragment, notes
end

----------------------------------------------------------------------
-- 运行期范围覆盖（可选）
----------------------------------------------------------------------

--- 用 LrDevelopController.getRange(param) 的真实范围覆盖静态建议区间。
-- 必须在 Develop 模块激活且处于 LrTasks 任务中调用；失败则保持静态值。
-- @param getRangeFn function(param) -> min, max
-- @return table 实际生效的范围表 { [sdkKey] = {min,max} }
function XmpMapping.applyRuntimeRanges(getRangeFn)
    local ranges = {}
    if type(getRangeFn) ~= "function" then
        return ranges
    end
    for _, def in pairs(FIELDS) do
        if def.type == "number" then
            local ok, mn, mx = pcall(getRangeFn, def.sdk)
            if ok and type(mn) == "number" and type(mx) == "number" and mx > mn then
                ranges[def.sdk] = { mn, mx, fromRuntime = true }
            end
        end
    end
    return ranges
end

return XmpMapping
