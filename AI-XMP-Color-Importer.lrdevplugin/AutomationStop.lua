--[[
    AutomationStop.lua  —  菜单入口：停止自动化监听
--]]

local LrPathUtils, LrFileUtils = import "LrPathUtils", import "LrFileUtils"

local bootSource = LrFileUtils.readFile(LrPathUtils.child(_PLUGIN.path, "src/Boot.lua"))
if bootSource == nil then
    error("无法读取 src/Boot.lua —— 插件文件不完整？", 0)
end

local Boot = loadstring(bootSource, "@src/Boot.lua")()
local ctx  = Boot.prepare()

local LrDialogs = import "LrDialogs"
local Listener  = ctx.load("src/AutomationListener.lua")

if not Listener.isRunning() then
    LrDialogs.message("自动化未运行", Listener.statusText(), "info")
    return
end

local statusBefore = Listener.statusText()
Listener.stop()

LrDialogs.message("已请求停止自动化监听",
    statusBefore .. "\n\n后台循环会在下一次检查后退出。", "info")
