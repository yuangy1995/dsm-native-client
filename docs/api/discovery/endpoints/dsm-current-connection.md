# DSM 当前连接内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-observability` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 资源监控与连接管理 |
| 能力名称 | 当前连接列表与受保护的连接断开 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `high` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.CurrentConnection` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| 方法 / 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- |
| `list.start` / `limit` | `integer` | 是 | 有界分页 | `0` / `500` |
| `list.sort_by` / `sort_direction` | `string` | 是 | 按连接时间倒序 | `time` / `DESC` |
| `kick_connection.service_conn` | `objectArray` | 是 | 非网页连接目标，包含 `pid`、`type`、`who`、`from` | `<synthetic-service-connection>` |
| `kick_connection.http_conn` | `objectArray` | 是 | 网页连接目标，包含 `did`、`descr`、`who`、`from` | `<synthetic-http-connection>` |

网页连接只允许使用列表返回的非空 `did`；其他服务连接只允许使用非空 `pid`。目标必须
来自刚刚重新读取的列表，且 `can_be_kicked=true`。不得由显示文本、列表行号、用户名或
来源地址单独拼接写请求。

## 响应与错误

列表只保留 `pid`、`did`、`who`、`from`、`location`、`protocol`、`type`、`time`、
`descr`、`is_current_connected` 和 `can_be_kicked` 白名单字段。写响应的 `success=true`
只表示请求被接受；必须重新读取列表并确认同一设备或进程标识已经消失。

| 场景 | 错误语义 | 是否自动重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或标识缺失 | 不支持/目标不可确认 | 否 | 保留只读列表，关闭断开入口 |
| `can_be_kicked` 不为真 | 权限或受保护目标 | 否 | 不发送写请求 |
| 当前会话 | 可能使本应用掉线 | 否 | 使用更强确认，说明需重新登录 |
| 权限不足或会话失效 | 明确拒绝 | 否 | 提示使用具备权限的账号或重新登录 |
| 提交后目标消失 | 确认成功 | 不适用 | 更新连接列表 |
| 提交超时、断线或回读失败 | 结果未确认 | 否 | 重新连接并刷新列表后核对 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `read-verified`（仅列表） | v1 | `list` 字段已核对；`kick_connection` 仅有官方网页请求线索和源码/合成测试，本环境未执行写行为 | 2026-07-27 | `docs/api/discovery/environments/INDEX.md` |

列表证据不得提升断开操作的证据等级；连接断开保持“已实现、未实机验证”。

## 能力探测与降级

- 必须发现 `SYNO.Core.CurrentConnection` v1。
- 新 DSM build 在完成版本化写行为验证前，只能依据能力、列表显式许可和用户确认谨慎开放；无法取得完整目标字段时关闭。
- 列表失败仅影响连接页，不阻断文件、照片或其他 NAS 设置。
- 当前没有覆盖 DSM 会话与服务连接统一断开的公开 API。

## 安全与副作用

- 连接数据可能包含账号、来源地址、位置、设备和进程标识，原文不持久化、不遥测、不写日志；移动恢复仅保留不可逆摘要与操作阶段。
- 断开当前会话会让应用失去连接；其他服务连接可能中断文件传输或后台任务。
- 同一设备/进程目标必须防重复；提交异常只回读，不自动重放。
- 写后比较当次原始目标标识，移动重启恢复使用相同字段的不可逆摘要；诊断标签不得包含账号、地址、`did` 或 `pid`。

## 未验证事项

- 管理员/普通账号、当前会话、HTTP/HTTPS 与其他服务连接的真实权限及错误码未验证。
- QuickConnect 中继、目标自然结束、列表延迟和写后断线行为未验证。
- 当前没有专用测试目标授权，因此未通过浏览器或客户端触发真实连接断开。
- Windows 原生管理只有源码和合成证据。大于有界读取范围、
  原始标识缺失/复用、当前会话断开后重登等情况仍需专用 NAS 验证；无法证明目标
  消失时继续保留未知，不提供强制重放入口。Apple 移动端已有管理与持久恢复源码，
  Android 当前实现及验证见下文，五端真实兼容结论均不提升。

## Apple PID 兼容修复

兼容整数与原有文本形式的 `pid`，只对该标识字段执行转换，拒绝小数和越界编号。
其余权限、身份摘要、重复目标、预检与断开回读保持不变。当前连接错误不再误报
为区域与时间错误。来源和现场观察限制见 [本次观察](../environments/INDEX.md#2026-09-26-nas-settings-read-observation)。

2026-09-27 补充：已在当前浏览器成功响应中核对数字 PID，以及文本身份字段和
布尔 `is_current_connected/can_be_kicked`；未执行断开。见
[实测记录](../environments/INDEX.md#2026-09-27-nas-settings-live-validation)。


## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
