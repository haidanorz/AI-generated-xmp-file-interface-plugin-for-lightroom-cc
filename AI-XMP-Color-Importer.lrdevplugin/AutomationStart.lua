--[[
    AutomationStart.lua  —  菜单入口：启动自动化监听

    由用户手动点击才启动（不随插件加载自动运行）。启动后每 N 秒检查一次队列目录的
    inbox/ 子目录，处理其中所有 *.json 的 job。
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

if Listener.isRunning() then
    LrDialogs.message("自动化已在运行", Listener.statusText(), "info")
    return
end

local ok, err = Listener.start { interval = 1.0 }

if ok then
    LrDialogs.message("自动化监听已启动", Listener.statusText() ..
        "\n\n把 job.json 放进队列的 inbox/ 目录即可；" ..
        "结果会写到 results/<id>.json，处理完的 job 归档到 archive/。" ..
        "\n\n要停止请点菜单「AI Color: Stop Automation Listener」。", "info")
else
    LrDialogs.message("无法启动自动化监听", tostring(err), "critical")
end
