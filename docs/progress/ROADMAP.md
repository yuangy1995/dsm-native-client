<!-- doc-role: roadmap -->
<!-- last-reviewed: 2026-08-20 -->

# 产品路线图

本页只保留未来事项、优先级与进入条件。当前事实见[当前开发进度](STATUS.md)，跨端
范围见[平台功能矩阵](PLATFORM_MATRIX.md)，历史结论见 `docs/archive/2026-h2/`。

## P0：发布硬化与可验证性

### macOS 首个 Beta

- 在受控环境完成 Developer ID 签名、公证、票据装订、Gatekeeper、安装、升级和回退验收。
- 使用专用 NAS 验证 Finder/File Provider、会话隔离、缓存、取消、恢复和危险写最终回读。
- 在正式签名和真实环境结论形成前，不发布、不宣称稳定支持，也不开放未验证高风险内部写。

### Android 发布门

- 保持 Android 质量基线、契约、fixture 脱敏、本地化和结构债务门禁为可重跑状态。
- 在专用验证分支由托管 Runner 完整验证 JVM、Debug、Release/R8、仪器测试 APK 与 lint。
- 在真实设备上验证登录、证书、WorkManager、后台恢复、跨 NAS、危险写和辅助功能。

### Windows 发布门

- 在 Windows 托管 Runner 验证 x64、ARM64、xUnit 与 WinUI XAML。
- 在专用 Windows 设备验证安装、更新、Explorer、Cloud Files、通知、托盘、外接卷和恢复。
- 保持当前发布形态，除非另行批准签名、Identity、安装包或系统版本的迁移方案。

## P1：结构债务与可维护性

### Android

- 保留 `DsmRepository` 和 `AppViewModel` 兼容门面，按 decoder、request builder、
  capability resolver、mutation verifier 和领域 Repository 逐步机械拆分。
- 先迁移 Transfer 与 Photo Backup 等任务所有权明确的路径，再迁 Files、Chat、Downloads、
  NAS、Container 和 VMM；每个 Job、锁和序列号只能有一个所有者。
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
- 继续验证桌面云盘与 Cloud Files 的系统生命周期，不把模拟器、合成测试或静态审查写成
  真机通过。

## P3：后续产品候选

- Apple 移动端自动照片备份、后台常驻传输、iPad 多窗口与 File Provider。
- File Station 的异步目录大小、MD5、VFS 扩展和更完整的后台任务恢复。
- Download Station 的高级 RSS、文件优先级、BT 协议设置、全局设置写入和删除已下载数据。
- Container Manager 与 Virtual Machine Manager 的高级生命周期、网络、控制台和迁移能力。
- Synology Chat 的语音、投票参与、加密会话、多附件和实时通话。
- Audio Station、Video Station、Note Station、Synology Drive、Calendar、Contacts、
  Surveillance Station、Hyper Backup、Active Backup 和 Synology Office。

## 进入条件

任何路线图事项进入活动实现前，必须同时满足：

1. 用户优先级、目标平台和范围明确；
2. API 来源、版本与安全边界可追溯；
3. 不会未经批准改变公开契约、数据格式、签名、包名、Bundle ID、最低系统版本或依赖；
4. 具有聚焦自动化与目标平台验证路径；
5. 高风险写操作具有关闭态、确认、权限、重复提交保护和最终状态复查策略。
