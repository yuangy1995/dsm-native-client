# 存储、硬盘检测与客户端挂载

主实现：[存储读取扩展](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+Storage.swift)、[硬件/检测 Repository](../../../apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository.swift)；领域：[NasAdministration](../../../apple/Packages/DsmCore/Sources/NasAdministration.swift)。

## NAS 存储接口

| 功能 | API / 方法与版本 | 输入 / 输出及限制 |
| --- | --- | --- |
| 存储总览 | `SYNO.Storage.CGI.Storage.load_info` v1 | 无业务参数；存储池/卷/硬盘映射为 `NasStorageSnapshot`，磁盘 `id/device` 必须非空且唯一 |
| SMART 当前状态 | `SYNO.Core.Storage.Disk.get_smart_test_log` v1 | `device` 必须来自当前存储列表，不能拿 UI 的磁盘 ID 替代 |
| SMART 历史 | `Core.Storage.Disk.disk_test_log_get` v1 | `device/offset/limit/sort_by/sort_direction/type`；保持检测类型和实际结果 |
| 启动 / 停止 SMART | `Core.Storage.Disk.do_smart_test` v1 | `device`、`type=quick/extend/stop`；确认目标/可检测能力/占用，再单次发送并读取最终状态 |
| 外接存储 | `Core.ExternalDevice.Storage.USB/eSATA` v1 的已接读取 | 分别保留可用性；当前不提供弹出写操作；[外接存储记录](../discovery/endpoints/dsm-external-storage.md) |
| 电源计划 | `Core.Hardware.PowerSchedule.load` v1 | 只读，未知时间/启用状态不补值；[记录](../discovery/endpoints/dsm-power-schedule.md) |
| 内存压缩 | `Core.Hardware.ZRAM.get` v1 | 只读，不提供设置开关；[记录](../discovery/endpoints/dsm-zram.md) |

SMART 详细响应容器、状态别名与占用规则见[硬盘检测记录](../discovery/endpoints/dsm-smart-test.md)，精确写入字段见[参数目录](requests.md#storage)。权限、读取错误、设备换盘和不支持检测均不能解释为“未运行，可启动”。

## 文件空间分析

客户端的空间分析复用公开 File Station List/Search/MD5，不是一个已固化的 Storage Analyzer API。保持当前账号可见范围，排除明确不在分析范围的回收站、远程挂载及系统数据；先按大小筛选重复候选，再核对内容。取消只停止自己的任务。

文件逻辑大小不等于文件系统实际占用，也不等于可释放空间。Storage Analyzer 套件历史报告、报告配置和计划尚无本项目固化的完整契约，不得根据页面名称猜方法；范围见[存储长期计划](../../development/NATIVE_DSM_STORAGE_MANAGEMENT_PLAN_ZH.md)。

## Finder / Explorer 挂载属于客户端集成

macOS File Provider 与 Windows Cloud Files 复用[文件 API](files.md)，没有新增“挂载成本地磁盘”的 NAS Web API。平台系统注册、按需取回、缓存、工作集、写回与恢复日志是客户端职责，不能从 NAS `Mount` 接口推导出来。

- NAS `FileStation.Mount`：把另一台服务器的远程文件夹接入 NAS。
- 客户端系统挂载：在 Finder/Explorer 中显示当前 NAS 文件，按需下载或保存。
- 本机预览缓存/Office 编辑副本：独立生命周期，不是上述任何一种远程挂载。

领域参考：[DesktopCloudDrive](../../../apple/Packages/DsmCore/Sources/DesktopCloudDrive.swift)、[写回语义](../../../apple/Packages/DsmCore/Sources/DesktopDriveWriteback.swift)。系统行为和恢复约束只维护于[桌面挂载计划](../../development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)与[发布验收](../../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)，不得把临时签名包当成已验证 File Provider。

## 验收

先验证只读存储和原始设备身份，再在用户明确授权的专用磁盘/目标上验证检测。写入未知时只查询原检测，不能重复启动；热点拔插、真实硬盘健康、休眠/唤醒和正式系统挂载需真实设备。合成测试与版本化 NAS 证据分别记录于[测试目录](../../../apple/Packages/DsmNetwork/Tests/)及[兼容索引](../../../contracts/private-api/compatibility.json)。
