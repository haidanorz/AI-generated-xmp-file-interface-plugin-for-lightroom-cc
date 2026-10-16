--[[
    ui/ImportDialog.lua  —  主交互界面

    流程：
        Select XMP…  ->  runOpenPanel
        Analyze      ->  XmpParser.parseFile -> XmpMapping.toDevelopSettings -> Validation.validate
        Preview…     ->  展示将要应用的参数清单
        Apply        ->  文件名匹配校验 -> 覆盖确认 -> ApplyDevelop.apply -> 报告

    使用的 API 全部经过核实：
        LrView.osFactory / LrView.bind
        LrBinding.makePropertyTable(context)
        LrFunctionContext.callWithContext
        LrDialogs.presentModalDialog{ title, contents, actionVerb, cancelVerb, resizable }
        LrDialogs.message(message, info, style)          style ∈ warning|info|critical
        LrDialogs.confirm(message, info, actionVerb, cancelVerb[, otherVerb])
        LrDialogs.runOpenPanel{ title, prompt, canChooseFiles, allowsMultipleSelection, fileTypes, initialDirectory }
            返回值：(table) 路径数组，取消时为 nil

    注意：Analyze 阶段绝不修改照片。只有用户点击 Apply 之后才写目录。
--]]

----------------------------------------------------------------------
-- 延迟 / 安全导入
--   本文件同样需要能在普通 Lua 环境下被 require（语法 + 加载期错误检查），
--   因此所有 Lightroom 模块都在这里通过 safeImport 获取，缺失时得到 nil 而不是报错。
--   真正调用它们时（ImportDialog.run）一定处于 Lightroom 运行时中。
----------------------------------------------------------------------
local function safeImport(name)
    if type(import) ~= "function" then
        return nil
    end
    -- import 本身不会 yield，因此这里用原生 pcall 是安全的
    local ok, mod = pcall(import, name)
    if ok then return mod end
    return nil
end

local LrView            = safeImport("LrView")
local LrDialogs         = safeImport("LrDialogs")
local LrBinding         = safeImport("LrBinding")
local LrFunctionContext = safeImport("LrFunctionContext")
local LrApplicationView = safeImport("LrApplicationView")
local LrPrefs           = safeImport("LrPrefs")

--- 延迟求值的 bind（LrView 在普通 Lua 下为 nil，不能在此处直接取 .bind）
local function bind(key)
    return LrView.bind(key)
end

----------------------------------------------------------------------
-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径）
local Utils           = AI_COLOR_IMPORTER.load("src/Utils.lua")
local Logger          = AI_COLOR_IMPORTER.load("src/Logger.lua")
local Manifest        = AI_COLOR_IMPORTER.load("manifest.lua")
local XmpParser       = AI_COLOR_IMPORTER.load("src/XmpParser.lua")
local XmpMapping      = AI_COLOR_IMPORTER.load("src/XmpMapping.lua")
local Validation      = AI_COLOR_IMPORTER.load("src/Validation.lua")
local DevelopSettings = AI_COLOR_IMPORTER.load("src/DevelopSettings.lua")
local PhotoResolver   = AI_COLOR_IMPORTER.load("src/PhotoResolver.lua")
local ApplyDevelop    = AI_COLOR_IMPORTER.load("src/ApplyDevelop.lua")
local ProgressDialog  = AI_COLOR_IMPORTER.load("ui/ProgressDialog.lua")

local ImportDialog = {}

----------------------------------------------------------------------
-- 偏好读写（失败不影响主流程）
----------------------------------------------------------------------

local function loadConfig()
    local cfg = Utils.shallowCopy(Manifest.defaults)
    if LrPrefs == nil then
        return cfg
    end
    local ok, prefs = Utils.safeCall("ai-color-prefs-read", function()
        return LrPrefs.prefsForPlugin()
    end)
    if ok and prefs then
        if type(prefs.applyExtendedFields) == "boolean" then
            cfg.applyExtendedFields = prefs.applyExtendedFields
        end
        if type(prefs.lastXmpFolder) == "string" then
            cfg.lastXmpFolder = prefs.lastXmpFolder
        end
    end
    return cfg
end

local function rememberFolder(folder)
    if LrPrefs == nil or Utils.isBlank(folder) then
        return
    end
    Utils.safeCall("ai-color-prefs-write", function()
        LrPrefs.prefsForPlugin().lastXmpFolder = folder
    end)
end

--- 记住「是否应用扩展字段」这一偏好
local function rememberExtended(value)
    if LrPrefs == nil then
        return
    end
    Utils.safeCall("ai-color-prefs-ext", function()
        LrPrefs.prefsForPlugin().applyExtendedFields = value and true or false
    end)
end

local function folderOf(path)
    if Utils.isBlank(path) then return nil end
    local p = Utils.normalizePath(path)
    local folder = p:match("^(.*)/[^/]*$")
    return folder
end

----------------------------------------------------------------------
-- 文本查看器（长文本用可滚动多行框，而不是塞进 message 对话框）
----------------------------------------------------------------------

local function showTextViewer(title, text)
    LrFunctionContext.callWithContext("aiColorTextViewer", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.text = text

        local contents = f:column {
            bind_to_object = props,
            spacing = 8,
            f:static_text {
                title = title,
                font = "<system>",
            },
            f:separator { fill_horizontal = 1 },
            f:edit_field {
                value = bind "text",
                width_in_chars = 88,
                height_in_lines = 32,
            },
        }

        LrDialogs.presentModalDialog {
            title       = title,
            contents    = contents,
            actionVerb  = "关闭",
            cancelVerb  = "< exclude >",
            resizable   = true,
        }
    end)
end

ImportDialog.showTextViewer = showTextViewer

----------------------------------------------------------------------
-- 分析（读 XMP -> 映射 -> 校验）
----------------------------------------------------------------------

--- @return result table|nil, parsed table|nil, errString|nil
local function analyzeFile(xmpPath, cfg)
    local parsed, err = XmpParser.parseFile(xmpPath)
    if not parsed then
        return nil, nil, err
    end

    local bundle = XmpMapping.toDevelopSettings(parsed, {
        applyExtendedFields = cfg.applyExtendedFields,
        logger              = Logger,
    })

    -- 运行期范围：仅当 Develop 模块处于激活状态时 getRange 才有效；
    -- 失败会被安全调用吞掉并退化为静态建议区间，属预期行为。
    local runtimeRanges = {}
    if LrApplicationView then
        local ok, moduleName = Utils.safeCall("ai-color-current-module", function()
            return LrApplicationView.getCurrentModuleName()
        end)
        if ok and moduleName == "develop" then
            runtimeRanges = XmpMapping.applyRuntimeRanges(function(param)
                return ApplyDevelop.getParamRange(param)
            end)
        end
    end

    local result = Validation.validate(bundle, { runtimeRanges = runtimeRanges })
    return result, parsed, nil
end

----------------------------------------------------------------------
-- 组织对话框上显示的文字
----------------------------------------------------------------------

local function buildSummary(result, parsed)
    if result == nil then
        return "尚未分析。请先选择 XMP 文件并点击 Analyze。", ""
    end

    local c = result.counts or {}
    local m = parsed and parsed.metadata or {}

    local lines = {}
    lines[#lines + 1] = string.format(
        "可应用字段：%d      收拢：%d",
        c.settings or 0, c.clamped or 0)
    lines[#lines + 1] = string.format(
        "忽略：%d      不支持：%d      警告：%d      错误：%d",
        c.ignored or 0, c.unsupported or 0, c.warnings or 0, c.errors or 0)

    if m.presetName then
        lines[#lines + 1] = "预设名称：" .. tostring(m.presetName)
    end
    if m.sourceFile then
        lines[#lines + 1] = "XMP Source：" .. tostring(m.sourceFile)
    end
    if m.aiVersion then
        lines[#lines + 1] = "AI 版本：" .. tostring(m.aiVersion)
    end
    local skippedCount = #(result.skipped or {})
    if skippedCount > 0 then
        lines[#lines + 1] = string.format(
            "跳过 %d 个扩展字段（勾选上面「同时应用扩展字段」即可应用）", skippedCount)
    end

    if result.schema and result.schema.version then
        lines[#lines + 1] = string.format("AI Color Schema：%s（%s）",
            tostring(result.schema.version), tostring(result.schema.status))
    else
        lines[#lines + 1] = "AI Color Schema：未声明，按 "
            .. tostring(Manifest.schemaVersion) .. " 处理"
    end

    ----------------------------------------------------------------
    -- 问题清单（最多显示 8 条，避免面板被撑爆）
    ----------------------------------------------------------------
    local problems = {}
    local function addProblem(kind, item)
        if #problems >= 8 then return end
        if type(item) == "table" then
            problems[#problems + 1] = string.format("[%s] %s — %s",
                kind, tostring(item.field), tostring(item.message or item.reason or ""))
        else
            problems[#problems + 1] = string.format("[%s] %s", kind, tostring(item))
        end
    end

    for _, e in ipairs(result.errors or {})      do addProblem("错误", e) end
    for _, u in ipairs(result.unsupported or {}) do addProblem("不支持", u) end
    for _, w in ipairs(result.warnings or {})    do addProblem("警告", w) end

    local totalProblems = #(result.errors or {}) + #(result.unsupported or {}) + #(result.warnings or {})
    if totalProblems > #problems then
        problems[#problems + 1] = string.format("… 另有 %d 条，点击 Preview… 查看完整清单", totalProblems - #problems)
    end

    return table.concat(lines, "\n"), table.concat(problems, "\n")
end

----------------------------------------------------------------------
-- 主流程
----------------------------------------------------------------------

function ImportDialog.run()
    local cfg = loadConfig()

    ----------------------------------------------------------------
    -- 1) 目标照片
    ----------------------------------------------------------------
    local photo, err = PhotoResolver.getTargetPhoto()
    if not photo then
        LrDialogs.message("AI Color Importer",
            tostring(err or "请先在 Lightroom Library 中选择目标照片。"), "warning")
        return
    end

    local desc = PhotoResolver.describe(photo)
    local selected = PhotoResolver.getTargetPhotos()

    -- 诊断日志：把解析到的照片信息落盘，便于排查「目标照片显示未知」这类问题
    Logger.info(string.format(
        "目标照片解析：fileName=%s（来源 %s） fileFormat=%s isVirtualCopy=%s path=%s",
        tostring(desc.fileName), tostring(desc.fileNameSource),
        tostring(desc.fileFormat), tostring(desc.isVirtualCopy), tostring(desc.path)),
        {
            operation = "RESOLVE",
            photo     = desc.fileName,
            result    = Utils.isBlank(desc.fileName) and "NO_FILENAME" or "OK",
        })

    if Utils.isBlank(desc.fileName) then
        -- 拿到了照片对象却读不出任何元数据。先试目录级批量读取，
        -- 把逐项诊断落盘 + 直接展示，这样一次就能定位，不必再来回一轮。
        local meta = PhotoResolver.fetchMetaViaCatalog(photo)
        if type(meta) == "table" and type(meta.path) == "string" and meta.path ~= "" then
            desc.path = meta.path
            desc.fileName = Utils.basename(meta.path)
            desc.fileNameSource = "catalog:batchGetRawMetadata"
            if meta.fileFormat ~= nil then desc.fileFormat = meta.fileFormat end
            Logger.info("照片元数据改用目录级批量读取成功：" .. tostring(meta.path),
                { operation = "RESOLVE", result = "FALLBACK_OK" })
        end
    end

    if Utils.isBlank(desc.fileName) then
        local lines = PhotoResolver.diagnose(photo, desc)
        for _, l in ipairs(lines) do
            Logger.warn("照片解析诊断: " .. l, { operation = "RESOLVE", result = "DIAG" })
        end

        local shown = {}
        for i = 1, math.min(#lines, 24) do
            shown[#shown + 1] = lines[i]
        end
        if #lines > #shown then
            shown[#shown + 1] = string.format("… 另有 %d 行，见日志", #lines - #shown)
        end

        LrDialogs.message(
            "无法读取目标照片的信息",
            "插件已经拿到了照片对象，但读不出文件名 / 路径 / 格式。\n\n" ..
            "诊断信息（同样已写入日志）：\n" ..
            table.concat(shown, "\n") ..
            "\n\n请把这一整段发给我。",
            "critical")
        return
    end

    if #selected > 1 then
        local ans = LrDialogs.confirm(
            string.format("当前选中了 %d 张照片，但本插件每次只处理 1 张。", #selected),
            "将处理 Target Photo（最亮 / 最后点选的那张）：" .. tostring(desc.fileName) ..
            "\n\n如果这不是你想要的，请先只选中一张照片再运行。",
            "继续", "取消")
        if ans ~= "ok" then
            return
        end
    end

    if desc.fileFormat and not PhotoResolver.isRawLike(desc.fileFormat) then
        Logger.warn(string.format(
            "目标照片格式为 %s（非 RAW/DNG）。Lightroom 对非 RAW 文件的色温刻度可能不是 Kelvin，"
            .. "应用后请自行核对预览。", tostring(desc.fileFormat)),
            { operation = "PREPARE", photo = desc.fileName })
    end

    ----------------------------------------------------------------
    -- 2) 对话框循环
    ----------------------------------------------------------------
    local state = {
        xmpPath = nil,
        parsed  = nil,
        result  = nil,
    }

    local proceed = false
    repeat
        local dialogResult

        LrFunctionContext.callWithContext("aiColorImportDialog", function(context)
            local f = LrView.osFactory()
            local props = LrBinding.makePropertyTable(context)

            local summaryText, problemText = buildSummary(state.result, state.parsed)
            props.targetPhoto = tostring(desc.fileName or "(未知)") ..
                (desc.fileFormat and ("  ·  " .. tostring(desc.fileFormat)) or "")
            props.xmpText      = state.xmpPath and Utils.basename(state.xmpPath) or "(尚未选择)"
            props.xmpPathFull  = state.xmpPath or ""
            props.summary      = summaryText
            props.problems     = problemText
            -- 「同时应用扩展字段」开关（细节 / 效果 / 镜头 / 校准），持久化到插件偏好
            props.applyExt     = cfg.applyExtendedFields and true or false

            ----------------------------------------------------------
            -- 动作：选择 XMP
            ----------------------------------------------------------
            local function onSelectXmp()
                local args = {
                    title                  = "选择 AI 生成的 XMP 调色文件",
                    prompt                 = "选择",
                    canChooseFiles         = true,
                    canChooseDirectories   = false,
                    allowsMultipleSelection= false,
                    fileTypes              = { "xmp" },
                }
                if cfg.lastXmpFolder then
                    args.initialDirectory = cfg.lastXmpFolder
                end

                local paths = LrDialogs.runOpenPanel(args)
                if paths == nil or #paths == 0 then
                    return -- 用户取消
                end

                state.xmpPath = paths[1]
                state.result  = nil
                state.parsed  = nil
                props.xmpText     = Utils.basename(state.xmpPath)
                props.xmpPathFull = state.xmpPath
                props.summary     = "已选择文件，请点击 Analyze 进行分析。"
                props.problems    = ""
                rememberFolder(folderOf(state.xmpPath))
                cfg.lastXmpFolder = folderOf(state.xmpPath)
            end

            ----------------------------------------------------------
            -- 动作：分析
            ----------------------------------------------------------
            local function onAnalyze()
                if Utils.isBlank(state.xmpPath) then
                    LrDialogs.message("尚未选择 XMP", "请先点击「Select XMP…」选择一个 XMP 文件。", "warning")
                    return
                end

                -- 用界面上的勾选状态覆盖配置，并记住它
                cfg.applyExtendedFields = props.applyExt and true or false
                rememberExtended(cfg.applyExtendedFields)

                local result, parsed, aerr = ProgressDialog.wrap("正在分析 XMP…", function()
                    return analyzeFile(state.xmpPath, cfg)
                end)

                if result == nil then
                    state.result = nil
                    state.parsed = nil
                    local s, p = buildSummary(nil, nil)
                    props.summary  = "分析失败。"
                    props.problems = tostring(aerr or "未知错误")
                    Logger.error("分析 XMP 失败：" .. tostring(aerr), {
                        operation = "ANALYZE",
                        photo     = desc.fileName,
                        xmp       = Utils.basename(state.xmpPath),
                        result    = "FAILED",
                    })
                    return
                end

                state.result = result
                state.parsed = parsed
                local s, p = buildSummary(result, parsed)
                props.summary  = s
                props.problems = p

                Logger.info(string.format("分析完成：可应用 %d 个字段",
                    (result.counts or {}).settings or 0), {
                    operation = "ANALYZE",
                    photo     = desc.fileName,
                    xmp       = Utils.basename(state.xmpPath),
                    result    = "OK",
                })
            end

            ----------------------------------------------------------
            -- 动作：预览
            ----------------------------------------------------------
            local function onPreview()
                if state.result == nil then
                    LrDialogs.message("尚未分析", "请先选择 XMP 文件并点击「Analyze」。", "warning")
                    return
                end
                local text = DevelopSettings.renderPreview(state.result, {
                    photoName  = desc.fileName,
                    xmpName    = Utils.basename(state.xmpPath),
                    sourceFile = state.parsed and state.parsed.metadata
                                 and state.parsed.metadata.sourceFile or nil,
                    presetName = state.parsed and state.parsed.metadata
                                 and state.parsed.metadata.presetName or nil,
                })
                showTextViewer("AI Color Plan — 应用预览", text)
            end

            ----------------------------------------------------------
            -- 动作：查看日志
            ----------------------------------------------------------
            local function onViewLog()
                showTextViewer("AI Color Importer — 本次会话日志", Logger.dump(200))
            end

            ----------------------------------------------------------
            -- 布局
            ----------------------------------------------------------
            local contents = f:column {
                bind_to_object = props,
                spacing = 10,

                f:row {
                    spacing = 8,
                    f:static_text { title = "目标照片：", width_in_chars = 12 },
                    f:static_text { title = bind "targetPhoto", width_in_chars = 60 },
                },
                f:row {
                    spacing = 8,
                    f:static_text { title = "XMP 文件：", width_in_chars = 12 },
                    f:static_text { title = bind "xmpText", width_in_chars = 60 },
                },

                f:separator { fill_horizontal = 1 },

                f:row {
                    spacing = 8,
                    f:push_button {
                        title  = "Select XMP…",
                        action = onSelectXmp,
                    },
                    f:push_button {
                        title  = "Analyze",
                        action = onAnalyze,
                    },
                    f:push_button {
                        title  = "Preview…",
                        action = onPreview,
                    },
                    f:push_button {
                        title  = "View Log…",
                        action = onViewLog,
                    },
                },

                f:separator { fill_horizontal = 1 },

                f:checkbox {
                    title = "同时应用扩展字段（细节 / 效果 / 镜头 / 校准：锐化、降噪、暗角、颗粒、去色差、Override Look Vignette 等）",
                    value = bind "applyExt",
                },

                f:static_text {
                    title = bind "summary",
                    width_in_chars = 78,
                },
                f:static_text {
                    title = bind "problems",
                    width_in_chars = 78,
                },
                f:static_text {
                    title = "点击 Apply 之前不会修改任何照片；原始 XMP 文件始终只读。",
                    width_in_chars = 78,
                },
            }

            dialogResult = LrDialogs.presentModalDialog {
                title      = "AI Color Importer",
                contents   = contents,
                actionVerb = "Apply",
                cancelVerb = "Cancel",
                resizable  = true,
            }
        end)

        if dialogResult ~= "ok" then
            Logger.info("用户取消了操作", { operation = "CANCEL", photo = desc.fileName })
            return -- 取消
        end

        if state.result == nil then
            LrDialogs.message("尚未分析",
                "请先选择 XMP 文件并点击「Analyze」，确认预览后再点击 Apply。", "warning")
        elseif not state.result.applicable then
            LrDialogs.message("没有可应用的字段",
                "分析结果里没有任何可写入的 Develop 字段，请检查 XMP 内容。", "warning")
        else
            -- 有校验错误时先明确告知并确认再写照片：
            -- 明显非法的字段会被丢弃，其余字段仍可应用，但不该悄悄放行）。
            local errCount = state.result.counts.errors or 0
            if errCount > 0 then
                local msgs = {}
                for i, e in ipairs(state.result.errors) do
                    if i > 6 then
                        msgs[#msgs + 1] = string.format("  … 另有 %d 条", errCount - 6)
                        break
                    end
                    msgs[#msgs + 1] = string.format("  %s：%s",
                        tostring(e.field), tostring(e.message))
                end

                local ans = LrDialogs.confirm(
                    string.format("有 %d 个字段校验未通过，这些字段会被丢弃。", errCount),
                    table.concat(msgs, "\n") ..
                    string.format("\n\n其余 %d 个字段仍会正常应用到照片上。要继续吗？",
                        state.result.counts.settings or 0),
                    "仍然应用", "取消")
                if ans == "ok" then
                    proceed = true
                end
            else
                proceed = true
            end
        end
    until proceed

    ----------------------------------------------------------------
    -- 3) 安全校验
    ----------------------------------------------------------------
    local meta = state.parsed and state.parsed.metadata or {}

    -- 3a) XMP 声明的源文件 vs 目标照片
    local status, detail = PhotoResolver.compareSourceFile(meta.sourceFile, desc)
    if status == "mismatch" then
        local ans = LrDialogs.confirm(
            "XMP 与当前照片可能不匹配。",
            string.format(
                "XMP:\n  %s\n\n当前照片:\n  %s\n\n默认行为是取消。只有在你确认这份调色方案本来就该用在这张照片上时，才选择「仍然应用」。",
                tostring(meta.sourceFile), tostring(desc.fileName)),
            "仍然应用", "取消")
        if ans ~= "ok" then
            Logger.warn("用户因源文件不匹配而取消了应用：" .. tostring(detail), {
                operation = "APPLY", photo = desc.fileName,
                xmp = Utils.basename(state.xmpPath), result = "CANCELLED",
            })
            return
        end
        Logger.warn("用户选择忽略源文件不匹配：" .. tostring(detail), {
            operation = "APPLY", photo = desc.fileName, result = "OVERRIDE",
        })
    elseif status == "probable" then
        Logger.info("源文件按宽容规则匹配：" .. tostring(detail), {
            operation = "APPLY", photo = desc.fileName,
        })
    elseif status == "unknown" then
        Logger.warn(detail, { operation = "APPLY", photo = desc.fileName })
    end

    -- 3b) 该 XMP 是否看起来是 Lightroom 的官方随图配置文件（会被 Lightroom 覆写）
    local isSidecar, sidecarWhy = PhotoResolver.looksLikeOfficialSidecar(state.xmpPath, desc)
    if isSidecar then
        local ans = LrDialogs.confirm(
            "这个 XMP 看起来是 Lightroom 的官方随图配置文件。",
            tostring(sidecarWhy) ..
            "\n\n本插件只读取、不会修改它，但 Lightroom 自身在「自动写入 XMP」开启时可能会覆写它，" ..
            "从而丢失这份 AI 调色方案。\n\n建议：把 AI 生成的 XMP 另存为不同文件名（例如 IMG_1023__Natural_Warm__AI-v1.xmp）再使用。",
            "仍然继续", "取消")
        if ans ~= "ok" then
            return
        end
    end

    ----------------------------------------------------------------
    -- 4) 写入
    ----------------------------------------------------------------
    local applyTable = DevelopSettings.toApplyTable(state.result)
    local historyName = Manifest.historyStepPrefix
    if meta.presetName and meta.presetName ~= "" then
        historyName = Manifest.historyStepPrefix .. ": " .. tostring(meta.presetName)
    end

    local applyResult
    ProgressDialog.working("正在应用 " .. tostring(Utils.tcount(applyTable)) .. " 个 Develop 字段…")
    applyResult = ApplyDevelop.apply(photo, applyTable, {
        historyName = historyName,
        actionName  = "AI Color: " .. tostring(meta.presetName or "XMP"),
        timeout     = 60,
        verify      = cfg.verifyAfterApply,
    })

    ----------------------------------------------------------------
    -- 5) 报告
    ----------------------------------------------------------------
    local record = DevelopSettings.buildReportRecord(state.result, {
        operation     = "APPLY",
        timestamp     = Utils.timestamp(Utils.platform.now and Utils.platform.now() or 0),
        photoName     = desc.fileName,
        xmpName       = Utils.basename(state.xmpPath),
        presetName    = meta.presetName,
        sourceFile    = meta.sourceFile,
        aiVersion     = meta.aiVersion,
        result        = applyResult.ok and "SUCCESS" or "FAILED",
    })
    if not applyResult.ok then
        record.errors[#record.errors + 1] = { field = "-", message = applyResult.message or "未知失败" }
    end

    local reportText = Logger.buildApplyReport(record, true)

    -- 落盘 / 落内存
    if applyResult.ok then
        Logger.info("Apply 成功：" .. tostring(applyResult.message), {
            operation = "APPLY", photo = desc.fileName,
            xmp = Utils.basename(state.xmpPath), result = "SUCCESS",
        })
    else
        Logger.error("Apply 失败：" .. tostring(applyResult.message), {
            operation = "APPLY", photo = desc.fileName,
            xmp = Utils.basename(state.xmpPath), result = "FAILED",
        })
    end
    Logger.info(reportText, { operation = "APPLY_REPORT", photo = desc.fileName })

    ----------------------------------------------------------------
    -- 读回校验结果
    ----------------------------------------------------------------
    if applyResult.ok and applyResult.verify then
        local v = applyResult.verify
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

    ----------------------------------------------------------------
    -- 6) 给用户结果
    ----------------------------------------------------------------
    if applyResult.ok then
        if cfg.switchToDevelopAfterApply and LrApplicationView then
            ApplyDevelop.goToDevelopModule()
        end

        local headline = string.format(
            "已应用 %d 个 Develop 字段到 %s。",
            Utils.tcount(applyTable), tostring(desc.fileName))

        local extra = ""
        local c = state.result.counts or {}
        if (c.clamped or 0) > 0 or (c.unsupported or 0) > 0 or (c.errors or 0) > 0 then
            extra = string.format(
                "\n\n注意：收拢 %d · 不支持 %d · 错误 %d（细节见下方报告与日志）。",
                c.clamped or 0, c.unsupported or 0, c.errors or 0)
        end

        Logger.info(headline, { operation = "APPLY", photo = desc.fileName, result = "SUCCESS" })
        showTextViewer("AI Color — 应用结果", headline .. extra .. "\n\n" .. reportText)

        -- 原始 XMP 只读声明
        Logger.info("原始 XMP 文件未被修改（只读）", {
            operation = "APPLY", xmp = Utils.basename(state.xmpPath),
        })
    else
        LrDialogs.message("应用失败", tostring(applyResult.message or "未知错误"), "critical")
        showTextViewer("AI Color — 失败报告", reportText)
    end
end

return ImportDialog
