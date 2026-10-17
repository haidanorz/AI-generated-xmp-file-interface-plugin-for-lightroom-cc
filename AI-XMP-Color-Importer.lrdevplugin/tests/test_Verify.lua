--[[
    tests/test_Verify.lua  —  读回校验（verify）与「校验结果怎么出去」

    背景（真机踩到的）：
      第一次真实应用（apply-001）带了 verify: true，但结果 JSON 里没有任何校验信息，
      而 Lightroom 里根本没有可看的日志文件（LrLogger 不落盘）——
      等于「校验跑了，但结论丢失」。

    另外 verify 原来只比 number 和曲线，布尔与字符串字段（WhiteBalance /
    ConvertToGrayscale / ToneCurveName2012）被静默跳过，看起来"全通过"。

    这组用例锁住三件事：
      1. 四种类型的值都要真的比对，缺失也算不一致
      2. 摘要能压缩、能带上 readError、能进 result.json（空数组要保留 []）
      3. 结果条目必须带 verify，不得再丢
--]]

local T            = require "framework"
local Utils        = require "Utils"
local Logger       = require "Logger"
local Json         = require "Json"
local ApplyDevelop = require "ApplyDevelop"
local JobRunner    = require "JobRunner"

Logger.configure { level = "error", echo = false }

--- 假照片：只实现 verify 需要的 getDevelopSettings
local function fakePhoto(current)
    return {
        getDevelopSettings = function() return current end,
    }
end

--- 找某字段的不一致记录
local function mismatchOf(v, field)
    for _, m in ipairs(v.mismatches or {}) do
        if m.field == field then
            return m
        end
    end
    return nil
end

----------------------------------------------------------------------

T.suite("ApplyDevelop / 读回校验（四种类型都要真比）")

T.case("数值：容差内算通过（0.35 读回 0.349999）", function()
    local v = ApplyDevelop.verify(
        fakePhoto { Exposure2012 = 0.349999 },
        { Exposure2012 = 0.35 })

    T.eq(v.readError, nil)
    T.eq(v.checked, 1, "应比对 1 项")
    T.eq(#v.mismatches, 0, "精度误差不该算不一致")
end)

T.case("数值：超出容差算不一致，并带上 want / got", function()
    local v = ApplyDevelop.verify(
        fakePhoto { Exposure2012 = 0.90 },
        { Exposure2012 = 0.35 })

    T.eq(#v.mismatches, 1)
    local mm = mismatchOf(v, "Exposure2012")
    T.truthy(mm, "应报出该字段")
    T.near(mm.want, 0.35, 1e-9, "want 应是写入值")
    T.near(mm.got, 0.90, 1e-9, "got 应是读回值")
end)

T.case("布尔：参与比对（早期版本整类被跳过）", function()
    local ok = ApplyDevelop.verify(
        fakePhoto { ConvertToGrayscale = true },
        { ConvertToGrayscale = true })
    T.eq(ok.checked, 1, "应比对 1 项")
    T.eq(#ok.mismatches, 0)

    local bad = ApplyDevelop.verify(
        fakePhoto { ConvertToGrayscale = false },
        { ConvertToGrayscale = true })
    T.eq(bad.checked, 1)
    T.eq(#bad.mismatches, 1, "写入 true 读回 false 必须报出来")
end)

T.case("字符串：忽略大小写与空白（Custom vs ' custom '）", function()
    local v = ApplyDevelop.verify(
        fakePhoto { WhiteBalance = " custom " },
        { WhiteBalance = "Custom" })
    T.eq(v.checked, 1)
    T.eq(#v.mismatches, 0, "枚举大小写差异不应算不一致")
end)

T.case("字符串：值真的不同要报出来", function()
    local v = ApplyDevelop.verify(
        fakePhoto { WhiteBalance = "Daylight" },
        { WhiteBalance = "Custom" })
    T.eq(#v.mismatches, 1)
    local m = mismatchOf(v, "WhiteBalance")
    T.eq(m.want, "Custom")
    T.eq(m.got, "Daylight")
end)

T.case("曲线：逐点比对，长度一致才算比过", function()
    local curve = { 0, 0, 92, 106, 255, 255 }

    local same = ApplyDevelop.verify(
        fakePhoto { ToneCurvePV2012 = { 0, 0, 92, 106, 255, 255 } },
        { ToneCurvePV2012 = curve })
    T.eq(same.checked, 1)
    T.eq(#same.mismatches, 0)

    local diff = ApplyDevelop.verify(
        fakePhoto { ToneCurvePV2012 = { 0, 0, 80, 106, 255, 255 } },
        { ToneCurvePV2012 = curve })
    T.eq(#diff.mismatches, 1)
    T.eq(mismatchOf(diff, "ToneCurvePV2012").note, "读回曲线与写入不一致")

    local short = ApplyDevelop.verify(
        fakePhoto { ToneCurvePV2012 = { 0, 0 } },
        { ToneCurvePV2012 = curve })
    T.eq(#short.mismatches, 1)
end)

T.case("读回里根本没有这个键 → 记为不一致（不能当通过）", function()
    local v = ApplyDevelop.verify(
        fakePhoto {},
        { Highlights2012 = -25, WhiteBalance = "Custom" })

    T.eq(v.checked, 0, "缺失的键不算比过")
    T.eq(#v.mismatches, 2, "两个键都应报不一致")
    T.eq(mismatchOf(v, "Highlights2012").note, "读回值缺失或类型不符")
end)

T.case("getDevelopSettings 报错 → readError，不抛穿", function()
    local photo = {
        getDevelopSettings = function() error("目录忙") end,
    }
    local v = ApplyDevelop.verify(photo, { Exposure2012 = 0.1 })
    T.truthy(v.readError, "应带出读取错误")
    T.contains(v.readError, "目录忙")
    T.eq(#v.mismatches, 0)
end)

T.case("无法比较的类型计入 unverified，不判失败", function()
    local v = ApplyDevelop.verify(
        fakePhoto { Weird = "x" },
        { Weird = function() end })
    T.eq(v.checked, 0)
    T.eq(v.unverified, 1)
    T.eq(#v.mismatches, 0)
end)

----------------------------------------------------------------------

T.suite("ApplyDevelop / summarizeVerify（能落盘的摘要）")

T.case("nil 摘要 → nil", function()
    T.eq(ApplyDevelop.summarizeVerify(nil), nil)
end)

T.case("明细按上限截断，但总数照实报", function()
    local mismatches = {}
    for i = 1, 25 do
        mismatches[#mismatches + 1] = { field = "F" .. i, want = i, got = i + 1 }
    end
    local s = ApplyDevelop.summarizeVerify(
        { checked = 30, unverified = 2, mismatches = mismatches, readError = nil }, 20)

    T.eq(s.checked, 30)
    T.eq(s.unverified, 2)
    T.eq(s.mismatchCount, 25, "总数不能因为截断而变小")
    T.eq(#s.mismatches, 20, "明细应截到上限")
end)

T.case("readError 会带出去", function()
    local s = ApplyDevelop.summarizeVerify({ checked = 0, mismatches = {}, readError = "读不到" })
    T.eq(s.readError, "读不到")
end)

----------------------------------------------------------------------

T.suite("JobRunner / 结果条目带校验结论")

T.case("verifyForJson：没有摘要就返回 nil（不写空块）", function()
    T.eq(JobRunner.verifyForJson(nil), nil)
end)

T.case("verifyForJson：无不一致时 fields 编码成 []", function()
    local j = JobRunner.verifyForJson {
        checked = 55, mismatchCount = 0, unverified = 0, mismatches = {},
    }
    T.eq(j.checked, 55)
    T.eq(j.mismatches, 0)
    T.contains(Json.encode(j), '"fields":[]', "空数组不能被编码成 null")
end)

T.case("verifyForJson：明细字段原样保留", function()
    local j = JobRunner.verifyForJson {
        checked = 3, mismatchCount = 1, unverified = 0,
        mismatches = { { field = "WhiteBalance", want = "Custom", got = "Daylight" } },
    }
    T.eq(j.mismatches, 1)
    T.eq(#j.fields, 1)
    T.eq(j.fields[1].field, "WhiteBalance")
    T.eq(j.fields[1].want, "Custom")
end)

T.case("applyOutcomeToEntry：applied / 历史步骤 / verify 都进条目", function()
    local entry = { photo = "C:/p/a.CR3" }
    JobRunner.applyOutcomeToEntry(entry, {
        ok          = true,
        stage       = "apply",
        skipped     = false,
        message     = "已应用 55 个 Develop 字段",
        applied     = 55,
        wouldApply  = 55,
        historyName = "AI Color: 海岸旷野-01-自然",
        counts      = { errors = 0, warnings = 4 },
        verifySummary = {
            checked = 55, mismatchCount = 0, unverified = 0, mismatches = {},
        },
    })

    T.eq(entry.ok, true)
    T.eq(entry.stage, "apply")
    T.eq(entry.applied, 55)
    T.eq(entry.warnings, 4)
    T.eq(entry.historyStep, "AI Color: 海岸旷野-01-自然")
    T.isTable(entry.verify, "结果条目必须带 verify")
    T.eq(entry.verify.checked, 55)
end)

T.case("applyOutcomeToEntry：dryRun 时没有 verify → 不硬塞", function()
    local entry = { photo = "C:/p/a.CR3" }
    JobRunner.applyOutcomeToEntry(entry, {
        ok = true, stage = "dryrun", skipped = false, applied = 0, wouldApply = 55,
        counts = {},
    })
    T.eq(entry.verify, nil)
    T.eq(entry.applied, 0)
    T.eq(entry.wouldApply, 55)
end)
