#!/usr/bin/env python3
"""检查活动文档的职责元数据、链接、锚点、生成物与时效。"""

from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path
import re
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[2]
STATUS_PATH = ROOT / "docs/progress/STATUS.md"

ACTIVE_DOCUMENTS = {
    "README.md": "entrypoint",
    "README.en.md": "entrypoint",
    "android/README.md": "platform-readme",
    "apple/README.md": "platform-readme",
    "windows/README.md": "platform-readme",
    "docs/README.md": "documentation-index",
    "docs/progress/STATUS.md": "status",
    "docs/progress/PLATFORM_MATRIX.md": "platform-matrix",
    "docs/progress/ROADMAP.md": "roadmap",
    "docs/quality/VERIFICATION_LEVELS_ZH.md": "quality-policy",
    "docs/quality/ANDROID_QUALITY_BASELINE_ZH.md": "generated-quality-baseline",
    "docs/quality/MACOS_BETA_READINESS_ZH.md": "release-readiness",
    "docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md": "development-plan",
    "docs/development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md": "development-plan",
    "docs/development/MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md": "development-plan",
    "docs/development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md": "development-plan",
}

ROLE_PATTERN = re.compile(r"<!--\s*doc-role:\s*([a-z0-9-]+)\s*-->")
DATE_PATTERN = re.compile(r"<!--\s*last-reviewed:\s*(\d{4}-\d{2}-\d{2})\s*-->")
LINK_PATTERN = re.compile(r"(?<!!)\[[^\]]*\]\((?P<target><[^>]+>|[^)\s]+)(?:\s+[^)]*)?\)")
HEADING_PATTERN = re.compile(r"^(?:#{1,6})\s+(.+?)\s*#*\s*$")
CI_RUN_PATTERN = re.compile(
    r"\b(?:CI|GitHub|Apple|Android|Windows|Repository)\s+(?:Run|run|Build|build)\s*`?\d{6,}`?",
    re.IGNORECASE,
)
MANUAL_TEST_COUNT_PATTERN = re.compile(
    r"(?:测试|test|xUnit|XCTest|用例).{0,28}\b\d+\s*/\s*\d+\b|"
    r"\b\d+\s*/\s*\d+\b.{0,28}(?:测试|test|通过|passed)",
    re.IGNORECASE,
)


def _strip_code_fences(text: str) -> str:
    return re.sub(r"```.*?```", "", text, flags=re.DOTALL)


def _heading_slug(title: str) -> str:
    title = re.sub(r"`([^`]*)`", r"\1", title)
    title = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", title)
    title = re.sub(r"[*_~]", "", title).strip().lower()
    title = re.sub(r"[^\w\-\u4e00-\u9fff\s]", "", title)
    return re.sub(r"[\s-]+", "-", title).strip("-")


def anchors(text: str) -> set[str]:
    counts: dict[str, int] = {}
    values: set[str] = set()
    for line in text.splitlines():
        match = HEADING_PATTERN.match(line)
        if not match:
            continue
        slug = _heading_slug(match.group(1))
        if not slug:
            continue
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        values.add(slug if count == 0 else f"{slug}-{count}")
    return values


def _local_document_paths(root: Path) -> list[Path]:
    paths = [path for path in (root / "docs").rglob("*.md")]
    paths.extend(root / relative for relative in ACTIVE_DOCUMENTS if not relative.startswith("docs/"))
    return sorted({path.resolve() for path in paths if path.is_file()})


def _resolve_link(source: Path, target: str) -> tuple[Path | None, str | None]:
    raw = unquote(target.strip().strip("<>") )
    if not raw or raw.startswith(("https://", "http://", "mailto:", "tel:", "data:")):
        return None, None
    file_part, separator, anchor = raw.partition("#")
    destination = source if not file_part else (source.parent / file_part).resolve()
    return destination, anchor if separator else None


def validate_links(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    content_cache: dict[Path, str] = {}
    for path in paths:
        content = path.read_text(encoding="utf-8")
        content_cache[path] = content
        for match in LINK_PATTERN.finditer(_strip_code_fences(content)):
            destination, anchor = _resolve_link(path, match.group("target"))
            if destination is None:
                continue
            try:
                display = path.relative_to(ROOT).as_posix()
            except ValueError:
                display = str(path)
            if not destination.exists():
                errors.append(f"断链：{display} -> {match.group('target')}")
                continue
            if anchor and destination.is_file():
                target_text = content_cache.get(destination)
                if target_text is None:
                    target_text = destination.read_text(encoding="utf-8")
                    content_cache[destination] = target_text
                if anchor not in anchors(target_text):
                    errors.append(f"标题锚点不存在：{display} -> {match.group('target')}")
    return errors


def _metadata(path: Path) -> tuple[str | None, date | None, list[str]]:
    text = path.read_text(encoding="utf-8")
    header = "\n".join(text.splitlines()[:12])
    role_match = ROLE_PATTERN.search(header)
    date_match = DATE_PATTERN.search(header)
    errors: list[str] = []
    parsed_date: date | None = None
    if date_match:
        try:
            parsed_date = date.fromisoformat(date_match.group(1))
        except ValueError:
            errors.append(f"last-reviewed 日期无效：{path.relative_to(ROOT)}")
    return (role_match.group(1) if role_match else None), parsed_date, errors


def validate_active_metadata(
    root: Path = ROOT,
    active_documents: dict[str, str] = ACTIVE_DOCUMENTS,
    strict_release: bool = False,
    today: date | None = None,
) -> list[str]:
    errors: list[str] = []
    now = date.today() if today is None else today
    for relative, expected_role in active_documents.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"活动文档不存在：{relative}")
            continue
        role, reviewed, metadata_errors = _metadata(path)
        errors.extend(metadata_errors)
        if role is None:
            errors.append(f"活动文档缺少 doc-role：{relative}")
        elif role != expected_role:
            errors.append(f"活动文档 doc-role 不匹配：{relative}（应为 {expected_role}，当前 {role}）")
        if reviewed is None:
            errors.append(f"活动文档缺少 last-reviewed：{relative}")
        elif reviewed > now:
            errors.append(f"活动文档 last-reviewed 不能晚于当前日期：{relative}")

        text = _strip_code_fences(path.read_text(encoding="utf-8"))
        if CI_RUN_PATTERN.search(text):
            errors.append(f"活动文档不得记录 CI Run ID：{relative}")
        if MANUAL_TEST_COUNT_PATTERN.search(text):
            errors.append(f"活动文档不得记录人工维护的测试数量：{relative}")

        if strict_release and reviewed is not None:
            max_age = 30 if relative == "docs/progress/STATUS.md" else 90
            if relative in {
                "docs/progress/STATUS.md",
                "docs/progress/PLATFORM_MATRIX.md",
                "docs/progress/ROADMAP.md",
            } and (now - reviewed).days > max_age:
                errors.append(f"发布预检时效超限：{relative} 已超过 {max_age} 天")
    return errors


def validate_status_line_count(path: Path = STATUS_PATH) -> list[str]:
    lines = len(path.read_text(encoding="utf-8").splitlines())
    if not 150 <= lines <= 250:
        return [f"STATUS.md 必须为 150 至 250 行，当前 {lines} 行"]
    return []


def validate(strict_release: bool = False) -> list[str]:
    paths = _local_document_paths(ROOT)
    errors = validate_links(paths)
    errors.extend(validate_active_metadata(strict_release=strict_release))
    errors.extend(validate_status_line_count())
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="检查文档链接、角色和时效")
    parser.add_argument("--strict-release", action="store_true", help="启用发布预检时效限制")
    args = parser.parse_args()
    errors = validate(strict_release=args.strict_release)
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    suffix = "（严格发布预检）" if args.strict_release else ""
    print(f"文档检查通过{suffix}：链接、标题锚点、角色、时效和状态页行数均符合要求。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
