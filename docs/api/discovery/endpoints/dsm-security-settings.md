# DSM 安全防护与防火墙设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-security-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板安全性与防火墙 |
| 能力名称 | 自动封锁、拒绝服务防护、防火墙通知与防火墙开关 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Security.AutoBlock`、`SYNO.Core.Security.DoS`、`SYNO.Core.Security.Firewall`、`SYNO.Core.Security.Firewall.Conf`、`SYNO.Core.Security.Firewall.Profile.Apply` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | DoS 读写 v2；其余 v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

参数：

| API / 方法 | 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- | --- |
| AutoBlock `set` | `enable`、`attempts`、`within_mins`、`expire_day` | 多类型 | 是 | 自动封锁开关、失败次数、统计时间与到期天数 | `true`、`5`、`10`、`7` |
| DoS `get` / `set` | `configs` | `object[]` | 是 | 按网卡标识读取或设置拒绝服务防护 | `eth-synthetic` |
| Firewall.Conf `set` | `enable_port_check` | `boolean` | 是 | 防火墙通知开关 | `true` |
| Firewall `set` | `set_type` | `string` | 关闭时需要 | 使用专用动作关闭防火墙 | `disable` |
| Firewall.Profile.Apply `start` | `name`、`profile_applying` | 多类型 | 开启时需要 | 应用 NAS 已返回的当前防火墙配置档 | `synthetic-profile`、`false` |
| Firewall.Profile.Apply `status` | `task_id` | `string` | 任务轮询需要 | 查询配置档应用任务 | 仅使用运行时返回值，不保存 Fixture |

客户端只提交实际变化的子操作。防火墙配置档名称必须来自同一次预检读取，不能由用户
输入、翻译文案或客户端猜测。

## 响应与错误

读取响应按各接口分别返回自动封锁字段、网卡防护列表、防火墙开关、当前配置档名称和
防火墙通知开关。配置档应用由 `start` 返回任务标识，随后轮询 `status`，最终调用
`stop` 清理已完成的任务上下文。

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或所需版本未发现 | 当前环境不支持对应设置 | 否 | 保持该项只读或隐藏写入口 |
| 权限不足 | 当前账号不能修改安全设置 | 否 | 提示使用具备安全管理权限的账号 |
| 预检失败 | 尚未提交任何设置 | 按错误类型 | 保留编辑内容，恢复连接后重新读取 |
| 中途明确拒绝 | 先前子操作可能已经完成 | 否 | 停止后续提交并回读全部目标字段 |
| 提交断网、超时或响应无效 | 当前子操作结果未知 | 否 | 回读当前状态；回读失败时禁止自动重放 |
| 配置档任务超时或提交后取消 | 防火墙开关结果未知 | 否 | 停止自动轮询，刷新并核对当前状态 |
| 完整回读只有部分字段符合 | 部分成功 | 否 | 显示已重新读取的状态，要求逐项核对 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | DoS v2；其余 v1 | 只读结构和网页请求已有记录；本批次只完成合成请求与故障注入测试，未执行写行为验收 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

## 能力探测与降级

- 启用条件：预检一次性确认所有实际变化所需的 API 与版本，并成功读取当前设置。
- macOS 本轮按用户明确授权提供测试入口，以实际接口版本、权限、输入、确认、防重复和结果核查判断可用性，不仅因未实测固定关闭。新 DSM build 的真实行为仍待验证；其他平台以其最新授权和实施状态为准。
- 接口缺失：只关闭依赖该接口的设置，不阻断文件浏览等主流程。
- 字段缺失或类型变化：不能构造完整当前状态时不提交猜测值。
- 权限不足：不提升权限、不切换账号、不继续后续子操作。
- 网络失败：提交前失败可在恢复后重试；提交开始后必须先回读，不自动再次保存。
- 替代的官方 API：当前项目未找到覆盖这些 DSM 安全设置的公开 API。
- 功能开关：NAS 设置模块开关、运行时能力发现和当前环境兼容记录共同控制。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- Android Adapter：`DsmRepository`、`AppViewModel` 与 `NasSecuritySettingsScreen`；四个子操作使用原始/目标双基线、固定版本能力预检、共享 NAS 设置原子门闩、逐步取消检查、配置档任务轮询/清理、整体回读、持久结果与专项刷新，部分成功和未知结果不得清除后重放。
- Windows Adapter：已接四分区固定读取、DoS 按网卡 configs/重复状态覆盖及原生只读
  入口及四段基线保存/防火墙任务核心，未知值不猜测。所有变化一次预检，中途失败停止
  后续配置；开启使用预检配置档，完成状态后才 stop 清理，未知任务/清理不重发。
  旧 fire-and-forget 假成功已移除，生产行为门独立关闭，源码/合成不等于真实验收。
- Schema：复用 `MutationResult` 与请求 Fixture Schema。
- 脱敏 Fixture：
  - `contracts/request-fixtures/security/set-auto-block/synthetic-settings/request.json`
  - `contracts/request-fixtures/security/set-dos/synthetic-interface/request.json`
  - `contracts/request-fixtures/security/set-port-scan/synthetic-settings/request.json`
  - `contracts/request-fixtures/security/disable-firewall/synthetic-settings/request.json`
  - `contracts/request-fixtures/security/apply-firewall-profile/synthetic-profile/request.json`
- 自动化测试：Apple 覆盖四段确认成功、中途部分成功、提交断网且回读失败、重复提交和提交后取消；Android 本批 7 项正式 Repository 测试覆盖双基线、多步骤计数、第二步在途取消与不可取消整体回读，8 项状态策略和 6 项界面策略覆盖原子门闩、专项刷新、可写字段规范化及结果关闭门禁；API 35 安全/硬件专项设备测试包含五态、确认拒绝、48dp 整行开关和深色 2× 字体。
- 产品兼容矩阵条目：`NAS 设置`、`统一写操作结果 MR0/MR1/MR2`。

## 安全与副作用

- 会读取的数据类别：安全开关、失败次数策略、网卡标识、防火墙状态和配置档显示名称。
- 可能产生的副作用：登录封锁策略改变、网络防护改变、已有连接或新连接被防火墙阻止。
- 所需权限：由 DSM 返回的能力和当前会话权限决定。
- 重复提交保护：Repository 与 macOS/Android 模型均阻止并发安全设置保存。
- 写后结果校验：按四个稳定子操作整体回读并计数；部分成功和未知结果不得自动重放。
- 临时数据清理：不生成 HAR、响应转储、任务标识或含设备信息的 Fixture。

## 未验证事项

- 当前环境未在专用测试目标完成自动封锁、DoS、防火墙通知、防火墙启停、权限不足、
  中途断网、配置档任务超时和回滚行为验收。
- 不同 DSM build 的任务状态字段、接口错误码和防火墙生效时序尚未验证。
- Windows 四段安全写/任务核心与表单有合成回归，真实副作用未验收；iPhone/iPad
  用户调用链见下方 M6b5 增量。Android 仍待真实设备、真实 DSM 和权限矩阵验收，不以本波 Windows
  回归提升其或当前 NAS 的证据等级。

## 2026-10-03 字段语义修正

官方控件 `name=enable_port_check` 绑定 `firewall_enable_port_detect`，当前中文为
“启用防火墙通知”：服务或应用被防火墙阻挡时通知用户并提供解锁选项。该字段不是
防端口扫描。macOS 双语文案已修正；共享模型的历史属性名为保持源码兼容暂不重命名，
不得以属性名推断安全功能。Windows/Android 需在后续 UI 切片同步含义，本轮未修改。
旧 `security/set-port-scan` 样本路径保留作为稳定标识，仅解释更新，不修改传输字段。
macOS 按本轮用户授权保留现有可用写入口，去除仅实测证据不足的产品禁用含义；实际
权限、预检、确认、重复提交与回读不变。没有新增真实安全设置写入证据。

## 2026-10-06 Apple 移动 M6b5 增量

- iPhone/iPad 复用现有服务管理流程，固定 AutoBlock/Firewall/Conf/Profile.Apply v1、DoS v2、Ethernet list v2；只保存变化的四组。管理读取不把缺失期限默认成永不过期，不截断小数或越界次数；DoS 要求完整网卡映射，保留同网卡后返回状态覆盖旧值的已记录语义。
- 用户看到的原配置、网卡 ID 集合和配置档绑定到保存前读取；只读显示名称不参与比较。所有变化所需版本在首次提交前检查，每组再次验证原值、权限和持久记录。配置档不可手填或替换；`enable_port_check` 始终表示防火墙通知。
- `NAS/service-operations-v1.json` 保存设置/账号摘要、逐组阶段及开启防火墙的原任务回执和终态；不保存配置正文、名称或凭据。没有回执不能仅凭开关已开启宣布完成，未提交后组不能被后来状态认领。
- 连续执行期间仅在原任务明确结束后、再次通过权限及取消检查、写入清理边界后调用一次 `stop`。该动作没有任务参数；App 重启或旧流程中断后的恢复只调用原 `status(task_id)` 和配置读取，不尝试全局 `stop`、重新 `start` 或重复清理。原任务成功加原配置匹配才解除保护，任务失败保留失败。旧任务上下文可能仍由 DSM 保留，后续应用的兼容性须在专用环境验证，不能自动清理其他任务。
- Mac 共享任务 helper 同步移除超时盲目清理与清理错误吞掉；权限/证书失败停止请求，未知任务不由配置相同改为成功。Mac 页面模型不再用缓存覆盖明确拒绝、部分或未知结果。旧页面与持久配置保持兼容。
- Windows/Android 本片无源码变化，仅登记完整字段、固定版本和任务边界的影响。共享合成与两端验证以移动主计划/验证历史为准，不提升 `lab-a` 的 `observed` 等级，不新增真实 NAS 写入证据。
