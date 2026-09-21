# DSM 关机与重启内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-power-actions` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 系统电源控制 |
| 能力名称 | NAS 正常关机与重启 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.System` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | 当前客户端使用能力发现选出的版本；合成 Fixture 固定 v3 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| 方法 | 参数 | 类型 | 必需 | 含义 |
| --- | --- | --- | --- | --- |
| `info` | 无 | - | - | 写入前检查当前会话、权限和 API 可达性 |
| `shutdown` | 无 | - | - | 请求 DSM 正常关闭 NAS |
| `reboot` | 无 | - | - | 请求 DSM 重启 NAS |

关机和重启请求没有业务参数。客户端必须先完成一次 `info` 预检，再只发送一次目标电源
请求；预检失败时不得发送 `shutdown` 或 `reboot`。

## 结果语义与不可回读边界

`shutdown` 和 `reboot` 会主动中断当前连接，不能使用同一会话安全回读最终设备状态：

1. `success=true` 只表示 DSM 已接受请求，不表示 NAS 已经完全断电。
2. 重启请求被接受不表示 NAS 已经完成启动、服务恢复或重新上线。
3. 提交阶段超时、断线或取消时，请求可能已经到达 DSM，结果必须标记为未确认。
4. 未确认结果不得自动重放，也不得建议用户立即再次发送；用户应检查设备或等待重新
   连接。

| 场景 | 结果语义 | 恢复方式 |
| --- | --- | --- |
| API 未发现或版本不可用 | 不支持 | 不发送预检或写请求 |
| `info` 权限不足 | 权限拒绝、未提交 | 使用管理员账号重新登录 |
| `info` 会话失效或连接失败 | 提交前确认失败 | 重新登录或恢复连接，确认没有发送电源请求 |
| DSM 明确接受 `shutdown` / `reboot` | 已接受 | 等待连接中断；不声称最终电源状态 |
| 写请求明确权限不足或被拒绝 | 明确失败 | 核对账号权限和设备状态 |
| 写请求超时、断线或响应无效 | 已提交结果未确认 | 检查设备或等待重连，不重放 |
| 提交前取消 | 未提交取消 | 不需要设备状态恢复 |
| 提交阶段取消 | 已提交结果未确认 | 按未知结果处理 |
| 另一项关机或重启正在进行 | 重复提交冲突 | 等待当前操作结束 |

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 当前只完成源码审查、合成请求、故障注入和模型测试；未在真实 NAS 执行关机或重启 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成 Fixture 与源码测试只证明客户端预检顺序、请求方法、结果分类和禁止重放策略稳定，
不将当前环境提升为 `observed`、`read-verified` 或 `behavior-verified`。

## 能力探测与降级

- 未发现 `SYNO.Core.System` 时不显示可用的电源写操作。
- 写入前使用同一 API 的 `info` 检查当前会话与权限；预检通过不替代写方法自身的权限
  检查。
- Repository 和 macOS 模型分别使用全局互斥，关机与重启不得并行提交。
- 新 DSM build 或未记录版本上的内部写入口默认保持关闭，直至完成版本化验证。
- 电源请求失败不改变文件、照片或消息数据，但连接中断后其他请求会自然失败。
- 当前项目未找到覆盖 NAS 关机与重启的统一公开 API。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- macOS：性能概览页保留原生破坏性确认，提交期间显示进度并禁用重复操作。
- Android：`DsmRepository`、`AppViewModel` 与 `NasHardwareSettingsScreen` 已接入预检、全局互斥、不可回读结果、独立二次确认和未知结果不重放；模糊提交以持久核对卡保留，界面与 ViewModel 均拒绝直接清除，必须重新连接并检查 NAS 后才能再次操作。
- Windows：固定 v3 的 info 预检和空参数 shutdown/reboot 已接入原生双重确认；另以
  已记录的 get_user_service 检查版本与明确管理员身份。旧无确认签名保持 Unsupported。
  同客户端按账号/NAS 保存接受或未知结果，不在命令后读取或轮询设备最终状态。
  请求 ID 重复不重放，关机与重启共享挂起门；仅使用不可逆会话摘要辨别新登录，
  不保存 SID。新会话加用户明确检查设备后，才用 info 验证连接并解除本地阻止，
  不把 info 可读当成关机/重启完成。原生入口、迟到响应隔离和关闭取消已有合成证据。
  生产电源行为门独立关闭，原私有未接线嵌套弹窗已移除。
- iPhone 与 iPad：复用领域结果类型，电源动作调用链尚未迁移。
- 合成 Fixture（`readbackPolicy=unavailable`、`retryPolicy=never`）：
  - `contracts/request-fixtures/system-power/shutdown/synthetic-nas/request.json`
  - `contracts/request-fixtures/system-power/reboot/synthetic-nas/request.json`
- 自动化测试覆盖接受结果、能力缺失、预检权限不足、提交后权限拒绝、会话失效、提交
  超时、提交前/提交后取消、Repository 全局防重复、模型防重复、Android 危险结果关闭门禁、
  无可用关闭操作的持久提示和 macOS 用户反馈。

## 安全与副作用

- UI 必须在每次关机或重启前单独二次确认，并说明服务、文件共享和连接会中断。
- 请求 Fixture 使用空业务参数，不记录 NAS 地址、账号、Cookie、SID、SynoToken 或
  真实响应。
- 未确认结果不自动重试；用户明确核对设备状态后才能再次操作。
- 本批次不实现强制断电、Wake-on-LAN、电源日程、UPS 联动或系统更新安装。

## 未验证事项

- 不同 DSM build、权限类别、运行中套件、存储任务和直连/QuickConnect 组合下的真实
  关机与重启行为尚未验证。
- 请求被接受到连接中断、完全关机、重新上线和服务恢复的时间没有权威状态字段。
- 断电恢复、UPS、安全模式和虚拟机运行状态对电源动作的影响尚未实机验收。
- Windows 调用链只有合成证据；iPhone 与 iPad 尚未迁移，Android 仍待设备与专用 NAS 验收。
- Windows 当前保守使用已记录 v3，不推断较低版本可写。新会话检查、用户设备核对、
  实际断线和再次允许操作仍需专用 NAS 验证；未持久化跨进程电源恢复记录。
