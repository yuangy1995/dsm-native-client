# Windows / Apple 移动端功能对齐账本：第 5 波

> 状态：源码与云端门禁完成；Apple A0/A1 和 Windows W0/W1 已通过本波全部云端构建与测试。真实 Chat Server、系统选择器和无障碍/弱网体验仍按 `PENDING_USER_VALIDATION` 验收
> 基线提交：`2491212da6f81c5b932d97a6af035cfef0719e8f`（`接入跨端活动中心下载任务投影`）
> 实施分支：`codex/chat03-attachments`
> 当前范围：Windows/iPhone/iPad `CHAT-03 单附件选择、前台发送、图片缩略预览与另存为`
> 禁止范围：`android/**`、`apple/Apps/DsmMac/**`；多附件、实时 Socket、前后台轮询、语音、加密会话、投票、提醒、定时消息、建群、删除/转发、通知、后台恢复与跨重启续传

## 1. 账本口径

- 本波只把已经记录的 Chat Server 单附件链补到 Windows 与 Apple 移动端：选择一个图片、视频或普通文件，前台发送，显示进度和结果；收到的图片可按需读缩略图，所有附件可由用户选择位置另存。
- Chat 的 `Post.create` v5 multipart 与 `Post.File` v2 是已记录的内部套件接口，不等同于 Synology 官方公开 API。只有运行时能力发现明确覆盖对应版本时才显示入口；没有能力或当前会话加密时保持关闭。
- 单附件发送复用统一 `MutationResult` 语义：提交前取消可以重新选择；实际 multipart 请求开始后，取消、断线、解析失败或回读不匹配都只进入“需要核对”，不能自动重传。
- 本波不以 macOS 页面是否完整作为移动端串行前置。macOS 仅提供业务语义和已记录请求形态参考；不得修改 `apple/Apps/DsmMac/**`。
- 真实 Chat Server、系统选择器、iPad/Windows 无障碍和弱网行为保留为 `PENDING_USER_VALIDATION`，不阻断源码与云端构建闭环。

## 2. 当前事实与依赖

| 层级 | Apple 当前事实 | Windows 当前事实 | 本波决策 |
| --- | --- | --- | --- |
| 领域模型 | `ChatAttachment`、`ChatMessageDraft.localAttachmentURLs`、`ChatMessageSendOutcome` 已存在；`sendMessageResult` 仅支持纯文字 | `ChatAttachment` 仅为元数据；`IChatRepository` 只有 `SendTextAsync` | 两端新增向后兼容的“单附件发送结果”入口，复用既有统一结果词汇，不建立第三套反馈模型 |
| 上传契约 | `DsmChatRepository` 已有 `Post.create` v5 multipart 上传，但附件路径直接抛错或返回消息，不能表达提交未知 | 已有 `chat/send-attachment` 合成请求 Fixture，但没有 multipart transport | Apple 收口为 typed outcome；Windows 以同义 typed outcome 实现最小 multipart transport，固定 `channel_id`、`type=file`、`message`、`is_thread=false` 与 `file` |
| 缩略图与保存 | 共享仓库已有 `Post.File.thumbnail/get` v2 二进制读取；移动 wrapper 当前故意拒绝 | 仅解析附件元数据，尚无二进制读写 | 只在 `Post.File` v2 能力可用时开放；缩略图按消息 post ID 读取，另存为由用户确认目标位置 |
| 移动/桌面界面 | SwiftUI composer 只有文字输入，已有附件仅显示“只读” | WinUI composer 只有文字输入，附件行明确不可打开 | 新增独立附件 state/model/partial，避免继续膨胀既有文字 composer 文件 |

## 3. 用户结果与非目标

| 用户结果 | iPhone / iPad 交互转换 | Windows 交互转换 | 安全与数据边界 |
| --- | --- | --- | --- |
| 选择一个附件 | Composer 左侧使用 44 pt 系统附件按钮；使用 Photos 或 Files 的单选系统选择器；选择后显示名称、大小和移除动作 | Composer 使用 WinUI 单文件选择器、48 px 操作区和单个附件卡 | 本地选择只驻会话内存；不持久化路径、正文或文件内容 |
| 前台发送与取消 | Composer 显示上传进度；提交前取消回到可编辑状态，提交后取消显示需要核对 | 同义状态、键盘可达取消和明确状态播报 | 同一个 client request / 已核对目标不得自动发第二次 multipart |
| 图片预览与所有附件另存 | 可见图片按需加载缩略图，点击使用系统查看器；另存由系统选择位置 | 可见图片缩略图；另存使用系统保存选择器 | 服务端文件名只作建议名，不能成为本机写入路径；失败或取消不覆盖已有目标 |
| 会话切换与离页 | 立即取消前台任务并阻断迟到回写 | 同义 generation/profile/repository 门 | 旧 profile、旧 repository、加密会话或回收站/只读语义不能获得发送入口 |

明确不做：多附件、附件批量重试、视频内嵌播放、语音、图片编辑、聊天实时 Socket、后台上传/下载、跨重启恢复、会话/成员管理、投票、提醒、定时消息、加密会话附件和任何未记录接口。

## 4. 契约与结果语义

### 4.1 Apple A0

- 在 `ChatRepository` 增量加入 `sendAttachmentMessageResult(_:progress:) -> ChatMessageSendOutcome`；默认实现返回 `unsupported`，旧文字 `sendMessageResult` 和 macOS 既有签名保持不变。
- 只接受一个本地 URL，结果操作标识固定为 `chatAttachmentSend`。
- `DsmChatRepository` 复用现有 multipart 路径，但成功必须经稳定 post / 消息回读确认；只凭附件名称、正文或时间窗口的模糊匹配不能静默标记为成功。
- 同一个 client request 已提交但未确认时，后续调用仅回读，不再发起 multipart。
- **当前实现证据**：`sendAttachmentMessageResult(_:progress:)` 已作为向后兼容入口落入 `DsmCore` 与 `DsmChatRepository`；聚焦 `DsmChatRepositoryTests` 已在本机执行 39 项相关 XCTest 与 2 项既有未验证适配器测试，0 失败。确认回读额外要求稳定消息 ID、当前用户、会话、正文、恰好一个附件、文件名及本地已知长度完全一致；旧 `sendMessage` 在上传响应只有稳定 ID 时也改为同一严格回读，不再用正文或时间窗口猜测成功。

### 4.2 Windows W0

- Domain 新增单附件 source/request/outcome 与独立 `AttachmentMessage`、`AttachmentThumbnail`、`AttachmentContent` capability；文字消息能力不被附件 capability 缺失影响。
- Windows 发送固定为 `SYNO.Chat.Post.create` v5 multipart；缩略图和另存读取固定为 `SYNO.Chat.Post.File` v2，按 post ID 读取，不能把展示 attachment ID 猜成远端参数。
- 上传进入真实发送边界后，一切未确认结果都进入本进程 review blocker；后续只通过消息列表精确回读核对，绝不重复上传。
- **当前实现状态**：单附件 multipart 发送、精确回读和提交未知防重传，以及缩略图和流式另存为均已落入 Domain/Infrastructure；WinUI 通过独立 composer、附件 partial 和系统选择器复用这些读写结果，不修改通用 File Station 上传或范围读取契约。GitHub Windows Build 已完成 .NET 测试与 WinUI 双架构构建；真实设备与 Chat Server 行为仍待验收。

## 5. 实施顺序与文件所有权

1. **A0 Apple shared contract**：仅 `DsmCore/Chat.swift`、`DsmNetwork/DsmChatRepository.swift` 与其测试，先固定单附件 outcome 和防重传语义。
2. **W0 Windows contract/transport**：仅 `LanStash.Domain/Chat/**`、`LanStash.Infrastructure/Features/Chat/**` 与 Chat 契约测试；不改 WinUI、资源或通用 File Station upload/range 合同。
3. **A1 Apple mobile presentation**：在 A0 验收后，单独所有权覆盖 `DsmMobile/Sources/Features/Chat/**`、专属测试、英中 strings 与工程生成；iPhone/iPad 共用 SwiftUI 状态机。
4. **W1 Windows presentation**：在 W0 验收后，单独所有权覆盖 `LanStash.App/Features/Chat/**`、`ChatPage` 附件 partial、专属测试、双语 resw；不把附件代码堆回现有文字 composer 文件。
5. **集成与文档**：主线程更新本账本、进度、平台矩阵和专项计划，运行本地轻量门后由 GitHub 执行 Apple、Windows、Repository 与必要的 Android 回归。

## 6. 必须自动化的门禁

- 运行时 capability 缺失、加密会话、空/多个附件、无效文件源或选择器取消时零发送请求。
- 正常单附件发送固定 multipart 字段、版本和认证位置；正文/本机路径/凭据不写入 URL 或诊断。
- 发送前取消零请求；发送后取消、断线、坏响应或消息回读不匹配进入 `submittedButUnverified` 或 `cancellationRequestedAfterSubmission`，同 request ID 第二次调用零重传。
- 精确回读至少校验当前 profile、会话、本人、候选消息、单附件名称、已知长度和正文；不匹配不得误报成功。
- 缩略图只按可见行按需读取，超过已定义边界或非图片时安全降级；另存选择器取消零下载，失败不覆盖用户已有文件。
- profile、repository、会话或页面代次变化后，进度、缩略图和结果均不能回写旧界面。
- iPhone/iPad 触控目标至少 44 pt，Windows 至少 48 px；动态文字、VoiceOver/Narrator、键盘、浅深色、高对比和窄宽布局分别有代码/资源门。

## 7. 当前验证与后续出口

- Apple A0 已通过 `swift test --package-path apple --filter DsmChatRepositoryTests`（41 项，0 失败）及差异格式检查；A1 已完成 iOS 通用构建，并在 iPhone 17 Pro iOS 26.5 模拟器通过 Chat 附件与 NAS 只读详情聚焦 13 项，0 失败。GitHub [Apple Build 31384177365](https://github.com/yuangy1995/dsm-native-client/actions/runs/31384177365) 又通过 685 项 XCTest（2 项跳过）、10 项 Swift Testing、工程生成、iPhone/iPad 通用应用构建、macOS 打包与产物上传。iPad 真机与真实 Chat Server 仍未验收。
- Windows W0/W1 已通过静态契约、fixture、XAML/resw XML、本地化和差异门；WinUI 已接入单文件选择、取消、精确确认、图片缩略预览与用户主动另存，且提交未知跨页面重建不重传。GitHub [Windows Build 31384177338](https://github.com/yuangy1995/dsm-native-client/actions/runs/31384177338) 通过 921/921 项 .NET xUnit，WinUI x64、ARM64 均构建成功；[Repository Check 31384179104](https://github.com/yuangy1995/dsm-native-client/actions/runs/31384179104) 也已通过。本机没有 .NET SDK，因此真实 Windows 交互仍待设备验收。
- 将以本次文档回填后的最终提交再运行同一组云端门禁；全绿后整理为一条简体中文功能提交合入 `main`，并删除本地和远端 `codex/chat03-attachments` 验证分支。

## 8. PENDING_USER_VALIDATION

- 真实 Chat Server：记录 DSM/Chat Server 脱敏版本、能力版本范围、成功/权限/取消/断线后的结果类别和调用次数；不得回传正文、文件名、post ID、路径、地址、账号、Cookie、SID、Token 或原始响应。
- iPhone/iPad：Photos/Files 单选、系统分享/另存、横竖屏、分屏、动态文字、VoiceOver、弱网和会话切换。
- Windows：文件/保存选择器、Narrator、键盘、浅深色、高对比、200% 缩放、x64/ARM64 与真实 NAS 取消边界。
