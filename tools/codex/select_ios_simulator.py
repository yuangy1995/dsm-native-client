#!/usr/bin/env python3
"""为目标设备族选择实际安装的 iOS 模拟器，缺失时失败而不是伪造验收。"""
import argparse
import json
import re
import subprocess


def select_device(payload: dict, family: str, major: int) -> str:
    matches = []
    for runtime, devices in payload.get("devices", {}).items():
        version = re.search(r"\.iOS-(\d+)(?:-(\d+))?", runtime)
        if not version or int(version.group(1)) != major:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith(family):
                matches.append((int(version.group(2) or 0), device["name"], device["udid"]))
    if not matches:
        raise RuntimeError(f"没有可用的 iOS {major} {family} 模拟器")
    return sorted(matches, reverse=True)[0][2]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=("iPhone", "iPad"), required=True)
    parser.add_argument("--major", type=int, default=27)
    args = parser.parse_args()
    result = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                            check=True, capture_output=True, text=True)
    print(select_device(json.loads(result.stdout), args.family, args.major))


if __name__ == "__main__":
    main()
