# VMM 高级创建只读核查与专用测试样本

按环境模板建立，设备仍待归属，不以版本相同推断为 lab-a。

| 字段 | 值 |
| --- | --- |
| 日期 | 2026-09-20 |
| 匿名设备 / 基线状态 / 替代基线 | 待归属 / 待归属 / none |
| DSM / build / Update | 同日网络观察已核实 7.2.1 / 69057 / Update 12；本轮有变化则另记 |
| 套件 | Virtual Machine Manager（Virtualization），同日已核实 2.6.5-12202 |
| 架构 / 证书类别 | 未独立核实 / 未独立核实 |
| 连接方式 / 权限 | 既有 Chrome 官方 DSM，HTTPS QuickConnect 入口 / 同日已核实管理员 |

## 范围

同日后续授权：用户明确允许新建一台专用验证虚拟机，1 CPU、512 MiB 内存、
1 GiB 空白磁盘、网卡断开、不挂 ISO、不启动；不修改既有虚拟机。仅该创建写
进入本次验证范围，删除测试机仍需另行确认，不以此前一般授权扩大写入范围。
验证完成只保留字段/类型/对应关系，测试 VM 名称和实际 ID 不进入仓库。

用户随后明确授权不涉及真实数据的测试改动，因此本次专用测试机可按官方向导
最小值使用 10 GiB 磁盘。仍保持 1 CPU、512 MiB、网卡断开、无 ISO、不启动，
不改既有 VM 或真实文件；该授权不解除永久删除的操作时确认要求。

初始只读阶段只查看未改动的虚拟机编辑表单及已经加载的官方脚本，观察 get/get_setting/
list_resource 读取；核对系统预设、固件、ISO 及创建回执的证据边界。
不提交创建/保存/电源/删除，不启动导入、上传或挂载，不导出原始响应/脚本/HAR。
只保存字段名、类型、枚举与版本，不保存名称、MAC、路径、主机、账号或会话值。

## 结论

同日续查：映像导入已独立完成后，重新读取当前浏览器清单，官方 DSM 标签仍存在。
本次继续沿上述只读范围尝试附加；版本/权限若未重新取得，不把旧观察提升为
本次验证，也不读取浏览器凭据文件或借其他调试通道绕过工具连接限制。

本次附加成功。未改动编辑表单的自然复合请求确认 Guest.get_setting v1（单
guest_id）、Guest.Image.list v2、Guest.list_resource v1、Guest.usb_list v1、
Host.list v2 和 Repo.list v2 成功。只提取字段/类型，没有保存原响应。get_setting
包含 use_ovmf/is_general_vm/cpu_passthru/hyperv_enlighten 布尔、iso_images/usbs
字符串数组、boot_from/video_card/kb_layout 字符串；vdisks 的 size 为字符串，
vdisk_mode 为数字；vnics 的 mac/network_id/vnic_id 为字符串、vnic_type 为数字。
Repo.list 的 allocated_size 为数字，size/used 为字符串；不能把这些响应类型
与公开 Storage 的 MiB 字段互换。未修改的编辑窗口已取消。

官方静态预设表：Windows 为 video=vga、vdisk_mode=2、vnic_type=2、auto_switch=true；
Linux 为 vmvga/1/1/false；others 为 vga/2/2/false。CPU/内存只是预设，用户可另改。
OthersPanel.getValues 在 add 模式发送 is_windows_vm，并固定 boot_from=disk；
use_ovmf 来自 legacy/uefi，空 ISO/USB 槽为 unmounted；edit 额外发送 old_use_ovmf。
这些是静态发送线索，不提升为已观察写请求。

Cluster.get_total_progress v1 自然读取成功，但当前无 guest 创建任务。静态界面
按主机/任务分组读取 info.prefix、info.param、finish、success、data.guest_id，
创建 callback 不消费回执。尚不能据此猜测创建回执或新字段。受控创建向导已按
授权填写 1 CPU/512 MiB/1 GiB，官方磁盘页拒绝并显示最小 10 GiB；尚未提交，
已单独请求用户确认扩大至 10 GiB，其余约束不变。没有绕过表单最小值校验。

公开 Guest.create 文档没有系统类型、固件和启动介质参数，不能把内部字段当成
公开 API 字段，也不能在未知保存能力下猜测创建后设置。
初次失败阶段两次读取标签页及一次按文档重新 claim 用户标签页均返回调试器未附加；
未取得页面或配置响应，没有新的 read-verified 字段。未安装监听、未触发任何
页面动作，不沿用早前观察宣称本次成功；其他独立验证继续。

## 后续受控创建结果

授权后旧标签再次无法附加；同一 Chrome 新标签通过既有登录会话恢复。创建前
列表核实没有专用测试机，最终摘要逐项确认 1 CPU、512 MiB、10 GiB 空白盘、
Linux 预设、UEFI、网卡未连接、两个 ISO 槽未挂载、自动启动关闭、创建后不开机，
未给其他用户/群组增加权限。仅提交一次 Guest.create v1（JSON 参数的 POST）。
最终新增单台测试 VM，状态关机；原 VM 未修改。测试机暂保留，不自动删除。

- `behavior-verified`（仅本样本）：Guest.create v1 返回 success=true，data.task_id
  为字符串。不得将公开 Task.Info 的回执结构用于此内部任务。
- `read-verified`：自然 Cluster.get_total_progress v1 响应按主机/任务 ID 两层
  对象组织；与上述 task_id 精确匹配的记录先 finish=false，再 finish=true，
  success=true、data.progress=100、data.guest_id 为字符串。info.api/method/version
  为本次 Guest/create/1，info.prefix=virtualization_guest_create；info.param 完整
  回显本次参数，synovmm_ui_id 与请求一致。auto_remove=false；官方页面随后自动
  清理已完成任务，客户端不得把任务消失视为创建成功，也不得因此重发。
- `read-verified`：按任务 guest_id 的 Guest.get v2 和 get_setting v1 均匹配新建
  测试机；核实关机、1 CPU、UEFI、10 GiB 磁盘、断网、未挂载 ISO、无自动启动。
  编辑窗口仅打开读取后取消，没有保存修改。
- 请求实际类型：allocated_size 为 JSON 数字、size 为字符串；vdisks[*].vdisk_size
  的 10 表示 GiB，而 vram_size 的 512 表示 MiB。空 ISO 槽有 2 项、USB 槽有 4 项，
  值均为 unmounted；poweron_after_create=false。
- 新发现的单位缺陷：同一 512 MiB 测试机的内部 Guest.get v2、get_setting v1
  返回 vram_size=524288；经官方请求封装补做 Guest.list v2 只读调用，仅提取测试机
  字段，也返回 524288。这三种内部读取使用 KiB；内部 create/set 参数仍使用 MiB
  （create 为本次实际请求，set 为官方 SpecPanel.getValues 的静态映射）。不能与
  公开 API 的 MiB 读取混用。Windows 内部优先级读取/核查及 Mac 内部列表显示/
  保存核查受影响，已进入同类修复。

彻底合成的参数样本为 contracts/request-fixtures/vmm/create-guest/synthetic-internal-advanced/request.json。
没有写出原始响应、HAR、脚本、截图、实际 VM/任务/主机/存储身份、MAC、账号或凭据。
本样本不证明 Windows App 已完成高级创建，也不证明 Windows/Other 预设、ISO
挂载、启动、其他固件或其他 DSM/VMM 版本已验收；设备归属仍待核实，历史 lab-a
基线不升级。后续所有不涉及真实数据的隔离测试已获用户授权，永久删除等工具
强制操作时确认仍单独执行。

## 2026-09-21 只读启用条件复验

通过既有官方请求封装只读查询 API.Info 与 Guest.Image.list v2，不新增或修改 VM。
公共 Guest/Storage/Task.Info 的 min/max 均为 1；内部 Guest/Repo/Guest.Image 和
Cluster 的 min/max 为 1/2，全部声明 JSON。当前 ISO 条目的状态为 online/healthy，
id/name/repo_id/host_id 均为非空字符串，is_freeze 为布尔。只返回状态和类型，
不记录用户映像名称/身份或响应正文。这验证当前高级入口所需版本和读取条件，
不等于 Windows App 的创建/开机行为已经在真实 NAS 验收。
