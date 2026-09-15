#!/usr/bin/env python3
"""为 Windows x:Uid 生成实时语言切换绑定；不改变资源键和业务状态。"""
import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "windows/src/LanStash.App"
NAMESPACE = 'xmlns:desktop="using:LanStash.App.Presentation"'
ATTRIBUTE = "desktop:DesktopLocalization.Bindings"


def generated(source, resources):
    source = re.sub(r"\s+" + re.escape(ATTRIBUTE) + r'="[^"]*"', "", source)
    if 'x:Uid="' not in source:
        return source
    if NAMESPACE not in source:
        source = source.replace('xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"',
                                'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"\n    ' + NAMESPACE, 1)
    def attach(match):
        uid = match.group(1)
        properties = []
        for key in sorted(resources):
            if key.startswith(uid + "."):
                property_name = re.sub(r"^\[[^]]+\]", "", key[len(uid) + 1:])
                properties.append(property_name + "=" + key)
        return match.group(0) + (" " + ATTRIBUTE + '="' + ";".join(properties) + '"' if properties else "")
    return re.sub(r'x:Uid="([^"]+)"', attach, source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    resources = {data.attrib["name"] for data in ET.parse(APP / "Strings/en-US/Resources.resw").getroot().findall("data")}
    changed = []
    for path in sorted((APP / "Views").rglob("*.xaml")):
        # 未参与正式导航的 File Station 历史照片视图不扩展功能。
        if path.name.startswith(("PhotosPage", "PhotoTimelineView", "WorkspacePage", "LanguageSettingsPage")):
            continue
        before = path.read_text(encoding="utf-8")
        after = generated(before, resources)
        if before != after:
            changed.append(str(path.relative_to(ROOT)))
            if not args.check:
                path.write_text(after, encoding="utf-8")
    if args.check and changed:
        print("Windows live localization bindings are stale:\n" + "\n".join(changed), file=sys.stderr)
        return 1
    print("Windows live localization bindings: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
