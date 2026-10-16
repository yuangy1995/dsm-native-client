# Chat 高级消息与会话动作

投票、搜索、编辑、线程与已读的现行定义见[消息交互](chat-message-interaction.md)；以下高级方法与该定义共用版本/编码规则。

属于既有 `chat-internal` 端点组；分类为内部 API，个人提醒、定时消息和无附件投票是普通写，
取消操作需要确认；本记录也覆盖普通消息转发、公告设置/取消和关闭会话。请求路径来自
能力发现，当前记录为 `entry.cgi`；POST 外层始终是表单。

## 已记录请求

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

## 响应映射与证据

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

## Windows 能力与安全规则

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

### 转发、公告和关闭的结果核对

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

### Windows 批量编排

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

## 置顶搜索更正

置顶读取使用数字会话数组in；旧channel_id在10-03观察中被搜索忽略，失败证据留于环境索引，当前正文不保留旧参数作为可用方案。



## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
