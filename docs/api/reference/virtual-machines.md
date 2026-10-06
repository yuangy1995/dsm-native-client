# Virtual Machine Manager

主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)，领域：[ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift)。公开 `SYNO.Virtualization.API.*` 与内部 `SYNO.Virtualization.*` 是两套接口，不能只删掉名称中的 `API` 就复用请求。

## 读取与来源

公开 `API.Guest/Host/Storage/Network/Guest.Image/Task.Info` 使用 v1；当前适配优先使用对应公开能力。内部 Guest/Host/Repo/Network/Image 读取有 v1/v2 范围，写入常固定 v1。缺少一类读取不等于其他分区为空。

返回映射为 `VirtualMachineManagerSnapshot`、虚拟机/主机/存储/网络/映像清单；保留实际身份、状态与单位。内部列表的内存可能以 KiB 返回，编辑 `vram_size` 使用 MiB；不得直接比较未经转换的数字。

完整原始容器、方法、权限和版本见[VMM 内部记录](../discovery/endpoints/vmm-internal.md)；[请求参数目录](requests.md#vmm)覆盖已有公开/内部样例，二者来源须逐项保留。

2026-10-06 当前官方页面已补核内部电源 `action=poweron/shutdown/poweroff/reboot`、
Guest.delete v1 单 `guest_id`、Guest.Image.delete v2 的 `id/synovmm_ui_id` 及网络改名
保持拓扑的字段。Apple 内部电源 on/off、逗号合并 ID/版本差距已在 2026-10-07 M7d1
修正；映像 image_id 和网络 name-only 参数差距仍待后续切片。新增定义仅为
官方静态证据，详见[本次观察](../discovery/environments/2026-10-06-container-vmm-api-read-observation.md)。

## macOS 当前写入入口

| 用户结果 / 入口 | API 与关键字段 | 结果边界 |
| --- | --- | --- |
| 电源操作 `controlVirtualMachines` | 公开三方法 v1 优先；内部 `Guest.Action.pwr_ctl` v1 使用 poweron/shutdown/poweroff/reboot；单 guest_id | 整批与逐项身份/状态检查、接受回执及目标状态分别确认；内部重启仅记录接受，不能由仍 running 判定完成，未知不重发 |
| 创建 `createVirtualMachine` | 当前 macOS 使用内部 `Guest.create` v1；名称、CPU、MiB 内存、存储/主机、磁盘、网卡、固件、ISO、USB、自启动等 | 以当前 `VirtualMachineCreation` 和精确快照为界，不把 Windows 的公开创建流程写成 macOS 已实现 |
| 基础设置 `updateVirtualMachine` | 内部 `Guest.set` v1：`guest_id/synovmm_ui_id` 与修改的 `name/desc/vcpu_num/vram_size/cpu_weight/autorun` | CPU/内存修改要求停机；回读同一内部清单，逐字段比较，不接受缺失值或展示默认值 |
| 删除虚拟机 | 公开/内部 Guest.delete 均固定 v1、逐个 guest_id；内部读取 list v2 | 原名称/停机状态与完整清单、批量逐项结果；已接受且原 ID 消失才完成，丢回执不认领、不重放 |
| 网络改名 / 删除 | 内部 `Network.set/delete` 固定 v1，读取为 v2 | 当前 name-only 基线不等于完整 VLAN/接口拓扑编辑；名称变化不改变原拓扑 |
| 映像删除 | 公开/内部 Guest.Image 路径分别处理 | 校验目标、占用及实际删除结果，不能把清理任务记录当删除映像 |

2026-10-07 Apple 公开虚拟机/映像删除修正结果归属：现有仓库实例按 API 与原 ID 保存
是否收到本次接受回执。仅“已接受 + 完整清单中原 ID 消失”计为完成；丢回执后即使条目
消失，也保留未知，不认领其他客户端的变化、不重放、不借批量恢复提交后项。恢复读取
失败保留原提交和未知计数；接受后的回读失败可由后续只读请求确认。清单含 total/offset
时要求原生数字、总量一致且从零开始，不把局部清单当作删除完成。

Mac 对全部 VMM 删除反馈以仓库最终结果为准，不再用页面刷新覆盖未知或部分结果。
虚拟机和映像的中英文提示只引导重新连接和查看，不建议重发。该修正不改变请求参数、公开契约、
账号权限或存储；Mac 记录限当前仓库实例，不声称已有跨重启删除恢复。后续 M7d1 已为移动端
接入写入口与独立持久恢复，详见下节；Windows/Android 无源码变化。合成复现和本机回归见
[M7d0 账本](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-07-m7d0-虚拟机删除结果归属)，
未增加真实 NAS 或版本行为证据；其他内部参数差距仍按上文独立处理。

## iPhone / iPad 电源与删除（M7d1）

原生详情和多选确认支持开机、正常关机、强制断电、重启及删除；能力不足、状态转换中、
原对象变化、权限失效或已有未知操作时不提交。与 macOS 共用电源/删除流水线，无平行
请求实现；接口优先级、固定版本、整批预检、逐项权限和结果保护一致。强制断电与删除
分别说明数据损坏和永久删除后果，取消零写。

移动记录只保存账号/ID/名称摘要、动作、逐项阶段和接受标记，复用现有文件保护与备份
排除；不保存名称、地址或凭据明文。提交前必须保存，接受后单独落盘；重新进入或重启
只读取完整清单，只有原操作已接受才可确认完成。丢回执后目标即使达到相同状态或消失
仍保留未知和防重复；原 ID 改名仍受保护，换账号不显示或续写旧账号内容。

公开 v1 没有重启方法，仅在内部 Guest v2 / Guest.Action v1 可用时发送 reboot，不通过
关机再开机替代。[官方静态补核](../discovery/environments/2026-10-07-vmm-power-read-observation.md)
没有提供可靠完成标记，uptime 的类型/单位及重启变化也未验证，因此重启接受后保留操作
记录和互斥，提示在 Virtual Machine Manager 中查看；刷新或重新打开不会凭仍 running
认领完成。证书异常立即停止后续请求，不降级为普通未知后继续读取。

本机验证、独立复核及具体真机待办见
[M7d1 账本](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-07-m7d1-虚拟机控制与移动恢复)。
基础编辑进入 M7d2，见下节；创建、网络/映像写与控制台仍为后续源码工作，不把这些
缺口写为已完成待真机。

## iPhone / iPad 基础设置编辑（M7d2）

详情中的原生表单提供名称/说明、CPU/内存、五档优先级与三态自动启动，CPU/内存
仅明确关机时开放，内存以精确 MiB 编辑。只提交变化，不为缺失值填默认数值；当前
原值/状态变化要求重新打开设置。与 Mac 共用内部 get/list v2、set v1 流水线，写前重新
核对原身份和字段、权限及完整清单；取消零写，明确保存按钮不附加重复确认勾选。

编辑与电源/删除共用目标保护；提交前、接受后和完成阶段分别落盘。设置仅保存逐字段
摘要，表单明文不进入操作文件，未知不重放；接受后恢复只读精确字段，不能由公开摘要、
布尔转换、同名对象或外部修改认领。账号切换隔离在途结果，存储/证书失败停止后续操作。
源码与实际验证进度见移动主计划的 M7d2 账本；真实 NAS 尚未保存，不提升兼容等级。

创建时 ISO/USB 空槽使用已记录的 `unmounted`，不能发送任意空字符串。CPU/内存/磁盘输入限制、枚举值、vdisks/vnics 嵌套字段及存储单位以 `VirtualMachineCreation`、Repository 与快照为准，不凭其他端表单补字段。

**当前实现限制：** macOS 内部创建发送后，以刷新清单中存在匹配名称作为完成检查；这不足以证明全部创建参数、任务归属和实际启动行为。此处记录源码事实，不把它提升为完整行为验证，也不建议其他端把同名存在性当成通用可靠结果。需要加强时应独立处理接口/任务身份契约与回归，不在文档整理中猜测新字段或更改实现。

## 控制台

`openVirtualMachineConsole` 返回受控会话对象：NAS 同源 `webman/3rdparty/Virtualization/noVNC/vnc.html`，WebSocket 路径为 `synovirtualization/ws/<guest id>`。URL 不携带 SID，认证在受控 Cookie/连接上下文；只允许当前主机的资源与握手，不把任意网页变成携带 NAS 凭据的浏览器。

控制台打开、成功握手、虚拟机实际运行是不同状态。目标平台采用自己的 WebView/窗口及证书处理，不复制 AppKit。真实键盘、剪贴板、代理与网络重连单独验收。

## 其他端实施要求

- 功能范围以平台专项计划为准。2026-10-04 用户已批准的移动 M7 包含完整管理与触控控制台；当前已接入电源/删除，其余只读投影是尚未实施写入口的进度状态，不再是固定“精选”范围，也不代表已有入口已验证。
- 公开 API 的能力、参数和结果不能用内部字段替代；内部只读结果不能证明内部写兼容。
- 未确认的关机、强制断电、删除、网络变更不能自动重试或假定可回滚。专用测试资源的授权不等于对真实 VM 的操作授权。
- 任务已接受、任务完成、资源已按要求创建、创建后开机分别核对，不把一个状态覆盖全部阶段。

验证入口：[网络回归](../../../apple/Packages/DsmNetwork/Tests/) 的 VMM/服务管理与请求快照测试、[macOS 工作流测试](../../../apple/Apps/DsmMac/Tests/)。版本化兼容依据仍是[机器索引](../../../contracts/private-api/compatibility.json)，不能从本页推导全版本写入已验证。
