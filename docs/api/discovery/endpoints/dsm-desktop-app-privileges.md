# DSM 当前账号应用权限摘要（候选）

## 标识

- 稳定标识：`dsm-desktop-app-privileges`；组件：`dsm-core`；范围：DSM。
- 分类：内部 API；操作：读取；风险：medium（初始化响应含会话和用户设置，不得完整记录）。
- 状态：已按用户确认的策略接入 macOS，App 会话实机验证待完成；已有成功网页观察，设备归属待确认，机器索引 verifications 为空。

## 请求契约

| 字段 | 本次实际观察 |
| --- | --- |
| API | SYNO.Core.Desktop.Initdata |
| 路径 | /webapi/entry.cgi |
| HTTP 方法 | GET |
| method | get_user_service |
| version | 1 |
| launch_app | 查询参数字符串 null，不是空串；必需性未验证 |
| 请求 Content-Type | application/x-www-form-urlencoded; charset=UTF-8 |
| 鉴权 | 官方已登录网页，请求有令牌 Header；没有复制任何值，未验证本地 App 会话兼容性 |

未重放请求，不推断 POST 可用，也不推断可省略 launch_app。其他同名 API 方法不在本记录契约范围内。

## 响应与权限

- 成功包络：success=true，data 为对象。
- data 字段结构：ActionPrivilege 为数组；AppPrivilege、GroupSettings、ServiceStatus、Session、UserSettings 为对象。
- 本次 AppPrivilege 为对象，13 个键的值均为布尔值；以下仅列本任务必要投影：

| 稳定应用键 | 本次状态 | 官方主菜单 |
| --- | --- | --- |
| SYNO.SDS.App.FileStation3.Instance | true | 可见 |
| SYNO.SDS.Chat.Application | true | 可见 |
| SYNO.SDS.Drive.Application | true | 可见 |
| SYNO.SDS.DownloadStation.Application | 键缺失 | 不可见 |
| SYNO.SDS.ContainerManager.Application | 键缺失 | 不可见 |
| SYNO.SDS.Virtualization.Application | 键缺失 | 不可见 |

后三项应用类名同时存在于官方 get_ui_config 返回的 JSConfig 中；这不是“已授权”证据，也不把混淆变量名用作业务协议。当前只记录关联，不宣称授权表单独决定了所有菜单可见性。

- Session.is_admin=false、isLogined=true；Session 还提供 DSM 版本字段，见环境观察记录。
- 未观察到明确 false、该方法自身的无权限/失效/字段缺失响应。缺失键与明确拒绝的区别仍需复验，不得直接等同。
- 禁止把 Session 或 UserSettings 整体写入诊断或日志。

## 版本验证

### 同日管理员对照：不能将所有缺失键解释为禁止

同一浏览器切换管理员后，get_user_service 返回 is_admin=true，版本保持 7.2.1-69057 Update 12。AppPrivilege 有 25 个键；File Station、Chat、Drive 保持 true，Download Station 与 VMM 的应用键新增并为 true。

**Container Manager 和控制面板在管理员 AppPrivilege 中仍缺失，但官方主菜单显示它们。** 官方 get_ui_config 中应用定义的必要投影：

| 应用定义 | allUsers | grantPrivilege | advanceGrantPrivilege |
| --- | --- | --- | --- |
| SYNO.SDS.ContainerManager.Application | false | 未出现 | 未出现 |
| SYNO.SDS.AdminCenter.Application | false | 未出现 | 未出现 |
| SYNO.SDS.Virtualization.Application | false | all | true |
| SYNO.SDS.DownloadStation.Application | true | local | true |

因此需区分管理员管理入口与可授予应用权限的套件。不能对所有入口统一套用“AppPrivilege 缺失即隐藏”，也不能对所有 allUsers=false 的应用统一套用管理员限制，VMM 已体现独立应用授权。此处只记录本环境官方定义与菜单的交叉证据，不以混淆变量或界面译文建立契约。

本机语言、主题、连接等设置与上述 NAS 权限无关，应始终可用。用户确认 NAS 设置整体与容器要求显式 is_admin=true；独立应用仅允许对应 AppPrivilege 键为 true。显式 false 不得由管理员身份覆盖。入口允许不等于具体写操作获准，原权限及确认门禁仍然必要。该策略已接入 macOS，尚未完成 App 会话验证。

用户补充 VMM 为手工安装且机型非官方支持。安装来源与应用授权分开处理：既有 VMM 原生模块依据稳定应用授权与已有接口能力决定入口，不新增机型白名单拦截，不依据安装成功自动放行，也不把菜单可见提升为完整兼容验证。任意第三方应用不自动映射成原生模块；没有明确授权规则或专门 Adapter 时不试探其业务接口，更不解锁套件写操作。

2026-09-09 在 DSM 7.2.1-69057 Update 12 的非管理员官方网页中观察到请求并读取成功响应；证据详见 [环境观察](../environments/2026-09-09-nonadmin-permission-observation.md)。设备是否为旧 lab-a 尚未确认，因此不建立已归属的 read-verified verification，也不改变现有产品支持矩阵。

## 能力探测与降级

- macOS 先通过 SYNO.API.Info 协商 v1，仅读取 get_user_service；沿用既有 GET Header 认证，绝不把凭据放入 URL。不查询其他应用业务数据，不解析菜单译文或动态执行 JSConfig。
- 用户确认的入口策略：File Station、Chat、下载、VMM 明确 true 才允许，缺失或 false 隐藏；管理设置与容器要求管理员且对应键不为 false。还需已有接口能力，手动安装与机型不单独限制；未知第三方应用键全部忽略。
- AppPrivilege 整表缺失或已知字段类型错误与有效空表严格区分：有效空表不额外请求文件；摘要失败才保留原文件只读会话确认，其他模块全部关闭，并提供本地化刷新提示。安全错误和取消不触发额外探测。没有伪造空授权响应或改写 119。
- 请求缺失、失败或响应类型变化不得阻断文件主流程；不能退回逐个加载容器/虚拟机/下载业务列表的权限试探。
- AppPrivilege 只决定入口可用性候选，不替代具体操作的权限校验，尤其不能解锁危险写操作。
- 未确认有公开 API 能等价提供本次摘要；不据此宣称不存在公开替代。

## 客户端、测试与五端影响

- macOS：`WorkspaceModuleAccessReader` 改为一次摘要读取；权限整体替换，隐藏模块停止后台模型并禁止导航，套件模型另阻止旧页面加载/操作回调。照片功能仍为 File Station 文件视图，继承文件权限，不接入 Photos API。
- iPhone / iPad：共享网络层仅增加只读服务和能力名称，默认能力发现可登记该能力；移动 App 未调用新服务，页面和业务行为不变。本轮使用 macOS 回归验证共享代码，不冒充移动设备验证。
- Android / Windows：记录相同规则供后续对齐，本轮不改两端代码或请求。
- 新服务：`apple/Packages/DsmNetwork/Sources/DsmDesktopAppPrivileges.swift`；测试：`apple/Packages/DsmNetwork/Tests/DsmDesktopAppPrivilegesTests.swift`、`apple/Apps/DsmMac/Tests/WorkspaceModuleAccessTests.swift`。白名单解码忽略真实会话和用户设置，合成 fixture 内联于测试，不保存原始响应。
- [产品验证状态](../../../compatibility/DSM_COMPATIBILITY_MATRIX.md) 标记 App 实机待验；没有把代码接入提升为环境验证。
- 机器索引沿用 private-api-compatibility.schema.json；当前验证限于文档和索引一致性。

## 安全与副作用

该方法是官方页面已发出的读取，没有手工重放。页面导航自动发出的 UserSettings.apply 等请求另见环境记录，不属于本读取契约，也未由 Agent 修改或重放。未打开受限组件、聊天或用户文件内容；没有新增写操作。

## 未验证事项

设备归属；更多管理员及普通账号；明确 false 和缺失键的完整服务端语义（当前按用户确认策略处理）；其他 DSM build；最小必需参数；错误码；与本地 App 登录会话的兼容性；返回授权与菜单最终过滤条件的完整关系；客户端组件请求导致后续文件 119 的具体原因。
