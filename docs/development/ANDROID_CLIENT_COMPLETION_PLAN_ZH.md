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


### 2026-09-29 分享有效期增量

macOS分享表单新增读取当前到期日期、设置/更改与取消期限；未编辑保留原始值，未知状态不当成不限日期。共享领域SynologyPhotoSharingState增加默认nil的expiration（Unix秒），shareAlbum增加默认nil的expiration参数，nil保留、0取消、正数设置；既有调用源兼容，所有模式匹配已同步。Repository要求确认快照、所有者权限与原修订一致，仅发送改变字段，关闭分享时编辑不启用，自动核对有效期/密码/成员。日期使用本地日末，覆盖夏令时。无数据迁移、依赖/权限变更和人工白名单。

iOS/iPadOS共享模型与网络受影响，无新界面，未运行本轮移动构建；Android/Windows仅同步契约影响，不改代码。回滚移除可选字段/参数及日期编辑控件，不影响已有分享。真实NAS写入为PENDING_USER_VALIDATION：在授权测试相册设置未来日期、取消、关闭状态编辑，并与网页核对保护和成员；断网不得重发，网页并发更改应拒绝覆盖。密码编辑、照片请求、人脸纠正、预览重建、共享空间和重启恢复仍未完成。详情见照片对齐账本和photos-management.md。


### 2026-09-29 共享空间读取适配增量

Apple Repository 接入 team_space_permission 的 entry/management 与 TeamSpace.enabled，增加 FotoTeam 时间线/目录/筛选/媒体能力发现；缩略图和大图按照片空间选择 p/t 路由，同编号不混读。entry核对目录view权限，management仅适用于共享空间；旧授权在重新核对时撤销，缺失接口不回退个人图库。未新增版本白名单、依赖、持久化或用户权限。

macOS空间选择、相册/分类作用域及共享上传/管理仍未完成，不能将网络层适配当作完整界面对齐。iOS/iPadOS共享网络实现受影响，当前无UI变更；Android/Windows仅同步协议影响。自动化覆盖授权、路由、图片、视频与原件导出；真实NAS entry/management账号和目录限制为PENDING_USER_VALIDATION，未运行本轮移动构建。回滚仅移除本轮共享读取增量，保留个人能力与既有分享有效期修改。证据及验收步骤见MACOS_PHOTOS_PARITY_20260929_ZH.md、photos-library-read.md。


### 2026-09-29 共享空间选择与上传增量

macOS 时间线/文件夹可切换个人与共享空间，切换清除旧目录、筛选和预览；上传表单/队列固定空间，支持共享目录层级导入。共享领域 upload/createFolder 新增默认 personal 的 space，Serving 增加带默认桥接的 managementFeatures(in:)；无数据格式或持久化迁移。Apple Repository 按 FotoTeam.Upload.Item 与 Folder 能力、真实权限和目标读回处理，不设人工版本白名单。共享元数据、移动复制、人物/相册来源仍未完整接入。

五端影响：macOS 已实现本切片；iOS/iPadOS 共享包源兼容，现有枚举匹配已同步，平台界面/构建未验证；Android、Windows 只记录后续空间目标与队列隔离的等价语义，未修改其实现。回滚可撤销选择器及本轮作用域扩展，个人上传保持独立。官方协议证据为 static，本地171项功能与6项本地化、2项界面测试通过不等于真实NAS写入验收；entry/management账号和共享目标写入标记 PENDING_USER_VALIDATION，详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-management.md。


### 2026-09-29 共享照片管理增量

macOS/Apple Repository接入共享评级、描述、绝对/相对日期、标签新建增删、同空间移动复制、原件删除与结果自动核对。createTag增加默认personal的space，其他照片命令由不可变目标推导空间，预检拒绝混合空间/NAS；目标文件夹表单固定原空间。后台File操作使用FotoTeam，Info状态仍统一Foto。未修改存储，无新增人工版本名单；回滚可撤销本轮作用域增量，既有个人语义保留。

五端：macOS本轮实现；iOS/iPadOS共享包关联值匹配已同步，UI和构建未运行；Android/Windows仅记录上述等价语义，不修改实现。191项XCTest（含能力发现）及6项本地化通过，合成Model覆盖共享月份编辑/删除保持位置。真实共享NAS写入证据仍为static，entry管理权限、management账号、失权/断网/回收站/任务结果列入PENDING_USER_VALIDATION，操作步骤见Photos对齐账本。共享分类/人物/相册来源、跨空间移动、其他完整对齐剩余项未宣称完成。


### 2026-09-29 照片分享密码增量

macOS与共享Apple Repository接入分享密码设置、替换和清除。shareAlbum新增默认nil的password（保留），空字符串清除、非空原样设置；沿用现有HTTPS连接策略，不新增持久化或依赖。新密码成功需update明确回执及保护状态、访问方式、成员、期限一致回读；回执丢失不能用已有保护标记确认替换，未知结果不重发。表单使用安全输入，关闭即清空草稿。

五端影响：macOS实现；iOS/iPadOS共享枚举匹配同步但未新增界面、未运行移动构建；Android/Windows仅记录待迁移语义，不修改实现。无新增版本/测试白名单，真实权限与确认仍保留。回滚移除本轮password关联值与表单即可，成员和期限独立保留。官方证据static，未做真实NAS密码写入；PENDING_USER_VALIDATION步骤、测试命令与最终结果见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`。完整照片网页对齐仍在进行中。


### 2026-09-29 照片收集请求主流程增量

macOS/Apple Repository新增收集请求创建/编辑/删除、完整快照、个人/共享目录选择、默认目录规则、addable自有/共享相册、期限与单文件大小限制。按精确passphrase读回，创建无回执不按名称追认；编辑差量与原快照冲突、删除失效核对、局部列表更新，未知不重发。完整目录路径通过Collection新增默认nil的path传递，不新增持久化或依赖。

五端：macOS接原生表单与自动核对；iOS/iPadOS共享领域/Repository增量，服务方法提供默认显式不支持以保持旧实现兼容，未新增移动UI或运行移动构建；Android/Windows仅记录待迁移语义，不修改源码。沿用用户契约授权，不设人工版本名单；NAS权限、确认、身份和结果校验保留。回滚移除请求管理入口/命令/结构和可选path即可，既有照片管理不受影响。证据仍static，真实NAS请求创建/删除及访客上传为PENDING_USER_VALIDATION；命令和结果见Photos对齐账本。收集窗口内新建相册、请求搜索及其余照片功能仍未宣称完成。


### 2026-09-29 人脸整理增量

macOS在个人空间人物照片的选择菜单接入移出人物、归入其他/新人物和设置人物封面。先按照片读取Person.list_face，以独立人脸编号选择，不把照片编号当人脸编号。移出后只有该照片在原人物中不再有其他脸时才从当前人物视图移除；原照片保留，页面与筛选不跳回时间轴。分离必须核对来源缺失且目标含相同人脸与照片对应；新人物缺回执不能按名称追认。封面须明确set_cover回执及Person.get最终cover一致。

共享契约新增SynologyPhotoFace、peopleFaces/peopleCover能力、personFaces/thumbnail读取、remove/reassign/setCover命令及结果removedFromPersonPhotoIDs；旧服务通过默认显式不支持兼容，结果字段默认空。macOS与Apple Repository实现；iOS/iPadOS共享声明可编译兼容但无新UI，移动端未构建；Android/Windows仅同步待迁移语义，未改实现。无持久化/依赖/工具链变更；回滚移除新增入口、命令、读取及字段，保留已有命名合并。真实权限、确认、身份与重复提交保护保留，不设未实测白名单。

证据为官方脚本static和本地合成验证，真实NAS验收为PENDING_USER_VALIDATION；详细命令、结果和失败记录见MACOS_PHOTOS_PARITY_20260929_ZH.md。完整图片内人脸框绘制/新增、人物显示隐藏、共享人物与其他照片功能仍在后续范围，不宣称全部复刻。


### 2026-09-29 人物显示管理增量

macOS个人空间人物页新增批量显示/隐藏、搜索与恢复隐藏入口，人物卡片菜单可直接选择原人物。隐藏不删除照片，结果局部更新，不刷新到最新日期。读取Person.list(show_hidden/show_more)，提交前后Person.get明确核对show，Person.show仅改变选中项；部分成功只更新已确认项，未知只回读不重放。人物封面同时支持unit_id/type=unit和人物编号/type=person两种结构。

共享契约增量为SynologyPhotoPersonVisibility、peopleVisibility能力/读取、setPeopleVisibility命令及结果personVisibility（默认空）；服务读取默认显式不支持保证旧实现源码兼容。macOS及共享Apple Repository实现；iOS/iPadOS仅共享声明，不新增UI且未运行移动构建；Windows/Android记录迁移影响，未改源码。无依赖、工具链或持久化变更；回滚移除本轮入口和增量声明/方法即可，已改变的人物状态可在官方网页恢复。权限、确认、重复保护和结果核对保留，不设置待实测人工禁用开关。

证据等级static及本地合成验证；PENDING_USER_VALIDATION：以少量测试人物隐藏后重新显示，确认照片仍保留、刷新后状态一致、关闭弹窗不写入；失败回传脱敏步骤与界面错误。详细本地命令及结果见MACOS_PHOTOS_PARITY_20260929_ZH.md，不能据此宣称共享人物或手工画框完成。


### 2026-09-29 图片内手工人脸编辑增量

macOS个人照片预览接入编辑人脸：加载原有框、鼠标绘制/拖动/缩放、键盘等价的居中新增与位置/尺寸滑块、归入既有或新人物、移除与撤销移除，点击保存前不写NAS。裁剪最长边256的JPEG，照片显示坐标归一化；调整既有框按新增框并完成缩略图后移除旧标记，原图保留。读取Item.list_face v6；新增Person.add_face v3返回临时编号到face_id映射；Upload.Face upload v1传multipart JPEG。归属纠正和移除沿separate/delete_face。不新增猜测API。

共享契约增量为FaceBounds/FaceRegion/NewFace/FaceChange、photoFaces读取（旧服务默认显式不支持）、manualFaces能力及editPhotoFaces命令；结果仍复用photos/completedCount。macOS与共享Apple Repository实现个人空间；iOS/iPadOS共享声明但无新UI且未构建；Windows/Android仅记录待迁移，不改代码。没有存储、依赖或工具链变更。回滚可移除入口和增量声明/方法，不回退已保存NAS状态；原图无变化，人物标记可在网页恢复。

权限、照片身份、原始人脸/目标人物快照和唯一操作编号保留；新增编号不能与旧脸冲突或错配裁剪图。未知新增回执不按同名追认，丢失上传回执只接受明确新编号下完全一致的图像，否则保留待核对且不重传。部分回执只上传明确返回项；缺新增项时不移除旧框。编辑完成局部更新照片详情，月份/选择/预览保留。真实NAS为PENDING_USER_VALIDATION，功能按实际权限/能力开放，无待实测人工禁用；版本证据仍static。


### 2026-09-29 预览重建NAS分支增量

共享契约新增previewRegeneration能力与regeneratePreviews照片快照命令，结果沿用photos/completedCount。macOS个人/共享空间选择照片后确认，依实际目录管理权限执行；Network先订阅EIO4完成事件，再标记并发起NAS重建，按明确照片编号确认结果并回读身份。明确失败才恢复对应重建标记，未知不重放；部分成功局部更新，保留月份/选择并重新读取已打开的预览。无待实测人工白名单。

macOS及共享Apple网络实现本轮NAS分支；iOS/iPadOS共享新增枚举，无新UI且未构建；Windows/Android记录命令、权限与通知生命周期迁移影响，未改代码。无依赖、持久化、签名或工具链变更；回滚移除新增入口/命令/事件通道即可，不自动撤销NAS已完成的预览。Socket.IO使用官方查询令牌机制，完整URL和含URL的底层错误不得进入日志；证书、同源重定向规则沿用现有实现。

完整网页对齐尚未完成：本机图像/视频转换及ConvertedFile上传、通知中断后完整恢复仍待实现。NAS实际转换、反向代理路径及照片/视频格式覆盖为PENDING_USER_VALIDATION，需用户用测试照片/视频确认成功、失败和断线行为及原件/月份保留；失败回传脱敏步骤与提示，不包含真实内容或连接资料。精确测试命令和结果见MACOS_PHOTOS_PARITY_20260929_ZH.md；静态脚本/合成测试不代表真实版本兼容。


### 2026-09-29 收集默认目录选择契约增量

SynologyPhotosAccess新增canManageSharedSpace，旧初始化默认false，来源为Photos共享空间已启用且team_space_permission=management。macOS按个人优先选择收集默认空间，共享管理者可自动目录，entry必须明确选目录；从目录发起或编辑保留原目标，提交沿既有真实上传权限、确认、去重和结果核对。共享Apple领域/Repository增量已实现；iOS/iPadOS未接新UI且未构建，Windows/Android仅记录未来迁移影响、未改源码。无API参数、存储或工具链变化；回滚移除字段/UI逻辑即可，NAS记录不受影响。真实NAS目录建立/访客上传为PENDING_USER_VALIDATION，无人工待实测禁用；证据及命令见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 本机预览转换与上传增量

共享Apple Network新增SynologyPhotosPreviewConverter，使用系统ImageIO与AVFoundation生成图片/视频三档JPEG预览；Repository增量发现Foto/Fototeam.Upload.ConvertedFile v3，复用现有regeneratePreviews命令。PNG优先本机，NAS明确失败/尚未连接时可本机处理；临时原件随处理结束删除，转换前后核对身份权限，上传未知不重放，成功局部更新。无新第三方依赖、公开领域契约或持久化格式变化，未重新编码完整视频。macOS实现并构建；iOS/iPadOS共享源码但未新增界面且未构建；Windows/Android仅记录其平台媒体转换与上传适配待办，未改源码。回滚移除本机转换与候选发现即可保留NAS分支，原件无修改。真实NAS上传/格式覆盖为PENDING_USER_VALIDATION，无人工待验开关；证据与命令见MACOS_PHOTOS_PARITY_20260929_ZH.md。

### 2026-09-29 共享分类浏览契约增量

macOS相册页接入共享人物/主题/地点/标签分类、对应照片及封面，空间选择/返回/分页保持来源，entry权限转文件夹。Apple共享服务新增带space的分类读取重载，集合space默认personal；旧方法兼容，无存储迁移或新依赖。缓存按空间与分类隔离同编号。iOS/iPadOS仍调用既有个人入口，新共享重载供后续原生流程使用；Windows与Android记录同等来源/权限/分页语义，本轮未改其代码或界面。共享人物写管理、共享来源相册/条件源、跨空间移动仍未完成；接口static证据不提升实机兼容等级。聚焦验证和用户验收步骤统一见MACOS_PHOTOS_PARITY_20260929_ZH.md的共享分类浏览波次。

### 2026-09-29 共享人物管理契约增量

macOS共享人物改名/合并/显示隐藏/人脸整理/封面及图片内手工人脸接入，命令由集合space或照片ID固定来源；读写/回读/裁剪上传均沿同一空间，混合空间目标写前拒绝，同编号缩略图隔离。共享人物管理需真实management权限、人物启用设置及对应API能力，无待实测白名单。Apple服务新增带space的人物管理/显示读取重载，个人旧调用兼容；iOS/iPadOS尚无新增UI，Windows/Android只记录适配计划，未改五端存储。真实NAS写验收仍PENDING_USER_VALIDATION，static证据不升级。具体命令、测试包和剩余功能见MACOS_PHOTOS_PARITY_20260929_ZH.md共享人物管理波次。

### 2026-09-29 相册照片来源契约增量

macOS条件相册新增个人/共享来源选择与独立草稿，条件建议增量重载conditionSuggestions(keyword:in:)；旧调用默认个人，共享按user_id=0与实际management权限接入。普通相册的创建/加入/移出/封面命令从照片身份固定来源，允许统一相册中的混合来源成员逐项预检；相册列表及照片走统一Foto接口，owner_user_id=0保留共享照片身份，封面带album_id授权。无照片目标的普通相册命令不依赖个人空间开启；共享照片上传后沿既有队列加入相册。

iOS/iPadOS共享Apple Package兼容旧签名，新增重载默认显式不支持共享，实际Repository已实现；未新增移动UI。Windows与Android需适配条件来源、统一相册入口、逐项来源预检和回读，当前仅记录影响，未改其代码、存储或构建。静态证据不提升NAS验证等级，真实验收为PENDING_USER_VALIDATION；具体本地验证、测试包与剩余范围见MACOS_PHOTOS_PARITY_20260929_ZH.md本轮记录。他人相册协作权限、跨空间移动与队列恢复不以本轮源码构建代替完成。


### 2026-09-29 相册上下文读取契约增量

共享Apple领域SynologyPhoto新增可选albumContext(albumID,ownerUserID)，构造参数默认nil，旧调用兼容、无持久化变更。macOS相册列表→项目→详情→缩略图/视频/实况/原件保存携带同一相册编号，走统一Foto读取；没有原空间权限仍由NAS按相册授权处理，拒绝不回退原件路由。Photos已启用但个人/共享空间均关闭时仍可浏览相册/与我共享，原空间管理按钮按实际能力保持无权限。详情校验来源身份，刷新授权丢弃在途内容；相册查看不赋予他人个人原件写权。

iOS/iPadOS共享Repository得到读取修正但未新增UI或运行移动构建；Windows/Android后续需在自身媒体模型保留相册上下文、作用域和读取/写权限分离，本轮仅记录影响，未改其源码。真实NAS和受限分享角色验收PENDING_USER_VALIDATION；仅static证据与本地合成验证，不宣称版本兼容。相册协作添加/上传及角色按钮、跨空间移动和队列恢复仍未完成，具体测试及测试包见MACOS_PHOTOS_PARITY_20260929_ZH.md本轮记录。


### 2026-09-29 相册协作契约增量

Apple共享服务增量albumAccess/addableAlbums及uploadToAlbum，照片上下文增量可选providerUserID；不改变持久化。macOS按所有者/查看/下载/贡献角色开放入口，贡献者通过相册目标直接上传、仅移除本人提供的成员，上传队列切页保持目标；源照片加入相册仍独立检查访问权。权限刷新失败不沿用旧角色，原件修改和相册成员管理分离，最终状态回读和去重保留。

iOS/iPadOS仅共享模型与Repository增量，不新增移动界面，本轮未运行移动构建；Windows/Android仅记录等价契约影响，后续分别实现原生交互，无源码变更。私有接口static与合成测试不构成真实版本兼容；PENDING_USER_VALIDATION需核对角色、provider、上传/移除/部分失败。具体自动化与测试包以MACOS_PHOTOS_PARITY_20260929_ZH.md本波次记录为准。跨相册转加无原空间项目、跨空间搬移、其他混合批量编辑、预览恢复、上传持久化及分类拼图/相似项目仍未完成。


### 2026-09-29 相册间添加来源语义更正

官方静态操作栏表明：原空间启用时，本人provider可将相册项目添加到已有目标或新建相册；其他下载角色不等于添加权，混合来源另需共享管理权。原空间关闭时只提供移除成员，先前把无空间跨相册转加列为缺口不准确。macOS与Apple Repository已按source album_id重新核对快照及provider，再用既有目标id/passphrase和item提交，不新增来源写参数或公开契约。原件owner与provider分离，仅添加成员不授予原件写权。iOS/iPadOS共享Repository受影响但无界面修改或移动构建；Windows/Android仅同步语义计划，不改源码。真实NAS仍PENDING_USER_VALIDATION，不提升static证据等级。剩余跨空间移动/批量编辑、预览中断恢复、上传持久化与分类拼图/相似项目继续推进，详细命令与测试包见MACOS_PHOTOS_PARITY_20260929_ZH.md本波次。

### 2026-09-30 macOS Photos跨空间移动与复制

共享Apple领域move/copy增量加入可选destinationSpace，省略时保持原空间；macOS已接入目标空间/目录选择，个人→共享移动及个人↔共享复制，来源与目标权限分别核对，任务回执匹配目标目录/owner/total并回读完成状态，未知只查已知任务、不重放。跨空间不沿用旧原件编号推断成功。完整完成后当前列表按旧身份局部更新，不刷新到最新月份；混合来源批量仍待补。

五端影响：macOS实现本轮完整流程；iOS/iPadOS共享包保持调用兼容，目标选择及触控转换按专项计划后续实施；Windows/Android记录等价契约依赖，不改本轮界面或存储。无新依赖、标识或权限变更。官方端点证据static、真实NAS为PENDING_USER_VALIDATION；源码、回归与测试包证据见[本轮账本](../development/MACOS_PHOTOS_PARITY_20260929_ZH.md)。未把其他平台验收或真实NAS写入表述为通过。


### 2026-09-30 混合来源编辑与相册原位更新

macOS 已接入个人/共享混合评级、绝对/相对日期和预览重建；先检查两空间能力及共享管理权，每张照片仍检查原件权限，按来源分发、回读，部分完成只继续原快照中的剩余项。跨空间移动后按相册已加载范围重新读取新身份，短暂失败自动重试，不刷新整个照片库；最终读取失败保留内容并允许只读重试，导航取消隔离。

官方 static 证据更正：混合标签不可用，普通/共享相册菜单没有混合移动复制，因此两项不应继续计为网页待办。五端影响：macOS 完成本切片；iOS/iPadOS 共享 Apple 计算属性及 Repository 增量，无存储/调用签名变更，无移动界面修改或构建；Windows/Android 后续按原生交互实现分来源批量及部分结果，不修改本轮源码。实际验证、风险及测试包见 MACOS_PHOTOS_PARITY_20260929_ZH.md 本波次，未提升真实环境兼容等级。剩余代码组为预览通知/队列恢复、上传持久化恢复（授权待答复）和分类拼图/相似项目；真实 NAS 另列 PENDING_USER_VALIDATION。


### 2026-09-30 预览通知短暂断线恢复

Apple共享Photos事件通道增加已订阅任务的自动重连：最多三次1/2/3秒退避，总等待期限不延长，只握手并重新注册原照片编号，不重发重建/标记/上传。拒绝连接、证书错误、非法帧、超时和取消停止；完整结果仍由明确事件与Repository身份回读核对。macOS使用该通道；iOS/iPadOS共享实现受影响但本轮无移动UI或构建，Windows/Android仅记录等价恢复语义，不改源码。无公开签名、持久化、权限或工具链变更。真实NAS待用户验证、静态接口证据不升级。list_regenerating未完成队列与丢失事件补查仍未完成，不能把该子项视为整个恢复组完成。测试和包证据见MACOS_PHOTOS_PARITY_20260929_ZH.md对应波次。


### 2026-09-30 未完成预览队列恢复

共享Apple契约增量pendingPreviewRegenerations(in:)只读方法（旧服务显式unsupported）和regeneratePreviews默认false的resuming参数；领域无存储格式变更。macOS新增工具栏恢复面板，读取个人/共享未完成队列、选择确认继续，准备/提交两次核对队列与原件，初次恢复不重复set_regenerating。已丢失通知的原操作自动检查提交前新鲜版本基准、原件身份、新版本及队列无目标；不以队列消失单独认定完成，未知不重放，部分完成只重试剩余目标。读取失败不清空原写入记录。

五端影响：macOS完成原生入口与Repository恢复；iOS/iPadOS共享声明/实现受影响，原调用省略resuming继续普通重建，模式匹配需适配新增关联参数，无移动UI/构建；Windows/Android仅同步等价队列与核对语义，没有本轮源码改动。依旧static/PENDING_USER_VALIDATION，不把合成证明当真实NAS兼容。当前主要剩余代码为上传跨重启持久化（授权待答复）及分类拼图/相似项目，具体命令、失败修正与包见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-30 Photos 分类首页拼图增量

共享Apple服务新增categoryPreviewImages只读方法，默认显式不支持；Repository按所选空间读取最多4张分类缩略图，不改变持久化或完整分类封面缓存。macOS卡片显示拼图，失败保留可点击占位。iPhone/iPad暂不新增界面；Android、Windows仅同步未来等价读取语义，不修改代码。人物show_more、不读取隐藏人物，视频type=video，个人/共享来源和权限独立；原生显式空间选择不采用网页跨空间回退。真实NAS封面为PENDING_USER_VALIDATION，static证据不提高验证等级。相似项目仍待完整分组契约与实现；上传跨重启持久化授权待答复。


### 2026-09-30 相似照片分组浏览增量

macOS 新增 Similar/SimilarItem/SimilarTimeline v1 的分类、月份分页和组内预览，显示推荐项与数量，按实际权限/enable_similar 开放。共享 DsmCore 增加分组模型和只读服务默认实现；iOS/iPadOS 仅补齐穷尽枚举编译分支，分类入口保持原范围，移动端功能不在本轮交付。Android、Windows 仅记录影响，不修改实现。分组管理操作仍待后续；无工具链、存储、标识或凭据变更。静态证据不代表 NAS 行为兼容，实测为 PENDING_USER_VALIDATION；具体契约见 `docs/api/discovery/endpoints/photos-similar-items.md`，自动化与交付见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`。

2026-09-30 后续：macOS相似组推荐设置、移出、拆组及会话撤销已接入既有mutation流程；共享新增similarGroups/editSimilarGroup和结果similarGroup，按原件/目录权限、成员快照、operationID与双重回读保护，未知不重放。撤销不能覆盖其他组，也不会将旧月份照片插入新月份。iOS/iPadOS无新增UI，Android/Windows仅记录同等语义；没有持久化变更。真实NAS仍PENDING_USER_VALIDATION，保留所选删除其他仍待接入。


### 2026-09-30 相似照片清理、批量与识别状态

macOS新增保留所选删除其他（确认固定补集、原件自动核对、分组原位只读刷新）、主列表多组拆分及会话批量撤销、get_status识别运行/等待状态。批量未知暂停后续，不重放，核对成功后继续；失败可取消剩余，撤销仍拒绝覆盖其他组。月份位置按查询保留。共享Apple只读服务增量similarGroupDetails/similarStatus及状态模型，旧Adapter默认显式unsupported；iPhone/iPad无新UI，Windows/Android仅记录后续等价语义，无本轮源码变更。无持久化、依赖、权限或标识变更；私有API仍static，真实NAS为PENDING_USER_VALIDATION，入口按实际权限/能力开放。当前已核实代码缺口为上传队列跨重启恢复，存储授权待答复；合成/构建与测试包证据见MACOS_PHOTOS_PARITY_20260929_ZH.md文末，不以合成测试提升兼容等级。


### 2026-09-30 Photos压缩下载及剩余清单更正

Apple只读契约新增SynologyPhotoDownloadFormat和download(format:)返回实际格式，原downloadOriginal兼容；macOS所选/预览/右键提供原件与压缩JPEG，按真实结果命名、原格式保留提示、同名另存，相似组下载全部成员。沿Download v2与相册授权，检查完整内容、原件保留和权限代次，无存储/工具链变化。iPhone/iPad无新界面，Android/Windows只记录等价语义。本轮仍static/PENDING_USER_VALIDATION，证据及包见MACOS_PHOTOS_PARITY_20260929_ZH.md。新一轮真实网页菜单审计发现整相册/文件夹下载、特定格式原尺寸JPEG转换及幻灯片仍有缺口；此前仅列上传跨重启恢复的清单不完整，以上加入后续，不能宣布全量完成。


### 2026-09-30 Photos整相册与目录归档

Apple共享只读契约增量加入SynologyPhotoArchiveTarget和downloadArchive，默认unsupported保持旧适配器兼容；macOS接入完整普通/条件/协作相册及个人/共享目录原件或压缩JPEG ZIP，按真实权限开放，取消/失败保留原本地文件，不改变月份。无NAS写入、持久化、依赖或标识变更。官方静态证据与回归不等同真实NAS验收，详见photos-library-read.md及MACOS_PHOTOS_PARITY_20260929_ZH.md。Android仅记录契约影响，无源码/UI修改；未来实现需用系统保存器和任务取消，不能以当前页照片冒充整个集合。


### 2026-09-30 macOS Photos幻灯片

macOS新增独立全屏播放、三秒照片计时、视频结束推进、暂停/恢复、前后循环和键盘退出；按现有只读照片查询独立分页，保留图库月份/选择，不要求下载权限。相似组预览按组成员播放，出错暂停、离开取消。没有新增共享契约、存储、NAS接口或其他端UI；iPhone/iPad/Android/Windows保留当前范围，不能以macOS实现宣称五端完成。官方静态证据与本地验证见MACOS_PHOTOS_PARITY_20260929_ZH.md；真实NAS和系统全屏/多显示器行为PENDING_USER_VALIDATION，无人工未实测禁用。


### 2026-09-30 Photos原尺寸JPEG

共享SynologyPhotoDownloadFormat增量增加originalSizeJPEG，SynologyPhotosAccess增加默认false的实际转换能力，旧调用和原件下载默认实现兼容；无持久化、依赖、工具链或权限变化。macOS单张菜单按HEIC/TIFF/RAW、NAS两项设置与下载权限开放，先convert v2成功再下载原尺寸JPEG，校验结果后同名另存；批量归档不支持此单项格式。相册统一Foto，协作者口令仅进POST体；取消不重放转换，不承诺撤回NAS派生缓存。详细契约及用户验证见photos-library-read.md和MACOS_PHOTOS_PARITY_20260929_ZH.md。iPhone/iPad仅共享包兼容扩展，移动导出入口后续另定；Windows需按此语义接系统保存，Android仅记录影响，均未修改界面或宣称完成。static/合成验证不能代替NAS验收，不新增人工未实测功能禁用。


### 2026-09-30 Photos文件夹封面

共享Apple契约增量增加folderCover、setFolderCover(folder:photo:)和folderCoverImages；默认读取实现返回unsupported，沿已授权契约扩展，无持久化/依赖/标识变化。macOS提供目录/单选/右键/预览入口及固定目标的子目录选图窗口，显示默认拼图和自定义封面；按实际目录管理权和来源查看权开放。Folder.set_cover v2单元素数组，成功回执加自定义封面可读共同确认，读失败自动核对、写回执未知不重放，保留图库月份和选择。公开枚举增量需适配穷举，但不改变现有命令语义；其他端界面没有修改，不能以共享包构建代替五端完成。证据static，验收PENDING_USER_VALIDATION，详细契约和限制见photos-management.md、photos-library-read.md及MACOS_PHOTOS_PARITY_20260929_ZH.md。

Android仅记录协议影响，后续按原生目录/单选确认交互接入，本轮未修改或构建Android。


### 2026-09-30 Photos目录排序

Apple共享模型增加SynologyPhotoSort，folder查询追加带默认值的排序参数、集合追加可选sort，Serving增加folderSort和带方向的folders读取，命令增加setFolderSort（folderSorting特性）。旧查询构造不变，旧模式匹配需要接收第二个参数；旧目录读取保持升序，未适配的新能力明确unsupported。macOS封面选择器接入四字段/两方向，按Folder.set_order v1保存并严格回读；每页请求排序，当前图库目录同步重排，保留目录和选择，不影响其他相册。实际view权限即可改浏览偏好，设置封面本身仍需manage。无本地持久化、依赖或权限配置变更，沿已授权契约扩展；static与合成验证不代替NAS兼容，PENDING_USER_VALIDATION。完整证据及回滚（移除本轮排序入口/增量契约，不影响照片原件）见照片对齐账本及photos-management.md。

Windows、Android仅记录等价行为和契约影响，本轮未修改界面、未执行目标端构建。iPhone/iPad目录封面编辑及其排序继续属于后续范围；现有目录浏览保持，后续用触控菜单/系统返回，两者同范围，不照搬桌面菜单；共享包扩展不代表移动功能已经交付。


### 2026-09-30 Photos目录重命名与图库排序入口

共享Apple命令增量renameFolder(folder:name:)，继续沿folders能力，公开名称校验与网页规则一致；已授权契约扩展，无持久化/标识/依赖变化。macOS目录卡片打开固定目标表单，重新检查身份/manage，rename v1后按完整新路径及id/parent自动回读；未知只查不重发，局部更新卡片/面包屑/后代路径，保留月份与选择。同编号相册/其他空间隔离。主目录页接入已有四字段/两方向排序，包含根目录；封面窗口复用同一菜单。源码与合成测试不代表NAS验收，PENDING_USER_VALIDATION步骤和回滚见MACOS_PHOTOS_PARITY_20260929_ZH.md、photos-management.md。

Windows/Android仅同步共享契约与等价语义影响，本轮未改其UI或运行其目标端构建。iPhone/iPad目录重命名及排序编辑继续为后续范围，未来用触控菜单/系统返回，现有浏览不变；共享包可编译不等于移动功能交付。剩余目录删除、目录移动复制、共享目录权限分享，以及待授权的上传重启恢复仍未完成。


### 2026-09-30 Photos多文件夹与混合删除

共享Apple增量folderDeletion、deleteFolderItems(photos:folders:)及默认空的deletedFolders/deletedPhotoIDs结果；既有删除策略由macOS组合根显式开启，其他端不自动获得UI入口。macOS目录选择/混选确认固定目标，重新核对原空间、目录路径/父级/管理权和照片身份；按官方BackgroundTask.File.delete v1(item_id,folder_id)主流程提交。任务完成无错误后完整父目录分页及照片空回读共同确认，成功原地移除/修正分页；进入已删目录时回父目录。未知回执不重放，任务部分失败缺少逐目录结果时不猜测哪些目录已删除。纠正旧Browse.Folder.delete候选；详见photos-item-deletion.md与照片对齐账本。

无依赖、标识、权限配置或持久化变更，沿已授权契约扩展；回滚移除本轮多选/删除命令和入口，不撤销已经在NAS发生的删除，真实恢复取决于NAS回收站。static与合成测试不是行为验收，PENDING_USER_VALIDATION操作、风险和脱敏回传见端点记录。Windows/Android只记录等价流程，本轮不改UI或运行其构建。iPhone/iPad目录管理仍是后续范围，未来通过触控选择/原生确认，两者同范围；共享包增量不等于已交付。目录移动复制、共享目录权限分享、多目录/混合整批下载及待授权的上传恢复仍有缺口。


### 2026-09-30 Photos文件夹移动复制

共享Apple move/copy命令末尾增加默认空folders关联值，既有调用兼容、模式匹配同步；macOS同一目标弹窗接入多目录和照片混选，固定来源空间、父目录与完整路径，写前重新检查身份/权限和自身后代冲突。沿官方BackgroundTask.File v1 folder_id及move extra_info.source_folder_ids，统一Info回读目标空间/目录、递归任务total和完成状态；丢失回执不重放，部分失败不猜哪些目录成功，重复项沿skip。完成后局部更新/保留原父目录，复制保留来源；核对期间进入来源时内部刷新回父目录，修复移动/删除共用忙碌刷新问题。

已授权契约增量，无存储/签名/依赖变化。Windows/Android仅同步等价语义与契约影响，不修改UI或运行其构建；iPhone/iPad目录管理仍为后续，不把共享包兼容编译写成已交付，两者未来都采用触控选择与原生目标浏览。static与合成证据不代替NAS行为验证；PENDING_USER_VALIDATION步骤、回滚与未知结果处理见photos-management.md及MACOS_PHOTOS_PARITY_20260929_ZH.md。剩余共享目录权限分享、多目录/混合整批下载、拖放移动及重复项设置细节、待授权的上传重启恢复仍需继续。


### 2026-09-30 Photos共享目录权限读取基础

Apple共享包新增SynologyPhotoFolderSharingState及默认兼容的folderSharing/folderSharingRecipients，区别management/private/public-view/public-download、未知成员/密码状态与父级限制。macOS目录右键/当前目录页可只读查看成员角色、链接和保护状态；打开与刷新不创建分享或更新权限，固定目录和父目录身份、共享完整访问权与授权代次。保存/成员修改/密码修改及应用到所有子目录仍待后续接入，不是禁用已实现功能，也不算完整对齐。

内部静态契约与候选写方法见photos-management.md；无真实NAS写入，版本未知，PENDING_USER_VALIDATION只覆盖本轮读取与显示。Windows/Android仅记录对应语义影响，无UI改动或目标端构建。iPhone/iPad目录权限仍为后续范围，不把共享包编译记为移动端交付。无存储、签名或依赖变化，回滚移除新增读取类型/方法/面板即可，无NAS数据恢复需求。


### 2026-09-30 共享目录权限保存增量

共享Apple契约新增folderSharing管理能力和setFolderSharing(original,access,members,password,appliesToSubfolders)命令；默认服务读取接口沿前轮，无存储迁移。macOS实现四种访问范围、成员增删/四种角色、保留/新密码/移除保护、首层子目录选项、固定快照确认与自动结果核对，按真实FotoTeam接口和共享管理角色开放，不增加未实测禁用。未知成员不改名单，旧密码不读取；HTTPS无降级。更新与默认配置分别校验，默认值失败返回部分完成；回执未知不重复写，子目录应用和新密码不能只凭顶层旧状态确认。

Android/Windows仅同步适配要求，不改界面或代码；iPhone/iPad目录权限管理仍为专项计划“后续”，不是本轮待真机功能。其他Apple适配器无需实现新只读默认方法；如果穷举共享命令/能力须新增分支，已检查当前调用点，macOS回归覆盖共享Package。未运行其他端构建。真实NAS权限行为为PENDING_USER_VALIDATION，证据仍static；完整验证和测试包见MACOS_PHOTOS_PARITY_20260929_ZH。回滚移除本轮命令/能力/保存控件，已有查看与相册分享保留；NAS已保存权限需用户用原快照恢复，不能靠回滚App撤销。


### 2026-09-30 多目录与照片混选ZIP下载增量

已授权的共享Apple归档目标增加selection(photos,folders)，不改原有album/folder接口和持久化。macOS工具栏/已选项目右键固定整组选项，下载完整子目录及同级照片，原件/压缩JPEG、取消和失败恢复复用现有流程，保持当前目录与选择。权限和身份全部检查后发送单次Download v2；当前未增加人工未验证禁用。

Windows/Android仅同步同级混选、完整后代、单次归档与权限/取消/不覆盖要求，不修改其代码或声明构建通过。iPhone/iPad目录批量管理仍为专项计划“后续”，共享枚举新增不等于移动入口已交付；未来采用触控多选与系统文件导出，不照搬桌面右键。当前共享调用点已检查，新增枚举须在未来穷举时处理。无依赖、签名、系统权限或存储迁移；回滚移除此枚举分支、预检和菜单分支，原单目录/相册下载保留。真实NAS内容和权限验收PENDING_USER_VALIDATION，static及合成验证见photos-library-read.md与MACOS_PHOTOS_PARITY_20260929_ZH.md；未验证其他平台构建。


### 2026-09-30 macOS文件夹拖放移动

macOS文件夹页增加单项/混选拖动、可见目录/上级按钮/路径导航接收、固定来源与目标的预选确认。只传当前Model的一次性UUID，ownProcess且不含路径或凭据；刷新/跨Model/自移动/原目录/后代或无权限目标拒绝。沿既有移动协议、NAS预检、任务去重与结果核对，无共享契约、存储、依赖或系统权限变化。

Windows未来可对应WinUI原生拖动反馈和同等确认；Android保持已有原生选择操作，不直接照搬桌面鼠标交互。iPhone/iPad目录管理仍为后续，本轮只记录基准交互，无任何其他端代码或构建结论。真实NAS与物理拖放PENDING_USER_VALIDATION，合成测试/预选表单不等于实机通过。回滚移除拖放修饰器、一次性快照及预选路径即可，原有移动复制菜单保留。默认重复项设置及overwrite执行仍是剩余功能。


### 2026-09-30 Photos重复项默认设置与操作规则

已授权共享Apple契约增加SynologyPhotoDuplicateSettings、duplicateSettings()默认不支持方法、setDuplicateSettings命令及能力；upload/uploadToAlbum和move/copy末尾增加带默认值策略，旧构造分别沿rename/skip，模式匹配增加一个关联值；结果skippedCount默认0。macOS读取NAS当前默认、单次调整、确认覆盖、队列冻结策略与忽略状态区分，设置保存原快照校验和自动回读，真实接口权限仍保留，无人工未验证禁用。

内部Setting.User get/set v1证据static，真实NAS行为PENDING_USER_VALIDATION。当前无本地持久化、工具链、签名、依赖变化；不等于五端UI完成。回滚移除本轮设置入口/增量契约及策略参数，恢复原rename/skip行为，旧已排队操作不重放；不会自动改回NAS已保存偏好。证据、验证、验收步骤见MACOS_PHOTOS_PARITY_20260929_ZH.md和photos-management.md。

Android本轮仅记录影响，不修改代码或触发构建；后续原生上传选项可采用相同固定策略与结果区分，桌面拖动不直接迁移。


### 2026-09-30 相册内照片排序增量

共享契约新增albumSort、setAlbumSort(original,sort)，album query带默认sort保持旧调用行为。macOS从NAS读取当前相册顺序，原生菜单支持四字段与升降序，统一分页、原始快照冲突检查、同操作去重与最终明确字段回读；未知结果只核对，个人空间关闭但相册可查看仍开放。上传及搬移后沿已选择排序刷新当前相册，不回时间线。官方证据仅static，真实NAS保存/排序为PENDING_USER_VALIDATION，不因未实测禁用。

五端：macOS本轮实现；Windows记录等价列表菜单/分页/回读适配；iPhone/iPad不改变本轮范围（未来触控菜单，无桌面悬停）；Android仅记契约影响，不改其他端UI。没有本地存储、权限、依赖或工具链迁移。回滚客户端增量不撤销NAS偏好，可在网页重新选择。相册列表显示/排序与分享列表排序仍未接入，上传重启恢复仍待持久化授权，不能将本轮构建等同完整对齐。详细证据及验证命令见MACOS_PHOTOS_PARITY_20260929_ZH.md文末。


### 2026-09-30 相册列表偏好与分享排序

macOS新增全部/我的相册范围、相册首页及两类分享列表各自排序，读取已有NAS偏好，固定条件分页，原值冲突拒绝覆盖、去重和保存后回读；未知不重发，不改相册内容/共享权限。共享领域和服务增量扩展，旧列表调用语义保留，新参数默认适配器明确不支持，不静默忽略。Album偏好v2/v3分别探测，home关闭仍开放实际可用能力，NAS实际验证由用户完成，没有人工未验证禁用开关。

五端影响：macOS本轮实现；Windows后续用原生菜单保留相同范围/分页/回读；iPhone与iPad的等价触控排序记为后续专项取舍，不扩张本轮UI范围；Android仅记契约影响。不改变其他端UI、本地存储、权限、依赖或工具链。回滚移除客户端增量，不删NAS偏好。PENDING_USER_VALIDATION步骤与静态证据见photos-management.md及Photos对齐账本，不将构建当作NAS行为验证。


### 2026-09-30 macOS 预览旋转保存增量

共享Photos契约新增rotation能力与rotatePhoto单张命令，SynologyPhoto增加原始方向及支持旋转/动态播放计算属性（可选字段默认nil，旧调用兼容，无存储格式变化）。macOS预览逆时针90°保存到NAS，个人/共享Item.set v2；真实权限与媒体条件、快照比较、操作编号去重、自动只读结果核对，回读更新当前照片而不刷新图库。方向1–8镜像映射及宽高交换按官方static证据，原件字节副作用仍待用户验证。无“未验证”禁用。

五端：macOS实现与回归；iOS/iPadOS共享包被动增加向后兼容类型，不新增界面，本轮仅记录候选交互：照片预览工具栏或菜单旋转，仍需各端专项范围确认；Windows记录预览菜单等价语义；Android仅影响记录，不改源码。真实NAS/手势PENDING_USER_VALIDATION不等于其他端已实现。本轮不升级工具链、不改Bundle ID/权限/持久化、不正式发布。


### 2026-09-30 主题分类显示管理契约增量

macOS新增conceptVisibility读取、setConceptVisibility命令与独立结果字段，个人/共享固定空间，隐藏/恢复只更新主题卡片并自动核对，不删除照片。共享Apple服务默认unsupported实现保留源码兼容；iPhone/iPad高级分类管理仍属后续，不新增UI或标成待真机核心项。Windows/Android记录待适配，不修改实现。公开契约扩展已有用户授权，无持久化/最低系统/依赖变更，移除本轮接口及入口即可回滚。Concept v2的官方证据为static，真实NAS权限、隐藏恢复及断网核对为PENDING_USER_VALIDATION；不能把本地合成测试写成五端行为兼容。


### 2026-09-30 主题封面/误分类移除契约影响

共享Core增量提供conceptState、可选displayThreshold、setConceptCover/removeConceptItems及独立移出结果。默认服务unsupported与可选字段保留源码兼容；macOS新增分类多选和预览入口、阈值提示、写后自动核对并局部更新。Windows/Android待适配；iPhone/iPad高级分类管理仍为后续，不扩大核心范围或改UI。无存储/依赖/权限格式改变；回滚移除新入口/命令。真实NAS原件保留、低于阈值与连拍封面行为PENDING_USER_VALIDATION，不以static或本地测试宣布五端兼容。


### 2026-09-30 照片显示偏好增量影响

macOS新增日/月分组、九种日期格式、12/24小时、默认目录排序及预览/幻灯片底部信息；Setting.User get/set v1，严格快照和差量保存、自动只读核对。共享access增量可选displaySettings，旧调用不变。Windows后续按原生控件实现等价结果；iPhone/iPad保持专项范围，本轮不新增界面与DAG任务；Android仅记录接口变化。无新增持久化、权限或依赖。真实NAS为PENDING_USER_VALIDATION，static不等于行为验证；实际命令与结果见macOS照片对齐账本。


### 2026-09-30 个人照片识别设置增量

macOS接入人物/主题/相似照片个人开关，User get/set v1和Admin get v1，真实个人空间/全局条件、快照、差量保存及自动只读核对；局部更新个人分类，共享分类不变。共享服务增量默认不支持，Windows后续原生设置适配；iPhone/iPad沿专项范围，本轮不新增界面/DAG，Android仅记录影响。无本地存储、依赖或权限变化；static与PENDING_USER_VALIDATION不等于NAS行为验证，自动预览仍需完整触发流程。验证命令和结果见照片对齐账本。


### 2026-09-30 自动预览只读候选基础

共享Apple服务增量automaticPreviewTasks(in:support:)及独立预览单元任务/转换能力类型，旧服务默认明确不支持；ConvertedFile.list_convert_needed v3，官方preset/type条件，个人/共享management隔离，取消/访问代次检查。只读，不下载或写入；自动转换执行、设置与调度仍待完成，不把本切片计为完整功能对齐。macOS尚无新增可见入口；Windows后续实现等价后台流程，iPhone/iPad保持专项范围，不新增移动端DAG，Android仅记录契约影响。无存储/权限/依赖变化，证据static，真实NAS为PENDING_USER_VALIDATION。验证命令和结果见照片对齐账本。


### 2026-09-30 自动预览原件与本机视频转换

Apple共享服务新增downloadAutomaticPreviewSource，默认明确不支持；Download v2单元读取前后核对候选，按空间权限、取消/访问代次和内容长度校验，不覆盖已有目标。本机AVFoundation导出H.264/AAC，合成MJPEG/PCM验证方向/时长/音轨与原件保持；无依赖或最低系统变更。完整自动上传/核对/调度/设置仍在实施，macOS尚无新增界面，Windows/Android仅同步影响，iPhone/iPad不新增专项范围/DAG。真实编码与NAS行为PENDING_USER_VALIDATION，不将测试扩大为全格式支持。具体命令见macOS照片账本。


### 2026-09-30 自动预览上传与结果核对

共享Apple增量管理命令generateAutomaticPreview与automaticPreview能力，沿既有操作编号去重/结果核对；三档JPEG及H.264/AAC通过ConvertedFile v3文件流式上传。明确同步回执确认，未知只读媒体摘要核对、不重放；候选消失不等于完成。个人/共享management隔离，源文件及临时媒体保护，真实NAS仍PENDING_USER_VALIDATION（视频回读档位绑定/缓存行为为标明的客户端推断，不能当兼容认证）。设置/调度/实际编解码能力采集/可见项优先尚待接入，未新增macOS可见入口或安装包；Android/Windows仅记录适配影响，iPhone/iPad不扩展专项范围或DAG。无持久化、依赖、权限或最低系统变更，回滚新增命令和执行逻辑即可；详细测试见macOS Photos对齐账本。


### 2026-09-30 自动预览设置与后台扫描

Apple共享服务/Access增加可选自动开关与读写命令，User.get/set v1仅更新auto_generate_thumbnail并核对结果。macOS新增中英设置、系统HEIC读取/H.264输出能力采集、照片页串行扫描、暂停继续、同批候选可见优先及未知退避核对，保留月份/选择。个人及共享management后台范围已接通；共享entry目录可见任务、批次外/实况优先仍未对齐，不将网格onAppear等同0.8可见阈值。真实NAS仍PENDING_USER_VALIDATION，已实现入口无人工实测开关；Android/Windows仅同步契约影响，iPhone/iPad不扩展专项DAG或UI。无本地持久化/最低系统/依赖/权限改变，回滚新增命令、worker与入口即可。实际测试和测试包见macOS Photos对齐账本。


### 2026-09-30 macOS可见照片自动预览契约增量

共享PhotosServing增加automaticPreviewTasks(for:support:)默认空实现，AutomaticPreviewTask增加sourcePhoto可选快照（旧初始化nil）；不改变原有后台候选调用。macOS按照片实际owner/目录download读取批次外候选，实况分单元，读取前后/提交前/未知结果复查共用原执行链，2秒去抖及跨来源去重。共享entry不获全库扫描权。无持久化、API新参数、依赖或权限变更。Windows、Android、iOS、iPadOS后续按平台前台可见/预览语义接入，当前不修改其界面；Apple共享库保持向后兼容并运行macOS回归。637项XCTest/6项本地化通过，真实NAS仍PENDING_USER_VALIDATION；证据及回滚见photos-advanced-management与macOS Photos账本本轮记录，不把本地合成测试提升为五端已实现。


### 2026-09-30 共享空间设置增量

Android仅记录共享空间管理员设置契约：TeamSpace启停/识别/公开顶层分享，复用真实管理员身份、固定原值及自动核对；本轮不修改Android源码。 无新增存储、依赖或工具链变化；移除本轮入口/命令即可回滚。


### 2026-09-30 全局设置与转换缓存

Android本轮不改代码或UI；后续全局设置需按Android交互接入同一多阶段语义，真实管理员与共享角色分开，不以界面存在视为对齐。

契约为Photos Core/Serving增量设置/缓存读取和命令、MutationResult可选状态；复用Admin/User/TeamSpace v1与Download缓存v2，实际权限/字段/编解码条件开放，无待实测白名单。NAS实测按photos-global-settings-cache的PENDING_USER_VALIDATION由用户执行。无存储迁移、依赖、工具链或标识变更；回滚移除本轮入口及增量方法，保留已有图库和数据。验证结果统一见MACOS_PHOTOS_PARITY_20260929_ZH.md最新波次。


### 2026-09-30 共享成员与按成员目录权限（读取与领域规则切片）

Core/Serving增量加入共享成员快照、候选及两层目录权限分页，协议默认显式unsupported，既有实现源兼容。Repository独立回读DSM管理员身份，保留本人、用户/群组及数字/字符串ID区别；目录权限不要求成员姓名、不创建分享链接，未知角色保留，缺字段报错，访问代次变化丢弃旧结果。草稿遵循管理角色开启备份/降级保留备份及系统administrators群组保护；本轮尚无成员保存命令或原生入口，不把读取等同完整管理闭环。

五端：macOS继续接入确认、分阶段保存、自动核对与原生编辑器；Windows/Android仅同步后续适配，未改界面或执行平台构建。iPhone/iPad管理员共享成员设置继续属于后续非核心能力，不新增UI，也不以PENDING_USER_VALIDATION暗中扩大范围；可继续使用NAS网页管理。无新增存储、依赖、权限、工具链。公开契约沿用户已有增量扩展授权，回滚可移除新增协议默认方法/类型/实现，不迁移用户数据。

私有组photos-shared-space-members为static；真实NAS写入仍由用户在完整入口交付后验收，当前不能形成行为兼容结论。保存流程完成后验证新增/降级entry时目录授权、取消草稿零写入、部分失败与断网不重放、历史月份保留。完整余项仍见MACOS_PHOTOS_PARITY_20260929_ZH.md。


共享成员保存切片继续（2026-09-30）：Core新增setSharedMembers组合命令、目录批量/单项草稿和可选sharedMembers结果，Serving增加完整两层快照方法及unsupported默认实现。Repository按固定原快照分阶段提交，未知仅回读、明确失败核对部分应用，最后回读本人真实空间权限。未接macOS原生表单/Model轮询，不宣称完整入口可用；Windows/Android同步适配影响，iPhone/iPad管理员设置仍为后续，未改变其他端UI、存储或工具链。真NAS兼容未验证，静态证据与自动化范围见照片对齐账本和photos-shared-space-members。


共享成员原生入口完成（2026-09-30）：macOS已接入成员/角色/自动备份及按成员目录草稿、最终确认、分阶段保存、后台自动核对和本人实际权限更新，个人月份/选择保留，在途旧分页隔离。692项XCTest、6项本地化及2项原生UI通过，真实NAS为PENDING_USER_VALIDATION；无人工待实测禁用。本轮复用上一切片共享契约，无新增协议/存储/依赖。Windows/Android适配计划保持，未修改或构建其他端；iPhone/iPad管理员设置仍后续非核心，通过网页管理。详细范围/实际命令/限制见MACOS_PHOTOS_PARITY_20260929_ZH.md及photos-shared-space-members。


### 2026-09-30 自动预览完整相邻与格式顺序

Photos Core任务增量priority枚举：普通1、HEVC/实况视频2、VC1/WMV3为3、后台4；初始化保留默认参数，旧调用源兼容，无持久化变更。Network依据已读取的编码/单元来源赋级，macOS按级升序并在同级保持当前、后3/前2、可见顺序，先按网页小集合缩减再排除相邻视频。只使用已加载照片，分页缺口不循环、不为预取主动改月份；后台候选和权限/去重/结果核对保持原流程。完整验证与未验证限制见MACOS_PHOTOS_PARITY_20260929_ZH.md最新波次。

五端影响：macOS接入；Windows/Android未来对应自动预览调度须映射相同优先级，当前未改或构建二者；iPhone/iPad不新增桌面后台转换能力，后续规划范围不变，仅共享Apple模型向后兼容。没有新增API写方法、系统权限、依赖、工具链或存储。回滚本轮priority映射及调度即可恢复原处理顺序，不迁移或删除NAS内容。真实编码/预览结果与物理浏览体验交由用户验证，不设人工待实测禁用。


### 2026-10-01 当前空间整库维护契约增量

Core新增SynologyPhotoLibraryMaintenanceStatus、libraryMaintenanceStatus(in:)默认unsupported与maintainLibrary命令；用户此前已授权契约扩展。macOS按个人/共享空间接入Index get/reindex v1、basic/thumbnail动作；确认固定空间，真实管理员及H.264条件、重复提交保护和自动读状态，不刷新历史月份。证据static；明确回执与计数归零结束本阶段核对，丢失回执无任务ID可能长期未确认，不重发或推断全部后台阶段完成。详见photos-library-maintenance及Photos对齐账本。

五端影响：macOS实现原生入口；Windows/Android需在各自维护能力实施时映射相同语义，本轮未修改界面或运行构建；iPhone/iPad整库管理员维护仍为后续范围，不因为共享协议增量新增移动端入口或验收待办。Apple默认实现兼容既有服务；无存储/依赖/工具链变化。回滚本次入口、命令和读取协议即可，不迁移或删除NAS数据。真实NAS由用户验收，无待实测人工开关。全用户reindex_all_user欢迎流程仍未实现。


### 2026-10-01 新格式提示与全用户补预览契约增量

Core新增SynologyPhotoCodecPrompt、codecPrompt默认unsupported与respondToCodecPrompt命令，沿此前公开契约扩展授权。macOS接入新格式提示、稍后已读及按管理员身份分流的全用户/个人补预览。明确区分生成请求已接收和后台完成：不拿个人计数证明全用户完成；未知回执只核对、不重发，部分成功仅补保存提示，历史月份和选择保留。证据static，真实NAS为PENDING_USER_VALIDATION，无人工待实测禁用。

五端影响：macOS原生入口已接入；Windows/Android对应照片设置实施时需保持上述范围和结果语义，本轮不改界面或构建；iPhone/iPad全用户管理员维护仍属后续非核心，可通过网页管理，不新增移动验收待办。共享协议提供默认实现保持现有服务源兼容。无存储、依赖、工具链迁移；回滚新增入口、命令和读取接口即可，不回滚NAS已开始的后台作业、不删除用户数据。验证记录见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-10-01 自动预览失败同步结果增量

Photos管理结果新增automaticPreviewFailureRecorded默认false，兼容既有初始化调用；仅在明确转换失败的标记接收/真实状态核对后为true，生成结果仍为rejected，不计成功。macOS显示对应重建预览入口提示；其他错误沿既有重试路径。Network按单元/空间/阶段调用set_broken v3，未知上传回执、权限撤回、取消和临时系统错误不标记。无存储/工具链/依赖变更；回滚新增失败同步和提示即可，不删除原件或回滚NAS已记录状态。

五端影响：macOS接入；Windows/Android未来自动预览实现需映射各自系统的明确转换失败与临时错误，不照搬AVFoundation码。本轮不改其他端UI或运行其构建。iPhone/iPad后台全库转换仍后续非核心，不新增移动入口或待验；共享Apple结果默认值保持旧实现兼容。静态API证据不提升，真实NAS由用户验收，无人工待实测禁用；完整验证见Photos对齐账本。


### 2026-10-01 临时分享生命周期契约增量（实现中）

用户已授权Photos对齐所需共享契约扩展。Core新增createTemporaryAlbum、copyTemporaryAlbum、deleteTemporaryAlbum，以及SharingState可选isTemporary（缺字段保持nil）；沿既有临时分享静态端点，不改变普通createAlbum/deleteAlbum语义。Repository创建需核对temporary_shared、名称、所有者及完整成员；复制需回执新编号、普通非共享标记及完整成员快照一致；清理仅接受所有者的已停止临时相册与一致分享快照。未知回执沿操作编号只读核对，不按名称追认、不自动重放。macOS组合界面尚待接入，此记录不表示完整临时分享已交付。

五端影响：macOS接入后需覆盖取消清理和停止保留副本；Apple移动共享Package采用默认nil增量字段，枚举使用方需编译确认，未增加移动端界面；Windows与Android仅同步未来等价语义，当前不修改UI。无持久化/数据迁移。回滚移除新命令、字段和新入口，既有普通相册功能保持。当前仅static证据和待运行本地测试；真实NAS继续PENDING_USER_VALIDATION，不设人为待实测功能锁。


### 2026-10-01 临时分享组合流程增量

macOS现已接入创建取消清理、停止及保留副本确认、未知结果持续核对。deleteTemporaryAlbum增量默认参数preservedCopyID仅用于本地清理前的副本身份和完整成员复查，不改变NAS参数或持久化。明确失败可保留现有相册，不能丢弃在途未知操作。无迁移；回滚移除本轮入口、模型阶段及可选参数，已存在普通相册仍保留。

五端影响：macOS组合界面及共享Core/Repository改变；iPhone/iPad共享调用由默认值兼容，枚举匹配保持原语义，本轮未改其界面或运行目标平台构建。Windows/Android只记录未来等价流程，不修改实现。其他端不得以macOS本地通过冒充目标平台完成。用户NAS仍PENDING_USER_VALIDATION，static等级不提升，当前环境验证及包状态以Photos对齐账本为准。


### 2026-10-01 上传任务导航与单项管理契约增量

用户已授权Photos对齐所需接口扩展。Serving新增folder(id:in:)只读方法，默认显式不支持；Repository复用已有Browse.Folder.get v2权限校验，返回当前名称、父目录、路径及空间，不增加NAS端点、写操作或持久化。macOS上传结果导航先回读照片当前目录，再逐层校验目录身份/访问权；直接相册贡献上传只提供相册入口，不绕过原空间权限。队列取消仅针对未开始单项，终态记录移除不删除NAS照片，未知结果保留自动核对。

五端影响：macOS新增使用入口；iPhone/iPad共享Package采用向后兼容默认实现，本轮不改移动UI；Windows/Android仅记录未来等价语义，不修改实现或冒称目标平台通过。无数据迁移；回滚移除新入口/方法即可，旧上传重试保持。当前验证结果以Photos对齐账本为准，真实NAS为PENDING_USER_VALIDATION，不因未实测增加人工功能锁。


### 2026-10-01 Photos后台任务契约增量

静态证据与请求参数见`docs/api/discovery/endpoints/photos-background-tasks.md`及compatibility.json的photos-background-tasks。统一Info v1读取当前用户任务、错误详情；取消id数组，清理id标量。macOS原生任务窗口提供筛选、进度、取消确认、单项/冻结快照批量清理、错误名称/原因与目标目录导航。completion包含错误，done不等同全部成功；取消保留已完成的复制/移动，清理只移除记录。操作编号去重、身份快照、失权/迟到结果隔离和未知回执只读核对沿现有管理模型。允许取消本App待核对搬移，但终态证据核对前禁止清理记录。

五端影响：macOS本轮实施；iPhone与iPad共享新增服务默认明确不支持，不新增移动入口；Android与Windows只登记后续等价语义，不修改实现。本轮未运行其他端构建，不能以共享代码编译代表跨端完成。无存储/权限/依赖/工具链变更；回滚移除新增入口与方法，NAS用户资料不迁移。

本轮新增接口13项、模型7项；最终相关回归780项XCTest、6项本地化及2项原生UI/56张合成截图通过，独立Release包结果见MACOS_PHOTOS_PARITY_20260929_ZH账本最新记录。接口证据仅static，PENDING_USER_VALIDATION包含真实NAS跨空间错误名称、取消终态、断网恢复和清理快照范围；不新增人工待实测功能锁。冻结条件相册、待独立存储授权的上传跨重启恢复及最终菜单审计继续。


### 2026-10-01 冻结条件相册恢复契约增量

macOS新增独立冻结标志、本人冻结相册快照及普通恢复/条件重建命令，复用现有条件编辑器与操作编号。普通恢复只在回读freeze_album明确false后确认；重建先核对新相册的身份和完整条件，再固定旧相册快照删除，旧对象变化时保留两册。创建或删除回执未知不重放；不继承旧分享。冻结前不开放普通相册上传、成员增删和收集目标，既有预览封面设置保留；本人相册列表隐藏重命名/新分享，但“由我共享”的既有分享管理按官方分支保留。证据与真实版本限制见photos-advanced-management.md，当前为static；798项XCTest、6项本地化、1项原生UI/28张合成截图与独立Release临时签名包通过，详见Photos对齐账本。

五端影响：macOS本轮实现；iPhone/iPad共享领域字段默认false、读取默认明确不支持，不新增移动入口；Android/Windows需后续按等价确认、部分完成和失权语义适配，本轮不改代码也不运行各端构建。无持久化/权限/依赖变更，无本地迁移。回滚移除新增入口与调用；已恢复或重建的NAS相册不自动回滚，原照片保留。PENDING_USER_VALIDATION：以真实冻结样本核对普通恢复、受支持条件与重建后的新旧相册/分享、断网恢复和权限变化。只回传脱敏版本及步骤/错误，不含真实照片、路径、地址或凭据。


### 2026-10-01 预览重建角色分支增量

官方static菜单与worker已核对，macOS/共享Apple Repository补齐普通共享目录view+download及相册本人提供者的重建资格；不把任意相册下载权当作重建权，不修改原件编辑权限。相册只读按album_id核对真实提供者/来源/相册状态，重建写请求仍按来源发送item_id/unit_id；本机转换后重查资格。冻结相册按官方入口区分：保留多选重建，预览窗口省略。预览窗口复用已有确认表单；803项XCTest、6项本地化、最终8项聚焦及2项UI/12张合成截图通过，独立Release结果见Photos对齐账本。

无公开API/存储/依赖变更，iPhone/iPad共享Repository受影响但未新增入口；Android/Windows只记录等价语义，不改其代码。PENDING_USER_VALIDATION：真实目录下载者、本人相册贡献者、仅相册下载者、冻结/关闭来源、转换期间失权与断网恢复。缺失来源上下文不能用猜测权限恢复后台队列。回滚客户端本轮资格分支与入口，不反向修改已生成预览；接口证据保持static。


### 2026-10-01 Photos三项统一收尾：Android

只记录影响，本轮不修改Android源码；后续按实际provider_user_id/共享management复验角色，上传恢复不得照搬Apple书签。

上传专用SynologyPhotosUploadCheckpoint只表示上传、直接相册上传、创建上传目录、加入相册；写前与回执同步保存，恢复入口只读核对。新协议有显式不支持默认实现，不改变既有Serving实现的行为。提供者编辑不提升原件删除/移动资格；混合来源标签仍禁止。详见`MACOS_PHOTOS_PARITY_20260929_ZH.md`文末源码映射与后续实际验证记录。真实NAS结果仍为PENDING_USER_VALIDATION。
