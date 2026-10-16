<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-16 -->

# Android 原生客户端

Kotlin、Jetpack Compose、Coroutines、OkHttp 与 Android Keystore。包名为 `io.github.qwertyuiop1995.dsmnativeclient`，最低 API 29；Debug 使用 `.debug` 后缀。当前 compile/target API 37，JVM 输出 17，工具版本以[Gradle 配置](app/build.gradle.kts)、[插件](build.gradle.kts)、[Wrapper](gradle/wrapper/gradle-wrapper.properties)和[CI](../.github/workflows/android-build.yml)为准。

功能只在[五端矩阵](../docs/progress/PLATFORM_MATRIX.md)维护，当前错误与真实环境条件见[限制清单](../docs/progress/KNOWN_LIMITATIONS.md)。界面沿[用户确认的 UI](../docs/design/ANDROID_UI_SPEC_ZH.md)；首页显隐和导航偏好独立于 NAS 权限。

## 使用与系统边界

每个 NAS/账号拥有独立会话、授权、页面和任务。切换不是退出；改账号/地址后旧任务不会接管新身份。通知只定位原账号，不显示消息正文。Photos 独立授权，文件权限不代替照片权限。

跨 NAS 移动先复制和校验，再独立确认删源。任务未知时只读取恢复，不通过重登、改名或重新创建请求重发。目录备份使用 File Station；它与 Photos 套件上传是两条不同功能。

系统分享接收用户选择的副本，再明确选择 NAS/目录上传。DocumentsProvider 默认只读，单独允许 Office 编辑后仍需回到原账号主动保存；关闭系统入口不能收回已交付其他 App 的内容。当前不提供离线目录浏览或编辑器关闭后自动回传。后台/前台服务受系统资格、省电与超时限制，进程终止不自动重放照片、Office 覆盖或跨 NAS 删源。完整差异见[平台集成](../docs/development/PLATFORM_INTEGRATION.md)。

## 开发与验证

安装 [CI](../.github/workflows/android-build.yml) 使用的 Java 与 Android SDK；本机 `local.properties`、签名材料和真实配置不提交。在 `android` 目录运行：

```sh
./gradlew :app:compileDebugKotlin
./gradlew :app:testDebugUnitTest --tests '<聚焦测试类>'
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
```

Windows 使用 `gradlew.bat`。完整 JVM、Release/R8、仪器包与 lint 优先交托管 Runner；设备测试只使用专用模拟器/测试账号。Release 在未提供私有 keystore 时使用 debug 签名便于测试，不能据此称为正式发布。

仓库根目录的质量检查：

```sh
python3 tools/codex/generate_android_quality_baseline.py --check
python3 tools/codex/check_android_write_test_matrix.py
python3 tools/codex/check_android_page_state_matrix.py
python3 tools/codex/check_android_touch_targets.py
python3 tools/codex/check_android_motion_audit.py
python3 tools/codex/check_android_structure_debt.py
python3 tools/localization/check_localization.py
```

[机器基线](../tools/codex/android_quality_baseline.json)维护实际写入口、页面状态和结构限制；运行生成器可在 `build/reports/android-quality.md` 查看报告，不维护第二份手写质量表。各模块源码位于 `app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient` 的 domain、network、storage、data、ui 及功能目录；`DsmRepository` 与 `AppViewModel` 保留既有组合职责。

API 参数与恢复语义见[API 目录](../docs/api/README.md)，证据范围见[验证原则](../docs/quality/VERIFICATION_LEVELS_ZH.md)。系统权限、长期后台、真实 NAS、第三方编辑器和物理 TalkBack 需要单独验收，聚焦测试数量不代表完整覆盖。
