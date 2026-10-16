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

## 缺失请求字段补全（只读与静态）

[本次观察](../environments/INDEX.md#2026-10-06-container-vmm-api-read-observation) 已从当前官方页面
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
Network.list尚未取得可验证IPv6地址/IP伪装结果的新字段；不能用其他已读字段证明这些选项保存成功。

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

### 生命周期与镜像删除参数静态确认

本节更新上表的“未固化”历史状态，详见[只读观察](../environments/INDEX.md#2026-09-19-container-lifecycle-read-observation)。
DSM 7.2.1-69057 Update 12 / Container Manager 24.0.2-1535；设备归属未确认，不
复用旧 lab-a 行为等级。官方 MainVue.js 静态确认 Container.start/stop/restart v1
均发送 `name`，普通 delete 为 `name,force=false,preserve_profile=false`；重置的
preserve_profile=true 不得冒充删除。Image.delete v1 发送 `images` 对象数组，元素
为 `{repository,tags:[...]}` 或裸映像标识的 `{identity}`，不使用单 id。

Container.list v1 自然请求为 POST entry.cgi、offset=0/limit=-1/type JSON
字符串 all，成功响应含稳定 id/name 及 State 对象。Running/Paused/Restarting 为
布尔，ExitCode 为数字，Status/StartedAt/FinishedAt 为字符串，时间字段呈 ISO
日期格式。请求 ID 与实际名称/时间值不进入记录；重启必须绑定同一容器身份并核对
启动时间变化候选，不能仅以 running 状态回显报成功。尚无真实写行为结论。
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

### 映像列表与下载任务分离

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

### 读取更正（待归属观察）

2026-09-16 [Windows 对齐只读核查](../environments/INDEX.md#2026-09-16-windows-parity-read-observation)
确认当前 Container Manager 24.0.2-1535 的 Container/Log v1 声明 JSON；仅能力元数据
read-verified，不增加当前日志响应或写操作证据。Windows 按本节已有契约同步完整读取与分页。

见[日志与网络观察](../environments/INDEX.md#2026-09-10-container-read-observation)。本次观察未确认设备关系与完整版本，不升级下方历史基线的证据等级。

- `SYNO.Docker.Log.list` v1：官方日志页面发送 `action=load, offset=0, limit=1000, sort_by=time, sort_dir=DESC, loglevel="", filter_content="", datefrom=0, dateto=0`。客户端此前只有 offset/limit，与官方请求不一致。
- 成功响应 `logs` 元素为 `event/level/log_type/time/user`，均为字符串；时间为 `yyyy/MM/dd HH:mm:ss`。顶层 `offset/limit/total` 和分级数量为数字。客户端按返回总数读取后页，不能将首批当作全部。
- `SYNO.Docker.Network.list` v1 无附加参数，返回 `network` 数组；关联容器为 `containers:[string]`，显示数量应取数组长度。缺失数组且没有已支持计数字段时标记分区失败，不冒充零。
- 同一网络响应还包含 `enable_ipv6:boolean` 与 `gateway/iprange/subnet:string`；用户已明确批准为共享领域模型增加向后兼容的可选只读字段，macOS 展开显示子网、网关、IPv6 与关联容器名称，不改请求或存储格式。官方 UI 的 IP 伪装显示未在本次响应中找到对应字段，不按界面文案猜契约。
- 不增加或开放写操作。macOS 修复读取与分区展示；Apple 移动端专用清单、Android、Windows 实现不变，后两端只记录后续适配影响。
- 后续同日核对 `Project.list` v1 无附加参数：官方无项目返回 `{}`，不是空数组；按 ID 键值解析的非空摘要仅有官方脚本静态证据，字段 `name/status/containerIds`。客户端仅对项目分区兼容这一对象容器。
- 网络创建表单和静态参数差异见[观察记录](../environments/INDEX.md#2026-09-10-container-read-observation)。实际创建未发送，不能把只读详情授权或表单可见当成写行为验证。
- 用户后续已批准创建契约同步：默认参数为 `name/enable_ipv6/disable_masquerade`，手动 IPv4 加 `subnet/iprange/gateway`，手动 IPv6 加 `ipv6_subnet/ipv6_iprange/ipv6_gateway`，不传 `driver`。客户端增加确认、校验、同名互斥与读前/读后核对；提交能力默认关闭，只有合成测试显式开启，不升级真实写入证据。五端影响与迁移/回滚见观察记录。
- 用户再次明确要求可点击测试包后，macOS 独立本地测试包允许手动确认并提交创建；正式版默认关闭不变，真实写入仍待用户验收，不将入口开放升级为行为验证。
- 同日用户授权单个无关联测试网络的真实删除：`Network.remove` v1 发送 `networks:[所选网络对象]`，响应 `failed:[]`，最终列表目标消失。对象键及限定证据见[删除观察](../environments/INDEX.md#2026-09-10-container-read-observation)。已纠正 Apple 的单 id 参数及共享请求 fixture；不外推到其他网络、权限、版本或其他写操作。
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
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 未捕获详情请求版本 | 官方页面只读显示总览 CPU/RAM/网络，以及容器详情网络、环境变量、进程和日志分区；未读取内容或原始响应 | 2026-08-02 | `docs/api/discovery/environments/INDEX.md#2026-07-29-lab-a-dsm-69057-u12` |

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

## 搜索版本与下载失败更正

本次待归属环境 DSM 7.2.1-69057 Update 12 / Container Manager 24.0.2-1535；详见
[观察记录](../environments/INDEX.md#2026-10-03-container-image-pull-observation)。不改写旧 lab-a verification。

- search 必须固定 Registry v1：本次 v1 返回成功，v2 返回 103；不能跟随 Registry 最高版本。
- 成功结构 data.data 为数组；空数组是空结果，缺失/畸形容器应报告读取失败。
- 用户授权的独立测试下载成功取得字符串 task_id；运行中为原生布尔 finished 与数值 downloaded，current/total 可缺省。
- 同一任务随后以 1202（官方 Docker 未知错误常量）失败，目标标签没有出现、原任务消失。macOS 记住此明确失败，不再将它永久显示为未知进度。传输/暂时查询错误仍保留任务并自动只读恢复；无回执不猜测、不重发。
- 不能从 1202 判断具体网络、权限、空间或仓库故障；界面提供这些检查方向及 Container Manager 详情入口说明，不暴露错误码。
- 未验证成功下载终态；仍要求 task_id/finished/目标匹配/完整清单。搜索 v1 与失败路径证据不外推全部下载场景。

五端影响：共享 Apple 读取适配修正并执行 macOS 回归和 iOS 模拟器构建；macOS 原生恢复/双语 UI 修复；Windows/Android 记录 search 版本及 1202 处理风险，未更改实现。未改变公开模型、存储或权限。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
