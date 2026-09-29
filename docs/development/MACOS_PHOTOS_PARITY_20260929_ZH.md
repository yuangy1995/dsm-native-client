# macOS Photos 网页对齐：2026-09-29 交付与待验证账本

## 标签与相对日期波次（进行中）

本波次继续使用现有 Photos 文件和双语资源，保留前次上传/封面以及 Download Station 改动。已获共享契约扩展和实际能力开放授权，不增加人工默认禁用。

| 流程 | 证据与实施方式 | 风险/验证 |
| --- | --- | --- |
| 新建标签并应用到选择照片 | 既有官方静态记录：GeneralTag.create v1(name) 返回 tag 对象；按返回 id 核对 GeneralTag.list，再沿用 Item.add_tag | 创建/应用分阶段；未知不重放，应用明确失败保留新标签 |
| 整体调整拍摄时间 | 按每张原始照片快照计算同一秒数偏移，逐项复用已记录 Item.set v2(time)；暂不猜测 shift_time 候选参数类型 | 保留间隔，逐项回读；部分完成只继续原目标中尚未完成项 |

2026-09-29 本次浏览器工具明确报告 Mac 锁屏，已请用户解锁。没有绕过锁屏或直接提取浏览器会话；在恢复页面观察前，仅使用仓库已记录结构，不提升私有接口证据等级。以上无依赖实现与合成测试继续推进，不将整项任务标为阻塞。

## 继续复刻波次（进行中）

本节为当前状态入口；下文此前交付的“默认关闭”描述为历史方案，已被用户后续明确授权取消。

| 本波次用户流程 | 既有源码与依赖 | 原生交互与写边界 | 当前状态 |
| --- | --- | --- | --- |
| 多文件上传队列 | Model.submitMutation、Upload.Item 单文件上传 | 系统多选、逐项进度、停止后续任务、失败单项重试；未知结果仅回读 | 源码、聚焦测试与合成 UI 已通过；真实 NAS 待验 |
| 上传到当前相册或文件夹 | 既有 upload(folderID)、addToAlbum | 上传成功后按返回照片编号加入目标相册；保留原上传结果，加入失败不重新上传 | 源码、聚焦测试与合成 UI 已通过；真实 NAS 待验 |
| 相册封面 | 已有 setAlbumCover 与 Album.set_cover | 在当前相册单选照片，确认后设置；回读封面编号 | 源码、聚焦测试与合成 UI 已通过；真实 NAS 待验 |

本波次由当前任务独占 Photos Model/View/Panel、相关测试与双语资源中的 Photos 键；Repository 修改封面身份、回读及缩略图读取相关分支；共享领域/服务仅增量加入可选相册缩略图与读取方法。既有 Download Station 文件不修改。以上复用已授权接口，没有新增依赖、持久化、系统权限或其他平台界面。

后续仍需推进：新建标签、相对拍摄时间、条件相册、具名分享成员及密码/有效期、照片请求、人物修正、预览重建、共享空间权限。逐项取得官方接口证据后实现，不以本波次范围缩小完整对齐目标。

## 授权、范围与基线

用户要求先解决批量删除、月份跳转漂移和删除后回到最新月份，再对齐官方网页。用户明确授权新增上传、相册管理、分享管理、标签/评级/日期编辑、移动/复制接口；同时同意增量修改、同步五端影响、不改其他端 UI/存储，未验证的写入口保持关闭。

本轮基线是已有未提交的 Download Station 界面工作，未回退或覆盖。实际修改集中在 Apple Photos 协议/Repository/macOS Model/View/新表单、双语资源、Photos 自动化和发现记录。没有提交、推送、PR、安装或启动真实 App，没有向 NAS 写入测试数据。

## 功能账本

| 用户流程 | macOS 实现证据 | 契约/安全边界 | 当前验证 |
| --- | --- | --- | --- |
| 勾选多张、按天勾选、范围选择、批量删除 | SynologyPhotosModel/View 的 selection、deletionCandidates、prepare/confirm | 原有删除入口；每项预检、确认快照、自动只读回查 | 单测与浅/深色合成 UI；真实 NAS 批量异常待验 |
| 跳转月份后不自动前移 | 显式“查看更新的照片”和非惯性真实向上滚轮触发，prepend 恢复锚点 | 无新 API | 单测与静置 UI 回归；真实触控板待验 |
| 删除不刷新整页 | confirmed 项局部移除、pagedPhotoIDs 修正偏移，保留月份 | 只有成功空回读确认消失；未知不重放 | 单测与 UI 通过 |
| 批量下载原件 | saveSelection、目录选择器、逐项原件保存 | 既有读取接口；本机同名自动另存、不覆盖 | 合成文件保存测试通过 |
| 评级/说明/绝对拍摄时间 | PhotoManagementPanel、Mutation.edit、Item.set/get | 个人空间、每项身份/权限；100 项上限 | static + 合成；新入口关闭 |
| 添加/移除已有标签 | tagsAdd/tagsRemove、additional.tag | 缺失字段不视为空列表 | static + 合成缺失字段回归；关闭 |
| 创建/重命名/删除相册、加入/移除成员 | 相册右键菜单与选择菜单，NormalAlbum/Album | 所有者检查；移除成员保留原件 | static + 创建、非所有者回归；关闭 |
| 移动/复制 | 原生文件夹选择表单、BackgroundTask | 目标目录权限、同名 skip、最终计数、移动编号回读 | static + skip 回归；关闭 |
| 上传个人照片 | 系统文件选择、multipart、返回编号回查 | 当前一次一个文件；改名保留同名文件；磁盘临时体0600 | static + multipart/回读回归；关闭 |
| 相册公开查看/下载、关闭分享 | 相册右键管理分享，Passphrase/Album | 明确访问范围确认、先关闭再配置再开启、不发送密码/有效期 | static + 分享顺序和中途失败回归；真实行为待验，关闭 |

源码证据：
- `apple/Packages/DsmCore/Sources/SynologyPhotosManagement.swift`
- `apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift`
- `apple/Apps/DsmMac/Sources/SynologyPhotosModel.swift`
- `apple/Apps/DsmMac/Sources/SynologyPhotosView.swift`
- `apple/Apps/DsmMac/Sources/PhotoManagementPanel.swift`

## 完整网页对齐尚未完成的部分

不得将本轮称为“全部网页功能已经可用”。新增六类写入口没有开启；还没有覆盖多文件上传队列、上传到相册、创建新标签、相对时间调整、条件相册、具名成员/密码/有效期编辑、照片请求管理、人物修正/预览重建。部分候选方法已有静态线索，但参数或最终状态证据不足，不能猜测实现。共享空间正向权限和写行为也不在当前已验证范围。

相册封面底层有静态候选实现，原生入口尚未接入，回读证据仍需确认。现阶段仅作为 gated 接口保留，不计为用户可完成流程。

## 五端影响与迁移

| 平台 | 影响 | 实施边界 |
| --- | --- | --- |
| macOS | 新表单、选择菜单、局部结果更新；新服务协议默认关闭 | 本轮主体；无系统版本、依赖、Bundle ID、签名设置或持久化改动 |
| iPhone | 共享模型和 Repository 新增成员；协议默认实现保持源兼容 | 单项删除签名保留，自动核对新增时序仅 macOS；不添加移动 UI，不自动开放写能力 |
| iPad | 同上 | 未来应使用触控多选、系统选择器；不搬运右键/悬停交互 |
| Android | 仅影响记录 | 不修改代码；将来映射 typed mutation/结果与权限门禁 |
| Windows | 仅影响记录 | 不修改代码；将来使用 WinUI 原生选择与确认，不复制 SwiftUI 布局 |

回滚：移除新增管理表单/接口与默认关闭的能力注入，保留本轮首批照片缺陷修复可独立交付。协议新增默认实现，没有持久化迁移。未知状态目前只保存在会话中，重启恢复尚未实现，不能据此开放真实写入。

## 已执行验证

- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：76 个 XCTest（28 Model、48 Repository）与 6 个 Swift Testing 本地化测试通过。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-management-ui`：2 个合成 UI 测试通过，浅/深色表单及选择/删除后月份；只打开表单不发写请求。
- 初版修复包：`apple/Apps/DsmMac/dist/photos-selection-timeline-20260928/LanStash-1.0.10-arm64.dmg` 已完成 Release 构建、临时签名、Sparkle 实际加载与 DMG 校验。此包早于新管理功能，不能当完整对齐版。
- 新功能最终 Release 包、当前资源/契约检查与独立复核结果见后续追加；不得以旧包或局部单测代替。

## PENDING_USER_VALIDATION

1. 首批缺陷：现有测试包打开真实照片库，定位一个旧月份，静置、手动向上/向下滚动、批量选择并对明确可丢弃的测试照片删除。预期自动核对、不跳到最新、不产生重复请求；确认 VoiceOver/键盘与实际触控板行为。
2. 新写功能：先明确专用合成照片/相册/目录与 DSM、Photos 完整版本，再制作限定目标的验证包。分别验证正常、无权限、断网、取消、部分成功和二次点击；分享单独确认范围。未满足条件不开放入口。
3. 反馈只需要脱敏步骤、版本、错误类别及结果变化，不发送凭据、真实照片、地址或文件路径。

## 独立集成复核（只读）

复核以最终差异重新检查：默认能力空、原有删除门禁未放宽、profile/空间/所有者检查、先确认再写、重复标识绑定、未知状态不重放、上传不把凭据放入 URL、保存不覆盖、其他端协议默认实现及先前 Download Station 差异保留。新增真实写行为仍未验证；不能以静态证据升级兼容结论。

### 最终静态门禁与工程生成

- `python3 tools/localization/check_localization.py`：通过，Apple 4232 个资源键，双语、参数、引用与硬编码检查无问题。
- `python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、27 项私有端点文档引用通过。
- 使用项目 CI 固定的 XcodeGen 2.46.0 和既有 SHA-256 校验临时工具，执行 `xcodegen generate --spec apple/Apps/DsmMac/project.yml`；工程仅增加 PhotoManagementPanel 的 4 行引用，未手改生成文件、未升级工具链。
- `git diff --check`：通过。Chrome 临时静态检查变量已删除并核对，开发者工具已关闭。

### 最终 Release 测试包

- 实际打包：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-management-20260929" bash apple/Apps/DsmMac/package.sh`。临时命令包装仅为 xcodebuild 指定既有 `apple/.build` Sparkle 2.9.6 缓存与 `-skipPackageUpdates`，结束删除；未修改依赖、打包脚本或工具链。
- 首次预检发现新增视图未加入 Xcode 工程，按上述锁定生成流程补齐后重新打包成功，退出码 0。
- 产物：`apple/Apps/DsmMac/dist/photos-management-20260929/LanStash-1.0.10-arm64.dmg`；1.0.10 (20)，arm64。本机临时签名、Hardened Runtime 本地测试权限、Sparkle **实际加载**、架构与 DMG checksum 全部通过。
- 未安装或启动真实 App，未覆盖旧包。临时签名包不包含 Finder 本地磁盘挂载扩展；此限制与 Photos 无关。
- 首批修复与批量下载可测试；六类新增管理功能默认关闭，未声称真实环境已对齐。当前 NAS 专用合成资料的写验证范围已向用户提出，尚未收到答复，不以等待时间视为授权。
- 本轮临时测试日志、合成截图与临时工具已清理；正式测试源码、发现记录和两轮 DMG 交付物保留。工作区全部改动仍未提交，原有 Download Station 改动保持。

## 2026-09-29 后续：按用户要求移除默认禁用（当前状态）

用户明确回复“可以，代码中不要限制禁用功能”。该要求取代前面首轮新增功能保持关闭的安排，并授权仅使用新增合成资料的 NAS 验证。当前 Repository 已删除人工能力白名单字段与构造参数，六类功能按接口实际支持开放；没有追加新开关或版本白名单。身份/空间/所有者/目录权限、用户确认和未知结果不重放继续保留。未修改其他平台 UI 或存储，未提交、推送。

对应测试不再注入人工开放列表，而是使用默认真实服务入口；新增“接口齐全默认开放”“缺少上传接口不阻断其他功能”回归。`swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：77 项 XCTest（28 Model、49 Repository）和 6 项本地化测试通过。

受控网页验证只在个人空间操作：已上传两张 160×120 合成纯色 PNG；创建专用测试相册并命名；仅对合成照片设置评级和日期。保留新资料，不删除、不创建公开分享，不操作原有照片。最终回读和最新 Release 包结果继续追加。

### 当前启用版交付与复核

- 当前产物：`apple/Apps/DsmMac/dist/photos-enabled-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64；前面的 management 包是历史默认关闭版，请使用本路径。
- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-enabled-20260929" bash apple/Apps/DsmMac/package.sh`，退出码 0。继续用临时包装指定既有依赖缓存和 `-skipPackageUpdates`，未改打包脚本或依赖。
- 临时签名、Hardened Runtime 测试权限、Sparkle 实际加载（`library loaded`）和 arm64 架构均通过；额外执行 `codesign --verify --deep --strict`、`file`、`hdiutil verify`，签名、架构及 DMG checksum 通过。
- `python3 tools/localization/check_localization.py` 通过（Apple 4232、Android 2188、Windows 3402）；`python3 tools/contract-validation/validate_fixtures.py` 通过（3 组 fixture、27 项私有端点文档引用）。照片 77 项 XCTest 和 6 项 Swift Testing 全部通过。
- 独立复核：人工白名单字段和初始化参数已移除；API 版本/请求格式与空间权限仍按实际支持判断，缺失上传接口不阻断其他功能。未删除身份、所有者、确认、重复提交及未知结果不重放保护；macOS 原有删除入口保持开启。其他端 UI 与持久化、原有 Download Station 改动未改变。
- 官方网页合成资料验证：两次上传均完成，创建相册并命名；评级操作收到成功提示；修改日期为 2020-03-15 后刷新仍保持该日期。详细证据及限制见环境记录，不能代替本包的真实 NAS 写操作验收。
- PENDING_USER_VALIDATION：本包连接真实 NAS 后的完整上传、标签、相册、移动/复制、分享、断网恢复及权限失败流程尚未实测。用户已明确要求开放入口，这些待办不再用于人工禁用功能。公开分享与删除未在浏览器执行。
- 本包未自动安装、启动或覆盖旧包；临时签名包仍不包含 Finder 本地磁盘挂载扩展。当前源码未提交、未推送。


## 本波次剩余清单（当前）

| 功能 | 当前缺口 |
| --- | --- |
| 标签管理 | 新建并应用、添加/移除已有标签已接入；当前版本实机写入待验 |
| 批量时间调整 | 绝对日期与整体前移/后移已接入；部分失败只继续剩余原始目标，真实 NAS 待验 |
| 条件相册 | 个人空间创建、规则编辑、建议查找和数量预览已接入；共享空间来源随共享空间切片推进，真实 NAS 待验 |
| 分享高级设置 | 已有公开查看/下载/关闭；缺少指定成员、密码、有效期编辑及完整权限面板 |
| 照片请求 | 只有列表读取，尚无创建、修改、关闭和收集目标管理 |
| 人物整理 | 可浏览/筛选；缺少命名、合并、纠正人物识别等写操作 |
| 预览重建 | 尚未接入网页重建照片/视频预览的操作 |
| 共享空间 | 仍需确认真实正向权限枚举和完整写入契约，不能推测管理员权限 |
| 上传完整体验 | 已支持拖放、子目录媒体导入、保留目录层级与上传期间浏览；尚无跨会话续传和重启恢复 |
| 完整实机验收 | 本轮原生上传队列、相册封面、移动/复制、分享异常恢复等仍需真实 NAS 测试；不能用合成测试代替 |

此清单保持完整网页对齐目标，当前波次完成不代表总目标完成。标签、相对日期和导入体验已推进；接下来处理条件相册/分享高级设置等需要补充官方契约证据的流程。未引入默认禁用功能的人工白名单。


### 后续波次的实际验证

- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：85 项 XCTest（33 Model、52 Repository）与 6 项 Swift Testing 全部通过。新增覆盖多文件顺序、相册成员失败只重试第二阶段、未知结果核对后继续、停止队列、单项预检失败、封面成员检查、重复设置不重发、按当前会话读取封面。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test多文件上传确认与队列浅深色布局|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-remaining-ui`：3 项合成 UI 测试通过；修正上传表单重复目标文案、封面测试使用单选后，前两项再次通过。已查看浅/深色上传确认、队列与封面截图，无顶部留白错位或底部操作区挤压。
- `python3 tools/localization/check_localization.py`：双语资源、引用、占位符与硬编码扫描通过，Apple 4251、Android 2188、Windows 3402；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、27 项私有端点引用通过。
- 独立集成与写操作复核：上传入队前保留文件快照，写后按返回照片编号确认；相册加入失败保留原件，不自动重传；未知结果保留操作编号，仅回读。停止按钮不假装取消已提交请求；封面按成员与所有者检查，读取时不用旧会话缩略图编号。未新增公开分享、真实上传或删除测试操作。
- 共享契约：SynologyPhotoCollection.thumbnail 默认 nil，thumbnail(for: collection) 有协议默认实现；五端影响同步记录。队列仍为内存状态，不改变持久化/签名/权限/最低版本。回滚可移除队列和封面入口及可选字段/默认方法，既有单文件上传、普通相册管理和首批时间轴修复保持独立。
- PENDING_USER_VALIDATION：用专用合成图片，在真实 NAS 上验证多文件上传至个人图库、当前文件夹和本人相册；制造加入相册失败后确认只重试加入；设置封面后返回相册列表确认图片更新。要求回传脱敏步骤、DSM/Photos 版本和失败类别，不提供凭据或原照片。未运行的 NAS 验收不计为通过；入口遵循用户要求不设人工默认禁用。


### 后续波次测试包

- `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-uploads-cover-20260929" bash apple/Apps/DsmMac/package.sh`：退出码 0；临时 xcodebuild 包装继续使用既有依赖缓存与 `-skipPackageUpdates`，未改变工具链。
- 新产物：`apple/Apps/DsmMac/dist/photos-uploads-cover-20260929/LanStash-1.0.10-arm64.dmg`；1.0.10 (20)、arm64。本机临时签名、Sparkle 实际加载、架构和 DMG checksum 通过；额外 `codesign --verify --deep --strict` 与 `file` 复核通过。
- 未自动安装或启动，未覆盖前次交付包；本地磁盘挂载扩展按既有临时签名流程排除。上传队列、目标相册/文件夹与封面入口按实际能力开放。
- 最终 `git diff --check` 通过；本轮临时测试日志、合成截图已清理，正式测试与交付包保留。源码仍未提交，原有 Download Station 改动保留。整体网页复刻目标仍在进行中，剩余清单见上节。


### 标签与相对日期波次验证

- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：最终 96 项 XCTest（36 Model、60 Repository）与 6 项 Swift Testing 全部通过。覆盖新标签创建/回读/应用、丢失回执不重建、缺少创建接口不影响已有标签、正负日期偏移、时间越界、部分失败及原目标续做。
- 只读集成复核发现“续做预检失败会丢失继续入口”。新增 `SynologyPhotosModelTests/test继续剩余照片预检失败仍保留原目标供再次继续` 首次运行失败（3 条断言），修复后纳入上述 96 项回归通过；没有降低原断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-tags-dates-ui`：2 项合成 UI 测试通过。表单测试已覆盖新建标签与相对时间的浅/深色；时间预览补充秒级显示后再次运行表单测试。
- `python3 tools/localization/check_localization.py`：通过，Apple 4267、Android 2188、Windows 3402。`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture 和 27 项端点文档引用通过。`git diff --check` 通过。
- 写操作复核：每张照片身份与目录权限先检查；标签创建回执丢失不按名称猜测；新标签应用失败保留编号；相对日期仅复用已记录绝对时间请求，保留原目标，未知只读，部分结果不累加已成功偏移。七类管理能力均按实际 API 支持开放，不设人工白名单。
- macOS 是本轮验证目标。DsmMobile 通过 project.yml 引用共享 Model，未发现移动 UI 的新命令调用或需同步修改的穷尽分支；本轮未运行 iOS 构建，不以 macOS 通过代替移动端构建。
- PENDING_USER_VALIDATION：在专用合成图片中创建/应用一个新标签；选择具有不同拍摄时间的两张合成图片，统一前移或后移，确认间隔保留；断网/权限失败后继续仅处理未完成项。真实 NAS 与网页参数核对仍等待 Mac 解锁，未新增真实写入或公开分享。

已实现项目现在包括新建标签与相对日期。尚未实现的已确认项：条件相册、分享高级设置、照片请求写管理、人物整理写操作、预览重建、共享空间完整权限/写操作，以及上传拖放/目录批量导入/后台浏览/重启恢复。整体对齐目标保持进行中。


### 标签与日期最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-tags-time-20260929" bash apple/Apps/DsmMac/package.sh`。修复续做预检失败和秒级预览后重新构建，最终退出码 0；临时命令包装仅指定既有 `apple/.build` 缓存与 `-skipPackageUpdates`，已自动删除。
- 最终产物：`apple/Apps/DsmMac/dist/photos-tags-time-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64。签名、Hardened Runtime 测试权限、Sparkle 实际加载（library loaded）、架构与 DMG checksum 均通过；`codesign --verify --deep --strict` 与 `file` 额外复核通过。
- 秒级预览修正后的 `WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐` 再次通过，浅/深色截图已查看。没有声称锁屏状态下完成真实 Chrome/NAS 验收。
- 本包未自动安装、启动或覆盖前轮已交付包；临时签名包仍不包含 Finder 本地磁盘挂载扩展。当前改动未提交、未推送，原有 Download Station 改动保留。
- 本轮临时日志、截图及失败回归日志已清理；正式测试、发现记录与 DMG 保留。整体目标仍在进行中，不能将当前两个功能交付当作完整网页复刻完成。

### 拖放与目录导入波次基线

- 范围：macOS 照片上传入口、上传确认表单和本地来源准备；复用既有上传及加入相册契约，不改变 NAS 写入参数或其他端界面。
- 交互：拖放文件/文件夹或选择目录后，展开支持的照片/视频供确认，上传到当前目标。目录层级不重建，确认页明确说明；不把该切片描述为完整目录同步。
- 安全：原始选择的目录访问授权保留到队列释放，忽略符号链接、隐藏项和软件包；读取错误不静默上传不完整清单；重叠来源去重。
- 当前证据：既有多文件上传实现与测试；新切片尚未验证。Chrome 已恢复，可继续只读网页核对。
- 非目标：此切片不改持久化，不做重启恢复、文件夹创建或用户真实资料写入。上传期间浏览另行拆分读写生命周期，集成结果见下节。


### 拖放、目录导入与上传期间浏览验证

- 实际修改：`SynologyPhotosModel.swift` 增加本地媒体清单准备、原始目录授权共享持有，图库读侧与上传队列生命周期分离；`SynologyPhotosView.swift` 增加 URL 拖放与目录选择；`PhotoManagementPanel.swift` 在后台准备清单并展示忽略数量、无媒体状态和目录汇总说明。双语资源与正式 Model/UI 测试同步。
- 上传期间可刷新、跳月份、切换照片内页面/文件夹、离开图库，队列保留原始目标并继续；退出当前连接或禁用模块仍沿用全部工作取消流程。刷新复用当前已确认访问范围，不重置 Repository 的在途写操作权限代数；新的上传文件不使正在读取的图库代数失效。写操作仍串行，未知结果仅回读。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：101 项 XCTest（41 Model、60 Repository）及 6 项 Swift Testing 通过。新增目录/重叠来源、链接循环/隐藏项/空文件、不完整读取失败、目录授权释放、离开图库继续上传、读取和下一文件上传交叉时序测试。
- 新增目录测试最初失败：对符号链接调用 skipDescendants 会跳过后续正常项目；已移除该调用，保留 FileManager 不遍历符号链接的行为，原断言通过。系统临时路径别名采用规范化后的文件身份比较，没有降低来源授权和去重断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录上传确认浅深色布局|WorkspacePresentationTests/test多文件上传确认与队列浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-import-ui`：3 项通过；已查看目录确认浅/深色截图，标题、清单与底部按钮正常。
- `python3 tools/localization/check_localization.py`：Apple 4270、Android 2188、Windows 3402，通过；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、27 项私有端点引用通过；`git diff --check` 通过。
- 独立集成复核：读取和写入状态分别管控；未删所有者/权限、预检、确认、重复提交与结果核对保护；保留用户要求的按实际能力开放。未添加 NAS API、第三方依赖、持久化、权限或工具链变更。其他端不新增界面；移动端共享 Model 的编译影响仍需 iOS 构建，未运行。
- PENDING_USER_VALIDATION：在本包选择专用合成目录并拖放同一目录，确认文件数、忽略提示、重复文件处理；上传时跳转旧月份、打开其他相册/文件夹，确认上传持续且目标不变。真机拖放、沙盒目录授权与真实 NAS 上传尚未执行，不能以合成测试替代。目录层级保留和重启恢复仍未实现。


### 导入与浏览测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-import-browse-20260929" bash apple/Apps/DsmMac/package.sh`，退出码 0。临时 xcodebuild 包装仅指定既有 `apple/.build` 缓存和 `-skipPackageUpdates`，已自动删除。
- 产物：`apple/Apps/DsmMac/dist/photos-import-browse-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)，约 17 MB。临时签名、权限检查、Sparkle 实际加载（library loaded）、arm64 架构和 DMG checksum 均通过；额外 `codesign --verify --deep --strict` 与 `file` 通过。
- 未自动安装、启动或覆盖既有包；本地磁盘挂载扩展仍按现有临时签名流程排除。当前源码未提交、未推送，既有 Download Station 修改保留。本轮临时日志和合成 UI 截图已清理，正式测试与交付包保留。
- Chrome 在后续确认时再次报告锁屏，未绕过；本轮没有新增 NAS 写入。网页完整参数核对继续等待可用会话，不将尚未完成的条件相册、分享高级设置等声明为完成。

### 剩余能力依赖复核与重启恢复方案（待授权）

2026-09-29 本轮重新读取源码、契约索引和 Photos 发现记录。前一波次属于实际进展：已交付目录导入/并行浏览及构建验证。当前 Chrome 再次明确报告锁屏，不能据旧控件文案猜测新请求。

| 剩余能力 | 当前权威证据 | 接入前缺口 |
| --- | --- | --- |
| 条件相册 | 现有 NormalAlbum 普通相册契约 | 条件表达式结构、创建/修改方法与回读规则 |
| 分享高级设置 | Passphrase.set_shared/update 仅有 public view/download 参数；官方控件已观察 | 成员身份/角色、密码更新与移除、有效期语义、完整现状回读 |
| 照片请求写管理 | PhotoRequest.list v1 与空响应 | 创建/编辑/关闭参数、收集目标权限与结果回读 |
| 人物整理 | Browse.Person.list v1 | 命名/合并/纠正参数与识别成员回读 |
| 预览重建 | 无已记录写方法 | 任务创建、进度、终态与权限 |
| 共享空间写操作 | 个人空间写权限已接入 | 共享空间正向权限和实际写端点组 |
| 导入保留目录层级 | Upload.Item.upload_to_folder 已有 | Browse.Folder 创建目录的准确契约与回读 |

重启恢复为独立的本地存储变更，尚未实施；先提供可审阅方案，再取得项目 AGENTS.md 要求的单独授权：

1. 范围仅 macOS Photos 上传队列。使用当前 NAS 配置 UUID 分区，新增独立 version=1 队列记录，不改已有文件传输、NAS 配置、认证或其他端存储。目录在应用私有 Application Support 下，文件权限 0600、原子替换。
2. 存储字段：队列项 UUID、源文件名/大小/修改时间、所选来源的系统访问书签与相对路径、个人空间目标文件夹/相册编号、状态、操作 UUID、已返回的照片编号及最小身份快照。密码、Cookie、SID、SynoToken、下载数据、分享链接和用户照片内容均不保存；书签不输出日志或提交仓库。
3. 原始源目录授权用系统书签延续；过期或不可访问时让用户重新选同一来源，并按原大小/修改时间核对，不能改为扫描其他目录。若需要新增系统权限配置，另行说明，不能借本次存储授权暗中改变 entitlement。
4. 顺序：入队先原子落盘；发送前落盘“在途”；获取返回照片编号即保存；核对成功后保存“已上传”；加入相册独立记录。写入失败先停止尚未开始项并给出可重试错误，不能显示已保存。
5. 重启后未开始项恢复为可继续；已确认上传项只核对/补加入相册；原件大小/修改时间变化时要求重新选择。已提交但没有收到照片编号的结果仍不可按文件名猜测成功，也不自动重复上传。没有服务端幂等证据时，不承诺字节级断点续传或恰好一次恢复。
6. 迁移：无旧 Photos 队列，首次读取为空；老版本忽略新增文件，不迁移已有数据。回滚移除新存储注入与恢复入口，保留或由用户清除新队列记录，绝不删除 NAS 文件；现有进程内队列可独立工作。
7. 验证：进程在各状态边界终止后恢复、跨 NAS 隔离、书签失效、文件变化、原子保存失败、部分相册加入成功与未知结果不重放。五端只记录影响：macOS 接入，iOS/iPadOS 不接入桌面书签恢复，Android/Windows 不修改代码或存储。

此方案不是已完成的功能，不改变现有测试包；批准后再实现、测试和打包。


### 目录层级与后续接口发现波次

Chrome 已恢复，静态接口证据已扩展至条件相册/高级分享/人物/照片请求/预览重建/目录创建，记录见 photos-advanced-management.md，仍不是实机写入验证。优先接入逐级目录导入，单一修改范围为 Photos 领域命令、Repository、macOS 队列/上传表单及对应测试/双语资源；其他端 UI 与持久化保持不变。复用已授权契约扩展，不涉及待授权重启存储。回滚本轮新建目录命令及层级开关即可保留原汇总上传流程。


### 目录层级上传实现与验证

- 实际修改：共享 SynologyPhotosManagement 的目录能力/命令/可选结果；Repository 的预检、创建、去重及精确回读；macOS Model 的逐级解析、同批目录缓存和未知结果恢复；PhotoManagementPanel 的默认保留层级开关、目标展示和准备目录状态；双语资源和正式测试同步。未变更权限、持久化、工具链或其他端 UI。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：109 项 XCTest（45 Model、64 Repository）和 6 项本地化测试通过。新增已有目录/逐级创建/同批复用/跨批隔离/平铺选择/未知暂停恢复/回执丢失/权限拒绝与身份不匹配回归。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录上传确认浅深色布局|WorkspacePresentationTests/test多文件上传确认与队列浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-hierarchy-ui`：3 项通过，浅深色截图已查看；发现重复同名文件说明后去重。
- `python3 tools/localization/check_localization.py`：Apple 4273、Android 2188、Windows 3402，通过；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、31 项私有端点引用通过；`git diff --check` 通过。
- 独立集成与写操作复核：目录缓存以批次/父编号/名称定位，跨批重新核对；创建结果未知只读，确认后继续原队列；清除已完成项可能改变数组下标，await 后按稳定队列编号重新定位；进入上传时清除照片选择，避免阻止浏览；上传仍进行来源快照和目标权限核对。同名文件不覆盖，失败不自动回滚删除目录。
- 五端影响已同步：macOS 接入；iOS/iPadOS 共享增量但无新 UI、未运行移动构建；Android/Windows 只记影响。用户授权不设默认禁用/环境白名单，保留真实能力、权限、确认和结果检查。
- PENDING_USER_VALIDATION：专用合成目录包含两级子目录及同名目标，选择/拖放后确认层级；上传中浏览旧月份，确认不跳回最新；断网后确认不重复新建/上传，恢复后目标正确；关闭保留层级后确认汇总到原目标。回传脱敏版本、步骤、错误类别及是否重复，不提供原照片/地址/凭据。本轮未做 NAS 写入，沙盒目录权限和真实行为仍待验。

当前剩余：条件相册、分享高级设置、照片请求写管理、人物整理、预览重建、共享空间完整权限/写操作、上传跨会话与重启恢复。高级接口已取得静态线索，仍需接入和验证；重启持久化继续等待已发出的独立授权，不阻塞其他功能。

去重说明后再次运行 `WorkspacePresentationTests/test目录上传确认浅深色布局`，1 项通过，浅/深色截图复查无截断或重复提示。本地化、fixture 引用和 `git diff --check` 再次通过。


### 目录层级上传测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-structure-20260929" bash apple/Apps/DsmMac/package.sh`，退出码 0；临时 xcodebuild 包装仅指定既有依赖缓存和 `-skipPackageUpdates`，已自动删除。
- 产物：`apple/Apps/DsmMac/dist/photos-folder-structure-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)，约 17 MB；App 名为 `LanStash Test.app`。临时签名、权限、Sparkle 实际加载（library loaded）、arm64 架构与 DMG checksum 均通过。
- 额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-folder-structure-20260929/LanStash Test.app'` 与 `file 'apple/Apps/DsmMac/dist/photos-folder-structure-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 通过；首次复核误用 LanStash.app 路径报不存在，按打包输出的实际 Test.app 路径重跑成功，非构建失败。
- 未安装、启动或覆盖之前的交付包；本机临时签名包不含 Finder 本地磁盘挂载扩展。未改变 Bundle ID、权限、存储结构或其他端界面，未提交/推送，原有 Download Station 修改保留。
- 本轮临时测试日志、截图和打包日志已清理，正式测试、脱敏接口记录与交付包保留。完整网页复刻目标仍在进行中，下一切片优先条件相册；剩余清单见上节。

### 条件相册波次基线

范围为个人空间条件相册创建、规则读取/编辑、规则建议与数量预览，集成既有相册列表/删除/重命名。当前静态证据确认 Album.list 的 normal_share_with_me 也用于官方全部相册列表，type=condition 标识条件相册；ConditionAlbum.suggest v3 返回按字段分组的建议，规则引用回读为 id/name，范围/关键词/闪光灯原样。编辑保留完整规则，不静默丢弃未知或缺失名称的引用；不做官方自动迁移清理。新契约仅按既有授权增量扩展，五端同步影响；持久化和其他端界面非目标，NAS 不执行写入。上一轮目录层级上传已交付，为有效进展。


### 条件相册实现与验证

- 实际修改：SynologyPhotosManagement 的条件能力/值/命令，SynologyPhotos 的可选类型标记和默认读取方法，Repository 的创建/原条件快照冲突检测/完整回读/建议与数量请求；DsmJSONValue 增加 decimal/null 保留合法 JSON 值。macOS 相册加号菜单增加创建条件相册，条件相册右键菜单增加编辑规则，复用重命名/删除；选择源目录与相机等规则、关键词/人物/标签/主题匹配策略、预览数量均接入。双语资源、正式测试和五端影响同步。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests|DsmRequest'`：120 项 XCTest（47 Model、70 Repository、3 Request）和 6 项本地化测试通过。覆盖条件创建的 v3/类型编码/目录权限/集合顺序，完整回读、无名引用、未知字段、过期快照、创建回执丢失不重发、所有者/日期/策略拒绝、建议范围/地点与只读数量、列表插入类型。
- 独立集成复核发现未知数组被集合归一化，新增 `test条件回读保留缺名引用和未知字段编辑时不丢失` 的两条断言先失败（空数组丢失、顺序被改），限制归一化到已知集合字段后，完整 120 项通过；没有降低原断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test条件相册表单创建编辑错误浅深色布局|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-conditions-ui`：3 项通过。已查看创建/编辑/错误浅深色图，发现错误内容偏左后补齐可用区布局并单独复测该表单。
- `python3 tools/localization/check_localization.py`：Apple 4313、Android 2188、Windows 3402，通过；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、31 项私有端点引用通过；`git diff --check` 通过。
- 写操作只读对抗复核：条件来源绑定当前个人空间用户，所有者/目录可见性独立核对；编辑前重新读取原条件，别处修改则报冲突而不覆盖。原有缺名引用和未知字段保留，只有已知集合归一化。创建丢失回执不按名称猜测、同操作不重发、写后规则不匹配不报成功。重命名独立于规则保存，不引入两阶段假原子保存。条件相册不提供手工加入/移除照片，其自动规则决定成员；普通相册不受影响。
- 兼容边界：个人空间已接入，共享来源仍属于剩余共享空间能力；已有闪光灯规则保留/可移除，官方默认建议未提供新闪光灯值域，不编造新入口。未引入人工禁用/版本白名单，无持久化、权限、工具链或依赖变更。iOS/iPadOS 共享模型受影响但无新 UI，未运行移动构建；Android/Windows 只同步计划。
- PENDING_USER_VALIDATION：在专用合成资料中创建条件相册，组合日期、类型、标签等规则并预览数量；保存后与网页核对成员/规则，再编辑其中一项，确认其他规则保留；网页同时修改时应提示重新核对；断网后不得重复创建。需确认真实 DSM/Photos 版本、非空建议字段、日期边界与集合回读结构。回传脱敏步骤和失败类别，不提供原照片/地址/凭据。本轮未执行真实 NAS 条件写入，不能以合成测试替代。

当前尚未完成：高级分享（成员、密码、有效期）、照片请求写管理、人物整理、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复。普通个人条件相册已从“未实现”移为“源码和本地验证完成、真实 NAS 待验”。总目标继续，不把此切片算作完整网页复刻。

错误状态居中修正后，`WorkspacePresentationTests/test条件相册表单创建编辑错误浅深色布局` 再次通过（1 项，浅深色各覆盖创建、编辑与错误）。已查看修正截图，标题/表单/底部操作区与错误内容位置正常。


创建菜单最终复核：普通相册与条件相册入口独立按实际能力判定，父菜单仅在两种都不支持时不可用。新增 `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests/test普通与条件相册能力独立不相互禁用'`，1 项通过；测试初次编译的枚举类型推断问题已修正。该 UI 修正后重新生成最终 Release 包，不沿用修正前包。本地化/fixture/diff 校验再次通过。


### 条件相册最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-conditions-20260929" bash apple/Apps/DsmMac/package.sh`。菜单能力独立修正后重新完整构建，最终退出码 0；临时 xcodebuild 包装仅指向既有缓存与 `-skipPackageUpdates`，自动清理。
- 产物：`apple/Apps/DsmMac/dist/photos-conditions-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64，约 17 MB。临时签名、权限检查、Sparkle 实际加载（library loaded）及 DMG checksum VALID；额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-conditions-20260929/LanStash Test.app'` 与 `file 'apple/Apps/DsmMac/dist/photos-conditions-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 均通过。
- 未自动安装或启动，未覆盖前轮交付包；本机临时签名包仍不含 Finder 本地磁盘挂载扩展。不修改应用标识、持久化、系统权限或其他端 UI，未提交/推送，已有 Download Station 改动保留。
- 当前波次临时日志/合成截图已清理，浏览器源码变量删除与开发者工具关闭已确认；正式源码、测试、脱敏发现记录和交付包保留。最终 `git diff --check` 通过。整体目标继续，下一切片优先高级分享，缺口及授权边界见本账本。

### 高级分享波次基线

上一波次已交付条件相册，为有效进展。当前 Chrome 明确报告 Mac 锁屏，暂不能补齐分享密码加密、成员列表/权限非空结构及有效期时间语义；不绕过锁屏或读取浏览器会话文件。先接入已有分享状态读取、保留现状与公开/仅受邀者访问方式，复用已记录 set_shared/update 参数；高级密码、成员和有效期编辑仍保留完整目标，不凭猜测编码。只修改 Photos 领域、Repository、macOS 分享表单、测试/双语/契约记录，其他端 UI 与持久化非目标，不进行真实公开分享或权限写入。


### 分享现状与访问方式实现、集成复核

- 实际修改：Photos 领域新增 SynologyPhotoSharingState、albumSharing 与 shareAlbum 可选原快照；Repository 只读现状、并发快照检测、无改动不写入、仅受邀者公共成员删除、保护元数据回读；macOS 分享表单按当前设置初始化，展示保护标记/链接复制，修复英文提示截断。6 个双语资源同步；无人工验证名单，无持久化/权限/依赖变更。
- Chrome 恢复可用后继续静态复核，发现公开权限转换仅 private/public-view/public-download；纠正开发中按常量误加的 public-upload，并新增未知权限拒绝测试。upload 仍为具名成员角色的后续范围。未执行真实分享、密码或成员写入。加密和日期后续线索已脱敏记录，临时浏览器变量已删除、开发者工具关闭。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：125 项 XCTest（47 Model、78 Repository）与 6 项本地化测试通过。新增 7 项测试覆盖三种已启用模式读取/保护未知/不变不提交/并发修改/预读失败重试/公共成员差量/保护回读变化/未知权限。新增错误态 UI fixture 首次使用错误的 AppError 初始化参数导致编译失败，改为标准 URLError 后重跑通过；没有降低断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-sharing-ui`：2 项通过，覆盖关闭/仅受邀者/公开下载/读取错误及现有表单，已查看浅深色合成截图。打开表单写入次数为0，提示不再截断。
- `python3 tools/localization/check_localization.py`：Apple 4319、Android 2188、Windows 3402；双语、参数、引用与硬编码检查通过。`python3 tools/contract-validation/validate_fixtures.py`：3 组、31 项引用通过；`git diff --check` 通过。
- 独立集成与只读对抗复核：新增快照是内存 SHA-256，不记录分享凭据；含原成员/保护字段用于并发检测。预读取位于写入记录之外，读失败不会留下阻塞重试的未知写入；同操作复用去重。仅受邀者只删除 public 项，不误删具名成员。链接限制 http(s)、有主机、无嵌入账号密码。最后状态不符不宣称成功。其他端仅同步影响，未运行移动/Windows/Android 构建，保留既有 Download Station 改动。
- PENDING_USER_VALIDATION：专用合成相册分别在网页设置关闭、仅受邀者、公开查看/下载，macOS 打开应准确显示且无写入；更改方式时核对现有成员、密码与有效期仍保留；网页同时更改后 macOS 保存应提示重新打开；断网后只核对不重复保存。实际分享写入需要针对测试相册/访问范围单独授权，本轮未执行。回传脱敏版本、步骤和错误类别，不提供真实链接、成员和凭据。

当前剩余仍为：高级分享成员/密码/有效期编辑、照片请求写管理、人物整理、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复（独立存储授权仍待答复）。分享现状读取与访问方式已补齐，不把它称为高级分享全部完成。下一切片继续成员结构和密码/日期协议核对。


### 分享状态最终测试包

- 命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sharing-state-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0；临时 xcodebuild 包装只指定既有依赖缓存和 -skipPackageUpdates，自动清理。
- 产物：`apple/Apps/DsmMac/dist/photos-sharing-state-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)，arm64，约17 MB。签名、Hardened Runtime 权限与 Sparkle 实际加载（library loaded）通过，DMG checksum VALID。额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-sharing-state-20260929/LanStash Test.app'` 与 `file 'apple/Apps/DsmMac/dist/photos-sharing-state-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 均通过。
- 未自动安装/启动，旧交付包保留；临时签名包按既有流程移除 Finder 本地磁盘挂载扩展。应用标识、存储和系统权限无变更，未提交/推送。工作区仍在 main@9c30efeab8fb，保留全部此前用户/本任务改动及未跟踪正式源码/文档，Download Station 不触碰。
- 当前波次临时日志和合成截图已删除；正式测试、脱敏证据、账本和交付包保留。最终 diff 检查通过。整体网页复刻目标仍在进行中，未标记完成。


### 分享成员管理波次基线

上一轮已交付分享状态读取、访问方式和独立测试包，属于有效进展。继续原完整目标，当前优先补齐具名成员查询、增加/移除与角色编辑，保留未展示成员并按完整原快照核对。单一修改范围为 Photos 领域/Repository/macOS 分享表单及测试、资源和契约记录；其他端 UI、持久化和 NAS 实际权限写入均非本轮范围。共享契约扩展沿用已获授权，未获上传持久化授权不影响本切片。开始前已检查 dirty main，保留此前所有改动，不提交/推送。


### 分享成员实现与验证

- 实际修改：Photos 领域新增成员身份/角色对象，状态 members 可选值与 sharingRecipients 默认方法，shareAlbum 增加默认 nil 的成员参数；Repository 读取候选、保留编号原 JSON 类型、区分系统 uid 和 Photos id、解析当前名单、差量校验/保存/回读。macOS 同一分享窗口增加搜索、用户/群组选取、角色修改和移除；内容可滚动，标题/底部操作固定，长英文权限完整显示。14 条双语资源同步。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：135 项 XCTest（47 Model、88 Repository）与6项本地化测试通过。新增10项覆盖用户/群组同编号、当前 uid 排除、整数/字符串编号、增删改差量、名字变化忽略、名单重排不写、未知结构不当空名单、目标消失、回读不符不重发、重复身份、条件相册禁止上传、关闭时成员更改不启用、仅关闭时缺失成员字段、未知原角色不降级。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-members-ui`：2项通过；扩展关闭/仅受邀者/公开下载/整体错误/候选错误/空名单/上传角色的浅深色状态，打开所有表单的写入次数为0。已查看成员正常、最长英文角色、候选错误截图；失败不遮挡既有名单和基础分享。
- `python3 tools/localization/check_localization.py`：Apple4333、Android2188、Windows3402，双语/参数/引用/硬编码扫描通过；`python3 tools/contract-validation/validate_fixtures.py`：3组、31项端点引用通过；`git diff --check` 通过。
- 独立集成/只读对抗复核：原快照完整摘要校验；新成员写前重读候选；名单重复不构造 Dictionary 以免崩溃；只发送 type/id 与改变角色，不发送显示名或完整名单；保留未知原角色，无法完整解析名单时不当空值覆盖；未改公开模式不发送 public 差量。关闭时改成员不调用 enabled=true，单纯关闭不要求已隐藏成员字段；有成员修改则核对完整身份/角色和保护状态。成员目录能力单独读取，缺失不关闭其他分享功能。检查全部 Apple shareAlbum 模式匹配已同步；五端影响记录同步，未运行其他端构建。
- 本轮无真实成员列表响应/权限写入，证据为官方前端 static 与合成自动化；后续额外常量检查遇到锁屏，之前临时源码变量已经删除，未绕过锁屏。无人工验证白名单，真实空间/所有者、重复提交和最终核对仍保留。未改变权限、存储、工具链、依赖或其他端 UI。
- PENDING_USER_VALIDATION：在明确授权的专用合成相册，添加测试用户/群组并分别查看、下载、上传，条件相册不显示上传；改一成员并移除另一成员后与网页核对名单，原密码/有效期不变；同时在网页编辑应触发冲突提示；断网不重复提交；关闭分享时调整成员仍保持关闭。提供脱敏 DSM/Photos 版本、步骤、错误类别与是否出现重复或意外扩大权限，不回传成员真实数据/链接/凭据。本轮未执行权限写入，不能把合成测试称为真实 NAS 通过。

当前剩余：分享密码/有效期编辑、照片请求写管理、人物整理、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复（独立持久化授权仍待答复）。具名成员增删改与角色编辑已从“未实现”移为“源码/本地验证完成、真实 NAS 待验”。下一切片继续密码与有效期协议和界面，完整网页目标保持进行中。


### 分享成员最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sharing-members-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时 xcodebuild 包装只指定已存在依赖缓存与 -skipPackageUpdates，任务结束自动移除。
- 产物：`apple/Apps/DsmMac/dist/photos-sharing-members-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64、约17 MB。签名、Hardened Runtime 权限、Sparkle 实际加载（library loaded）及 DMG checksum VALID 全部通过。额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-sharing-members-20260929/LanStash Test.app'`、`file 'apple/Apps/DsmMac/dist/photos-sharing-members-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 均通过。
- 未自动安装/启动，不覆盖此前包；本地临时签名按既有流程不包含 Finder 本地磁盘挂载扩展。未更改应用标识、系统权限、持久化或其他端 UI，未提交/推送。dirty main@9c30efeab8fb 仍保留此前所有改动，Download Station 未触碰。
- 当前波次临时测试日志、合成截图及打包日志已清理，正式源码/测试、脱敏记录、账本和交付包保留；最终 diff 检查通过。总目标保持 active，尚未完成全量网页复刻。


### 人物命名与合并波次基线

上一轮成员管理已完成源码、本地验证和独立包，属于有效进展。当前 Chrome 锁屏，分享加密和日期绑定暂不能补证；继续已记录 Person.set v1 和 merge v2，先完成命名/合并主流程，其他人脸级整理仍保持原目标。使用现有 Person.list、Timeline.get(person_id) 与 Item.list(person_id) 做前后核对，不猜测 face_id 或预览事件。单一修改范围为 Photos 领域、Repository、macOS 人物入口/表单、测试/双语和契约记录；其他端 UI、持久化、真实 NAS 写入非目标。保留全部 dirty main 与 Download Station 改动，不提交推送。


### 人物命名、合并与分类封面验证

- 实际修改：共享 Photos 领域增加独立人物能力/命令/结果与默认人物列表/分类缩略图方法；Repository 接入 Person.set v1、merge v2、合并前照片并集与目录权限、原人物快照和最终回读；macOS 人物卡片右键入口、命名/合并表单、封面与照片数、当前列表局部更新。新增9条中英文资源，五端影响与契约记录同步；其他端 UI、依赖、持久化、权限未改。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：146项 XCTest（49 Model、97 Repository）和6项本地化测试通过。新增覆盖改名冲突、清空名称隐去且回执丢失、合并重叠照片并集、来源仍存在、目录权限/不完整照片拒绝、同操作不重发、重复身份、Person v1独立命名、分类封面隔离与重新授权失效。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test人物命名合并空列表和错误浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-people-ui`：2项通过，命名/合并/空列表/错误浅深色、月份定位及删除保持位置覆盖。查看命名浅色、合并深色截图，修正误用“已选择”的照片数量文案，并增加封面以区分未命名人物；修正后上述全量聚焦测试与界面测试重新通过。
- 独立集成/只读对抗复核：分类卡片原来按相册编号取封面，现改为当前分类授权列表缩略图，分类隔离且重新授权清空；新增两项回归。人物合并所有来源与目标必须唯一且仍存在，重读名称/数量，完整读取照片并检查目录权限后才提交；回读必须同时满足来源消失、目标名称和照片并集一致。清空名称只有明确成功回执+列表隐去才认可特殊结果，未知结果仅回读不重发。此核对是照片级而非人脸级，不宣称实际识别结果已验证。正常命名不依赖 merge v2 能力，未增加人为禁用或版本白名单。
- 本轮 Chrome 锁屏，未新增前端观察或执行 NAS 写入，依赖已记录官方 static 参数与合成测试。无临时浏览器源码变量。共享空间与人脸级整理非本切片，不猜 face_id。
- PENDING_USER_VALIDATION：在专用合成照片形成的测试人物中修改名称、清空少于两张照片人物的名称，核对网页与 App 列表；将两个代表同一人的测试人物合并，含一张重叠照片，确认所有原图保留、目标名称正确、来源卡片消失；断网不得重复合并，网页同时改名应提示重新核对。需要明确真实 NAS 写入测试范围；本轮未执行。回传脱敏版本、步骤、错误类别及重复/遗漏现象，不提供原图、人物真实姓名或凭据。

当前剩余：分享密码与有效期编辑、照片请求写管理、人脸分离/封面/识别纠正、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复（独立持久化授权仍待答复）。人物命名与合并已从未实现移至源码/本地验证完成、NAS待验。完整网页对齐总目标仍进行中。

补充校验：`python3 tools/localization/check_localization.py` 通过（Apple4342、Android2188、Windows3402，含双语/参数/引用/硬编码）；`python3 tools/contract-validation/validate_fixtures.py` 通过（3组、31项端点文档引用），契约文档更新后再次通过；`git diff --check` 通过。已另查看人物空列表深色、加载错误浅色截图，内容区域与恢复按钮布局正常。


### 人物整理最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-people-management-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时 xcodebuild 包装仅指定既有 apple/.build 依赖缓存与 -skipPackageUpdates，自动移除。
- 产物：`apple/Apps/DsmMac/dist/photos-people-management-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64、17 MB。签名、Hardened Runtime 权限、Sparkle 实际加载（library loaded）、DMG checksum VALID 均通过；额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-people-management-20260929/LanStash Test.app'` 和 `file 'apple/Apps/DsmMac/dist/photos-people-management-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 通过。
- 未自动安装/启动，旧包保留。本机临时签名包按项目流程不包含 Finder 本地磁盘挂载扩展，应用标识/存储/系统权限无变更。工作区保持 dirty main@9c30efeab8fb，保留已有所有改动和正式未跟踪源码/文档，不提交或推送，Download Station 本轮不触碰。
- 当前人物波次临时日志/合成截图已清理；正式源码、自动化、脱敏文档和独立包保留。最终 diff 检查通过。完整网页复刻目标继续，下一步优先分享密码/有效期的官方绑定证据及照片请求写管理。


### 分享有效期与收集请求波次基线

上一轮人物命名/合并与分类封面已交付源码、验证和独立包，为有效进展。本轮 Chrome 恢复可读，沿用已有环境快照仅观察官方前端，不进行分享或收集链接写入。先核对有效期日期绑定与照片请求结构，再接入完整主流程；单一修改范围为 Photos 领域、网络、macOS表单/模型、测试、双语资源与五端契约文档。保留 dirty main 及下载模块改动，无持久化/依赖/其他端UI变更。
