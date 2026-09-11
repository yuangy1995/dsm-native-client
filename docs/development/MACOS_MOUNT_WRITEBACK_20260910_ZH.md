# macOS 现有挂载写回实施基线

## 当前实施决定（2026-09-11，取代下文早期调查的阻塞结论）

用户明确选择个人使用的简化覆盖策略并要求实施：有可比较信息时保存前检查，发现变化暂停并保留本机修改，
没有可用版本时直接覆盖；接受检查到覆盖之间的竞争，不要求跨所有 NAS 入口的原子条件提交。
不为此新增 Drive、WebDAV、锁服务或 NAS API，不再等待 Synology 解释条件覆盖。

本波次单一修改范围：Mac 扩展与挂载设置、共享 Apple 挂载存储、退出登录保护、双语资源和相应测试。
其他四端无新增能力；Apple 共享修改保持旧数据可解码。既有只读映射、会话和普通退出行为保留。
仍不开放 Finder 删除。远程挂载、符号链接、跨挂载移动不进入当前写入范围。

必须说明：当前 File Station 读取没有 Drive 的 `version_id`。此次复用文件大小／修改时间形成的基础内容版本，
它只能发现部分变化，不能识别相同大小和时间的修改，也不等同于历史版本号。
元数据缺失时按无版本覆盖；读取失败不能当成无版本，已存在的基础版本检查丢失也会停止保存。

独立写回记录保存在 App Group 下 `desktop-drive-writeback-v1`，不属于可回收下载缓存。
记录先于 NAS 提交持久化，跨进程按挂载互斥；未知结果只核对内容，不自动重放。
用户在“编辑与未上传修改”中检查后可明确重新保存或导出本机副本。
上传完成通过内容回读核对，首版因此会增加一次文件读取流量；不把“跳过同名”当上传成功。

旧版 App 不认识写回记录，回滚前必须处理待上传修改；此目录不会随旧版映射 JSON 重写而丢失。
挂载移除仍沿用系统 `preserveDownloadedUserData`，同时在本地有未确认记录时阻止移除／退出登录。

初期本机构建曾用 `LANSTASH_WRITEBACK_VALIDATION` 保护入口。用户随后明确要求通过正常正式版本测试，
因此 1.0.7 改为正式版提供编辑设置，仍由每个挂载默认关闭的开关、启用确认和请求前检查保护写入。
读写测试用独立临时目录覆盖启用和禁用两条路径。未因此把真实 Finder／NAS 验收记为通过。

发布采用现有稳定通道、双架构签名与公证流程，版本 1.0.7、构建号 17。
先在专用功能分支完成云端门禁，整合为单一功能提交后再发布正式标签；不改变现有签名身份或升级密钥。
面向普通用户的更新说明仅概括新增编辑与上传、异常恢复和界面优化，不罗列开发细节。

## 授权与当前状态

2026-09-10 用户选择在现有 File Provider 挂载中增加写回，并同意新增本地写回存储及兼容处理。
范围为指定文件夹的新建、上传、编辑保存、重命名、移动；已有挂载默认只读，Finder 删除暂不开放。
不引入 SMB、第三方依赖，不改变应用标识、签名权限或凭据保存方式。

前期已完成源码、公开资料及用户已登录的官方 Drive v1/v2 相关文档核查；
现按顶部新决定进入源码实施与测试。下文保留早期研究经过，不作为当前等待官方文档的阻塞条件。
基线 `git status --short` 无输出。本任务没有提交、推送或访问真实 NAS。

## 源码事实与依赖

| 范围 | 证据 | 写回需要处理的内容 |
| --- | --- | --- |
| 访问模式 | `apple/Packages/DsmCore/Sources/DesktopCloudDrive.swift` 的 `DesktopDriveAccessMode` 仅有 `readOnly` | 旧配置继续可读；不得直接写入旧版本不能解码的新枚举值并宣称支持降级 |
| Finder 能力 | `apple/Apps/DsmMac/FileProviderExtension/ProviderItem.swift` 的 `capabilities` | 当前仅允许读取和枚举；读写需按挂载及实际权限开放 |
| 系统回调 | `apple/Apps/DsmMac/FileProviderExtension/FileProviderExtension.swift` | 修改失败、现存项目删除被拒绝；创建仅处理系统项目恢复，不是 NAS 上传 |
| 读取仓储 | `apple/Apps/DsmMac/FileProviderExtension/ProviderRuntime.swift` 的 `ProviderRuntimeRepository` | 只有读取和下载，不能直接拿现有回调当作写回队列 |
| 上传 | `apple/Packages/DsmNetwork/Sources/DsmFileRepository.swift` 的 `upload` | 有写权限预查和响应检查，但接口参数没有远端预期版本条件 |
| 重命名与移动 | 同文件 `renameResult`、`copyMoveResult` | 已有预查和结果复核可复用；仍需处理重试、稳定标识及文件夹后代路径 |
| 版本 | `apple/Packages/DsmCore/Sources/DesktopCloudDriveMetadata.swift` 的 `DesktopDriveItemVersionStrategy`；`ProviderItem.swift` | 当前调用用大小和修改时间构造内容版本，不是 NAS 提供的强版本令牌 |
| 持久化 | `apple/Packages/DsmCore/Sources/DesktopCloudDriveProvider.swift` | 已有跨进程文件锁、原子配置保存；旧版本会重写已知字段，不宜把不可丢弃队列仅放进可被旧版忽略的字段 |
| 移除与退出登录 | `apple/Apps/DsmMac/Sources/DesktopDriveMappingTransactionCoordinator.swift` | 必须在注销系统挂载及移除会话之前检查待上传内容，不能仅在最后删除配置时阻止 |
| 普通退出 | `docs/development/MACOS_QUIT_KEEP_MOUNTS_20260910_ZH.md` | 保留退出主 App 不断开挂载的行为；写回恢复不能依赖主 App 常驻 |

## 安全写入契约缺口

已核查 [Synology File Station 官方 API 指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)
的 Upload、Rename 与 CopyMove 参数说明（PDF 页索引 68、84、87）。
Upload 记录覆盖、跳过和同名报错选项，但没有记录“仅当远端仍是指定版本时覆盖”的条件参数。
Rename 和 CopyMove 的已记录参数也不能据此证明具备条件替换保证。
这是**当前已查证据未提供保证**，不是声称所有 Synology 接口都不支持该能力。

具体风险：Mac 读取版本 A → 预查仍是 A → 另一客户端写入 B → Mac 覆盖为 C。
上传后回读 C 只能证明本次结果存在，不能证明 B 没有丢失。再次预查、客户端互斥、
按大小/时间比较，以及先上传临时文件再重命名，均不能单独证明排除了该竞争。

此外，Upload 的不覆盖选项可能跳过同名文件；收到成功响应不能直接认定此次内容已上传。
新建路径也需要处理同名、响应丢失后的重复提交以及内容结果验证。

Apple 的 [File Provider 修改选项](https://developer.apple.com/documentation/fileprovider/nsfileprovidermodifyitemoptions)
提供冲突处理选项，但不为 NAS 请求自动补充服务器端条件写入能力。

### 契约调查授权与边界

用户随后已明确同意把独立的安全写入契约切片纳入本次范围，无需再次确认是否开展调查。
该授权不等同于安装 NAS 套件、启用新服务、提交第三方申请、修改认证方式、执行真实写入，
或减弱“不静默覆盖其他设备修改”的保证。不得猜测私有接口或用真实文件试写。

如果只能支持创建不覆盖的修改副本，应明确称为“另存副本”，不能包装为原文件编辑保存。
是否接受这一用户结果变化，需要用户决定。写回队列的提交、重试和完成判定依赖该选择，
本轮没有预先实现一套尚未确定提交语义的持久化结构。

## 公开资料调查结果（2026-09-10）

| 候选 | 已查证内容 | 判定与下一步 |
| --- | --- | --- |
| File Station 覆盖上传 | 公开参数没有预期版本条件；现有客户端只提供覆盖布尔值 | 不作为安全条件提交契约；不能盲加 `If-Match` 到 `entry.cgi`，其资源不等于 NAS 文件 |
| Drive 文件锁 | 官方明确锁保护 Drive 网页、客户端与移动端；仍可通过 SMB、Hybrid Share、File Station 编辑 | 不能采用“Drive 加锁 + File Station 上传”来提供跨入口互斥 |
| Drive 历史版本 | 版本保留数量可调整，版本控制可关闭 | 可用于恢复，但没有取得“每次条件提交与保留上一版本同属一个事务”的保证，不能替代冲突控制 |
| 官方 Drive REST API | 官方确认存在 Files API，包含上传和文件管理；详细文档需要账号及申请 | 当前最值得继续核查的官方候选；未确认条件更新、稳定 revision、提交结果及适用套件版本 |
| WebDAV 条件请求 | HTTP 标准有强 ETag 与 `If-Match`；Synology 规格说明支持 WebDAV HTTP/HTTPS | 协议有能力不等于该 NAS 实现已验证；需额外服务、地址和认证方案，不自动改道 |

### 来源与证据边界

1. [Drive Admin Console 官方说明](https://kb.synology.com/en-global/DSM/help/SynologyDrive/drive_admin_console)：
   文件锁对 Drive 以外入口的限制；页面动态正文在普通抓取中不可见，本次由检索返回的官方页面正文取得，
   不把客户端描述或社区帖子当接口保证。
2. [Drive 版本存储管理](https://kb.synology.com/en-eu/DSM/tutorial/How_to_manage_storage_in_Drive)：
   可降低历史版本数、定期轮替或关闭版本控制。
3. [Synology Office Suite API 官方入口](https://www.synology.com/en-global/dsm/feature/productivityapi)：
   Drive Files API 存在；详细文档要求 Synology Account 登录及提交申请。
   其公开页面实际链接到 [官方 API 文档站](https://office-suite-api.synology.com)。
   本次匿名打开文档站被重定向至 Synology 身份认证，未取得接口正文；未代用户登录、提交表单或调用其他 AI。
4. [RFC 9110 §13.1.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.1)：
   强比较的 `If-Match` 用于防止丢失更新；条件失败不得执行对应方法。只引用标准语义，
   不据此声称 Synology File Station 或 WebDAV Server 实现已通过。
5. [Synology WebDAV Server 规格（DSM 7.2）](https://www.synology.com/en-global/dsm/7.2/software_spec/webdav)：
   该页未提供条件写入、崩溃提交或跨协议原子性保证。不得将历史规格推广到未验证版本。

所有结果均为公开资料核查，未达到目标 NAS 的 `observed`、`read-verified` 或 `behavior-verified`。
未发现可录入私有 API 兼容表的已确定新端点，因此本轮不创建猜测端点、fixture 或生产能力键。

### 取得官方 Drive 文档后必须回答的问题

- 基础条件：最低 DSM／Drive Server 版本，支持的文件夹范围，File Station 路径与 Drive 项目标识如何映射。
- 认证：是否可安全复用现有授权，是否需要独立凭据或会话；不把当前 SID 直接发给未知端点。
- 版本：修改内容、同大小快速修改、删除重建以及其他入口修改时，是否都会改变强版本令牌。
- 提交：是否有预期 revision 或条件更新；条件核对是否与最终替换不可分割，而非仅在上传开始时核对。
- 新建：同名必须明确冲突；不得把“跳过”当此次创建成功。
- 重试：是否有幂等标识或可查询的上传会话；断线、取消和响应丢失后如何识别已提交结果。
- 结果：能否核对目标项目、最终内容与新版本；历史版本是否有明确保留和失败语义。
- 移动：稳定标识、目录后代、同名冲突与多步骤失败如何处理，不能仅有内容写入就宣称全流程完成。

### 五端影响评估（候选阶段，不是新增生产契约）

| 平台 | 当前变化 | 若采纳 Drive API 的影响 |
| --- | --- | --- |
| macOS | 无运行时变化，挂载只读 | File Provider 内接入经确认的写入能力；需要与现有读取的标识、版本、认证一致 |
| iPhone | 无变化 | 共享 Apple 接口仅增量兼容，不自动启用 Files 写回 |
| iPad | 无变化 | 同 iPhone，不扩张移动端范围 |
| Windows | 无变化，原只读挂载不变 | 记录未来条件提交语义，不在本任务实现 |
| Android | 无变化 | 仅记录契约影响，不修改 Android 代码 |

迁移和回滚仍沿上述只读默认及待上传保护要求；文档未证明候选可用前，不增加套件依赖或改变持久化格式。

## 已登录官方文档复核（2026-09-11）

用户已登录官方文档并授权读取，文档访问缺口已解决，不再要求用户重复登录或提供同一批页面。
本轮仅操作文档导航、版本选择和 Schema 显示，未填写 NAS 地址、凭据，未操作接口执行按钮，
未导出登录材料或记录官方示例中的账号与项目值。以下均为文档级 `static` 证据，不是 NAS 请求观察结果。

### 环境与已确定的请求边界

- [v1 简介](https://office-suite-api.synology.com/Synology-Drive/v1#overview)：DSM 7.2.2 nano3 及以上，Drive 3.5.2 及以上。
- [v2 简介](https://office-suite-api.synology.com/Synology-Drive/v2#overview)：DSM 7.2.2 nano3 及以上，Drive 4.0.0 及以上。
- 以上是 API 所需 NAS 环境，不是对本项目最低 macOS 或现有只读功能最低 DSM 的修改。
- [v2 登录](https://office-suite-api.synology.com/Synology-Drive/v2#post-/api/SynologyDrive/default/v2/login)：
  `POST /api/SynologyDrive/default/v2/login`，JSON 请求 Schema 仅列出 `format`、`account`、`passwd`；
  后续接口要求 Cookie 中的会话。文档未证明当前 App 会话可直接复用，也未在该 Schema 中说明 OTP／多因素流程。
  不因此另存密码、自动重登或削弱已有认证。

| 用户操作 | v2 文档中的方法与路径 | 确认内容与限制 |
| --- | --- | --- |
| 读取信息 | `GET /api/SynologyDrive/default/v2/files` | 有 `path` 参数，接受文件 ID 或文档列举的 Drive 路径形式；不是无条件复用 File Station 路径的证据 |
| 上传内容 | `PUT /api/SynologyDrive/default/v2/files/upload` | multipart 请求，有 `file`、`path`、`conflict_action` 等字段；未列出预期版本、条件请求头或幂等键 |
| 新建项目 | `POST /api/SynologyDrive/default/v2/files` | 同名策略默认 `stop`；可直接提交 Base64 内容，但文档限制为 1 MB，较大内容走上传接口 |
| 重命名 | `PUT /api/SynologyDrive/default/v2/files` | `name` 修改名称，Schema 明确同名时报错；未列出预期版本条件 |
| 移动 | `POST /api/SynologyDrive/default/v2/files/move` | `files`、`to_parent_folder`、`conflict_action`、`dry_run`；返回异步任务 ID，不能将任务已创建当成移动完成 |

### 上传和版本：解决了哪些疑问，哪些仍没有答案

[v2 上传](https://office-suite-api.synology.com/Synology-Drive/v2#put-/api/SynologyDrive/default/v2/files/upload)
与 [v1 上传](https://office-suite-api.synology.com/Synology-Drive/v1#put-/api/SynologyDrive/default/v1/files/upload)
均列出 `overwrite`、`autorename`、`stop`、`version` 四个 `conflict_action` 值。
定义针对目标目录中的**同名冲突**，不是针对“远端从基础版本发生变化”的条件提交。
请求字段还包括类型、时间、标签及相关属性，没有列出 `base_version`、`expected_revision`、
`If-Match`、上传会话完成条件或重复提交标识。只描述所读页面，不据此断言所有未公开接口均无此能力。

`version` 只在该页作为可选值列出，未说明版本控制关闭、空间不足、并发写入和中断时的保留保证；
不能仅凭名称把它实现为“必定保存上一版本且不会丢失修改”。页面关于类型字段的 patching 提示，
也不能作为未列出的 PATCH 方法或条件更新契约。

[v2 元数据](https://office-suite-api.synology.com/Synology-Drive/v2#get-/api/SynologyDrive/default/v2/files)
确实给出 `file_id`、`parent_id`、`version_id`、`hash`、`revisions` 和操作权限：

- 这些字段有助于项目识别和回读；**返回版本号不等于允许按预期版本更新**。
- `hash` 定义为内容哈希，但未说明算法；不得从示例字符串长度推断算法并写入实现。
- `version_id` 的 Schema 标为非负整数，Example 却展示字符串；必须记录文档歧义，不能选择其中一种并宣称真实响应已验证。
- 文档没有保证 File Station／SMB 修改与 Drive 版本索引更新即时一致。
- `can_write`、`can_rename`、`can_organize` 等可用于能力判断候选，不能取代提交时的权限执行。

[v2 重命名](https://office-suite-api.synology.com/Synology-Drive/v2#put-/api/SynologyDrive/default/v2/files)
与 [v2 移动](https://office-suite-api.synology.com/Synology-Drive/v2#post-/api/SynologyDrive/default/v2/files/move)
均未在已读请求 Schema 中列出基础版本。移动默认同名自动改名；若将来用于 Finder，
必须明确选择与用户操作相符的策略，不能沿用默认值静默改变名称。
`dry_run` 与真实提交是两个步骤，不构成事务。

### 调查结论与下一步决策

1. 官方 Drive API 是真实可研究的文件管理接口，但本轮没有取得解决条件覆盖的契约保证；
   不以“接上新接口”宣称安全写回问题已经解决。
2. 当前不建议仅为本问题强制增加 Drive Server 依赖：它引入环境、路径、认证和版本适配成本，
   却尚未证明能满足原定的跨入口不静默覆盖要求。
3. 若坚持原定保证，需要 Synology 针对以下问题给出明确契约说明，或另选有明确条件写入保证且获用户同意的服务：
   - 是否支持在最终替换时原子核对预期版本；具体请求字段／请求头和冲突结果是什么？
   - `conflict_action=version` 是否在每次成功提交时可靠保留被替换内容；版本控制关闭和存储失败时如何处理？
   - 对 File Station／SMB 并发写入、提交响应丢失和取消，有哪些明确保证及恢复接口？
4. 上述询问未发送给 Synology。不得自动联系第三方、测试真实写入，或把预查加事后回读降格为完整保证。
5. 实机可验证具体版本的行为，但少量成功用例不能证明所有并发时序均安全；有歧义的原文件覆盖入口继续关闭。

官方资源页提供 OpenAPI 下载链接；本次将其作为新标签页打开时浏览器报告阻止访问，
未绕过该限制、未取得下载正文。结论来自已实际读取的文档及 Schema，不声称扫描了整个 OpenAPI 文件。
本轮无生产契约或平台能力变更，前述五端影响评估保持候选状态。

## 后续实施顺序

1. 明确安全写入契约及编辑原文件的完成语义；未知或未经验证的能力保持关闭。
2. 实现独立于下载缓存的待上传内容与操作记录：绑定挂载、项目、基础版本和操作标识，
   保护文件及记录一致性，跨进程防重复执行；提交结果不确定时先核对，不盲目覆盖重试。
3. 处理稳定项目标识、重命名和文件夹移动的后代路径；接入创建与修改回调。
4. 接入挂载读写选择、权限、失败恢复及双语文案；移除挂载和退出登录前保护待上传文件。
5. 独立集成复核、只读对抗检查、聚焦测试、本地化检查和包含扩展的 macOS 构建。
6. 正式签名扩展在专用 NAS 目录进行用户验收，完成前不对正常挂载开放写入。

迁移：旧挂载保留只读，不自动迁移为可写；队列不能由旧版配置重写或缓存清理删除。
回滚：关闭新的写入请求，先上传完成或明确导出待上传修改，再退回只读；不自动丢弃队列。

## 跨端与非目标

- 当前实施目标仅 macOS；共享 Apple 代码的后续增量须运行 macOS 回归。
- iPhone、iPad、Windows、Android 不新增写入能力；若新增公开契约，必须另行完成五端影响评估。
- 本次不做 Finder 删除、跨挂载移动、协同编辑、文件锁服务、驱动或 SMB 接入。
- 不把“每次保存都生成新副本”视为已完成原文件编辑。

## 验证记录

- 前期文档调查：已运行 `git status --short`、相关源码 `rg` / `sed` 检查，读取已登录的官方 v1/v2 页面及相关 Schema，没有运行 NAS 请求。
- 实施后全量 `swift test --package-path apple --jobs 4`：1015 项 XCTest，959 通过、56 跳过、0 失败；另有 12 项 Swift Testing 通过。
  56 项跳过由项目原有条件控制：54 项合成界面检查、1 项十万条元数据基准、1 项需要外部测试资料的 QuickConnect 实机检查。
  全量过程中系统打印通讯录服务连接警告，未导致测试失败；未输出或保留用户通讯录数据，不据此改动无关系统配置。
- `ProviderWritebackTests` 新增 17 项：只读拒绝、有信息／无信息保存、变化冲突、读取失败、响应丢失后恢复、禁止盲重放、单次人工重试授权、
  新建文件和目录、空文件、移动／改名及原路径重用、移除／退出保护、跨实例互斥和另存停止。
- `DesktopDriveWritebackStoreTests` 新增 4 项：旧配置解码、记录损坏不冒充空队列、独立记录恢复、文件夹后代标识与固定路径迁移。
- `ConnectionFlowTests` 新增 1 项验证待上传修改阻止主动退出和删除连接，工作区及会话不被清除；原有登录回归保留。
- 本次合成界面单独执行：

  ```sh
  LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test挂载写回设置双语主题状态绘制' \
    bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-writeback-ui.9isPZg
  ```

  覆盖空内容、冲突、结果未知、读取失败四种状态 × 中英文 × 浅深主题，共 16 组绘制。
  以图片检查修正了透明背景、深色按钮对比和长英文按钮排列；不把合成绘制当作 VoiceOver 或 Finder 实机测试。
- 用户随后要求优化样式：仅调整设置 Sheet、双语展示文案及合成绘制测试，不修改保存逻辑。
  按 `ui-ux-pro-max` 的原生控件、主次操作和渐进显示原则，使用紧凑标题与挂载名称、独立开关行、
  文件卡片、状态标签、一个主要保存按钮及次要操作菜单；保留危险操作原有确认。
  不引入 Web 字体、图标依赖或新的全局主题，继续使用系统语义字体、SF Symbols 和项目主题色。
- 样式优化后命令：

  ```sh
  LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test挂载写回设置双语主题状态绘制' \
    bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-writeback-refined-ui.lkNuZZ
  ```

  新增多文件／长文件名、只读状态，合计 6 种状态 × 中英文 × 浅深色 = 24 组绘制通过；
  合成测试用活动控件环境检查主按钮，同时保持真实界面的原生窗口激活行为。
  最终样式再次通过下述完整 App／扩展构建和本地化检查。未把渲染测试当成真机屏幕阅读器验收。
- 用 `xcodegen generate` 按既有流程更新 Mac 工程，变动仅为新增设置 Sheet 和扩展使用既有本地化模块。
- 完整 Mac App／扩展构建命令：

  ```sh
  xcodebuild -quiet -jobs 4 \
    -workspace apple/DsmNativeClient.xcworkspace -scheme DsmMac \
    -configuration Debug -destination 'generic/platform=macOS' \
    -derivedDataPath /tmp/lanstash-writeback-build.D52J8h \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG LANSTASH_WRITEBACK_VALIDATION' build
  ```

  未签名构建通过；核对包含主 App 与扩展可执行文件，并检查 DsmCore 的验收开关在此构建中确为开启。
  不安装、不运行；这不是可发布包，也没有完成签名或系统注册验收。
- `python3 tools/localization/check_localization.py`：中英资源、参数、引用和硬编码扫描通过。
- `python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check`：通过。

### 集成及只读安全复核

本轮由同一执行者另行逐段复核，不冒充其他模型审查。确认没有新增 NAS 端点、Drive 依赖、
凭据存储、应用标识、签名权限或其他平台写入口。NAS 写方法复用现有 Repository 的权限检查和结果模型。
持久化 `.submitted` 先于请求，未知上传用完整内容回读核对；一次确认不能授权失败后的无限重试。
移动后项目标识不变，原路径再次使用时分配新标识；目录移动前等待系统提交已有子项变化。
保存成功才清理对应备份；永久失败时可先另存副本再停止，不把停止状态标成 NAS 已保存。
普通退出主 App 的既有保留挂载逻辑未修改。

### 实际修改范围

- 扩展：`FileProviderExtension.swift`、`ProviderRuntime.swift`、`ProviderItem.swift`、`ProviderErrorMapper.swift`。
- 主 App：新增 `DesktopDriveWritebackSettingsSheet.swift`；修改 `WorkspaceView.swift`、`DesktopCloudDriveManager.swift`、`LoginViewModel.swift`。
- 共享存储：新增 `DesktopDriveWriteback.swift`；修改 `DesktopCloudDriveProvider.swift`，保持旧配置解码兼容。
- 资源与工程：中英文 `Localizable.strings`、`project.yml` 及生成的 `DsmMac.xcodeproj/project.pbxproj`。
- 测试：新增 `ProviderWritebackTests.swift`、`DesktopDriveWritebackStoreTests.swift`；补充 `ConnectionFlowTests.swift`、`WorkspacePresentationTests.swift`。
- 文档：本文更新当前决定、实施证据与待验收事项；前期调查保留为历史。

### 交付与清理

本地测试阶段未暂存、提交或推送；之后按用户要求准备 1.0.7 正式发布。测试源码保留，未降低既有测试断言或跳过条件。
本次独立构建目录约 1.4 GiB 与中间截图已移入系统废纸篓，可恢复，也可用上面的命令重新生成；
不清理项目已有 SwiftPM 缓存或用户安装的应用。
用户引用的两张初版截图保留，优化后的两张交付预览另存于源码之外，不覆盖原图。

### 本地测试包（2026-09-11）

用户要求生成本地测试包，沿用项目现有隔离测试版流程，未更改源码、应用身份规则或存储格式。
执行 `bash apple/Apps/DsmMac/package.sh`，固定选项为：

- `LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_BUILD_TYPE=Release`、`LANSTASH_TARGET_ARCH=native`。
- `LANSTASH_SIGNING_IDENTITY=-`、`LANSTASH_RUN_AFTER_PACKAGE=0`、`LANSTASH_ENABLE_ONLINE_UPDATES=0`。
- `LANSTASH_BUILD_NUMBER=20260911.1027`。
- 独立 `LANSTASH_BUILD_ROOT=/tmp/lanstash-local-package.CImZyG`；输出使用仓库内新建目录
  `apple/Apps/DsmMac/dist/local-test-writeback-20260911.Rf3HPw`，不覆盖或清理其他目录的旧包。

结果：`1.0.6 (20260911.1027)`，arm64 Release；生成 `LanStash Test.app`（约 47 MiB）及
`LanStash-1.0.6-arm64.dmg`（约 16 MiB）。沿用 `.localtest` 测试身份和隔离配置；在线更新关闭。
DMG SHA-256：`1ea31028e8b94b3f4cdaac25b66376478d0642d2f97f5af6af8bb2f4a0e04546`。

实际验证：

- 打包脚本的源码成员检查、临时签名、Hardened Runtime、唯一库验证例外、组件实际加载及 DMG 校验通过。
- `hdiutil attach -readonly -nobrowse -mountpoint /tmp/lanstash-local-package-mount.km3KPn <本次 DMG>` 后，
  对镜像内 `LanStash Test.app` 再执行 `bash tools/release/verify_macos_local_test.sh`，通过且实际加载 Sparkle。
- `rsync -anic --delete <输出 App>/ <镜像内 App>/` 无差异；版本和构建号一致。这里的 `-n` 为只读比较，不删除文件。
- 打包前后 Apple 跟踪文件差异摘要一致，没有修改业务源码。
- 检查后用 `hdiutil detach /tmp/lanstash-local-package-mount.km3KPn` 卸载镜像；主 App 未安装或启动。

限制：本机临时签名流程会移除挂载扩展，并未开启写回验收开关。
此包用于主应用常规功能测试，不能验收 Finder 挂载、写回及依赖挂载入口的编辑设置流程。
正式签名／配套授权与真实 NAS 验收仍按下一节执行。

### 1.0.7 发布前复核

- 使用与云端一致的 XcodeGen 2.46.0，核验官方发布归档摘要后重新生成工程，不手改生成文件。
- 新增变化检查标记放在系统的元数据版本中，保留旧版内容版本，避免将升级误判为文件内容变化。
  只改变元数据时不拒绝相同内容版本的下载；保存时已知基础信息丢失仍停止，不降级覆盖。
- 系统刷新基础版本后，相同未确认操作仍复用原记录；不会因此新建一次覆盖请求。
- 独立复核以合成损坏配置复现了“只读快照被写入路径沿用”的问题，新增回归先失败后修正：
  每次写入在挂载互斥内重新读取磁盘配置，损坏、移除、暂停或恢复中的状态不发送 NAS 写请求。
- 退出登录回归补齐独立挂载配置目录注入，保留原断言，避免依赖本机实际共享容器的状态。
- 本地发布与签名回归 `python3 -m unittest discover -s tools/release -p 'test_*.py'`：27 项通过。
  云端会在锁定工具链下重新执行完整测试、构建和正式签名门禁，不以本机结果替代。

## PENDING_USER_VALIDATION

以下为源码与合成验证之后的实机验收，不再等待原先的原子覆盖契约。

- 条件：包含本次修改、带正式签名和有效共享权限的扩展，
  以及授权的可丢弃 NAS 文件夹。普通临时签名包会移除扩展，不能用于此验收。
- 从指定文件夹创建挂载（不选“全部共享文件夹”），打开“更多 → 编辑与未上传修改”，启用“允许编辑 NAS 文件”并确认覆盖风险。
  未主动启用的映射继续只读；1.0.7 正式版在指定文件夹挂载中提供编辑开关。
- 操作：新建、拖入、编辑保存、重命名、移动；断网/恢复、扩展中断/重启、响应丢失、
  同名文件、另一客户端并发修改；待上传时移除挂载或退出登录。
- 预期：只在核实保存结果后完成；可检测到的变化停止上传，用户检查后可以明确覆盖；未上传修改可恢复；普通退出不停止挂载；
  NAS 权限不足时安全失败；Finder 删除仍关闭。
- 必测：常用编辑器的普通保存／自动保存及临时文件替换；由于 Finder 删除尚未开放，依赖删除重建的编辑器可能需要“另存”，
  不能把当前单元测试当作所有编辑器均兼容。测试文本文件、常用办公文档和大文件时分别记录结果。
- 同时检查：正在保存时暂停／退出、断网后重试、NAS 拒绝写入、NAS 空间不足、上传被取消及回复丢失；
  目录移动和已打开的子文件、旧映射启用、系统重新拉起扩展、路径含中文、只读账号、VoiceOver 与键盘操作。
- 已接受的限制：检查与覆盖不是原子操作，时间／大小也不能识别所有修改；不会承诺企业协作、自动合并或 NAS 历史版本恢复。
  上传确认会再读取完整文件，流量和大文件耗时需实机评估。
- 回传：应用版本、操作顺序、错误类别及脱敏状态；不提供地址、凭据、真实路径或文件正文。
