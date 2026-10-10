<!-- doc-role: documentation-index -->
<!-- last-reviewed: 2026-10-10 -->

# 项目文档

开发其他平台时，从[按功能 API 参考](api/README.md)查 macOS 当前请求与业务语义，再读对应平台计划。源码/契约是事实来源；页面存在、合成测试与真实 NAS 验证分开记录。

## 当前状态与计划

- [开发进度](progress/STATUS.md)、[平台功能矩阵](progress/PLATFORM_MATRIX.md)、[产品路线图](progress/ROADMAP.md)
- [macOS 使用与功能说明](../apple/Apps/DsmMac/README.md)、[iPhone/iPad 使用与构建](../apple/Apps/DsmMobile/README.md)
- [跨端总控](development/MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)、[Windows 计划](development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)、[iPhone/iPad 计划](development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)、[Android 计划](development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)
- [Photos](development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)、[Chat](development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)、[下载、容器与虚拟机](development/NATIVE_DSM_SERVICE_MANAGEMENT_PLAN_ZH.md)、[存储管理](development/NATIVE_DSM_STORAGE_MANAGEMENT_PLAN_ZH.md)、[桌面挂载与缓存](development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)

- 移动系统集成：[普通传输与分享](development/APPLE_MOBILE_SYSTEM_TRANSFERS_ZH.md)、[Files 与原位编辑](development/APPLE_MOBILE_FILES_PROVIDER_ZH.md)、[照片/跨 NAS/Office 后台](development/APPLE_MOBILE_BACKGROUND_EXECUTORS_ZH.md)

## API 与架构

- [功能 API 目录](api/README.md)：通用标准、认证、文件、照片、聊天、下载、容器、虚拟机、系统、存储与生成的请求参数目录
- [共享领域契约](../contracts/README.md)、[私有 API 发现规范](api/discovery/README.md)、[端点记录](api/discovery/endpoints/INDEX.md)、[环境记录](api/discovery/environments/INDEX.md)
- [架构与 ADR](architecture/ARCHITECTURE.md)、[安全与隐私](security/SECURITY_BASELINE.md)、[DSM 兼容矩阵](compatibility/DSM_COMPATIBILITY_MATRIX.md)
- [历史 API 来源](api/DSM_WEB_API_REFERENCE_ZH.md)：仅为既有证据索引保留，不作为当前开发入口

## 验证与发布

- [验证等级](quality/VERIFICATION_LEVELS_ZH.md)、[Android 质量基线（生成）](quality/ANDROID_QUALITY_BASELINE_ZH.md)
- [macOS 发布就绪与安全整改](quality/MACOS_BETA_READINESS_ZH.md)、[桌面云盘发布/升级及现场矩阵](compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)、[性能基准](quality/DESKTOP_CLOUD_DRIVE_BENCHMARK_ZH.md)
- [Apple CI 签名配置](development/APPLE_GITHUB_ACTIONS_SIGNING_ZH.md)、[macOS 发布与升级](releases/MACOS_GITHUB_RELEASE_ZH.md)
- [历史验证记录](archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)：已执行的提交/测试/包及手工反馈；不作为新候选通过的证明

## 历史与查证

- [macOS 功能与使用反馈](archive/2026-h2/MACOS_FEEDBACK_HISTORY.md)：原八份日期账本合并，保留当时范围、结果和未验条件。
- [移动 M0–M8 实施历史](archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md)：逐波决策、交接和原失败。
- [移动 Files 调查历史](archive/2026-h2/APPLE_MOBILE_FILES_INVESTIGATION_HISTORY.md)：平台适配对照与系统生命周期调查。
- [验证历史](archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)：精确提交、命令、CI 与发布产物。历史的“当前”和授权只针对记录当时，不作为后续任务许可。

## 维护约定

文档日期（包括 `last-reviewed`）统一按北京时间 UTC+08:00 记日。检查器使用同一日历，不随本机或云端 Runner 时区变化；真实未来日期仍拒绝，状态与矩阵的时效要求不变。

状态只写当前结论，矩阵只写平台范围和证据边界，长期计划只写不变量/差距/执行顺序，功能 API 只写当前调用和恢复规则。一次性施工说明合并到上述位置，避免新建同主题日期文档。私有端点和环境保留版本历史，不为减少文件数合并掉证据。

请求参数目录通过 `python3 tools/codex/generate_api_reference.py` 生成，修改后运行 `--check` 与 `python3 tools/codex/check_documentation.py --strict-release`。归并文档前先迁移独有事实、更新入链，再删除来源。
