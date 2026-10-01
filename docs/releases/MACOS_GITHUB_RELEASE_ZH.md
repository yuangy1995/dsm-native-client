# macOS GitHub 发布与在线升级

## 更新说明与挂载刷新修正（2026-09-11）

用户已明确要求发布本轮修复，按既有稳定通道准备 1.0.9，主 App 与扩展构建号均为 19。
先在专用分支完成云端门禁，再将单一修复提交合入主分支，沿用双架构签名、公证与更新源回读校验流程。
以下保留开发阶段的实际验证记录；真实 Finder 回调和用户系统上的安装后验收不因发版准备而视为通过。

### 改动与边界

- 用户反馈 1.0.8 更新弹窗没有日志：原生成器没有 `description`，普通更新只读内嵌文本且不启动已存在的公开日志获取。
  现在优先显示更新源正文，缺失时从固定 GitHub 仓库按弹窗中的精确版本获取对应发布说明。
  稳定与验收标签分别匹配，不使用其他平台、草稿或错误版本的内容替换当前候选版本。
- 获取仅限公开文字，使用无 Cookie／凭据存储的短期会话、请求超时和响应大小检查。
  窗口内呈现加载、正文、空说明或重试；开始下载安装包不会中断日志读取，关闭或新版本到来会废弃旧请求。
  正文只作为文本显示，不执行 HTML、不加载图片；按当前 App 语言选择发布文件的中英段落。
- 发布流程把同一份 `MACOS_RELEASE_NOTES.md` 同时用于 GitHub 发布正文和两个架构条目的内嵌说明。
  采用 Sparkle 已支持的 [description 字段](https://sparkle-project.org/documentation/publishing/)，转换标题／列表并转义正文，
  随更新源一起签名。因此旧客户端在下一次发布时也能读取内嵌日志，不需要先具备自动补取逻辑。
  没有修改已经公开的 1.0.8 安装包或已签名更新源。
- 挂载设置修正后台回调误继承主线程隔离的崩溃，使用现有异步回调桥接而非关闭隔离检查。
  依据为用户提供的必要崩溃栈与 [Swift 的回调迁移说明](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/)。
  已保存的权限不会因刷新通知失败而撤销；不改变任何 NAS 写入门禁。
- 界面沿用原生控件和现有窗口，`ui-ux-pro-max` 仅用于状态、重试与双语主题检查，不新增常驻说明小字。
  不改依赖、最低系统版本、Bundle ID、签名、权限、会话存储或更新密钥；其他平台实现不变。

### 已运行验证

- `swift test --package-path apple --jobs 4`：1062 项 XCTest，1005 通过、57 项条件跳过、0 失败，另 12 项 Swift Testing 通过。
  55 项合成界面需显式开启，另两项仍是既有元数据基准与真实 QuickConnect 条件检查；未降低原有断言。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：30 项通过；`bash -n tools/release/publish_macos_release.sh` 通过。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test更新弹窗内日志加载结果双语主题|WorkspacePresentationTests/test更新窗口双语主题各阶段不自动下载或重启|WorkspacePresentationTests/test挂载写回设置双语主题状态绘制' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-update-fix.phuhTt/ui`：
  三项测试通过，96 组绘制，包括 16 组日志加载状态、36 组更新流程和 44 组挂载设置；已检查中英文、浅深色及重试布局。
- `xcodebuild -quiet -jobs 4 -workspace apple/DsmNativeClient.xcworkspace -scheme DsmMac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/lanstash-update-fix.phuhTt/build CODE_SIGNING_ALLOWED=NO build`：
  完整未签名构建通过，主 App 和扩展均核对包含 arm64、x86_64；不代表正式签名或实机验收。
- 对 `https://api.github.com/repos/yuangy1995/dsm-native-client/releases/tags/macos%2Fv1.0.8` 做不附加认证参数的只读 GET，
  返回 200；核对标签、非草稿、非预发布及正文存在。该结果不替代 App 在所有网络环境中的实际请求验证。
- `python3 tools/localization/check_localization.py`：4018 个 Apple 资源键的双语、参数、引用和硬编码扫描通过。
- 开发验证阶段没有提交、推送、发布、安装或启动主 App；没有操作真实 NAS 文件，原始用户报告与截图保留在用户提供的位置。
- 最后独立复核了具体版本／稳定与验收通道匹配、晚返回请求隔离、文本展示及挂载回调线程边界，未修改签名或安装保护。
  `python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。
  本轮独立构建、日志、公开接口响应及合成截图已在核验后移入系统废纸篓，可恢复；项目已有测试和缓存保留。

`PENDING_USER_VALIDATION`：正式签名修复版中检查对应版本日志的获取、断网重试和语言显示，以及挂载开关确认后的持续运行。
当前已安装的 1.0.8 不会被源码修改直接替换；须发布并安装后再做系统集成验收。已有更新包签名、下载与安装确认机制保持不变。

## 范围与关键决策

- 仅发布 macOS；Android、Windows、iPhone、iPad 不参加本次发布流程。
- 发布标签为 `macos/vX.Y.Z`，版本与 `apple/Apps/DsmMac/project.yml` 的 `MARKETING_VERSION` 一致。主应用与 File Provider 的 `CURRENT_PROJECT_VERSION` 同步增加，必须高于上一公开版本。构建号不再取工作流运行次数，避免不同工作流之间比较错误。
- 从 1.0.3 起，每次正式发布必须同时提供 `LanStash-X.Y.Z-arm64.dmg`（Apple Silicon）与 `LanStash-X.Y.Z-x86_64.dmg`（Intel）；最低 macOS 14 不变。两个包的 App 与 File Provider 均检查实际单架构，不能只改附件名。
- 保留现有 Developer ID 签名、公证、File Provider 与共享钥匙串门禁；不沿用 QuotaLens 的临时签名分发。开发用临时签名流程继续存在，但不启用在线升级。
- Sparkle 固定为 2.9.6，只链接 macOS 应用，不链接共享领域库、网络库或移动端应用。SwiftPM 和 XcodeGen 使用同一个版本，工程由 XcodeGen 生成。
- 主应用继续保持沙盒，只增加 Sparkle Installer 必需的两个通信权限；不启用 Downloader 服务，因为主应用已具有联网权限。
- 更新源固定为本仓库 `macos-updates` 发布项的 `appcast.xml`，不使用跨平台的 `releases/latest`。更新包和更新源都必须进行 Ed25519 签名；包解压前验证，发布前使用应用内公钥独立验签。
- 同一更新源按固定顺序提供两个同版本／构建号条目：arm64 在前且带 `sparkle:hardwareRequirements=arm64`，Intel 在后作为匹配项。Sparkle 2.9.6 会过滤不满足硬件要求的条目，并在版本相同时选择首个匹配项；Rosetta 按实际 Apple Silicon 硬件判断。旧通用版本无需切换更新地址或密钥，安装确认机制不变。
- 自动检查默认开启，可在应用菜单关闭。禁止静默自动安装；安装重启前要求确认，取消安装不会遗留退出时自动安装。当前应用文件任务和文本编辑未结束时拒绝升级重启，并在系统退出请求时再次检查。
- Finder 扩展的在途任务、签名安装替换和共享钥匙串保留仍须真实签名环境验证，不能由单元测试替代。

## 发布配置

使用现有 GitHub Environment `macos-release`，保留已有证书、授权文件、公证 Secrets 及 Bundle ID、App Group、共享钥匙串 Variables，不改变这些身份。

需要新增：

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Variable | `SPARKLE_PUBLIC_ED_KEY` | 本项目独立更新公钥，随候选应用分发 |
| Secret | `SPARKLE_PRIVATE_ED_KEY` | 对安装包及更新源签名；不得提交或打印 |
| Variable | `MACOS_ONLINE_UPDATE_VALIDATED` | 完成下述真实签名升级验收后才设为 `true` |

密钥应由负责人使用 Sparkle `generate_keys --account` 创建本项目独立账户，备份并妥善保存私钥；不能复用 QuotaLens 的密钥，不能把私钥作为命令行参数，也不能放入仓库。新增公钥后必须用同一私钥签名，否则发布门禁拒绝发布。

Apple 发布身份配置保持不变。用户授权后，已为本项目生成独立升级密钥，保存在本机钥匙串的专用账户，并配置到 `macos-release` 的上述 Secret/Variable；私钥不进入源码。`MACOS_ONLINE_UPDATE_VALIDATED` 仍须等待真实升级验收，不能提前设为通过。

## 操作流程

1. 完成源码审查、Apple 测试、本地化检查和 macOS 构建。更新双目标版本、构建号及 `MACOS_RELEASE_NOTES.md`。
2. 首次接入须先完成签名候选包和升级验证。仅生成候选文件时，手动运行 `macOS Release`，`package_mode=release`、`enable_updates=true`、`publish_to_github=false`。进行真实在线升级验收时，分别准备递增的两个版本与构建号，使用 `macos-validation/vX.Y.Z` 标签，手动运行 `package_mode=release`、`publish_validation=true`、`publish_to_github=false`。这会发布明确标记的预发布验收包，候选应用只读取独立的 `macos-validation-updates` 更新源；正式应用不会读到它。验收包同样必须正式签名和公证。
3. 验证通过后设置 `MACOS_ONLINE_UPDATE_VALIDATED=true`。在获得提交与发布授权后，推送对应 `macos/vX.Y.Z` 标签。该标签不会触发 Android 或 Windows 发布。
4. 正式工作流分别在 `dist/arm64`、`dist/x86_64` 构建、签名、公证，验证版本、来源、身份和更新密钥一致后创建草稿。两份 DMG、签名更新源和 SHA-256 清单全部上传回读通过才公开版本，最后更新 `macos-updates`；任一架构失败不切换更新源。
5. `macos-updates` 是非最新版的预发布条目，仅作更新源；正式版本的安装附件不会被覆盖。若流程中途失败且版本已存在，停止自动重试，先核对草稿、安装包和更新源状态，不删除已公开产物。

历史未含 Sparkle 的应用需要手动安装一次升级版。在线更新仅替换客户端，不改变 NAS、套件或账号数据。

预测试签名模式保留通用包，且不得发布到正式更新源；正式候选与正式发布均强制双架构。修改架构顺序、Sparkle 版本或硬件条件时，必须重跑 `python3 -m unittest discover -s tools/release -p 'test_*.py'`，覆盖 Intel、Apple Silicon、Rosetta、旧通用源迁移、缺包、架构错误和来源不一致。

`PENDING_USER_VALIDATION`：在 Intel、原生 Apple Silicon 和 Rosetta 旧版分别检查更新并安装，预期得到对应原生包，保留已有配置及 Finder 挂载。自动化覆盖更新源规则和构建产物，不宣称三类设备实际升级均已验证；反馈仅提供设备架构、版本和脱敏错误。

## 回滚

- 尚未公开：关闭发布入口、保留版本草稿用于核对，不改写已发布版本。
- 更新源错误：恢复上一份已经签名的完整更新源；不要重新签署或直接编辑 XML 后上传。
- 应用缺陷：用更高版本号和构建号发布修复版；不降低版本或替换同版本附件。
- 移除升级能力：后续修复版移除入口、Sparkle 依赖和专用权限，恢复手动分发。NAS 配置与会话格式无需迁移。
- 丢失或轮换密钥须单独设计迁移，不能直接替换公钥；当前发布脚本会拒绝用不同密钥覆盖已有更新源。

## 用户验收与剩余验证范围

2026-09-07，用户明确确认“可以正常升级和挂载了”，并提供更新提示与 Finder 挂载截图。记录为用户报告的 0.2.7 → 0.2.8 在线升级及挂载主流程通过；不上传含真实目录内容的截图。结合两份候选包的正式签名、公证和完整云端门禁，可以进入正式发布流程。

1. 独立更新密钥、GitHub 锁定 Xcode 16.4 门禁、两份正式签名公证验收包及用户报告的在线升级/挂载主流程均已通过。
2. 验收用户需手动安装一次正式通道版本；两种通道不自动切换，避免把普通用户带入测试更新。清理验收更新源后，测试通道将不再提供更新。
3. `PENDING_USER_VALIDATION`：不同 Mac 架构和系统版本，以及中英文、浅深色、键盘、VoiceOver、大文字和降低动态效果的完整实机覆盖。用户未提供精确系统版本，不据此宣称两类架构均已实测。
4. `PENDING_USER_VALIDATION`：在途 Finder 传输、各类任务中断和完整凭据保留矩阵。已有任务重启阻止与回调单次执行自动化证据，但用户本次主流程确认不替代全部异常场景验证。
5. `PENDING_USER_VALIDATION`：断网、安装权限不足及安装失败恢复的实机覆盖；错误签名/篡改、取消与未完成工作阻止已具备自动化回归。

请仅回传脱敏的系统版本、应用版本/构建号、操作步骤、预期与实际结果；不得回传 NAS 地址、真实路径、会话、私钥或原始响应。

## 本地验证记录（2026-09-07）

- `swift test --package-path apple --jobs 4`：783 项 XCTest，0 失败、2 项沿用既有条件跳过（大目录性能基准、真实 QuickConnect）；另 11 项 Swift Testing 通过。包含 7 项新增升级回归。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：15 项通过，含正式/验收通道隔离、工作流入口门禁、版本回退、更新包公钥验签、篡改失败及实际二进制架构校验测试。
- `python3 tools/localization/check_localization.py`：通过，包含双语、参数、引用与硬编码扫描。
- `xcodegen generate --spec apple/Apps/DsmMac/project.yml`：使用与 CI 一致的锁定版本 2.46.0 生成工程；本机默认 2.45.4 不可替代，以免生成目标顺序不一致。
- `xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/lanstash-updater-build CODE_SIGNING_ALLOWED=NO -jobs 4 build`：arm64、x86_64 构建成功；这是无正式签名的本地构建，不代表分发验收。
- 本机 Xcode 26.6 曾在新代码闭包的 IR 生成阶段崩溃，显式标注主线程闭包并避免方法引用转换后正常编译；未改变项目或 CI 工具链。
- 独立复核发现 macOS Bash 3.2 对失败的 `[[ ... ]]` 不会可靠执行 `errexit`，新发布与更新校验均显式退出，入口回归实际在 `/bin/bash` 执行。另修正空数组在 `set -u` 下失败、安装取消遗留退出安装和错误提示不准确的问题。
- 升级窗口使用原生按钮并提供清晰取消路径，可调整大小并滚动，不加入新的 UI 框架。实际屏幕阅读器和不同文字尺寸仍待人工验收。
- 用户已授权使用专用分支 `codex/macos-release-updater` 完成云端验证与签名升级验收；全部通过后整理为单一功能提交，再合入主分支正式发布。成功后删除本任务测试分支、验收标签/发布及对应临时产物，保留正式发布和正式更新源。实际云端与升级验收结果将在完成后补录，不能用本地构建替代。

## 云端验证进度（2026-09-07）

- 仓库实际位置已核实为 `yuangy1995/dsm-native-client`，新发布逻辑和更新地址已同步；应用 Bundle ID、权限身份及 Apple 证书未随仓库账号迁移改变。
- `49f5d35` 的 Apple、Android、Windows、仓库、社区兼容性与文档 CI 均通过。
- [首次签名验收运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/34091563990)：通用构建、正式签名、Apple 公证 Accepted、票据装订及 App/扩展签名验证已通过；随后因新增 `lipo` 校验参数顺序错误而失败，未发布安装包。修正后新增实际系统二进制的成功/失败回归，不删除架构门禁。
- 验收版 0.2.7（8）和 0.2.8（9）的在线升级与挂载已收到用户通过确认；这与最终正式 Release 发布结果分开记录。
- [0.2.7 签名验收运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/34092398095) 完整成功：构建、正式签名、公证装订、架构/权限门禁、更新包与更新源签名、GitHub 上传回读校验及预发布创建均通过。[验收安装包](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos-validation/v0.2.7) 已可下载；这不是实际应用替换与 NAS/Finder 验收结果。
- [0.2.8 升级目标运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/34092508014) 完整成功，正式签名、公证、更新签名、发布回读校验和测试更新源切换均已通过。同一验收标签的 Apple、Android、Windows、仓库、文档与社区兼容性 CI 均成功。
- 用户已确认在线升级和挂载正常，并要求主分支只保留单一功能提交，不携带中间修复记录。合并前核对主分支无未整合变化，正式发布成功后删除本任务验收分支/标签/发布附件；正式版本及正式更新源必须保留。


## 2026-09-29 macOS 1.0.11 发布基线

用户明确要求“截止到当前，先帮我发布一个新版本，再继续”。发布截至人物命名/合并波次已经实现的下载与个人照片管理，版本1.0.11、构建号21，两个目标同步。未完成的分享有效期仅有只读证据，无功能代码，不纳入本次功能声明；剩余完整网页复刻发布后继续。发布授权涵盖对应功能提交、专用发布分支、验证后整合与正式标签/版本，不修改签名身份、权限、更新密钥或存储格式。

开始时 main@9c30efeab8fb 与 origin/main 一致，已有未提交改动均为本会话下载/照片范围；先切至 codex/macos-1.0.11-release 保留所有内容。暂未发布；实际云端结果后续追加。本轮此前本地照片测试146项、6项本地化、2项界面回归与临时签名构建通过；这些不代替正式签名、公证和完整云端门禁。

### 1.0.11 发布前本地验证

- `swift test --package-path apple --skip-update --jobs 4`：1401项 XCTest、64项既有条件跳过、0失败，另12项 Swift Testing通过。62项界面测试需显式启用，另2项为既有环境/性能条件；未降低断言。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：30项通过。
- `python3 tools/localization/check_localization.py`：Apple4342、Android2188、Windows3402，双语/参数/引用/硬编码通过；`python3 tools/contract-validation/validate_fixtures.py`：3组、31项引用通过；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。
- 按官方归档及既定SHA256校验下载XcodeGen2.46.0，执行 `xcodegen generate --spec apple/Apps/DsmMac/project.yml` 更新工程；工具临时目录自动删除。主App/扩展均1.0.11 (21)。待发布文件隐私模式检查未命中凭据/私网地址。未自动安装或启动，不进行NAS写入。

- 显式界面回归：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片|WorkspacePresentationTests/test分享窗口|WorkspacePresentationTests/test条件相册|WorkspacePresentationTests/test人物' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-release-1011-ui`：10项通过。上传/下载补充4项中3项通过，旧选择测试4个断言失败；定位为新增分类List导致取到首个侧栏表格、关闭详情重建任务表后仍检查旧实例。改为识别多列任务表并在清空后重新取得当前实例，保留选中/失焦/清空的全部断言。`WorkspacePresentationTests/test下载与虚拟机选中行使用低饱和主题色并保留原生选择`复测1项通过；应用代码未因此改变。
- 发布分支只保留单一功能提交，测试定位修正合入同一提交；重新验证最终提交，不用旧SHA的状态替代。

- Windows附加回归首次3929项中3928通过、1项失败：跨端源码契约测试仍匹配macOS旧单参数删除签名，而本轮已增加确认时任务集合。同步该测试到新签名，并新增确认对象捕获、当前选择/列表一致性断言；不改Windows产品代码，不撤销macOS确认快照保护。修正后以最终发布分支重新执行云端门禁。

- 云端锁定Xcode16.4发现两处新上传测试使用`weak let`，本机较新编译器接受但云端拒绝。改为兼容的`weak var`，仍核对同一授权对象的保留与释放，不改应用行为或升级工具链。

### 1.0.11 工具链升级授权

用户在发布期间明确要求升级云端较旧Xcode。已核对本机为Xcode26.6 (17F113)，GitHub官方macos-26镜像提供相同版本，macos-15最多26.3。Apple Build、macOS Release与iOS Release统一迁移macos-26并锁定26.6/17F113，保留XcodeGen2.46.0、macOS14最低要求、现有签名/权限/更新密钥；移动模拟器沿用动态选择。工具链变更需最终提交重新跑云端验证，不沿用旧工具链结果声称新工具链通过。本轮不发布iOS。必要时回滚三个工作流到macos-15/Xcode16.4 (16F6)并重新验证；无用户数据迁移。

### 1.0.11 正式发布结果（2026-09-29）

- 最终单一提交 `5684170b3ccfab327ed2a9062ad3aac20f95ba71` 的六项云端门禁全部通过：Apple Build `36522282536`、Android Build `36522291829`、Windows Build `36522282499`、Repository Check `36522282403`、Documentation & Quality Preflight `36522282547`、Community Compatibility `36522297331`。Apple 使用锁定的 Xcode26.6 (17F113)，共享测试、iPhone/iPad 模拟器回归、macOS 打包与产物校验均通过。
- 重新获取主分支后确认仍为 `9c30efeab8fb`，将上述单一提交快进合入并推送 main；正式标签 `macos/v1.0.11` 指向相同提交，未改写已发布历史。发布成功后已删除本次远端和本地临时分支。
- [正式发布运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/36523391845) 完整成功：两个架构构建、Developer ID 签名、Apple 公证/装订、App与扩展校验、更新签名、上传回读和正式更新源更新通过。[macOS1.0.11](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.11) 于北京时间13:07:55公开，非草稿、非预发布，构建号21。
- 公开附件：`LanStash-1.0.11-arm64.dmg`（22285016字节）、`LanStash-1.0.11-x86_64.dmg`（23989612字节）、`appcast.xml`、`SHA256SUMS.txt`。发布后再次读取公开版本附件与 `macos-updates/appcast.xml`，两份更新源逐字节相同、SHA256匹配；两个条目均1.0.11/21，arm64在前并带硬件条件，Intel条目在后，安装包签名字段存在。实际签名验真与安装包回读校验由已成功的正式发布流程完成。
- 本轮临时日志和合成截图已清理，正式源码、测试、脱敏文档与此前独立测试包保留。未自动安装/启动应用，未对真实NAS执行分享、人物合并或收集请求写入；iOS仅更新构建配置，没有发布。
- `PENDING_USER_VALIDATION`：用户在实际Mac上升级至1.0.11，检查下载详情关闭、BT搜索布局、2020.03等月份定位后批量删除及位置保持，并验收新增个人照片管理。不同架构的安装后系统集成、Finder挂载与真实NAS写入仍不能由云端成功替代。剩余网页功能按照片对齐账本继续，本次发布不宣称完整复刻完成。


### 1.0.11 后续原尺寸JPEG本地测试包（2026-09-30）

本次未发布正式版本或更新订阅源。独立本机临时签名包位于 `apple/Apps/DsmMac/dist/photos-original-jpeg-20260930/LanStash-1.0.11-arm64.dmg`，1.0.11(21)、arm64约19MB；包含原尺寸JPEG和此前照片累计改动，不含Finder挂载扩展，未自动安装/启动。460项XCTest加6项本地化测试、2项28场景UI检查、资源/契约/文档检查，以及Release、签名、权限、Sparkle实际加载、架构、DMG校验通过。真实NAS转换和物理交互仍PENDING_USER_VALIDATION。实际命令、权限语义、剩余工作及验证限制见[照片对齐账本](../development/MACOS_PHOTOS_PARITY_20260929_ZH.md#原尺寸jpeg独立测试包交付2026-09-30)。


### 1.0.11 后续文件夹封面本地测试包（2026-09-30）

未发布新正式版本或修改更新源。独立临时签名包 `apple/Apps/DsmMac/dist/photos-folder-cover-20260930/LanStash-1.0.11-arm64.dmg`，1.0.11(21)、arm64约19MB；新增文件夹默认/自定义封面、子目录选图及保存自动核对，保留原图库位置，包含此前照片累计改动。468项XCTest、6项本地化及2项32场景UI检查通过；资源/契约/文档检查、Release、签名、测试权限、Sparkle实际加载、架构和DMG校验通过。未安装启动，不含Finder挂载扩展；真实NAS待用户验收，剩余排序控件与上传重启恢复见[照片对齐账本](../development/MACOS_PHOTOS_PARITY_20260929_ZH.md#文件夹封面独立测试包交付2026-09-30)。


### 1.0.11 后续文件夹排序本地测试包（2026-09-30）

本轮无正式发布或更新源修改。独立本机临时签名包 `apple/Apps/DsmMac/dist/photos-folder-sort-20260930/LanStash-1.0.11-arm64.dmg`，1.0.11(21)、arm64约19MB，包含封面选图四字段/双向排序、NAS保存回读及逐页排序，同目录图库同步排列；含此前照片改动，不含Finder挂载扩展，未安装或启动。476项XCTest与6项本地化、3项36场景UI检查、资源/契约/文档检查以及Release/签名/权限/Sparkle实际加载/架构/DMG通过。真实NAS待用户验收；完整审计发现目录管理仍有遗漏，剩余与命令证据见[照片对齐账本](../development/MACOS_PHOTOS_PARITY_20260929_ZH.md#文件夹排序独立测试包交付2026-09-30)。


### 文件夹重命名独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-rename-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-rename-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-rename-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器仅复用apple/.build依赖缓存并跳过更新，不修改工具链。Release、arm64、Hardened Runtime专用测试权限、签名、Sparkle实际library loaded检查通过；独立codesign --verify --deep --strict、file及hdiutil verify（VALID）通过。只有既有hdiutil弃用提示，最终UI验证后产品源码未修改。

产物 `apple/Apps/DsmMac/dist/photos-folder-rename-20260930/LanStash-1.0.11-arm64.dmg`（19,658,863字节，约19MB），1.0.11(21)、本机临时签名，不包含Finder本地磁盘挂载扩展；含本轮重命名/主页面排序与此前照片累计实现。未安装、启动、覆盖旧包、正式发布或更改更新源。main@5684170b3ccf与34个累计修改/未跟踪文件保留，未提交推送。一次性日志、合成截图、临时启动器和本轮专用构建目录在进程结束后移入废纸篓，保留dist、依赖缓存和正式测试源码。

当前切片完成，但完整网页对齐仍进行中。下一切片为文件夹删除，随后目录移动/复制、共享目录权限/分享；上传跨会话恢复继续等待此前单独的存储授权。真实NAS写入和物理触控板验收由用户完成，未代测或宣称实机通过。


### 文件夹混合删除独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-folder-delete-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-delete-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-delete-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。启动器仅复用apple/.build依赖缓存并skipPackageUpdates，不改工具链。Release、打包脚本签名/Designated Requirement、Hardened Runtime测试权限、Sparkle实际library loaded、arm64和hdiutil verify（VALID）通过；另以file核对产物arm64。只有既有hdiutil弃用提示。UI最终验证后产品源码未再修改，随后2项新增单测及合成服务状态补充通过完整497项回归。

产物 `apple/Apps/DsmMac/dist/photos-folder-delete-20260930/LanStash-1.0.11-arm64.dmg`，19,731,645字节（约19MB），版本1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展；包含本轮多文件夹/照片混合删除及此前累计功能。未安装、启动、覆盖旧包、正式发布或修改更新源。main@5684170b3ccf与34个累计修改/未跟踪文件保留，未提交推送。临时日志、合成截图、启动器及本轮构建目录在进程结束后移入废纸篓；保留正式测试源码、全部dist和依赖缓存。

本轮切片已完成，完整网页对齐仍继续。剩余已确认代码缺口：目录移动复制、共享目录权限分享、多目录/照片目录混选整批下载；上传队列跨会话恢复仍等待此前存储授权。下一切片继续目录移动复制，不能因可用构建或现有单目录ZIP而宣称整个Photos功能已对齐。真实NAS删除与恢复由用户验收，本轮未执行任何NAS写操作。


### 文件夹移动复制独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-folder-transfer-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-transfer-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-transfer-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。启动器只复用apple/.build依赖缓存并skipPackageUpdates，不改变工具链。Release、签名/Designated Requirement、Hardened Runtime测试权限、Sparkle实际library loaded、arm64及hdiutil verify（VALID）通过；最终产物为LanStash Test.app，另以file检查其实际主程序。只有既有hdiutil弃用提示。

产物 `apple/Apps/DsmMac/dist/photos-folder-transfer-20260930/LanStash-1.0.11-arm64.dmg`，19,761,979字节，1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展。508项XCTest、6项本地化与3项36场景通过，标题调整后移动复制16场景又通过；详情与真实命令见本轮账本。不自动安装或启动、不覆盖旧包、不改更新源、不正式发布。main@5684170b3ccf和34个累计工作区文件保留，未提交/推送。临时日志、合成截图、启动器、本轮构建目录在进程结束后移入废纸篓，保留dist与依赖缓存。真实NAS写入仍由用户验收。


### 共享目录权限读取独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-folder-permissions-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-permissions-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-permissions-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器只复用apple/.build缓存并skipPackageUpdates，不修改工具链。Release、签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64和DMG VALID检查通过；另以file确认LanStash Test.app/Contents/MacOS/LanStash为arm64。仅既有hdiutil弃用提示。

产物 `apple/Apps/DsmMac/dist/photos-folder-permissions-20260930/LanStash-1.0.11-arm64.dmg`，19,820,085字节，1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展。包含此前累计照片功能及本轮共享目录权限查看；保存/成员调整/密码修改/子目录应用尚未实现，不是人工禁用。513项XCTest、6项本地化、1项20个界面场景通过，实际命令和初次失败修复见对齐账本。不自动安装/启动、不覆盖旧包、不改更新源、不正式发布。main@5684170b3ccf和34个累计文件保留，未提交推送。

所有本轮进程结束后，临时测试日志、合成截图、启动器及本轮独立构建目录移入唯一废纸篓目录；保留dist、正式测试与依赖缓存。Chrome控制台已清空并关闭，没有保存原始脚本、HAR或真实NAS响应。完整对齐继续，下一切片为权限保存；后续仍有多目录/混合下载、拖放/重复项设置以及待存储授权的上传重启恢复。真实NAS与物理触控板验收由用户执行。


### 共享目录权限保存独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-permission-save-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-permission-save-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-permission-save-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。启动器只复用apple/.build依赖缓存并skipPackageUpdates，不改变工具链。Release、签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64及hdiutil verify（VALID）均通过，另以file确认主程序架构。仅既有hdiutil弃用提示。

产物 `apple/Apps/DsmMac/dist/photos-permission-save-20260930/LanStash-1.0.11-arm64.dmg`，19,956,616字节，1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展。包含本轮共享目录权限编辑、成员/密码/子目录选项、确认保存和自动核对，以及此前累计照片改动。524项XCTest、6项本地化、2项36界面场景通过，另有12确认快照；真实命令、失败修复和离屏绘制限制见对齐账本。不自动安装/启动、不覆盖旧包、不改更新源、不正式发布。main@5684170b3ccf与34个累计工作区文件保留，未提交推送。

本轮进程结束后，临时日志、合成截图、启动器及独立构建目录移入唯一废纸篓目录，保留dist、依赖缓存和正式测试。Chrome控制台已清空关闭；没有原始HAR或真实NAS响应落盘，没有执行真实NAS写入。权限保存源码切片完成，NAS成员真实访问/密码/后代应用为PENDING_USER_VALIDATION，完整功能对齐仍进行中。当前归档目标源码仍只有album(id)与folder(id,space)，下一切片多目录/照片混选下载；拖放/重复项设置及待持久化授权的上传重启恢复仍未完成。


### 2026-09-30 照片混选下载本地测试包（非正式发布）

产物`apple/Apps/DsmMac/dist/photos-mixed-download-20260930/LanStash-1.0.11-arm64.dmg`，19,969,162字节，1.0.11(21)，arm64。包括多个同级文件夹、照片与文件夹混选ZIP下载，原件/压缩JPEG、取消失败保留本地旧文件和图库位置。530项XCTest、6项本地化及3项合成UI测试（44场景）通过；Release、临时签名、Designated Requirement、Hardened Runtime及Sparkle实际加载、DMG完整性检查通过。未自动安装或启动，未覆盖先前测试包；临时签名不包含本地磁盘挂载扩展。真实NAS下载与权限组合由用户验收；无git提交、推送或正式发布。证据与剩余事项见MACOS_PHOTOS_PARITY_20260929_ZH.md。


### 2026-09-30 照片文件夹拖放移动测试包（非正式发布）

`apple/Apps/DsmMac/dist/photos-drag-move-20260930/LanStash-1.0.11-arm64.dmg`，20,018,786字节，1.0.11(21)，arm64，本机临时签名。文件夹页支持照片/目录单项与混选拖放到可见目录、上级按钮及路径导航，预选固定目标后确认，复用原有移动任务和结果核对。535 XCTest、6本地化、3合成UI测试（48场景）通过，Release、签名、Hardened Runtime、Sparkle实际加载和DMG校验通过。未安装/启动/正式发布，临时包无本地磁盘挂载扩展；真实NAS和物理拖放待用户验收。重复项设置/策略及上传重启恢复仍未完成。


### 重复项处理最终测试包

实际执行 `PATH="/tmp/dsm-photos-duplicates-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-duplicate-settings-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-duplicate-settings-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时包装仅指定现有apple/.build依赖缓存与skipPackageUpdates，没有升级工具链或依赖。

产物`apple/Apps/DsmMac/dist/photos-duplicate-settings-20260930/LanStash-1.0.11-arm64.dmg`，20,135,178字节，1.0.11(21)，arm64。包含此前累计照片功能与本轮重复项默认设置、ignore/rename上传、skip/overwrite移动复制；无人工未验证禁用。Release、签名/Designated Requirement、专用本地测试Hardened Runtime权限、Sparkle实际library loaded与DMG VALID检查通过；额外plist/字节数/主程序file检查确认版本和arm64，PlugIns为空。只有既有hdiutil弃用提示。

未自动安装或启动，不覆盖旧包、不改更新源、不执行正式发布；本机临时签名不包含Finder本地磁盘挂载扩展。544项XCTest、6项本地化和5项合成UI测试的最终通过结果与限制见上述记录。真实NAS写行为、物理手势仍待用户验收，未提升版本兼容等级。全部34个累计工作区改动保留，未git add/提交/推送。整体目标继续，剩余上传队列跨重启恢复需要此前待确认的本地持久化授权。


### 2026-09-30 相册内照片排序独立测试包

实际执行 `PATH="/tmp/dsm-photos-album-sort-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-album-sort-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-album-sort-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器仅指定现有apple/.build依赖缓存与skipPackageUpdates，未升级工具链或依赖。Release、实际arm64、临时签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际`library loaded`与DMG校验VALID通过；仅既有hdiutil弃用提示。额外检查成品含photos.albumSort标识。

产物`apple/Apps/DsmMac/dist/photos-album-sort-20260930/LanStash-1.0.11-arm64.dmg`，20,169,527字节，1.0.11(21)，本机临时签名，沿既有独立localtest应用标识。没有自动安装/启动，不覆盖旧包，无本地磁盘挂载扩展（PlugIns=0）。含本轮相册内照片排序、保持当前排序的上传/搬移后刷新，以及此前累计照片与捏合缩放改动。552项XCTest、6项本地化、2项原生合成UI测试通过（16张截图）；详细命令与首次失败修复见对齐账本。NAS真实排序/权限/断网及物理触控板仍由用户验收，不冒充行为验证。

main@5684170b3ccf及34个累计工作区文件保留，没有git add、提交、推送或正式发布。完整对齐目标继续：相册列表显示/排序和分享列表独立排序仍待实施；上传重启恢复仍待之前本地存储方案授权。前轮“只剩上传恢复”的结论已由本轮官方静态再审计纠正。没有真实NAS写入、下载或用户数据导出。

本轮所有测试/构建进程结束后，6项临时日志、合成截图目录、启动器和独立构建目录移入唯一废纸篓目录；保留dist成品、正式测试和依赖缓存。控制台已清空并关闭，无原始脚本/HAR/真实NAS响应留存。


### 2026-09-30 相册列表与分享排序独立测试包

实际执行 `PATH="/tmp/dsm-photos-list-sort-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-list-sort-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-list-sort-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时包装仅指定既有apple/.build依赖缓存与skipPackageUpdates，无依赖或工具链升级。Release、临时签名及Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded、arm64与DMG checksum VALID通过；额外检查成品含photos.albumList.sort。仅既有hdiutil弃用提示。

产物`apple/Apps/DsmMac/dist/photos-list-sort-20260930/LanStash-1.0.11-arm64.dmg`，20,226,522字节，1.0.11(21)，沿既有localtest标识的本机临时签名，不含本地磁盘挂载扩展（PlugIns=0）。含全部/我的相册范围、相册列表5字段及两类分享列表4字段/双向、三个独立偏好保存/回读、固定分页与迟到响应保护，以及此前累计照片改动。560项XCTest、6项本地化、2项原生UI测试（28张合成截图）通过，截图限制见对齐账本。实际NAS偏好及权限由用户验收，未提升版本证据等级。

不自动安装/启动、不覆盖旧包、不改更新源、不正式发布；main@5684170b3ccf、34项累计工作区文件保留，没有git add/提交/推送。完整目标继续：网页预览旋转保存已补证为下一代码缺口，上传跨重启恢复仍待先前持久化方案授权；不因本轮通过就宣称完整对齐。没有执行真实NAS写入/下载或导出用户数据。

所有本轮执行进程结束后，6项临时日志/合成截图目录/启动器/独立构建目录移入唯一废纸篓目录。保留dist成品、正式测试和依赖缓存。浏览器控制台已清空并关闭，无原始脚本、HAR、NAS响应或真实用户资料留存。


### 2026-09-30 旋转保存独立测试包交付

最终实际执行 `PATH="/tmp/dsm-photos-rotation-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-rotation-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-rotation-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。先前因修正重复提示主动终止一次未完成构建，未交付中间包；本次产物含最终界面修正。临时启动器仅复用apple/.build依赖缓存，无工具链/依赖变更。

产物`apple/Apps/DsmMac/dist/photos-rotation-20260930/LanStash-1.0.11-arm64.dmg`，20,276,556字节，1.0.11(21)，沿既有localtest标识与本机临时签名。Release、严格签名和Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64与DMG checksum VALID通过，二进制含photos.media.rotate。无本地磁盘挂载扩展（PlugIns=0），没有安装、启动、正式发布或覆盖旧包。仅hdiutil弃用提示。

567项XCTest、6项本地化、最终1项UI测试及8张合成截图通过；最后UI测试发生在统一状态栏修正之后。本轮实际NAS操作为零，静态证据未升级为行为验证，具体用户验收见照片对齐账本。保留main@5684170b3ccf及34项累计工作区文件，没有git add/提交/推送。目标继续：上传跨重启恢复待已说明的持久化授权，全量官方功能审计未结束。

全部执行进程结束后，6项临时日志/截图目录/启动器/独立构建目录移入唯一废纸篓目录；保留dist成品、正式测试及依赖缓存。Chrome控制台已清空并关闭，未落盘原始脚本或真实NAS资料。


### 2026-09-30 主题显示管理独立测试包

`apple/Apps/DsmMac/dist/photos-concepts-20260930/LanStash-1.0.11-arm64.dmg`，20,298,719字节，1.0.11(21)，沿既有localtest标识、本机临时签名、PlugIns=0。包含个人/共享主题批量显示隐藏、隐藏项搜索恢复与封面，以及此前双指缩放和累计照片改动。既有package.sh的Release arm64、严格签名、Hardened Runtime测试权限、Sparkle实际加载及DMG校验通过；详细实际命令与失败修复见Photos对齐账本。574项XCTest、6项本地化、2项UI测试/17张合成截图通过，真实NAS与物理触控板仍待用户验收。

未自动安装或启动、未覆盖旧包、未改变版本或正式发布。main@5684170b3ccf及34项累计工作区文件保留，未git add/提交/推送。剩余代码为主题封面/误分类移除及照片设置等，不能声明完整对齐；上传跨重启恢复仍待既有持久化方案授权。


### 2026-09-30 主题封面与误分类移除独立测试包

实际命令 `PATH="/tmp/dsm-photos-concept-management-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-concept-management-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-concept-management-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器仅指定既有apple/.build依赖缓存与skipPackageUpdates，无工具链或依赖变更。

成品`apple/Apps/DsmMac/dist/photos-concept-management-20260930/LanStash-1.0.11-arm64.dmg`，20,350,835字节，1.0.11(21)，沿既有localtest标识。Release arm64、严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded及DMG checksum VALID通过；额外检查二进制含photos.concepts.cover，PlugIns=0。只有既有hdiutil弃用提示。没有自动安装/启动、覆盖旧包或正式发布，本机临时签名不含本地磁盘挂载扩展。

582项XCTest、6项本地化、2项原生UI测试/28张合成截图通过；本轮源码包含主题封面及误分类移除、双语表单与自动局部回读，继续保留此前捏合缩放等累计改动。真实NAS写入/下载为零，静态和合成证据不代替真实设备行为。main@5684170b3ccf、34项累计工作区文件保留，没有git add/提交/推送。完整目标继续，下一切片为照片显示与识别设置；共享管理与缓存管理仍待完成，上传跨重启恢复仍待既有存储方案授权。


### 2026-09-30 照片显示设置独立测试包

实际命令`PATH="/tmp/dsm-photos-display-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-display-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-display-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器仅使用现有apple/.build依赖缓存与skipPackageUpdates，无依赖或工具链升级。

成品`apple/Apps/DsmMac/dist/photos-display-20260930/LanStash-1.0.11-arm64.dmg`，20,417,000字节，1.0.11(21)，沿既有独立localtest标识。Release arm64、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded及DMG checksum VALID通过；额外检查二进制含photos.display.title，PlugIns=0。只有既有hdiutil弃用提示。没有自动安装/启动、覆盖旧包或正式发布；本机临时签名不含本地磁盘挂载扩展。

含本轮六项显示设置和此前累计照片改动，587项XCTest、6项本地化、2项UI/28张合成截图通过，命令与限制见照片对齐账本。真实NAS写入/下载为零，static不升级为行为验证。main@5684170b3ccf及34项累计文件保留，没有git add/提交/推送；完整对齐继续，剩余个人识别/自动预览、共享管理及缓存设置，上传跨重启恢复仍待此前存储方案授权。


### 2026-09-30 个人照片识别独立测试包

实际命令 `PATH="/tmp/dsm-photos-recognition-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-recognition-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-recognition-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。临时启动器仅指定既有apple/.build依赖缓存和skipPackageUpdates，无依赖或工具链变更。

成品 `apple/Apps/DsmMac/dist/photos-recognition-20260930/LanStash-1.0.11-arm64.dmg`，20,510,902字节，1.0.11(21)，沿既有localtest标识。Release arm64、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded和DMG checksum VALID通过；额外检查主程序包含photos.recognition.title，PlugIns=0。打包仅有既有hdiutil弃用提示；测试命令另有skip-update弃用提示。未自动安装/启动，未覆盖旧包或正式发布；临时签名不含本地磁盘挂载扩展。

593项XCTest、6项本地化及1项原生UI/24张合成截图通过，本地化完整性/硬编码扫描、3组fixture/36项引用、严格文档预检和git diff --check通过。实际命令、关键决策及PENDING_USER_VALIDATION步骤见照片对齐账本与photos-recognition-settings端点。真实NAS写入/下载为零，静态和合成证据不代替行为验证。

main@5684170b3ccf和34项累计工作区文件保留，没有git add/提交/推送。完整对齐继续，下一切片为自动生成预览完整流程；共享管理/全局设置、转换缓存仍未完成，上传跨重启恢复待此前持久化方案授权。

全部本轮测试和构建进程结束后，6项临时日志、合成截图目录、临时启动器与独立构建目录已移入唯一废纸篓目录；保留dist成品、正式自动化测试和依赖缓存。Chrome控制台此前已清空关闭，无原始网页资源或真实NAS数据落盘。


### 2026-09-30 自动预览独立测试包（非正式发布）

实际命令 `PATH="/tmp/dsm-photos-automatic-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-automatic-previews-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-automatic-previews-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。临时启动器仅使用现有apple/.build依赖缓存及skipPackageUpdates；没有依赖/工具链变更，也未覆盖既有测试包。

成品 `apple/Apps/DsmMac/dist/photos-automatic-previews-20260930/LanStash-1.0.11-arm64.dmg`，20,671,362字节，1.0.11(21)，沿既有localtest标识。包含之前累计照片功能及本轮自动设置/后台扫描/暂停继续/结果核对。Release arm64、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist确认localtest，PlugIns=0，主程序含photos.automatic.title。本机临时签名不提供本地磁盘挂载，未自动安装/启动、未正式发布。打包只有现有hdiutil弃用提示。

623项XCTest、6项本地化及1项原生UI/24张合成截图通过；本地化硬编码/资源、3组fixture/37项引用、严格文档和diff检查通过。真实NAS读取/写入未由Agent验证，入口无待实测白名单；按照片账本PENDING_USER_VALIDATION验收。仍缺共享普通entry目录可见触发、批次外/相邻/实况完整优先等内容，不把此包当成完整网页复刻完成。


### 2026-09-30 可见照片优先独立测试包

`apple/Apps/DsmMac/dist/photos-visible-previews-20260930/LanStash-1.0.11-arm64.dmg`，1.0.11(21)，20,678,166字节，独立localtest/Release arm64。包含累计照片功能及本轮实际80%可见比例、多位置独立注销、同批当前/相邻/可见任务优先；原件与图库月份不变。627项XCTest及6项本地化通过，双语/硬编码与严格文档检查通过。实际打包命令及可复现验证见Photos对齐账本本轮记录。

临时签名、Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际加载、DMG校验均通过；额外严格codesign退出0，PlugIns=0。未自动安装/启动、未覆盖旧包、未正式发布，本机临时签名不提供本地磁盘挂载。真实NAS与物理手势为PENDING_USER_VALIDATION；新静态发现的相邻视频排除/实况单元与2秒唤醒等仍待后续，不能把该包表述为全功能网页复刻完成。


### 2026-09-30 可见来源与实况自动预览测试包

`apple/Apps/DsmMac/dist/photos-visible-sources-20260930/LanStash-1.0.11-arm64.dmg`，20,733,190字节，1.0.11(21)，Release arm64/localtest。包含本轮共享entry可见目录、批次外照片、实况单元、2秒触发、相邻视频排除和跨来源语义去重，以及之前累计功能。637项相关XCTest和6项本地化通过，最终去重修正后182项Model回归通过；本地化/硬编码、fixture引用、严格文档及diff通过。实际完整打包命令见macOS Photos账本同日记录。

最终源码完整重构建，临时签名与Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际加载、arm64及DMG校验通过。PlugIns=0，不含本地磁盘挂载；没有自动安装/启动、正式发布或覆盖旧交付包。真实NAS和物理手势仍由用户验证，未增加人工白名单。尚有共享管理设置、转换缓存、待授权上传队列持久化及最终审计，不能称整体功能全部完成。


### 1.0.11 后续共享空间设置本地测试包（2026-09-30）

新增共享空间启停、共享识别和顶层公开分享设置，保存自动核对并保留个人历史月份；实际命令和失败修正见[照片对齐账本](../development/MACOS_PHOTOS_PARITY_20260929_ZH.md)。独立包`apple/Apps/DsmMac/dist/photos-shared-settings-20260930/LanStash-1.0.11-arm64.dmg`，20,879,215字节、1.0.11(21)、arm64/localtest。646项完整XCTest+6项本地化、最后49项共享聚焦、1项UI/32张合成截图、资源/契约/文档和Release/签名/Sparkle实际加载/DMG校验通过。没有新正式发布、安装启动或覆盖旧包；临时签名不含本地磁盘挂载，NAS操作由用户验收。全局/共享成员权限/缓存/整库重索引等剩余工作保持。


### 2026-09-30 本地全局设置测试包（非正式发布）

`apple/Apps/DsmMac/dist/photos-global-settings-20260930/LanStash-1.0.11-arm64.dmg`，1.0.11(21)、21,122,652字节，arm64、本机临时签名。新增Photos管理员全局识别/分享/访客信息/格式排除/JPEG与转换缓存管理，保留此前累计功能；660项XCTest、6项本地化、1项原生UI/40张合成截图、Release、严格签名、Sparkle实际加载与DMG校验通过。沿既有localtest，不含本地磁盘挂载扩展，未自动安装启动、未覆盖旧包、未正式发布或提交推送。真实NAS由用户验收；共享成员/整库维护及最终对齐审计尚未完成。证据与实际命令见macOS照片对齐账本最新波次。


### 2026-09-30 共享成员原生管理测试包（非正式发布）

`apple/Apps/DsmMac/dist/photos-shared-members-20260930/LanStash-1.0.11-arm64.dmg`，21,454,162字节，1.0.11(21)、arm64、localtest、本机临时签名。包含成员增删/角色/自动备份与两层目录权限原生草稿、最终确认、后台自动核对和本人实际权限更新；个人月份保留，撤权丢弃在途旧分页。692项XCTest、6项本地化、2项原生UI/52张合成截图、Release构建、严格签名、Sparkle实际加载和DMG校验通过。无本地磁盘挂载扩展；未安装启动、未正式发布、旧包保留。真实NAS由用户验收，当前源码/剩余范围和实际命令见照片对齐账本。


### 2026-09-30 默认排序确认测试包（非正式发布）

`apple/Apps/DsmMac/dist/photos-sort-confirm-20260930/LanStash-1.0.11-arm64.dmg`，21,503,209字节，1.0.11(21)、arm64、localtest。包含此前照片累计改动与共享成员原生管理，新增排序字段/方向变更确认，取消保留草稿，普通显示设置不额外确认。4项相关XCTest、6项本地化、2项原生UI/20张合成截图通过；Release、严格签名、Sparkle实际加载及DMG校验通过。无本地磁盘挂载扩展，未自动安装启动、覆盖旧包或正式发布。真实NAS仍由用户验证。具体命令与剩余范围见照片对齐账本。


### 2026-09-30 Photos 自动预览调度测试包（非正式发布）

`apple/Apps/DsmMac/dist/photos-preview-priority-20260930/LanStash-1.0.11-arm64.dmg`，21,509,854字节，1.0.11(21)、arm64、localtest、本机临时签名。新增网页前2/后3及小集合缩减、相邻视频排除与普通/HEVC实况/VC1/后台处理顺序；包含先前照片完整累计改动。696项相关XCTest、6项本地化及Release、严格签名、实际Sparkle加载、DMG校验通过。没有本地磁盘挂载扩展，未安装启动或覆盖旧包，未正式发布。真实NAS/物理手势仍待用户验证，入口无人工待实测禁用；整库维护和最终网页审计仍未完成。详细命令/风险/范围见MACOS_PHOTOS_PARITY_20260929_ZH.md最新波次。


### 2026-10-01 Photos 当前空间整库维护测试包

独立本机临时签名成品`apple/Apps/DsmMac/dist/photos-library-maintenance-20261001/LanStash-1.0.11-arm64.dmg`，21,608,749字节，1.0.11(21)、arm64；新增个人/共享重新索引、异常预览生成、确认及自动状态核对，包含全部此前Photos改动。源码与完整验证范围见Photos对齐账本：705项XCTest、6项本地化、1项UI/24张合成截图，Release/严格签名/Sparkle实际加载/DMG校验通过。无本地磁盘挂载扩展；没有安装启动、覆盖旧包或正式发布。

此包仍未包含长断线后删除持续核对、全用户编解码器欢迎流程及上传跨重启恢复；自动预览异常状态与最终菜单审计继续。NAS真实维护和物理手势由用户测试，接口static不等于行为验证。


### 2026-10-01 Photos 长断线删除持续恢复测试包

独立包`apple/Apps/DsmMac/dist/photos-deletion-continuing-20261001/LanStash-1.0.11-arm64.dmg`，21,613,407字节，1.0.11(21)、arm64、本机临时签名。包含此前整库维护，新增单张/批量及目录混选删除持续核对，移除手动要求，离开/禁用丢弃晚到结果并修正并发分页偏移。709项XCTest、6项本地化、2项UI/8张合成截图、Release/严格签名/实际组件加载/DMG校验通过。无本地磁盘挂载扩展，未安装启动、覆盖旧包或正式发布。真实NAS由用户验证；新格式全用户处理、失败同步及上传跨重启恢复尚未包含。


### 2026-10-01 Photos新格式提示独立本地测试包

`apple/Apps/DsmMac/dist/photos-codec-prompt-20261001/LanStash-1.0.11-arm64.dmg`，1.0.11(21)、21,705,865字节、arm64、localtest。新增新格式提示、稍后已读、管理员全用户/普通用户个人补预览；未知结果不重发，部分失败只补保存提示，历史月份保持。包含此前全部照片功能。721项XCTest、6项本地化、1项UI/28张合成截图、Release构建、严格签名、专用临时权限、Sparkle实际加载、DMG校验及额外codesign检查通过。无本地磁盘挂载扩展，未安装/启动或正式发布，旧包保留。真实NAS由用户验收；剩余失败状态同步、最终查漏和待独立授权的上传跨重启恢复，详见Photos对齐账本。


### 2026-10-01 Photos自动预览失败同步本地测试包

`apple/Apps/DsmMac/dist/photos-preview-failures-20261001/LanStash-1.0.11-arm64.dmg`，1.0.11(21)、21,701,299字节、arm64、localtest。明确转换失败按照片/视频阶段同步，临时错误及未知上传结果不误标记；生成失败不计成功，提供重建预览提示，保持历史月份。包含此前全部照片改动。728项XCTest、6项本地化、1项UI/4张合成截图、Release、严格签名、专用临时权限、Sparkle实际加载及DMG校验通过。无本地磁盘挂载扩展，未安装启动或正式发布，旧包保留。真实NAS由用户验收；剩余选片直接分享组合流程、最终菜单查漏和待独立存储授权的上传跨重启恢复。


### 2026-10-01 选片直接分享本机测试包（非正式发布）

产物`apple/Apps/DsmMac/dist/photos-selection-sharing-20261001/LanStash-1.0.11-arm64.dmg`，21,757,043字节，1.0.11(21)、arm64、localtest。包含累计照片功能与本轮工具栏/右键/预览直接选片分享，私有相册核对后同窗设置分享，创建与分享持续自动核对。729项XCTest、6项本地化、2项原生UI/42张合成截图通过；Release、严格签名、专用临时权限、Sparkle实际加载和DMG校验通过，无本地磁盘挂载扩展。未安装启动、覆盖旧包、推送或正式发布。真实NAS验收由用户执行，完整网页菜单查漏及上传跨重启恢复仍未完成。


### 2026-10-01 照片独立新建文件夹测试包（非正式发布）

`apple/Apps/DsmMac/dist/photos-create-folder-20261001/LanStash-1.0.11-arm64.dmg`，21,791,872字节、1.0.11(21)、arm64、localtest。个人/共享当前目录独立创建入口，确认后只更新目录分页，照片与选择保持；包含此前累计改动。732项XCTest、6项本地化、2项UI/12张合成截图通过，Release、严格签名、Sparkle实际加载及DMG校验通过。真实NAS由用户验收，无本地磁盘挂载扩展，未安装启动或正式发布，旧包保留。命令及待验步骤见照片对齐账本；完整网页对齐继续，不将临时分享/冻结相册等剩余项计为已实现。


### 2026-10-01 临时分享测试包完成（非正式发布）

`apple/Apps/DsmMac/dist/photos-temporary-sharing-20261001/LanStash-1.0.11-arm64.dmg`，21,974,554字节，1.0.11(21)、arm64、localtest。包含累计照片功能及临时分享创建取消清理、停止保留副本、未知结果自动核对、明确失败保留现有相册。748项XCTest、6项本地化、4项UI/74张合成截图、Release、严格签名、Sparkle实际加载与DMG校验通过。无本地磁盘挂载扩展，未自动安装启动或正式发布；真实NAS和系统确认框最终视觉由用户验收。其他端未构建，static证据不提升。完整命令、限制与待验步骤见Photos对齐账本；冻结条件相册等剩余项继续。


### 2026-10-01 照片缩略图大小测试包完成

`apple/Apps/DsmMac/dist/photos-thumbnail-size-20261001/LanStash-1.0.11-arm64.dmg`，21,996,598字节、1.0.11(21)、arm64、localtest。包含累计照片改动及五档滑杆/按钮/键盘调整，保留历史月份、多选和可见照片锚点。246项XCTest、6项本地化、3项UI/24张合成截图、Release、严格签名、Sparkle实际加载及DMG校验通过。无本地磁盘挂载扩展，未自动安装或正式发布；会话内记忆，不新增持久化，真实触控与VoiceOver由用户验收。其他平台未改动，冻结条件相册、分享列表快捷管理和任务后续操作等仍继续。


### 2026-10-01 分享列表快捷管理测试包完成

“由我共享”行可直接管理，打开/取消只读；保存/停止确认后保持范围和排序更新已加载窗口，未知结果继续自动核对，读取失败保留旧列表并只读重试，迟到结果不覆盖新页面。无新API/存储或其他端UI改动。250项模型/外观XCTest、6项本地化、1项原生UI/16张合成截图通过。独立Release包`apple/Apps/DsmMac/dist/photos-sharing-list-20261001/LanStash-1.0.11-arm64.dmg`，22,015,788字节、1.0.11(21)、arm64、localtest；严格签名、Sparkle实际加载、DMG校验通过。包含此前累计功能，无本地磁盘挂载扩展，未安装启动或正式发布，真实NAS由用户验收。冻结条件相册、任务后续操作、待独立存储授权的上传跨重启恢复及最终查漏仍未完成。详细命令与步骤见Photos对齐账本。


### 2026-10-01 上传任务后续操作测试包完成

本机上传队列已增加打开实际目录、前往相册、单项排队取消和终态记录移除；未知/在途项保留核对，移除只清本地记录。760项XCTest、6项本地化、2项原生UI/16张合成截图通过。独立Release包`apple/Apps/DsmMac/dist/photos-upload-actions-20261001/LanStash-1.0.11-arm64.dmg`，22,040,123字节、1.0.11(21)、arm64、localtest；严格签名、Sparkle实际加载及DMG校验通过，包含此前累计照片改动。无本地磁盘挂载扩展，未安装启动或正式发布；真实NAS与物理设备由用户验收。NAS后台任务列表、冻结条件相册、待独立存储授权的上传跨重启恢复及最终菜单查漏仍未完成。详细命令、错误修正与PENDING_USER_VALIDATION步骤见Photos对齐账本。


### 2026-10-01 NAS后台任务中心测试包完成

`apple/Apps/DsmMac/dist/photos-background-tasks-20261001/LanStash-1.0.11-arm64.dmg`，22,262,350字节，1.0.11(21)、arm64、localtest，包含此前全部照片改动。新增复制/移动任务筛选、进度、取消、单项/固定快照批量清理、错误详情和目标目录导航；未知回执不重发，清理不删照片。780项XCTest、6项本地化、2项原生UI/56张合成截图及Release通过；严格签名、Sparkle实际加载、DMG校验通过。无本地磁盘挂载扩展，未安装启动或正式发布。真实NAS由用户验收；冻结相册恢复/重建、上传跨重启恢复（待独立存储授权）及最终菜单查漏仍未完成。详细命令与PENDING_USER_VALIDATION见Photos对齐账本。


### 2026-10-01 预览直接操作本机测试包

独立Release交付为`apple/Apps/DsmMac/dist/photos-preview-actions-20261001/LanStash-1.0.11-arm64.dmg`（22,486,900字节，1.0.11(21)，arm64，既有localtest标识）。包含预览相册/元数据/移动复制/人物直接操作及确认移出后的预览同步；808项XCTest、6项本地化、3项原生UI/28张合成截图通过。按既有package.sh流程打包，严格签名、Hardened Runtime专用测试权限、Sparkle实际加载与DMG校验通过；无本地磁盘挂载扩展，未自动安装启动或正式发布。真实NAS待用户验证，剩余功能与实际命令见Photos对齐账本。


### 2026-10-01 Photos三项统一收尾本机测试包

贡献者编辑角色、上传跨重启队列/回执恢复、列表/预览/全局设置菜单终审一次实现后统一验证。独立产物`apple/Apps/DsmMac/dist/photos-three-final-20261001/LanStash-1.0.11-arm64.dmg`为22,647,845字节，1.0.11(21)、arm64、localtest；827项XCTest、6项本地化、4项原生UI/48张中英浅深色截图和临时生成移动端工程的模拟器构建通过。严格签名、专用Hardened Runtime权限、Sparkle实际加载及DMG校验通过。

本机临时包不含本地磁盘挂载扩展，未安装启动、上传或正式发布。正式主App的`com.apple.security.files.bookmarks.app-scope`权限尚待用户确认，现有权限保持原样；正式沙盒上传恢复及真实NAS行为不能据本机测试宣布通过。详细命令、修复记录、用户待验步骤见`docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`文末。


### 2026-10-02 正式沙盒文件书签权限补齐

用户已明确授权，仅正式主App加入`com.apple.security.files.bookmarks.app-scope = true`，扩展与本地测试权限保持原样。`plutil -lint`、逐键差异校验、`python3 tools/release/test_macos_signing.py`的10项测试、严格文档检查及差异检查通过。既有本机临时包使用独立权限文件，本轮不重新打包；正式签名、沙盒跨重启恢复和真实NAS验收仍未运行，也未进行发布。此前“权限待确认”属于历史状态，已由本节解除。


## 2026-10-02 macOS 1.0.12 正式发布

用户明确授权整理代码提交、推送并发布新版本。发布目标为`macos/v1.0.12`，主App和File Provider均为1.0.12、构建号22，上一稳定版为1.0.11(21)。专用分支`codex/photos-release-1.0.12`承载本轮累计Photos功能及共享枚举所需的两行移动端适配；按既有锁定XcodeGen流程更新工程，版本说明中英同步。保持既有签名身份、最低系统版本与更新通道，正式主App采用已授权的文件书签权限。

交付范围包含自1.0.11以来的分享/收集、人物主题相似照片、共享空间与成员权限、预览重建及自动转换、图库设置/维护、后台任务、冻结相册、预览直接操作及上传跨重启恢复。原始功能与每轮验证见`docs/development/MACOS_PHOTOS_PARITY_20260929_ZH.md`；真实NAS、VoiceOver与系统书签恢复的待验标记不因发布而自动升级。

执行顺序为专用分支提交及完整云端门禁、重新核对远端main、合入单一正式提交、推送版本标签，再由既有macOS Release流程完成arm64/x86_64签名公证、附件回读和更新源签名验证。任一门禁失败不推发布标签，不绕过签名/公证/更新验收条件。精确提交和云端运行结果以GitHub该版本记录为准。
