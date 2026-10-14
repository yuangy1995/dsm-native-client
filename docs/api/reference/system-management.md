# NAS 系统管理

分类：本页为 DSM 内部接口。主实现：[DsmNasAdministrationRepository](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository.swift) 及同目录功能扩展；领域输入/输出：[NasAdministration](../../../apple/Packages/DsmCore/Sources/NasAdministration.swift)。公开文件协议与 NAS 设置不能混成一个权限层。

## 功能分类

| 用户结果 / 领域入口 | API 与版本规则 | 参数、响应和风险的规范位置 |
| --- | --- | --- |
| 概览 `loadSystemOverview` | `SYNO.Core.System.info`，当前支持区间 1…3 | 系统版本、运行状态等 → `NasSystemOverview`；字段未知保留未知 |
| 资源监控 `loadPerformanceSnapshot` | `Core.System.Utilization.get` v1 | 专用性能快照；采样/图表历史属于客户端，不把内存采样写成 NAS 历史记录；[样例](requests.md#system-performance) |
| 进程 `loadSystemProcesses` | `Core.System.Process/ProcessGroup` v1 的已接读取 | [进程记录](../discovery/endpoints/dsm-system-processes.md)，仅最小白名单信息，无终止进程接口 |
| 套件 `loadPackages/controlPackageResult/uninstallPackageResult` | Package 列表 v2，可行性、Control 和 Uninstallation v1 | [套件控制](../discovery/endpoints/dsm-package-control.md)；启动、停止、卸载分别判断，列表可见不代表允许操作 |
| 套件目录、安装、更新和 SPK 上传 | Package 目录、准备、安装与进度的分阶段契约 | 已有[安装实现](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageInstallation.swift)和 macOS 原生入口；Android A7已接新主流程与摘要恢复，72项聚焦JVM通过，整波次和手机/平板验收仍在进行；[安装记录](../discovery/endpoints/dsm-package-installation.md)维护预检、卷、许可、提交、取消及回读；共享实现不等于移动入口或真实安装已经验证 |
| 账号、群组 | `Core.User/Group` v1 | [账号目录](../discovery/endpoints/dsm-account-directory.md)；`NasAccountDraft/NasGroupDraft`，密码意图、成员增删及当前账号保护分别处理；Android A7已接v1完整管理与加密摘要恢复，32项聚焦测试通过，真实账号写与整模块UI未验收 |
| 当前连接 | `Core.CurrentConnection.list/kick_connection` | [连接记录](../discovery/endpoints/dsm-current-connection.md)；按完整连接身份断开，当前或不能判断是否当前连接时保留额外风险说明；Android 已接原目标预检、单次提交与跨重启加密摘要恢复，完整目录及当前权限才能认领消失 |
| 日志 | `Core.SyslogClient.Log`、`LogCenter.History` 已接列表 | `NasLogPage`；Android A7使用系统日志v1，已接分页/本页筛选/全文详情；日志正文不得进入调试导出或本契约材料 |
| 计划任务 | `Core.TaskScheduler` 列表 v3、详情/保存等固定契约；`Core.EventScheduler` 结果读取 | [任务记录](../discovery/endpoints/dsm-task-scheduler.md)；`NasScheduledTaskDraft`，任务 ID 与 real_owner/原快照绑定；运行接受不等于脚本成功；Android A7已接管理与恢复，25项聚焦JVM通过 |
| 系统更新检查 | `Core.Upgrade.Server.check` v3 | `user_reading=true,need_auto_smallupdate=true,need_promotion=false`；`update` → `NasSystemUpdateInfo`，不下载或安装系统更新；[记录](../discovery/endpoints/dsm-system-update-check.md) |
| 关机 / 重启 | `Core.System.shutdown/reboot`，样例 v3 | 先 `info` 预检，单次发送；只确认接受或结果未知，不能证明已断电/已启动；Android A7 接受/未知跨重启保留，新登录与设备恢复确认后只读解锁；[电源记录](../discovery/endpoints/dsm-system-power-actions.md) |

计划任务当前列表首批上限为 1000，达到上限时以结果不完整拒绝继续假定已读全；该边界不是服务器总量限制。其他列表的分页和容器必须按对应实现/端点记录处理，不能统一假定响应有 `items/total`。

## 设置分组

各组读取 → 形成原基线 → 用户修改 → 再检查原基线和权限 → 发送差量 → 回读实际字段。多 API 保存不是事务；部分成功和未知结果不能简单回填旧界面值当作成功。

| 设置 | API / 版本 | 输入与输出 / 详细字段 |
| --- | --- | --- |
| SMB、NFS、FTP、FTPS、SFTP、服务发现、DSM 文件相关选项 | `Core.FileServ.*`、`Core.Web.DSM` 等，各组固定版本 | `NasFileServiceSettings`；Android A7 原快照、逐组单次保存及加密摘要恢复（101项聚焦/兼容回归，真实服务待验证）；[文件服务](../discovery/endpoints/dsm-file-service-settings.md)、[参数](requests.md#file-services) |
| SSH/Telnet | `Core.Terminal`，支持区间 1…3，具体保存遵循已记录版本 | `NasTerminalSettings`；[终端](../discovery/endpoints/dsm-terminal-settings.md)、[参数](requests.md#terminal) |
| 互联网代理 | `Core.Network.Proxy` | `NasProxySettings`；[代理](../discovery/endpoints/dsm-proxy-settings.md)，秘密仅当次请求，读取未知不当关闭 |
| 物理网卡 | `Core.Network.Ethernet` | `NasEthernetInterface`；[网络](../discovery/endpoints/dsm-ethernet-settings.md)、[参数](requests.md#network)；Android 已接单网卡单次保存、原配置比较与加密摘要恢复；新地址需原连接/原账号重新登录并明确同 NAS 后只读恢复，不复用旧源站会话 |
| 硬件、风扇、LED、蜂鸣、休眠、断电恢复、UPS | `Core.Hardware.*`、`Core.ExternalDevice.UPS` v1 | `NasHardwareSettings`；[硬件](../discovery/endpoints/dsm-hardware-settings.md)、[参数](requests.md#hardware)；Android A7按设备支持集编辑、七步摘要恢复与主动继续原亮度应用，137项聚焦/兼容JVM通过，物理结果待验 |
| 内存压缩及重启要求 | `Core.Hardware.ZRAM/NeedReboot` v1 | [内存压缩](../discovery/endpoints/dsm-zram.md)；Android A7 两步分别保存接受与回读，只读恢复及主动继续标记，不自动重启 |
| 电源计划 | `Core.Hardware.PowerSchedule` load/save v1 | [电源计划](../discovery/endpoints/dsm-power-schedule.md)；Android A7 完整双数组草稿、200 条、冲突/时区/原基线检查，单次整体保存与加密摘要恢复；两项功能75项聚焦/兼容 JVM通过，真实副作用待验 |
| QuickConnect 与路由映射设置 | `Core.QuickConnect/QuickConnect.Upnp` | `NasRemoteAccessSettings`；Android A7 逐步单次保存与原账号加密恢复（64项聚焦/兼容回归，真实网络待验证）；[远程访问](../discovery/endpoints/dsm-remote-access-settings.md)；与登录前地址解析区分 |
| 自动封锁、DoS、防火墙 | `Core.Security.*`，DoS v2，其余相应 v1 | `NasSecuritySettings`；[安全设置](../discovery/endpoints/dsm-security-settings.md)、[参数](requests.md#security)；防火墙任务接受与应用完成分开；Android A7逐组加密摘要与原任务恢复，重启不重新开启或清理；119项聚焦/兼容JVM通过，真实防护待验 |
| 时区、NTP、手动时间、校时 | `Core.Region.NTP`：get/set v3、listzone v1、sync v2 | `NasRegionSettings`；Android A7 原配置、分步单次保存/独立校时及加密摘要恢复（99项聚焦/兼容回归，真实改时待验证）；[区域时间](../discovery/endpoints/dsm-region-time-settings.md)、[参数](requests.md#region)；系统时间变动可能影响登录与任务 |
| DDNS | `Core.DDNS.Provider/Record` v1 | `NasDDNSDraft/NasDDNSDirectory`；[DDNS](../discovery/endpoints/dsm-ddns-settings.md)、[参数](requests.md#ddns)；测试、保存、删除、刷新分别核对  Android 已接四动作单次传输、原记录/服务商预检及加密摘要恢复；仅换密码缺回执不凭列表成功，编辑不回写旧公网地址 |

具体字段的类型、可选性、枚举与默认值只在上述端点记录、领域模型和[生成参数目录](requests.md)维护；不得根据 UI 开关名自行拼请求。旧值是否存在与用户是否修改是不同状态，尤其不能把缺失字段变成 `false/0/""` 写回 NAS。

## 只读与未接入能力

电源计划与 ZRAM 已有保存流程，USB/eSATA 保持只读，详见[存储页](storage.md)。系统固件安装、外接设备弹出和 Storage Analyzer 报告配置仍未接入；不可由 API 名称、页面或领域字段推导实现。打印机 Bonjour 仅有[稳定发现记录](../discovery/endpoints/dsm-printer-bonjour-sharing.md)，移植时按当前目标平台明确范围处理。

## 结果、权限与移植检查

使用功能专用权限和 `MutationResult`/专用状态。高风险动作必须固定 profile、会话、原对象和实际后果；关闭界面不代表撤回已发送操作。普通确认按钮是明确提交，仪式式“已核对”勾选不代替任何权限或目标检查。

测试至少覆盖完整/部分读取、无权限、已变化目标、重复点击、写后断网、回读不一致、跨 NAS 与取消。现有回归位于 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmNasAdministration*` 与请求快照测试；原生流程在 [DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/)。真实系统/网络/账号副作用不能由合成结果推断。

Android A7 套件启停/卸载使用原安装摘要、严格完整目录和统一套件活动恢复；固定版本、写前记录、未知只读与 89 项聚焦证据见[套件控制记录](../discovery/endpoints/dsm-package-control.md#2026-10-13-android-a7-套件控制与统一活动恢复)。原生整组与真实 NAS 分开验收，不能由 JVM 通过推断实机结果。

Android A10 已将连接断开旧回归迁到 `NasConnectionRepository.disconnect`，并移除不再被产品调用的仓储旧门面及其重复身份判断。固定 v1、完整原目标、当前权限与登记环境、单次提交和持久检查点仍沿 A7 执行器；取消后保留已提交事实，原账号恢复只读。迁移测试继续断言网页/服务连接参数、禁止目标、权限拒绝、重复请求、响应丢失、模糊身份和取消，不改变 NAS 请求契约或其他平台实现，也不新增真实环境证据。

关机/重启旧回归同样迁到 `NasPowerActionRepository.perform` 并移除旧门面。执行前按当前实现分别检查登记环境和连接，v3 单次命令后仅记录“已接受”；断线或取消保留已提交检查点，不靠 NAS 暂时不可达认领完成。共享请求 fixture 继续核对动作无额外参数、固定版本与认证位置，模拟结果不证明 NAS 已关机或重启。


2026-10-13 Android A7 原生整合：同一应用APK在中文手机和英文平板深色二倍字号上完成九条真实模型/请求主流程；加上控件、恢复和既有回归，手机79个不同用例分组通过，平板34项通过。合成传输不访问NAS，不改变上述接口的真实环境证据等级；版本/权限门、未知只读及持久化规则不变。详细范围、早期失败与A10剩余门禁见[Android A7账本](../../archive/2026-h2/ANDROID_REWRITE_IMPLEMENTATION_HISTORY_ZH.md#a7-nas-与套件管理整模块功能对齐账本主流程与当前环境聚焦验收已完成)。

Android A10已将SMART旧请求回归迁到当前独立执行器并移除重复门面：固定v1与原device参数不变；取消保留提交检查点，后续仅主动读取原硬盘状态，不自动重新启动/停止。该项为本地合成验证，未提升真实NAS证据等级。

Android A10套件启停/卸载只保留当前安装管线作为执行入口，旧27条协议回归迁到其检查点与异常；既有安装互斥、固定版本/参数及结果回读不变。目录中缺少卸载许可的项目可浏览，但不能提交卸载；本地合成验证不代表真实NAS副作用已验收。

Android A10 套件管线补充验证覆盖设置/来源断线、取消、拒绝和只读恢复，以及安装/配置/取消下载/下一依赖提交中断。SPK上传属于准备阶段：当前实例的未知上传阻止重复提交；跨实例只把准备记为中断，不声称已安装、NAS暂存已清除，也不自动重传或删除。当前VMM控制、网络及映像入口已切换到独立执行器并移除不可达旧确认调用链；既有版本、权限、原身份和只读恢复边界保持。以上为合成自动化证据，不提升真实环境兼容等级。

Android A10已移除旧DDNS测试/保存/删除/地址刷新仓储门面，原25条回归直接构造当前`NasDdnsRepository.plan`并运行`perform`，保留真实请求fixture与取消、防重复断言。服务商和全局动作共享当前仓储互斥；删除基线区分已知网络字段与未提供字段，刷新缺接受回执不能由可读目录升级成功。迁移同时修复共用设置结果把连接/响应失败误归为未知的问题，仍保留提交后未知状态与禁止重发。DDNS、服务与区域设置相关157项聚焦JVM通过；真实环境兼容等级不变。

Android A10其余NAS旧写门面已清理：文件服务、终端、代理、网卡、远程访问、安全与硬件统一走`NasServiceSettingsRepository`，区域/校时走`NasRegionSettingsRepository`，账号/群组删除走`NasDirectoryRepository`。旧有效断言迁到实际HTTP和检查点，保留公共请求fixture、完整基线、权限/环境、防重复、取消和断线边界。设置按完整请求组统计；未提交后组不冒充未知提交，部分字段相同不构成整组完成，区域最终读取失败撤回旧配置成功证据。正常取消停止自动回读，后续使用当前模型的只读恢复。SMB/NFS/终端按既有v1…v3范围选择，公共v1样本与较高已支持版本分别验证；未修改请求契约、持久化或其他平台。252项聚焦集成与仪器源码编译通过，详细失败修正见[A10历史](../../archive/2026-h2/ANDROID_REWRITE_IMPLEMENTATION_HISTORY_ZH.md#a10-收口账本2026-10-14)，真实NAS仍待用户验证。
