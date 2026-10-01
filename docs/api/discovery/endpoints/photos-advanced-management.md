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
- Passphrase.get_permission v1：passphrase、exclude_public，返回 permission.download/upload；协作实现与限制见文末相册协作补充。
- Passphrase.update v1：passphrase，permission 数组。具名成员 `{type,id}`；更改/新增 `{action:"update",role,member}`，移除 `{action:"delete",member}`。public 同理，private 通过删除 public 成员实现。
- 具名成员的普通相册角色 view/download/upload，条件相册仅 view/download；共享目录还有 manage。公开链接转换 exB 仅支持 private/public-view/public-download，不能从常量推导 public-upload。不得把普通相册 upload 角色用于条件相册。
- 修改密码仅在用户更改时发送 password，未改变时完全省略；清除为默认空字符串。官方 mr 调用明确指定 encryption=["password"]，需要复用并核实 DSM 加密机制，不能直接照搬普通表单明文参数。
- expiration 仅在修改时发送；默认 0。日期转 Unix 单位与日界语义尚需检查。
- 现有基础分享不会发送这些新字段。高级权限必须以读取的原成员快照计算增删改并回读，不得将未展示成员意外删除。公开分享未进行实测。

## 人物整理

`SYNO.Foto.Browse.Person`（共享空间对应 FotoTeam 前缀）：show v1、set v1、merge v2、separate v1、set_cover v1、delete_face v1、add_face v3、list_face v1、get/list v1。

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

2026-09-29 后续静态补证：`regenerate_preview_by_nas` v1 参数为 `unit_id:Int`（单个编号）。调用前通过页面事件通道发送 `{type:REGENERATE_PREVIEW,operation:REGISTER,data:{idUnit:Int}}`，接收时按 `data.idUnit` 过滤；接口success仅代表接受，最终以匹配事件的 `data.success` 判断。`restore_from_regenerating` v1 参数为 `unit_id:[Int]`，官方仅在各转换方式均失败后调用；该写操作不能当作普通读取或无条件清理。`list_regenerating` 无参数，列表字段unit_id/type/filename供重建队列恢复。官方按媒体格式在外部转换客户端、浏览器和NAS之间选择顺序；完整事件传输/鉴权、上传转换文件和失败恢复契约仍未补齐，不把仅NAS请求当作网页完整流程。本次只读官方脚本，无真实照片或写请求，等级static。

后续静态补齐：官方Socket.IO路径为当前Photos页面所在目录加`FotoSocketIo/socket.io`（本次页面目录为`/`）；仅websocket，Engine.IO版本4，握手查询含SynoToken。内部包装将上述send结构转换为Socket.IO事件`regenerate-preview`，发送载荷为`{idUnit:Int,operation:"register"}`，并非嵌套data。接收载荷通过`data.idUnit`与`data.success`匹配。原生使用同源WSS和会话Cookie，保留官方查询令牌机制，禁止记录完整请求URL或底层含URL错误；沿既有DSM证书及重定向策略。路径来自应用目录，不假定所有反向代理部署都与本次根目录相同；其他部署仍待用户验证。

转换上传静态结构：`SYNO.Foto.Upload.ConvertedFile`/`SYNO.FotoTeam.Upload.ConvertedFile`的`upload`为v3，multipart包含unit_id，以及有值时的thumb_xl/thumb_sm/thumb_m/film_h264；标量值使用JSON编码。浏览器照片路径生成JPEG质量0.9，按比例缩至短边至多1280/240/320，不放大较小图片，处理EXIF方向；不是方形裁剪。JPEG优先外部转换→NAS→浏览器，PNG优先浏览器→外部转换→NAS，其他格式按官方集合分派；GIF/WEBP手动重建策略为空。视频外部转换可分别请求缩略图/视频，完整转换输出与上传流尚未实现，不能用本轮NAS路径代替。

本轮实现仅NAS分支：`SynologyPhotosPreviewEvents.swift`完成EIO4握手、订阅、心跳、按照片编号匹配结果、超时/取消/断线收尾；Repository先验证管理权限和照片身份，再订阅→set_regenerating→校验返回unit_id/type/filename→regenerate_preview_by_nas→等待匹配事件→回读详情。明确失败后恢复对应重建标记；未知不重复提交、不以任务消失当成功。批量部分成功保留成功项，当前预览重新读取，时间轴不刷新。共享使用FotoTeam接口；真实设备结果为PENDING_USER_VALIDATION，功能无人工实测开关。本机转换/上传分支及未知通知恢复的完整体验仍是待办。

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
- 网络层 requestWebAPI 只在 env.isSecure() 为 false 且配置 encryption 时调用 encryptParams。该方法读取 SYNO.API.Encryption.getinfo v1、format=module；返回 cipherkey/public_key/ciphertoken/server_time。p3 使用指数10001的 RSA 公钥加密随机口令，并以该口令 AES 加密含校准秒时间和业务字段的参数体（精确序列化以后文补证为准），组合 rsa/aes 放入 cipherkey 指定键。口令生成 p2(501)、AES 序列化/KDF/模式/填充、RSA 编码及服务端完整行为仍需核对，未直接实现猜测协议，也未将网页的加密失败吞错照搬到客户端。
- 通用日期帮助函数存在两套：vY 会 utc(true) 后转 Unix，v$ 直接按本地 dayjs 转 Unix；均有 startOf/endOf(day)。日期组件根据参数选择转换并回调开始与结束秒数。仅凭通用帮助函数不能确认分享有效期使用哪套时区，分享表单绑定仍待补齐；照片请求默认使用 v$.getNowTimestampEndOf 加间隔。
- 以上为 static，不提升任何 NAS 版本为 behavior-verified。已落地的状态读取/仅受邀者访问见 photos-management.md；密码、有效期编辑及成员完整管理仍为待实现切片。


### 2026-09-29 成员结构补充

官方 ePW 将 Album.get 的 additional.sharing_info.permission 直接传入 sharingUserGroup；成员表格以 id 为键、name 为显示、type 区分图标、role 初始化选择。exN 以 type_id 建表，exF 对比角色并生成增删改，保留未改变成员。候选 list_user_group.list 按用户/群组分组，以 id/type 排除已有成员，排除自己的比较对象为 UserInfo.uid 而不是 id。原脚本只在浏览器内临时读取，变量已删除并确认关闭开发者工具。最后一次额外常量检查遇到锁屏，未绕过、未留下新临时源码变量；当前仍为 static，没有真实成员请求/写入验收。

具名成员管理已接入源码与合成测试；本文件此前“成员增删改待实现”的记录由本节更新。密码与有效期编辑仍待实现，完整字段与失败策略见 photos-management.md。


## 2026-09-29 人物命名与合并实现

macOS 人物卡片提供命名/清空名称及合并入口，能力独立：命名只需 Person v1，合并需 Person v2、Timeline v5、Item v4、Folder v2。操作前重新读取目标名称/数量；合并读取全部人物照片并检查目录权限，同操作编号不重复提交，写后自动核对名称、来源消失和目标照片并集。清空少于两张照片的人物名称后列表可能隐去，只有成功回执与隐去结果同时成立才确认；回执丢失不按隐去推断成功。

领域增量为 peopleNames/peopleMerge、renamePerson/mergePeople、managementPeople、结果 person/removedPersonIDs，旧调用默认兼容。分类封面通过当前授权分类列表中的缩略图读取，按分类隔离、重新授权清空，不再将人物编号当作相册编号。合成测试覆盖冲突、权限、回执丢失、照片重叠并集、来源残留、重复身份、能力独立和封面隔离。证据仍为 static 与本地自动化，无真实 NAS 写入；不新增版本验证白名单。人脸分离/纠正/封面及共享空间仍未实现。真实环境条件和步骤见 MACOS_PHOTOS_PARITY_20260929_ZH.md。


## 2026-09-29 有效期日期绑定补证与实现

发布前只读观察的官方前端：ePp启用使用v$.getNowTimestampEndOf()、取消使用默认0，日期回调取第二个参数。所用ZR=ZD(ZL,Zk)，Zk=false，unit=day，因此使用本地dayjs而非utc(true)。辅助函数endOf(day).unix()生成所选本地日结束的Unix秒。以上变量名仅作static证据定位，不参与客户端运行判断；现环境快照沿用2026-09-28-photos-parity-observation.md。本轮锁屏未再次观察，不把前端静态发现标为真实写入验证。

已接入读取/修改/取消有效期，覆盖23小时和25小时夏令时日；未编辑时不归一化原始秒数，未读取到值不自动清除，密码字段仍省略。密码加密与PhotoRequest完整写协议仍需补证，未发送真实分享写入。

## 2026-09-29 发布后恢复观察：照片请求与密码编码

Chrome 恢复后继续只读同一官方脚本，环境沿用上述快照，仍为 static；未执行收集请求或分享写入。下列补充覆盖此前相应未知项，不构成 NAS 行为兼容结论。

- PhotoRequest.list v1 的官方入口使用 offset=0、limit=5000 和可选 keyword；返回 list。记录投影字段为 passphrase、subject、description、library、folder_home_path、folder_id、album_id、album_passphrase、album_name、expiration、filesize_limit、is_folder_valid、sharing_link。create 返回完整记录，官方从返回值取得 sharing_link；update 的界面本地更新不能代替原生端的最终回读。
- 创建 passphrase 默认空字符串；subject 去首尾空白且最多50字符，description 最多100字符。filesize_limit 为启用后的1至3000 MiB乘1048576，不限为0；expiration 不限为0，日期组件取本地日末秒数。默认目录由 /PhotoRequest 与处理后的标题组成；新目录建立、路径合法性与默认到期间隔仍需核对，不能因默认路径看似目录而要求它必须已存在。
- 更新只发送改变字段；library 与 folder_home_path 改变时一起发送。**清除目标相册的 API 值为 album_id=-1**，而界面内部未选值为 null，两者不能混用。album_passphrase 非空时优先并省略 album_id；空时省略 album_passphrase、保留 album_id。删除传 passphrase 字符串数组。目录选择器检查 upload 权限，而非一律要求 manage。
- 非 HTTPS 的 password 编码采用官方 CryptoJS 密码模式：AES-256-CBC、PKCS7，OpenSSL Salted__ 格式和8字节随机盐，EvpKDF 使用 MD5、iterations=1，连续摘要派生密钥与 IV。RSA 部分将随机口令加密结果从十六进制转 Base64，公开指数为10001；随机口令生成器调用参数为501。以上只记录互操作格式，不照搬官方 Math.random 作为客户端随机源。
- RSA 填充、server_time 的精确偏差换算和错误响应仍未补齐，因此密码写入尚未实现。前端未找到独立密码核对调用；enable_password=true 只能证明保护已启用，不能在改密回执丢失时证明目标密码生效。不得以该布尔值确认未知改密成功，亦不得在加密失败后退回明文 HTTP。
- 浏览器临时源码变量已删除并确认 undefined，开发者工具已关闭；未导出原始脚本、会话、链接、密码或用户内容。


## 2026-09-29 密码编码完整补证及HTTPS客户端适用范围

只读同一官方脚本，未打开写入表单：RSA填充为PKCS#1 v1.5，公钥为十六进制modulus与指数10001；p3中p2(501)生成随机口令。此前“JSON加密体”描述不准确：encryptParams先对WebAPI字符串值JSON.stringify，再以pz构造encodeURIComponent键值串；时间字段以ciphertoken为键、值为floor(Date.now()/1000)+timeBias，timeBias为getinfo.server_time减获取时本地秒数。该参数串才送入CryptoJS AES密码模式，输出OpenSSL Salted__格式。返回cipherkey指定的对象包含rsa/aes，经普通WebAPI JSON字段编码。原始脚本未保存。

requestWebAPI仅在env.isSecure()为false时运行上述加密，isSecure依据baseURL的https前缀；HTTPS直接发送password业务字段。当前原生DsmEndpoint和DsmRequestBuilder只接受HTTPS，故密码管理直接沿用此官方HTTPS路径，不新增HTTP支持、RSA/AES依赖或不可达加密代码。非HTTPS仍由既有连接层拒绝，不能为本功能削弱传输保护。

密码参数nil代表不修改、空字符串清除、非空字符串设置/替换，空格和Unicode保留原样。非nil要求当前分享快照；提交前仍校验相册所有者及revision。update成功回执加enable_password=true才能确认设置/替换；回执丢失且旧密码本来已启用时不得伪报成功或自动重发。清除可通过明确enable_password=false回读确认。无需读取/返回原密码，不把密码写到URL、日志、文件或持久化队列；界面关闭清除输入，操作会话内保留原命令仅作去重，不跨启动保存。

浏览器临时源码变量已删除并确认undefined，控制台已关闭；未输入真实密码或执行NAS分享写入。版本未知与static证据等级保持不变。


## 2026-09-29 收集请求目录与目标相册补证

- 官方默认目录在个人home开启时为personal_space；home关闭且共享management时为shared_space，否则共享entry必须选目录。默认路径为`/PhotoRequest/<trim后的标题>`；正则`^\s*$|^\.|\.$|^@(?:database|eaDir|tmp|sharebin)$|^#(?:recycle|snapshot)$|[/\\:]`匹配替换下划线。默认目录可以尚不存在；改选目录后关闭标题与目录联动，编辑已有请求不联动。目录控件只读，通过Folder选择器取path/id并要求UPLOAD。
- PhotoRequest v1 create返回顶层完整记录，官方取sharing_link及同字段列表投影；update使用差量，不把本地更新当回读；delete使用passphrase数组。期限本地日末、不限0；大小默认25MiB但未开启限制，开启范围1至3000MiB。
- 收集目标相册选择器实际查询`SYNO.Foto.Browse.NormalAlbum.list v1`，category=addable、sort_by=album_name、sort_direction=asc、additional=[sharing_info,thumbnail]。owner_user_id等于当前UserInfo.id时用album_id，否则从sharing_info取passphrase并用album_passphrase。不能用普通所有相册列表替代addable或人为只准自己的相册。现有非共享相册选择前会提示收集者不能查看相册；选择器也允许先创建新普通相册。
- 本次仅官方脚本静态读取，没有创建请求/分享/目录/相册或删除数据。新增读回通过自有请求list按精确passphrase定位，不猜测未确认的get响应；丢失create回执不得按同标题追认。浏览器临时源码已删除并确认undefined，DevTools关闭。证据static，现环境版本未知。


### 收集请求客户端主流程

Apple共享契约新增PhotoRequestSettings/PhotoRequest快照与候选相册、photoRequests能力、create/update/delete命令和结果；服务新增photoRequest与photoRequestAlbums，旧服务默认显式不支持。目录Collection增加默认nil的path，仅用于既有Folder.name全路径；不改变存储。macOS分享→照片请求提供创建、编辑、删除确认及复制链接，表单支持空间、默认/已有目录、相册、期限和大小限制。修改只发改变字段，变更目录总是同时发送library/folder_home_path，清除相册-1，共享相册优先passphrase。保存结果局部更新列表，不刷新时间线。

预检查NAS身份、完整自有请求快照、目录编号/路径/上传权限、addable相册；共享entry必须选有上传权限的已有目录，management可用默认目录。默认目录不预创建，create响应提供passphrase后按精确编号查自有list；回执丢失不按名称追认、不重放。更新必须字段一致，删除必须完整分页查不到原passphrase；原目录失效不阻止删除请求。名单重复、缺字段或读取失败不能充当删除/保存成功。对已知错误按现有拒绝语义处理，未知结果由模型自动回读。

协议范围仍static，本轮不创建或删除真实NAS请求。收集窗口内直接新建目标相册、请求列表搜索和真实访客上传行为尚待完成；不能将此主流程交付标为完整网页复刻。PENDING_USER_VALIDATION需专用合成目录/相册，核对创建链接访客上传、期限/大小限制、更新目标、删除后链接失效及已收集文件处理；不采集真实链接/用户文件。

### macOS收集配套交互增量

后续客户端已接入文件夹与个人普通相册的快捷入口、按App语言格式化日期的默认标题、表单内新建普通目标相册，以及已有请求按标题搜索。新建相册复用既有NormalAlbum创建/精确身份核对，不引入PhotoRequest新参数；确认完成后才选中目标相册，未知结果保留原操作编号，不按名称猜测。搜索由客户端过滤已读取的请求列表，无匹配且仍有后续页时继续分页，不构造未经确认的远程搜索字段。共享相册来源完整对齐仍在后续范围，真实访客上传与限制行为由用户验收；本轮没有新增真实NAS写入证据，static等级不变。


### 2026-09-29 人脸选择与纠正静态补证

继续只读同一官方脚本，未执行人物写入或读取真实人脸数据。Person.list_face v1使用person_id和item_id整数数组，返回list；选择器取list[].id作为face_id，缩略图取additional.thumbnail.cache_key，以type=face请求Thumbnail.get且不指定size。每张照片独立查询可建立照片与人脸对应关系，不依赖未确认的响应照片字段。

人物相册纠正使用delete_face(person_id,face_id数组)，返回list用于更新移出的照片；分离使用separate(name,target_id,face_id数组)，新人物target_id=0，返回id/name。另一个图片内人脸框编辑路径新人物省略target_id，不能混用两条流程。原图不删除。set_cover(id,photo_id)返回id/name/cover/additional，最终人物封面应通过Person.get/list重新读取，不能把封面编号假设为照片编号。官方Item.list_face v6使用id_item及additional=[thumbnail]，返回face_id/person_id等；人脸框增删改是后续独立流程。以上仅static，不注册版本兼容通过。


个人空间人物相册的人脸选择/移出/归入及人物封面已接入客户端。写前核对人物快照、每张照片身份/目录权限、所选人脸仍属于原人物；提交使用不可变快照和操作编号。分离回读要求来源无所选人脸、目标对应照片有同一人脸，且目标名称一致；新人物没有明确返回id保持未知。移出按原人物对每张照片剩余人脸判断局部移除，不删除原图。封面回执cover不是推测的照片编号，使用Person.get回读与明确回执比较，丢回执不误认成功。缩略图缓存限制当前授权会话和已读人脸身份，type=face且不指定size。图片内手工画框新增人脸、人物显示隐藏、共享人物仍待接入，真实NAS行为未验证。


### 2026-09-29 人物显示隐藏与封面静态补证

官方Person.list v1在显示管理中使用show_hidden=true并保留show_more，全部人物计数使用show_more=true/show_hidden=true；list[].show为Bool，编辑器直接使用该值。Person.get v1传id数组，返回同样人物条目，官方suggest后会get所选人物并检查show与name。Person.show v1接收id数组及show布尔值；网页把相反目标分成两组分别写入。不存在删除原图行为。客户端以单次同目标批量操作，严格读回每个人物的show，不把列表缺失当隐藏成功。

官方人物缩略图helper先检查additional.thumbnail.unit_id：存在时用该编号和type=unit，否则使用人物编号和type=person；只有cache_key而无preview尺寸状态时不传size。此前原生分类封面仅解码必需unit_id不完整，本轮修正人物分支，其他分类仍沿原结构。

图片内手工人脸：face_bounding_box包含top_left/bottom_right的x/y归一化坐标。add_face v3传face数组和id_item，每个新脸包含face_bounding_box、face_id_temp，以及person_id或name；响应list包含face_id/face_id_temp。官方随后逐脸通过独立Upload API上传裁剪缩略图，再Item.get(additional=[person])更新显示。上传API名称、图片编码与完整回读仍待补齐，因此不以add_face单独调用代替完整新增流程。全为static，无真实NAS写入或真实人脸内容读取。


### 2026-09-29 显示管理原生实现

个人空间人物页工具栏和人物卡片菜单均可打开显示管理，读取全部人物（含隐藏项），搜索后选择同一显示目标；提交前确认窗口保留不可变人物/show快照，最多100项沿用已有Photos管理批量上限。Person.get严格核对原始show、名称和已知照片数量，Person.show仅提交选中且需要改变的编号。成功后逐项get读取show，全部匹配才确认，明确写回执且部分匹配只更新已完成项；丢失回执进入自动只读核对，相同操作编号不重放。缺失条目、缺少show或未改变均不能视作成功。权限拒绝保留既有拒绝语义，无验证版本白名单。

人物封面缓存区分unit/person类型，支持仅cache_key的封面，重新授权时清空。显示/隐藏局部更新人物卡片与筛选，不清空照片、不跳回时间轴、不删除文件。证据仍static+合成测试，当前DSM/套件版本未知，verifications保持空；真实NAS由用户验收。


### 2026-09-29 手工人脸完整流程静态补证

重新只读当前官方脚本：Item.list_face v6参数id_item、additional=[thumbnail]，结果list以face_id/person_id/name/face_bounding_box组织。新增人脸Person.add_face v3传id_item和face数组，face_id_temp为字符串（官方照片编号-递增计数），face_bounding_box为左上/右下归一化x/y，person_id或name二选一；返回list中的face_id和face_id_temp一一映射。编辑已有归属用Person.separate v1，name及face_id数组，既有人物再加target_id；删除识别成员用delete_face(person_id,face_id数组)，不删除原照片。未发现修改既有框坐标的独立方法，若调整既有框需明确按新框创建并移除旧识别记录实现，不能猜造set字段。

官方新框控件为aspect=1，最小36显示像素；裁剪编码image/jpeg，最大边常量256。以照片显示方向的自然尺寸及归一化坐标裁剪。新增回执后逐脸调用SYNO.Foto.Upload.Face（共享对应SYNO.FotoTeam.Upload.Face）upload v1，multipart字段api/method/version/face_id/file：api等路由值原始字符串，face_id JSON数值，file为JPEG Blob；临时编号只用于本地找裁剪图，不发送tempFaceId。上传沿能力发现路径，认证由会话层提供。保存结束重新Item.get(additional=[person])，不能只发add_face忽略缩略图。官方多项错误会提示保存失败，未表明事务回滚。

以上static，无真实人脸读取或NAS写入；浏览器临时源码已删除、确认undefined并关闭DevTools。不登记版本兼容通过，当前环境仍沿2026-09-28观察记录。


### 2026-09-29 图片内手工人脸编辑增量

macOS个人照片预览接入编辑人脸：加载原有框、鼠标绘制/拖动/缩放、键盘等价的居中新增与位置/尺寸滑块、归入既有或新人物、移除与撤销移除，点击保存前不写NAS。裁剪最长边256的JPEG，照片显示坐标归一化；调整既有框按新增框并完成缩略图后移除旧标记，原图保留。读取Item.list_face v6；新增Person.add_face v3返回临时编号到face_id映射；Upload.Face upload v1传multipart JPEG。归属纠正和移除沿separate/delete_face。不新增猜测API。

共享契约增量为FaceBounds/FaceRegion/NewFace/FaceChange、photoFaces读取（旧服务默认显式不支持）、manualFaces能力及editPhotoFaces命令；结果仍复用photos/completedCount。macOS与共享Apple Repository实现个人空间；iOS/iPadOS共享声明但无新UI且未构建；Windows/Android仅记录待迁移，不改代码。没有存储、依赖或工具链变更。回滚可移除入口和增量声明/方法，不回退已保存NAS状态；原图无变化，人物标记可在网页恢复。

权限、照片身份、原始人脸/目标人物快照和唯一操作编号保留；新增编号不能与旧脸冲突或错配裁剪图。未知新增回执不按同名追认，丢失上传回执只接受明确新编号下完全一致的图像，否则保留待核对且不重传。部分回执只上传明确返回项；缺新增项时不移除旧框。编辑完成局部更新照片详情，月份/选择/预览保留。真实NAS为PENDING_USER_VALIDATION，功能按实际权限/能力开放，无待实测人工禁用；版本证据仍static。


2026-09-29 共享收集默认目录补齐：客户端现在沿已记录的home/entry/management规则选择初始空间。个人可用时优先个人；仅共享management可自动使用默认收集目录；entry显示目录选择并要求明确目标。文件夹快捷入口和已有请求保持原目录，切换空间清除旧列表。SynologyPhotosAccess增量公开canManageSharedSpace（默认false），值来自Photos TeamSpace启用及User.team_space_permission，不从DSM管理员推断；提交继续按实际Folder上传权限核对。没有新API或真实NAS写入，本次证据仍static。


2026-09-29 预览恢复补证（同一官方脚本只读，static）：网页LoadRegenerateTasks调用list_regenerating，非空条目按unit_id/type/filename及当前library重新加入REGENERATE队列，并刷新对应照片编号。队列条目明确need_thumbnail=true、need_video=false；手动预览重建不应被扩大解释为必须重新编码完整视频。之后仍执行按格式选择的转换流程；所有方式失败才restore_from_regenerating。空队列仅让加载过程返回，没有返回已完成的逐项结果，所以不能用条目消失替代此前丢失的完成通知。原生完整恢复仍待接入，需处理重建队列身份和在途重复问题。

同次核对ConvertedFile.upload v3经通用multipart请求构造，照片浏览器路径上传thumb_xl/thumb_sm/thumb_m；包装成功解析data，失败抛出，通用有限重试由错误码决定。外部视频返回tempFileName，转换上传构造只把convertedFile.video映射film_h264。后续原生缩略图流程应按手动重建的need_video=false复刻，不猜测外部临时文件名等同本地视频字节。没有真实读写照片、注册事件或发起转换；只取静态脚本，临时页面变量已删除且控制台清空。


2026-09-29 原生本机预览分支已接入：ImageIO按方向变换生成三档JPEG（质量0.9，短边至多1280/240/320，小图不放大、不裁方形），AVFoundation取视频预览帧并应用轨道方向。手动重建不生成film_h264，不上传原视频；PNG先本机，其他格式在NAS明确失败或尚未建立事件通道时尝试本机。原件下载沿既有Download，随机0700临时目录内处理，结束删除；转换后重新核对照片身份和管理权限。ConvertedFile.upload v3发送unit_id及thumb_xl/thumb_sm/thumb_m，个人/共享分别对应Foto/FotoTeam，会话仍在请求头，固定multipart文件名不使用真实原名。

同步上传成功回执后沿照片编号回读；明确API失败才转其他方式，断网/非2xx/畸形/矛盾回执保留未知，不重传或无条件恢复标记。原件/权限在转换期间变化且尚未写入时报告未处理；已开始写入的未知结果继续保留原操作编号。没有升级证据等级，真实NAS格式/上传行为为PENDING_USER_VALIDATION。旧版本缺ConvertedFile时保留NAS能力；无待实测人工白名单。完整中断队列恢复仍待实现。


共享人物后续静态补证：官方命名/封面/建议/合并处理通过FotoTeam.Browse.Person路由，合并仍target_id/merged_id/name并标记shared_space；图片内人脸保存明确使用FotoTeam.Browse.Person、FotoTeam.Browse.Item和FotoTeam.Upload.Face。接口版本与共享基础表复用；未接客户端共享UI、未真实写入。共享分类及权限前提见photos-library-read.md，不能从个人权限或DSM管理员身份推断。

### 2026-09-29 共享人物管理接入

客户端共享人物改名、合并、显示/隐藏、所选照片人脸移出/归入新旧人物、人物封面，以及图片内新增/调整/纠正/移除人脸框均已沿已记录的FotoTeam.Person、Item、Upload.Face路由实现。集合space固定人物写命令来源，照片ID固定手工人脸来源；新增managementPeople(in:)/peopleVisibility(in:)重载，旧调用继续个人空间。共享功能按实际management权限、人物启用设置及具体API版本/JSON能力开放；没有build白名单或待实测开关。

预检拒绝混合空间的人物、脸和照片；合并按当前空间核对成员照片并集、目录权限和授权代次。人物、人脸缩略图分别按空间隔离缓存，上传丢失回执后的精确JPEG回读也走同一空间；记录未知不重复写。结果人物及显示状态携带来源，界面仅更新对应空间的卡片/筛选/月份/预览，不刷新到最新照片。移除人脸仅操作识别标记，原照片保留。

未进行真实NAS人物写入，证据等级保持static，合成验证不登记behavior-verified；用户验收步骤和构建证据见MACOS_PHOTOS_PARITY_20260929_ZH.md。iOS/iPadOS共享Apple契约与Repository但不新增界面；Windows/Android只记录迁移语义，本轮未改其代码，无存储迁移、新依赖或工具链变化。

### 2026-09-29 共享条件来源静态复核

沿同一官方react_bundle.js只读复核：条件来源选择器仅在enable_home_service时提供个人，team_space_permission=management时提供共享；来源解析对共享返回0，对个人返回当前UserInfo.id。suggest接收keyword/user_id/condition/additional，create/set_condition/peek_item_count仍走统一Foto.ConditionAlbum v3；条件中的folder_filter等编号均属于所选来源。普通相册create/add_item/delete_item仍走Foto.NormalAlbum，item为选中项目编号数组；此静态证据不证明跨空间项目编号转换或混合结果读取已实现。未发送写请求、未保存脚本副本或会话数据；临时变量清除后验证undefined并关闭调试工具。环境仍见2026-09-28-photos-parity-observation.md，版本未知，等级static。


## 相册协作角色、成员与直接上传（2026-09-29）

稳定分组沿用photos-sharing-management、photos-album-management和photos-upload；证据来自当前官方react_bundle.js静态调用与字段使用，没有NAS写验证，完整DSM/Photos版本未知。以下仅为static与合成测试，不新增版本级verifications。

- Sharing.Passphrase.get_permission v1，POST：passphrase:String、exclude_public:Bool。共享页面使用false，返回permission.download/upload；缺字段不等同有权限。当前用户编号与相册owner区分所有者，普通相册才允许贡献。
- NormalAlbum.list v1，POST：category="addable"、sort_by="album_name"、sort_direction="asc"、offset/limit及additional=[sharing_info,thumbnail]；用于添加目标选择，不把所有可见相册当可贡献相册。
- NormalAlbum.add_item/delete_item v1，POST：所有者以id:Int定位，相册贡献者以passphrase:String定位；item:[Int]。写回执error_list的元素结构尚未观察，只保留可解码JSON与是否存在失败，不猜测编号字段含义。最终通过统一Item.list(album_id)逐项回读成员，明确失败下返回已完成子集，未知不重放。
- 官方provider_user_id来自照片additional，与owner_user_id不同。贡献者移除前通过相册Item.get再次读取provider，要求全部为当前用户提供；所有者可移除相册成员。移除成员不删除原件，不要求他人原件目录管理权。新增现有照片仍核对源照片身份和访问权，共享来源检查目录view/download或全局管理权。
- Upload.Item.upload v1，multipart：file、duplicate、name、mtime、folder=["PhotoLibrary"]，所有者album_id或贡献者passphrase二选一；相册模式不发送uploadDestination=timeline或target_folder_id。上传回读统一Item.get v5(id,album_id,additional含provider_user_id)，确认编号、大小与当前提供者；回执丢失不按名称猜测、不自动重传。相册上传完成即为成员，不再发送一次add_item。

Apple共享契约增量albumAccess(id)、addableAlbums(offset,limit)、uploadToAlbum及albumContext.providerUserID；旧照片上下文构造参数默认nil，旧服务默认角色读取unsupported/addable回用albums，不引入持久化。macOS角色读取失败清理旧权限而保留相册浏览；下载/上传/移除按实际角色显示，视频错误恢复下载也遵循同一权限。原件修改仍需源空间权限，贡献角色不授予删除他人原件能力。队列固定初始相册目标，切页不改上传去向；直接相册模式不展示原空间目录层级选项。口令只在Repository请求中使用，不进入UI或领域权限对象。

限制：从其他用户相册转加到另一个相册的无原空间项目尚未接入；跨个人/共享空间搬移、其他混合批量编辑及上传持久化仍是独立待办。真实角色响应、provider字段、部分失败与二进制上传需用户验收，功能无待实测白名单。


## 相册间添加的来源语义更正（2026-09-29）

当前官方脚本的共享照片操作栏先按原空间启用状态和provider_user_id判断，不能仅依赖相册download/upload角色：本人提供的个人或共享照片，在对应空间启用时显示ADD_TO_ALBUM；只有下载角色的其他项目仅DOWNLOAD。混合来源还需两空间启用及共享管理权限。SPACE_DISABLE菜单只有REMOVE_FROM_ALBUM，不包含ADD_TO_ALBUM，因此先前“无原空间跨相册转加未实现”不能作为网页功能缺口。

添加处理从选择项目得到itemArray，目标选择器返回id或passphrase；仍向NormalAlbum.add_item提交目标id/passphrase与item，或create(name,item)新建，未发现source_album_id等来源参数用于此流程，不能猜加。原生实现通过源album_id读取详情并复核编号、文件名、大小、目录、索引时间及当前provider；原件owner可以是另一用户，不应因此拒绝本人提供的项目。原空间关闭、提供者不符、来源读取拒绝或快照变化时不发送目标写入，也不改用原空间请求绕过拒绝。写后按目标album_id回读，不删除原相册成员。

本轮只读脚本证据为static，无NAS写入或版本级验证。混淆函数名称只是定位线索，不作为持久契约；以上参数与字段沿既有契约，不新增公开接口或持久化。其他原件编辑继续独立核对原件/目录权限，不从本轮相册添加授权推导原件修改权。


## 混合来源评级、日期与预览重建（2026-09-30）

证据：当前已登录官方页面的 react_bundle.js 只读静态观察，环境沿用 2026-09-28-photos-parity-observation.md；没有 NAS 写入，不提升为 behavior-verified。

- 普通相册混合菜单在两空间启用、共享管理权和当前用户提供/共享原件条件下使用 NORMAL_ALBUM_WITHOUT_EDIT_TAG；共享相册混合菜单要求两空间、共享管理权及全部由当前用户提供，使用 SHARED_ALBUM_WITHOUT_EDIT_TAG。保留每张原件的实际修改权限，不因贡献角色授予其他个人原件写权。
- getSelectedItemIdSetBySpace 分 personalItemIds/teamItemIds。eI4 在同一日期表单后分别派发 kn/kr；eI6 将评级分别交给 eet/een。底层沿用 Foto/Fototeam.Browse.Item set v2 的 id 数组、rating/time，部分错误沿 error_list，再逐项详情核对。编号必须携带空间；两空间相同数字编号不能合并。
- eCI 分别使用 Foto.RegeneratePreview 和 FotoTeam.RegeneratePreview 提交并聚合完成结果；每张照片仍按所属空间订阅和核对原有预览重建协议，没有新增请求字段。
- 标签路径 eI5 对混合来源直接返回；普通/共享相册菜单没有 MOVE_TO/COPY_TO。混合标签与混合相册搬移不再列为网页缺口。客户端既有额外搬移功能保留，完成后按当前已加载相册范围读取新身份，不清空相册或跳至最新日期。

实现先核对两空间能力及原件身份，再分别提交。每组发送前记录目标，拒绝与未知区分；断线只回读，已完成项目不重复修改，明确部分失败只续作原快照中未完成项。评级/绝对日期属于赋值；相对日期继续从原始时间计算绝对目标，防止重复偏移。相册读取自动重试三次，仍失败时保留当前内容并提供只读重试，导航/取消后丢弃旧读取。

五端影响：共享 Apple mutation 新增计算属性 supportsMixedPhotoSpaces，不改变存储、序列化或调用签名；macOS 已接入，iOS/iPadOS 共享 Repository 行为增量但无界面修改或移动构建；Windows/Android 仅记录按空间分组、固定目标和结果核对计划。真实 NAS 待用户测试。


## 预览通知短暂断线恢复（2026-09-30）

沿用已登记 EIO4 握手与 regenerate-preview register 协议，不新增私有 API 或改变证据等级。Apple 事件通道在已订阅目标的等待阶段收到普通断线时，最多三次按1/2/3秒退避新建连接并重新握手、注册原unitID；全过程计入原600秒等待期限，不把每次重连当成新的等待窗口。成功仍要求匹配编号的明确布尔事件，由Repository继续回读原件身份与新预览。

只重发握手、心跳和注册；不调用set_regenerating、regenerate_preview_by_nas或ConvertedFile来尝试恢复。Socket.IO 44连接拒绝与普通断线分开；证书/权限错误、非法帧、总超时、用户取消或显式关闭均停止重连。新连接沿用同一目标地址、凭据、证书钉扎和系统信任要求，关闭旧连接；没有降级到不安全通道或打印带凭据URL。连续失败仍pendingReview，不能用队列条目消失代替完成。

范围限制：这补齐在途通知的短暂断线恢复，尚不包含关闭应用后读取list_regenerating并恢复任务，也不能恢复所有已错过的完成事件；完整队列恢复仍待实现。合成传输测试覆盖成功/明确失败、不同编号过滤、重连握手失败、三次限制、总超时、取消/关闭、连接拒绝与证书错误；Repository集成覆盖个人/共享只发一次重建、成功回读、失败只恢复一次和身份变化拒绝。真实NAS为PENDING_USER_VALIDATION。


## 未完成预览读取与继续处理（2026-09-30）

沿已登记 static 的 Foto/Fototeam.RegeneratePreview list_regenerating v1（无业务参数），读取list中的unit_id/type/filename；拒绝重复/无效身份。根据所属空间调用Browse.Item get v5，请求thumbnail/resolution/orientation，校对编号、文件名、类型和目录管理权后构造完整原件快照。没有新增猜测的任务状态字段，不把队列条目等同“当前不在处理”。

共享接口增量：pendingPreviewRegenerations(in:)为只读方法，旧服务默认显式不支持；regeneratePreviews增加默认false的resuming参数，原调用行为保持。macOS工具栏“未完成的预览”打开列表，可按个人/共享空间查看、选择并确认继续；打开和切空间只读取，不自动写入。原生恢复确认用于固定目标并避免在用户未选择时重做其他会话遗留任务，功能按实际能力开放。

恢复提交前再次读队列、原件及目录权限，实际发出转换请求前再核对队列身份；沿用现有转换/订阅/上传路径，resuming=true不重复set_regenerating。当前会话存在pending操作时不能换operationID绕过未知状态。若继续前队列已变化且尚未提交，返回明确拒绝而非制造新的待核对写入；订阅失败且没有新的NAS转换时保留原队列标记。明确部分失败只重新处理剩余原目标，以普通重建模式开始新的已确认尝试，已完成项不重做。

通知丢失后的自动核对使用组合证据：提交前原件身份检查同时请求thumbnail并固定其unit_id/cache_key基准；已提交目标不再位于list_regenerating，同一原件身份的非空预览版本相比该基准发生变化，再读队列仍无目标，最后详情回读仍保留新版本，才把当前预览结果确认为更新。此为客户端结果核对策略，并非新增NAS完成回执或官方行为验证；单独队列消失、列表中的过期版本、空版本、身份变化、读取断网都不能确认。无法证明时保留原未知操作且不重发/清理标记，后续自动核对继续用同一编号。

本轮不新增本地持久化：重开应用通过NAS队列读取遗留项目，NAS实际保留队列和cache_key更新行为为PENDING_USER_VALIDATION。预览恢复主流程源码与合成验证不升级版本兼容等级。iOS/iPadOS共享协议与Repository受影响，无移动UI或构建；Windows/Android仅同步按空间队列、确认快照和组合证据的适配计划。

## 相似照片后续切片静态线索（2026-09-30，尚未实现）

同一观察环境官方脚本只读核对，未触发真实写操作。Foto/FotoTeam.Browse.Similar的get_status v1无业务参数，消费is_similar_hash_migration_done、similar_clustering_stage和waiting_count。SimilarItem.get v1沿照片详情id数组与additional读取，照片顶层可带similar组对象；组字段为id/count/top_pick/item_id。组内照片由同空间Item.get v5(id=item_id，additional含folder/thumbnail/resolution/orientation/video_convert/video_meta)读取。Similar.get v1以id数组查询组，读取list[0]及同样字段；组数量小于2时官方隐藏组界面。

写方法候选（均v1）：set_top_pick(id=组编号,item_id=所选照片编号)；ungroup(id=组编号数组)；remove_item(id=组编号,item_id=所选照片编号数组)；撤销分组/移出使用add_item(id=原组编号,item_id=原成员数组,top_pick=原推荐照片)。官方还提供“保留当前/所选，删除其他”，明确确认后走既有照片删除并回读组；它是删除原件，不等于仅移出分组。后续必须区分两种用户结果，保持确认、身份/目录权限、去重与最终回读。当前仅静态候选，尚未接入原生入口，也未验证空组get的返回、写后回读延迟或并发修改语义；不能将源码字段线索表述为NAS行为验证。浏览器变量已删除确认undefined，控制台清空并关闭开发工具。


## `photos-concept-visibility`：主题显示管理（2026-09-30）

- 分类：internal；仅static。环境沿2026-09-28-photos-parity-observation未知完整版本记录，不声明behavior-verified。
- 路由：个人`SYNO.Foto.Browse.Concept`、共享`SYNO.FotoTeam.Browse.Concept`；`/webapi/entry.cgi` POST，JSON参数编码。list/get/set_visibility均v2。
- list参数：offset、limit、show_hidden=true、additional=[thumbnail]；完整分页读取隐藏项。get参数：id整型数组、additional=[thumbnail]。响应data.list含id/name/item_count/visibility及可选additional.thumbnail(unit_id/cache_key)；visibility必须为布尔值，缺失不能当作隐藏。
- set_visibility参数：id整型数组、visibility布尔值。仅改变分类显示，不删除照片。官方批量动作按期望状态拆分，当前原生表单选择同一期望状态；无变化项不提交。
- 权限与能力：已有照片空间权限、Concept v2 JSON能力；共享空间额外要求management和enable_concept。预检再次读取目标名称与原visibility，固定空间和编号，拒绝混空间/重复项/过期快照。
- 结果：写后get核对每个编号的visibility；缺字段、缺目标或读取失败保持未知，不以成功空回执或分类消失当作完成。操作编号去重，未知结果只读核对，不重放set_visibility。部分完成仅更新已确认分类。
- 降级：能力或权限缺失时不提供本操作，读取失败保留正常图库浏览；不增加“未实测”白名单。
- 本显示隐藏波次未包含set_cover v1(photo_id)、hide_item v1(item_id)；两项后续实现及验证见下方“主题封面与误分类移除”扩展记录。
- PENDING_USER_VALIDATION：个人/共享主题页批量隐藏、搜索隐藏项后恢复；短暂断网后自动核对，不删除原件，不刷新到最新月份。只回传脱敏套件版本、空间类别、步骤和错误文案。


### 2026-09-30 主题封面与误分类移除（photos-concept-visibility同组扩展）

稳定组ID保持`photos-concept-visibility`，新增同一Concept端点的管理操作。官方static：个人Foto/共享FotoTeam Browse.Concept，set_cover v1(id:Int,photo_id:Int)，hide_item v1(id:Int,item_id:[Int])。照片选择处理使用Item编号，setCover后官方本地封面编号也使用该photo_id；get v2(id:[Int],additional:[thumbnail])的additional.thumbnail.unit_id用于封面回读。封面操作无已确认结构化回执，不依赖回执字段猜测完成。

hide_item仅移出主题，不是原件删除。官方确认窗在item_count减所选数量小于display_threshold时提示主题将隐藏；操作后重新读取Concept名称、数量、visibility/display_threshold和封面。客户端详情增量增加可选displayThreshold，旧服务/初始化向后兼容；新移除表单必须取得实际数量和阈值，不猜默认值。

预检固定分类快照、照片身份和原目录管理权限，完整分页读取分类成员证明选中照片属于该主题。写后Concept.get与完整分类时间线/照片分页共同核对，成员计数一致才接受缺席结果，逐项确认移出照片原件仍可读且身份不变。原件缺失、get缺目标、字段缺失、读取失败均保留未知，不将成功回执/当前页缺席当完成。部分确认只移除已核对项，不自动重发剩余项；同operationID只核对。

封面按选中Item编号与主题thumbnail.unit_id精确比较；共享需management及enable_concept。低于阈值仅更新主题卡片是否可见；当前分类仍保留剩余照片/月份，已移出的预览关闭，不跳最新。本人/共享来源不混用、不新增白名单。真实NAS特别是连拍封面编号、低于阈值或全部移出后的get返回行为均待用户验收，static不升级为行为兼容。


## 2026-09-30 自动预览候选与执行协议（static，实施中）

稳定标识 `photos-automatic-preview`。沿2026-09-28照片发现环境的未知完整版本限制，仅读取已登录官方静态资源，无真实设置、原件读取、转换或上传请求。

| 环节 | 官方静态绑定 | 当前实现/限制 |
| --- | --- | --- |
| 个人及共享后台扫描 | SYNO.Foto.Upload.ConvertedFile / SYNO.FotoTeam.Upload.ConvertedFile，POST JSON，list_convert_needed v3，能力发现路径（当前entry.cgi） | 已接入只读服务，按空间访问及共享management检查；不是文件夹下载权 |
| 请求条件 | type=[photo,video,live_video]；无HEVC能力时仅video；HEVC和视频能力均无则不扫描；HEVC+VC1用windows，无HEVC且有VC1用windows2，其余macos | 保留官方映射；能力由后续实际转换后端提供，不假设所有Mac支持所有编解码器 |
| 返回 | data.list[].unit_id、filename、type、need_thumbnail、need_video；官方type=0为照片，非0为视频，需求值转换布尔 | 独立预览单元身份含profile/space/unitID，保留type原值；不能当成Browse.Item编号。布尔或0/1是客户端接受范围，当前NAS实际类型未验证；缺字段/重复单元/未知值明确失败 |
| 自动调度 | 自动开关与桌面能力开启，队列空闲5秒后扫描；先当前空间，再另一可用空间；空列表标记该分类已完成 | 尚未接入模型调度；不宣称整体自动预览可用 |
| 优先级 | 可见照片达到0.8可见比例、预览当前/相邻/实况单元优先入队；有缺陷缩略图或视频才候选 | 尚未接入可见项优先与预览联动 |
| 原件下载 | Download.download v2，unit_id数组；与item_id分开 | 后续不能直接传任务unit_id给现有图库项目下载 |
| 自动转换 | 独立于手动RegeneratePreview；缩略图和视频按need_*分别请求，不先set_regenerating | 现有手动本机转换可复用图像生成，但不能用重建标记替代自动任务 |
| 转换上传 | ConvertedFile.upload v3，unit_id与有值的thumb_xl/thumb_sm/thumb_m/film_h264 | 缩略图上传已有；自动视频经官方桌面扩展tempFileName/原件大小/格式列表桥接，桥接最终视频参数仍需补证，不把临时文件名臆造成视频字节 |
| 失败 | 非连接/超时错误分别调用set_broken v3，id=[unitID]，type=[photo]或[video] | 仅记录候选；未实现或发出该写请求，客户端失败不得提前标记NAS原件损坏 |
| 未完成手动重建 | 桌面能力可用时另读list_regenerating，任务类型REGENERATE；不受自动候选队列同一类型假设影响 | 现有手动恢复保留，自动候选不合并其身份/写状态 |

只读服务 `automaticPreviewTasks(in:support:)` 返回当前候选批次，官方调用不传offset/limit，客户端不编造分页或以一个候选批次代表完整图库。返回空批次、解码失败、接口不可用分别处理；调用前后取消检查、访问代次校验，旧会话返回不得进入新队列。读取不触发下载、标记重建、上传或set_broken。旧服务默认明确不支持，属于已授权增量契约；其他端无UI变化。本切片未新增自动设置入口，因为完整任务执行仍在实现中，不是以“未实测”禁用已实现入口。

PENDING_USER_VALIDATION：后续完整入口交付后，使用个人空间及共享management/entry账号验证后台扫描范围，确认缺预览的HEIC、普通视频和实况视频分别生成，关闭自动设置后不再启动新任务；历史月份、预览位置、原件不变。断网/取消/登录切换不重复上传，当前任务状态可见。现在只完成只读候选，真实NAS返回字段类型、批次语义、视频上传及最终回读均未验证。只回传脱敏版本/媒体类别/操作/错误，不包含原件或地址。

回滚可移除本轮自动候选服务与类型，不影响手动重建或既有图库，无存储迁移。后续依赖顺序：独立unit原件读取与转换结果核对→自动缩略图/视频执行→队列调度与设置→可见项优先及恢复→原生UI与用户实测。


### 自动预览单元原件与本机视频转换增量（2026-09-30）

本轮继续同一静态环境。官方下载帮助函数Y$明确默认type=Unit→unit_id数组，Item类型才使用item_id；自动任务ep6使用该默认单元下载。桌面上传桥接sendUploadVideoInfo构造_dataField=film_h264及api/method/version/unit_id，其最终视频数据来自本机临时视频文件；普通multipart构造eSr也将video映射film_h264。未执行真实下载或上传，没有把临时文件名作为视频内容。

缩略图通知static补证：事件thumbnail-update；注册data含unit_id数组及is_team，取消注册仅unit_id；返回data数组中每项thumbnail用于更新缓存，包含unit_id、xl/m/sm状态及缓存字段。此事件只明确缩略图状态，不把它推断为完整视频转换成功；本轮尚未扩展现有regenerate-preview事件实现。自动完整视频最终回读仍待补证/接入。

已实现 `downloadAutomaticPreviewSource(_:support:to:progress:)`：固定profile/space/unitID与候选快照，下载前后重新读取同一候选批次；仅用Download.download v2的unit_id参数，不构造Item编号、不猜相册或目录。HTTP 200、非错误/归档内容类型、正文件长度及可用Content-Length一致后才导出到未占用目标；取消/访问代次变化/候选变化均不提升临时文件，既有目标不覆盖。随机0700临时目录结束删除；这个读取结果本身不授予上传或原件管理权限。

本机 `SynologyPhotosPreviewConverter.video(file:to:)` 使用Apple既有AVFoundation的HighestQuality H.264/AAC导出，原比例、方向、小视频不放大、移除容器元数据；输出读取视频轨道格式确认H.264、有效时长后沿既有原子导出，不覆盖源文件或已有目标。Apple当前SDK AVAssetExportSession.h明确HighestQuality为H.264/AAC，无新增依赖/工具链/最低系统版本。macOS 14导出对象非Sendable，启动和取消通过MainActor持有对象与回调续体在同一执行域处理，没有unchecked Sendable或绕过并发诊断。

本轮只是完整自动执行流程的输入与转换阶段，尚未把自动任务接入转换上传、结果核对和调度/设置；不宣称整个功能可用，也未新增人工待实测禁用。现有手动预览重建保持三档JPEG行为。真实HEVC/VC1/VP9/MPEG2及实况视频兼容仍PENDING_USER_VALIDATION，测试仅使用合成MJPEG/PCM转H.264/AAC、旋转小视频和合成图片，不能将该结果扩大为所有编码支持。

回滚新增单元下载服务与video转换方法即可，无NAS或本地存储迁移；后续仍需明确视频结果读取、操作编号去重和流式multipart上传，再接模型队列及自动设置。权限不足共享entry的可见目录优先任务仍需独立于management后台扫描设计，不能以本轮扫描权限拒绝替代完整可见项功能。


### 自动预览上传与未知回执核对增量（2026-09-30）

共享Apple管理命令新增 `generateAutomaticPreview(_:support:)`，沿现有prepare/perform/review及operationID记录执行；feature为automaticPreview。不新增平行写队列，不把预览unitID转换成图库Item身份。个人与共享后台扫描分别路由，后者要求实际management。准备、下载前后和本机转换后均核对候选快照；转换后的最后核对仍不能消除NAS上无条件upload的并发窗口，此接口未见版本条件写参数，不能虚构原子比较更新。

随机0700目录保存原件、转换结果和0600 multipart；临时源文件只保留原扩展名，不保留真实名称（实际合成MOV证明无扩展名时AVFoundation可能无法打开）。按needsThumbnail/needsVideo分别上传thumb_xl/sm/m JPEG与film_h264 MP4；单元id、api、method=upload、version=3来自已记录官方static链路。视频按1MiB读写multipart文件，使用既有二进制传输层上传，不将完整视频装入内存。成功、失败、取消与断网都清理临时媒体；不修改原件，不调用set_broken。

以同步upload明确success=true且无error回执作为保存确认；明确success=false且有error为rejected。HTTP异常、丢失/畸形回执及提交后取消都保留pendingReview，同编号再次执行只读复查，新编号也不能绕过未决记录。提交前转换/候选变化/取消没有写入，返回rejected。授权重新核对后，在当前真实权限下允许继续只读复查；读取中的访问代次变化则丢弃迟到结果。

未知回执核对为本客户端的恢复策略，不是已观察到的官方完整恢复流程：三档Thumbnail/get沿已知unit路由，空cache_key并禁用本地缓存，逐档SHA256与本次上传比较；视频沿已知Streaming.streaming v2，id=unitID、type=unit、quality=orig_h264、use_mov=true，下载后核对编码样本摘要、样本数/时长、音视频轨道类型与格式、方向及总时长。允许MP4→MOV重新封装，不接受仅文件大小/时长相等或候选从一批列表消失。官方static明确film_h264上传字段及orig_h264播放档位，但两者的实际绑定和空cache_key回读尚未在NAS验证；此处为明确标注的推断性读取，不能作为跨版本兼容结论。内容不匹配或不可读只保持未知，不重传、不假报成功。

本地合成测试已覆盖三档图片、仅视频/组合输出、个人/共享路由、MJPEG/PCM实际转H.264/AAC、MP4重新封装MOV摘要一致、旧图片/旧视频不确认、断网后恢复、重登核对、取消前后分界、相同/不同操作编号去重、权限不足、缺接口/转换能力、变更候选、错误与畸形回执、临时上传文件清理。原生读取中的零样本EditBoundary标记不计入媒体样本，实际视频/音轨必须存在；没有放宽既有媒体断言。最终命令和计数以Photos对齐账本为准。

PENDING_USER_VALIDATION：自动入口集成后，用专用合成媒体验证三种需求组合、实际编码/实况视频、未知回执回读（尤其film_h264→orig_h264及缓存行为）、共享权限和大视频取消清理。仅丢失回执才重新下载视频核对，会增加一次完整视频读取；持续无法核对时不能宣称完成。当前仍缺设置与调度、设备实际转换能力采集和可见目录优先链路，因此尚未新增可见入口或可安装包；这不是未实测白名单。回滚本轮枚举命令、上传/摘要核对与相关feature即可，无存储迁移；其他端界面未改。


### 自动预览设置与macOS调度增量（2026-09-30）

User.get/set v1的auto_generate_thumbnail来自既有官方个人设置static记录；当前共享服务增加automaticPreviewEnabled()和setAutomaticPreview(original:enabled:)。读取缺字段明确失败；写前核对原值，保存只写变化的该字段，回读一致后才确认；断网同操作只复查，不重发。Access携带可选开关，旧实现默认nil。无新增NAS参数、依赖、权限或本地持久化。

macOS设置菜单新增自动生成预览；中英、浅深色、加载/错误/正常/本机无转换器均有原生表单。设置编辑期间不领取新转换任务，当前任务可暂停；无本机转换器也可保存NAS设置供其他设备使用，没有待实测白名单。能力来源为ImageIO注册HEIC读取类型及AVFoundation的HighestQuality输出预设；这是系统声明的解码/输出能力，不是所有文件可解码的承诺，VC1不向NAS声明支持，实际格式/容器失败按单项报告并可继续。

照片页面活动期间空闲5秒扫描，已有完成或单项失败后0.1秒让出UI并继续下一项。每次只执行一个候选，复用现有Repository操作编号/互斥；不改变图库generation、当前月份、分页或选择，浏览/预览/选择仍可使用，写操作按既有串行规则执行。候选集合优先当前空间；同批次内当前预览优先，其次已出现在网格中的照片，再处理其他候选。个人与共享management分别读取，共享普通entry不能借扫描扩大权限；单个空间读取失败不会抹掉其他空间候选。离开页面/禁用模块取消worker和当前转换，保留已提交未知操作；返回后继续同编号只读复查。暂停阻止新任务但不阻止已提交结果核对；未知核对间隔逐步增长到60秒，不连续重传或密集重下视频。

已确认任务在当前会话去重，失败单项留在失败集合，点继续重试；后续任务仍可处理。成功按空间+预览单元更新缩略图加载标识，并仅回读已加载的相关照片详情，不刷新整个图库或重置历史月份。普通失败不调用set_broken，不伪报整个空间全部完成。NAS网页关闭自动开关会在下次领取前停止新任务；页面重进/刷新读取最新开关。

尚未覆盖官方完整优先链：本轮优先限当前list_convert_needed批次，原生网格onAppear不等同官方IntersectionObserver的0.8阈值；共享entry可下载目录的可见项，以及批次外当前/邻近/实况视频单元仍需独立读取状态与权限后加入任务，不能用management后台扫描替代。跨重启任务账本未持久化，不声称可以跨进程核对旧operationID；新会话仅从NAS重新读取候选。媒体回读档位/缓存兼容限制沿上节，不提升为真实NAS已验证。

PENDING_USER_VALIDATION：在照片→设置→自动生成预览保存开关，以个人及共享management的专用合成HEIC/视频验证出现预览、暂停/继续、网页关停、断网恢复和离页返回；历史月份/选择不应改变，原件不变。普通entry账号后台不得扫描整个共享空间。实际HEVC/VP9/MPEG2/音轨/长视频/实况兼容和回读档位均需真实NAS验收，回传仅脱敏版本、媒体类别、步骤、提示。回滚本轮设置命令与macOS工作循环/入口即可；NAS既有开关仍保留，可在网页修改，无本机存储迁移。


### 2026-09-30 原生可见比例与同批预览优先补齐

客户端按既有static证据实现80%实际裁切面积门槛，替换onAppear预加载即视为可见的近似。网格/相似条独立登记来源，任务同批内依次优先当前、前后相邻、实际可见，其余保持候选顺序；幻灯片使用已有播放集合。仅macOS调度和视口桥接改变，协议、接口参数和写结果证明不变。本轮Chrome工具报告锁屏，未产生新官方请求或行为证据。627项XCTest和6项本地化通过，原生裁切测试不代表NAS行为验证。普通entry权限/批次外/实况单元和2秒唤醒仍需后续补齐，不能据此提升证据等级。

用户解锁后static补证（本轮后半段）：AmeDefect是字符串`ame_defect`，不是数字枚举。需要缩略图由thumbnail.xl/sm判断，视频由additional.video_convert_status与转换器视频支持共同判断；视频编码来自additional.video_meta.video_codec。owner_user_id等于当前用户，或为0且有共享management/当前目录download权限，才允许构造可见候选；两种权限不能互相替代。HEVC视频/HEIC缺本机支持跳过；VC1/wmv3缺本机VC1或网页已有VC1+H264组合时跳过。优先级数值VC1为3、HEVC/实况视频为2、其余1。

官方预览回调2秒去抖：当前项有liveUnits时逐单元构造候选，否则用当前项；随后nextItems和prevItems仅非视频项加入（video、video360或live_type视频均排除）。thumbnailUnitId是前端归一化字段，缩略图状态来自按该标识索引的状态表；不得直接猜同名字段存在于原始Item响应。当前原生本轮只是已有候选的当前/前后同批优先，尚未复刻网页对相邻视频的排除、完整相邻集合、格式分级和2秒唤醒；后续应统一在可见候选构造切片实现，避免当前工作记录误报完全等价。

以上来自官方静态脚本，不是实际照片响应；未触发真实NAS下载/写入。浏览器控制台已清空并关闭，未保存原始脚本/响应。环境版本仍未知，不升级verifications等级。


### 2026-09-30 可见项与实况单元自动预览执行链

本轮static核对：官方Item列表归一化仅拆出additional.thumbnail保存状态表，并以其unit_id填入内部thumbnailUnitId，其余additional字段保持原值；video_convert_status仅被消费，不向NAS请求同名additional。客户端沿用Item.get v5(id数组，additional thumbnail/video_meta/video_convert)读取可选状态和video_codec，Unit.get v1沿既有id_item与orientation/resolution/thumbnail/video_meta/video_convert参数展开实况单元。没有猜新增NAS参数或把前端归一化字段当原始字段。该字段链是静态证据，真实响应兼容仍待用户验收。

共享服务增量automaticPreviewTasks(for:support:)与Task.sourcePhoto可选快照；旧初始化默认nil，旧服务默认无可见候选，不改变原有后台服务。可见来源复查profile、Item ID、文件名、大小、索引时间、目录、媒体类型、owner和Unit归属；个人要求本人owner，共享owner=0且管理权或实际目录view+download。使用物理来源API读取证明原件访问，不把相册只读权限替代个人原件写权。共享entry可以处理有下载权的可见照片，但后台list_convert_needed仍仅management。实况Unit要求对应id_item、唯一正数单元、明确photo/video、文件名和缩略图单元一致；不以Item ID下载视频单元。

只有xl/sm=ame_defect或视频video_convert_status=ame_defect才候选；实际HEIC/HEVC、VC1/wmv3和视频转换支持决定本机是否能处理，不增加待实测开关。生成、原件读取前后、上传前按候选原来源复查；提交后核对仅检查原件/单元身份与实际权限，不再要求状态仍为缺陷，从而允许已成功变ready。原JPEG摘要/视频轨道摘要只读核对、操作编号去重、临时文件清理保持；失去权限且回执未知不能转为已完成，更不能重传。

macOS可见照片和当前预览变化后2秒去抖触发，当前实况包含两个单元；相邻按next/prev且排除视频，网格沿80%阈值。优先读取这些来源，未产生任务才读后台批次；普通共享entry不触发全库扫描。完成/失败会话去重忽略来源快照，并按0=照片/非0=视频比较媒体语义，避免列表不同视频数字类型造成重复生成。完整多邻居/格式优先级与识别/共享管理、缓存设置仍后续审计，不提升为全网页完全对齐。

验证：新增7项Repository与3项Model合成测试，637项XCTest及6项本地化通过；最后视频类型语义去重补测单独回归Model。没有真实NAS照片读取、下载或写入。PENDING_USER_VALIDATION：在专用个人/共享entry/management目录中以HEIC、普通视频和实况媒体检查批次外预览自动补齐、2秒触发、权限收回、断网只读核对及网格位置保持。实际媒体格式、Unit/缩略图标识一致性、缓存和film_h264回读仍待实际套件版本验证。回滚新增可见重载、sourcePhoto与Model可见候选分支即可，未改变任何存储或其他端UI。


## 2026-09-30 共享空间设置与全局设置补证（photos-shared-space-settings）

环境沿用2026-09-28-photos-parity-observation.md；本日Chrome已解锁，仅读取已登录官方页面静态react_bundle.js，没有NAS设置读写或真实照片下载。DSM/build/Update/Photos完整版本仍未知，本段只属static。此前photos-library-read.md的UserInfo.me v1记录含enabled/is_admin；管理员身份不能代替共享空间entry/management访问权。

稳定组`photos-shared-space-settings`：内部、mixed、高风险。相对路径entry.cgi，以现有认证POST表单发送JSON业务值，不保存凭据。SYNO.Foto.Setting.TeamSpace的get/set/set_enable/list_permission/update_permission均v1；SYNO.Foto.Setting.Admin和User的get/set均v1；UserInfo.me v1。官方设置窗口仅DSM is_admin显示共享/全局页。

本轮实现范围：TeamSpace.get读取enabled、allow_root_folder_public及enable_person/enable_concept/enable_similar可选布尔；User.get的enable_home_service、team_space_permission与Admin.get的三识别全局布尔共同决定状态。缺字段不猜关闭，字段存在且全局开启才能编辑对应共享识别项。TeamSpace.set只发送修改字段，不发送enabled或个人/全局设置。启停单独调用TeamSpace.set_enable(enabled:boolean)，随后get读取状态；官方不允许个人空间未启用时停用最后一个空间。已记录team_space_disabled_by_share_folder_disabled=true时提供DSM恢复提示，但官方仍允许尝试启用，客户端不以该原因字段额外禁用按钮。

固定profile/管理员编号和原始完整设置快照；保存前重新核对UserInfo身份、User/Admin/Team状态。管理员身份失去时拒绝，不以management角色代替；新操作服从统一互斥，重复编号复查原操作，未知只读核对，不重新发set/set_enable。普通设置必须完整目标及条件匹配才能确认；启停可能让套件调整默认分类，按回读状态确认启停并返回实际设置给界面。关闭共享空间不等于删除照片；启停与顶层公开权限均有明确确认。NAS在最后回读与写入间仍存在竞态窗口，未见条件更新参数，不能声称原子条件写。

界面保存后只更新共享空间与分类；个人历史月份和选择保持。正在浏览被关闭的共享空间则退出并重新选择可访问空间；关闭当前共享分类回到相册首页。按实际管理员/接口权限提供入口，没有待实测人工白名单。字段未知、授权失败、网络错误采用现有错误恢复；不回退个人接口或提升其他账号权限。

进一步静态发现仍须实现：TeamSpace.list_permission/update_permission的成员角色与auto_backup；全局enable_user_sharing/display_photo_info_to_guest/exclude_extension/识别开关；enable_converted_original_jpeg关闭先清转换缓存。SYNO.Foto.Download clear_cache/get_cache_status/calculate_cache_size均v2，响应使用status（processing表示进行中）和cache_size。官方共享及个人设置页另含重新索引和缺陷预览生成，这些设置页动作未实现，不能等同于已实现的选择照片重建预览。最终全菜单审计继续。

五端影响：共享Core/Serving增量方法与命令/结果，默认方法明确不支持；macOS接入，iPhone/iPad管理设置不扩展范围，Windows/Android仅记录后续适配。无存储迁移、依赖、工具链或系统权限变化。回滚移除本轮共享设置入口/命令/可选结果，不触碰原个人识别及图库操作。

PENDING_USER_VALIDATION：以管理员打开设置，核对共享空间三识别项及公开顶层文件夹开关；保存后重新打开与网页比较。启停只使用用户授权的测试空间，核对最后空间限制、公开权限确认、现有分享影响、角色撤回/断网/网页并发修改与结果自动核对。个人2020.03位置和选择保持；共享空间停用后退出旧空间。回传脱敏版本、角色类别、步骤、提示与实际结果，不提供账号、主机、照片或凭据。尚无当前版本behavior-verified结论。


## 2026-09-30 全局设置与转换缓存（photos-global-settings-cache）

稳定组`photos-global-settings-cache`：Synology Photos内部、mixed、高风险，证据仅static。沿`2026-09-28-photos-parity-observation.md`未知DSM/build/Update/套件版本限制；2026-09-30在同一Chrome已登录页面只读取官方react_bundle静态资源，没有调用真实设置或缓存方法，也没有下载照片。以下函数名只定位此次证据，不作为运行时契约。

- `SYNO.Foto.UserInfo.me` v1返回enabled/is_admin/id。管理员页仅is_admin提供；共享照片management角色不能替代DSM管理员。
- `SYNO.Foto.Setting.Admin.get/set` v1：enable_person、enable_concept、enable_similar、enable_user_sharing、display_photo_info_to_guest、enable_converted_original_jpeg为布尔；exclude_extension为字符串数组。get还沿既有package_version读取。缺失字段不猜默认值、不写入；need_hevc不进入普通保存。
- `SYNO.Foto.Setting.User.get/set`和`SYNO.Foto.Setting.TeamSpace.get/set` v1：全局识别关闭后，将当前用户及共享对应的已知识别字段同步关闭；重新开启全局不自动开启这两个空间的识别。User的ame_status.has_hevc是真实JPEG控件条件。网页会再次检查编解码器并提供安装提示；客户端重新打开设置读取真实条件，不安装NAS软件。
- `SYNO.Foto.Download.clear_cache/get_cache_status/calculate_cache_size`均v2，均无业务参数；status字符串等于processing表示清理中，其他结束值的完整枚举未知；cache_size为非负字节数，客户端缺失/类型错误不当作0。固定个人统一Download路由，不随当前共享空间切换成FotoTeam。
- 路径由SYNO.API.Info提供，当前契约相对entry.cgi（索引/webapi/entry.cgi）；通过既有认证POST表单发送JSON业务值，不记录凭据。

官方eHo/eHi证实：Admin识别false联动User/Team草稿false，仅保存存在且变化的字段，数组排序后比较；eLN并发执行各设置差异，不能视为事务。eLk在关闭原尺寸JPEG前调用清缓存；eLW异常被网页捕获，不能据此认定清理成功；eLV/eL$读取cache_size和processing状态。客户端串行跟踪缓存、全局、个人、共享四类实际步骤，清理失败时停止后续写入并核对已尝试步骤，向用户报告部分结果，不声称原子保存。

格式候选由官方ng.PHOTOS/VIDEOS与RAW列表转大写组成：JPG JPEG JPE WEBP BMP PNG GIF TIF TIFF HEIC HEIF HIF ARW SRF SR2 DCR K25 KDC CR2 CR3 CRW NEF MRW PTX PEF RAF 3FR ERF MEF MOS ORF RW2 DNG X3F RAW MPG MPEG AVI ASF WMV MOV FLV F4V MP4 DIVX XVID M2TS M2T MTS M4V 3GP 3G2 QT。保留既有未知字符串和大小写，允许移除，不凭猜测增加格式。排除格式保存使用原数组精确值，顺序不影响比较。

每次保存固定profile/管理员身份和完整原快照，重新读取UserInfo/User/Admin/Team并检查访问代次；旧快照、撤权、缺字段、外来NAS、编解码条件改变均不直接覆盖。共享API增量方法有显式unsupported默认实现。统一操作编号与互斥防重复，丢失回执仅只读复查，不补发未提交步骤；部分完成后重新打开设置从当前原值提交剩余差异。确认实际已写字段和联动目标，不把一条成功回执当作整次成功。缓存有成功回执且状态结束时允许有新生成缓存，并显示实际大小；无回执则要求非processing且实际大小为0。未见任务ID或条件更新参数，清理/设置并发变化仍存在归因与竞态限制，不能升级为当前NAS行为验证。

界面：管理员原生分组表单、格式展开选择、缓存大小/刷新/清理，中英资源；全局影响和清缓存保存前确认。设置失败和缓存读取失败独立，后者不阻断其他设置。清理中自动刷新；提交后先沿既有短退避回读，再由照片页每15秒继续只读核对，离页停止调度、返回恢复，未完成操作不重发。照片月份与多选不刷新；当前识别分类实际关闭才回到相册。部分保存也按实际返回状态更新分类与原尺寸JPEG能力，无待实测人工禁用。

五端影响：Core/Serving/MutationResult向后兼容增量，macOS界面接入；Windows/Android仅计划与适配影响，iPhone/iPad不新增管理员设置UI。无新增存储、依赖、系统权限或工具链。回滚移除本组原生入口、命令/结果字段与Repository方法即可，不更改既有用户数据格式。

PENDING_USER_VALIDATION：用户在专用NAS环境用管理员逐项切换识别/普通用户分享/访客详情/排除格式/JPEG，重新打开与网页对照；全局关闭识别应联动当前个人和共享开关。清理缓存不删除原件、状态自动结束；断网不重复提交，部分完成可重新打开继续。保持2020.03月份及选择，关闭正在浏览的识别分类时返回相册。检查非管理员、共享entry、缺HEVC、并发网页改设置、缓存清理中与重新生成缓存。仅回传脱敏套件版本、角色/格式类别、操作步骤、界面提示与预期/实际差异，不提供主机、账号、照片或凭据。真实NAS读写、其他端构建尚未验证。


### 共享成员与自动备份权限后续static补证（尚未实现）

沿photos-shared-space-settings组记录，2026-09-30官方eM9/egR/eM6/exU/eU6/eLy确认：TeamSpace.list_permission v1无参数，data直接为成员数组（不是list容器），每项type/id/name/permission/auto_backup；前端仅把permission重命名为role。TeamSpace.update_permission v1接收list数组，每项action(update/delete)、type(user/group)、id、permission(entry/management)、auto_backup。新增使用update，删除传原role及auto_backup；候选列表复用Sharing.Misc.list_user_group v1的data.list。响应写回执结构仍沿现有空成功，必须回读列表证明最后结果，未实际写入。

官方角色选项仅entry与management，none属于无访问状态。新增management自动开启auto_backup，新增entry默认false；现有成员改management将auto_backup=true，降为entry保留原auto_backup值。management行不可单独关闭自动备份；整列全选只修改非management成员。系统type=group且name=administrators受保护，角色、自动备份和移除均不可编辑，这一特殊原始系统名不是翻译文案。

entry新增或由management降级时，网页立即打开按该成员编辑共享文件夹权限窗口；取消可撤回新增/降级。该窗口使用FotoTeam.Sharing.FolderBatchPermission.update_all_by_member/update_by_member与临时entry授权/撤销流程，不能只增加角色下拉框就宣称该完整主流程已对齐。现有客户端按文件夹权限表单可复用部分组件，按成员批量权限的确切结构和最终回读仍需下一切片补证。移除成员及管理降级有确认；保存后更新列表，浏览共享目录时重载当前目录权限。

本次只有官方静态资源观察，没有读取真实成员/目录权限或调用写接口，版本未知不增加兼容验证。全局设置最终包源码已冻结，本补证仅记录下一步，不包含共享成员实现。Chrome控制台已清空关闭，无原始资源落盘。

### 2026-09-30 按成员目录权限静态补证

稳定组 `photos-shared-space-members`；环境沿2026-09-28-photos-parity-observation.md的本日记录，DSM/build/Update/套件完整版本仍未知，仅为static，不追加当前设备兼容验证。通过已登录官方页面只读获取静态资源，没有读取真实成员、文件夹或执行权限写入。

- `SYNO.Foto.Sharing.Misc.list_user_group` v1：此成员管理用途不传业务参数，data.list包含当前用户；不能沿用相册邀请列表的过滤本人逻辑，也不传team_space_sharable_list。
- `SYNO.Foto.Setting.TeamSpace.list_permission/update_permission` v1：结构见上节。管理入口核对UserInfo.me的DSM管理员身份及TeamSpace.get.enabled，不能以共享照片management角色替代管理员。
- `SYNO.FotoTeam.Browse.Folder.get` v2无业务参数读取共享根；list v2使用id、offset、limit、sort_by=filename、sort_direction=asc、additional=[sharing_info]。网页初始200项并继续分页；目录返回id/name/parent，sharing_info包含privacy_type及permission数组，权限项只需type/id/role，不要求name。
- 目录树可编辑根下两层。第一层可展开第二层，第二层不继续展开。按type和原始id类型精确匹配成员直接角色，不推导群组成员身份。public-view/public-download提供公开权限下限，直接角色空值不等于有效无访问；第二层父目录既非公开也无该成员权限时不可编辑。取消第一层私有目录查看权限提示会清除子目录权限。
- `SYNO.FotoTeam.Sharing.FolderBatchPermission.update_by_member` v1：permission={id,type,list:[{folder_id,role,action:"update"}|{folder_id,action:"delete"}]}。删除不传role。
- 同API的`update_all_by_member` v1：permission={role,action,member:{id,type}}，action明确为check_all或uncheck_all；role层级view<download<upload<manage。全选只提升低于目标的成员权限，取消某层权限把达到该层的角色降到前一层，不是无条件给所有目录赋同一角色。网页先提交全局批量，再提交逐目录差异。
- 网页新entry成员先临时update_permission授权，再写目录；取消新建会清临时授权。原生实现计划在本地保留草稿，用户最终确认后才分阶段提交，不能把多次请求当作原子事务；未知回执只读核对，必须跟踪成员与目录阶段的部分结果。

路径由能力发现取得，已知相对entry.cgi；认证POST沿既有客户端，JSON对象用业务参数编码。成员/目录快照不持久化；缺少关键权限字段按读取失败恢复，未知原始角色保持原值，权限不足不退回其他空间。尚未验证写后传播时序、批量请求对所有后代的最终覆盖及部分失败返回结构；真实NAS验收由用户执行，当前静态证据不证明写行为。


### 2026-09-30 共享成员组合保存与结果核对实现

photos-shared-space-members新增Core组合命令setSharedMembers、目录草稿/批量层级规则和sharedMembers可选结果；服务增加完整两层目录快照默认unsupported接口，既有分页方法保留。Repository沿既有操作编号互斥和确认前prepare执行成员→批量目录→逐目录差异；没有在读取或取消草稿时临时写入NAS，也不做隐式回滚。成员变更仅发送实际增删/角色/备份差量，新增前复核完整候选，移除携带原权限和auto_backup。既有未知成员角色/系统administrators群组原样保留，名单顺序不算权限变化。

目录草稿保存完整两层快照，保存前完整回读比较身份及权限摘要；不能以只加载的第一页冒充全库批量范围。新增/降级entry成员的目录计划包含在同一命令，先保存成员再应用目录；同一成员最多一个计划。管理角色不能混入受限成员目录计划。批量check_all/uncheck_all按层级变换，逐目录差异随后覆盖，私有第一层撤销查看的子目录结果一并核对。公开权限下限内的角色按网页等价语义比较；未改变的未知目录角色不阻断其他已知目录的单项编辑，批量仍需要完整已知角色。

每个步骤记录尝试、明确回执与明确失败。重复操作编号只读取原记录结果；有未知写入时新命令被既有互斥拒绝。失去回执不补发任何步骤；若成员已确认、目录未尝试，自动结束为部分完成。收到结构化success:false不推断完全未执行，回读真实目标并报告部分结果。网络断开/响应损坏仍无法证明最终状态时保留pendingReview。批量后单项覆盖的中间/最终角色都参与前一阶段核对，不能让后一步的部分失败掩盖前一步已完成的批量设置。

结束前再次读取本人的实际共享空间设置，结果携带当前成员及sharedSpaceSettings，供原生Model同步访问权限；不从某个被编辑群组推导登录用户最终角色。当前尚未接入原生表单及Model自动轮询/位置保持，不能把Repository自动回读等同用户可用完整流程。接口无条件更新参数，最后核对至写入仍有竞态；无法取得最终权限时不伪造成功。完整目录扫描可能增加大量目录下的读取耗时，真NAS传播时序、目录后代权限和跨版本行为仍未验证。

无新增存储/依赖/权限/工具链；Apple协议增量默认实现保持源兼容，Windows/Android计划同步，iPhone/iPad暂不增加管理员成员UI。PENDING_USER_VALIDATION将在完整原生入口交付后执行：使用专用测试成员新增/移除/管理与受限切换，逐级目录授权、批量后单项覆盖、备份开关，确认草稿取消不写NAS，断网自动核对且不重复，部分失败重开表单呈现实际状态，个人历史月份保持。只回传脱敏版本、权限类别、步骤、提示与预期/实际差异。


### 2026-09-30 共享成员原生界面与权限更新

macOS Photos新增共享成员管理窗口：搜索、添加用户或用户组、自定义/管理角色、移除、逐成员及批量自动备份；新增或降级自定义权限时打开两层目录编辑器。目录支持搜索、展开、逐项角色及四级全体授予/撤销；公开访问下限独立显示，未知权限保留，系统管理员组不能编辑。成员和目录都只在内存编辑，目录“完成”返回草稿，主窗口最终确认才提交固定组合命令。取消不写NAS，连续批量操作按当前草稿组合，父目录撤权清理子项草稿；无待实测人工白名单。

Model将共享成员保存纳入持续自动核对，断线只回读，部分完成要求重开当前权限而非重放旧命令。以结果中的本人真实权限更新空间及能力；个人时间线保留月份、选择及已加载照片。共享访问撤回退出旧空间，降级后清理旧预览并重读原历史查询；权限变化使先前在途分页/预加载响应失效，避免晚到旧照片重新显示。新增45组中英文资源，没有存储/权限/工具链变更或其他端UI改动。

验证：692项XCTest（Repository441、Model194、Converter8、Events20、Appearance29）及6项本地化通过。原生UI两项/52张合成截图覆盖中英浅深色、正常/空/关闭/加载/错误/筛选为空；实际点击备份开关，打开最终确认后断言组合命令，目录实际选择上传权限、展开并按完成只返回草稿不写入。独立集成及只读对抗复核检查取消零写、protected/未知角色、候选读取失败不阻断既有成员编辑、公开权限下限、连续批量组合、父目录影响、保存结果部分/未知、本人权限刷新及在途页隔离。真实NAS传播、权限组合、网络恢复和实际备份仍未验证，证据等级保持static。

PENDING_USER_VALIDATION：使用专用测试成员，在共享成员管理中新增/移除、自定义与管理切换、修改自动备份，编辑第一/二层目录和连续批量后单项覆盖。先取消确认NAS未变，再保存检查最终权限；保存时断网后恢复，应自动核对且无重复提交。个人2020.03位置和多选保持；修改自己的权限时不可继续显示或操作已失去访问的照片。需回传脱敏版本、角色、步骤、提示及实际/预期差异；不提供账号、地址或照片内容。


### 2026-09-30 自动预览完整相邻范围与优先顺序补证

沿既有photos-automatic-preview组和未知版本环境，只读官方脚本，等级static。eO9默认后3/前2；前项按远到近排列，后项按近到远。eO8对前项、当前、后项去重计数：不足4时后项仅第一项；正好4时后项去掉最后一项；不足6时前项仅最后一项。相册/目录完整列表按取模循环，时间线按已加载日期分段取项、遇到未加载项停止；不得为预取主动加载历史月份或改变浏览锚点。YR当前实况逐单元，其后nextItems、prevItems排除视频，2秒去抖。

Ea分级：VC1/wmv3视频=3，HEVC视频或实况视频单元=2，其余=1；HEIC照片仍为1。后台list_convert_needed候选统一4。ehJ消费顺序为手动重建→1→2→3→4；同级中当前/相邻插入队首，保持当前、next、prev顺序。因此不能让当前VC1压过相邻普通照片，也不能在第一项高等级候选出现时停止查找其他低等级可见候选。官方tier1支持桌面建议批量，原生沿现有单任务转换器串行执行，不新增并行转换。相邻计数先缩减再排除视频，不能越过范围补找非视频。

### 2026-09-30 整库维护静态候选（尚未接入）

官方hB为Index.get/reindex v1，个人/共享分别SYNO.Foto.Index与SYNO.FotoTeam.Index。个人和共享设置中的eUj组件：get无业务参数、读取data.basic计数；每15秒轮询，basic>0表示重新索引进行中。重新索引调用reindex(type=basic)，前端先暂设basic=1；错误100显示任务失败。缺陷预览入口依赖网页H264能力，调用reindex(type=thumbnail)，点击后本地设置进行中，不以此证明NAS完成。另见个人Index.reindex_all_user v1(type=thumbnail)和metadata动作，但对应范围/权限及可靠最终完成证据仍待独立实现核对。本段只是候选证据，不注册运行时兼容或提前开放维护入口，不执行任何NAS写入。


## `photos-library-maintenance`：当前空间整库维护（2026-10-01）

- 分类：Synology Photos内部接口；POST `/webapi/entry.cgi`，按能力发现路径发送，JSON参数。个人`SYNO.Foto.Index`、共享`SYNO.FotoTeam.Index`，`get`与`reindex`均v1。
- 来源：2026-09-30官方react_bundle静态调用绑定；环境见`2026-09-28-photos-parity-observation.md`。DSM/build/Update/Photos完整版本未知，不绑定已有lab-a基线。首次静态发现2026-09-30；2026-10-01仅本地合成验证，无真实维护API调用，证据等级仍为static。
- `get`无业务参数；data含basic、metadata、thumbnail、geo_coding、face_extraction、person_clustering、concept_detection计数。本实现读取必需整数basic/thumbnail，缺失、错误类型、负数均报错，不当作空闲。
- `reindex(type="basic")`重新索引当前空间；`reindex(type="thumbnail")`补生成格式支持相关异常预览。没有任务编号或单次任务版本。官方按15秒读取basic状态；缩略图按钮另有本地提交状态，不能由此证明所有处理阶段完成。
- 个人要求启用home服务和当前用户身份；共享要求启用空间、真实DSM管理员及共享访问。缩略图动作依赖User.get返回`ame_status.has_h264`，不是本机HEVC能力；不支持此动作不影响重新索引。
- 能力依赖UserInfo.me、Setting.User.get以及共享Setting.TeamSpace.get v1。弹窗读取不写入，最终确认固定profile/user/space/action；提交前重新核对身份、空间状态和对应计数。旧快照已忙碌、异NAS或异用户拒绝执行，不把当前空间动作扩大为所有用户。
- 操作编号复用只读核对；已有未确认命令时禁止新维护。明确success:false（含code100）结束为失败；无回执、超时、取消后不重复提交。权限撤回中止读取，缺接口不阻断普通浏览。
- 客户端结果策略：明确接收回执且对应计数归零才结束本次核对；这是当前索引阶段无待处理项的证据，不声称所有识别阶段或NAS后台作业都已完成。回执丢失后即使计数经历正数到零也无法归属于本次命令，保持未确认并持续只读检查；无任务ID意味着此情况可能长期无法自动证明结果，不能伪造成功。
- macOS原生窗口含空闲、处理中、实际能力不支持、加载、错误与重试，双语/浅深色；操作确认取消零写。提交后复用短期核对和15秒持续轮询，局部更新，保留历史月份、选择和已加载照片。无人工待实测开关。
- Core新增LibraryMaintenanceStatus、libraryMaintenanceStatus默认unsupported和maintainLibrary命令。Adapter为SynologyPhotosRepository；测试位于同名RepositoryTests、SynologyPhotosModelTests、WorkspacePresentationTests。无新存储、工具链或第三方依赖。
- PENDING_USER_VALIDATION：在专用库分别测试个人/共享basic和thumbnail，取消应无写入，确认后观察状态与网页一致，重复点击不重启作业；维护时历史月份与多选保持。断网恢复只核对，不再发起维护。回传脱敏版本、角色、动作、提示、计数/状态与预期差异，不回传照片、账号、地址或凭据。
- 后续缺口：官方新编解码器欢迎流程管理员使用`SYNO.Foto.Index.reindex_all_user(type="thumbnail")`；本轮没有实现该全用户动作，不能将当前空间维护当作全用户功能完成。


### 2026-10-01 全用户格式提示与失败标记 static 补证（下一切片）

只读官方react_bundle，未执行真实设置、维护、媒体读取或写请求。当前完整版本仍未知，沿2026-09-28观察环境记录；临时源码变量已删除确认undefined、控制台清空关闭。以下为已定位的函数绑定，不是NAS行为验证。

`photos-library-maintenance`增量：`SYNO.Foto.Setting.Wizard.get/set` v1。get无业务参数，data.prompt为name/show对象数组；前端getWizardPrompt读取该数组，只有name=new_codec_installed且show=true才显示提示。生成与“稍后”都推进提示队列，最终set发送`prompt:[{name:"new_codec_installed",show:false}]`，不发送其他设置字段。点击生成先推进提示，再以当前is_admin选择Foto.Index.reindex_all_user v1(type=thumbnail)或个人Foto.Index.reindex v1(type=thumbnail)，并显示等待提示；未发现全用户任务编号或可归因的终态读取。取消只更新提示已读，不启动维护。客户端后续需保留固定身份/范围与只读结果核对，不能用个人计数证明所有用户都处理完成，也不能打开界面即触发写入。该提示、已读保存和全用户动作仍未实现。

`photos-automatic-preview`补证：eAU按缩略图与视频阶段分别处理。下载/缩略图转换/上传链抛错时，EXTERNAL_CONVERT_TIMEOUT、WORKER_TO_PC_CLIENT_CONNECTION_ERROR、CONTENT_TO_WORKER_CONNECTION_ERROR触发依赖状态更新，其他抛错调用ConvertedFile.set_broken v3，id=[unitID]、type=[photo]；上传结果success=false只打印警告，不直接进入标记分支。视频仅在取得转换文件、支持视频转换且need_video时尝试，视频上传抛错调用同方法type=[video]。个人/共享按单元来源分路由。原生错误类型不能机械映射网页桥接错误码；本地取消、权限撤回、临时断网、未知上传回执和确定转换失败必须区分。现有代码没有set_broken，后续仍需实现对应语义及可证明的结果读取，不能把候选从有限批次消失当作完成。


### 2026-10-01 新格式提示原生接入与结果语义

沿前节static证据实现codecPrompt读取、respondToCodecPrompt组合命令与macOS原生提示。打开页面仅get；生成前固定当前账号与管理员/个人空间状态并重新核对，管理员调用reindex_all_user、普通用户调用reindex，均type=thumbnail。实际点击生成才写入，先取得生成接收回执再将唯一new_codec_installed提示标为已读；“稍后”只保存该提示，其他提示保留。此顺序避免启动明确失败却隐藏提示，无全用户最终完成证据，界面只显示“已开始生成预览”。

同操作编号只读原记录；未知接收回执不能用提示已读或个人计数追认，也不重放生成。生成已接收、保存提示明确失败返回部分成功，原生继续操作仅保存提示；同会话已接收标记禁止再次生成，观察到提示关闭后才允许将来再次出现的新提示。没有新增持久化，重启恢复不作保证。保持历史月份、选择和分页，不因管理结果全量刷新。

接口缺失或提示读取失败不阻断图库，设置入口提供重试。缺失字段、重复同名提示、账号变化、个人空间关闭或管理员身份变化均不误发生成；管理员全用户范围不依赖其个人空间开启。沿既有权限与重复提交保护，无人工待实测禁用。

PENDING_USER_VALIDATION：在出现新格式提示的专用环境分别用管理员/普通用户核对范围；“稍后”应只关闭提示，生成应由NAS后台处理且历史月份不动。检查断网恢复不重复生成，已接收但提示保存失败后继续只保存提示。回传脱敏套件版本、角色、动作及提示，不回传账号、照片、地址或凭据。完整构建与测试记录见Photos对齐账本；本地验证不提升static等级。


2026-10-01失败同步下一切片static补证：同一官方react_bundle的预览状态枚举明确包含Broken="broken"、AmeDefect="ame_defect"、Converting="converting"、Ready="ready"、Regenerating="regenerating"、SpaceDisable="space_disable"、None="none"。缩略图解析按请求尺寸读取状态，ready时生成媒体地址，非ready直接使用该尺寸状态；字段未定义还会在UI层回退为broken。因此结果校验必须读取实际字段值，不能把UI默认broken或候选批次消失当作写入成功。视频组件默认broken同样不是NAS已标记证据。本轮仅静态读取，无真实标记或媒体下载；实现仍待下一切片。


### 2026-10-01 原生自动预览失败同步

沿static的ConvertedFile.set_broken v3实现当前单元的photo/video阶段标记，个人/共享分别路由，不改原件内容。操作属于用户已开启自动预览的失败处理；提交前再次校对候选、身份、真实权限和访问代次，其他客户端已生成或用户取消不再标记。接收成功或可见照片真实broken字段确认后仍返回生成失败，completedCount=0，界面引导选中照片“重建预览”。同操作编号不重复标记。

原生错误分类依据本地AVFoundation头文件和已有转换器错误：明确不可读媒体、编码失败、AVError.decodeFailed/invalidSourceMedia/fileFormatNotRecognized进入标记；CancellationError、URLError、权限/身份或候选变化、未知接口/HTTP返回、磁盘/内存资源、编码器缺失/暂不可用和无明确原因的exportFailed不进入。不能将网页桥接错误码机械套到原生系统；这些错误沿原错误/重试路径。上传返回success:false保持拒绝，传输/解码回执未知仍核对媒体内容，不另外set_broken，避免破坏可能成功的上传。

结果校验：明确同步接收回执确认标记已被接收；失去回执时，有sourcePhoto的任务重新取得同单元及权限，只接受thumbnail.xl/sm均为实际broken（photo阶段）或video_convert_status实际broken（video阶段）。missing、ready、UI回退和候选批次消失均不是该结果。后台任务只含unitID、没有已证实的单元直接状态查询，回执未知保留pending，不猜Item编号、不重复标记。原应用退出后的未决恢复仍不保证，未新增持久化。

PENDING_USER_VALIDATION：在专用库启用自动预览，用可复现转换失败媒体核对网页失败显示及重建预览恢复；个人、共享目录和实况视频分别核对目标单元/阶段。断网/取消/权限撤回不应新增失败标记；丢失回执恢复不重复提交，历史月份不跳转。回传脱敏套件版本、媒体格式、操作与显示差异，不需真实媒体、账号或地址。自动化命令和构建结果见对齐账本，本地测试不提升static等级。


## 2026-10-01 临时分享与冻结相册：静态发现及接入进度

沿用环境`2026-09-28-photos-parity-observation.md`的已登录官方页面只读资源。当前DSM/build/Update/套件完整版本仍未取得，不借历史环境推断；仅static，未执行写入或真实成员读取。路径由SYNO.API.Info发现，候选entry.cgi，POST；字段来自官方处理链，不能视为已验证响应契约。

| 端点/字段 | 官方静态参数与行为 | 原生差距 |
| --- | --- | --- |
| NormalAlbum.create v1 | name、item编号数组、shared=true；随后读取Album分享信息并显示分享表单 | 现有快捷流程创建普通私有相册，不含临时分享语义 |
| Album.get v4 | id数组、additional=[sharing_info]；读取temporary_shared与shared及分享配置 | 当前Collection没有临时标记，不能据名称猜测 |
| Passphrase.set_shared v1 / Album.delete v1 | 停止临时分享先policy=album、album_id、enabled=false，再删除id数组；取消初始临时分享也走清理 | 需区分普通相册与临时相册，取消不能误删普通相册 |
| NormalAlbum.copy v1 | name、source_album_id；返回album.id；临时分享的停止并保留副本先复制，再停止/清理旧项 | 原生需确认新副本身份及成员后才清理旧项，未知回执不能重放或猜成功 |
| Album.get v4 | additional=[condition_object]；freeze_album、cant_migrate_condition、condition_object用于迁移提示 | 当前冻结条件相册未建模 |
| NormalAlbum.set_unfreeze v1 | id；官方“保存为相册”动作 | 当前没有入口与核对，不能把请求接收当完成 |
| 条件重建组合 | 编辑新条件并成功建立替代相册后，才删除旧冻结相册 | 需保留失败/未知结果下的旧相册；沿已记录ConditionAlbum契约，不猜新接口 |

权限与副作用：临时分享/复制/删除会改变相册和共享状态，需实际所有者/分享权限、明确用户操作、固定目标与去重、逐阶段最终回读；原始照片删除不属于这些动作。能力探测必须确认相关方法版本和元数据，不得通过静态字符串宣称NAS兼容。错误语义、默认公开范围及副本继承字段仍待补证；无证据时不可猜字段、不可把普通相册流程作为完整对齐替代。只读降级为展示已有相册，不触发自动创建/清理。

五端影响：macOS先做独立共享模型/Repository增量切片；Apple移动端共享包编译需同步，界面仍按专项范围；Windows/Android只记录等价结果和待接入，不改其UI。当前没有增加领域枚举或网络请求，无存储迁移；候选回滚仅移除此记录/候选说明，不影响已有分享。首次发现2026-10-01，最后行为验证无，覆盖环境无，自动化与fixture待实现切片。静态资源仅留浏览器内存，完成后已删除并清空控制台，无原件下载或未脱敏落盘。


### 临时分享底层接入（组合界面仍待完成）

Core新增createTemporaryAlbum(name,photos)、copyTemporaryAlbum(id,name,original)、deleteTemporaryAlbum(id,original)及SharingState.isTemporary可选字段。Repository使用已有albums能力和静态端点；新建还需实际sharing能力及非空选片，删除只接受本人已停止的临时相册，原分享快照（包含临时标记）发生变化即拒绝。

创建/复制回执仅要求明确album.id，其他信息必须重新读取，不假定回执携带完整相册。创建核对名称、所有者、临时标记和完整成员；复制前保存来源全部分页成员身份，复制后要求不同的新编号、名称、本人所有、temporary_shared=false、shared=false及完整成员一致。分页丢项、重复、字段缺失和丢失编号不能确认；同一操作编号不重发。单独复制从不关闭或删除来源，清理命令从不调用照片删除。组合流程后续必须确认副本后再停止/清理，且处理创建中关闭窗口和未知结果；当前UI仍是普通相册流程，未宣称临时分享闭环完成。

以上不新增持久化、原件读取、外部写测试或验证白名单；只读核对不自动补发写入。真实NAS仍PENDING_USER_VALIDATION，iPhone/iPad与其他端构建尚未执行。五端兼容计划已同步；冻结条件相册仍为未实现候选。


### 2026-10-01 临时分享macOS组合流程接入

前节底层状态为历史记录；当前macOS已接入创建中取消、设置关闭/Esc清理，以及停止时保留普通副本。模型持有阶段，确认复制→停止→清理，未知回执只核对原编号；明确失败可重试或保留现有相册。deleteTemporaryAlbum新增默认nil的preservedCopyID，此字段仅为本地校验上下文，不作为NAS参数。存在副本时清理前重新核对双方完整成员及所有权/临时/分享状态；变化则不删除。没有改变Item原件，不进行用户NAS写测试，不提升static等级。

沿既有Passphrase链，分享范围不变但没有可用链接时仍取得并启用链接；disabled状态维持既有空操作语义。UI确认、权限、去重与最终回读保留；完整自动化、独立测试包和PENDING_USER_VALIDATION步骤见Photos对齐账本。冻结条件相册仍未实现。


### 2026-10-01 冻结相册公开帮助交叉核对

Synology官方[升级功能变化说明](https://kb.synology.com/en-global/DSM/tutorial/What_functions_have_changed_after_Photo_Station_Moments_upgraded_to_Photos)的搜索索引摘要确认两条用户路径：修改不再支持的条件以解冻，或保存为普通相册并保留已有照片、停止自动添加。直接页面读取仅返回站点外壳，未取得完整正文或请求。此结果仅支持既有产品语义，不补足freeze_album/cant_migrate_condition的实际类型、接口响应、写后状态或重建继承规则，也不提升任何API验证等级；不能据此猜测字段完成实现。无需NAS会话，未发送用户资料。

### 2026-10-01 冻结相册恢复与重建静态补证（待接入）

来源同[当前只读环境](../environments/2026-10-01-photos-remaining-observation.md)，版本仍未知，未执行NAS写入。官方Album.get v4的additional包含condition_object；返回name、cant_migrate_condition对象、additional.condition_object对象。弹窗以cant_migrate_condition的键显示无法迁移的项目，固定顺序recently_add、recently_comment、update_time、people、geocoding、rating、camera、lens、flash；未知键不应被客户端猜成已迁移。

官方仅当condition_object不是唯一字段user_id=0时提供“编辑条件”；否则只提供“保存为普通相册”和忽略。普通恢复调用SYNO.Foto.Browse.NormalAlbum.set_unfreeze v1、id整数标量，然后把freezeAlbum设为false并通知解锁。静态代码未读取真实写后响应，不能据乐观UI证明成员/权限保持。

重建沿现有条件相册表单：载入原name、源空间user_id映射、folder_filter、item_type、time首项、rating、条件与策略以及nonmigratableCondition；确认后ConditionAlbum.create v3返回新album，跳转新编号，再派发旧相册DeleteAlbum(albumId:旧编号,shouldGoBack:false,needRemoveShared默认false)。不是原编号set_condition，也不是复制共享授权。创建参数沿普通条件相册name/user_id/规则；尚需补读删除worker和非迁移条件编辑转换，不能宣称原分享链接/成员自动继承。未创建或删除任何真实相册。

旧相册删除worker补证：ey0调用统一SYNO.Foto.Browse.Album.delete，id整数数组；ey1在调用后移除本地相册列表。官方worker吞掉删除失败后仍继续更新UI，因此客户端不能照抄乐观结果，必须保留新旧相册编号并回读旧相册不存在后才确认替换。nonmigratableCondition在表单状态中独立保留，未并入普通条件创建参数；不能据此臆造权限/分享继承。


补充冻结条件转换：官方eTj分别初始化condition_object与cant_migrate_condition，后者只用于提示不可迁移条件，不进入create的condition。eTR从表单当前的来源、目录、媒体、时间、评级、已支持条件和策略重建参数；不是把旧cant_migrate_condition并入新请求。eTk在condition_object仅含user_id=0时只提供“保存为普通相册”，否则同时提供编辑条件。eTX创建新相册成功后导航新编号，再发起旧相册删除；未见继承旧分享的调用。冻结标记来自普通Album列表记录的freeze_album，不能根据type=condition推断冻结。全部为2026-10-01官方静态资源证据，无真实NAS写入验证。


冻结菜单范围复核：eFG的eIM(sharedType)分支即“由我共享”，即使freezeAlbum为true仍提供重命名、复制链接、停止分享、编辑分享及删除；只去掉收集照片。仅本人普通相册列表的冻结分支只显示删除，详情另有恢复提示。因此客户端按页面隐藏普通列表入口，但Repository不能一概拒绝冻结相册的既有分享管理/重命名；成员贡献和上传按冻结状态限制；封面以其下方预览菜单补证为准，保持可用。此前“冻结时不能分享”只适用于普通列表的新分享入口，不应扩展成所有分享管理禁止。来源仍为2026-10-01官方react_bundle.js静态代码。


预览菜单进一步复核：官方freeze_album_lightbox包含SLIDESHOW、DOWNLOAD_ITEM、ADD_TO_ALBUM、ROTATE、SET_COVER，edit_face变体另含EDIT_FACE。冻结并不禁止设置封面，也不禁止把现有照片添加到其他相册；限制的是本相册手动成员增删及上传。实施时保留这些既有能力，不把“普通列表只显示删除”推导为所有入口通用权限禁令。核对后删除临时静态资源变量、清空控制台并关闭，刷新官方页面释放控制台词法变量；未保存原始脚本或NAS资料。


### 2026-10-01 预览重建角色分支补证（static，待修正）

官方完整预览菜单eej显示：team_download_lightbox提供SLIDESHOW、DOWNLOAD_ITEM、ADD_TO_ALBUM、REGENERATE_PREVIEW、COPY_TO；team_guest_download_lightbox仅幻灯片/下载，team_view_lightbox仅幻灯片。album_photo_provider_not_management_lightbox及shared_album_photo_provider_not_management_lightbox提供REGENERATE_PREVIEW，普通shared_album_download_lightbox只有下载。原空间关闭的album_space_disable_lightbox只有REMOVE_FROM_ALBUM；freeze_album_lightbox含设置封面、加入其他相册、旋转而不含重建/删除。菜单是静态入口证据，不能直接推断NAS写接口最低权限或绕过来源/相册资格检查。

现有macOS将regeneratePreviews归入canModifyOriginal，Network预检requireManagedFolder，因此已确认原生权限分支比上述官方入口收紧，尚需worker/参数/回读契约续查与独立修正。不将所有下载者泛化为可重建，也不运行真实NAS写入。具体剩余范围见Photos对齐账本的预览角色审计。


### 2026-10-01 冻结相册原生接入与验收边界

冻结标记独立于相册类型；本人快照同时读取名称、freeze_album、cant_migrate_condition及condition_object。普通恢复发送NormalAlbum.set_unfreeze v1、id标量，只在回读freeze_album明确false后确认，不以缺失字段或请求接收代替解冻结果。条件重建复用已有ConditionAlbum.create v3参数，完全从当前受支持表单生成；收到新编号并回读身份/所有权/完整条件后才删除固定旧相册。删除前旧快照变化则保留新旧相册；创建未知且无编号不猜同名成功，删除未知不重放，明确失败返回部分完成。不额外继承旧分享，不删除原照片。

界面提供普通恢复及可用时的条件重建，显示不支持条件与旧分享不继承的确认。仅user_id=0的旧规则只显示普通恢复。普通恢复不依赖重建目录读取；窗口关闭仍保留模型中的操作与持续核对。冻结成员贡献/上传/收集受限，既有分享管理及封面按上述官方菜单保留。共享领域采用默认字段及默认不支持方法，不增加移动入口或持久化。

本地798项XCTest、6项本地化、1项原生UI/28张合成截图及独立Release包通过，命令见Photos对齐账本。PENDING_USER_VALIDATION覆盖真实冻结样本、普通恢复成员保持、条件重建新旧身份与分享、断网和失权；版本仍未知，证据仅static。回滚仅移除客户端入口/调用，不自动反向修改已恢复的NAS相册。


预览角色worker补证：eCS（预览）和eCI（多选）调用eCw，后者仅向按原空间选择的Foto/FotoTeam.RegeneratePreview.set_regenerating v1发送item_id数组；随后eCT分派队列单元到既有转换链。没有发送album_id或额外授权参数。菜单选择先检查来源空间可用，再区分本人提供者及共享原目录管理者；已登录共享目录download与guest_download不同，后者没有重建。以上仅读取官方静态代码，不能据此豁免身份/会话/实际NAS权限验证。


### 2026-10-01 预览重建角色原生接入

Repository为重建使用独立资格检查：普通个人来源保持目录管理验证；普通共享目录接受实际view+download、目录管理或全空间管理。相册来源统一Foto.Item.get v5携带album_id读取原件身份及provider_user_id，再读Album v4核对相册类型/冻结状态；本人提供者可继续，共享其他提供者要求原目录管理，普通个人相册其他提供者不因相册下载/所有权获得重建权。个人条件及冻结相册保留本人原件管理路径。冻结相册在多选菜单保留重建，预览窗口单独省略该入口，不在Repository全局拒绝。来源空间必须开启；身份变化、删除待决、访问代次变化均拒绝。

写请求仍使用原空间RegeneratePreview.set_regenerating(item_id数组)及regenerate_preview_by_nas(unit_id)，没有臆造相册写参数。本机转换后的权限复查复用同一规则；结果读取仍携带原相册上下文，未知回执不重放。macOS模型单独判断本人贡献者与冻结状态，选择入口与预览工具栏进入既有确认表单。普通下载者不因此获得旋转、删除或元数据写入权限。初轮新增4项接口/1项模型聚焦通过，完整回归/UI待验证；不提升static等级。


#### 冻结多选与预览必须分别判断

后续完整上下文映射xX确认freeze_album(e)无论单选或多选均包含REGENERATE_PREVIEW；单选额外SET_COVER。MM根据MI.getCurrentFreezeAlbum选该菜单，MR传入L7生成实际菜单，并非未引用候选。与eej.freeze_album_lightbox缺少重建不同，因此不能据预览菜单建立Repository全局冻结重建禁令。Ei的定义为user_setting.team_space_permission==MANAGE，澄清相册非提供者管理分支属于全空间管理者。仍是当前版本未知环境的static证据，未执行真实请求。


本轮最终验证补记：冻结多选与预览差异修正后803项XCTest/6项本地化通过，最终8项角色/重建聚焦通过，2项UI/12张合成截图通过；Release、签名、实际组件加载及DMG校验通过。原生代码完成不提升未知NAS环境的static证据等级，真实角色及结果见Photos账本PENDING_USER_VALIDATION步骤。


### 2026-10-01 手动人脸相册提供者角色（static）

官方预览菜单P条件检查平台支持与当前空间识别开关，普通/共享相册个人提供者和共享management角色可进入EDIT_FACE。客户端现在与资料编辑共用角色核对：相册读取实际provider_user_id与照片身份，再沿来源空间调用既有Item.list_face v6和人物管理接口。原件删除/移动资格保持独立；共享相册仅贡献而无management不授予手动人脸编辑。没有新增NAS接口，真实NAS写入仍为PENDING_USER_VALIDATION。证据与对应回归见photos-management.md和macOS Photos账本。
