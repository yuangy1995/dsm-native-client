# Chat 置顶读取反馈复验

本文件按环境模板建立；与同日五组功能观察使用同一已登录页面。设备匿名别名未重新确认，不建立或替换 current 基线。

| 字段 | 值 |
| --- | --- |
| 环境标识 / 匿名设备别名 | 待归属观察 / 未重新确认 |
| 基线状态 / 替代旧基线 | 观察记录，非 current / none |
| 日期 | 2026-10-03 |
| DSM 版本 / build / Update | 官方 Session 当前读取：7.2.1 / 69057 / 12 |
| 架构类别 | 未验证 |
| 连接方式 | 已登录官方网页；同日先前记录为 QuickConnect 直连，本轮未重测链路 |
| 证书类别 | 未单独记录，不绕过证书检查 |
| 权限类别 | 管理员，具有 Chat 使用权限；Session.is_admin=true |
| 套件 | Synology Chat Server / 2.4.1-22111 / 运行中 |
| 证据来源 | 官方 Chat WebAPI.sendPromise 的 Post_search 只读请求；Session 和 Utils.getChatVersion |

## 结果与边界

- `failed`：`SYNO.Chat.Post.search` v5 使用 `channel_id` 搭配 `has=["pin"]` 时，返回集合包含其他会话；请求成功不能证明过滤生效。
- `read-verified`：同一已选会话改为 `in=[数字会话ID]` 后成功，所有返回项归属当前会话。保留 offset、limit、has、sort_by、sort_by_array；返回包含 search_results 数组与 limit/offset/total 数字。
- 已核对消息字段名和类型，包括 channel_id、post_id、last_pin_at 数字、is_sticky 布尔；不保存任何真实值。未重新设置或取消置顶，未调用 Channel.view，不把本次观察写成写操作行为验证。
- 原生 macOS 的完整置顶列表与阅读同步仍须用户使用修复包验证；普通账号、其他 DSM/Chat 版本、中继未验证。
- 没有保存 Cookie、SID、SynoToken、DID、主机、账号、正文、文件路径或原始 HAR；仅输出字段名、类型、计数和匿名比较结果。诊断控制台临时输出已清理；官方网页自身可能自动更新阅读状态。

稳定契约与五端影响见 [消息交互记录](../endpoints/chat-message-interaction.md)。合成请求见 `contracts/request-fixtures/chat/list-pinned/synthetic-channel/request.json`，不含真实会话标识。
