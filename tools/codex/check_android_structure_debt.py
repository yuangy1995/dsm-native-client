#!/usr/bin/env python3
"""将 Android 巨型文件约束为只能收紧的当前行数 ratchet。"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_android_quality_baseline import (
    PRODUCTION_ROOT,
    default_structure_debt_target_lines,
    load_baseline,
)


def _line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8").splitlines())


def _registered_large_files(
    debt: dict[str, Any],
    limit: int,
    errors: list[str],
    allow_legacy_target_lines: bool = False,
) -> dict[str, dict[str, int]]:
    registered: dict[str, dict[str, int]] = {}
    for item in debt.get("existingLargeFiles", []):
        if not isinstance(item, dict) or not isinstance(item.get("file"), str):
            errors.append("existingLargeFiles 含无效条目")
            continue
        relative = item["file"]
        max_lines = item.get("maxLines")
        target_lines = item.get("targetLines")
        if target_lines is None and allow_legacy_target_lines:
            target_lines = default_structure_debt_target_lines(relative)
        if not isinstance(max_lines, int) or max_lines <= limit:
            errors.append(f"{relative} 缺少大文件有效 maxLines")
            continue
        if not isinstance(target_lines, int) or target_lines <= 0 or target_lines > max_lines:
            errors.append(f"{relative} 缺少不大于当前 ratchet 的有效 targetLines")
            continue
        if relative in registered:
            errors.append(f"既有大文件重复登记：{relative}")
            continue
        registered[relative] = {"maxLines": max_lines, "targetLines": target_lines}
    return registered


def _exceptions(debt: dict[str, Any], errors: list[str]) -> dict[str, str]:
    exceptions: dict[str, str] = {}
    for item in debt.get("exceptions", []):
        if not isinstance(item, dict) or not isinstance(item.get("file"), str):
            errors.append("exceptions 含无效条目")
            continue
        relative = item["file"]
        reason = item.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"超大文件例外缺少理由：{relative}")
            continue
        if relative in exceptions:
            errors.append(f"超大文件例外重复登记：{relative}")
            continue
        exceptions[relative] = reason
    return exceptions


def _compare_previous_ratchet(
    current: dict[str, dict[str, int]],
    previous_structure_debt: dict[str, Any],
    limit: int,
    errors: list[str],
) -> None:
    previous_errors: list[str] = []
    previous = _registered_large_files(
        previous_structure_debt,
        limit,
        previous_errors,
        allow_legacy_target_lines=True,
    )
    if previous_errors:
        errors.extend(f"上一基线无效：{error}" for error in previous_errors)
        return
    for relative, current_item in current.items():
        previous_item = previous.get(relative)
        if previous_item is None:
            errors.append(
                f"新增巨型文件不得直接登记为既有债务：{relative}；请先拆分或登记明确例外理由"
            )
            continue
        if current_item["maxLines"] > previous_item["maxLines"]:
            errors.append(
                f"当前 ratchet 不得上调：{relative}（上一基线 {previous_item['maxLines']} 行，"
                f"当前 {current_item['maxLines']} 行）"
            )
        if current_item["targetLines"] > previous_item["targetLines"]:
            errors.append(
                f"非阻断目标不得上调：{relative}（上一基线 {previous_item['targetLines']} 行，"
                f"当前 {current_item['targetLines']} 行）"
            )


def validate(
    production_root: Path = PRODUCTION_ROOT,
    structure_debt: dict[str, Any] | None = None,
    previous_structure_debt: dict[str, Any] | None = None,
) -> list[str]:
    """校验当前精确 ratchet、例外理由及上一基线的单调性。"""
    debt = load_baseline()["structureDebt"] if structure_debt is None else structure_debt
    limit = debt.get("newProductionFileLineLimit")
    if not isinstance(limit, int) or limit <= 0:
        return ["结构债务基线缺少有效的 newProductionFileLineLimit"]

    errors: list[str] = []
    existing = _registered_large_files(debt, limit, errors)
    exceptions = _exceptions(debt, errors)
    for relative in sorted(set(existing) & set(exceptions)):
        errors.append(f"既有巨型文件不应同时登记例外：{relative}")

    discovered: set[str] = set()
    for path in sorted(production_root.rglob("*.kt")):
        relative = path.relative_to(production_root).as_posix()
        discovered.add(relative)
        lines = _line_count(path)
        registered = existing.get(relative)
        if registered is not None:
            max_lines = registered["maxLines"]
            if lines <= limit:
                errors.append(
                    f"既有巨型文件已降至 {limit} 行以内，请移除当前 ratchet：{relative}（当前 {lines} 行）"
                )
            elif lines > max_lines:
                errors.append(
                    f"既有巨型文件不得增长：{relative}（当前 ratchet {max_lines} 行，当前 {lines} 行）"
                )
            elif lines < max_lines:
                errors.append(
                    f"既有巨型文件已缩短，当前 ratchet 必须收紧：{relative}（当前 ratchet {max_lines} 行，"
                    f"当前 {lines} 行）"
                )
        elif lines > limit and relative not in exceptions:
            errors.append(
                f"新增生产文件超过 {limit} 行且没有明确例外理由：{relative}（当前 {lines} 行）"
            )

    for relative in sorted(set(existing) - discovered):
        errors.append(f"既有大文件当前 ratchet 指向不存在文件：{relative}")
    for relative in sorted(set(exceptions) - discovered):
        errors.append(f"超大文件例外指向不存在文件：{relative}")
    for relative in sorted(set(exceptions) & discovered):
        if _line_count(production_root / relative) <= limit:
            errors.append(f"超大文件例外已不再需要，请移除：{relative}")

    if previous_structure_debt is not None:
        _compare_previous_ratchet(existing, previous_structure_debt, limit, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 Android 结构债务当前 ratchet")
    parser.add_argument(
        "--previous-baseline",
        type=Path,
        help="与当前基线比较的上一版 Android 质量基线 JSON",
    )
    args = parser.parse_args()
    try:
        previous = (
            load_baseline(args.previous_baseline)["structureDebt"]
            if args.previous_baseline is not None
            else None
        )
        errors = validate(previous_structure_debt=previous)
    except (OSError, ValueError) as error:
        print(f"错误：{error}")
        return 1
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("Android 结构债务 ratchet 通过：当前行数精确匹配，且没有放宽上一基线。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
