<!-- doc-role: quality-policy -->
<!-- last-reviewed: 2026-10-16 -->

# 验证原则与验收方法

功能状态只在[矩阵](../progress/PLATFORM_MATRIX.md)维护；当前问题和 `PENDING_USER_VALIDATION` 步骤只在[限制清单](../progress/KNOWN_LIMITATIONS.md)维护。源码、自动化、构建、设备和发布分别说明，不由测试数量或页面存在推定“全部完成”。

| 证据 | 能证明什么 | 不能替代什么 |
| --- | --- | --- |
| 源码复核 | 生产入口、请求、结果与安全边界已接通 | 实际运行、接口兼容 |
| 聚焦/完整自动化 | 指定提交和用例范围内的实际结果 | 未运行场景、真实 NAS 和设备 |
| 目标构建 | 指定工具链/架构/签名类型能够构建 | 安装、升级、系统注册与使用 |
| 设备/NAS 验收 | 记录环境下的真实用户结果 | 其他平台、版本、权限或网络 |
| 发布验收 | 指定候选的签名、公证、包内容、更新和回退证据 | 后续未发布源码及全部业务行为 |

历史 `IMPLEMENTED/AUTOMATED/BUILD_VERIFIED/DEVICE_VERIFIED/RELEASE_READY` 标签按上表解释；`SIGNING_REQUIRED` 和 `PENDING_USER_VALIDATION` 只是缺少条件，不能当作通过等级。

修改后运行相关行为测试、目标构建与必要原生场景。UI 必须实际检查加载、空内容、筛选空、错误和正常状态，以及双语/主题、焦点和可见边界；资源存在、截图文件生成或进程正常退出不证明界面正确。高风险操作另核对提交前拒绝、权限/对象变化、防重、接受与最终结果、取消/断网、部分完成及恢复。

结果记录只需：**源码/包身份、命令或工作流链接、平台/架构、通过/失败/跳过及范围、未解决问题**。失败修正后的定点结果不改写原失败，也不冒称完整重跑；条件跳过不算通过。CI 只覆盖其来源提交，运行中日志片段不证明任务卡住；取消不是通过。

当前 Checks、发布资产及正式测试是证据入口，不在多个 README、计划和矩阵复制逐轮次数、耗时与临时路径。已结束的调试流水不作为永久开发文档；未解决问题及兼容/迁移决策保留在相应唯一说明。

## 可重跑入口

平台命令见 [Apple](../../apple/README.md)、[Android](../../android/README.md)、[Windows](../../windows/README.md)。仓库级执行：

```sh
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

Android 写入口、页面状态、触控、动效与结构检查继续读取[机器基线](../../tools/codex/android_quality_baseline.json)；可读报告按需生成，不能把人工登记或静态扫描等同业务通过。Documentation & Quality Preflight 不是签名/设备/发布门禁。

桌面云盘合成大目录基准按需运行：

```sh
LANSTASH_RUN_DESKTOP_DRIVE_BENCHMARKS=1 swift test --package-path apple --filter DesktopCloudDrivePerformanceTests
```

它验证 200 页、100000 条合成元数据完整进入缓存；耗时只与同机同配置比较，不是 CI 性能硬门槛。真实 Finder/Explorer 首次枚举、连续滚动、取消和内存压力另按[云盘验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)执行。
