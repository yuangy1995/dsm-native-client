# Chat 会话基础接口

### `chat-internal`

相关消息读取/写入见[消息交互](chat-message-interaction.md)和[高级动作](chat-advanced-actions.md)。

- 组件：`synology-chat-server`
- API 与客户端范围：
  - `SYNO.Chat.Channel` v1-v5。
  - `SYNO.Chat.Channel.Named` v1。
  - `SYNO.Chat.Channel.Anonymous` v1-v2，当前确认 `initiate` v2。
  - `SYNO.Chat.Channel.Member` v1。
  - `SYNO.Chat.User` v1-v3、`SYNO.Chat.User.Avatar` v1。
  - `SYNO.Chat.Post` v1-v8；当前确认的创建、转发与公告方法使用 v5。
  - `SYNO.Chat.Post.File` v1-v2，当前确认 v2。
  - `SYNO.Chat.Post.Reminder`、`Post.Vote`、`Post.Schedule` v1。
- 当前证据：Chat Server `2.4.1-22111` 官方网页客户端与能力发现契约；读取、创建、删除、提醒、投票等仍按原兼容矩阵的单项证据等级处理。
- 降级：内部接口不可用时隐藏聊天能力，不用公开 Bot/Webhook API 冒充用户会话。

## 会话创建与编码

- [待归属管理员观察](../environments/INDEX.md#2026-09-09-admin-chat-observation)核实了 `Anonymous` v2、`Named` v1、`Member` v1 的 `requestFormat=JSON`；旧的 FORM-only 判定错误，不能将 JSON 声明当成无权限或接口缺失。仅元数据达到 `read-verified`，未执行真实创建。
- 请求仍为 POST `application/x-www-form-urlencoded`，相对路径采用能力发现的 `entry.cgi`。JSON 声明表示业务字段按 JSON 值编码，再作为表单字段发送，并不是直接发送 JSON HTTP 正文。
- 固定使用 `Anonymous.initiate` v2（`user_ids` 数组、`encrypted=false`、`channel_key_encs=[]`）；群聊使用 `Named.create` v1（`name`、`type=private`），随后 `join(channel_id)`、`invite(channel_id,user_ids,channel_key_encs)`。空密钥数组必须保持数组，不编码成内容为 `[]` 的字符串。
- 创建响应需要候选 `channel_id/id`，但不能单凭候选判断成功；单聊重读会话列表，群聊另外使用 `Member.get` v1 的 `user_ids` 确认所有所选成员。`success=false` 的显式拒绝与传输未知分开处理，沿用现有固定请求 ID、串行创建和未知结果处理。
- 仍需当前账号有 Chat 使用权限，版本缺失/Member 缺失时不开放对应创建；加密会话不因编码修复而开放。没有手动发送消息、创建群聊或执行权限变更。
- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift`；FORM 和 JSON 的能力、完整创建链、数组编码、回读及去重测试见同包 `Tests/DsmChatRepositoryTests.swift`；JSON 合成请求见 `contracts/request-fixtures/chat/create-private-group/synthetic-json/request.json`。
平台状态与限制见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)及[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。
