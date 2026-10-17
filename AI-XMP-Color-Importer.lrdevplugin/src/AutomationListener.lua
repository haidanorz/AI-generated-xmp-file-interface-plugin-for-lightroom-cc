--[[
    src/AutomationListener.lua  —  自动化监听器（由用户手动开启，不随插件启动自动运行）

    设计约束（用户明确要求）：
        **不要用 LrInitPlugin 自动启动。** 必须由用户点菜单项显式开启，
        这样插件不会在用户不知情的情况下动照片。

    用法：
        AutomationListener.start{ interval = 1.0 }   -- 由菜单入口调用
        AutomationListener.stop()

    分工：
        · begin / halt / tick  纯状态与一轮处理（可单测，不依赖 LrTasks）
        · start / stop         额外负责后台任务与 sleep（只有 Lightroom 里能用）
--]]

local Utils     = AI_COLOR_IMPORTER.load("src/Utils.lua")
local Logger    = AI_COLOR_IMPORTER.load("src/Logger.lua")
local JobRunner = AI_COLOR_IMPORTER.load("src/JobRunner.lua")

local Listener = {}

local state = {
    running   = false,
    interval  = 1.0,
    startedAt = nil,
    lastTick  = nil,
    totalJobs = 0,
}

----------------------------------------------------------------------
-- 状态
----------------------------------------------------------------------

function Listener.isRunning()
    return state.running
end

function Listener.getInterval()
    return state.interval
end

--- 供界面/菜单显示的一句话状态
function Listener.statusText()
    local p = JobRunner.paths()
    if not state.running then
        return "状态：已停止\n队列目录：" .. tostring(p.root)
    end
    return string.format(
        "状态：运行中（每 %s 秒检查一次）\n队列目录：%s\n启动于：%s\n累计处理 job：%d\n上次检查：%s",
        tostring(state.interval), tostring(p.root),
        tostring(state.startedAt), state.totalJobs, tostring(state.lastTick or "尚未"))
end

----------------------------------------------------------------------
-- 启停（不含后台任务，便于测试）
----------------------------------------------------------------------

--- 进入运行状态并准备好队列目录
-- @param opts table|nil { interval = number, queueDir = string }
-- @return ok boolean, errString
function Listener.begin(opts)
    opts = opts or {}

    if state.running then
        return false, "自动化已经在运行中"
    end

    local interval = tonumber(opts.interval) or state.interval or 1.0
    if interval < 0.5 then interval = 0.5 end
    if interval > 60 then interval = 60 end

    if opts.queueDir ~= nil then
        JobRunner.setQueueDir(opts.queueDir)
    end

    local okDirs, dirErr = Utils.safeCall("ai-color-queue-dirs", function()
        return JobRunner.ensureDirs()
    end)
    if not okDirs then
        return false, "无法创建队列目录：" .. tostring(dirErr)
    end

    -- 写一个探针文件验证可写：宁可现在失败，也不要等第一个 job 才发现
    local p = JobRunner.paths()
    local probe = Utils.platform.joinPath(p.inbox, ".write-probe")
    local okW, werr = Utils.platform.writeFile(probe, "ok")
    if not okW then
        return false, string.format("队列目录不可写（%s）：%s", p.inbox, tostring(werr))
    end
    if Utils.platform.deleteFile then
        Utils.platform.deleteFile(probe)
    end

    state.running   = true
    state.interval  = interval
    state.startedAt = Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0)
    state.totalJobs = 0
    state.lastTick  = nil

    Logger.info("自动化监听已启动（队列：" .. tostring(p.root) .. "）",
        { operation = "AUTOMATION", result = "STARTED" })
    return true
end

--- 请求停止（后台循环会在下一次 tick 前退出）
function Listener.halt()
    if not state.running then
        return false
    end
    state.running = false
    Logger.info("自动化监听已请求停止", { operation = "AUTOMATION", result = "STOPPING" })
    return true
end

----------------------------------------------------------------------
-- 一轮处理
----------------------------------------------------------------------

--- 处理 inbox 里的全部 job（不做 sleep，可单测）
-- @return summary table { jobs, ok, failed }
function Listener.tick(opts)
    if not state.running then
        return { jobs = 0, ok = 0, failed = 0, notRunning = true }
    end

    local summary = JobRunner.processAll(opts)
    state.lastTick = Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0)
    if summary.jobs > 0 then
        state.totalJobs = state.totalJobs + summary.jobs
    end
    return summary
end

----------------------------------------------------------------------
-- 后台轮询（需要 LrTasks）
----------------------------------------------------------------------

--- 启动后台轮询任务
-- @return ok boolean, errString
function Listener.start(opts)
    if state.running then
        return false, "自动化已经在运行中"
    end

    local LrTasks = Utils.lrImport("LrTasks")
    if LrTasks == nil or type(LrTasks.startAsyncTask) ~= "function" then
        return false, "当前环境无法启动后台任务（LrTasks 不可用）"
    end

    local ok, err = Listener.begin(opts)
    if not ok then
        return false, err
    end

    LrTasks.startAsyncTask(function()
        while state.running do
            -- 单轮出错不能让整个监听停摆
            Utils.safeCall("ai-color-listener-tick", function()
                return Listener.tick()
            end)
            -- LrTasks.sleep 会 yield，必须直接调用（不能包在任何 pcall 里）
            LrTasks.sleep(state.interval)
        end
        Logger.info("自动化监听已停止（累计处理 " .. tostring(state.totalJobs) .. " 个 job）",
            { operation = "AUTOMATION", result = "STOPPED" })
    end, "AI Color Automation Listener")

    return true
end

function Listener.stop()
    return Listener.halt()
end

--- 仅供测试：重置状态
function Listener._reset()
    state.running   = false
    state.interval  = 1.0
    state.startedAt = nil
    state.lastTick  = nil
    state.totalJobs = 0
end

return Listener
