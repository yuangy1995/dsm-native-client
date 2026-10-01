# Synology Photos 照片库只读接口

## 2026-09-29 共享空间静态补证与读取适配

来源为已登录官方页面加载的 react_bundle.js，环境见2026-09-28-photos-parity-observation.md；DSM/Photos版本仍未确认，只登记 static，不覆盖下文历史只读验证结论。

- 官方 team_space_permission 枚举为 none、entry、management；none 无访问权，entry 使用目录权限，management 对应共享空间管理权限。入口同时依赖 team_setting.enabled；UserInfo.is_admin 不作为替代授权。
- 目录 access_permission 的键为 view、download、upload、manage。官方权限判断允许 management，或核对当前目录对应权限；entry 不能被等同为所有目录可读写。
- 官方空间路由选择 Foto / FotoTeam；Thumbnail.get v2 的个人路由为 /synofoto/api/v2/p/Thumbnail/get，共享路由为 /synofoto/api/v2/t/Thumbnail/get。参数仍为 id、cache_key、type、size。此处仅核实静态路由，没有请求真实共享图片。
- Apple Repository 已增加上述空间角色判定、FotoTeam读取能力发现、按照片身份选择 p/t 路由；共享管理角色可读取共享根目录，entry仍按view字段核对，管理角色不会绕过个人目录权限。重新核对权限先撤销旧授权，图片读取期间授权代次变化则不返回旧图片。接口缺失不回退个人空间；未改写任何NAS权限。
- 后续同日增量：macOS 时间线/文件夹新增空间选择器；显式切换和权限回退同步清除旧目录、分类、筛选、搜索、预览与选择。上传队列固定入队空间；相册/分享仍使用个人入口，返回照片库恢复原选择。共享分类与相册来源尚未完整接入，不宣称全量对齐。
- 共享空间完整读取及写入仍未完成；需要合成路由/权限回归，以及 entry、management 账号的真实 NAS 验收。没有新增默认禁用名单或改变 NAS 权限策略。

> 最新补充：2026-09-10 系统分类、组合筛选、只读共享和实况视频单元，见本文末尾与当天环境记录。早期施工状态保留为历史，不代替当前实现账本。

## 标识与环境

- 稳定标识：`photos-library-read`；组件 `synology-photos`；分类 `internal`；操作 `read`；隐私风险 `high`。
- 发现日期：2026-09-09；DSM 7.2.1-69057 Update 12；Photos 1.8.2-10090。
- 环境证据：[本次观察](../environments/2026-09-09-photos-observation.md)。与既有 lab-a 的设备关系未确认，不冒用旧环境 verification。
- 证据等级：以下明确标注成功响应的个人空间接口为浏览器 `read-verified`；不代表 App 会话验证、跨版本或写操作验证。

## 请求契约

官方请求为 POST `/webapi/entry.cgi/<API名称>`，能力发现声明相对路径 `entry.cgi`、`requestFormat=JSON`。外层仍为 form-urlencoded；业务字符串以 JSON 字符串编码，数组为 JSON 数组。身份由现有会话提供，不保存值；客户端不把凭据放入 URL。

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
| `SYNO.Foto.Browse.Album` | count / 3 | 按官方页面请求进一步核对 | count:number；本次未验证非空相册列表与写入 |
| `SYNO.Foto.Browse.Category` | get / 3 | 无 | list:[{id:string}] |
| `SYNO.Foto.Search.Filter` | list / 3 | additional=["thumbnail"]、setting:按筛选项启用的 object | item_type、time、person、geocoding、rating 等数组；复杂组合筛选执行待验证 |
| `SYNO.Foto.Search.Search` | get_search_timeline / 2 | timeline_group_unit="day"、keyword:string | section 时间分组；合成关键词经官方 UI 搜索，成功响应已核对 |
| `SYNO.Foto.Search.Search` | list_item / 1 | keyword、offset、limit、start_time、end_time、additional 同时间线 | list:[媒体项目]；使用合成关键词观察到非空成功响应 |

媒体项目：`id:number,filename:string,filesize:number,time:number,indexed_time:number,owner_user_id:number,folder_id:number,type:string,additional:object`。已观察类型 `photo/video/live`，不能按同名文件猜测 Live Photo 组合。

`additional` 请求值：时间线 `["thumbnail","resolution","orientation","video_convert","video_meta","address"]`；文件夹列表不请求 address。观察到 `resolution:{width,height}`、`orientation:number`、`orientation_original:number`、`thumbnail:{unit_id:number,cache_key:string,m:string,xl:string,preview:string,sm:string}`。媒体路径和真实元数据不进入 fixture。

缩略图：官方 GET `/synofoto/api/v2/p/Thumbnail/get`；id:number、cache_key:string、type="unit"、size="m"。此路由已观察，但 App 自身会话的请求头认证方式未验证，不能把网页 URL 中的会话参数照搬到 App。其他尺寸、共享空间路由、原件下载和播放尚未验证。

## 权限、错误与降级

- 本次 Photos `team_space_permission=none`；即使 DSM `is_admin=true` 也不得启用共享空间。正向授权枚举、共享空间成功读取需要独立证据。
- `SYNO.FotoTeam.*` 在能力发现中存在，只能视为已观察声明，不能提升为共享空间读取通过。
- 套件缺失、权限不足、字段缺失或版本不兼容时提示无法访问照片，其他模块继续使用；不回退 File Station 照片扫描。
- 错误码专项语义未验证，先复用现有通用会话/网络错误映射，不编造套件错误码。
- 空页为有效空结果；不能恢复旧照片。满页继续分页，使用原始返回数量推进 offset。
- 所有内部写入口保持关闭，直到完成明确版本、权限、确认、防重复和最终状态回读的受控验证。

## 实现与验证

- 2026-09-19 macOS 1.0.9 用户反馈修正：原件网络参数不变，中间文件改放应用临时区，
  已校验内容通过系统替换目录/文件协调保存，不要求所选文件旁任意临时文件的权限。
  Repository 无覆盖契约保留；Mac 保存面板确认替换后由界面层显式安全导出。
  Swift/沙盒实际行为待 Mac 验证，不新增原件或删除接口的环境证据。

- Apple 领域：`apple/Packages/DsmCore/Sources/SynologyPhotos.swift`。
- Apple 只读适配：`apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift`。
- 合成测试：`apple/Packages/DsmNetwork/Tests/SynologyPhotosRepositoryTests.swift`；测试样本完全合成，不来源于用户媒体。
- 五端影响与清理顺序：[当前照片计划](../../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。
- Android/Windows 与 Apple 界面尚未切换，不称为替换已完成。已有旧代码须在引用全部迁移后清理。
- macOS 新页面与分页状态源码已建立，主题复用现有颜色资源、文案双语；尚未接入正式入口或完成视觉验收。
- `PENDING_USER_VALIDATION`：App 会话、其他权限与共享空间、其他版本；前置条件与回传脱敏要求见替换账本。

## 2026-09-09 相册、根目录与媒体读取补充

- 官方前端静态资源明确根目录初始化为 `Browse.Folder.get(name="/")`，v2。本轮按该读取方法做同源只读请求，成功返回真实根 ID 与 `additional.access_permission.view`；没有使用硬编码 ID。
- `Browse.Album.list` v4：offset、limit、category="normal_share_with_me"、additional=["thumbnail","sharing_info"]。同源只读请求成功，当前账号返回空相册；非空元素字段及相册内容参数仍只有官方静态实现与合成测试证据，不标为非空实机通过。
- 相册内容使用 `SYNO.Foto.Browse.Item.list` v4，album_id:number、sort_by="takentime"、sort_direction、additional=["thumbnail","resolution","orientation","video_convert","video_meta","provider_user_id"]。不得按目录名或同名文件猜测相册关系。
- 官方照片／视频预览实际发出 `Browse.Item.get` v5：id 为数字数组。成功响应仍是 `data.list`，补充 description、exif.camera、video_meta.duration 等字段。大图采用已观察的缩略图路由，size="xl"。
- 先前观察到的视频 GET `/webapi/entry.cgi` 使用 `SYNO.Foto.Streaming`、method=streaming、version=2、id:number、type="item"、quality="high"、use_mov=true；这只适用于存在对应转换版本的项目，不能作为所有视频的固定选源规则。App 复用现有媒体播放器、分段读取和证书／同源重定向校验，不使用 File Station URL。
- 2026-09-10 MP4 排查：两个目标 video_convert=[]，固定 high 返回 404/text/html；Download v2、item_id:[同一项目ID] 的有界 Range 请求返回 206/video/mp4。能播放的 MOV 提供 high 转换版。已修正 App 选源，见下一节；原件 GET 用于播放器，不保存完整视频到磁盘或新增写接口。
- 原件读取的官方静态调用为 `SYNO.Foto.Download.download` v2，item_id 数字数组、force_download=true、download_type="source"。按相同参数做最小 Range 请求，响应 206、application/force-download、含 Content-Range；检查头部后取消正文，不保存真实原件。完整字节传输尚待 App 实机验收。
- App 原件保存使用随机临时文件、状态和字节数检查、无覆盖提升，失败清理本次临时文件；JSON、HTML、ZIP 不作为单张原件成功保存。Live Photo 的组合原件下载未验证，可能被此检查拒绝；动态预览保留套件视频流入口供用户验证。
- 本轮没有调用创建、修改、删除或分享写接口；只读补验与官方自然请求观察分别记录。浏览器临时原始数据已在观察结束后清理。
- macOS 已接入能力发现、登录组合根、Workspace 页面与侧栏；现有套件不可用提示不回退旧照片扫描。共享空间仍未开放，其他平台尚未迁移。

## 2026-09-10 用户反馈补充

证据：[本轮环境记录](../environments/2026-09-10-photos-filter-share-observation.md)。本轮新增只读能力，不提升分享写入等级。

| 能力 | API / 方法 / 版本 | 参数与结果 |
| --- | --- | --- |
| 系统分类 | Browse.Category / get / 3 | list[].id 为 recently_added/person/concept/geocoding/general_tag/video；与普通 Album.list 分开 |
| 筛选候选 | Search.Filter / list / 3 | setting object；person 数组；geocoding 为含 id/name/level/children 的树 |
| 筛选时间轴 | Browse.Timeline / get_with_filter / 3 | timeline_group_unit="day"，item_type:[0或1]、person:[id]+person_policy="or"、geocoding:[id]、rating:[0到5]、time:[{start_time,end_time}] |
| 筛选照片 | Browse.Item / list_with_filter / 2 | 上述条件加 offset/limit/additional；条件送到 Photos，不在本地截断已加载结果 |
| 主题分类内容 | Browse.Timeline.get v5 / Browse.Item.list v4 | concept_id:number；照片列表另带 start_time/end_time |
| 标签分类内容 | 相同时间轴／照片列表 | general_tag_id 字段仅有官方静态前端线索，当前无非空标签样本，待验证 |
| 与我共享 | Sharing.Misc / list_shared_with_me_album / 2 | offset/limit/additional=["sharing_info","thumbnail","access_permission"]；本次 list 为空 |
| 与他人共享 | Browse.Album / list / 4 | category="shared"、offset/limit/additional；本次 list 为空 |
| 照片请求 | PhotoRequest / list / 1 | offset/limit；空成功响应已验证；非空 passphrase/subject/sharing_link 字段来自官方静态映射 |
| 实况视频单元 | Browse.Unit / get / 1 | id_item:[照片ID]，additional=["orientation","resolution","thumbnail","video_meta","video_convert"]；校验返回 id_item，选唯一 live_type="video" 单元 |
| 实况播放 | Streaming / streaming / 2 或 Download / download / 2 | 存在转换版才请求对应 quality；无转换版使用 unit_id:[视频单元ID] 读取原件，不复用主照片或照片缩略图单元 ID |

客户端共享页只实现三个读取页签、打开已有共享相册和复制服务器提供的照片请求链接；不猜测普通共享相册链接字段，不创建或修改公开访问权限。链接只在内存保留，非 HTTPS、含用户名或密码的链接不会作为可复制项。

新增共享创建、撤销和权限管理仍需要专用可恢复测试内容、明确授权、一次提交与结果回读；本轮没有实现或启用这些写入口。非空共享相册／照片请求和标签内容仍为 PENDING_USER_VALIDATION。

## 2026-09-10 后续修正：共享排序与完整标准筛选

- 与他人共享的 Album.list v4 必须包含 sort_by="share_modify_time"、sort_direction="desc"。同一会话对照：缺少排序返回 120，错误参数名 sort_by；补齐排序返回成功。去掉 additional.access_permission 但不补排序仍失败，不能把额外权限字段当成根因。
- 客户端与他人共享采用 additional=["thumbnail","sharing_info"]；与我共享继续使用独立 Misc 方法及 access_permission。
- 标准筛选补全 camera/lens/iso/aperture/general_tag 的数字 ID 数组，general_tag_policy="or"；focal_length_group 为 [{start:Int,end:Int}]，exposure_time_group 为 [{start:{num:Int,den:Int},end:{num:Int,den:Int}}]。候选显示名称仅用于界面，不发送翻译后的文本。
- 扩展 Search.Filter.list v3 的 setting 请求上述字段；真实响应已核对 id/name 与整数／分数结构，相机、镜头、ISO、光圈、焦距与曝光组合请求返回成功。分数分母必须大于零，零端点作为开放范围边界保留。
- 筛选 UI 对齐官方标准设置的 12 类条件。flash 虽出现在候选响应，但官方设置代码明确排除；concept/folder_filter 未有可用候选，不扩张为虚构过滤条件。
- 筛选候选错误在筛选面板内显示与重试，不再改变照片／共享主列表的错误状态。

## 视频选源修正（2026-09-10）

- 普通视频播放前读取 Item.get v5 的 video_convert；实况读取选定视频 Unit 的同名字段。仅对返回的同一项目／唯一视频单元构造播放请求。
- 转换质量按官方已知顺序 raw、orig_h264、high、medium、low、mobile 选择，但必须实际出现在列表中；raw 或没有可选转换版时使用 Download v2 原件读取，不再猜测 high 存在。
- 普通原件使用 item_id 数组，实况原件使用 unit_id 数组；不添加 force_download，不请求组合 ZIP。保留真实文件扩展名，响应 MIME 仍由安全播放器优先识别。转换流沿用 use_mov=true。
- 规则与文件扩展名无关，合成测试覆盖 MP4、MOV、M4V、MKV、AVI、WebM、FLV、MTS 无转换版、仅中／低清版本及实况视频。测试证明选源而非所有编码可解码；系统不支持的原件仍提示重试／下载后其他应用打开，不误导重新登录。
- 五端影响：共享 Apple 网络实现新增私有响应字段解码并运行 macOS 回归，iPhone/iPad 现有照片入口未迁移；Android／Windows 后续按相同契约选源，本轮代码不变。凭据 Header、TLS、同源重定向、Range 和错误拒绝规则不变。
- PENDING_USER_VALIDATION：测试包中重试原问题 MP4、原先可用 MOV、实况及其他自有测试视频，检查播放、暂停与拖动；不同编码、设备和 NAS 版本仍需实际反馈，不用合成请求测试替代。


### 2026-09-29 共享分类与来源补充静态证据

同一官方react_bundle.js版本表中，Foto与FotoTeam共用Person（list/get/count/set/show等v1、merge v2、add_face v3）、Concept（list/get/count v2）、Geocoding/GeneralTag（list/get/count v1）、Item.list v4、RecentlyAdded.list v1。类别路由明确把人物/地点/标签/主题/视频/最近添加分别映射到当前命名空间的这些接口；共享人脸保存明确传FotoTeam.Browse.Person、FotoTeam.Browse.Item、FotoTeam.Upload.Face。候选尚未接入客户端共享分类/人物，不得将已有个人流程当作共享实现。

分类入口本身是统一的Foto.Browse.Category.get v3，官方FotoTeam版本表没有Category或Album/NormalAlbum/ConditionAlbum，不能仅替换前缀构造共享相册接口。分类卡片预览先取个人list（offset0/limit4/additional thumbnail，人物show_more=true）；个人不可用或列表为空时，只有team_space_permission=management才读共享对应list，并分别附带library=personal_space/shared_space。人物/主题/相似项目还检查team_setting.enable_person/enable_concept/enable_similar，默认false；读取卡片来源后后续照片/缩略图继续带同一library。此处个人优先是卡片预览策略，不等于禁止进入共享完整列表。共享入口、选择器和完整列表参数仍需按各调用方继续补齐；未因本次静态线索宣称实机权限兼容。

只读脚本观察，没有请求照片API或触发写入；临时变量已删除、控制台清空并关闭。环境未知项沿2026-09-28-photos-parity-observation.md，不提升verifications。

### 2026-09-29 共享分类读取实现

Apple服务新增categories(in:)/categoryItems(_:in:offset:limit:)/categoryTimeline(_:id:in:)重载，旧方法继续走个人空间；SynologyPhotoCollection增加默认personal的space，不涉及序列化或持久化迁移。Repository发现FotoTeam.Person/Concept/Geocoding，沿统一Foto.Category.get v3发现入口；共享全局列表须management，Person/Concept分别检查enable_person/enable_concept与实际版本能力。entry的文件夹、已授权照片查询和既有筛选能力保持可用，不把分类卡片策略扩大成照片查询禁令。

人物、主题、地点、标签列表分别沿当前空间对应API；日期使用同空间Timeline v5，照片沿Item已有路由。分类封面缓存按space/category/id隔离，人物unit/person缩略图类型也按space/id隔离，读取走p/t对应路径，重新核对权限清空旧封面授权。macOS相册页新增空间选择，分类进入/返回/分页固定来源，权限撤回清空旧分类，entry显示文件夹下一步。普通相册仍沿个人入口，未构造FotoTeam.Album；共享相册来源、条件源和人物写管理属于后续切片。证据等级维持static，真实环境PENDING_USER_VALIDATION。

### 2026-09-29 相册项目来源补充

同一环境的官方react_bundle.js静态复核：相册照片统一Foto.Browse.Item.list，参数album_id、offset/limit、sort_by/sort_direction及additional thumbnail/resolution/orientation/video_convert/video_meta/provider_user_id。官方按owner_user_id=0分组为共享，正数为个人；选中混合项目按两种来源分组。缩略图帮助函数携带album_id，统一相册上下文不等同于个人照片来源。

客户端相册列表在个人/共享分类入口共用；照片读取保留每项owner来源，后续详情、缩略图和原件继续使用其真实空间。相册查询允许已授权的两种来源，非相册查询保持严格同空间校验。相册项目缺少owner或为负值时明确报读取错误，不把未知来源猜成个人；共享照片需要已获该空间访问权限。封面先回读当前相册，再附album_id读取统一缩略图；个人空间关闭不再单独阻断相册列表和封面。此范围不声明他人分享给我但无原空间访问权限的项目完整对齐，该协作权限仍待补齐。无真实照片或响应保存，static等级不变。


### 2026-09-29 相册上下文读取

在同一观察环境的官方静态脚本中重新确认：Item.get v5使用id数组并携带album_id，详情additional增加provider_user_id；Unit.get v1使用id_item数组、album_id；缩略图帮助函数传入album_id；Streaming的id/type/quality及Download的item_id或unit_id均保留album_id。Download帮助函数明确把相册场景切换至统一Foto入口。官方也支持passphrase分支，本轮已登录会话采用album_id，不暴露分享凭据。分享权限由Foto.Sharing.Passphrase.getPermission(passphrase,exclude_public)取得permission.download/upload，这是下一协作权限切片的static线索，当前尚未接入该读接口。

本轮替代上节“后续媒体沿原空间”和“需源空间权限”的限制：SynologyPhoto新增可选albumContext(albumID,ownerUserID)，相册内容始终经统一Foto的Item/Unit/Thumbnail/Streaming/Download读取，并附原相册编号。owner只保留来源身份，不用作相册读取权限；启用Photos但没有个人/共享空间的账号仍可请求其有权相册和共享列表，NAS逐次判断成员及权限，拒绝后不降级至原件接口。普通时间线/目录读取不变。详情保持上下文并校验owner未变化，授权刷新后在途结果丢弃；缩略图视图重载键包括上下文，防止同一项目切换相册时沿用旧请求。

原件写入口继续核对空间和目录权限，带相册上下文的他人个人照片不能按本人原件执行删除/修改。相册协作添加/上传与下载按钮的角色显示仍需下一切片，不把能发起相册请求等同已实现全部协作。证据仅static及合成测试，真实NAS响应、下载受限角色、所有DSM/Photos版本均PENDING_USER_VALIDATION；无新增真实写操作或用户资料留存。

### 2026-09-30 分类拼图与相似项目静态复核

同一官方脚本再次确认Category.get v3返回的每类卡片读取offset=0、limit=4、additional=[thumbnail]；人物另传show_more=true（不传show_hidden），视频使用Item.list v4和字符串type=video，最近添加使用RecentlyAdded.list v1。其他分类复用各自list版本。人物保留person/unit封面区别，其他用unit；网页先个人、空列表时在共享management及对应设置启用的条件下读取共享。原生已有显式分类空间选择，拼图固定所选空间，与点击后完整列表来源一致。只读封面失败不阻断打开分类；卡片读取不清空完整分类列表授权缓存。

额外候选范围：Foto/FotoTeam.Browse.Similar含get_status/ungroup/add_item/set_top_pick/get/remove_item v1；SimilarItem含list/list_with_filter/list_similar/get/count_with_filter与对应basic_timeline_info v1；SimilarTimeline含get/get_with_filter/get_similar v1。分类预览相似项使用list_similar；完整时间线分别get_similar/list_similar，普通聚合时间线使用get/list；状态模型读取similar.id/count/top_pick/items/current_pick，set_top_pick请求id（组）与item_id（照片）。完整响应、分组写回读及当前NAS入口未验证，不能据此宣称已实现相似项。证据static，不新增真实写验证；调试变量已删除并确认undefined，控制台清空、DevTools关闭。


## 2026-09-30 压缩JPEG下载

同一观察环境官方静态脚本：Download.download v2支持download_type=source/optimized_jpeg，item_id为整数数组、force_download=true；按照片来源路由Foto/FotoTeam，相册场景统一Foto并携带album_id（官方另有passphrase分支，登录客户端保留albumContext）。压缩结果可能仍是原格式，官方批量提示明确这一点；不推测照片转换尺寸或质量。单项视频/GIF/WebP不提供压缩菜单，混合批量支持原格式保留。相似主列表下载展开组内所有成员，预览内下载只针对当前照片。

Apple增量SynologyPhotoDownloadFormat及download(format:)返回实际保存格式；旧Adapter默认原件委托downloadOriginal，压缩显式unsupported，原件方法和大小校验保持兼容。Repository用同一下载临时文件及无覆盖提升流程：200成功，拒绝JSON/HTML/ZIP；压缩内容有Content-Length时核对完整大小，JPEG通过ImageIO完整性/格式检查；返回非JPEG时必须匹配原件大小，保留原后缀，不把视频/其他原格式伪装为JPEG。源照片、相册上下文和授权代次沿既有校验，取消不提升文件。

macOS批量工具栏、照片右键和预览增加原件/压缩JPEG菜单，压缩保存选择目录后按实际格式命名；同名自动另存，不能覆盖，部分失败显示完成数量；保留原格式的数量在完成提示说明。相似组批量先读取全部成员并去重，保持月份和选择。没有NAS原件写入、持久化或第三方依赖。macOS接入；iPhone/iPad共享协议向后兼容但无新UI，Android/Windows仅同步未来语义。本轮真实NAS下载未验证，证据static，不能用合成JPEG测试提升NAS兼容结论。

PENDING_USER_VALIDATION：在个人/共享及仅相册可访问的来源分别保存压缩照片，确认JPEG可打开、原件不变；混合视频批量检查原格式保留及提示；已有同名文件应另存，相似组应保存全部成员并保持月份。断网或权限撤回不能得到伪成功文件。回传文件类型、包版本、步骤及脱敏提示，不附真实媒体/地址/凭据。

新发现待办：original_size_jpeg需先Download.convert v2；Browse.Album.download整册、文件夹整目录下载及幻灯片入口尚未接入，不能将本轮单张/所选下载等同全部网页下载。


## 2026-09-30 整相册与目录归档下载

同一官方脚本静态核对：`SYNO.Foto.Browse.Album.download v2`以`id`整数（所有者）或`passphrase`字符串（协作成员）选择完整相册，并传`download_type=source/optimized_jpeg`；普通和条件相册共用此方法。目录使用`SYNO.Foto.Download`或`SYNO.FotoTeam.Download v2`，`folder_id`为整数数组、`force_download=true`、相同download_type；不是当前已加载item_id的替代集合。路径来自API.Info能力发现，通常`/webapi/entry.cgi`。官方隐藏表单明确使用POST，数组JSON编码、passphrase按JSON字符串编码。响应为ZIP附件，不能按单张原件解码。压缩JPEG不能转换的项目仍保留原格式。

Apple新增`SynologyPhotoArchiveTarget.album(id)/folder(id,space)`及`downloadArchive`，默认实现unsupported以保持旧Adapter源码兼容。相册先Album.get v4核对身份；本人所有返回下载许可，协作成员以Passphrase.get_permission v1核对download，不将upload当下载权。相册统一Foto且不要求原空间开启。目录先Folder.get v2核对id/access_permission；个人目录要求view且download不为显式false，共享entry要求view/download均true，共享management沿已记录管理权限。权限刷新代次变化拒绝在途结果。passphrase只放POST体，不进入URL或日志。

仅本机导出，无NAS写操作。临时文件检查HTTP200、非JSON/HTML、可选Content-Length和ZIP首标识/标准结束记录，再协调导出；最多读取末尾65557字节，不解压或一次读完整相册。检查不等于逐文件CRC验证，真实大归档/ZIP64与内容完整性仍待用户测试。Repository拒绝覆盖既存目标，macOS只在系统保存面板确认后替换本地目标；失败与取消不修改旧文件。无权限/不支持直接说明失败，不回退扫描原件或File Station。

macOS当前集合工具栏与相册/目录右键提供原件ZIP、压缩JPEG ZIP和取消；不刷新图库或改变月份。协议增量影响iPhone/iPad共享包但无新增UI；Android/Windows只记录等价语义，无代码修改。没有存储/签名/依赖变更，回滚可独立移除本轮目标/方法/菜单。证据仍static，当前环境版本未知，不填虚构verifications。自动化位于SynologyPhotosRepositoryTests、SynologyPhotosModelTests、WorkspacePresentationTests，实际运行结果见本轮Photos对齐账本。

PENDING_USER_VALIDATION：使用测试相册（含条件/协作）和个人/共享目录保存两种ZIP；解压核对完整范围、原格式保留、取消/断网不覆盖现有目标，下载受限成员不能以贡献权限下载。回传版本、空间、步骤与脱敏提示，不含真实照片/地址/凭据。


## 2026-09-30 幻灯片播放语义

沿同一环境已加载官方脚本核对：全屏照片3秒计时，视频结束后推进；空格暂停/继续，左右切换，repeat=true，停止/退出全屏结束carousel。时间线、目录、相册与分类入口复用lightbox，查看角色也有幻灯片，不把下载权当预览权。原生使用独立NSWindow全屏，不改变主窗口全屏状态；保持原查询/空间，以独立分页游标按需补读，当前图库月份和选择不变；相似组内预览固定组成员。无新API或NAS写操作，媒体继续现有只读授权与错误语义，不改变内部接口证据等级。静态线索和合成测试不代表真实NAS/屏幕验收。


原尺寸JPEG候选静态补证：Download.convert v2先传单个item_id整数，按上下文附album_id或passphrase；转换成功再调用download_type=original_size_jpeg下载。单选照片的菜单还受hasHevc与enableConvertedOriginalJpeg实际标记约束，类型判断包含TIFF及RAW扩展arw/srf/sr2/dcr/k25/kdc/cr2/cr3/crw/nef/mrw/ptx/pef/raf/3fr/erf/mef/mos/orf/rw2/dng/x3f/raw，另有yh判定分支尚待完整核实。相册下载统一Foto，所有者album_id、协作者passphrase；其他来源沿Foto/FotoTeam。尚未核全标记来自哪个响应、转换返回结构和转换中的取消/重试副作用，因此保留下一契约切片，未写产品代码或触发真实转换。无持久调试变量、未保存原始脚本；控制台清空、DevTools关闭。


## 2026-09-30 原尺寸JPEG转换下载

继续核对同一环境的官方静态脚本（仅读取已加载资源，未执行真实转换/下载）：Setting.User.get v1返回可选ame_status.has_hevc，Setting.Admin.get v1返回可选enable_converted_original_jpeg。下载菜单在单选且两项为true时提供原尺寸JPEG；缺字段按实际能力不可用处理，不因未实测增加人工禁用。

格式为HEIC/HEIF/HIF照片（官方照片类型含photo/photo360/burst/motion_photo，实况照片亦可判定），以及TIFF和RAW扩展tif/tiff/arw/srf/sr2/dcr/k25/kdc/cr2/cr3/crw/nef/mrw/ptx/pef/raf/3fr/erf/mef/mos/orf/rw2/dng/x3f/raw。此项只适用单张，不能用于整册/目录或相似组批量。前段yh与设置来源未知的候选记录由本段补全；不改变历史证据等级。

Download.convert v2使用POST，item_id为单个整数；个人/共享原空间分别Foto/Fototeam，相册统一Foto，当前账号为相册所有者传album_id，否则按相册实际下载权限传passphrase。官方代码只消费转换成功信封，不读取额外data字段；成功后Download.download v2，item_id数组、force_download=true、download_type=original_size_jpeg。原生转换/下载均用请求体传递相册口令。这里的转换可能生成NAS派生缓存，不修改原件，因此机器索引标为mixed，不能称为纯读取；实际缓存副作用、长转换耗时和取消行为仍未验证。

原生实现先核对最新照片身份、相册或目录下载权、会话代次与v2实际能力；同照片在途去重，失败不自动重放convert，取消停止后续请求及本地保存（不能承诺撤回NAS已接收的转换）。下载结果须是ImageIO可完整解码的JPEG，不能回退原件却标记原尺寸JPEG；临时文件校验后另存，不覆盖现存文件。没有修改NAS设置、原件格式或本地持久化结构。

证据static；仅合成请求/结果测试，不提升为read-verified或behavior-verified。PENDING_USER_VALIDATION：实际NAS开启原尺寸JPEG、HEVC解码可用，选择HEIC/TIFF/RAW逐张下载；确认JPEG分辨率与旋转、原件不变、协作/共享权限正确，断网或取消不会生成损坏目标，同名另存。回传版本、格式、入口/空间、动作和脱敏失败提示，不提供真实媒体或凭据。

补充角色边界：协作相册延续既有本人贡献下载语义；原空间开启且最新Item.get additional.provider_user_id确认为当前账号时，允许下载本人贡献，即使相册不给其他成员下载权。身份核对仍走原album_id，不回退原空间绕过拒绝；旧提供者信息不作为授权。该路径已加入合成回归。


### 文件夹封面读取（2026-09-30）

官方脚本static：Foto/FotoTeam.Browse.Folder v2 get/list 的additional.thumbnail是数组，默认封面条目包含unit_id/cache_key，自定义封面条目包含folder_cover_seq/cache_key。默认图沿对应空间Thumbnail/get读取type=unit、id=unit_id、size=m；自定义图使用type=folder、id=目录编号、folder_cover_seq、cache_key，不传size。个人与共享分别使用/synofoto/api/v2/p/Thumbnail/get、/synofoto/api/v2/t/Thumbnail/get。

macOS目录卡片最多显示四张；先按固定空间和目录重新核对查看权限，单图失败保留占位，不阻断打开目录。空间、目录和封面修订组成视图任务身份；取消/旧权限不能回填图片。设置写端点及成功判断见photos-management.md的文件夹封面记录。仅静态证据与合成验证，不注册实际版本兼容，不保存真实图像到仓库。


### 封面选图排序候选（2026-09-30，后续切片）

同一官方脚本的封面选择器使用目录排序菜单，选中照片时菜单禁用；四项为名称/大小/类型/拍摄时间，对应filename/filesize/item_type/takentime，方向asc/desc。切换动作携带当前目录id、sortBy和sortDirection，并分个人/共享FolderAPI和ItemAPI重读，不是只重排当前页。该静态候选已确认菜单与枚举，但完整分页worker、默认排序及是否保存目录偏好仍需核对；本轮不发送排序写请求，也不把候选作为已接入能力。静态脚本仅在控制台临时查看，输出清空、开发工具关闭。


### 文件夹排序保存与读取（2026-09-30）

内部Foto/FotoTeam.Browse.Folder.set_order v1，POST /webapi/entry.cgi，参数id、sort_by、sort_direction；不是只读本地排序。官方封面选择器先保存再重读目录照片，打开目录读取Folder.get v2的sort_by/sort_direction。名称filename、大小filesize、类型item_type、拍摄时间takentime，方向asc/desc；每个缺失或未知字段独立回退Setting.User.get v1的item_sort_by/sort_direction，官方缺省takentime/asc。子目录Folder.list v2始终filename并沿同一方向；照片Item.list v4使用所选字段/方向和原目录/空间/offset/limit，每页100。

排序是浏览偏好，官方入口基于可查看目录；原生先重新核对固定目录id/已知路径和view，不能因没有原件管理或下载权而阻止排序。保存采用既有操作编号去重、权限代次保护及自动结果核对，回执丢失只读重查；必须回读两个明确字段均匹配，不能用默认值拼成成功，也不重放。已选照片时排序菜单禁用，取消选择后可继续；设置封面仍独立要求管理权。

新增SynologyPhotoSort及folder查询的可选默认排序参数、集合可选sort、folderSort读取、folders方向重载和setFolderSort命令。旧调用仍为takentime/asc，旧目录读取重载仅兼容升序；无实现的新能力显式unsupported，不伪造降序。macOS封面选择器每次进目录沿已保存顺序，保存后重置其分页；同一主图库目录同步重排，留在原目录并保持照片选择ID；修改子目录不重排父目录。排序加载/保存时避免重复动作，旧请求以加载编号/代次隔离，失败可重试。所有枚举为稳定协议值，翻译不参与请求。

证据static：只读官方react_bundle.js的封面选择器、ChangeEmbededSorting worker、Folder方法版本表、默认设置及照片/子目录读取；没有真实NAS保存排序、读取用户排序值或导出会话。当前环境版本沿既有未验证记录，verifications不新增。兼容与用户验收PENDING_USER_VALIDATION；用户已授权契约扩展，不新增本地存储、依赖、标识或其他端UI。


### 2026-09-30 多目录与照片混选归档下载

官方静态资源的统一下载流程接受同一目录所选照片及文件夹，Download.download v2通过POST同时传入非空item_id、folder_id数组、force_download=true及download_type=source/optimized_jpeg；个人/共享使用对应Foto/FotoTeam路由，不加入相册上下文。目录包含完整后代，不从当前已加载照片拼装ZIP；照片单独多选的既有逐文件保存保留。

共享Apple枚举SynologyPhotoArchiveTarget增量增加selection(photos,folders)，要求至少一个文件夹、同一父目录/空间及固定照片快照。Repository逐目录回读身份/下载权，并按每批100项回读照片身份，全部通过后只提交一次归档请求；不因任一项失败改下载其余项目。接续既有取消、授权代次、有限读取ZIP结束记录校验、暂存与原子导出。macOS工具栏及已选文件夹/照片右键均下载整组选项，NSSavePanel开启时固定目标，取消和失败保留旧本地文件，图库位置与选择不刷新。

证据为static，未在真实NAS执行下载，不新增环境verifications或提升兼容等级。PENDING_USER_VALIDATION：个人与共享空间分别选择两个含后代文件的目录，再混选同级照片，验证原件/压缩JPEG的ZIP内容完整、权限拒绝可理解、取消不改旧文件且不跳回最新月份；反馈脱敏错误提示、选择数量和格式，不提供私有路径/凭据。接口拒绝直接提示失败，不使用File Station或另一空间绕过。


## 2026-10-01 上传任务位置导航（既有只读端点复用）

Shared Serving增量folder(id:in:)映射既有`SYNO.Foto[Team].Browse.Folder`、`POST /webapi/entry.cgi`、version 2、method get，id为正整数，additional为thumbnail/access_permission。回读folder.id必须一致，访问代次不变，view=true或共享空间management角色；个人目录不可借共享角色绕过权限。返回id/name/parent/path/space，名称由当前响应解析，不从任务显示名推测。

macOS从已确认上传照片的details回读folder_id，再沿parent逐层读取至根目录；拒绝重复编号、错空间/错编号和无读取权。位置或权限预检失败不切换原页面，进入目录后的加载失败显示可重试错误；迟到结果不覆盖新导航。直接相册上传仅提供相册入口。没有新增NAS写入、版本证据或真实NAS验证，沿本文件既有static等级；合成测试与后续用户验收分开记录。未知上传回执不允许以任务移除丢弃核对状态。
