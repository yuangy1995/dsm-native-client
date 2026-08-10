# Windows / Apple 移动端功能对齐账本：第 0 波

> 状态：基础拆分、Apple M1、M2-C、M3-A 大目录浏览、M3-B 服务端排序筛选、FILE-02 只读位置导航、FILE-07 分享链接、FILE-08 图片/PDF/文本/音视频只读预览、M4-A1 文件系统照片库、PHOTO-01 用户主动有界时间线、M5-A1a Chat 只读闭环、M6-S0 Download Station、M7-A NAS 健康、M7-B1a VMM 官方虚拟机清单、M7-B2 Container 实例清单与 SET-01 本地设置闭环已通过；Windows W1、W2 文件/传输、FILE-02 只读位置导航、FILE-07 分享链接、FILE-08 预览、W3 文件系统照片库/Chat、PHOTO-01 用户主动有界时间线、W4 Download Station、W4-B0 VMM 官方只读、W4-A Container 实例清单与 SET-01 本地设置源码已收口，GitHub Windows CI 的 691 项 xUnit 与 x64/ARM64 Release 构建已通过，目标设备验收后置
> 基线提交：`21172ac`（`docs: 完善跨平台复制计划`）
> 范围：Windows `W0/W1/W2-A/W2-B/W2-C0/W2-C1/W2-D0/W2-D1/W3-A0/W3-A1/W3-A2/W3-B0/W3-B1a/W4-DS0/W4-DS1/W4-B0/W4-A/FILE-02/FILE-07/PHOTO-01/SET-01`、Apple 移动端 `M0/M1/M2-A0/M2-B/M2-C/M3-A/M3-B/M3-C1/M4-A1/M5-A1a/M6-S0/M7-A/M7-B1a/M7-B2/FILE-02/FILE-07/PHOTO-01/SET-01`
> 禁止范围：`android/**`、`apple/Apps/DsmMac/**`

## 1. 账本口径

- `完整`：源码、聚焦自动化及目标平台构建证据均覆盖该用户结果；需要真实设备或真实 NAS 的项目仍可另记 `PENDING_USER_VALIDATION`。
- `部分`：已有真实主流程，但范围、状态、错误恢复、自动化或平台构建证据不完整。
- `占位`：存在页面或模型，但尚不能完成计划中的用户结果。
- `关闭`：当前范围明确不开放，入口不可见、只读或由能力门保护。
- `BUILD_VERIFIED` 只能由目标平台的真实构建结果取得；macOS 上的静态阅读不能替代 Windows x64/arm64 构建。
- `PENDING_USER_VALIDATION` 只用于已进入当前核心/受限范围且必须依赖真机、签名、系统权限或真实 NAS 的验收，不用于把“当前不做”或“后续”伪装成待验收功能。

## 2. 本波文件所有权

| 热点 | 本波 owner | 其他 agent 约束 |
| --- | --- | --- |
| Windows Domain / Repository 机械拆分 | Windows 基础 agent | 不修改 App、资源、工程、文档 |
| DsmMobile `Sources/**` 与 `Tests/**` 机械拆分 | Apple M0 agent | 不修改共享 Package、资源、工程和 macOS App |
| 本账本、共享资源、工程文件、最终集成 | 主 agent | 串行修改并独立复核 |
| macOS 业务语义证据 | 只读审计 agent | 不修改任何文件 |

## 3. Windows W0/W1 对齐账本

| 用户结果 | macOS 证据 | Windows 当前证据 | 状态 | 交互转换 | 安全 / 契约依赖 | 本波验证与下一出口 | 明确非目标 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 保存多个 NAS 资料并连接 | `apple/Apps/DsmMac/Sources/LoginViewModel.swift`、`LoginView.swift` | `AppViewModel.cs`、`LoginPage.xaml`、`ShellPage.xaml` 已加入可取消连接和已连接状态下的 NAS 切换/新增/移除；每次连接冻结 profile、密码、OTP 与记住密码选择，并以 attempt gate 阻止旧任务回写 | 部分：源码完成且 Windows x64/ARM64 云端构建通过，真机交互未验证 | WinUI 表单与原生 `MenuFlyout`；44 px 主操作和 Narrator 名称；连接期间锁定完整表单，仅保留取消 | Credential Locker；切换仅断开本地工作区，显式退出才远程 logout；密码不得进入 Cloud Files | 纯状态与源码契约护栏已写，双语资源/硬编码/XML、691 项 xUnit 与 x64/ARM64 Release 构建通过；仍需真机交互 | 不改变包身份、签名或持久化格式 |
| QuickConnect 解析但保留原始 NAS 身份 | macOS `AppModel` 连接流程及共享 `DsmQuickConnectResolver` | `DsmConnectionResolver.cs`、`DsmQuickConnectResolver.cs`、`AppViewModel.cs` | 部分 | 在连接状态中显示通俗的连接方式，不暴露内部路由字段 | 发现阶段不得发送登录凭据；relay 只走系统信任 | 需要聚焦测试覆盖身份不匹配、取消、回退 | 不复制私有请求或猜测字段 |
| OTP、会话恢复与退出 | `LoginViewModel.swift`、`ConnectionFlowTests.swift` | `AppViewModel.cs`、`CredentialSessionStore.cs`、`CredentialPasswordStore.cs`；连接/恢复均传递取消令牌，只有明确认证失败才清保存会话，临时网络错误保留会话且不回退密码登录 | 部分：取消、恢复与切换语义已落源码且 Windows x64/ARM64 云端构建通过，真机会话未验证 | Windows 保持系统密码库与明确的重新登录路径 | SID、Token、密码分离；取消不删除资料/密码/会话；退出与切换 NAS 分离；每个关键异步边界检查当前 attempt | 纯状态及源码契约护栏与 Windows CI 已通过；仍需真机会话过期/profile 导航验证 | 不把会话或密码写入诊断 |
| 自签名证书首次核对与变化阻断 | macOS 连接流程、共享 `DsmCertificateTrust.swift` 与对应测试 | 当前未发现等价的完整 Windows 用户核对闭环 | 占位 | 使用 ContentDialog 展示通俗风险说明，技术指纹置于次级信息 | 结构/有效期合格的叶证书；按 profile pin；系统信任优先 | 独立 Auth/证书切片及旧/新指纹测试 | 未验证时不得静默信任 |
| 能力不可用有原因和下一步 | macOS `WorkspaceModel.swift`、服务与管理模型 | `DsmRepository.AvailableModules`、`WorkspaceViewModel.cs` | 部分 | NavigationView 中保留模块位置并显示可恢复空/错误状态 | 固定 API 版本、typed response、用户安全错误映射 | W1 建立 `ModuleAvailability`，不能仅靠隐藏入口 | 不向普通用户展示 API/build 术语 |
| 只读浏览共享目录与文件夹 | macOS `FileWorkspaceModel.swift` 与文件页面只作为业务语义来源 | 新 `FileBrowserViewModel`、`FilesPage` 已接入 Shell：共享根、进入目录、面包屑、返回/上一级、刷新、真实 offset/limit 加载更多、列表/网格与五态；同一 Shell 内缓存页面状态 | W2-A `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | Fluent `BreadcrumbBar` + `CommandBar` + List/Grid；Alt+Left 返回，Enter/双击实际目录打开；44 px 操作目标 | 仅调用公开列表契约；generation+取消阻止旧导航回写；跨页按完整路径去重；offset 错位或零进展稳定失败 | 行为与源码契约测试已写，本地化/XML 检查及第二轮独立复核通过；Windows CI 构建已通过；仍需真实大目录只读验证 | 不开放创建、重命名、删除、完整递归搜索或 Cloud Files；普通上传下载由独立切片提供 |
| 服务端排序与类型筛选 | macOS 文件工作区仅作为“结果应覆盖完整目录而非当前已载页”的语义参考 | `FileListOptions` 已贯通 Domain、Repository、浏览缓存与 Files 页：普通目录支持名称/大小/修改日期、升降序、全部/仅文件/仅文件夹；共享根固定名称与全部，仅保留方向；分页、历史和缓存键包含有效条件 | W2-B `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | 原生 `MenuFlyout` + `RadioMenuFlyoutItem`；共享根禁用不适用项；清除筛选同时恢复全部类型；双语 Narrator 名称和 44 px 目标 | 使用公开 List 参数白名单；不发送 `pattern`/`search_type`；每次条件变化从 offset 0 开始，旧 generation 不得回写 | 契约、状态模型和 UI 三阶段只读复核均为 P0/P1=0；Windows 双语资源 352 项、本地化/XML/diff 检查通过；Windows CI 构建已通过；仍需真实大目录分页验证 | 不把已载页本地排序冒充完整排序；不新增私有搜索参数、持久化 schema 或 Cloud Files 依赖 |
| 普通前台单文件下载与 Activity | macOS 下载只提供“用户选择目标、失败不破坏原文件”的业务语义参考 | `SafeFileDownloadService`、`ForegroundTransferCoordinator`、路径型 `FileSavePicker`、同目录 staging 事务目标与 Activity 已接入 Files/Shell：零字节零 Range、4 MiB 有界读取、单块允许无强 ETag、多块固定强版本与总长度、精确任务取消、按 profile/generation 隔离 | W2-C1 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | 普通文件可见“下载”和 `Ctrl+S`；系统 SavePicker 只返回路径，不预先清空旧目标；Activity 显示当前 NAS 的进度、完成、失败、取消 | 复用 W1-R typed Range；目标同目录唯一 staging，全部下载与 staging Commit 成功后才 Move/Replace；失败/取消清 staging；不依赖 Cloud Files | 基础行为与 UI/源码契约测试已写；首次复核发现 legacy picker P0 与两个竞态，修复后二次复核 P0/P1=0；双语资源 319 键通过；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含上传、批量、暂停/续传、后台、跨重启恢复或 Cloud Files；staging 删除失败诊断与真机残留核对后置 |
| 普通前台单文件上传与 Activity | macOS 上传仅作为“用户明确选择、一次提交、结果回读”的业务语义参考 | `SYNO.FileStation.Upload` v2 精确 multipart、有界流式正文、调用方持有 Stream、`MutationResult` 提交边界与分页同名/大小回读已贯通；路径型 `FileOpenPicker`、Files 上传入口和 Activity 已接线 | W2-D1 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | 当前真实目录显示“上传”和 `Ctrl+U`；系统单文件 Picker；Activity 显示进度、明确失败、提交前取消或“请核对结果” | 默认 `overwrite=false`；`SendAsync` 后取消、断网、非成功响应或解析未知均禁止重放；只有回读同名普通文件且大小一致才确认成功 | D0 契约两轮复核与 D1 UI 独立复核 P0/P1=0；双语资源已随 W2-B 合计 352 键，取消按钮按文件名提供 Narrator 标签；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含多文件、覆盖、暂停/续传、后台、自动重试或跨重启恢复；中文/特殊 Unicode 文件名兼容需真机 NAS 验证 |
| FILE-07 单对象分享链接 | macOS 仅作为“用户明确选择一个对象、创建一次、确认后复制或系统分享”的业务语义参考 | Files 已接单个文件或文件夹的官方 Sharing v3 创建：可选密码、无到期或 7/30/90 天；写前完整基线、一次提交与独立写后回读；仅唯一新稳定 ID、精确路径、密码状态和到期日均一致时暴露 URL | FILE-07 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | 原生 ContentDialog、可见字段标签、44 px、Narrator 与 live region；确认后可复制；当前 unpackaged 构建的系统分享保持禁用并给出说明 | Sharing v3 + FileStation List v2 + FORM 能力门；严格 native JSON、offset/total、路径与绝对 HTTP(S) URL；提交后取消/断线/解析失败只独立回读且绝不重放；需核对按当前 profile/path 阻断再次创建；剪贴板必须确认历史和漫游均被禁用 | B0 与 B1/B2 均经独立复核；四项 UI P1 和两项 P2 已关闭；双语资源总计 725 键，本地化/XML/diff 门禁通过；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含批量、分享管理、撤销/删除、二维码、提前生效日期或密码复制；系统分享在 unpackaged interop 真机验证前不开启 |
| FILE-08 文件预览 | macOS 仅提供图片/PDF、纯文本和系统媒体播放的用户语义；不复用其 App 层非严格 Range 实现 | Files 已接只读文本、图片、PDF、音频和视频预览；文本最多读取 512 KiB+1，图片/PDF 使用 128 MiB 上限的事务临时 artifact，媒体使用原生 `MediaPlayerElement` 与严格随机 Range，不把 DSM URL 或凭据交给播放器 | FILE-08 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | 宽窗列表+预览 pane，窄窗同页详情；Enter/双击打开，Alt+Left/Escape 关闭；原生 Image/PDF/Media 控件、44 px 与 Narrator；保存副本沿用用户主动 Picker | 专用 profile-bound 只读 Repository；每段≤4 MiB，较大媒体首段强 ETag、后续固定版本+总长；seek/clone/关闭 generation 隔离；随机临时文件且展示释放后才删除 | 独立终审关闭游标迟到、保存对象错配和 presenter/artifact 清理三项 P1，最终 P0/P1=0；双语资源 640 项及 XML/本地化/diff 门禁通过；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含编辑、覆盖保存、转码、WebView、外部 DSM URL、后台播放/恢复、Cloud Files 或任何 NAS 写操作 |
| 文件系统照片库与用户主动有界时间线 | macOS Photos 仅提供“个人/共享空间、文件夹相册、缩略图、导出与本地时间线筛选”的用户语义；不复制智能相册或后台索引 | W3-A 保留文件夹浏览；PHOTO-01 在同一专用 `PhotosPage` 加入 Folders/Timeline 切换：用户明确启动前台 BFS 扫描，按 `createdAt ?? modifiedAt` 月份分组，本地文件名搜索与图片/视频筛选，复用缩略图和保存副本 | PHOTO-01 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | Fluent 模式切换、SearchBox、筛选、虚拟化分组 Grid；显式扫描/取消/刷新，空、筛选空、错误、部分、截断和刷新失败均有下一步 | 只用公开 File Station List/Thumb；固定上限为 2,000 文件夹、50,000 原始项、10,000 媒体、每页 200；严格 offset/total/原生类型/根边界；跳过 `@*` 与 `#recycle`；零 Search/Foto/后台/持久化/NAS 写 | typed 契约、状态、页面与源码测试已写；双语资源总计 758 键、本地化/XML/diff 门禁通过；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含服务端/全库搜索、人物/地点/标签、真正相册、EXIF、导入、移动、删除、恢复、私有 Foto API、Cloud Files 或后台索引 |
| Chat 只读会话与消息闭环 | macOS Chat 只作为会话、历史消息与向前分页的业务语义来源；不复制发送区、附件动作、右键菜单或实时常驻 | W3-B0/B1a 已接专用 `ChatPage`：按 profile 读取会话、本地筛选、选择普通非加密会话、消息首屏/刷新/原始 cursor 加载更早；加密会话只显示说明，旧 Workspace Chat 路径已移除 | W3-B `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | Fluent 常规宽度双栏、窄窗会话列表→消息详情；Alt+Left、Ctrl+F、F5；五态、只读提示、44 px 与 Narrator 参数化未读语义 | 内部 API 仅在 User v1–3、Channel v1–5、Post v1–8 与运行时能力范围相交时启用，并固定到已记录最高交集版本；根数组/对象容器、数字 ID、跨会话消息和原始 offset 均有严格契约；无发送、附件读取或实时连接入口 | Chat 契约 22 个测试方法/28 个 case 与状态/UI 测试源码已写；版本门、真实 HTTP 根数组、筛选/刷新竞态、不可用刷新路径经独立复核最终 P0/P1/P2=0；双语资源总计 439 键，静态门禁通过；Windows 691 项 xUnit 与 x64/ARM64 Release 构建已通过 | 不包含发送、草稿、新建单聊/群聊、附件操作、加密正文、已读回写、Socket、轮询、通知或任何管理写 |
| Download Station 官方只读任务闭环 | macOS Download Station 仅提供任务状态、进度与活动速率的用户语义；创建、控制、删除和设置不直接迁移 | W4-DS0/DS1 已建立仅官方 `SYNO.DownloadStation.Task/Statistic` v1 的 typed 契约与专用 `DownloadStationPage`：真实 offset/total 分页、活动速率、搜索/状态筛选、任务详情、刷新与加载更多；Shell 缺少前置时显示专用不可用页，绝不回退旧 Workspace 或内部 DS2 | W4 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | Fluent 常规宽度双栏、窄窗列表→详情；F5、Ctrl+F、Alt+Left；六态、只读提示、44 px 与 Narrator 汇总 | 官方能力必须包含 v1；`additional=detail,transfer`；错误来自 `status_extra` 但只显示通俗说明；原始分页严格校验；Statistic 失败与任务页隔离；DS2-only 零请求 | 契约、状态和页面测试源码已写；W4-DS0/DS1 多轮独立复核最终 P0/P1/P2=0；旧 `IDsmRepository` 下载读写与 DS2 adapter 已移除；双语资源总计 507 键，GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含创建、暂停、继续、删除、设置、RSS/BT 高级操作、内部 DS2 写或自动重试；这些不是 `PENDING_USER_VALIDATION` |
| VMM 官方 v1 只读资源闭环 | macOS VMM 只提供虚拟机与资源摘要的业务语义；内部接口、日志、保护、控制台和写操作不直接迁移 | W4-B0 已建立 `IVirtualMachineManagerRepository` 与专用页面：仅公开 `SYNO.Virtualization.API.Guest/Host/Storage/Network/Guest.Image` v1，机器为主区，主机/存储/网络/映像独立可用、不可用或失败；Shell 严格校验 profile 且绝不回退 Workspace | W4-B0 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | Fluent 常规宽度双栏、窄窗列表→详情；F5、Alt+Left、44 px、Narrator 与五分区五态 | Guest v1 是模块主门；所有请求固定公开 v1/list；缺能力零请求；稳定 ID 缺失/重复时分区失败；无内部 fallback、伪造 ID 或原始错误文案 | 契约、ViewModel、页面和 Shell 源码护栏已写；独立复核 P0/P1=0；双语资源 565 项、本地化/XML/diff 门禁通过；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建 | 不包含 Container、VMM 电源/删除/网络或映像写、保护、日志、控制台或内部 API；这些不是 `PENDING_USER_VALIDATION` |
| SET-01 本地设置闭环 | macOS 仅作为“语言、外观与本机偏好不写回 NAS”的业务语义参考 | 专用 `AppSettingsPage` 已统一语言、system/light/dark 主题、可选模块可见性、已注册照片缩略图内存清理与隐私说明；系统 Settings 齿轮是唯一入口，主题和模块偏好先持久化成功再发布 | SET-01 `SOURCE_REVIEW_PASSED` / `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64` | 原生 ComboBox、Toggle、Button 与 InfoBar；主题在窗口根即时应用；隐藏当前可选模块安全返回设置页；44 px、键盘与 Narrator 语义齐全 | 偏好仅保存在本机；可见模块为本机偏好与当前 NAS capability 的交集；缓存清理只触及当前注册的进程内照片缩略图，不触碰 Cloud Drive、资料、凭据、传输、预览或用户文件；本地存储无权限/损坏安全回退 | 双语资源 686 项、本地化/XML/diff 与独立终审通过，最终 P0/P1=0；GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建；NAS Health 取消和 scheduler 交错仍需真实 Windows 行为验证 | 不包含 NAS 设置写入、偏好跨设备同步、诊断导出、Cloud Drive 清理、资料/凭据/会话/用户文件清理或新增语言 |
| 写操作呈现成功、部分成功、拒绝、未知与复查结果 | `WorkspaceMutationFeedbackTests.swift`、共享 `MutationResult.swift` | Windows `MutationResult.cs` 及现有测试；页面尚未全面接入 | 部分 | InfoBar / ContentDialog 呈现结果及下一步 | 危险写确认、权限检查、重复提交保护、一次提交、最终回读 | 先接一个低风险和一个高风险试点，再迁移其余写操作 | 不为假设故障堆叠 fallback |
| 严格分段读取 | macOS/Apple 共享下载契约只作为安全语义参考 | `FileRangeReadResult` 已贯通 `IDsmRepository`；严格 206/Content-Range/长度/总长，强 ETag + `If-Match`，非法范围在发请求前拒绝 | W1-R 源码与契约审查通过 / Windows 691 项 xUnit 已通过 | 无直接 UI；旧 `byte[]` 消费方在 W1-C 前对部分区间安全失败 | 首段强 ETag、总长度与每段一致；412/弱响应版本/短长响应均稳定失败 | 23 个测试方法、26 个用例已纳入通过的 Windows xUnit；真实 DSM 验证前不得默认开放多段水合 | 不从路径、时间戳或本地缓存猜测内容版本 |
| Windows Cloud Files 只读水合 | macOS 桌面云盘只提供用户目标与只读语义参考 | 默认能力门关闭且初始化不注册、连接或注销既有同步根；实验路径只接受从 0 开始、单次覆盖完整文件、最大 64 MiB、全段同一强版本与总长度，全部缓冲验证后才一次提交 | 关闭：安全源码与 Windows x64/ARM64 云端构建已通过 / Explorer 真机未验证 | Explorer 原生占位体验后置；当前 App 不开放添加、恢复、显示位置或开机注册 | 禁止部分水合和无强版本提交；取消只在覆盖完整待处理范围时终止；失败提交有效范围且仅一次 | 合成测试已纳入 691 项 xUnit，Windows x64/ARM64 编译通过；Explorer/Office/Win32 创建写入截断矩阵通过前保持关闭 | 不自动注销旧同步根；不宣称大文件、部分读取或本地只读隔离已可用 |
| 按领域独立演进 | macOS 已按 Workspace、Photos、Chat、Services、NAS 管理分文件 | 原 `Models.cs` 已拆到 Auth、Transport、Shell、Files、Downloads、Services、Chat、NasAdmin、Repository；`DsmRepository` 已拆到七个 Feature 文件，兼容 facade 保留 | 源码出口通过 / Windows x64/ARM64 云端构建通过 | 不改变用户交互，仅建立功能目录 | 公共 namespace、类型名、方法签名和请求体保持不变 | 公共声明集合及各方法体机械对比零差异，`git diff --check` 与 Windows x64/ARM64 云端编译通过 | 本波不新增功能/API/资源键 |

最终正式提交云端验证状态：提交 `b0f0334` 的 GitHub Actions `Windows Build` 运行 `31301134782` 通过 691 项 xUnit，并完成 WinUI x64 与 ARM64 Release 构建，0 警告、0 错误；`Apple Build` 运行 `31301134776` 通过 636 项 XCTest（2 项按环境跳过）、Swift Testing、iPhone/iPad 通用应用构建与 macOS 回归打包；`Android Build` 运行 `31301134788` 完成单元测试、Debug、Release、R8、仪器测试 APK 编译与 Debug lint；`Repository Check` 运行 `31301134780` 同步通过。这些证据不替代真实 Windows 10/11、iPhone/iPad、系统选择器、Explorer、剪贴板、媒体播放、无障碍、高 DPI 与真实 NAS 的 `PENDING_USER_VALIDATION`。

## 4. Apple 移动端 M0/M1 对齐账本

| 用户结果 | macOS 证据 | iPhone / iPad 当前证据 | 状态 | 移动端替代 | 安全 / 契约依赖 | 本波验证与下一出口 | 明确非目标 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 多 NAS 资料、连接、OTP、恢复与退出 | `LoginViewModel.swift`、`LoginView.swift`、`ConnectionFlowTests.swift` | 已支持明确取消、已连接 profile 菜单、本地切换/新增/删除、单独退出；切换不调用远程 logout；一次连接冻结 profile、账号、密码、OTP 与本地保存选择 | M1 通过 | iPhone/iPad 使用原生 Menu/确认框；连接按钮在进行中变为取消；切换与退出分离 | Keychain；profile 隔离；QuickConnect 原始身份保留；关键异步边界同时检查任务取消和 attempt ID | iPhone/iPad 各 25/25；独立第二轮安全复核确认跨目标凭据与旧任务回写 P0/P1 均关闭 | 不建立多 Scene 或新的持久化 schema |
| iPhone 五个顶层入口 | macOS `WorkspaceSection` 仅作业务语义来源 | 已建立 `MobileTopLevelDestination`：文件、照片、聊天、活动、更多；活动承载传输与下载，更多承载受限摘要和设置 | M0 通过 | 原生 `TabView`；每个顶层入口拥有 `NavigationStack`，子能力进入活动或更多 | `MOBILE_CORE` / `MOBILE_LIMITED` 清单是唯一范围依据 | 新范围测试已替换“所有 Mac 模块均应出现”的旧断言；M1 继续补独立路径和 profile 隔离 | Container/VMM 写管理、桌面云盘、后台常驻传输不作为顶层入口 |
| iPad 单窗口自适应工作区 | macOS `NavigationSplitView` 只提供信息结构参考 | 常规宽度使用五入口 `NavigationSplitView`，紧凑宽度使用同一目标集合的 `TabView`；顶层/模块选择按 profile 隔离；文件预览在常规宽度进入 Inspector，并可在同一窗口全屏 | 部分 | Sidebar + 内容；宽度不足时折叠；文件导出/分享使用系统自适应 sheet/popover；图片/PDF 使用详情区或全屏 | 当前进程内状态按 profile ID 隔离；预览切换 profile 会取消并清理独占临时目录；不新增 Scene 状态 | 源码范围已覆盖 FILE-02/07/08、PHOTO-01、Container/VMM 与 SET-01 的 iPad 自适应路径；M3-B 前 iPad Air 11-inch (M4) iOS 26.5 模拟器全量 82/82，之后尚无最新完整 iPad Simulator 结论；实际分屏、旋转、最大动态文字、VoiceOver 和系统面板列入用户验证 | 当前不新增独立窗口或多窗口状态 |
| FILE-07 单对象分享链接 | macOS 仅作为“创建一次并在确认后交给系统分享”的业务语义参考 | Files 单项菜单已接官方 Sharing v3：文件或文件夹、可选密码、无到期或 7/30/90 天；确认后可复制或打开系统分享；iPhone 使用 sheet，iPad 使用系统自适应 sheet/popover | FILE-07 通过 | 原生 Form/secure field/Picker/结果页；普通用户只看到创建结果与下一步，不显示协议、原始错误或内部 ID | 完整写前列表基线、同路径 actor 锁、一次 create、独立完整写后回读；仅唯一新 ID、路径、密码与到期日一致且 URL 合法才确认；未知结果按 profile/path 阻断重放；密码不进入剪贴板或系统分享 | 分享链接模型/展示/集成等五套聚焦 39/39，DsmMobile 全量 288/288；共享 Package 全量 612 XCTest（2 跳过）+10 Swift Testing；独立终审 P0/P1/P2=0 | 不包含链接管理、撤销/删除、批量、二维码、提前生效日期或后台创建；真实 NAS 字段与权限仍待专用环境验证 |
| 文件系统照片库与用户主动有界时间线 | macOS Photos 仅作为照片空间、浏览、导出与本地时间线筛选的业务语义参考 | M4-A1 保留文件夹浏览；PHOTO-01 新增显式前台时间线扫描、本地文件名搜索、图片/视频筛选、月份分组、部分/截断提示，并继续复用预览、存储副本和分享 | PHOTO-01 通过 / iPad 与真实 NAS 待验收 | iPhone 使用模式切换、搜索和自适应网格；iPad 沿用空间侧栏与同一窗口网格/Inspector，不新增窗口；扫描中可取消，刷新失败精确保留旧快照 | 只读公开 File Station；`.mobileDefault` 固定 2,000/50,000/10,000/200，旧 Mac API 继续 `.legacyDefault`；BFS 根包含、跳过 `@*`/`#recycle`、严格分页；profile/repository/canonical item 门；零 Search/Foto/后台/持久化/NAS 写 | Apple 共享时间线契约聚焦 17/17、共享 Package 621 项 XCTest（2 跳过）+10 项 Swift Testing、DsmMac 无签名构建通过；iPhone 时间线与照片回归 58/58。iPad/真机未运行，不宣称通过 | 不包含服务端/全库搜索、智能相册、人物/地点/标签、EXIF、PhotosPicker 导入、移动/删除/恢复、自动备份或独立窗口 |
| Chat 只读会话与消息闭环 | macOS Chat 仅提供会话、历史消息和分页的用户语义；桌面输入区、右键菜单、附件动作和实时常驻不直接迁移 | M5-A1a 已接只读模型与专用界面：会话列表、本地筛选、非加密消息首屏/刷新/加载更早；iPhone 层级导航，iPad 常规宽度双栏；退出/删除资料清明文缓存，本地切换 profile 保留内容缓存但不保留旧 session repository | M5-A1a 只读子切片通过 / M5 文字写闭环未完成 | 触控下拉刷新、系统返回、只读说明；附件只显示元数据，加密会话只给替代路径；无输入区和桌面手势 | `MobileReadOnlyChatRepository` 清空写能力与 realtime，所有写/附件/高级接口零底层调用；会话/消息独立 generation，跨 profile/会话迟到结果受门禁；logout/purge 清正文 | iPhone Chat 模型/展示 31/31；DsmMobile 全量 182/182；独立终审 P0/P1=0。iPad 真实双栏、真 NAS Chat 响应与权限仍待用户验证 | 不包含发送、草稿、新建会话、附件打开/下载、加密正文、前台实时/轮询、已读回写、通知或后台推送 |
| Download Station 移动端安全收口 | macOS 只作为任务状态、进度与详情的业务语义来源；桌面创建、控制、删除与设置不照搬 | M6-S0 已把下载页改为纯只读列表与详情，显示状态、进度、大小、保存位置和通俗错误；URL 创建、暂停/继续确认框及所有写调用均从生产页面和移动模型扩展移除 | M6-S0 通过 | iPhone/iPad 使用原生列表、详情与刷新；用户需要创建或控制任务时转交 DSM 网页或 Mac | 读取继续使用现有 Download Station 快照；移动 UI 零创建、控制、删除、设置符号；模块能力明确标为只读 | 安全测试与 M7 模型/展示合计聚焦 21/21；DsmMobile 全量 203/203；独立复核 P0/P1/P2=0 | 不包含创建、暂停、继续、删除、设置或后台监控；这些是明确移动端取舍，不列 `PENDING_USER_VALIDATION` |
| NAS 健康只读概览 | macOS NAS 管理仅提供系统、当前性能、存储健康与更新检查的业务语义；账号、日志、连接、套件与写管理不照搬 | M7-A 已建立按 profile 绑定的四分区只读模型和自适应页面：系统、当前性能、存储/硬盘、更新检查分别加载、失败和刷新；旧内容刷新失败继续显示；iPhone 分区列表，iPad 常规宽度侧栏+详情 | M7-A 通过 | 触控下拉刷新、通俗健康等级和只读说明；安装更新转交 DSM 网页；不显示序列号、内部 ID、路径、账号、日志或来源地址 | `MobileReadOnlyNasHealthRepository` 只暴露四项读；generation/profile gate；退出/删除资料 purge，普通切换保留有界进程内缓存但不保留旧 repository | 正式模型/展示/Download安全聚焦 21/21，DsmMobile 全量 203/203；共享 Package 592 XCTest（2 跳过）+10 Swift Testing；DsmMac 无签名构建通过；独立复核最终 P0/P1/P2=0 | 不包含账号/群组、日志、连接、套件、磁盘测试、服务配置、关机重启或更新安装；这些不是待真机项目 |
| VMM 官方虚拟机清单只读闭环 | macOS VMM 仅提供虚拟机基本摘要的业务语义；移动端不复制桌面七分区、日志、保护或管理能力 | M7-B1a 已建立 profile-bound 窄仓库、清单模型和自适应页面；只读取公开 Guest v1 的名称、规范化状态、CPU、内存、虚拟磁盘容量和自动启动；iPhone 列表→详情，iPad 常规宽度列表+详情 | M7-B1a 通过 | 原生状态筛选、下拉/工具栏刷新、刷新保留、只读说明；需要管理时转交 DSM 或 Mac | 公开 Guest v1 专用严格解析，只接受 `guests` 与确定字段；缺根/身份/名称/状态/autorun、重复 ID、畸形类型或容量溢出均失败；无内部 fallback、附属分区、日志或写能力 | Guest v1 聚焦 5/5、移动模型/展示 15/15、DsmMobile 全量 218/218；共享 Package 597 XCTest（2 跳过）+10 Swift Testing；DsmMac 无签名构建通过；独立复核的宽松解析 P1 已关闭 | 不包含主机/存储/网络/映像、保护、日志、控制台、电源、创建、修改或删除；这些不是待真机项目 |
| 能力不可用有通俗原因 | macOS Workspace、Service、NAS 模型 | 当前移动端多为模块加载消息或隐藏行为 | 部分 | 保留入口或摘要位置，提供原因与下一步；当前排除项直接不进入导航 | 用户文案不得暴露 API、build、Token 等内部术语 | M1 建立稳定 availability 状态并补五态 | 不预建后续功能空页面 |
| 证书首次核对与变化阻断 | macOS 连接流程和共享 `DsmCertificateTrust.swift` | 登录/恢复捕获 trust error；原生 sheet 展示首次核对或旧/新指纹；invalid 仅允许取消；确认使用原 submission 的 profile、地址与凭据重试 | M1 通过 | 可滚动 sheet；先给通俗说明，指纹作为可选择的次级详情 | 合格叶证书、按 profile pin、变化阻断；direct host 不误判为 relay，relay 仍只允许系统信任 | 证书、取消和临时网络错误行为已纳入 25 项移动测试；共享网络包测试与独立复核通过 | 不提供忽略验证、永久信任所有证书或 relay pin |
| 当前不做项零危险请求 | macOS Container/VMM/NAS 写能力只用于理解语义 | Container/VMM 只读摘要保留；对应控制、删除、网络/映像写均移除；Download 删除任务/数据入口也已移除 | 部分：已收口 CM/VM/DS 排除写 | 手机和平板仅保留计划允许的只读摘要或受限动作；高级管理转交 Mac App 或 DSM Web | 移动源码扫描应保持零排除项危险写调用 | CM/VM/DS 生产源码危险写符号扫描无匹配；仍需 recording repository 零调用测试并逐项覆盖完整范围矩阵 | 不以 `PENDING_USER_VALIDATION` 保留排除的写入口 |
| 按功能目录独立演进与五态 | macOS 已按 Workspace、Photos、Chat、Services、NAS 管理分文件 | 已拆为 AppShell、Session、CommonUI、Files、Photos、Chat、Downloads、ReadOnlyServices、Administration、Settings；CommonUI 已建立 loading/empty/filteredEmpty/error/content 与语义 token | M0 基础出口通过 / Feature 接入待后续 | 原生 Tab/Split 导航；普通空态居中，筛选空/内容 topLeading；系统字体颜色、44pt、Reduce Motion | Shared Package 仅新增双语“活动”“添加 NAS”资源键，未改业务契约 | M0 当时验证：XcodeGen 生成工程，iPhone 与 iPad 模拟器均 25/25、共享 Package 588 项 XCTest + 10 项 Swift Testing、DsmMac 无签名回归构建通过；当前累计证据见本节追加集成结果 | 本波不新增后台、File Provider、自动备份、多窗口 |

### 4.1 iPhone / iPad 完整产品范围冻结

下表是实现 DAG 的范围门；“后续”和“当前不做”不能以空页面、隐藏开关或 `PENDING_USER_VALIDATION` 进入当前版本。

| 能力 | iPhone | iPad | 当前移动替代 / 降级 | 当前实现证据 |
| --- | --- | --- | --- | --- |
| FND-01～04、NAV-01 | 核心 | 核心 | 触控资料管理、五 Tab；iPad 自适应 Sidebar；按 profile 隔离单窗口状态 | 主干完成：登录/OTP/恢复/取消/切换隔离/证书核对及五入口已完成；重命名/排序和能力说明继续 M1 |
| FILE-01 浏览 | 核心 | 核心 | 列表/网格、分页、搜索、排序筛选；iPad 可用更宽列表与详情 | M3-A 已完成大目录分页、显式加载更多、目录历史/向上/刷新、递归搜索取消、列表/网格与按 profile 进程内缓存；M3-B 已基于公开 List 参数完成目录服务端 name/size/mtime、升降序、全部/文件/文件夹筛选，条件进入分页缓存与 generation，完整搜索快照才本地排序筛选；共享根只使用名称与方向 |
| FILE-02 收藏/最近/回收站/远程位置 | 受限 | 受限 | 已完成只读位置导航：官方 Favorite v2 收藏、profile 会话内最近目录、当前可见共享的有界回收站根发现、官方 VirtualFolder v2 远程位置；iPhone/iPad 使用原生位置 sheet，Windows 在 Files 内使用自适应位置栏；挂载管理交给 Mac/DSM Web | Apple 共享契约、移动状态/UI 与 Windows fixed-v2 typed 契约、事务导航、WinUI 已收口；Remote/Recycle 及后代保持只读，收藏写、内部挂载写、恢复与永久删除保持关闭 |
| FILE-03 新建/重命名/详情 | 受限 | 受限 | 触控详情页；不做空文件、递归统计、MD5 | 已完成基本详情和结果型单项新建/重命名：固定公开 v2、权限/冲突预检、一次提交、独立回读、提交未知 review blocker 与当前文件夹刷新；旧 Void 入口不作为移动生产路径 |
| FILE-04 单文件传输 | 核心 | 核心 | Document Picker、Exporter、Share Sheet；仅用户主动前台单文件 | M2-C 完成：单文件导入先协调复制到受控临时目录再上传；下载成功后才存储副本/分享；按 profile 隔离，系统面板 FIFO 呈现并在完成/取消后清理；不承诺常驻后台 |
| FILE-05 同 NAS 复制/移动 | 受限 | 受限 | 单个普通本地文件、无覆盖；iPad 可增加拖放快捷方式 | 已完成 CopyMove v3 结果型契约、目标选择、源/目标互斥、一次提交、任务轮询、独立回读和跨页面 blocker；目录、批量、跨 NAS 与覆盖转交 Mac/DSM Web |
| FILE-06 压缩解压 | 当前不做 | 当前不做 | 转交 Mac App 或 DSM Web | 无移动入口；不得预建空页 |
| FILE-07 分享链接 | 核心/受限 | 核心/受限 | 创建、复制、系统分享为核心；管理/撤销后置 | 已完成首个安全闭环：官方 Sharing v3、单文件/文件夹、可选密码、无到期或 7/30/90 天、一次提交和完整回读；仅 NAS 明确确认后允许复制/系统分享，未知结果禁止重放；管理、撤销、批量、二维码与提前生效日期未进入当前切片 |
| FILE-08 预览 | 核心 | 核心 | 图片/PDF/文本只读/音视频；iPhone 全屏，iPad 详情区或全屏 | 已完成：图片/PDF 仅在精确刷新大小已知且≤128 MiB时，以4 MiB严格 Range、强 ETag/`If-Match`生成随机临时 artifact；文本仅在大小已知且≤1 MiB时读取并严格解码 UTF-8/BOM UTF-16；白名单音视频使用 AVKit 随机 Range，不完整落盘；iPad Inspector 与全屏互斥；不新增独立窗口、不编辑、不后台播放 |
| FILE-09 回收站 | 受限 | 受限 | 单个普通文件移入回收站与恢复；必要确认和最终回读 | 已完成 Files 受限入口，并在 Photos 的 `#recycle` 普通文件上复用恢复；永久删除、清空和目录批量仍关闭 |
| ACT-01 活动中心 | 核心 | 核心 | App 前台字节任务与 NAS/Download 任务分源显示、取消和结果说明 | App 前台单文件传输、按 profile 隔离、进度/取消/待复核、状态筛选和白名单从头重试已完成；当前分支的第 4 波首片已把 Download Station 已加载任务快照投影到 Activity 的独立 NAS 来源，并禁用 NAS 项取消/重试。Activity 主动轮询、系统通知、NAS 文件后台任务和跨重启恢复仍是后续缺口，不能把首片写成 ACT-01 全部完成 |
| PHOTO-01～02 浏览/时间线 | 核心 | 核心 | 文件系统空间/文件夹相册、用户主动有界时间线、当前快照本地搜索和基础查看器 | 文件夹浏览、缩略图、PHOTO-01 有界时间线和 PHOTO-02 冻结可见快照查看/元数据已完成；人物/地点/标签、真正相册、全库服务端搜索和敏感 EXIF 仍关闭 |
| PHOTO-03 主动导入/导出 | 受限 | 受限 | PhotosPicker 单项明确选择，NAS 内回收站恢复有界；不删除系统照片 | PHOTO-03A 单项图片/视频导入已完成并复用既有上传与 Activity；导出/分享与 `#recycle` 恢复复用现有链路，更完整 NAS 内整理和自动备份后置 |
| CHAT-01～02 文字核心 | 核心 | 核心 | 会话、非加密历史、草稿与受限纯文字发送；实时和会话管理逐项按版本门开放 | 已完成会话筛选、消息首屏/刷新/向前分页、profile 缓存和受限纯文字发送；附件、首次会话/成员管理、已读回写和前台实时仍未完成，不以待真机项目伪装 |
| CHAT-03～04 附件/常用动作 | 受限 | 受限 | 单附件收发/保存与少量常用动作 | 未完成；提醒、定时、投票、服务端置顶、语音、加密当前不做 |
| DS-01～02 Download Station | 受限 | 受限 | 单任务查看、URL/磁力/任务文件创建、暂停/继续、只移除任务和官方 BT 搜索；删除数据、批量与高级设置交给 Mac App/DSM Web | 常用单任务闭环、当前活动摘要与 BTSearch v1 目录、七类排序及方向、有界搜索/清理、零提供方恢复态和单结果安全创建均已通过源码与云端门禁。删除已下载数据、RSS、文件优先级、BT 协议高级与设置写仍关闭 |
| CM-01 Container 实例清单 | 受限只读 | 受限只读 | 查看容器名称、规范化状态与可选映像名称；其他分区转交 Mac App 或 DSM Web | M7-B2 / W4-A 已完成内部 observed/degraded v1 `Container.list` 窄契约、profile/generation/cache、筛选、刷新保留、五态与自适应列表详情；不读取映像库、网络、项目、事件、日志、资源或进程 |
| CM-02 Container 写管理 | 当前不做 | 当前不做 | 转交 Mac App 或 DSM Web | 控制、删除、网络和映像写入口/模型调用已移除 |
| VM-01 VMM 摘要 | 受限只读 | 受限只读 | 查看公开 Guest v1 的虚拟机名称、状态、CPU、内存、磁盘与自动启动；附属资源和日志转交 Mac/DSM | M7-B1a 已完成严格公开 Guest v1 窄契约、profile/generation/cache、五态与 iPhone/iPad 自适应页面；无内部 fallback |
| VM-02 VMM 写/控制台 | 当前不做 | 当前不做 | 转交 Mac App 或 DSM Web | 电源、删除、网络/映像写入口/模型调用已移除；不嵌入控制台 |
| NAS-01 健康概览 | 核心 | 核心 | 系统、当前性能、存储/硬盘健康与更新检查；安装更新转交 DSM Web | M7-A 已完成四分区独立状态、刷新保留、profile 隔离与 iPhone/iPad 自适应只读页；正式聚焦验证及当时移动全量已通过；最新累计证据见本节追加集成结果 |
| NAS-02/04 服务信息 | 受限 | 受限 | 仅套件、计划任务、日志和当前连接等隐私白名单有界只读详情；配置写、断开、生命周期与任务执行转交 Mac App/DSM Web | 2026-08-10 范围升级：iPhone/iPad 已完成四分区独立加载、失败/不可用/空内容/截断呈现及字段白名单适配；本地 iOS 聚焦测试覆盖当前实现，真实 NAS 响应和系统交互待验收。Windows 仍先建立 typed、分区独立失败、分页和 partial/truncated 契约；两端均不得恢复旧浅层聚合或任何写入口。 |
| NAS-03/05 管理写与完整存储分析 | 当前不做 | 当前不做 | 转交 Mac App 或 DSM Web | 当前移动入口必须关闭；不以真机待办保留 |
| SET-01 本地设置 | 核心 | 核心 | 语言、设备级主题、可选服务入口、本地可再生缓存与隐私边界；不写回 NAS | 已完成：保留既有系统/英语/简中语言；新增 system/light/dark 根级主题；仅 Download Station、Container、VMM、NAS 健康可隐藏，且可见性取本机偏好与当前 NAS capability 交集；Files、Photos、Chat、Transfers、Settings 永远可达；照片缩略图按 generation 安全清理，普通 profile 切换释放旧 session repository 但保留有界缓存，显式退出/删除只清目标 profile |
| SYS-01 File Provider | 后续 | 后续 | 当前使用 App 内 Document Picker/Exporter | DAG 外，不预建 Target/入口 |
| 自动照片备份 | 后续 | 后续 | 当前仅 PhotosPicker 用户主动导入 | DAG 外，不申请整库后台授权 |
| 后台常驻传输/通知 | 后续 | 后续 | 当前只承诺前台任务与下次打开后的可解释状态 | DAG 外，不注册 BGTask/后台 URLSession |
| iPad 多窗口 | 不适用 | 后续 | 当前单窗口随实际宽度折叠 | DAG 外，不建立 Scene 状态 |

Apple 当前自动化基线：

```text
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -destination 'platform=iOS Simulator,id=7741B4CC-FFEF-4D02-B3B6-A1C1FCCC6E8C' \
  -derivedDataPath /tmp/lanstash-mobile-baseline CODE_SIGNING_ALLOWED=NO test

结果：TEST SUCCEEDED，5 tests，0 failures。
```

截至 M7-B1a 的阶段集成结果（历史节点，非当前最终总数）：iPhone 17 Pro iOS 26.5 模拟器全量 218/218、0 失败、0 跳过；M7-B1a VMM 模型/展示聚焦 15/15、Guest v1 契约聚焦 5/5；M6-S0/M7-A 安全、模型与展示聚焦 21/21；M5-A1a Chat 模型/展示聚焦 31/31。缩略图优先级用例曾因测试在可见与预取任务尚未确认入队前释放首请求而偶发失败；测试改为观察两类队列均已建立后再释放，单套重新构建通过并连续复跑 3 次 31/31，后续全量继续通过，生产优先队列未增加额外分支。M3-B 前的 iPad Air 11-inch (M4) iOS 26.5 模拟器全量 82/82；M3-C1、M4-A1、M5-A1a 与当前 M7-A/M7-B1a 的 iPad 真机/最新模拟器交互结论均不得由 iPhone 结果替代。测试目标已在 XcodeGen 事实源中启用 Info.plist 自动生成。共享 Package 597 项 XCTest（2 项按环境跳过）与 10 项 Swift Testing通过；DsmMac 无签名回归构建、本地化（Apple 3050、Android 1985、Windows 565）、84 个请求 Fixture、响应 Fixture、契约与差异检查均通过。Apple M7-B1a 对抗复核发现的 Guest v1 宽松解析 P1 已改为专用严格解析，并补齐缺根、别名、缺字段、重复 ID 与溢出负向测试；筛选详情残留和刷新反馈一并收口。Apple M1 第二轮独立安全复核剩余 P0/P1 均为 0。M2-A0 对抗复核发现的两项 P1（取消后误报成功、未知或成功上传可再次写）已修复；执行 generation 和旧执行释放等待共同阻止旧进度或未释放提交锁污染重试。M2-C 三轮独立复核关闭临时文件所有权、Profile 切换、Files Provider 协调复制、并发系统面板与 Sheet 关闭时序问题，最终 P0/P1 均为 0。M3-A 独立复核关闭 iPhone 布局切换、慢搜索清空、空目录缓存和分页 total/hasMore 一致性问题；M3-B 的公开请求契约与移动状态/UI 独立复核均为 P0/P1=0。M3-C1 独立复核发现的临时预览析构清理和离开 Files 后 artifact 残留两项 P1 已修复；M4-A1 的生产 Repository 绑定、系统面板断开清理、全屏预览生命周期与有界后台缩略图解码问题均已关闭；M5-A1a 关闭跨会话首帧错显、iPad 双请求与 logout 明文缓存/旧 repository 生命周期问题；M6-S0/M7-A 关闭移动端危险 Download 写入口、健康页缓存刷新与单分区取消收口，最终独立复核 P0/P1/P2=0。旧 create/rename/delete 生产入口保持关闭，M2-C 上传/保存副本/分享保持可达。预览与普通下载生产适配均固定 `expectedSize: nil`，上传提交后的取消/失败只进入结果待核对且不自动重放。

M7-B2 / W4-A Container 追加集成结果：iPhone 17 Pro iOS 26.5 模拟器容器模型、展示与会话聚焦 24/24，DsmMobile 全量 236/236，均 0 失败、0 跳过；共享 Package 601 项 XCTest（2 项按环境跳过）与 10 项 Swift Testing 通过；DsmMac 无签名构建通过；本地化门禁通过（Apple 3076、Android 1985、Windows 601）。Apple 与 Windows 均把 Container 收窄为内部 `observed/degraded` 的 `SYNO.Docker.Container.list` v1，只发送 `offset=0`、`limit=-1`、`type=all`，并只跨层保留稳定 ID、名称、状态和可选映像。独立复核发现的 Windows 模块能力测试反向断言已修正，最终生产链 P0/P1/P2=0。GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建，验证等级为 `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64`。

FILE-08 追加集成结果（覆盖上文 M3-C1 的旧预览描述）：Apple 预览聚焦 60/60、DsmMobile 全量 252/252，均 0 失败、0 跳过；本地化门禁通过（Apple 3089、Android 1985、Windows 640）。Apple 图片/PDF、文本与音视频全部使用专用只读严格 Range，不再使用普通下载的 `expectedSize:nil` 预览链；Windows 使用 profile-bound Repository、事务 artifact 和原生随机访问媒体流。两轮独立复核关闭小媒体版本混合、iPad 双 presenter、Windows seek 游标迟到、保存对象错配及 presenter/artifact 清理竞态，最终 P0/P1=0。GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建；真实媒体栈继续列入 `PENDING_USER_VALIDATION`。

SET-01 追加集成结果：Apple 在 iPhone 17 Pro、iOS 26.5 模拟器完成设置/照片/session/Shell/module 聚焦 66/66 与 DsmMobile 全量 271/271，均 0 失败、0 跳过；Windows 完成源码、XAML、双语资源与独立对抗复核，最终 P0/P1=0。全仓本地化门禁通过（Apple 3109、Android 1985、Windows 686）。Apple 已覆盖 capability 与偏好交集、隐藏当前 Download 的非合作迟到结果、照片 repository 生命周期与按 profile 缩略图清理；Windows 已覆盖主题/模块/语言持久化失败不崩溃、隐藏 NAS Health 取消失效与缩略图 generation 清理。GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建，验证等级为 `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64`。

FILE-07 追加集成结果：Apple 共享契约全量 612 项 XCTest（2 项按环境跳过）与 10 项 Swift Testing 通过，移动端分享链接模型/展示/集成等五套聚焦 39/39、DsmMobile 全量 288/288，均 0 失败、0 跳过；请求契约 validator 通过 86 个 fixture 与 1 个写结果。Apple 独立终审最终 P0/P1/P2=0。Windows 已完成官方 Sharing v3 typed 契约、一次提交/完整回读、Files ContentDialog、复制与安全关闭；B0 和 B1/B2 独立源码终审最终 P0/P1/P2=0，本地化门禁通过（Apple 3142、Android 1985、Windows 725），XAML/resw XML 与差异检查通过。GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建；unpackaged 构建的系统分享保持关闭，不能由复制功能或 Apple 系统分享结果替代验证。

PHOTO-01 追加集成结果：Apple 共享层新增 typed 有界 BFS 扫描，同时以 `.legacyDefault` 保持既有 Mac 调用不被移动上限静默截断；聚焦 17/17、共享 Package 621 项 XCTest（2 项按环境跳过）与 10 项 Swift Testing、DsmMac/File Provider 无签名构建均通过。DsmMobile 在 iPhone 17 Pro iOS 26.5 模拟器完成时间线模型、展示、既有照片模型和展示回归 58/58，0 失败、0 跳过；独立终审最终 P0/P1/P2=0。Windows 已完成同义 typed 契约、严格公开 List v2 BFS、专用 Timeline UserControl、搜索/筛选/月份分组与现有缩略图/保存副本接线；对抗源码复核最终 P0/P1=0，本地化门禁通过（Apple 3169、Android 1985、Windows 758），XAML/resw XML 与差异检查通过。GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建，验证等级为 `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64`。

FILE-02 追加集成结果：Apple 共享层完成 Favorite v2 严格有界分页、List v2 回收站根发现与 Info/VirtualFolder v2 分协议远程位置；共享 Package 636 项 XCTest（2 项按环境跳过）与 10 项 Swift Testing、DsmMac/File Provider 无签名构建均通过。DsmMobile 在 iPhone 17 Pro iOS 26.5 模拟器完成位置模型、事务导航、展示、文件浏览、分享链接与会话生命周期聚焦 68/68，0 失败、0 跳过；Apple 独立终审 P0/P1/P2=0。Windows 完成 fixed-v2 安全只读 transport、三分区 typed repository、profile/repository/browser generation、首屏原子导航、会话内 12 条 MRU 与 Files 内自适应位置栏；Remote/Recycle、已知只读根后代及任意 `#recycle` 路径均隐藏并拒绝上传/创建分享链接，预览与保存副本继续可用；W0/W1/W2 三轮独立源码终审最终均为 P0/P1/P2=0。本地化门禁通过（Apple 3209、Android 1985、Windows 794），XAML/resw XML 与差异检查通过。GitHub Windows CI 已执行 691 项 xUnit，并完成 x64/ARM64 Release 构建，验证等级为 `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64`。

FILE-02 开始前范围账本：用户目标是从 Files 内快速打开收藏、最近目录、可访问回收站根和公开远程位置，并继续复用既有分页、预览、保存副本与分享；iPhone 使用原生位置 sheet，iPad 在现有 Workspace 层级内提供位置栏或 Inspector，Windows 在 FilesPage 内提供自适应位置栏，不新增顶级模块。远端读取固定为官方 `SYNO.FileStation.Favorite` v2、`SYNO.FileStation.List` v2、`SYNO.FileStation.Info` v2 和 `SYNO.FileStation.VirtualFolder` v2；最近目录只在成功打开目录后按 profile 记入当前 App 会话内存，去重置顶且最多 12 项，不持久化真实路径。回收站仅对当前账号可见共享做有界 `/#recycle` 探测与只读浏览；notFound/permission 表示该共享不可访问，认证、取消和根级网络错误不得吞掉。partial 与 truncated 分开呈现。收藏新增/删除、内部 Mount/VFS 创建修改断开、回收站恢复、移入回收站、清空和永久删除均不进入本波，也不以 `PENDING_USER_VALIDATION` 保留入口。

这些结果不能证明 iPad 实际宽度、真机 Keychain、证书交互、系统选择器或真实 NAS 副作用。后续需要用户设备验证的当前范围项目将逐项写为 `PENDING_USER_VALIDATION`。

### 4.2 分切片 `PENDING_USER_VALIDATION`（含历史验收快照）

本节按每个切片完成当时的边界保留验收步骤，便于回归和追溯；其中“当前不要求”或“没有
写入口”等句子只描述该历史切片，不能覆盖第 4.1 节和第 5 节后来已经合并的能力。例如
M3-A/M3-B、M4-A1、M5-A1a、M6-S0 的旧清单早于 FILE-03/05/09、PHOTO-02/03A、
Chat 纯文字发送和 Download 创建/控制/删除。执行当前版本验收时必须同时使用最新追加
集成结果与对应功能 PUV，不得要求已经存在的入口消失，也不得把历史局部通过当成当前
完整范围通过。

FILE-02 只读位置导航追加验收：

- 条件：一台 iPhone、一台 iPad、一台具备 .NET 10 与 Windows App SDK 2.3.1 的 Windows x64 或 ARM64 设备，以及至少一个脱敏测试 NAS profile；该账号应具有普通共享目录、收藏、一个启用回收站的本地共享，并在条件允许时配置 cifs/nfs/iso 中至少一种公开 VirtualFolder。不得使用生产账号或真实敏感路径。
- 操作：分别打开共享文件夹、收藏、最近、回收站和远程位置；在目录首屏加载中关闭位置面板、离页和切换 profile；打开普通目录后检查最近位置去重置顶和 12 条上限；从 Remote/Recycle 进入后代并返回父级；刷新时断网或制造部分共享无权限；Windows 覆盖宽窗常驻栏与窄窗 Overlay、键盘焦点和 Narrator，iPhone/iPad 覆盖下滑关闭、旋转/分屏、VoiceOver 与最大动态文字。
- 预期：只出现官方 Favorite/List/Info/VirtualFolder v2 读取；最近路径仅在当前 App 会话内按 profile 保存且只在首屏成功后提交；失败、取消、旧 profile 和旧 repository 结果不改变当前目录或 MRU；partial 与 truncated 独立显示；Remote/Recycle、其已知后代及 `#recycle` 路径不出现上传或创建分享链接入口，处理器也拒绝调用，但预览与保存副本仍可用；收藏写、Mount/VFS 管理、恢复、删除、清空和永久删除始终无入口、零请求。
- 回传：仅提供平台、系统/App/DSM 与相关套件版本、位置类别、脱敏数量级、发生阶段、页面状态、错误分类和复现步骤；不得回传 NAS 地址、账号、真实路径/名称、收藏内容、远程地址、原始响应、SID、Token、Cookie 或截图中的用户数据。
- 影响范围：FILE-02 的只读位置发现、事务导航、会话内最近目录和既有文件只读动作；不包含收藏增删、远程挂载管理、回收站恢复/移入/删除/清空、永久删除或跨端路径持久化。

PHOTO-01 用户主动有界时间线追加验收：

- 条件：一台 iPhone、一台 iPad、一台具备 .NET 10 与 Windows App SDK 2.3.1 的 Windows x64 或 ARM64 设备，以及两个脱敏测试 NAS profile；至少一个照片空间包含跨月份、未知日期、图片/视频/非媒体混合项目、权限受限子目录，并能覆盖一项安全上限或合成截断场景。
- 操作：从个人/共享空间切换到时间线并显式开始扫描；扫描中取消、离页、切 profile；完成后用大小写和音调不同的文件名搜索，切换全部/图片/视频；重新扫描时断网；在空结果、筛选空、部分和截断状态检查提示；快速滚动缩略图，并从时间线执行预览、存储副本或分享；检查 iPhone/iPad 旋转与分屏、Windows 窄窗/200% 缩放、VoiceOver/Narrator、深浅色、高对比和减少动态效果。
- 预期：每次扫描最多尝试 2,000 个文件夹、处理 50,000 个原始项目和 10,000 个媒体项目，每页 200；只出现公开 File Station List/Thumb 读取，无 Search、Foto、后台索引或 NAS 写；取消/失败保留上次完整快照，旧 profile/repository/thumbnail 不回写；搜索只覆盖本次有界快照且 partial/truncated 始终可见；日期按 `createdAt ?? modifiedAt` 分组，未知日期独立；保存/分享只处理当前 profile 的 canonical 项目。
- 回传：仅提供平台、系统/App/DSM 版本、空间类别、脱敏项目数量级、发生阶段、页面状态、截断/失败类别和复现步骤；不得回传 NAS 地址、账号、真实路径/文件名、查询内容、缩略图、原始响应、SID、Token 或 Cookie。
- 影响范围：PHOTO-01 的文件系统照片时间线、本地文件名搜索、图片/视频筛选与既有只读动作；不包含全库服务端搜索、智能相册、人物/地点/标签、EXIF、导入、移动、删除、恢复、后台扫描或自动备份。

FILE-07 分享链接追加验收：

- 前置条件：专用测试 NAS 支持官方 `SYNO.FileStation.Sharing` v3 与 File Station List v2；准备一个脱敏测试文件和一个测试文件夹；iPhone、iPad 与 Windows 测试机使用独立测试资料，Windows 需可构建当前 WinUI 工程的 SDK 环境。
- 操作：分别对文件和文件夹创建无密码/有密码链接，覆盖无到期和一个 7/30/90 天到期选项；在提交前取消一次、提交后断网或取消一次；确认结果后分别执行复制与系统分享；关闭“请先核对”后重新打开同一对象并切换 profile 往返；Windows 额外核对剪贴板历史/漫游未记录该 URL，且 unpackaged 形态下系统分享保持禁用。
- 预期：每次用户动作最多提交一次；只有 NAS 回读确认唯一新稳定 ID、精确路径、密码状态和到期日一致时才显示 URL；未知结果不会自动重放，关闭重开或 Shell 重建后同一 profile/path 仍要求先在 DSM 核对；剪贴板和系统分享只包含 URL，不包含密码、真实路径或凭据；取消/退出后旧弹窗和旧 profile 结果不会重现。
- 回传：仅回传平台/系统版本、DSM 与 File Station 脱敏版本、文件或文件夹类别、到期选项、提交阶段、页面结果状态和脱敏错误类别；不得回传分享 URL、密码、真实文件名/路径、NAS 地址、账号、SID、Token、Cookie 或原始响应。
- 影响范围：仅 FILE-07 单对象创建、复制和已确认后的系统分享；不包含分享链接管理、撤销/删除、批量、二维码、提前生效日期或后台创建。Windows 系统分享必须在 unpackaged interop 真机验证通过后另行启用。

SET-01 本地设置追加验收：

- 条件：一台 iPhone、一台 iPad、一台 Windows x64 或 ARM64 设备，以及两个能力集合不同的脱敏测试 NAS profile；Windows 需先在具备 .NET/Windows App SDK 的环境完成 build 与专项 xUnit。
- 操作：切换跟随系统/浅色/深色并重启 App；隐藏和恢复 Download Station、Container、VMM、NAS 健康，包含隐藏当前正在加载的模块；切换两个 profile；在照片快速滚动和缩略图加载期间清理缓存；检查 iPad 分屏/横竖屏、Windows 窄窗口与 125%–200% 缩放、键盘、VoiceOver/Narrator、最大动态文字、高对比和保存失败反馈。
- 预期：主题即时生效且重启保持；可选模块只有同时满足本机偏好和当前 NAS capability 才显示，五个核心模块永远可达；隐藏当前模块后旧请求不回写；清理只移除可再生照片缩略图并允许再次下载，不影响 NAS 文件、资料、密码、会话、传输、正在使用的预览、Cloud Drive 或已导出文件；退出/删除 profile 不保留旧 session repository，也不误清其他 profile 缓存。
- 失败回传：仅提供平台、系统/App 版本、模块类别、主题选择、页面状态、脱敏复现步骤与错误文案；不得回传 NAS 地址、账号、路径、文件名、凭据、日志正文或缓存内容。
- 影响范围：SET-01 的本地设置、模块导航和已注册照片缩略图内存清理；不包含 NAS 配置写入、偏好同步、Cloud Drive 清理、诊断导出或新增语言。

M7-B2 / W4-A Container 实例清单追加验收：

- 条件：一台 iPhone、一台 iPad、一台 Windows x64 或 ARM64 设备，以及安装 Container Manager 的专用测试 NAS；使用只读或最低必要权限账号和脱敏容器名称。
- 操作：打开容器页，切换全部/运行中/已停止/需要处理筛选，刷新期间断网后恢复，两个 profile 往返，退出登录并重新连接；检查 iPhone 层级导航、iPad/宽 Windows 列表详情、窄 Windows 返回、动态文字、VoiceOver/Narrator、深浅色与高对比。
- 预期：每次读取只出现一次 `SYNO.Docker.Container.list` v1，参数固定为 `offset=0`、`limit=-1`、`type=all`；页面只显示名称、状态和可选映像；无 Image/Network/Project/Event/Log/Resource/Process/Registry/Terminal/Compose 或写请求；刷新失败保留旧列表，profile 与退出登录不串缓存。
- 失败回传：仅回传平台、系统/App/DSM/Container Manager 版本、脱敏错误类别、复现步骤、API 名/version/method/参数键；不得回传 SID、Cookie、Token、地址、账号、真实容器名、映像名或响应正文。
- 影响范围：仅 M7-B2 / W4-A 的实例清单与自适应展示。映像库、网络、项目、事件、日志、资源、进程、注册表、终端、Compose 和所有写操作未进入当前切片，不是 `PENDING_USER_VALIDATION`。

- 设备：一台 iPhone、一台 iPad、两个脱敏测试 NAS profile，其中至少一个具有可恢复会话。
- 操作：分别在 QuickConnect 路由发现、能力发现和提交登录阶段取消；连接 NAS A 后切到非默认模块，再切换 NAS B 并切回 A；使用首次自签名、证书已更换、过期/结构无效证书及 QuickConnect relay；检查 iPhone Tab、iPad Sidebar、横竖屏/分屏、最大动态文字与 VoiceOver。
- 预期：取消立即停止进度且不清资料/密码、不显示登录失败；切换不等于远程退出；两个 NAS 的顶层/模块选择互不串用；首次证书可核对、变化同时显示旧/新指纹、无效证书不能确认、relay 不允许自定义 pin；主操作可见且触控区域足够。
- 失败回传：设备类型、系统版本、发生阶段、可见错误文案与脱敏步骤；不要回传地址、账号、密码、SID、Token、Cookie、证书或真实路径。
- 影响范围：真实网络任务取消响应、Keychain 真机行为、TLS 证书链/relay 边界、iPad 实际分屏与辅助功能；不阻塞其他无设备依赖的 M1/M2 切片。

M2 前台传输、系统文档与 Activity 追加验收：

- 条件：iPhone、iPad、真实测试 NAS 与不含敏感数据的单文件；当前不要求后台执行、通知或跨重启恢复。
- 操作：观察 App 前台上传/下载进度；从本地、iCloud Drive 和一个第三方 Files Provider 各选择单文件；完成或取消“存储副本”和分享；iPad 检查分屏、旋转和 Popover；在提交前和提交后分别取消；对下载失败/取消执行一次明确的从头重试；切换两个 profile；检查最大动态文字、VoiceOver 与减少动态效果。
- 预期：Activity 只显示当前 profile；离开页面不取消当前进程任务；上传源在安全作用域内协调复制，系统面板完成前受控文件不被删除；多个就绪文件依次呈现；切换 NAS 不展示旧 NAS 文件；上传进入 NAS 请求后取消只显示“请核对结果”且没有普通重试；下载取消清理分片和受控临时目标；成功或结果未知的上传绝不产生第二次写请求。
- 失败回传：仅提供脱敏状态序列、上传/下载/回读/清理调用次数、设备与系统版本；不得回传 NAS 地址、账号、路径、文件名或会话凭据。
- 影响范围：M2 前台单文件传输状态、Activity、Files Provider 协调读取、Document Picker、Exporter 与 Share Sheet；不包含后台、多文件、跨重启恢复或 File Provider 扩展。

M3-A / M3-B 大目录浏览、排序与筛选追加验收：

- 条件：iPhone、iPad、两个测试 NAS profile；至少一个目录超过 200 项，并准备空目录、权限受限目录与可搜索的脱敏文件名。
- 操作：逐页加载、加载更多期间断网再重试、进入多层目录后返回/向上、提交搜索后立即清空、在列表/网格间切换；分别验证名称、大小、修改日期的升降序与全部/仅文件/仅文件夹，切换条件时观察第一页和后续至少两页；NAS A/B 往返；iPad 分屏/旋转，检查 VoiceOver、最大动态文字和深浅色。
- 预期：已加载内容在加载更多失败时保留；旧目录、旧搜索、旧排序筛选的迟到结果不覆盖当前页面；每一页使用相同条件且类型不混入；共享根只按名称排序；普通目录偏好经根目录往返后恢复；两个 NAS 的路径、历史、查询、布局、条件和缓存不串用；旧新建/重命名/删除入口不可见，上传/保存副本/分享仍可用。
- 失败回传：设备与系统版本、脱敏目录别名、页序号、可见状态和重现步骤；不得回传真实路径、文件名、账号、地址或凭据。
- 影响范围：M3-A/M3-B 当前进程内文件浏览；不包含详情/预览、写操作、跨重启缓存或后台。

FILE-08 文件预览追加验收：

- 条件：iPhone、iPad、Windows 10/11 x64 或 ARM64、真实测试 NAS；准备 UTF-8/UTF-8 BOM/UTF-16 BOM 文本、普通图片、PDF，以及白名单内的 MP3/M4A/WAV/AAC 和 MP4/M4V/MOV（Apple 另含 3GP，Windows 另含 WMA/AVI/WMV）。准备一个接近但不超过 128 MiB 的图片或 PDF，以及大小未知、超限和不支持格式。
- 操作：逐类打开并取消/重试；音视频播放后多次拖动进度；播放中切后台/恢复、关闭、切 NAS 和退出；iPhone 检查全屏手势，iPad 检查 Inspector 放大全屏、下滑关闭、旋转和分屏；Windows 检查宽窄窗口、Enter/双击、Alt+Left/Escape、PDF 翻页、保存副本、Narrator、高对比和 125%～200% 缩放。
- 预期：文本只读且编码不支持时给出通俗说明；图片/PDF 只有大小已知且≤128 MiB时形成随机临时 artifact；媒体不完整落盘，seek 始终读取同一强版本；任一时刻 iPad 只有一个预览 presenter；取消、关闭、切 profile/退出后 Range 与临时文件均清理；Windows 保存副本始终绑定屏幕中正在预览的文件；无 WebView、编辑、转码、后台恢复或 NAS 写请求。
- 失败回传：设备与系统版本、文件格式和脱敏大小级别、首次播放或 seek 后、页面可见状态、通俗错误文案和复现步骤；不得回传真实文件名、路径、NAS 地址、请求头、Cookie、SID、Token、证书内容或媒体正文。
- 影响范围：FILE-08 图片/PDF、纯文本和白名单音视频只读预览；不包含编辑、格式转换、未知格式、后台常驻播放、独立窗口或外部 DSM URL。Windows 构建/xUnit 是目标平台工程门禁，不以 `PENDING_USER_VALIDATION` 代替。

M4-A1 文件系统照片库追加验收：

- 条件：一台 iPhone、一台 iPad、两个脱敏测试 NAS profile；至少一个开放个人照片空间，一个开放共享照片空间；准备超过一页的混合目录，其中包含文件夹、JPEG、PNG、HEIC、WebP、视频和非媒体文件。当前不要求时间线、搜索、视频查看、EXIF、PhotosPicker 或任何写操作。
- 操作：在个人/共享空间和多层文件夹间往返并逐页加载；快速滚动缩略图网格、切换“全部/仅图片”、加载更多期间断网后重试；点开图片并在 iPhone 全屏、iPad Inspector/全屏查看；分别完成和取消存储副本/分享；在缩略图、预览和系统面板进行中切换 NAS、退出登录和离开照片模块；检查旋转、分屏、深浅色、最大动态文字、VoiceOver 与减少动态效果。
- 预期：分页始终按 NAS 原始目录项推进，视频和非媒体不会导致重复或漏页；只显示文件夹与图片，缩略图滚出后取消且旧 NAS 结果不串入；加载更多失败保留已有内容；图片预览、保存和分享只属于当前 profile；切换、退出或关闭后不会残留旧系统面板或受控临时文件；iPad 保持单窗口，不出现独立窗口或后台扫描。
- 失败回传：设备与系统版本、空间类别、脱敏媒体格式/大小级别、页序号、发生阶段、可见状态和复现步骤；不得回传真实路径、文件名、NAS 地址、账号、缩略图数据或凭据。
- 影响范围：M4-A1 文件系统照片浏览、缩略图、图片预览、保存副本与分享；不包含时间线、搜索、视频、元数据、导入、移动、删除、恢复或自动备份。

M5-A1a Chat 只读闭环追加验收：

- 条件：一台 iPhone、一台 iPad、一个安装 Synology Chat 且当前账号可读取普通会话的脱敏测试 NAS；准备普通单聊、非加密群聊、加密会话、超过一页的历史消息和一个无权访问或能力不可用场景。当前不要求发送、草稿、新建会话、附件操作、实时连接或通知。
- 操作：进入 Chat 后筛选会话、选择普通会话、刷新并加载更早消息；从会话 A 返回后立即进入 B；在加载期间离开 Chat、切换 NAS 并切回；显式退出后重新登录同一 profile；iPad 检查常规宽度双栏、紧凑宽度折叠、横竖屏和分屏；检查 VoiceOver、最大动态文字、深浅色与减少动态效果。
- 预期：A 的正文不会在 B 首帧出现；每次选择只产生一次消息首屏请求；加载更早使用服务器原始 cursor，失败保留现有消息；加密会话与附件只有只读说明且零附件请求；本地切换 profile 可恢复筛选/选择/消息缓存，但旧 session repository 不保留；显式退出或删除 profile 会清除对应明文缓存；界面始终没有输入、发送、新建、附件动作或实时入口。
- 失败回传：仅提供设备与系统版本、Chat 套件脱敏版本、会话类型、页次、可见状态和复现步骤；不得回传真实会话标题、成员、消息正文、附件名、NAS 地址、账号、SID、Token、Cookie 或其他凭据。
- 影响范围：M5-A1a 当前进程内只读会话与非加密消息历史；不包含文字/Emoji 写入、成员管理、附件、加密正文、已读回写、Socket/轮询、通知或后台。

M6-S0 / M7-A Download Station 与 NAS 健康只读追加验收：

- 条件：一台 iPhone、一台 iPad、两个脱敏测试 NAS profile；至少一个启用 Download Station，并准备正常、警告或未知存储健康状态以及有更新/无更新之一。当前不要求任何下载任务写操作或 NAS 管理写操作。
- 操作：查看下载任务列表与详情并刷新；进入 NAS 健康，分别观察系统、当前性能、存储/硬盘和更新分区；制造一个分区读取失败后重试；在加载/刷新中快速切换 NAS；退出并重新登录；iPad 检查横竖屏、分屏、侧栏选择；检查 VoiceOver、最大动态文字、深浅色和减少动态效果。
- 预期：下载页始终只有查看与刷新，绝无创建、暂停、继续、删除或设置入口；健康四分区独立成功/失败，刷新失败保留旧内容；旧 NAS 结果和缓存不串入当前 NAS，显式退出或删除资料后不恢复旧健康缓存；界面不显示序列号、内部 ID、路径、账号、日志、连接来源或协议术语。
- 失败回传：仅提供设备与系统版本、脱敏 profile 别名、分区/任务状态类别、可见文案和复现步骤；不得回传 NAS 地址、账号、任务标题、保存路径、序列号、原始响应或凭据。
- 影响范围：M6-S0 只读任务查看与 M7-A 四分区健康概览；不包含任务创建/控制/删除、账号/日志/套件/连接管理、磁盘测试、更新安装、关机重启或后台监控。

M7-B1a / W4-B0 VMM 官方只读追加验收：

- 条件：一台 iPhone、一台 iPad、一台 Windows 10/11 x64 或 ARM64 设备，以及启用 VMM 且公开 v1 能力可用的脱敏测试 NAS；准备运行、停止、异常/未知状态与空清单场景。当前不要求任何 VMM 写、控制台、日志或内部 API。
- 操作：在 Apple 移动端查看虚拟机列表、切换状态筛选、进入详情并刷新；在 Windows 查看机器详情和主机/存储/网络/映像四分区，制造一个附属分区失败后刷新；两端均在加载中切换两个 profile；检查 iPad 横竖屏/分屏、Windows 窄窗/高 DPI、键盘、触控、VoiceOver/Narrator、最大动态文字、高对比与深浅色。
- 预期：Apple 只产生公开 Guest v1/list 请求且只显示白名单字段；Windows 只产生五个公开 `.API.*` v1/list 请求，附属分区失败不清空其他分区；旧 profile 结果不串入；页面没有电源、创建、修改、删除、保护、日志、控制台或内部 API 入口。
- 失败回传：仅提供设备/系统、脱敏 profile 别名、VMM 套件脱敏版本、公开 API 名、分区/状态类别、可见文案与复现步骤；不得回传 VM 名称、ID、主机名、网络/存储信息、地址、账号、原始响应或凭据。
- 影响范围：Apple M7-B1a 官方 Guest v1 虚拟机清单与 Windows W4-B0 官方五分区只读资源；不包含 Container、任何 VMM 写、控制台、保护或日志。

Download Station BTSearch v1 跨端追加验收：

- 条件：一台 iPhone、一台 iPad、一台 Windows 10/11 x64 或 ARM64 设备，以及安装 Download Station、`SYNO.DownloadStation.BTSearch` v1 可用的脱敏专用测试 NAS；准备至少一个启用提供方、两个可区分类别和一个“无提供方/能力关闭”场景。创建下载任务的步骤只在允许写入的一次性测试目录执行。
- 操作：打开搜索页核对隐私说明；依次使用全部、仅启用和明确选择提供方，切换类别、标题、七类排序与方向；搜索中取消一次、直接关闭一次、改变条件后再改回原值一次；覆盖无提供方重载、空结果、筛选空、错误和正常结果；最后选择一个合成/公开无敏感内容的结果创建任务，并在提交边界断网或取消一次以验证核对提示。
- 预期：仅调用官方 BTSearch v1 的 `getModule/getCategory/start/list/clean`，不回退 `DownloadStation2`；单次列表最多 200 项、轮询最多 60 次且每次间隔约 500 ms；拿到 task ID 后成功、失败、超时或取消都最多独立尝试一次 best-effort `clean`，清理失败不覆盖原结果。搜索中条件冻结但关闭/取消可用；关闭清除本地输入，旧目录、旧 profile、旧 repository 与 A→B→A 迟到结果不回写。只有用户明确选择且既有创建结果链确认后才报告任务创建；提交未知不自动重放。
- 回传：仅提供平台/系统/App、DSM 与 Download Station 脱敏版本、连接方式类别、提供方/类别数量级、操作阶段、请求方法名、调用次数、页面状态和脱敏错误分类；不得回传搜索词、结果标题、下载 URI、task ID、保存路径、NAS 地址、账号、SID、Token、Cookie、原始响应或截图中的用户数据。
- 影响范围：只覆盖 BTSearch 提供方/类别目录、有界搜索、临时任务清理和单结果复用既有创建链；不包含 BT 协议高级设置、Tracker/Peer、RSS、文件优先级、监听目录、NZB 服务器、批量创建、删除已下载数据或 Download Station 设置写。

## 5. 第 0 波出口

- Windows：完成 Domain / Repository 拆分、会话与严格 Range 基础、只读 Files 浏览、服务端排序与类型筛选、普通单文件下载/上传与 Activity、W3-A 文件系统照片库、PHOTO-01 用户主动有界时间线、W3-B Chat、W4 Download Station 与 W4-B0 VMM 官方五分区只读闭环；后续第 1–4 波又完成证书安全、FILE-03 新建/重命名、FILE-05 单文件复制/移动、PHOTO-03A 单项导入、FILE-09 回收站入口、Chat 纯文字发送以及 Download Station 单任务控制、链接/任务文件创建、单任务删除、只读当前活动摘要、BTSearch v1 和 ACT-01 活动中心首片。正式 ACT-01 提交 `2491212` 的 GitHub Windows CI run `31360092210` 已通过 889/889 项 xUnit，并完成 WinUI x64 与 ARM64 构建；真实 Windows 交互和真实 NAS 继续后置用户验证。
- Apple：DsmMobile Sources 拆分、五入口导航、统一五态/token、M1 会话与证书、M2 前台单文件传输与 Activity、M3 大目录浏览/排序筛选/基础详情、FILE-02 只读位置、FILE-07 单对象分享链接、FILE-08 图片/PDF/文本/音视频只读预览、M4-A1 文件系统照片空间、PHOTO-01 有界时间线、M5-A1a Chat 只读历史、M6-S0 Download 只读详情、M7-A NAS 健康、M7-B1a VMM Guest、M7-B2 Container 实例及 SET-01 已完成第 0 波源码与聚焦自动化。后续第 1–4 波又完成 PHOTO-02 查看增强、PHOTO-03A 单项导入、FILE-03/05/09 受限写、Chat 纯文字发送以及 Download Station 单任务控制、链接/任务文件创建、单任务删除、只读当前活动摘要、BTSearch v1 和 ACT-01 活动中心首片；正式 ACT-01 提交 `2491212` 的 GitHub Apple Build run `31360092209` 已覆盖共享包、iPhone/iPad 通用应用构建和 macOS 打包。最新完整 iPad 真机交互、真机系统集成与真实 NAS 保持 `PENDING_USER_VALIDATION`；Chat 附件/实时、Download 高级能力和其他长期范围继续列入后续独立契约切片。
- 两端：本波仅新增已记录的公开 File Station 列表/上传契约，不修改 Android、不修改 macOS App、不增加依赖、不改变签名与持久化结构。
- 后续只在对应依赖出口通过后启动非重叠切片；M1 会话/AppShell 可与 M0 CommonUI/范围测试串行集成，不能把局部通过写成 M0 全部完成。

## 6. 重新对照总计划后的剩余进度

第 0 波已经形成可构建、可测试的跨端基础和多项只读/低风险主流程，但它不是总控计划的最终完成点。以下项目仍属于当前 Windows 全量对齐或 Apple 移动端核心/受限范围，必须在后续波次继续实现；没有稳定契约或真实行为证据的写入口继续保持关闭，不能用本波的 `BUILD_VERIFIED` 冒充功能完成。

### 6.1 Windows 后续波次

1. **W1 认证与统一状态**：自签名证书首次核对、按 profile 固定、变化阻断和连接来源说明已进入 Windows；统一 `ModuleAvailability` 原因与恢复动作、真实连接验收和部分旧写结果迁移仍按后续切片推进。
2. **W2 Files 完整桌面工作流**：新建/重命名、单文件同 NAS 复制/移动、移入回收站与恢复已进入 Windows；文件夹/批量传输、跨 NAS、覆盖、永久删除、冲突高级处理和 Activity 深度联动仍保持独立后续范围。
3. **W3 Photos 与 Chat**：PHOTO-01 时间线、PHOTO-03A 单项导入和 Chat 受限纯文字发送已完成当前低风险闭环；Windows PHOTO-02 查看器/基础元数据已接入文件夹与时间线媒体打开、右侧预览、前后切换、图片尺寸展示和保存副本，并随基础查看器提交 `4e1272e` 通过 Windows xUnit、WinUI x64/ARM64 和 Repository Check；更完整 EXIF/沉浸式细节、Chat 附件后的实时、更多消息动作、照片更完整管理和真实设备/NAS 验收仍按套件版本与真实环境验证推进。
4. **W4 服务与 NAS 管理**：Download Station 单任务暂停/继续、URL/磁力创建、任务文件创建、单任务删除、BTSearch v1 和 ACT-01 活动中心首片已进入 Windows/iPhone/iPad；Apple shared/mobile 与 Windows Domain/Infrastructure/ViewModel/WinUI 均完成当前闭环。Apple 本机共享聚焦 65/65、共享全量 675 项 XCTest（2 跳过）+10 项 Swift Testing、iPhone 模拟器 11/11 已通过；Windows BTSearch 专项自动化为 8 项 Repository、15 项 ViewModel 与 3 项 source-contract，共 26 项。正式 ACT-01 提交 `2491212` 已通过 Repository Check run `31360092211`、Apple Build run `31360092209` 和 Windows Build run `31360092210`，其中 Windows 为 889/889 项 xUnit 并完成 WinUI x64/ARM64 构建。真实 NAS、iPad 与 Windows 交互后置；RSS、文件优先级、BT 协议高级设置、设置写、Container/VMM 计划内剩余分区和 NAS 管理继续按公开或已记录契约分区推进。Container/VMM 高风险写与 VMM 控制台在契约和实机开放门前不启用。
5. **W5/W6 系统集成与发布**：Cloud Files 继续保持默认关闭，等待 Explorer/Office/Win32 写入安全矩阵；补托盘/通知/安装卸载生命周期、真实 x64/ARM64 设备、Narrator、高 DPI、多显示器和真实 NAS 验收。

### 6.2 iPhone / iPad 后续波次

1. **M3 Files 受限写**：新建文件夹、重命名、有界同 NAS 复制/移动、移入回收站与恢复已完成当前单项闭环；复杂归档、跨 NAS、大批量、覆盖和永久删除继续排除。
2. **M4 Photos 主动导入与受限管理**：`PhotosPicker` 单项主动导入、基础元数据查看和 `#recycle` 普通文件恢复已进入当前范围；更完整的 NAS 内移动/整理、自动备份和整库权限仍是后续独立决策，不申请整库权限，不加入后台扫描。
3. **M5 Chat 核心与附件**：受限纯文字发送已接入；附件选择、上传、保存、预览、前台实时/轮询降级和更多消息动作仍需版本化契约与真实 Chat Server 验收，没有版本化内部写契约时入口继续关闭。
4. **M6/M7 受限服务能力**：Download Station 已完成 URL/磁力创建、任务文件创建、单任务暂停/继续、单任务删除、BTSearch v1 和 ACT-01 活动中心首片；搜索共享契约、移动 Sheet、结果创建链、48 项英中资源和 iPhone 模拟器聚焦已经收口，本地共享聚焦、共享全量与移动聚焦均通过，正式 BTSearch 提交 `5850f4c` 的 Apple Build run `31356270194` 已验证 BTSearch，正式 ACT-01 提交 `2491212` 的 Apple Build run `31360092209` 又通过共享包测试、iPhone/iPad 通用构建和 macOS 打包。iPad/真机与真实 NAS 仍待完成。RSS、文件优先级、BT 协议高级设置和设置写继续关闭；NAS 侧下一步只推进有界只读详情，不把连接断开、套件生命周期、任务执行或设置写带入移动端。
5. **M8/M9 iPad 与自动化收口**：补 iPad 紧凑/常规宽度切换、焦点、键盘、指针、拖放可见替代动作和全范围自动化；真实分屏、旋转、外接输入、VoiceOver、系统选择器、正式签名与真实 NAS 统一保留为 `PENDING_USER_VALIDATION`。

### 6.3 下一实现顺序

BTSearch 与 ACT-01 首片均已通过 Apple/Windows/Repository 云端门禁；BTSearch 另覆盖 Android 云端门禁。两者都只剩真实 NAS、iPad、Windows 交互和无障碍验收，不再占用下一功能波次。ACT-01 首片已把 App 前台传输与 Download Station 已加载任务快照按来源做只读投影。后续顺序调整为：第一，CHAT-03 先补 Apple 单附件 typed outcome 与 Windows 上传、缩略图、下载 typed 契约，再接附件 UI；第二，NAS-02/NAS-04 有界只读详情与 Chat 契约并行；第三，ACT-01 后续再补 Activity 主动刷新 NAS/Download、NAS 文件后台任务和系统通知。Chat 实时、Download RSS/文件优先级/BT 协议高级设置、Container/VMM 高风险写和无证据端点继续后置。每个写切片仍须满足稳定目标、一次提交、结果回读和提交后不自动重放。
