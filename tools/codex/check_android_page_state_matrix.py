#!/usr/bin/env python3
"""校验 Android 页面五态基线与生产页面清单没有漂移。"""

from __future__ import annotations

import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_android_quality_baseline import BASELINE_PATH, load_baseline


ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/ui"
STATE_VALUES = {"覆盖", "不适用", "缺口"}
AUTOMATION_VALUES = {"完整", "局部", "缺失"}


def discover_surface_files(ui_root: Path = UI_ROOT) -> set[str]:
    """发现需要进入五态审计的生产 Compose 页面和弹窗文件。"""
    discovered = {
        path.relative_to(ui_root).as_posix()
        for path in ui_root.rglob("*.kt")
        if path.name.endswith("Screen.kt") or path.name.endswith("Dialog.kt")
    }
    service_screens = ui_root / "services/ServiceScreens.kt"
    if service_screens.exists():
        discovered.add("services/ServiceScreens.kt")
    return discovered


def parse_baseline(path: Path = BASELINE_PATH) -> tuple[dict[str, list[str]], list[str]]:
    baseline = load_baseline(path)
    rows: dict[str, list[str]] = {}
    errors: list[str] = []
    for index, page in enumerate(baseline["pageStates"], 1):
        if not isinstance(page, dict):
            errors.append(f"pageStates 第 {index} 项必须是对象")
            continue
        source = page.get("file", "")
        if not isinstance(source, str) or not source:
            errors.append(f"pageStates 第 {index} 项缺少 file")
            continue
        if source in rows:
            errors.append(f"JSON 页面基线重复记录页面文件：{source}")
            continue
        states = page.get("states", {})
        values = [
            states.get("loading", ""),
            states.get("empty", ""),
            states.get("filteredEmpty", ""),
            states.get("error", ""),
            states.get("content", ""),
        ]
        invalid = [value for value in values if value not in STATE_VALUES]
        if invalid:
            errors.append(f"{source} 使用了非法状态值：{', '.join(invalid)}")
        automation = page.get("automation", "")
        if automation not in AUTOMATION_VALUES:
            errors.append(f"{source} 使用了非法自动化等级：{automation}")
        evidence = page.get("evidence", "")
        if not isinstance(evidence, str) or not evidence:
            errors.append(f"{source} 缺少代码与测试依据")
        rows[source] = values + [str(automation), str(evidence)]
    return rows, errors


def validate(
    ui_root: Path = UI_ROOT,
    baseline_path: Path = BASELINE_PATH,
) -> tuple[list[str], int, int]:
    """直接校验机器基线和已完成的页面覆盖，不依赖人工计划勾选。"""
    rows, errors = parse_baseline(baseline_path)
    discovered = discover_surface_files(ui_root)
    expected_files = set(rows)
    missing_inventory = sorted(discovered - expected_files)
    stale_inventory = sorted(expected_files - discovered)
    if missing_inventory:
        errors.append("矩阵遗漏生产页面/弹窗文件：" + ", ".join(missing_inventory))
    if stale_inventory:
        errors.append("矩阵包含不存在的页面/弹窗文件：" + ", ".join(stale_inventory))
    if discovered != expected_files:
        errors.append(
            "生产页面文件清单已变化，请先人工审计再更新 Android JSON 基线："
            f"新增={sorted(discovered - expected_files)}，移除={sorted(expected_files - discovered)}"
        )

    gap_count = sum(value == "缺口" for row in rows.values() for value in row[:5])
    automation_gap_count = sum(row[5] != "完整" for row in rows.values())
    if gap_count or automation_gap_count:
        errors.append(
            "页面五态完整基线出现回退："
            f" {gap_count} 个生产状态缺口、{automation_gap_count} 个自动化未闭环页面"
        )
    return errors, gap_count, automation_gap_count


def main() -> int:
    errors, gap_count, automation_gap_count = validate()
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print(
        "Android 页面五态基线通过："
        f"{len(parse_baseline()[0])} 个生产页面/弹窗文件，"
        f"{gap_count} 个生产状态缺口，{automation_gap_count} 个自动化未闭环页面。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
