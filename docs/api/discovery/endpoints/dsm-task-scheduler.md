# DSM 任务计划与运行结果内部 API

## 标识与证据范围

端点组：`dsm-administration` 的任务计划切片，组件 `dsm-core`，分类 `internal`，
管理风险 `critical`。本文整理已有 [API 参考 8.5](../../README.md)、
`DsmNasAdministrationRepository` 及其合成测试，不是新的真实 NAS 验证。

## 已记录的只读契约

路径由 SYNO.API.Info 发现；使用 POST 表单封装和既有会话/令牌机制，不记录凭据。

| API / 方法 | 固定版本 | 参数 | 响应 |
| --- | --- | --- | --- |
| SYNO.Core.TaskScheduler.list | 3 | start、limit 整数 | tasks 对象数组；id、name、owner、real_owner、type、action、enable、next_trigger_time、can_run、can_edit |
| SYNO.Core.TaskScheduler.get | 4 | id 整数；可选 real_owner 字符串 | name、owner、real_owner、enable、schedule 对象、extra 对象 |
| TaskScheduler.get 创建模板 | 4 | id=-1、type=script；可选 real_owner | 同详情，使用服务器明确返回的默认值 |
| SYNO.Core.EventScheduler.result_list | 1 | task_name 字符串 | data 直接数组，或 data.results 数组 |
| SYNO.Core.EventScheduler.result_get_file | 1 | task_name、result_id 字符串 | script_in、script_out 可选字符串 |

schedule 白名单为 date_type、week_day、date、repeat_date、monthly_week、hour、minute、
repeat_hour、repeat_min、last_work_hour。extra 白名单为 script、notify_if_error、
notify_mail；不执行返回脚本。运行记录保留 result_id/id、task_name、start_time、
stop_time、exit_info.exit_type/exit_code（或同名顶层字段）、trigger_event。

任务以数字 id 与 real_owner 定位，不能按名称或列表行号伪造身份；结果 ID 必须非空且
属于所选 task_name。未知许可默认关闭，缺失时间不得自动变成零点或每天运行。
缺失/畸形根与真实空列表不同，字段冲突或类型不符不能悄悄丢弃条目。

## 管理操作边界

既有记录规定 TaskScheduler.create/set v4，run/set_enable/delete v3；不能将整个
TaskScheduler 一律升级到 v4。

| v3 命令 | 参数 | 结果边界 |
| --- | --- | --- |
| set_enable | id 整数、可选原始 real_owner、enable 布尔 | 回读相同身份的启用状态，不代表终止正在运行的脚本 |
| run | id 整数、可选原始 real_owner | 接受只表示开始请求，不代表脚本成功；不能以最新历史记录推断本次结果 |
| delete | id 整数、可选原始 real_owner | 完整列表中原数字身份消失才确认；所有者变化不当作删除 |

Windows 四命令核心已接入确认基线、明确管理员与许可检查、固定版本、同目标互斥
及不重放恢复。脚本任务启用/运行还要比对用户预览的 get v4 详情，防止列表不变但
执行代码、用户或计划已变化；启用要求关键计划字段完整。恢复只保存必要任务身份
和结果，不持有脚本或通知内容。运行明确接受后缓存结果；模糊运行不能靠历史记录
自动解除未知状态，需用户在 DSM 核查，客户端不提供强制重放。

create/set v4 保存 name、owner、enable、type=script、schedule 与 extra；编辑额外
发送 id，可选 real_owner 只沿用确认时选择器。schedule 保留服务器既有日期/重复
策略，只编辑 Mac 已提供的 hour/minute/week_day，保留固定 repeat_min_store_config
和 repeat_hour_store_config；未知的可选 date/monthly_week 不补造。extra 为 script、
notify_enable、notify_if_error、notify_mail，通知开关按已记录逻辑由错误通知或邮件
非空推导。脚本和通知值只在当次请求中使用。

保存使用服务器模板与双基线，固定管理员/许可、原身份和执行用户；同目标跨命令互斥。创建候选必须通过get v4完整配置回读，ID/名称存在不能代替脚本、计划、执行用户和通知字段匹配。恢复只保留必要身份及摘要，不存原始脚本；未知只读，不重发。入口按实际能力、参数、权限与安全规则，未实测不产生精确版本白名单，也不宣称真实兼容。

## 安全与未验证事项

Mac 命令模型现先重读列表比对确认任务、许可及执行用户，不再以 owner 代替缺失的
real_owner；启停/删除核对当次成功加载的新列表，失败不使用旧缓存。模糊命令错误
不建议立即重试，运行调用仅表示接受。真实执行结果需按环境记录验证。

Mac 编辑窗口将原始详情快照传回模型；保存前重新核对，保存后用当次列表和详情
逐字段确认，不再凭 ID/名称判断成功。保存开始时复制草稿，保存期间禁用启用开关，
避免界面变化影响已提交值；新增模型回归仍待 Mac 执行。

脚本、通知地址、命令和输出可能含秘密，只在当前读取/窗口使用，不自动执行、不
写入磁盘、日志、遥测或默认 JSON。结果输出只能在用户选择记录后读取，不随列表
预取。失败只影响任务页，不阻断文件、照片或其他 NAS 页面。

尚未验证真实任务、权限、长输出、计划类型和系统管理任务；不因合成读取成功开放
创建、启停、运行或删除。真实写验收必须另行授权专用、可恢复任务，结果仅回传脱敏
步骤与错误；不提供脚本、邮箱、主机、账号、凭据或原始响应。


## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
