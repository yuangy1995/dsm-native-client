# 当前私有 API 端点组索引

本页按稳定业务边界汇总源码已经接入或明确保持关闭的内部 API。端点组用于减少重复，但每个 API 名称仍逐项列出。版本含义必须结合环境 verification 阅读：

- “客户端范围”来自 `DsmCapabilityDiscovery.supportedRanges`，不是某台 NAS 的实机承诺。
- “当前确认”来自 [`lab-a` 当前基线](../environments/2026-07-29-lab-a-dsm-69057-u12.md) 所引用的既有脱敏发现证据。
- 同一端点组可以在不同 NAS 或版本下拥有不同 verification，不复制端点定义。

## 端点组

2026-09-19 Windows 已按用户授权开放现有 NAS 专用管理和容器网络验证入口，保留
接口、权限、确认、预检、防重复及结果核查；不再仅因未行为验收固定关闭。旧通用
辅助/未实现能力不包括在内，记录中的历史关闭状态以此客户端补充为准，API 契约和
真实环境证据不变。详情见 [Windows 开放账本](../../../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-09-19-可测试入口开放nas-专用流程与容器网络)。

2026-09-19 Windows Chat 高级入口策略已更新：移除单一 DSM/套件 build 白名单及
系统套件列表依赖，普通 Chat 用户按绑定会话和对应接口能力使用；操作前仍核对会话
可访问性、消息归属，保留确认/去重/结果核查。仅客户端授权策略变化，无新 API 或
真实行为证据；其他四端不改。见 [Chat 开放账本](../../../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-09-19-可测试入口开放chat-高级操作)。

### Container 映像列表与下载任务边界

- [映像列表精确参数、任务静态线索与未验证语义](container-manager-internal.md#2026-09-17-映像列表与下载任务分离)。
- Image.list 请求/字段结构已在待归属环境只读验证；pull_status 和聚合任务列表仅有静态线索，下载写操作仍未验证。

### 任务计划读取与管理边界

- [TaskScheduler v3/v4 与 EventScheduler v1 方法级契约](dsm-task-scheduler.md)。
- 整理已有 NAS 管理切片，不增加真实环境证据等级；脚本及输出只在当前窗口使用。

### `photos-item-deletion`

- 内部危险写接口，已完成单张合成 PNG 的真实删除与刷新回读；macOS 按接口能力跨 DSM／Photos 版本开放个人空间供测试，共享空间关闭。
- [删除边界、版本门禁及待验证事项](photos-item-deletion.md)。

### `photos-library-read`

- 2026-09-10 已补入系统分类、服务端筛选、共享三个只读列表与实况视频单元；共享创建／撤销仍未启用，详见端点最新补充。

- 组件：`synology-photos`；2026-09-09 Photos 1.8.2-10090 个人空间时间线、项目、文件夹、搜索和分类读取结构已有官方网页成功响应证据。
- 设备匿名归属未确认；App 会话与共享空间未验证，全部写入口保持关闭。
- 完整替换正在实施，macOS 个人空间只读入口已切换至 Photos；共享空间、写操作与其他端迁移仍未完成。
- [请求结构、版本、实现与限制](photos-library-read.md)。

### `dsm-desktop-app-privileges`

- 组件：`dsm-core`；内部只读候选 `SYNO.Core.Desktop.Initdata` v1 / `get_user_service`。
- 2026-09-09 非管理员官方网页成功响应含 `AppPrivilege` 和 `Session.is_admin`；应用授权摘要与官方菜单形成交叉证据。
- 设备匿名归属尚未确认，不挂靠既有 `lab-a` verification。macOS 已按用户确认的“应用明确授权、管理模块要求管理员”策略接入；App 会话实机待验。有效空表与整个摘要缺失分别处理，不加载组件业务数据试权限。
- [请求、响应、安全限制及五端影响](dsm-desktop-app-privileges.md)。

### `quickconnect-relay-control`

- 组件：`dsm-core`
- 内部协议：QuickConnect `Serv.php`；[区域转介、信任范围与五端影响](quickconnect-relay-control.md)。
- 命令：`get_server_info`、`request_tunnel`
- 数字 API 版本：不适用
- 当前证据：中继建立、目标身份核对及随后 `SYNO.API.Info` 探测已有行为记录。
- 降级：直连候选全部失败时才尝试；中继异常时停止，不绕过证书或身份核对。

### `file-station-remote-mount`

- 组件：`file-station`
- API：`SYNO.FileStation.Mount`
- 客户端范围：v1
- 当前确认：v1 `mount_remote`、`unmount` 为内部实验性契约。
- 新字段证据与旧实现偏差见[远程挂载记录](file-station-remote-mount.md)；Mount.List.get 空列表已只读核对。
- 状态：候选写能力；需要专用环境完成权限、错误凭据、重连、重复提交和公开 `getinfo` 回读验证。

### `dsm-system-observability`

- 组件：`dsm-core`
- API 与当前确认：
  - `SYNO.Core.System`：`info` v3。
  - `SYNO.Core.System.Utilization`：`get` v1。
  - `SYNO.Core.System.Process`：客户端保守范围 v1，`list` 只读适配等待真实响应验证。
  - `SYNO.Core.System.ProcessGroup`：客户端保守范围 v1，`list` 可选降级；
    `service_info` 保持关闭。
  - `SYNO.Core.CurrentConnection`：`list` / `kick_connection` v1；只读列表已核对，断开未执行。
  - `SYNO.Core.SyslogClient.Log`：`list` v1。
  - `SYNO.Core.Upgrade.Server`：`check` v3。
  - `SYNO.LogCenter.History`：客户端范围 v1；无记录时允许空结果。
- 降级：性能、连接、日志或更新检查失败时各自显示不可用，不阻断其他 NAS 管理能力。
- 电源动作稳定记录：[DSM 关机与重启内部 API](dsm-system-power-actions.md)。
- 当前连接稳定记录：[DSM 当前连接内部 API](dsm-current-connection.md)。列表已只读核对，
  断开写行为仍待专用目标验证。
- 系统更新检查稳定记录：[DSM 系统更新检查内部 API](dsm-system-update-check.md)。当前
  仅允许 `check` 只读请求，下载、安装、取消和重启任务保持关闭。
- 系统进程稳定记录：[DSM 系统进程与服务进程组内部 API](dsm-system-processes.md)。
  当前只展示字段白名单后的单次快照，不读取命令行、路径、账号或网络地址，也不提供
  结束进程操作。

### `dsm-storage-hardware`

- 组件：`dsm-core`、`storage-manager`
- API 与客户端范围：
  - `SYNO.Storage.CGI.Storage` v1。
  - `SYNO.Storage.CGI.Smart` v1。
  - `SYNO.Core.Storage.Volume` v1。
  - `SYNO.Core.Storage.Disk` v1。
  - `SYNO.Core.Hardware.PowerRecovery`、`Led.Brightness`、`FanSpeed`、`BeepControl`、`Hibernation` v1。
  - `SYNO.Core.Hardware.PowerSchedule`：客户端保守范围 v1；仅启用 `load`，
    `save` 保持关闭。
  - `SYNO.Core.Hardware.ZRAM`：客户端保守范围 v1；仅启用 `get`，`set` 保持关闭。
  - `SYNO.Core.ExternalDevice.UPS` v1。
  - `SYNO.Core.ExternalDevice.Storage.USB`、`Storage.eSATA`：客户端保守范围 v1；
    仅启用 `list`，USB `eject` 保持关闭。
- S.M.A.R.T. 稳定记录：[DSM S.M.A.R.T. 检测内部 API](dsm-smart-test.md)。
- 硬件设置稳定记录：[DSM 硬件与 UPS 设置内部 API](dsm-hardware-settings.md)。
- 电源计划稳定记录：[DSM 电源计划内部 API](dsm-power-schedule.md)。当前只读取动作、
  启用状态、时间、命名星期、一次日期和可选时区，最多 128 条，不发送 `save`。
- 内存压缩稳定记录：[DSM 内存压缩（ZRAM）内部 API](dsm-zram.md)。当前只读取启用
  状态、明确字节容量和算法白名单，不发送 `set`；官方页面已观察但 API 响应未验证。
- 打印机 Bonjour 共享稳定记录：[DSM 打印机 Bonjour 共享内部 API](dsm-printer-bonjour-sharing.md)。
  当前只有静态 API 名称与 `get`，版本、参数和响应均未知，客户端保持关闭且零请求。
- 外接存储稳定记录：[DSM USB 与 eSATA 外接存储内部 API](dsm-external-storage.md)。
  当前每种连接最多读取 64 项白名单摘要，不读取路径、序列号或共享名，不发送 `eject`。
- 当前确认：`Storage.load_info` v1 与硬盘检测读取结构已核对；`Storage.Volume.list` 在当前环境返回错误 `101`；S.M.A.R.T. 启停和硬件设置没有为发现而执行。
- 降级：以 `load_info` 为主，不使用失败的 `Volume.list` 覆盖有效结果；写入口按能力与权限逐项关闭。

### `dsm-administration`

- 组件：`dsm-core`
- 套件与任务：
  - `SYNO.Core.Package` v1-v2，当前列表使用 v2。
  - `SYNO.Core.Package.Control`、`SYNO.Core.Package.Uninstallation`、`SYNO.Core.Package.Thumb` v1。
  - `SYNO.Core.TaskScheduler` v1-v4；列表/运行使用 v3，详情/创建/修改使用 v4。
  - `SYNO.Core.EventScheduler` v1。
- 控制面板：
  - `SYNO.Core.Terminal`、`SYNO.Core.FileServ.SMB`、`SYNO.Core.FileServ.NFS` v1-v3。
  - `SYNO.Core.FileServ.FTP`、`SYNO.Core.FileServ.FTP.SFTP`、`SYNO.Core.Network.Proxy` v1。
  - `SYNO.Core.QuickConnect` v1-v3、`SYNO.Core.QuickConnect.Upnp` v1。
  - `SYNO.Core.Security.AutoBlock`、`SYNO.Core.FileServ.ServiceDiscovery` v1。
  - `SYNO.Core.Web.DSM`、`SYNO.Core.Network.Ethernet`、`SYNO.Core.Security.DoS` v1-v2。
  - `SYNO.Core.Region.NTP` v1-v3。
  - `SYNO.Core.DDNS.Provider`、`SYNO.Core.DDNS.Record` v1。
  - `SYNO.Core.Security.Firewall`、`Firewall.Conf`、`Firewall.Profile.Apply` v1。
- 远程访问稳定记录：[DSM 远程访问设置内部 API](dsm-remote-access-settings.md)。
- 文件服务稳定记录：[DSM 文件服务设置内部 API](dsm-file-service-settings.md)。
- 远程终端稳定记录：[DSM 远程终端设置内部 API](dsm-terminal-settings.md)。
- 互联网代理稳定记录：[DSM 互联网代理设置内部 API](dsm-proxy-settings.md)。
- 区域与时间稳定记录：[DSM 区域与时间设置内部 API](dsm-region-time-settings.md)。
- DDNS 稳定记录：[DSM DDNS 设置内部 API](dsm-ddns-settings.md)。
- 套件启动与停止稳定记录：[DSM 套件启动与停止内部 API](dsm-package-control.md)。
- 套件安装与升级边界：[DSM 套件安装与升级内部 API 边界](dsm-package-installation.md)。
  当前只解释 `Package.list` 明确返回的 `upgrade` 为非交互提示；
  `Package.Server` 与 `Package.Installation` 保持关闭。
- 共享访问稳定记录：[DSM 共享文件夹访问权限契约](dsm-share-access.md)。当前仅使用公开
  File Station `list_share` 展示登录账号可见的有效权限；内部
  `SYNO.Core.Share.Permission.list_by_user` 只有静态方法名证据，保持关闭。
- 当前证据：只读结构、网页请求和能力发现已分项记录；套件启停/卸载、任务写入、网络、防火墙等不得仅凭同一端点组标记为行为验证。

### `dsm-account-directory`

- 组件：`dsm-core`
- API：`SYNO.Core.User`、`SYNO.Core.Group` v1。
- 稳定记录：[DSM 账号与群组目录内部 API](dsm-account-directory.md)。
- 当前证据：只读结构与网页请求为 `observed`；账号和群组写行为尚未在专用环境完成
  `behavior-verified`。

### `dsm-ethernet-settings`

- 组件：`dsm-core`
- API：`SYNO.Core.Network.Ethernet`，列表 v2、详情与设置 v1。
- 稳定记录：[DSM 物理网卡设置内部 API](dsm-ethernet-settings.md)。
- 当前证据：只读结构与网页请求为 `observed`；网卡写行为尚未在专用网络完成
  `behavior-verified`。
- 降级：能力、权限或写后回读不满足要求时关闭写入口，不自动提升权限或重放请求。

### `dsm-security-settings`

- 组件：`dsm-core`
- API：`SYNO.Core.Security.AutoBlock`、`Security.DoS`、`Security.Firewall`、
  `Firewall.Conf`、`Firewall.Profile.Apply`。
- 稳定记录：[DSM 安全防护与防火墙设置内部 API](dsm-security-settings.md)。
- 当前证据：只读结构与网页请求为 `observed`；合成请求、部分成功、断网、取消和重复
  提交测试不提升当前环境的写行为证据等级。
- 降级：任一实际变化缺少能力或完整预检时不提交；提交开始后失败必须先回读，不自动
  重放复合设置。

### `download-station2-fallback`

- 稳定记录：[Download Station 2 内部降级接口](download-station2-fallback.md)。
- 组件：`download-station`
- API 与客户端范围：
  - `SYNO.DownloadStation2.Task` v1-v2。
  - `SYNO.DownloadStation2.Task.Statistic` v1。
  - `SYNO.DownloadStation2.Settings.Location` v1。
  - `SYNO.DownloadStation2.RSS.Feed` v1。
- 既有静态目录还包含 `Task.List`、`Task.List.Polling`、BT Tracker/Peer/File，但未进入当前稳定能力表。
- 状态：仅在官方 `SYNO.DownloadStation.*` 缺少必要能力且运行时明确发现时使用。

### `vmm-internal`

- 稳定记录：[Virtual Machine Manager 内部接口](vmm-internal.md)。
- 组件：`virtual-machine-manager`
- API 与客户端范围：
  - `SYNO.Virtualization.Guest`、`Guest.Image`、`Host`、`Repo`、`Network`、`GuestProtect.Plan` v1-v2。
  - `SYNO.Virtualization.Guest.Action` v1。
  - `SYNO.Virtualization.Log` v1。
- 当前确认：VMM `2.6.5-12202` 的读取方法、日志 v1 参数和 noVNC 地址生成逻辑已有记录；网络 `set/delete`、创建和修改未形成写行为验证结论。
- 降级：优先公开 `SYNO.Virtualization.API.*` v1；内部读取不可用时保留明确的不可用状态。

### `container-manager-internal`

- 稳定记录：[Container Manager 内部接口](container-manager-internal.md)
- 组件：`container-manager`
- API：`SYNO.Docker.Container`、`Image`、`Registry`、`Network`、`Project`、`Log`
- 客户端范围：全部 v1
- 当前确认：Container Manager `24.0.2-1535` 下，容器列表、仓库搜索和标签参数已经核对；镜像拉取请求在发送前终止。
- 状态：读取按能力降级；所有写行为仍需专用目标验证。

### `chat-internal`

- 2026-09-16 Windows 提醒、定时、投票、批量关闭/转发/本人消息删除、新联系人转发与公告的请求/响应映射、安全门、五端影响与待验收集中在
  [高级动作记录](chat-advanced-actions.md)。只有源码与合成证据，未新增 NAS 写入行为验证。

- 组件：`synology-chat-server`
- API 与客户端范围：
  - `SYNO.Chat.Channel` v1-v5。
  - `SYNO.Chat.Channel.Named` v1。
  - `SYNO.Chat.Channel.Anonymous` v1-v2，当前确认 `initiate` v2。
  - `SYNO.Chat.Channel.Member` v1。
  - `SYNO.Chat.User` v1-v3、`SYNO.Chat.User.Avatar` v1。
  - `SYNO.Chat.Post` v1-v8；当前确认的创建、转发与公告方法使用 v5。
  - `SYNO.Chat.Post.File` v1-v2，当前确认 v2。
  - `SYNO.Chat.Post.Reminder`、`Post.Vote`、`Post.Schedule` v1。
- 当前证据：Chat Server `2.4.1-22111` 官方网页客户端与能力发现契约；读取、创建、删除、提醒、投票等仍按原兼容矩阵的单项证据等级处理。
- 降级：内部接口不可用时隐藏聊天能力，不用公开 Bot/Webhook API 冒充用户会话。

#### 2026-09-09 会话创建编码纠正

2026-09-16 [当前管理员只读复核](../environments/2026-09-16-windows-parity-read-observation.md)
再次确认同一版本组合的三项创建/成员能力声明 JSON。Windows 已开始同步现有创建链编码、
独立成员回读与未知结果保护；元数据证据不代表建群行为通过，设备匿名归属仍待确认。

- [待归属管理员观察](../environments/2026-09-09-admin-chat-observation.md)核实了 `Anonymous` v2、`Named` v1、`Member` v1 的 `requestFormat=JSON`；旧的 FORM-only 判定错误，不能将 JSON 声明当成无权限或接口缺失。仅元数据达到 `read-verified`，未执行真实创建。
- 请求仍为 POST `application/x-www-form-urlencoded`，相对路径采用能力发现的 `entry.cgi`。JSON 声明表示业务字段按 JSON 值编码，再作为表单字段发送，并不是直接发送 JSON HTTP 正文。
- 固定使用 `Anonymous.initiate` v2（`user_ids` 数组、`encrypted=false`、`channel_key_encs=[]`）；群聊使用 `Named.create` v1（`name`、`type=private`），随后 `join(channel_id)`、`invite(channel_id,user_ids,channel_key_encs)`。空密钥数组必须保持数组，不编码成内容为 `[]` 的字符串。
- 创建响应需要候选 `channel_id/id`，但不能单凭候选判断成功；单聊重读会话列表，群聊另外使用 `Member.get` v1 的 `user_ids` 确认所有所选成员。`success=false` 的显式拒绝与传输未知分开处理，沿用现有固定请求 ID、串行创建和待核对结果处理。
- 仍需当前账号有 Chat 使用权限，版本缺失/Member 缺失时不开放对应创建；加密会话不因编码修复而开放。没有手动发送消息、创建群聊或执行权限变更。
- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift`；FORM 和 JSON 的能力、完整创建链、数组编码、回读及去重测试见同包 `Tests/DsmChatRepositoryTests.swift`；JSON 合成请求见 `contracts/request-fixtures/chat/create-private-group/synthetic-json/request.json`。
- 五端影响与剩余工作见[本轮修复和功能真实性审计](../../../development/MACOS_ENTRY_FIXES_AND_FUNCTION_AUDIT_20260909_ZH.md)。本次不替代其他 build/套件版本的兼容复验，不提高既有创建操作的实机验证等级。

### `chat-realtime`

- 稳定记录：[Chat 实时事件通道](chat-realtime.md)。Windows 已接入同源原生 WebSocket、现有证书管线、事件合并与取消隔离；只有本地合成证据。
- 组件：`synology-chat-server`
- 协议：同源 `sc/socket.io`
- Engine.IO 客户端兼容：4 / 3
- 状态：实时事件只触发 API 回读；连接失败时回退 5 秒轮询，连接稳定时每 30 秒校准。
- 未验证：不同 Chat Server 版本、QuickConnect 中继、睡眠唤醒和登录续期的完整矩阵。

### `photos-internal-candidate`

- 组件：`synology-photos`
- 候选命名空间：`SYNO.Foto.*`、`SYNO.FotoTeam.*`
- 候选能力：Album、Folder、Item、Timeline、RecentlyAdded、GeneralTag、Geocoding、Thumbnail、Download。
- 当前证据：仅为静态候选目录；在 Synology Photos `1.8.2-10090` 上没有完成内部 Adapter 契约测试。
- 状态：增强能力保持关闭；基础照片库继续使用官方 File Station 能力。

## 未形成稳定端点的组件

- `storage-analyzer`：当前安装版本 `2.1.0-0620`，但历史报告内部 API 尚未固化，不登记猜测的 API 名称。
- 只有源码候选名称、没有当前环境证据的接口，不得自动提升到本索引的“当前确认”。


### 2026-09-29 Photos 管理增量

- `photos-file-management`：个人空间 Folder.create v1(target_id,name) 与 Folder.get v2 回读已接入目录层级上传；稳定记录见 [照片管理](photos-management.md)。按真实能力和权限开放，静态证据与合成测试不代表 NAS 行为验收。
- `photos-condition-albums`、`photos-people-management`、`photos-request-management`、`photos-preview-regeneration`：稳定候选记录见 [高级照片管理静态发现](photos-advanced-management.md)。兼容登记仅 static，尚未接入原生写流程。该记录亦补充已有分享组的成员/密码/有效期静态证据。
- 上述增量沿用用户明确授权取消人工禁用；不改变其他历史端点的验证等级，也不以本地构建替代真实环境核验。


条件相册增量状态：photos-condition-albums 已接入 macOS 个人空间创建/编辑/建议/数量预览；稳定记录仍见 photos-advanced-management.md，实机等级未提升。其余三组高级候选仍未实现写流程。


### 2026-09-29 Photos 分享现状增量

- `photos-sharing-management`：新增 Album.get v4 只读分享快照、原快照冲突检测、仅受邀者模式和保护元数据回读；公开权限不包含上传，具名成员/密码/有效期编辑仍待接入。状态见 [照片管理](photos-management.md)，加密与日期静态线索见 [高级管理](photos-advanced-management.md)。未做真实分享写验证，无人工验证白名单。

- 2026-09-29 后续：`photos-sharing-management` 接入具名成员候选、添加/移除/角色差量和最终回读；static + 合成验证，真实成员目录和权限写入待验。密码、有效期编辑仍未接入。

- 2026-09-29 后续：`photos-people-management` 已接入个人空间命名/清空名称与合并及照片集合核对；人脸纠正、分离、封面未实现。仍为 static + 合成验证，未执行真实 NAS 写入。分类封面改用分类列表缩略图，不按人物编号查询相册。

### `photos-similar-items`

- 2026-09-30 macOS 分组分类、月份列表、组内预览、推荐设置、移出、拆组和会话内撤销接入；原件清理仍后续。
- [静态参数、权限、失败与五端影响](photos-similar-items.md)；无真实 NAS 验收。


- 2026-09-30 `photos-library-read`：新增整相册Album.download v2、个人/共享目录Download.download v2归档下载；POST口令/数组编码、下载角色、ZIP有限读取校验和macOS原生菜单见[稳定记录](photos-library-read.md)。static及合成测试，不代表真实NAS兼容。

- 2026-09-30 `photos-library-read`：补齐原尺寸JPEG实际设置、支持格式及convert v2→download流程，可能生成派生缓存，索引改为mixed；仅static/合成测试，完整约束见[端点记录](photos-library-read.md)。


2026-09-30增量：[文件夹封面设置](photos-management.md#2026-09-30-文件夹封面)与[封面读取](photos-library-read.md#文件夹封面读取2026-09-30)，静态证据、单选/目录边界/回执与封面组合核对，真实NAS待用户验证。


2026-09-30补充：[文件夹排序保存与读取](photos-management.md#文件夹排序保存与读取2026-09-30)，Folder.set_order v1、目录/用户默认顺序、按序分页与原目录同步；static，真实NAS待用户验收。

2026-09-30：[文件夹重命名与主页面排序](photos-management.md#文件夹重命名与主页面排序2026-09-30)完成原生接入与契约记录；rename v1固定目录/管理权/完整路径自动回读，证据仍static，未代测真实NAS写入。

2026-09-30：[文件夹与照片混合删除](photos-item-deletion.md#2026-09-30-文件夹与照片混合删除)按官方BackgroundTask.File主流程接入；纠正Browse.Folder.delete候选并保留历史线索。静态/合成证据，未新增真实NAS写验证。

2026-09-30增量：[照片与多目录混选归档](photos-library-read.md#2026-09-30-多目录与照片混选归档下载)，官方静态POST数组参数、权限与身份预检及原生整组选项导出；static，真实NAS待用户验收。

2026-09-30增量：[原生文件夹拖放及重复项候选](photos-management.md#2026-09-30-原生文件夹拖放移动与重复项静态线索)：macOS复用现有move，已选组快照、预选确认；默认设置候选仍static且未接入。


### `photos-duplicate-settings`

- 内部 `SYNO.Foto.Setting.User` get/set v1：upload_default_action(ignore/rename)、copy_move_default_action(skip/overwrite)。静态版本表、差异保存与回读已确认；Apple实现严格快照/差异字段/去重/最终核对。
- macOS设置和单次策略开放，上传忽略与新上传区分，移动复制覆盖需确认；真实NAS验证由用户执行，不提升static等级。详见[重复项默认设置与执行](photos-management.md)。

- `photos-concept-visibility`：[主题分类显示隐藏、封面与误分类移除](photos-advanced-management.md)，个人/共享Concept v1/v2，static，实际NAS待用户验证。

- `photos-display-settings`：[照片显示偏好](photos-management.md)，个人设置get/set v1，static，真实NAS待用户验证。

- `photos-recognition-settings`：[个人照片识别设置](photos-management.md)，User get/set及Admin get v1，static，真实NAS待验。

- `photos-automatic-preview`：[自动预览候选与执行协议](photos-advanced-management.md)，ConvertedFile v3候选/上传、Download v2单元读取、本机转换及未知回执媒体核对已实现；设置与后台串行扫描已接通，entry目录可见任务/批次外优先仍进行中，static与合成测试。

- `photos-shared-space-settings`：管理员共享空间启停、识别和顶层公开分享设置，见[高级管理](photos-advanced-management.md)；static，NAS待用户验证。

- `photos-global-settings-cache`：全局识别/分享/格式排除/JPEG及转换缓存，见[高级管理](photos-advanced-management.md)；static，多阶段核对，NAS待用户验证。

- `photos-shared-space-members`：共享成员/自动备份和按成员目录权限，见[高级管理](photos-advanced-management.md)；static，原生成员/目录草稿、最终确认、分阶段保存、自动核对与本人实际权限更新已接入；真实NAS仍待用户验证。

- `photos-library-maintenance`：个人/共享当前空间重新索引、异常预览生成与自动核对，见[高级管理](photos-advanced-management.md)；static；已接入新格式提示已读及管理员全用户/普通用户个人补预览，提交确认不代表后台全部完成。

2026-10-01补充：photos-advanced-management.md记录临时分享与冻结条件相册静态候选；尚未实现，无行为验证，不代表普通相册分享已完整对齐。

2026-10-01接入进度：临时分享的创建、保留副本、已停止临时相册清理已进入Core/Repository，本地测试进行中；macOS组合界面和冻结相册仍未完成，不提升static证据等级。

- [Photos后台任务中心](photos-background-tasks.md)：统一列表、取消、清理与错误详情；2026-10-01仅static，macOS已接入并通过本地合成回归。
