# DSM 系统进程与服务进程组内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-processes` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 资源监控 |
| 能力名称 | 系统进程与服务进程组只读摘要 |
| 分类 | `internal` |
| 操作性质 | `read` |
| 风险等级 | `medium` |

## 当前证据与启用边界

静态 API 目录只确认以下方法名：

| API | 方法 | 当前状态 |
| --- | --- | --- |
| `SYNO.Core.System.Process` | `list` | 客户端只读适配已实现，等待真实脱敏响应验证 |
| `SYNO.Core.System.ProcessGroup` | `list` | 可选只读补充，失败时降级 |
| `SYNO.Core.System.ProcessGroup` | `service_info` | 参数、响应与隐私边界未知，保持关闭 |

客户端仅接受运行时 `SYNO.API.Info` 明确返回且包含 v1 的能力。v1 是当前客户端的保守
支持范围，不代表静态证据已经证明所有 DSM build 都提供该版本。能力缺失、仅提供其他
版本或请求失败时，不猜测路径、版本或替代方法。

## 请求契约

进程列表与服务组列表均使用运行时发现的路径和请求格式：

| API / 方法 | 版本 | 参数 |
| --- | ---: | --- |
| `System.Process.list` | v1 | `start=max(0, start)`、`limit=1...500` |
| `System.ProcessGroup.list` | v1 | `start=0`、`limit=1...500` |

macOS 当前从 `start=0` 读取单个最多 500 项的快照，不持续轮询，也不为取得完整列表自动
追加请求。服务端报告总数超过已读取数量，或正好返回 500 项且没有可信总数时，界面明确
提示列表已截断，引导用户使用 DSM 资源监控查看完整信息。

该参数形态目前只有客户端合成请求测试，尚未达到 `observed` 或 `read-verified`。

## 响应白名单

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

## 隐私与写操作边界

领域模型没有命令行、可执行文件路径、工作目录、账号、环境变量、打开文件、监听端口、
来源地址或目标地址字段。即使服务器返回这些内容，Adapter 也不会复制、缓存或展示。
自动化测试使用合成敏感字段确认它们不会出现在结果模型中。

本页面不提供结束进程、发送信号、重启服务、调整优先级或导出原始响应。静态目录也没有
形成任何相关写方法的稳定契约；未来如发现写候选，必须建立独立高风险端点记录、确认、
权限检查、防重复与最终状态复查，不得扩展当前只读接口完成。

## 降级与失败语义

- `System.Process` 缺失或 v1 不在发现范围时，页面显示当前 NAS 不提供该只读能力，且
  不发送猜测请求。
- `System.Process.list` 权限、网络、格式或服务错误只影响系统活动页，不阻断系统概况、
  文件、照片或其他设置。
- `System.ProcessGroup.list` 缺失或失败时保留进程列表，并提示服务组暂不可用。
- 取消请求会继续向上抛出，不转换为部分成功。
- 空列表只在请求成功后显示为空，不把错误解释为“没有进程”。

## 客户端与界面

- Apple 领域：`NasProcessDirectory`、`NasSystemProcess`、`NasProcessGroup`。
- Apple Adapter：`DsmNasAdministrationRepository.loadSystemProcesses(start:limit:)`。
- macOS：NAS 设置中的“系统活动”页，支持本地搜索、手动刷新、只读/隐私说明、截断
  提示、服务组降级提示及加载、空内容、筛选空、错误和正常五种状态。
- iPhone、iPad、Android 与 Windows：尚未迁移该页面。
- 界面没有写按钮，不依赖颜色表达状态；原生列表和按钮保留键盘焦点与 VoiceOver 语义。

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 仅确认 API 与方法名；未保存或提交真实进程响应 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成响应、能力协商、字段白名单、截断、零猜测请求和服务组降级测试不能把当前环境提升为
`read-verified`。

## 未验证事项

- 真实 DSM build 的版本、路径、参数名、分页容器、总数字段和权限错误尚未核对。
- 进程与服务组名称、状态枚举、重启瞬间的重复编号和排序稳定性尚未实机验证。
- `service_info` 的必需参数、返回字段、权限与隐私影响未知，保持关闭。
- 当前页面是单次快照，不宣称实时监控；也不展示尚无单位证据的 CPU 与内存数值。

## 2026-09-26 macOS 兼容候选修复

根据原始开源 Schema 补充 `process[]` 与 `slices[]` 容器；进程的 `command` 仅提取
首个空白前片段的末级名称，参数和目录不进入模型；服务组使用 `unit_name` 标识，
数量可从嵌套 `process[]` 计算。既有 `processes/items` 与 `groups/items` 继续兼容。
读取结果在客户端仍限制最多 500 项，缺失容器报错，服务组异常不阻断进程列表。
来源及当前环境限制见 [本次观察](../environments/2026-09-26-nas-settings-read-observation.md)；
仅有静态结构线索与合成验证，当前 NAS 读取仍为 `PENDING_USER_VALIDATION`。

## 2026-09-27 当前响应核对

在 DSM 7.2.1-69057 Update 12 官方资源监控中，Process.list v1 成功返回
`process[]` 与 `command/pid/status`，ProcessGroup.list v1 成功返回
`slices[]` 与 `unit_name/name/process[]`。上轮兼容候选已得到当前只读响应支持，
未执行进程控制。见 [实测记录](../environments/2026-09-27-nas-settings-live-validation.md)。
