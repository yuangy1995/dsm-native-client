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
- 新版本默认行为：未记录的新 DSM build 默认关闭内部写入口。
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
  用户调用链未迁移。Android 仍待真实设备、真实 DSM 和硬件矩阵验收，本波不提升证据。
