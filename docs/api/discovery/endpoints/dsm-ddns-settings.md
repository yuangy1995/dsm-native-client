# DSM DDNS 设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-ddns-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板外部访问与 DDNS |
| 能力名称 | 服务商列表、连接测试、记录保存、地址更新与删除 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.DDNS.Provider`、`SYNO.Core.DDNS.Record` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| API 与方法 | 参数 | 类型 | 必需 | 含义 | 合成示例 |
| --- | --- | --- | --- | --- | --- |
| `Provider.list` | 无 | - | - | 读取可用服务商和字段要求 | - |
| `Record.list` | 无 | - | - | 读取已有 DDNS 记录 | - |
| `Record.test` | 记录字段 | 混合 | 是 | 仅测试当前服务商、主机名和凭据组合 | 合成域名与脱敏凭据 |
| `Record.create` | 记录字段 | 混合 | 新建时 | 新建记录 | 合成域名与脱敏凭据 |
| `Record.set` | 记录字段 | 混合 | 编辑时 | 更新已有记录 | 合成域名与脱敏凭据 |
| `Record.update_ip_address` | 无 | - | - | 请求 DSM 立即更新当前记录地址 | - |
| `Record.delete` | `id` | `stringArray` | 是 | 删除指定服务商记录 | `["Example"]` |

记录字段包括 `provider`、`hostname`、`username`、`passwd`、`enable`、`heartbeat`、
`net`、`ip`、`ipv6`、`interface_v4` 和 `interface_v6`。客户端只在当前连接测试或保存
请求中持有密码或密钥；请求 Fixture 只记录字段存在且标记为脱敏，不保存凭据值。

## 独立操作、结果与恢复

连接测试、记录保存、立即更新和删除是四个独立副作用边界：

1. 连接测试只调用 `Record.test`，不会创建、编辑、立即更新或删除记录。
2. 保存只调用一次 `Record.create` 或 `Record.set`，随后重新列出记录并按服务商、
   主机名、账号、启用状态和心跳设置逐字段核对。
3. 立即更新只调用一次 `Record.update_ip_address`，随后确认记录列表仍可重新读取。
4. 删除只调用一次 `Record.delete`，随后确认目标服务商记录已经从列表消失。

测试成功只说明 DSM 接受当前测试请求，不代表记录已经保存。立即更新返回成功并重新
载入列表，只说明 DSM 接受更新请求且列表仍可读取，不证明公网 DNS 已完成传播，也不
证明公共解析器已经收敛到 NAS 当前地址。

| 场景 | 结果语义 | 恢复方式 |
| --- | --- | --- |
| 服务商、主机名、账号或必需密码无效 | 提交前确认失败 | 修正输入 |
| API 未发现或版本不足 | 不支持 | 不发送读取或写请求 |
| 权限不足 | 权限拒绝 | 使用具备外部访问设置权限的账号 |
| 同服务商正在测试、保存或删除 | 重复提交冲突 | 等待当前操作结束 |
| 立即更新与其他 DDNS 写操作重叠 | 重复提交冲突 | 等待当前操作结束 |
| 测试明确成功或失败 | 仅报告测试结果 | 用户另行决定是否保存 |
| 保存后记录逐字段匹配 | 确认成功 | 使用回读列表刷新界面 |
| 删除后目标记录消失 | 确认成功 | 使用回读列表刷新界面 |
| 保存或删除超时，但单次回读确认目标状态 | 确认成功 | 不重放请求 |
| 保存、删除或立即更新结果无法确认 | 已提交结果未确认 | 恢复连接后重新读取，不自动重放 |
| 提交后取消 | 已提交结果未确认 | 重新读取记录后再决定 |

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 能力范围、读取结构和网页请求已有记录；写入只完成源码审查、合成请求、故障注入与模型测试，未执行真实 DDNS 写行为 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成 Fixture 与源码测试只证明客户端请求参数、操作隔离和恢复语义稳定，不将当前环境
提升为 `behavior-verified`。

## 能力探测与降级

- `Provider` 或 `Record` v1 未发现时，不读取或提交 DDNS 设置。
- 服务商不存在、编辑目标不存在或新建时目标已存在均在提交前拒绝。
- 新 DSM build 或未记录版本上的内部写入口默认保持关闭，直至完成版本化验证。
- 保存和删除遇到可能已经提交的超时或断线时只回读一次，不重放写请求。
- 立即更新没有可证明公网 DNS 传播结果的状态字段，未知结果不得自动重放。
- DDNS 操作失败不阻断文件、照片、消息或其他 NAS 设置。
- 当前项目未找到覆盖这些控制面板能力的统一公开写 API。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- Android Adapter：`DsmRepository` 的 `testDdnsResult`、`saveDdnsResult(original, desired)`、`deleteDdnsResult(original)` 与 `refreshDdnsResult(expectedProviderIds)`；四类操作保持独立，固定使用 Provider/Record v1。Provider/Record 根、对象项、稳定身份与重复项均严格校验；Record 仅要求契约承诺的 `provider/hostname/username/enable/heartbeat`，可选网络字段若出现则严格检查。
- Windows：Provider/Record v1 双能力门与严格记录读取已接，记录身份固定为 provider；
  提供商协议重复项按已记录行为归并并保留友好显示名，记录重复则失败。可选网络字段
  保留未知/空值，返回密码不进入模型；读取与写权限分离，原生只读入口已接线。
  四种独立操作核心已迁移并接入共享 NAS 写协调器：确认快照/目录基线、固定请求 ID、
  环境门、提交前双能力与目录校验、单次发送和回读。密码只传入当次调用，不进入共享
  恢复状态或指纹；原生四类编辑/确认/反馈/只读恢复入口已接，生产门关闭。
  确认绑定当前草稿/目标/目录和临时密码，改变输入即失效；操作期间阻止其他动作，
  关闭/换 NAS 清除密码并隔离迟到结果，测试后的输入变化取消旧测试成功提示。
- iPhone 与 iPad：DDNS 用户调用链尚未迁移。
- 脱敏 Fixture：
  - `contracts/request-fixtures/ddns/test-provider/synthetic-record/request.json`
  - `contracts/request-fixtures/ddns/create-record/synthetic-record/request.json`
  - `contracts/request-fixtures/ddns/update-address/synthetic-record/request.json`
  - `contracts/request-fixtures/ddns/delete-record/synthetic-record/request.json`
- 自动化测试覆盖四类操作隔离、保存/删除超时后的单次回读、结果未确认、无效输入、
  能力缺失、权限反馈、按服务商和全局重复提交保护，以及 macOS 用户反馈；Android
  `DdnsMutationResultTest` 的 24 项合成测试另覆盖双 v1 零请求门禁、严格根/行/重复校验、合法五字段最小响应、四操作隔离、按服务商/全局双向防重复、提交前后取消解锁、陈旧保存/删除基线、模糊提交单次回读不重放和输入边界。Android 另有 9 项状态/策略 JVM 与 10 项 Compose 设备测试覆盖草稿恢复、密码清除、四类确认和持久反馈、专项刷新门禁、目标变化、深色 2× 字体与无障碍语义。

## 安全与副作用

- 保存凭据可能改变 DSM 与外部 DDNS 服务商的认证状态；删除会停止对应记录更新。
- 2026-09-17 Windows 合成复核及 Apple 源码修正：明确拒绝不得被恰好匹配的旧配置
  或其他来源的删除覆盖为成功。仅换凭据且丢失接受响应时，列表不能证明新密码已保存，
  必须报告未确认；不得自动重新测试或重放保存。Windows 此情形维持同会话协调器的
  挂起状态，需通过官方界面人工核对；客户端不提供未经验证的强制解锁入口。
- 测试或立即更新响应丢失时，Windows 缓存该请求的未知结果而不重发；这类瞬时动作
  无法从列表恢复，不占用永久挂起锁。后续新动作必须是用户重新确认的新请求。
- 用户名和密码只用于当前请求，不写入日志、Fixture 或客户端持久化。
- 合成测试请求只使用 `.example.invalid` 域名与合成服务商；Fixture 仍将主机名和凭据
  标记为脱敏，不记录真实域名、公网地址、账号、NAS 地址、会话或完整 DSM 响应。
- 本批次不修改 DNS 服务器、默认网关、防火墙、证书信任或 QuickConnect 设置。

## 未验证事项

- 不同 DSM build、套件版本、权限、服务商和直连/QuickConnect 组合下的真实写入副作用
  尚未验证。
- 服务商特定错误码、频率限制、双因素认证、IPv6 和外部地址探测差异尚未收集。
- `update_ip_address` 被接受后的公网 DNS 传播时间与公共解析器收敛没有权威状态字段。
- Android 调用链已迁移，但尚未做设备及真实 DSM/服务商写行为验收；Windows 已有
  读取、四操作核心及原生调用链合成证据；iPhone 与 iPad 用户调用链尚未迁移。
- Apple 共享层新增明确拒绝与仅换密码超时回归，当前 Windows 环境无 Swift，测试未运行；
  Mac 界面层也移除凭旧列表把拒绝/未知转为成功的覆盖，并补对应模型回归。
  macOS/iPhone/iPad 构建和回归为 PENDING_USER_VALIDATION。Android 不修改源码，需后续
  核查相同错误映射；本次没有改变请求字段或现有真实环境证据等级。
