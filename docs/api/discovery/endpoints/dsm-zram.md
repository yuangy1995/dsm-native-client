# DSM 内存压缩（ZRAM）内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-zram` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板 |
| 能力名称 | 内存压缩只读摘要和设置关闭边界 |
| 分类 | `internal` |
| 操作性质 | `mixed`（当前客户端仅 `read`） |
| 风险等级 | `high`（来自尚未启用的 `set`） |

## 范围与证据边界

本记录覆盖 DSM 控制面板“硬件和电源”中的内存压缩只读摘要。静态 API 目录显示
`SYNO.Core.Hardware.ZRAM` 提供 `get` / `set`；2026-08-03 在已登录的官方 DSM
页面中只读观察到“内存压缩”设置控件存在，但没有捕获或保存对应网络请求、响应或
任何会话数据。因此 API 版本、路径、参数和响应结构仍是 `static` 候选，不能表述为
当前 DSM build 已经 `read-verified`。

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Hardware.ZRAM` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| 客户端版本范围 | 保守接受运行时发现的 v1 |
| 只读方法 | `get` |
| 写方法 | `set`，当前关闭 |
| `get` 参数 | 无 |
| 鉴权 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | 真实请求未捕获，当前环境未验证 |

客户端不会猜测不存在的版本、路径或参数；能力缺失，或发现范围不包含 v1 时，页面
独立不可用并保持零请求。

## 响应与错误

当前没有真实脱敏响应。客户端只按 DSM 通用响应外壳读取 `success` / `data`，再从
`data` 中应用下述字段白名单；实际容器、必需字段和错误码均为未验证。

| 场景 | 已知程度 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 未发现或不含 v1 | 客户端可确定 | 否 | 页面独立不可用，零请求 |
| 无权限 | 真实错误码未验证 | 否 | 显示通俗错误，不猜测管理员权限 |
| 网络失败 | 通用传输错误 | 是 | 保留其他 NAS 设置页面，允许手动刷新 |
| 字段缺失或类型变化 | 合成响应已覆盖 | 读取可重试 | 单字段降级为不可用/未知，不读取未知字段 |
| `set` | 参数和错误均未验证 | 否 | 客户端无入口，不发送请求 |

## 只读字段白名单

领域模型只保留以下三类摘要：

- 启用状态：`enable`、`enabled` 或 `zram_enable`；
- 配置容量：只接受单位明确为字节的 `configured_bytes`、`capacity_bytes` 或
  `size_bytes`，负值和单位不明确的 `size` / `capacity` 不采信；
- 压缩算法：`algorithm`、`compression_algorithm` 或 `compressor`，只归一为
  `lz4`（含 `lz4hc`）、`lzo`（含 `lzo-rle` / `lzorle`）、`zstd` 或未知。

内核参数、交换设备名称、设备路径、命令、进程、账号、网络地址及未知字段不会进入
领域模型，也不会出现在默认界面。

2026-09-17 Windows/Apple 字段读取补充：启用状态仅接受原生 Boolean；容量只接受
非负整数，不截断小数；同义字段冲突保持未知，非对象 data 为错误。单字段未知
不清空其他可信摘要，全部不可识别时显示无信息，而不是停用或零容量。

## 写操作关闭边界

`set` 会改变内存管理行为，可能影响内存压力、系统响应、服务稳定性和重启后的状态。
当前没有把 `set` 加入 Repository 协议、请求 Fixture 或界面。未来启用前必须取得：

- 对应 DSM build 的版本化参数、字段类型和权限错误；
- 修改是否即时生效、是否要求重启、内存压力和回滚语义；
- 提交前权限与当前状态预检、明确确认和全局防重复提交；
- 提交异常时禁止自动重放，并通过最终 `get` 回读确认结果；
- 专用测试环境中的故障注入、服务稳定性与重启后状态验证。

## 客户端与界面

- Apple 领域：`NasZRAMSnapshot`、`NasZRAMAlgorithm`；
- Apple Adapter：`DsmNasAdministrationRepository.loadZRAM()`；
- macOS：NAS 设置中的“内存压缩”只读页，显示启用状态、明确字节容量和受限算法，
  支持手动刷新以及加载、空内容、错误和正常状态；该标量页面没有筛选场景；
- Windows：已接固定 v1 读取、标量状态/空信息/错误/不可用与双语只读原生页面，
  只有合成证据，没有 set 方法或开关。
- iPhone、iPad、Android：本波不迁移页面，Apple 移动需回归共享严格读取修正。

界面没有开关、保存或其他写入口，并提示需要修改时前往 DSM。状态同时使用文字与系统
图标，不依赖颜色；中英文用户可见文案均通过语言资源提供。

## 能力探测与降级

- 启用条件：`SYNO.API.Info` 返回该 API，且服务端范围与客户端 v1 相交；
- 新版本默认行为：只协商共同支持的 v1，不因服务端暴露更高版本而猜测升级；
- 接口缺失：页面独立不可用且零请求，不阻断其他 NAS 设置；
- 字段缺失或类型变化：只保留可安全解析的单字段，全部缺失时显示空状态；
- 权限不足与网络失败：显示可恢复错误并允许手动刷新，不解释为功能已禁用；
- 替代的官方 API：当前未发现满足同一用途的公开 API；
- 功能开关：复用 NAS 设置模块开关，关闭模块后不发起请求；`set` 无功能开关且始终关闭。

## 客户端与测试定位

- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository.swift`；
- Apple 领域：`apple/Packages/DsmCore/Sources/NasAdministration.swift`；
- macOS 模型与界面：`apple/Apps/DsmMac/Sources/NasAdministrationModel.swift`、
  `apple/Apps/DsmMac/Sources/NasAdministrationView.swift`；
- Windows Adapter：`DsmRepository.NasSettings.Zram.cs`；Android 本波未实现；
- Schema：没有保存真实响应，因此没有响应 Schema；机器兼容索引由
  `contracts/schemas/private-api-compatibility.schema.json` 校验；
- 脱敏 fixture：没有真实响应，未创建 fixture；合成响应只存在于正式自动化测试；
- 自动化测试：`apple/Packages/DsmNetwork/Tests/DsmCapabilityDiscoveryTests.swift`、
  `apple/Packages/DsmNetwork/Tests/DsmNasAdministrationRepositoryTests.swift`、
  `apple/Apps/DsmMac/Tests/NasAdministrationModelTests.swift`；
- 产品兼容矩阵：`docs/compatibility/DSM_COMPATIBILITY_MATRIX.md`；
- 机器索引：`contracts/private-api/compatibility.json`。

## 安全与副作用

- 会读取的数据类别：内存压缩启用摘要、明确字节容量和受限算法名称；
- 可能产生的副作用：`get` 预期只读但真实响应未验证；`set` 可能影响内存管理和服务
  稳定性，因此关闭；
- 所需权限：真实权限类别与错误码未验证，客户端不推断；
- 重复提交保护：当前无写请求；未来 `set` 必须全局防重复；
- 写后结果校验：当前不适用；未来必须通过最终 `get` 回读；
- 临时数据清理：没有保存 HAR、响应、截图或浏览器导出；构建产物在本批结束前清理。

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 在同一匿名设备补充观察到官方设置控件；当日未重新核实版本，API 请求、响应和写行为未捕获或执行 | 2026-08-03 | `docs/api/discovery/environments/2026-07-29-lab-a-dsm-69057-u12.md`、`docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成响应、字段白名单、v1 协商、能力缺失零请求和零 `set` 测试不能把当前环境提升为
`observed`、`read-verified` 或 `behavior-verified`。

## 未验证事项

- 真实 DSM build 的 API 版本、路径、响应容器、字段名、字段类型和权限错误；
- 容量是否始终以字节返回、算法枚举，以及禁用状态下容量与算法字段的行为；
- 不同硬件、内存容量、DSM 更新和普通账号下的可用性；
- `set` 的参数、即时/重启生效、资源影响、取消、超时、回滚和最终状态复查。
