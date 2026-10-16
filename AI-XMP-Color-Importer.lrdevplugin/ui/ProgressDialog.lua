--[[
    ui/ProgressDialog.lua  —  轻量进度提示

    只使用已核实的 API：
        LrDialogs.showBezel( message, fadeDelay )     SDK 5.0+
            「在一个会快速淡出的窗口中显示一条消息。」fadeDelay 默认 1.2 秒。
            「在任何给定时间只会有一个 bezel 可见。」

    为什么不用 showModalProgressDialog？
        它需要 LrFunctionContext + LrProgressScope 配合，并且会阻塞整个 Lightroom UI。
        本插件的操作（读一个几十 KB 的 XMP + 一次目录写入）通常在 1 秒内完成，
        用 bezel 更合适，失败面也更小。
        若将来需要长任务，可在此基础上接入 showModalProgressDialog。

    所有调用都包 pcall —— 进度提示失败绝不能影响业务流程。
--]]

local pcallImport = function(name)
    if type(import) ~= "function" then return nil end
    -- import 本身不会 yield，原生 pcall 安全
    local ok, mod = pcall(import, name)
    if ok then return mod end
    return nil
end

local LrDialogs = pcallImport("LrDialogs")

-- 依赖统一从插件加载器获取
local Utils = AI_COLOR_IMPORTER.load("src/Utils.lua")

local ProgressDialog = {}

--- 显示一条会淡出的提示
-- @param message string
-- @param seconds number|nil 默认 1.5
function ProgressDialog.bezel(message, seconds)
    if LrDialogs == nil then
        return
    end
    -- showBezel 是 UI 调用，用 yield-safe 的安全调用
    Utils.safeCall("ai-color-bezel", function()
        LrDialogs.showBezel(message, seconds or 1.5)
    end)
end

--- 开始一次操作前的提示
function ProgressDialog.working(message)
    ProgressDialog.bezel(message or "正在处理…", 3.0)
end

--- 完成提示
function ProgressDialog.done(message)
    ProgressDialog.bezel(message or "完成", 1.2)
end

--- 把一段操作包在「工作中 / 完成」提示里
--  ★ 受保护调用用 Utils.safeCall 而不是原生 pcall：
--    fn 里可能包含 yield 型 SDK 调用（例如 LrDevelopController.getRange、
--    照片元数据读取），原生 pcall 会让它们直接失败。
-- @param workingMessage string
-- @param fn function 会被调用一次
-- @return fn 的多个返回值
function ProgressDialog.wrap(workingMessage, fn)
    ProgressDialog.working(workingMessage)

    local ok, a, b, c, d = Utils.safeCall("ai-color-progress", fn)

    if ok then
        ProgressDialog.done()
    else
        ProgressDialog.done("操作失败")
        error(a, 0)
    end

    return a, b, c, d
end

return ProgressDialog
