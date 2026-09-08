#!/bin/bash
# 只用于本机临时测试包：保留 Hardened Runtime，仅主 App 放宽库验证。
set -euo pipefail
[[ $# -eq 1 ]] || { echo "用法：$0 /path/to/LocalTest.app" >&2; exit 2; }
app_path="$1"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
entitlements="$repo_root/apple/Apps/DsmMac/SupportingFiles/DsmMacLocalTest.entitlements"
[[ -d "$app_path/Contents/MacOS" && -f "$entitlements" ]] || exit 1

# 不把主 App 的例外传播到框架与辅助进程。
/usr/bin/codesign --force --deep --options runtime --timestamp=none --sign - "$app_path"
/usr/bin/codesign --force --options runtime --timestamp=none \
    --entitlements "$entitlements" --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
