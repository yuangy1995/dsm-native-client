# NAS 系统管理

分类：本页为 DSM 内部接口。主实现：[DsmNasAdministrationRepository](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository.swift) 及同目录功能扩展；领域输入/输出：[NasAdministration](../../../apple/Packages/DsmCore/Sources/NasAdministration.swift)。公开文件协议与 NAS 设置不能混成一个权限层。

## 功能分类

| 用户结果 / 领域入口 | API 与版本规则 | 参数、响应和风险的规范位置 |
| --- | --- | --- |
| 概览 `loadSystemOverview` | `SYNO.Core.System.info`，当前支持区间 1…3 | 系统版本、运行状态等 → `NasSystemOverview`；字段未知保留未知 |
| 资源监控 `loadPerformanceSnapshot` | `Core.System.Utilization.get` v1 | 专用性能快照；采样/图表历史属于客户端，不把内存采样写成 NAS 历史记录；[样例](requests.md#system-performance) |
| 进程 `loadSystemProcesses` | `Core.System.Process/ProcessGroup` v1 的已接读取 | [进程记录](../discovery/endpoints/dsm-system-processes.md)，仅最小白名单信息，无终止进程接口 |
| 套件 `loadPackages/controlPackageResult/uninstallPackageResult` | Package 列表/可行性 v2，Control 和 Uninstallation v1 | [套件控制](../discovery/endpoints/dsm-package-control.md)；启动、停止、卸载分别判断，列表可见不代表允许操作 |
| 套件目录、安装、更新和 SPK 上传 | Package 目录、准备、安装与进度的分阶段契约 | 已有[安装实现](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageInstallation.swift)和 macOS 原生入口；[安装记录](../discovery/endpoints/dsm-package-installation.md)维护预检、卷、许可、提交、取消及回读；共享实现不等于移动入口或真实安装已经验证 |
| 账号、群组 | `Core.User/Group` v1 | [账号目录](../discovery/endpoints/dsm-account-directory.md)；`NasAccountDraft/NasGroupDraft`，密码意图、成员增删及当前账号保护分别处理 |
| 当前连接 | `Core.CurrentConnection.list/kick_connection` | [连接记录](../discovery/endpoints/dsm-current-connection.md)；按完整连接身份断开，当前或不能判断是否当前连接时保留额外风险说明 |
| 日志 | `Core.SyslogClient.Log`、`LogCenter.History` 已接列表 | `NasLogPage`；分页与源区分，日志正文不得进入调试导出或本契约材料 |
| 计划任务 | `Core.TaskScheduler` 列表 v3、详情/保存等固定契约；`Core.EventScheduler` 结果读取 | [任务记录](../discovery/endpoints/dsm-task-scheduler.md)；`NasScheduledTaskDraft`，任务 ID 与 real_owner/原快照绑定；运行接受不等于脚本成功 |
| 系统更新检查 | `Core.Upgrade.Server.check` v3 | `user_reading=true,need_auto_smallupdate=true,need_promotion=false`；`update` → `NasSystemUpdateInfo`，不下载或安装系统更新；[记录](../discovery/endpoints/dsm-system-update-check.md) |
| 关机 / 重启 | `Core.System.shutdown/reboot`，样例 v3 | 先 `info` 预检，单次发送；只确认接受或结果未知，不能证明已断电/已启动；[电源记录](../discovery/endpoints/dsm-system-power-actions.md) |

计划任务当前列表首批上限为 1000，达到上限时以结果不完整拒绝继续假定已读全；该边界不是服务器总量限制。其他列表的分页和容器必须按对应实现/端点记录处理，不能统一假定响应有 `items/total`。

## 设置分组

各组读取 → 形成原基线 → 用户修改 → 再检查原基线和权限 → 发送差量 → 回读实际字段。多 API 保存不是事务；部分成功和未知结果不能简单回填旧界面值当作成功。

| 设置 | API / 版本 | 输入与输出 / 详细字段 |
| --- | --- | --- |
| SMB、NFS、FTP、FTPS、SFTP、服务发现、DSM 文件相关选项 | `Core.FileServ.*`、`Core.Web.DSM` 等，各组固定版本 | `NasFileServiceSettings`；[文件服务](../discovery/endpoints/dsm-file-service-settings.md)、[参数](requests.md#file-services) |
| SSH/Telnet | `Core.Terminal`，支持区间 1…3，具体保存遵循已记录版本 | `NasTerminalSettings`；[终端](../discovery/endpoints/dsm-terminal-settings.md)、[参数](requests.md#terminal) |
| 互联网代理 | `Core.Network.Proxy` | `NasProxySettings`；[代理](../discovery/endpoints/dsm-proxy-settings.md)，秘密仅当次请求，读取未知不当关闭 |
| 物理网卡 | `Core.Network.Ethernet` | `NasEthernetInterface`；[网络](../discovery/endpoints/dsm-ethernet-settings.md)、[参数](requests.md#network)；地址变化后的重新连接不能复用错误源站会话 |
| 硬件、风扇、LED、蜂鸣、休眠、断电恢复、UPS | `Core.Hardware.*`、`Core.ExternalDevice.UPS` v1 | `NasHardwareSettings`；[硬件](../discovery/endpoints/dsm-hardware-settings.md)、[参数](requests.md#hardware) |
| QuickConnect 与路由映射设置 | `Core.QuickConnect/QuickConnect.Upnp` | `NasRemoteAccessSettings`；[远程访问](../discovery/endpoints/dsm-remote-access-settings.md)；与登录前地址解析区分 |
| 自动封锁、DoS、防火墙 | `Core.Security.*`，DoS v2，其余相应 v1 | `NasSecuritySettings`；[安全设置](../discovery/endpoints/dsm-security-settings.md)、[参数](requests.md#security)；防火墙任务接受与应用完成分开 |
| 时区、NTP、手动时间、校时 | `Core.Region.NTP`：get/set v3、listzone v1、sync v2 | `NasRegionSettings`；[区域时间](../discovery/endpoints/dsm-region-time-settings.md)、[参数](requests.md#region)；系统时间变动可能影响登录与任务 |
| DDNS | `Core.DDNS.Provider/Record` v1 | `NasDDNSDraft/NasDDNSDirectory`；[DDNS](../discovery/endpoints/dsm-ddns-settings.md)、[参数](requests.md#ddns)；测试、保存、删除、刷新分别核对 |

具体字段的类型、可选性、枚举与默认值只在上述端点记录、领域模型和[生成参数目录](requests.md)维护；不得根据 UI 开关名自行拼请求。旧值是否存在与用户是否修改是不同状态，尤其不能把缺失字段变成 `false/0/""` 写回 NAS。

## 只读与未接入能力

电源计划与 ZRAM 已有保存流程，USB/eSATA 保持只读，详见[存储页](storage.md)。系统固件安装、外接设备弹出和 Storage Analyzer 报告配置仍未接入；不可由 API 名称、页面或领域字段推导实现。打印机 Bonjour 仅有[稳定发现记录](../discovery/endpoints/dsm-printer-bonjour-sharing.md)，移植时按当前目标平台明确范围处理。

## 结果、权限与移植检查

使用功能专用权限和 `MutationResult`/专用状态。高风险动作必须固定 profile、会话、原对象和实际后果；关闭界面不代表撤回已发送操作。普通确认按钮是明确提交，仪式式“已核对”勾选不代替任何权限或目标检查。

测试至少覆盖完整/部分读取、无权限、已变化目标、重复点击、写后断网、回读不一致、跨 NAS 与取消。现有回归位于 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmNasAdministration*` 与请求快照测试；原生流程在 [DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/)。真实系统/网络/账号副作用不能由合成结果推断。
