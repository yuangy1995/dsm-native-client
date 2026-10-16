<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# Windows 原生客户端

C#/WinUI 3 客户端，目标为 Windows 10 19041 及以上、x64/ARM64，使用 .NET 10。具体版本以[工程](src/LanStash.App/LanStash.App.csproj)和[Windows 工作流](../.github/workflows/windows-build.yml)为准。

[功能矩阵](../docs/progress/PLATFORM_MATRIX.md)维护可用范围，[当前限制](../docs/progress/KNOWN_LIMITATIONS.md)列出未解决问题与设备验收，[平台集成](../docs/development/PLATFORM_INTEGRATION.md)说明 Office、Cloud Files 和恢复边界。不要把有页面或测试通过视为真实 NAS 全部可用。

## 运行与打包

在 `windows` 目录执行 `./package.ps1`，按提示选择构建与架构。非交互示例：

```powershell
$env:LANSTASH_NON_INTERACTIVE = '1'
$env:LANSTASH_TARGET_PLATFORM = 'both' # x64 / arm64 / both
$env:LANSTASH_RUN_TESTS = '1'
$env:LANSTASH_LAUNCH_AFTER = '0'
./package.ps1
```

每次在独立 `dist/yyyyMMdd-HHmmss/` 生成便携 ZIP、SHA-256 和构建来源。解压整个包后手动运行 `LanStash.App.exe`，不覆盖旧目录；同一 Windows 用户仍共享本机设置，不要同时运行新旧包。默认包含 .NET 与 Windows App Runtime；`LANSTASH_SELF_CONTAINED=0` 可选择已安装运行库。控制台另需 WebView2 Runtime，Office/媒体预览取决于系统组件。

正常包禁用合成 UI 编译选项。Cloud Files 必须先在设置中明确启用本次测试，映射默认只读，编辑与删除分别授权。Photos 危险管理、跨 NAS 删源、Office 自动覆盖、下载未完成文件处理、套件高风险增量和 VMM 新内部写的默认保护见矩阵；本地构建不会自动解除。

## 开发与验证

命令从 `windows` 目录执行：

```powershell
dotnet restore LanStash.slnx
dotnet test tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore
dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-x64 -p:Platform=x64 --no-restore
dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-arm64 -p:Platform=ARM64 --no-restore
./tests/UiSmoke/run.ps1 -Language zh-CN
./tests/UiSmoke/run.ps1 -SkipBuild -Language en-US -Scenarios photos,chat,downloads,containers,vms -WindowWidth 900 -PaneState cycle
```

按改动选择聚焦用例，未改动的整组不为凑次数重复执行。原生宿主使用隔离合成数据，不读取真实 NAS 配置；检查实际文字、操作、边界及退出结果。无托管异常的原生退出可用 `-CaptureNativeFailures` 复跑对应场景，收集该宿主的错误码/原生栈，不生成内存转储；附加调试与普通运行分别记录。诊断自检为 `./tests/UiSmoke/verify-native-diagnostics.ps1`。

四层入口为 [Domain](src/LanStash.Domain)、[Infrastructure](src/LanStash.Infrastructure)、[Application](src/LanStash.Application)、[App](src/LanStash.App)；Repository 沿现有 partial、DI 与 HttpClient 复用。接口查[API 目录](../docs/api/README.md)，仓库检查与证据边界见[验证原则](../docs/quality/VERIFICATION_LEVELS_ZH.md)。

升级/回退前处理未结束传输并导出需要的 Office/录音副本，保留恢复记录；旧包不能接管不认识的记录。构建不等于签名、安装、Explorer、通知、物理 ARM64 或真实 NAS 已验收。
