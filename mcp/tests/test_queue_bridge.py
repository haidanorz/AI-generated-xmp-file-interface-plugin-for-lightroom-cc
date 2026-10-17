"""队列桥接的单元测试。

用一个 FakePlugin 线程模拟 Lightroom 插件的行为（扫 inbox → 处理 → 写 results
→ 归档），因此不需要真的打开 Lightroom 就能覆盖整条链路，包括失败路径：

  * 监听器没开（job 永远躺在 inbox）
  * 插件取走了 job 但结果没落盘（JobLost，必须快速失败而不是死等）
  * 插件非原子写结果（读到半截 JSON 要能重试）
"""

from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
from pathlib import Path

from ai_color_mcp.queue_bridge import (
    BridgeError,
    JobLost,
    JobOptions,
    ListenerNotRunning,
    QueueBridge,
    read_json,
    summarize,
)


def fake_result(job: dict) -> dict:
    """插件成功时写出的结果形态（字段名与真机一致）。"""
    photos = [
        {
            "photo": p,
            "fileName": Path(p).name,
            "stage": "dryrun" if job["options"].get("dryRun") else "apply",
            "ok": True,
            "skipped": False,
            "applied": 0 if job["options"].get("dryRun") else 55,
            "wouldApply": 55,
            "historyStep": "AI Color: 海岸旷野-01-自然",
            "message": "ok",
            "errors": 0,
            "warnings": 4,
            "verify": None
            if job["options"].get("dryRun")
            else {
                "checked": 55,
                "mismatches": 0,
                "unverified": 0,
                "fields": [],
            },
        }
        for p in job["photos"]
    ]
    return {
        "id": job["id"],
        "ok": True,
        "dryRun": bool(job["options"].get("dryRun")),
        "pluginVersion": "1.0.0 (build 16)",
        "xmp": job["xmp"],
        "startedAt": "2026-10-17 19:00:00",
        "finishedAt": "2026-10-17 19:00:01",
        "counts": {"photos": len(photos), "ok": len(photos), "failed": 0, "skipped": 0},
        "photos": photos,
        "message": None,
    }


class FakePlugin(threading.Thread):
    """模拟插件的轮询监听器。"""

    def __init__(
        self,
        bridge: QueueBridge,
        *,
        delay: float = 0.0,
        write_result: bool = True,
        archive: bool = True,
        partial_first: bool = False,
    ) -> None:
        super().__init__(daemon=True)
        self.bridge = bridge
        self.delay = delay
        self.write_result = write_result
        self.archive = archive
        self.partial_first = partial_first
        self.stop_event = threading.Event()
        self.handled: list[str] = []

    def run(self) -> None:
        while not self.stop_event.is_set():
            for job_file in sorted(self.bridge.inbox.glob("*.json")):
                try:
                    job = json.loads(job_file.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, FileNotFoundError):
                    continue
                if self.delay:
                    time.sleep(self.delay)
                if self.write_result:
                    target = self.bridge.results / f"{job['id']}.json"
                    body = json.dumps(fake_result(job), ensure_ascii=False)
                    if self.partial_first:
                        # 模拟 Lua io 的非原子写：先落半截，再落完整
                        target.write_text(body[: len(body) // 2], encoding="utf-8")
                        time.sleep(0.25)
                    target.write_text(body, encoding="utf-8")
                if self.archive:
                    job_file.unlink(missing_ok=True)
                self.handled.append(job["id"])
            time.sleep(0.05)

    def stop(self) -> None:
        self.stop_event.set()
        self.join(timeout=5)


class BridgeTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.bridge = QueueBridge(
            self.root / "queue", poll_interval=0.05, result_timeout=5.0
        )
        self.bridge.ensure_dirs()

        self.xmp = self.root / "coast.xmp"
        self.xmp.write_text("<x:xmpmeta/>", encoding="utf-8")
        self.photos = []
        for name in ("A.ARW", "B.ARW"):
            p = self.root / name
            p.write_bytes(b"raw")
            self.photos.append(str(p))

    def tearDown(self) -> None:
        self._tmp.cleanup()


class TestHappyPath(BridgeTestBase):
    def test_dry_run_roundtrip(self) -> None:
        plugin = FakePlugin(self.bridge)
        plugin.start()
        try:
            result, job_id, elapsed = self.bridge.run(
                self.xmp,
                self.photos[:1],
                JobOptions(dry_run=True, verify=False),
                timeout=5,
            )
        finally:
            plugin.stop()

        self.assertTrue(job_id.startswith("mcp-"))
        self.assertTrue(result["ok"])
        self.assertTrue(result["dryRun"])

        payload = summarize(result, job_id, elapsed)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["counts"]["photos"], 1)
        self.assertEqual(payload["photos"][0]["would_apply"], 55)
        self.assertIsNone(payload["photos"][0]["verify"], "dryRun 不该有 verify 段")

        # 结束后 job 不应留在 inbox（插件已归档）
        self.assertEqual(list(self.bridge.inbox.glob("*.json")), [])

    def test_apply_writes_verify_block(self) -> None:
        plugin = FakePlugin(self.bridge)
        plugin.start()
        try:
            result, job_id, elapsed = self.bridge.run(
                self.xmp, self.photos, JobOptions(dry_run=False, verify=True), timeout=5
            )
        finally:
            plugin.stop()

        payload = summarize(result, job_id, elapsed)
        self.assertEqual(len(payload["photos"]), 2, "两张照片都要有条目")
        verify = payload["photos"][0]["verify"]
        self.assertIsNotNone(verify)
        self.assertEqual(verify["checked"], 55)
        self.assertEqual(verify["mismatches"], 0)
        self.assertEqual(verify["details"], [])
        self.assertEqual(payload["photos"][0]["history_step"], "AI Color: 海岸旷野-01-自然")

    def test_slow_plugin_still_succeeds(self) -> None:
        plugin = FakePlugin(self.bridge, delay=0.4)
        plugin.start()
        try:
            result, _, _ = self.bridge.run(
                self.xmp, self.photos[:1], JobOptions(dry_run=True), timeout=10
            )
        finally:
            plugin.stop()
        self.assertTrue(result["ok"])

    def test_partial_result_file_is_retried(self) -> None:
        """插件非原子写：先出现半截 JSON，不能因此报错。"""
        plugin = FakePlugin(self.bridge, partial_first=True)
        plugin.start()
        try:
            result, _, _ = self.bridge.run(
                self.xmp, self.photos[:1], JobOptions(dry_run=True), timeout=10
            )
        finally:
            plugin.stop()
        self.assertTrue(result["ok"])


class TestFailureModes(BridgeTestBase):
    def test_listener_not_running_is_explicit(self) -> None:
        """没有插件在跑时，超时信息必须指向「怎么开监听器」。"""
        with self.assertRaises(ListenerNotRunning) as ctx:
            self.bridge.run(
                self.xmp, self.photos[:1], JobOptions(dry_run=True), timeout=0.8
            )
        message = str(ctx.exception)
        self.assertIn("Start Automation Listener", message)
        self.assertIn("inbox", message)

    def test_job_lost_fails_fast(self) -> None:
        """job 被取走却没有结果：要早于总超时失败，而不是死等。"""
        plugin = FakePlugin(self.bridge, write_result=False, archive=True)
        plugin.start()
        bridge = QueueBridge(
            self.bridge.queue_dir, poll_interval=0.05, result_timeout=10.0, orphan_grace=0.4
        )
        started = time.monotonic()
        try:
            with self.assertRaises(JobLost):
                bridge.run(self.xmp, self.photos[:1], JobOptions(dry_run=True), timeout=10)
        finally:
            plugin.stop()
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 5, f"应在宽限期后立刻失败，实际等了 {elapsed:.1f}s")

    def test_xmp_missing(self) -> None:
        with self.assertRaises(BridgeError) as ctx:
            self.bridge.submit(self.root / "nope.xmp", self.photos[:1])
        self.assertIn("XMP 文件不存在", str(ctx.exception))

    def test_photo_missing(self) -> None:
        with self.assertRaises(BridgeError) as ctx:
            self.bridge.submit(self.xmp, [str(self.root / "nope.ARW")])
        self.assertIn("不存在", str(ctx.exception))

    def test_photos_empty(self) -> None:
        with self.assertRaises(BridgeError):
            self.bridge.submit(self.xmp, [])

    def test_too_many_photos(self) -> None:
        many = [str(self.root / f"{i}.ARW") for i in range(51)]
        for p in many:
            Path(p).write_bytes(b"x")
        with self.assertRaises(BridgeError) as ctx:
            self.bridge.submit(self.xmp, many)
        self.assertIn("50", str(ctx.exception))


class TestQueueMechanics(BridgeTestBase):
    def test_submit_is_atomic(self) -> None:
        """不能留下 .tmp，也不能让插件看见半个文件。"""
        job_id = self.bridge.submit(self.xmp, self.photos[:1])
        files = sorted(p.name for p in self.bridge.inbox.iterdir())
        self.assertEqual(files, [f"{job_id}.json"])
        job = json.loads((self.bridge.inbox / f"{job_id}.json").read_text(encoding="utf-8"))
        self.assertEqual(job["id"], job_id)
        self.assertEqual(job["options"]["dryRun"], False)
        self.assertEqual(job["photos"], [self.photos[0].replace("\\", "/")])

    def test_get_result_from_archive(self) -> None:
        job_id = "mcp-1-deadbe"
        (self.bridge.archive / f"failed-{job_id}.json").write_text(
            json.dumps({"id": job_id, "ok": False, "photos": []}), encoding="utf-8"
        )
        found = self.bridge.get_result(job_id)
        self.assertIsNotNone(found)
        self.assertFalse(found["ok"])

    def test_get_result_missing(self) -> None:
        self.assertIsNone(self.bridge.get_result("mcp-none"))

    def test_cleanup_keeps_recent(self) -> None:
        for i in range(8):
            p = self.bridge.results / f"mcp-{i}.json"
            p.write_text("{}", encoding="utf-8")
            # 让 mtime 有先后
            time.sleep(0.01)
        removed = self.bridge.cleanup_results(keep=3)
        self.assertEqual(removed, 5)
        self.assertEqual(len(list(self.bridge.results.glob("*.json"))), 3)

    def test_self_check(self) -> None:
        info = self.bridge.self_check()
        self.assertTrue(info["exists"])
        self.assertTrue(info["writable"])
        self.assertTrue(all(info["dirs"].values()))
        self.assertIn("Start Automation Listener", info["listener_hint"])

    def test_read_json_tolerates_partial(self) -> None:
        p = self.bridge.results / "half.json"
        p.write_text('{"id": "half", "photos": [', encoding="utf-8")
        self.assertIsNone(read_json(p))
        p.write_text('{"id": "half"}', encoding="utf-8")
        self.assertEqual(read_json(p)["id"], "half")


if __name__ == "__main__":
    unittest.main()
