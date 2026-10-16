# DSM 套件启动、停止与卸载内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-package-control` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 套件中心 |
| 能力名称 | 已安装套件列表、操作可行性检查、启动、停止与卸载 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `high` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Package`、`SYNO.Core.Package.Control`、`SYNO.Core.Package.Uninstallation` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | 套件列表 v2；可行性检查、启动、停止与卸载 v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| API / 方法 | 参数 | 类型 | 必需 | 含义 |
| --- | --- | --- | --- | --- |
| `Package.list` | `offset`、`limit`、`additional` | 多类型 | 是 | 读取稳定套件 ID、状态、可用操作和桌面应用标识 |
| `Package.feasibility_check` | `type` | `string` | 是 | 启动、停止、卸载分别使用 `start_check`、`stop_check`、`uninstall_check` |
| `Package.feasibility_check` | `packages` | `stringArray` | 是 | 只包含当前目标的稳定套件 ID |
| `Package.Control.start` | `id` | `string` | 是 | 启动目标套件 |
| `Package.Control.start` | `dsm_apps` | `stringArray` | 是 | 使用列表返回的桌面应用标识，不接受用户输入 |
| `Package.Control.stop` | `id` | `string` | 是 | 停止目标套件 |
| `Package.Uninstallation.uninstall` | `id` | `string` | 是 | 卸载目标套件 |
| `Package.Uninstallation.uninstall` | `dsm_apps` | `stringArray` | 是 | 使用列表返回的桌面应用标识，不接受用户输入 |

客户端不得根据界面行号、显示名称或翻译后的状态选择目标。每次启动、停止或卸载都先重新
读取列表，确认稳定套件 ID 仍存在且当前动作明确可用，再执行 `feasibility_check`。卸载还
必须确认套件不是系统类型，并且 `ctl_uninstall=true` 或可用操作包含 `uninstall`；字段缺失
时默认关闭。任何预检失败都不得发送写请求。

## 结果语义与写后回读

1. 同一稳定套件 ID 的启动、停止和卸载共享 Repository 互斥，不能并行提交。
2. 写请求明确成功后最多读取套件列表十次，每次间隔一秒，确认目标达到运行或停止状态。
3. 写请求超时、断线、响应无效或服务繁忙时，不重放原写请求，只读取列表核对；普通
   模糊失败最多核对三次。
4. 提交阶段取消后使用独立的只读任务尝试一次状态核对；无法确认时保留“提交后取消”
   语义。
5. 只有列表确认目标状态后才返回 `confirmedSuccess`。列表仍是旧状态、目标意外消失或
   回读失败时返回 `submittedButUnverified`，要求用户刷新后再决定下一步。

| 场景 | 结果语义 | 恢复方式 |
| --- | --- | --- |
| API 未发现或版本不可用 | 不支持、未提交 | 关闭对应操作入口 |
| 套件不存在或当前状态不允许动作 | 预检失败、未提交 | 刷新列表并核对套件状态 |
| 可行性检查权限不足 | 权限拒绝、未提交 | 使用具备套件管理权限的账号 |
| 写请求明确权限不足或会话失效 | 明确失败 | 重新登录或更换有权限的账号 |
| 写请求后列表确认目标状态 | 确认成功 | 更新界面状态 |
| 写请求超时后列表确认目标状态 | 确认成功 | 不重放写请求 |
| 卸载后列表确认目标消失 | 确认成功 | 更新界面并移除目标 |
| 写请求后无法确认目标状态 | 已提交结果未确认 | 刷新列表，确认前不得再次执行同一动作 |
| 提交前取消 | 未提交取消 | 不需要状态恢复 |
| 提交阶段取消 | 已提交结果未确认 | 先刷新套件列表 |
| 同一套件已有操作 | 重复提交冲突 | 等待当前操作完成 |

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 已核对能力范围、官方网页前端请求线索、合成请求和故障注入测试；本批未在真实 NAS 启动、停止或卸载套件 | 2026-07-31 | `docs/api/discovery/environments/INDEX.md` |

合成 Fixture 与源码测试只能证明客户端请求形态、预检顺序、互斥、回读和禁止重放策略，
不能把当前环境提升为 `behavior-verified`。

## 能力探测与降级

- 启停必须同时发现 `SYNO.Core.Package` 和 `SYNO.Core.Package.Control`；卸载必须同时发现
  `SYNO.Core.Package` 和 `SYNO.Core.Package.Uninstallation`，缺少任一所需能力时关闭对应入口。
- 列表字段缺失、目标不存在或无法判断 `canStart` / `canStop` / `canUninstall` 时禁止写入，
  不猜测套件状态或卸载许可。
- Android 普通套件快照在 `startable`、`available_operation` 或卸载类型缺失时默认关闭对应
  操作；读取失败将 `packagesAvailable` 标记为不可用，不把失败折叠成可信空列表。
- `feasibility_check` 是提交前的必要条件，但不替代目标写方法自身的权限判断。
- macOS 按用户明确授权提供测试入口，以实际接口版本、权限、输入、确认、防重复和结果核查判断可用性，不仅因未实测固定关闭。新 DSM build 的真实行为仍待验证；其他平台以其最新授权和实施状态为准。
- 套件控制失败只降级套件管理，不阻断文件、照片、消息或其他 NAS 设置读取。
- 当前项目未找到覆盖 DSM 套件启动、停止与卸载的统一公开 API。

## 安全与副作用

- 停止套件会中断该套件提供的功能和连接；启动也可能触发后台任务和资源占用；卸载还
  可能移除套件设置或数据。界面必须在提交前说明影响并要求确认。
- 请求只使用列表返回的稳定 ID 和 `dsm_apps`，不接受任意用户输入的 API 参数。
- 请求 Fixture 不记录真实套件、NAS 地址、账号、Cookie、SID、SynoToken 或响应。
- 未确认结果不得自动重试，也不得建议用户立即再次执行套件操作。
- 此历史切片未实现安装和升级；2026-10-03 macOS 新流程见独立套件中心记录，其他平台未在迁移。

## 未验证事项

- 不同 DSM build、管理员/普通账号、依赖套件、套件忙碌、启动失败、停止超时和
  QuickConnect 中继下的真实行为尚未验收。
- 部分套件可能返回过渡状态或需要超过十秒才能稳定，当前没有权威的统一任务 ID。
- 系统套件、依赖链和正在处理存储或备份任务的套件可能有额外拒绝语义。
- 套件控制源码与合成结果不等于目标设备或真实DSM副作用已验收；平台状态统一见平台矩阵。
- 第 53 批新增的 Android 严格基线、固定版本、权限失败关闭、专项回读和持久反馈均只通过
  合成响应与自动化故障注入验证，真实 NAS 上的启动、停止、卸载和取消行为仍未验证。

## 可用操作对象与安装互斥

官方成功响应中 `additional.available_operation` 是对象，`upgrade` 是目录候选对象，
不应作为启停许可数组读取。macOS 对对象响应使用状态和 `startable` 判定启停，
`ctl_uninstall/install_type` 判定卸载；历史数组保留明确操作限制。安装/更新进入
[独立安装计划](dsm-package-installation.md)，不用旧 controlPackage(.upgrade) 绕过预检。
安装、下载或未确认任务存在时，Repository 和模型都拒绝同时启停/卸载。其他平台
未修改，需同步对象形态及全局安装互斥；没有新的真实套件控制写入证据。

另将可行性检查固定为官方前端使用的 v1；`system_hidden` 与 `system` 一样不能由普通卸载入口删除。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。

## 套件图标读取

`SYNO.Core.Package.Thumb` 为内部API；只有能力明确覆盖v1才调用get，参数name=套件ID、ver=已安装版本、size=请求尺寸。返回二进制图像只保留内存，失败降级占位，不阻断套件清单；会话仅Cookie/请求头，不进入URL。当前调用可在`apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+Packages.swift`及`android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt`的packageIcon核对。这里只确认现行源码形态，未增加真实版本验证。
