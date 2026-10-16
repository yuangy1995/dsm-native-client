# NAS 系统管理

本页为 DSM 内部接口入口。请求/响应细节只维护于下列稳定定义；[通用标准](common.md)约束认证、错误、权限和写入结果。主实现为 [DsmNasAdministrationRepository](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository.swift)，领域模型为 [NasAdministration](../../../apple/Packages/DsmCore/Sources/NasAdministration.swift)。

## 读取与管理

| 用户结果 | API / 版本 | 当前定义与关键边界 |
| --- | --- | --- |
| 系统概览与资源 | Core.System.info v3；Utilization.get v1 | [基础读取](../discovery/endpoints/dsm-system-monitoring.md#dsm-system-read)；字段未知保留未知，内存采样不是 NAS 历史 |
| 进程 / 连接 / 日志 | Process/ProcessGroup v1；CurrentConnection；SyslogClient.Log/LogCenter.History | [进程](../discovery/endpoints/dsm-system-monitoring.md#dsm-system-processes)、[连接](../discovery/endpoints/dsm-account-and-connection.md#dsm-current-connection)、[日志](../discovery/endpoints/dsm-system-monitoring.md#dsm-system-log)；无终止进程接口，断开固定目标，正文不进入诊断材料 |
| 套件启停与卸载 | Package.list v2；Control/Uninstallation v1 | [套件控制](../discovery/endpoints/dsm-packages.md#dsm-package-control)；列表可见不代表允许操作 |
| 安装、更新、SPK上传 | Package/Installation 分阶段固定版本 | [套件中心](../discovery/endpoints/dsm-packages.md#dsm-package-installation)；预检、卷、许可、依赖、提交、取消和回读分别处理 |
| 账号与群组 | Core.User/Group v1 | [账号目录](../discovery/endpoints/dsm-account-and-connection.md#dsm-account-directory)；密码意图、成员差量、当前/保留账号保护 |
| 计划任务 | TaskScheduler 列表/运行v3；详情/创建/修改v4；EventScheduler | [任务计划](../discovery/endpoints/dsm-system-monitoring.md#dsm-task-scheduler)；任务ID、real_owner与原快照绑定，接受运行不等于脚本成功 |
| 系统更新检查 | Upgrade.Server.check v3 | [更新检查](../discovery/endpoints/dsm-system-monitoring.md#dsm-system-update-check)；仅检查，不下载/安装固件 |
| 关机与重启 | Core.System.shutdown/reboot v3 | [电源动作](../discovery/endpoints/dsm-hardware-and-power.md#dsm-system-power-actions)；先info预检、单次发送，只确认接受或未知，不以暂时不可达证明完成 |

计划任务首批上限1000是客户端完整性边界，达到上限不能假定已读全；它不是服务器总量限制。各列表容器和分页按对应定义处理，不统一猜测 items/total。

## 设置

| 设置 | API范围 | 唯一字段定义 |
| --- | --- | --- |
| 文件服务 | Core.FileServ / Web.DSM | [SMB/NFS/FTP/FTPS/SFTP/服务发现](../discovery/endpoints/dsm-network-and-security.md#dsm-file-service-settings) |
| 远程终端 / 代理 | Core.Terminal / Network.Proxy | [终端](../discovery/endpoints/dsm-network-and-security.md#dsm-terminal-settings)、[代理](../discovery/endpoints/dsm-network-and-security.md#dsm-proxy-settings) |
| 网卡 | Core.Network.Ethernet | [物理网卡](../discovery/endpoints/dsm-network-and-security.md#dsm-ethernet-settings)；地址改变不能向新来源转送旧会话 |
| 硬件 / UPS | Core.Hardware / ExternalDevice.UPS v1 | [硬件](../discovery/endpoints/dsm-hardware-and-power.md#dsm-hardware-settings)；仅编辑设备支持项 |
| 内存压缩 | Core.Hardware.ZRAM/NeedReboot v1 | [ZRAM](../discovery/endpoints/dsm-hardware-and-power.md#dsm-zram)；保存与重启标记分步，不自动重启 |
| 电源计划 | Core.Hardware.PowerSchedule.load/save v1 | [电源计划](../discovery/endpoints/dsm-hardware-and-power.md#dsm-power-schedule)；完整双数组和原基线 |
| QuickConnect/路由映射 | Core.QuickConnect/QuickConnect.Upnp | [远程访问](../discovery/endpoints/dsm-account-and-connection.md#dsm-remote-access-settings)；与登录前地址解析区分 |
| 自动封锁/DoS/防火墙 | Core.Security | [安全](../discovery/endpoints/dsm-network-and-security.md#dsm-security-settings)；任务接受与应用完成分开 |
| 时区/NTP/校时 | Region.NTP get/set v3、listzone v1、sync v2 | [区域时间](../discovery/endpoints/dsm-network-and-security.md#dsm-region-time-settings)；时间变化可能影响登录和计划 |
| DDNS | DDNS.Provider/Record v1 | [DDNS](../discovery/endpoints/dsm-network-and-security.md#dsm-ddns-settings)；测试、保存、删除、刷新分别核对，秘密不回显 |

读取完整原基线后形成差量；写前再次检查目标和权限，按实际字段回读。多 API 保存不是事务；不能把未知字段变成 false/0/空串写回，也不能回填旧界面值冒充成功。密码替换缺少接受回执时，现有保护标志不能证明新密码生效。

USB/eSATA读取、SMART与本地挂载边界见[存储](storage.md)。只有名称的 Printer BonjourSharing 保持零猜测请求。五端实现状态见[平台矩阵](../../progress/PLATFORM_MATRIX.md)，当前缺口及实际系统/网络/账号副作用验收见[已知限制](../../progress/KNOWN_LIMITATIONS.md)。
