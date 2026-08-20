<!-- doc-role: archive -->
<!-- last-reviewed: 2026-08-20 -->

# Android 对齐历史（第 82–89 批）

本文件收录已停止维护的阶段性账本，用于追溯当时的决策、范围与验证边界。当前状态请查看 `docs/progress/STATUS.md`，未来工作请查看 `docs/progress/ROADMAP.md`。历史中的本地链接已转为纯文本，避免删除源文档后形成断链；其中的测试、构建和环境结论仅代表当时记录，不能推断当前状态。

## 原始账本：`docs/development/ANDROID_WAVE_82_ALIGNMENT_LEDGER_ZH.md`

更新时间：2026-08-05

本账本只记录第 82 批的实施边界，不替代或拆分
`ANDROID_CLIENT_COMPLETION_PLAN_ZH.md` 中的 A0–A8 原目标。完成一个子能力不等于完成父目标，
实体机验收按用户安排保留为未验证。

| 切片 | macOS / 契约证据 | Android 等价语义与移动交互 | 契约依赖 | 安全级别 | 批前验证等级 | 本批决定 | 明确非目标 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A0 深层导航与返回栈 | `apple/Apps/DsmMac/Sources/WorkspaceModel.swift`、`WorkspaceView.swift`、`Tests/WorkspaceNavigationTests.swift`；Android 事实来源为 `WorkspaceRoute.kt`、`WorkspaceShell.kt` 与现有路由测试 | 继续使用 Material 3 顶部返回、系统返回和预测返回；路由只保存模块与无载荷页面层级，不复制路径、会话、任务、查询、镜像或 NAS 标识。配置重建后恢复安全层级，业务对象仍由当前内存领域状态解析 | 不新增 DSM 请求；外部入口仅在当前已认证 Workspace 内执行，并先经过能力门禁 | 中；外部入口按高风险输入处理 | 模块根外部入口与 5 类内部末级路由已有 JVM / Compose 证据，真实进程死亡和真机预测返回未验证 | 审计确认现成且安全的最大固定深页只有 `lanstash://open/containers/registry`。已按“固定枚举 → Containers 根 → Registry 能力门禁 → 无载荷末级页”实现；成功或拒绝后清除 URI，Workspace 未就绪和 Activity 重建保持最新枚举请求 | 不在 URI、SavedState、日志或磁盘保存业务标识；不为“任意业务对象”猜测身份映射；不宣称实机通过 |
| A6 Container 创建/编辑与 Compose | `apple/Apps/DsmMac/Sources/ServiceManagementModel.swift`、`ServiceManagementView.swift`；`docs/api/discovery/endpoints/container-manager-internal.md`、`contracts/private-api/compatibility.json` | 手机端若未来开放，应使用分步表单、可返回草稿、明确确认、部署进度与可恢复结果；当前不得把纯本地文本检查冒充 NAS 校验或部署 | 当前稳定范围只有只读列表与 Registry 搜索/标签；`pull_start`、创建/编辑、Compose 校验/部署和异步任务 Schema 尚未行为验证 | 高；会创建或改写容器工作负载 | observed / degraded，只读自动化；写操作三层零请求关闭 | 本批不新增无真实出口的草稿或假部署入口；保留关闭并记录所需证据 | 不解析静态脚本猜字段，不操作真实 NAS 写接口，不改变兼容结论 |
| A6 VMM 高级管理 | `apple/Packages/DsmCore/Sources/ServiceManagement.swift`、`apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift`；公开 VMM v1 指南登记于 `DSM_WEB_API_REFERENCE_ZH.md`，内部候选见 `vmm-internal.md` | 高级硬件编辑、迁移、克隆、导出应采用独立确认、单次提交、Task.Info 只读跟踪和最终资源回读；手机端使用分步表单而非桌面表格 | 公开 `Guest.set` 当前只覆盖名称、描述、vCPU、内存和自动启动；内部 clone/move/export/image edit 未行为验证 | 高；可能中断虚拟机或产生大文件 | 公开基础创建/设置/映像导入与任务中心已有自动化；高级写候选仅 static / observed | 审计确认没有可安全新增的公开高级写闭环，相关入口继续关闭；同时修正 `Guest.Image.delete` Fixture：公开删除返回空成功，必须由 Image.list 回读，不能误标为 Task.Info 轮询 | 不用公开 v1 参数推断内部 v2，不执行真实生命周期或迁移写操作，不把任务列表等同于高级管理完成 |

## 实施结果

- 修改范围：Android 固定外部路由解析、Activity 待处理枚举、Registry 能力导航及专项测试；VMM 删除映像 Fixture 和精确策略守护测试。
- 未新增可见文案、第三方依赖、权限、Manifest 契约、DSM 请求、持久业务载荷或私有写能力。
- 本地已通过 60 项外部/Workspace/VMM 聚焦 JVM、Debug 与 AndroidTest Kotlin 编译、49 项工具测试、82 份请求 Fixture、13 项请求契约工具测试和 VMM 策略守护。独立复核发现的 VIEW/内部 extra 优先级 P1，以及旧 Bundle、能力后置和同模块根页 3 项 P2 已修复。GitHub [Android Build 31018613142](https://github.com/yuangy1995/dsm-native-client/actions/runs/31018613142) 完成 1238/1238 JVM、Debug/Release/R8、仪器测试 APK、Debug lint 与产物上传；[Repository Check 31018611379](https://github.com/yuangy1995/dsm-native-client/actions/runs/31018611379) 完成仓库门禁。
- A0/A6 父组合目标均未完成，A0–A8 仍为 183/202（90.6%），剩余 19 项。

## 本批共同出口

- 所有新增可见文案同时提供英语和简体中文资源，不在 Compose 中硬编码。
- 返回优先级、能力不可用、加载、空、错误、正常和提交中状态必须可测试。
- 自定义触控目标保持至少 48dp，并使用原生按压、键盘和屏幕阅读器语义。
- 本机只运行聚焦 JVM、Kotlin 编译及轻量静态门禁；完整 Debug/Release/R8、仪器测试 APK 与 lint 交给 GitHub Runner。
- 本批不会因为契约或设备条件不足而删除、拆分或重写 A0/A6 原目标。

## 原始账本：`docs/development/ANDROID_WAVE_83_ALIGNMENT_LEDGER_ZH.md`

## 目标与证据

| 能力 | macOS / 契约证据 | Android 等价语义 | 安全与降级 | 验证等级 |
| --- | --- | --- | --- | --- |
| 套件可用更新提示 | `Package.list` v2 的 `additional.available_operation`；macOS `NasPackage.isUpgradeAvailable` | 仅当服务端明确返回 `upgrade` 时显示“DSM 中有可用更新”，不提供安装或升级按钮 | 缺字段或没有 `upgrade` 时不显示；安装/升级继续关闭 | 源码与合成自动化 |
| 已安装套件图标 | 已登记内部只读 `SYNO.Core.Package.Thumb.get` v1，参数 `name`、`ver`、`size`；macOS 同契约 | 套件行优先显示真实位图，读取或解码失败时使用现有本地图标 | 运行时 v1 能力门禁；认证仅在 Cookie/请求头；2 MiB 流式上限；只接受 PNG/JPEG/GIF/WebP 签名并要求 Bitmap 解码成功；4 MiB 内存 LRU，不写磁盘 | 源码与合成自动化；真实响应未验证 |
| Registry 官方来源标识 | `ContainerRegistryImage.isOfficial` 已由既有 Registry 搜索响应的 `is_official` 解析 | 搜索结果和当前所选镜像详情仅在 `isOfficial=true` 时显示“官方镜像” | 不从 `trusted`、`automated`、Registry 名称或文案推断，不新增请求和写入口 | 源码与 AndroidTest 编译 |

## 交互转换

- 套件更新是非交互辅助信息，不把“存在更新”转化为危险写入口。
- 套件图标是装饰性图片，屏幕阅读器继续读取套件名称、版本、状态和可用操作；加载失败不增加错误噪声，也不遮蔽列表。
- Registry 官方标识使用双语可见文案和屏幕阅读器语义，位于可换行、可滚动内容中，兼容 2× 字体。

## 边界与非目标

- 不实现套件安装、升级、队列、取消或最终版本回读。
- 不持久保存套件图标、响应、认证信息或 NAS 地址；缓存键只按当前 profile、套件 ID、版本和请求尺寸隔离。
- 不把官方来源解释为镜像安全审计、签名验证或可信保证。
- 不改变 A0–A8 原目标或计分口径；三项均完善既有组合能力，当前仍为 183/202（90.6%），剩余 19 项。

## 本地验证

- `:app:compileDebugKotlin` 通过。
- 套件与 Registry 相关 JVM 51/51，通过且无跳过。
- `:app:compileDebugAndroidTestKotlin` 通过；当前没有连接设备或模拟器，设备测试留给用户统一验证。
- 1976 项 Android 双语资源、82 份请求 Fixture、页面五态、触控、动效、写矩阵、49 项工具测试及契约/Fixture 工具全部通过。
- 独立只读对抗复核发现的文档漂移和失败图标重组重复请求两项 P2 已修复，最终无未解决 P0/P1/P2。
- GitHub [Android Build 31022870159](https://github.com/yuangy1995/dsm-native-client/actions/runs/31022870159) 完成 1245/1245 JVM、Debug/Release/R8、仪器测试 APK、Debug lint 与报告/安装包上传；[Repository Check 31022869808](https://github.com/yuangy1995/dsm-native-client/actions/runs/31022869808) 同步通过。

## 原始账本：`docs/development/ANDROID_WAVE_84_ALIGNMENT_LEDGER_ZH.md`

## 目标与证据

| 能力 | macOS / 契约证据 | Android 等价语义 | 安全与降级 | 验证等级 |
| --- | --- | --- | --- | --- |
| VMM 任务页可见期轮询 | 公开 `SYNO.Virtualization.API.Task.Info` v1；既有任务中心与 2 秒增量刷新 | 只有任务页真实可见且存在未结束任务时轮询；切换到其他 VMM 分区或返回根页立即停止 | 不新增请求类型，不持久化任务 token，不把模块可见冒充任务页可见 | 源码与自动化通过；设备未验证 |
| VMM 任务固定深页 | 既有 VMM 任务中心；第 82 批固定无载荷深页规则 | `lanstash://open/virtual-machines/tasks` 只打开任务分区，系统返回回到 VMM 根页 | 只保存目标枚举；严格区分协议与主机大小写，并拒绝查询、片段、用户信息、端口、编码路径、额外层级和业务对象；Task.Info v1 缺失时拒绝 | 源码与自动化通过；设备未验证 |
| NAS 性能固定深页 | 已登记只读 `SYNO.Core.System.Utilization.get` v1；既有性能趋势页 | `lanstash://open/nas-settings/performance` 只打开性能分区，进入后启动既有可见期采样，返回根页后停止 | 只保存目标枚举；迟到回调按代次、NAS、Repository、页签和可见性隔离；不持久化原始响应；能力缺失时拒绝，不新增写入口 | 源码与自动化通过；设备未验证 |

## 交互转换

- 固定深页使用现有 Compose 页面和系统返回，不新增平行页面、弹窗或业务载荷路由。
- VMM 任务轮询归属任务分区可见性，避免用户查看虚拟机、映像、网络或日志时继续产生无关请求。
- 性能采样继续遵守既有暂停、离页停止和错误重试行为；固定入口只决定初始分区，不改变采样契约。

## 边界与非目标

- 不实现任务对象深链、任务 token 持久化、任意 NAS 设置深链或携带 NAS 身份的外部 URI。
- 不实现 VMM 高级硬件编辑、迁移、克隆、导出、noVNC、Container 写操作或新的私有 API。
- 不把固定深页冒充任意业务对象深链、全部深层页、真实进程死亡或真机预测返回验收。
- 三项均完善既有组合目标，不拆分、删除或重复计分；A0–A8 保持 183/202（90.6%），剩余 19 项。

## 验证计划

- 外部 URI 严格解析、Workspace 未就绪、Activity 重建、最新请求覆盖、能力门禁、同模块根页收口和系统返回。
- VMM 任务页进入、切出、未结束任务完成及 Repository/NAS 切换时的轮询启停。
- NAS 性能深页进入、返回和模块切换时的采样启停。
- 聚焦 JVM、Debug 与 AndroidTest Kotlin 编译、双语资源、页面/触控/动效/写矩阵、契约与 GitHub 完整门禁。
- 当前实体机与真实 NAS 行为按用户安排留待统一打包验证。

## 当前验证结果

- 聚焦 JVM 19/19 通过，Debug 与 AndroidTest Kotlin 编译通过。
- 49/49 工具测试、1976 项 Android 双语资源、82 份请求 Fixture，以及页面五态、触控、动效、写操作矩阵和契约检查通过。
- 独立对抗复核发现的同模块根路由未关闭深页、性能迟到回调污染两项 P1，以及 URI 大小写宽松解析一项 P2 均已修复；第二轮复核无未解决 P0/P1/P2。
- GitHub [Android Build 31028760878](https://github.com/yuangy1995/dsm-native-client/actions/runs/31028760878) 完成完整 JVM 1248/1248（0 失败、0 跳过）、Debug/Release/R8、仪器测试 APK、Debug lint 和四组产物上传；[Repository Check 31028761405](https://github.com/yuangy1995/dsm-native-client/actions/runs/31028761405) 同步通过。

## 原始账本：`docs/development/ANDROID_WAVE_85_ALIGNMENT_LEDGER_ZH.md`

## 目标与证据

| 能力 | macOS / 契约证据 | Android 等价语义 | 安全与降级 | 验证等级 |
| --- | --- | --- | --- | --- |
| VMM 电源生命周期 | 官方公开 `SYNO.Virtualization.API.Guest.Action` v1 已登记 `poweron`、`shutdown`、`poweroff`；既有 Repository 已具备状态预检、单次提交和列表回读 | 已停止虚拟机只显示启动；运行中虚拟机显示正常关机与明确的强制关机；其他状态不显示电源操作 | 强制关机使用危险色入口、独立风险确认和写后停止态回读，不改变既有重复提交保护 | 源码与自动化待完整门禁；设备/NAS 未验证 |
| Container 只读边界 | 当前登记的 Container Manager 附属读取均以 v1 为既有基线；日志仍属于内部、可降级读取 | 附属分区和日志只在明确支持 v1 时请求，所有调用显式固定 v1 | 取消、会话过期和认证失败不得吞为分区不可用；概览只保留 `id`、名称与状态，不携带路径、环境变量或其他响应原语 | 源码与聚焦 JVM 通过；真实 DSM 未验证 |
| 下载与照片备份耐久性 | WorkManager 的后台任务必须先有可恢复的本机持久状态；第 69 批已建立加密传输记录 | 下载任务和照片备份来源同步落盘成功后才允许入队；下载持久化失败不启动任务并释放本次新取得的 URI 授权 | 不保存密码、会话或真实路径日志；旧持久记录使用默认字段向后兼容 | 源码与自动化待完整门禁；真实进程死亡未验证 |
| 自动备份扫描上限 | SAF 目录扫描已有 10,000 项有界上限，但旧实现丢弃截断结果 | 超过上限时零部分入队，持久标记需要处理并暂停来源；恢复后提示选择更小文件夹 | 不把部分扫描冒充完整成功，不无界重复扫描；状态字段默认关闭，兼容旧记录 | 源码与聚焦 JVM 通过；厂商文档提供程序未验证 |
| 图片 EXIF 与全屏预览安全区 | Android 系统 EXIF 方向 1–8；项目已启用 edge-to-edge，全屏预览复用于 Files 与 Photos | 预览按 EXIF 完成旋转/镜像，媒体详情使用方向后的宽高；非嵌入预览内容避开安全绘制区和 IME | 使用系统 API，不新增依赖；背景仍铺满窗口，嵌入模式不重复应用 inset | 源码与自动化待完整门禁；HEIF/OEM/真机刘海与 IME 未验证 |

## 交互转换

- VMM 保留 Material 原生动作列表；强制关机不是普通关机的同义入口，必须先解释直接断电及未保存数据风险。
- 自动备份扫描过大时不显示协议或扫描实现术语，只说明没有项目入队以及用户可选择更小文件夹继续。
- 全屏预览继续使用既有缩放、平移、详情和编辑交互；安全区只约束内容，不缩小全屏背景。

## 持久化与兼容

- `PersistedPhotoBackupSource` 增加默认值为 `false` 的 `needsAttention`，旧 JSON 无需迁移即可读取。
- 下载记录与照片备份来源改为同步提交；只有提交成功的记录才能成为 WorkManager 的输入事实来源。
- 本批不改变服务器契约、包名、签名、最低系统版本或第三方依赖。

## 边界与非目标

- 不开放 Container 创建、编辑、Compose 部署、拉取或日志流等未验证能力。
- 不新增 Download Station 私有设置、VMM 高级硬件、迁移、克隆、导出或 noVNC。
- 不把源码修复冒充进程死亡、SAF/OEM、HEIF/MOV、刘海/折叠屏、TalkBack、真实 NAS 写入或实体机验收。
- 本批完善既有组合目标，不拆分、删除或重复计分；A0–A8 保持 183/202（90.6%），剩余 19 项。

## 验证计划

- VMM 状态动作矩阵、强制关机确认、2× 字体可达性以及预检—提交—回读。
- Container v2-only 零请求、显式 v1、取消/认证错误传播与敏感字段投影。
- 下载/备份持久化顺序、旧记录兼容、截断零部分计划、关注状态恢复与 EXIF 1–8。
- Debug、AndroidTest Kotlin 编译、双语本地化、页面/触控/动效/写矩阵和 GitHub 完整 JVM、Debug/Release/R8、测试 APK、lint 门禁。

## 当前验证结果

- 本地 78/78 项聚焦 JVM 测试、Debug Kotlin 与 AndroidTest Kotlin 编译通过；VMM 独立危险操作复核及全量集成终审均未留下 P0/P1。GitHub [Android Build 31036318092](https://github.com/yuangy1995/dsm-native-client/actions/runs/31036318092) 完成完整 JVM 1265/1265、Debug/Release/R8、仪器测试 APK、Debug lint 与产物上传，[Repository Check 31036318979](https://github.com/yuangy1995/dsm-native-client/actions/runs/31036318979) 同步通过。
- 当前未执行实体机、真实 NAS 写入、厂商 SAF、HEIF/MOV、刘海/折叠屏、TalkBack 或预测返回验收。

## 原始账本：`docs/development/ANDROID_WAVE_86_ALIGNMENT_LEDGER_ZH.md`

## 本批目标

- 重新核对第 85 批合并后的源码、计划与 19 个未完成叶子，不删除、拆分或降低任何目标。
- 并行区分可继续编码、需要实体机验收和需要 DSM 私有契约证据的工作。
- 利用已登录 DSM 会话尝试最小化只读观察；不触发写操作，不导出 HAR，不记录主机、Cookie、SID、SynoToken、DID、真实对象标识、路径或响应正文。

## 未完成叶子分类

| 分类 | 数量 | 范围 | 当前处理 |
| --- | ---: | --- | --- |
| 实体机或系统环境验收 | 10 | A0 大窗口；A2 SAF；A3 后台限制与恢复；A4 HEIF/MOV、旋转和媒体库；A8 TalkBack、尺寸/分屏/键鼠与 API 34+ 手势 | 源码与自动化基线已存在，但不能代替真实设备、OEM、DocumentsProvider、系统媒体栈和后台调度验收；按用户安排留待统一打包验证 |
| 公开路由、安全语义与设备混合叶子 | 1 | A0 任意业务对象外部深链、全部深层页面、完整返回栈，以及真实进程死亡/预测返回验收 | 现有固定无载荷入口不泄露业务标识；继续扩展前需定义公开 URI/Intent、对象身份映射、恢复与持久化边界，完成后仍需设备验收 |
| 跨 NAS 安全契约 | 1 | A2 跨 NAS 文件夹移动 | 文件/文件夹复制和文件移动已有有界管道；文件夹移动仍需可验证的冻结或非递归删除能力，不能以现有递归删除补齐 |
| DSM 私有契约依赖 | 7 | A5 Chat 服务器已读；A6 Download 高级设置、Container 详情/资源/日志/终端、镜像拉取、Container/Compose 写入、VMM noVNC 与高级管理 | 没有足够的版本化契约或行为证据，不猜方法、参数和响应；写能力继续关闭 |

当前没有一个未完成叶子能在“无实体机、无新增契约证据”条件下安全勾选。A0–A8 仍为 183/202（90.6%），剩余 19 项。

## 源码与文档核对

- 现有内部强类型深层路由已经覆盖 Files 目录/选择/预览、Photos 文件夹/查看器、Chat 会话、Download 详情、Container Registry、VMM Tasks 和 NAS Performance；`navigateUp()` 对这些路由均有对应收口。
- Container、VMM 与 NAS Settings 的普通页签是同层导航，不应在缺少产品定义时强行变成返回栈层级；携带草稿或危险写状态的对话框也不应伪装成可恢复深链。
- 外部 URI 仍只接受九个固定模块根页，以及三个无业务载荷的固定深页：`containers/registry`、`virtual-machines/tasks`、`nas-settings/performance`。任意业务对象深链仍未实现，且需要单独定义公开 URI/Intent、安全身份映射和持久化边界。
- 跨 NAS 文件夹移动继续安全关闭。现有公开递归删除无法证明复制基线之后没有新增内容，不能以递归删除补齐安全移动语义。

## DSM 只读观察结果

- 已确认 Chrome 中存在可用的已登录 DSM 页面，并在独立观察标签页尝试读取官方页面产生的最小请求元数据。
- 页面与网络调试读取连续超时，未取得可复验的 API 名称、方法、版本、相对路径、参数键或脱敏响应结构，因此不新增端点记录，也不提升任何证据等级。
- 本次没有打开 Chat 未读会话、VMM 控制台、Container 日志/终端/环境变量/挂载等敏感页面，没有触发 DSM 写操作，也没有保存原始网络事件或用户数据。

## 下一步解锁条件

1. Container 资源只读：在 Container Manager 已有容器的总览/资源页，被动确认实际 API、版本、相对路径、参数键与仅含资源指标字段的脱敏成功结构；首次观察只记 `observed`，完整只读响应复验后才可升为 `read-verified` 并实现资源切片。
2. Chat 服务器已读：打开未读会话本身具有写副作用，只能在用户明确授权的专用测试环境中建立精确方法、权限、重复提交保护和写后列表回读证据。
3. Container、Download 和 VMM 写能力：必须使用专用测试目标完成 `behavior-verified`，包括权限拒绝、单次提交、断线/取消不重放、最终回读和副作用清理。
4. VMM noVNC：先只读确认实际 HTML/WebSocket 路径、Origin、子协议和会话边界；Android 开放前还需非持久 WebView、无 JS bridge、外链拦截、关闭清理和实体机验收。

## 非目标与验证

- 不修改 macOS 源码，不以 macOS 私有实现作为 Android 契约。
- 不新增占位 UI、猜测请求、平行 Repository、无调用者抽象或仅为提高进度而拆分计分。
- 本批为只读审计与事实文档纠偏；运行计划计数、差异和文档检查，不以静态审计替代 Android 构建或实体机验收。

## 原始账本：`docs/development/ANDROID_WAVE_87_ALIGNMENT_LEDGER_ZH.md`

## 授权与目标

- 用户于 2026-08-06 明确同意 Android 新增不透明令牌公开深链和本机加密路由映射，并授权按计划继续实现。
- 本批补齐 A0 中可编码的任意业务对象外部深链、完整业务深页到达和返回栈语义；真实进程死亡、预测返回及实体机验收继续如实保留。
- 公共形式新增 `lanstash://open/object/<opaque-token>`。URI 只含随机令牌，不携带 NAS、路径、会话、任务、查询、对象标识或凭据。

## 功能对齐

| 目标 | macOS / 现有 Android 证据 | Android 等价语义 | 安全级别 | 验证等级 |
| --- | --- | --- | --- | --- |
| Files 目录与预览 | Android 已有目录历史、任意路径快捷入口、文件重读和预览返回栈 | 从加密映射恢复目标资料和路径；Repository 重读确认存在后打开目录或预览，返回先关闭预览再沿目录层级返回 | 敏感定位符只在既有加密存储中；URI、Bundle、日志只出现令牌 | 源码、JVM 与 AndroidTest 编译已验证；实体机待验收 |
| Photos 文件夹与查看器 | Android 已有空间隔离、文件夹层级、查看器及预览关闭顺序 | 恢复空间与路径，重读目标后进入文件夹或查看器；错误空间、越界路径或对象消失时不打开错误页面 | 与 Files 相同；不保存完整 `PhotoItem` 或媒体列表 | 同上；公开 File Station 单项重读 JVM 已验证 |
| Chat 会话 | Android 已有会话列表、详情和本地已读覆盖 | 仅在当前 NAS 的刷新列表中找到稳定会话后打开，不从令牌内容猜测会话 | 不保存成员、预览或消息正文 | 同上 |
| Download 任务详情 | Android 已有任务分页列表、详情和任务消失自动关闭 | 仅在当前 NAS 的已读取任务列表中找到稳定任务后打开 | 不保存任务内容、文件列表或下载来源 | 同上 |
| Container / VMM / NAS 固定深页 | 已有 Registry、Tasks、Performance 三个无载荷固定入口 | 继续使用现有 URI，不重复建立对象映射 | 无业务载荷 | 已有自动化，实体机待验收 |

## 持久化、迁移与回滚

- 复用 `SecureProfileStore` 的 Android Keystore `MasterKey` 与 `EncryptedSharedPreferences`；不新增依赖、DataStore、数据库或平行 Keystore。
- 每条记录只保存令牌、资料 ID、强类型目标的最小定位符和创建时间；完整领域对象、显示名、NAS 地址、账号、会话和响应均不保存。
- 同一资料和同一目标重复签发时复用令牌；每个资料保留有界数量并淘汰最旧记录，删除资料或清空安全存储时同步清理。
- 显式退出只撤销会话，不删除映射；重新认证到同一资料后仍可使用。资料不匹配时拒绝，绝不自动切换 NAS。
- 旧版本会把新 URI 当作未知路径安全拒绝；新字段保存在独立加密键中，不改变既有资料、会话、传输和 Workspace 状态 Schema。回滚时旧版本忽略该键。

## 到达、消费与恢复

- URI 解析保持纯函数，只接受固定长度 Base64URL 令牌，拒绝查询、片段、端口、用户信息、编码路径、额外层级和畸形输入。
- Activity SavedState 只保存令牌；解密目标不进入 Bundle。Workspace 未就绪时保留请求，最新外部请求覆盖旧请求。
- 只有目标对象已由当前 Repository 重读确认、模块能力满足且最终页面已经打开，才消费 Intent；加载中和可恢复失败不冒充完成。
- 资料错配、令牌不存在/损坏、对象确定消失和能力不支持属于终态拒绝，使用普通用户可理解的双语提示并清除本次待处理请求。
- 外链到达不恢复筛选、搜索、选择、编辑草稿或危险操作，只恢复用户要查看的业务对象和由该对象派生的正常返回层级。

## 签发交互

- Workspace 顶部栏在当前页面可生成本机链接时显示 Material 原生链接按钮；触控区域至少 48dp，具备双语无障碍名称、按压反馈和成功/失败提示。
- 模块根页和三个固定深页直接复制既有无载荷 URI；六类业务对象页面先同步持久化加密映射，成功后才复制 URI。
- 文案明确说明链接仅适用于这台设备，并且打开时仍需登录对应 NAS；不与 NAS 端公开共享 URL 混用。
- 不新增页面、弹窗、装饰动效或运行时依赖；浅色/深色、键盘、屏幕阅读器、动态文字和降低动态效果沿用 Material 3 与既有顶部栏。

## 非目标

- 不把 Container、VMM、NAS Settings 的普通同层页签变成返回栈层级。
- 不把文件选择、复制/移动、上传、创建、编辑、设置、确认框、终端或其他危险写工作流持久化为外链。
- 不修改 macOS 源码，不改变 DSM API 契约，不以本批开放任何未验证私有 API。
- 本批代码完成仍不能替代真实进程死亡、真机预测返回、浏览器/第三方 App 启动和实体机辅助功能验收。

## 当前验证与进度结论

- 本地 URI、加密模型、路径恢复、照片单项读取与 Download 后页目标聚焦 JVM 23/23 通过；`compileDebugKotlin` 与 `compileDebugAndroidTestKotlin` 通过。
- AndroidTest 已补未知/跨资料拒绝、最新请求覆盖、脏草稿取消、固定/对象签发和 Bundle 仅令牌边界；当前没有连接设备，因此只完成编译，未声称仪器运行通过。
- 两轮独立复核发现的容量、删除竞态、终态唤醒、取消语义、暂态失败、完整分页和确认框签发缺口均已修正；GitHub Android Build `31062270484` 与 Repository Check `31062270513` 已通过，当前只保留实体机验收。
- A0 原叶子同时要求任意业务对象、全部深页、完整返回栈、真实进程死亡和预测返回。本批只完成六类可安全定位对象，未修改目标，也不提前勾选；A0–A8 仍为 183/202（90.6%），剩余 19 项。

## 原始账本：`docs/development/ANDROID_WAVE_88_ALIGNMENT_LEDGER_ZH.md`

- 目标：为已有公开 `SYNO.Virtualization.API.Guest.get` v1 的 VMM Guest 增加独立只读详情页、`ModuleRoot(VIRTUAL_MACHINES) → GuestDetails` 返回层级与不透明对象深链。
- 稳定目标：加密映射仅保存当前资料 ID 与 `guest_id`；URI、Intent、Bundle 和日志仍只允许 32 字节不透明令牌。
- 重读门禁：必须发现官方 `SYNO.Virtualization.API.Guest` v1，按 `guest_id` 单项读取并核对响应 ID；资料、Repository、代次或能力变化时拒绝陈旧结果。
- 交互转换：外链只打开独立只读页；不打开现有含启动、编辑、关机和删除动作的弹窗。系统返回先关闭详情，再回 VMM Machines 根页。
- 可见内容：复用现有 Guest 基础信息与只读硬件投影；加载、错误和正常状态提供重试，不展示内部 ID、API、任务令牌或凭据。
- 安全级别：只读。外链不恢复编辑器、确认框、选中 tab 或任何危险操作；能力缺失、对象消失或 ID 不一致时终态拒绝，暂态网络失败保留重试。
- 非目标：VMM 写操作、noVNC、映像/存储/网络/任务对象深链、Container/套件私有对象、macOS 源码与 DSM 契约变更。
- 验收：Repository 单项重读、路由/返回、opaque 签发恢复、五态/2× 字体与双语资源自动化；真实 NAS 与实体机仍由用户统一验收。

## 完成记录

- 已完成：本地入口、独立只读页、官方 Guest v1 单项重读、加载/失败重试、强类型返回、opaque 签发与恢复、双语和无障碍测试均已接通；原 VMM 写动作入口保持可达，外链永不打开动作弹窗。
- 复核修正：请求前与返回后双重拒绝活跃编辑、确认、mutation target 和在途写状态；严格要求非空 `guest_name`，避免通用资源投影以内部 ID 代替标题；能力缺失时不显示本地详情入口。
- 本地验证：VMM Repository/状态/路由/opaque 聚焦 JVM 通过，`compileDebugKotlin` 与 `compileDebugAndroidTestKotlin` 通过；31 页五态矩阵、49 项工具测试、1985 项 Android 双语资源、触控、动效、写操作矩阵与差异检查通过。
- 云端验证：GitHub Android Build `31064773022` 与 Repository Check `31064773033` 通过；完整 JVM、Debug/Release/R8、仪器测试 APK、Debug lint、报告和安装包上传均由托管 Runner 完成。
- 进度：本批完善 A0/A6/A8 既有组合目标，不拆分、删除或重复计分；A0–A8 仍为 183/202（90.6%），剩余 19 项。真实 NAS 与实体机结论保持“未验证”。

## 原始账本：`docs/development/ANDROID_WAVE_89_MOBILE_SCOPE_LEDGER_ZH.md`

## 决策背景

用户于 2026-08-06 明确要求按移动端实际使用场景重新审计 Android 剩余目标，避免把
macOS 或 DSM Web 的高密度管理能力机械压缩到手机界面。本次只调整 Android 产品范围，
不改变公共 API 事实、Apple/macOS/Windows 计划，也不把未验证能力写成已完成。

Android 的定位是：高频文件、照片、聊天与下载主流程，以及远程观察、任务调度和可回读的
单项处置。需要脚本编辑、终端、批量清理、服务器级协议配置、集群迁移或完整虚拟机编排时，
使用 DSM Web 或桌面端。

## 最终五项的范围结论

1. Chat 服务器未读同步：当前使用已有进程内活动快照安全覆盖旧未读；未发现已读写 API、
   参数与回读关系，不猜测接口，不做全部标记或后台批量回写。
2. Download Station 单文件优先级：公开文件模型没有稳定身份，`Task.edit` v1 没有优先级
   写参数；移动端保留只读展示，不按文件名匹配写入。
3. Container 详情、资源与近期日志：私有端点缺少可复验参数和字段白名单；移动端保留
   容器列表、保守总览与事件分区，详细运维使用 DSM Web/桌面端。
4. 单镜像拉取：`pull_start` 只有静态线索，没有任务、断线及最终回读行为契约；移动端
   保留 Registry 搜索和标签查看，拉取、更新和清理使用 DSM Web/桌面端。
5. 平板 noVNC：缺少稳定页面、WebSocket、认证契约，Android WebView 也没有已证明的
   非持久会话隔离和崩溃清理；移动端保留状态、生命周期与任务中心，控制台使用 DSM Web。

三路独立审计和已登录 Chrome 复核均未取得足以打开上述能力的版本化契约；页面控制可用，
但开发请求元数据读取连续超时，不能把可见控件、静态方法名或 macOS 私有实现提升为 Android
契约。这五项不标记为“已实现”，而是从当前 Android 开发叶子转为“版本化契约后再评估”。
若未来重新开放，写操作仍必须具备稳定目标、单次提交、防重复、取消或断线不重放、最终
回读及专用 NAS 行为证据。

## 已完成的移动端等价目标

- 外部对象入口只覆盖高频且能由当前 NAS 安全重读的七类持久对象。临时编辑页、确认框、
  写操作和无稳定重读语义的页面不提供外链。
- 第 89 批补齐 Photos 共享空间根目录的不透明链接：个人根仍使用固定 Photos 链接；共享根
  只暴露本机加密令牌，打开前通过公开 File Station `getinfo` 重读并核对目录与读权限。
- 跨 NAS 文件和文件夹使用 12 MiB 有界管道。文件可在目标核对后删除源；文件夹只提供
  “复制并核对”，不自动递归删除源目录，避免复核后新增内容被误删。
- Compact/Medium/Expanded、系统字体、TalkBack 语义、预测返回与安全区域的源码及自动化
  目标完成；真实设备行为保留在 A9。

## 明确移出 Android 当前范围的能力

- Download Station：RSS 站点/过滤规则、BT 协议高级设置、监听目录、NZB 服务器、RSS 与
  服务器通知等 NAS 级配置。
- Container Manager：容器终端、容器创建/编辑、Compose 编辑/校验/部署、自动或批量更新、
  未使用镜像清理。
- VMM：高级磁盘/网络编辑、迁移、克隆及完整虚拟机导入导出。现有公开创建、常规设置、
  映像导入、硬件只读摘要和任务中心继续属于 Android。
- 本账本“最终五项的范围结论”列出的服务器已读、文件优先级、Container 详细运维、镜像
  拉取和 noVNC。它们保留重新开放条件，但不再阻塞当前 Android 开发目标。

这些能力不是“Android 已实现”，也不是因契约暂缺而临时隐藏；它们是经用户授权确认的
产品非目标，应在界面需要解释时引导至 DSM Web/桌面端。

## 验证与统计口径

- A0–A8 只统计开发叶子；纯真机、OEM、TalkBack 服务、DocumentsProvider、Doze、重启、
  媒体格式和真实网络矩阵迁入 A9，状态统一为 `PENDING_USER_VALIDATION`。
- 最终范围调整与第 89 批 Photos 共享根实现后，计划脚本应输出 `187/187（100%）`、
  剩余 0 项。
- 第 89 批当前本地证据：Photos/路由相关 JVM 40/40，`compileDebugAndroidTestKotlin`
  通过；独立复核发现的恢复测试伪通过风险已修复。真实外部 App、进程死亡和设备行为仍由
  用户统一验收。
- Android A0–A8 开发目标在自动化和 GitHub 门禁通过后结束；A9 仍单独表示用户尚未
  完成的真实设备与真实 NAS 发布验收，不能由 100% 开发完成率替代。

## 文件所有权与非目标

- 本批功能源码：`android/**`。
- Android 计划与进度：`docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md`、本文及
  `docs/progress/STATUS.md`。
- 不修改 `apple/Apps/DsmMac/**`，不以 macOS 私有请求作为 Android 契约。
- 不修改当前由其他任务占用的根 `AGENTS.md`、macOS 复制主计划、Windows 专项计划和
  Apple Mobile 专项计划。
