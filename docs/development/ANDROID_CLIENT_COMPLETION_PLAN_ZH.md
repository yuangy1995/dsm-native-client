<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-08-20 -->

# Android 原生客户端长期计划

## 用途与事实来源

本计划记录 Android 后续源码拆分、验证和发布条件，不记录动态完成率、CI 标识或历史测试
数量。当前状态见[开发进度](../progress/STATUS.md)，跨端范围见[平台功能矩阵](../progress/PLATFORM_MATRIX.md)，
已结束的对齐记录见[历史归档](../archive/2026-h2/ANDROID_ALIGNMENT_HISTORY_82_89.md)。

源码、契约、脱敏 fixture、自动化与可重现命令是事实来源；真实 NAS、签名或真机未执行时
必须明确标记 `PENDING_USER_VALIDATION`，不得把模拟器或静态阅读写成通过。

## 不变量

- 保持 `DsmRepository` 为兼容门面，不能改变公开签名、DSM API 名称/版本/参数、错误语义
  或 `MutationResult` 映射。
- 保持持久化键、状态顺序、StateFlow 身份、导航、WorkManager 唯一任务名以及取消、重试、
  退出和恢复语义。
- 不新增 Gradle 模块、第三方依赖、最低系统版本、包名、Bundle ID、签名配置或数据格式。
- 写操作必须保留确认、权限检查、重复提交保护和最终状态校验；未验证内部写默认关闭。
- 用户可见文案只通过英语和简体中文资源提供，不能加入 Kotlin/Compose 硬编码显示文案。

## 当前代码边界

```text
AppViewModel.kt                 Compose 兼容入口与跨领域协调
data/DsmRepository.kt           兼容门面与共享网络能力
data/downloads/                 已拆出的 Download Station Repository
data/container/                 已拆出的 Container Repository
data/PhotoRepository.kt         已拆出的照片读取能力
PhotoBackup*.kt                 照片备份与唯一后台任务所有权
*ViewModelState.kt              按领域状态与纯策略函数
ui/                             Compose 页面与组件
```

`AppViewModel` 和 `DsmRepository` 已是结构债务热点。任何拆分都应缩小其行数，不得让
既有巨型文件增长；新生产 Kotlin 文件超过行数上限时必须在质量基线中声明清晰理由。

## 质量基线

[Android 质量基线](../quality/ANDROID_QUALITY_BASELINE_ZH.md) 由
`tools/codex/android_quality_baseline.json` 生成，记录：

- 每个写调用点的调用文件、所属函数、`Result` 方法、开放状态、适用场景和测试证据；
- 页面五态、点击目标与显式时间动效的机器数据；
- 既有大文件上限和新增超大文件例外；
- 对新增或移动写入口的人工审查要求，而不是整文件 SHA-256 比较。

修改相关代码前后均运行：

```bash
python3 tools/codex/generate_android_quality_baseline.py --check
python3 tools/codex/check_android_write_test_matrix.py
python3 tools/codex/check_android_page_state_matrix.py
python3 tools/codex/check_android_touch_targets.py
python3 tools/codex/check_android_motion_audit.py
python3 tools/codex/check_android_structure_debt.py
python3 tools/localization/check_localization.py
```

## 源码拆分顺序

### 1. DsmRepository 共享底座

先抽出以下无 UI 依赖的内部组件，并由门面委托：

1. response decoder；
2. request builder；
3. capability resolver；
4. mutation verifier。

组件只接受现有网络、会话和模型依赖。不得复制请求、增加 fallback、提高 API 版本或改变
参数编码。每次移动后运行受影响 fixture、契约和 Repository 聚焦测试。

### 2. 领域 Repository

在共享底座稳定后，按以下顺序从门面提取实现：

1. VMM；
2. NAS Administration；
3. Chat；
4. File Station。

复用既有 `PhotoRepository`、`DownloadStationRepository` 和 `ContainerRepository`，不再为
同一能力建立平行 Repository。门面仅保留向后兼容的委托；每个领域均保持相同 API 名称、
版本、参数和 `MutationResult` 语义。

### 3. AppViewModel 任务所有权

先迁移 Transfer 与 Photo Backup 等 Job、锁和序列号所有者明确的路径，再依次迁移：

1. Files；
2. Chat；
3. Downloads；
4. NAS Administration；
5. Container；
6. VMM。

每个任务只保留一个 owner。迁移时必须证明 `onCleared`、取消、重试、进程恢复、迟到结果
拒绝、持久化和 WorkManager 名称均未改变。跨 NAS、后台、认证和危险写路径在平台构建或
实机验收前需要额外只读对抗复核。

### 4. Compose 机械拆分

在状态和事件边界稳定后，按“状态输入 / 事件输出”机械拆分 Chat、Files 和 Photos 大型
页面文件。拆分前运行 `tools/codex/ensure_ui_ux_pro_max.py` 并完整阅读安装后的 Skill；
拆分不改变布局、文案、动效、导航、可访问性或交互。

每个页面继续覆盖加载、空内容、筛选后为空、错误和正常内容。新增页面、弹窗、自定义点击
或时间动效必须先更新 JSON 基线与生成报告。

- [x] 每页覆盖加载、空内容、筛选后为空、错误和正常内容五种状态；

## 验证策略

| 范围 | 本机 | 托管 Runner | 用户验证 |
| --- | --- | --- | --- |
| 纯 Kotlin / Repository | 聚焦单测、fixture、契约与增量编译。 | 完整 JVM 与 Release/R8。 | 仅真实 DSM/套件行为。 |
| Compose | 静态质量门、聚焦页面策略测试。 | Debug、仪器 APK 与 lint。 | TalkBack、动态字体、触控、横竖屏与 OEM 行为。 |
| WorkManager / 传输 | 取消、唯一任务名、恢复策略和持久化测试。 | 构建与仪器包。 | Doze、低电量、重启、系统选择器与实际后台限制。 |
| 危险写 / 私有 API | fixture、能力门、结果映射与只读对抗复核。 | 完整契约和 Android 门禁。 | 专用 NAS 的权限、断线、重复提交和最终回读。 |

完整 Android JVM、Debug、Release/R8、仪器 APK 与 lint 默认由 GitHub 托管 Runner 执行。
用户已授权仅为验证创建并推送专用 `codex/` 分支；其中不能含凭据、本机设置、临时日志或
无关更改。完成验证后应整理当前功能分支的临时提交，不改写共享历史。

## 发布与真实环境

以下项目均是 `PENDING_USER_VALIDATION`，不是源码阻塞：

- Android 真机登录、认证恢复、证书确认与网络切换；
- 真实 DSM / 套件 build 的公开与内部 API 行为；
- WorkManager、后台传输、照片备份和跨 NAS 的系统行为；
- 高风险写操作的权限、确认、重复提交保护、断线、取消和最终回读；
- TalkBack、最大字体、显示缩放、折叠屏、平板和 OEM 触控。

未验证高风险入口必须保持关闭、只读或受能力开关保护。用户回传信息只包含环境类别、
步骤、预期/实际用户可见结果和脱敏失败语义，不能包含 SID、Cookie、地址、路径、账号、
真实文件名或原始响应。

## 交接要求

每个 Android 切片结束时记录：

1. 实际修改与单一文件边界；
2. 保持的契约、状态和任务所有权；
3. 实际运行命令及结果；
4. 未验证风险与 `PENDING_USER_VALIDATION` 条件；
5. 工作区状态、剩余步骤和不得触碰的并发修改。
