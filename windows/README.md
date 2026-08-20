<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-08-20 -->

# Windows 原生客户端

Windows 客户端使用 C#、WinUI 3、HttpClient、System.Text.Json 和 Windows Credential Locker。
当前发布形态、程序集引用、`IDsmApiClient`、`DsmApiClient`、DI、`HttpClient` 生命周期和
证书策略均不是本轮修改范围。

```text
LanStash.Domain          领域模型与跨模块契约
LanStash.Infrastructure  DSM Web API、会话和 Repository
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

## 相关文档

- [Windows 长期计划](../docs/development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [平台功能矩阵](../docs/progress/PLATFORM_MATRIX.md)
- [当前开发进度](../docs/progress/STATUS.md)
- [功能实现与验证等级](../docs/quality/VERIFICATION_LEVELS_ZH.md)
