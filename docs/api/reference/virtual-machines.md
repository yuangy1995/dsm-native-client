# Virtual Machine Manager

主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)，领域：[ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift)。公开 `SYNO.Virtualization.API.*` 与内部 `SYNO.Virtualization.*` 分开适配，不能删除名称中的API后复用请求。

## 读取与用户操作

公开 API.Guest/Host/Storage/Network/Guest.Image/Task.Info 使用v1并优先；内部读取多为v2，具体写方法常为v1。各资源分区独立失败，不以空清单吞掉错误。完整内部字段、枚举、单位与结果证明只维护于[VMM内部定义](../discovery/endpoints/vmm-internal.md)。

| 用户结果 | 关键语义 |
| --- | --- |
| 查看VM/主机/存储/网络/映像/保护 | 保留稳定身份、状态、来源及单位；内部内存读取KiB、写入MiB |
| 电源控制 | 公开方法优先；内部pwr_ctl使用poweron/shutdown/poweroff/reboot，逐项原身份；重启接受不等于完成 |
| 创建VM | 完整参数、UUID、任务编号及最终guest_id关联，按编号回读；无回执不认领同名对象 |
| 编辑VM | 原基线与差量分开，精确autorun/CPU权重；一次提交，不能跨公开/内部自动重试 |
| 删除VM/映像 | 原身份、权限与占用复查，明确回执及完整列表结果分别核对；保护冻结对象 |
| 网络管理 | 改名保留拓扑，external接口增删/private主机和VLAN按实际变化发送；删除不影响未选目标 |
| 控制台 | 固定VM、窗口来源、认证上下文与证书边界；凭据不进入URL，不能作为通用登录浏览器 |

[生成样例](requests.md#vmm)保留特定请求形态，不能证明所有当前流程或真实环境通过。身份/权限变化、部分结果、取消和提交后断线都须保留准确状态与防重复保护。

## 公开任务与内部任务

公开创建使用 `SYNO.Virtualization.API.Guest.create` v1 和 `API.Task.Info.get` v1，绑定原 `task_id`、完成状态和新 `guest_id`，再按原资源与配置回读；不把内部系统预设、固件或ISO字段混入公开请求。内部创建使用独立的 `Guest.create` / `Cluster.get_total_progress` 契约，不能用公开任务的返回结构解码。创建、配置核对、用户所选的开机分别记录结果，恢复读取不自动开始尚未提交的开机。

NAS 已有文件导入使用公开 `API.Guest.Image.create` v1，保留原文件、存储与映像类型，按原任务返回的新映像编号及配置确认；不以同名映像认领导入。任务清理使用 `API.Task.Info.list/get/clear` v1，绑定用户所选终态记录，清理前重读；未完成创建或导入仍依赖的任务不得清除，清记录不删除映像或源文件。

平台功能状态见[平台矩阵](../../progress/PLATFORM_MATRIX.md)，未完成项和真实NAS验证条件见[已知限制](../../progress/KNOWN_LIMITATIONS.md)，控制台宿主约束见[平台集成](../../development/PLATFORM_INTEGRATION.md)。
