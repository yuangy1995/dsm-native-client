#!/usr/bin/env python3
"""检查 Android 生产界面是否新增未经 JSON 基线审计的显式时间动效。"""

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

TIME_MOTION_PATTERNS = (
    re.compile(r"^import android\.animation(?:\.|$)"),
    re.compile(r"^import androidx\.compose\.animation(?:\.|$)"),
    re.compile(
        r"\b(?:Animatable|AnimatedContent|AnimatedVisibility|Crossfade|"
        r"TargetBasedAnimation|animate\w*AsState|animateTo|decay|"
        r"infiniteRepeatable|keyframes|rememberInfiniteTransition|repeatable|"
        r"spring|tween|updateTransition)\s*\("
    ),
    re.compile(r"\bValueAnimator\.areAnimatorsEnabled\s*\("),
)


def _motion_policy() -> dict[str, Any]:
    return load_baseline()["motion"]


# 兼容已有聚焦单测，并且值始终由机器基线而非 Markdown 文档给出。
_BASELINE_MOTION = _motion_policy()
ALLOWED_SOURCES = set(_BASELINE_MOTION["allowedSources"])
ALLOWED_PATH = _BASELINE_MOTION["allowedPath"]


@dataclass(frozen=True)
class MotionFinding:
    path: str
    line: int
    source: str


def scan_ui(ui_root: Path = UI_ROOT) -> list[MotionFinding]:
    findings: list[MotionFinding] = []
    for path in sorted(ui_root.rglob("*.kt")):
        for line_number, raw_line in enumerate(
            path.read_text(encoding="utf-8").splitlines(),
            1,
        ):
            source = raw_line.strip()
            if source and any(pattern.search(source) for pattern in TIME_MOTION_PATTERNS):
                findings.append(
                    MotionFinding(
                        path=path.relative_to(ui_root).as_posix(),
                        line=line_number,
                        source=source,
                    )
                )
    return findings


def validate_findings(
    findings: list[MotionFinding],
    policy: dict[str, Any] | None = None,
) -> list[str]:
    resolved_policy = _motion_policy() if policy is None else policy
    allowed_sources = set(resolved_policy["allowedSources"])
    allowed_path = resolved_policy["allowedPath"]
    animation_gate = resolved_policy["systemAnimationGate"]
    errors: list[str] = []
    actual_sources: set[str] = set()
    for finding in findings:
        if finding.path != allowed_path or finding.source not in allowed_sources:
            errors.append(
                f"未经审计的显式时间动效：{finding.path}:{finding.line}: {finding.source}"
            )
        elif finding.source in actual_sources:
            errors.append(
                f"允许的动效源码重复出现：{finding.path}:{finding.line}: {finding.source}"
            )
        else:
            actual_sources.add(finding.source)

    missing = allowed_sources - actual_sources
    for source in sorted(missing):
        errors.append(f"预测返回动效审计基线缺失：{source}")

    gate_sources = {source for source in allowed_sources if animation_gate in source}
    if not gate_sources.issubset(actual_sources):
        errors.append("预测返回进度与取消回弹必须同时遵守系统动画开关")
    return errors


def main() -> int:
    errors = validate_findings(scan_ui())
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("Android 显式时间动效审计通过：仅保留遵守系统动画开关的预测返回动效。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
