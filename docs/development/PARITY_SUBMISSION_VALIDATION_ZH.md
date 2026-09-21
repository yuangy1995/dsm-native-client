<!-- doc-role: validation-report -->
<!-- last-reviewed: 2026-09-21 -->

# 跨端修复提交与推送验证记录

## 提交范围与授权

用户已明确要求生成提交记录并推送，并授权先修复 Android 下载创建请求版本不一致，
全部云端门禁通过后推送 main，再删除专用测试分支。不发布版本、不提交包、凭据、
真实用户数据或临时抓包；已有源码和正式自动化测试均保留。

正式提交包含 Windows 已完成的功能对齐、云盘同步与恢复，Mac 文件下载/照片及同类
API 修复，共享契约/五端影响文档，以及本轮 Android 下载创建兼容修复。详细原有
证据见 [Windows 最终范围核对](WINDOWS_PARITY_FINAL_REVIEW_ZH.md) 与
[Apple 集成验证](APPLE_PARITY_INTEGRATION_VALIDATION_ZH.md)。

## 本轮 Android 修复

- 根因：共享 fixture 已要求带 destination 的公开 create 使用 v2；Android 链接创建
  未固定版本，原合成能力仅 v1；任务文件上传还直接使用 maxVersion。
- 按 [Synology 官方指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/DownloadStation/All/enu/Synology_Download_Station_Web_API.pdf)
  的 destination 自 v2 提供规则修复，不改变现有公开契约。无目录固定 v1，有目录固定
  v2，能力区间不覆盖时提交前拒绝；不把 v1 请求移到错误目录、不盲目使用最高版本。
- 复用现有 Repository、传输层、错误分类、重复提交保护与任务 ID 回读，不增加依赖、
  持久化结构、系统权限或可见文案，不改变内部 DownloadStation2 备用接口。
- 新增五项测试覆盖默认目录、v1-only、能力下限不匹配、multipart 版本及零请求/零文件
  读取拒绝；原 fixture 断言保持不变，原 multipart 测试补充 v2 断言。
- 结构门禁要求既有大文件不得增长：将创建请求摘要函数原样提取为同包独立函数，
  不改变摘要算法、输入或防重语义；通过既有生成器收紧行数基线，不上调限额。
- 五端影响：Android 追平已实现的 macOS/iPhone/iPad/Windows 公开请求语义；其他四端
  源码本轮不作额外修改。PENDING_USER_VALIDATION：用可丢弃链接/任务文件在真实 NAS
  创建，核对实际目录与只创建一次；失败仅回传版本、步骤及脱敏错误。

## 验证与交付状态

本轮在专用 codex/ 分支运行完整云端门禁，当前等待结果；未提前推送 main。
Android 使用既有 Android Build：JVM、Debug/Release/R8、androidTest APK 构建、lint；
仪器 APK 构建不代表真机仪器测试已执行。合并前核查远端 main 无新提交、所有相关
云端门禁通过，并确认最终提交内容与已验证源码一致。
