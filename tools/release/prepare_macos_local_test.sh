#!/bin/bash
# 仅加工新生成的隔离测试包，不修改正式版资源与用户资料。
set -euo pipefail
[[ $# -eq 1 ]] || exit 2
app_path="$1"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist="$app_path/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == io.github.qwertyuiop1995.dsmnativeclient.macos.localtest ]] || exit 1
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName LanStash Test' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName LanStash Test' "$plist"
for locale in en zh-Hans; do
    /usr/bin/ditto "$repo_root/apple/Apps/DsmMac/SupportingFiles/LocalTest/$locale.lproj/InfoPlist.strings" \
        "$app_path/Contents/Resources/$locale.lproj/InfoPlist.strings"
done
