<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# iPhone / iPad 客户端

岚仓的通用 SwiftUI App，最低 iOS/iPadOS 17。业务范围相同，iPhone 使用导航栈/标签栏，iPad 按可用宽度和字号采用分栏及键盘入口。[功能矩阵](../../../docs/progress/PLATFORM_MATRIX.md)是唯一功能清单。

## 使用

支持 HTTPS 或 QuickConnect、OTP、用户明确选择的记住密码与自动登录。默认导航为文件和 App 设置；在设置中按当前账号授权开启照片、聊天、下载、容器、虚拟机和 NAS 设置。权限刷新只过滤入口，不覆盖用户的显隐偏好。

文件活动入口集中显示传输、跨 NAS、Office 与扩展任务；重新打开应用只查询已提交的未知结果，未开始部分由用户明确继续。Files 位置的启用、授权、移除前检查与系统分享规则见[平台集成](../../../docs/development/PLATFORM_INTEGRATION.md)。

后台时间的限制见[后台执行与系统分享](../../../docs/development/PLATFORM_INTEGRATION.md#后台执行与系统分享)。Chat 新消息更新限前台工作区，本地定时提醒最多安排最近50条；无后台远程推送。录音由用户主动开始，后台/中断不自动恢复。

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

Files 系统用例在 CI 中逐个执行，每例按当前选定的设备型号与系统运行时新建模拟器并安装测试 App，不继承其他设备的系统选择器缓存、禁用状态或 Spotlight 索引数据库。用例仍须在原期限内自行完成域清理；独立结果封存后回收该设备。任一失败都会使整组失败，分享、后台和其余模块回归仍继续执行。

[界面卡顿诊断](../../../tools/release/capture_apple_ui_hangs.py)在建立自动化会话时预取指定模拟器的测试 App 路径与合成进程身份。启动、等待空闲或界面查询持续 20 秒无输出，以及明确的启动、空闲和快照查询超时，都会触发后台采样；普通业务等待不触发无输出诊断。采样前重新核对精确路径、PID 与显式合成参数；路径查询超时可保留已核对结果，拒绝或无效结果会清除缓存，不按进程名推测目标。采样失败允许有界重试，成功后去重，并限制总采样次数。工作流分别上传诊断文本与完整测试结果，便于直接检查调用栈；诊断不延长测试断言期限或改写失败结果。
