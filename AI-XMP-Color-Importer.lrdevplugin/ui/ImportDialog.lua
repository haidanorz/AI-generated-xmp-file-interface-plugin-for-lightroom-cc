--[[
    ui/ImportDialog.lua  —  主交互界面

    流程：
        Select XMP…  ->  runOpenPanel
        Analyze      ->  ApplyEngine.analyze（解析 → 映射 → 校验）
        Preview…     ->  展示将要应用的参数清单
        Apply        ->  ApplyEngine.apply（判定 → 确认 → 写入 → 报告）

    本文件只负责界面：所有判断与写入都在 src/ApplyEngine.lua 里，
    界面通过 confirm 回调决定「需要人裁决的问题」，其余一律交给引擎。

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
local DevelopSettings = AI_COLOR_IMPORTER.load("src/DevelopSettings.lua")
local ApplyEngine     = AI_COLOR_IMPORTER.load("src/ApplyEngine.lua")
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

--- 分析一个 XMP：直接转调 ApplyEngine（界面只负责显示，不做判断）
-- @return analysis table|nil, errString
local function analyzeFile(xmpPath, cfg)
    return ApplyEngine.analyze(xmpPath, {
        applyExtendedFields = cfg.applyExtendedFields,
        logger              = Logger,
    })
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
        xmpPath  = nil,
        parsed   = nil,
        result   = nil,
        analysis = nil,   -- ApplyEngine.analyze 的完整结果（含 parsed + 校验结果）
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

                local analysis, aerr = ProgressDialog.wrap("正在分析 XMP…", function()
                    return analyzeFile(state.xmpPath, cfg)
                end)

                if analysis == nil then
                    state.analysis = nil
                    state.result   = nil
                    state.parsed   = nil
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

                state.analysis = analysis
                state.result   = analysis.result
                state.parsed   = analysis.parsed
                local result   = analysis.result
                local s, p = buildSummary(result, analysis.parsed)
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
            -- 校验错误 / 源文件不匹配 / 官方 sidecar 等「需要人裁决」的问题，
            -- 统一由 ApplyEngine 在写入前通过 confirm 回调处理。
            -- 这里只做初筛：有没有东西可应用。
            proceed = true
        end
    until proceed

    ----------------------------------------------------------------
    -- 3) 判定 + 写入（交给 ApplyEngine；它不弹任何对话框）
    --    需要人裁决的问题通过 confirm 回调交回界面
    ----------------------------------------------------------------
    local function uiConfirm(issue)
        if not Utils.isBlank(issue.actionVerb) and not Utils.isBlank(issue.cancelVerb) then
            return LrDialogs.confirm(issue.headline, issue.detail or "",
                issue.actionVerb, issue.cancelVerb) == "ok"
        end
        -- 没有可选项的问题（例如「没有可应用的字段」）：告知并中止
        LrDialogs.message(issue.headline, issue.detail or "", "warning")
        return false
    end

    ProgressDialog.working("正在应用 Develop 字段…")

    local outcome = ApplyEngine.apply(photo, desc, state.analysis, {
        confirm = uiConfirm,
        verify  = cfg.verifyAfterApply,
        timeout = 60,
    })

    ----------------------------------------------------------------
    -- 4) 把结果呈现给用户
    ----------------------------------------------------------------
    if outcome.skipped then
        LrDialogs.message("未应用", tostring(outcome.message or "未通过前置校验"), "warning")
        return
    end

    if outcome.ok then
        if cfg.switchToDevelopAfterApply and LrApplicationView then
            ApplyDevelop.goToDevelopModule()
        end

        local headline = string.format("已应用 %d 个 Develop 字段到 %s。",
            outcome.applied or 0, tostring(desc.fileName))

        local extra = ""
        local c = outcome.counts or {}
        if (c.clamped or 0) > 0 or (c.unsupported or 0) > 0 or (c.errors or 0) > 0 then
            extra = string.format(
                "\n\n注意：收拢 %d · 不支持 %d · 错误 %d（细节见下方报告与日志）。",
                c.clamped or 0, c.unsupported or 0, c.errors or 0)
        end

        Logger.info("原始 XMP 文件未被修改（只读）", {
            operation = "APPLY", xmp = Utils.basename(state.xmpPath),
        })
        showTextViewer("AI Color — 应用结果",
            headline .. extra .. "\n\n" .. tostring(outcome.reportText))
    else
        LrDialogs.message("应用失败", tostring(outcome.message or "未知错误"), "critical")
        showTextViewer("AI Color — 失败报告", tostring(outcome.reportText))
    end
end

return ImportDialog
