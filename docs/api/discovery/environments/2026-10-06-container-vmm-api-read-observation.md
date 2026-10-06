# 容器与 VMM API 缺口只读核查

> 2026-10-06 用户明确授权对照 macOS 实现与 Chrome 已登录官方页面补齐接口文档。本次只读发现，不以表单操作代替写入验证。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属；不凭相同版本推定为历史 lab-a |
| 匿名设备别名 | 待核实与历史设备关系 |
| 基线状态 | 待归属观察，不新增 current 基线 |
| 替代的旧基线 | none；尚未确认升级关系 |
| 发现日期 | 2026-10-06 |
| DSM 版本 | 7.2.1；官方信息中心当前显示 |
| DSM build | 69057 |
| Update | 12 |
| 设备架构类别 | 未知；本次仅在兼容必要时核实 |
| 连接方式 | Chrome 既有 HTTPS QuickConnect 直连域名；仅记录连接类别 |
| 证书类别 | 尚未独立核实 |
| 账号权限类别 | 已登录且可见控制面板与套件中心管理视图；群组角色未独立核实 |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| `container-manager` | Container Manager | 24.0.2-1535 | 正在运行 | 官方套件中心“安装的版本”当前显示，应用已打开 |
| `virtual-machine-manager` | Virtual Machine Manager | 2.6.5-12202 | 正在运行 | 官方套件中心“安装的版本”当前显示，既有应用窗口存在；未连接任何 VM 控制台 |

## 证据来源

- [ ] `SYNO.API.Info` 脱敏能力发现。
- [x] 已登录官方网页的只读网络请求。
- [ ] 官方公开文档。
- [x] 官方前端静态资源中的候选接口。
- [ ] 客户端自动化契约测试。
- [ ] 专用测试环境的受控行为验证。

相关文档或 fixture：

- `docs/api/discovery/endpoints/container-manager-internal.md`
- `docs/api/discovery/endpoints/vmm-internal.md`
- `apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift`
- `apple/Apps/DsmMac/Sources/ServiceManagementView.swift`

## 发现范围

- 本次目标：网络创建结果字段、容器创建/编辑与项目写缺口，以及 VMM 创建/编辑/资源/控制台已有实现所需文档；先核对 Mac 与既有记录，再观察官方必要只读请求和静态定义。
- 明确不检查：真实容器环境变量、用户文件/路径/日志正文、VM 画面；不提交创建、删除、启停、安装、网络或权限改变。
- 当前限制：浏览器标签连接超时，改用 Chrome 原生界面与其开发者工具。只观察官方页面产生的只读 XHR，在内存保留 API/方法/版本、参数名及响应字段类型；读取官方已加载的同源静态脚本，不存响应值或脚本文件。设备与历史 lab-a 的关系尚未确认。

## 安全检查

- [x] 未保存 Cookie、SID、SynoToken、DID、OTP 或密码。
- [x] 未保存 NAS 地址、IP、QuickConnect ID、序列号或证书指纹。
- [x] 未保存用户名、共享名、路径、文件名、消息、日志正文或其他真实用户数据。
- [x] 未执行未获授权的写操作。
- [x] 没有导出 HAR、原始响应、浏览器截图或官方脚本文件。已恢复临时 XHR 观察方法，删除全部内存观察数据/脚本文本并关闭本次 DevTools；控制台确认观察器已不存在。

## 结论

- 已确认：Mac 已有 VMM 创建、编辑、启停/删除、网络编辑/删除、映像删除与控制台入口；容器创建/编辑/项目写尚未形成现有 Mac 实现。这里只是本仓库源码事实，不是官方静态发现。
- 未验证：全部新增写行为、跨账号/版本、真实取消/并发/权限失败和部分字段。源码与官方静态请求定义分别记录，静态写回执处理不等于实际回执已观察。
- 需要在其他版本或权限下复验：每个新增证据仅适用本次实际读取的版本和权限，不推广到其他环境。

## 当前官方页面读取证据

本节均为本次 `read-verified`，只适用于上述版本及当前已登录会话。请求路径只记录相对路径；参数列不含认证字段。

| API / 方法 / 版本 | 官方请求参数与路径 | 成功响应结构 |
| --- | --- | --- |
| `SYNO.Docker.Network.list` v1 | 无额外参数；观察到 `/webapi/entry.cgi` 与 `/webapi/entry.cgi/SYNO.Docker.Network` 两种路由 | `data.network:array`；元素 `containers:array`、`driver/name/id/gateway/iprange/subnet:string`、`enable_ipv6:boolean`。当前样本没有 IPv6 地址和 IP 伪装结果字段 |
| `SYNO.Docker.Container.list` v1 | `limit/offset/type`；`/webapi/entry.cgi`；值另由官方静态定义核对为 -1/0/all | `containers:array`，`limit/offset/total:number`；元素 `id/name/image/Image/ImageID/cmd/status/up_status:string`，`created:number`，`State/Labels/NetworkSettings:object`，`is_ddsm/is_package/enable_service_portal/exporting:boolean`；样本 `finish_time/services/up_time:null`。不读取或记录嵌套用户配置值 |
| `SYNO.Docker.Project.list` v1 | 无额外参数；`/webapi/entry.cgi/SYNO.Docker.Project` | 当前成功 data 为 `{}`；非空元素结构仍只来自官方静态代码，不能提升为当前非空读取验证 |
| `SYNO.Docker.Image.list` v1 | `limit/offset/show_dsm`；`/webapi/entry.cgi/SYNO.Docker.Image`；参数精确值沿既有记录，本次只保存结构 | `images:array`、`limit/offset/total:number`；元素 `id/repository/description/digest/remote_digest:string`、`created/size/virtual_size:number`、`tags:array`、`upgradable:boolean` |
| `SYNO.Docker.Registry.get` v1 | `limit/offset`；`/webapi/entry.cgi/SYNO.Docker.Registry` | `registries:array`、`using:string`、`offset/total:number`；不保存仓库地址 |
| `SYNO.Virtualization.Cluster.get` v2 | 无额外参数；`/webapi/entry.cgi`；既有后台页面产生 | `cluster_status:string`、`guest_summ/host_summ/license_summ/repo_summ:object`、`reasons:array`；不保存内部资源详情 |

## 官方静态创建、编辑与项目定义

已从 DOM 中确认并只读取得 `/webman/3rdparty/ContainerManager/MainVue.js`；它是当前已安装官方套件的主模块。下列均为 `static`，未发送写请求。混淆函数名/偏移只用于现场定位，不作为客户端契约。

- `Container.create` v1：普通向导参数 `is_run_instantly:boolean` 与 `profile:object`。共享转换会把 UI 的 `port_bindings[].type=tcp_udp` 拆成相同端口的 tcp、udp 两项，不将 tcp_udp 直接发送。向导成功处理读取 `services`、`start_dependent_container`、`dependent_container`；真实响应尚未观察。
- 创建 profile 初值：`name=""`、`image` 由选择传入，`cpu_priority=0`、`memory_limit=0`，`privileged=false`，`port_bindings=[]`、`volume_bindings=[]`，`env_variables` 来自映像 env 或空数组，`network=[{name:"bridge",driver:"bridge"}]`、`use_host_network=false`、`cmd=""`。这些初值不是服务端完整 Schema；高级字段如下。
- `Container.get` v1 以 `name` 寻址；`Container.set` v1 提交原 `name`、`edit_name=profile.name` 和经过同一端口转换的 `profile`。能力编辑另有 `name/edit_name` 与 `profile={privileged:false,CapAdd,CapDrop}`；不默认启用特权或扩大访问。
- `Project.create` v1 直接发送项目 profile；成功处理读取 `id/name/enable_service_portal/services`。`Project.get/delete` v1 提交 `id`，`Project.update` v1 提交 `id` 和明确更新字段；完整静态字段及后续构建见下表，未发送写请求。
- `Network.list_container` v1 静态参数 `limit=-1/offset=0`；`Network.set` v1 静态参数 `networkName` 和所选容器名称数组 `containers`。这属于连接关系修改，区别于本片网络创建/删除；尚未实现或行为验证，不借文档核查自动修改网络。
- `Network.remove` v1 静态错误处理读取 `errors.failed[].network`；这只补充官方失败展示结构，不能将成功响应与错误包中的 failed 混为一谈。现共享单项删除对明确错误仍停止，不认领随后外部消失。

| 容器 profile 字段 | 官方静态类型、转换与边界 |
| --- | --- |
| `cpu_priority/memory_limit` | 资源限制关闭时均发 0；开启时 CPU 选项为 10/50/90，内存界面 MB 乘 `1024*1024` 后发送字节数；界面最低 6 MB，上限来自当前系统资源。不能与 VMM 的 MiB 写入单位混用 |
| `port_bindings` | 对象数组，元素 `host_port:number/container_port:number/type:string`；主机端口空输入转 0，容器端口转数字。`tcp_udp` 仅是 UI 合并选项，提交拆成 tcp、udp 两项；服务门户专用端口不混入普通映射 |
| `volume_bindings` | 对象数组，元素 `host_volume_file/mount_point/type:string`、`is_directory:boolean`；默认 type 为 rw。真实宿主机路径和挂载内容未读取；字段存在不表示任意目录都获授权 |
| `env_variables` | `{key:string,value:string}[]`；没有读取任何容器实际变量或值 |
| `network/use_host_network` | 普通网络为所选 `{name,driver}` 数组；host 模式发送 `use_host_network=true` 且 `network=[]`。是否可切换及后果仍需独立验证 |
| `enable_restart_policy` | 开关布尔；只确认官方字段，不把它解释为任意 Docker 原生重启策略枚举 |
| `privileged/CapAdd/CapDrop` | privileged 为布尔，能力选择为数组；开启 privileged 时官方提交空 CapAdd/CapDrop。提升权限具有独立风险，不因发现字段自动启用 |
| `enable_service_portal/service_portals` | 布尔及 `{port,protocol}` 数组；官方依赖 Web Station 状态。端口在界面路径中可能为数字或输入值，最终服务端类型未观察，不固化为已验证 Schema |

| 项目方法 v1 | 已确认的静态请求与响应消费 |
| --- | --- |
| `create` | 直接参数 `name/content/share_path:string`、`enable_service_portal:boolean`、`service_portal_name:string`、`service_portal_port:number`、`service_portal_protocol:string`；默认端口 0。content 是 Compose 文本。`is_run_instantly` 是本地向导选项，不是这个 create profile 字段；成功后该选项另行打开 `build_stream`，不能把 create 接受等同容器已运行 |
| `get_share_info` | 参数 `path`；消费 `is_docker_compose_yml_exist/content/compose_path`。这是路径/文件内容读取候选，本次未主动读取用户文件 |
| `get` | 参数 `id`；官方状态模型消费 `id/name/path/share_path/content/schema/containerIds/status/created_at/updated_at/enable_service_portal/service_portal_name/service_portal_port/service_portal_protocol/is_package`。模型默认类型不是实际响应类型证明；本次 Project.list 是空对象 |
| `update` | Compose 编辑只追加 `content`；门户编辑追加 `enable_service_portal/service_portal_name/service_portal_port/service_portal_protocol`；两条路径均由适配器加入原 `id`。保存 Compose 后单独询问是否构建，不隐式把更新视为构建成功 |
| `build_stream/start_stream/stop_stream/restart_stream/clean_stream` | 每个方法只传 `id`，前端以 text 响应和下载进度处理；不能按普通 `{success,data}` JSON 成功模型猜测终态。原始输出可能含路径与日志，本次没有读取 |
| `delete/log` | 参数 `id`；delete 为写，log 为读取。官方托管项目 `is_package` 限制与状态限制独立于名称，不以按钮可见证明权限 |

## VMM 新静态核对与已知源码差距

本次读取当前官方 `/webman/3rdparty/Virtualization/virtualization.js`，没有执行表中写方法，
没有连接控制台。过去记录的只读/受控创建结果仍保留原日期和证据范围，不归入本次观察。

| API / 方法 | 版本与参数 | 本次证据 |
| --- | --- | --- |
| `Guest.get/get_basic` | v2，单 `guest_id`；`get_basic` 部分调用另有 `additional:["guest_repo"]` | static；区别于清单 `list_basic` v2 |
| `Guest.get_setting` | v1，单 `guest_id` | static；历史 2026-09-20 有只读字段证据 |
| `Guest.list_resource` | v1，无额外参数；创建/编辑资源读取 | static；本次未取得完整资源响应 |
| `Guest.create` | v1，向导各页参数合并，加 `poweron_after_create:boolean` 与 `synovmm_ui_id`；仅普通创建使用 create，OVA/import 等不是同一方法 | static；字段与任务终态参见 2026-09-20 高级创建记录 |
| `Guest.set` | v1，原 `guest_id`、改动字段及 `synovmm_ui_id` | static；编辑不跟随 get/list 的 v2 |
| `Guest.delete` | v1，每个对象单独发送 `guest_id` | static；现 Apple 内部兼容分支把多个 ID 逗号拼接且未固定 v1，与当前官方定义有差距 |
| `Guest.Action.pwr_ctl` | v1，单 `guest_id`、`action=poweron/shutdown/poweroff/reboot`；poweron 路径可由 Entry.Request 批量封装 | static；现 Apple 内部兼容分支使用 on/off，需要聚焦修正；公开 API 方法不受本差异直接影响 |
| `Guest.Action.reset` | v1，单 `guest_id`；强制重置独立于 reboot | static；不因发现方法扩大移动操作范围 |
| `Guest.Image.delete` | v2，`id`、`synovmm_ui_id`；官方更新组件的特殊路径另加 blocking=true，普通删除无此参数 | static；现 Apple 内部兼容分支发送 image_id，与官方内部方法不同。公开 API 的 image_id 不能直接复制到内部接口 |
| `Network.set/delete` | 均 v1；set 的 `network_id/name` 加 external 的 interfaces_add/remove 或 private 的 host_id，VLAN 仅变化时发送；delete 单 `network_id` | static；重新确认历史网络观察；现 Apple name-only 分支未发保持拓扑所需字段，应后续修正 |
| `Cluster.get_total_progress` | v1，按用途传 prefix：virtualization、virtualization_guest 或 virtualization_image | static；未知任务不能按名称猜测身份 |

创建/编辑内存单位、autorun 三态、CPU 五档、vdisks/vnics、任务回执和控制台别名规则
已有独立观察：见 [高级创建](2026-09-20-vmm-creation-read-observation.md)、
[设置与控制台](2026-09-20-vmm-parity-read-observation.md)、
[控制台资源](2026-09-21-vmm-console-resource-observation.md)。这些是不同日期的证据，
本次不重复真实操作以获取同类结论。当前 Mac 创建仍按同名清单认领，控制台仍默认
en-us/空别名，属于实施差距，不能被记录为稳定 API 契约。

## 静态资源识别与五端影响

只保存 UTF-8 文本 SHA-256 以定位当前官方静态版本，不保存脚本或原始响应：

| 当前官方资源 | 字符数 | UTF-8 SHA-256 |
| --- | --- | --- |
| `ContainerManager/MainVue.js` | 2523375 | `22b13fc28bf2a1d3ceef5803979d5a90731c343e1fdd50f752c5275d9651870c` |
| `Virtualization/virtualization.js` | 1053676 | `d73dd9f28ee8c30d6cf18957cc772f634f0f15466d551c99549f84511cd986e5` |

- macOS：网络管理沿现读取字段；VMM 内部电源、逐项删除、映像删除、网络拓扑保持、创建身份与控制台差距需独立修复和回归，不能照抄现有实现补契约。
- iPhone/iPad：同一共享接口影响两端；本次文档提供后续容器创建/编辑/项目与 VMM 的字段来源，未新增这些产品入口，不把静态候选视作完成。网络 M7c3 的已有功能另行验收。
- Windows：核对内部电源与删除的同等参数；已有高级创建、拓扑保持和控制台独立实现继续以自身源码/测试为准，本片不改源码。
- Android：只记录契约差异，未修改代码或开放写操作。

文档、机器索引、兼容矩阵同步；未变更公开契约、持久化、权限、依赖或发布配置。
没有新 Adapter 接入的静态候选不伪造成功 fixture；后续实现须按实际请求构造补合成断言，
真实响应/行为仍需版本、权限、可丢弃目标、接受回执与最终状态的独立证据。未知账号角色、
证书类别、设备归属、非空项目响应、失败码、流式终态及新增写行为均保持未验证。
