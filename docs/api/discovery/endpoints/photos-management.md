# Synology Photos 管理、删除与后续接口

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="photos-management"></a>
<a id="photos-sharing-management"></a>
<a id="photos-duplicate-settings"></a>
<a id="photos-display-settings"></a>
<a id="photos-recognition-settings"></a>
<a id="photos-upload"></a>
<a id="photos-file-management"></a>
<a id="photos-album-management"></a>
<a id="photos-item-metadata"></a>
## Photos 照片、相册与目录管理


稳定端点：`photos-item-metadata`、`photos-album-management`、`photos-file-management`、`photos-upload`、`photos-sharing-management`、`photos-duplicate-settings`、`photos-display-settings`、`photos-recognition-settings`。

均为内部API。当前参数来自[2026-09-28起官方静态资源](../environments/INDEX.md#2026-09-28-photos-parity-observation)，完整版本未知；除单独登记的受控场景，不宣称真实写入通过。API/path/版本须发现；JSON业务值通过POST表单编码，上传为multipart。通用身份、权限、确认、去重和未知只读规则见[通用标准](../../reference/common.md)。

### 命名空间与原件编辑

照片和目录按实际来源选择 `SYNO.Foto` 或 `SYNO.FotoTeam`，不因切换界面改写既有操作来源。相册与分享仍使用统一Foto相册接口，不能构造FotoTeam.Album。共享management只作用于共享范围；entry的upload权限不能替代manage。DSM管理员不自动拥有Photos共享管理权。

| API后缀 / 方法 | 版本、参数 | 回读与限制 |
| --- | --- | --- |
| Browse.Item.set | v2；id整数数组；rating=0…5、description或time（Unix秒） | 一次固定字段；Item.get v5回读对应值和原身份 |
| Browse.Item.add_tag/remove_tag | v1；id整数数组、tag整数数组 | additional.tag，缺字段不当空集合 |
| Browse.GeneralTag.create | v1；name字符串；data.tag含id/name | 按明确新id在list v1回读；无回执不按同名追认 |
| Browse.NormalAlbum.create/add_item/delete_item | v1；create(name,item)，成员变更(id或passphrase,item) | create返回album.id/name；delete_item只移出相册，原件保留 |
| Browse.Album.set_name/delete/set_cover | v1；(id,name)、id整数数组、(id,id_item) | Album.get v4固定id；封面additional.thumbnail.unit_id与照片匹配 |
| Browse.Album.get | v4；id整数数组及sharing_info/thumbnail等additional | 所有者、分享、权限与原快照分别核对 |

原件编辑固定profile/账号/空间/id/文件名/大小/拍摄与索引时间/目录/类型，写前重读最小身份和Folder.get v2实际view/manage。单次照片集合最多100个，不能静默丢弃超量。相对日期按每张原快照的Unix秒加偏移，逐项Item.set v2(time)；一天按24小时，检查溢出，不猜shift_time候选参数，不把重新核对变成再次累加。

混合来源评级、绝对/相对日期与预览重建按来源分别预检和提交，逐项保存结果；标签与混合相册移动不由该能力推导。相册内个人项目以provider_user_id判断本人贡献、实际个人服务权限；共享相册项目要求全空间MANAGE。普通相册与条件/冻结相册的原件权限路径分开，不能把owner当provider。精确协作角色见[高级管理](photos-management.md#photos-advanced-management)。

### 上传与目录创建

`Foto/FotoTeam.Upload.Item` v1：

- upload_to_folder：multipart file、duplicate、name、mtime（秒）、target_folder_id。
- upload：file、uploadDestination=timeline、duplicate、name、mtime、folder=["PhotoLibrary"]。
- 非文件业务字段JSON编码；凭据只在既有请求头/受保护正文。临时文件权限0600，结束删除。
- 回执必须提供明确项目编号；同空间Item.get核对大小、目标目录和相册provider。缺编号不按名称猜测、不自动重传。
- 多文件逐项提交，固定来源文件摘要、目标和operationID；切换图库不改变队列目标。目录缓存仅当前批有效。
- `Browse.Folder.create` v1(target_id,name)返回folder.id；Folder.get v2(id,additional=[access_permission])核对父编号、名称和权限。目录创建未知就停止依赖步骤，部分成功不自动删除已建目录。
- 共享entry上传需view且upload或manage；management按共享目录规则；不借个人API处理共享编号。
- 相册直接上传与先上传再add_item是不同路径；相册上下文、passphrase和贡献者规则统一见[高级管理](photos-management.md#photos-advanced-management)，加入失败不能重复文件上传。

### 分享、密码与有效期

读取Album.get v4 additional=[sharing_info]不创建链接。shared=false表示关闭；已共享模式区分private/public-view/public-download，未知不当关闭。公开upload不属于普通相册权限；具名成员另有upload角色。固定所有者和完整原快照摘要，写前重读拒绝并发覆盖。

`SYNO.Foto.Sharing.Passphrase` v1：set_shared(policy=album,album_id,enabled)；update以passphrase绑定原链接。公开权限为permission=[{action:update,role:view或download,member:{type:public}}]；仅受邀者删除public成员。分阶段关闭公开访问→保存变化→按需启用，部分成功不伪装事务。最终核对访问方式、成员、保护与期限；旧链接只在当前授权会话内使用。

password意图：未提供保留、空字符串清除、非空原值设置，不修剪空格/Unicode。本项目HTTPS路径使用官方普通password字段，不增加HTTP降级；非HTTPS密码协议仅作为[静态来源](photos-management.md#photos-advanced-management)保存。设置/替换需成功update回执与enable_password=true及其他预期字段；丢回执时原有true不能证明新密码生效。清除可由明确false确认。秘密不进入URL、日志或恢复记录。

expiration为非负整数Unix秒，0不限期，缺失/负数/非整数未知。只在明确改变时传：0清除、正数为所选本地日末；未变省略并保留原时分秒/夏令时语义。关闭分享时可修改配置但不自动启用；只有明确匹配回读才确认。具名成员结构、权限差量、照片请求与临时/冻结相册只维护于[高级管理](photos-management.md#photos-advanced-management)。

### 照片与目录移动复制

`Foto/FotoTeam.BackgroundTask.File` v1 move/copy，源命名空间固定；target_folder_id为目标，item_id和folder_id为整数数组，action=skip或overwrite取明确选择。不猜target_library/target_user_id。move的extra_info为JSON字符串：version=2、source_library=personal_space/shared_space；目录混选另含原父目录source_folder_ids。copy无该源目录上下文时省略extra_info。

跨空间移动仅个人→共享；复制可双向，实际个人服务和共享entry/management必须可用。源移动需manage，共享复制需view/download，目标需view及upload/manage。目录选择同空间同父目录，禁止根、重复、自身/后代及原父目录；跨空间不能仅凭同路径/编号判冲突。

回执task_info含id/create_time/total/target_folder，目标含id/owner_user_id（0为共享）。统一 `SYNO.Foto.BackgroundTask.Info` v1 get_status；没有FotoTeam.Info证据。缺目标回执可用list_user_task补查**已知taskID**，不按名称认领。目录混选total涉及后代，不能与顶层选择数比较。

done及计数合法后按具体action解释：skip策略不得报告覆盖；error/skip意味着部分结果，不能猜逐目录完成。同空间move再按原照片/目录id核对新目标；跨空间不假定旧id仍有效，以明确任务目标/所有者/完成数和当前权限确认。copy保留来源；未知不重发、不回退File Station。原件及目录删除独立见[删除定义](photos-management.md#photos-item-deletion)。

### 目录名称、封面和排序

- `Browse.Folder.rename` v1(id,name)：非根目录；非空、UTF-16长度≤255，拒绝纯空白、首尾点、NUL、路径分隔符/冒号及@database/@eaDir/@tmp/@sharebin/#recycle/#snapshot。写前固定id/原路径/parent/manage；回读同id、父目录及完整新路径，回执不能单独证明完成。
- set_cover v2：id为目标目录、id_item为单元素数组，照片来自目标或后代；目标manage和照片来源view分别检查，不能以下载权代替view。无清除封面动作证据。成功回执加Folder.get thumbnail和folder_cover_seq=0自定义图可读构成确认，**不是回读了所选item_id**；丢回执不凭图片变化认领。
- set_order v1(id,sort_by,sort_direction)，Folder.get v2读取。字段filename/filesize/item_type/takentime，asc/desc；缺省展示可分别使用Setting.User.item_sort_by/sort_direction，再按官方takentime/asc，但默认值不能证明保存成功。保存需目录view，不要求原件下载/manage。子目录Folder.list v2始终filename并用同方向，照片Item.list v4用固定排序、每页100。
- 结果仅更新原目录/后代路径、封面或当前分页，旧请求代次失效；不借目录操作改变其他空间/同编号相册。

### 共享目录权限

`SYNO.FotoTeam.Sharing.FolderPermission` v1，不能复用相册嵌套member：

| 方法 | 参数与结果 |
| --- | --- |
| get_folder_link | folder_id → folder_link，仅未共享且无现成链接时读取 |
| get_config / set_config | get无参数，set仅set_to_subfolder布尔变化；与权限update独立 |
| update | folder_id/privacy_type/set_to_subfolder，可选password及permission扁平数组 |
| FotoTeam.Browse.Folder.get v2 | id及sharing_info/access_permission/password_verified，核对身份/父共享状态与保护 |
| Foto.Sharing.Misc.list_user_group v1 | team_space_sharable_list=true；id/type/name，排除当前系统uid |

模式management/private/public-view/public-download；成员view/download/upload/manage。每个permission为{id,type,role,action}，变更集合中保留成员也发update、删除携原role、新增携新role；不发送auto_backup。未知字段/成员不当空名单。shared=false映射management。

官方仅前两层可编辑；根与更深层不提供入口，第二层父目录必须已共享。第一层可应用子目录。核对共享management、管理员启用分享条件、父目录、原完整快照与权限降低后果；不能由DSM管理员身份替代Photos权限。先update，只有默认子目录选项改变才set_config，再回读；顶层匹配不能证明每个后代已应用。密码沿HTTPS保护及成功回执/状态规则，未知不重放。

### 重复项及用户偏好

`photos-duplicate-settings`：`SYNO.Foto.Setting.User.get/set` v1；upload_default_action=ignore/rename，copy_move_default_action=skip/overwrite。仅差量、原快照比较与结果回读；修改默认不改变既有队列，覆盖需明确后果。上传action=ignore只在原请求ignore且id有效时接受，按返回id/原文件名/目标回读，可与待上传大小不同；completedCount=0并计skipped，不伪装新上传。相册加入单独处理。

`photos-display-settings`：User get/set v1。timeline_group_unit=day/month；time_format为12/24字符串；item_sort_by=filename/filesize/item_type/takentime；sort_direction=asc/desc；show_item_info_in_lightbox布尔。date_format为年/月/日三种顺序与- / .三种分隔符组合，协议小写yyyy，不能用周所属年YYYY。只写变化字段，完整原快照及明确字段回读；目录/相册显式排序优先，不改变原件和授权。

`photos-recognition-settings`：User get/set v1及Admin.get v1，enable_person/enable_concept/enable_similar在两侧均明确且个人空间启用、全局true时可编辑。未知不能补false；只写个人变化，禁止借共享空间修改全局。关闭识别的长期NAS索引行为未验证。自动预览不仅是auto_generate_thumbnail布尔，完整协议见[高级管理](photos-management.md#photos-advanced-management)。

### 相册顺序与列表偏好

Album.get v4 / set_order v1(id,sort_by,sort_direction)：filename/filesize/takentime/item_type、asc/desc。实际查看权限即可，不推定上传或原件管理权；保存比较原偏好、回读明确字段，相册项目仍统一Foto.Item.list且保留album_id。

Album.get/set_album_list_order v2：album_list_sort_by/direction、shared_with_me_sort_by/direction、shared_with_others_sort_by/direction，保存只发所选范围两字段。首页允许album_name/album_type/start_time/create_time/share_status；分享范围允许album_name/album_type/start_time/share_modify_time，均asc/desc。
Album.get/set_album_list_display v3：album_display_type=all_album/my_album；对应Album.list v4 category=normal_share_with_me/normal。与我共享为Sharing.Misc.list_shared_with_me_album v2；与他人共享Album.list category=shared，默认share_modify_time/desc。照片请求列表不使用这些偏好。未知偏好不得写默认值回NAS。

### 旋转与贡献者角色

Item.set v2(id,rotate_action=counter_clockwise)，回读Item.get v5。排除未准备好的图片、video/video360/photo360/GIF/WebP；逆时针orientation映射1→8、2→5、3→6、4→7、5→4、6→1、7→2、8→3。相册个人项目检查本人provider和个人服务；共享相册需MANAGE，其他照片使用原件管理权限。

[10-07静态证据](../environments/INDEX.md#2026-10-07-photos-rotation-observation)区分网页布局交换与原始resolution：有明确成功回执时仍核对原身份/权限及预期方向，分辨率允许原值或交换值，其他尺寸不能确认。丢回执只读恢复沿严格判定，不推断成功、不重发非幂等旋转。原件字节/大小是否改变未验证，不能放宽身份校验。

以上当前参数定义不维护平台施工日志。平台实现及本地恢复格式见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)，真实NAS验证和已知代码缺口见[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。后台任务统一见[任务中心](photos-library.md#photos-background-tasks)，更复杂相册/人物/主题/预览协议见[高级管理](photos-management.md#photos-advanced-management)。

<a id="photos-advanced-management"></a>
<a id="photos-condition-albums"></a>
<a id="photos-people-management"></a>
<a id="photos-request-management"></a>
<a id="photos-preview-regeneration"></a>
<a id="photos-concept-visibility"></a>
<a id="photos-automatic-preview"></a>
<a id="photos-shared-space-settings"></a>
<a id="photos-shared-space-members"></a>
<a id="photos-global-settings-cache"></a>
<a id="photos-library-maintenance"></a>
## Photos 高级相册、识别、预览与设置


稳定端点：`photos-condition-albums`、`photos-people-management`、`photos-request-management`、`photos-preview-regeneration`、`photos-concept-visibility`、`photos-automatic-preview`、`photos-shared-space-settings`、`photos-shared-space-members`、`photos-global-settings-cache`、`photos-library-maintenance`；协作及临时/冻结相册沿用photos-sharing-management/photos-album-management/photos-upload。

来源为[2026-09-28起](../environments/INDEX.md#2026-09-28-photos-parity-observation)及[10-01](../environments/INDEX.md#2026-10-01-photos-remaining-observation)已登录官方页面加载的react_bundle.js，DSM/套件完整版本未知。以下均为内部接口与static证据，不冒用lab-a，不把客户端实现或合成测试升级为真实写验证。路径由API.Info发现；除multipart与事件通道外，POST表单内JSON业务值。通用安全规则见[通用标准](../../reference/common.md)。

### 条件相册

`SYNO.Foto.Browse.ConditionAlbum`：create/get/list/set_condition/suggest/peek_item_count v3，count v1。个人、共享来源均使用此统一相册API。

- create(name,condition)返回data.album.id；set_condition(id,condition)，名称另走Album.set_name v1，不能假设两步事务。
- get(id整数数组,additional=[condition_object])返回list[].additional.condition_object；peek_item_count(condition)返回count。
- suggest(keyword,user_id,condition字段名数组,additional=[thumbnail])返回各字段建议；地点children递归并保留父编号，建议显示名称不参与请求。

| condition字段 | 值与编码 |
| --- | --- |
| user_id | 个人当前UserInfo.id；共享0。个人需home服务，共享需management |
| item_type | 全部[]、照片[-1]、视频[-2]，不同于普通筛选0/1 |
| folder_filter | 所选来源目录编号数组，须实际可见 |
| time | 对象数组；start_time/end_time可独立省略，双端时开始不晚于结束 |
| rating、keyword | 评级数组、文件名/描述关键词字符串数组 |
| person/general_tag/concept | 编号数组；非空条件带对应_policy=and/or；keyword_policy同样and/or |
| camera/lens/aperture/iso/geocoding/flash | 建议id数组；flash无已证实的新建值域，保留已有条件或允许移除 |
| focal_length_group/exposure_time_group | 建议additional的start/end数组，精确类型沿建议结构，不猜值 |

condition_object中的已知引用对象（含rating/folder_filter）取id重编码；time/item_type/keyword/范围/flash保留结构。未知字段、空名引用与合法decimal/null不静默丢弃。已知集合规范化用于比较，未知值保持原样。写前确认相册所有者、来源和原条件，回读完整目标条件；创建无编号不按名称追认。条件相册不手工增删成员，普通相册归集另行处理。

### 分享成员与相册协作

基本分享、密码、有效期的唯一说明见[照片管理](photos-management.md#photos-management)。此处只补协作差异：

- `SYNO.Foto.Sharing.Misc.list_user_group` v1：相册邀请带team_space_sharable_list布尔；data.list含id/type/name，排除当前UserInfo.uid而不是id。permission回读为扁平成员字段，写入为{action:update,role,member:{type,id}}或{action:delete,member}，按type+id求差量，保留未改变成员。
- 普通相册具名role为view/download/upload，条件相册仅view/download；公开模式没有public-upload。权限无变化省略permission，不能把未知成员当空列表删掉。
- `SYNO.Foto.Sharing.Passphrase.get_permission` v1(passphrase,exclude_public)返回permission.download/upload；缺失不当允许，普通相册才可贡献。
- `SYNO.Foto.Browse.NormalAlbum.list` v1：category=addable、sort_by=album_name、sort_direction=asc、offset/limit、additional=[sharing_info,thumbnail]。可见不等于可添加。
- add_item/delete_item v1：所有者用id、贡献者用passphrase，item整数数组。error_list元素尚无实测固定结构，只保留明确失败；最终Item.list(album_id)逐项核对。贡献者移除须按相册上下文get确认provider_user_id为本人；所有者移出成员也不获得删除他人原件权限。
- `SYNO.Foto.Upload.Item.upload` v1相册multipart：file/duplicate/name/mtime/folder=["PhotoLibrary"]，所有者album_id或贡献者passphrase二选一；不发uploadDestination或target_folder_id。Item.get v5(id,album_id,additional含provider_user_id)核对编号/大小/贡献者；上传即为成员，不重复add_item。
- 跨相册添加以源album_id读详情、核对本人provider和原件身份，来源空间必须启用；混合来源要求两空间及共享管理条件。目标仍只传id/passphrase与item，不猜source_album_id。源拒绝不能绕回原空间，添加不删除源成员。

官方无链接分享弹窗可能调用set_shared(enabled=false)创建关闭链接；观察阶段不能把打开表单当成必然只读。官方非HTTPS分支使用`SYNO.API.Encryption.getinfo` v1(format=module)的cipherkey/public_key/ciphertoken/server_time及RSA/AES包装；本项目只接受HTTPS，沿官方HTTPS普通password字段，不新增HTTP降级或不可达加密实现。密码替换缺回执不能凭enable_password=true确认。

### 照片收集请求

`SYNO.Foto.PhotoRequest` create/update/delete/get/list v1。现行回读通过list按精确passphrase定位，不猜未确认的get响应。list(offset=0,limit=5000,可选keyword)返回list；投影包括passphrase/subject/description/library/folder_home_path/folder_id/album_id/album_passphrase/album_name/expiration/filesize_limit/is_folder_valid/sharing_link。

- create：passphrase默认空、subject修剪且≤50字符、description≤100、library=personal_space/shared_space、folder_home_path、filesize_limit、expiration；返回完整记录和sharing_link。丢回执不以同标题追认。
- 大小不限为0，否则1…3000MiB乘1048576；默认25MiB但限制未开启。期限不限0，否则本地日末Unix秒。
- 默认目录/PhotoRequest/<处理标题>可尚不存在；空白、首尾点、系统保留名或路径分隔符等非法名称片段替换下划线。个人home优先；仅共享management可自动选共享默认，entry必须明确选有UPLOAD的目录。改选后不再随标题联动，编辑旧请求不联动。
- 目标相册来自NormalAlbum.list addable；所有者用album_id，非所有者优先album_passphrase并省略album_id。清除相册发送album_id=-1，不能用UI的null。
- update仅差量；library和folder_home_path变化一起发送，目标字段互斥。delete传passphrase字符串数组，只删除收集请求，不推断删除已上传照片。
- 固定创建/更新原对象、上传目标与权限，分步回读；访问范围、收集副作用与非空响应仍需真实验证。

### 人物和手工人脸

`SYNO.Foto.Browse.Person`及共享FotoTeam对应接口：get/list/show/set/list_face/separate/set_cover/delete_face v1，merge v2，add_face v3。

| 方法 | 参数与结果 |
| --- | --- |
| set | id/name → id/name；空名且少于两张的分类变化不能仅本地改名 |
| merge | target_id、merged_id整数数组、name；按目标名称、来源消失和照片并集回读，不宣称人脸级等价 |
| list_face | person_id、item_id整数数组 → list[].id为face_id；逐照片关联，不猜响应照片字段 |
| separate | name、face_id数组；人物相册新人物target_id=0，图片内新人物省略target_id；既有人物传target_id |
| delete_face | person_id、face_id数组；移除识别关联，不删除照片 |
| set_cover | id/photo_id → id/name/cover/additional；cover不假设为照片ID，用Person.get核对明确回执 |
| show | id数组/show布尔；list(show_hidden=true并保留show_more)、get(id数组)回读每项show |
| Item.list_face | v6，id_item、additional=[thumbnail] → face_id/person_id/name/face_bounding_box |
| Person.add_face | v3，id_item、face数组；每项face_id_temp字符串、归一化top_left/bottom_right坐标，person_id或name二选一 |
| Upload.Face.upload | v1 multipart，face_id JSON数值、file JPEG；路由字段原始字符串，Foto/FotoTeam按来源 |

新增回执逐项face_id_temp→face_id映射后才上传裁剪图：按显示方向自然尺寸和归一化坐标裁剪，JPEG最大边256；官方新框为正方形、最小36显示像素。临时编号不作为tempFaceId发给上传。保存后Item.get(additional=[person])核对；不能只调用add_face省略缩略图。未知新增不按名称认领；部分回执只处理明确编号，新增/上传未确认前不能移除旧框。未发现修改原框坐标的独立方法，调整需新建并确认后移除旧识别记录，不能虚构set参数。

人物封面thumbnail有unit_id时type=unit，否则人物id/type=person；仅cache_key无尺寸状态时不传size。人脸缩略图type=face且不传size。固定人物/原件/人脸/权限快照，分离需原人物不再含该脸、目标照片仍含同脸且名称匹配。共享需实际management及识别开关；相册手工人脸按本人provider/共享MANAGE，不从贡献角色推定原件删除权。

### 主题

`photos-concept-visibility`：Foto/FotoTeam.Browse.Concept.list/get/set_visibility v2；set_cover/hide_item v1。list(offset,limit,show_hidden=true,additional=[thumbnail])、get(id数组,additional)返回id/name/item_count/visibility及thumbnail，visibility须布尔。

set_visibility(id数组,visibility)只改分类显示；set_cover(id,photo_id)按get.thumbnail.unit_id核对；hide_item(id,item_id数组)只移出主题，原件保留。必须完整成员分页证明选择归属并读取实际display_threshold；低于阈值可能隐藏分类，不能当原件消失。写后分类/成员计数与每张原件身份共同核对，当前页缺席或空回执不够。共享需management及enable_concept，未知不重发。

### 手动预览重建

`photos-preview-regeneration`：Foto/FotoTeam.RegeneratePreview.set_regenerating/regenerate_preview_by_nas/list_regenerating/restore_from_regenerating均v1。

- set_regenerating(item_id数组)返回list的unit_id/type/filename；list_regenerating无参数。同一来源的unit身份不同于Item编号。
- 先订阅匹配单元事件，再regenerate_preview_by_nas(unit_id单整数)；接口接受不代表完成，匹配事件data.idUnit/data.success后再回读。
- 官方通道为当前Photos应用目录下FotoSocketIo/socket.io、WSS/Engine.IO4；Socket.IO事件regenerate-preview载荷{idUnit,operation:"register"}，不是外层嵌套data。官方握手保留查询SynoToken机制，原生同源WSS/Cookie和既有证书规则；完整URL及含URL错误不得日志化，部署目录不能硬编码为根。
- restore_from_regenerating(unit_id数组)是写入，仅所有转换方式明确失败后使用；未知通知/回执不无条件恢复、不重发。空list或任务消失不能证明此前完成。
- 手动恢复need_thumbnail=true、need_video=false。JPEG按外部→NAS→浏览器，PNG按浏览器→外部→NAS，其他格式按官方集合；GIF/WEBP无手动重建策略。
- Foto/FotoTeam.Upload.ConvertedFile.upload v3 multipart含unit_id及实际输出thumb_xl/thumb_sm/thumb_m/film_h264。手动只生成三档JPEG质量0.9，短边至多1280/240/320，小图不放大、不裁方形、保留显示方向，不生成完整视频。
- 本机转换与NAS重建是不同路径；只有明确失败可转其他方式，网络/畸形回执保持未知。处理前后核对原件和权限，随机受保护临时目录收尾清理。

资格按具体上下文：共享download入口与共享guest_download不同；相册本人provider可能有重建入口，普通下载角色不自动拥有。冻结网格单/多选有REGENERATE_PREVIEW，冻结预览菜单没有；不能据预览菜单建立Repository全局冻结禁令。静态菜单只描述入口，不直接证明NAS最低写权限，仍核对来源、相册与原对象。

### 自动预览

个人开关为 `SYNO.Foto.Setting.User.get/set` v1 的 `auto_generate_thumbnail`，必须为布尔；读取缺字段明确失败，不补false。写前核对原值，保存仅发送变化的该字段，get回读一致才确认；提交后断网或结果未知只复查，不自动重发。开关不代表本机具有转换器或系统后台执行资格。

`photos-automatic-preview`，Foto/FotoTeam.Upload.ConvertedFile.list_convert_needed/upload/set_broken均v3。后台扫描共享需management，可见原件可按实际view+download及身份读取，二者不能混为同一权限。

- list_convert_needed不分页；type=[photo,video,live_video]，无HEVC只video，HEVC和视频能力均无不扫描。请求preset字符串按HEVC+VC1→windows、无HEVC且有VC1→windows2、其余macos选择，与type数组一同发送。data.list含unit_id/filename/type/need_thumbnail/need_video；type=0照片、非0视频，需求布尔或0/1为客户端接受范围，实际NAS类型未验。
- 独立Download.download v2(unit_id数组)取原件；按需求产生三档缩略图和/或H.264/AAC MP4，upload v3用thumb_*及film_h264。不是临时文件名，也不把任务unitID当Item。自动不先set_regenerating，手动恢复队列身份独立。
- 可见候选来自Item.get v5 additional=[thumbnail,video_meta,video_convert]的真实状态，以及Unit.get v1展开实况；不请求video_convert_status这个前端字段名作为additional。xl/sm=ame_defect或实际video_convert_status=ame_defect才候选；固定原profile/space/item/unit/owner和权限，提交后身份回读不再要求状态仍缺陷。
- 上传明确success=true且无error可确认；明确拒绝与传输/解码/取消未知分开。未知只读核对原输出，不能凭候选从有限批次消失认定成功。
- 客户端恢复策略（未被NAS实测证明）：三档Thumbnail空cache_key禁缓存比SHA256；视频Streaming v2(id=unitID,type=unit,quality=orig_h264,use_mov=true)比编码样本/轨道/时长/方向，允许重封装，不能只比大小/时长。film_h264→orig_h264绑定与空cache_key行为仍未验证，内容不符只保留未知，不重传。
- thumbnail-update事件注册unit_id数组/is_team，注销unit_id；返回thumbnail.unit_id及xl/m/sm等状态，仅能证明缩略图变化，不能证明完整视频完成。
- set_broken(id=[unitID],type=[photo]或[video])仅在确定媒体读取/编码失败且身份权限仍有效时使用。取消、断网、缺编码器、资源不足、撤权或未知上传不能标坏。回执未知时有sourcePhoto才读取真实thumbnail.xl/sm或video_convert_status=broken；UI默认broken/缺字段不算证据，纯后台unit无直接状态查询不能猜Item编号。
- 状态候选broken/ame_defect/converting/ready/regenerating/space_disable/none来自静态枚举，未知值不能补为完成。

官方调度静态依据：手动→普通1→HEVC视频2→VC1/wmv3视频3→后台4，同级当前/next/prev；可见阈值0.8，2秒去抖，后台空闲5秒扫描。相邻后3/前2，不足4仅后第一、正好4去后末、不足6仅前最后；先缩减再排除相邻视频，不能补找超范围。目录/相册循环、时间线不加载未知月份。实际平台后台执行范围另见矩阵，不能由该算法宣称系统后台能力。

### 共享空间与全局设置

`photos-shared-space-settings`：UserInfo.me、Setting.User/Admin/TeamSpace get/set及TeamSpace.set_enable均v1。共享管理页要求真实DSM is_admin，不以Photos management替代；共享访问仍独立检查。

TeamSpace.get含enabled/allow_root_folder_public及可选enable_person/concept/similar；User.home/role与Admin全局开关共同决定可编辑项。TeamSpace.set只发变化字段，enabled用独立set_enable；不允许关闭个人未启用时的最后空间。team_space_disabled_by_share_folder_disabled可说明恢复路径，但不能由原因字段额外禁止官方允许的启用尝试。写前完整原快照/身份比较，最后读写仍有竞态，无条件更新参数不伪装原子保存。

`photos-global-settings-cache`：Admin get/set v1含enable_person/concept/similar/user_sharing、display_photo_info_to_guest、enable_converted_original_jpeg布尔与exclude_extension字符串数组；need_hevc不进入普通保存。全局识别关闭联动User/Team对应已知字段false，重新开启不自动开启两空间。User.ame_status.has_hevc为原尺寸JPEG条件，不安装NAS软件。

`SYNO.Foto.Download.clear_cache/get_cache_status/calculate_cache_size`均v2、无参数，统一Foto路由。status=processing表示处理中，其余终态完整枚举未知；cache_size非负字节数。关闭原尺寸JPEG先清缓存，失败停止后续设置，逐步追踪缓存/全局/个人/共享而非事务。明确清理回执加结束状态可允许新缓存产生；无回执要求非processing且0大小才可按现策略核对，仍有并发归因限制。

排除格式保留未知原值和大小写，允许移除，不猜新格式；官方候选为JPG JPEG JPE WEBP BMP PNG GIF TIF TIFF HEIC HEIF HIF ARW SRF SR2 DCR K25 KDC CR2 CR3 CRW NEF MRW PTX PEF RAF 3FR ERF MEF MOS ORF RW2 DNG X3F RAW MPG MPEG AVI ASF WMV MOV FLV F4V MP4 DIVX XVID M2TS M2T MTS M4V 3GP 3G2 QT，比较时不把数组顺序当内容变更。

### 共享成员与目录

`photos-shared-space-members`：TeamSpace.list_permission v1无参数，data直接为数组，非list容器；type/id/name/permission/auto_backup。update_permission v1(list数组)每项action=update/delete、type=user/group、id、permission=entry/management、auto_backup；删除携原角色/备份值。候选Misc.list_user_group v1此用途无参数，包含本人，不能沿相册邀请过滤。

management自动备份true且不可单独关闭，entry新增false、从management降级保留原值；系统group/administrators保护不编辑。管理员身份及TeamSpace.enabled重新核对。成员entry配置与目录权限多阶段，不假设事务或自动撤销未知授权。

FotoTeam.Browse.Folder.get v2无参数取共享根；list v2(id,offset,limit,filename/asc,additional=[sharing_info])初始200并继续分页。只编辑根下两层；按type+原始id类型匹配直接角色，不推导群组成员，public-view/download是下限；第二层父目录无公开或直接权限时不可编辑。

FotoTeam.Sharing.FolderBatchPermission v1：
- update_by_member：permission={id,type,list:[{folder_id,role,action:update}|{folder_id,action:delete}]}，delete不传role。
- update_all_by_member：permission={role,action,member:{id,type}}，action=check_all/uncheck_all；角色view<download<upload<manage。全选只提升低于目标项，取消降低达到该层者到前一层，不是全部赋相同值。
- 全局批量先于逐目录差量；降低父目录查看需说明子目录影响。未知阶段只回读成员与目录，不补发；顶层结果不能证明所有后代传播或部分失败均已验证。

### 图库维护与新格式提示

`photos-library-maintenance`：Foto/FotoTeam.Index.get/reindex v1。get无参数，data计数basic/metadata/thumbnail/geo_coding/face_extraction/person_clustering/concept_detection；当前必需basic/thumbnail非负整数。reindex(type=basic/thumbnail)作用当前空间，无任务ID；thumbnail需User.ame_status.has_h264，不是本机HEVC。个人需home，Shared需启用空间、DSM管理员及实际访问。

提交前固定身份/空间/动作与空闲原计数。明确接受且对应计数归零只证明该索引阶段无待处理，不证明全部识别/后台完成；丢回执不能以计数正数到零归属于本次操作，持续未知只读，不重发。

Setting.Wizard.get/set v1：data.prompt数组name/show；仅new_codec_installed=true提示，set只发prompt=[{name:new_codec_installed,show:false}]。生成用管理员Foto.Index.reindex_all_user v1(type=thumbnail)，普通用户个人reindex；全用户无可归因终态，不用个人计数证明全完成。客户端先取得生成接受再清提示；稍后只清提示。生成已接受而清提示失败可仅继续后一步，不能再生成。

### 临时分享与冻结相册

NormalAlbum.create v1(name,item,shared=true)与普通相册不同；Album.get v4读取temporary_shared/shared/sharing_info。停止临时分享先Passphrase.set_shared(enabled=false)，再Album.delete v1(id数组)，不可误删普通相册。保留副本用NormalAlbum.copy v1(name,source_album_id)，明确新album.id且成员回读完成后才停止旧分享；无回执不猜新副本。

冻结标记freeze_album来自Album列表，不能从type=condition推定。Album.get v4 additional=[condition_object]读取cant_migrate_condition、condition_object；不可迁移提示键顺序recently_add/recently_comment/update_time/people/geocoding/rating/camera/lens/flash，未知键不当已迁移。
- condition_object仅user_id=0时只可保存普通相册，NormalAlbum.set_unfreeze v1(id单整数)后核对冻结状态/成员。
- 条件重建以原名称和受支持条件调用ConditionAlbum.create v3，cant_migrate_condition仅提示、不并入新condition。明确新编号及结果后才Album.delete旧编号；删除失败保留新旧身份，不抄网页吞错乐观移除。
- 不推定继承原分享链接或成员。冻结限制手工成员增删/上传，但不能一概禁止重命名、既有分享管理、封面、加入其他相册、旋转；网格与预览资格分别判断。

[Synology升级功能变化说明](https://kb.synology.com/en-global/DSM/tutorial/What_functions_have_changed_after_Photo_Station_Moments_upgraded_to_Photos)当时仅取得搜索索引摘要，直接页面是外壳；只能支持解冻/保留普通相册这两条产品语义，不能补足字段类型或行为证据。

### 证据与平台范围

字段和请求之外的原生入口、后台调度、持久恢复及设备能力只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。上述客户端核对策略与官方静态线索分别标注；未知版本、权限、非空响应和真实副作用不能用合成通过代替。

<a id="photos-item-deletion"></a>
## Photos 原件与目录删除


端点组：`photos-item-deletion`；内部接口，风险 critical。个人和共享来源分别使用 Foto / FotoTeam，禁止以 File Station 删除替代。

### 请求与完成条件

- `BackgroundTask.File.delete` v1，POST，JSON 业务值装入表单；`item_id` 与 `folder_id` 均为整数数组。单张照片传单元素 item_id 与空 folder_id；混选传固定照片和目录编号。
- 返回 `data.task_info.id`。使用统一 `SYNO.Foto.BackgroundTask.Info.get_status` v1、`id=[任务编号]` 查询同一任务；共享任务也不改用 FotoTeam.Info。
- 已观察单张删除初态为 waiting、completion=0、total=1，终态 done、completion=1、total=1、error=0、skip=0。接受回执或任务消失均不单独证明原件删除。
- 单张照片必须以同空间 `Browse.Item.get` v5 的成功空 list 确认不存在；权限拒绝、解析失败或非空结果不能当成功。
- 混选需任务 done 且 error/skip/overwrite 为零，再回读原父目录身份和访问权、完整分页确认目标目录不再列出，照片逐项成功空回读。目录读取按100条分页，重复页或错误父编号拒绝；不声称直接验证所有后代文件。
- `Browse.Folder.delete` 静态 helper 不是官方主界面的混选流程，不能替代上述任务接口。

### 身份、权限与不确定结果

预检固定 profile/账号/空间/照片编号、文件名、大小、拍摄和索引时间、目录、媒体类型；读取最小身份，不依赖 EXIF、地址或转换详情。写前重新核对目录 view/manage；共享 entry 需要实际目录管理权，upload 不等于删除权。管理角色只在相应共享范围生效。

目录必须非根、同一空间与父目录，有完整原始路径/父编号，目标不能重复；混选照片位于该父目录且无相册上下文。确认明确目录全部内容及相册引用受影响，恢复取决于 NAS 配置。能力、权限、确认、去重与结果处理遵循[通用标准](../../reference/common.md)，不按精确 DSM/Photos 版本白名单决定入口。

同一操作标识绑定固定目标且只提交一次。明确 DSM 105/106/107/119 拒绝与 117、网络中断、畸形回执、提交后取消的未知结果区分；未知只读查询原目标，不重发，不按名称认领新对象。取消未提交项目不回滚已提交项。任务存在 skip/error 时保留部分结果，没有逐目录结果就不能猜测哪些目录已删除。

完成只移除已确认目标并修正原查询分页，保留月份/目录与选择；旧分页响应不能使已删除目标重现。若当前目录被删，返回存活父目录。恢复是否跨进程属于平台实现范围，不能由 NAS 任务能力推断。

### 证据与范围

[2026-09-10 记录](../environments/INDEX.md#2026-09-10-photos-deletion-observation)在 DSM 7.2.1-69057 Update12 / Photos1.8.2-10090 对唯一合成 PNG 单次删除、任务完成和刷新后空回读提供 behavior-verified；设备归属未知。共享删除、目录混选、断网/重启与其他版本没有因此通过。共享命名空间与混选流程为官方脚本 static 证据。

当前实现与未完成验证只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
