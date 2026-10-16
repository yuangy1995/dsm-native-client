<!-- doc-role: entrypoint -->
<!-- last-reviewed: 2026-10-16 -->

# 岚仓（LanStash）

[简体中文](README.md) · [English](README.en.md)

岚仓是面向 Synology DSM 的开源原生客户端，覆盖 macOS、iPhone、iPad、Android 和 Windows。Apple 使用 Swift/SwiftUI，Android 使用 Kotlin/Jetpack Compose，Windows 使用 C#/WinUI 3；共享 API 契约，保留各平台原生交互。

功能包括文件、Synology Photos、Chat、下载、NAS 设置、套件、容器和虚拟机管理。各端实现范围、未完成能力和入口限制统一见[五端功能表](docs/progress/PLATFORM_MATRIX.md)；现存问题与真实环境验收条件见[限制与待办](docs/progress/KNOWN_LIMITATIONS.md)。源码已实现不等于所有 DSM、套件和设备组合已经验证。

## 使用与开发入口

| 需要了解什么 | 入口 |
| --- | --- |
| Apple 使用、构建和测试 | [Apple](apple/README.md)、[macOS](apple/Apps/DsmMac/README.md)、[iPhone/iPad](apple/Apps/DsmMobile/README.md) |
| Android 构建与测试 | [Android](android/README.md) |
| Windows 构建与测试 | [Windows](windows/README.md) |
| API 定义与依据 | [API 目录](docs/api/README.md)、[跨端契约](contracts/README.md) |
| 已发布版本 | [GitHub Releases](https://github.com/yuangy1995/dsm-native-client/releases) |
| 其余维护说明 | [文档目录](docs/README.md) |

## 语言与隐私

支持英语和简体中文；首次启动跟随系统，不支持的语言回退英语，也可在本机固定选择。资源及回退规则见[语言契约](contracts/localization/README.md)。

优先使用 Synology 官方公开 API，内部接口明确标注。危险写操作需要权限、必要确认、防重复提交及结果校验。不要公开提交凭据、会话、真实主机、路径、原始响应或抓包；安全问题见[安全策略](SECURITY.md)。

参与开发先读 [AGENTS.md](AGENTS.md) 和[贡献指南](CONTRIBUTING.md)。不同 NAS 环境可按[社区兼容性指南](docs/compatibility/COMMUNITY_COMPATIBILITY_GUIDE_ZH.md)提交脱敏结果。

本项目及其历史提交采用 [Apache License 2.0](LICENSE)。
