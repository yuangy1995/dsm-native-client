<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-09-16 -->

# Windows 原生客户端

Windows 客户端使用 C#、WinUI 3、HttpClient、System.Text.Json 和 Windows Credential Locker。
2026-09-16 按用户提供的 macOS 浅色／深色截图重建原生工作区、文件页、登录、照片、消息与 NAS 设置布局。
协议、认证、会话存储和危险写门保持既有实现；本次界面交付不等于全部 macOS 功能已完成对齐。
范围、测试与缺口统一见[原生重建账本](../docs/development/WINDOWS_NATIVE_REBUILD_ZH.md)。

```text
LanStash.Domain          领域模型与跨模块契约
LanStash.Infrastructure  DSM Web API、会话和 Repository
LanStash.Application     特性模型、用例、平台无关协调
LanStash.App             WinUI 3 原生界面
LanStash.Tests           不依赖真实 NAS 的自动化测试
```

## 当前范围

- 认证、Files、Photos、受限 Chat、Download Station、本机设置与桌面路径维持既有实现。
- Cloud Files、通知、安装与平台系统集成不以静态代码替代 Windows 设备验收。
- Container/VMM、NAS 设置、下载设置和其他高影响写操作只在记录的能力门允许时开放；
  未验证路径继续关闭或只读。
- 结构拆分只使用现有 partial 文件方向，不删除 Windows Application 项目，也不重做架构。

## Windows 环境验证

```powershell
dotnet restore LanStash.slnx
dotnet test tests\LanStash.Tests\LanStash.Tests.csproj --configuration Release --no-restore
dotnet build src\LanStash.App\LanStash.App.csproj --configuration Release --runtime win-x64 --no-restore
dotnet build src\LanStash.App\LanStash.App.csproj --configuration Release --runtime win-arm64 --no-restore
```

完整验证必须在 Windows 托管 Runner 或受控 Windows 环境运行。Explorer、Cloud Files、通知、
托盘、安装、外接卷、辅助功能和真实 NAS 仍为 `PENDING_USER_VALIDATION`，不能由非 Windows
主机构建或源码阅读替代。

## 本地便携包

在 `windows` 目录运行 `./package.ps1`。默认生成包含 .NET 与 Windows App Runtime 的
unpackaged 便携 ZIP，解压后运行 `LanStash.App.exe`，不需要改动系统运行库或覆盖旧包。
每次输出到独立的 `dist/yyyyMMdd-HHmmss/` 目录，包含 SHA-256 和构建来源记录。
未签名测试包不等于正式分发；Explorer、Cloud Files 和通知仍需要独立系统验收。

```powershell
$env:LANSTASH_NON_INTERACTIVE = '1'
$env:LANSTASH_TARGET_PLATFORM = 'both' # x64 / arm64 / both
$env:LANSTASH_RUN_TESTS = '1'
$env:LANSTASH_LAUNCH_AFTER = '0'
./package.ps1
```

`LANSTASH_SELF_CONTAINED=0` 可生成依赖已安装运行库的包；默认为 `1`。
脚本始终禁用合成 UI 编译选项，正常包不包含演示账户或合成 Repository。

## 原生 UI 合成回归

```powershell
./tests/UiSmoke/run.ps1
./tests/UiSmoke/run.ps1 -SkipBuild -Scenarios chat -PaneState cycle
./tests/UiSmoke/run.ps1 -SkipBuild -Scenarios photos,chat,downloads,containers,vms -WindowWidth 900 -PaneState cycle
```

测试宿主在独立输出目录运行，覆盖 24 组浅深色、文件五态、选中详情、列表、登录、NAS 存储、照片、消息及下载／容器／虚拟机内容状态。
截图来自程序自己的 WinUI XAML 树，所有文件和容量都是合成数据，不加载本机 NAS 配置或凭据。
该回归不替代真实 NAS、文件选择器、触控、Narrator、系统注册或 ARM64 实机验证。

## 相关文档

- [Windows 长期计划](../docs/development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [平台功能矩阵](../docs/progress/PLATFORM_MATRIX.md)
- [当前开发进度](../docs/progress/STATUS.md)
- [功能实现与验证等级](../docs/quality/VERIFICATION_LEVELS_ZH.md)
