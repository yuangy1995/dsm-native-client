<!-- doc-role: status -->
<!-- last-reviewed: 2026-10-10 -->

# 当前开发进度

更新至 2026-10-10。本页只记录当前结论与下一步；平台范围见[功能矩阵](PLATFORM_MATRIX.md)，精确提交、命令、原失败与产物见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。源码、契约及实际结果优先于历史描述。

## 当前结论

| 平台 / 功能 | 当前实现与验证边界 | 下一步 |
| --- | --- | --- |
| macOS 文件与 Office | 文件高级搜索、批量/目录上传、归档、分享、权限、远程位置、任务控制，以及系统预览、本机编辑自动回传和冲突恢复已接入；已有聚焦回归与临时签名包证据 | 专用文件验证真实权限、编辑器、云回调、断网与最终结果；见[使用说明](../../apple/Apps/DsmMac/README.md) |
| macOS Photos | 浏览、管理、上传恢复和预览已实现；已发布的独立 Photos 授权修复与当前源码的旋转/浮层反馈修改分开记录 | 旋转与反馈修复已纳入当前源码，尚未正式发布，相关共享回读影响继续按[端点记录](../api/discovery/endpoints/photos-management.md)验收；不提升真实 NAS 证据等级 |
| macOS NAS、套件、容器与 VMM | NAS 设置、安装/更新/SPK、服务控制及恢复已有实现；VMM 电源、删除、设置、创建、网络/映像和控制台有共享/Mac 回归与构建证据 | 真实系统写仅在专用可丢弃环境验收；控制台合成握手不能代替真实画面、键鼠和长连接 |
| macOS Chat 与桌面集成 | 搜索、编辑、线程、投票参与、录音播放、阅读同步及通知已接入；挂载默认只读，编辑和删除分别授权 | 真实 Chat、Finder、通知、辅助功能及升级场景分别验收；[历史反馈](../archive/2026-h2/MACOS_FEEDBACK_HISTORY.md)不替代新包结果 |
| iPhone / iPad | M0–M7 批准范围及 M8 普通文件/照片/跨 NAS/Office 后台时间、系统分享与 Files 已接入；两端分片 UI、单元和构建已有证据 | 原云端六项失败经 `7f411313` 相关修正后按原机型本机复跑全部通过；用户已要求跳过本次等待，完整云端验收延期。共享/macOS 分组通过；截至本页复核，移动分组仍在运行或排队。保留原失败与系统时序风险，见[移动主计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md) |
| Windows | 已完成 2026-09-21 范围的业务对齐、云盘写回/恢复及 x64/ARM64 云端验证；后续 Mac 增量不自动算已移植 | 按[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)推进 Photos 管理、File Station 增量与 Office，并独立完成 Windows 设备验收 |
| Android | Compose 客户端、后台/传输、Photos 和质量门已建立；已记录 Task.edit 版本及 Chat 投票请求差异，既有云端失败仍待独立修正 | 按[Android 计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)修正契约差异、收敛结构并验证目标设备；完整 JVM/Release/R8/lint 交托管 Runner |

## 验证与发布边界

移动修正来源的[完整 Apple 检查](https://github.com/yuangy1995/dsm-native-client/actions/runs/38006897143)尚未形成全部通过结论；本机未复现不能证明云端根因消失。本次文档整理不重跑整轮，也不删除测试或放宽断言。Files 默认只读与编辑回传已有本机通过证据，历史系统读访问占用及后续清理失败仍单独保留，见[Files 账本](../development/APPLE_MOBILE_FILES_PROVIDER_ZH.md)。

按发布时间，最近的 macOS 正式版本为 [1.0.17（27）](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.17)。其签名、公证、双架构安装包与更新源回读证据见[发布记录](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-07-macos-1017-正式发布与公开回读)；后续共享层及当前工作区改动不属于该版本。本机临时签名包不含 Finder 挂载扩展，不自动安装或启动，也不替代正式分发与系统验收。

iPhone/iPad、Android、Windows 的源码、自动化、真机与发布等级分别维护；不能由 macOS 发布或共享测试推定其他端已完成。

## PENDING_USER_VALIDATION

| 条件 | 操作与预期 | 脱敏反馈与影响 |
| --- | --- | --- |
| 真实 DSM / 套件与专用可丢弃目标 | 按功能验证权限、断网、取消、重复操作与最终状态；未知写只查询恢复 | App/DSM/套件版本、步骤和错误类别；不回传凭据、真实地址、路径或正文。版本证据按[发现流程](../api/discovery/README.md)保存 |
| Apple 正式签名、共享权限和系统注册 | 分享、Files、Finder、锁屏/进程回收、冲突、删除与移除分别验收 | 签名类别、系统版本、失败阶段；步骤见[移动计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)及[桌面验收矩阵](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md) |
| Windows / Android 真实系统行为 | Explorer/Cloud Files、后台/Doze、通知、安装升级、外接卷与辅助功能 | 平台版本、设备类别及脱敏步骤；按各端计划记录，构建不能代替这些结果 |
| Office、媒体与辅助功能 | 常用编辑器、相机/麦克风、选择器、最大文字、屏幕阅读器与键盘 | 具体控件、来源 App 和操作阶段；冲突或未知保留本机副本，不自动重复写入 |

## 后续顺序

1. 优先处理用户实际反馈的可复现问题，补聚焦回归与独立测试包。
2. 在获授权范围内完成延期的云端复验与设备待办；不以设备缺口暂停独立源码切片。
3. 新增跨端功能从[API 目录](../api/README.md)查当前语义，再按目标平台计划实施；未开发能力与已实现待验收分开。
4. 发布、外部写入及范围变化遵循项目授权边界。未来候选见[路线图](ROADMAP.md)，验证含义见[等级规则](../quality/VERIFICATION_LEVELS_ZH.md)。
