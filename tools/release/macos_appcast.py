#!/usr/bin/env python3
"""从已签名应用生成 macOS 专用更新源；拒绝版本回退、错误标签和未启用的候选包。"""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from html import escape
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

REPOSITORY = "yuangy1995/dsm-native-client"
BASE_URL = f"https://github.com/{REPOSITORY}"
FEED_URL = f"{BASE_URL}/releases/download/macos-updates/appcast.xml"
VALIDATION_FEED_URL = f"{BASE_URL}/releases/download/macos-validation-updates/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("版本号必须使用一至三段数字")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def create_feed(packages: dict[str, tuple[dict, Path, str]], tag: str,
                previous: Path | None = None, validation: bool = False,
                release_notes: str | None = None) -> bytes:
    if set(packages) != {"arm64", "x86_64"}:
        raise ValueError("发布必须同时提供 Apple Silicon 与 Intel 安装包")
    info = packages["arm64"][0]
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    prefix = "macos-validation/v" if validation else "macos/v"
    expected_feed = VALIDATION_FEED_URL if validation else FEED_URL
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or tag != f"{prefix}{version}":
        raise ValueError("发布标签与 macOS 应用版本不一致")
    version_tuple(build)
    if info.get("LanStashOnlineUpdatesEnabled") is not True or info.get("SUFeedURL") != expected_feed:
        raise ValueError("候选包未启用正确的 macOS 更新源")
    if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
        raise ValueError("候选包更新公钥无效")
    identity_keys = ("CFBundleShortVersionString", "CFBundleVersion", "CFBundleIdentifier",
                     "LSMinimumSystemVersion", "LanStashOnlineUpdatesEnabled", "SUFeedURL",
                     "SUPublicEDKey", "LanStashSourceCommit")
    for arch, (package_info, archive, signature) in packages.items():
        if any(package_info.get(key) != info.get(key) for key in identity_keys):
            raise ValueError("两种架构的版本、身份、来源和更新配置必须一致")
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("更新签名无效")
        if archive.name != f"LanStash-{version}-{arch}.dmg" or archive.stat().st_size == 0:
            raise ValueError("安装包版本或架构标识不匹配")
    if previous is not None:
        items = ET.parse(previous).findall("./channel/item")
        if not items:
            raise ValueError("已有更新源缺少版本记录，不可覆盖")
        for item in items:
            old_build = item.findtext(f"{{{SPARKLE}}}version")
            old_version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
            if not old_build or not old_version:
                raise ValueError("已有更新源版本不完整")
            if version_tuple(build) <= version_tuple(old_build) or version_tuple(version) <= version_tuple(old_version):
                raise ValueError("版本号和构建号都必须高于已发布的 macOS 版本")

    description = None
    if release_notes is not None:
        if not release_notes.strip():
            raise ValueError("发布说明不能为空")
        # 仅转换项目发布说明使用的标题和列表，所有正文转义，不引入网页或图片。
        lines = []
        for raw_line in release_notes.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            heading = re.match(r"^#{1,6}\s+(.+)$", line)
            if heading:
                lines.append(f"<h2>{escape(heading.group(1))}</h2>")
            else:
                line = re.sub(r"^[-*]\s+", "• ", line)
                lines.append(f"<p>{escape(line)}</p>")
        description = "\n".join(lines)

    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "LanStash macOS"
    ET.SubElement(channel, "link").text = f"{BASE_URL}/releases"
    # Sparkle 2.9.6 同版本取首个匹配项；Intel 排除 arm64 要求，Rosetta 按实际硬件匹配。
    for arch, label in [("arm64", "Apple Silicon"), ("x86_64", "Intel")]:
        _, archive, signature = packages[arch]
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = f"LanStash {version} — {label}"
        ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
        if description is not None:
            ET.SubElement(item, "description").text = description
        ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
        ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
        ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
        if arch == "arm64":
            ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
        ET.SubElement(item, "enclosure", {
            "url": f"{BASE_URL}/releases/download/{tag}/{archive.name}",
            "length": str(archive.stat().st_size),
            "type": "application/octet-stream",
            f"{{{SPARKLE}}}edSignature": signature,
            f"{{{SPARKLE}}}os": "macos",
        })
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, action="append")
    parser.add_argument("--archive", required=True, type=Path, action="append")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--signature", required=True, action="append")
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--validation", action="store_true")
    parser.add_argument("--release-notes", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not len(args.app) == len(args.archive) == len(args.signature) == 2:
        parser.error("按 arm64、x86_64 顺序分别提供两组 app、archive 和 signature")
    packages = {}
    for arch, app, archive, signature in zip(("arm64", "x86_64"), args.app, args.archive, args.signature):
        with (app / "Contents/Info.plist").open("rb") as source:
            packages[arch] = (plistlib.load(source), archive, signature)
    notes = args.release_notes.read_text(encoding="utf-8") if args.release_notes else None
    args.output.write_bytes(create_feed(packages, args.tag, args.previous, args.validation, notes))


if __name__ == "__main__":
    main()
