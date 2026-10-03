# DsmFileFeature

M2 将 macOS 已有的 `FileUploadPlan` 和 `FileUploadBatch` 迁入此内部模块，供 macOS、iPhone 和 iPad 共用目录遍历、同名处理、父目录顺序、最多两个文件并发、逐项结果及未知上传的内容核对。没有复制第二套 NAS 上传实现，也未新增第三方依赖。

来源的安全范围授权由 `FileUploadSourceAccess` 保持。Mac 继续使用用户选择的原文件；移动端先保存独立受保护副本。平台层负责账号身份、选择器和存储位置，`FileUploadEntryCheckpoint` 只记录稳定状态。恢复后的未提交项暂停，已提交项只查询；可选 `beforeSubmission` 在移动端落盘失败时阻止写请求，Mac 不设置该回调，原流程保持。

文件协议和网络仍位于 `DsmCore`、`DsmNetwork`，本模块不改变公开 NAS 契约。共享改动须运行 Mac 上传回归和移动目标测试；当前实施与验证见[移动主计划](../../../docs/development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。
