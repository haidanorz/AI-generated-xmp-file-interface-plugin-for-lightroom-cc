--[[
    tests/test_JobRunner.lua  —  自动化队列与监听器

    重点：
      · job 的校验（缺字段、坏 JSON、超上限）必须明确拒绝，不能"猜"
      · 处理失败时也要写结果 + 归档，不能把 job 留在 inbox 里反复重试
      · 监听器的启停状态机（手动开启，不自动运行）
--]]

local T             = require "framework"
local Utils         = require "Utils"
local Logger        = require "Logger"
local Json          = require "Json"
local JobRunner     = require "JobRunner"
local Listener      = require "AutomationListener"

Logger.configure { level = "error", echo = false }

local FX       = T.root .. "/tests/fixtures"
local QUEUE    = T.root .. "/tests/.tmp-queue"
local BASIC_XMP = FX .. "/basic.xmp"

local function jobFile(name, data)
    JobRunner.ensureDirs()
    local path = Utils.platform.joinPath(JobRunner.paths().inbox, name)
    local text = (type(data) == "string") and data or Json.encode(data)
    local ok, err = Utils.platform.writeFile(path, text)
    if not ok then
        error("写测试 job 失败: " .. tostring(err), 0)
    end
    return path
end

local function readResult(id)
    local path = JobRunner.resultPath(id)
    local text = Utils.platform.readFile(path)
    if not text then return nil end
    return Json.decode(text)
end

----------------------------------------------------------------------

T.suite("JobRunner / 目录与扫描")

T.case("默认队列目录在插件下，可被覆盖", function()
    JobRunner.setQueueDir(nil)
    T.contains(JobRunner.defaultQueueDir(), "queue", "默认目录应叫 queue")

    JobRunner.setQueueDir(QUEUE)
    local p = JobRunner.paths()
    T.eq(p.root, QUEUE)
    T.contains(p.inbox, "inbox")
    T.contains(p.results, "results")
    T.contains(p.archive, "archive")
    JobRunner.setQueueDir(nil)
end)

T.case("ensureDirs 建出三个子目录", function()
    JobRunner.setQueueDir(QUEUE)
    JobRunner.ensureDirs()
    Logger.configure { level = "error", echo = false }

    -- 各写一个文件，验证目录确实可写
    local p = JobRunner.paths()
    for _, dir in ipairs({ p.inbox, p.results, p.archive }) do
        local probe = Utils.platform.joinPath(dir, ".probe")
        local ok, err = Utils.platform.writeFile(probe, "x")
        T.truthy(ok, "目录写不进去: " .. dir .. " (" .. tostring(err) .. ")")
        Utils.platform.deleteFile(probe)
    end
end)

T.case("listPending 只挑 .json", function()
    local p = JobRunner.paths()
    Utils.platform.writeFile(Utils.platform.joinPath(p.inbox, "a.json"), "{}")
    Utils.platform.writeFile(Utils.platform.joinPath(p.inbox, "b.txt"), "not a job")

    local found = {}
    for _, path in ipairs(JobRunner.listPending()) do
        found[Utils.basename(path)] = true
    end
    T.truthy(found["a.json"], "应扫到 .json")
    T.falsy(found["b.txt"], "不应扫到 .txt")

    Utils.platform.deleteFile(Utils.platform.joinPath(p.inbox, "a.json"))
    Utils.platform.deleteFile(Utils.platform.joinPath(p.inbox, "b.txt"))
end)

----------------------------------------------------------------------

T.suite("JobRunner / parseJob 校验")

T.case("合法 job（含缺省 id 用文件名）", function()
    local path = jobFile("job-1.json", {
        xmp = BASIC_XMP, photos = { "D:/p/IMG_1.CR3" },
    })
    local job, err = JobRunner.parseJob(path)
    T.truthy(job ~= nil, "应解析成功: " .. tostring(err))
    T.eq(job.id, "job-1", "缺省 id 应取文件名")
    T.eq(job.xmp, BASIC_XMP)
    T.eq(#job.photos, 1)
    Utils.platform.deleteFile(path)
end)

T.case("缺 xmp / 缺 photos / photos 为空 → 拒绝", function()
    local cases = {
        { { photos = { "a" } },          "缺少 xmp" },
        { { xmp = "a.xmp" },             "缺少 photos" },
        { { xmp = "a.xmp", photos = {} }, "缺少 photos" },
    }
    for i, c in ipairs(cases) do
        local path = jobFile("bad-" .. i .. ".json", c[1])
        local job, err = JobRunner.parseJob(path)
        T.eq(job, nil, "应拒绝")
        T.contains(tostring(err), c[2], "错误信息应说明原因")
        Utils.platform.deleteFile(path)
    end
end)

T.case("坏 JSON / 非对象 → 拒绝", function()
    local p1 = jobFile("broken.json", '{ "xmp": ')
    local j1, e1 = JobRunner.parseJob(p1)
    T.eq(j1, nil)
    T.truthy(type(e1) == "string" and #e1 > 0)
    Utils.platform.deleteFile(p1)

    local p2 = jobFile("notobj.json", '[1,2,3]')
    local j2, e2 = JobRunner.parseJob(p2)
    T.eq(j2, nil)
    T.contains(tostring(e2), "JSON 对象")
    Utils.platform.deleteFile(p2)
end)

T.case("photos 里有非字符串 → 拒绝并指出下标", function()
    local path = jobFile("badtype.json", { xmp = BASIC_XMP, photos = { 123 } })
    local job, err = JobRunner.parseJob(path)
    T.eq(job, nil)
    T.contains(tostring(err), "photos[1]")
    Utils.platform.deleteFile(path)
end)

T.case("照片数超过安全上限 → 拒绝", function()
    local photos = {}
    for i = 1, JobRunner.MAX_PHOTOS_PER_JOB + 1 do
        photos[i] = "D:/p/" .. i .. ".CR3"
    end
    local path = jobFile("toomany.json", { xmp = BASIC_XMP, photos = photos })
    local job, err = JobRunner.parseJob(path)
    T.eq(job, nil, "应拒绝超上限的 job")
    T.contains(tostring(err), "最多")
    Utils.platform.deleteFile(path)
end)

----------------------------------------------------------------------

T.suite("JobRunner / 处理与落盘")

T.case("找不到照片时：逐张记错、整 job 失败、结果照写、job 归档", function()
    local path = jobFile("resolve-fail.json", {
        id   = "rf-1",
        xmp  = BASIC_XMP,
        photos = { "D:/photos/IMG_1.CR3", "D:/photos/IMG_2.CR3" },
        options = { dryRun = true },
    })

    local ok = JobRunner.processOne(path, nil)
    T.falsy(ok, "找不到照片应视为失败")

    local result = readResult("rf-1")
    T.truthy(result ~= nil, "结果文件应该写出来")
    T.eq(result.ok, false)
    T.eq(result.dryRun, true, "应回显 dryRun")
    T.eq(#result.photos, 2, "每张照片都应有条目")
    T.eq(result.photos[1].stage, "resolve", "应停在解析照片阶段")
    T.truthy(result.photos[1].message ~= nil, "应说明原因")
    T.eq(result.counts.photos, 2)
    T.eq(result.counts.failed, 2)
    T.eq(result.counts.ok, 0)

    -- job 不该留在 inbox
    T.falsy(Utils.platform.fileExists(path), "job 应被移走")
    local archived = Utils.platform.joinPath(JobRunner.paths().archive, "failed-resolve-fail.json")
    T.truthy(Utils.platform.fileExists(archived), "失败件应加 failed- 前缀归档")
end)

T.case("XMP 不存在时：整 job 在 analyze 阶段失败", function()
    local path = jobFile("bad-xmp.json", {
        id = "bx-1", xmp = FX .. "/__没有这个文件__.xmp", photos = { "D:/p/a.CR3" },
    })
    local ok = JobRunner.processOne(path, nil)
    T.falsy(ok)

    local result = readResult("bx-1")
    T.truthy(result ~= nil)
    T.eq(result.ok, false)
    T.eq(result.stage, "analyze", "应停在分析阶段")
    T.contains(tostring(result.message), "XMP")
    T.eq(#result.photos, 0, "分析失败时不应逐张处理")
end)

T.case("坏 job 也会写结果并归档（避免在 inbox 里反复重试）", function()
    local path = jobFile("broken2.json", '{oops')
    local ok, err = JobRunner.processOne(path, nil)
    T.falsy(ok)
    T.truthy(err ~= nil)

    local result = readResult("broken2")
    T.truthy(result ~= nil, "解析失败也要写结果")
    T.eq(result.stage, "parse")
    T.eq(result.ok, false)

    T.falsy(Utils.platform.fileExists(path), "坏 job 也应被移出 inbox")
end)

T.case("processAll 汇总统计", function()
    local p = JobRunner.paths()
    -- 清空 inbox 里的历史文件
    for _, f in ipairs(Utils.platform.listFiles(p.inbox)) do
        Utils.platform.deleteFile(f)
    end

    jobFile("s1.json", { id = "s1", xmp = BASIC_XMP, photos = { "D:/p/a.CR3" } })
    jobFile("s2.json", { id = "s2", xmp = FX .. "/__无__.xmp", photos = { "D:/p/b.CR3" } })

    local summary = JobRunner.processAll(nil)
    T.eq(summary.jobs, 2, "应处理 2 个 job")
    T.eq(summary.failed, 2, "两个都失败（测试环境没有目录）")
    T.eq(summary.ok, 0)
end)


T.case("归档失败时兜底删除，避免 job 留在 inbox 被反复处理", function()
    JobRunner.setQueueDir(QUEUE)
    JobRunner.ensureDirs()
    local path = jobFile("stuck.json", { xmp = BASIC_XMP, photos = { "D:/p/a.CR3" } })
    T.truthy(Utils.platform.fileExists(path), "前置：job 应已写入")

    local savedWrite  = Utils.platform.writeFile
    local savedDelete = Utils.platform.deleteFile
    local deleteCalled = false

    -- 归档 = 读 + 写 + 删；这里让「写」失败
    Utils.platform.writeFile = function() return nil, "模拟写失败" end
    Utils.platform.deleteFile = function(p)
        deleteCalled = true
        return savedDelete(p)
    end

    local okRun, archived = pcall(JobRunner.archiveJob, path, true)

    Utils.platform.writeFile  = savedWrite
    Utils.platform.deleteFile = savedDelete

    T.truthy(okRun, "archiveJob 不应抛错")
    T.falsy(archived, "归档应报告失败")
    T.truthy(deleteCalled, "应尝试兜底删除")
    T.falsy(Utils.platform.fileExists(path), "job 不应还留在 inbox 里")
end)

T.case("归档彻底失败时不会每秒重复处理同一个 job", function()
    JobRunner.setQueueDir(QUEUE)
    JobRunner.ensureDirs()
    JobRunner._resetProcessed()

    local p = JobRunner.paths()
    for _, f in ipairs(Utils.platform.listFiles(p.inbox)) do
        Utils.platform.deleteFile(f)
    end

    local path = jobFile("dup.json", { id = "dup", xmp = BASIC_XMP, photos = { "D:/p/a.CR3" } })

    local savedWrite  = Utils.platform.writeFile
    local savedDelete = Utils.platform.deleteFile
    Utils.platform.writeFile  = function() return nil, "模拟写失败" end
    Utils.platform.deleteFile = function() return false end   -- 连删除也失败

    local first  = JobRunner.processAll(nil)
    local second = JobRunner.processAll(nil)

    Utils.platform.writeFile  = savedWrite
    Utils.platform.deleteFile = savedDelete

    T.eq(first.jobs, 1, "第一次应处理")
    T.eq(second.jobs, 0, "第二次不应重复处理")
    T.eq(second.alreadyProcessed, 1, "应被识别为已处理")
    T.truthy(Utils.platform.fileExists(path), "模拟归档失败，job 应仍在")

    Utils.platform.deleteFile(path)
    JobRunner._resetProcessed()
end)

----------------------------------------------------------------------

T.suite("PhotoResolver / 按路径定位（自动化入口的健壮性）")

local PhotoResolver = require "PhotoResolver"

local BS = string.char(92)   -- 反斜杠，避免在源码里写一堆转义

--- 造一个假目录：exact 是「精确匹配表」，byName 是 findPhotos 的返回值
local function fakeCatalog(exact, byName)
    return {
        findPhotoByPath = function(_, p)
            return (exact or {})[p]
        end,
        findPhotos = function()
            return byName or {}
        end,
    }
end

local function fakePhoto(path)
    return {
        getRawMetadata = function(_, key)
            if key == "path" then return path end
            return nil
        end,
    }
end

T.case("原样命中", function()
    local photo = fakePhoto("C:/p/a.CR3")
    local got, err = PhotoResolver.findByPath("C:/p/a.CR3",
        fakeCatalog({ ["C:/p/a.CR3"] = photo }))
    T.truthy(got ~= nil, "应命中: " .. tostring(err))
    T.truthy(rawequal(got, photo))
end)

T.case("正斜杠写成反斜杠也能命中（目录里存的是反斜杠）", function()
    -- 只有反斜杠形态能命中，正斜杠形态查不到
    local backPath = "C:" .. BS .. "p" .. BS .. "a.CR3"
    local photo = fakePhoto(backPath)
    local got, err = PhotoResolver.findByPath("C:/p/a.CR3",
        fakeCatalog({ [backPath] = photo }))
    T.truthy(got ~= nil, "应通过换分隔符命中: " .. tostring(err))
end)

T.case("大小写不同也能命中（按文件名搜 + 比路径兜底）", function()
    local upperPath = "C:" .. BS .. "P" .. BS .. "A.CR3"
    local photo = fakePhoto(upperPath)
    local got, err = PhotoResolver.findByPath("c:/p/a.CR3",
        fakeCatalog(nil, { photo }))
    T.truthy(got ~= nil, "应通过兜底命中: " .. tostring(err))
end)

T.case("同名但路径不同 → 明确报错指出同名数量", function()
    local other = fakePhoto("C:" .. BS .. "other" .. BS .. "a.CR3")
    local got, err = PhotoResolver.findByPath("C:/p/a.CR3",
        fakeCatalog(nil, { other }))
    T.eq(got, nil, "不应命中别的同名照片")
    T.contains(tostring(err), "同名")
end)

T.case("完全找不到 → 可读错误", function()
    local got, err = PhotoResolver.findByPath("C:/p/missing.CR3", fakeCatalog(nil, {}))
    T.eq(got, nil)
    T.contains(tostring(err), "找不到")
end)

T.case("空路径 → 直接拒绝", function()
    local got, err = PhotoResolver.findByPath("", fakeCatalog())
    T.eq(got, nil)
    T.contains(tostring(err), "路径为空")
end)

T.case("normalizeForCompare 归一化分隔符与大小写", function()
    T.eq(PhotoResolver.normalizeForCompare("C:" .. BS .. "A" .. BS .. "b.CR3"),
         PhotoResolver.normalizeForCompare("c:/a/B.cr3"))
end)

----------------------------------------------------------------------

T.suite("AutomationListener / 手动启停状态机")

T.case("初始未运行；begin 之后进入运行态", function()
    Listener._reset()
    T.falsy(Listener.isRunning(), "默认不应运行")

    local ok, err = Listener.begin { interval = 2, queueDir = QUEUE }
    T.truthy(ok, "应能启动: " .. tostring(err))
    T.truthy(Listener.isRunning())
    T.near(Listener.getInterval(), 2)

    T.contains(Listener.statusText(), "运行中")
    Listener.halt()
    T.falsy(Listener.isRunning(), "halt 后应停止")
end)

T.case("重复 begin 会被拒绝（避免起两个轮询）", function()
    Listener._reset()
    Listener.begin { queueDir = QUEUE }
    local ok, err = Listener.begin { queueDir = QUEUE }
    T.falsy(ok, "第二次应失败")
    T.contains(tostring(err), "已经在运行")
    Listener.halt()
end)

T.case("间隔被钳制在 0.5 ~ 60 秒", function()
    Listener._reset()
    Listener.begin { interval = 0.01, queueDir = QUEUE }
    T.near(Listener.getInterval(), 0.5, 1e-9, "过小应抬到 0.5")
    Listener.halt()

    Listener._reset()
    Listener.begin { interval = 9999, queueDir = QUEUE }
    T.near(Listener.getInterval(), 60, 1e-9, "过大应压到 60")
    Listener.halt()
end)

T.case("未运行时 tick 不做任何事", function()
    Listener._reset()
    local summary = Listener.tick()
    T.eq(summary.jobs, 0)
    T.truthy(summary.notRunning, "应标记未运行")
end)

T.case("运行中 tick 会处理 inbox", function()
    Listener._reset()
    local p = JobRunner.paths()
    for _, f in ipairs(Utils.platform.listFiles(p.inbox)) do
        Utils.platform.deleteFile(f)
    end

    jobFile("t1.json", { id = "t1", xmp = BASIC_XMP, photos = { "D:/p/a.CR3" } })

    Listener.begin { interval = 1, queueDir = QUEUE }
    local summary = Listener.tick()
    Listener.halt()

    T.eq(summary.jobs, 1, "应处理 1 个 job")
    T.contains(Listener.statusText(), "已停止")
end)

T.case("start 在非 Lightroom 环境明确失败（不能用 LrTasks）", function()
    Listener._reset()
    local ok, err = Listener.start { queueDir = QUEUE }
    T.falsy(ok, "测试环境没有 LrTasks，应失败")
    T.contains(tostring(err), "LrTasks")
    T.falsy(Listener.isRunning(), "失败后不应留在运行态")
end)

----------------------------------------------------------------------

T.suite("Diagnostics / 自检报告（日志看不到时的唯一出口）")

local Diagnostics = require "Diagnostics"

T.case("collect 覆盖关键段落，且文件自检能跑通", function()
    JobRunner.setQueueDir(QUEUE)
    JobRunner.ensureDirs()

    local report = Diagnostics.collect { listener = Listener }

    T.contains(report, "诊断报告")
    T.contains(report, "[监听器]")
    T.contains(report, "[队列目录]")
    T.contains(report, "[文件操作自检]")
    T.contains(report, "writeFile:")
    T.contains(report, "archive(读写删)")
    T.contains(report, "deleteFile:")
    T.contains(report, "build", "应带上插件版本")
    T.contains(report, "OK", "自检至少应有一项通过")
end)

T.case("write 会落到 <队列>/status.txt", function()
    JobRunner.setQueueDir(QUEUE)
    local path = Diagnostics.write { listener = Listener }

    T.truthy(path ~= nil, "应写入成功")
    T.contains(path, "status.txt")
    T.truthy(Utils.platform.fileExists(path), "文件应存在")

    local back = Utils.platform.readFile(path)
    T.contains(back, "诊断报告", "内容应完整落盘")
    Utils.platform.deleteFile(path)
end)

return true
