# DSM 套件管理三端实现计划

> 当前完成情况和验证结果以[当前开发进度](../progress/STATUS.md)为准。本文只维护范围、契约、安全门槛、未完成工作和验收条件。

## 1. 范围

本计划覆盖 Download Station、Virtual Machine Manager 和 Container Manager。目标是在 macOS、移动端与 Windows 上共享同一领域契约、安全门槛和兼容矩阵，同时保持各平台原生界面。

三个模块分别覆盖 Download Station 任务与设置、Container Manager 容器与资源，以及 Virtual Machine Manager 虚拟机生命周期与控制台。各平台具体已实现范围不在本文重复维护。

## 2. 契约与接口优先级

1. Download Station 优先使用公开 `SYNO.DownloadStation.*`。只有能力发现未返回公开接口时，才使用独立的 `SYNO.DownloadStation2.*` 适配分支。
2. VMM 优先使用公开 `SYNO.Virtualization.API.*`。内部 `SYNO.Virtualization.*` 不复用公开接口的参数或响应模型。
3. Container Manager 当前依赖 `SYNO.Docker.*` 内部接口。每个 API、版本和方法必须由运行时能力发现明确返回后才可调用。
4. 未知状态必须原样保留，界面不得将未知值误报为失败或成功。
5. SID、SynoToken、Cookie、DID、下载链接、Tracker、容器环境变量、挂载路径、Registry 凭据、虚拟机控制台凭据和日志正文不得进入分析日志。
6. 容器主列表固定按当前已验证契约提交 `offset=0`、`limit=-1`、`type=all`；映像、网络、项目和活动记录属于附属读取，单项不可用不得遮蔽已成功读取的容器。
7. VMM 主列表优先读取官方 `SYNO.Virtualization.API.Guest`；只有官方读取明确不兼容且内部 Guest 能力同时存在时，才允许只读降级。主列表成功后，主机、存储、网络、映像、保护和日志单项失败不阻断页面；日志 `list` 必须携带网页端要求的筛选、日期和排序参数。各端必须区分“确实为空”和“读取不可用”，登录失效、证书变化与取消仍必须立即上报。
8. 镜像仓库使用已验证的内部契约：`SYNO.Docker.Registry.search` 提交 `offset=0`、`limit=50`、`page_size=50` 和 `q`，`tags` 使用 `repo`；下载由 `SYNO.Docker.Image.pull_start` 提交 `repository` 与 `tag`。三端不得退回未验证的 `pull` 方法。
9. VMM 基础创建和常规修改优先使用 Synology 官方 VMM API Guide 公开的 `SYNO.Virtualization.API.Guest` v1，并配合公开 Task、Storage、Network 与 Guest Image v1；内部 `SYNO.Virtualization.Guest.create/set` 只能作为经版本化验收的降级。控制台使用套件 noVNC 页面与 `synovirtualization/ws/{guest_id}` 通道。会话 Cookie 只注入非持久 WebView，不写入 URL、日志或磁盘。
10. VMM 从 NAS 已有文件创建映像使用公开 `SYNO.Virtualization.API.Guest.Image.create` v1，固定提交 `auto_clean_task=false`、`storage_ids`、`type`、`ds_file_path` 与 `image_name`；提交前复核源文件、存储和名称占用基线，提交后只跟踪返回的稳定任务 ID，以 `Task.Info.get` 终态的 `image_id` 严格核对映像名称和类型，再调用 `Task.Info.clear`。断线与取消不得重放 `create`。映像删除优先使用公开 `Guest.Image.delete`；网络修改和删除没有公开写接口，只允许在内部 `SYNO.Virtualization.Network` 能力存在、当前 DSM/VMM 版本通过契约验收后开放，并保持确认、防重复提交和写后回读。
11. Android 本机映像导入通过系统 `OpenDocument` 取得持久只读授权，先以 File Station 无覆盖上传到用户选择的暂存目录，再沿公开 `Guest.Image.create → Task.Info.get → 映像列表回读 → Task.Info.clear` 完成创建，最后仅按完整暂存文件基线删除临时文件。恢复记录保存在既有加密传输存储；同资料同映像名原子插入并领取，上传、创建或清理处于不明确提交边界时只读核对、不重放。持久结构为向后兼容新增；若回滚到不了解该记录的旧版本，应先让当前版本收敛或清理导入任务。
12. Apple、Android 与 Windows 共用 `VirtualMachineManagerSnapshot` 的保护计划、计划策略、保留策略、日志和分区可用性语义；Android/Windows 实现界面时不得把读取失败呈现为空数据。
13. 下载任务文件使用官方 `SYNO.DownloadStation.Task.create` multipart 契约，文件是正文的最后一个字段；基础设置使用官方 `Info.getconfig/setserverconfig`，计划使用 `Schedule.getconfig/setconfig`，保存后必须回读核验。

## 3. 写操作安全门槛

所有写操作必须同时满足：

- 能力发现与版本范围检查。
- 当前账号权限由 NAS 最终裁决，客户端只显示可恢复提示。
- 单次操作防重复提交，操作期间禁用相关按钮并显示进度。
- 删除、移除下载数据、强制断电等不可逆操作二次确认。
- 能回读的操作必须在完成后重新读取目标状态；回读不一致不得报告成功。
- VMM 异步任务在接入创建、迁移、导入导出前必须增加任务轮询、取消、超时与最终状态核对；任务清理前必须保留稳定任务 ID，断线和取消只允许回读，不得重放写请求。

## 4. 平台计划

### Apple

- `DsmCore` 保持平台无关模型与 `ServiceManagementRepository` 契约。
- `DsmNetwork` 负责公开/内部适配隔离、版本能力发现、写后回读和安全错误映射。
- macOS 使用 SwiftUI 原生列表、工具栏、确认对话框和键盘操作。
- iPhone/iPad 复用共享包；采用导航栈、底部操作栏和分步表单，不压缩桌面表格。

### Android

- 使用 Kotlin/Jetpack Compose 复刻相同领域字段和动作枚举。
- 将公开与内部适配器拆成不同数据源，禁止用一个动态 Map 贯穿界面。
- 使用 Material 确认对话框、WorkManager 长任务和系统安全存储。

### Windows

- 使用 C#/WinUI 复刻相同领域字段和动作枚举。
- 使用 NavigationView、DataGrid、ContentDialog 和系统凭据存储。
- 长任务通过可取消后台任务呈现，窗口关闭前提示仍在执行的高影响操作。

## 5. 后续里程碑

### M2：Download Station 完整功能

- Tracker、Peer、BT 文件选择与优先级。
- BT 搜索模块、类别、搜索结果和直接下载。Apple shared/mobile 与 Windows Domain/Infrastructure/ViewModel/WinUI 已建立官方 `SYNO.DownloadStation.BTSearch` v1 完整闭环，覆盖 `getModule`、`getCategory`、`start`、`list` 与 `clean`；两端均有能力门、会话内隐私、搜索/取消/空态、条件迟到隔离和复用既有单链接创建链。Apple 本机共享聚焦 65/65、全量 675 XCTest（2 跳过）+10 Swift Testing、iPhone 模拟器 11/11；Windows 专项自动化为 26 项。候选提交 `53360d2` 已通过 Apple Build run `31354549813`、Windows Build run `31354549859`、Android Build run `31354549827` 与 Repository Check run `31354549826`，其中 Windows 为 886/886 项 xUnit 且 WinUI x64/ARM64 均 0 警告、0 错误。iPad/真机、Windows/Narrator/键盘和真实 NAS 验收继续后置。
- RSS 站点、条目、下载过滤器。
- 已完成官方基础设置：默认位置、eMule、自动解压、BT/HTTP/FTP/NZB/eMule 限速与计划；继续补齐套件内部的 BT 协议高级设置、监听目录、NZB 服务器、RSS 与通知设置。
- Android 已完成官方任务文件、Tracker、Peer 详情、RSS 站点/条目浏览、RSS 单站点手动刷新和 BT 实际搜索。BT Search v1 通过 `getModule/getCategory` 读取提供方和类别，支持全部、已启用或明确选定提供方、类别、标题过滤、排序字段和方向，并在搜索完成、失败、超时或取消后尝试清理本次临时服务端搜索任务；清理失败不冒充记录已经移除。这不代表 BT 协议高级设置已完成。RSS 条目和搜索结果可经可写目录选择后直接创建任务。RSS 刷新具备目标预检、同站点防重复、写后回读和未确认结果；官方指南未公开 RSS 完整编辑或文件优先级写参数，相关能力与其他高级设置保持关闭并等待版本化契约和真实 NAS 验收。
- Android、Windows 与 Apple 公开 Download Station 路径均使用官方 `SYNO.DownloadStation.Statistic.getinfo` v1 显示当前标准/eMule 上下行聚合字节速率；Apple 既有 `DownloadStation2` 降级路径仍 best-effort 调用内部 `SYNO.DownloadStation2.Task.Statistic.get`。Android/Windows 对缺失、负数或错误类型进入摘要独立错误，Apple 当前兼容字段别名并在读取失败时隐藏摘要；三端都不得让摘要失败遮蔽任务列表，也不得把结果冒充历史流量、单任务速度或传输结果。
- Android 已按官方 `SYNO.DownloadStation.Task.edit` v1 接入单任务保存位置修改：选择可写目录、明确提示可能移动已有文件，写前复核任务与目录完整基线，提交后严格回读，断线和取消不自动重放；该能力不复用 `DownloadStation2`。
- BTSearch 门禁完成后的下一波顺序冻结为：ACT-01 统一活动中心优先；CHAT-03 先补 Apple 单附件 typed outcome 与 Windows 上传/缩略图/下载 typed 契约；NAS-02/NAS-04 有界只读详情可与 Chat 契约并行。RSS、文件优先级、BT 协议高级设置、Container/VMM 高危写不并入该波。

### M3：Container Manager 完整功能

- 容器创建/编辑向导：端口、卷、网络、资源限制、启动策略与能力。
- 容器详情、进程、实时资源、日志流、终端与导入导出。
- 私有 Registry 管理与凭据安全存储。
- 项目 Compose 校验、创建、更新、构建日志和删除。
- 映像导入、导出、更新与清理未使用资源。

### M4：VMM 完整功能

- Android 已使用官方公开 v1 契约完成分步创建与常规设置修改，并覆盖提交前检查、防重复、任务轮询/清理和最终回读；独立 noVNC 控制台仍因 Android 侧稳定契约未验证而关闭。
- 扩展编辑向导：虚拟盘扩容/增删和多网络接口管理。
- 克隆、迁移、导入导出。
- Android 已使用官方 `Guest.Image.create` v1 完成“从 NAS 已有文件创建映像”：有界浏览 NAS 文件、源文件/存储/名称基线、单次提交、任务跟踪、稳定 `image_id` + 名称 + 类型严格回读和终态清理；该 NAS 既有文件流程的任务 ID 只保存在 Workspace，可跨 Activity 配置重建继续核对，断线和取消不重放，但应用进程死亡或重启后的恢复未实现。系统选择的本机文件不使用这条内存边界，而是按第 2 节第 11 项进入既有加密传输存储并支持只读恢复。两条流程的真实格式、权限与 NAS 写入结果均仍待验收。
- 本机文件映像导入已实现；映像编辑、导出与其他未登记来源创建仍未完成。公开映像删除已具备受保护入口，但仍需真实 NAS 验收。
- 快照、保护计划、恢复与保留策略。
- Android 已使用官方 Guest v1 `additional=true` 只读展示磁盘与网卡配置，并使用 Task.Info v1 提供最多 100 项、不含真实任务 ID/内部状态的任务中心。用户可明确确认清理已结束任务：提交前重新读取任务目录，只对用户确认基线中身份仍一致且仍为已结束的目标逐一调用 `Task.Info.clear` v1；无关任务新增或进度变化不扩大清理范围，目标变为进行中时零写。提交异常或取消后只回读一次且不重放。真实任务标识仅驻留当前 Workspace 内存和请求边界，不展示、记录或持久化。该子能力不代表高级硬件编辑、迁移、克隆或完整导入导出已完成。
- Android 创建请求支持总计最多 8 块磁盘、空白盘与映像盘混合、多网卡及空 `network_id` 表示的未连接网卡。空白硬件可按数量、容量和网络归属严格回读；公开 `Guest.get` 不返回磁盘源映像 ID，含映像盘时不能证明来源，因此结果保持需要刷新核对，不写成已确认成功。
- Task.Info 增量刷新仅在任务页可见、VMM 可用且存在未结束任务时每 2 秒执行，仅刷新任务分区；离页、任务终结、Repository/NAS 或代次变化会停止，局部失败保留上次成功摘要。清理仍要求完整已结束基线，进行中目标及漂移目标零写。
- 许可证与 High Availability 状态。

## 6. 验收

- 每个 DSM build、套件版本与权限组合都记录在兼容矩阵。
- 公开 API、内部降级和接口缺失至少各有一组自动化契约测试。
- 所有危险写操作在专用测试目标完成成功、权限不足、重复点击、超时、状态不一致和断线恢复测试。
- 浅色/深色、键盘、触控、VoiceOver/屏幕阅读器、动态文字与降低动态效果均通过平台验收。
