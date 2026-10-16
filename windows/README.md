<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# Windows 原生客户端

Windows 客户端使用 C#、WinUI 3、HttpClient、System.Text.Json 和 Windows Credential Locker。
本轮按固定 `a521ccb5` 的 macOS 业务基线完善文件、Photos、Office、Chat、下载、NAS/套件、容器/VMM 与桌面生命周期。
范围和逐功能证据统一见[Windows 长期计划](../docs/development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)，测试包使用、保护项与真实环境步骤见[验收清单](../docs/quality/WINDOWS_TEST_BUILD_ACCEPTANCE_ZH.md)。

```text
LanStash.Domain          领域模型与跨模块契约
LanStash.Infrastructure  DSM Web API、会话和 Repository
LanStash.Application     特性模型、用例、平台无关协调
LanStash.App             WinUI 3 原生界面
LanStash.Tests           不依赖真实 NAS 的自动化测试
```

开发 API 时先读[按功能实现参考](../docs/api/README.md)，保留 macOS 的请求与恢复语义，并按 Windows 原生交互实现。

## 当前范围

- 认证、Files、Photos 完整管理、Office 本机预览/编辑恢复、Chat 日常流程、Download Station、NAS/套件、Container/VMM 与本机设置均有生产调用链和正式自动化。
- Cloud Files、通知、安装与平台系统集成不以静态代码替代 Windows 设备验收。
- 写操作按实际接口、账号/对象权限、必要确认、防重复和结果回读开放，不使用 DSM/build/套件版本白名单。
- 尚未完成真实环境验收且可能造成数据丢失、越权或不可逆副作用的新增入口保留专项开关，
  具体范围见验收清单；相关限制不阻断其他已开放功能。
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
虚拟机控制台另需本机可用的 Microsoft Edge WebView2 Runtime；ZIP 不包含该浏览器运行时。

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

测试宿主在独立输出目录运行，覆盖各模块浅深色、五态、实际操作、迟到响应、取消、恢复和桌面生命周期；每次生成逐项结果，不能把截图存在或提前退出当作通过。
截图来自程序自己的 WinUI XAML 树，所有文件和容量都是合成数据，不加载本机 NAS 配置或凭据。
该回归不替代真实 NAS、文件选择器、触控、Narrator、系统注册或 ARM64 实机验证。

遇到没有托管异常日志的原生退出，可使用 `-CaptureNativeFailures` 复跑对应 `-Scenarios` / `-States`，在场景目录保存原始错误码、WinRT 起源文本、原生模块栈和合成编码阶段；有匹配的本机符号时显示函数名。该开关仅附加本次启动的隔离宿主，不生成内存转储、不修改系统错误报告设置，也不吞掉被测异常；调试附加会改变运行时序，应与未附加的结果分别记录。`./tests/UiSmoke/verify-native-diagnostics.ps1` 在独立子进程验证可捕获异常和真实 WinRT FailFast 两条路径，检查错误文本、原生栈及字符串边界，不运行生产 App。

## 相关文档

- [Windows 长期计划](../docs/development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [Windows 测试包验收清单](../docs/quality/WINDOWS_TEST_BUILD_ACCEPTANCE_ZH.md)
- [平台功能矩阵](../docs/progress/PLATFORM_MATRIX.md)
- [当前开发进度](../docs/progress/STATUS.md)
- [功能实现与验证等级](../docs/quality/VERIFICATION_LEVELS_ZH.md)
