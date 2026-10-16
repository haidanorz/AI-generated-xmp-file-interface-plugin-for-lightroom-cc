--[[
    src/Utils.lua  —  通用工具层（纯 Lua，无 Lightroom 依赖）

    设计要点：
      * 所有「平台能力」（读文件 / 写文件 / 取时间 / 拼接路径）都通过 Utils.platform
        间接访问。Lightroom 沙箱里没有 io / os.getenv，必须换成 LrFileUtils / LrPathUtils。
        Main.lua 启动时会调用 Utils.configurePlatform{...} 注入 Lightroom 实现；
        普通 Lua 测试环境则使用下面的默认实现（io / os）。
      * 这样 XmpParser / XmpMapping / Validation 三个核心模块可以在普通 Lua 里跑单元测试，
        完全不需要 Lightroom runtime。

    Lua 5.1 兼容（同时兼容 5.3/5.4，便于用 fengari/lupa 做交叉验证）。
--]]

local Utils = {}

-- Lua 5.1/5.3 兼容
local unpack = table.unpack or unpack

----------------------------------------------------------------------
-- 平台抽象
----------------------------------------------------------------------

local platform = {
    readFile   = nil,   -- function(path) -> contents | nil, err
    writeFile  = nil,   -- function(path, contents) -> ok | nil, err
    fileExists = nil,   -- function(path) -> boolean
    joinPath   = nil,   -- function(...) -> path
    now        = nil,   -- function() -> os.time() 风格整数
    date       = nil,   -- function(fmt, t) -> string
    sleep      = nil,   -- function(seconds)
}

local hasIO = (type(io) == "table" and type(io.open) == "function")

if hasIO then
    platform.readFile = function(path)
        if type(path) ~= "string" or path == "" then
            return nil, "路径为空"
        end
        local f, err = io.open(path, "rb")
        if not f then
            return nil, err or ("无法打开文件: " .. path)
        end
        local content = f:read("*a")
        f:close()
        if content == nil then
            return nil, "读取文件内容失败: " .. path
        end
        return content
    end

    platform.writeFile = function(path, contents)
        local f, err = io.open(path, "wb")
        if not f then
            return nil, err or ("无法写入文件: " .. tostring(path))
        end
        f:write(contents)
        f:close()
        return true
    end

    platform.fileExists = function(path)
        local f = io.open(path, "rb")
        if f then
            f:close()
            return true
        end
        return false
    end
end

-- 路径拼接默认实现：统一使用 '/' 作为分隔符（Windows / macOS 均可识别）
platform.joinPath = function(...)
    local parts, n = { ... }, select("#", ...)
    local out = {}
    for i = 1, n do
        local p = parts[i]
        if type(p) == "string" and p ~= "" then
            if #out > 0 then
                p = p:gsub("^[\\/]+", "")
            end
            p = p:gsub("[\\/]+$", "")
            if p ~= "" then
                out[#out + 1] = p
            end
        end
    end
    local sep = "/"
    local joined = table.concat(out, sep)
    -- 保留 UNC / 盘符前缀
    local first = parts[1]
    if type(first) == "string" and first:match("^[\\/]") and not first:match("^[\\/][\\/]") then
        joined = "/" .. joined
    end
    return joined
end

if type(os) == "table" then
    platform.now = function()
        if type(os.time) == "function" then
            return os.time()
        end
        return 0
    end
    platform.date = function(fmt, t)
        if type(os.date) == "function" then
            return os.date(fmt, t)
        end
        return "?"
    end
end

if type(os) == "table" and type(os.clock) == "function" then
    platform.sleep = function(seconds)
        local t0 = os.clock()
        while os.clock() - t0 < seconds do end
    end
end

Utils.platform = platform

--- 注入 / 覆盖平台实现（Lightroom 端由 Main.lua 调用）
-- @param overrides table 键名同 platform
function Utils.configurePlatform(overrides)
    if type(overrides) ~= "table" then
        return
    end
    for k, v in pairs(overrides) do
        if platform[k] == nil or v ~= nil then
            platform[k] = v
        end
    end
end

--- 是否运行在 Lightroom 内部（存在 _PLUGIN 全局）
function Utils.isLightroom()
    return type(_PLUGIN) == "table"
end

----------------------------------------------------------------------
-- Lightroom 模块导入 与 yield-safe 受保护调用
--
--  ★★★ 本项目最重要的一个坑（已用真实故障定位）★★★
--  Lightroom 的很多 SDK 调用会「让出」(yield) 给 Lightroom 主循环，
--  例如：
--      photo:getRawMetadata()  photo:getFormattedMetadata()
--      catalog:batchGetRawMetadata()  catalog:withWriteAccessDo()
--      photo:getDevelopSettings()  LrTasks.sleep()  ...
--
--  Lua 5.1 的 pcall 是 **C 函数**，跨 C 边界不允许 yield，因此一旦把这类调用
--  包进原生 pcall，它们就会全部失败，报：
--      "Yielding is not allowed within a C or metamethod call"
--  更糟的是 pcall 会把错误吞掉，让人误以为是别的原因。
--
--  官方解法（LrFunctionContext API Reference）：
--      LrFunctionContext.pcallWithContext
--        "执行保护调用，类似 Lua 标准 pcall，但在返回控制权前会调用所有清理处理器"
--        异步行为：若从异步任务中调用，**会使用 LrTasks.pcall()**（即 yield-safe 版本）
--
--  所以：凡是可能触碰 Lightroom SDK 的受保护调用，一律用 Utils.safeCall，
--        不要直接用 Lua 的 pcall。
----------------------------------------------------------------------

local lrCache = {}

--- 延迟导入 Lightroom 命名空间；不在 Lightroom 中时返回 nil。
-- （import 本身不会 yield，所以这里用原生 pcall 是安全的）
function Utils.lrImport(name)
    if lrCache[name] ~= nil then
        return lrCache[name]
    end
    if type(import) ~= "function" then
        return nil
    end
    local ok, mod = pcall(import, name)
    if ok and mod ~= nil then
        lrCache[name] = mod
        return mod
    end
    return nil
end

--- yield-safe 的受保护调用，返回值与 pcall 完全一致：(ok, ...)
--  · Lightroom 里：走 LrFunctionContext.pcallWithContext（异步任务中 = LrTasks.pcall）
--  · 普通 Lua 里：退回标准 pcall
-- @param name string 上下文名（仅用于调试）
-- @param fn function 要执行的函数
function Utils.safeCall(name, fn)
    local LrFunctionContext = Utils.lrImport("LrFunctionContext")
    if LrFunctionContext and type(LrFunctionContext.pcallWithContext) == "function" then
        return LrFunctionContext.pcallWithContext(name or "AI Color", fn)
    end
    return pcall(fn)
end

--- 当前是否具备 yield-safe 的受保护调用能力（诊断用）
function Utils.hasYieldSafeCall()
    local LrFunctionContext = Utils.lrImport("LrFunctionContext")
    return LrFunctionContext ~= nil
        and type(LrFunctionContext.pcallWithContext) == "function"
end

----------------------------------------------------------------------
-- 字符串
----------------------------------------------------------------------

--- 去首尾空白（含各类 Unicode 空白与换行）
function Utils.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    -- \194\160 = U+00A0 NBSP, \226\128\174 = U+202E 之类不做处理，只处理常见空白
    s = s:gsub("^[ \t\r\n\194\160]+", "")
    s = s:gsub("[ \t\r\n\194\160]+$", "")
    return s
end

--- 是否是空串或纯空白
function Utils.isBlank(s)
    if s == nil then
        return true
    end
    if type(s) ~= "string" then
        return false
    end
    return Utils.trim(s) == ""
end

--- 按分隔字符切分；不会对空片段做特殊处理
-- @param s string
-- @param sep string 单个字符（会按 Lua pattern 处理，默认逗号）
function Utils.split(s, sep)
    sep = sep or ","
    local out = {}
    if type(s) ~= "string" then
        return out
    end
    for piece in s:gmatch("([^" .. sep .. "]+)") do
        out[#out + 1] = piece
    end
    return out
end

--- 严格数字解析。
-- 与 tonumber 的区别：拒绝空串、拒绝 16 进制、拒绝 NaN/Infinity、去首尾空白。
-- @return number | nil, errString
function Utils.parseNumber(raw)
    if type(raw) == "number" then
        if raw ~= raw then
            return nil, "NaN 不是合法数值"
        end
        if raw == math.huge or raw == -math.huge then
            return nil, "Infinity 不是合法数值"
        end
        return raw
    end

    if type(raw) ~= "string" then
        return nil, "不是数字或数字字符串（实际类型: " .. type(raw) .. "）"
    end

    local s = Utils.trim(raw)
    if s == "" then
        return nil, "空字符串不是合法数值"
    end

    -- 只接受十进制：可选符号、整数部分、可选小数、可选指数
    local isDecimal =
        s:match("^[%+%-]?%d+$") or
        s:match("^[%+%-]?%d*%.%d+$") or
        s:match("^[%+%-]?%d+%.%d*$") or
        s:match("^[%+%-]?%d+%.?%d*[eE][%+%-]?%d+$") or
        s:match("^[%+%-]?%d*%.%d+[eE][%+%-]?%d+$")

    if not isDecimal then
        -- 明确点出几种常见坏值
        local low = s:lower()
        if low == "nan" or low:match("^[%+%-]?nan$") then
            return nil, "NaN 不是合法数值"
        end
        if low:match("inf") then
            return nil, "Infinity 不是合法数值"
        end
        return nil, "非法数字: \"" .. s .. "\""
    end

    local n = tonumber(s)
    if n == nil then
        return nil, "非法数字: \"" .. s .. "\""
    end
    if n ~= n then
        return nil, "NaN 不是合法数值"
    end
    if n == math.huge or n == -math.huge then
        return nil, "Infinity 不是合法数值"
    end
    return n
end

--- 布尔解析：接受 Lua boolean 与常见 XMP 写法
-- @return boolean | nil, err
function Utils.parseBoolean(raw)
    if type(raw) == "boolean" then
        return raw
    end
    if type(raw) == "number" then
        if raw == 0 then return false end
        if raw == 1 then return true end
        return nil, "无法把数字 " .. tostring(raw) .. " 解释为布尔值"
    end
    if type(raw) ~= "string" then
        return nil, "无法把 " .. type(raw) .. " 解释为布尔值"
    end
    local s = Utils.trim(raw):lower()
    if s == "true" or s == "1" then return true end
    if s == "false" or s == "0" then return false end
    return nil, "无法把 \"" .. raw .. "\" 解释为布尔值"
end

--- 数字显示：正数带 +，负数带 -，去掉无意义的尾随 0
function Utils.formatSigned(n)
    if type(n) ~= "number" then
        return tostring(n)
    end
    if n ~= n then
        return "NaN"
    end
    local s
    if n == math.floor(n) and math.abs(n) < 1e15 then
        s = string.format("%d", n)
    else
        s = string.format("%.4f", n)
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    if n > 0 and not s:match("^%+") then
        s = "+" .. s
    end
    return s
end

--- 数字显示：不带正号（用于色相 0-360、色温等）
function Utils.formatPlain(n, decimals)
    if type(n) ~= "number" then
        return tostring(n)
    end
    if decimals then
        return string.format("%." .. decimals .. "f", n)
    end
    if n == math.floor(n) then
        return string.format("%d", n)
    end
    local s = string.format("%.4f", n)
    return (s:gsub("0+$", ""):gsub("%.$", ""))
end

----------------------------------------------------------------------
-- 表
----------------------------------------------------------------------

--- 计数字典/数组中的键数量
function Utils.tcount(t)
    local n = 0
    if type(t) ~= "table" then
        return 0
    end
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

--- 返回排序后的键数组（便于确定性输出 / 测试稳定）
function Utils.sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            return a < b
        end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- 浅拷贝
function Utils.shallowCopy(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[k] = v
    end
    return out
end

--- 数组是否为空
function Utils.isEmptyArray(t)
    return type(t) ~= "table" or #t == 0
end

Utils.unpack = unpack

----------------------------------------------------------------------
-- 路径
----------------------------------------------------------------------

--- 取文件名（含扩展名）；同时兼容 Windows 与 POSIX 分隔符
function Utils.basename(p)
    if type(p) ~= "string" then
        return ""
    end
    local name = p:match("[^\\/]+$")
    return name or p
end

--- 取扩展名（小写，不含点）
function Utils.extension(p)
    local name = Utils.basename(p)
    local ext = name:match("%.([^.]+)$")
    if ext then
        return ext:lower()
    end
    return ""
end

--- 去掉扩展名
function Utils.stripExtension(p)
    local name = Utils.basename(p)
    return (name:gsub("%.[^.]+$", ""))
end

--- 统一分隔符为 '/'
function Utils.normalizePath(p)
    if type(p) ~= "string" then
        return ""
    end
    return (p:gsub("\\", "/"))
end

--- 只保留文件名主干用于「宽容比较」：
-- 去扩展名、去 AI 生成 XMP 常见的 "__xxx__AI-vN" 后缀、转小写。
-- 例：IMG_1023__Natural_Warm__AI-v1.xmp -> img_1023
function Utils.tolerantBaseName(p)
    local base = Utils.stripExtension(Utils.basename(p))
    base = base:gsub("__.*$", "")
    base = base:gsub("[%s_%-]+$", "")
    return base:lower()
end

----------------------------------------------------------------------
-- 时间
----------------------------------------------------------------------

--- 日志时间戳，格式 YYYY-MM-DD HH:MM:SS
function Utils.timestamp(t)
    if platform.date then
        local ok, s = pcall(platform.date, "%Y-%m-%d %H:%M:%S", t)
        if ok and type(s) == "string" then
            return s
        end
    end
    return "unknown-time"
end

--- 文件名安全时间戳，格式 YYYYMMDD-HHMMSS
function Utils.fileTimestamp(t)
    if platform.date then
        local ok, s = pcall(platform.date, "%Y%m%d-%H%M%S", t)
        if ok and type(s) == "string" then
            return s
        end
    end
    return "unknown"
end

return Utils
