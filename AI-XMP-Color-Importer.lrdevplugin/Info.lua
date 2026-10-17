--[[
    Info.lua  —  Lightroom Classic SDK 插件清单（真正的 SDK manifest）

    本文件是 Lightroom 启动扫描插件时读取的唯一入口，必须：
      * 纯数据：不得调用 import / require（官方明确：本文件运行在一个比普通脚本
        更受限的 Lua 环境里，"you cannot use import or require in this context"）
      * 直接 return 一个 table

    版本号等常量与 manifest.lua 保持一致（由单元测试强制校验，防止漂移）。

    ==================================================================
    菜单（已按官方文档逐字核实，2026-10-16 修复）
    ==================================================================
    官方 SDK **只允许三个菜单键**，且菜单 **只有一层，没有子菜单写法**：

        LrExportMenuItems    ->  文件     ▸ 增效工具扩展
        LrLibraryMenuItems   ->  图库     ▸ 增效工具扩展
        LrHelpMenuItems      ->  帮助     ▸ 增效工具扩展

    不存在 LrDevelopMenuItems / LrFileMenuItems / LrPluginExtrasMenuItem
    —— 这三个名字在整本官方指南里出现次数为 0，写进去会被静默忽略。

    每个菜单项成员表**只接受三个字段**：
        title       (String)           显示名称
        file        (String)           被点击时执行的 Lua 文件
        enabledWhen (String, optional) photosAvailable / photosSelected /
                                       videosSelected / anythingSelected

    ★ 依据：Lightroom Classic SDK Programmers Guide, Chapter 2,
      "Defining menu items for a plug-in"（p.35-36）原文：
        "Each item is a table of tables, and each member table defines one menu
         item. The member table for a menu item should contain these entries:
         title (String) ... file (String) ... enabledWhen (String, optional) ..."

    ★ 结论：常见的两级子菜单设想，例如
          Library ▸ AI Color ▸ Apply XMP to Target Photo
      这种**两级子菜单在插件 SDK 中无法实现** —— 这是 SDK 限制，不是实现取舍。
      改用自描述的单层标题，让它在「增效工具扩展」里依然一目了然：
          图库 ▸ 增效工具扩展 ▸ "AI Color: Apply XMP to Target Photo…"

    ★ 关于 enabledWhen：刻意**不设置**，使菜单项始终可点击，
      从而让 Main.lua 能弹出「请先选择目标照片」这类友好提示
      「请先在 Lightroom Library 中选择目标照片。」
      如果你更希望没选照片时菜单直接变灰，加上
          enabledWhen = "photosSelected",
      即可。
--]]

return {

    ------------------------------------------------------------------
    -- SDK / 身份
    ------------------------------------------------------------------
    LrSdkVersion         = 11.4,
    LrSdkMinimumVersion  = 11.4,

    LrToolkitIdentifier  = "com.aicolor.xmp-importer",
    LrPluginName         = "AI XMP Color Importer",

    VERSION = { major = 1, minor = 0, revision = 0, build = 12 },

    ------------------------------------------------------------------
    -- 菜单项
    --   file 相对于插件根目录。每个成员表只能有 title / file / enabledWhen。
    --   两个入口都指向 Main.lua，由 Main.lua 统一分发。
    ------------------------------------------------------------------
    LrExportMenuItems = {
        {
            title = "AI Color: Apply XMP to Target Photo…",
            file  = "Main.lua",
        },
    },

    LrLibraryMenuItems = {
        {
            title = "AI Color: Apply XMP to Target Photo…",
            file  = "Main.lua",
        },
        {
            -- 自动化监听**必须由用户手动开启**（不随插件加载自动运行）
            title = "AI Color: Start Automation Listener…",
            file  = "AutomationStart.lua",
        },
        {
            title = "AI Color: Stop Automation Listener…",
            file  = "AutomationStop.lua",
        },
    },
}
