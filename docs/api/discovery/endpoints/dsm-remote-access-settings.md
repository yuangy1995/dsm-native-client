# DSM 远程访问设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-remote-access-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板外部访问 |
| 能力名称 | QuickConnect 中继与路由器自动配置 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

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

## 响应与错误

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

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | QuickConnect v3；Upnp v1 | 读取结构和网页接口线索已记录；写入只完成合成请求、部分成功、断网和取消测试，未执行真实行为验收 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

机器可读兼容记录继续保持 `observed / degraded`。Android 第 55 批的合成请求、故障注入、
领域与 Compose 测试只证明客户端契约和保护逻辑，不提升真实环境证据等级；既有
QuickConnect 登录、隧道建立或 `SYNO.API.Info` 探测证据也不外推为本端点的读取或写入
行为证据。

## 能力探测与降级

- 启用条件：成功读取当前设置，并一次性确认所有实际变化所需 API 与版本。
- 新版本默认行为：未记录的新 DSM build 默认关闭内部写入口。
- 接口缺失：只隐藏依赖该接口的开关，不阻断文件浏览或其他 NAS 设置。
- 字段缺失或类型变化：不显示无法确定当前值的开关，也不提交猜测值。
- 权限不足：不提升权限、不切换账号、不继续后续子操作。
- 网络失败：提交前失败可在恢复后重试；提交开始后必须重新连接并回读，不自动保存。
- 替代的官方 API：当前项目未找到覆盖 DSM 控制面板这两项设置的公开 API。
- 功能开关：NAS 设置模块开关、运行时能力发现、连接方式保护和环境兼容记录共同控制。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- Android Adapter：正式 Repository 固定 QuickConnect v3 与 Upnp v1，严格解析 Boolean；
  单项读取失败保留另一项并以 `null` 降级。只有完整匹配已记录 DSM build 与 Update 的
  环境开放写入口，保存仅提交实际变化字段并执行专项回读。
- Windows Adapter：新增固定 v3/v1 独立读取，严格 Boolean，缺失能力与读取失败独立
  标记；认证/取消不降级成成功。保存核心仅对已读可信字段形成变化子操作，整体
  检查方法版本和基线，明确管理员与已登记环境后提交。沿用可信中继主机分类，
  不能用草稿中的可关闭字段绕过当前中继保护。任何一项拒绝/模糊响应立即停止后续
  提交，整体回读仅计算已提交项，未知在同一客户端跨 Repository 保留且不重放。
  原生表单已接入独立字段状态、中继保护、变化确认、结果计数和未知恢复；未知时
  明示显示最后读取值并锁定保存，确认/提交前同步控件值。生产行为门保持关闭，
  Windows 核心和原生合成测试不提升真实证据。
- Apple 同类修正：固定 Upnp v1、严格布尔并独立读取；已知认证、取消和证书错误
  不吞掉。当前值未知的字段不提交猜测值。回读不会把明确拒绝或未提交的项计为
  成功，缺失字段保留未知计数；Mac Model 不再用旧缓存覆盖未知/拒绝结果。新增
  5 项共享/App 测试方法未在 Mac 运行，不能记作目标平台通过。
- Schema：复用 `MutationResult` 与请求 Fixture Schema。
- 脱敏 Fixture：
  - `contracts/request-fixtures/network/set-relay/synthetic-setting/request.json`
  - `contracts/request-fixtures/network/set-router-configuration/synthetic-setting/request.json`
- 自动化测试：第 55 批远程访问专项共 36 项 JVM 与 12 项 Compose 测试，覆盖单字段与
  双字段计数、严格 Boolean/缺失字段、环境门禁、可信中继保护、两项确认成功、中途
  超时后的部分成功、提交断网且回读失败、Repository 重复提交、提交后取消、不重放、
  持久结果反馈、专项刷新门槛、迟到回调和切换 NAS 隔离。
- 产品兼容矩阵条目：`NAS 设置`、`统一写操作结果 MR0/MR1/MR2`。

## 安全与副作用

- 会读取的数据类别：QuickConnect 中继和路由器自动配置开关。
- 可能产生的副作用：改变外部访问路径、端口映射或当前可用连接，可能导致连接中断。
- 所需权限：由 DSM 返回的能力和当前会话权限决定。
- 重复提交保护：Repository、Android AppViewModel 和 macOS 模型均阻止并发远程访问
  设置保存。
- 写后结果校验：按两个稳定逻辑子操作整体回读并计数；部分成功与未知结果不得重放。
- 临时数据清理：不记录 QuickConnect ID、主机、外网地址、路由器地址、会话或响应。

## 未验证事项

- 当前环境未在专用测试网络完成中继、路由器自动配置、权限不足、连接切换、中途断网
  和端口映射副作用验收。
- `set_misc_config` 与 Upnp 字段在不同 DSM build、路由器和权限组合中的差异尚未验证。
- Windows 读取、保存核心及原生表单已迁移，真实验证待进行；iPhone、iPad 需回归共享
  Apple 读取/计数修正；Android 本波未改源码，已完成合成契约与界面测试，
  但尚未在真实 NAS 和路由器上执行写操作。
