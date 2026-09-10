# macOS 窗口销毁闪退修复（2026-09-10）

## 范围与证据

- 初始修复基线：`305598a1e06b`，开始时工作区干净。修复阶段只修改 macOS 窗口外观生命周期、对应测试和本文档；用户要求发布后增加版本配置、生成工程、变更记录与双语发布说明。
- 用户报告：1.0.5（15），macOS 27.0（26A5425a），主线程 `NSWindow dealloc → HostView.viewWillMove → setStyleMask → SwiftUI updateNSView → HostView.configure → observe → objc_initWeak` 后终止。
- 原因：离开窗口时先清空监听，再恢复样式；样式修改同步触发布局，重新进入配置并观察正在销毁的旧窗口。原始报告含本机信息，不复制进仓库。

## 修复与复核

- 在窗口迁移开始、撤销监听之前设置迁移状态；配置入口在读取窗口之前检查该状态，阻止同步重入。迁移结束后恢复配置。
- 保留现有标题栏恢复、新旧外壳交接和新窗口监听行为。不改 API、权限、数据格式、应用身份配置或界面文案。
- 独立复核差异与调用顺序：标记先于监听清理和样式恢复；恢复配置在 `viewDidMoveToWindow`；无新增强引用或并行实现。
- 增加直接销毁窗口、同步样式回调重入、旧窗口监听清除和新窗口重新配置的自动化覆盖。

## 已执行验证

环境：macOS 27.0（26A5425a），Xcode 26.6（17F113），Apple 芯片。

- `swift test --package-path apple --jobs 4 --filter MacAppearanceTests`：23 项通过。
- 反向检查：仅暂时移除配置入口的迁移保护，运行 `swift test --package-path apple --jobs 4 --filter 'MacAppearanceTests/test窗口外壳离开时忽略同步布局重入并可接入新窗口'`，1 项测试出现 4 个预期断言失败；随后恢复保护。
- 恢复后运行 `swift test --package-path apple --jobs 4 --filter 'MacAppearanceTests|WorkspacePresentationTests'`：23 项通过，49 项按现有要求因未指定合成输出目录跳过，不记为通过。随后使用专用脚本补跑。
- `python3 tools/localization/check_localization.py`：双语资源、参数、引用和硬编码扫描通过。
- `git diff --check`：通过。
- `bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-crash-ui-20260910-1`：未完成。卡在既有 `test语言与文件排序菜单双语双主题不铺原生白底` 的 `NSPopUpButtonCell.trackMouse` / `NSMenuTrackingSession` 等待事件；采样确认后终止该测试进程（退出码 1）。未修改该测试、未降低断言，不宣称完整 UI 门禁通过。
- 聚焦补跑：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test真实附着确认前后窗口保持清晰且背景使用原生模糊|WorkspacePresentationTests/test完整工作区跨模块切换保留文件选择和窗口标题区|WorkspacePresentationTests/test设置窗口保留原生按钮且不恢复白色标题栏|WorkspacePresentationTests/test页面操作栏不遮挡原生分栏标题' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-crash-ui-focused-20260910-1`：4 项通过，0 跳过、0 失败。

## 独立测试包

构建命令：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_NUMBER=20260910.1 LANSTASH_BUILD_ROOT=/tmp/lanstash-crash-fix-20260910-1 LANSTASH_DIST_DIR="$OUTPUT_DIR" bash apple/Apps/DsmMac/package.sh
```

`OUTPUT_DIR` 为本次新建的下载目录 `LanStash-crash-fix-20260910-1`，未复用或覆盖旧包。

- Release/arm64 构建及打包成功。当时源码版本为 1.0.3，因此产物为 `1.0.3 (20260910.1)`，不冒充报告中的正式版 1.0.5。
- 沿用既有打包脚本的 LanStash Test 隔离身份与存储方式，未修改身份配置或权限文件；未安装、未启动主 App、未提交或推送。
- 输出 App 与只读 DMG 内分别运行 `bash tools/release/verify_macos_local_test.sh <App>` 均通过：临时签名、Hardened Runtime、唯一库验证例外、无挂载扩展、禁用在线更新及实际 Sparkle 加载。
- `hdiutil verify <DMG>` 通过；镜像内构建号为 `20260910.1`；使用 `rsync -rclni --delete <输出App/> <镜像App/>` 只读比较文件校验和及符号链接，无差异；镜像已卸载。
- DMG SHA-256：`f24e67b389e297011e9fdde7d402239fcfa63176f37fb5de6c5895b7442a271d`。

## 用户验证与正式发布准备

- 2026-09-10，用户明确反馈“不会闪退了”，并要求发布版本。记录为本次本地测试包的用户使用验证通过，不扩展为所有窗口、系统版本或正式签名包均已实测。
- 发布准备已同步远端 1.0.5 基线 `d6b4c92`，保留其完整改动；两份正式提交均未修改本次窗口源码与测试文件。
- 正式版本计划为 1.0.6（16），仅更新 macOS 双目标版本与双语发布说明，沿用现有签名、公证和双架构发布流程。
- 使用发布流程锁定的 XcodeGen 2.46.0，校验归档 SHA-256 后重新生成工程；生成差异只有主 App 与扩展的版本及构建号。
- 同步基线后 `python3 -m unittest discover -s tools/release -p 'test_*.py'`：27 项通过；本地化扫描、`python3 tools/codex/check_documentation.py` 及 `git diff --check` 通过。
- 同步基线后再次运行 `swift test --package-path apple --jobs 4 --filter MacAppearanceTests`：23 项通过，0 失败。

## PENDING_USER_VALIDATION（正式包及更多场景）

- 前置条件：正式包完成云端构建、签名和公证后，用户保存工作、等待传输完成，再手动升级正式版；本地测试包不替代正式包的完整验证。
- 操作：重复上次闪退前的操作；多次打开并关闭文件/视频预览窗口，切换登录与工作区，关闭并重新打开窗口，检查标题栏和系统按钮是否正常。
- 预期：关闭或切换窗口不再导致整个应用退出，新窗口正常显示与操作。
- 如失败：回传发生时间、测试包版本、最短操作步骤与去除设备、账号、地址、真实路径等信息后的崩溃堆栈。
- 影响范围：本次修复只覆盖该窗口销毁重入路径；用户报告已确认原使用场景不再闪退，不代表其他闪退全部消除。正式签名、公证与 Intel 构建由云端发布门禁验证；更多系统版本、Intel 实机及挂载回归仍待用户验证。
