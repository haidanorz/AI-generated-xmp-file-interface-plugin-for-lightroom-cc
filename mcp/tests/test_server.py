"""MCP 工具层的测试：注册的 schema 对不对、错误路径怎么回给客户端。

真实的队列行为由 test_queue_bridge 覆盖；这里只测"AI 看到的那一层"：
工具名、参数、返回结构、以及基础设施故障是否转成可操作的错误。
"""

from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from ai_color_mcp import server
from ai_color_mcp.queue_bridge import JobOptions, QueueBridge

try:  # `-s tests` 直接发现时为顶层模块，作为包导入时带 tests. 前缀
    from test_queue_bridge import FakePlugin
except ModuleNotFoundError:  # pragma: no cover
    from tests.test_queue_bridge import FakePlugin


class ToolSchemaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tools = {t.name: t for t in server.mcp._tool_manager.list_tools()}

    def test_expected_tools_registered(self) -> None:
        self.assertEqual(
            set(self.tools),
            {
                "ai_color_dry_run",
                "ai_color_apply",
                "ai_color_get_result",
                "ai_color_queue_status",
            },
        )

    def test_apply_schema_has_expected_parameters(self) -> None:
        schema = self.tools["ai_color_apply"].parameters
        props = schema.get("properties", {})
        self.assertIn("xmp", props)
        self.assertIn("photos", props)
        self.assertIn("verify", props)
        self.assertIn("apply_extended_fields", props)
        self.assertEqual(props["verify"].get("default"), True, "verify 默认应开启")

    def test_dry_run_schema_has_no_verify(self) -> None:
        """dry_run 没有 verify：预演不该有读回校验这种概念。"""
        props = self.tools["ai_color_dry_run"].parameters.get("properties", {})
        self.assertNotIn("verify", props)

    def test_descriptions_are_present(self) -> None:
        for name, tool in self.tools.items():
            self.assertTrue(tool.description, f"{name} 缺少描述")
        self.assertIn("不修改", self.tools["ai_color_dry_run"].description)


class VersionNoticeTest(unittest.TestCase):
    def test_build_number_parsing(self) -> None:
        self.assertEqual(server.build_number("1.0.0 (build 16)"), 16)
        self.assertEqual(server.build_number("1.0.0 (build 14)"), 14)
        self.assertEqual(server.build_number(None), 0)
        self.assertEqual(server.build_number("garbage"), 0)

    def test_old_build_warns_about_missing_verify(self) -> None:
        notice = server.version_notice("1.0.0 (build 14)")
        self.assertIsNotNone(notice)
        self.assertIn("verify", notice)
        self.assertIn("重新加载增效工具", notice)

    def test_current_build_has_no_notice(self) -> None:
        self.assertIsNone(server.version_notice("1.0.0 (build 16)"))
        self.assertIsNone(server.version_notice(None))


class ToolBehaviourTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.bridge = QueueBridge(root / "queue", poll_interval=0.05)
        self.bridge.ensure_dirs()
        self.xmp = root / "a.xmp"
        self.xmp.write_text("<x/>", encoding="utf-8")
        self.photo = root / "A.ARW"
        self.photo.write_bytes(b"raw")
        server._bridge = self.bridge

    def tearDown(self) -> None:
        server._bridge = None
        self._tmp.cleanup()

    def test_queue_status_returns_self_check(self) -> None:
        info = server.ai_color_queue_status()
        self.assertTrue(info["writable"])
        self.assertIn("listener_hint", info)

    def test_get_result_missing_raises_tool_error(self) -> None:
        with self.assertRaises(Exception) as ctx:
            server.ai_color_get_result("mcp-nope")
        self.assertIn("找不到", str(ctx.exception))

    def test_listener_down_produces_actionable_error(self) -> None:
        with self.assertRaises(Exception) as ctx:
            server.ai_color_dry_run(
                str(self.xmp), [str(self.photo)], timeout_sec=0.6
            )
        message = str(ctx.exception)
        self.assertIn("Start Automation Listener", message)

    def test_dry_run_summary_shape(self) -> None:
        """用假结果直接验 summarize 的输出（不跑插件线程）。"""
        job_id = "mcp-1-abc123"
        raw = {
            "id": job_id,
            "ok": True,
            "dryRun": True,
            "pluginVersion": "1.0.0 (build 16)",
            "counts": {"photos": 1, "ok": 1, "failed": 0, "skipped": 0},
            "photos": [
                {
                    "photo": str(self.photo),
                    "fileName": "A.ARW",
                    "stage": "dryrun",
                    "ok": True,
                    "applied": 0,
                    "wouldApply": 55,
                    "historyStep": "AI Color: 海岸旷野-01-自然",
                }
            ],
        }
        payload = server.summarize(raw, job_id, 0.5)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["dry_run"])
        self.assertEqual(payload["photos"][0]["would_apply"], 55)
        self.assertIsNone(payload["photos"][0]["verify"])
        json.dumps(payload)  # 必须可 JSON 序列化（MCP 会序列化返回）


class ResultPruneTest(unittest.TestCase):
    """results/ 的清理必须真的接上，而且**永远不能影响调用结果**。

    之前 `QueueBridge.cleanup_results` 写了却没人调用 → 队列目录无限增长。
    """

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.bridge = QueueBridge(root / "queue", poll_interval=0.05)
        self.bridge.ensure_dirs()
        self.xmp = root / "a.xmp"
        self.xmp.write_text("<x/>", encoding="utf-8")
        self.photo = root / "A.ARW"
        self.photo.write_bytes(b"raw")

        self._old_keep = server._keep_results
        server._bridge = self.bridge
        server._keep_results = 3

        # 预埋 6 份"旧结果"，mtime 递增，模拟长期使用后的堆积
        for i in range(6):
            path = self.bridge.results / f"old-{i}.json"
            path.write_text("{}", encoding="utf-8")
            os.utime(path, (1_000_000 + i, 1_000_000 + i))

        self.plugin = FakePlugin(self.bridge)
        self.plugin.start()

    def tearDown(self) -> None:
        self.plugin.stop_event.set()
        self.plugin.join(timeout=2)
        server._bridge = None
        server._keep_results = self._old_keep
        self._tmp.cleanup()

    def results(self) -> list[Path]:
        return sorted(self.bridge.results.glob("*.json"))

    def test_successful_call_prunes_old_results(self) -> None:
        out = server.ai_color_dry_run(str(self.xmp), [str(self.photo)], timeout_sec=5)
        files = self.results()
        self.assertEqual(len(files), 3, [p.name for p in files])
        self.assertIn(f"{out['job_id']}.json", [p.name for p in files], "本次结果不能被清掉")
        # 保留的应是最新的：old-5 / old-4 还在，old-0 已被删
        names = {p.name for p in files}
        self.assertIn("old-5.json", names)
        self.assertNotIn("old-0.json", names)

    def test_keep_zero_disables_pruning(self) -> None:
        server._keep_results = 0
        server.ai_color_dry_run(str(self.xmp), [str(self.photo)], timeout_sec=5)
        self.assertEqual(len(self.results()), 7, "keep=0 表示不清理")

    def test_prune_failure_never_breaks_the_call(self) -> None:
        """清理失败（权限 / 文件被占用）不能让用户以为照片没写成功。"""

        def boom(keep: int = 20) -> int:
            raise OSError("locked")

        self.bridge.cleanup_results = boom  # type: ignore[method-assign]
        out = server.ai_color_dry_run(str(self.xmp), [str(self.photo)], timeout_sec=5)
        self.assertTrue(out["ok"])
        self.assertEqual(len(self.results()), 7, "清理失败时旧文件原样保留")


class ParamDefaultTest(unittest.TestCase):
    """`Field(default=...)` 在直接调用时是 FieldInfo 对象，恒为真值。

    省略 `apply_extended_fields` 就等于**悄悄打开扩展字段**（55 → 73 个字段，
    多写暗角等 18 个）。这个 bug 在真机上被发现：同一个 XMP 两次 dry run
    字段数不同，一查是呼叫方式差异。
    """

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.bridge = QueueBridge(root / "queue", poll_interval=0.05)
        self.bridge.ensure_dirs()
        self.xmp = root / "a.xmp"
        self.xmp.write_text("<x/>", encoding="utf-8")
        self.photo = root / "A.ARW"
        self.photo.write_bytes(b"raw")
        self._old_bridge = server._bridge
        server._bridge = self.bridge
        self.plugin = FakePlugin(self.bridge)
        self.plugin.start()

        self.seen: list[JobOptions] = []
        real_submit = self.bridge.submit

        def spy(xmp, photos, options=None, *, job_id=None):  # noqa: ANN001
            self.seen.append(options)
            return real_submit(xmp, photos, options, job_id=job_id)

        self.bridge.submit = spy  # type: ignore[method-assign]

    def tearDown(self) -> None:
        self.plugin.stop_event.set()
        self.plugin.join(timeout=2)
        server._bridge = self._old_bridge
        self._tmp.cleanup()

    def test_flag_helper_ignores_non_bool(self) -> None:
        from pydantic.fields import FieldInfo

        self.assertFalse(server._flag(FieldInfo(default=False), False))
        self.assertFalse(server._flag(None, False))
        self.assertTrue(server._flag(True, False))
        self.assertFalse(server._flag(False, True))

    def test_timeout_helper_ignores_non_number(self) -> None:
        from pydantic.fields import FieldInfo

        self.assertEqual(server._timeout(FieldInfo(default=60.0), 60.0), 60.0)
        self.assertEqual(server._timeout(None, 120.0), 120.0)
        self.assertEqual(server._timeout(5, 120.0), 5.0)

    def test_dry_run_without_flags_keeps_extended_fields_off(self) -> None:
        server.ai_color_dry_run(str(self.xmp), [str(self.photo)])
        self.assertEqual(len(self.seen), 1)
        self.assertFalse(self.seen[0].apply_extended_fields)
        self.assertEqual(self.seen[0].to_json()["applyExtendedFields"], False)

    def test_apply_without_flags_defaults_verify_on(self) -> None:
        server.ai_color_apply(str(self.xmp), [str(self.photo)])
        self.assertTrue(self.seen[0].verify)
        self.assertFalse(self.seen[0].apply_extended_fields)


if __name__ == "__main__":
    unittest.main()