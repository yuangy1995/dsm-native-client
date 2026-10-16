# Photos 照片、相册与目录管理

稳定端点：`photos-item-metadata`、`photos-album-management`、`photos-file-management`、`photos-upload`、`photos-sharing-management`、`photos-duplicate-settings`、`photos-display-settings`、`photos-recognition-settings`。

均为内部API。当前参数来自[2026-09-28起官方静态资源](../environments/INDEX.md#2026-09-28-photos-parity-observation)，完整版本未知；除单独登记的受控场景，不宣称真实写入通过。API/path/版本须发现；JSON业务值通过POST表单编码，上传为multipart。通用身份、权限、确认、去重和未知只读规则见[通用标准](../../reference/common.md)。

## 命名空间与原件编辑

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

混合来源评级、绝对/相对日期与预览重建按来源分别预检和提交，逐项保存结果；标签与混合相册移动不由该能力推导。相册内个人项目以provider_user_id判断本人贡献、实际个人服务权限；共享相册项目要求全空间MANAGE。普通相册与条件/冻结相册的原件权限路径分开，不能把owner当provider。精确协作角色见[高级管理](photos-advanced-management.md)。

## 上传与目录创建

`Foto/FotoTeam.Upload.Item` v1：

- upload_to_folder：multipart file、duplicate、name、mtime（秒）、target_folder_id。
- upload：file、uploadDestination=timeline、duplicate、name、mtime、folder=["PhotoLibrary"]。
- 非文件业务字段JSON编码；凭据只在既有请求头/受保护正文。临时文件权限0600，结束删除。
- 回执必须提供明确项目编号；同空间Item.get核对大小、目标目录和相册provider。缺编号不按名称猜测、不自动重传。
- 多文件逐项提交，固定来源文件摘要、目标和operationID；切换图库不改变队列目标。目录缓存仅当前批有效。
- `Browse.Folder.create` v1(target_id,name)返回folder.id；Folder.get v2(id,additional=[access_permission])核对父编号、名称和权限。目录创建未知就停止依赖步骤，部分成功不自动删除已建目录。
- 共享entry上传需view且upload或manage；management按共享目录规则；不借个人API处理共享编号。
- 相册直接上传与先上传再add_item是不同路径；相册上下文、passphrase和贡献者规则统一见[高级管理](photos-advanced-management.md)，加入失败不能重复文件上传。

## 分享、密码与有效期

读取Album.get v4 additional=[sharing_info]不创建链接。shared=false表示关闭；已共享模式区分private/public-view/public-download，未知不当关闭。公开upload不属于普通相册权限；具名成员另有upload角色。固定所有者和完整原快照摘要，写前重读拒绝并发覆盖。

`SYNO.Foto.Sharing.Passphrase` v1：set_shared(policy=album,album_id,enabled)；update以passphrase绑定原链接。公开权限为permission=[{action:update,role:view或download,member:{type:public}}]；仅受邀者删除public成员。分阶段关闭公开访问→保存变化→按需启用，部分成功不伪装事务。最终核对访问方式、成员、保护与期限；旧链接只在当前授权会话内使用。

password意图：未提供保留、空字符串清除、非空原值设置，不修剪空格/Unicode。本项目HTTPS路径使用官方普通password字段，不增加HTTP降级；非HTTPS密码协议仅作为[静态来源](photos-advanced-management.md)保存。设置/替换需成功update回执与enable_password=true及其他预期字段；丢回执时原有true不能证明新密码生效。清除可由明确false确认。秘密不进入URL、日志或恢复记录。

expiration为非负整数Unix秒，0不限期，缺失/负数/非整数未知。只在明确改变时传：0清除、正数为所选本地日末；未变省略并保留原时分秒/夏令时语义。关闭分享时可修改配置但不自动启用；只有明确匹配回读才确认。具名成员结构、权限差量、照片请求与临时/冻结相册只维护于[高级管理](photos-advanced-management.md)。

## 照片与目录移动复制

`Foto/FotoTeam.BackgroundTask.File` v1 move/copy，源命名空间固定；target_folder_id为目标，item_id和folder_id为整数数组，action=skip或overwrite取明确选择。不猜target_library/target_user_id。move的extra_info为JSON字符串：version=2、source_library=personal_space/shared_space；目录混选另含原父目录source_folder_ids。copy无该源目录上下文时省略extra_info。

跨空间移动仅个人→共享；复制可双向，实际个人服务和共享entry/management必须可用。源移动需manage，共享复制需view/download，目标需view及upload/manage。目录选择同空间同父目录，禁止根、重复、自身/后代及原父目录；跨空间不能仅凭同路径/编号判冲突。

回执task_info含id/create_time/total/target_folder，目标含id/owner_user_id（0为共享）。统一 `SYNO.Foto.BackgroundTask.Info` v1 get_status；没有FotoTeam.Info证据。缺目标回执可用list_user_task补查**已知taskID**，不按名称认领。目录混选total涉及后代，不能与顶层选择数比较。

done及计数合法后按具体action解释：skip策略不得报告覆盖；error/skip意味着部分结果，不能猜逐目录完成。同空间move再按原照片/目录id核对新目标；跨空间不假定旧id仍有效，以明确任务目标/所有者/完成数和当前权限确认。copy保留来源；未知不重发、不回退File Station。原件及目录删除独立见[删除定义](photos-item-deletion.md)。

## 目录名称、封面和排序

- `Browse.Folder.rename` v1(id,name)：非根目录；非空、UTF-16长度≤255，拒绝纯空白、首尾点、NUL、路径分隔符/冒号及@database/@eaDir/@tmp/@sharebin/#recycle/#snapshot。写前固定id/原路径/parent/manage；回读同id、父目录及完整新路径，回执不能单独证明完成。
- set_cover v2：id为目标目录、id_item为单元素数组，照片来自目标或后代；目标manage和照片来源view分别检查，不能以下载权代替view。无清除封面动作证据。成功回执加Folder.get thumbnail和folder_cover_seq=0自定义图可读构成确认，**不是回读了所选item_id**；丢回执不凭图片变化认领。
- set_order v1(id,sort_by,sort_direction)，Folder.get v2读取。字段filename/filesize/item_type/takentime，asc/desc；缺省展示可分别使用Setting.User.item_sort_by/sort_direction，再按官方takentime/asc，但默认值不能证明保存成功。保存需目录view，不要求原件下载/manage。子目录Folder.list v2始终filename并用同方向，照片Item.list v4用固定排序、每页100。
- 结果仅更新原目录/后代路径、封面或当前分页，旧请求代次失效；不借目录操作改变其他空间/同编号相册。

## 共享目录权限

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

## 重复项及用户偏好

`photos-duplicate-settings`：`SYNO.Foto.Setting.User.get/set` v1；upload_default_action=ignore/rename，copy_move_default_action=skip/overwrite。仅差量、原快照比较与结果回读；修改默认不改变既有队列，覆盖需明确后果。上传action=ignore只在原请求ignore且id有效时接受，按返回id/原文件名/目标回读，可与待上传大小不同；completedCount=0并计skipped，不伪装新上传。相册加入单独处理。

`photos-display-settings`：User get/set v1。timeline_group_unit=day/month；time_format为12/24字符串；item_sort_by=filename/filesize/item_type/takentime；sort_direction=asc/desc；show_item_info_in_lightbox布尔。date_format为年/月/日三种顺序与- / .三种分隔符组合，协议小写yyyy，不能用周所属年YYYY。只写变化字段，完整原快照及明确字段回读；目录/相册显式排序优先，不改变原件和授权。

`photos-recognition-settings`：User get/set v1及Admin.get v1，enable_person/enable_concept/enable_similar在两侧均明确且个人空间启用、全局true时可编辑。未知不能补false；只写个人变化，禁止借共享空间修改全局。关闭识别的长期NAS索引行为未验证。自动预览不仅是auto_generate_thumbnail布尔，完整协议见[高级管理](photos-advanced-management.md)。

## 相册顺序与列表偏好

Album.get v4 / set_order v1(id,sort_by,sort_direction)：filename/filesize/takentime/item_type、asc/desc。实际查看权限即可，不推定上传或原件管理权；保存比较原偏好、回读明确字段，相册项目仍统一Foto.Item.list且保留album_id。

Album.get/set_album_list_order v2：album_list_sort_by/direction、shared_with_me_sort_by/direction、shared_with_others_sort_by/direction，保存只发所选范围两字段。首页允许album_name/album_type/start_time/create_time/share_status；分享范围允许album_name/album_type/start_time/share_modify_time，均asc/desc。
Album.get/set_album_list_display v3：album_display_type=all_album/my_album；对应Album.list v4 category=normal_share_with_me/normal。与我共享为Sharing.Misc.list_shared_with_me_album v2；与他人共享Album.list category=shared，默认share_modify_time/desc。照片请求列表不使用这些偏好。未知偏好不得写默认值回NAS。

## 旋转与贡献者角色

Item.set v2(id,rotate_action=counter_clockwise)，回读Item.get v5。排除未准备好的图片、video/video360/photo360/GIF/WebP；逆时针orientation映射1→8、2→5、3→6、4→7、5→4、6→1、7→2、8→3。相册个人项目检查本人provider和个人服务；共享相册需MANAGE，其他照片使用原件管理权限。

[10-07静态证据](../environments/INDEX.md#2026-10-07-photos-rotation-observation)区分网页布局交换与原始resolution：有明确成功回执时仍核对原身份/权限及预期方向，分辨率允许原值或交换值，其他尺寸不能确认。丢回执只读恢复沿严格判定，不推断成功、不重发非幂等旋转。原件字节/大小是否改变未验证，不能放宽身份校验。

## 证据与实现范围

以上当前参数定义不维护平台施工日志。平台实现及本地恢复格式见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)，真实NAS验证和已知代码缺口见[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。后台任务统一见[任务中心](photos-background-tasks.md)，更复杂相册/人物/主题/预览协议见[高级管理](photos-advanced-management.md)。
