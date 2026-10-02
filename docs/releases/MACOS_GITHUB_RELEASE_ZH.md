# macOS GitHub 发布与在线升级

本文只维护正式发布、更新和回滚流程；已执行结果与用户反馈集中在[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。开发测试包不追加到发布操作说明。

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

Apple 发布身份配置保持不变。用户授权后，已为本项目生成独立升级密钥，保存在本机钥匙串的专用账户，并配置到 `macos-release` 的上述 Secret/Variable；私钥不进入源码。该开关必须依据已有真实升级验收及当前候选要求配置，不能由文档整理或单元测试擅自设为通过。

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


## 当前工具链与文件访问权限

Apple Build、macOS Release、iOS Release 已按用户授权统一使用 macos-26 / Xcode 26.6 (17F113)，XcodeGen 固定 2.46.0；最低 macOS 14、既有签名与更新身份保持不变。必要时工具链回退至 macos-15 / Xcode 16.4 (16F6) 后必须重新验证，不沿用新旧工具链结果。

正式主 App 已获准使用 app-scope 文件书签权限，供用户选择的上传文件跨重启恢复；扩展与本地测试权限文件保持各自职责。权限存在不代表真实沙盒恢复已验收，不新增任意文件访问授权。

## 用户验收与剩余覆盖

历史已有正式签名、公证及用户报告的在线升级/挂载主流程证据；这些不覆盖所有后续候选和异常路径。

- `PENDING_USER_VALIDATION`：Intel、Apple Silicon、Rosetta 与支持的系统版本升级后保留配置和挂载，获得对应原生包。
- `PENDING_USER_VALIDATION`：在途 Finder/文件/Office 保存和上传恢复期间阻止提前重启；断网、安装权限不足及失败恢复保留原内容。
- `PENDING_USER_VALIDATION`：正式沙盒文件书签跨重启、真实 NAS 权限与读写、完整 VoiceOver/键盘/动态文字/降低动态效果。

先用受控候选和可恢复快照，核对当前功能及签名身份后执行。回传仅含版本、架构/系统类别、步骤、预期与实际结果、脱敏错误；不回传地址、路径、会话或私钥。
