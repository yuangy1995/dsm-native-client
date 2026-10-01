# 2026-09-28 Photos 网页对照观察

2026-09-30共享成员波次补证：仅通过已登录Chrome只读官方静态脚本，确认FolderBatchPermission v1两种按成员提交结构、check_all/uncheck_all、两层目录树及公开权限下限/父目录限制；未读取真实成员或目录，未执行NAS写入。DSM/build/Update/Photos版本仍未知，不能升级验证等级或绑定历史设备。静态结构已记录photos-shared-space-members，临时控制台输出已清空并关闭，无原始脚本落盘。

## 环境边界

| 字段 | 本轮记录 |
| --- | --- |
| 日期 | 2026-09-28；源码验证延续至 2026-09-29 |
| 来源 | 已登录 Chrome 中的官方 Synology Photos 页面、该页面加载的官方静态脚本 |
| 匿名设备归属 | 与已有 lab-a 的关系未确认；本记录不注册新的 current 基线 |
| DSM 版本 / build / Update | 未验证，不沿用历史记录 |
| Photos 完整版本 | 未验证 |
| 架构、证书类别、实际网络路径 | 未验证；仅确认 HTTPS 网页会话 |
| 权限类别 | 可读取个人照片空间；不推断管理员或管理权限 |
| 静态资源 | `/webman/3rdparty/SynologyPhotos/react_bundle.js`；只记录接口结构，不保存脚本副本 |

## 已观察范围

- 官方界面支持按天勾选、选中计数、下载原件、加入相册、编辑标签/评级/日期、移动/复制、删除、分享等入口。
- 仅勾选与取消勾选，没有上传、创建相册、修改、删除、建立分享或更改权限。
- API 名称、版本、参数及返回字段来自官方静态脚本，证据等级为 **static**。页面入口可见属于 UI 观察，不等于接口行为验证。
- 上传返回 `id/action`；移动/复制返回后台任务编号；相册和照片编辑支持按编号回读；分享弹窗本身可能创建链接，因此未通过打开分享弹窗探测接口。
- 浏览器专用连接不可用，采用 Chrome 原生无障碍入口；未导出 HAR，未导出会话。

## 相关记录

- `docs/api/discovery/endpoints/photos-management.md`
- `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`
- `contracts/private-api/compatibility.json`

## 安全与限制

未将凭据、设备地址、真实文件名、照片、路径或用户资料写入仓库。测试全部采用合成数据。静态候选不得注册为 read-verified 或 behavior-verified，不冒用旧环境 verifications。新写入口默认关闭，需要专用合成测试资料和明确环境版本后分别验证。旧的照片删除既有授权与门禁保持原语义。

## 2026-09-29 授权更新与受控验证开始

用户回复“可以，代码中不要限制禁用功能”，明确同意上一轮提出的当前 NAS 个人空间新增专用相册和少量合成图片验证范围，并要求移除新增写能力默认关闭开关。该授权取代本轮先前的默认关闭安排；权限检查、操作确认、身份校验与不重放要求仍保留。

验证只使用本轮生成的两张 160×120 纯色 PNG 与新建测试相册/目录，不修改原有照片，不创建公开分享，不删除测试资料。已通过当前页面路由确认个人空间。DSM 与 Photos 完整版本仍未从关于页面取得，不冒用历史版本。行为与参数观察的最终结果在后文逐项追加。

### 官方网页操作结果

- 两张合成 PNG 分别上传，官方任务界面均显示单项上传完成；其中一张从新建普通相册内上传。
- 新建普通相册并修改名称，刷新后名称仍在；未改动已有相册。
- 新相册内唯一的合成照片设为 4 星，官方界面显示单项评级成功。评级未单独刷新回读，不把成功提示当作持久化复验。
- 同一张合成照片的拍摄日期修改为 2020-03-15；刷新页面后相册日期显示 2020-03-15，确认日期保留。
- 标签、移动、复制、公开分享和删除未执行真实写验证；以上仅为官方网页流程结果，不代表原生客户端请求链已通过实机验收。
- 未捕获可用于契约确认的请求结构，因此端点证据仍为 static；DSM/Photos 完整版本未知，不登记版本级 behavior-verified。
- 测试相册与两张合成照片保留在 NAS；没有公开分享或删除。页面刷新后确认临时调试变量消失，开发者工具已关闭。


### 标签与日期后续波次的环境限制

2026-09-29 再次使用已绑定 Chrome 时，工具报告 Mac 已锁屏、自动解锁失败。已请求用户手动解锁，没有绕过锁屏或提取会话。继续开发只依据上述已保存的静态接口结构；未观察新请求或执行 NAS 写入，不更新版本验证等级。


### 2026-09-29 Chrome 恢复后的只读观察

Chrome 已恢复可访问，仍位于专用合成测试相册。打开官方共享设置，观察到启用共享链接、公开链接、密码保护及受邀用户权限区；取消后通过“离开”放弃未保存设置，没有点击保存或执行分享写入。只记录控件语义，不记录真实 URL、权限成员或凭据；未捕获新接口结构，版本与端点验证等级保持原状态。


### 2026-09-29 剩余管理能力静态核对

本次 Chrome 恢复可用，只读取已加载官方 react_bundle.js 的方法表、参数构造和结果使用；没有触发新写请求。补充证据见 photos-advanced-management.md。重新核实官方分享弹窗可能在打开时创建 disabled 链接，因此此前“未保存分享设置”仅证明未执行保存按钮，不能证明该弹窗未产生关闭状态链接；不将那次操作登记为纯读接口验证。版本和设备归属仍未知。


本轮静态读取结束后已删除浏览器临时 `__photosParitySource`，确认不存在并关闭开发者工具。未保存官方脚本、原始响应或用户内容；新增目录层级功能仅运行合成验证，未执行真实 NAS 写入。


### 条件相册波次静态观察

Chrome 可用时继续读取官方已加载脚本，确认相册 type、全部列表 category、condition_object 的引用转换、规则匹配策略、建议字段及地点展平规则。未发送创建/修改请求，没有打开可能产生链接的分享表单；临时源码变量已确认删除，开发者工具已关闭。未记录主机、凭据、原照片、原始脚本或真实响应，版本/环境等级保持未验证。


2026-09-29 分享状态波次：锁屏曾阻止浏览器观察，恢复后继续只读官方静态代码。确认公开权限转换不含上传，补记 encryption 条件与日期两套转换。未读取/写入真实分享成员、密码或链接，不产生新行为验证等级；环境版本缺口仍保留。临时源码变量已删除，DevTools 已关闭。


2026-09-29 分享成员波次：已读取官方前端 permission 到成员表格的映射、type/id/name/role 使用、UserInfo.uid 自己过滤及差量构造。无真实成员数据或权限写入；原始脚本临时变量删除且 DevTools 关闭。后续额外检查遇到 Mac 锁屏，未绕过。环境版本缺口与 static 等级保持不变。

2026-09-29 发布后恢复只读观察：Chrome 已恢复访问，不再沿用锁屏阻塞结论。补齐 PhotoRequest 字段投影、更新差量、清除相册使用-1（界面内部为null）、文件大小限制与本地日期末；核实密码编码中的 AES/CBC/PKCS7、OpenSSL 盐格式及 MD5 派生；确认共享空间 entry/management 权限枚举和 t 缩略图路由。详见 photos-advanced-management.md 与 photos-library-read.md。无 NAS 写操作、真实密码或共享媒体读取；版本、设备归属和行为等级仍未验证。临时源码变量删除并确认 undefined，DevTools 已关闭，无脚本文件落盘。


2026-09-29 共享上传补证：用户解锁后继续只读官方 react_bundle.js，确认 AddUploadToFolderTask / AddUploadToTimelineTask 的 TEAM_SPACE 使用 FotoTeam.Upload.Item；公共 helper 对应 upload_to_folder/upload v1，mtime 为秒，时间线目录常量 ["PhotoLibrary"]。详见 photos-management.md。没有共享空间NAS写入，版本和行为证据等级未升级；未保存脚本或用户响应。结束后删除临时源码变量并确认 undefined，关闭开发者工具。


2026-09-29 共享管理补证：只读官方前端方法表及action/helper，确认FotoTeam.Item编辑/标签、GeneralTag、BackgroundTask.File移动复制删除与统一Foto.BackgroundTask.Info状态查询。没有打开写入表单或执行NAS修改。临时源码变量删除并确认undefined，DevTools关闭；仅保存脱敏协议记录，版本/环境行为等级不变。


2026-09-29 分享密码补证：只读官方脚本确认RSA PKCS#1 v1.5、server_time偏差计算，以及AES明文实际为JSON编码字段组成的URL转义参数串，纠正旧JSON对象描述。HTTPS下官方不执行额外加密；原生当前仅允许HTTPS，因此本轮实现不引入HTTP加密路径。无真实密码输入或NAS写入；临时脚本变量删除、控制台关闭，证据仍static。


2026-09-29 收集请求补证：官方静态前端确认默认目录创建条件/字符替换、选目录UPLOAD权限及NormalAlbum.list(category=addable)目标相册；自有目标用album_id、非所有者目标用album_passphrase。未执行NAS写入或读取真实收集内容。临时源码删除、DevTools关闭，证据仍static。


2026-09-29 人脸整理补证：只读官方react_bundle.js中的Person.list_face、separate、delete_face和set_cover调用及人脸选择器。确认人脸编号/缩略图字段、目标0的新人物路径及封面回执；未访问真实人脸列表或执行NAS写入。临时脚本变量已删除并确认undefined，DevTools关闭，无原始代码落盘；版本与static证据等级不变。


2026-09-29 手工人脸补证：只读已加载官方脚本，确认add_face临时编号映射、Item.list_face v6、Upload.Face upload v1的multipart字段、256边长JPEG裁剪、已有归属修改与移除动作。没有读取真实人脸或执行NAS写入。临时源码清除确认undefined、DevTools关闭；只留协议结构，环境版本未知、等级static。

2026-09-29 预览重建后续补证：只读相同官方静态脚本，确认NAS重建单个unit_id、事件按data.idUnit匹配及data.success完成判定、全部转换方式失败后restore_from_regenerating的数组参数。没有触发预览重建、读取实际任务列表或上传媒体。临时源码变量删除并确认undefined，DevTools关闭；环境版本与static等级不变，事件传输等缺口见photos-advanced-management.md。

2026-09-29 预览事件与转换补证：仅浏览官方静态脚本，补齐EIO4、Photos目录下FotoSocketIo路径、查询令牌机制、注册载荷转换、三档JPEG缩略图与ConvertedFile upload v3字段。未读取实际任务/媒体，未发起重建或上传；临时源码删除并确认undefined，DevTools关闭。页面目录只记录标准路径`/`，不保存主机、查询值、原始脚本或响应；环境与版本证据保持static。


2026-09-29 后续仅重新读取上述官方静态脚本，核对list_regenerating调用方及ConvertedFile包装；恢复会把明确返回条目加入重建队列，手动重建标记need_thumbnail=true/need_video=false，空列表无逐项成功凭据。未发起照片API、事件订阅、转换或写入，版本和环境未知项不变，等级static。只输出必要代码片段，无凭据/地址/用户内容；临时页面变量已删除并确认undefined，控制台清空、DevTools关闭。


2026-09-29 本机预览波次同时只读核对共享分类后续：官方统一Category入口、个人优先且空列表时management共享回退、enable_person/concept/similar设置、FotoTeam人物/人脸调用方已记录。只取同一静态脚本，未读取真实照片或发起写操作，不变更版本证据。临时变量删除并确认undefined、清空控制台且关闭DevTools；无HAR/本地脚本副本或用户数据。


### 2026-09-29 相册读取上下文静态补证

官方脚本的详情与实况Unit参数包含album_id或passphrase；缩略图、Streaming、Download均接受相册信息，Download相册分支统一个人API路由而不依赖原件source。共享权限处理函数通过Sharing.Passphrase.getPermission传passphrase、exclude_public并读取permission.download/upload，未执行该请求。具体参数与实现边界见photos-library-read.md相册上下文段。本轮只读官方静态文件，没有读取或保存真实分享内容、口令、相册名称或用户资料；临时脚本变量已删除并确认undefined，控制台清空及关闭。DSM/套件版本仍未验证，证据不提升。


### 2026-09-29 相册协作静态核对

从已登录官方页面脚本核对get_permission、NormalAlbum成员修改、addable列表、provider_user_id和相册Upload.Item.upload调用。共享模式passphrase、所有者album_id/id，上传folder=PhotoLibrary且无timeline目的参数；详细结构与限制见photos-advanced-management.md。仅静态读取，没有触发NAS写入；临时脚本变量删除并核对undefined、控制台清理并关闭。版本未知及证据等级保持不变，不登记兼容验证。


### 2026-09-29 相册间添加来源规则更正

再次只读检查官方ADD_TO_ALBUM处理及角色菜单：本人provider且原空间启用才开放相册转加，混合来源需共享管理权；SPACE_DISABLE仅允许REMOVE_FROM_ALBUM。转加提交目标id/passphrase与item，新建提交name/item；无来源相册参数。没有执行任何NAS写操作，临时脚本删除后验证undefined并关闭开发工具。更正前轮把无原空间转加当作缺口的说法，静态等级和未知版本保持不变。

2026-09-29至09-30跨空间搬移补证：只读官方react_bundle.js中目标选择规则、source_library编码、BackgroundTask.File源空间路由与task_info/Info列表的使用。没有执行NAS移动复制；版本未知限制及static等级保持。临时__photosMoveSource已删除并确认undefined，DevTools关闭；只保留上述结构描述，无原始脚本、真实任务或用户数据。实现与合成验证于09-30完成，不能据此提升NAS行为等级。

### 2026-09-30 混合来源编辑补充

沿同一官方页面只读观察 react_bundle.js（4,086,892 字符），确认混合来源菜单、评级/日期按两空间分发和预览重建两组任务；混合标签直接返回，相册菜单没有移动复制。仅保留函数/参数结构，版本仍按本记录既有未知范围，不推定 DSM/套件升级或兼容。没有真实写入、保存原始脚本或导出会话；临时变量删除、验证 undefined 并清空控制台、关闭开发工具。等级 static；详细结构见 photos-advanced-management.md 的混合来源章节。

### 2026-09-30 分类拼图与相似项目观察开始

沿同一已登录Chrome官方页面继续只读静态核对；首次工具提示锁屏，用户回复已解锁后恢复访问。DSM/build/Update、Photos完整版本与lab别名关系仍未知，保留上表边界，不新建版本兼容结论。仅提取分类卡片与SimilarItem的接口参数/响应字段和UI控制语义，不记录地址、凭据、真实照片或用户资料，不触发NAS写入。

本次观察结束：分类卡片limit4及人物show_more、视频字符串type=video已核对；相似组只读状态、详情和管理候选参数记录在photos-library-read与photos-advanced-management。第二次确认VIDEO枚举为字符串，未把筛选NORMAL_VIDEO整数枚举混用到Item.list。仅读取官方静态资源，未调用真实照片读写接口；临时变量均删除并确认undefined，控制台清空、开发工具关闭。版本/权限未知项与static等级不变。

## 2026-09-30 相似识别状态静态补证

沿同一已登录Chrome照片页面，只读取已经加载的react_bundle.js，不调用真实照片API或修改NAS；环境版本和设备归属仍未知。本次确认get_status消费waiting_count、similar_clustering_stage和is_similar_hash_migration_done：waiting_count为0且迁移完成时隐藏状态；waiting_count大于0且stage为running时显示处理数量，其余待处理情况显示计划处理文案与说明。初始静态状态stage为waiting；不能将初始值当作NAS实际状态。官方INDEXING_COUNT_POLLING_INTERVAL为15e3毫秒，页面挂载后轮询、卸载清理计时器。证据仅static，没有读取或保存真实照片、地址和凭据；临时脚本变量删除后确认undefined、控制台清空并关闭开发工具。


## 2026-09-30 下载格式入口复核开始

同一已登录Chrome官方照片页面在标签分类的下载菜单提供“原始文件”和“压缩版 JPEG”。继续仅核对当前已加载官方静态脚本，不下载真实照片或写入NAS；环境版本、设备归属及完整权限仍沿本快照未知项。发现目标为压缩下载的路由/版本/参数、来源/相册权限和文件类型语义；UI入口可观察，接口细节在完成静态核对后追加，不预先提高证据等级。


静态核对完成：Download.download/convert均v2，download_type枚举source/optimized_jpeg/original_size_jpeg；下载携带item_id数组、force_download=true，普通空间分别Foto/FotoTeam，相册统一Foto并携带album_id或passphrase。批量压缩下载前官方提示不能转换时保留原格式；相似组主列表选中项展开为组内全部item_id。单项视频/GIF/WebP不显示压缩选项。特定原始格式单选另有original_size_jpeg，需先convert；整相册有Browse.Album.download和幻灯片入口，尚未完成相关完整参数复核，保留后续待办。没有读取真实照片或触发下载/转换；临时__photoDownloadSource删除确认undefined，控制台清空并关闭，API证据static。


## 2026-09-30 整册与文件夹下载核对开始

沿同一官方照片页面只读检索已加载脚本，核对Browse.Album.download版本、folder_id下载参数及所有者/协作角色选择规则；不下载真实媒体或执行NAS写入。DSM/Photos版本、设备归属等未知项不变，保留原快照边界，待核对后追加静态结构。


本轮静态核对完成：Browse.Album.download明确v2，所有者id/协作者passphrase两分支；Download.download v2目录传folder_id整数数组、force_download=true；两者支持source/optimized_jpeg、附件ZIP。官方隐藏表单POST，数组与口令JSON编码。Folder.set_cover v2及id/id_item只得到静态线索，权限/结果回读未核全，仍为后续。未下载真实媒体、未调用NAS写接口，未保存原始脚本或会话；临时__photoArchiveSource删除并确认undefined，第二次只读脚本提取无持久变量，控制台清空并关闭DevTools。环境版本、设备归属未知项不变，API证据仅static。


## 2026-09-30 幻灯片播放观察开始

同一已登录Chrome照片页面，只读核对官方已加载脚本中的播放范围、间隔、循环和视频完成规则，不打开真实照片、不触发NAS写入。DSM/build/套件版本与lab归属沿既有未知范围，不新增环境兼容声明。


幻灯片静态核对完成：当前视图/相册工具栏及预览菜单进入同一lightbox的slideshow路由，设置fullscreen/carousel；照片延迟明确为3e3毫秒，暂停取消计时，空格切换播放，左右键前后切换。全屏时repeat=true，停止或离开全屏清除carousel；视频等待onVideoEnd才推进，Live/Motion默认仍是静态图。只读查看权限的菜单也保留幻灯片，不依赖download权。未观察到本轮播放器内自定义间隔/随机顺序设置，未猜测新增。原生独立全屏窗口、现有预览媒体/照片分页即可实现，不增加NAS接口或写入。检索使用局部Promise变量，无持久脚本变量、未保留原始脚本；控制台清空、DevTools已关闭。证据仍static，真实全屏设备与NAS播放待用户验收。


## 2026-09-30 原尺寸JPEG候选复核开始

幻灯片产品源码冻结、独立包构建中；继续只读核对同一官方已加载脚本的original_size_jpeg转换参数，不触发真实转换或下载，不改变环境版本未知范围。目标为下一功能切片提供必要参数证据，不因找到枚举就视为实现完成。


原尺寸JPEG候选静态补证：Download.convert v2先传单个item_id整数，按上下文附album_id或passphrase；转换成功再调用download_type=original_size_jpeg下载。单选照片的菜单还受hasHevc与enableConvertedOriginalJpeg实际标记约束，类型判断包含TIFF及RAW扩展arw/srf/sr2/dcr/k25/kdc/cr2/cr3/crw/nef/mrw/ptx/pef/raf/3fr/erf/mef/mos/orf/rw2/dng/x3f/raw，另有yh判定分支尚待完整核实。相册下载统一Foto，所有者album_id、协作者passphrase；其他来源沿Foto/FotoTeam。尚未核全标记来自哪个响应、转换返回结构和转换中的取消/重试副作用，因此保留下一契约切片，未写产品代码或触发真实转换。无持久调试变量、未保存原始脚本；控制台清空、DevTools关闭。


## 2026-09-30 原尺寸JPEG转换下载

继续核对同一环境的官方静态脚本（仅读取已加载资源，未执行真实转换/下载）：Setting.User.get v1返回可选ame_status.has_hevc，Setting.Admin.get v1返回可选enable_converted_original_jpeg。下载菜单在单选且两项为true时提供原尺寸JPEG；缺字段按实际能力不可用处理，不因未实测增加人工禁用。

格式为HEIC/HEIF/HIF照片（官方照片类型含photo/photo360/burst/motion_photo，实况照片亦可判定），以及TIFF和RAW扩展tif/tiff/arw/srf/sr2/dcr/k25/kdc/cr2/cr3/crw/nef/mrw/ptx/pef/raf/3fr/erf/mef/mos/orf/rw2/dng/x3f/raw。此项只适用单张，不能用于整册/目录或相似组批量。前段yh与设置来源未知的候选记录由本段补全；不改变历史证据等级。

Download.convert v2使用POST，item_id为单个整数；个人/共享原空间分别Foto/Fototeam，相册统一Foto，当前账号为相册所有者传album_id，否则按相册实际下载权限传passphrase。官方代码只消费转换成功信封，不读取额外data字段；成功后Download.download v2，item_id数组、force_download=true、download_type=original_size_jpeg。原生转换/下载均用请求体传递相册口令。这里的转换可能生成NAS派生缓存，不修改原件，因此机器索引标为mixed，不能称为纯读取；实际缓存副作用、长转换耗时和取消行为仍未验证。

原生实现先核对最新照片身份、相册或目录下载权、会话代次与v2实际能力；同照片在途去重，失败不自动重放convert，取消停止后续请求及本地保存（不能承诺撤回NAS已接收的转换）。下载结果须是ImageIO可完整解码的JPEG，不能回退原件却标记原尺寸JPEG；临时文件校验后另存，不覆盖现存文件。没有修改NAS设置、原件格式或本地持久化结构。

证据static；仅合成请求/结果测试，不提升为read-verified或behavior-verified。PENDING_USER_VALIDATION：实际NAS开启原尺寸JPEG、HEVC解码可用，选择HEIC/TIFF/RAW逐张下载；确认JPEG分辨率与旋转、原件不变、协作/共享权限正确，断网或取消不会生成损坏目标，同名另存。回传版本、格式、入口/空间、动作和脱敏失败提示，不提供真实媒体或凭据。


## 2026-09-30 文件夹封面静态补充

只读查看同一官方react_bundle.js：setCover封装Foto/FotoTeam.Browse.Folder.set_cover v2，worker以{id:folderId,id_item:itemIds}提交，成功后刷新目标目录封面。选择窗口强制单选并以目标目录为根，允许进入子目录；根目录无入口，共享需要管理权限。选图允许可查看项目，不要求下载权限。

Folder.get/list additional.thumbnail为数组；folder_cover_seq存在时映射自定义目录封面，否则由unit_id读取普通拼图。自定义Thumbnail/get参数type=folder、id=目录id、folder_cover_seq、cache_key，不含size。官方保存成功仅生成序号0及新cache_key刷新，未找到可回读所选照片id的字段。原生实现采用成功回执和新鲜可解码封面共同确认，写回执丢失仍未知，不自动重放。

证据static；DSM/build/Update、套件完整版本及lab-a归属继续未验证，不补造环境兼容。没有真实封面写入、下载或照片修改；无原始脚本/HAR/会话导出，控制台清空并关闭开发工具。详见photos-management.md和photos-library-read.md。


### 封面选图排序候选（2026-09-30，后续切片）

同一官方脚本的封面选择器使用目录排序菜单，选中照片时菜单禁用；四项为名称/大小/类型/拍摄时间，对应filename/filesize/item_type/takentime，方向asc/desc。切换动作携带当前目录id、sortBy和sortDirection，并分个人/共享FolderAPI和ItemAPI重读，不是只重排当前页。该静态候选已确认菜单与枚举，但完整分页worker、默认排序及是否保存目录偏好仍需核对；本轮不发送排序写请求，也不把候选作为已接入能力。静态脚本仅在控制台临时查看，输出清空、开发工具关闭。


## 2026-09-30 文件夹排序完整静态核对

补齐前轮候选：Folder.set_order v1先保存；Folder.get返回目录sort_by/sort_direction，缺失或未知字段独立沿Setting.User.item_sort_by/sort_direction（官方默认takentime/asc）。选择器排序菜单四字段和两方向、选中禁用；Item.list逐页传排序，子目录始终按名称和相同方向。当前主目录相同时官方同步重新排列主图库。对应worker/版本映射/默认值均来自官方静态脚本，等级static，无真实写操作或真实用户排序读取。未保存脚本副本，控制台清空并关闭；DSM/build/Photos完整版本及lab-a归属继续未验证。端点/源码策略见photos-management.md和photos-library-read.md的文件夹排序记录。


### 完整范围复核纠正（2026-09-30）

本轮打包期间重新比对官方动作绑定与当前源码，确认先前“只剩上传重启恢复”的清单不完整，不能据此结束完整网页对齐目标。官方handleRenameFolder个人/共享分别绑定Folder.rename动作；worker单选目录、打开名称输入框、rename v1(id,name)，响应folder.id/name更新目录树。删除worker用Folder.delete v1(id数组)；移动/复制官方动作保留selectedFolderId/folderArray和BackgroundTask.File。当前SynologyPhotosMutation只有createFolder/setFolderCover/setFolderSort，move/copy目标为照片数组，macOS目录卡片没有这些目录管理入口。以上是static与当前源码差异，尚未核全删除/搬移确认、目录树和最终结果校验，不可直接复制接口片段执行。还发现共享handleEditPermission绑定与主文件夹页排序入口，应列入后续菜单审计，不能把封面选择器排序当成所有文件夹页面控件齐全。

下一切片优先目录重命名，随后目录删除及移动/复制；相关共享目录权限/分享和主页面排序继续核对。上传重启恢复仍等待既有存储授权。未触发任何真实目录重命名、删除、搬移或权限修改；没有给候选写接口注册已验证兼容记录。构建期间未再修改产品源码。


### 2026-09-30 重命名静态补充

解锁后只读官方react_bundle.js，核实Folder.rename v1(id,name)、成功folder.id/name，以及非空/UTF-16长度255/保留名称正则。未执行真实重命名或读出用户目录，未保留脚本、HAR、会话或真实内容；控制台已清空关闭。DSM/build/Update、Photos完整版本及与lab-a关系仍未核实，证据static。具体请求、权限、失败及原生确认策略见photos-management.md本轮段落。


### 2026-09-30 目录删除主流程静态补充

只读官方react_bundle.js的HandleDelete、DeleteItemAndFolder、Lr/Li来源绑定及epV任务worker。确认多目录/照片混选、item_id/folder_id数组、task_info.id和后台完成通知；不采用此前Browse.Folder.delete helper作主流程。确认框包含总选择数，回收站提示取决于设置；本轮没有修改设置、删除文件或导出用户内容。浏览器控制台清空关闭，没有保存脚本或会话。DSM/build/Update/Photos完整版本及匿名设备归属仍未知，不提升证据。详见photos-item-deletion.md。


### 2026-09-30 文件夹移动复制静态补证

只读已加载官方react_bundle.js：CopyToFolder/MoveToFolder的folder_id选择、个人/共享源命名空间、目标UPLOAD检查、原父目录/自身后代冲突、move extra_info.version=2/source_library/source_folder_ids、统一BackgroundTask.Info及task_info.total/target_folder。浏览器不发送写请求，不记录真实目录或用户资料；没有取得DSM/build/套件完整版本，保持static及既有环境关系未知。实现与边界见photos-management.md。


### 2026-09-30 共享目录权限静态发现

沿官方已加载react_bundle.js只读核对FolderPermission v1方法表、目录权限弹窗ePj/ePA、update参数构造及hK/hY转换、成员列表和父目录限制。未打开会导致分享写入的官方表单，未执行get以外NAS业务请求或任何权限写入；仅查看静态脚本。现状读取与尚未接入的保存候选明确分开记录于photos-management.md。DSM/build/Photos版本未知限制保持，不注册行为验证。

2026-09-30追加只读官方菜单静态核对：TEAM_SELECTED_FIRST_TWO_LAYER_FOLDER在Ei()管理分支选择，EDIT_PERMISSION另由su()读取DSM is_admin或Admin.enable_user_sharing；普通目录manage/download分支无该动作。没有触发分享或权限变更，未记录真实成员/链接/响应，环境版本未知限制不变。


### 2026-09-30 混选下载静态补证

只读官方已加载react_bundle.js的统一选择下载worker及表单辅助：同一请求接收item_id与folder_id，非空才加入；force_download=true、download_type及空间路由。文件夹选择先检查锁定状态，照片与目录混选不能走原尺寸JPEG单张转换。未触发下载、没有NAS写入或真实用户数据导出；静态检查结束已清空并关闭控制台。DSM/build/Photos完整版本及环境关联仍未知，证据static。参数、实现和用户验收见photos-library-read.md。


### 2026-09-30 拖放移动与重复项处理静态补证

只读官方脚本，核对单目录与整组选项移动worker、task action、设置组件选项、用户设置字段和set调用差异对象；未调用真实NAS读写业务接口、未进行移动/复制/上传或保存设置。默认规则上传ignore/rename、移动复制skip/overwrite；set方法版本尚未核定，保留候选。当前环境DSM/build/Photos完整版本未知及设备关联未知不变，无verifications新增。控制台已清空并关闭，未保存原始脚本或会话内容。


### 2026-09-30 重复项设置版本补证

继续同一Chrome已登录官方页面，只读取react_bundle.js的必要静态片段：Foto.Setting.User版本表get:1/set:1；保存worker传差异字段，reload时再get。字段upload_default_action与copy_move_default_action及对应ignore/rename、skip/overwrite选项已核对。没有调用真实NAS业务接口、保存设置、上传、移动复制或读取用户照片。未输出/保存原始脚本、凭据、地址或响应。环境版本与设备关联未知不变，证据static，不增加verifications；完成后console.clear并关闭DevTools，确认控制台不再开放。

### 2026-09-30 最终剩余功能只读复核（开始）

沿用本环境未知版本与未关联设备的限制。范围仅已登录官方Photos页面静态菜单/设置/操作定义，核对当前实现之外是否还有独立的照片或相册用户操作，不发起业务写请求、不保存原始脚本或用户数据。具体发现与是否存在新缺口以随后追加证据为准；不因历史剩余清单只列上传恢复就认定完整对齐。


最终复核追加：官方Album版本表含get:4/set_order:1、get/set_album_list_order:2、get/set_album_list_display:3。相册内容工具栏四字段及升降序，缺省taken time升序；id路径set_order后重新分页，口令路径只改变本页面状态。照片list传album_id或passphrase及sort_by/sort_direction/offset/limit。相册列表另读album_display_type和album_list_sort_by/direction，分享列表有shared_with_me与shared_with_others独立排序字段；故前次“仅剩上传恢复”结论不完整，已纠正账本。

列表候选排序常量含album_name/album_type/start_time/create_time/share_status/share_modify_time；下一波继续核对展示类型与列表分类映射，不猜字段实现。RotateFolderItems/RotateAlbumItems只是前端action/reducer线索，尚无对应NAS接口证据，不将旋转列为已确认缺口。以上只读静态片段，无真实业务请求/写入/下载，无原始JS或用户数据保存。已清空并关闭控制台，确认consoleOpen=false。环境完整版本与设备关联未知，不新增任何observed/read-verified/behavior-verified结论。


### 2026-09-30 相册列表排序补证（开始）

沿用本环境DSM/build/Photos完整版本及设备关联未知的限制，只读已登录官方页面的静态脚本，限定列表显示范围、排序选项及读取/保存版本。不开启写请求、不导出原始脚本或会话/用户资料；证据仍为static，待随后记录结论。


补证完成：官方显示枚举all_album/my_album，分类映射分别normal_share_with_me/normal。Album.get/set_album_list_display v3读写album_display_type。get/set_album_list_order v2三个独立前缀album_list、shared_with_me、shared_with_others，各带_sort_by/_sort_direction。相册菜单名称/类型/最早照片时间/创建时间/分享状态；两类分享列表菜单名称/类型/最早照片时间/分享修改时间。字段album_name/album_type/start_time/create_time/share_status/share_modify_time，方向asc/desc。LW绑定相册菜单LH，LV绑定分享菜单LU；保存后清空原列表并按新条件分页。首页Album.list v4带对应category及sort；与我共享Sharing.Misc.list_shared_with_me_album v2带sort；与他人共享Album.list v4带category=shared及sort。仅静态读取，无业务请求或设置保存；console.clear后关闭控制台，确认consoleOpen=false，无原始资源或用户数据保存，环境限制及static证据等级不变。


### 2026-09-30 旋转候选后续只读复核（开始）

列表排序代码/测试完成后，构建期间继续限定官方静态RotateFolderItems/RotateAlbumItems调用链及菜单入口；不发真实照片读取/写入或下载，不保存原始脚本。版本未知和static限制沿用，结论待后续补证。


旋转补证结论：已找到实际预览菜单ROTATE及个人/共享管理菜单绑定，不再只是孤立reducer字符串。kV/kY经HandleRotate，D6/D9产生UpdateItem，key=rotate_action、value=counter_clockwise，分别使用Foto.Browse.Item与FotoTeam.Browse.Item；worker eOq调用Item.set，参数id数组加该字段，随后按clockwise/counter_clockwise交换布局宽高并清除主图及unit缩略图缓存。菜单仅按已有权限类型绑定，未据常量推断六种旋转均有可见入口。此轮未调用set或旋转真实照片，没有真实响应/回读语义验证。当前Core mutation与Model未见对应持久旋转流程，Mac预览rotation状态仅本地视图变量，因此列为明确后续缺口。下一切片仍须复核set版本、媒体限制、读取orientation的变化及非幂等未知结果校验。console.clear后关闭控制台，确认consoleOpen=false，无原始脚本留存。


### 2026-09-30 预览旋转版本与限制补证开始

沿本文件环境边界，版本/匿名设备关系仍未验证；继续只读读取同一登录页面已加载的官方静态资源，核对Item.set版本、菜单媒体限制与方向语义，不调用业务写接口，不保存原始脚本或真实照片资料。证据等级仅static。


### 2026-09-30 预览旋转保存静态补证

同一官方脚本Item版本表set:2/get:5，个人及共享路由沿已确认Item.set调用链。菜单在图片未准备好、video/video360/photo360、GIF、WebP时排除旋转；方向转换逆时针映射1→8、2→5、3→6、4→7、5→4、6→1、7→2、8→3，宽高交换。实况预览仅在orientation与orientation_original相等时显示动态播放。网页匹配GIF/WebP文件名，客户端按扩展名匹配，避免名称中间含后缀的误判。证据仅static，不是请求或写行为验证。

本轮新增单张rotatePhoto命令与rotation能力，固定原照片/方向/尺寸快照；写前重新核对身份、方向与管理权限；Item.set v2仅发送id和rotate_action=counter_clockwise。操作编号沿既有去重，失败/丢回执只读Item.get v5核对预期方向和交换后的尺寸，不重发旋转。已确认后重新请求当前预览与更新缩略图，图片请求既有reloadIgnoringLocalCacheData。不会重载图库或跳回最新月份。原件字节是否改变未验证，照片身份/大小变化不擅自追认。


### 2026-09-30 官方功能入口清单补证开始

同一环境边界（DSM/Photos版本与设备归属未验证），只读核对已登录官方页面加载脚本的菜单动作与导航/设置定义，不保存原始脚本、凭据或用户数据。用于确认剩余用户功能，证据仅static。


### 2026-09-30 主题与设置静态补证

已解锁Chrome，仅读取已登录官方Photos页面静态脚本。Concept个人/共享路由、list/get/set_visibility v2、show_hidden=true、id数组与visibility布尔值，以及get返回list[].visibility/name/item_count/display_threshold/additional.thumbnail均有调用绑定。个人设置白名单、管理表单、User/Admin/TeamSpace保存链确认；未读取或记录真实设置值，未触发NAS写入。分类封面和hide_item只记录后续待办。证据为static，沿本环境未知完整版本限制，未升级行为兼容等级；控制台已清空并关闭。


### 2026-09-30 主题封面与误分类移除补证开始

沿同一未知完整版本环境，仅读取已登录官方页面的静态处理链。范围限Concept.set_cover/hide_item及结果读取、低于分类展示阈值后的行为。未执行实际NAS写入，证据不升级为behavior-verified。


本轮补证结果：官方选中列表/预览处理以Item编号提交set_cover.photo_id、hide_item.item_id；封面读取来自get.additional.thumbnail.unit_id。移出确认比较剩余数量与display_threshold；移除后更新分类数量/显示与封面，不删除原件。证据来自官方静态函数绑定及转换函数，无真实写请求。控制台已清空并关闭，无原始脚本或用户数据落盘。


2026-09-30继续同一会话静态核对照片个人设置，沿用本文件既有环境和未知版本信息，不升级证据等级。只读取官方已加载资源中的字段、枚举及保存调用链，无真实NAS设置变更。

显示设置static补证：官方个人表单含日/月、九种日期格式、12/24字符串、四字段排序及asc/desc、show_item_info_in_lightbox；date_format读大写写小写，Setting.User.set只传差异对象。预览底部显示拍摄日期、前三项地址和描述，视频排除、详情栏显示时隐藏；日期/月标题根据分组和格式组合。客户端外观沿已有原生设置作为平台替代，本轮不写网页theme。已更新photos-display-settings端点和五端影响，实际NAS读写/下载为零。控制台清空并关闭，未保存原始脚本或用户资料。

2026-09-30继续同一已登录会话静态核对个人识别与自动预览。沿本记录未知版本限制，只读官方资源，不修改真实NAS设置或生成真实照片预览。


个人识别static补证：官方个人表单按Admin对应enable_person/enable_concept/enable_similar与enable_home_service条件显示，User.set v1仅写个人变化字段；管理员全局与共享设置为独立页。识别变化触发设置/页面重新加载，默认排序变化另有确认。auto_generate_thumbnail还与桌面转换和HEVC/VC1/VP9/MPEG2能力共同决定支持状态，不等同保存布尔值。本轮实现个人识别三项，自动预览留待完整触发链切片。未读取真实设置值、未执行写入或下载；控制台清空并关闭，无原始资源或用户数据落盘。完整环境版本仍沿本记录未知限制，不提升为behavior-verified。


2026-09-30沿同一已登录环境继续自动预览静态发现，复用已建快照及未知版本限制；范围为auto_generate_thumbnail消费者、候选选择、转换/上传触发及恢复流程。只观察官方静态资源，不下载真实原件或提交NAS写入。

自动预览static结果：list_convert_needed v3与preset/type条件、空闲5秒扫描、可见项优先、独立unit_id原件下载、AUTO_GENERATE与REGENERATE分流均有函数绑定；记录thumb_*及film_h264映射，视频桌面桥接最终参数仍待补证。原生只读候选服务已接入，未进行真实调用，未把待办表述为整体完成。Chrome控制台已清空关闭，未保存原始脚本、HAR或真实用户资料。

2026-09-30沿既有环境快照继续静态核对自动预览单元与视频结果读取；未知版本限制保留，只读官方资源，不执行真实原件读取/上传。

自动执行static增量：Download帮助函数默认unit_id，桌面视频上传_dataField=film_h264与常规multipart同名字段，thumbnail-update注册unit_id/is_team及data[].thumbnail；仅证实缩略图状态，不代表视频完成。本轮实现单元读取与本机H.264/AAC转换，无真实NAS下载/写入。一次浏览器管道中断后重新读取状态成功，控制台最终清空并关闭，无原始脚本或私有数据落盘。


2026-09-30自动预览上传/核对实施增量只使用此前static记录；本轮没有新NAS浏览器读取、真实原件下载或写入。ConvertedFile v3 multipart及同步回执沿原证据；Thumbnail空缓存键与Streaming orig_h264进行本次上传内容核对为明确标注的客户端恢复策略，实际绑定与NAS响应仍未验证。以本地合成媒体测试上传、断网、取消和重新封装，不提升现有环境验证等级。详情见photos-advanced-management.md最新增量与Photos对齐账本。

2026-09-30本轮自动预览设置/调度实现沿先前auto_generate_thumbnail与User.get/set静态线索，没有新浏览器采集或真实NAS读取/写入；状态与未知版本限制不变。仅执行本机合成服务测试和原生设置UI测试，记录不提升为observed/behavior-verified。

2026-09-30用户再次解锁后，继续同一环境的可见项自动预览静态核对；目标为AmeDefect状态、媒体/实况单元与共享entry目录下载权限绑定。DSM/build/套件版本继续保留原未知限制，沿用已登录连接与权限类别；只读官方脚本，不触发照片下载、转换或写入。

本轮解锁后static补证完成：ame_defect为字符串，候选读取缩略图xl/sm与additional.video_convert_status/video_meta.video_codec，个人owner或共享management/目录download条件；预览2秒去抖、liveUnits逐项、next/prev排除video/video360/live_type视频。详情追加到photos-advanced-management.md。没有读取真实照片或进行NAS写入；控制台清空并关闭，无原始资源落盘，verifications不升级。

2026-09-30继续同一解锁会话静态核对原始Item/Unit状态到前端字段的归一化，范围为video_convert_status与thumbnailUnitId的来源，避免猜请求字段。版本未知等限制保留，禁止真实照片下载或NAS写入。

本轮static结果：Item归一化仅拆additional.thumbnail→状态表/thumbnailUnitId，其余additional保持，video_convert_status是消费字段，未向NAS新增同名请求。沿已有Item.get/Unit.get请求和可见权限规则接入原生流程；真实NAS数据读写/原件下载为零。控制台清空并关闭，没有原始脚本落盘，未知版本及static证据等级保留。

2026-09-30沿同一已登录环境继续管理员/共享空间设置static核对，目标为Setting.Admin/TeamSpace的字段、控件条件、确认与保存过程。既有版本未知限制保留，只读取官方静态资源，不读取真实设置值、不触发NAS写入。

2026-09-30续：Chrome已解锁，只读官方静态脚本确认TeamSpace get/set/set_enable v1、管理页权限、差量保存与启停回读；另记录全局分享/排除格式、Download缓存v2及设置页重索引待办。未读取用户设置值、未下载照片或执行NAS写入，版本未知不升证据等级。控制台已清空关闭，无原始脚本落盘。

2026-09-30全局设置续查开始：仍按相同未知DSM/build/Update/Photos版本环境记录，Chrome官方静态资源只读核对；聚焦全局保存联动、缓存状态与排除格式候选，不读取用户数据或修改实际设置。

2026-09-30全局static完成：重新读取官方eHo/eHi/eLk/eLN、eLW/eLV/eL$、ng.PHOTOS/VIDEOS及hU/hj版本表，确认识别联动、Admin字段、数组差量、need_hevc剔除、JPEG/HEVC条件及Download缓存三方法v2。只读取官方静态资源，没有读取真实用户设置/缓存或照片；未保存原始脚本。Chrome控制台已清空关闭。完整字段、格式列表与客户端多阶段结果语义见photos-global-settings-cache；版本未知，不写入behavior-verified。

2026-09-30全局设置打包期间，开始同一环境的共享成员/自动备份权限static核对；沿已记录未知版本和只读边界，只读取官方脚本的列表、保存和角色映射，不读取真实成员或修改权限。

共享成员static已确认TeamSpace权限列表直接数组、update_permission(list)变更项、entry/management角色、auto_backup联动、administrators组保护及entry目录批量权限弹窗。写入和真实成员读取为零，尚未实现，详见高级管理的后续补证。控制台清空关闭，未知版本限制不变。

2026-09-30共享成员波次继续：相同未知DSM/build/Update/Photos版本基线，仅只读官方静态资源，核对按成员的文件夹批量权限请求、列表读取及临时成员恢复，不读取真实成员/目录或执行权限写入。


2026-09-30最后调度补证：Chrome恢复可用，只读同一官方react_bundle.js。eO9默认next=3/prev=2，eO8按唯一项目数缩减；YR按当前/next/prev构造，ehJ明确tier1→tier2→tier3→tier4，Ea编码分类与后台priority=4。整库Index.get/reindex版本1，basic/thumbnail动作和15秒计数轮询亦已定位；没有调用维护API。临时源码变量删除并确认undefined、DevTools关闭；没有保存原始脚本。DSM/build/Update/Photos版本与设备归属仍未知，证据只属static。


2026-09-30整库维护补证：切回已登录Synology Photos标签页后只读官方react_bundle.js。Index计数明确basic/metadata/thumbnail/geo_coding/face_extraction/person_clustering/concept_detection；个人入口依赖enable_home_service，共享设置仅enabled后显示维护；has_h264来自Setting.User.ame_status。新编解码器欢迎提示中管理员会调用个人Index.reindex_all_user(type=thumbnail)，属于另外的全用户范围，不隐含授权原生当前空间按钮维护所有用户。未调用维护API。临时源码清除确认undefined并关闭控制台；版本仍未知、等级static。前次第二次空脚本读取时实际Chrome已切至其他页面，不能据空资源推断NAS故障；本轮定位Photos标签后读取成功。


2026-10-01继续同一已登录Photos环境只读官方react_bundle，核对新编解码器欢迎提示和失败标记。沿用未知DSM/build/Update/套件版本限制，不绑定lab-a，不读真实照片或设置，不发NAS写请求；本轮目标只提取静态参数、条件与错误分支。


2026-10-01 static补证完成：Wizard.get/set v1、prompt name/show与new_codec_installed、确认/稍后推进并保存已读、管理员reindex_all_user与个人reindex分流；自动预览缩略图链三种桥接超时/连接例外不set_broken，其他抛错photo，视频上传抛错video，上传success=false仅警告。未调用上述真实API，不读真实用户设置。详见photos-advanced-management增量。临时window源码删除确认undefined，控制台清空关闭，无原始脚本或响应落盘。版本未知限制和static证据等级不变。


### 2026-10-01 新格式包构建期间的失败状态static补证

沿同一已登录Chrome环境只读官方react_bundle.js（4,086,892字符），未发出照片API或设置/维护/下载/删除请求。DSM/build/Update及Photos完整版本仍未知，证据只记static。确认预览状态Broken="broken"，缩略图尺寸状态字段与视频UI默认值必须区分：缺失字段会被网页回退broken，不能作为NAS写后证明。端点记录追加，未提升兼容等级；临时源码变量清理和DevTools关闭在本轮结束前核对。


### 2026-10-01 照片菜单只读对齐审计

同一Chrome官方Photos页面只读核对标签内批量菜单、相册创建/排序和个人设置完整字段；没有点击保存/生成/删除、改变设置或创建共享，没有导出数据。静态UI发现选片“创建共享链接”，当前原生缺直接组合入口，登记下一切片；不据UI推断写接口。共享/全局标签本轮未成功切换显示，未把个人设置重复读取冒充其覆盖。设置最后Esc取消关闭，完整版本仍未知，不提升接口兼容等级。


2026-10-01最终菜单复核第二部分：沿用同一已登录会话、原生Chrome可访问性，只读设置标签；鼠标点击未切换，键盘Tab/Return可切换。共享空间关闭，只观察启用入口未执行；全局确认识别总开关、普通用户分享、访客信息和排除扩展名。未保存或改变设置，未触发真实写入。不导出/保存原始页面或截图；DSM/build/Update/Photos版本仍待About只读核对，现有static等级不变。


### 2026-10-01 最终菜单第二部分静态结果

官方资源发现临时分享create(shared=true)/temporary_shared、停止保留副本copy及取消清理，以及冻结条件相册set_unfreeze/重建条件链；最小参数和未验证语义见photos-advanced-management.md同日候选节，机器索引同步。另有独立新建文件夹、缩略图大小、分享列表管理及任务打开位置/前往相册菜单。仍仅static，无NAS写入、原件下载或版本升级结论。两个浏览器内存临时变量已删除并确认undefined，控制台清空、开发者工具关闭；无原始资源落盘。


2026-10-01冻结条件相册后续补证尝试：Chrome原生工具报告Mac锁屏，无法继续读取官方静态处理细节；已请求解锁。没有新请求或真实写入，未提升证据等级。期间先完成独立缩略图布局控制，不推测冻结字段类型或迁移行为。
