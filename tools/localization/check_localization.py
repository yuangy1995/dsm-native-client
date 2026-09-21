#!/usr/bin/env python3
"""检查五端本地化资源完整性、参数一致性和可见文案硬编码。"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
APPLE_FORMAT = re.compile(r"%(?:\d+\$)?[@dfiusxX%]")
ANDROID_FORMAT = re.compile(r"%(?:\d+\$)?[a-zA-Z%]")
DOTNET_FORMAT = re.compile(r"\{\d+(?::[^}]*)?\}")
SWIFT_STRING = re.compile(r'"(?:\\.|[^"\\\n])*[\u3400-\u4dbf\u4e00-\u9fff](?:\\.|[^"\\\n])*"')
JVM_STRING = SWIFT_STRING
CS_STRING = SWIFT_STRING


class Validation:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def finish(self) -> None:
        if self.errors:
            print("本地化检查失败：", file=sys.stderr)
            for error in self.errors:
                print(f"- {error}", file=sys.stderr)
            raise SystemExit(1)
        print("本地化检查通过：双语资源、参数、资源引用和硬编码扫描均无问题。")


def read_apple_strings(path: Path, validation: Validation) -> dict[str, str]:
    result: dict[str, str] = {}
    line_pattern = re.compile(r'^"([^"]+)"\s*=\s*"((?:\\.|[^"])*)";$')
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith(("/*", "*", "//")):
            continue
        match = line_pattern.fullmatch(line)
        validation.require(match is not None, f"{path.relative_to(ROOT)}:{number} 不是有效的 .strings 条目")
        if match is None:
            continue
        key, value = match.groups()
        validation.require(key not in result, f"{path.relative_to(ROOT)} 存在重复键 {key}")
        result[key] = value
    return result


def read_android_resources(path: Path, validation: Validation) -> dict[str, str]:
    root = ET.parse(path).getroot()
    result: dict[str, str] = {}
    for node in root:
        name = node.attrib.get("name")
        if not name or node.attrib.get("translatable") == "false":
            continue
        if node.tag == "string":
            value = "".join(node.itertext())
        elif node.tag in {"plurals", "string-array"}:
            value = "\u241e".join("".join(item.itertext()) for item in node.findall("item"))
        else:
            continue
        validation.require(name not in result, f"{path.relative_to(ROOT)} 存在重复键 {name}")
        result[name] = value
    return result


def read_windows_resources(path: Path, validation: Validation) -> dict[str, str]:
    root = ET.parse(path).getroot()
    result: dict[str, str] = {}
    for node in root.findall("data"):
        name = node.attrib["name"]
        value = node.findtext("value", default="")
        validation.require(name not in result, f"{path.relative_to(ROOT)} 存在重复键 {name}")
        result[name] = value
    return result


def compare_resources(
    label: str,
    english: dict[str, str],
    chinese: dict[str, str],
    placeholder_pattern: re.Pattern[str],
    validation: Validation,
    *,
    compare_unique_placeholders: bool = False,
) -> None:
    missing_chinese = sorted(english.keys() - chinese.keys())
    missing_english = sorted(chinese.keys() - english.keys())
    validation.require(not missing_chinese, f"{label} 缺少简体中文：{', '.join(missing_chinese)}")
    validation.require(not missing_english, f"{label} 缺少英语：{', '.join(missing_english)}")
    for key in english.keys() & chinese.keys():
        en_parameters = sorted(placeholder_pattern.findall(english[key]))
        zh_parameters = sorted(placeholder_pattern.findall(chinese[key]))
        if compare_unique_placeholders:
            en_parameters = sorted(set(en_parameters))
            zh_parameters = sorted(set(zh_parameters))
        validation.require(
            en_parameters == zh_parameters,
            f"{label} 的 {key} 参数不一致：en={en_parameters}, zh-Hans={zh_parameters}",
        )


def scan_han_literals(
    paths: list[Path],
    suffixes: set[str],
    pattern: re.Pattern[str],
    validation: Validation,
) -> None:
    for base in paths:
        for path in base.rglob("*"):
            if path.suffix not in suffixes or any(part in {".build", "build", "obj", "bin"} for part in path.parts):
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if pattern.search(line):
                    validation.errors.append(
                        f"{path.relative_to(ROOT)}:{number} 存在中文字符串硬编码"
                    )


def scan_visible_literal_calls(validation: Validation) -> None:
    swift_call = re.compile(
        r"\b(?:Text|Button|Label|Toggle|Picker|navigationTitle|help|"
        r"accessibilityLabel|accessibilityHint|alert|confirmationDialog)\(\s*\"([^\"]*)\""
    )
    for base in [ROOT / "apple/Apps/DsmMac/Sources", ROOT / "apple/Apps/DsmMobile/Sources"]:
        for path in base.rglob("*.swift"):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                match = swift_call.search(line)
                if not match:
                    continue
                value = match.group(1)
                if not value or "\\(" in value or re.fullmatch(r"[\s·()—]+", value):
                    continue
                validation.errors.append(
                    f"{path.relative_to(ROOT)}:{number} 存在未资源化的 Apple 可见文案：{value}"
                )

    android_call = re.compile(r'\bText\(\s*"([^"]*)"|contentDescription\s*=\s*"([^"]*)"')
    for path in (ROOT / "android/app/src/main").rglob("*.kt"):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = android_call.search(line)
            if not match:
                continue
            value = next(group for group in match.groups() if group is not None)
            if not value or "${" in value:
                continue
            validation.errors.append(
                f"{path.relative_to(ROOT)}:{number} 存在未资源化的 Android 可见文案：{value}"
            )

    xaml_attribute = re.compile(
        r'(?:Text|Content|Header|Label|PlaceholderText|Title|AutomationProperties\.Name)="([^"{][^"]*)"'
    )
    for path in (ROOT / "windows/src/LanStash.App").rglob("*.xaml"):
        if not path.is_file() or any(part in {"bin", "obj"} for part in path.parts):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = xaml_attribute.search(line)
            if match:
                validation.errors.append(
                    f"{path.relative_to(ROOT)}:{number} 存在未资源化的 Windows 可见文案：{match.group(1)}"
                )


def scan_apple_app_locale_bypasses(validation: Validation) -> None:
    pattern = re.compile(
        r"\.locale\s*=\s*(?:(?:Locale\.)?(?:current|autoupdatingCurrent))"
        r'|Locale\s*\(\s*identifier:\s*"zh(?:[_-]|")'
    )
    for base in [ROOT / "apple/Apps/DsmMac/Sources", ROOT / "apple/Apps/DsmMobile/Sources"]:
        for path in base.rglob("*.swift"):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if pattern.search(line):
                    validation.errors.append(
                        f"{path.relative_to(ROOT)}:{number} 的用户界面格式化绕过了 App 当前语言"
                    )


def validate_references(
    paths: list[Path],
    suffix: str,
    pattern: re.Pattern[str],
    keys: set[str],
    label: str,
    validation: Validation,
) -> None:
    for base in paths:
        for path in base.rglob(f"*{suffix}"):
            if not path.is_file() or any(part in {".build", "build", "bin", "obj"} for part in path.parts):
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                for key in pattern.findall(line):
                    validation.require(
                        key in keys,
                        f"{path.relative_to(ROOT)}:{number} 引用了不存在的 {label} 资源 {key}",
                    )


def validate_windows_xuid_references(keys: set[str], validation: Validation) -> None:
    uid_attribute = "{http://schemas.microsoft.com/winfx/2006/xaml}Uid"
    for path in (ROOT / "windows/src/LanStash.App").rglob("*.xaml"):
        if not path.is_file() or any(part in {"bin", "obj"} for part in path.parts):
            continue
        for node in ET.parse(path).getroot().iter():
            uid = node.attrib.get(uid_attribute)
            if uid:
                validation.require(
                    any(key.startswith(f"{uid}.") for key in keys),
                    f"{path.relative_to(ROOT)} 的 x:Uid={uid} 没有对应 Windows 资源",
                )


def main() -> None:
    validation = Validation()

    contract = json.loads(
        (ROOT / "contracts/localization/supported-locales.json").read_text(encoding="utf-8")
    )
    validation.require(contract["fallbackLocale"] == "en", "语言契约的回退语言必须是 en")
    validation.require(
        [locale["id"] for locale in contract["locales"]] == ["en", "zh-Hans"],
        "初期语言契约必须且只能包含 en、zh-Hans",
    )

    apple_root = ROOT / "apple/Packages/DsmLocalization/Sources/Resources"
    apple_en = read_apple_strings(apple_root / "en.lproj/Localizable.strings", validation)
    apple_zh = read_apple_strings(apple_root / "zh-Hans.lproj/Localizable.strings", validation)
    compare_resources("Apple", apple_en, apple_zh, APPLE_FORMAT, validation)
    for key, value in apple_en.items():
        validation.require(
            not HAN.search(value) or key == "language.simplified_chinese",
            f"Apple 英语资源 {key} 仍包含中文",
        )

    android_en = read_android_resources(
        ROOT / "android/app/src/main/res/values/strings.xml", validation
    )
    android_zh = read_android_resources(
        ROOT / "android/app/src/main/res/values-zh-rCN/strings.xml", validation
    )
    compare_resources(
        "Android",
        android_en,
        android_zh,
        ANDROID_FORMAT,
        validation,
        compare_unique_placeholders=True,
    )

    windows_en = read_windows_resources(
        ROOT / "windows/src/LanStash.App/Strings/en-US/Resources.resw", validation
    )
    windows_zh = read_windows_resources(
        ROOT / "windows/src/LanStash.App/Strings/zh-CN/Resources.resw", validation
    )
    compare_resources("Windows", windows_en, windows_zh, DOTNET_FORMAT, validation)

    scan_han_literals(
        [
            ROOT / "apple/Apps/DsmMac/Sources",
            ROOT / "apple/Apps/DsmMobile/Sources",
            ROOT / "apple/Packages/DsmCore/Sources",
            ROOT / "apple/Packages/DsmNetwork/Sources",
        ],
        {".swift"},
        SWIFT_STRING,
        validation,
    )
    scan_han_literals(
        [ROOT / "android/app/src/main/java"],
        {".kt", ".java"},
        JVM_STRING,
        validation,
    )
    scan_han_literals(
        [ROOT / "windows/src"],
        {".cs", ".xaml"},
        CS_STRING,
        validation,
    )
    scan_visible_literal_calls(validation)
    scan_apple_app_locale_bypasses(validation)

    validate_references(
        [
            ROOT / "apple/Apps/DsmMac/Sources",
            ROOT / "apple/Apps/DsmMobile/Sources",
            ROOT / "apple/Packages/DsmCore/Sources",
            ROOT / "apple/Packages/DsmNetwork/Sources",
        ],
        ".swift",
        re.compile(r'L10n\.string\("([^"]+)"'),
        set(apple_en),
        "Apple",
        validation,
    )
    validate_references(
        [ROOT / "android/app/src/main/java"],
        ".kt",
        re.compile(r"R\.string\.([A-Za-z0-9_]+)"),
        set(android_en),
        "Android",
        validation,
    )
    validate_references(
        [ROOT / "windows/src"],
        ".cs",
        re.compile(r'(?:Get|Format|UserText\.Key)\("([^"]+)"'),
        set(windows_en),
        "Windows",
        validation,
    )
    validate_windows_xuid_references(set(windows_en), validation)

    print(
        f"资源统计：Apple {len(apple_en)}，Android {len(android_en)}，Windows {len(windows_en)}。"
    )
    validation.finish()


if __name__ == "__main__":
    main()
