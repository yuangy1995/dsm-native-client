<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-03 -->

# Windows 对齐 macOS 功能长期计划

## Download Station 契约影响（2026-10-05）

Apple 移动 M5a1 新增完整任务目录与官方单项详情，并修正共享公开控制/创建/移除结果的分页完整性。Windows 本轮不改实现；后续核实不能以首批任务判断对象不存在，缺失速度/剩余时间显示 `--`，Task.edit 须使用官方字段表要求的 v2。公开 RSS 只提供已记录的订阅查看/刷新和条目读取，不推定创建/删除订阅接口。跨端证据与当前差异见[下载接口说明](../api/reference/download-station.md)。

Apple 移动 M5a2 补充逐项写前保存、未知只读恢复与剩余显式继续/取消；同一任务的反向控制和移除也受未结束记录约束。Windows 后续对齐应保留该结果语义，本轮不改 Windows 源码。

## 置顶读取更正（2026-10-03）

当前官方页面只读证据确认 Post.search 的 channel_id 不能限定置顶会话，正确字段为数字 in 数组。本平台本轮不改代码；现有同类请求需后续授权切片修正，不能标为仅待真机。 参数、失败语义与五端边界见[消息交互记录](../api/discovery/endpoints/chat-message-interaction.md#2026-10-03-置顶搜索修正)。


## Chat 五组新基线影响（2026-10-03）

macOS 新增旧消息搜索、本人编辑、文字线程回复、参与投票、媒体/录音和通知/跨端已读。本轮 Windows 只登记后续对齐切片，未改代码，不标成仅待真机验收；按 WinUI 列表、键盘、原生媒体及通知完成独立实现和自动化。当前真实契约纠正：Post.list 使用 post_id/prev_count/next_count，投票创建 choices 为 text 对象数组、options 为对象，真实投票在 props.vote；旧 Windows 请求/解析需要后续核实。保留 Windows 既有用户授权的能力策略，不依据 macOS 的设备记录扩大 Windows 的验证结论。详见[消息交互契约](../api/discovery/endpoints/chat-message-interaction.md)与[功能账本](MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md)。


## NAS 设置与套件中心新增基线影响（2026-10-03）

macOS 本轮新增内存压缩保存、完整电源计划编辑及套件目录/安装/更新/手动上传/进度/设置/来源管理。Windows 仅记录后续对齐切片，本轮未修改实现，也不标记为仅待真机验收。后续须按 WinUI 文件选择器、列表、对话框和后台状态习惯实现：ZRAM 的 enable_zram 与 NeedReboot 独立标记、200 条双数组电源计划、available_operation 对象、依赖计划确认、签名/许可、未知提交只核查与目标版本确认。enable_port_check 的用户含义是防火墙通知，提示音与风扇按真实设备支持位显示。静态/合成证据不能代替 Windows 构建或真实 NAS 验收。契约及源文件见 [NAS 设置账本](NAS_SETTINGS_WEB_AUDIT_20261002_ZH.md)；依赖安装、状态恢复、写入和原生 UI 应作为完整功能切片，不复用旧直接 upgrade 控制。

同日反馈修复补充：套件预检成功可以没有 data；Setting.get 的 update_channel 为 Boolean，set 仍为 stable/beta，单卷 default_vol 可缺省。macOS 已修正并同步应用实际加载的双语资源；其他平台实现范围保持上述取舍。官方单个 MediaServer 更新已成功，但不能代替任何目标客户端的真实提交验收。详见[反馈修复账本](PACKAGE_CENTER_FIX_20261003_ZH.md)。 后续确认 system/system_hidden 可以缺省普通存储列表；安装准备取消须丢弃迟到结果，已提交安装只关闭窗口后台继续。照片过期操作反馈修复仅涉及 macOS 模型，不改变五端照片读取/写入契约。见[二次反馈账本](PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)。

## File Station 新增基线影响

macOS 文件夹上传、条件/全文搜索、逐项分享/收集、归档、权限/所有者、ISO、FTP/SFTP/WebDAV 连接管理、套件设置及指定后台任务控制构成后续 WinUI 适配基线，本轮不修改 Windows 功能。保留每目标独立结果、密码意图、空选择拒绝解压、继承与递归确认、版本/权限保护、未知写不重放和会话核查等语义；UI 按 Windows 选择器、拖放、键盘与窗口习惯实现。正式云授权回调、远程 URI 浏览下载、域/LDAP 挂载名单及分享页换图已在 macOS 接入，仍不能把其合成自动化或真实云授权假设当作 Windows/NAS 验收。证据与请求样本见 [File Station 账本](../../apple/Apps/DsmMac/README.md)。


## Office 本机编辑的新增语义基线

macOS 已接入六种 Office 扩展名的系统预览，以及“选择本机副本 → 默认或自选应用打开 → 保存稳定后自动回传”的流程。Windows 同类流程尚未在本轮接入，属于后续对齐范围，不能标为已实现或仅待真机验收。后续按 Windows 文件选择器、文件关联和窗口习惯实现，保持未修改零上传、原 NAS 目标绑定、独立快照、权限检查、冲突暂停、未知结果只回查及退出保留本机副本；不直接复用 Quick Look、NSWorkspace 或 macOS 文件监测机制，也不等同于 Explorer/Cloud Files 写回。没有新增共享 API 或持久化契约，具体源码和边界见 [Office 账本](../../apple/Apps/DsmMac/README.md)。

## 目标

Windows 使用 C# 与 WinUI 3，目标是在符合 Windows 键鼠、触控、窗口、资源管理器和系统
通知习惯的前提下，对齐 macOS 已承诺的业务与安全语义。当前状态见
[开发进度](../progress/STATUS.md)，跨端范围见[平台功能矩阵](../progress/PLATFORM_MATRIX.md)，
总控规则见[macOS 对齐总控计划](MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)。

## 不变量与代码边界

- 保持 `IDsmApiClient`、`DsmApiClient`、DI、`HttpClient` 生命周期和证书策略。
- 不新增程序集引用、不删除 Windows Application 项目、不重做 solution 架构。
- 保持 profile、会话、证书、能力、模块、导航、缓存和传输的隔离边界。
- 保持公开 API 的固定版本、参数编码、错误映射和 `MutationResult` 语义；私有写在未知
  DSM build 或套件版本默认关闭。
- 不改变当前发布形态、签名、Identity、最低系统版本或数据格式；这些变更必须单独批准。
- 所有新增用户可见文案同时提供英语和简体中文 `.resw` 资源。

## 当前结构与拆分方向

```text
windows/src/LanStash.Domain/          领域模型和跨模块契约
windows/src/LanStash.Infrastructure/  DSM 传输、会话、Repository 和平台无关实现
windows/src/LanStash.App/             WinUI Shell、页面、ViewModel 和平台适配
windows/tests/LanStash.Tests/         自动化测试
```

保留 `DsmApiClient` 门面，按现有 partial 文件方向拆分以下职责：

1. transport；
2. authentication；
3. discovery；
4. multipart upload；
5. download stream；
6. response decoding；
7. certificate policy。

拆分只能移动既有实现，不改变 API、DI 注册、`HttpClient` 复用、证书校验或异常语义。每个
partial 文件保持单一领域边界，并以源级契约、fixture 或 xUnit 证明行为不变。

## 已完成的基础范围

下表对应 2026-09-21 已交付基线；后续 macOS 新增 Photos、File Station 和 Office 仍按下节推进。已有源码与云端构建证据不代表真实 NAS、Explorer 或系统集成验收。

| 范围 | 当前入口与可复核源码 | 证据与边界 |
| --- | --- | --- |
| 认证、多 NAS、QuickConnect、证书 | `Features/Authentication`、`DsmApiClient`、Shell 连接上下文 | Authentication/SessionRequestParity/QuickConnect/Certificate 测试进入完整 xUnit；不同真实网络另验。 |
| Files、传输、复杂操作 | `FilesPage` 各 partial、`Features/Files`、`Features/Transfers` | 搜索、上传下载、目录/批量、文本预览编辑、压缩解压、分享、回收恢复、跨 NAS、拖放及撤销有专用测试和原生场景；真实数据副作用另验。 |
| Photos | `ShellPage → SynologyPhotosPage`、`SynologyPhotosWorkspace`、Synology Repository | 初始 UTC 范围、1970 下限、分页、筛选、保存/个人单项删除和错误恢复回归；错误不再假装空图库。当前 Mac 无自动备份/RSS 等新承诺，不据总称扩张范围。 |
| Chat | `ChatPage`、`ChatBrowserViewModel`、ChatAdvanced/Actions/Realtime | 消息、附件、成员、公告、提醒、定时、投票及已实现高级动作接入；未知结果不重发。Mac 尚未实现的加密/通话不伪装已实现。 |
| Download Station | `DownloadStationPage`、Settings/Batch/CreateFile/BtSearch | 设置、批量、任务文件创建与选项已接；`force_complete` 按保留未完成文件的语义处理，不冒充删除数据。 |
| NAS 管理 | `NasDetailsPage` 与 `Features/NasAdmin` 专用编辑/确认/恢复 | 系统、账号群组、网络、安全、硬件、电源、套件、计划、连接、硬盘和远程访问按已记录契约接入。电源计划、外接存储、内存压缩遵循 Mac 只读基线。 |
| Container/VMM | 两个正式管理页及 `Features/Containers`、`Features/VirtualMachines` | 生命周期、映像、网络、创建、设置、控制台、任务和恢复均有专用测试/原生场景；实际 VM/容器及控制台画面另验。 |
| 云盘 | `DesktopCloudDriveService`、SyncStore、三组协调器、`CloudDriveWriteScope`、设置/恢复窗口 | 分段读取、版本、保存、新建、移动/改名、删除、缓存和已完成副本回收已接；指定文件夹与全部共享内部均支持，挂载/共享根仍保护。日志版本 10 向后读取、旧包拒绝新格式并保留内容。 |
| 托盘、通知、本地设置 | `MainWindow` 注入 WindowsTransferNotificationService，Shell/生命周期及设置入口 | Null 服务仅作未注入后备，不是生产恒关；对应生命周期测试与原生场景存在。系统通知、外接卷、辅助功能及安装升级由用户后置验证。 |
| Mac 1.0.9 及同类修复 | Apple 共享 Repository、Workspace/SynologyPhotos/ServiceManagement/NasAdministration | 对应 Apple 集成构建与源码一致性检查已完成；精确提交和结果集中在验证历史。 |

上述源码相对路径位于 `windows/src/LanStash.App`，网络适配位于
`windows/src/LanStash.Infrastructure`；测试位于 `windows/tests/LanStash.Tests`。
接口见[功能 API](../api/README.md)，精确测试命令和包摘要见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。


## 下一阶段对齐顺序

1. **Photos 管理**：按[照片 API](../api/reference/photos.md)拆分上传/恢复、相册/分享、元数据/目录、人物/相似组、预览转换/后台任务及设置。先比较现有 Repository 与共享请求，记录缺口后补 WinUI 用户主流程。
2. **File Station 增量**：按[文件 API](../api/reference/files.md)对齐高级/全文搜索、逐项分享/收集、归档选取、权限/所有者、ISO/VFS、授权回调、设置与指定任务控制；保持 Windows 选择器、拖放、键盘与原生窗口。
3. **Office 编辑**：使用系统文件关联与用户指定副本，保存前核对原目标和版本，结果不明只回查；不照搬 macOS 轮询/Quick Look，也不混同 Cloud Files 写回。
4. 每一切片分别完成领域/请求测试、WinUI 接线、原生五态与双语主题检查，再进入 x64/ARM64 完整构建；不要等所有功能完成才集成。

## Windows 平台转换与恢复

- Shell、设备侧栏、工具栏、网格和详情延续已确认的 macOS 布局层次，控件/焦点/触控/窗口遵循 WinUI/Fluent。视图异步结果必须绑定当前 profile、模块、导航代次。
- 注入现有传输通知与托盘生命周期服务；不能用 Null 后备服务推断生产始终关闭。
- NAS 专用写入口按实际接口和管理员/目标权限判断；旧通用入口恒关不代表专用入口关闭。确认绑定当前输入，密码用后清除，迟到结果与未知写不自动重复。
- 云盘通过设置明确授权系统集成，再按映射开启编辑；删除另行确认。指定文件夹及全部共享内部的写回、创建、移动/改名、删除和恢复遵循[桌面云盘计划](NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)。挂载根及共享根受保护。
- 存储日志 v10 向后读取；旧版本遇到新格式拒绝并保留内容，不覆盖或重建。更改格式、依赖、身份或安装形态需另行授权。

## 验证与交接

```powershell
dotnet restore windows/LanStash.slnx
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore
dotnet build windows/src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-x64 --no-restore
dotnet build windows/src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-arm64 --no-restore
```

完整目标构建需 Windows 工具链或托管 Runner，其他平台的核心库编译不能替代。运行仓库现有原生 UI 与 CloudFilesNativeChecks 场景，保存脱敏结果；既有云端证据只作为对应提交的历史记录，不冒充新改动回归。

`PENDING_USER_VALIDATION`：在专用 Windows 设备、可丢弃 NAS 数据与可恢复同步根上，验证登录/证书、媒体和外部编辑器、权限拒绝、断网/重启、Explorer 占位与写回、通知/外接卷、辅助功能、安装升级及卸载。预期确认/权限/防重复/回读有效、未知不重放、失败保留本机内容。仅回传版本类别、步骤、结果与脱敏错误。

每轮建立 macOS 证据 → Windows 等价语义 → 契约/权限 → 原生交互 → 自动化/构建 → 用户验收账本；共享热点由单一负责人修改。交接列出修改、实际命令/结果、失败、剩余步骤和工作区保护范围。macOS 新增但 Windows 未实现的能力必须记录为待开发，不能只写待验收。

2026-10-03 容器契约补充：Registry.search 必须固定 v1（v2 实测 103）；下载任务 1202 为已观察的 Docker 失败路径，传输读取失败应保留原任务自动恢复。详见 `MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md` 和当日发现记录。本端未新增功能或私有写开放结论；Apple 共享层另做构建回归。
