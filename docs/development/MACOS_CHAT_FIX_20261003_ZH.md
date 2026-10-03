# macOS Chat 正确性修复账本

## 范围与基线

- 用户于 2026-10-03 授权修复此前审查发现的问题；真实发送测试仅限已指定的主账号与测试账号之间的会话，不删除原有消息。
- 起点：`main` / `2fada4af`，工作区干净。修改范围为 macOS Chat、共享 Apple Chat Adapter、相关正式测试和英中资源。
- 沿用 `ChatRepository` 及既有消息/会话创建结果接口；不新增 NAS API、公开类型、持久化格式、依赖、权限或应用标识。
- 独立测试包不覆盖旧包，不自动安装或启动；正式发布和 Git 提交/推送不在本轮范围。
- 非目标：新增搜索、线程、投票参与、录音、频道管理、通知或完整加密能力；不修改 Windows、Android 或移动端 App 源码。

## 修复顺序与证据

| 顺序 | 用户结果 / 缺陷 | 源码基线 | 安全约束与验收 |
|---|---|---|---|
| 1 | 发送结果不明与失败分开；附件断线不重复上传；结果核对只认稳定消息身份 | `ChatWorkspaceModel.send/retryMessage`、`DsmChatRepository.sendMessage*` | 保留原草稿和请求 ID；未知不重放；补丢回执与跨会话回调回归 |
| 2 | 加密会话不提供未经实现的收发；本人身份不以昵称判断 | `canSendText/canDelete`、`isOwnedByCurrentUser` | 明确他人身份优先；未知归属不开放本人操作 |
| 3 | 较早消息删除有完整定位与回读；异常列表不能伪装空列表 | `deleteMessage/listMessages` | 完整分页或明确拒绝；删除确认、权限与重复保护保持 |
| 4 | 投票及转发不误报结果、不在未知时重新创建 | `createPoll/forwardMessage` | 固定原操作、内容和目标；验证不足保留待核对 |
| 5 | 刷新处理删除、未读以实际读到的内容为界；切换会话隔离消息和附件 | `refreshCurrentConversation/applyingLocalReadState`、`ChatConversationView` | 迟到结果不串入新会话；保留历史与独立草稿 |
| 6 | 建群重试继续原操作；错误态、预览和无障碍提示准确 | `NewChatSheet`、消息行与预览 | 双语、浅深色、合成 UI；真实 VoiceOver 待用户验收 |

## 验证状态

源码、自动化、共享 Apple 构建与独立 macOS 包已完成。未安装或启动新包；修复后的真实 NAS 行为不以自动化或构建替代。

### 实际改动与关键决策

- macOS 文字和附件均接入既有 `ChatMessageSendOutcome`；内部结果不明时仅续读原请求，不按正文/文件名/180 秒时间窗认领另一条消息，不直接丢弃有可能已经提交的消息。
- 认证写回执提供稳定 ID 时，精确回读同一会话和内容；本人标记缺失不会单独造成误报，但明确他人身份、加密内容、正文或附件不符均拒绝成功。昵称不再作为本人身份依据。
- 附件旧入口也走相同结果流程；切换会话后失败回调更新原会话分桶。附件草稿按会话保留，选择器与预览任务绑定所属视图，迟到提交不使用新会话。
- 删除查遍分页定位旧消息并复查删除结果；历史、提醒、定时和置顶列表不再把结构错误当成空列表。破损分页和跨会话记录拒绝继续，内部历史扫描不额外缓存全部消息正文。
- 投票回读实际投票、选项和设置，保留真实选项 ID；提醒回读消息及时间；定时消息保留稳定任务 ID；表单重新打开与重试沿用原草稿。转发先检查来源/接收人，成功回执后检查目标新增记录，丢回执不重放；批量重试复用各项请求 ID。
- 自动刷新替换已覆盖的最新范围，保留更早历史和本地发送；未读只按可见详情实际成功读取的时间更新，失败、空内容、加密和未知活动时间不清零。
- 一对一置顶消息提供只读入口，不扩张原群聊置顶写范围。原图预览使用既有下载接口，已知大小不超过 64 MiB；超限、大小未知或预览失败时提示另存为。原件和临时文件及时清理。
- 普通消息辅助功能包含正文；发送操作的恢复入口可单独访问。错误与加密状态有独立页面，不伪装空会话。遵守用户追加文案规则：内部结果分类不出现在界面，不把用户当作测试人员。

### 已运行验证

| 命令 | 结果 |
|---|---|
| `swift test --package-path apple --jobs 4 --filter 'Chat'` | 最终 120 项通过、0 失败；包括刷新操作实际重新读取消息且保持原请求身份 |
| `swift test --package-path apple --jobs 4` | 最终源码 2,382 项 XCTest，2,215 通过、167 按原门禁跳过、0 失败；另 12 项 Swift Testing 通过 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test消息' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-chat-fix-ui` | 4 项通过，覆盖中英、浅深色、消息恢复、错误/加密状态、原有表单，以及正文和恢复入口的辅助功能属性 |
| `python3 tools/localization/check_localization.py` | 通过；Apple 5,509 项资源，双语、参数、引用与硬编码扫描通过 |
| `python3 tools/codex/check_documentation.py`、`git diff --check` | 通过 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/chat-fix-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | iPhone/iPad 通用模拟器构建通过；不代表真机行为验收 |
| 既有 `apple/Apps/DsmMac/package.sh`，`LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0`，独立 build/dist 目录 | Release arm64 构建、临时签名、Hardened Runtime 权限检查、Sparkle 实际加载、架构及 DMG 完整性检查均通过 |

全量测试的跳过项为项目原有显式 UI/环境门禁；Chat 的四项 UI 用例已另行执行，没有把跳过计作通过。旧测试中以昵称覆盖明确他人身份的预期已纠正，并新增权威身份正反例；投票、附件与定时用例补入真实对象回读，未删除原字段、进度或去重断言。

### 独立测试包

- 版本：1.0.13（23），Release / arm64，本机临时签名。
- App：`apple/Apps/DsmMac/dist/chat-reliability-20261003/LanStash Test.app`。
- 安装镜像：`apple/Apps/DsmMac/dist/chat-reliability-20261003/LanStash-1.0.13-arm64.dmg`。
- 镜像 SHA-256：`e9f657146495fa2bfe8e6b5de2cfb22161516b01ad5ea28293b45c1b3258f908`。
- 沿用项目本机测试包标识和权限，不覆盖旧包，不自动启动。按既定流程移除临时签名不支持的本地磁盘挂载扩展；正式 App/扩展权限和源码未改变。
- 临时日志、合成截图及本轮独立构建中间目录在保存此记录后清理；正式回归源码和交付包保留。工作区变更未提交或推送。

### 独立集成与只读对抗复核

- 单独复查 UI → 模型 → Adapter 的入口、原请求保留、重复提交、迟到结果和成功提示；通过无稳定身份、明确他人身份、旧同文消息、坏列表、历史分页、跨会话及传输中断的反例验证。
- Cookie/令牌、证书处理、附件临时文件权限、危险操作确认和公共 `ChatRepository` 签名均保留；没有引入新的公开类型、请求方法、依赖或存储格式。
- 新代码使用共享 Apple Adapter，因此 iPhone/iPad 的既有文字、附件、身份、列表解析和本人消息删除会受到修正影响；移动 App 源码没有扩张范围，构建已通过。Windows/Android 源码未改，不借用 Apple 结果宣称其对应缺陷已修复。
- Debug Xcode 构建已完成，但现有打包脚本只扫描主启动文件，未扫描 `LanStash.debug.dylib`，因而拒绝该次包。保持打包规则不变，改用项目默认 Release 配置重新打包；不以此失败的 Debug 包交付。
- Release 首次依赖解析遇到 GitHub 连接超时。构建进程临时通过 Git URL 映射复用 `apple/.build/repositories/Sparkle-09d89c53`；其 `2.9.6` 标签的 commit 为 `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`，与 `apple/Package.resolved` 完全一致。没有修改全局或仓库 Git 配置、依赖版本、网络设置、打包脚本或校验门禁。
- 状态仅在进程内保存，重启后不承诺恢复；没有扩大到真实断网、睡眠、其他 DSM/Chat 版本或加密协议验证。

### PENDING_USER_VALIDATION

前置：独立 macOS 测试包、兼容 Chat Server 和可丢弃的专用测试会话。需要核对断网/取消后未知结果、真实附件和投票响应、历史删除权限、跨客户端删除、睡眠重连以及 VoiceOver。只回传 DSM/Chat 版本、连接类别、脱敏步骤和错误类别，不回传凭据、地址、消息正文或原始响应。

共享 Apple Adapter 的兼容修正会影响 iPhone/iPad 的既有 Chat 调用；须补共享包与可用的移动端构建/聚焦回归，不能以 macOS 通过替代移动设备验收。Windows/Android 只记录审查线索，不变更实现或提升验证等级。

本账本保留第一轮修复与旧测试包的历史记录。用户随后追加的五组功能、工作区常驻实时连接和容器修复统一交付于 [MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md](MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md)，后者为本轮最新产物和验证入口。
