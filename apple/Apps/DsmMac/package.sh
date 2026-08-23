#!/bin/bash

# 构建 LanStash.app、执行签名并生成可安装的 DMG。
# 无需命令行参数，所有打包选项都在交互菜单中选择。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/.." && pwd)"
WORKSPACE="$APPLE_DIR/DsmNativeClient.xcworkspace"
SCHEME="DsmMac"
PRODUCT_NAME="LanStash"
ENTITLEMENTS="$SCRIPT_DIR/SupportingFiles/DsmMac.entitlements"
FILE_PROVIDER_ENTITLEMENTS="$SCRIPT_DIR/SupportingFiles/DsmFileProvider.entitlements"
BUILD_ROOT="$SCRIPT_DIR/build/package"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
STAGING_DIR="$BUILD_ROOT/dmg"
DIST_DIR="$SCRIPT_DIR/dist"
MAC_APP_BUNDLE_ID="${LANSTASH_MAC_APP_BUNDLE_ID:-io.github.qwertyuiop1995.dsmnativeclient.macos}"
MAC_FILE_PROVIDER_BUNDLE_ID="${LANSTASH_MAC_FILE_PROVIDER_BUNDLE_ID:-io.github.qwertyuiop1995.dsmnativeclient.macos.fileprovider}"
MAC_APP_GROUP_ID="${LANSTASH_MAC_APP_GROUP_ID:-group.io.github.qwertyuiop1995.dsmnativeclient}"
SHARED_KEYCHAIN_SUFFIX="${LANSTASH_SHARED_KEYCHAIN_SUFFIX:-io.github.qwertyuiop1995.dsmnativeclient.shared}"
MAC_APP_PROVISIONING_PROFILE_PATH="${LANSTASH_MAC_APP_PROVISIONING_PROFILE_PATH:-}"
MAC_FILE_PROVIDER_PROVISIONING_PROFILE_PATH="${LANSTASH_MAC_FILE_PROVIDER_PROVISIONING_PROFILE_PATH:-}"

CONFIGURATION="Release"
TARGET_ARCH="native"
TARGET_ARCH_DESCRIPTION="当前 Mac"
RUN_AFTER_PACKAGE=1
SIGNING_IDENTITY="-"
SELECTED_CHOICE=""

fail() {
    echo "错误：$*" >&2
    exit 1
}

validate_and_embed_profile() {
    local profile_path="$1"
    local expected_bundle_id="$2"
    local destination_path="$3"
    local decoded_profile="$4"
    local profile_team=""
    local application_identifier=""
    local profile_keychain_groups=""

    [[ -f "$profile_path" ]] \
        || fail "找不到 macOS provisioning profile：$profile_path"
    /usr/bin/security cms -D -i "$profile_path" > "$decoded_profile"
    profile_team="$(
        "$PLIST_BUDDY" -c 'Print :TeamIdentifier:0' "$decoded_profile"
    )"
    if ! application_identifier="$(
        "$PLIST_BUDDY" \
            -c 'Print :Entitlements:com.apple.application-identifier' \
            "$decoded_profile" 2>/dev/null
    )"; then
        application_identifier="$(
            "$PLIST_BUDDY" \
                -c 'Print :Entitlements:application-identifier' \
                "$decoded_profile"
        )"
    fi
    [[ "$profile_team" == "$TEAM_IDENTIFIER" ]] \
        || fail "macOS profile 与签名证书团队不匹配"
    [[ "$application_identifier" == "$TEAM_IDENTIFIER.$expected_bundle_id" ]] \
        || fail "macOS profile 与目标 Bundle ID 不匹配"
    profile_keychain_groups="$("$PLIST_BUDDY" \
        -c 'Print :Entitlements:keychain-access-groups' \
        "$decoded_profile" \
    )"
    if ! printf '%s\n' "$profile_keychain_groups" \
            | /usr/bin/grep -Fq "$SHARED_KEYCHAIN_GROUP" \
        && ! printf '%s\n' "$profile_keychain_groups" \
            | /usr/bin/grep -Fq "$TEAM_IDENTIFIER.*"; then
        fail "macOS profile 未授权共享 Keychain group"
    fi
    /bin/cp "$profile_path" "$destination_path"
}

validate_xcode_source_membership() {
    local project_file="$SCRIPT_DIR/DsmMac.xcodeproj/project.pbxproj"
    local source_directory=""
    local source_file=""
    local source_name=""
    local missing_sources=()

    [[ -f "$project_file" ]] || fail "找不到 Xcode 项目文件：$project_file"
    # 主 App 与 File Provider 扩展都必须进入对应构建阶段；避免新建扩展源码只停留在磁盘上。
    for source_directory in "$SCRIPT_DIR/Sources" "$SCRIPT_DIR/FileProviderExtension"; do
        shopt -s nullglob
        for source_file in "$source_directory/"*.swift; do
            source_name="$(basename "$source_file")"
            if ! /usr/bin/grep -Fq "/* $source_name in Sources */" "$project_file"; then
                missing_sources[${#missing_sources[@]}]="$source_name"
            fi
        done
        shopt -u nullglob
    done

    if [[ ${#missing_sources[@]} -gt 0 ]]; then
        fail "以下源码尚未加入 macOS 构建目标：${missing_sources[*]}"
    fi
}

cleanup_old_packages() {
    local package=""
    local removed=0

    shopt -s nullglob
    for package in "$DIST_DIR/$PRODUCT_NAME-"*.dmg; do
        if [[ "$package" == "$DIST_DIR/$PRODUCT_NAME-$VERSION-"*.dmg ]]; then
            continue
        fi
        /bin/rm -f -- "$package"
        removed=$((removed + 1))
    done
    shopt -u nullglob

    if [[ "$removed" -gt 0 ]]; then
        echo "==> 已清理 $removed 个旧版本安装包"
    fi
}

ask_choice() {
    local title="$1"
    local default_choice="$2"
    shift 2
    local options=("$@")
    local choice=""
    local index=0
    local suffix=""

    while true; do
        echo
        echo "$title"
        for ((index = 0; index < ${#options[@]}; index++)); do
            suffix=""
            if [[ $((index + 1)) -eq "$default_choice" ]]; then
                suffix=" [默认]"
            fi
            printf '  %d) %s%s\n' "$((index + 1))" "${options[$index]}" "$suffix"
        done
        printf '请选择 [%s]，输入 q 可退出：' "$default_choice"

        if ! IFS= read -r choice; then
            fail "没有读取到选择，打包已停止"
        fi
        choice="${choice:-$default_choice}"

        if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo "已取消打包。"
            exit 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] \
            && [[ "$choice" -ge 1 ]] \
            && [[ "$choice" -le "${#options[@]}" ]]; then
            SELECTED_CHOICE="$choice"
            return
        fi

        echo "输入无效，请输入 1-${#options[@]}，或输入 q 退出。" >&2
    done
}

choose_signing_identity() {
    local identities=()
    local identity=""

    while IFS= read -r identity; do
        [[ -n "$identity" ]] && identities[${#identities[@]}]="$identity"
    done < <(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')

    if [[ ${#identities[@]} -eq 0 ]]; then
        echo
        echo "未在钥匙串中找到可用的代码签名证书。"
        echo "将继续使用本机临时签名；主应用可以运行，但不会包含云盘映射扩展。"
        SIGNING_IDENTITY="-"
        return
    fi

    ask_choice "选择签名证书" 1 "${identities[@]}"
    SIGNING_IDENTITY="${identities[$((SELECTED_CHOICE - 1))]}"
}

configure_package() {
    local confirmation=""

    while true; do
        echo
        echo "========================================"
        echo "  LanStash macOS 打包工具"
        echo "========================================"
        echo "直接按回车会使用每一步的默认选项。"

        ask_choice "1/4 选择构建类型" 1 \
            "Release（推荐，运行更快）" \
            "Debug（用于开发调试）"
        case "$SELECTED_CHOICE" in
            1) CONFIGURATION="Release" ;;
            2) CONFIGURATION="Debug" ;;
        esac

        ask_choice "2/4 选择适用的 Mac" 1 \
            "当前 Mac（构建最快）" \
            "Apple 芯片与 Intel 通用版" \
            "仅 Apple 芯片" \
            "仅 Intel Mac"
        case "$SELECTED_CHOICE" in
            1)
                TARGET_ARCH="native"
                TARGET_ARCH_DESCRIPTION="当前 Mac"
                ;;
            2)
                TARGET_ARCH="universal"
                TARGET_ARCH_DESCRIPTION="Apple 芯片与 Intel 通用版"
                ;;
            3)
                TARGET_ARCH="arm64"
                TARGET_ARCH_DESCRIPTION="仅 Apple 芯片"
                ;;
            4)
                TARGET_ARCH="x86_64"
                TARGET_ARCH_DESCRIPTION="仅 Intel Mac"
                ;;
        esac

        ask_choice "3/4 选择签名方式" 1 \
            "本机临时签名（可启动，但不包含云盘映射）" \
            "从钥匙串选择签名证书"
        case "$SELECTED_CHOICE" in
            1) SIGNING_IDENTITY="-" ;;
            2) choose_signing_identity ;;
        esac

        ask_choice "4/4 打包完成后" 1 \
            "直接启动 LanStash" \
            "只生成安装包，不启动"
        case "$SELECTED_CHOICE" in
            1) RUN_AFTER_PACKAGE=1 ;;
            2) RUN_AFTER_PACKAGE=0 ;;
        esac

        echo
        echo "打包设置"
        echo "  构建类型：$CONFIGURATION"
        echo "  目标架构：$TARGET_ARCH_DESCRIPTION"
        if [[ "$SIGNING_IDENTITY" == "-" ]]; then
            echo "  签名方式：本机临时签名（不包含 File Provider 云盘扩展）"
        else
            echo "  签名证书：$SIGNING_IDENTITY"
        fi
        if [[ "$RUN_AFTER_PACKAGE" -eq 1 ]]; then
            echo "  完成操作：启动应用"
        else
            echo "  完成操作：仅生成安装包"
        fi

        ask_choice "确认以上设置" 1 \
            "开始打包" \
            "重新选择" \
            "退出"
        confirmation="$SELECTED_CHOICE"
        case "$confirmation" in
            1) return ;;
            2) continue ;;
            3)
                echo "已取消打包。"
                exit 0
                ;;
        esac
    done
}

if [[ -n "${LANSTASH_NON_INTERACTIVE:-}" ]]; then
    # CI / 自动化打包：通过环境变量固定选项
    case "${LANSTASH_BUILD_TYPE:-Release}" in
        Release|Debug) CONFIGURATION="${LANSTASH_BUILD_TYPE:-Release}" ;;
        *) fail "不支持的构建类型：${LANSTASH_BUILD_TYPE}，请使用 Release 或 Debug" ;;
    esac
    case "${LANSTASH_TARGET_ARCH:-native}" in
        native|universal|arm64|x86_64) TARGET_ARCH="${LANSTASH_TARGET_ARCH:-native}" ;;
        *) fail "不支持的架构：${LANSTASH_TARGET_ARCH}，请使用 native / universal / arm64 / x86_64" ;;
    esac
    SIGNING_IDENTITY="${LANSTASH_SIGNING_IDENTITY:--}"
    case "${LANSTASH_RUN_AFTER_PACKAGE:-1}" in
        0|1) RUN_AFTER_PACKAGE="${LANSTASH_RUN_AFTER_PACKAGE:-1}" ;;
        *) fail "LANSTASH_RUN_AFTER_PACKAGE 只能是 0 或 1" ;;
    esac
else
    [[ $# -eq 0 ]] || fail "无需命令行参数，请直接运行 ./package.sh 后按菜单选择"
    configure_package
fi

for command in xcodebuild codesign hdiutil ditto lipo open; do
    command -v "$command" >/dev/null 2>&1 || fail "未找到命令 ${command}，请先安装完整 Xcode"
done

[[ -d "$WORKSPACE" ]] || fail "找不到 Xcode 工作区：$WORKSPACE"
[[ -f "$ENTITLEMENTS" ]] || fail "找不到权限文件：$ENTITLEMENTS"
[[ -f "$FILE_PROVIDER_ENTITLEMENTS" ]] \
    || fail "找不到 File Provider 权限文件：$FILE_PROVIDER_ENTITLEMENTS"
validate_xcode_source_membership

SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
SOURCE_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD || echo detached)"
SOURCE_STATE="clean"
if [[ -n "$(git -C "$REPO_ROOT" status --short)" ]]; then
    SOURCE_STATE="包含未提交改动"
fi

echo "==> 源码：$SOURCE_BRANCH @ ${SOURCE_COMMIT:0:12}（${SOURCE_STATE}）"

HOST_ARCH="$(uname -m)"
case "$TARGET_ARCH" in
    native)
        case "$HOST_ARCH" in
            arm64|x86_64) BUILD_ARCHS="$HOST_ARCH" ;;
            *) fail "不支持当前 Mac 架构：$HOST_ARCH" ;;
        esac
        ARCH_LABEL="$HOST_ARCH"
        ;;
    universal)
        BUILD_ARCHS="arm64 x86_64"
        ARCH_LABEL="universal"
        ;;
    arm64|x86_64)
        BUILD_ARCHS="$TARGET_ARCH"
        ARCH_LABEL="$TARGET_ARCH"
        ;;
    *)
        fail "不支持的架构：$TARGET_ARCH"
        ;;
esac

echo "==> 构建 ${PRODUCT_NAME}（${CONFIGURATION}，${ARCH_LABEL}）"
rm -rf "$BUILD_ROOT"
mkdir -p "$DERIVED_DATA" "$DIST_DIR"

xcodebuild \
    -quiet \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    "LANSTASH_MAC_APP_BUNDLE_ID=$MAC_APP_BUNDLE_ID" \
    "LANSTASH_MAC_FILE_PROVIDER_BUNDLE_ID=$MAC_FILE_PROVIDER_BUNDLE_ID" \
    "LANSTASH_MAC_APP_GROUP_ID=$MAC_APP_GROUP_ID" \
    "LANSTASH_SHARED_KEYCHAIN_SUFFIX=$SHARED_KEYCHAIN_SUFFIX" \
    "ARCHS=$BUILD_ARCHS" \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"
[[ -d "$BUILT_APP" ]] || fail "构建完成但找不到应用：$BUILT_APP"

APP_PATH="$DIST_DIR/$PRODUCT_NAME.app"
rm -rf "$APP_PATH"
/usr/bin/ditto "$BUILT_APP" "$APP_PATH"

PLIST_BUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLIST_BUDDY" ]] || fail "找不到 PlistBuddy"
if ! "$PLIST_BUDDY" -c "Add :LanStashSourceCommit string $SOURCE_COMMIT" "$APP_PATH/Contents/Info.plist" 2>/dev/null; then
    "$PLIST_BUDDY" -c "Set :LanStashSourceCommit $SOURCE_COMMIT" "$APP_PATH/Contents/Info.plist"
fi

if [[ -f "$SCRIPT_DIR/Sources/ChatWorkspaceView.swift" ]] \
    && ! /usr/bin/grep -a -Fq "ChatWorkspaceView" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"; then
    fail "源码包含 Chat，但构建产物未发现 ChatWorkspaceView，请检查 Release target"
fi
if [[ -f "$SCRIPT_DIR/Sources/ChatWorkspaceView.swift" ]]; then
    echo "==> 已验证 Chat 界面进入构建产物"
fi

echo "==> 签名应用"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    # App Group 与共享钥匙串属于受限权限，macOS 不允许临时签名携带。
    # 临时包移除 File Provider 扩展并且不附带受限权限，确保主应用可以启动。
    /bin/rm -rf -- "$APP_PATH/Contents/PlugIns/LanStashFileProvider.appex"
    /usr/bin/codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp=none \
        --sign - \
        "$APP_PATH"
    echo "==> 临时签名包已移除云盘扩展；测试云盘映射请使用 Apple 开发签名证书"
else
    CERTIFICATE_PEM="$BUILD_ROOT/signing-certificate.pem"
    EXPANDED_APP_ENTITLEMENTS="$BUILD_ROOT/DsmMac.expanded.entitlements"
    EXPANDED_FILE_PROVIDER_ENTITLEMENTS="$BUILD_ROOT/DsmFileProvider.expanded.entitlements"
    if /usr/bin/security find-certificate \
        -c "$SIGNING_IDENTITY" \
        -p > "$CERTIFICATE_PEM" 2>/dev/null; then
        TEAM_IDENTIFIER="$(
            /usr/bin/openssl x509 \
                -in "$CERTIFICATE_PEM" \
                -noout \
                -subject \
                -nameopt RFC2253 \
            | /usr/bin/sed -n 's/.*OU=\([^,]*\).*/\1/p'
        )"
    fi
    if [[ -z "$TEAM_IDENTIFIER" ]]; then
        # CI 的临时钥匙串有时可列出签名身份，但 find-certificate 无法按完整显示名称反查。
        # Apple 签名身份名称固定以十位 Team ID 的括号结尾，作为经过格式校验的后备来源。
        if [[ "$SIGNING_IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
            TEAM_IDENTIFIER="${BASH_REMATCH[1]}"
        fi
    fi
    [[ "$TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]] \
        || fail "无法从签名证书读取团队标识，请改用 Apple 开发或 Developer ID 证书"
    if [[ "$MAC_APP_GROUP_ID" != group.* \
        && "$MAC_APP_GROUP_ID" != "$TEAM_IDENTIFIER".* ]]; then
        fail "macOS Team-ID 风格 App Group 与签名证书团队不匹配"
    fi
    SHARED_KEYCHAIN_GROUP="${TEAM_IDENTIFIER}.${SHARED_KEYCHAIN_SUFFIX}"
    [[ -n "$MAC_APP_PROVISIONING_PROFILE_PATH" ]] \
        || fail "正式签名缺少主 App 的 macOS provisioning profile"
    [[ -n "$MAC_FILE_PROVIDER_PROVISIONING_PROFILE_PATH" ]] \
        || fail "正式签名缺少 File Provider 的 macOS provisioning profile"
    /bin/cp "$ENTITLEMENTS" "$EXPANDED_APP_ENTITLEMENTS"
    /bin/cp \
        "$FILE_PROVIDER_ENTITLEMENTS" \
        "$EXPANDED_FILE_PROVIDER_ENTITLEMENTS"
    "$PLIST_BUDDY" \
        -c "Set :keychain-access-groups:0 $SHARED_KEYCHAIN_GROUP" \
        "$EXPANDED_APP_ENTITLEMENTS"
    "$PLIST_BUDDY" \
        -c "Set :keychain-access-groups:0 $SHARED_KEYCHAIN_GROUP" \
        "$EXPANDED_FILE_PROVIDER_ENTITLEMENTS"
    "$PLIST_BUDDY" \
        -c "Set :com.apple.security.application-groups:0 $MAC_APP_GROUP_ID" \
        "$EXPANDED_APP_ENTITLEMENTS"
    "$PLIST_BUDDY" \
        -c "Set :com.apple.security.application-groups:0 $MAC_APP_GROUP_ID" \
        "$EXPANDED_FILE_PROVIDER_ENTITLEMENTS"

    FILE_PROVIDER_APP="$APP_PATH/Contents/PlugIns/LanStashFileProvider.appex"
    [[ -d "$FILE_PROVIDER_APP" ]] \
        || fail "完整签名需要 File Provider 扩展，但构建产物中未找到"
    validate_and_embed_profile \
        "$MAC_FILE_PROVIDER_PROVISIONING_PROFILE_PATH" \
        "$MAC_FILE_PROVIDER_BUNDLE_ID" \
        "$FILE_PROVIDER_APP/Contents/embedded.provisionprofile" \
        "$BUILD_ROOT/DsmFileProvider.profile.plist"
    validate_and_embed_profile \
        "$MAC_APP_PROVISIONING_PROFILE_PATH" \
        "$MAC_APP_BUNDLE_ID" \
        "$APP_PATH/Contents/embedded.provisionprofile" \
        "$BUILD_ROOT/DsmMac.profile.plist"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$EXPANDED_FILE_PROVIDER_ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$FILE_PROVIDER_APP"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$EXPANDED_APP_ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_PATH"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$($PLIST_BUDDY -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
[[ -x "$EXECUTABLE" ]] || fail "应用主程序不存在：$EXECUTABLE"

echo "==> 校验架构：$(/usr/bin/lipo -archs "$EXECUTABLE")"

DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION-$ARCH_LABEL.dmg"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/$PRODUCT_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> 生成 DMG"
/bin/rm -f -- "$DMG_PATH"
# hdiutil 在 macOS 15 与更高版本均支持此格式；diskutil 的 image 子命令参数并不稳定。
/usr/bin/hdiutil create \
    -volname "$PRODUCT_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "==> 验证 DMG"
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    echo "==> 签名 DMG"
    /usr/bin/codesign \
        --force \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$DMG_PATH"
    /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
fi

# 只有当前安装包已经成功生成并通过验证后，才删除 dist 中较早版本的 DMG。
# 同一版本的不同架构会保留，方便同时分发 Apple 芯片版和通用版。
cleanup_old_packages

echo
echo "打包完成："
echo "  版本：$VERSION ($BUILD_NUMBER)"
echo "  App：$APP_PATH"
echo "  DMG：$DMG_PATH"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "  签名：本机临时签名（可运行主应用，不包含云盘映射）"
else
    echo "  签名：$SIGNING_IDENTITY"
    echo "  提示：公开分发前仍需完成 Apple 公证。"
fi

if [[ "$RUN_AFTER_PACKAGE" -eq 1 ]]; then
    echo "==> 启动刚生成的 ${PRODUCT_NAME}（新实例）"
    /usr/bin/open -n "$APP_PATH"
fi
