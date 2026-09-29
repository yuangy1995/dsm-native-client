<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-15 -->

# Android 原生客户端长期计划

## 用途与事实来源

本计划记录 Android 后续源码拆分、验证和发布条件，不记录动态完成率、CI 标识或历史测试
数量。当前状态见[开发进度](../progress/STATUS.md)，跨端范围见[平台功能矩阵](../progress/PLATFORM_MATRIX.md)，
已结束的对齐记录见[历史归档](../archive/2026-h2/ANDROID_ALIGNMENT_HISTORY_82_89.md)。

源码、契约、脱敏 fixture、自动化与可重现命令是事实来源；真实 NAS、签名或真机未执行时
必须明确标记 `PENDING_USER_VALIDATION`，不得把模拟器或静态阅读写成通过。

## 不变量

- 保持 `DsmRepository` 为兼容门面，不能改变公开签名、DSM API 名称/版本/参数、错误语义
  或 `MutationResult` 映射。
- 保持持久化键、状态顺序、StateFlow 身份、导航、WorkManager 唯一任务名以及取消、重试、
  退出和恢复语义。
- 不新增 Gradle 模块、第三方依赖、最低系统版本、包名、Bundle ID、签名配置或数据格式。
- 写操作必须保留确认、权限检查、重复提交保护和最终状态校验；未验证内部写默认关闭。
- 用户可见文案只通过英语和简体中文资源提供，不能加入 Kotlin/Compose 硬编码显示文案。

## 当前代码边界

```text
AppViewModel.kt                 Compose 兼容入口与跨领域协调
ChatFeatureModel.kt             Chat 读取、轮询、实时连接与资料代次所有权
NasAdministrationFeatureModel.kt NAS 设置读取 Job、代次与同步边界所有权
data/DsmRepository.kt           兼容门面与共享网络能力
data/downloads/                 已拆出的 Download Station Repository
data/container/                 已拆出的 Container Repository
data/PhotoRepository.kt         File Station 照片文件／备份兼容能力
data/SynologyPhotos*.kt         正式 Synology Photos Repository 与门面委托
photos/SynologyPhotosSession.kt 照片模型、会话与父作用域的唯一所有者
PhotoBackup*.kt                 照片备份与唯一后台任务所有权
*ViewModelState.kt              按领域状态与纯策略函数
ui/                             Compose 页面与组件
```

`AppViewModel` 和 `DsmRepository` 已是结构债务热点。任何拆分都应缩小其行数，不得让
既有巨型文件增长；新生产 Kotlin 文件超过行数上限时必须在质量基线中声明清晰理由。

`ChatFeatureModel` 只拥有 Chat 的读取、轮询、实时连接、本地已读叠加和资料代次；Chat 写操作仍在
`AppViewModel` 的既有确认、权限、重复提交和结果复查边界中。`NasAdministrationFeatureModel` 只拥有
NAS 设置读取 Job、请求代次及其与设置刷新共用的同步边界；其他 NAS 管理写操作仍通过兼容门面执行。
二者均直接发布既有 `WorkspaceState`，不复制 UI 状态、公开方法、持久化键或 WorkManager 名称。

## 质量基线

[Android 质量基线](../quality/ANDROID_QUALITY_BASELINE_ZH.md) 由
`tools/codex/android_quality_baseline.json` 生成，记录：

- 每个写调用点的调用文件、所属函数、`Result` 方法、开放状态、适用场景和测试证据；
- 页面五态、点击目标与显式时间动效的机器数据；
- 既有大文件上限和新增超大文件例外；
- 对新增或移动写入口的人工审查要求，而不是整文件 SHA-256 比较。

修改相关代码前后均运行：

```bash
python3 tools/codex/generate_android_quality_baseline.py --check
python3 tools/codex/check_android_write_test_matrix.py
python3 tools/codex/check_android_page_state_matrix.py
python3 tools/codex/check_android_touch_targets.py
python3 tools/codex/check_android_motion_audit.py
python3 tools/codex/check_android_structure_debt.py
python3 tools/localization/check_localization.py
```

## 源码拆分顺序

### 1. DsmRepository 共享底座

先抽出以下无 UI 依赖的内部组件，并由门面委托：

1. response decoder；
2. request builder；
3. capability resolver；
4. mutation verifier。

组件只接受现有网络、会话和模型依赖。不得复制请求、增加 fallback、提高 API 版本或改变
参数编码。每次移动后运行受影响 fixture、契约和 Repository 聚焦测试。

### 2. 领域 Repository

在共享底座稳定后，按以下顺序从门面提取实现：

1. VMM；
2. NAS Administration；
3. Chat；
4. File Station。

正式 Photos 路由已按[照片计划](NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)使用 `SynologyPhotosRepository`；`PhotoRepository` 只保留文件／备份兼容范围，不回退旧扫描库。复用既有 `DownloadStationRepository` 和 `ContainerRepository`，不再为
同一能力建立平行 Repository。门面仅保留向后兼容的委托；每个领域均保持相同 API 名称、
版本、参数和 `MutationResult` 语义。

### 3. AppViewModel 任务所有权

已迁移 Transfer、Photo Backup、Chat 读取/实时会话和 NAS 设置读取等 Job、锁及序列号所有者明确的
路径。后续依次迁移：

1. Files；
2. Downloads；
3. Container；
4. VMM；
5. Chat 与 NAS Administration 中未迁移的高风险写操作，仅在既有安全契约可独立验证时拆分。

每个任务只保留一个 owner。迁移时必须证明 `onCleared`、取消、重试、进程恢复、迟到结果
拒绝、持久化和 WorkManager 名称均未改变。跨 NAS、后台、认证和危险写路径在平台构建或
实机验收前需要额外只读对抗复核。

### 4. Compose 机械拆分

在状态和事件边界稳定后，按“状态输入 / 事件输出”机械拆分 Chat、Files 和 Photos 大型
页面文件。拆分不改变布局、文案、动效、导航、可访问性或交互。

每个页面继续覆盖加载、空内容、筛选后为空、错误和正常内容。新增页面、弹窗、自定义点击
或时间动效必须先更新 JSON 基线与生成报告。

- [x] 每页覆盖加载、空内容、筛选后为空、错误和正常内容五种状态；

## 验证策略

| 范围 | 本机 | 托管 Runner | 用户验证 |
| --- | --- | --- | --- |
| 纯 Kotlin / Repository | 聚焦单测、fixture、契约与增量编译。 | 完整 JVM 与 Release/R8。 | 仅真实 DSM/套件行为。 |
| Compose | 静态质量门、聚焦页面策略测试。 | Debug、仪器 APK 与 lint。 | TalkBack、动态字体、触控、横竖屏与 OEM 行为。 |
| WorkManager / 传输 | 取消、唯一任务名、恢复策略和持久化测试。 | 构建与仪器包。 | Doze、低电量、重启、系统选择器与实际后台限制。 |
| 危险写 / 私有 API | fixture、能力门、结果映射与只读对抗复核。 | 完整契约和 Android 门禁。 | 专用 NAS 的权限、断线、重复提交和最终回读。 |

完整 Android JVM、Debug、Release/R8、仪器 APK 与 lint 默认由 GitHub 托管 Runner 执行。
用户已授权仅为验证创建并推送专用 `codex/` 分支；其中不能含凭据、本机设置、临时日志或
无关更改。完成验证后应整理当前功能分支的临时提交，不改写共享历史。

## 发布与真实环境

以下项目均是 `PENDING_USER_VALIDATION`，不是源码阻塞：

- Android 真机登录、认证恢复、证书确认与网络切换；
- 真实 DSM / 套件 build 的公开与内部 API 行为；
- WorkManager、后台传输、照片备份和跨 NAS 的系统行为；
- 高风险写操作的权限、确认、重复提交保护、断线、取消和最终回读；
- TalkBack、最大字体、显示缩放、折叠屏、平板和 OEM 触控。

未验证高风险入口必须保持关闭、只读或受能力开关保护。用户回传信息只包含环境类别、
步骤、预期/实际用户可见结果和脱敏失败语义，不能包含 SID、Cookie、地址、路径、账号、
真实文件名或原始响应。

## 交接要求

每个 Android 切片结束时记录：

1. 实际修改与单一文件边界；
2. 保持的契约、状态和任务所有权；
3. 实际运行命令及结果；
4. 未验证风险与 `PENDING_USER_VALIDATION` 条件；
5. 工作区状态、剩余步骤和不得触碰的并发修改。

## 2026-09-29 Photos macOS 增量对齐影响

用户已授权增量扩展上传、相册/分享管理、标签/评级/日期、移动/复制共享契约。完整账本见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`，接口证据见 `docs/api/discovery/endpoints/photos-management.md`。新增写方法默认关闭，仅有官方静态结构和合成测试，不升级为真实 NAS 兼容结论。macOS 批量删除、月份稳定与自动核对沿用既有删除门禁；新增批量保存使用原有只读接口。iPhone/iPad 共用 Apple 协议的默认不支持实现，保持既有单项删除界面；Android/Windows 仅记录影响，未改代码或开放新入口。未完成的网页能力与验证条件在账本明确列出，不计作完整对齐。

2026-09-29 后续明确授权：用户要求取消新增照片功能的默认禁用。Apple 实际 Photos Repository 已移除人工能力白名单，macOS 按真实接口支持开放上述功能；保留权限、确认与结果校验。其他端 UI/存储仍未修改；接口开放不能表述为跨版本验证通过。专用合成图片/相册的网页验证与最新包记录见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md` 末尾。


### 2026-09-29 Photos 后续波次

Android 影响记录：后续可复用上传后按照片编号加入相册、队列分阶段失败恢复、相册缩略图可选数据与封面成员核对语义。当前仅记录契约影响，不修改 Android 代码、依赖或存储。


### 2026-09-29 Photos 标签与日期增量

Android 影响记录：未来接入 createTag/shiftDates 时需保留操作标识、标签创建与应用阶段、按原始时间快照计算偏移及剩余项续做。本轮不修改 Android 代码或持久化。


### 2026-09-29 Photos 目录契约影响

macOS 已增量接入个人空间 Folder.create v1 / get v2，层级上传先核对目录再传文件。共享语义为 folders/createFolder 与可选结果 folder；Android 本轮只记录影响，不修改代码、UI 或存储。后续对齐必须保留父目录身份、权限、同名复用、未知结果不重放语义；当前只有静态及 macOS 合成证据，不代表 Android 或 NAS 验收。


### 2026-09-29 条件相册增量

macOS 新增 conditionAlbums 与条件相册创建/编辑/读取/建议/数量语义。本轮 Android 只记录影响，不改代码/UI/存储。后续按原始条件快照冲突检测、完整字段保留、所有者/来源权限和结果核对实现等价语义；不得把合成证据计作 Android 或 NAS 验收。

回滚可移除条件相册入口、命令和新增默认字段/方法，既有普通相册、时间轴和上传流程保留；不迁移已有持久化。完整证据见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。


### 2026-09-29 分享现状与访问方式增量

macOS 接入只读分享快照、当前设置初始化、仅受邀者模式、已有保护标记与复制链接；不修改时不提交，保存校验原快照并保留密码/有效期。公开访问只有查看/下载，upload 是具名成员角色。新增领域 albumSharing 与 shareAlbum 可选快照，旧调用默认兼容；不改持久化、权限或工具链。iOS/iPadOS 共享领域受影响但无新 UI、未运行移动构建；Android/Windows 本轮只同步契约影响，不改实现。密码/有效期编辑与成员增删改仍未完成，NAS 写入为 PENDING_USER_VALIDATION，无人工验证白名单。回滚移除新方法/快照/入口即可，无数据迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 和 photos-management.md。


### 2026-09-29 Photos 分享成员增量

macOS 已接入用户/群组候选、成员添加/移除与角色调整；type+id 识别身份，按原快照计算差量，保存后核对完整角色名单。普通相册成员可上传，条件相册不提供上传角色。未知列表不当空名单，原未知角色不静默降级，原密码/有效期保留，关闭状态不意外启用。新增共享领域成员类型、sharingRecipients 默认方法和 shareAlbum.members 可选参数；无存储/权限/工具链变更。iOS/iPadOS 共享领域增量但无新 UI、未运行移动构建；Android/Windows 仅同步影响。真实权限写入 PENDING_USER_VALIDATION，不设验证白名单。回滚移除成员增量，不影响基本分享。高级分享剩余密码与有效期编辑，详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 Photos 人物命名与合并增量

macOS 人物卡片接入命名/清空名称和合并，表单显示人物封面、名称与照片数量；独立按真实能力开放。新增共享领域 peopleNames/peopleMerge、renamePerson/mergePeople、managementPeople、结果 person/removedPersonIDs 和分类缩略图默认方法，无存储格式变更。合并前后核对照片集合、目录权限和目标快照，结果自动确认，同操作不重发；更新当前列表而不跳到最新照片。分类封面使用当前分类列表的授权缩略图，避免把人物编号用于相册查询。iOS/iPadOS 共享领域受影响但无新增 UI、未运行移动构建；Android/Windows 仅更新影响计划。真实 NAS 人物写入 PENDING_USER_VALIDATION，无人工禁用/验证白名单；人脸分离、封面和识别纠正仍未完成。回滚移除人物入口/命令/结果增量，既有照片流程保留；无依赖、权限或持久化迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。
