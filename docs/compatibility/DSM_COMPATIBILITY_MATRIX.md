# DSM 兼容矩阵

2026-09-20 Windows 已按下述网络契约接 name-only 改名、多选逐项删除及只读恢复，
保护完整网络/关联 VM 快照，保持 VLAN/接口/主机不变，网络未知与相关 VMM 写
互锁。全量 3439 通过、双语各 19 原生合成场景通过，不能代替真实配置变更或
网络连接验收，也不提升历史 lab-a 证据等级；其他四端本波不变。

2026-09-20 待归属环境重新核实 DSM 7.2.1-69057 Update 12、VMM 2.6.5-12202，
管理员 Network.list/get v2 和 list_avail_interface v1 读取成功；官方脚本 set/delete
v1、接口增删数组、Guest.create v1 与 unmounted 空槽为静态线索。Apple 同类版本/
空槽已修源码但 Swift/Mac 未构建；Windows 网络写仍待实现，不提升写行为等级。
详见 [网络观察](../api/discovery/environments/2026-09-20-vmm-network-read-observation.md)。

> 只记录版本和验证结论，不记录 NAS 地址、序列号、账号或真实共享名。
>
> 当前匿名发现基线：[`lab-a-dsm-7-2-1-69057-u12-20260729`](../api/discovery/environments/2026-07-29-lab-a-dsm-69057-u12.md)。
>
> 本文件记录维护者验证结论。用户自愿提交的结果单独显示在[社区兼容矩阵](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)，不会自动提升本文件或私有 API 契约的证据等级。

| DSM build | File Station | 证书类型 | 平台 | 登录 | 浏览 | 下载 | 上传 | 删除 | 恢复 | 日期 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 7.2.1-69057 Update 12 | File Station 1.4.1-1559 | 公共 CA | macOS | 官方网页会话已通过；岚仓待复验 | 官方网页可见；岚仓基础浏览已有反馈 | 未验证 | 未验证 | 未验证 | 未验证 | 2026-07-29 |

## 连接方式验证

2026-09-20 Windows 控制台已接独立窗口，真实 WebView2 组件的双语合成回归通过：
私密配置、Cookie 属性、两层 CSP、外部导航阻断、关闭取消和目录清理已执行检查。
未加载真实 noVNC、未连接真实 WebSocket、未向 VM 输入，不能提升 DSM/VMM 行为
兼容等级。系统信任连接可主动验证；固定指纹模式仍不向网页组件释放凭据。

2026-09-20 Windows CPU 优先级以当前官方只读/静态记录实现 Guest.get v2 / set v1；
新合成 HTTP/状态回归覆盖 JSON/FORM、五档、同源核查、未知不重发及公开基础降级。
没有实际保存，不能据全量测试提升 DSM/VMM 写兼容等级；操作入口仍要求实际能力、
可核查基线、确认和权限响应，不自动处理真实 VM。

2026-09-20 待归属环境 DSM 7.2.1-69057 Update 12 / VMM 2.6.5-12202：管理员官方
页面的 Guest 元数据、get v2/get_setting v1 成功，相关字段为原生数字；set v1、
autorun 三态、CPU 五档和控制台路径只有静态线索。没有保存或控制台连接，不提升
旧 lab-a 或写兼容等级。Apple 已修源码，但 Swift/目标构建仍待执行。

2026-09-20 Windows 可选创建后开机使用已记录的公开 create/set/poweron 顺序，先
核对创建资源和配置再开机。合成证据不提升真实 DSM/VMM 兼容等级，没有实际开机
或自动删除回滚；开机未知的创建任务继续受清理保护，其他平台行为不变。

2026-09-20 Apple 公开 VMM 电源源码修正单 guest_id、固定 v1、空响应和状态核查，
未知不重发。公开重启无已记录契约，不调用猜测方法。13 项新增共享/Mac 测试均待
Swift 环境运行，只有源码/静态门禁证据，不提升任何 NAS 或 macOS 兼容等级。

2026-09-20 Windows 公开 Guest.Image.delete v1 已接空响应、ID/名称/类型预检、同源
严格回读及创建源保护。新后端及完整批次合成测试不等同 NAS 实测，没有实际删除
任何映像，不改变设备版本兼容等级，也不保证公开接口外的占用关系。

2026-09-20 Windows Task.Info.clear v1 为任务记录清理，沿用官方单 ID 参数和空
响应，加入创建证据保护及回读；未知不重发。合成/本机回归不等于真实 NAS 清理
验证，也不意味着 VM/映像业务任务已经成功，其他平台兼容结论不变。

2026-09-20 Windows 公开 Guest.delete v1 已有单 ID 空响应、身份/停机预检、严格
列表核对及会话内防重发实现，与原 VMM 写协调器互锁。1/21/205 项合成批次及
全量 3253 项通过属于本机代码验证，没有删除真实 VM，不升级任何设备兼容等级。

2026-09-20 Apple 共享 VMM 删除源码与公开指南对齐：Guest/Guest.Image.delete v1
单身份、空成功、同源列表验证；不使用 Task.Info，不以内部失败空列表报告成功。
只有源码及静态契约检查证据，Swift 测试/目标构建和真实 NAS 删除均未运行，不据此
升级 macOS 或移动端兼容状态，其他平台实现未变。

2026-09-20 Windows 多台 VM 电源操作沿用公共 Guest.Action v1 单 guest_id 请求及
Guest.get 回读，不新增内部接口。已接受的过渡态等待目标状态，未知或取消不重发；
205 台合成批次及全量 3231 项通过不代表真实设备电源验证，现有版本证据等级不变。

2026-09-20 Windows 回收/恢复仅补原会话内只读核对、成功本地回执、源路径存在性
核查及健康任务等待；Delete.status 按官方定义接受 total=-1、校验 processed_num。
两操作保留原权限、目标冲突与未知约束，未进行真实删除/恢复，不改变 NAS build/
套件版本或其他平台的验证等级。

2026-09-20 Windows 复制/移动待核对列表只使用原任务状态/文件读取，成功回执仅清理
本地会话记录；不增加 NAS 写接口。纯核对按稳定身份绑定已存任务，缺失身份不启动
操作，覆盖仍保持任务+回读证明。合成回归不改变真实 NAS 或其他平台的证据等级。

2026-09-20 Windows 复制/移动同名语义按官方 CopyMove v3 补齐：默认跳过、主动
覆盖，覆盖成功要求任务完成与独立回读；total=-1 统计态不再误报格式错误。108 个
请求 fixture 含新增两条覆盖，25 项新测试及全量 3164 项通过属于合成证据，不提升
真实设备覆盖/目录合并兼容结论。旧调用、恢复及旧照片不自动获得覆盖权限。

2026-09-20 Windows 文件页回收/恢复取消额外 20 项上限，仍沿用既有请求、权限检查、
禁止覆盖和精确回读。原生合成 206 项及单测 1001 项不代表真实 NAS 回收/恢复已验证；
没有修改设备、套件版本或内部 API 的证据等级，其他四端不改。

2026-09-20 Windows 复制/移动批次取消额外 20 项限制，仍按既有公开 API 和逐项结果
核查执行，未知不重发。206 项原生合成流程及 1001 项单测通过；未对真实 NAS 执行
大量复制/移动，不改变设备兼容结论，也不代表同名覆盖等语义已经完成对齐。

2026-09-20 Windows 多文件上传只移除客户端选择/拖放数量上限，仍逐项使用现有
公开 Upload 请求及结果核查，默认不覆盖；205 本地文件的原生合成流程通过。
未进行真实 NAS 上传/覆盖测试，不改变版本兼容结论或扩展其他平台权限。

2026-09-20 Windows 多选文件/目录下载复用公开 Download v2 的 path 数组，一次保存
一个 ZIP；单文件仍原样保存。客户端不截断为 20 项，合成传输与本地事务测试通过，
但真实 NAS ZIP 目录结构、权限和 URL 长度限制未实测，不提升下列环境验证结论。

2026-09-20 Mac 远程挂载的请求别名、NFS 缺参及错误断开接口已在共享源码纠正，
移除无证据只读保证；补参数与 fixture 回归，但没有 Swift/Mac 构建或真实写验证。
随后已补严格身份清单与写后来源/协议/自动挂载/目录双重核查，新增测试仍未运行。
后续已将确认前旧身份、目标预检和最后新连接核查接入 Mac 窗口与仓库，14 个新
Swift/Mac 测试方法未运行；未知恢复仍待实施。不提升下面版本行或声明目标构建通过。

同日后续已补本次连接内操作记录、未知只读核查、明确继续及结束剩余步骤的源码与
恢复窗口，新增 15 个 Swift/Mac 方法仍未运行。没有新的真实 NAS 证据或 Mac 测试包，
不把请求错误后的缺失观察当作“永久未执行”，不承诺跨重连/跨进程恢复。

2026-09-20 Windows 远程挂载阶段式核心已接官方静态参数及完整清单/getinfo 核查，
39 项核心合成回归覆盖修改分步确认、取消、身份漂移、防重复和未知恢复；后续原生
窗口已接入并按接口/会话/确认开放用户验证，增加无密码恢复与配置重新确认。
这不提升 DSM/File Station 真实写兼容等级，当前环境仍只有空清单只读证据；CIFS/NFS
连接、断开、副作用与选项需用户在专用共享验证。详见[挂载端点](../api/discovery/endpoints/file-station-remote-mount.md)。

2026-09-19 用户重新登录后，只读核查当前 DSM 7.2.1-69057 Update 12 与 Container
Manager 24.0.2-1535：官方静态容器写参数为 name，删除还带 force/preserve_profile；
映像删除为 images 对象数组，与 Mac 当前单 id 实现有差异。Container.list 的
State 运行布尔及启动时间字段类型已只读确认，尚未测试重启或删除；设备待归属，
不提升 lab-a 验证行。详见[生命周期观察](../api/discovery/environments/2026-09-19-container-lifecycle-read-observation.md)。

2026-09-19 Windows 公开 Compress v3 高级格式/级别/密码已接现有契约，33 项聚焦
合成回归及双语原生场景通过。任务完成与输出回读必须同时成立，未知任务不凭输出
存在确认成功；真实密码包解压、断线和权限仍待用户验证，不提升本表环境等级。

2026-09-19 Windows Chat 高级功能不再绑定单一 DSM/Chat build，也不依赖系统套件
管理读取权限；以有效绑定会话、对应接口版本/格式及每次会话/消息归属预检决定可用性。
未知操作仍不重放，确认与结果核查不变。290 项 Chat 合成回归通过，不增加真实环境
验证记录，macOS/iPhone/iPad/Android 请求和开放策略均不变。

2026-09-19 Windows NAS 专用管理/容器网络按用户授权开放验证入口，不再把单一 DSM
build 或“未行为验收”作为永久关闭条件。系统管理按明确管理员、接口及确认/回读
判断；容器保留套件权限边界。该策略只有合成与构建证据，不新增/升级任何环境
verification，历史“关闭”描述不等于当前 Windows 客户端策略。

2026-09-19 用户要求验证版本可操作：Windows VMM 电源/设置/创建已移除恒关闭门，
运行时仍核对会话、公开版本/格式，调用保留确认/目标/重复保护及回读。仅有公开
入口合成与原生 UI 证据，不能把开放状态标为 behavior-verified；无真实 NAS 写。

2026-09-19 Windows 创建核心仅增加公开 Guest.create / Task.Info.get / Guest.get /
Guest.set v1 的合成证据：新任务身份、资源/配置回读、一次性提交及未知恢复。
含映像盘不宣称来源已验证，原生向导未接、生产门关闭；公开存储 size/used 单位
转换修复不构成真实 NAS 写行为证据，不提升任何历史环境等级。

2026-09-19 Windows Task.Info v1 的完整清单/状态/进度读取和可见页刷新已有合成回归，
结束不视为创建成功；原始任务标识不进入 UI。真实权限、断线及大量任务性能未验证，
不提升任何环境证据等级，也没有任务清理或创建写行为证据。

2026-09-17 macOS 共享设置核查源码补齐 desc/cpu_weight/autorun 等实际发送值；
仅比较既有内部字段的精确回显，不确认内部自动启动含义。浏览器核查因连接失败未
产生新环境证据，4 个 Swift 回归待 Mac 执行，不提升下面任一读写兼容等级。

2026-09-17 Windows 基础设置编辑采用公开 Guest.get/set v1 的五类字段，autorun 明确为
0/1/2（关闭/恢复原状态/开启），不沿用内部接口的布尔映射。自动化与原生合成覆盖
原值漂移、部分保存、拒绝、断线核查和电源互锁；保存门关闭，真实 VM 验收为
PENDING_USER_VALIDATION，不提升下表或私有接口的任何证据等级。

2026-09-17 Windows VMM 官方单机电源操作已有源码/合成闭环：poweron、shutdown 与
poweroff v1 分开确认，按 guest_id 单次提交，空成功回执之后用 Guest.get 核查目标状态，
未确认不重放；没有虚构任务 ID 或调用内部电源方法。生产门仍关闭，真实 VM 权限、
断线与电源副作用待专用目标验收，不提升任何历史环境验证等级。

2026-09-17 Windows VMM 既有读取修正只增加合成证据：资源/保护/事件数组不再被客户端
截断到 200 项，内部日志按 JSON 声明编码，能力名称/版本/格式错误时关闭对应读取。
日志仍为既有首批 1000 项，未验证真实完整历史、生命周期或控制台，不提升下方版本
兼容等级。详情见 [VMM 内部接口](../api/discovery/endpoints/vmm-internal.md)。

Windows Container Network.list v1 已增加原生展开详情和严格关联计数合成证据；
创建核心与原生配置/确认/核查已有合成证据，生产门关闭、删除待接。
Apple 同类计数修正待 Mac 回归。未执行真实容器/网络写操作，不外推行为验证。

Windows 电源计划、USB/eSATA 与内存压缩只读候选适配及原生页面已有合成证据，Apple
严格读取修正待 Mac 回归；仍为 static，未验证真实读取，不开放保存、弹出或设置。

Windows 中继/路由器自动配置固定 v3/v1 读取、受保护保存及原生表单已有合成证据，
生产门关闭；Apple 独立读取和拒绝/未知结果修正待 Mac 回归。未执行
真实远程访问变更，不改变网络副作用或套件兼容验证等级。

Windows 硬盘检测目标/状态/最近历史固定 v1 读取新增合成证据，旧猜测写入已禁止；
Apple 设备身份、检测许可、严格读取、缓存绑定和未知反馈修正待 Mac 回归。未运行任何真实硬盘检测，
不提升既有读取或写行为验证等级；Windows 正确启停/有限回读/不重放恢复核心已有
合成证据，原生选择/状态/历史/确认/恢复已接入且生产门关闭。

Windows TaskScheduler list v3/get/create/set v4、EventScheduler 结果/输出 v1 以及 v3 命令核心
新增合成证据，原生列表/编辑/确认/记录输出已接线且通过合成场景；Mac 同类目标/新回读修正待回归。没有创建、运行、启停或删除真实任务，不提升
既有版本环境的写行为兼容等级。

Windows CurrentConnection v1 严格读取、完整目标 kick_connection 和原始标识回读
及原生确认/恢复新增合成证据，生产写门关闭。Mac 相应解析和结果修正待回归；不提升
已有列表的真实读取证据为断开行为验证，不自动重放当前会话或其他连接的断开。

Windows System v3 电源命令只有固定请求/预检/原生确认的合成证据，生产门关闭；
未知或已接受请求均不重放，新登录和用户设备核对只解除本地阻止，不证明最终电源
状态。未执行真实关机、重启或连接断开，不提升真实兼容等级。

Windows User/Group v1 独立读取、新建/编辑/删除及原生管理/只读恢复新增合成证据，生产写门
保持关闭；Mac 保存基线、真实回读、许可与结果覆盖修正待目标平台回归。未创建、编辑或删除
任何真实账号/用户组，不提升真实 DSM 兼容等级。

Windows 套件严格读取、基线确认/可行性检查/三操作核心与原生恢复新增合成证据，
生产门仍关闭。Mac 解析失败关闭修正待 Swift 回归；升级仅为只读提示，
不新增安装/升级请求，不提升真实 DSM 套件行为兼容等级。

Windows DDNS 的四操作核心及原生调用链已有固定请求、基线确认和故障恢复合成证据；
生产门关闭。Apple 适配器及 Mac 界面层同步纠正明确拒绝被旧列表覆盖及仅换密码超时
误报成功，Mac 回归尚未运行；不提升真实 NAS 写行为等级，Android 不在本波源码范围内。

Windows 终端/代理的固定版本读取及基线绑定保存/逐字段回读核心已补合成回归；未知
结果不显示已保存或自动重放，生产行为门仍关闭。只增加源码/本地自动化证据，不提升上述真实环境的 observed 等级，
不改变 macOS/iPhone/iPad/Android 既有契约或兼容结论。

区域/时间的 Windows 读取与 Apple 解码边界修复仅增加源码和 Windows 合成证据；
Apple 回归、真实模式/时区/改时副作用未验证，不提升现有版本环境证据等级。

Windows 文件服务六组读取及基线保存核心增加合成证据，原生入口在生产行为门下保持
只读；不使用猜测聚合 FileServ 接口，不提升真实 DSM 证据等级，真实六组写行为仍未验证。

普通链接和任务文件的显式 destination 均要求 Task v2。Windows/Apple 已修正适配与
共有链接 fixture；Android 引用该 fixture 的测试仍配置 v1，需单独同步/复验，不能将
Windows 构建成功视为 Android 或真实 NAS 兼容通过。

macOS Download Station 已纠正 `force_complete` 的入口和结果文案：它结束任务并移出
未完成文件，不是删除数据；任务消失不证明文件移动完成。本次不提升 NAS 行为验证等级，
Swift/macOS 回归仍需 Mac 环境，见[授权修复记录](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。

Windows Download Station 设置按官方 Info v2 读取/保存默认位置，仅 v1 时不展示虚假的空
默认目录；基础与计划分组件预检/保存/回读，目标目录先核对可写。新增本地合成证据，
不提升实际 NAS 保存、目录权限、eMule/自动解压副作用或计划执行的兼容等级，见
[Windows 实施账本](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。

Windows Chat 实时通道已有 EIO 4/3、心跳、重连、同源握手、事件回读与隐藏取消的本地合成
证据；复用原证书策略，不提升真实 NAS/代理/TLS 兼容结论，见[实时记录](../api/discovery/endpoints/chat-realtime.md)。

Windows 新 Chat 提醒/定时/投票/关闭/转发/公告及批量本人消息删除动作仅对既有 7.2.1-69057 Update 12 / Chat 2.4.1-22111 组合
开放受确认保护的操作入口；当前只有源码与合成验证，没有新增实机写入结论。未知组合保持
新写关闭，列表读取可降级；详细边界见[高级动作记录](../api/discovery/endpoints/chat-advanced-actions.md)。

2026-09-16 Windows 对齐核查：当前官方网页确认 DSM 7.2.1-69057 Update 12、Chat 2.4.1-22111、
Container Manager 24.0.2-1535、Photos 1.8.2-10090；Chat 创建/成员及 Docker Container/Log
声明 JSON。只增加能力元数据证据，设备归属未确认，不提升 Windows App、日志分页或写行为
等级，见[脱敏记录](../api/discovery/environments/2026-09-16-windows-parity-read-observation.md)。

### Photos 单项删除测试开放（2026-09-10）

- DSM 7.2.1 / 69057 / Update 12、Photos 1.8.2-10090：个人空间新增合成 PNG 单次删除完成，刷新后原件回读为空；设备匿名归属仍待确认，不冒用既有 lab-a。
- 用户进一步授权未逐一验证的版本也开放；macOS 个人空间单项删除按接口能力与权限启用，不按 DSM／Photos 版本拦截。确认、防重复及结果核对保留；共享空间关闭；此条记录 2026-09-10 macOS 授权与证据，不把后续端口迁移视为真实验证。未测版本不标记为已验证。
- PENDING_USER_VALIDATION：App 会话、重启、断网、权限变化和恢复。测试前使用可丢弃照片；结果不明先通过官方 Photos 核对，不重复提交。见 [端点记录](../api/discovery/endpoints/photos-item-deletion.md)。

### macOS 应用权限入口（2026-09-09）

- DSM 7.2.1-69057 Update 12 的管理员与普通账号官方桌面摘要已观察，设备匿名归属待确认，不能直接挂靠旧 lab-a 基线。
- macOS 已实现权限摘要读取与入口规则，替代登录后的套件业务加载试探；NAS 设置整体仅管理员可见，容器遵循管理员管理入口规则，独立应用必须明确授权。手动安装不单独拦截，第三方未知应用不生成请求。入口可见不解锁原有危险写门禁。
- `PENDING_USER_VALIDATION`：本地 App 登录会话读取摘要、管理员/非管理员显示差异、隐藏应用无请求、已授权应用与文件切换后不再出现 119；源码与自动化不替代真实 NAS 验收。
- iPhone/iPad 仅共享新增网络能力声明，未调用摘要服务；Android/Windows 代码未修改，后续再按各端计划接入。[发现与五端影响](../api/discovery/endpoints/dsm-desktop-app-privileges.md)。

| 连接方式 | 平台 | 地址发现 | 公开登录入口 | 完整登录 | 备注 |
| --- | --- | --- | --- | --- | --- |
| QuickConnect ID 直连 | macOS | 已通过 | 已通过 | 待用户复测 | 局域网与公网候选会在提交凭据前逐一探测；不记录 ID、解析地址和证书指纹 |
| QuickConnect 中继 | macOS | 已通过 | 已通过 | 待用户使用新密码复测 | 已完成真实环境的隧道建立、NAS 身份核对和 `SYNO.API.Info` 探测；`request_tunnel` 属于内部、可降级契约 |
| QuickConnect ID / 中继 | iPhone、iPad | 共享解析器已通过 | Release 模拟器构建、登录路由、冷启动自动登录测试和两种设备形态启动通过 | 待真机输入密码复测 | 保存资料保留原始 ID；可选密码存入 Keychain，自动登录和会话恢复均重新解析临时连接地址 |
| QuickConnect ID / 中继 | Android | 已通过真机探测 | 已通过真机 `SYNO.API.Info` 能力发现 | 待用户在修复版输入密码复测 | Release 启动崩溃已修复；可选密码由 Keystore 保护，探测不发送账号、密码或验证码 |
| QuickConnect ID / 中继 | Windows | 已通过真实服务探测 | .NET Release 测试已通过 `SYNO.API.Info` 能力发现 | 待 Windows 设备输入密码复测 | 可选密码由 Credential Locker 保护；登录和恢复均使用临时解析地址，完整 WinUI 构建须在 Windows 执行 |

## 文件操作验证

2026-09-09 macOS 修复补充：File Station 搜索改为公开指南要求的目录数组；Chat 创建能力兼容当前 NAS 声明的 JSON 参数编码。下载任务菜单按状态开放。浏览器只核实 DSM 7.2.1-69057 Update 12 / Chat 2.4.1-22111 的版本与能力元数据；本轮未在 NAS 创建会话、控制下载或执行空间分析，不能将合成测试或构建通过提升为实机通过。五端影响、自动化与用户验收见[本轮交付记录](../development/MACOS_ENTRY_FIXES_AND_FUNCTION_AUDIT_20260909_ZH.md)。

| 能力 | 使用契约 | macOS 状态 | 实机要求 |
| --- | --- | --- | --- |
| 同 NAS 复制/移动 | `SYNO.FileStation.CopyMove` 官方 API | 已实现 | 验证文件夹、冲突、取消和权限不足 |
| 文件与文件夹重命名 | `SYNO.FileStation.Rename` 官方 API | macOS 已实现；iOS/Android 待接入同一契约 | 验证同名冲突、无写入权限和特殊字符 |
| NAS 端压缩与解压缩 | `SYNO.FileStation.Compress` v3、`SYNO.FileStation.Extract` v2 官方 API | macOS 已实现；共享契约包含压缩包预读、密码检测和文件名编码，iOS/Android UI 待接入 | 验证 ZIP/7z 创建、简体中文旧版 ZIP、加密包密码循环、常见压缩格式、空间不足、同名覆盖和取消任务 |
| 跨 NAS 复制/移动 | Download + CreateFolder + Upload + 可选 Delete 官方 API | Apple 已实现 12 MiB 有界中转；Android 已实现文件复制/移动与文件夹复制，文件夹移动因递归删除竞态关闭 | 验证递归文件夹与背压；移动必须确认目标完成且源未变化后才删除，Android 需先补齐文件夹冻结或安全删除方案 |
| 下载断点续传 | Download 响应的 HTTP Range | 已实现、待验证 | 确认目标 DSM 返回 `206`，以及中断后字节一致 |
| 含糊扩展名识别 | Download 的 4 KiB Range 文件头 + 文件签名 | macOS 已实现；三端共享识别契约 | 验证 `.ts` 的 MPEG 传输流与 TypeScript；禁止按文件大小猜测 |
| 上传断点续传 | Upload multipart | 不支持字节续传 | 公开 API 未提供 offset/token；暂停后从头重新上传 |
| 子目录搜索 | `SYNO.FileStation.Search` 官方 API | 已实现 | 验证任务清理、中文、正则结果上限和无权限目录 |
| NAS 后台文件任务摘要 | `SYNO.FileStation.BackgroundTask.list` v3 官方 API | Apple 共享领域、Adapter、macOS 传输中心以及 Android Repository、Workspace 和传输中心已实现：App 传输/NAS 文件任务使用独立数据源，NAS 任务支持全部/进行中/已结束筛选、刷新、有限分页及加载/空/筛选空/错误/正常五态；每页 `limit=1...100`、按 `crtime desc` 排序，只请求 CopyMove/Delete/Extract/Compress 四类任务，敏感参数和路径在解码边界丢弃，`clear_finished` 保持关闭 | 尚未实机验证 API 发现、普通用户/管理员可见范围、分页变化、任务字段差异，以及“已结束”与实际成功/失败的判定来源 |
| 文件夹大小计算 | `SYNO.FileStation.DirSize` v2 官方 API 的 `start/status/stop` | Apple 共享仓库与 macOS 属性窗口已实现显式计算、重新计算和取消；窗口关闭后允许后台继续，关闭 File Station 模块或断连时取消；同路径防重复、有界轮询、`start` 禁止自动重放，仅能力缺失时回退客户端递归；路径和任务 ID 不进入领域结果、错误或持久化 | 尚未实机验证 API 发现、普通用户权限、大目录/远程挂载/加密目录、计数与逻辑字节语义、并发变化、超时、取消和任务丢失；官方 `stop` 表格疑似把 `taskid` 误写为 `tasked`，客户端按示例使用 `taskid` |
| 收藏夹 | `SYNO.FileStation.Favorite` 官方 API | 已实现 | 验证新增、移除和失效路径 |
| 分享链接管理 | `SYNO.FileStation.Sharing` 官方 API | 已实现 | 验证密码、有效期、批量路径、复制和取消分享 |
| 当前账号可见空间 | `SYNO.FileStation.List.list_share` 官方 API 的 `real_path` 与 `volume_status` | 已实现并按卷去重 | 验证多共享同卷、多卷、配额账号和字段缺失；结果不代表物理硬盘容量 |
| 当前账号共享访问 | `SYNO.FileStation.List.list_share` 官方 API 的 `adv_right` | macOS 只读页已实现；只解释可见条目的有效读写/删除能力，不展示物理路径，也不冒充管理员权限矩阵 | 验证管理员、普通账号、隐藏共享、只读共享、权限字段缺失、File Station 停用和 QuickConnect；不得记录真实共享名或响应 |
| 远程位置浏览 | `SYNO.FileStation.Info.get` 的 `support_virtual_protocol` + `SYNO.FileStation.VirtualFolder.list` v2 官方 API | 本批按能力返回的 `cifs`、`nfs`、`iso` 分协议只读枚举，以“协议 + 路径”去重；单次请求最多 500 条、每协议读取窗口最多 5,000 条，最终返回最多 5,000 个结果并明确提示截断（三协议最坏排序前处理 15,000 条）；不发送未公开的 `type=all`；ISO 只显示，不提供编辑或删除 | 尚未实机验证协议大小写、空能力、CIFS/SMB、NFS、ISO、失效位置、跨协议同路径、分页合并、普通用户权限和旧 DSM 行为 |
| 文件详情批量读取 | `SYNO.FileStation.List.getinfo` v2 官方 API | 本批按输入路径字符串去重并保持首次输入顺序，以每批最多 100 条分块，只请求功能所需最小字段；100 条是客户端保守上限，不是官方服务端上限 | 尚未实机验证大批量、部分路径不存在、无权限、返回乱序或缺项、QuickConnect 与不同 DSM build 的响应差异 |
| 远程位置创建、修改、删除 | `SYNO.FileStation.Mount` v1 内部实验性 API；公开 `getinfo` 只用于辅助回读 | macOS 已实现、默认由能力发现控制，尚未实机验收；ISO 不提供编辑或删除；`SYNO.FileStation.VFS.Connection` 与 `SYNO.Entry.Request` 继续关闭且未验证 | 必须记录 DSM build；验证管理员/普通账号权限、只读、错误密码、重复提交、修改回滚和断开后远端文件不受影响；不得把 `getinfo` 成功单独当作连接写操作已完成 |
| 旧照片文件扫描（历史，不再作为正式 Photos 入口） | `SYNO.FileStation.List`、`Thumb` 官方 API | 仅保留旧文件夹扫描证据，不能用于证明新 Photos 时间线兼容 | 新入口按 Photos 专项计划验证，文件／备份通用能力仍按 File Station 契约 |

## 统一存储管理（新增组合功能）

> 该功能由群晖“存储管理器”和“存储空间分析器”两个官方组件的能力合并而成，是岚仓 Mac 端新增的统一入口，不应记录成群晖某个单一官方套件已有的功能。

| 能力 | 使用契约 | macOS 状态 | 实机要求 |
| --- | --- | --- | --- |
| 容量与健康总览 | `SYNO.Storage.CGI.Storage.load_info` 内部只读接口 | 已与空间分析合并到同一入口；卷、存储池和硬盘详情保留 | 验证多卷、多存储池、SSD、扩展柜、异常状态和字段缺失 |
| 文件占用报告 | `SYNO.FileStation.List`、`SYNO.FileStation.Search` 官方 API | 已实现当前账号可见共享、文件类型、所有者、大文件及时间维度；用户主动开始并可取消 | 验证大目录、无权限共享、加密未挂载共享、远程挂载、回收站和网络中断 |
| 重复内容校验 | `SYNO.FileStation.MD5` v2 官方 API | 已实现先按大小筛选、再校验内容；当前每次优先校验较大的 400 个候选文件，取消时停止后台任务 | 验证同名不同内容、不同名相同内容、零字节、大文件、接口缺失和任务取消 |
| Storage Analyzer 套件历史报告 | 套件内部接口尚未固化 | 当前不读取或修改已有报告配置；已确认官方套件首页包含卷用量、报告配置和历史报告入口 | 取得脱敏契约后验证版本、权限、报告类型、时间线与套件停用；未验证前不得猜测接口 |

存储分析兼容记录不得包含真实共享名、文件路径、文件名、所有者、校验值或报告配置名称。

## 记录要求

- 私有 API 的环境、端点和升级差异必须按 [`DSM 与套件私有 API 发现规范`](../api/discovery/README.md) 留档，并同步更新机器可读的 [`compatibility.json`](../../contracts/private-api/compatibility.json)。
- 每次 DSM 或 File Station 升级后重新执行关键契约测试。
- 证书类型只记录“公共 CA”“自签名”或“私有 CA”，不记录证书正文、主机名或指纹。
- 内部 API 必须精确记录验证版本。
- “API 可发现”不能替代行为验证。
- 恢复必须完成删除、进入 `#recycle`、恢复和冲突测试。

## Synology Photos 兼容记录

> 五端正式入口已切换 Photos 个人空间读取及单项删除；删除按用户授权依接口与权限开放，不按软件版本白名单拦截。以下表格保留早期历史观察，不代表当前入口状态；当前能力见[照片计划](../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)，受控删除结论见本文件前文。未测版本不标为通过。

| DSM build | Synology Photos 版本 | 平台 | 个人空间 | 共享空间 | 基础照片库 | 时间轴 | 相册 | 人物/主题 | 地点/标签 | 日期 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 7.2.1-69057 Update 12 | 1.8.2-10090 | macOS | 内部接口未验证 | 内部接口未验证 | File Station 基础照片库已实现，待完整实机验收 | 内部接口未验证 | 内部接口未验证 | 未验证 | 未验证 | 2026-07-29 |
| 7.2.1-69057 Update 12 | 1.8.2-10090 | 官方网页观察／Apple 适配源码 | 个人读取结构已核对，App 未验证 | 当前账号 Photos 权限 none；成功读取未验证 | 完整替换施工中；旧入口尚未切换 | 官方时间分组及分页结构已核对 | 仅部分只读辅助方法，非空相册待验 | 列表结构已核对，App 未接入 | 地点列表结构已核对，标签样本为空 | 2026-09-09 |

2026-09-15 四端迁移仅增加 Android、iPhone、iPad、Windows 的源码与合成回归消费方；本轮没有新增真实 NAS 行为证据，也没有提升以上历史记录的等级。每个平台的 App 会话、媒体格式、共享非空数据、权限撤销与删除恢复仍为 `PENDING_USER_VALIDATION`。

照片兼容记录必须满足：

- 只记录 DSM build、套件版本、平台和结论，不记录 NAS 地址、账号、真实路径、相册名、人物或地点。
- 个人空间与共享空间分别验证不存在、无权限、只读和完整访问场景。
- 新照片模块验证套件未安装、停用和内部接口不可用时的恢复提示；不得暗中恢复旧照片库。
- 时间轴、相册、人物、主题、地点和标签分别记录，不能用一个总开关代替逐项能力判断。
- 每次 DSM 或 Synology Photos 套件升级后重新运行内部 Adapter 契约测试。
- Photos 个人空间单项删除的逐版本门禁已获明确豁免；权限、确认、防重复和结果校验仍必须保留，其他写能力按各自记录控制。

## Synology Chat 兼容记录

> 普通用户聊天使用独立的 `SYNO.Chat.*` 内部适配器。当前开发联调版只在 `SYNO.API.Info` 明确返回兼容路径和版本时启用第一批能力；未完成实机记录前不得作为发布兼容结论。`SYNO.Chat.External` 的 Bot/Webhook 能力不能替代普通用户会话验证。

| DSM build | Chat Server 版本 | 平台 | 用户会话 | 一对一/建群 | 文字/Emoji | 媒体/文件 | 语音 | 提醒/投票 | 加密 | 日期 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 7.2.1-69057 Update 12 | 2.4.1-22111 | macOS | 官方网页客户端已登录；岚仓待复验 | 首次单聊和建群静态契约已确认；写入待验收 | 静态契约已确认；岚仓待复验 | 上传/读取契约已确认；实际送达待新构建验收 | 音频附件播放可见；录音未确认 | 提醒/投票契约已确认；写入待验收 | 能力存在；密钥协议未验证 | 2026-07-23 |

当前开发联调契约：

| 能力 | 内部 API | 客户端状态 | 首轮实机检查 |
| --- | --- | --- | --- |
| 用户目录 | `SYNO.Chat.User.list` | 已兼容根数组、单数/复数容器、对象字典和常见字段别名 | 复验当前 NAS 的用户数量、显示名、停用账号和当前账号标记 |
| 用户头像 | `SYNO.Chat.User.Avatar.get` | 仅在能力发现存在且用户声明有头像时读取；限制响应为图片且最大 2 MiB | 复验有头像、无头像、无权限和 QuickConnect 场景 |
| 会话列表 | `SYNO.Chat.Channel.list` | 已接线，按成员和名称区分已有单聊/群聊；Android 首次单聊把列表同时用于写前查重和模糊提交后的最终确认，提交后取消只回读且不重放；打开会话后以进程内时间/预览快照压制相同活动的旧未读数，时间推进或同秒预览变化时恢复服务器值，切换连接时清理；不冒充服务器已读 | 空名称双人会话、首次联系模糊提交、服务器已读回写方法、未读数、最后消息和时间单位 |
| 历史消息 | `SYNO.Chat.Post.list` | 已接线 offset/limit 向上分页、消息 ID 去重、原阅读位置恢复；连接工作区每 5 秒刷新会话列表，消息页面可见时刷新当前消息，进入页面立即刷新；空发送者名称由用户目录回填 | 复验发送者、顺序、总数、跨页重复、增量遗漏和消息时间单位 |
| 会话置顶/星标 | 本地 `UserDefaults`；群晖官方客户端提供 Star，但未公开写入 API | macOS 已实现按 NAS 配置隔离的本地持久化置顶、固定顺序、原生右键菜单和可访问图钉状态；关闭会话时清理本地记录。当前不会猜测调用群晖内部星标写接口 | 验证重启、多个 NAS、刷新和实时事件后的顺序；取得脱敏官方请求后再增加云端星标同步与冲突规则 |
| 文字/Emoji | `SYNO.Chat.Post.create` | 已接线客户端请求 ID 进程内去重、发送中/失败状态、手动重试和重试前结果复查；每个会话保留独立内存草稿 | 发送返回字段、超时最终状态、重试去重、组合 Emoji 和权限错误 |
| 消息转发 | `SYNO.Chat.Post.forward` v5，`post_id`、`channel_ids`；无已有会话的联系人先使用 `SYNO.Chat.Channel.Anonymous.initiate` v2（内部接口） | 已按 Chat Server `2.4.1-22111` 官方网页客户端确认并接入；可选择已有会话或联系人，后者先创建并复查一对一会话；NAS 直接复制文字和附件，不经过客户端下载；投票和加密消息保持关闭 | 实机验证无历史联系人的首次转发、跨单聊/群聊、多个目标、图片/视频/大文件、机器人消息、部分失败、权限与 QuickConnect 行为 |
| 群成员 | `SYNO.Chat.Channel.Member.get` v1，`channel_id`（内部接口） | macOS 已提供群成员列表，并使用用户目录补齐名称、头像、当前账号和停用状态 | 实机验证群主/普通成员、成员较多、退出成员、无权限和 `broken_user_ids` |
| 群公告 | `SYNO.Chat.Post.pin/unpin/search` v5（内部接口） | macOS 已提供消息右键设置/移除公告和群公告列表；写入后用 `Post.search(has=["pin"])` 复查 | 实机验证普通成员权限、公告排序、文字/附件、移除、重复提交和实时更新 |
| 图片/视频/文件上传 | `SYNO.Chat.Post.create` v5，multipart `file`（内部接口） | 已按官方网页客户端静态实现接线；仅在运行时版本范围覆盖 v5 时开放；一次一附件，支持进度、取消、失败重试、临时文件权限保护和响应解析 | 在新构建中分别发送虚构图片、视频、文本文件；验证送达、取消、弱网、超时去重、空间不足和特殊文件名 |
| 附件读取/缩略图 | `SYNO.Chat.Post.File.get(post_id)`、`thumbnail(post_id,type)` v2（内部接口） | 已接入按需缩略图、下载进度和另存为；图片单击显示无元数据的纯图片预览，不再显示重复的打开入口；HEIC/HEIF 在 NAS 无缩略图时于 64 MiB 上限内下载原图并由 macOS 生成预览；附件辅助空记录不进入消息列表，分页游标按服务器原始记录推进；认证信息只放请求头，临时文件即时清理 | 实机确认图片预览、HEIC/HEIF 本机兜底、辅助记录形态、`type=sm`、响应类型、权限、缓存、特殊文件名、大文件和 QuickConnect 行为 |
| 内置贴纸 | `SYNO.Chat.Post.create`，`type=sticker`，`message=:贴纸令牌:`（内部接口） | 已确认当前版本令牌与三组套件静态资源；因资源文件带版本哈希且许可/跨版本策略未完成，岚仓暂不提供贴纸面板 | 验证不同版本资源定位、素材许可、令牌兼容和接收端显示后实现 |
| 私人群聊 | `SYNO.Chat.Channel.Named.create/join/invite` | 已接线，创建前去重、邀请后复查成员；Android 保存本进程稳定频道 ID，成员不完整报告部分成功，创建提交后取消不继续加入或邀请，只执行最终回读 | 三账号创建、117 已加入语义、部分邀请失败、取消临界点和重复提交 |
| 提醒 | `SYNO.Chat.Post.Reminder.set/list/delete/get` v1 | 已接入设置、列表、修改式覆盖、取消、重复提交保护和取消后结果复查；列表按官方契约携带当前 `channel_id`，失败在弹窗内提供重试 | 实机验证时间单位、列表容器、修改语义、取消、权限和到期行为 |
| 定时消息 | `SYNO.Chat.Post.Schedule.create/set/list/delete` v1 | 已接入纯文字定时消息创建、列表、取消、创建前查重、取消后复查和原生表单；列表按官方契约携带当前 `channel_id`，修改与附件未实现 | 实机验证时间单位、返回结构、重复提交、取消、离线发送和权限 |
| 投票 | `SYNO.Chat.Post.Vote.create/close/delete/set/get_choices/vote/create_option` v1 | 已接入无附件投票创建、输入校验、重复提交保护、结果回读、历史投票结构解析和原生创建表单；参与、关闭、删除、附图和结果实时同步未实现 | 用虚构数据验证创建返回、历史字段、截止时间单位、单选/多选、匿名、权限、投票与关闭 |
| 删除本人消息 | `SYNO.Chat.Post.delete` 内部联调契约 | 已实现单个/批量确认、只允许本人消息、请求 ID 去重和删除后复查；兼容成功响应仅含 `success`、不含 `data` 的实机形态；未完成更多版本实机记录前不作为通用发布兼容结论 | 管理员允许/禁止、24 小时/全部消息策略、无权限、重复提交、部分失败和 QuickConnect |
| 关闭会话 | `SYNO.Chat.Channel.close` 内部联调契约 | 已实现单个/批量确认、归档说明、请求 ID 去重和关闭后复查；兼容成功响应仅含 `success`、不含 `data` 的实机形态；未完成更多版本实机记录前不作为通用发布兼容结论 | 单聊/群聊、普通成员/所有者、无权限、归档可见性、重复提交和部分失败 |
| 首次一对一会话 | `SYNO.Chat.Channel.Anonymous.initiate` v2 | `user_ids`, `encrypted`, `channel_key_encs` 已由官方客户端确认；岚仓已实现先查重、创建、再回读复查，尚未对测试 NAS 提交写请求 | 由两个从未聊天的测试账号验证权限、重复提交、返回结构和最终会话唯一性 |
| 实时增量 | `sc/socket.io`（内部协议） | macOS 已接入同源 WebSocket、Engine.IO 4/3 协商、心跳、指数退避重连、200 ms 事件合并刷新和 5 秒轮询降级；连接稳定时保留 30 秒 API 校准。认证仅使用 Cookie/请求头，事件正文不进入业务层和日志 | 用 DSM 7.2.x 与不同 Chat Server 版本验证路径、Origin、Engine.IO 版本、登录续期、睡眠唤醒、QuickConnect 中继和事件覆盖；失败时确认 5 秒同步继续可用 |
| 语音 | `SYNO.Chat.Post.File.get` 可播放音频附件 | 官方网页可播放音频附件，但未确认独立录音消息的创建语义；岚仓不显示录音按钮 | 确认录制编码、消息类型、时长、取消和跨端显示后实现 |
| 加密 | `Channel.Anonymous.initiate` 的 `encrypted/channel_key_encs` 及官方前端密钥流程 | 保持关闭；接口字段存在不代表密钥协议已安全验证 | 完成设备密钥、恢复、轮换、撤销和附件加密全流程后再启用 |

Chat 兼容记录必须满足：

- 只记录 DSM build、Chat Server 版本、平台、连接方式类别和结论，不记录 NAS 地址、账号、频道名、成员名、消息、附件名或密钥。
- 套件未安装、停用、升级中、当前账号无权限和会话被撤销分别验证。
- 用户会话、Bot Token 和 DSM 会话分别记录能力结论，不能互相替代。
- 用户列表、一对一、建群、文字/Emoji、媒体/文件、语音、提醒、投票和加密分别记录，不能用一个总开关代替逐项能力判断。
- 每次 DSM 或 Chat Server 升级后重新运行内部 Adapter 契约测试；未覆盖的新版本默认关闭发送、建群、提醒、投票和加密写操作。
- 建群、文字发送、附件发送、本人消息删除和会话关闭必须验证权限、重复提交保护、超时后复查与最终结果。
- 图片、视频和文件分别验证大小限制、格式、取消、弱网、空间不足、特殊文件名和 QuickConnect 行为。
- 语音消息验证麦克风权限、编码、时长、取消、后台切换和临时文件清理。
- 提醒与投票验证权限、截止、重复提交、结果同步和锁屏隐私。
- 加密会话验证首次设备、设备加入、恢复、轮换、成员变化、撤销、附件加密和错误口令；任何失败不得回退明文。

## 系统、连接、VMM 与容器只读发现记录

| 范围 | 当前版本 | 证据 | 本轮结论 | 未验证 |
| --- | --- | --- | --- | --- |
| DSM 系统/系统活动/当前连接 | DSM 7.2.1-69057 Update 12 | 官方网页可见 + `SYNO.API.Info` + 已登录会话只读响应结构核对 + DSM 前端静态请求；进程 API 目前仅有静态目录 | 已确认 `System.info`、`System.Utilization.get(resource=all,type=current)`、`Upgrade.Server.check` v3、`CurrentConnection.list/kick_connection` 和 `SyslogClient.Log.list`；Android 已按固定 v1 接入每 2 秒采样、最近 120 点内存历史及离页停止的处理器/内存/网络/存储趋势，并与 macOS 对齐固定 v3 更新检查参数、候选版本/说明解析及无候选/失败边界；macOS 系统活动页已实现只接受运行时发现 v1、最多 500 项、字段白名单和服务组失败降级，但真实进程响应未验证；更新下载/安装和结束进程保持关闭；连接断开具备确认、防重复和复查 | Android 真实采样耗电/流量、后台切换、普通账号权限、多网卡与空字段；进程/服务组真实版本与响应、无更新/分阶段更新/重大版本、更新服务离线/代理、长时间采样和连接消失竞态；更新下载/安装和连接断开尚未对真实会话执行 |
| DSM 远程访问设置 | DSM 7.2.1-69057 Update 12 | 官方页面请求线索与已记录环境为 `observed / degraded`；Android 仅完成合成请求、故障注入、领域和 Compose 测试 | Android 第 55 批正式 Repository 固定 `SYNO.Core.QuickConnect.get_misc_config/set_misc_config` v3 与 `SYNO.Core.QuickConnect.Upnp.get/set` v1，严格 Boolean、单项 `null` 降级、已记录环境写门禁、可信中继关闭保护、实际变化字段提交、取消/断线不重放、专项回读与持久八状态/三计数反馈；专项 36 项 JVM 与 12 项 Compose 通过 | 未在真实 NAS 或路由器执行中继和自动端口映射写操作；不同 build、路由器、权限、断线与最终状态仍需专用目标验收；登录、QuickConnect 隧道和 `SYNO.API.Info` 证据不能外推为本设置写入证据 |
| DSM 电源计划 | DSM 7.2.1-69057 Update 12 | 仅有静态 API 目录与客户端合成响应；未保存真实响应 | macOS 已候选接入运行时发现的 v1 `load`，最多 128 条，只保留动作、启用状态、合法时间、命名星期、一次日期和可选时区；能力缺失零请求，`save` 保持关闭 | 真实版本、路径、字段、动作与重复枚举、时区/夏令时、权限、数量上限和排序；保存操作尚无版本化契约 |
| DSM USB/eSATA 外接存储 | DSM 7.2.1-69057 Update 12 | 仅有静态 API 目录与客户端合成响应；未保存真实设备响应 | macOS 已候选接入两个运行时发现的 v1 `list`，每类最多 64 项，只保留受限标识/名称、归一状态和单位明确的字节容量；单项失败独立降级，USB `eject` 保持关闭 | 真实版本、路径、容器、字段、权限、多分区/扩展坞/热插拔身份、容量单位与排序；安全弹出尚无版本化契约 |
| DSM 内存压缩（ZRAM） | DSM 7.2.1-69057 Update 12 | 静态目录确认 `get/set`；2026-08-03 已在官方 DSM 页面只读观察到设置，但未捕获 API 请求或响应 | macOS 已候选接入运行时发现的 v1 `get`，只保留启用状态、单位明确的字节容量和 `lz4`/`lzo`/`zstd` 算法白名单；能力缺失零请求，`set` 保持关闭 | 真实版本、路径、容器、字段、权限、禁用状态、算法枚举和不同硬件可用性；设置操作尚无版本化参数、资源影响、重启/即时生效与最终回读契约 |
| DSM 打印机 Bonjour 共享 | DSM 7.2.1-69057 Update 12 | 仅有静态目录中的 API 名称和 `get`；没有在当前环境观察或调用 | 客户端保持关闭，不注册版本、领域模型或 Adapter，不复用通用 Bonjour/Avahi 字段，零猜测请求 | 运行时 API 是否存在、版本、路径、参数、响应容器、布尔语义、权限，以及是否包含打印机/队列/设备/网络字段 |
| DSM 存储/套件/任务/账号 | DSM 7.2.1-69057 Update 12 | `SYNO.API.Info` + 已登录会话只读响应结构核对 + DSM 前端静态请求 | 已确认 `Storage.Disk.get_smart_test_log/disk_test_log_get/do_smart_test` v1：请求使用 `load_info.disks[].device`，状态取 `testInfo[0]`，历史取 `testLog`，并识别其他检测占用；同时确认 `EventScheduler.result_list/result_get_file` v1、套件管理、任务管理以及用户/群组管理；macOS 已实现硬盘检测启停、真实历史记录、任务运行记录和其他受保护流程；套件启动/停止另已实现列表状态与可行性预检、同 ID 防重复、写后轮询及提交异常只回读不重放；`available_operation=upgrade` 仅显示 DSM 只读提示，安装/升级保持关闭 | 不同 RAID/SSD/扩展柜、普通账号、空目录和大清单；硬盘检测、套件启停及其他写操作仍需用专用测试目标完成权限、依赖阻止、忙碌、重复提交、超时与最终状态实机验收；套件来源、安装队列、取消和最终版本回读未验证 |
| Virtual Machine Manager | 2.6.5-12202 | 官方网页可见 + `SYNO.API.Info` + Synology 官方 VMM API 指南 + 2026-07-27 已登录页面只读导航、创建/修改请求发送前拦截、日志页面与前端读取契约核对和 noVNC 地址生成逻辑核对 | macOS 已接入官方 `SYNO.Virtualization.API.*` v1 优先和内部接口隔离降级；Android 可创建总计最多 8 块空白/映像混合磁盘和多网卡（含未连接网卡），但 `Guest.get` 缺少源映像 ID，含映像盘结果只标记需刷新核对。Task.Info 最多读取 100 项，仅在任务页可见且仍有未结束任务时每 2 秒独立刷新；清理以全量 `list/get` 基线为准，只逐项 `clear` 未漂移的已结束任务。NAS 既有文件和系统 `OpenDocument` 本机文件均可沿公开 `Guest.Image.create` 创建；本机文件先经 File Station 无覆盖暂存，跨进程恢复记录使用加密存储，写边界不明时不重放，终态按完整基线删除临时文件 | 新增能力仅增加公开指南驱动的合成契约、JVM、编译与模拟器界面证据，不升级真实环境证据等级；真实 NAS 的多磁盘/多网卡字段、映像来源、任务字段、清理权限与副作用，以及系统文件授权、后台限制、格式、权限、存储和临时文件删除待用户打包验证。高级硬件编辑、迁移、克隆、映像编辑/导出和内部网络修改/删除仍需稳定契约或专用目标 |
| Container Manager | 24.0.2-1535 | 官方网页可见 + `SYNO.API.Info` + 2026-07-27 已登录页面只读导航、脱敏请求结构核对和下载请求发送前拦截 | 已确认 `SYNO.Docker.Container.list` v1 需要 `offset=0`、`limit=-1`、`type=all`；镜像仓库使用 `SYNO.Docker.Registry.search(offset,limit,page_size,q)` 与 `tags(repo)`，下载使用 `SYNO.Docker.Image.pull_start(repository,tag)`；macOS 已实现搜索、结果选择、标签筛选和下载启动，并将映像、网络、项目和活动记录隔离为可降级附属读取 | 下载请求在发送前终止，未对真实 NAS 执行拉取；其他写操作尚未在专用目标执行；环境变量、挂载路径、容器日志正文与 Registry 凭据未读取 |
| Download Station | 4.1.2-5012 | 官方公开指南 + 2026-07-27 已登录页面只读导航与脱敏字段核对 + 2026-07-29 套件中心版本复核 | macOS 官方 `SYNO.DownloadStation.*` 优先，当前 NAS 的 `SYNO.DownloadStation2.*` 独立降级；Android 已接入 Tracker/Peer、RSS 浏览/单站点刷新和结构化任务控制。Android、Apple shared/mobile 与 Windows Domain/Infrastructure/ViewModel/WinUI 均已按官方 `SYNO.DownloadStation.BTSearch` v1 接入提供方/类别目录、全部/仅启用/指定提供方范围、类别、标题、七类排序与方向、有界列表和临时任务清理，不回退到 `DownloadStation2`；正式提交 `5850f4c` 已通过 Apple、Android、Windows 与 Repository 四组云端门禁，但不构成新的真实 NAS 证据。Android、Windows 与 Apple 公开 Download Station 路径的当前活动摘要使用官方 `SYNO.DownloadStation.Statistic.getinfo` v1；Apple 既有 `DownloadStation2` 降级路径仍 best-effort 使用内部 `SYNO.DownloadStation2.Task.Statistic.get`。两条 Apple 路径都只显示标准任务/eMule 当前聚合速率，读取失败不替换任务列表，也不升级真实 NAS 证据。第 78 批另新增官方 Task.edit v1 单任务保存位置：任务/可写目录双基线、单次提交、严格回读、断线/取消不重放及持久反馈 | 新增能力只增加公开指南驱动的合成请求、领域、自动化、模拟器和云端构建证据，不升级真实环境或写行为等级；真实 NAS 的搜索提供方/类别、清理、速率字段、权限与版本差异，以及文件移动副作用和断线边界待用户打包验收。官方指南仍未公开 RSS 完整编辑或文件优先级写参数；BT 协议高级设置、监听目录、NZB、RSS 与通知设置仍需契约和专用目标验收 |

2026-09-10 Container Manager 后续反馈：macOS 已修正日志 load 参数、网络关联数组计数与只读详情、项目空键值对象解析，并按用户批准同步完整网络创建表单和配置契约。1.0.5 按用户明确要求移除错误的包类型创建限制，正式版与测试版均连接同一套受保护创建流程；具体环境的权限与写后结果仍按证据记录验收；Agent 没有对真实 NAS 创建网络，不提升上表历史基线等级。当前观察的设备归属及完整版本未重新核实，五端影响、迁移及回滚见[容器反馈记录](../api/discovery/environments/2026-09-10-container-read-observation.md)。

2026-09-17 Windows 网络管理已补详情、创建与删除原生流程及合成回归。删除按对象数组
提交，保护系统/占用网络，部分结果按原 ID 回读，不重放未知操作。Windows 生产创建/
删除门仍关闭，批量删除和高级创建选项未取得真实行为证据；不改变 macOS 既有入口策略。

同日 Windows 映像仓库搜索/标签读取已接 v1 编码、严格数组解析和原生取消/迟到隔离，
只有合成证据，不增加拉取或其他写验证。Apple 字符串标签被丢弃的同类解析问题已修，
尚未运行 Swift/macOS 回归，不外推为共享调用方已通过验收。

2026-09-17 后续官方只读核查确认 Image.list 的 offset=0/limit=-1/show_dsm=false 和
tags 字符串数组，Windows/macOS 已有读取同步补参并拒绝不完整目录；记录仍待匿名
设备归属，不修改旧基线等级。pull_start/pull_status 与聚合任务列表仅有静态线索，
多标签/下载任务公开模型待单独审批，实际下载与异常终态未验证，详见
[本轮发现记录](../api/discovery/environments/2026-09-17-container-image-pull-read-observation.md)。

2026-09-20 Windows 镜像删除已依据官方静态 images 数组接入仓库/标签与裸 identity，
标签身份、占用预检、多选确认、部分结果及只读恢复已有合成回归；测试版按会话/接口
开放供用户验证。并未在 NAS 执行删除或提升历史行为等级；Mac 单 id 参数、多标签
表达和独立只读恢复已修源码，但 Swift/Mac 未构建。拉取追踪亦已补源码，移动范围不变。

2026-09-20 后续 Windows 拉取接入 task_id 绑定、pull_status v1、进度/标签回查、
无回执不重发与会话内恢复，界面按能力允许用户验证。依据官方静态流程并增加合成
请求/客户端回归，不代表当前 NAS 字段类型、任务结束或取消行为已实测。Mac 任务
追踪已补源码但未执行 Swift/App 构建回归，恢复限当前连接内存；移动平台不开放。

本表只确认当前记录的发现范围。合并后的 NAS 设置已形成当前 DSM build 的既有读取结构兼容结论；新增系统活动、电源计划、外接存储与内存压缩适配仍只有静态目录、页面观察或合成测试，不继承其他系统接口的 `read-verified`；打印机 Bonjour 共享仅完成静态登记，客户端整体关闭。当前账号共享访问只使用公开 File Station 契约，内部管理员权限矩阵保持关闭。文件服务、远程终端、代理、物理网卡、DDNS、区域时间、远程访问、防火墙基础控制、UPS 和套件启停已按当前 DSM 前端契约接入客户端保护与写后回读，但尚未在专用测试设备上形成真实写操作兼容结论。Android 第 55 批远程访问合成测试不改变机器可读记录的 `observed / degraded`，也不把登录或 QuickConnect 连接证据外推为设置写行为证据。Android 第 56 批 Download Station 合成测试同样不升级套件兼容证据，不把任务消失外推为文件删除副作用已确认；真实暂停、继续与两类删除仍待专用目标验收。Android 第 67 批文本保存、压缩和解压只增加客户端基线、路径锁、结果保存及合成回读证据，不升级 File Station 兼容等级；顶层解压路径与类型核对不代表递归内容或校验和已验证。第 68 批 RSS 持久结果与 `DownloadStation2`/VMM 独立文档只修正客户端反馈和证据引用，不提升 `observed`、`read-verified` 或写行为等级；第 69 批后台上传持久结果只保留公开 File Station 调用的客户端语义，不形成新的真实 NAS 证据。真实任务字段、权限、断线、取消、挂载切换和副作用仍待专用目标验收。共享文件夹复合管理、完整防火墙规则、电源计划保存、USB 安全弹出和内存压缩设置仍保持关闭；其他 DSM build、套件版本与权限组合仍需验证。Download Station、VMM 与 Container Manager 已进入 macOS 实现，但内部接口写操作仍以专用目标验收为发布前置条件。

## 2026-09-29 Photos macOS 增量对齐影响

用户已授权增量扩展上传、相册/分享管理、标签/评级/日期、移动/复制共享契约。完整账本见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`，接口证据见 `docs/api/discovery/endpoints/photos-management.md`。新增写方法默认关闭，仅有官方静态结构和合成测试，不升级为真实 NAS 兼容结论。macOS 批量删除、月份稳定与自动核对沿用既有删除门禁；新增批量保存使用原有只读接口。iPhone/iPad 共用 Apple 协议的默认不支持实现，保持既有单项删除界面；Android/Windows 仅记录影响，未改代码或开放新入口。未完成的网页能力与验证条件在账本明确列出，不计作完整对齐。

2026-09-29 后续明确授权：用户要求取消新增照片功能的默认禁用。Apple 实际 Photos Repository 已移除人工能力白名单，macOS 按真实接口支持开放上述功能；保留权限、确认与结果校验。其他端 UI/存储仍未修改；接口开放不能表述为跨版本验证通过。专用合成图片/相册的网页验证与最新包记录见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md` 末尾。


### 2026-09-29 Photos 后续波次

Photos 多文件上传和相册目标复用已有单文件上传/成员接口；封面使用既有 set_cover/get/Thumbnail 通道。合成验证与真实版本兼容性分开记录，未新增 behavior-verified 版本结论，继续按用户明确授权开放实际支持入口。


### 2026-09-29 Photos 标签与日期增量

Photos 新标签使用已记录 GeneralTag.create/list，日期偏移复用已记录 Item.set(time)，不猜测 shift_time 参数。尚无当前版本真实行为结论；取消人工默认禁用的用户授权继续有效，实际 API/权限检查保留。


### 2026-09-29 Photos 目录层级与高级管理发现

个人空间 Folder.create v1(target_id,name) / get v2 已进入 macOS 层级上传；创建回执必须按编号、父目录、名称和 view/manage 权限回读，未知不重放。不设人工白名单，真实 NAS 写入仍为 PENDING_USER_VALIDATION，合成测试不提升环境等级。photos-file-management 已同步；另登记条件相册、人物、照片请求与预览重建四组静态候选，高级分享补充静态结构。31 项端点引用校验通过。不得把候选登记或网页参数读取称为 behavior-verified。


### 2026-09-29 条件相册增量

photos-condition-albums 已接入 macOS：ConditionAlbum v3 create/get/set_condition/suggest/peek_item_count，Album v4 列表识别 type=condition。仅个人来源，所有者和目录可见性检查、原规则冲突检测、去重与完整回读；未新增环境行为等级。PENDING_USER_VALIDATION：专用合成条件相册创建/编辑及只读预览，NAS/Photos 版本、日期边界和建议非空结构待核对。

回滚可移除条件相册入口、命令和新增默认字段/方法，既有普通相册、时间轴和上传流程保留；不迁移已有持久化。完整证据见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。


### 2026-09-29 分享现状与访问方式增量

macOS 接入只读分享快照、当前设置初始化、仅受邀者模式、已有保护标记与复制链接；不修改时不提交，保存校验原快照并保留密码/有效期。公开访问只有查看/下载，upload 是具名成员角色。新增领域 albumSharing 与 shareAlbum 可选快照，旧调用默认兼容；不改持久化、权限或工具链。iOS/iPadOS 共享领域受影响但无新 UI、未运行移动构建；Android/Windows 本轮只同步契约影响，不改实现。密码/有效期编辑与成员增删改仍未完成，NAS 写入为 PENDING_USER_VALIDATION，无人工验证白名单。回滚移除新方法/快照/入口即可，无数据迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 和 photos-management.md。


### 2026-09-29 Photos 分享成员增量

macOS 已接入用户/群组候选、成员添加/移除与角色调整；type+id 识别身份，按原快照计算差量，保存后核对完整角色名单。普通相册成员可上传，条件相册不提供上传角色。未知列表不当空名单，原未知角色不静默降级，原密码/有效期保留，关闭状态不意外启用。新增共享领域成员类型、sharingRecipients 默认方法和 shareAlbum.members 可选参数；无存储/权限/工具链变更。iOS/iPadOS 共享领域增量但无新 UI、未运行移动构建；Android/Windows 仅同步影响。真实权限写入 PENDING_USER_VALIDATION，不设验证白名单。回滚移除成员增量，不影响基本分享。高级分享剩余密码与有效期编辑，详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 Photos 人物命名与合并增量

macOS 人物卡片接入命名/清空名称和合并，表单显示人物封面、名称与照片数量；独立按真实能力开放。新增共享领域 peopleNames/peopleMerge、renamePerson/mergePeople、managementPeople、结果 person/removedPersonIDs 和分类缩略图默认方法，无存储格式变更。合并前后核对照片集合、目录权限和目标快照，结果自动确认，同操作不重发；更新当前列表而不跳到最新照片。分类封面使用当前分类列表的授权缩略图，避免把人物编号用于相册查询。iOS/iPadOS 共享领域受影响但无新增 UI、未运行移动构建；Android/Windows 仅更新影响计划。真实 NAS 人物写入 PENDING_USER_VALIDATION，无人工禁用/验证白名单；人脸分离、封面和识别纠正仍未完成。回滚移除人物入口/命令/结果增量，既有照片流程保留；无依赖、权限或持久化迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。


### 2026-09-29 分享有效期增量

macOS分享表单新增读取当前到期日期、设置/更改与取消期限；未编辑保留原始值，未知状态不当成不限日期。共享领域SynologyPhotoSharingState增加默认nil的expiration（Unix秒），shareAlbum增加默认nil的expiration参数，nil保留、0取消、正数设置；既有调用源兼容，所有模式匹配已同步。Repository要求确认快照、所有者权限与原修订一致，仅发送改变字段，关闭分享时编辑不启用，自动核对有效期/密码/成员。日期使用本地日末，覆盖夏令时。无数据迁移、依赖/权限变更和人工白名单。

iOS/iPadOS共享模型与网络受影响，无新界面，未运行本轮移动构建；Android/Windows仅同步契约影响，不改代码。回滚移除可选字段/参数及日期编辑控件，不影响已有分享。真实NAS写入为PENDING_USER_VALIDATION：在授权测试相册设置未来日期、取消、关闭状态编辑，并与网页核对保护和成员；断网不得重发，网页并发更改应拒绝覆盖。密码编辑、照片请求、人脸纠正、预览重建、共享空间和重启恢复仍未完成。详情见照片对齐账本和photos-management.md。


### 2026-09-29 共享空间读取适配增量

Apple Repository 接入 team_space_permission 的 entry/management 与 TeamSpace.enabled，增加 FotoTeam 时间线/目录/筛选/媒体能力发现；缩略图和大图按照片空间选择 p/t 路由，同编号不混读。entry核对目录view权限，management仅适用于共享空间；旧授权在重新核对时撤销，缺失接口不回退个人图库。未新增版本白名单、依赖、持久化或用户权限。

macOS空间选择、相册/分类作用域及共享上传/管理仍未完成，不能将网络层适配当作完整界面对齐。iOS/iPadOS共享网络实现受影响，当前无UI变更；Android/Windows仅同步协议影响。自动化覆盖授权、路由、图片、视频与原件导出；真实NAS entry/management账号和目录限制为PENDING_USER_VALIDATION，未运行本轮移动构建。回滚仅移除本轮共享读取增量，保留个人能力与既有分享有效期修改。证据及验收步骤见MACOS_PHOTOS_PARITY_20260929_ZH.md、photos-library-read.md。


### 2026-09-29 共享空间选择与上传增量

macOS 时间线/文件夹可切换个人与共享空间，切换清除旧目录、筛选和预览；上传表单/队列固定空间，支持共享目录层级导入。共享领域 upload/createFolder 新增默认 personal 的 space，Serving 增加带默认桥接的 managementFeatures(in:)；无数据格式或持久化迁移。Apple Repository 按 FotoTeam.Upload.Item 与 Folder 能力、真实权限和目标读回处理，不设人工版本白名单。共享元数据、移动复制、人物/相册来源仍未完整接入。

五端影响：macOS 已实现本切片；iOS/iPadOS 共享包源兼容，现有枚举匹配已同步，平台界面/构建未验证；Android、Windows 只记录后续空间目标与队列隔离的等价语义，未修改其实现。回滚可撤销选择器及本轮作用域扩展，个人上传保持独立。官方协议证据为 static，本地171项功能与6项本地化、2项界面测试通过不等于真实NAS写入验收；entry/management账号和共享目标写入标记 PENDING_USER_VALIDATION，详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-management.md。


### 2026-09-29 共享照片管理增量

macOS/Apple Repository接入共享评级、描述、绝对/相对日期、标签新建增删、同空间移动复制、原件删除与结果自动核对。createTag增加默认personal的space，其他照片命令由不可变目标推导空间，预检拒绝混合空间/NAS；目标文件夹表单固定原空间。后台File操作使用FotoTeam，Info状态仍统一Foto。未修改存储，无新增人工版本名单；回滚可撤销本轮作用域增量，既有个人语义保留。

五端：macOS本轮实现；iOS/iPadOS共享包关联值匹配已同步，UI和构建未运行；Android/Windows仅记录上述等价语义，不修改实现。191项XCTest（含能力发现）及6项本地化通过，合成Model覆盖共享月份编辑/删除保持位置。真实共享NAS写入证据仍为static，entry管理权限、management账号、失权/断网/回收站/任务结果列入PENDING_USER_VALIDATION，操作步骤见Photos对齐账本。共享分类/人物/相册来源、跨空间移动、其他完整对齐剩余项未宣称完成。


### 2026-09-29 照片分享密码增量

macOS与共享Apple Repository接入分享密码设置、替换和清除。shareAlbum新增默认nil的password（保留），空字符串清除、非空原样设置；沿用现有HTTPS连接策略，不新增持久化或依赖。新密码成功需update明确回执及保护状态、访问方式、成员、期限一致回读；回执丢失不能用已有保护标记确认替换，未知结果不重发。表单使用安全输入，关闭即清空草稿。

五端影响：macOS实现；iOS/iPadOS共享枚举匹配同步但未新增界面、未运行移动构建；Android/Windows仅记录待迁移语义，不修改实现。无新增版本/测试白名单，真实权限与确认仍保留。回滚移除本轮password关联值与表单即可，成员和期限独立保留。官方证据static，未做真实NAS密码写入；PENDING_USER_VALIDATION步骤、测试命令与最终结果见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`。完整照片网页对齐仍在进行中。


### 2026-09-29 照片收集请求主流程增量

macOS/Apple Repository新增收集请求创建/编辑/删除、完整快照、个人/共享目录选择、默认目录规则、addable自有/共享相册、期限与单文件大小限制。按精确passphrase读回，创建无回执不按名称追认；编辑差量与原快照冲突、删除失效核对、局部列表更新，未知不重发。完整目录路径通过Collection新增默认nil的path传递，不新增持久化或依赖。

五端：macOS接原生表单与自动核对；iOS/iPadOS共享领域/Repository增量，服务方法提供默认显式不支持以保持旧实现兼容，未新增移动UI或运行移动构建；Android/Windows仅记录待迁移语义，不修改源码。沿用用户契约授权，不设人工版本名单；NAS权限、确认、身份和结果校验保留。回滚移除请求管理入口/命令/结构和可选path即可，既有照片管理不受影响。证据仍static，真实NAS请求创建/删除及访客上传为PENDING_USER_VALIDATION；命令和结果见Photos对齐账本。收集窗口内新建相册、请求搜索及其余照片功能仍未宣称完成。


### 2026-09-29 人脸整理增量

macOS在个人空间人物照片的选择菜单接入移出人物、归入其他/新人物和设置人物封面。先按照片读取Person.list_face，以独立人脸编号选择，不把照片编号当人脸编号。移出后只有该照片在原人物中不再有其他脸时才从当前人物视图移除；原照片保留，页面与筛选不跳回时间轴。分离必须核对来源缺失且目标含相同人脸与照片对应；新人物缺回执不能按名称追认。封面须明确set_cover回执及Person.get最终cover一致。

共享契约新增SynologyPhotoFace、peopleFaces/peopleCover能力、personFaces/thumbnail读取、remove/reassign/setCover命令及结果removedFromPersonPhotoIDs；旧服务通过默认显式不支持兼容，结果字段默认空。macOS与Apple Repository实现；iOS/iPadOS共享声明可编译兼容但无新UI，移动端未构建；Android/Windows仅同步待迁移语义，未改实现。无持久化/依赖/工具链变更；回滚移除新增入口、命令、读取及字段，保留已有命名合并。真实权限、确认、身份与重复提交保护保留，不设未实测白名单。

证据为官方脚本static和本地合成验证，真实NAS验收为PENDING_USER_VALIDATION；详细命令、结果和失败记录见MACOS_PHOTOS_PARITY_20260929_ZH.md。完整图片内人脸框绘制/新增、人物显示隐藏、共享人物与其他照片功能仍在后续范围，不宣称全部复刻。


### 2026-09-29 人物显示管理增量

macOS个人空间人物页新增批量显示/隐藏、搜索与恢复隐藏入口，人物卡片菜单可直接选择原人物。隐藏不删除照片，结果局部更新，不刷新到最新日期。读取Person.list(show_hidden/show_more)，提交前后Person.get明确核对show，Person.show仅改变选中项；部分成功只更新已确认项，未知只回读不重放。人物封面同时支持unit_id/type=unit和人物编号/type=person两种结构。

共享契约增量为SynologyPhotoPersonVisibility、peopleVisibility能力/读取、setPeopleVisibility命令及结果personVisibility（默认空）；服务读取默认显式不支持保证旧实现源码兼容。macOS及共享Apple Repository实现；iOS/iPadOS仅共享声明，不新增UI且未运行移动构建；Windows/Android记录迁移影响，未改源码。无依赖、工具链或持久化变更；回滚移除本轮入口和增量声明/方法即可，已改变的人物状态可在官方网页恢复。权限、确认、重复保护和结果核对保留，不设置待实测人工禁用开关。

证据等级static及本地合成验证；PENDING_USER_VALIDATION：以少量测试人物隐藏后重新显示，确认照片仍保留、刷新后状态一致、关闭弹窗不写入；失败回传脱敏步骤与界面错误。详细本地命令及结果见MACOS_PHOTOS_PARITY_20260929_ZH.md，不能据此宣称共享人物或手工画框完成。


### 2026-09-29 图片内手工人脸编辑增量

macOS个人照片预览接入编辑人脸：加载原有框、鼠标绘制/拖动/缩放、键盘等价的居中新增与位置/尺寸滑块、归入既有或新人物、移除与撤销移除，点击保存前不写NAS。裁剪最长边256的JPEG，照片显示坐标归一化；调整既有框按新增框并完成缩略图后移除旧标记，原图保留。读取Item.list_face v6；新增Person.add_face v3返回临时编号到face_id映射；Upload.Face upload v1传multipart JPEG。归属纠正和移除沿separate/delete_face。不新增猜测API。

共享契约增量为FaceBounds/FaceRegion/NewFace/FaceChange、photoFaces读取（旧服务默认显式不支持）、manualFaces能力及editPhotoFaces命令；结果仍复用photos/completedCount。macOS与共享Apple Repository实现个人空间；iOS/iPadOS共享声明但无新UI且未构建；Windows/Android仅记录待迁移，不改代码。没有存储、依赖或工具链变更。回滚可移除入口和增量声明/方法，不回退已保存NAS状态；原图无变化，人物标记可在网页恢复。

权限、照片身份、原始人脸/目标人物快照和唯一操作编号保留；新增编号不能与旧脸冲突或错配裁剪图。未知新增回执不按同名追认，丢失上传回执只接受明确新编号下完全一致的图像，否则保留待核对且不重传。部分回执只上传明确返回项；缺新增项时不移除旧框。编辑完成局部更新照片详情，月份/选择/预览保留。真实NAS为PENDING_USER_VALIDATION，功能按实际权限/能力开放，无待实测人工禁用；版本证据仍static。


### 2026-09-29 预览重建NAS分支增量

共享契约新增previewRegeneration能力与regeneratePreviews照片快照命令，结果沿用photos/completedCount。macOS个人/共享空间选择照片后确认，依实际目录管理权限执行；Network先订阅EIO4完成事件，再标记并发起NAS重建，按明确照片编号确认结果并回读身份。明确失败才恢复对应重建标记，未知不重放；部分成功局部更新，保留月份/选择并重新读取已打开的预览。无待实测人工白名单。

macOS及共享Apple网络实现本轮NAS分支；iOS/iPadOS共享新增枚举，无新UI且未构建；Windows/Android记录命令、权限与通知生命周期迁移影响，未改代码。无依赖、持久化、签名或工具链变更；回滚移除新增入口/命令/事件通道即可，不自动撤销NAS已完成的预览。Socket.IO使用官方查询令牌机制，完整URL和含URL的底层错误不得进入日志；证书、同源重定向规则沿用现有实现。

完整网页对齐尚未完成：本机图像/视频转换及ConvertedFile上传、通知中断后完整恢复仍待实现。NAS实际转换、反向代理路径及照片/视频格式覆盖为PENDING_USER_VALIDATION，需用户用测试照片/视频确认成功、失败和断线行为及原件/月份保留；失败回传脱敏步骤与提示，不包含真实内容或连接资料。精确测试命令和结果见MACOS_PHOTOS_PARITY_20260929_ZH.md；静态脚本/合成测试不代表真实版本兼容。


### 2026-09-29 收集默认目录选择契约增量

SynologyPhotosAccess新增canManageSharedSpace，旧初始化默认false，来源为Photos共享空间已启用且team_space_permission=management。macOS按个人优先选择收集默认空间，共享管理者可自动目录，entry必须明确选目录；从目录发起或编辑保留原目标，提交沿既有真实上传权限、确认、去重和结果核对。共享Apple领域/Repository增量已实现；iOS/iPadOS未接新UI且未构建，Windows/Android仅记录未来迁移影响、未改源码。无API参数、存储或工具链变化；回滚移除字段/UI逻辑即可，NAS记录不受影响。真实NAS目录建立/访客上传为PENDING_USER_VALIDATION，无人工待实测禁用；证据及命令见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 本机预览转换与上传增量

共享Apple Network新增SynologyPhotosPreviewConverter，使用系统ImageIO与AVFoundation生成图片/视频三档JPEG预览；Repository增量发现Foto/Fototeam.Upload.ConvertedFile v3，复用现有regeneratePreviews命令。PNG优先本机，NAS明确失败/尚未连接时可本机处理；临时原件随处理结束删除，转换前后核对身份权限，上传未知不重放，成功局部更新。无新第三方依赖、公开领域契约或持久化格式变化，未重新编码完整视频。macOS实现并构建；iOS/iPadOS共享源码但未新增界面且未构建；Windows/Android仅记录其平台媒体转换与上传适配待办，未改源码。回滚移除本机转换与候选发现即可保留NAS分支，原件无修改。真实NAS上传/格式覆盖为PENDING_USER_VALIDATION，无人工待验开关；证据与命令见MACOS_PHOTOS_PARITY_20260929_ZH.md。

### 2026-09-29 共享分类浏览契约增量

macOS相册页接入共享人物/主题/地点/标签分类、对应照片及封面，空间选择/返回/分页保持来源，entry权限转文件夹。Apple共享服务新增带space的分类读取重载，集合space默认personal；旧方法兼容，无存储迁移或新依赖。缓存按空间与分类隔离同编号。iOS/iPadOS仍调用既有个人入口，新共享重载供后续原生流程使用；Windows与Android记录同等来源/权限/分页语义，本轮未改其代码或界面。共享人物写管理、共享来源相册/条件源、跨空间移动仍未完成；接口static证据不提升实机兼容等级。聚焦验证和用户验收步骤统一见MACOS_PHOTOS_PARITY_20260929_ZH.md的共享分类浏览波次。

### 2026-09-29 共享人物管理契约增量

macOS共享人物改名/合并/显示隐藏/人脸整理/封面及图片内手工人脸接入，命令由集合space或照片ID固定来源；读写/回读/裁剪上传均沿同一空间，混合空间目标写前拒绝，同编号缩略图隔离。共享人物管理需真实management权限、人物启用设置及对应API能力，无待实测白名单。Apple服务新增带space的人物管理/显示读取重载，个人旧调用兼容；iOS/iPadOS尚无新增UI，Windows/Android只记录适配计划，未改五端存储。真实NAS写验收仍PENDING_USER_VALIDATION，static证据不升级。具体命令、测试包和剩余功能见MACOS_PHOTOS_PARITY_20260929_ZH.md共享人物管理波次。

### 2026-09-29 相册照片来源契约增量

macOS条件相册新增个人/共享来源选择与独立草稿，条件建议增量重载conditionSuggestions(keyword:in:)；旧调用默认个人，共享按user_id=0与实际management权限接入。普通相册的创建/加入/移出/封面命令从照片身份固定来源，允许统一相册中的混合来源成员逐项预检；相册列表及照片走统一Foto接口，owner_user_id=0保留共享照片身份，封面带album_id授权。无照片目标的普通相册命令不依赖个人空间开启；共享照片上传后沿既有队列加入相册。

iOS/iPadOS共享Apple Package兼容旧签名，新增重载默认显式不支持共享，实际Repository已实现；未新增移动UI。Windows与Android需适配条件来源、统一相册入口、逐项来源预检和回读，当前仅记录影响，未改其代码、存储或构建。静态证据不提升NAS验证等级，真实验收为PENDING_USER_VALIDATION；具体本地验证、测试包与剩余范围见MACOS_PHOTOS_PARITY_20260929_ZH.md本轮记录。他人相册协作权限、跨空间移动与队列恢复不以本轮源码构建代替完成。


### 2026-09-29 相册上下文读取契约增量

共享Apple领域SynologyPhoto新增可选albumContext(albumID,ownerUserID)，构造参数默认nil，旧调用兼容、无持久化变更。macOS相册列表→项目→详情→缩略图/视频/实况/原件保存携带同一相册编号，走统一Foto读取；没有原空间权限仍由NAS按相册授权处理，拒绝不回退原件路由。Photos已启用但个人/共享空间均关闭时仍可浏览相册/与我共享，原空间管理按钮按实际能力保持无权限。详情校验来源身份，刷新授权丢弃在途内容；相册查看不赋予他人个人原件写权。

iOS/iPadOS共享Repository得到读取修正但未新增UI或运行移动构建；Windows/Android后续需在自身媒体模型保留相册上下文、作用域和读取/写权限分离，本轮仅记录影响，未改其源码。真实NAS和受限分享角色验收PENDING_USER_VALIDATION；仅static证据与本地合成验证，不宣称版本兼容。相册协作添加/上传及角色按钮、跨空间移动和队列恢复仍未完成，具体测试及测试包见MACOS_PHOTOS_PARITY_20260929_ZH.md本轮记录。


### 2026-09-29 相册协作契约增量

Apple共享服务增量albumAccess/addableAlbums及uploadToAlbum，照片上下文增量可选providerUserID；不改变持久化。macOS按所有者/查看/下载/贡献角色开放入口，贡献者通过相册目标直接上传、仅移除本人提供的成员，上传队列切页保持目标；源照片加入相册仍独立检查访问权。权限刷新失败不沿用旧角色，原件修改和相册成员管理分离，最终状态回读和去重保留。

iOS/iPadOS仅共享模型与Repository增量，不新增移动界面，本轮未运行移动构建；Windows/Android仅记录等价契约影响，后续分别实现原生交互，无源码变更。私有接口static与合成测试不构成真实版本兼容；PENDING_USER_VALIDATION需核对角色、provider、上传/移除/部分失败。具体自动化与测试包以MACOS_PHOTOS_PARITY_20260929_ZH.md本波次记录为准。跨相册转加无原空间项目、跨空间搬移、其他混合批量编辑、预览恢复、上传持久化及分类拼图/相似项目仍未完成。


### 2026-09-29 相册间添加来源语义更正

官方静态操作栏表明：原空间启用时，本人provider可将相册项目添加到已有目标或新建相册；其他下载角色不等于添加权，混合来源另需共享管理权。原空间关闭时只提供移除成员，先前把无空间跨相册转加列为缺口不准确。macOS与Apple Repository已按source album_id重新核对快照及provider，再用既有目标id/passphrase和item提交，不新增来源写参数或公开契约。原件owner与provider分离，仅添加成员不授予原件写权。iOS/iPadOS共享Repository受影响但无界面修改或移动构建；Windows/Android仅同步语义计划，不改源码。真实NAS仍PENDING_USER_VALIDATION，不提升static证据等级。剩余跨空间移动/批量编辑、预览中断恢复、上传持久化与分类拼图/相似项目继续推进，详细命令与测试包见MACOS_PHOTOS_PARITY_20260929_ZH.md本波次。

### 2026-09-30 macOS Photos跨空间移动与复制

共享Apple领域move/copy增量加入可选destinationSpace，省略时保持原空间；macOS已接入目标空间/目录选择，个人→共享移动及个人↔共享复制，来源与目标权限分别核对，任务回执匹配目标目录/owner/total并回读完成状态，未知只查已知任务、不重放。跨空间不沿用旧原件编号推断成功。完整完成后当前列表按旧身份局部更新，不刷新到最新月份；混合来源批量仍待补。

五端影响：macOS实现本轮完整流程；iOS/iPadOS共享包保持调用兼容，目标选择及触控转换按专项计划后续实施；Windows/Android记录等价契约依赖，不改本轮界面或存储。无新依赖、标识或权限变更。官方端点证据static、真实NAS为PENDING_USER_VALIDATION；源码、回归与测试包证据见[本轮账本](../development/MACOS_PHOTOS_PARITY_20260929_ZH.md)。未把其他平台验收或真实NAS写入表述为通过。


### 2026-09-30 混合来源编辑与相册原位更新

macOS 已接入个人/共享混合评级、绝对/相对日期和预览重建；先检查两空间能力及共享管理权，每张照片仍检查原件权限，按来源分发、回读，部分完成只继续原快照中的剩余项。跨空间移动后按相册已加载范围重新读取新身份，短暂失败自动重试，不刷新整个照片库；最终读取失败保留内容并允许只读重试，导航取消隔离。

官方 static 证据更正：混合标签不可用，普通/共享相册菜单没有混合移动复制，因此两项不应继续计为网页待办。五端影响：macOS 完成本切片；iOS/iPadOS 共享 Apple 计算属性及 Repository 增量，无存储/调用签名变更，无移动界面修改或构建；Windows/Android 后续按原生交互实现分来源批量及部分结果，不修改本轮源码。实际验证、风险及测试包见 MACOS_PHOTOS_PARITY_20260929_ZH.md 本波次，未提升真实环境兼容等级。剩余代码组为预览通知/队列恢复、上传持久化恢复（授权待答复）和分类拼图/相似项目；真实 NAS 另列 PENDING_USER_VALIDATION。


### 2026-09-30 预览通知短暂断线恢复

Apple共享Photos事件通道增加已订阅任务的自动重连：最多三次1/2/3秒退避，总等待期限不延长，只握手并重新注册原照片编号，不重发重建/标记/上传。拒绝连接、证书错误、非法帧、超时和取消停止；完整结果仍由明确事件与Repository身份回读核对。macOS使用该通道；iOS/iPadOS共享实现受影响但本轮无移动UI或构建，Windows/Android仅记录等价恢复语义，不改源码。无公开签名、持久化、权限或工具链变更。真实NAS待用户验证、静态接口证据不升级。list_regenerating未完成队列与丢失事件补查仍未完成，不能把该子项视为整个恢复组完成。测试和包证据见MACOS_PHOTOS_PARITY_20260929_ZH.md对应波次。


### 2026-09-30 未完成预览队列恢复

共享Apple契约增量pendingPreviewRegenerations(in:)只读方法（旧服务显式unsupported）和regeneratePreviews默认false的resuming参数；领域无存储格式变更。macOS新增工具栏恢复面板，读取个人/共享未完成队列、选择确认继续，准备/提交两次核对队列与原件，初次恢复不重复set_regenerating。已丢失通知的原操作自动检查提交前新鲜版本基准、原件身份、新版本及队列无目标；不以队列消失单独认定完成，未知不重放，部分完成只重试剩余目标。读取失败不清空原写入记录。

五端影响：macOS完成原生入口与Repository恢复；iOS/iPadOS共享声明/实现受影响，原调用省略resuming继续普通重建，模式匹配需适配新增关联参数，无移动UI/构建；Windows/Android仅同步等价队列与核对语义，没有本轮源码改动。依旧static/PENDING_USER_VALIDATION，不把合成证明当真实NAS兼容。当前主要剩余代码为上传跨重启持久化（授权待答复）及分类拼图/相似项目，具体命令、失败修正与包见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-30 Photos 分类首页拼图增量

共享Apple服务新增categoryPreviewImages只读方法，默认显式不支持；Repository按所选空间读取最多4张分类缩略图，不改变持久化或完整分类封面缓存。macOS卡片显示拼图，失败保留可点击占位。iPhone/iPad暂不新增界面；Android、Windows仅同步未来等价读取语义，不修改代码。人物show_more、不读取隐藏人物，视频type=video，个人/共享来源和权限独立；原生显式空间选择不采用网页跨空间回退。真实NAS封面为PENDING_USER_VALIDATION，static证据不提高验证等级。相似项目仍待完整分组契约与实现；上传跨重启持久化授权待答复。


### 2026-09-30 相似照片分组浏览增量

macOS 新增 Similar/SimilarItem/SimilarTimeline v1 的分类、月份分页和组内预览，显示推荐项与数量，按实际权限/enable_similar 开放。共享 DsmCore 增加分组模型和只读服务默认实现；iOS/iPadOS 仅补齐穷尽枚举编译分支，分类入口保持原范围，移动端功能不在本轮交付。Android、Windows 仅记录影响，不修改实现。分组管理操作仍待后续；无工具链、存储、标识或凭据变更。静态证据不代表 NAS 行为兼容，实测为 PENDING_USER_VALIDATION；具体契约见 `docs/api/discovery/endpoints/photos-similar-items.md`，自动化与交付见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`。

2026-09-30 后续：macOS相似组推荐设置、移出、拆组及会话撤销已接入既有mutation流程；共享新增similarGroups/editSimilarGroup和结果similarGroup，按原件/目录权限、成员快照、operationID与双重回读保护，未知不重放。撤销不能覆盖其他组，也不会将旧月份照片插入新月份。iOS/iPadOS无新增UI，Android/Windows仅记录同等语义；没有持久化变更。真实NAS仍PENDING_USER_VALIDATION，保留所选删除其他仍待接入。


### 2026-09-30 相似照片清理、批量与识别状态

macOS新增保留所选删除其他（确认固定补集、原件自动核对、分组原位只读刷新）、主列表多组拆分及会话批量撤销、get_status识别运行/等待状态。批量未知暂停后续，不重放，核对成功后继续；失败可取消剩余，撤销仍拒绝覆盖其他组。月份位置按查询保留。共享Apple只读服务增量similarGroupDetails/similarStatus及状态模型，旧Adapter默认显式unsupported；iPhone/iPad无新UI，Windows/Android仅记录后续等价语义，无本轮源码变更。无持久化、依赖、权限或标识变更；私有API仍static，真实NAS为PENDING_USER_VALIDATION，入口按实际权限/能力开放。当前已核实代码缺口为上传队列跨重启恢复，存储授权待答复；合成/构建与测试包证据见MACOS_PHOTOS_PARITY_20260929_ZH.md文末，不以合成测试提升兼容等级。


### 2026-09-30 Photos压缩下载及剩余清单更正

Apple只读契约新增SynologyPhotoDownloadFormat和download(format:)返回实际格式，原downloadOriginal兼容；macOS所选/预览/右键提供原件与压缩JPEG，按真实结果命名、原格式保留提示、同名另存，相似组下载全部成员。沿Download v2与相册授权，检查完整内容、原件保留和权限代次，无存储/工具链变化。iPhone/iPad无新界面，Android/Windows只记录等价语义。本轮仍static/PENDING_USER_VALIDATION，证据及包见MACOS_PHOTOS_PARITY_20260929_ZH.md。新一轮真实网页菜单审计发现整相册/文件夹下载、特定格式原尺寸JPEG转换及幻灯片仍有缺口；此前仅列上传跨重启恢复的清单不完整，以上加入后续，不能宣布全量完成。


### 2026-09-30 Photos整相册与目录归档

Apple共享只读契约增量加入SynologyPhotoArchiveTarget和downloadArchive，默认unsupported保持旧适配器兼容；macOS接入完整普通/条件/协作相册及个人/共享目录原件或压缩JPEG ZIP，按真实权限开放，取消/失败保留原本地文件，不改变月份。无NAS写入、持久化、依赖或标识变更。官方静态证据与回归不等同真实NAS验收，详见photos-library-read.md及MACOS_PHOTOS_PARITY_20260929_ZH.md。当前没有新增已知DSM/build/套件兼容环境，真实归档大小/ZIP64/下载受限协作角色均PENDING_USER_VALIDATION；拒绝后不回退File Station。


### 2026-09-30 macOS Photos幻灯片

macOS新增独立全屏播放、三秒照片计时、视频结束推进、暂停/恢复、前后循环和键盘退出；按现有只读照片查询独立分页，保留图库月份/选择，不要求下载权限。相似组预览按组成员播放，出错暂停、离开取消。没有新增共享契约、存储、NAS接口或其他端UI；iPhone/iPad/Android/Windows保留当前范围，不能以macOS实现宣称五端完成。官方静态证据与本地验证见MACOS_PHOTOS_PARITY_20260929_ZH.md；真实NAS和系统全屏/多显示器行为PENDING_USER_VALIDATION，无人工未实测禁用。


### 2026-09-30 Photos原尺寸JPEG

共享SynologyPhotoDownloadFormat增量增加originalSizeJPEG，SynologyPhotosAccess增加默认false的实际转换能力，旧调用和原件下载默认实现兼容；无持久化、依赖、工具链或权限变化。macOS单张菜单按HEIC/TIFF/RAW、NAS两项设置与下载权限开放，先convert v2成功再下载原尺寸JPEG，校验结果后同名另存；批量归档不支持此单项格式。相册统一Foto，协作者口令仅进POST体；取消不重放转换，不承诺撤回NAS派生缓存。详细契约及用户验证见photos-library-read.md和MACOS_PHOTOS_PARITY_20260929_ZH.md。iPhone/iPad仅共享包兼容扩展，移动导出入口后续另定；Windows需按此语义接系统保存，Android仅记录影响，均未修改界面或宣称完成。static/合成验证不能代替NAS验收，不新增人工未实测功能禁用。


### 2026-09-30 Photos文件夹封面

共享Apple契约增量增加folderCover、setFolderCover(folder:photo:)和folderCoverImages；默认读取实现返回unsupported，沿已授权契约扩展，无持久化/依赖/标识变化。macOS提供目录/单选/右键/预览入口及固定目标的子目录选图窗口，显示默认拼图和自定义封面；按实际目录管理权和来源查看权开放。Folder.set_cover v2单元素数组，成功回执加自定义封面可读共同确认，读失败自动核对、写回执未知不重放，保留图库月份和选择。公开枚举增量需适配穷举，但不改变现有命令语义；其他端界面没有修改，不能以共享包构建代替五端完成。证据static，验收PENDING_USER_VALIDATION，详细契约和限制见photos-management.md、photos-library-read.md及MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-30 Photos目录排序

Apple共享模型增加SynologyPhotoSort，folder查询追加带默认值的排序参数、集合追加可选sort，Serving增加folderSort和带方向的folders读取，命令增加setFolderSort（folderSorting特性）。旧查询构造不变，旧模式匹配需要接收第二个参数；旧目录读取保持升序，未适配的新能力明确unsupported。macOS封面选择器接入四字段/两方向，按Folder.set_order v1保存并严格回读；每页请求排序，当前图库目录同步重排，保留目录和选择，不影响其他相册。实际view权限即可改浏览偏好，设置封面本身仍需manage。无本地持久化、依赖或权限配置变更，沿已授权契约扩展；static与合成验证不代替NAS兼容，PENDING_USER_VALIDATION。完整证据及回滚（移除本轮排序入口/增量契约，不影响照片原件）见照片对齐账本及photos-management.md。

Windows、Android仅记录等价行为和契约影响，本轮未修改界面、未执行目标端构建。iPhone/iPad目录封面编辑及其排序继续属于后续范围；现有目录浏览保持，后续用触控菜单/系统返回，两者同范围，不照搬桌面菜单；共享包扩展不代表移动功能已经交付。


### 2026-09-30 Photos目录重命名与图库排序入口

共享Apple命令增量renameFolder(folder:name:)，继续沿folders能力，公开名称校验与网页规则一致；已授权契约扩展，无持久化/标识/依赖变化。macOS目录卡片打开固定目标表单，重新检查身份/manage，rename v1后按完整新路径及id/parent自动回读；未知只查不重发，局部更新卡片/面包屑/后代路径，保留月份与选择。同编号相册/其他空间隔离。主目录页接入已有四字段/两方向排序，包含根目录；封面窗口复用同一菜单。源码与合成测试不代表NAS验收，PENDING_USER_VALIDATION步骤和回滚见MACOS_PHOTOS_PARITY_20260929_ZH.md、photos-management.md。

Windows/Android仅同步共享契约与等价语义影响，本轮未改其UI或运行其目标端构建。iPhone/iPad目录重命名及排序编辑继续为后续范围，未来用触控菜单/系统返回，现有浏览不变；共享包可编译不等于移动功能交付。剩余目录删除、目录移动复制、共享目录权限分享，以及待授权的上传重启恢复仍未完成。


### 2026-09-30 Photos多文件夹与混合删除

共享Apple增量folderDeletion、deleteFolderItems(photos:folders:)及默认空的deletedFolders/deletedPhotoIDs结果；既有删除策略由macOS组合根显式开启，其他端不自动获得UI入口。macOS目录选择/混选确认固定目标，重新核对原空间、目录路径/父级/管理权和照片身份；按官方BackgroundTask.File.delete v1(item_id,folder_id)主流程提交。任务完成无错误后完整父目录分页及照片空回读共同确认，成功原地移除/修正分页；进入已删目录时回父目录。未知回执不重放，任务部分失败缺少逐目录结果时不猜测哪些目录已删除。纠正旧Browse.Folder.delete候选；详见photos-item-deletion.md与照片对齐账本。

无依赖、标识、权限配置或持久化变更，沿已授权契约扩展；回滚移除本轮多选/删除命令和入口，不撤销已经在NAS发生的删除，真实恢复取决于NAS回收站。static与合成测试不是行为验收，PENDING_USER_VALIDATION操作、风险和脱敏回传见端点记录。Windows/Android只记录等价流程，本轮不改UI或运行其构建。iPhone/iPad目录管理仍是后续范围，未来通过触控选择/原生确认，两者同范围；共享包增量不等于已交付。目录移动复制、共享目录权限分享、多目录/混合整批下载及待授权的上传恢复仍有缺口。


### 2026-09-30 Photos文件夹移动复制

共享Apple move/copy命令末尾增加默认空folders关联值，既有调用兼容、模式匹配同步；macOS同一目标弹窗接入多目录和照片混选，固定来源空间、父目录与完整路径，写前重新检查身份/权限和自身后代冲突。沿官方BackgroundTask.File v1 folder_id及move extra_info.source_folder_ids，统一Info回读目标空间/目录、递归任务total和完成状态；丢失回执不重放，部分失败不猜哪些目录成功，重复项沿skip。完成后局部更新/保留原父目录，复制保留来源；核对期间进入来源时内部刷新回父目录，修复移动/删除共用忙碌刷新问题。

已授权契约增量，无存储/签名/依赖变化。Windows/Android仅同步等价语义与契约影响，不修改UI或运行其构建；iPhone/iPad目录管理仍为后续，不把共享包兼容编译写成已交付，两者未来都采用触控选择与原生目标浏览。static与合成证据不代替NAS行为验证；PENDING_USER_VALIDATION步骤、回滚与未知结果处理见photos-management.md及MACOS_PHOTOS_PARITY_20260929_ZH.md。剩余共享目录权限分享、多目录/混合整批下载、拖放移动及重复项设置细节、待授权的上传重启恢复仍需继续。


### 2026-09-30 Photos共享目录权限读取基础

Apple共享包新增SynologyPhotoFolderSharingState及默认兼容的folderSharing/folderSharingRecipients，区别management/private/public-view/public-download、未知成员/密码状态与父级限制。macOS目录右键/当前目录页可只读查看成员角色、链接和保护状态；打开与刷新不创建分享或更新权限，固定目录和父目录身份、共享完整访问权与授权代次。保存/成员修改/密码修改及应用到所有子目录仍待后续接入，不是禁用已实现功能，也不算完整对齐。

内部静态契约与候选写方法见photos-management.md；无真实NAS写入，版本未知，PENDING_USER_VALIDATION只覆盖本轮读取与显示。Windows/Android仅记录对应语义影响，无UI改动或目标端构建。iPhone/iPad目录权限仍为后续范围，不把共享包编译记为移动端交付。无存储、签名或依赖变化，回滚移除新增读取类型/方法/面板即可，无NAS数据恢复需求。


### 2026-09-30 共享目录权限保存增量

共享Apple契约新增folderSharing管理能力和setFolderSharing(original,access,members,password,appliesToSubfolders)命令；默认服务读取接口沿前轮，无存储迁移。macOS实现四种访问范围、成员增删/四种角色、保留/新密码/移除保护、首层子目录选项、固定快照确认与自动结果核对，按真实FotoTeam接口和共享管理角色开放，不增加未实测禁用。未知成员不改名单，旧密码不读取；HTTPS无降级。更新与默认配置分别校验，默认值失败返回部分完成；回执未知不重复写，子目录应用和新密码不能只凭顶层旧状态确认。

Android/Windows仅同步适配要求，不改界面或代码；iPhone/iPad目录权限管理仍为专项计划“后续”，不是本轮待真机功能。其他Apple适配器无需实现新只读默认方法；如果穷举共享命令/能力须新增分支，已检查当前调用点，macOS回归覆盖共享Package。未运行其他端构建。真实NAS权限行为为PENDING_USER_VALIDATION，证据仍static；完整验证和测试包见MACOS_PHOTOS_PARITY_20260929_ZH。回滚移除本轮命令/能力/保存控件，已有查看与相册分享保留；NAS已保存权限需用户用原快照恢复，不能靠回滚App撤销。


### 2026-09-30 多目录与照片混选ZIP下载增量

已授权的共享Apple归档目标增加selection(photos,folders)，不改原有album/folder接口和持久化。macOS工具栏/已选项目右键固定整组选项，下载完整子目录及同级照片，原件/压缩JPEG、取消和失败恢复复用现有流程，保持当前目录与选择。权限和身份全部检查后发送单次Download v2；当前未增加人工未验证禁用。

Windows/Android仅同步同级混选、完整后代、单次归档与权限/取消/不覆盖要求，不修改其代码或声明构建通过。iPhone/iPad目录批量管理仍为专项计划“后续”，共享枚举新增不等于移动入口已交付；未来采用触控多选与系统文件导出，不照搬桌面右键。当前共享调用点已检查，新增枚举须在未来穷举时处理。无依赖、签名、系统权限或存储迁移；回滚移除此枚举分支、预检和菜单分支，原单目录/相册下载保留。真实NAS内容和权限验收PENDING_USER_VALIDATION，static及合成验证见photos-library-read.md与MACOS_PHOTOS_PARITY_20260929_ZH.md；未验证其他平台构建。


### 2026-09-30 macOS文件夹拖放移动

macOS文件夹页增加单项/混选拖动、可见目录/上级按钮/路径导航接收、固定来源与目标的预选确认。只传当前Model的一次性UUID，ownProcess且不含路径或凭据；刷新/跨Model/自移动/原目录/后代或无权限目标拒绝。沿既有移动协议、NAS预检、任务去重与结果核对，无共享契约、存储、依赖或系统权限变化。

Windows未来可对应WinUI原生拖动反馈和同等确认；Android保持已有原生选择操作，不直接照搬桌面鼠标交互。iPhone/iPad目录管理仍为后续，本轮只记录基准交互，无任何其他端代码或构建结论。真实NAS与物理拖放PENDING_USER_VALIDATION，合成测试/预选表单不等于实机通过。回滚移除拖放修饰器、一次性快照及预选路径即可，原有移动复制菜单保留。默认重复项设置及overwrite执行仍是剩余功能。


### 2026-09-30 Photos重复项默认设置与操作规则

已授权共享Apple契约增加SynologyPhotoDuplicateSettings、duplicateSettings()默认不支持方法、setDuplicateSettings命令及能力；upload/uploadToAlbum和move/copy末尾增加带默认值策略，旧构造分别沿rename/skip，模式匹配增加一个关联值；结果skippedCount默认0。macOS读取NAS当前默认、单次调整、确认覆盖、队列冻结策略与忽略状态区分，设置保存原快照校验和自动回读，真实接口权限仍保留，无人工未验证禁用。

内部Setting.User get/set v1证据static，真实NAS行为PENDING_USER_VALIDATION。当前无本地持久化、工具链、签名、依赖变化；不等于五端UI完成。回滚移除本轮设置入口/增量契约及策略参数，恢复原rename/skip行为，旧已排队操作不重放；不会自动改回NAS已保存偏好。证据、验证、验收步骤见MACOS_PHOTOS_PARITY_20260929_ZH.md和photos-management.md。


### 2026-09-30 相册内照片排序增量

共享契约新增albumSort、setAlbumSort(original,sort)，album query带默认sort保持旧调用行为。macOS从NAS读取当前相册顺序，原生菜单支持四字段与升降序，统一分页、原始快照冲突检查、同操作去重与最终明确字段回读；未知结果只核对，个人空间关闭但相册可查看仍开放。上传及搬移后沿已选择排序刷新当前相册，不回时间线。官方证据仅static，真实NAS保存/排序为PENDING_USER_VALIDATION，不因未实测禁用。

五端：macOS本轮实现；Windows记录等价列表菜单/分页/回读适配；iPhone/iPad不改变本轮范围（未来触控菜单，无桌面悬停）；Android仅记契约影响，不改其他端UI。没有本地存储、权限、依赖或工具链迁移。回滚客户端增量不撤销NAS偏好，可在网页重新选择。相册列表显示/排序与分享列表排序仍未接入，上传重启恢复仍待持久化授权，不能将本轮构建等同完整对齐。详细证据及验证命令见MACOS_PHOTOS_PARITY_20260929_ZH.md文末。


### 2026-09-30 相册列表偏好与分享排序

macOS新增全部/我的相册范围、相册首页及两类分享列表各自排序，读取已有NAS偏好，固定条件分页，原值冲突拒绝覆盖、去重和保存后回读；未知不重发，不改相册内容/共享权限。共享领域和服务增量扩展，旧列表调用语义保留，新参数默认适配器明确不支持，不静默忽略。Album偏好v2/v3分别探测，home关闭仍开放实际可用能力，NAS实际验证由用户完成，没有人工未验证禁用开关。

五端影响：macOS本轮实现；Windows后续用原生菜单保留相同范围/分页/回读；iPhone与iPad的等价触控排序记为后续专项取舍，不扩张本轮UI范围；Android仅记契约影响。不改变其他端UI、本地存储、权限、依赖或工具链。回滚移除客户端增量，不删NAS偏好。PENDING_USER_VALIDATION步骤与静态证据见photos-management.md及Photos对齐账本，不将构建当作NAS行为验证。


### 2026-09-30 macOS 预览旋转保存增量

共享Photos契约新增rotation能力与rotatePhoto单张命令，SynologyPhoto增加原始方向及支持旋转/动态播放计算属性（可选字段默认nil，旧调用兼容，无存储格式变化）。macOS预览逆时针90°保存到NAS，个人/共享Item.set v2；真实权限与媒体条件、快照比较、操作编号去重、自动只读结果核对，回读更新当前照片而不刷新图库。方向1–8镜像映射及宽高交换按官方static证据，原件字节副作用仍待用户验证。无“未验证”禁用。

五端：macOS实现与回归；iOS/iPadOS共享包被动增加向后兼容类型，不新增界面，本轮仅记录候选交互：照片预览工具栏或菜单旋转，仍需各端专项范围确认；Windows记录预览菜单等价语义；Android仅影响记录，不改源码。真实NAS/手势PENDING_USER_VALIDATION不等于其他端已实现。本轮不升级工具链、不改Bundle ID/权限/持久化、不正式发布。


### 2026-09-30 主题分类显示管理契约增量

macOS新增conceptVisibility读取、setConceptVisibility命令与独立结果字段，个人/共享固定空间，隐藏/恢复只更新主题卡片并自动核对，不删除照片。共享Apple服务默认unsupported实现保留源码兼容；iPhone/iPad高级分类管理仍属后续，不新增UI或标成待真机核心项。Windows/Android记录待适配，不修改实现。公开契约扩展已有用户授权，无持久化/最低系统/依赖变更，移除本轮接口及入口即可回滚。Concept v2的官方证据为static，真实NAS权限、隐藏恢复及断网核对为PENDING_USER_VALIDATION；不能把本地合成测试写成五端行为兼容。


### 2026-09-30 主题封面/误分类移除契约影响

共享Core增量提供conceptState、可选displayThreshold、setConceptCover/removeConceptItems及独立移出结果。默认服务unsupported与可选字段保留源码兼容；macOS新增分类多选和预览入口、阈值提示、写后自动核对并局部更新。Windows/Android待适配；iPhone/iPad高级分类管理仍为后续，不扩大核心范围或改UI。无存储/依赖/权限格式改变；回滚移除新入口/命令。真实NAS原件保留、低于阈值与连拍封面行为PENDING_USER_VALIDATION，不以static或本地测试宣布五端兼容。


### 2026-09-30 照片显示偏好增量影响

macOS新增日/月分组、九种日期格式、12/24小时、默认目录排序及预览/幻灯片底部信息；Setting.User get/set v1，严格快照和差量保存、自动只读核对。共享access增量可选displaySettings，旧调用不变。Windows后续按原生控件实现等价结果；iPhone/iPad保持专项范围，本轮不新增界面与DAG任务；Android仅记录接口变化。无新增持久化、权限或依赖。真实NAS为PENDING_USER_VALIDATION，static不等于行为验证；实际命令与结果见macOS照片对齐账本。


### 2026-09-30 个人照片识别设置增量

macOS接入人物/主题/相似照片个人开关，User get/set v1和Admin get v1，真实个人空间/全局条件、快照、差量保存及自动只读核对；局部更新个人分类，共享分类不变。共享服务增量默认不支持，Windows后续原生设置适配；iPhone/iPad沿专项范围，本轮不新增界面/DAG，Android仅记录影响。无本地存储、依赖或权限变化；static与PENDING_USER_VALIDATION不等于NAS行为验证，自动预览仍需完整触发流程。验证命令和结果见照片对齐账本。


### 2026-09-30 自动预览只读候选基础

共享Apple服务增量automaticPreviewTasks(in:support:)及独立预览单元任务/转换能力类型，旧服务默认明确不支持；ConvertedFile.list_convert_needed v3，官方preset/type条件，个人/共享management隔离，取消/访问代次检查。只读，不下载或写入；自动转换执行、设置与调度仍待完成，不把本切片计为完整功能对齐。macOS尚无新增可见入口；Windows后续实现等价后台流程，iPhone/iPad保持专项范围，不新增移动端DAG，Android仅记录契约影响。无存储/权限/依赖变化，证据static，真实NAS为PENDING_USER_VALIDATION。验证命令和结果见照片对齐账本。


### 2026-09-30 自动预览原件与本机视频转换

Apple共享服务新增downloadAutomaticPreviewSource，默认明确不支持；Download v2单元读取前后核对候选，按空间权限、取消/访问代次和内容长度校验，不覆盖已有目标。本机AVFoundation导出H.264/AAC，合成MJPEG/PCM验证方向/时长/音轨与原件保持；无依赖或最低系统变更。完整自动上传/核对/调度/设置仍在实施，macOS尚无新增界面，Windows/Android仅同步影响，iPhone/iPad不新增专项范围/DAG。真实编码与NAS行为PENDING_USER_VALIDATION，不将测试扩大为全格式支持。具体命令见macOS照片账本。


### 2026-09-30 自动预览上传与结果核对

共享Apple增量管理命令generateAutomaticPreview与automaticPreview能力，沿既有操作编号去重/结果核对；三档JPEG及H.264/AAC通过ConvertedFile v3文件流式上传。明确同步回执确认，未知只读媒体摘要核对、不重放；候选消失不等于完成。个人/共享management隔离，源文件及临时媒体保护，真实NAS仍PENDING_USER_VALIDATION（视频回读档位绑定/缓存行为为标明的客户端推断，不能当兼容认证）。设置/调度/实际编解码能力采集/可见项优先尚待接入，未新增macOS可见入口或安装包；Android/Windows仅记录适配影响，iPhone/iPad不扩展专项范围或DAG。无持久化、依赖、权限或最低系统变更，回滚新增命令和执行逻辑即可；详细测试见macOS Photos对齐账本。


### 2026-09-30 自动预览设置与后台扫描

Apple共享服务/Access增加可选自动开关与读写命令，User.get/set v1仅更新auto_generate_thumbnail并核对结果。macOS新增中英设置、系统HEIC读取/H.264输出能力采集、照片页串行扫描、暂停继续、同批候选可见优先及未知退避核对，保留月份/选择。个人及共享management后台范围已接通；共享entry目录可见任务、批次外/实况优先仍未对齐，不将网格onAppear等同0.8可见阈值。真实NAS仍PENDING_USER_VALIDATION，已实现入口无人工实测开关；Android/Windows仅同步契约影响，iPhone/iPad不扩展专项DAG或UI。无本地持久化/最低系统/依赖/权限改变，回滚新增命令、worker与入口即可。实际测试和测试包见macOS Photos对齐账本。


### 2026-09-30 macOS可见照片自动预览契约增量

共享PhotosServing增加automaticPreviewTasks(for:support:)默认空实现，AutomaticPreviewTask增加sourcePhoto可选快照（旧初始化nil）；不改变原有后台候选调用。macOS按照片实际owner/目录download读取批次外候选，实况分单元，读取前后/提交前/未知结果复查共用原执行链，2秒去抖及跨来源去重。共享entry不获全库扫描权。无持久化、API新参数、依赖或权限变更。Windows、Android、iOS、iPadOS后续按平台前台可见/预览语义接入，当前不修改其界面；Apple共享库保持向后兼容并运行macOS回归。637项XCTest/6项本地化通过，真实NAS仍PENDING_USER_VALIDATION；证据及回滚见photos-advanced-management与macOS Photos账本本轮记录，不把本地合成测试提升为五端已实现。


### 2026-09-30 共享空间设置增量

photos-shared-space-settings新增内部TeamSpace get/set/set_enable v1，联读UserInfo/User/Admin。仅static及合成验证，当前DSM/套件版本未知；真实启停/分享影响与识别回读由用户验证。没有人工未实测禁用。 无新增存储、依赖或工具链变化；移除本轮入口/命令即可回滚。


### 2026-09-30 全局设置与转换缓存

新增photos-global-settings-cache稳定记录；未知DSM/build/套件版本保持static，verifications为空，不宣称当前NAS写入兼容。

契约为Photos Core/Serving增量设置/缓存读取和命令、MutationResult可选状态；复用Admin/User/TeamSpace v1与Download缓存v2，实际权限/字段/编解码条件开放，无待实测白名单。NAS实测按photos-global-settings-cache的PENDING_USER_VALIDATION由用户执行。无存储迁移、依赖、工具链或标识变更；回滚移除本轮入口及增量方法，保留已有图库和数据。验证结果统一见MACOS_PHOTOS_PARITY_20260929_ZH.md最新波次。


### 2026-09-30 共享成员与按成员目录权限（读取与领域规则切片）

Core/Serving增量加入共享成员快照、候选及两层目录权限分页，协议默认显式unsupported，既有实现源兼容。Repository独立回读DSM管理员身份，保留本人、用户/群组及数字/字符串ID区别；目录权限不要求成员姓名、不创建分享链接，未知角色保留，缺字段报错，访问代次变化丢弃旧结果。草稿遵循管理角色开启备份/降级保留备份及系统administrators群组保护；本轮尚无成员保存命令或原生入口，不把读取等同完整管理闭环。

五端：macOS继续接入确认、分阶段保存、自动核对与原生编辑器；Windows/Android仅同步后续适配，未改界面或执行平台构建。iPhone/iPad管理员共享成员设置继续属于后续非核心能力，不新增UI，也不以PENDING_USER_VALIDATION暗中扩大范围；可继续使用NAS网页管理。无新增存储、依赖、权限、工具链。公开契约沿用户已有增量扩展授权，回滚可移除新增协议默认方法/类型/实现，不迁移用户数据。

私有组photos-shared-space-members为static；真实NAS写入仍由用户在完整入口交付后验收，当前不能形成行为兼容结论。保存流程完成后验证新增/降级entry时目录授权、取消草稿零写入、部分失败与断网不重放、历史月份保留。完整余项仍见MACOS_PHOTOS_PARITY_20260929_ZH.md。


共享成员保存切片继续（2026-09-30）：Core新增setSharedMembers组合命令、目录批量/单项草稿和可选sharedMembers结果，Serving增加完整两层快照方法及unsupported默认实现。Repository按固定原快照分阶段提交，未知仅回读、明确失败核对部分应用，最后回读本人真实空间权限。未接macOS原生表单/Model轮询，不宣称完整入口可用；Windows/Android同步适配影响，iPhone/iPad管理员设置仍为后续，未改变其他端UI、存储或工具链。真NAS兼容未验证，静态证据与自动化范围见照片对齐账本和photos-shared-space-members。


共享成员原生入口完成（2026-09-30）：macOS已接入成员/角色/自动备份及按成员目录草稿、最终确认、分阶段保存、后台自动核对和本人实际权限更新，个人月份/选择保留，在途旧分页隔离。692项XCTest、6项本地化及2项原生UI通过，真实NAS为PENDING_USER_VALIDATION；无人工待实测禁用。本轮复用上一切片共享契约，无新增协议/存储/依赖。Windows/Android适配计划保持，未修改或构建其他端；iPhone/iPad管理员设置仍后续非核心，通过网页管理。详细范围/实际命令/限制见MACOS_PHOTOS_PARITY_20260929_ZH.md及photos-shared-space-members。


### 2026-09-30 自动预览完整相邻与格式顺序

Photos Core任务增量priority枚举：普通1、HEVC/实况视频2、VC1/WMV3为3、后台4；初始化保留默认参数，旧调用源兼容，无持久化变更。Network依据已读取的编码/单元来源赋级，macOS按级升序并在同级保持当前、后3/前2、可见顺序，先按网页小集合缩减再排除相邻视频。只使用已加载照片，分页缺口不循环、不为预取主动改月份；后台候选和权限/去重/结果核对保持原流程。完整验证与未验证限制见MACOS_PHOTOS_PARITY_20260929_ZH.md最新波次。

五端影响：macOS接入；Windows/Android未来对应自动预览调度须映射相同优先级，当前未改或构建二者；iPhone/iPad不新增桌面后台转换能力，后续规划范围不变，仅共享Apple模型向后兼容。没有新增API写方法、系统权限、依赖、工具链或存储。回滚本轮priority映射及调度即可恢复原处理顺序，不迁移或删除NAS内容。真实编码/预览结果与物理浏览体验交由用户验证，不设人工待实测禁用。


### 2026-10-01 当前空间整库维护契约增量

Core新增SynologyPhotoLibraryMaintenanceStatus、libraryMaintenanceStatus(in:)默认unsupported与maintainLibrary命令；用户此前已授权契约扩展。macOS按个人/共享空间接入Index get/reindex v1、basic/thumbnail动作；确认固定空间，真实管理员及H.264条件、重复提交保护和自动读状态，不刷新历史月份。证据static；明确回执与计数归零结束本阶段核对，丢失回执无任务ID可能长期未确认，不重发或推断全部后台阶段完成。详见photos-library-maintenance及Photos对齐账本。

五端影响：macOS实现原生入口；Windows/Android需在各自维护能力实施时映射相同语义，本轮未修改界面或运行构建；iPhone/iPad整库管理员维护仍为后续范围，不因为共享协议增量新增移动端入口或验收待办。Apple默认实现兼容既有服务；无存储/依赖/工具链变化。回滚本次入口、命令和读取协议即可，不迁移或删除NAS数据。真实NAS由用户验收，无待实测人工开关。全用户reindex_all_user欢迎流程仍未实现。


### 2026-10-01 新格式提示与全用户补预览契约增量

Core新增SynologyPhotoCodecPrompt、codecPrompt默认unsupported与respondToCodecPrompt命令，沿此前公开契约扩展授权。macOS接入新格式提示、稍后已读及按管理员身份分流的全用户/个人补预览。明确区分生成请求已接收和后台完成：不拿个人计数证明全用户完成；未知回执只核对、不重发，部分成功仅补保存提示，历史月份和选择保留。证据static，真实NAS为PENDING_USER_VALIDATION，无人工待实测禁用。

五端影响：macOS原生入口已接入；Windows/Android对应照片设置实施时需保持上述范围和结果语义，本轮不改界面或构建；iPhone/iPad全用户管理员维护仍属后续非核心，可通过网页管理，不新增移动验收待办。共享协议提供默认实现保持现有服务源兼容。无存储、依赖、工具链迁移；回滚新增入口、命令和读取接口即可，不回滚NAS已开始的后台作业、不删除用户数据。验证记录见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-10-01 自动预览失败同步结果增量

Photos管理结果新增automaticPreviewFailureRecorded默认false，兼容既有初始化调用；仅在明确转换失败的标记接收/真实状态核对后为true，生成结果仍为rejected，不计成功。macOS显示对应重建预览入口提示；其他错误沿既有重试路径。Network按单元/空间/阶段调用set_broken v3，未知上传回执、权限撤回、取消和临时系统错误不标记。无存储/工具链/依赖变更；回滚新增失败同步和提示即可，不删除原件或回滚NAS已记录状态。

五端影响：macOS接入；Windows/Android未来自动预览实现需映射各自系统的明确转换失败与临时错误，不照搬AVFoundation码。本轮不改其他端UI或运行其构建。iPhone/iPad后台全库转换仍后续非核心，不新增移动入口或待验；共享Apple结果默认值保持旧实现兼容。静态API证据不提升，真实NAS由用户验收，无人工待实测禁用；完整验证见Photos对齐账本。


### 2026-10-01 临时分享生命周期契约增量（实现中）

用户已授权Photos对齐所需共享契约扩展。Core新增createTemporaryAlbum、copyTemporaryAlbum、deleteTemporaryAlbum，以及SharingState可选isTemporary（缺字段保持nil）；沿既有临时分享静态端点，不改变普通createAlbum/deleteAlbum语义。Repository创建需核对temporary_shared、名称、所有者及完整成员；复制需回执新编号、普通非共享标记及完整成员快照一致；清理仅接受所有者的已停止临时相册与一致分享快照。未知回执沿操作编号只读核对，不按名称追认、不自动重放。macOS组合界面尚待接入，此记录不表示完整临时分享已交付。

五端影响：macOS接入后需覆盖取消清理和停止保留副本；Apple移动共享Package采用默认nil增量字段，枚举使用方需编译确认，未增加移动端界面；Windows与Android仅同步未来等价语义，当前不修改UI。无持久化/数据迁移。回滚移除新命令、字段和新入口，既有普通相册功能保持。当前仅static证据和待运行本地测试；真实NAS继续PENDING_USER_VALIDATION，不设人为待实测功能锁。


### 2026-10-01 临时分享原生组合流程

macOS已接入临时分享创建取消、停止并保留普通副本、关闭/Esc和未知结果自动核对。副本完整成员复查后才清理，明确失败可保留现有相册；不会删除原件。748项XCTest、6项本地化、4项UI/74张合成截图通过，独立Release包构建中，最终产物以Photos对齐账本为准。真实NAS仍PENDING_USER_VALIDATION，static证据不提升；其余四端界面/构建未验，不因此记为完成。冻结条件相册等剩余功能继续，不声明完整对齐。


### 2026-10-01 临时分享测试包完成（非正式发布）

`apple/Apps/DsmMac/dist/photos-temporary-sharing-20261001/LanStash-1.0.11-arm64.dmg`，21,974,554字节，1.0.11(21)、arm64、localtest。包含累计照片功能及临时分享创建取消清理、停止保留副本、未知结果自动核对、明确失败保留现有相册。748项XCTest、6项本地化、4项UI/74张合成截图、Release、严格签名、Sparkle实际加载与DMG校验通过。无本地磁盘挂载扩展，未自动安装启动或正式发布；真实NAS和系统确认框最终视觉由用户验收。其他端未构建，static证据不提升。完整命令、限制与待验步骤见Photos对齐账本；冻结条件相册等剩余项继续。


### 2026-10-01 上传任务导航与单项管理契约增量

用户已授权Photos对齐所需接口扩展。Serving新增folder(id:in:)只读方法，默认显式不支持；Repository复用已有Browse.Folder.get v2权限校验，返回当前名称、父目录、路径及空间，不增加NAS端点、写操作或持久化。macOS上传结果导航先回读照片当前目录，再逐层校验目录身份/访问权；直接相册贡献上传只提供相册入口，不绕过原空间权限。队列取消仅针对未开始单项，终态记录移除不删除NAS照片，未知结果保留自动核对。

五端影响：macOS新增使用入口；iPhone/iPad共享Package采用向后兼容默认实现，本轮不改移动UI；Windows/Android仅记录未来等价语义，不修改实现或冒称目标平台通过。无数据迁移；回滚移除新入口/方法即可，旧上传重试保持。当前验证结果以Photos对齐账本为准，真实NAS为PENDING_USER_VALIDATION，不因未实测增加人工功能锁。


### 2026-10-01 Photos后台任务契约增量

静态证据与请求参数见`docs/api/discovery/endpoints/photos-background-tasks.md`及compatibility.json的photos-background-tasks。统一Info v1读取当前用户任务、错误详情；取消id数组，清理id标量。macOS原生任务窗口提供筛选、进度、取消确认、单项/冻结快照批量清理、错误名称/原因与目标目录导航。completion包含错误，done不等同全部成功；取消保留已完成的复制/移动，清理只移除记录。操作编号去重、身份快照、失权/迟到结果隔离和未知回执只读核对沿现有管理模型。允许取消本App待核对搬移，但终态证据核对前禁止清理记录。

五端影响：macOS本轮实施；iPhone与iPad共享新增服务默认明确不支持，不新增移动入口；Android与Windows只登记后续等价语义，不修改实现。本轮未运行其他端构建，不能以共享代码编译代表跨端完成。无存储/权限/依赖/工具链变更；回滚移除新增入口与方法，NAS用户资料不迁移。

本轮新增接口13项、模型7项；最终相关回归780项XCTest、6项本地化及2项原生UI/56张合成截图通过，独立Release包结果见MACOS_PHOTOS_PARITY_20260929_ZH账本最新记录。接口证据仅static，PENDING_USER_VALIDATION包含真实NAS跨空间错误名称、取消终态、断网恢复和清理快照范围；不新增人工待实测功能锁。冻结条件相册、待独立存储授权的上传跨重启恢复及最终菜单审计继续。


### 2026-10-01 冻结条件相册恢复契约增量

macOS新增独立冻结标志、本人冻结相册快照及普通恢复/条件重建命令，复用现有条件编辑器与操作编号。普通恢复只在回读freeze_album明确false后确认；重建先核对新相册的身份和完整条件，再固定旧相册快照删除，旧对象变化时保留两册。创建或删除回执未知不重放；不继承旧分享。冻结前不开放普通相册上传、成员增删和收集目标，既有预览封面设置保留；本人相册列表隐藏重命名/新分享，但“由我共享”的既有分享管理按官方分支保留。证据与真实版本限制见photos-advanced-management.md，当前为static；798项XCTest、6项本地化、1项原生UI/28张合成截图与独立Release临时签名包通过，详见Photos对齐账本。

五端影响：macOS本轮实现；iPhone/iPad共享领域字段默认false、读取默认明确不支持，不新增移动入口；Android/Windows需后续按等价确认、部分完成和失权语义适配，本轮不改代码也不运行各端构建。无持久化/权限/依赖变更，无本地迁移。回滚移除新增入口与调用；已恢复或重建的NAS相册不自动回滚，原照片保留。PENDING_USER_VALIDATION：以真实冻结样本核对普通恢复、受支持条件与重建后的新旧相册/分享、断网恢复和权限变化。只回传脱敏版本及步骤/错误，不含真实照片、路径、地址或凭据。


### 2026-10-01 预览重建角色分支增量

官方static菜单与worker已核对，macOS/共享Apple Repository补齐普通共享目录view+download及相册本人提供者的重建资格；不把任意相册下载权当作重建权，不修改原件编辑权限。相册只读按album_id核对真实提供者/来源/相册状态，重建写请求仍按来源发送item_id/unit_id；本机转换后重查资格。冻结相册按官方入口区分：保留多选重建，预览窗口省略。预览窗口复用已有确认表单；803项XCTest、6项本地化、最终8项聚焦及2项UI/12张合成截图通过，独立Release结果见Photos对齐账本。

无公开API/存储/依赖变更，iPhone/iPad共享Repository受影响但未新增入口；Android/Windows只记录等价语义，不改其代码。PENDING_USER_VALIDATION：真实目录下载者、本人相册贡献者、仅相册下载者、冻结/关闭来源、转换期间失权与断网恢复。缺失来源上下文不能用猜测权限恢复后台队列。回滚客户端本轮资格分支与入口，不反向修改已生成预览；接口证据保持static。


### 2026-10-01 Photos三项统一收尾：五端兼容

NAS接口与会话格式不变；相册实际提供者资格与来源空间重新核对，上传本机记录不包含凭据，不提升NAS证据等级。

上传专用SynologyPhotosUploadCheckpoint只表示上传、直接相册上传、创建上传目录、加入相册；写前与回执同步保存，恢复入口只读核对。新协议有显式不支持默认实现，不改变既有Serving实现的行为。提供者编辑不提升原件删除/移动资格；混合来源标签仍禁止。详见`MACOS_PHOTOS_PARITY_20260929_ZH.md`文末源码映射与后续实际验证记录。真实NAS结果仍为PENDING_USER_VALIDATION。
