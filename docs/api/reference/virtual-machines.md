# Virtual Machine Manager

主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)，领域：[ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift)。公开 `SYNO.Virtualization.API.*` 与内部 `SYNO.Virtualization.*` 是两套接口，不能只删掉名称中的 `API` 就复用请求。

## 读取与来源

公开 `API.Guest/Host/Storage/Network/Guest.Image/Task.Info` 使用 v1；当前适配优先使用对应公开能力。内部 Guest/Host/Repo/Network/Image 读取有 v1/v2 范围，写入常固定 v1。缺少一类读取不等于其他分区为空。

返回映射为 `VirtualMachineManagerSnapshot`、虚拟机/主机/存储/网络/映像清单；保留实际身份、状态与单位。内部列表的内存可能以 KiB 返回，编辑 `vram_size` 使用 MiB；不得直接比较未经转换的数字。

完整原始容器、方法、权限和版本见[VMM 内部记录](../discovery/endpoints/vmm-internal.md)；[请求参数目录](requests.md#vmm)覆盖已有公开/内部样例，二者来源须逐项保留。

## macOS 当前写入入口

| 用户结果 / 入口 | API 与关键字段 | 结果边界 |
| --- | --- | --- |
| 电源操作 `controlVirtualMachines` | 按公开/内部支持路径执行；内部 `Guest.Action.pwr_ctl` v1；ID 与动作由枚举生成 | 批量确认、当前状态与状态转换互斥，未知不重新发送开关机；最终设备状态须另核对 |
| 创建 `createVirtualMachine` | 当前 macOS 使用内部 `Guest.create` v1；名称、CPU、MiB 内存、存储/主机、磁盘、网卡、固件、ISO、USB、自启动等 | 以当前 `VirtualMachineCreation` 和精确快照为界，不把 Windows 的公开创建流程写成 macOS 已实现 |
| 基础设置 `updateVirtualMachine` | 内部 `Guest.set` v1：`guest_id/synovmm_ui_id` 与修改的 `name/desc/vcpu_num/vram_size/cpu_weight/autorun` | CPU/内存修改要求停机；回读同一内部清单，逐字段比较，不接受缺失值或展示默认值 |
| 删除虚拟机 | 对应 Guest 删除路径 | 稳定目标和停止条件、批量逐项结果；丢回执先查，不重放 |
| 网络改名 / 删除 | 内部 `Network.set/delete` 固定 v1，读取为 v2 | 当前 name-only 基线不等于完整 VLAN/接口拓扑编辑；名称变化不改变原拓扑 |
| 映像删除 | 公开/内部 Guest.Image 路径分别处理 | 校验目标、占用及实际删除结果，不能把清理任务记录当删除映像 |

创建时 ISO/USB 空槽使用已记录的 `unmounted`，不能发送任意空字符串。CPU/内存/磁盘输入限制、枚举值、vdisks/vnics 嵌套字段及存储单位以 `VirtualMachineCreation`、Repository 与快照为准，不凭其他端表单补字段。

**当前实现限制：** macOS 内部创建发送后，以刷新清单中存在匹配名称作为完成检查；这不足以证明全部创建参数、任务归属和实际启动行为。此处记录源码事实，不把它提升为完整行为验证，也不建议其他端把同名存在性当成通用可靠结果。需要加强时应独立处理接口/任务身份契约与回归，不在文档整理中猜测新字段或更改实现。

## 控制台

`openVirtualMachineConsole` 返回受控会话对象：NAS 同源 `webman/3rdparty/Virtualization/noVNC/vnc.html`，WebSocket 路径为 `synovirtualization/ws/<guest id>`。URL 不携带 SID，认证在受控 Cookie/连接上下文；只允许当前主机的资源与握手，不把任意网页变成携带 NAS 凭据的浏览器。

控制台打开、成功握手、虚拟机实际运行是不同状态。目标平台采用自己的 WebView/窗口及证书处理，不复制 AppKit。真实键盘、剪贴板、代理与网络重连单独验收。

## 其他端实施要求

- 功能范围以平台专项计划为准。移动端的只读精选范围不因桌面存在电源或高级创建而扩张。
- 公开 API 的能力、参数和结果不能用内部字段替代；内部只读结果不能证明内部写兼容。
- 未确认的关机、强制断电、删除、网络变更不能自动重试或假定可回滚。专用测试资源的授权不等于对真实 VM 的操作授权。
- 任务已接受、任务完成、资源已按要求创建、创建后开机分别核对，不把一个状态覆盖全部阶段。

验证入口：[网络回归](../../../apple/Packages/DsmNetwork/Tests/) 的 VMM/服务管理与请求快照测试、[macOS 工作流测试](../../../apple/Apps/DsmMac/Tests/)。版本化兼容依据仍是[机器索引](../../../contracts/private-api/compatibility.json)，不能从本页推导全版本写入已验证。
