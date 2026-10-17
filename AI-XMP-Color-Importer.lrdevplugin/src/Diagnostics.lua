--[[
    src/Diagnostics.lua  —  自检报告（写完就有一个 txt 可以看，不依赖日志文件）

    为什么需要它：
        LrLogger 的 "logfile" 在某些环境下并不会真的落盘（实测没有生成
        Lightroom Logs 目录），所以出问题时用户没有任何地方能看到原因。
        这里改成：把所有状态 + 一次真实的文件操作自检 + 内存里的日志，
        汇总成一份纯文本，用我已经验证可用的 io 写文件落到队列目录里。

    自检部分会真的去 move / delete 一个临时文件 —— 因为之前出现过
    「结果写得出来、但归档静默失败」这种半死不活的情况，只有真做一遍才知道。
--]]

local Utils     = AI_COLOR_IMPORTER.load("src/Utils.lua")
local Logger    = AI_COLOR_IMPORTER.load("src/Logger.lua")
local Manifest  = AI_COLOR_IMPORTER.load("manifest.lua")

local Diagnostics = {}

local function line(label, value)
    return string.format("%-14s %s", label .. ":", tostring(value))
end

----------------------------------------------------------------------
-- 单项检查
----------------------------------------------------------------------

local function checkWrite(dir)
    local probe = Utils.platform.joinPath(dir, ".selftest-write.txt")
    local ok, err = Utils.platform.writeFile(probe, "selftest")
    if not ok then
        return "FAILED  " .. tostring(err)
    end
    local content = Utils.platform.readFile(probe)
    Utils.platform.deleteFile(probe)
    if content ~= "selftest" then
        return "FAILED  写进去的内容读回来不一致"
    end
    return "OK"
end

local function checkList(dir)
    local files = Utils.platform.listFiles(dir)
    if type(files) ~= "table" then
        return "FAILED  返回了非表"
    end
    return string.format("OK（%d 项）", #files)
end

--- 真正做一次 move：这是之前静默失败的那一步
local function checkMove(fromDir, toDir)
    local src  = Utils.platform.joinPath(fromDir, ".selftest-move.txt")
    local dest = Utils.platform.joinPath(toDir, ".selftest-move.txt")

    local okW, wErr = Utils.platform.writeFile(src, "move-test")
    if not okW then
        return "SKIPPED  源文件写不出来：" .. tostring(wErr)
    end

    if Utils.platform.fileExists(dest) then
        Utils.platform.deleteFile(dest)
    end

    local okM, mErr = Utils.platform.moveFile(src, dest)

    local movedShowsUp = Utils.platform.fileExists(dest)
    local srcGone      = not Utils.platform.fileExists(src)

    -- 清理现场（两种可能的残留都清掉）
    if movedShowsUp then Utils.platform.deleteFile(dest) end
    if not srcGone  then Utils.platform.deleteFile(src)  end

    if not okM then
        return "FAILED  " .. tostring(mErr)
    end
    if not movedShowsUp then
        return "FAILED  move 报告成功，但目标位置没有文件"
    end
    if not srcGone then
        return "FAILED  move 报告成功，但源文件仍在"
    end
    return "OK"
end

local function checkDelete(dir)
    local probe = Utils.platform.joinPath(dir, ".selftest-del.txt")
    local okW = Utils.platform.writeFile(probe, "x")
    if not okW then
        return "SKIPPED  源文件写不出来"
    end
    local ok = Utils.platform.deleteFile and Utils.platform.deleteFile(probe)
    if not ok then
        return "FAILED  deleteFile 返回 false"
    end
    if Utils.platform.fileExists(probe) then
        return "FAILED  deleteFile 之后文件还在"
    end
    return "OK"
end

----------------------------------------------------------------------
-- 汇总
----------------------------------------------------------------------

--- 生成诊断报告
-- @param opts table|nil { queueDir = string, listener = table }
-- @return reportString
function Diagnostics.collect(opts)
    opts = opts or {}
    local lines = {}

    local function add(s) lines[#lines + 1] = s or "" end

    local now = Utils.platform.now and Utils.platform.now() or 0
    local stamp = Utils.timestamp(now)

    add("AI Color Importer — 诊断报告")
    add(string.rep("=", 60))
    add(line("生成时间", stamp))
    add(line("插件版本", string.format("%s (build %s)",
        tostring(Manifest.pluginVersionText),
        tostring(Manifest.pluginVersion and Manifest.pluginVersion.build))))
    add(line("插件目录", tostring(AI_COLOR_IMPORTER.root)))
    add(line("Lua", tostring(_VERSION)))

    ----------------------------------------------------------------
    -- 监听器
    ----------------------------------------------------------------
    add("")
    add("[监听器]")
    local listener = opts.listener
    if listener then
        add(line("是否运行", tostring(listener.isRunning())))
        add(line("轮询间隔", tostring(listener.getInterval()) .. " 秒"))
        local okS, status = Utils.safeCall("ai-color-diag-status", function()
            return listener.statusText()
        end)
        if okS then
            for s in tostring(status):gmatch("[^\n]+") do add("  " .. s) end
        end
    else
        add(line("是否运行", "（未加载监听器）"))
    end

    ----------------------------------------------------------------
    -- 目录
    ----------------------------------------------------------------
    add("")
    add("[队列目录]")
    local JobRunner = AI_COLOR_IMPORTER.load("src/JobRunner.lua")
    local p = JobRunner.paths()
    add(line("根目录", tostring(p.root)))
    for _, name in ipairs({ "root", "inbox", "results", "archive" }) do
        local dir = p[name]
        local exists = Utils.platform.fileExists(dir)
        local files = exists and Utils.platform.listFiles(dir) or {}
        add(string.format("  %-8s %s  (%d 个文件)", name,
            exists and "存在" or "不存在", #files))
        if name ~= "root" and #files > 0 and #files <= 8 then
            for _, f in ipairs(files) do
                add("           - " .. Utils.basename(f))
            end
        end
    end

    ----------------------------------------------------------------
    -- 文件操作自检（关键：move 到底行不行）
    ----------------------------------------------------------------
    add("")
    add("[文件操作自检]")
    add(line("writeFile", checkWrite(p.inbox)))
    add(line("listFiles", checkList(p.inbox)))
    add(line("move→archive", checkMove(p.inbox, p.archive)))
    add(line("deleteFile", checkDelete(p.inbox)))
    add(line("yield-safe pcall", tostring(Utils.hasYieldSafeCall())))

    ----------------------------------------------------------------
    -- 最近日志
    ----------------------------------------------------------------
    add("")
    add("[最近日志]")
    local okD, dump = Utils.safeCall("ai-color-diag-dump", function()
        return Logger.dump(200)
    end)
    if okD and type(dump) == "string" and dump ~= "" then
        for s in dump:gmatch("[^\n]+") do add("  " .. s) end
    else
        add("  （内存里没有日志）")
    end

    return table.concat(lines, "\n")
end

--- 生成并落盘，返回写入路径
-- @return path|nil, err
function Diagnostics.write(opts)
    opts = opts or {}
    local JobRunner = AI_COLOR_IMPORTER.load("src/JobRunner.lua")
    local dir = JobRunner.getQueueDir()
    if not Utils.platform.fileExists(dir) then
        Utils.platform.makeDirectory(dir)
    end
    local path = Utils.platform.joinPath(dir, "status.txt")
    local report = Diagnostics.collect(opts)
    local ok, err = Utils.platform.writeFile(path, report .. "\n")
    if not ok then
        return nil, err
    end
    return path, report
end

return Diagnostics
