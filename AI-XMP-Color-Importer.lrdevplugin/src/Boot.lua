--[[
    src/Boot.lua  —  统一的启动引导（三个入口共用）

    谁来加载它：
        Main.lua / AutomationStart.lua / AutomationStop.lua 都用同一段 4 行代码：
            local LrPathUtils, LrFileUtils = import "LrPathUtils", import "LrFileUtils"
            local Boot = loadstring(LrFileUtils.readFile(
                LrPathUtils.child(_PLUGIN.path, "src/Boot.lua")), "@src/Boot.lua")()
            local ctx = Boot.prepare()

        （Lightroom 没有 package / package.path，所以连"加载引导本身"都得这么来。
          用 LrFileUtils.readFile 而不是 io，是因为前者不受系统 ANSI 代码页限制。）

    prepare() 做什么（幂等，重复调用只做一次）：
        1. 建立模块加载器，挂到插件全局 AI_COLOR_IMPORTER
        2. 加载 Utils / Logger / manifest
        3. 把 Lightroom 的文件 / 时间能力注入 Utils.platform
        4. 配置日志（落盘到 Lightroom Logs）

    返回 ctx：
        { load = function(relPath), utils =, logger =, manifest =, loader =, root = }
--]]

local Boot = {}

local function toSlashes(p)
    return (tostring(p):gsub("\\", "/"))
end

--- 读取插件内某个文件的源码
local function readPluginSource(pluginRoot, relativePath)
    local LrFileUtils = import "LrFileUtils"
    local LrPathUtils = import "LrPathUtils"

    local full = LrPathUtils.child(pluginRoot, relativePath)

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

--- 编译一段 Lua 源码（Lua 5.1 用 loadstring；5.2+ 叫 load）
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
-- 各平台能力的 Lightroom 实现
----------------------------------------------------------------------

-- 注意：这里接收 Utils，是为了能用 Utils.safeCall 而不是原生 pcall。
-- LrFileUtils 里 readFile / exists 不 yield，但 **move / delete / 目录操作会 yield**，
-- 用原生 pcall 包住它们会报 "Yielding is not allowed within a C or metamethod call"，
-- 而且错误会被 pcall 吞掉（曾经导致 job 归档静默失败、卡在 inbox 里反复重试）。
local function buildPlatform(pluginRoot, Utils)
    local LrFileUtils = import "LrFileUtils"
    local LrPathUtils = import "LrPathUtils"

    local function lrFileExists(path)
        local ok, kind = pcall(LrFileUtils.exists, path)
        return ok and kind ~= false and kind ~= nil
    end

    return {
        -- 官方建议：路径可能含非 ASCII 字符时优先用 LrFileUtils.readFile 而不是 io
        readFile = function(path)
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
            if content == nil then
                return nil, "读取失败（返回空）"
            end
            return content
        end,

        -- LrFileUtils 没有写文件函数（官方 API 列表里确实没有），只能走 Lua 的 io。
        -- 因此队列目录请放在纯 ASCII 路径下，否则 Windows 的 ANSI fopen 可能打不开。
        writeFile = function(path, contents)
            if type(path) ~= "string" or path == "" then
                return nil, "路径为空"
            end
            if type(io) ~= "table" or type(io.open) ~= "function" then
                return nil, "当前环境无法写文件"
            end
            local f, err = io.open(path, "wb")
            if not f then
                return nil, err or ("无法写入：" .. path)
            end
            local okWrite, werr = f:write(contents)
            f:close()
            if okWrite == nil then
                return nil, werr or "写入失败"
            end
            return true
        end,

        fileExists = lrFileExists,

        makeDirectory = function(path)
            local ok, err = Utils.safeCall("ai-color-mkdir", function()
                return LrFileUtils.createAllDirectories(path)
            end)
            if not ok then
                return false, tostring(err)
            end
            return true
        end,

        -- directoryEntries / files 都是迭代器，且文档要求不能 break 出循环
        listFiles = function(dirPath)
            local out = {}
            if type(dirPath) ~= "string" or dirPath == "" then
                return out
            end
            local ok = Utils.safeCall("ai-color-list-files", function()
                for filePath in LrFileUtils.files(dirPath) do
                    out[#out + 1] = filePath
                end
            end)
            if not ok then
                return {}
            end
            table.sort(out)
            return out
        end,

        -- LrFileUtils.move 会 yield，必须走 safeCall。
        -- ★ 注意：safeCall 的第一个返回值是「调用有没有抛异常」，
        --   而 LrFileUtils.move 自己会用 (false, reason) 表示「失败但不抛异常」。
        --   之前就是只看第一个返回值，把 move 的失败当成了成功 —— 结果 job 永远不归档，
        --   还看不到任何错误。
        moveFile = function(srcPath, destPath)
            local okCall, result, reason = Utils.safeCall("ai-color-move-file", function()
                return LrFileUtils.move(srcPath, destPath)
            end)
            if not okCall then
                return nil, "调用异常：" .. tostring(result)
            end
            if result == false or result == nil then
                return nil, "move 返回失败：" .. tostring(reason or "（没有给出原因）")
            end
            return true
        end,

        chooseUniqueFile = function(path)
            local ok, unique = Utils.safeCall("ai-color-unique-file", function()
                return LrFileUtils.chooseUniqueFileName(path)
            end)
            if ok and type(unique) == "string" then
                return unique
            end
            return path
        end,

        fileSize = function(path)
            local ok, attrs = Utils.safeCall("ai-color-file-attrs", function()
                return LrFileUtils.fileAttributes(path)
            end)
            if ok and type(attrs) == "table" then
                return attrs.fileSize
            end
            return nil
        end,

        deleteFile = function(path)
            local okCall, result, reason = Utils.safeCall("ai-color-delete-file", function()
                return LrFileUtils.delete(path)
            end)
            if not okCall or result == false or result == nil then
                return false, tostring(reason or result or "delete 失败")
            end
            return true
        end,

        joinPath = function(...)
            local parts, n = { ... }, select("#", ...)
            if n == 0 then return "" end
            local out = parts[1]
            for i = 2, n do
                out = LrPathUtils.child(out, parts[i])
            end
            return out
        end,

        now = function()
            local ok, t = pcall(os.time)
            if ok and type(t) == "number" then
                return t
            end
            local ok2, t2 = pcall(function()
                local LrDate = import "LrDate"
                return LrDate.currentTime()
            end)
            if ok2 and type(t2) == "number" then
                return t2
            end
            return 0
        end,

        date = function(fmt, t)
            local ok, s = pcall(os.date, fmt, t)
            if ok and type(s) == "string" then
                return s
            end
            local ok2, s2 = pcall(function()
                return import("LrDate").timeToW3CDate(t)
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
        end,
    }
end

----------------------------------------------------------------------
-- 引导
----------------------------------------------------------------------

--- 初始化插件运行时（幂等）
-- @return ctx table { load, utils, logger, manifest, loader, root }
function Boot.prepare()
    if AI_COLOR_IMPORTER and AI_COLOR_IMPORTER.booted then
        -- ★ 已经初始化过时，**必须把 ctx 字段补齐再返回**。
        --   这里原来直接 return Boot，而 Boot.load 只在下面完整初始化时才赋值，
        --   于是「先开主界面、再点自动化菜单」这类第二次调用会拿到一个没有 load 的
        --   Boot，报 attempt to call field 'load' (a nil value)。
        Boot.root     = AI_COLOR_IMPORTER.root
        Boot.load     = AI_COLOR_IMPORTER.load
        Boot.loader   = AI_COLOR_IMPORTER.Loader
        Boot.utils    = AI_COLOR_IMPORTER.load("src/Utils.lua")
        Boot.logger   = AI_COLOR_IMPORTER.load("src/Logger.lua")
        Boot.manifest = AI_COLOR_IMPORTER.load("manifest.lua")
        return Boot
    end

    ----------------------------------------------------------------
    -- 1) 插件根目录（_PLUGIN.path 是官方文档化的只读属性）
    ----------------------------------------------------------------
    local pluginRoot = "."
    do
        local ok, path = pcall(function() return _PLUGIN.path end)
        if ok and type(path) == "string" and path ~= "" then
            pluginRoot = toSlashes(path)
        end
    end
    Boot.root = pluginRoot

    ----------------------------------------------------------------
    -- 2) 加载 Loader 自身（它还不在，只能先手工读一次）
    ----------------------------------------------------------------
    local source, rerr = readPluginSource(pluginRoot, "src/Loader.lua")
    if not source then
        error("无法加载 src/Loader.lua —— 插件文件不完整？\n      " .. tostring(rerr), 0)
    end
    local chunk, cerr = compileSource(source, "src/Loader.lua")
    if not chunk then
        error("src/Loader.lua 编译失败：\n      " .. tostring(cerr), 0)
    end
    local Loader = chunk()
    if type(Loader) ~= "table" then
        error("src/Loader.lua 没有返回模块表", 0)
    end

    Loader.configure {
        root       = pluginRoot,
        readSource = function(rel)
            return readPluginSource(pluginRoot, rel)
        end,
    }

    -- 官方文档：插件里定义的全局位于「本插件专属的函数环境」，不影响 Lightroom 整体
    AI_COLOR_IMPORTER        = AI_COLOR_IMPORTER or {}
    AI_COLOR_IMPORTER.root   = pluginRoot
    AI_COLOR_IMPORTER.load   = Loader.load
    AI_COLOR_IMPORTER.Loader = Loader
    AI_COLOR_IMPORTER.booted = false   -- 下面全部成功后再置 true

    ----------------------------------------------------------------
    -- 3) 业务模块
    ----------------------------------------------------------------
    local Utils    = Loader.load("src/Utils.lua")
    local Logger   = Loader.load("src/Logger.lua")
    local Manifest = Loader.load("manifest.lua")

    Boot.load   = Loader.load
    Boot.loader = Loader
    Boot.utils  = Utils
    Boot.logger = Logger
    Boot.manifest = Manifest

    ----------------------------------------------------------------
    -- 4) 平台注入
    ----------------------------------------------------------------
    Utils.configurePlatform(buildPlatform(pluginRoot, Utils))

    ----------------------------------------------------------------
    -- 5) 日志
    ----------------------------------------------------------------
    local attached = Logger.attachLightroom(Manifest.loggerName)
    Logger.configure {
        level      = "info",
        maxEntries = Manifest.defaults.maxLogEntries,
        echo       = not attached,
    }

    AI_COLOR_IMPORTER.booted = true
    return Boot
end

return Boot
