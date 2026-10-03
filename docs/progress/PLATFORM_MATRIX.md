<!-- doc-role: platform-matrix -->
<!-- last-reviewed: 2026-10-03 -->

# 平台功能矩阵

“核心／受限／后续／非目标”表示平台产品范围，不是源码、设备或发布等级；实现与验证分开看。当前事实见[开发进度](STATUS.md)，API 参数与恢复语义见[功能参考](../api/README.md)。

## macOS 新增基线与其他端差距

| 增量 | macOS | iPhone / iPad | Android | Windows |
| --- | --- | --- | --- | --- |
| Photos 管理、上传恢复、人物/目录/相册/分享、预览转换/设置 | 已接入并修复操作错误归属/刷新残留，自动化/本机构建；真实行为按版本另验 | 两端均不进入现有移动 DAG；保留浏览/保存/单项删除与系统分享 | 尚需独立适配，本轮仅记录影响 | 后续逐项对齐，不能标成仅待真机验证 |
| File Station 高级/全文搜索、分享/收集、归档、权限、ISO/VFS、云授权、设置和任务控制 | 已接入，保留权限/确认/未知核查 | 共享兼容类型可用不等于界面已实现；目录上传/基础分享另按核心范围评估，桌面管理不进入计划 | 后续独立适配 | 后续 WinUI 增量 |
| Office 系统预览与本机保存自动回传 | 已实现与本机验证，真实编辑器/NAS 待验 | 当前非目标；下载/系统分享后用户主动上传，不监测其他 App 保存 | 本轮未接入，后续按 SAF/外部编辑器生命周期设计 | 本轮未接入，后续按文件关联/原生窗口实现 |
| NAS 设置、内存压缩、电源计划与套件中心 | 21 页核对及新增写流程；套件预检/设置解析、弹窗与资源覆盖已修复，补齐系统套件缺省位置及准备取消；客户端真实提交待验 | 复杂运维当前不做；共享兼容模型不等于移动页面已实现，使用只读摘要与浏览器 DSM | 本轮未移植，后续独立授权 | 后续按 WinUI 完整切片对齐，不能把旧升级提示称为安装功能 |

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
| macOS | 已建立核心客户端和桌面挂载；指定文件夹/全部共享均可按映射启用写回，默认只读，删除须另外确认。 | 共享 Package、写回回归和无签名构建已通过；云端门禁可重跑。 | 旧版升级与只读挂载已有用户反馈；本次写回、不同架构及真实 NAS 异常场景待验证。 | 已建立签名、公证与正式更新流程，发布结果见[macOS 发布指南](../releases/MACOS_GITHUB_RELEASE_ZH.md)。 |
| iPhone | 已建立移动核心与受限能力。 | Apple Build 包含共享 Package、通用构建及独立 iPhone 模拟器合成回归；提交结果见 Checks。 | 未验证：真机、系统选择器、网络、VoiceOver 与真实 NAS。 | 未发布：等待 Apple Beta 决策。 |
| iPad | 已建立与 iPhone 共用的移动核心和宽屏路径。 | Apple Build 独立执行 iPad 模拟器合成回归并保留结果；提交结果见 Checks，不借用 iPhone 结论。 | 未验证：分栏、键盘、多任务、VoiceOver 与真实 NAS。 | 未发布：不以 iPhone 结果替代。 |
| Android | 已建立 Compose 客户端、后台任务和质量门。 | 单元、增量构建与 JSON 质量基线可重跑；完整门禁由托管 Runner 执行。 | 未验证：真实设备、证书、后台、危险写和 NAS。 | 未发布：完整构建与设备验收分开记录。 |
| Windows | 已建立 WinUI、领域与基础设施路径；云盘写回、移动/改名、删除与恢复已接入，默认只读，写入逐项授权。 | xUnit、XAML 和目标架构构建由 Windows Runner 执行。 | 未验证：Explorer、Cloud Files、通知、安装和真实 NAS。 | 未发布：不改变当前发布形态。 |

## SEC-002：File Station 上传认证位置

此项是 macOS 发布整改的受限安全收敛，不代表五端都已完成同一迁移。共享
`file-station.upload.synthetic-overwrite` Fixture 仍记录 Android 的旧 URL 认证位置；它不能
降低 Apple 的 URL 凭据禁止要求。

| 平台 | 当前证据与范围 |
| --- | --- |
| macOS | Apple 共享网络层已禁止文件读取和上传 URL 携带会话或 Token，并有合成请求测试；真实 DSM、重定向和发布环境仍待验收。 |
| iPhone / iPad | 与 macOS 复用 Apple 网络层；移动模拟器证据独立保存，真实认证/上传仍待设备与 NAS 验证。 |
| Android | File Station 上传仍使用 URL 认证字段，测试也明确记录该现状；迁移需要独立授权、契约更新和 Android 门禁。 |
| Windows | File Station 上传 URI 已不含会话或 Token，使用 Cookie、Header 和 multipart；本轮只读核实，未执行 Windows 发布验收。 |

## 用户能力范围

QuickConnect 区域转介：Apple 共享层（macOS、iPhone、iPad）与 Android 已接入 Windows 既有的官方 `sites` 查询语义；保留中继身份核对，不增加用户操作。逐端测试、构建与真实环境边界见[区域转介账本](../api/discovery/endpoints/quickconnect-relay-control.md)。

| 能力 | macOS | iPhone | iPad | Android | Windows |
| --- | --- | --- | --- | --- |
| 登录、会话、安全存储 | 核心 | 核心 | 核心 | 核心 | 核心 |
| 多 NAS、QuickConnect 与证书确认 | 核心 | 受限 | 受限 | 核心 | 受限 |
| 文件浏览、搜索与预览 | 核心 | 核心 | 核心 | 核心 | 核心 |
| Office 系统预览与本机应用编辑自动回传 | 核心：已接入，真实编辑器/NAS 待验 | 本轮非目标 | 本轮非目标 | 仅记录影响，本轮未接入 | 后续对齐，本轮未接入 |
| 文件上传、下载与前台传输 | 核心 | 受限 | 受限 | 核心 | 受限 |
| 文件复制、移动、回收站与分享 | 核心 | 受限 | 受限 | 核心 | 受限 |
| 文本编辑与复杂批量管理 | 核心 | 非目标 | 非目标 | 受限 | 受限 |
| Photos 浏览、原件保存／系统分享与个人单项删除 | 核心 | 核心 | 核心 | 核心 | 核心 |
| 自动照片备份 | 后续 | 后续 | 后续 | 受限 | 非目标 |
| Chat 会话与文字消息 | 核心 | 受限 | 受限 | 核心 | 受限 |
| Chat 附件、提醒、定时与投票 | 核心 | 受限 | 受限 | 核心 | 受限 |
| Chat 加密、语音与实时通话 | 后续 | 非目标 | 非目标 | 后续 | 非目标 |
| Download Station 基础任务 | 核心 | 受限 | 受限 | 核心 | 受限 |
| Download Station 设置、RSS、批量与删除数据 | 受限 | 非目标 | 非目标 | 受限 | 受限 |
| Container Manager / VMM 只读摘要 | 核心 | 受限 | 受限 | 受限 | 受限 |
| Container / VMM 生命周期、删除与控制台 | 受限 | 非目标 | 非目标 | 受限 | 受限 |
| NAS 健康、存储与服务只读摘要 | 核心 | 受限 | 受限 | 核心 | 受限 |
| NAS 账户、网络、套件、电源与磁盘写入 | 受限 | 非目标 | 非目标 | 受限 | 受限 |
| Desktop Cloud Drive / File Provider / Cloud Files | 核心 | 非目标 | 非目标 | 非目标 | 受限 |
| 常驻后台传输、系统通知与系统级集成 | 受限 | 后续 | 后续 | 受限 | 受限 |

## 安全开放规则

上述 Windows“受限”不是未实现或全部关闭：Chat 已接附件、提醒、纯文字定时及无附件
投票；Download Station 已接设置、批次和已记录删除语义，不据此声称 RSS 已实现。
Container/VMM 和 NAS 专用操作范围以对应账本为准；云盘源码缺口已按上文最新复核补齐，
目标设备/真实 NAS 仍未完成；已执行云端门禁见验证历史。

2026-09-19 用户验证策略补充：Windows 已实现的 NAS 专用管理与容器网络创建/删除
不再按固定 DSM build 或行为验收常量关闭。NAS 系统写入要求当前明确管理员、
有效接口及每次确认/预检/防重复/回读；容器按套件权限处理，不强加 DSM 管理员身份。
旧无确认通用辅助、缺生产传输或未实现的功能不在开放范围。只有合成/构建证据，
不提升真实验证等级；其他四端策略和实现不因本次 Windows 调整改变。

| 范围 | 必要条件 | 未满足时的行为 |
| --- | --- | --- |
| 公开写 API | 版本化契约、权限检查、确认、重复提交保护和结果回读。 | 拒绝提交并提供恢复路径。 |
| 内部只读 API | 私有 API 记录、能力探测、可失败降级和脱敏 fixture。 | 不阻断无关主流程。 |
| 内部写 API | 已记录 DSM/套件版本、专用环境行为验证和最终状态复查。用户已明确开放的 macOS Photos、File Station、NAS 设置与 Windows 专用写入口按各功能记录执行，仍须能力／权限／确认／防重复／回读。 | 无相应授权或条件不足时关闭；未测版本不标为已验证。 |
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
