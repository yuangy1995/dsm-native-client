# Apple 签名与 macOS 发布

本页维护现行签名配置、macOS 发布、更新和回滚流程。功能与待验范围见[平台矩阵](../progress/PLATFORM_MATRIX.md)和[已知限制](../progress/KNOWN_LIMITATIONS.md)。工作流、脚本与源码版本为事实来源，不在此累计每次构建日志。

## 本地测试包

macOS 开发默认通过 [package.sh](../../apple/Apps/DsmMac/package.sh) 生成独立临时签名包，不自动安装或启动：

```bash
mkdir -p apple/Apps/DsmMac/dist
test_package_dir="$(mktemp -d "$PWD/apple/Apps/DsmMac/dist/local-test-XXXXXX")"
LANSTASH_NON_INTERACTIVE=1 LANSTASH_SIGNING_IDENTITY=- \
LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$test_package_dir" \
bash apple/Apps/DsmMac/package.sh
```

临时签名沿用既有 `LanStash Test` / `.macos.localtest` 身份、独立 localtest App Group 与钥匙串，和正式版数据隔离；不修改既有正式/测试身份，不迁移正式数据或存储格式。脚本默认使用 `dist/local-test`、`build/local-test`，会覆盖同名 DMG 并清理该输出目录中的旧版本；上例为每次打包新建独立输出目录以保留旧包。

临时签名移除 File Provider 扩展，不能验证 Finder 挂载；只有专用测试权限文件允许库验证例外，其余 Hardened Runtime 保护保留。需验证实际组件加载，签名校验本身不等于可运行。工具链与完整平台验证入口见[平台集成](../development/PLATFORM_INTEGRATION.md)。

## GitHub 发布身份

使用受保护的 `macos-release` Environment。以下配置以 [macOS Release 工作流](../../.github/workflows/macos-release-verification.yml) 为准；证书、App/扩展 profile、Bundle ID、App Group 与共享钥匙串必须属于一致的团队和授权身份。

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Secret | `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64` | 仅含目标 Developer ID Application 身份及私钥的 P12 |
| Secret | `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` | P12 密码 |
| Secret | `MACOS_APP_PROVISIONING_PROFILE_BASE64` | 主 App profile |
| Secret | `MACOS_FILE_PROVIDER_PROVISIONING_PROFILE_BASE64` | File Provider profile |
| Secret | `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | 公证 API 私钥 |
| Secret | `APP_STORE_CONNECT_API_KEY_ID` / `APP_STORE_CONNECT_API_ISSUER_ID` | 公证身份 |
| Variable | `MACOS_APP_BUNDLE_ID` / `MACOS_FILE_PROVIDER_BUNDLE_ID` | 已注册的主 App / 扩展标识 |
| Variable | `MACOS_APP_GROUP_ID` / `MACOS_SHARED_KEYCHAIN_SUFFIX` | 两组件共享容器与钥匙串身份 |
| Variable | `SPARKLE_PUBLIC_ED_KEY` | 随应用分发的独立更新公钥 |
| Secret | `SPARKLE_PRIVATE_ED_KEY` | 安装包与更新源签名私钥 |
| Variable | `MACOS_ONLINE_UPDATE_VALIDATED` | 满足真实签名升级验收要求后才设为 `true` |

Base64 不是加密。材料只进受控 Secret/钥匙串，不进入仓库、命令行参数或日志。Sparkle 密钥使用本项目独立账户生成并备份，不复用其他项目密钥；更新公私钥必须匹配。文档整理或单元测试不能擅自修改验收开关。

iPhone/iPad 使用独立的 `ios-release` Environment，配置见 [iOS Signed IPA 工作流](../../.github/workflows/ios-release.yml)：

| 类型 | 名称 |
| --- | --- |
| Secret | `IOS_DISTRIBUTION_CERTIFICATE_BASE64`、`IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`、`IOS_APP_STORE_PROVISIONING_PROFILE_BASE64`、`APPLE_TEAM_ID` |
| Variable | `IOS_APP_BUNDLE_ID` |
| 仅上传 App Store Connect 时需要的 Secret | `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64`、`APP_STORE_CONNECT_API_KEY_ID`、`APP_STORE_CONNECT_API_ISSUER_ID` |

iOS P12 只含目标 Apple Distribution 身份，证书、profile、团队与 App 标识须匹配。此配置入口不表示移动端已发布或已完成真机验收。

## macOS 发布流程

1. 完成范围内审查、Apple 测试、本地化与构建。同步 [project.yml](../../apple/Apps/DsmMac/project.yml) 中主 App/扩展版本与构建号，更新脚本输入 [MACOS_RELEASE_NOTES.md](MACOS_RELEASE_NOTES.md)。构建号须高于上一公开版本，不使用工作流运行次数。
2. 仅生成正式签名候选：手动运行 `macOS Release`，`package_mode=release`、`enable_updates=true`、`publish_to_github=false`。真实升级验收使用两个递增版本与构建号、`macos-validation/vX.Y.Z` 标签和 `publish_validation=true`；它们使用独立的 `macos-validation-updates` 更新源，仍须正式签名与公证。
3. 完成当前候选要求的[正式签名与 Finder 验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)，再依已有证据设置 `MACOS_ONLINE_UPDATE_VALIDATED=true`。提交、标签、发布分别需要用户授权。
4. 正式发布标签为 `macos/vX.Y.Z`，须与 App 版本一致。工作流分别构建 `LanStash-X.Y.Z-arm64.dmg` 与 `LanStash-X.Y.Z-x86_64.dmg`，校验 App/扩展实际单架构、来源、身份、版本和更新密钥，完成签名、公证、票据装订与 Gatekeeper 校验。
5. 两份 DMG、签名更新源与 SHA-256 清单上传回读成功后公开版本，最后更新 `macos-updates`。任一架构失败不切换更新源；若版本已存在，先核对草稿与产物，不能自动重试覆盖已公开附件。

本机正式公证通过 [notarize.sh](../../apple/Apps/DsmMac/notarize.sh) 和钥匙串中的 `LANSTASH_NOTARY_PROFILE` 完成；不把公证私钥正文传入脚本。工具链版本直接以 [Apple Build](../../.github/workflows/apple-build.yml)、macOS/iOS 工作流为准；工具链变化须重新验证，不能沿用结果。

## 在线更新规则

- 更新源固定为 `macos-updates/appcast.xml`，不使用跨平台 `releases/latest`。包与源都需 Ed25519 签名，解包前验证，发布前用应用内公钥独立验签。
- 同版本/构建号按 arm64 在前、带硬件要求，Intel 在后的顺序发布。Rosetta 按实际 Apple Silicon 硬件匹配；旧通用版本保留原更新地址与密钥。
- 自动检查默认开启，可关闭；不静默安装，安装重启前确认。当前文件任务或文本编辑未结束时阻止升级重启，系统退出请求再次检查。
- 预测试签名通用包不进入正式源；没有 Sparkle 的旧版本须手动安装一次。升级只替换客户端，不改变 NAS、套件或账号数据。
- Sparkle 仅链接 macOS App，版本和权限以工程配置为准。修改版本、架构顺序或硬件条件须运行 `python3 -m unittest discover -s tools/release -p 'test_*.py'`，覆盖 Intel、Apple Silicon、Rosetta、旧源迁移、缺包与来源不一致。

## 回滚与验收边界

- 尚未公开：保留草稿核对；更新源错误：恢复上一份已签名的完整源，不直接编辑 XML。
- 应用缺陷：用更高版本/构建号发布修复，不降版本或替换同版本附件。
- 移除更新能力须单独移除入口、依赖及专用权限；密钥丢失/轮换须设计迁移，不能直接换公钥覆盖旧源。
- `PENDING_USER_VALIDATION`：Intel、原生 Apple Silicon、Rosetta 与支持系统的升级保留配置和映射；Finder/Office/上传在途任务阻止提前重启；断网、安装权限不足、正式沙盒文件书签跨重启及失败恢复保留内容。历史签名或升级反馈不能替代当前候选和异常路径。

使用可恢复的测试快照；回传仅含版本、架构/系统类别、步骤、预期与实际结果和脱敏错误。CI artifact 按服务留存策略保留，并非永久证据库；只在现行限制或 API 记录中保存必要结论，不把原始日志和产物提交仓库。
