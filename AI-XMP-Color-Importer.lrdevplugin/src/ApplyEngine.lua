--[[
    src/ApplyEngine.lua  —  无 UI 的应用引擎（纯逻辑，不弹任何对话框）

    为什么要有这一层：
        Phase 1 之前，「分析 → 校验 → 写入 → 报告」这段流程是直接内联在
        ui/ImportDialog.lua 里的，和 LrDialogs / LrView 缠在一起。
        这样一来自动化（无点击模式）就没法复用，只能再写一遍 —— 两条路径必然分叉。

        现在把它抽成引擎：引擎只做判断与写入，**所有需要人确认的地方都交出去**
        （通过 opts.confirm 回调，或通过 policy 策略自动决定）。
        · 界面模式：UI 传入 confirm 回调，用对话框问
        · 自动化模式：不传 confirm，按 policy 自动取舍，结果写进 outcome

    对外 API：
        ApplyEngine.analyze(xmpPath, opts)                  → analysis | nil, err
        ApplyEngine.decide(analysis, desc, opts)            → decision（纯函数）
        ApplyEngine.resolve(decision, opts)                 → proceed, skipReason
        ApplyEngine.apply(photo, desc, analysis, opts)      → outcome
        ApplyEngine.runOne(photo, desc, xmpPath, opts)      → outcome（analyze + apply）

    outcome 结构：
        { ok, stage, message, skipped, applied, counts, issues, verify,
          verifySummary, reportText }
--]]

local Utils           = AI_COLOR_IMPORTER.load("src/Utils.lua")
local Logger          = AI_COLOR_IMPORTER.load("src/Logger.lua")
local Manifest        = AI_COLOR_IMPORTER.load("manifest.lua")
local XmpParser       = AI_COLOR_IMPORTER.load("src/XmpParser.lua")
local XmpMapping      = AI_COLOR_IMPORTER.load("src/XmpMapping.lua")
local Validation      = AI_COLOR_IMPORTER.load("src/Validation.lua")
local DevelopSettings = AI_COLOR_IMPORTER.load("src/DevelopSettings.lua")
local PhotoResolver   = AI_COLOR_IMPORTER.load("src/PhotoResolver.lua")
local ApplyDevelop    = AI_COLOR_IMPORTER.load("src/ApplyDevelop.lua")

local ApplyEngine = {}

----------------------------------------------------------------------
-- 默认策略：无 UI（自动化）时如何取舍
--   mismatch = "skip"  —— XMP 声明的源文件与照片不一致 → 不动这张照片
--   sidecar  = "apply" —— 看起来是官方随图 XMP → 只记警告，照常应用
--   errors   = "skip"  —— 有校验错误 → 不动这张照片
----------------------------------------------------------------------
ApplyEngine.defaultPolicy = {
    mismatch = "skip",
    sidecar  = "apply",
    errors   = "skip",
}

----------------------------------------------------------------------
-- 1) 分析（不触碰照片）
----------------------------------------------------------------------

--- 是否应该在 Develop 模块下取运行期参数范围
local function shouldUseRuntimeRanges()
    local LrApplicationView = Utils.lrImport("LrApplicationView")
    if not LrApplicationView then
        return false
    end
    local ok, name = Utils.safeCall("ai-color-current-module", function()
        return LrApplicationView.getCurrentModuleName()
    end)
    return ok and name == "develop"
end

--- 分析一个 XMP 文件：解析 → 映射 → 校验
-- @param xmpPath string
-- @param opts table|nil {
--          applyExtendedFields = boolean,
--          useRuntimeRanges    = boolean|nil（nil = 在 Develop 模块下自动启用）,
--          logger              = Logger 兼容对象（可选，测试注入用）,
--        }
-- @return analysis table|nil, errString
function ApplyEngine.analyze(xmpPath, opts)
    opts = opts or {}

    if Utils.isBlank(xmpPath) then
        return nil, "未指定 XMP 文件"
    end

    local parsed, perr = XmpParser.parseFile(xmpPath)
    if not parsed then
        return nil, perr
    end

    local bundle = XmpMapping.toDevelopSettings(parsed, {
        applyExtendedFields = opts.applyExtendedFields and true or false,
        logger              = opts.logger,
    })

    -- 运行期参数范围（可选增强）：只有在 Develop 模块下才拿得到
    local runtimeRanges = {}
    local useRuntime = opts.useRuntimeRanges
    if useRuntime == nil then
        useRuntime = shouldUseRuntimeRanges()
    end
    if useRuntime then
        runtimeRanges = XmpMapping.applyRuntimeRanges(function(param)
            return ApplyDevelop.getParamRange(param)
        end)
    end

    local result = Validation.validate(bundle, { runtimeRanges = runtimeRanges })

    return {
        xmpPath = xmpPath,
        parsed  = parsed,
        result  = result,
        meta    = parsed.metadata or {},
    }
end

----------------------------------------------------------------------
-- 2) 判定（纯函数：不做 IO、不弹窗、不写照片）
----------------------------------------------------------------------

--- 汇总分析结果 + 目标照片，得出「要不要应用 / 有哪些问题」
--
-- 每个 issue：
--   kind      "mismatch"|"probable"|"unknownSource"|"sidecar"|"errors"|"empty"
--   severity  "block"（默认拦截）| "warn"（默认放行）| "info"（只记日志）
--   policy    无 UI 时的默认动作 "apply"|"skip"
--   action    实际动作；会被 opts.confirm 覆盖
--   headline / detail / actionVerb / cancelVerb   供 UI 直接摆进对话框
--
-- @param opts table|nil { policy = { mismatch=, sidecar=, errors= } }
-- @return decision table { ok, skipReason, issues }
function ApplyEngine.decide(analysis, desc, opts)
    opts = opts or {}

    local policy = {}
    for k, v in pairs(ApplyEngine.defaultPolicy) do
        policy[k] = v
    end
    for k, v in pairs(opts.policy or {}) do
        policy[k] = v
    end

    local decision = { ok = true, skipReason = nil, issues = {} }

    if analysis == nil or analysis.result == nil then
        decision.ok = false
        decision.skipReason = "没有可用的分析结果"
        return decision
    end

    local meta   = analysis.meta or {}
    local counts = analysis.result.counts or {}

    --- 登记一个需要人裁决的问题
    local function addIssue(kind, severity, headline, detail, actionVerb, cancelVerb, defaultAction)
        local issue = {
            kind       = kind,
            severity   = severity,
            headline   = headline,
            detail     = detail,
            actionVerb = actionVerb,
            cancelVerb = cancelVerb,
            policy     = defaultAction,
            action     = defaultAction,
        }
        decision.issues[#decision.issues + 1] = issue
        if defaultAction == "skip" then
            decision.ok = false
            if decision.skipReason == nil then
                decision.skipReason = headline
            end
        end
        return issue
    end

    --- 登记一个只记录、不影响决策的提示
    local function addNote(kind, headline, detail)
        decision.issues[#decision.issues + 1] = {
            kind = kind, severity = "info",
            headline = headline, detail = detail,
            policy = "apply", action = "apply",
        }
    end

    ----------------------------------------------------------------
    -- 2a) XMP 声明的源文件 vs 目标照片
    ----------------------------------------------------------------
    local status, detail = PhotoResolver.compareSourceFile(meta.sourceFile, desc)
    if status == "mismatch" then
        addIssue("mismatch", "block",
            "XMP 与当前照片可能不匹配。",
            string.format(
                "XMP:\n  %s\n\n当前照片:\n  %s\n\n源文件不一致时默认不应用。只有确认这份调色方案本来就该用在这张照片上时，才继续。",
                tostring(meta.sourceFile), tostring(desc and desc.fileName)),
            "仍然应用", "取消", policy.mismatch)
    elseif status == "probable" then
        addNote("probable", "源文件按宽容规则匹配", tostring(detail))
    elseif status == "unknown" then
        addNote("unknownSource", "XMP 未声明来源文件", tostring(detail))
    end

    ----------------------------------------------------------------
    -- 2b) 是否看起来是 Lightroom 官方随图 XMP（会被 LR 覆写）
    ----------------------------------------------------------------
    local isSidecar, why = PhotoResolver.looksLikeOfficialSidecar(analysis.xmpPath, desc)
    if isSidecar then
        addIssue("sidecar", "warn",
            "这个 XMP 看起来是 Lightroom 的官方随图配置文件。",
            tostring(why) ..
            "\n\n本插件只读取、不会修改它，但 Lightroom 自身在「自动写入 XMP」开启时可能会覆写它，" ..
            "从而丢失这份 AI 调色方案。\n\n建议：把 AI 生成的 XMP 另存为不同文件名再使用。",
            "仍然继续", "取消", policy.sidecar)
    end

    ----------------------------------------------------------------
    -- 2c) 校验错误（个别字段非法，会被丢弃）
    ----------------------------------------------------------------
    local errCount = counts.errors or 0
    if errCount > 0 then
        local msgs = {}
        for i, e in ipairs(analysis.result.errors or {}) do
            if i > 6 then
                msgs[#msgs + 1] = string.format("  … 另有 %d 条", errCount - 6)
                break
            end
            msgs[#msgs + 1] = string.format("  %s：%s", tostring(e.field), tostring(e.message))
        end
        addIssue("errors", "block",
            string.format("有 %d 个字段校验未通过，这些字段会被丢弃。", errCount),
            table.concat(msgs, "\n") ..
            string.format("\n\n其余 %d 个字段仍会正常应用。", counts.settings or 0),
            "仍然应用", "取消", policy.errors)
    end

    ----------------------------------------------------------------
    -- 2d) 一个字段都没有
    ----------------------------------------------------------------
    if (counts.settings or 0) == 0 then
        addIssue("empty", "block",
            "没有可应用的字段",
            "分析结果里没有任何可写入的 Develop 字段，请检查 XMP 内容。",
            nil, nil, "skip")
    end

    return decision
end

--- 把 decision 里的问题逐一裁决
--  · 传了 opts.confirm  → 交给它（界面模式）
--  · 没传               → 沿用 policy（自动化模式）
-- @return proceed boolean, skipReason string|nil
function ApplyEngine.resolve(decision, opts)
    opts = opts or {}
    local confirm = opts.confirm

    if decision == nil then
        return false, "没有判定结果"
    end

    for _, issue in ipairs(decision.issues or {}) do
        -- info 级不需要人管，不调 confirm
        if issue.severity ~= "info" then
            if type(confirm) == "function" then
                local accepted = confirm(issue)
                issue.action = accepted and "apply" or "skip"
            end
            -- 没有 confirm 时 issue.action 已经是 policy
        end
    end

    local proceed, skipReason = true, nil
    for _, issue in ipairs(decision.issues or {}) do
        if issue.severity ~= "info" and issue.action == "skip" then
            proceed = false
            skipReason = skipReason or issue.headline
        end
    end

    return proceed, skipReason
end

----------------------------------------------------------------------
-- 3) 应用（会写目录，但不弹窗）
----------------------------------------------------------------------

--- 生成历史步骤名
function ApplyEngine.historyNameFor(meta)
    local name = Manifest.historyStepPrefix
    if meta and not Utils.isBlank(meta.presetName) then
        name = Manifest.historyStepPrefix .. ": " .. tostring(meta.presetName)
    end
    return name
end

--- 把分析结果应用到一张照片
-- @param photo LrPhoto
-- @param desc  PhotoResolver.describe 的结果
-- @param analysis ApplyEngine.analyze 的返回值
-- @param opts table|nil {
--          confirm   = function(issue) -> boolean   （不传 = 按 policy 自动决定）
--          policy    = { mismatch=, sidecar=, errors= }
--          verify    = boolean  写后读回校验
--          timeout   = number   等待写权限秒数
--        }
-- @return outcome table
function ApplyEngine.apply(photo, desc, analysis, opts)
    opts = opts or {}

    local outcome = {
        ok      = false,
        stage   = "precheck",
        message = nil,
        skipped = false,
        dryRun  = false,
        applied = 0,
        wouldApply = 0,
        historyName = nil,
        counts  = {},
        issues  = {},
        verify  = nil,
        verifySummary = nil,
        reportText = nil,
    }

    if photo == nil then
        outcome.message = "没有目标照片"
        return outcome
    end
    if analysis == nil or analysis.result == nil then
        outcome.message = "没有可用的分析结果"
        return outcome
    end

    local photoName = desc and desc.fileName or nil
    local xmpName   = Utils.basename(analysis.xmpPath)
    local meta      = analysis.meta or {}
    outcome.counts  = analysis.result.counts or {}

    ----------------------------------------------------------------
    -- 判定 + 裁决
    ----------------------------------------------------------------
    local decision = ApplyEngine.decide(analysis, desc, opts)
    outcome.issues = decision.issues

    -- info 级：只记日志
    for _, issue in ipairs(decision.issues) do
        if issue.severity == "info" then
            Logger.info(string.format("%s：%s", tostring(issue.headline), tostring(issue.detail)),
                { operation = "APPLY", photo = photoName, xmp = xmpName })
        end
    end

    local proceed, skipReason = ApplyEngine.resolve(decision, opts)

    ----------------------------------------------------------------
    -- 报告构造器（成功/失败/跳过都要能出报告）
    ----------------------------------------------------------------
    local function buildReport(resultLabel, failMessage)
        local record = DevelopSettings.buildReportRecord(analysis.result, {
            operation  = "APPLY",
            timestamp  = Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0),
            photoName  = photoName,
            xmpName    = xmpName,
            presetName = meta.presetName,
            sourceFile = meta.sourceFile,
            aiVersion  = meta.aiVersion,
            result     = resultLabel,
        })
        if failMessage then
            record.errors[#record.errors + 1] = { field = "-", message = failMessage }
        end
        return Logger.buildApplyReport(record, true)
    end

    ----------------------------------------------------------------
    -- 未通过前置校验
    ----------------------------------------------------------------
    if not proceed then
        outcome.stage    = "precheck"
        outcome.skipped  = true
        outcome.message  = skipReason or "未通过前置校验"
        outcome.reportText = buildReport("SKIPPED", outcome.message)

        Logger.warn("跳过应用：" .. outcome.message, {
            operation = "APPLY", photo = photoName, xmp = xmpName, result = "SKIPPED",
        })
        return outcome
    end

    ----------------------------------------------------------------
    -- 写入
    ----------------------------------------------------------------
    local applyTable = DevelopSettings.toApplyTable(analysis.result)
    local historyName = ApplyEngine.historyNameFor(meta)
    outcome.historyName = historyName
    outcome.wouldApply  = Utils.tcount(applyTable)

    ----------------------------------------------------------------
    -- dryRun：只算不写（自动化模式必备的安全阀）
    ----------------------------------------------------------------
    if opts.dryRun then
        outcome.stage      = "dryrun"
        outcome.ok         = true
        outcome.dryRun     = true
        outcome.message    = string.format(
            "dryRun：本应写入 %d 个字段，未实际修改照片", outcome.wouldApply)
        outcome.reportText = buildReport("DRYRUN")
        Logger.info(outcome.message, {
            operation = "APPLY", photo = photoName, xmp = xmpName, result = "DRYRUN",
        })
        return outcome
    end

    local applyResult = ApplyDevelop.apply(photo, applyTable, {
        historyName = historyName,
        actionName  = "AI Color: " .. tostring(meta.presetName or "XMP"),
        timeout     = opts.timeout or 60,
        verify      = opts.verify,
    })

    outcome.stage   = "apply"
    outcome.ok      = applyResult.ok and true or false
    outcome.message = applyResult.message
    outcome.applied = Utils.tcount(applyTable)
    outcome.verify  = applyResult.verify
    -- 可落盘的摘要：结果 JSON / 界面都从这里取，避免"校验跑了但没人看得见"
    outcome.verifySummary = ApplyDevelop.summarizeVerify(applyResult.verify)
    outcome.reportText = buildReport(outcome.ok and "SUCCESS" or "FAILED",
        (not outcome.ok) and (applyResult.message or "未知失败") or nil)

    ----------------------------------------------------------------
    -- 日志
    ----------------------------------------------------------------
    if outcome.ok then
        Logger.info("Apply 成功：" .. tostring(applyResult.message), {
            operation = "APPLY", photo = photoName, xmp = xmpName, result = "SUCCESS",
        })
    else
        Logger.error("Apply 失败：" .. tostring(applyResult.message), {
            operation = "APPLY", photo = photoName, xmp = xmpName, result = "FAILED",
        })
    end
    Logger.info(outcome.reportText, { operation = "APPLY_REPORT", photo = photoName })

    ----------------------------------------------------------------
    -- 读回校验（只记日志，不改变成功判定）
    ----------------------------------------------------------------
    local v = applyResult.verify
    if outcome.ok and v then
        if v.readError then
            Logger.warn("读回校验不可用：" .. tostring(v.readError), { operation = "VERIFY" })
        elseif #v.mismatches > 0 then
            local parts = {}
            for _, m in ipairs(v.mismatches) do
                parts[#parts + 1] = string.format("%s: 写入 %s / 读回 %s",
                    tostring(m.field), tostring(m.want), tostring(m.got))
            end
            Logger.warn(string.format(
                "读回校验发现 %d 处不一致（Lightroom 的 develop 读回存在已知滞后，通常稍后会一致）：%s",
                #v.mismatches, table.concat(parts, "; ")),
                { operation = "VERIFY", result = "MISMATCH" })
        else
            Logger.info(string.format("读回校验通过（比对 %d 项）", v.checked or 0),
                { operation = "VERIFY", result = "OK" })
        end
    end

    return outcome
end

--- 一步到位：分析 + 应用（自动化模式的主入口）
-- @return outcome table（stage 可能是 "analyze" / "precheck" / "apply"）
function ApplyEngine.runOne(photo, desc, xmpPath, opts)
    local analysis, err = ApplyEngine.analyze(xmpPath, opts)
    if analysis == nil then
        return {
            ok = false, stage = "analyze", message = tostring(err),
            skipped = false, applied = 0, counts = {}, issues = {},
        }
    end
    return ApplyEngine.apply(photo, desc, analysis, opts)
end

return ApplyEngine
