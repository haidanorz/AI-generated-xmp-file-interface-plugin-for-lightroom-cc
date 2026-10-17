"""最小 MCP 客户端冒烟测试：真的用 stdio 起一个 server，列工具、调一个只读工具。

存在的理由：单元测试只能证明函数返回对，证明不了
"stdio 协议跑得通、stdout 没被日志污染"。这条链路出错时症状很怪
（客户端直接断开、不报原因），所以留一个能手动跑的脚本。

    python tests/smoke_stdio.py
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

MCP_DIR = Path(__file__).resolve().parents[1]


async def main() -> int:
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "ai_color_mcp"],
        cwd=str(MCP_DIR),
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            print("tools:", names)

            result = await session.call_tool("ai_color_queue_status", {})
            text = "\n".join(
                c.text for c in result.content if getattr(c, "type", "") == "text"
            )
            info = json.loads(text)
            print("queue_dir:", info["queue_dir"])
            print("writable:", info["writable"])
            print("recent_jobs:", len(info["recent_jobs"]))

    expected = {
        "ai_color_apply",
        "ai_color_dry_run",
        "ai_color_get_result",
        "ai_color_queue_status",
    }
    if set(names) != expected:
        print("工具集合不符：", set(names) ^ expected, file=sys.stderr)
        return 1
    if not info["writable"]:
        print("队列目录不可写", file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
