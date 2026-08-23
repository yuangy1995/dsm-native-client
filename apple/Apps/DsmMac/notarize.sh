#!/bin/bash

# 提交已使用 Developer ID 签名的 DMG，等待公证并装订票据。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VERIFY_SCRIPT="$REPO_ROOT/tools/release/verify_macos_distribution.sh"

if [[ $# -ne 1 ]]; then
    echo "用法：设置 LANSTASH_NOTARY_PROFILE 或完整 API Key 环境变量后，运行 $0 /path/to/LanStash.dmg" >&2
    exit 2
fi

DMG_PATH="$1"
NOTARY_PROFILE="${LANSTASH_NOTARY_PROFILE:-}"
NOTARY_API_KEY_PATH="${LANSTASH_NOTARY_API_KEY_PATH:-}"
NOTARY_API_KEY_ID="${LANSTASH_NOTARY_API_KEY_ID:-}"
NOTARY_API_ISSUER_ID="${LANSTASH_NOTARY_API_ISSUER_ID:-}"
NOTARY_AUTH_ARGUMENTS=()

fail() {
    echo "错误：$*" >&2
    exit 1
}

if [[ -n "$NOTARY_API_KEY_PATH" \
    || -n "$NOTARY_API_KEY_ID" \
    || -n "$NOTARY_API_ISSUER_ID" ]]; then
    [[ -f "$NOTARY_API_KEY_PATH" ]] \
        || fail "LANSTASH_NOTARY_API_KEY_PATH 指向的 API 私钥不存在"
    [[ -n "$NOTARY_API_KEY_ID" && -n "$NOTARY_API_ISSUER_ID" ]] \
        || fail "API Key 公证必须同时设置 Key ID 与 Issuer ID"
    NOTARY_AUTH_ARGUMENTS=(
        --key "$NOTARY_API_KEY_PATH"
        --key-id "$NOTARY_API_KEY_ID"
        --issuer "$NOTARY_API_ISSUER_ID"
    )
else
    [[ -n "$NOTARY_PROFILE" ]] \
        || fail "请设置 LANSTASH_NOTARY_PROFILE，或提供完整 API Key 公证环境变量"
    NOTARY_AUTH_ARGUMENTS=(--keychain-profile "$NOTARY_PROFILE")
fi
[[ -f "$DMG_PATH" ]] || fail "找不到 DMG：$DMG_PATH"
[[ -x "$VERIFY_SCRIPT" ]] || fail "找不到正式分发校验脚本"
command -v xcrun >/dev/null 2>&1 || fail "未找到 xcrun，请安装完整 Xcode"

SIGNING_DESCRIPTION="$(
    /usr/bin/codesign -dv --verbose=4 "$DMG_PATH" 2>&1
)"
[[ "$SIGNING_DESCRIPTION" == *"Authority=Developer ID Application:"* ]] \
    || fail "DMG 必须先使用 Developer ID Application 证书签名"

echo "==> 提交 Apple 公证服务并等待结果"
/usr/bin/xcrun notarytool submit \
    "$DMG_PATH" \
    "${NOTARY_AUTH_ARGUMENTS[@]}" \
    --wait

echo "==> 装订并验证公证票据"
/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"

APP_PATH="$SCRIPT_DIR/dist/LanStash.app"
[[ -d "$APP_PATH" ]] \
    || fail "找不到与 DMG 同批生成的 App：$APP_PATH"
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
"$VERIFY_SCRIPT" "$APP_PATH" "$DMG_PATH" "$SOURCE_COMMIT"
