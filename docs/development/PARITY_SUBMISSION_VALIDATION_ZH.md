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

功能提交：`a5f3935a945b357c8aef1e063da4e6611cd3ccf3`，标题为
`feat: 完成 Windows 功能对齐并修复跨端 NAS 操作契约`。临时结构门禁修正已整理进
同一功能提交；验收记录单独作为文档提交，不保留 retry/fix CI 中间提交。

| 门禁 | 运行 | 结果 |
| --- | --- | --- |
| Windows Build | [35605280483](https://github.com/yuangy1995/dsm-native-client/actions/runs/35605280483) | 3929 项全部通过；WinUI x64/ARM64 均 0 警告、0 错误。 |
| Android Build | [35605280419](https://github.com/yuangy1995/dsm-native-client/actions/runs/35605280419) | HTML 报告确认 1424 项、0 失败、0 跳过；Debug、Release、R8、androidTest APK、lint 均通过。 |
| Apple Build | [35605280383](https://github.com/yuangy1995/dsm-native-client/actions/runs/35605280383) | XCTest 1281 项中 1224 通过、57 项既有条件跳过、0 失败；Swift Testing 12 项通过；iPhone/iPad 各 498 项通过；工程一致性、Mac 打包及临时签名产物检查通过。 |
| Repository Check | [35605280398](https://github.com/yuangy1995/dsm-native-client/actions/runs/35605280398) | 通过。 |
| Documentation & Quality Preflight | [35605280323](https://github.com/yuangy1995/dsm-native-client/actions/runs/35605280323) | 通过。 |

Android 实际命令：`./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease
:app:minifyReleaseWithR8 :app:assembleDebugAndroidTest :app:lintDebug --no-parallel --stacktrace`。
Windows 实际命令沿用仓库 Windows Build：Release xUnit 与 win-x64/win-arm64 构建。
本地额外执行质量工具 105 项、脱敏工具 3 项、响应契约 13 项、请求契约 13 项测试，均通过；
111 请求 fixture、3 响应组、22 私有引用、本地化、结构与严格文档检查均通过。

仪器 APK 构建不代表真机仪器测试已执行。合并前核查远端 main 无新提交、所有相关
云端门禁通过，并确认最终源码与已验证功能提交一致；只快进推送，不强推 main。
推送完成后按授权删除本次专用分支和隔离工作树；真实设备与正式发布仍独立验收。

完整功能提交的五组云端门禁均已通过。后续验收记录提交仅修改本报告、前一阶段总结
与进度/矩阵，不修改源码、契约、工作流或测试；再运行仓库和文档门禁，保留上述准确
提交级证据。Apple 临时签名包不含本地挂载扩展，57 项条件跳过不记为通过。
