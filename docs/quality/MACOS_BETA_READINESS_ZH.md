<!-- doc-role: release-readiness -->
<!-- last-reviewed: 2026-08-20 -->

# macOS 首个 Beta 就绪报告

> 更新日期：2026-08-20
> 结论：`PENDING_USER_VALIDATION`。当前候选已具备共享层、iPhone/iPad 模拟器和无签名
> macOS 构建证据；尚未满足正式签名、系统集成与真实 NAS 的 Beta 分发出口。

本报告只汇总当前可重跑的自动化、构建和只读对抗复核。它不包含 Developer ID 凭据、
notarization 凭据、会话、设备标识、NAS 信息、真实路径或用户数据，也不把无签名构建或
模拟器结果表述为设备、Finder 或发布验证。

## 当前可重跑证据

| 范围 | 已执行的命令或检查 | 当前结论 | 不能证明的内容 |
| --- | --- | --- | --- |
| Apple 共享层 | `swift test --package-path apple` | 通过；共享网络拆分后的 Package、macOS 回归和请求 fixture 契约可执行。 | 真实 DSM、认证、证书、私有 API 或副作用。 |
| iPhone | `xcodebuild` 无签名 Debug 模拟器构建 | 通过；通用移动工程可为 iPhone Simulator 编译。 | 真机登录、选择器、网络、触控、VoiceOver 或发布。 |
| iPad | `xcodebuild` 无签名 Debug 模拟器构建 | 通过；使用独立 iPad Simulator 目标编译，未以 iPhone 替代。 | 分栏、多任务、硬件键盘、动态文字、VoiceOver 或发布。 |
| macOS | `xcodebuild` 无签名 Debug 构建 | 通过；主 App 与嵌入扩展的编译路径可执行。 | Developer ID、entitlement 运行时注册、公证、票据、Gatekeeper、Finder/File Provider 或安装升级。 |
| 桌面云盘 | 现有 Desktop Cloud Drive 单元与合成边界测试 | 通过；取消、回滚、空间保护和恢复的代码级约束仍可重跑。 | 系统 File Provider 调度、真实卷、真实网络传输或物理缓存状态。 |

iPad 构建仅出现既有的 `await` 无异步操作编译警告，未产生构建错误。本轮不为无关警告
改变移动代码、签名配置或最低系统版本。

## 只读对抗复核

| 边界 | 复核证据 | 结论 |
| --- | --- | --- |
| File Provider 与 App Group | `DesktopCloudDriveAvailability` 只有嵌入 Extension 与共享容器同时可用才开放；缺任一项即关闭入口。 | 无签名构建不会假装具备系统集成能力。 |
| 认证、会话与跨 NAS | `DesktopDriveSessionBridge` 以 profile 标识保存和清理最小必要会话；映射事务测试覆盖会话发布、回滚、恢复和最后映射清理。 | 未观察到跨 profile 合并会话或绕过证书确认的路径；真实 Keychain 行为仍待验收。 |
| 后台、取消与恢复 | `DesktopCloudDriveManager` 对每个映射保留离线任务所有权，取消后通过既有回滚与状态机处理；测试覆盖取消请求、固定范围回滚失败和重连失败。 | 代码级取消语义保持，不能推断 Finder 或系统网络传输已经停止。 |
| 危险写与结果确认 | NAS、文件、下载、容器和虚拟机路径继续通过能力、确认、权限、重复提交和回读结果建模；未确认结果不会被映射为成功。 | 未记录或未行为验证的高风险内部写继续关闭。 |
| 私有 API | 私有 API 记录要求新 DSM 或套件版本默认关闭内部写，并禁止在断线、超时或取消后自动重放。 | 本轮没有连接 DSM、读取真实响应或触发任何写请求。 |

这只是只读代码和测试复核；它不是安全审计、渗透测试或真实系统的行为验证。

## `PENDING_USER_VALIDATION` 清单

| 前置条件 | 用户操作 | 预期结果 | 允许回传的脱敏信息 |
| --- | --- | --- | --- |
| Developer ID Application 证书与候选包 | 按[桌面云盘发布与升级验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)生成正式签名候选包。 | 主 App 与 Extension 的签名身份一致。 | 成功/失败、macOS 大版本和架构类别、通俗错误摘要。 |
| 受控 notarization 凭据 | 对候选 DMG 完成公证、票据装订和 Gatekeeper 检查。 | 干净测试用户可安装并启动候选包。 | 用例 ID、成功/失败、错误类别；不得回传凭据、Team ID 全值或日志正文。 |
| 专用 Mac、专用 NAS 账号与可丢弃数据 | 按[正式签名验收执行矩阵](../development/MACOS_DESKTOP_CLOUD_DRIVE_SIGNED_ACCEPTANCE_MATRIX_ZH.md)验证 Finder、File Provider、App Group、共享会话、取消、恢复、升级与回退。 | 映射创建、浏览、暂停、恢复和移除均收敛，危险写只在明确授权后回读确认。 | 用例 ID、最终状态、连接/证书/缓存卷类别、清理状态与脱敏失败摘要。 |
| iPhone 与 iPad 设备 | 分别验证登录、系统选择器、网络切换、VoiceOver、动态文字、键盘和宽屏交互。 | 对应设备上的移动核心与受限能力符合平台范围。 | 设备类别、系统大版本、用例 ID、成功/失败和可复现的脱敏步骤。 |

若出现凭据暴露、签名或 Extension 身份不一致、映射可能影响非测试数据、无法安全清理、
未知系统状态或危险写结果无法回读，立即停止相关验收并保持不发布。

## 发布出口

在上表中的正式签名、系统集成、真实 NAS、升级回退和清理证据都完成前：

- 不创建公开 macOS Beta，不启动 TestFlight 或其他分发；
- 不把无签名构建、模拟器或合成测试升级为 `DEVICE_VERIFIED` 或 `RELEASE_READY`；
- 未验证内部写、File Provider 与真实系统集成继续保持关闭、只读或能力门保护；
- 使用[发布与手工验收历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)保存可复用的
  脱敏结论，不复制临时日志、测试数量或 CI 标识。

## 相关材料

- [macOS 桌面云盘发布与升级验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [macOS 桌面云盘正式签名验收执行矩阵](../development/MACOS_DESKTOP_CLOUD_DRIVE_SIGNED_ACCEPTANCE_MATRIX_ZH.md)
- [验证等级](VERIFICATION_LEVELS_ZH.md)
- [平台功能矩阵](../progress/PLATFORM_MATRIX.md)
