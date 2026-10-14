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
| 消息删除、关闭会话 | `Post.delete`、`Channel.close` v5 | 删除重读作者/原内容与会话访问，完整历史确认消失；未知只读恢复，关闭会话不伪装删除所有历史 |
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

2026-10-03 macOS 正确性修复：文字与附件统一使用既有结果接口；本人身份不再由昵称推断，缺少本人布尔标记时可用本次认证写回执的稳定消息 ID、原会话和精确内容进行回读，明确他人身份或加密内容仍拒绝确认。投票和定时消息必须保留返回身份并检查实际对象，提醒检查同一消息与时间；转发要求成功回执及目标会话相对提交前新增的唯一匹配记录，丢失回执不自动重放。删除定位与结果检查覆盖完整分页，坏列表不能伪装为空。所有新增状态只在内存保留，不新增持久化或 NAS 方法。界面只显示业务状态和刷新操作，内部结果分类不作为日常提示。执行证据与限制见[修复账本](../../archive/2026-h2/MACOS_FEEDBACK_HISTORY.md#macos-chat-正确性修复账本)。

## 2026-10-05 Apple 单聊恢复增量

`openDirectConversationResult(...willSubmit:)` 在新鲜用户/会话预检之后、Anonymous v2 写入之前调用本机保存回调；复用已有普通单聊时无需写入。回调失败或提交前取消时零创建请求，原调用方式继续使用相同请求。`recoverDirectConversation` 只查询会话并导入原操作身份，同编号的普通调用也只能回读；必须为当前用户与指定对端组成的未加密单聊，成员总数存在时必须为 2。打开该正确单聊即可满足用户目标，不以群聊同名或消息内容猜测结果。

iPhone/iPad 在独立受保护文件中保存账号上下文、请求/对端身份及提交阶段，不保存凭据或消息。已提交未知在重启后只读取；同账号执行互斥、明确拒绝释放、完成记录保存失败继续保护及换账号迟到结果均由移动模型负责。保存提交阶段后、实际网络写入前终止仍可能永久缺少结果，不允许自动超时重发。群聊与消息发送持久恢复已由 M4b4 接入，当前范围见 Chat 长期计划。

五端影响：macOS 继续原调用并接受更精确的单聊成员/加密检查，需共享测试与 Mac 双架构回归；iPhone/iPad 接入新增恢复方法和存储；Windows/Android 仅记录同等结果语义，无源码与请求变更。没有增加 NAS 参数、私有 API 或真实环境证据，不更新既有兼容记录的验证等级。当前实现与验证见[移动 M4b3b2](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#m4b3b2-新联系人单聊恢复)。

## 实时通道

[DsmChatRealtimeClient](../../../apple/Packages/DsmNetwork/Sources/DsmChatRealtimeClient.swift) 使用同源 `sc/socket.io/` 的 WSS/Engine.IO 通道。该通道只发握手和心跳，内容事件仅触发既有 API 回读，不从事件载荷直接构造可信聊天记录。

EIO 版本、心跳、帧大小、超时、重连及轮询降级的完整约束见[实时记录](../discovery/endpoints/chat-realtime.md)。Chat 模块启用且 NAS 仍连接时，离开页面或切换当前 NAS 保留该工作区的独立订阅；关闭模块、断开该 NAS 或退出时结束订阅，迟到事件不能刷新另一个工作区；实时失败不阻断普通列表读取与手动刷新。

## 移植验收

先完成登录/列表/文字/分页，再接附件和高级动作。验证取消、断网后未知结果、重复点击、成员变化、同名不同 ID、不同 NAS、分页去重以及实时与轮询并存。输入法、键盘、触控与通知按目标平台实现；当前移动实施范围见[M0–M8 主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)，加密边界及其他平台见[Chat 长期计划](../../development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)。

测试入口：[DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmChat*`、[DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/) 的 Chat 状态与呈现测试。真实服务版本证据依旧查询[兼容索引](../../../contracts/private-api/compatibility.json)。

用户于 2026-10-03 明确要求开放全部已实现功能后，macOS 取消精确 DSM/Chat 版本白名单；新交互只检查实际 API 能力、会话权限、作者/编辑规则、去重与结果回读，不再依赖套件版本查询。其他版本仍需实测，不把开放入口视为兼容结论。

## 2026-10-04 移动 M4a 接入

iPhone/iPad 已接入现有搜索、本人编辑与线程回复协议，使用移动搜索页面、消息菜单和线程详情。搜索 offset 与线程历史游标互不混用；搜索得到的旧回复单独定位，并读取原线程。附件沿用原有受控下载、预览和导出，不读取正文中的任意 URL。编辑重新检查原文、本人身份和策略，回复必须回读同一会话/线程及本次返回身份。

移动 `Chat/interactions-v1.json` 只保存账号上下文、操作/原对象/作者身份、文字 SHA-256 摘要及请求编号，受系统文件保护且排除备份；无正文、认证秘密或旧开发数据迁移。写前保存失败零提交；未知编辑只回读原消息与摘要，未知回复在重启后仍禁止相同内容再次发送，不凭相似文字认定归属。退出线程取消下载并清理临时展示，账号失效后迟到结果不进入当前界面。

本次没有新增或修改 NAS 请求、公开契约及共享 Chat 实现。macOS 只做共享资源/工程回归；Windows/Android 没有本次源码变更或新的兼容结论。投票、提醒、定时、语音和阅读同步已由后续 M4 切片接入；真实 NAS/设备验证仍记录在移动主计划。


## 2026-10-05 移动批量转发接入

移动端使用既有 `forwardMessage(original:…, recordProgress:)`、`recoverForward` 及单聊写前回调/只读恢复；没有新增 NAS 字段或改变 Post v5 / Anonymous v2 请求。每条消息转发到本批已准备成功的全部目标，确认结果保留到各目标稳定消息身份；部分完成只读补查询，随后需用户明确继续下一条。没有成功回执时保持未知，不猜测同内容归属。

`Chat/forwarding-v1.json` 独立保存来源身份、时间、内容摘要、接收身份、创建阶段和共享回执，不保存正文、联系人姓名或附件内容；原消息变化、写前存储失败、重复来源、跨账号回调、编辑/删除/关闭和单聊创建互斥由移动功能模型处理。iPhone/iPad 功能一致，原生多选/搜索/结果表单不同于 Mac 窗口交互。macOS、Windows、Android 没有本次请求或实现变化，共享前置验证见已有记录；真实环境证据不提升。当前验收见[移动 M4b3b3](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#m4b3b3-批量转发与接收人结果)。


## 2026-10-05 Apple 发送恢复共享基础

普通文字、线程文字与单附件发送新增最小回执及保存回调；旧调用进入同一请求流程，发送后回读失败保留未知，同编号不能换内容或重发。新只读恢复按创建返回编号读取原会话/线程，核对账号、作者和内容摘要；没有编号不认领相同内容。写前和创建回执先保存，附件恢复不依赖原本机文件。接口、五端影响和证据边界见[发送回执契约](../discovery/endpoints/chat-advanced-actions.md#2026-10-05-apple-普通发送持久回执)。这是 M4b4a 共享前置，移动普通/线程/附件队列在 M4b4b 接入，群聊恢复在 M4b4c 实施；不把共享模型存在当作移动功能完成。

## 2026-10-05 移动本人消息删除恢复

M4b3c 将单条和多条删除统一为原内容快照及逐项持久记录，共享增加写前保存回调和只读恢复，旧 Mac 调用进入同一实现。固定 Post v5，写前/回读均检查当前作者与可访问未加密会话，完整历史找不到目标才确认；丢回执、读取失败、空辅助记录或权限丢失不解除保护。恢复只查原项，继续剩余项单独确认；确认期间冻结消息，迟到读取不插回已删除对象。两端完整单元、五项实际 UI、共享和 Mac 双架构已有通过证据；真实 NAS 权限、分页/并发编辑及真机保护继续待验。详见[删除契约增量](../discovery/endpoints/chat-advanced-actions.md#2026-10-05-apple-本人消息删除恢复)及[移动账本](../../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md#m4b3c-本人消息批量删除)。

移动发送接入补充（2026-10-05）：iPhone/iPad 的文字、线程及单附件统一使用以上保存回调，关闭无回调的移动写入口；独立本机队列为继续未发送草稿暂存正文与受保护附件副本，成功后清理，不改变共享最小回执的数据边界。结果未知只读，重启不重放；明确拒绝的用户重试使用新请求编号并替换原终态记录。NAS 参数、认证、能力和权限语义未变，Mac 保留原调用，Windows/Android 无本轮实现变更。

## 2026-10-05 移动语音接入

M4c 的录音发送复用 Post.create v5 单附件及既有持久发送回执，语音播放复用 Post.File 读取；没有新增 NAS 参数、公开契约或新的私有接口证据。移动透出已有 voiceMessage 能力，AAC 录音与其他音频附件经过相同账号、权限、保存和未知结果恢复边界；读取仍只按消息身份，不访问正文中的任意地址。麦克风仅由用户主动录制申请，后台/中断停止或暂停，不开启后台音频模式。macOS 仅共享双语资源回归，Windows/Android 无实现变化，不提升任何真实环境验证等级。实现、两端验证与设备待办见[移动 M4c](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。

## Apple 移动 M4d 接入

iPhone/iPad 沿用已记录的 Channel.view v2 和 Post.Subscribe.view v2，不新增私有字段或公开接口。主会话只提交实际可见最新消息的 create_at，读取 Channel.list 确认 last_view_at；同步失败保持未读，缓存时间不得回退其他客户端更晚的阅读。线程先读取最新回复身份再提交 view，真实线程未读计数仍按原端点证据等级记录，不能把合成成功提高为实机验证。

实时连接复用共享 Apple 的源站、证书与凭据约束；移动 App 前台且当前账号启用 Chat 时运行，离开聊天页面保留订阅，后台取消，事件和 30 秒轮询均通过业务 API 回读。通知与定时提醒是移动系统适配，不改变 NAS 请求或凭据；本机最多安排最近 50 条未来提醒，后台期间其他客户端的改期/取消只能在重新连接后同步。源码与双端验证集中在[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)，当前真实 NAS 与系统通知行为未新增验证结论。

## 2026-10-13 Android A5 接入

Android A5 的正式消息主流程和当前环境聚焦界面验收已接通，真实NAS兼容仍待验；系统通知已由A9接入，见下文。现有历史读取已迁移为 Post v5 原始消息游标，搜索仍使用独立 offset；新增同一 Chat Repository 的搜索、完整公告、线程、本人编辑、投票参与和阅读同步。用户身份仅使用账号字段/明确本人标记；错误目录与冲突身份不开放写入，加密正文不进入消息列表。投票兼容显示缺少真实选项身份的旧形态，但不据此发起投票。

新增动作编排共用独立加密恢复记录，覆盖文字/回复/附件、编辑/投票、公告/删除/关闭、提醒/定时/投票创建，以及单聊、群聊分步和转发。记录包含账号身份、操作/对象编号、摘要、阶段和返回编号，不保存正文、文件名或凭据；写前保存失败零提交，缺回执不按相同内容认领，恢复只读取原对象。群聊分别保存创建、加入和邀请，已创建群不因后续失败重建；转发按既有成功回执、各目标基线、时间范围和唯一新身份判断，保留部分完成。正式 Compose 入口与主模型已改为调用同一动作模型；主模型原有创建、发送与重试编排已经删除。A10已删除旧 Repository 的无人调用写门面与旧相似消息匹配/重试状态辅助，原有效断言迁到正式执行器、持久锁与动作模型；仍在使用的原界面显示投影和附件读取保留。

普通文字沿用公共请求样本的 channel_id/message；线程回复单独携带 type/is_thread/thread_id。附件预检保留名称非空、不含路径分隔符、长度与正文上限；投票选项按稳定区域规则忽略大小写拒绝重复。A10迁移回归定位并补回这三处与原行为/样本的差异，未新增NAS方法、公开字段或改变持久格式。

附件沿用已有 Post.create v5 multipart，按能力声明编码业务字符串，认证位置不变。请求最外层使用不可重放正文，修正当前网络库未向外传播子正文标记的问题。网络错误分类追加“明确 API 拒绝”事实，HTTP拒绝与传输/取消仍保留提交未知；这只是 Android 内部结果映射，没有新增 NAS 字段、共享协议或其他端源码变化。

独立加密草稿另存正文、原消息快照与成员选择，附件先复制到应用私有目录，再进行写前预检；成功清理本次草稿，未知结果和未提交内容在重启后保留，恢复不会自动发送。多条删除/转发/关闭另存固定顺序，确认后逐项执行；中途未知停止后续，只读恢复后必须再次点击继续。移除连接清理该连接草稿和副本，运行中的操作阻止移除，其他账号记录不受影响。

语音按已批准范围新增可选麦克风权限，用户主动申请后录制 AAC，最长5分钟，离开应用或聊天页停止；停止后进入独立未发送草稿，试听、取消与发送分别操作。音频附件复用原 Post.File v2 安全下载与既有播放器，没有正文URL下载。仅增加独立本机存储，不迁移旧消息/登录数据，回滚可移除新入口与新增权限而保留既有存储格式。物理麦克风、系统打断和实际NAS仍待验证。

当前证据为本机合成请求/持久恢复/读取状态聚焦测试、手机中文浅色和英文平板深色二倍字号各六项原生流程及既有表单/无障碍回归；模拟器已运行录音、试听和取消，不新增NAS或物理设备兼容结论。集中验收与剩余范围见 [A5账本](../../archive/2026-h2/ANDROID_REWRITE_IMPLEMENTATION_HISTORY_ZH.md#a5-chat-整模块功能对齐账本)。


## 2026-10-14 Android A9 本地通知

当前前台工作区启用通知后复用 `ChatFeatureModel` 的唯一实时连接，离开 Chat 页继续收事件，进入后台停止；事件合并及一分钟补读通过既有 Channel.list/Post.list 回读。首次只建基线，仅真实较新、未读、非本人、非加密且未实际阅读的消息显示通用提醒；不会因通知推进已读，也没有快捷回复或后台发送。实时事件不重复扫描全部提醒，确认过的提醒动作会主动触发同步。

Post.Reminder.list 的实际结果保存在独立加密本地索引，仍复用既有严格身份/时间解码；每个原身份最多安排最近50条，通过 [WorkManager 延迟执行](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work) 承接。系统省电和调度可延后，不能承诺准点；后台期间其他客户端的取消或改期只有再次前台同步后才知道。Worker 只带随机编号、不联网、不发送消息，领取前复查本地启用和原账号身份，已消费或改期编号不能重发。显示前保存消费事实，极端进程终止可能漏发一次；不以重复通知换取重放。关闭或撤权清理相应计划，通知中仅有通用标题与原账号不透明会话入口，无正文、地址、路径或原始对象编号。

使用既有 [POST_NOTIFICATIONS 运行时权限](https://developer.android.com/develop/ui/compose/notifications/notification-permission) 和独立系统通知频道；用户主动启用，拒绝后可进入系统设置。没有新增 NAS API、请求字段、第三方依赖、精确闹钟权限或远程推送服务。其他四端契约/实现不变，Android 加密索引与系统行为的合成/设备证据见 A9 账本，真实NAS兼容等级不提升。

## 写入可用性与版本策略（五端统一）

五端均按实际接口能力、当前账号/对象权限、必要确认、防重复提交和结果复查开放操作；不匹配DSM/build/套件或客户端类型版本白名单，也不为版本匹配要求额外系统管理读取权限。未实测版本不标为已验证，但不据此关闭功能。

Android已移除A10误加的版本门和附加元数据查询。普通Photos/Chat账号可按套件与对象实际授权使用写入；文件设置、权限、挂载和系统管理仍保留功能本身要求的权限。能力缺失、参数或原对象变化、实际权限拒绝仍会停止对应操作；未知提交只读恢复，不自动重放。

版本记录用于追踪证据和排障，不构成功能白名单。本轮不改NAS接口参数、存储格式或其他端原有业务实现。源码与验证见[Android主计划](../../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md#a10-当前工作与剩余条件)。
