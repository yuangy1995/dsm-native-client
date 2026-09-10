<!-- doc-role: status -->
<!-- last-reviewed: 2026-09-10 -->

# 当前开发进度

本页只维护当前实现、验证缺口与下一步，不重复专项计划、历史测试数字和平台验收清单。
本次核对更新 macOS Photos 与文档组织；其他平台沿用既有记录，未在本轮重新构建或验收。
详细范围见[平台矩阵](PLATFORM_MATRIX.md)，优先级见[路线图](ROADMAP.md)，证据等级见[验证规则](../quality/VERIFICATION_LEVELS_ZH.md)。

## 五端状态

| 平台 | 源码 | 自动化 | 真机 / 真实 NAS | 发布 |
| --- | --- | --- | --- | --- |
| macOS | 已接入 Synology Photos 主流程、按能力开放个人空间单项删除；其余模块保持各自门禁。 | 共享 Swift 回归和本机 arm64 Release 测试包已有执行记录；提交级 CI 仍以 Checks 为准。 | 已有 Photos 读取及单张合成图删除证据；App 异常路径、正式签名、Finder/File Provider 仍待验证。 | 提供独立临时签名测试包；不等于正式发布批准。 |
| iPhone | 移动范围内的登录、Files、Photos、受限 Chat、Download Station 与只读 NAS 摘要已在通用工程中。 | Apple Build 的 DsmMobile 通用 iOS Simulator 无签名构建只覆盖通用工程编译，不构成独立 iPhone 启动验证；精确结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：设备登录、选择器、网络切换、VoiceOver 与真实套件行为。 | 未发布；随 Apple Beta 验收入口统一判断。 |
| iPad | 与 iPhone 共用领域与网络层，保留双栏、键盘与宽屏适配路径。 | Apple Build 的 DsmMobile 通用 iOS Simulator 无签名构建只覆盖通用工程编译，不构成独立 iPad 验证；精确结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：iPad 启动、分栏/宽屏、键盘、动态文字、VoiceOver 与真实 NAS。 | 未发布；不以通用编译替代 iPad 验收。 |
| Android | Compose 兼容入口、领域状态、后台任务和质量基线均在源码中；Container 未验证写操作继续关闭。 | Android Build 覆盖 JVM 单测、Debug APK、Release/R8、androidTest APK 构建与 lintDebug；写操作、页面五态、点击目标、动效、结构债务、本地化、fixture 与契约门禁可在仓库运行。精确提交的结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：真实登录、证书、后台、真实 NAS、危险写和多设备辅助功能。 | 未发布；自动化构建覆盖不替代仪器执行、签名、安装或升级回滚验收。 |
| Windows | WinUI、领域、基础设施与 Cloud Files 路径保留；危险写和未验证系统集成继续关闭或只读。 | Windows Build 在托管 Runner 覆盖 xUnit、WinUI x64 与 ARM64 构建；精确提交的结果以 GitHub Checks 为准。 | `PENDING_USER_VALIDATION`：Windows 设备、Explorer/Cloud Files、通知、安装生命周期和真实 NAS。 | 未发布；不改变当前 unpackaged 形态、签名或程序集引用。 |

## 当前工作与边界

### macOS

- 当前按用户授权修改 macOS App 并提供独立临时签名测试包；“DsmMac 只读参考”仅适用于 Windows／Apple 移动对齐任务，不能作为 macOS 自身开发的全局限制。
- Photos 当前能力、五端迁移和待完成写功能统一见[照片计划](../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。新入口不回退 File Station，其他平台旧实现尚未全部迁移或删除。
- 个人空间删除按用户授权跨 DSM／Photos 版本依接口与实际权限开放；确认、防重复和结果回读不变。其他版本仍未验证，开放不等于通过验收，也不解锁其他写操作。
- 已有真实 Photos 读取及单张新增合成 PNG 删除／刷新回读证据，见[环境索引](../api/discovery/environments/INDEX.md)；不能再笼统描述为“没有 NAS 验证环境”或“所有危险写都没有证据”。
- 本机测试包沿用独立身份及临时权限，不包含本地磁盘挂载、不自动安装或启动。正式签名、公证、升级和 Finder 验收仍须独立执行，见[Beta 就绪报告](../quality/MACOS_BETA_READINESS_ZH.md)。
- 当前源码包含尚未提交的改动；本地通过不能写成该改动已通过云端提交门禁。

### 其他平台

- Apple 移动只实现专项计划的核心／受限路径；通用 iOS Simulator 编译不证明 iPhone 或 iPad 的启动、系统选择器、宽屏或辅助功能通过。共享 Apple 网络变更仍需 macOS 回归。
- Android 保留 `AppViewModel`／`DsmRepository` 兼容门面，传输、照片备份、Chat 读取和 NAS 摘要已由现有协调器／特性模型管理。写流程保持原有安全边界，后台唯一名称和存储格式不因拆分改变。
- Android 质量基线由机器数据生成；结构债务 ID 和行数 ratchet 不得借移动文件或新增例外放宽。完整 JVM、Release/R8、androidTest APK 与 lint 交托管 Runner；APK 构建不等于仪器执行。
- Windows 保留既有 API 客户端、DI、连接及证书策略；WinUI x64／ARM64 完整构建由 Windows Runner 验证，非 Windows 本机检查不替代目标平台结果。
- 其他端的详细范围与迭代顺序分别由[Apple 移动计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)、[Android 计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)、[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)维护，不在本页重复展开。

## 待验证条件

以下使用 `PENDING_USER_VALIDATION`，只约束依赖该条件的能力，不阻塞独立源码和自动化切片。

| 条件缺口 | 影响范围与当前边界 | 验证出口 |
| --- | --- | --- |
| 正式 Apple 签名、公证与系统注册 | macOS 正式分发、Finder/File Provider；临时包不替代 | 按[桌面云盘验收矩阵](../development/MACOS_DESKTOP_CLOUD_DRIVE_SIGNED_ACCEPTANCE_MATRIX_ZH.md)执行 |
| 尚无对应目标的套件／写场景证据 | 未覆盖的认证、Chat、管理写、权限及恢复；不能用 Photos 结果类推 | 按[私有 API 发现规则](../api/discovery/README.md)逐切片记录授权、版本和脱敏结果 |
| Photos App 异常路径与其他版本 | 已开放个人空间删除；断网、重启、权限变化与恢复未验证 | 可丢弃照片取消／删除／刷新／重启；未知结果先查官方页面，反馈脱敏错误 |
| 移动端与 Windows 系统行为 | 选择器、后台、Explorer、通知、辅助功能等 | 按目标平台专项计划在真实设备或适用模拟器验证 |
| Android 仪器与发布生命周期 | 系统版本矩阵、Doze、进程恢复、签名、安装、升级与回滚 | 受控设备执行；不把构建结果当作仪器或发布验收 |

发布、隐私、权限变更审批和证据规则统一见[验证等级](../quality/VERIFICATION_LEVELS_ZH.md)、[安全基线](../security/SECURITY_BASELINE.md)及各平台验收文档。`Documentation & Quality Preflight` 只验证文档和质量门禁，不是完整发布验收。没有新公开发布批准；本机测试包与正式发布必须区分。

## 下一步

1. 按实际反馈继续修复 macOS Photos 主流程；新增上传、整理、分享写入单独拆分契约和授权，不借反馈扩大写入范围。
2. 继续各平台已有计划，Photos 迁移与 Android 结构收敛按独立文件／模块切片执行，避免共享热点交叉修改。
3. 在具备条件时补正式签名、系统集成、目标设备与真实 NAS 验证；按功能记录缺口和脱敏结果，不设置全项目等待。

历史决策和执行记录见[跨端历史](../archive/2026-h2/CROSS_PLATFORM_PARITY_HISTORY.md)、[Android 历史](../archive/2026-h2/ANDROID_ALIGNMENT_HISTORY_82_89.md)、[发布验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。
