# Chat 五组功能的环境观察

本记录沿用环境模板字段；设备匿名归属未重新确认，不创建或替换 `current` 基线。

| 字段 | 值 |
|---|---|
| 环境标识 | 待归属观察 |
| 匿名设备别名 | 未重新确认，不以地址或相同版本推定设备 |
| 基线状态 | 观察记录，非 current |
| 替代旧基线 | none |
| 日期 | 2026-10-03 |
| DSM 版本/build/Update | 官方页面 Session 再次读取：7.2.1 / 69057 / 12 |
| 设备架构类别 | 未验证 |
| 连接方式 | 已登录官方网页，QuickConnect 直连 |
| 证书类别 | 未单独记录；不绕过浏览器或系统证书检查 |
| 账号权限类别 | 具有 Chat 使用权限的管理员；官方 Session.is_admin=true |
| Chat 套件完整版本 | 官方 Chat Utils.getChatVersion() 当前读取：2.4.1-22111 |

## 来源、范围与安全

- 用户明确要求实现五组聊天能力，并已授权在本人和测试账号之间发送测试内容。
- 默认只观察官方页面和必要请求；受控写入仅使用本任务新建的合成消息、回复和投票，不改动真实历史。
- 只记录 API 名称、版本、方法、字段名称/类型及脱敏结构；不保存地址、账号、真实消息、路径、Cookie、SID、令牌、DID、密码或原始响应。
- 官方页面可能自动推进已读，不能将整个网页加载描述为绝无服务端变化。
- 临时前端资源或观察文件在形成脱敏记录后删除；静态线索、请求观察、只读响应及实际行为严格分级，不互相替代。

## 当前结论

- `read-verified`：Post.list 定位分页和线程分页、Post.search keyword/in/offset/limit、Admin.Setting.get 编辑设置、Post.Vote.get_choices、Channel.list.last_view_at。
- `behavior-verified`：本轮新建合成消息的编辑与回读、合成根消息的线程回复与回读、合成投票创建及当前用户选择回读、Channel.view 写入并读取已推进的 last_view_at。
- `observed`：Post.Subscribe.view 对合成线程返回成功；未单独证明未读线程计数变化。
- `failed`：投票 options 为 JSON 文本时 117；options 为对象但 choices 仍是字符串数组时 101。官方表单静态方法证实新 choices 应为 text 对象数组，纠正后成功。
- 未执行真实原消息修改/删除，不创建或修改真实用户资料；没有采集音频或替用户接受麦克风/通知授权。
- 临时前端资源只用于读取静态代码；未导出网络 HAR，任务完成前清理资源与页面临时状态。

字段、权限、失败语义与五端影响见[消息交互记录](../endpoints/chat-message-interaction.md)。
