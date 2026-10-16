#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tests/run_lua51.py  —  在「真正的 Lua 5.1 / LuaJIT」上运行插件测试

为什么需要这个：
    Adobe Lightroom Classic 内嵌的 Lua 运行时是 **Lua 5.1**。
    本项目用 lupa 提供真实的 Lua 5.1 与 LuaJIT 2.1 运行时，
    因此可以做到「与 Lightroom 同版本语义」的单元测试。

    （fengari 是 Lua 5.3 且默认不提供 io 库，只适合做语法检查，
      不适合跑依赖 fixture 文件的用例。）

关于路径：
    Lua 5.1 在 Windows 上通过 C 的 fopen 读文件，路径按当前 ANSI 代码页解释。
    若插件所在路径包含非 ASCII 字符（例如中文目录名），Lua 侧会「找不到文件」。
    脚本会自动把插件复制一份到纯 ASCII 的临时目录再运行，并把日志回写到原目录。

用法：
    python tests/run_lua51.py [runtime] [pluginRoot]
        runtime     : lua51（默认） | luajit21 | lua54
        pluginRoot  : 可选，默认取本脚本所在目录的上一级

示例：
    python tests/run_lua51.py
    python tests/run_lua51.py luajit21
"""

import importlib
import os
import shutil
import sys
import tempfile


def stage(src_root):
    """如果路径含非 ASCII 字符，复制一份到临时 ASCII 目录后返回新的根目录。"""
    if os.path.abspath(src_root).isascii():
        return src_root, None

    tmp = tempfile.mkdtemp(prefix="aicolor_lua_")
    dst = os.path.join(tmp, "AIColorPlugin.lrdevplugin")
    shutil.copytree(src_root, dst)
    return dst, tmp


def main():
    runtime = sys.argv[1] if len(sys.argv) > 1 else "lua51"

    here = os.path.dirname(os.path.abspath(__file__))
    original_root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(here)
    original_root = os.path.abspath(original_root)

    try:
        mod = importlib.import_module("lupa." + runtime)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(
            "无法加载 lupa.%s: %s\n"
            "可用的运行时通常是 lua51 / luajit21 / lua54；请先执行: pip install lupa\n"
            % (runtime, exc)
        )
        return 3

    run_root, tmp_dir = stage(original_root)
    script = os.path.join(run_root, "tests", "run_tests.lua").replace("\\", "/")
    root_s = run_root.replace("\\", "/")

    lua = mod.LuaRuntime(unpack_returned_tuples=True)

    # 屏蔽 os.exit，避免 Lua 直接把 Python 进程杀掉，同时保留退出码
    lua.execute("_ai_exit_code = nil")
    lua.execute("os.exit = function(c) _ai_exit_code = c end")

    lua.execute("arg = {}")
    lua.execute('arg[0] = "%s"' % script)
    lua.execute('arg[1] = "%s"' % root_s)

    print("=== Lua runtime : %s (reports %s) ===" % (runtime, lua.eval("_VERSION")))
    print("=== plugin root : %s ===" % root_s)
    if tmp_dir:
        print("=== note        : 原路径含非 ASCII 字符，已在临时目录副本中运行 ===")
    sys.stdout.flush()

    with open(script, "r", encoding="utf-8") as fh:
        code = fh.read()

    lua.execute(code)

    exit_code = 0
    code_val = lua.eval("_ai_exit_code")
    if code_val:
        exit_code = int(code_val)

    # 把日志回写到源码目录，便于直接查看
    staged_log = os.path.join(run_root, "tests", ".last-run.log")
    if os.path.isfile(staged_log):
        try:
            shutil.copyfile(
                staged_log,
                os.path.join(original_root, "tests", ".last-run.log"),
            )
        except Exception:  # noqa: BLE001
            pass

    if tmp_dir:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
