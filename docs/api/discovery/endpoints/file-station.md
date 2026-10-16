# File Station 搜索、分享、权限、远程位置与设置

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="file-station-content-search"></a>
## File Station 文件内容搜索


### 标识、来源与版本

端点组 `file-station-content-search`，组件 file-station，internal / read / low。来源为[2026-10-02 官方网页观察](../environments/INDEX.md#2026-10-02-file-station-live-observation)：DSM 7.2.1-69057 Update 12，File Station 1.4.1-1559；匿名设备待归属，不挂靠既有 lab-a。

官方前端静态条件 `supportfileindex` 决定内容搜索复选框，当前网页实际显示。官方高级搜索产生的 POST `entry.cgi` 已只读核对，Search/start v2 返回 HTTP 200、业务成功、任务编号与原生布尔 `has_not_index_share=true`。只有请求形态和未索引提示达到 read-verified；合成无命中查询不能证明真实文档正文召回。

### 请求与响应

- `SYNO.FileStation.Search/start v2`：保留公开高级条件，增加 `search_content: true`、`search_type: "advance"`。pattern 是用户的内容关键词；不下载文件替代索引。
- 返回 `taskid: string`、`has_not_index_share: bool`。true 表示部分位置未建索引，不等于读取失败，也不代表所有位置未索引。
- `list/stop/clean v2` 沿用公开契约，完整分页；取消/异常只停止和清理本次任务，不能操作其他任务。
- 使用绑定的 DSM 会话及已发现相对路径、编码方式；所有搜索词、目录、任务编号仅留当前会话，不日志化。

### 能力、失败与客户端

需要 Search v2。正文请求若未返回索引状态则明确不可用并清理，不回退为名称结果。权限/读取错误不得当零命中；普通名称搜索不受影响。正文搜索属于只读能力，读取失败按功能降级；其他操作按各自实际能力与权限开放，不从搜索结果推断写权限。

Apple 在 FileSearchRequest 中增加默认 false 的 searchesContents；searchWithReport 返回结果与索引覆盖状态，旧 search 签名复用同一实现。macOS 内容结果不再按文件名二次剔除，名称正则与正文搜索分别使用。合成测试位于 FileStationParityTests 与 FileStationSearchWorkflowTests；真实正文命中、普通账号/管理员和多位置覆盖仍为 PENDING_USER_VALIDATION。

五端：macOS 实现；iPhone/iPad 只编译共享增量，移动入口另行评估；Android/Windows 只记录契约影响。本次没有改变其他四端功能。

<a id="file-station-sharing-extended"></a>
## File Station 具名分享与文件请求扩展


端点组 `file-station-sharing-extended`，组件 file-station，internal / mixed / high。来源：[2026-10-02 环境](../environments/INDEX.md#2026-10-02-file-station-live-observation)中的官方 FileBrowser.js；DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。写请求均为 static，未创建、编辑或删除真实链接；官方管理器自然读取的 list 字段类型和空日期形态已只读核对。

### 请求契约

使用会话认证、API.Info 相对 entry.cgi、POST 表单和声明的参数编码：
- `SYNO.FileStation.UserGrp/list_all v1`：type="all"、prefix、offset、limit；owners 数组，每项 name/type（user/group），total。只选择实际读取的成员，不通过随意输入拼造账号。
- `SYNO.FileStation.Sharing/list v3`：在公开字段上扩展 expire_times、protect_type、protect_users/protect_groups、enable_upload、request_name/request_info、isFolder、limit_size。保留既有 id/path/url/日期/status 字段；缺失不能冒充默认值。
- `Sharing/edit v3`：id 为选中链接数组；protect_type 为 none/password/user；protect_users/protect_groups 是完整所选集合，new_protect_users/new_protect_groups 是相对原快照的新增集合。密码保留时不发送密码；空成员不能静默变公开。expire_times=0 表示不限制次数，正整数表示限制；官方输入最多四位。
- `Sharing/create v3`：公开 path 数组上增加 file_request=true，目标应为可写目录。官方网页先创建后编辑；客户端不得照搬取消窗口后自动删除链接的隐式副作用。
- 文件请求的 edit 发送 file_request=true、request_name/request_info 与有效期；enable_upload 只读展示，不据字段名猜测开关写法；仅把已观察静态字段用于对应业务，不发送 Core.Sharing 的其他父类字段。

### 权限与安全

按实际接口版本能力、目标身份及当前权限开放。按用户追加要求取消实测开关和精确固件白名单，真实写仍待用户验证。具名保护、收集开关和访问限制先读取完整快照，确认影响成员/范围后再写。进行中和未知结果阻止重复写；超时先查原 id，不重建、不自动撤销。密码不回显或记录。修改后逐字段回读；账号保护缺字段不得判成功。文件请求会允许接收者向目标上传，确认须说明这一点。

接口字段来自静态记录，不代表各端已经实现或真实NAS写入已验收；状态见平台矩阵。

<a id="file-station-file-permissions"></a>
## File Station 所有者、POSIX 与 ACL


端点组 `file-station-file-permissions`，组件 file-station，internal / mixed / high。来源为[环境](../environments/INDEX.md#2026-10-02-file-station-live-observation)的 FileProperty.js、Share/PermissionDialog.js。DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559；均 static，无权限写验证。

### 请求及结果结构

POST、能力发现的 entry.cgi 与编码方式、绑定 DSM 会话。公开 List.getinfo 的 additional.real_path 提供真实文件系统路径映射；不可猜 volume 路径，不日志化。
- `SYNO.Core.ACL/get v1`：file_path、type="all"、include_noname_rules=true。data 含 is_acl、change_permission、acl_editable、is_inherited、acl 数组。
- ACL 行：owner_type/name/id/is_internal、permission_type、level（0 为显式）、permission 对象和 inherit 对象。permission 包含 read_data/write_data/exe_file/append_data/delete/delete_sub/read_attr/write_attr/read_ext_attr/write_ext_attr/read_perm/change_perm/take_ownership；inherit 为 child_files/child_folders/this_folder/all_descendants。继承项保留只读，不能混入待写规则。
- `Core.ACL/check_self_denied v1` 与 set 使用同一权限草稿，返回 is_denied；失败或缺字段必须关闭写入，不能按网页宽松逻辑继续。
- `Core.ACL/set v1`：file_path、change_acl、rules（仅显式）、inherited、acl_recur。所有者变化增加 change_acl_owner、acl_owner_type、acl_owner、acl_owner_recur。
- `SYNO.FileStation.Property.ACLOwner/get v1`：file 为真实路径；返回 name/type/value/hasPrivilege。
- POSIX `SYNO.FileStation.Property/set v1`：files 数组、dir_paths 数组、mode 为三位权限数字字符串；-1 表示保持，owner/group 可 null 保持；posix_owner_recur、posix_mode_recur。不得把三位十进制文本误作八进制整数编码。
- Property 返回 running/taskid；同 API status/stop v1 管理该任务。Core.ACL.set 返回 task_id；Core.ACL.status/stop v1 参数 task_id。FileBrowser.js 的 onPropertySendDone/onPropertyDone 使用 finished、result="fail"、errno、errItems 区分进行中与失败。客户端仅读取错误项数量，不保存真实路径或正文；不把根目录回读当作递归任务完成。

### 安全与降级

默认当前项目；先显示当前所有者、显式与继承规则，再显示差异、账号和应用范围。递归、移除访问、修改所有者分别确认。写前再次核对映射/目标/完整权限快照和授权；跨快照变化拒绝，不覆盖新设置。未知只回查，不重放权限写。无法证明实际授权时保留只读详情；不修改相邻文件，不提供权限绕过。

真实权限、继承、自锁保护及递归部分失败需要专用数据验收；当前实现范围见平台矩阵。

### 读取故障修复

1.0.13 的权限读取要求 `additional.real_path`，但 `List.getinfo` 复用了未包含 `real_path` 的普通详情字段列表。NAS 按请求返回附加字段时，客户端在调用 ACL 之前即因缺少路径映射报错。新增请求回归已在旧实现复现此遗漏；修复只在权限读取中显式请求既有契约中的 `real_path`，不扩大普通详情读取、不猜测路径、不放宽缺字段校验。

共享根、挂载位置及回收站的已有写入范围限制同时用于生成只读快照，所有者和权限规则仍可读取；界面允许展开只读规则，修改控件保持禁用。字段名、版本、响应结构及公开接口保持原契约，证据等级仍为 synthetic/static。五端影响：共享 Apple 网络层为兼容修复，macOS 完成相应界面与回归；iPhone/iPad 没有新增入口，Android/Windows 无代码或契约变更。

`PENDING_USER_VALIDATION`：使用修复测试包，以原账号打开共享根和普通子目录的“所有者与权限”，确认所有者、显式和继承规则可显示；共享根只读，展开规则不会提交修改。若仍失败，仅反馈 DSM/File Station 版本、位置类别、操作步骤及脱敏提示，不提供真实路径、账号、会话或原始响应。未连接真实 NAS，也未执行权限写入。

<a id="file-station-vfs-connections"></a>
## File Station VFS 连接


端点组 `file-station-vfs-connections`，组件 file-station，internal / mixed / high。静态来源：[官方 FileBrowser.js / FileBrowserUtil.js](../environments/INDEX.md#2026-10-02-file-station-live-observation)，版本 DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。未连接、修改或断开实际远程位置。

### 契约候选

所有接口为 v1、POST、能力发现 entry.cgi、绑定会话：
- `SYNO.FileStation.VFS.Protocol/list` 返回 protocols：protocol/name/default_port/has_server。选择 NAS 返回的协议，不硬编码承诺所有云厂商。
- `VFS.Profile/list` 返回 profiles：protocol_name/protocol/uri/hostname/port/alias/account/codepage/connect_status。id 来自 JsonReader 默认 id 属性，作为不透明稳定标识；不能从主机、别名或 URI 自行拼接。实际非空连接身份仍待专用环境核对。
- `VFS.Profile/get` 参数 id；可返回密码，不为表单回显读取密码。网页用假密码占位，客户端不能把假密码提交回 NAS。
- `VFS.Connection/create` 与 `VFS.Profile/create` 使用 protocol、client_id、hostname、port、alias、account/password、codepage、uri_path、access_token/refresh_token/expires_in、max_connection、force=false；已保存连接可仅 profile_id。必须区分这两步的结果，不能盲重放 compound。
- Profile.set 为 id 与实际变化字段；Profile.delete 为指定 id。Connection 断开与保存配置删除不同，不自动连带删除配置。
- 2107/2112/2115 表示证书、主机身份或重新授权类警示；禁止自动 force 绕过。

### 云盘正式授权

官方前端通过 `synooauth.synology.com/FileStation/Cloud/login.php` 启动授权，传 type、host、callback 和系统版本字段，最终同源消息含 callback、account、access_token/refresh_token/client_id/expires_in。官方只将 google/dropbox/baidu/onedrive/box 视为云盘，实际入口仍以 NAS Protocol.list 为准。

2026-10-02 使用完全合成参数只读检查：major=7、minor=2、type=google、回调 host 为本机随机路径即可进入 Google 官方账号选择页；省略 major/minor 则服务报告不支持。Google 请求的 redirect_uri 仍是群晖官方 Cloud/redirect.php，state 保留原 host 与 callback。未选择账号、未提交授权、未取得令牌。此证据仅为授权启动 observed，不证明成功回调或云连接写入。

macOS 使用系统浏览器，符合 [Google 原生应用授权要求](https://developers.google.com/identity/protocols/oauth2/native-app)。主 App 只在授权期间监听 127.0.0.1 的系统分配端口；host 附一次性随机路径，callback 使用同一尝试的随机名称。回调 HTTP 解析仅支持 GET/query 或 POST/form、JSON/data 载荷，并保留官方已声明的账号/令牌字段；成功中继的实际传输封装尚未在真实账号验证，必须记录为 PENDING_USER_VALIDATION。未知或缺字段明确拒绝，不能伪造授权成功。

凭据只在授权/请求内存中，不日志化或复制到待核查模型。创建固定协议/账号/别名，续授权固定原 id/协议/URI/账号；两个请求分别核对。未知不重放，不自动撤销连接，不触发文件删除。协议能力、绑定会话权限、确认与回读仍保留，按用户要求取消测试环境开关及精确固件白名单。

五端影响：macOS 当前实施；iPhone/iPad 保持原移动范围，Android/Windows 只更新计划。真实行为均未验证。

### 进一步证据与当前边界

只读打开官方“连接设置”向导后观察 Protocol.list 自然响应：default_port 为数值、protocol/name 为字符串、has_server 为布尔。FTP 条目也可能 has_server=false；FileBrowser.js 的 createVFSRoot 仅在 has_server 时显示树根，因此该字段表示是否已有连接，不能作为“协议是否支持服务器输入”或能力关闭条件。协议名称来自 NAS，客户端只为静态表单已明确的 ftp/sftp/dav/davs 提供新建与修改。

Connection.set 与 Profile.set 必须分别调用并核对；create 同理。保存配置删除与断开分为不同操作，只有已断开配置才可删除。两个步骤中任一步未知，后续不自动重放；凭据不进入待核查记录。新建/修改凭据要求本机到 NAS 的 HTTPS，force 始终为 false。远程浏览按官方 FileBrowserUtil.js 的 getRemoteTreeParams 使用公开 List.list 与原始远程 URI；无需另猜 Entry.Request。客户端只接受原连接根下路径，完整分页、过滤、返回和下载均复用既有文件能力。

源码：`DsmFileRepository+VFS.swift`、`FileVFSViews.swift`、`FileVFSBrowserView.swift`、`FileVFSCloudAuthorizationView.swift`、`FileVFSCloudAuthorizationSession.swift`；自动化：`FileStationParityTests`。合成请求位于 `contracts/request-fixtures/file-station/create-vfs-connection`、`create-vfs-profile`，响应位于 `contracts/fixtures-redacted/file-station/vfs`，结构描述为 `contracts/schemas/file-station-vfs.schema.json`。公开核查入口与保存共享互斥状态，不持久化密码或自动补发第二步。

请求新增 create-vfs-cloud-connection/profile、reauthorize-vfs-connection/profile 合成样本；真实本机回调测试为 `FileVFSCloudAuthorizationTests`，无云账号登录、NAS 请求或浏览器数据读取。正式主 App 新增 network.server entitlement 仅满足 loopback 回调；取消/完成/超时关闭，不改变扩展、Bundle ID 或存储。

<a id="file-station-remote-mount"></a>
## File Station 远程挂载内部接口


### 标识

| 字段 | 值 |
| --- | --- |
| 端点组 / 组件 | `file-station-remote-mount` / `file-station` |
| 范围 / 能力 | File Station；SMB/NFS 连接、重连和断开 |
| 分类 / 操作 / 风险 | internal / mixed / high |

### 请求契约

来源：[2026-09-20 只读核查](../environments/INDEX.md#2026-09-20-remote-mount-read-observation)。
当前环境 DSM 7.2.1-69057 Update 12、File Station 1.4.1-1559，设备待归属。
Mount 和 Mount.List 都由 API.Info 发现 entry.cgi、JSON、v1；通过 DSM 会话认证，
不记录凭据值、不将远程凭据放 URL。发送形态为 POST 表单内按声明编码参数。

| API / 方法 | 已确认参数形态 | 等级 |
| --- | --- | --- |
| SYNO.FileStation.Mount / mount_remote | mount_type:CIFS/NFS、server_ip、mount_point、user_set:bool、auto_mount:bool | static |
| CIFS 专用 | account、passwd | static |
| NFS 专用 | nfs_version:3/4 字符串、protocol:tcp/udp；默认 3/tcp，v4 固定 tcp | static |
| SYNO.FileStation.Mount.List / get | 无业务参数 | read-verified（空列表） |
| Mount.List / unmount、reconnect | mount_point:array of paths | static |
| Mount / unmount | mount_type、is_mount_point、mount_point | static，文件树变体 |

不发送旧 Windows create/update/delete，不复制旧 Mac 的 server/remote_folder/
src_folder/dst_folder/username/password 等重复别名。当前没有只读参数证据，不把
read_only=true 当作远端权限保证。修改配置不是直接 reconnect，必须独立规划旧、新
目标与失败恢复。禁止根据 UI 译文或偶然请求顺序生成参数。

### 响应与错误

Mount.List.get 当前成功 data 为 isoList、remoteList 数组和 mountConfig 对象；
enable_iso_mount/enable_remote_mount 是布尔。非空行字段仅 static：type、source、
mount_point、actor、date、auto_mount。actor/真实路径不进入记录或日志。
写回执和非空列表的完整类型、每项失败语义未进行真实验证。

认证/权限失败立即停止；网络或解析失败不得当成目标消失。未知写结果不重放，不能
盲目回滚卸载“新目标”；用户需核查新旧连接。仅凭 getinfo 返回非 normal 类型不能
确认目标是本次预期远程连接。读取只失败降级，不影响普通文件/收藏。

### 版本验证

| 环境 | 等级 | 范围 | 日期 |
| --- | --- | --- | --- |
| 旧 lab-a 基线 | observed/candidate | 历史方法候选，不能支持旧别名字段 | 2026-07-27 |
| 待归属当前环境 | static | 官方请求参数和非空行字段名 | 2026-09-20 |
| 待归属当前环境 | read-verified | 能力缓存、套件版本及空 Mount.List.get | 2026-09-20 |

### 安全与未验证范围

远程密码仅在当次输入和 HTTPS 正文，不持久化、日志化或在调试字符串中展开。
断开不得调用 FileStation.Delete，不暗中清理本地或远程目录。默认自动挂载/开机
重连、域账号、只读策略、并发占用、真实路径映射、升级与失败恢复尚未验证。
不新增 NAS 权限或绕过证书。后续用户验收需专用可恢复远程共享和清晰目标。

### ISO 静态补充

[官方 FileBrowser.js](../environments/INDEX.md#2026-10-02-file-station-live-observation)确认 `Mount.mount_iso v1` 参数 source、mount_point、auto_mount、user_set。来源和挂载点均为 NAS 路径；客户端只允许明确选定现有空目录、user_set=true，不照搬隐式创建/卸载后删除目录。列表仍是 Mount.List.get 的 isoList，断开仅指定 mount_point。auto_mount 为持久行为，需单独确认；未挂载或卸载真实 ISO，证据仅 static，不提升历史验证。

<a id="file-station-package-settings"></a>
## File Station 套件设置与分享页面


端点组 `file-station-package-settings`，组件 file-station，internal / mixed / high。来源：[2026-10-02 官方页面和脚本](../environments/INDEX.md#2026-10-02-file-station-live-observation)，DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。Settings.get 达到 read-verified；Bandwidth.list 字段只读核对。所有 set、主题读写和权限差量目前仅 static。

### 设置

`SYNO.FileStation.Settings/get,set v1`，POST、能力发现 entry.cgi 与编码方式。get：
- 原生 bool：transfer_log_enable、use_unix_default_perm、enable_list_usergrp。
- string 枚举：rf_allow/vd_allow=admin/everyone，sharing_allow/file_request_allow=admin/everyone/per_user。
- bandwidth_enable=bandwidth_disable/bandwidth_enable/bandwidth_schedule，schedule_plan 为时间表字符串；当前真实空值，非空结构依静态组件另行核对。
- sharing_default_limit、sharing_disable_html、sharing_gofile_protocol、enable_sharing_custom_setting 为字符串值。
- sharing_privilege、sharing_group_privilege、file_request_privilege、file_request_group_privilege 为含 items 数组的对象；link_limit 数组。
set 仅提交变化字段，具名授权差量为 enabled_sharing_privilege/disabled_sharing_privilege 及对应 group/file_request 字段。缺失或未知枚举不能默认改成管理员或所有人。

`SYNO.FileStation.VFS.User/get,set v1` 单独管理远程协议挂载权限；get content=user_enabled_type 返回 user_enabled_type=all/admin/custom；set settings 对象。自定义用户/组另读 content=user_settings/group_settings、type=local/domain/ldap、usergroup、offset/limit/domain；usergrp_settings 行 name/enabled/uid/gid/is_modifiable。不可把多 API 设置伪装原子保存。

### 限速

`SYNO.Core.BandwidthControl/list,set v1`；list protocol="FileStation"、owner_type、offset/limit，返回 bandwidths/total。条目 name/protocol/owner_type/policy/schedule_plan 为字符串；upload_limit_1/2、download_limit_1/2、upload_result/download_result 为数字。policy=disabled/enabled/scheduled，0 为不限速，File Station 非零下限 10 KB/s，官方输入最多九位。set bandwidths 数组，只提交修改项。通过 Sources 只读核对 DSM 自带 ux-all.js 的 SYNO.ux.ScheduleTable：DAY_STRING_SHORT 按日、一、二、三、四、五、六；createTemplate 每日 0…23 列；getSchedule 为 currentSchedule.join("")。服务级 0=不限速、1=启用账号限速；账号级 0=不限速、1=默认限速、2=自定义限速。不能把 CLASS_LIST 的通用样式名当作限速语义。

### 分享页面

`SYNO.Core.Theme.FileSharingLogin/get,set v1`：
enable_logo_customize、logo_position（rightup/leftup/rightbottom/leftbottom）、
enable_background_customize、background_position（center/fill/fit/stretch/tile）、
background_color、footer_msg（最多 512）、enable_footer_html。
换图附 logo_type/logo_path、background_type/background_path；来源 fromDS/history/default。
图片接口与来源按文末第三波次契约接入；预览不得拼接带令牌的 URL。

### 管理授权及核对

管理员身份以绑定会话的明确授权摘要为准；未知权限拒绝。内部写要求实际 API 能力、草稿差异确认、提交去重、写前快照与写后回读。按用户要求取消精确固件白名单及专用验证开关。超时回读不匹配或读取失败列为待核对，不重放；不支持的 API 版本明确拒绝。设置读取失败不影响文件浏览。

五端：macOS 实施，Apple 共享增量保留旧调用；其他四端只同步影响。未提交任何真实设置，所有实际保存、普通账号拒绝、并发变化和部分保存均需专用环境验证。

### 第三波次目录来源契约（static）

官方 `ProtocolUserGrid.loadRoles` 使用 `SYNO.Core.Directory.LDAP/get v1` 的 `enable_client`，`SYNO.Core.Directory.Domain/get v1` 的 `enable_domain`，以及 `test_dc v1` 的 `test_join_success`。启用且加入有效的域用 `get_domain_list v2` 读取 `domain_list`：每项是域字符串，或 `[显示名称, 请求值, 说明]` 数组；请求必须使用第二列，不能用显示名称代替。此处只读查询不加入或修改目录服务。

名单 get 为 `type=local/ldap/domain`、`usergroup=user/group`、`content=user_settings/group_settings`、`substr/offset/limit`；域来源另传 `domain`。保存仍为 `settings.user_settings/group_settings` 中单 uid/gid 与 enabled，不提交整个来源名单。客户端把来源绑定在确认快照及待核查身份中，回读同一来源。某目录查询失败明确提示，可用的其他来源继续列出，不将失败伪装成未启用。

按实际能力与权限判断；实际管理员、文件服务权限、目标基线、确认、重复保护和回读仍保留。未执行真实目录权限写入，证据保持 static / synthetic automated。

### 第三波次图片契约（static）

来源为官方 image_selector.js：`SYNO.Core.Theme.Image/list,get,upload v1`。type 为 fbsharing_login_logo/background；list 返回 list 数组（index、path、可选 filename/hd_path）。get 使用 type、index、is_thumbnail=true；客户端先按稳定 path 重新确认当前 index，认证只在 Cookie/请求头，不进入 URL。NAS 选图复用 List/getinfo 与 Thumb，权限由 NAS 校验。默认背景沿官方 dsm7_0 加 1…10（第十张 dsm7_010.jpg）和 default_login_background 目录。

upload 为 multipart，type 与 upload_image 文件字段，成功 data.path 作为历史身份；上传后回查历史，之后页面应用需要独立确认。上传超时保存当前会话内图片摘要，不重复发送同一图片；用户查看历史后可选取已上传项，其他图片和页面设置不被阻断。摘要不包含文件路径、内容或凭据。图片来源为 fromDS/history/default：NAS 保留完整路径，历史/默认用文件名。Theme.set 保存回执和 logo_seq/background_seq 变化同时成立才确认换图成功；单独序列变化不证明未知写完成。

未执行真实上传或主题写入。合成 fixture 覆盖 list/get/upload、历史清单及目录来源；源码为 `DsmFileRepository+ThemeImages.swift`、`FileStationThemeImagePicker.swift`，自动化在 `FileStationParityTests`。真实图片尺寸限制、所有支持格式和最终页面显示由用户验收，不增加推测的文件大小上限。

### 本机账号名单类型更正

[只读核查](../environments/INDEX.md#2026-10-02-file-station-settings-read-fix)重新确认 DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。官方名单的 VFS.User.get v1 返回成功，但用户 `uid` 和群组 `gid` 都是十进制数字字符串；`offset/total` 为整数，`enabled/is_modifiable` 为原生布尔。此前仅按整数解码编号的客户端会把成功响应误报为无法读取设置，合成回归已复现同一错误。

读取适配只为该端点的 uid/gid 接受整数或数字字符串，转换后仍需有效的非负编号，不接受空值、非数字、布尔、溢出或重复身份；权限布尔不作宽松转换。确认快照、来源、可修改标识、提交去重及单账号保存/回读规则保持不变。新增合成响应为 `contracts/fixtures-redacted/file-station/settings/synthetic-mount-account-string-ids`，旧整数样本保留；Schema 的更正仅限 `mountAccounts`，不扩大尚未验证的其他设置响应。

五端影响：macOS 修复名单读取及来源/用户组控件；Apple 共享网络层兼容增量可供 iPhone/iPad 复用，没有新增移动入口；Android/Windows 后续接入此端点时应采用相同编号语义，不修改两端代码。读取格式达到本次待归属观察的 `read-verified`，真实保存、其他权限和其他版本仍须用户验收；分享账号等其他端点不借此提升证据等级。

### 未配置限速状态更正

上述早期枚举记录不完整。[追加只读核查](../environments/INDEX.md#2026-10-02-file-station-settings-read-fix)在相同 DSM/套件版本观察到本机用户和群组的 `policy=notexist`；官方用户列表显示应用群组设置。该值表示没有独立账号配置，不能归并为 `disabled`。新增读取枚举并保留未知值拒绝，用户显示“应用群组限速”，群组显示“未设置限速”。首次打开编辑器保持原状态，未作修改时不保存；仅可明确选择既有 `disabled/enabled/scheduled` 策略，仓库拒绝把 `notexist` 发往账号或服务级设置。未新增恢复群组配置的写操作。

响应 Schema 及 `synthetic-bandwidth-unconfigured-user/group` 合成样本已同步；`FileStationParityTests` 覆盖两类读取、已配置策略、首次明确设定后回读、未知策略拒绝及禁止回写未配置标记。该标记只补全共享 Apple 内存模型，没有会话/持久化格式、公开 DSM 请求或存储迁移；回滚可撤销解析与界面变更，NAS 原数据不受影响。

五端影响：macOS 接入名单与编辑状态；iPhone/iPad 共享模型和网络层兼容读取，不新增设置入口；Windows/Android 后续接入应保留“继承或未配置”和“不限速”的区别，不借本次修复改变两端源码。真实保存、实际速度、群组继承计算及域/LDAP 均为 `PENDING_USER_VALIDATION`，不提升写验证等级。

<a id="dsm-share-access"></a>
<a id="file-station-share-access"></a>
<a id="dsm-share-permission-matrix"></a>
## DSM 共享文件夹访问权限契约


稳定端点标识：`file-station-share-access`。

### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-share-access` |
| 私有兼容索引条目标识 | `dsm-share-permission-matrix` |
| 项目组件标识 | `file-station` / `dsm-core` |
| 所属范围 | 当前账号共享文件夹访问、管理员共享权限矩阵 |
| 能力名称 | 当前账号有效访问读取；管理员权限矩阵候选 |
| 分类 | 公开读取 / 内部候选 |
| 操作性质 | `read` |
| 风险等级 | `medium` |

### 已实现的公开读取契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.FileStation.List` |
| 方法 | `list_share` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | 客户端选择能力发现范围内的版本，当前测试使用 v2 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

客户端按 `offset`、`limit` 分页读取，并请求 File Station 的附加权限字段。页面只显示当前
登录账号可见的本地共享文件夹，排除回收站路径和 CIFS/NFS 等远程挂载。相同运行时条目
按稳定 ID 去重，权限解释如下：

| 返回字段 | 客户端语义 |
| --- | --- |
| `adv_right.write=true` | 可读取和修改 |
| `adv_right.read=true` 且不可写 | 仅可读取 |
| `adv_right.delete=true` | 另行显示可删除 |
| 权限字段缺失或无法解释 | 权限未知，不推断为拒绝访问 |

`list_share` 返回的是当前账号可见集合。某个共享文件夹没有出现在结果中，既不能证明它
存在，也不能区分隐藏、无权限、套件不可用或其他服务端策略；因此界面明确标注这不是
完整的管理员权限矩阵。

### 尚未实现的内部候选

静态 API 目录仅发现 `SYNO.Core.Share.Permission.list_by_user` 方法名。目前没有可信的
版本、参数、响应结构、权限要求或失败语义证据，客户端不调用该接口，也不在能力探测中
声明支持。

共享文件夹创建、修改、删除、加密、WORM、配额、移动和权限写入继续保持关闭。增加任何
写入口前必须取得并版本化记录：

1. `SYNO.Core.Share.validate_set` 或等价完整预检；
2. 用户与群组权限的复合提交参数及继承/拒绝优先级；
3. 加密、WORM、配额与权限之间的约束；
4. 移动任务 ID、轮询、取消和最终状态；
5. 权限检查、确认、稳定目标标识、防重复、写后回读及部分成功语义。

### 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 公开 `list_share` 契约已由既有 File Station 路径和合成响应覆盖；本批未读取或修改真实共享权限 | 2026-07-31 | `docs/api/discovery/environments/INDEX.md` |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 仅发现内部 `list_by_user` 方法名，管理员矩阵保持关闭 | 2026-07-31 | `docs/api/discovery/environments/INDEX.md` |

合成响应与源码测试只能证明客户端分页、解析、去重、远程挂载过滤和降级行为，不能把
当前环境的管理员权限读取或写入提升为 `read-verified` / `behavior-verified`。

### 能力探测与降级

- 公开视图仅要求运行时发现 `SYNO.FileStation.List`；能力缺失、无权限或 File Station
  不可用时，页面独立显示错误和重试，不阻断其他 NAS 设置。
- 空结果只表示当前账号没有收到可显示的共享文件夹，不推断 NAS 没有共享文件夹。
- 权限位缺失时显示“暂时无法判断”，不把默认值或路径可见性冒充完整 ACL。
- 内部 `SYNO.Core.Share.Permission` 在取得版本化契约前保持禁用；不得根据方法名猜测
  参数。
- 新 DSM build 或 File Station 版本必须重新验证分页、附加字段和权限解释。

### 安全与隐私

- 页面不显示物理路径、账号 SID、群组明细或内部权限位原文。
- 测试只使用合成共享名、保留地址与脱敏会话占位符。
- 不记录或提交真实共享名、路径、账号、权限响应、Cookie、SID 或 SynoToken。
- 本批没有权限写入、副作用操作或管理员权限提升。

### 未验证事项

- 当前 DSM build 下管理员、普通账号、隐藏共享、只读共享、回收站差异和 QuickConnect
  中继的真实结果尚未逐项验收。
- 不同 DSM/File Station 版本是否始终返回相同 `adv_right` 字段尚未验证。
- 内部管理员矩阵的版本、参数、响应、继承、显式拒绝和权限要求均未验证。
- 五端 UI 与跨平台契约尚未全部迁移。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
