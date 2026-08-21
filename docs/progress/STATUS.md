<!-- doc-role: status -->
<!-- last-reviewed: 2026-08-21 -->

# 当前开发进度

> 更新日期：2026-08-21

本页只记录当前源码、自动化、真实环境和发布准备状态。历史决策见
[跨端功能对齐历史](../archive/2026-h2/CROSS_PLATFORM_PARITY_HISTORY.md) 与
[Android 对齐历史](../archive/2026-h2/ANDROID_ALIGNMENT_HISTORY_82_89.md)。
当前定位仍为 RC 工程预览，不构成任何平台的发布批准。

## 五端状态

| 平台 | 源码 | 自动化 | 真机 / 真实 NAS | 发布 |
| --- | --- | --- | --- | --- |
| macOS | Files、Photos、Chat、Download Station、NAS 管理与桌面云盘路径均在源码中；高风险内部写入口保持能力门保护。 | Apple Build 覆盖共享 Package 测试、DsmMobile 通用 iOS Simulator 无签名构建、macOS 无签名构建和桌面云盘专用回归；精确提交的结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：正式签名、Finder/File Provider、真实 NAS、升级与危险写回读。 | 未发布；首个 Beta 仅准备，不得在签名与公证前分发。 |
| iPhone | 移动范围内的登录、Files、Photos、受限 Chat、Download Station 与只读 NAS 摘要已在通用工程中。 | Apple Build 的 DsmMobile 通用 iOS Simulator 无签名构建只覆盖通用工程编译，不构成独立 iPhone 启动验证；精确结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：设备登录、选择器、网络切换、VoiceOver 与真实套件行为。 | 未发布；随 Apple Beta 验收入口统一判断。 |
| iPad | 与 iPhone 共用领域与网络层，保留双栏、键盘与宽屏适配路径。 | Apple Build 的 DsmMobile 通用 iOS Simulator 无签名构建只覆盖通用工程编译，不构成独立 iPad 验证；精确结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：iPad 启动、分栏/宽屏、键盘、动态文字、VoiceOver 与真实 NAS。 | 未发布；不以通用编译替代 iPad 验收。 |
| Android | Compose 兼容入口、领域状态、后台任务和质量基线均在源码中；Container 未验证写操作继续关闭。 | Android Build 覆盖 JVM 单测、Debug APK、Release/R8、androidTest APK 构建与 lintDebug；写操作、页面五态、点击目标、动效、结构债务、本地化、fixture 与契约门禁可在仓库运行。精确提交的结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：真实登录、证书、后台、真实 NAS、危险写和多设备辅助功能。 | 未发布；自动化构建覆盖不替代仪器执行、签名、安装或升级回滚验收。 |
| Windows | WinUI、领域、基础设施与 Cloud Files 路径保留；危险写和未验证系统集成继续关闭或只读。 | Windows Build 在托管 Runner 覆盖 xUnit、WinUI x64 与 ARM64 构建；精确提交的结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：Windows 设备、Explorer/Cloud Files、通知、安装生命周期和真实 NAS。 | 未发布；不改变当前 unpackaged 形态、签名或程序集引用。 |

### macOS

- 源码状态：共享 Apple Package 是可修改范围；`apple/Apps/DsmMac/**` 仍是只读参考实现。
- 自动化状态：Apple Build 覆盖共享 Package 测试、DsmMobile 通用 iOS Simulator 目标无签名构建与 macOS 无签名构建；精确提交结论由 GitHub Checks 提供。
- 真机状态：正式签名、notarization、stapling、Gatekeeper、Finder、File Provider、真实 NAS、升级安装和危险写回读均为 `PENDING_USER_VALIDATION`。
- 发布状态：未形成可公开 Beta；候选包必须先经过正式签名与执行矩阵。

### iPhone

- 源码状态：坚持随身伴侣范围，不把复杂运维、后台常驻或桌面交互隐式迁入。
- 自动化状态：DsmMobile 通用 iOS Simulator 目标无签名构建用于通用工程编译；共享 Package 改动需要同时走 macOS 回归，未单独验证 iPhone 启动。
- 真机状态：系统选择器、前后台切换、触控、网络切换和真实 Chat Server 行为待用户验证。
- 发布状态：无 TestFlight 或公开分发动作。

### iPad

- 源码状态：双栏和宽屏路径保留在移动范围，不复制 macOS 的菜单栏或常驻进程语义。
- 自动化状态：DsmMobile 通用 iOS Simulator 目标无签名构建用于通用工程编译；未单独指定 iPad destination、启动或宽屏流程。
- 真机状态：分栏、多任务、键盘、VoiceOver、最大动态文字和真实 NAS 待用户验证。
- 发布状态：无 TestFlight 或公开分发动作。

### Android

- 源码状态：`AppViewModel` 与 `DsmRepository` 保持兼容门面；`TransferCoordinator` 已唯一持有
  前台传输 Job、下载 execution id 与后台观察 Job，`PhotoBackupCoordinator` 已持有扫描调度代次、
  Profile 与本地观察 Job。`ChatFeatureModel` 已持有 Chat 读取、轮询、实时连接、本地已读叠加和
  会话列表与每会话消息的资源 revision、会话与同名任务代次；`NasAdministrationFeatureModel` 已持有 NAS 设置读取 Job、代次和与设置刷新共用的锁。
  Chat 写操作与其余 NAS 管理写操作仍保留在门面既有安全边界内，不改变公开契约、任务语义或持久化格式。
- 自动化状态：Android Build 覆盖 JVM 单测、Debug APK、Release 构建及 R8、
  `assembleDebugAndroidTest` 和 lintDebug；androidTest APK 生成只证明测试包可生成，不等于已在真机或模拟器执行仪器测试。精确提交结论由 GitHub Checks 提供。
- 真机状态：真实仪器执行与 Android 版本矩阵、WorkManager 长时间后台、网络切换、Doze、进程重启、
  真实 DSM/NAS、认证、证书、危险写和辅助功能均为 `PENDING_USER_VALIDATION`。
- 发布状态：发布签名、安装、升级与回滚均为 `PENDING_USER_VALIDATION`；无 Play 分发，未验证内部写入口保持关闭。

### Windows

- 源码状态：保留 `IDsmApiClient`、`DsmApiClient`、DI、`HttpClient` 生命周期与证书策略；只按 partial 文件边界拆分。
- 自动化状态：Windows Build 在托管 Runner 覆盖 xUnit、WinUI x64 与 ARM64 构建；Windows 系统与设备集成仍待验证，精确提交结论由 GitHub Checks 提供。
- 真机状态：Explorer、Cloud Files、通知、安装、托盘、外接卷和真实 NAS 待用户验证。
- 发布状态：不创建安装包、不变更签名策略、不发布。

## 五端验证边界

### macOS Beta 准备

- 源码：共享 Package 可以继续收敛网络和领域实现；DsmMac App 保持只读。
- 源码：桌面云盘所有改变继续保持只读、安全失败或能力门保护。
- 自动化：Apple Build 覆盖共享 Package 测试与无签名 macOS 构建；精确提交结论由 GitHub Checks 提供。
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
- 自动化：DsmMobile 通用 iOS Simulator 目标无签名构建只验证通用工程可编译，不构成独立 iPad destination、启动或宽屏组合验证。
- 自动化：共享 Package 回归与通用 iOS Simulator 构建共同覆盖修改的移动领域层。
- 真机：分栏、多任务、键盘、最大动态文字和 VoiceOver 需要真实 iPad。
- 真机：真实 NAS、网络切换、系统分享和选择器权限仍待用户验证。
- 发布：没有独立 iPad 发布批准；随 Apple Beta 统一判断。
- 发布：后续多窗口与后台候选不属于当前分发范围。

### Android 验证边界

- 源码：写入口清单、页面五态、触控、动效和结构债务已由 JSON 基线保护。
- 源码：领域拆分只减少门面责任，不改变请求、持久化、状态和任务语义。
- 自动化：本机执行轻量门禁、聚焦测试和增量编译，完整 Android 任务交由托管 Runner。
- 自动化：`assembleDebugAndroidTest` 成功只表示 androidTest APK 已生成，不能替代真机或模拟器上的仪器执行。
- 自动化：fixture 脱敏、请求契约、私有 API 引用和本地化均为每个切片的基础检查。
- 真机：实际仪器执行与 Android 版本矩阵、设备认证、证书、Doze、WorkManager 长时间后台、
  网络切换和进程重启需要真实 Android。
- 真机：跨 NAS、危险写、真实 DSM/NAS 与套件返回、TalkBack/OEM 行为需要专用测试环境。
- 发布：发布签名、安装、升级、回滚与设备验收完成前不创建发布候选。
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
- “自动化可重跑”只表示命令或托管任务存在；某次提交的执行结论仅以对应 GitHub Checks 为准。
- “真机未验证”不得被写成失败，也不得被自动化或模拟器结果覆盖。
- 高风险内部写在契约、能力和真实回读不足时始终保持关闭或只读。
- 认证、证书、后台、跨 NAS、File Provider 与 Cloud Files 的设备结果单独记录。
- 发布前必须确认脱敏、清理、回滚和已知限制，不保存真实用户或环境数据。
- 任何平台的签名、包名、Bundle ID、最低系统版本和依赖变更均需独立审批。
- 当前没有跨端发布动作；各平台的验证可并行，但证据不能相互替代。
- 需要用户操作的项目使用明确前置条件、步骤、预期和允许回传的脱敏信息。
- 发布结论只在对应平台的签名、设备和回滚证据同时满足后更新。
- `Documentation & Quality Preflight` 只提供文档与质量门禁，不能作为 Apple、Android、Windows
  完整构建、签名、安装、升级、回滚、真机或真实 NAS 的发布结论；完整 Release Preflight
  仍待跨平台构建、Artifact manifest、SHA-256、签名状态和人工验收清单齐备后单独建设。

## 当前阻塞

| 阻塞 | 影响范围 | 当前安全状态 | 解锁条件 |
| --- | --- | --- | --- |
| 正式 Apple 签名与公证材料不可在仓库中提供 | macOS Beta 与 Finder 验收 | 不发布，不把无签名结果表述为正式发布验证。 | 用户在受控环境运行签名、公证、装订和 Gatekeeper 检查。 |
| 没有可授权的专用 NAS / Chat Server 环境 | 认证、私有 API、危险写、套件行为与兼容矩阵 | 内部写保持关闭；公开只读可继续开发。 | 用户提供专用环境并按脱敏步骤回传结果。 |
| 真机与平台系统行为不可由当前工作区模拟 | iPhone、iPad、Android、Windows 和桌面云盘 | 标记 `PENDING_USER_VALIDATION`，不阻塞独立源码与自动化切片。 | 用户完成设备、系统集成和辅助功能矩阵。 |
| Android 真实仪器执行与系统矩阵未验证 | Android 版本兼容、设备行为和辅助功能 | androidTest APK 已构建不被表述为仪器通过；高风险入口继续关闭或受能力门保护。 | 在专用设备或模拟器执行仪器测试，并完成 Android 版本矩阵、网络/Doze/进程重启验证。 |
| Android 发布签名与安装生命周期未验证 | 发布准备、安装、升级与回滚 | 不创建发布候选，不把 CI 构建等同于已签名或可升级安装包。 | 在受控环境完成签名、安装、升级与回滚，并回传脱敏结论。 |

## 最近发布周期变化

- 文档角色已收敛为入口、状态、矩阵、路线图、计划、质量基线和归档；阶段性账本已迁入历史归档。
- Android 四份人工维护审计矩阵已迁入机器数据，生成报告由 CI 比对，写操作门禁不再依赖巨型 Kotlin 文件的整文件散列。
- Android 结构债务基线已改为带稳定 ID 的当前行数精确 ratchet：文件可重命名但必须沿用 ID，
  文件缩短必须同步收紧，`maxLines` 与 `targetLines` 均不得相对上一基线上调；既有超限生产文件
  不得转移至新增例外、改换身份或脱离债务追踪。
- Android 传输与照片备份运行时所有权已收敛：旧 Job、旧 execution、旧观察和已切换 Profile 的
  迟到回调不能清理新任务；后台唯一工作名称与持久化格式未改变。
- Android Chat 的读取、轮询、实时连接与本地已读状态，以及 NAS 设置读取的 Job、代次与锁，
  已迁至各自的特性模型；`AppViewModel` 保持 Compose 兼容门面与既有高风险写操作边界。
- `Documentation & Quality Preflight` 已按实际覆盖范围命名；它不再被描述为完整发布预检。
- macOS Beta 就绪报告记录构建与手工验收边界；没有可以替代正式签名或真实 NAS 的结论。
- 发布状态保持保守：未完成真实环境验证的高风险能力不会因源码或模拟器结果而开放。

## 下一步（三项）

1. 继续按领域缩小 Android `DsmRepository` 与 `AppViewModel` 的剩余责任；逐切片保持 JSON 写入口登记、
   任务唯一所有权和聚焦测试通过，不迁移已验证的高风险写边界。
2. 在受控环境执行 macOS 正式签名、公证、票据装订、Gatekeeper 与真实 NAS 验收，并将缺失条件保留为 `PENDING_USER_VALIDATION`。
3. 在专用验证分支持续使用托管 Runner 运行 Android 与 Windows 完整门禁；设备、NAS、签名和安装结论仍须按
   `PENDING_USER_VALIDATION` 条件单独记录，不提交凭据或本机生成物。
