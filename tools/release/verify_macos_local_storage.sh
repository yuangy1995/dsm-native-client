#!/bin/bash
# 链接真实存储实现，使用相同临时签名策略跨进程验证合成资料；不启动主 App。
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="$(swift build --package-path "$repo_root/apple" --show-bin-path)"
probe_dir="$(mktemp -d /tmp/lanstash-storage-probe.XXXXXX)"
probe_id="$(uuidgen)"
app="$probe_dir/StorageProbe.app"
executable="$app/Contents/MacOS/StorageProbe"
cleanup() {
    if [[ -x "$executable" ]]; then
        "$executable" "$probe_dir/data" "$probe_id" cleanup || return 1
    fi
    rm -r -- "$probe_dir"
}
trap cleanup EXIT
mkdir -p "$app/Contents/MacOS"
ditto "$repo_root/tools/release/fixtures/macos_local_storage_probe.plist" "$app/Contents/Info.plist"
xcrun swiftc -parse-as-library -I "$build_dir/Modules" \
    "$repo_root/tools/release/fixtures/macos_local_storage_probe.swift" \
    "$build_dir"/DsmCore.build/*.swift.o \
    "$build_dir"/DsmLocalization.build/*.swift.o \
    "$build_dir"/DsmNetwork.build/*.swift.o \
    -o "$executable"
bash "$repo_root/tools/release/sign_macos_local_test.sh" "$app"
"$executable" "$probe_dir/data" "$probe_id" write
"$executable" "$probe_dir/data" "$probe_id" read
echo "隔离测试身份下的加密保存与跨进程读取检查通过。"
