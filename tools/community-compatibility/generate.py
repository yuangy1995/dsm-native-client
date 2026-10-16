#!/usr/bin/env python3
"""从已审核报告生成中英文社区兼容矩阵。"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = Path(__file__).with_name("validate.py")
ZH_OUTPUT = (
    REPOSITORY_ROOT
    / "docs/compatibility/COMMUNITY_COMPATIBILITY_MATRIX_ZH.md"
)
EN_OUTPUT = (
    REPOSITORY_ROOT
    / "docs/compatibility/COMMUNITY_COMPATIBILITY_MATRIX_EN.md"
)

STATUS_ORDER = ("passed", "partial", "failed", "not-supported", "skipped")
STATUS_LABELS = {
    "zh-Hans": {
        "passed": "通过",
        "partial": "部分通过",
        "failed": "失败",
        "not-supported": "不支持",
        "skipped": "跳过",
    },
    "en": {
        "passed": "Passed",
        "partial": "Partial",
        "failed": "Failed",
        "not-supported": "Unsupported",
        "skipped": "Skipped",
    },
}
REVIEW_LABELS = {
    "zh-Hans": {
        "reviewed": "已审核",
        "corroborated": "社区复核",
        "maintainer-verified": "维护者验证",
        "disputed": "存在冲突",
        "superseded": "已取代",
    },
    "en": {
        "reviewed": "Reviewed",
        "corroborated": "Corroborated",
        "maintainer-verified": "Maintainer verified",
        "disputed": "Disputed",
        "superseded": "Superseded",
    },
}


def load_validator() -> Any:
    specification = importlib.util.spec_from_file_location(
        "community_compatibility_validate", VALIDATOR_PATH
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(
            "无法加载社区兼容性校验器 / unable to load compatibility validator"
        )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def escape_cell(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def dsm_label(report: dict[str, Any]) -> str:
    dsm = report["dsm"]
    suffix = ""
    if dsm["update"] not in {"none", "unknown"}:
        suffix = f" U{dsm['update']}"
    elif dsm["update"] == "unknown":
        suffix = " U?"
    return f"{dsm['version']}-{dsm['build']}{suffix}"


def package_label(report: dict[str, Any], empty: str) -> str:
    packages = report["packages"]
    if not packages:
        return empty
    return "<br>".join(
        f"{escape_cell(package['id'])} {escape_cell(package['version'])}"
        for package in sorted(packages, key=lambda item: item["id"])
    )


def report_summary(report: dict[str, Any], language: str) -> str:
    counts = Counter(result["status"] for result in report["results"])
    parts = []
    for status in STATUS_ORDER:
        if counts[status]:
            parts.append(f"{STATUS_LABELS[language][status]} {counts[status]}")
    return " / ".join(parts)


def environment_key(report: dict[str, Any]) -> tuple[str, ...]:
    packages = "; ".join(
        f"{package['id']} {package['version']}"
        for package in sorted(report["packages"], key=lambda item: item["id"])
    )
    return (
        report["nas"]["model"],
        report["nas"]["architecture"],
        dsm_label(report),
        report["app"]["platform"],
        report["app"]["platformVersion"],
        report["app"]["version"],
        report["app"]["commit"],
        str(report["testSuiteVersion"]),
        report["connectionType"],
        report["accountRole"],
        report["certificateType"],
        packages,
    )


def render_overview(
    reports: list[dict[str, Any]],
    language: str,
) -> list[str]:
    if language == "zh-Hans":
        header = (
            "| 报告 / 来源 | NAS 型号 / 架构 | DSM | 客户端 | 测试条件 | "
            "套件版本 | 审核状态 | 结果摘要 |"
        )
        separator = "| --- | --- | --- | --- | --- | --- | --- | --- |"
        empty = "暂无已审核社区报告。"
        no_packages = "未记录"
    else:
        header = (
            "| Report / source | NAS model / architecture | DSM | Client | Test context "
            "| Package versions | Review status | Result summary |"
        )
        separator = "| --- | --- | --- | --- | --- | --- | --- | --- |"
        empty = "No reviewed community reports are available yet."
        no_packages = "Not recorded"
    if not reports:
        return [empty]

    lines = [header, separator]
    for report in reports:
        review_label = REVIEW_LABELS[language].get(
            report["reviewStatus"], report["reviewStatus"]
        )
        lines.append(
            "| {report_id}<br>{source_ref} | {model} / {architecture} | {dsm} | "
            "{platform} {platform_version}<br>LanStash {app_version} | "
            "{connection}<br>{role}<br>{certificate} | "
            "{packages} | {review} | {summary} |".format(
                report_id=escape_cell(report["reportId"]),
                source_ref=escape_cell(report["sourceRef"]),
                model=escape_cell(report["nas"]["model"]),
                architecture=escape_cell(report["nas"]["architecture"]),
                dsm=escape_cell(dsm_label(report)),
                platform=escape_cell(report["app"]["platform"]),
                platform_version=escape_cell(report["app"]["platformVersion"]),
                app_version=escape_cell(report["app"]["version"]),
                connection=escape_cell(
                    (
                        "测试套件 v"
                        if language == "zh-Hans"
                        else "Test suite v"
                    )
                    + str(report["testSuiteVersion"])
                    + "<br>"
                    + report["connectionType"]
                ),
                role=escape_cell(report["accountRole"]),
                certificate=escape_cell(report["certificateType"]),
                packages=package_label(report, no_packages),
                review=escape_cell(review_label),
                summary=escape_cell(report_summary(report, language)),
            )
        )
    return lines


def render_coverage(
    reports: list[dict[str, Any]],
    capabilities: dict[str, dict[str, Any]],
    language: str,
) -> list[str]:
    active_reports = [
        report for report in reports if report["reviewStatus"] != "superseded"
    ]
    if language == "zh-Hans":
        header = "| 环境组合 | 能力 | 通过 | 部分通过 | 失败 | 不支持 | 跳过 |"
        separator = "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
        empty = "暂无可汇总的有效报告。"
    else:
        header = (
            "| Environment combination | Capability | Passed | Partial | Failed "
            "| Unsupported | Skipped |"
        )
        separator = "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
        empty = "No active reports are available for aggregation."
    if not active_reports:
        return [empty]

    grouped: dict[
        tuple[str, ...], dict[str, Counter[str]]
    ] = defaultdict(lambda: defaultdict(Counter))
    for report in active_reports:
        key = environment_key(report)
        for result in report["results"]:
            grouped[key][result["capabilityId"]][result["status"]] += 1

    lines = [header, separator]
    for key in sorted(grouped):
        (
            model,
            architecture,
            dsm,
            platform,
            platform_version,
            app_version,
            app_commit,
            test_suite_version,
            connection,
            role,
            certificate,
            packages,
        ) = key
        environment = (
            f"{model} / {architecture}<br>{dsm}<br>"
            f"{platform} {platform_version} / LanStash {app_version} "
            f"({'提交' if language == 'zh-Hans' else 'commit'} {app_commit})<br>"
            f"{'测试套件' if language == 'zh-Hans' else 'Test suite'} "
            f"v{test_suite_version}<br>"
            f"{connection} / {role} / {certificate}<br>{packages or '-'}"
        )
        for capability_id in capabilities:
            if capability_id not in grouped[key]:
                continue
            counts = grouped[key][capability_id]
            capability_name = capabilities[capability_id]["name"][language]
            lines.append(
                f"| {escape_cell(environment)} | "
                f"{escape_cell(capability_name)}<br>`{capability_id}` | "
                f"{counts['passed']} | {counts['partial']} | {counts['failed']} | "
                f"{counts['not-supported']} | {counts['skipped']} |"
            )
    return lines


def render_document(
    reports: list[dict[str, Any]],
    capabilities: dict[str, dict[str, Any]],
    language: str,
) -> str:
    if language == "zh-Hans":
        title = "# 社区兼容矩阵"
        language_link = "[English](COMMUNITY_COMPATIBILITY_MATRIX_EN.md)"
        warning = (
            "> 本文件由结构化社区报告自动生成，请勿直接修改。社区报告不等同于"
            "维护者实机验收；“通过”只适用于表中精确版本组合。"
        )
        source = (
            "参与计划、隐私限制和审核规则见"
            " [`COMMUNITY_COMPATIBILITY_GUIDE_ZH.md`]"
            "(COMMUNITY_COMPATIBILITY_GUIDE_ZH.md)。"
        )
        overview = "## 报告概览"
        coverage = "## 能力汇总"
        generated_note = (
            f"当前包含 **{len(reports)}** 份已审核结构化报告。"
        )
    else:
        title = "# Community Compatibility Matrix"
        language_link = "[简体中文](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)"
        warning = (
            "> This file is generated from structured community reports. Do not edit "
            "it directly. Community reports are not maintainer device acceptance; a "
            "passing result applies only to the exact version combination shown."
        )
        source = (
            "See [`COMMUNITY_COMPATIBILITY_GUIDE_EN.md`]"
            "(COMMUNITY_COMPATIBILITY_GUIDE_EN.md) for participation, privacy, "
            "and review rules."
        )
        overview = "## Report overview"
        coverage = "## Capability coverage"
        generated_note = (
            f"The matrix currently contains **{len(reports)}** reviewed structured reports."
        )

    lines = [
        title,
        "",
        language_link,
        "",
        warning,
        "",
        source,
        "",
        generated_note,
        "",
        overview,
        "",
        *render_overview(reports, language),
        "",
        coverage,
        "",
        *render_coverage(reports, capabilities, language),
        "",
    ]
    return "\n".join(lines)


def write_or_check(path: Path, content: str, check: bool) -> bool:
    if check:
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        if existing != content:
            print(
                f"生成文件未同步 / generated file is out of date: {path}",
                file=sys.stderr,
            )
            return False
        return True
    path.write_text(content, encoding="utf-8")
    print(f"已生成 / generated: {path.relative_to(REPOSITORY_ROOT)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="生成社区兼容矩阵")
    parser.add_argument(
        "--check",
        action="store_true",
        help="只检查生成结果是否与仓库文件一致",
    )
    arguments = parser.parse_args()

    validator = load_validator()
    try:
        capabilities, reports = validator.load_and_validate_all()
    except validator.ValidationError as error:
        print(
            f"社区兼容性校验失败 / Community compatibility validation failed: "
            f"{error}",
            file=sys.stderr,
        )
        return 1

    reports = sorted(reports, key=lambda report: report["reportId"])
    outputs = (
        (ZH_OUTPUT, render_document(reports, capabilities, "zh-Hans")),
        (EN_OUTPUT, render_document(reports, capabilities, "en")),
    )
    succeeded = all(
        write_or_check(path, content, arguments.check) for path, content in outputs
    )
    return 0 if succeeded else 1


if __name__ == "__main__":
    raise SystemExit(main())
