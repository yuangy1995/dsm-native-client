# DSM API 历史来源与内部接口证据

当前开发统一从[按功能 API 参考](README.md)进入；本文件仅保留既有私有兼容索引引用的历史证据，避免重写证据来源。原始整理日期 2026-07-23，第三方静态源码基线为 `apaipai/dsm_helper` dev 提交 `8c104e9a783a1acaf366a250e5fcd1d623f14eb2`（2024-06-25）。这些来源不是当前 macOS 实现或新版本 NAS 已验证的证明。

通用协议、认证、官方文件/下载/VMM 当前调用及跨端规范已归入功能文档；下面保留的编号与证据表属于原记录，当前证据等级统一按[发现规范](discovery/README.md)解释。

## 1. 文档目的与边界

本文将群晖 DSM Web API 分为三类：

| 标记 | 含义 | 维护策略 |
| --- | --- | --- |
| `官方` | 群晖提供正式开发文档，接口名称、方法和参数有公开说明 | 可作为核心功能依赖，但仍需运行时查询版本 |
| `混合` | 同一产品存在官方 API，但项目使用了不同名称、更新版本或额外方法 | 优先调用官方版本，内部变体单独适配 |
| `内部` | DSM 网页或套件自身使用，但没有找到对应的正式 API 规范 | 视为易变实现细节，必须做能力探测和降级 |

本文不是群晖官方文档的替代品。官方接口的完整字段、限制与错误码应以群晖原文为准；内部接口仅记录项目源码中观察到的调用方式，不代表群晖承诺兼容。

### 1.1 资料来源

- [DSM Login Web API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf)
- [File Station Official API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)
- [Download Station Web API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/DownloadStation/All/enu/Synology_Download_Station_Web_API.pdf)
- [Virtual Machine Manager API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/Virtualization/All/enu/Synology_Virtual_Machine_Manager_API_Guide.pdf)
- [DSM Developer Guide 7](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf)
- [Synology QuickConnect White Paper](https://global.download.synology.com/download/Document/Software/WhitePaper/Os/DSM/All/enu/Synology_QuickConnect_White_Paper_enu.pdf)
- [`dsm_helper` 项目源码](https://gitee.com/apaipai/dsm_helper/tree/dev/)
- 项目集中式接口实现：[`lib/utils/api.dart`](https://gitee.com/apaipai/dsm_helper/blob/dev/lib/utils/api.dart)
- 项目模型与分模块接口：[`lib/models/Syno`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno)

### 1.2 动态验证范围

本文已对当前 NAS 设置只读模块执行脱敏的实机响应结构核对，但没有对所有内部接口、权限组合和 DSM 版本逐项执行。正式发布前仍应补充以下验证矩阵：

- DSM 6 与 DSM 7 的具体版本及 build number。
- 安装的 File Station、Download Station、Container Manager、Synology Photos、VMM 版本。
- 管理员与普通用户的权限差异。
- 请求格式、返回字段和错误码的实际差异。

### 1.3 当前实机只读确认

2026-07-23 在一台已登录的测试 NAS 上完成了只读核对。为避免泄漏真实环境，本文只记录版本和能力结论：

- DSM `7.2.1-69057 Update 12`；Virtual Machine Manager `2.6.5-12202`；Container Manager `24.0.2-1535`；Chat Server `2.4.1-22111`。
- 使用无凭据的 `SYNO.API.Info query=all` 确认 API 名称、路径、版本范围与请求格式；通过已登录网页会话只读调用确认了系统利用率、存储、套件、计划任务、账号与群组、系统日志和当前连接的实际响应结构。
- 未导出或保存 Cookie、SID、SynoToken、DID、浏览器存储、真实主机地址、账号、消息、虚拟机名称、容器名称或文件路径；仓库只保留脱敏后的接口契约。
- 未执行删除、断开连接、网络修改、虚拟机电源控制、容器控制、消息发送等写操作。

本文把证据分成四级：`能力可发现`、`官方界面可见`、`官方前端静态契约确认`、`行为验证通过`。前三者都不能替代最后一级。


### 2.1.1 QuickConnect 地址解析 - 内部、可降级

群晖公开资料说明 QuickConnect ID 可以用于群晖移动应用，并会把浏览器入口重定向到可用的直连或中继地址，但没有找到面向第三方客户端的正式地址解析 API 规范：

- [Synology NAS External Access Quick Start Guide](https://kb.synology.com/en-my/DSM/tutorial/Quick_Start_External_Access)
- [Synology QuickConnect White Paper](https://global.download.synology.com/download/Document/Software/WhitePaper/Os/DSM/All/enu/Synology_QuickConnect_White_Paper_enu.pdf)

macOS 参考实现使用 QuickConnect Web Portal 自身的内部解析入口作为可降级适配器：

```text
POST https://global.quickconnect.<region>/Serv.php
command=get_server_info
id=mainapp_https
serverID=<QUICKCONNECT_ID>
```

直连候选均不可用时，参考实现会向解析结果中的控制服务器请求中继：

```text
POST https://<CONTROL_HOST>/Serv.php
command=request_tunnel
version=1
id=mainapp_https
serverID=<QUICKCONNECT_ID>
```

`request_tunnel` 的字段和响应结构来自 QuickConnect 当前客户端实现，属于未公开的内部契约。客户端只接受 `*.relay.*.quickconnect.to` 或 `*.relay.*.quickconnect.cn` 中继主机，并在发送登录信息前请求控制响应给出的 `pingpong_path`；返回的 `ezid` 必须等于 NAS 标识的小写 MD5，否则立即终止连接。中继 HTTPS 必须通过系统证书信任，不能使用自签名证书确认流程绕过异常证书。

安全与兼容边界：

- 该入口标记为 `内部`，不视为群晖承诺兼容的公开 API。
- 请求不携带 DSM 用户名、密码、SID、SynoToken、文件路径或其他会话数据。
- 只接受 `smartdns.lan` 或 `smartdns.host` 中以 `.direct.quickconnect.cn`、`.direct.quickconnect.to` 结尾的地址，并校验端口范围。
- 先验证直连候选；全部失败后才请求中继，并在中继身份核对成功后执行 DSM 能力发现。
- 解析失败时允许用户改为粘贴浏览器最终地址，或输入 NAS 的 IP、`.local`、DDNS 和自定义域名。
- 解析结果只用于当前连接，不替换界面和本地配置中保存的 QuickConnect ID，也不写入日志。


## 8. 项目源码中的内部与混合接口目录

### 8.1 判定方法

本节的“内部”表示：在本文审阅的群晖公开 PDF 中没有找到相同 API 名称和方法，但在 `dsm_helper` 源码、DSM Web UI 或套件前端中可观察到。它不等于恶意接口，也不等于作者凭空创建；多数是作者观察 DSM 自身请求后进行的客户端复现。

风险等级：

| 等级 | 含义 |
| --- | --- |
| 低 | 只读、容易降级，字段变化影响有限 |
| 中 | 会改配置或依赖套件版本，需要强能力探测 |
| 高 | 管理、删除、关机、安装、远程连接等高影响操作 |

### 8.2 File Station 扩展 - 混合

| API | 方法 | 用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.FileStation.VFS.Connection` | `create/set/delete` v1 | macOS 已接入远程连接及云盘授权；真实写待用户验证 | 中 |
| `SYNO.FileStation.Mount` | `mount_remote`, `unmount` | 远程挂载 | 高 |
| `SYNO.FileStation.Property.CompressSize` | `get` | 压缩大小属性 | 低 |
| `SYNO.Entry.Request` | `request`（未验证） | 候选复合批处理；客户端保持关闭 | 中 |

`SYNO.Entry.Request` 的子请求可能分别成功或失败，必须逐项检查结果。不要因为外层 `success=true` 就假定所有修改都完成。

`SYNO.FileStation.VFS.Connection` 属于内部接口。2026-10-02 已根据官方网页完成
[私有契约记录](discovery/endpoints/file-station-vfs-connections.md)，macOS 按实际能力、
会话权限及目标确认开放连接管理、云盘新授权和原账号续授权；写后分别核查连接与
保存配置，未知结果不重放。真实云授权回调及 NAS 写行为仍待用户验证。远程浏览
使用公开 `List.list` 的原始 URI，不使用 `SYNO.Entry.Request`；后者继续关闭。

#### `SYNO.FileStation.Mount` 使用边界

> **内部、实验性契约：** 当前审阅的群晖公开 File Station PDF 未提供 `SYNO.FileStation.Mount` 的稳定参数说明。客户端只在能力发现明确返回 v1 时显示创建、修改和删除远程位置入口，并且仍需在目标 DSM build 上实机验证。

Windows 当前仍关闭远程位置写入：现有 create/update/delete 及其参数与下述契约不
一致，必须独立修复。收藏的专用提交接口已接通，但不代表挂载适配器也已实现。

- 创建使用 `mount_remote`，支持 SMB/CIFS 与 NFS；远程地址、目标目录和只读选项随请求提交。
- 修改不是假定存在稳定的 `edit` 方法：目标目录变化时先连接并确认新位置，再断开并确认旧位置；目标不变时明确提示会短暂断开后重连。
- 删除使用 `unmount`，语义仅为断开远程位置，不删除远端文件；提交前必须二次确认。
- SMB 密码只保留在当前表单内存和 HTTPS 请求正文中，不写入配置、日志、URL 或文档。修改连接时需要重新输入。
- 所有写操作必须防止重复提交，并通过公开的 `SYNO.FileStation.List.getinfo` 复查 `mount_point_type`；仅收到内部接口的 `success=true` 不算完成。
- API 未发现、权限不足或结果无法复查时必须关闭入口或给出可恢复提示，不能自动尝试更高权限账号。

### 8.3 系统状态、连接与日志 - 内部

| API | 方法 | 主要参数/用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.Core.System` | `info` | 系统与网络信息；源码出现 v1/v3 | 低 |
| `SYNO.Core.System` | `shutdown`, `reboot` | 无业务参数；正常关机与重启 | 关键 |
| `SYNO.Core.System.Utilization` | `get` | `resource`, `type`；CPU、内存、网络等 | 低 |
| `SYNO.Core.System.Process` | `list` | 进程列表；客户端仅接受运行时发现的 v1，并只保留编号、名称、状态和服务组标识 | 中 |
| `SYNO.Core.System.ProcessGroup` | `list`, `service_info` | `list` 作为可失败降级的服务组摘要；`service_info` 参数与隐私边界未验证，保持关闭 | 中 |
| `SYNO.Core.CurrentConnection` | `list`, `download`, `kick_connection` | `list` 使用 `start`、`limit`、`sort_by` 和 `sort_direction` 读取当前连接；`kick_connection` 按网页会话和服务会话分别提交目标；导出未接入 | 高 |
| `SYNO.Core.FileHandle` | `kickable_list`, `export`, `delete_db` | 打开的文件、导出与强制断开 | 高 |
| `SYNO.Core.Service` | `get` | 服务状态 | 低 |
| `SYNO.Core.Service.PortInfo` | `load` | 服务端口 | 低 |
| `SYNO.Core.Desktop.Initdata` | `get` | DSM 桌面初始化数据 | 中 |
| `SYNO.Core.Desktop.SessionData` | `getjs` | 登录阶段的桌面会话数据 | 高 |
| `SYNO.Core.UserSettings` | `apply` | DSM 用户设置 | 中 |
| `SYNO.Core.DSMNotify` | `notify` | DSM 通知 | 中 |
| `SYNO.Core.DSMNotify.Strings` | `get` | 通知文本资源 | 低 |
| `SYNO.Core.SyslogClient.Status` | `latestlog_get` | 最新日志 | 中 |
| `SYNO.Core.SyslogClient.Log` | `list` | 系统日志 | 中 |
| `SYNO.Core.SyslogClient.FileTransfer` | `get`, `get_level`, `set_level` | 文件传输日志开关与级别 | 中 |
| `SYNO.LogCenter.History` | `list` | Log Center 历史 | 中 |
| `SYNO.Core.SecurityScan.Status` | `rule_get`, `system_get` | 仅静态确认名称与方法；组件归属、版本、参数和响应未知，客户端保持关闭 | 中 |

连接、进程、文件句柄和日志可能泄漏用户名、IP、共享路径、文件名与服务信息。客户端只应按需展示，默认禁止遥测上报。

`SYNO.Core.SecurityScan.Status` 当前只完成静态审计。`SYNO.Core.*` 命名不能证明它由 DSM 核心直接提供，也不能排除对“安全顾问”套件的依赖；仓库没有该套件版本、运行时路径、参数或响应证据。`rule_get` 可能包含规则正文或发现详情，`system_get` 也可能包含系统配置、账号、主机、网络、路径或套件信息，因此客户端不注册能力、不调用两个方法，也不把它并入现有自动封锁、DoS 和防火墙设置。

当前 macOS 的“NAS 设置”统一接入以下已核对的只读路径；原“服务与监控”入口已经合并，不再单独运行第二套性能采样：

- `System.info` v3：型号、DSM 版本、运行时间、处理器、内存容量和系统温度。
- `System.Utilization.get` v1：固定发送 `resource=all`、`type=current`；CPU 使用率来自 `user_load + system_load + other_load`，内存来自 `real_usage`，网络使用 `network` 数组中 `device=total` 的 `rx/tx`，磁盘与存储空间速率读取 `disk.total` 和 `space.total`。
- `CurrentConnection.list` v1：分页读取连接账号、来源、位置、协议、时间、设备/进程标识和可断开标记；断开操作使用 `kick_connection` v1，网页会话提交 `http_conn`，其他服务提交 `service_conn`。当前登录账号的连接会显示更强警告，所有断开操作都具备确认、防重复和结果复查。
- `SyslogClient.Log.list` v1：分页读取系统日志及信息、警告、错误计数；Log Center 没有记录时不把空结果误判为加载失败。
- `Upgrade.Server.check` v3：固定发送 `user_reading=true`、`need_auto_smallupdate=true`、`need_promotion=false`，只读取 `update.version` 和可选更新说明。没有 `update` 时才显示“没有发现更新”，不得用 `System.info` 的当前版本伪造检查结果；客户端不下载或安装 DSM 更新。

性能页每 2 秒读取一次当前采样，只在内存中保存最近 120 个点并绘制处理器、内存、网络与存储趋势。用户可暂停更新；离开页面、关闭模块或断开 NAS 后停止读取。刷新期间保留上一次成功结果，不提前显示空状态。原始响应、连接地址和日志正文不写入本地持久化存储。

关机与重启先调用 `System.info` 检查当前会话、权限和 API 可达性，再只发送一次
`shutdown` 或 `reboot`。明确成功只表示 DSM 已接受请求；关机不能据此宣称设备已经
完全断电，重启不能据此宣称设备已经重新上线。提交阶段断线、超时或取消均按结果未知
处理，提示用户检查设备或等待重新连接，禁止自动重放。完整稳定记录见
[`dsm-system-power-actions.md`](discovery/endpoints/dsm-system-power-actions.md)。

### 8.4 存储、硬盘与硬件控制 - 内部

| API | 方法 | 用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.Storage.CGI.Storage` | `load_info` | 存储总览 | 低 |
| `SYNO.Storage.CGI.Smart` | `get_health_info` | SMART 健康摘要 | 低 |
| `SYNO.Core.Storage.Volume` | `list` | 存储空间列表 | 低 |
| `SYNO.Core.Storage.Disk` | `disk_test_log_get`, `get_smart_test_log`, `do_smart_test` | SMART 测试与日志 | 中 |
| `SYNO.Core.Hardware.ZRAM` | `get`, `set` | macOS 读取 enable_zram 并按用户授权实现 set，与 NeedReboot 标记共同回读，不自动重启 | 高 |
| `SYNO.Core.Hardware.PowerRecovery` | `get`, `set` | 来电自启 | 高 |
| `SYNO.Core.Hardware.BeepControl` | `get`, `set` | 蜂鸣器 | 中 |
| `SYNO.Core.Hardware.FanSpeed` | `get`, `set` | 风扇模式 | 高 |
| `SYNO.Core.Hardware.Led.Brightness` | `get`, `set` | LED 亮度 | 中 |
| `SYNO.Core.Hardware.Hibernation` | `get`, `set` | 休眠设置 | 中 |
| `SYNO.Core.Hardware.PowerSchedule` | `load`, `save` | 客户端仅候选接入运行时发现的 v1 `load`，最多读取 128 条白名单摘要；`save` 保持关闭 | 高 |
| `SYNO.Core.ExternalDevice.UPS` | `get`, `set` | UPS 设置 | 高 |
| `SYNO.Core.ExternalDevice.Storage.USB` | `list`, `eject` | 客户端仅候选接入运行时发现的 v1 `list`，每类最多读取 64 项白名单摘要；`eject` 保持关闭 | 高 |
| `SYNO.Core.ExternalDevice.Storage.eSATA` | `list` | 客户端仅候选接入运行时发现的 v1 `list`，与 USB 独立降级 | 低 |
| `SYNO.Core.ExternalDevice.Printer.BonjourSharing` | `get` | 仅静态确认名称与方法；版本、参数和响应未知，客户端保持关闭 | 中 |

硬件操作必须使用精确的设备标识并在提交前显示摘要。不要根据数组索引选择硬盘或外接设备。

当前 macOS 已按设备能力接入断电恢复、LED 亮度、风扇模式、设备提示音、外接存储深度休眠、唤醒日志、SATA 深度休眠、休眠时忽略发现流量、闲置自动关机和 UPS 基础安全关机设置。UPS 支持 DSM 返回的 USB、网络从属与 SNMP 三种模式，以及等待时间、低电量策略和关机联动；不猜测未返回的 SNMP v3 密钥或 ACL 字段。只显示 DSM 实际返回的字段，保存后重新读取所有已修改字段。

内存压缩在 2026-10-02/03 官方成功响应中确认 `enable_zram:Boolean`；macOS 已按用户授权接入 v1 `set` 及 `NeedReboot.set/get`，保留基线比较、明确确认、防重复和两项结果核对，不自动重启。容量与算法只在服务端提供可信字段时显示。写参数来自官方前端 static 证据，真实保存及重启后状态仍待用户验证。见 [`dsm-zram.md`](discovery/endpoints/dsm-zram.md)。

打印机 Bonjour 共享目前只完成静态审计。既有目录仅列出 `SYNO.Core.ExternalDevice.Printer.BonjourSharing.get`，没有版本、路径、参数或响应证据；它不能与文件服务的通用 Bonjour/Avahi 设置混用。客户端不注册该能力、不发送请求，也不推断打印机清单、共享状态或设备字段。稳定记录见 [`dsm-printer-bonjour-sharing.md`](discovery/endpoints/dsm-printer-bonjour-sharing.md)。

当前 macOS 直接从 `Storage.load_info` v1 的 `disks`、`storagePools` 和 `volumes` 读取硬盘、S.M.A.R.T. 摘要、温度、型号、序列号、固件、位置、4Kn、寿命/坏扇区摘要、存储池成员、RAID、文件系统与容量，并在原生详情页按空间、存储池和硬盘分别展示。`Smart.get_health_info` 必须携带精确的 `device`，缺少硬盘参数时返回 `114`；`Storage.Volume.list` 在当前目标返回 `101`，因此客户端不会用失败接口覆盖 `load_info` 已返回的数据。

S.M.A.R.T. 检测使用能力发现返回的 `SYNO.Core.Storage.Disk` v1。`Storage.load_info` 返回的列表稳定标识 `id` 只用于界面选择，所有检测请求必须使用同一硬盘的 `device`，不得把两者混用。当前状态调用 `get_smart_test_log(device)` 并读取 `testInfo[0]` 的 `testing`、`remain`、`ihm_testing`、`perf_testing` 和 `latest_test_result`；历史记录另行调用 `disk_test_log_get(device,type=smart,sort_by=time,sort_direction=DESC)`，从 `testLog` 的 `test_type=quick/extend` 分别选择最近记录。历史读取失败必须显示可重试错误，不能伪装成“暂无记录”。

启动调用 `do_smart_test(device,type)`，快速检测的 `type=quick`，完整检测的 `type=extend`；停止正在运行的检测使用同一方法且 `type=stop`。开始和停止前都读取当前状态；`ihm_testing` 或 `perf_testing` 表示其他检测正在占用硬盘，此时不得提交 S.M.A.R.T. 写请求。界面再次确认影响，同一硬盘防重复提交，提交后最多等待 5 秒并重复读取状态，分别确认 `testing=true/false`，运行期间每 4 秒刷新状态和历史。当前不会为验证而在真实硬盘上自动启动或停止测试；修复、擦除和存储配置修改仍未接入。

### 8.5 终端、套件与计划任务 - 内部

| API | 方法 | 主要参数/用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.Core.Terminal` | `get`, `set` | `enable_ssh`, `enable_telnet`, `ssh_port` | 高 |
| `SYNO.Core.TrustDevice` | `delete`, `logout` | 删除可信设备或退出会话 | 高 |
| `SYNO.Core.Package` | `list`, `get`, `feasibility_check` | 套件与可行性检查 | 中 |
| `SYNO.Core.Package.Info` | `get` | 套件详情 | 低 |
| `SYNO.Core.Package.Server` | `list` | 套件源 | 中 |
| `SYNO.Core.Package.Thumb` | `get` | 已安装套件图标；`name`、`ver`、`size` | 中 |
| `SYNO.Core.Package.Control` | `start`, `stop` | 启停套件 | 高 |
| `SYNO.Core.Package.Installation` | `install`, `status`, `get_queue`, `cancel` | 安装队列 | 高 |
| `SYNO.Core.Package.Uninstallation` | `uninstall` | 卸载套件 | 高 |
| `SYNO.Core.TaskScheduler` | `list`, `run`, `delete`, `set_enable`, `view`, `result_list`, `result_get_file` | 计划任务及结果 | 高 |
| `SYNO.Core.EventScheduler` | `run`, `delete`, `set_enable`, `result_list`, `result_get_file` | 事件计划任务 | 高 |
| `SYNO.Core.Upgrade.Server` | `check` | DSM 更新检查；客户端使用 v3，只读参数为 `user_reading=true`、`need_auto_smallupdate=true`、`need_promotion=false` | 中 |

套件安装 URL、计划任务脚本和任务结果都可能包含秘密。源码中存在直接安装/执行能力，不应在普通功能页静默触发。系统更新当前只读取 `System.info` 与 `Upgrade.Server.check`；候选版本为空或与当前版本相同时不宣告更新，下载、安装、取消和重启任务没有稳定契约，保持关闭。

当前 macOS 与 Android 使用 `Package.list` v2，并请求 `status`、`description`、`install_type`、`startable`、`dsm_apps`、`available_operation` 和 `ctl_uninstall` 附加字段，展示真实套件名称、版本、状态与说明。两端套件图标使用 `Package.Thumb.get` v1 读取，认证信息只放在 Cookie 与请求头，不写入图片 URL；Android 另以 2 MiB 流式上限、PNG/JPEG/GIF/WebP 签名和 Bitmap 解码约束响应，只在内存保留 4 MiB LRU，失败时使用本地通用图标。

2026-10-03 已确认 `available_operation` 是可携带 `upgrade` 候选对象的对象，不是启停许可数组。macOS 已接 `Package.Server.list` v2 目录、安装依赖计划、安装/更新/上传、进度和取消下载、自动更新设置与来源管理；直接 `.upgrade` 控制继续拒绝，统一走有确认的安装计划。目录和设置 get 为只读证据；同日按授权通过官方网页完成单个 MediaServer 更新。已确认预检成功可没有 data，Setting.get.update_channel 为 Boolean、set 仍为 stable/beta。客户端真实提交及其他写操作仍待用户验证。Android/Windows 仍保留旧更新提示，iPhone/iPad 未迁移。详见 [`dsm-package-installation.md`](discovery/endpoints/dsm-package-installation.md)。

启动与暂停每次都先重新调用 `Package.list` v2，按稳定套件 ID 核对目标仍存在且
`canStart/canStop` 与当前状态一致，再调用 `Package.feasibility_check` v1 和
`Package.Control.start/stop` v1。同一套件 ID 的启动、停止与卸载在 Repository 和
macOS 模型两层防重复；界面提交前说明影响并确认，执行中显示进度且禁用重复操作。
写请求明确成功后最多轮询列表十次；提交超时、断线或响应无效时只读取列表核对，不重放
原写请求。只有列表确认目标达到运行或停止状态才显示完成，无法确认时要求先刷新，确认
前不得再次执行同一动作。卸载继续使用独立的破坏性结果链路，先检查可行性和系统套件
限制，再调用 `Package.Uninstallation.uninstall` v1。当前 DSM 7.2.1-69057 Update 12
的能力发现与官方网页前端静态请求已核对，但本轮没有为验证而启动、停止或卸载真实套件；
发布兼容结论仍需使用专用测试套件完成管理员、普通账号、依赖阻止、超时和 QuickConnect
场景的行为验收。安装和升级需要来源、空间、依赖与安装队列流程，当前保持关闭。

计划任务列表继续使用 `TaskScheduler.list` v3 的 `start/limit` 分页字段；详情、新建和修改按 DSM 前端契约使用 `get/create/set` v4，运行、启停和删除使用 v3。运行记录使用 `EventScheduler.result_list(task_name)` v1，选择记录后再调用 `result_get_file(task_name,result_id)` v1 读取执行内容和输出；结果只保留在当前窗口内，不写入磁盘或日志。客户端必须按方法选择版本，不能把整个 API 一律升级到 v4。脚本任务界面具备详情、创建、修改、启停、立即运行、删除和运行记录入口，危险动作均要求确认并防止重复提交；脚本内容和通知地址只在当前请求中使用，不写入日志。

### 8.6 用户、群组、共享与配额 - 内部

| API | 观察到的方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.Core.User` | `list`, `get`, `create`, `set`, `delete` | 高 |
| `SYNO.Core.Group` | `list`, `create`, `set`, `delete` | 高 |
| `SYNO.Core.Group.Member` | `add`, `remove` | 高 |
| `SYNO.Core.NormalUser` | `get`, `set` | 高 |
| `SYNO.Core.User.PasswordExpiry` | `get` | 中 |
| `SYNO.Core.Share.Permission` | `list_by_user` | 中 |
| `SYNO.Core.Quota` | `get` | 中 |
| `SYNO.Core.PersonalSettings` | 配额相关调用 | 中 |
| `SYNO.Core.OTP`, `SYNO.Core.OTP.Admin` | OTP 与管理员设置 | 高 |
| `SYNO.Core.Share` | `list`, `get`, `add`, `set`, `delete`, `get_all_move_task`, `move_status` | 高 |
| `SYNO.Core.RecycleBin` | `start`（清理回收站） | 高 |

当前 macOS 使用 `User.list` 与 `Group.list` 展示当前账号有权查看的账号、群组、说明、邮件地址、停用状态和数字标识，并分别保留账号与群组结果。账号与群组的新建、修改和删除已接入专用接口，密码只用于当次请求，所有删除均确认、防重复并回读。共享访问页面只使用公开 `SYNO.FileStation.List.list_share` 展示登录账号可见共享文件夹的有效读写权限；不可见条目不推断为拒绝访问，内部 `Share.Permission.list_by_user` 因缺少版本化参数与响应证据保持关闭。共享文件夹的加密、权限、WORM、配额、移动和删除存在相互依赖；在完成 `validate_set`、权限复合提交与移动任务轮询前不提供不完整写入口。

这些接口涉及账号、权限与数据删除。原生客户端应要求重新确认，并只发送用户改变的字段，避免把完整对象回写导致覆盖新设置。

### 8.7 网络、文件服务与 DDNS - 内部

| API 组 | 观察到的方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.Core.Network` | `get`；网络总览 | 中 |
| `SYNO.Core.Network.Ethernet` | `list`, `get`, `set`；网卡 | 高 |
| `SYNO.Core.Network.PPPoE` | `list`；PPPoE | 高 |
| `SYNO.Core.Network.Proxy` | `get`, `set`；`enable`, `http_host`, `http_port` | 中 |
| `SYNO.Core.BandwidthControl` | `get`；账号带宽规则 | 中 |
| `SYNO.Core.Web.DSM` | `get`, `set`；DSM HTTP/HTTPS、门户与局域网发现设置 | 中 |
| `SYNO.Core.FileServ.SMB` | `get`, `set`；`enable_samba` | 中 |
| `SYNO.Core.FileServ.FTP` | `get`, `set`；`enable_ftp`, `enable_ftps`, `portnum` | 中 |
| `SYNO.Core.FileServ.FTP.SFTP` | `get`, `set`；`enable`, `portnum` | 中 |
| `SYNO.Core.FileServ.NFS` | `get`, `set`；`enable_nfs` | 中 |
| `SYNO.Core.FileServ.AFP` | `get`；AFP 设置 | 中 |
| `SYNO.Core.FileServ.ReflinkCopy` | `get`；写时复制能力 | 低 |
| `SYNO.Core.FileServ.ServiceDiscovery` | `get`, `set`；服务发现与 SMB Time Machine | 中 |
| `SYNO.Core.ACL` | `get_bypass_traverse` | 中 |
| `SYNO.Core.Security.Firewall` | `get`, `set`；防火墙状态 | 高 |
| `SYNO.Core.Security.Firewall.Conf` | `get`, `set`；防火墙通知 | 高 |
| `SYNO.Core.Security.Firewall.Profile.Apply` | `start`, `status`, `stop`；应用当前配置 | 高 |
| `SYNO.Core.Security.Firewall.Rules.Serv` | `policy_check` | 中 |
| `SYNO.Backup.Service.NetworkBackup` | `get` | 中 |
| `SYNO.Core.DDNS.Provider` | `list` | 低 |
| `SYNO.Core.DDNS.Record` | `list`, `test`, `create`, `set`, `update_ip_address`, `delete` | 高 |
| `SYNO.Core.DDNS.ExtIP` | `list` | 中 |
| `SYNO.Core.DDNS.Synology` | `get_myds_account` | 高 |
| `SYNO.Core.QuickConnect` | `get` v2、`set` v2、`check_availability` v3、`get_misc_config` v3、`set_server_alias` v2、`status` v1 | 高 |
| `SYNO.Core.QuickConnect.Permission` | `get` v1 | 中 |
| `SYNO.Core.QuickConnect.Hostname` | `get_ip` v1 | 中 |

网络与 DDNS 响应可能包含公网 IP、域名、账号和代理配置。抓包样本必须删除这些字段后才能共享。

当前 macOS 已将 SMB、NFS、FTP/FTPS、SFTP、互联网代理、物理网卡、DDNS 和防火墙基础控制加入运行时能力发现。物理网卡编辑支持 DHCP/静态 IPv4、网关、DNS、默认网关、MTU 与 VLAN；提交前明确提示可能断开当前连接，提交时只发送目标网卡 `configs`，随后按 `ifname` 回读。DDNS 将服务商连接测试、记录新建/编辑、立即更新和删除拆为四个独立操作；密码/密钥仅用于当次测试或保存请求，保存和删除后重新列出记录核对，测试成功不代表已经保存，立即更新被接受也不代表公网 DNS 已完成传播。防火墙支持启停当前配置和防火墙通知（enable_port_check）；启用通过 `Profile.Apply` 任务轮询，失败或超时不报告成功。完整防火墙规则编辑仍需服务端口、网卡策略、配置保存和应用任务组成原子流程，当前不提供半成品入口。

局域网服务发现同时接入 `SYNO.Core.Web.DSM` v2 的 `enable_ssdp`、`enable_avahi` 与 `SYNO.Core.FileServ.ServiceDiscovery` v1 的 `enable_smb_time_machine`，按实际变化分别提交并回读。

### 8.7.1 区域与时间 - 内部

`SYNO.Core.Region.NTP` 使用 v3 `get/set` 读取和保存日期格式、时间格式、时区、手动时间或网络校时方式；时区选项使用 v1 `listzone` 的真实 `zonedata`。客户端先保存并逐字段回读配置，只有网络校时模式或最多三个服务器发生变化且配置完整确认后，才调用 v2 `sync(servers)` 立即校时并再次回读配置。`sync` 成功只证明 DSM 接受请求且设置仍被保留，不证明 NAS 时钟已经达到权威时间精度。手动改时要求高风险确认；用户没有编辑时间时使用本次预检刚从 NAS 读取的值，不使用 Mac 当前时间或页面打开时的旧值。提交超时、断线或取消均不得自动重放。

### 8.7.2 DDNS - 内部

`SYNO.Core.DDNS.Provider` 与 `SYNO.Core.DDNS.Record` 使用 v1。连接测试只调用 `test`；
保存只调用 `create` 或 `set` 并按服务商、主机名、账号、启用状态和心跳设置回读；
立即更新调用 `update_ip_address` 后只确认 DSM 接受请求且记录列表可重新载入；删除调用
`delete` 后确认目标记录消失。保存或删除超时后仅允许一次列表回读，能够确认目标状态
时不重放请求，无法确认时提示用户重新读取。完整稳定记录见
[`dsm-ddns-settings.md`](discovery/endpoints/dsm-ddns-settings.md)。

### 8.8 Container Manager/Docker - 内部

| API | 观察到的方法 | 风险 |
| --- | --- | --- |
| `SYNO.Docker.Container` | `list`, `get`, `create`, `set`, `start`, `restart`, `stop`, `signal`, `delete`, `stats`, `get_process` | 高 |
| `SYNO.Docker.Container.Resource` | `get` | 低 |
| `SYNO.Docker.Container.Log` | `get`, `export` | 高 |
| `SYNO.Docker.Image` | `list`, `get`, `import`, `upload`, `export`, `delete`, `prune`, `pull`, `upgrade` | 高 |
| `SYNO.Docker.Registry` | `search`, `tags`, `get`, `create`, `set`, `delete`, `using` | 中 |
| `SYNO.Docker.Network` | `list`, `list_container`, `create`, `set`, `remove` | 高 |
| `SYNO.Docker.Project` | `list`, `get`, `create`, `update`, `delete`, `log`, `get_share_info` | 高 |
| `SYNO.Docker.Log` | `list` | 高 |

这些名称由当前 Container Manager 官方网页前端和能力清单确认；本轮只查看概览与列表，没有控制容器或读取环境变量、挂载路径和日志。套件升级时名称、字段和流式日志方式很容易改变。容器环境变量、挂载路径、Registry 凭据和日志应视为秘密。

### 8.9 Synology Photos - 内部

| API 组 | 观察到的方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.Foto.Browse.Album` / `SYNO.FotoTeam.Browse.Album` | 相册列表与详情 | 中 |
| `SYNO.Foto.Browse.Folder` / Team 变体 | 文件夹浏览 | 中 |
| `SYNO.Foto.Browse.Item` / Team 变体 | 照片项目列表 | 中 |
| `SYNO.Foto.Browse.Timeline` / Team 变体 | 时间线 | 中 |
| `SYNO.Foto.Browse.RecentlyAdded` / Team 变体 | 最近添加 | 中 |
| `SYNO.Foto.Browse.GeneralTag` / Team 变体 | 标签 | 高 |
| `SYNO.Foto.Browse.Geocoding` / Team 变体 | 地理位置聚合 | 高 |
| `SYNO.Foto.Thumbnail` / Team 变体 | 缩略图二进制 | 中 |
| `SYNO.Foto.Download` / Team 变体 | 原图下载 | 高 |

源码还包含 DSM 6 时代 Moments/Photo 相关变体，应按产品版本拆分适配。特别注意：项目中部分缩略图和下载 URL 把 `_sid` 拼在查询串中；新应用不要照搬，应使用带认证的请求数据源，避免 SID 出现在日志、历史或第三方播放器中。

### 8.10 Synology Chat - 内部

当前 Chat Server 官方网页客户端与 `SYNO.API.Info` 交叉确认以下契约。它们都不是公开的第三方普通用户聊天 API；公开的 `SYNO.Chat.External` 不能替代这些用户会话接口。

| API | 版本/方法 | 已确认参数或用途 |
| --- | --- | --- |
| `SYNO.Chat.Channel.Anonymous` | v2 `initiate` | `user_ids`, `encrypted`, `channel_key_encs`；首次一对一会话 |
| `SYNO.Chat.Channel.Named` | v1 `create`, `join`, `invite` | 私人群聊 |
| `SYNO.Chat.Post` | v5 `create` | 文字或 multipart `file` 附件 |
| `SYNO.Chat.Post.File` | v2 `get`, `thumbnail` | `get(post_id)`；`thumbnail(post_id,type)` |
| `SYNO.Chat.Post.Reminder` | v1 `set`, `list`, `delete`, `get` | `set(post_id,remind_at)`；`list(channel_id)`；`delete(post_id)` |
| `SYNO.Chat.Post.Schedule` | v1 `create`, `set`, `list`, `delete` | `list(channel_id)`；创建使用 `channel_id`, `message`, `send_at`；修改/删除使用 `cronjob_id` |
| `SYNO.Chat.Channel.Member` | v1 `get` | `channel_id`；返回 `user_ids` 与 `broken_user_ids` |
| `SYNO.Chat.Channel` 关闭会话 | Windows 固定 v5 `close` | `channel_id` 字符串；macOS 源码/已记录版本范围证据，Windows 写行为待验证 |
| `SYNO.Chat.Post` 消息转发 | v5 `forward` | `post_id` 字符串、`channel_ids` 数字数组；由 NAS 直接转发原消息及附件 |
| `SYNO.Chat.Post` 群公告 | v5 `pin`, `unpin`, `search` | 写入使用 `post_id`；公告列表使用 `channel_id`, `has=["pin"]`, `sort_by=last_pin_at` |
| `SYNO.Chat.Post.Vote` | v1 `create`, `close`, `delete`, `set`, `get_choices`, `vote`, `create_option` | 创建时使用 `channel_id`, `message`, `choices`, `options`；`options` 含 `multiple`, `anonymous`, `add_option` 和可选 `expire_at` |

官方网页客户端的实时同步使用当前源站下的 Socket.IO 路径 `sc/socket.io`，初始化后取得连接标识，处理消息创建/更新/删除、频道加入/关闭、输入状态和用户更新等事件。认证字段属于秘密，不得写入本文、日志或 URL 遥测。岚仓 macOS 端已接入同源 WebSocket、Engine.IO 4/3 协商、心跳响应和指数退避重连；内部事件只触发会话与消息 API 回读，不解析或记录事件正文。连接未建立时每 5 秒同步，连接建立后每 30 秒校准一次，真实 DSM 与 Chat Server 版本兼容性仍需实机验证。

群晖官方帮助确认频道和会话支持 Star，并会显示在官方客户端的 Starred 区域，但当前公开 WebAPI 文档没有提供对应写入契约。岚仓目前只做按 NAS 配置隔离的本地会话置顶；取得脱敏请求、能力名称、版本、参数和结果复查方式前，不猜测调用内部写接口。

直接会话还存在 `encrypted` 与 `channel_key_encs`，官方前端包含密钥处理代码；这只证明加密能力存在，不足以安全复现密钥生成、恢复、轮换和设备撤销，因此保持关闭。网页端可播放音频附件，但没有确认独立的录音消息创建契约。

### 8.11 其他内部接口

| API | 方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.SynologyDrive.Index` | `get_native_client_status` | 低 |
| `SYNO.Core.MediaIndexing` | `reindex`, `status` | 中 |
| `SYNO.Core.MediaIndexing.ThumbnailQuality` | `get`, `set` | 中 |
| `SYNO.Core.MediaIndexing.MobileEnabled` | `get`, `set` | 中 |
| `SYNO.Core.MediaIndexing.MediaConverter` | `status` 及动态转换动作 | 中 |

### 8.12 内部接口的调用规则

每个内部 API 必须满足以下条件才能启用：

1. `SYNO.API.Info` 能查询到该 API。
2. 客户端选择 `maxVersion` 与已验证上限的较小值，不能盲目固定源码中的版本。
3. 套件已安装且运行，当前账号权限足够。
4. 对当前 DSM build/套件版本存在已通过的契约测试样本。
5. 接口失败时有明确降级，不自动切换成管理员账号。
6. 写操作有用户确认、幂等保护和审计摘要。

建议为内部适配器使用 feature flag，例如：

```json
{
  "feature": "container.list",
  "api": "SYNO.Docker.Container",
  "verifiedBuilds": ["DSM-7.2.2-72806"],
  "packageRange": "ContainerManager 24.x",
  "enabled": false
}
```

默认值应为关闭，动态探测和本地验证成功后才开启。


## 14. 源码证据索引

本节便于后续追踪项目实现；行号可能随分支变化，链接固定到 `dev` 分支目录：

| 功能 | 项目位置 |
| --- | --- |
| 集中式 API 与旧实现 | [`lib/utils/api.dart`](https://gitee.com/apaipai/dsm_helper/blob/dev/lib/utils/api.dart) |
| DSM 模型化接口 | [`lib/models/Syno`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno) |
| Docker/Container | [`lib/models/Syno/Docker`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno/Docker) |
| 系统控制 | [`lib/models/Syno/Core`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno/Core) |
| VMM | [`lib/models/Syno/Virtualization`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno/Virtualization) |
| Photos | [`lib/models/photos`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/photos) |

## 2026-10-03 NAS 设置全项核对

本轮检查 21 个官方对应页面，修正性能图 CPU/内存叠加、提示音支持位、风扇档位、
日期/时间格式选择、ZRAM 字段及防火墙通知含义。电源计划已按官方前端完整双数组
`load/save` v1 和 200 条上限实现本地草稿与整表确认；详见
[电源计划记录](discovery/endpoints/dsm-power-schedule.md)和
[实施/验证账本](../development/NAS_SETTINGS_WEB_AUDIT_20261002_ZH.md)。
新写入口遵循用户本轮授权，未执行真实 NAS 写入；静态/合成结论不提升历史环境等级。
