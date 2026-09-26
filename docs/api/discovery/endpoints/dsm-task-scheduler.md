# DSM 任务计划与运行结果内部 API

## 标识与证据范围

端点组：`dsm-administration` 的任务计划切片，组件 `dsm-core`，分类 `internal`，
管理风险 `critical`。本文整理已有 [API 参考 8.5](../../DSM_WEB_API_REFERENCE_ZH.md)、
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

Windows 保存核心已接服务器模板/双基线预检、管理员与许可、同目标跨命令互斥、
唯一创建候选与 get v4 完整配置回读。恢复只存配置摘要和必要身份，不存原始脚本。
模糊响应先回读，不重发；ID/名称存在不能代替脚本、计划、执行用户和通知字段匹配。
原生列表/详情/编辑/命令确认和记录输出已接同一 Repository，合成控件场景覆盖确认
失效、未知不重放与敏感详情清除。未知版本与未验证行为的生产入口保持关闭；上述
源码/合成证据不提升真实 NAS 兼容等级。

## 版本与五端影响

既有匿名环境 `lab-a-dsm-7-2-1-69057-u12-20260729` 的 NAS 管理索引记载 TaskScheduler
列表/运行 v3、详情/创建/修改 v4。本文端点细节以现有源码及合成测试作 `static`
证据，不把旧汇总记录外推为本批详情、结果或写行为已验证。

Windows 使用独立只读适配并接入摘要；Mac 是已存在的读取/管理基准，同类严格解析
修正仍需 Mac 回归。iPhone/iPad 需回归共享网络层影响；Android 本波只评估，不修改
源码。没有新增方法、路径或版本，不改变公共网络契约、身份、签名或存储格式。

Windows 新增合成测试覆盖 FORM/JSON 的方法版本和选择器、创建模板、未知字段、
身份与 owner 冲突、畸形/重复结果、直接数组和对象根、空输出、输出隐私、权限/取消
与读取门禁；脚本不会随列表预取。Mac 取消伪造列表 ID、整数截断和关键时间默认值，
详情关键字段不完整时拒绝编辑读取，结果列表错误不当作空记录，EventScheduler 明确
固定 v1；保留现有可选 monthly_week 的兼容空数组，不能外推未验证计划类型可写。

## 安全与未验证事项

Mac 命令模型现先重读列表比对确认任务、许可及执行用户，不再以 owner 代替缺失的
real_owner；启停/删除核对当次成功加载的新列表，失败不使用旧缓存。模糊命令错误
不建议立即重试，运行调用仅表示接受。新增 Mac 回归尚未在目标环境执行。

Mac 编辑窗口将原始详情快照传回模型；保存前重新核对，保存后用当次列表和详情
逐字段确认，不再凭 ID/名称判断成功。保存开始时复制草稿，保存期间禁用启用开关，
避免界面变化影响已提交值；新增模型回归仍待 Mac 执行。

脚本、通知地址、命令和输出可能含秘密，只在当前读取/窗口使用，不自动执行、不
写入磁盘、日志、遥测或默认 JSON。结果输出只能在用户选择记录后读取，不随列表
预取。失败只影响任务页，不阻断文件、照片或其他 NAS 页面。

尚未验证真实任务、权限、长输出、计划类型和系统管理任务；不因合成读取成功开放
创建、启停、运行或删除。真实写验收必须另行授权专用、可恢复任务，结果仅回传脱敏
步骤与错误；不提供脚本、邮箱、主机、账号、凭据或原始响应。

## 2026-09-26 Apple 新建草稿与错误提示修复

新建脚本任务使用现有领域默认值创建本地空白草稿，仍检查 TaskScheduler v4 能力，
执行账号预填当前登录账号；不再用已有任务的必需字段校验阻止打开空白表单。
保存时继续通过既有 create 请求、变更确认、同名预检、防重复和回读链路。
已有任务仍严格读取，不用零点或空脚本替代缺失数据。任务解析错误使用专属双语提示，
不再显示区域与时间错误。真实创建/编辑/执行没有进行，均待用户测试。

2026-09-27 补充：官方页面打开已有脚本任务的 get v4 成功响应中，schedule/extra、
时间整数、monthly_week 数组、week_day 文本及通知布尔字段与当前解析匹配。打开后
取消，未保存/执行。见 [实测记录](../environments/2026-09-27-nas-settings-live-validation.md)。
