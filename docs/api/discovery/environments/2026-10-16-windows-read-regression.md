# Windows 读取故障只读核查

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 / 设备别名 | 待归属；不凭相同版本认定为历史 lab-a |
| 基线状态 / 替代基线 | 待归属观察，不建立 current，不替代旧记录 |
| 发现日期 | 2026-10-16 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12；官方信息中心当前显示 |
| 连接方式 | Chrome 既有 QuickConnect HTTPS；应用沿已有连接解析和证书策略，只记录连接类别 |
| 证书类别 | 浏览器证书链未独立核实；应用未更改信任策略或保存新信任 |
| 权限类别 | 既有登录会话；可打开控制面板，Photos 个人来源启用、共享角色为 none；不推断其他账号权限 |

## 相关套件

版本由官方套件中心自然产生的 SYNO.Core.Package.list v2 成功结果读取，只输出套件标识与版本。

| 组件 | 完整版本 |
| --- | --- |
| Synology Photos | 1.8.2-10090 |
| Synology Chat | 2.4.1-22111 |
| Download Station | 4.1.2-5012 |
| Virtual Machine Manager | 2.6.5-12202 |

## 证据与边界

先观察官方页面必要读取和已加载官方静态脚本；随后使用应用已有会话、原证书策略和生产 Transport/Repository 做定点只读诊断。诊断不重新登录、不加载写恢复存储、不调用写接口，只允许已记录的 query/me/get/list 以及公开下载 getinfo/getconfig。输出限 API 名称、HTTP 状态、字段类型/合法性布尔、失败枚举与方法名；不输出异常正文、响应内容或真实项目值。临时诊断源码和编译目录已删除；浏览器观察已停止，临时会话数据已清空。

Chrome 中单独打开公开 query.cgi 导航遭 ERR_BLOCKED_BY_CLIENT，已关闭，没有绕过浏览器限制。应用按既有公开能力发现正常返回：Photos 为 JSON、entry.cgi，UserInfo/Setting 为 v1，Timeline 最高 v5、Item 最高 v6；Chat.Post 为 JSON、v1–v8；公开 DownloadStation.Task 为 FORM、v1–v3。只读诊断按固定实现版本调用，不选最高版本代替方法契约。

## 读取结论

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

真实会话仅覆盖该套件组合及当前权限；没有开启共享照片权限、修改/删除照片、发送或标记已读消息、创建/控制下载、启停虚拟机、修改保护计划或连接控制台。

## 五端影响与安全

- Windows 固定 indexed_time 毫秒解码；普通照片、原件快照、自动预览身份保持同一精度。领域与持久结构不变，旧错误时间的恢复记录不会被自动改写或重放。
- macOS、iPhone、iPad 共用 Apple Repository；Android 也需要单独复核索引时间、最近添加、原件快照及恢复匹配。本轮只登记影响，不改其源码、不运行其构建、不宣称已修复。
- VMM 非空 protect_ids 的后续详情形态没有本次证据，Windows 不将其静默当空，也不猜 get 请求。
- 正式回归数据全部合成；没有保存凭据、真实地址、账号、路径、文件名、消息、原始响应或 HAR。

## 后续验证

PENDING_USER_VALIDATION：在本轮新 Windows 包中重连原 NAS，分别打开照片四分区、消息、下载和 VMM；预期正常内容/明确空状态，照片初始无未操作的权限提示、VMM 空保护计划无刷新警告。再验证实际窗口缩放、Narrator、触控及持续使用；仅回传模块、操作步骤、套件版本和已脱敏错误，不回传原始请求或用户内容。危险写操作不在本轮只读验收范围，保留原有专项保护。
