# 请求契约与写操作结果模型实施计划

## 1. 目标与当前基线

本计划解决两类风险：

1. 网络层重构后仍能证明 API 名称、方法、版本、CGI 路径、HTTP 方法、参数编码、
   认证材料位置和重试策略没有漂移。
2. 写请求超时、任务异步执行或批量部分成功时，五端使用一致语义，避免把“结果未知”
   显示为“失败”并诱导用户立即重复提交。

仓库已经建立请求 Fixture Schema、跨模块请求快照、统一写操作结果类型、隐私扫描和
多端校验流程；当前状态、数量和云端门禁以[当前开发进度](../progress/STATUS.md)
记录的同一源码版本为准。本计划继续维护设计原则、迁移边界和后续扩展，不根据名称
推测 DSM 请求。

## 2. 请求契约设计

当前请求 Fixture 目录按模块滚动扩展，典型布局为：

```text
contracts/request-fixtures/
  authentication/
  file-station/
  users/
  groups/
  permissions/
  packages/
  container-manager/
  vmm/
  network/
  storage/
```

每个 Fixture 使用完全合成的参数，并记录：

| 字段 | 说明 |
| --- | --- |
| `fixtureId` | 不含设备、账号或路径信息的稳定标识 |
| `apiName`、`method` | DSM API 与方法 |
| `preferredVersion`、`resolvedVersion` | 客户端偏好与能力发现后的实际版本 |
| `resolvedPath` | 规范化后的 CGI 相对路径，不含主机 |
| `httpMethod`、`requestFormat` | HTTP 与参数编码方式 |
| `parameterNames`、`encodedParameters` | 参数集合和合成编码结果 |
| `requiresAuthentication` | 是否需要会话 |
| `requiresSynoToken` | 是否要求 SynoToken |
| `retryPolicy` | 不重试、只读可重试或查询状态后决定 |
| `risk` | 只读、普通写入、高风险或破坏性 |
| `readbackPolicy` | 无需回读、必须回读、异步任务轮询或客观无法回读 |

`parameters` 必须是数组，但允许合法的无业务参数方法使用空数组；API、方法、版本和
认证字段仍由同一 Fixture 固定，客户端测试继续确认没有发送额外业务参数。

`readbackPolicy=unavailable` 只允许用于客观无法安全复查最终状态的高风险或破坏性
操作，并且必须同时使用 `retryPolicy=never`。它不是跳过回读的通用豁免；结果文案必须
明确说明能够确认到哪一步，并为未确认提交提供设备侧核对路径。

禁止保存 base URL、Cookie、SID、SynoToken、账号、真实路径、文件名、主机、原始请求
头或原始请求体。参数值只使用固定合成值；敏感参数只记录“存在、位置和编码类型”，
不记录占位凭据正文。

早期优先覆盖项为：

- 文件删除、移动和覆盖上传；
- 用户创建/删除、群组和共享权限；
- 套件卸载；
- 容器、虚拟机和映像删除；
- 网络、防火墙和远程访问设置；
- S.M.A.R.T. 任务和 DSM 更新提交。

只有公开 API 文档、当前源码或已记录的脱敏发现证据能够支持的请求才可进入 Fixture。
私有写请求继续受 `contracts/private-api/compatibility.json` 的环境开关约束。

## 3. 统一写操作结果语义

建议公共稳定值：

| 稳定值 | 语义 | 默认用户动作 |
| --- | --- | --- |
| `confirmedSuccess` | 写入完成且通过回读或最终任务状态确认 | 显示完成并刷新 |
| `confirmedFailure` | DSM 明确拒绝，或回读明确证明未执行 | 修正条件后重试 |
| `submittedButUnverified` | 请求可能已被接收，但最终状态无法确认 | 先刷新状态，不立即重复 |
| `partialSuccess` | 批量项目只有部分完成 | 展示成功/失败数量并复查 |
| `cancelledBeforeSubmission` | 请求尚未提交即取消 | 无需复查 |
| `cancellationRequestedAfterSubmission` | 已提交后请求取消，是否生效未知 | 刷新或查询任务 |
| `permissionDenied` | 权限不足 | 更换授权账号或停止 |
| `unsupported` | 当前 DSM、套件或平台不支持 | 不提供重试 |

结果对象还需包含：

- 稳定操作类别；
- 是否已经提交；
- 是否要求刷新；
- 成功、失败和未知项目数量；
- 可选的安全错误类别或本地化资源键；
- 不含原始响应、路径、名称、账号或请求材料的诊断标签。

领域层不得保存翻译后的句子。各平台 UI 根据稳定值和资源键显示“发生了什么”以及
“下一步怎么做”。

## 4. 五端影响与迁移

这是新增公共契约和平台领域类型，实施前必须同步评估五端：

| 平台 | 计划 |
| --- | --- |
| macOS/iPhone/iPad | 在 `DsmCore` 增加稳定结果类型；Repository 先适配高风险操作 |
| Android | 增加对应 Kotlin sealed 类型，ViewModel 不再只依赖异常和成功提示 |
| Windows | 增加对应 C# record/enum，保留现有“NAS 未确认”文案语义 |

迁移采用增量方式：

1. 先增加 JSON Schema、合成示例和校验器，不改变运行时。
2. 三端增加等价类型和序列化测试，旧 Repository 签名保持不变。
3. 选择一个具备回读的低影响写操作进行端到端适配。
4. 再迁移文件删除、账号、套件、容器、VMM、网络和存储。
5. 所有调用方迁移后，才评估移除旧的“成功或抛错”专用路径。

不修改现有本地数据 schema，不持久化尚未确认的操作结果，不自动重放写请求。升级
期间旧客户端继续使用原有方法；新类型只在完成迁移的调用链生效。

## 5. 回滚方案

- 请求 Fixture 和 Schema 为新增文件；若校验设计不适用，可在没有运行时依赖时整体
  回退，不影响客户端数据。
- 平台结果类型先作为并行返回适配层，不立即删除旧签名；单个模块可以回退到旧调用
  路径。
- 任何迁移不得改变 API 方法、参数、重试次数或写后复查策略。发现行为差异时关闭新
  适配并恢复旧路径。
- 不通过把 `submittedButUnverified` 降级成普通失败来兼容旧 UI；旧 UI 无法安全表达
  时，该模块保持未迁移。

## 6. 分批实施

### RC0：Schema 与校验工具

状态：`IMPLEMENTED`、`UNIT_TESTED`。

- 已建立请求 Fixture Schema、目录规则和隐私扫描。
- 已增加 File Station 删除合成示例、8 条正反向校验测试和 CI。
- 敏感业务参数只允许记录名称、类型和 `redacted: true`，禁止保存编码值。
- 已明确 Fixture 只证明客户端请求稳定性，不证明真实 DSM 兼容性。

### RC1：Apple 请求快照

状态：File Station、账号、套件、容器、VMM、Download Station、网络、安全、存储、
硬件、远程访问、文件服务、远程终端、互联网代理、区域与时间、DDNS 设置及 NAS 电源
动作的代表性请求为 `UNIT_TESTED`；共享权限、系统更新及更多写操作继续实施。

- 已从 `DsmRequestBuilder` 和当前 Repository 建立审核后的结构化对照测试。
- 已覆盖 File Station 删除、移动和覆盖上传，验证 API、方法、版本、路径、参数编码
  和认证材料位置；删除与移动已进一步通过 `DsmFileRepository` 的实际
  `start → status` 调用链捕获请求，不再停留在请求构建器级对照。
- 已覆盖 DSM 账号创建、账号删除和群组删除；密码只验证参数存在与传输位置，不进入
  Fixture。
- 已覆盖套件启动、停止、卸载、容器删除和 VMM 公开 API 虚拟机删除；内部接口
  Fixture 只证明当前客户端请求稳定性，不提升真实环境写行为证据等级。
- 已覆盖 QuickConnect 中继停用与 S.M.A.R.T. 快速检测启动；两者均使用当前
  Repository 真实调用链完成写请求对照，并保留写后回读策略。
- 已覆盖物理网卡 DHCP 设置；`configs` 按 JSON 结构比较，不依赖对象键顺序，Fixture
  不保存地址、网关或 DNS 值。
- 已覆盖 Download Station 任务删除、容器映像/网络删除和 VMM 映像/网络删除；内部
  接口仍只证明当前客户端序列化稳定，不代表目标 DSM 或套件版本已验证。
- 已覆盖自动封锁、DoS、防端口扫描、防火墙停用和配置档应用五类合成请求；配置档、
  网卡和任务均使用无设备信息的合成标识。
- 已覆盖断电恢复、指示灯、风扇、蜂鸣器、休眠和 UPS 六类合成请求；网络服务地址只
  使用语义占位值，LED 无参数的 `update` 仍由同一调用链测试覆盖。
- 已覆盖 QuickConnect 中继与路由器自动配置两类远程访问请求，目标地址、账号与设备
  信息均不进入 Fixture。
- 已覆盖 SMB、NFS、FTP/FTPS、SFTP、局域网发现和 Time Machine 六类文件服务请求；
  只使用合成开关与端口，不含共享目录、账号或设备信息。
- 已覆盖 SSH、Telnet 与 SSH 端口组成的远程终端请求，只使用合成开关与端口。
- 已覆盖互联网代理开关、合成地址与端口；不保存真实代理地址、账号或密码。
- 已覆盖区域与时间配置保存和立即校时；两份 Fixture 使用合成时区与 `.example.invalid`
  服务器，并分别固定 v3 `set` 与 v2 `sync` 的参数和危险重试策略。
- 已覆盖 DDNS 服务商测试、记录新建、立即更新和删除四类独立请求；用户名与密码仅验证
  参数存在和传输位置，Fixture 不保存凭据值。
- 已覆盖 NAS 正常关机与重启两类无业务参数请求；两者固定禁止重试且不伪造写后回读。
- 历史 RC1 批次已从 71 份请求 Fixture 起步；当前仓库的请求 Fixture、写结果示例和
  响应 Fixture 数量以[当前开发进度](../progress/STATUS.md)和对应 Repository Check
  输出为准。系统更新、共享权限与更多写操作仍待后续批次覆盖。

### RC2：Android 与 Windows 对齐

状态：Android 首批为 `UNIT_TESTED`；Windows 首批已由后续云端门禁覆盖。BTSearch
正式提交 `5850f4c` 已完成 Apple shared/mobile 与 Windows
Domain/Infrastructure/ViewModel/WinUI 闭环，并新增 `start`/`clean` 合成请求；该提交的
Windows Build run `31356270192` 完成 886/886 项 .NET 10 xUnit，并通过
WinUI x64 与 ARM64 Release 构建，Repository Check run `31356270189` 同步通过。

- 使用同一 Fixture 验证 API、方法、版本、路径、参数集合和策略。
- 平台特有 HTTP 实现可以不同，但可观察请求语义必须一致。
- Android 已从 Repository 实际调用链读取并对照 File Station 删除、容器删除和公开
  VMM 虚拟机删除三份共享 Fixture；File Station 删除补齐
  `accurate_progress=true`，公开 VMM 请求只发送 `guest_id`，未验证的旧内部 API
  继续保留原兼容参数。
- Windows 已为相同三份 Fixture 增加 Repository 请求测试，并把通用删除层改为由
  实际 API 调用点提供资源标识参数；公开 VMM 只发送 `guest_id`，旧内部 Guest 保留
  `guest_id + id`，网络和映像不再混入无关资源标识。早期 macOS 本机缺少 .NET 10
  编译器的限制已由后续 GitHub Windows Build 覆盖；后续新增契约仍必须在对应分支
  重新取得 Windows CI 证据。
- 后续继续把套件、容器/VMM 子资源、网络、防火墙、Download Station 新切片及其他代表性
  请求扩展到 Android/Windows；平台没有生产写入口的能力只建立契约消费测试，不为对齐而
  新增未经验证入口。当前 BTSearch v1 的实现口径为两端完整闭环：本机已通过 Apple shared
  聚焦/全量、iPhone 聚焦、94 份请求 Fixture、本地化和静态门；正式提交 `5850f4c` 又通过
  Apple Build run `31356270194`、Windows Build run `31356270192`、Android Build run
  `31356270244` 与 Repository Check run `31356270189`。真实设备与真实 NAS 仍单独验收。
- Android 收藏新增和 File Station 上传已对照公共合成 Fixture 验证 API、方法、版本、
  路径、表单或 multipart 参数、SID、SynoToken 位置和回读策略；其余代表性操作与
  Windows 继续迁移。

### MR0：结果类型与序列化

状态：Apple、Android 为 `UNIT_TESTED`；Windows 领域类型已由后续 GitHub Windows
Build 覆盖，BTSearch 正式提交 `5850f4c` 完成 886/886 项 xUnit 与 WinUI x64/ARM64
Release 构建。后续若新增 `MutationResult` 消费者或请求契约，仍需在对应分支重新跑
Windows CI。

- 已增加公共 Schema 和 Apple、Android、Windows 等价领域类型。
- 已覆盖 8 个稳定枚举线值、数量约束、状态不变量和安全诊断字段。
- 旧 Repository 签名和现有运行时行为保持不变。

### MR1：低影响试点

状态：Apple 与 Android 收藏新增试点为 `UNIT_TESTED`。

- 已选择公开 File Station 收藏新增作为低影响试点，并通过收藏列表确定回读。
- 已贯通 `FileRepository`、`DsmFileRepository` 和 macOS `WorkspaceModel`；旧
  `addFavorite` 方法继续保留。
- 已覆盖确认成功、明确拒绝、提交未确认、回读失败、回读不一致和提交前取消。
- 只有 `confirmedSuccess` 才更新本地收藏；未确认状态提示用户先刷新，不自动重放。
- Android 已接入提交、收藏列表回读、同路径防重复、未确认禁止自动重放和分级用户提示；
  Windows 调用链尚未迁移。

### MR2：高风险操作迁移

状态：Apple File Station 批量删除、套件启动/停止/卸载、账号/群组删除、物理网卡设置、
防火墙与安全防护、S.M.A.R.T. 检测启停、硬件设置保存、远程访问设置、文件服务设置、
远程终端设置、互联网代理设置、区域与时间设置、DDNS 设置、NAS 关机与重启，以及服务
管理模块的容器、虚拟机、Download Station 任务、容器映像/网络和 VMM 映像/网络删除为
`UNIT_TESTED`，其余模块继续实施。

- 批量删除已贯通 `FileRepository`、`DsmFileRepository` 与 macOS `WorkspaceModel`；
  旧 `delete` 方法继续保留。
- 已覆盖输入拒绝、权限拒绝、任务完成并逐项回读、提交时断网、回读失败、部分成功、
  提交前取消、提交后取消和父子路径重复提交。
- 只有逐项确认全部不存在才显示完成；未确认和部分成功均先刷新核对，不提供立即重试。
- 套件卸载已接入能力与可行性检查、同目标重复提交保护、写后套件列表回读、提交前/
  提交后取消区分，以及断网或回读失败时的未确认语义；未确认提示要求先刷新核对，
  不建议立即再次卸载。
- 套件启动与停止已把结果边界从 macOS 轮询下沉到 Repository。每次写入前重新读取
  列表，按稳定套件 ID 核对 `canStart/canStop`，再执行可行性检查；启动、停止和卸载
  共享同 ID 互斥。明确写入后最多轮询十次，提交超时、断线或取消时只读取列表核对，
  不重放原写请求；只有列表确认运行/停止状态才显示完成。macOS 提交前说明影响并确认，
  执行中显示进度、禁用重复操作并提供 VoiceOver 标签。两类请求均已增加合成 Fixture，
  真实套件启停行为仍需专用测试目标验收。
- 容器与虚拟机删除已接入能力及目标存在性预检、重叠目标重复提交保护、批量逐项
  统计、写后列表回读、提交前/提交后取消区分和断网未确认语义；只有确认全部目标
  不存在，或随后刷新确认全部不存在，界面才显示完成。
- Download Station 任务、容器映像/网络和 VMM 映像/网络删除已复用同一结果门禁；
  保留旧 Repository 方法以兼容既有调用方，macOS 只在回读或刷新确认目标消失后清除
  选择并显示完成。提交超时或回读失败均不自动重放。
- 账号与群组删除已增加受保护目标拦截、能力与存在性预检、同目标重复提交保护、写后
  目录回读和提交后未确认反馈；旧删除方法继续保留。
- 物理网卡设置已增加输入、能力与目标状态预检、同网卡重复提交保护、逐字段回读，以及
  提交断网、回读超时和提交后取消的未确认语义；提示用户尝试新旧地址重新连接，禁止
  自动再次保存。
- 共享权限写入依赖 `validate_set`、复合权限提交和移动任务轮询的稳定契约，当前不提供
  不完整入口。继续逐项迁移存储和系统更新。
- 防火墙与安全防护已按复合写操作迁移：预检计算自动封锁、DoS、防端口扫描和防火墙
  配置的实际差异，并一次性检查所需能力与配置档；提交逐项记录已接受的子操作，中途
  失败后停止后续写入并整体回读，区分确认成功、部分成功和提交未确认。配置档应用任务
  在提交后取消、轮询超时或连接中断时不自动重放；Repository 已增加全局重复提交保护。
- S.M.A.R.T. 检测启停已增加 `diskTestStart` 与 `diskTestStop` 结果操作，预检硬盘
  存在性、检测支持能力和当前运行状态，并在 Repository 按稳定硬盘标识阻止并发启停。
  提交断网、轮询超时、回读失败或提交后取消均要求先刷新检测状态，不自动再次启停；
  只有回读确认目标状态才显示完成。启动与停止请求均使用完全合成 Fixture，并已覆盖
  故障注入和模型反馈测试。
- 硬件设置保存已按断电恢复、指示灯、风扇、蜂鸣器、休眠和 UPS 六个逻辑子操作迁移：
  预检按字段差异一次性检查所需能力，逐项记录提交结果；中途失败、连接中断或整体
  回读不一致时区分部分成功与结果未确认，要求刷新全部硬件设置且不得自动重放。
  Repository 已增加全局重复提交保护，macOS 保存时显示原生进度并提供逐项核对提示。
- 远程访问设置已按 QuickConnect 中继与路由器自动配置两个独立子操作迁移。提交前
  识别连接方式、计算实际差异并一次性检查全部所需能力；当前通过受信 QuickConnect
  中继连接时拒绝关闭中继。Repository 使用全局重复提交保护，逐项提交后整体回读；
  中途断网、部分生效、回读失败和提交后取消分别给出部分成功或结果未确认，均不自动
  重放。macOS 会提示用户换用可用地址重新连接并核对两项设置，路由器自动配置已增加
  完全合成的请求 Fixture 与故障注入测试。
- Android 第 55 批已贯通远程访问正式 Repository、AppViewModel 和 Compose 界面：
  Repository 固定 QuickConnect v3 与 Upnp v1，只接受严格 Boolean，单项失败以 `null`
  独立降级；内部写入口只在完整匹配已记录 DSM build/Update 时开放。保存仅提交实际
  变化字段，可信中继连接禁止关闭中继；取消、断线和歧义失败均不重放，按实际变化字段
  专项回读并保留八类结果、三计数、刷新/放弃门槛和可恢复草稿。专项覆盖 36 项 JVM 与
  12 项 Compose 测试；第 55 批未执行真实 NAS 或路由器写操作，合成测试与既有登录链路
  证据均不提升 `observed / degraded` 兼容等级。
- Android 第 56 批已贯通 Download Station 暂停、继续、仅移除任务及移除任务并删除文件
  的正式 Repository、AppViewModel 和 Compose 界面。写入口只接受完整稳定任务基线，
  严格分页读取拒绝畸形、重复、总数漂移与截断；同目标跨动作原子防重复，提交后取消、
  断线或结果不明时只专项回读且不重放。危险删除必须显式确认，旧字符串旁路已移除；
  删除文件按任务移除和文件删除两个效果计数，任务消失只确认前一效果，不把公开 API
  无法独立核对的文件副作用冒充成功。严格刷新证据绑定 Repository、NAS、稳定目标与
  代次，并持久阻止危险结果在核对前清除、切换 NAS 或退出登录。专项 49 项 JVM 与
  24 项 Compose、完整 857 项 JVM 和 API 35 全量 263 项均通过；本批未操作浏览器或
  真实 NAS，未执行真实暂停、继续、任务移除或文件删除。
- 文件服务设置已按 SMB、NFS、FTP/FTPS、SFTP、局域网发现和 Time Machine 六个逻辑
  子操作迁移。提交前计算全部差异，验证端口范围、活跃服务端口冲突和 SMB/Time Machine
  依赖，并一次性检查全部所需能力；Repository 使用全局重复提交保护，按稳定顺序提交
  后整体回读。中途超时、部分生效、断网、回读失败和提交后取消均不自动重放，macOS
  会显示保存进度并提示重新读取全部设置逐项核对。六类请求均已增加完全合成 Fixture。
- 远程终端设置已按 SSH、Telnet 与 SSH 端口三个实际变化字段迁移。提交前验证端口和
  API 能力，Repository 使用全局重复提交保护；一次提交后逐字段回读，完整匹配、部分
  生效、明确不匹配和结果未知使用不同状态。断线、超时、回读失败和提交后取消均不自动
  重放，macOS 会显示端口行内错误、保存进度和重新读取提示。LanStash 使用 HTTP/HTTPS
  DSM 会话，不虚构当前 SSH/Telnet 连接保护；请求已增加完全合成 Fixture。
- 互联网代理设置已按启用状态、地址与端口三个实际变化字段迁移。启用时先规范化并
  验证地址、端口和目标能力，Repository 使用全局重复提交保护；一次提交后逐字段回读，
  停用时只校验开关，不把 DSM 保留的旧地址和端口误判为失败。断线、超时、回读失败和
  提交后取消均不得自动重放；Fixture 只使用合成地址，不保存密码或真实代理信息。
- 区域与时间设置已分离配置保存和立即校时两个副作用边界。客户端规范化格式与最多
  三个时间服务器，验证时区和能力，先一次性保存配置并逐字段回读；只有配置完整确认
  且网络校时模式或服务器变化时才调用立即校时。配置提交未知时不继续校时，校时失败
  则保留已确认配置并报告部分成功，所有提交后异常均不得自动重放。未编辑手动时间时
  使用预检刚读取的 NAS 时间，不用 Mac 时间或页面旧值。
- DDNS 已将服务商测试、新建/编辑、立即更新和删除拆为四个独立操作。密码或密钥只
  存在于当次测试或保存请求；Repository 按服务商稳定标识和全局立即更新互斥预检与
  防重复。保存和删除提交后重新列出记录逐项核对，超时后只允许单次回读且不重放；
  测试成功不冒充记录保存成功，立即更新被接受也不冒充公网 DNS 已传播。
- NAS 关机与重启已增加 `System.info` 会话、权限和可达性预检，两类动作共享
  Repository 与 macOS 模型全局互斥，并区分提交前取消、明确接受、明确拒绝、提交阶段
  取消和结果未知。由于关机没有可用回读、重启会主动断开连接，成功只表述为“DSM 已
  接受请求”，不伪造设备已关机或已重新上线；未知结果提示检查设备或等待重连且不自动
  重放。两类无参数请求已增加合成 Fixture，真实行为只在专用测试目标验收。
- 共享文件夹权限批次已先完成安全的只读边界：`FileStationShareAccessRepository`
  分页读取公开 `list_share`，按稳定 ID 去重并排除远程挂载；macOS 只显示当前账号
  可见共享的读写和删除能力，权限字段缺失时标为未知，不把不可见条目推断为禁止。
  `SYNO.Core.Share.Permission.list_by_user` 只有静态方法名证据，管理员权限目录、继承
  规则、冲突优先级和写后回读契约仍保持关闭。任何后续写入都必须先取得版本化
  `validate_set`、复合权限提交和移动任务契约，再按共享文件夹稳定标识防重复、显示
  变更摘要、验证管理员权限并逐主体回读。
- 系统更新安装边界已完成只读审计：客户端继续仅调用 `System.info` 与
  `Upgrade.Server.check` v3，规范化候选版本与发布说明，候选为空或与当前版本相同时
  不宣告更新；macOS 明确提示安装须在 DSM 中安排，不提供下载或安装按钮。下载、
  准备、安装、取消、重启和恢复尚无版本化任务状态机，继续保持关闭。
- 套件安装与升级批次已完成安全的只读边界：`Package.list` 明确返回
  `available_operation=upgrade` 时设置独立的 `isUpgradeAvailable`，macOS 只显示
  “DSM 中有可用更新”的非交互标签；`canUpgrade` 继续固定关闭，模型防御性拒绝升级且
  不进入 Repository。`Package.Server` 与 `Package.Installation` 只有静态方法名证据，
  在取得套件来源、签名、依赖、空间、安装队列、取消和最终版本回读契约前不探测、不
  调用，也不创建猜测的请求 Fixture。
- 系统进程与服务进程组批次已完成保守的只读适配：客户端只接受运行时发现的 v1，
  `System.Process.list` 与可选的 `System.ProcessGroup.list` 单次最多读取 500 项，
  领域模型仅保留编号、名称、状态、服务组标识和数量。命令行、路径、账号、网络地址及
  未知字段不会进入模型；服务组失败不阻断进程列表，`service_info` 和结束进程等写操作
  保持关闭。当前只有静态目录与合成测试，真实 DSM 响应仍标为未验证。
- 电源计划批次已完成保守的只读适配：客户端只接受运行时发现的 v1 `load`，一次最多
  保留 128 条；只解释白名单动作、启用状态、合法时间、命名星期、一次日期与受限时区。
  数值星期因周日起始歧义保持未知，命令、路径、账号和地址不会进入模型。`save` 没有
  进入 Repository 或界面，当前真实 DSM 响应仍标为未验证。
- 外接存储批次已完成保守的只读适配：客户端分别发现并调用 USB 与 eSATA v1
  `list`，每种连接最多保留 64 项；只读取受限标识、名称、归一状态以及字段名明确为
  字节的容量。设备节点、挂载路径、共享名、序列号和地址不会进入模型；单项失败保留
  另一项结果。USB `eject` 没有进入 Repository、Fixture 或界面。
- 内存压缩批次已完成保守的只读适配：客户端只接受运行时发现的 v1 `get`，仅保留
  启用状态、字段名明确为字节的配置容量和 `lz4` / `lzo` / `zstd` 算法白名单。
  官方 DSM 页面已只读观察到该设置，但没有捕获 API 请求或响应，真实契约仍标为
  未验证；`set` 没有进入 Repository、Fixture 或界面。
- 打印机 Bonjour 共享批次已完成静态审计：当前只确认
  `SYNO.Core.ExternalDevice.Printer.BonjourSharing.get` 名称与方法，版本、路径、参数、
  响应和权限均未知。通用 Bonjour/Avahi 字段属于其他 API，不能复用；客户端不注册
  能力、领域模型或 Adapter，保持零猜测请求。取得版本化静态契约或脱敏只读响应后，
  再决定是否只保留可空布尔状态。
- 安全扫描状态批次已完成静态审计：当前只确认
  `SYNO.Core.SecurityScan.Status.rule_get/system_get` 名称与方法，组件归属、版本、路径、
  参数、响应和权限均未知。客户端不注册能力，不与现有自动封锁、DoS 或防火墙设置
  合并，保持零请求；规则正文、发现详情、路径、账号、主机、网络与修复命令均禁止
  进入领域模型或默认界面。组件与环境版本未确认前暂不建立机器端点记录。
- File Station 后台任务批次已在 Apple 共享领域、Adapter 与 macOS 传输中心完成官方
  `SYNO.FileStation.BackgroundTask.list` v3 的只读实现：请求使用 `offset >= 0`、
  `limit=1...100`、`sort_by=crtime`、
  `sort_direction=desc`，`api_filter` 只允许 CopyMove、Delete、Extract 和 Compress
  四类 API。`params`、`path` 与 `processing_path` 在解码边界直接丢弃，避免路径、
  文件名或压缩密码进入领域模型、日志、遥测和 Fixture；`finished=true` 只归一为
  “已结束”，没有独立结果证据时不得宣称成功。`clear_finished` 不进入 Repository 或
  界面，能力缺失或 v3 不在运行时发现范围时保持零请求。传输中心把 App 传输和 NAS
  文件任务作为独立数据源，NAS 任务支持全部/进行中/已结束筛选、刷新、有限分页，以及
  加载、空内容、筛选后为空、错误和正常内容五种状态。聚焦自动化 13 项已通过，当前
  尚未取得真实 DSM / File Station 只读响应。
- File Station 目录大小批次已在 Apple 共享仓库与 macOS 属性窗口完成官方
  `SYNO.FileStation.DirSize` v2 的 `start(path JSON array) -> taskid`、
  `status(taskid) -> finished/num_dir/num_file/total_size` 和 `stop(taskid)` 工作流。官方
  `stop` 参数表疑似写作 `tasked`，但请求示例和其余方法都使用 `taskid`，客户端按一致
  契约提交 `taskid`。用户必须显式选择计算或重新计算；取消只提交一次 `stop`，同路径
  防重复，轮询有界，结果未知时不自动重放 `start`。属性窗口关闭后任务继续，关闭
  File Station 模块或断连时取消；只有能力缺失才回退客户端递归，其他错误保持可见。
  路径和服务端任务 ID 只在 Repository 内存中短暂存在，不进入领域结果、错误、日志、
  遥测或持久化。8 项 DirSize 聚焦测试、529 项 Apple XCTest、4 项 Swift Testing、
  本地化与契约校验以及 `DsmMac` Debug 无签名构建均已通过；真实 DSM / File Station
  验收仍待完成。
- 后续任何写项必须具备确认、权限检查、重复提交保护、最终状态复查和故障注入测试；
  只读项必须具备能力与权限边界、字段白名单、失败降级、零猜测请求和隐私测试。

### SEC-002：Apple URL 凭据收敛的跨端迁移边界

2026-08-22 的 macOS 发布整改使 Apple 共享网络层不再把 File Station 读取或上传的会话、
Token 写入 URL，保留 Cookie、Header 和现有 multipart 认证字段。此变更不修改 DSM API
名称、方法、业务参数或公开客户端签名。

当前 `file-station.upload.synthetic-overwrite` Fixture 仍记录 URL 认证位置，因为 Android
上传实现和自动化尚未迁移。不能为了让 Apple 测试表面一致而直接修改该 Fixture，也不能把
Apple 的安全收敛表述为 Android 或 Windows 都已完成。Apple 测试应在保留 Fixture 的 API、
参数和 multipart 约束下，额外断言 URL 没有凭据；平台矩阵和 macOS 整改账本记录该例外。

后续跨端切片须先获得授权，再按 Android 实现与测试、共享 Fixture、Windows/Apple 回归、
真实 DSM 兼容性和五端矩阵的顺序迁移；在此之前，Android 不属于本 macOS 发布整改的修改
范围。

## 7. 完成条件

- 请求 Fixture 校验器能够拒绝凭据、主机、真实路径、未知字段和危险写操作的可重试
  配置。
- Apple、Android、Windows 对同一 Fixture 给出一致业务请求语义；认证位置若因已记录的
  平台安全收敛而不同，必须保留共享 Fixture 的历史证据、逐平台自动化、五端矩阵与后续
  迁移计划，且不得把例外表述为全端完成。
- 每个迁移的写操作覆盖至少：提交前失败、提交成功且回读成功、提交后网络失败、回读
  失败、批量部分成功和提交后取消。
- UI 对 `submittedButUnverified` 明确提示先刷新状态，不建议立即重复操作。
- 平台矩阵记录已迁移模块和仍使用旧结果语义的模块。

## 8. 审批门槛

新增请求 Fixture Schema 本身不改变 App 行为；统一写操作结果会新增公共契约并影响
五端 Repository 和 UI。开始 RC0/MR0 前，应确认上述影响、增量迁移和回滚方案；未经
确认不得直接批量修改五端公开签名。
