<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# iPhone / iPad 客户端

岚仓的通用 SwiftUI App，最低 iOS/iPadOS 17。业务范围相同，iPhone 使用导航栈/标签栏，iPad 按可用宽度和字号采用分栏及键盘入口。[功能矩阵](../../../docs/progress/PLATFORM_MATRIX.md)是唯一功能清单。

## 使用

支持 HTTPS 或 QuickConnect、OTP、用户明确选择的记住密码与自动登录。默认导航为文件和 App 设置；在设置中按当前账号授权开启照片、聊天、下载、容器、虚拟机和 NAS 设置。权限刷新只过滤入口，不覆盖用户的显隐偏好。

文件活动入口集中显示传输、跨 NAS、Office 与扩展任务。复制/上传、加入相册、删源等阶段分开处理；重新打开应用只查询已提交的未知结果，未开始部分由用户明确继续。Office 使用系统副本后主动保存，Files 原位编辑另有授权及冲突保护。

在设置中为原账号启用 Files 位置后，还需在系统“文件”启用该提供器。默认只读，编辑与删除分别授权；移除前处理未完成操作与未保存副本。系统分享在扩展内选择 NAS/目录并明确上传，主 App 只接手已释放的原任务。

普通文件、照片、跨 NAS 与 Office 可使用系统允许的后台时间，到期停止后项并保留恢复事实，不承诺锁屏或进程终止后继续。Chat 新消息更新限前台工作区，本地定时提醒最多安排最近50条；无后台远程推送。录音由用户主动开始，后台/中断不自动恢复。

平台与存储边界见[集成说明](../../../docs/development/PLATFORM_INTEGRATION.md)。真机密码在 Keychain；仅模拟器用沙盒保护存储验证。移动仍使用当前开发格式，不保证旧开发记录迁移，也不能清空未知记录绕过防重复。

## 构建与测试

使用 [Apple 工作流](../../../.github/workflows/apple-build.yml)锁定的 Xcode/XcodeGen。以下从仓库根目录运行：

```sh
xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<测试设备ID>' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

通用无签名构建只证明编译；实际模拟器测试使用正常临时签名，分别选择 iPhone 和 iPad。按改动使用 `-only-testing` 聚焦，失败退出不得吞掉。仅 Debug 的 `--ui-fixture` 使用隔离偏好和合成网络；Release 不包含这些入口。共享修改另运行 `swift test --package-path apple` 和 Mac 回归。

正式 App/Share/Files 的团队与移动 App Group、共享会话权限须一致，见[签名配置](../../../docs/releases/MACOS_GITHUB_RELEASE_ZH.md)。已知源码问题、完整云端复验及真机/真实 NAS 条件见[限制清单](../../../docs/progress/KNOWN_LIMITATIONS.md)；模拟器通过不表示系统文件、后台调度或正式分发完成。
