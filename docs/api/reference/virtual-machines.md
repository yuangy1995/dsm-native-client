# Virtual Machine Manager

主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)，领域：[ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift)。公开 `SYNO.Virtualization.API.*` 与内部 `SYNO.Virtualization.*` 是两套接口，不能只删掉名称中的 `API` 就复用请求。

## 读取与来源

公开 `API.Guest/Host/Storage/Network/Guest.Image/Task.Info` 使用 v1；当前适配优先使用对应公开能力。内部 Guest/Host/Repo/Network/Image 读取有 v1/v2 范围，写入常固定 v1。缺少一类读取不等于其他分区为空。

返回映射为 `VirtualMachineManagerSnapshot`、虚拟机/主机/存储/网络/映像清单；保留实际身份、状态与单位。内部列表的内存可能以 KiB 返回，编辑 `vram_size` 使用 MiB；不得直接比较未经转换的数字。

完整原始容器、方法、权限和版本见[VMM 内部记录](../discovery/endpoints/vmm-internal.md)；[请求参数目录](requests.md#vmm)覆盖已有公开/内部样例，二者来源须逐项保留。

2026-10-06 当前官方页面已补核内部电源 `action=poweron/shutdown/poweroff/reboot`、
Guest.delete v1 单 `guest_id`、Guest.Image.delete v2 的 `id/synovmm_ui_id` 及网络改名
保持拓扑的字段。Apple 内部电源 on/off、逗号合并 ID/版本差距已在 2026-10-07 M7d1
修正；网络 name-only 参数差距已在 M7d4a 修正，映像内部 id/synovmm_ui_id 已在 M7d4b 接入。新增定义仅为
官方静态证据，详见[本次观察](../discovery/environments/2026-10-06-container-vmm-api-read-observation.md)。

## macOS 当前写入入口

| 用户结果 / 入口 | API 与关键字段 | 结果边界 |
| --- | --- | --- |
| 电源操作 `controlVirtualMachines` | 公开三方法 v1 优先；内部 `Guest.Action.pwr_ctl` v1 使用 poweron/shutdown/poweroff/reboot；单 guest_id | 整批与逐项身份/状态检查、接受回执及目标状态分别确认；内部重启仅记录接受，不能由仍 running 判定完成，未知不重发 |
| 创建 `createVirtualMachine` | 当前 macOS 使用内部 `Guest.create` v1；名称、CPU、MiB 内存、存储/主机、磁盘、网卡、固件、ISO、USB、自启动等 | 以当前 `VirtualMachineCreation` 和精确快照为界，不把 Windows 的公开创建流程写成 macOS 已实现 |
| 基础设置 `updateVirtualMachine` | 内部 `Guest.set` v1：`guest_id/synovmm_ui_id` 与修改的 `name/desc/vcpu_num/vram_size/cpu_weight/autorun` | CPU/内存修改要求停机；回读同一内部清单，逐字段比较，不接受缺失值或展示默认值 |
| 删除虚拟机 | 公开/内部 Guest.delete 均固定 v1、逐个 guest_id；内部读取 list v2 | 原名称/停机状态与完整清单、批量逐项结果；已接受且原 ID 消失才完成，丢回执不认领、不重放 |
| 网络改名 / 删除 | 内部 `Network.set/delete` 固定 v1，读取为 v2 | 当前 name-only 基线不等于完整 VLAN/接口拓扑编辑；名称变化不改变原拓扑 |
| 映像删除 | 公开 Guest.Image v1 的 image_id；内部 v2 的 id/synovmm_ui_id | 原身份/完整副本/冻结状态、内部 ISO 挂载检查、逐项确认和接受回执后回读；移动同来源摘要恢复，缺回执不重放，与引用映像的创建互锁；公开占用由 NAS 拒绝，不猜内部字段。不能把清理任务记录当删除映像 |

2026-10-07 Apple 公开虚拟机/映像删除修正结果归属：现有仓库实例按 API 与原 ID 保存
是否收到本次接受回执。仅“已接受 + 完整清单中原 ID 消失”计为完成；丢回执后即使条目
消失，也保留未知，不认领其他客户端的变化、不重放、不借批量恢复提交后项。恢复读取
失败保留原提交和未知计数；接受后的回读失败可由后续只读请求确认。清单含 total/offset
时要求原生数字、总量一致且从零开始，不把局部清单当作删除完成。

Mac 对全部 VMM 删除反馈以仓库最终结果为准，不再用页面刷新覆盖未知或部分结果。
虚拟机和映像的中英文提示只引导重新连接和查看，不建议重发。该修正不改变请求参数、公开契约、
账号权限或存储；Mac 记录限当前仓库实例，不声称已有跨重启删除恢复。后续 M7d1 已为移动端
接入写入口与独立持久恢复，详见下节；Windows/Android 无源码变化。合成复现和本机回归见
[M7d0 账本](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#2026-10-07-m7d0-虚拟机删除结果归属)，
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
[M7d1 账本](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#2026-10-07-m7d1-虚拟机控制与移动恢复)。
基础编辑、创建、网络与映像管理已分别进入 M7d2、M7d3、M7d4a 与 M7d4b，见下节；控制台
仍为后续源码工作，不把这些缺口写为已完成待真机。

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

## iPhone / iPad 创建与中断恢复（M7d3）

移动原生分步表单填写名称/系统、CPU/MiB 内存、单空白盘及存储、单网卡或断开、ISO/
固件与启动选项，最终摘要说明存储和启动后果后由明确按钮创建，不附加仪式式勾选。
Mac 原创建入口和移动共用内部 v1 请求，磁盘最低 10 GiB，已记录的三类系统预设分别
映射，boot_from 固定 disk；映像只从所选存储和主机选择，资源改变时要求重新选择。

原同名清单成功判断已替换为 task_id、随机请求 UUID、全部参数摘要与任务完成身份
关联。唯一匹配的 Cluster.get_total_progress v1 任务成功且新 guest_id 不属于原清单后，
再核对 get v2/get_setting v1/get v2 的原 ID、基础配置、精确单位、磁盘/网卡/启动结果。
缺回执只允许原 UUID 和完整参数恢复接受；任务消失不能算成功，未知不自动重发。

移动独立文件只保存账号/名称/资源/参数摘要及阶段，写前保存失败零写，换账号隔离
迟到结果，恢复仅只读。未完成记录不能移除以绕过防重复；与原 VM 控制/编辑/删除
以及所引用的当前实例网络/映像写入互斥。Mac 没有新增跨重启存储，其保护仍限
当前仓库实例。外部竞争、真实预设/ISO/启动副作用及系统保护仍需受控环境验收，
不将源码和合成结果提升为版本行为验证。目标平台验证进度见移动主计划 M7d3；
网络与映像管理见下节 M7d4a/M7d4b；控制台已由 M7d5 接入，见下节控制台边界。

## iPhone / iPad 网络管理（M7d4a）

两端提供网络详情、关联虚拟机、单项改名和单项/多项删除；iPhone 用导航详情与表单，
iPad 沿原生分栏、弹窗与键盘操作。删除明确展示网络和关联 VM 数量、断开连接及不可
撤销后果，取消零写。网络创建、VLAN/主机/接口拓扑编辑没有 Mac 产品基线，继续使用
官方 VMM 网页，两端范围一致，不把未实现能力写成只待设备验证。

与 Mac 原入口共用严格 Network.list/get v2；唯一 ID/名称、原生字段、关联数量和
is_freeze 均参与检查。get 不含网络 ID，以 list 身份/名称/数量组合核对，瞬时速率
不参与拓扑身份。set v1 只改名：external 保留空 interfaces_add/remove，private
保留原 host_id，不发送未改 VLAN 或全量接口；delete v1 逐项单 ID。未改名称的 Mac
保存严格读取后零写结束；没有接受回执不会由同名或清单消失认领完成。

移动独立受保护文件只保存上下文、原网络/关联 VM/拓扑/新名称摘要和逐项阶段；
提交前必须落盘，接受/拒绝/完成分别记录，未知中止后项并跨重启只读恢复。已接受
改名须原 ID、新名称和原拓扑一致；删除须完整清单中原 ID 消失且没有冻结，缺回执
继续保护，不重发。同名网络、关联 VM 的控制/编辑/删除与引用网络的创建相互保护，
存储、登录或证书错误不能被正常刷新覆盖。Mac 恢复仍限当前仓库实例，不新增其
持久化；Windows/Android 无本片源码变化，不提升任何真实版本行为证据。

测试、两端实际界面结果和 `PENDING_USER_VALIDATION` 见
[M7d4a 账本](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#2026-10-07-m7d4a-虚拟机网络改名与删除)。

## iPhone / iPad 映像删除（M7d4b）

两端共用严格映像清单、详情、搜索、单项/多项删除和逐项操作记录。公开
Guest.Image list/delete 固定 v1、image_id；内部 list/delete 固定 v2，删除使用
id 和新的 synovmm_ui_id。内部完整清单的 is_freeze、原映像名称/类型/全部副本
共同绑定确认，相同映像的不同主机/存储副本合并为一个目标，相同位置重复或身份
冲突拒绝写入。内部 ISO 的占用只读取已记录 Guest.list v2 和 get_setting v1 的
iso_images；停止的虚拟机仍可能挂载，必须先在 VMM 弹出。公开清单缺少相同占用
字段时不猜测，保留 NAS 拒绝与结果核查；没有显示名称的对象仅供读取。

每项删除前保存摘要，收到明确接受回执后，只有同来源、非冻结、完整清单中原 ID
消失才显示完成；明确拒绝不由外部删除覆盖，缺回执也不因消失认领结果或自动重发。
第二项未知会停止后项，保留第一项完成。未完成删除与引用该映像的创建双向保护，
已接受且恢复完成后才解除。移动独立受保护记录不含映像名称、主机/存储位置或凭据；
Mac 共用同一请求和普通刷新恢复，其保护仍限仓库实例。

映像导入/创建不在现有 macOS 产品基线，两种移动设备统一通过官方 VMM 完成。
源码、实际两端界面、构建结果和设备待办见
[M7d4b 账本](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#2026-10-07-m7d4b-虚拟机映像删除)。
合成测试不提升真实 NAS 删除兼容等级。

## 控制台

`openVirtualMachineConsole` 返回受控会话对象：NAS 同源 `webman/3rdparty/Virtualization/noVNC/vnc.html`，WebSocket 路径为 `synovirtualization/ws/<guest id>`。URL 不携带 SID，认证在受控 Cookie/连接上下文；只允许当前主机的资源与握手，不把任意网页变成携带 NAS 凭据的浏览器。

Apple M7d5 使用共享 `DsmVirtualMachineConsoleFeature` 的非持久 WebKit 宿主，静态资源与 WSS 由 `DsmVirtualMachineConsoleTransport` 沿原证书/会话边界获取，网页只接受受限资源和二进制消息，不向网页安装 NAS Cookie。Mac 按 VM 绑定窗口，移动使用触控宿主；退出、切账号、关闭模块或移动进入后台清理，会话断开后手动重连。源码与合成证据见[M7d5 历史](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#2026-10-07-m7d5-虚拟机触控控制台)。

控制台打开、成功握手、虚拟机实际运行是不同状态。目标平台采用自己的 WebView/窗口及证书处理，不复制 AppKit。真实键盘、剪贴板、代理与网络重连单独验收。

## 其他端实施要求

- 功能范围以平台专项计划为准。2026-10-04 用户已批准的移动 M7 包含完整管理与触控控制台；当前已接入电源/删除、基础设置、创建、网络管理、映像删除与触控控制台；源码接入不代表真实 NAS、正式签名或设备验收通过。
- 公开 API 的能力、参数和结果不能用内部字段替代；内部只读结果不能证明内部写兼容。
- 未确认的关机、强制断电、删除、网络变更不能自动重试或假定可回滚。专用测试资源的授权不等于对真实 VM 的操作授权。
- 任务已接受、任务完成、资源已按要求创建、创建后开机分别核对，不把一个状态覆盖全部阶段。

验证入口：[网络回归](../../../apple/Packages/DsmNetwork/Tests/) 的 VMM/服务管理与请求快照测试、[macOS 工作流测试](../../../apple/Apps/DsmMac/Tests/)。版本化兼容依据仍是[机器索引](../../../contracts/private-api/compatibility.json)，不能从本页推导全版本写入已验证。
