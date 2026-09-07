# macOS GitHub 发布与在线升级

## 范围与关键决策

- 仅发布 macOS；Android、Windows、iPhone、iPad 不参加本次发布流程。
- 发布标签为 `macos/vX.Y.Z`，版本与 `apple/Apps/DsmMac/project.yml` 的 `MARKETING_VERSION` 一致。主应用与 File Provider 的 `CURRENT_PROJECT_VERSION` 同步增加，必须高于上一公开版本。构建号不再取工作流运行次数，避免不同工作流之间比较错误。
- 通用 DMG 同时支持 arm64、x86_64；最低 macOS 14 不变。
- 保留现有 Developer ID 签名、公证、File Provider 与共享钥匙串门禁；不沿用 QuotaLens 的临时签名分发。开发用临时签名流程继续存在，但不启用在线升级。
- Sparkle 固定为 2.9.6，只链接 macOS 应用，不链接共享领域库、网络库或移动端应用。SwiftPM 和 XcodeGen 使用同一个版本，工程由 XcodeGen 生成。
- 主应用继续保持沙盒，只增加 Sparkle Installer 必需的两个通信权限；不启用 Downloader 服务，因为主应用已具有联网权限。
- 更新源固定为本仓库 `macos-updates` 发布项的 `appcast.xml`，不使用跨平台的 `releases/latest`。更新包和更新源都必须进行 Ed25519 签名；包解压前验证，发布前使用应用内公钥独立验签。
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
4. 工作流测试、签名、公证后创建版本草稿，上传 DMG、签名更新源及 SHA-256 清单，再回读核对。核对通过才公开版本，最后更新 `macos-updates` 更新源。
5. `macos-updates` 是非最新版的预发布条目，仅作更新源；正式版本的安装附件不会被覆盖。若流程中途失败且版本已存在，停止自动重试，先核对草稿、安装包和更新源状态，不删除已公开产物。

历史未含 Sparkle 的应用需要手动安装一次升级版。在线更新仅替换客户端，不改变 NAS、套件或账号数据。

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
