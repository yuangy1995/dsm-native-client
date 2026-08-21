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
    ROOT,
    PRODUCTION_ROOT,
    default_structure_debt_target_lines,
    load_baseline,
)


STABLE_ID_PATTERN = re.compile(r"[a-z0-9]+(?:[.-][a-z0-9]+)*\Z")
RENAME_STATUS_PATTERN = re.compile(r"R(?:00[1-9]|0[1-9]\d|100)\Z")
IDENTITY_TRANSITION_KINDS = frozenset({"migration", "deletion"})
PRODUCTION_PREFIX = PRODUCTION_ROOT.relative_to(ROOT).as_posix()
PRODUCTION_NAMESPACE_ROOTS = frozenset(
    child.name for child in PRODUCTION_ROOT.iterdir() if child.is_dir()
)


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


def _safe_transition_path(
    value: object,
    field: str,
    index: int,
    errors: list[str],
) -> str | None:
    """只接受生产根下可比较的 POSIX 相对路径。"""
    if not isinstance(value, str) or not value:
        errors.append(f"identityTransitions 第 {index} 条缺少有效 {field} 路径")
        return None
    if (
        value.startswith("/") or
        "\\" in value or
        "\x00" in value or
        re.match(r"^[A-Za-z]:", value)
    ):
        errors.append(f"identityTransitions 第 {index} 条的 {field} 必须是安全 POSIX 相对路径")
        return None
    parts = value.split("/")
    if any(not part or part in {".", ".."} for part in parts):
        errors.append(f"identityTransitions 第 {index} 条的 {field} 包含路径遍历或异常分段")
        return None
    return value


def _identity_transitions(
    debt: dict[str, Any],
    errors: list[str],
) -> list[dict[str, str | None]]:
    """解析一次性低相似度 D+A 身份迁移/删除声明。"""
    if "identityTransitions" not in debt:
        errors.append("结构债务基线缺少 identityTransitions；没有活动迁移时必须显式写为空列表")
        return []
    raw_transitions = debt["identityTransitions"]
    if not isinstance(raw_transitions, list):
        errors.append("identityTransitions 必须是列表")
        return []

    transitions: list[dict[str, str | None]] = []
    seen_ids: set[str] = set()
    seen_from: set[str] = set()
    seen_to: set[str] = set()
    for index, item in enumerate(raw_transitions, start=1):
        if not isinstance(item, dict):
            errors.append(f"identityTransitions 第 {index} 条不是对象")
            continue
        from_path = _safe_transition_path(item.get("from"), "from", index, errors)
        stable_id = _stable_id(
            item,
            "identityTransitions",
            from_path or f"第 {index} 条",
            errors,
            allow_legacy_ids=False,
        )
        kind = item.get("kind")
        if not isinstance(kind, str) or kind not in IDENTITY_TRANSITION_KINDS:
            errors.append(
                f"identityTransitions 第 {index} 条的 kind 必须是 migration 或 deletion",
            )
            continue
        reason = item.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"identityTransitions 第 {index} 条缺少理由")
            continue

        to_path: str | None
        if kind == "migration":
            to_path = _safe_transition_path(item.get("to"), "to", index, errors)
            if from_path is not None and to_path == from_path:
                errors.append(f"identityTransitions 第 {index} 条的 from 与 to 不得相同")
                continue
        else:
            raw_to = item.get("to")
            if raw_to is not None and raw_to != "":
                errors.append(f"identityTransitions 第 {index} 条的 deletion 不得设置 to")
                continue
            to_path = None

        if stable_id is None or from_path is None or (kind == "migration" and to_path is None):
            continue
        if stable_id in seen_ids:
            errors.append(f"identityTransitions 稳定 id 重复：{stable_id}")
            continue
        if from_path in seen_from:
            errors.append(f"identityTransitions from 路径重复：{from_path}")
            continue
        if to_path is not None and to_path in seen_to:
            errors.append(f"identityTransitions to 路径重复：{to_path}")
            continue
        seen_ids.add(stable_id)
        seen_from.add(from_path)
        if to_path is not None:
            seen_to.add(to_path)
        transitions.append(
            {
                "id": stable_id,
                "kind": str(kind),
                "from": from_path,
                "to": to_path,
                "reason": reason,
            },
        )
    return transitions


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


def _normalize_git_production_path(path: str, line_number: int) -> str | None:
    """将 Git 仓库相对路径严格归一为生产根相对路径。"""
    if not path:
        raise ValueError(f"rename map 第 {line_number} 行包含空路径")
    if path == PRODUCTION_PREFIX or path == f"{PRODUCTION_PREFIX}/":
        raise ValueError(f"rename map 第 {line_number} 行包含空生产相对路径")
    if (
        path.startswith("/") or
        "\\" in path or
        "\x00" in path or
        re.match(r"^[A-Za-z]:", path)
    ):
        raise ValueError(f"rename map 第 {line_number} 行包含绝对或异常路径")
    parts = path.split("/")
    if any(not part or part in {".", ".."} for part in parts):
        raise ValueError(f"rename map 第 {line_number} 行包含路径遍历或异常分段")

    prefix = f"{PRODUCTION_PREFIX}/"
    if path.startswith(prefix):
        relative = path.removeprefix(prefix)
        if not relative:
            raise ValueError(f"rename map 第 {line_number} 行包含空生产相对路径")
        return relative

    # Git 命令必须在仓库根输出路径；把已是生产根相对形式的 io/... 一类混合命名空间拒绝，
    # 不能误当成生产目录外的普通文件而借出或绕过稳定身份。
    if parts[0] in PRODUCTION_NAMESPACE_ROOTS:
        raise ValueError(f"rename map 第 {line_number} 行混用仓库与生产路径命名空间")
    return None


def load_rename_map(path: Path | None) -> dict[str, str]:
    """读取 Git 精确 Rnnn 记录，并只保留两端都在生产目录的规范化映射。"""
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
        normalized_previous = _normalize_git_production_path(previous, line_number)
        normalized_current = _normalize_git_production_path(current, line_number)
        # 移出生产目录、进入生产目录及生产目录外的改名都不传递 Android 结构身份。
        if normalized_previous is None or normalized_current is None:
            continue
        if (
            normalized_previous == normalized_current or
            normalized_previous in renames or
            normalized_current in destinations
        ):
            raise ValueError(f"rename map 第 {line_number} 行包含歧义的路径身份")
        renames[normalized_previous] = normalized_current
        destinations.add(normalized_current)
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


def _validate_identity_transitions(
    transitions: list[dict[str, str | None]],
    previous: list[dict[str, Any]],
    previous_exceptions: list[dict[str, str | None]],
    current: list[dict[str, Any]],
    current_exceptions: list[dict[str, str | None]],
    production_root: Path,
    rename_map: dict[str, str],
    errors: list[str],
) -> tuple[dict[str, str], set[str]]:
    """验证一次性声明与上一/当前身份、磁盘状态和 Git R 证据的闭环。"""
    previous_entries = {
        **{str(item["id"]): ("tracked", item) for item in previous if item["id"] is not None},
        **{
            str(item["id"]): ("exception", item)
            for item in previous_exceptions
            if item["id"] is not None
        },
    }
    current_entries = {
        **{str(item["id"]): ("tracked", item) for item in current if item["id"] is not None},
        **{
            str(item["id"]): ("exception", item)
            for item in current_exceptions
            if item["id"] is not None
        },
    }
    current_by_file = {
        **_by_file(current),
        **_by_file(current_exceptions),
    }
    rename_sources_by_destination = {destination: source for source, destination in rename_map.items()}
    verified_migrations: dict[str, str] = {}
    verified_deletions: set[str] = set()

    for transition in transitions:
        stable_id = str(transition["id"])
        kind = str(transition["kind"])
        from_path = str(transition["from"])
        to_path = transition["to"]
        previous_entry = previous_entries.get(stable_id)
        if previous_entry is None:
            errors.append(
                "identityTransitions source 必须精确对应上一基线 tracked 或 exception："
                f"{stable_id}（{from_path}）",
            )
            continue
        previous_kind, previous_item = previous_entry
        if previous_item["file"] != from_path:
            errors.append(
                "identityTransitions source 路径必须精确对应上一基线稳定 id："
                f"{stable_id}（{previous_item['file']} != {from_path}）",
            )
            continue

        git_destination = rename_map.get(from_path)
        if kind == "migration":
            assert to_path is not None
            current_entry = current_entries.get(stable_id)
            if current_entry is None or current_entry[1]["file"] != to_path:
                current_path = current_entry[1]["file"] if current_entry is not None else "<缺失>"
                errors.append(
                    "identityTransitions 当前目标必须为同一稳定 id 的当前登记项："
                    f"{stable_id}（期望 {to_path}，实际 {current_path}）",
                )
                continue
            current_kind, _ = current_entry
            if previous_kind == "tracked" and current_kind != "tracked":
                errors.append(
                    "上一基线既有大文件不得转入 exceptions："
                    f"{stable_id}；identityTransitions 不能降低 tracked 身份",
                )
                continue
            if (production_root / from_path).is_file():
                errors.append(
                    f"identityTransitions 迁移源路径仍存在，声明不是一次性 D+A：{from_path}",
                )
                continue
            if not (production_root / to_path).is_file():
                errors.append(f"identityTransitions 迁移目标不存在：{to_path}")
                continue
            if git_destination is not None:
                if git_destination == to_path:
                    errors.append(
                        "identityTransitions 与 Git rename 证据重复："
                        f"{from_path} -> {to_path}",
                    )
                else:
                    errors.append(
                        "identityTransitions 与 Git rename 证据冲突："
                        f"{from_path} -> {to_path}，Git 为 {from_path} -> {git_destination}",
                    )
                continue
            git_source = rename_sources_by_destination.get(to_path)
            if git_source is not None and git_source != from_path:
                errors.append(
                    "identityTransitions 与 Git rename 目标冲突："
                    f"{from_path} -> {to_path}，Git source 为 {git_source}",
                )
                continue
            verified_migrations[from_path] = to_path
            continue

        if git_destination is not None:
            errors.append(
                "identityTransitions 删除声明与 Git rename 证据冲突："
                f"{from_path} -> {git_destination}",
            )
            continue
        if (production_root / from_path).is_file():
            errors.append(f"identityTransitions 删除声明的 source 路径仍存在：{from_path}")
            continue
        if stable_id in current_entries:
            errors.append(
                "identityTransitions 删除声明不得保留同一稳定 id 的当前注册目标："
                f"{stable_id}",
            )
            continue
        if from_path in current_by_file:
            errors.append(
                "identityTransitions 删除声明不得保留 source 路径的当前注册目标："
                f"{from_path}",
            )
            continue
        verified_deletions.add(stable_id)

    return verified_migrations, verified_deletions


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
    transitions: list[dict[str, str | None]],
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
    verified_migrations, verified_deletions = _validate_identity_transitions(
        transitions,
        previous,
        previous_exceptions,
        current,
        current_exceptions,
        production_root,
        rename_map,
        errors,
    )
    continuity_map = {**rename_map, **verified_migrations}

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
            _require_verified_path_continuity(previous_item, current_item, continuity_map, errors)
            _compare_entry_ratchet(current_item, previous_item, errors)
            continue

        relative = str(previous_item["file"])
        same_path_item = _entry_at_previous_or_renamed_path(
            relative,
            current_by_file,
            current_exceptions_by_file,
            continuity_map,
        )
        if same_path_item is not None:
            errors.append(
                f"上一基线既有大文件稳定 id 不得改换：{stable_id}（路径 {relative}）",
            )
        elif stable_id not in verified_deletions:
            previous_path = production_root / relative
            if not previous_path.is_file():
                errors.append(
                    "上一基线既有大文件删除缺少显式删除声明："
                    f"{stable_id}（{relative}）",
                )
            elif _line_count(previous_path) > current_limit:
                errors.append(
                    f"上一基线既有大文件仍超过 {current_limit} 行，必须继续登记："
                    f"{stable_id}（当前 {_line_count(previous_path)} 行）",
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
                continuity_map,
                errors,
            )
            continue
        if current_item is not None:
            _require_verified_path_continuity(
                previous_exception,
                current_item,
                continuity_map,
                errors,
            )
            continue

        relative = str(previous_exception["file"])
        same_path_item = _entry_at_previous_or_renamed_path(
            relative,
            current_by_file,
            current_exceptions_by_file,
            continuity_map,
        )
        if same_path_item is not None:
            errors.append(
                f"上一基线 exception 稳定 id 不得改换：{stable_id}（路径 {relative}）",
            )
        elif stable_id not in verified_deletions:
            previous_path = production_root / relative
            if not previous_path.is_file():
                errors.append(
                    "上一基线 exception 删除缺少显式删除声明："
                    f"{stable_id}（{relative}）",
                )
            elif _line_count(previous_path) > current_limit:
                errors.append(
                    f"上一基线 exception 仍超过 {current_limit} 行，必须继续登记："
                    f"{stable_id}（当前 {_line_count(previous_path)} 行）",
                )

    previous_ids = set(previous_by_id) | set(previous_exceptions_by_id)
    new_exception_ids = sorted(set(current_exceptions_by_id) - previous_ids)
    if new_exception_ids:
        for stable_id, previous_item in {**previous_by_id, **previous_exceptions_by_id}.items():
            if stable_id in current_by_id or stable_id in current_exceptions_by_id:
                continue
            if stable_id in verified_deletions:
                continue
            if not (production_root / str(previous_item["file"])).is_file():
                errors.append(
                    "检测到 previous 身份消失与新增 exception 的 D+A 组合，"
                    "缺少有效一次性迁移或删除声明："
                    f"{stable_id}（新增 exception：{', '.join(new_exception_ids)}）",
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
    transitions = _identity_transitions(debt, errors)
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
            transitions,
            previous_structure_debt,
            production_root,
            limit,
            errors,
            rename_map or {},
        )
    elif transitions:
        errors.append("identityTransitions 需要上一基线；无法验证一次性声明是否已被消费")
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
