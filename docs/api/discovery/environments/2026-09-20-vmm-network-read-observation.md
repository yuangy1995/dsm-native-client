# VMM 网络管理只读核查

按环境模板建立；不按页面名称或先前会话推断设备归属。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 / 匿名设备别名 | 待归属 |
| 基线状态 / 替代旧基线 | 待归属 / none |
| 日期 | 2026-09-20 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / Update 12；本轮 Info Center 可见版本已核实 |
| 设备架构 | 未验证 |
| 连接方式 | 已登录 Chrome 官方 DSM，HTTPS QuickConnect 入口；未独立区分直连/中继 |
| 证书类别 | 未验证 |
| 账号权限类别 | 管理员；官方脚本使用的 _S("is_admin") 标记为 true，不记录账号 |

## 相关套件

| 项目组件 | 套件 | 完整版本 | 状态 |
| --- | --- | --- | --- |
| virtual-machine-manager | Virtual Machine Manager | 2.6.5-12202；官方 Package.list v2 | 当前管理页面可用；未记录未经返回的套件运行字段 |

## 证据来源与范围

- 只观察官方网络页面读取及已加载脚本；确认修改/删除候选参数、占用和保护字段。
- 不点击保存、删除、创建、开关机、网络或权限变更，不导出 HAR。
- 只记录版本、字段名和类型，不保存主机、账号、真实网络/VM 身份、名称或响应正文。
- 结束后取消未改表单、关闭本次窗口、停止监听并清除原始观察变量。

## 结论

- 2026-09-20 后续重试：重新初始化浏览器工具；准备继续同一只读范围。版本、设备归属和参数必须重新取得证据，不沿用页面标题推断。

- 同一已登录标签页两次绑定均失败；文档化 CDP 通道的 Runtime.enable 也返回未附加调试器。未能读取页面或记录请求，没有本轮新字段、版本或行为证据。
- 没有触发页面操作、安装监听或保存响应/截图；不根据旧 Fixture 猜测修改/删除参数。网络写契约切片暂待浏览器通道恢复，其他独立开发继续。

## 后续恢复后的观察

同日重新初始化后，已可读取既有用户标签页。上述失败记录保留为当时结果，
本节才是恢复后的新证据；设备与 lab-a 的关系仍未确认，不改历史环境归属。

- `read-verified`：自然页面 `SYNO.Virtualization.Network.list/get` v2、打开未改动
  编辑表单时的 `list_avail_interface` v1 成功，均使用 POST entry.cgi；后者提交单
  network_id，其参数在表单中是 JSON 引号包围的字符串。未执行 set/delete/create。
- list 响应：data.is_freeze 为布尔，networks 为数组。条目含 network_id/name/type/
  host_id 字符串，vlan_id、num_guests、num_hosts、num_interfaces、num_vinterfaces
  数字，interfaces 数组；其条目有 host_id/interface_id/ifname/ip/mask/status/type
  字符串、speed 数字、use_dhcp 布尔。真实值未保存。
- get 响应只有 name 及 interfaces/guests 数组，本轮未返回 network_id，不能伪造其
  存在。interfaces 的字段为 host_name/interface_name/status 字符串、speed_mbs/rx/tx
  数字、has_sriov 布尔；guests 含 guest_id/name/mac_addr/vinterface_names 字符串及
  running/prefer_sriov/use_vf 布尔。身份核查需结合完整 list，而非猜 get 的 ID。
- list_avail_interface 响应 data.interfaces 条目含 checked 布尔、host_id/host_name/
  interface_id/interface_name/status 字符串与 speed_mbs 数字。

`static`：已加载官方 virtualization.js 的 Network.EditWindow/OverviewPanel：

1. set 固定 v1，network_id/name；只有 VLAN 改动才提交 vlan_id，清空提交数字 0。
2. external 网络提交 interfaces_add/interfaces_remove 数组，只包含改变的选择，
   每项为 host_id/interface_id；仅改名时这两个数组为空。不能提交全量 interfaces。
3. private 网络提交选中 host_id；类型在编辑时不可修改。
4. delete 固定 v1，每次一个 network_id，不批量拼接；客户端删除确认后逐个发送。
5. 名称上限 127 且不重名；VLAN 可空或 1–4094；编辑至少保留一个所选接口/主机。
   本环境只读样本为 external，private 分支仅静态，写后副作用/错误均未行为验证。
6. 静态错误码：800 创建失败、802 删除失败、806 编辑接口被虚拟网卡占用、
   807 删除时 SR-IOV 占用、808 网络数量上限、809 VLAN 修改受 SR-IOV 占用限制、
   810 更改网络主机失败。没有触发这些错误，不将静态名称推断成完整错误响应。

同脚本高级创建静态线索：Guest create/import/import_hybrid_src 固定 v1，带
synovmm_ui_id 与 poweron_after_create；系统类型选择只触发各表单的默认值变更，
SelectOSTypeStep 继承的 getValues 是空函数，不能据 radio 名称猜测提交 mode/os_type。
OthersPanel 将固件映射到 use_ovmf 布尔，未挂载 ISO 是两个 "unmounted"，USB 空位
也用 "unmounted" 并按 max_usb_port 补齐；add 分支 boot_from 固定 disk。此处是
静态线索，不是完整创建请求或行为证据，不能推断 Windows 高级创建已经完成。

本轮只读表单已取消，控制面板及套件中心已关闭；不保存原始脚本/响应/截图/HAR。
本次 VMM 窗口也已关闭，Network/Debugger 观察停止并重置运行时内存；已捕获请求中
没有 Network/Guest set/delete/create/import/import_hybrid_src。既有用户标签页保留。
