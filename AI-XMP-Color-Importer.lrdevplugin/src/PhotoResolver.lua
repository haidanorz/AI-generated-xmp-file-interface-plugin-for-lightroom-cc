--[[
    src/PhotoResolver.lua  —  目标照片解析与匹配（Lightroom 适配层）

    已核实的 SDK API（来源：Adobe Lightroom Classic SDK API Reference - LrCatalog）
        catalog:getTargetPhoto()            -> LrPhoto | nil
            「Retrieves the active photo... or nil if no photos are selected.」 SDK 3.0+
        catalog:getTargetPhotos()           -> array of LrPhoto
        catalog:setSelectedPhotos(activePhoto, otherSelectedPhotos)
        catalog:getAllPhotos()              -> array（必须在 LrTasks 异步任务内）
        catalog:findPhotoByPath(path, caseSensitivity) -> LrPhoto | nil（必须在 LrTasks 任务内）
        catalog:findPhotos{ searchDesc = { criteria="filename", operation="==", value=... } }
    LrPhoto 取值使用 photo:getRawMetadata(key)：fileName / path / fileFormat /
        isVirtualCopy / uuid（均为 LrPhoto:getRawMetadata 的文档化键）
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径）
local Utils = AI_COLOR_IMPORTER.load("src/Utils.lua")

local PhotoResolver = {}

----------------------------------------------------------------------
-- 延迟获取 Lightroom 模块
--   目的：本文件在「普通 Lua 测试环境」下也必须能被 require 成功，
--   这样纯逻辑函数（compareSourceFile / looksLikeOfficialSidecar /
--   isRawLike / describe 的属性读取）都能被单元测试覆盖。
--   只有真正需要访问目录的函数才会要求 Lightroom 运行时。
----------------------------------------------------------------------
local LrApplicationCache = nil
local function getLrApplication()
    if LrApplicationCache == nil then
        LrApplicationCache = Utils.lrImport("LrApplication")
    end
    return LrApplicationCache
end

----------------------------------------------------------------------

function PhotoResolver.getCatalog()
    local LrApplication = getLrApplication()
    if LrApplication == nil then
        return nil, "当前不在 Lightroom 运行时中（LrApplication 不可用）"
    end

    local ok, catalog = Utils.safeCall("ai-color-get-catalog", function()
        return LrApplication.activeCatalog()
    end)
    if not ok or catalog == nil then
        return nil, "无法访问 Lightroom 目录（LrApplication.activeCatalog() 返回空）"
    end
    return catalog
end

--- 第一版默认使用 Lightroom 当前 Target Photo
-- @return LrPhoto | nil, errString
function PhotoResolver.getTargetPhoto()
    local catalog, err = PhotoResolver.getCatalog()
    if not catalog then
        return nil, err
    end

    local ok, photo = Utils.safeCall("ai-color-target-photo", function()
        return catalog:getTargetPhoto()
    end)
    if not ok then
        return nil, "获取目标照片时出错：" .. tostring(photo)
    end
    if photo == nil then
        return nil, "请先在 Lightroom Library 中选择目标照片。"
    end
    return photo
end

--- 当前选中的全部照片（用于给出「你选了 N 张」的提示）
function PhotoResolver.getTargetPhotos()
    local catalog = PhotoResolver.getCatalog()
    if not catalog then
        return {}
    end
    local ok, photos = Utils.safeCall("ai-color-target-photos", function()
        return catalog:getTargetPhotos()
    end)
    if ok and type(photos) == "table" then
        return photos
    end
    return {}
end

--- 描述一张照片（全部取值都做了 pcall 保护）
--
--  ★ 取值 API 的正确用法（已按官方 LrPhoto 文档逐键核实）★
--     photo:getRawMetadata(key) 的合法键里 **没有 fileName**。
--     文档给出的合法键是：
--        v1.3: fileSize, rating, dimensions, croppedDimensions, shutterSpeed, aperture,
--              exposureBias, flash, isoSpeedRating, focalLength, focalLength35mm,
--              dateTimeOriginal, dateTimeDigitized, dateTime, gps, gpsAltitude,
--              countVirtualCopies, virtualCopies, masterPhoto, isVirtualCopy,
--              countStackInFolderMembers, stackInFolderMembers, isInStackInFolder,
--              stackInFolderIsCollapsed, stackPositionInFolder,
--              topOfStackInFolderContainingPhoto, colorNameForLabel
--        v2.0: fileFormat, width, height, aspectRatio, isCropped,
--              dateTime*ISO8601, lastEditTime, editCount, copyrightState
--        v3.0: uuid, path, isVideo, durationInSeconds, keywords, customMetadata
--     fileName 属于 **getFormattedMetadata**（"The leaf name of the file"）。
--
--  本函数把每次读取的**成败与错误原文**都记进 d.diagnostics，
--  这样「读不到」时能立刻知道是「键不存在」还是「调用抛错」。
function PhotoResolver.describe(photo)
    local d = {
        fileName      = nil,
        fileNameSource= nil,   -- "getFormattedMetadata" | "path"
        path          = nil,
        fileFormat    = nil,
        isVirtualCopy = false,
        uuid          = nil,
        stem          = nil,
        diagnostics   = {},
    }
    local diag = d.diagnostics
    local function add(s) diag[#diag + 1] = s end

    if photo == nil then
        add("photo = nil")
        return d
    end

    add("photo 类型 = " .. type(photo))
    Utils.safeCall("ai-color-photo-type", function()
        if type(photo.type) == "function" then
            add("photo:type() = " .. tostring(photo:type()))
        end
    end)

    ----------------------------------------------------------------
    -- 读取器：把成功/失败都记下来
    -- ★ 必须用 Utils.safeCall（= LrFunctionContext.pcallWithContext）而不是原生 pcall，
    --   因为 photo:getRawMetadata / getFormattedMetadata 都会 yield。
    --   原生 pcall 是 C 函数，跨 C 边界不让 yield，会把它们全部打死。
    ----------------------------------------------------------------
    local function read(label, fn)
        local ok, res = Utils.safeCall("ai-color-read-" .. label, fn)
        if not ok then
            add(label .. " -> ERROR: " .. tostring(res))
            return nil
        end
        if res == nil then
            add(label .. " -> nil")
            return nil
        end
        add(label .. " -> " .. type(res) .. " " .. tostring(res))
        return res
    end

    -- 1) 文件名：正规来源是 getFormattedMetadata("fileName")
    local name = read('getFormattedMetadata("fileName")', function()
        return photo:getFormattedMetadata("fileName")
    end)
    if type(name) == "string" and name ~= "" then
        d.fileName = name
        d.fileNameSource = "getFormattedMetadata"
    end

    -- 2) 路径（getRawMetadata("path") 是合法键）
    local p = read('getRawMetadata("path")', function()
        return photo:getRawMetadata("path")
    end)
    if type(p) == "string" and p ~= "" then
        d.path = p
    end

    -- 3) 兜底 A：从 path 取叶子名
    if Utils.isBlank(d.fileName) and not Utils.isBlank(d.path) then
        local leaf = Utils.basename(d.path)
        if not Utils.isBlank(leaf) then
            d.fileName = leaf
            d.fileNameSource = "path"
        end
    end

    -- 4) 其余字段（只有取到非 nil 值时才覆盖，避免把默认值抹成 nil）
    local fmt = read('getRawMetadata("fileFormat")', function()
        return photo:getRawMetadata("fileFormat")
    end)
    if fmt ~= nil then d.fileFormat = fmt end

    local vc = read('getRawMetadata("isVirtualCopy")', function()
        return photo:getRawMetadata("isVirtualCopy")
    end)
    if vc ~= nil then d.isVirtualCopy = vc and true or false end

    local u = read('getRawMetadata("uuid")', function()
        return photo:getRawMetadata("uuid")
    end)
    if u ~= nil then d.uuid = u end

    -- 5) 兜底 B：无参数调用会返回全部元数据，从中找文件名相关的键
    if Utils.isBlank(d.fileName) then
        local all = read("getRawMetadata() 全量", function()
            return photo:getRawMetadata()
        end)
        if type(all) == "table" then
            local keys = {}
            for k in pairs(all) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            add("  全量原始元数据的键 = " .. table.concat(keys, ", "))
            for _, cand in ipairs({ "fileName", "filename", "originalFileName", "path" }) do
                local v = all[cand]
                if type(v) == "string" and v ~= "" then
                    d.fileName = (cand == "path") and Utils.basename(v) or v
                    d.fileNameSource = "getRawMetadata()-全量/" .. cand
                    break
                end
            end
        end
    end

    if Utils.isBlank(d.fileName) then
        local allFmt = read("getFormattedMetadata() 全量", function()
            return photo:getFormattedMetadata()
        end)
        if type(allFmt) == "table" then
            local keys = {}
            for k in pairs(allFmt) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            add("  全量格式化元数据的键 = " .. table.concat(keys, ", "))
            for _, cand in ipairs({ "fileName", "fileType", "folderName" }) do
                local v = allFmt[cand]
                if type(v) == "string" and v ~= "" then
                    if cand == "fileName" then
                        d.fileName = v
                        d.fileNameSource = "getFormattedMetadata()-全量/fileName"
                    end
                    break
                end
            end
        end
    end

    if d.fileName then
        d.stem = Utils.stripExtension(d.fileName):lower()
    end
    return d
end

--- 兜底：用「目录级批量读取」拿照片元数据。
--  LrCatalog:batchGetRawMetadata(photos, keys) 是另一条独立代码路径
--  （Adobe 官方示例 samrambles 就是用它取 path 的），
--  万一 photo:getRawMetadata 在这些对象上不可用，这里还能兜住。
-- @param photo LrPhoto
-- @param catalog LrCatalog|nil 可选注入（便于单测）；默认取当前目录
-- @return table|nil { path=, fileFormat=, isVirtualCopy=, uuid= }, errString
function PhotoResolver.fetchMetaViaCatalog(photo, catalog)
    if catalog == nil then
        local err
        catalog, err = PhotoResolver.getCatalog()
        if not catalog then
            return nil, err
        end
    end
    if photo == nil then
        return nil, "照片为空"
    end

    local keys = { "path", "fileFormat", "isVirtualCopy", "uuid" }
    local ok, batch = Utils.safeCall("ai-color-batch-raw", function()
        return catalog:batchGetRawMetadata({ photo }, keys)
    end)
    if not ok then
        return nil, "batchGetRawMetadata 调用失败：" .. tostring(batch)
    end
    if type(batch) ~= "table" then
        return nil, "batchGetRawMetadata 返回了非表：" .. type(batch)
    end

    local entry = batch[photo]
    if type(entry) ~= "table" then
        return nil, "批量读取结果里没有这张照片的条目"
    end
    return entry
end

--- 汇总照片解析的诊断信息（供日志与错误对话框使用）
-- @param photo LrPhoto
-- @param desc table|nil 已算好的 describe 结果
-- @return array of strings
function PhotoResolver.diagnose(photo, desc)
    local lines = {}

    lines[#lines + 1] = "yield-safe pcall 可用 = " .. tostring(Utils.hasYieldSafeCall())

    local catalog
    do
        local ok, c = Utils.safeCall("ai-color-diag-catalog", PhotoResolver.getCatalog)
        catalog = ok and c or nil
    end
    lines[#lines + 1] = "catalog            = " .. type(catalog)

    if catalog then
        local ok, err = Utils.safeCall("ai-color-diag-photos", function()
            local photos = catalog:getTargetPhotos()
            lines[#lines + 1] = string.format("getTargetPhotos()  = %s（%d 张）",
                type(photos), type(photos) == "table" and #photos or -1)
            if type(photos) == "table" and photos[1] then
                lines[#lines + 1] = "  [1] 类型 = " .. type(photos[1])
                local okB, batch = Utils.safeCall("ai-color-diag-batch", function()
                    return catalog:batchGetRawMetadata({ photos[1] }, { "path" })
                end)
                if okB and type(batch) == "table" then
                    local entry = batch[photos[1]]
                    lines[#lines + 1] = "  batchGetRawMetadata -> " ..
                        (type(entry) == "table" and ("path=" .. tostring(entry.path)) or tostring(entry))
                else
                    lines[#lines + 1] = "  batchGetRawMetadata -> " .. tostring(batch)
                end
            end
        end)
        if not ok then
            lines[#lines + 1] = "getTargetPhotos 失败: " .. tostring(err)
        end
    end

    lines[#lines + 1] = "photo              = " .. type(photo)

    local d = desc
    if d == nil and photo ~= nil then
        local ok, r = Utils.safeCall("ai-color-diag-describe", PhotoResolver.describe, photo)
        d = ok and r or nil
    end
    if d and d.diagnostics then
        for _, s in ipairs(d.diagnostics) do
            lines[#lines + 1] = s
        end
    end

    return lines
end

--- 该照片的格式是否可能支持 Kelvin 色温（仅作提示用途，不做强制拦截）
function PhotoResolver.isRawLike(fileFormat)
    if type(fileFormat) ~= "string" then
        return nil
    end
    local f = fileFormat:upper()
    return (f == "RAW" or f == "DNG")
end

function PhotoResolver.selectPhoto(photo)
    local catalog = PhotoResolver.getCatalog()
    if not catalog or not photo then
        return false
    end
    local ok = Utils.safeCall("ai-color-select-photo", function()
        catalog:setSelectedPhotos(photo, { photo })
    end)
    return ok
end

----------------------------------------------------------------------
-- 第二阶段：按路径 / 文件名定位照片
-- 两者都已在 SDK 文档中确认存在。
----------------------------------------------------------------------

--- @return LrPhoto | nil, errString
function PhotoResolver.findByPath(path)
    local catalog, err = PhotoResolver.getCatalog()
    if not catalog then
        return nil, err
    end
    if Utils.isBlank(path) then
        return nil, "路径为空"
    end

    -- 必须处于 LrTasks 任务中；调用方（Main.lua）已保证
    local ok, photo = Utils.safeCall("ai-color-find-by-path", function()
        return catalog:findPhotoByPath(path)
    end)
    if not ok then
        return nil, "findPhotoByPath 调用失败：" .. tostring(photo)
    end
    if photo == nil then
        return nil, "目录中找不到路径为 " .. tostring(path) .. " 的照片"
    end
    return photo
end

--- 按文件名在目录中定位（可能命中多张，这里返回第一张并提示）
-- @return LrPhoto | nil, errString, matchCount
function PhotoResolver.findByFileName(fileName)
    local catalog, err = PhotoResolver.getCatalog()
    if not catalog then
        return nil, err, 0
    end
    if Utils.isBlank(fileName) then
        return nil, "文件名为空", 0
    end

    local ok, photos = Utils.safeCall("ai-color-find-by-name", function()
        return catalog:findPhotos {
            searchDesc = {
                criteria  = "filename",
                operation = "==",
                value     = fileName,
            },
        }
    end)
    if not ok then
        return nil, "findPhotos 调用失败：" .. tostring(photos), 0
    end
    if type(photos) ~= "table" or #photos == 0 then
        return nil, "目录中找不到文件名为 " .. tostring(fileName) .. " 的照片", 0
    end
    return photos[1], nil, #photos
end

----------------------------------------------------------------------
-- XMP 与目标照片的匹配校验
----------------------------------------------------------------------

--- 比对 XMP 声明的源文件与当前目标照片
-- @param xmpSourceFile string|nil  XMP 中的 crs:RawFileName
-- @param photoDesc table            PhotoResolver.describe() 的结果
-- @return status "match" | "probable" | "mismatch" | "unknown", detailString
function PhotoResolver.compareSourceFile(xmpSourceFile, photoDesc)
    if Utils.isBlank(xmpSourceFile) then
        return "unknown", "XMP 未声明 RawFileName，无法校验来源照片"
    end
    if photoDesc == nil or Utils.isBlank(photoDesc.fileName) then
        return "unknown", "无法读取目标照片文件名，跳过匹配校验"
    end

    local a = Utils.trim(xmpSourceFile)
    local b = Utils.trim(photoDesc.fileName)

    -- 1) 完全一致（忽略大小写）
    if a:lower() == b:lower() then
        return "match", string.format("XMP Source=%s 与目标照片一致", a)
    end

    -- 2) 宽容比较：去扩展名 + 去 AI 常见后缀
    if Utils.tolerantBaseName(a) == Utils.tolerantBaseName(b)
        and Utils.tolerantBaseName(a) ~= "" then
        return "probable", string.format(
            "XMP Source=%s 与目标照片 %s 名称主干相同（可能是同一张的不同扩展名 / 版本）", a, b)
    end

    return "mismatch", string.format("XMP Source=%s 与目标照片 %s 不一致", a, b)
end

--- 判断所选 XMP 是否「看起来就是 Lightroom 的官方随图配置文件」。
-- 若是，Lightroom 可能会把它当作照片的 sidecar 覆写 —— 必须提醒用户。
-- @param xmpPath string
-- @param photoDesc table
-- @return boolean, detailString
function PhotoResolver.looksLikeOfficialSidecar(xmpPath, photoDesc)
    if Utils.isBlank(xmpPath) or photoDesc == nil or Utils.isBlank(photoDesc.fileName) then
        return false, nil
    end
    local xmpStem = Utils.stripExtension(Utils.basename(xmpPath)):lower()
    local photoStem = Utils.stripExtension(photoDesc.fileName):lower()
    if xmpStem == photoStem then
        return true, string.format(
            "%s 与照片同名同扩展名位置，Lightroom 会把它视为官方随图 XMP 并可能覆写它",
            Utils.basename(xmpPath))
    end
    return false, nil
end

return PhotoResolver
