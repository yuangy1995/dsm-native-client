#!/usr/bin/env python3
"""检查 Android 自定义点击目标是否满足 JSON 基线中的尺寸与反馈合约。"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import sys
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_android_quality_baseline import load_baseline


ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = ROOT / "android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/ui"

INTERACTION_PATTERN = re.compile(
    r"\.(?P<kind>clickable|combinedClickable|toggleable|selectable)\s*(?:\(|\{)"
)
GESTURE_TAP_PATTERN = re.compile(r"\b(?:pointerInput|detectTapGestures)\s*\(")
HEIGHT_PATTERN = re.compile(
    r"\.(?:height|heightIn)\s*\(\s*(?:min\s*=\s*)?(?P<value>\d+(?:\.\d+)?)\.dp"
)
WIDTH_PATTERN = re.compile(
    r"\.(?:width|widthIn)\s*\(\s*(?:min\s*=\s*)?(?P<value>\d+(?:\.\d+)?)\.dp"
)
SIZE_PATTERN = re.compile(r"\.size\s*\(\s*(?P<value>\d+(?:\.\d+)?)\.dp")
SIZE_IN_MIN_WIDTH_PATTERN = re.compile(
    r"\.sizeIn\s*\([^)]*minWidth\s*=\s*(?P<value>\d+(?:\.\d+)?)\.dp",
    re.DOTALL,
)
SIZE_IN_MIN_HEIGHT_PATTERN = re.compile(
    r"\.sizeIn\s*\([^)]*minHeight\s*=\s*(?P<value>\d+(?:\.\d+)?)\.dp",
    re.DOTALL,
)


@dataclass(frozen=True)
class TouchTargetFinding:
    path: str
    line: int
    kind: str
    modifier_source: str


def _modifier_source(lines: list[str], interaction_index: int) -> str:
    """截取当前交互调用所属 Modifier 链，避免借用另一组件的尺寸。"""
    lower_bound = max(0, interaction_index - 16)
    start = interaction_index
    for index in range(interaction_index, lower_bound - 1, -1):
        if index < interaction_index and re.search(r"\bmodifier\s*=", lines[index]):
            if not re.search(r"\bModifier\b", lines[index]):
                return "\n".join(lines[index : interaction_index + 1])
        if re.search(r"\bModifier\b", lines[index]):
            start = index
            break
    return "\n".join(lines[start : interaction_index + 1])


def scan_ui(ui_root: Path = UI_ROOT) -> tuple[list[TouchTargetFinding], list[str]]:
    findings: list[TouchTargetFinding] = []
    gesture_errors: list[str] = []
    for path in sorted(ui_root.rglob("*.kt")):
        lines = path.read_text(encoding="utf-8").splitlines()
        relative_path = path.relative_to(ui_root).as_posix()
        for index, source in enumerate(lines):
            for match in INTERACTION_PATTERN.finditer(source):
                findings.append(
                    TouchTargetFinding(
                        path=relative_path,
                        line=index + 1,
                        kind=match.group("kind"),
                        modifier_source=_modifier_source(lines, index),
                    )
                )
            if GESTURE_TAP_PATTERN.search(source):
                gesture_errors.append(
                    f"需人工审计的手势点击区域：{relative_path}:{index + 1}: {source.strip()}"
                )
    return findings, gesture_errors


def _at_least(match: re.Match[str] | None, minimum_dp: float) -> bool:
    return match is not None and float(match.group("value")) >= minimum_dp


def _policy() -> dict[str, Any]:
    return load_baseline()["touchTargets"]


def validate_findings(
    findings: list[TouchTargetFinding],
    gesture_errors: list[str],
    policy: dict[str, Any] | None = None,
) -> list[str]:
    """根据机器基线验证静态扫描结果，便于单测注入不同阈值。"""
    resolved_policy = _policy() if policy is None else policy
    minimum_dp = float(resolved_policy["minimumDp"])
    rules = resolved_policy.get("rules", {})
    errors = list(gesture_errors) if rules.get("forbidGestureTapWithoutReview", True) else []
    for finding in findings:
        source = finding.modifier_source
        native_minimum = ".minimumInteractiveComponentSize()" in source
        height_ok = (
            native_minimum
            or _at_least(HEIGHT_PATTERN.search(source), minimum_dp)
            or _at_least(SIZE_PATTERN.search(source), minimum_dp)
            or _at_least(SIZE_IN_MIN_HEIGHT_PATTERN.search(source), minimum_dp)
        )
        width_ok = (
            native_minimum
            or ".fillMaxWidth(" in source
            or ".weight(" in source
            or _at_least(WIDTH_PATTERN.search(source), minimum_dp)
            or _at_least(SIZE_PATTERN.search(source), minimum_dp)
            or _at_least(SIZE_IN_MIN_WIDTH_PATTERN.search(source), minimum_dp)
        )
        location = f"{finding.path}:{finding.line} ({finding.kind})"
        if not height_ok:
            errors.append(f"自定义点击目标缺少至少 {minimum_dp:g}dp 的高度合约：{location}")
        if not width_ok:
            errors.append(f"自定义点击目标缺少至少 {minimum_dp:g}dp 的宽度合约：{location}")
        if rules.get("requireNativePressFeedback", True) and "indication = null" in source:
            errors.append(f"自定义点击目标禁用了原生按压反馈：{location}")
    return errors


def main() -> int:
    policy = _policy()
    findings, gesture_errors = scan_ui()
    errors = validate_findings(findings, gesture_errors, policy)
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    minimum_dp = policy["minimumDp"]
    print(
        "Android 点击目标审计通过："
        f"{len(findings)} 处自定义交互均具备至少 {minimum_dp}dp 双向尺寸与原生按压反馈。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
