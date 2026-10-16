# Synology Photos 图库与媒体

稳定标识 `photos-library-read`；internal，隐私风险high；大部分为读取，原尺寸JPEG的convert会生成派生缓存，属于mixed。早期标识 `photos-internal-candidate` 仅保留历史定位，不是另一个适配器。现行图库不回退File Station，不构造不存在的FotoTeam.Browse.Album。

[证据索引](../environments/INDEX.md)区分09-09/10个人读取、09-28起静态共享/相册、10-16 Windows读取回归。设备归属未知不冒用lab-a；单个方法读取成功不证明其他方法、平台或权限通过。

## 访问、编码与分页

UserInfo.enabled、User.enable_home_service及TeamSpace.enabled和team_space_permission分别判断；none无共享访问，entry依目录view/download/upload/manage，management仅共享范围生效，DSM is_admin不能代替Photos角色。刷新授权使旧在途结果失效，缺能力只影响相关功能，拒绝不能伪造为空或回退其他空间。

API.Info声明entry.cgi/JSON，POST表单内业务字符串和数组按JSON值编码。官方请求可使用/webapi/entry.cgi/<API名>；实际路径按能力发现。会话秘密不进入普通媒体URL。空页合法，满页继续；offset按原始返回数推进，不能按客户端筛选后数量推进。

## 基础读取

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

## 分类与筛选

Category.get v3统一Foto，分类有recently_added/person/concept/geocoding/general_tag/video；普通Album空不代表分类不存在。FotoTeam复用Person/Concept/Geocoding/GeneralTag/RecentlyAdded与Item版本，**不含Category或Album/NormalAlbum/ConditionAlbum**。分类空间与后续列表一致；卡片offset=0/limit=4/additional=[thumbnail]，人物show_more=true，视频Item.list v4(type=video)。

Timeline.get_with_filter v3、Item.list_with_filter v2：timeline_group_unit=day；item_type=[0或1]、person数组+person_policy=or、geocoding数组、rating=[0…5]、time=[{start_time,end_time}]，项目另加offset/limit/additional。camera/lens/iso/aperture/general_tag为数字ID数组，general_tag_policy=or；focal_length_group=[{start:Int,end:Int}]；exposure_time_group=[{start:{num,den},end:{num,den}}]，分母>0，零端点是开放边界。候选名称不参与请求。flash虽出现但官方标准过滤器排除，不猜编码；未取得可用concept/folder_filter候选不造选项。筛选失败不清空主列表。

主题Item/Timeline可传concept_id；标签general_tag_id等非空样本的覆盖见环境记录。相似专用get_similar/list_similar与分组规则见[相似照片](photos-similar-items.md)，不与普通聚合时间线混用。

## 相册、分享与上下文

Album.list v4(offset/limit,category=normal_share_with_me,additional=[thumbnail,sharing_info])；与我共享使用Sharing.Misc.list_shared_with_me_album v2并取access_permission；与他人共享Album.list v4(category=shared,sort_by=share_modify_time,sort_direction=desc)。缺排序曾返回120/sort_by/condition，不能误归因于access_permission。PhotoRequest.list v1(offset/limit)的空成功与非空字段证据分开。

相册Item.list v4统一Foto：album_id、分页/排序、additional=[thumbnail,resolution,orientation,video_convert,video_meta,provider_user_id]。owner_user_id=0共享、正数个人，未知不能猜；owner是来源身份，**不替代相册访问权**。相册上下文的Item.get v5、Unit.get v1、Thumbnail、Streaming及Download始终统一Foto并携原album_id。个人/共享原空间关闭仍可访问本人被授予的相册；拒绝后不退回原件接口。原件修改仍独立检查真实来源与权限，provider/协作规则见[高级管理](photos-advanced-management.md)。

## 缩略图与视频

个人路由/synofoto/api/v2/p/Thumbnail/get，共享为/t/Thumbnail/get；id/cache_key/type/size，其中普通unit使用m或xl等实际可用尺寸。相册统一个人路由并带album_id。人物封面有unit_id用type=unit，否则type=person；人脸type=face且无size。

Folder.get/list v2 additional.thumbnail为数组：默认unit_id/cache_key，自定义folder_cover_seq/cache_key。默认type=unit/id=unit_id/size=m，自定义type=folder/id=目录/folder_cover_seq/cache_key且不传size。先核对目录view；单图失败不阻断目录。排序/封面保存只维护于[管理定义](photos-management.md)。

Item.get v5提供video_convert；实况先Unit.get v1(id_item数组,additional=[orientation,resolution,thumbnail,video_meta,video_convert])，核对id_item并选唯一live_type=video单元。不能用主照片ID或缩略图ID替代视频单元。

存在实际转换档位才用Streaming.streaming v2(id,type=item/unit,quality,use_mov=true)，已知质量顺序raw/orig_h264/high/medium/low/mobile；raw或无转换版使用Download.download v2，普通item_id数组、实况unit_id数组。播放不加force_download，不请求组合ZIP。该选择与文件扩展名无关；无转换MP4的high曾404而原件206，不等于编码不支持。Range、响应类型、同源与证书检查继续生效。

## 原件、JPEG与归档

Download.download v2支持download_type=source/optimized_jpeg，item_id数组、force_download=true；按原来源Foto/FotoTeam，相册统一Foto并携上下文。单张视频/GIF/WebP无压缩菜单，混合输出可保留原格式；实际字节格式决定扩展名，不把原格式伪装JPEG。

单文件保存使用受保护临时文件，核对HTTP/类型/长度，拒绝JSON/HTML/ZIP错误结果，失败/取消不覆盖目标。JPEG完整解码；optimized_jpeg若仍原格式需核对原件大小。相似列表下载先完整展开成员，预览只下载当前项。

整相册Browse.Album.download v2：所有者id单整数或协作passphrase字符串，download_type=source/optimized_jpeg；普通/条件相册同法。目录Download.download v2用folder_id数组；同级混选同时用非空item_id/folder_id，至少一个目录，不从已加载照片拼完整内容。三类均POST，口令只在请求体；force_download=true仅用于目录和混选的Download.download，相册Browse.Album.download不发送该字段。逐目标固定身份/实际下载权，全部预检成功后一次请求；不因一项失败偷偷下载剩余。

归档须HTTP200、非JSON/HTML、长度一致并检查ZIP首标识及结束记录，末尾最多65557字节；这不是全文件CRC或ZIP64实机验收。取消/失败保留旧本地文件，不扫描原件或借File Station绕过权限。

原尺寸JPEG仅单张、User.ame_status.has_hevc与Admin.enable_converted_original_jpeg明确true；HEIC/HEIF/HIF及TIFF/RAW类，不扩大为整册或相似组批量。Download.convert v2 POST(item_id单整数)成功信封后，download v2(item_id数组,force_download=true,download_type=original_size_jpeg)。相册所有者album_id、其他成员按实际下载权passphrase；本人provider的额外资格须以最新相册get验证，不能绕回原空间。

convert可能产生NAS派生缓存，取消不能承诺撤回；同目标去重，不自动重发，输出必须可完整解码为JPEG，不能降回原件并误标格式。实际转换/缓存/大归档与设备编码能力仍未验证。

## 实现范围

当前平台状态见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)，目标平台与真实NAS验收条件见[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。本页只维护当前读取/导出语义，不保存逐轮构建数字或平台施工状态。
