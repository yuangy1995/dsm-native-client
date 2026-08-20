#!/usr/bin/env python3
"""生成并校验 Android 质量基线报告。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
BASELINE_PATH = ROOT / "tools/codex/android_quality_baseline.json"
REPORT_PATH = ROOT / "docs/quality/ANDROID_QUALITY_BASELINE_ZH.md"
PRODUCTION_ROOT = ROOT / "android/app/src/main/java"

STRUCTURE_DEBT_TARGET_LINES = {
    "io/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt": 12000,
    "io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt": 11000,
    "io/github/qwertyuiop1995/dsmnativeclient/AppViewModelSupport.kt": 1200,
    "io/github/qwertyuiop1995/dsmnativeclient/data/downloads/DownloadStationRepository.kt": 1800,
}

FUNCTION_PATTERN = re.compile(
    r"(?m)^\s*(?:(?:private|internal|public|protected|open|final|override|"
    r"inline|tailrec|operator|infix)\s+)*(?:suspend\s+)?fun\s+"
    r"(?:<[^>\n]+>\s*)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\("
)
DIRECT_RESULT_CALL_PATTERN = re.compile(
    r"(?:\.\s*|::\s*)(?P<method>[A-Za-z_][A-Za-z0-9_]*Result)\s*(?:\(|\b)"
)


def _read_json(path: Path = BASELINE_PATH) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_baseline(path: Path = BASELINE_PATH) -> dict[str, Any]:
    """读取并做最小 Schema 校验，供各静态门禁复用。"""
    baseline = _read_json(path)
    required = {
        "schemaVersion",
        "lastReviewed",
        "writeOperations",
        "pageStates",
        "touchTargets",
        "motion",
        "structureDebt",
    }
    missing = sorted(required - baseline.keys())
    if missing:
        raise ValueError(f"Android 质量基线缺少字段：{', '.join(missing)}")
    if baseline["schemaVersion"] != 1:
        raise ValueError("Android 质量基线版本不受当前生成器支持")
    return baseline


def _function_ranges(source: str) -> list[tuple[int, int, str]]:
    matches = list(FUNCTION_PATTERN.finditer(source))
    ranges: list[tuple[int, int, str]] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        ranges.append((match.start(), end, match.group("name")))
    return ranges


def _owner_for_offset(ranges: list[tuple[int, int, str]], offset: int) -> str:
    candidates = [item for item in ranges if item[0] <= offset < item[1]]
    if not candidates:
        return "<top-level>"
    # 同一文件的嵌套局部函数以范围最小者为所属函数。
    return min(candidates, key=lambda item: item[1] - item[0])[2]


def discover_result_call_sites(
    methods: set[str],
    production_root: Path = PRODUCTION_ROOT,
) -> list[dict[str, str | int]]:
    """找出受审 ``*Result`` 调用点，不以文件散列作为审计边界。"""
    sites: list[dict[str, str | int]] = []
    occurrences: dict[tuple[str, str, str], int] = {}
    for path in sorted(production_root.rglob("*.kt")):
        source = path.read_text(encoding="utf-8")
        relative = path.relative_to(production_root).as_posix()
        ranges = _function_ranges(source)
        for match in DIRECT_RESULT_CALL_PATTERN.finditer(source):
            method = match.group("method")
            if method not in methods:
                continue
            owner = _owner_for_offset(ranges, match.start())
            key = (relative, owner, method)
            occurrences[key] = occurrences.get(key, 0) + 1
            sites.append(
                {
                    "file": relative,
                    "owner": owner,
                    "resultMethod": method,
                    "occurrence": occurrences[key],
                }
            )
    return sites


def _markdown_table_row(cells: list[str]) -> str:
    return "| " + " | ".join(cells) + " |"


def default_structure_debt_target_lines(relative_path: str) -> int:
    """返回既有结构债务文件的非阻断拆分目标。"""
    return STRUCTURE_DEBT_TARGET_LINES.get(relative_path, 1000)


def tighten_structure_debt_ratchet(
    baseline: dict[str, Any],
    production_root: Path = PRODUCTION_ROOT,
) -> dict[str, Any]:
    """仅收紧已登记大文件的当前 ratchet，并同步其默认非阻断目标。"""
    updated = json.loads(json.dumps(baseline, ensure_ascii=False))
    debt = updated["structureDebt"]
    limit = debt["newProductionFileLineLimit"]
    entries: list[dict[str, Any]] = []
    for item in debt.get("existingLargeFiles", []):
        relative = item["file"]
        path = production_root / relative
        if not path.is_file():
            continue
        lines = len(path.read_text(encoding="utf-8").splitlines())
        if lines <= limit:
            continue
        entries.append(
            {
                "file": relative,
                "maxLines": lines,
                "targetLines": default_structure_debt_target_lines(relative),
            }
        )
    debt["existingLargeFiles"] = entries
    return updated


def generate_report(baseline: dict[str, Any]) -> str:
    """从机器数据生成供维护者阅读的稳定报告。"""
    writes = list(baseline["writeOperations"])
    pages = list(baseline["pageStates"])
    unique_methods = sorted({item["resultMethod"] for item in writes})
    touch = baseline["touchTargets"]
    motion = baseline["motion"]
    debt = baseline["structureDebt"]
    lines = [
        "<!-- doc-role: generated-quality-baseline -->",
        f"<!-- last-reviewed: {baseline['lastReviewed']} -->",
        "<!-- generated-from: tools/codex/android_quality_baseline.json -->",
        "<!-- generated-by: tools/codex/generate_android_quality_baseline.py -->",
        "",
        "# Android 质量基线",
        "",
        "本报告由机器数据生成。请修改 `tools/codex/android_quality_baseline.json`，再运行生成器；"
        "不要直接编辑本文件。",
        "",
        "## 审计边界",
        "",
        f"- 写操作：{len(writes)} 个生产调用点，{len(unique_methods)} 个 `Result` 方法。",
        f"- 页面状态：{len(pages)} 个生产页面或弹窗文件。",
        f"- 自定义点击目标：至少 {touch['minimumDp']}dp × {touch['minimumDp']}dp，并保留原生按压反馈。",
        f"- 显式时间动效：仅允许 `{motion['allowedPath']}` 中登记的预测返回实现。",
        "- 本基线只证明源码和自动化门禁；真实 NAS、实体机触控、TalkBack、OEM 行为与危险写"
        "副作用均不得由此报告宣称已验收。",
        "",
        "## 写操作调用点",
        "",
        _markdown_table_row(["调用文件", "所属函数", "Result 方法", "开放状态", "测试证据"]),
        _markdown_table_row(["---", "---", "---", "---", "---"]),
    ]
    for operation in writes:
        scenarios = operation["scenarios"]
        evidence = "；".join(
            f"{name}={reference}"
            for name, reference in scenarios.items()
            if reference not in {"", "na"}
        )
        lines.append(
            _markdown_table_row(
                [
                    f"`{operation['file']}`",
                    f"`{operation['owner']}`",
                    f"`{operation['resultMethod']}`",
                    str(operation["state"]),
                    evidence or "不适用",
                ]
            )
        )

    lines.extend(
        [
            "",
            "## 页面五态",
            "",
            _markdown_table_row(["文件", "页面", "加载", "空内容", "筛选空", "错误", "正常", "自动化", "依据"]),
            _markdown_table_row(["---", "---", "---", "---", "---", "---", "---", "---", "---"]),
        ]
    )
    for page in pages:
        states = page["states"]
        lines.append(
            _markdown_table_row(
                [
                    f"`{page['file']}`",
                    page["surface"],
                    states["loading"],
                    states["empty"],
                    states["filteredEmpty"],
                    states["error"],
                    states["content"],
                    page["automation"],
                    page["evidence"],
                ]
            )
        )

    lines.extend(
        [
            "",
            "## 点击目标",
            "",
            _markdown_table_row(["模块", "自定义目标", "尺寸与交互合约", "自动化证据"]),
            _markdown_table_row(["---", "---", "---", "---"]),
        ]
    )
    for item in touch["modules"]:
        lines.append(_markdown_table_row([item["module"], item["targets"], item["contract"], item["evidence"]]))

    lines.extend(
        [
            "",
            "## 界面体验与动效",
            "",
            f"- 审计范围：`{motion['scope']}`。",
            f"- 唯一允许路径：`{motion['allowedPath']}`；系统动画开关：`{motion['systemAnimationGate']}`。",
            "- 精确允许源码：",
            "",
        ]
    )
    lines.extend(f"  - `{source}`" for source in motion["allowedSources"])
    lines.extend(
        [
            "",
            f"- {motion['deviceValidation']}",
            "",
            "## 结构债务门禁",
            "",
            f"新增生产 Kotlin 文件超过 {debt['newProductionFileLineLimit']} 行必须在 JSON 的 `exceptions` 中"
            "写明理由。以下既有大文件的当前 ratchet 必须精确等于当前行数；文件缩短后必须同步"
            "下调，降至阈值以内时必须移除登记。`targetLines` 只指导后续拆分，不会单独阻断提交：",
            "",
            _markdown_table_row(["文件", "当前 ratchet", "非阻断目标"]),
            _markdown_table_row(["---", "---:", "---:"]),
        ]
    )
    for item in debt["existingLargeFiles"]:
        lines.append(
            _markdown_table_row(
                [f"`{item['file']}`", str(item["maxLines"]), str(item["targetLines"])],
            )
        )
    if debt.get("exceptions"):
        lines.extend(["", "已登记例外："])
        for exception in debt["exceptions"]:
            lines.append(f"- `{exception['file']}`：{exception['reason']}")
    lines.extend(
        [
            "",
            "## 再生成与校验",
            "",
            "```bash",
            "python3 tools/codex/generate_android_quality_baseline.py",
            "python3 tools/codex/generate_android_quality_baseline.py --check",
            "python3 tools/codex/check_android_write_test_matrix.py",
            "python3 tools/codex/check_android_page_state_matrix.py",
            "python3 tools/codex/check_android_touch_targets.py",
            "python3 tools/codex/check_android_motion_audit.py",
            "```",
            "",
        ]
    )
    return "\n".join(lines)


def write_baseline(baseline: dict[str, Any], path: Path = BASELINE_PATH) -> None:
    path.write_text(
        json.dumps(baseline, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def write_report(baseline: dict[str, Any], path: Path = REPORT_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(generate_report(baseline), encoding="utf-8")


def check_report(baseline: dict[str, Any], path: Path = REPORT_PATH) -> list[str]:
    expected = generate_report(baseline)
    if not path.is_file():
        return [f"生成报告不存在：{path.relative_to(ROOT)}"]
    if path.read_text(encoding="utf-8") != expected:
        return [
            "Android 质量报告与 JSON 基线漂移："
            "运行 python3 tools/codex/generate_android_quality_baseline.py 更新"
        ]
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description="生成或校验 Android 质量基线报告")
    parser.add_argument("--check", action="store_true", help="仅检查生成报告是否漂移")
    parser.add_argument(
        "--update-structure-ratchet",
        action="store_true",
        help="仅收紧已登记大文件的当前 ratchet，并重新生成报告",
    )
    args = parser.parse_args()
    try:
        baseline = load_baseline()
        if args.update_structure_ratchet:
            baseline = tighten_structure_debt_ratchet(baseline)
            write_baseline(baseline)
            write_report(baseline)
            print("已收紧 Android 结构债务 ratchet 并重新生成质量报告。")
            return 0
        if args.check:
            errors = check_report(baseline)
            if errors:
                for error in errors:
                    print(f"错误：{error}")
                return 1
            print("Android 质量基线生成报告通过：JSON 与 Markdown 一致。")
            return 0
        write_report(baseline)
        print("已从 Android 质量基线 JSON 生成报告。")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"错误：{error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
