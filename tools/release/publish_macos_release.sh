#!/bin/bash
# 仅在正式签名、公证、回归与人工升级验收通过后发布；私钥只通过标准输入传递。
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
[[ "${GITHUB_REPOSITORY:-}" == "yuangy1995/dsm-native-client" ]] || exit 1
[[ "${GITHUB_REF_TYPE:-}" == tag ]] || exit 1
release_prefix="macos/v"
feed_tag="macos-updates"
prerelease=false
case "${LANSTASH_UPDATE_CHANNEL:-stable}" in
    stable)
        [[ "${GITHUB_REF_NAME:-}" =~ ^macos/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
        ;;
    validation)
        [[ "${GITHUB_REF_NAME:-}" =~ ^macos-validation/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
        release_prefix="macos-validation/v"
        feed_tag="macos-validation-updates"
        prerelease=true
        ;;
    *) echo "无效更新通道" >&2; exit 1 ;;
esac
[[ "$(git rev-parse "$GITHUB_REF_NAME^{commit}")" == "$GITHUB_SHA" ]] || exit 1
[[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]] || exit 1
app="apple/Apps/DsmMac/dist/arm64/LanStash.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
release_title="macOS $version"
if [[ "$prerelease" == true ]]; then
    release_title="$release_title 升级验收版"
fi
[[ "$GITHUB_REF_NAME" == "$release_prefix$version" ]] || exit 1
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
sign_tool="apple/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_tool" ]] || exit 1
release_tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lanstash-publish.XXXXXX")"
trap 'rm -rf -- "$release_tmp"' EXIT
sign_update() {
    # Sparkle 命令在无效私钥时可能回显输入；失败只显示固定提示。
    if ! printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$sign_tool" --ed-key-file - "$@" \
        > "$release_tmp/sign-output" 2> "$release_tmp/sign-error"; then
        echo "更新签名失败，请核对专用密钥配置。" >&2
        return 1
    fi
    if [[ "${1:-}" == -p ]]; then
        cat "$release_tmp/sign-output"
    fi
}
gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" > "$release_tmp/releases.json"
if jq -e --arg tag "$GITHUB_REF_NAME" 'flatten | any(.tag_name == $tag)' "$release_tmp/releases.json" >/dev/null; then
    echo "此版本已存在（可能是待检查的草稿）；不会覆盖已上传的安装包。" >&2
    exit 1
fi
previous_feed=""
if jq -e --arg tag "$feed_tag" 'flatten | any(.tag_name == $tag)' "$release_tmp/releases.json" >/dev/null; then
    mkdir "$release_tmp/previous"
    gh release download "$feed_tag" --pattern appcast.xml --dir "$release_tmp/previous"
    # 已有更新源必须能由同一密钥验证；密钥轮换需要独立迁移，不能误覆盖。
    sign_update --verify "$release_tmp/previous/appcast.xml"
    previous_feed="$release_tmp/previous/appcast.xml"
fi
feed_arguments=(--tag "$GITHUB_REF_NAME" --release-notes docs/releases/MACOS_RELEASE_NOTES.md --output "$release_tmp/appcast.xml")
archives=()
for arch in arm64 x86_64; do
    app="apple/Apps/DsmMac/dist/$arch/LanStash.app"
    archive="apple/Apps/DsmMac/dist/$arch/LanStash-$version-$arch.dmg"
    tools/release/verify_macos_distribution.sh "$app" "$archive" "$GITHUB_SHA"
    signature="$(sign_update -p "$archive")"
    swift tools/release/verify_update_signature.swift "$archive" "$public_key" "$signature"
    feed_arguments+=(--app "$app" --archive "$archive" --signature "$signature")
    cp "$archive" "$release_tmp/"
    archives+=("$release_tmp/$(basename "$archive")")
done
if [[ -n "$previous_feed" ]]; then
    feed_arguments+=(--previous "$previous_feed")
fi
if [[ "$prerelease" == true ]]; then
    feed_arguments+=(--validation)
fi
python3 tools/release/macos_appcast.py "${feed_arguments[@]}"
sign_update "$release_tmp/appcast.xml"
sign_update --verify "$release_tmp/appcast.xml"
(
    cd "$release_tmp"
    shasum -a 256 "LanStash-$version-arm64.dmg" "LanStash-$version-x86_64.dmg" appcast.xml > SHA256SUMS.txt
)
gh release create "$GITHUB_REF_NAME" --verify-tag --draft --latest=false --prerelease="$prerelease" \
    --title "$release_title" --notes-file docs/releases/MACOS_RELEASE_NOTES.md \
    "${archives[@]}" "$release_tmp/appcast.xml" "$release_tmp/SHA256SUMS.txt"
# 回读 GitHub 上的安装包与更新源，确认上传没有损坏，再把草稿公开。
mkdir "$release_tmp/downloaded"
gh release download "$GITHUB_REF_NAME" --dir "$release_tmp/downloaded"
(cd "$release_tmp/downloaded" && shasum -a 256 -c SHA256SUMS.txt)
gh release edit "$GITHUB_REF_NAME" --draft=false --latest=false
if [[ -z "$previous_feed" ]]; then
    gh release create "$feed_tag" --target "$GITHUB_SHA" --prerelease --latest=false \
        --title "macOS 在线更新 / Online Updates" \
        --notes "此条目供 macOS 客户端检查更新。安装包请前往对应版本的发布页面。 / Update feed only; download installers from versioned macOS releases." \
        "$release_tmp/appcast.xml"
else
    gh release upload "$feed_tag" "$release_tmp/appcast.xml" --clobber
fi
echo "macOS 版本和签名更新源已发布。"
