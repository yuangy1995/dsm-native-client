# Synology Photos 图库读取、相似组与后台任务

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="photos-library-read"></a>
<a id="photos-internal-candidate"></a>
## Synology Photos 图库与媒体


稳定标识 `photos-library-read`；internal，隐私风险high；大部分为读取，原尺寸JPEG的convert会生成派生缓存，属于mixed。早期标识 `photos-internal-candidate` 仅保留历史定位，不是另一个适配器。现行图库不回退File Station，不构造不存在的FotoTeam.Browse.Album。

[证据索引](../environments/INDEX.md)区分09-09/10个人读取、09-28起静态共享/相册、10-16 Windows读取回归。设备归属未知不冒用lab-a；单个方法读取成功不证明其他方法、平台或权限通过。

### 访问、编码与分页

UserInfo.enabled、User.enable_home_service及TeamSpace.enabled和team_space_permission分别判断；none无共享访问，entry依目录view/download/upload/manage，management仅共享范围生效，DSM is_admin不能代替Photos角色。刷新授权使旧在途结果失效，缺能力只影响相关功能，拒绝不能伪造为空或回退其他空间。

API.Info声明entry.cgi/JSON，POST表单内业务字符串和数组按JSON值编码。官方请求可使用/webapi/entry.cgi/<API名>；实际路径按能力发现。会话秘密不进入普通媒体URL。空页合法，满页继续；offset按原始返回数推进，不能按客户端筛选后数量推进。

### 基础读取

| API | 方法 / 实际版本 | 业务参数 | 成功响应 data |
| --- | --- | --- | --- |
| `SYNO.Foto.UserInfo` | me / 1 | 无 | enabled:boolean、is_admin:boolean；不保存用户信息 |
| `SYNO.Foto.Setting.User` | get / 1 | 无 | enable_home_service:boolean、team_space_permission:string 等 |
| `SYNO.Foto.Setting.Admin` | get / 1 | 无 | package_version:string；人物、主题、分享等设置布尔值 |
| `SYNO.Foto.Setting.TeamSpace` | get / 1 | 无 | enabled:boolean、team_space_disabled_by_share_folder_disabled:boolean |
| `SYNO.Foto.Browse.Timeline` | get / 5 | timeline_group_unit="day" | section:[{offset:number,limit:number,list:[{year,month,day,item_count:number}]}] |
| `SYNO.Foto.Browse.Item` | list / 4 | offset、limit、additional；时间线 start_time/end_time；文件夹 folder_id、sort_by="takentime"、sort_direction="asc" | list:[媒体项目]；未返回 total 或 has_more |
| `SYNO.Foto.Browse.Item` | count / 4 | folder_id:number | count:number |
| `SYNO.Foto.Browse.Folder` | get / 2 | id:number、additional=["access_permission"] | folder:{id,name,parent,owner_user_id,shared,sort_by,sort_direction,additional}；不保存名称或分享凭据 |
| `SYNO.Foto.Browse.Folder` | list / 2 | id、offset、limit、sort_by="filename"、sort_direction="asc"、additional=["thumbnail"] | list:[文件夹] |
| `SYNO.Foto.Browse.Folder` | list_parents / 1 | id、default_sort_direction | list:[父文件夹]；根 ID 不可硬编码为 0 或 1 |
| `SYNO.Foto.Browse.RecentlyAdded` | list / 1 | offset、limit、additional=["thumbnail"] | list:[媒体项目] |
| `SYNO.Foto.Browse.Person` | list / 1 | offset、limit、additional=["thumbnail"] | list:[{id,cover,item_count,name,show,additional}]；封面 thumbnail 可能仅有 cache_key |
| `SYNO.Foto.Browse.Concept` | list / 2 | offset、limit、additional=["thumbnail"] | list:[{id,item_count,name,sort_index,visibility,display_threshold,additional}] |
| `SYNO.Foto.Browse.Geocoding` | list / 1 | offset、limit、additional=["thumbnail"] | list:[{id,item_count,name,country,country_id,first_level,second_level,additional}] |
| `SYNO.Foto.Browse.GeneralTag` | list/count / 1 | list 使用 offset、limit、可选 additional | list:[] / count:number；空列表不能证明标签元素结构 |
| `SYNO.Foto.Browse.Album` | count / 3 | 按官方页面请求进一步核对 | count:number；非空/写入证据按环境记录区分 |
| `SYNO.Foto.Browse.Category` | get / 3 | 无 | list:[{id:string}] |
| `SYNO.Foto.Search.Filter` | list / 3 | additional=["thumbnail"]、setting:按筛选项启用的 object | item_type、time、person、geocoding、rating 等数组；具体组合证据按环境记录区分 |
| `SYNO.Foto.Search.Search` | get_search_timeline / 2 | timeline_group_unit="day"、keyword:string | section 时间分组；合成关键词经官方 UI 搜索，成功响应已核对 |
| `SYNO.Foto.Search.Search` | list_item / 1 | keyword、offset、limit、start_time、end_time、additional 同时间线 | list:[媒体项目]；使用合成关键词观察到非空成功响应 |

媒体字段id/filename/filesize/time/indexed_time/owner_user_id/folder_id/type/additional保留原身份。time为Unix秒，indexed_time为整数毫秒且保留非整秒精度；不能按数值大小猜单位。10-16官方脚本与生产Windows只读复验确认该单位；Apple/Android已知适配缺口见[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。旧错误恢复身份不自动换算或继续不匹配写入。

时间线additional为thumbnail/resolution/orientation/video_convert/video_meta/address；目录不请求address。resolution含width/height，orientation与orientation_original为数值；thumbnail含unit_id/cache_key/m/xl/preview/sm。媒体类型已观察photo/video/live，不能凭同名文件拼Live Photo。根目录以Folder.get v2(name="/")解析，不能硬编码0或1。

### 分类与筛选

Category.get v3统一Foto，分类有recently_added/person/concept/geocoding/general_tag/video；普通Album空不代表分类不存在。FotoTeam复用Person/Concept/Geocoding/GeneralTag/RecentlyAdded与Item版本，**不含Category或Album/NormalAlbum/ConditionAlbum**。分类空间与后续列表一致；卡片offset=0/limit=4/additional=[thumbnail]，人物show_more=true，视频Item.list v4(type=video)。

Timeline.get_with_filter v3、Item.list_with_filter v2：timeline_group_unit=day；item_type=[0或1]、person数组+person_policy=or、geocoding数组、rating=[0…5]、time=[{start_time,end_time}]，项目另加offset/limit/additional。camera/lens/iso/aperture/general_tag为数字ID数组，general_tag_policy=or；focal_length_group=[{start:Int,end:Int}]；exposure_time_group=[{start:{num,den},end:{num,den}}]，分母>0，零端点是开放边界。候选名称不参与请求。flash虽出现但官方标准过滤器排除，不猜编码；未取得可用concept/folder_filter候选不造选项。筛选失败不清空主列表。

主题Item/Timeline可传concept_id；标签general_tag_id等非空样本的覆盖见环境记录。相似专用get_similar/list_similar与分组规则见[相似照片](photos-library.md#photos-similar-items)，不与普通聚合时间线混用。

### 相册、分享与上下文

Album.list v4(offset/limit,category=normal_share_with_me,additional=[thumbnail,sharing_info])；与我共享使用Sharing.Misc.list_shared_with_me_album v2并取access_permission；与他人共享Album.list v4(category=shared,sort_by=share_modify_time,sort_direction=desc)。缺排序曾返回120/sort_by/condition，不能误归因于access_permission。PhotoRequest.list v1(offset/limit)的空成功与非空字段证据分开。

相册Item.list v4统一Foto：album_id、分页/排序、additional=[thumbnail,resolution,orientation,video_convert,video_meta,provider_user_id]。owner_user_id=0共享、正数个人，未知不能猜；owner是来源身份，**不替代相册访问权**。相册上下文的Item.get v5、Unit.get v1、Thumbnail、Streaming及Download始终统一Foto并携原album_id。个人/共享原空间关闭仍可访问本人被授予的相册；拒绝后不退回原件接口。原件修改仍独立检查真实来源与权限，provider/协作规则见[高级管理](photos-management.md#photos-advanced-management)。

### 缩略图与视频

个人路由/synofoto/api/v2/p/Thumbnail/get，共享为/t/Thumbnail/get；id/cache_key/type/size，其中普通unit使用m或xl等实际可用尺寸。相册统一个人路由并带album_id。人物封面有unit_id用type=unit，否则type=person；人脸type=face且无size。

Folder.get/list v2 additional.thumbnail为数组：默认unit_id/cache_key，自定义folder_cover_seq/cache_key。默认type=unit/id=unit_id/size=m，自定义type=folder/id=目录/folder_cover_seq/cache_key且不传size。先核对目录view；单图失败不阻断目录。排序/封面保存只维护于[管理定义](photos-management.md#photos-management)。

Item.get v5提供video_convert；实况先Unit.get v1(id_item数组,additional=[orientation,resolution,thumbnail,video_meta,video_convert])，核对id_item并选唯一live_type=video单元。不能用主照片ID或缩略图ID替代视频单元。

存在实际转换档位才用Streaming.streaming v2(id,type=item/unit,quality,use_mov=true)，已知质量顺序raw/orig_h264/high/medium/low/mobile；raw或无转换版使用Download.download v2，普通item_id数组、实况unit_id数组。播放不加force_download，不请求组合ZIP。该选择与文件扩展名无关；无转换MP4的high曾404而原件206，不等于编码不支持。Range、响应类型、同源与证书检查继续生效。

### 原件、JPEG与归档

Download.download v2支持download_type=source/optimized_jpeg，item_id数组、force_download=true；按原来源Foto/FotoTeam，相册统一Foto并携上下文。单张视频/GIF/WebP无压缩菜单，混合输出可保留原格式；实际字节格式决定扩展名，不把原格式伪装JPEG。

单文件保存使用受保护临时文件，核对HTTP/类型/长度，拒绝JSON/HTML/ZIP错误结果，失败/取消不覆盖目标。JPEG完整解码；optimized_jpeg若仍原格式需核对原件大小。相似列表下载先完整展开成员，预览只下载当前项。

整相册Browse.Album.download v2：所有者id单整数或协作passphrase字符串，download_type=source/optimized_jpeg；普通/条件相册同法。目录Download.download v2用folder_id数组；同级混选同时用非空item_id/folder_id，至少一个目录，不从已加载照片拼完整内容。三类均POST，口令只在请求体；force_download=true仅用于目录和混选的Download.download，相册Browse.Album.download不发送该字段。逐目标固定身份/实际下载权，全部预检成功后一次请求；不因一项失败偷偷下载剩余。

归档须HTTP200、非JSON/HTML、长度一致并检查ZIP首标识及结束记录，末尾最多65557字节；这不是全文件CRC或ZIP64实机验收。取消/失败保留旧本地文件，不扫描原件或借File Station绕过权限。

原尺寸JPEG仅单张、User.ame_status.has_hevc与Admin.enable_converted_original_jpeg明确true；HEIC/HEIF/HIF及TIFF/RAW类，不扩大为整册或相似组批量。Download.convert v2 POST(item_id单整数)成功信封后，download v2(item_id数组,force_download=true,download_type=original_size_jpeg)。相册所有者album_id、其他成员按实际下载权passphrase；本人provider的额外资格须以最新相册get验证，不能绕回原空间。

convert可能产生NAS派生缓存，取消不能承诺撤回；同目标去重，不自动重发，输出必须可完整解码为JPEG，不能降回原件并误标格式。实际转换/缓存/大归档与设备编码能力仍未验证。

### 实现范围

当前平台状态见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)，目标平台与真实NAS验收条件见[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。本页只维护当前读取/导出语义，不保存逐轮构建数字或平台施工状态。

<a id="photos-similar-items"></a>
## Synology Photos 相似照片分组


### 标识、证据与范围

稳定标识 `photos-similar-items`；组件 `synology-photos`；内部接口，读取涉及私有照片，隐私风险 high。2026-09-30 从已登录官方页面加载的脚本静态核对，环境沿用 [观察记录](../environments/INDEX.md#2026-09-28-photos-parity-observation)，DSM/套件版本和设备归属未确认。证据仅为 **static**，没有真实 NAS 请求或写入验收，不挂靠旧 lab-a verification。


### 请求与响应

使用能力发现路径 `entry.cgi`，HTTP POST，业务字符串/数组按既有 JSON 参数编码；会话仅使用现有认证通道。以下 API 前缀按照片实际来源选择 `SYNO.Foto` 或 `SYNO.FotoTeam`，不混用来源。

| API 后缀 | 方法/版本 | 参数 | data 结构 |
| --- | --- | --- | --- |
| Browse.SimilarTimeline | get_similar / 1 | timeline_group_unit="day" | section[].list[] 含 year/month/day/item_count；沿用日期时间线解码 |
| Browse.SimilarItem | list_similar / 1 | start_time/end_time、offset/limit、additional；分类拼图 offset=0/limit=4/additional=[thumbnail] | list[] 为照片，顶层 similar 含 id/count/top_pick/item_id |
| Browse.Similar | get / 1 | id=[groupID] | list[] 为分组快照，同上四字段 |
| Browse.Item | get / 5 | id=分组 item_id，additional=[folder,thumbnail,resolution,orientation,video_convert,video_meta] | list[] 完整成员；沿用照片库基础字段 |

分组字段 id/count/top_pick 为整数，item_id 为整数数组；显示至少两项的有效分组。count 与唯一成员数必须一致，top_pick 及入口照片必须属于成员。成员回读集合完全一致后按 item_id 顺序组装，不依赖响应顺序、不按文件名补齐成员。详情接口保留代表照片的分组身份，组内读取另行获取新快照。

### 能力、权限与失败处理

分类由 Category.get v3 的 similar 项决定；还必须具备上述三个 Similar* v1 能力、个人 UserSetting.enable_similar 或共享 TeamSetting.enable_similar。共享分类要求实际 management 权限，目录 entry 不代表可读取整个共享库。没有因为待实机验证而增加禁用白名单。

固定 profileID/space/groupID，拒绝相册上下文、跨设备、跨空间及不匹配成员；权限刷新使在途读取失效。失效或解散的组显示可重试错误，不恢复旧列表；组内读取失败不遮挡已经加载的照片，关闭或切换预览后迟到结果丢弃。接口不可用不阻断其他分类，不回退扫描文件夹。未知错误使用现有通用映射，不推测专用错误码。

副作用：以上均为读取，没有 NAS 修改。本地只有短期预览状态，没有新增持久化结构。

### 分组管理

下列官方静态方法，共享/个人分别使用 FotoTeam/Foto.Browse.Similar v1；没有真实 NAS 写入，证据仍 static。分组移出不是原件删除。

| 方法 | 参数 | 用户结果 |
| --- | --- | --- |
| set_top_pick | id=groupID, item_id=当前照片整数ID | 更改推荐项 |
| ungroup | id=[groupID] | 拆分组，保留原件 |
| remove_item | id=groupID, item_id=所选整数ID数组 | 移出所选成员，保留原件 |
| add_item | id=原groupID, item_id=原成员数组, top_pick=原推荐项 | 撤销本会话已确认的拆组/移出 |

共享契约增加similarGroups能力、editSimilarGroup(detail, edit)命令及结果similarGroup；仍走现有operationID记录、prepare/perform/review流程，不新增平行写操作系统。UI保留完整确认快照，缩略图独立勾选多个成员；更改前确认原件会保留，成功后提供撤销。未实测不构成功能禁用条件，实际设置/能力/权限继续生效。

预检先固定每张原件的profile/space/id/filename/filesize/folder/indexed_time/type与目录管理权限，再读取Similar.get和SimilarItem.get的成员归组信息，必须仍与原快照一致。每次写入前重查分类访问权；未知提交只读核对，同operationID不重发。SimilarItem.get v1使用id=原成员数组、additional=[thumbnail,resolution,orientation]；身份字段和顶层similar沿只读分组契约。

核对：推荐项需精确成员集合及top_pick，移出需剩余集合完全匹配且所移出照片不再归属原组，拆组需组不存在或有效count小于2且所有原照片不再归属原组；不能只凭组列表消失推断。有效单成员组也按解散处理，非法字段、失败响应和读取异常绝不当作空组。所有结果都需回读完整原件，不能因分组操作而静默接受原件消失。

撤销仅接受同会话已confirmed的remove/ungroup记录与完全相同原快照；重新核对原操作结果仍成立，原件仍可管理，且成员未加入其他组。成功回读恢复原成员集合和原top_pick；同原操作只能发起一次撤销，未知不换编号重试。跨重启恢复范围按平台矩阵记录。新月份窗口只更新已有同组，恢复旧组不会把旧月份照片插进新窗口。


### 清理、批量与识别状态

Similar.get_status v1无业务参数，返回waiting_count（非负整数）、similar_clustering_stage（非空字符串）、is_similar_hash_migration_done（布尔）；两空间各用其API前缀。零等待且迁移完成时不提示；数量大于零且stage=running时显示数量，其余显示等待处理。不枚举或猜测其他stage含义；按15秒间隔仅在分类可见期间读取，错误不阻断浏览，授权代次变化丢弃结果。来源仍是官方静态脚本，没有当前NAS返回验证。

similarGroupDetails允许读取已解散组为空，读取失败绝不伪造解散。删除前先核对完整原组和每张身份，再固定保留补集作为删除确认名单；原件删除沿photos-item-deletion既有契约，无新删除端点。已确认删除后只读刷新原组，不将分组消失当作原件删除证据。最多三次自动读取失败后可只读重试，不刷新整个月份。

多组拆分在一次确认后逐组提交既有ungroup(id=[单组])，保留每组operationID；未知暂停后续，确认成功再续作，失败保留继续/取消选择。会话撤销按逆序恢复已确认组，不覆盖其他操作；删原件不进入分组撤销。平台实现范围见平台矩阵，接口证据仍为static。

#### 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。

<a id="photos-background-tasks"></a>
## Synology Photos 后台任务中心


### 标识与环境

端点组 `photos-background-tasks`，组件 `synology-photos`，内部混合读写接口，风险 medium。首次静态发现及本次复核日期2026-10-01，来源为已登录官方Photos页面加载的react_bundle.js；[环境快照](../environments/INDEX.md#2026-10-01-photos-remaining-observation)尚未确认DSM/build/Update及Photos版本，不归入lab-a或任何已验证基线。证据仅static，未列出或修改真实NAS任务。

### 请求契约

统一 `SYNO.Foto.BackgroundTask.Info` v1，POST JSON，路径来自能力发现（候选 `/webapi/entry.cgi`）；沿现有会话认证，凭据不保存于任务快照。不使用FotoTeam替换，即使目标是共享空间。

| 方法 | 参数 | 结果/副作用 |
| --- | --- | --- |
| list_user_task | 无 | 当前用户任务，data.list数组 |
| get_status | id整数数组 | 已知任务状态，data.list；任务可能消失 |
| abort_task | id整数数组 | 停止未处理部分；已完成复制/移动保留；接收回执不代表已经停止 |
| clear_completed_task | 单项id整数标量；网页全部清理无参数 | 清理终态任务记录，不删除照片或文件夹 |
| get_error_detail | id整数标量 | data.list包含type、id、reason |

list字段：id整数；operation字符串copy/move；status字符串waiting/processing/aborting/done；total、completion、error、skip、overwrite整数；create_time时间戳；可选target_folder含id和owner_user_id。owner_user_id=0为共享，等于当前用户为个人；其他值不推断可导航空间。extra_info为JSON字符串，version1包含source_folder_ids，version2增加source_library；客户端当前不靠该字段推断错误照片身份。

completion是已处理数并包含失败；成功数completion-error；done且completion<total表示取消后终态。done且全部失败不能显示成功，aborting仍在途。未知类型/状态保留可读摘要，不开放取消或清理。无效计数、重复编号、缺必需字段明确失败，不静默当成空列表。

错误reason：quota_full账户配额；space_full存储满；skipped目标在来源子目录；not_existed原项目不存在；target_not_existed目标不存在；excluded_extension排除类型。其他值保留为未知原因，不直接给用户显示原始码。type为item/folder，未知type不能借类型猜测原件路由。官方详情通过目标library的Item.get(additional=folder)或Folder.get补姓名/路径；客户端沿官方目标library路由补名称/目录，并按编号匹配，不依赖返回顺序；原件已不存在或无权读取时仍保留错误原因。跨空间错误来源仅有static证据，真实NAS需验证，不推断另一来源空间。

### 权限、确认与结果核对

读取依赖Photos登录用户身份和Info v1能力，允许个人空间关闭但统一Photos入口可用的用户查看任务。任务快照绑定NAS profile UUID、Photos用户ID、任务ID、创建时间、操作、总数和目标；prepare及提交前重新读取当前用户任务列表，身份变化拒绝写入，进度变化允许。所有写操作以原生确认冻结快照。

取消和清理复用既有mutation操作编号去重、拒绝处理与只读回读。取消回读done或记录消失才结束核对；未知回执不重发。清理全部使用确认快照逐项标量请求，不调用无参数范围接口，因此随后完成的新任务不会被清掉。中途失败只核对已尝试项；确认部分成功后剩余记录保留并允许重新选择。

后台控制允许取消本App尚待核对的复制/移动；独立保留控制操作编号，不替换原搬移操作。原搬移done但未全部处理时返回partial；不能提前清理本会话仍待核对的任务记录，以免删除唯一终态证据。旧适配器默认明确不支持新增读取，其他端不会静默执行。

窗口关闭停止刷新而不取消NAS任务。目标跳转沿实际目录权限和父链，重复父节点/账号变化拒绝跳转；不能凭任务目标获得新的文件访问权限。错误或不支持不阻断普通图库。


接口字段来自官方静态资源；没有真实任务控制验证。平台状态及恢复实现见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)，用户验证条件见[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
