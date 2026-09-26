# DSM 账号与群组目录内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-account-directory` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM |
| 能力名称 | 账号与群组目录读取和管理 |
| 分类 | `internal` |
| 操作性质 | `mixed` |
| 风险等级 | `critical` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.User`、`SYNO.Core.Group` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现；客户端当前测试路径为 `entry.cgi` |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie 与请求字段；可用时同时携带 SynoToken 请求头与字段，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

账号方法：`list`、`get`、`create`、`set`、`delete`。群组方法使用相同方法名和独立的
`SYNO.Core.Group` API。

关键参数：

| 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- |
| `offset`、`limit` | `integer` | 列表需要 | 分页范围 | `0`、`1000` |
| `additional` | `string[]` | 列表需要 | 请求数字标识、说明、状态和可操作性字段 | `["uid","can_delete"]` |
| `name` | `string` 或 `string[]` | 写入需要 | 合成账号或群组标识；删除使用数组 | `<synthetic-account>` |
| `description`、`email`、`expired` | 多类型 | 账号保存需要 | 只发送编辑器当前值 | 完全合成值 |
| `groups` | `string[]` | 可选 | 账号所属群组 | `["<synthetic-group>"]` |
| `password`、`password_confirm` | `string` | 新建账号需要 | 只用于当次请求 | 仅记录存在和已脱敏，不保存值 |

群组 create/set 使用稳定 `name` 和 `description` 字符串；不携带账号邮件、停用、密码
或组成员参数。编辑不重命名目录项。账号编辑省略空密码以保留凭据，`groups` 未选择
时省略以保留成员关系；缺少原有组关系时不以空数组覆盖。

## 响应与错误

只读成功响应使用 DSM 通用信封，`User.list` 的 `data.users` 与 `Group.list` 的
`data.groups` 为数组。客户端只解析名称、数字标识、说明、邮件地址、停用状态、群组
以及 `can_edit`、`can_delete`；字段缺失时不推断额外权限。

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或版本未发现 | 当前环境不支持 | 否 | 关闭账号管理入口 |
| 会话失效 | 需要重新登录 | 否 | 停止写入并重新认证 |
| 权限不足 | 当前账号不能执行操作 | 否 | 不尝试管理员权限 |
| 写请求连接中断 | 最终结果未确认 | 否 | 先重新读取目录，不自动重放 |
| 写后目录不符合预期 | 结果不一致 | 否 | 保留当前列表并提示人工核对 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | User / Group v1 | 只读结构和网页请求已记录；未执行账号写行为验收 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

共享请求 Fixture 和本地源码测试只证明客户端请求没有漂移，不把本环境提升为
`behavior-verified`。

## 能力探测与降级

- 启用条件：`SYNO.API.Info` 返回对应 API、v1 和可用路径，当前会话具备页面权限。
- Android 对账号与群组列表分别保留读取成功状态；请求失败时即使列表回退为空，也将
  `accountsAvailable` / `groupsAvailable` 标记为不可用，不把失败误认为真实空目录。
- 新版本默认行为：未记录的新 DSM build 上内部写入口保持关闭，完成重新观察和专用
  环境行为验收后再形成兼容结论。
- 接口缺失：账号管理页面独立降级，不阻断文件浏览等公开 API 主流程。
- 字段缺失或类型变化：不假定额外权限；身份、行结构或字段类型无法安全解析时目录
  读取失败，不通过丢弃条目伪造删除成功。可选值缺失保持未知，不自动补为可写字段。
- 权限不足：显示可恢复说明，不自动切换或尝试更高权限账号。
- 网络失败：写后先重新读取账号与群组目录，不自动重新提交。
- 替代的官方 API：当前项目未找到满足 DSM 本地账号管理需求的公开 API。
- 功能开关：运行时能力发现与平台账号管理入口共同控制。

## 客户端与测试

- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository.swift`
- Android Adapter：`DsmRepository.deleteAccountResult` / `deleteGroupResult` 使用用户确认时看到的
  完整 `NasAccount` / `NasGroup` 作为删除基线；写前以固定 v1 严格重读并比较数字标识、名称、
  说明、账号邮件、停用状态和删除许可，任何漂移均按冲突零写入。严格列表要求唯一数组根、
  对象行、非空且唯一的稳定名称以及类型正确的权限字段；普通快照同时保留
  `additional.uid` / `additional.gid`，避免同一响应在写前产生伪基线漂移。列表只在
  `can_delete=true` 时开放入口，并额外保护当前账号和系统保留名称。
- Android 删除结果通过持久状态保存确认目标、确认阶段、提交结果、专项刷新结果与失败；
  写后只调用严格账号或群组目录回读。畸形、缺根、重复身份或读取失败不能证明目标消失，
  也不会触发删除重放。
- Windows Adapter：User/Group v1 独立严格读取、确认基线删除及只读恢复核心已迁移。
  解析根/行、稳定名称、uid/gid、说明、邮件、停用、组关系和权限；同时支持已记录的
  根与 additional 字段，但两处冲突时失败，未知停用状态保持可空。目录达到 1000 条
  源边界时失败，不将未完整读取当成目标消失。旧工作区分别保存账号/群组状态，一方
  失败不遮蔽另一方成功数据；原生管理调用链已接入读取、新建、编辑、删除和恢复。
- Windows 删除固定 name 数组，保护当前账号与系统保留名称；写前重读并比较完整
  确认基线。按账号/NAS/目录类型/名称保存同客户端挂起状态，同请求不重放，未知目标
  不允许以新请求 ID 绕过。断线后只回读一次，提交后取消保留未知，重建页面可查询
  挂起目标后只读核对。账号/群组生产删除行为门各自关闭。
- Windows 新建/编辑核心已迁移：按已记录 Session.is_admin 的明确布尔真值及版本
  做管理权限检查，编辑重读完整基线且要求 can_edit，组关系变更核查目标组目录。
  当前账号不能被停用或改变自身组关系。保存与删除共用目标互斥和未知恢复；密码与
  确认密码仅是调用参数，不进入确认 DTO、共享缓存或指纹，空密码不发送。
  记录回读比较姓名、说明、邮件、停用、选择的组关系与既有数字 ID；涉及密码还必须
  收到接受响应。密码响应丢失时即便字段匹配也保持未知，不能据此证明密码登录可用。
  用户/群组保存行为门独立关闭。原生界面仅在明确选择修改组关系时发送 groups；
  原组关系未知、组目录不可读或当前账号时禁止修改，其他允许编辑的资料不受影响。
- Windows 原生目录管理具备账号/用户组切换、本地搜索、只读编号/邮箱/所属组、
  独立的保存和删除确认以及持续反馈。确认绑定当前字段、目标、组选择及临时密码，
  控件变化会失效，执行前重新读取控件；关闭/切换清除两个密码框并隔离迟到结果。
  恢复包含已从目录消失的目标，不重放写请求。当前只有合成界面证据，生产写门未开放。
- Mac 本波修正：严格根/行/重复身份及字段类型，保留 additional.uid/gid 和可信空文本；
  缺少许可不默认允许，缺少会被编辑器覆盖的字段时关闭编辑。删除前重新检查当前
  can_delete，并保护已知当前账号；界面不再凭目录为空覆盖拒绝或未知结果。
  名称只在保护检查中规范化，不裁剪后去删除另一个目录目标。
  Mac 保存模型已增加创建重名/编辑基线预检、逐字段核对与真实新回读，回读失败不得
  使用页面缓存确认；模糊错误改为不可重试的未确认提示。保存/删除共用规范化目标
  标识及界面忙碌状态，已知当前账号不能被保存动作停用或改组。Mac 名称式删除的
  完整确认基线仍待后续完善；新增共享 Swift 与 Mac 模型回归未在 Windows 环境运行。
- Schema：`contracts/schemas/request-fixture.schema.json`
- 合成 Fixture：
  - `contracts/request-fixtures/users/create/synthetic-account/request.json`
  - `contracts/request-fixtures/users/delete/synthetic-account/request.json`
  - `contracts/request-fixtures/groups/delete/synthetic-group/request.json`
- 自动化测试：
  - `apple/Packages/DsmNetwork/Tests/RequestFixtureContractTests.swift`
  - `apple/Packages/DsmNetwork/Tests/DsmNasAdministrationRepositoryTests.swift`
  - `android/app/src/test/java/io/github/qwertyuiop1995/dsmnativeclient/data/DirectoryDeletionMutationTest.kt`
  - `android/app/src/test/java/io/github/qwertyuiop1995/dsmnativeclient/data/NasSettingsAvailabilityTest.kt`
- Android 自动化覆盖完整基线相等与漂移、权限拒绝、保留账号、固定 v1 和不支持版本零请求、
  严格列表畸形回读、模糊提交只回读、同目标互斥以及失败列表与真实空列表的可用性区分。
  第 53 批仓库汇总口径为 JVM 753 项、Android 双语资源完整性 1526 项；API 35 仪器测试
  最终 XML 为 220 项，其中 214 项通过、6 项跳过、0 项失败。这些自动化结果不替代真实
  NAS 验收。
- 产品兼容矩阵条目：`contracts/private-api/compatibility.json` 的
  `dsm-account-directory`

## 安全与副作用

- 会读取的数据类别：账号与群组名称、说明、邮件地址、状态、成员关系和可操作性。
- 可能产生的副作用：创建、修改或删除 DSM 本地账号与群组，可能影响访问权限。
- 所需权限：由 DSM 返回的能力和当前会话权限决定；客户端不得提升权限。
- 重复提交保护：Repository 与 macOS 模型均按稳定账号或群组标识隔离正在执行的删除。
- 写后结果校验：保存或删除后重新读取账号与群组目录并核对目标状态；提交后断网、取消
  或回读失败均返回未确认结果，不自动再次删除。
- 临时数据清理：密码只存在于编辑草稿和当次请求，不写入 Fixture、日志或持久化。

## 未验证事项

- 当前环境未在专用测试账号上完成创建、修改、删除、权限不足、网络中断和重复提交的
  行为验收。
- Android 创建和编辑以及 iPhone、iPad 用户调用链尚未迁移；
  Windows 新建/编辑/删除核心只有合成证据，Android 删除仍待真实 DSM 与设备验收。
- Mac 新增读取失败关闭及删除反馈修正待目标平台回归；Apple 共享内部 JSON 类型只
  增加等值比较供根/额外字段冲突检测，不改变持久化格式。iPhone/iPad 需评估共享层
  回归，Android 本波只更新适配评估、不修改源码；真实环境证据等级不提升。
- 第 53 批新增的 Android 严格基线、固定版本、取消、专项回读和持久反馈均只通过合成响应
  与自动化测试验证，尚未在真实 NAS 上执行删除行为验收。
- DSM 升级后的方法参数、权限和错误码变化尚未验证。

## 2026-09-26 macOS 读取回归修复

当前待归属浏览器观察确认用户列表的 `expired` 是 `normal/now` 文本枚举，Apple
兼容这两个状态及原有布尔响应。完整资料缺少 `can_edit` 时允许打开编辑器；显式 false
继续禁止，缺少可编辑资料继续关闭，服务端权限拒绝不绕过。删除仍要求显式许可，
当前账号与保留账号保护不变。证据见 [本次观察](../environments/2026-09-26-nas-settings-read-observation.md)。
