<!-- doc-role: roadmap -->
<!-- last-reviewed: 2026-10-10 -->

# 产品路线图

本页只保留未来事项、优先级与进入条件。当前事实见[当前开发进度](STATUS.md)，跨端
范围见[平台功能矩阵](PLATFORM_MATRIX.md)，历史结论见 `docs/archive/2026-h2/`。

## P0：发布硬化与可验证性

### 完整 Release Preflight 基础设施

- 现有 `Documentation & Quality Preflight` 只覆盖文档与仓库质量门禁，不替代跨平台发布验证。
- 在 Apple、Android、Windows 可复用构建、Artifact manifest、SHA-256、签名状态和人工验证
  清单齐备后，再单独编排真正的 Release Preflight。
- 在此之前，不把质量工作流通过表述为签名、安装、升级、回滚、真机或真实 NAS 通过。

### macOS 后续候选与覆盖补齐

- 为后续候选保留 Developer ID 签名、公证、票据装订与公开回读，并补齐未覆盖的 Gatekeeper、安装、升级和回退验收；已发布版本证据见验证历史。
- 使用专用 NAS 验证 Finder/File Provider、会话隔离、缓存、取消、恢复和危险写最终回读。
- 在正式签名和真实环境结论形成前，不发布、不宣称稳定支持，高风险功能按实际授权、能力与权限保护，不把功能开放等同于验收通过。

### Android 发布门

- 保持 Android 质量基线、契约、fixture 脱敏、本地化和结构债务门禁为可重跑状态。
- 使用获授权推送的 `main` 提交或既有工作流，由托管 Runner 完整验证 JVM、Debug、Release/R8、仪器测试 APK 与 lint。
- 在真实设备上验证登录、证书、WorkManager、后台恢复、跨 NAS、危险写和辅助功能。

### Windows 发布门

- 在 Windows 托管 Runner 验证 x64、ARM64、xUnit 与 WinUI XAML。
- 在专用 Windows 设备验证安装、更新、Explorer、Cloud Files、通知、托盘、外接卷和恢复。
- 保持当前发布形态，除非另行批准签名、Identity、安装包或系统版本的迁移方案。

## P1：跨端增量与可维护性

macOS 新增 Photos 管理、File Station 扩展与 Office 本机编辑形成 Windows 后续语义基线，按[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)先形成用户主流程，再完成聚焦自动化与可用构建；iPhone/iPad 的 M0–M8 源码范围已接入，继续完成延期云端复验及明确设备待办，Android 需独立确定范围。


### Android

- 保留 `DsmRepository` 和 `AppViewModel` 兼容门面，按 decoder、request builder、
  capability resolver、mutation verifier 和领域 Repository 逐步机械拆分。
- `TransferCoordinator` 与 `PhotoBackupCoordinator` 已收敛前台/观察 Job、execution、调度代次和
  Profile 生命周期；下一步按 Chat、NAS、Files、Downloads、Container 和 VMM 的完整状态＋任务
  切片推进。每个 Job、锁和序列号只能有一个所有者。
- 最后按状态输入/事件输出拆分 Chat、Files 与 Photos Compose 文件；不改变布局、文案、
  动效、导航、StateFlow 身份或 WorkManager 名称。

### Apple

- 先拆 `apple/Packages` 共享网络中的 NAS Administration Repository，按存储、服务、网络、
  账号、套件、安全、电源和日志形成文件边界。
- `apple/Apps/DsmMac/**` 保持只读；如需修改 Workspace、NAS Administration View 或对应
  Model，必须先取得用户明确授权。

### Windows

- 在保留 `IDsmApiClient`、`DsmApiClient`、DI 和 `HttpClient` 生命周期的前提下，按
  transport、authentication、discovery、multipart upload、download stream、response decoding
  和 certificate policy 拆分 partial 文件。
- 不新增 Gradle/.NET 模块、不重做工程架构、不删除 Windows Application 项目。

## P2：受限能力的真实环境验证

- 使用版本化 fixture 和私有 API 记录，逐项验证 DSM/套件 build 差异、权限、失败语义和
  安全降级；不从网页文案或未验证请求推断契约。
- 对文件、下载、Chat、NAS 管理、Container/VMM 的开放写操作，补齐专用环境的确认、
  权限、重复提交保护、断线与取消、最终状态回读证据。
- macOS Office 预览与本机编辑自动回传已完成源码及本机自动化，后续按 [Office 验收清单](../../apple/Apps/DsmMac/README.md) 验证真实编辑器、NAS、旧格式、正式签名文件访问与辅助功能；不重复列为待开发功能。
- 继续验证桌面云盘与 Cloud Files 的系统生命周期，不把模拟器、合成测试或静态审查写成
  真机通过。

## P3：后续产品候选

- Apple 移动端自动照片备份与 iPad 多窗口。Files 和系统允许的后台执行时间已经接入，按当前计划验收；不承诺不受系统限制的后台常驻。
- File Station 尚未覆盖的远程服务扩展和更完整的后台任务恢复；已有 macOS 功能与边界见 [File Station 账本](../../apple/Apps/DsmMac/README.md)。
- Download Station 各端尚未覆盖的更高阶协议选项；移动端已有 RSS 查看、更新与条目创建，其他端是否接入按矩阵分别记录；已实现的创建、设置、批量与删除语义见[下载 API](../api/reference/download-station.md)，不重复列为新功能。
- Container Manager / VMM 的未覆盖高级拓扑与迁移；已有生命周期、网络管理和控制台按[容器](../api/reference/containers.md)及[虚拟机](../api/reference/virtual-machines.md)记录范围。
- Synology Chat 的加密会话、多附件和实时通话；语音、投票参与已在 macOS 与 Apple 移动端接入，其他端按各自范围评估。
- Audio Station、Video Station、Note Station、Synology Drive、Calendar、Contacts、
  Surveillance Station、Hyper Backup、Active Backup 和 Synology Office。这里的 Synology Office 指 NAS 协作文档套件，与已接入的 macOS 本机 Office 文档预览/编辑不同。

## 进入条件

任何路线图事项进入活动实现前，必须同时满足：

1. 用户优先级、目标平台和范围明确；
2. API 来源、版本与安全边界可追溯；
3. 不会未经批准改变公开契约、数据格式、签名、包名、Bundle ID、最低系统版本或依赖；
4. 具有聚焦自动化与目标平台验证路径；
5. 高风险写操作具有关闭态、确认、权限、重复提交保护和最终状态复查策略。
