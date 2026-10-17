"""MCP 工具层的测试：注册的 schema 对不对、错误路径怎么回给客户端。

真实的队列行为由 test_queue_bridge 覆盖；这里只测"AI 看到的那一层"：
工具名、参数、返回结构、以及基础设施故障是否转成可操作的错误。
"""

from __future__ import annotations

import json
import tempfile
import time
import unittest
from pathlib import Path

from ai_color_mcp import server
from ai_color_mcp.queue_bridge import JobOptions, QueueBridge


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


if __name__ == "__main__":
    unittest.main()
