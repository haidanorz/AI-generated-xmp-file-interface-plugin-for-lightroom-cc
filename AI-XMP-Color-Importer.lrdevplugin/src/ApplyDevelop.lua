--[[
    src/ApplyDevelop.lua  —  把 settings 真正写进照片（Lightroom 适配层）

    已核实的 SDK API：
      LrPhoto:applyDevelopSettings( settings, optHistoryName, optFlattenAutoNow )   SDK 11.2+ 文档化
          settings          (table)  要应用的设置表
          optHistoryName    (string) 历史步骤名
          optFlattenAutoNow (boolean) true 时在本次调用内同步解析 Auto 设置
      LrPhoto:getDevelopSettings()  -> table（SDK 3.0+，**被官方标注为 experimental**）
      LrCatalog:withWriteAccessDo( actionName, func, timeoutParams )
          timeoutParams = { timeout = 秒数, callback = fn, asynchronous = bool }   SDK 4.0+
          返回 "executed" | "queued" | "aborted"

    安全约定：
      * 只调用 applyDevelopSettings —— 不创建 Preset、不 applyDevelopPreset、不改 XMP 文件
      * 一次操作只针对明确传入的那一张照片
      * settings 表在进入前由 DevelopSettings.toApplyTable() 过滤，杜绝未知键
      * 全程 pcall，任何失败都转成可读错误而不抛穿
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径）
local Utils      = AI_COLOR_IMPORTER.load("src/Utils.lua")
local XmpMapping = AI_COLOR_IMPORTER.load("src/XmpMapping.lua")

local ApplyDevelop = {}

----------------------------------------------------------------------
-- 延迟获取 Lightroom 模块（理由同 PhotoResolver：本文件需能在普通 Lua 环境被 require）
----------------------------------------------------------------------
local function getLr(name)
    return Utils.lrImport(name)
end

----------------------------------------------------------------------

--- 应用 develop settings
-- @param photo LrPhoto
-- @param settings table  仅含 SDK 键（务必先用 DevelopSettings.toApplyTable 过滤）
-- @param opts table {
--     historyName = string,  历史步骤名（默认 "AI Color"）
--     actionName  = string,  Undo 菜单名
--     timeout     = number,  获取写权限的超时秒数（默认 60）
--     verify      = boolean, 是否读回校验
--   }
-- @return result table { ok, message, writeResult, verify }
function ApplyDevelop.apply(photo, settings, opts)
    opts = opts or {}
    local historyName = opts.historyName or "AI Color"
    local actionName  = opts.actionName  or ("AI Color: " .. historyName)
    local timeout     = opts.timeout or 60

    local result = {
        ok          = false,
        message     = nil,
        writeResult = nil,
        verify      = nil,
        count       = 0,
    }

    if photo == nil then
        result.message = "目标照片为空"
        return result
    end

    local count = Utils.tcount(settings)
    result.count = count
    if count == 0 then
        result.message = "没有可应用的 Develop 字段"
        return result
    end

    ----------------------------------------------------------------
    -- 防御：settings 里只允许出现 FIELDS 中登记过的 SDK 键
    ----------------------------------------------------------------
    local illegal = {}
    for k in pairs(settings) do
        if XmpMapping.FIELDS[k] == nil then
            illegal[#illegal + 1] = tostring(k)
        end
    end
    if #illegal > 0 then
        table.sort(illegal)
        result.message = "拒绝写入：settings 中存在未登记的 SDK 键 -> " .. table.concat(illegal, ", ")
        result.ok = false
        return result
    end

    ----------------------------------------------------------------
    -- 写权限门 + applyDevelopSettings
    ----------------------------------------------------------------
    local LrApplication = getLr("LrApplication")
    if LrApplication == nil then
        result.message = "当前不在 Lightroom 运行时中，无法写入目录"
        return result
    end

    local catalog
    do
        local ok, c = Utils.safeCall("ai-color-apply-catalog", function()
            return LrApplication.activeCatalog()
        end)
        if not ok or c == nil then
            result.message = "无法访问 Lightroom 目录"
            return result
        end
        catalog = c
    end

    ----------------------------------------------------------------
    -- ★★★ 这里必须用 Utils.safeCall，不能用 Lua 原生 pcall ★★★
    --   catalog:withWriteAccessDo() 与 photo:applyDevelopSettings() 都会 yield，
    --   而原生 pcall 是 C 函数，跨 C 边界不让 yield —— 包住它们会直接报
    --   "Yielding is not allowed within a C or metamethod call"，
    --   也就是写入功能会整体失效。
    ----------------------------------------------------------------
    local writeResult = nil
    local ok, errMsg = Utils.safeCall("ai-color-apply-develop", function()
        writeResult = catalog:withWriteAccessDo(actionName, function()
            -- 关键调用：这里不会创建任何 Preset，也不会写 XMP 文件
            photo:applyDevelopSettings(settings, historyName, nil)
        end, { timeout = timeout })
    end)

    if not ok then
        result.ok = false
        result.message = "写入 Develop 设置失败：" .. tostring(errMsg)
        return result
    end

    -- withWriteAccessDo 在 SDK 4.0+ 会返回 "executed" / "queued" / "aborted"
    result.writeResult = writeResult
    if writeResult == "aborted" then
        result.ok = false
        result.message = "未能在 " .. timeout .. " 秒内取得目录写权限（Lightroom 可能正在执行其它操作），操作已放弃"
        return result
    end

    result.ok = true
    result.message = string.format("已应用 %d 个 Develop 字段（历史步骤：%s）", count, historyName)

    ----------------------------------------------------------------
    -- 读回校验（可选）
    -- 注意：SDK 把 develop settings API 标注为 experimental，且社区已多次报告
    --       读回值存在滞后。因此这里的不一致只作为提示，绝不影响成功判定。
    ----------------------------------------------------------------
    if opts.verify then
        result.verify = ApplyDevelop.verify(photo, settings)
    end

    return result
end

----------------------------------------------------------------------

--- 数值容差：Lightroom 内部对滑块值有精度截断（例如 0.35 读回 0.349999）
local NUMBER_TOLERANCE = 0.02

--- 枚举 / 字符串比较：忽略首尾空白与大小写（"Custom" vs "custom"）
local function sameText(a, b)
    return string.lower(Utils.trim(tostring(a))) == string.lower(Utils.trim(tostring(b)))
end

--- 读回并比对。返回 { checked, unverified, mismatches = {...}, readError }
--
--  比对规则（按写入值的类型分派，全部类型都要比 —— 早期版本只比 number 与曲线，
--  导致 WhiteBalance / ConvertToGrayscale / ToneCurveName2012 这几个枚举与布尔字段
--  实际上从未被校验过）：
--    number  → 容差 0.02
--    boolean → 严格相等
--    string  → 忽略大小写与空白
--    table   → 曲线逐点（容差 0.01）
--    其它    → 计入 unverified（不判失败，只说明"没法比"）
function ApplyDevelop.verify(photo, settings)
    local out = { checked = 0, unverified = 0, mismatches = {}, readError = nil }

    -- 给 Lightroom 一点时间落库（getDevelopSettings 的读回滞后是已知现象）
    -- ★ LrTasks.sleep 是 yield 型调用，必须走 safeCall
    Utils.safeCall("ai-color-verify-sleep", function()
        local LrTasks = getLr("LrTasks")
        if LrTasks and type(LrTasks.sleep) == "function" then
            LrTasks.sleep(0.3)
        end
    end)

    local ok, current = Utils.safeCall("ai-color-get-develop-settings", function()
        return photo:getDevelopSettings()
    end)
    if not ok or type(current) ~= "table" then
        out.readError = "getDevelopSettings() 读取失败：" .. tostring(current)
        return out
    end

    for _, key in ipairs(Utils.sortedKeys(settings)) do
        local want = settings[key]
        local got  = current[key]
        local wt   = type(want)

        if wt == "number" then
            if type(got) == "number" then
                out.checked = out.checked + 1
                if math.abs(want - got) > NUMBER_TOLERANCE then
                    out.mismatches[#out.mismatches + 1] = {
                        field = key, want = want, got = got,
                    }
                end
            else
                out.mismatches[#out.mismatches + 1] = {
                    field = key, want = want, got = tostring(got),
                    note = "读回值缺失或类型不符",
                }
            end
        elseif wt == "boolean" then
            if type(got) == "boolean" then
                out.checked = out.checked + 1
                if want ~= got then
                    out.mismatches[#out.mismatches + 1] = {
                        field = key, want = tostring(want), got = tostring(got),
                    }
                end
            else
                out.mismatches[#out.mismatches + 1] = {
                    field = key, want = tostring(want), got = tostring(got),
                    note = "读回值缺失或类型不符",
                }
            end
        elseif wt == "string" then
            if type(got) == "string" then
                out.checked = out.checked + 1
                if not sameText(want, got) then
                    out.mismatches[#out.mismatches + 1] = {
                        field = key, want = want, got = got,
                    }
                end
            else
                out.mismatches[#out.mismatches + 1] = {
                    field = key, want = want, got = tostring(got),
                    note = "读回值缺失或类型不符",
                }
            end
        elseif wt == "table" then
            -- 曲线：逐点比对
            if type(got) == "table" and #got == #want then
                out.checked = out.checked + 1
                local same = true
                for i = 1, #want do
                    if math.abs(want[i] - got[i]) > 0.01 then
                        same = false
                        break
                    end
                end
                if not same then
                    out.mismatches[#out.mismatches + 1] = {
                        field = key, want = "(曲线)", got = "(曲线)",
                        note = "读回曲线与写入不一致",
                    }
                end
            else
                out.mismatches[#out.mismatches + 1] = {
                    field = key, want = "(曲线)", got = tostring(got),
                    note = "读回曲线缺失或长度不符",
                }
            end
        else
            out.unverified = out.unverified + 1
        end
    end

    return out
end

----------------------------------------------------------------------

--- 把 verify 结果压成「可落盘 / 可进结果 JSON」的小表
--  原因：读回校验的价值全在「哪个字段没落地」，而日志在 Lightroom 里
--        不保证可见（LrLogger 的 logfile 在本机不生成文件），
--        所以必须能跟着 result.json 一起出去。
-- @param v ApplyDevelop.verify 的返回值
-- @param limit 最多保留多少条明细（默认 20，防止曲线等大字段把 JSON 撑爆）
-- @return summary table|nil { checked, mismatchCount, unverified, readError, mismatches }
function ApplyDevelop.summarizeVerify(v, limit)
    if type(v) ~= "table" then
        return nil
    end
    limit = limit or 20

    local all = v.mismatches or {}
    local list = {}
    for i = 1, #all do
        if i > limit then break end
        local m = all[i]
        list[#list + 1] = {
            field = m.field,
            want  = m.want,
            got   = m.got,
            note  = m.note,
        }
    end

    local summary = {
        checked       = v.checked or 0,
        mismatchCount = #all,
        unverified    = v.unverified or 0,
        mismatches    = list,
    }
    if v.readError then
        summary.readError = tostring(v.readError)
    end
    return summary
end

----------------------------------------------------------------------

--- 应用后把 Lightroom 切到 Develop 模块，方便用户立刻看到结果
function ApplyDevelop.goToDevelopModule()
    local ok = Utils.safeCall("ai-color-goto-develop", function()
        local LrApplicationView = Utils.lrImport("LrApplicationView")
        if LrApplicationView then
            LrApplicationView.showDevelopModule()
        end
    end)
    return ok
end

--- 在 Develop 模块激活时读取某个参数的真实取值范围（可选增强）
-- @return min, max  （失败时返回 nil）
function ApplyDevelop.getParamRange(param)
    local ok, mn, mx = Utils.safeCall("ai-color-get-range", function()
        local LrDevelopController = Utils.lrImport("LrDevelopController")
        if not LrDevelopController then
            return nil
        end
        return LrDevelopController.getRange(param)
    end)
    if ok and type(mn) == "number" and type(mx) == "number" then
        return mn, mx
    end
    return nil, nil
end

return ApplyDevelop
