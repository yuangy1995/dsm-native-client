#!/usr/bin/env python3
"""校验 Android 长期计划保留结构债务与验证入口，而不重新维护动态进度。"""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md"
REQUIRED_SECTIONS = (
    "## 不变量",
    "## 质量基线",
    "## 源码拆分顺序",
    "## 验证策略",
    "## 发布与真实环境",
    "## 交接要求",
)
LEGACY_PROGRESS_PATTERN = re.compile(r"(?:完成度|当前完成率|\b\d+\s*/\s*\d+\b|\b\d+(?:\.\d+)?%)")


def validate(path: Path = PLAN) -> list[str]:
    if not path.is_file():
        return ["Android 长期计划不存在"]
    text = path.read_text(encoding="utf-8")
    errors = [f"Android 长期计划缺少章节：{section}" for section in REQUIRED_SECTIONS if section not in text]
    if LEGACY_PROGRESS_PATTERN.search(text):
        errors.append("Android 长期计划不得维护动态完成率、百分比或人工测试数量")
    return errors


def main() -> int:
    errors = validate()
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("Android 长期计划结构通过：范围、质量基线、拆分、验证和交接边界均已声明。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
