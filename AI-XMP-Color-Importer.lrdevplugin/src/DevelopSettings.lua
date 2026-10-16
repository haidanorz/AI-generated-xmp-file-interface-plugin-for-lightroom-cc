--[[
    src/DevelopSettings.lua  —  最终 settings 装配 + 人类可读 Preview（纯 Lua）

    职责边界：
      * 把 Validation 的输出压成一张「只含 SDK 键」的纯 settings 表，直接交给
        photo:applyDevelopSettings()。
      * 生成 Apply 前的 Preview 文本与结果摘要。
      * 不访问 Lightroom，不做 IO。

    Lua 5.1 兼容。
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径）
local Utils      = AI_COLOR_IMPORTER.load("src/Utils.lua")
local XmpMapping = AI_COLOR_IMPORTER.load("src/XmpMapping.lua")

local DevelopSettings = {}

----------------------------------------------------------------------
-- 装配
----------------------------------------------------------------------

--- 从校验结果取出可直接交给 SDK 的 settings 表（浅拷贝，避免外部改动）
function DevelopSettings.toApplyTable(result)
    local out = {}
    local defs = XmpMapping.FIELDS
    for _, key in ipairs(Utils.sortedKeys(result.settings or {})) do
        local def = defs[key]
        -- 只放行「已定义 + 类型可写」的键，杜绝意外键进入 SDK
        if def then
            out[key] = result.settings[key]
        end
    end
    return out
end

--- 统计给 UI 用的摘要
function DevelopSettings.summary(result)
    local c = result.counts or {}
    return {
        fields      = c.settings or 0,
        applied     = c.applied or 0,
        clamped     = c.clamped or 0,
        ignored     = c.ignored or 0,
        unsupported = c.unsupported or 0,
        warnings    = c.warnings or 0,
        errors      = c.errors or 0,
    }
end

--- 把 applied 列表按 group 分桶，并按 GROUP_ORDER 排序
function DevelopSettings.groupApplied(result)
    local buckets = {}
    for _, item in ipairs(result.applied or {}) do
        local g = item.group or "basic"
        buckets[g] = buckets[g] or {}
        buckets[g][#buckets[g] + 1] = item
    end

    local order = XmpMapping.GROUP_ORDER
    local seen = {}
    local ordered = {}
    for _, g in ipairs(order) do
        if buckets[g] then
            ordered[#ordered + 1] = { group = g, label = XmpMapping.GROUP_LABEL[g] or g, items = buckets[g] }
            seen[g] = true
        end
    end
    -- 兜底：GROUP_ORDER 之外的组
    for _, g in ipairs(Utils.sortedKeys(buckets)) do
        if not seen[g] then
            ordered[#ordered + 1] = { group = g, label = XmpMapping.GROUP_LABEL[g] or g, items = buckets[g] }
        end
    end
    return ordered
end

----------------------------------------------------------------------
-- Preview
----------------------------------------------------------------------

local function valueText(def, value)
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    if type(value) == "table" then
        -- 色调曲线：显示成点对
        local pts = {}
        local i = 1
        while i < #value do
            pts[#pts + 1] = string.format("(%s, %s)",
                Utils.formatPlain(value[i]), Utils.formatPlain(value[i + 1]))
            i = i + 2
        end
        return table.concat(pts, " ")
    end
    if def and def.group == "whitebalance" and def.sdk == "Temperature" then
        return Utils.formatPlain(value) .. " K"
    end
    if def and def.group == "colorgrading" then
        -- 色相显示 0-360 无符号；饱和度 / 亮度带符号
        local isHue = def.sdk:match("Hue$") ~= nil
        local isSat = def.sdk:match("Sat$") ~= nil or def.sdk:match("Saturation$") ~= nil
        if isHue or isSat then
            return Utils.formatPlain(value)
        end
    end
    return Utils.formatSigned(value)
end

--- 生成 Preview 文本行数组
-- @param result table Validation 的输出
-- @param opts table|nil { locale = "zh"|"en", includeZero = boolean }
function DevelopSettings.previewLines(result, opts)
    opts = opts or {}
    local locale = opts.locale or "en"
    local includeZero = opts.includeZero and true or false

    local lines = {}
    local groups = DevelopSettings.groupApplied(result)

    for _, g in ipairs(groups) do
        lines[#lines + 1] = "-- " .. g.label
        for _, item in ipairs(g.items) do
            local def = XmpMapping.FIELDS[item.sdkField]
            local name = item.display or item.sdkField
            if locale == "zh" and def and def.displayZh then
                name = def.displayZh
            end

            local value = item.value
            local skip = false
            if not includeZero and type(value) == "number" and value == 0 then
                -- 零值默认不展示，避免 Preview 塞满无意义的 0
                skip = true
            end
            if not skip then
                lines[#lines + 1] = string.format("%-30s %12s", name, valueText(def, value))
            end
        end
        lines[#lines + 1] = ""
    end

    -- 去掉尾部空行
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    return lines
end

--- 生成完整 Preview 文本
-- @param result table Validation 的输出
-- @param ctx table|nil { photoName, xmpName, sourceFile, presetName }
function DevelopSettings.renderPreview(result, ctx)
    ctx = ctx or {}
    local out = {}
    out[#out + 1] = "AI Color Plan"
    out[#out + 1] = string.rep("-", 46)

    if ctx.presetName then
        out[#out + 1] = "Preset      : " .. tostring(ctx.presetName)
    end
    if ctx.photoName then
        out[#out + 1] = "Target Photo: " .. tostring(ctx.photoName)
    end
    if ctx.xmpName then
        out[#out + 1] = "XMP File    : " .. tostring(ctx.xmpName)
    end
    if ctx.sourceFile then
        out[#out + 1] = "XMP Source  : " .. tostring(ctx.sourceFile)
    end
    out[#out + 1] = string.rep("-", 46)

    local lines = DevelopSettings.previewLines(result)
    for _, l in ipairs(lines) do
        out[#out + 1] = l
    end

    out[#out + 1] = string.rep("-", 46)

    local c = result.counts or {}
    out[#out + 1] = string.format(
        "Fields: %d    Warnings: %d    Unsupported: %d    Errors: %d",
        c.settings or 0, c.warnings or 0, c.unsupported or 0, c.errors or 0)

    if (c.clamped or 0) > 0 then
        out[#out + 1] = string.format("Clamped: %d （超范围值已收拢到合法区间）", c.clamped)
    end

    ----------------------------------------------------------------
    -- 附上问题清单
    ----------------------------------------------------------------
    if #(result.errors or {}) > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "Errors"
        for _, e in ipairs(result.errors) do
            out[#out + 1] = string.format("  %s: %s", tostring(e.field or "-"), tostring(e.message or e.reason or "?"))
        end
    end

    if #(result.unsupported or {}) > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "Unsupported XMP field"
        for _, u in ipairs(result.unsupported) do
            out[#out + 1] = string.format("  %s  — %s", tostring(u.field), tostring(u.reason or ""))
        end
    end

    if #(result.skipped or {}) > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "Skipped (extended fields not enabled)"
        for _, s in ipairs(result.skipped) do
            out[#out + 1] = string.format("  %s  — %s", tostring(s.field), tostring(s.reason or ""))
        end
    end

    if #(result.warnings or {}) > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "Warnings"
        for _, w in ipairs(result.warnings) do
            out[#out + 1] = "  " .. tostring(w)
        end
    end

    return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- 与 Logger 的桥接
----------------------------------------------------------------------

--- 把一次 Apply 的结果整理成 Logger.buildApplyReport 需要的结构
function DevelopSettings.buildReportRecord(result, ctx)
    ctx = ctx or {}
    local applied = {}
    for _, item in ipairs(result.applied or {}) do
        applied[#applied + 1] = {
            field    = item.field,
            sdkField = item.sdkField,
            rawValue = (type(item.rawValue) == "table")
                and "(序列)" or tostring(item.rawValue),
            value    = (type(item.value) == "table")
                and DevelopSettings.valueTextPublic(nil, item.value) or tostring(item.value),
        }
    end

    local ignored = {}
    for _, it in ipairs(result.ignored or {}) do
        ignored[#ignored + 1] = { field = it.field, reason = it.reason }
    end
    for _, it in ipairs(result.skipped or {}) do
        ignored[#ignored + 1] = { field = it.field, reason = it.reason }
    end

    local unsupported = {}
    for _, it in ipairs(result.unsupported or {}) do
        -- 必须保留 kind：Logger 靠它把「已知 LR 原生字段」与「真正未知字段」分开
        unsupported[#unsupported + 1] = {
            field = it.field, reason = it.reason, kind = it.kind,
        }
    end

    local errors = {}
    for _, it in ipairs(result.errors or {}) do
        errors[#errors + 1] = { field = it.field, message = it.message }
    end

    return {
        operation     = ctx.operation or "APPLY",
        timestamp     = ctx.timestamp or Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0),
        photo         = ctx.photoName,
        xmp           = ctx.xmpName,
        presetName    = ctx.presetName,
        sourceFile    = ctx.sourceFile,
        aiVersion     = ctx.aiVersion,
        schemaVersion = result.schema and result.schema.version or nil,
        applied       = applied,
        clamped       = result.clamped,
        ignored       = ignored,
        unsupported   = unsupported,
        errors        = errors,
        result        = ctx.result or "UNKNOWN",
    }
end

function DevelopSettings.valueTextPublic(def, value)
    return valueText(def, value)
end

return DevelopSettings
