# 项目文档

文档按职责维护，避免在多处重复记录实现状态：

- 当前完成情况、测试结果和阻塞项以[当前开发进度](progress/STATUS.md)为准。
- 后续优先级以[产品路线图](progress/ROADMAP.md)为准。
- 各平台能力差异以[平台功能矩阵](progress/PLATFORM_MATRIX.md)为准。
- API、安全、兼容和架构文档保存长期有效的工程事实。

## 当前状态与计划

- [当前开发进度](progress/STATUS.md)
- [产品路线图](progress/ROADMAP.md)
- [平台功能矩阵](progress/PLATFORM_MATRIX.md)
- [当前开发与验收计划](development/NATIVE_DSM_FILE_APP_DEVELOPMENT_PLAN_ZH.md)

## 专项开发计划

- [Windows / Apple 移动端第 1 波功能对齐账本](development/CROSS_PLATFORM_PARITY_WAVE_1_LEDGER_ZH.md)
- [Windows / Apple 移动端第 0 波功能对齐账本](development/CROSS_PLATFORM_PARITY_WAVE_0_LEDGER_ZH.md)
- [macOS 业务语义向 Windows 与 Apple 移动端复制总计划](development/MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)
- [Windows 对齐 macOS 专项计划](development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [iPhone / iPad 对齐 macOS 专项计划](development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [Android 原生客户端完善、进度记录与跨电脑交接计划](development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)
- [Android 第 85 批功能对齐账本](development/ANDROID_WAVE_85_ALIGNMENT_LEDGER_ZH.md)
- [Android 点击目标审计矩阵](development/ANDROID_TOUCH_TARGET_AUDIT_MATRIX_ZH.md)
- [Android 写操作测试审计矩阵](development/ANDROID_WRITE_MUTATION_TEST_MATRIX_ZH.md)
- [桌面端 NAS 云盘映射与按需缓存开发计划](development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)
- [请求契约与写操作结果模型实施计划](development/REQUEST_CONTRACT_AND_MUTATION_RESULT_PLAN_ZH.md)
- [照片管理开发计划](development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)
- [Synology Chat 原生聊天功能开发计划](development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)
- [DSM 套件管理三端实现计划](development/NATIVE_DSM_SERVICE_MANAGEMENT_PLAN_ZH.md)
- [“统一存储管理”新功能三端实现计划](development/NATIVE_DSM_STORAGE_MANAGEMENT_PLAN_ZH.md)

专项计划只保存范围、设计约束、未完成工作和验收条件，不作为当前完成状态的事实来源。

## 工程参考

- [DSM Web API 参考](api/DSM_WEB_API_REFERENCE_ZH.md)
- [DSM 与套件私有 API 发现规范](api/discovery/README.md)
- [总体架构](architecture/ARCHITECTURE.md)
- [DSM 兼容矩阵](compatibility/DSM_COMPATIBILITY_MATRIX.md)
- [社区兼容性计划（中文）](compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_ZH.md)
- [Community Compatibility Program (English)](compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_EN.md)
- [社区兼容矩阵](compatibility/COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)
- [macOS 桌面云盘发布与升级验收](compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [Community Compatibility Matrix](compatibility/COMMUNITY_COMPATIBILITY_MATRIX_EN.md)
- [功能实现与验证等级](quality/VERIFICATION_LEVELS_ZH.md)
- [安全与隐私基线](security/SECURITY_BASELINE.md)

## 历史归档

- [第一阶段开发文档（2026-07-16）](archive/NATIVE_DSM_FILE_APP_DEVELOPMENT_PLAN_V1_ARCHIVE_ZH.md)

归档只用于追溯，不代表当前实现。完成有效设计迁移、清除活动引用并建立可追溯版本标签后，可以从当前文档树移除归档全文。

## 架构决策

- [ADR-0001：使用单仓库](architecture/decisions/0001-monorepo.md)
- [ADR-0002：使用平台原生技术栈](architecture/decisions/0002-native-stacks.md)
- [ADR-0003：官方 API 优先](architecture/decisions/0003-official-api-first.md)
- [ADR-0004：应用身份与首个参考平台](architecture/decisions/0004-app-identity-and-reference-platform.md)

文档与源码放在同一个 Git 提交中维护。
