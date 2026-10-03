# macOS Chat 五组功能补齐账本

## 授权、基线与变更边界

- 用户于 2026-10-03 明确要求补齐：旧消息搜索、消息编辑和回复、参与投票、音视频播放与录音发送、新消息通知与跨端已读同步。
- 在 `main` / `2fada4af` 的现有未提交修复上继续；保留 `MACOS_CHAT_FIX_20261003_ZH.md` 所述全部改动，不提交或推送。
- 必要变更：在现有 `ChatRepository` 和消息模型上追加兼容能力、默认关闭的旧提供者实现及可选字段；macOS 主 App 增加系统麦克风使用声明和录音所需权限。已在实现前向用户说明必要性、影响及回滚，并沿用本轮五项功能的明确授权。
- 只在点击录音时请求麦克风；开发过程中不替用户接受系统授权，不自动录音。音视频读取沿用既有附件接口，不将会话凭据交给播放器或消息中的任意 URL。
- 不变更依赖、最低系统版本、应用标识、凭据存储或既有持久化格式；新增接口为兼容增量，旧调用继续有效，无数据迁移。回滚移除新入口、增量能力和麦克风声明即可。
- Windows、Android 和 Apple 移动端只同步契约影响与兼容说明，不扩张 App 功能；共享 Apple 修改必须回归和构建。
- 用户追加要求：同步 API 文档；Chat 启用时持续保持实时连接，独立于当前页面，后台收到消息不自动已读。
- 界面只使用日常业务文案；内部协议、测试和结果复核不进入用户操作流程。

## 功能账本与依赖

| 顺序 | 用户可完成的结果 | 基线与依赖 | 当前证据 / 安全边界 |
|---|---|---|---|
| 1 | 搜索 NAS 上的旧消息并查看结果 | `ChatWorkspaceView/Model`；`Post.search` 的普通搜索形态 | 已实现；Post.search v5 真实只读验证，Post.list 改用锚点分页；合成回归通过 |
| 2 | 编辑本人消息，回复指定消息并查看讨论 | 既有消息身份、作者判断和发送结果；编辑/线程实际请求 | 已实现；指定合成消息编辑与线程回复有行为回读证据；尊重本人权限和管理员时间限制，未知不重放 |
| 3 | 单选/多选参与投票并显示自己的选择和票数 | `ChatPoll`；`Post.Vote.vote/get_choices` | 已实现；合成投票参与及选择回读已验证；单选/多选、关闭和过期、选项变化有回归 |
| 4 | 播放音视频，录制、试听、发送或丢弃语音 | `Post.File.get`、既有单附件发送、AVFoundation/AVKit | 已实现原生播放器、录音/试听/丢弃/发送；离线 AAC 解码与文件生命周期回归通过；真实麦克风与通知授权待用户 |
| 5 | 收到新消息通知，阅读后同步网页及其他设备 | 既有实时/轮询、UserNotifications、已读写接口 | 已实现工作区常驻实时连接、隐私通知与可见消息已读；Channel.view 的实际已读回读已验证，系统通知交互待用户 |

独立集成范围：本任务单一修改者负责 Chat UI/模型、共享 Core/Network、双语资源、工程生成及文档。每组同时补正式回归；完成后单独检查跨 NAS/会话、重复提交、取消、权限、通知隐私和已读边界。

## 发现与验收记录

网络观察记录见 `docs/api/discovery/environments/2026-10-03-chat-five-features-observation.md`。仅在用户指定的主账号与测试账号会话使用合成内容；不改原有真实消息，不导出原始 HAR、Cookie、令牌或真实资料。

### 实际改动与关键决策

- `ChatDetailsViews.swift` 提供服务器旧消息搜索、本人编辑、线程讨论和单/多选投票；编辑与投票草稿绑定原始请求身份，结果未知只读取，不重复写。校验会话、消息作者、管理员编辑开关和允许时长。
- `DsmChatRepository` 修正 Post.list 使用 `post_id/prev_count/next_count/thread_id`，不再把 NAS 忽略的 offset/limit 当真实分页；搜索使用 search_results/total。修正创建投票的 choices 对象数组与 options 对象编码，保留真实选项字符串 ID。
- 新增共享领域能力为兼容增量，旧 Repository 默认不支持；依用户追加授权，新编辑、回复、投票和已读依据实际 API 能力开放，不按精确 DSM/Chat 版本拦截。移动只读包装器不开放新写入口。
- `ChatNativeMedia` 通过既有附件鉴权接口下载到私有临时目录供 AVPlayer 使用，不把凭据传给媒体 URL。可播放音视频；录音最长五分钟，AAC，先试听再发送。仅按钮操作请求麦克风授权；录音、已发送暂存与播放器文件按生命周期清理。
- `ChatNotificationService` 通知只含会话标题和本次连接的随机导航标识，不带正文、NAS 地址或凭据。历史基线、本人消息和加密会话不通知；点击后定位对应已连接 NAS。测试注入通知回调，不弹系统权限提示。
- 实时连接归属已连接工作区：登录后启用 Chat 即启动，切换文件/照片或 NAS 页面不中断，模块关闭、断开与退出才停止；停用和迟到连接回调有回归。
- 跨端已读使用服务器结果更新，移除本地清零掩码；只在消息页、活动窗口且实际布局显示最新已确认消息时推进。后台收到消息和正在查看旧历史都不清零；线程已读接受回执没有等价回读，只记录 observed。
- 主 App/本地测试包同步麦克风隐私声明与 audio-input 权限。四个新源文件通过项目既定 `xcodegen generate --spec apple/Apps/DsmMac/project.yml` 纳入 Xcode target；未手改生成工程。
- 双语资源齐全；容器修复并入同一新测试包，详见 `MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md`。

### 已运行验证

| 实际命令 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter Chat` | 145 项通过、0 失败；包括实时连接生命周期、窗口/底部可见证据、跨端已读、编辑/线程/投票、通知与媒体临时文件 |
| `swift test --package-path apple --jobs 4` | 合并容器修复后最终 2,415 项 XCTest：2,246 通过、169 按既有 UI/环境门禁跳过、0 失败；另 12 项 Swift Testing 通过 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test消息' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-chat-five-ui` | 5 项通过；五种新增面板、英中/浅深色、辅助功能、无自动发送或录音。截图的原生合成存在局部缺失，不能代替真实系统窗口和 VoiceOver 验收 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test容器下载恢复与搜索错误' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-container-ui` | 1 项通过，覆盖 20 个状态/语言/主题组合；错误不冒充空结果，不自动写 |
| `python3 tools/localization/check_localization.py` | 最终 Apple 5,576、Android 2,188、Windows 3,402；双语、占位符、引用、硬编码扫描均通过 |
| `python3 tools/request-contract/validate_contracts.py` | 169 个请求 fixture、1 个写结果示例通过 |
| `python3 tools/contract-validation/validate_fixtures.py` | 29 组 fixture、48 项私有 API 引用通过 |
| `python3 tools/codex/generate_api_reference.py --check`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 通过；请求目录通过既定工具生成 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/chat-five-features-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | 最终共享源码的 iPhone/iPad 通用模拟器构建通过；不等于设备运行验收 |

依赖解析只在构建进程中用临时 Git URL 映射复用既有 Sparkle 2.9.6 精确缓存，未改仓库/全局配置或依赖。首次打包门禁发现四个新文件未纳入 Xcode target，已由既定生成流程修复；本地化检查同时发现主 App 覆盖资源与共享资源不同，已同步英中两份，最终检查通过。

### 独立集成与只读对抗复核

逐项复核 UI → 模型 → Adapter 的跨 NAS/会话、稳定身份、原草稿、取消、回调迟到、重复提交、权限和最终状态。读取失败不伪装空内容；未知写入不重放；附件只读既有凭据边界内内容；通知不泄露正文；背景同步不触发后台已读。聚焦回归、全量回归与共享移动构建通过。没有为测试降低断言或删除既有测试，系统/硬件条件以原门禁保留。

### PENDING_USER_VALIDATION

前置：本轮独立 macOS 测试包、已安装 Chat 的 NAS 和可丢弃测试会话；其他版本的真实兼容性尚待核验；用户主动授予系统麦克风及通知权限。

1. 搜索历史、编辑本人消息、回复并参加单/多选投票，网页端应看到同一消息、线程与选择；编辑限制/关闭投票应明确不可提交，断网恢复不重复创建。
2. 录制一段语音，试听、丢弃与重新录制，发送后在官方网页或另一设备播放；视频/音频播放、音量与系统实际编解码仍需真实设备。只回传文件格式、近似大小和脱敏错误，不回传私密内容。
3. Chat 启用后切到文件/照片页，用测试账号来消息：应有未读/系统通知；点通知跳回目标会话；后台和旧历史阅读时不自动清零。活动窗口看到最新消息后，网页/另一设备已读同步。
4. 验证睡眠/唤醒、弱网、切换 NAS、关闭模块与重新启用；不会串号、重复通知或在退出后持续连接。真实 VoiceOver、动态文字和降低动态效果需用户系统验收。

线程已读没有等价回读证据；系统通知点击和麦克风授权不以合成测试替代。其他 DSM/套件版本按实际能力开放，并保留权限、去重及回读保护；Windows/Android 未修改实现，移动 App 未扩张功能。

### 交付产物

- 版本：1.0.13（23），Release / arm64，本机临时签名，未安装或启动。
- App：`apple/Apps/DsmMac/dist/chat-and-container-20261003/LanStash Test.app`。
- DMG：`apple/Apps/DsmMac/dist/chat-and-container-20261003/LanStash-1.0.13-arm64.dmg`，26,502,223 字节。
- SHA-256：`c6384860a92db19339614390c45e3e22074040acc2d24eec45680283f333211c`；同目录 `SHA256SUMS` 可复核。
- 构建入口：`apple/Apps/DsmMac/package.sh`；环境 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0`，本轮专用 `LANSTASH_BUILD_ROOT=apple/Apps/DsmMac/build/chat-and-container-20261003` 和 `LANSTASH_DIST_DIR=apple/Apps/DsmMac/dist/chat-and-container-20261003`（运行时均传绝对路径）。临时 Git URL 映射复用精确 Sparkle 缓存，未改持久配置。
- 最终 Release 构建、严格递归签名校验、Hardened Runtime 与精确权限清单、Sparkle 实际加载（`library loaded`）、arm64 架构、DMG checksum 均通过。另检查包内中英覆盖资源，旧“检查下载状态”文案已替换，麦克风隐私说明已进入产物。
- 既定本机测试包标识与正式版隔离，保留此前 `chat-reliability-20261003` 交付包；临时签名包按既定流程移除本地磁盘挂载扩展。没有放开证书验证、正式权限或 NAS 访问控制。
- 打包曾因录音新增 audio-input 与旧测试包精确清单不一致而失败；现在清单只允许 audio-input 与既有库验证例外，不接受其他运行时例外，12 项签名回归及实际加载门禁通过。
- 临时日志、合成截图、音频源素材、静态脚本和本轮专用 Mac/iOS 构建中间目录已清理；保留正式自动化源码及 App/DMG/校验和。所有变更仍在 `main` 工作区，未暂存、提交或推送。


### 用户追加：开放已实现功能与版本限制

用户明确选择“开放所有功能和版本限制，保留必要安全保护”。本轮范围为正在交付的 macOS App；不自动操作 NAS 设置、不修改其他端 App。

| 范围 | 代码核查 | 处理 |
| --- | --- | --- |
| Chat 新编辑/回复/投票/已读 | DsmChatRepository 的 DSM/Chat 精确版本白名单 | 移除额外白名单与版本元数据读取，依据实际 API 能力开放；保留会话访问、作者身份、编辑策略、并发和写后回读 |
| 照片管理与删除 | LoginViewModel 已传 deletionEnabled=true；Photos 按 API 与实际空间/账号权限 | 已开放，不改用户权限或共享空间设置 |
| 容器网络创建 | LoginViewModel 已传 containerNetworkCreationEnabled=true | 已开放；保留输入校验、确认、占用、状态回读 |
| 文件、下载、NAS 设置、VMM | 现有入口按 API 能力和目标可操作状态开放，没有发现额外 DSM/build 白名单 | 保留实际接口版本要求，不用 NAS 未声明的版本发请求 |
| 系统权限与本地测试包 | 麦克风权限、Hardened Runtime、唯一库验证例外、File Provider 正式授权 | 保留；签名检查允许录音这一必要权限，其余额外运行时例外继续拒绝 |
| 用户模块选择、删除/写回确认 | 属于用户设置与危险操作保护 | 保留，不替用户启用模块或批准删除/写回 |

此授权改变功能开放策略，不提升未知 DSM/Chat 版本的验证等级；真实兼容性按实际结果记录。

本地签名回归：`python3 tools/release/test_macos_signing.py` 12 项通过，含额外运行时例外拒绝、正式 App/扩展不携带库验证例外、麦克风仅用于主 App、英中隐私说明和合成动态库实际加载。首次新回归的管道输入与 Python 3.14 plist 读取方式不符，已改为与真实脚本相同的普通文件输入；未放宽权限断言。
