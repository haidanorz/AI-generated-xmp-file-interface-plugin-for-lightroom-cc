"""AI XMP Color Importer — MCP 适配层。

把 Lightroom 插件的文件队列包装成 MCP 工具。插件本身跑在没有网络的
Lua 沙箱里，所以这一层是「协议适配器」，不是插件的替代品。
"""

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

__all__ = [
    "BridgeError",
    "JobLost",
    "JobOptions",
    "JobTimeout",
    "ListenerNotRunning",
    "QueueBridge",
    "discover_queue_dir",
    "summarize",
]

__version__ = "0.1.0"
