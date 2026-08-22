<!-- doc-role: platform-matrix -->
<!-- last-reviewed: 2026-08-22 -->

# 平台功能矩阵

本矩阵分开记录产品范围和验证证据。范围不是完成度，源码或自动化也不等于真实设备或
发布通过。当前状态见[当前开发进度](STATUS.md)，未来优先级见[产品路线图](ROADMAP.md)。

## 范围标签

| 标签 | 含义 |
| --- | --- |
| 核心 | 当前平台应交付的用户主流程；必须有对应安全边界与自动化。 |
| 受限 | 当前只交付明确列出的安全子集；未列出的写入、后台或系统集成继续关闭。 |
| 后续 | 有产品价值，但不进入当前实现 DAG 或 `PENDING_USER_VALIDATION`。 |
| 非目标 | 当前平台不做；不得因其他平台已有实现而自动迁入。 |

## 证据维度

| 维度 | 含义 |
| --- | --- |
| 源码 | 当前仓库中存在对应实现与明确安全边界。 |
| 自动化 | 当前平台或共享层有可重跑的测试、构建或静态门禁。 |
| 真机 | 在真实目标设备、受控账户和必要 NAS 环境完成脱敏验收。 |
| 发布 | 已满足目标平台分发、签名、安装、回滚和发布策略。 |

`未验证` 仅表示缺少该维度的证据；不能由相邻平台、其他 DSM build 或模拟器结果推断。

## 平台级证据状态

| 平台 | 源码 | 自动化 | 真机 | 发布 |
| --- | --- | --- | --- | --- |
| macOS | 已建立核心客户端和桌面云盘路径；内部危险写保持受保护。 | 本轮已通过共享 Package 与无签名构建；仓库门禁可重跑。 | 未验证：正式签名、Finder/File Provider、真实 NAS 与升级。 | 未发布：等待签名、公证、装订和 Gatekeeper。 |
| iPhone | 已建立移动核心与受限能力。 | 本轮已通过共享 Package 与 iPhone 模拟器构建。 | 未验证：真机、系统选择器、网络、VoiceOver 与真实 NAS。 | 未发布：等待 Apple Beta 决策。 |
| iPad | 已建立与 iPhone 共用的移动核心和宽屏路径。 | 本轮已通过共享 Package 与独立 iPad 模拟器构建。 | 未验证：分栏、键盘、多任务、VoiceOver 与真实 NAS。 | 未发布：不以 iPhone 结果替代。 |
| Android | 已建立 Compose 客户端、后台任务和质量门。 | 单元、增量构建与 JSON 质量基线可重跑；完整门禁由托管 Runner 执行。 | 未验证：真实设备、证书、后台、危险写和 NAS。 | 未发布：等待完整构建与设备验收。 |
| Windows | 已建立 WinUI、领域与基础设施路径；系统集成写操作保持关闭或只读。 | xUnit、XAML 和目标架构构建由 Windows Runner 执行。 | 未验证：Explorer、Cloud Files、通知、安装和真实 NAS。 | 未发布：不改变当前发布形态。 |

## SEC-002：File Station 上传认证位置

此项是 macOS 发布整改的受限安全收敛，不代表五端都已完成同一迁移。共享
`file-station.upload.synthetic-overwrite` Fixture 仍记录 Android 的旧 URL 认证位置；它不能
降低 Apple 的 URL 凭据禁止要求。

| 平台 | 当前证据与范围 |
| --- | --- |
| macOS | Apple 共享网络层已禁止文件读取和上传 URL 携带会话或 Token，并有合成请求测试；真实 DSM、重定向和发布环境仍待验收。 |
| iPhone / iPad | 与 macOS 复用 Apple 网络层；本轮没有运行单独移动构建或真机验证。 |
| Android | File Station 上传仍使用 URL 认证字段，测试也明确记录该现状；迁移需要独立授权、契约更新和 Android 门禁。 |
| Windows | File Station 上传 URI 已不含会话或 Token，使用 Cookie、Header 和 multipart；本轮只读核实，未执行 Windows 发布验收。 |

## 用户能力范围

| 能力 | macOS | iPhone | iPad | Android | Windows |
| --- | --- | --- | --- | --- |
| 登录、会话、安全存储 | 核心 | 核心 | 核心 | 核心 | 核心 |
| 多 NAS、QuickConnect 与证书确认 | 核心 | 受限 | 受限 | 核心 | 受限 |
| 文件浏览、搜索与预览 | 核心 | 核心 | 核心 | 核心 | 核心 |
| 文件上传、下载与前台传输 | 核心 | 受限 | 受限 | 核心 | 受限 |
| 文件复制、移动、回收站与分享 | 核心 | 受限 | 受限 | 核心 | 受限 |
| 文本编辑与复杂批量管理 | 核心 | 非目标 | 非目标 | 受限 | 受限 |
| Photos 浏览、分享与基础管理 | 核心 | 核心 | 核心 | 核心 | 受限 |
| 自动照片备份 | 后续 | 后续 | 后续 | 受限 | 非目标 |
| Chat 会话与文字消息 | 核心 | 受限 | 受限 | 核心 | 受限 |
| Chat 附件、提醒、定时与投票 | 核心 | 受限 | 受限 | 核心 | 后续 |
| Chat 加密、语音与实时通话 | 后续 | 非目标 | 非目标 | 后续 | 非目标 |
| Download Station 基础任务 | 核心 | 受限 | 受限 | 核心 | 受限 |
| Download Station 设置、RSS、批量与删除数据 | 受限 | 非目标 | 非目标 | 受限 | 后续 |
| Container Manager / VMM 只读摘要 | 核心 | 受限 | 受限 | 受限 | 受限 |
| Container / VMM 生命周期、删除与控制台 | 受限 | 非目标 | 非目标 | 受限 | 后续 |
| NAS 健康、存储与服务只读摘要 | 核心 | 受限 | 受限 | 核心 | 受限 |
| NAS 账户、网络、套件、电源与磁盘写入 | 受限 | 非目标 | 非目标 | 受限 | 后续 |
| Desktop Cloud Drive / File Provider / Cloud Files | 核心 | 非目标 | 非目标 | 非目标 | 受限 |
| 常驻后台传输、系统通知与系统级集成 | 受限 | 后续 | 后续 | 受限 | 受限 |

## 安全开放规则

| 范围 | 必要条件 | 未满足时的行为 |
| --- | --- | --- |
| 公开写 API | 版本化契约、权限检查、确认、重复提交保护和结果回读。 | 拒绝提交并提供恢复路径。 |
| 内部只读 API | 私有 API 记录、能力探测、可失败降级和脱敏 fixture。 | 不阻断无关主流程。 |
| 内部写 API | 已记录 DSM/套件版本、专用环境行为验证和最终状态复查。 | 默认关闭。 |
| 认证与证书 | 平台安全存储、会话隔离和用户可理解的确认流程。 | 不显示秘密，不绕过证书校验。 |
| 后台、跨 NAS、File Provider / Cloud Files | 唯一所有者、取消语义、恢复策略和平台系统验收。 | 保持前台、只读或能力门保护。 |

## 取舍说明

- macOS 是业务语义与安全行为基准，不是 iPhone、iPad 或 Windows 的逐像素模板。
- iPhone 和 iPad 只实现本矩阵中的核心或受限结果；桌面悬停、右键、菜单栏和常驻进程不
  因共享代码存在而进入移动范围。
- Android 的功能范围由 Android 专项计划单独维护；本矩阵只约束跨端安全语义和证据表述。
- Windows 以完整业务语义对齐为目标，但遵循 WinUI、键鼠、触控、窗口和资源管理器习惯。
- “后续”和“非目标”不应被写进发布待办或真机验收清单；它们需要单独产品与契约决策。

## 相关文档

- [Android 长期计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)
- [Apple 移动端长期计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [Windows 长期计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [macOS 对齐总控计划](../development/MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)
- [DSM 兼容矩阵](../compatibility/DSM_COMPATIBILITY_MATRIX.md)
- [发布与手工验收历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)
- [macOS 首个 Beta 就绪报告](../quality/MACOS_BETA_READINESS_ZH.md)
