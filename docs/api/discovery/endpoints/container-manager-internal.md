# Container Manager 内部接口

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `container-manager-internal` |
| 项目组件标识 | `container-manager` |
| 所属范围 | Container Manager |
| 能力名称 | 容器、映像、仓库、网络、项目、事件与容器详情候选读取 |
| 分类 | `internal` |
| 操作性质 | `mixed` |
| 风险等级 | `critical` |

## 2026-10-06 缺失请求字段补全（只读与静态）

[本次观察](../environments/2026-10-06-container-vmm-api-read-observation.md) 已从当前官方页面
重新核实 DSM 7.2.1-69057 Update 12 / Container Manager 24.0.2-1535。设备待归属，账号
群组角色未单独核实；不修改旧 lab-a verification。Container/Network/Image/Registry 列表
与空 Project.list 成功结构为 `read-verified`，下列新增写定义均为官方 MainVue.js `static`。
请求仍由运行时 API.Info 决定路径/编码，不能把当前网页的 entry.cgi/API-name 路由固定到客户端。

| API / 方法 / 版本 | 参数与已知响应消费 | 权限、副作用及结果边界 |
| --- | --- | --- |
| `Container.get` v1 | 原 `name`；官方读取后交给 profile 状态模型 | 配置可能含路径、变量及秘密；本次未读取真实配置，不允许普通日志记录 profile |
| `Container.create` v1 | `is_run_instantly:boolean`、`profile:object`；成功处理消费 services、start_dependent_container、dependent_container | 创建及可选立即运行可能写文件、开放端口或启动依赖；需专用授权目标、套件/目录权限、固定配置与防重复。未观察真实写响应，不用同名对象认领未知创建 |
| `Container.set` v1 | 原 `name`、`edit_name=profile.name`、`profile`；使用与 create 相同端口转换 | 更改配置/名称/资源/挂载可能中断应用。局部能力编辑另仅提交 privileged=false、CapAdd、CapDrop；不得默认扩大权限 |
| `Project.get_share_info` v1 | `path`；静态消费 is_docker_compose_yml_exist、content、compose_path | 只读文件候选；本次未读取用户路径或 Compose 正文 |
| `Project.create` v1 | 直接发送 name、content、share_path、enable_service_portal、service_portal_name、service_portal_port、service_portal_protocol；成功处理消费 id/name/enable_service_portal/services | 本地 is_run_instantly 不在此 profile 中；它在接受 create 后另开 build_stream。创建项目记录不等于服务已启动 |
| `Project.get` v1 | 单 `id`；静态状态字段包括 id/name/path/share_path/content/schema/containerIds/status/created_at/updated_at 及门户/is_package 字段 | 当前空 Project.list 不证明非空类型；按原项目身份绑定，不根据显示名称关联写入 |
| `Project.update` v1 | 原 `id`；Compose 编辑追加 content，门户编辑追加 enable_service_portal/service_portal_name/service_portal_port/service_portal_protocol | 配置保存与重新构建是不同动作；官方保存后另询问是否构建。Compose 可能挂载目录、创建资源或开放端口，不能在没有明确后果的普通保存中自动部署 |
| `Project.build_stream/start_stream/stop_stream/restart_stream/clean_stream` v1 | 单 `id`；官方采用 text 响应与下载进度回调 | 写方法与普通 JSON API 不同，流式终态/断开语义未验证；不猜成功标记或自动重放。clean 不等于 delete，不假定删除数据范围 |
| `Project.delete/log` v1 | 单 `id` | delete 是项目写操作，log 是内容读取；本次未执行。托管项目与具体状态限制仍需保留 |
| `Network.list_container/set` v1 | list_container 为 limit=-1/offset=0；set 为 networkName、containers 名称数组 | set 修改连接关系，与 Network.create/remove 不同；未实现/未验证，不能借网络详情读取扩大为连接修改 |

容器 profile 的已知字段：

| 字段 | 类型/转换 |
| --- | --- |
| name、image、cmd | 字符串；默认 cmd 为空；映像来自明确选择 |
| cpu_priority、memory_limit | 数字；关闭资源限制时均为 0，开启时 CPU 10/50/90，内存界面 MB 转字节（×1024²），最低界面值 6 MB；非 VMM 的 MiB 写字段 |
| port_bindings | `{host_port:number,container_port:number,type:string}[]`；自动主机端口为 0；UI tcp_udp 必须拆 tcp/udp 两项 |
| volume_bindings | `{host_volume_file:string,mount_point:string,type:string,is_directory:boolean}[]`；默认 rw，不推断目录访问权限 |
| env_variables | `{key:string,value:string}[]`；敏感值不入普通日志、fixture 或恢复摘要原文 |
| network、use_host_network | `{name,driver}[]` 与布尔；host 模式 network=[]，普通模式保留选择网络 |
| privileged、CapAdd、CapDrop | 布尔及能力数组；开启 privileged 时官方清空两个能力数组，不由客户端暗中升权 |
| enable_restart_policy | 布尔，不泛化为 Docker 的任意重启策略字符串 |
| enable_service_portal、service_portals | 布尔及 `{port,protocol}[]`，依赖 Web Station；端口最终类型仍缺实际响应/提交证据 |

没有真实新增写回执、错误码、流式终态或非空项目响应，以上不等于完整服务端 Schema。
新 Adapter 接入时按这些来源建立合成请求断言；断线或取消保留未知，只读恢复，明确拒绝
不能被随后外部变化覆盖。能力/权限不足只限制相关操作，不阻断已有容器清单。
五端影响：macOS 与 Windows 对照现有实现补对应缺口；iPhone/iPad 同一共享接口及触控
流程，尚未实施创建/编辑/项目写；Android 仅记录。此次文档不开放新写入口，不变更公开
Schema、权限、持久化或依赖；旧环境写兼容等级保持。Network.list 的本次字段继续支持
M7c3，但仍没有可用于验证 IPv6 地址/IP 伪装结果的新字段。

## 2026-10-06 Apple 移动网络管理增量

M7c3 沿既有 Network.list/create/remove v1 实现 iPhone/iPad 创建、详情、单项/多项删除和
持久恢复；共享旧 Mac 签名进入同一网络流水线，不改变 NAS 字段。实际组合根开放已实现
创建，继续核对 v1 能力范围和当前 Container Manager 授权，不额外强加 DSM 管理员身份。
只删除非默认且无关联容器的网络，写前重读比较确认时原 ID、名称与可读配置；每次 remove
只包含一个已确认网络对象，非空 failed 数组即该项拒绝，不猜测数组内未验证的目标字段。
批量失败停止后项，明确拒绝和预检失败不能被外部移除覆盖。本轮已用合成测试复现旧误报。

创建继续只发已记录默认/手动字段，不传 driver。接受回执与完整列表中的原名称、bridge、
IPv6 开关、手动 IPv4 配置共同确认；历史 list 未验证 IPv6 地址和 IP 伪装结果字段，不能
因此猜测响应或声称每个选项已核对。没有创建回执但出现同名对象时只显示“已找到同名网络”，
不冒称本次创建成功。无删除回执时，原 ID 消失只显示当前已不在列表中，不认领写入成功。
未找到目标的未知创建、仍存在的未知删除保持保护，刷新只读取，不自动重新提交。

创建/删除分别保存写前、接受、明确拒绝与完成边界；保存失败停止后续请求。独立受保护的
Containers/network-operations-v1.json 仅保存账号、目标/配置摘要与阶段，名称/地址仅在
当前内存；重启后的未发送项停止，已发送项只读恢复。完整列表检查已有可选 total/offset
类型和数量，缺失/重复身份不作为成功证据。后续对抗复核另补旧批量入口的删除接受标记：
丢回执后原 ID 消失仍不能认领本次成功；移动恢复同时保护原 ID/名称，外部改名不能绕过。
共享 ContainerNetwork 增加默认 nil 的 ipRange
只读字段，延续已记录 list 字段，不增加持久化配置迁移。

五端影响：iPhone/iPad 原生表单、触控多选、详情和活动记录；macOS 保留页面与调用，获得
同一拒绝/预检修正并运行回归；Windows/Android 仅登记同等安全语义，不改代码。当前移动
开发格式不提供旧开发记录迁移，登录、权限、App 身份、依赖与最低版本不变。回滚停用
入口并保留未完成记录，不自动恢复已删除网络。实际验证见移动主计划和验证历史，真实
创建/副作用及新环境未验证，不提升历史证据等级。

## 2026-10-06 Apple 移动容器删除与恢复增量

iPhone/iPad M7c2 沿用 Container.list/delete v1，发送当前原 ID 对应的 name、force=false、
preserve_profile=false，不增加卷或目录删除字段。详情和多选确认明确容器及其内部未外存
文件不可恢复，映像与共享文件夹数据不自动删除；实际数据后果仍需专用可丢弃环境验证。

共享旧批量入口和新增原快照入口进入同一实现。删除前比较原 ID、名称和原生运行/托管
状态，仅停止且非套件托管的容器可删除；Compose 项目的 is_package 限制同样生效。
写前、接受、明确拒绝和已完成四个边界沿现容器控制观察者保存。写前保存或权限失败零写，
回执保存失败停止后续链路；证书错误保留原错误且停止，明确拒绝不能被后来的外部删除覆盖。
旧批量后项预检单独发生在提交边界之前，已发送前项与未提交/明确拒绝后项分开计数。

Container.list 的可选 total 必须等于实际条目数、offset 必须为零，且均须原生数字。
本轮合成测试复现部分清单被误判删除完成，修正后启停、删除预检及只读恢复均使用严格
清单；这不是新增真实响应观察。删除完成只由完整目录中原 ID 消失证明，同名新 ID 不会
被继续删除；原 ID 改名仍不能认领删除完成。缺少可选分页元数据时沿既有 v1 全量契约。

移动沿用 Containers/container-controls-v1.json，增加本地 delete 类型而不扩展共享
ContainerAction 的启停三动作。记录仍只有账号/目标摘要、阶段和接受标记，名称只在
当前账号内存保留；损坏目录或在途文件丢失不能解除保护。批次出错后剩余项停止，不自动
续跑；未知删除与启停按原 ID/名称双向互斥，重启只读恢复。原账号迟到结果只写原记录。

五端影响：iPhone/iPad 新增删除闭环；macOS App 无新增改动，共享旧签名保留，清单完整性、
批量计数及证书停止行为同步修正并运行共享与 Mac 回归。Windows/Android 只登记同等恢复
和完整性要求，不改源码。无新增依赖、应用身份、权限或登录格式；移动采用当前开发格式，
不提供旧开发记录迁移。回滚停用删除入口并保留未完成记录，不恢复已删容器。实际命令、
结果和真机条件见移动主计划与验证历史；不提升现有环境的证据等级。

## 2026-10-06 Apple 移动映像删除与恢复增量

M7c1 沿用 Image.list/delete v1 与完整 Container.list 的占用判断，不新增 NAS 方法或
参数。单项/多项确认绑定原始映像 ID、仓库和标签；提交前重读完整清单与占用，停止容器
同样计入占用。按原 `images` 数组合并同仓库标签，无标签条目使用 `identity`，不得隐含
删除同 ID 的其他有效标签。删除后的单项结果按原标签地址或裸映像 ID 判断；标签改指向
其他 ID 时仍保留未知，不按旧选择 ID 消失推断成功。

共享兼容增加固定选择请求、写前/接受/明确拒绝检查点和只读恢复方法。旧 Mac 入口仍
进入同一提交/回读实现；未实现新协议的适配器直接不可用，不回退到无记录写入。持久
恢复摘要包含所选身份、规范化地址与原 ID 的 SHA-256 及是否无标签。移动新增独立受
完整文件保护、排除备份的 `Containers/image-deletions-v1.json`，仅保存账号摘要、目标
摘要、阶段/接受标记与逐项结果，不保存仓库名称、路径、地址或凭据。

写前存储失败零提交，回执保存失败停止后续读取；明确拒绝为终态，不能被第三方删除
覆盖。原未知记录重启后只读清单恢复，准备但未提交的记录停止；部分完成保留未结束
结果且不自动重发整个批次。恢复不依赖容器占用读取能力，新删除仍必须取得完整占用
信息。当前账号权限或证书失败停止关联链路，旧账号迟到结果只写原记录。

移动下载和删除共享当前账号的恢复保护；下载提交前再次比较标签及原裸映像摘要，
删除提交前再次检查相关下载记录。共享内存互斥同时保留；恢复中的同标签/裸映像不能
被另一操作重写。结果终态才允许移除本机记录，移除不操作 NAS。

没有新增依赖、身份或系统权限，不迁移已发布 Mac 数据或登录结构；回滚停用新入口并
保留未完成记录。macOS 通用删除反馈缺陷另行请求授权，本片映像路径已禁用该兜底，
不修改 Mac App。Windows/Android 仅记录影响，不改实现，不提升任何真实环境证据等级。

## 2026-10-06 Apple 移动映像下载与恢复增量

iPhone/iPad M7b 继续使用已记录 Registry.search/tags v1、Image.pull_start/pull_status/list
v1；搜索沿现有前 50 项结果，不猜分页或取消接口。下载前使用当前套件授权，重新读取标签与
完整映像清单，用户在固定仓库/标签页面明确点击下载；离开页面不停止 NAS 下载。

共享 `ContainerImagePullRecovery` 保存规范化目标与原映像 ID 的 SHA-256 摘要，以及原类型
字符串/安全整数任务编号。兼容增加写前、接受、明确拒绝检查点及只读恢复方法，旧 Mac
签名继续进入同一请求/状态检查路径，默认协议实现不支持新增写入。移动独立
`Containers/image-pulls-v1.json` 采用完整文件保护并排除备份，只含账号/目标摘要、原任务、
阶段与稳定结果类别，不含仓库名称、地址或凭据；任务编号不进入用户界面或日志。

写前落盘失败零提交，回执保存失败停止后续读取。有回执时只查原 task_id，并将状态回显
repository/tag 规范化后与原摘要比较；finished 必须是原生布尔，结束后还须完整 Image.list
包含目标标签。百分比、旧标签存在或其他任务完成均不能代替此条件。无回执只恢复保护记录，
不从同名映像或聚合任务猜测、不自动重发。恢复仅依赖 Image 能力，Registry 缺失不阻断已有
任务读取；当前授权失效或证书错误停止关联链路，跨账号迟到回执只写原记录。

重启后恢复的下载继续参与原标签及原裸映像身份的删除互斥；未提交记录停止、不自动执行。
明确失败不被之后外部变化改写为成功，原任务读取的 1202 沿既有观察解释为下载失败；完成后
Image.list 的同码仍只表示无法读取结果。macOS 的跨进程恢复仍未实施，旧内存行为不变。
Windows/Android 只记录语义影响，不改源码；没有新增依赖、系统权限或真实 NAS 写验证。
移动恢复格式沿本阶段已批准的独立存储范围；不迁移旧配置，回滚停用新增入口并保留记录。
源码、合成与目标构建证据见移动主计划和验证历史，不能提升既有环境验证等级。

## 2026-10-06 Apple 移动容器控制与恢复增量

iPhone/iPad M7a 沿用下方已记录的 Container.list/start/stop/restart v1，不新增网络方法或
猜测参数。兼容增加 `ContainerControlState`、逐项提交观察者及只读管理状态方法；旧
`controlContainers` 继续进入相同身份/托管/状态校验流程，旧协议适配器默认不支持新增
管理方法，不回退到不带恢复记录的写调用。移动入口采用 Container Manager 明确应用
授权，不把 DSM 管理员身份视为套件授权；NAS 仍执行最终权限裁决。

确认固定 ID、名称、原生 Running/Paused/Restarting、StartedAt 与项目托管状态。每项
提交前重新读取并重新授权，willSubmit/accepted/rejected/verified 分别保存到当前账号
独立的 `container-controls-v1.json`；记录只保留账号和目标摘要、操作类型、启动时间、
逐项阶段及稳定错误类别，不含名称、主机、凭据或事件正文。文件使用完整数据保护并排除
备份；记录损坏或保存失败停止后续写。批次出错后未提交项停止，恢复不会自动继续剩余项。

重新打开后，只有实际相同 ID/名称的完整状态读取可以解除未知保护；重启还要求启动时间
严格增大，不能凭 running 或同名容器认领。明确拒绝、未提交项不因外部状态变化改判成功。
同一目标 ID 或名称的未完成记录阻止重复操作；跨账号迟到回执只更新原账号记录。活动日志
正文和用户来自已有完整 Log.list/load 读取，只在当前页面内存展示，不保存到恢复文件。

五端影响：iPhone/iPad 新增上述流程；macOS App 不改，旧共享调用保持兼容并需完整共享与
Mac 构建回归。Windows/Android 仅记录恢复/身份语义，无源码变化。无依赖、系统权限、
Bundle ID 或登录配置变更；移动开发数据不做历史迁移，回滚停用新增控制入口并保留配置。
当前属于源码与合成验证范围，最新实际命令/结果见移动主计划及验证历史，不提升下方真实
环境等级。删除、映像、网络和 VMM 另片实施；Container.Log.get/export 等缺证据接口继续
不实现。

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Docker.Container`、`SYNO.Docker.Image`、`SYNO.Docker.Registry`、`SYNO.Docker.Network`、`SYNO.Docker.Project`、`SYNO.Docker.Log`；任务列表候选 `SYNO.Entry.Request.Polling`；详情候选另有 `SYNO.Docker.Container.Resource` 与 `SYNO.Docker.Container.Log` |
| 路径 | 由 `SYNO.API.Info` 在运行时返回，不固定拼接 |
| HTTP 方法 | `POST` |
| API 版本 | 当前客户端范围为 v1；每项调用前仍须核对能力范围 |
| 鉴权机制 | DSM 会话 Cookie 与可选安全请求头；值不得进入 URL、日志或诊断导出 |
| 内容类型 | 由能力发现与当前 DSM 客户端适配器决定 |

当前稳定读取参数：

| API / 方法 | 参数 | 类型 | 必需 | 含义 |
| --- | --- | --- | --- | --- |
| `Container.list` | `offset=0` | `integer` | 是 | 从首项读取 |
| `Container.list` | `limit=-1` | `integer` | 是 | 读取当前容器列表 |
| `Container.list` | `type=all` | `string` | 是 | 不按状态过滤 |
| `Image.list` | `offset=0`、`limit=-1` | `integer` | 是 | 2026-09-17 官方完整映像清单请求 |
| `Image.list` | `show_dsm=false` | `boolean` | 是 | 与官方普通映像页一致，不以字符串编码 |
| `Registry.search` | `offset=0`、`limit=50`、`page_size=50` | `integer` | 是 | 固定首批分页 |
| `Registry.search` | `q` | `string` | 是 | 用户输入的仓库查询词 |
| `Registry.tags` | `repo` | `string` | 是 | 仓库稳定名称，不使用翻译文案 |

写入候选只保留既有静态/观察记录，不作为 Android 开放条件：

| API / 方法 | 已知参数 | 当前结论 |
| --- | --- | --- |
| `Image.pull_start` | `repository`、`tag` | 2026-07-27 请求在发送前终止；没有行为验证，入口关闭 |
| 容器、映像、网络、项目其他写方法 | 未在本记录固化 | 必须在专用测试目标重新发现并完成写后复查 |

### 2026-09-19 生命周期与镜像删除参数静态确认

本节更新上表的“未固化”历史状态，详见[本轮只读观察](../environments/2026-09-19-container-lifecycle-read-observation.md)。
DSM 7.2.1-69057 Update 12 / Container Manager 24.0.2-1535；设备归属未确认，不
复用旧 lab-a 行为等级。官方 MainVue.js 静态确认 Container.start/stop/restart v1
均发送 `name`，普通 delete 为 `name,force=false,preserve_profile=false`；重置的
preserve_profile=true 不得冒充删除。Image.delete v1 发送 `images` 对象数组，元素
为 `{repository,tags:[...]}` 或裸映像标识的 `{identity}`，不使用单 id。

Container.list v1 本轮自然请求为 POST entry.cgi、offset=0/limit=-1/type JSON
字符串 all，成功响应含稳定 id/name 及 State 对象。Running/Paused/Restarting 为
布尔，ExitCode 为数字，Status/StartedAt/FinishedAt 为字符串，时间字段呈 ISO
日期格式。请求 ID 与实际名称/时间值不进入记录；重启必须绑定同一容器身份并核对
启动时间变化候选，不能仅以 running 状态回显报成功。尚无本轮真实写行为结论。
macOS 既有单 id 请求需修复；Windows 生命周期和映像管理依本记录继续实施。

2026-09-20 追加静态限制及源码：官方容器写入口排除由容器自身或 Compose 项目标记
为 is_package 的实例；项目用 Labels[com.docker.compose.project] 对应 Project.list
的 name，项目 is_package 缺省 false。两端现已补名称寻址、上述托管预检及结果
核查核心；Mac 停止/重启新增确认，未知结果按会话内目标保留、只查不重发。
Windows 的启停/重启/删除核心按当前会话与接口开放，不依赖 DSM 单值版本门，
原生管理 UI 已接操作切换、筛选、多选确认、逐目标结果和会话内恢复，核查不重发；
Mac/共享 Swift 构建未运行，不能称目标端已验收。
Windows 映像删除已按下节接入；Mac 同日完成参数/标签及只读恢复源码修复，目标
构建未执行。不因源码修正而冒称两端镜像管理与验收全部完成。

### 2026-09-20 Windows 镜像标签删除适配

镜像清单按原生 tags 展开，标签身份绑定原始 ID/仓库/标签；旧无 tags 摘要只读显示，
不猜 latest。分页 total 与原始镜像记录数核对，不与展开后的标签数比较。内部 v1
delete 发送 images 对象数组，同仓库合组 tags，裸标签用 identity；不发送单 id 或
force。裸 identity 不得隐含删除同 ID 的其他有效标签。提交前读取完整镜像及容器
清单，按官方 image/Image/ImageID 静态归属规则检查包含停止容器在内的占用。

用户确认绑定清单快照和请求标识，名称/ID/标签变化重新选择；同作用域未知请求按
标签地址或裸身份互斥，回执丢失、取消或部分成功只读核查。标签删除须确认所选地址
消失（底层 ID 可保留其他标签）；identity 删除须原始 ID 消失。明确拒绝不因第三方
删除而改判成功。窗口包含多选、确认、反馈与恢复，按会话/接口开放，无未验证恒关门。
权限仍由 NAS 裁决；运行中的并发外部变化由 NAS 最终保护，Agent 未执行真实删除。

五端影响：Windows 新增兼容可选镜像元数据/默认仓库方法；Mac 同日修复见下一节；
iPhone/iPad 保持只读，Android 不改代码。无需存储、依赖、权限迁移，
回滚仅撤销增量与入口；不改变下方历史 verification 或声明真实写行为已经验证。

### 2026-09-20 Mac 镜像标签删除源码修复

Apple 共享 ContainerImage 增加可选 sourceImageID，标签行使用原始 ID/仓库/标签
组合成会话内选择身份，不改变存储。Image.list/删除固定内部 v1；total 对原始记录
数核对后再展开 tags，普通旧摘要不猜 latest、无可写身份。根据完整容器清单计算
占用，保留普通名称/摘要/裸标识的已记录官方静态归属。delete 发送 images 数组，
同仓库合组 tags、裸标签 identity；仍要求权限、确认、新鲜身份和无占用。

未知批次在仓库会话内保留原始标签范围；独立 reviewContainerImageDeletion 只读
Image.list，旧适配器默认不支持，绝不回退调用删除。标签换 ID 不按旧选择消失判
成功，原生窗口固定确认时的选择，增加“核查删除状态”；移除该路径的 UI 列表消失
兜底成功判定。明确拒绝为终态，不因其他客户端动作改判成功。新增共享合成请求
fixture `container-manager/delete-image-tags/synthetic-selection/request.json`，
Apple/Windows 请求断言使用同一结构；Windows 已执行，Apple 测试源码未执行。
本机无 Swift/macOS，不宣称构建、签名或真实删除验收通过，不提升任何环境等级。

同日对齐 RESTARTING 分组：官方将该状态归入 running，因此停止/重启不应要求
Restarting=false。两端已修正提交资格；稳定停止才允许启动/普通删除，暂停/托管/
缺失运行字段继续拒绝。结果核查仍要求不再重启中，restart 还要 StartedAt 变大，
不能以允许提交或过渡状态回显宣称完成。没有新增方法/参数或真实写行为验证。

`Container.Resource.get`、`Container.Log.get/export`、`Container.stats/get_process` 的完整参数和响应尚未获得脱敏请求证据，不得根据方法名猜测。

### 2026-09-17 映像列表与下载任务分离

2026-09-20 更新：下方“暂不实施/关闭”是当时决策；后续用户已批准兼容接口增量和
可测试入口。Windows 现接入 pull_start/pull_status v1 及任务身份绑定，见发现记录
同日补充；仍只有静态契约与合成证据，真实字段类型、完成/失败行为尚待用户验证。
严格接受字符串/非负整数 task_id 并原类型回传，finished 只接受原生布尔；进度值
只作显示，不能单凭百分比或旧标签存在判完成。同一任务成功响应、finished、仓库/
标签回显匹配与完整列表标签可用共同支持“任务已结束，镜像可用”，不承诺远端内容
必定变更。未收到 task_id 不从 admin 聚合列表猜测，未知只核查、不重发。

启动前核对标签与读取权限，按请求 ID/作用域及仓库标签互斥；与对应标签/裸镜像
删除交叉保护。已知任务状态读取只依赖 Image 能力，不因 Registry 能力缺失而阻断。
Registry 原生窗口增加确认、下载列表、5 秒可见任务刷新与会话内恢复；关闭只停止
本地等待，不发送未发现的取消接口。能力满足时用户可操作，不加单值 DSM 版本门。
新增 pull-start/pull-status 合成请求 fixture；旧 delete-image fixture 的错误 id
同步改为 images:[{identity}]，Apple 构造器测试和 Windows 实际适配器断言同步。
五端：Windows 实施；Mac 同日新增任务追踪源码，目标构建与测试未执行，见下节；
Apple 移动端保持只读，Android 不修改。无持久化/依赖/权限迁移，不新增真实写证据。

### 2026-09-20 Mac 拉取任务追踪源码

新增兼容请求/进度结果和默认协议方法，旧适配器未实现时不回退调用启动；实际
macOS 适配器按当前 Image/Registry v1 能力开放。旧 pullContainerImage 入口委托
同一受保护流程，不再绕过任务记录；新的 Mac 搜索窗口带固定目标确认与下载任务
分区，5 秒仅刷新可见且正在下载的任务，手动核查不发送 pull_start，关闭取消本地
任务等待而非 NAS 下载。确认变化失效，已确认终态不被迟到缓存覆盖。

任务编号字符串原样回传；ServiceJSON 使用 Double，整数编号只接受不超过 2^53−1
的安全整数，不能把超范围编号四舍五入后查询别的任务。finished 原生布尔、回显
仓库/标签及完整镜像清单共同验证可用。无回执、查询失败或取消保留未知，不猜取消
方法；拉取与对应镜像删除交叉保护，保留原请求编号的结果供重复调用只读核查。
这些是源码/合成契约范围，没有新的真实字段或写行为验证。

恢复仅限同一仓库实例/工作区的内存记录，不跨应用重启或彻底重建登录连接；不会
以镜像名称重绑全局任务，空记录提示用户先在 DSM 核查。这不改变持久化格式或
读取其他账号任务，跨进程恢复若需要持久化必须单列审批。Mac Swift/App 构建和
新增回归当前未运行；iPhone/iPad 新协议只保留默认不可写行为，Android 源码不变。

[本轮只读记录](../environments/2026-09-17-container-image-pull-read-observation.md)已核实
DSM 7.2.1-69057 Update 12、Container Manager 24.0.2-1535 管理员环境的 Image.list
请求及成功响应结构。设备归属仍未知，不更新旧 lab-a 等级。列表为 images 数组与
数值 offset/limit/total；每项 id/repository/digest/remote_digest 为字符串，tags 为
字符串数组。完整请求仍返回非零 offset、总数不匹配或畸形分页字段时，客户端仅使
映像分区失败，不把部分页当作完整目录。Windows/macOS 已有列表调用同步修正参数；
未新增公开模型，tags 多值表达仍需单列兼容扩展。

官方 MainVue.js 静态线索另确认 Image.pull_start 回执的 task_id 被用于
Image.pull_status v1 的 task_id 参数。状态消费 finished/repository/tag/downloaded，
另一处消费 current/total；实际类型、单位、失败终态及任务消失语义仍未验证。
Entry.Request.Polling.list v1 的 task_id_prefix 与 extra_group_tasks 参数仅作为
聚合任务发现候选（具体固定值见环境记录），不能用聚合列表为空证明某个下载成功。
Image 与 Polling 能力元数据声明 JSON；没有执行下载或自行轮询真实任务。
权限/取消/重复提交/回执丢失/最终回读契约未闭合，Windows 下载入口保持关闭，
不新增猜测的 Domain/Repository 方法。其他三端只记录影响，不增加写能力。

### 2026-09-10 读取更正（待归属观察）

2026-09-16 [Windows 对齐只读核查](../environments/2026-09-16-windows-parity-read-observation.md)
确认当前 Container Manager 24.0.2-1535 的 Container/Log v1 声明 JSON；仅能力元数据
read-verified，不增加当前日志响应或写操作证据。Windows 按本节已有契约同步完整读取与分页。

见[日志与网络观察](../environments/2026-09-10-container-read-observation.md)。本次观察未确认设备关系与完整版本，不升级下方历史基线的证据等级。

- `SYNO.Docker.Log.list` v1：官方日志页面发送 `action=load, offset=0, limit=1000, sort_by=time, sort_dir=DESC, loglevel="", filter_content="", datefrom=0, dateto=0`。客户端此前只有 offset/limit，与官方请求不一致。
- 成功响应 `logs` 元素为 `event/level/log_type/time/user`，均为字符串；时间为 `yyyy/MM/dd HH:mm:ss`。顶层 `offset/limit/total` 和分级数量为数字。客户端按返回总数读取后页，不能将首批当作全部。
- `SYNO.Docker.Network.list` v1 无附加参数，返回 `network` 数组；关联容器为 `containers:[string]`，显示数量应取数组长度。缺失数组且没有已支持计数字段时标记分区失败，不冒充零。
- 同一网络响应还包含 `enable_ipv6:boolean` 与 `gateway/iprange/subnet:string`；用户已明确批准为共享领域模型增加向后兼容的可选只读字段，macOS 展开显示子网、网关、IPv6 与关联容器名称，不改请求或存储格式。官方 UI 的 IP 伪装显示未在本次响应中找到对应字段，不按界面文案猜契约。
- 不增加或开放写操作。macOS 修复读取与分区展示；Apple 移动端专用清单、Android、Windows 实现不变，后两端只记录后续适配影响。
- 后续同日核对 `Project.list` v1 无附加参数：官方无项目返回 `{}`，不是空数组；按 ID 键值解析的非空摘要仅有官方脚本静态证据，字段 `name/status/containerIds`。客户端仅对项目分区兼容这一对象容器。
- 网络创建表单和静态参数差异见[观察记录](../environments/2026-09-10-container-read-observation.md#项目列表与新建网络后续核对)。实际创建未发送，不能把只读详情授权或表单可见当成写行为验证。
- 用户后续已批准创建契约同步：默认参数为 `name/enable_ipv6/disable_masquerade`，手动 IPv4 加 `subnet/iprange/gateway`，手动 IPv6 加 `ipv6_subnet/ipv6_iprange/ipv6_gateway`，不传 `driver`。客户端增加确认、校验、同名互斥与读前/读后核对；提交能力默认关闭，只有合成测试显式开启，不升级真实写入证据。五端影响与迁移/回滚见观察记录。
- 用户再次明确要求可点击测试包后，macOS 独立本地测试包允许手动确认并提交创建；正式版默认关闭不变，真实写入仍待用户验收，不将入口开放升级为行为验证。
- 同日用户授权单个无关联测试网络的真实删除：`Network.remove` v1 发送 `networks:[所选网络对象]`，响应 `failed:[]`，最终列表目标消失。对象键及限定证据见[删除观察](../environments/2026-09-10-container-read-observation.md#用户授权的单个测试网络删除)。已纠正 Apple 的单 id 参数及共享请求 fixture；不外推到其他网络、权限、版本或其他写操作。
- 1.0.5 按用户明确要求纠正正式版创建接线：不再要求 localtest 包标识，保留实际接口能力和所有提交保护。此前“正式版关闭”记录为历史状态，不代表当前入口策略；不因该修正宣称其他环境已验证。

## 响应与错误

成功响应仅记录稳定外层：

```json
{
  "success": true,
  "data": {}
}
```

| 数据类别 | 当前可依赖范围 | 客户端处理 |
| --- | --- | --- |
| 容器 | 稳定标识、显示名称、状态；其他字段按能力解析 | 主列表失败时模块失败，不以空列表代替 |
| 映像、网络、项目、事件 | 数组容器和稳定标识的兼容解析 | 每个分区独立失败降级，不遮蔽容器主列表 |
| Registry 搜索 | 仓库名、Registry、描述、收藏数和官方/可信标志的可选字段 | 缺失可选字段使用安全默认值 |
| Registry 标签 | `tag` / `name` 或字符串数组 | 去重且保持首次顺序 |
| 资源、进程、容器日志 | 未形成可依赖 Schema | 保持关闭，不读取真实内容 |

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| 能力缺失或版本不覆盖 | 当前套件不提供兼容能力 | 否 | 隐藏对应入口；其他分区继续可用 |
| 附属读取失败 | 该分区暂时无法读取 | 是 | 显示明确不可用状态和刷新入口 |
| 登录失效、证书变化或取消 | 会话/信任边界已改变 | 重新认证后可重试 | 立即上报，不吞并为附属失败 |
| 写请求断线或结果不一致 | 已提交但结果无法确认 | 否 | 不自动重放；刷新并回读最终状态 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 客户端范围 v1 | Container Manager `24.0.2-1535` 的容器列表、Registry 搜索/标签请求结构已有脱敏记录；`pull_start` 未发送 | 2026-07-27 | `docs/compatibility/DSM_COMPATIBILITY_MATRIX.md` |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 未捕获详情请求版本 | 官方页面只读显示总览 CPU/RAM/网络，以及容器详情网络、环境变量、进程和日志分区；未读取内容或原始响应 | 2026-08-02 | `docs/api/discovery/environments/2026-07-29-lab-a-dsm-69057-u12.md` |

第二条只证明当前官方界面存在对应能力入口，不证明详情 API、参数或响应已经验证。

## 能力探测与降级

- 启用条件：`SYNO.API.Info` 返回目标 API，v1 落在其版本范围内，且客户端对该只读契约有记录。
- 新版本默认行为：内部读取先关闭或显示不可用，完成新版本复验后再启用。
- 接口缺失：仅关闭对应分区；容器主列表与无关模块不受影响。
- 字段缺失或类型变化：保留未知状态，不把解析失败冒充空数据。
- 权限不足：提示当前账号无法读取；不得自动提升权限或切换账号。
- 网络失败：允许用户刷新；写请求不自动重放。
- 替代的官方 API：当前 Container Manager 必要能力没有等价公开 API。
- 功能开关：写能力必须同时满足版本兼容记录和专用目标行为验证。

## 客户端与测试

2026-09-17 Windows 网络只读详情迁移：在原有 Network.list v1 响应中增加兼容可选
详情映射及原生展开视图，显示驱动、关联数量/名称、子网、网关、IP 范围和 IPv6。
数组存在时数量来自数组；没有数组时必须有明确一致的非负整数计数，缺失或错误
只让网络分区失败，不补零。名称未提供与已知无关联分别显示，错误 IPv6 不补 false，
非 IP/CIDR 地址字段不作为可用地址显示。展开不会追加请求、读取日志正文或环境变量。
Apple 同类计数修正拒绝 Boolean、小数、溢出和冲突计数，新增回归待 Mac 执行。
这些源码/合成证据不开放 Windows 网络创建/删除，也不提升真实环境写行为等级。

2026-09-17 Windows 创建核心：完整自动/手动 IPv4、IPv6 与 disable_masquerade
配置复用既有创建契约，不发送 driver。客户端验证名称、地址族、规范 IPv4、CIDR
及子网归属，读取完整网络列表后检查名称占用；同一客户端按 NAS/账号/地址作用域
和名称保存未确认操作，重复请求或重建 Repository 后只回读。基本创建需唯一新
身份、bridge、IPv6 开关和手动 IPv4 参数吻合才确认，不把旧 ID 改名当作新建；
明确拒绝不因其他客户端改值而成功。启用 IPv6 或禁用 IP 伪装时，当前没有已验证
的完整选项回读字段，保留未确认状态。生产行为门关闭，已接原生完整配置与确认/
核查表单，并以合成仓库验证正常、拒绝、未知、关闭取消和主列表更新；不改变
Mac 1.0.5 的既有入口策略，也不声称真实套件或路由副作用已验收。

2026-09-17 Windows 删除核心及原生流程：remove v1 使用已记录的 networks 对象数组，
只复制白名单字段。确认绑定稳定 ID 与读取基线，提交前重新核对系统名称保护、明确
零关联、驱动及 IPv6 开关；缺失或类型错误不补可删除状态。共享协调器隔离 NAS/账号，
同一目标及创建/删除交叉互斥，未知结果不重放。严格完整列表按原 ID 确认消失，部分
消失逐项计数，明确拒绝不被其他客户端操作覆盖为成功。原生多选、风险确认、恢复核查、
离页取消与父列表刷新已有合成测试；没有新增真实删除记录，批量仅有合成证据。Windows
生产写门仍关闭；macOS/iPhone/iPad/Android 无代码或入口策略变化，无契约/存储迁移。

2026-09-17 Windows Registry 只读对齐：运行时路径、固定 v1 与 FORM/JSON 声明，
search 的 offset/limit/page_size 为数字，q/repo 按声明编码。支持 data/items/results
搜索数组、data/tags/items 标签数组及传输层保留的顶层数组；标签可为原生字符串或
tag/name 对象，按首次出现顺序去重。缺失/错误列表或必需身份不冒充空结果；可选收藏
数和徽章缺失/错类型保留未知。仅请求首批 50 项且界面明示，不猜测后页。搜索/标签
状态绑定请求代次和当前仓库，离页/改词/切换仓库取消旧读取，迟到响应隔离。
真实权限、数量与弱网仍待验收，不增加 pull_start 或其他写行为证据。
同波按用户既有授权修正 Apple 共享标签解析：原 objects.compactMap 会丢弃字符串
标签并把畸形响应当作空/部分列表；现接相同已记录形态并严格区分错误。macOS 调用
签名和 iPhone/iPad 共享 API 不变，新增 Swift 测试未在此 Windows 主机执行，Android
代码不变。没有修改 NAS 协议、存储或权限；回滚仅撤销该解析增量与 Windows 新入口。

- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift`
- Android Adapter：`android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt`
- Windows Adapter：`windows/src/LanStash.Infrastructure/Features/Containers/PrivateApi/DsmRepository.ContainerManager.Private.cs`
- Schema：当前使用各平台强类型领域模型和脱敏合成响应；详情 Schema 尚未建立。
- 脱敏 fixture：`contracts/request-fixtures/container-manager/`
- Android 自动化测试：`ContainerMutationResultTest.kt`、`ContainerRegistryRepositoryTest.kt`、`ContainerWriteSafetyTest.kt`、`ContainerReadOnlyScreenTest.kt`
- 产品兼容矩阵条目：`docs/compatibility/DSM_COMPATIBILITY_MATRIX.md` 的 Container Manager 行。

## 安全与副作用

- 会读取的数据类别：资源名称、状态、映像元数据和 Registry 公共信息；详情候选可能涉及环境变量、挂载路径、进程与日志正文，因此默认关闭。
- 可能产生的副作用：生命周期、删除、创建、拉取、更新、清理和项目操作均可能改变服务或数据。
- 所需权限：由 NAS 最终裁决；客户端不推断管理员权限。
- Android 当前写操作：界面不展示入口，ViewModel 与 Repository 双重拒绝，自动化确认不产生读取或写入请求。
- 后续重复提交保护：只有通过行为验证并重新开放后，才可按同一稳定目标和操作在进程内互斥。
- 后续写后结果校验：只有通过行为验证并重新开放后，能回读的操作必须通过列表或详情确认最终状态；无法确认不得报告成功。
- 临时数据清理：不得保存原始 HAR、响应、日志正文、环境变量、路径、Registry 凭据或终端内容。

## 未验证事项

- 容器详情、实时资源、进程、日志流和终端的完整 API 参数、响应 Schema、刷新频率、上限与错误语义。
- Registry 私有凭据、安全存储及登录失败语义。
- `pull_start`、映像更新/清理、容器创建编辑、Compose 校验/部署和异步任务的真实写行为。
- 管理员与普通账号、QuickConnect、弱网、套件升级及大量容器/日志下的行为。

## 2026-10-03 搜索版本与下载失败更正

本次待归属环境 DSM 7.2.1-69057 Update 12 / Container Manager 24.0.2-1535；详见
[观察记录](../environments/2026-10-03-container-image-pull-observation.md)。不改写旧 lab-a verification。

- search 必须固定 Registry v1：本次 v1 返回成功，v2 返回 103；不能跟随 Registry 最高版本。
- 成功结构 data.data 为数组；空数组是空结果，缺失/畸形容器应报告读取失败。
- 用户授权的独立测试下载成功取得字符串 task_id；运行中为原生布尔 finished 与数值 downloaded，current/total 可缺省。
- 同一任务随后以 1202（官方 Docker 未知错误常量）失败，目标标签没有出现、原任务消失。macOS 记住此明确失败，不再将它永久显示为未知进度。传输/暂时查询错误仍保留任务并自动只读恢复；无回执不猜测、不重发。
- 不能从 1202 判断具体网络、权限、空间或仓库故障；界面提供这些检查方向及 Container Manager 详情入口说明，不暴露错误码。
- 未验证成功下载终态；仍要求 task_id/finished/目标匹配/完整清单。搜索 v1 与失败路径证据不外推全部下载场景。

五端影响：共享 Apple 读取适配修正并执行 macOS 回归和 iOS 模拟器构建；macOS 原生恢复/双语 UI 修复；Windows/Android 记录 search 版本及 1202 处理风险，未更改实现。未改变公开模型、存储或权限。
