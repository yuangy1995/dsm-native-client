# macOS 下载管理与 Download Station 对齐账本

## 基线与范围

- 基线：2026-09-27 开始时工作区干净；用户截图布局与当前卡片列表源码一致，目标暂按 DSM 官方 Download Station，等待用户确认。
- 网页依据：Synology 官方 `DownloadStation/download_manage?version=7`，以及 `docs/api/DSM_WEB_API_REFERENCE_ZH.md` 第 6 节；没有在真实 NAS 上做读写探测。
- macOS 证据：`apple/Apps/DsmMac/Sources/ServiceManagementView.swift`、`ServiceManagementModel.swift`。
- 共享契约证据：`apple/Packages/DsmCore/Sources/ServiceManagement.swift`、`apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift`。
- 单一修改范围：macOS 下载页面、下载模型方法与测试、下载相关 Apple 双语资源、本账本。容器、虚拟机、移动端、Android、Windows 实现不在本轮范围。

## 对齐清单

| 用户结果 | 当前缺口 | 实现路径 | 安全边界 / 验证 |
| --- | --- | --- | --- |
| 快速浏览和比较任务 | 大卡片，无列排序/搜索 | 原生 Table、分类侧栏、列排序、名称搜索 | 仅本地展示，已通过聚焦测试及原生合成布局检查 |
| 正确理解任务进度 | 缺失传输值被显示为 0 | 未知值显示未提供；完成状态展示 100%，传输字节不伪造 | 测试完成、暂停、缺字段等状态 |
| 查看任务详情 | 没有详情入口 | 下方详情区展示现有契约的状态、目录、大小、累计传输、分享率 | 本地只读，不显示原始响应错误 |
| 查看当前活动 | 页面不会定时更新，统计缺失仍显示零 | 页面在前台时定时读取，失败保留旧列表并提示，缺失统计明确显示不可用 | 离开页面取消；不自动重试写操作 |
| 安全管理多项任务 | 确认期间选择可能改变，筛选后隐藏选择 | 绑定确认对象，搜索/分类后清理隐藏选择；复用现有操作 | 保留确认、防重复与结果复查 |
| 搜索并创建 BT 任务 | 共享层已支持，macOS 无入口 | 接入现有目录、搜索和创建契约 | 仅用户提交后搜索，告知发送范围，结果只在内存 |
| 文件明细、Tracker、连接用户、RSS | Apple 共享接口尚未覆盖 | 需要兼容接口扩展，已询问用户授权 | 未授权前不新增接口或假入口 |
| 网页全部高级设置/任务编辑 | 现有模型仅含基础设置 | 单独核对公开契约与私有接口证据 | 不猜测接口，不声称完整复刻 |

## 验证记录

- `swift test --package-path apple --filter 'ServiceManagementModelTests|DsmLocalizationTests|DsmServiceManagementRepositoryTests'`：179 项 XCTest 与 6 项 Swift Testing 通过，无失败。
- 最后一次聚焦回归：`swift test --package-path apple --filter 'ServiceManagementModelTests|DsmLocalizationTests'`：32 项模型测试与 6 项本地化测试通过。本轮新增 11 项回归，涵盖缺失传输值、完成进度、分类/搜索、剩余时间、确认对象变化、刷新失败、模块关闭、旧读取覆盖删除结果以及搜索参数转发、陈旧来源/类别拒绝和能力关闭。
- `python3 tools/localization/check_localization.py`：通过，Apple 4176 个资源，双语、参数、引用和硬编码扫描均通过。
- `git diff --check`：通过。
- 原生合成布局检查：隔离 XCTest 宿主承载现有 SwiftUI 下载页面，使用合成数据检查 1100×720 浅色/深色布局；未启动实际 App、未连接 NAS。最初宿主缺少 `MacAppearanceStore`，补齐测试环境后渲染通过；临时探针和图片已删除。此检查不能代替实际窗口键盘、VoiceOver 与真实 NAS 验收。
- Debug 的 Xcode 构建完成，但既有 `package.sh` 在 `ChatWorkspaceView` 产物标记检查失败；未修改脚本、未跳过门禁，改用推荐的 Release 配置打包；为补齐已授权的 BT 高级查询界面，主动取消过一次构建，然后重新对最终源码打包。最终 Release 打包通过（退出码 0）。
- 最终命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/downloads-parity-20260927-1106" bash apple/Apps/DsmMac/package.sh`。
- 产物：`apple/Apps/DsmMac/dist/downloads-parity-20260927-1106/LanStash-1.0.10-arm64.dmg`，版本 1.0.10 (20)，仅 Apple 芯片，本机临时签名；主 App、Hardened Runtime 权限、Sparkle 实际加载、架构和 DMG 校验全部通过。未自动安装或启动。
- 保留项目既有 `LanStash Test.app` 测试身份配置，没有修改正式应用标识；临时包按现有流程移除 File Provider。正式签名、公证、Intel 构建及真实 NAS 验证未运行。
- 工作区：`main` 上 5 个现有文件修改和本账本新文件；未暂存、提交、推送或创建 PR。所有改动均属于本轮；临时探针、截图和日志清理，交付测试包保留于独立目录。

## 独立集成与只读对抗复核

- 实现后重新检查最终差异：仅下载相关页面、模型、测试、Apple 资源与本账本发生变化；未改变共享协议、网络适配器、权限、工程文件或正式应用配置。
- 新增定时读取每次串行执行；离开页面取消，后台暂停；创建、设置和删除确认期间不开始新轮询。
- 自动刷新只读取，失败保留旧列表；较早请求不能覆盖操作后新状态，已使用受控延迟和删除场景验证。
- 搜索/分类变化清理不可见选择；删除确认绑定任务身份，提交前复核选择与当前任务；不重放写请求，保留原有删除结果校验。
- 搜索仅用户提交后发出；默认使用 NAS 启用的来源，可切换全部来源或明确选定来源，并按类别、标题、排序字段和方向查询；提交前检查来源/类别属于当前目录，目录与搜索结果仅驻留页面内存，取消沿用共享仓库清理行为；选择结果后进入已有创建确认界面。
- 状态、目录等详情只取现有结构化字段；不展示未经处理的服务端错误或未知协议状态，不将缺失数据解释为零。
- 当前没有接入文件明细、Tracker、连接用户、RSS 或完整高级设置；因此本轮**不能标记为网页端完整复刻**。继续开发需先获得共享公开接口扩展授权，并核对用户目标网页版本。
- 无可用独立子代理工具，本轮复核由同一执行者在实现后单独进行，不宣称独立人员审计。

## PENDING_USER_VALIDATION

- 前置：安装支持 Download Station 的 NAS，使用有套件权限的测试账号；本机临时签名包不含 Finder 本地磁盘挂载扩展。
- 操作：核对英文/中文、浅色/深色、缩放窗口、键盘多选与 VoiceOver；创建一个可删除的合成下载，检查网页和客户端的状态、完成进度、速度及默认目录。
- 操作：暂停/继续合成任务，断网后恢复，确认保留列表与刷新错误恢复；搜索/筛选后删除只影响确认过的可见任务。
- 预期：状态可随刷新变化，未知数据不伪造为零，批量操作不包含隐藏/过期选择；真实 NAS 未运行前不宣称验证通过。
- 失败信息：仅回传脱敏操作步骤、状态差异、套件版本；不提供链接、真实路径、账号、凭据或原始响应。

## 2026-09-27 跟进：详情区按选择显示并支持关闭

- 用户反馈：未选中任务时仍显示大块空详情区，展开后无法正常收起。
- 本次仅修改 `ServiceManagementView.swift`、关闭按钮的 Apple 中英资源及本记录，保留前一轮所有未提交改动。
- 详情默认隐藏，只有存在当前可见的选中任务且用户展开时显示；选入新任务自动展开，清空选择自动收起。
- 增加详情栏右上角关闭按钮；顶部详情开关在无选中任务时禁用。关闭保留任务选择，顶部开关或双击任务可以再次展开。
- 关闭时移除整个 `VSplitView`，列表恢复占满高度；只刷新数据或移除失效选择不会重开手动关闭的详情。
- 已执行 `python3 tools/localization/check_localization.py`（Apple 4177 个资源）与 `git diff --check`，均通过。此次属于局部界面修复，未新增实现镜像测试或改变模型/接口测试。
- `swift build --package-path apple --skip-update --product LanStash`：使用已固定的本地依赖缓存，编译与链接通过（8.98 秒）。
- 首次 Release 打包在依赖解析阶段失败：连接 GitHub 获取 Sparkle 超时；不是源码编译错误。确认网络恢复后按原命令重试，未改变依赖版本、项目配置或签名流程。
- 构建命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/downloads-details-20260927" bash apple/Apps/DsmMac/package.sh`。重试通过（退出码 0），主 App 签名、权限、Sparkle 实际加载、arm64 架构及 DMG 完整性校验全部通过。
- `PENDING_USER_VALIDATION`：打开下载管理且不选任务，应无下方详情占位；选择任务后显示详情；点右上角“×”及顶部开关均可收起且不留空白；等待自动刷新仍保持关闭；换选任务或双击任务可重新展开；清空选择或筛选掉选中项时自动收起。此验收只涉及界面读取，不需要在 NAS 上执行写操作；如失败，仅回传脱敏操作步骤和布局现象。

- 跟进产物：`apple/Apps/DsmMac/dist/downloads-details-20260927/LanStash-1.0.10-arm64.dmg`。独立目录保留上一版测试包；本机临时签名，不含 Finder 本地磁盘挂载扩展，未自动安装或启动；实际点击/键盘交互仍按上述步骤待用户验证。临时构建日志与本次失败产生的结果包已清理，未提交或推送。

## 2026-09-28 跟进：BT 搜索布局与镜像分段按钮

- 用户反馈：BT 搜索弹窗顶部留白过大，错误提示与初始空状态同时出现；镜像下载弹窗不需要可见的“镜像任务”标签，切换按钮需要前移。
- 本次修改范围：`ServiceManagementView.swift` 的 BT 搜索弹窗，以及 `PullImageSheet` 中分段控件的标签/对齐；Apple 中英资源增加两条 macOS 文案；保留此前所有工作区改动。
- BT 搜索改为顶部标题/输入/筛选、中央填满剩余空间的内容区、底部固定操作栏；保持项目原生材质和按钮样式。隐私说明精简后置于底栏，保留发送范围与临时保留说明。
- 分别呈现加载选项、搜索中、目录读取失败、搜索失败、没有来源、初始空内容、筛选/搜索无结果和正常表格；错误态只显示一个带重试入口的说明，选项读取失败不再误称搜索失败。读取选项期间编辑关键词不重复取消或重发目录读取。
- 镜像分段控件使用 `labelsHidden()` 隐藏可见标签，保留无障碍语义，按控件自然宽度靠左排列；镜像搜索、下载和任务管理逻辑未修改。
- `swift build --package-path apple --skip-update --product LanStash`：编译与链接通过（9.80 秒）。随后仅将错误图标改为项目已有的 `exclamationmark.triangle`；最终源码由下述 Release 构建验证。
- `python3 tools/localization/check_localization.py`：通过，Apple 4179 个资源；`git diff --check`：通过。
- 最终构建命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/downloads-search-layout-20260928" bash apple/Apps/DsmMac/package.sh`。Release 构建与打包通过（退出码 0）；主 App 签名、Hardened Runtime 权限、Sparkle 实际加载（`library loaded`）、arm64 架构及 DMG 完整性校验均通过。
- 实现后单独复核：只有上述两处界面与状态呈现改变，没有扩展接口、改变搜索来源授权或启用新的写操作；本轮不新增仅复述布局实现的测试。检查覆盖上述所有状态分支，但不将源码检查视为真实 NAS 或实际窗口渲染验证。
- `PENDING_USER_VALIDATION`：分别在浅色/深色与中英文打开 BT 搜索；标题应靠顶，底部按钮不随内容上下漂移；读取失败应只显示错误与重试，恢复后显示初始状态；搜索无结果、正常结果、筛选展开、关闭与再次打开均应正常。打开下载映像弹窗，不显示“镜像任务”标签，分段按钮与搜索框左边缘对齐，并可切换两个页面。实际 NAS 搜索失败的具体原因未在本轮定位；如失败，仅回传脱敏步骤与状态差异。

- 首次打包在从 GitHub 获取 Sparkle 时连接超时，未进入源码编译。重试通过临时命令包装为原有 `xcodebuild` 增加 `-clonedSourcePackagesDirPath "$PWD/apple/.build" -skipPackageUpdates`，复用本地缓存；缓存 Sparkle 2.9.6 的提交 `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a` 与 `Package.resolved` 一致。没有修改打包脚本、依赖版本或签名校验流程；临时包装随构建结束删除。
- 跟进产物：`apple/Apps/DsmMac/dist/downloads-search-layout-20260928/LanStash-1.0.10-arm64.dmg`，版本 1.0.10 (20)，本机临时签名，仅 Apple 芯片；按既有流程不包含 Finder 本地磁盘挂载扩展。新包位于独立目录，旧包保留，未自动安装或启动。
- 本次最终资源文案已包含在 Release 产物中；临时构建日志和失败结果包已清理。未暂存、提交或推送，模型和测试文件沿用此前未提交改动，本次未修改。
