<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-20 -->

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
设备范围相同，不引入桌面创建/编辑/控制台；共享、Mac 与移动回归待 Apple 工具链。

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

## 2026-09-29 Photos macOS 增量对齐影响

用户已授权增量扩展上传、相册/分享管理、标签/评级/日期、移动/复制共享契约。完整账本见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`，接口证据见 `docs/api/discovery/endpoints/photos-management.md`。新增写方法默认关闭，仅有官方静态结构和合成测试，不升级为真实 NAS 兼容结论。macOS 批量删除、月份稳定与自动核对沿用既有删除门禁；新增批量保存使用原有只读接口。iPhone/iPad 共用 Apple 协议的默认不支持实现，保持既有单项删除界面；Android/Windows 仅记录影响，未改代码或开放新入口。未完成的网页能力与验证条件在账本明确列出，不计作完整对齐。

2026-09-29 后续明确授权：用户要求取消新增照片功能的默认禁用。Apple 实际 Photos Repository 已移除人工能力白名单，macOS 按真实接口支持开放上述功能；保留权限、确认与结果校验。其他端 UI/存储仍未修改；接口开放不能表述为跨版本验证通过。专用合成图片/相册的网页验证与最新包记录见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md` 末尾。


### 2026-09-29 Photos 后续波次

iPhone/iPad 影响：SynologyPhotoCollection.thumbnail 为可选增量，初始化默认 nil；SynologyPhotosServing.thumbnail(for: collection) 有默认不支持实现。共享 Model 新增上传队列，但移动 UI 未接入；macOS 队列不自动扩大移动端范围，无持久化迁移。


### 2026-09-29 Photos 标签与日期增量

iPhone/iPad 影响：共享管理命令增量 createTag/shiftDates、tagCreation 能力及结果可选 tag。结果初始化默认参数保持源兼容，枚举穷尽分支需包含新增命令；共享 Model 的部分完成续做固定原始目标。移动 UI、存储和权限不变。


### 2026-09-29 Photos 目录上传共享影响

共享 Apple 领域新增 folders/createFolder 和默认 nil 的结果 folder，Repository 按实际能力开放；共享 Model 增加进程内目录创建队列。iPhone/iPad 本轮不增加目录选择 UI，不迁移桌面拖放/书签或存储；移动端目录导入范围仍由专项计划决定。macOS 109 项 XCTest 与 6 项本地化测试通过；本轮未运行 iOS/iPadOS 构建，不能以 macOS 结果代替。


### 2026-09-29 条件相册增量

共享 Apple 领域增量 conditionAlbums/createConditionAlbum/setAlbumCondition、条件值和集合 isConditional（默认 false）；服务读取方法有默认显式不支持实现。共享 DsmJSONValue 添加 decimal/null，原请求编码不变。iPhone/iPad 本轮无新 UI、无存储变更，未运行移动构建。macOS 回归不能代替移动构建；移动条件编辑范围仍按专项计划取舍。

回滚可移除条件相册入口、命令和新增默认字段/方法，既有普通相册、时间轴和上传流程保留；不迁移已有持久化。完整证据见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。


### 2026-09-29 分享现状与访问方式增量

macOS 接入只读分享快照、当前设置初始化、仅受邀者模式、已有保护标记与复制链接；不修改时不提交，保存校验原快照并保留密码/有效期。公开访问只有查看/下载，upload 是具名成员角色。新增领域 albumSharing 与 shareAlbum 可选快照，旧调用默认兼容；不改持久化、权限或工具链。iOS/iPadOS 共享领域受影响但无新 UI、未运行移动构建；Android/Windows 本轮只同步契约影响，不改实现。密码/有效期编辑与成员增删改仍未完成，NAS 写入为 PENDING_USER_VALIDATION，无人工验证白名单。回滚移除新方法/快照/入口即可，无数据迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 和 photos-management.md。


### 2026-09-29 Photos 分享成员增量

macOS 已接入用户/群组候选、成员添加/移除与角色调整；type+id 识别身份，按原快照计算差量，保存后核对完整角色名单。普通相册成员可上传，条件相册不提供上传角色。未知列表不当空名单，原未知角色不静默降级，原密码/有效期保留，关闭状态不意外启用。新增共享领域成员类型、sharingRecipients 默认方法和 shareAlbum.members 可选参数；无存储/权限/工具链变更。iOS/iPadOS 共享领域增量但无新 UI、未运行移动构建；Android/Windows 仅同步影响。真实权限写入 PENDING_USER_VALIDATION，不设验证白名单。回滚移除成员增量，不影响基本分享。高级分享剩余密码与有效期编辑，详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 Photos 人物命名与合并增量

macOS 人物卡片接入命名/清空名称和合并，表单显示人物封面、名称与照片数量；独立按真实能力开放。新增共享领域 peopleNames/peopleMerge、renamePerson/mergePeople、managementPeople、结果 person/removedPersonIDs 和分类缩略图默认方法，无存储格式变更。合并前后核对照片集合、目录权限和目标快照，结果自动确认，同操作不重发；更新当前列表而不跳到最新照片。分类封面使用当前分类列表的授权缩略图，避免把人物编号用于相册查询。iOS/iPadOS 共享领域受影响但无新增 UI、未运行移动构建；Android/Windows 仅更新影响计划。真实 NAS 人物写入 PENDING_USER_VALIDATION，无人工禁用/验证白名单；人脸分离、封面和识别纠正仍未完成。回滚移除人物入口/命令/结果增量，既有照片流程保留；无依赖、权限或持久化迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。
