# DsmFileFeature

M2 将 macOS 已有的 `FileUploadPlan` 和 `FileUploadBatch` 迁入此内部模块，供 macOS、iPhone 和 iPad 共用目录遍历、同名处理、父目录顺序、最多两个文件并发、逐项结果及未知上传的内容核对。没有复制第二套 NAS 上传实现，也未新增第三方依赖。

来源的安全范围授权由 `FileUploadSourceAccess` 保持。Mac 继续使用用户选择的原文件；移动端先保存独立受保护副本。平台层负责账号身份、选择器和存储位置，`FileUploadEntryCheckpoint` 只记录稳定状态。恢复后的未提交项暂停，已提交项只查询；可选 `beforeSubmission` 在移动端落盘失败时阻止写请求，Mac 不设置该回调，原流程保持。

文件协议和网络仍位于 `DsmCore`、`DsmNetwork`，本模块不改变公开 NAS 契约。共享改动须运行 Mac 上传回归和移动目标测试；当前实施与验证见[移动主计划](../../../docs/development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。

`FileArchiveBrowserModel` 同时共用压缩包分页、编码处理、条目选择和解压清单。Mac 保留原交互，仅引用迁移后的模型；移动端提供原生表单和目录选择。平台归档队列单独记录输出与完成回执，不存密码、不自动重发未知操作。共享模型不直接承担平台持久化或导航。

M6a2 将 Mac 原 `StorageAnalysisEngine` 及内存结果类型迁入本模块，两端使用同一共享遍历、搜索和内容摘要比较流程。Mac 只调整引用，旧容量小计和页面调用保留；分类使用稳定枚举，未知文件大小和部分重复比较单独标记，移动端不把不完整容量展示为零。分页声明未完成但没有条目时不生成空报告。分析不持久保存文件信息，不增加 NAS 文件写入、第三方依赖或旧数据迁移。
