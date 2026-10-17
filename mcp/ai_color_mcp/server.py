"""AI XMP Color Importer 的 MCP server（Phase A）。

对上：MCP 客户端（Claude Desktop / WorkBuddy / 任意 Agent）通过 stdio 调工具。
对下：把调用翻译成 queue/inbox 里的 job.json，等插件写回 results/<id>.json。

为什么必须这么绕：Lightroom 的 Lua 插件跑在没有 socket 的沙箱里，
只能轮询目录。**MCP server 是适配层，不是插件的替代品。**

设计取舍（用户拍板）：
  * apply 与 dry_run 是两个工具，不是同一个工具的布尔参数——
    预演写成显式动词，AI 就没有"传错一个参数把照片改了"的机会。
  * Phase A 不含 analyze / diagnose：现有 job 契约要求 photos 非空，
    拿不到"只解析 XMP"的报告。这两个能力要等插件端加 action（Phase B）。
"""

from __future__ import annotations

import argparse
import logging
import sys
from typing import Annotated, Iterable

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from pydantic import Field

from .queue_bridge import (
    BridgeError,
    JobLost,
    JobOptions,
    JobTimeout,
    ListenerNotRunning,
    QueueBridge,
    discover_queue_dir,
    summarize,
)

# stdout 属于 MCP 协议，任何日志都必须走 stderr。
# Windows 控制台默认 cp936，不显式改编码的话中文日志会变乱码 —— 排错时很要命。
if hasattr(sys.stderr, "reconfigure"):
    try:
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        pass

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="[ai-color-mcp] %(levelname)s %(message)s",
)
log = logging.getLogger("ai-color-mcp")

mcp = FastMCP(
    "ai-color-importer",
    instructions=(
        "把 AI 生成的 XMP 调色方案写进 Lightroom Classic 的照片。"
        "写操作不可凭空撤销，所以：先用 ai_color_dry_run 预演，确认字段数与告警，"
        "再调 ai_color_apply；apply 之后看返回里每张照片的 verify 段"
        "（checked / mismatches）判断字段是否真的落地。"
        "调用前请确认用户在 Lightroom 里开启了自动化监听器"
        "（图库 ▸ 增效工具扩展 ▸ AI Color: Start Automation Listener…），"
        "否则 job 会一直等在队列里。"
    ),
)

_bridge: QueueBridge | None = None

# results/ 只保留最近 N 份。每调一次工具就多一份结果文件，长期使用会无限增长；
# 0 表示不清理（排错时想要完整历史就设 0）。
RESULT_KEEP = 20
_keep_results = RESULT_KEEP


def configure(
    queue_dir: str | None = None,
    *,
    timeout: float | None = None,
    keep_results: int | None = None,
) -> QueueBridge:
    """设置/替换全局桥接实例（命令行与测试都用它）。"""
    global _bridge, _keep_results
    kwargs = {}
    if timeout is not None:
        kwargs["result_timeout"] = timeout
    if keep_results is not None:
        _keep_results = max(0, int(keep_results))
    _bridge = QueueBridge(discover_queue_dir(queue_dir), **kwargs)
    log.info("队列目录：%s（结果保留最近 %d 份）", _bridge.queue_dir, _keep_results)
    return _bridge


def _prune_results() -> None:
    """清掉 results/ 里的旧结果。

    纯 housekeeping：**失败绝不影响本次调用**——用户要的是照片被写好，
    不是队列目录干净。所以这里吞掉所有异常，只记一条 warning。
    """
    if _keep_results <= 0:
        return
    try:
        removed = bridge().cleanup_results(keep=_keep_results)
    except OSError as exc:  # 权限 / 文件被别人占用
        log.warning("清理旧结果失败（不影响本次调用）：%s", exc)
        return
    if removed:
        log.info("清理了 %d 份旧结果（保留最近 %d 份）", removed, _keep_results)


def bridge() -> QueueBridge:
    global _bridge
    if _bridge is None:
        _bridge = QueueBridge(discover_queue_dir(None))
    return _bridge


MIN_VERIFY_BUILD = 16


def _flag(value: object, default: bool) -> bool:
    """把工具参数归一化成 bool。

    ★ 为什么需要这个：`Field(default=False)` 写在函数签名里，**直接调用函数**
    （不经过 MCP 协议）时拿到的是 `FieldInfo` 对象本身，而它恒为真值 ——
    于是 `apply_extended_fields` 省略不传就等于 True，悄悄多写 18 个扩展字段。
    MCP 协议路径上框架会填真默认值，所以只有 Python 侧直调（测试 / 内嵌）会中招。
    """
    return value if isinstance(value, bool) else default


def _timeout(value: object, default: float | None) -> float | None:
    """同上：`timeout_sec` 省略时会把 FieldInfo 传进 time.monotonic() 相加。"""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return float(value)


def build_number(plugin_version: str | None) -> int:
    """从 "1.0.0 (build 16)" 里取出 16；认不出来就返回 0。"""
    if not plugin_version:
        return 0
    try:
        tail = str(plugin_version).rsplit("build ", 1)[1]
        return int("".join(ch for ch in tail if ch.isdigit()) or 0)
    except (IndexError, ValueError):
        return 0


def version_notice(plugin_version: str | None) -> str | None:
    """低于 build 16 时明确告诉调用方：结果里不会有 verify。

    真机踩过：manifest 在插件首次 Boot 时被缓存，重载文件后可能仍报旧版本，
    而"跑新代码、报旧版本号"会让人误判校验功能没生效。
    """
    build = build_number(plugin_version)
    if 0 < build < MIN_VERIFY_BUILD:
        return (
            f"插件版本 {plugin_version} 早于 build {MIN_VERIFY_BUILD}："
            "本次结果里不会有 verify 数据。请在 Lightroom 里重新加载增效工具"
            "（文件 ▸ 增效工具 ▸ 重新加载增效工具）后再试。"
        )
    return None


def _call(
    xmp: str,
    photos: Iterable[str],
    *,
    dry_run: bool,
    verify: bool,
    apply_extended_fields: bool,
    timeout_sec: float | None,
) -> dict:
    options = JobOptions(
        dry_run=dry_run,
        verify=verify,
        apply_extended_fields=apply_extended_fields,
    )
    try:
        result, job_id, elapsed = bridge().run(
            xmp, list(photos), options, timeout=timeout_sec
        )
    except ListenerNotRunning as exc:
        raise ToolError(str(exc)) from exc
    except JobLost as exc:
        raise ToolError(str(exc)) from exc
    except JobTimeout as exc:
        raise ToolError(
            str(exc) + "（结果可能已经写出来了，稍后可以用 ai_color_get_result 补查）"
        ) from exc
    except BridgeError as exc:  # 参数类错误：路径不存在、张数超限
        raise ToolError(str(exc)) from exc

    payload = summarize(result, job_id, elapsed)

    # 温和提示，不改变 ok 判定
    notice_version = version_notice(payload.get("plugin_version"))
    if notice_version:
        payload["notice_version"] = notice_version

    if not dry_run and payload["ok"]:
        mismatched = [p for p in payload["photos"] if (p["verify"] or {}).get("mismatches")]
        if mismatched:
            payload["notice"] = (
                f"{len(mismatched)} 张照片的读回校验有不一致字段，"
                "详见 photos[].verify.details（Lightroom 的读回存在已知滞后，"
                "多数稍后会一致；若持续不一致，多半是这类字段被 SDK 忽略）"
            )

    # 结果已经在手里了，再清理旧文件；放最后是为了任何清理问题都影响不到返回值
    _prune_results()
    return payload


# ----------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------


@mcp.tool()
def ai_color_dry_run(
    xmp: str = Field(description="XMP 调色文件的绝对路径（只读，不会被修改）"),
    photos: list[str] = Field(description="目标照片的绝对路径列表，最多 50 张"),
    apply_extended_fields: bool = Field(
        default=False, description="是否同时应用扩展字段（暗角等，默认关闭）"
    ),
    timeout_sec: float | None = Field(
        default=60.0, description="等待 Lightroom 返回的秒数"
    ),
) -> dict:
    """预演：解析 XMP 并算出要写多少字段，但**不修改任何照片**。

    用于在真写之前确认：字段数、告警数、校验错误数，以及照片是否能在目录里找到。
    任何一个 job 都可以安全地反复 dry run。
    """
    return _call(
        xmp,
        photos,
        dry_run=True,
        verify=False,
        apply_extended_fields=_flag(apply_extended_fields, False),
        timeout_sec=_timeout(timeout_sec, 60.0),
    )


@mcp.tool()
def ai_color_apply(
    xmp: str = Field(description="XMP 调色文件的绝对路径（只读，不会被修改）"),
    photos: list[str] = Field(description="目标照片的绝对路径列表，最多 50 张"),
    verify: bool = Field(
        default=True,
        description="写完读回校验（建议保持开启；结果里的 verify 段会告诉你字段是否真的落地）",
    ),
    apply_extended_fields: bool = Field(
        default=False, description="是否同时应用扩展字段（暗角等，默认关闭）"
    ),
    timeout_sec: float | None = Field(
        default=120.0, description="等待写权限与写入完成的秒数，照片多时要放大"
    ),
) -> dict:
    """把调色方案写进照片的 Develop 设置（真实修改，可在 Lightroom 里撤销）。

    写入不经过 Preset，因此不会污染预设列表。调用前建议先 ai_color_dry_run。
    """
    return _call(
        xmp,
        photos,
        dry_run=False,
        verify=_flag(verify, True),
        apply_extended_fields=_flag(apply_extended_fields, False),
        timeout_sec=_timeout(timeout_sec, 120.0),
    )


@mcp.tool()
def ai_color_get_result(
    job_id: str = Field(description="job 标识，例如 mcp-1729150000-a1b2c3"),
) -> dict:
    """按 job 标识补查结果（适用于超时后、或想回看历史 job）。"""
    result = bridge().get_result(job_id)
    if result is None:
        raise ToolError(
            f"找不到 job {job_id} 的结果（results/ 与 archive/ 都没有）。"
            "如果刚提交就超时，可能是监听器没开。"
        )
    return summarize(result, job_id, 0.0)


@mcp.tool()
def ai_color_queue_status() -> dict:
    """查看队列与插件环境：目录是否存在可写、最近的 job、上次诊断报告多久前。

    排错第一步。如果 writable=false 或 dirs 有 false，先解决路径问题。
    """
    return bridge().self_check()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="ai-color-mcp", description=__doc__)
    parser.add_argument(
        "--queue-dir",
        default=None,
        help="插件队列目录（默认取 AI_COLOR_QUEUE_DIR 或 Pictures/Lightroom/<插件>/queue）",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help="默认等待结果的秒数（工具参数可覆盖）",
    )
    parser.add_argument(
        "--keep-results",
        type=int,
        default=None,
        help=f"results/ 保留最近多少份结果（默认 {RESULT_KEEP}，0 = 不清理）",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="只做一次环境自检并打印 JSON（不启动 MCP 协议，便于排错）",
    )
    args = parser.parse_args(argv)

    configure(args.queue_dir, timeout=args.timeout, keep_results=args.keep_results)

    if args.check:
        import json

        print(json.dumps(bridge().self_check(), ensure_ascii=False, indent=2))
        return

    mcp.run()


if __name__ == "__main__":
    main()
