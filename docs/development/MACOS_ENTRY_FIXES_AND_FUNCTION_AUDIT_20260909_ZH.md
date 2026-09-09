# macOS 三个入口修复与功能真实性检查

## 范围与结论

用户反馈下载完成任务仍显示继续/暂停、新建聊天点击无反应、空间分析失败，并要求检查演示数据与仅展示功能。本轮针对 macOS；不修改 Windows、Android 或移动端 App，不提交或推送。

开始时 `git status --short` 为空，基线为 `main` 的 `da6ee5a3e848`。所有判断以当前代码和本轮验证为准，不继承历史对话中的实机结论。

三处源码修复已完成；新建聊天所需能力的 JSON 声明已在管理员官方网页核实，真实创建和全盘分析仍待用户验收。没有发现主工作区注入预置任务、聊天记录或随机容量数据；但“本地生效”“只读列表”“未实现入口”和“缺失值默认显示”必须与完整 NAS 管理功能区分。

## 实际修改

| 问题 | 原因与修复 | 代码证据 |
| --- | --- | --- |
| 完成任务仍能继续/暂停 | 原菜单无条件创建两个动作，工具栏只检查是否选中；现在暂停任务仅可继续，活动任务仅可暂停，完成/未知任务不可执行二者；混合选择在提交前过滤，过期 ID 不提交 | `apple/Apps/DsmMac/Sources/ServiceManagementView.swift`、`ServiceManagementModel.swift` |
| 新建聊天被禁用 | NAS 提供 `Anonymous` v2、`Named`/`Member` v1，均声明 JSON，而原创建门要求 FORM；改为保留精确版本检查并使用已有统一编码器。群名、类型、频道 ID 正确编码，空密钥列表保持数组 | `apple/Packages/DsmNetwork/Sources/DsmChatRepository.swift` |
| 空间分析失败 | `Search.start` 的 `folder_path` 错误地发送单个字符串；按公开指南改为数组，去除未列入公开搜索参数表的 `search_content`。保留分页、搜索清理与原有分析范围；未知失败使用已有分析专用重试提示，认证/权限等明确错误仍保留 | `apple/Packages/DsmNetwork/Sources/DsmFileRepository.swift`、`apple/Apps/DsmMac/Sources/NasAdministrationModel.swift` |

新增/扩充自动化：`DsmChatRepositoryTests`、`DsmFileRepositoryTests`、`ServiceManagementModelTests`、`StorageAnalysisIntegrationTests`、`WorkspacePresentationTests`。新增 JSON 群聊请求示例并同步发现记录、请求说明、Chat 计划和兼容矩阵。

本轮复用现有中英文资源，不新增硬编码可见文案。不改变存储格式、应用标识、签名策略、依赖、最低系统版本或公开 Repository 接口。现有 UI 技能的可用状态和错误恢复要求用于复核，保留 SwiftUI/AppKit 原生实现，未引入网页 UI 依赖。

## 功能真实性检查

本节是源码接线审计，不表示已逐项在真实 NAS 点击验收。正式组合根 `apple/Apps/DsmMac/Sources/LoginViewModel.swift` 创建 `DsmFileRepository`、`DsmChatRepository`、`DsmNasAdministrationRepository`、`DsmServiceManagementRepository`；照片通过真实文件 Repository 构造 `FileStationPhotoRepository`。合成数据位于 Tests，不是上述正式注入路径。`UnverifiedDsmChatRepository` 是明确关闭功能的适配器，不返回虚构消息。

### 确认只在本机生效或由本机计算

| 功能 | 用户实际得到的结果 | 证据 |
| --- | --- | --- |
| 聊天会话置顶 | 只保存当前 Mac、当前 NAS 配置下的排序，不同步官方 Chat 星标 | `ChatWorkspaceModel.toggleConversationPin`、`persistPinnedConversations` |
| 聊天阅读后的未读数变化 | 当前 Mac 本地清除未读展示；没有向 NAS 写入官方已读状态 | `ChatWorkspaceModel.markConversationReadLocally`、`applyingLocalReadState` |
| 最近访问 | 本机记录最近打开的远程位置，不是 NAS 全局活动历史 | `WorkspaceModel.rememberRecentLocation`、`recentLocations` |
| 性能/容量趋势 | 根据本次工作区读取的真实采样绘制，内存中最多保留 120 个点；不是 NAS 长期历史报表 | `NasAdministrationModel.swift` 中 `performanceHistory`、`storageUsageHistory` |
| 空间分析 | 当前账号可见共享目录的文件占用汇总，不是读取“存储空间分析器”已有报告，也不是存储池全部物理占用 | `StorageAnalysisEngine.analyze` |
| 照片时间线 | 读取真实照片文件并在本机整理时间线；不是完整 Synology Photos 相册、人脸/地点/标签系统 | `WorkspaceModel` 的 `FileStationPhotoRepository` 注入及其 `scanTimeline` |

### 确认只展示真实数据，未提供完整操作

| 入口 | 当前范围与缺失操作 | 证据 |
| --- | --- | --- |
| 聊天投票消息 | 可创建投票、展示题目/选项/票数；选项使用 `Label` 绘制，没有点击投票、关闭或删除投票动作 | `ChatWorkspaceView.swift` 的投票消息内容；`ChatWorkspaceModel.createPoll` |
| 容器 → 项目 | 显示项目名称、状态与容器数量；没有项目创建、编辑、启动/停止或删除入口 | `ServiceManagementView.swift` 的 `projectList` |
| 虚拟机 → 主机、存储 | 资源列表，只读；不是主机/存储配置管理 | 同文件 `resourceList` 与 `.hosts/.storages` 分支 |
| 虚拟机 → 保护 | 保护计划、计划策略、保留策略列表；不能在此创建或修改策略 | 同文件 `protectionView` |
| NAS → 外接存储 | 设备及状态查看、筛选、刷新；不提供弹出/格式化 | `NasAdministrationView.swift` 的 `ExternalStorageView` |
| NAS → 内存压缩 | 显示状态与统计、刷新；不提供启停或大小设置 | 同文件 `ZRAMView` |
| NAS → 进程 | 进程/进程组查看、搜索、刷新；不提供结束进程 | 同文件 `ProcessActivityView` |
| NAS → 共享访问 | 显示当前账号有效权限；“可删除”等是权限标签，不是修改共享权限或删除按钮 | 同文件 `ShareAccessView` |

日志/活动记录等本来就是只读信息页，不应把缺少写操作误判为假数据。相反，文件上传/下载/删除、消息发送/附件、下载创建与控制、容器/虚拟机已提供的操作、NAS 设置保存等均有真实请求调用，不能作为“安全的演示按钮”随意点击。本轮未逐一执行这些真实写操作。

### 其他边界与待办

- **存在缺失数据被显示成 0 的风险**：`DownloadTaskRow.sizeSummary` 与速度标签对缺失计数字段使用 `?? 0`；仓库读取失败的速度摘要也可能回落到 0。因此“0 KB”不总能区分真实零值与未取得字段。用户截图中的具体 0 是否属于此路径未抓取任务响应核实，不能据此认定是假任务。本轮仅按授权修复动作状态，不另外扩大统计呈现改造。
- 空间分析的重复文件检查最多取 400 个候选，且个别校验失败会跳过；不能把未列出重复文件视为整个 NAS 没有重复文件。其他共享、回收站、系统/套件和快照占用不等于这份文件报告的范围。此次不扩张为全 NAS 存储审计。
- 语音录制、加密聊天、内置贴纸等未开放能力没有伪装成可用按钮；不因修复创建入口而解锁。
- “下载管理”的 BT 搜索、RSS 等共享层能力并未在当前 macOS `DownloadStationView` 暴露成完整入口；其他端或共享层有实现，不等于此界面已经可用。
- 本轮不把只读页面补成写操作，不顺手修复上述额外边界；建议下个独立切片优先处理投票参与，以及缺失统计值与真实 0 的区分。

## 五端影响与实施顺序

| 平台 | 本轮影响 | 后续验证/工作 |
| --- | --- | --- |
| macOS | 下载界面与模型、空间分析反馈；使用共享 Chat/文件编码修复 | 当前平台测试与 Release 包；用户验收三个入口 |
| iPhone | 共享 `DsmNetwork` 的会话创建/文件搜索编码增量修复，App 文件未改 | 单独移动端构建与回归；不以 macOS 结果替代 |
| iPad | 与 iPhone 共享修复，未改变专项功能范围 | 单独核对 iPad 交互与构建，不引入桌面能力 |
| Windows | 未改源码；`DsmRepository.FileSearch.cs` / `DsmRepository.Files.cs` 搜索仍传单字符串，Chat 创建计划仍有 FORM-only 门 | 独立契约适配切片，检查编码器最终输出并补测试；不能直接沿用旧说明 |
| Android | 未改源码；`DsmRepository.kt` 的 `search` / `searchAllFiles` 同样传单字符串 | 获授权后独立核对统一编码器与 Chat 创建各阶段；高负载测试按云端规则执行 |

本次是修复已存在 API 的客户端编码，并非新增 API 或公开接口。公开 File Station 参数依据官方指南；内部 Chat 的本轮证据仅为版本和能力元数据，见[脱敏环境记录](../api/discovery/environments/2026-09-09-admin-chat-observation.md)。

## 集成与只读对抗复核

- 对最终差异单独复核：仅两个已有创建入口的格式选择改变，固定版本、用户过滤、禁用加密、串行创建、候选回读、群成员核对、已有待确认结果机制保留；不把格式支持扩大为权限支持。
- FORM 请求原有测试保留；JSON 新增成功/重复调用与编码断言；原 FORM-only 的 JSON 拒绝断言根据实际观察纠正为能力可用，而非删除能力检查。精确版本不足与 Member 缺失仍断言不可用。
- 搜索仍按当前账号可见目录工作，不通过私有搜索写接口或忽略权限错误绕过；未返回完整结果时不生成一份声称成功的合成报告。
- 下载上下文菜单、工具栏和提交目标共用一套状态判断；删除流程未改。模型级测试确认批量暂停/继续不触及已完成任务，也不提交过期 ID。
- 搜索接口数组测试最初因 JSONEncoder 转义斜杠导致两个新增断言失败；修正测试为严格 JSON 数组解码比较，生产编码器未改变。随后回归通过。
- 所有资料与测试均为合成或严格脱敏；未访问本地 App 凭据、未安装/启动新包、未手动调用 NAS 写请求。

## 验证记录

- `swift test --package-path apple --jobs 4 --filter 'DsmChatRepositoryTests|DsmFileRepositoryTests|ServiceManagementModelTests|NasAdministrationModelTests|ChatWorkspaceModelTests|StorageAnalysisIntegrationTests'`：290 项通过，0 失败。
- `swift test --package-path apple --jobs 4`：当次发现 900 项，855 项执行通过，45 项按既有条件跳过（43 项 UI、1 项大目录基准、1 项真实 QuickConnect）；退出码 0。系统框架输出 contacts 服务连接诊断，但没有测试失败，也未取得通讯录数据。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test下载与虚拟机选中行|WorkspacePresentationTests.test消息页双语|WorkspacePresentationTests.test消息辅助列表|WorkspacePresentationTests.testNAS各二级|WorkspacePresentationTests.test下载辅助弹窗|WorkspacePresentationTests.test套件各子页面' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-entry-ui.hyMEwJ`：6 项通过；覆盖双语、双主题的多个页面/弹窗，无 NAS 写入。
- 追加 `test新建聊天按钮点击可打开表单且不会自动提交`，通过真实 SwiftUI 按钮点击确认 sheet 打开。`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test新建聊天按钮|WorkspacePresentationTests.test下载与虚拟机选中行' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-entry-ui.hyMEwJ`：2 项通过，其中 1 项是前轮复跑；UI 共 7 项不同测试通过。
- `python3 tools/localization/check_localization.py`：通过，双语资源、占位符、引用及硬编码扫描无新增问题。
- `python3 tools/request-contract/validate_contracts.py`：96 个请求 Fixture、1 个写操作结果示例通过。
- `python3 tools/contract-validation/validate_fixtures.py`：3 组 Fixture、20 项私有 API 文档引用通过。
- 最终 `swift test --package-path apple --jobs 4 --skip-build`：901 项，855 项执行通过，46 项按原有条件跳过（含新增 UI 用例；UI 已按前述独立方式运行 7 项），0 失败。
- `python3 tools/codex/check_documentation.py`、`git diff --check`：通过。
- 打包命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_SIGNING_IDENTITY=- LANSTASH_BUILD_NUMBER=20260909.2215 LANSTASH_BUILD_ROOT=/tmp/lanstash-entry-build.Vkz2jd LANSTASH_DIST_DIR=/Users/yuangy/Downloads/applist/dsm-native-client/apple/Apps/DsmMac/dist/entry-fixes-20260909.TkcWNE bash apple/Apps/DsmMac/package.sh`。
- Release/arm64 构建及打包通过，版本 `1.0.2 (20260909.2215)`；沿用现有隔离测试身份。包内无本地磁盘挂载扩展，保留 Hardened Runtime，在线更新关闭。对输出 App 和只读挂载的 DMG 内 App 分别执行既有临时包门禁，实际 Sparkle 加载均成功，不仅检查签名。
- `hdiutil verify` 校验通过；DMG 内构建号已核对。输出文件为 `apple/Apps/DsmMac/dist/entry-fixes-20260909.TkcWNE/LanStash-1.0.2-arm64.dmg`，SHA-256 为 `e7be4b8ba0a65ff64ead25d5c66a71a9329734c1e5bd3ca993f79c651aea0c3c`。
- 对只读挂载内容运行 `rsync -anic --delete`（dry-run，含符号链接）比较输出 App，未发现差异；已卸载镜像。一次性 UI 截图、构建目录和挂载空目录已清理，可通过上述命令重新生成；仅保留正式测试源码、脱敏记录、交付 App/DMG 和测试说明。

## PENDING_USER_VALIDATION

前置条件：用户自行打开本轮独立测试包，使用有相应权限的账号连接同一 NAS；本轮测试包按既有流程移除本地磁盘挂载扩展，不用它验收挂载功能。

1. 下载管理：右键已完成任务，不再出现继续/暂停；只选完成任务时工具栏两按钮不可用。选择暂停任务应只允许继续；选择正在下载或做种任务应允许暂停。先使用可恢复的测试下载核对 NAS 最终状态。
2. 消息：点击会话旁加号应出现新建聊天表单。使用专用测试联系人创建单聊和至少两个成员的私人群聊；确认只出现一个会话且成员正确，不向真实联系人自动发送内容。验证权限拒绝与刷新恢复。
3. 空间分析：点击开始分析，最终显示共享目录和文件占用报告；用已知大小的专用测试文件核对结果。大目录可能耗时，取消后应能重新开始；权限不足应提示失败而非成功空报告。

需回传：测试包构建号、DSM/相关套件版本、操作步骤、脱敏错误文字或遮盖账号/路径/主机/聊天内容后的截图。不要发送 Cookie、SID、SynoToken、密码、真实文件列表或原始抓包。

本轮工作区保持未提交。未运行 Windows/Android/移动端构建，未进行真实 NAS 创建、下载控制或全盘分析；这些限制不影响本轮源码与 macOS 测试包交付，但不能据此宣称实机已全部通过。
