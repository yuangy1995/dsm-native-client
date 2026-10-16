# Virtual Machine Manager 内部接口

稳定端点 `vmm-internal`；组件 virtual-machine-manager；internal/mixed/critical。优先公开 `SYNO.Virtualization.API.*` v1；以下内部 `SYNO.Virtualization.*` 不能复制公开参数。路径与JSON业务值格式来自能力发现，业务请求POST，认证与错误遵循[通用标准](../../reference/common.md)。

## 方法、版本与字段

下表短名均以 `SYNO.Virtualization.` 为前缀。明确方法版本优先于API声明的最大版本。

| API / 方法 | 版本与请求 | 响应或边界 |
| --- | --- | --- |
| Guest.list/get/get_basic | v2；get/get_basic 单 guest_id，部分get_basic用途additional=[guest_repo] | 稳定guest_id/name、状态及原字段，不用模型默认值代替返回 |
| Guest.get_setting/list_resource/usb_list | v1；get_setting单guest_id，其余按资源方法 | use_ovmf/is_general_vm/cpu_passthru/hyperv_enlighten布尔；ISO/USB字符串数组；磁盘size字符串，vdisk_mode数字；网卡mac/network_id/vnic_id字符串、vnic_type数字 |
| Guest.set | v1，guest_id、synovmm_ui_id及修改字段 | 内存写MiB；autorun：0不启动、1恢复原状态、2启动；官方CPU权重五档为8/64/256/512/1024；未变字段不补默认值 |
| Guest.create | v1，完整向导参数，见下节 | 原请求UUID、task_id、回显参数与最终guest_id关联；不按同名认领 |
| Guest.delete | v1，逐个guest_id | 不发送逗号合并ID；明确回执和完整清单回读分别处理 |
| Guest.Action.pwr_ctl | v1，guest_id、action=poweron/shutdown/poweroff/reboot | poweron可由Entry.Request包装；接受不等于完成 |
| Guest.Action.reset | v1，单guest_id | 强制重置不能代替普通reboot或自动降级 |
| Guest.Action.clone/move/export/check_poweron | v1候选 | 无本记录的完整行为验证，不能从名称推导参数 |
| Guest.Image.list/create/delete/edit | v2；delete用id、synovmm_ui_id | 普通删除不传blocking；工具更新专用路径才有blocking=true；不能改用公开API的image_id |
| Host.list/get、Repo.list/get | v2 | Repo.allocated_size数字，size/used字符串，不与公开Storage的MiB字段混用 |
| Network.list/get | v2，get单network_id | list含is_freeze和完整networks；get可仅含name/interfaces/guests，无ID不能伪造 |
| Network.list_avail_interface | v1 | checked与host_id/interface_id；实际返回决定可选接口 |
| Network.set | v1，network_id/name；VLAN改变才传vlan_id | external发interfaces_add/remove对象数组（host_id/interface_id），仅改名数组为空；private发host_id；不直接切换类型 |
| Network.delete | v1，单network_id | 固定拓扑/关联VM，读取失败不等于删除 |
| Cluster.get | v2 | cluster_status字符串，guest_summ/host_summ/license_summ/repo_summ对象，reasons数组 |
| Cluster.get_total_progress | v1，prefix为virtualization/virtualization_guest/virtualization_image | 按主机/任务两层对象读取原task_id，验证回显API/方法/参数及synovmm_ui_id |
| GuestProtect.Plan.list | v2 | 已观察data.protect_ids=[]为合法空清单；非空详情及get参数未验证，不猜测 |
| Log.list | v1 | offset/limit、datefrom/dateto为数字；loglevel/filter_content/sort_by=time/sort_dir=DESC为字符串，JSON模式保持各自类型 |
| Setting.General.get | v1 | Default键盘布局读取kb_layout；缺失不补en-us |

Network名称不超过127字符且不重名；VLAN为空或1–4094；保留至少一个实际接口/主机。external读取样本不证明private写行为。公开与内部读取、写入、回读不能跨契约混用。

autorun、cpu_weight读取是原生整数，不用布尔替代三态。非预设的既有正整数权重保留显示原值，不能因编辑其他字段重写成默认档。网络get不含ID时，须与按ID取得的完整list及名称、关联数量匹配；列表失败、重复身份或冻结状态不能视为可写。当前客户端的网络改名范围不等于已支持VLAN或接口拓扑编辑。

## 创建与恢复

完整参数分组：

- 身份/规格：name、desc、vcpu_num、vram_size（MiB）、cpu_weight、autorun、synovmm_ui_id。
- 存储/主机：repo_id、repo_name、host_id、repo_host_name、allocated_size（原生整数）、size（字符串）、increaseAllocatedSize。
- 磁盘/网卡：vdisks含type=add、vdisk_mode、vdisk_size（GiB）、idx、限速/unmap；vnics含type=add、network_id、mac、vnic_type、prefer_sriov；以及vdisk_struct。
- 启动/预设：bios、use_ovmf、boot_from、iso_images、usb_version、usbs、kb_layout、video_card、is_windows_vm、is_general_vm、cpu_passthru、hyperv_enlighten、cpu_pin_num、auto_switch、guest_privilege、poweron_after_create。ISO/USB空槽用unmounted，不发送系统类型单选控件名称。
- 静态预设：Windows为video_card=vga/vdisk_mode=2/vnic_type=2并启用auto_switch；Linux为vmvga/1/1且关闭；others为vga/2/2且关闭。Apple当前请求将auto_switch编码为整数0/1，不把静态预设布尔含义当成所有请求的字段类型。add模式boot_from=disk，edit额外使用old_use_ovmf。

内部Guest.get/get_setting/list的vram_size为KiB，create/set为MiB；不能直接比较未经换算的数字。存储需online/healthy且未冻结，所选ISO绑定原存储/主机；单空白盘样本及当前模板下限为10 GiB，允许网卡未连接、ISO未挂载，不据此推断其他规格都可用。

create成功回执的task_id为字符串。查询参数prefix=virtualization_guest；返回info必须匹配api=SYNO.Virtualization.Guest、method=create、version=1、prefix=virtualization_guest_create及原synovmm_ui_id和完整参数。已知task_id还须精确相同；丢回执只允许唯一匹配的原UUID及参数任务恢复接受，不能按名称认领。finish=true、success=true、data.guest_id为创建前不存在的新身份后保存，再按该编号get v2/get_setting v1/get v2核对身份与完整配置。保存新guest身份后任务被清理不妨碍只读恢复；尚无该证据时任务消失不能算成功或触发重发。

2026-09-20唯一受控Linux/UEFI样本为1 CPU、512 MiB、10 GiB空白盘，网卡断开、无自动启动且创建后关机；ISO两槽、USB四槽均为unmounted，见[环境记录](../environments/INDEX.md#2026-09-20-vmm-creation-read-observation)。该样本不证明其他预设、ISO挂载、启动、权限与失败路径通过。

## 写入结果与占用

电源/删除/设置/网络操作冻结原身份和配置，写前复查权限与当前对象，按操作身份互斥。提交后断线、超时或取消保留未知，只读查询原目标；证书/认证失败不能吞掉或换协议重试。明确拒绝不因其他客户端恰好改变状态而变成成功。

内部reboot可确认接受；官方回调未提供可证明完成的任务身份，uptime类型/单位及重启变化未得到行为证据，不能凭仍running或猜测uptime宣布完成。CPU/内存编辑要求shutdown；读取失败不补默认值，已发送字段逐项回读。支持公开基础编辑的适配器在优先级未改时可沿公开set；改动时先核对内部与公开身份/状态/基础字段，再一次内部set并按内部原字段回读，不在内部失败后重发公开写。

映像删除检查内部全部repo_id/host_id副本、健康与is_freeze状态；相同映像的不同存储副本合为一个目标，同位置重复或矛盾则拒绝。ISO占用读取完整Guest.list v2及逐项get_setting v1的iso_images，关机VM也占用；未知不能当未挂载。公开清单未提供这些字段时不猜内部占用，NAS拒绝仍为失败。删除须按原来源回读，明确接受且完整清单中原ID消失才完成；缺回执不能认领外部删除。网络改名同时核对原拓扑，删除同样要求接受回执和完整列表缺失。映像/网络操作与引用它们的创建、关联VM控制互锁；未知批次不自动续发后项。

## 控制台

只读准备固定VM身份/运行状态、权限、kb_layout和原会话，不启动VM或创建分享链接。Default键盘必须读取Setting.General.get v1，不能猜默认布局。打开窗口、WSS握手、实际VM画面是不同状态。

[官方资源观察](../environments/INDEX.md#2026-09-21-vmm-console-resource-observation)保留以下路径与证据：

- 静态页面为同源`/<alias>/webman/3rdparty/Virtualization/noVNC/vnc.html`；无别名时省略alias段。参数包括autoconnect/reconnect/path/title/app_id/kb_layout/v/app_alias；path为synovirtualization/ws/<guest-id>。
- WSS为同源`/<alias>/synovirtualization/ws/<guest-id>?app_id=<window-id>`；app_id必须与该窗口文档一致。sharing_id属于分享连接，本客户端不提供该模式。网页的autoconnect规则和别名拼接仅static，不证明真实代理部署可用。
- 已读取noVNC/app.js、app/error-handler.js、样式/SVG、app/locale/zh.json及app/sounds/bell.oga；语言JSON返回application/json，铃声当时返回application/octet-stream。客户端资源类型映射与该原始响应MIME分别记录。
- 套件图标只允许`../images/VirtualManagement_{16,24,32,48,64,72,256}.png`；32像素样本为read-verified/image/png，其余路径来自static定义。工具注入的data图标不扩大白名单。

来源和请求绑定固定VM、单窗口app_id及原会话，不接受任意网页、外部导航或通用HTTP代理。HTTP/WSS沿原证书策略，QuickConnect中继强制系统信任，不绕过错误或跟随重定向。Windows系统信任与固定指纹连接的宿主路径不同，详见[平台集成](../../../development/PLATFORM_INTEGRATION.md#虚拟机控制台)；不能宣称浏览器直连继承原生证书指纹检查。

## 证据与实现范围

方法级观察见[环境索引](../environments/INDEX.md)：历史读取、09-20单台创建、10-06静态字段、10-07电源边界、10-16空保护清单分别适用各自版本与权限，不能互相提升。其他高风险写与真实控制台仍需专用目标验证。当前五端状态只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。
