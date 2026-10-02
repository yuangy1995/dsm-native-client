#!/usr/bin/env python3
"""从现有合成请求生成跨端 API 参数目录，不复制参数值或提升兼容证据。"""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs/api/reference/requests.md"
MODULES = {
    "file-station": "文件、分享与远程连接",
    "photos": "照片",
    "chat": "聊天",
    "download-station": "下载管理",
    "container-manager": "容器",
    "vmm": "虚拟机",
    "file-services": "文件服务",
    "hardware": "硬件与 UPS",
    "security": "安全设置",
    "ddns": "DDNS",
    "network": "网络",
    "packages": "套件",
    "region": "区域与时间",
    "storage": "存储",
    "system-power": "系统电源",
    "users": "账号",
    "groups": "群组",
    "system-performance": "资源监控",
    "system-update": "系统更新检查",
    "terminal": "终端",
}


def code(value: object) -> str:
    return "`" + str(value).replace("|", "&#124;").replace("`", "") + "`"


def render() -> str:
    groups: dict[str, list[tuple[Path, dict]]] = defaultdict(list)
    for path in sorted((ROOT / "contracts/request-fixtures").rglob("request.json")):
        item = json.loads(path.read_text(encoding="utf-8"))
        groups[path.relative_to(ROOT / "contracts/request-fixtures").parts[0]].append((path, item))
    lines = [
        "<!-- generated-by: tools/codex/generate_api_reference.py -->",
        "# 请求参数目录（由合成快照生成）", "",
        "本页直接读取 `contracts/request-fixtures`，只列请求形态和调用策略，不保存参数值。",
        "这些快照证明已有客户端请求的约束，**不是全部 macOS 功能清单，也不证明真实 NAS 兼容**。",
        "功能流程、未被快照覆盖的读取接口和响应结构见[API 入口](../README.md)。", "",
        "`版本`为样例的 preferred/resolved 版本；`路径`为该样例的发现结果，运行时仍须读取能力。",
        "参数表列本场景实际发送的字段，不把出现过的字段全部认定为必填。",
        "秘密参数只标记类型与“敏感”；可选值、JSON 内部结构及精确编码打开对应快照查看。",
        "认证、重试与结果规则见[通用标准](common.md)。", "",
        "重新生成：`python3 tools/codex/generate_api_reference.py`；校验：加 `--check`。", "",
    ]
    for module in sorted(groups):
        lines.extend([f"## {module}", "", MODULES.get(module, module), "",
            "| 场景与快照 | API / method | 版本；路径 | HTTP / 参数格式 | 业务参数（名称：类型） | 认证与执行约束 |",
            "| --- | --- | --- | --- | --- | --- |"])
        for path, item in groups[module]:
            api, transport, auth, policy = (item[k] for k in ("api", "transport", "authentication", "policy"))
            relative = "../../../" + path.relative_to(ROOT).as_posix()
            label = item["fixtureId"]
            parameters = "<br>".join(
                code(p["name"]) + ": " + code(p["valueType"]) + ("（敏感）" if p.get("redacted") else "")
                for p in item.get("parameters", [])
            ) or "—"
            constraints = [code(policy["risk"]), code(policy["retryPolicy"]), "回读 " + code(policy["readbackPolicy"])]
            constraints.append("会话 " + (" / ".join(code(x) for x in auth.get("sessionLocations", [])) or "无"))
            if auth.get("synoTokenRequired"):
                constraints.append("必须提供 SynoToken")
            lines.append(
                f"| [{label}]({relative}) | {code(api['name'])}<br>{code(api['method'])} | "
                f"{code(api['preferredVersion'])} / {code(api['resolvedVersion'])}<br>{code(api['resolvedPath'])} | "
                f"{code(transport['httpMethod'])} / {code(transport['requestFormat'])} | {parameters} | "
                + "<br>".join(constraints) + " |"
            )
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只检查生成文件是否与现有请求快照一致")
    args = parser.parse_args()
    expected = render()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != expected:
            print("API 参数目录需要更新：python3 tools/codex/generate_api_reference.py")
            return 1
        print("API 参数目录与现有请求快照一致。")
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(expected, encoding="utf-8")
    print("已生成 docs/api/reference/requests.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
