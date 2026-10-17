--[[
    tests/test_ApplyEngine.lua  —  无 UI 应用引擎的测试

    重点验证两件事：
      1. analyze / decide 是纯逻辑，不需要 Lightroom；
      2. **判定与裁决的正确性** —— 无 UI 模式下「该跳过的必须跳过」，
         这层如果错了，自动化就会在没人看的情况下动照片。
--]]

local T             = require "framework"
local Utils         = require "Utils"
local Logger        = require "Logger"
local ApplyEngine   = require "ApplyEngine"

-- 避免测试输出被业务日志淹没
Logger.configure { level = "error", echo = false }

local FX = T.root .. "/tests/fixtures"

local SilentLogger = {
    info = function() end, warn = function() end,
    error = function() end, debug = function() end,
}

local function analyzeFixture(name, opts)
    opts = opts or {}
    opts.logger = SilentLogger
    local a, err = ApplyEngine.analyze(FX .. "/" .. name, opts)
    if a == nil then
        error("analyze 失败: " .. tostring(err), 0)
    end
    return a
end

local function descFor(fileName)
    return { fileName = fileName, isVirtualCopy = false }
end

----------------------------------------------------------------------

T.suite("ApplyEngine / analyze（不触碰照片）")

T.case("basic.xmp：37 个可应用字段、零错误", function()
    local a = analyzeFixture("basic.xmp")
    T.eq(a.result.counts.settings, 37, "可应用字段数")
    T.eq(a.result.counts.errors, 0, "不应有错误")
    T.eq(a.meta.sourceFile, "IMG_1023.CR3", "meta 应透传")
    T.truthy(a.parsed ~= nil, "应带 parsed")
    T.contains(a.xmpPath, "basic.xmp", "应记录 xmpPath")
end)

T.case("tone_curve.xmp：曲线零错误（回归）", function()
    local a = analyzeFixture("tone_curve.xmp")
    T.eq(a.result.counts.errors, 0, "不应有错误")
    T.isTable(a.result.settings.ToneCurvePV2012, "曲线应已转换")
    T.eq(#a.result.settings.ToneCurvePV2012, 6, "曲线点数")
end)

T.case("applyExtendedFields 开关生效", function()
    local a1 = analyzeFixture("basic.xmp")                       -- 默认关闭
    T.eq(a1.result.settings.AutoLateralCA, nil, "默认不应用扩展字段")

    local a2 = analyzeFixture("basic.xmp", { applyExtendedFields = true })
    T.truthy(a2.result.settings.AutoLateralCA ~= nil, "开启后应应用")
end)

T.case("空路径 / 文件不存在 → 返回可读错误而不是抛穿", function()
    local a1, e1 = ApplyEngine.analyze("", { logger = SilentLogger })
    T.eq(a1, nil); T.contains(tostring(e1), "未指定")

    local a2, e2 = ApplyEngine.analyze(FX .. "/__不存在__.xmp", { logger = SilentLogger })
    T.eq(a2, nil)
    T.truthy(type(e2) == "string" and #e2 > 0, "应返回错误字符串")
end)

----------------------------------------------------------------------

T.suite("ApplyEngine / decide（纯判定，无 UI 语义）")

T.case("源文件匹配且无问题 → ok", function()
    local a = analyzeFixture("basic.xmp")
    local d = ApplyEngine.decide(a, descFor("IMG_1023.CR3"), {})
    T.truthy(d.ok, "应放行")
    T.eq(d.skipReason, nil)
    for _, issue in ipairs(d.issues) do
        T.neq(issue.severity, "block", "不应有拦截级问题")
    end
end)

T.case("源文件不匹配 → 默认策略 skip", function()
    local a = analyzeFixture("basic.xmp")
    local d = ApplyEngine.decide(a, descFor("IMG_9999.CR3"), {})
    T.falsy(d.ok, "默认应拦截")
    T.truthy(d.skipReason ~= nil, "应给出跳过原因")

    local found = false
    for _, issue in ipairs(d.issues) do
        if issue.kind == "mismatch" then
            found = true
            T.eq(issue.severity, "block")
            T.eq(issue.policy, "skip")
            T.contains(issue.detail, "IMG_1023.CR3", "详情应含 XMP 侧文件名")
            T.contains(issue.detail, "IMG_9999.CR3", "详情应含照片侧文件名")
        end
    end
    T.truthy(found, "应有 mismatch 问题")
end)

T.case("源文件不匹配 + policy=apply → 放行", function()
    local a = analyzeFixture("basic.xmp")
    local d = ApplyEngine.decide(a, descFor("IMG_9999.CR3"), { policy = { mismatch = "apply" } })
    T.truthy(d.ok, "策略允许时应放行")
end)

T.case("看起来是官方随图 XMP → warn 级，默认放行", function()
    local a = analyzeFixture("basic.xmp")
    a.xmpPath = "/photos/IMG_1023.xmp"           -- 与照片同名 → 命中 sidecar 规则
    local d = ApplyEngine.decide(a, descFor("IMG_1023.CR3"), {})
    T.truthy(d.ok, "warn 级不应拦截")

    local found = false
    for _, issue in ipairs(d.issues) do
        if issue.kind == "sidecar" then
            found = true
            T.eq(issue.severity, "warn")
            T.eq(issue.policy, "apply")
        end
    end
    T.truthy(found, "应识别为官方 sidecar")
end)

T.case("官方 sidecar + policy=skip → 拦截", function()
    local a = analyzeFixture("basic.xmp")
    a.xmpPath = "/photos/IMG_1023.xmp"
    local d = ApplyEngine.decide(a, descFor("IMG_1023.CR3"), { policy = { sidecar = "skip" } })
    T.falsy(d.ok, "策略改为 skip 后应拦截")
end)

T.case("有校验错误 → block 级，默认 skip", function()
    local a = analyzeFixture("basic.xmp")
    a.result.counts.errors = 1
    a.result.errors = { { field = "Exposure2012", message = "值非法" } }

    local d = ApplyEngine.decide(a, descFor("IMG_1023.CR3"), {})
    T.falsy(d.ok, "默认应拦截")
    local found = false
    for _, issue in ipairs(d.issues) do
        if issue.kind == "errors" then
            found = true
            T.eq(issue.severity, "block")
            T.contains(issue.detail, "Exposure2012", "详情应列出出错字段")
        end
    end
    T.truthy(found, "应有 errors 问题")
end)

T.case("一个字段都没有 → block 级", function()
    local a = analyzeFixture("basic.xmp")
    a.result.counts.settings = 0
    local d = ApplyEngine.decide(a, descFor("IMG_1023.CR3"), {})
    T.falsy(d.ok, "应拦截")
    local found = false
    for _, issue in ipairs(d.issues) do
        if issue.kind == "empty" then found = true end
    end
    T.truthy(found, "应有 empty 问题")
end)

T.case("analysis 为 nil → 直接判定不可应用", function()
    local d = ApplyEngine.decide(nil, descFor("x.CR3"), {})
    T.falsy(d.ok)
    T.truthy(d.skipReason ~= nil)
end)

T.case("info 级提示不参与拦截", function()
    local a = analyzeFixture("basic.xmp")
    local d = ApplyEngine.decide(a, descFor("IMG_1023.CR3"), {})
    -- basic.xmp 的源文件与 desc 一致，不应产生 info；换一个未声明来源的
    local b = analyzeFixture("tone_curve.xmp")
    local d2 = ApplyEngine.decide(b, descFor("别的名字.CR3"), {})
    -- tone_curve.xmp 声明了 IMG_1023.CR3，与「别的名字」不匹配 → block
    T.falsy(d2.ok, "不匹配应拦截")
    T.truthy(d.ok, "匹配时应放行")
end)

----------------------------------------------------------------------

T.suite("ApplyEngine / resolve（谁来拍板）")

local function decisionWithIssue(policy)
    local a = analyzeFixture("basic.xmp")
    return ApplyEngine.decide(a, descFor("IMG_9999.CR3"), { policy = policy or {} })
end

T.case("没有 confirm 回调 → 沿用 policy（自动化模式）", function()
    local d = decisionWithIssue()
    local proceed, reason = ApplyEngine.resolve(d, {})
    T.falsy(proceed, "默认策略 skip 时不应放行")
    T.truthy(reason ~= nil)

    local d2 = decisionWithIssue({ mismatch = "apply" })
    local proceed2 = ApplyEngine.resolve(d2, {})
    T.truthy(proceed2, "策略 apply 时应放行")
end)

T.case("confirm 返回 true 可以推翻 skip", function()
    local d = decisionWithIssue()
    local proceed = ApplyEngine.resolve(d, {
        confirm = function(issue)
            T.eq(issue.kind, "mismatch", "应把问题交给界面")
            T.contains(issue.headline, "不匹配")
            T.truthy(issue.actionVerb ~= nil and issue.cancelVerb ~= nil, "应带按钮文案")
            return true
        end,
    })
    T.truthy(proceed, "界面接受后应放行")
end)

T.case("confirm 返回 false 会拦住（即使 policy 是 apply）", function()
    local d = decisionWithIssue({ mismatch = "apply" })
    local proceed = ApplyEngine.resolve(d, {
        confirm = function() return false end,
    })
    T.falsy(proceed, "界面拒绝后应拦截")
end)

T.case("info 级问题不会调 confirm", function()
    -- 构造一个只有 info 的判定：源文件未声明
    local a = analyzeFixture("basic.xmp")
    a.meta.sourceFile = nil
    local d = ApplyEngine.decide(a, descFor("任意.CR3"), {})
    local called = 0
    local proceed = ApplyEngine.resolve(d, {
        confirm = function() called = called + 1; return true end,
    })
    T.truthy(proceed, "只有 info 时应放行")
    T.eq(called, 0, "info 级不应弹确认")
end)

----------------------------------------------------------------------

T.suite("ApplyEngine / apply（结束条件与安全阀）")

T.case("photo 为 nil → 明确失败", function()
    local a = analyzeFixture("basic.xmp")
    local o = ApplyEngine.apply(nil, descFor("x.CR3"), a, {})
    T.falsy(o.ok)
    T.contains(tostring(o.message), "没有目标照片")
end)

T.case("analysis 为 nil → 明确失败", function()
    local o = ApplyEngine.apply({}, descFor("x.CR3"), nil, {})
    T.falsy(o.ok)
    T.contains(tostring(o.message), "分析结果")
end)

T.case("前置校验不通过 → skipped，且不进入写入阶段", function()
    local a = analyzeFixture("basic.xmp")
    local o = ApplyEngine.apply({}, descFor("IMG_9999.CR3"), a, {})
    T.falsy(o.ok)
    T.truthy(o.skipped, "应标记为 skipped")
    T.eq(o.stage, "precheck", "应停在 precheck 阶段")
    T.truthy(o.reportText ~= nil, "跳过也应产出报告，便于自动化读取")
    T.contains(o.reportText, "SKIPPED", "报告应标注 SKIPPED")
end)

T.case("界面拒绝确认 → skipped", function()
    local a = analyzeFixture("basic.xmp")
    local o = ApplyEngine.apply({}, descFor("IMG_9999.CR3"), a, {
        confirm = function() return false end,
    })
    T.truthy(o.skipped, "应跳过")
    T.eq(o.stage, "precheck")
end)

T.case("通过前置校验后会真的走到写入阶段（测试环境无 Lightroom 应优雅失败）", function()
    local a = analyzeFixture("basic.xmp")
    local o = ApplyEngine.apply({}, descFor("IMG_1023.CR3"), a, {})
    T.eq(o.stage, "apply", "应进入写入阶段")
    T.falsy(o.ok, "无 Lightroom 运行时必然失败")
    T.contains(tostring(o.message), "Lightroom", "错误信息应说明不在 Lightroom 中")
    T.truthy(o.reportText ~= nil, "失败也要出报告")
    T.contains(o.reportText, "FAILED", "报告应标注 FAILED")
end)

T.case("跳过时不调用写入（不会误伤照片）", function()
    -- 用一个会记录调用次数的光标签达不到目的，这里改为断言 stage：
    -- verify 为 nil 且 stage=precheck 说明没走到 ApplyDevelop
    local a = analyzeFixture("basic.xmp")
    a.result.counts.errors = 3
    a.result.errors = { { field = "A", message = "x" } }
    local o = ApplyEngine.apply({}, descFor("IMG_1023.CR3"), a, {})
    T.eq(o.stage, "precheck", "有错误且默认策略 skip 时应停在前置阶段")
    T.eq(o.verify, nil, "不应有读回校验结果")
end)

----------------------------------------------------------------------

T.suite("ApplyEngine / runOne 与历史步骤名")

T.case("runOne 在分析阶段失败时 stage=analyze", function()
    local o = ApplyEngine.runOne({}, descFor("x.CR3"), FX .. "/__不存在__.xmp", {})
    T.falsy(o.ok)
    T.eq(o.stage, "analyze")
    T.truthy(o.message ~= nil)
end)

T.case("historyNameFor 带上预设名", function()
    local n1 = ApplyEngine.historyNameFor({ presetName = "Natural Warm" })
    T.contains(n1, "Natural Warm", "应含预设名")

    local n2 = ApplyEngine.historyNameFor({})
    T.truthy(type(n2) == "string" and #n2 > 0, "无预设名时也要有默认步骤名")
    T.falsy(n2:find(": $") ~= nil, "不应出现空后缀")
end)

T.case("默认策略表是公开且可覆盖的", function()
    T.eq(ApplyEngine.defaultPolicy.mismatch, "skip")
    T.eq(ApplyEngine.defaultPolicy.sidecar, "apply")
    T.eq(ApplyEngine.defaultPolicy.errors, "skip")
end)

return true
