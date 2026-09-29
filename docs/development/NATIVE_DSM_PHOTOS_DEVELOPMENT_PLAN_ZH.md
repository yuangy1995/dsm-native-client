<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-19 -->

# Synology Photos 开发与迁移计划

本文是五端照片范围、对齐账本、性能边界和剩余验收的唯一入口。平台长期计划只引用本页，不另行维护照片功能副本。[旧 File Station 方案](../archive/2026-h2/PHOTOS_FILE_STATION_PLAN_HISTORY.md)保留为历史，不再定义正式照片入口。

## 当前决策与交付范围

- 2026-09-19 用户报告 macOS 1.0.9 文件下载提示“文件操作没有完成”，照片保存/删除也失败，
  上传正常。本轮优先修复已确认源码缺口；真实失败日志、单文件/新文件名范围及删除
  具体提示仍待用户补充，不把源码假设宣称为已复现全部真实故障。

- macOS 是业务与安全语义基线；Android、iPhone、iPad、Windows 正式入口已切换为原生 Synology Photos。套件不可用时提示恢复操作，不退回 File Station 扫描，也不把协议失败伪装为空图库。
- 本轮包含用户明确授权的 Android 照片迁移；macOS App 和 Apple 共享 Package 生产源码不变，不改依赖、应用标识、最低系统、权限、后台任务名称或存储格式。
- 用户已明确授权个人空间单项原件删除按接口支持、实际权限和目标一致性开放，不按 DSM／Photos 版本白名单拦截。所有平台保留确认、防重复和最终回读；未测版本仍未验证。此授权不扩展到共享空间或其他写操作。
- “源码迁移完成”“目标构建／合成回归通过”“真机／NAS 验收”分别记录。PR 的 Checks 是精确提交的自动化结果；下方 `PENDING_USER_VALIDATION` 不是已通过证据。
- 旧 File Station 文件导入、备份及其通用组件和回归仍保留，但不再连接正式 Photos 浏览路由，也不充当 Photos 上传、相册管理或分享 API。临时集成工作流不进入交付树。

## 2026-09-19 macOS 1.0.9 下载与照片操作反馈

证据路径：DsmFileRepository.performDownload 在所选文件旁创建 part/segment，
URLSessionDsmTransport 又在同目录暂存；NSSavePanel 只保证所选文件的沙盒访问，
不能据此假定可写任意兄弟临时文件。普通文件提示来自 translate 的未知错误兜底，
不是已证实的 NAS API 拒绝。Photos 原件保存同样在目标旁暂存；Mac save 未显式持有
选择位置的安全作用域，且面板确认同名替换后仍调用无覆盖下载，必然不能完成替换。
删除 prepareDeletion 调用全量 details，导致 EXIF/地址/视频等非删除所需字段的
解码失败也阻断预检。以上为源码证据，尚未在用户 Mac 复现具体 NSError 或 NAS 回执。

当前修改范围为 Apple 共享下载落盘、Mac 照片保存、最小删除身份回读及正式测试，
不改上传、登录、证书、权限、应用身份、删除端点或删除开放范围。新
DownloadedFileExporter 统一使用系统 itemReplacementDirectory 与 NSFileCoordinator
保存已校验内容，失败不先删除目标；File Station 继续严格核对长度、Range 和版本。
下载缓存移至应用 temporaryDirectory，目标路径摘要隔离同名不同输出位置，断点
元数据结构不变；旧目标旁缓存不自动迁移，新尝试从零开始，旧片段只在用户移除任务
时按旧范围清理。该变化仅影响可丢弃缓存，不变更传输队列/用户数据格式；回滚本次
源码不会删除已保存文件，新临时缓存可由对应任务清理。临时区可能被系统清理，不能
承诺跨系统清理后的续传。

Photos Repository 仍默认无覆盖；Mac 面板确认后先下载到应用临时副本，持有目标
访问作用域直到系统协调保存完成，才显示成功。取消/网络失败不覆盖旧文件。
删除只用既有 Browse.Item.get v5 核对 ID、名称、大小、日期、目录、类型，忽略
无关附加详情；仍要求目录 view/manage、个人空间、确认、防重复和成功空回读。
没有执行任何真实删除，也没有用“管理员”绕过权限。

五端影响：macOS 新保存接线；iPhone/iPad 与 File Provider 共享下载基础层受到兼容
行为修正，协议签名和 UI 不变，但需 Apple 回归；Windows/Android 无本次代码修改。
只修改上述文件，保留工作区中 NAS/VMM/下载管理等既有未提交改动。

正式回归新增共享导出 4 项、删除最小预检 1 项、本地错误映射 1 项、Mac 保存 2 项，并更新断点路径与
定向清理断言；现有无覆盖/截断响应/Range 完整性断言保留。本机运行
`swift test --package-path apple --filter 'DownloadedFileExporterTests|DsmFileRepositoryTests|SynologyPhotosRepositoryTests'`
因 swift 不存在而未执行，不能标为编译/测试通过；Mac 模型回归及完整
`swift test --package-path apple` 亦为 PENDING_USER_VALIDATION。

PENDING_USER_VALIDATION：在 Mac 构建独立临时签名测试包，不覆盖旧包；确认单个文件、
目录 ZIP、批量、非空/空文件、同名替换、新目标、断网后续传及外接卷。照片分别验证
新位置保存、已确认覆盖、取消后旧文件保留；删除仅用用户另行选定的可丢弃个人空间
照片，核对确认前无写、单次提交、最终原件不存在，失败只核查不重复删除。
需回传版本、操作步骤、错误类型/脱敏提示；不要回传路径、账号、凭据、照片或原始
DSM 响应。删除的实际失败原因仍待具体提示，不宣称当前改动已证明修复用户全部问题。

同日独立复核补充：本地导出改为 async，并将系统复制/文件协调放入独立任务，避免
大视频保存占用 MainActor；取消传播到该任务，在复制之前、复制之后和替换前核查。
系统单次 copyItem 不能中途打断，但取消后不得进入最终替换；目标替换已经完成的
情况不谎称可以回滚。新增已取消导出保持源和目标的回归，所有调用方同步 await，
新辅助方法尚未发布，不改变既有 Repository 协议。

Photos 删除 catch-all 原先连明确权限/会话拒绝也伪装成 pendingReview。本次仅对
既有通用 DSM 错误 105/106/107/119 返回映射后的明确原因并清除该次待核查状态，
同一 operationID 缓存拒绝且不重发；新的用户确认仍必须重新预检。117、网络、HTTP、
畸形响应及取消继续保留未知，不扩大“明确未执行”的推断范围。新增一组回归覆盖
四个拒绝码、重复请求与新确认的区分。没有新增真实删除或改变权限要求。

上述两项正式回归同样未运行：Get-Command swift 确认当前主机无 Swift。本轮只能
执行本地化、请求/响应 fixture、文档及差异静态门；不得据此宣布 Mac 编译或沙盒通过。

## 2026-09-28 macOS 照片交互修复与网页对照（进行中）

本轮仅修改 macOS 照片视图、现有照片模型、相关测试及 Apple 双语资源；保留下载管理未提交改动。该模型也被 iPhone/iPad 引用，保留单项删除调用方式，评估共享行为回归；不修改其他端源码或公开契约。

| 用户目标 | 当前源码证据／网页观察 | 本轮处理 | 验证 |
| --- | --- | --- | --- |
| 批量选取和删除 | macOS 只有单张右键/预览删除；官方网页按日期组选择并显示选中数量和批量操作 | 增加勾选、范围选择、日期组选取及固定确认快照；逐项复用已有删除预检、提交、防重复与回读 | 待聚焦自动化 |
| 月份定位稳定 | 顶部分页占位 `.task` 自行触发，补入后强制滚动 | 只在用户向顶部滚动或明确点击时加载较新照片；保持已有可见照片锚点 | 待合成验证和实际滚动 |
| 删除后留在当前月份 | `applyDeletionResult` 成功后调用 `refresh()`，重置月份和整个列表 | 自动只读核对，原地移除确认删除项，修正后续分页偏移，保留月份和筛选 | 待聚焦自动化 |
| 网页完整功能对照 | 2026-09-28 已登录 Chrome 官方 Photos UI 只读观察：日期组选取、选中数量、共享链接、加入相册、下载、标签、评级、日期、生成预览、移动/复制、删除 | 先完成已有契约内闭环；尚无契约的写功能逐项记录，不能用界面入口冒充实现 | UI 观察，无真实写入 |

浏览器扩展连接不可用，使用 Chrome 原生无障碍控件查看。2026-09-28 用户明确允许扩展上传、相册、分享、元数据、移动和复制接口，并要求继续完整对齐；不再等待接口扩展授权。授权不包含在现有真实照片上试写。按原方案，尚未验证的新写入口保持关闭；先完成源码、合成验证和可用包，真实环境另列验收。

前三项修复已完成：勾选、Shift 范围、按日组选取、已加载项全选和批量确认；原地移除确认删除项，保留月份、查询和分页；桌面删除自动进行最多六轮只读核对（等待 0.5/1/2/3/5/8 秒），持续未知保留重试检查而不重放写请求。移动端保留单项调用及原核对时机，未开放移动批量入口。关闭模块取消后续批量提交与核对，保留已提交未知目标。

验证命令与结果：
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：62 项 XCTest（25 项模型、37 项 Repository）与 6 项本地化测试通过。本轮新增 8 项模型回归。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-ui-checks`：1 项正式合成 UI 回归通过，覆盖浅色/深色静置、批量选择、删除后月份与请求数量；没有连接 NAS，未声称真实滚轮手势或 VoiceOver 通过。
- `python3 tools/localization/check_localization.py`：Apple 4193 个资源通过；`git diff --check` 通过。
- Release 打包：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-selection-timeline-20260928" bash apple/Apps/DsmMac/package.sh`；临时包装仅为系统 xcodebuild 增加 `-clonedSourcePackagesDirPath "$PWD/apple/.build" -skipPackageUpdates`，复用与锁定版本一致的 Sparkle 2.9.6 缓存，未改脚本或依赖。退出码 0，签名、权限、实际加载、arm64 和 DMG 校验均通过。
- 产物 `apple/Apps/DsmMac/dist/photos-selection-timeline-20260928/LanStash-1.0.10-arm64.dmg` 已在对话交付，旧包保留，不自动安装/启动，不含本地磁盘挂载扩展。

独立集成复核：变更后重新核查确认快照、单次提交、权限预检、分页失效、向上补入与向下 offset 区分、取消和部分失败；现有 Repository 删除权限门禁不变，无真实写入验证。`PENDING_USER_VALIDATION`：用户选定可丢弃个人空间照片，检查确认取消/多选删除、2020.03 静置不漂移、真实向上滚动、删除后位置、断网恢复与键盘/VoiceOver；仅回传脱敏步骤和错误。新管理能力另见本轮静态发现记录。

## 业务语义对齐账本

| 用户目标 | macOS 证据 | Android、iPhone／iPad、Windows 等价实现与边界 |
| --- | --- | --- |
| 打开照片与账号隔离 | `DsmCore/SynologyPhotos.swift`、`DsmNetwork/SynologyPhotosRepository.swift` | 能力与个人空间访问检查；账号＋空间＋项目 ID；退出、切换与失效时取消请求并隔离迟到结果。管理员权限不能代替照片访问权限。 |
| 时间线与年月定位 | `SynologyPhotosModel.swift`、`SynologyPhotosView.swift` | 按 NAS 日期分组、服务端分页、刷新替换；可跳转月份并分别向较新／较旧范围续页，不预载全库。空月份仍能向前加载。 |
| 搜索与筛选 | Repository 与 `PhotoFilterPanel` | 全库服务端搜索；类型、日期、人物、位置、标签、评分、相机、镜头、焦距、曝光、光圈、ISO 共 12 类。已选日期与月份窗口取交集，不扩大筛选范围。 |
| 相册、分类与目录 | Repository 与照片视图 | 普通相册、最近添加、人物、主题、位置、标签、视频及根目录，依服务端返回展示；畸形响应不是合法空列表。 |
| 查看与保存原件 | `SynologyPhotoPreview`、媒体 Repository | 大图、缩放、属性、视频、Live Photo 独立视频单元；普通原件经用户选择保存。没有有效转换版时仅使用有契约支持的对应原件，不以整个视频下载掩盖 Range 失败。 |
| 查看共享入口 | Repository 的 `sharedEntries` | 与我共享、与他人共享、照片请求的只读入口；非空列表及不同权限仍待 NAS 验收。共享入口不等于开放共享照片空间。 |
| 删除一个原件 | `prepareDeletion/deletePhoto/reviewDeletion` | 确认后重核项目、文件夹查看及管理权限；同一目标最多一次写入；超时／未知只核对，不自动重发；精确 ID 成功空回读才移除列表。 |
| 平台交互 | macOS 原生工具栏、筛选与预览 | Compose／SwiftUI／WinUI 原生界面；浅深色、双语资源、加载／空／筛选空／错误／正常五态；恢复操作不暴露凭据或协议内部字段。 |

Apple 路径基准为 `apple/Packages/*/Sources/` 和 `apple/Apps/DsmMac/Sources/`。macOS 模型与网络回归为 `SynologyPhotosModelTests.swift`、`SynologyPhotosRepositoryTests.swift`；本轮不改变这些参考实现。

## 各端实施位置与交互转换

| 平台 | 正式实现位置 | 交互转换、生命周期与自动化 |
| --- | --- | --- |
| iPhone | `apple/Apps/DsmMobile/Sources/Features/Photos/MobileSynologyPhotos*.swift`、`project.yml` | 复用 Apple Photos Repository 及现有 macOS Photos 业务模型；触控工具栏、年月选择、原生缩放／播放、系统分享和 Files 导出替代悬停／右键；后台及账号切换取消导出。`MobileSynologyPhotosTests.swift` 覆盖移动集成。 |
| iPad | 与 iPhone 共用上述实现 | 同一业务范围，网格随宽度变化，保留 Shell 分栏与键盘刷新；不增加桌面常驻任务。Apple Build 分别选择 iPhone、iPad 模拟器执行测试，不以一个通用构建替代两者。 |
| Android | `data/SynologyPhotos*.kt`、`domain/SynologyPhotoModels.kt`、`photos/Synology*.kt`、`network/SynologyPhotosMediaTransport.kt`、`ui/photos/` | 正式 `PhotosScreen` 使用 Compose 网格、筛选、预览及系统保存；`SynologyPhotosSession` 统一拥有模型并在父作用域结束时关闭。原有 `PhotoBackupCoordinator` 与 File Station 备份保留独立入口，不改变 WorkManager 语义。 |
| Windows | `Domain/Photos/`、`Infrastructure/Features/Photos/Synology/`、`App/Features/Photos/Synology/`、`App/Views/Photos/` | Shell 路由到 `SynologyPhotosPage`，保持 WinUI 窗口、键鼠与文件保存选择器；原件、预览及删除各自有取消／结果核对状态，不向新照片页注入 File Station 写适配器。 |

Android 通过 `SynologyPhotosProvider` 委托接入既有 `DsmRepository`，避免继续扩大兼容门面；Windows 通过既有 `DsmApiClient` partial 及连接证书上下文接入，不新增第二套认证客户端。iPhone 与 iPad 不复制共享网络层或新建另一套照片协议。

## 性能与安全复核

2026-09-16 Windows 用户反馈复核：照片初始时间范围补齐 macOS 的跨时区边界及非负下限，
认证表单对齐现有 Apple 请求构造器，登录失效与空图库提示分离。真实 Repository 合成回归
已复现并修复纪元日期导致的“月份成功、照片失败”；截图现场根因及真实 NAS 仍待验证。
本次仅 Windows 实现变更，五端接口字段、安全门与持久化格式不变；跨模块检查、真实命令
和环境限制见[Windows 请求一致性复核](WINDOWS_API_PARITY_AUDIT_ZH.md)。

| 项目 | 约束与回归证据 |
| --- | --- |
| 大图库 | 服务端分页、独立前后游标、页面去重和请求代次；筛选日期与月份窗口交集有合成测试。滚动／月份定位不预取所有照片。 |
| 缩略图 | 移动与 Windows 缓存按会话／项目身份隔离；并发上限 4、内存预算 32 MiB。Windows 另限 120 项并按解码成本记账、下采样到网格尺寸；同键请求合并，最后订阅者离开才取消。 |
| 原件导出 | 使用流式读取及临时文件；拒绝伪装成图片的 JSON、HTML、ZIP 响应；检查长度、取消及访问代次后才发布，不覆盖已有目标。失败清理未完成文件。 |
| 视频 | 使用严格 Range 数据源；检查状态、范围及表示一致性，分段读取而非完整驻留；会话失效停止旧媒体读取。 |
| 状态更新 | 刷新、月份跳转、筛选、离开及切换账号使旧响应失效；权限撤销后的下载不能成为成功文件。 |
| 回归 | Android Repository／MediaTransport／Session／Presentation 与 Windows `SynologyPhotos*Tests` 覆盖上述边界；Apple 复用原模型／网络回归并增加移动会话、入口和导出测试。没有删除失败测试、放宽结构债务阈值或跳过安全断言。 |

以上是实现上限、代码审查与合成回归，不是设备帧率、启动耗时或内存峰值实测。不同媒体解码器、超大图库和长时间滚动仍需下方设备验收，不能据此宣称性能提升百分比。

## 接口事实与验证归属

- [照片读取接口](../api/discovery/endpoints/photos-library-read.md)维护固定版本、参数、响应、媒体凭据边界与失败语义；[单项删除](../api/discovery/endpoints/photos-item-deletion.md)维护写前检查和结果回读。没有为迁移猜测新 API。
- 精确 DSM／Photos 版本和真实证据只维护在[环境索引](../api/discovery/environments/INDEX.md)、[兼容矩阵](../compatibility/DSM_COMPATIBILITY_MATRIX.md)，不复制成五端已验证结论。
- 既有 macOS 单张新增合成 PNG 删除／刷新回读为空的证据仍保留；不能替代 Android、iPhone、iPad、Windows 的 App 会话、重启、断网、权限变化或媒体格式验收。
- 个人单项删除结果不明时先在官方 Photos 核对；待核对状态仅在当前会话内，不能把重启当作安全重试。没有承诺回收站可恢复。

## 可重跑自动化

| 平台／门禁 | 命令或工作流 |
| --- | --- |
| Apple 共享与 Mac 回归 | `swift test --package-path apple`；Apple Build 同时生成工程、编译移动端、分别运行 iPhone／iPad 合成回归，再打包及校验 macOS 测试产物。模拟器测试宿主只使用 ad-hoc 签名，不触及正式分发签名。 |
| Android | `./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:minifyReleaseWithR8 :app:assembleDebugAndroidTest :app:lintDebug --no-parallel --stacktrace`，由 Android Build 托管 Runner 执行。仪器 APK 构建不等于仪器测试执行。 |
| Windows | `dotnet test tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release`；Windows Build 分别构建 `LanStash.App.csproj --runtime win-x64` 与 `--runtime win-arm64`。 |
| 质量与契约 | Repository Check、Documentation & Quality Preflight；本地运行下列入口。 |

```sh
python3 -m unittest discover -s tools/codex/tests -p 'test_*.py'
python3 tools/codex/check_documentation.py --strict-release
python3 tools/codex/generate_android_quality_baseline.py --check
python3 tools/codex/check_android_structure_debt.py
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
git diff --check
```

精确提交的通过／失败以 PR Checks 及其测试产物为准。发布签名、安装、升级和 NAS 手工验收不包含在这些构建结论中。

## 明确非目标

本轮不新增 macOS 自身尚未实现的 Photos 上传、相册创建／编辑／移除、分享创建／撤销／权限修改、共享照片空间写入或 Live Photo 组合 ZIP 导出。现有分享条目的读取与系统原件分享不是这些写能力。iPhone／iPad 自动备份、释放设备空间、后台常驻和完整编辑器仍是后续独立产品决策，不记为本轮待验收。Android 原有备份的上传目的地仍遵循其 File Station 契约。

## PENDING_USER_VALIDATION

| 前置条件 | 操作 | 预期与影响范围 |
| --- | --- | --- |
| 各端测试构建、授权且跨多年有照片的 NAS | 仅加载首批后跳到旧月份，连续向前、向后翻页；重复搜索／筛选、空月份、刷新和弱网重试 | 日期和项目与官方图库一致，同月多页不缺项，不重复追加，不整库预载；大图库耗时和滚动锚点待测。 |
| 同端两个测试账号／NAS、可调整访问权限 | 加载／预览／导出期间切换账号、断网、退后台、退出或撤销访问 | 旧照片、播放器及下载结果不进入新会话；恢复提示可用，取消的文件不对外发布。 |
| 合成或已授权的 JPEG、PNG、HEIC、RAW、GIF、视频与 Live Photo | 查看缩略图、大图、属性、播放／拖动及保存原件 | 支持格式正常，服务端不可用或系统不支持时明确提示；长视频不全量读入内存。 |
| 可丢弃的个人空间照片、允许删除的专用账号 | 先取消确认，再确认一次；刷新核对；结果不明先看官方 Photos，不再次删除 | 取消无写入，权限不足拒绝，未知状态仅核对；不承诺恢复。共享空间和其他未授权写继续关闭。 |
| iPhone、iPad、Android 和 Windows 真实设备 | 浅深色、双语、大字体、屏幕阅读器、横竖屏／窄宽窗、键盘；检查系统保存／分享 | 点击目标、焦点、返回、分栏和选择器正确。iPad 单独验收，不能由 iPhone 通过替代。 |
| 大图库与合成大图／长视频 | 连续滚动、反复打开预览和切换会话，记录资源趋势 | 缓存可回收、无持续增长或卡顿；只记录实测，不预设帧率或峰值结论。 |

仅回传平台／App／DSM／Photos 版本、权限类别、操作步骤、时间点和脱敏错误；不附凭据、主机、账号、真实照片、路径或原始响应。需要新增写能力时另行确认范围与契约，不借本轮设备反馈扩大授权。

## 2026-09-29 Photos macOS 增量对齐影响

用户已授权增量扩展上传、相册/分享管理、标签/评级/日期、移动/复制共享契约。完整账本见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`，接口证据见 `docs/api/discovery/endpoints/photos-management.md`。新增写方法默认关闭，仅有官方静态结构和合成测试，不升级为真实 NAS 兼容结论。macOS 批量删除、月份稳定与自动核对沿用既有删除门禁；新增批量保存使用原有只读接口。iPhone/iPad 共用 Apple 协议的默认不支持实现，保持既有单项删除界面；Android/Windows 仅记录影响，未改代码或开放新入口。未完成的网页能力与验证条件在账本明确列出，不计作完整对齐。

2026-09-29 后续明确授权：用户要求取消新增照片功能的默认禁用。Apple 实际 Photos Repository 已移除人工能力白名单，macOS 按真实接口支持开放上述功能；保留权限、确认与结果校验。其他端 UI/存储仍未修改；接口开放不能表述为跨版本验证通过。专用合成图片/相册的网页验证与最新包记录见 `docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md` 末尾。


### 2026-09-29 Photos 后续波次

macOS 继续对齐：多文件上传队列、当前相册/文件夹上传、封面设置与缩略图展示已接入；测试和最终打包证据见 MACOS_PHOTOS_PARITY_20260929_ZH.md。相册缩略图是共享领域/服务的向后兼容增量；未扩展其他端界面、持久化或权限。


### 2026-09-29 Photos 标签与日期增量

macOS 新建标签与相对时间调整已接入；新增部分失败只继续剩余目标的操作。完整测试、实机限制和交付包见 MACOS_PHOTOS_PARITY_20260929_ZH.md；条件相册、分享高级管理、照片请求、人物整理等总目标继续保持。


### 2026-09-29 Photos 导入与并行浏览

macOS 已增加拖放、本地目录媒体批量导入与上传期间继续浏览；目录内容汇总到当前目标，不保留层级。共享 Model 将图库读请求与上传队列分开管理，无新 NAS 契约或持久化。101 项 XCTest、6 项本地化测试及 3 项合成 UI 测试通过，真实拖放/沙盒权限/NAS 待验。详见 MACOS_PHOTOS_PARITY_20260929_ZH.md；其余平台 UI 未变，未运行 iOS 构建。


### 2026-09-29 Photos 目录层级上传

macOS 确认页默认保留目录层级，可选择原汇总方式；同名目录复用，缺少的目录逐级创建并回读，再上传/加入相册。共享契约新增 folders/createFolder 与可选结果 folder，其他端 UI/存储不变；真实 NAS 验收待完成。109 项 XCTest、6 项本地化测试和 3 项合成 UI 测试通过。静态发现还补齐条件相册、高级分享、人物、照片请求与预览重建的线索，不计为实现。完整记录见 MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 条件相册增量

macOS 已接入个人条件相册创建/编辑、规则建议与匹配数量预览；支持类型/日期/文件夹/评级、关键词、人物/主题/标签匹配及相机等规则。保留已有未知字段，冲突不覆盖，未知创建不重放。共享空间来源仍在共享空间切片；高级分享等剩余目标保持。

回滚可移除条件相册入口、命令和新增默认字段/方法，既有普通相册、时间轴和上传流程保留；不迁移已有持久化。完整证据见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。


### 2026-09-29 分享现状与访问方式增量

macOS 接入只读分享快照、当前设置初始化、仅受邀者模式、已有保护标记与复制链接；不修改时不提交，保存校验原快照并保留密码/有效期。公开访问只有查看/下载，upload 是具名成员角色。新增领域 albumSharing 与 shareAlbum 可选快照，旧调用默认兼容；不改持久化、权限或工具链。iOS/iPadOS 共享领域受影响但无新 UI、未运行移动构建；Android/Windows 本轮只同步契约影响，不改实现。密码/有效期编辑与成员增删改仍未完成，NAS 写入为 PENDING_USER_VALIDATION，无人工验证白名单。回滚移除新方法/快照/入口即可，无数据迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 和 photos-management.md。


### 2026-09-29 Photos 分享成员增量

macOS 已接入用户/群组候选、成员添加/移除与角色调整；type+id 识别身份，按原快照计算差量，保存后核对完整角色名单。普通相册成员可上传，条件相册不提供上传角色。未知列表不当空名单，原未知角色不静默降级，原密码/有效期保留，关闭状态不意外启用。新增共享领域成员类型、sharingRecipients 默认方法和 shareAlbum.members 可选参数；无存储/权限/工具链变更。iOS/iPadOS 共享领域增量但无新 UI、未运行移动构建；Android/Windows 仅同步影响。真实权限写入 PENDING_USER_VALIDATION，不设验证白名单。回滚移除成员增量，不影响基本分享。高级分享剩余密码与有效期编辑，详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-29 Photos 人物命名与合并增量

macOS 人物卡片接入命名/清空名称和合并，表单显示人物封面、名称与照片数量；独立按真实能力开放。新增共享领域 peopleNames/peopleMerge、renamePerson/mergePeople、managementPeople、结果 person/removedPersonIDs 和分类缩略图默认方法，无存储格式变更。合并前后核对照片集合、目录权限和目标快照，结果自动确认，同操作不重发；更新当前列表而不跳到最新照片。分类封面使用当前分类列表的授权缩略图，避免把人物编号用于相册查询。iOS/iPadOS 共享领域受影响但无新增 UI、未运行移动构建；Android/Windows 仅更新影响计划。真实 NAS 人物写入 PENDING_USER_VALIDATION，无人工禁用/验证白名单；人脸分离、封面和识别纠正仍未完成。回滚移除人物入口/命令/结果增量，既有照片流程保留；无依赖、权限或持久化迁移。详情见 MACOS_PHOTOS_PARITY_20260929_ZH.md 与 photos-advanced-management.md。
