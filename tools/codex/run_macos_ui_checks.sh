#!/bin/bash
# 显式运行合成 UI 绘制；fixture 注入空缓存准备动作，不清理真实 App 的预览缓存。
# 可用 LANSTASH_UI_TEST_FILTER 选择检查；原生截图另设 LANSTASH_UI_NATIVE_SCREENSHOTS=1，需屏幕录制权限。
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo '用法：bash tools/codex/run_macos_ui_checks.sh <合成截图输出目录>' >&2
    exit 2
fi

case "$1" in
    /*) ;;
    *) echo '输出目录必须是绝对路径。' >&2; exit 2 ;;
esac

LANSTASH_UI_TEST_ISOLATED=1 LANSTASH_UI_ARTIFACTS="$1" \
    swift test --package-path apple --jobs 4 --filter "${LANSTASH_UI_TEST_FILTER:-WorkspacePresentationTests}"
