--[[
    src/XmpParser.lua  —  XMP / XML 解析器（纯 Lua，零 Lightroom 依赖）

    为什么不用 string.match 硬编码？
        用 string.match 硬编码整个 XML 是不可靠的。XMP 是 XML/RDF，必须处理：
        命名空间声明、前缀任意变化、属性顺序、空白、XML 实体、Unicode、
        rdf:Description / rdf:Seq / rdf:Bag / rdf:Alt / 结构体。

    本文件实现一个「有限但健壮」的递归下降 XML 子集解析器：
        * 支持：XML 声明、注释、处理指令、DOCTYPE（跳过）、CDATA、
               元素、属性（单/双引号）、自闭合标签、文本节点、
               实体引用（含数值实体）、命名空间前缀解析与作用域继承
        * 明确不支持（会给出可读报错或宽容降级）：
               内部 DTD 实体定义、非 ASCII 的元素名（实际 XMP 不会出现）、
               XML 1.1 特性

    命名空间策略：
        **绝不相信 "crs:" 这个字面前缀。**
        解析时先建立 前缀 -> namespace URI 的映射栈，之后一律按
        (namespace URI, localName) 定位字段。这样
            <crs:Exposure2012>          （prefix=crs）
            <CameraRaw:Exposure2012>    （prefix=CameraRaw，同一 URI）
        会被同等对待。

    Lua 5.1 兼容。
--]]

-- 依赖统一从插件加载器获取（Lightroom 没有 package / require 搜索路径）
local Utils = AI_COLOR_IMPORTER.load("src/Utils.lua")

local XmpParser = {}

----------------------------------------------------------------------
-- 命名空间 URI 常量
-- 注意：这里硬编码的是 **URI**（字段的身份证），而不是前缀。
----------------------------------------------------------------------
XmpParser.NS = {
    XML   = "http://www.w3.org/XML/1998/namespace",
    XMLNS = "http://www.w3.org/2000/xmlns/",
    RDF   = "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    X     = "adobe:ns:meta/",
    CRS   = "http://ns.adobe.com/camera-raw-settings/1.0/",
    DC    = "http://purl.org/dc/elements/1.1/",
    XMP   = "http://ns.adobe.com/xap/1.0/",
}

----------------------------------------------------------------------
-- 实体与 UTF-8
----------------------------------------------------------------------

local NAMED_ENTITIES = {
    amp  = "&",
    lt   = "<",
    gt   = ">",
    quot = "\"",
    apos = "'",
}

local function codepointToUtf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
    elseif code < 0x110000 then
        return string.char(
            0xF0 + math.floor(code / 0x40000),
            0x80 + (math.floor(code / 0x1000) % 0x40),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40))
    end
    return "\239\191\189" -- U+FFFD
end
XmpParser.codepointToUtf8 = codepointToUtf8

--- 解码 XML 实体。未知实体原样保留（宽容），不抛错。
function XmpParser.decodeEntities(s)
    if type(s) ~= "string" or not s:find("&", 1, true) then
        return s
    end
    local out = s:gsub("&(#?[%w%._%-]+);", function(body)
        if body:sub(1, 1) == "#" then
            local num = body:sub(2)
            local base = 10
            if num:sub(1, 1):lower() == "x" then
                num = num:sub(2)
                base = 16
            end
            local code = tonumber(num, base)
            if code and code >= 0 and code <= 0x10FFFF then
                return codepointToUtf8(code)
            end
            return "&" .. body .. ";" -- 非法数值实体：原样保留
        end
        local v = NAMED_ENTITIES[body]
        if v then
            return v
        end
        return "&" .. body .. ";"     -- 未知实体：原样保留
    end)
    return out
end

----------------------------------------------------------------------
-- 递归下降解析器
----------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

local function newParser(text)
    return setmetatable({
        s        = text,
        i        = 1,
        n        = #text,
        warnings = {},
    }, Parser)
end

function Parser:warn(msg)
    self.warnings[#self.warnings + 1] = msg
end

function Parser:lineAt(pos)
    local _, count = self.s:sub(1, math.min(pos or self.i, self.n)):gsub("\n", "")
    return count + 1
end

function Parser:fail(msg)
    error(string.format("[XMP 解析] 第 %d 行 (字符 %d): %s",
        self:lineAt(), math.min(self.i, self.n + 1), msg), 0)
end

function Parser:peek(len)
    len = len or 1
    return self.s:sub(self.i, self.i + len - 1)
end

function Parser:startsWith(lit)
    return self.s:sub(self.i, self.i + #lit - 1) == lit
end

function Parser:skipWhitespace()
    local _, e = self.s:find("^[ \t\r\n]+", self.i)
    if e then
        self.i = e + 1
    end
end

function Parser:skipComment()
    local e = self.s:find("-->", self.i + 4, true)
    if not e then
        self:fail("注释未闭合（缺少 -->）")
    end
    self.i = e + 3
end

function Parser:skipPI()
    local e = self.s:find("?>", self.i + 2, true)
    if not e then
        self:fail("处理指令未闭合（缺少 ?>）")
    end
    self.i = e + 2
end

function Parser:skipDoctype()
    local j = self.i + 9
    local depth = 0
    while j <= self.n do
        local c = self.s:sub(j, j)
        if c == "[" then
            depth = depth + 1
        elseif c == "]" then
            depth = depth - 1
        elseif c == ">" and depth <= 0 then
            self.i = j + 1
            return
        end
        j = j + 1
    end
    self:fail("DOCTYPE 未闭合")
end

function Parser:skipMisc()
    while true do
        self:skipWhitespace()
        if self:startsWith("<!--") then
            self:skipComment()
        elseif self:startsWith("<?") then
            self:skipPI()
        elseif self:startsWith("<!DOCTYPE") or self:startsWith("<!doctype") then
            self:skipDoctype()
        else
            return
        end
    end
end

--- 读取一个 QName（元素名或属性名）
function Parser:parseQName()
    local _, e = self.s:find("^[%a_][%w%._:%-]*", self.i)
    if not e then
        self:fail("期望元素名或属性名，实际遇到: \"" .. self.s:sub(self.i, self.i + 20) .. "\"")
    end
    local name = self.s:sub(self.i, e)
    self.i = e + 1
    return name
end

function Parser:parseAttrValue()
    local q = self:peek(1)
    if q ~= "\"" and q ~= "'" then
        self:fail("属性值必须用引号包围")
    end
    self.i = self.i + 1
    local e = self.s:find(q, self.i, true)
    if not e then
        self:fail("属性值缺少结束引号 " .. q)
    end
    local raw = self.s:sub(self.i, e - 1)
    self.i = e + 1
    return XmpParser.decodeEntities(raw)
end

local function splitQName(qname)
    local p, l = qname:match("^(.-):(.+)$")
    if p then
        return p, l
    end
    return nil, qname
end
XmpParser.splitQName = splitQName

--- 解析一个元素，返回节点表
-- @param scope table 外层命名空间作用域（前缀 -> URI）
function Parser:parseElement(scope)
    if self:peek(1) ~= "<" then
        self:fail("期望 '<'")
    end
    self.i = self.i + 1

    local qname = self:parseQName()
    local prefix, localName = splitQName(qname)

    local node = {
        qname     = qname,
        prefix    = prefix,
        localName = localName,
        uri       = nil,
        attrs     = {},   -- 有序数组
        children  = {},   -- 有序数组（仅元素）
        text      = "",   -- 直接文本节点拼接
    }

    -- 本元素的命名空间作用域：先继承，再被本元素的 xmlns 覆盖
    local localScope = setmetatable({}, { __index = scope })

    ----------------------------------------------------------------
    -- 属性
    ----------------------------------------------------------------
    while true do
        self:skipWhitespace()
        local c = self:peek(1)
        if c == "" then
            self:fail("元素 <" .. qname .. "> 未闭合")
        end
        if c == ">" or c == "/" then
            break
        end

        local aqname = self:parseQName()
        self:skipWhitespace()
        if self:peek(1) ~= "=" then
            self:fail("属性 " .. aqname .. " 缺少 '='")
        end
        self.i = self.i + 1
        self:skipWhitespace()
        local avalue = self:parseAttrValue()

        if aqname == "xmlns" then
            localScope[""] = avalue
        elseif aqname:sub(1, 6) == "xmlns:" then
            localScope[aqname:sub(7)] = avalue
        else
            local ap, al = splitQName(aqname)
            node.attrs[#node.attrs + 1] = {
                qname     = aqname,
                prefix    = ap,
                localName = al,
                value     = avalue,
                uri       = nil, -- 稍后填
            }
        end
    end

    ----------------------------------------------------------------
    -- 解析元素自身与属性的命名空间 URI
    ----------------------------------------------------------------
    if prefix then
        node.uri = localScope[prefix]
        if not node.uri then
            self:fail("元素 <" .. qname .. "> 使用了未声明的命名空间前缀 \"" .. prefix .. "\"")
        end
    else
        node.uri = localScope[""] or nil -- 无默认命名空间时为 nil
    end

    for _, a in ipairs(node.attrs) do
        if a.prefix then
            a.uri = localScope[a.prefix]
            if not a.uri then
                self:fail("属性 " .. a.qname .. " 使用了未声明的命名空间前缀 \"" .. a.prefix .. "\"")
            end
        else
            a.uri = nil -- 无前缀属性不属于任何命名空间
        end
    end

    ----------------------------------------------------------------
    -- 自闭合
    ----------------------------------------------------------------
    if self:peek(1) == "/" then
        if self:peek(2) ~= "/>" then
            self:fail("自闭合标签写法错误（应为 \"/>\"）")
        end
        self.i = self.i + 2
        node.selfClosing = true
        node.scope = localScope
        return node
    end

    if self:peek(1) ~= ">" then
        self:fail("元素 <" .. qname .. "> 起始标签缺少 '>'")
    end
    self.i = self.i + 1

    ----------------------------------------------------------------
    -- 内容
    ----------------------------------------------------------------
    while true do
        if self.i > self.n then
            self:fail("元素 <" .. qname .. "> 缺少结束标签 </" .. qname .. ">")
        end

        if self:startsWith("</") then
            self.i = self.i + 2
            local endName = self:parseQName()
            if endName ~= qname then
                self:fail(string.format("结束标签不匹配：期望 </%s>，实际 </%s>", qname, endName))
            end
            self:skipWhitespace()
            if self:peek(1) ~= ">" then
                self:fail("结束标签 </" .. endName .. "> 缺少 '>'")
            end
            self.i = self.i + 1
            break

        elseif self:startsWith("<![CDATA[") then
            self.i = self.i + 9
            local e = self.s:find("]]>", self.i, true)
            if not e then
                self:fail("CDATA 段未闭合")
            end
            node.text = node.text .. self.s:sub(self.i, e - 1)
            self.i = e + 3

        elseif self:startsWith("<!--") then
            self:skipComment()

        elseif self:startsWith("<?") then
            self:skipPI()

        elseif self:peek(1) == "<" then
            local child = self:parseElement(localScope)
            child.parent = node
            node.children[#node.children + 1] = child

        else
            local e = self.s:find("<", self.i, true)
            if not e then
                self:fail("元素 <" .. qname .. "> 中的文本未闭合")
            end
            node.text = node.text .. XmpParser.decodeEntities(self.s:sub(self.i, e - 1))
            self.i = e
        end
    end

    node.scope = localScope
    return node
end

function Parser:parseDocument()
    local rootScope = { xml = XmpParser.NS.XML, xmlns = XmpParser.NS.XMLNS }

    local root = nil
    while true do
        self:skipMisc()
        if self.i > self.n then
            break
        end
        if self:startsWith("</") then
            self:fail("出现多余的结束标签")
        elseif self:startsWith("<!") then
            -- 顶层 CDATA / DOCTYPE 等：CDATA 在文档顶层是非法的，容忍跳过
            if self:startsWith("<![CDATA[") then
                self.i = self.i + 9
                local e = self.s:find("]]>", self.i, true)
                if not e then self:fail("CDATA 段未闭合") end
                self.i = e + 3
            else
                self:skipDoctype()
            end
        elseif self:peek(1) == "<" then
            if root then
                self:fail("文档中出现了多个根元素")
            end
            root = self:parseElement(rootScope)
        else
            -- 顶层非空白文本：XML 不允许，宽容跳过
            local e = self.s:find("<", self.i, true)
            if not e then break end
            self.i = e
        end
    end

    if not root then
        self:fail("文档中没有任何根元素")
    end
    return root
end

----------------------------------------------------------------------
-- 对外：低层解析
----------------------------------------------------------------------

--- 去掉 UTF-8 BOM
local function stripBom(text)
    if type(text) == "string" and text:sub(1, 3) == "\239\187\191" then
        return text:sub(4)
    end
    return text
end
XmpParser.stripBom = stripBom

--- 解析 XML 文本为 DOM 树
-- @return rootNode | nil, errString, warnings
function XmpParser.parseXml(text)
    if type(text) ~= "string" or text == "" then
        return nil, "XML 内容为空", {}
    end
    text = stripBom(text)

    local parser = newParser(text)
    local ok, result = pcall(parser.parseDocument, parser)
    if not ok then
        return nil, tostring(result), parser.warnings
    end
    return result, nil, parser.warnings
end

----------------------------------------------------------------------
-- DOM 辅助
----------------------------------------------------------------------

--- 深度优先遍历
function XmpParser.walk(node, fn)
    if not node then return end
    fn(node)
    for _, c in ipairs(node.children or {}) do
        XmpParser.walk(c, fn)
    end
end

--- 按 (namespace URI, localName) 找属性；localName 匹配即可时 uri 传 nil
function XmpParser.findAttr(node, uri, localName)
    for _, a in ipairs(node.attrs or {}) do
        if a.localName == localName and (uri == nil or a.uri == uri) then
            return a
        end
    end
    return nil
end

--- 该元素下第一个匹配 (uri, localName) 的子元素
function XmpParser.findChild(node, uri, localName)
    for _, c in ipairs(node.children or {}) do
        if c.localName == localName and (uri == nil or c.uri == uri) then
            return c
        end
    end
    return nil
end

--- 某元素的直接子元素里，第一个属于 rdf:Seq / rdf:Bag / rdf:Alt 的容器
function XmpParser.findRdfContainer(node)
    for _, c in ipairs(node.children or {}) do
        if c.uri == XmpParser.NS.RDF
            and (c.localName == "Seq" or c.localName == "Bag" or c.localName == "Alt") then
            return c
        end
    end
    return nil
end

----------------------------------------------------------------------
-- 对外：XMP 语义抽取
----------------------------------------------------------------------

local function langAlt(node)
    -- 把 rdf:Alt 容器读成 { lang -> text }
    local out = {}
    for _, li in ipairs(node.children or {}) do
        if li.uri == XmpParser.NS.RDF and li.localName == "li" then
            local lang = nil
            local a = XmpParser.findAttr(li, XmpParser.NS.XML, "lang")
            if a then lang = a.value end
            out[lang or ("#item" .. tostring(#out + 1))] = li.text
        end
    end
    return out
end

local function firstLangValue(tbl)
    if type(tbl) ~= "table" then return nil end
    if tbl["x-default"] ~= nil then return tbl["x-default"] end
    for _, v in pairs(tbl) do
        return v
    end
    return nil
end
XmpParser.firstLangValue = firstLangValue

--- 读取一个 crs 子元素的值，返回 (kind, value)
--   kind ∈ "Seq" | "Bag" | "Alt" | "Struct" | "Text"
local function readCrsElement(elem)
    -- 结构体：<crs:Foo><rdf:Description rdf:about="" crs:Bar="1"/></crs:Foo>
    for _, c in ipairs(elem.children or {}) do
        if c.uri == XmpParser.NS.RDF and c.localName == "Description" then
            local st = {}
            for _, a in ipairs(c.attrs) do
                if a.uri then
                    st[a.localName] = a.value
                else
                    st[a.localName] = a.value
                end
            end
            -- 结构体自身也可能带子元素
            for _, cc in ipairs(c.children or {}) do
                if cc.uri then st[cc.localName] = cc.text end
            end
            return "Struct", st
        end
    end

    local container = XmpParser.findRdfContainer(elem)
    if container then
        if container.localName == "Alt" then
            return "Alt", langAlt(container)
        end
        local list = {}
        for _, li in ipairs(container.children or {}) do
            if li.uri == XmpParser.NS.RDF and li.localName == "li" then
                list[#list + 1] = li.text
            end
        end
        return container.localName, list
    end

    return "Text", elem.text
end

--- 从 DOM 抽取字段与元数据
-- @return parsed table { raw, fields, metadata, namespaces, warnings, fieldSources }
function XmpParser.extractFromDom(root, rawText, parserWarnings)
    local NS = XmpParser.NS

    local fields       = {}   -- localName -> value（标量为字符串，容器为表）
    local fieldKinds   = {}   -- localName -> "Scalar"|"Seq"|"Bag"|"Alt"|"Struct"|"Text"
    local fieldSources = {}   -- localName -> 描述字符串（用于日志溯源）
    local duplicates   = {}   -- 重复字段记录
    local namespaces   = {}   -- prefix -> uri
    local warnings     = {}

    for _, w in ipairs(parserWarnings or {}) do
        warnings[#warnings + 1] = w
    end

    -- 收集文档里出现过的所有命名空间（诊断用）
    XmpParser.walk(root, function(n)
        if n.prefix and n.uri and not namespaces[n.prefix] then
            namespaces[n.prefix] = n.uri
        end
        for _, a in ipairs(n.attrs or {}) do
            if a.prefix and a.uri and not namespaces[a.prefix] then
                namespaces[a.prefix] = a.uri
            end
        end
    end)

    -- 收集所有 rdf:Description
    local descriptions = {}
    XmpParser.walk(root, function(n)
        if n.uri == NS.RDF and n.localName == "Description" then
            descriptions[#descriptions + 1] = n
        end
    end)
    if #descriptions == 0 then
        -- 宽容：没有 rdf:Description 的畸形 XMP，退化为整树扫描
        warnings[#warnings + 1] = "未找到 rdf:Description 节点，已退化为整树扫描（文件并非严格 XMP 结构）"
        descriptions[1] = root
    end

    local function putField(localName, kind, value, source)
        if fields[localName] ~= nil then
            duplicates[#duplicates + 1] = {
                field  = localName,
                first  = fieldSources[localName],
                second = source,
            }
            -- 策略：首个出现者胜出，同时在 warnings 里记一条（不静默）
            return
        end
        fields[localName]       = value
        fieldKinds[localName]   = kind
        fieldSources[localName] = source
    end

    for di, desc in ipairs(descriptions) do
        -- 1) 属性形式的 crs 字段
        for _, a in ipairs(desc.attrs or {}) do
            if a.uri == NS.CRS then
                putField(a.localName, "Scalar", a.value,
                    string.format("rdf:Description#%d/@%s", di, a.qname))
            end
        end

        -- 2) 子元素形式的 crs 字段
        for _, e in ipairs(desc.children or {}) do
            if e.uri == NS.CRS then
                local kind, value = readCrsElement(e)
                putField(e.localName, kind, value,
                    string.format("rdf:Description#%d/%s", di, e.qname))
            end
        end
    end

    ----------------------------------------------------------------
    -- 违规/重复警告
    ----------------------------------------------------------------
    for _, d in ipairs(duplicates) do
        warnings[#warnings + 1] = string.format(
            "字段 %s 出现多次（首次: %s；再次: %s）。按策略保留首次出现的值。",
            d.field, tostring(d.first), tostring(d.second))
    end

    ----------------------------------------------------------------
    -- 元数据（人类可读性）
    ----------------------------------------------------------------
    local metadata = {}

    local function scanAnyLocal(localName)
        -- 在任意命名空间中按 localName 找一个值（用于 AIColorSchema 之类的自定义字段）
        for _, desc in ipairs(descriptions) do
            for _, a in ipairs(desc.attrs or {}) do
                if a.localName == localName then return a.value end
            end
            for _, e in ipairs(desc.children or {}) do
                if e.localName == localName then
                    local _, v = readCrsElement(e)
                    if type(v) == "string" then return v end
                    return e.text
                end
            end
        end
        return nil
    end
    XmpParser.scanAnyLocal = scanAnyLocal

    local function pickAlt(localName)
        local v = fields[localName]
        if type(v) == "table" then
            return firstLangValue(v)
        end
        if type(v) == "string" then
            return v
        end
        return nil
    end

    metadata.creator        = pickAlt("creator") or scanAnyLocal("creator")
    metadata.title          = pickAlt("title")
    metadata.description    = pickAlt("description")
    metadata.copyright      = pickAlt("Copyright")
    metadata.presetName     = pickAlt("Name") or pickAlt("ShortName")
    metadata.presetGroup    = pickAlt("Group")
    metadata.presetUUID     = fields.UUID
    metadata.sourceFile     = fields.RawFileName or scanAnyLocal("RawFileName")
    metadata.processVersion = fields.ProcessVersion
    metadata.crsVersion     = fields.Version
    metadata.creatorTool    = scanAnyLocal("CreatorTool")
    metadata.schemaVersion  = scanAnyLocal("AIColorSchema")
    metadata.aiVersion      = scanAnyLocal("AIVersion")
        or scanAnyLocal("AIColorVersion")
        or scanAnyLocal("AIModel")
    metadata.presetType     = fields.PresetType

    return {
        raw         = rawText,
        fields      = fields,
        fieldKinds  = fieldKinds,
        fieldSources= fieldSources,
        metadata    = metadata,
        namespaces  = namespaces,
        duplicates  = duplicates,
        warnings    = warnings,
    }
end

----------------------------------------------------------------------
-- 对外主入口
----------------------------------------------------------------------

--- 解析 XMP 文本（测试与内部使用）
-- @return parsed | nil, errString
function XmpParser.parseString(text)
    local root, err, parserWarnings = XmpParser.parseXml(text)
    if not root then
        return nil, err
    end
    return XmpParser.extractFromDom(root, text, parserWarnings)
end

--- 读取并解析 XMP 文件（主 API）
-- @param path string
-- @return parsed | nil, errString
function XmpParser.parseFile(path)
    if type(path) ~= "string" or Utils.isBlank(path) then
        return nil, "XMP 文件路径为空"
    end

    if not Utils.platform.readFile then
        return nil, "当前平台不支持读取文件（未注入 readFile 实现）"
    end

    local content, err = Utils.platform.readFile(path)
    if not content then
        return nil, "XMP 文件不存在或无法读取：" .. tostring(path) .. "  (" .. tostring(err) .. ")"
    end
    if Utils.isBlank(content) then
        return nil, "XMP 文件内容为空：" .. tostring(path)
    end

    local parsed, perr = XmpParser.parseString(content)
    if not parsed then
        return nil, perr
    end

    parsed.path = path
    parsed.metadata.sourcePath = path
    if not parsed.metadata.sourceFile then
        -- 兜底：从文件名推断（去掉 __xxx__AI-vN 之类后缀）
        parsed.metadata.sourceFileGuess = Utils.tolerantBaseName(path)
    end
    return parsed
end

--- 便捷入口：既接受文件路径，也接受 XML 文本
function XmpParser.parse(pathOrText)
    if type(pathOrText) ~= "string" then
        return nil, "XmpParser.parse 需要一个字符串参数"
    end
    local head = pathOrText:sub(1, 200)
    if head:match("^%s*<") then
        return XmpParser.parseString(pathOrText)
    end
    return XmpParser.parseFile(pathOrText)
end

--- 该 XMP 是否包含 x:xmpmeta 根（用于判断文件是否像 XMP）
function XmpParser.looksLikeXmp(text)
    if type(text) ~= "string" then return false end
    local t = stripBom(text)
    return t:find("<x:xmpmeta", 1, true) ~= nil
        or t:find(":xmpmeta", 1, true) ~= nil
        or t:find("rdf:RDF", 1, true) ~= nil
end

return XmpParser
