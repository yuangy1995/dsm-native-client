<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# macOS 客户端

岚仓的 SwiftUI/AppKit 应用。内部 target/scheme 为 `DsmMac`，正式产物为 `LanStash.app`。功能范围只维护在[五端矩阵](../../../docs/progress/PLATFORM_MATRIX.md)，当前源码与已发布版本分开，发布见[手册](../../../docs/releases/MACOS_GITHUB_RELEASE_ZH.md)。

## 使用与恢复

每个 NAS 工作区独立持有连接、文件位置和任务；切换页面或 NAS 不结束该工作区传输。文件图标视图支持 Command/Shift 多选和空白处框选，列表沿用系统多选。任务进度与逐项结果从传输中心查看；清理记录不删除 NAS 内容，未知任务不自动重发。

上传暂停后继续可能重新发送未完成文件，公开 Upload 没有字节偏移续传契约；已经提交但结果不明时先只读恢复。下载续传和媒体预览需要可靠的 Range/版本证据。图片、PDF、音视频和 Office 的实际格式支持由系统组件决定。

Office 预览不会自动开始回传。选择本机副本及编辑器后，稳定保存可回传到原路径；未修改不上传、冲突停止覆盖、未知只读核对。关闭视图不结束会话，明确停止/断开/退出后保留副本，重启不自动接管，“另存为”不跟踪新路径。公开接口没有跨客户端原子锁；跨 NAS 移动还有[待处理风险](../../../docs/progress/KNOWN_LIMITATIONS.md)，测试前先保留源文件。

Finder 本地磁盘挂载默认只读，编辑和删除分别授权；缓存不是备份，映射根/共享根受保护。Mac 主 App 的会话及可选密码存于加密文件，主密钥在私有 Keychain；系统挂载只共享必要会话。系统权限、映射移除和回退规则见[平台集成](../../../docs/development/PLATFORM_INTEGRATION.md)。

## 构建与本机测试包

完整 Xcode 和 XcodeGen 版本以 [Apple 工作流](../../../.github/workflows/apple-build.yml)为准。从仓库根目录执行：

```sh
swift test --package-path apple
xcodegen generate --spec apple/Apps/DsmMac/project.yml
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$PWD/build/mac-local-test" bash apple/Apps/DsmMac/package.sh
```

也可在本目录运行 `./package.sh` 交互选择构建、架构、签名和是否启动；脚本不接受命令行参数。测试使用独立输出目录并关闭自动启动，避免覆盖旧包；默认输出目录会在成功验证后清理更早版本 DMG。

本机临时签名沿用脚本既有的 `.macos.localtest` 身份、`LanStash Test.app` 和独立 App Group/Keychain，默认输出到 `dist/local-test`；不访问或迁移正式应用数据，不含 Finder 挂载扩展。只给专用测试权限文件增加库验证例外，正式包不得携带。打包验证实际 Sparkle 加载、签名、架构与 DMG 内容，不能仅凭 codesign 完整性认定可运行。签名证书、主 App/扩展 profile、公证和正式在线更新均按[发布手册](../../../docs/releases/MACOS_GITHUB_RELEASE_ZH.md)办理。

## 原生验证与源码入口

```sh
LANSTASH_UI_TEST_FILTER='<相关 WorkspacePresentationTests 方法>' LANSTASH_UI_NATIVE_SCREENSHOTS=1 bash tools/codex/run_macos_ui_checks.sh "$PWD/build/mac-ui-check"
```

原生用例应使用独立输出目录，实际检查双语、主题、文字及交互边界；默认共享测试中的条件跳过不替代这些检查。Office 真实编辑器、Finder、麦克风、VoiceOver、升级和 NAS 写入按[限制清单](../../../docs/progress/KNOWN_LIMITATIONS.md)及[云盘验收](../../../docs/compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)执行。

工作区入口在 [WorkspaceView](Sources/WorkspaceView.swift)/[WorkspaceModel](Sources/WorkspaceModel.swift)，Photos/文件共用模块见 [Apple 结构](../../README.md)；请求与结果语义从 [API 目录](../../../docs/api/README.md)查阅。不要在本 README 复制逐次构建、截图和发布流水。
