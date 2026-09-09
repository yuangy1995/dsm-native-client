#!/bin/bash
# 验证临时包的权限边界，并用相同签名选项实测包内 Sparkle 加载。
set -euo pipefail
[[ $# -eq 1 ]] || { echo "用法：$0 /path/to/LocalTest.app" >&2; exit 2; }
app_path="$1"
script_dir="$(cd "$(dirname "$0")" && pwd)"
[[ -d "$app_path" ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" == io.github.qwertyuiop1995.dsmnativeclient.macos.localtest ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LanStashAppGroupIdentifier' "$app_path/Contents/Info.plist")" == group.io.github.qwertyuiop1995.dsmnativeclient.localtest ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LanStashSharedKeychainAccessGroup' "$app_path/Contents/Info.plist")" == io.github.qwertyuiop1995.dsmnativeclient.localtest.shared ]] || exit 1
signing="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)"
[[ "$signing" == *"Signature=adhoc"* && "$signing" == *"runtime"* ]] || exit 1
[[ ! -e "$app_path/Contents/PlugIns/LanStashFileProvider.appex" ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LanStashOnlineUpdatesEnabled' "$app_path/Contents/Info.plist")" == false ]] || exit 1
/usr/bin/codesign --verify --deep --strict "$app_path"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/lanstash-local-loader.XXXXXX")"
trap 'rm -r -- "$probe_dir"' EXIT
/usr/bin/codesign -d --entitlements - --xml "$app_path" > "$probe_dir/entitlements.plist" 2>/dev/null
python3 -c 'import plistlib,sys; assert plistlib.load(sys.stdin.buffer) == {"com.apple.security.cs.disable-library-validation": True}, "临时包权限超出单一库验证例外"' < "$probe_dir/entitlements.plist"
xcrun clang "$script_dir/fixtures/macos_library_load_probe.c" -o "$probe_dir/loader"
/usr/bin/codesign --force --options runtime --timestamp=none \
    --entitlements "$probe_dir/entitlements.plist" --sign - "$probe_dir/loader"
"$probe_dir/loader" "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
echo "本地临时包权限与 Sparkle 实际加载检查通过。"
