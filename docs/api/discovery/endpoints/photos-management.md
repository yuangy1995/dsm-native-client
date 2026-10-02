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


## 2026-09-29 分享有效期管理

- Album.get sharing_info.expiration解析非负整数秒（含数值等价整数的JSON小数），0表示不限期；缺失/负数/非整数/未知类型保留为未知，不猜测取消。领域expiration可选字段默认nil，兼容原调用。
- Passphrase.update v1仅在用户明确修改时添加expiration，0清除、正数为所选本地日末Unix秒；未变化省略，不修改password和permission。调用仍以原快照、当前所有者与个人空间为前提，已有确认/重复提交保护保留。
- 分享关闭时修改日期可保存配置但不会启用；只关闭且无配置修改仍允许shared=false作为结果。主动修改有效期必须回读匹配，且密码/成员不变；未知结果不重放。回读数值类型等价可确认，保护变化不能声称成功。
- 自动化覆盖设置/取消、关闭状态修改、无变化无请求、未知值、无原快照/负数拒绝、回读不符及重复操作只查不写；界面日期覆盖本地夏令时日末和未修改旧日期。真实写入仍未验证，用户验收步骤见照片对齐账本。无存储、签名、权限或依赖变化；共享契约扩展已获授权，五端影响同步。


## 2026-09-29 共享空间上传与目录作用域

证据来源：当前已登录官方页面的 react_bundle.js，只读静态核对，环境见 `../environments/2026-09-28-photos-parity-observation.md`。未执行共享空间上传或创建目录，证据等级为 static，不能登记 behavior-verified。

- 官方 AddUploadToFolderTask / AddUploadToTimelineTask 的 TEAM_SPACE 分支明确使用 `SYNO.FotoTeam.Upload.Item`；PERSONAL_SPACE 使用 `SYNO.Foto.Upload.Item`。两者复用同一构造函数和版本表。
- POST 到能力发现返回的 entry.cgi 路径，multipart：`upload_to_folder` v1 包含 file、duplicate、name、mtime（秒）、target_folder_id；`upload` v1 包含 file、uploadDestination="timeline"、duplicate、name、mtime、folder=["PhotoLibrary"]。可选缩略图字段不属于当前客户端必须生成的内容。认证沿用现有请求头，不放入URL。
- 上传回执取得 item.id，按同一空间 Item.get 回读大小与指定目录；没有明确编号不能按名称猜测成功。共享目录创建使用已记录 FotoTeam.Browse.Folder.create v1(target_id,name)，回读 Folder.get v2 验证 id、parent、name 和可用权限。
- 共享空间必须实际启用且角色为 entry/management；entry 上传目标要求 view 且 upload 或 manage，management 只在共享目录范围内生效。个人权限检查保持原行为。缺少实际 API 能力不借个人接口处理共享编号。
- 领域命令 upload/createFolder 增加默认 personal 的 space 参数；Serving 增加 managementFeatures(in:)，默认个人桥接旧方法，共享未实现的适配器返回空集合。现有命令构造源兼容，枚举匹配需要增加关联值，Apple现有实现已同步。无持久化迁移；回滚时撤销本轮选择器、作用域关联值与共享上传路由即可，个人功能独立保留。
- macOS 上传表单和队列显示固定目标空间；切换照片库不改变排队文件、子目录创建和结果复查的空间。不同批次目录缓存隔离，异空间返回值不插入当前画廊。共享元数据/移动复制/人物与共享相册来源仍需后续契约切片。
- 自动化覆盖共享专用命名空间、个人服务关闭、目录上传权限不足不发送、回读目录不匹配、重复操作不重传、操作编号不可换空间、共享子目录导入以及上传中切换空间。真实NAS验收见开发账本，未新增测试白名单或人为关闭开关。


## 2026-09-29 共享照片编辑与后台管理静态补证

继续只读同一官方react_bundle.js：FotoTeam.Browse复用Item方法表（set v2、get v5、add_tag/remove_tag v1）和GeneralTag（create/get/list v1）；共享批量评级、日期、描述及标签action传入FotoTeam.Browse.Item，参数与既有个人编辑相同。标签请求id:[Int]、tag:[Int]，创建name，最终以同空间目录和照片回读核对。

共享移动/复制action传入FotoTeam.BackgroundTask.File v1，参数target_folder_id、item_id、folder_id、action；返回task_info.id。官方状态监控明确仍传入Foto.BackgroundTask.Info.get_status v1，响应list内status/completion/error/skip/overwrite，**没有FotoTeam.BackgroundTask.Info证据**。当前实现只做同空间目标，不推测跨空间extra_info转换。

共享删除action传入FotoTeam.BackgroundTask.File.delete v1，item_id和folder_id数组；照片身份回读使用FotoTeam.Browse.Item.get v5。目录manage权限和共享management角色适用于这些修改/删除操作，upload权限不能代替管理权限。没有真实NAS写入，不升级行为证据；沿用当前环境快照的版本未知限制。


## 2026-09-29 分享密码设置、替换与清除

- `shareAlbum` 增加默认nil的password：nil保留原设置、空字符串清除、非空原样设置（不修剪空格/Unicode）。修改密码必须携带原分享快照，既有所有者、版本快照、重复提交与关闭→更新→按需启用流程继续生效。
- DsmEndpoint和DsmRequestBuilder均只接受HTTPS，故使用官方HTTPS分支的普通password字段；不新增HTTP降级或不可能触发的额外加密实现。官方非HTTPS加密细节仅记录在advanced-management，证据为static。
- 设置或替换必须有update成功回执，且enable_password=true、目标访问方式、成员与期限回读一致；丢失回执后原有true不能证明新密码生效。清除可由明确false回读确认。未知结果只核对，不自动重发。
- macOS默认保留设置，选新密码后出现SecureField，空输入不能保存；移除选项明确清除。关闭表单清空输入，密码不进URL/日志/磁盘；原命令仅随当前Repository操作记录驻留内存，以维持重复提交保护。
- 共享契约为构造兼容的默认参数增量；Apple枚举匹配已同步，其他端UI未改变。未使用真实密码、未执行NAS分享写入，不提升行为验证等级。

### 2026-09-29 普通相册的共享照片来源

官方静态NormalAlbum.create(name,item)、add_item/delete_item(id,item)仍使用统一Foto；Album.set_cover(id,id_item)同样统一。新增普通相册共享成员支持，预检逐项按照片空间读取Item.get和目录权限，再向统一相册提交编号；混合来源同一编号拒绝以避免含混目标。写后按统一相册读取结果及每项owner_user_id核对完整身份集合，未知结果不重放。空相册创建/改名/删除只依赖已授权照片会话和实际相册能力，仍保留所有者限制；共享相册封面带album_id回读。没有新增真实NAS写验证。已有“只准个人来源”限制已由本轮取代；协作相册的非所有者上传/添加权限与无原空间授权的分享读取仍待后续对齐，不因放开来源而绕过所有权检查。

### 相册协作权限与上传补充（2026-09-29）

前述非所有者协作待办已增量接入：get_permission读取实际download/upload，NormalAlbum.list category=addable列出可添加目标；非所有者成员添加/移除使用passphrase，移除前回读provider_user_id。相册直接上传使用album_id或passphrase与folder=PhotoLibrary，回读编号/大小/提供者，不重复add_item；没有原空间权限的贡献者仍可直接上传。源项目跨相册转加尚未接入。准确参数、静态来源、部分失败与安全边界见[相册协作角色、成员与直接上传](photos-advanced-management.md#相册协作角色成员与直接上传2026-09-29)。真实NAS仍为PENDING_USER_VALIDATION，无新增验证白名单。


### 相册间添加来源规则更正（2026-09-29）

原空间关闭时网页不提供跨相册添加，故前述该待办撤销为“与网页一致的限制”。现已接入原空间启用时本人provider的相册项目转加或新建相册，详情通过源album_id重新核对，目标写入仍用既有item及id/passphrase；原件owner不再误作提供者。详情拒绝不回退，目标结果回读且原相册保留。依据与参数见[相册间添加的来源语义更正](photos-advanced-management.md#相册间添加的来源语义更正2026-09-29)，等级static，真实NAS待用户验证。

## 2026-09-30 跨空间文件移动与复制增量（static）

延续当前观察会话中官方react_bundle.js静态证据，不含NAS写入：

- `PERSONAL=personal_space`、`TEAM=shared_space`。复制的目标空间切换以个人空间启用和共享entry/management为条件；移动仅源为个人空间时允许跨空间目标，共享到个人不属于当前网页提供的移动方向。
- 源空间选择Foto或FotoTeam.BackgroundTask.File v1 move/copy，目标仅由target_folder_id决定，不发送猜测的target_library/target_user_id字段。item_id为照片数组，folder_id为空数组，action为skip。
- move添加extra_info，类型为JSON字符串，内容version:2和source_library（personal_space或shared_space）；官方可选source_folder_ids在本照片流程未使用。copy无源目录上下文时不传extra_info。
- 回执task_info读取id、create_time、total、target_folder；target_folder包含id/owner_user_id，owner_user_id=0表示共享，否则为个人所有者。跨空间必须核对任务目标目录、目标所有者和total，再结合get_status中done与完成数确认；不假定迁移后的照片仍能从原空间按旧编号读取。
- 缺少目标回执时使用统一Foto.BackgroundTask.Info v1 list_user_task，只匹配本次已知taskID，返回列表含id/operation/total/target_folder/extra_info及状态计数。没有任务编号不得用名称猜测或重放。get_status仅依赖已记录状态计数字段，不臆测返回目标字段。
- 目标目录以upload/manage权限核对；源移动需要manage，源共享复制需要view/download。最终跨空间完成回读仍检查目标权限与当前授权代次。部分完成仅报告计数，不把全部源照片从列表移除。

领域move/copy新增可选destinationSpace，默认保持同空间调用兼容；macOS表单提供目标空间与目录选择，确认快照固定目标，完整完成才移除旧来源身份，时间线不全量刷新。混合个人/共享来源批量命令仍是后续切片。五端影响同步到平台计划；没有更改其他端UI、持久化或版本兼容验证记录。

### 2026-09-30 混合来源增量

评级、绝对/相对日期及预览重建允许按原件权限混合处理个人与共享来源，先核对两空间能力和共享管理权，再按来源 API 分发并逐项回读；已完成项目不重复提交。标签和混合相册移动不是官方菜单提供能力，撤销先前相关待办。详情见 [混合来源记录](photos-advanced-management.md#混合来源评级日期与预览重建2026-09-30)，等级 static，真实 NAS 待用户测试。

### 2026-09-30 未完成预览恢复

新增按空间读取未完成队列、选择确认继续及通知丢失后的自动结果核对；恢复沿原照片身份并在提交前再次检查队列，初次恢复不重复设置标记。完成判断同时要求提交前新鲜版本基准、照片身份一致、新版本出现和两次队列无目标；未知保持只读核对，不按队列消失猜测成功。详见 [未完成预览读取与继续处理](photos-advanced-management.md#未完成预览读取与继续处理2026-09-30)，沿既有static证据；组合完成判断为原生端策略，真实NAS行为待用户验证。


### 2026-09-30 文件夹封面

内部端点组沿用photos-file-management；证据static，来自已登录官方页面加载的react_bundle.js，未执行真实写请求，环境版本见2026-09-28-photos-parity-observation.md。

- 个人SYNO.Foto.Browse.Folder、共享SYNO.FotoTeam.Browse.Folder；POST /webapi/entry.cgi，version=2，method=set_cover，id为固定目标目录，id_item为单元素照片编号数组。官方选择器强制单选，允许在目标目录及子目录选图；根目录不提供设置入口，没有确认到清除封面的动作。
- 提交前读取目标Folder.get v2，核对id/已知路径和manage权限（共享管理者可管理）；Item.get v5重新核对照片身份，再读取照片所属目录view权限，并按路径分段确认它是目标或后代。可查看且不可下载的来源仍可设置封面，不能偷换成下载权限；不接受其他空间、相册上下文、兄弟目录或待删除原件。
- 沿现有operationID去重及权限代次保护；确认窗口固定目标，浏览子目录不会把设置目标改成子目录。成功回执后只读重查Folder.get additional.thumbnail及自定义封面序号0的可解码图片，再更新封面修订，不刷新图库月份/照片选择。短暂读失败沿既有自动复查；写回执丢失不重放、不凭图片变化猜测成功。
- 官方成功后使用folder_cover_seq=0和随机cache_key刷新，而没有读取本次照片编号。原生端的“成功回执＋自定义封面可读”是组合确认策略，不能宣称回读了所选item_id；另一客户端并发修改、回执丢失后的最终归属仍需用户核对，不能把未知当失败后重复提交。
- 实际权限、去重和确认保持；不额外添加“未实测”禁用。真实NAS写入与并发行为PENDING_USER_VALIDATION；共享公开模型增加folderCover特性、setFolderCover命令及默认unsupported的folderCoverImages读取，五端影响见各平台计划，无持久化迁移。


### 文件夹排序保存与读取（2026-09-30）

内部Foto/FotoTeam.Browse.Folder.set_order v1，POST /webapi/entry.cgi，参数id、sort_by、sort_direction；不是只读本地排序。官方封面选择器先保存再重读目录照片，打开目录读取Folder.get v2的sort_by/sort_direction。名称filename、大小filesize、类型item_type、拍摄时间takentime，方向asc/desc；每个缺失或未知字段独立回退Setting.User.get v1的item_sort_by/sort_direction，官方缺省takentime/asc。子目录Folder.list v2始终filename并沿同一方向；照片Item.list v4使用所选字段/方向和原目录/空间/offset/limit，每页100。

排序是浏览偏好，官方入口基于可查看目录；原生先重新核对固定目录id/已知路径和view，不能因没有原件管理或下载权而阻止排序。保存采用既有操作编号去重、权限代次保护及自动结果核对，回执丢失只读重查；必须回读两个明确字段均匹配，不能用默认值拼成成功，也不重放。已选照片时排序菜单禁用，取消选择后可继续；设置封面仍独立要求管理权。

新增SynologyPhotoSort及folder查询的可选默认排序参数、集合可选sort、folderSort读取、folders方向重载和setFolderSort命令。旧调用仍为takentime/asc，旧目录读取重载仅兼容升序；无实现的新能力显式unsupported，不伪造降序。macOS封面选择器每次进目录沿已保存顺序，保存后重置其分页；同一主图库目录同步重排，留在原目录并保持照片选择ID；修改子目录不重排父目录。排序加载/保存时避免重复动作，旧请求以加载编号/代次隔离，失败可重试。所有枚举为稳定协议值，翻译不参与请求。

证据static：只读官方react_bundle.js的封面选择器、ChangeEmbededSorting worker、Folder方法版本表、默认设置及照片/子目录读取；没有真实NAS保存排序、读取用户排序值或导出会话。当前环境版本沿既有未验证记录，verifications不新增。兼容与用户验收PENDING_USER_VALIDATION；用户已授权契约扩展，不新增本地存储、依赖、标识或其他端UI。


### 完整范围复核纠正（2026-09-30）

本轮打包期间重新比对官方动作绑定与当前源码，确认先前“只剩上传重启恢复”的清单不完整，不能据此结束完整网页对齐目标。官方handleRenameFolder个人/共享分别绑定Folder.rename动作；worker单选目录、打开名称输入框、rename v1(id,name)，响应folder.id/name更新目录树。删除worker用Folder.delete v1(id数组)；移动/复制官方动作保留selectedFolderId/folderArray和BackgroundTask.File。当前SynologyPhotosMutation只有createFolder/setFolderCover/setFolderSort，move/copy目标为照片数组，macOS目录卡片没有这些目录管理入口。以上是static与当前源码差异，尚未核全删除/搬移确认、目录树和最终结果校验，不可直接复制接口片段执行。还发现共享handleEditPermission绑定与主文件夹页排序入口，应列入后续菜单审计，不能把封面选择器排序当成所有文件夹页面控件齐全。

下一切片优先目录重命名，随后目录删除及移动/复制；相关共享目录权限/分享和主页面排序继续核对。上传重启恢复仍等待既有存储授权。未触发任何真实目录重命名、删除、搬移或权限修改；没有给候选写接口注册已验证兼容记录。构建期间未再修改产品源码。


### 文件夹重命名与主页面排序（2026-09-30）

内部端点沿photos-file-management：个人SYNO.Foto.Browse.Folder、共享SYNO.FotoTeam.Browse.Folder，POST /webapi/entry.cgi，rename v1，参数id整数、name字符串，成功响应含folder.id/name。官方单目录表单校验非空、UTF-16长度≤255，禁止纯空白、开头/结尾点、@database/@eaDir/@tmp/@sharebin、#recycle/#snapshot、斜杠/反斜杠/冒号。静态来源为已登录官方react_bundle.js的重命名worker与表单校验器；没有实际写请求，版本未知沿当前观察记录，不注册已验证兼容。

原生固定目录空间/id/原路径；根目录不提供重命名；执行前Folder.get v2重新核对身份、可查看与manage（或共享管理者）、已知parent。输入沿网页规则并拒绝NUL。沿现有operationID去重、权限代次保护；提交rename后必须重新读取同一id、同一父路径下完整新路径及已知parent和管理权限，回执本身不代表成功。丢失回执只重读、不重发；自动核对未知/读失败沿现有恢复流程。正常确认仅更新卡片/面包屑和已加载后代路径，不全局刷新、不改变所选照片或跳到最新日期；迟到确认隔离同编号相册与其他空间。

共享Apple命令增量renameFolder，继续使用folders能力；UI在目录卡片右键提供固定目标表单。main文件夹页复用封面选择器四字段双方向菜单，含根目录，沿set_order保存/精确回读及已实现分页排序。不新增持久化、依赖、标识或权限。按用户授权和真实API能力开放，没有人工未实测开关。回滚移除本轮命令和菜单，不影响照片原件或既有排序；重命名是NAS上的实际文件夹名称变更，用户可在具备权限时再次重命名恢复。

PENDING_USER_VALIDATION：专用个人/共享目录重命名，核对网页同步、子目录路径和照片不变；无管理权、同名冲突、加锁目录、断网及另一客户端并发更名；主页面保存排序后跨页/返回/重进核对顺序。按实际NAS错误说明恢复，不猜测未知错误码；当前未捕获真实错误码与套件版本。只需回传版本、空间、操作步骤、脱敏错误。


### 文件夹删除主流程纠正（2026-09-30）

进一步只读官方HandleDelete/选中栏绑定确认，文件夹与照片混选走Foto/FotoTeam.BackgroundTask.File.delete v1(item_id,folder_id)，返回task_info.id并等待后台完成；之前Browse.Folder.delete helper仅为候选线索，不能当成主流程。新实现、安全与回读边界见[文件夹与照片混合删除](photos-item-deletion.md#2026-09-30-文件夹与照片混合删除)，证据static，真实目录删除未代测。


## 2026-09-30 文件夹及照片混合移动复制（static）

沿当前官方react_bundle.js只读观察：CopyToFolder/MoveToFolder把选择中的folder_id和item_id一并提交Foto/FotoTeam.BackgroundTask.File v1 copy/move，源命名空间不跟随目标切换；统一Foto.BackgroundTask.Info get_status监控。目录移动的extra_info为JSON字符串，包含version:2、source_library（personal_space/shared_space）和source_folder_ids（原父目录数组）；复制无此额外信息。网页同一选择器禁止原父目录、所选目录自身及后代，目标需UPLOAD；个人→共享移动和双向复制规则与照片相同。

共享命令move/copy末尾新增默认空folders，原构造调用兼容；photos与folders须同空间同父目录，目录固定id/name/path/parent，根目录、重复、跨父目录选择拒绝。写前依次回读照片身份、原父目录、目录身份与manage（共享复制可用view/download）、目标view/upload；权限代次变化不写入。相同空间用实际目标完整路径排除自身及后代，跨空间不能因相同路径或编号误判冲突。

folder_id非空时task_info.total涉及目录内容，不与顶层选择数比较；仍核对非负total、目标id/owner，回执缺字段按唯一已知任务号list_user_task补查。get_status必须匹配同一任务并done，计数在任务total范围内、overwrite=0；error/skip存在返回部分完成，不猜逐目录成功。无错误时重新核对目标上传权，同空间移动另按原目录id回读新parent/名称，照片按既有流程核对。未知任务/丢失回执不按名称追认、不重放，不回退File Station。沿已交付action=skip，不覆盖已有资料；网页copy_move_default_action配置的完整选项仍有差距，另列后续，不宣称完全复刻。

macOS主选择菜单/目录右键均使用同一弹窗，显示照片+目录总数并冻结快照；确认才调用，无效目标、加载或读取失败不能提交。完成后原父目录局部移除，复制保留来源；待核对时进入被移动目录则返回原父目录并内部刷新，修正之前内部刷新被忙碌门禁拦住的相关问题（删除亦复用该路径）。其他空间及同编号相册不移除；部分结果不自动重复批次。

PENDING_USER_VALIDATION：使用可丢弃目录测试单/多目录及照片混合、空目录、含大量后代、个人/共享来源和允许的跨空间方向；同名冲突应跳过并提示部分完成；核对期间导航、断网、任务历史消失、源/目标权限变化、新旧目录身份由用户实测。未执行真实NAS移动复制或提升版本验证等级。公开增量已授权，无存储/权限/依赖变化；回滚移除folders参数及入口，已经发生的NAS移动需用户按真实位置恢复。


## 2026-09-30 共享目录权限现状与候选保存契约（static）

当前官方react_bundle.js只读发现，未触发真实权限或分享写入。稳定分组沿photos-sharing-management，新增SYNO.FotoTeam.Sharing.FolderPermission（内部，v1，路径由能力发现，POST JSON业务参数）。原相册的Passphrase.update参数不能用于目录。

| 方法 | 参数 | 最小响应/用途 |
| --- | --- | --- |
| FotoTeam.Browse.Folder.get v2 | id，additional=[sharing_info,access_permission] | folder.id/name/parent/shared及additional.sharing_info.privacy_type/sharing_link/enable_password/permission |
| FolderPermission.get_folder_link v1 | folder_id | folder_link；仅未共享且无现成链接时读取，不调用set_shared |
| FolderPermission.get_config v1 | 无业务参数 | set_to_subfolder:Bool，为用户应用到子目录的默认选择 |
| FolderPermission.update v1（候选，尚未实现） | folder_id/privacy_type/set_to_subfolder，可选password与permission数组 | 官方成功后回读Folder.get；成员为扁平{id,type,role,action}，不同于相册member嵌套 |
| FolderPermission.set_config v1（候选，尚未实现） | set_to_subfolder | 仅应用子目录默认选择变化时保存；与update分开 |
| Foto.Sharing.Misc.list_user_group v1 | team_space_sharable_list=true | list成员id/type/name；共享候选，排除当前系统uid，不使用个人列表 |

hK/hY静态定义明确将参数名驼峰转snake_case，不递归改数组成员。目录公开模式仅management/private/public-view/public-download；management表示仅完整访问用户，shared=false映射此态，不能把未知已共享模式当关闭。成员角色view/download/upload/manage；未知角色原样保留。普通与共享相册逻辑保持原样。

官方前两层目录有权限入口，根目录和更深层没有；第二层父目录shared=false时禁止独立编辑，第一层显示应用到全部子目录。网页su还受管理员启用用户分享设置影响，当前客户端按已知Photos共享management与实际NAS响应读取，不假定DSM管理员替代Photos授权。未来保存需补齐设置约束、权限降低确认、password变更回执/状态核对及apply到子目录的结果语义；不得根据顶层Folder.get匹配就宣称所有后代已验收。

本轮已接入只读SynologyPhotoFolderSharingState、folderSharing/folderSharingRecipients默认服务方法及macOS查看面板。读取固定共享空间、目录id/完整路径/父id、Photos完整访问权；父目录路径/编号/shared严格核对，权限代次变化则撤销。成员缺失或无法解析为unknown，不当空名单；链接仅接受无内嵌凭据http(s)。快照摘要包含profile、目录身份、完整sharing_info、父共享状态和默认配置，未来用于并发检测，只有摘要进入领域层，密码与分享口令不输出。链接/成员仅本次窗口内存，不写日志或持久化。

macOS卡片右键和当前文件夹页提供查看，打开/刷新只读，显示成员、保护状态、链接与父目录限制，失败可重试；未接入保存按钮，原因是保存流程仍在开发，**不是未实测禁用开关**，不能把本轮读取交付算成完整权限管理。PENDING_USER_VALIDATION：在共享前两层目录打开并与网页核对模式、成员/角色、密码标志、父级限制、断网和权限改变；回传版本/层级/脱敏失败，不传链接、成员实际资料或凭据。

五端：Apple公共方法默认不支持以保持现有适配器构造兼容；macOS先接读取，iPhone/iPad目录管理仍后续，Android/Windows仅记录影响。无存储/工具链迁移；回滚移除只读方法、类型和面板，不改变NAS状态。发现环境仍版本未知，不增加verifications。

补充静态证据：eP3明确以encryption:[password]标记密码字段，后续接入需沿现有传输保护核对；eP6先update，只有默认子目录选项变化时再set_config，最后Folder.get含thumbnail/sharing_info/access_permission/password_verified。exj调用exU，当成员集合变化时对保留成员也发update，移除项携带原role，新增项携带新role；eP3最终丢弃auto_backup，仅发送id/type/role/action。权限降低确认exV检查原公开下载降至仅查看/私有，或原可下载成员被移除/降至仅查看。以上仅候选保存依据，不代表写入已实现或已验证。


## 2026-09-30 共享目录权限保存实现（static，待用户验证）

沿上一节静态字段实现FolderPermission.update v1与set_config v1。管理能力只在共享管理账号及Folder.get v2/FolderPermission v1实际可用时提供；本轮再次只读官方菜单确认，前两层EDIT_PERMISSION分支位于Ei()管理分支，普通目录manage/download分支不含权限编辑。官方还以DSM is_admin或Admin.enable_user_sharing控制分享菜单；当前客户端不臆造DSM管理员字段，最终保存继续服从NAS实际授权错误，此类账号差异需用户验收。

命令带原始完整领域快照和revision，prepare及perform写前重新读取并比较；目录id/path/parent、密码标志、成员、父共享状态、配置变化均不能被旧表单覆盖。第二层父目录未共享不能独立修改，第二层不能改隐藏的默认应用选项。新增成员重新核对Foto.Sharing.Misc共享候选；角色允许view/download/upload/manage，原未知角色未改时保留，重复身份和非法新角色拒绝。成员参数完全扁平，变更名单时保留成员也update、删除项带原role；未改变名单不发permission。密码nil保持、空字符串移除、非空替换，沿DsmRequestBuilder强制HTTPS传输；不输出或持久化，不新增明文降级。

update成功后才保存变化的set_to_subfolder默认值；两次操作沿同一operationID且单次写入。最终Folder.get/get_config/父状态回读核对访问范围、成员角色和密码标志，update回执为应用子目录及新密码必要证据；有成功回执加顶层匹配说明NAS接受此操作，**不是每个后代独立行为验证**。默认选项不匹配而权限匹配返回partial，界面说明权限已保存而选项未保存。初次回执丢失、读取失败、状态不匹配或新密码无法证明时保持pendingReview，只自动只读核对、不重放update/set_config。明确权限拒绝且未有成功回执为rejected。保存不刷新图库、不改变月份或当前空间。

macOS完整编辑窗口：保留现状查看和复制链接，访问范围Picker、成员角色/删除/搜索添加、密码选择及安全输入、仅第一层显示应用子目录；保存前冻结命令并确认可能扩大/缩小访问范围，应用子目录时明确覆盖现有子目录权限。确认/取消原生界面经过合成测试，窗口打开或编辑字段不写。未实测不是禁用条件，未知必要身份或NAS权限不足仍拒绝。

PENDING_USER_VALIDATION：在可丢弃的共享目录分别测试四种范围、数字/字符串账号和群组、添加删除与四种角色、保留/替换/移除密码、第二层父限制、应用所有子目录和默认值记忆；用网页及专用不同权限账号核对实际访问与后代结果。另测另一客户端并发编辑、断网丢回执、NAS明确拒绝以及Admin.enable_user_sharing关闭的非管理员差异。仅回传版本、层级、脱敏错误和期望/实际，不回传密码、链接或真实成员资料。没有执行真实NAS权限写入；没有增加版本verifications。五端影响、回滚与结果见各平台计划及对齐账本。


### 2026-09-30 原生文件夹拖放移动与重复项静态线索

只读官方react_bundle.js：拖单目录与当前选择的移动worker均调用既有createMoveToFolderTask，传selectedFolderId或itemIds/folderIds、targetFolderId及源目录信息；使用getCopyMoveDefaultDuplicateHandling。当前macOS文件夹页拖动照片/目录，已选项固定完整混选集合，目标支持可见文件夹、返回上级按钮及已访问路径导航。落下后预选目标并显示既有移动表单，确认才提交；复用已有BackgroundTask流程及最终状态核对。拖动数据仅为NSItemProvider ownProcess的一次性UUID，身份、路径和照片在当前Model，不接受跨Model/刷新后的旧标识或外来文件。自移动、原父目录、后代目录和无权限/忙碌状态拒绝。

新增路径导航只改变本地浏览状态，无新NAS接口/存储/权限。文件夹视图之外沿既有移动表单，不将本轮称为新增目录树或Finder拖入上传。真实物理拖动命中、目标高亮/光标、NAS移动和权限变化为PENDING_USER_VALIDATION；现有确认/跳过同名语义不变。

后续重复项设置证据static：设置组件uploadDefaultAction提供ignore/rename，copyMoveDefaultAction提供skip/overwrite；选取器分别读取Setting.User中的upload_default_action、copy_move_default_action。官方保存worker调用Foto.Setting.User.set，传差异字段对象；移动/复制任务action为skip/overwrite，上传duplicate为ignore/rename。静态默认表为上传ignore、移动复制skip。当前尚未接入设置保存与策略执行，Set方法版本仍需核对；不得把候选线索记为已实现或NAS验证。现有客户端上传rename、移动复制skip保持原行为，后续必须连同ignore/overwrite结果计数、原件身份和部分结果一起完成。


### 2026-09-30 重复项默认设置与实际策略（取代上节候选状态）

稳定标识 `photos-duplicate-settings`，内部mixed接口 `SYNO.Foto.Setting.User`，POST到能力发现路径（当前候选entry.cgi），版本get:1/set:1。官方同一脚本的版本映射、get调用、set差异对象和保存后reload/get流程已静态核对；证据static，DSM/build/Update/Photos完整版本及匿名设备关联仍未知，未发起NAS业务读写，不新增兼容verifications。

get响应data含`upload_default_action:ignore|rename`、`copy_move_default_action:skip|overwrite`。set只传更改的字段，沿既有JSON业务参数POST编码；不发送其他用户设置。读取须Photos用户有效，与个人空间是否开启无关，用户只能改当前会话自身设置。缺字段/未知枚举明确失败，不猜测覆盖规则；能力缺失不阻断无关图库浏览。

共享契约新增SynologyPhotoDuplicateSettings、duplicateSettings()、duplicateSettings能力与setDuplicateSettings(original:updated:)；协议默认不支持用于旧适配器。prepare严格比较完整原快照、拒绝无变化或并发修改；保存按操作编号绑定、互斥去重，写后get完全匹配才确认。回执丢失保持待核对，只读回查；明确权限拒绝结束且不重发。没有本地存储格式变化。macOS工具栏设置页读取当前默认值，两个Picker编辑；将默认改为覆盖需要明确确认。保存不刷新图库。

move/copy末尾新增duplicate默认skip，upload/uploadToAlbum末尾新增duplicate默认rename，保持旧构造调用行为；穷尽模式匹配需要增加关联值。macOS打开上传/移动/复制时读取实际用户默认并允许单次更改，确认命令和队列固定该规则，之后更改设置不改变既有队列。选择overwrite的移动复制另有明确覆盖确认，目标/身份/权限与任务自动回读均保留。overwrite计数不得负数/超出任务总数，skip策略不得报告覆盖；错误或跳过仍部分完成，不猜测逐目录成功状态。

上传multipart duplicate使用所选ignore/rename；返回action=ignore须原请求ignore且id有效。已有项目可与待上传大小不同，按返回id/原文件名/目标目录回读；相册回读携带album_id并保留真实provider，不伪装成当前用户新上传。结果新增默认0的skippedCount，忽略时completedCount=0；队列标记“已忽略重复照片”，仍按目标完成后续加入相册，加入失败只重试成员操作。新上传继续原有大小/目录/相册provider校验。丢回执不凭名称猜编号，不重传。

PENDING_USER_VALIDATION：专用同名合成照片分别验证ignore/rename、目录和相册目标、已有照片不同大小/提供者；验证个人/共享move/copy的skip/overwrite、目录合并与覆盖计数，特别是NAS覆盖后编号是否保持。保存两个默认值后网页刷新核对，另一客户端同时修改时应拒绝过期保存；断网后仅回读、无重复上传/写入，月份/目录不变化。覆盖会替换目标原件，使用可丢弃资料；不承诺NAS可恢复。回传脱敏版本、操作步骤和结果类别，不提供凭据/真实文件/地址。


## 2026-09-30 相册内照片排序（static）

当前官方静态版本表：`SYNO.Foto.Browse.Album.get v4`、`set_order v1`。相册工具栏读取当前相册 `sortBy`/`sortDirection`，缺省拍摄时间升序；四字段为 `filename`、`filesize`、`takentime`、`item_type`，方向 `asc`/`desc`。普通登录相册保存 `{id,sort_by,sort_direction}` 后重新分页；外部口令浏览仅更新该页面状态，此轮不引入公开分享页面。Album.get返回字段经既有snake/camel映射进入状态，本轮证据仅静态，不冒充真实NAS返回验证。

内部接口路径由能力发现，POST JSON。读取固定id数组并核对返回唯一相册，所有者或相册当前查看权限；不要求上传权，不因个人空间关闭隐藏能力，也不推断原件管理权。服务新增albumSort，旧适配器默认明确不支持；相册query新增带默认值的sort，旧调用保留拍摄时间降序，macOS读取实际顺序后覆盖。照片Item.list仍统一Foto、album_id及固定sort跨页，不切回原件空间。

保存命令固定相册id、原始与目标排序，写前重读原始设置与查看权；原始变化拒绝覆盖。只要求Album v1/v4真实可用，不添加未验证禁用开关。操作编号重复保护；成功和未知回执均按同相册明确字段核对，缺失字段只能用于首次默认展示，不能证明已保存；未知仅重读不重发。保存改变用户在NAS上的相册排序，不修改照片文件内容。

macOS使用既有本地化原生排序菜单。成功重新分页当前相册，旧分页代次作废，保留相册及选择；上传和跨空间移动后沿当前相册query回读已加载范围，避免默认query等值判断误跳过刷新或本地日期排序覆盖用户设置。排序读取失败可继续浏览并提示，其他照片能力不受影响。

五端影响：macOS接入；Windows后续以原生排序菜单保留同语义；iPhone/iPad新增等价相册排序仅作待计划能力，不扩张当前专项范围；Android记录参数与能力变化，不修改界面。无依赖、权限、持久化或系统版本变更。回滚移除排序入口/查询参数扩展与新方法，NAS现有偏好保留，用户可在网页重新选择。

PENDING_USER_VALIDATION：登录有权限的普通/条件/别人分享相册，切换四字段与升降序、翻页、重新打开、上传后核对顺序；个人空间关闭但相册可查看时仍可排序；断网恢复应自动核对同次保存，权限撤回不继续写入。预期不跳时间线、不反复保存、不改变原件。回传脱敏版本、步骤和失败文案，不提供相册名/照片/凭据。实际NAS尚未执行，verifications保持空。


## 2026-09-30 相册列表与分享列表偏好（static）

内部端点组沿photos-album-management；路径由能力发现，POST JSON。当前官方静态代码验证以下绑定，未实际写NAS。

| 方法 | 版本与参数 | 响应/行为 |
| --- | --- | --- |
| Album.get_album_list_order | v2，无业务参数 | album_list_sort_by/direction、shared_with_me_sort_by/direction、shared_with_others_sort_by/direction |
| Album.set_album_list_order | v2，只提交所选范围的两个字段 | 成功后原范围回读，其他范围不写 |
| Album.get_album_list_display | v3，无业务参数 | album_display_type=all_album或my_album |
| Album.set_album_list_display | v3，album_display_type | 全部相册/我的相册；不改变排序或共享权限 |
| Album.list | v4，offset/limit/category/sort_by/sort_direction/additional | 显示全部category=normal_share_with_me，仅本人category=normal；两个条件固定于每页 |
| Sharing.Misc.list_shared_with_me_album | v2，offset/limit/sort_by/sort_direction/additional | 与我共享；沿原权限路由 |
| Album.list | v4，category=shared及上述分页/排序参数 | 与他人共享，默认调用仍保留原share_modify_time/desc |

首页菜单允许album_name/album_type/start_time/create_time/share_status；两类分享允许album_name/album_type/start_time/share_modify_time，均asc/desc。照片收集列表不属于该偏好，不传排序或显示范围。sort/display读取缺失、未知或与范围不符时明确失败，不猜默认值覆盖NAS；图库仍可按既有列表读取，并显示可刷新提示。

共享新增SynologyPhotoAlbumListScope/Sort/Display及默认明确不支持的服务方法，列表重载以可空参数保持旧调用兼容；新调用值不被默认适配器静默忽略。保存命令冻结范围、原始与目标值，prepare和提交前核对原偏好，变化拒绝覆盖；能力按Album v2/v3分开判断，个人空间关闭时仍可用于全局相册。只提交变化的独立范围，同operationID去重，回执未知仅回读不重放，明确返回目标偏好才confirmed。权限拒绝遵从NAS，不借浏览偏好授予相册或原件权限。

macOS顶部原生菜单、中英资源、全部/我的相册和当前排序勾选；改变后只重载当前列表，代次丢弃旧页/旧偏好；每页携带相同条件，切换分享范围及重新打开重新读取各自偏好。没有本地存储变更、工具链/依赖/权限新增，其他端UI不修改。回滚移除客户端新增方法、类型和入口；NAS已存偏好保留，可在网页更改。

PENDING_USER_VALIDATION：在有可查看相册的账号中分别修改相册首页、与我共享、与他人共享的字段与方向；切全部/我的相册、翻页、重新打开并与网页核对。三个范围应互不影响，原件内容与共享权限不变；home关闭仍可浏览和排序，断网后只核对同次保存。只回传脱敏版本、操作步骤、错误文字，不提交相册名、分享链接、凭据。未提升任何版本行为验证等级。


### 2026-09-30 预览旋转后续切片（仅static，未实现）

官方预览ROTATE实际绑定个人/共享Item.set：`id:[照片编号]`、`rotate_action:"counter_clockwise"`。成功后更新原图库布局与缩略图缓存；用户目标是保存旋转到NAS，不是纯本地显示角度。当前已确认调用链，但本轮未新增客户端写入口，尚需补全版本/媒体限制/方向回读、原件身份和未知结果不重放方案后实施。旋转属于非幂等操作，不能用重试set来确认结果；不得从常量列表臆造未观察到的菜单选项。真实NAS验证仍由用户承担。


### 2026-09-30 预览旋转保存静态补证

同一官方脚本Item版本表set:2/get:5，个人及共享路由沿已确认Item.set调用链。菜单在图片未准备好、video/video360/photo360、GIF、WebP时排除旋转；方向转换逆时针映射1→8、2→5、3→6、4→7、5→4、6→1、7→2、8→3，宽高交换。实况预览仅在orientation与orientation_original相等时显示动态播放。网页匹配GIF/WebP文件名，客户端按扩展名匹配，避免名称中间含后缀的误判。证据仅static，不是请求或写行为验证。

本轮新增单张rotatePhoto命令与rotation能力，固定原照片/方向/尺寸快照；写前重新核对身份、方向与管理权限；Item.set v2仅发送id和rotate_action=counter_clockwise。操作编号沿既有去重，失败/丢回执只读Item.get v5核对预期方向和交换后的尺寸，不重发旋转。已确认后重新请求当前预览与更新缩略图，图片请求既有reloadIgnoringLocalCacheData。不会重载图库或跳回最新月份。原件字节是否改变未验证，照片身份/大小变化不擅自追认。


## 2026-09-30 照片显示偏好（static）

稳定标识`photos-display-settings`。内部`SYNO.Foto.Setting.User`，能力发现路径（当前entry.cgi），POST JSON，get/set v1，当前登录Photos用户自己的偏好；不要求个人空间开启，不改变原件与共享授权。沿本轮环境快照的未知版本限制，未执行真实NAS写入。

字段：timeline_group_unit=day/month；date_format支持yyyy-mm-dd、yyyy/mm/dd、yyyy.mm.dd、dd-mm-yyyy、dd/mm/yyyy、dd.mm.yyyy、mm-dd-yyyy、mm/dd/yyyy、mm.dd.yyyy；time_format=12/24字符串；item_sort_by=filename/filesize/item_type/takentime；sort_direction=asc/desc；show_item_info_in_lightbox为布尔值。前端将date_format读为大写、保存小写，客户端规范化为小写，日期格式转换用公历年yyyy，不误用周所属年YYYY。

官方设置表单及eLL/eLN保存调用链：比较差异，仅传改变字段，必要时重新读取设置。底部信息显示拍摄日期、前三项地址和描述，视频不显示；详情侧栏打开时隐藏底部信息。日/月为时间线显示分组。默认照片排序影响未自行指定排序的目录，保留现有目录/相册显式排序和时间线按日期分组；本轮不改变原相册排序契约。外观使用App原生外观设置，不重复修改NAS网页主题。

新增可选显示偏好于access及默认明确不支持的displaySettings服务，旧调用兼容。写前重新读取完整六项原快照，过期拒绝；只写差量，重复操作编号去重；最终回读一致才应用。缺字段/未知值不能证明保存成功，不用默认值回写。macOS从访问结果应用已知偏好，改变分组/日期/预览信息不重载图库或清空月份、选择；底层仍以日时间段分页保证现有锚点和批量核对语义。没有本地持久化、权限、依赖或其他端界面变更。

PENDING_USER_VALIDATION：个人及仅共享/相册可用账号，在设置→照片显示中分别切换全部字段、重开并与网页核对；已有目录/相册显式排序不受默认设置覆盖，未设排序目录采用新默认。2020.03内日/月切换保持月份与照片；预览/幻灯片显示日期地点描述、视频不叠加，详情侧栏日期遵从选择。补测断网后自动只读确认、设置同时被网页修改后的冲突；回传脱敏版本、步骤、提示和显示差异即可。回滚移除新增类型/入口/读取应用，NAS偏好仍可在网页调整。


## 2026-09-30 个人识别设置（static）

稳定标识`photos-recognition-settings`。内部SYNO.Foto.Setting.User get/set v1、SYNO.Foto.Setting.Admin get v1，能力发现路径（当前entry.cgi），POST JSON；个人设置无FotoTeam替换，不能借当前共享空间修改全局或共享识别。读User的enable_home_service及可选enable_person/enable_concept/enable_similar，Admin的对应可选布尔字段作为实际全局条件。未知字段不猜false；两侧都有明确值才形成可管理项，个人空间开启且全局true时可编辑。

官方个人表单仅在管理员启用识别和个人空间可用时提供对应项；保存与其他个人设置统一按差量调用User.set，只写发生改变的enable_*布尔值。个人识别保存没有额外的原件删除请求，不从这一点推断关闭识别时NAS索引的所有长期行为。全局设置另有管理员页，不在本切片修改。eHo保存后按识别变化重新加载设置与页面；原生端保留时间线位置，只更新分类能力/卡片，关闭正在浏览的个人分类时回到相册首页。

共享新增SynologyPhotoRecognitionSettings，已知值、全局启用项和个人空间条件分离；prepare及写前读取User/Admin完整原快照，过期/权限变化拒绝，目标变化必须完全属于可编辑项。相同operationID不重复写；回读全部已知值、个人空间与全局条件一致才confirmed，字段缺失或变化保持待核对。已知关闭的个人分类拒绝继续读取/管理，旧环境缺字段沿既有Category能力；共享分类沿原团队权限和开关。其他端旧适配器默认明确不支持，不扩大其他端UI。

PENDING_USER_VALIDATION：个人设置分别开关人物/主题/相似照片，重开并与网页核对；图库当前月份和选择保持，个人分类卡片同步更新，关闭正在浏览的分类返回相册首页，共享分类不变。补测管理员关闭、个人空间关闭、服务器缺少某项字段、断网和网页同时修改；无权限不能写、未知结果只核对。仅回传脱敏版本/步骤/提示及分类变化，不提供照片、凭据或地址。回滚移除新设置入口/契约与应用逻辑，已保存NAS偏好仍可由网页修改，无本地数据迁移。

自动生成预览的本轮静态补证：auto_generate_thumbnail开关与桌面转换能力共同形成isSupportAutoGenerateThumbnail，依赖本机HEVC/VC1/VP9/MPEG2能力、原件读取和生成结果上传。现有手动预览重建可复用部分流程，但自动触发不能等同保存一个布尔值；本轮不宣称自动生成已完成，下一切片继续核对触发条件及取消/去重。


### 2026-09-30 默认排序确认交互

macOS显示设置现在仅在默认排序字段或方向变化时确认，显示冻结目标字段/方向；取消保留窗口草稿且不写NAS，确认复用原setDisplaySettings差量保存/去重/结果核对。普通显示设置不额外确认。本轮无新API或证据等级变化；4项显示设置XCTest、6项本地化、2项原生UI通过，真实NAS仍待用户验证。浏览器本次报告锁屏，未进行新的官方请求观察。


## 2026-10-01 NAS后台任务中心补证（static，待接入）

来源：当前Chrome官方`react_bundle.js`，环境见[只读续查快照](../environments/2026-10-01-photos-remaining-observation.md)。仅读取脚本，未列出真实任务、未执行取消/清理。以下是已观察官方静态处理链，不代表真实NAS兼容或完成实现。

- 所有后台任务控制统一使用`SYNO.Foto.BackgroundTask.Info` v1：`list_user_task`无参数；`get_status`参数`id:[任务编号]`；`abort_task`参数`id:[任务编号]`；`clear_completed_task`清理全部时无参数，单项时`id:任务编号`（标量）；`get_error_detail`参数`id:任务编号`（标量）。路径沿能力发现，不记录当前主机或会话。
- `list_user_task`返回`list`，官方映射：`id`、`operation`、`status`、`total`、`completion`、`error`、`skip`、`overwrite`、`create_time`，`target_folder.id/owner_user_id`及`extra_info`。owner_user_id决定个人/共享目标空间，沿既有0表示共享规则。
- `operation`枚举copy/move；状态waiting/processing/aborting/done。`completion`是已处理数量（包含错误项），不是纯成功数：成功展示使用completion-error；skip/overwrite作为成功细分。取消完成判据是done且completion<total，取消数量显示total-completion+error。不能把done等同全部成功。
- extra_info是JSON字符串：version=1含source_folder_ids；version=2还含source_library。缺失/解析失败仅缺少源上下文，不猜目标空间。该信息用于导航/错误来源，不应成为新请求凭据。
- 官方列表加载映射全部项目；监控waiting/processing任务，按已知id调用get_status，条目消失时移除。取消接口成功后持续get_status至任务消失或done。get_status只用list[].id/status/completion/error/skip/overwrite，不依赖目标字段。
- 清理单项和全部已完成任务为不同参数范围；客户端实现必须固定用户确认的范围并回读列表，不能照搬网页乐观移除来证明成功。未知回执只回读，不自动重放，保留在途操作。
- 错误详情list[]使用type=item/folder、id、reason。照片补充Browse.Item.get(id数组,additional=[folder])获取filename/folder_id/additional.folder；目录逐项Browse.Folder.get(id标量)取parent，再读取父目录，原件已经不存在时网页排除该项。来源API由任务library选Foto/FotoTeam，准确错误码表和跨空间来源选择仍需后续核对。
- 列表UI：waiting显示等待；processing显示completion/total进度；aborting显示正在取消；done且未取消、全部错误时显示失败；完成项可打开目标目录，错误计数入口显示错误详情。活跃项提供取消，终态项提供清理及后续操作。独立于本机上传队列，不能仅复用上传记录代替。

当前只有static证据，尚未扩展领域/Repository/原生入口，真实响应和写行为由用户后续验收，不在本次发现中操作真实任务。冻结条件相册补证仍在photos-advanced-management记录，持久化授权待办不受本节影响。

2026-10-01接入更新：上述后台任务发现记录已转为独立稳定文档[photos-background-tasks](photos-background-tasks.md)，Core/Repository/macOS入口已实现，本地合成回归已通过；发现证据等级仍为static。后续状态以独立文档与Photos对齐账本为准。


### 2026-10-01 相册贡献者信息编辑与旋转角色补证（static）

沿photos-remaining-observation-20261001环境读取官方react_bundle.js：Mk/ML选择器按选中项目provider_user_id与当前UserInfo.id比较。个人来源开启时，普通本人/他人相册中本人提供者有标签、评级和时间编辑资格；仅下载者没有。共享来源必须Ei（全空间MANAGE），仅本人提供且非MANAGE只有重建与移出。混合来源的普通相册仅MANAGE且个人照片均本人提供可评级/时间，标签仍不支持跨空间。条件/冻结相册有独立菜单，不把普通相册的提供者限制误套到本人原件。

预览en选择器与isReadOnly使用同一资格：个人来源本人提供者可旋转/说明编辑；共享相册来源以全空间MANAGE判断。D6/D9/D8/D7/ke/kt分派个人/共享Browse.Item，eOq最终set({id:idArray,[key]:value})，key为rotate_action/description/time；没有album_id或分享参数。eOX批量日期用time或shift_time；当前客户端保持已实现的绝对时间核对语义。本轮不新增NAS参数，不执行NAS写验证。

客户端对metadata/rotation/tags/tagCreation的相册目标新增独立预检：通过既有相册上下文get读取真实提供者和原件身份；个人检查实际提供者，共享检查MANAGE，条件/冻结保留本人原件路径。写入仍按原空间路由，删除与移动继续用原有更严格规则。实现及测试尚待本轮三项全部完成后统一验证，证据不提升为behavior-verified。

静态菜单清单：GRID动作并集为EDIT_GENERAL_TAG、EDIT_RATING、EDIT_DATE_TIME、REGENERATE_PREVIEW、MOVE_TO、COPY_TO、UNSTACK、SET_AS_FOLDER_COVER、RENAME、CHANGE_FOLDER_COVER、COLLECT_PHOTO_TO_HERE_FROM_FOLDER、EDIT_PERMISSION、DELETE、REMOVE_FROM_ALBUM、SET_COVER、DELETE_IN_ALBUM、SET_PERSON_COVER、REMOVE_FROM_PERSON_ALBUM、SET_CONCEPT_COVER、REMOVE_FROM_CONCEPT_ALBUM（另含分隔符）；PREVIEW为SLIDESHOW、DOWNLOAD_ITEM、ADD_TO_ALBUM、ROTATE、REGENERATE_PREVIEW、MOVE_TO、COPY_TO、EDIT_FACE、SET_AS_STACK_COVER、REMOVE_FROM_STACK、KEEP_THIS_DELETE_REST、SET_AS_FOLDER_COVER、SET_COVER、DELETE、REMOVE_FROM_ALBUM、SET_PERSON_COVER、REMOVE_FROM_PERSON_ALBUM、SET_CONCEPT_COVER、REMOVE_FROM_CONCEPT_ALBUM。须按源码逐项对照，不以菜单数量当作功能验收。

### 2026-10-01 菜单终审补证（static）

官方react_bundle中3176000附近的P函数要求平台支持人脸识别并启用当前空间识别；3179900–3181400的普通/共享相册预览分支对个人提供者、共享management提供EDIT_FACE菜单。原生手动人脸因此复用本轮资料编辑角色，并保留现有Item.list_face v6、Person.add_face v3/delete_face/separate及上传编号核对，未新增NAS接口。原件删除、移动仍使用原有独立权限。2692274/2693142的列表动作定义与2727911/2728084的kZ/k0表明COLLECT_PHOTO_TO_HERE_FROM_FOLDER通过openPhotoRequestDialogAction打开照片请求，对应原生createPhotoRequest。

本机上传恢复新增的是客户端本地记录能力，不是NAS新增API，也不提升接口证据等级。仅持久化上传、直接相册上传、创建上传目录、加入相册的意图与必要回执；恢复只调用既有只读核对。没有回执时不按文件名自动追认，用户明确核对后只能移除本机记录。会话与分享口令禁止进入该文件。当前完整功能覆盖与验收范围见[照片计划](../../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。
