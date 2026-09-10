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

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Docker.Container`、`SYNO.Docker.Image`、`SYNO.Docker.Registry`、`SYNO.Docker.Network`、`SYNO.Docker.Project`、`SYNO.Docker.Log`；详情候选另有 `SYNO.Docker.Container.Resource` 与 `SYNO.Docker.Container.Log` |
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
| `Registry.search` | `offset=0`、`limit=50`、`page_size=50` | `integer` | 是 | 固定首批分页 |
| `Registry.search` | `q` | `string` | 是 | 用户输入的仓库查询词 |
| `Registry.tags` | `repo` | `string` | 是 | 仓库稳定名称，不使用翻译文案 |

写入候选只保留既有静态/观察记录，不作为 Android 开放条件：

| API / 方法 | 已知参数 | 当前结论 |
| --- | --- | --- |
| `Image.pull_start` | `repository`、`tag` | 2026-07-27 请求在发送前终止；没有行为验证，入口关闭 |
| 容器、映像、网络、项目其他写方法 | 未在本记录固化 | 必须在专用测试目标重新发现并完成写后复查 |

`Container.Resource.get`、`Container.Log.get/export`、`Container.stats/get_process` 的完整参数和响应尚未获得脱敏请求证据，不得根据方法名猜测。

### 2026-09-10 读取更正（待归属观察）

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

- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift`
- Android Adapter：`android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt`
- Windows Adapter：`windows/src/Dsm.Infrastructure/DsmServiceManagementRepository.cs`
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
