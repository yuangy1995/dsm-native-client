# 系统读取、进程、日志、更新与计划任务

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="dsm-system-read"></a>
## DSM 基础读取接口


本页保留聚合端点标识，具体设置不重复定义；均为内部 API。

<a id="dsm-system-observability"></a>

### `dsm-system-observability`

`SYNO.Core.System.info` v3、`SYNO.Core.System.Utilization.get` v1 提供系统与性能摘要；进程、连接、日志和更新分别见 [进程](dsm-system-monitoring.md#dsm-system-processes)、[连接](dsm-account-and-connection.md#dsm-current-connection)、[日志](dsm-system-monitoring.md#dsm-system-log)、[更新检查](dsm-system-monitoring.md#dsm-system-update-check)。各分区独立失败，不以空数据替代权限或解析错误。

<a id="dsm-storage-hardware"></a>

### `dsm-storage-hardware`

`SYNO.Storage.CGI.Storage.load_info` v1 为存储读取基线。历史环境 `SYNO.Core.Storage.Volume.list` v1 返回 101，不得覆盖有效的 load_info 结果；`SYNO.Storage.CGI.Smart`、`SYNO.Core.Storage.Disk` 的具体调用由 [SMART](dsm-hardware-and-power.md#dsm-smart-test)和[存储入口](../../reference/storage.md)说明。硬件、UPS、电源计划、ZRAM、外接存储见各自记录，不在聚合索引复制写入口状态。

<a id="dsm-administration"></a>

### `dsm-administration`

套件列表 `SYNO.Core.Package.list` v2；详情与控制见 [套件控制](dsm-packages.md#dsm-package-control)和[安装](dsm-packages.md#dsm-package-installation)。计划任务详情/创建/修改 v4、列表/运行 v3 见[任务计划](dsm-system-monitoring.md#dsm-task-scheduler)。其余网络、账号、文件服务、安全与时间设置由[系统管理入口](../../reference/system-management.md)链接到独立参数定义。

### 证据

[环境记录](../environments/INDEX.md)保留版本、权限和方法级结果。聚合端点有读取证据不代表其全部写方法已验证。

### 名称与定位

完整API名为 `SYNO.Core.TaskScheduler`、`SYNO.Core.EventScheduler`（计划与结果）、`SYNO.Core.SyslogClient.Log` 和 `SYNO.LogCenter.History`（日志）；请求细节由上述独立记录维护。`SYNO.Core.Storage.Volume` 的list历史返回101，保持已有降级。`SYNO.Core.Package.Thumb` v1的现行二进制读取见[套件图标](dsm-packages.md#套件图标读取)；源码形态与真实版本证据分别记录。

<a id="dsm-system-processes"></a>
## DSM 系统进程与服务进程组内部 API


### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-processes` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 资源监控 |
| 能力名称 | 系统进程与服务进程组只读摘要 |
| 分类 | `internal` |
| 操作性质 | `read` |
| 风险等级 | `medium` |

### 当前证据与启用边界

静态 API 目录只确认以下方法名：

| API | 方法 | 当前状态 |
| --- | --- | --- |
| `SYNO.Core.System.Process` | `list` | 客户端只读适配已实现，等待真实脱敏响应验证 |
| `SYNO.Core.System.ProcessGroup` | `list` | 可选只读补充，失败时降级 |
| `SYNO.Core.System.ProcessGroup` | `service_info` | 参数、响应与隐私边界未知，保持关闭 |

客户端仅接受运行时 `SYNO.API.Info` 明确返回且包含 v1 的能力。v1 是当前客户端的保守
支持范围，不代表静态证据已经证明所有 DSM build 都提供该版本。能力缺失、仅提供其他
版本或请求失败时，不猜测路径、版本或替代方法。

### 请求契约

进程列表与服务组列表均使用运行时发现的路径和请求格式：

| API / 方法 | 版本 | 参数 |
| --- | ---: | --- |
| `System.Process.list` | v1 | `start=max(0, start)`、`limit=1...500` |
| `System.ProcessGroup.list` | v1 | `start=0`、`limit=1...500` |

macOS 当前从 `start=0` 读取单个最多 500 项的快照，不持续轮询，也不为取得完整列表自动
追加请求。服务端报告总数超过已读取数量，或正好返回 500 项且没有可信总数时，界面明确
提示列表已截断，引导用户使用 DSM 资源监控查看完整信息。

该参数形态目前只有客户端合成请求测试，尚未达到 `observed` 或 `read-verified`。

### 响应白名单

客户端只从 `processes` 或 `items` 容器读取：

- 数字进程编号：`pid` / `process_id`；
- 进程名称：`name` / `process_name`，若值含路径只保留最后一个名称片段；
- 可选状态：`status`；
- 可选服务组标识：`group_id` / `group` / `service`，仅接受字母、数字及 `._-:`。

服务组只从 `groups` 或 `items` 容器读取：

- 稳定标识：`id` / `group_id` / `service`；
- 显示名称：`display_name` / `name` / `service`，若值含路径只保留最后一个片段；
- 可选状态：`status`；
- 非负且有上限的进程数量：`process_count` / `count`。

未知字段一律丢弃。重复进程编号和服务组标识只保留第一项。名称、状态与标识均限制长度，
换行会被折叠，非法标识会被忽略。

### 隐私与写操作边界

领域模型没有命令行、可执行文件路径、工作目录、账号、环境变量、打开文件、监听端口、
来源地址或目标地址字段。即使服务器返回这些内容，Adapter 也不会复制、缓存或展示。
自动化测试使用合成敏感字段确认它们不会出现在结果模型中。

本页面不提供结束进程、发送信号、重启服务、调整优先级或导出原始响应。静态目录也没有
形成任何相关写方法的稳定契约；未来如发现写候选，必须建立独立高风险端点记录、确认、
权限检查、防重复与最终状态复查，不得扩展当前只读接口完成。

### 降级与失败语义

- `System.Process` 缺失或 v1 不在发现范围时，页面显示当前 NAS 不提供该只读能力，且
  不发送猜测请求。
- `System.Process.list` 权限、网络、格式或服务错误只影响系统活动页，不阻断系统概况、
  文件、照片或其他设置。
- `System.ProcessGroup.list` 缺失或失败时保留进程列表，并提示服务组暂不可用。
- 取消请求会继续向上抛出，不转换为部分成功。
- 空列表只在请求成功后显示为空，不把错误解释为“没有进程”。

### 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 仅确认 API 与方法名；未保存或提交真实进程响应 | 2026-07-31 | `docs/api/discovery/environments/INDEX.md` |

合成响应、能力协商、字段白名单、截断、零猜测请求和服务组降级测试不能把当前环境提升为
`read-verified`。

### 未验证事项

- 真实 DSM build 的版本、路径、参数名、分页容器、总数字段和权限错误尚未核对。
- 进程与服务组名称、状态枚举、重启瞬间的重复编号和排序稳定性尚未实机验证。
- `service_info` 的必需参数、返回字段、权限与隐私影响未知，保持关闭。
- 当前页面是单次快照，不宣称实时监控；也不展示尚无单位证据的 CPU 与内存数值。

### macOS 兼容候选修复

根据原始开源 Schema 补充 `process[]` 与 `slices[]` 容器；进程的 `command` 仅提取
首个空白前片段的末级名称，参数和目录不进入模型；服务组使用 `unit_name` 标识，
数量可从嵌套 `process[]` 计算。既有 `processes/items` 与 `groups/items` 继续兼容。
读取结果在客户端仍限制最多 500 项，缺失容器报错，服务组异常不阻断进程列表。
来源及当前环境限制见 [本次观察](../environments/INDEX.md#2026-09-26-nas-settings-read-observation)；
仅有静态结构线索与合成验证，当前 NAS 读取仍为 `PENDING_USER_VALIDATION`。

### 当前响应核对

在 DSM 7.2.1-69057 Update 12 官方资源监控中，Process.list v1 成功返回
`process[]` 与 `command/pid/status`，ProcessGroup.list v1 成功返回
`slices[]` 与 `unit_name/name/process[]`。上轮兼容候选已得到当前只读响应支持，
未执行进程控制。见 [实测记录](../environments/INDEX.md#2026-09-27-nas-settings-live-validation)。

<a id="dsm-system-log"></a>
## DSM 系统日志读取内部 API


本页细化既有 `dsm-system-observability` 端点组中的日志能力，来源是已有 API 参考、兼容索引和 Apple 读取适配；本次没有进行新的现场发现、读取真实日志或提升环境证据等级。

### 标识与请求

| 字段 | 值 |
| --- | --- |
| 稳定端点组 | `dsm-system-observability` |
| 组件 / 分类 | `dsm-core` / `internal` |
| API / 方法 | `SYNO.Core.SyslogClient.Log.list` |
| 客户端版本 | v1；`DsmCapabilityDiscovery.supportedRanges` 限制为 1...1 |
| 路径与格式 | 运行时 `SYNO.API.Info` 返回的路径和请求格式，既有 POST 会话构造器 |
| 参数 | `offset` 为非负整数，`limit` 为 1...500 |
| 性质 / 风险 | 只读 / 日志可能包含个人或环境信息 |
| 权限 | 当前会话实际权限；移动 NAS 管理入口另要求明确管理员身份，不据此绕过接口拒绝 |

移动界面每页可选 50、100 或 200 条；按实际偏移读取，不把本页搜索冒充 NAS 全局搜索。排序保持既有接口行为，不添加未记录的查询或排序参数。没有清空、导出或写入日志的请求。

### 响应与客户端解释

- `data.items` 必须为对象数组，行数不超过请求上限；缺失、畸形或没有可读正文的行返回读取错误，不能静默丢行后显示为空。
- 正文沿用既有 `descr` / `message` / `msg` 候选，必须有可读值；不把未识别对象或原始响应直接展示。
- 时间沿用 `time`；来源沿用 `logtype` / `orginalLogType`，后者拼写保持既有适配；等级为 `level`，账号为 `who`。缺失的可选值保持未知或省略，不填造账号、来源或日期。
- `total` 缺失或为 null 时，`NasLogPage.isTotalKnown=false`；数值不完整不能显示成总共零条。当前页面恰好填满时可继续读取，空页和不足一页时停止继续；页面本身保留实际请求偏移。
- 已提供的 `total` 必须是非负整数；`infoCount` / `warnCount` / `errorCount` 是可选计数，未知或无效时不补零。
- 日志随时间增长或轮转，不承诺多次分页属于同一快照。下一页读取失败保留原页及原页码，并显示刷新失败；数量减少后的空页允许返回之前的页。
- 级别使用稳定枚举，本地化文本不进入请求或筛选状态。正文、账号和来源为 NAS 返回的用户数据，保留原文；时间按 App 当前语言显示。

### 失败、取消与隐私

缺能力、版本不支持、权限拒绝、认证或网络错误仅影响日志页面。请求按页面及会话代次隔离，迟到页不能覆盖更新的翻页或新账号。重新绑定同一配置也会清除正文和已打开的详情。

日志只在当前会话的页面内存中保存，不进入恢复记录、诊断日志、分析报告、截图提交或远端问题追踪。自动化使用合成账号、正文和日期。Agent 不读取或导出用户 NAS 的日志正文。

### 环境证据与待验

既有 `lab-a-dsm-7-2-1-69057-u12-20260729` 基线索引记录 SyslogClient.Log.list v1 的 `read-verified` 读取证据（核对日期 2026-07-27），参见 [API 参考](../../README.md)及[兼容索引](../../../../contracts/private-api/compatibility.json)。该历史等级不扩张为本次移动客户端、其他设备或 DSM 版本的实测结论。

`PENDING_USER_VALIDATION`：两种移动真机及具备日志查看权限的测试账号，分别读取多页、切换页大小、查看长正文、等级筛选、断网重试、日志轮转及切换账号。预期空/失败/未知总数分别表达，详情不串账号、不产生 NAS 写入。只回传版本、权限类别、数量及脱敏步骤/错误；不回传正文、账号、路径、地址、原始响应或凭据。

<a id="dsm-system-update-check"></a>
## DSM 系统更新检查内部 API


### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-update-check` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 系统更新 |
| 能力名称 | 当前版本与可用更新只读检查 |
| 分类 | `internal` |
| 操作性质 | `read` |
| 风险等级 | `medium` |

### 请求契约

检查由两个只读请求组成：

| API / 方法 | 版本 | 参数 | 用途 |
| --- | ---: | --- | --- |
| `SYNO.Core.System.info` | 能力发现范围内版本 | 无业务参数 | 读取当前 DSM 版本 |
| `SYNO.Core.Upgrade.Server.check` | v3 | `user_reading=true`、`need_auto_smallupdate=true`、`need_promotion=false` | 读取当前账号可见的更新候选 |

路径和请求格式必须由 `SYNO.API.Info` 运行时发现。任一能力缺失、v3 不在服务器声明范围
或检查失败时，客户端只显示检查失败，不尝试其他版本、下载或安装方法。

### 响应解释

- 当前版本优先读取 `System.info` 的 `firmware_ver`，兼容 `version`。
- 更新版本读取 `Upgrade.Server.check` 的 `update.version`。
- 更新说明只在候选更新中读取 `release_note`、`release_notes`、`whats_new` 或
  `description` 的第一个非空值。
- 版本和说明只清理首尾空白，服务器返回的用户可见正文保持原文。
- 候选版本为空，或与当前版本完全相同时，不宣告存在更新。
- 客户端不根据版本字符串自行计算升级路径，也不把 `promotion` 当作系统更新。
- `update.rss_result` 存在且不是 `success` 时显示读取失败，不以空候选宣告最新。

macOS 将检查结果用于[补丁更新流程](#dsm-system-update-install)；其他端保持只读检查。

### 安装边界

下载安装与最终版本核验由独立端点组定义。检查接口本身不授权安装，也不把候选消失当作安装成功。

### 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `read-verified` | `System.info` 与 `Upgrade.Server.check` v3 只读结构已核对；未执行下载或安装 | 2026-07-31 | `docs/api/discovery/environments/INDEX.md` |

合成测试覆盖候选更新、无候选、相同版本、空白规范化和请求参数；这些测试不提升下载或
安装行为的证据等级。

### 能力探测与降级

- `System` 与 `Upgrade.Server` 必须分别存在，v3 必须落在更新服务的发现范围内。
- 更新检查失败只影响本次检查，不阻断系统概况、文件或其他设置页面。
- 不自动重试检查，不把网络错误解释为“已是最新版本”。
- 当前版本缺失时仍可展示服务器明确返回的候选版本，但不自行比较版本号。
- 新 DSM build 上继续允许只读检查；安装是否可用由补丁更新端点组的实际能力与预检结果决定。

### 未验证事项

- 无更新、分阶段更新、重大版本、回退版本、区域限制、代理离线和更新服务维护时的所有
  真实响应形态尚未覆盖。
- 发布说明可能包含富文本；当前仅按普通文字展示。
- 原生客户端的实际安装与异常恢复验收见[当前限制](../../../progress/KNOWN_LIMITATIONS.md)。

<a id="dsm-task-scheduler"></a>
## DSM 任务计划与运行结果内部 API


### 标识与证据范围

端点组：`dsm-administration` 的任务计划切片，组件 `dsm-core`，分类 `internal`，
管理风险 `critical`。本文整理已有 [API 参考 8.5](../../README.md)、
`DsmNasAdministrationRepository` 及其合成测试，不是新的真实 NAS 验证。

### 已记录的只读契约

路径由 SYNO.API.Info 发现；使用 POST 表单封装和既有会话/令牌机制，不记录凭据。

| API / 方法 | 固定版本 | 参数 | 响应 |
| --- | --- | --- | --- |
| SYNO.Core.TaskScheduler.list | 3 | start、limit 整数 | tasks 对象数组；id、name、owner、real_owner、type、action、enable、next_trigger_time、can_run、can_edit |
| SYNO.Core.TaskScheduler.get | 4 | id 整数；可选 real_owner 字符串 | name、owner、real_owner、enable、schedule 对象、extra 对象 |
| TaskScheduler.get 创建模板 | 4 | id=-1、type=script；可选 real_owner | 同详情，使用服务器明确返回的默认值 |
| SYNO.Core.EventScheduler.result_list | 1 | task_name 字符串 | data 直接数组，或 data.results 数组 |
| SYNO.Core.EventScheduler.result_get_file | 1 | task_name、result_id 字符串 | script_in、script_out 可选字符串 |

schedule 白名单为 date_type、week_day、date、repeat_date、monthly_week、hour、minute、
repeat_hour、repeat_min、last_work_hour。extra 白名单为 script、notify_if_error、
notify_mail；不执行返回脚本。运行记录保留 result_id/id、task_name、start_time、
stop_time、exit_info.exit_type/exit_code（或同名顶层字段）、trigger_event。

任务以数字 id 与 real_owner 定位，不能按名称或列表行号伪造身份；结果 ID 必须非空且
属于所选 task_name。未知许可默认关闭，缺失时间不得自动变成零点或每天运行。
缺失/畸形根与真实空列表不同，字段冲突或类型不符不能悄悄丢弃条目。

### 管理操作边界

既有记录规定 TaskScheduler.create/set v4，run/set_enable/delete v3；不能将整个
TaskScheduler 一律升级到 v4。

| v3 命令 | 参数 | 结果边界 |
| --- | --- | --- |
| set_enable | id 整数、可选原始 real_owner、enable 布尔 | 回读相同身份的启用状态，不代表终止正在运行的脚本 |
| run | id 整数、可选原始 real_owner | 接受只表示开始请求，不代表脚本成功；不能以最新历史记录推断本次结果 |
| delete | id 整数、可选原始 real_owner | 完整列表中原数字身份消失才确认；所有者变化不当作删除 |

Windows 四命令核心已接入确认基线、明确管理员与许可检查、固定版本、同目标互斥
及不重放恢复。脚本任务启用/运行还要比对用户预览的 get v4 详情，防止列表不变但
执行代码、用户或计划已变化；启用要求关键计划字段完整。恢复只保存必要任务身份
和结果，不持有脚本或通知内容。运行明确接受后缓存结果；模糊运行不能靠历史记录
自动解除未知状态，需用户在 DSM 核查，客户端不提供强制重放。

create/set v4 保存 name、owner、enable、type=script、schedule 与 extra；编辑额外
发送 id，可选 real_owner 只沿用确认时选择器。schedule 保留服务器既有日期/重复
策略，只编辑 Mac 已提供的 hour/minute/week_day，保留固定 repeat_min_store_config
和 repeat_hour_store_config；未知的可选 date/monthly_week 不补造。extra 为 script、
notify_enable、notify_if_error、notify_mail，通知开关按已记录逻辑由错误通知或邮件
非空推导。脚本和通知值只在当次请求中使用。

保存使用服务器模板与双基线，固定管理员/许可、原身份和执行用户；同目标跨命令互斥。创建候选必须通过get v4完整配置回读，ID/名称存在不能代替脚本、计划、执行用户和通知字段匹配。恢复只保留必要身份及摘要，不存原始脚本；未知只读，不重发。入口按实际能力、参数、权限与安全规则，未实测不产生精确版本白名单，也不宣称真实兼容。

### 安全与未验证事项

Mac 命令模型现先重读列表比对确认任务、许可及执行用户，不再以 owner 代替缺失的
real_owner；启停/删除核对当次成功加载的新列表，失败不使用旧缓存。模糊命令错误
不建议立即重试，运行调用仅表示接受。真实执行结果需按环境记录验证。

Mac 编辑窗口将原始详情快照传回模型；保存前重新核对，保存后用当次列表和详情
逐字段确认，不再凭 ID/名称判断成功。保存开始时复制草稿，保存期间禁用启用开关，
避免界面变化影响已提交值；新增模型回归仍待 Mac 执行。

脚本、通知地址、命令和输出可能含秘密，只在当前读取/窗口使用，不自动执行、不
写入磁盘、日志、遥测或默认 JSON。结果输出只能在用户选择记录后读取，不随列表
预取。失败只影响任务页，不阻断文件、照片或其他 NAS 页面。

尚未验证真实任务、权限、长输出、计划类型和系统管理任务；不因合成读取成功开放
创建、启停、运行或删除。真实写验收必须另行授权专用、可恢复任务，结果仅回传脱敏
步骤与错误；不提供脚本、邮箱、主机、账号、凭据或原始响应。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。

<a id="dsm-system-update-install"></a>
## DSM 在线补丁下载与安装

端点组 `dsm-system-update-install`，组件 `dsm-core`，内部 `mixed` 操作，风险 `critical`。安装会中断服务并可能重启 NAS；只支持在线单机 `smallupdate`，不上传本地固件，不执行降级、取消或猜测迁移步骤。路径及参数编码由 `SYNO.API.Info` 发现；`requestFormat=json` 表示参数值 JSON 编码，不改变 HTTP 表单正文。

### 请求与状态

| API / 方法 | 版本 | 参数 | 结果与用途 |
| --- | ---: | --- | --- |
| `SYNO.Core.Upgrade.basic_status` | 1 | 无 | `status`、`allow_upgrade:Boolean`、`target`，准备完成时有 `patch_info` |
| `SYNO.Core.Upgrade.Server.Download.start` | 2 | `target="update"`、`need_auto_smallupdate=true` | 开始服务器提供的在线更新下载；成功响应不表示下载完成 |
| `SYNO.Core.Upgrade.Server.Download.progress` | 2 | `need_download_target=true` | `percent:Number`、`status`、`target`、`version` |
| `SYNO.Core.Upgrade.status` | 1 | `feasibility_check=true` | 安装许可与可行性；`check_type=hard/soft` 分别有阻断/额外确认提示 |
| `SYNO.Core.Upgrade.check_having_upgradeable_drives` | 1 | `upgrade_to={base:buildnumber,nano:smallfixnumber}` | 官方安装前驱动检查；失败停止，响应真值影响官方重启提示，客户端统一明确提示可能重启 |
| `SYNO.Core.Upgrade.start` | 1 | `force=true`、`type="server"` | 明确成功仅表示接受安装；提交阶段断线或 HTTP 5xx 保留结果未知且不重放 |
| `SYNO.Core.Upgrade.progress` | 1 | 无 | `percent:Number`、`type`、`step`；`step` 具体值尚未形成稳定映射，不由它猜测迁移/重启阶段 |

已观察 `basic_status` 的 `none`、`downloading`、`ready_upgrade`；官方脚本静态确认 `upgrading` 表示安装中、`system_busy` 表示系统忙。安装中可只读读取进度，未知或非 `update` 下载目标不冒充当前补丁。`patch_info` 包含 `buildnumber`、`smallfixnumber`、`upgradetype="smallupdate"`、`type="smallupdate"`、`reboot="now"`、`restart_all`、`restart_some`、`restart_pkgs`、`restart_servs`。不保存机型唯一标识或私有地址。百分比仅接受 0–100 的有效数字，缺失时显示不定进度，不自行计时填充。

### 许可、确认与恢复

- 下载前重新检查相同候选及 `status=none / allow_upgrade=true`；安装前及用户确认后均重新检查相同候选、已下载补丁的 build/Update、实际许可、可行性和驱动检查。
- 安装确认绑定一次性计划。任何 `hard`、`soft` 或未知可行性警告均转到 DSM；不跳过额外后果确认。发现 `SYNO.SHA.Upgrade` 时保留集群专用流程，普通安装入口关闭；大版本 `dsm` 需要另有 `PreCheck.start`，不复用补丁流程。
- 重复安装和电源操作互斥；可能提交后只读查询。带 DSM 错误码的明确拒绝或提交前证书错误可以释放安装保护，HTTP 5xx 等没有明确拒绝证据的响应保留结果未知。关闭弹窗不取消 NAS 工作；再打开继续读取同一内存状态。不新增持久化记录、不保存会话或凭据。重新登录或重启 App 后重新检查 NAS 当前版本，不自动认领或重放旧安装。
- 安装期间只读取 NAS 本机版本和进度，不依赖外部更新服务器再次返回候选。安装 100% 只进入等待恢复；只有 `basic_status` 返回 `none`、`System.info.firmware_ver` 的完整版本与已确认目标一致，且含目标 build/Update，才能报告更新完成。需要重启的补丁还须用 `System.info.up_time` 核对启动发生在安装提交后；运行时间缺失时保留未确认状态。缺少补丁号、旧版本、候选消失或网络恢复均不足以确认成功。
- 网络不可达/超时显示等待恢复；认证、权限和证书错误停止自动读取并给出恢复动作。轮询每 5 秒，最长 40 分钟，超时后保留未确认状态并允许用户手动回读。

### 证据与五端影响

[2026-10-22 官方升级观察](../environments/INDEX.md#2026-10-22-dsm-update-observation)覆盖 DSM 7.2.1-69057 Update 12 到 Update 13 的下载、安装接受、进度与重启后版本回读；这是官方页面的行为证据，不是原生客户端实际安装验收。驱动检查响应完整结构与其他升级类型仍未验证。

macOS 使用增量共享领域类型与 Repository 默认不支持方法实现；iPhone/iPad 不新增安装入口，Windows/Android 代码与安装范围不变。合成回归检查许可、版本变化、额外警告、重复提交、断线未知与阶段展示；未完成的真实环境项只见[当前限制](../../../progress/KNOWN_LIMITATIONS.md)。
