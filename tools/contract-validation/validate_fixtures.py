#!/usr/bin/env python3
"""严格校验仓库中的脱敏 Fixture 及其元数据。"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPOSITORY_ROOT / "contracts/fixtures-redacted"
PRIVATE_API_COMPATIBILITY_PATH = (
    REPOSITORY_ROOT / "contracts/private-api/compatibility.json"
)
DISCOVERY_ENDPOINT_INDEX_REF = "docs/api/discovery/endpoints/INDEX.md"

FIXTURE_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:[.-][a-z0-9]+)*$")
DSM_VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")
BUILD_PATTERN = re.compile(r"^[0-9]{4,8}$")
API_PATTERN = re.compile(r"^SYNO\.[A-Za-z0-9_.]+$")
API_PATH_PATTERN = re.compile(r"^(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.cgi$")
METHOD_PATTERN = re.compile(r"^[a-z][A-Za-z0-9_]{0,79}$")
PLACEHOLDER_PATTERN = re.compile(r"^<redacted:[a-z0-9-]+>$")

SENSITIVE_KEY_PATTERN = re.compile(
    r"^(?:_?sid|synotoken|cookie|did|password|passwd|otp(?:_code)?|"
    r"device_(?:id|token)|access_token|refresh_token|token|account|username|"
    r"hostname|server_name|serial(?:_number)?|mac(?:_address)?|quickconnect_id|"
    r"certificate|fingerprint)$",
    re.IGNORECASE,
)
PROHIBITED_VALUE_PATTERNS = (
    ("URL", re.compile(r"https?://", re.IGNORECASE)),
    (
        "IPv4 地址",
        re.compile(
            r"(?<![0-9])(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})"
            r"(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3}(?![0-9])"
        ),
    ),
    ("MAC 地址", re.compile(r"\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b", re.IGNORECASE)),
    (
        "电子邮箱",
        re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    ),
    (
        "真实 NAS 路径",
        re.compile(r"(?:/volume[0-9]+/|/homes?/|\\\\\\\\[^\\s]+\\\\)", re.IGNORECASE),
    ),
)

SOURCE_KINDS = {"synthetic", "real-redacted"}
ARCHITECTURES = {"x86_64", "aarch64", "armv7", "unknown"}
ACCOUNT_ROLES = {"standard", "administrator", "unknown"}
CONNECTION_TYPES = {
    "lan",
    "quickconnect-direct",
    "quickconnect-relay",
    "reverse-proxy",
    "unknown",
}
EVIDENCE_LEVELS = {
    "static",
    "observed",
    "read-verified",
    "behavior-verified",
    "failed",
}


class ValidationError(ValueError):
    """表示 Fixture 不满足提交要求。"""


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"{path}: 无法读取 JSON：{error}") from error


def require_keys(
    value: dict[str, Any],
    location: str,
    required: set[str],
    optional: set[str] | None = None,
) -> None:
    optional = optional or set()
    missing = required - value.keys()
    unexpected = value.keys() - required - optional
    if missing:
        raise ValidationError(f"{location} 缺少字段：{', '.join(sorted(missing))}")
    if unexpected:
        raise ValidationError(f"{location} 包含未定义字段：{', '.join(sorted(unexpected))}")


def require_string(value: Any, location: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value:
        raise ValidationError(f"{location} 必须是非空字符串")
    if pattern and pattern.fullmatch(value) is None:
        raise ValidationError(f"{location} 格式无效")
    return value


def require_enum(value: Any, location: str, choices: set[str]) -> str:
    if not isinstance(value, str) or value not in choices:
        raise ValidationError(f"{location} 必须是以下值之一：{', '.join(sorted(choices))}")
    return value


def validate_metadata(value: Any, path: Path) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{path}: 元数据必须是对象")
    require_keys(
        value,
        str(path),
        {
            "schemaVersion",
            "fixtureId",
            "sourceKind",
            "environment",
            "accountRole",
            "connectionType",
            "evidenceLevel",
            "api",
            "scenario",
            "redactedFields",
        },
        {"package"},
    )
    if value["schemaVersion"] != 1:
        raise ValidationError(f"{path}: schemaVersion 必须为 1")
    fixture_id = require_string(value["fixtureId"], f"{path}.fixtureId", FIXTURE_ID_PATTERN)
    if path.parent.name != fixture_id:
        raise ValidationError(f"{path}: fixtureId 必须与目录名一致")
    source_kind = require_enum(value["sourceKind"], f"{path}.sourceKind", SOURCE_KINDS)

    environment = value["environment"]
    if not isinstance(environment, dict):
        raise ValidationError(f"{path}.environment 必须是对象")
    require_keys(
        environment,
        f"{path}.environment",
        {"alias", "dsmVersion", "build", "update", "architecture"},
    )
    alias = require_string(environment["alias"], f"{path}.environment.alias")
    if source_kind == "synthetic" and alias != "synthetic":
        raise ValidationError(f"{path}: 合成样本必须使用 synthetic 环境别名")
    if source_kind == "real-redacted" and re.fullmatch(r"lab-[a-z]", alias) is None:
        raise ValidationError(f"{path}: 真实脱敏样本必须使用 lab-a 等稳定环境别名")
    require_string(environment["dsmVersion"], f"{path}.environment.dsmVersion", DSM_VERSION_PATTERN)
    require_string(environment["build"], f"{path}.environment.build", BUILD_PATTERN)
    update = require_string(environment["update"], f"{path}.environment.update")
    if re.fullmatch(r"(?:[0-9]{1,3}|none|unknown)", update) is None:
        raise ValidationError(f"{path}.environment.update 格式无效")
    require_enum(
        environment["architecture"],
        f"{path}.environment.architecture",
        ARCHITECTURES,
    )

    if "package" in value:
        package = value["package"]
        if not isinstance(package, dict):
            raise ValidationError(f"{path}.package 必须是对象")
        require_keys(package, f"{path}.package", {"name", "version"})
        require_string(package["name"], f"{path}.package.name")
        require_string(package["version"], f"{path}.package.version")

    require_enum(value["accountRole"], f"{path}.accountRole", ACCOUNT_ROLES)
    require_enum(value["connectionType"], f"{path}.connectionType", CONNECTION_TYPES)
    require_enum(value["evidenceLevel"], f"{path}.evidenceLevel", EVIDENCE_LEVELS)

    api = value["api"]
    if not isinstance(api, dict):
        raise ValidationError(f"{path}.api 必须是对象")
    require_keys(api, f"{path}.api", {"name", "path", "version", "method"})
    require_string(api["name"], f"{path}.api.name", API_PATTERN)
    require_string(api["path"], f"{path}.api.path", API_PATH_PATTERN)
    if not isinstance(api["version"], int) or api["version"] < 1:
        raise ValidationError(f"{path}.api.version 必须是正整数")
    require_string(api["method"], f"{path}.api.method", METHOD_PATTERN)
    scenario = require_string(value["scenario"], f"{path}.scenario")
    if len(scenario) > 240:
        raise ValidationError(f"{path}.scenario 不能超过 240 个字符")
    redacted_fields = value["redactedFields"]
    if not isinstance(redacted_fields, list) or any(
        not isinstance(item, str) or not item for item in redacted_fields
    ):
        raise ValidationError(f"{path}.redactedFields 必须是非空字符串数组")
    if len(redacted_fields) != len(set(redacted_fields)):
        raise ValidationError(f"{path}.redactedFields 不能重复")
    return value


def scan_privacy(value: Any, location: str = "$", key: str | None = None) -> None:
    if key and SENSITIVE_KEY_PATTERN.fullmatch(key):
        if not isinstance(value, str) or PLACEHOLDER_PATTERN.fullmatch(value) is None:
            raise ValidationError(f"{location} 的敏感字段值没有使用脱敏占位符")
        return
    if isinstance(value, dict):
        for child_key, child in value.items():
            scan_privacy(child, f"{location}.{child_key}", child_key)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            scan_privacy(child, f"{location}[{index}]", key)
        return
    if not isinstance(value, str):
        return
    for description, pattern in PROHIBITED_VALUE_PATTERNS:
        if pattern.search(value):
            raise ValidationError(f"{location} 包含禁止的{description}")


def validate_fixture_directory(directory: Path) -> None:
    metadata_path = directory / "metadata.json"
    response_path = directory / "response.json"
    unexpected = {
        child.name
        for child in directory.iterdir()
        if child.is_file() and child.name not in {"metadata.json", "response.json"}
    }
    if unexpected:
        raise ValidationError(
            f"{directory}: 包含未定义文件：{', '.join(sorted(unexpected))}"
        )
    if not metadata_path.is_file() or not response_path.is_file():
        raise ValidationError(f"{directory}: 必须同时包含 metadata.json 和 response.json")
    metadata = validate_metadata(load_json(metadata_path), metadata_path)
    scan_privacy(metadata, "$metadata")
    response = load_json(response_path)
    if not isinstance(response, dict) or not isinstance(response.get("success"), bool):
        raise ValidationError(f"{response_path}: 必须是包含布尔 success 的 DSM 响应对象")
    scan_privacy(response)


def discover_fixture_directories(root: Path = FIXTURE_ROOT) -> list[Path]:
    return sorted(
        path.parent
        for path in root.rglob("metadata.json")
        if path.parent != root
    )


def validate_all(root: Path = FIXTURE_ROOT) -> list[Path]:
    directories = discover_fixture_directories(root)
    response_parents = {
        path.parent for path in root.rglob("response.json") if path.parent != root
    }
    if response_parents != set(directories):
        raise ValidationError(f"{root}: 存在缺少 metadata.json 的响应样本")
    if not directories:
        raise ValidationError(f"{root}: 至少需要一个 Fixture")
    for directory in directories:
        validate_fixture_directory(directory)
    return directories


def resolve_repository_document(document_ref: str, repository_root: Path) -> Path:
    root = repository_root.resolve()
    document = (root / document_ref).resolve()
    try:
        document.relative_to(root)
    except ValueError as error:
        raise ValidationError(f"documentRef 越出仓库范围：{document_ref}") from error
    if not document.is_file():
        raise ValidationError(f"documentRef 指向的文件不存在：{document_ref}")
    return document


def validate_private_api_document_refs(
    value: Any,
    repository_root: Path = REPOSITORY_ROOT,
) -> int:
    if not isinstance(value, dict) or not isinstance(value.get("endpoints"), list):
        raise ValidationError("私有 API 兼容索引必须包含 endpoints 数组")

    validated = 0
    for index, endpoint in enumerate(value["endpoints"]):
        location = f"endpoints[{index}]"
        if not isinstance(endpoint, dict):
            raise ValidationError(f"{location} 必须是对象")
        if endpoint.get("classification") != "internal":
            continue

        endpoint_id = require_string(endpoint.get("id"), f"{location}.id")
        document_ref = require_string(
            endpoint.get("documentRef"),
            f"{location}.documentRef",
        )
        document = resolve_repository_document(document_ref, repository_root)
        is_summary_index = Path(document_ref).name == "INDEX.md"

        if is_summary_index:
            raise ValidationError(
                f"{endpoint_id}: 内部端点不能只引用汇总 INDEX，必须引用声明稳定标识的接口正文"
            )
        elif f"`{endpoint_id}`" not in document.read_text(encoding="utf-8"):
            raise ValidationError(
                f"{endpoint_id}: 独立稳定记录未声明对应端点标识"
            )
        validated += 1
    return validated


def validate_private_api_compatibility(
    path: Path = PRIVATE_API_COMPATIBILITY_PATH,
    repository_root: Path = REPOSITORY_ROOT,
) -> int:
    return validate_private_api_document_refs(load_json(path), repository_root)


def main() -> int:
    parser = argparse.ArgumentParser(description="校验仓库中的脱敏 DSM Fixture")
    parser.add_argument("--root", type=Path, default=FIXTURE_ROOT)
    arguments = parser.parse_args()
    try:
        directories = validate_all(arguments.root)
        private_api_count = validate_private_api_compatibility()
    except ValidationError as error:
        print(error, file=sys.stderr)
        return 1
    print(
        f"Fixture 校验通过：{len(directories)} 组；"
        f"私有 API 文档引用校验通过：{private_api_count} 项"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
