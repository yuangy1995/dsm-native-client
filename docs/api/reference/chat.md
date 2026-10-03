# Synology Chat

本项目实现普通用户会话，使用内部 `SYNO.Chat.*`；公开 Bot/Webhook 的 `SYNO.Chat.External` 不能代替用户聊天权限。主实现：[DsmChatRepository](../../../apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift)，领域：[Chat](../../../apple/Packages/DsmCore/Sources/Chat.swift)。

## 功能与请求

| 领域操作 | API / 方法 | 关键约束 |
| --- | --- | --- |
| 用户与会话列表 | `User.list`、`Channel.list` | 使用当前用户可见清单，保留 API 返回身份；会话/用户不得按显示名关联 |
| 成员 | `Channel.Member.get` v1 | 固定会话 ID，成员权限与当前会话上下文绑定 |
| 历史消息 | `Post.list` v5 | `thread_id=0,prev_count,next_count`，更早页传定位 post_id 并排除重复定位记录；该版本忽略 offset/limit |
| 全文搜索 | `Post.search` v5 | keyword、in 数字数组、offset/limit；search_results 与 total，单独使用搜索游标 |
| 编辑本人消息 | `Post.set` v8、`Admin.Setting.get` v3 | 新鲜作者/原文/编辑时限预检、稳定请求、精确回读 |
| 线程回复 | `Post.create/list` v5 | thread_id 为根消息；根独立读取，回复初始页不传根 post_id |
| 参与投票 | `Post.Vote.vote/get_choices` v1 | choice_ids 字符串数组，提交完整选择并回读自己的选择和票数 |
| 阅读同步 | `Channel.view` v2、`Post.Subscribe.view` v2 | 仅实际可见、活跃窗口；主会话使用实际消息时间并回读 last_view_at |
| 发起一对一 | `Channel.Anonymous.initiate` v2 | 校验对端用户、现有会话与实际返回身份；丢回执不重复创建 |
| 私人群聊 | `Channel.Named.create` v1，再 `join/invite` v1 | 创建、加入、邀请分别核对，部分失败保留已创建群聊，不重复提交全部步骤 |
| 文字 / 附件发送 | `Post.create` v5 与附件上传流程 | 请求固定会话、内容快照与附件；确认服务端消息身份后才算发送成功 |
| 置顶 / 取消、转发 | `Post.pin/unpin/forward` v5 | 目标消息和目标会话绑定，读取当前成员资格；置顶读取使用相应搜索流程 |
| 消息删除、关闭会话 | `Post.delete`、`Channel.close` | 作者/操作权限、具体目标确认与最终状态检查；关闭会话不伪装删除所有历史 |
| 提醒 | `Post.Reminder.set/list/delete` v1 | 消息/会话与时间绑定，删除只针对所选提醒 |
| 投票 | `Post.Vote.create` v1 | `choices` 为 text 对象数组，`options` 为对象；expire_at=0 表示无截止 |
| 定时消息 | `Post.Schedule.list/create/delete` v1 | 内容与发送时间保持固定；结果未知只查原任务 |
| 附件与头像 | `Post.File.thumbnail/get`、`User.Avatar` | 二进制按权限读取，认证不进入 URL，不把 JSON 错误当媒体 |

固定请求字段、JSON 参数差异、认证位置和读写策略见[Chat 请求参数目录](requests.md#chat)。其余逐项字段见[高级动作记录](../discovery/endpoints/chat-advanced-actions.md)和对应 Repository 方法。没有固定版本要求的方法仍须在当前客户端支持区间内选择，不自动改成 NAS 的最高版本。

2026-10-03 的真实请求、响应字段、错误观察和能力要求见[消息交互契约](../discovery/endpoints/chat-message-interaction.md)。
新增领域能力为 messageSearch/messageEditing/threadedReplies/pollVoting/readSynchronization；ChatMessage 追加可选 kind/threadID/replyCount/editedAt，ChatConversation 追加可选 lastViewedAt，ChatMessageDraft 追加默认 nil 的 threadID。旧提供者的新方法默认明确拒绝，不隐式开放其他端入口。搜索结果使用 ChatSearchPage，编辑策略使用 ChatEditingPolicy，不改变既有持久化格式。

## 结果与错误

领域输出为 `ChatUser/ChatConversation/ChatMessage/ChatMessagePage` 及专用创建/发送结果。新端必须区分本机草稿、请求已提交、服务端消息已确认和未知状态。遇到丢失回执，不允许凭相同文字、时间近似或可见列表中相似条目断言是本次发送。

图片、语音及附件使用既有下载/上传接口与尺寸/类型约束；不要把消息里任意 URL 当成有权携带 NAS 会话访问的地址。加密会话与普通会话的支持范围分开记录，缺少已验证实现时不假装解密。

2026-10-03 macOS 正确性修复：文字与附件统一使用既有结果接口；本人身份不再由昵称推断，缺少本人布尔标记时可用本次认证写回执的稳定消息 ID、原会话和精确内容进行回读，明确他人身份或加密内容仍拒绝确认。投票和定时消息必须保留返回身份并检查实际对象，提醒检查同一消息与时间；转发要求成功回执及目标会话相对提交前新增的唯一匹配记录，丢失回执不自动重放。删除定位与结果检查覆盖完整分页，坏列表不能伪装为空。所有新增状态只在内存保留，不新增持久化或 NAS 方法。界面只显示业务状态和刷新操作，内部结果分类不作为日常提示。执行证据与限制见[修复账本](../../development/MACOS_CHAT_FIX_20261003_ZH.md)。

## 实时通道

[DsmChatRealtimeClient](../../../apple/Packages/DsmNetwork/Sources/DsmChatRealtimeClient.swift) 使用同源 `sc/socket.io/` 的 WSS/Engine.IO 通道。该通道只发握手和心跳，内容事件仅触发既有 API 回读，不从事件载荷直接构造可信聊天记录。

EIO 版本、心跳、帧大小、超时、重连及轮询降级的完整约束见[实时记录](../discovery/endpoints/chat-realtime.md)。Chat 模块启用且 NAS 仍连接时，离开页面或切换当前 NAS 保留该工作区的独立订阅；关闭模块、断开该 NAS 或退出时结束订阅，迟到事件不能刷新另一个工作区；实时失败不阻断普通列表读取与手动刷新。

## 移植验收

先完成登录/列表/文字/分页，再接附件和高级动作。验证取消、断网后未知结果、重复点击、成员变化、同名不同 ID、不同 NAS、分页去重以及实时与轮询并存。输入法、键盘、触控与通知按目标平台实现；移动精选范围和加密能力边界见[Chat 长期计划](../../development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)。

测试入口：[DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmChat*`、[DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/) 的 Chat 状态与呈现测试。真实服务版本证据依旧查询[兼容索引](../../../contracts/private-api/compatibility.json)。

用户于 2026-10-03 明确要求开放全部已实现功能后，macOS 取消精确 DSM/Chat 版本白名单；新交互只检查实际 API 能力、会话权限、作者/编辑规则、去重与结果回读，不再依赖套件版本查询。其他版本仍需实测，不把开放入口视为兼容结论。
