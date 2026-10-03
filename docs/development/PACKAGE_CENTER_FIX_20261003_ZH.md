# 套件中心反馈修复账本（2026-10-03）

源码、回归和独立本机测试包已完成。沿用 `codex/nas-settings-web-audit`；上一轮全部未提交改动和安装包保留，本轮未暂存、提交、推送或发布。

## 实际修复

| 用户反馈 | 确认的原因 | 修复结果 |
| --- | --- | --- |
| 点击更新立即报错 | 官方 `Package.feasibility_check` v1 成功只有 `success:true`，客户端通用读取要求存在 data，将成功误判为损坏 | 使用已有 `callVoid`；仍拒绝服务器错误、畸形响应和权限拒绝。套件设置及取消/清理等不读取返回正文的命令同样使用此通道，结果复查保留 |
| 设置数据无法读出 | `Setting.get.update_channel` 实际是 Boolean；原解析要求 stable/beta 字符串 | get 严格读取布尔，set 按官方保存函数继续发送 stable/beta；单卷响应缺少 default_vol 可正常显示，只有多个位置才显示选择器 |
| 设置弹窗标题、按钮漂到中间 | 错误分支只占内容固有高度，没有填满弹窗剩余空间 | 所有状态共用伸展内容区，标题顶部对齐，底部操作固定；错误标题改为“无法载入设置”；失败清除可写基线，保存需数据读取成功且确有修改 |
| 内存压缩仍称只读，其他修正文案未生效 | L10n 先读 App 主资源，而旧副本覆盖了共享包的新文案 | 同步两层中英文资源，覆盖内存压缩、电源计划、硬盘休眠、防火墙通知等旧说明；检查器增加主应用双语与共享同名值一致性检查 |

主要代码：

- `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageCatalog.swift`
- `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageSettings.swift`
- `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageInstallation.swift`
- `apple/Apps/DsmMac/Sources/PackageCenterSettingsView.swift`
- `apple/Apps/DsmMac/Resources/{en,zh-Hans}.lproj/Localizable.strings`
- `apple/Packages/DsmLocalization/Sources/Resources/{en,zh-Hans}.lproj/Localizable.strings`
- `tools/localization/check_localization.py`

全局文案复核针对实际 macOS 引用与条件判断：存储卷不可写、远程只读连接、权限编辑不允许修改、新挂载默认只读、尚未实现的 DSM 系统更新等仍保留其准确限制。后台任务等旧只读资源键已经没有界面引用，不据此改变功能。电源计划缺失快照时的旧“去 DSM 创建”提示改成读取失败的刷新路径；正常空清单继续提供本机新增计划入口。

## 官方环境实际观察

- DSM：7.2.1-69057 Update 12，信息中心当日重新核对；匿名设备与历史 lab-a 关系未确认，不改写历史验证等级。
- 唯一真实写动作：用户明确授权的官方 MediaServer 更新，**2.2.1-3406 → 2.2.2-3412**；官方最终安装版本与在线版本一致，状态“已启动”。未批量更新、安装其他套件或保存系统/套件设置。
- 实际观察预检、队列、check v2、upgrade v1 的任务回执、status v1，以及 Setting.get v1。此单目标官方更新为 behavior-verified；不等于修复后的岚仓客户端已经完成真实提交。
- 不保存地址、账号、真实路径、任务编号、响应正文或 HAR；浏览器临时请求记录已清除并关闭开发者工具。

最小字段、静态写格式与证据边界见[环境记录](../api/discovery/environments/2026-10-03-package-center-followup.md)和[套件中心内部接口](../api/discovery/endpoints/dsm-package-installation.md)。新增两个完全合成响应样本分别覆盖无 data 成功和布尔频道/缺省安装位置；五端计划、兼容矩阵及 Schema 已同步。iPhone/iPad、Windows、Android 没有新实现或新增验收声明。

## 实际验证

以下命令均在仓库根目录运行：

| 命令 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter DsmPackageCenterTests` | 首轮 26 项通过；随后补充 3 项回归，最终 29 项随完整测试通过 |
| `swift test --package-path apple --jobs 4` | 2328 项，161 项按既定条件跳过，0 失败；另 12 项 Swift Testing 测试通过 |
| `LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test套件中心目录搜索与安装设置双语主题不自动写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-package-center-fix.WImXNN/ui` | 1 项原生 UI 检查通过，40 个合成场景、80 张普通/原生截图；含双语双主题、正常/错误设置与真实 sheet 容器、目录和搜索空结果；确认不触发写入 |
| `python3 tools/localization/check_localization.py` | 通过；Apple 5486、Android 2188、Windows 3402；新增 App 主资源覆盖检查通过 |
| `python3 tools/contract-validation/validate_fixtures.py` | 28 组响应 fixture、47 项私有 API 引用通过 |
| `python3 tools/request-contract/validate_contracts.py` | 158 个请求 fixture、1 个写结果示例通过 |
| `git diff --check` | 通过 |

原生 UI 首次运行因测试在 sheet 动画及异步加载结束前点击仍禁用的“关闭”，出现 4 个关闭断言失败。测试改为等待明确错误状态，并继续断言标题/底部位置、保存禁用与最终关闭；没有删减断言，重跑通过。已人工查看中文深色真实错误弹窗、英文浅色错误窗口及中文浅色正常表单。

额外尝试 Draft 2020-12 通用 Schema 引擎校验时，系统和内置 Python 均缺少 jsonschema，未安装新依赖，不能将此项称为通过。Schema 已同步字段并保持有效 JSON；现有 fixture/请求门禁和 Swift 实际解析回归均已通过。

## 单独集成复核与只读对抗检查

- 本轮仅复用无正文命令通道；该通道仍校验 HTTP 成功、有效 JSON、success=true，并在出现 DSM error 时拒绝。读取方法仍强制存在数据及必需字段，未加入笼统布尔/字符串转换或吞错 fallback。
- 预检通过只生成计划，不触发安装；目录变更、缺失依赖、权限拒绝、并发、签名失败、未知提交不重放及最终目标版本核对的原回归保留并通过。
- 设置读取失败后旧草稿不能作为可写基线；sources 与 settings 的错误状态分别保留，保存仍先比较最新基线并回读。
- 没有改认证、会话/持久化格式、第三方依赖、工具链、签名规则或运行时权限。文案同步不改变真实只读/能力限制。
- 此为单独的源码集成复核，未声称经过其他模型审查或真实客户端写入验收。

## 测试包

按现有本机临时签名流程生成，使用独立输出目录 `apple/Apps/DsmMac/dist/package-center-fix-20261003`；保留旧包，不自动安装或启动，不含 Finder 本地磁盘挂载扩展。

构建命令：

```bash
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release \
LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- \
LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_BUILD_ROOT=/tmp/dsm-package-center-fix.WImXNN/package-build \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/package-center-fix-20261003" \
bash apple/Apps/DsmMac/package.sh
```

产物：`apple/Apps/DsmMac/dist/package-center-fix-20261003/LanStash-1.0.13-arm64.dmg`，1.0.13 (23)，arm64，26,194,862 字节。

SHA-256：`74c77b62c664cb9a3a7e3702ad539ff4fc86442ce92bdc7718adf925d110c00a`。

Release 构建成功；既定打包脚本的严格签名、实际 Sparkle 加载、临时权限与架构、`hdiutil verify` 均通过。直接读取成品 App 的 Info.plist 确认在线更新关闭、无 File Provider 扩展。通过 `plutil` 读取成品主资源与共享 bundle：每种语言 2202 个主资源键、5486 个共享键全部匹配当前源码；重点检查 ZRAM、电源计划、防火墙通知、进阶休眠及设置错误标题。未启动真实应用或读取其账号。

旧 `nas-settings-package-center-20261003` 和 `settings-read-ui-fix-20261002` 测试包均保留。包内源码提交字段沿用基线 `8e6b0f3e`，实际包含当前未提交修复。交付前清理本轮临时日志、80 张合成截图与打包中间目录，保留源码、合成 fixture、账本及最终包。

## PENDING_USER_VALIDATION

标签表示尚待用户验收，不代表平台构建或真实写行为已通过。

- 前置条件：运行本次新测试包，连接对应 NAS；旧测试应用先退出。当前账号须具有相关权限。普通读取检查不需要更新其他套件。
- 先检查设置页常规、自动更新和套件来源，与 DSM 当前值比较；预期能正常加载，未修改时保存禁用，单卷不显示多余位置选择器。
- 检查内存压缩和电源计划；预期有编辑能力时没有旧只读/前往 DSM 修改说明，真实能力不足或只读权限仍明确受限。
- 客户端真实更新、设置保存、其他套件/依赖、断线/取消/恢复，以及正式签名、Intel、VoiceOver 真实操作仍未验证。后续由用户选定愿意更改的目标进行验证；本轮不继续更新第二个套件。
- 预期更新须经过明确目标/风险确认，最终版本正确；未知状态只刷新核对，不重复提交。设置保存后与 DSM 一致。
- 若失败，仅回传 DSM/套件版本、使用的测试包、操作步骤和脱敏错误文案；不要提供密码、会话、原始 HAR 或真实文件路径。
