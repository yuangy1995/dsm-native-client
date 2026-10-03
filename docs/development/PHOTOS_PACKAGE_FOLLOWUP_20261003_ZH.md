# 照片与套件更新二次反馈修复（2026-10-03）

源码、聚焦与完整回归、独立测试包均已完成。工作区沿用 `codex/nas-settings-web-audit`，保留前轮全部未提交改动与测试包；本轮没有暂存、提交或推送。

## 反馈、证据与修复

### 照片底部“无法加载照片库”

在用户正在运行的上一轮 `package-center-fix-20261003/LanStash Test.app` 中只读复现：时间线与照片已经显示，点击“刷新”后，底部旧提示仍在。该位置属于操作反馈，区别于图库滚动区域内的读取错误。

源码确认：

- 通用解析失败的 AppError 在局部管理、保存、自动预览等路径被直接显示为“无法加载照片库”，错误范围被扩大。
- refresh 重置了图库 errorMessage，却没有清理已经结束的 managementMessage/saveMessage，因此用户照提示刷新仍不能消除旧反馈。

本轮修正为按操作上下文使用已有双语错误文案；保留权限/登录等具体错误。明确刷新时清理终态反馈，但待确认操作、分批继续、临时分享清理仍保留。自动预览有独立反馈，不阻挡图库清理旧的管理提示。图库本身真正读取失败时继续显示图库错误，不把错误简单吞掉。

**限制：**用户尚未补充截图最初由哪一次照片操作触发。本轮没有据此推断某个具体保存、分享或转换接口损坏，也没有修改照片 API。已验证的是错误归属、残留反馈与恢复保护。

### 套件更新仍提示信息不完整

官方已安装清单中，截图的 Active Insight 更新候选为 `install_type=system`。官方前端 `_onCheckInstall` 明确允许 `system/system_hidden` 缺省普通 `volume_list`；客户端原实现先强制解析列表，再判断是否系统套件，合法系统形状也会抛出“信息不完整”。

现在只对这两种已知系统类型接受缺省/null 的普通存储列表；普通套件仍须返回合法安装位置，已占用状态仍拒绝。目标、版本、依赖、权限、签名与许可、提交前重查和最终版本确认均保留。

证据边界：安装类型为真实只读观察；缺省列表的分支为官方静态证据，已用合成样本和完整更新流程回归。本轮没有点击官方更新按钮，也没有取得该目标的真实 check 响应或完成新客户端实际更新。前轮一次 MediaServer 更新不被重复使用为本轮行为证据。

### 更新检查窗口无法取消

原来准备阶段仅显示 ProgressView，触发读取的 Task 没有可取消句柄。现在：

- 只读准备显示“取消”，支持按钮及 Esc，立即关闭窗口并取消读取。
- 模型通过请求代次丢弃取消后的迟到成功或失败，旧请求不能恢复计划、覆盖新计划或弹出旧错误。
- 离开安装窗口、关闭模块也取消只读准备；Repository 保留互斥，不能强行绕过仍在退出的请求。
- 用户已经确认、正在提交安装或上传时显示“后台继续”，允许关闭窗口；不会把窗口关闭说成已经取消 NAS 安装。下载阶段继续沿用已有的真实取消与状态核对。

## 修改位置

| 范围 | 文件 |
| --- | --- |
| 照片反馈归属与生命周期 | `apple/Apps/DsmMac/Sources/SynologyPhotosModel.swift` |
| 准备取消、请求代次与关闭模块 | `apple/Apps/DsmMac/Sources/NasAdministrationModel.swift` |
| 取消按钮、后台继续与取消静默收尾 | `apple/Apps/DsmMac/Sources/PackageInstallationSheet.swift`、`PackageCenterView.swift` |
| 系统安装类型与取消读取 | `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageCatalog.swift` |
| 聚焦回归 | `SynologyPhotosModelTests.swift`、`NasAdministrationModelTests.swift`、`DsmPackageCenterTests.swift`、`WorkspacePresentationTests.swift` |
| 契约 | `contracts/fixtures-redacted/packages/installation-check/synthetic-system-no-volume/`、`contracts/schemas/nas-package-center.schema.json`、既有套件中心端点与兼容矩阵 |

未增加依赖、资源键、持久化结构、权限、应用身份或公共方法；使用已有中英文资源。Apple 共享网络层对系统套件的形状兼容已同步五端计划；Windows/Android 未移植，iPhone/iPad 复杂运维的原取舍不变。照片修复只在 macOS 模型层，不改变任何平台的照片读取或写入契约。

## 实际验证

所有命令从仓库根目录运行，合成资料不连接 NAS。命令中的 LANSTASH_CHECK_DIR 表示本轮临时目录；机器专属随机路径已脱敏，复验时重新创建。

| 命令 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter NasAdministrationModelTests` | 96 项通过；含准备立即取消、迟到成功/失败、新计划保护和模块关闭 |
| `swift test --package-path apple --jobs 4 --filter DsmPackageCenterTests` | 31 项通过；含系统缺省位置、普通套件拒绝、占用拒绝、单次提交及最终版本确认 |
| `swift test --package-path apple --jobs 4 --filter SynologyPhotosModelTests` | 250 项通过；含局部失败范围、刷新清理、待确认/部分完成保留、原件保存错误 |
| `swift test --package-path apple --jobs 4` | 2337 项，163 项按既定条件跳过，2174 项通过，0 失败；另 12 项 Swift Testing 通过 |
| 下方原生 UI 命令 | 2 项通过，12 个场景、24 张合成/原生截图；双语浅深色，按钮与 Esc 取消，照片错误与刷新后状态 |
| `python3 tools/localization/check_localization.py` | 通过，Apple 5486、Android 2188、Windows 3402；主应用覆盖资源一致 |
| `python3 tools/contract-validation/validate_fixtures.py` | 29 组响应样本、47 项私有引用通过 |
| `python3 tools/request-contract/validate_contracts.py` | 158 个请求样本、1 个写结果示例通过 |
| `git diff --check` | 通过 |

```sh
LANSTASH_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lanstash-check.XXXXXX")"
LANSTASH_UI_NATIVE_SCREENSHOTS=1 \
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test套件准备窗口双语主题可取消且不提交安装|WorkspacePresentationTests/test照片局部错误双语主题不误报图库且刷新清除提示' \
bash tools/codex/run_macos_ui_checks.sh "$LANSTASH_CHECK_DIR/ui"
```

新增保存失败测试首次误用了测试替身和方法名称，造成测试编译失败；改为既有 PhotoServiceStub 与 save 方法后通过，未改业务断言。最后的完整回归包含该修正。人工查看中文深色取消窗口与英文浅色照片错误状态，位置和文字正确。

## 单独集成复核与只读对抗检查

- 系统位置兼容仅依赖明确目录类型；未知类型、普通套件缺少位置、占用、版本变化和依赖失败没有放宽。
- 取消只发生在未提交的准备 Task；已确认提交不冒充取消。取消或停用后的旧成功/错误不触发界面恢复，旧 defer 不清掉新请求状态。
- 照片清理仅处理终态提示；未知写结果、剩余目标和分享清理记录不被刷新丢弃，也不自动重放操作。
- 不根据翻译后的字符串判断行为；照片错误按 AppError.category 区分，套件按稳定安装类型和阶段判断。
- 本轮为单独的源码与集成复核，没有宣称其他模型复核、完整 VoiceOver 或真实新客户端更新已通过。

## 测试包

独立输出目录：`apple/Apps/DsmMac/dist/photos-package-fix-20261003`。沿用本机临时签名与 arm64 Release，不自动安装或启动；保留上一轮包，不包含 Finder 本地磁盘挂载扩展。

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 \
LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_BUILD_ROOT="$LANSTASH_CHECK_DIR/package-build" \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-package-fix-20261003" \
bash apple/Apps/DsmMac/package.sh
```

最终包：`apple/Apps/DsmMac/dist/photos-package-fix-20261003/LanStash-1.0.13-arm64.dmg`，1.0.13 (23) arm64，26,185,471 字节。

SHA-256：`2f585372c284a50d721bc72c439b6848f7dcc7427cc9170d7699649833894db3`。

Release 构建、严格签名、专用临时权限与 Sparkle 实际加载检查通过，`hdiutil verify` 校验有效。成品 Info.plist 确认在线更新关闭、无 File Provider 扩展。通过 plutil 逐项读取成品资源：每种语言主资源 2202 键、共享资源 5486 键，全部与当前源码一致；取消、后台继续和照片局部错误的双语文案正确。源码基线为 `8e6b0f3e`，产物包含当前全部未提交改动，旧测试包保留。

严格文档检查 `python3 tools/codex/check_documentation.py --strict-release` 通过。交付前删除本轮临时日志、24 张合成截图与打包中间目录；不删除用户截图或旧包。

## PENDING_USER_VALIDATION

前置条件：退出旧测试应用，打开本次新包，连接有相应权限的 NAS。标签仅标记待办，不是验证等级。

1. 打开照片页并刷新，预期正常内容保持可浏览，不残留已结束操作的旧图库错误。若再次出现，请说明刚才执行的具体操作；这用于继续定位最初的实际失败点。
2. 在套件更新检查窗口点击“取消”或按 Esc，预期立即关闭，稍后不弹回旧错误、不自动开始安装；之后可重新检查。
3. 如用户选择实际更新，确认列表与目标版本后再提交；系统套件不应因没有普通存储列表被拦截，最终版本须与 DSM 一致。正式安装关闭窗口应显示后台继续，不能声称已取消。
4. 新客户端真实更新、复杂依赖、网络中断、其他 DSM/套件版本、正式签名、Intel 和真实 VoiceOver 仍未验证。仅回传版本、触发步骤和脱敏错误；不要发送凭据、原始 HAR 或真实照片/文件路径。

观察记录见[环境快照](../api/discovery/environments/2026-10-03-photos-package-followup.md)。浏览器临时记录已清除并关闭开发者工具；交付前清理本轮临时日志、合成截图与打包中间目录。
