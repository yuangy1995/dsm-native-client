#!/usr/bin/env python3
"""将 Android 巨型文件约束为带稳定身份且只能收紧的当前行数 ratchet。"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
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


STABLE_ID_PATTERN = re.compile(r"[a-z0-9]+(?:[.-][a-z0-9]+)*\Z")
RENAME_STATUS_PATTERN = re.compile(r"R(?:100|\d{1,2})\Z")


def _line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8").splitlines())


def _stable_id(
    item: dict[str, Any],
    collection: str,
    relative: str,
    errors: list[str],
    allow_legacy_ids: bool,
) -> str | None:
    """读取当前或旧基线中的稳定身份；旧版仅允许完全缺失 ID。"""
    if "id" not in item and allow_legacy_ids:
        return None
    value = item.get("id")
    if not isinstance(value, str) or not STABLE_ID_PATTERN.fullmatch(value):
        errors.append(f"{collection} 缺少有效、稳定的 id：{relative}")
        return None
    return value


def _registered_large_files(
    debt: dict[str, Any],
    limit: int,
    errors: list[str],
    allow_legacy_target_lines: bool = False,
    allow_legacy_ids: bool = False,
) -> list[dict[str, Any]]:
    registered: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_files: set[str] = set()
    for item in debt.get("existingLargeFiles", []):
        if not isinstance(item, dict) or not isinstance(item.get("file"), str):
            errors.append("existingLargeFiles 含无效条目")
            continue
        relative = item["file"]
        stable_id = _stable_id(item, "existingLargeFiles", relative, errors, allow_legacy_ids)
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
        if relative in seen_files:
            errors.append(f"既有大文件重复登记：{relative}")
            continue
        seen_files.add(relative)
        if stable_id is not None:
            if stable_id in seen_ids:
                errors.append(f"既有大文件稳定 id 重复：{stable_id}")
                continue
            seen_ids.add(stable_id)
        registered.append(
            {
                "id": stable_id,
                "file": relative,
                "maxLines": max_lines,
                "targetLines": target_lines,
            },
        )
    return registered


def _exceptions(
    debt: dict[str, Any],
    errors: list[str],
    allow_legacy_ids: bool = False,
) -> list[dict[str, str | None]]:
    exceptions: list[dict[str, str | None]] = []
    seen_ids: set[str] = set()
    seen_files: set[str] = set()
    for item in debt.get("exceptions", []):
        if not isinstance(item, dict) or not isinstance(item.get("file"), str):
            errors.append("exceptions 含无效条目")
            continue
        relative = item["file"]
        stable_id = _stable_id(item, "exceptions", relative, errors, allow_legacy_ids)
        reason = item.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"超大文件例外缺少理由：{relative}")
            continue
        if relative in seen_files:
            errors.append(f"超大文件例外重复登记：{relative}")
            continue
        seen_files.add(relative)
        if stable_id is not None:
            if stable_id in seen_ids:
                errors.append(f"超大文件例外稳定 id 重复：{stable_id}")
                continue
            seen_ids.add(stable_id)
        exceptions.append({"id": stable_id, "file": relative, "reason": reason})
    return exceptions


def _validate_global_identity(
    existing: list[dict[str, Any]],
    exceptions: list[dict[str, str | None]],
    errors: list[str],
) -> None:
    """ID 与路径必须在两类债务条目间全局唯一，避免身份切换绕过。"""
    existing_ids = {item["id"] for item in existing if item["id"] is not None}
    exception_ids = {item["id"] for item in exceptions if item["id"] is not None}
    for stable_id in sorted(existing_ids & exception_ids):
        errors.append(f"结构债务 id 不得同时登记为 tracked 与 exception：{stable_id}")
    existing_files = {item["file"] for item in existing}
    exception_files = {item["file"] for item in exceptions}
    for relative in sorted(existing_files & exception_files):
        errors.append(f"结构债务路径不得同时登记为 tracked 与 exception：{relative}")


def _uses_legacy_ids(debt: dict[str, Any]) -> bool:
    """只允许 138dbd16 这一类完全未引入 ID 的上一基线做按路径迁移。"""
    entries = [
        item
        for collection in ("existingLargeFiles", "exceptions")
        for item in debt.get(collection, [])
        if isinstance(item, dict)
    ]
    return bool(entries) and all("id" not in item for item in entries)


def _by_id(entries: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in entries if item["id"] is not None}


def _by_file(entries: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {str(item["file"]): item for item in entries}


def load_rename_map(path: Path | None) -> dict[str, str]:
    """读取 ``git diff --name-status -M`` 的精确旧路径到新路径映射。"""
    if path is None:
        return {}
    renames: dict[str, str] = {}
    destinations: set[str] = set()
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line:
            continue
        fields = line.split("\t")
        status = fields[0]
        if not status.startswith("R"):
            continue
        if len(fields) != 3 or not RENAME_STATUS_PATTERN.fullmatch(status):
            raise ValueError(f"rename map 第 {line_number} 行不是有效的 Rnnn<TAB>old<TAB>new 记录")
        previous, current = fields[1:]
        if not previous or not current:
            raise ValueError(f"rename map 第 {line_number} 行包含空路径")
        if previous in renames or current in destinations:
            raise ValueError(f"rename map 第 {line_number} 行包含歧义的路径身份")
        renames[previous] = current
        destinations.add(current)
    return renames


def _has_verified_path_continuity(
    previous_item: dict[str, Any],
    current_item: dict[str, Any],
    rename_map: dict[str, str],
) -> bool:
    previous_path = str(previous_item["file"])
    current_path = str(current_item["file"])
    return previous_path == current_path or rename_map.get(previous_path) == current_path


def _require_verified_path_continuity(
    previous_item: dict[str, Any],
    current_item: dict[str, Any],
    rename_map: dict[str, str],
    errors: list[str],
) -> bool:
    if _has_verified_path_continuity(previous_item, current_item, rename_map):
        return True
    errors.append(
        "结构债务稳定 id 的路径变更缺少 Git rename 证据："
        f"{previous_item['id']}（{previous_item['file']} -> {current_item['file']}）",
    )
    return False


def _may_remove_previous_entry(relative: str, production_root: Path, current_limit: int) -> bool:
    """仅允许文件删除、移出生产目录或已降至当前阈值内时移除历史身份。"""
    path = production_root / relative
    return not path.is_file() or _line_count(path) <= current_limit


def _entry_at_previous_or_renamed_path(
    relative: str,
    current_by_file: dict[str, dict[str, Any]],
    current_exceptions_by_file: dict[str, dict[str, Any]],
    rename_map: dict[str, str],
) -> dict[str, Any] | None:
    return (
        current_by_file.get(relative)
        or current_exceptions_by_file.get(relative)
        or current_by_file.get(rename_map.get(relative, ""))
        or current_exceptions_by_file.get(rename_map.get(relative, ""))
    )


def _compare_entry_ratchet(
    current_item: dict[str, Any],
    previous_item: dict[str, Any],
    errors: list[str],
) -> None:
    stable_id = current_item["id"]
    if current_item["maxLines"] > previous_item["maxLines"]:
        errors.append(
            f"当前 ratchet 不得上调：{stable_id}（上一基线 {previous_item['maxLines']} 行，"
            f"当前 {current_item['maxLines']} 行）",
        )
    if current_item["targetLines"] > previous_item["targetLines"]:
        errors.append(
            f"非阻断目标不得上调：{stable_id}（上一基线 {previous_item['targetLines']} 行，"
            f"当前 {current_item['targetLines']} 行）",
        )


def _compare_legacy_previous_ratchet(
    current: list[dict[str, Any]],
    current_exceptions: list[dict[str, str | None]],
    previous: list[dict[str, Any]],
    previous_exceptions: list[dict[str, str | None]],
    production_root: Path,
    current_limit: int,
    errors: list[str],
) -> None:
    """首次升级稳定 ID 时，仅以同路径承接 138dbd16 的历史债务。"""
    current_by_file = _by_file(current)
    current_exceptions_by_file = _by_file(current_exceptions)
    previous_by_file = _by_file(previous)
    previous_exceptions_by_file = _by_file(previous_exceptions)

    for previous_item in previous:
        relative = str(previous_item["file"])
        current_item = current_by_file.get(relative)
        if current_item is not None:
            _compare_entry_ratchet(current_item, previous_item, errors)
            continue
        if relative in current_exceptions_by_file:
            errors.append(
                f"上一基线既有大文件不得转入 exceptions：{relative}；"
                "请继续保留在 existingLargeFiles 并收紧当前 ratchet",
            )
            continue
        path = production_root / relative
        if path.is_file() and _line_count(path) > current_limit:
            errors.append(
                f"上一基线既有大文件仍超过 {current_limit} 行，必须继续登记："
                f"{relative}（当前 {_line_count(path)} 行）",
            )

    for current_item in current:
        relative = str(current_item["file"])
        if relative in previous_by_file or relative in previous_exceptions_by_file:
            continue
        errors.append(
            f"新增巨型文件不得直接登记为既有债务：{relative}；请先拆分或登记明确例外理由",
        )


def _compare_previous_ratchet(
    current: list[dict[str, Any]],
    current_exceptions: list[dict[str, str | None]],
    previous_structure_debt: dict[str, Any],
    production_root: Path,
    current_limit: int,
    errors: list[str],
    rename_map: dict[str, str],
) -> None:
    previous_errors: list[str] = []
    previous_limit = previous_structure_debt.get("newProductionFileLineLimit")
    if not isinstance(previous_limit, int) or previous_limit <= 0:
        errors.append("上一基线缺少有效的 newProductionFileLineLimit")
        return
    if current_limit > previous_limit:
        errors.append(
            "newProductionFileLineLimit 不得上调："
            f"上一基线 {previous_limit} 行，当前 {current_limit} 行",
        )

    legacy_ids = _uses_legacy_ids(previous_structure_debt)
    previous = _registered_large_files(
        previous_structure_debt,
        previous_limit,
        previous_errors,
        allow_legacy_target_lines=True,
        allow_legacy_ids=legacy_ids,
    )
    previous_exceptions = _exceptions(
        previous_structure_debt,
        previous_errors,
        allow_legacy_ids=legacy_ids,
    )
    _validate_global_identity(previous, previous_exceptions, previous_errors)
    if previous_errors:
        errors.extend(f"上一基线无效：{error}" for error in previous_errors)
        return

    if legacy_ids:
        _compare_legacy_previous_ratchet(
            current,
            current_exceptions,
            previous,
            previous_exceptions,
            production_root,
            current_limit,
            errors,
        )
        return

    current_by_id = _by_id(current)
    current_exceptions_by_id = _by_id(current_exceptions)
    current_by_file = _by_file(current)
    current_exceptions_by_file = _by_file(current_exceptions)
    previous_by_id = _by_id(previous)
    previous_exceptions_by_id = _by_id(previous_exceptions)

    for stable_id, previous_item in previous_by_id.items():
        current_item = current_by_id.get(stable_id)
        current_exception = current_exceptions_by_id.get(stable_id)
        if current_exception is not None:
            errors.append(
                f"上一基线既有大文件不得转入 exceptions：{stable_id}；"
                "请继续保留在 existingLargeFiles 并收紧当前 ratchet",
            )
            continue
        if current_item is not None:
            _require_verified_path_continuity(previous_item, current_item, rename_map, errors)
            _compare_entry_ratchet(current_item, previous_item, errors)
            continue

        relative = str(previous_item["file"])
        same_path_item = _entry_at_previous_or_renamed_path(
            relative,
            current_by_file,
            current_exceptions_by_file,
            rename_map,
        )
        if same_path_item is not None:
            errors.append(
                f"上一基线既有大文件稳定 id 不得改换：{stable_id}（路径 {relative}）",
            )
        elif not _may_remove_previous_entry(relative, production_root, current_limit):
            errors.append(
                f"上一基线既有大文件仍超过 {current_limit} 行，必须继续登记："
                f"{stable_id}（当前 {_line_count(production_root / relative)} 行）",
            )

    for current_item in current:
        stable_id = str(current_item["id"])
        if stable_id in previous_by_id or stable_id in previous_exceptions_by_id:
            # 既有 tracked 项或从历史 exception 转入 tracked 都已经在上方处理。
            continue
        errors.append(
            f"新增巨型文件不得直接登记为既有债务：{current_item['file']}；"
            "请先拆分或登记明确例外理由",
        )

    for stable_id, previous_exception in previous_exceptions_by_id.items():
        current_exception = current_exceptions_by_id.get(stable_id)
        current_item = current_by_id.get(stable_id)
        if current_exception is not None:
            _require_verified_path_continuity(
                previous_exception,
                current_exception,
                rename_map,
                errors,
            )
            continue
        if current_item is not None:
            _require_verified_path_continuity(
                previous_exception,
                current_item,
                rename_map,
                errors,
            )
            continue

        relative = str(previous_exception["file"])
        same_path_item = _entry_at_previous_or_renamed_path(
            relative,
            current_by_file,
            current_exceptions_by_file,
            rename_map,
        )
        if same_path_item is not None:
            errors.append(
                f"上一基线 exception 稳定 id 不得改换：{stable_id}（路径 {relative}）",
            )
        elif not _may_remove_previous_entry(relative, production_root, current_limit):
            errors.append(
                "上一基线 exception 只能在文件删除、移出生产目录或降至阈值以内时移除："
                f"{stable_id}（当前 {_line_count(production_root / relative)} 行）",
            )


def validate(
    production_root: Path = PRODUCTION_ROOT,
    structure_debt: dict[str, Any] | None = None,
    previous_structure_debt: dict[str, Any] | None = None,
    rename_map: dict[str, str] | None = None,
) -> list[str]:
    """校验当前精确 ratchet、稳定身份、例外理由及上一基线的单调性。"""
    debt = load_baseline()["structureDebt"] if structure_debt is None else structure_debt
    limit = debt.get("newProductionFileLineLimit")
    if not isinstance(limit, int) or limit <= 0:
        return ["结构债务基线缺少有效的 newProductionFileLineLimit"]

    errors: list[str] = []
    existing = _registered_large_files(debt, limit, errors)
    exceptions = _exceptions(debt, errors)
    _validate_global_identity(existing, exceptions, errors)
    existing_by_file = _by_file(existing)
    exceptions_by_file = _by_file(exceptions)

    discovered: set[str] = set()
    for path in sorted(production_root.rglob("*.kt")):
        relative = path.relative_to(production_root).as_posix()
        discovered.add(relative)
        lines = _line_count(path)
        registered = existing_by_file.get(relative)
        if registered is not None:
            max_lines = registered["maxLines"]
            if lines <= limit:
                errors.append(
                    f"既有巨型文件已降至 {limit} 行以内，请移除当前 ratchet：{relative}（当前 {lines} 行）",
                )
            elif lines > max_lines:
                errors.append(
                    f"既有巨型文件不得增长：{relative}（当前 ratchet {max_lines} 行，当前 {lines} 行）",
                )
            elif lines < max_lines:
                errors.append(
                    f"既有巨型文件已缩短，当前 ratchet 必须收紧：{relative}（当前 ratchet {max_lines} 行，"
                    f"当前 {lines} 行）",
                )
        elif lines > limit and relative not in exceptions_by_file:
            errors.append(
                f"新增生产文件超过 {limit} 行且没有明确例外理由：{relative}（当前 {lines} 行）",
            )

    for relative in sorted(set(existing_by_file) - discovered):
        errors.append(f"既有大文件当前 ratchet 指向不存在文件：{relative}")
    for relative in sorted(set(exceptions_by_file) - discovered):
        errors.append(f"超大文件例外指向不存在文件：{relative}")
    for relative in sorted(set(exceptions_by_file) & discovered):
        if _line_count(production_root / relative) <= limit:
            errors.append(f"超大文件例外已不再需要，请移除：{relative}")

    if previous_structure_debt is not None:
        _compare_previous_ratchet(
            existing,
            exceptions,
            previous_structure_debt,
            production_root,
            limit,
            errors,
            rename_map or {},
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 Android 结构债务当前 ratchet")
    parser.add_argument(
        "--previous-baseline",
        type=Path,
        help="与当前基线比较的上一版 Android 质量基线 JSON",
    )
    parser.add_argument(
        "--rename-map",
        type=Path,
        help="由 git diff --name-status -M 生成的旧路径到新路径证据",
    )
    args = parser.parse_args()
    try:
        previous = (
            load_baseline(args.previous_baseline)["structureDebt"]
            if args.previous_baseline is not None
            else None
        )
        errors = validate(
            previous_structure_debt=previous,
            rename_map=load_rename_map(args.rename_map),
        )
    except (OSError, ValueError) as error:
        print(f"错误：{error}")
        return 1
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("Android 结构债务 ratchet 通过：稳定 ID、当前行数与上一基线均未放宽。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
