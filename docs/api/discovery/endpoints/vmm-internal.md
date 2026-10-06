# Virtual Machine Manager 内部接口

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `vmm-internal` |
| 项目组件标识 | `virtual-machine-manager` |
| 所属范围 | Virtual Machine Manager |
| 能力名称 | VMM 网页端读取、日志与隔离写能力 |
| 分类 | `internal` |
| 操作性质 | `mixed` |
| 风险等级 | `critical` |

## 请求契约

### 2026-10-07 Apple 控制台凭据与来源边界

M7d5 复用既有 Guest 严格清单、内部 Guest.get v2 的 guest_id/name/is_online/
kb_layout；Default 布局固定调用 Setting.General.get v1，缺失不补 en-us。准备时
保留原 VM 名称与运行状态、权限拒绝、未完成电源/编辑/删除/网络/创建互锁。只读
准备不启动 VM，不创建分享链接，不自动发送输入。

Apple 三端共用非持久 WebKit 宿主；页面地址和资源使用仅限单窗口的自定义来源，
网页没有 Cookie/SID/SynoToken。HTTP 静态资源与固定 VM/app_id 的 WSS 均由原生
URLSession 与既有 DsmTLSDelegate 处理，固定证书与 QuickConnect 强制系统信任
规则一致，HTTP/WSS 均拒绝重定向。语言 JSON 只读桥限 1 MiB；启动 HTML 限
4 MiB、其他静态资源限 8 MiB，资源路径沿 2026-09-21 记录，图标仅七种尺寸。
保留 NAS CSP 并附加禁止网页直连网络、frame/object/worker、表单和来源变更。

画面单条原生消息限制 32 MiB，再按 256 KiB 有序交付；输入单条 1 MiB、网页发送
队列 4 MiB，不自动重连或重发。关闭、账号退出/切换、移动离开前台会停止资源和
连接；准备或读取的迟到结果被丢弃。独立 Mac 窗口按原 VM 绑定并随退出关闭。
现有 Apple 配置只支持主机/端口根地址，非根应用别名入口不在本片新增；策略层
有别名合成覆盖，不能当作实际门户连接证据。

本机真实 WebKit、临时证书回环 HTTPS/WSS 和合成原请求已检查；具体构建及设备
进度见移动主计划 M7d5。尚未使用真实 NAS noVNC 资源、实际 VNC 握手/画面或键鼠，
不提升任何已记录环境的 observed/read-verified/behavior-verified 等级。Windows
继续既有实现并登记相同边界，Android 只登记影响，二者没有源码、API 或存储迁移。

### 2026-10-07 映像删除与移动恢复边界

M7d4b Apple 映像删除优先使用公开 Guest.Image list/delete v1 的 image_id；仅内部
能力可用时固定 list/delete v2，删除单个 id 并携带随机 synovmm_ui_id，不发送公开
image_id，也不借官方工具更新路径加入 blocking。共享旧 Mac 协议入口保留，两种
来源共用逐项删除/接受回执/完整清单回查，异步附加字段不用于猜测新的删除任务。

内部清单要求 is_freeze、映像原 ID/name/type、全部 repo_id/host_id 和健康状态；
相同映像的不同存储副本合为一个目标，同位置重复或元数据矛盾拒绝。ISO 占用依据
完整 Guest.list v2 与逐项 get_setting v1 的 iso_images，停止的 VM 仍计为占用；
未知或不完整响应不能当作未挂载。公开清单未提供同等字段时，不猜占用或内部副本；
NAS 拒绝保留为失败，原始 ID/可选名称类型、接受回执及完整列表决定结果。

移动原生详情/单多选确认冻结当前对象，提交前重读；新增独立受保护摘要记录仅含
原账号、对象与快照摘要、来源和阶段/回执，不存名称、主机、存储位置或凭据。
恢复必须同一读取来源；已接受且完整清单消失才完成，无回执不认领外部删除。
未执行项重启停止，部分完成逐项保留，未知不重发；删除与引用该映像的创建双向
互锁。证书和登录异常立即停止；明确拒绝不追加读取来覆盖失败。

Mac 共用正确参数与实例内恢复，普通刷新只补读取已接受结果；没有新增 Mac 持久化。
Windows 既有公开删除实现及 Android 仅登记字段/结果归属影响，不改源码。
当前源码、合成及平台进度见移动主计划 M7d4b；真实 NAS 删除未执行，不提升任何
environment verification。映像导入/创建仍使用官方 VMM，不扩大现有 Mac 功能范围。

### 2026-10-07 网络改名/删除与移动恢复边界

M7d4a Apple 共用 Network.list/get v2 的严格原生字段读取与 set/delete v1。list 必须
完整、未冻结且 ID/名称唯一；关联数量和接口 ID 完整。get 仅提供名称/关联 VM 与
显示指标，不伪造 network_id；以原 list、名称和数量关联。仅改名时 external 发
interfaces_add/remove 空对象数组，private 保留原 host_id，不发未变 VLAN 或完整
接口集合。Mac 保留未改名称保存零写行为；本片不增加创建、VLAN/接口/主机编辑。

移动确认绑定原网络/拓扑/关联 VM 快照，批量先核对全选后逐项提交与回读；冻结、
变更或字段缺失阻止写入。写前持久化摘要，接受后单独保存；改名只有原 ID、新名称
和原拓扑一致才完成，删除只有接受回执加完整清单消失才完成。缺回执不认领外部
变化，不重发；未知中止后项。登录/证书错误立即停止，不追加查询。原网络、同名
改名、关联 VM 电源/编辑/删除与引用网络的创建相互保护，移动跨重启保留原记录。

Mac 共用修正但只保留仓库实例内记录，iPhone/iPad 新增独立受保护摘要文件与原生
表单/详情/逐项记录。Windows/Android 仅登记同一字段与结果归属要求，无源码修改。
只有源码、合成和目标平台测试进度，真实网络写、副作用和版本 verification 不提升；
最新构建/界面结果见移动主计划 M7d4a。映像删除已接入 M7d4b（见本页上文），控制台继续独立处理。

### 2026-10-07 创建任务与恢复实现边界

M7d3 Apple 共用内部 Guest.create v1，不再将同名清单作为创建成功。创建资源独立读取
Repo/Network/Guest.Image.list v2；存储必须 online/healthy 且未冻结，可不连接网卡、
不挂载 ISO。所选映像绑定原存储及主机，空 ISO/USB 槽仍为 unmounted，磁盘最小
10 GiB，内存写 MiB。按已记录静态预设区分 Linux 与 Windows/Other 的磁盘/网卡/
视频值及 Windows auto_switch；add 的 boot_from 固定 disk。未取得额外静态或行为
证据的 CPU 透传/Hyper-V 等字段沿既有基线，不因本次修正宣称全部预设已实测。

写前记录随机 synovmm_ui_id、完整发送参数摘要和原有 VM ID 集合摘要；create 返回
task_id 后单独记录接受。Cluster.get_total_progress v1 的 prefix=virtualization_guest，
只接受唯一匹配任务、Guest/create/1、virtualization_guest_create 与全部原参数回显。
丢回执可通过原请求 UUID 与完整参数恢复接受，不能通过名称恢复；任务消失不能认领
成功或重发。finish/success 与新 guest_id 确认后保存身份摘要，再按 get v2 /
get_setting v1 / get v2 校对基础、存储、磁盘、网卡、ISO/USB、固件与启动结果；
已经保存完成任务身份时，任务被官方清理不妨碍只读恢复原 ID。

移动新增独立受保护摘要记录，现有控制记录追加折叠大小写的名称摘要，避免跨重启
改名与创建相互绕过；保持当前开发格式，不迁移旧开发文件或 Mac 数据。创建与相同
VM 的电源/编辑/删除、所引用网络/映像的当前实例写入相互保护；外部客户端竞争和
旧资源写分支的完整未知恢复仍按相应切片处理。Mac 保留原协议入口，同一未完成
配置再次调用只读查询，不重复创建；其任务记录限仓库实例。

本片只有源码和合成证据，移动页面、目标平台验证与限制以主计划 M7d3 实时账本为准。
Windows/Android 仅同步上述契约与任务归属要求，无源码修改，不提升任何环境 verification。

### 2026-10-07 基础编辑实现边界

M7d2 Apple 共用内部 get/list v2 与 set v1：读取原 ID/名称/状态及可选原始设置，缺失
不补默认值；写入只发改动字段，CPU/内存仅 shutdown，内存读 KiB/写 MiB，autorun
0/1/2 和 CPU 五档保持原契约。移动表单传入原快照，写前重新核对完整清单和字段，
落盘成功后才发送；明确拒绝不读外部状态伪成功，丢回执或中断不重放，编辑与电源/
删除互斥。已接受记录仅在原 ID、原名称或本次改名及全部发送字段符合时完成。

iPhone/iPad 现有操作文件只追加设置摘要与阶段，记录不含字段明文；重启只读恢复，
原 ID 改名仍保护，旧账号回执只落原记录。Mac 旧入口仍使用同一共享实现，其防重复
标记限当前实例，未增加 Mac 持久化。共享合成回归已运行，目标构建/两端验证在主计划
记录；没有真实保存，不改变任何版本 verification。Windows/Android 仅同步以上语义，
没有本片源码修改。创建、磁盘/网卡/ISO 高级设置、资源及控制台不属于本片。

### 2026-10-07 电源完成条件补核

[同版本官方静态核查](../environments/2026-10-07-vmm-power-read-observation.md) 确认 pwr_ctl v1
成功回调仅恢复轮询，没有消费 task_id 或启动时间。详情字段 uptime 只作显示格式化，
未取得原生类型/单位或 reboot 时变化的行为依据。内部 reboot 可以确认请求接受，不能
只凭仍 running 或猜测 uptime 含义宣布完成；未知期间保留防重复与只读恢复。此补核
没有真实写请求，不提升任一环境的验证等级；五端均须保持上述区别。

同日 M7d1 Apple 实现已将内部电源统一为上述精确枚举、Guest.delete 固定 v1 逐个 ID，
公开/内部共用原身份、状态、回执和最终读取保护；移动新增摘要持久恢复。共享合成回归
不提升真实环境等级。证书异常立即停止后续读取；没有接受回执不认领外部变化；重启
缺少完成证据继续保留互斥。网络改名与创建已由上方 M7d4a/M7d3 修正，映像删除与控制台差距仍待后续切片。
实现与目标平台验证见[主账本](../../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-07-m7d1-虚拟机控制与移动恢复)。

### 2026-10-06 缺口补全与当时 Apple 内部兼容分支差距

[当前官方页面观察](../environments/2026-10-06-container-vmm-api-read-observation.md) 已核实
DSM 7.2.1-69057 Update 12 / VMM 2.6.5-12202，设备待归属、群组角色未单独核实。
只有 Cluster.get v2 当前成功结构为本次 `read-verified`：cluster_status 字符串，
guest_summ/host_summ/license_summ/repo_summ 对象，reasons 数组。下表为当前
virtualization.js 的 `static`，没有执行任何写入或控制台连接，也没有提升历史设备等级。

| 内部 API / 方法 | 固定版本与字段 | 结果、失败及现有实现影响 |
| --- | --- | --- |
| Guest.get/get_basic | v2，单 guest_id；get_basic 部分用途 additional=[guest_repo] | 与 list_basic 清单不同；响应字段以历史只读记录为准，不把模型默认值当响应 |
| Guest.get_setting/list_resource | get_setting v1 单 guest_id；list_resource v1 无额外参数 | 创建/编辑资源读取；内部内存读 KiB、写 MiB，缺失资源/字段只关闭依赖操作 |
| Guest.create | v1，向导合并字段及 poweron_after_create、synovmm_ui_id | 完整字段、原生数字 allocated_size、两种内存单位与 task_id 关联见下节及历史高级创建记录；现 Mac 同名清单判断不足以证明本次创建 |
| Guest.set | v1，单 guest_id、synovmm_ui_id 与改动字段 | 不随 get/list 使用 v2；未变字段不补默认值，内存写 MiB、autorun 0/1/2、CPU 五档见原记录 |
| Guest.delete | v1，逐个 guest_id | 官方逐项请求，不发送逗号拼接 ID；Apple 内部分支当前版本选择/合并参数有差距，后续修复须回归公开分支与批量计数 |
| Guest.Action.pwr_ctl | v1，guest_id、action=poweron/shutdown/poweroff/reboot | poweron 可由 Entry.Request 包装；Apple 内部 on/off 与当前定义不同。API 接受不等于电源最终状态，restart 不能仅凭仍在运行认领成功 |
| Guest.Action.reset | v1，单 guest_id | 强制重置不同于普通 reboot，不能无确认替换为降级动作 |
| Guest.Image.delete | v2，id、synovmm_ui_id | 普通删除无 blocking；官方工具更新专用路径另有 blocking=true。Apple M7d4b 已纠正内部 image_id；公开 API 的 image_id 仍沿其公开契约 |
| Network.set | v1，network_id/name；external 另发 interfaces_add/remove 对象数组，private 发 host_id；vlan_id 仅变化时发送 | 改名需保持原拓扑；Apple 当前只发 ID/name 与官方有差距。接口/主机数组来自原读取，不猜空值为允许断网 |
| Network.delete | v1，单 network_id | 按原身份/拓扑/关联 VM 检查并逐项核查完整列表；读失败不等于网络已删除 |
| Cluster.get_total_progress | v1，prefix=virtualization、virtualization_guest 或 virtualization_image | 创建按原 task_id、synovmm_ui_id、回显 API/方法/参数关联；无回执不得按同名 VM 认领 |

Guest.create 的历史已核参数按组整理如下，来源是 2026-09-20 的官方静态定义、读取与
唯一专用样本，而非本次重新创建：

- 身份/规格：name、desc、vcpu_num、vram_size（MiB）、cpu_weight、autorun、synovmm_ui_id。
- 存储/主机：repo_id、repo_name、host_id、repo_host_name、allocated_size（原生整数）、size（字符串）、increaseAllocatedSize。
- 磁盘/网卡：vdisks 中 add、vdisk_mode、vdisk_size（GiB）、idx 与限速/unmap 字段；vnics 中 add、network_id、mac、vnic_type、prefer_sriov；vdisk_struct。
- 启动/预设：bios、use_ovmf、boot_from、iso_images、usb_version、usbs、kb_layout、video_card、is_windows_vm、is_general_vm、cpu_passthru、hyperv_enlighten、cpu_pin_num、auto_switch、guest_privilege、poweron_after_create。ISO/USB 空槽使用 unmounted；不是把 OS radio 名称直接当 API 字段。

单台 Linux/UEFI 空白盘样本证明 task_id → finish/success/data.guest_id 与请求身份关联，
随后 get/get_setting 核对配置；不证明其他预设、挂载、启动、权限或失败行为。控制台的
同源固定页面、别名、窗口 app_id、Default 键盘设置与资源限制沿 2026-09-20/21 记录，
现 Apple 默认 en-us/空别名仍需后续修正，不能把当前客户端缺陷变成接口约定。

五端影响：macOS/Apple 共享兼容分支的上述差距随后独立修复并回归；iPhone/iPad 以准确
方法及原生交互接入后续 VMM；Windows 对照自身已实现任务绑定/网络/控制台及请求测试；
Android 只登记，本片无源码修改。优先公开 API，内部方法不得混用公开参数。当前文档
不改变入口授权、公开 Schema、权限、存储或发布配置；未知、证书/认证失败和明确拒绝
保留原语义，不自动重放或扩展到其他写方法。

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Virtualization.Guest`、`SYNO.Virtualization.Guest.Action`、`SYNO.Virtualization.Guest.Image`、`SYNO.Virtualization.Host`、`SYNO.Virtualization.Repo`、`SYNO.Virtualization.Network`、`SYNO.Virtualization.GuestProtect.Plan`、`SYNO.Virtualization.Log` |
| 路径 | 由 `SYNO.API.Info` 在运行时返回，不固定拼接 |
| HTTP 方法 | `POST` |
| API 版本 | 读取组客户端范围 v1-v2；`Guest.Action` 为 v1；`Log.list` 为 v1 |
| 鉴权机制 | DSM 会话 Cookie 与可选安全请求头；值不得进入 URL、日志或诊断导出 |
| 内容类型 | 由能力发现与当前 DSM 客户端适配器决定 |

当前已有资料记录的方法如下；公开 `SYNO.Virtualization.API.*` 的参数不能用于推断这些内部接口：

| API | 已记录方法与版本 | 当前边界 |
| --- | --- | --- |
| `SYNO.Virtualization.Host` | `list`、`get` v2 | 只读 |
| `SYNO.Virtualization.Guest` | `list`、`get`、`get_basic` v2；`get_setting` v1；`set` v1 静态；`delete` 待验收 | get/get_setting 已有只读观察；修改和删除没有行为验证 |
| `SYNO.Virtualization.Guest.Action` | `pwr_ctl`、`reset`、`clone`、`move`、`export`、`check_poweron` v1 | 写操作没有行为验证 |
| `SYNO.Virtualization.Guest.Image` | `list`、`create`、`delete`、`edit` v2 | 读取已记录；写操作没有行为验证 |
| `SYNO.Virtualization.Network` | `list/get` v2、`list_avail_interface` v1 只读验证；`set/delete` v1 静态 | 写后副作用仍待专用环境验证 |
| `SYNO.Virtualization.Repo` | `list`、`get` v2 | 只读 |
| `SYNO.Virtualization.GuestProtect.Plan` | `list`、`get` 兼容读取 | 只读，具体版本按运行时能力范围 |
| `SYNO.Virtualization.Log` | `list` v1 | 分页参数之外必须提交 `loglevel`、`filter_content`、`datefrom`、`dateto`、`sort_by=time`、`sort_dir=DESC` |
| `SYNO.Virtualization.Setting.General` | `get` v1 | 官方打开 VMM 时观察到请求；默认键盘布局字段 kb_layout 为静态线索，不猜缺失值 |

以下日期记录补充已观察的方法参数，不将静态写定义视为行为验证。

### 2026-09-20 网络编辑/删除与高级创建静态核查

[待归属环境](../environments/2026-09-20-vmm-network-read-observation.md) 已重新核实
DSM 7.2.1-69057 Update 12 / VMM 2.6.5-12202 / 管理员。Network.list/get v2 和
list_avail_interface v1 成功，POST entry.cgi，network_id 为 JSON 编码的单字符串。
list 返回 is_freeze 及完整 networks（network_id/name/type/host_id/vlan_id/数量/
interfaces），get 仅 name/interfaces/guests，本样本无 ID，不用缺失字段伪造身份。
可用接口列表带 checked 与 host_id/interface_id，详细字段类型见环境记录。

官方静态 set v1：network_id/name，只有更改 VLAN 才发 vlan_id（空值归 0）；
external 用 interfaces_add/interfaces_remove 的增量对象数组，每项 host_id/
interface_id，改名时为空数组；private 用 host_id，不允许直接切换网络类型。
delete v1 单个 network_id。名称 127 字符且不重名；VLAN 空或 1–4094；至少一个
接口/主机。当前只读 external 样本不证明 private 或任何写入行为。
Guest 创建/导入静态也固定 v1；ISO/USB 空槽为 unmounted。系统类型 radio 不直接
成为请求字段。完整创建字段、写后证明、权限/占用错误仍需独立实现和验证。

五端影响：Windows 网络修改/删除及高级创建依此新增适配；macOS 共享内部网络
写不能跟随 list 的 v2，创建空槽/版本同类问题需修；iPhone/iPad 仍限既有只读
VMM 范围，不新增网络写；Android 只记录接口影响，本波不修改代码。

### Windows 网络改名/删除实现

沿 Mac 现有 name-only 更新及多选删除结果，Windows 已接内部 list/get v2 的严格
完整读取；get 不返回 ID，需匹配已按唯一 ID/名称核对的 list 目标及关联 VM 数量。
写入前重新核对全选集合，逐项再核对名称、类型、VLAN、host/interface ID 和关联
VM 身份/运行状态，不以公开摘要或显示默认值代替。is_freeze 阻止写入。
改名仅发 set v1 的 network_id/name：external 的 interfaces_add/remove 均为空数组，
private 保持原 host_id；删除为 delete v1 单 ID。写后只读相同内部 list，改名同时
核对原拓扑，删除核对完整清单缺失；明确拒绝不被其他客户端的结果覆盖。
结果未知按现有 API 客户端及会话范围保留内存恢复，重复请求只核查，关闭只取消
本地等待，不撤回已提交请求。关联 VM 电源/设置/删除及引用网络的创建相互保护。
原生确认显示网络数与关联 VM 数，删除可能中断连接，不保证自动重连或可撤销。
新增合成 fixture 为 vmm/update-network/synthetic-external-name/request.json，HTTP
回归比对实际编码。真实写效果未验证，iPhone/iPad/Android 不增加写能力；VLAN/
接口拓扑编辑不属于 Mac 当前 name-only 基线，不能把该实现说成所有官方网络编辑。

## 响应与错误

当前只依赖 DSM 响应的稳定外层：

```json
{
  "success": true,
  "data": {}
}
```

- 各读取分区按能力独立解析；失败必须显示不可用状态，不把错误伪装成空列表。
- 能力缺失、版本不覆盖或字段变化时关闭相应内部读取或写入，不猜测参数。
- 登录失效、证书变化和权限错误应保留其原始语义。
- 写请求若在提交后断线、超时或取消，结果未知，不得自动重放或仅凭外层成功报告完成。

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `read-verified` | `Guest`、`Guest.Image`、`Host`、`Repo`、`Network`、`GuestProtect.Plan` 客户端范围 v1-v2；`Guest.Action` v1；`Log.list` v1 | `degraded`；VMM `2.6.5-12202`，创建、修改、网络写和删除未形成行为验证结论 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md`、`docs/compatibility/DSM_COMPATIBILITY_MATRIX.md` |

读取方法由当前官方 VMM 网页前端静态代码与 `SYNO.API.Info` 交叉确认；`read-verified` 不提升任何写方法的证据等级。

## 能力探测与降级

- 默认优先使用公开 `SYNO.Virtualization.API.*` v1。
- 内部调用前必须由 `SYNO.API.Info` 确认 API、路径和版本范围。
- 内部读取失败时显示明确不可用状态；不以公开 API 参数拼装内部请求。
- 未记录的新 DSM build 或 VMM 版本默认关闭全部内部写能力。
- 网络 `set/delete`、虚拟机和镜像的创建、修改、删除及动作只有在专用目标完成行为验证后才能进入发布兼容范围。

## 客户端与测试

2026-09-20 [待归属官方页面核查](../environments/2026-09-20-vmm-parity-read-observation.md)
确认 DSM 7.2.1-69057 Update 12、VMM 2.6.5-12202、管理员。API.Info 声明 Guest
v1–v2、entry.cgi、JSON；自然 Guest.get v2 和编辑窗口 Guest.get_setting v1 读取成功，
后者单 guest_id。autorun/cpu_weight 是原生数字，不按布尔或字符串转换。官方脚本
Guest.set 固定 v1，编辑参数带 guest_id/synovmm_ui_id 及改动字段；保存未执行。

静态设置值：autorun 0=不启动、1=恢复原状态、2=启动；cpu_weight 五档 8、64、256、
512、1024。Apple 创建旧 bool=true 原先误发 1，已改为三态枚举并将兼容 true 映射 2；
Mac 创建/编辑用三态，CPU 选择五档，高档不再被旧 <=512 校验拒绝。未知读取保持未知，
非预设的既有原生整数权重只展示原值，不因其他编辑重写。iPhone/iPad 仅同步只读
三态显示；公开只读摘要也接受 0/1/2，不再接受 bool 替代。Swift/目标构建尚未运行。

对应合成请求：contracts/request-fixtures/vmm/update-guest/synthetic-startup-priority/request.json，
固定 JSON、set v1、单 guest_id、synovmm_ui_id、cpu_weight=1024、autorun=2；
RequestFixtureContractTests 新增重放断言，随机 UI 身份检查 UUID 后再替换占位值。
证据仍为 sourceReviewed，不是观察到的写请求或行为验证。

控制台静态路径为同源 /webman/3rdparty/Virtualization/noVNC/vnc.html；参数包括
autoconnect/reconnect/path/title/app_id/kb_layout/v/app_alias，path 指向
synovirtualization/ws/<guest-id>。Default 键盘布局取套件设置；重写入口需保留应用
别名路径。未连接控制台、未读取会话凭据，现有 Mac 默认 en-us/省略版本的差距已
记录，Windows 隔离浏览组件和认证/证书/导航边界仍未完成，不据静态路径开放入口。

该观察未归属 lab-a，不增加历史环境的行为等级；写契约只有 static，读响应只证明
当前版本/账号读取成功。Android 未修改；Windows 公开启动三态已正确，内部优先级
编辑仍未接。本次不新增公开请求 Schema、持久化或权限。

2026-09-17 macOS 共享实现补齐 updateVirtualMachine 已发送字段的最终核查：使用既有
内部 Guest.list 而非展示快照或公开清单，按原 guest_id 唯一目标比较 name/desc/
vcpu_num/vram_size/cpu_weight/autorun，保留空说明和原生数值类型。没有字段时不填
false/0；内部写回读不以公开 autorun 语义替代。该改动只校验现有发送值，不确认内部
自动启动开关的实际语义；本轮浏览器连接失败，无新增观察/读验证。新增 4 个 Swift
测试待 Mac 执行，生产写能力不因源码修复开放。其他平台不改接口或存储，Windows
继续公开三态字段；iPhone/iPad 不新增编辑入口，Android 仅评估影响。

2026-09-17 Windows 既有读取纠正：公开五分区仍固定 v1，内部保护范围仍为 v1-v2、
日志 v1；能力元数据需名称一致、正向有效版本范围及 FORM/JSON 格式。内部日志的
loglevel/filter_content/sort_by/sort_dir 在 JSON 模式下按字符串编码，offset/limit/
datefrom/dateto 保持数字，不混用公开接口参数。去除所有返回数组的客户端 200 项
截断，保护规则三组不再争用该额度；格式错误和冲突的已知根容器明确失败，不被另一
空数组掩盖。日志仍只有已记录的首批 limit=1000 请求，不声称已经读取完整历史。
新增真实 HTTP 合成回归覆盖请求格式、完整响应/尾部错误、能力关闭和公开分区隔离；
没有增加内部回退、写方法、公开接口或真实环境证据，其他四端无源码/契约迁移。

- 初次独立记录仅迁移既有兼容条目；后续 Windows 实现修正见本节日期说明。
- 兼容索引：`contracts/private-api/compatibility.json`。
- 事实来源：`docs/api/DSM_WEB_API_REFERENCE_ZH.md` 与 `docs/compatibility/DSM_COMPATIBILITY_MATRIX.md`。
- 后续 fixture 必须彻底脱敏虚拟机、主机、网络、存储、镜像、日志、地址和路径信息。

## 安全与副作用

2026-09-20 Windows 优先级沿用上述 get v2 / set v1，get 原始 guest_id/name/desc/
vcpu_num/vram_size/autorun/is_online/cpu_weight 必须与公开基础快照一致才提供可编辑
权重。失败降级为仅基础设置，认证/证书/取消仍抛出。优先级未改时继续公开 set；
改动时将本次字段一次性映射到内部 name/desc 等键并带 synovmm_ui_id，随后只用
内部 get 原生字段核查。不存在两次写或内部失败后自动重放公开写的降级。
共用设置请求身份、模块互斥、确认和未知恢复，服务端权限拒绝明确失败。用户主动
验证入口按既有授权和实际能力开放；不把该源码/合成进度标作行为验证或发布兼容。
复用共享 synthetic-startup-priority fixture，Windows JSON 请求已自动回归。

- VMM 数据可能包含虚拟机名称、网络地址、存储位置、镜像名称、日志正文和远程控制信息，不得写入普通日志或提交原始响应。
- 电源、重置、创建、修改、删除、克隆、迁移、导出和网络变更均为高风险写操作；当前未形成完整行为验证，不得据源码进度宣称发布兼容。用户已授权的主动验证入口按总控计划保留实际能力、确认、权限拒绝、互锁和回读门禁，不授权 Agent 执行真实危险写入。
- 后续开放写能力时必须具备明确确认、权限检查、稳定目标识别、防重复提交和写后最终状态复查。
- 远程控制地址生成逻辑已有记录，但本端点记录不保存真实地址、会话值或连接令牌。

## 未验证事项

2026-09-21 [控制台静态资源观察](../environments/2026-09-21-vmm-console-resource-observation.md)
补齐实际脚本规则：连接为同源 /<app_alias>/synovirtualization/ws/<guest-id>
并追加同一窗口 app_id；无别名时省略该路径段，分享参数不在本客户端范围。
Windows 托管策略现按此规则绑定 URI，仍拒绝其他窗口、其他别名与跨源目标。
语言 JSON 使用 XHR，IPv6 下显式 CSP 源不兼容，故最终保持 connect-src none，
经现有受限消息桥读取同源语言白名单。单文件 1 MiB、并发 4、无网页凭据或通用
HTTP 转发；语言失败显示原生错误并关闭会话。实际静态资源路径/MIME 已读取，
真实别名门户和 VNC 画面仍待用户验证，未据此提升历史行为兼容等级。

2026-09-20 高级创建续查的只读字段见
[高级创建观察](../environments/2026-09-20-vmm-creation-read-observation.md)。官方表单
get_setting v1 成功返回 use_ovmf 布尔、iso_images 字符串数组、vdisks 中 size
字符串及 vdisk_mode 数字、vnics 中 mac/network_id/vnic_id 字符串及 vnic_type
数字。Repo.list v2 的 allocated_size 是数字，size/used 是字符串。静态创建
预设及 add/edit 参数差异已记录，不能混入公开 Guest.create。当前任务聚合没有
创建任务样本；专用创建尚未提交，用户已批准 1 GiB 规格但向导最少 10 GiB，
该规格变更随后已获授权，最新受控创建结果见同一观察记录的“后续受控创建结果”。
本样本 Guest.create v1 的 task_id 经 Cluster.get_total_progress v1 精确关联到
finish/success/data.guest_id，并核对 info.api/method/version/prefix 与
info.param.synovmm_ui_id；创建后只读确认关机及授权规格。仅该 Linux/UEFI/空白盘
样本形成行为证据，不外推其他预设、挂载、启动或历史设备兼容等级。

内部 Guest.get/list v2、get_setting v1 的 vram_size 读取单位为 KiB；内部
create/set 写入单位为 MiB（本次 create 观察与官方编辑器静态映射），公开 API
仍按官方 MiB 处理。Windows 正规化内部读取后再与公开基础字段/期望值比较；
Mac 按公开/内部来源分别换算，内部保存核查换算单位，allocated_size 发送原生
整数而非字符串。Apple 源码/测试已同步但未在本机执行 Swift/Mac 构建。
合成请求 fixture：contracts/request-fixtures/vmm/create-guest/synthetic-internal-advanced/request.json。

2026-09-21 Windows 高级空白盘创建已沿该契约接线：不复用公开 create 参数，
使用内部 create v1 和 Cluster.get_total_progress v1，task_id、请求 UUID 与
完整回显参数共同绑定结果。丢回执仅按该 UUID 核查；不按名称认领，不重新创建。
获得可信 guest_id 后核对 get/get_setting 的完整配置，再进入原有开机流程；
只读恢复不会自动发起开机。默认公开路径与高级路径共享原请求号/互斥/待办，
高级 ISO 引用也参与映像删除互锁。x64/ARM64 构建和双语原生合成验证通过，
当前 NAS 的所需版本已只读复验；其他预设及 App 完整真实创建仍待用户验证。

2026-09-20 Windows 控制台已接固定同源 noVNC 地址、单次凭据安装和独立窗口；
系统信任连接可按能力主动验证，尚未连接真实 VNC。准备时公开 Guest.get v1 与内部
Guest.get v2 必须匹配同一运行中身份/名称；Default 键盘布局再读 General.get v1，
缺失不补 en-us。页面只通过既有 HTTP/证书上下文读取，HTML 4 MiB 上限只约束启动
文档，不约束 VNC 画面流；拒绝重定向、非 HTML、跨配置/来源/应用别名读取。

URI 不含 SID/SynoToken，Cookie 只允许对固定页面安装一次；会话关闭取消读取，
迟到文档清零，文档/凭据对象不序列化。返回头保留服务器 CSP 并附加精确 HTTPS/WSS
connect-src、禁 frame/object/worker、no-store/no-referrer。实际 WebView2 合成
回归已验证头生效、私密模式与 Cookie 属性、外部导航/弹窗阻断及关闭清理。缓存
目录只在对应浏览进程退出后删除；不影响其他窗口目录，不用策略单元测试替代
真实组件测试，也不将合成页面显示等同真实 VM 键鼠/画面验收。

WebView2 普通请求事件不覆盖全部 WebSocket，证书错误事件只在验证失败时触发，
不能据此声称继承已固定指纹。系统信任连接（或强制系统信任的 QuickConnect
中继）保留浏览器直连。固定指纹根路径连接改为原生读取资源与 WSS，复用原
HttpClient/证书上下文，经受限二进制消息桥连接网页；不向网页安装 Cookie，
文档 CSP connect-src 为 none，不提供忽略证书回退。资源限同源 noVNC 静态目录和
HTML 明确引用的七种套件图标，语言 JSON 另走受限消息桥，
消息绑定固定页面、单窗口上下文及连接编号，关闭销毁连接。应用别名 socket
路径已由同日官方脚本确认，实际部署仍待验。已有本机 TLS 和真实 WebView2 合成证据，真实 NAS noVNC
资源、画面和键鼠尚属 PENDING_USER_VALIDATION；不能外推真实 VNC 已验证。
依据：[Microsoft WinUI WebView2](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2)、
[Microsoft 非 HTTP 请求事件说明](https://github.com/MicrosoftEdge/WebView2Feedback/blob/main/specs/WebResourceRequested-CustomScheme.md)
和本地 SDK 1.0.3719.77 ServerCertificateErrorDetected 文档。

- 当前未读取的响应字段、具体权限组合与失败码；不能由静态表单推定服务端完整 Schema。
- 网络 set/delete 的版本、参数已由静态核实；写后状态与副作用仍待专用环境验证。
- 除历史单台受控创建样本外的虚拟机/映像创建、修改、删除及生命周期行为；新增静态参数不提升行为证据。
- 不同 DSM build、VMM 版本、账号权限与连接方式下的兼容性。
