<!-- doc-role: status -->
<!-- last-reviewed: 2026-08-20 -->

# 当前开发进度

> 更新日期：2026-08-20

本页只记录当前源码、自动化、真实环境和发布准备状态。历史决策见
[跨端功能对齐历史](../archive/2026-h2/CROSS_PLATFORM_PARITY_HISTORY.md) 与
[Android 对齐历史](../archive/2026-h2/ANDROID_ALIGNMENT_HISTORY_82_89.md)。

## 五端状态

| 平台 | 源码 | 自动化 | 真机 / 真实 NAS | 发布 |
| --- | --- | --- | --- | --- |
| macOS | Files、Photos、Chat、Download Station、NAS 管理与桌面云盘路径均在源码中；高风险内部写入口保持能力门保护。 | 本轮共享包测试、无签名构建和桌面云盘专用回归已通过。 | `PENDING_USER_VALIDATION`：正式签名、Finder/File Provider、真实 NAS、升级与危险写回读。 | 未发布；首个 Beta 仅准备，不得在签名与公证前分发。 |
| iPhone | 移动范围内的登录、Files、Photos、受限 Chat、Download Station 与只读 NAS 摘要已在通用工程中。 | 本轮 iPhone 模拟器无签名构建已通过。 | `PENDING_USER_VALIDATION`：设备登录、选择器、网络切换、VoiceOver 与真实套件行为。 | 未发布；随 Apple Beta 验收入口统一判断。 |
| iPad | 与 iPhone 共用领域与网络层，保留双栏、键盘与宽屏适配路径。 | 本轮独立 iPad 模拟器无签名构建已通过。 | `PENDING_USER_VALIDATION`：分栏、键盘、动态文字、VoiceOver 与真实 NAS。 | 未发布；不以 iPhone 模拟器替代 iPad 验收。 |
| Android | Compose 兼容入口、领域状态、后台任务和质量基线均在源码中；Container 未验证写操作继续关闭。 | 写操作、页面五态、点击目标、动效、结构债务、本地化、fixture 与契约门禁可在仓库运行；完整 Android 门禁待托管 Runner。 | `PENDING_USER_VALIDATION`：真实登录、证书、后台、真实 NAS、危险写和多设备辅助功能。 | 未发布；Release/R8、仪器 APK、lint 与设备验收均是后续门。 |
| Windows | WinUI、领域、基础设施与 Cloud Files 路径保留；危险写和未验证系统集成继续关闭或只读。 | xUnit、WinUI x64/ARM64 由 Windows 托管 Runner 验证。 | `PENDING_USER_VALIDATION`：Windows 设备、Explorer/Cloud Files、通知、安装生命周期和真实 NAS。 | 未发布；不改变当前 unpackaged 形态、签名或程序集引用。 |

### macOS

- 源码状态：共享 Apple Package 是可修改范围；`apple/Apps/DsmMac/**` 仍是只读参考实现。
- 自动化状态：本轮已通过共享 Package 测试、iPhone/iPad 模拟器构建与 macOS 无签名构建。
- 真机状态：正式签名、notarization、stapling、Gatekeeper、Finder、File Provider、真实 NAS、升级安装和危险写回读均为 `PENDING_USER_VALIDATION`。
- 发布状态：未形成可公开 Beta；候选包必须先经过正式签名与执行矩阵。

### iPhone

- 源码状态：坚持随身伴侣范围，不把复杂运维、后台常驻或桌面交互隐式迁入。
- 自动化状态：本轮 iPhone 模拟器构建已通过；共享 Package 改动同时完成 macOS 回归。
- 真机状态：系统选择器、前后台切换、触控、网络切换和真实 Chat Server 行为待用户验证。
- 发布状态：无 TestFlight 或公开分发动作。

### iPad

- 源码状态：双栏和宽屏路径保留在移动范围，不复制 macOS 的菜单栏或常驻进程语义。
- 自动化状态：本轮独立 iPad 模拟器构建已通过。
- 真机状态：分栏、多任务、键盘、VoiceOver、最大动态文字和真实 NAS 待用户验证。
- 发布状态：无 TestFlight 或公开分发动作。

### Android

- 源码状态：`AppViewModel` 与 `DsmRepository` 仍是门面，后续仅作机械拆分，不改变公开契约、任务语义或持久化格式。
- 自动化状态：本轮 JSON 质量基线和 Python 门禁已建立；完整 JVM、Release/R8、仪器 APK 与 lint 由托管 Runner 执行。
- 真机状态：认证、证书、WorkManager、跨 NAS、后台恢复、危险写和辅助功能均待用户验证。
- 发布状态：无 Play 分发；未验证内部写入口保持关闭。

### Windows

- 源码状态：保留 `IDsmApiClient`、`DsmApiClient`、DI、`HttpClient` 生命周期与证书策略；只按 partial 文件边界拆分。
- 自动化状态：本轮需要 Windows Runner 复核 x64、ARM64、xUnit 与 WinUI XAML。
- 真机状态：Explorer、Cloud Files、通知、安装、托盘、外接卷和真实 NAS 待用户验证。
- 发布状态：不创建安装包、不变更签名策略、不发布。

## 五端验证边界

### macOS Beta 准备

- 源码：共享 Package 可以继续收敛网络和领域实现；DsmMac App 保持只读。
- 源码：桌面云盘所有改变继续保持只读、安全失败或能力门保护。
- 自动化：本轮共享 Package 测试与无签名 macOS 构建已通过。
- 自动化：共享网络变更必须同时验证 macOS 回归，不能只跑移动构建。
- 真机：正式签名、App Group、Keychain、Finder 与 Extension 的系统行为仍缺证据。
- 真机：真实 NAS 文件、缓存、取消、恢复、升级和回退仅在专用环境执行。
- 发布：签名、公证、票据装订和 Gatekeeper 未完成前不产生发布批准。
- 发布：手工验收记录只保存脱敏结论与清理状态，不保存凭据或真实环境信息。

### iPhone 验证边界

- 源码：仅维护批准的移动核心和受限路径，不扩张至桌面专有能力。
- 源码：共享模型变化不能破坏 macOS 行为或已有移动 StateFlow/ObservableObject 语义。
- 自动化：模拟器构建用于编译与组合检查，不推断系统选择器、权限或设备手势。
- 自动化：页面状态、可访问性和本地化保持可重跑，真实服务端时序另行验证。
- 真机：登录、证书、系统 Files/Photos 选择器、前后台和网络切换需要真实设备。
- 真机：VoiceOver、最大动态文字、触控和真实 Chat Server 行为需要专用账号。
- 发布：TestFlight、签名、安装和回退尚未启动。
- 发布：移动分发不因无签名模拟器通过而进入 Beta。

### iPad 验证边界

- 源码：双栏只在可用宽度下出现，保持与 iPhone 共享领域和会话隔离。
- 源码：不引入 macOS 菜单栏、悬停、右键或桌面常驻流程。
- 自动化：iPad 模拟器构建验证通用工程与宽屏组合，不替代实体键盘或多任务。
- 自动化：共享 Package 回归与 iPhone/iPad 构建共同覆盖修改的移动领域层。
- 真机：分栏、多任务、键盘、最大动态文字和 VoiceOver 需要真实 iPad。
- 真机：真实 NAS、网络切换、系统分享和选择器权限仍待用户验证。
- 发布：没有独立 iPad 发布批准；随 Apple Beta 统一判断。
- 发布：后续多窗口与后台候选不属于当前分发范围。

### Android 验证边界

- 源码：写入口清单、页面五态、触控、动效和结构债务已由 JSON 基线保护。
- 源码：领域拆分只减少门面责任，不改变请求、持久化、状态和任务语义。
- 自动化：本机执行轻量门禁、聚焦测试和增量编译，完整 Android 任务交由托管 Runner。
- 自动化：fixture 脱敏、请求契约、私有 API 引用和本地化均为每个切片的基础检查。
- 真机：设备认证、证书、Doze、WorkManager、相册授权和实际后台限制需要真实 Android。
- 真机：跨 NAS、危险写、真实套件返回和 TalkBack/OEM 行为需要专用测试环境。
- 发布：未完成 Release/R8、仪器 APK、lint 与设备验收前不创建发布候选。
- 发布：内部写保持关闭，不能因静态覆盖或模拟结果自动开放。

### Windows 验证边界

- 源码：partial 拆分保留 API 客户端、DI、连接生命周期和证书策略。
- 源码：Cloud Files 与高风险写在能力、恢复和系统证据不足时保持只读或关闭。
- 自动化：Windows Runner 是 x64、ARM64、xUnit 与 WinUI XAML 的唯一完整构建来源。
- 自动化：非 Windows 主机上的检查只能作为辅助证据，不能提升目标平台等级。
- 真机：Explorer、Cloud Files 回调、通知、托盘、安装、外接卷和无障碍都需要 Windows 设备。
- 真机：真实 NAS 权限、套件差异、断线、取消和最终回读需要专用环境。
- 发布：当前没有安装或商店分发动作，也不改变现有发布形态。
- 发布：如未来需签名、Identity 或安装器迁移，必须先取得用户批准并说明回滚。

### 发布状态统一口径

- “未发布”表示没有获得目标平台分发批准，不等于源码不可继续开发。
- “候选准备”只表示可开始运行既定构建和验收步骤，不表示签名或安装通过。
- “自动化可重跑”只表示命令或托管任务存在，不替代本轮实际运行结果。
- “真机未验证”不得被写成失败，也不得被自动化或模拟器结果覆盖。
- 高风险内部写在契约、能力和真实回读不足时始终保持关闭或只读。
- 认证、证书、后台、跨 NAS、File Provider 与 Cloud Files 的设备结果单独记录。
- 发布前必须确认脱敏、清理、回滚和已知限制，不保存真实用户或环境数据。
- 任何平台的签名、包名、Bundle ID、最低系统版本和依赖变更均需独立审批。
- 当前没有跨端发布动作；各平台的验证可并行，但证据不能相互替代。
- 需要用户操作的项目使用明确前置条件、步骤、预期和允许回传的脱敏信息。
- 发布结论只在对应平台的签名、设备和回滚证据同时满足后更新。

## 当前阻塞

| 阻塞 | 影响范围 | 当前安全状态 | 解锁条件 |
| --- | --- | --- | --- |
| 正式 Apple 签名与公证材料不可在仓库中提供 | macOS Beta 与 Finder 验收 | 不发布，不把无签名结果表述为正式发布验证。 | 用户在受控环境运行签名、公证、装订和 Gatekeeper 检查。 |
| 没有可授权的专用 NAS / Chat Server 环境 | 认证、私有 API、危险写、套件行为与兼容矩阵 | 内部写保持关闭；公开只读可继续开发。 | 用户提供专用环境并按脱敏步骤回传结果。 |
| 真机与平台系统行为不可由当前工作区模拟 | iPhone、iPad、Android、Windows 和桌面云盘 | 标记 `PENDING_USER_VALIDATION`，不阻塞独立源码与自动化切片。 | 用户完成设备、系统集成和辅助功能矩阵。 |
| Windows 托管构建未在本轮触发 | Windows 编译、架构构建和 xUnit 结果 | 不把静态阅读视为 Windows 通过。 | 在不含敏感信息的专用验证分支由托管 Runner 执行。 |
| Android 高负载门禁未在本轮触发 | Release/R8、仪器 APK 与 lint | 本地仅运行增量和聚焦检查。 | 在专用验证分支由托管 Runner 执行完整 Android 门禁。 |

## 最近发布周期变化

- 文档角色已收敛为入口、状态、矩阵、路线图、计划、质量基线和归档；阶段性账本已迁入历史归档。
- Android 四份人工维护审计矩阵已迁入机器数据，生成报告由 CI 比对，写操作门禁不再依赖巨型 Kotlin 文件的整文件散列。
- Android 结构债务基线开始阻止既有巨型文件增长，并要求新增超大生产文件提供明确例外理由。
- macOS Beta 就绪报告已记录本轮构建与手工验收边界；没有可以替代正式签名或真实 NAS 的结论。
- 发布状态保持保守：未完成真实环境验证的高风险能力不会因源码或模拟器结果而开放。

## 下一步（三项）

1. 继续完成 Android `DsmRepository` 与 `AppViewModel` 的剩余机械领域拆分，逐切片保持 JSON 写入口登记、任务唯一所有权和聚焦测试通过。
2. 在受控环境执行 macOS 正式签名、公证、票据装订、Gatekeeper 与真实 NAS 验收，并将缺失条件保留为 `PENDING_USER_VALIDATION`。
3. 在专用验证分支使用托管 Runner 运行 Android 全量门禁和 Windows x64/ARM64、xUnit、WinUI XAML 验证，不提交凭据或本机生成物。
