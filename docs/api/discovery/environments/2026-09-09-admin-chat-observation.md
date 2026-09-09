# 管理员 Chat 入口只读观察

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不新建 current 基线 |
| 匿名设备别名 | 待确认是否为既有 lab-a，不以相同版本推断设备相同 |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-09-09 |
| DSM 版本、build、Update | 7.2.1 / 69057 / 12，官方 get_user_service 的 Session 白名单字段 |
| 设备架构类别 | 未验证 |
| 连接方式 | QuickConnect 直连 |
| 证书类别 | 未验证 |
| 账号权限类别 | 管理员，用户提供且 Session.is_admin=true |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 |
| --- | --- | --- | --- |
| synology-chat-server | Synology Chat Server | 2.4.1-22111，官方 get_ui_config 应用定义 | 官方页面可打开 |

## 证据来源与范围

- 已登录官方网页，只观察打开 Chat 页面产生的必要能力元数据。
- 不创建会话、不发送消息、不提取或保存消息正文、账号或用户目录。
- 当前目的：核对客户端新建会话能力判断；不提升既有内部写接口的验证等级。

## 安全检查

- 不保存 Cookie、SID、SynoToken、DID、OTP、密码及主机信息。
- 不保存真实文件路径、共享名、消息、用户信息或原始响应。
- 未手工发起 NAS 写请求；只保留脱敏版本、API 名称和参数结构。
- 官方 Chat 打开后自动显示原有会话，也可能自动更新已读或页面偏好；未观察确认这些副作用，不能将整次网页加载描述为服务端绝无变化。两张由本轮打开的 Chat 标签均已关闭，原 DSM 标签保留。
- 网络响应仅在内存中投影必要字段后清除；没有导出 HAR、响应、截图或会话资料。

## 结论

- 官方页面自然产生的 `SYNO.API.Info` 响应中，`SYNO.Chat.Channel.Anonymous` 为 v1–v2，`Channel.Named` / `Channel.Member` 为 v1，三者路径均为 `entry.cgi`、`requestFormat=JSON`。此元数据为 `read-verified`，不是创建行为验证。
- 同一响应的 `SYNO.FileStation.Search` 为 v1–v2、`entry.cgi`、`JSON`；未启动真实文件搜索或全盘分析。
- 旧 Apple 代码只接受 FORM，因而对上述已提供的 Chat 能力返回不可用。修复按能力声明使用项目现有统一编码器，不新增 API 方法、权限或版本。
- File Station 公开指南第 40–41 页要求搜索 `folder_path` 为路径数组。修正现有单字符串错误并去除该公开指南未列出的 `search_content` 参数；真实搜索仍未验证。
- DSM/Chat 版本已核实但设备匿名归属未核实；不修改旧 lab-a 的历史证据，也不将本次记录作为新的 current 基线。
- 新建单聊、建群、成员回读、真实容量分析与其他版本仍为 `PENDING_USER_VALIDATION`。
