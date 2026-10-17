# AI-generated-xmp-file-interface-plugin-for-lightroom-cc

An AI generated xmp-file interface for lightroom cc, which can use xmp-file to alter photo paramters
</br>一个可以将ai生成的xmp图片参数配置文件应用到lr的接口插件

> 插件本体位于本仓库的 **`AI-XMP-Color-Importer.lrdevplugin/`** 目录。
> 在 Lightroom 的「增效工具管理器」中把该文件夹添加进来即可。

---

```
XMP 文件  →  解析  →  转换为 SDK 参数  →  校验  →  预览  →  应用  →  Lightroom Develop Settings
（人类可读、可归档、可版本管理）                                  （一次目录写入，无预设参与）
```

---

## 目录

- [特性](#特性)
- [环境要求](#环境要求)
- [安装](#安装)
- [准备 XMP 文件](#准备-xmp-文件)
- [使用步骤](#使用步骤)
- [应用之后发生什么](#应用之后发生什么)
- [支持的字段](#支持的字段)
- [字段转换说明](#字段转换说明)
- [不支持的字段](#不支持的字段)
- [已知限制](#已知限制)
- [日志位置](#日志位置)
- [安全原则](#安全原则)
- [目录结构](#目录结构)
- [开发与测试](#开发与测试)
- [参考](#参考)
- [授权](#授权)

---

## 特性

- **不创建任何 Lightroom 预设。** XMP 只是「参数说明书」，不是 Lightroom 资产。
- **不修改原始 XMP 文件。** 插件对 XMP 只有读取路径，没有任何写入路径。
- **只处理你明确指定的那一张照片。**
- **应用前可预览。** 点 Apply 之前，你可以逐项检查将要写入的参数。
- **零外部依赖。** 纯 Lua 插件，不需要 Python / Node / 任何第三方运行时。
- **支持 92 个 Develop 字段**（其中 65 个默认启用，27 个扩展字段可选）。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| Lightroom Classic | **11.4 或更高**（推荐 13 / 14 及以上） |
| 已验证版本 | Lightroom Classic 14.5.1 |
| 操作系统 | Windows / macOS |
| 额外依赖 | 无 |

---

## 安装

1. 把整个 `AI-XMP-Color-Importer.lrdevplugin` 文件夹放到一个稳定位置
   （例如 `D:\Lightroom-Plugins\AI-XMP-Color-Importer.lrdevplugin`）。
2. 打开 Lightroom Classic。
3. 菜单 **文件 → 增效工具管理器…**（File → Plug-in Manager…）。
4. 点左下角 **添加**（Add），选择上面那个文件夹本身（**不是**里面的某个文件）。
5. 左侧列表出现 **AI XMP Color Importer**，右侧状态显示
   **"This plug-in is enabled and running."** 即安装成功。
6. 若显示未启用，点 **启用**（Enable）后确定。

> 这是个 `.lrdevplugin`（开发用插件），无需编译、无需安装包。

**菜单位置**：安装后菜单项出现在

```
图库 ▸ 增效工具扩展 ▸ AI Color: Apply XMP to Target Photo…
文件 ▸ 增效工具扩展 ▸ AI Color: Apply XMP to Target Photo…
```

> Lightroom 插件 SDK 只允许把菜单项放进「增效工具扩展」，且**只支持一层菜单**，
> 无法创建自定义的多级子菜单 —— 这是 SDK 的限制，因此标题写成了自描述的形式。

---

## 准备 XMP 文件

一份可用的 XMP 至少要有这些内容（节选）：

```xml
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    crs:RawFileName="IMG_1023.CR3"          <!-- 建议填写：用于来源校验 -->
    crs:AIColorSchema="1.0"                 <!-- 建议填写：方案版本 -->
    crs:Exposure2012="+0.35"
    crs:Highlights2012="-25"
    crs:Shadows2012="+18"
    crs:Vibrance="+8" />
 </rdf:RDF>
</x:xmpmeta>
```

三条实用建议：

1. **写上 `crs:RawFileName`**（目标照片文件名）。插件会拿它和当前照片比对；
   不写就只能跳过来源校验。
2. **文件名要跟 Lightroom 的随图 XMP 区分开。** 用
   `IMG_1023__Natural_Warm__AI-v1.xmp` 这种带后缀的命名，而不是 `IMG_1023.xmp`。
   否则 Lightroom 会把它当成官方随图配置文件，日后可能覆写它。
   插件检测到这种情况会弹窗提醒。
3. `crs:AIColorSchema` 写上 `"1.0"`。插件按它决定兼容策略。

### AI Color Schema 版本策略

| 声明值 | 状态 | 行为 |
|---|---|---|
| `1.0` | supported | 正常应用 |
| `0.x` | compatible | 记录兼容性警告，仍然应用 |
| `2.x` | unsupported | **拒绝应用**，报明确错误 |
| 未声明 | assumed | 按 `1.0` 处理 |

---

## 使用步骤

### 1. 选择目标照片

1. 进入 **图库（Library）** 模块。
2. 在网格或胶片栏里**点选一张照片**（这就是 Target Photo）。
3. 插件每次只处理**一张**照片；如果选了多张，插件会告诉你它将处理哪一张并要求确认。

### 2. 运行插件

菜单：**图库 → 增效工具扩展 → AI Color: Apply XMP to Target Photo…**

### 3. 选择 XMP 并分析

```
┌────────────────────────────────────────────────┐
│ AI Color Importer                              │
├────────────────────────────────────────────────┤
│ 目标照片：  IMG_1023.CR3  ·  RAW               │
│ XMP 文件：  (尚未选择)                         │
│ ────────────────────────────────────────────── │
│ [Select XMP…] [Analyze] [Preview…] [View Log…] │
│ ────────────────────────────────────────────── │
│ ☐ 同时应用扩展字段（细节 / 效果 / 镜头 / 校准）│
│ ────────────────────────────────────────────── │
│ 尚未分析。请先选择 XMP 文件并点击 Analyze。    │
│                                                │
│ 点击 Apply 之前不会修改任何照片；              │
│ 原始 XMP 文件始终只读。                        │
├────────────────────────────────────────────────┤
│                          [Apply]   [Cancel]    │
└────────────────────────────────────────────────┘
```

- **Select XMP…** 选文件 → **Analyze** 分析。
- **同时应用扩展字段**（可选）：勾上会一并应用锐化、降噪、暗角、颗粒、去色差、
  Override Look Vignette 等「细节 / 效果 / 镜头 / 校准」字段。这个选择会被记住。

分析完成后窗口会显示：

```
可应用字段：37      收拢：0
忽略：14      不支持：4      警告：2      错误：0
预设名称：Natural Warm
XMP Source：IMG_1023.CR3
AI Color Schema：1.0（supported）
```

### 4. 预览

点 **Preview…** 打开完整清单，在动手前逐项检查：

```
AI Color Plan
----------------------------------------------
Preset      : Natural Warm
Target Photo: IMG_1023.CR3
XMP File    : IMG_1023__Natural_Warm__AI-v1.xmp
XMP Source  : IMG_1023.CR3
----------------------------------------------
-- Basic
Exposure                            +0.35
Contrast                              +12
Highlights                            -25
Shadows                               +18
...
-- Color Mixer / HSL
Blue Saturation                       -10
Orange Hue                             -4
...
----------------------------------------------
Fields: 37    Warnings: 2    Unsupported: 4    Errors: 0
```

### 5. 应用

确认无误后点 **Apply**。此时才会写入照片。

- 如果 XMP 声明的来源文件与当前照片**不一致**，插件会弹窗列出两边文件名，
  **默认取消**，需要你手动选择「仍然应用」。
- 如果分析结果里有**校验错误**，插件会列出错误并要求确认后才写入。

---

## 应用之后发生什么

- 照片的 Develop 设置被修改 —— 可以在「修改照片」模块逐个滑块上看到，
  也可以撤销（Ctrl+Z / Cmd+Z）。
- 「历史记录」面板里生成一步名为 `AI Color: <预设名>` 的记录。
- **Presets 菜单没有任何变化。**
- **XMP 文件没有被改动。**
- 只有你选中的那一张照片被改动。
- 完整过程写进日志文件。

---

## 支持的字段

**V1 = 65 个字段**（默认应用），**扩展 = 27 个字段**（需勾选「同时应用扩展字段」），
合计 **92 个**。

键名定义集中在 `src/XmpMapping.lua` 的 `FIELDS` 表中。
**「随相机变化」表示该字段没有静态区间（布尔 / 枚举 / 色温），校验时只做合理性检查。**

### Basic

| XMP 字段 (`crs:` 之后) | SDK 键名 | 类型 | 建议区间 | 层级 |
|---|---|---|---|---|
| `Exposure2012` | `Exposure2012` | number | -5 .. 5 | V1 |
| `Contrast2012` | `Contrast2012` | number | -100 .. 100 | V1 |
| `Highlights2012` | `Highlights2012` | number | -100 .. 100 | V1 |
| `Shadows2012` | `Shadows2012` | number | -100 .. 100 | V1 |
| `Whites2012` | `Whites2012` | number | -100 .. 100 | V1 |
| `Blacks2012` | `Blacks2012` | number | -100 .. 100 | V1 |
| `Texture` | `Texture` | number | -100 .. 100 | V1 |
| `Clarity2012` | `Clarity2012` | number | -100 .. 100 | V1 |
| `Dehaze` | `Dehaze` | number | -100 .. 100 | V1 |
| `Vibrance` | `Vibrance` | number | -100 .. 100 | V1 |
| `Saturation` | `Saturation` | number | -100 .. 100 | V1 |
| `ConvertToGrayscale` | `ConvertToGrayscale` | boolean | — | V1 |

### White Balance

| XMP 字段 | SDK 键名 | 类型 | 建议区间 | 层级 |
|---|---|---|---|---|
| `WhiteBalance` | `WhiteBalance` | enum | — | V1 |
| `Temperature` | `Temperature` | number | 随相机变化 | V1 |
| `Tint` | `Tint` | number | -150 .. 150 | V1 |

### Tone Curve

| XMP 字段 | SDK 键名 | 类型 | 层级 |
|---|---|---|---|
| `ToneCurvePV2012` | `ToneCurvePV2012` | 点序列 | V1 |
| `ToneCurvePV2012Red` | `ToneCurvePV2012Red` | 点序列 | V1 |
| `ToneCurvePV2012Green` | `ToneCurvePV2012Green` | 点序列 | V1 |
| `ToneCurvePV2012Blue` | `ToneCurvePV2012Blue` | 点序列 | V1 |
| `ToneCurveName2012` | `ToneCurveName2012` | enum | V1 |

### Parametric Tone Curve

| XMP 字段 | SDK 键名 | 建议区间 | 层级 |
|---|---|---|---|
| `ParametricShadows` / `ParametricDarks` / `ParametricLights` / `ParametricHighlights` | 同名 | -100 .. 100 | V1 |
| `ParametricShadowSplit` / `ParametricMidtoneSplit` / `ParametricHighlightSplit` | 同名 | 0 .. 100 | V1 |

### Color Mixer / HSL（24 项）

| XMP 字段 | SDK 键名 | 建议区间 | 层级 |
|---|---|---|---|
| `HueAdjustment{Red,Orange,Yellow,Green,Aqua,Blue,Purple,Magenta}` | 同名 | -100 .. 100 | V1 |
| `SaturationAdjustment{同 8 色}` | 同名 | -100 .. 100 | V1 |
| `LuminanceAdjustment{同 8 色}` | 同名 | -100 .. 100 | V1 |

八个颜色通道集中定义在 `src/XmpMapping.lua` 的 `COLOR_NAMES` / `COLOR_MAP`，
24 个字段由它生成。

### Color Grading

| XMP 字段 | SDK 键名 | 建议区间 | 层级 |
|---|---|---|---|
| `SplitToningShadowHue` | `SplitToningShadowHue` | 0 .. 360 | V1 |
| `SplitToningShadowSaturation` | `SplitToningShadowSaturation` | 0 .. 100 | V1 |
| `ColorGradeShadowLum` | `ColorGradeShadowLum` | -100 .. 100 | V1 |
| `ColorGradeMidtoneHue` | `ColorGradeMidtoneHue` | 0 .. 360 | V1 |
| `ColorGradeMidtoneSat` | `ColorGradeMidtoneSat` | 0 .. 100 | V1 |
| `ColorGradeMidtoneLum` | `ColorGradeMidtoneLum` | -100 .. 100 | V1 |
| `SplitToningHighlightHue` | `SplitToningHighlightHue` | 0 .. 360 | V1 |
| `SplitToningHighlightSaturation` | `SplitToningHighlightSaturation` | 0 .. 100 | V1 |
| `ColorGradeHighlightLum` | `ColorGradeHighlightLum` | -100 .. 100 | V1 |
| `ColorGradeGlobalHue` | `ColorGradeGlobalHue` | 0 .. 360 | V1 |
| `ColorGradeGlobalSat` | `ColorGradeGlobalSat` | 0 .. 100 | V1 |
| `ColorGradeGlobalLum` | `ColorGradeGlobalLum` | -100 .. 100 | V1 |
| `ColorGradeBlending` | `ColorGradeBlending` | 0 .. 100 | V1 |
| `SplitToningBalance` | `SplitToningBalance` | -100 .. 100 | V1 |

### 扩展字段（需在界面勾选「同时应用扩展字段」）

| 分组 | 字段 |
|---|---|
| Detail | `Sharpness`、`SharpenRadius`、`SharpenDetail`、`SharpenEdgeMasking`、`LuminanceSmoothing`、`LuminanceNoiseReductionDetail`、`LuminanceNoiseReductionContrast`、`ColorNoiseReduction`、`ColorNoiseReductionDetail`、`ColorNoiseReductionSmoothness` |
| Effects | `PostCropVignetteAmount`、`PostCropVignetteMidpoint`、`PostCropVignetteFeather`、`PostCropVignetteRoundness`、`PostCropVignetteStyle`、`PostCropVignetteHighlightContrast`、`GrainAmount`、`GrainSize`、`GrainFrequency` |
| Lens | `AutoLateralCA`、`OverrideLookVignette` |
| Calibration | `ShadowTint`、`RedHue`、`RedSaturation`、`GreenHue`、`GreenSaturation`、`BlueHue`、`BlueSaturation` |

---

## 字段转换说明

绝大多数字段是「同名直通」，但有三个地方**必须转换**，否则 Lightroom 会报错或静默丢弃。

### 1. 白平衡

| XMP 情况 | 插件行为 |
|---|---|
| 只有 `WhiteBalance="Daylight"` 之类预设 | 原样写入同名预设 |
| 有 `Temperature` 和 / 或 `Tint` | **强制 `WhiteBalance = "Custom"`**，再写入色温 / 色调 |
| 声称 `As Shot` 却同时给了色温 | 按 `Custom` 处理并记警告 |
| 白平衡模式不在已知列表内 | 报错，不写入该字段 |

> Lightroom 只有在白平衡模式为 `Custom` 时才会采用显式的 `Temperature` / `Tint` 数值；
> 否则这两个值会被**静默忽略**。

### 2. 色调曲线

XMP 写法与 SDK 要求**格式不同**：

```
XMP（rdf:Seq，每个点是一段 "x, y" 文本）
  <crs:ToneCurvePV2012><rdf:Seq>
    <rdf:li>0, 0</rdf:li><rdf:li>92, 106</rdf:li><rdf:li>255, 255</rdf:li>
  </rdf:Seq></crs:ToneCurvePV2012>

SDK 需要的扁平数字数组
  ToneCurvePV2012 = { 0, 0, 92, 106, 255, 255 }
```

| 情况 | 行为 |
|---|---|
| 有自定义点 | 转换为扁平数组 + **强制 `ToneCurveName2012 = "Custom"`** |
| 点曲线等价于恒等（`0,0 / 255,255`） | 跳过，不写入 |
| 只有 `ToneCurveName2012="Medium Contrast"` | 只写名称 |
| 点格式非法 / 越界 / X 非单调 / 少于 2 点 | 跳过该曲线并记录错误，其余字段照常应用 |

### 3. 颜色分级键名

Lightroom 的色轮命名并不整齐：**阴影轮 / 高光轮的色相与饱和度**叫 `SplitToning*`，
而**中间调 / 全局**的色相饱和度、以及四个轮的**明度**叫 `ColorGrade*`。
如果用「整齐」的方式写出 `ColorGradeShadowHue` 这类名字，Lightroom 会**静默丢弃**。
插件通过别名表自动转换：

| XMP 中可能出现的键名 | 实际写入的 SDK 键名 |
|---|---|
| `ColorGradeShadowHue` | `SplitToningShadowHue` |
| `ColorGradeShadowSat` / `ColorGradeShadowSaturation` | `SplitToningShadowSaturation` |
| `ColorGradeHighlightHue` | `SplitToningHighlightHue` |
| `ColorGradeHighlightSat` / `ColorGradeHighlightSaturation` | `SplitToningHighlightSaturation` |
| `ColorGradeMidtoneSaturation` | `ColorGradeMidtoneSat` |
| `ColorGradeGlobalSaturation` | `ColorGradeGlobalSat` |

---

## 不支持的字段

日志里会分两组汇报，含义不同。

### 第 1 组：已知的 Lightroom 原生字段，但本插件不处理

属于预期之内，只是通知。

| 字段 / 分组 | 原因 |
|---|---|
| `MaskGroupBasedCorrections`、`Masking`、`local_*` | 遮罩 / 局部调整。SDK 限制严重：手写该字段不会渲染任何遮罩，而且会**整体替换**照片已有的遮罩数组 |
| `RetouchInfo`、`RedEyeInfo` | 污点修复 / 红眼，属于像素级操作 |
| `CameraProfile`、`CameraProfileDigest`、`Look`、`LookTable` | 相机配置文件 / Look 表。按名称应用依赖本机是否装了同一配置文件，结果不可预期 |
| `PointColors`、`LensBlur*` | Point Color、Lens Blur |
| `Crop*`、`straightenAngle`、`HasCrop`、`Orientation` | 裁剪与旋转 |
| `Perspective*` | 透视校正 |
| `LensProfile*`、`LensManualDistortionAmount` | 镜头配置文件具体项 |
| `Defringe*` | 去边 |
| `GrayMixer*` | 黑白混合（本插件只支持 `ConvertToGrayscale` 开关本身） |
| `IncrementalTemperature`、`IncrementalTint` | 白平衡**增量**，语义与 `Temperature` / `Tint` 不同，混用会出错 |
| `Enable*` | 面板启用开关，不是可调参数 |
| `Auto*` | Auto 系列 / 自动设置缓存键 |
| `Brightness`、`HighlightRecovery`、`FillLight`、`ToneCurve`、`ChromaticAberration*`、`VignetteAmount`、`VignetteMidpoint` | PV2010 遗留键，在 Process Version 2012+ 下不生效 |
| `HDREditMode`、`HDR*`、`SDR*`、`Enhance*`、`Depth*`、`TrimStart`、`TrimEnd` | HDR / SDR 显示、AI 增强、视频剪辑等较新功能 |

### 第 2 组：真正未知的字段

不是已知的 Lightroom Develop 键。插件会记一条警告并继续应用其它字段，**不会崩溃**。
这一组出现时才值得留意 —— 可能是新版本字段，或 XMP 来自非 Lightroom 工具。

### 预设元数据（静默忽略）

`PresetType`、`UUID`、`Cluster`、`Group`、`Name`、`ShortName`、`SortName`、`Description`、
`Copyright`、`ContactInfo`、`Version`、`ProcessVersion`、`CameraModelRestriction`、
`HasSettings`、`AlreadyApplied`、`Supports*`、`RawFileName`、`AIColorSchema`、`AIVersion`

> **`ProcessVersion` 也在忽略列表里，是刻意的。** 它虽然是合法的 Develop 参数，
> 但改动它等于改变渲染基准，会在你没有预期的情况下改变影调。

---

## 已知限制

1. **一次只处理一张照片。** 多选时会先确认。
2. **虚拟副本（Virtual Copy）与主文件同名**，来源校验可能因此产生误判。
3. **非 RAW / DNG 文件的色温刻度可能不是 Kelvin。** 若照片是 JPEG/TIFF/PNG
   而 XMP 带 `Temperature`，插件会记一条警告提醒你核对预览效果（不做拦截）。
4. **读回校验可能出现「不一致」。** Lightroom 的 `getDevelopSettings()` 被官方标注为
   *experimental*，读回值存在已知滞后。因此插件把读回不一致只记为警告，不影响成功判定。
5. **`applyDevelopSettings` 是「增量合并」而不是「整体替换」。** 插件只写入 XMP 里出现的字段，
   照片上其它已有调整（裁剪、遮罩等）不会被清掉。
6. **不要用 `IMG_1023.xmp` 这种与照片同名的文件名**，否则有被 Lightroom 覆写的风险
   （插件会检测并提醒）。
7. **取值范围是「建议区间」**，来自 Lightroom UI 的滑块范围。
   若运行插件时 Lightroom 正处于「修改照片」模块，插件会尝试用运行时真实范围覆盖静态区间。
8. **扩展字段默认关闭**，需在界面勾选。
9. **日志会同时留一份在内存里**（最多 500 条），窗口上的 **View Log…** 可查看。

---

## 日志位置

插件使用 Lightroom 的 `LrLogger`，日志写在目录文件夹下的 `Lightroom Logs` 目录里：

```
<目录所在文件夹>/Lightroom Logs/AI-XMP-Color-Importer.log
```

例如目录是 `D:\Photos\Catalog`，日志就在该目录下的 `Lightroom Logs` 文件夹里。

一次 Apply 会在日志里留下这样的记录：

```
[2026-10-16 19:30:12]
APPLY

Preset:
  Natural Warm

Photo:
  IMG_1023.CR3

XMP:
  IMG_1023__Natural_Warm__AI-v1.xmp

XMP SourceFile:
  IMG_1023.CR3

AI Color Schema:
  1.0

Applied: 37 setting(s)
  Exposure2012 = +0.35
  Highlights2012 = -25
  ...

Clamped (轻微超范围，已收拢到合法区间): 1
  Contrast2012: 150 -> 100  (合法区间 -100 .. 100)

Ignored (元数据 / 不参与 Develop): 14
  PresetType
  UUID
  ...

Not applied (Lightroom 原生字段，V1 不处理): 3
  EnableLensCorrections  — 面板启用开关，不是可调参数
  ...

Result:
  SUCCESS
```

窗口上的 **View Log…** 按钮可查看本次会话日志（内存缓冲，最近 500 条）。

---

## 安全原则

| 原则 | 实现方式 |
|---|---|
| 不修改原 XMP | 对 XMP 文件只有读取路径，没有任何写入路径 |
| 不删除原 XMP | 同上 |
| 不覆盖原照片 | 只调用非破坏性的目录写入 |
| **不创建 Lightroom 预设** | 不使用任何预设相关 API |
| 不修改其它照片 | 写入函数只接受一个照片参数 |
| 应用前校验目标照片 | 来源不匹配时**默认取消** |
| 应用前校验参数 | 有校验错误时必须确认后才写入 |
| 单字段出错不崩溃 | 字段级错误只转成日志，其它字段照常应用 |
| 未知键不进入 SDK | 白名单过滤 + 写入前二次校验 |

---

## 目录结构

```
AI-generated-xmp-file-interface-plugin-for-lightroom-cc/
├── README.md                            ← 本文件
├── LICENSE
├── .gitignore
└── AI-XMP-Color-Importer.lrdevplugin/     ← 插件本体（在 Lightroom 中指向这个文件夹）
    ├── Info.lua                         ← 插件清单（菜单注册）
    ├── Main.lua                         ← 入口
    ├── manifest.lua                     ← 运行时清单与默认配置
    ├── src/
    │   ├── Loader.lua                   ← 模块加载器
    │   ├── Utils.lua                    ← 工具 + 平台抽象
    │   ├── Logger.lua                   ← 日志与结构化报告
    │   ├── XmpParser.lua                ← XMP / XML 解析器（纯 Lua）
    │   ├── XmpMapping.lua               ← 字段映射表（唯一事实来源）
    │   ├── Validation.lua               ← 范围校验（纯 Lua）
    │   ├── DevelopSettings.lua          ← 参数装配与预览（纯 Lua）
    │   ├── PhotoResolver.lua            ← 目标照片解析与来源匹配
    │   ├── ApplyEngine.lua              ← 无 UI 应用引擎（判定 / 确认 / 写入）
    │   └── ApplyDevelop.lua             ← 唯一的写入点
    ├── ui/
    │   ├── ImportDialog.lua             ← 主界面
    │   └── ProgressDialog.lua           ← 进度提示
    └── tests/                           ← 单元测试与 fixtures
```

---

## 开发与测试

测试**不需要 Lightroom**（核心解析 / 映射 / 校验逻辑不依赖 Lightroom 运行时）。

```bash
# 推荐：在真实的 Lua 5.1（Lightroom 内嵌版本）上运行
# 依赖：pip install lupa
python tests/run_lua51.py            # 186 个用例
python tests/run_lua51.py luajit21   # 换 LuaJIT 2.1 交叉验证
python tests/run_lua51.py lua54      # 换 Lua 5.4 交叉验证
```

| 运行时 | 结果 |
|---|---|
| Lua 5.1（lupa） | 186 passed / 0 failed |
| LuaJIT 2.1（lupa） | 186 passed / 0 failed |
| Lua 5.4（lupa） | 185 passed / 0 failed |

覆盖内容：解析器（命名空间、`rdf:Seq` / `Bag` / `Alt`、实体、CDATA、BOM、错误路径）、
字段映射与类型转换、白平衡与色调曲线转换、颜色分级别名、范围校验与收拢、
来源匹配、应用判定与安全阀，以及端到端加载检查。

**核心逻辑与界面是分开的。** `src/ApplyEngine.lua` 不弹任何对话框：
所有「需要人裁决」的情况（源文件不匹配、官方随图 XMP、字段校验有错）
都以结构化问题的形式交出，由调用方决定 —— 界面用对话框问，脚本用策略自动决定
（默认：不匹配与校验错误则跳过该照片，不写入）。所以这套逻辑可以直接被自动化复用。

调试提示：测试会同时把完整报告写到 `tests/.last-run.log`。

**注意**：Windows 上如果插件路径包含非 ASCII 字符，Lua 5.1 通过 C 的 `fopen`
读文件会失败。`tests/run_lua51.py` 会自动把插件复制到纯 ASCII 的临时目录再运行。

---

## 参考

实现以 Adobe 官方文档为准。SDK 可从 Adobe 开发者站获取（搜索 "Lightroom Classic SDK"），
压缩包内包含两份关键资料：

- **Lightroom Classic SDK Programmer's Guide**（PDF）——
  插件加载机制、`Info.lua` 结构、菜单项定义、脚本环境可用范围、错误处理方式等。
- **Lightroom Classic SDK API Reference**（HTML）——
  与本项目直接相关的模块：
  `LrPhoto`、`LrCatalog`、`LrDevelopController`、`LrDialogs`、`LrFileUtils`、
  `LrFunctionContext`、`LrPlugin`、`LrTasks`。

开发时有两处值得特别注意（都写进了本项目的代码注释与测试）：

1. **脚本环境**：Lightroom 不支持 Lua 5.1 的模块系统，`package` 不可用；
   `getfenv` / `setfenv` / `module` 也不可用。可用的是 `io` / `math` / `string`，
   以及 `loadfile` / `loadstring` 等部分全局函数。
2. **调用约定**：Lightroom 的不少 SDK 调用会让出（yield）给主循环，
   **不能包在 Lua 原生 `pcall` 里**（会报 `Yielding is not allowed within a C or
   metamethod call`）。受保护调用应使用 `LrFunctionContext.pcallWithContext`，
   顶层错误处理应使用 `LrFunctionContext` + `LrDialogs.attachErrorDialogToFunctionContext`。

---

## 授权

本项目以 [MIT 许可证](LICENSE) 发布。
