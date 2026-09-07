#!/bin/bash
# 验证升级组件与主应用使用相同的正式签名，保留主应用沙盒边界。
set -euo pipefail
[[ $# -eq 1 ]] || { echo "用法：bash $0 /path/to/LanStash.app" >&2; exit 2; }
app_path="$1"
plist="$app_path/Contents/Info.plist"
buddy=/usr/libexec/PlistBuddy
framework="$app_path/Contents/Frameworks/Sparkle.framework"
app_signing="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
team="$(printf '%s\n' "$app_signing" | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || exit 1
bundle_id="$("$buddy" -c 'Print :CFBundleIdentifier' "$plist")"
entitlements="$(codesign -d --entitlements - "$app_path" 2>/dev/null)"
[[ "$entitlements" == *"$bundle_id-spks"* && "$entitlements" == *"$bundle_id-spki"* ]] || exit 1
[[ "$entitlements" != *'$('* ]] || exit 1
[[ "$("$buddy" -c 'Print :SUEnableInstallerLauncherService' "$plist")" == true ]] || exit 1
[[ "$("$buddy" -c 'Print :SUAllowsAutomaticUpdates' "$plist")" == false ]] || exit 1
[[ "$("$buddy" -c 'Print :SUVerifyUpdateBeforeExtraction' "$plist")" == true ]] || exit 1
[[ "$("$buddy" -c 'Print :SURequireSignedFeed' "$plist")" == true ]] || exit 1
for component in \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/Autoupdate" \
    "$framework/Versions/B/Updater.app" \
    "$framework"; do
    codesign --verify --strict "$component"
    signing="$(codesign -dv --verbose=4 "$component" 2>&1)"
    [[ "$signing" == *"Authority=Developer ID Application:"* ]] || exit 1
    [[ "$signing" == *"TeamIdentifier=$team"* ]] || exit 1
    [[ "$signing" == *"runtime"* ]] || exit 1
done
for executable in \
    "$framework/Versions/B/Sparkle" \
    "$framework/Versions/B/Autoupdate" \
    "$framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
    "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    for arch in $(lipo -archs "$app_path/Contents/MacOS/LanStash"); do
        lipo "$executable" -verify_arch "$arch"
    done
done
echo "升级组件签名、权限和架构校验通过。"
