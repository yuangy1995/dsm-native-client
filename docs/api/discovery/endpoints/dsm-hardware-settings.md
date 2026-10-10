# DSM 硬件与 UPS 设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-hardware-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板硬件与电源 |
| 能力名称 | 断电恢复、指示灯、风扇、提示音、休眠与 UPS 设置 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `high` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Hardware.PowerRecovery`、`SYNO.Core.Hardware.Led.Brightness`、`SYNO.Core.Hardware.FanSpeed`、`SYNO.Core.Hardware.BeepControl`、`SYNO.Core.Hardware.Hibernation`、`SYNO.Core.ExternalDevice.UPS` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

参数：

| API / 方法 | 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- | --- |
| PowerRecovery `get` / `set` | `rc_power_config` | `boolean` | 写入时需要 | 来电后是否自动启动 | `true` |
| Led.Brightness `get` / `get_static_data` | 无 | - | - | 读取当前亮度及设备允许范围 | - |
| Led.Brightness `set_current_brightness` | `led_brightness` | `integer` | 是 | 设置范围内的当前亮度 | `5` |
| Led.Brightness `update` | 无 | - | - | 提交已经设置的亮度 | - |
| FanSpeed `get` / `set` | `dual_fan_speed` | `string` | 写入时需要 | 使用设备支持的稳定风扇模式 | `coolfan` |
| BeepControl `get` / `set` | `fan_fail`、`volume_or_cache_crash` 或 `volume_crash`、`poweron_beep`、`poweroff_beep`、`reset_beep` | `boolean` | 按返回字段 | 故障与电源事件提示音 | 合成布尔值 |
| Hibernation `get` / `set` | `eunit_deep_sleep`、`enable_log`、`sata_deep_sleep`、`ignore_netbios_broadcast`、`auto_poweroff_enable` | `boolean` | 按返回字段 | 外接设备、硬盘与网络唤醒节能设置 | 合成布尔值 |
| UPS `get` / `set` | `enable`、`mode`、`delay_time`、`ups_set_safemode_until_lowbatt`、`shutdown_device`、`net_server_ip`、`snmp_server_ip` | 多类型 | 按模式 | UPS 连接方式与安全关机设置 | `SLAVE`、`120`、`<synthetic-ups-server>` |

客户端只提交当前读取结果中实际变化且可修改的字段。UPS 地址字段明确存在但为空时保留
为可信空值，字段缺失才表示未知；未知原始值不得直接写入新值。蜂鸣器音量故障字段必须沿用设备
返回的 `volume_or_cache_crash` 或 `volume_crash`，不得同时猜测提交。LED 亮度必须先
落在 `get_static_data` 返回范围内，再依次调用设置与更新方法。

## 响应与错误

读取响应分别提供当前开关、亮度范围、风扇模式、提示音字段、休眠字段和 UPS 模式。
保存前按六个逻辑子操作计算差异，保存后重新读取所有可用硬件接口，并逐项比较目标值。

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或所需版本未发现 | 当前设备不支持对应设置 | 否 | 关闭该项写入口，不影响其他硬件信息 |
| 亮度、风扇模式或 UPS 参数无效 | 输入未通过本地预检 | 否 | 保留表单并修正字段 |
| 权限不足 | 当前账号不能修改硬件设置 | 否 | 使用具备系统管理权限的账号 |
| 中途明确拒绝 | 前面的子操作可能已经完成 | 否 | 停止后续提交并整体回读 |
| 提交断网、超时或响应无效 | 当前子操作结果未知 | 否 | 整体回读；回读失败时不得自动重放 |
| 完整回读只有部分子操作符合 | 部分成功 | 否 | 展示已重新读取的状态并逐项核对 |
| 提交后取消 | 已提交设置可能已经生效 | 否 | 停止后续请求，重新读取全部设置 |
| 同时再次保存 | 重复提交冲突 | 否 | 等待当前保存结束 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `read-verified` | v1 | 当前读取结构已核对；写入只完成合成请求、部分成功、断网和取消测试，未执行真实写行为验收 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

## 能力探测与降级

- 启用条件：预检成功读取当前值，并一次性确认所有实际变化所需 API 的 v1 能力。
- macOS 本轮按用户明确授权提供测试入口，以实际接口版本、权限、输入、确认、防重复和结果核查判断可用性，不仅因未实测固定关闭。新 DSM build 的真实行为仍待验证；其他平台以其最新授权和实施状态为准。
- 接口缺失：只隐藏依赖该接口的字段，不阻断其他硬件设置读取。
- 字段缺失或类型变化：不提交客户端猜测值；音量故障字段无法识别时保持只读。
- 权限不足：不提升权限、不切换账号、不继续后续子操作。
- 网络失败：提交前失败可在恢复后重试；提交开始后必须先整体回读，不自动再次保存。
- 替代的官方 API：当前项目未找到覆盖这些 DSM 硬件设置的公开 API。
- 功能开关：NAS 设置模块开关、运行时能力发现和当前环境兼容记录共同控制。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- Android Adapter：`DsmRepository`、`AppViewModel` 与 `NasHardwareSettingsScreen`；六组设置使用原始/目标双基线、固定 v1 能力与字段可信预检、共享 NAS 设置原子门闩、逐步取消检查、整体回读、持久结果和专项刷新，部分成功与未知结果不得清除后重放。
- Windows Adapter：已接六组 v1 读取、LED 设备范围、蜂鸣器真实字段名和 UPS 可信空值，
  原生编辑支持局部失败/恢复。旧聚合 Hardware 和猜测写路径已移除；六组基线保存、
  LED 设置/更新、可信字段预检和整体回读已有源码/合成证据，生产行为门独立关闭。
  LED 阶段未知不重发，也不凭暂存亮度匹配宣称物理更新完成。
- Schema：复用 `MutationResult` 与请求 Fixture Schema。
- 脱敏 Fixture：
  - `contracts/request-fixtures/hardware/set-power-recovery/synthetic-settings/request.json`
  - `contracts/request-fixtures/hardware/set-led-brightness/synthetic-settings/request.json`
  - `contracts/request-fixtures/hardware/set-fan-mode/synthetic-settings/request.json`
  - `contracts/request-fixtures/hardware/set-beep/synthetic-settings/request.json`
  - `contracts/request-fixtures/hardware/set-hibernation/synthetic-settings/request.json`
  - `contracts/request-fixtures/hardware/set-ups/synthetic-settings/request.json`
- Apple 自动化测试覆盖六段确认成功、中途超时后的部分成功、提交断网且回读失败、重复提交和提交后取消；Android 本批 9 项正式 Repository 测试覆盖六组请求/版本、完整多步骤计数、部分成功、在途取消、UPS 缺字段零写入和可信空地址写入，8 项状态策略和 6 项界面策略覆盖草稿规范化、刷新门禁与结果关闭策略；API 35 安全/硬件专项设备测试覆盖确认、持久反馈、五态、48dp 整行交互和深色 2× 字体。
- 产品兼容矩阵条目：`NAS 设置`、`统一写操作结果 MR0/MR1/MR2`。

## 安全与副作用

- 会读取的数据类别：设备硬件开关、灯光、散热、提示音、休眠和 UPS 设置。
- 可能产生的副作用：改变来电启动、设备灯光、散热噪声、提示音、休眠唤醒和安全关机
  行为；错误设置可能影响可用性或硬件温度。
- 所需权限：由 DSM 返回的能力和当前会话权限决定。
- 重复提交保护：Repository 和 macOS/Android 模型均阻止并发硬件设置保存。
- 写后结果校验：按六个稳定逻辑子操作整体回读并计数；部分成功与未知结果不得重放。
- 临时数据清理：不生成 HAR、响应转储、真实网络地址或含设备信息的 Fixture。

## 未验证事项

- 当前环境未在专用测试目标完成断电恢复、亮度、风扇、提示音、休眠、UPS、权限不足、
  中途断网及物理设备副作用验收。
- LED `update` 生效时序、不同机型风扇模式、蜂鸣器字段和 UPS 模式差异尚未跨设备验证。
- Windows 六组保存核心与原生编辑有合成证据，真实物理副作用尚未验收；iPhone/iPad
  M6c2 已接管理调用链，当前验证见移动主计划。Android 仍待真实设备、真实 DSM 和硬件矩阵验收，本波不提升证据。

## 2026-10-06 Apple 移动硬件管理与 LED 恢复

没有新增或猜测接口，六组请求继续使用已记录的 v1。移动入口复用 `NasServiceChange` 和
旧硬件请求编码；读取严格保留可选布尔、整数、范围、设备风扇模式与 UPS 空字符串。
UPS 字段缺失不同于明确空地址；蜂鸣故障写沿当前响应的真实字段。原配置和支持范围在
每个写前重新读取，全部变化一次预检；每组保存分别检查管理员权限并持久记录请求边界。

LED 拆成 `set_current_brightness` 和 `update` 两个独立边界，共七个请求步骤。两个步骤
各自缺少接受回执时均保持未知，不能仅凭 `get` 的暂存亮度宣称应用完成；持久恢复也执行
同样规则。只有原记录中亮度已接受且回读匹配、应用步骤明确未提交或拒绝时，才允许用户
主动继续应用原亮度；不会重发亮度设置。成功的 `update` 回执及亮度回读是客户端可核查
的范围，不能替代物理指示灯的实际生效验收。

共享旧调用保持六个逻辑组计数，但只核对已提交范围；明确拒绝、未执行的后组和未取得
完整两步回执的 LED 不会被当前相同值覆盖。Mac 模型同样不再以页面相等覆盖保存结果。
新增五项基线测试在修正前有 16 条失败断言，修正后的硬件相关 21 项通过；随后共享完整
2954 项 XCTest（172 条既有跳过）及 12 项 Swift Testing 通过。移动与 Mac 构建、实际 UI
和详细设备待办以[移动 M6c2 账本](../../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#2026-10-06-m6c2-硬件与-ups-设置)为准。

五端影响：macOS 使用修正后的旧入口；iPhone/iPad 使用新增管理入口与同一受保护摘要
记录，UPS 地址和配置正文不落盘；Windows/Android 仅登记这一结果核查语义，未修改源码、
身份、权限、存储或最低系统版本。请求契约和已有环境证据等级不变，未执行真实硬件写入。

## 2026-10-03 官方页面差异修正

在本轮待归属 DSM 7.2.1-69057 U12 成功读取中，BeepControl 的
`support_fan_fail/support_volume_crash/support_poweron_beep/support_poweroff_beep/support_reset_beep`
为 Boolean。支持位为 false 时，返回当前值也不意味着该设备允许编辑；Apple 只展示
支持项，并在写前重新确认对应字段仍可用。缺失支持位保留旧契约兼容，不捏造 false。

FanSpeed 的 `cool_fan` 与 `fan_type` 决定可选模式。官方前端位标记为高=1、低=2、
低速停转=4、全速=8；`yes` 按位提供 coolfan/quietfan/quietstop/fullfan，`single`
仅 quietfan/fullfan，`no` 使用 highfan/lowfan。未知模式保留当前读值，不新增猜测写值。
本轮修正以前显示所有模式的问题；风扇提交前按新快照允许集校验。扩展网卡对风扇最低
档位的附加限制仍需目标硬件验证，由 NAS 保留最终拒绝权限。

UPS 无对应硬件，本轮仅核对官方页面；没有保存配置。休眠文案按高级休眠含义修正。
测试为合成响应、零写入拒绝和 macOS UI 回归，不提升真实写行为等级。五端中只有
macOS/共享 Apple 实施；Windows、Android、iPhone、iPad 后续适配应遵守相同支持位与模式语义。
