#!/bin/bash

# 校验日常 CI 产生的临时签名包；它不是正式分发批准，正式包必须通过 verify_macos_distribution.sh。

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "用法：$0 /path/to/LanStash.app /path/to/LanStash.dmg <source-commit>" >&2
    exit 2
fi

APP_PATH="$1"
DMG_PATH="$2"
SOURCE_COMMIT="$3"
FILE_PROVIDER_PATH="$APP_PATH/Contents/PlugIns/LanStashFileProvider.appex"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
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

for command in codesign diff hdiutil mktemp; do
    command -v "$command" >/dev/null 2>&1 \
        || fail "缺少系统命令：$command"
done

[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || fail "来源提交必须是完整 SHA-1"
[[ -d "$APP_PATH" ]] || fail "找不到 App：$APP_PATH"
[[ -f "$DMG_PATH" ]] || fail "找不到 DMG：$DMG_PATH"
[[ -x "$PLIST_BUDDY" ]] || fail "找不到 PlistBuddy"
[[ -x "$APP_PATH/Contents/MacOS/LanStash" ]] \
    || fail "App 主程序不存在"
[[ ! -e "$FILE_PROVIDER_PATH" ]] \
    || fail "临时签名 CI 包不应包含需要正式签名的 File Provider 扩展"

ACTUAL_COMMIT="$("$PLIST_BUDDY" -c 'Print :LanStashSourceCommit' "$APP_PATH/Contents/Info.plist")"
[[ "$ACTUAL_COMMIT" == "$SOURCE_COMMIT" ]] \
    || fail "App 记录的来源提交与当前构建提交不一致"

echo "==> 校验临时签名 App 与 DMG"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/lanstash-ci-verify.XXXXXX")"
/usr/bin/hdiutil attach \
    "$DMG_PATH" \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_POINT" >/dev/null
ATTACHED=1
MOUNTED_APP_PATH="$MOUNT_POINT/$(/usr/bin/basename "$APP_PATH")"
[[ -d "$MOUNTED_APP_PATH" ]] \
    || fail "DMG 中缺少与待校验 App 同名的应用包"
[[ ! -e "$MOUNTED_APP_PATH/Contents/PlugIns/LanStashFileProvider.appex" ]] \
    || fail "DMG 内的临时签名 App 不应包含 File Provider 扩展"
/usr/bin/diff -qr "$APP_PATH" "$MOUNTED_APP_PATH" >/dev/null \
    || fail "DMG 内 App 与待校验 App 不完全一致"
echo "临时签名 CI 产物校验通过；不得据此替代正式签名、公证或 Finder 验收。"
