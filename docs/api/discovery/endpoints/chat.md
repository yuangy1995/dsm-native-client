# Chat 会话、实时事件与消息交互

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="chat-core"></a>
## Chat 会话基础接口


<a id="chat-internal"></a>

#### `chat-internal`

相关消息读取/写入见[消息交互](chat.md#chat-message-interaction)和[高级动作](chat.md#chat-advanced-actions)。

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

### 会话创建与编码

- [待归属管理员观察](../environments/INDEX.md#2026-09-09-admin-chat-observation)核实了 `Anonymous` v2、`Named` v1、`Member` v1 的 `requestFormat=JSON`；旧的 FORM-only 判定错误，不能将 JSON 声明当成无权限或接口缺失。仅元数据达到 `read-verified`，未执行真实创建。
- 请求仍为 POST `application/x-www-form-urlencoded`，相对路径采用能力发现的 `entry.cgi`。JSON 声明表示业务字段按 JSON 值编码，再作为表单字段发送，并不是直接发送 JSON HTTP 正文。
- 固定使用 `Anonymous.initiate` v2（`user_ids` 数组、`encrypted=false`、`channel_key_encs=[]`）；群聊使用 `Named.create` v1（`name`、`type=private`），随后 `join(channel_id)`、`invite(channel_id,user_ids,channel_key_encs)`。空密钥数组必须保持数组，不编码成内容为 `[]` 的字符串。
- 创建响应需要候选 `channel_id/id`，但不能单凭候选判断成功；单聊重读会话列表，群聊另外使用 `Member.get` v1 的 `user_ids` 确认所有所选成员。`success=false` 的显式拒绝与传输未知分开处理，沿用现有固定请求 ID、串行创建和未知结果处理。
- 仍需当前账号有 Chat 使用权限，版本缺失/Member 缺失时不开放对应创建；加密会话不因编码修复而开放。没有手动发送消息、创建群聊或执行权限变更。
- Apple Adapter：`apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift`；FORM 和 JSON 的能力、完整创建链、数组编码、回读及去重测试见同包 `Tests/DsmChatRepositoryTests.swift`；JSON 合成请求见 `contracts/request-fixtures/chat/create-private-group/synthetic-json/request.json`。
平台状态与限制见[平台矩阵](../../../progress/PLATFORM_MATRIX.md)及[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。

<a id="chat-realtime"></a>
## Chat 实时事件通道


稳定端点组：`chat-realtime`。内部、只读提示通道，业务消息始终通过既有 Chat API 回读。
NAS 专属路径/认证证据来自已有环境基线和 Apple Adapter；通用协议细节参考
[Engine.IO 官方协议](https://socket.io/docs/v4/engine-io-protocol/)及
[Socket.IO 官方协议](https://socket.io/docs/v4/socket-io-protocol/)。
本记录新增 Windows 源码与合成证据，不新增真实 NAS/Chat Server 验证结论。

2026-09-17 刷新时序回归：连接前轮询和 Connected 后补读可能先后发生，不能把
第一个回调一律视为连接后的刷新。Windows 内部使用可注入的标准 TimeProvider，
生产仍默认系统时间和既有 5 秒/30 秒/250ms 间隔；测试以手动时间和请求屏障分别
验证两种顺序、连接后低频校准、断开后轮询和停止清理，不以 30ms 墙钟等待判断
没有回读。未修改网络协议、事件内容或安全策略。

### 请求与协议

| 项目 | Windows 实现 |
| --- | --- |
| 地址 | 当前 HTTPS 源站及既有基础路径下的 `sc/socket.io/`，WebSocket 使用 WSS。 |
| 方法 | 原生 WebSocket GET 升级；查询仅 `EIO=4` 或 `3`、`transport=websocket`。 |
| 认证 | 复用当前会话 Cookie 和令牌请求头；不得在 URL、事件对象、日志或遥测中出现秘密。 |
| 来源 | Origin 仅当前源站 authority；拒绝用户信息、额外查询/fragment 和异 profile 会话。 |
| TLS | 使用现有 HttpClient 和 WindowsCertificateTrustHandler，上下文继续绑定 profile；不新建证书回调、不绕过中继系统信任。 |
| 生命周期 | 订阅归属已连接工作区；离开页面或切换当前 NAS 保留独立订阅。关闭模块、断开该 NAS 或销毁工作区时结束订阅；可见范围只控制消息刷新和已读同步。 |

源码证据：`apple/Packages/DsmNetwork/Sources/DsmChatRealtimeClient.swift` 与测试；Windows
`DsmApiClient.ChatRealtime.cs`、`DsmChatRealtimeClient.cs`、`DsmRepository.ChatRealtime.cs`。
现有环境范围见 `contracts/private-api/compatibility.json` 的原 `chat-realtime` 条目，不覆盖
历史版本。当前适配记录覆盖 EIO 4/3，但各 NAS/代理版本的实际协商仍待用户验证。

Windows 系统 ClientWebSocket 的自定义 invoker 接收 WSS 请求。适配器核对完整预期地址后
将其转换为同源 HTTPS，再走既有 HttpClient；不是跨源跳转。保留 App 原来禁用自动重定向
的处理器配置。握手拒绝/重定向的合成测试验证一次请求且不跟随异源地址；成功 101 的双向
合成流覆盖原生握手、控制帧、事件及取消，不能替代真实 TLS 或代理兼容验收。

### 帧与错误语义

- 网络连接与 Engine.IO/默认 namespace 握手分别有 20 秒上限。只有有效 open 后的默认
  namespace ACK 才产生 Connected；更早的内容事件忽略。
- open 读取非空、最多 512 字符的临时连接标识，绝不传入 App。心跳读取毫秒字段，缺省
  25 秒间隔/20 秒超时；字段存在但非法、非正或超过每项 300 秒的客户端上限则连接失败。
- EIO 4 响应服务端 ping，并在 interval+timeout 内收不到 ping 时断开；EIO 3 按协议历史
  的客户端 ping 方向发送并等待 pong。仅控制帧可写，不发送聊天、已读或输入状态事件。
- 支持 WebSocket 分片及严格 UTF-8，单帧合计最多 1 MiB；复合文本帧按分隔符处理。内容
  帧只变为 ContentChanged，不解释或记录载荷。关闭、协议错误、超时与无效编码转为降级。
- 首先尝试 EIO 4，未连接时尝试 3；记住本订阅成功版本。重试按 1/2/4…30 秒退避，连接
  成功后重置；取消立即退出，不将认证或信任失败当作已连接。
- 事件枚举队列最多 8 项，仅存枚举；页面按 250 毫秒合并内容变化。事件到达已有回读期间
  时，先等待该回读再做一次新读取，不并发读、不丢掉晚于旧快照的变化提示。
- 连接正常时每 30 秒校准，不可用时保留每 5 秒轮询。枚举未实现、结束或抛错不阻断列表、
  手动刷新和收发；旧代次取消后的事件不能改变重启后的页面或另一个 NAS。



源码核对：`apple/Apps/DsmMac/Sources/ChatWorkspaceModel.swift` 的 `syncWorkspaceChat` 与 `windows/src/LanStash.App/Features/Chat/ChatWorkspaceSession.cs`。此生命周期说明不提升网络实机证据。

<a id="chat-message-interaction"></a>
## Chat 消息搜索、编辑、线程、投票参与与已读


稳定端点组：`chat-message-interaction`；既有 `chat-internal` 的消息交互增量。全部属于内部 API。
观察来源：[2026-10-03 环境记录](../environments/INDEX.md#2026-10-03-chat-five-features-observation)。
当前实际观察组合：DSM **7.2.1-69057 Update 12**、Chat **2.4.1-22111**，管理员账号、QuickConnect 直连。
设备匿名归属未重新确认；不把该观察硬关联到 `lab-a`，不覆盖历史环境基线。

### 请求、版本与编码

相对路径取 `SYNO.API.Info`，本次均为 `entry.cgi`。HTTP 外层是 POST 表单；能力声明 JSON
时每个业务值编码为 JSON 值，再置入对应表单字段。认证沿用既有请求头/表单，不进入媒体 URL。
`conn_id` 是官方页面的事件回声关联字段；本次合成编辑、回复、投票、已读调用均未传入，仍成功。

| API / 版本 | method | 参数与含义 | 证据 |
|---|---|---|---|
| `SYNO.Chat.Post` v5 | list | `channel_id`；`thread_id=0` 为主时间线；`prev_count`、`next_count` 控制前后数量；后续传定位 `post_id` | read-verified |
| 同上 | list | 定位单条：`post_id` 为目标，`prev_count=0,next_count=0`；回复携带所属 `thread_id` | read-verified |
| 同上 | search | `keyword` 字符串、`in` 数字会话数组，空数组搜索当前账号全部可见聊天；`offset`、`limit` | read-verified |
| `SYNO.Chat.Admin.Setting` v3 | get | 无业务参数；读取 `allow_edit_message`、`allow_edit_message_time_within_min` | read-verified |
| `SYNO.Chat.Post` v8 | set | `channel_id`、`post_id`、`message` | behavior-verified，仅合成消息 |
| `SYNO.Chat.Post` v5 | create | `channel_id`、`message`、`type=normal`、`is_thread=false`、`thread_id=根消息 ID` | behavior-verified，仅合成回复 |
| `SYNO.Chat.Post.Vote` v1 | create | `channel_id`、`message`、`choices=[{text:…}]`、`options` 对象；新选项不发送 id | behavior-verified，纠正旧字符串数组/JSON 文本形态 |
| 同上 | get_choices | `post_id` | read-verified |
| 同上 | vote | `post_id`、`choice_ids` **字符串数组**；传完整选择集合 | behavior-verified，非匿名多选投票的一项选择 |
| `SYNO.Chat.Channel` v2 | view | `channel_id`、`last_view_at` Unix 毫秒整数，来自实际显示消息的 `create_at` | behavior-verified，Channel.list 回读已推进 |
| `SYNO.Chat.Post.Subscribe` v2 | view | `channel_id`、`thread_id` | observed，合成线程返回成功；未单独证明未读线程计数变化 |

#### 分页不能混用

- `Post.list` 的 `offset/limit` 在该版本被忽略；观察中 `limit=1` 仍返回 10 条。禁止继续使用
  该方式或依据其 `total` 推算历史完整性。
- 正常初始页：`thread_id=0,prev_count=N,next_count=0`，不传 `post_id`，取得最近消息。
  更早页以已读页最早原始记录 ID 定位，响应可能包含该定位记录，合并前排除它。辅助空记录
  仍参与游标推进。没有真实 `total/has_more`；不足 N 条作为末页，满 N 条允许再读取一页。
- 线程初始页传 `thread_id=根 ID,prev_count=N,next_count=0`，**不以根 ID 作为 post_id**。
  本次该错误组合只返回根消息。根消息独立定位读取，线程列表返回回复；后续以最早回复 ID 定位。
- 搜索继续使用其独立的 `offset/limit`，响应为 `search_results` 数组与 `total` 整数，不能与
  `Post.list` 游标混用。搜索结果固定消息/会话身份；加密会话不显示解密占位内容。

### 响应与领域映射

`post_id/channel_id/creator_id/create_at/update_at/thread_id/comment_count` 在本次观察为数字；
统一以稳定字符串 ID、Date、可选计数映射。`thread_id=0` 表示普通主消息，等于 `post_id` 表示
已有回复的根消息，其余非零值指向根。`update_at > create_at` 映射编辑时间，不能据此推断作者身份。
当前账号只能依据用户目录的账号字段或明确本人标记，不能用昵称获得修改权限。

投票在 **`props.vote`**：`state=open/close/delete`，`options` 包含
`multiple/anonymous/add_option` Boolean 与 `expire_at` 毫秒值；0 表示无截止。
`choices` 每项含 `id` 字符串、`text`、`count`、`voters` 数字 ID 数组。`get_choices` 返回根 `choices`。
适配器只计算当前用户是否选中并保留选项 ID/文字/票数，不保存或显示投票者名单。
历史顶层 vote/poll/vote_info 映射保留以兼容既有合成来源，但不能再把它们当成本版本真实形态。

`Channel.list` 中 `last_view_at` 为毫秒数，`unread` 为整数。客户端只在所属聊天窗口活跃、
最新消息可见时同步，使用读取到的消息时间，不用本机现在时间；回读成功前不抹掉未读数。
线程阅读方法不提供消息时间字段；提交前读取最后一条回复并要求仍是界面已显示的消息，否则不推进。单独记录其成功回执，不宣称与主会话相同的范围回读证明。

### 修改、权限与失败语义

1. 用户明确要求开放已实现功能与版本限制后，macOS 新增写入不再匹配 DSM/Chat 精确版本白名单，也不依赖管理员可读的套件版本接口；按 NAS 声明的实际 API 版本范围开放。登录、会话访问、作者身份、编辑策略、目标确认、去重和回读继续执行。能力缺失仍不可发送不受支持的请求；普通账号及其他版本仍未经过真实行为验收。
2. 编辑前重新读取作者、内容基线及管理员设置；只修改本人普通消息/附件说明，排除投票、贴纸、
   系统和加密消息。分钟数 0 表示不限时间，否则按原发送时间计算。其他设备已经修改原文时拒绝覆盖。
3. 编辑、投票和回复绑定原会话、消息、完整草稿和稳定请求 ID。网络未知只回读，不换 ID 自动重放；
   同目标处理中不能提交第二个动作。编辑回读同 ID、作者及新文字，投票回读当前用户完整选择与计数，
   回复沿用既有发送结果并另外要求所属线程一致。显式拒绝和提交后未知分别处理。
4. 已结束/过期投票不可提交；单选最多一项，多选提交全部选择，选项身份/文字或问题已变则要求重新读取。
5. 本次错误观察：旧 `options` JSON 文本产生 117；仅改 options 对象但仍传 choices 字符串数组产生 101。
   这些是该错误请求的结果，不推广为所有 DSM 版本的全局错误解释。
6. 主消息与投票创建的旧功能修正请求形态；这不等于为其他平台已经实现相同修复。

### 媒体与通知的边界

- 播放沿用 `Post.File.get`，保存到私有临时目录后交给 AVPlayer；没有新增播放 API，不向消息 URL
  附加凭据。播放准备限定 512 MiB，关闭播放器清理临时文件。系统不支持的编码保留另存路径。
- 语音使用 AVAudioRecorder 生成 AAC，先试听，再显式发送；最长 5 分钟。只在用户点击录音时申请
  麦克风，不使用后台常驻录音。上传沿用既有 `Post.create` v5 文件流程，失败草稿由原发送状态保留。
- 系统通知基于新一轮会话数据和真实消息回读，首轮旧消息不通知、本人消息不通知、加密消息不展开。
  默认通知不包含正文；应用需运行并连接。Chat 启用时连接绑定 NAS 工作区生命周期，离开页面或切换当前 NAS 不停止订阅；关闭模块、断开该 NAS 或退出时停止。后台收到消息不推进已读。系统通知与麦克风硬件效果属于本地系统授权验证，未由网页测试代替。

### 置顶搜索修正

- 内部只读接口：`SYNO.Chat.Post` / `search` / v5，POST，路径由 `SYNO.API.Info` 发现；要求当前账号能访问目标未加密会话，不扩大置顶/取消置顶写权限。
- 参数：`in=[数字会话ID]`、`has=["pin"]`、`offset=0` 起、`limit=100`、`sort_by="last_pin_at"`、`sort_by_array=["is_sticky","last_pin_at"]`。FORM/JSON 声明均保持 `in` 为数字数组，不能传字符串数组或 `channel_id`。
- 当前响应：`search_results` 消息数组，`total/offset/limit` 数字；置顶时间为 `last_pin_at`，大于零才作为有效置顶。短页或总数边界结束分页，保留既有日期映射和降序呈现。
- 当前环境只读复验：旧 `channel_id` 请求成功但含其他会话，属于过滤失效；`in` 结果全部属于请求会话。证据为 [2026-10-03 观察](../environments/INDEX.md#2026-10-03-chat-pinned-read-observation)，不替换历史匿名环境或证明置顶写入。
- 客户端仍拒绝跨会话/重复/坏结构，不通过丢弃越界项掩盖请求错误。读取失败显示可重试的置顶错误，合法空数组显示没有置顶消息，不阻断聊天正文。无响应模型或持久化 Schema 变更。
- 自动化：`DsmChatFiveFeatureTests` 覆盖 FORM/JSON 数字数组、101 项分页、空列表与跨会话拒绝；`DsmChatRepositoryTests` 保留 pin 后回读；合成请求 fixture 在 `contracts/request-fixtures/chat/list-pinned/synthetic-channel/request.json`。

<a id="chat-advanced-actions"></a>
## Chat 高级消息与会话动作


投票、搜索、编辑、线程与已读的现行定义见[消息交互](chat.md#chat-message-interaction)；以下高级方法与该定义共用版本/编码规则。

属于既有 `chat-internal` 端点组；分类为内部 API，个人提醒、定时消息和无附件投票是普通写，
取消操作需要确认；本记录也覆盖普通消息转发、公告设置/取消和关闭会话。请求路径来自
能力发现，当前记录为 `entry.cgi`；POST 外层始终是表单。

### 已记录请求

| API / 版本 | 方法 | 业务字段 |
| --- | --- | --- |
| `SYNO.Chat.Post.Reminder` / 1 | set | post_id 字符串；remind_at 为 Unix 毫秒的字符串表示 |
| 同上 | list / delete | list 使用 channel_id，delete 使用 post_id |
| `SYNO.Chat.Post.Schedule` / 1 | create | channel_id、message、send_at；send_at 为 Unix 毫秒的字符串表示 |
| 同上 | list / delete | list 使用 channel_id，delete 使用 cronjob_id |
| `SYNO.Chat.Post.Vote` / 1 | create | channel_id、message、choices 为[{text:…}]对象数组、options为对象 |
| `SYNO.Chat.Channel` / 5 | close | channel_id 字符串；只关闭当前用户会话，不删除消息 |
| `SYNO.Chat.Post` / 5 | forward | post_id 字符串；channel_ids 为数字数组，不是字符串数组 |
| 同上 | pin / unpin | post_id 字符串；仅未加密群聊 |
| 同上 | delete | post_id 字符串；仅当前会话内本人消息，删除前复核内容基线 |
| 同上 | search | in 为数字会话数组、offset、limit=100、has=["pin"]、sort_by=last_pin_at、sort_by_array=["is_sticky","last_pin_at"] |

`options` 内容为 `add_option=false`、`anonymous`、`multiple`。FORM 发送原始字符串与
序列化数组；JSON 声明下字符串再作 JSON 字符串编码，数组仍是数组，不把 `[]` 编码为文本。
毫秒值在 FORM 上与原有整数 fixture 的字节表示一致；JSON 变体按 Apple 既有
`DsmParameterValue.string` 编码。截止时间、修改定时消息和附件定时发送不得由本表推定；投票参与见消息交互定义。

### 响应映射与证据

以下是既有 Apple Adapter 和合成测试的 `static/sourceReviewed` 结构，不是新实机结论：

- 提醒列表可在根数组或 `reminders/posts/reminder_list/items/list/results` 中；项目使用
  post_id/message_id 和 remind_at/reminde_at/reminder_at/time，时间可位于 props。时间按已有
  日期规则识别秒或毫秒。响应显式包含会话 ID 时必须与请求一致。
  已有映射也接受带 post_id/message_id 的单条根对象；不能把无列表、无身份的对象当作空列表。
- 定时列表可在 `schedules/schedule_posts/scheduled_posts/cronjobs/items/list/results` 中；
  使用 cronjob_id/schedule_id/id、channel_id/conversation_id、message/text/content、
  send_at/scheduled_at/time。缺失身份、会话或时间不能伪装为合法空列表。
  带 cronjob_id/id 的单条根对象同样执行这些字段校验。
- 消息投票来自 vote/poll/vote_info 对象或 JSON 文本；choices/options 项目保留选项文字、
  ID、票数与当前用户状态；设置字段 multiple、anonymous、closed 及已记录同义字段按
  `DsmChatRepository.makePoll` 映射。不读取或存储投票者名单。
- 原始外层必须成功且列表结构有效；读取失败与空列表分开。可选投票附加字段无法解析时
  普通消息正文仍可显示，但该响应不能作为投票创建成功的证据。

证据路径：`apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift`，现有
`contracts/request-fixtures/chat/`，Windows `ChatAdvancedFlowTests/ChatAdvancedViewModelTests`。

### Windows 能力与安全规则

1. 用户 2026-09-16 明确批准 Windows 共享接口的兼容增量；未进行真实 NAS 写验证。
2. 按用户已明确的五端策略，实际API能力存在且权限允许时即可操作；不核对DSM/build/Chat精确版本白名单，也不要求管理员可读的系统版本摘要。版本记录只用于证据覆盖，不是只读开关。
3. 提交前重新核对实际API能力、会话可见性与未加密状态；关闭允许加密会话但不读取消息。提醒设置还验证消息归属该会话。默认按钮
   为关闭；取消提醒/定时消息带确认时完整基线，内容或时间变化即拒绝本次取消。
4. 固定请求 ID 与完整草稿绑定，进程内串行；同目标提交未知时只回读。Repository 重建后
   通过 profile/账号/目标指纹关联待核对状态，不保存旧 Repository 或 SID；静态记录仅驻内存，
   不持久化正文、凭据或原始响应。
5. 提醒核对目标与时间；定时核对 ID（存在时）、会话、正文和时间；投票核对本人消息、会话、
   候选 ID（存在时）、180 秒提交窗口、问题、全部选项和选项设置。无法唯一匹配不标成功。
   投票还排除提交前已读取到的消息 ID，旧的同内容投票不能确认新写；传输仍在进行时不抢先
   将另一客户端的回读结果提升为本次终态。
6. 网络/HTTP 失败、提交后取消或回读异常只进入待核对；明确 DSM 拒绝才是终态失败。
   重新编辑草稿不能复用旧请求 ID。成功后界面需要重新选择或编辑，连续点击不产生第二次创建。
7. 暂时离开对话框保留待核对草稿；重启进程不承诺恢复此内存状态，结果不明时先在官方 Chat
   核对，不把重新启动当成允许重复提交。提醒到期系统通知、投票参与、实时同步不由解锁。

#### 转发、公告和关闭的结果核对

- 关闭固定 v5，依据 macOS `closeConversation` 和既有 Channel 版本范围，不是新实机结论。
  回读必须具有完整合法的会话列表容器、唯一身份且无不可解析条目；缺失容器不能证明关闭。
  确认提示明确进入官方 Chat 归档，不删除消息；已经不可见的会话零提交。
- 转发预读来源内容与所有接收会话，不转发投票/加密消息，不选择来源会话。界面显示接收
  会话标题与已知成员供核对。Windows 支持多条已加载普通消息到多个既有会话；也支持选择
  新联系人，先通过既有 Anonymous v2 打开单聊，核对成员身份后再转发。
  每个目标记录最新 100 条身份基线；回读要求新身份、本人消息、正确会话、180 秒时间窗与
  正文/附件类型、名称、大小相同且唯一。附件是描述字段匹配，不宣称字节级内容校验。
  部分目标确认后只核对其余目标；结果不明时同一来源消息改变接收人也不能重新提交。
- 公告严格读取所有 100 条分页，拒绝缺失容器、异会话、重复身份或不前进页。设置前比较
  显示时的来源快照，取消前比较公告身份、正文和置顶时间；目标变化要求刷新后重新确认。
  pin/unpin 不用原写响应单独证明成功，必须回读期望状态。
- `GetMessageAsync` 仅封装既有消息分页查找，不新增 NAS `get` 端点。读取失败不能覆盖旧
  选择为另一个身份。所有动作继续复用同一高级操作状态机，不另建传输/重试管线。
- 本人消息删除已接入同一状态机，固定 Post v5，FORM/JSON 均编码字符串 post_id；移除旧的
  FORM-only 以及只核对最新 100 条的实现。查找/回读复用既有消息分页，检查身份、会话、
  容器、重复页、offset/total 与空洞；目标仍在较早页时不能误报删除成功。正文/附件快照
  变化、非本人和加密目标均零提交；成功/明确拒绝终态不重放，未知只核对。

#### Windows 批量编排

批量关闭、批量删除和批量转发在现有 `ChatAdvancedViewModel` 的同一待处理所有者内执行，
逐项固定请求 ID、内容和目标，按消息时间顺序转发。新联系人打开是前置项；身份不符或
创建失败不能继续消息转发。已成功/明确失败的项不重放；遇到未知暂停，点击“核对结果”
只调用已经开始的项。核对后还有未开始项时，必须另行勾选继续确认，避免连续点击跨过
核对与新写的边界；可选择不再执行剩余项，已完成变化不撤销。每个新项重新核对版本能力，
页面销毁后不开始后续写。进程重启仍不承诺恢复这份内存批次，未知结果先在官方 Chat 核对。

界面逐项展示完成/失败/待核对/未开始及汇总；单聊打开也作为独立项计数，不冒充已转发
消息。已经回读确认的删除会移除历史缓存，关闭会清理会话缓存与原有本地置顶记录，即使
后续刷新失败也保留这些确认结果。选项仅包含已加载消息；更早消息先在聊天页加载再选择。
关闭并非消息删除；批量删除有单独不可撤销提示及明确确认，不因批量入口放宽权限或版本门。

上述新增证据为 `static/sourceReviewed` 与本地合成测试 `ChatActionFlowTests`、
`ChatAdvancedViewModelTests/ChatBatchViewModelTests`，没有真实 NAS 写验证；FORM 与 JSON 均有真实 HttpClient
编码合成链覆盖。版本观察来源仍是原环境记录，不添加或覆盖历史环境基线。

### 置顶搜索更正

置顶读取使用数字会话数组in；旧channel_id在10-03观察中被搜索忽略，失败证据留于环境索引，当前正文不保留旧参数作为可用方案。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
