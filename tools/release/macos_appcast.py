#!/usr/bin/env python3
"""从已签名应用生成 macOS 专用更新源；拒绝版本回退、错误标签和未启用的候选包。"""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
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


def create_feed(info: dict, archive: Path, tag: str, signature: str,
                previous: Path | None = None, validation: bool = False) -> bytes:
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
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("更新签名无效")
    if archive.name != f"LanStash-{version}-universal.dmg" or archive.stat().st_size == 0:
        raise ValueError("正式发布须提供对应版本的通用 DMG")
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

    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "LanStash macOS"
    ET.SubElement(channel, "link").text = f"{BASE_URL}/releases"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"LanStash {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
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
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--validation", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    with (args.app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    args.output.write_bytes(create_feed(info, args.archive, args.tag, args.signature, args.previous, args.validation))


if __name__ == "__main__":
    main()
