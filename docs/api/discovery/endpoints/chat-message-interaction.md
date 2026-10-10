# Chat 消息搜索、编辑、线程、投票参与与已读

稳定端点组：`chat-message-interaction`；既有 `chat-internal` 的消息交互增量。全部属于内部 API。
观察来源：[2026-10-03 环境记录](../environments/2026-10-03-chat-five-features-observation.md)。
当前实际观察组合：DSM **7.2.1-69057 Update 12**、Chat **2.4.1-22111**，管理员账号、QuickConnect 直连。
设备匿名归属未重新确认；不把该观察硬关联到 `lab-a`，不覆盖历史环境基线。

## 请求、版本与编码

相对路径取 `SYNO.API.Info`，本次均为 `entry.cgi`。HTTP 外层是 POST 表单；能力声明 JSON
时每个业务值编码为 JSON 值，再置入对应表单字段。认证沿用既有请求头/表单，不进入媒体 URL。
`conn_id` 是官方页面的事件回声关联字段；本次合成编辑、回复、投票、已读调用均未传入，仍成功。

| API / 版本 | method | 参数与含义 | 证据 |
|---|---|---|---|
| `SYNO.Chat.Post` v5 | list | `channel_id`；`thread_id=0` 为主时间线；`prev_count`、`next_count` 控制前后数量；后续传定位 `post_id` | read-verified |
| 同上 | list | 定位单条：`post_id` 为目标，`prev_count=0,next_count=0`；回复携带所属 `thread_id` | read-verified |
| 同上 | search | `keyword` 字符串、`in` 数字会话数组，空数组搜索当前账号全部可见聊天；`offset`、`limit` | read-verified |
| `SYNO.Chat.Admin.Setting` v3 | get | 无业务参数；读取 `allow_edit_message`、`allow_edit_message_time_within_min` | read-verified |
| `SYNO.Chat.Post` v8 | set | `channel_id`、`post_id`、`message` | behavior-verified，仅本轮合成消息 |
| `SYNO.Chat.Post` v5 | create | `channel_id`、`message`、`type=normal`、`is_thread=false`、`thread_id=根消息 ID` | behavior-verified，仅本轮合成回复 |
| `SYNO.Chat.Post.Vote` v1 | create | `channel_id`、`message`、`choices=[{text:…}]`、`options` 对象；新选项不发送 id | behavior-verified，纠正旧字符串数组/JSON 文本形态 |
| 同上 | get_choices | `post_id` | read-verified |
| 同上 | vote | `post_id`、`choice_ids` **字符串数组**；传完整选择集合 | behavior-verified，非匿名多选投票的一项选择 |
| `SYNO.Chat.Channel` v2 | view | `channel_id`、`last_view_at` Unix 毫秒整数，来自实际显示消息的 `create_at` | behavior-verified，Channel.list 回读已推进 |
| `SYNO.Chat.Post.Subscribe` v2 | view | `channel_id`、`thread_id` | observed，合成线程返回成功；未单独证明未读线程计数变化 |

### 分页不能混用

- `Post.list` 的 `offset/limit` 在该版本被忽略；观察中 `limit=1` 仍返回 10 条。禁止继续使用
  该方式或依据其 `total` 推算历史完整性。
- 正常初始页：`thread_id=0,prev_count=N,next_count=0`，不传 `post_id`，取得最近消息。
  更早页以已读页最早原始记录 ID 定位，响应可能包含该定位记录，合并前排除它。辅助空记录
  仍参与游标推进。没有真实 `total/has_more`；不足 N 条作为末页，满 N 条允许再读取一页。
- 线程初始页传 `thread_id=根 ID,prev_count=N,next_count=0`，**不以根 ID 作为 post_id**。
  本次该错误组合只返回根消息。根消息独立定位读取，线程列表返回回复；后续以最早回复 ID 定位。
- 搜索继续使用其独立的 `offset/limit`，响应为 `search_results` 数组与 `total` 整数，不能与
  `Post.list` 游标混用。搜索结果固定消息/会话身份；加密会话不显示解密占位内容。

## 响应与领域映射

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

## 修改、权限与失败语义

1. 用户明确要求开放已实现功能与版本限制后，macOS 新增写入不再匹配 DSM/Chat 精确版本白名单，也不依赖管理员可读的套件版本接口；按 NAS 声明的实际 API 版本范围开放。登录、会话访问、作者身份、编辑策略、目标确认、去重和回读继续执行。能力缺失仍不可发送不受支持的请求；普通账号及其他版本仍未经过真实行为验收。
2. 编辑前重新读取作者、内容基线及管理员设置；只修改本人普通消息/附件说明，排除投票、贴纸、
   系统和加密消息。分钟数 0 表示不限时间，否则按原发送时间计算。其他设备已经修改原文时拒绝覆盖。
3. 编辑、投票和回复绑定原会话、消息、完整草稿和稳定请求 ID。网络未知只回读，不换 ID 自动重放；
   同目标处理中不能提交第二个动作。编辑回读同 ID、作者及新文字，投票回读当前用户完整选择与计数，
   回复沿用既有发送结果并另外要求所属线程一致。显式拒绝和提交后未知分别处理。
4. 已结束/过期投票不可提交；单选最多一项，多选提交全部选择，选项身份/文字或问题已变则要求重新读取。
5. 本次错误观察：旧 `options` JSON 文本产生 117；仅改 options 对象但仍传 choices 字符串数组产生 101。
   这些是该错误请求的结果，不推广为所有 DSM 版本的全局错误解释。
6. 主消息与投票创建的旧功能本轮修正请求形态；这不等于为其他平台已经实现相同修复。

## 媒体与通知的边界

- 播放沿用 `Post.File.get`，保存到私有临时目录后交给 AVPlayer；没有新增播放 API，不向消息 URL
  附加凭据。播放准备限定 512 MiB，关闭播放器清理临时文件。系统不支持的编码保留另存路径。
- 语音使用 AVAudioRecorder 生成 AAC，先试听，再显式发送；最长 5 分钟。只在用户点击录音时申请
  麦克风，不使用后台常驻录音。上传沿用既有 `Post.create` v5 文件流程，失败草稿由原发送状态保留。
- 系统通知基于新一轮会话数据和真实消息回读，首轮旧消息不通知、本人消息不通知、加密消息不展开。
  默认通知不包含正文；应用需运行并连接。Chat 启用时连接绑定 NAS 工作区生命周期，离开页面或切换当前 NAS 不停止订阅；关闭模块、断开该 NAS 或退出时停止。后台收到消息不推进已读。系统通知与麦克风硬件效果属于本地系统授权验证，未由网页测试代替。

## 五端影响

| 平台 | 本轮变化与后续 |
|---|---|
| macOS | 原生搜索、编辑、回复、投票、媒体/录音、通知和已读流程；本地测试/打包证据见功能账本 |
| iOS | 共享 Apple 网络分页、投票映射/编码修正；新协议有拒绝默认实现。未新增移动入口，录音/通知不在本轮移动 DAG |
| iPadOS | 与 iOS 相同；未增加桌面多窗口、常驻通知或麦克风权限；不把尚未实现的移动功能标为仅待真机验收 |
| Android | 只记录契约差异，未修改代码；后续需核实原分页与投票创建参数，不得复制错误旧样例 |
| Windows | 只记录新语义和旧投票样例纠正，未修改代码；既有用户授权的版本能力策略保持原样，不以 macOS 结果代替 Windows 验证 |

本轮未确认匿名投票、关闭投票操作、普通账号、其他 DSM/Chat 版本及 QuickConnect 中继组合。
来源、源码、正式测试及 `PENDING_USER_VALIDATION` 条件见
[五组功能账本](../../../archive/2026-h2/MACOS_FEEDBACK_HISTORY.md#macos-chat-五组功能补齐账本)。

## 2026-10-03 置顶搜索修正

- 内部只读接口：`SYNO.Chat.Post` / `search` / v5，POST，路径由 `SYNO.API.Info` 发现；要求当前账号能访问目标未加密会话，不扩大置顶/取消置顶写权限。
- 参数：`in=[数字会话ID]`、`has=["pin"]`、`offset=0` 起、`limit=100`、`sort_by="last_pin_at"`、`sort_by_array=["is_sticky","last_pin_at"]`。FORM/JSON 声明均保持 `in` 为数字数组，不能传字符串数组或 `channel_id`。
- 当前响应：`search_results` 消息数组，`total/offset/limit` 数字；置顶时间为 `last_pin_at`，大于零才作为有效置顶。短页或总数边界结束分页，保留既有日期映射和降序呈现。
- 当前环境只读复验：旧 `channel_id` 请求成功但含其他会话，属于过滤失效；`in` 结果全部属于请求会话。证据为 [2026-10-03 观察](../environments/2026-10-03-chat-pinned-read-observation.md)，不替换历史匿名环境或证明置顶写入。
- 客户端仍拒绝跨会话/重复/坏结构，不通过丢弃越界项掩盖请求错误。读取失败显示可重试的置顶错误，合法空数组显示没有置顶消息，不阻断聊天正文。无响应模型或持久化 Schema 变更。
- 自动化：`DsmChatFiveFeatureTests` 覆盖 FORM/JSON 数字数组、101 项分页、空列表与跨会话拒绝；`DsmChatRepositoryTests` 保留 pin 后回读；合成请求 fixture 在 `contracts/request-fixtures/chat/list-pinned/synthetic-channel/request.json`。

| 平台 | 本次影响 |
| --- | --- |
| macOS | 共享请求修正；消息内语音、通知入口、可见位置已读另见七项反馈账本；已读写契约不变 |
| iOS / iPadOS | 共享 Apple 请求获得修正；两端均不增加置顶页面、录音或桌面通知功能，保持既有移动范围 |
| Android | 不改实现；若已有置顶搜索使用 channel_id，后续授权切片改为数字 in 并运行目标平台测试 |
| Windows | 既有高级动作置顶读取同样需后续修正；本轮只登记影响，不宣称已对齐或仅缺真机 |


## 2026-10-04 移动投票恢复增量

M4b1 沿用上表 Vote.create/get_choices/vote 与 Post.list，不增加 NAS 请求或提高环境证据等级。共享 Apple `ChatRepository` 增加创建消息身份保存回调，以及只读 `pollMessage`；旧创建入口继续有效，其他提供者的只读新方法默认拒绝。创建回执先保存、后读取原消息；保存失败保持未知。只读详情重读当前账号/会话，再读取当前选择与票数，选项身份缺失或重复不作为有效结果；已确认的原投票请求可以在内存中结束，用户后续主动改选使用新操作。

iOS/iPadOS 的原生创建、结果与投票采用独立受保护 `Chat/polls-v1.json`，保存账号摘要、操作/消息 ID、草稿与完整选择摘要；不保存问题正文、选项文字、凭据或投票者名单。收到创建 ID 才能在重启后认领同一对象，完全丢回执时不以同内容消息推断归属。恢复只读；写前存储失败零提交，未知目标跨重启继续限制，其他账号和无关聊天不受污染。当前开发格式不附加旧版本兼容。

五端影响：iOS/iPadOS 获得原生投票流程及恢复；macOS 继续原 UI/存储，通过兼容的共享调用与回归；Windows/Android 无请求、代码或存储变化，仅登记本协议增量。客户端合成测试、模拟器及真实设备验收分别记入[移动 M4b1 账本](../../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#m4b1-投票创建参与与恢复)；不操作真实 NAS，也不将普通账号、匿名规则或其他版本标为已实测。
