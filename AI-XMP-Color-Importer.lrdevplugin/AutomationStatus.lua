--[[
    AutomationStatus.lua  —  菜单入口：诊断报告

    为什么单独做一个入口：
        LrLogger 的 logfile 在实测中并没有生成日志文件，出问题时用户无处可看。
        这个入口会把状态 + 一次真实的文件操作自检 + 内存里的日志，
        汇总写成 <队列目录>/status.txt，并把关键几行直接弹出来。
--]]

local LrPathUtils, LrFileUtils = import "LrPathUtils", import "LrFileUtils"

local bootSource = LrFileUtils.readFile(LrPathUtils.child(_PLUGIN.path, "src/Boot.lua"))
if bootSource == nil then
    error("无法读取 src/Boot.lua —— 插件文件不完整？", 0)
end

local Boot = loadstring(bootSource, "@src/Boot.lua")()
local ctx  = Boot.prepare()

local LrDialogs   = import "LrDialogs"
local Diagnostics = ctx.load("src/Diagnostics.lua")
local Listener    = ctx.load("src/AutomationListener.lua")

local path, reportOrErr = Diagnostics.write { listener = Listener }

if path == nil then
    LrDialogs.message("诊断报告写入失败",
        "无法写入队列目录：\n" .. tostring(reportOrErr) ..
        "\n\n这说明队列目录不可写 —— 自动化模式无法工作。", "critical")
    return
end

-- 只弹关键部分（版本 / 监听器 / 目录 / 自检），完整内容在 status.txt 里
local shown = {}
local count = 0
for s in tostring(reportOrErr):gmatch("[^\n]+") do
    count = count + 1
    if count > 22 then
        shown[#shown + 1] = "…"
        break
    end
    shown[#shown + 1] = s
end

LrDialogs.message("AI Color — 诊断报告",
    table.concat(shown, "\n") ..
    "\n\n完整报告（含最近 200 条日志）：\n" .. tostring(path), "info")
