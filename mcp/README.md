# AI XMP Color Importer — MCP 适配层（Phase A）

把 Lightroom 插件的文件队列包装成 [MCP](https://modelcontextprotocol.io) 工具，
让 Claude Desktop / WorkBuddy / 任意 Agent 能在对话里直接给照片上色，
并拿到结构化的结果（写了几张、哪些字段没落地）。

## 为什么必须多这一层

Lightroom 的 Lua 插件跑在一个没有 `socket` / `http` / `package` 的沙箱里，
**它无法监听端口，也就永远当不了 MCP server**。唯一被真机验证过的
进程间通道是插件自己的文件队列：

```
MCP 客户端  ⇄(stdio)⇄  MCP server（本目录）  ⇄(queue/)⇄  Lightroom 插件
```

所以这一层是**协议适配器**，不是插件的替代品：它只做三件事——
写 job、等结果、把失败翻译成能照做的建议。

## 安装

```bash
python -m pip install -r requirements.txt
python -m ai_color_mcp --check --queue-dir "<插件目录>/queue"
```

`--check` 不启动 MCP 协议，只打印一次环境自检（目录是否存在、可写、最近的 job），
排错时先跑它。

## 客户端配置

参考 `mcp.example.json`。三个要点：

| 项 | 说明 |
|---|---|
| `cwd` | 必须是本目录（`mcp/`），否则 `-m ai_color_mcp` 找不到模块 |
| `--queue-dir` | 指向 **Lightroom 实际加载的那个插件**下的 `queue/`，不是源码目录 |
| `command` | 用装了 `mcp` 的那个 Python；Windows 上写 `python.exe` 的绝对路径更稳 |

队列目录也可以不写，用环境变量 `AI_COLOR_QUEUE_DIR` 指定；都不给时会猜
`~/Pictures/Lightroom/AI-XMP-Color-Importer.lrdevplugin/queue`。

## 工具

| 工具 | 作用 | 会改照片吗 |
|---|---|---|
| `ai_color_dry_run` | 解析 XMP、算出要写多少字段、检查照片是否在目录里 | 否 |
| `ai_color_apply` | 真正写入 Develop 设置（可在 Lightroom 里撤销） | **是** |
| `ai_color_get_result` | 按 job 标识补查结果（超时后、或回看历史） | 否 |
| `ai_color_queue_status` | 队列目录自检 + 最近 job（排错第一步） | 否 |

`apply` 与 `dry_run` 刻意做成两个工具而不是一个布尔参数：
预演写成显式动词，AI 就没有「传错一个参数把照片改了」的机会。

### 返回结构

```jsonc
{
  "ok": true,
  "job_id": "mcp-1729150000-a1b2c3",
  "plugin_version": "1.0.0 (build 16)",
  "dry_run": false,
  "elapsed_sec": 2.13,
  "counts": { "photos": 1, "ok": 1, "failed": 0, "skipped": 0 },
  "photos": [
    {
      "file": "DSC05045.ARW",
      "stage": "apply",
      "ok": true,
      "applied": 55,
      "history_step": "AI Color: 海岸旷野-01-自然",
      "verify": { "checked": 55, "mismatches": 0, "unverified": 0, "details": [] }
    }
  ],
  "notice": "…仅在读回校验发现不一致时出现"
}
```

`verify` 需要插件 `build 16+`：它把「写进去」和「真的落地」区分开，
`mismatches > 0` 时 `details` 里是具体字段的 `field / want / got`。

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 报「job 仍在 inbox 里没有被取走」 | 监听器没开，或 `--queue-dir` 指向了别的目录 | 在 Lightroom 里 图库 ▸ 增效工具扩展 ▸ Start Automation Listener…；再用 `--check` 核对目录 |
| 报「job 已被取走但结果没有出现」 | 结果写盘失败（目录只读？） | 跑一次 Diagnostics 看文件自检 |
| 写中文路径失败 | 队列目录必须是纯 ASCII（插件用 Lua `io` 写结果，Windows 上是 ANSI fopen） | 把插件装在 ASCII 路径下 |
| 结果里没有 `verify` | 插件版本 < build 16 | 重载插件 |

## Phase A 的边界

- **没有 `analyze` / `diagnose`**：现有 job 契约要求 `photos` 非空，
  拿不到「只解析 XMP」的报告；诊断也要插件主动跑。两者都要等插件端加
  `action` 字段（Phase B）。
- 每次调用串行执行：Lightroom 的写权限是全局锁，并发没有收益。
- 一次最多 50 张照片（插件端安全阀）。

## 测试

```bash
python -m unittest discover -s tests -t . -v
```

`tests/test_queue_bridge.py` 用一个假插件线程覆盖整条链路，包括
「监听器没开」「job 被取走但结果丢了」「插件非原子写结果」这些真机上
很难复现的路径——不需要打开 Lightroom。
