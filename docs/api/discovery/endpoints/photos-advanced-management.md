# Photos 后续管理接口静态证据

## 范围与环境

2026-09-29 从已登录官方 Photos 页面实际加载的 `react_bundle.js` 读取；环境沿用 `../environments/2026-09-28-photos-parity-observation.md`。DSM/build/Photos 完整版本仍未知，不绑定历史设备基线。仅提取官方代码中的参数和字段；未执行这些写操作，等级均为 **static**，不是 observed 请求或 behavior-verified。

稳定分组：`photos-condition-albums`、`photos-people-management`、`photos-request-management`、`photos-preview-regeneration`。高级分享沿用 `photos-sharing-management`；目录创建沿用 `photos-file-management`。均为 internal、mixed、高风险（分享为 critical）；路径通过 SYNO.API.Info 发现，候选 `/webapi/entry.cgi`，POST 表单内 JSON 业务参数，认证沿用会话头，不记录其值。

## 条件相册

`SYNO.Foto.Browse.ConditionAlbum`：create/get/list/set_condition/suggest/peek_item_count 均 v3，count v1。

- create：`name:String,condition:Object`；返回 `data.album`，官方使用 album.id。
- set_condition：`id:Int,condition:Object`；编辑名称另调用 Album.set_name v1。两阶段写入需分别核对，不把第一步成功当作全部成功。
- get：`id:[Int],additional:["condition_object"]`，返回 `data.list[].additional.condition_object`。
- peek_item_count：`condition:Object`，读取 `data.count`。
- suggest：`keyword:String,user_id:Int,condition:[字段名],additional:["thumbnail"]`；建议对象的完整响应类型尚未观察。官方默认字段为 aperture、camera、exposure_time_group、focal_length_group、general_tag、geocoding、iso、lens、person、concept。

condition 构造：

| 字段 | 官方构造 |
| --- | --- |
| user_id | 个人空间为当前 UserInfo 用户编号；共享空间为 0 |
| item_type | 全部 `[]`，照片 `[-1]`，视频 `[-2]`；不能套用普通筛选的 0/1 |
| folder_filter | 可选目录编号数组 |
| time | 可选对象数组，当前表单生成单个对象；start_time/end_time 可独立省略，双端存在要求开始不晚于结束 |
| rating | 可选评级数组 |
| keyword | 字符串数组，对应文件名/描述 |
| person/general_tag/concept | 编号数组，每个非空条件同时带对应 `_policy`，值仅 and/or |
| keyword_policy | and/or |
| camera/lens/aperture/iso/geocoding/flash | 从所选建议提取 id 数组；flash 具体值域仍需核对 |
| focal_length_group/exposure_time_group | 从建议 additional 提取 `{start,end}` 数组；准确值类型须与建议响应核对，不猜测 |

回读 condition_object 的 folder_filter、person、general_tag 等引用字段是包含 id/name 的对象列表，官方编辑器按 id 再编码；time、item_type、keyword、焦距/曝光范围和 flash 原样保留。缺失名称的引用及空名称人物在旧条件迁移中有特殊处理，不得静默丢弃用户已有规则。

权限：创建个人条件源须核对个人访问与引用目录；修改须核对相册所有者和条件源。未知创建回执不按名称追认或重建。功能按实际 v3 能力开放，无人工验证白名单；不支持/错误仅影响本功能。未有最终字段归一化及非空回读行为验证。

## 高级分享（补充原分组）

- 现状通过 Album.get v4 additional=[sharing_info]：读取 shared，sharing_info 的 passphrase、privacy_type、sharing_link、permission、enable_password、expiration。
- 官方打开分享弹窗时，如果不存在 sharing_link，会先 set_shared(policy=album,album_id,enabled=false) 获取关闭状态的链接。这仍是写操作，后续发现不再次打开无链接的相册分享弹窗；不能把“未按保存”直接等同于完全无写入。
- Sharing.Misc.list_user_group v1：`team_space_sharable_list:Bool`；返回 list，包含 id/type/角色候选所需字段，完整非空类型待核对。网页从候选排除当前 uid。
- Passphrase.get_permission v1：passphrase、exclude_public，返回结构未补齐。
- Passphrase.update v1：passphrase，permission 数组。具名成员 `{type,id}`；更改/新增 `{action:"update",role,member}`，移除 `{action:"delete",member}`。public 同理，private 通过删除 public 成员实现。
- 具名成员的普通相册角色 view/download/upload，条件相册仅 view/download；共享目录还有 manage。公开链接转换 exB 仅支持 private/public-view/public-download，不能从常量推导 public-upload。不得把普通相册 upload 角色用于条件相册。
- 修改密码仅在用户更改时发送 password，未改变时完全省略；清除为默认空字符串。官方 mr 调用明确指定 encryption=["password"]，需要复用并核实 DSM 加密机制，不能直接照搬普通表单明文参数。
- expiration 仅在修改时发送；默认 0。日期转 Unix 单位与日界语义尚需检查。
- 现有基础分享不会发送这些新字段。高级权限必须以读取的原成员快照计算增删改并回读，不得将未展示成员意外删除。公开分享未进行实测。

## 人物整理

`SYNO.Foto.Browse.Person`（共享空间对应 FotoTeam 前缀）：set v1、merge v2、separate v1、set_cover v1、delete_face v1、add_face v3、list_face v1、get/list v1。

- set：`id,name`，返回 id/name。空名且人物照片少于两张时官方额外提示并重新加载，不能仅做本地名称替换。
- merge：`target_id,merged_id:[Int],name`。结果用于更新目标和移除合并来源；写回执完整结构尚缺。当前客户端忽略写响应数据，复用 Person.list 和 person_id 照片查询核对目标名称、来源消失及照片编号并集；不宣称验证了人脸级成员。
- separate：`name,target_id,face_id:[Int]`；也存在省略 target_id 的新人物分离路径。
- delete_face：`person_id,face_id:[Int]`。
- set_cover：`id,photo_id`；返回 id/name/cover/additional。
- 不得把 face_id 误当照片 unit_id。人物纠正涉及识别成员变化，需不可变目标、确认、权限、操作编号和最终成员核对；当前仅记录静态参数，不注册版本兼容结论。

## 照片请求

`SYNO.Foto.PhotoRequest` create/update/delete/get/list v1。

- 创建表单构造 passphrase、subject、description、library、folder_home_path、filesize_limit、expiration，若选择相册则 album_passphrase 非空时优先，否则 album_id。
- library 常量为 personal_space/shared_space。filesize_limit 是 MiB × 1048576 的字节数；0 表示不限制。expiration 默认0，日期单位仍待核对。
- 更新只发送改变的字段及 passphrase；关联相册、路径变化有独立处理，清除目标的哨兵值须进一步核对，不能猜测0/-1。
- create 返回 sharing_link，列表对象映射字段还包括 folder_id、album_id、album_passphrase、album_name、is_folder_valid。默认收集路径由官方表单生成，不用用户真实路径作为 fixture。
- delete：`passphrase:[String]`；官方删除后移除列表项。关闭/删除请求不应推断为删除已上传照片；其准确副作用待专用环境验证。
- 未执行创建或发布收集链接。需验证现状读取、权限、无重复创建、最终状态、访问范围与收集目标。

## 预览重建

`SYNO.Foto.RegeneratePreview` / `SYNO.FotoTeam.RegeneratePreview`：set_regenerating、regenerate_preview_by_nas、list_regenerating、restore_from_regenerating 均 v1。

- set_regenerating：`item_id:[Int]`；返回 list，网页读取 unit_id/type/filename 并加入外部转换队列。
- list_regenerating：无业务参数；list 同上。
- 网页常规重建流程检查桌面转换客户端可用性；NAS 重建另等待 REGENERATE_PREVIEW 事件，不能将普通成功回执直接当作预览已完成。
- NAS 重建的完整参数、事件订阅契约、客户端转换与还原路径未补齐，不能将两种流程混为一谈；此功能尚未实现。

## 目录创建（补充原文件管理分组）

`SYNO.Foto.Browse.Folder.create` v1（共享空间 FotoTeam）：`target_id:Int,name:String`，返回 `data.folder`，官方以 folder.id 导航。现有 Folder.get v2 可按编号获取 id/name/parent/access_permission。目录层级导入可逐级列出精确名称、创建缺少目录，再按返回编号核对名称/父目录和管理权限；未收到编号时不得猜测成功并盲目重建。

## 适配、回滚与验证范围

本记录只提供静态契约证据。macOS 后续逐个接入完整流程；共享契约扩展已获用户授权，五端影响随实现同步。Android/Windows/iOS/iPadOS 无新增界面或存储。缺失能力、权限不足、字段不兼容要给出可恢复错误，不设置测试名单；创建未知结果不重放。未保存原始脚本、会话、HAR 或用户数据。

PENDING_USER_VALIDATION：记录真实 DSM/Photos 版本后，在专用合成相册/目录中验证对应流程；本轮无新增写行为验证。正式测试应覆盖字段构造、未知结果、权限拒绝、部分完成和目标身份，不得以静态证据替代 NAS 行为验证。


## 2026-09-29 条件相册接入与补充证据

- 官方 Album.list 的全部相册 category 仍为 normal_share_with_me，原始 type=condition 标识条件相册；已同步领域集合默认 false 的 isConditional，不猜测名称。创建后按最小 album.id 回读，不要求创建响应重复全部相册字段。
- 官方 ehE 转换表：time/item_type/keyword/focal_length_group/exposure_time_group/flash 原样；其他已知引用字段（包含 rating/folder_filter）从 id/name 对象取 id。官方旧迁移会丢弃无名项，本客户端不执行该清理，保留无名编号并提示原有条件。未知字段保留完整值、空数组与顺序。
- suggest v3 返回以 aperture/camera/exposure_time_group/focal_length_group/general_tag/geocoding/iso/lens/person/concept 为键的建议；范围由 start/end 构造，地点递归 children 展平，同名末级使用父编号。额外缩略图字段不参与规则判断。闪光灯未列入官方默认建议，本轮保留已有闪光灯条件及移除能力，不编造新的值域。
- 已实现个人条件相册创建、编辑条件、数量预览、建议查找；编辑名称继续沿用独立重命名，避免把两个写入合并成假原子操作。可设置媒体类型、时间范围、文件夹、评级、文件名/描述关键词、人物/主题/标签及其 all/any 策略、相机/镜头/光圈/ISO/地点/焦距/曝光时间。
- 写前核对相册归属及个人来源；修改携带原条件快照，回读发现并发更改则拒绝覆盖。目录源要求实际可见，个人空间来源绑定当前用户。条件相册不接受手工加入/移除照片，仍可在普通相册中归集所选项目。
- 操作编号复用现有去重；创建丢失回执不按名称重建，写入未知只回读。回读必须完整匹配条件，不能仅看 success=true。空可选已知集合统一省略、已知集合顺序归一化；未知字段原样传递并核对。
- 共享契约新增 conditionAlbums/createConditionAlbum/setAlbumCondition、读取/建议/数量方法（默认显式不支持）和可选兼容标记；DsmJSONValue 增加 decimal/null，以保留规则里的合法 JSON 值，不改旧字段编码。未改变持久化、签名或权限，不涉及待授权上传恢复存储。
- 证据仍为 static + 合成自动化；本轮未创建真实条件相册、未写入真实 NAS。共享空间来源、日期边界、完整非空建议及新版兼容仍为 PENDING_USER_VALIDATION，不设人工禁用门。


## 2026-09-29 分享协议补充只读发现

Chrome 恢复可用后，从已加载官方 react_bundle.js 静态复核；未打开会隐式创建链接的分享对话框，未执行任何分享写入。原始代码只留浏览器内临时变量，完成后已删除并关闭开发者工具，不保存主机、凭据、用户列表或原始脚本。

- exB 的公开访问差量：private 删除 public 成员，public-view/public-download 分别更新 view/download，其他值抛错。exF 按 type+id 比较具名成员，更新 role、删除失去的成员、添加新增成员。exH 仅在密码改变时加入 password，有效期参数非 undefined 时加入 expiration，权限无变化时不发送 permission。
- 网络层 requestWebAPI 只在 env.isSecure() 为 false 且配置 encryption 时调用 encryptParams。该方法读取 SYNO.API.Encryption.getinfo v1、format=module；返回 cipherkey/public_key/ciphertoken/server_time。p3 使用指数10001的 RSA 公钥加密随机口令，并以该口令 AES 加密含校准秒时间和业务字段的 JSON，组合 rsa/aes 放入 cipherkey 指定键。口令生成 p2(501)、AES 序列化/KDF/模式/填充、RSA 编码及服务端完整行为仍需核对，未直接实现猜测协议，也未将网页的加密失败吞错照搬到客户端。
- 通用日期帮助函数存在两套：vY 会 utc(true) 后转 Unix，v$ 直接按本地 dayjs 转 Unix；均有 startOf/endOf(day)。日期组件根据参数选择转换并回调开始与结束秒数。仅凭通用帮助函数不能确认分享有效期使用哪套时区，分享表单绑定仍待补齐；照片请求默认使用 v$.getNowTimestampEndOf 加间隔。
- 以上为 static，不提升任何 NAS 版本为 behavior-verified。已落地的状态读取/仅受邀者访问见 photos-management.md；密码、有效期编辑及成员完整管理仍为待实现切片。


### 2026-09-29 成员结构补充

官方 ePW 将 Album.get 的 additional.sharing_info.permission 直接传入 sharingUserGroup；成员表格以 id 为键、name 为显示、type 区分图标、role 初始化选择。exN 以 type_id 建表，exF 对比角色并生成增删改，保留未改变成员。候选 list_user_group.list 按用户/群组分组，以 id/type 排除已有成员，排除自己的比较对象为 UserInfo.uid 而不是 id。原脚本只在浏览器内临时读取，变量已删除并确认关闭开发者工具。最后一次额外常量检查遇到锁屏，未绕过、未留下新临时源码变量；当前仍为 static，没有真实成员请求/写入验收。

具名成员管理已接入源码与合成测试；本文件此前“成员增删改待实现”的记录由本节更新。密码与有效期编辑仍待实现，完整字段与失败策略见 photos-management.md。


## 2026-09-29 人物命名与合并实现

macOS 人物卡片提供命名/清空名称及合并入口，能力独立：命名只需 Person v1，合并需 Person v2、Timeline v5、Item v4、Folder v2。操作前重新读取目标名称/数量；合并读取全部人物照片并检查目录权限，同操作编号不重复提交，写后自动核对名称、来源消失和目标照片并集。清空少于两张照片的人物名称后列表可能隐去，只有成功回执与隐去结果同时成立才确认；回执丢失不按隐去推断成功。

领域增量为 peopleNames/peopleMerge、renamePerson/mergePeople、managementPeople、结果 person/removedPersonIDs，旧调用默认兼容。分类封面通过当前授权分类列表中的缩略图读取，按分类隔离、重新授权清空，不再将人物编号当作相册编号。合成测试覆盖冲突、权限、回执丢失、照片重叠并集、来源残留、重复身份、能力独立和封面隔离。证据仍为 static 与本地自动化，无真实 NAS 写入；不新增版本验证白名单。人脸分离/纠正/封面及共享空间仍未实现。真实环境条件和步骤见 MACOS_PHOTOS_PARITY_20260929_ZH.md。
