#!/bin/bash

# 校验正式 macOS App 与 DMG 的签名、公证票据、扩展和权限。

set -euo pipefail

if [[ $# -ne 2 && $# -ne 3 ]]; then
    echo "用法：$0 /path/to/LanStash.app /path/to/LanStash.dmg [source-commit]" >&2
    exit 2
fi

APP_PATH="$1"
DMG_PATH="$2"
SOURCE_COMMIT="${3:-}"
FILE_PROVIDER_PATH="$APP_PATH/Contents/PlugIns/LanStashFileProvider.appex"
APP_PROFILE_PATH="$APP_PATH/Contents/embedded.provisionprofile"
FILE_PROVIDER_PROFILE_PATH="$FILE_PROVIDER_PATH/Contents/embedded.provisionprofile"
MOUNT_POINT=""
ATTACHED=0

fail() {
    echo "错误：$*" >&2
    exit 1
}

cleanup() {
    if [[ "$ATTACHED" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
    fi
    if [[ -n "$MOUNT_POINT" ]]; then
        /bin/rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

for command in codesign diff hdiutil mktemp security shasum spctl xcrun; do
    command -v "$command" >/dev/null 2>&1 \
        || fail "缺少系统命令：$command"
done

[[ -d "$APP_PATH" ]] || fail "找不到 App：$APP_PATH"
[[ -f "$DMG_PATH" ]] || fail "找不到 DMG：$DMG_PATH"
[[ -d "$FILE_PROVIDER_PATH" ]] \
    || fail "正式分发包缺少 File Provider 扩展"
[[ -f "$APP_PROFILE_PATH" ]] \
    || fail "正式分发包缺少主 App Developer ID provisioning profile"
[[ -f "$FILE_PROVIDER_PROFILE_PATH" ]] \
    || fail "正式分发包缺少 File Provider Developer ID provisioning profile"
/usr/bin/security cms -D -i "$APP_PROFILE_PATH" >/dev/null \
    || fail "主 App Developer ID provisioning profile 无效"
/usr/bin/security cms -D -i "$FILE_PROVIDER_PROFILE_PATH" >/dev/null \
    || fail "File Provider Developer ID provisioning profile 无效"
if [[ -n "$SOURCE_COMMIT" ]]; then
    [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
        || fail "来源提交必须是完整 SHA-1"
    PLIST_BUDDY="/usr/libexec/PlistBuddy"
    [[ -x "$PLIST_BUDDY" ]] || fail "找不到 PlistBuddy"
    ACTUAL_COMMIT="$("$PLIST_BUDDY" -c 'Print :LanStashSourceCommit' "$APP_PATH/Contents/Info.plist")"
    [[ "$ACTUAL_COMMIT" == "$SOURCE_COMMIT" ]] \
        || fail "App 记录的来源提交与待发布提交不一致"
fi

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/lanstash-release-verify.XXXXXX")"
/usr/bin/hdiutil attach \
    "$DMG_PATH" \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_POINT" >/dev/null
ATTACHED=1
MOUNTED_APP_PATH="$MOUNT_POINT/$(/usr/bin/basename "$APP_PATH")"
[[ -d "$MOUNTED_APP_PATH" ]] \
    || fail "DMG 中缺少与待发布 App 同名的应用包"
/usr/bin/diff -qr "$APP_PATH" "$MOUNTED_APP_PATH" >/dev/null \
    || fail "DMG 内 App 与待发布 App 不完全一致"

echo "==> 校验 App 与扩展签名"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$FILE_PROVIDER_PATH"

APP_SIGNING="$(
    /usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1
)"
EXTENSION_SIGNING="$(
    /usr/bin/codesign -dv --verbose=4 "$FILE_PROVIDER_PATH" 2>&1
)"
[[ "$APP_SIGNING" == *"Authority=Developer ID Application:"* ]] \
    || fail "App 不是 Developer ID Application 正式签名"
[[ "$EXTENSION_SIGNING" == *"Authority=Developer ID Application:"* ]] \
    || fail "File Provider 扩展不是 Developer ID Application 正式签名"

echo "==> 校验 App 与扩展权限"
APP_ENTITLEMENTS="$(
    /usr/bin/codesign -d --entitlements - "$APP_PATH" 2>/dev/null
)"
EXTENSION_ENTITLEMENTS="$(
    /usr/bin/codesign -d --entitlements - "$FILE_PROVIDER_PATH" 2>/dev/null
)"
for entitlement in \
    "com.apple.security.application-groups" \
    "keychain-access-groups"; do
    [[ "$APP_ENTITLEMENTS" == *"$entitlement"* ]] \
        || fail "App 缺少权限：$entitlement"
    [[ "$EXTENSION_ENTITLEMENTS" == *"$entitlement"* ]] \
        || fail "File Provider 扩展缺少权限：$entitlement"
done
[[ "$APP_ENTITLEMENTS" != *'$(AppIdentifierPrefix)'* ]] \
    || fail "App 权限仍包含未展开的签名变量"
[[ "$EXTENSION_ENTITLEMENTS" != *'$(AppIdentifierPrefix)'* ]] \
    || fail "File Provider 权限仍包含未展开的签名变量"

echo "==> 校验 Gatekeeper 与 DMG"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
/usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"

echo "==> 安装包 SHA-256"
/usr/bin/shasum -a 256 "$DMG_PATH"
echo "正式 macOS 分发包校验通过。"
