# DSM 基础读取接口

本页保留聚合端点标识，具体设置不重复定义；均为内部 API。

## `dsm-system-observability`

`SYNO.Core.System.info` v3、`SYNO.Core.System.Utilization.get` v1 提供系统与性能摘要；进程、连接、日志和更新分别见 [进程](dsm-system-processes.md)、[连接](dsm-current-connection.md)、[日志](dsm-system-log.md)、[更新检查](dsm-system-update-check.md)。各分区独立失败，不以空数据替代权限或解析错误。

## `dsm-storage-hardware`

`SYNO.Storage.CGI.Storage.load_info` v1 为存储读取基线。历史环境 `SYNO.Core.Storage.Volume.list` v1 返回 101，不得覆盖有效的 load_info 结果；`SYNO.Storage.CGI.Smart`、`SYNO.Core.Storage.Disk` 的具体调用由 [SMART](dsm-smart-test.md)和[存储入口](../../reference/storage.md)说明。硬件、UPS、电源计划、ZRAM、外接存储见各自记录，不在聚合索引复制写入口状态。

## `dsm-administration`

套件列表 `SYNO.Core.Package.list` v2；详情与控制见 [套件控制](dsm-package-control.md)和[安装](dsm-package-installation.md)。计划任务详情/创建/修改 v4、列表/运行 v3 见[任务计划](dsm-task-scheduler.md)。其余网络、账号、文件服务、安全与时间设置由[系统管理入口](../../reference/system-management.md)链接到独立参数定义。

## 证据

[环境记录](../environments/INDEX.md)保留版本、权限和方法级结果。聚合端点有读取证据不代表其全部写方法已验证。

## 名称与定位

完整API名为 `SYNO.Core.TaskScheduler`、`SYNO.Core.EventScheduler`（计划与结果）、`SYNO.Core.SyslogClient.Log` 和 `SYNO.LogCenter.History`（日志）；请求细节由上述独立记录维护。`SYNO.Core.Storage.Volume` 的list历史返回101，保持已有降级。`SYNO.Core.Package.Thumb` v1的现行二进制读取见[套件图标](dsm-package-control.md#套件图标读取)；源码形态与真实版本证据分别记录。
