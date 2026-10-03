# macOS 1.0.14 七项使用反馈修复

## 范围与基线

用户提供七张截图，要求修复语音播放、通知入口、置顶读取、本人消息未读残留、面包屑折叠、下载速度与剩余时间空值，以及 NAS 总览头部布局。基线为 `main` / `6141987e`，开始时工作区干净。截图只作本地定位，不复制其中账号、地址、路径或消息到源码和测试；本轮不自动提交、推送或发布新版本，不主动修改真实消息、文件和 NAS 设置；只读观察中的官方网页可能自行更新已读。

| 切片 | 现有证据 | 用户结果与边界 |
| --- | --- | --- |
| 语音 | ChatNativeMedia / ChatWorkspaceView | 点击后在消息内加载并开始播放；支持暂停/继续，离开会话停止和清理；沿用附件鉴权，不将会话交给外部播放器 |
| 通知 | ChatNotificationService / ChatWorkspaceView | 已授权时隐藏开启按钮；回到应用时更新状态，不自动请求系统权限 |
| 置顶 | DsmChatRepository.listPinnedMessages / PinnedMessagesSheet | 按当前会话读取，空列表与错误分开；保留原有置顶权限，不扩张一对一写入口 |
| 未读 | 可见位置、synchronizeVisibleReadState / Channel.view | 读到最新消息后同步服务器已读，后台/旧历史不提前已读，本人消息不产生错误通知 |
| 面包屑 | WorkspaceView.fileBreadcrumbs | 宽度足够时完整显示，不足才按需折叠；保留键盘、整块点击和完整路径入口 |
| 速度 | Download 管理列表 | 没有速度或剩余时间值显示 `--`；不伪造吞吐量，不把做种误判为停止传输 |
| 总览头部 | NasAdministrationView.PerformanceDashboard | 身份信息与操作紧凑排列，窄窗口自适应；危险电源确认保持原样 |

修改集中在现有 macOS 视图/模型及必要共享 Chat 解析，新增资源同步英中和主 App 覆盖资源。无新依赖、权限、应用身份或持久化迁移。共享层若需修正请求或响应，须同步契约与五端影响；Android/Windows 本轮只记录影响，不修改实现。

## 发现、验证与待验

### 已落实的修改

- `ChatVoicePlayback` 在应用内使用已鉴权下载的本机临时音频，首次点击自动播放，暂停/继续复用同一文件，播完可重播；切换消息、关闭会话/讨论页停止并清理。主会话与讨论页共享播放控件，不请求麦克风权限。
- `ChatNotificationService` 只读系统通知状态；已允许时隐藏按钮，重新激活窗口时刷新；只有用户点击按钮才申请授权。
- `Post.search` 改用数字 `in` 数组，保留分页和逐项会话校验。旧 channel_id 在官方页面返回了其他会话，修正后全部属于请求会话；见[只读观察](../api/discovery/environments/2026-10-03-chat-pinned-read-observation.md)。错误标题改为“无法载入置顶消息”。
- 最新消息可见位置改为直接跟踪消息行本身，避免检测消息后的空白和丢失的父层偏好更新；采用系统底部滚动锚点，修正首次打开窗口过早滚动。仍由 `Channel.view` 与回读确认清除未读；后台、读旧消息、读取/写入失败时不本地伪造已读。
- 面包屑以实际可用宽度选择显示数量，宽窗口完整显示，窄窗口只折叠放不下的前缀；保留完整父目录菜单、当前项中间截断、键盘与32点点击区域。
- 下载与上传速度，以及用户随后补充的剩余时间，缺失时显示 `--`；真实零速度仍显示零，字节等其他未知信息不随之改变。
- NAS 总览身份与版本独立排列，刷新/暂停/更新/电源集中在相邻控件中，窄窗口分组换行；电源危险操作确认与权限不变。

### 已运行验证

| 命令 / 检查 | 实际结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4` | 2,425 项 XCTest，2,253 项执行通过，172 项按既有环境/UI门禁跳过，0失败；另12项 Swift Testing 通过。语音静音合成播放、暂停、继续、自然结束、重播、取消及临时文件清理通过 |
| `LANSTASH_UI_TEST_ISOLATED=1 LANSTASH_UI_ARTIFACTS=/tmp/lanstash-seven-ui swift test --package-path apple --skip-build --filter 'WorkspacePresentationTests.test反馈\|WorkspacePresentationTests.test文件面包屑从长目录返回时显示目标目录首项'` | 4项真实视图回归全部通过；中英文、浅深主题、宽窄路径与头部、通知授权入口、最新语音已读、上翻历史及新消息不抢滚动、文件父目录/根目录导航 |
| `python3 tools/localization/check_localization.py` | Apple 5,581 / Android 2,188 / Windows 3,402，双语、参数、引用与硬编码检查通过 |
| `python3 tools/request-contract/validate_contracts.py` | 170份请求样例、1份写结果示例通过；新增置顶数字会话数组 fixture |
| `python3 tools/contract-validation/validate_fixtures.py` | 29组响应样例、48项私有API引用通过 |
| `python3 tools/codex/generate_api_reference.py`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 请求参数目录按既定流程生成；文档和差异检查通过 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/chat-five-features-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | 共享请求最终源码的 iPhone/iPad 通用模拟器 Debug 构建通过；不等于移动 UI 或实机验收 |

macOS Release / ARM64 构建与独立测试包已通过。实际命令：

```bash
LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_SIGNING_IDENTITY=- LANSTASH_TARGET_ARCH=arm64 \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/seven-feedback-20261003" \
LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/local-test" \
bash apple/Apps/DsmMac/package.sh
```

产物为 `apple/Apps/DsmMac/dist/seven-feedback-20261003/LanStash-1.0.14-arm64.dmg`，版本 `1.0.14 (24)`，包含本轮未提交修复，不是新的正式发布。主 App 临时签名、保留 Hardened Runtime 的专用测试权限、Sparkle 真实加载、ARM64 架构和 DMG 校验均通过；按既有流程移除 File Provider 挂载扩展。没有安装或启动 App，测试包使用现有独立配置与独立通知授权。

DMG 大小为 26,674,400 字节，SHA-256 为 `957834ef7834027fcc14327eeaeb225de669c251dab730f07a10a0d0452e184b`，输出目录内 `SHA256SUMS` 同步保存。

语音由静音合成文件测试，没有采集麦克风；界面使用合成资料，不连接真实 NAS。首次界面检查暴露并修复末条消息偏好更新失效、初始滚动时机和父目录菜单辅助功能识别问题，保留原回归断言及历史阅读不提前已读的断言。

### 集成与只读对抗复核

另行逐项核对 UI → 模型 → 共享请求：置顶仍按返回消息归属拒绝越界，不忽略错误、吞掉其他会话条目来冒充正确过滤；已读必须是活动窗口实际可见的最新已发送消息，并保持服务器回读；语音保留既有附件认证、大小限制和下载取消路径，不生成携带凭据的外部播放地址。切换/退出后迟到下载不能再次播放，讨论页沿用同一控件，不新增另一套下载。通知只读查询不触发授权；电源确认与权限不变。

没有新增依赖、应用权限、正式标识、持久化格式或响应 Schema。Windows/Android 没有修改源码或运行目标构建；iOS/iPadOS 只接受共享修正，不扩张移动功能范围。工作保留在现有 main，未提交、推送或发布正式版。

### PENDING_USER_VALIDATION

| 前置条件与操作 | 预期结果 | 影响与脱敏回传 |
| --- | --- | --- |
| 安装独立测试包，连接有语音附件的会话；点击播放、暂停、继续、切换另一段并离开会话 | 自动加载并播放，暂停保留位置，离开后停止，无外部播放器窗口 | macOS/Chat版本、音频格式与操作顺序；不发送真实音频或附件地址 |
| 系统设置已允许通知，打开消息页；切到系统设置改变授权后返回 | 已允许时无开启按钮，未允许时显示；不会自动请求权限 | 只回传授权类别和按钮是否变化 |
| 打开一对一及群聊的置顶列表，包含有置顶与空列表两种会话 | 仅显示当前会话，空列表和读取失败分别提示 | 只回传会话类别、数量、脱敏错误；不提供消息正文 |
| 发送测试语音后停留在最新消息；再滚到旧消息或离开窗口接收测试消息 | 最新消息可见时同步清除未读；后台和旧位置保留未读 | 操作顺序、未读计数和另一官方客户端的结果；不提供账号、消息或凭据 |
| 调整窗口宽度并切换语言、主题；检查下载完成任务与NAS总览头部 | 路径按需折叠、空速度/剩余时间为 --、操作紧凑且可读可点击 | 窗口宽度、语言/主题、脱敏局部截图；不含文件名、主机或账号 |

系统通知授权、实际音频设备、VoiceOver朗读和真实 NAS 的原生端到端结果不由合成检查替代。

