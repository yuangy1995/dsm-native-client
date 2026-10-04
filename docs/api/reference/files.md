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

`additional.mount_point_type` 对普通本地项目可以是空字符串；Apple Adapter 将精确空串归一化为没有特殊挂载类型，非空值原样保留。该字段不替代 `perm` 权限判断，SMB/NFS 等特殊挂载的写入限制保持不变。2026-10-03 的只读观察、回归和五端影响见[挂载修复账本](../../development/MACOS_MOUNT_WRITABILITY_FIX_20261003_ZH.md)。

## 搜索与后台任务

- 名称/高级搜索使用 `Search.start → list → stop/clean`；条件以 [FileSearchRequest](../../../apple/Packages/DsmCore/Sources/FileSearchRequest.swift) 为输入，保持原始任务 ID 和完整分页。
- 正文搜索是内部扩展：v2 `search_content=true`、`search_type="advance"`，读取 `has_not_index_share` 并返回索引覆盖状态；缺少所需字段不能退回名称搜索后假称正文无结果。见[正文搜索记录](../discovery/endpoints/file-station-content-search.md)。
- `BackgroundTask.list` 固定 v3；指定任务停止和清理使用对应任务身份，不能拿文件列表刷新或任务从列表消失推断业务成功。保留不能控制的任务类型及权限限制。

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

五端影响：iPhone/iPad 接入单项与最多 20 项的逐项删除/恢复及受保护的中断记录；macOS 继续原有操作语义，仅共享层增量需回归；Windows/Android 请求与实现不变，后续使用此语义时不得承诺所有删除都能恢复。本次没有新增 API、参数、权限或私有兼容版本，合成验证不代表真实 NAS 的回收站策略或嵌套内容已验证。

## 分享与文件收集

`SYNO.FileStation.Sharing` 的公开基础与内部扩展分开对待。创建/编辑结果流程固定 v3；每个目标独立结果，链接 ID 不从文件名推导。密码“保留/替换/清除”是不同意图；公开范围变化、移除密码、允许持链接者上传须展示实际后果。

高级收集、访问次数、具名用户/群组及返回字段见[分享扩展记录](../discovery/endpoints/file-station-sharing-extended.md)、[编辑领域模型](../../../apple/Packages/DsmCore/Sources/FileShareLinkEdit.swift)和请求快照。批量部分失败不覆盖已完成结果，不自动重发已创建链接。

## 权限、ISO 与 File Station 设置

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

macOS 用户流程标准：普通连接按钮直接执行；保存等待有进度文字；成功关闭表单并刷新；主页展示远程连接，已连接条目有独立“浏览文件”按钮。失败、权限不足、结果未知保持不同状态；未知只查看原操作结果。

## 验证与跨端

相关模型：[FileStationAdvanced](../../../apple/Packages/DsmCore/Sources/FileStationAdvanced.swift)、[RemoteMountOperation](../../../apple/Packages/DsmCore/Sources/RemoteMountOperation.swift)、[权限模型](../../../apple/Packages/DsmCore/Sources/FilePermissionEditing.swift)。网络回归集中在 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmFileRepositoryTests`、`FileStationParityTests`、`RemoteMountRecoveryTests`、请求快照测试；macOS 工作流在 [DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/)。

移植时先覆盖浏览/传输，再逐项接入写操作。File Station 扩展、Office 本机自动保存和桌面系统挂载不是同一个完成项；移动端范围按专项计划，不能把 macOS 测试当作其他端验收。
