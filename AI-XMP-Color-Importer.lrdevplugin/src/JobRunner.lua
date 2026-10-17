--[[
    src/JobRunner.lua  —  自动化队列：读 job → 调 ApplyEngine → 写 result

    目录约定（默认在插件目录下的 queue/，可用 LrPrefs.queueDir 覆盖）：

        queue/
        ├── inbox/      ← 外部把 job.json 丢进来
        ├── results/    ← 每处理一个 job 写一份 <id>.json（成功失败都写）
        └── archive/    ← 处理完的 job 归档（失败的加 failed- 前缀）

    job.json：
        {
          "id":    "20261017-001",          // 可选，缺省用文件名
          "xmp":   "D:/xmp/natural-warm.xmp",   // 必填
          "photos": ["D:/photos/IMG_1.CR3"],    // 必填，绝对路径
          "options": {
            "applyExtendedFields": false,
            "dryRun": false,
            "verify": false,
            "policy": { "mismatch": "skip", "sidecar": "apply", "errors": "skip" }
          }
        }

    result（<id>.json）：
        { "id":..., "ok":..., "dryRun":..., "xmp":..., "photos":[ {...} ], "counts":{...} }
        每个 photo 条目可带 verify = { checked, mismatches, unverified, fields=[...], readError? }
        —— 读回校验（options.verify）的结果必须落到这里，因为 Lightroom 里没有可看的日志文件

    注意：
      · 一次只处理一个 job（写权限是全局锁，并发没有收益）
      · 单张照片失败不影响同 job 内其它照片；整 job 的 ok = 所有照片都 ok
      · 队列目录请放在纯 ASCII 路径下：Lightroom 没有写文件 API，落盘要走 Lua 的 io，
        而 Lua 5.1 在 Windows 的 io 受系统 ANSI 代码页限制
--]]

local Utils         = AI_COLOR_IMPORTER.load("src/Utils.lua")
local Logger        = AI_COLOR_IMPORTER.load("src/Logger.lua")
local Manifest      = AI_COLOR_IMPORTER.load("manifest.lua")
local Json          = AI_COLOR_IMPORTER.load("src/Json.lua")
local ApplyEngine   = AI_COLOR_IMPORTER.load("src/ApplyEngine.lua")
local PhotoResolver = AI_COLOR_IMPORTER.load("src/PhotoResolver.lua")

local JobRunner = {}

--- 单个 job 最多处理多少张照片（防止一条错误 job 批量毁图）
JobRunner.MAX_PHOTOS_PER_JOB = 50

local state = { queueDir = nil }

--- 已处理过的 job：path -> 文件大小
--   作用：如果归档失败（文件留在 inbox），不要每秒把它重新处理一遍。
--   内容变了（大小不同）则视为新的 job。
local processed = {}
local skipWarned = {}

--- 仅供测试：清空「已处理」记忆
function JobRunner._resetProcessed()
    processed = {}
    skipWarned = {}
end

----------------------------------------------------------------------
-- 路径
----------------------------------------------------------------------

--- 默认队列目录：<插件目录>/queue
function JobRunner.defaultQueueDir()
    return Utils.platform.joinPath(AI_COLOR_IMPORTER.root, "queue")
end

--- 覆盖队列目录（nil = 回到默认）
function JobRunner.setQueueDir(dir)
    state.queueDir = dir
end

function JobRunner.getQueueDir()
    return state.queueDir or JobRunner.defaultQueueDir()
end

function JobRunner.paths()
    local root = JobRunner.getQueueDir()
    return {
        root    = root,
        inbox   = Utils.platform.joinPath(root, "inbox"),
        results = Utils.platform.joinPath(root, "results"),
        archive = Utils.platform.joinPath(root, "archive"),
    }
end

--- 确保队列目录存在
function JobRunner.ensureDirs()
    local p = JobRunner.paths()
    local dirs = { p.root, p.inbox, p.results, p.archive }
    for _, d in ipairs(dirs) do
        if not Utils.platform.fileExists(d) then
            Utils.platform.makeDirectory(d)
        end
    end
    return true
end

--- 待处理的 job 文件（按文件名排序）
function JobRunner.listPending()
    local p = JobRunner.paths()
    local out = {}
    for _, path in ipairs(Utils.platform.listFiles(p.inbox)) do
        if path:lower():match("%.json$") then
            out[#out + 1] = path
        end
    end
    return out
end

----------------------------------------------------------------------
-- 解析
----------------------------------------------------------------------

--- 解析并校验一个 job 文件
-- @return job table|nil, errString
function JobRunner.parseJob(jobPath)
    local text, rerr = Utils.platform.readFile(jobPath)
    if not text then
        return nil, "读不到 job 文件：" .. tostring(rerr)
    end

    local data, derr = Json.decode(text)
    if data == nil then
        return nil, tostring(derr)
    end
    if type(data) ~= "table" then
        return nil, "job 必须是一个 JSON 对象"
    end
    if data[1] ~= nil then
        return nil, "job 必须是一个 JSON 对象（不能是数组）"
    end

    local job = {
        id      = data.id,
        xmp     = data.xmp,
        photos  = {},
        options = (type(data.options) == "table") and data.options or {},
        source  = jobPath,
    }

    if Utils.isBlank(job.id) then
        job.id = Utils.stripExtension(Utils.basename(jobPath))
    end
    if Utils.isBlank(job.xmp) then
        return nil, "job 缺少 xmp 字段"
    end
    if type(data.photos) ~= "table" or #data.photos == 0 then
        return nil, "job 缺少 photos（应为非空数组）"
    end

    for i, ph in ipairs(data.photos) do
        if type(ph) ~= "string" or ph == "" then
            return nil, string.format("photos[%d] 不是有效路径", i)
        end
        if #job.photos >= JobRunner.MAX_PHOTOS_PER_JOB then
            return nil, string.format("单个 job 最多 %d 张照片（安全上限）",
                JobRunner.MAX_PHOTOS_PER_JOB)
        end
        job.photos[#job.photos + 1] = ph
    end

    return job
end

----------------------------------------------------------------------
-- 处理
----------------------------------------------------------------------

--- 把 verify 摘要转成结果 JSON 里的形态
--   数组语义要保住：没有不一致时 fields 也要输出 []，而不是被编码成 null
function JobRunner.verifyForJson(summary)
    if type(summary) ~= "table" then
        return nil
    end

    local fields = Json.array({})
    for _, m in ipairs(summary.mismatches or {}) do
        fields[#fields + 1] = {
            field = m.field,
            want  = m.want,
            got   = m.got,
            note  = m.note,
        }
    end

    local out = {
        checked    = summary.checked or 0,
        mismatches = summary.mismatchCount or #fields,
        unverified = summary.unverified or 0,
        fields     = fields,
    }
    if summary.readError then
        out.readError = tostring(summary.readError)
    end
    return out
end

--- 把 ApplyEngine.apply 的 outcome 摊平进一个结果条目
--   单独拆出来是为了能在没有 Lightroom 的环境里单测；
--   之前这段内联在循环里，等于「结果 JSON 的字段」完全无法被测试覆盖。
function JobRunner.applyOutcomeToEntry(entry, outcome)
    entry.ok          = outcome.ok and true or false
    entry.stage       = outcome.stage
    entry.skipped     = outcome.skipped and true or false
    entry.message     = outcome.message
    entry.applied     = outcome.applied or 0
    entry.wouldApply  = outcome.wouldApply or 0
    entry.historyStep = outcome.historyName
    entry.errors      = (outcome.counts or {}).errors or 0
    entry.warnings    = (outcome.counts or {}).warnings or 0
    entry.verify      = JobRunner.verifyForJson(outcome.verifySummary)
    return entry
end

--- 处理一个已解析的 job
-- @param job table（parseJob 的返回值）
-- @param opts table|nil { dryRun =, verify = }
-- @return result table
function JobRunner.processJob(job, opts)
    opts = opts or {}
    local opt = job.options or {}

    local dryRun = (opts.dryRun ~= nil) and (opts.dryRun and true or false)
        or (opt.dryRun and true or false)
    local verify = (opts.verify ~= nil) and (opts.verify and true or false)
        or (opt.verify and true or false)

    local result = {
        id       = job.id,
        ok       = true,
        dryRun   = dryRun,
        pluginVersion = string.format("%s (build %s)",
            tostring(Manifest.pluginVersionText),
            tostring(Manifest.pluginVersion and Manifest.pluginVersion.build)),
        xmp      = job.xmp,
        startedAt = Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0),
        photos   = Json.array({}),   -- 保持 JSON 数组语义（空的时候也是 []）
        counts   = { photos = 0, ok = 0, failed = 0, skipped = 0 },
        message  = nil,
    }

    ----------------------------------------------------------------
    -- 同一个 job 共用一次分析（XMP 只解析一遍）
    ----------------------------------------------------------------
    local analysis, aerr = ApplyEngine.analyze(job.xmp, {
        applyExtendedFields = opt.applyExtendedFields and true or false,
        logger              = Logger,
    })
    if analysis == nil then
        result.ok = false
        result.stage = "analyze"
        result.message = "XMP 分析失败：" .. tostring(aerr)
        Logger.error(result.message, {
            operation = "JOB", result = "FAILED", jobId = job.id,
        })
        return result
    end

    local engineOpts = {
        policy  = (type(opt.policy) == "table") and opt.policy or nil,
        verify  = verify,
        dryRun  = dryRun,
        timeout = 60,
    }

    ----------------------------------------------------------------
    -- 逐张处理
    ----------------------------------------------------------------
    for _, path in ipairs(job.photos) do
        result.counts.photos = result.counts.photos + 1

        local entry = { photo = path }

        local photo, perr = PhotoResolver.findByPath(path)
        if photo == nil then
            entry.ok      = false
            entry.stage   = "resolve"
            entry.message = "在 Lightroom 目录中找不到这张照片：" .. tostring(perr)
        else
            local desc = PhotoResolver.describe(photo)
            entry.fileName = desc.fileName

            local outcome = ApplyEngine.apply(photo, desc, analysis, engineOpts)
            JobRunner.applyOutcomeToEntry(entry, outcome)
        end

        if entry.ok then
            result.counts.ok = result.counts.ok + 1
        elseif entry.skipped then
            result.counts.skipped = result.counts.skipped + 1
            result.ok = false
        else
            result.counts.failed = result.counts.failed + 1
            result.ok = false
        end

        result.photos[#result.photos + 1] = entry
    end

    result.finishedAt = Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0)

    Logger.info(string.format(
        "job %s 处理完成：%d 张（成功 %d / 跳过 %d / 失败 %d）%s",
        tostring(job.id), result.counts.photos, result.counts.ok,
        result.counts.skipped, result.counts.failed,
        dryRun and " [dryRun]" or ""),
        { operation = "JOB", result = result.ok and "OK" or "FAILED", jobId = job.id })

    return result
end

----------------------------------------------------------------------
-- 结果落盘 / 归档
----------------------------------------------------------------------

function JobRunner.resultPath(id)
    return Utils.platform.joinPath(JobRunner.paths().results, tostring(id) .. ".json")
end

--- 写结果文件。写入失败只记日志（不能因为写不了日志目录就崩掉整个轮询）
-- @return path|nil, err
function JobRunner.writeResult(result)
    JobRunner.ensureDirs()
    local path = JobRunner.resultPath(result.id)
    local ok, err = Utils.platform.writeFile(path, Json.encode(result) .. "\n")
    if not ok then
        Logger.error("写结果文件失败：" .. tostring(err), {
            operation = "JOB", result = "FAILED", jobId = result.id,
        })
        return nil, err
    end
    return path
end

--- 把处理完的 job 移到 archive/（失败件加 failed- 前缀）
function JobRunner.archiveJob(jobPath, succeeded)
    local p = JobRunner.paths()
    local name = Utils.basename(jobPath)
    if not succeeded then
        name = "failed-" .. name
    end
    local dest = Utils.platform.joinPath(p.archive, name)

    -- 避免重名覆盖
    if Utils.platform.fileExists(dest) and Utils.platform.chooseUniqueFile then
        dest = Utils.platform.chooseUniqueFile(dest)
    end

    -- 归档方式：读 → 写 → 删。
    --   刻意**不用** LrFileUtils.move：实测在 Lightroom Classic 14.5.1 上它返回 false
    --   且不给出任何原因（诊断报告里就是 move→archive: FAILED（没有给出原因））。
    --   而 readFile / writeFile / deleteFile 三个原语是实测可用的。
    local content = Utils.platform.readFile(jobPath)
    if content then
        local okWrite, wErr = Utils.platform.writeFile(dest, content)
        if okWrite then
            Utils.platform.deleteFile(jobPath)
            return true
        end
        Logger.warn("归档写入失败：" .. tostring(wErr), {
            operation = "JOB", jobId = Utils.basename(jobPath),
        })
    else
        Logger.warn("归档读取失败，无法复制 job 内容", {
            operation = "JOB", jobId = Utils.basename(jobPath),
        })
    end

    -- 兜底：留在 inbox 里会被反复处理，宁可只删掉（结果文件里有完整信息）
    if Utils.platform.deleteFile and Utils.platform.deleteFile(jobPath) then
        Logger.warn("job 未能归档，已直接删除（结果文件仍保留）", {
            operation = "JOB", jobId = Utils.basename(jobPath),
        })
        return false
    end

    Logger.error("job 既无法归档也无法删除，会停留在 inbox 里被反复处理：" ..
        tostring(jobPath), { operation = "JOB", result = "STUCK" })
    return false
end

----------------------------------------------------------------------
-- 一轮处理
----------------------------------------------------------------------

--- 处理一个 job 文件（解析 → 执行 → 写结果 → 归档）
-- @return ok boolean, errString
function JobRunner.processOne(jobPath, opts)
    local job, perr = JobRunner.parseJob(jobPath)

    if job == nil then
        local id = Utils.stripExtension(Utils.basename(jobPath))
        JobRunner.writeResult({
            id = id, ok = false, stage = "parse", dryRun = false,
            xmp = nil, photos = Json.array({}), message = "job 解析失败：" .. tostring(perr),
            counts = { photos = 0, ok = 0, failed = 0, skipped = 0 },
        })
        JobRunner.archiveJob(jobPath, false)
        Logger.error("job 解析失败：" .. tostring(perr), {
            operation = "JOB", result = "FAILED", jobId = id,
        })
        return false, perr
    end

    local result = JobRunner.processJob(job, opts)
    JobRunner.writeResult(result)
    JobRunner.archiveJob(jobPath, result.ok)
    return result.ok, nil
end

--- 处理 inbox 里的全部 job
-- @return summary table { jobs=, ok=, failed= }
function JobRunner.processAll(opts)
    JobRunner.ensureDirs()
    local summary = { jobs = 0, ok = 0, failed = 0, alreadyProcessed = 0 }

    for _, jobPath in ipairs(JobRunner.listPending()) do
        -- 归档失败时文件会留在 inbox；这里挡一下，避免每秒重复处理。
        -- 用「路径 + 文件大小」判断内容是否变过。
        local size = Utils.platform.fileSize and Utils.platform.fileSize(jobPath) or nil
        local seenSize = processed[jobPath]
        if seenSize ~= nil and (size == nil or seenSize == size) then
            summary.alreadyProcessed = summary.alreadyProcessed + 1
            if not skipWarned[jobPath] then
                skipWarned[jobPath] = true
                Logger.warn("这个 job 已经处理过但没能归档，先跳过避免重复处理：" ..
                    tostring(Utils.basename(jobPath)) ..
                    "（内容改动或重载插件后会重新处理）",
                    { operation = "JOB", result = "SKIPPED_DUP" })
            end
        else
            summary.jobs = summary.jobs + 1
            local ok = JobRunner.processOne(jobPath, opts)
            processed[jobPath] = size
            if ok then
                summary.ok = summary.ok + 1
            else
                summary.failed = summary.failed + 1
            end
        end
    end
    return summary
end

return JobRunner
