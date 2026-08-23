# GitHub Actions Apple 签名与发布配置

Apple 正式发布使用两个受保护的 GitHub Environment：`macos-release` 和
`ios-release`。两个环境都应启用 required reviewers；普通 push、PR 和 fork PR 只运行
无签名构建，不得获得发布凭据。

证书、私钥和 provisioning profile 不得提交到仓库。二进制文件先在可信 Mac 上转为
单行 Base64，再保存为 GitHub Environment Secret。Key ID、Issuer ID、Team ID 也按
Secret 管理，避免将维护者账号元数据写入 workflow 或日志。

## 共享 App Store Connect API Secrets

macOS 公证和可选的 iOS 上传共用以下 Secrets：

| Secret | 内容 |
| --- | --- |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | `AuthKey_<KEY_ID>.p8` 的 Base64，不是文件路径 |
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect API Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | App Store Connect API Issuer ID |

必须使用能够访问 `notarytool` 的 Team API Key。Individual API Key 不能用于公证或
Provisioning API。若 iOS workflow 只导出 IPA 而不上传，这三个 Secrets 对该次 iOS
运行不是必需项。

## macOS DMG：`macos-release`

配置以下 Environment Secrets：

| Secret | 内容 |
| --- | --- |
| `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64` | 包含 Developer ID Application 证书和私钥的密码保护 `.p12` Base64 |
| `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `MACOS_APP_PROVISIONING_PROFILE_BASE64` | 主 App 的 Developer ID `.provisionprofile` Base64 |
| `MACOS_FILE_PROVIDER_PROVISIONING_PROFILE_BASE64` | File Provider Extension 的 Developer ID `.provisionprofile` Base64 |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | 共享 API 私钥 Base64 |
| `APP_STORE_CONNECT_API_KEY_ID` | 共享 API Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | 共享 API Issuer ID |

配置以下 Environment Variables。它们会进入签名产物，本身不是密码，但必须全部属于
Developer ID 证书对应的同一个 Apple Developer Team：

| Variable | 内容 |
| --- | --- |
| `MACOS_APP_BUNDLE_ID` | 主 App 的显式 Bundle ID |
| `MACOS_FILE_PROVIDER_BUNDLE_ID` | File Provider Extension 的显式 Bundle ID |
| `MACOS_APP_GROUP_ID` | 两个 target 共用的 App Group；macOS 推荐 `<TeamID>.<名称>`，也支持已注册的 `group.<名称>` |
| `MACOS_SHARED_KEYCHAIN_SUFFIX` | 共享 Keychain group 的 Team ID 后缀，不包含 Team ID 和前导点 |

`.p12` 必须且只能包含一张 `Developer ID Application` 身份。由于 App 与 Extension
使用受限的共享 Keychain entitlement，两份 Developer ID profile 都是必需项。workflow
会验证 profile、证书 Team、Bundle ID 和 Keychain group 一致，再嵌入各自 bundle；
App Group 则由两个 target 的同一构建变量生成；使用 macOS Team-ID 风格时，workflow
还会确认前缀与签名证书团队一致。它随后签名 App、Extension 和 DMG，使用 API Key 公证、装订票据并执行
Gatekeeper 与 entitlement 校验。

## iOS IPA：`ios-release`

配置以下 Environment Secrets：

| Secret | 内容 |
| --- | --- |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | 包含 Apple Distribution 证书和私钥的密码保护 `.p12` Base64 |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64` | 与正式 Bundle ID、Apple Distribution 证书匹配的 App Store Connect `.mobileprovision` Base64 |
| `APPLE_TEAM_ID` | 上述证书和 profile 所属 Team ID |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | 上传时使用的共享 API 私钥 Base64 |
| `APP_STORE_CONNECT_API_KEY_ID` | 上传时使用的共享 API Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | 上传时使用的共享 API Issuer ID |

配置一个 Environment Variable：

| Variable | 内容 |
| --- | --- |
| `IOS_APP_BUNDLE_ID` | 已在 Apple Developer 与 App Store Connect 注册的 iOS Bundle ID |

workflow 会验证 profile 的 Team ID 和 `application-identifier`，然后生成 archive、导出
签名 IPA 并上传 IPA 与 dSYM 为 GitHub Artifact。手工触发时可选择是否把 IPA 上传到
App Store Connect/TestFlight。上传前必须已经在 App Store Connect 创建对应 App 记录，
而且每次运行的 build number 必须唯一；workflow 使用 `GITHUB_RUN_NUMBER` 作为 build。

当前 iOS workflow 面向 App Store Connect/TestFlight。若需要 Ad Hoc IPA，应另外提供
包含目标设备的 Ad Hoc profile；若需要 Development IPA，则必须改用 Apple Development
证书和 Development profile，不能复用 App Store profile。

## 凭据准备与安全边界

- `.cer` 只有公钥，不够用于 CI；必须导出包含私钥的密码保护 `.p12`。
- 不要把本机登录钥匙串、所有证书或无关身份整体导出，只导出目标签名身份。
- Base64 只是一种编码，不是加密；编码结果必须放入 GitHub Secret。
- 不要在 workflow 中 `echo`、打印、上传或缓存解码后的 `.p8`、`.p12`、profile 或临时
  keychain。
- 发布 job 只允许 `workflow_dispatch` 或受保护 tag，环境启用人工批准；不要在
  `pull_request_target` 中使用发布 Secrets。
- API Key 应使用满足上传与公证所需的最小角色。怀疑泄露时立即在 App Store Connect
  撤销并更换。

在 macOS 上可使用下列命令把单个文件编码后直接复制到剪贴板；命令不会修改原文件：

```bash
base64 -i /安全路径/DeveloperID.p12 | pbcopy
base64 -i /安全路径/MacApp.provisionprofile | pbcopy
base64 -i /安全路径/FileProvider.provisionprofile | pbcopy
base64 -i /安全路径/AppleDistribution.p12 | pbcopy
base64 -i /安全路径/AuthKey_KEYID.p8 | pbcopy
base64 -i /安全路径/Profile.mobileprovision | pbcopy
```

不要把这些命令替换成真实秘密后保存到脚本或 shell 历史文件中。
