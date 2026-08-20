<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-08-20 -->

# Android 原生客户端

Android 客户端使用 Kotlin、Jetpack Compose、Coroutines、OkHttp 和 Android Keystore。
当前 `applicationId` 为 `io.github.qwertyuiop1995.dsmnativeclient`，最低 Android 版本为
API 29；这些标识和最低版本不是本轮修改范围。

## 代码边界

```text
app/src/main/.../domain/    领域模型、状态和统一错误语义
app/src/main/.../network/   DSM Web API 传输、登录与解析
app/src/main/.../storage/   Keystore 保护的会话与本机偏好
app/src/main/.../data/      DsmRepository 门面与按领域拆分的 Repository
app/src/main/.../ui/        Compose 平台原生界面
```

`DsmRepository` 与 `AppViewModel` 是既有 Compose 兼容门面。结构拆分必须保留公开签名、
DSM 请求契约、`MutationResult` 映射、持久化键、状态顺序、WorkManager 唯一任务名以及
取消、重试和退出语义。

## 当前范围

- 登录、HTTPS、QuickConnect、会话恢复和平台安全存储。
- Files、Photos、Chat、Download Station、NAS 设置、传输中心和应用设置的既有用户路径。
- Container Manager 与 VMM 的只读摘要；未完成功能行为验证的 Container 内部写入口保持
  三层关闭，不向 NAS 发送写请求。
- 文件、下载、Chat、NAS 设置和 VMM 的开放写操作使用确认、权限、重复提交保护和最终
  结果回读；模糊提交或提交后取消只允许核对，不自动重放。
- Android 界面继续遵守 Material、触控、动态字体、深浅色、TalkBack 与降低动效要求。

范围、后续候选和非目标请查看[平台功能矩阵](../docs/progress/PLATFORM_MATRIX.md)。当前
源码、自动化、真机和发布状态请查看[当前开发进度](../docs/progress/STATUS.md)。

## 质量门

Android 质量基线是机器可读数据：

```bash
python3 tools/codex/generate_android_quality_baseline.py --check
python3 tools/codex/check_android_write_test_matrix.py
python3 tools/codex/check_android_page_state_matrix.py
python3 tools/codex/check_android_touch_targets.py
python3 tools/codex/check_android_motion_audit.py
python3 tools/codex/check_android_structure_debt.py
python3 tools/localization/check_localization.py
```

本机默认只运行低负载的增量编译和聚焦测试：

```bash
./gradlew :app:compileDebugKotlin
./gradlew :app:testDebugUnitTest --tests '<聚焦测试类>'
```

完整 JVM、Debug、Release/R8、仪器测试 APK 与 lint 交由 GitHub 托管 Runner。在专用
`codex/` 验证分支执行前，检查不含凭据、本机配置或一次性产物；不要把本机增量结果
表述为完整 Android 发布验证。

## 真实环境边界

真实设备、证书、WorkManager、后台限制、系统选择器、跨 NAS、真实 DSM/套件返回和
危险写副作用均为 `PENDING_USER_VALIDATION`。缺少这些环境不阻塞独立源码和自动化工作，
但未验证的高风险入口必须继续关闭、只读或受能力门保护。

## 相关文档

- [Android 长期计划](../docs/development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)
- [Android 质量基线](../docs/quality/ANDROID_QUALITY_BASELINE_ZH.md)
- [功能实现与验证等级](../docs/quality/VERIFICATION_LEVELS_ZH.md)
- [请求契约与写操作结果计划](../docs/development/REQUEST_CONTRACT_AND_MUTATION_RESULT_PLAN_ZH.md)
- [历史对齐记录](../docs/archive/2026-h2/ANDROID_ALIGNMENT_HISTORY_82_89.md)
