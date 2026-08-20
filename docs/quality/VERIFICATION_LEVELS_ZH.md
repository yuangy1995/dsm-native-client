<!-- doc-role: quality-policy -->
<!-- last-reviewed: 2026-08-20 -->

# 功能实现与验证等级

本文统一描述“代码存在”“可重跑自动化”“目标平台构建”“真实环境验证”和“发布”的
区别。低等级证据不能替代高等级证据，也不能从其他平台、DSM build、套件版本或签名方式
推断通过。

## 等级定义

| 标识 | 含义 | 最低证据 |
| --- | --- | --- |
| `IMPLEMENTED` | 目标路径已有源码实现。 | 代码审查确认入口、错误处理和安全边界存在。 |
| `AUTOMATED` | 不依赖真实环境的逻辑、静态门禁或测试可重跑。 | 真实命令、源码版本和通过/失败结果。 |
| `BUILD_VERIFIED` | 目标工程在声明工具链成功构建。 | 构建命令、平台、架构与签名类型。 |
| `SIGNING_REQUIRED` | 下一项验证依赖正式签名、entitlement 或系统注册。 | 明确列出证书、权限、目标系统和运行步骤。 |
| `DEVICE_VERIFIED` | 在真实目标设备和受控测试数据上完成。 | 脱敏环境类别、步骤、结果、日期与清理结论。 |
| `COMMUNITY_VERIFIED` | 独立外部环境给出经过审核的一致结果。 | 结构化、脱敏的社区报告；不含秘密或真实用户数据。 |
| `RELEASE_READY` | 当前候选满足平台发布准入。 | 构建、签名、回滚、已知限制和必要设备验收均完整。 |

一个功能可以同时拥有多个等级。例如，一个写操作可同时是 `IMPLEMENTED`、`AUTOMATED`
和 `BUILD_VERIFIED`，但只有在目标设备和专用 NAS 的真实结果形成后才能增加
`DEVICE_VERIFIED`。社区结论不会提升私有 API 的证据等级，也不会自动解除内部写接口
的默认关闭策略。

## 记录规则

每个需要发布判断的功能记录：

- 功能、平台与当前源码版本；
- 已获得的验证等级；
- 已运行命令或脱敏证据路径；
- 尚缺的签名、目标设备、DSM build、套件版本或权限；
- 已知限制、失败后的恢复方式和是否应保持关闭；
- 对危险写操作，确认、权限、重复提交保护、取消边界和最终状态复查。

动态测试数量、CI 标识和中间构建记录不进入活动状态页、矩阵或路线图；必要的历史上下文
只能保留在归档，不能用作当前结论。

## 平台应用

| 平台 | 自动化或构建可证明 | 仍需真实环境证明 |
| --- | --- | --- |
| macOS | 共享 Package、无签名 macOS 构建和仓库门禁。 | Developer ID、notarization、stapling、Gatekeeper、Finder/File Provider、真实 NAS 与升级。 |
| iPhone / iPad | 共享 Package 和对应模拟器构建。 | 真机、系统选择器、键盘、VoiceOver、动态文字、网络和真实 NAS。 |
| Android | 单元、增量编译、质量基线、本地化、fixture 与契约门禁。 | 真机、证书、后台、WorkManager、危险写和真实 DSM/套件行为。 |
| Windows | xUnit、WinUI XAML、x64/ARM64 构建。 | Windows 设备、Explorer、Cloud Files、通知、安装与真实 NAS。 |

## macOS 桌面云盘特别规则

桌面云盘在正式签名、App Group/Keychain、Finder/File Provider、升级回退和真实 NAS 验收
完成前，最多表述为 `IMPLEMENTED`、`AUTOMATED`、`BUILD_VERIFIED` 或
`SIGNING_REQUIRED`。不得称为 `DEVICE_VERIFIED` 或 `RELEASE_READY`。

完整手工步骤见[macOS 桌面云盘发布与升级验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)，
当前待验收边界见[发布与手工验收历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。
