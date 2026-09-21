# DSM 区域与时间设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-region-time-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板区域与时间 |
| 能力名称 | 日期格式、时间格式、时区、手动时间与网络校时 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Region.NTP` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | `get/set` v3、`listzone` v1、`sync` v2 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| 方法 | 参数 | 类型 | 必需 | 含义 | 合成示例 |
| --- | --- | --- | --- | --- | --- |
| `get` | 无 | - | - | 读取格式、时区、校时模式、服务器和 NAS 当前时间 | - |
| `listzone` | 无 | - | - | 读取可选时区 `zonedata` | - |
| `set` | `date_format` | `string` | 是 | 日期显示格式 | `Y/m/d` |
| `set` | `time_format` | `string` | 是 | 时间显示格式 | `H:i` |
| `set` | `timezone` | `string` | 是 | `listzone` 返回的稳定时区值 | `UTC` |
| `set` | `enable_ntp` | `string` | 是 | `ntp` 或 `manual` | `ntp` |
| `set` | `server` | `string` | 是 | 逗号分隔的时间服务器，最多三个 | `time.example.invalid` |
| `set` | `date/hour/minute/second` | 混合 | 手动模式 | 用户明确选择的 NAS 日期与时间 | 合成日期和数字 |
| `sync` | `servers` | `stringArray` | 网络校时变化时 | 使用已保存的时间服务器立即校时 | `["time.example.invalid"]` |

客户端先规范化格式和服务器，验证目标时区来自刚读取的 `listzone`，并一次性检查 v3
能力。用户没有编辑手动时间时，客户端使用本次预检刚从 NAS 读取的时间，不使用 Mac
当前时间，也不回写页面打开时已经变旧的秒数。

## 提交顺序、结果与恢复

配置保存和立即校时是两个副作用边界：

1. 读取当前配置和时区列表，计算实际变化。
2. 只提交一次 v3 `set`，随后使用 `get` 和 `listzone` 逐字段回读。
3. 只有网络校时模式或服务器发生变化、且配置已经完整确认时，才调用 v2 `sync`。
4. `sync` 返回成功后再次回读配置，确认校时请求没有破坏已保存设置。

`sync` 成功只证明 DSM 接受了立即校时请求且配置仍然存在，不证明 NAS 时钟已经达到
权威时间精度。当前契约没有独立的校时任务标识或权威偏差字段，因此不得把配置回读
冒充时钟精度验证。

| 场景 | 结果语义 | 恢复方式 |
| --- | --- | --- |
| 格式、时区或服务器无效 | 提交前确认失败 | 修正输入 |
| API 未发现或版本不足 | 不支持 | 不发送读取或写请求 |
| 权限不足 | 权限拒绝 | 使用具备区域设置权限的账号 |
| 配置逐字段匹配且无需校时 | 确认成功 | 使用回读值刷新界面 |
| 配置确认且 `sync` 被接受 | 确认成功 | 刷新配置；不声称时钟精度已验证 |
| 只有部分配置字段匹配 | 部分成功或明确失败 | 重新读取全部区域与时间设置 |
| `set` 断网、超时或响应无效 | 结果未知 | 不继续校时，不自动重放，先重新读取 |
| 配置确认后 `sync` 失败或超时 | 部分成功 | 保留已确认配置，重新连接后核对时间 |
| 回读失败或提交后取消 | 已提交结果未确认 | 恢复连接后重新读取 |
| 同时再次保存 | 重复提交冲突 | 等待当前保存结束 |

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 能力范围、读取结构和网页请求已有记录；写入只完成源码审查、合成请求、故障注入与模型测试，未执行真实改时 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成 Fixture 与源码测试只证明客户端请求顺序、参数编码和恢复语义稳定，不将当前环境
提升为 `behavior-verified`。

## 能力探测与降级

- 未发现 `SYNO.Core.Region.NTP` v3 时不读取或提交设置。
- `get` 缺少格式、时区或模式，或 `listzone` 缺少目标时区时视为无效响应。
- 新 DSM build 或未记录版本上的内部写入口默认保持关闭，直至完成版本化验证。
- `set` 开始后的异常必须先回读，禁止自动重放；配置未确认时不得继续 `sync`。
- 区域与时间设置失败不阻断文件、照片、消息或其他 NAS 设置。
- 当前项目未找到覆盖这些控制面板设置的统一公开写 API。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。2026-09-16 读取修复拒绝未知模式与
  当前时区不在列表的响应；保留既有 ntp/manual 及明确布尔文本别名，不再把其他值当成
  manual。缺失、非整数、越界或无效日期不补午夜，新增读/未编辑手动时间零写回归。
  当前 Windows 环境未执行 Swift/macOS 测试，保持待验收。
- Android Adapter：`DsmRepository` 与 `NasRegionSettingsScreen`；具备固定版本、输入/时区预检、全局防重复、配置回读、条件校时、部分成功与未知结果不重放。
- Windows：已接 get v3 / listzone v1、明确模式/时区验证及 NAS 墙上时间；新增基线/
  风险/手动编辑意图的请求、配置保存/回读/条件 sync/复查核心及原生表单。只读恢复不
  重放 set/sync，校时接受不等于精度验证；区域生产行为门独立关闭，未进行真实改时。
- iPhone 与 iPad：共享 Apple 读取修复，但区域设置用户调用链尚未迁移。
- 脱敏 Fixture：
  - `contracts/request-fixtures/region/set-settings/synthetic-settings/request.json`
  - `contracts/request-fixtures/region/synchronize-time/synthetic-servers/request.json`
- Apple 自动化测试覆盖确认成功、配置提交超时、校时超时、无效输入、能力缺失、全局重复提交、提交后取消、未编辑手动时间和 macOS 用户反馈；Android 合成测试覆盖固定版本/参数、未编辑手动时间、配置提交超时、校时超时、非法服务器和非设备时区。

## 安全与副作用

- 修改时区或时间可能使当前会话、OTP、证书判断、计划任务和日志时间发生变化。
- macOS 与 Android 在保存前使用高风险确认；Repository 与模型共同阻止并发保存。
- 请求 Fixture 只使用 `.example.invalid` 合成服务器，不记录真实服务器、NAS 地址、
  会话、时间响应或用户数据。
- 本批次不修改 NTP 服务实现、证书信任、账号、计划任务或网络配置。

## 未验证事项

- 不同 DSM build、权限、直连与 QuickConnect 下的真实写入、会话续期和证书行为未验证。
- 不可达服务器、多个服务器、IPv6 字面值和 DSM 特定错误码尚未收集。
- `sync` 接受后实际时钟收敛时间与偏差没有权威字段，仍需专用测试环境独立测量。
- Windows 读取、set/sync 核心及原生表单有合成证据，生产行为门仍关闭；iPhone 与 iPad 用户调用链未
  迁移。Apple 新解码边界需在 Mac 跑共享回归；Android 未改且仍待设备、真实 DSM 和权限矩阵验收。
