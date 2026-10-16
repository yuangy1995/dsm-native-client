<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# Apple 原生客户端

Swift 6、SwiftUI 与 Swift Package Manager；macOS 最低 14，iOS/iPadOS 最低 17。项目版本与目标以 [Package.swift](Package.swift) 及各 App 的 `project.yml` 为准。功能状态见[五端矩阵](../docs/progress/PLATFORM_MATRIX.md)，不从共享实现推定所有平台已验证。

| 入口 | 职责 |
| --- | --- |
| [DsmMac](Apps/DsmMac/README.md) | macOS 原生工作区、系统预览/本机编辑、Finder 与桌面生命周期 |
| [DsmMobile](Apps/DsmMobile/README.md) | iPhone/iPad 通用 App、系统后台时间、分享扩展与 Files |
| [DsmCore](Packages/DsmCore/Sources) | 连接、文件、照片、聊天、下载、NAS/容器/VMM 的领域模型、Repository 协议及恢复类型 |
| [DsmNetwork](Packages/DsmNetwork/Sources) | HTTP/二进制/WebSocket、认证/证书/QuickConnect、能力发现、参数编码与各套件适配 |
| [DsmLocalization](Packages/DsmLocalization/Sources) | 英语/简体中文资源、语言偏好与区域格式 |
| [DsmFileFeature](Packages/DsmFileFeature/Sources) | 上传计划/批次、归档、VFS 表单/云授权、Office 格式和空间分析 |
| [DsmPhotosFeature](Packages/DsmPhotosFeature/Sources) | 图库、分页/选择、管理、预览、上传与恢复；文件访问/选择器由平台注入 |
| [DsmFileProviderRuntime](Packages/DsmFileProviderRuntime/Sources) | 系统文件枚举、缓存、版本/冲突、写回与恢复的共用逻辑 |
| [DsmVirtualMachineConsoleFeature](Packages/DsmVirtualMachineConsoleFeature/Sources) | 非持久控制台宿主、原生资源/连接桥及来源边界 |

平台层负责 UI、账号生命周期、系统文件授权和存储位置，共享模块不建立第二套上传或恢复算法。共享变更保留 macOS 调用与已发布数据兼容，并运行 Mac 回归。Mac 私有会话文件的主密钥在私有 Keychain；移动真机使用 Keychain，模拟器测试存储不代表真机保护。更多边界见[平台集成](../docs/development/PLATFORM_INTEGRATION.md)。

## 验证

从仓库根目录运行：

```sh
swift test --package-path apple
```

Xcode 与 XcodeGen 必须与 [Apple 工作流](../.github/workflows/apple-build.yml)锁定版本一致。修改 `project.yml` 后通过 XcodeGen 重生成工程，不能手改生成文件。具体构建/包与原生 UI 命令见两个 App README；共享单元通过不能代替各 App 构建及两种移动设备 UI。

签名配置与正式发布见[Apple 发布手册](../docs/releases/MACOS_GITHUB_RELEASE_ZH.md)，当前问题与设备步骤见[限制清单](../docs/progress/KNOWN_LIMITATIONS.md)。协议从[API 目录](../docs/api/README.md)查阅，测试证据遵循[验证原则](../docs/quality/VERIFICATION_LEVELS_ZH.md)。
