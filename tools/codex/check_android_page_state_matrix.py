#!/usr/bin/env python3
"""校验 Android 页面五态基线与生产页面清单没有漂移。"""

from __future__ import annotations

import sys
from pathlib import Path
import re


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_android_quality_baseline import BASELINE_PATH, load_baseline


ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/ui"
PLAN_PATH = ROOT / "docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md"
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


def parse_legacy_matrix(path: Path) -> tuple[dict[str, list[str]], list[str]]:
    """仅为门禁单测保留的旧格式解析器，不用于仓库生产基线。"""
    rows: dict[str, list[str]] = {}
    errors: list[str] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.startswith("| `"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 9:
            errors.append(f"矩阵第 {line_number} 行必须有 9 列，实际为 {len(cells)} 列")
            continue
        source = cells[0].strip("`")
        if source in rows:
            errors.append(f"矩阵重复记录页面文件：{source}")
            continue
        states = cells[2:7]
        invalid = [value for value in states if value not in STATE_VALUES]
        if invalid:
            errors.append(f"{source} 使用了非法状态值：{', '.join(invalid)}")
        if cells[7] not in AUTOMATION_VALUES:
            errors.append(f"{source} 使用了非法自动化等级：{cells[7]}")
        rows[source] = states + [cells[7], cells[8]]
    return rows, errors


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


# 兼容既有单测；其值完全由 JSON 基线派生，不再由 Markdown 审计矩阵维护。
EXPECTED_FILES = set(parse_baseline()[0])


def _plan_marks_five_state_target_complete(plan_path: Path) -> bool | None:
    if not plan_path.is_file():
        return None
    plan = plan_path.read_text(encoding="utf-8")
    pattern = re.compile(
        r"- \[(?P<checked>[ x])\] 每页覆盖加载、空内容、筛选后为空、错误和正常内容五种状态；"
    )
    match = pattern.search(plan)
    return None if match is None else match.group("checked") == "x"


def validate(
    ui_root: Path = UI_ROOT,
    baseline_path: Path | None = None,
    plan_path: Path = PLAN_PATH,
) -> tuple[list[str], int, int]:
    """验证当前生产清单；传入 Markdown 路径仅支持既有单测夹具。"""
    if baseline_path is not None and baseline_path.suffix == ".md":
        rows, errors = parse_legacy_matrix(baseline_path)
    else:
        rows, errors = parse_baseline(BASELINE_PATH if baseline_path is None else baseline_path)
    discovered = discover_surface_files(ui_root)
    expected_files = EXPECTED_FILES if baseline_path is not None and baseline_path.suffix == ".md" else set(rows)
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
    completed = _plan_marks_five_state_target_complete(plan_path)
    if completed is None:
        errors.append("未找到 Android 计划中的页面五态叶子目标")
    elif completed and (gap_count or automation_gap_count):
        errors.append(
            "页面五态目标已勾选，但矩阵仍有"
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
