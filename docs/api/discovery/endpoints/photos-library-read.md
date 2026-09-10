# Synology Photos 照片库只读接口

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
