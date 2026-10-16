--[[
    src/Validation.lua  —  数值范围与合法性校验（纯 Lua）

    策略（原则：正确性 > 可解释性 > 安全性）
        明显非法（非数值 / NaN / Infinity / 离谱到不可能是笔误）  -> ERROR，字段被丢弃
        轻微超范围                                              -> CLAMP + WARNING
        未知字段                                                -> WARNING（在 Mapping 层记录）
        非法枚举                                                -> ERROR（在 convertValue 中记录）

    ★ 不擅自创造 Lightroom 参数范围 ★
      FIELDS 里的 range 一律标记为「建议区间」（advisory）。
      运行时若已注入 LrDevelopController.getRange 的真实范围，
      则以真实范围为准（见 XmpMapping.applyRuntimeRanges）。

    Lua 5.1 兼容。
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径）
local Utils      = AI_COLOR_IMPORTER.load("src/Utils.lua")
local XmpMapping = AI_COLOR_IMPORTER.load("src/XmpMapping.lua")

local Validation = {}

--- 「离谱」倍率：超出建议区间 span 的这个倍数即判 ERROR 而非 CLAMP。
-- 取 1 倍 span，即允许区间外最多再偏移一个区间宽度。
Validation.ABSURD_SPAN_MULTIPLIER = 1.0

--- 色温这类无静态范围的字段的合理性边界
Validation.TEMPERATURE_SANE = { 500, 100000 }

----------------------------------------------------------------------

--- 校验并收拢一个 Mapping 结果
-- @param bundle table XmpMapping.toDevelopSettings 的输出
-- @param opts table|nil {
--     runtimeRanges = { [sdkKey] = {min,max} },   -- 来自 LrDevelopController.getRange
--     logger = Logger|nil,
--   }
-- @return result table  与 bundle 同构，但 settings 已收拢、errors/clamped 已补齐
function Validation.validate(bundle, opts)
    opts = opts or {}
    local runtimeRanges = opts.runtimeRanges or {}

    -- 深拷贝一层，避免修改调用方数据
    local result = {
        settings    = {},
        applied     = {},
        clamped     = {},
        ignored     = {},
        unsupported = {},
        knownNative = {},
        unknown     = {},
        errors      = {},
        warnings    = {},
        skipped     = {},
        schema      = bundle.schema,
        meta        = bundle.meta,
        rangeSource = {},
    }

    for k, v in pairs(bundle.settings or {})      do result.settings[k] = v end
    for _, v in ipairs(bundle.applied or {})      do result.applied[#result.applied + 1] = v end
    for _, v in ipairs(bundle.ignored or {})      do result.ignored[#result.ignored + 1] = v end
    for _, v in ipairs(bundle.knownNative or {})  do result.knownNative[#result.knownNative + 1] = v end
    for _, v in ipairs(bundle.unsupported or {})  do result.unsupported[#result.unsupported + 1] = v end
    for _, v in ipairs(bundle.unknown or {})      do result.unknown[#result.unknown + 1] = v end
    for _, v in ipairs(bundle.errors or {})       do result.errors[#result.errors + 1] = v end
    for _, v in ipairs(bundle.warnings or {})     do result.warnings[#result.warnings + 1] = v end
    for _, v in ipairs(bundle.skipped or {})      do result.skipped[#result.skipped + 1] = v end

    ----------------------------------------------------------------
    -- 逐个 SDK 键校验
    ----------------------------------------------------------------
    local finalSettings = {}
    local dropped = {}

    for _, sdkKey in ipairs(Utils.sortedKeys(bundle.settings or {})) do
        local value = bundle.settings[sdkKey]
        local def = XmpMapping.FIELDS[sdkKey]

        if def == nil then
            -- 理论上不会发生（Mapping 层只写 FIELDS 里的键），做防御性告警
            result.warnings[#result.warnings + 1] =
                string.format("SDK 键 %s 没有对应的字段定义，已丢弃", sdkKey)
            dropped[#dropped + 1] = sdkKey

        elseif def.type == "boolean" or def.type == "string" or def.type == "enum" then
            -- 注意：不能拿「转换结果」当成功标志 —— parseBoolean 对合法输入会返回 false，
            -- 那是一个合法值而不是失败。必须用 nil 判定。
            if def.type == "boolean" then
                local converted, err = Utils.parseBoolean(value)
                if converted == nil then
                    result.errors[#result.errors + 1] = {
                        field = sdkKey, rawValue = value,
                        message = "无法转换为布尔值：" .. tostring(err),
                    }
                    dropped[#dropped + 1] = sdkKey
                else
                    finalSettings[sdkKey] = converted
                end
            else
                if value == nil then
                    result.errors[#result.errors + 1] = {
                        field = sdkKey,
                        message = "值为空，无法作为 " .. tostring(def.type) .. " 写入",
                    }
                    dropped[#dropped + 1] = sdkKey
                else
                    finalSettings[sdkKey] = value
                end
            end

        elseif def.type == "toneCurve" then
            if type(value) ~= "table" or #value < 4 or (#value % 2) ~= 0 then
                result.errors[#result.errors + 1] = {
                    field = sdkKey,
                    message = "色调曲线必须是长度为偶数的数字数组（至少 4 项）",
                }
                dropped[#dropped + 1] = sdkKey
            else
                local bad = false
                for i, n in ipairs(value) do
                    if type(n) ~= "number" or n ~= n then
                        bad = true
                        result.errors[#result.errors + 1] = {
                            field = sdkKey,
                            message = string.format("曲线第 %d 项不是合法数字", i),
                        }
                        break
                    end
                end
                if bad then
                    dropped[#dropped + 1] = sdkKey
                else
                    finalSettings[sdkKey] = value
                end
            end

        elseif def.type == "number" then
            -- 1) 类型与 NaN 检查
            if type(value) ~= "number" then
                result.errors[#result.errors + 1] = {
                    field = sdkKey, rawValue = value,
                    message = "不是合法数值（类型 " .. type(value) .. "）",
                }
                dropped[#dropped + 1] = sdkKey

            elseif value ~= value then
                result.errors[#result.errors + 1] = {
                    field = sdkKey, rawValue = "NaN",
                    message = "NaN 不是合法数值",
                }
                dropped[#dropped + 1] = sdkKey

            elseif value == math.huge or value == -math.huge then
                result.errors[#result.errors + 1] = {
                    field = sdkKey, rawValue = tostring(value),
                    message = "Infinity 不是合法数值",
                }
                dropped[#dropped + 1] = sdkKey

            else
                -- 2) 范围检查
                local range = runtimeRanges[sdkKey] or def.range
                local source = runtimeRanges[sdkKey] and "runtime(getRange)" or "static(advisory)"
                result.rangeSource[sdkKey] = source

                if sdkKey == "Temperature" and range == nil then
                    -- 特例：色温无静态范围，只做合理性检查
                    local sane = Validation.TEMPERATURE_SANE
                    if value < sane[1] or value > sane[2] then
                        result.errors[#result.errors + 1] = {
                            field = sdkKey, rawValue = value,
                            message = string.format(
                                "色温 %s K 明显非法（合理区间 %d..%d K）",
                                tostring(value), sane[1], sane[2]),
                        }
                        dropped[#dropped + 1] = sdkKey
                    else
                        finalSettings[sdkKey] = value
                    end

                elseif range ~= nil then
                    local mn, mx = range[1], range[2]
                    local span = mx - mn

                    if value < mn or value > mx then
                        local absurdLo = mn - span * Validation.ABSURD_SPAN_MULTIPLIER
                        local absurdHi = mx + span * Validation.ABSURD_SPAN_MULTIPLIER

                        if value < absurdLo or value > absurdHi then
                            result.errors[#result.errors + 1] = {
                                field = sdkKey, rawValue = value,
                                message = string.format(
                                    "数值 %s 明显非法（合法区间 %s..%s，已超出可容错范围）",
                                    Utils.formatPlain(value), Utils.formatPlain(mn), Utils.formatPlain(mx)),
                            }
                            dropped[#dropped + 1] = sdkKey
                        else
                            local clampedValue = (value < mn) and mn or mx
                            finalSettings[sdkKey] = clampedValue
                            result.clamped[#result.clamped + 1] = {
                                field = sdkKey,
                                sdkField = sdkKey,
                                rawValue = value,
                                value = clampedValue,
                                min = mn,
                                max = mx,
                                direction = (value < mn) and "below" or "above",
                            }
                        end
                    else
                        finalSettings[sdkKey] = value
                    end
                else
                    -- 无范围信息：放行
                    finalSettings[sdkKey] = value
                end
            end

        else
            -- 未知类型：放行但告警
            result.warnings[#result.warnings + 1] =
                string.format("字段 %s 的类型 %s 未知，未做范围校验", sdkKey, tostring(def.type))
            finalSettings[sdkKey] = value
        end
    end

    ----------------------------------------------------------------
    -- 丢弃记录（使 applied 与实际写入保持一致）
    ----------------------------------------------------------------
    if #dropped > 0 then
        local keep = {}
        for _, item in ipairs(result.applied) do
            local isDropped = false
            for _, k in ipairs(dropped) do
                if item.sdkField == k then
                    isDropped = true
                    break
                end
            end
            if not isDropped then
                keep[#keep + 1] = item
            end
        end
        result.applied = keep
    end

    result.settings = finalSettings

    ----------------------------------------------------------------
    -- 冒烟检查
    ----------------------------------------------------------------
    if Utils.tcount(finalSettings) == 0 then
        result.warnings[#result.warnings + 1] = "没有可应用的 Develop 字段"
    end

    ----------------------------------------------------------------
    -- 统计与结论
    ----------------------------------------------------------------
    local counts = {
        applied     = #result.applied,
        clamped     = #result.clamped,
        ignored     = #result.ignored + #result.skipped,
        unsupported = #result.unsupported,
        knownNative = #result.knownNative,
        unknown     = #result.unknown,
        errors      = #result.errors,
        warnings    = #result.warnings,
        settings    = Utils.tcount(finalSettings),
    }
    result.counts = counts
    result.ok = (counts.errors == 0) and (counts.settings > 0)
    result.applicable = counts.settings > 0

    -- 仅有 clamp 而没有其它问题时也允许应用
    if counts.errors > 0 then
        result.ok = false
    end

    return result
end

----------------------------------------------------------------------

--- 把校验结果压缩成给用户看的一句话结论
function Validation.summarize(result)
    local c = result.counts or {}
    local parts = {}
    parts[#parts + 1] = string.format("可应用字段 %d", c.settings or 0)
    if (c.clamped or 0) > 0     then parts[#parts + 1] = string.format("收拢 %d", c.clamped) end
    if (c.ignored or 0) > 0     then parts[#parts + 1] = string.format("忽略 %d", c.ignored) end
    if (c.unsupported or 0) > 0 then parts[#parts + 1] = string.format("不支持 %d", c.unsupported) end
    if (c.warnings or 0) > 0    then parts[#parts + 1] = string.format("警告 %d", c.warnings) end
    if (c.errors or 0) > 0      then parts[#parts + 1] = string.format("错误 %d", c.errors) end
    return table.concat(parts, " · ")
end

return Validation
