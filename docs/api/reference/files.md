# 文件、传输、分享与远程连接

主实现：[DsmFileRepository](../../../apple/Packages/DsmNetwork/Sources/DsmFileRepository.swift) 及同目录 `+Advanced/+Permissions/+Settings/+ISO/+VFS/+ThemeImages`；领域入口：[FileRepository](../../../apple/Packages/DsmCore/Sources/FileStation.swift)。遵循[通用标准](common.md)，精确编码见[文件请求快照](requests.md#file-station)。

## 浏览与读取

| 用户结果 / 领域入口 | API / 方法 | 版本规则与输入 | 响应与映射 |
| --- | --- | --- | --- |
| 共享列表 `listShares` | `SYNO.FileStation.List.list_share` | 支持区间 1…2；`offset/limit/sort_by/sort_direction/additional`，共享根只按名称排序，不套普通目录类型过滤 | `shares/offset/total` → `FilePage` |
| 目录 `listFolder` | `SYNO.FileStation.List.list` | 支持区间 1…2；增加 `folder_path`，按 `FileListOptions` 编码排序和类型 | `files/offset/total` → `FilePage`；使用 NAS 页偏移及原始项目数 |
| 文件详情 `getInfo` | `SYNO.FileStation.List.getinfo` | 操作选择其支持版本；路径数组和所需 `additional` | 文件身份、大小、时间、所有者及权限 → `FileItem`，未知权限不当可写 |
| 缩略图 | `SYNO.FileStation.Thumb.get` | 绑定文件路径、尺寸与当前会话 | 二进制图片；JSON 错误不能作为图片 |
| 写权限 | `SYNO.FileStation.CheckPermission.write` | 目标目录/名称及实际覆盖意图 | 权限检查不等于后续写入一定成功，提交前仍核对目标 |
| 远程挂载目录 | `SYNO.FileStation.Info.get`、`VirtualFolder.list` | `VirtualFolder` 固定 v2；分别读取 SMB/NFS/ISO，保留不可用分区和截断信息 | `FileVirtualFolderPage`，失败分区不吞掉其他分区 |
| 大小 / 校验 | `DirSize.start/status/stop`、`MD5.start/status` | 目录大小固定 v2；仅轮询/停止本次任务 | 专用任务结果，取消与完成分开 |
| 收藏 | `Favorite.list/add/delete` | 当前账号会话，目标路径与名称 | 列表/写入后核对；不能以显示文案作为身份 |

2026-10-04 移动收藏维护复用公开 Favorite v2；共享 Apple 新增兼容的 `removeFavoriteResult`，旧 `removeFavorite` 调用保持。新增/移除回读保留 5000 项上限及截断标记，截断缺失不作为写结果；没有新增 NAS 字段、版本或权限。iPhone/iPad 接入文件与目录收藏和原目标恢复；macOS 的新增收藏共享回读随之修正并执行回归，既有移除入口不改变。Windows/Android 请求不变，仅记录相同的完整列表判断要求。

List 原始条目通常含 `name/path/isdir/additional`；领域时间、权限和文件类型由适配器解析。完整原始字段容器在 Repository 的 `FileListPayload/FilePayload` 中，不能将 `FileItem` JSON 直接当作 DSM 响应。

Android 权限读取按[官方 File Station API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)第 27、33、36 页使用 `additional.perm.acl.read/write/del`。NAS 在 POSIX 模式下也会返回当前用户的 ACL 派生权限，不根据 POSIX 数字自行猜测当前用户或群组。共享列表无 ACL 节点时可以使用明确的 `share_right=RO/RW` 读写摘要，但不推断删除权限。ACL 节点存在时，明确拒绝或缺项不能回退到更宽的共享摘要；已有扁平权限字段保留旧兼容，全部缺失时不授予权限。分享的旧路径入口也先读取当前权限再提交；本次未改变 NAS 请求参数或存储格式。

`additional.mount_point_type` 对普通本地项目可以是空字符串；Apple Adapter 将精确空串归一化为没有特殊挂载类型，非空值原样保留。该字段不替代 `perm` 权限判断，SMB/NFS 等特殊挂载的写入限制保持不变。2026-10-03 的只读观察、回归和五端影响见[挂载修复账本](../../archive/2026-h2/MACOS_FEEDBACK_HISTORY.md#本地磁盘挂载开启读写后仍只读修复账本)。

## 搜索与后台任务

- 名称/高级搜索使用 `Search.start → list → stop/clean`；条件以 [FileSearchRequest](../../../apple/Packages/DsmCore/Sources/FileSearchRequest.swift) 为输入，保持原始任务 ID 和完整分页。
- 正文搜索是内部扩展：v2 `search_content=true`、`search_type="advance"`，读取 `has_not_index_share` 并返回索引覆盖状态；缺少所需字段不能退回名称搜索后假称正文无结果。见[正文搜索记录](../discovery/endpoints/file-station-content-search.md)。
- `BackgroundTask.list` 固定 v3；指定任务停止和清理使用对应任务身份，不能拿文件列表刷新或任务从列表消失推断业务成功。保留不能控制的任务类型及权限限制。

2026-10-12 Android A3o 接入后台任务详情和指定记录控制：停止分别为 CopyMove v3、Delete v2、Compress v3、Extract v2，清理为 BackgroundTask.clear_finished v3 的单个 taskid 数组。控制前后严格分页检查完整数据、重复身份与总数；原任务编号、类型、完整创建时间（含小数）、版本和 start 方法必须相符。旧脱敏缓存不新增字段，刷新前仅供查看；独立加密恢复只保存原任务身份、动作和提交/回执事实，未知只读恢复、不重发，不存文件路径或原始正文。任务结束不代表文件处理成功，停止后已处理文件不回滚；清理不删除文件。参数和已有请求样例未变，其他四端源码不变；仓储/模型及手机、平板中英文浅深色、大字号聚焦检查已通过，真实 NAS、设备与 TalkBack 仍待专用环境验收，合成测试不提高真实证据等级。

2026-10-11 Android A3c 接入上述服务端高级字段、完整分页与正文扩展；条件作为当前工作区的读取状态，不写入旧持久化格式。结果列表/图标显示实际所在位置，排序复用已取得的完整结果，修改类型时同步既有筛选与搜索条件并重新查询，避免不同类型条件相互遮蔽。原版单次读取 1000 项后停止的实现已移除，搜索结束前不报空结果；缺少结束状态、总数或分页内容明确失败，当前任务清理有时间上限。A3f 继续接入 `/表达式/` 与 `/表达式/i` 名称正则：发送 `pattern=*`，完整读取后在后台按文件名筛选，原对象路径和其他条件保持；无效表达式或正文/正则组合不启动搜索。未闭合斜线和非 `i` 标志按普通关键词处理，匹配使用各平台原生正则引擎，不承诺全部高级语法跨引擎等价。NAS 参数和共享样例不变，其他四端源码只读，真实召回及多目录权限另验。

## 文件变更与传输

| 业务操作 | 请求族 | 必须保留的行为 |
| --- | --- | --- |
| 创建目录、改名 | `CreateFolder.create`、`Rename.rename` | 已迁移结果流程固定 v2；输入父目录/名称或原路径/新名称，拒绝含糊目标，回读实际项目 |
| 复制/移动 | `CopyMove.start/status/stop` | 目标和覆盖意图绑定；部分完成逐项返回；不能自动重发结果未知的操作 |
| 删除 | `Delete.start/status` | 确认完整目标、权限与任务；最后按成功回读判断消失，权限拒绝不能当删除成功 |
| 压缩 | `Compress.start` v3 | 固定压缩格式、目标名称与选中路径；任务成功后核对目标归档 |
| 解压与归档内容 | `Extract` v2 | 归档列表、密码、编码、指定成员、保留结构、覆盖意图见 [FileArchiveRequest](../../../apple/Packages/DsmCore/Sources/FileArchiveRequest.swift)；空选择不变成全部解压 |
| 上传 | `Upload` multipart | 流式进度、取消、目标权限、实际覆盖确认；没有公开字节偏移续传时从头重传并明确说明 |
| 下载 / 媒体 | `Download.download` | 支持时验证 HTTP 206、Content-Range 和实际字节范围；未完成副本与最终文件分开，不覆盖无关本机文件 |
| 文件夹上传 | 多次既有创建目录/上传 | 先形成固定上传计划，保留层级、空目录、每项结果与重试范围，不虚构批量原子 API |
| 跨 NAS | 两端已有下载/上传 | 每端独立会话/权限/证书，固定源与目标；只有已确认目标满足条件才处理源，不把复制失败当移动成功 |

回收站恢复不是通用“撤销删除”：保持目标身份、原位置、冲突策略及已记录的能力范围。Office 外部编辑自动保存是 macOS 本机工作流，复用读取、写权限、上传和回读；它没有新增 DSM Office API，也没有多人协作锁。其他端实现时保留未修改零上传、冲突暂停、未知结果只查看和保留本机副本的语义。

2026-10-04 共享 Apple 回收站适配补充：`moveToRecycleResult` 与 `restoreFromRecycleResult` 向后兼容接受普通文件夹，目录大小不作为身份比较；仍核对类型、规范路径、源修改时间、权限、同名冲突及最终源/目标状态。前者调用 Delete v2，并不能保证 NAS 开启回收站；只有目标回收站项目存在且原位置消失才报告移入成功。普通删除使用 `deleteResult`，只在最终读取确认原目标消失时报告删除成功，界面必须说明可能永久删除；回收站内删除明确无法恢复。恢复使用 CopyMove v3、`remove_src=true`、`overwrite=false`，不自动重建缺失的原目录。

共享删除还修复了路径裁剪风险：原实现会去掉路径两端空白，使 `/fixture/item.txt ` 与 `/fixture/item.txt` 混为同一删除目标。现实现只按原路径去重，提交、互斥及回读保持同一原始身份；非绝对路径不通过裁剪补正，而是直接拒绝。此修正适用于共享 Apple 的所有调用方，没有新请求参数。

2026-10-11 Android A3d 将同一身份语义接入新建目录的父路径、重命名、删除、复制/移动、分享路径锁和压缩/解压：文件名空白不再被裁剪，原路径用于对象快照、提交及回读；无效相对/点路径不自动纠正。现有表单新名称约束和目录分隔符兼容保持，权限、危险确认及不确定结果不重放保持；没有新增接口或修改其他四端源码，合成测试不提升真实 NAS 证据等级。

五端影响：iPhone/iPad 接入单项与最多 20 项的逐项删除/恢复及受保护的中断记录；macOS 继续原有操作语义，仅共享层增量需回归；Windows/Android 请求与实现不变，后续使用此语义时不得承诺所有删除都能恢复。本次没有新增 API、参数、权限或私有兼容版本，合成验证不代表真实 NAS 的回收站策略或嵌套内容已验证。

2026-10-04 移动 M2h3 复用 `Download.download` 的原始路径数组，文件夹/多项下载沿用 `downloadArchive`；未知输出大小时从头下载，不请求字节续传，也不调用 Compress 在 NAS 新建压缩文件。移动端增加源路径/类型及读取权限重读、现有活动恢复和系统保存/分享；共享请求、版本、认证与五端协议均不变，Mac 回归通过，Windows/Android 无代码变更。真实 NAS 输出内容仍需专项验收。

2026-10-11 Android A3g 复用同一公开 Download v2：单目录/多选通过原始路径数组保存一份 ZIP，普通单文件保持长度校验与 Range 续传。ZIP 来源清单与任务原子保存于独立加密键，按原账号恢复；暂停继续/失败重试从零输出，不把源文件大小当作 ZIP 大小。前台和 Worker 共用输出执行器，同一目标等待旧流关闭，清单损坏/丢失或原身份失效时在打开目标前拒绝，不降级为首个来源或父目录下载。失败 ZIP 保留目标供明确重试，取消/移除历史按 URI 引用清理；清单丢失提示重新选择文件。无 NAS 写入、额外 API 字段、旧下载结构或其他四端源码变化；合成 ZIP/系统保存测试不代表真实 NAS、后台系统终止或全部文档提供器通过。

2026-10-11 Android A3b 复用 `List.getinfo` 与 `Download.download` 完成上传中断的内容恢复：实际发送时计算完整 SHA-256，未知/取消后的成功判定必须匹配原正文；普通成功响应仍结合目标类型/大小读取。摘要通过既有加密存储的独立版本键绑定任务、连接和执行编号，旧任务不按大小认领成功。明确重试不覆盖现有不同内容，结果未知不重发；没有保存会话时仍允许当前已连接账号进行只读恢复。照片备份跳过已有文件也比较实际内容。没有新增 NAS 请求字段、权限、API 或旧任务格式；Apple 三端与 Windows 源码不变，不提升真实 NAS 的验证等级。

2026-10-11 Android A3e 沿用上述公开文件 API 接入完整目录上传：系统授权的固定来源清单保留根目录、空目录和原名称，先目录后文件，按原账号/目录校验权限。同名文件默认跳过，只有明确确认才覆盖；来源名称、大小和可用的修改时间在实际读取前复查。清单和逐项阶段存入独立加密版本键，原上传记录格式不变；先同步保存提交事实，取消不删除 NAS 内容，未知文件只读匹配原摘要，明确失败项通过用户继续恢复。没有增加 NAS 参数或私有 API，也不修改其他四端。真实提供器和 NAS 后台生命周期仍须按 Android 主计划验收。

## 压缩包内容与选择解压

2026-10-12 Android A3i 复用公开 Extract v2 的 `list/start/status/stop` 与既有请求样本，接入包内目录、完整分页、明确所选 ID、名称编码、密码、目标目录、保留结构、新建同名目录和覆盖意图。`itemid` 与官方示例中的 `item_id` 均可读取；返回路径是包内相对路径，不能裁剪绝对/父目录路径后继续写入。空所选集合、重复/变化的编号、缺失页、跨目录条目和扁平化同名冲突均在写入前拒绝。提交所选使用逗号分隔的 `item_id`，未改变既有表单编码或 API 版本；[官方字段和例子](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)见第 96、99、100 页。

提交前完整读取归档目录树并核对所选快照、源读取权限和目标写入权限；保留原路径、逐项输出类型及可用尺寸。已有目录和覆盖文件必须观察原任务结束并回读匹配，连接中断或缺少任务编号不能以原文件存在认定成功。独立加密清单和原任务输出同时保存，不含密码；原账号只读恢复原编号，清单丢失/损坏不降级到旧存在性判断，同一未结束目标禁止重复提交。新压缩界面传递既有 ZIP/7z、四种压缩级别和密码，不裁掉用户文件名中的其他点号。五端请求契约不变，Apple 三端和 Windows 未改代码；Android 合成验证不提升真实 NAS 的证据等级。

## 分享与文件收集

`SYNO.FileStation.Sharing` 的公开基础与内部扩展分开对待。创建/编辑结果流程固定 v3；每个目标独立结果，链接 ID 不从文件名推导。密码“保留/替换/清除”是不同意图；公开范围变化、移除密码、允许持链接者上传须展示实际后果。

高级收集、访问次数、具名用户/群组及返回字段见[分享扩展记录](../discovery/endpoints/file-station-sharing-extended.md)、[编辑领域模型](../../../apple/Packages/DsmCore/Sources/FileShareLinkEdit.swift)和请求快照。批量部分失败不覆盖已完成结果，不自动重发已创建链接。

2026-10-11 Android A3h 已接入上述 Sharing v3 与 UserGrp v1：逐目标创建、批量编辑/删除、完整成员分页和新增成员差量、日期保留/清除/替换、密码保留/清除/替换、访问次数及文件夹收集。缺失保护或日期字段保持未知，不用于判成功；保留日期时不发送参数，保留原时分秒。创建必须取得本次响应中原路径对应的新编号，不能按同名/同路径链接推导；设置新密码需要成功响应和密码状态回读，单凭已有密码标志不能确认替换。

分享写前保存独立加密结果记录，绑定原账号身份；记录只包含原目标、编号/网址、预期字段与成功回执，不保存密码，也不能生成重放请求。重新登录同一账号后只读原编号恢复，缺编号或结果不匹配继续保留，其他账号不接管。普通创建/保存使用按钮提交，允许上传、移除密码或改变访问范围显示具体后果；批量停止只停止尚未开始的项目。系统分享及二维码只使用用户选择的链接，二维码在本机生成。没有新增 NAS 字段或其他四端源码变化；真实 NAS 私有扩展写入仍按主计划保留 `PENDING_USER_VALIDATION`。

## 权限、ISO 与 File Station 设置

Android A3j 接入既有所有者/ACL/POSIX 契约，显式规则可编辑、继承规则只读，支持成员搜索与目录子项应用；共享根、回收站和挂载位置只读。保存必须具备明确应用/动作授权、必要管理员角色、两次快照、自锁检查和具体风险确认。独立加密恢复记录只保留目标/账号、结果摘要和原任务回执，重启后不重放；递归部分失败不能由根项匹配判定成功。五端请求字段与版本不变，不增加真实 NAS 证据，详见[权限记录](../discovery/endpoints/file-station-file-permissions.md#2026-10-12-android-接入)。

Android A3k 接入 ISO 的空目录挂载、自动连接确认、列表浏览和断开；未结束操作按原账号加密保存，只读恢复且与权限修改互斥。严格区分普通挂载类型的精确空串和缺字段；不删除 ISO/目录、VFS 独立推进，见[Android ISO 记录](../discovery/endpoints/file-station-remote-mount.md#2026-10-12-android-iso-适配)。
Android A3l 接入 SMB/NFS 创建、浏览、同位置/换位置编辑、断开与独立加密分步恢复；密码不保存，未知只读、继续需明确动作，关联 ISO/权限写互斥。普通连接由动作按钮确认，自动连接和修改后果具体说明；真实环境验证仍待完成，见[Android SMB/NFS 记录](../discovery/endpoints/file-station-remote-mount.md#2026-10-12-android-smbnfs-适配)。
Android A3n 已接入常规设置、分享/收集名单、远程访问范围与本机/域/LDAP 名单、六类账号限速和每周时间表；分享页外观/图片仍在实施。保存使用完整原快照与差量字段，未知结果只读比较持久期望摘要，保留原账号和来源；`notexist` 不回写，目录来源失效阻止旧名单写入，Core 管理授权不绕过。设备测试与真实 NAS 验证分开记录，见[Android 设置记录](../discovery/endpoints/file-station-package-settings.md#2026-10-12-android-设置接入)。

| 功能 | 接口组 / 版本 | 原始结构与精确约束 |
| --- | --- | --- |
| ACL、POSIX、所有者 | `SYNO.Core.ACL`、`FileStation.Property/ACLOwner` v1，`List.getinfo` v2 | [权限记录](../discovery/endpoints/file-station-file-permissions.md)；真实路径由 NAS 返回，不猜卷路径；保留继承、递归、所有者及移除权限的独立确认 |
| SMB/NFS 与 ISO 挂载 | `FileStation.Mount`、`Mount.List` v1 | [挂载记录](../discovery/endpoints/file-station-remote-mount.md)；绑定挂载点及来源，未知只读恢复，不自动停止或替换其他连接 |
| 套件设置、远程账号、限速、分享页面 | `FileStation.Settings/VFS.User`、`Core.BandwidthControl`、`Core.Theme.*` v1 | [设置记录](../discovery/endpoints/file-station-package-settings.md)；管理员与文件服务授权分别检查，多接口保存不是原子事务 |
| 目录账号来源 | `Core.Directory.LDAP` v1、`Core.Directory.Domain` v1/v2 | local/domain/ldap 与 user/group 绑定原快照，域请求值不使用显示名称 |
| 分享页图片 | `Core.Theme.Image.list/get/upload` v1 | 图片上传仅加入历史；应用主题是独立保存。未知上传禁止重复发送同一图片 |

## FTP、SFTP、WebDAV 与云盘

这些是 NAS 管理的远程连接，接口均为内部 v1；不是本机直接实现 FTP/WebDAV。详见[稳定端点记录](../discovery/endpoints/file-station-vfs-connections.md)与 [FileVFSConnection](../../../apple/Packages/DsmCore/Sources/FileVFSConnection.swift)。

| API / 方法 | 业务参数 | 返回与语义 |
| --- | --- | --- |
| `VFS.Protocol.list` | 无额外业务参数 | `protocols[]`：`protocol/name/default_port/has_server`；`has_server=false` 不代表不能创建 |
| `VFS.Profile.list/get` | get 使用 `id` | `profiles[]` 或详情；`id` 为不透明身份，`connect_status` 映射 connected/disconnected/unknown；不解码密码供回显 |
| `VFS.Connection.create`、`VFS.Profile.create` | `protocol/hostname/port/alias/account/password/codepage/uri_path/max_connection`；Connection 使用 `force=false` | 连接与保存分别请求、分别核对，第二步失败不能盲目重连 |
| 已保存连接 `Connection.create` | `profile_id` | 权限和当前断开状态检查后执行；确认成功才刷新为已连接 |
| 编辑 `Connection.set`、`Profile.set` | `id` 与实际配置；密码未替换时不发送占位密码 | 固定原连接身份/类型，逐步结果检查 |
| 断开 / 移除 | `Connection.delete` / `Profile.delete`，`id` | 断开保留连接记录；仅已断开的记录可移除，均不删除远端文件 |
| 浏览 | 公开 `FileStation.List.list` | 使用 NAS 返回的原始远程 URI，禁止转换为本机路径或跳出该连接根目录 |

完整 WebDAV 网址是表单输入便利功能：解析为主机、HTTPS 类型、端口和 `uri_path` 后仍发送上述字段；不是新增 API 参数。网址不能嵌入账号密码或任意查询字段，路径冲突由用户修正。

云盘类型取实际 `Protocol.list` 与已支持供应商的交集。macOS 使用系统浏览器及一次性本机回调接收授权，`account/access_token/refresh_token/client_id/expires_in` 仅在当次内存中；不发送 NAS 会话给授权网站，不把令牌写入待查看结果。登录启动、授权回调和 NAS 保存是三段不同证据。

Android A3m 接入相同内部参数和动态协议，使用原生管理/表单与系统浏览器。单文件下载的连接身份、父目录与文件快照独立加密保存，每次执行先重查原连接与原文件，再打开本地目标；不把远程 URI 放宽为普通 NAS 写路径。组合写分别保存回执，未知只读且不补发。当前源码/合成与模拟器状态见[Android 适配记录](../discovery/endpoints/file-station-vfs-connections.md#2026-10-12-android-a3m-适配)，不提升真实云授权或 NAS 写证据。

macOS 用户流程标准：普通连接按钮直接执行；保存等待有进度文字；成功关闭表单并刷新；主页展示远程连接，已连接条目有独立“浏览文件”按钮。失败、权限不足、结果未知保持不同状态；未知只查看原操作结果。

## 验证与跨端

相关模型：[FileStationAdvanced](../../../apple/Packages/DsmCore/Sources/FileStationAdvanced.swift)、[RemoteMountOperation](../../../apple/Packages/DsmCore/Sources/RemoteMountOperation.swift)、[权限模型](../../../apple/Packages/DsmCore/Sources/FilePermissionEditing.swift)。网络回归集中在 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmFileRepositoryTests`、`FileStationParityTests`、`RemoteMountRecoveryTests`、请求快照测试；macOS 工作流在 [DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/)。

移植时先覆盖浏览/传输，再逐项接入写操作。File Station 扩展、Office 本机自动保存和桌面系统挂载不是同一个完成项；移动端范围按专项计划，不能把 macOS 测试当作其他端验收。


2026-10-04 移动 M2h4 复用 List/getinfo/MD5、现有跨 NAS Download/Upload、CreateFolder 与 `deleteResult(recursive: false)`，共享请求、版本、认证与五端协议不变，Windows/Android 无代码修改。移动端两端会话分别装配，先冻结完整清单并核对内容，不覆盖同名输出；已确认复制之后才显示独立删源确认，删源前重读内容与权限，逐文件/空目录非递归删除。未知文件写入仅完整比对，未知建目录不根据同名对象继续写入；重启不重放已完成或未知步骤。公开删除 API 不提供与 MD5 联动的原子条件删除，仍有外部并发修改窗口，不能将合成测试等同真实 NAS 验收。平台范围及限制见移动 M2h4 账本。

2026-10-12 Android A3p 已接入相同的持久分步流程。新增严格 List/getinfo 读取：分页总数/偏移/行数、文件元数据、原路径和权限必须完整，漏字段不作为空列表或文件不存在；getinfo 只有原路径的明确 408 才可表示缺失。固定两端账号身份、源树与 MD5，逐项保存写前事实；重启将进行中的写步骤转为只读恢复。未知文件上传只比对两端完整内容，未知建目录不认领同名目录；复制后删源独立确认并逐项 `recursive=false`，保留源名称首尾空格。现有普通新建目录和普通删除的默认请求不变，既有传输存储不迁移。原生目的地选择、分步详情和全局本机任务已接入；复制后可独立确认删源，也可保留原项目并结束，本机结束/清理记录均不删除 NAS 内容。原自动删源协调入口已移除，固定容量管道仍由唯一队列使用。聚焦合成/模拟器验证不提高真实 NAS 证据等级；无需改动其他四端请求。



2026-10-04 移动 M2i 将 Office 六种格式加入本机 Quick Look，编辑副本下载与主动回传复用现有 GetInfo/Download/MD5/CheckPermission/Upload；没有新的 Office API 或请求字段。`DsmFileFeature/OfficeDocumentSupport` 共享稳定副本、内容摘要与格式白名单，Mac 仅调整引用；既有桌面自动保存行为与格式不迁移。iPhone/iPad 均保留未改零上传、原文件变化停止覆盖、上传后完整内容回读、未知不重放和账号隔离；Windows/Android 记录影响但无代码变化。公开 Upload 不提供原文件摘要条件下的原子覆盖，真实编辑器、NAS 与生命周期按移动 M2i 待办验证，不能推定五端全部通过。


2026-10-12 Android A3q 将六种 Office 格式接入系统副本打开/编辑与主动回传。沿用已记录的 List/getinfo、Download、MD5、CheckPermission 与 Upload；既有上传写锁内增加本流程的提交前检查，先检查原文件完整元数据与 MD5，再同步保存提交事实，然后发送唯一上传请求。导入时冻结本机副本并计算 MD5/SHA-256；未改内容零上传，原文件变化停止覆盖，写后读取完整文件比对，未知只刷新不重传。系统文件选择结果按原账号/会话和单次请求绑定；不在 Activity 返回时自动保存。独立加密索引与私有副本不迁移原传输存储，副本不纳入可再生缓存；移除连接前提示另存副本。公开 Upload 仍不提供按摘要的原子覆盖，不新增 API、系统权限、依赖或其他四端请求；真实编辑器/文档提供器/NAS 按 A3q 待办验收，直接系统原位编辑由 A9 单独承担。

2026-10-14 Android A9 系统分享接收沿用公开 `List.list_share/list/getinfo` 与现有 Upload Worker：通过 [Android 分享接收](https://developer.android.com/develop/ui/compose/sharing/receive) 取得明确授权的内容 URI，将完整文件复制到不参与备份的私有目录；文字转为 UTF-8 文本文件。来源 URI 和外部 Intent 不落入任务索引。每批最多100个不同名文件，固定原文件名、内容大小及所选连接/目标；进入目录和入队前刷新原账号授权及目标写权限，同名替换单独确认。

新增不导出、不授予外部访问的 `SharedInputProvider` 只供同应用现有 Worker 读取副本。独立加密索引保存草稿，整批上传任务与接收标记在原传输存储内一次提交，原任务格式不变；调度前中断的任务回到原账号任务页明确重试，已接受批次不再作为新草稿发送。副本在草稿取消或可清理任务记录删除后回收，未知上传继续沿完整内容摘要只读恢复。没有新增 NAS API、参数、第三方依赖或其他四端代码；18项分享 JVM 与11项既有上传恢复通过，六项原生系统/状态用例仅编译，真实系统入口、后台与 NAS 仍按 A9 验收。

2026-10-14 Android A9 `NasDocumentsProvider` 使用 [Android DocumentsProvider](https://developer.android.com/guide/topics/providers/create-document-provider) 的系统 `MANAGE_DOCUMENTS` 权限与逐 URI 授权。用户逐连接开启位置，根与文档只暴露随机编号；原身份、路径映射保存在独立加密索引中，凭据仍只来自原安全会话存储。新增 `DOCUMENT_PROVIDER` 归属键复用既有身份/会话代次，不改变旧登录或任务字段。浏览使用公开 List，完整分页拒绝缺页、重复或越界路径；文件内容通过 Download 复制为可定位读取的私有临时文件，检查实际长度、读取前后元数据和最终账号授权。正常关闭回收只读副本，进程重启清理上次只读临时文件。退出、改身份或关闭位置拒绝后续访问；已交付给外部应用的内容不能撤回。

单独编辑授权仅对实际可写的六种 Office 文件提供系统写标记，不声明创建、删除、重命名或移动。系统文件描述符操作原 Office 流程的独立工作副本，持有相同目标互斥；关闭只冻结本机候选内容，不发送 Upload。原 Office 加密版本1记录增量增加可选 `externalId`，旧记录默认空；异常关闭/进程中断保留工作副本，用户关闭编辑器后主动接收，NAS 覆盖仍须既有明确确认、原件元数据/MD5检查、提交事实与完整内容回读。正常接收后系统读取返回本机候选；未知上传不可编辑或重发。旧二进制不理解未接收的编辑编号，回退前先接收、导出或明确放弃这些副本，不能直接清空存储。

本片没有新 NAS API、参数、依赖、工具链或其他四端代码；Android 新增系统 provider 注册及私有索引，Apple/Windows 业务与契约不变。公开上传仍不能提供跨客户端原子条件覆盖。系统选择器、PFD关闭/错误与设置原生测试已编译，设备运行和真实 NAS 尚未验证，不能由 JVM 测试推定系统授权或编辑器兼容。


2026-10-14 Android A9 为照片显式上传/导出、Office 准备/主动保存及跨 NAS 阶段接入同一个非导出 `dataSync` 前台服务。沿 [Android 前台服务启动](https://developer.android.com/develop/background-work/services/fgs/launch) 先取得系统执行资格，再运行原领域协程；通知进度和取消只指向本次随机执行编号，打开入口沿原账号加密页面映射。没有复制网络或恢复协议，不改变普通文件 WorkManager 的执行器。使用已声明的前台服务权限，不新增权限、第三方库、持久请求或 NAS 参数。

[系统执行超时](https://developer.android.com/develop/background-work/services/fgs/timeout)、用户取消和模型销毁均取消原协程，并及时停止服务；原领域的写前保存、未知结果、冲突检查和只读恢复仍生效。服务不黏性重启，进程死亡不自动重放覆盖、上传或删源。照片选择器等待不占用前台执行时间，返回后本机保存重新申请；后台不停止已经取得执行资格的导出，切换账号/撤权仍取消并只清理本次临时文件。系统强制终止时来不及收尾的本机输出需用户检查，不能计作成功，不能为清理去删除无法确认归属的外部文件。正式系统行为与真实NAS仍分别记录，其他四端接口无变化。

系统目录定位实现了公开 [findDocumentPath](https://developer.android.com/reference/android/provider/DocumentsProvider#findDocumentPath(java.lang.String,java.lang.String))：从系统根或指定父目录返回包含两端的不透明文档链，逐级确认真实目录与原账号权限；指定父目录时不返回根编号，跨树与已退出连接拒绝。此补充来自实际DocumentsUI打开初始目录失败的系统日志，不更改NAS契约。

## 写入可用性与版本策略（五端统一）

五端均按实际接口能力、当前账号/对象权限、必要确认、防重复提交和结果复查开放操作；不匹配DSM/build/套件或客户端类型版本白名单，也不为版本匹配要求额外系统管理读取权限。未实测版本不标为已验证，但不据此关闭功能。

Android已移除A10误加的版本门和附加元数据查询。普通Photos/Chat账号可按套件与对象实际授权使用写入；文件设置、权限、挂载和系统管理仍保留功能本身要求的权限。能力缺失、参数或原对象变化、实际权限拒绝仍会停止对应操作；未知提交只读恢复，不自动重放。

版本记录用于追踪证据和排障，不构成功能白名单。本轮不改NAS接口参数、存储格式或其他端原有业务实现。源码与验证见[Android主计划](../../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md#a10-当前工作与剩余条件)。
