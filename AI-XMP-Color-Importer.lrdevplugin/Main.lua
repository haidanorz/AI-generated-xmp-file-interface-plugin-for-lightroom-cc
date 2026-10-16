--[[
    Main.lua  —  插件入口（由 Info.lua 的菜单项 file = "Main.lua" 触发）

    职责：
      1. 用官方文档列明「可用」的 loadstring() + LrFileUtils.readFile() 引导加载 src/Loader.lua
         （Lightroom **没有** package / package.path，不能用常规的 package.path 方案；
           详见 src/Loader.lua 顶部的官方原文引用）
      2. 把加载器挂到插件专属全局 AI_COLOR_IMPORTER 上，供各模块统一取依赖
      3. 把 Lightroom 的沙箱能力注入 Utils.platform
      4. 配置 Logger（挂接 LrLogger 落盘）
      5. 在 LrTasks 异步任务里启动主界面
         （SDK 要求 getDevelopSettings / applyDevelopSettings / 目录访问
           必须在 LrTasks 启动的任务中调用）

    Lua 5.1 兼容。全程不使用 package / module / getfenv / setfenv —— 这些在
    Lightroom 中不可用（官方指南 p.19-20）。
--]]

local LrDialogs   = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

----------------------------------------------------------------------
-- 插件根目录（_PLUGIN.path 是官方文档化的只读属性：
--   "Retrieves the absolute path of the plug-in folder or package."）
----------------------------------------------------------------------
local PLUGIN_ROOT = "."
do
    local ok, path = pcall(function() return _PLUGIN.path end)
    if ok and type(path) == "string" and path ~= "" then
        PLUGIN_ROOT = path
    end
end

----------------------------------------------------------------------
-- 1) 引导：读取 + 编译一个模块源码
--    Lightroom 没有 package，所以连「加载 Loader 本身」都得用最原始的方式。
--    这里只需要这两件事，其余逻辑（缓存、错误信息、BOM）都在 Loader.lua 里。
----------------------------------------------------------------------

--- 按插件内相对路径读源码
-- 用 LrFileUtils.readFile 而不是 io.open —— 官方明确建议：
-- 「如果读取的路径可能包含非 ASCII 字符，请优先使用此函数而非内置的 Lua io 命名空间。」
local function readPluginSource(relativePath)
    local full = LrPathUtils.child(PLUGIN_ROOT, relativePath)

    -- LrFileUtils 的调用验证过不会 yield，这里用不带闭包的原生 pcall 是安全的
    local okExists, kind = pcall(LrFileUtils.exists, full)
    if not okExists then
        return nil, "无法检查文件是否存在：" .. tostring(kind)
    end
    if kind == false or kind == nil then
        return nil, "文件不存在：" .. full
    end
    if kind == "directory" then
        return nil, "这是一个目录而不是文件：" .. full
    end

    local okRead, content = pcall(LrFileUtils.readFile, full)
    if not okRead then
        return nil, "读取失败：" .. tostring(content) .. "  (" .. full .. ")"
    end
    if content == nil then
        return nil, "读取返回空内容：" .. full
    end
    return content
end

--- 编译一段 Lua 源码
-- （Lua 5.1 用 loadstring；Lightroom 内嵌的正是 5.1。兼容 5.2+ 的 load 写法。）
local compileString = loadstring or load

local function compileSource(source, chunkName)
    local body = source
    if body:sub(1, 3) == "\239\187\191" then -- UTF-8 BOM
        body = body:sub(4)
    end
    local chunk, err = compileString(body, "@" .. chunkName)
    if not chunk then
        return nil, err
    end
    return chunk
end

----------------------------------------------------------------------
-- 2) 加载 Loader 自身，然后把它挂到插件专属全局
----------------------------------------------------------------------
local Loader
do
    local source, rerr = readPluginSource("src/Loader.lua")
    if not source then
        error("无法加载 src/Loader.lua —— 插件文件不完整？\n      " .. tostring(rerr), 0)
    end
    local chunk, cerr = compileSource(source, "src/Loader.lua")
    if not chunk then
        error("src/Loader.lua 编译失败：\n      " .. tostring(cerr), 0)
    end
    Loader = chunk()
    if type(Loader) ~= "table" then
        error("src/Loader.lua 没有返回模块表", 0)
    end
end

Loader.configure {
    root       = PLUGIN_ROOT,
    readSource = readPluginSource,
}

-- 官方文档：插件里定义的全局位于「本插件专属的函数环境」中，不影响 Lightroom 整体，
-- 且插件重新加载时会得到全新环境。因此这里挂全局是安全且符合惯例的。
AI_COLOR_IMPORTER        = AI_COLOR_IMPORTER or {}
AI_COLOR_IMPORTER.root   = PLUGIN_ROOT
AI_COLOR_IMPORTER.load   = Loader.load
AI_COLOR_IMPORTER.Loader = Loader

----------------------------------------------------------------------
-- 3) 加载业务模块
----------------------------------------------------------------------
local Utils    = Loader.load("src/Utils.lua")
local Logger   = Loader.load("src/Logger.lua")
local Manifest = Loader.load("manifest.lua")

----------------------------------------------------------------------
-- 4) 平台注入（Lightroom 沙箱没有可用的 io / os.getenv）
----------------------------------------------------------------------
local function lrFileExists(path)
    -- LrFileUtils 不会 yield，原生 pcall 安全
    local ok, kind = pcall(LrFileUtils.exists, path)
    return ok and kind ~= false and kind ~= nil
end

local function lrJoinPath(...)
    local parts, n = { ... }, select("#", ...)
    if n == 0 then return "" end
    local out = parts[1]
    for i = 2, n do
        out = LrPathUtils.child(out, parts[i])
    end
    return out
end

-- os 在 Lightroom 中只剩 clock / date / time / tmpname（官方 p.20），够用；
-- 万一不可用则退回 LrDate。
local function lrNow()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then
        return t
    end
    -- LrDate 是兜底路径，用 yield-safe 的安全调用
    local ok2, t2 = Utils.safeCall("ai-color-now", function()
        local LrDate = Utils.lrImport("LrDate")
        return LrDate and LrDate.currentTime() or nil
    end)
    if ok2 and type(t2) == "number" then
        return t2
    end
    return 0
end

local function lrDate(fmt, t)
    local ok, s = pcall(os.date, fmt, t)
    if ok and type(s) == "string" then
        return s
    end
    local ok2, s2 = Utils.safeCall("ai-color-date", function()
        local LrDate = Utils.lrImport("LrDate")
        return LrDate and LrDate.timeToW3CDate(t) or nil -- 形如 2026-10-16T19:30:12
    end)
    if ok2 and type(s2) == "string" then
        local d, tm = s2:match("^(%d%d%d%d%-%d%d%-%d%d)T([%d:]+)")
        if d and tm then
            if fmt:find("Ymd", 1, true) then
                return (d:gsub("%-", "")) .. "-" .. (tm:gsub(":", ""))
            end
            return d .. " " .. tm
        end
        return s2
    end
    return "unknown"
end

Utils.configurePlatform {
    readFile   = function(path)
        if type(path) ~= "string" or path == "" then
            return nil, "路径为空"
        end
        if not lrFileExists(path) then
            return nil, "文件不存在：" .. tostring(path)
        end
        local ok, content = pcall(LrFileUtils.readFile, path)
        if not ok then
            return nil, "读取失败：" .. tostring(content)
        end
        return content
    end,
    fileExists = lrFileExists,
    joinPath   = lrJoinPath,
    now        = lrNow,
    date       = lrDate,
}

----------------------------------------------------------------------
-- 5) 日志
----------------------------------------------------------------------
local attachedToFile = Logger.attachLightroom(Manifest.loggerName)
Logger.configure {
    level      = "info",
    maxEntries = Manifest.defaults.maxLogEntries,
    echo       = not attachedToFile,
}

----------------------------------------------------------------------
-- 6) 启动
----------------------------------------------------------------------
Logger.info(string.format(
    "AI XMP Color Importer v%s 启动（目标环境 %s，LrSdkVersion=%s）",
    Manifest.pluginVersionText, Manifest.verifiedOn, tostring(Manifest.lrSdkVersion)),
    { operation = "STARTUP" })

Logger.debug("已加载模块：" .. table.concat(Loader.loadedPaths(), ", "),
    { operation = "STARTUP" })

--[[
    ★★★ 顶层绝对不能用原生 pcall 包住整个流程 ★★★

    流程里到处是 yield 型 SDK 调用：
        photo:getRawMetadata / getFormattedMetadata
        catalog:batchGetRawMetadata / withWriteAccessDo
        photo:getDevelopSettings / LrTasks.sleep ...
    Lua 5.1 的 pcall 是 C 函数，跨 C 边界不允许 yield，
    一旦被它挡住，这些调用会**全部失败**并报
        "Yielding is not allowed within a C or metamethod call"
    而且 pcall 会把错误吞掉，让你以为是别的原因（这个坑真实踩过）。

    官方错误处理方式（LrFunctionContext）：
      · postAsyncTaskWithContext(name, func)  —— 启动异步任务并给出函数上下文
      · LrDialogs.attachErrorDialogToFunctionContext(context) —— 出错时弹 Lightroom 标准错误框
      · context:addFailureHandler(fn)         —— 同时把错误记进我们自己的日志
]]
local LrFunctionContext = import "LrFunctionContext"

LrFunctionContext.postAsyncTaskWithContext("AI Color Importer", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)

    context:addFailureHandler(function(okFlag, errMsg)
        Logger.error("AI Color Importer 出错：" .. tostring(errMsg), {
            operation = "FATAL",
            result    = "FAILED",
        })
    end)

    local ImportDialog = Loader.load("ui/ImportDialog.lua")
    ImportDialog.run()
end)
