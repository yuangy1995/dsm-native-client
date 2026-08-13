#!/usr/bin/env python3
"""校验 Android 生产写入口与写操作测试矩阵没有漂移。"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt"
CROSS_NAS_COORDINATOR = ROOT / (
    "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/"
    "CrossNasTransferCoordinator.kt"
)
MATRIX = ROOT / "docs/development/ANDROID_WRITE_MUTATION_TEST_MATRIX_ZH.md"
TEST_ROOT = ROOT / "android/app/src/test/java"
REPOSITORY = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt"
UI_ROOT = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/ui"
PRODUCTION_ROOT = ROOT / "android/app/src/main/java"

ROW_PATTERN = re.compile(r"<!-- WRITE-MUTATION (?P<body>.*?) -->")
FIELD_PATTERN = re.compile(r"(?P<key>[a-z]+)=(?P<value>[^;]*)(?:;|$)")
REQUIRED_OPEN_SCENARIOS = ("pre", "success", "disconnect", "readback", "cancel")
VALID_STATES = {"open", "closed", "readonly", "pending"}
REPOSITORY_FUNCTION_PATTERN = re.compile(
    r"(?m)^\s{4}(?:(?:internal|public|open|final|override)\s+)*"
    r"(?:suspend\s+)?fun\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("
)
VIEW_MODEL_FUNCTION_PATTERN = re.compile(
    r"(?m)^\s{4}(?:(?:private|internal|public|protected|open|override|final)\s+)*"
    r"(?:suspend\s+)?fun\s+(?:<[^>\n]+>\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*\("
)
FLAT_RESULT_COORDINATORS = {"action", "nasSettingsMutation"}

# 这里记录的是已经逐调用人工审查过的生产文件。门禁不尝试用正则猜测 Kotlin
# 数据流；任一文件内容、调用数量或调用所在文件变化都会要求重新审查并更新指纹。
AUDITED_PRODUCTION_FILES = {
    "io/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt": (
        "1bf4bc3db7a6c6c480575b7a8408fc161cfca7df9ff5b69a7c167c9d62dd1655",
        66,
    ),
    "io/github/qwertyuiop1995/dsmnativeclient/PhotoBackupWorker.kt": (
        "52afb09663aaefc417b8193fd2b4fd883e6598400b82cc83344f3964d5e8abce",
        2,
    ),
    "io/github/qwertyuiop1995/dsmnativeclient/VirtualMachineImageImportWorker.kt": (
        "0b163157eed769ee57f6a49331482f840a33a0a8d23776b3213a4a665523cb67",
        2,
    ),
    "io/github/qwertyuiop1995/dsmnativeclient/data/CrossNasTransferCoordinator.kt": (
        "87d52134afcb1ec0e4a1ad7fffec50e9413c2f7a5df5009e78b63379236996f8",
        6,
    ),
    "io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt": (
        "ca5199b0845bcdcb3e4e696f13cf47c718be41ed8d14bbaf11a1bcbc63884c1f",
        1,
    ),
}


@dataclass(frozen=True)
class MatrixRow:
    methods: tuple[str, ...]
    state: str
    multi: bool
    fields: dict[str, str]


@dataclass(frozen=True)
class ViewModelFunction:
    name: str
    body: str


def _view_model_functions(source: str) -> list[ViewModelFunction]:
    """提取 AppViewModel 的成员函数范围，兼容块函数和表达式函数。"""
    matches = list(VIEW_MODEL_FUNCTION_PATTERN.finditer(source))
    return [
        ViewModelFunction(
            name=match.group(1),
            body=source[match.start() : matches[index + 1].start()]
            if index + 1 < len(matches)
            else source[match.start() :],
        )
        for index, match in enumerate(matches)
    ]


def _repository_methods(source: str | None = None) -> set[str]:
    text = REPOSITORY.read_text(encoding="utf-8") if source is None else source
    return set(REPOSITORY_FUNCTION_PATTERN.findall(text))


def _default_ui_source() -> str:
    return "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted(UI_ROOT.rglob("*.kt"))
    )


def _calls_coordinator(body: str, names: set[str]) -> bool:
    return any(re.search(rf"\b{re.escape(name)}\s*(?:\(|\{{)", body) for name in names)


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
    aliases.update(re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:DsmRepository|CrossNasTransferEndpoint)\b",
        source,
    ))
    receiver = "|".join(re.escape(alias) for alias in sorted(aliases, key=len, reverse=True))
    method = "|".join(re.escape(name) for name in sorted(legacy_methods, key=len, reverse=True))
    pattern = re.compile(
        rf"\b(?:{receiver}|[A-Za-z_][A-Za-z0-9_]*\.repository)\s*"
        rf"(?:\.\s*|::\s*)(?P<method>{method})\b"
    )
    return [match.group("method") for match in pattern.finditer(source)]


def _production_sources() -> dict[str, str]:
    return {
        path.relative_to(PRODUCTION_ROOT).as_posix(): path.read_text(encoding="utf-8")
        for path in sorted(PRODUCTION_ROOT.rglob("*.kt"))
    }


def _container_gate_is_fixed_closed(source: str, functions: list[ViewModelFunction]) -> bool:
    gate_is_false = re.search(
        r"\bfun\s+containerWriteActionsEnabled\s*\([^)]*\)\s*:\s*Boolean\s*=\s*false\b",
        source,
    ) is not None
    coordinator = next((item for item in functions if item.name == "containerMutation"), None)
    if not gate_is_false or coordinator is None:
        return False
    gate = coordinator.body.find("if (!containerWriteActionsEnabled())")
    repository_claim = coordinator.body.find("val repo = repository")
    return gate >= 0 and repository_claim >= 0 and gate < repository_claim


def validate_workspace_routing(
    source: str | None = None,
    repository_source: str | None = None,
    ui_source: str | None = None,
    additional_sources: tuple[str, ...] | None = None,
) -> list[str]:
    """确保生产写调用仍与已人工审查的文件快照完全一致。"""
    text = VIEW_MODEL.read_text(encoding="utf-8") if source is None else source
    functions = _view_model_functions(text)
    repository_methods = _repository_methods(repository_source)
    result_methods = {method for method in repository_methods if method.endswith("Result")}
    errors: list[str] = []

    container_entries = {
        function.name
        for function in functions
        if function.name != "containerMutation" and
        _calls_coordinator(function.body, {"containerMutation"})
    }
    resolved_ui_source = _default_ui_source() if ui_source is None else ui_source
    container_is_closed = _container_gate_is_fixed_closed(text, functions) and all(
        re.search(rf"\b(?:model|viewModel)\s*\.\s*{re.escape(name)}\s*\(", resolved_ui_source)
        is None
        for name in container_entries
    )

    # 合成源码只用于门禁单测：任何未登记 Result 调用都必须触发人工审查。
    if source is not None:
        synthetic_text = "\n".join((text, *(additional_sources or ())))
        legacy = _legacy_repository_calls(synthetic_text, repository_methods)
        for method in sorted(set(legacy)):
            errors.append(f"发现旧服务端写入口 {method}，必须改用 {method}Result")
        calls = _result_calls(synthetic_text, result_methods)
        if calls and not container_is_closed:
            errors.append("发现未进入已审生产文件快照的 Result 调用，必须人工复核持久结果路由")
        return errors

    sources = _production_sources()
    call_files = {
        relative: calls
        for relative, source_text in sources.items()
        if (calls := _result_calls(source_text, result_methods))
    }
    for relative in sorted(call_files.keys() - AUDITED_PRODUCTION_FILES.keys()):
        errors.append(f"新增疑似 Result 调用文件未审计：{relative}")
    for relative in sorted(AUDITED_PRODUCTION_FILES.keys() - call_files.keys()):
        errors.append(f"已审 Result 调用文件不再包含调用：{relative}")
    for relative in sorted(call_files.keys() & AUDITED_PRODUCTION_FILES.keys()):
        expected_digest, expected_count = AUDITED_PRODUCTION_FILES[relative]
        path = PRODUCTION_ROOT / relative
        actual_digest = sha256(path.read_bytes()).hexdigest()
        if actual_digest != expected_digest:
            errors.append(f"已审写调用文件发生变化，必须重新复核并更新指纹：{relative}")
        if len(call_files[relative]) != expected_count:
            errors.append(
                f"已审写调用数量变化：{relative}（预期 {expected_count}，"
                f"当前 {len(call_files[relative])}）"
            )
    for relative, source_text in sources.items():
        for method in sorted(set(_legacy_repository_calls(source_text, repository_methods))):
            errors.append(f"{relative} 使用旧服务端写入口 {method}，必须改用 {method}Result")
    return errors


def production_result_calls(source: str | None = None) -> set[str]:
    result_methods = {method for method in _repository_methods() if method.endswith("Result")}
    sources = [source] if source is not None else _production_sources().values()
    return {method for text in sources for method in _result_calls(text, result_methods)}


def parse_rows(text: str | None = None) -> list[MatrixRow]:
    source = MATRIX.read_text(encoding="utf-8") if text is None else text
    rows: list[MatrixRow] = []
    for match in ROW_PATTERN.finditer(source):
        fields = {
            field.group("key"): field.group("value").strip()
            for field in FIELD_PATTERN.finditer(match.group("body"))
        }
        methods = tuple(filter(None, fields.get("methods", "").split(",")))
        rows.append(
            MatrixRow(
                methods=methods,
                state=fields.get("state", ""),
                multi=fields.get("multi") == "yes",
                fields=fields,
            )
        )
    return rows


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
    actual_calls = production_result_calls() if calls is None else calls
    actual_rows = parse_rows() if rows is None else rows
    errors: list[str] = []
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
                errors.append(
                    f"{','.join(row.methods)} 的 {scenario} 场景没有有效测试证据"
                )
                continue
            evidence_error = _validate_evidence(reference)
            if evidence_error:
                errors.append(evidence_error)

        if row.state == "pending":
            gaps = [
                scenario
                for scenario in REQUIRED_OPEN_SCENARIOS
                + (("partial",) if row.multi else ())
                if row.fields.get(scenario, "") == "gap"
            ]
            if not gaps:
                errors.append(f"pending 行未声明 gap：{','.join(row.methods)}")
            else:
                errors.append(
                    f"待补测试：{','.join(row.methods)} -> {','.join(gaps)}"
                )

        # 对已经填写的证据也做路径和测试名校验，避免 pending 行留下失效链接。
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
    print("Android 写操作测试矩阵通过：生产调用文件已审，入口、适用场景与测试证据均完整。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
