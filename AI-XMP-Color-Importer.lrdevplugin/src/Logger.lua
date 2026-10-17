--[[
    src/Logger.lua  —  日志与结构化报告层

    要求：
        日志至少包含 timestamp / operation / photo / xmp / field /
        rawValue / convertedValue / result

    设计：
      * 双后端：内存环形缓冲（供 UI 直接展示）+ 可选 Lightroom LrLogger（落盘）。
      * 普通 Lua 环境下自动退化为 stdout 输出，以便单元测试无副作用地运行。
      * 绝不因为日志失败而中断业务流程（全部 pcall 包裹）。

    Lua 5.1 兼容。
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径，
-- 详见 src/Loader.lua 顶部引用的官方原文）
local Utils = AI_COLOR_IMPORTER.load("src/Utils.lua")

local Logger = {}

Logger.LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
Logger.LEVEL_ORDER = { "debug", "info", "warn", "error" }

local state = {
    level       = "info",
    entries     = {},      -- 环形缓冲（数组）
    maxEntries  = 500,
    lrLogger    = nil,     -- Lightroom LrLogger 对象（可选）
    echo        = false,   -- 是否同时 print 到 stdout（LR 内默认关闭）
    operationId = 0,
}

----------------------------------------------------------------------
-- 配置
----------------------------------------------------------------------

--- @param opts table { level, maxEntries, echo, lrLogger }
function Logger.configure(opts)
    opts = opts or {}
    if opts.level and Logger.LEVELS[opts.level] then
        state.level = opts.level
    end
    if type(opts.maxEntries) == "number" and opts.maxEntries > 0 then
        state.maxEntries = opts.maxEntries
    end
    if opts.echo ~= nil then
        state.echo = opts.echo and true or false
    end
    if opts.lrLogger ~= nil then
        state.lrLogger = opts.lrLogger
    end
    return Logger
end

--- 尝试挂接 Lightroom 的 LrLogger（在 LR 环境由 Main.lua 调用）
-- 任何失败都被吞掉，只影响落盘，不影响功能。
function Logger.attachLightroom(name)
    if type(name) ~= "string" then
        return false
    end
    local ok, lrLogger = pcall(function()
        local LrLogger = import "LrLogger"
        local lg = LrLogger(name)
        -- "logfile" 会把日志写到 <目录文件夹>/Lightroom Logs/<name>.log
        lg:enable("logfile")
        return lg
    end)
    if ok and lrLogger then
        state.lrLogger = lrLogger
        return true
    end
    return false
end

function Logger.setLevel(level)
    if Logger.LEVELS[level] then
        state.level = level
    end
end

function Logger.getLevel()
    return state.level
end

----------------------------------------------------------------------
-- 写入
----------------------------------------------------------------------

local function push(entry)
    local buf = state.entries
    buf[#buf + 1] = entry
    -- 环形裁剪
    local over = #buf - state.maxEntries
    if over > 0 then
        for i = 1, over do
            table.remove(buf, 1)
        end
    end
end

local function forward(line, level)
    if state.lrLogger then
        pcall(function()
            local fn = state.lrLogger[level]
            if type(fn) == "function" then
                fn(state.lrLogger, line)
            else
                state.lrLogger:info(line)
            end
        end)
    end
    if state.echo or not state.lrLogger then
        pcall(function()
            print(line)
        end)
    end
end

--- 核心写入
-- @param level string debug|info|warn|error
-- @param message string 人类可读消息
-- @param context table|nil 结构化上下文（field / rawValue / convertedValue / photo / xmp ...）
function Logger.emit(level, message, context)
    level = level or "info"
    if not Logger.LEVELS[level] then
        level = "info"
    end

    -- 低于当前配置级别的日志直接丢弃。
    -- 默认级别是 info，因此字段级的 debug 日志（每次 Apply 有几十条）不会进日志文件，
    -- 只在需要排错时把级别调成 debug 才看得到。
    local threshold = Logger.LEVELS[state.level] or Logger.LEVELS.info
    if Logger.LEVELS[level] < threshold then
        return nil
    end

    local now = Utils.platform.now and Utils.platform.now() or 0
    local ts = Utils.timestamp(now)
    local line = string.format("[%s] %-5s %s", ts, level:upper(), tostring(message))

    local entry = {
        time      = now,
        timestamp = ts,
        level     = level,
        message   = tostring(message),
        context   = context,
        line      = line,
    }
    push(entry)

    -- 若 context 带 field 信息，把 rawValue/convertedValue 也追加到落盘行
    local extra = ""
    if type(context) == "table" then
        local bits = {}
        if context.operation then bits[#bits + 1] = "op=" .. tostring(context.operation) end
        if context.field     then bits[#bits + 1] = "field=" .. tostring(context.field) end
        if context.sdkField  then bits[#bits + 1] = "sdk=" .. tostring(context.sdkField) end
        if context.rawValue ~= nil then bits[#bits + 1] = "raw=" .. tostring(context.rawValue) end
        if context.convertedValue ~= nil then bits[#bits + 1] = "converted=" .. tostring(context.convertedValue) end
        if context.result then bits[#bits + 1] = "result=" .. tostring(context.result) end
        if #bits > 0 then
            extra = "  {" .. table.concat(bits, ", ") .. "}"
        end
    end

    forward(line .. extra, level)
    return entry
end

function Logger.debug(message, context) return Logger.emit("debug", message, context) end
function Logger.info(message, context)  return Logger.emit("info",  message, context) end
function Logger.warn(message, context)  return Logger.emit("warn",  message, context) end
function Logger.error(message, context) return Logger.emit("error", message, context) end

--- 生成一次操作的编号，便于把同一批日志串起来
function Logger.nextOperationId()
    state.operationId = state.operationId + 1
    return state.operationId
end

----------------------------------------------------------------------
-- 读取 / 清空
----------------------------------------------------------------------

function Logger.getEntries()
    return state.entries
end

function Logger.clear()
    state.entries = {}
end

--- 把最近的日志拼成文本（供 UI「查看日志」使用）
-- @param maxLines number|nil 只取末尾 N 行
function Logger.dump(maxLines)
    local out = {}
    local buf = state.entries
    local startAt = 1
    if maxLines and #buf > maxLines then
        startAt = #buf - maxLines + 1
    end
    for i = startAt, #buf do
        out[#out + 1] = buf[i].line
    end
    return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- 结构化报告（APPLY 块）
----------------------------------------------------------------------

--- 生成一次 Apply 操作的完整报告文本
-- @param rec table {
--     operation = "APPLY",
--     timestamp = ...,
--     photo = "IMG_1023.CR3",
--     xmp = "IMG_1023__Natural_Warm__AI-v1.xmp",
--     presetName = "Natural Warm",
--     sourceFile = "IMG_1023.CR3",
--     aiVersion = "portrait-color-v1",
--     schemaVersion = "1.0",
--     applied = { {field=, sdkField=, rawValue=, value=} , ... },
--     clamped = { {field=, rawValue=, value=, min=, max=} , ... },
--     ignored = { "-- 或 {field=, reason=}" , ... },
--     unsupported = { ... },
--     errors = { ... },
--     result = "SUCCESS" | "FAILED",
--   }
-- @param verbose boolean 是否输出每一条 raw -> converted 明细
function Logger.buildApplyReport(rec, verbose)
    rec = rec or {}
    local L = {}
    local function add(s) L[#L + 1] = s end

    add("[" .. (rec.timestamp or Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0)) .. "]")
    add(tostring(rec.operation or "APPLY"))
    add("")

    if rec.presetName then
        add("Preset:")
        add("  " .. tostring(rec.presetName))
        add("")
    end

    add("Photo:")
    add("  " .. tostring(rec.photo or "(未知)"))
    add("")

    add("XMP:")
    add("  " .. tostring(rec.xmp or "(未知)"))
    add("")

    if rec.sourceFile then
        add("XMP SourceFile:")
        add("  " .. tostring(rec.sourceFile))
        add("")
    end

    if rec.aiVersion then
        add("AI Version:")
        add("  " .. tostring(rec.aiVersion))
        add("")
    end

    if rec.schemaVersion then
        add("AI Color Schema:")
        add("  " .. tostring(rec.schemaVersion))
        add("")
    end

    ------------------------------------------------------------------
    local applied = rec.applied or {}
    add(string.format("Applied: %d setting(s)", #applied))
    for _, it in ipairs(applied) do
        if verbose then
            add(string.format(
                "  %s = %s -> %s = %s",
                tostring(it.field), tostring(it.rawValue),
                tostring(it.sdkField or it.field), tostring(it.value)))
        elseif it.sdkField and it.sdkField ~= it.field then
            add(string.format("  %s -> %s = %s", it.field, it.sdkField, tostring(it.value)))
        else
            add(string.format("  %s = %s", it.field, tostring(it.value)))
        end
    end
    add("")

    ------------------------------------------------------------------
    local clamped = rec.clamped or {}
    if #clamped > 0 then
        add(string.format("Clamped (轻微超范围，已收拢到合法区间): %d", #clamped))
        for _, it in ipairs(clamped) do
            add(string.format("  %s: %s -> %s  (合法区间 %s .. %s)",
                tostring(it.field), tostring(it.rawValue), tostring(it.value),
                tostring(it.min), tostring(it.max)))
        end
        add("")
    end

    ------------------------------------------------------------------
    local ignored = rec.ignored or {}
    if #ignored > 0 then
        add(string.format("Ignored (元数据 / 不参与 Develop): %d", #ignored))
        for _, it in ipairs(ignored) do
            if type(it) == "table" then
                add("  " .. tostring(it.field) .. (it.reason and ("  — " .. tostring(it.reason)) or ""))
            else
                add("  " .. tostring(it))
            end
        end
        add("")
    end

    ------------------------------------------------------------------
    local unsupported = rec.unsupported or {}
    if #unsupported > 0 then
        -- 分成两组：
        --   · 已知的 Lightroom 原生键但 V1 不处理 —— 预期之内，只是通知
        --   · 真正不认识的键 —— 这才是需要警惕的信号（可能是新版本或非 Lightroom 来源）
        local known, unknown = {}, {}
        for _, it in ipairs(unsupported) do
            if type(it) == "table" and it.kind == "unknown" then
                unknown[#unknown + 1] = it
            else
                known[#known + 1] = it
            end
        end

        if #known > 0 then
            add(string.format("Not applied (Lightroom 原生字段，V1 不处理): %d", #known))
            for _, it in ipairs(known) do
                if type(it) == "table" then
                    add("  " .. tostring(it.field) ..
                        (it.reason and ("  — " .. tostring(it.reason)) or ""))
                else
                    add("  " .. tostring(it))
                end
            end
            add("")
        end

        if #unknown > 0 then
            add(string.format("Unknown XMP field (不是已知的 Lightroom Develop 键): %d", #unknown))
            for _, it in ipairs(unknown) do
                if type(it) == "table" then
                    add("  " .. tostring(it.field) ..
                        (it.reason and ("  — " .. tostring(it.reason)) or ""))
                else
                    add("  " .. tostring(it))
                end
            end
            add("")
        end
    end

    ------------------------------------------------------------------
    local errors = rec.errors or {}
    if #errors > 0 then
        add(string.format("Errors: %d", #errors))
        for _, it in ipairs(errors) do
            if type(it) == "table" then
                add("  " .. tostring(it.field or "-") .. ": " .. tostring(it.message or it.reason or "?"))
            else
                add("  " .. tostring(it))
            end
        end
        add("")
    end

    add("Result:")
    add("  " .. tostring(rec.result or "UNKNOWN"))

    return table.concat(L, "\n")
end

return Logger
