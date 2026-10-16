# 连接、应用权限与账号目录

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="quickconnect-relay-control"></a>
## QuickConnect 控制面与区域转介


稳定端点组：`quickconnect-relay-control`。既有中继基线继续以兼容索引记录为准，本页记录五端登录的区域转介处理。

### 请求与响应

内部接口 `POST /Serv.php`，命令 `get_server_info`，协议请求版本 1，服务为既有 `mainapp_https`。请求不携带 NAS 登录凭据。成功响应包含 `errno=0` 与既有 `server`、`service`、`smartdns`、`env` 字段。

全球入口也可能返回非零 `errno` 和 `sites: string[]`。2026-09-16 只读观察为 `errno=4` / `suberrno=0`，并不表示 ID 不存在；继续查询白名单区域入口可获得在线结果。官方前端同样将 sites 加入待查询列表并去重。字段缺失时不猜测区域主机。

### 安全与失败语义

- 仅接受 DNS 标签合法、以 `.quickconnect.to` / `.quickconnect.cn` 结尾的主机，不允许 URI、端口、路径、凭据或相似域名。
- 固定 HTTPS 和 `/Serv.php`，全部控制请求沿用系统证书信任。总计最多 8 个唯一控制入口，受单次超时、取消和 1 MiB 响应限制。
- 成功在线响应没有直连候选时，保留 `QuickConnectDirectUnavailable` 给既有中继流程；不继续用其他区域的错误覆盖在线结果。
- 中继发现使用同一个转介查询流程；后续中继官方域名、证书、`ezid` 身份核对和登录前探测门禁不变。
- 未找到成功结果时保留既有错误处理；危险业务写入口没有变化。

### 证据

[客户端环境记录](../environments/INDEX.md#2026-09-16-quickconnect-client-observation)仅确认未认证控制面行为，不新增 DSM build 兼容结论。官方静态来源：[QuickConnect 客户端脚本](https://quickconnect.to/connect_lib.da3fae9c5d057ef58d3a.bundle.js)。


平台功能与真实连接验收见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。源码/模拟请求只验证解析与边界，不能证明所有网络环境连接成功。

<a id="dsm-desktop-app-privileges"></a>
## DSM 当前账号应用权限摘要（候选）


### 标识

- 稳定标识：`dsm-desktop-app-privileges`；组件：`dsm-core`；范围：DSM。
- 分类：内部 API；操作：读取；风险：medium（初始化响应含会话和用户设置，不得完整记录）。
- 状态：已按用户确认的策略接入 macOS，App 会话实机验证待完成；已有成功网页观察，设备归属待确认，机器索引 verifications 为空。

### 请求契约

| 字段 | 本次实际观察 |
| --- | --- |
| API | SYNO.Core.Desktop.Initdata |
| 路径 | /webapi/entry.cgi |
| HTTP 方法 | GET |
| method | get_user_service |
| version | 1 |
| launch_app | 查询参数字符串 null，不是空串；必需性未验证 |
| 请求 Content-Type | application/x-www-form-urlencoded; charset=UTF-8 |
| 鉴权 | 官方已登录网页，请求有令牌 Header；没有复制任何值，未验证本地 App 会话兼容性 |

未重放请求，不推断 POST 可用，也不推断可省略 launch_app。其他同名 API 方法不在本记录契约范围内。

### 响应与权限

- 成功包络：success=true，data 为对象。
- data 字段结构：ActionPrivilege 为数组；AppPrivilege、GroupSettings、ServiceStatus、Session、UserSettings 为对象。
- 本次 AppPrivilege 为对象，13 个键的值均为布尔值；以下仅列本任务必要投影：

| 稳定应用键 | 本次状态 | 官方主菜单 |
| --- | --- | --- |
| SYNO.SDS.App.FileStation3.Instance | true | 可见 |
| SYNO.SDS.Chat.Application | true | 可见 |
| SYNO.SDS.Drive.Application | true | 可见 |
| SYNO.SDS.DownloadStation.Application | 键缺失 | 不可见 |
| SYNO.SDS.ContainerManager.Application | 键缺失 | 不可见 |
| SYNO.SDS.Virtualization.Application | 键缺失 | 不可见 |

后三项应用类名同时存在于官方 get_ui_config 返回的 JSConfig 中；这不是“已授权”证据，也不把混淆变量名用作业务协议。当前只记录关联，不宣称授权表单独决定了所有菜单可见性。

- Session.is_admin=false、isLogined=true；Session 还提供 DSM 版本字段，见环境观察记录。
- 未观察到明确 false、该方法自身的无权限/失效/字段缺失响应。缺失键与明确拒绝的区别仍需复验，不得直接等同。
- 禁止把 Session 或 UserSettings 整体写入诊断或日志。

### 版本验证

#### 同日管理员对照：不能将所有缺失键解释为禁止

同一浏览器切换管理员后，get_user_service 返回 is_admin=true，版本保持 7.2.1-69057 Update 12。AppPrivilege 有 25 个键；File Station、Chat、Drive 保持 true，Download Station 与 VMM 的应用键新增并为 true。

**Container Manager 和控制面板在管理员 AppPrivilege 中仍缺失，但官方主菜单显示它们。** 官方 get_ui_config 中应用定义的必要投影：

| 应用定义 | allUsers | grantPrivilege | advanceGrantPrivilege |
| --- | --- | --- | --- |
| SYNO.SDS.ContainerManager.Application | false | 未出现 | 未出现 |
| SYNO.SDS.AdminCenter.Application | false | 未出现 | 未出现 |
| SYNO.SDS.Virtualization.Application | false | all | true |
| SYNO.SDS.DownloadStation.Application | true | local | true |

因此需区分管理员管理入口与可授予应用权限的套件。不能对所有入口统一套用“AppPrivilege 缺失即隐藏”，也不能对所有 allUsers=false 的应用统一套用管理员限制，VMM 已体现独立应用授权。此处只记录本环境官方定义与菜单的交叉证据，不以混淆变量或界面译文建立契约。

本机语言、主题、连接等设置与上述 NAS 权限无关，应始终可用。用户确认 NAS 设置整体与容器要求显式 is_admin=true；独立应用仅允许对应 AppPrivilege 键为 true。显式 false 不得由管理员身份覆盖。入口允许不等于具体写操作获准，原权限及确认门禁仍然必要。该策略已接入 macOS，尚未完成 App 会话验证。

用户补充 VMM 为手工安装且机型非官方支持。安装来源与应用授权分开处理：既有 VMM 原生模块依据稳定应用授权与已有接口能力决定入口，不新增机型白名单拦截，不依据安装成功自动放行，也不把菜单可见提升为完整兼容验证。任意第三方应用不自动映射成原生模块；没有明确授权规则或专门 Adapter 时不试探其业务接口，更不解锁套件写操作。

2026-09-09 在 DSM 7.2.1-69057 Update 12 的非管理员官方网页中观察到请求并读取成功响应；证据详见 [环境观察](../environments/INDEX.md#2026-09-09-nonadmin-permission-observation)。设备是否为旧 lab-a 尚未确认，因此不建立已归属的 read-verified verification，也不改变现有产品支持矩阵。

### 能力探测与降级

- macOS 先通过 SYNO.API.Info 协商 v1，仅读取 get_user_service；沿用既有 GET Header 认证，绝不把凭据放入 URL。不查询其他应用业务数据，不解析菜单译文或动态执行 JSConfig。
- 用户确认的入口策略：File Station、Chat、下载、VMM 明确 true 才允许，缺失或 false 隐藏；管理设置与容器要求管理员且对应键不为 false。还需已有接口能力，手动安装与机型不单独限制；未知第三方应用键全部忽略。
- AppPrivilege 整表缺失或已知字段类型错误与有效空表严格区分：有效空表不额外请求文件；摘要失败才保留原文件只读会话确认；Photos 由独立访问设置决定，其他模块关闭，并提供本地化刷新提示。安全错误和取消不触发额外探测。没有伪造空授权响应或改写 119。
- 请求缺失、失败或响应类型变化不得阻断文件主流程；不能退回逐个加载容器/虚拟机/下载业务列表的权限试探。
- AppPrivilege 只决定入口可用性候选，不替代具体操作的权限校验，尤其不能解锁危险写操作。
- 未确认有公开 API 能等价提供本次摘要；不据此宣称不存在公开替代。

### 安全与副作用

该方法是官方页面已发出的读取，没有手工重放。页面导航自动发出的 UserSettings.apply 等请求另见环境记录，不属于本读取契约，也未由 Agent 修改或重放。未打开受限组件、聊天或用户文件内容；没有新增写操作。

### 未验证事项

设备归属；更多管理员及普通账号；明确 false 和缺失键的完整服务端语义（当前按用户确认策略处理）；其他 DSM build；最小必需参数；错误码；与本地 App 登录会话的兼容性；返回授权与菜单最终过滤条件的完整关系；客户端组件请求导致后续文件 119 的具体原因。

### 未登录空摘要回归

当前 App 已保存会话用 GET 和 POST 都取得 `success=true`，但 `Session.isLogined=false`、
`is_admin=false` 和空权限表。Apple 解码器现在拒绝显式未登录摘要，恢复登录及权限刷新
回到既有文件会话核实；合法的已登录空权限表仍不放行该摘要管理的应用；Photos 另由自身访问设置授权。没有修改请求方法、
登录会话名或持久化格式。修复包已恢复真实文件与 NAS 设置菜单，五个相关页面读取通过；
最终包退出后重新连接由用户确认菜单正常。未将原始空摘要单独等同整体会话过期。详见 [实测记录](../environments/INDEX.md#2026-09-27-nas-settings-live-validation)。

<a id="dsm-current-connection"></a>
## DSM 当前连接内部 API


### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-observability` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 资源监控与连接管理 |
| 能力名称 | 当前连接列表与受保护的连接断开 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `high` |

### 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.CurrentConnection` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| 方法 / 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- |
| `list.start` / `limit` | `integer` | 是 | 有界分页 | `0` / `500` |
| `list.sort_by` / `sort_direction` | `string` | 是 | 按连接时间倒序 | `time` / `DESC` |
| `kick_connection.service_conn` | `objectArray` | 是 | 非网页连接目标，包含 `pid`、`type`、`who`、`from` | `<synthetic-service-connection>` |
| `kick_connection.http_conn` | `objectArray` | 是 | 网页连接目标，包含 `did`、`descr`、`who`、`from` | `<synthetic-http-connection>` |

网页连接只允许使用列表返回的非空 `did`；其他服务连接只允许使用非空 `pid`。目标必须
来自刚刚重新读取的列表，且 `can_be_kicked=true`。不得由显示文本、列表行号、用户名或
来源地址单独拼接写请求。

### 响应与错误

列表只保留 `pid`、`did`、`who`、`from`、`location`、`protocol`、`type`、`time`、
`descr`、`is_current_connected` 和 `can_be_kicked` 白名单字段。写响应的 `success=true`
只表示请求被接受；必须重新读取列表并确认同一设备或进程标识已经消失。

| 场景 | 错误语义 | 是否自动重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或标识缺失 | 不支持/目标不可确认 | 否 | 保留只读列表，关闭断开入口 |
| `can_be_kicked` 不为真 | 权限或受保护目标 | 否 | 不发送写请求 |
| 当前会话 | 可能使本应用掉线 | 否 | 使用更强确认，说明需重新登录 |
| 权限不足或会话失效 | 明确拒绝 | 否 | 提示使用具备权限的账号或重新登录 |
| 提交后目标消失 | 确认成功 | 不适用 | 更新连接列表 |
| 提交超时、断线或回读失败 | 结果未确认 | 否 | 重新连接并刷新列表后核对 |

### 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `read-verified`（仅列表） | v1 | `list` 字段已核对；`kick_connection` 仅有官方网页请求线索和源码/合成测试，本环境未执行写行为 | 2026-07-27 | `docs/api/discovery/environments/INDEX.md` |

列表证据不得提升断开操作的证据等级；连接断开保持“已实现、未实机验证”。

### 能力探测与降级

- 必须发现 `SYNO.Core.CurrentConnection` v1。
- 新 DSM build 在完成版本化写行为验证前，只能依据能力、列表显式许可和用户确认谨慎开放；无法取得完整目标字段时关闭。
- 列表失败仅影响连接页，不阻断文件、照片或其他 NAS 设置。
- 当前没有覆盖 DSM 会话与服务连接统一断开的公开 API。

### 安全与副作用

- 连接数据可能包含账号、来源地址、位置、设备和进程标识，原文不持久化、不遥测、不写日志；移动恢复仅保留不可逆摘要与操作阶段。
- 断开当前会话会让应用失去连接；其他服务连接可能中断文件传输或后台任务。
- 同一设备/进程目标必须防重复；提交异常只回读，不自动重放。
- 写后比较当次原始目标标识，移动重启恢复使用相同字段的不可逆摘要；诊断标签不得包含账号、地址、`did` 或 `pid`。

### 未验证事项

- 管理员/普通账号、当前会话、HTTP/HTTPS 与其他服务连接的真实权限及错误码未验证。
- QuickConnect 中继、目标自然结束、列表延迟和写后断线行为未验证。
- 当前没有专用测试目标授权，因此未通过浏览器或客户端触发真实连接断开。
- Windows 原生管理只有源码和合成证据。大于有界读取范围、
  原始标识缺失/复用、当前会话断开后重登等情况仍需专用 NAS 验证；无法证明目标
  消失时继续保留未知，不提供强制重放入口。Apple 移动端已有管理与持久恢复源码，
  Android 当前实现及验证见下文，五端真实兼容结论均不提升。

### Apple PID 兼容修复

兼容整数与原有文本形式的 `pid`，只对该标识字段执行转换，拒绝小数和越界编号。
其余权限、身份摘要、重复目标、预检与断开回读保持不变。当前连接错误不再误报
为区域与时间错误。来源和现场观察限制见 [本次观察](../environments/INDEX.md#2026-09-26-nas-settings-read-observation)。

2026-09-27 补充：已在当前浏览器成功响应中核对数字 PID，以及文本身份字段和
布尔 `is_current_connected/can_be_kicked`；未执行断开。见
[实测记录](../environments/INDEX.md#2026-09-27-nas-settings-live-validation)。

<a id="dsm-remote-access-settings"></a>
## DSM 远程访问设置内部 API


### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-remote-access-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板外部访问 |
| 能力名称 | QuickConnect 中继与路由器自动配置 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

### 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.QuickConnect`、`SYNO.Core.QuickConnect.Upnp` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | QuickConnect v3；Upnp v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

参数：

| API / 方法 | 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- | --- |
| QuickConnect `get_misc_config` | 无 | - | - | 读取中继开关 | - |
| QuickConnect `set_misc_config` | `relay_enabled` | `boolean` | 是 | 启用或停用 QuickConnect 中继 | `false` |
| Upnp `get` | 无 | - | - | 读取路由器自动配置开关 | - |
| Upnp `set` | `enabled` | `boolean` | 是 | 启用或停用路由器自动配置 | `true` |

客户端只提交实际变化的字段。是否正在通过 QuickConnect 中继连接由当前受信任连接主机
类别判断，不接受用户输入；使用中继连接时禁止关闭中继，避免主动切断完成保存与回读
所需的唯一连接。

### 响应与错误

QuickConnect 读取响应提供 `relay_enabled`；Upnp 读取响应提供 `enabled`。保存前将两项
差异拆成独立子操作并一次性检查所需版本，保存后整体重新读取两项状态。

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| 当前正通过中继连接并请求关闭中继 | 连接保护冲突 | 否 | 使用局域网或公网直连后再修改 |
| API 或所需版本未发现 | 当前设备不支持对应设置 | 否 | 隐藏对应开关，不影响另一项读取 |
| 权限不足 | 当前账号不能修改远程访问 | 否 | 使用具备网络管理权限的账号 |
| 中途明确拒绝 | 前一项可能已经完成 | 否 | 停止后续提交并整体回读 |
| 提交断网、超时或响应无效 | 当前子操作结果未知 | 否 | 使用局域网、公网或 QuickConnect 地址重新连接并回读 |
| 完整回读只有一项符合 | 部分成功 | 否 | 展示重新读取后的两项状态并逐项核对 |
| 回读失败或提交后取消 | 已提交设置可能已经生效 | 否 | 不自动重放；恢复连接后再读取 |
| 同时再次保存 | 重复提交冲突 | 否 | 等待当前保存结束 |

### 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | QuickConnect v3；Upnp v1 | 读取结构和网页接口线索已记录；写入只完成合成请求、部分成功、断网和取消测试，未执行真实行为验收 | 2026-07-27 | `docs/api/discovery/environments/INDEX.md` |

机器可读兼容记录继续保持 `observed / degraded`。Android 第 55 批的合成请求、故障注入、
领域与 Compose 测试只证明客户端契约和保护逻辑，不提升真实环境证据等级；既有
QuickConnect 登录、隧道建立或 `SYNO.API.Info` 探测证据也不外推为本端点的读取或写入
行为证据。

### 能力探测与降级

- 启用条件：成功读取当前设置，并一次性确认所有实际变化所需 API 与版本。
- macOS 按用户明确授权提供测试入口，以实际接口版本、权限、输入、确认、防重复和结果核查判断可用性，不仅因未实测固定关闭。新 DSM build 的真实行为仍待验证；其他平台以其最新授权和实施状态为准。
- 接口缺失：只隐藏依赖该接口的开关，不阻断文件浏览或其他 NAS 设置。
- 字段缺失或类型变化：不显示无法确定当前值的开关，也不提交猜测值。
- 权限不足：不提升权限、不切换账号、不继续后续子操作。
- 网络失败：提交前失败可在恢复后重试；提交开始后必须重新连接并回读，不自动保存。
- 替代的官方 API：当前项目未找到覆盖 DSM 控制面板这两项设置的公开 API。
- 功能开关：NAS 设置模块开关、运行时能力发现、连接方式保护和环境兼容记录共同控制。

### 安全与副作用

- 会读取的数据类别：QuickConnect 中继和路由器自动配置开关。
- 可能产生的副作用：改变外部访问路径、端口映射或当前可用连接，可能导致连接中断。
- 所需权限：由 DSM 返回的能力和当前会话权限决定。
- 重复提交保护：Repository、Android AppViewModel 和 macOS 模型均阻止并发远程访问
  设置保存。
- 写后结果校验：按两个稳定逻辑子操作整体回读并计数；部分成功与未知结果不得重放。
- 临时数据清理：不记录 QuickConnect ID、主机、外网地址、路由器地址、会话或响应。

### 未验证事项

- 当前环境未在专用测试网络完成中继、路由器自动配置、权限不足、连接切换、中途断网
  和端口映射副作用验收。
- `set_misc_config` 与 Upnp 字段在不同 DSM build、路由器和权限组合中的差异尚未验证。
- Windows 读取、保存核心及原生表单已迁移，真实验证待进行；iPhone、iPad 已接本页两项管理及恢复，并运行共享/目标平台回归；Android 本波未改源码，已完成合成契约与界面测试，
  但尚未在真实 NAS 和路由器上执行写操作。

<a id="dsm-account-directory"></a>
## DSM 账号与群组目录内部 API


### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-account-directory` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM |
| 能力名称 | 账号与群组目录读取和管理 |
| 分类 | `internal` |
| 操作性质 | `mixed` |
| 风险等级 | `critical` |

### 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.User`、`SYNO.Core.Group` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现；客户端当前测试路径为 `entry.cgi` |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie 与请求字段；可用时同时携带 SynoToken 请求头与字段，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

账号方法：`list`、`get`、`create`、`set`、`delete`。群组方法使用相同方法名和独立的
`SYNO.Core.Group` API。

关键参数：

| 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- |
| `offset`、`limit` | `integer` | 列表需要 | 分页范围 | `0`、`1000` |
| `additional` | `string[]` | 列表需要 | 请求数字标识、说明、状态和可操作性字段 | `["uid","can_delete"]` |
| `name` | `string` 或 `string[]` | 写入需要 | 合成账号或群组标识；删除使用数组 | `<synthetic-account>` |
| `description`、`email`、`expired` | 多类型 | 账号保存需要 | 只发送编辑器当前值 | 完全合成值 |
| `groups` | `string[]` | 可选 | 账号所属群组 | `["<synthetic-group>"]` |
| `password`、`password_confirm` | `string` | 新建账号需要 | 只用于当次请求 | 仅记录存在和已脱敏，不保存值 |

群组 create/set 使用稳定 `name` 和 `description` 字符串；不携带账号邮件、停用、密码
或组成员参数。编辑不重命名目录项。账号编辑省略空密码以保留凭据，`groups` 未选择
时省略以保留成员关系；缺少原有组关系时不以空数组覆盖。

### 响应与错误

只读成功响应使用 DSM 通用信封，`User.list` 的 `data.users` 与 `Group.list` 的
`data.groups` 为数组。客户端只解析名称、数字标识、说明、邮件地址、停用状态、群组
以及 `can_edit`、`can_delete`；字段缺失时不推断额外权限。

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或版本未发现 | 当前环境不支持 | 否 | 关闭账号管理入口 |
| 会话失效 | 需要重新登录 | 否 | 停止写入并重新认证 |
| 权限不足 | 当前账号不能执行操作 | 否 | 不尝试管理员权限 |
| 写请求连接中断 | 最终结果未确认 | 否 | 先重新读取目录，不自动重放 |
| 写后目录不符合预期 | 结果不一致 | 否 | 保留当前列表并提示人工核对 |

### 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | User / Group v1 | 只读结构和网页请求已记录；未执行账号写行为验收 | 2026-07-27 | `docs/api/discovery/environments/INDEX.md` |

共享请求 Fixture 和本地源码测试只证明客户端请求没有漂移，不把本环境提升为
`behavior-verified`。

### 能力探测与降级

- 启用条件：`SYNO.API.Info` 返回对应 API、v1 和可用路径，当前会话具备页面权限。
- Android 对账号与群组列表分别保留读取成功状态；请求失败时即使列表回退为空，也将
  `accountsAvailable` / `groupsAvailable` 标记为不可用，不把失败误认为真实空目录。
- 新版本行为：按实际接口能力、当前管理员与对象权限开放操作，不以未记录DSM/build作为禁用理由；真实兼容仍须独立留存证据。
- 接口缺失：账号管理页面独立降级，不阻断文件浏览等公开 API 主流程。
- 字段缺失或类型变化：不假定额外权限；身份、行结构或字段类型无法安全解析时目录
  读取失败，不通过丢弃条目伪造删除成功。可选值缺失保持未知，不自动补为可写字段。
- 权限不足：显示可恢复说明，不自动切换或尝试更高权限账号。
- 网络失败：写后先重新读取账号与群组目录，不自动重新提交。
- 替代的官方 API：当前项目未找到满足 DSM 本地账号管理需求的公开 API。
- 功能开关：运行时能力发现与平台账号管理入口共同控制。

### 安全与副作用

- 会读取的数据类别：账号与群组名称、说明、邮件地址、状态、成员关系和可操作性。
- 可能产生的副作用：创建、修改或删除 DSM 本地账号与群组，可能影响访问权限。
- 所需权限：由 DSM 返回的能力和当前会话权限决定；客户端不得提升权限。
- 重复提交保护：Repository 与 macOS 模型均按稳定账号或群组标识隔离正在执行的删除。
- 写后结果校验：保存或删除后重新读取账号与群组目录并核对目标状态；提交后断网、取消
  或回读失败均返回未确认结果，不自动再次删除。
- 临时数据清理：密码只存在于编辑草稿和当次请求，不写入 Fixture、日志或持久化。

### 未验证事项

- 当前环境未在专用测试账号上完成创建、修改、删除、权限不足、网络中断和重复提交的
  行为验收。
- Android 创建、编辑与恢复已在2026-10-13 A7接通；iPhone/iPad 已接调用链，但真实账号行为未验证；
  Windows 新建/编辑/删除核心只有合成证据，Android 删除仍待真实 DSM 与设备验收。
- Mac 新增读取失败关闭及删除反馈修正待目标平台回归；Apple 共享内部 JSON 类型只
  增加等值比较供根/额外字段冲突检测，不改变持久化格式。iPhone/iPad 需评估共享层
  回归，Android 本波只更新适配评估、不修改源码；真实环境证据等级不提升。
- 第 53 批新增的 Android 严格基线、固定版本、取消、专项回读和持久反馈均只通过合成响应
  与自动化测试验证，尚未在真实 NAS 上执行删除行为验收。
- DSM 升级后的方法参数、权限和错误码变化尚未验证。

### macOS 读取回归修复

当前待归属浏览器观察确认用户列表的 `expired` 是 `normal/now` 文本枚举，Apple
兼容这两个状态及原有布尔响应。完整资料缺少 `can_edit` 时允许打开编辑器；显式 false
继续禁止，缺少可编辑资料继续关闭，服务端权限拒绝不绕过。删除仍要求显式许可，
当前账号与保留账号保护不变。证据见 [本次观察](../environments/INDEX.md#2026-09-26-nas-settings-read-observation)。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
