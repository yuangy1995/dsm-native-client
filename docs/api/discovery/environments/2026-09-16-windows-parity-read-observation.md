# Windows 对齐过程的官方网页只读核查

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不建立 current 基线 |
| 匿名设备别名 | 未确认是否属于既有 lab-a，不以页面名称或相同版本推断 |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-09-16 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12，当前官方 get_user_service 的 Session 白名单字段 |
| 设备架构类别 | 未验证 |
| 连接方式 | Chrome 已登录官方 DSM，QuickConnect；直连或中继未验证 |
| 证书类别 | 未验证 |
| 账号权限类别 | 管理员，当前官方 Session.is_admin=true |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| synology-chat-server | Synology Chat Server | 2.4.1-22111 | 未单独核实运行状态 | 官方 Package.list 版本字段 |
| container-manager | Container Manager | 24.0.2-1535 | 官方页面可打开 | 官方 Package.list 版本字段 |
| synology-photos | Synology Photos | 1.8.2-10090 | 未单独核实运行状态 | 官方 Package.list 版本字段，不提升图库验证 |

## 证据来源

- 用户明确表示 Chrome 已登录 NAS，可按需核查；不包含写操作授权。
- 官方 DSM 刷新自然产生的 `SYNO.API.Info.query`、`SYNO.Core.Desktop.Initdata.get_user_service`
  和 `SYNO.Core.Package.list` 成功响应；只在内存投影白名单版本与能力，不保存原始载荷。
- 目标文档：`docs/development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md` 的剩余差距账本。

## 发现范围

- 本次目标：按需要观察官方网页的能力声明、页面读取和必要的版本信息。
- 明确不检查：创建会话、发送消息、容器生命周期、删除、网络或权限变更等写操作。
- 当前限制：设备归属未核实；真实客户端行为不能由网页元数据证明。已打开 Container Manager
  活动记录页，但本轮观察通道未取得可归属的日志 API 响应，因此不增加日志响应验证等级。

## 安全检查

- 不导出 HAR，不读取或保存 Cookie、SID、SynoToken、DID、OTP、密码。
- 不保存地址、账号、真实路径、文件名、聊天内容或日志正文；只保留字段类型与必要版本。
- 不绕过登录/证书/浏览器权限提示；若遇到交给用户处理，不阻塞无依赖源码切片。
- 不创建临时原始响应文件或截图；浏览器观察只能增加对应证据等级，不能提升写验证结论。
- 未手动创建会话、发送消息或执行容器/网络/删除写操作。官方桌面刷新自然发出认证恢复、
  令牌读取、`UserSettings.apply`、WebRTC 连接控制等请求；未提取这些载荷，不能声称整个
  网页加载绝无服务端副作用。没有据此构建新写契约。
- 观察结束关闭 Network 监听并清除原始响应变量；返回 DSM 桌面，保留用户原标签，未导出 HAR。

## 结论

- `read-verified` 仅限能力元数据：`SYNO.Chat.Channel.Anonymous` v1–v2，`Named/Member` v1；
  `SYNO.Docker.Container/Log` v1。五项均为 `entry.cgi`、`requestFormat=JSON`。
- Windows FORM-only 创建/成员门与当前能力声明确实不一致；对应修复仍以真实 HTTP 合成链
  验证，不将元数据读取说成成功创建。容器读取须对字符串使用 JSON 编码。
- 未验证：Windows 新包真实会话、建群、邀请、独立成员回读、完整日志分页及全部危险写行为。
- 其他版本、普通/受限账号和连接类别仍需独立复验；不冒用既有 lab-a 历史证据。
