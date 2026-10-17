--[[
    manifest.lua  —  插件运行时清单与常量（单一事实来源）

    说明（重要，避免误解）：
      * 本文件 **不是** Lightroom SDK 要求的文件。SDK 只要求插件根目录下的 Info.lua。
      * 本项目保留 manifest.lua 作为「运行时清单」，为插件身份、版本号、SDK 版本要求、
        默认配置项提供唯一来源，避免同一个版本号散落在 Info.lua / Logger / UI 多处。
      * Info.lua 是真正的 SDK 清单，它按 SDK 要求内联了同样的字面量；
        tests/test_XmpParser.lua 中有一致性断言，会比对两份版本号，防止漂移。
      * 本文件只返回纯数据表，不 import 任何 Lr* 模块，因此可在普通 Lua 环境中被测试。

    Lua 5.1 兼容。
--]]

local Manifest = {}

----------------------------------------------------------------------
-- 插件身份
----------------------------------------------------------------------
Manifest.pluginName        = "AI XMP Color Importer"
Manifest.pluginId          = "com.aicolor.xmp-importer"
Manifest.pluginVersion     = { major = 1, minor = 0, revision = 0, build = 16 }
Manifest.pluginVersionText = "1.0.0"

----------------------------------------------------------------------
-- 运行环境要求
--   LrSdkVersion        : 编译/构建所依据的 SDK 版本
--   LrSdkMinimumVersion : 允许运行的最低 SDK 版本
--   依据：photo:applyDevelopSettings 的 optHistoryName 参数在 SDK 11.2 才被写入文档，
--         故取 11.4 作为安全下限。开发机验证环境为 Lightroom Classic 14.5.1。
----------------------------------------------------------------------
Manifest.lrSdkVersion        = 11.4
Manifest.lrSdkMinimumVersion = 11.4
Manifest.verifiedOn          = "Lightroom Classic 14.5.1"

----------------------------------------------------------------------
-- AI Color Schema 版本
--   插件读取 XMP 中的 AIColorSchema 字段：
--     "1.0"  -> supported
--     "0.x"  -> 兼容性 warning
--     "2.x"  -> unsupported（拒绝应用）
--     缺失   -> supported（按 1.0 处理，并记录 info）
----------------------------------------------------------------------
Manifest.schemaVersion = "1.0"
Manifest.schemaPolicy = {
    supported   = "1.",
    compatible  = "0.",
    unsupported = "2.",
}

----------------------------------------------------------------------
-- 日志
----------------------------------------------------------------------
Manifest.loggerName        = "AI-XMP-Color-Importer"
Manifest.historyStepPrefix = "AI Color"

----------------------------------------------------------------------
-- 默认配置（可被 UI 覆盖；UI 的持久化实现见 ui/ImportDialog.lua）
----------------------------------------------------------------------
Manifest.defaults = {
    -- 是否应用「扩展字段」（detail / effects / lens / calibrate 等已核实键名、
    -- 但不在 V1 范围内的字段）。V1 默认关闭。
    applyExtendedFields = false,

    -- 应用后是否读回校验。注意：Lightroom 的 getDevelopSettings 存在已知的
    -- 读回滞后现象（见 README「已知限制」），因此读回不一致只记 warning，不判失败。
    verifyAfterApply = true,

    -- 应用后是否切换到 Develop 模块方便用户确认
    switchToDevelopAfterApply = true,

    -- 源文件名不匹配时是否默认拒绝
    rejectOnFilenameMismatch = true,

    -- 日志内存缓冲条数上限
    maxLogEntries = 500,
}

return Manifest
