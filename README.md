<!-- doc-role: entrypoint -->
<!-- last-reviewed: 2026-08-20 -->

# 岚仓（LanStash）

[简体中文](README.md) · [English](README.en.md)

岚仓是面向 Synology DSM 的开源原生客户端项目，覆盖 macOS、iPhone、iPad、Android 和 Windows 五种设备形态。项目不使用跨平台 UI 运行时：Apple 端使用 Swift 与 SwiftUI，Android 使用 Kotlin 与 Jetpack Compose，Windows 使用 C# 与 WinUI 3。

三个技术栈共享 DSM API 契约、错误语义、语言契约、脱敏样本和验收标准，但分别遵循各平台的导航、窗口、触控、键盘、辅助功能和安全存储习惯。

## 项目状态

当前里程碑是“五端原生客户端对齐与实机验收”。

| 客户端 | 技术栈 | 当前状态 |
| --- | --- | --- |
| macOS | Swift 6、SwiftUI、Swift Package Manager | 完成度最高；文件、照片、消息、下载、容器、虚拟机和 NAS 管理主流程已建立 |
| iPhone | Swift 6、SwiftUI | 已形成登录、Files、Photos、受限 Chat 文字、Download Station 常用单任务与只读管理页等移动闭环；当前范围和实机缺口见[开发状态](docs/progress/STATUS.md) |
| iPad | Swift 6、SwiftUI | 与 iPhone 共用通用工程，并已接入分栏、键盘和大屏自适应路径；真实 iPad 与 NAS 交互仍按[开发状态](docs/progress/STATUS.md)验收 |
| Android | Kotlin、Jetpack Compose | 主要模块源码和自动化闭环已建立；当前范围、验证状态与验收缺口见[开发状态](docs/progress/STATUS.md) |
| Windows | C#、WinUI 3 | 已形成认证、Files、Photos、受限 Chat 文字、Download Station、本地设置与桌面集成等原生闭环；云端构建证据和真实设备缺口见[开发状态](docs/progress/STATUS.md) |

“已建立”表示源码路径和自动化测试存在，不等于所有 DSM 型号、系统版本和套件版本都已完成实机兼容验证。高影响写操作仍需能力发现、权限检查、用户确认、重复提交保护和结果校验。

## 主要能力

- 多 NAS 配置、HTTPS 地址和 QuickConnect ID。
- DSM 登录、双重验证、会话恢复和平台安全存储。
- 文件与共享文件夹浏览、搜索、上传、下载、复制、移动、重命名、压缩、解压和分享。
- 照片空间、缩略图、时间线和常见媒体预览。
- Synology Chat 会话、附件、提醒、投票和定时消息能力。
- Download Station、Container Manager、Virtual Machine Manager 和 NAS 设置入口。
- 存储、套件、账号、日志、连接、网络和安全状态的原生管理界面。
- 浅色/深色模式、键盘、触控、动态文字、屏幕阅读器和降低动态效果适配。

部分能力依赖 DSM 或套件版本。项目优先使用 Synology 官方公开 API；必须使用内部 API 时，会在实现与兼容文档中明确标注并通过能力探测隔离。

## 语言与本地化

初期支持：

- 英语（`en`）
- 简体中文（`zh-Hans`）

首次启动默认跟随系统首选语言。英语及其地区变体使用英语；简体中文、中国大陆和新加坡中文使用简体中文；繁体中文和其他尚未支持的语言回退英语。用户可以在 App 内固定选择英语或简体中文，选择仅保存在本机，不与 NAS、账号、密码或会话绑定。

统一语言契约位于 [`contracts/localization/supported-locales.json`](contracts/localization/supported-locales.json)。新增语言必须同时更新 Apple、Android、Windows 资源、语言选择器、测试、README 和平台矩阵。运行以下命令可检查资源缺失、参数不一致、无效引用和用户界面硬编码：

```bash
python3 tools/localization/check_localization.py
```

## 仓库结构

```text
apple/
  Apps/DsmMac/             macOS SwiftUI 应用
  Apps/DsmMobile/          iPhone/iPad 通用 SwiftUI 应用
  Packages/                Apple 共享领域、网络和本地化包
android/                   Android Jetpack Compose 应用
windows/                   Windows WinUI 3 应用
contracts/                 API、错误和语言等跨端契约
docs/                      架构、开发计划、进度、安全和兼容文档
tools/                     本地化、契约和仓库校验工具
```

## 构建与测试

### Apple

需要当前稳定版 Xcode 和 XcodeGen。

```bash
swift test --package-path apple

cd apple/Apps/DsmMac
xcodegen generate
xcodebuild \
  -project DsmMac.xcodeproj \
  -scheme DsmMac \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

cd ../DsmMobile
xcodegen generate
xcodebuild \
  -project DsmMobile.xcodeproj \
  -scheme DsmMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Android

需要 JDK 17 和 Android SDK。

```bash
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

以上是快速冒烟；Release、R8、仪器测试 APK、lint、API 35 和仓库契约的完整命令见
[Android 原生客户端完善计划](docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)。

### Windows

需要 Windows、.NET 10 SDK 和 WinUI 3 构建环境。

```powershell
cd windows
dotnet restore LanStash.slnx
dotnet test tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore
dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-x64 --no-restore
```

各平台的补充环境说明见 [`apple/README.md`](apple/README.md)、[`android/README.md`](android/README.md) 和 [`windows/README.md`](windows/README.md)。GitHub Actions 会分别验证 Apple、Android、Windows 和仓库级契约。

`Documentation & Quality Preflight` 只检查严格文档、Android 质量基线、写操作矩阵、结构债务和本地化；它不是完整发布预检，不能证明 Apple/Android/Windows 构建、签名、安装、升级、回滚、真机或真实 NAS 已通过。真正的 Release Preflight 仍是后续发布基础设施：需先具备跨平台可复用构建、Artifact manifest、SHA-256、签名状态和人工验证清单。

## 安全与隐私

- 不提交密码、OTP、SID、SynoToken、Cookie、DID、证书私钥或真实用户数据。
- 不提交未脱敏的 HAR、PCAP、DSM 响应、文件路径或主机地址。
- Release 构建只允许 HTTPS，不提供全局忽略证书错误的选项。
- 密码和会话只使用平台安全存储，并由用户明确决定是否保存。
- 删除、恢复、网络设置等危险写操作必须确认权限、避免重复提交并校验结果。
- 真实 DSM 行为只在专用测试 NAS 上验证，并记录 DSM build、套件版本和证书类型。

安全问题请遵循 [`SECURITY.md`](SECURITY.md)，不要在公开 Issue 中附带真实环境数据。

## 文档入口

- [当前开发与验收计划](docs/development/NATIVE_DSM_FILE_APP_DEVELOPMENT_PLAN_ZH.md)
- [Android 原生客户端完善、进度与换电脑计划](docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)
- [当前进度](docs/progress/STATUS.md)
- [产品路线图](docs/progress/ROADMAP.md)
- [平台功能矩阵](docs/progress/PLATFORM_MATRIX.md)
- [Android 质量基线](docs/quality/ANDROID_QUALITY_BASELINE_ZH.md)
- [发布与手工验收历史](docs/archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)
- [DSM 兼容矩阵](docs/compatibility/DSM_COMPATIBILITY_MATRIX.md)
- [社区兼容性计划](docs/compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_ZH.md)
- [社区兼容矩阵](docs/compatibility/COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)
- [总体架构](docs/architecture/ARCHITECTURE.md)
- [安全基线](docs/security/SECURITY_BASELINE.md)
- [DSM Web API 参考](docs/api/DSM_WEB_API_REFERENCE_ZH.md)
- [DSM 与套件私有 API 发现规范](docs/api/discovery/README.md)
- [语言契约说明](contracts/localization/README.md)

## 参与开发

开始修改前请阅读 [`AGENTS.md`](AGENTS.md) 和 [`CONTRIBUTING.md`](CONTRIBUTING.md)。所有新增或修改的用户可见文案必须同时提供英语和简体中文资源；翻译后的字符串不得参与业务判断、导航、筛选、持久化或 API 参数。

如果你拥有不同型号或版本的 Synology NAS，也可以参加[社区兼容性计划](docs/compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_ZH.md)。普通用户通过双语 GitHub 表单提交脱敏测试结果，开发者也可以提交经过校验的结构化报告。第一阶段不收集日志、截图、主机信息或真实文件数据。

本项目及其所有历史提交均采用 [Apache License 2.0](LICENSE)。
