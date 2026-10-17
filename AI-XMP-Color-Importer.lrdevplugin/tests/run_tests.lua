--[[
    tests/run_tests.lua  —  测试入口

    用法：
        lua tests/run_tests.lua [pluginRoot]

    在不传参时会从脚本自身路径推断插件根目录，因此可以直接：
        fengari AI-XMP-Color-Importer.lrdevplugin/tests/run_tests.lua
        lupa(lua51)  -> python tests/run_lua51.py
--]]

----------------------------------------------------------------------
-- 定位插件根目录
----------------------------------------------------------------------
local scriptPath = (arg and arg[0]) or "tests/run_tests.lua"

local function dirname(p)
    return (tostring(p):match("^(.*)[/\\][^/\\]*$")) or "."
end

local root = (arg and arg[1]) or nil
if not root or root == "" then
    root = dirname(dirname(scriptPath))
end
root = tostring(root):gsub("\\", "/")

package.path = table.concat({
    root .. "/?.lua",
    root .. "/src/?.lua",
    root .. "/ui/?.lua",
    root .. "/tests/?.lua",
    package.path or "",
}, ";")

----------------------------------------------------------------------
-- 插件加载器全局
--   业务模块一律通过 AI_COLOR_IMPORTER.load("src/Xxx.lua") 取依赖
--   （因为 Lightroom 里 `package` 不可用，不能用 package.path 方案）。
--   测试环境里提供一个同接口的实现，底层走标准 require（package.path 已设好）。
----------------------------------------------------------------------
AI_COLOR_IMPORTER = {
    root = root,
    load = function(relativePath)
        local name = tostring(relativePath):match("([^/]+)%.lua$") or tostring(relativePath)
        return require(name)
    end,
}

----------------------------------------------------------------------
local T = require "framework"
T.setRoot(root)

local Utils     = require "Utils"
local Manifest  = require "manifest"

T.log_root = root
T.suite("测试环境")
T.case("插件根目录可定位: " .. tostring(root), function()
    T.truthy(root ~= "" and root ~= ".", "根目录为空")
end)
T.case("Lua 运行时版本: " .. tostring(_VERSION), function()
    T.truthy(_VERSION ~= nil)
end)

--- 依赖 fixture 的用例需要文件读取能力。
-- Lightroom 里由 Main.lua 注入 LrFileUtils；普通 Lua 里靠 io 库。
-- fengari 等刻意禁用 io 的运行时会走到这里，给出明确提示而不是一堆 NULL 错误。
if Utils.platform.readFile == nil then
    print("")
    print("!! 当前 Lua 运行时不提供文件读取能力（没有 io 库），无法运行依赖 fixtures 的用例。")
    print("!! 请改用: python tests/run_lua51.py   (lupa 提供的 Lua 5.1 / LuaJIT)")
    if type(os) == "table" and type(os.exit) == "function" then
        os.exit(2)
    end
    return
end

----------------------------------------------------------------------
-- 加载期检查：所有模块都必须能在普通 Lua 环境下 require 成功。
-- 语法错误、顶层 index nil 等都会在这里暴露。
----------------------------------------------------------------------
T.suite("模块加载期检查（无 Lightroom 运行时）")

local MODULES = {
    -- 加载器本身（零依赖）
    "Loader",
    -- 纯 Lua 核心
    "Utils", "Logger", "manifest", "XmpParser", "XmpMapping",
    "Validation", "DevelopSettings",
    -- 无 UI 应用引擎
    "ApplyEngine",
    -- 自动化队列
    "Json", "JobRunner", "AutomationListener", "Boot",
    -- Lightroom 适配层（import 已改为延迟获取，因此也应能加载）
    "PhotoResolver", "ApplyDevelop",
    -- UI
    "ProgressDialog", "ImportDialog",
}

for _, name in ipairs(MODULES) do
    T.case("require \"" .. name .. "\"", function()
        local ok, mod = pcall(require, name)
        if not ok then
            error("加载失败: " .. tostring(mod), 0)
        end
        T.isTable(mod, "模块返回值必须是 table")
    end)
end

----------------------------------------------------------------------
-- 语法检查（只编译不执行）：入口与 SDK 清单
----------------------------------------------------------------------
T.suite("语法检查（loadfile，仅编译）")

local COMPILE_ONLY = { "Main.lua", "Info.lua", "manifest.lua" }

for _, rel in ipairs(COMPILE_ONLY) do
    T.case("编译 " .. rel, function()
        if type(loadfile) ~= "function" then
            error("当前 Lua 运行时没有 loadfile，跳过", 0)
        end
        local chunk, err = loadfile(root .. "/" .. rel)
        if not chunk then
            error("编译失败: " .. tostring(err), 0)
        end
    end)
end

----------------------------------------------------------------------
-- Info.lua 与 manifest.lua 的版本一致性（防止两份版本号漂移）
----------------------------------------------------------------------
T.suite("版本一致性")

T.case("Info.lua 的 VERSION 与 manifest.lua 一致", function()
    local text, err = Utils.platform.readFile(root .. "/Info.lua")
    if not text then
        error("无法读取 Info.lua: " .. tostring(err), 0)
    end
    local maj, min, rev, bld = text:match("VERSION%s*=%s*{%s*major%s*=%s*(%d+)%s*,%s*minor%s*=%s*(%d+)%s*,%s*revision%s*=%s*(%d+)%s*,%s*build%s*=%s*(%d+)")
    T.truthy(maj ~= nil, "在 Info.lua 中找不到 VERSION 表")

    local v = Manifest.pluginVersion
    T.eq(tonumber(maj), v.major, "major 不一致")
    T.eq(tonumber(min), v.minor, "minor 不一致")
    T.eq(tonumber(rev), v.revision, "revision 不一致")
    T.eq(tonumber(bld), v.build, "build 不一致")
end)

T.case("Info.lua 的 SDK 版本与 manifest.lua 一致", function()
    local text = Utils.platform.readFile(root .. "/Info.lua")
    local sdk = text and text:match("LrSdkVersion%s*=%s*([%d%.]+)")
    T.truthy(sdk ~= nil, "在 Info.lua 中找不到 LrSdkVersion")
    T.eq(tonumber(sdk), Manifest.lrSdkVersion, "LrSdkVersion 不一致")
end)

T.case("Info.lua 使用了官方合法的菜单键", function()
    local text = Utils.platform.readFile(root .. "/Info.lua")
    T.contains(text, "LrExportMenuItems", "缺少 文件▸增效工具扩展 菜单")
    T.contains(text, "LrLibraryMenuItems", "缺少 图库▸增效工具扩展 菜单")
    T.contains(text, "Main.lua", "菜单未指向 Main.lua")
    -- 注意：这里只做「正向存在性」检查。
    -- 「不能出现非法菜单键」由下面的「真实执行 Info.lua」用例通过遍历实际表键来保证，
    -- 那才是权威检查；在源文本里搜关键字会被注释内容误伤。
end)

----------------------------------------------------------------------
-- Info.lua 真实执行 + 结构校验
--   Info.lua 按 SDK 要求是纯数据文件（不 import 任何 Lr* 模块），
--   因此可以在这里真正执行它，把「清单写错导致插件加载失败」提前抓出来。
----------------------------------------------------------------------
T.suite("Info.lua 清单结构（真实执行）")

T.case("执行 Info.lua 并校验必需字段", function()
    local chunk, lerr = loadfile(root .. "/Info.lua")
    T.truthy(chunk ~= nil, "loadfile 失败: " .. tostring(lerr))

    local info = chunk()
    T.isTable(info, "Info.lua 必须 return 一个 table")

    T.eq(type(info.LrToolkitIdentifier), "string", "LrToolkitIdentifier 必须是字符串")
    T.truthy(#info.LrToolkitIdentifier > 0, "LrToolkitIdentifier 不能为空")
    T.eq(type(info.LrPluginName), "string", "LrPluginName 必须是字符串")

    T.eq(type(info.LrSdkVersion), "number", "LrSdkVersion 必须是数字")
    T.eq(type(info.LrSdkMinimumVersion), "number", "LrSdkMinimumVersion 必须是数字")
    T.truthy(info.LrSdkVersion >= info.LrSdkMinimumVersion,
        "LrSdkVersion 不能低于 LrSdkMinimumVersion")

    T.isTable(info.VERSION, "缺少 VERSION 表")
    T.eq(type(info.VERSION.major), "number", "VERSION.major 必须是数字")

    -- 清单里不允许出现函数（SDK 要求纯数据）
    for k, v in pairs(info) do
        T.neq(type(v), "function", "Info.lua 的字段 " .. tostring(k) .. " 不应是函数")
    end
end)

T.case("菜单项是单层结构，且每一项都有 title + file", function()
    local chunk = loadfile(root .. "/Info.lua")
    local info = chunk()

    -- 官方只认这三个键
    local OFFICIAL = {
        LrExportMenuItems = true, LrLibraryMenuItems = true, LrHelpMenuItems = true,
    }
    for key, v in pairs(info) do
        if key:match("MenuItems$") then
            T.truthy(OFFICIAL[key], "出现了非官方菜单键: " .. tostring(key))
        end
    end

    -- 成员表只允许 title / file / enabledWhen
    local ALLOWED = { title = true, file = true, enabledWhen = true }

    for _, key in ipairs({ "LrExportMenuItems", "LrLibraryMenuItems" }) do
        local items = info[key]
        T.isTable(items, key .. " 应为表")
        T.truthy(#items >= 1, key .. " 至少应有一个菜单项")

        for i, item in ipairs(items) do
            local where = string.format("%s[%d]", key, i)
            T.isTable(item, where .. " 应是表")
            T.eq(type(item.title), "string", where .. ".title 必须是字符串")
            T.eq(type(item.file), "string", where .. ".file 必须是字符串")

            -- ★ 回归防护：菜单项里绝不能出现 items 之类的嵌套键。
            --   这正是本次 Lightroom 报错的原因：
            --   "无法读取增效工具的菜单说明…(\"file\"是\"nil\"，应该是\"string\"。)"
            T.eq(item.items, nil,
                where .. " 含有 items 字段。SDK 的菜单只有一层，没有子菜单写法；" ..
                "写了会让 Lightroom 把该项当成缺少 file 的叶子项而报错")

            for k in pairs(item) do
                T.truthy(ALLOWED[k],
                    where .. " 含有非法的字段 \"" .. tostring(k) ..
                    "\"（官方只允许 title / file / enabledWhen）")
            end

            -- 被指向的脚本必须真的存在，否则点击时才会报错
            local target = root .. "/" .. item.file
            T.truthy(Utils.platform.fileExists(target),
                where .. " 指向的文件不存在: " .. tostring(item.file))
        end
    end
end)

T.case("菜单标题能自描述（因为 SDK 不支持子菜单，标题要自带分组）", function()
    local chunk = loadfile(root .. "/Info.lua")
    local info = chunk()
    local item = info.LrLibraryMenuItems[1]
    T.contains(item.title, "AI Color", "标题里应包含插件分组名，便于在「增效工具扩展」里辨认")
    T.contains(item.title, "Apply XMP", "标题应说明功能")
end)

----------------------------------------------------------------------
-- Loader：在「没有 package」的前提下加载模块
--   Lightroom 不提供 package / module / getfenv（官方指南 p.19-20），
--   因此插件不能靠 package.path 组织 src/ 与 ui/。加载器是整条链路的根。
----------------------------------------------------------------------
T.suite("Loader / 模块加载器（Lightroom 无 package 环境）")

local Loader = require "Loader"

local function fakeLoader()
    local L = Loader.new()
    L:configure {
        readSource = function(p)
            if p == "a.lua"  then return "return { name = 'a', n = 1 }" end
            if p == "b.lua"  then return "return { name = 'b', dep = AI_COLOR_IMPORTER.load('a.lua') }" end
            if p == "bom.lua" then return "\239\187\191return { bom = true }" end
            if p == "broken.lua" then return "this is ) not lua (((" end
            if p == "empty.lua" then return "" end
            if p == "noreturn.lua" then return "local x = 1" end
            return nil, "不存在: " .. tostring(p)
        end,
    }
    return L
end

T.case("能加载模块并拿到它的返回值", function()
    local L = fakeLoader()
    local a = L:load("a.lua")
    T.isTable(a, "应返回模块表")
    T.eq(a.name, "a")
    T.eq(a.n, 1)
end)

T.case("同一模块只加载一次（单例语义）", function()
    local L = fakeLoader()
    local a1 = L:load("a.lua")
    local a2 = L:load("a.lua")
    T.truthy(rawequal(a1, a2), "两次加载必须是同一个表实例")
    T.eq(L:loadedCount(), 1, "只应执行过一次")
    T.truthy(L:isCached("a.lua"))
end)

T.case("去 UTF-8 BOM", function()
    local L = fakeLoader()
    local m = L:load("bom.lua")
    T.eq(m.bom, true, "带 BOM 的源文件也应能编译")
end)

T.case("模块内的依赖通过 AI_COLOR_IMPORTER.load 解析", function()
    local L = fakeLoader()
    local real = AI_COLOR_IMPORTER
    AI_COLOR_IMPORTER = { load = function(p) return L:load(p) end }
    local ok, m = pcall(L.load, L, "b.lua")
    AI_COLOR_IMPORTER = real
    T.truthy(ok, "加载失败: " .. tostring(m))
    T.eq(m.name, "b")
    T.eq(m.dep.name, "a", "依赖应被正确解析")
end)

T.case("编译失败 / 空文件 / 无返回值 / 文件不存在 都给出可读错误", function()
    local cases = {
        { "broken.lua",   "编译" },
        { "empty.lua",    "为空" },
        { "noreturn.lua", "return" },
        { "missing.lua",  "无法加载模块" },
    }
    local L = fakeLoader()
    for _, c in ipairs(cases) do
        local ok, err = pcall(L.load, L, c[1])
        T.falsy(ok, c[1] .. " 应该报错")
        T.contains(tostring(err), c[2], c[1] .. " 的错误信息应包含「" .. c[2] .. "」")
    end
end)

T.case("未配置 readSource 时给出明确提示", function()
    local L = Loader.new()
    local ok, err = pcall(L.load, L, "x.lua")
    T.falsy(ok, "应报错")
    T.contains(tostring(err), "readSource", "错误信息应指明缺少 readSource")
end)

T.case("Loader.require() 能拿到宿主环境的加载器", function()
    local fn = Loader.require()
    T.eq(type(fn), "function", "应返回一个函数")
    T.eq(fn("manifest.lua"), require "manifest", "应能加载 manifest.lua")
end)

----------------------------------------------------------------------
-- 用「真实文件 + 真实加载器」把全部模块跑一遍
----------------------------------------------------------------------
T.suite("Loader / 真实文件集成（模拟 Lightroom 的引导方式）")

T.case("用 loadstring + 文件读取加载全部模块", function()
    local L = Loader.new()
    L:configure {
        root = root,
        readSource = function(rel)
            return Utils.platform.readFile(root .. "/" .. rel)
        end,
    }

    -- 把宿主加载器临时指向它，使模块间的依赖也走同一条路径
    local saved = AI_COLOR_IMPORTER
    AI_COLOR_IMPORTER = { root = root, load = function(p) return L:load(p) end }

    local ok, err = pcall(function()
        L:load("manifest.lua")
        local U = L:load("src/Utils.lua")
        L:load("src/Logger.lua")
        local P = L:load("src/XmpParser.lua")
        local M = L:load("src/XmpMapping.lua")
        L:load("src/Validation.lua")
        L:load("src/DevelopSettings.lua")
        L:load("src/PhotoResolver.lua")
        L:load("src/ApplyDevelop.lua")
        L:load("ui/ProgressDialog.lua")
        L:load("ui/ImportDialog.lua")

        -- 加载进来的实例必须真的能用
        T.near(U.parseNumber("0.35"), 0.35, 1e-9, "加载到的 Utils 应可正常工作")
        local parsed = P.parseFile(root .. "/tests/fixtures/basic.xmp")
        T.truthy(parsed ~= nil, "加载到的 XmpParser 应能解析 fixture")
        T.eq(parsed.fields.Highlights2012, "-25")
        T.truthy(M.FIELDS.Exposure2012 ~= nil, "加载到的 XmpMapping 应含字段表")
    end)

    AI_COLOR_IMPORTER = saved
    T.truthy(ok, "加载失败: " .. tostring(err))
    T.truthy(L:loadedCount() >= 11, "应加载了全部模块，实际 " .. L:loadedCount())
end)

----------------------------------------------------------------------
-- ★ 端到端：在「package 不存在」的沙箱里真实执行 Main.lua
--   这个用例直接对应真实故障：
--     [string "Main.lua"]:44: attempt to index global 'package' (a nil value)
--   Lightroom 不提供 package，所以 Main.lua 绝不能碰它。
----------------------------------------------------------------------
T.suite("Main.lua / 在 Lightroom 风格沙箱中真实执行")

local function buildSandbox(started)
    local lrPathUtils = {
        child = function(a, b)
            return (tostring(a):gsub("\\", "/") .. "/" .. tostring(b))
        end,
    }
    local lrFileUtils = {
        exists = function(p)
            local f = io.open(p, "rb")
            if f then f:close() return "file" end
            return false
        end,
        readFile = function(p)
            local f = io.open(p, "rb")
            if not f then return nil end
            local c = f:read("*a")
            f:close()
            return c
        end,
    }
    local imports = {
        LrPathUtils = lrPathUtils,
        LrFileUtils = lrFileUtils,
        LrTasks = {
            startAsyncTask = function(_, name) started[#started + 1] = name end,
            sleep = function() end,
        },
        LrDialogs = {
            message = function() end,
            confirm = function() return "cancel" end,
            showBezel = function() end,
            presentModalDialog = function() return "cancel" end,
            runOpenPanel = function() return nil end,
            attachErrorDialogToFunctionContext = function() end,
        },
        LrApplication = { activeCatalog = function() return nil end },
        LrDate = {
            currentTime = function() return 0 end,
            timeToW3CDate = function() return "2026-10-16T00:00:00" end,
        },
        LrPrefs = { prefsForPlugin = function() return {} end },
        LrBinding = { makePropertyTable = function() return {} end },
        LrFunctionContext = {
            -- callWithContext(name, func, ...)，函数上下文会作为首个实参传入
            callWithContext = function(_, fn)
                return fn({ addCleanupHandler = function() end,
                            addFailureHandler = function() end,
                            addOperationTitleForError = function() end })
            end,
            -- 启动异步任务：记录名字，但刻意不执行 fn（避免沙箱里弹对话框）
            postAsyncTaskWithContext = function(name, fn)
                started[#started + 1] = name
            end,
            -- yield-safe 受保护调用（真实 Lightroom 里会走 LrTasks.pcall）
            pcallWithContext = function(_, fn)
                return pcall(fn, { addCleanupHandler = function() end,
                                   addFailureHandler = function() end })
            end,
        },
        LrView = {
            osFactory = function() return nil end,
            bind = function(k) return k end,
        },
        LrApplicationView = {
            getCurrentModuleName = function() return "library" end,
            showDevelopModule = function() end,
        },
        LrDevelopController = { getRange = function() return 0, 1 end },
    }

    local sb = {
        _PLUGIN = { path = root },
        import = function(name)
            if name == "LrLogger" then
                return function()
                    return {
                        enable = function() end, trace = function() end,
                        debug = function() end, info = function() end,
                        warn = function() end, error = function() end,
                    }
                end
            end
            return imports[name]
        end,
        -- 与 Lightroom 一致的 Lua 标准环境子集（官方指南 p.19-20）
        assert = assert, error = error, getmetatable = getmetatable,
        ipairs = ipairs, load = load, loadfile = loadfile,
        loadstring = loadstring, next = next, pairs = pairs, pcall = pcall,
        rawequal = rawequal, rawget = rawget, rawset = rawset, select = select,
        setmetatable = setmetatable, tonumber = tonumber, tostring = tostring,
        type = type, unpack = unpack,
        string = string, table = table, math = math, io = io,
        os = { time = os.time, date = os.date, clock = os.clock },
        print = function() end,
        -- ★ 刻意不提供 package / module / getfenv / setfenv —— 与 Lightroom 一致
    }
        sb._G = sb

        -- 忠实模拟 Lightroom 的 loadstring 行为：
        --   Lua 5.1 的 loadstring 本身不会继承调用者的环境，新 chunk 会落在「全局环境」上。
        --   在 Lightroom 中那个全局环境就是插件的专属函数环境；
        --   沙箱里用 setfenv 把新 chunk 挂到 sb 上，来复现这一点。
        local realLoadstring = loadstring
        sb.loadstring = function(src, chunkname)
            local f, err = realLoadstring(src, chunkname)
            if f then setfenv(f, sb) end
            return f, err
        end
        -- 刻意不提供 setfenv / getfenv / package / module —— 与 Lightroom 一致（官方 p.19）

        return sb
    end

-- 不依赖 setfenv 的那条，任何时候都跑
T.case("Main.lua 源码不引用 package / module / getfenv / setfenv", function()
    local text = Utils.platform.readFile(root .. "/Main.lua")
    T.truthy(text ~= nil, "读不到 Main.lua")

    -- 先剥掉块注释与行注释，只检查真实代码
    local code = text:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

    for _, bad in ipairs({ "package", "getfenv", "setfenv", "module(" }) do
        T.falsy(code:find(bad, 1, true) ~= nil,
            "Main.lua 的代码里不应出现 " .. bad .. "（Lightroom 不提供）")
    end
end)

if type(setfenv) ~= "function" then
    -- Lua 5.2+ 移除了 setfenv，无法构造沙箱。
    -- 目标运行时是 Lua 5.1（Lightroom 内嵌版本），因此这里只是提示而不是失败。
    local note = "  [skip] 当前 Lua (" .. tostring(_VERSION) ..
        ") 没有 setfenv，跳过「沙箱端到端执行 Main.lua」用例（请在 Lua 5.1 上运行以覆盖）"
    print(note)
    T.lines[#T.lines + 1] = note
else
    T.case("Main.lua 在无 package 的沙箱中能完整加载全部模块", function()
        local started = {}
        local sb = buildSandbox(started)

        local chunk, lerr = loadfile(root .. "/Main.lua")
        T.truthy(chunk ~= nil, "loadfile Main.lua 失败: " .. tostring(lerr))
        setfenv(chunk, sb)

        local ok, err = pcall(chunk)
        T.truthy(ok, "Main.lua 执行失败: " .. tostring(err))

        -- 加载器必须已挂到插件全局上
        local host = sb.AI_COLOR_IMPORTER
        T.isTable(host, "Main.lua 应挂载 AI_COLOR_IMPORTER 全局")
        T.eq(type(host.load), "function", "AI_COLOR_IMPORTER.load 应是函数")

        -- 全部模块都应加载成功
        -- 注意：Loader.isCached / loadedPaths / loadedCount 是「函数」不是「方法」，
        --       这里用 '.' 调用（用 ':' 会把 Loader 表当成第一个参数）
        -- 另注：src/Loader.lua 本身是由 Main.lua 的「自举」代码加载的，
        --       不经过 Loader 自己的缓存，因此不在此列表中。
        local expected = {
            "manifest.lua", "src/Utils.lua", "src/Logger.lua",
        }
        for _, p in ipairs(expected) do
            T.truthy(host.Loader.isCached(p), "应加载过 " .. p)
        end
        T.truthy(host.Loader.loadedCount() >= 3,
            "加载模块数偏少: " .. host.Loader.loadedCount())
        T.contains(table.concat(host.Loader.loadedPaths(), ","), "manifest.lua",
            "已加载列表里应有 manifest.lua")

        -- 加载进来的模块必须真的可用
        local U = host.load("src/Utils.lua")
        T.near(U.parseNumber("5600"), 5600, 1e-9, "Utils 应可用")
        T.truthy(U.platform.readFile ~= nil, "平台 readFile 应被注入")
        local text = U.platform.readFile(root .. "/tests/fixtures/basic.xmp")
        T.truthy(text ~= nil, "注入的 readFile 应能读到 XMP")

        -- 最后应启动异步任务（菜单点击后的主流程入口）
        T.eq(#started, 1, "应且仅应启动 1 个异步任务")
        T.eq(started[1], "AI Color Importer", "任务名")
    end)
end

----------------------------------------------------------------------
-- ★ yield-safe 受保护调用（本项目最重要的一个坑）★
--   Lightroom 的很多 SDK 调用会 yield；Lua 原生 pcall 是 C 函数，跨 C 边界
--   不允许 yield，包住它们会让调用全部失败并报
--   "Yielding is not allowed within a C or metamethod call"，
--   而且错误还会被 pcall 吞掉。
--   正确做法：Utils.safeCall（内部走 LrFunctionContext.pcallWithContext）。
----------------------------------------------------------------------
T.suite("yield-safe 调用纪律")

T.case("Utils.safeCall 返回与 pcall 一致的 (ok, ...)", function()
    local ok, v = Utils.safeCall("t", function() return 42 end)
    T.eq(ok, true, "成功时 ok 应为 true")
    T.eq(v, 42, "应取到返回值")

    local ok2, err = Utils.safeCall("t", function() error("炸了", 0) end)
    T.eq(ok2, false, "失败时 ok 应为 false")
    T.contains(tostring(err), "炸了", "应取到错误信息")

    local ok3, a, b = Utils.safeCall("t", function() return 1, 2 end)
    T.eq(ok3, true); T.eq(a, 1); T.eq(b, 2, "应透传多个返回值")
end)

T.case("非 Lightroom 环境下 safeCall 退回标准 pcall，lrImport 返回 nil", function()
    T.falsy(Utils.hasYieldSafeCall(),
        "测试环境没有 LrFunctionContext，应报告不具备 yield-safe 能力")
    T.eq(Utils.lrImport("LrPhoto"), nil, "非 Lightroom 环境应返回 nil")
end)

T.case("SDK 数据路径文件里不得出现原生 pcall 包住 SDK 调用", function()
    -- 这些文件会调用 yield 型 SDK 接口（元数据读取 / 目录写入 / sleep 等），
    -- 因此一律使用 Utils.safeCall，绝不能用裸的 pcall(function ... end)。
    -- （Main.lua 与 Logger.lua 例外：它们只用 LrFileUtils / LrLogger 等
    --   已实测不会 yield 的接口，那里保留原生 pcall 是安全的。）
    local GUARDED = {
        "src/PhotoResolver.lua",
        "src/ApplyDevelop.lua",
        "ui/ImportDialog.lua",
        "ui/ProgressDialog.lua",
    }

    for _, rel in ipairs(GUARDED) do
        local text = Utils.platform.readFile(root .. "/" .. rel)
        T.truthy(text ~= nil, "读不到 " .. rel)
        -- 剥掉块注释与行注释，只看真实代码
        local code = text:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
        T.falsy(code:find("pcall(function", 1, true) ~= nil,
            rel .. " 出现了 pcall(function ... ) —— 会掐死 yield 型 SDK 调用；" ..
            "请改用 Utils.safeCall")
    end
end)

T.case("Utils.safeCall 的签名在 Lightroom 环境下会走 pcallWithContext", function()
    -- 用沙箱验证：Lightroom 环境下 safeCall 必须调用 LrFunctionContext.pcallWithContext
    local called = false
    local realImport = _G.import
    local ok, safeOk, probeOk, probeVal

    _G.import = function(name)
        if name == "LrFunctionContext" then
            return {
                pcallWithContext = function(cname, fn)
                    called = true
                    return pcall(fn)
                end,
            }
        end
        return nil
    end

    -- 先取结果，再恢复全局，最后断言 —— 保证断言失败也不会污染其它用例
    ok = pcall(function()
        local L2 = Loader.new()
        L2:configure {
            root = root,
            readSource = function(rel) return Utils.platform.readFile(root .. "/" .. rel) end,
        }
        local saved = AI_COLOR_IMPORTER
        AI_COLOR_IMPORTER = { root = root, load = function(p) return L2:load(p) end }
        local U2 = L2:load("src/Utils.lua")
        safeOk = U2.hasYieldSafeCall()
        probeOk, probeVal = U2.safeCall("probe", function() return 7 end)
        AI_COLOR_IMPORTER = saved
    end)

    _G.import = realImport

    T.truthy(ok, "探测过程本身不应报错")
    T.truthy(safeOk, "沙箱下 Utils 应识别出 yield-safe 能力")
    T.truthy(called, "safeCall 必须经由 LrFunctionContext.pcallWithContext")
    T.eq(probeOk, true, "safeCall 的第一个返回值应是成功标志")
    T.eq(probeVal, 7, "应取到被调用函数的返回值")
end)

----------------------------------------------------------------------
-- 业务测试
----------------------------------------------------------------------
require "test_XmpParser"
require "test_XmpMapping"
require "test_Validation"
require "test_ApplyEngine"
require "test_Json"
require "test_JobRunner"

----------------------------------------------------------------------
-- 收尾
----------------------------------------------------------------------
local ok = T.report()
T.writeReport(root .. "/tests/.last-run.log")

if type(os) == "table" and type(os.exit) == "function" then
    os.exit(ok and 0 or 1)
end
