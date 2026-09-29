# Photos 个人空间管理候选接口

端点组稳定标识：`photos-item-metadata`、`photos-album-management`、`photos-file-management`、`photos-upload`、`photos-sharing-management`。

## 证据与开放条件

2026-09-28 官方网页静态资源证据；环境见 `../environments/2026-09-28-photos-parity-observation.md`。所有新增方法均为 **内部 API**，当前等级 **static**，没有真实写行为结论。路径由 `SYNO.API.Info` 发现，候选为 `/webapi/entry.cgi`，JSON 格式业务参数通过 POST 表单编码；上传采用 multipart。

用户于本轮明确授权增量扩展共享契约与五端影响记录。`SynologyPhotosServing` 新方法默认返回不支持，Repository 的 `verifiedManagementFeatures` 默认空。仅合成测试显式注入能力；以上为 2026-09-28 首轮方案，已由下方 2026-09-29 授权更新取代。不得以功能开放代替版本行为验证。

## 端点分组与静态结构

| 分组 | API / 版本 / 方法 | 请求与结果 |
| --- | --- | --- |
| 元数据 | `SYNO.Foto.Browse.Item` v2 `set` | `id:[Int]`，一次传 `rating:0...5` / `description:String` / `time:Unix秒`。网页另有 `shift_time`，本轮未接入。回读 Item.get v5 的 additional.rating/description 与 time |
| 标签 | 同上 v1 `add_tag/remove_tag` | `id:[Int],tag:[Int]`。Item.get v5 additional.tag 回读。缺失 tag 字段不能当空数组；GeneralTag.create v1 `name` 返回 tag 对象，创建标签尚未接入 |
| 相册 | `SYNO.Foto.Browse.NormalAlbum` v1 `create/add_item/delete_item` | create(name,item) 返回 album.id/name；成员操作(id,item)。delete_item 仅移除相册成员，不删除原件 |
| 相册管理 | `SYNO.Foto.Browse.Album` v1 `set_name/delete/set_cover`、v4 `get` | set_name(id,name)，delete(id:[Int])，set_cover(id,id_item)；get(id:[Int],additional:[sharing_info,thumbnail])。owner_user_id 与当前用户 id 比较；缺失所有者拒绝写入 |
| 文件管理 | `SYNO.Foto.BackgroundTask.File` v1 `move/copy` | target_folder_id,item_id:[Int],folder_id:[],action:"skip"；返回 task_info.id。静态另有 overwrite，客户端不发送 |
| 任务回读 | `SYNO.Foto.BackgroundTask.Info` v1 `get_status` | id:[任务编号]，list[].id/status/completion/error/skip/overwrite。done 且无错误、无跳过、完成数量匹配才确认；移动另按照片编号核对目标文件夹 |
| 上传 | `SYNO.Foto.Upload.Item` v1 `upload/upload_to_folder` | multipart file，name、mtime、duplicate:"rename"。upload 使用 folder:["PhotoLibrary"],uploadDestination:"timeline"；upload_to_folder 使用 target_folder_id。非文件业务字段 JSON 编码。返回 data.id/action，再按 id 回读照片大小/文件夹 |
| 分享 | `SYNO.Foto.Sharing.Passphrase` v1 `set_shared/update` | set_shared(policy:"album",album_id,enabled)；update(passphrase,permission:[{action:"update",role:"view"或"download",member:{type:"public"}}])。最终回读 Album.get shared、sharing_info.privacy_type/sharing_link |

## 权限、副作用与结果语义

- 仅个人空间；照片必须属于当前 profileID/space，身份核对文件名、大小、拍摄/索引日期、文件夹和类型，再核对 Folder.get v2 access_permission.view/manage。相册须确认所有者；目标文件夹独立核对管理权限。
- 最大单次照片集合 100 个，与网页元数据批次一致；超过数量拒绝，不能悄悄丢弃多余选择。
- 全部新写操作按 operationID 绑定不可变命令；提交前登记，未知结果只读取，不重放；相同编号不能更换目标。未知操作阻止再次写入，删除与新增管理操作互斥。
- 明确单请求权限/会话拒绝结束本次操作且不重发；多阶段分享失败保持核对状态。分享先关闭公开访问、再设置权限、最后开启，避免中途失败扩大旧权限。密码/有效期/具名成员不在本轮实现，不发送这些字段。
- 未拿到新相册/上传/后台任务编号的断网结果无法可靠追认，不通过名称猜测成功，也不自动重试创建。该限制需专用环境验证与后续恢复设计，入口继续关闭。
- copy 使用后台任务最终计数作为完成证据；move 额外核对每个原照片编号。任务结束但有 skip/error 报部分完成。真实响应中的计数字段语义尚待 behavior-verified。
- 上传以磁盘临时文件组织 multipart，逐块复制，临时文件权限 0600，结束删除；会话仅使用既有 Cookie/token header，不进入 URL。
- 新操作状态为内存状态，未改变持久化格式；进程退出后的未知结果恢复尚未实现，因此不得在真实资料上开放未经验证的写入。

## 自动化与待验证

合成回归覆盖默认关闭、评级回读、未知结果不重放、标签字段缺失、相册非所有者、相册创建回读、复制跳过、上传 multipart/身份回读、明确权限拒绝、分享权限回读与中途失败；测试路径 `apple/Packages/DsmNetwork/Tests/SynologyPhotosRepositoryTests.swift`。

`PENDING_USER_VALIDATION`：提供专用可丢弃的合成照片/相册/文件夹，记录 DSM 与 Photos 完整版本，分别验证上述组。不得用真实照片验证；分享需要单独确认访问范围，删除需确认具体可丢弃对象。只回传脱敏的步骤、错误类别、是否产生重复项、结果是否保持原位置，禁止传凭据、真实地址或内容。通过后才允许按环境与功能启用。

## 2026-09-29 用户明确要求取消默认禁用

用户确认专用合成资料的真实 NAS 验证，并明确要求“代码中不要限制禁用功能”。已移除 Repository 的 `verifiedManagementFeatures` 字段、构造参数与空集合白名单；实际服务枚举六类管理能力，并依据 NAS 的 API 版本与 JSON 格式判定是否支持。不新增测试模式、版本白名单或替代关闭开关。

执行时继续进行目标身份、个人空间、目录管理权限、相册所有者、确认快照、防重复提交及结果回读。这些是正常操作条件，不是未验证功能禁用。协议扩展的默认“不支持”仍用于尚未实现该协议的适配器，不影响实际 SynologyPhotosRepository。

更新回归验证：接口完整时默认开放全部六类功能；空间访问建立前不暴露管理能力；仅缺 Upload.Item 时只影响上传。真实 NAS 使用新建纯色图片与专用相册验证，现有用户照片保持不变；不创建公开分享、不删除测试资料。开放不等于所有 NAS 版本已验证。


## 继续对齐：多文件上传与封面展示

- 多选上传在 macOS Model 按文件串行调用既有 upload/upload_to_folder，不新增 NAS 批量上传接口。每项保存文件大小/修改时间快照和独立操作编号，并展示单项进度、失败与待核对状态。
- 在文件夹中上传使用已有 target_folder_id；在相册中上传先调用个人图库上传，取得并回读照片编号后调用既有 NormalAlbum.add_item。加入失败保留已上传编号，用户重试只补加入步骤，不重复传输文件。未知结果阻止后续写入，核对成功再继续队列。
- “完成当前文件后停止”保留当前确认流程，未开始项转为已停止，可逐项重试。队列目前为内存状态，不提供退出重启后的恢复，也不声称后台传输能力。
- 相册单选照片可设置封面。写前要求照片属于目标相册、相册所有者匹配，写后 Album.get additional.thumbnail.unit_id 必须等于原照片编号。重复 operationID 不重发。
- 相册列表保留已存在的 additional.thumbnail；共享领域模型 SynologyPhotoCollection 新增可选 thumbnail（初始化默认 nil），服务新增 thumbnail(for: SynologyPhotoCollection) 默认不支持实现。真实 Repository 按相册编号重新读取当前会话封面后，使用既有认证缩略图通道；不直接信任旧会话的封面编号。
- 所有新增流程仍复用既有静态接口证据，不提升为真实版本 behavior-verified。针对队列、封面身份与失败恢复增加合成自动化；当前 NAS 的原生 App 实测继续记录为 PENDING_USER_VALIDATION，按用户授权不额外设禁用开关。


## 标签创建与相对日期调整

- `SYNO.Foto.Browse.GeneralTag` v1 `create`：POST JSON 业务参数 `name:String`，返回 `data.tag:{id:Int,name:String}`；这是此前官方静态脚本已记录的结构，本波次接入。按返回编号在已记录的 GeneralTag.list v1 中核对名称，不按同名猜测丢失的创建回执。
- `createTag(name,photos)` 可创建空标签，或创建后调用 Item.add_tag 应用到选中照片。新能力 tagCreation 只依赖实际 GeneralTag/Item/Folder 能力，不阻断只有既有标签编辑能力的 NAS。提交前先核对全部目标；创建/应用分阶段记录，应用明确被拒绝后返回已创建标签与部分结果，后续只应用同一标签编号。
- `shiftDates(photos,seconds)` 是客户端用户语义：对每张不可变原照片快照计算 `原始 Unix 秒 + 偏移秒`，逐项调用既有 Item.set v2(time)。所有目标写前验证，正负偏移及整数越界校验；一天按 24 小时。当前未采用静态候选 shift_time，不猜测其参数结构；没有新增平行 fallback。
- 相对日期保存已提交与明确拒绝的目标编号。回读匹配目标时间才计入完成；未知请求只回读，未提交项不伪报成功；部分完成返回已确认照片，原生端继续时仅使用原始快照中的剩余照片，避免再次累加偏移。
- 领域契约增量：新增 tagCreation 能力、createTag/shiftDates 命令、结果的可选 tag 字段（默认 nil）。不修改会话、持久化、系统权限或其他端 UI；回滚移除新增命令/入口及默认字段，既有标签加减和绝对日期流程独立保留。
- 当前 Mac 锁屏，无法继续官方页面比对；已请求解锁，不绕过访问边界。以上等级仍为 static + 合成测试，真实 NAS 正常/断网/权限失败路径为 PENDING_USER_VALIDATION。用户已明确要求开放，未增加人工禁用。


## 2026-09-29 后续静态发现

高级分享密码加密、成员增删改、条件相册、人物、照片请求和预览重建证据见 `photos-advanced-management.md`。Folder.create v1 已取得官方 `target_id/name -> folder` 参数；目录层级上传以此接入。现有分享弹窗在没有链接时可能写入关闭状态的链接，今后发现避免重复打开。以上不提升真实版本验证等级。


## 保留目录层级上传

- 新增 `folders` 能力和 `createFolder(parentID,name)` 命令，结果增量可选 `folder`（默认 nil）。`SYNO.Foto.Browse.Folder` v1 create 的 JSON 业务参数为 target_id/name，最小回执 data.folder.id；v2 get 以 id 和 additional=[access_permission] 回读。来源是官方脚本静态证据，见 photos-advanced-management.md；本轮没有进行 NAS 创建请求。
- 写前核对父目录管理权限，拒绝空名称、点目录、分隔符和 NUL。写后精确核对返回编号、父编号、名称及 view/manage 权限；回执丢失不按名称猜测，也不重复创建。同一 operationID 不重发。
- macOS 确认页默认保留所选根目录及子目录，可切换汇总上传。每批按父编号/名称复用已有目录或逐级创建，缓存仅在该批内有效；上传前继续核对实际文件目标权限。同名文件沿用另行保存语义，不覆盖已有文件。
- 目录创建结果未知则暂停队列，核对后从原目标继续；上传到相册仍先确认文件上传，再加入相册，加入失败不重传。未新增持久化、第三方依赖或权限。部分成功不自动删除已创建目录。
- 合成覆盖：逐级新建、同批复用、跨批目标隔离、已有目录、结果未知暂停/恢复、平铺选择，以及 Repository 身份/父目录/权限错误与丢失回执。真实 NAS 为 PENDING_USER_VALIDATION，按用户要求不设人工禁用或环境白名单。


## 2026-09-29 分享现状与访问方式

- 新增只读 albumSharing(id)，调用 Album.get v4 additional=[sharing_info]；须为当前用户所有相册。读取不会创建链接或调用 set_shared。shared=false 显示关闭并隐藏旧链接；shared=true 按 private/public-view/public-download 读取，不把未知值当关闭。保护状态缺失保留 unknown。
- macOS 分享表单读取现状后才允许保存更改；提供关闭、仅受邀者、公开查看、公开查看并下载。显示已有密码/有效期标记和可复制链接。未改变选择不提交，默认 disabled 不构成保存值。
- shareAlbum 增加可选原快照（默认 nil，既有调用兼容），摘要对 Album.get 的 shared、sharing_info 已知字段含原 permission JSON 生成 SHA-256，仅在内存做并发检测，不存凭据。写前再次读取；预读失败不创建已提交记录。原快照不匹配时明确提示重新打开。
- 仅受邀者使用 permission=[{action:delete,member:{type:public}}]；公开查看/下载使用对应 update/role。不发送密码、有效期或具名成员更改。最终核对共享模式、保护元数据和合法 http(s) 链接；未知结果只回读，不重放。既有临时关闭→更新→启用顺序不变。
- 重新核对官方 exB 表明公开权限转换只有 private/public-view/public-download；普通相册的 upload 是具名成员角色，不能误扩为 public-upload。开发中曾按常量误加公开上传，源码/界面/测试已纠正，未交付该错误选项。
- 回滚移除新状态方法、可选快照、invited 枚举及界面读取即可，无持久化或应用权限迁移。五端共享语义需同步；本轮只有 macOS UI。用户已授权取消人为验证白名单，真实能力/账号权限/确认和去重仍保留。
- 证据：static + 合成自动化；本轮没有真实 NAS 分享或权限写入。成员增删改、密码和有效期编辑仍未完成，不能把现状读取写成高级分享完整对齐。


## 2026-09-29 具名成员管理接入

- 读取候选：Sharing.Misc.list_user_group v1，team_space_sharable_list=false，list 中的 id/type/name。官方页面按用户/群组分组，以 type+id 区分，排除当前 UserInfo.uid，不能用 Photos UserInfo.id 替代系统 uid。客户端保留原编号的数字或字符串 JSON 类型，不把同编号用户与群组合并。
- 现状：Album.get additional.sharing_info.permission 直接供网页成员表格，单项包含 id/type/name/role；额外字段不参与差量，不重写。缺失、重复身份或无法完整解析的列表保持 unknown，不能当空列表删除其他成员；基础公开分享仍独立可用。
- 领域新增 SynologyPhotoShareRecipient、SynologyPhotoShareGrant，状态 members 可选默认 nil；sharingRecipients 默认不支持，shareAlbum.members 默认 nil 保持旧调用。macOS 同一表单搜索并选择用户/群组、添加/移除成员、选择角色；普通相册 view/download/upload，条件相册 view/download。现有未知角色保留，不强制降级。长权限文案与多成员滚动区域均独立于底部操作区。
- 写入仍使用原 Passphrase.update v1 permission 差量，成员目标是 {type,id}，不包含显示名称；只发送新增、删除、角色变化。原快照冲突则拒绝；新成员保存前再次读取可选列表，不向已消失目标扩大权限。重复身份、无原始名单及条件相册 upload 修改均拒绝。
- 关闭分享时可保存成员配置但不重新开启；公开设置和成员无变化时没有写入。最终以完整 type+id→role 字典比较，忽略名单顺序和显示名称变化，并保留密码/有效期核对。仅关闭分享且未更改成员时，以 shared=false 确认，不要求关闭后可能不再返回的成员字段。结果未知只核对，重复操作编号不重发。
- 字段证据来自已加载官方前端对 permission 的读取、exF 差量和候选的 id/type/name 使用，等级 static；未取得当前 NAS 非空成员响应或权限写入行为验证。合成 fixture 用虚构用户/群组、数字/字符串编号覆盖字段保留，不代表该 NAS 的成员目录已验收。
- 五端影响：macOS 接入；iOS/iPadOS 共享领域/服务默认方法有增量但无 UI，未运行移动构建；Android/Windows 仅同步计划。无持久化、系统权限或第三方依赖变化。回滚移除 members 可选参数、新成员类型/读取和界面部分即可，保留前轮基本分享。
