--[[
    src/Loader.lua  —  插件内模块加载器（零依赖，可脱离 Lightroom 单测）

    ==================================================================
    为什么需要自己写加载器（已逐字核实，不是猜测）
    ==================================================================
    Lightroom Classic **不支持 Lua 5.1 的模块系统**。官方 SDK Programmer's Guide 原文：

      · 第 12 页：
        "Lightroom Classic defines a namespace as a table containing a suite of
         functions. This is somewhat like the Lua module; however, **Lightroom
         Classic does not use or support the module system that was introduced
         in Lua 5.1**"

      · 第 19-20 页「Using built-in Lua features」：
          在 Lightroom 中**可用**的 Lua 全局函数：
              assert, dofile, error, getmetatable, ipairs, load, loadfile,
              loadstring, next, pairs, pcall, rawequal, rawget, rawset,
              select, setmetatable, tonumber, tostring, type, unpack
          **不可用**：
              collectgarbage, gcinfo, getfenv, module, newproxy, **package**, setfenv
          标准库：io / math / string 可用；**package 完全不可用**；
              os 只剩 clock/date/time/tmpname；table 去掉 getn/setn/maxn

      => `package` 是 nil，`package.path` 根本不存在。
         所以**不能**用「把 src/ 与 ui/ 加进 package.path」这种常规做法。

    ==================================================================
    本加载器怎么做
    ==================================================================
      1. 用 `LrFileUtils.readFile` 读源码 —— 官方明确建议：路径可能含非 ASCII 字符时
         优先用它，而不是受系统 ANSI 代码页限制的 C `fopen`（后者遇到中文路径会打不开）。
      2. 用文档列为「可用」的 `loadstring` 编译。
      3. 自己缓存模块实例，保证「同一个模块只加载一次」，
         这对 Utils.platform 这类单例状态是必需的。

    路径解析由调用方注入（readSource），因此本文件零依赖、可在普通 Lua 环境完整单测。
]]

local Loader = {}

--- 编译源码的入口。
--  Lua 5.1（也就是 Lightroom 内嵌的版本）用 loadstring；
--  Lua 5.2+ 把它改名为 load（并且 load 直接接受字符串）。
--  两个分支语义一致，所以这里取一个即可。
local compileString = loadstring or load

----------------------------------------------------------------------
-- 实例
----------------------------------------------------------------------

local LoaderMT = {}
LoaderMT.__index = LoaderMT

--- 创建一个独立的加载器实例（测试用；生产用下面的默认单例）
function Loader.new()
    return setmetatable({
        cache      = {},     -- relativePath -> module table
        readSource = nil,    -- function(relativePath) -> source | nil, err
        root       = nil,
        count      = 0,      -- 实际执行过的模块数（命中缓存不计数）
    }, LoaderMT)
end

--- @param opts table { root = string, readSource = function }
function LoaderMT:configure(opts)
    opts = opts or {}
    if opts.root ~= nil then
        self.root = opts.root
    end
    if opts.readSource ~= nil then
        self.readSource = opts.readSource
    end
    return self
end

--- 加载（或从缓存取回）一个模块
-- @param relativePath string 相对插件根目录，例如 "src/Utils.lua"、"ui/ImportDialog.lua"
-- @return module table（即模块文件的 return 值）
function LoaderMT:load(relativePath)
    if type(relativePath) ~= "string" or relativePath == "" then
        error("Loader.load: 需要一个非空的模块相对路径", 0)
    end

    -- 关键：同一模块只加载一次，保证单例状态（例如 Utils.platform）不被复制
    local cached = self.cache[relativePath]
    if cached ~= nil then
        return cached
    end

    if type(self.readSource) ~= "function" then
        error("Loader.load: 还没有配置 readSource，无法读取模块 " .. relativePath, 0)
    end

    local source, err = self.readSource(relativePath)
    if not source then
        error(string.format(
            "无法加载模块 %s\n      原因：%s",
            relativePath, tostring(err)), 0)
    end
    if type(source) ~= "string" or source == "" then
        error("模块 " .. relativePath .. " 的文件内容为空", 0)
    end

    -- 去掉 UTF-8 BOM（带 BOM 的源文件会让 loadstring 直接编译失败）
    local body = source
    if body:sub(1, 3) == "\239\187\191" then
        body = body:sub(4)
    end

    local chunk, cerr = compileString(body, "@" .. relativePath)
    if not chunk then
        error(string.format(
            "模块 %s 编译失败\n      原因：%s",
            relativePath, tostring(cerr)), 0)
    end

    -- 关于执行环境（重要，已验证）：
    --   Lua 5.1 的 loadstring 不会继承调用者的环境，新 chunk 会落在「全局环境」上。
    --   在 Lightroom 中，那个「全局环境」正是本插件专属的函数环境
    --   （官方指南 p.21：插件的全局定义在 "a special function environment for your plug-in"），
    --   因此模块里的 AI_COLOR_IMPORTER / _PLUGIN / import 都能正常解析，无需额外处理。
    --   Lightroom 不提供 setfenv/getfenv（官方 p.19 列为不可用），所以这里也不依赖它们。
    local ok, mod = pcall(chunk)
    if not ok then
        error(string.format(
            "模块 %s 执行失败\n      原因：%s",
            relativePath, tostring(mod)), 0)
    end
    if mod == nil then
        error(string.format(
            "模块 %s 没有 return 任何值（每个模块都必须 return 自己的表）",
            relativePath), 0)
    end

    self.cache[relativePath] = mod
    self.count = self.count + 1
    return mod
end

--- 该模块是否已经加载过
function LoaderMT:isCached(relativePath)
    return self.cache[relativePath] ~= nil
end

--- 实际执行过的模块数量
function LoaderMT:loadedCount()
    return self.count
end

--- 清空缓存（仅供测试）
function LoaderMT:reset()
    self.cache = {}
    self.count = 0
end

--- 已加载模块的相对路径列表（排序，便于日志与断言）
function LoaderMT:loadedPaths()
    local out = {}
    for k in pairs(self.cache) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

----------------------------------------------------------------------
-- 默认单例（Main.lua 与各模块共用）
----------------------------------------------------------------------

local default = Loader.new()

--- 模块级转发函数。这些是「函数」而不是「方法」，
--  但为了容错，如果被用 ':' 语法调用（第一个参数会是 Loader 表本身），
--  会自动把那个 self 丢掉，避免出现「查了 Loader 表当 key」这种静默错误。
local function stripSelf(first)
    if first == Loader then
        return nil
    end
    return first
end

function Loader.configure(opts) return default:configure(opts) end
function Loader.load(relativePath) return default:load(stripSelf(relativePath)) end
function Loader.isCached(relativePath) return default:isCached(stripSelf(relativePath)) end
function Loader.loadedCount() return default:loadedCount() end
function Loader.reset() return default:reset() end
function Loader.loadedPaths() return default:loadedPaths() end

Loader.default = default

----------------------------------------------------------------------
-- 各模块统一的依赖获取入口
----------------------------------------------------------------------

--- 拿到「模块加载器」。Lightroom 里由 Main.lua 挂到插件专属全局上；
--  普通 Lua 测试环境里由测试引导代码挂上同名全局。
--  这样各模块代码在两种环境下写法完全一致。
function Loader.require()
    local host = rawget(_G, "AI_COLOR_IMPORTER")
    if type(host) == "table" and type(host.load) == "function" then
        return host.load
    end
    error(
        "AI_COLOR_IMPORTER 加载器不存在。\n" ..
        "      · 在 Lightroom 中：说明 Main.lua 没有正常运行（插件未正确加载）\n" ..
        "      · 在测试中：请先设置 AI_COLOR_IMPORTER = { load = ... } 再 require 业务模块", 0)
end

return Loader
