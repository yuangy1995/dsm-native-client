# Synology Photos 开发与迁移计划

> 更新：2026-09-10。本文合并旧照片计划与替换账本，作为当前照片范围、实现位置和剩余工作的唯一入口。[旧 File Station 方案](../archive/2026-h2/PHOTOS_FILE_STATION_PLAN_HISTORY.md)仅用于迁移追溯，不再作为新实现要求。

## 当前决策

- 照片模块直接使用 Synology Photos，不保留 File Station 扫描库作为降级；套件不可用时提供恢复操作，不伪造空图库。
- macOS 已接入新读取主流程和个人空间单项删除；iPhone、iPad、Android、Windows 尚未迁移，五端完整替换未完成。
- 用户明确授权个人空间删除不按 DSM／Photos 版本白名单拦截：按接口支持、实际权限和目标一致性开放；未测版本仍标为未验证。此授权不扩展到共享空间或其他危险写操作。
- 保留原生 UI、现有主题、双语资源、会话隔离和证书校验；不改变应用标识、依赖、权限或持久化结构。
- 旧照片专用源码在所有调用方迁移后删除；文件管理仍使用的通用实现必须保留。

## macOS 功能对齐账本

| 用户能力 | 当前实现与证据位置 | 状态与边界 |
| --- | --- | --- |
| 照片身份、空间 | `DsmCore/SynologyPhotos.swift`、`DsmNetwork/SynologyPhotosRepository.swift` | 账号＋空间＋项目 ID；个人空间启用，共享空间未开放；管理员不等于共享权限 |
| 时间线、分页、刷新 | `SynologyPhotosModel.swift`、`SynologyPhotosView.swift` | NAS 日期分组、自动分页、刷新替换与迟到结果隔离；右侧年月点击／拖动／方向键定位，不预载全部照片 |
| 搜索与筛选 | Repository 与 `PhotoFilterPanel` | 12 类标准条件：类型、日期、人物、位置、标签、评分、相机、镜头、焦距、曝光、光圈、ISO；不以当前已加载页面代替全库搜索 |
| 相册、分类、目录 | Repository 与照片视图 | 普通相册、最近添加、人物、主题、位置、标签、视频及根目录，依 NAS 实际分类显示 |
| 预览、属性、下载 | `SynologyPhotoPreview`、Repository | 大图、视频、实况独立视频单元、元数据和普通原件保存；Live Photo 组合 ZIP 导出未完成 |
| 共享读取 | Repository 的 `sharedEntries` | 与我共享、与他人共享、照片请求；非空共享和 App 行为待验证；创建／撤销／权限修改未实现 |
| 单项原件删除 | Repository 的 `prepareDeletion/deletePhoto/reviewDeletion` | 个人空间已开放；确认后重核目标和权限、只提交一次、未知只核对，成功空回读才更新列表 |
| UI 与入口 | `LoginViewModel`、`WorkspaceModel/View`、照片视图 | 正式路由不再实例化旧扫描库；统一背景、原生等宽筛选、五态和双语；年月轴禁用整块焦点框，保留局部月份提示和键盘／读屏 |

路径基准：领域与网络位于 `apple/Packages/DsmCore/Sources/`、`apple/Packages/DsmNetwork/Sources/`，macOS 文件位于 `apple/Apps/DsmMac/Sources/`。回归为网络包的 `SynologyPhotosRepositoryTests.swift` 和 App 的 `SynologyPhotosModelTests.swift`、`WorkspacePresentationTests.swift`。

## 接口事实与验证等级

- [照片读取接口](../api/discovery/endpoints/photos-library-read.md)：参数、响应、媒体凭据边界、排序与筛选修正。
- [单项原件删除](../api/discovery/endpoints/photos-item-deletion.md)：写前检查、重复提交保护、异步任务与缺失语义。
- [环境索引](../api/discovery/environments/INDEX.md)、[兼容矩阵](../compatibility/DSM_COMPATIBILITY_MATRIX.md)：精确版本与证据归属，不在计划重复维护。
- 已有真实证据：个人空间一张新增合成 PNG 单次删除完成，刷新后原件回读为空；不是所有媒体、账号或版本的完整验收。
- App 重启／断网／权限变化和恢复仍未验证；待核对状态仅在会话内，结果不明先核对，不重复删除。
- 视频选源已修正：普通视频和实况只选择实际存在的转换版；没有转换版时读取对应项目／视频单元原件。两个 MP4 的失败原因已真实对照，其他格式有合成选源回归；实际播放与编码兼容待用户验收。
- 构建与合成绘制不替代实际 App 会话、NAS 或 VoiceOver 验收。历史测试包见[发布验证记录](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#photos-测试包与受控删除2026-09)。

## 五端迁移顺序与非目标

| 平台 | 下一步 | 保留的边界 |
| --- | --- | --- |
| macOS | 按反馈修复读取／删除，再拆分上传、整理和分享写切片 | 不把相册移除当原件删除，不把 File Station 操作当 Photos 分享 |
| iPhone | 迁移共享模型／网络、触控入口和系统选择器／分享 | 仅移动专项计划批准的核心／受限能力，不复制桌面悬停、右键和常驻进程 |
| iPad | 与 iPhone 同一业务范围，验证双栏、宽屏和键盘 | 不以通用 iOS 编译代替 iPad 验收，不暗中增加桌面能力 |
| Android | 单独授权波次迁移 Kotlin Repository、Compose 及现有备份依赖 | 高负载构建交托管 Runner；本轮不改 Android 代码或后台语义 |
| Windows | 迁移 Repository 与 WinUI，保留文件管理通用能力 | Windows Runner 完成目标构建，不以 macOS 测试代替 |

iPhone/iPad 自动备份及释放设备空间仍是后续独立决策，不是本次替换的隐含范围；Android 遵循自身已批准计划。不修改 NAS 数据库、不自建识别模型、不自动更改套件／索引／共享权限，不引入完整照片编辑器。

每个切片先交付主流程与聚焦自动化，设备条件后置；新增写能力单独核实契约与授权。全部调用及测试迁移后，最后清理旧照片专用组件、资源和失效引用。

## 可重跑检查

```sh
swift test --package-path apple --jobs 4 --filter SynologyPhotos
swift test --package-path apple --jobs 4
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

合成 UI 使用 `tools/codex/run_macos_ui_checks.sh <独立临时目录>`，通过 `LANSTASH_UI_TEST_FILTER` 聚焦照片用例；覆盖浅深主题、双语、五态与焦点。测试包按既有 `apple/Apps/DsmMac/package.sh` 独立生成，不自动安装或启动，不含本地磁盘挂载扩展。

## PENDING_USER_VALIDATION

### 2026-09-10：时间轴跨年跳转后的向前分页

- 范围：仅 macOS Photos 页、分页模型及其回归测试；不修改共享 API 契约、其他平台、权限、应用标识或持久化结构。
- 原因：旧月份定位截断查询结束时间，同时只有尾部分页入口，无法向前读取较新照片。
- 用户实测发现首版累计数量定位会造成月份跳转为空，已撤销该算法。恢复原有按所选月份月底限定查询、从零读取的跳转逻辑，不改变向下分页；向上加载独立读取相邻较新月份对应的时间区间，区间内按页读完再整体补入，避免同月多页出现缺口。失败保留原时间边界与已有照片，重试复用双语按钮；空定位结果不隐藏向上入口。刷新、跳转、离开及删除操作隔离迟到结果。滚动区域保留现有悬浮滚动条样式。
- 已运行：`swift test --package-path apple --filter 'SynologyPhotosModelTests|MacAppearanceTests|SynologyPhotosRepositoryTests'`，编译通过，71 项测试通过；`python3 tools/localization/check_localization.py` 及 `git diff --check` 通过。分页测试覆盖跨年双向游标、搜索范围保留、失败重试、并发重复触发及刷新后迟到结果隔离。
- 复核：前后游标独立；不新增请求参数和写接口；新增错误入口复用语言资源。以上为源码、macOS Swift Package 编译及合成回归证据，不代表真实 NAS 或完整安装包验收。
- 待验收前置条件：包含此修复的 macOS 构建、已授权且跨多年有照片的 NAS。仅加载首批后跳到较早年份，连续向上翻过多页，再向下滚动；重复一次搜索后的跳转，并检查浅深色及系统“始终显示滚动条”设置。
- 预期：目标月份可定位，向上按较新时间段补入，较旧照片仍按原逻辑加载，不出现重复照片或整页位置跳动；滚动条无实色框，滑块仍可用。连续滚动锚点、同月大量照片的加载耗时及最终外观均为 `PENDING_USER_VALIDATION`。图库在浏览期间发生增删时应刷新后重试。
- 回归改为真正按照片时间和页内偏移返回结果，并故意提供与列表条数不一致的时间轴计数；直接断言目标月份照片、同月同秒多页完整性、向下查询不变、搜索条件及失败重试。首轮发现新增测试未考虑原有全库日期上界裁剪，已修正该预期；不改变原查询边界实现。
- 失败反馈：仅回传 App/macOS/DSM/Photos 版本、所选月份、滚动方向、是否启用搜索或筛选、脱敏错误提示；不得附真实照片、主机、账号或凭据。

| 前置条件 | 操作 | 预期及影响范围 |
| --- | --- | --- |
| 测试包与授权 NAS | 浏览、切换日期／搜索／筛选，刷新及重开 App | 与官方图库一致；涵盖长列表、跨 NAS 隔离、大图库分页 |
| 可丢弃照片 | 先取消删除，再确认一次，刷新和重启核对；未知先查官方页面 | 取消无写入，确认后原件消失；不保证回收站可恢复 |
| 合成／授权媒体 | JPEG、PNG、HEIC、RAW、GIF、视频、Live Photo 查看与保存 | 可用格式正确显示／播放，不支持的组合明确提示 |
| 键盘、VoiceOver、不同主题与显示设置 | 操作工具栏、年月轴、预览、筛选 | 无整块蓝框，当前月份可辨认，方向键与读屏可定位 |
| 后续共享／写切片 | 另行明确目标、权限和允许副作用 | 不把当前只读证据当新增写操作批准 |

反馈只需平台／App／DSM／Photos 版本、权限类别、步骤和脱敏错误；不提交凭据、主机、真实照片、路径或原始响应。
