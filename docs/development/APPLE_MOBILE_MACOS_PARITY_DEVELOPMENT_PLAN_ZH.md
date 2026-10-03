<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-03 -->

# iPhone 与 iPad 移动精选功能长期计划

## 置顶读取更正（2026-10-03）

共享 Apple 已改用 Post.search 的数字 in 数组限定置顶会话；iPhone/iPad 均保持既有受限能力，不新增本轮桌面入口。 参数、失败语义与五端边界见[消息交互记录](../api/discovery/endpoints/chat-message-interaction.md#2026-10-03-置顶搜索修正)。


## Chat 共享增量影响（2026-10-03）

共享 Apple 网络修正历史定位分页、投票创建对象和 props.vote 解析，领域模型添加可选线程/编辑/阅读字段与默认拒绝的新方法。本轮 iPhone/iPad 保持现有受限聊天能力，未增加搜索、编辑、投票参与、录音、常驻通知入口或权限，也不把这些尚未实现的能力列为 PENDING_USER_VALIDATION。未来需要移动端独立范围授权，并采用触控消息菜单、系统麦克风/媒体、前台阅读同步及系统后台约束；不能复制桌面常驻连接保证。两种设备本轮范围相同，替代路径为官方 Chat；本轮共享回归与模拟器构建结果见[功能账本](MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md)，协议以[消息交互契约](../api/discovery/endpoints/chat-message-interaction.md)为准。


## NAS 管理共享增量与移动取舍（2026-10-03）

共享 Apple 增加套件目录/安装模型、Repository 默认不支持方法以及内存压缩/电源计划保存语义；旧移动实现保持源码兼容。本轮未增加 iPhone 或 iPad 页面，二者范围一致：内存压缩、电源计划、套件安装/卸载/自动更新与来源信任等长流程运维均为**当前不做**，不加入移动 DAG，也不标为 PENDING_USER_VALIDATION。用户目标由现有健康/服务摘要加浏览器 DSM 管理替代；不承诺移动后台持续安装监控或照搬桌面表单。共享读取后续需同步 enable_zram、available_operation 对象及正确防火墙通知含义，并继续做 macOS 回归。证据与契约见 [NAS 设置账本](NAS_SETTINGS_WEB_AUDIT_20261002_ZH.md)。

同日反馈修复补充：套件预检成功可以没有 data；Setting.get 的 update_channel 为 Boolean，set 仍为 stable/beta，单卷 default_vol 可缺省。macOS 已修正并同步应用实际加载的双语资源；其他平台实现范围保持上述取舍。官方单个 MediaServer 更新已成功，但不能代替任何目标客户端的真实提交验收。详见[反馈修复账本](PACKAGE_CENTER_FIX_20261003_ZH.md)。 后续确认 system/system_hidden 可以缺省普通存储列表；安装准备取消须丢弃迟到结果，已提交安装只关闭窗口后台继续。照片过期操作反馈修复仅涉及 macOS 模型，不改变五端照片读取/写入契约。见[二次反馈账本](PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)。

## File Station 共享接口增量影响

高级搜索/索引报告、分享日期/密码/增强选项、包内分页/选择解压、任务控制和权限/ISO/VFS/设置类型，以及目录来源、主题图片和临时云授权类型均为共享兼容增量；旧签名复用同一实现，分享可选字段兼容旧数据，缺失新能力显式拒绝。iPhone/iPad 本轮仅验证共享代码及通用工程构建，不新增界面、默认私有写或移动 DAG。后续目录上传、基础分享、触控筛选仍按 Files/前台/系统分享的核心或受限范围评估；ACL、ISO、桌面连接与套件管理仅作为契约参考，未排入移动实现或真机待办，当前替代路径为 DSM 官方管理入口，iPhone/iPad 本轮范围相同。详见 [File Station 账本](../../apple/Apps/DsmMac/README.md)。


## Office 本机编辑的移动范围

macOS 已实现 Office 系统预览和本机应用编辑自动回传；该增量只在 macOS 展示及会话层，不改变共享 `PreviewKind`、网络协议或移动端预览能力。iPhone/iPad 本轮均未新增此功能，尤其不引入持续监测其他应用保存或后台常驻回传。移动端继续通过既有前台下载、系统分享/另存将文件交给兼容应用，回传由用户主动上传；不承诺外部编辑保存自动回到 NAS。两端范围相同，未实施的自动回传不列为 `PENDING_USER_VALIDATION`，后续须先明确移动生命周期与用户结果，再单独排入计划。macOS 证据见 [Office 账本](../../apple/Apps/DsmMac/README.md)。

## 目标与范围

本计划定义 iPhone 和 iPad 的移动交付边界。macOS 是业务语义和安全行为基准，但不是移动
页面模板；移动端只实施[平台功能矩阵](../progress/PLATFORM_MATRIX.md)中明确的核心或受限
结果。当前状态见[开发进度](../progress/STATUS.md)，已结束的跨端对齐记录见
[历史归档](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。

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
| Photos | 核心 | 核心 | Synology Photos 浏览、筛选、预览、原件保存／系统分享和个人单项删除；范围以照片计划为准，自动备份为后续。 |
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

- Photos 已迁移到 `Features/Photos/MobileSynologyPhotos*`，复用现有 Apple 网络和照片模型；触控筛选、系统保存／分享代替桌面交互。完整能力、非目标和设备验收只维护在[照片计划](NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。
- Apple Build 分别在 iPhone 与 iPad 模拟器执行移动合成回归并上传结果；自动备份、Photos 上传／相册编辑不因旧文件导入组件仍存在而进入本轮范围。
- Chat 只推进已记录的文字、单附件和低风险动作；提交未知、取消或回读不一致只核对，
  不自动重放。
- 真实 Chat Server、选择器、大附件、系统权限和无障碍行为均后置给用户验证。

### M4：只读管理与发布收口

2026-09-20 VMM 同类读取语义修正：原来把 autorun 作为开关，会混淆恢复原状态与
开机。共享启动策略和 iPhone/iPad 详情改为三态/未知投影，继续原生 LabeledContent；
七字段隐私白名单将 autoStart 布尔替换为 startupBehavior，不新增身份、事件或写
方法。Mac 对应源码修复与官方只读证据见 Windows 持续账本和 VMM 发现记录。两种
设备范围相同，不引入桌面创建/编辑/控制台；对应 Apple 集成构建及回归已记入[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)，真实 NAS 与设备行为仍待验证。

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


## Photos 新增共享能力的范围

macOS 后续管理契约见[照片 API](../api/reference/photos.md)，不逐波复制施工记录。iPhone/iPad 仍保持上表范围；上传、相册/人物/目录管理、系统设置、常驻预览转换及重启恢复不因共享协议存在而进入移动实现或 `PENDING_USER_VALIDATION`。两端均可通过已有保存/分享及 DSM 官方界面完成范围外需求；未来增量先明确移动用户结果、生命周期及降级。

2026-10-03 容器契约补充：Registry.search 必须固定 v1（v2 实测 103）；下载任务 1202 为已观察的 Docker 失败路径，传输读取失败应保留原任务自动恢复。详见 `MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md` 和当日发现记录。本端未新增功能或私有写开放结论；Apple 共享层另做构建回归。
