# Container Manager 只读观察

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察；不冒用既有基线 |
| 匿名设备别名 | 与 lab-a 关系未确认 |
| 基线状态 | 不建立 current 基线 |
| 替代的旧基线 | none |
| 发现日期 | 2026-09-10 |
| DSM 版本 / build / Update | 待本次核实 |
| 设备架构类别 | 未验证 |
| 连接方式 | QuickConnect；直连或中继未验证 |
| 证书类别 | 未验证 |
| 账号权限类别 | 待核实；已登录会话可打开 Container Manager |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 |
| --- | --- | --- | --- |
| container-manager | Container Manager | 待核实 | 官方页面可打开 |

## 证据来源与范围

- 用户截图及已登录官方网页；后续仅观察页面正常读取产生的必要请求。
- 目标：日志读取、网络容器数量和网络详情字段，核对当前客户端映射。
- 不检查日志正文、真实容器环境变量或挂载路径；不执行启停、创建、删除、导出或权限变更。
- 仅保存请求参数结构和脱敏响应字段类型，不保存原始 HAR、响应、会话、地址、账号、日志正文或真实资源标识。

## 结论

### 用户授权的单个测试网络删除

- 用户反馈已通过本地测试包创建一个测试网络，但客户端删除失败，并明确要求 Agent 在官方页面删除该测试网络以核对请求；执行前又确认了最终删除。
- 范围限定为该单个测试网络。官方列表执行前显示关联容器为 0；其他网络不得操作。仅记录脱敏参数类型、返回状态与最终列表变化，不保存实际网络标识、地址、账号或凭据。
- 实际观察到 `SYNO.Docker.Network.remove` v1：参数为 `networks` 对象数组，不是单个 `id`。每个对象带 `id/_key/name/driver/containers/enable_ipv6/disable_masquerade/subnet/gateway/iprange/ipv6_subnet/ipv6_gateway/ipv6_iprange`；本次仅一个无关联容器的测试网络。原客户端发送单个 id，与官方请求不一致。
- 官方响应成功且 `failed:[]`，随后列表不再包含目标；其他网络仍在。只对本次单目标删除形成行为证据，未核实完整 DSM/套件版本，不归入历史基线；未删除容器/映像，已移除临时观察包装器。
- 客户端两条删除入口共用已观察的对象数组提交；写前重新解析目标，默认网络及连接容器的网络禁止删除，写后沿用按 ID 回读与结果不明核对。请求 fixture 和 macOS/Apple 回归同步；Windows/Android 旧 id 参数仍需后续独立迁移，不能视为已经修复。
- `swift test --package-path apple --jobs 4 --filter 'DsmServiceManagementRepositoryTests|RequestFixtureContractTests|ServiceManagementModelTests|AppUpdateTests|SynologyPhotosModelTests'`：163 项通过，覆盖删除对象参数、共享 fixture、保护网络无写入及版本展示。首次编译发现对象数组应使用项目既有 DsmJSONValue 类型，已修正后重跑通过。

- 官方日志页 `SYNO.Docker.Log.list` v1 成功返回非空列表；只记录类型，不保存正文。参数：`action=load`、`offset=0`、`limit=1000`、`sort_by=time`、`sort_dir=DESC`、`loglevel=""`、`filter_content=""`、`datefrom=0`、`dateto=0`。
- 日志响应字段：`logs:[{event:string,level:string,log_type:string,time:string,user:string}]`，`time` 形式为 `yyyy/MM/dd HH:mm:ss`；`offset/limit/total/error_count/info_count/warn_count` 为数字。观察到 `level=info`。没有记录日志内容或用户值。
- 官方网络页轮询 `SYNO.Docker.Network.list` v1 成功；响应为 `network:[{containers:[string],driver:string,enable_ipv6:boolean,gateway:string,id:string,iprange:string,name:string,subnet:string}]`。已观察非空和空关联数组，数量由数组长度得到，不是 `container_count`。
- 请求和成功结构通过官方页面自身读取观察；网络 `list` 不传额外参数。普通网络事件工具未收到请求事件，改为临时观察官方请求包装器及轮询回调，只提取白名单参数和字段类型；所有临时包装器已恢复，未落盘原始响应或脚本。
- 已加载官方 `MainVue.js` 静态线索：日志默认每页 1000，按 `total` 换页；级别筛选、用户、事件、时间均来自上述记录。清除、导出、网络管理等写或导出动作没有执行。
- DSM 完整版本、Container Manager 完整版本与权限类别本轮未重新核实；结果不能归入历史 lab-a 基线，也不能证明其他版本、权限和客户端实机验收通过。

## 客户端修复与剩余范围

### 1.0.5 正式版创建入口修正

- 用户已实际创建成功，并明确要求正式版也可用。1.0.4 仍用 `AppStorageNamespace.isLocalTest` 作为创建开关，是发布接线错误；1.0.5 移除这一包类型条件，macOS 正式版与测试版均显式启用现有创建逻辑。
- 不改变请求参数、NAS 权限裁决、接口版本检查、输入校验、用户确认、同名互斥或写后回读；其他平台与持久化不变。历史各轮的“正式版关闭”描述仅代表当时状态，以本节为当前实现。
- 新增正式组合根的源码接线回归，配合已有能力快照、模型创建调用及请求参数测试，防止只验证测试包而遗漏正式入口。真实版本覆盖范围不因开关修正而自动扩展。

### 项目列表与新建网络后续核对

- 用户后续反馈：项目页面加载失败，新建网络表单与官方页面不一致；同时要求隐藏日志筛选框前重复的级别标签。
- 本次只观察官方项目读取与网络新增表单，不提交创建、不修改现有网络；复用本快照的连接类别、版本未知与设备未归属限制。先核对实际参数与字段，再决定兼容修正；涉及写契约的扩展不能继承此前只读字段扩展的授权。
- 项目 `SYNO.Docker.Project.list` v1 无附加参数；官方页面本次两次成功读取均返回空对象 `{}`。这是无项目，不是请求失败。静态官方状态管理按对象的键提取项目 ID，非空摘要使用 `name/status/containerIds`；非空结构只有静态证据和合成测试，不表述为真实非空项目已验证。
- 客户端为项目分区单独解析 ID 键值对象，空对象返回正常空列表；保留此前数组/标准包装格式，畸形对象仍报错，不放宽其他分区。日志只隐藏筛选器可见标签，保留无障碍标签、筛选功能和表格级别列。
- 用户补充要求隐藏标签后仍需对齐：筛选栏与表头共用水平边距，筛选器左对齐到时间列，搜索框从下一列起点排列，条数与列表内容右边缘对齐；不改变筛选或日志数据。
- 官方创建网络表单：名称、IPv4 自动/手动及子网/IP 范围/网关、IPv6 无/手动及对应三项、禁用 IP 伪装；没有驱动选择器。仅打开后取消，未输入真实数据、未发送创建请求。
- 已加载官方脚本静态定义 `Network.create` v1 参数：`name`、`enable_ipv6`、`disable_masquerade`；手动 IPv4 追加 `subnet/iprange/gateway`，手动 IPv6 追加 `ipv6_subnet/ipv6_iprange/ipv6_gateway`。自动/无配置会移除对应地址字段。默认自动 IPv4、IPv6 关闭、IP 伪装不禁用；不传 `driver`。这只是静态写契约线索，不是行为验证。
- 用户随后明确批准一起同步修复。已新增 `ContainerNetworkCreation`，将 Apple 服务创建方法从 `name/driver` 迁移为配置对象，仓库内调用方和测试同步迁移，不保留并行的简化创建实现。表单包含官方自动/手动模式及全部已知字段，提交前确认、名称/地址/前缀/范围校验、同名预查、同名操作互斥、写后回读；结果不明保留待核对状态，再次调用只读取，不重放创建。
- 真实创建未验证，因此 `containerNetworkCreationEnabled` 默认 false，快照 `canCreateNetworks` 默认 false，UI/Model/Repository 同时限制提交；当前 App 组合根未开启。测试仅对合成传输显式开启。完整表单可查看，实际创建保持 `PENDING_USER_VALIDATION`，不能把代码完成表述为当前 NAS 已可安全创建。
- 后续用户明确要求测试包必须可点击并实际测试创建：独立本地测试包组合根改为按 `AppStorageNamespace.isLocalTest` 开启创建能力，正式 App 与移动端仍使用默认关闭。此授权只开放用户手动操作的本地验收入口，不代表 Agent 获准替用户在 NAS 创建网络，也不升级真实写入证据。UI 确认、配置校验、权限裁决、同名互斥、结果不明只回读等保护不变。新包构建号为 1.0.3（14），替代之前不能提交的（13）包用于验收。
- 回读核对稳定身份、名称、bridge 类型、IPv6 开关及手动 IPv4 的子网/网关/IP 范围；当前只读响应没有已验证的 IPv6 地址和 IP 伪装结果字段，不宣称这些选项已完成实机核对。开启真实创建前必须补齐专用环境的权限、错误、结果及副作用验证。
- 使用系统 Network 框架解析 IP 地址，无第三方依赖、最低系统版本或持久化变化。回滚时移除新增配置类型及表单链路并保持创建入口关闭，不能恢复未经验证的旧 name/driver 写入入口。

| 平台 | 创建契约影响与迁移 |
| --- | --- |
| macOS | 创建配置、表单、Model 和 Repository 已统一迁移；未验证提交默认关闭 |
| iPhone | 共享包获得配置类型；现有只读容器清单接口不变，不新增创建入口 |
| iPad | 与 iPhone 相同；不借共享类型增加未批准的移动写能力 |
| Android | 仅记录后续需迁移的字段与安全门禁，本次不改 Kotlin 代码 |
| Windows | 仅记录后续需迁移的字段与安全门禁，本次不改 C# 代码 |

- 修复日志请求参数、读取后续页、网络计数，保留缺字段/失败与真实空列表的区别；macOS 消费各附属分区失败/不可用状态，补日志用户列、级别和搜索以及正常空状态。
- 首轮只修读取；用户随后明确同意扩展网络只读详情。共享 `ContainerNetwork` 增加默认 nil 的可选 `subnet/gateway/isIPv6Enabled/connectedContainerNames`，旧构造调用保持兼容；macOS 原生展开视图展示这些字段，未知状态显示“未提供”，已知空关联列表显示无连接。不改公开服务方法、NAS 请求、持久化、权限或写接口，无数据迁移；回滚移除新增可选字段、映射和详情视图即可。
- 五端影响：macOS 与 Apple 网络层获得读取修复及可选详情映射；iPhone/iPad 现有专用容器清单不调用附属分区，服务接口与旧构造调用不变，暂不新增页面；Android 与 Windows 不修改，本记录可供后续独立迁移，不能宣称已经对齐。
- 不包含容器日志流/终端、资源进程、环境变量、镜像私有凭据及启停/删除/清除日志/网络管理等写能力扩展。

## 自动化与集成复核

- 用户授权开放本地测试入口后，`swift test --package-path apple --jobs 4 --filter 'AppStorageNamespaceTests|ContainerNetworkCreationTests|DsmServiceManagementRepositoryTests|ServiceManagementModelTests|SynologyPhotosModelTests'` 共 124 项通过；新增开启能力到快照及模型创建调用的验证，同时保留默认关闭零请求断言。
- 可提交测试包以 `LANSTASH_BUILD_NUMBER=14` 重新打包，实际应用标识已核对为既有独立 localtest 标识，构建号 14；Xcode Release arm64、签名、实际组件加载和 DMG 校验通过。完整表单绘制增加名称为 test 的自动配置开放场景，12 组中英/浅深绘制通过，已核对按钮可用且无旧限制提示。未安装/启动应用、未在真实 NAS 创建网络，临时构建与合成截图清理，旧包保留。

- 三项反馈合并修复：`swift test --package-path apple --jobs 4 --filter 'ContainerNetworkCreationTests|DsmServiceManagementRepositoryTests|ServiceManagementModelTests|SynologyPhotosModelTests'` 共 120 项通过。新增项目空对象/ID 键值/畸形兼容、自动和手动网络参数、未开启零请求、校验和重名拦截、并发单次写入、取消前零写入、结果不明只回读等回归。
- 合并修复及日志对齐版使用既有 `package.sh` 独立临时签名流程完成 Xcode Release arm64 构建，1.0.3（13）；签名、Sparkle 实际加载与 DMG 校验通过。未安装或启动，网络创建提交仍默认关闭，不含本地磁盘挂载。已复核筛选器/时间列、搜索框/下一列及条数右边缘的合成对齐截图；临时目录在交付前清理。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test新建网络完整表单自动手动双语主题绘制|WorkspacePresentationTests.test容器日志网络正常空失败不可用双语主题绘制' bash tools/codex/run_macos_ui_checks.sh <独立临时目录>`：2 项通过，包含日志/网络/项目 48 组状态绘制、4 组网络展开、8 组自动/手动网络表单，共 60 组。新增表单测试首轮缺少外观环境而失败，补齐测试宿主依赖后通过；检查了手动表单、默认受限表单和隐藏级别标签后的日志截图。

- 用户批准后的详情切片：相同聚焦命令 105 项通过；新增可选详情字段映射、缺字段/错误 IPv6 类型保留未知、旧构造兼容以及仅产生列表读取的断言。详情绘制新增 12 组桥接/host/未知 × 中英 × 浅深主题，原日志/网络 32 组继续通过；额外 4 组原生箭头点击后展开截图，已检查完整网络页展开效果。点击测试等待展开动画结束再截图，确认模型数据不变且未执行写操作。
- 详情版按同一独立临时签名流程重新生成 1.0.3（13）arm64 Release 测试包，签名、Sparkle 实际加载与 DMG 校验通过；未安装或启动，不覆盖旧包。测试用临时构建和合成截图清理，回归测试保留。

- `swift test --package-path apple --jobs 4 --filter 'DsmServiceManagementRepositoryTests|ServiceManagementModelTests|SynologyPhotosModelTests'`：103 项通过；包含官方日志参数/时间用户解析、后页读取、后页空缺失败、网络非空/空/缺字段/错类型、原有删除回读和照片回归。新增测试首轮曾引用不存在的参数帮助函数，已改用项目既有 `requestValue` 并重新编译通过。
- `LANSTASH_UI_TEST_FILTER=WorkspacePresentationTests.test容器日志网络正常空失败不可用双语主题绘制 bash tools/codex/run_macos_ui_checks.sh <独立临时目录>`：1 项绘制测试通过，32 组日志/网络 × 正常/空/失败/不可用 × 中英 × 浅深色。检查了正常日志和失败页面截图，调整了失败状态按钮位置与日志列对齐；合成截图不含真实数据。
- `python3 tools/localization/check_localization.py`、`python3 tools/codex/check_documentation.py`、`python3 tools/request-contract/validate_contracts.py`、`python3 tools/contract-validation/validate_fixtures.py`、`git diff --check` 通过。
- 首轮独立差异复核：未改照片、共享领域模型、权限和持久化；网络计数解析失败会进入已有分区失败状态，不会伪造无关联。日志后页失败不返回伪装完整的部分记录，认证/证书/取消仍沿用原有上抛规则；没有增加写接口或在真实 NAS 执行写入。后续详情切片仅增加上述用户已批准的可选领域字段及显示；IPv6 仅接受观察到的布尔类型，未知或错类型不推断为停用。
- `apple/Apps/DsmMac/package.sh`：以 `LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_BUILD_TYPE=Release`、`LANSTASH_TARGET_ARCH=native`、`LANSTASH_SIGNING_IDENTITY=-`、`LANSTASH_RUN_AFTER_PACKAGE=0` 和独立构建/输出目录运行成功，生成 1.0.3（13）arm64 本地测试包。签名、专用测试权限、Sparkle 实际加载与 DMG 校验通过；未安装或启动，不包含本地磁盘挂载。临时构建与合成截图已清理，测试源码保留。

## PENDING_USER_VALIDATION

- 用户已明确授权开放独立测试包，由用户手动点击创建并确认。建议使用可丢弃的新网络，先验证自动 IPv4、IPv6 关闭的主流程，再按自动/手动、权限拒绝、重名、地址冲突、断网和重复提交逐项验收；记录完整 DSM/套件版本及脱敏结果。IPv6 地址/IP 伪装的完整回读与正式启用仍需补齐证据，不改现有业务网络，不由 Agent 自动执行创建或清理。
- 前置条件：包含此修复的 macOS 构建、同一授权 NAS、正常运行的 Container Manager。
- 操作：分别打开活动记录和网络页，核对活动条数、时间、级别、用户、事件与网络关联数量；展开有连接的桥接网络与空的 host 网络，核对子网、网关、IPv6 和关联容器名称；搜索和级别筛选后清空条件；断网刷新后重连刷新。
- 预期：日志不再整页空白，非空网络显示正确数量，读取失败或不可用有明确说明和刷新入口；照片功能不变。
- 需回传：App/DSM/套件版本、账号权限类别、操作步骤、脱敏错误；不得附主机、账号、凭据或日志正文。
