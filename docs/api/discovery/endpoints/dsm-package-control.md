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
| API 版本 | 套件列表与可行性检查 v2；启动、停止与卸载 v1 |
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
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 已核对能力范围、官方网页前端请求线索、合成请求和故障注入测试；本批未在真实 NAS 启动、停止或卸载套件 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

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
- 新 DSM build 或未记录版本上的内部写入口默认保持关闭，直至完成版本化验证。
- 套件控制失败只降级套件管理，不阻断文件、照片、消息或其他 NAS 设置读取。
- 当前项目未找到覆盖 DSM 套件启动、停止与卸载的统一公开 API。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- macOS：启动、停止和卸载均使用原生确认框；操作期间显示进度、禁用同一套件操作并提供
  VoiceOver 标签。
- Android：`DsmRepository.controlPackageResult`、`uninstallPackageResult` 使用用户确认时看到的完整
  `PackageInfo` 基线；写前以固定 Package v2 严格重读并完整比较，启停与卸载写请求固定 v1，
  已发现版本范围不包含所需版本时零请求关闭。严格列表要求唯一 `packages` 数组根、对象行、
  非空且唯一的稳定 ID，以及类型正确的状态、可用操作、`startable` 和 `dsm_apps`；启停专项
  回读不依赖卸载字段，卸载专项回读则要求完整 `install_type` / `ctl_uninstall`。
- Android 三类操作共享稳定套件 ID 互斥，权限字段缺失时失败关闭；明确成功后最多按一秒
  间隔回读十次，模糊提交只回读三次，提交阶段取消执行一次 `NonCancellable` 专项回读，
  均不重放写请求。确认目标、操作类型、确认框、提交结果、专项刷新结果和失败通过持久状态
  保存并提供分级反馈。三类操作均使用原生确认框；该实现不提升真实环境证据等级。
- iPhone 与 iPad：复用领域结果类型，套件控制调用链尚未迁移。
- 2026-09-17 Windows：固定 v2 严格读取及三操作核心已迁移。确认绑定完整可读基线、
  profile/账号/地址与请求 ID，先重读、再 feasibility_check、再专用 v1 写；启动/卸载的
  dsm_apps 必须来自已知列表，停止不发送该字段。旧无基线签名保持 Unsupported，
  移除错误 Package.start/stop/uninstall 和空回读假成功路径。普通摘要及旧工作区共用
  严格读取，旧工作区显式保留失败状态；不把失败当空列表。原生三动作调用链已接：
  本地搜索、目标/动作确认、进度与持续反馈，刷新只核对，不重发。启停与卸载能力分开。
- Windows 恢复摘要从同客户端的按账号/NAS 隔离协调器读取，包含可能已从目录消失
  的卸载目标；新页面先枚举挂起目标再逐项回读，不从当前列表推断先前操作成功。
  确认后的选择/搜索变化会撤销确认；页面关闭或换 NAS 取消旧任务并忽略迟到结果。
  升级只提供非交互提示，没有安装或升级写入口。
- Windows 核心复用现有 NAS 协调器及按目标挂起记录；同请求只返回缓存或只读恢复，
  未知目标不能用新请求 ID 绕过。明确接受最多十次、模糊提交最多三次、间隔一秒；
  提交后取消做一次独立且十五秒超时的回读。明确权限/认证拒绝不被匹配列表覆盖；
  DSM 繁忙与未知错误码只读核对、不重发。生产套件行为门独立关闭。
- Mac 同类修正：缺失 startable/available_operation 不再默认允许启停，未知状态不能
  推断 stopped，status_origin 的 inactive 不能因包含 active 被当作 running；缺失
  安装类型或卸载许可不再默认允许，明确 ctl_uninstall=false 始终阻止卸载。畸形根、
  无稳定 id、重复 id、非对象项及触及 1000 条源边界的列表失败，不伪造卸载成功。
  新增共享 Swift 回归未在当前 Windows 环境运行，不能提升 Mac 验证等级。
- 合成 Fixture（`retryPolicy=queryStateBeforeDecision`、`readbackPolicy=required`）：
  - `contracts/request-fixtures/packages/start/synthetic-package/request.json`
  - `contracts/request-fixtures/packages/stop/synthetic-package/request.json`
  - `contracts/request-fixtures/packages/uninstall/synthetic-package/request.json`
- 自动化测试覆盖请求参数、预检顺序、状态拒绝、能力缺失、提交前取消、写后确认、提交
  超时后回读、明确权限拒绝、完整基线漂移零写入、固定 v2/v1 与最低版本门禁、严格列表
  畸形和权限字段缺失、启停/卸载专项刷新、同 ID 跨动作互斥、提交后取消、禁止重放和
  Model 层持久反馈。第 53 批仓库汇总口径为 JVM 753 项、Android 双语资源完整性 1526 项；
  API 35 仪器测试最终 XML 为 220 项，其中 214 项通过、6 项跳过、0 项失败。

## 安全与副作用

- 停止套件会中断该套件提供的功能和连接；启动也可能触发后台任务和资源占用；卸载还
  可能移除套件设置或数据。界面必须在提交前说明影响并要求确认。
- 请求只使用列表返回的稳定 ID 和 `dsm_apps`，不接受任意用户输入的 API 参数。
- 请求 Fixture 不记录真实套件、NAS 地址、账号、Cookie、SID、SynoToken 或响应。
- 未确认结果不得自动重试，也不得建议用户立即再次执行套件操作。
- 安装和升级仍保持关闭。

## 未验证事项

- 不同 DSM build、管理员/普通账号、依赖套件、套件忙碌、启动失败、停止超时和
  QuickConnect 中继下的真实行为尚未验收。
- 部分套件可能返回过渡状态或需要超过十秒才能稳定，当前没有权威的统一任务 ID。
- 系统套件、依赖链和正在处理存储或备份任务的套件可能有额外拒绝语义。
- Windows 三操作核心和原生调用链已有合成证据；iPhone 与 iPad 用户调用链
  尚未迁移，Apple 共享解析变更仍需三端回归；Android 本波未改，仍待真实 DSM 与设备验收。
- 第 53 批新增的 Android 严格基线、固定版本、权限失败关闭、专项回读和持久反馈均只通过
  合成响应与自动化故障注入验证，真实 NAS 上的启动、停止、卸载和取消行为仍未验证。
