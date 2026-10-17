--[[
    Main.lua  —  主界面入口（由 Info.lua 的菜单项 file = "Main.lua" 触发）

    只做三件事：
      1. 引导运行时（src/Boot.lua：模块加载器 + 平台注入 + 日志）
      2. 记一条启动日志
      3. 在异步任务里打开主界面

    真正的流程都在 src/ 里：ApplyEngine（判定与写入）、ImportDialog（界面）。

    Lua 5.1 兼容。全程不使用 package / module / getfenv / setfenv。
--]]

----------------------------------------------------------------------
-- 引导：读取并执行 src/Boot.lua
--   Lightroom 没有 package / package.path，所以连「加载引导本身」都得手工来。
--   用 LrFileUtils.readFile 而不是 io —— 前者不受系统 ANSI 代码页限制。
----------------------------------------------------------------------
local LrPathUtils, LrFileUtils = import "LrPathUtils", import "LrFileUtils"

local bootPath   = LrPathUtils.child(_PLUGIN.path, "src/Boot.lua")
local bootSource = LrFileUtils.readFile(bootPath)
if bootSource == nil then
    error("无法读取 src/Boot.lua —— 插件文件不完整？", 0)
end

local Boot = loadstring(bootSource, "@src/Boot.lua")()
local ctx  = Boot.prepare()

local LrFunctionContext = import "LrFunctionContext"
local LrDialogs         = import "LrDialogs"

local Logger   = ctx.logger
local Manifest = ctx.manifest

----------------------------------------------------------------------
-- 启动
----------------------------------------------------------------------
Logger.info(string.format(
    "AI XMP Color Importer v%s 启动（目标环境 %s，LrSdkVersion=%s）",
    Manifest.pluginVersionText, Manifest.verifiedOn, tostring(Manifest.lrSdkVersion)),
    { operation = "STARTUP" })

Logger.debug("已加载模块：" .. table.concat(ctx.loader.loadedPaths(), ", "),
    { operation = "STARTUP" })

--[[
    ★ 顶层绝对不能用原生 pcall 包住整个流程 ★
    Lightroom 的很多 SDK 调用会 yield（读元数据 / 写目录 / sleep），
    Lua 5.1 的 pcall 是 C 函数、跨 C 边界不允许 yield，
    包住它们会全部失败并报 "Yielding is not allowed within a C or metamethod call"，
    而且错误会被 pcall 吞掉。所以这里用官方的函数上下文做错误处理。
]]
LrFunctionContext.postAsyncTaskWithContext("AI Color Importer", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)

    context:addFailureHandler(function(okFlag, errMsg)
        Logger.error("AI Color Importer 出错：" .. tostring(errMsg), {
            operation = "FATAL",
            result    = "FAILED",
        })
    end)

    local ImportDialog = ctx.load("ui/ImportDialog.lua")
    ImportDialog.run()
end)
