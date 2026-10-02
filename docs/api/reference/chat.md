# Synology Chat

本项目实现普通用户会话，使用内部 `SYNO.Chat.*`；公开 Bot/Webhook 的 `SYNO.Chat.External` 不能代替用户聊天权限。主实现：[DsmChatRepository](../../../apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift)，领域：[Chat](../../../apple/Packages/DsmCore/Sources/Chat.swift)。

## 功能与请求

| 领域操作 | API / 方法 | 关键约束 |
| --- | --- | --- |
| 用户与会话列表 | `User.list`、`Channel.list` | 使用当前用户可见清单，保留 API 返回身份；会话/用户不得按显示名关联 |
| 成员 | `Channel.Member.get` v1 | 固定会话 ID，成员权限与当前会话上下文绑定 |
| 历史消息 | `Post.list` | 使用服务返回的消息/分页身份，保持原始消息顺序和去重；失败不作空历史 |
| 发起一对一 | `Channel.Anonymous.initiate` v2 | 校验对端用户、现有会话与实际返回身份；丢回执不重复创建 |
| 私人群聊 | `Channel.Named.create` v1，再 `join/invite` v1 | 创建、加入、邀请分别核对，部分失败保留已创建群聊，不重复提交全部步骤 |
| 文字 / 附件发送 | `Post.create` v5 与附件上传流程 | 请求固定会话、内容快照与附件；确认服务端消息身份后才算发送成功 |
| 置顶 / 取消、转发 | `Post.pin/unpin/forward` v5 | 目标消息和目标会话绑定，读取当前成员资格；置顶读取使用相应搜索流程 |
| 消息删除、关闭会话 | `Post.delete`、`Channel.close` | 作者/操作权限、具体目标确认与最终状态检查；关闭会话不伪装删除所有历史 |
| 提醒 | `Post.Reminder.set/list/delete` v1 | 消息/会话与时间绑定，删除只针对所选提醒 |
| 投票 | `Post.Vote.create` v1 | `channel_id/message/choices/options`，精确对象形态见快照 |
| 定时消息 | `Post.Schedule.list/create/delete` v1 | 内容与发送时间保持固定；结果未知只查原任务 |
| 附件与头像 | `Post.File.thumbnail/get`、`User.Avatar` | 二进制按权限读取，认证不进入 URL，不把 JSON 错误当媒体 |

固定请求字段、JSON 参数差异、认证位置和读写策略见[Chat 请求参数目录](requests.md#chat)。其余逐项字段见[高级动作记录](../discovery/endpoints/chat-advanced-actions.md)和对应 Repository 方法。没有固定版本要求的方法仍须在当前客户端支持区间内选择，不自动改成 NAS 的最高版本。

## 结果与错误

领域输出为 `ChatUser/ChatConversation/ChatMessage/ChatMessagePage` 及专用创建/发送结果。新端必须区分本机草稿、请求已提交、服务端消息已确认和未知状态。遇到丢失回执，不允许凭相同文字、时间近似或可见列表中相似条目断言是本次发送。

图片、语音及附件使用既有下载/上传接口与尺寸/类型约束；不要把消息里任意 URL 当成有权携带 NAS 会话访问的地址。加密会话与普通会话的支持范围分开记录，缺少已验证实现时不假装解密。

## 实时通道

[DsmChatRealtimeClient](../../../apple/Packages/DsmNetwork/Sources/DsmChatRealtimeClient.swift) 使用同源 `sc/socket.io/` 的 WSS/Engine.IO 通道。该通道只发握手和心跳，内容事件仅触发既有 API 回读，不从事件载荷直接构造可信聊天记录。

EIO 版本、心跳、帧大小、超时、重连及轮询降级的完整约束见[实时记录](../discovery/endpoints/chat-realtime.md)。离开页面/切换 NAS/退出应结束旧订阅，迟到事件不能刷新另一个工作区；实时失败不阻断普通列表读取与手动刷新。

## 移植验收

先完成登录/列表/文字/分页，再接附件和高级动作。验证取消、断网后未知结果、重复点击、成员变化、同名不同 ID、不同 NAS、分页去重以及实时与轮询并存。输入法、键盘、触控与通知按目标平台实现；移动精选范围和加密能力边界见[Chat 长期计划](../../development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)。

测试入口：[DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmChat*`、[DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/) 的 Chat 状态与呈现测试。真实服务版本证据依旧查询[兼容索引](../../../contracts/private-api/compatibility.json)。
