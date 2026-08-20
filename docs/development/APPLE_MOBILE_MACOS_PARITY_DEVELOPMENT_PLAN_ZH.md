<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-08-20 -->

# iPhone 与 iPad 移动精选功能长期计划

## 目标与范围

本计划定义 iPhone 和 iPad 的移动交付边界。macOS 是业务语义和安全行为基准，但不是移动
页面模板；移动端只实施[平台功能矩阵](../progress/PLATFORM_MATRIX.md)中明确的核心或受限
结果。当前状态见[开发进度](../progress/STATUS.md)，已结束的跨端对齐记录见
[历史归档](../archive/2026-h2/CROSS_PLATFORM_PARITY_HISTORY.md)。

### 移动端必须保持的原则

- 使用 SwiftUI、系统返回、触控、系统分享、Files/Photos、系统选择器和移动后台规则。
- 不复制桌面悬停、右键、双击、菜单栏、常驻进程或复杂长流程运维。
- iPhone 优先单手、随身、短会话；iPad 在可用宽度下提供双栏、键盘和并列详情，但不超出
  已批准移动范围。
- 用户可见内容使用英语和简体中文资源；动态文字、VoiceOver、降低动效、浅色/深色和
  触控是所有页面的基础要求。
- 没有稳定契约或真实行为证据的内部写操作默认关闭，不以“macOS 已有实现”解除保护。

## 当前核心与受限能力

| 领域 | iPhone | iPad | 边界 |
| --- | --- | --- | --- |
| 登录与会话 | 核心 | 核心 | 平台安全存储、会话隔离、证书确认；真实设备与 NAS 待验收。 |
| Files | 核心 | 核心 | 浏览、预览、用户主动前台传输和明确列出的安全文件操作。 |
| Photos | 核心 | 核心 | 浏览、预览、主动导入/分享和基础管理；自动备份为后续。 |
| Chat | 受限 | 受限 | 文字、单附件和少量明确操作；语音、加密、复杂管理和后台实时为后续或非目标。 |
| Download Station | 受限 | 受限 | 常用单任务和只读信息；全局设置写、批量和删除数据不进入移动范围。 |
| NAS 摘要 | 受限 | 受限 | 健康与服务只读摘要；复杂运维、网络、账号、电源和磁盘写入不进入移动范围。 |
| Container / VMM | 受限 | 受限 | 隐私白名单只读摘要；生命周期、网络、删除和控制台不进入移动范围。 |
| Activity | 核心 | 核心 | 前台任务与 NAS 任务的可理解投影；不承诺后台常驻。 |

## 共享代码边界

```text
apple/Packages/DsmCore/       领域模型、协议、结果语义
apple/Packages/DsmNetwork/    HTTP、会话、能力与 Repository
apple/Packages/*Feature/      Files、传输和可复用特性
apple/Apps/DsmMobile/         iPhone/iPad SwiftUI 组合根和平台适配
apple/Apps/DsmMac/            只读 macOS 参考实现
```

- 共享 Package 只能做向后兼容的增量修改，保持公开协议、actor、会话和错误类型。
- 每次共享 Package 变化同时运行 `swift test --package-path apple` 和 macOS 回归。
- `apple/Apps/DsmMac/**` 不是移动对齐任务的可写范围。如需修改其中 Workspace、NAS
  Administration View、WorkspaceModel 或 NasAdministrationModel，必须先向用户请求授权。
- 移动 View 与 Model 拆分先保持 `@MainActor`、`ObservableObject`、`@Published` 顺序、
  Binding、View identity、`task`、`onChange`、sheet/popover 和传输取消恢复语义。

## 实施顺序

### M0：范围和回归护栏

- 维护 iPhone/iPad 的核心、受限、后续和非目标矩阵。
- 为每个切片记录 macOS 证据路径、移动替代、契约依赖、安全级别、自动化与真机等级。
- 保持共享 Package 和移动组合根的单一修改范围；并发时先核对差异再写入。

### M1：会话、Shell 与可访问性

- 保持 profile、会话、能力、导航和迟到结果的隔离。
- iPhone 使用清晰的返回和单栏路径；iPad 按可用宽度切换为双栏，不固定设备型号断点。
- 页面覆盖加载、空内容、筛选后为空、错误与正常内容；不适用状态要有产品原因。

### M2：Files、传输与 Activity

- 保持用户主动、可取消的前台传输，明确提交前取消和提交后核对的区别。
- Files 预览、分享和系统另存遵循 iOS/iPadOS 原生流程；不引入桌面常驻任务模型。
- Activity 区分 App 发起任务和 NAS 服务器任务，不能把读取失败或后台未知状态写成成功。

### M3：Photos 与受限 Chat

- Photos 保留精简浏览、查看、主动导入/分享和已批准的管理操作；自动备份单独决策。
- Chat 只推进已记录的文字、单附件和低风险动作；提交未知、取消或回读不一致只核对，
  不自动重放。
- 真实 Chat Server、选择器、大附件、系统权限和无障碍行为均后置给用户验证。

### M4：只读管理与发布收口

- Download Station、NAS、Container 和 VMM 保持当前受限只读摘要；新增写能力需要独立
  契约、安全和验收切片。
- 运行 iPhone/iPad 模拟器构建、共享 Package 和 macOS 回归；不把模拟器结果写成真机通过。
- 将签名、安装、TestFlight、真实设备、真实 NAS、网络切换和辅助功能记录为
  `PENDING_USER_VALIDATION`。

## 验证与发布

| 验证层 | 可在当前环境执行 | 需要用户或正式环境 |
| --- | --- | --- |
| 共享逻辑 | Swift Package 测试、fixture、协议和错误语义。 | 真实 DSM/套件字段、权限与时序。 |
| iPhone / iPad UI | 对应模拟器构建与可访问性代码检查。 | 触控、分栏、键盘、系统选择器、VoiceOver、动态文字。 |
| 认证与传输 | 取消、迟到结果、会话隔离和状态机测试。 | Keychain、网络切换、前后台、系统限制和真实文件。 |
| 发布 | 无签名构建与候选准备。 | 签名、TestFlight、安装、升级、回退和正式设备矩阵。 |

用户验证回传仅包含平台/系统类别、步骤、预期和实际用户可见结果、清理结果和脱敏失败
语义。不得回传设备名称、账号、NAS 地址、文件路径、Cookie、SID、SynoToken 或原始响应。

## 当前不做

- macOS 专有复杂运维、菜单栏、常驻后台、File Provider 和桌面云盘映射；
- 未经独立产品和权限决策的自动照片备份、长期后台传输、iPad 多窗口；
- Chat 语音、加密、实时通话、多附件和未经验证的服务器管理写操作；
- Container/VMM 生命周期、网络、删除、控制台和其他高风险内部写；
- 将桌面“后续”能力写进移动真机待办，或用 `PENDING_USER_VALIDATION` 掩盖范围外工作。
