"""队列桥接：MCP server 与 Lightroom 插件之间的唯一通道。

架构约束（为什么是文件队列，而不是 socket）：

    Lightroom 的 Lua 沙箱没有 socket / HTTP / package，
    插件无法监听端口，只能轮询目录。而 queue/{inbox,results,archive}
    是本项目唯一在真机上验证过的进程间通道：
        inbox/<id>.json   ← 我们写 job
        results/<id>.json → 插件写完，我们读
        archive/          ← 插件归档（失败件带 failed- 前缀）

约定与坑：

  * **job 文件必须原子写入**：插件每 1 秒扫一次 inbox，看到半个 JSON 会
    解析失败并把 job 归档成 failed-*。所以先写 `.json.tmp` 再 os.replace。
    （插件的 listPending 只挑 .json，`.json.tmp` 不会被误处理。）
  * **结果的唯一成功信号是 results/<id>.json 出现**。job 从 inbox 消失
    不代表成功——插件可能是归档了但结果写盘失败。所以消失后只给一小段
    宽限期（orphan_grace），过了就报 JobLost，不必死等超时。
  * **超时要能区分两种原因**：job 还在 inbox = 监听器没开（最常见）；
    job 不见了但没有结果 = 插件处理过但结果丢了。
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

# 默认队列位置：部署目录下的 queue/（ASCII 路径，插件端 io 的 ANSI 限制）
PLUGIN_DIR_NAME = "AI-XMP-Color-Importer.lrdevplugin"
ENV_QUEUE_DIR = "AI_COLOR_QUEUE_DIR"

LISTENER_HINT = (
    "Lightroom 的自动化监听器没有在运行。请打开 Lightroom Classic，"
    "进入 图库 ▸ 增效工具扩展 ▸ “AI Color: Start Automation Listener…”，"
    "或点一次 “AI Color: Diagnostics…” 确认队列目录是否与应用配置的一致。"
)


class BridgeError(RuntimeError):
    """桥接层的基础异常；消息会直接回给 AI 客户端，所以要可操作。"""


class ListenerNotRunning(BridgeError):
    """job 还躺在 inbox 里没人取——几乎总是监听器没开。"""


class JobTimeout(BridgeError):
    """等结果超时，但无法确定原因。"""


class JobLost(BridgeError):
    """job 被取走了却没有结果——插件处理过，结果没落盘。"""


@dataclass
class JobOptions:
    dry_run: bool = False
    verify: bool = True
    apply_extended_fields: bool = False
    policy: Mapping[str, str] | None = None

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "dryRun": bool(self.dry_run),
            "verify": bool(self.verify),
            "applyExtendedFields": bool(self.apply_extended_fields),
        }
        if self.policy:
            out["policy"] = dict(self.policy)
        return out


@dataclass
class QueueBridge:
    """一个队列目录的读写封装。可安全地在多线程里复用（内部串行化）。"""

    queue_dir: Path
    poll_interval: float = 0.15
    result_timeout: float = 120.0
    orphan_grace: float = 4.0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    # ------------------------------------------------------------------
    # 目录
    # ------------------------------------------------------------------

    def __post_init__(self) -> None:
        self.queue_dir = Path(self.queue_dir)

    @property
    def inbox(self) -> Path:
        return self.queue_dir / "inbox"

    @property
    def results(self) -> Path:
        return self.queue_dir / "results"

    @property
    def archive(self) -> Path:
        return self.queue_dir / "archive"

    def ensure_dirs(self) -> None:
        for d in (self.inbox, self.results, self.archive):
            d.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # 提交与等待
    # ------------------------------------------------------------------

    def new_job_id(self) -> str:
        """mcp-<epoch>-<6hex>：可排序、不撞手工 job、不含非法字符。"""
        return f"mcp-{int(time.time())}-{uuid.uuid4().hex[:6]}"

    def submit(
        self,
        xmp: str | os.PathLike[str],
        photos: Sequence[str | os.PathLike[str]],
        options: JobOptions | None = None,
        *,
        job_id: str | None = None,
    ) -> str:
        """写一个 job 到 inbox，返回 job_id。参数在这里做基础校验。"""
        options = options or JobOptions()
        job_id = job_id or self.new_job_id()

        xmp_path = Path(xmp)
        if not xmp_path.is_file():
            raise BridgeError(f"XMP 文件不存在：{xmp_path}")

        photo_list = [str(Path(p)) for p in photos]
        if not photo_list:
            raise BridgeError("photos 不能为空：至少给一张照片的绝对路径")

        missing = [p for p in photo_list if not Path(p).exists()]
        if missing:
            raise BridgeError("这些照片路径不存在：" + "；".join(missing))
        if len(photo_list) > 50:
            raise BridgeError(
                f"一个 job 最多 50 张照片（现在 {len(photo_list)} 张），"
                "请拆成多个 job —— 这是插件端的安全阀，避免一条错误指令批量改图"
            )

        job = {
            "id": job_id,
            "xmp": str(xmp_path).replace("\\", "/"),
            "photos": [p.replace("\\", "/") for p in photo_list],
            "options": options.to_json(),
        }

        # 原子写入：插件 1 秒扫一次，不能让它看见半个文件
        self.ensure_dirs()
        final = self.inbox / f"{job_id}.json"
        tmp = self.inbox / f".{job_id}.json.tmp"
        tmp.write_text(
            json.dumps(job, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        os.replace(tmp, final)
        return job_id

    def wait(self, job_id: str, timeout: float | None = None) -> dict[str, Any]:
        """等 results/<id>.json 出现。超时按原因抛不同的异常。"""
        timeout = self.result_timeout if timeout is None else timeout
        deadline = time.monotonic() + timeout

        job_file = self.inbox / f"{job_id}.json"
        missing_since: float | None = None

        while True:
            result = read_json(self.results / f"{job_id}.json")
            if result is not None:
                return result

            now = time.monotonic()
            if job_file.exists():
                missing_since = None
            else:
                # job 已被取走却没有结果：给宽限期，避免和插件写盘竞态
                if missing_since is None:
                    missing_since = now
                elif now - missing_since > self.orphan_grace:
                    archived = self.get_result(job_id)
                    if archived is not None:
                        return archived
                    raise JobLost(
                        f"job {job_id} 已被插件取走，但 results/{job_id}.json 没有出现。"
                        "通常是结果写盘失败（队列目录不可写？）——"
                        "请在 Lightroom 里运行 “AI Color: Diagnostics…” 看文件自检。"
                    )

            if now >= deadline:
                if job_file.exists():
                    raise ListenerNotRunning(
                        f"等了 {timeout:.0f} 秒，job 仍在 inbox 里没有被取走。\n{LISTENER_HINT}"
                    )
                raise JobTimeout(
                    f"等了 {timeout:.0f} 秒仍未拿到 results/{job_id}.json，"
                    "job 也不在 inbox 里。请运行 Diagnostics 查看插件状态。"
                )

            time.sleep(self.poll_interval)

    def run(
        self,
        xmp: str | os.PathLike[str],
        photos: Sequence[str | os.PathLike[str]],
        options: JobOptions | None = None,
        *,
        timeout: float | None = None,
    ) -> tuple[dict[str, Any], str, float]:
        """submit + wait，返回 (result, job_id, 耗时秒)。

        串行化：Lightroom 的写权限是全局锁，并发提交没有收益，
        反而容易让用户分不清哪次调用改的是哪张照片。
        """
        with self._lock:
            started = time.monotonic()
            job_id = self.submit(xmp, photos, options)
            result = self.wait(job_id, timeout)
            return result, job_id, time.monotonic() - started

    # ------------------------------------------------------------------
    # 结果读取
    # ------------------------------------------------------------------

    def get_result(self, job_id: str) -> dict[str, Any] | None:
        """先找 results/，再找 archive/（失败件带 failed- 前缀）。"""
        found = read_json(self.results / f"{job_id}.json")
        if found is not None:
            return found
        for name in (f"{job_id}.json", f"failed-{job_id}.json"):
            found = read_json(self.archive / name)
            if found is not None:
                return found
        return None

    def recent_jobs(self, limit: int = 5) -> list[dict[str, Any]]:
        """results/ 里最近的若干份结果（按文件名排序，job id 自带时间序）。"""
        if not self.results.is_dir():
            return []
        files = sorted(p for p in self.results.glob("*.json") if p.is_file())
        out: list[dict[str, Any]] = []
        for path in files[-limit:]:
            data = read_json(path)
            if data is None:
                continue
            out.append(
                {
                    "job_id": data.get("id") or path.stem,
                    "ok": data.get("ok"),
                    "dry_run": data.get("dryRun"),
                    "finished_at": data.get("finishedAt"),
                    "photos": len(data.get("photos") or []),
                }
            )
        return out

    def cleanup_results(self, keep: int = 20) -> int:
        """只保留最近 N 份结果，避免长期使用后 results/ 无限增长。"""
        if not self.results.is_dir():
            return 0
        files = sorted(
            (p for p in self.results.glob("*.json") if p.is_file()),
            key=lambda p: p.stat().st_mtime,
        )
        removed = 0
        for path in files[:-keep] if keep > 0 else files:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
        return removed

    # ------------------------------------------------------------------
    # 自检
    # ------------------------------------------------------------------

    def self_check(self) -> dict[str, Any]:
        """启动/排错用：目录在不在、可不可写、上次诊断报告多久前。"""
        info: dict[str, Any] = {
            "queue_dir": str(self.queue_dir),
            "exists": self.queue_dir.is_dir(),
            "dirs": {},
            "writable": False,
            "recent_jobs": [],
            "status_txt_age_sec": None,
            "listener_hint": LISTENER_HINT,
        }

        for name, d in (("inbox", self.inbox), ("results", self.results), ("archive", self.archive)):
            info["dirs"][name] = d.is_dir()

        try:
            self.ensure_dirs()
            probe = self.queue_dir / ".mcp-selftest"
            probe.write_text("ok", encoding="utf-8")
            info["writable"] = probe.read_text(encoding="utf-8") == "ok"
            probe.unlink(missing_ok=True)
        except OSError as exc:  # 目录只读 / 权限不足
            info["write_error"] = str(exc)

        status = self.queue_dir / "status.txt"
        if status.is_file():
            info["status_txt_age_sec"] = round(time.time() - status.stat().st_mtime, 1)

        info["recent_jobs"] = self.recent_jobs(3)
        return info


# ----------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------


def read_json(path: Path) -> dict[str, Any] | None:
    """读 JSON；文件不存在或正在被写（半截内容）都返回 None。

    插件用 Lua io 写结果，不是原子写，所以读到半截 JSON 是正常现象，
    下一次轮询就好——这里绝不能把 JSONDecodeError 抛出去。
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError):
        return None
    if not raw.strip():
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def discover_queue_dir(explicit: str | os.PathLike[str] | None = None) -> Path:
    """优先级：命令行参数 > 环境变量 > 常见的部署位置。

    队列目录必须放在这个位置才能被插件看到，猜错的话会表现为
    「监听器明明开着，job 就是没人取」——所以自检要把它打印出来。
    """
    if explicit:
        return Path(explicit).expanduser()
    env = os.environ.get(ENV_QUEUE_DIR)
    if env:
        return Path(env).expanduser()
    return Path.home() / "Pictures" / "Lightroom" / PLUGIN_DIR_NAME / "queue"


def summarize(result: Mapping[str, Any], job_id: str, elapsed: float) -> dict[str, Any]:
    """把插件的结果 JSON 换成 AI 好读的形态（字段名换成下划线风格）。"""
    photos: list[dict[str, Any]] = []
    for entry in result.get("photos") or []:
        verify = entry.get("verify")
        photos.append(
            {
                "file": entry.get("fileName") or entry.get("photo"),
                "path": entry.get("photo"),
                "stage": entry.get("stage"),
                "ok": entry.get("ok"),
                "skipped": bool(entry.get("skipped", False)),
                "applied": entry.get("applied", 0),
                "would_apply": entry.get("wouldApply", 0),
                "history_step": entry.get("historyStep"),
                "message": entry.get("message"),
                "verify": (
                    {
                        "checked": verify.get("checked", 0),
                        "mismatches": verify.get("mismatches", 0),
                        "unverified": verify.get("unverified", 0),
                        "read_error": verify.get("readError"),
                        "details": verify.get("fields") or [],
                    }
                    if isinstance(verify, Mapping)
                    else None
                ),
            }
        )

    return {
        "ok": bool(result.get("ok")),
        "job_id": result.get("id") or job_id,
        "plugin_version": result.get("pluginVersion"),
        "dry_run": bool(result.get("dryRun")),
        "elapsed_sec": round(elapsed, 2),
        "counts": result.get("counts") or {},
        "photos": photos,
        "message": result.get("message"),
    }
