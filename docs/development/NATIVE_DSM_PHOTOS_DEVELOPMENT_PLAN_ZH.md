<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-15 -->

# Synology Photos 开发与迁移计划

本文是五端照片范围、对齐账本、性能边界和剩余验收的唯一入口。平台长期计划只引用本页，不另行维护照片功能副本。[旧 File Station 方案](../archive/2026-h2/PHOTOS_FILE_STATION_PLAN_HISTORY.md)保留为历史，不再定义正式照片入口。

## 当前决策与交付范围

- macOS 是业务与安全语义基线；Android、iPhone、iPad、Windows 正式入口已切换为原生 Synology Photos。套件不可用时提示恢复操作，不退回 File Station 扫描，也不把协议失败伪装为空图库。
- 本轮包含用户明确授权的 Android 照片迁移；macOS App 和 Apple 共享 Package 生产源码不变，不改依赖、应用标识、最低系统、权限、后台任务名称或存储格式。
- 用户已明确授权个人空间单项原件删除按接口支持、实际权限和目标一致性开放，不按 DSM／Photos 版本白名单拦截。所有平台保留确认、防重复和最终回读；未测版本仍未验证。此授权不扩展到共享空间或其他写操作。
- “源码迁移完成”“目标构建／合成回归通过”“真机／NAS 验收”分别记录。PR 的 Checks 是精确提交的自动化结果；下方 `PENDING_USER_VALIDATION` 不是已通过证据。
- 旧 File Station 文件导入、备份及其通用组件和回归仍保留，但不再连接正式 Photos 浏览路由，也不充当 Photos 上传、相册管理或分享 API。临时集成工作流不进入交付树。

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
