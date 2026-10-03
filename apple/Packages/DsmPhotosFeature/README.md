# DsmPhotosFeature

macOS、iPhone 和 iPad 共用的 Synology Photos 状态机与上传恢复模块，依赖现有 DsmCore、DsmNetwork 和 DsmLocalization，不增加第三方库或 NAS 请求。

- `SynologyPhotosModel` 在主线程持有图库、分页、选择、管理操作、预览与上传状态；每个 NAS/账号会话使用独立实例。
- `PhotoUploadRecoveryStore` 保留既有版本 1 的队列、回执和字段。恢复先核对账号身份及旧操作，不自动重放未知上传；原件已上传时只补相册加入等剩余步骤。
- `PhotoUploadBookmarkAccess` 由平台注入：macOS 保持原安全范围只读书签，iOS 使用系统选择器授权。来源变化或授权失效时保留任务并要求重选，不自行扩大文件访问。
- 主 App 在首次加载前配置恢复存储；视图和系统导出/选择器留在各平台。网络身份、权限和重复提交保护继续由已有 Repository 实现。
- 本模块的公开 Swift 访问级别用于仓库内跨目标共享，不是新增 DSM 协议。原队列无需迁移；撤回模块拆分时可沿用旧文件格式。

运行 `swift test --package-path apple`，并分别构建 macOS 与 iPhone/iPad、执行两种模拟器回归。当前波次的命令和证据统一记录于[移动主计划](../../../docs/development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)及[验证历史](../../../docs/archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。
