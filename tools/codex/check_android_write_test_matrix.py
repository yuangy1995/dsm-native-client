#!/usr/bin/env python3
"""校验 Android 生产写入口、结果路由和 JSON 测试基线没有漂移。"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import sys
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_android_quality_baseline import (
    BASELINE_PATH,
    DIRECT_RESULT_CALL_PATTERN,
    PRODUCTION_ROOT,
    discover_result_call_sites,
    load_baseline,
)


ROOT = Path(__file__).resolve().parents[2]
TEST_ROOT = ROOT / "android/app/src/test/java"
REPOSITORY = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt"
UI_ROOT = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/ui"
VIEW_MODEL = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt"
REQUIRED_OPEN_SCENARIOS = ("pre", "success", "disconnect", "readback", "cancel")
VALID_STATES = {"open", "closed", "readonly", "pending"}
REPOSITORY_FUNCTION_PATTERN = re.compile(
    r"(?m)^\s{4}(?:(?:internal|public|open|final|override|private)\s+)*"
    r"(?:suspend\s+)?fun\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("
)
REPOSITORY_EXPOSED_RESULT_PATTERN = re.compile(
    r"(?m)^\s{4}(?:(?:internal|public|open|final|override)\s+)*"
    r"(?:suspend\s+)?fun\s+([A-Za-z_][A-Za-z0-9_]*Result)\s*\("
)


@dataclass(frozen=True)
class MatrixRow:
    methods: tuple[str, ...]
    state: str
    multi: bool
    fields: dict[str, str]


def _baseline() -> dict[str, Any]:
    return load_baseline()


def _operations(baseline: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    return list((_baseline() if baseline is None else baseline)["writeOperations"])


def _operation_methods(operations: Iterable[dict[str, Any]]) -> set[str]:
    return {str(item["resultMethod"]) for item in operations}


def _repository_methods(source: str | None = None) -> set[str]:
    text = REPOSITORY.read_text(encoding="utf-8") if source is None else source
    return set(REPOSITORY_FUNCTION_PATTERN.findall(text))


def _result_call_pattern(result_methods: set[str]) -> re.Pattern[str]:
    names = "|".join(re.escape(name) for name in sorted(result_methods, key=len, reverse=True))
    return re.compile(rf"\.\s*(?P<direct>{names})\s*\(|::\s*(?P<reference>{names})\b")


def _result_calls(source: str, result_methods: set[str]) -> list[str]:
    if not result_methods:
        return []
    return [
        match.group("direct") or match.group("reference")
        for match in _result_call_pattern(result_methods).finditer(source)
    ]


def _legacy_repository_calls(source: str, repository_methods: set[str]) -> list[str]:
    result_methods = {method for method in repository_methods if method.endswith("Result")}
    legacy_methods = {
        method.removesuffix("Result")
        for method in result_methods
        if method.removesuffix("Result") in repository_methods
    }
    if not legacy_methods:
        return []
    aliases = {"repo", "repository"}
    aliases.update(
        re.findall(
            r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:DsmRepository|CrossNasTransferEndpoint)\b",
            source,
        )
    )
    receiver = "|".join(re.escape(alias) for alias in sorted(aliases, key=len, reverse=True))
    method = "|".join(re.escape(name) for name in sorted(legacy_methods, key=len, reverse=True))
    pattern = re.compile(
        rf"\b(?:{receiver}|[A-Za-z_][A-Za-z0-9_]*\.repository)\s*"
        rf"(?:\.\s*|::\s*)(?P<method>{method})\b"
    )
    return [match.group("method") for match in pattern.finditer(source)]


def _default_ui_source() -> str:
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(UI_ROOT.rglob("*.kt"))
    )


def _container_gate_is_fixed_closed(source: str) -> bool:
    return (
        re.search(
            r"\bfun\s+containerWriteActionsEnabled\s*\([^)]*\)\s*:\s*Boolean\s*=\s*false\b",
            source,
        )
        is not None
        and "if (!containerWriteActionsEnabled())" in source
    )


def _baseline_site_key(item: dict[str, Any]) -> tuple[str, str, str, int]:
    return (
        str(item["file"]),
        str(item["owner"]),
        str(item["resultMethod"]),
        int(item["occurrence"]),
    )


def _validate_operation_schema(operations: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    seen: set[tuple[str, str, str, int]] = set()
    for index, operation in enumerate(operations, 1):
        required = {"file", "owner", "resultMethod", "occurrence", "state", "multi", "scenarios"}
        missing = sorted(required - operation.keys())
        if missing:
            errors.append(f"writeOperations 第 {index} 项缺少字段：{', '.join(missing)}")
            continue
        key = _baseline_site_key(operation)
        if key in seen:
            errors.append(f"写调用点重复登记：{'::'.join(map(str, key))}")
        seen.add(key)
        if operation["state"] not in VALID_STATES:
            errors.append(f"{operation['resultMethod']} 的 state 无效：{operation['state']}")
        if not isinstance(operation["multi"], bool):
            errors.append(f"{operation['resultMethod']} 的 multi 必须为布尔值")
        scenarios = operation["scenarios"]
        if not isinstance(scenarios, dict):
            errors.append(f"{operation['resultMethod']} 的 scenarios 必须为对象")
    return errors


def _rows_from_operations(operations: list[dict[str, Any]]) -> tuple[list[MatrixRow], list[str]]:
    grouped: dict[str, MatrixRow] = {}
    errors: list[str] = []
    for operation in operations:
        method = str(operation["resultMethod"])
        fields = {str(name): str(value) for name, value in operation["scenarios"].items()}
        row = MatrixRow(
            methods=(method,),
            state=str(operation["state"]),
            multi=bool(operation["multi"]),
            fields=fields,
        )
        existing = grouped.get(method)
        if existing is None:
            grouped[method] = row
        elif existing != row:
            errors.append(f"同一 Result 方法的调用点测试合约不一致：{method}")
    return [grouped[method] for method in sorted(grouped)], errors


def parse_rows() -> list[MatrixRow]:
    """返回按 Result 方法归并的机器数据，兼容既有工具单测调用。"""
    rows, errors = _rows_from_operations(_operations())
    if errors:
        raise ValueError("；".join(errors))
    return rows


def production_result_calls(source: str | None = None) -> set[str]:
    methods = _operation_methods(_operations())
    if source is not None:
        return set(_result_calls(source, methods))
    return {
        str(item["resultMethod"])
        for item in discover_result_call_sites(methods)
    }


def _unknown_production_result_calls(known_methods: set[str]) -> list[str]:
    """发现新声明并被调用但尚未进入 JSON 的 DsmRepository Result 方法。"""
    repository_source = REPOSITORY.read_text(encoding="utf-8")
    # 仅把可由门面外部调用的 Result 方法视为新增生产写入口；私有 helper 的命名
    # 也以 Result 结尾，但不会形成新的 UI/Worker 写入口。
    candidate_methods = set(REPOSITORY_EXPOSED_RESULT_PATTERN.findall(repository_source))
    unknown: set[str] = set()
    for path in sorted(PRODUCTION_ROOT.rglob("*.kt")):
        source = path.read_text(encoding="utf-8")
        for match in DIRECT_RESULT_CALL_PATTERN.finditer(source):
            method = match.group("method")
            if method in candidate_methods and method not in known_methods:
                unknown.add(method)
    return sorted(unknown)


def _validate_call_site_inventory(operations: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    methods = _operation_methods(operations)
    expected = {_baseline_site_key(item) for item in operations}
    actual = {
        (
            str(site["file"]),
            str(site["owner"]),
            str(site["resultMethod"]),
            int(site["occurrence"]),
        )
        for site in discover_result_call_sites(methods)
    }
    for key in sorted(actual - expected):
        errors.append(
            "生产写入口未登记或已移动，必须补充调用文件、所属函数、状态和测试证据："
            + "::".join(map(str, key))
        )
    for key in sorted(expected - actual):
        errors.append("JSON 登记的生产写入口不存在：" + "::".join(map(str, key)))
    for method in _unknown_production_result_calls(methods):
        errors.append(f"发现新的 DsmRepository Result 写入口未登记：{method}")
    return errors


def validate_workspace_routing(
    source: str | None = None,
    repository_source: str | None = None,
    ui_source: str | None = None,
    additional_sources: tuple[str, ...] | None = None,
) -> list[str]:
    """验证新/移动调用点；合成源码分支供单测证明审查不可被绕过。"""
    if source is None and repository_source is None and additional_sources is None:
        operations = _operations()
        errors = _validate_operation_schema(operations)
        errors.extend(_validate_call_site_inventory(operations))
        repository_methods = _repository_methods()
        for path in sorted(PRODUCTION_ROOT.rglob("*.kt")):
            text = path.read_text(encoding="utf-8")
            for method in sorted(set(_legacy_repository_calls(text, repository_methods))):
                relative = path.relative_to(PRODUCTION_ROOT).as_posix()
                errors.append(f"{relative} 使用旧服务端写入口 {method}，必须改用 {method}Result")
        return errors

    text = source or ""
    repository_text = repository_source or ""
    synthetic = "\n".join((text, *(additional_sources or ())))
    repository_methods = _repository_methods(repository_text)
    result_methods = {method for method in repository_methods if method.endswith("Result")}
    errors: list[str] = []
    for method in sorted(set(_legacy_repository_calls(synthetic, repository_methods))):
        errors.append(f"发现旧服务端写入口 {method}，必须改用 {method}Result")

    calls = _result_calls(synthetic, result_methods)
    if calls:
        resolved_ui = _default_ui_source() if ui_source is None else ui_source
        container_closed = _container_gate_is_fixed_closed(text) and not re.search(
            r"\b(?:model|viewModel)\s*\.\s*(?:controlContainer|deleteContainer|"
            r"deleteContainerImage|createContainerNetwork|deleteContainerNetwork)\s*\(",
            resolved_ui,
        )
        if not container_closed:
            errors.append("发现未登记 Result 调用，必须人工复核结果持久化、取消边界与 JSON 测试证据")
    return errors


def _validate_evidence(reference: str) -> str | None:
    if reference in {"na", "gap", ""}:
        return None
    if "::" not in reference:
        return f"证据格式错误（应为相对路径::测试名片段）：{reference}"
    relative_path, test_name = reference.split("::", 1)
    path = TEST_ROOT / relative_path
    if "/" not in relative_path:
        matches = list(TEST_ROOT.rglob(relative_path))
        if len(matches) != 1:
            return f"测试证据文件必须唯一存在：{relative_path}（当前 {len(matches)} 个）"
        path = matches[0]
    if not path.is_file():
        return f"测试证据文件不存在：{relative_path}"
    if test_name not in path.read_text(encoding="utf-8"):
        return f"测试证据名称不存在：{relative_path}::{test_name}"
    return None


def validate(
    calls: set[str] | None = None,
    rows: list[MatrixRow] | None = None,
) -> list[str]:
    operations = _operations()
    actual_calls = production_result_calls() if calls is None else calls
    actual_rows, row_errors = _rows_from_operations(operations) if rows is None else (rows, [])
    errors: list[str] = list(row_errors)
    represented: dict[str, int] = {}

    for index, row in enumerate(actual_rows, 1):
        if not row.methods:
            errors.append(f"第 {index} 行缺少 methods")
            continue
        if row.state not in VALID_STATES:
            errors.append(f"第 {index} 行 state 无效：{row.state or '<空>'}")
        for method in row.methods:
            represented[method] = represented.get(method, 0) + 1

        required = ("zero",) if row.state == "closed" else ()
        if row.state == "open":
            required = REQUIRED_OPEN_SCENARIOS + (("partial",) if row.multi else ())
        elif row.state == "readonly":
            required = ("success", "readback", "cancel")

        for scenario in required:
            reference = row.fields.get(scenario, "")
            if reference in {"", "gap", "na"}:
                errors.append(f"{','.join(row.methods)} 的 {scenario} 场景没有有效测试证据")
                continue
            evidence_error = _validate_evidence(reference)
            if evidence_error:
                errors.append(evidence_error)

        if row.state == "pending":
            gaps = [
                scenario
                for scenario in REQUIRED_OPEN_SCENARIOS + (("partial",) if row.multi else ())
                if row.fields.get(scenario, "") == "gap"
            ]
            if not gaps:
                errors.append(f"pending 行未声明 gap：{','.join(row.methods)}")
            else:
                errors.append(f"待补测试：{','.join(row.methods)} -> {','.join(gaps)}")

        for scenario in ("pre", "success", "disconnect", "readback", "cancel", "partial", "zero"):
            reference = row.fields.get(scenario, "")
            if reference not in {"", "gap", "na"}:
                evidence_error = _validate_evidence(reference)
                if evidence_error and evidence_error not in errors:
                    errors.append(evidence_error)

    missing = actual_calls - represented.keys()
    extra = represented.keys() - actual_calls
    for method in sorted(missing):
        errors.append(f"生产写入口未进入矩阵：{method}")
    for method in sorted(extra):
        errors.append(f"矩阵记录了不存在的生产调用：{method}")
    for method, count in sorted(represented.items()):
        if count != 1:
            errors.append(f"生产写入口必须且只能记录一次：{method}（当前 {count} 次）")
    if calls is None and rows is None:
        errors.extend(validate_workspace_routing())
    return errors


def main() -> int:
    errors = validate()
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("Android 写操作测试基线通过：调用点、开放状态、场景与测试证据均完整。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
