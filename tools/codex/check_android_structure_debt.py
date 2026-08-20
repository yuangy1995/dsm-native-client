#!/usr/bin/env python3
"""防止 Android 现有巨型生产文件增长，并阻止新增超大文件无理由进入仓库。"""

from __future__ import annotations

from pathlib import Path
import sys
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_android_quality_baseline import PRODUCTION_ROOT, load_baseline


def _line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8").splitlines())


def validate(
    production_root: Path = PRODUCTION_ROOT,
    structure_debt: dict[str, Any] | None = None,
) -> list[str]:
    """校验既有高债务文件上限和新文件的明确例外理由。"""
    debt = load_baseline()["structureDebt"] if structure_debt is None else structure_debt
    limit = debt.get("newProductionFileLineLimit")
    if not isinstance(limit, int) or limit <= 0:
        return ["结构债务基线缺少有效的 newProductionFileLineLimit"]
    existing: dict[str, int] = {}
    errors: list[str] = []
    for item in debt.get("existingLargeFiles", []):
        if not isinstance(item, dict) or not isinstance(item.get("file"), str):
            errors.append("existingLargeFiles 含无效条目")
            continue
        max_lines = item.get("maxLines")
        if not isinstance(max_lines, int) or max_lines <= limit:
            errors.append(f"{item['file']} 缺少大文件有效 maxLines")
            continue
        if item["file"] in existing:
            errors.append(f"既有大文件重复登记：{item['file']}")
            continue
        existing[item["file"]] = max_lines

    exceptions: dict[str, str] = {}
    for item in debt.get("exceptions", []):
        if not isinstance(item, dict) or not isinstance(item.get("file"), str):
            errors.append("exceptions 含无效条目")
            continue
        reason = item.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"超大文件例外缺少理由：{item['file']}")
            continue
        if item["file"] in exceptions:
            errors.append(f"超大文件例外重复登记：{item['file']}")
            continue
        exceptions[item["file"]] = reason

    discovered: set[str] = set()
    for path in sorted(production_root.rglob("*.kt")):
        relative = path.relative_to(production_root).as_posix()
        discovered.add(relative)
        lines = _line_count(path)
        if relative in existing:
            if lines > existing[relative]:
                errors.append(
                    f"既有巨型文件不得增长：{relative}（基线 {existing[relative]} 行，当前 {lines} 行）"
                )
        elif lines > limit and relative not in exceptions:
            errors.append(
                f"新增生产文件超过 {limit} 行且没有明确例外理由：{relative}（当前 {lines} 行）"
            )

    for relative in sorted(set(existing) - discovered):
        errors.append(f"既有巨型文件基线指向不存在文件：{relative}")
    for relative in sorted(set(exceptions) - discovered):
        errors.append(f"超大文件例外指向不存在文件：{relative}")
    for relative in sorted(set(exceptions) & discovered):
        if relative not in existing and _line_count(production_root / relative) <= limit:
            errors.append(f"超大文件例外已不再需要，请移除：{relative}")
    return errors


def main() -> int:
    errors = validate()
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("Android 结构债务基线通过：既有巨型文件未增长，新增生产文件均未越过上限。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
