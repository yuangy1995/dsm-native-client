# 私有 API 环境与证据索引

本页保存匿名版本快照和方法级证据；条目日期代表原观察，不因文档整理而更新验证。仅明确归属的设备进入机器索引环境列表；相同版本不能证明同一设备。现行接口定义见[端点索引](../endpoints/INDEX.md)，机器字段见[兼容索引](../../../../contracts/private-api/compatibility.json)。

证据保持 static / observed / read-verified / behavior-verified / failed 原义；一次官方网页行为不代表原生客户端通过。合成 fixture 只验证约定形状。下列旧基线的 current 是历史登记状态，不表示已于今天重新检查设备。升级时保留旧行并以 historical/supersedes 串联，未知关系不猜测。

## 2026-07-29-lab-a-dsm-69057-u12

**原环境元数据**：环境标识：`lab-a-dsm-7-2-1-69057-u12-20260729`；匿名设备别名：`lab-a`；基线状态：`current`；替代的旧基线：`none`；观察日期：2026-07-29；DSM 版本：`7.2.1`；DSM build：`69057`；Update：`12`；连接方式类别：QuickConnect HTTPS；账号权限类别：未在本次版本核实中判定；证书类别：未在本次版本核实中单独登记

**套件及来源**：`dsm-core` / DSM / `7.2.1-69057 Update 12` / 已登录 DSM 信息中心可见；`file-station` / File Station / `1.4.1-1559` / 已登录套件中心详情可见；`storage-manager` / 存储管理器 / `1.0.0-0017` / 已登录套件中心详情可见；`storage-analyzer` / 存储空间分析器 / `2.1.0-0620` / 已登录套件中心详情可见；`download-station` / Download Station / `4.1.2-5012` / 已登录套件中心详情可见；`virtual-machine-manager` / Virtual Machine Manager / `2.6.5-12202` / 已登录套件中心详情可见；`container-manager` / Container Manager / `24.0.2-1535` / 已登录套件中心详情可见；`synology-chat-server` / Synology Chat Server / `2.4.1-22111` / 已登录套件中心详情可见；`synology-photos` / Synology Photos / `1.8.2-10090` / 已登录套件中心详情可见

**证据与结论**：来源：已登录 DSM 信息中心及套件中心，只复核版本；方法证据继承 2026-07-23 至 07-27 已登记发现。仅此记录归属 lab-a/current。QuickConnect 既有 behavior-verified、各读取/写入等级仍按机器索引的方法结论；本次未重新验证 API。2026-08-02 容器/VMM 页面观察未取得可提升等级的请求；08-03 ZRAM 控件仅 static、Chat 已读发现未成功。没有新的升级或 supersedes 关系。

## 2026-09-09-admin-chat-observation

**原环境元数据**：环境标识：待归属观察，不新建 current 基线；匿名设备别名：待确认是否为既有 lab-a，不以相同版本推断设备相同；基线状态：待归属；替代的旧基线：none；发现日期：2026-09-09；DSM 版本、build、Update：7.2.1 / 69057 / 12，官方 get_user_service 的 Session 白名单字段；设备架构类别：未验证；连接方式：QuickConnect 直连；证书类别：未验证；账号权限类别：管理员，用户提供且 Session.is_admin=true

**套件及来源**：synology-chat-server / Synology Chat Server / 2.4.1-22111，官方 get_ui_config 应用定义 / 官方页面可打开

**证据与结论**：来源：官方 Chat 页面自然产生的能力元数据。read-verified：Anonymous v1–v2、Named/Member v1 与 FileStation.Search v1–v2 均声明 entry.cgi/JSON；这是参数编码声明，不是 JSON HTTP 正文或创建/搜索行为验证。未创建会话或启动真实搜索。官方页面可能自动更新已读/偏好，未确认这些副作用。

## 2026-09-09-nonadmin-permission-observation

**原环境元数据**：发现日期：2026-09-09；环境标识、匿名设备别名：待用户确认与既有 lab-a 的关系；版本相同不能证明设备相同；基线状态、替代的旧基线：未建立正式基线，不修改旧记录；DSM 版本：7.2.1；build / Update：69057 / 12；fullversion 为 69057-s12；版本来源：官方 get_user_service 响应 Session 中 productversion、version、smallfixnumber；账号权限类别：用户提供非管理员；响应 is_admin=false、isLogined=true；连接方式：QuickConnect HTTPS；直连或中继未单独核实；证书、架构类别：未核实；未绕过浏览器安全提示

**套件及来源**：File Station：1.4.1-1559；Synology Chat Server：2.4.1-22111；Download Station：4.1.2-5012；Synology Drive：3.5.0-26085；Synology Photos：1.8.2-10090；Container Manager / VMM：本次返回列表未提供可核实版本，未验证

**证据与结论**：来源：官方 get_user_service、Package.list 及 get_ui_config；非管理员与同日管理员对照。AppPrivilege 的应用授权与 is_admin 管理入口需区分：管理员菜单可有未列入 AppPrivilege 的容器/控制面板，不能据此让管理员绕过所有套件授权。纠正浏览器账号后，普通账号 VMM 应用键为 true，但官方 VMM 仍拒绝具体操作；先前账号不一致的观察不能证明 App 误显示，也未验证具体 VMM 请求。管理员应用定义另声明 Container Manager 24.0.2-1535、VMM 2.6.5-12202，不冒充安装详情。未修改权限；网页自行发送 UserSettings.apply，未读/重放正文。用户补充 VMM 手工安装且非官方支持机型，仅为环境限制，不是硬件验证。

## 2026-09-09-photos-observation

**原环境元数据**：环境标识：待归属观察，不因版本相同认定为既有设备；匿名设备别名：待核实与既有 lab-a 的关系；基线状态：待核实，不新增 current 基线；替代的旧基线：none；发现日期：2026-09-09；DSM 版本 / build / Update：7.2.1 / 69057 / 12，官方初始化响应核实；设备架构类别：未验证；连接方式：未验证具体直连或中继类别；证书类别：未验证；账号权限类别：DSM 管理员；Photos 共享空间权限为 none，不因管理员身份推断照片权限

**套件及来源**：synology-photos / Synology Photos / 1.8.2-10090 / 运行 / 本次 Setting.Admin.get 响应核实

**证据与结论**：来源：官方 Photos 页面、能力发现及 Setting.Admin.get。read-verified：个人时间线/项目/文件夹和分类结构，Folder.get 根目录成功、Album.list 成功但为空；详情/视频流已观察，原件最小 Range 返回 206 后取消正文。Item 目录最高 v6 不等于列表应使用 v6，官方列表实际 v4。共享角色为 none，共享空间成功读取、App 自身会话和写入未验证，不冒用 lab-a。

## 2026-09-10-container-read-observation

**原环境元数据**：环境标识：待归属观察；不冒用既有基线；匿名设备别名：与 lab-a 关系未确认；基线状态：不建立 current 基线；替代的旧基线：none；发现日期：2026-09-10；DSM 版本 / build / Update：待本次核实；设备架构类别：未验证；连接方式：QuickConnect；直连或中继未验证；证书类别：未验证；账号权限类别：待核实；已登录会话可打开 Container Manager

**套件及来源**：container-manager / Container Manager / 待核实 / 官方页面可打开

**证据与结论**：来源：官方 Container Manager 必要请求与 MainVue.js。read-verified：SYNO.Docker.Log.list v1 的 action=load 活动日志及字段类型；Network.list v1 的 containers:string[]（数量取数组长度）；Project.list v1 两次成功返回空对象，非空项目形状仅 static。Network.create 参数仅 static。后续明确授权的单个无关联容器测试网络使用 Network.remove v1、networks 对象数组，响应 failed=[] 且最终目标消失，仅该单目标形成行为证据；完整 DSM/套件版本未核实，不登记版本级 behavior-verified。未执行其他资源删除。

## 2026-09-10-photos-deletion-observation

**原环境元数据**：环境标识、匿名设备别名：待确认与既有 lab-a 的关系；不新增 current 基线；替代的旧基线：不覆盖既有记录；发现日期：2026-09-10；DSM 版本 / build / Update：7.2.1 / 69057 / 12，本轮再次核对；设备架构类别：未验证；连接方式：QuickConnect 域名连接，直连／中继未验证；证书类别：未验证；账号权限类别：前轮为管理员，本轮仍单独检查目标目录权限

**补充版本来源**：Synology Photos 1.8.2-10090，原记录说明本轮再次核对；DSM7.2.1/build69057/Update12按原环境元数据。

**证据与结论**：来源：明确授权的个人空间唯一合成 PNG，官方上传后再次核对身份/权限，只提交一次 BackgroundTask.File.delete（folder_id=[]）。behavior-verified 仅限该单项：任务由 waiting 到 done，error/skip=0，Item.get v5 及网页刷新后原件均为空；未删除既有照片、目录或回收站内容。回收站开关为 true 不证明恢复成功；App 会话/重启、未知结果、批量、其他角色与实际恢复未验证，不写入旧 lab-a verification。

## 2026-09-10-photos-filter-share-observation

**原环境元数据**：发现日期2026-09-10；设备与既有lab-a关系未确认，不新增/覆盖current；DSM7.2.1/build69057/Update12来自当日官方初始化响应；Photos1.8.2-10090来自当日Setting.Admin.get；连接、证书未验证；DSM管理员，不据此推断Photos共享空间/分享写权限；来源为已登录官方Photos必要读取、官方静态资源及脱敏字段结构。

**证据与结论**：来源：官方 Photos 读取与静态脚本。read-verified：分类/筛选结构，三个共享列表成功空响应及独立 Live Photo 视频单元；非空共享和写入未验证，rating=[0] 仅请求接受，不证明实际筛选效果。共享列表旧请求失败 code120、errors.name=sort_by/reason=condition；依 get_album_list_order 加 share_modify_time/desc 后成功，access_permission 不是该次根因。无转换 MP4 的 Streaming high 返回404/text/html，Download 按 item_id 返回206/video/mp4；官方 raw 分支使用 Download，不能凭扩展名认定不支持。原生播放仍未验。

## 2026-09-16-quickconnect-client-observation

**原环境元数据**：环境标识：待归属客户端观察，不新建 DSM 版本基线；匿名设备别名：待核实，不推断与既有 lab-a 的关系；基线状态 / 替代旧基线：未归属 / none；发现日期：2026-09-16；DSM 版本 / build / Update：未验证；未登录 NAS；相关套件完整版本：未验证；本次访问未认证 QuickConnect 控制面与 SYNO.API.Info；客户端平台：Windows x64 / .NET 10；连接与证书类别：官方 QuickConnect HTTPS / 系统证书信任；权限类别：未认证，不发送 NAS 账号、密码或会话

**证据与结论**：来源：客户端 get_server_info 只读复验及官方 connect_lib 静态转介逻辑。全球入口 errno=4/suberrno=0/sites:string[]，通过域名白名单的区域入口返回 errno=0、ds_state=CONNECTED 和连接候选；Windows 登录前 SYNO.API.Info 探测通过。未提交凭据，完整登录、DSM 版本和设备归属未确认，不新增版本兼容结论。

## 2026-09-16-windows-parity-read-observation

**原环境元数据**：环境标识：待归属观察，不建立 current 基线；匿名设备别名：未确认是否属于既有 lab-a，不以页面名称或相同版本推断；基线状态：待归属；替代的旧基线：none；发现日期：2026-09-16；DSM 版本 / build / Update：7.2.1 / 69057 / 12，当前官方 get_user_service 的 Session 白名单字段；设备架构类别：未验证；连接方式：Chrome 已登录官方 DSM，QuickConnect；直连或中继未验证；证书类别：未验证；账号权限类别：管理员，当前官方 Session.is_admin=true

**套件及来源**：synology-chat-server / Synology Chat Server / 2.4.1-22111 / 未单独核实运行状态 / 官方 Package.list 版本字段；container-manager / Container Manager / 24.0.2-1535 / 官方页面可打开 / 官方 Package.list 版本字段；synology-photos / Synology Photos / 1.8.2-10090 / 未单独核实运行状态 / 官方 Package.list 版本字段，不提升图库验证

**证据与结论**：来源：官方版本页面和 SYNO.API.Info。read-verified 仅限版本、Chat 创建/成员与 Docker 容器/日志 JSON 能力元数据。未创建群聊、未执行容器写入。

## 2026-09-17-container-image-pull-read-observation

**原环境元数据**：环境标识：待归属观察，不建立 current 基线；匿名设备别名：未确认，不根据页面名称或相同版本推断 lab-a；基线状态：待归属；替代的旧基线：none；发现日期：2026-09-17；DSM 版本 / build / Update：7.2.1 / 69057 / 12，当前官方 get_user_service 的 Session 白名单字段；设备架构类别：未验证；连接方式：已登录 Chrome 官方 DSM，QuickConnect；直连/中继类别未验证；证书类别：未验证；账号权限类别：管理员，当前官方 Session.is_admin=true

**套件及来源**：container-manager / Container Manager / 24.0.2-1535 / 官方页面可打开 / 当前官方 Package.list 的版本字段

**证据与结论**：来源：官方版本/能力、Image.list 读取和官方脚本。read-verified：Image.list 的 offset/limit/show_dsm 与响应形状；static：pull_start/pull_status/聚合任务身份。没有执行映像下载。

## 2026-09-17-vmm-settings-read-observation

**原环境元数据**：环境标识 / 匿名设备别名：待归属；不根据页面名称推断 lab-a；基线状态 / 替代的旧基线：待归属 / none；发现日期：2026-09-17；DSM 版本 / build / Update：待当前页面核实；此前同日观察为 7.2.1 / 69057 / 12；设备架构类别：未验证；连接方式：已登录 Chrome 官方 DSM，QuickConnect；直连/中继未验证；证书类别：未验证；账号权限类别：待当前页面核实；不读取账号值

**套件及来源**：virtual-machine-manager / Virtual Machine Manager / 待核实 / 待核实

**证据与结论**：来源尝试：浏览器会话未附加，未获得新环境、请求或响应证据。仅有既有源码字段核查，不能记作 read-verified 或真实写入。

## 2026-09-19-container-lifecycle-read-observation

**原环境元数据**：环境标识：待归属观察，不建立 current 基线；匿名设备别名：未确认，不按页面名称或版本推断 lab-a；基线状态：待归属；替代的旧基线：none；发现日期：2026-09-19；DSM 版本 / build / Update：7.2.1 / 69057 / 12，本轮官方 System.info 的 firmware_ver；设备架构类别：未验证；连接方式：用户登录的 Chrome 官方 DSM，经 QuickConnect；直连/中继未验证；证书类别：未验证；账号权限类别：管理员，官方当前页面 Session.is_admin 原生布尔为 true

**套件及来源**：container-manager / Container Manager / 24.0.2-1535 / 官方页面正常打开 / 当前官方 Package.list v2 的版本字段

**证据与结论**：来源：官方 MainVue.js 与自然 Container.list v1。read-verified：offset=0/limit=-1/type=all、containers/State 字段类型，StartedAt/FinishedAt 为日期字符串；未证明重启后变化。static：start/stop/restart 按 name，signal=9、delete 的 force/preserve_profile，以及映像按仓库标签或 identity 删除；容器及所属项目 is_package 保护、全部容器占用检查也仅 static。未执行生命周期、重置或删除，不提升旧 lab-a。

## 2026-09-20-remote-mount-read-observation

**原环境元数据**：环境标识：待归属观察，不建立 current 基线；匿名设备别名：未确认，不推断为 lab-a；基线状态：待归属；替代的旧基线：none；发现日期：2026-09-20；DSM 版本 / build / Update：7.2.1 / 69057 / 12；当前官方 Session 的 productversion/version/fullversion 白名单字段；设备架构类别：未验证；连接方式：用户登录的 Chrome DSM，QuickConnect；直连/中继未验证；证书类别：未验证；账号权限类别：管理员；当前官方 Session.is_admin 为 true

**套件及来源**：file-station / File Station / 1.4.1-1559 / 官方页面已加载 / 官方套件中心自然 Package.list 响应

**证据与结论**：来源：官方 FileBrowser.js、版本/能力及 Mount.List.get。read-verified：Mount/Mount.List v1/JSON，isoList/remoteList 数组、mountConfig 布尔，remoteList 为空；非空字段仅 static。mount_remote、unmount、reconnect 及 NFS/CIFS 参数仅 static；官方无 read_only 字段，不能当只读保证。自动目录创建/卸载后删除只是官方静态分支，不授权客户端隐式清理。未挂载、断开或验证错误凭据。

## 2026-09-20-vmm-creation-read-observation

**原环境元数据**：日期：2026-09-20；匿名设备 / 基线状态 / 替代基线：待归属 / 待归属 / none；DSM / build / Update：同日网络观察已核实 7.2.1 / 69057 / Update 12；本轮有变化则另记；套件：Virtual Machine Manager（Virtualization），同日已核实 2.6.5-12202；架构 / 证书类别：未独立核实 / 未独立核实；连接方式 / 权限：既有 Chrome 官方 DSM，HTTPS QuickConnect 入口 / 同日已核实管理员

**证据与结论**：来源：官方创建表单/静态代码、只读选项，以及随后明确授权的单台隔离创建。behavior-verified 仅限一次 Guest.create v1：1 CPU、512 MiB、10 GiB 空白盘、Linux/UEFI、断网、无ISO、无自动启动且创建后关机；data.task_id 字符串。read-verified：Cluster.get_total_progress v1按主机/任务两层对象精确匹配该任务，finish/success/progress及data.guest_id，Guest.get v2/get_setting v1核对配置。任务消失不能当成功或重发。内部get/get_setting/list的vram_size为KiB，create/set为MiB（set仅static），vdisk_size为GiB。09-21只读复验能力与ISO online/healthy；不代表App创建、开机或其他预设通过。

## 2026-09-20-vmm-network-read-observation

**原环境元数据**：环境标识 / 匿名设备别名：待归属；基线状态 / 替代旧基线：待归属 / none；日期：2026-09-20；DSM 版本 / build / Update：7.2.1 / 69057 / Update 12；本轮 Info Center 可见版本已核实；设备架构：未验证；连接方式：已登录 Chrome 官方 DSM，HTTPS QuickConnect 入口；未独立区分直连/中继；证书类别：未验证；账号权限类别：管理员；官方脚本使用的 _S("is_admin") 标记为 true，不记录账号

**套件及来源**：virtual-machine-manager / Virtual Machine Manager / 2.6.5-12202；官方 Package.list v2 / 当前管理页面可用；未记录未经返回的套件运行字段

**证据与结论**：来源：浏览器附加最初失败，恢复后观察官方页面与 virtualization.js。read-verified：Network.list/get v2、list_avail_interface v1；当前列表为 external，get 未返回 network_id，身份须结合 list。static：set/delete v1，external 的 interfaces_add/remove 仅差量、单纯改名为空数组，private 的 host_id 及逐项删除。private 分支、静态错误码和全部网络写副作用未验证，未创建 VM。

## 2026-09-20-vmm-parity-read-observation

**原环境元数据**：环境标识 / 匿名设备别名：待归属，不根据地址或设备名称推断；基线状态 / 替代的旧基线：待归属 / none；发现日期：2026-09-20；DSM 版本 / build / Update：7.2.1 / 69057 / 12；官方页面 Session fullversion=69057-s12；设备架构类别：未验证；连接方式：用户已登录的 Chrome 官方 DSM，QuickConnect 类；直连/中继未验证；证书类别：待核实；账号权限类别：管理员；只读取 is_admin 布尔，不记录账号

**套件及来源**：virtual-machine-manager / Virtual Machine Manager / 2.6.5-12202 / 官方页面已打开，资源读取成功

**证据与结论**：来源：官方 API.Info、Guest.get v2/get_setting v1 与 virtualization.js。read-verified：能力元数据及读取字段，autorun/cpu_weight 为原生数字。static：autorun 三态、CPU 五档、set v1、固件/ISO 字段与控制台地址；未保存设置、未连接控制台，字段显示不能证明 WebSocket/认证或写行为。

## 2026-09-21-vmm-console-resource-observation

**原环境元数据**：日期：2026-09-21；匿名设备 / 基线状态 / 替代基线：待归属 / 待归属 / none；DSM / build / Update：同会话既有记录 7.2.1 / 69057 / Update 12，本次尚未重读系统版本；套件：既有记录 Virtualization 2.6.5-12202，本次核对其已加载/同源静态资源；架构 / 证书类别：未独立核实 / 未独立核实；连接 / 权限：Chrome 既有 HTTPS QuickConnect 会话 / 先前管理员记录，本次只读

**证据与结论**：来源：不指定 VM、autoconnect=false 的官方 noVNC 研究页。static：app_alias/app_id 的同源 WebSocket 路径、窗口绑定及资源相对路径。read-verified：语言 zh.json、铃声 bell.oga、样式与图标读取，32 像素套件图标为 image/png；资源版本参数与先前 2.6.5-12202 记录一致。未连接 VM、未修改门户，真实别名部署与 VNC 画面未验证；Windows CSP/原生桥合成结果不升级该环境等级。

## 2026-09-26-nas-settings-read-observation

**原环境元数据**：日期：2026-09-26；DSM 版本 / build / Update：未完整核实；官方已加载静态资源版本为 `69057-s12`，不能代替系统版本读取；相关套件：本次只涉及 DSM Core；未读取或验证套件版本；连接类别：Chrome 中现有 QuickConnect 直连页面；权限类别：可打开官方系统管理页面；未独立核实账号角色；证书类别：未独立核实；设备归属：待核实，不据历史会话认定同一设备

**证据与结论**：来源：官方控制面板自然请求。read-verified：User.list v1 的 expired=normal/now，PowerSchedule.load v1 的独立 poweron/poweroff 数组，CurrentConnection.list 的 items/systime/total 容器；PID 与星期编码当时未核实。Process/ProcessGroup 及整数 PID 仅取第三方 mikespub 原始 Schema 候选，不是 Synology 官方或当前 NAS 读取证据。没有手动保存/运行/删除；页面自然发送 Led.Brightness.update，副作用未核实。

**来源链接**：[CurrentConnection 原始 Schema](https://github.mikespub.net/synology/tools/schemas/SYNO.Core.CurrentConnection-list.json)、[Process 原始 Schema](https://github.mikespub.net/synology/tools/schemas/SYNO.Core.System.Process-list.json)、[ProcessGroup 原始 Schema](https://github.mikespub.net/synology/tools/schemas/SYNO.Core.System.ProcessGroup-list.json)（第三方静态候选）。

## 2026-09-27-nas-settings-live-validation

**原环境元数据**：发现日期：2026-09-27（与前一日连续工作）；DSM 版本：7.2.1；DSM build / Update：69057 / 12；浏览器连接类别：现有 QuickConnect 直连；客户端连接类别：已保存的局域网连接；证书类别、设备架构：未独立核实；权限类别：官方页面可访问系统管理；修复包已恢复管理员菜单与读取；相关套件：本轮只验证 DSM Core；不将套件版本或写操作标为已验证

**证据与结论**：来源：官方 DSM 读取和原生 App 会话对照；设备仍待归属，不改 lab-a。read-verified：CurrentConnection.list 数字 PID、TaskScheduler.get v4、PowerSchedule.load v1 数字星期、Process/ProcessGroup v1 结构。App 的 GET/POST 摘要均返回成功但 isLogined=false、空权限表；该摘要无效，不能冒充已登录无权限，也不能单独断言全部会话过期。isLogined=true 的合法空表仍拒绝。修复包五个页面只读点击通过；退出/重连成功为用户后续反馈，Agent 工具中断不算退出通过。未执行真实配置写入。

## 2026-09-28-photos-parity-observation

**原环境元数据**：日期：2026-09-28；源码验证延续至 2026-09-29；来源：已登录 Chrome 中的官方 Synology Photos 页面、该页面加载的官方静态脚本；匿名设备归属：与已有 lab-a 的关系未确认；本记录不注册新的 current 基线；DSM 版本 / build / Update：未验证，不沿用历史记录；Photos 完整版本：未验证；架构、证书类别、实际网络路径：未验证；仅确认 HTTPS 网页会话；权限类别：可读取个人照片空间；不推断管理员或管理权限；静态资源：`/webman/3rdparty/SynologyPhotos/react_bundle.js`；只记录接口结构，不保存脚本副本

**证据与结论**：来源：已登录官方 Photos 与 react_bundle.js；2026-09-28 至 10-01 多次静态核对。管理接口仍为 static。授权下两张合成图片上传、普通相册新建/改名、日期刷新保留；评级仅有成功提示，未独立回读。没有可用于契约确认的请求结构，且 DSM/Photos 完整版本未知，因此不登记版本级 behavior-verified；标签/移动/复制/公开分享/删除未实测。后续相册协作、混合来源、预览转换、共享权限、相似/主题/人物、后台任务及冻结相册均仅静态字段证据，当前定义见 Photos 各端点记录。曾打开分享弹窗后取消；后续静态核对表明打开即可创建 disabled 链接，未点保存不能证明绝无副作用，不登记为纯读验证。

## 2026-09-30-photos-1-7-0-official-package

**原环境元数据**：环境标识：`photos-1-7-0-0795-official-package-20260930`；匿名设备别名：不适用：官方公开下载包，不对应用户NAS；基线状态：静态来源；不注册设备current基线；替代的旧基线：none；发现日期：`2026-09-30`；DSM 版本：未验证，无运行中的DSM；DSM build：未验证，无运行中的DSM；Update：未验证，无运行中的DSM；设备架构类别：armada37xx公开套件；不是用户NAS架构；连接方式：HTTPS官方公开下载，无NAS连接；证书类别：官方下载站HTTPS；未连接NAS；账号权限类别：无账号，无NAS会话

**套件及来源**：`synology-photos` / Synology Photos / `1.7.0-0795` / 未安装、未运行 / 仅读取官方包中必要网页资源

**证据与结论**：来源：Synology 官方公开归档包，非设备。标准归档工具未能取得内部脚本，未安装或执行；没有新增 API 证据，不形成 current/historical NAS 基线。

**来源链接**：[Synology Photos 1.7.0-0795 官方目录](https://archive.synology.com/download/Package/SynologyPhotos/1.7.0-0795)。

## 2026-09-30-photos-1-9-1-official-package

**原环境元数据**：环境标识：`photos-1-9-1-10928-official-package-20260930`；匿名设备别名：不适用：官方公开下载包，不对应用户NAS；基线状态：静态来源；不注册设备current基线；替代的旧基线：none；发现日期：`2026-09-30`；DSM 版本：未验证，无运行中的DSM；DSM build：未验证，无运行中的DSM；Update：未验证，无运行中的DSM；设备架构类别：x86_64公开套件；不是用户NAS架构；连接方式：HTTPS官方公开下载，无NAS连接；证书类别：官方下载站HTTPS；未连接NAS；账号权限类别：无账号，无NAS会话

**套件及来源**：`synology-photos` / Synology Photos / `1.9.1-10928` / 未安装、未运行 / 仅读取官方包中必要网页资源

**证据与结论**：来源：Synology 官方公开包，非设备。标准归档工具未能取得内部脚本，未安装或执行；没有新增 API 证据，不形成 current/historical NAS 基线。

**来源链接**：[Synology Photos 1.9.1-10928 官方目录](https://archive.synology.com/download/Package/SynologyPhotos/1.9.1-10928)。

## 2026-10-01-photos-remaining-observation

**原环境元数据**：环境标识：`photos-remaining-observation-20261001`；匿名设备别名：待归属；延续此前Photos观察，不推断与lab-a的关系；基线状态：观察记录；不注册current设备基线；替代的旧基线：none；不是已确认的设备升级；发现日期：2026-10-01；DSM 版本：未验证；DSM build：未验证；Update：未验证；设备架构类别：未验证；连接方式：已登录HTTPS网页会话；连接类别未验证；证书类别：未验证；账号权限类别：可读取个人照片空间；不推断管理员权限

**套件及来源**：`synology-photos` / Synology Photos / 未验证 / 官方页面可读取 / 关于窗口未显示完整版本

**证据与结论**：来源：浏览器恢复后的官方静态资源。static：后台任务与冻结相册的参数、权限和恢复候选；完整版本仍未知，未执行真实 NAS 写入。

## 2026-10-02-file-station-live-observation

**原环境元数据**：环境标识：待归属观察，不建立 current 基线；匿名设备别名：未确认，不按相同版本推断为 lab-a；基线状态：待归属；替代的旧基线：none；发现日期：2026-10-02；DSM 版本 / build / Update：7.2.1 / 69057 / 12；官方信息中心显示；设备架构类别：未验证；连接方式：用户已登录的 Chrome DSM；QuickConnect 直连页面，链路类别未独立验证；证书类别：未验证；账号权限类别：未验证

**套件及来源**：file-station / File Station / 1.4.1-1559 / 已启动 / 官方套件中心详情；不据此推断所有接口可用

**证据与结论**：来源：官方 File Station 页面必要请求与已加载脚本。read-verified：Settings.get v1、BandwidthControl.list v1、Sharing.list 字段（含无日期空串）、Protocol.list 协议/has_server，以及 Search.start v2 接受 search_content=true 并返回 has_not_index_share=true；零命中不证明全文召回。其余分享/权限/ISO/VFS/Theme 写参数和非空时间表仅 static。云授权页仅用合成参数进入账号选择，未授权或取得令牌/成功回调。未保存设置、修改权限或执行文件写入。

## 2026-10-02-file-station-official-package

**原环境元数据**：环境标识：`file-station-1-4-1-1559-official-package-20261002`；匿名设备别名：不适用，官方公开下载包；基线状态：静态来源，不注册 current 设备基线；替代的旧基线：none；发现日期：2026-10-02；DSM 版本 / build / Update：未验证，无可访问的运行会话；设备架构类别：x86_64 下载包，不代表用户设备；连接方式：官方 HTTPS 下载，无 NAS 连接；证书类别：官方下载站 HTTPS，未检查 NAS；账号权限类别：无账号、无会话

**套件及来源**：file-station / File Station / 1.4.1-1559 / 未安装、未执行

**证据与结论**：来源：Synology 官方下载包，非设备。浏览器会话不可访问，标准归档工具未能取得目标脚本，没有新增字段证据或 NAS 基线。

**来源链接**：[File Station 1.4.1-1559 官方目录](https://archive.synology.com/download/Package/FileStation/1.4.1-1559)。

## 2026-10-02-file-station-settings-read-fix

**原环境元数据**：环境标识：待归属观察，不注册 current 基线；匿名设备别名：未确认与既有 lab-a 的关系，不按版本推断；基线状态：待归属；替代的旧基线：none；发现日期：2026-10-02；DSM 版本 / build / Update：7.2.1 / 69057 / 12；官方信息中心本轮显示；设备架构类别：未验证；连接方式：已登录的 Chrome 官方页面，具体链路类别未验证；证书类别：未验证；账号权限类别：可读取 File Station 设置及用户/群组名单；DSM 管理员身份未独立核实

**套件及来源**：file-station / File Station / 1.4.1-1559 / 官方页面可用，未操作服务状态 / 官方套件中心详情本轮显示

**证据与结论**：来源：官方 File Station 只读请求及对应脚本。read-verified：本机账号/群组 uid/gid 数字字符串、权限布尔、限速 notexist 未配置状态。草稿取消，没有设置或权限写入。

## 2026-10-02-nas-settings-web-audit

**原环境元数据**：环境标识：待归属观察，不注册 current 基线；匿名设备别名：与既有 lab-a 的关系未确认；基线状态：待归属；替代的旧基线：none；发现日期：2026-10-02 至 2026-10-03；DSM 版本：7.2.1；DSM build：69057；Update：12；设备架构类别：未验证；连接方式：用户已登录 Chrome；QuickConnect 直连地址类别（不保存地址）；证书类别：未验证；账号权限类别：可访问官方管理页面；角色待核对

**套件及来源**：dsm-core / DSM / 7.2.1-69057 Update 12 / 不操作运行状态 / 套件按实际覆盖追加

**证据与结论**：来源：官方管理页面导航、必要请求与前端静态绑定。已读验 ZRAM.get 的 enable_zram、BeepControl 支持位、FanSpeed 字段、Package.Server.list v2 和已安装清单 available_operation 对象；21 页可见不等于每项响应均读验。防火墙通知语义、区域格式、电源计划 save、ZRAM/NeedReboot 写、套件安装/队列/设置/来源管理参数仅 static；Setting.get/set 此轮未核实真实响应。未执行真实配置、安装或其他写操作，字段定义见对应端点。

## 2026-10-03-chat-five-features-observation

**原环境元数据**：环境标识：待归属观察；匿名设备别名：未重新确认，不以地址或相同版本推定设备；基线状态：观察记录，非 current；替代旧基线：none；日期：2026-10-03；DSM 版本/build/Update：官方页面 Session 再次读取：7.2.1 / 69057 / 12；设备架构类别：未验证；连接方式：已登录官方网页，QuickConnect 直连；证书类别：未单独记录；不绕过浏览器或系统证书检查；账号权限类别：具有 Chat 使用权限的管理员；官方 Session.is_admin=true；Chat 套件完整版本：官方 Chat Utils.getChatVersion() 当前读取：2.4.1-22111

**证据与结论**：来源：官方 Chat 页面读取及用户明确授权的本轮合成消息/回复/投票。read-verified：定位/线程分页、Post.search、编辑设置、投票选择、last_view_at；behavior-verified：合成消息编辑、线程回复、投票创建/选择和 Channel.view 后会话时间推进。Post.Subscribe.view为observed：仅回执，不等于线程未读数改变；failed：投票options JSON文本返回117、choices字符串数组返回101，改text对象数组成功。未验证普通用户、其他套件版本或中继。

## 2026-10-03-chat-pinned-read-observation

**原环境元数据**：环境标识 / 匿名设备别名：待归属观察 / 未重新确认；基线状态 / 替代旧基线：观察记录，非 current / none；日期：2026-10-03；DSM 版本 / build / Update：官方 Session 当前读取：7.2.1 / 69057 / 12；架构类别：未验证；连接方式：已登录官方网页；同日先前记录为 QuickConnect 直连，本轮未重测链路；证书类别：未单独记录，不绕过证书检查；权限类别：管理员，具有 Chat 使用权限；Session.is_admin=true；套件：Synology Chat Server / 2.4.1-22111 / 运行中；证据来源：官方 Chat WebAPI.sendPromise 的 Post_search 只读请求；Session 和 Utils.getChatVersion

**证据与结论**：来源：官方 Post.search 与 Session/Utils.getChatVersion。failed：channel_id 加 has=[pin] 返回其他会话；read-verified：in 数字会话数组正确限制结果，含 search_results、offset/limit/total。未设置/取消置顶、未调用 Channel.view。

## 2026-10-03-container-image-pull-observation

**原环境元数据**：环境标识 / 匿名设备 / 基线状态：待归属观察；未确认设备别名，不根据版本推断 lab-a，不建立 current 基线；替代旧基线：none；日期：2026-10-03；DSM 版本 / build / Update：7.2.1 / 69057 / 12；设备架构类别：未验证；连接方式：已登录 Chrome 官方 DSM，QuickConnect；直连与中继未验证；证书类别：未验证；权限类别：管理员；当前官方 Session.is_admin=true

**套件及来源**：container-manager / Container Manager / 24.0.2-1535 / 页面可打开，读取及下载启动可用

**证据与结论**：来源：官方请求及明确授权的单次固定版本小映像拉取。read-verified：Registry.search/tags v1、Image.list、pull_status 运行中字段（finished=false/downloaded=0，无 current/total）和 Entry.Request.Polling.list 的 admin 字符串数组；后者仅诊断，不授权跨账号恢复。failed：search v2 返回103。observed：pull_start 字符串 task_id；同任务最终返回1202且目标标签未出现，记录为失败，原因不推断为网络/权限等。较早既有任务的后续117/errors=508不能覆盖首次1202。成功下载和取消未验证。

## 2026-10-03-package-center-followup

**原环境元数据**：环境标识：待归属观察，不注册 current 基线；匿名设备别名：与既有 lab-a 的关系未确认；基线状态：待归属；替代的旧基线：none；发现日期：2026-10-03；DSM 版本：7.2.1；DSM build：69057；Update：12；设备架构类别：未验证；连接方式：用户已登录 Chrome；QuickConnect 直连地址类别，不保存地址；证书类别：未验证；账号权限类别：可访问管理页面并完成本次套件更新；角色未另行读取

**套件及来源**：dsm-core / DSM / 7.2.1-69057 Update 12 / 不改变系统运行状态 / 信息中心当日重新读取；MediaServer / 媒体服务器 / 2.2.1-3406 → 2.2.2-3412 / 更新后官方页面显示“已启动” / 唯一获授权更新目标，Synology Inc. 官方套件

**证据与结论**：来源：官方页面与明确授权的一次 MediaServer 更新。behavior-verified 仅限 2.2.1-3406 → 2.2.2-3412 最终已启动及回读。Package.feasibility_check v1 成功可无 data；Installation.get_queue/check/upgrade/status 的实际字段另有观察，不能把‘无 data’扩展到它们。Setting.get v1 的 update_channel 为 Boolean、单卷可缺 default_vol；set 转 stable/beta 字符串仅 static，未保存设置。原生 App 提交、其他套件、复杂依赖、取消与安装/卸载未验证。

## 2026-10-03-photos-package-followup

**原环境元数据**：环境标识：待归属观察，不注册 current 基线；匿名设备别名：与历史 lab-a 关系未确认；基线状态：待归属；替代的旧基线：none；发现日期：2026-10-03；DSM 版本：7.2.1；DSM build：69057；Update：12；设备架构类别：未验证；连接方式：浏览器为 QuickConnect 直连类别；测试应用显示局域网连接，不记录地址；证书类别：未验证；账号权限类别：能查看官方套件中心；未额外读取角色

**套件及来源**：ActiveInsight / Active Insight / 3.0.5-24122 / 本轮不改变状态 / 用户截图与当前客户端清单；官方候选 install_type 为 system；SynologyPhotos / Synology Photos / 1.8.2-10090 / 本轮不改变状态 / 当前客户端已安装清单；没有更改照片或套件

**证据与结论**：来源：官方已安装清单、静态分支、用户反馈与原生测试包。read-verified：ActiveInsight 候选 install_type=system；允许系统类型缺省 volume_list 仅为官方静态分支，没有本轮真实 Installation.check 响应或更新。照片观察是刷新后旧操作错误提示残留，源码修正错误归属与终态清理；最初失败操作未确认，不能声称具体媒体/保存/分享/转换接口已复验。未继续更新其他套件、未修改照片。

## 2026-10-06-container-vmm-api-read-observation

**原环境元数据**：环境标识：待归属；不凭相同版本推定为历史 lab-a；匿名设备别名：待核实与历史设备关系；基线状态：待归属观察，不新增 current 基线；替代的旧基线：none；尚未确认升级关系；发现日期：2026-10-06；DSM 版本：7.2.1；官方信息中心当前显示；DSM build：69057；Update：12；设备架构类别：未知；本次仅在兼容必要时核实；连接方式：Chrome 既有 HTTPS QuickConnect 直连域名；仅记录连接类别；证书类别：尚未独立核实；账号权限类别：已登录且可见控制面板与套件中心管理视图；群组角色未独立核实

**套件及来源**：`container-manager` / Container Manager / 24.0.2-1535 / 正在运行 / 官方套件中心“安装的版本”当前显示，应用已打开；`virtual-machine-manager` / Virtual Machine Manager / 2.6.5-12202 / 正在运行 / 官方套件中心“安装的版本”当前显示，既有应用窗口存在；未连接任何 VM 控制台

**证据与结论**：来源：官方版本页面、自然请求与当前 MainVue.js/virtualization.js。read-verified：Docker Container/Network/Image.list、Registry.get v1、Project.list v1 空对象及 Virtualization.Cluster.get v2；非空项目字段仍仅 static。Container profile、Project CRUD/流式操作、VMM get/set/delete/pwr_ctl/映像/网络等方法的本轮补充均 static；不得把其他日期的 Guest 读取或受控创建算成本轮行为。未操作真实资源或连接 VM。

## 2026-10-07-photos-rotation-observation

**原环境元数据**：环境标识：待归属观察；匿名设备别名：待核实与历史设备关系；基线状态：待归属；不新增 current 基线；替代的旧基线：none；发现日期：2026-10-07；DSM 版本：7.2.1；当前官方信息中心；DSM build：69057；Update：12；设备架构类别：未核实；连接方式：HTTPS QuickConnect 直连；仅记录类别；证书类别：未独立核实；账号权限类别：已登录且可见管理页面；群组未独立核实

**套件及来源**：synology-photos / Synology Photos / 1.8.2-10090（2026-10-03 记录；当前待复核） / 不改变状态 / 仅静态核对

**证据与结论**：来源：官方已加载静态回调。static：旋转成功分支刷新布局和缩略图；显示尺寸不能替代原始分辨率，也不能凭宽高交换认定成功。未执行 NAS 旋转，Photos 完整版本为前次记录、当前未复核。

## 2026-10-07-vmm-power-read-observation

**原环境元数据**：环境标识：待归属观察；匿名设备别名：待核实与历史设备关系；基线状态：待归属；不新增 current 基线；替代的旧基线：none；发现日期：2026-10-07；DSM 版本：7.2.1；当前官方信息中心显示；DSM build：69057；Update：12；设备架构类别：未核实；连接方式：Chrome 既有 HTTPS QuickConnect 直连域名；仅记录类别；证书类别：未独立核实；账号权限类别：已登录且可见管理页面；群组角色未独立核实

**套件及来源**：`virtual-machine-manager` / Virtual Machine Manager / 2.6.5-12202 / 正在运行；当前官方套件中心显示 / 仅读取已加载官方定义及必要字段类型

**证据与结论**：来源：官方已加载 virtualization.js；系统/套件版本另由信息中心与套件中心核实。static：pwr_ctl 成功回调未消费任务身份，uptime 只是 parseInt/格式化的显示候选，原生类型、单位及重启后变化未验证；仍 running 不证明重启完成。未发送电源写，公开 v1 无 reboot 不能改用强制断电再开机替代。

## 2026-10-16-windows-read-regression

**原环境元数据**：环境标识 / 设备别名：待归属；不凭相同版本认定为历史 lab-a；基线状态 / 替代基线：待归属观察，不建立 current，不替代旧记录；发现日期：2026-10-16；DSM 版本 / build / Update：7.2.1 / 69057 / 12；官方信息中心当前显示；连接方式：Chrome 既有 QuickConnect HTTPS；应用沿已有连接解析和证书策略，只记录连接类别；证书类别：浏览器证书链未独立核实；应用未更改信任策略或保存新信任；权限类别：既有登录会话；可打开控制面板，Photos 个人来源启用、共享角色为 none；不推断其他账号权限

**套件及来源**：官方套件中心自然 SYNO.Core.Package.list v2 成功响应：Synology Photos 1.8.2-10090；Synology Chat 2.4.1-22111；Download Station 4.1.2-5012；Virtual Machine Manager 2.6.5-12202

**证据与结论**：来源：官方页面必要读取、官方 react_bundle.js，以及既有应用会话/证书策略下的生产 Repository 定点只读调用。read-verified：Photos time 秒/indexed_time 毫秒、授权/时间线/项目/缩略图/目录/相册/本人分享；Chat normal/file/system/vote 及 file_props 对象；VMM protect_ids=[] 合法。修复后对应 Windows 读取通过。下载公开读取成功且旧包对照也成功，原截图失败未稳定复现；数字字符串/null 修复不能冒称实机根因。static：官方脚本对 indexed_time 除1000。无写入、无共享照片提权、无控制台连接。

### 2026-10-16 方法级结果

| 范围 | 观察与复验 | 证据等级 |
| --- | --- | --- |
| Photos 授权 | UserInfo.me 和 Setting.User/Admin/TeamSpace.get v1 成功；enabled/home 为布尔，id/uid 为数字，package_version 与 team_space_permission 为字符串 | read-verified |
| Photos 时间线 | Timeline.get v5，section[].list[] 的年月日、item_count 为整数，日期合法；应用原实现此步成功 | read-verified |
| Photos 项目 | Item.list v4 的 time 为秒，indexed_time 为整数毫秒且有非整秒精度。原实现在 Timestamp 越界；固定毫秒解码后列表成功 | read-verified |
| Photos 官方脚本 | 已加载 react_bundle.js 对最近添加执行 Math.floor(indexed_time / 1e3)，并把过滤秒边界乘 1000；不按数值猜单位 | static |
| Photos 主流程 | 修复后的应用读取授权、时间线、项目、首张缩略图、个人根目录/子目录、相册和本人分享列表均成功；缩略图仅内存使用并清除 | read-verified |
| Chat | 官方 Post.list v5 同页包含 normal/file/system/vote；file 的 file_props 是对象，normal 样本未含该字段。原 Windows 将已属于消息树的节点重挂 JsonArray 会抛异常；修复后应用三个会话消息页读取成功 | read-verified；解析错误另有正式合成回归 |
| 下载 | 官方网页使用 DownloadStation2，不能当公开 Task.list 的证据。应用公开 Task.list、Statistic.getinfo、Info.getconfig/getinfo、Schedule.getconfig、RSS.Site.list 均成功；活动/设置/RSS 分区 Available。随后使用用户原测试包的 Infrastructure DLL 做同会话只读对照，下载也成功，因此截图中的下载失败本次未稳定复现；数字字符串/null 兼容是独立的已知解析改进，不冒称实机根因 | read-verified |
| VMM | 官方 Plan.list v2 成功返回 protect_ids=[]。旧包同会话保护分区 Failed，当前修复后公开虚拟机/主机/存储/网络/映像和内部保护六分区全部 Available | read-verified |
