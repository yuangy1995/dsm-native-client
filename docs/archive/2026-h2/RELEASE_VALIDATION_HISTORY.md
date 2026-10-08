<!-- doc-role: archive -->
<!-- last-reviewed: 2026-10-05 -->

# 发布与手工验收历史（2026-H2）

本文件收敛无法由 CI 重建的脱敏手工验收结论与待验收边界。它不是发布批准，不能用
源码阅读、模拟器或自动化构建替代正式签名包、真实设备或真实 NAS 的结果。

当前发布条件与执行步骤仍以以下保留文档为准：

- [macOS 桌面云盘发布与升级验收](../../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [macOS 桌面云盘正式签名验收执行矩阵](../../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [功能实现与验证等级](../../quality/VERIFICATION_LEVELS_ZH.md)

## 已归档的结论口径

本节为 2026-08-20 的历史状态；后续 Photos 等专项证据另行追加，不以旧表覆盖新记录。

截至本次文档收敛，仓库中没有可复核、脱敏且与当前候选包绑定的以下手工验收结果：

| 验收领域 | 归档结论 | 原因与后续条件 |
| --- | --- | --- |
| Developer ID 签名 | `PENDING_USER_VALIDATION` | 需要正式证书、干净测试用户和候选安装包。 |
| 公证与票据装订 | `PENDING_USER_VALIDATION` | 需要可用的 notarization 凭据与候选 DMG；凭据不得进入仓库或回传内容。 |
| Gatekeeper 与嵌入 Extension | `PENDING_USER_VALIDATION` | 需要未安装候选包的测试 Mac，确认系统接受安装与 Extension 注册。 |
| Finder / File Provider | `PENDING_USER_VALIDATION` | 需要真实 macOS、专用 NAS 与可丢弃映射；无签名构建不能证明系统生命周期。 |
| 真实 NAS 登录、会话和证书 | `PENDING_USER_VALIDATION` | 需要专用账户与测试环境；不得回传地址、会话材料、真实名称或原始响应。 |
| 升级安装与回退 | `PENDING_USER_VALIDATION` | 需要上一个公开包、候选包和可恢复的专用测试快照。 |
| 危险写操作最终回读 | `PENDING_USER_VALIDATION` | 需要已授权的专用 NAS；未完成前高风险内部写入口继续关闭或受能力门保护。 |

上述状态表示“尚无真实环境证据”，不表示失败，也不表示可发布。

## 允许开始的 macOS Beta 前置条件

只有满足下列条件时，才可由项目负责人开始手工 Beta 验收：

1. 候选代码已通过当前仓库的可执行质量门，并能生成无签名 macOS 包。
2. 仅使用 Developer ID 正式证书、受控 notarization 凭据和专用测试 Mac；不得导出
   钥匙串、证书私钥、密码或 API 凭据。
3. NAS 使用专用账号、可丢弃目录和稳定别名（如 `lab-a`）；现场材料不记录设备名称、
   地址、账号、路径、文件名、Cookie、SID、SynoToken 或原始 DSM 响应。
4. 升级、缓存、映射和外接卷测试均有可恢复快照；无法安全回滚时停止该轮测试。

## 建议执行顺序与预期

| 顺序 | 条件与操作 | 预期结果 | 可回传的脱敏信息 |
| --- | --- | --- | --- |
| 1 | 正式签名候选包完成公证与票据装订后，在干净测试用户安装。 | Gatekeeper 接受安装，应用可启动。 | 成功/失败、macOS 大版本与架构类别、错误的通俗摘要。 |
| 2 | 创建、浏览和移除一个可丢弃的只读云盘映射。 | Finder 入口与应用状态一致，移除不影响其他测试映射。 | 用例 ID、最终状态、是否完成清理。 |
| 3 | 在可丢弃文件上执行读取、取消、断网恢复与离线保留。 | 结果符合执行矩阵，取消和恢复不把未知状态写成成功。 | 文件规模类别、连接类别、结果一致/不一致、下一步。 |
| 4 | 覆盖安装候选包并按矩阵执行回退。 | 映射、缓存与会话按兼容策略收敛，不通过删除配置伪造成功。 | 安装路径类别、用例 ID、通过/失败/未执行、清理结果。 |
| 5 | 在已授权专用 NAS 上逐项验证允许开放的危险写操作。 | 提交前确认、权限检查、重复提交保护与最终回读均成立。 | API 名称、版本类别、结果状态、脱敏失败语义；不回传请求正文。 |

## 失败与停止规则

发现凭据暴露、非测试数据影响、映射无法安全移除、签名/Extension 身份不一致、升级可能
覆盖唯一配置副本，或无法完成现场材料脱敏时，立即停止该轮测试并按执行矩阵恢复。将
结果记为失败或未执行及其条件；不要以重试掩盖首次异常，也不要上传原始日志、截图或
系统数据库。

## 归档格式

每一轮仅记录候选版本标识、环境类别、用例 ID、通过/失败/未执行、用户可见结果、清理
结果、剩余影响和下一步。候选包散列可在受控发布记录中保存；本仓库不保存真实环境
标识、秘密或未脱敏附件。

## Photos 测试包与受控删除（2026-09）

本节合并原替换账本的可追溯执行结论，省略反复更新的施工状态和中间失败后已修正的打包流水。[当前范围](../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)独立维护；下列结果不表示五端完成或正式发布。

| 构建号（版本均为 1.0.2） | 主要变化 | DMG SHA-256 |
| --- | --- | --- |
| 20260909.20 | macOS 新 Photos 读取入口 | `bd43caeec89b47318625011280482e7020d0b0d642ad5a4e2785c31e7993eca9` |
| 20260910.1 | 分类、筛选、实况及共享读取 | `c1fe4dccb35fa3d7c6e1ffc7158d7cf525f4d658b333a6e394ef76c185301935` |
| 20260910.2 | 标准筛选与共享排序修正 | `12c4174559fc0e6333dc7f2808df11d620669e8627a68426bb68f8602271da24` |
| 20260910.3 | 背景、右侧年月轴；删除当时关闭 | `c24e36c09aeef50b3245f7f6a98b2c92a6971fddfe353da347488f590f8c6762` |
| 20260910.5 | 个人空间单项删除按能力跨版本开放 | `fa69b148b34bbeb9586b873a198452380d5142687a297f70707f399fb300b041` |
| 20260910.6 | 视频按可用转换版／原件选源，年月轴去整块焦点框 | `41d87979f247d8a9b51a7f4b4badd3bb1f35182928e0aa57cb0b0bbd09aeb9b0` |

- 上述包均按既有 `apple/Apps/DsmMac/package.sh` 生成 arm64 Release、独立临时签名包，未自动安装／启动，不含本地磁盘挂载扩展。构建号 .4 是中途限定版本包，未最终交付，已移入废纸篓。
- 最终 .5：`swift test --package-path apple --jobs 4 --filter SynologyPhotos` 43 项通过；完整 `swift test --package-path apple --jobs 4` 949 项、50 条件跳过、0 失败，另 12 项 Swift Testing 通过。未将跳过计为实际 UI 验收。
- .1 合成 UI 5 项、.2 筛选 UI 1 项、.3 背景／年月轴 UI 3 项通过，均覆盖相应双语／主题场景。正式回归源码保留，中间截图已清理；不是全设备辅助功能验收。
- .5 打包使用 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_NUMBER=20260910.5`，并配置独立临时构建／输出目录。DMG 完整性、输出及镜像内 `verify_macos_local_test.sh` 的签名／权限／Sparkle 实际加载通过；`rsync -anic --delete` 镜像比对无差异。
- 读取修正：共享列表缺少 sort_by 时返回 120；补共享修改时间排序后成功。实况使用独立视频单元，不使用主照片 ID。筛选保留整数／分数结构。请求事实见[读取端点](../../api/discovery/endpoints/photos-library-read.md)。
- 用户授权仅上传并删除一张新增合成 PNG，单次提交成功、任务完成、刷新后原件回读为空；没有删除既有照片或回收站内容。环境和步骤见[删除观察](../../api/discovery/environments/2026-09-10-photos-deletion-observation.md)。
- 删除初期默认关闭；受控验证后先按精确版本开放，随后用户明确授权移除 DSM／Photos 版本白名单。最终按接口支持、实际权限、目标一致性、确认、防重复和回读保护，不降低证据等级。
- .6：`swift test --package-path apple --jobs 4 --filter SynologyPhotos` 46 项通过；完整 Swift 测试 953 项、51 条件跳过、0 失败，另 12 项 Swift Testing 通过。八种视频扩展名的原件选源、可用中低清和实况单元回归通过，不代表全部编码可播放。年月轴浅深焦点／方向键／像素及背景两项合成 UI 已单独运行通过。
- .6 沿用上述打包参数，仅构建号改为 20260910.6，独立临时构建／输出；arm64 Release、DMG 校验、镜像内外签名／权限／Sparkle 实际加载通过，`rsync -anic --delete` 无差异。文档、本地化、请求 fixture 和私有接口引用检查通过；构建和挂载临时目录已清理，未自动安装／启动、未提交／推送。真实 App 视频播放和不同编码仍待用户反馈。

## 跨端正式提交验证（2026-09-21）

以下是已完成执行的历史记录，不是本次文档整理重跑，也不适用于之后所有源码变更。

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


该功能提交随后按当次授权快进 main 并清理专用验证分支；Android destination 请求修复已经包含在内，旧记录中的 v1 测试失败不再是未解决事项。仪器 APK 构建不等于真机测试，Apple 条件跳过不算通过，正式签名/真实 NAS 独立验收。

### Apple 与 Windows 测试包

Apple 前序集成 [35564520773](https://github.com/yuangy1995/dsm-native-client/actions/runs/35564520773) 完成共享层、两类模拟器、macOS 打包及临时签名检查；包取回至 `apple/Apps/DsmMac/dist/github-parity-integration-20260921/`，ZIP digest 已核对，未重组 App bundle。

Windows 前序 [35601196998](https://github.com/yuangy1995/dsm-native-client/actions/runs/35601196998) 对提交 `c54acdc943c28a4b14f524a4d7b05714485cc3c6` 执行 Release xUnit，3929 项全部通过，WinUI x64/ARM64 均 0 警告/错误。`windows/package.ps1` 使用 `NON_INTERACTIVE=1 TARGET_PLATFORM=both RUN_TESTS=1 LAUNCH_AFTER=0 SELF_CONTAINED=1` 生成两个自包含包；未安装/启动。完整中文原生波次既有 925 场景通过，随后云盘中英各 47 场景通过，二者未冒充同次重跑。`CloudFilesNativeChecks --isolated-shell-binding` 与 `--isolated-recycle` 通过。

实际 Windows 命令在 `windows/` 执行：

```powershell
dotnet restore LanStash.slnx
dotnet test tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore --logger "console;verbosity=normal" --blame-hang --blame-hang-timeout 2m
dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-x64 --no-restore
dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-arm64 --no-restore
```

| 产物 | SHA-256 |
| --- | --- |
| Apple 集成 ZIP | `372b66d2838529ab0aba48ba651457dc114642ee9a3af61ad8991cbe39f4b564` |
| Apple `LanStash-1.0.9-arm64.dmg` | `e59864682fafa3ca2600d4231135c636dc8d5ffb0d01a9b7ead4e7d6fd3e89e7` |
| Windows `dist/20260921-190403/LanStash-0.1.0-x64.zip` | `3b913b493c6dd59d4766e2634dadd9efc6a954adfd94c7408d29fa60008f612eb` |
| Windows `dist/20260921-190403/LanStash-0.1.0-arm64.zip` | `8ab9165bc3c76185018c26a33596517a684742bf11c3af74cdbbebd1b794a2df` |

专用分支与工作树清理前核对源码已保留，未删除其他历史分支。专用 NAS 测试 VM 当时保留；本次文档整理未查询或操作其状态。

## 早期架构与迁移里程碑

- Apple/Android/Windows 保持平台原生技术栈；应用身份与官方 API 优先等决定现集中在[架构决策](../../architecture/ARCHITECTURE.md#架构决策)。
- 原 File Station 照片扫描方案由 Synology Photos 正式入口替代；历史文件导入/备份公共组件不等于图库 fallback。当前迁移边界集中在[照片计划](../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。
- Android 对齐 82–89 波与旧跨端流水已归并；长期不变量、任务所有权、质量基线及未完成工作仍由平台计划和现有源码/自动化维护，不以已结束的阶段编号作为验收依据。

## macOS 历史修复的有效结论（2026-09）

| 领域 | 已记录的执行结果 | 仍未证明的内容 |
| --- | --- | --- |
| 挂载签名与共享权限 | 9 月 7 日开发签名包，两独立沙盒探针完成合成 Keychain/App Group 互通；签名、DMG 内容比对通过 | Finder 调度、真实 NAS 与外接盘行为 |
| 账号、工作区和更新窗口 | 合成中英主题/权限/窗口操作、Release 临时包与 Sparkle 实际加载已执行 | 不同系统版本和真实账号流程 |
| 外观、密度和缓存 | 独立原生主题与键盘回归、Release 包验证完成；正式测试源码保留 | 完整 VoiceOver、Intel 和真实缓存卷 |
| 退出保留挂载 | 聚焦映射/会话/Provider 回归合计 143 项通过；无签名 Debug 主 App 与扩展构建通过 | 系统进程与真实 File Provider 生命周期 |
| 窗口销毁崩溃 | 用户 9 月 10 日反馈不再闪退；该本机测试包 DMG 为 `f24e67b389e297011e9fdde7d402239fcfa63176f37fb5de6c5895b7442a271d` | 仅为该包的用户使用反馈，不外推所有窗口/系统/正式签名包 |
| 写回与删除 | 指定文件夹、全部共享及单独删除授权逐步接入；当前安全语义见云盘计划 | 未将自动化更新为真实数据写入验收 |
| 下载管理 | 9 月 27–28 日任务创建、详情和搜索布局完成；`downloads-search-layout-20260928` 的 1.0.10 (20) arm64 Release、签名、Sparkle 加载和 DMG 校验通过 | 实际任务副作用、键盘/辅助功能完整走查 |

## macOS Photos 完成审查（2026-10-02）

对照最终 `SynologyPhotosManagementFeature` 的 42 项及 View → Model → Repository 链路，已登记 macOS Photos 开发范围完成；当前集合见[照片计划](../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。

历史实际命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`，827 项 XCTest 与 6 项本地化测试通过；响应契约检查 3 组及 42 项私有引用通过，签名回归 10 项通过。10 月 1 日四项原生 UI/48 张合成截图、Release/签名/实际组件加载/DMG 检查已有记录；10 月 2 日未冒充重新打包。正式沙盒书签权限由用户批准后加入，真实 NAS/重启与完整辅助功能未验收。

## macOS File Station、Office 与界面修复（2026-10-02）

各包均沿用独立测试身份、临时签名和既有打包流程；不含 Finder 本地磁盘挂载扩展、在线更新关闭，未自动安装或启动。下面是历史执行结果，不是此次文档修改重新运行。

| 功能 / 独立输出目录 | 执行证据 | 待用户验证 |
| --- | --- | --- |
| File Station 三轮增量 | 高级搜索、分享、上传、归档、权限、ISO/VFS/云授权与设置已有合成请求/模型/原生界面与 Release 包；生成工程沿固定 XcodeGen 流程更新 | 云授权实际回调、NAS 写入/权限/断网及服务兼容 |
| Office `office-autosave-20261002` | 聚焦编辑测试 18 项；完整 XCTest 2234 项、150 条件跳过、0 失败，另 Swift Testing 12 项；两项原生测试覆盖 40 张合成中英浅深截图，docx/xlsx/pptx 实际显示；Release/签名/加载/DMG 通过 | 真实编辑器、旧格式、复杂文档、正式沙盒、NAS 冲突及辅助功能 |
| UI `ui-fixes-20261002` | WebDAV 完整 URL、路径/按钮及照片控件合成回归与最终 Release 包；签名/加载/DMG 通过 | 真实连接和完整 VoiceOver |
| 远程位置最终 `save-feedback-20261002` | 25 项聚焦与原生行为回归通过，36 张截图；完整 XCTest 2264 项、157 条件跳过、0 失败，另 Swift Testing 12 项；最终包 Release/签名/加载/DMG 通过 | NAS 真实保存与浏览、系统减少动态效果及 VoiceOver |

包目录统一位于 `apple/Apps/DsmMac/dist/`，Office 之后各包为 1.0.12 (22)、arm64。最终远程位置完整 XCTest 中实际通过 2107 项；155 项原生 UI 与两项环境测试跳过，本轮受影响 UI 另行启用。目录中旧包保留，不把文件存在当作已安装/用户验收。

| DMG 所在子目录 | SHA-256 |
| --- | --- |
| `office-autosave-20261002` | `6dde48dac78bd65012a9fc9858b6e611f66ae42d0a9a44cbef52123e8876ceb6` |
| `ui-fixes-20261002` | `85ac7276672444aa041b2a6f2651850cac92cc057a7c32b38b1d222fa9e6b8f3` |
| `save-feedback-20261002` | `13a488d0c08e339317ac3ff0d61be5601cf42ad7801920cb8357a4350f686709` |

最终远程位置实际命令：

```sh
LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test远程连接主页直接|WorkspacePresentationTests/test远程连接成功自动关闭|WorkspaceRemoteConnectionsTests|FileVFSFormTests' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-save-feedback-screens-20261002
swift test --package-path apple --skip-update --jobs 4
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_ROOT=/tmp/dsm-save-feedback-package-20261002 LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/save-feedback-20261002" bash apple/Apps/DsmMac/package.sh
```

随后对输出 App/DMG 执行 `verify_macos_local_test.sh`（绝对 App 路径）、`codesign --verify --deep --strict` 和 `hdiutil verify`，均通过，实际 Sparkle 输出 `library loaded`。临时工具仅提供并行作业和同版本依赖缓存；一次性构建/日志/截图清理。历史报告中的阶段失败已在原波次修复，未降低断言或更改发布权限。

## 正式发布与用户反馈记录

2026-09-07 用户报告 0.2.7 → 0.2.8 在线升级和 Finder 挂载主流程成功；未提供精确系统版本，不扩展为所有架构或异常路径通过。

### 1.0.11 正式发布结果（2026-09-29）

- 最终单一提交 `5684170b3ccfab327ed2a9062ad3aac20f95ba71` 的六项云端门禁全部通过：Apple Build `36522282536`、Android Build `36522291829`、Windows Build `36522282499`、Repository Check `36522282403`、Documentation & Quality Preflight `36522282547`、Community Compatibility `36522297331`。Apple 使用锁定的 Xcode26.6 (17F113)，共享测试、iPhone/iPad 模拟器回归、macOS 打包与产物校验均通过。
- 重新获取主分支后确认仍为 `9c30efeab8fb`，将上述单一提交快进合入并推送 main；正式标签 `macos/v1.0.11` 指向相同提交，未改写已发布历史。发布成功后已删除本次远端和本地临时分支。
- [正式发布运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/36523391845) 完整成功：两个架构构建、Developer ID 签名、Apple 公证/装订、App与扩展校验、更新签名、上传回读和正式更新源更新通过。[macOS1.0.11](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.11) 于北京时间13:07:55公开，非草稿、非预发布，构建号21。
- 公开附件：`LanStash-1.0.11-arm64.dmg`（22285016字节）、`LanStash-1.0.11-x86_64.dmg`（23989612字节）、`appcast.xml`、`SHA256SUMS.txt`。发布后再次读取公开版本附件与 `macos-updates/appcast.xml`，两份更新源逐字节相同、SHA256匹配；两个条目均1.0.11/21，arm64在前并带硬件条件，Intel条目在后，安装包签名字段存在。实际签名验真与安装包回读校验由已成功的正式发布流程完成。
- 本轮临时日志和合成截图已清理，正式源码、测试、脱敏文档与此前独立测试包保留。未自动安装/启动应用，未对真实NAS执行分享、人物合并或收集请求写入；iOS仅更新构建配置，没有发布。
- `PENDING_USER_VALIDATION`：用户在实际Mac上升级至1.0.11，检查下载详情关闭、BT搜索布局、2020.03等月份定位后批量删除及位置保持，并验收新增个人照片管理。不同架构的安装后系统集成、Finder挂载与真实NAS写入仍不能由云端成功替代。剩余网页功能按照片对齐账本继续，本次发布不宣称完整复刻完成。



### 1.0.12 源码发布基线

本机 `main` 为 `4ac451d4c2b0`，提交标题为“发布 1.0.12 照片管理与上传恢复增强”，标签 `macos/v1.0.12` 指向同一提交。主 App 与扩展 1.0.12 (22)，包含此前 Photos 管理与恢复；之后 File Station/Office/连接界面改动为工作区独立开发。本文整理只核对本地提交/标签，未重新查询远端发布运行或下载附件，不以标签存在补写云端结果。

## macOS 1.0.13 发布记录（2026-10-02）

用户明确授权提交当前功能与文档整理，并发布 macOS 新版用于升级体验。目标为 `macos/v1.0.13`、主 App/扩展 1.0.13 (23)，专用分支 `codex/macos-1.0.13-release`；保持既有正式签名、应用身份、最低系统和更新密钥。

只读查询确认 1.0.12 的[发布运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/36896115537)失败：Apple 公证凭据检查返回 403，原因是账号缺少生效协议；当时未创建 1.0.12 Release。1.0.13 更新说明同时覆盖此前未公开的 Photos 增量与本轮 File Station、Office、远程连接及界面修复。协议须由账号持有人处理，不能跳过签名、公证或更新验收门禁。

用户随后确认 Apple 协议已经处理完成。最终单一功能提交为 `a293a9b1ad25c05cdb0b85da1d9ec3f3a92e6720`；合并前重新获取远端，确认主分支仍为 `4ac451d4c2b0`，再快进合入并推送 `main`。正式标签 `macos/v1.0.13` 指向同一提交，未改写已发布历史；合并后的专用临时分支已在远端和本地删除，后续可直接重跑标签发布。

### 云端与本地验证

| 检查 | 运行与真实结果 |
| --- | --- |
| Apple Build | [36983187954](https://github.com/yuangy1995/dsm-native-client/actions/runs/36983187954) 全部成功；共享 XCTest 2264 项中 157 项按环境条件跳过、2107 项通过、0 失败，另有 12 项 Swift Testing 通过；iPhone 与 iPad 模拟器各 498 项通过；macOS Release 打包、Sparkle 实际加载及临时签名产物检查通过 |
| Android Build | [36983187860](https://github.com/yuangy1995/dsm-native-client/actions/runs/36983187860) 成功；Debug/JVM、Release/R8、仪器测试 APK 构建及 lint 通过，未冒充设备仪器测试已运行 |
| Windows Build | [36983187938](https://github.com/yuangy1995/dsm-native-client/actions/runs/36983187938) 成功；3929 项测试全部通过，WinUI x64、ARM64 Release 构建均无错误 |
| Repository Check | [36983187948](https://github.com/yuangy1995/dsm-native-client/actions/runs/36983187948) 成功 |
| Documentation & Quality Preflight | [36983187871](https://github.com/yuangy1995/dsm-native-client/actions/runs/36983187871) 成功 |
| Community Compatibility | [36983233483](https://github.com/yuangy1995/dsm-native-client/actions/runs/36983233483) 成功 |

本地实际执行 `python3 -m unittest discover -s tools/codex/tests -p 'test_*.py'`（105 项）、`python3 -m unittest discover -s tools/release -p 'test_*.py'`（30 项）、`python3 tools/localization/check_localization.py`（Apple 5318、Android 2188、Windows 3402 条资源及硬编码检查）、文档严格检查、请求与响应契约检查，均通过。固定 XcodeGen 2.46.0 重新生成工程并复核一致性。

首轮 Windows 发现 macOS 与共享资源的三条“结束下载”中文提示不一致，已同步资源并保留原测试断言；修正归入上述单一功能提交。macOS 本机尝试运行该 Windows 聚焦测试时因 `MakePri.exe` 不能在当前系统执行而未完成，最终结论依据上表 Windows 托管 Runner 的完整验证。

### 正式发布

[正式发布运行 36986480876 的首次尝试](https://github.com/yuangy1995/dsm-native-client/actions/runs/36986480876/attempts/1)由标签触发，共享测试、本地化和发布回归通过；北京时间 17:00:47 执行 `xcrun notarytool history` 时，Apple 再次返回 HTTP 403，原因为所需协议未签署或已过期。该次失败发生于正式安装包构建之前，未创建 1.0.13 GitHub Release、未上传该版正式安装包、未修改正式更新源。

首次尝试时，用户此前确认协议已处理，但实际请求仍被拒绝，当时未确认是发布团队协议状态、账号状态还是 Apple 同步问题。后续由用户再次处理并确认已同意协议，再重跑同一标签的正式发布流程；没有跳过账号检查、修改发布身份或替换更新密钥。[Apple 官方账号角色说明](https://developer.apple.com/help/account/access/roles/)明确由账号持有人接受更新协议。

### 重试成功与公开附件

- 用户再次明确要求重试后，执行 `gh run rerun 36986480876 --failed`。[第二次尝试](https://github.com/yuangy1995/dsm-native-client/actions/runs/36986480876/attempts/2)完整成功；18:06:25 公证账号检查通过，18:27:19 正式公开 [macOS 1.0.13](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.13)，非草稿、非预发布。源码仍为 `a293a9b1ad25c05cdb0b85da1d9ec3f3a92e6720`，主 App/扩展均为 1.0.13 (23)。以上时间均为北京时间。
- 本次发布重新执行 `swift test --package-path apple`，2264 项 XCTest 中 157 项按环境条件跳过、2107 项通过、0 失败，另有 12 项 Swift Testing 通过；本地化检查及 `python3 -m unittest discover -s tools/release -p 'test_*.py'` 的 30 项通过。
- arm64 与 x86_64 分别完成 Release 构建和 Developer ID 签名，Apple 公证均返回 `Accepted`，装订成功；App、File Provider、更新组件的签名、权限、架构与正式分发检查通过。
- 发布流程对两个安装包及更新源执行签名验真、上传和实际下载回读，`shasum -a 256 -c SHA256SUMS.txt` 全部通过，再公开正式版本并更新 `macos-updates`。
- 发布后另行读取公开附件元数据，并下载版本内的 `appcast.xml`、`SHA256SUMS.txt` 及实际更新源。两份 XML 逐字节相同，SHA-256 为 `fa656395d61643a21a409ad1b16c3c8e18e441256eeef029c5853351e86ea61a`；两个条目均为 1.0.13 / 23，arm64 在前并带硬件条件，Intel 在后，下载地址、长度、签名字段及 GitHub 附件摘要均与发布清单一致。

| 公开安装包 | 字节数 | SHA-256 |
| --- | --- | --- |
| `LanStash-1.0.13-arm64.dmg` | 32118697 | `632339c5d164608eb420ba1cedf503998a5fa33997d8452f6bc6fb4f50faf384` |
| `LanStash-1.0.13-x86_64.dmg` | 35257465 | `8609ffb36aa774af0d1093c22f5d4343b1367a291742f4bfbc598f5adaef7d5f` |

`PENDING_USER_VALIDATION`：在实际 Mac 检查更新并安装 1.0.13，验证文件管理、远程位置与 Office 保存；真实 NAS、外部编辑器、正式沙盒恢复、Finder 挂载及完整辅助功能继续按对应计划验收。本次未自动安装或启动应用，未对真实 NAS 执行写入。保留可恢复文件与现有配置，反馈仅含版本、系统/架构、操作步骤及脱敏错误。

## macOS 所有者与权限读取修复（2026-10-02，未发布）

用户反馈在共享根目录打开“所有者与权限”时收到读取失败提示。1.0.13 源码确认权限详情请求缺少既有契约要求的 `real_path` 附加字段；新增请求测试在旧实现失败，补齐字段后通过。具体范围及五端影响见[权限端点记录](../../api/discovery/endpoints/file-station-file-permissions.md)。普通详情请求保持原字段，缺少有效路径仍停止后续权限读取。

共享根、挂载及回收站继续禁止权限写入，但可读取所有者和规则。只读规则的展开操作与修改控件分开，允许查看具体权限；载入中和无可编辑权限时不开放修改。普通读取错误使用含刷新恢复步骤的提示。中英文资源同步完成，没有变更身份、权限文件、数据格式或发布配置。

实际验证：

```sh
swift test --package-path apple --skip-update --jobs 4 --filter FileStationParityTests
LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test权限读取加载错误空内容和共享根只读双语主题' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-permissions-fix.m0FHHf/checked-screens
swift test --package-path apple --skip-update --jobs 4
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py --strict
git diff --check
```

- 相关网络回归 55 项通过；覆盖主动请求实际路径、缺字段停止、共享根/挂载/回收站只读、POSIX 读取及已有权限写保护。
- 最终完整 XCTest 共 2269 项，158 项按环境条件跳过、2111 项通过、0 失败；另有 12 项 Swift Testing 通过。最终 UI 修改后已重新执行完整测试。
- 原生界面回归 1 项覆盖中英、浅深色及正常、只读、空内容、错误、加载五态，含系统辅助功能展开与禁用修改检查；最终生成 24 张原生窗口截图和 24 张布局位图。已查看只读展开和错误恢复的实际窗口，不能以透明缓存位图替代原生视觉检查。
- 本地化资源 Apple 5319、Android 2188、Windows 3402，双语、占位符、引用及硬编码检查通过；文档严格检查与差异检查通过。
- 独立集成及只读安全复核确认：请求只增加已记录的只读字段，路径不猜测也不持久化；提交流程沿用相同目标范围、权限、确认、重复提交保护与两次快照检查，不因开放读取而放宽写入。

最终测试包通过既有 `apple/Apps/DsmMac/package.sh` 生成，配置为 `LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_BUILD_TYPE=Release`、`LANSTASH_TARGET_ARCH=native`、`LANSTASH_SIGNING_IDENTITY=-`、`LANSTASH_RUN_AFTER_PACKAGE=0`，构建与输出使用本轮独立目录。实际 arm64 Release、`codesign --verify --deep --strict`、`verify_macos_local_test.sh`（Sparkle 输出 `library loaded`）及 `hdiutil verify` 均通过。

输出为 `apple/Apps/DsmMac/dist/permissions-read-fix-20261002/LanStash-1.0.13-arm64.dmg`，SHA-256 为 `764c85088efb2751d7a87a3cbbeb2476362cd8ccbe16b1233d0177bd585692b1`。包内为独立的 `LanStash Test.app`，版本仍 1.0.13 (23)，包含本轮未提交修复，不是已发布的 1.0.13 正式包。测试包不含 Finder 本地磁盘挂载扩展，在线更新关闭，未自动安装或启动；没有提交、推送或发布本次修复。

`PENDING_USER_VALIDATION`：使用此测试包，以原账号分别打开原共享根和普通子目录的“所有者与权限”，预期显示所有者及规则，允许展开只读规则，共享根的修改控件和保存按钮保持禁用。若仍失败，只提供 DSM/File Station 版本、位置类别、步骤和脱敏提示；本轮未读取真实 NAS 响应、未执行权限写入，不能把合成回归表述为真实设备验证。完整 VoiceOver、实际鼠标/键盘操作和 NAS 兼容性仍待用户确认。


## 2026-10-02 账号名单、传输限速读取与重复控件修复

本轮在既有未提交权限读取修复之上继续修改，保留此前文件与测试。仅生成本地测试包，不提交、推送或发布正式版本。

- 官方已登录页面只读确认 DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559：VFS.User 的用户 `uid`、群组 `gid` 为十进制数字字符串；BandwidthControl 的未单独配置条目使用 `policy=notexist`。两个问题均先以合成响应复现旧解析失败，再修复并回归。观察中的未保存草稿全部取消，没有设置写入或原始响应导出。
- `DsmFileRepository+Settings.swift` 仅为账号编号补充严格数字字符串读取；共享 `FileStationBandwidthPolicy` 增加未配置状态。用户继承群组限速与不限速保持区分，账号及服务级写入均拒绝 `notexist`，其他确认、权限、去重和回读保护保留。
- `FileStationMountAccountList` 隐藏唯一来源选择，去除用户/群组前的重复标签，并把错误复用的“修改分享链接”改为“修改权限”。全量检查 macOS 10 处分段选择：原本已靠左的一处保留，其余 9 处按内容宽度靠左并隐藏重复标签，涉及账号选择、限速计划、分享图片、照片显示/隐藏、时间调整、空间选择及后台任务筛选。真实多来源切换及辅助功能名称保留。
- 中英文错误提示改为刷新重试及反馈，不再把客户端解析错误直接归因于 DSM 版本；新增限速状态文案均有双语资源。私有接口记录、两类限速合成样本、账号编号样本、响应 Schema 和五端影响同步完成。

实际验证：

```sh
swift test --package-path apple --skip-update --jobs 4 --filter FileStationParityTests
LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test账号选择隐藏单一来源并靠左保留多来源与用户群组切换|WorkspacePresentationTests/test文件远程浏览图片选择与云盘表单四态双语主题|WorkspacePresentationTests/test文件高级设置各标签与核查入口不自动提交|WorkspacePresentationTests/test主题显示隐藏中英浅深色正常空错误和搜索确认|WorkspacePresentationTests/test人物显示隐藏表单正常空错误浅深色布局不提前写入|WorkspacePresentationTests/test跨空间移动复制表单中英浅深色切换目标且不提前提交|WorkspacePresentationTests/test未完成预览恢复中英浅深色四种状态且打开不写入|WorkspacePresentationTests/test后台任务窗口中英浅深色五状态与错误详情' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-settings-read-ui.XBInJB/global-screens
LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test未配置限速正确显示群组继承且打开编辑器不产生保存' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-settings-read-ui.XBInJB/bandwidth-screens
swift test --package-path apple --skip-update --jobs 4
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict
git diff --check
```

- 最终相关网络回归 61 项通过；完整 XCTest 2277 项，160 项按环境条件跳过，实际 2117 项通过、0 失败；另 12 项 Swift Testing 通过。
- 原生界面分批共 10 个独立用例通过（全局分组 8 项、照片表单布局 1 项、未配置限速 1 项）。账号选择覆盖 40 个来源/语言/主题/状态组合，含切换绑定及左边缘检查；限速新增 12 张原生名单/编辑窗口截图，核对未修改时不开放保存。已查看最终账号、分享图片、照片时间调整和限速原生窗口；完整 VoiceOver 朗读及真实 NAS App 会话不据此视为通过。
- 本地化 Apple 5322、Android 2188、Windows 3402；双语、占位符、资源引用及硬编码检查通过。响应 fixture 21 组、私有文档引用 47 项、请求 fixture 140 个及写结果示例 1 个通过；文档严格检查、差异检查通过。
- 独立集成及只读安全复核：编号转换限定端点和字段，权限布尔不宽松转换，转换后重复身份仍拒绝；未知限速策略不猜测，未配置状态不写回；来源身份、管理员权限、确认与双次快照检查、未知结果不重放保持原有保护。未修改其他平台源码、签名权限配置、版本号或持久化格式。

`PENDING_USER_VALIDATION`：在新测试包中使用原账号打开“文件管理设置 → 远程权限 → 管理账号权限”，预期本机唯一来源不显示选择器，用户/群组靠左且两类名单可读；打开“传输限速”，预期未配置用户显示应用群组限速、群组显示未设置限速，打开编辑窗口不会自动保存。真实保存、实际传输速度、群组继承计算和域/LDAP 须在用户明确授权的测试范围验证。若读取仍失败，请提供 DSM/File Station 完整版本、用户或群组类别、操作步骤与脱敏错误文字，不回传凭据、主机或真实账号资料。相关风险仅限这些设置的兼容性，不以待验证项阻断无关功能。


最终测试包命令：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_ROOT=/tmp/dsm-settings-read-ui.XBInJB/package LANSTASH_DIST_DIR=/Users/yuangy/Downloads/applist/dsm-native-client/apple/Apps/DsmMac/dist/settings-read-ui-fix-20261002 bash apple/Apps/DsmMac/package.sh
```

arm64 Release 构建、`codesign --verify --deep --strict`、`verify_macos_local_test.sh` 的权限与 Sparkle 实际加载检查（`library loaded`）及 `hdiutil verify` 均通过。输出：`apple/Apps/DsmMac/dist/settings-read-ui-fix-20261002/LanStash-1.0.13-arm64.dmg`，25,448,961 字节，SHA-256 `5a9260454a0160aec6ca11575bf3a096c48181def882abbb1d598cacdff4918e`。包内为 `LanStash Test.app`，版本 1.0.13 (23)，沿用既定 localtest 独立身份；包含本轮及上一轮权限读取修复，与正式发布的 1.0.13 包不同。未覆盖旧测试包，未自动安装或启动；本地磁盘挂载扩展不在包内，在线更新关闭。临时日志、合成截图和独立构建目录在记录验证结果后清理，保留源码测试、脱敏合成 fixture 和最终安装包。

2026-10-02 用户试用后反馈“目前没什么问题了”，并要求先提交本轮修复。此为整体试用反馈，不据此补记未单独确认的 NAS 写入、域/LDAP 或实际限速效果；详细待验收边界保留。


## 2026-10-03 macOS NAS 设置核对与套件中心测试包

按用户要求先将上一轮权限/设置读取与控件修复提交为 `8e6b0f3e`，未推送；本轮在
`codex/nas-settings-web-audit` 完成 NAS 设置 21 页只读网页对照、ZRAM 开关、电源计划
编辑及原生套件中心主流程。新增安装/更新/手动上传、依赖与位置确认、进度/下载取消、
设置和来源管理；签名、许可、权限、危险确认、互斥与结果检查保持有效。本轮未提交
或推送。具体范围、静态/读取证据与五端影响见
[NAS 设置账本](../../development/NAS_SETTINGS_WEB_AUDIT_20261002_ZH.md)。

实际验证：

- `swift test --package-path apple --jobs 4`：2325 项，161 项按运行条件跳过，2164 项通过，0 失败；另 12 项 Swift Testing 通过。最终运行已包含后台安装完成不抢走当前页面的回归。
- 原生 GUI 三项专项检查退出码 0：21 页、网络/账号/电源编辑和套件目录/详情/安装/设置的双语浅深色共 152 组场景；截图是完全合成本机资料。套件详情进入停止确认后取消另完成真实点击回归，控制请求为零；不据此声称完整 VoiceOver 或真实 NAS 验收。
- 本地化检查通过：Apple 5485、Android 2188、Windows 3402；请求样本 158、写结果示例 1、响应样本 26、私有文档引用 47 校验通过；生成请求参数目录后，严格文档检查与 `git diff --check` 通过。
- 使用既定 `xcodegen generate` 更新 4 个新原生源文件的目标成员；未改项目身份、工具链、依赖版本、签名权限配置或持久化格式。

最终打包在 `apple/Apps/DsmMac` 执行：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$PWD/dist/nas-settings-package-center-20261003" ./package.sh
```

Release 构建、`codesign --verify --deep --strict`、本机测试权限与 Sparkle 实际加载检查
和 `hdiutil verify` 通过。包为 1.0.13 (23) arm64，本机临时签名，沿用既定
`LanStash Test.app` 独立测试身份，无 File Provider 扩展、无自动安装或启动；保留旧包。
DMG：`apple/Apps/DsmMac/dist/nas-settings-package-center-20261003/LanStash-1.0.13-arm64.dmg`，
26,189,182 字节，SHA-256 `6179089bc0a18d05efbd60d1481d86c3e8466f5e56ba1ed36066d78dd3840568`。
包内源码提交字段是基线 `8e6b0f3e`，产物包含本轮未提交修改。

`PENDING_USER_VALIDATION`：使用不承载真实业务的测试套件验证安装/更新/卸载、上传、
依赖中断及状态恢复；电源计划先测停用计划，内存压缩保存后重启由用户单独安排。
首次测试版协议、购买激活与浏览器专属安装表单在 DSM 完成。其他 DSM、权限、
UPS/外设/扩展网卡、正式签名和 Finder 行为均未在本轮验证；没有借用 macOS 结果
宣告 Windows/Android/iPhone/iPad 已实现。官方网页观察结束时已取消设置窗口并关闭
开发者工具，没有点击真实 NAS 的保存、安装、卸载或电源操作。临时日志、合成图片
和本轮打包中间目录清理后，保留源码、契约和最终安装包。


## 2026-10-03 套件中心反馈修复测试包

同一工作分支保留前轮未提交改动，未暂存、提交、推送或发布。新增修复：成功预检无 data 的解码、Setting.get 布尔频道与单卷缺省位置、设置弹窗错误态布局及保存门、App 主语言资源覆盖共享修正文案。详细源码、决策、失败记录、命令和待验收范围见[反馈修复账本](../../development/PACKAGE_CENTER_FIX_20261003_ZH.md)。

用户明确授权的一次官方网页更新已完成：DSM 7.2.1-69057 Update 12，MediaServer 2.2.1-3406 → 2.2.2-3412，最终“已启动”；未保存套件或系统设置。此单目标官方行为不能替代修复后岚仓客户端真实写入验收，不提升匿名关系未确认的 lab-a 历史记录。

实际验证：

- `swift test --package-path apple --jobs 4`：2328 项，161 项按既定条件跳过，2167 项通过，0 失败；另 12 项 Swift Testing 通过。套件专项从 26 项增加到 29 项，含实际形状合成样本。
- `LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test套件中心目录搜索与安装设置双语主题不自动写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-package-center-fix.WImXNN/ui`：1 项、40 个合成场景、80 张截图，通过；实际 sheet 错误标题/底部定位、保存禁用及关闭均断言通过。
- `python3 tools/localization/check_localization.py`：主 App 覆盖检查及双语资源通过，Apple 5486、Android 2188、Windows 3402；响应样本 28、私有引用 47、请求样本 158、写结果示例 1 通过对应校验；`git diff --check` 通过。
- 额外通用 JSON Schema 引擎缺少 jsonschema，因此未运行该额外验证；未安装依赖。实际读取/拒绝语义已有 Swift 回归。

仓库根目录打包命令：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_ROOT=/tmp/dsm-package-center-fix.WImXNN/package-build LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/package-center-fix-20261003" bash apple/Apps/DsmMac/package.sh
```

Release、严格签名、Sparkle 实际加载、临时权限/架构及 DMG 校验通过，沿用既定独立 `LanStash Test.app` 本机临时身份。包为 1.0.13 (23) arm64，无 File Provider 挂载扩展、关闭在线更新，不自动安装或启动。成品的两种语言各 2202 个主资源键与 5486 个共享键已逐项比对源码，无旧值覆盖。

DMG：`apple/Apps/DsmMac/dist/package-center-fix-20261003/LanStash-1.0.13-arm64.dmg`，26,194,862 字节。
SHA-256：`74c77b62c664cb9a3a7e3702ad539ff4fc86442ce92bdc7718adf925d110c00a`。
包内源码基线仍是 `8e6b0f3e`，成品包含本轮未提交修复；之前两个测试包保留。

`PENDING_USER_VALIDATION`：新客户端真实更新与设置保存、其他版本/权限/复杂依赖/取消/断线恢复，以及正式签名、Intel 与实际 VoiceOver。只读显示验收步骤和允许回传的脱敏信息见上述账本。浏览器临时请求记录清除、开发者工具关闭；本轮临时日志、合成截图和打包中间目录在交付前清理。


## 2026-10-03 照片反馈与套件准备取消修复测试包

保留既有未提交功能与全部旧测试包；未暂存、提交、推送或发布。范围为照片局部错误归属/刷新后旧提示残留、系统套件缺省普通位置的合法形状，以及可立即取消的只读安装准备。准备取消丢弃迟到成功/失败，已确认提交提供后台继续，未知安装不重放。具体源文件、静态/只读证据、测试命令和边界见[二次反馈账本](../../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)。

实际验证：

- 模型专项 `NasAdministrationModelTests` 96 项、网络套件专项 `DsmPackageCenterTests` 31 项、照片模型专项 `SynologyPhotosModelTests` 250 项通过。
- `swift test --package-path apple --jobs 4`：2337 项，163 项按既定条件跳过，2174 项通过，0 失败；另 12 项 Swift Testing 通过。
- 原生 UI 两项检查通过，双语浅深色 12 个场景、24 张合成/原生截图；覆盖按钮及 Esc 取消、过期操作提示刷新、零写请求。完整原生命令见账本。
- 本地化检查通过：Apple 5486、Android 2188、Windows 3402；响应 fixture 29、私有 API 引用 47、请求 fixture 158、写结果示例 1 通过；严格文档和 git diff --check 通过。

仓库根目录打包（机器专属临时路径已脱敏，复验时重新创建）：

```sh
LANSTASH_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lanstash-check.XXXXXX")"
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_ROOT="$LANSTASH_CHECK_DIR/package-build" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-package-fix-20261003" bash apple/Apps/DsmMac/package.sh
```

Release、严格签名、临时权限、实际 Sparkle 加载、架构与 DMG 校验通过。1.0.13 (23) arm64，既定独立本机临时身份，在线更新关闭、无 Finder 挂载扩展；未自动安装或启动。成品两种语言的 2202 个主资源键与 5486 个共享键逐项匹配源码。源码基线 `8e6b0f3e`，产物包含全部当前未提交修复。

DMG：`apple/Apps/DsmMac/dist/photos-package-fix-20261003/LanStash-1.0.13-arm64.dmg`，26,185,471 字节。
SHA-256：`2f585372c284a50d721bc72c439b6848f7dcc7427cc9170d7699649833894db3`。

本轮只手动触发必要读取与刷新，未再次更新 NAS 套件或手动修改照片。官方候选的系统类型为只读证据，缺省位置分支为静态证据，不冒充真实 check 或安装响应。照片原始触发操作尚无补充，因此只确认并修复错误归属与残留，不宣称某项 NAS 照片写接口已验收。新客户端真实更新、复杂依赖、断网恢复、其他版本、正式签名、Intel 和真实 VoiceOver 为 PENDING_USER_VALIDATION。浏览器临时记录清空，开发者工具关闭；本轮临时日志、合成截图与打包中间目录在交付前清理，保留最终包和源码。


## 2026-10-03 macOS 1.0.14 正式发布

用户明确授权在现有 `main` 发布新版本，不创建测试、功能或验证分支。版本更新为 1.0.14（24），主 App 与 File Provider 同步；沿用 Developer ID、公证、App Group、共享钥匙串、Sparkle 更新源和独立双架构发布流程。保留既有 1.0.13 发布附件，不覆盖同版本产物；回滚通过更高版本修复或恢复已签名的上一份更新源。

本次包含主分支上尚未发布的 NAS 设置/套件、QuickConnect/照片/文件修复，以及 Chat 补齐、容器下载跟踪和挂载读写修复。具体实现和验收边界见 [Chat 账本](../../development/MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md)、[容器账本](../../development/MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md)、[挂载账本](../../development/MACOS_MOUNT_WRITABILITY_FIX_20261003_ZH.md)；双语用户说明见[版本说明](../../releases/MACOS_RELEASE_NOTES.md)。

发布前本地证据：最终源码 `swift test --package-path apple --jobs 4` 为 2,417 XCTest（2,248 通过、169 按既有门禁跳过、0 失败），另 12 Swift Testing 通过；macOS Release arm64 主 App/扩展与 iPhone/iPad 通用模拟器 Debug 构建通过。Chat 与容器合成界面检查已分别通过，完整命令保留在对应账本。追加 `python3 -m unittest discover -s tools/release -p 'test_*.py'` 为 32 项通过；本地化、169 个请求样本、29 组响应样本及 48 项私有接口引用校验通过；文档与差异检查通过。

发现此前 Apple Build 在工程生成一致性检查失败：本机 XcodeGen 2.45.4 与仓库锁定的 2.46.0 对 target 排序不同。此次使用经仓库既有 SHA-256 验证的 2.46.0 重新生成并确认重复生成一致；不手改生成文件，不修改工具链锁定或放宽门禁。版本、构建号与说明更新后由正式工作流重新测试及构建。

发布完成：北京时间 2026-10-03 22:26:08 公开 [macOS 1.0.14](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.14)，非草稿、非预发布。正式标签 `macos/v1.0.14` 指向已推送到 `main` 的 `e069cb3d665683e7fbca9782517b7f3667ac4177`；全程没有创建或使用测试/功能分支，没有改写已发布标签或附件。

[macOS Release 37127867041](https://github.com/yuangy1995/dsm-native-client/actions/runs/37127867041) 成功：重新运行 2,417 XCTest（169 既有条件跳过、0 失败）、12 Swift Testing 和 32 项发布回归，完成两种架构主 App/挂载扩展构建、Developer ID 签名、Apple 公证 Accepted、装订、正式包门禁、上传回读和签名更新源发布。两份正式包均包含 File Provider，区别于此前本机临时测试包。

| 正式附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `LanStash-1.0.14-arm64.dmg` | 33,427,743 | `ac13256335492838c6fa6f45c3dd30cadf49425912bf4c44bbae8b686744622f` |
| `LanStash-1.0.14-x86_64.dmg` | 36,878,723 | `716a5b0e00d12cfb023f26a1341f9fbf751970dba7cd977baaa0524f40bb8ec9` |
| `appcast.xml` | 9,446 | `6bd217a0f07eca34342d713c16fba9cc9f7628268f942cc31c6b26ed1ca3f85d` |

发布后本机重新下载两份 DMG、`SHA256SUMS.txt` 及版本内的 `appcast.xml`，逐项 SHA-256 一致；另读 `macos-updates/appcast.xml`，与版本附件逐字节一致。更新源首两项均为 1.0.14（24），arm64 条件项在前、Intel 项在后，公开附件地址、字节数与签名字段正确；签名验签由正式工作流执行。未在用户电脑安装或启动正式包，未操作 NAS 文件。

同提交的 Repository Check、Documentation & Quality Preflight、Community Compatibility 和 Windows Build 已通过。Android Build 在 `main` 与发布标签均失败；标签运行 [37127867031](https://github.com/yuangy1995/dsm-native-client/actions/runs/37127867031) 显示 1,436 测试中 1 项创建投票断言失败。根因是 Android 仍编码旧字符串选项/旧 options，与已根据 NAS 实际行为修正的共享请求样本不符；这是 [Chat 勘误](../../api/discovery/endpoints/chat-advanced-actions.md)已记录的未对齐项。本次只发布 macOS，未改 Android 源码、恢复错误样本或降低断言，不宣称全平台门禁通过。Apple Build 的独立通用构建和 iPhone/iPad 合成回归已通过，常规 macOS 打包检查另见[主线运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/37127844011)。

`PENDING_USER_VALIDATION`：升级后 Finder 实际保存/删除、Intel/Apple Silicon/Rosetta 升级保持配置与挂载、系统麦克风与通知、真实 NAS 异常路径；正式发布、签名与自动化不替代这些设备行为。临时下载、工具和日志在核对并记录后清理，既有测试包保留；发布结果文档继续以普通提交推送到 `main`，正式标签保持指向上述源码提交。


## 2026-10-04 移动 M0 基线

用户确认 M0→M8 完整移动业务对齐，允许必要共享提取和 macOS 引用调整，禁止自动影响 NAS 真实数据。代码基线 `e3bd3480973b325fb76c75783c2f26b682e64f5f`，源码尚未修改；范围与差距统一在[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。

- Xcode 26.6（17F113），iOS 26.5 专用 iPhone 17 Pro（`8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`）和 iPad Air 11（`A31ABDE2-186F-43DD-8D40-5EB9511A9289`）均成功启动；未擦除旧模拟器。
- `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：通过。
- 同一项目/方案/构建目录分别对两个设备执行 `test-without-building -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：iPhone 498/498、0 失败（01:51），iPad 498/498、0 失败（01:52）。两端分别保存 `build/m0-m8-baseline-iphone.xcresult` 和 `build/m0-m8-baseline-ipad.xcresult`，生成物不提交。
- 随后通过 `simctl launch` 分别运行主 App，在原生 Simulator 窗口检查 iPhone 单栏和 iPad 宽屏登录页。未填写真实账号或连接真实 NAS。
- 现有测试含静态源码护栏，不等于所有界面交互已验证；真实 NAS、系统选择器、辅助功能及后续新功能均须各自验收。
- M0 纠正套件安装、ZRAM、电源计划的旧 API 状态说明，并同步移动范围与各功能计划；不改变网络请求或 Windows/Android 代码。

M0 追加原生操作：iPad 空地址点击连接后显示“请输入 NAS 地址或 QuickConnect ID”，未发起真实连接；切换英文菜单成功，再次提交空地址显示英文修正提示。发现切换语言时旧错误消息未重新本地化，记录至 M1；不把该项记为通过。源码另确认配置 UUID 复用时账号/连接变更的缓存隔离需要补强。


## 2026-10-04 macOS 1.0.15 正式发布

用户明确要求先发布当前 macOS 修复，再执行移动 M0→M8；在既有 `main` 更新主 App/File Provider 为 1.0.15（25），锁定 XcodeGen 2.46.0 重新生成工程。发布提交 `e3bd3480973b325fb76c75783c2f26b682e64f5f`，标签 `macos/v1.0.15`；未改写共享历史或旧版本附件。

[正式工作流 37141445406](https://github.com/yuangy1995/dsm-native-client/actions/runs/37141445406) 成功，包含共享包 2425 项 XCTest（172 项环境/UI 条件跳过、0 失败）及 12 项 Swift Testing、本地化、32 项发布脚本回归、双架构构建、Developer ID 签名、公证 Accepted、装订、Gatekeeper 与组件验证。未运行的原生/真实环境项目不记为通过。

北京时间 2026-10-04 02:07:51 公开 [macOS 1.0.15](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.15)，非草稿、非预发布。

| 正式附件 | 字节数 | SHA-256 |
| --- | --- | --- |
| `LanStash-1.0.15-arm64.dmg` | 33,414,369 | `a01f6a22f584e5a1b33ab3fe45fb18c71a3074e5db29e04e99a8e1f67fae00cc` |
| `LanStash-1.0.15-x86_64.dmg` | 36,941,464 | `802d152deef4d48863660216d998918d9265addf23b84f210cf420b770dc423e` |
| `appcast.xml` | 6,316 | `231df110543b1817b19d05525aa453d41e159e1ea22918400c02660793bab52c` |

发布后本机重新下载两份 DMG、`SHA256SUMS.txt` 和 `appcast.xml`，执行 `shasum -a 256 -c SHA256SUMS.txt` 全部通过。另下载 `macos-updates/appcast.xml`，`cmp` 确认逐字节相同；首两项为 1.0.15（25），Apple Silicon 在前、Intel 在后，附件地址/长度/更新签名字段正确。签名验真由正式工作流完成。未安装或启动正式 Mac 包，未改 NAS 真实数据。

移动对齐固定在此发布提交，后续移动源码不会进入这个已发布标签；M0 两台模拟器证据见上一节，真实设备及 Finder/NAS 验收仍按各功能步骤进行。


## 2026-10-04 移动 M1 共享结构、会话与导航

本轮是 M0→M8 中的基础结构切片，未将 M2–M8 写成完成。原 File Station 图库的行为/测试迁移与最终清理随 M3 收敛，仍属源码待办。

实际修改：Photos 状态机和原版本 1 上传恢复存储迁入内部 `DsmPhotosFeature`，Mac 保留原安全范围书签适配，移动工程移除 Mac App 源文件引用；下载状态/操作从组合根移入 `MobileDownloadsModel`；缓存、活动记录与系统文件选择回调加入账号/连接上下文隔离。修改地址/端口/账号形成独立连接并清空表单旧密码，保留原配置及凭据；迟到密码不覆盖手动输入。原生导航以目标页面出现驱动加载，修复手势影响下载等入口的问题，并隔离 iPad 分组路径。登录重复标题、旧语言错误残留及英文账号文案同步修正。

测试增加 Debug 专用内存服务与 `DsmMobileUITests`，普通启动和 Release 均不进入样例模式；不访问真实 NAS，不放宽认证、证书或私有写权限。新增模块没有第三方依赖，不改变主 App 身份、最低系统版本、登录格式或 NAS 请求契约；Mac 修改仅限共享引用/书签适配及对应测试。

| 实际命令／范围 | 结果 |
| --- | --- |
| `swift build --package-path apple --target DsmPhotosFeature --jobs 4` | 通过；公共值类型明确遵循 Sendable，没有放宽并发检查 |
| `swift test --package-path apple --jobs 4 --filter 'SynologyPhotos|PhotoUploadRecoveryAdapter'` | 803/803，0 失败，含旧上传恢复和新平台适配回归 |
| `swift test --package-path apple --jobs 4` | 2427 项 XCTest、172 项既有环境/UI 条件跳过、0 失败，另 12 项 Swift Testing 通过 |
| XcodeGen 2.46.0 生成两个工程，移动 `build-for-testing` | 通过，包含新增 UI 测试目标 |
| `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` | 最终 iPhone：507 项单元 + 5 项真实 UI 测试全部通过；最终轮设置模拟器深色模式 |
| 同命令，iPad 目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` | 最终 iPad：507 项单元 + 5 项真实 UI 测试全部通过；浅色分栏独立运行 |
| `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=NO` | 通过；`lipo -info` 确认 arm64/x86_64，属于工程回归构建，未签名、未安装或启动此 Mac 产物 |
| `python3 tools/localization/check_localization.py`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 通过 |

两端最终结果分别保存在忽略的本地构建目录 `apple/Apps/DsmMobile/build/m1-iphone-final.xcresult` 与 `apple/Apps/DsmMobile/build/m1-ipad-2.xcresult`，包含界面截图附件。原生 UI 覆盖中英文登录、空输入恢复、语言选择持久化、文件/下载/设置导航、加载/空内容/错误/正常/筛选为空。额外通过 Simulator 实际点击复核 iPhone 下载入口、iPad 分栏及折叠搜索按钮。

迭代中发现并修复：旧源码断言仅比较配置 UUID；iPhone 标签栏测试需按系统标签定位；导航点击手势干扰原生 NavigationLink；iPad 搜索先由工具栏按钮展开。均保留原安全断言、修正实际流程或测试定位，没有跳过失败项目。

独立集成与只读对抗复核：重新检查 Mac 引用、平台书签/队列版本、切换目标前后的凭据身份、迟到回调、活动任务显示/重试以及 Debug 测试入口。新目标不会复用原配置会话或收到旧密码回填；当前进程中的旧任务记录可按原账号找回，但不会由新账号重试；旧文件选择回调在复制前后及入队后均有上下文核对。没有创建分支、PR、移动发布或真实 NAS 写测试。

未验证：实际设备的安全存储、系统选择器权限撤销、完整动态文字/VoiceOver/外接键盘矩阵，以及真实 NAS 时序，按移动主计划 `PENDING_USER_VALIDATION` 执行。跨重启任务恢复、后台传输、扩展和新业务入口仍在后续阶段；不能以本轮构建或 UI 样例宣称完成。


M1 云端文档检查修正：提交 `c776de72f40f5d80795c490010c9eba80860776b` 的 [Repository Check](https://github.com/yuangy1995/dsm-native-client/actions/runs/37147153437) 和[文档预检](https://github.com/yuangy1995/dsm-native-client/actions/runs/37147153419) 在 UTC 10 月 3 日将北京时间 10 月 4 日误判为未来；本机以 `TZ=UTC` 复现。检查器现统一按项目北京时间 UTC+08:00 取日，不修改系统时区、不放宽未来日期或时效门。新增跨日、同一时刻不同时区及真实未来日期拒绝回归，工具测试 107/107 通过；`TZ=UTC` 和 `TZ=America/Los_Angeles` 下的 `check_documentation.py --strict-release` 均通过。此增量不改变客户端或 NAS 契约，云端最终状态另按实际运行结果记录。


## 2026-10-04 移动 M2a 可恢复传输与目录上传

本切片为 M2 的文件传输基础，不代表 M2 全部高级文件管理或 M3–M8 完成。Mac 只迁移已有上传计划/批次到内部 `DsmFileFeature` 并调整引用；增加可选恢复检查点和提交前保存回调，原 Mac 调用不启用新存储。没有修改 Windows/Android 或 NAS 请求契约，也没有访问或写入真实 NAS。

- 移动文件入口统一接多选/目录上传确认：空目录和隐藏文件保留，符号链接跳过，同名默认跳过，替换单独说明原内容可能无法恢复。活动按文件显示结果，可暂停、继续、重试明确失败项、只读取未知结果、清除已结束任务的本机副本。
- 传输记录和批次副本位于独立受保护目录并排除备份，不保存凭据、不迁移登录格式。阶段落盘失败不提交；恢复后未提交项暂停，已提交上传只查询，下载可从头恢复。完整内容比对确认未知上传，不能只凭同名和大小判成功。
- 任务绑定 NAS/账号上下文；迟到选择器结果不进入新会话。系统下载导出面板由工作区统一持有，从活动页恢复也可展示；系统面板关闭后清理受控副本，不改用户原件。旧图库使用的单文件上传桥仍随 M3 清理，正式文件页已使用批次。
- 新增 Debug 合成目录上传 UI 场景；只使用隔离测试目录和内存网络，不读取真实配置或登录资料。其验证范围是原生确认/活动/重启流程，不等同系统 Files 选择器、真实文件提供商或 NAS 的实机验收。

实际命令与结果：

| 命令／证据 | 结果 |
| --- | --- |
| `swift build --package-path apple --target DsmFileFeature --jobs 4` | 通过 |
| `swift test --package-path apple --jobs 4 --filter 'FileUploadWorkflowTests|WorkspacePresentationTests.test.*上传'` | 8 项上传行为通过；6 项既有合成截图测试按环境要求跳过，不能算 UI 验收 |
| `swift test --package-path apple --jobs 4` | 2427 项 XCTest，172 项既有环境/UI 跳过，0 失败；另 12 项 Swift Testing 通过 |
| XcodeGen 2.46.0 生成 Mobile/Mac 工程；移动 `build-for-testing`，`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` | 通过；复用 M0 的专用模拟器与忽略的 `build/m0-m8` 目录 |
| iPhone `xcodebuild test-without-building ... -parallel-testing-enabled NO` | 523 项单元 + 6 项实际 UI 全通过；`apple/Apps/DsmMobile/build/m2-upload-iphone-full.xcresult` |
| iPad 同命令、独立目标 | 523 项单元 + 6 项实际 UI 全通过；`apple/Apps/DsmMobile/build/m2-upload-ipad-full.xcresult` |
| macOS `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` | 通过；只构建，不安装或启动，不重发 1.0.15 |
| `python3 tools/localization/check_localization.py`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 通过；双语、占位符、资源引用、硬编码与文档一致性均通过 |

模拟器目标仍为 iPhone `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`、iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。已检查两端上传完成截图。第一轮恢复测试发现非法 mutation operation 标识（包含点），改为既有字母标识并增加生产适配器的内容匹配/不匹配回归；首次 UI 测试发现英文取消按钮过长将提交动作挤进工具栏折叠菜单，改用简短“取消／上传”后两端全通过。未降低断言或跳过新测试。

独立只读集成与对抗复核覆盖：共享提取仅保留一套目录上传业务；身份变化后的任务/文件隔离；复制完成前取消零上传；原子保存失败零提交；未知上传只查询、相同目标未知任务不重复写；完整内容不一致不能判成功；原件不被清理，记录或路径无效时保留原文件并拒绝写入。上述结论来自源码与合成测试，未提升为真实 NAS 行为验证。

`PENDING_USER_VALIDATION`：iPhone/iPad 真机系统 Files 来源授权、iCloud/第三方提供商、锁屏/进后台中断、低空间、真实 NAS 同名覆盖与断网恢复、VoiceOver/大字号/键盘。使用独立可丢弃目录与文件；预期暂停/恢复不重复覆盖、不串账号，结果与目标文件一致；仅回传 OS/App/DSM 版本、脱敏操作和错误类别，不回传凭据、主机或真实路径。系统后台任务、分享扩展和 Files 扩展未开发，仍在 M8，不能写成仅待真机验证。

M2a 补充：iPhone 深色外观下单独重跑目录上传/重启 UI 测试，1/1 通过（`m2-upload-iphone-dark.xcresult`），已查看深色截图，之后将专用模拟器恢复浅色。Mac Release 二进制实际包含 `x86_64 arm64`；Mobile/Mac 工程及共享测试方案用锁定生成器再次生成，摘要一致。M1 的源码提交 `c776de72` 对应 Apple Build 仍在云端运行，本机通过不冒充云端门禁完成。


## 2026-10-04 移动 M2b 高级搜索与目录选择

已实现多目录、名称/正文、类型、扩展名、大小、修改/创建/访问日期、所有者/群组条件；共享搜索请求和完整分页不变，新增可哈希值语义用于移动缓存。正文索引不完整时保留提示，不支持时显示恢复说明；清空正文关键词不退回普通搜索。目录选择复用现有浏览模型，不改变主页面位置。所有接口测试均为内存替身，未读取或写入真实 NAS。

缓存按完整条件隔离，切换连接/条件丢弃迟到响应；文件变更使包含该目录的多位置搜索缓存失效。目录导航清除条件并恢复目录页。iPhone 工具栏保留筛选与“更多”，iPad 直接显示上传及新建文件夹；上传仅在有效文件夹开放，模型也拒绝共享根目标。搜索结果不显示无关的根容量摘要。

当前已实际运行：共享 `swift test --package-path apple --jobs 4`，2427 项 XCTest（172 项既有环境/UI 跳过）、0 失败，另 12 项 Swift Testing 通过。两端第一轮聚焦行为各 41 项通过；新增高级搜索 UI 曾分别暴露紧凑工具栏入口溢出、弹窗背后同名测试元素和系统首次键盘提示干扰开关，已修正布局/定位并增加实际开关状态断言。其后高级搜索 UI 在 iPhone 深色与 iPad 浅色各通过，截图已查看。

最终验证：XcodeGen 2.46.0 生成移动工程；`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过。随后两端分别 `test-without-building ... -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test高级搜索通过文件夹选择应用条件并显示部分正文提示`：iPhone、iPad 均为 533 项单元 + 1 项高级搜索实际 UI 全通过。结果为 `m2b-search-iphone-final2.xcresult`、`m2b-search-ipad-final2.xcresult`（同一忽略的构建目录，iPad ID 沿用 M0）；最终 iPhone 深色、iPad 浅色，之后恢复 iPhone 浅色。其他四项工作区 UI（导航、基础搜索、加载/空/错误、目录上传及重启）已在 `m2b-search-iphone-ui2.xcresult`、`m2b-search-ipad-ui2.xcresult` 各通过；这些结果中的高级搜索失败已由最终轮补回，不能将前一结果包整体称为通过。

`python3 tools/localization/check_localization.py`（Apple 5597、Android 2188、Windows 3402）、`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 均通过。新增高级搜索行为覆盖条件透传、缓存、正文覆盖/错误、迟到响应、导航、变更失效和输入边界；上传增加共享根零提交回归。完整单元首次发现两处旧源码文本断言：现已改为检查连接身份（配置及 Repository）与有效文件夹/只读限制，保留原安全语义，不通过删除或跳过断言消除失败。

独立集成审查核对了搜索完整分页、完整条件缓存、账号隔离、正文缺失不降级、目录选择不写 NAS、原有只读来源限制、当前目录上传权限及双语资源。公开请求、其他端行为和既有存储格式未改。`PENDING_USER_VALIDATION`：真实 NAS 大目录/索引覆盖、实际权限，以及 VoiceOver、大字号、外接键盘；使用专用可丢弃目录查找已有测试文件，预期各条件生效且不串账号，仅回传脱敏版本、条件和错误类别。

M1 的 [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37147153425) 已完成并成功；文档日期修复后的 [Repository Check](https://github.com/yuangy1995/dsm-native-client/actions/runs/37147481568) 与[文档预检](https://github.com/yuangy1995/dsm-native-client/actions/runs/37147481548) 均成功。M2a `b675fc6e` 的 [Repository Check](https://github.com/yuangy1995/dsm-native-client/actions/runs/37149447493) 与[文档预检](https://github.com/yuangy1995/dsm-native-client/actions/runs/37149447500) 均成功，Apple Build 仍在运行；本切片未发布移动安装包或改动正式 macOS 标签。


M2b Mac 工程回归：`xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过；未改 Mac App 源码，不安装/启动或重新发布。Mobile/Mac 工程用 XcodeGen 2.46.0 重复生成后摘要一致。两端最终搜索结果截图已查看，文件容量摘要在搜索时隐藏；完整动态文字/VoiceOver 和真实 NAS 仍按设备待办执行。


## 2026-10-04 移动 M2c 归档与 NAS 任务

源码已接多文件压缩（ZIP/7z、级别、密码）、原生压缩包列表/编码/分页/条目选择、目录选择及解压选项。`FileArchiveBrowserModel` 从 Mac 迁到现有 `DsmFileFeature`，Mac 仅调整模块引用和编码评分委托；共享公共 NAS 请求未改。Windows/Android 无代码或契约变化。归档与 NAS 控制记录分别使用独立版本 1 受保护文件，不存密码，不迁移登录配置；写前保存失败不提交，重启/断连不自动重发。

归档绑定账号上下文和输出清单；压缩拒绝已有同名、源目录内输出和变化的源快照。解压校验完整清单、相对路径、扁平名称、源文件快照；默认不替换已有文件，不把已有同名当成本次成功。明确的完成回执结合输出类型/大小回读后才显示完成；无回执的中断保留原记录，不能仅凭同名认定成功或再次提交同一输出。已创建文件不自动删除，取消只进入原 Repository 持有的本次任务。局部输出或完成会刷新关联目录及搜索缓存。

NAS 任务按完整分页读取；页码、总量、漏项或重复异常保留上次完整快照。停止/清除绑定账号与原任务 ID、类型、创建时间、版本、方法及状态，沿用 Repository 的写前重读与写后回读。未知控制落盘并禁止重发，只有完整读取确认原任务结束或记录消失才解除；写前读取抛错不会被误锁为已提交。停止说明部分文件会保留；移除记录不删除文件。

共享 `swift test --package-path apple --jobs 4` 实际通过：2427 项 XCTest（172 项原有环境/UI 跳过），0 失败；另 12 项 Swift Testing 通过。macOS `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过，实际二进制为 `x86_64 arm64`，未安装、启动或重新发布。

第一轮移动测试发现压缩表单首次打开未携带选择项，已改为以文件/目标目录快照驱动弹窗；增加表单实际选中项断言，保留取消与账号变化清理。旧预览静态断言因增加归档清理语句而失效，现检查整个身份变更块内的清理动作，未删除安全断言。确认按钮首次定位命中弹窗后的原按钮，改为实际可点击的确认控件，并断言停止后的记录可清除、清除后进入空列表。第二轮 iPhone 549 项单元及 3 项新增实际 UI 全通过；之后补写前失败回归、任务分组及筛选空状态，最终两端结果继续登记。

独立集成与只读对抗复核覆盖：共享业务单一实现、Mac 行为未改；密码不落盘，坏记录保留；取消/账号切换不向新账号提交；写前保存失败零写；同一未结束输出防重复；已有文件与不完整任务列表不能证明新操作成功；NAS 控制的写前异常和提交后未知分开，失败时不隐式重试。所有新增交互使用双语资源，合成网络及独立 Debug 测试目录不读取真实配置或访问 NAS。

`PENDING_USER_VALIDATION`：两种真机使用可丢弃文件验证加密/大压缩包、编码、多层选择、ZIP/7z、权限变化、同名替换、断网/终止恢复及停止的最终 NAS 状态；预期不串账号、不重复提交，保留部分输出且原包不删除。VoiceOver、大字号、外接键盘和真实 NAS 文件名/时间行为独立验收。仅回传 OS/App/DSM 版本、脱敏步骤与错误类别，不回传凭据、真实地址或路径。无完成回执的中断不能证明成功，继续保留记录并允许选择其他输出位置；后台继续执行仍属 M8。


M2c 最终验证：XcodeGen 2.46.0 重复生成 Mobile/Mac 工程，摘要一致；`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过。两端分别执行 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<目标 ID>' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests`，均为 **550 项单元 + 10 项实际 UI 全通过**，无新增跳过。iPhone 目标沿用上列 ID，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；独立结果为 `apple/Apps/DsmMobile/build/m2c-archive-iphone-final.xcresult`、`apple/Apps/DsmMobile/build/m2c-archive-ipad-final.xcresult`。最终 iPhone 浅色、iPad 深色，结束后恢复 iPad 浅色；测试覆盖原有登录/语言、导航、文件五态/搜索、目录上传恢复及新增归档/NAS 控制流程。

`python3 tools/localization/check_localization.py`（Apple 5630、Android 2188、Windows 3402）、`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check` 均通过。新增归档 11 项、NAS 控制 6 项行为测试；既有 NAS 首页截断测试改为完整多页及同步验证。没有发布移动包或修改正式 macOS 1.0.15 标签。M2b 的 Repository Check/文档预检已成功，M2a/M2b Apple Build 仍在云端运行，不将本机结果代替云端状态。


## 2026-10-04 移动 M2d 分享与文件收集

已接入文件/目录混合多选创建、起止日期、密码和可写目录收集；全部分享的完整分页/筛选/多选、批量密码与日期编辑、撤销；单项访问对象、次数与收集信息编辑、实际成员分页选择、本机二维码、系统分享及短期本设备剪贴板。界面沿用共享 Repository 的结果方法，没有复制 NAS 请求。高级设置保留实际文件应用权限和成员核对；日期“保持”不覆盖原时间，设置密码需要收到成功回执与状态回读，不能仅凭已有密码标记推定成功。

创建/编辑/撤销的未结束身份先保存在独立受保护的 `sharing-v1.json`，不含密码、会话、分享 URL 或内部路径映射；坏记录保留、保存失败零提交。账号上下文隔离，注销保留，删除连接仅移除该连接记录。完整全部列表确认链接已消失可解除未知撤销；未知创建/编辑保持相应目标限制并允许查看最新列表，不推测新密码或重放请求。普通创建前明确按钮确认，文件收集、移除密码、替换访问对象和撤销分别说明具体后果，不增加仪式式勾选。

独立集成与只读对抗复核检查了完整原对象绑定、共享层写前/写后回读、超过 5000 项的全部分页、总量/重复异常拒绝、不以截断列表中的缺失推定删除、保存失败零写、未知提交跨重启防重复、账号切换迟到响应丢弃、密码只留当次内存及安全 URL。新增 20 项行为测试覆盖上述边界与混合结果；原 13 项分享测试保留。代码审查不代替真实 NAS 验收。

共享 `swift test --package-path apple --jobs 4` 通过：2427 项 XCTest（172 项既有环境/UI 跳过）、0 失败，另 12 项 Swift Testing 通过；最终短标题资源修改后 `swift test --package-path apple --jobs 4 --filter DsmLocalizationTests` 的 6 项 Swift Testing 通过。Mac 工程 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过；未修改 Mac App 业务、未安装/启动或重新发布。

第一轮新增测试暴露替身结果操作名不符合既有契约，已修正替身而未改变生产校验；高级设置 UI 改为重新打开后断言实际次数输入值。批量 UI 发现子目录顶部操作溢出，已将两端“上一级”移入“更多”、移除 Shell 重复刷新，保留文件页菜单刷新与下拉刷新。多选可包含目录供分享/压缩，目录批量复制/移动仍未实现，维持原限制并列入后续 M2；不能把该选择扩展当作其完成。修复后 iPhone 文件与文件夹混合批量创建实际 UI 通过，两项成功及可复制链接均有断言和截图。最终两端完整结果另行登记。

`PENDING_USER_VALIDATION`：两种真机使用独立可丢弃目录与专用账号，验证密码/日期保留与更新、具名成员、访问次数、文件收集、批量部分失败/撤销、网络中断/重启，以及系统分享/剪贴板/二维码。预期每项结果绑定原链接，扩大访问前说明后果，不重放未知写，不向其他账号泄漏链接。实际 NAS 写入、接收端访问、VoiceOver/大字号/键盘未验证；只回传 App/OS/DSM/套件版本和脱敏步骤/错误类别，不回传密码、链接、主机或路径。Agent 未向外部收件人发送链接，全部 UI 网络为内存替身。

M2a [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37149447568) 与 M2b [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37150909914) 已成功。M2c 的 Repository Check 和文档预检成功，Apple Build 在本次记录时仍在运行；本机验证不替代云端门禁。


M2d 最终移动验证：XcodeGen 2.46.0 生成工程，`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过。测试使用 `xcodebuild test-without-building`、同工程/方案/构建目录及 `-parallel-testing-enabled NO`。iPhone 的 `m2d-sharing-iphone-final.xcresult` 中 570 项单元全部通过，原批量 UI 失败在工具栏修复后补回；随后 `-only-testing:DsmMobileUITests` 的 `m2d-sharing-iphone-ui-final.xcresult` **14 项实际 UI 全通过**。iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，深色 `m2d-sharing-ipad-final.xcresult` 中 570 项单元与 13 项 UI 通过，批量 UI 因分栏溢出失败；进一步将 iPad 的上一级也并入菜单后，`m2d-sharing-ipad-toolbar.xcresult` 的 **570 项单元 + 批量创建和高级搜索 2 项实际 UI 全通过**（分别使用 `-only-testing:DsmMobileTests` 和对应 `DsmMobileUITests/MobileWorkspaceUITests` 方法）。不将包含中间失败的结果包整体记为通过；两端 14 项界面用例均已有通过证据。

已查看 iPhone 浅色批量结果、iPad 深色访问设置/批量结果和工具栏截图；iPad 测后恢复浅色。最终 `python3 tools/localization/check_localization.py`（Apple 5643、Android 2188、Windows 3402）、`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。M2e 权限仍是后续切片，未作为本次已验证功能或安装包发布。


## 2026-10-04 移动 M2e 所有者与权限

已接入共享权限读取/修改/只读查询、原生分组表单、所有者/群组与成员选择、全部十三项显式权限及四种继承范围、基础读写权限和目录应用范围。继承规则可以展开查看但不能编辑；共享根、挂载位置、回收站及实际授权不足保持只读。移动端用一次具体后果确认呈现账号、范围、访问移除与所有权转移，确认后草稿发生变化则拒绝沿用旧确认。Mac 业务与公开请求未改，Windows/Android 无实现或契约变化。

独立受保护版本 1 文件 `permissions-v1.json` 只保存配置、账号上下文摘要和未结束逻辑路径，不存内部映射路径、权限快照或凭据。提交前保存失败零写，损坏记录不覆盖；重复点击/未知结果不重放；同一会话保留原请求用于只读查询，重启后保留未知目标限制并可读取当前权限。删除配置只清理对应记录。保存后刷新失败仍保留已知成功反馈，但在重新读到权限前禁止再次编辑；权限改变清除当前账号的旧目录/搜索缓存，保留搜索条件并重新读取。

独立集成和只读对抗复核覆盖原对象/账号上下文、确认草稿冻结、实际访问授权、仅显式规则写入、成员类型、共享层两次权限/路径映射重读及自锁保护、递归任务状态与最终回读、保存失败/损坏记录、迟到回调、只读查询不重放，以及保护位置只读仍可展开。确认后的三个业务标志由实际展示的后果生成，不移除共享校验；无真实 NAS 读取或写入。

共享 `swift test --package-path apple --jobs 4` 通过：2427 项 XCTest（172 项既有环境/UI 跳过）、0 失败，另 12 项 Swift Testing 通过；最终两项短标题/错误资源调整后 `swift test --package-path apple --jobs 4 --filter DsmLocalizationTests` 的 6 项通过。Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过，没有安装/启动或发布。

首轮编译修正测试构造参数和 Swift switch 表达式使用位置。第一轮实际界面发现保存反馈位于长表单末尾，以及测试误读导航容器的启用状态、展开组标识覆盖内部开关标识。已把反馈移到顶部并滚动显示，保留开关独立标识，改为断言实际禁用按钮和继承项可展开，没有削弱只读检查。随后 `m2e-permission-iphone2.xcresult` 的 583 项单元和 3 项新增权限 UI 全通过，iPhone 浅色保存结果及确认截图已查看。补同配置账号隔离、保存后重新读取失败和权限变更缓存回归后，最终两端完整回归另行登记。

`PENDING_USER_VALIDATION`：两种真机、已授权可丢弃目录、管理员与普通账号，验证继承/显式权限、增加或拒绝访问、所有者/群组、目录范围、自锁拒绝、其他客户端同时改变权限、部分失败、断网和重启。预期原权限变化时不覆盖、共享根/挂载/回收站不修改、不把根项目匹配视为整个目录完成、未知不重放；内部请求仍按实际接口能力/权限/稳定对象保护。实际 NAS 权限行为、VoiceOver、大字号、键盘仍未验证；只回传 App/OS/DSM/File Station 版本、位置类别、脱敏步骤及错误类别，不回传账号、路径、权限明细或原始响应。重启后缺少原会话映射/任务证据的未知操作不能据当前状态判定完成，修改限制保留，不保存敏感快照来绕过该限制。


M2e 最终移动验证：锁定 XcodeGen 2.46.0 生成工程；`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过。两端分别执行 `xcodebuild test-without-building`、同工程/方案/构建目录、`-parallel-testing-enabled NO`：iPhone 的 `m2e-permission-iphone-final.xcresult` 为 **586 项单元 + 17 项实际 UI 全通过**；iPad（`A31ABDE2-186F-43DD-8D40-5EB9511A9289`）深色 `m2e-permission-ipad-final.xcresult` 为 **586 项单元及 16 项 UI 通过**，共享根继承项显示断言失败。查看实际录屏确认继承项位于弹窗可见区域下方，测试补滚动并断言可见后重新构建；两端分别 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test共享根权限只读且仍可展开继承规则` 的 `m2e-permission-iphone-inherited.xcresult`、`m2e-permission-ipad-inherited.xcresult` 均 **1/1 通过**，保留保存按钮及显式开关禁用的原断言。不将中间失败结果包整体记为通过。上述结果均位于忽略的 `apple/Apps/DsmMobile/build/`。

已查看 iPhone 浅色权限结果/确认和共享根截图、iPad 深色共享根继承项截图；iPad 测后恢复浅色。最终工程重复生成摘要、本地化完整性/硬编码检查（Apple 5654、Android 2188、Windows 3402）、严格文档和差异检查通过。M2c 的 [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37152701529) 已通过；本次移动源码不属于安装包发布，真实权限及辅助功能验收继续按上列条件执行。


## 2026-10-04 移动 M2f 远程位置与云连接

已接 SMB/NFS 创建、修改、断开及原任务分步继续，ISO 选择空目录加载/卸载，FTP/SFTP/WebDAV/云连接的创建、编辑、连接、断开和移除，以及原始远程 URI 目录分页/筛选/下载。文件页“更多”和位置列表可达，同一功能使用原生触控表单。云授权以系统 Safari 模态呈现，沿用一次性 IPv4 loopback 监听，不读取浏览器表单/Cookie；取消/完成关闭监听。`FileVFSForm` 与 `FileVFSCloudAuthorizationSession` 移入现有 `DsmFileFeature`，Mac 只调整引用和测试导入，公开/内部请求没有变化。

独立版本 1 恢复记录只保存原配置/账号上下文、操作身份和逻辑目标或摘要，不存密码、主机/云账号、令牌及完整回调。提交前保存失败零写；损坏记录保留；挂载的父子路径互斥，未知 VFS 原对象及新建别名禁止重放。共享 Repository 的原对象/实际权限和两步提交结果继续有效，同一会话只查询原请求；已知尚未执行的挂载步骤可重新输入密码并明确继续，不能放弃未知结果来重新提交。重启仅保留限制和当前状态读取，不能伪造原操作完成。删除配置仅清理其记录，账号切换丢弃旧界面反馈。成功的连接变化使旧目录/搜索/位置缓存失效。

独立集成和只读对抗复核覆盖上述身份/存储/凭据边界、共享校验单一实现、关闭新挂载后仍可断开旧连接、VFS 读取失败不阻断 SMB、明文连接具体风险确认、ISO 空目录与来源快照、断开不删文件，以及保存配置移除必须已经断开。新增 16 项模型行为与 4 项真实本机 socket 回调测试；后者验证错误路径/回调名、字段白名单、重复长度/额外请求拒绝、分段正文、完成及取消关闭端口，均不访问 NAS。

共享 `swift test --package-path apple --jobs 4 --filter 'FileVFS(Form|CloudAuthorization)Tests'` 的 16 项通过；完整 `swift test --package-path apple --jobs 4` 为 2427 项 XCTest（172 项既有环境/UI 跳过）、0 失败，另 12 项 Swift Testing 通过。Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过，不安装/启动或重新发布。

首轮编译修正 Swift 6 系统浏览器代理导入兼容和测试构造参数。第一轮两端均通过新增模型/本机回调，旧位置弹窗源码断言因新增关闭回调失败，已同步断言并保留全部安全限制；远程筛选 UI 错选背景文件页搜索框，现精确定位当前目录筛选。iPhone 的 ISO、SMB、VFS 创建/断开/移除 UI 通过；iPad 的 ISO、SMB 通过，最后一项反复等待系统动画结束，保留日志后中止并重启本次专用模拟器，不把该轮记为通过。界面复核另修正读取错误同时显示空目录、ISO 空列表下一步提示。

`PENDING_USER_VALIDATION`：两种真机、专用可丢弃共享和账号，分别验证 SMB/NFS、远程修改换位置/同位置恢复、域账号、ISO、FTP/SFTP/WebDAV、实际支持的云服务授权回调及保存、网络/前后台/重启、权限变化和未知结果。预期不串账号、不重复提交、不绕过远端证书/主机警示，断开保留原文件和目录；重启缺少原任务证据时保持相应目标限制。VoiceOver、大字号、iPad 键盘及真实 NAS 行为未验证；只回传 App/OS/DSM/套件版本、脱敏步骤和错误类别，不回传凭据、回调、主机、账号或路径。后台系统传输仍属于 M8。

M2d [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37155299594) 本轮返回失败：iPad 分享编辑用例在首次查询 Sample folder 时 UI 快照超时；日志没有业务断言差异，该用例两端本机已有通过证据。保留云端失败，不以本机替代，后续主分支门禁继续检查。


M2f 界面复验发现 iPad 导航进入远程目录后自动布局未展示筛选栏，已明确使用原生导航筛选栏；两端对应实际 UI 及原有导航/文件五态/搜索共 4 项复验通过。云授权最初的同名按钮定位已改独立标识；进一步实际呈现暴露 Safari 全屏使原 SwiftUI 表单触发 onDisappear，从而立即取消自身授权。通过仅合成会话的临时生命周期日志定位后，将清理移到宿主真正被移除时，保留显式取消/账号切换清理及尝试编号，阻止已关闭页面的迟到准备结果重新打开；临时诊断代码已删除。授权返回不再重置新连接别名。连接失败还保留共享层的服务器身份/云授权恢复提示，并补行为断言，不能笼统归因于权限。最终两端结果见下列记录。


M2f 最终验证：XcodeGen 2.46.0 重复生成 Mobile/Mac 工程，摘要一致；`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过。两端使用 `xcodebuild test-without-building`、同工程/方案/构建目录、`-parallel-testing-enabled NO`；iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。

- `-only-testing:DsmMobileTests` 的 `m2f-cloud-iphone4.xcresult` 与 `m2f-cloud-ipad4.xcresult` 各 **606 项单元全通过**；同包中的云 UI 当时仍因系统按钮定位失败，不将整个结果包记为通过。
- `m2f-remote-iphone2.xcresult`、`m2f-remote-ipad2.xcresult` 的 SMB 创建/断开、ISO 加载/卸载、VFS 创建/断开/移除三项 UI 均通过。
- `m2f-remote-iphone3.xcresult`、`m2f-remote-ipad3.xcresult` 的远程筛选与原有文件导航、文件五态、搜索共四项 UI 均通过。
- 云 UI 使用 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test云授权使用系统浏览器且取消后返回原表单`：`m2f-cloud-ipad6.xcresult` 与 `m2f-cloud-iphone7.xcresult` 各 **1/1 通过**。系统关闭按钮已从实际界面定位；iPhone 按该按钮实际边界触控后，断言返回原表单、可重新授权且没有保存按钮。测试只打开官方公开起始页并取消，不选择账号、提交云授权或写 NAS。

上述结果均在忽略的 `apple/Apps/DsmMobile/build/`，合计两端各 5 项新增及 3 项原有实际 UI 已有通过证据，无新增跳过。已检查 iPhone 浅色远程目录/ISO/系统浏览器及 iPad 深色远程列表/浏览器截图；iPad 测后恢复浅色。最终本地化完整性/硬编码（Apple 5671、Android 2188、Windows 3402）、严格文档及差异检查通过。Mac 二进制实际含 x86_64/arm64；未发布移动安装包。


## 2026-10-04 移动 M2g1 收藏维护

文件和文件夹菜单均可添加/取消收藏；位置列表支持滑动或长按移除，目录继续导航、文件转入现有预览。成功反馈放在页面内，不追加确认弹窗。收藏读取使用共享层既有 5000 项完整有界快照，超过上限显示限制；新增前读取当前清单及实际文件，移除绑定原路径与名称。独立受保护 `favorites-v1.json` 保存账号上下文、逻辑目标及操作方向；保存失败零提交，损坏保留，未知只读恢复，重启不会重发，迟到结果不进入新账号界面。

共享 Apple 增量新增 `removeFavoriteResult`，原 `removeFavorite` 保持；修正新增收藏回读在截断清单中缺少目标时误报失败的问题。移除结果也不能从截断缺失推定成功。公开 Favorite 请求、版本/字段、主 App 身份、既有配置格式均不变，Windows/Android 仅记录影响。独立集成与只读对抗复核覆盖当前会话/原目标、明确拒绝与断网未知的区别、写前记录、完整清单、取消、双击、重启、切换账号/Repository 及旧回执；没有连接真实 NAS 或测试真实资料。

`swift test --package-path apple --jobs 4 --filter DsmFileRepositoryTests` 最终 165 项通过，新增 3 项覆盖完整回读/权限拒绝、提交及回读断网、5000 项截断；首次截断测试错误使用 1000 项响应，实际请求上限为 500，修正合成分页后通过，未降低断言。完整 `swift test --package-path apple --jobs 4` 为 **2430 项 XCTest，172 项既有跳过，0 失败**，另 12 项 Swift Testing 通过。

XcodeGen 2.46.0 生成移动工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过。两端分别使用 `xcodebuild test-without-building`、同工程/方案/构建目录、`-parallel-testing-enabled NO`，iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；`m2g-favorites-iphone.xcresult` 与 `m2g-favorites-ipad.xcresult` 均 **614 项单元 + 2 项新增实际 UI 通过**。新增 8 项模型测试覆盖持续修改、截断防误判、未知恢复/持久化、损坏/保存失败、双击/迟到结果、账号隔离和权限拒绝。随后将结果弹窗改为页面反馈，并为收藏行增加稳定标识，补预览实际内容断言；最终 UI 与 Mac 结果另记下段。

`PENDING_USER_VALIDATION`：iPhone/iPad 真机与专用可丢弃文件/目录，验证收藏增删、另一客户端同时变更、断网、退出/重新登录及重启；预期不重复提交、列表截断不误报、文件收藏可预览、移除收藏不删除文件。VoiceOver、大字号与键盘交互仍待设备验证；只回传版本、脱敏步骤与错误类别，不回传账号/路径/原响应。File Station 设置仍在 M2g2 实施，不能以收藏交付代表完成。


M2g1 最终界面验证：第二次 `build-for-testing` 通过后，两端分别以 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<方法名>` 执行新增目录收藏/移除、文件收藏/实际预览内容，以及原有导航、文件搜索、文件加载/空/错误五项；`m2g-favorites-iphone2.xcresult`、`m2g-favorites-ipad2.xcresult` 均 **5/5 通过**。本切片全部结果包位于本机临时验证目录，没有新增跳过。已查看 iPhone 浅色移除反馈和 iPad 深色文件预览截图，iPad 测后恢复浅色。移动工程重复生成摘要一致；本地化完整性/硬编码（Apple 5676、Android 2188、Windows 3402）、`python3 tools/codex/check_documentation.py --strict-release` 和 `git diff --check` 通过。最终恢复错误文案补明确持续失败的支持路径，仅资源检查，不宣称重新执行全部 UI。

M2e 的 [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37156630957) 已完成并通过；M2f 的云端门禁仍在运行，不以本机通过替代其结论。

M2g1 Mac 回归：`xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过；实际二进制包含 x86_64/arm64，没有安装、启动或发布。


## 2026-10-04 移动 M2g2 File Station 设置

两端文件页“更多”已接入文件管理设置：常规开关、分享/收集具名账号、远程连接范围与本机/域/LDAP 账号名单、六类账号限速/每周时间表、分享页布局/颜色/页脚与 NAS/历史/本机/内置图片选择。iPhone/iPad 均以原生导航与分步表单操作；时间表采用星期选择和完整时段行，数值输入保留字段标签。各类保存独立执行；普通按钮直接保存，扩大访问范围使用说明具体后果的原生警告框。成功后重读并更新表单基线，保留滚动位置、允许继续编辑。

新增 `MobileFileSettingsModel` 复用共享 Repository，当前管理员、File Station 权限、原设置快照、具名账号与最终回读继续在共享层执行。独立受保护且排除备份的 `FileSettings/settings-v1.json` 只保存上下文/目标摘要及操作身份，不包含设置快照、账号名单、路径、页脚、图片或凭据。写前保存失败零提交；未知结果只读刷新，重启/更换 Repository 不复用旧回执或自动重放。图片上传异常保留图片摘要，用户从历史图片继续选取；图片上传与主题应用独立。没有新增依赖、身份、权限、既有存储迁移或 NAS 请求变化；Android/Windows 只同步接口影响记录。

独立集成与只读对抗复核检查身份/目标绑定、同 UUID 换账号的延后按钮任务、旧读取/写回、重复提交、原记录保护、重新打开/保存基线、来源与 uid/gid 区分、未配置限速和图片预览/上传/应用边界。13 项新增行为测试覆盖连续保存、管理员与配置拒绝、放宽权限确认、未知只读恢复、重启/重连、明确提交前失败、回读失败、损坏/不可写记录、重复点击、旧账号结果、图片摘要和时间表/速率边界。测试使用本机临时目录及合成服务，没有访问或修改真实 NAS。

- `swift test --package-path apple --jobs 4`：**2430 项 XCTest，172 项既有跳过，0 失败**，另 **12 项 Swift Testing 通过**。现有 `FileStationParityTests` 覆盖实际请求编码、管理员拒绝、原快照变化、具名授权差量、时间表/限速、挂载账号和图片回执/序列验证；未改变这些共享请求。
- 锁定 XcodeGen 2.46.0 生成移动工程，重复生成 SHA-256 同为 `c1519e0586c3371911db401bb82aa9acb3d4a557a740344e4ce7278a5fa28493`。最终 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过（`m2g-settings-build10.log`）。首次编译修正错误变量遮蔽、测试 String/Substring 类型及结果计数参数，未降低断言。
- 两端分别执行 `xcodebuild test-without-building`，同工程/方案/构建目录，`-parallel-testing-enabled NO`，iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。`m2g-settings-iphone.xcresult` 和 `m2g-settings-ipad.xcresult` 中 `-only-testing:DsmMobileTests` 均 **627 项单元通过**，没有新增跳过；同包中的首轮 UI 有失败，不将整个结果包记为通过。
- 六项新增 UI 为普通保存/连续编辑、扩大权限/取消/保存回读、账号继承/时间表、内置图片预览/主题应用、设置加载/错误/普通账号只读、名单空内容/搜索无结果；另运行原有导航、文件搜索、文件加载/空/错误三项。按 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<方法名>` 选择；第二轮 `m2g-settings-iphone2.xcresult` 与 `m2g-settings-ipad2.xcresult` 的普通保存、换图、空名单/筛选及三项原有回归均通过，其他失败保留如下。
- 首轮 UI 暴露重建表单重置滚动位置、隐藏保存反馈，已改为更新现有表单基线；确认弹出层没有显式取消按钮，改为原生警告框。第二轮定位到系统将确认按钮暴露为嵌套元素、加载动画类型是 ActivityIndicator、iPad 通用返回选择器误点背景页，分别限定警告作用域、增加本地化加载状态及稳定标识、按当前导航栏定位返回。最终第三轮 `m2g-settings-iphone3.xcresult` 与 `m2g-settings-ipad3.xcresult` 的权限确认、加载/错误/只读、时间表和换图 **各 4/4 通过**。合并上述记录，两端各 **6 项新增 + 3 项原有 UI 均有通过证据**。
- 最终 Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过（`m2g-settings-macos-build2.log`），实际二进制含 x86_64/arm64；没有安装、启动或发布。

本切片日志和结果包在本机临时验证目录，未加入仓库。已检查 iPhone 浅色时间表/连续保存与 iPad 深色分享页截图；加载状态有辅助功能说明，时段使用完整触控行和当前策略朗读，不依赖颜色。iPad 测后恢复浅色。本地化资源/硬编码检查通过（Apple 5691、Android 2188、Windows 3402），严格文档及差异检查通过。资源变更后的 Mac 构建已重新执行；共享业务层没有变动。

`PENDING_USER_VALIDATION`：iPhone/iPad 真机、专用可丢弃管理员/普通账号和测试图片，分别验证所有设置最终生效、目录服务名单和权限、NAS 时区/实际限速/群组继承、系统文件选择、四类图片及实际分享页面、另一管理员同时修改、断网/重启和旧账号隔离。预期取消零提交、未知不重发、原设置变化拒绝覆盖、没有回执的换图不误报成功。VoiceOver、大字号、外接键盘、系统选择器与真实 NAS 行为未验证；仅回传版本、脱敏步骤和错误类别，不回传凭据、主机、账号、路径、图片或原响应。M2 批量/目录管理、跨 NAS 及 Office 主动回传仍须后续实现，不能用本切片代替整波完成。

M2g2 最后复核补充：当远程访问范围不是“指定账号”时，页面显示逐账号权限只有在该范围下才生效的既有双语限制说明。此项只增显示条件和文案引用，重新构建及本地化/文档检查通过；不宣称为该文案重新执行整组 UI。


## 2026-10-04 移动 M2h1 批量文件夹复制与移动

同一多选工具栏接入文件/文件夹混合复制移动，继续复用共享 `copyMoveResult` 的源快照、实际权限、同名拒绝、任务完成与回读；未改 NAS 请求或共享业务层。逐项结果区包含已完成、失败、未知、取消和未开始项，取消后即使当前项成功也不再启动下一项。未知结果停止批次，界面说明可重新连接/刷新内容，不要求用户进行开发验收，也不提供可能重放的重试按钮。

现有 `MobileFileCopyMoveReviewBlocker` 增加独立版本 1 的 `CopyMove/pending-v1.json`，由组合根注入真实恢复目录；包含账号上下文、配置 ID、操作及源/目标路径，文件受保护且排除备份，不存凭据。每项请求前保存，明确结束才清理；损坏/不可写保留原件并零提交，未知跨重启保持原源/子树与目标限制，不能改目标绕过。迟到明确结果只结束原持久记录，不写新账号界面。删除配置只清理该配置记录，退出登录不解除限制。原登录格式和应用身份不变。

目标浏览按原始条目推进分页，整页没有可选目录仍可继续；共享 Repository 的根目录 `/` 明确转换为移动导航空路径。独立集成与只读对抗复核检查原目标与账号绑定、持久化前后边界、原快照重读、取消/迟到结果、重启重复提交和目录子树；没有连接或写入真实 NAS。Windows/Android 与 Mac App 无源码或协议变化，共享语言资源执行 Mac 回归。

- `swift test --package-path apple --jobs 4`：**2430 项 XCTest，172 项既有跳过，0 失败**；另 **12 项 Swift Testing 通过**。现有共享真实编码测试包含单目录复制与回读；移动端没有另造请求。
- XcodeGen 2.46.0 重复生成工程，SHA-256 同为 `dea144939f6af24fb7e86c15f3202b769c0b4eff40245cfa0fe2d5c3421d1958`。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 各轮通过，最后界面收尾另记下段。
- 两端使用 `xcodebuild test-without-building`、同工程/方案/构建目录、`-parallel-testing-enabled NO`；iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。`m2h1-iphone2.xcresult` 与 `m2h1-ipad2.xcresult` 中 `-only-testing:DsmMobileTests` **各 634 项全部通过**。7 项新增行为测试涵盖混合目录、整页筛空、写前落盘/中断重启、账号/子树/改目标隔离、损坏/不可写、取消后当前项成功、迟到清理与旧按钮；原批次“目录非法”断言随需求改为“符号链接非法”，另加明确目录成功断言。
- 首轮两端各 4 项新增 UI 均在目标列表失败：真实 Repository 根路径是 `/`，旧单元替身误用空路径，修复移动对接并让替身遵循真实契约。第二轮两端单元全部通过，但 UI 夹具误将权限直接放在 `perm` 内，被真实 Repository 按无写权限拒绝；修正为已有的 `perm.adv_right`，没有降低权限检查。两轮原有批量分享 UI 均通过。
- 第三轮 `m2h1-iphone3.xcresult` 与 `m2h1-ipad3.xcresult` 的混合复制/源保留、移动/源刷新为空两项 UI 均通过。冲突、未知和新增无权限用例的摘要已正确，但逐项断言未按 SwiftUI 将名称和结果合并的实际辅助功能结构定位；根据导出的界面树改为精确“文件名＋状态”。最终 `m2h1-iphone4.xcresult` 和 `m2h1-ipad4.xcresult` 的这三项 **各 3/3 通过**，未知用例实际终止并重启 App，保留记录后再次进入只显示结果，不再出现提交按钮。合计两端 **5 项新增 + 1 项原有实际 UI 均有通过证据**，不把中间失败结果包记为整体通过。
- Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过（`m2h1-macos-build.log`），`lipo -archs` 确認实际二进制含 x86_64/arm64；未安装、启动或发布。

日志/结果包和合成截图留在本机临时验证目录，不加入仓库。已检查 iPhone 浅色和 iPad 深色的逐项成功截图，触控结果行保留系统文字与朗读语义。资源完整性/硬编码检查通过（Apple 5695、Android 2188、Windows 3402），严格文档与差异检查通过；最终文档收尾继续执行同门禁。

`PENDING_USER_VALIDATION`：专用可丢弃文件夹、普通/受限账号、iPhone/iPad 真机，分别验证混合复制/移动后的嵌套内容、空目录、同名和权限、取消/断网/重启/账号切换。预期无覆盖、无重放、无继续启动未开始项，实际结果与 NAS 一致。VoiceOver、大字号、键盘和真实 NAS 内容完整性未验证；只回传版本、脱敏步骤及错误类别，不回传账号、主机、路径、凭据或内容。批量回收站、打包下载、跨 NAS 和 Office 仍为未完成源码范围。

M2h1 截图收尾：完成或结果暂不可用时，导航栏显示“关闭”，不再显示“取消”以暗示能撤销已完成操作。最终 `m2h1-build6.log` 构建通过；`m2h1-iphone5.xcresult` 和 `m2h1-ipad5.xcresult` 的混合复制/关闭返回源列表 UI 各 1/1 通过。iPad 测后恢复浅色；最终本地化、文档和差异门禁通过。


## 2026-10-04 移动 M2h2 批量删除与回收站恢复

单项和最多 20 项的删除/恢复沿用现有 Recycle 模型、文件多选和原生确认页，文件与文件夹可混合选择。普通删除明确可能永久删除，回收站内删除明确无法恢复；恢复原位置且拒绝同名覆盖，不自动新建缺失的原目录。逐项保留成功/失败/未知/取消/未开始结果，明确失败继续余项，未知或取消停止余项。删除前重新读取冻结对象及明确的删除权限；共享 Delete 完成后确认原目标消失，不能把权限拒绝当作删除成功。

现有 blocker 扩展为独立、受保护且排除备份的 `Recycle/pending-v1.json`，每项写前保存账号上下文和原源/目标，失败则零请求；退出登录不清理未知记录，删除配置只清理自身。未知记录覆盖源/目标子树及删除/恢复之间的重复操作；旧按钮和迟到结果不能影响新账号/弹窗，迟到明确结果只清理原记录。保留原登录格式、身份与权限。共享 `moveToRecycleResult` / `restoreFromRecycleResult` 补齐文件夹，继续路径/类型/修改时间/权限/同名/结果回读；目录大小不同不判为失败，也不声称逐个校验所有子文件。

独立集成和只读对抗复核检查共享根、回收站容器、远程位置、源快照、权限、原目录缺失、同名冲突、重复点击、取消、进程退出、损坏/不可写记录、旧账号和迟到进度。普通删除不再依赖发现回收站来承诺可恢复；旧照片兼容入口同步删除风险文案。未访问真实 NAS 或执行真实文件写入；Mac App、Windows、Android 无源码修改，API 文档记录五端增量影响。

- `swift test --package-path apple --jobs 4 --filter 'DsmFileRepositoryTests/test文件夹移入和恢复|DsmFileRepositoryTests/test回收站写操作拒绝|DsmFileRepositoryTests/test回收站恢复未知'`：**3/3 通过**，直接经过真实 Repository 请求编码和最终读取；旧“目录不支持”用例改为符号链接拒绝，并另加目录成功测试，未降低身份或权限断言。
- `swift test --package-path apple --jobs 4`：**2431 项 XCTest，172 项既有跳过，0 失败**；另 **12 项 Swift Testing 通过**（`m2h2-shared.log`）。
- XcodeGen 2.46.0 重复生成 SHA-256 同为 `04bc3ab7c2506aec280b31c93f3c59501545d8085a2e3fe1e303dbde6df725cb`。移动构建命令为 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。第一轮 Swift 6 并发闭包捕获错误、第三轮结果标题放置错误均已修正；第二、四、五轮构建通过，不把失败轮记为通过。
- 两端 `xcodebuild test-without-building`、同工程/方案/构建目录、`-parallel-testing-enabled NO`；iPhone ID 如上，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。`m2h2-iphone1.xcresult` / `m2h2-ipad1.xcresult` 的 `-only-testing:DsmMobileTests` **各 643 项通过**。9 项新增行为测试覆盖混合删除/恢复、明确失败继续、源被替换/权限未知、写前保存/重启、取消、迟到与旧按钮、恢复记录损坏、子树/账号隔离和伪成功。
- 首轮两端各 6 条实际 UI 中 4 条通过（权限拒绝、未知后实际重启、原有混合复制、永久删除）；普通删除断言触发 XCTest 128 字符查询限制，改为完整文字谓词匹配。恢复测试的合成目录详情误用共享显示名，真实 Repository 按规范身份拒绝；修正夹具的 `getinfo` 目录名，没有放宽检查。第二轮两端普通删除/源刷新、文件夹恢复成功/同名文件保留均通过，五项新增及一项原有 UI 已各有独立通过记录，完整第二轮结果另记下文。
- Mac 命令 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过（`m2h2-macos-build.log`）；`lipo -archs` 确认 x86_64/arm64。未安装、启动或发布 Mac 包。

合成日志、结果包与截图只保留于本机临时目录，不入仓库。iPhone 浅色未知结果已人工查看；第二轮 iPad 使用深色检查确认与结果页。真实 NAS/嵌套内容/权限策略和真机辅助功能按主计划 `PENDING_USER_VALIDATION` 后置，不能由模拟器或构建通过代替。下一切片为打包下载，跨 NAS 和 Office 仍为未完成源码范围。


M2h2 第二轮 `m2h2-iphone2.xcresult` 与 `m2h2-ipad2.xcresult` 各 **3/3 UI 通过**（68.298 秒 / 70.589 秒），包含普通删除、混合恢复冲突和永久删除。已人工查看 iPhone 浅色未知结果、iPad 深色永久删除确认及恢复部分成功截图。确认页收尾移除重复“项目”标签，删除按钮明确使用红色，动作后果和权限门不变；重复点击的显式断言并入现有取消用例，未增加或替换测试数量。最终界面和聚焦重测结果继续记录于下文。


M2h2 `m2h2-build7.log` 通过；`m2h2-iphone3.xcresult` / `m2h2-ipad3.xcresult` 各 **15 项回收站单元 + 1 项永久删除 UI 全部通过**，包含新增的重复点击断言及确认页文案/红色按钮收尾。

最终安全复核发现共享 `deleteResult` 使用 `trimmingCharacters` 会把尾部空格文件名改为另一目标。已改为按原路径去重，保持提交、互斥和回读身份一致；新增合成测试同时删除带/不带尾部空格的两个独立路径，断言请求与逐项回读均未混淆。既有非法路径测试增强为根路径、上级路径及前导空格非绝对路径均零请求。此为防止误删的必要共享修复，不涉及实际 NAS，不更改 Mac App，未另行发布 macOS；最终共享/两端/Mac 重跑结果继续记于下文。


M2h2 最终原路径修复后，`swift test --package-path apple --jobs 4`（`m2h2-shared2.log`）为 **2432 项 XCTest、172 既有跳过、0 失败，另 12 项 Swift Testing 通过**。相同 Mac 构建命令再次通过（`m2h2-macos-build2.log`）；移动 `m2h2-build8.log` 通过，随后两端 `m2h2-iphone4.xcresult` / `m2h2-ipad4.xcresult` 正常批量删除及源列表刷新 UI **各 1/1 通过**。第二、三、四轮是针对实际修正的重测，第一轮失败不计整体通过。最终本地化检查为 Apple 5707 / Android 2188 / Windows 3402，严格文档和差异门禁通过，iPad 测后恢复浅色。


## 2026-10-04 移动 M2h3 文件夹与多项目下载

基于现有公开 `downloadArchive` 和移动前台传输，接入单文件夹 ZIP、混合多项 ZIP 及系统保存/分享；多选单文件仍保留原格式。只读源可选择，写能力继续独立限制。下载前核对完整源清单、类型与读取权限，精确保留尾部空格路径；源清单摘要用于重复点击保护，与显示名/语言无关。取消后清除部分副本，重启只有原账号可主动从头下载，迟到结果不向新账号展示。

现有独立传输记录接受版本 1/2，含打包源清单时保存版本 2；旧 App 版本检查拒绝并保留原件，不会按第一个源文件继续。副本完成后明确设置文件保护，排除备份；不修改登录配置。活动显示实际 ZIP 名称；文件列表大小改用当前 App 语言，缺失大小为 `--`。共享网络请求、Mac App、Android/Windows 源码保持不变，测试仅用合成数据和系统模拟器，不访问 NAS。

- `swift test --package-path apple --jobs 4`：**2432 项 XCTest、172 项既有跳过、0 失败**，另 **12 项 Swift Testing 通过**（`m2h3-shared.log`）。
- Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` **通过**（`m2h3-macos-build.log`）；`lipo -archs` 确认实际二进制 x86_64/arm64。未安装、启动或发布。
- XcodeGen 2.46.0 生成移动工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：第一轮通过，第二轮因新增测试替身声明为基础 transport 而非二进制 transport 失败，修正声明后第三、四、五轮通过；未放宽下载断言。
- 两端 `xcodebuild test-without-building` 使用同工程/方案/构建目录、`-parallel-testing-enabled NO`；iPhone ID 如上，iPad ID `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。首轮 `-only-testing:DsmMobileTests` 在 `m2h3-iphone1.xcresult` / `m2h3-ipad1.xcresult` 中 **各 653 项全部通过**。其中 10 项新增行为覆盖只读/原路径、真实 Repository 请求及无 Range、类型/权限改变、版本兼容、原账号重启、失败重试、取消/迟到、重复点击和非法恢复原件保留。
- 首轮实际 UI：下载失败与活动重试入口两端通过；系统分享实际出现正确 ZIP 名称/类型，但系统替换了根视图标记，两端测试查找失败。iPad 文件夹系统导出/取消通过；iPhone 导出打开成功，但文件选择器自动进入上次目录，取消按钮切换为返回入口，原点击定位失败。已依据真实 UI 层级改查系统分享容器/标题，并等待保存面板稳定后返回顶层取消；不是下载请求失败。最终修正及文件保护断言的重测另记下文，首轮结果包不记为整体通过。

独立集成和只读安全复核检查原清单/类型/账号、摘要去重、旧版本拒绝、原件保护、取消清理、晚到面板和旧单文件路径；共享层不新增写请求。界面加载/空/筛空/错误仍沿用原文件页，新入口与系统交付通过实际 UI 验证。真实 NAS 下载完整性、系统写出到用户选定提供方、锁屏和辅助功能不得由模拟器打开面板替代；待办见主计划。


M2h3 第二轮 `m2h3-iphone2.xcresult` / `m2h3-ipad2.xcresult` 的 **3 项新增实际 UI + 1 项原有导航 UI 各全部通过**，iPad 使用深色，截图已查看 iPhone 分享和 iPad 系统保存面板。50 项聚焦单元中各有 1 项新增文件保护属性断言失败；第三轮尝试按字符串读取仍失败，确认模拟器未返回该系统属性，不能据此声称真机加密生效。该不可在模拟器执行的硬件验收移入明确的 `PENDING_USER_VALIDATION`，没有改为静默跳过；改为直接验证生产服务交付前请求 `.complete` 保护并增加设置失败即清理、禁止面板交付的行为测试。

第七轮构建发现直接持有 `FileManager` 不符合 Swift 6 Sendable，改为传入同步 `@Sendable` 的保护设置函数；生产默认仍调用 Foundation，不放宽并发检查。后续最终构建/单元结果在下文记录。系统文件保护实际锁屏效果需真机，自动化只证明调用参数、时序及失败处理；系统保存测试打开原生面板并取消，没有向其他服务写出测试文件。


M2h3 最终 `m2h3-build8.log` **构建通过**；`m2h3-iphone4.xcresult` / `m2h3-ipad4.xcresult` 各 **654 项全部单元通过**，其中 11 项打包下载行为含最终副本保护失败的清理/禁止交付。第三轮只有错误假设的系统属性断言失败，未把该结果包算作通过。第二轮四项实际 UI 已分别全部通过，最终异常清理逻辑由新行为测试覆盖；没有无理由重跑整组 UI。

XcodeGen 2.46.0 重复生成 SHA-256 为 `a6f07921bf9109d17b4be3934bd0da43582a742c08986de0f9dfaae9b6f13521`。本地化完整性/硬编码扫描为 Apple 5711 / Android 2188 / Windows 3402，通过；最终严格文档及差异检查均通过。所有临时日志、结果包与合成截图在本机临时验证目录，不进入源码；真实 NAS、系统实际写出和设备文件保护仍按主计划设备待办验收。


## 2026-10-04 移动 iPad 搜索与目录测试定位修正

M2g2 提交的 [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37162193861) 在完整移动回归失败：iPad ISO 的通用 `Any` 后代查询超时，账号限速搜索误选背景文件页的 `Search files`，点击后丢失键盘焦点。已读取云端日志和 xcresult；未修改业务/权限/请求，只将两处定位分别改为已存在的目录按钮和 `Search accounts` 搜索框，保留原成功、空列表及筛选结果断言。ISO 的长时间 AX 查询超时本机未复现，精确限定控件后仍须以新云端完整结果确认，不宣称所有 CI 已通过。

`xcodebuild build-for-testing` 沿用 M2h3 的同工程/方案/模拟器/构建目录及临时签名参数，通过（`m2-ui-query-build.log`）。随后 `xcodebuild test-without-building`、`-parallel-testing-enabled NO`、两端分别以 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/testISO选择空目录加载并可卸载` 和 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test限速名单空内容和搜索无结果提供恢复路径` 重测；`m2-ui-query-iphone.xcresult` 与 `m2-ui-query-ipad.xcresult` **各 2/2 全部通过**。该增量只改 UI 测试定位，不重复无关共享逻辑测试；本地化/严格文档/差异门禁在提交前再次检查。


## 2026-10-04 移动 M2h4 跨 NAS 复制与分步移动

范围为移动 Files 的单项/多选传输、两端会话装配、独立清单和活动恢复，以及完成复制后的独立删源确认。`Features/Files/CrossNAS` 复用共享 Repository，不复制网络实现；`CrossNAS/queue-v1.json` 只保存两端身份摘要和逐项数据，版本独立、受保护且排除备份。目标重名不覆盖，文件以 MD5 和原大小/类型核对，目录完整分页；未知文件上传只读恢复，未知目录创建不根据同名对象认定归属。删源先重新检查两端文件/目录和当前权限，逐项非递归删除；删除未知仅回读，完成项不重放，源列表自动刷新。真实 NAS、后台系统执行及公开接口缺少条件删除事务的并发窗口继续按 M2h4 待办验收。

独立集成与只读对抗复核检查了：两端分别加载保存会话及 TLS 规则、源退出/目标移除的迟到返回、同名文件和挂载路径、分页重复及目录新增、内容同大小改写、逐项写前持久化、丢回执后的归属、取消和非递归删除。发现并修正准备期间移除目标仍可能继续的问题、上一文件进度迟到影响下一项显示的问题，以及部分删除后的提示不能宣称所有原件仍保留。移动端不采用 macOS 原有复制后直接递归删源流程，也未顺手修改 Mac 文件。

实际执行：

- 锁定 XcodeGen 2.46.0 生成工程，重复生成 SHA-256 一致：`b6c3d34859d3992738e47a55d5c3ef350f56cb31c744b154d36e0a4f6c1cccd5`。没有改 Bundle ID、权限、签名、最低版本或新增依赖。
- `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 最终通过。前四轮依次发现局部错误变量遮蔽、测试传输未声明二进制协议、UI 测试查询写法及嵌套测试 Fixture 的主线程隔离，均修正后重新编译；没有降低 Swift 6 约束。
- `xcodebuild test-without-building` 使用同一工程/方案/派生目录、`-parallel-testing-enabled NO`、两台独立模拟器及 `-only-testing:DsmMobileTests`：iPhone `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F` 为 **674 项通过，0 失败**；iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 为 **674 项通过，0 失败**。新增 20 项覆盖空文件/目录、只读来源、两端内容和权限改变、完整分页、丢回执/部分删除、重启去重、迟到账号隔离、目标移除及存储失败；真实 Repository 合成链路要求每端使用自己的测试会话，并实际处理上传内容、摘要及非递归删除。
- 首轮同命令聚焦 `MobileCrossNASTests` 两端各 **17 项通过**；三项 UI 中断线恢复和重名/权限场景通过，删源确认文案超过 XCTest 简写查询的 128 字符限制失败，已改为完整 label 谓词匹配，没有缩短或移除确认断言。后续补齐 3 项会话/取消回归和源列表刷新。
- `swift test --package-path apple --jobs 4`：**2,432 项 XCTest，172 项既有条件跳过，0 失败**；另 **12 项 Swift Testing 通过**。共享变更仅双语资源，没有 Mac App 业务源码改动。
- `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过；`lipo -archs` 回读为 **x86_64 arm64**。没有安装、启动或发布。
- `python3 tools/localization/check_localization.py` 通过（Apple 5,747 / Android 2,188 / Windows 3,402）；`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。源码只读复核和模拟器证据不代表两台真实 NAS 验收。

- 最终三项 UI 均已分别通过：同一 `test-without-building` 命令以 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/` 分别选 `test跨NAS混合复制与移动删源分开确认`、`test跨NAS断线刷新后继续未开始项目`、`test跨NAS重名和只读目标保留来源并给出恢复方法`。第二轮两端各通过后两项；第一项测试误选背景同名按钮后，明确排除背景标识并断言唯一确认按钮。第三轮只复跑受影响第一项，iPhone **1/1 通过（41.324 秒）**，iPad **1/1 通过（47.962 秒）**，并验证移动后返回源目录自动显示为空。没有重跑已通过的无关测试或降低任何断言。
- iPhone 浅色、iPad 深色的实际表单、权限错误、活动明细和完成截图已检查，控件和恢复说明正常；设备辅助功能、真实证书/两端 NAS 及后台生命周期不计入上述通过。

代码同步和云端完整门禁分别记录，不将本机通过当作真实 NAS 验收或移动发布。


## 2026-10-04 移动 M2i Office 预览与主动回传

移动端增加六种 Office 格式的受控 Quick Look、原生分享/文件选择器交接、用户主动覆盖回传及活动恢复。共享 `OfficeDocumentSupport` 从 Mac 提取既有格式白名单、稳定文件副本和摘要算法；Mac 只改引用，自动保存行为不变。移动编辑记录使用独立受保护且排除备份的 `Office/sessions-v1.json`，原账号/文件基线、选回文件与上传快照分别固定。相同内容零上传，前后读取与 MD5 发现原件变化即停止覆盖；写前落盘失败零请求，上传未知只读恢复，重启不自动覆盖。未更改 DSM 请求、主 App 身份、旧配置或 Windows/Android 源码；真实 NAS 未参与自动化。

独立集成及只读对抗复核覆盖 18 项模型场景：原名/原位置、多轮保存、相同内容、同大小同时间的远端改写、权限撤销、权限检查期间内容变化、冻结上传不受编辑器晚到保存影响、丢回执回读、未知跨重启/禁止换文件重试、重复点击、会话切换与迟到结果、存储失败、未来/损坏版本、格式/符号链接拒绝、候选副本变化及记录隔离。另有一项新增模型测试覆盖六种格式与受控预览副本清理。

- `swift test --package-path apple --jobs 4`：**2432 项 XCTest，172 项既有条件跳过，0 失败（30.407 秒）**；另 **12 项 Swift Testing 全部通过**，包含既有 Mac Office 回归。日志 `m2i-shared1.log`。
- `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`：**通过**；产物 `lipo -archs` 为 **x86_64 arm64**，没有安装、启动或发布 Mac 安装包。
- 移动构建沿用 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。前两次发现进度闭包需要显式 `self`，已修正；第三至第七次构建通过，最终为 `m2i-build7.log`。
- 首次聚焦 `-only-testing:DsmMobileTests/MobileOfficeTests` 与 `MobileFilePreviewModelTests`：**45/45 通过**。补两项对抗场景后，`test-without-building` 关闭并行，iPhone 使用上述 ID，iPad 使用 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；`-only-testing:DsmMobileTests` 分别 **693/693 通过**，iPhone 11.366 秒、iPad 11.324 秒。结果包 `m2i-iphone1.xcresult` / `m2i-ipad1.xcresult`。
- 同轮新增实际 UI：iPhone **3/4 通过**，iPad **2/4 通过**；发现活动记录的编辑弹窗挂在 List Section 上未呈现，以及 iPad 权限错误在长表单底部不可见。将弹窗提升到页面根、错误移到表单上方，保留全部断言；同时补等待前一文档结束和重新进入时清理旧反馈。
- 最终同工程/方案/构建目录、`test-without-building`、`-parallel-testing-enabled NO`，分别选择 `-only-testing:DsmMobileTests/MobileOfficeTests` 及四个 `MobileWorkspaceUITests/testOffice…`：**每端 18/18 单元与 4/4 实际 UI 全部通过**。iPhone 模型 0.397 秒、UI 115.830 秒；iPad 模型 0.359 秒、UI 121.018 秒。结果包 `m2i-iphone2.xcresult` / `m2i-ipad2.xcresult`。四项为预览/系统交接与选回、主动保存后从活动继续、丢回执只读刷新、冲突/权限/相同内容恢复。

实际 UI 使用内存 NAS 与合成最小 Word 包，通过正式 Repository 和系统 Quick Look/分享/文件选择器；第二轮 iPhone 浅色与 iPad 深色实际文档、保存与权限错误截图已检查，测试后恢复 iPad 浅色。六种格式的真实编辑器、锁屏文件保护、真实 NAS 内容及辅助功能按 M2i 设备待办继续，不能以合成界面和模型测试替代。用户追加的默认两个导航入口与账号权限候选列表将在下一切片实现，不由本次 Office 验证覆盖。


## 2026-10-04 移动默认模块与账号权限导航

按用户补充要求，默认只显示文件与 App 设置，照片、聊天、下载、容器、虚拟机和 NAS 设置在设置中主动开启；候选同时要求当前账号授权与可用读取契约。文件工具栏保留活动入口，iPhone 使用动态系统标签栏，iPad 使用动态侧栏。复用既有内部只读 `DsmDesktopAppPrivilegesService`，Photos 单独调用既有 `access()`；不查询业务列表试探权限，不猜测 Photos 的桌面应用键。原偏好键与数组格式保持不变，已有显式选择保留，未保存设备默认空集。实际操作权限、危险写确认和恢复记录未改，无真实 NAS 请求或写入。

独立集成与只读对抗复核覆盖权限/能力取交集、管理员缺失键及显式拒绝、照片独立授权、摘要失败、证书/会话错误零追加探测、权限撤销后退出、旧偏好保留、重复刷新合并、切换账号迟到响应，以及快速重新配置时尚未开始的旧任务。最后一项增加取消前置检查，避免旧已取消任务抢占新连接读取；照片权限读取与工作区 Repository 实例分离，避免刷新破坏业务缓存。新增 10 项模型行为测试，原导航/设置测试按已批准的新语义更新，不删除业务安全断言。

- XcodeGen **2.46.0** 按 `apple/Apps/DsmMobile/project.yml` 生成工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：首轮新增测试误用错误枚举名称，已修正；第二至第五轮构建通过，日志 `m1nav-build*.log`。
- `xcodebuild test-without-building` 使用同工程、方案和派生目录，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`；iPhone ID 如上，iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。第一轮各 **701 项通过**；补快速配置取消回归后，最终 `m1nav-iphone3.xcresult` / `m1nav-ipad3.xcresult` 各 **702 项通过，0 失败**，分别 11.636 / 11.623 秒。
- 同一命令加六个 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test…`：默认两入口及按权限开关、权限刷新撤销、加载/空/失败、管理员六种模块、文件下载与设置导航、活动返回与直接切换设置。第三轮两端各 **6/6 通过**，iPhone 146.087 秒、iPad 175.958 秒。iPhone 浅色与 iPad 深色截图已检查。
- 第一轮 UI 两端各 3/7 通过；失败定位为测试点击开关外层而非实际控件、照片合成能力错误登记为 form，以及用请求次数模拟撤权。改为点击内层 Switch、真实 JSON 能力和访问下载列表后确定撤权；未放宽断言。第二轮 iPad **5/5 通过**，iPhone **4/5 通过**，其余失败为系统“更多”按系统中文显示、测试仅查英文；同时支持实际中英文系统标题后第三轮全过。独立的目录上传/重启和 Office 活动继续编辑在首轮两端均通过，证明活动迁入文件后既有闭环可达。
- `swift test --package-path apple --jobs 4`：**2432 项 XCTest，172 项既有条件跳过，0 失败，39.413 秒**；另 **12 项 Swift Testing 通过**。最终新增导航名称后，`swift test --package-path apple --jobs 4 --filter AppLanguageTests` 的 **6 项语言测试通过**。
- `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 两轮通过，最终日志 `m1nav-macos-build2.log`；`lipo -archs` 确认为 **x86_64 arm64**，未安装、启动或发布 Mac 包。

补充 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test中文模块设置可开启功能并保留原始文件名`：`m1nav-iphone4.xcresult` / `m1nav-ipad4.xcresult` 各 **1/1 通过**，分别 20.685 / 24.585 秒。界面使用中文入口与开关，NAS 文件名保留原文；测试后恢复 iPad 浅色。合计两端各有九项相关实际 UI 通过证据，其中七项为本轮模块/导航流程，两项为既有活动恢复回归。

真实账号权限、DSM/Photos 版本差异与辅助功能按主计划的 `PENDING_USER_VALIDATION` 继续验收。没有修改 Mac App、Windows 或 Android 实现；共享资源增加新键，私有接口文档/索引只记录移动使用范围，环境验证等级未提升。代码同步、云端完整门禁与真实 NAS 验收分别记录。


## 2026-10-04 移动 M3a 照片选择上传与恢复

正式 Synology Photos 页面增加系统 Photos/Files/目录选择、上传表单、逐项任务和恢复入口，复用共享状态机与已记录上传/相册协议。平台适配先生成按原账号隔离、排除备份且受系统保护的副本；沿用版本 1 记录，不迁移登录配置。目录层次、忽略/重命名、直接贡献相册、上传后加入相册及只补加入步骤保持既有业务语义。旧会话写入者停用后，迟到回执不能覆盖新会话队列；损坏记录不覆盖，未知上传只读恢复，取消及移除只清理自有副本。没有操作真实 NAS、修改 Mac App/Windows/Android、增加依赖或改变主 App 身份。

独立集成与只读对抗复核覆盖 15 项新增模型行为：原件/副本分离、重复提交、旧账号及选择器回调、未知跨重启、相册单步继续、直接贡献、写前落盘失败、损坏记录、权限/目标变化、符号链接拒绝、目录层次、缺失副本重新选择、同账号重连迟到落盘及未提交草稿清理。只在队列成功恢复后清理无引用草稿，损坏记录和失效书签保留副本。表单和队列使用中英文资源，上传期间保留取消/停止边界；真实硬件文件保护不由模拟器属性推定。

- XcodeGen **2.46.0** 按 `apple/Apps/DsmMobile/project.yml` 生成工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：第二轮因合成 actor 的不可变 profileID 隔离声明失败，修正为 `nonisolated let`；后续构建通过，没有降低 Swift 6 约束。
- `xcodebuild test-without-building` 使用同工程/方案/派生目录、`-parallel-testing-enabled NO -only-testing:DsmMobileTests`；iPhone ID 如上，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。最终 `m3a-iphone3.xcresult` / `m3a-ipad3.xcresult` **各 717/717 单元通过**，分别 11.768 / 11.907 秒。第一轮发现缓存 URL 属性没有察觉符号链接替换，改为实时文件属性并保留拒绝断言；损坏记录测试改用全新会话，避免仍在内存的旧队列先合法保存覆盖测试文件。第二轮各 716 项通过；加入草稿清理回归后第三轮 717 项通过。
- 同命令分别选择四个 `DsmMobileUITests/MobileWorkspaceUITests/test照片…`：上传结果及清理、相册加入失败继续、未知重启不显示重传/移除、中文表单与系统文件选择器。第三轮 iPhone **4/4 通过**，iPad **3/4 通过**。此前实际 UI 发现同一视图的两个 `fileImporter` 覆盖导致 Files 按钮不呈现，合并为一个并按选择类型切换；其余修复为使用实际按钮判断禁用、紧凑布局的分区标识及 iPad 系统分栏选择器定位，未降低业务断言。
- 第四轮仅复跑中文选择器：iPad **1/1 通过（29.836 秒）**；iPhone 的系统紧凑布局没有 iPad 的容器标识，仍有实际“浏览”按钮，按两种已观察布局修正定位。最终重测另记下文，不将失败结果包算作通过。
- `swift test --package-path apple --jobs 4`：**2432 项 XCTest、172 项既有条件跳过、0 失败（35.257 秒）**；另 **12 项 Swift Testing 通过**，日志 `m3a-shared1.log`。
- `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` **通过**，日志 `m3a-macos-build1.log`；`lipo -archs` 确认 **x86_64 arm64**。没有安装、启动或发布。

两端实际 UI 使用合成媒体与内存服务，iPhone 浅色、iPad 深色；已检查上传结果和失败恢复界面。Files 面板仅打开，没有向其他提供方写出数据。NAS/iCloud 媒体、真机锁屏、VoiceOver、大字号和键盘按主计划 `PENDING_USER_VALIDATION` 继续；M3 其余管理及 M8 后台未由本切片覆盖。API 文档和私有兼容索引只记录移动端接入既有契约，环境证据等级没有提升。

最终 `m3a-build8.log` 构建通过；第五轮仅复跑中文系统选择器，`m3a-iphone5.xcresult` **1/1 通过（32.501 秒）**，`m3a-ipad5.xcresult` **1/1 通过（30.882 秒）**。四项新增 UI 均有两端通过证据，已通过的单元与其余 UI 未无理由重跑。XcodeGen 重复生成 SHA-256 一致：`fb42e06f5f25f5b94aed06e09e8e30b2ba9a2c755ff5cfa7fd7c6fe9850dde44`。`python3 tools/localization/check_localization.py`（Apple 5794 / Android 2188 / Windows 3402）、`python3 tools/codex/check_documentation.py --strict-release`、`python3 tools/contract-validation/validate_fixtures.py`（29 组 / 48 引用）与 `git diff --check` 均通过。测试后恢复 iPad 浅色；日志、结果包和合成截图不进入源码。


## 2026-10-04 移动 M3b1 多选与普通相册

移动 Photos 增加触控多选、创建/加入普通相册、改名、封面、移除成员及删除相册。确认文案分别说明只移除相册关系或删除相册及链接，原照片保持。表单冻结原空间、相册及照片，候选完整分页；仅相册权限不依赖个人图库，原件权限不扩大。手机工具栏合并相册/上传操作并去除重复刷新；平板保留独立筛选。没有操作真实 NAS 或修改 Mac App、Windows、Android 源码。

独立版本 1 的 `Albums/pending-v1.json` 在写前原子保存，受系统保护并排除备份；只保存原对象及必要回执，不含分享口令或凭据。创建编号先落盘再回读，无编号不按同名推断成功；重启只恢复原操作，部分失败只继续剩余照片。损坏、跨账号或无法保存记录均保留保护，替换会话后旧写入者不能清空新记录。共享协议默认不支持，Mac 保持原调用；新增相册能力判断和删除当前相册后返回列表有共享回归，NAS 契约和真实证据等级不变。

独立集成与只读对抗复核覆盖冻结选择、旧表单/空间/账号、贡献者与所有者权限、加载取消、未知重启、无创建编号、写前保存失败、损坏记录、旧写入者、部分失败只补剩余项及关闭个人图库。末轮额外发现并修正只有相册权限时页面误显示图库权限错误；此类账号仍可创建空相册，不能据此编辑原件。

- XcodeGen **2.46.0** 按 `apple/Apps/DsmMobile/project.yml` 生成；重复生成 SHA-256 一致：`ee2267b2ed237a62cdfdaf591060a778ad4cdd07944686db220d6b50471e5241`。
- `swift test --package-path apple --jobs 4`：最终共享逻辑 **2435 项 XCTest、172 项既有条件跳过、0 失败（37.447 秒）**，另 **12 项 Swift Testing 通过**，日志 `m3b1-shared2.log`。含三项新增真实 Repository 合成测试：回执恢复且零重发、保存失败零请求/无编号不猜测、相册能力与原空间隔离。最终文案后另运行 `swift test --package-path apple --jobs 4 --filter AppLanguageTests`，**6 项通过**。
- `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 前八轮通过；末轮补仅有相册权限的显示修正，最终构建与结果在下文记录。
- `xcodebuild test-without-building` 沿用同工程/方案/派生目录、`-parallel-testing-enabled NO -only-testing:DsmMobileTests`；iPhone ID 如上，iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。第一轮各 727 项单元中三项新用例失败，原因是合成时间线没有返回新增照片的日期；修正 Fixture 后第二轮各 **727/727 通过**。第三轮最终工具栏版本仍各 **727/727 通过**，iPhone 12.670 秒、iPad 12.520 秒。
- 实际 UI 同命令以 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/` 选择中文候选加载/空/错误、多选创建改名、移除及删除保留原件、部分失败继续、未知重启及原有上传完成/清理。第一轮各 **3/6 通过**，三项失败同属合成时间线缺失；第二轮重测先前失败三项，各 **2/3 通过**，剩余为无标签进度控件不可被辅助功能识别。为进度增加双语加载标签和标识后，第三轮中文三态在两端通过；其余最终结果在下文记录。未降低任何成功/恢复/原件保留断言。

上述合成测试、构建和只读审查不代替真实 NAS、真机锁屏与辅助功能。详细 `PENDING_USER_VALIDATION` 路径见移动主计划 M3b1；相册分享、资料/目录、条件相册及其余 M3 功能继续独立切片。


Mac 共享回归构建沿用 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`；首轮完整构建与最终资源增量构建均通过（`m3b1-macos-build1.log` / `m3b1-macos-build2.log`），`lipo -archs` 确认为 **x86_64 arm64**。未安装、启动或发布 Mac 包。最终语言资源为 Apple 5805 / Android 2188 / Windows 3402；本地化完整性/硬编码扫描通过，29 组 fixture / 48 项私有文档引用校验通过。


第三轮 `m3b1-iphone3.xcresult` / `m3b1-ipad3.xcresult` 两端各 **6/6 实际 UI 全部通过**；未知创建跨重启仅刷新、部分成员继续及原上传/清理均通过。已查看 iPhone 浅色的改名后相册页和 iPad 深色的删除确认，工具栏、原件保留说明及结果入口正常；长相册名由系统标题截断，不影响原名或辅助功能标识。仅有相册权限的末轮用例单独追加，不用之前的 727 项代替其结果。


第九轮移动构建通过，第四轮 `m3b1-iphone4.xcresult` / `m3b1-ipad4.xcresult` 各 **728/728 单元通过**（12.155 / 12.040 秒），新增“仅有相册权限仍能创建且不显示图库错误”实际 UI 各 **1/1 通过**（29.495 / 28.664 秒）。合计六项相册 UI 加一项原有上传回归均有两端证据。复核实际 Repository 时进一步发现空相册命令仍要求至少一个原图库，已将该入口改为统一相册授权，所有者预检保持；新增合成请求测试覆盖创建/改名/删除与拒绝他人相册。此最后共享层变更后的完整回归和构建另记下文，不借用前一版结果。


最后权限修正后，`swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests` **516/516 通过**（2.878 秒）；第十轮移动构建通过，`m3b1-iphone5.xcresult` / `m3b1-ipad5.xcresult` 再次各 **728/728 单元通过**（12.657 / 12.782 秒）。全部移动用例含 11 项本轮相册模型回归；先前六项相册实际 UI 及上传回归的生产界面未再改动，未重复运行。测试后恢复 iPad 浅色，临时日志、结果包及合成截图不进入源码。


最终完整 `swift test --package-path apple --jobs 4`：**2436 项 XCTest、172 项既有条件跳过、0 失败（34.272 秒）**，另 **12 项 Swift Testing 通过**（`m3b1-shared3.log`）。与前次差异为补充实际统一相册授权的请求链路，未降低原件编辑/上传门禁。最终严格文档及差异检查通过。

最终共享权限修正后的 Mac Release 构建再次通过（`m3b1-macos-build3.log`），`lipo -archs` 仍为 **x86_64 arm64**。没有安装、启动或发布产物；M3b1 源码与本机验证收口，后续继续相册分享。


## 2026-10-04 移动 M3b2 相册分享设置

移动 Photos 接入相册与“与他人共享”列表的分享设置、具名用户/群组、保护设置及系统链接交接。表单冻结原对象和权限快照；无更改零提交，公开访问、移除保护及扩大成员权限有具体后果确认，关闭/换账号清除密码。未知成员列表不当作空名单，条件相册不授予上传，既有未知角色保留。当前分享编辑保留 Mac 个人图库访问及所有者要求；临时分享生命周期/照片收集是后续 M3b3，不由本切片计为已完成。

相册分享恢复写为版本 2，普通相册继续版本 1；原路径不迁移，旧客户端拒绝新内容并保留记录。记录不含密码、链接、口令、成员名称，仅保留身份/权限意图及关键回执。更新密码回执先保存，开启访问之前保存尝试阶段；跨重启只读，已有保护状态不能替代新密码回执，移除密码可按明确无保护回读确认。部分完成提示仍关闭并重新打开设置，不自动再次保存。Mac 仅将两种纯草稿逻辑移入共享模块，保留原参数、空格/Unicode、日期精度和夏令时语义。没有新增 NAS 请求、依赖、主 App 权限/身份，也未触碰真实 NAS 或修改 Windows/Android。

- `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests`：**520/520 通过（1.638 秒）**，日志 `m3b2-repository1.log`。四项新增测试验证非秘密记录/逐步骤回执、改密丢回执跨实例不误报、清除密码的明确回读以及持久化失败不能公开访问。
- `swift test --package-path apple --jobs 4`：**2440 项 XCTest、172 项既有条件跳过、0 失败（31.354 秒）**，另 **12 项 Swift Testing 通过**；日志 `m3b2-shared1.log`，包括迁移后原 Mac 密码和日期草稿回归。
- 锁定 XcodeGen **2.46.0** 生成移动工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 前两轮通过，日志 `m3b2-build1.log` / `m3b2-build2.log`。随后本地化扫描发现两处动态拼接资源键无法静态检查，改为明确分支引用；最终构建另记下文，没有修改扫描规则。
- `xcodebuild test-without-building` 使用同工程/方案/派生目录、`-parallel-testing-enabled NO -only-testing:DsmMobileTests`，iPhone ID 如上，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。首轮两端各 **739/739 单元通过**（12.579 / 12.633 秒），包含 11 项新分享模型用例：零更改/去重、完整密码、成员编号/条件角色、未知成员、确认取消/过期、旧账号/迟到候选、权限快照变化、版本 2 重启只读、部分完成和来源范围切换。

两端实际 UI、本机 Mac 构建与最终资源版本仍在验证，结果完成后单独补记。真实 NAS、系统分享实际发送和设备辅助功能按主计划 `PENDING_USER_VALIDATION` 执行；代码同步、云端门禁与真机验收不混用。


首轮实际 UI 两端均通过中文四态及原相册移除/删除回归；其余四项在系统保存确认的点击定位失败。读取失败层级后确认：同一个 `Save Changes` 控件同时呈现外层和内层 Button，且具有相同标识。测试改为在当前 alert 内选取该控件的首个匹配，保留具体后果、完成链接、成员、未知重启及部分完成断言；不改变业务确认流程。最终表单同时移除重复的密码/日期分节标题，并去除临时分享限制提示下无意义的重试按钮。


最终 Mac Release 构建（`m3b2-macos-build1.log`）通过；命令沿用 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`，`lipo -archs` 确认为 **x86_64 arm64**。未安装、启动或发布 Mac 包。第三轮最终移动构建已通过（`m3b2-build3.log`）；Apple 5816 / Android 2188 / Windows 3402 语言资源完整性及硬编码扫描、29 组 fixture / 48 项私有文档引用均通过。


第二轮最终 `m3b2-iphone2.xcresult` / `m3b2-ipad2.xcresult`：两端分别 **739/739 单元通过（12.513 / 12.650 秒）**，五项新分享实际 UI **5/5 通过（274.974 / 298.858 秒）**。覆盖公开下载与密码移除确认、具名成员、未知重启、部分完成保持关闭及中文加载/错误/候选空内容；原相册移除/删除回归在首轮两端通过（41.758 / 48.048 秒）。已查看最终 iPhone 浅色确认及 iPad 深色部分完成截图，具体后果、恢复提示和操作入口可见，无秘密显示。独立集成与只读对抗复核未发现待修缺陷；真实 NAS 和设备项目仍按主计划待验。

XcodeGen 2.46.0 重复生成一致，最终工程 SHA-256 为 `f94de91816c1fdcec5696e779d12d969954e31f6302a5f541b999fbd2e5e6f49`；严格文档与差异检查通过。模拟器测试后恢复 iPad 浅色；临时合成截图及测试结果不提交。相册分享设置源码收口，M3 临时分享、照片收集及其他管理继续。


## 2026-10-04 移动 M3b3 临时分享生命周期

移动 Photos 多选接入临时分享创建与同一弹窗设置，已有临时分享可停止或先保留普通相册。准备取消沿原操作清理，原照片保留。普通相册分享表单复用原有成员/保护设置，停止说明临时相册移除和可保留副本；未知结果不显示可用链接。恢复记录不保存链接、口令或密码；写前保存版本 3 临时命令与完整成员依据，独立版本 1 流程先保存下一阶段再清除旧操作，已确认副本不重复复制。分享回执增加可选临时身份，避免恢复后混入普通相册。Mac 不装配新存储，NAS 请求不变，Windows/Android 仅记录影响。

独立集成及只读对抗复核补上创建预检失败清除未提交阶段、准备完成与取消同时发生时仍清理已创建相册、恢复时保留临时身份。实际网络合成用例验证返回编号和完整成员恢复、成员变化保持未知、无编号不按同名追认、停止后删除只查询消失；模型用例覆盖旧回执与新阶段同时存在、取消/重启、明确失败保留、跨账号/损坏记录、写前保存失败及受限账号。

- `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests`：首轮 520 项通过（1.903 秒）；加入三项回执用例后 **523/523 通过（3.004 秒）**，日志 `m3b3-repository2.log`。
- `swift test --package-path apple --jobs 4`：首轮 **2443 项 XCTest、172 项既有条件跳过、0 失败（32.026 秒）**；最终共享逻辑第二轮同样 **2443 项、172 项既有条件跳过、0 失败（34.630 秒）**，另 **12 项 Swift Testing 通过**（`m3b3-shared2.log`）。
- XcodeGen **2.46.0** 生成移动工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：首轮分享弹窗绑定超出 Swift 类型检查时限，拆为具名 Binding 后第二轮通过。第三轮测试引用新增合成方法时使用了构建期间较早编译的服务快照，停止编辑后完整增量第四轮通过（`m3b3-build4.log`）；没有降低业务或测试断言。
- `xcodebuild test-without-building` 沿用同工程、方案和派生目录，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`；iPhone ID 如上、iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，本轮两端各 **751/751 单元通过（13.039 / 13.048 秒）**。其中 12 项临时分享行为测试均通过。

两端四项临时分享实际 UI 加原普通分享回归及 Mac Release 双架构构建仍在进行；结果完成后单独补记。真实 NAS、锁屏保护和系统辅助功能按移动主计划 M3b3 的 `PENDING_USER_VALIDATION` 验收，不能由合成测试提升真实环境证据等级。


首轮 `m3b3-iphone1.xcresult` / `m3b3-ipad1.xcresult` 两端各 **5/5 实际 UI 通过（190.667 / 218.680 秒）**，含四项临时分享主流程及一项普通相册分享回归。已查看 iPhone 浅色设置页和 iPad 深色停止确认，选片名称、成员、保护设置与停止/保留副本后果清晰。随后删去访问范围下重复的受邀成员说明，并加入独立中文流程；第五轮构建通过（`m3b3-build5.log`），中文实际 UI 另记结果。

最终本地化资源 Apple 5818 / Android 2188 / Windows 3402 的完整性、参数、资源引用和硬编码检查通过；29 组 fixture / 48 项私有文档引用校验通过。XcodeGen 2.46.0 重复生成一致，移动工程 SHA-256 为 `c1023c756becc19894b505b3aab0df55478f538c44378e587ad55fda68f32d8a`；严格文档及差异检查通过。


最终中文 `m3b3-iphone2.xcresult` / `m3b3-ipad2.xcresult` 各 **1/1 实际 UI 通过（35.643 / 39.973 秒）**，覆盖中文创建→设置→取消→保留原件；已查看最终 iPad 深色中文设置截图，重复提示已移除。合计五项新临时分享 UI 加一项既有普通分享回归均有两端通过证据。第五轮除新增中文测试外仅移除重复说明，没有修改行为模型；已通过的 751 项单元和其余 UI 未重复运行。

Mac 最终回归命令 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过（`m3b3-macos-build1.log`）；实际主程序 `lipo -archs` 为 **x86_64 arm64**。没有安装、启动或发布 Mac 包。iPad 已恢复浅色，临时合成截图、日志和结果包不提交；M3b3 源码及本机验证收口，照片收集继续 M3b4。


## 2026-10-04 移动 M3b4 照片收集请求

仅使用合成服务/响应、iPhone/iPad 模拟器和本机工具，没有对真实 NAS 进行写测试。实现范围和恢复格式取舍见[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m3b4-照片收集请求)。本轮结果保存在 `/tmp/lanstash-release-1.0.15.1x6wUX/m3b4-*`，不提交一次性产物。

- `swift test --package-path apple --filter SynologyPhotosRepositoryTests`：首轮编译发现摘要比较中的短路表达式未标记可抛出，改为显式空间判断；第二轮 **527/527 通过（2.097 秒）**。加入后页及重复分页用例后，`swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests` **528/528 通过（3.433 秒）**，日志 `m3b4-repository-final.log`。
- `swift test --package-path apple --jobs 4`：**2447 项 XCTest、172 项既有条件跳过、0 失败（31.449 秒）**，另 **12 项 Swift Testing 通过（0.036 秒）**，日志 `m3b4-shared1.log`。此后只新增一项网络分页测试，不改变共享业务实现；新增项已纳入上述 528 项聚焦回归。
- 锁定 XcodeGen **2.46.0** 按移动 `project.yml` 生成工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：首轮 Swift IRGen 在直接传入 MainActor setter 方法引用时崩溃，改为显式闭包；第二轮页面主表达式类型检查超时，提取具名空状态视图与弹窗 Binding；第三轮通过（`m3b4-build3.log`），未改工具链或关闭检查。
- `xcodebuild test-without-building` 沿用同一工程/方案/模拟器 SDK/派生目录，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`，目标分别为上述 iPhone 和 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` iPad；两端各 **763/763 单元通过（12.860 / 12.827 秒）**，包含 **12 项新增收集模型测试**。结果包为 `m3b4-iphone1.xcresult` / `m3b4-ipad1.xcresult`；同轮实际 UI 仍在运行，另记最终结果。
- `python3 tools/localization/check_localization.py` 通过，资源 Apple **5824** / Android **2188** / Windows **3402**；`python3 tools/contract-validation/validate_fixtures.py` 通过 **29 组 / 48 项**；`python3 tools/codex/check_documentation.py --strict` 与 `git diff --check` 通过。

首轮两端实际 UI 各 **6/7 通过**，失败均在“读取等待和错误”用例：测试查找 `Retry`，实际 `photos.retry` 英文为 `Try again`；等待和错误正文均已正确呈现。修正精确按钮标题，保留禁用保存与取消返回断言，并新增两种状态截图。首轮 UI 总耗时 **293.415 / 324.818 秒**。已查看 iPhone 浅色中文表单，以及 iPad 深色删除确认与空目录截图，目标和删除后果清楚。

收尾将相册专用的恢复提示改为当前更改的通用结果说明，避免将收集误称为相册；新文案沿用共享 L10n 资源，主应用不存在旧覆盖项，不复制无关资源。目录路径与“使用此文件夹”合并为同一底栏，统一按钮样式/44 点区域并补路径分隔符。第四/第五轮移动测试构建均通过；最终针对中文、重启、错误恢复及目录选择分别复验，结果另记。`swift test --package-path apple --jobs 4 --filter AppLanguageTests` **6 项 Swift Testing 通过（0.054 秒）**。

最终 `m3b4-iphone2.xcresult` / `m3b4-ipad2.xcresult` 两端各 **4/4 实际 UI 通过（179.051 / 201.278 秒）**，含正确英文按钮、新的恢复说明、中文表单和合并目录底栏。合计六项新收集 UI 和一项原有普通分享回归均有两端通过证据；业务模型没有在 763 项单元通过后改变。最终截图已确认浅色目录操作栏和深色错误恢复；iPhone 长英文目录标题改为原生行内标题，再作目录单项复验。

Mac 命令 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 首轮通过；共享文案收尾后第二轮同样通过（`m3b4-macos-build2.log`）。主程序 `lipo -archs` 为 **x86_64 arm64**。未安装、启动或发布 Mac 包。移动工程重复生成 SHA-256 不变：`2bc4c393644d8fc7755a28416f2ce9124e80a023c9c90022154e128c0150f69d`。

第六轮移动测试构建通过；最终行内目录标题在 `m3b4-iphone3.xcresult` / `m3b4-ipad3.xcresult` 各 **1/1 UI 通过（34.024 / 35.351 秒）**。最终代码没有新增运行失败或未解决编译问题；iPad 已恢复浅色。M3b4 源码及本机验证收口，真实 NAS/真机仍按主计划的 `PENDING_USER_VALIDATION` 后置，不据模拟器结果提升私有 API 真实兼容等级。

## 2026-10-04 移动 M3b5 条件相册

范围、Mac 证据、存储版本 5 边界和真实设备步骤见[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m3b5-条件相册)。本轮接入条件相册新建/编辑、来源草稿、媒体/日期/目录/评分/规则、建议与预览计数；共享请求和只读恢复共用原有集合归一化，未知字段与顺序保留，创建必须有返回编号。独立集成及只读对抗复核检查了所有者/目录权限、原快照、损坏摘要、跨账号、迟到响应、写前保存失败和丢回执不按名称猜测。全部自动化使用合成资料，没有真实 NAS 写操作。

实际命令（仓库根目录，Xcode 26.6、iOS Simulator 26.5）：

```bash
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests
swift test --package-path apple --jobs 4
swift test --package-path apple --jobs 4 --filter DsmFileRepositoryTests.test分享创建提交前取消不访问网络
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

移动分别运行 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=…' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath … -only-testing:DsmMobileTests`，并追加 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/…` 以下七项：`test条件相册创建添加关键词预览并保存`、`test条件相册编辑保留缺名规则并取消不写入`、`test条件相册中文建议搜索空结果与选择人物`、`test条件相册共享目录选择与空子目录导航`、`test条件相册未知重启限制重复创建`、`test条件相册读取等待与失败支持退出重试`、`test照片收集创建并显示可分享链接`。iPhone 为 `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果分别保存为临时目录下 `m3b5-iphone1.xcresult` / `m3b5-ipad1.xcresult`；iPad 本轮使用深色模式。

中间结果：共享网络 532 项通过（2.138 秒）。首次完整共享回归 2452 项、172 项既有条件跳过、1 项失败（35.404 秒），失败是既有文件分享提交前取消用例的“零读取”断言；提交前取消状态断言通过，未改该用例或降低断言，单项原样复验 1/1 通过（0.027 秒），完整复验 2452 项、172 项既有条件跳过、0 失败（38.506 秒）。首次/复验另 12 项 Swift Testing 分别通过（0.046 / 0.418 秒）。首次移动构建因新增测试误用 `openAlbum` 而失败，改为现有 `open` 后第二次构建通过。本地化首次动态键引用被扫描拒绝，改为十二项明确资源键后通过（Apple 5827 / Android 2188 / Windows 3402）。Fixture 29 组、私有文档引用 48 项及严格文档检查通过。两端各 774 项单元已通过（iPhone 16.027 秒、iPad 14.298 秒），包含本轮 11 项条件相册测试。首轮两端各 7/7 实际 UI 通过（306.214 / 358.939 秒），Mac 两次 Release 构建通过，`lipo -archs` 确认 x86_64 / arm64。截图复核后缩短条件表单标题、区分新建按钮、删除重复文件夹标签，并让添加/搜索/预览后关闭键盘；移除规则按钮补读出目标名称。第三次移动构建通过，第二轮各四项 UI 中创建/预览、编辑、目录均通过，中文搜索在清空关键词后失败；失败时输入已空，补显式滚动至按钮及空值断言后仍复现，第四次构建/第三轮单项 UI 继续失败，不能归因于点按位置。随后修正输入内容未变时重复回写也清空建议/取消读取的问题，来源切换及关闭仍显式清空，并新增一项在途/已返回建议保持测试；第五次构建通过；第四轮两端各 775/775 单元通过（13.110 / 13.074 秒），包含 12 项条件相册测试；中文搜索和创建预览两项 UI 均通过（iPhone 单项 41.402 / 37.394 秒，iPad 41.118 / 39.124 秒），保留找到人物并成功保存的原断言。最后双语资源为 5830 / 2188 / 3402，AppLanguageTests 6 项通过（0.041 秒）。不据此声明实机通过。

收尾复验仍用上述 `test-without-building` 命令：第二轮只选条件创建、编辑、中文建议、共享目录四项，第三轮只选中文建议，第四轮选全部 `DsmMobileTests` 加中文建议与创建两项 UI，分别保存 `m3b5-{iphone,ipad}{2,3,4}.xcresult`。源码、双语资源、过期草稿隔离及最终差异再次只读复核通过；新增规则未扩展 NAS 请求或删除原件。已导出并检查 iPhone 浅色的中文规则、来源目录、完整英文标题与可见预览数，以及 iPad 深色的旧引用、读取错误、表单标题与键盘关闭状态；完整辅助功能和真实 NAS 条件匹配仍按主计划待用户验证。最终工程经锁定 XcodeGen 重复生成检查，SHA-256 为 `f6165f999a62215c2b3927119377933e958fb79123ab1a0fa7943098ef20daad`，不改最低版本、应用身份、权限或原登录格式，临时日志/截图仅保留在仓库外，未提交。


## 2026-10-04 移动 M3b6 冻结相册恢复

范围对应[移动主计划 M3b6](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m3b6-冻结相册恢复)。复用条件表单与既有冻结快照，恢复普通相册无需条件功能/个人图库；重建明确确认旧册移除、原件保留、分享不转移。版本 6 独立记录仅含摘要/编号和删除阶段，兼容读取 1–5；删除前保存失败零删除，重启只读、未尝试删除则保留两册。Mac 原非恢复调用保持，NAS 请求契约不变，Windows/Android 无代码变化。所有验证使用合成内容，无真实 NAS 写入。

构建前独立集成及只读对抗复核覆盖原快照、账号权限、来源、未知回执、真实返回编号、阶段保存失败、重复点击、恢复不重放删除、原件保留与摘要隐私。新增网络用例包含普通恢复/关闭个人图库、五种重建恢复阶段、删除前保存失败及同实例后续只读、正常/明确拒绝删除、错误身份与另一快照；移动增加七项冻结行为测试及四项实际 UI。

命令与已知结果（环境 Xcode 26.6、iOS/iPadOS 26.5，日志及结果在仓库外临时目录）：

- `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests` **537/537 通过（1.864 秒）**，`m3b6-network1.log`。
- `swift test --package-path apple --jobs 2` **2457 项、172 项既有条件跳过、0 失败（34.948 秒）**，另 **12 项 Swift Testing 通过（0.071 秒）**，`m3b6-shared1.log`。
- `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 首轮测试源码使用不存在的 `XCUIElement.lastMatch`，构建失败；修正为查询匹配按钮的最后一项，不修改业务或工具链。第二轮及目标测试结果另记下文。
- Mac 使用 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`；结果另记下文。
- `python3 tools/localization/check_localization.py` **通过（Apple 5837 / Android 2188 / Windows 3402）**；`python3 tools/contract-validation/validate_fixtures.py` **29 组 / 48 引用通过**；`python3 tools/codex/check_documentation.py --strict-release` 和 `git diff --check` 通过。

第二轮移动构建通过（`m3b6-mobile-build2.log`）。iPhone/iPad 分别执行 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=…' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath … -only-testing:DsmMobileTests`，并选取 `DsmMobileUITests/MobileWorkspaceUITests` 中四项 `test冻结相册…` 用例与 `test条件相册创建添加关键词预览并保存`。iPhone ID 如上，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；结果包 `m3b6-iphone1.xcresult` / `m3b6-ipad1.xcresult`。两端各 **782/782 单元通过（13.483 / 13.688 秒）**，包含 7 项新冻结测试。首轮界面结果及复验见下文；iPad 使用深色模式。

首轮 UI：iPhone 5 项中 4 项通过、普通恢复的规则文字查询失败（总 244.702 秒）；iPad 5 项中 2 项通过，普通恢复文字查询及两项重建确认失败（275.811 秒）。导出无障碍树确认 `LabeledContent` 将标题和规则合并成单个文本，测试改为完整规则内容匹配；原规则内容断言保留。iPad 重建日志与截图确认选中了弹层下方同名工具栏按钮，取消弹层也无独立取消行，改用原生警告框及独立“替换相册”按钮，测试直接限定系统警告框。读取等待/错误/重启和既有条件相册创建在两端均通过。截图另发现已打开的空相册误用“没有相册”提示，改为当前相册无可显示照片及刷新路径，并增加中文回归断言。第三/四次移动构建通过；末轮本地化扫描发现新空内容资源与旧“可加入相册为空”键重名，改为独立 `mobile.photos.album.emptyContent`，保留旧资源用途，最终扫描 5839 / 2188 / 3402 通过。第五次构建及第二轮三项受影响 UI 结果另记下文。

最终移动构建 `m3b6-mobile-build5.log` **通过**。第二轮沿用上述 `test-without-building` 命令，去掉全部单元及已通过的读取/重启/条件相册项，仅选择 `test冻结相册普通恢复与不支持规则展示`、`test冻结相册重建确认取消后再提交`、`test冻结相册中文重建保留旧册显示部分结果`；结果 `m3b6-iphone2.xcresult` / `m3b6-ipad2.xcresult`，两端各 **3/3 通过（106.609 / 112.129 秒）**。四项新增 UI 均具备两端通过记录，不以 iPhone 代替 iPad。导出并检查了 iPhone 浅色普通恢复、中文规则与部分结果，以及 iPad 深色系统警告框、明确取消/替换和空相册/部分结果。iPad 测后恢复浅色；真实 NAS、VoiceOver、大字号、键盘和真机锁屏保护按主计划待用户验证。

Mac 首次完整构建及三次资源收尾增量构建均通过，最终 `m3b6-macos-build4.log`；`lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 为 **x86_64 arm64**。最初按中文显示名定位产物未找到文件，改为实际 `LanStash.app` 路径后核实；没有安装、启动或发布。末轮 `swift test --package-path apple --jobs 2 --filter AppLanguageTests` **6 项 Swift Testing 通过（0.043 秒）**。锁定 XcodeGen 2.46.0 重复生成工程，前后 SHA-256 同为 `f6165f999a62215c2b3927119377933e958fb79123ab1a0fa7943098ef20daad`；本切片没有新增工程文件。最终本地化、fixture、严格文档及差异检查通过，源码之外的临时日志、截图及结果包均未提交。


## 2026-10-04 移动 M3c 资料日期与标签

本切片使用合成照片完成多选及单张预览的评分、描述、拍摄日期、时间偏移和标签管理。复用照片管理恢复文件，版本 7 只保存编号、身份/目标摘要和提交阶段，兼容旧 1–6；日期偏移重启只读，新标签应用失败只补添加。未写真实 NAS。独立集成及只读对抗复核覆盖原快照/提供者身份、来源权限、同编号意图、未知回执、首次/中途保存失败、损坏阶段、取消/账号替换和摘要隐私；发现标签提交阶段未保存会留下永久未知，修正为明确未执行并补回归。恢复部分结果禁止从摘要构造重试写入，须重新选取真实照片。

初轮 `swift test --package-path apple --filter SynologyPhotosRepositoryTests` 因两个可抛出的短路表达式缺少外层 `try` 编译失败；修正后既有 **537 项通过（2.005 秒）**（`m3c-network2.log`）。新增五项用例后 `--jobs 4 --filter SynologyPhotosRepositoryTests` 首轮 **542 项中 1 失败**，原因是新双来源测试默认未授予共享读取权限；合成访问改为明确共享入口权限，产品检查不变。`--jobs 2 --filter SynologyPhotosRepositoryTests` 复跑 **542/542 通过（1.818 秒）**（`m3c-network4.log`）。随后增加标签提交记录保存失败及相册贡献者恢复两项回归，结果并入本轮完整共享测试。

锁定 XcodeGen 2.46.0 生成移动工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 首轮合成服务初始化闭包访问 actor 属性失败，改为捕获本地标签快照；第二轮及最终第三轮构建通过（`m3c-mobile-build2.log` / `m3c-mobile-build3.log`）。本地化初检拒绝动态资源键拼接，改为完整枚举引用；复验 **Apple 5847 / Android 2188 / Windows 3402**、fixture **29 组 / 48 引用**、严格文档均通过。未更改工具链或删除断言。

两端执行 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=…' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath … -only-testing:DsmMobileTests`，追加 `DsmMobileUITests/MobileWorkspaceUITests` 的六项 `test照片资料…` 与既有 `test冻结相册普通恢复与不支持规则展示`。iPhone ID 如上，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；iPad 使用深色，结果 `m3c-iphone1.xcresult` / `m3c-ipad1.xcresult`。完整共享及 Mac 回归、两端最终结果继续下记，不将进行中作为通过。

完整 `swift test --package-path apple --jobs 2` **2464 项、172 项既有条件跳过、0 失败（45.839 秒）**；其中网络 **544/544（2.979 秒）**，另 **12 项 Swift Testing（0.111 秒）**，`m3c-shared1.log`。Mac 命令 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 完整及资源增量两轮通过（`m3c-macos-build1.log` / `m3c-macos-build2.log`）；实际主程序 `lipo -archs` 为 **x86_64 arm64**，未安装、启动或发布。

首轮两端各运行 **794 项单元，2 项新用例共 4 个断言失败**（14.634 / 14.768 秒）。合成相册中共享照片的所有者编号错误写成当前用户，被既有来源检查拒绝；修正为共享来源编号 0，并加强来源/照片数量断言。另一用例重复调用“全选”导致再次打开表单前取消了选择，修正测试准备，保留所有编辑资格断言。其他单元通过。首轮全部 **7/7 实际 UI 在两端通过（294.664 / 355.980 秒）**，包括六项新增编辑流程和一项冻结相册回归。

截图复核发现 iPhone 英文标题被“Save Changes”挤短，改为独立简短“Save / 保存”；时间数量保留常驻标签，加载/错误/标签空内容改为完整弹窗状态，新增 3 个资源。预览测试滚动到标签后再断言实际可见，未移除内容断言。第四、第五及最终第六轮移动构建均通过（`m3c-mobile-build6.log`）；第二轮重跑完整单元和四项受影响 UI（描述/日期、中文偏移/标签、预览评分、加载/失败/空内容），结果包 `m3c-iphone2.xcresult` / `m3c-ipad2.xcresult`。首轮导出截图前结果包尚未封口，导出失败；等待命令结束后正常导出，不将导出失败算产品错误。最终本地化扫描 **5850 / 2188 / 3402** 通过，`swift test --package-path apple --jobs 2 --filter AppLanguageTests` **6 项通过（0.038 秒）**。XcodeGen 2.46.0 重复生成 SHA-256 均为 `86780c576e51809068814fdb26587b6283ea2cccafbe5e58a69a7fe9c7bc3e82`。

第二轮两端各 **794/794 单元通过（13.653 / 13.492 秒）**；四项受影响的实际 UI 两端各 **4/4 通过（172.988 / 195.009 秒）**。未再执行已通过且不受布局调整影响的未知重启、标签部分失败继续及冻结回归。每个新增编辑 UI 均有 iPhone 和 iPad 独立通过证据。合成服务未提供可打开的预览媒体，本轮仅证明预览中的编辑、错误降级和资料展示，不能代替真实媒体兼容性验收。真实 NAS、设备锁屏保护、时区/夏令时与辅助功能按主计划保留明确用户步骤；未自动修改 NAS 真实资料。

最终分别导出并检查 iPhone 浅色英文完整标题、标签空状态及滚动后的资料/标签，以及 iPad 深色中文时间偏移与完整空状态；状态文案及按钮可读，iPad 测后恢复浅色。最终本地化、fixture、严格文档和差异检查均通过，临时日志、结果包和合成截图不进入提交。


## 2026-10-04 移动 M3d 目录与移动复制

本切片对齐目录创建/重命名/排序/封面、目录与照片混合移动复制及删除，复用已有权限预检、原对象与目标检查和任务终态读取。受保护的独立照片管理文件增量版本 8 保存必要快照与真实编号/回执，兼容版本 1–7；重启只查询，不按同名推定创建成功，不重复写入。图库内拖放只传会话内随机标识，最终仍显示目标表单并由用户提交。独立集成及只读对抗复核覆盖错账号/来源、同编号不同意图、丢回执、保存失败、目录自身/后代、共享反向移动、覆盖/删除确认和部分结果不重放；集成复核另外收起混合目录选择下仅适用于照片的菜单，避免忽略所选目录。没有对真实 NAS 执行写入，也没有改变请求参数、应用身份或系统权限。

`swift test --package-path apple --filter SynologyPhotosRepositoryTests` 第一轮既有 **544/544（1.880 秒）**，加入六项目录恢复回归后 **550/550（2.455 秒）**，日志 `m3d-network1.log` / `m3d-network2.log`。`swift test --package-path apple` 完整 **2470 项、172 项既有条件跳过、0 失败（32.453 秒）**，另 **12 项 Swift Testing（0.044 秒）**，`m3d-shared1.log`。恢复覆盖双来源创建/重命名/排序、真实移动复制任务及递归总数、目录删除任务与完整父列表、封面回执/实际解码，以及缺编号零猜测、首次存储失败零写与错误身份拒绝。

XcodeGen **2.46.0** 按现有流程生成工程。实际构建命令 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：首轮合成目录数组表达式过于复杂，编译器无法完成类型推断；拆成明确的局部循环后第二至第四轮通过（`m3d-mobile-build1.log` 至 `m3d-mobile-build4.log`）。初次本地化检查拒绝排序资源键拼接，改为四项完整枚举资源引用，复验 **Apple 5858 / Android 2188 / Windows 3402** 通过；fixture **29 组/48 引用**、请求 **170 组/1 写结果**、严格文档及差异检查通过。

两端首轮执行 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=…' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath … -only-testing:DsmMobileTests`，另选择七项 `DsmMobileUITests/MobileWorkspaceUITests/test照片目录…` 与既有 `test照片资料预览可评分并显示标签`。iPhone ID 如上，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，iPad 深色；结果 `m3d-iphone1.xcresult` / `m3d-ipad1.xcresult`。两端各 **807 项单元全部通过（14.227 / 14.420 秒）**，含 13 项新增目录用例。首轮各 8 项实际 UI 中 6 项通过、2 项因系统确认按钮在辅助功能树出现相同标识的嵌套匹配而失败（316.605 / 362.899 秒）；失败分别为混合删除及复制覆盖确认，实际确认文案断言均已通过。修正新测试定位为首个匹配，不删除确认内容、提交或结果断言；其余通过项覆盖中文子目录封面、未知重启、拖放、创建/重命名/排序、等待/错误/空内容和既有资料预览。


收尾保留排序重试的同一草稿，并在混合目录选择时收起照片专属菜单；第五轮移动构建通过（`m3d-mobile-build5.log`）。两端以相同 `test-without-building` 命令重新运行完整单元及三项受影响 UI（创建/重命名/排序、批量删除、混合复制覆盖），结果 `m3d-iphone2.xcresult` / `m3d-ipad2.xcresult`；单元各 **807/807（14.106 / 13.891 秒）** 通过；三项实际 UI 各 **3/3（111.219 / 115.605 秒）** 通过，包含确认后结果和混合选择不显示照片专属操作断言。所有七项新增目录 UI 与一项既有资料回归均分别已有两端通过证据。

Mac 命令 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过，`m3d-macos-build1.log`；实际主程序 `lipo -archs` 返回 **x86_64 arm64**。没有安装、启动或发布 Mac App。首轮两端完成后分别导出 xcresult 附件；已逐张检查 iPhone 中文封面、英文移动目标/删除确认及 iPad 深色覆盖确认/错误恢复，标题与后果完整可见，错误占满弹窗可用内容区。封面图仅为合成图片，不代表真实 NAS 媒体体验通过。


最终生成工程重复运行 SHA-256 一致：`fa818e6627d097a94cba3d70ef54d784a4b3748b20551017adeb65911cce1698`。未修改 macOS App、Windows、Android 源码，不把两端合成结果当作真实 NAS 或真机结论。具体设备/专用数据、权限、锁屏/终止/切账号、拖放/键盘/VoiceOver 步骤及允许回传内容集中在移动主计划 M3d 的 `PENDING_USER_VALIDATION`；目录分享、完整任务控制、人物/相似组、旋转/预览设置、旧图库清理与后续 M4–M8 继续实施。

## 2026-10-04 移动 M3e 文件夹权限与照片任务

本切片接共享目录权限、成员搜索与角色、密码变更、覆盖子目录确认，以及照片任务筛选、错误详情、取消、逐项清除完成记录和打开原目标。恢复记录版本 9 仅新增两类操作，旧版本 1–8 仍可读；目录权限保留原快照摘要与成员编号/角色，不保存密码、链接或成员名称。任务控制使用独立受保护文件，避免阻断取消本 App 的移动复制；每项清除前保存范围，恢复只读取原对象，不重复发送原写。

`swift test --package-path apple --filter SynologyPhotosRepositoryTests` 基线 **550 项（2.443 秒）**，新增七项恢复测试后 **557 项（1.906 秒）**通过；随后增加零时间/未知目标兼容用例。`swift test --package-path apple` 首轮 **2477 项、172 项既有条件跳过、0 失败（31.060 秒）**，另 **12 项 Swift Testing（0.041 秒）**。后续在 Mac 编译与两台模拟器同时运行期间，第二轮旧 `PhotoLibraryModelTests.test视窗完成后按显示顺序预取后续缩略图` 失败，第三轮该项通过，但相邻 `test离开视窗会取消后台预取并让新视窗请求先执行` 失败。两项既有用例分别依赖固定 30/10 毫秒等待，相关 Mac 源码和断言均未修改；最终串行复验结果另记。第三轮共 **2478 项、172 跳过、1 失败（45.624 秒）**，另 **12 项 Swift Testing（0.074 秒）**。一次聚焦命令误用了不存在的 `MacPhotoLibraryModelTests` 类名，执行零项，不计为通过证据。

移动使用 XcodeGen **2.46.0** 生成工程。实际构建命令 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。前四轮分别修正合成服务新增枚举分支、根视图类型推断超时、测试调用旧方法名和错误的语言参数，第五与第六轮构建通过；根视图将相关弹窗按现有方式收拢为独立 modifier，不改变页面导航。

两端以 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=…' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath … -only-testing:DsmMobileTests` 执行全部单元，另选择七项新增权限/任务 UI 和既有 `test照片目录混合选择复制覆盖确认可取消再保存`。iPhone ID 如上，iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，iPad 深色。首轮单元各 **823/823（14.283 / 14.309 秒）**通过；实际 UI 各八项中三项通过、五项失败（241.048 / 287.041 秒）。失败包括重启夹具未保留账号偏好/恢复文件、来源选择器辅助功能标签包含字段名，以及错误详情的“Close”定位到了下层同名控件；分别沿用既有重启保留标记、补稳定来源标识和错误详情关闭标识，并保留全部业务断言。任务按钮扩大为标准触控区域，读取原操作记录失败时禁止清除任务证据并提供重试；新增第 17 项移动控制测试覆盖该保护。

第六轮构建后的第二轮单元两端各 **824/824（14.199 / 14.190 秒）**通过，结果包 `m3e-iphone2.xcresult` / `m3e-ipad2.xcresult`。两端仍分别运行全部八项相关实际 UI，结果另记。日志、结果包、截图均为本机忽略产物，不进入提交。真实 NAS 未参与写操作测试，Windows/Android/macOS App 源码不改动。

第二轮实际 UI 两端各 **6/8 通过、2 项失败（335.942 / 345.728 秒）**。任务四流程、父目录限制/加载失败以及目录复制回归全部通过；权限确认用例遇 XCTest 字符串标识最多 128 字符限制，改用完整 `label` 谓词，不减少后果断言。成员搜索在 iPhone 进入系统搜索后隐藏导航栏，需要退出搜索再返回；iPad 默认布局未显示搜索入口，明确改为常驻原生搜索栏。两端分别保留搜索筛选、返回、普通收紧不确认及保存结果断言。截图另发现 iPhone 英文标题被长保存按钮挤短，改用已有“Save / 保存”资源；按钮含义不变。

停止两端实际 UI 和 Mac 编译后，`swift test --package-path apple --filter PhotoLibraryModelTests` **13/13（0.468 秒）**通过（`m3e-shared-prefetch4.log`），随后串行完整 `swift test --package-path apple` **2478 项、172 项既有条件跳过、0 失败（33.090 秒）**，另 **12 项 Swift Testing（0.036 秒）**（`m3e-shared4.log`）。没有改动旧 Mac 实现或测试来消除并行时序失败。网络的最终八项新增回归已包含在完整测试中；第三轮中网络单独计数 **558/558（3.531 秒）**也通过。

Mac 使用 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`，初次及最终共享修改后的两轮均通过，日志 `m3e-macos-build1.log` / `m3e-macos-build2.log`，实际主程序 `lipo -archs` 为 **x86_64 arm64**；未安装、启动或发布。XcodeGen 重复生成前后 SHA-256 一致为 `d2f26bc76039396a8d685d919b4300a5b354da428b5f83c6f5a5f1ba87ecc045`；fixture **29 组/48 引用**与请求契约 **170 组/1 写结果**通过。独立集成及只读对抗复核覆盖原账号/对象、父目录限制、未知成员、密码与链接不落盘、写前存储失败、权限更新回执后再改默认选项、冻结任务范围、逐项中断、未知重启和迟到回调。

最终第七轮移动构建通过（`m3e-mobile-build7.log`），仅调整成员搜索布局、短保存按钮及对应 UI 定位；共享逻辑与模型未再变化。第三轮以同一 `test-without-building` 命令选择三项权限 UI（中文成员搜索/普通收紧、共享范围/覆盖子目录确认、加载失败/父目录限制），两端各 **3/3（144.340 / 148.529 秒）**通过，结果 `m3e-iphone3.xcresult` / `m3e-ipad3.xcresult`。七项新增实际 UI 和原目录复制回归全部分别具有两端通过证据。最终本地化 **5859 / 2188 / 3402**、严格文档和差异检查通过。

已导出并逐张检查 iPhone 浅色完整权限标题、子目录覆盖后果确认、父目录只读提示及任务错误恢复；iPad 深色任务取消确认、父目录限制与中文成员搜索也可读可操作，测试后已恢复浅色。真实 NAS、设备文件保护、断网/终止恢复与完整辅助功能验收按移动主计划 M3e 的 `PENDING_USER_VALIDATION` 执行；不把合成测试当作真实版本行为验证。下一切片继续预览与设置、人物/相似组和批量导出，M4–M8 仍未完成。

## 2026-10-04 移动 M3f1 照片偏好与旋转

接入重复文件、显示方式、个人智能分类三类设置及预览向左旋转保存。移动上传读取已保存重复处理策略，显示偏好应用于时间线分组、日期/时钟与预览资料；默认覆盖须冻结确认，普通偏好由保存按钮提交。版本 10 恢复保存稳定偏好值及旋转原件身份/方向/尺寸，重启只回读，不保存描述、相机资料、媒体或凭据。共享模型的旋转入口同时受恢复文件可用性保护；Mac App、Windows 与 Android 源码不改。

使用锁定 XcodeGen 2.46.0 生成移动工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 四轮均通过。后两轮同步界面测试定位和截图发现的短标题/准确文案；新增动态资源引用在首次本地化扫描被拒绝，已改用现有明确资源键。最终资源检查为 **5863 / 2188 / 3402**，包含参数、引用和硬编码扫描；fixture **29 组/48 引用**、请求契约 **170 组/1 写结果**、API 参数生成一致性和严格文档检查通过。

首轮 `swift test --package-path apple --filter SynologyPhotosRepositoryTests` 在仍补充测试时因输入文件变更而中止，不计通过。完成编辑后的第二轮 **563/563（2.607 秒）**通过，包含五项新增持久恢复回归：偏好完整回读/缺字段、旋转方向/尺寸及原件替换、非必要资料不落盘、存储失败零写、跨账号拒绝与损坏枚举。

两端分别执行 `xcodebuild test-without-building`，沿上述 project/scheme/derivedDataPath，iPad destination 为 `platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289`，`-parallel-testing-enabled NO`。第一轮包含 `-only-testing:DsmMobileTests` 及五项新 UI；单元分别 **836/836（21.454 / 21.530 秒）**通过，其中新增偏好/旋转 12 项。实际 UI 第一轮各 **2/5 通过、3 项失败（209.625 / 234.286 秒）**：中文显示偏好/默认资料及旋转尺寸通过；重启用例误用不存在的恢复按钮标识、加载视图不是预设元素类型、系统确认按钮产生嵌套同标识节点。分别改用现有刷新标识、增加加载标识、限定确认框内首个匹配，保留全部业务断言。第一轮另指定的旧用例名称不存在，未运行旧回归；第二轮使用实际 `test照片资料预览可评分并显示标签`。

已查看第一轮 iPhone 中文显示设置、旋转后资料/尺寸、智能分类限制及 iPad 分类限制截图。发现英文分类标题在 iPhone 被截短，改用移动短标题；资料开关删去移动端没有的幻灯片措辞。第四轮构建后的最终六项实际 UI，两端各 **6/6（234.009 / 262.092 秒）**通过，结果为 `apple/Apps/DsmMobile/build/m3f1-iphone2.xcresult` / `m3f1-ipad2.xcresult`。iPad 使用深色并在测试结束后恢复浅色，iPhone 保持浅色；两端没有相互借用结果。本切片仅使用合成服务及图片，真实 NAS、实际媒体方向、系统保护和辅助功能按主计划明确待用户验证。

Mac 两轮 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 均通过；第二轮纳入最终语言资源，实际主程序 `lipo -archs` 为 **x86_64 arm64**，没有安装或发布。XcodeGen 重复生成 SHA-256 保持 `e2826dd4c4d7c6ee4a407306b0e0257f199266a692e2a41bdffc29520f14b6f8`。独立集成及只读对抗复核检查原设置差异、真实能力/权限、冻结覆盖确认、存储不可写零提交、记录损坏限制旋转、原件替换、旧账号迟到结果、重启只读和最小持久化字段；没有新 NAS 写接口。

两端实际 UI 和 Mac 构建结束后，串行 `swift test --package-path apple` 完整通过：**2483 项 XCTest、172 项既有条件跳过、0 失败（31.957 秒）**，另 **12 项 Swift Testing（0.031 秒）**。最终已查看 iPhone 未截断英文标题、中文显示设置及旋转尺寸，iPad 深色设置/错误恢复均完整可读。日志位于本机临时验证目录 `m3f1-*.log`，结果包及截图不提交；未把合成素材的尺寸变化当作真实媒体像素方向验证。下一切片为预览修复/生成，其余管理员设置、人物/相似组、批量导出、旧图库清理与 M4–M8 继续实施。

## 2026-10-04 移动 M3f2 手动预览重建与恢复

多选、单张预览和未完成列表复用原有预览重建；列表提供来源切换、文件名搜索、触控选择和 100 项上限。独立版本 11 记录区分写前意图、加入队列、转换提交、失败清理及完成回执；重启只读，完成必须有回执或原件身份/新版本/队列共同证据。本机转换临时媒体在 iOS 受保护并排除备份，结束后清理。无新增 NAS 请求、依赖、权限、应用身份或登录格式变化；真实 NAS 未参与自动写测试。

锁定 XcodeGen 2.46.0 生成工程；首轮 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 通过（`m3f2-build1.log`）。`swift test --package-path apple --filter SynologyPhotosRepositoryTests` 首轮 **569/569、0 失败（3.483 秒）**通过（`m3f2-network1.log`），含六项新恢复/保存失败/原件替换/PNG 上传/账号与记录校验测试。编译 133.04 秒，未把编译时间计作测试执行时间。

两端以 `xcodebuild test-without-building`、同 project/scheme/derivedDataPath、`-parallel-testing-enabled NO` 和各自 destination 运行 `-only-testing:DsmMobileTests` 及五项新增实际 UI、原有旋转尺寸 UI。iPhone ID 同上，iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；结果包为 `apple/Apps/DsmMobile/build/m3f2-iphone1.xcresult` / `m3f2-ipad1.xcresult`，iPad 深色。单元两端各 **845/845（14.351 / 14.101 秒）**通过，含九项新移动预览修复测试；随后分别执行实际 UI、Mac 及完整共享回归，最终结果见下。

本地化资源 **5865 / 2188 / 3402**、参数/引用/硬编码、fixture **29 组/48 引用**通过。首次请求校验误用了不存在的脚本名，未计通过；改用仓库真实 `python3 tools/request-contract/validate_contracts.py` 后 **170 组/1 写结果**通过。`python3 tools/codex/generate_api_reference.py --check`、严格文档与 `git diff --check` 通过。

首轮实际 UI 两端各 **3/6 通过、3 项失败（205.326 / 240.577 秒）**。空内容/错误/加载、未知重启及旧旋转全部通过。失败原因是批量重建后测试未退出多选就打开预览、搜索时系统隐藏导航按钮/iPad 清除文本后失去输入焦点，以及来源标签沿用旧资源大小写与移动主入口不一致。分别按实际原生步骤退出多选/搜索、重新聚焦，来源统一使用移动现有资源；保留全部业务断言。第二轮构建已通过，截图还发现英文标题被刷新按钮挤短，随后将刷新合并列表操作栏，添加未结束操作状态/恢复入口并重新构建。搜索框显式常驻；下一轮分别复跑六项实际 UI，业务模型和共享网络未再改动。

第三轮移动构建通过（`m3f2-build3.log`）。首轮 Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过，实际 `lipo -archs` 为 **x86_64 arm64**，没有安装或发布。XcodeGen 重复生成哈希均为 `da7c9e251e200de86963b7704584618ffccb9dc6da970b6cfe0de45a54c36e26`。

独立收尾复核发现“加入队列回执丢失、尚未转换”原本只能重启后读回并结束旧操作；已让当前会话同样只读处理，不再要求重启。`reviewMutation` 在写调用未返回前不会进入该处理，因此不会抢先结束仍在发送的请求。新增第七项网络回归明确仅发一次标记、不转换、不清理队列。共享、移动及 Mac 构建按最终代码复验；实际 UI 中 iPhone 系统搜索退出键名为“关闭”，已据实际辅助功能标签修正单个测试步骤。

第二轮实际 UI：iPhone **5/6 通过（218.372 秒）**，仅中文搜索的系统退出控件名称定位失败；iPad **6/6 通过（274.955 秒）**。iPhone 截图确认英文标题完整、共享来源标签与主入口一致、未结束操作的说明和刷新状态按钮可见；系统搜索退出改按实际“关闭”按钮，仅在导航动作隐藏时触发。未减少搜索为空、筛选结果、选择目标和完成后剩余项目断言。最终仅需复验这一测试及受影响的移动模型，不重复已通过的不相关 UI。

第四轮移动构建通过（`m3f2-build4.log`）。最终网络 **570/570、0 失败（2.009 秒）**通过（`m3f2-network2.log`）；两端第三轮九项预览修复单元各 **9/9（0.276 / 0.282 秒）**，中文搜索/选择/继续实际 UI 各 **1/1（35.454 / 38.604 秒）**通过，结果 `m3f2-iphone3.xcresult` / `m3f2-ipad3.xcresult`。五项新实际 UI 与旧旋转全部分别具有两端通过证据，未通过的中间轮次保留如上。已查看 iPhone 浅色完整标题/共享来源/未知恢复说明，以及 iPad 深色中文搜索/错误恢复截图；iPad 测后恢复浅色。

最终 Mac 第二轮双架构构建通过（`m3f2-mac2.log`），再次检查实际主程序为 **x86_64 arm64**。两端 UI 与 Mac 编译结束后串行 `swift test --package-path apple` 完整通过：**2490 项 XCTest、172 项既有条件跳过、0 失败（31.520 秒）**，另 **12 项 Swift Testing（0.031 秒）**（`m3f2-shared1.log`）。最终本地化、响应/请求契约、API 参数生成、严格文档及差异检查均通过。日志、结果包和截图是本机验证产物，不进入提交。真实 NAS、媒体像素效果、设备文件保护和辅助功能按主计划 M3f2 的 `PENDING_USER_VALIDATION` 验收；自动预览、图库维护、管理员设置、人物/相似组、批量导出和旧图库清理继续后续 M3，M4–M8 尚未完成。


## 2026-10-04 移动 M3f3 自动预览与图库维护

- 范围：原生自动预览设置/状态/暂停继续、新格式提示、个人/共享图库维护及原快照确认；自动工作只在照片页面前台运行，版本 12 保存写前意图、接收回执、图片/视频摘要与失败标记。新格式部分完成的后续记录独立保留，防止重启再次生成；无新 NAS 参数或真实 NAS 写测试。
- 独立集成及只读对抗复核覆盖原件/单元编号区分、账号与来源、旧设置/维护许可、取消与提交边界、落盘失败零写、未知结果只查、生成接受与最终完成区分、后续提示记录和其他操作并存、临时文件保护及旧版本兼容。复核补齐生成已接受但提示失败后的持久后续记录；处理中主动暂停而尚未上传的确定取消保持暂停状态，不能误报失败。Mac 未装配存储时保持原行为，后台或被替换会话仍保留原记录。
- 网络第一轮 `swift test --package-path apple --filter SynologyPhotosRepositoryTests` 570 项通过（1.631 秒）；新增七项后第二轮 577 项中一项失败，是测试把原件下载的 GET 请求送入表单解析器，未改变业务断言，已修正请求筛选。第三轮 `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests` 579 项、0 失败（1.753 秒），含九项新增恢复测试及真实合成视频摘要跨实例回读。对应编译分别 120.50、67.04、52.38 秒。
- 完整共享最终 `swift test --package-path apple --jobs 4` 通过：2499 项 XCTest、172 项既有条件跳过、0 失败，31.700 秒；另 12 项 Swift Testing 通过，0.031 秒。最终编译 18.20 秒；没有使用静态扫描替代行为测试，也没有新增跳过。
- 锁定 XcodeGen 2.46.0 生成工程并复验 SHA-256 相同。移动四轮 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 均通过。新增测试文件通过生成流程加入工程，没有手改生成内容。
- 两端分别执行 `xcodebuild test-without-building`，沿用上述 project/scheme/derivedDataPath，`-parallel-testing-enabled NO`，iPad 目标为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。结果在忽略目录的 `m3f3-iphone1/2/3.xcresult`、`m3f3-ipad1/2/3.xcresult`，每轮均单独运行 `-only-testing:DsmMobileTests`。第一轮各 855 项只有同一新增用例失败（三条断言）：连续使用相同远期时间，未跨过查询退避时间；修正第二次时间推进。第二轮两端各 856 项通过，最终第三轮各 857 项通过（iPhone 14.455、iPad 14.280 秒），包含 12 项新模型测试；断言与安全门均保留。
- 第一轮实际 UI 选择六项新流程与旧 `test照片显示偏好中文保存及预览默认资料`，两端各 6/7 通过（282.885/323.337 秒）；共享维护确认的定位未限定弹窗，命中重复元素，修正为当前 alert 的确认按钮，保留后果/来源/结果断言。第二轮六项新流程全部通过（247.782/275.766 秒）：`test自动预览中文开关保存后前台生成`、`test照片库维护确认取消和共享来源`、`test新格式部分完成只能补关闭提示`、`test预览设置空内容错误与加载状态`、`test维护忙碌与不支持预览仍显示真实限制`、`test自动预览设置未知重启后禁止再次保存`。第三轮新增 `test自动预览处理中暂停再继续保持可操作` 两端通过（25.235/23.473 秒）。界面选项为 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<上述方法名>`。
- 截图复核发现 iPhone 维护标题截断及空状态区留下表单空白行，已改为原生关闭/刷新图标并仅显示实际状态。最终 iPhone 浅色维护完整标题/空内容/暂停和 iPad 深色中文设置均已人工查看；两端 UI 都使用合成照片和账号，不能证明真实图片质量或系统辅助功能通过。iPad 测试后恢复浅色。
- Mac 三轮 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 均通过；最终 `lipo -archs` 为 `x86_64 arm64`。未安装或启动正式 Mac 包。
- 本地化 Apple 5868、Android 2188、Windows 3402 键通过；请求契约 170/1、Fixture 29 组与私有 API 文档引用 48 项、API 目录一致性、严格文档与差异空白检查通过。代码推送、云端结果和正式发布分别记录，不以本机验证推定云端或真实设备通过。
- `PENDING_USER_VALIDATION`：真实解码、NAS 接收/最终状态、锁屏保护、能耗、网络断开、VoiceOver、大字号、外接键盘和 iPad 分屏。条件、步骤、预期及可回传信息见移动主计划 M3f3；未实现的管理员设置、人物/相似组、导出/删除恢复、旧图库清理及 M4–M8 继续后续工作。


## 2026-10-04 移动 M3f4 管理员设置与共享成员

- 实现共享图库启停/选项、全局设置/排除格式、转换缓存与成员/备份/两层目录权限的原生表单。目录编辑只更新本机草稿，主表单确认固定全部改动；普通开关直接保存，公开范围、分类关闭、缓存及成员权限变更说明具体后果。纯目录草稿逻辑从 Mac 移入共享目标，Mac 保持行为，无新 NAS 参数、第三方依赖或登录格式变化。
- 恢复版本 13 保存最小设置、管理员/成员/目录身份与每一步尝试/接收/拒绝状态，不保存成员显示名称、密码、链接、媒体或会话。独立集成与只读对抗复核覆盖新旧记录、前序回执完整性、存储失败零写、原快照/实际管理员/候选名单、受保护/未知角色、父子目录与公开下限、跨账号迟到响应、重复确认及部分保存；所有恢复只回读，不自动补发权限或缓存操作。
- 网络 `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests` 三轮通过：579 项/1.698 秒，增加八项后 587 项/1.705 秒，收紧恢复步骤顺序校验后 587 项/1.736 秒；编译分别 136.88、23.03、26.33 秒。新增用例真实经过请求编码/阶段回执和跨实例恢复，覆盖全局多步/成员目录/共享开关/缓存、保存失败与受保护成员。
- 完整共享 `swift test --package-path apple --jobs 4` 在 Mac 和两端首轮 UI 结束后运行：2507 项 XCTest、172 项既有条件跳过、0 失败，32.392 秒；另 12 项 Swift Testing 通过，0.032 秒。编译 0.19 秒，没有新增跳过或降低断言。
- 锁定 XcodeGen 2.46.0 生成工程，重复生成前后 SHA-256 均为 `17c91541f1bddf29ecc5a4319e5b97ec7b7e0b247a7d69d7eb4ba031a8729226`。前三轮 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 均通过。
- 两端首轮 `xcodebuild test-without-building` 沿用上述 project/scheme/derivedDataPath，`-parallel-testing-enabled NO`，iPad destination 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。分别选择 `-only-testing:DsmMobileTests`，870 项单元全部通过（iPhone 15.794、iPad 15.534 秒），包含 13 项新增管理员模型测试。
- 首轮七项新增实际 UI：iPhone 6/7 通过（323.571 秒），iPad 5/7 通过（346.996 秒）。`test照片添加自定义成员并编辑目录后统一保存` 两端失败：候选菜单仅文字附近可触发，行中心点击无效；已扩大菜单标签到整行并明确点击范围。iPad `test照片全局格式保留未知项及缓存清理` 失败：截图显示开关滚到浮动标题栏下，测试点击未改变值；滚动辅助改为完整露出该行，另加点击后值与保存可用断言。未减少确认、取消或最终结果检查。
- 首轮其余五项两端通过：`test照片全局部分完成重新打开保留剩余修改`、`test照片共享最后图库与正在清理缓存保持限制`、`test照片共享设置中文确认取消和保存`、`test照片管理员未知保存重启仍禁止再次提交`、`test照片管理员空内容失败加载停用及搜索无结果`。界面选项为 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<方法名>`；两端结果分别为忽略目录中的 `m3f4-iphone1.xcresult`、`m3f4-ipad1.xcresult`，iPhone 浅色、iPad 深色。截图已检查正常、空内容、部分完成与中文设置的标题、布局和恢复入口。
- Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO` 通过；实际主程序 `lipo -archs` 为 `x86_64 arm64`，没有安装或启动正式包。
- 本地化 Apple 5868/Android 2188/Windows 3402、参数/硬编码/引用，Fixture 29 组及私有 API 引用 48 项，请求 170 组/1 写结果、API 参数目录、严格文档和差异空白检查通过。真实 NAS 未参与自动写测试；设备/NAS 条件、步骤与脱敏反馈要求见主计划 M3f4 的 `PENDING_USER_VALIDATION`。人物/相似组、批量导出/原件删除恢复、旧图库清理与 M4–M8 继续后续工作。

- 第二轮实际 UI 两端两项均通过：排除格式/缓存为 53.753 / 68.953 秒，新增自定义成员/目录/统一保存/再次搜索为 46.852 / 49.945 秒。使用同样命令，仅选择这两项；结果 `m3f4-iphone2.xcresult` / `m3f4-ipad2.xcresult`。最终 iPhone 目录权限与完整标题、iPad 深色成员筛选和格式开关截图已人工检查；iPad 测后恢复浅色。最终界面修复不改变模型、网络或 Mac 代码，未重复已通过的完整共享测试。

## 2026-10-04 移动 M3g 人物主题与手工人脸

- 两端实现人物改名/合并/显示隐藏、选中人脸移出/改归属/封面，主题显示/封面/移出，预览手工人脸新增/移动/缩放/命名/归属和撤销移除。普通保存直接提交，合并与移出固定目标并说明保留原照片。iPhone 纵向、宽屏 iPad 并列画布和表单；辅助大字使用纵向布局及完整辅助标签。纯框选/裁剪计算移入共享目标，Mac 保持原 JPEG 编码与行为。
- 独立恢复版本 14 兼容旧 1–13，保存稳定身份、名称/原件/裁剪摘要、合并原成员集合及提交/回执状态，不存姓名、照片、凭据或链接。新增框返回编号及裁剪全部保存成功后才允许改动旧框；未知只读，丢回执不按同名猜新人物。独立集成与只读对抗复核补上人物移出/改归属后的原件身份检查，覆盖原照片替换、存储失败、先增后删、裁剪丢回执、跨账号及迟到读取；Mac 未装配持久适配的路径保持原语义。
- 网络 `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests`：首轮编译暴露不可编码照片编号类型及闭包命名错误，修正后 587 项通过；增加十项用例后 597 项首轮失败三项，原因是合成共享分类权限未开启、隐私断言把属性名当正文、GET 回读被当作 POST 解码，修正 fixture 和定位后 597 项/1.988 秒通过。再补原件替换回归，最终完整共享运行包含 598 项网络测试，0 失败（1.994 秒）。未降低实际请求、摘要、不重复写或原件完整性断言。
- 完整 `swift test --package-path apple --jobs 4`：2518 项 XCTest、172 项既有条件跳过、0 失败（38.243 秒），另 12 项 Swift Testing 通过（0.042 秒），编译 186.68 秒。包含三项原 Mac 人脸裁剪/颜色/方框变化测试；既有条件跳过不能计作实际 UI 验收。移动新增 15 项模型用例覆盖人物/主题权限、冻结确认、隐藏搜索、真实人脸编号、空/错/取消、未知重启、JPEG 裁剪、方向元数据、原预览替换与迟到读取。
- 锁定 XcodeGen 2.46.0 生成工程。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 首轮因合成服务缺新增恢复枚举分支而失败；补齐后第二至第七轮均通过。后续迭代包含真实界面修复与测试操作修正，每次重建后才复测最终代码；未用构建期间编辑后的源码冒充已编译内容。
- 首次聚焦移动单元 14 项中两项失败，合成服务未转发人物分类筛选后的照片列表；补齐既有筛选语义并增加迟到读取用例后，两端分别执行 `xcodebuild test-without-building`，沿用上述 project/scheme/derivedDataPath，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`，iPad destination 为 `platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289`。最终各 885 项全部通过（iPhone 16.220 / iPad 16.303 秒）。
- 七项新增实际 UI 为 `test人物显示隐藏与主题搜索`、`test人物中文改名合并取消及确认`、`test主题移出提示分类数量并保留原照片`、`test人脸触控框选移动与辅助控件保存`、`test人物加载空内容错误正常与筛选无结果`、`test人物保存中断重启不可重复提交`、`test人脸大字中文空内容仍可命名保存`，选项为 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<方法名>`。首轮 iPad 六项仅一项通过（265.729 秒）：系统确认重复节点、隐藏按钮完整标签和滚动定位错误，另发现居中 sheet 无法提供并列编辑；分别修正定位、全屏编辑及选中框编辑区顺序。
- 第二轮七项：iPhone 5/7 通过（327.522 秒），iPad 6/7 通过（408.590 秒）。五个非人脸流程两端全部通过；失败集中在大字设置开关/原生长菜单滚动，以及人脸表单测试滚动滑过输入区。增加明确可见性检查、原生菜单滚动及人脸表单专用滚动定位，保留原业务断言。第三轮仅复测两项人脸：iPad 2/2（90.354 秒），iPhone 大字通过、普通触控因键盘仍占据下半屏而失败（两项共 102.202 秒）。
- 最终修复增加名称输入完成键、进入绘图/选择人脸时关闭键盘，并将表单测试滚动放在边缘，避开滑块。截图发现大字工具按钮截断，改为保留完整辅助标签的图标按钮；画布内标注保持图片比例，表单文字仍随系统字号变化。第七轮构建后，两项人脸实际 UI 两端全部通过：iPhone 2/2（87.812 秒），iPad 2/2（96.302 秒）。包括触控画框、滑块调整、移除/再画、保存及重新打开，中文无障碍最大字号空画布命名保存。七项均有各设备通过证据，不把不同轮次合称一次全套通过。
- 已查看最终 iPhone 浅色普通/中文大字和 iPad 深色并列/中文大字截图；加载、空内容、错误、正常及筛选无结果另由七项用例覆盖。实际 VoiceOver 读屏、硬件键盘、分屏和真实图片/NAS 未验证，按主计划 M3g 的 `PENDING_USER_VALIDATION` 后置；只使用合成图片和服务，未操作真实 NAS 数据。
- Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` 通过，实际主程序 `lipo -archs` 为 `x86_64 arm64`。未安装或启动 Mac 包；最终人脸视图修复仅移动端，不重复无变化的 Mac/完整共享测试。
- 本地化 Apple 5873 / Android 2188 / Windows 3402、参数/引用/硬编码扫描、fixture 29 组/48 私有引用、请求契约 170 组/1 写结果、API 参数生成、严格文档及差异空白检查通过。结果包和截图保留在忽略的本机验证目录，`m3g-*.log` 不提交；下一切片为相似组、原件批量删除恢复、批量导出和旧图库清理，其后继续 M4–M8。

## 2026-10-04 移动 M3h1 原件批量删除与恢复

- 修正移动端多选删除确认仍只传首张照片的问题；确认固定完整选择，每项重新读取身份/权限后提交，已确认删除才从图库和分页中移除。新增独立版本 1 删除记录，仅保存账号隔离身份、照片/拍摄时间摘要、操作编号和提交阶段。未知项目只读恢复，剩余项目先暂停，继续前重新读取并确认；取消剩余项目不撤销已提交删除。无新 NAS 参数、系统权限、应用身份、依赖或登录格式变化，旧上传/相册记录不迁移。
- 独立集成与只读对抗复核补上删除恢复完成后的 Repository 占用释放，以及未结束删除对上传继续/重试的限制。检查原件替换、权限变化、重复确认、同编号不同来源、单向持久阶段、损坏/跨账号记录、保存失败零提交和旧会话迟到回执；模拟器合成服务不接触真实 NAS。
- `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests` 首轮 605 项通过（2.102 秒，编译 166.68 秒）。再补占用释放回归后，完整 `swift test --package-path apple --jobs 4` 包含 606 项网络测试（1.517 秒），全套 2526 项 XCTest、172 项既有条件跳过、0 失败（33.729 秒），另 12 项 Swift Testing 通过（0.036 秒）；编译 101.66 秒。此后仅调整移动视图及移动测试，没有重复无变化的完整共享运行。
- 锁定 XcodeGen 2.46.0 生成工程，重复生成 SHA-256 均为 `0067b37c530d3ea3dfdd3230effc53cfa25479502155b1a1a2d2819ed214b0ad`。六轮 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 均通过。
- 两端分别执行 `xcodebuild test-without-building`，沿用上述 project/scheme/derivedDataPath，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`，iPad destination 为 `platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289`。前两轮各 900 项仅文件保护属性断言失败：首轮按 Swift 包装类型读取，第二轮按字符串读取仍为 nil。文件保护键的值类型依据为 [Apple Foundation 文档](https://developer.apple.com/documentation/foundation/fileattributekey/protectionkey?language=objc)；随后独立使用系统写入与显式保护属性设置作对照，两台模拟器仍不返回该键，证明当前环境无法提供这项回读证据。
- 原保护级别断言迁入单独的 `test真机删除恢复文件使用完整保护级别`，真机不允许跳过；模拟器只有在上述独立系统对照也缺少该属性时，明确报告 `PENDING_USER_VALIDATION` 跳过原因。其余摘要隐私、权限 0600、不进备份、阶段不可回退、旧会话停写、完整选择、部分完成/剩余恢复、账号隔离等断言保留并执行。第三轮两端各 **901 项、1 项明确的设备条件跳过、0 失败**（iPhone 16.252 / iPad 16.208 秒），即各 900 项实际通过；不能把这一跳过或属性配置当作真实锁屏保护通过。
- 五项首轮实际 UI 全部通过：`test照片完整批量删除确认可取消且删除全部选择`、`test照片删除未知重启后只能刷新或取消剩余项目`、`test照片部分删除中文只继续未提交项且不误报全部成功`、`test照片删除预检加载和连接错误不弹出删除确认`、`test预览删除单张后仍保留其余照片`。iPhone 共 197.607 秒，iPad 共 231.558 秒，分别为 `m3h1-phone1.xcresult` / `m3h1-pad1.xcresult`；两端整体运行因上述单元断言失败返回非零，未把整体报告为通过。界面参数为 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<方法名>`。
- 第二轮新增 `test照片删除中文大字确认和剩余操作仍可触达` 并复测完整批量删除，两端 2/2 通过（67.883 / 70.580 秒）。截图仍发现最大字号进度和继续按钮截断，另发现全部删除后留下无法退出的零项选择栏；随后在确认开始删除时退出多选，状态操作采用大号原生按钮，大字状态区可滚动且文字完整换行。保留取消、完整选择、重启防重放和逐项结果断言，最终界面复验另记如下。
- 第三轮完整删除与中文部分完成两端通过；iPad 三项全部通过，iPhone 大字取消按钮定位失败。失败视频证明默认滑动落在底部标签栏，修正状态滚动区裁剪与按实际可见区域定位的测试手势后，第四轮仅复测这项：iPhone 1/1（38.306 秒）、iPad 1/1（43.453 秒）通过，分别保留 `m3h1-phone4.xcresult` / `m3h1-pad4.xcresult`。最终查看两端进度与滚动后操作截图，继续/取消文字完整、按钮可触达；测试未降低断言。恢复 iPad 浅色设置。六项 UI 的通过证据来自上述分轮运行，不声称一次全套运行全部通过。
- Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` 通过，实际主程序 `lipo -archs` 为 `x86_64 arm64`。未安装或启动 Mac 包；最后的界面调整只涉及移动端。
- 本地化 Apple 5883 / Android 2188 / Windows 3402、参数/引用/硬编码扫描、fixture 29 组/48 私有引用、请求 170 组/1 写结果、API 参数生成、严格文档及差异空白检查通过。日志、结果包与合成截图位于本机临时验证目录，不提交。真实 NAS、锁屏保护、VoiceOver、键盘和分屏按主计划 M3h1 的具体 `PENDING_USER_VALIDATION` 步骤后置；相似分组/撤销、导出/浏览补齐、旧图库清理及 M4–M8 继续后续实施。

## 2026-10-04 移动 M3h2 相似分组与恢复

- 两端接入相似分组详情、代表照片、移出、拆组、撤销和批量拆组；保留选中照片并清理其余原件复用 M3h1 删除队列。版本 15 保存原分组、成员摘要、动作与提交阶段，独立批次文件保留已确认撤销依据；无新 NAS 参数、依赖、身份、系统权限或登录格式迁移。超过 100 张照片的单组仍保存全部成员，不截断分组；移动批次最多选择 100 组。
- 独立集成与只读对抗复核检查原件/组/账号快照、只读恢复、去重、保存失败、原件替换及成员加入其他分组时的撤销限制。新增提交前取消的终态处理，避免没有发出的请求残留处理中；离页后已保存明确拒绝时释放旧内存占用；重启后的原件删除按当前图库成员找到受影响分组并刷新。未使用真实 NAS 执行修改。
- 首轮 `swift test --package-path apple --jobs 4 --filter SynologyPhotosRepositoryTests`：613 项、0 失败，2.254 秒，编译 183.74 秒。补取消交界与 101 张成员回归后网络为 615 项，第二轮完整共享中 1.592 秒通过。
- 三轮完整 `swift test --package-path apple --jobs 4` 均通过：首轮 2533 项、172 项既有条件跳过、0 失败（33.506 秒），后两轮各 2535 项、172 项既有条件跳过、0 失败（34.562 / 34.316 秒）；三轮另有 12 项 Swift Testing 均通过（0.036 秒）。第二/三轮编译 137.86 / 104.11 秒。重复运行对应新增取消/大分组测试及后续恢复修正，不以先前结果代替最终共享源码验证。
- 锁定 XcodeGen 2.46.0 生成工程。移动沿用 M0 的完整 `xcodebuild build-for-testing` 命令、专用 iPhone 目的地、临时签名和 `build/m0-m8` 输出。前两轮在照片根视图报告表达式检查超时；将图库、工具栏工作区和已有弹窗组合拆成独立视图表达式后，第三轮构建通过，未移除功能或测试断言。两端单元与实际 UI 验证继续记录如下。
- 两端单元使用 `xcodebuild test-without-building`、M0 的 project/scheme/derivedDataPath、各自专用 simulator destination、`-parallel-testing-enabled NO -only-testing:DsmMobileTests`。首轮各 916 项、1 项 H1 已说明的真机文件保护条件跳过，两个新清理用例出现 10 条断言失败：合成服务仍只接受旧删除场景，拒绝了相似照片清理。扩展合成场景并保留身份/权限检查后，第二轮各 **916 项、1 条明确设备跳过、0 失败**（iPhone 16.646 / iPad 16.640 秒），即各 915 项实际通过；15 项新增相似测试全部通过。
- 实际 UI 首轮的空内容、加载、错误及只读权限四态用例两端通过（93.617 / 108.347 秒）。其余四项首次未通过，包含确认框原生父子按钮重复匹配、超过 128 字符的查询标识限制、大字确认框动画尚未完成；修正为准确的首个同一按钮匹配、完整 label 谓词和等待按钮实际可点击，保留确认内容与结果断言。大字截图另显示组内缩略图重复分组徽标和空状态区，移除两者后第四轮移动构建通过；第二轮四项实际 UI 继续记录如下。
- 第二轮实际 UI 中断/重启/取消剩余流程两端通过（50.951 / 61.396 秒），iPhone 中文最大字号也通过（42.772 秒）。清理流程发现实际弹窗归属问题：预检后关闭嵌套预览会丢失删除确认；改为在当前分组页显示确认，确认开始删除后才关闭预览，父预览同时停用重复确认。Mac 默认调用仍保持原交互。另将撤销测试限定在当前分组列表，避免同标识背景按钮；iPad 大字号拆组按钮须完整滚出导航栏覆盖区后操作。
- 该确认归属修正后，第四轮完整共享为 2535 项 XCTest、172 项既有条件跳过、0 失败（34.372 秒），另 12 项 Swift Testing 通过（0.034 秒），编译 99.13 秒。第五轮移动构建通过。新增“原件清理确认前保留当前预览”的断言，两端重新运行相似交互与既有单张预览删除回归，结果继续如下。
- 第三轮两端各 916 项单元、1 项明确设备条件跳过、0 失败（17.115 / 18.693 秒）；三项相似交互加既有 `test预览删除单张后仍保留其余照片` 均 4/4 通过（148.523 / 159.778 秒），分别保留 `m3h2-phone3.xcresult` 与 `m3h2-pad3.xcresult`。最终截图确认 iPhone 浅色和 iPad 深色、大字选择与完整确认，五项新 UI 的通过证据来自分轮运行，未将早期失败的整体报告为通过。截图收尾另去掉完成结果上方的空状态行，移动第六轮构建通过。
- Mac 两轮 Release 双架构构建通过，最后一次覆盖清理确认参数增量：`xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO`。最终实际主程序 `lipo -archs` 为 `x86_64 arm64`；未安装或启动包。之后只有移动列表空行修正，没有共享源码变化。
- 工程重复生成 SHA-256 均为 `9e57e597d258e5a9f8930359371b59f82e1ade047d373144325660e283cfaf7c`。本地化 Apple 5893 / Android 2188 / Windows 3402、参数/引用/硬编码扫描，fixture 29 组及私有引用 48 项，请求 170 组/1 写结果、API 参数目录、严格文档和差异检查通过。真实 NAS/设备保护、VoiceOver、键盘与分屏依主计划 M3h2 的 `PENDING_USER_VALIDATION` 后置；M3h3 与 M4–M8 仍未完成，不缩减原目标。

- 空状态行修正后的第四轮只复测代表照片/移出/撤销：iPhone 1/1（42.868 秒）、iPad 1/1（45.967 秒）通过，最终正常字号截图已查看。iPad 保留一条系统 `UIKitToolbar` 运行时提示，测试未失败；页面使用原生 SwiftUI 工具栏，未手动插入该视图，设备布局仍按待验步骤检查。已恢复 iPad 浅色设置，并清理本波次视频抽帧调试脚本及图片；保留合成测试结果与日志供本次完整目标核验，不提交临时产物。

## 2026-10-04 移动 M3h3a 导出与幻灯片

本切片基于 `a55817d6`。修改移动照片会话/预览/网格与菜单，新增 `MobilePhotoExportControls`、`MobilePhotoSlideshowView`，兼容扩展原系统保存/分享适配器及安全播放器，新增导出和实际播放器测试；同步合成服务、双语资源、生成工程与文档。没有修改 NAS 请求、公开协议、恢复格式、权限、身份、最低系统版本、Mac App、Windows 或 Android 源码。

- 下载保持实际目标和权限。纯照片逐项获取，相似分组展开完整成员，整相册/目录及含子目录的混合选择沿用已有 ZIP 契约。真实返回格式决定扩展名，重名副本不覆盖；失败文件不交付，已完成项目可交给系统面板并准确显示部分结果。受保护临时目录排除备份，取消/切账号/关闭及重启清理限于本应用副本，旧系统面板的迟到关闭不能清理新批次。原尺寸 JPEG 仍只向支持的单张开放。
- 幻灯片复用共享完整分页，不改变图库选片和月份位置；视频结束推进、暂停保留位置、错误停止、离页/后台取消。安全播放器新增可选控制与回调，默认文件预览仍不自动播放，媒体范围/证书/源站规则不变。日/月分组选择、范围扩选和五档缩略图补齐移动浏览入口。宽幅图的视觉布局与点击/无障碍区域分别验证，不能仅凭截屏或按钮存在推定正确。
- XcodeGen **2.46.0** 生成工程，重复 SHA-256 为 `be0f5320f6ad96c6a581412807ed73969e4d2dd0e1410434a44b6033cc3304d9`。实际构建命令 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。首轮仅新测试服务缺少 `thumbnail` 协议实现，第二轮测试试图修改只读 `albumContext`；修正测试构造后第 3–8 轮构建均通过，没有降低权限、格式或结果断言。
- `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests` 加对应界面测试选择器，分别使用上述 iPhone 与 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` iPad。第 1 轮各 **931 项**、第 2 轮各 **937 项**、第 3 轮各 **939 项**完整单元均 0 失败，均有 **1 项既有真机文件保护条件跳过**；最终单元 iPhone 21.214 秒、iPad 21.090 秒。新增 19 项导出/浏览测试与 4 项实际 AVPlayer 测试；后者从内存合成短 PCM WAV，由注入读取器供给，不使用网络、麦克风或用户媒体。
- 第 1 轮六项 UI 中，iPhone 三项失败、iPad 一项失败：中文导航使用了英文测试参数；系统分享容器覆盖自定义根标识，真实标识为 `ActivityListView`；iPhone 文件选择器进入目录后须返回浏览页再取消。按实际界面修正定位后，第 2 轮六项新增 UI 加既有相似预览回归 **两端各 7/7 通过**（iPhone 228.022 秒、iPad 255.683 秒）。没有跳过或弱化部分导出数量、取消、相似分组和原件保留断言。
- 第 3 轮两端四项 UI 中，中文大字、部分导出提示和单张预览删除通过；新方格边界断言均失败：宽幅图片按钮的无障碍宽度为高度的 1.5 倍。截图证明固定方格中的图片裁剪已经正确，随后添加明确点击形状；第 4 轮发现把整个按钮合并为独立无障碍元素会丢失原生按钮类型，两端两项测试均失败。最终仅隐藏装饰图片子节点，保留按钮类型、文件名、选中状态及分组信息；第 5 轮两端方形/不重叠断言和相似预览回归通过，iPad 两项整体通过（84.700 秒），iPhone 批量导出仅在系统取消入口的恢复时序上失败。补上等待系统保存入口、按真实目录层次返回及面板消失断言后，第 6 轮批量导出/取消 **两端各 1/1 通过**（38.158 / 37.714 秒）。未降低方格边界或面板确实关闭的要求。
- 最终第 9 轮生产构建和第 10 轮仅更新面板自动化的构建均通过。第 3 轮 939 项完整单元后只有缩略图的视觉/无障碍修复及系统面板测试定位变化，使用两端相关实际 UI 复验，不重复扩大单元范围。最终正常字号网格、深浅主题、完整图像、中文大字菜单和系统交接截图已查看；相关 NAS/真机结论仍保持未验证。
- 完整共享 `swift test --package-path apple --jobs 4`：**2535 项 XCTest、172 项既有条件跳过、0 失败**（44.958 秒），另 **12 项 Swift Testing** 通过（0.116 秒）。最后仅调整新增文案后，`swift test --package-path apple --jobs 4 --filter DsmLocalizationTests` 的 **6 项**本地化测试再次通过。Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` 两轮均通过，最终主程序 `lipo -archs` 为 **x86_64 arm64**；未安装、启动或发布。
- 集成与只读对抗复核覆盖下载权限、完整成员与归档身份、原格式回退、路径穿越/同名文件、取消和切账号、旧回调、临时文件与旧面板关闭、媒体结束/失败回调身份和前后台。模拟器截图覆盖 iPhone 浅色、iPad 深色、中文最大字号、实际几何图片、系统面板及准确部分失败提示。系统原生 SwiftUI 工具栏仍出现 UIKit 层级诊断，实际按钮回归通过；真机、VoiceOver、硬件键盘和分屏不据此宣告通过。
- 本地化最终 **Apple 5899 / Android 2188 / Windows 3402**，双语/参数/资源引用/硬编码检查通过；fixture **29 组/48 私有引用**、请求 **170 组/1 写结果**及 API 参数目录检查通过。最初误用不存在的 fixture 脚本未计通过，改用 `python3 tools/contract-validation/validate_fixtures.py` 后成功。严格文档与差异空白检查通过。
- 日志/结果包为本机临时目录的 `m3h3-*.log`、`m3h3-*.xcresult`，不提交；一次性导出截图/视频在复核后清理，iPad 恢复浅色设置。真实 NAS、设备文件保护和系统交接按主计划 M3h3a 的具体 `PENDING_USER_VALIDATION` 验收；旧图库清理继续 M3h3b，之后仍有 M4–M8，不将其计为只待真机。

## 2026-10-04 移动 M3h3b 旧图库与开发数据收口

在 `8a655ca3` 基线上核对正式路由及所有调用方后，删除无入口的 File Station 图库、Library/Timeline/Viewer、Cell/Grid 和旧单张导入共 **14 个源文件**，移除组合根和会话里的旧装配；设置改为只统计、清理并回读正式照片缩略图缓存。系统照片选择器仍供 Chat 与正式上传共用，File Station 共享 Repository、文件预览和已发布 Mac 上传书签存储保留实际用途。原旧图库只有内存缓存，没有需要迁移的旧磁盘相册库。

用户在本切片明确补充：移动端未发布，后续按开发阶段处理，不保留旧开发数据兼容模式，无用旧代码直接删除。依此将相册管理检查点统一为唯一当前格式 **16**，删去按操作选择 1–15 以及接受这些旧编号的分支；操作、账号、原目标、回执、写入阶段和损坏数据校验保持。仅移动端装配这套磁盘存储，Mac 共享调用按当前类型回归，NAS 方法、参数及其他端实现均未改变。旧开发记录不自动转换、删除或重放；格式往返与拒绝旧/未知编号新增两项 Core 测试，现有各类恢复用例改为断言当前格式，未移除写前保存或只读恢复断言。

旧 Library/Timeline 的目录扫描、视频排除和永久路径缓存断言随无入口实现退休；仍有效的会话、分页失败/偏移、迟到响应、空间权限、预览、系统选择及清理转到正式模型。五项缩略图缓存测试迁入 `MobilePhotoThumbnailStoreTests` 后逐函数与原代码比对完全一致；取消用例单独迁移并保留释放槽位、零取消缓存和可重试检查。完整映射和替代语义见[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m3h3b-旧图库迁移账本)。移动单元总数由 939 收敛为 910；共享正式模型与 Repository 的已有回归继续覆盖原件身份、权限及分页，不能将数量变化解释为删除安全门禁。

实际验证与结果：

- 锁定 XcodeGen **2.46.0** 生成移动工程；重复生成前后 SHA-256 均为 `9469fa8e2920a51f1c24de2a8d036ffe327ad3817315bc62336b14459281b237`。四轮 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 均通过；第四轮包含唯一当前恢复格式和对应测试。
- 两端以 `xcodebuild test-without-building` 沿用上述 project/scheme/derivedDataPath，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`，iPad destination 为 `platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289`。第一轮各 910 项、1 项既有设备文件保护跳过，两个测试共 3 条断言失败：静态检查仍写旧权限方法名，退出/删除配置用例在异步缓存清理前检查了零成本。改为检查正式 `canDeleteSelection`，并等待实际缓存清理完成再保留零成本断言；第二轮各 **910 项、1 跳过、0 失败**（21.899 / 21.708 秒）。格式收敛后的第三轮各 **910 项、1 跳过、0 失败**（iPhone **21.601** / iPad **21.532** 秒），即各 909 项实际通过。
- 第一轮四项实际 UI 两端全部通过：批量照片原件交给系统文件面板并取消、单张预览删除后保留其他照片、选择上传/清理记录、文件与 App 设置导航。iPhone **106.556 秒**、iPad **118.572 秒**。第四轮构建后另验“照片资料未知重启保留记录并限制再次编辑”，iPhone **46.671 秒**、iPad **59.650 秒**均通过，证明当前格式仍保留重启后的防重复提交；测试全部使用合成服务和素材，没有真实 NAS 写入。
- 清理后的聚焦共享 `swift test --package-path apple --jobs 4 --filter 'SynologyPhotos(Model|Repository)Tests'` 为 **865 项、0 失败（3.143 秒）**。格式收敛后的完整 `swift test --package-path apple --jobs 4` 为 **2537 项 XCTest、172 项既有条件跳过、0 失败（34.890 秒）**，另 **12 项 Swift Testing（0.036 秒）**通过。
- 最终 `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` **通过**；主程序 `lipo -archs` 实际为 **x86_64 arm64**。没有安装、启动或发布 Mac 包。
- 本地化资源检查 **Apple 5899 / Android 2188 / Windows 3402**，双语/参数/引用/硬编码通过；fixture **29 组/48 项私有引用**、请求 **170 组/1 写结果**、API 参数目录、严格发布文档及 `git diff --check` 通过。

独立集成与只读对抗复核覆盖无旧路由/装配、Chat/正式上传选择器仍在使用、当前格式校验的全部读取入口、损坏/不支持记录不自动重写、异步注销清理、旧会话迟到响应、有效测试映射以及无其他端源码变化。结果包和日志为本机临时目录中的 `m3h3b-*.xcresult` 与 `m3h3b-*.log`，不提交。真实 NAS、设备保护、媒体交接和完整辅助功能仍按各 M3 切片的具体 `PENDING_USER_VALIDATION` 进行；旧代码/开发格式清理已实现，不列为设备待验。下一阶段为 M4 Chat，M4–M8 仍未完成。

## 2026-10-04 移动 M4a 搜索编辑与线程

基线 `5e7d68aa`。移动 Chat 包装器逐项接入既有搜索、消息定位、本人编辑策略/写入及线程协议；新增 `MobileChatInteractionModel`、`MobileChatInteractionStore` 和原生搜索/编辑/线程页面。组合根沿用原模型并注入当前账号身份与独立受保护恢复目录；主消息行、附件读取与新页面复用。新增实际 `DsmChatRepository` 合成传输、18 项行为测试及四项实际 UI。Mac App、Android、Windows、共享 Chat 协议/网络源码、身份、权限、最低版本及依赖均未修改；共享变化仅双语资源。

- 搜索以自己的 offset 游标完整读取，线程使用实际根/更早消息游标，旧回复可单独定位。编辑仅本人普通消息/附件说明，并重新读取作者、原文与策略；同目标编辑期间不能删除。回复结果要求当前请求、会话、线程、本人及正文一致。独立 `Chat/interactions-v1.json` 只记录账号/对象/作者身份、请求编号及文字摘要，不保存正文或凭据；采用唯一当前格式，不做旧开发数据迁移。写前保存失败不提交，未知编辑只读恢复，未知回复重启后仍不重发同一内容。
- 修正实际 UI 中的消息行身份问题：原无障碍动作修饰器用条件分支替换整行，开始编辑时删除动作暂不可用会导致表单关闭。改为在稳定视图上更新可访问操作，保留删除确认和权限。关闭线程取消未完成附件下载、释放进度及缩略图加载状态，再次打开仍可读取和导出；新行为测试覆盖实际网络层与临时文件清理。回复发送中刷新仍按原草稿完成，不因视图代次变化保留可重复发送的成功草稿。
- 锁定 **XcodeGen 2.46.0** 生成工程，重复 SHA-256 为 `9585f908fb0433613f9f350120d7b8a292a58f8c3b3da08ac3a750d344caa911`。八次增量 `xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 均通过，分别覆盖源码、合成测试、UI 问题修复、附件恢复与测试配置。
- 单元使用 `xcodebuild test-without-building`，沿用上述 project/scheme/derivedDataPath，`-parallel-testing-enabled NO -only-testing:DsmMobileTests`，iPhone 与 iPad（`A31ABDE2-186F-43DD-8D40-5EB9511A9289`）独立执行。首轮各 923 项中两个旧源码检查共 3 条断言失败（原 `private` 行声明及旧初始化写法）；改为当前复用消息行和单模型注入，并保留权限/生命周期断言。第二轮各 923 项、1 项既有设备保护跳过、0 失败。
- 后续补齐线程 60 项分页、刷新中发送、关闭/迟到查询与附件读取回归，总数为 **928 项**。iPhone 两轮分别暴露既有文档 FIFO 与系统关闭测试的固定 300ms 假定，iPad 同轮均通过；没有改文档传输生产代码，改为等待实际任务成功及面板交接，并保留全部 FIFO、重复关闭与文件清理断言。最终第五轮两端各 **928 项、1 条明确设备条件跳过、0 失败**，即各 927 项实际通过；iPhone **21.924 秒**、iPad **22.143 秒**。
- 实际 UI 的早期失败还包括：选中了弹窗下方的会话搜索框、iPhone 搜索时工具栏被系统折叠、iPhone 文本框点击将光标放在开头、以工具栏父容器误判按钮启用状态。改为准确的消息搜索框/键盘搜索提交、真实行尾点击与文字值断言、实际按钮状态；未减弱正文、本人限制、重启或发送结果要求。第四轮四项 UI **两端 4/4 通过**：搜索原消息并发送线程回复、本人编辑与他人限制、编辑中断/重启只读恢复、中文搜索空/错误状态；iPhone **152.500 秒**，iPad **166.125 秒**。
- 截图复核发现 `-AppleInterfaceStyle Dark` 没有改变实际 App 主题，早期带 dark 名称的截图不计深色证据。改为 App 自身外观偏好及 `UICTContentSizeCategoryAccessibilityXXXL` 后，第六轮只运行 `-only-testing:DsmMobileUITests/MobileChatUITests/test中文深色大字号搜索空结果和失败均提供恢复路径`，两端 **1/1 通过**（**49.968 / 50.027 秒**）。已查看 iPhone 浅色回复、iPad 浅色线程及最终中文黑底/最大字号截图；搜索、错误恢复、系统键盘和返回入口实际可达，不能据此代替 VoiceOver 或硬件键盘验收。
- 完整 `swift test --package-path apple --jobs 4` **2537 项 XCTest、172 项既有条件跳过、0 失败（49.283 秒）**，另 **12 项 Swift Testing（0.087 秒）**通过。Mac `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` 通过，实际主程序 `lipo -archs` 为 **x86_64 arm64**。此后只有移动源码/测试和文档调整，没有共享资源变动；未安装或启动 Mac 包。
- `python3 tools/localization/check_localization.py`：**Apple 5907 / Android 2188 / Windows 3402**，双语/参数/资源引用/硬编码均通过。删除无用的旧能力教学提示并保留加密限制页面；新增错误均说明当前状态与恢复操作。`python3 tools/contract-validation/validate_fixtures.py` 为 **29 组 / 48 项私有文档引用**，`python3 tools/request-contract/validate_contracts.py` 为 **170 组请求 / 1 写结果**，均通过。严格文档与 `git diff --check` 同步通过。

独立集成和只读对抗复核检查账号/会话/作者/线程绑定、未知消息不按相似内容认领、写前持久失败零提交、跨账号与旧查询迟到、坏/旧格式拒绝、编辑/删除互斥、附件离页取消与清理、真实回读更新原消息，以及无其他平台源码变化。测试使用合成账号、消息与图像，没有访问或发送真实 NAS 聊天。结果与日志保留在本机临时目录的 `m4a-*.xcresult` / `m4a-*.log`，一次性导出图片/层次文本复核后清理，不提交临时产物。真实普通账号/编辑时限、多人并发、真机文件保护、VoiceOver 和硬件键盘按主计划 M4a 的 `PENDING_USER_VALIDATION` 执行；下一切片为 M4b 高级消息动作，M4b–M8 仍为未完成源码。


## 2026-10-04 移动 M4b1 投票创建、参与与恢复

- 实际修改：新增移动投票模型/恢复文件/创建与结果表单、Debug 合成服务及 24 项行为测试/四项实际 UI；接入原聊天工具栏和消息卡片，双语资源与工程按 XcodeGen 2.46.0 生成。共享 `ChatRepository` 增加创建回执回调和只读投票详情，复用原请求与解析；只读恢复结束原内存投票后允许用户主动改选。Mac App、Windows、Android 无文件修改。
- 决策：投票需要 Vote v1 与 Post v5 读取能力；创建回执先持久化、再确认本人原消息，不能凭同内容认领。`Chat/polls-v1.json` 仅含身份与摘要，保存失败零提交、未知跨重启不重放；无旧开发格式兼容，无登录存储/权限/身份/依赖变化。匿名和截止时间依现行读取，创建只开放已实现的无截止投票。
- 分离的只读集成/对抗复核覆盖权限撤销/加密变化、冻结目标、回执保存失败、取消、重复点击、坏结构、迟到响应、跨账号和恢复后继续改选；未使用其他模型或真实 NAS 作为验收来源。

实际命令（本轮调用锁定的 XcodeGen 2.46.0）：

```sh
xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py --strict-release
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
git diff --check
```

UI 在相同两台设备及 `test-without-building` 参数下运行：首轮同时指定 `-only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatPollUITests -only-testing:DsmMobileUITests/MobileChatUITests`；第二轮指定 `-only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatPollUITests`。每轮用独立 `-resultBundlePath` 保存结果。

| 实际门禁 | 结果 |
| --- | --- |
| 移动构建 | 四次 `build-for-testing` 均成功；最后一次包含新增读取能力门及测试 |
| iPhone 最终全部单元 | 952 项，1 条既有设备文件保护条件跳过，0 失败；22.616 秒（含框架开销 23.010 秒） |
| iPad 最终全部单元 | 952 项，1 条同类明确跳过，0 失败；22.513 秒（含框架开销 22.893 秒） |
| iPhone 投票实际 UI | 四项通过，197.895 秒；创建/投票、创建中断重启、中文深色超大字号多选/结束、错误/删除/加载状态 |
| iPad 投票实际 UI | 四项通过，221.196 秒，独立执行相同流程 |
| 原聊天实际 UI | iPhone 四项通过 167.740 秒，iPad 四项通过 194.099 秒；搜索、本人编辑、重启恢复与线程回复 |
| 最终共享 Apple | 2,540 项 XCTest，172 条既有环境/设备条件跳过，0 失败，48.288 秒；12 项 Swift Testing 通过，0.068 秒 |
| macOS Release | 主 App 与扩展工程构建通过；主可执行文件实际含 `x86_64 arm64`；未打安装包、安装或启动 Mac App |
| 资源/文档/契约 | 双语完整、参数/引用/硬编码与严格文档检查通过；29 组 fixture、48 项私有引用、170 个请求及 1 个结果示例通过 |

中间失败如实保留：第一轮两端各 948 项单元有同一创建恢复测试两条断言失败，原因是新 Repository 没有当前账号身份缓存；恢复改为读取当前账号/会话及原投票后解决。另一个首次测试脚本错误将现有 `Try Again` 按钮写成 `Retry`，导致每端四项投票 UI 中一项失败，修正准确按钮定位后通过；未降低恢复断言。复核补充同一连接恢复后继续改选、提交前/后取消和缺 Post v5 的零写入测试。第二轮两端 951 项单元均通过，最终加入能力门测试后为 952 项。截图复核还将选项正文/票数显式采用系统前景色，避免按钮内继承浅蓝色；第二轮实际截图已确认两种主题、大字与触控可用，iPad 大字结果可滚动。

结果保留在本机本轮工作目录的 `m4b1-build1..4.log`、`m4b1-iphone1..3`/`m4b1-ipad1..3` 结果包与日志、`m4b1-shared2.log`、`m4b1-macos.log`；导出的临时截图在复核后清理。生成工程 SHA-256 为 `8bb7d41394ed9e316fa076b0d76476f74728c6d851085586d7eb287b4fcaf504`。`PENDING_USER_VALIDATION` 的专用账号/可丢弃投票、匿名规则、断网、十选项、VoiceOver/硬件键盘与锁屏保护步骤见[移动 M4b1](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4b1-投票创建参与与恢复)。本轮没有真实 NAS 写入或移动分发，继续 M4b2 提醒/定时及 M4 后续切片。

## 2026-10-04 移动 M4b2 提醒与定时消息

基线 `052b88a7`。新增移动 `MobileChatTimedActionModel/Store/View`、Debug 合成服务、25 项行为测试及五项实际 UI；包装器按能力开放提醒及文字定时，原消息菜单和聊天工具栏接入原生表单、筛选、刷新及明确取消确认。工具栏次要动作收进统一菜单，保留公告/成员/置顶和可访问提示。共享协议增加定时创建回执保存回调；取消提交后的网络/读取异常保持未知语义，重复身份列表不能用来确认结果。Mac App、Windows、Android 未修改，NAS 请求字段不变；共享影响已同步 API 记录和矩阵。

`Chat/timed-actions-v1.json` 采用独立当前开发格式，受完整文件保护且排除备份，仅含账号上下文、动作/目标身份、时间与文字摘要，不含正文或凭据。提醒设置/取消、定时取消都重新读取原对象和会话；原时间或内容改变时零写入。定时创建回执先保存再回读，没有回执不按相似内容认领，重启只查询。超过发送时间的取消不能凭列表消失宣称未送达。分离的集成与只读对抗复核另外发现并修复同账号切会话后迟到成功替换当前列表，以及原会话错误出现到其他会话的问题；都有实际 Repository 合成回归。无新依赖、权限、最低版本、登录格式或旧开发迁移。

实际命令（`xcodegen` 调用锁定的 2.46.0）：

```sh
xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py --strict-release
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
git diff --check
```

每端第一轮在相同 `test-without-building` 中同时指定全部单元、`-only-testing:DsmMobileUITests/MobileChatTimedActionUITests`、`-only-testing:DsmMobileUITests/MobileChatPollUITests/test创建投票查看结果并提交选择` 和 `-only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复`；第二轮为全部单元，加 `MobileChatTimedActionUITests` 下的 `test中文深色大字定时列表及筛选空状态`、`test定时创建中断后重启按原回执恢复`、`test消息提醒保存修改与取消` 三个完整选择器。各轮用独立 `-resultBundlePath`。

| 实际门禁 | 结果 |
| --- | --- |
| 移动构建 | 首次发现消息缓存路径错误并修复，第二至四次 `build-for-testing` 成功；最后一次仅去除未使用的合成服务辅助方法；最终工程重复生成 SHA-256 为 `4006e78ed7744b2d396399c638ebcfde8a3b9440b7715a90b40ba8374095b522` |
| iPhone 最终全部单元 | 977 项，1 条既有设备文件保护条件跳过，0 失败；24.421 秒（含框架开销 24.908 秒） |
| iPad 最终全部单元 | 977 项，1 条同类跳过，0 失败；24.419 秒（含框架开销 24.864 秒） |
| 新行为测试 | 25 项两端通过：创建/修改/取消、毫秒参数、重复点击、明确拒绝、原快照变化、加密/撤权、坏列表/存储、回执丢失、跨重启、取消时点、迟到数据/错误、跨账号及过发送时间 |
| 新实际 UI | iPhone 首轮五项全部通过（315.053 秒）；iPad 首轮四项通过、一项定位失败，第二轮修正后通过。最后三项复验两端全通过（127.027 / 142.214 秒） |
| 原聊天 UI | 两端投票创建/参与及搜索原消息/线程发送均通过；菜单收拢未改变这些入口 |
| 共享 Apple | 2544 项 XCTest，172 条既有环境/设备条件跳过，0 失败，33.823 秒；另 12 项 Swift Testing 通过，0.037 秒 |
| macOS Release | 双架构构建通过，实际主程序 `lipo -archs` 为 `x86_64 arm64`；未安装或启动 |
| 双语/文档/契约 | Apple 5956 / Android 2188 / Windows 3402；引用、参数、硬编码、严格文档、29 组 fixture / 48 项私有引用及 170 个请求 / 1 个结果均通过 |

中间失败如实保留：首轮移动构建将会话消息缓存误写为不存在的顶层属性；本地化首次只增加 App 资源，缺共享资源，随后同步并通过。首轮两端 975 项单元的两个旧展示测试共三条断言失败：菜单合并遗漏公告/成员无障碍提示，以及图标由 Image 改为原生 Label；已恢复提示并精确检查 Label 图标，未删安全或隐私断言。iPad 中文筛选脚本误点弹窗下方的“搜索会话”，改为准确的“搜索消息”后通过；提醒关闭同样定位当前导航栏。复核再增加两项迟到结果/错误的会话隔离测试，使最终为 977 项。实际截图已查看两端浅色表单/列表、中文深色最大字号、错误和筛选空态，并移除表单空白提示行；最终截图复验确认空白行消失及 iPad 搜索可用。

日志和结果包留在本机本轮工作目录的 `m4b2-mobile-build1..4.log`、`m4b2-iphone1..2`/`m4b2-ipad1..2`、`m4b2-shared1.log`、`m4b2-mac-build1.log`；导出的临时截图/文本检查后清理，不纳入提交。真实 NAS 未参与写测试，移动端未分发；跨时区、到期实际投递、VoiceOver/硬件键盘和锁屏保护按[移动 M4b2 待办](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4b2-提醒与定时消息)验收。下一切片为 M4b3 转发/置顶/会话操作，M4–M8 尚未整体完成。

## 2026-10-04 移动 M4b3a 公告置顶与会话关闭

当前主分支在 `9df14f12` 后实施。新增 `MobileChatManagementModel/Store/View`、隔离服务与单元/实际 UI 测试，接入公告设置/取消、完整公告原消息和附件/投票、单项/多项关闭会话。保留前置原快照、权限/能力、确认、防重复、写前受保护落盘与未知只读恢复；同进程旧请求未结束时，新模型不能提前解除它的记录。关闭和发送/编辑/投票/提醒互斥；未知时暂停批次，恢复不自动开始剩余项。

共享 Apple 修正 pin/unpin/close 提交后的错误分类：传输失败可以继续只读查询，回读失败保留未知且不可普通重试；完整会话列表拒绝重复身份。NAS 字段不变，原方法签名不变，Windows/Android 与 Mac App 源码未修改。移动层不再截断公告或丢弃附件/投票，受保护条目不能被过滤为“已不存在”。恢复记录只含账号/动作/对象身份，不保存正文和凭据，不迁移旧开发数据。私有 API、独立集成与只读对抗复核的范围见移动主计划和端点记录。

本轮真实执行的命令主体（模拟器分别替换下列两个设备 ID，结果包/日志按轮次独立保存）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatManagementUITests -only-testing:DsmMobileUITests/MobileChatTimedActionUITests/test消息提醒保存修改与取消 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b3a-iphone1.xcresult
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py --strict-release
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
git diff --check
```

iPad 使用 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，两者运行 iOS 26.5，不能相互替代。第 2 轮为全部单元、新管理五项 UI 加原搜索/线程 UI；第 3 轮为全部单元加管理关闭/未知重启/公告取消三项 UI；第 4 轮为全部单元加公告附件/取消与原搜索/线程 UI；第 5 轮单独补完整关闭后返回路径；第 6–7 轮为全部单元和该关闭 UI。各轮沿用上述 `test-without-building` 参数，实际选择器均为源文件内中文方法名，输出分别为 `m4b3a-iphone1..7`、`m4b3a-ipad1..7` 的日志与结果包。

| 验证 | 实际结果 |
| --- | --- |
| 模拟器构建 | 最终第 10 次增量 `build-for-testing` 通过；此前各次构建亦通过，没有以静态阅读替代构建 |
| iPhone 单元 | 最终 1003 项，1 条既有设备条件跳过、0 失败，25.302 秒；包含 26 项新增行为测试 |
| iPad 单元 | 最终 1003 项，1 条既有设备条件跳过、0 失败，25.284 秒；包含同一 26 项新增行为测试 |
| 公告正常/空内容/加载/错误/筛选为空 | 两端第 2 轮中文深色超大字号及三态实际 UI 通过；112 条完整分页、附件与投票保留另有行为测试 |
| 公告附件及取消 | 第 4 轮两端均通过，分别 40.192/42.376 秒；实际进入系统 Quick Look、关闭预览后取消精确公告行，另一个公告保留 |
| 重启恢复与旧流程 | 第 3 轮置顶未知重启两端通过，44.269/47.706 秒；第 1 轮原提醒 UI 39.997/47.166 秒通过，第 4 轮原搜索/线程 27.617/29.420 秒通过 |
| 关闭后返回路径 | 第 7 轮两端通过，32.909/35.136 秒；明确检查结果窗口关闭后返回可见会话列表 |
| 共享 Apple | 2549 项 XCTest，172 条既有条件跳过、0 失败，34.726 秒；另 12 项 Swift Testing 0 失败，0.039 秒；包含 5 项新增请求/错误语义测试 |
| macOS | 两次 Release 双架构构建通过，最终实际二进制 `lipo -archs` 为 `x86_64 arm64`；未安装/启动 App 或发布新包 |
| 本地化/契约/文档 | Apple 5969、Android 2188、Windows 3402 键检查通过；29 组 fixture/48 项私有文档引用及 170 组请求/1 写结果示例通过，严格文档与差异检查通过 |

保留失败证据及修复：第 1 轮各 997 项单元仅旧实时源码断言失败，已将“不额外加载公告”的约束限定到实时同步函数，未删除安全断言；公告 UI 原先匹配底层相同文字，改为按公告原消息 ID 定位。第 2 轮发现普通样式列表行的透明区不能点击，补整行触控范围与选中状态断言；第 3 轮确认 Quick Look 已加载但缺导航栏，补文件标题和显式关闭。第 5 轮 iPhone 退出管理后仍显示加载消息；第 6 轮立即返回又提前关闭结果窗口，改为管理窗口退出后再返回，iPad 保留并列详情语义。所有原断言保留或按新的完整功能语义加强，未将失败改为跳过。

已查看两端中英文、浅深主题、超大字号、公告原内容、取消确认、批量结果与系统预览截图；iPad 背景聊天分栏/输入区的窄宽度问题留在 M4c，不能据新弹窗通过宣称整个聊天布局完成。临时导出截图/视频与诊断文本复核后清理；本机日志和结果包保留在本轮工作目录，不提交。锁定 XcodeGen 2.46.0 重复生成后的工程 SHA-256 均为 `3bdb87d5b82bc96368bb47861bd15419183b4aa57bef98085e5c77478b7819dc`。真实 NAS 不参与自动写测试，设备步骤见[移动 M4b3a](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4b3a-公告置顶与会话关闭)。继续 M4b3b 转发、多条本人消息删除与 M4b4 发送/创建恢复，M4–M8 尚未整体完成。


## 2026-10-04 移动 M4b3b1 转发恢复共享前置

范围为 Apple 共享转发的最小进度回执、保存回调与独立只读恢复。原 Mac 调用保留，同一来源写前串行，明确拒绝才解除未结束记录；成功回执、各目标完成身份分步保存，丢回执不认领同内容，导入未知记录后禁止换编号再发。来源按原线程/内容/作者/编辑时间重读，目标按账号、普通消息、内容摘要、提交前后 180 秒与原基线匹配，读取到旧时间边界或历史末尾才形成唯一结果，部分完成只恢复剩余目标。没有新增 NAS 参数或真实写证据。

新增 `ChatForwardReceiptTests` 4 项与 `DsmChatForwardRecoveryTests` 18 项正式测试。测试覆盖受保护的最小信息、FORM/JSON 编码、写前/回执/最终保存失败、线程来源、能力/权限、明确拒绝、跨页超过 100 条、重复候选/坏分页、账号、旧消息/其他作者/投票/加密、实际任务取消、并发点击/恢复及持久回执重建。原附件转发用例将固定过期时间改为测试时刻，以覆盖新提交窗口，原请求和不下载附件断言保留。分离的集成与只读对抗复核补上两个缺口：最终进度补存后释放来源占用、缺回执的重建 Repository 保留原操作并拒绝新编号重发。

实际命令（仓库根目录）：

```sh
swift test --package-path apple --jobs 2 --filter DsmChatRepositoryTests
swift test --package-path apple --jobs 2 --filter 'DsmChatRepositoryTests|ChatForwardReceiptTests'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b3b-iphone1.xcresult
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 使用相同测试命令，将目标改为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果为 `m4b3b-ipad1.xcresult`。两种设备均为 iOS 26.5。

| 验证 | 实际结果 |
| --- | --- |
| 聚焦网络与回执 | 首轮既有丢回执 1 项通过；第二轮 113 项零失败；第三轮 120 项零失败（新增最终保存与导入限制用例随后进入全量） |
| 完整共享第 1 轮 | 2571 项 XCTest，172 条既有条件跳过，零失败，37.425 秒；另 12 项 Swift Testing 通过 |
| 最终完整共享第 2 轮 | 2571 项 XCTest，172 条既有条件跳过，零失败，34.033 秒；另 12 项 Swift Testing，0.075 秒通过 |
| 移动构建 | `m4b3b-mobile-build1.log`，通过 |
| iPhone | 全部 1003 项单元，1 条既有设备条件跳过，零失败，25.319 秒；原聊天搜索/线程回复实际 UI 1 项通过，33.013 秒 |
| iPad | 全部 1003 项单元，1 条既有设备条件跳过，零失败，25.306 秒；相同实际 UI 1 项通过，42.895 秒 |
| Mac 双架构 | `m4b3b-mac-build1.log` 通过，10 月 5 日凌晨完成；`lipo -archs` 实际 App 为 `x86_64 arm64`，未安装或启动 |
| 本地化与契约 | Apple 5969 / Android 2188 / Windows 3402；29 组响应 / 48 私有引用；170 组请求 / 1 写结果，均通过 |

日志/结果包位于本轮临时工作目录，不进入源码；本切片无新界面或新移动转发 UI 验收。移动批量、新联系人创建恢复、本人批量删除和 M4c–M8 继续实施。真实 NAS/时钟偏差/同毫秒消息/附件内容及多人并发仍未验证；维持唯一归属不足时保留未知，不扩大匹配条件或自动重发。共享增量及五端影响见[高级动作契约](../../api/discovery/endpoints/chat-advanced-actions.md#2026-10-04-apple-转发恢复增量)。

## 2026-10-05 移动 M4b3b2 新联系人单聊恢复

范围为转发前置的新联系人普通单聊创建/打开与重启恢复。共享新增写前保存回调和独立只读恢复，旧调用保留；完整用户/会话预检之后才保存提交阶段，普通单聊必须精确匹配当前用户与对端且未加密。移动独立文件只存账号上下文、请求/用户身份与阶段，准备状态可由用户继续，提交状态只能读取。共享执行占用防止旧请求执行期间提前恢复；完成记录保存失败仍保留保护，同配置档换账号或重新绑定后旧结果不导航当前页面。

本轮新增 6 项网络测试、6 项存储测试、9 项模型测试、4 项实际 Repository/移动包装器集成测试及 3 项界面测试。分离的集成与只读对抗复核检查保存先后、缺回执、重启、执行锁、身份绑定、终态落盘失败与能力撤回；补上新建能力消失后仍显示未完成单聊恢复入口的缺口，并删除原单聊内存回读死分支。群聊持久恢复继续 M4b4，不能以本切片的单聊结果代替。

实际命令（仓库根目录）：

```sh
swift test --package-path apple --jobs 2 --filter DsmChatRepositoryTests
swift test --package-path apple --jobs 2
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatUITests/test新联系人打开单聊并进入会话 -only-testing:DsmMobileUITests/MobileChatUITests/test新联系人创建中断重启后刷新打开原单聊 -only-testing:DsmMobileUITests/MobileChatUITests/test中文深色大字号新建联系人空列表和加载失败 -only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b3b-direct-iphone3.xcresult
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 将目标改为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，使用 `m4b3b-direct-ipad3.xcresult`。两台均为 iOS 26.5。首轮聚焦移动 `m4b3b-direct-focused1` 仅选择 MobileChatModelTests / MobileChatConversationCreationStoreTests / MobileChatPresentationTests。界面第 1 轮只运行三项新增 UI 和完整单元；第 2 轮改为 14 项呈现单元与三项 UI，第 3 轮恢复全部单元并追加原聊天搜索/线程 UI。最终第 4 轮使用同一 `test-without-building` 命令，选择 `DsmMobileTests/MobileChatPresentationTests` 与两项新建/恢复 UI，结果分别为 `m4b3b-direct-iphone4.xcresult` / `m4b3b-direct-ipad4.xcresult`。

| 验证 | 已确认结果 |
| --- | --- |
| 聚焦共享 | 既有 117 项通过；新增后 123 项中的三项因成功响应 fixture 缺少 Anonymous 返回 data 产生 4 个断言失败；按既有单聊契约修正 fixture 后 123 项零失败，0.410 秒 |
| 完整共享 | 2577 项 XCTest，172 条既有条件跳过，零失败，39.155 秒；另 12 项 Swift Testing 通过，0.062 秒 |
| 移动构建 | `m4b3b-direct-build1` 至 `build6` 均通过；新增源文件由锁定 XcodeGen 生成 |
| 聚焦移动 | 80 项，零失败，2.851 秒 |
| 第 1 轮单元 | 两端各 1021 项，各 1 条既有设备条件跳过，零失败；iPhone 25.570 秒，iPad 25.426 秒 |
| 最终单元 | 两端各 1022 项，各 1 条既有设备条件跳过，零失败；iPhone 25.070 秒，iPad 25.033 秒 |
| 界面定位修正 | 第 1 轮把工具栏外层容器当作按钮读取禁用状态，iPhone 将实际导航栏标题当普通文本查找；第 2 轮新增筛选检查错误选中背景会话搜索栏。均已改为对应按钮/导航栏和明确联系人搜索栏，没有删除功能断言 |
| 第 3 轮实际 UI | iPad 三项新增及原搜索/线程共 4 项通过；iPhone 恢复、中文三态、原搜索/线程通过，新增筛选后打开流程发现搜索模式隐藏确认操作栏。已改为选择单聊联系人后自动退出搜索，第 4 轮两端复验通过 |
| 最终第 4 轮 | 两端各 14 项呈现单元通过；两项新建/恢复 UI 全通过，iPhone 73.631 秒，iPad 82.845 秒 |
| Mac 双架构 | `m4b3b-direct-mac-build1.log` 通过；实际二进制包含 `x86_64 arm64`，未安装或启动 |
| 本地化与契约 | Apple 5972 / Android 2188 / Windows 3402；29 组响应 / 48 私有引用；170 组请求 / 1 写结果通过 |

已查看首轮恢复页及第二轮普通联系人、中文深色大字号错误页截图。界面去掉恢复/加载/错误页无效搜索框，仅一种会话能力时不显示类型选择，待恢复不依赖联系人列表成功；所有提示描述聊天和恢复动作。最终已检查 iPhone 第 4 轮及 iPad 第 3 轮截图，两端正常、加载、空内容、筛选为空、错误与恢复状态均有实际证据。既有消息页在 iPhone 多按钮时标题被挤压、iPad 窄分栏和大字号背景布局的问题继续 M4c，本切片的新建弹窗验收不代表整个聊天布局完成。临时日志、截图、结果包不进入源码。真实 NAS、系统文件保护与完整辅助功能为 `PENDING_USER_VALIDATION`，具体条件和步骤见[移动主计划 M4b3b2](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4b3b2-新联系人单聊恢复)。

## 2026-10-05 移动 M4b3b3 批量转发与恢复

移动端接通消息单选/多选、接收会话/新联系人搜索多选、顺序转发及逐消息/接收人结果。新联系人先完成单聊准备；批次以受保护的独立 `forwarding-v1.json` 保存身份、时间、摘要和共享回执，不保存正文、联系人姓名或附件名。部分完成/丢回执后暂停后续消息，刷新只读取；用户可继续尚未开始项或取消剩余项。已完成目标不重发，未知记录不能移除。新建单聊、编辑/删除来源和关闭相关会话共享占用；账号失效后的迟到结果只落到原上下文。

新增 15 项实际 Repository/包装器/移动模型行为测试、7 项存储测试及 4 项实际 UI。分离进行集成与只读对抗复核，检查落盘顺序、单聊创建与转发之间的中断、明确拒绝/未知区分、回执不可倒退、跨账号执行与互斥；补上恢复文件损坏时另一创建入口的绕过，以及执行中取消剩余消息的处理。附件确认沿用共享的描述摘要，不将其称为附件字节校验。共享业务源码、公开协议和 NAS 请求均未改变；本次没有重新运行共享全量或 Mac 双架构构建，不冒用上一个切片的结果作为本次新增移动功能验证。

实际命令（仓库根目录）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatForwardUITests -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b3b-forward-iphone2.xcresult
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 使用 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 和 `m4b3b-forward-ipad2.xcresult`，两台均为 iOS 26.5；第 1 轮使用相应 `iphone1` / `ipad1` 结果包。聚焦轮选择 `MobileChatForwardTests`、`MobileChatForwardStoreTests`、`MobileChatModelTests`、`MobileChatPresentationTests`，结果为 `m4b3b-forward-focused1.xcresult`。所有构建/结果文件在既有临时目录保存，不进入源码。

| 验证 | 已确认结果 |
| --- | --- |
| 移动构建 | `m4b3b-forward-build1` 至 `build4` 均通过；当前代码由第 4 轮构建，工程由锁定 XcodeGen 生成 |
| 聚焦移动 | 94 项零失败，3.100 秒 |
| 第 1 轮全量单元 | 两端各 1043 项，各 1 条既有设备条件跳过，零失败；iPhone 25.000 秒，iPad 24.901 秒 |
| 最终全量单元 | 两端各 1044 项，各 1 条既有设备条件跳过，零失败；iPhone 24.776 秒，iPad 24.797 秒 |
| 第 1 轮实际 UI | iPhone 4 项通过；iPad 取消/中文三态/重启恢复通过，正常搜索转发失败。截图确认 iPad 接收页默认折叠搜索栏；已改为列表常显，加载/空内容/错误不显示无效搜索栏，没有放宽测试断言 |
| 最终第 2 轮实际 UI | 两端各 4 项全通过；iPhone 206.370 秒，iPad 217.536 秒。覆盖正常多选/搜索/新联系人、部分结果重启/继续、未知/取消，以及中文深色大字号加载/空内容/错误 |
| 本地化与契约 | Apple 6009 / Android 2188 / Windows 3402，双语、参数和硬编码扫描通过；29 组响应 / 48 私有引用、170 组请求 / 1 写结果通过 |

已查看第 1 轮 iPad 正常接收页、中文深色大字号错误页及 iPhone 多消息/多接收人结果截图。第 2 轮已检查 iPad 常显搜索栏与去掉无效搜索的中文错误页、iPhone 恢复后已完成/尚未发送分项与继续按钮；所有五态均有两端实际 UI 证据。既有 iPhone/iPad 消息主布局问题仍归 M4c。真实 NAS/设备、锁屏文件保护、完整 VoiceOver/硬件键盘与 iPad 分屏没有本次实际验证；条件和操作步骤见移动主计划 M4b3b3。


## 2026-10-05 移动 M4b3c 本人消息批量删除

范围为共享删除快照/写前保存/只读恢复、移动单条与多条删除共用的持久批次、逐项结果和相邻动作互斥；不访问真实 NAS。共享仍用已记录 Post v5，删除前后重新检查当前账号和可见会话；原内容改变、失去权限、辅助空记录、坏分页均不能冒充删除成功。独立记录不保存正文/附件名称；确认时冻结原消息，提交未知不重放，取消只影响未开始项，已结束删除不会被迟到的消息/搜索结果插回。Mac App 源码、Windows 和 Android 未修改。

分开执行的集成和只读对抗复核覆盖写前/写后保存失败、同 UUID 与换 UUID 重复删除、明确拒绝、丢回执、旧历史页、权限/账号/会话变化、原文变更、重启、旧模型仍在执行及取消边界。复核补齐了目标为空辅助记录时拒绝确认、取消准备项保留原计划、确认期间原内容快照、删除成功后忽略旧读取等边界；未引入新 NAS 字段。新增共享 16 项测试、移动 23 项测试（含 1 项组合根迟到读取回归）与 5 项实际 UI。

实际命令（仓库根目录）：

```sh
swift test --package-path apple --jobs 2 --filter 'DsmChatRepositoryTests|ChatMessageDeletionSnapshotTests'
swift test --package-path apple --jobs 2
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatDeletionUITests -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b3c-iphone2.xcresult
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 使用相同测试命令，将目标改为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果目录为 `m4b3c-ipad2.xcresult`。两端运行 iOS 26.5；临时证据目录仅含合成环境结果，未提交日志或图片。

| 验证 | 实际结果 |
| --- | --- |
| 共享聚焦 | 139 项，零失败，0.311 秒；包含原删除分页/权限回归及新增恢复、快照测试 |
| 共享完整第 1 轮 | 2593 项 XCTest、172 条既有条件跳过、零失败，36.995 秒；另 12 项 Swift Testing，0.045 秒通过 |
| 共享完整最终第 2 轮 | 2593 项 XCTest、172 条既有条件跳过、零失败，35.981 秒；另 12 项 Swift Testing，0.037 秒通过 |
| Mac 双架构 | 第 1、2 次构建均通过；最终主程序为 x86_64、arm64，未安装或启动 Mac 包 |
| 移动构建 | 第 1、3、4、5 次通过；第 2 次因 UI 测试把元素当作查询读取 count 编译失败，改为正确查询后重建 |
| 首轮两端完整单元 | 各 1065 项、各 1 条既有条件跳过、零失败；iPhone 26.629 秒，iPad 26.646 秒 |
| 第二轮两端完整单元 | 各 1067 项、各 1 条既有条件跳过、零失败；iPhone 26.520 秒，iPad 26.364 秒 |
| 首轮实际 UI | 每端 5 项中 2 项通过、3 项失败；原生弹框将同一按钮暴露为父子两层节点，且取消采用框外点击。通过实际截图和层级核对后，测试限定弹框内目标并沿用原生框外取消；没有删减业务断言 |
| 第二轮实际 UI | 两端各 5 项零失败；iPhone 231.132 秒，iPad 239.527 秒；最终截图已复核恢复后第一项已删除/第二项未删除、逐项完成及中文深色大字号空状态 |
| 静态门禁 | 双语资源 6031/2188/3402、29 组 fixture/48 私有引用、170 请求/1 写结果、最终严格文档和差异格式检查通过 |

真实 NAS 的删除权限、并发分页、其他客户端编辑与删除之间的竞态、附件实际删除范围及真机锁屏保护/辅助功能仍为 `PENDING_USER_VALIDATION`，步骤见[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4b3c-本人消息批量删除)。Post.delete 不是带原内容条件的原子删除，不能把合成回读通过写成跨客户端事务保证。M4b4/c/d 与 M5–M8 继续后续实施。

## 2026-10-05 移动 M4b4a 共享发送持久回执

范围为 Apple 共享普通文字、线程文字和单附件发送的最小回执、写前/写后保存、只读恢复，以及旧入口的去重/回读修正；移动队列与界面尚未接入，继续 M4b4b，群聊继续 M4b4c。本次不访问真实 NAS、不修改 Mac App 或 Windows/Android 源码、不改变登录配置、应用身份、权限、最低系统与 NAS 请求。

独立集成复核检查了新旧调用共用请求、公开协议默认拒绝、账号/会话和完整草稿绑定、终态与进行中互斥；分开的只读对抗复核覆盖缺回执不认领同内容、保存失败、旧记录降级候选、附件原文件消失、取消、读取权限丢失及线程归属。补充修复保存完成但尚未提交时取消返回明确未发送，以及实际上传文件名转义后仍用本机原名核查导致永久未知的问题。恢复回执只存身份及摘要，不含正文、名称、路径、附件内容或凭据；远端附件描述不能代替字节校验。

实际命令（仓库根目录）：

```sh
swift test --package-path apple --jobs 2 --filter 'DsmChatRepositoryTests|ChatMessageSendReceiptTests'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests '-only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复' -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b4a-iphone1.xcresult
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 使用同样命令，目标为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，首轮结果 `m4b4a-ipad1.xcresult`。两端 iOS 26.5。包内新增源文件由 Swift Package 自动发现，没有手改生成工程。所有临时日志/测试包均在忽略目录或临时证据目录；不提交真实数据。

| 验证 | 实际结果 |
| --- | --- |
| 既有 Chat 初次聚焦 | 135 项，零失败，0.254 秒 |
| 新回执首次编译 | 测试将已有 `DsmRequestFormat` 误写为不存在的类型名，编译失败；修正引用后通过，没有删除断言 |
| 新回执聚焦 | 152 项零失败，0.595 秒；补恢复保存/取消/附件拒绝后 155 项零失败，0.667 秒 |
| 第一轮共享全量 | 2613 项 XCTest、172 条既有条件跳过、零失败，37.108 秒；12 项 Swift Testing，0.050 秒通过 |
| 首轮移动 | 通用构建通过；两端各 1067 项单元、各 1 条既有条件跳过、零失败，iPhone 26.501 秒、iPad 26.882 秒；实际线程回复界面各 1 项通过，iPhone 30.304 秒、iPad 33.973 秒 |
| 最终共享全量 | 2614 项 XCTest、172 条既有条件跳过、零失败，36.814 秒；12 项 Swift Testing，0.039 秒通过；本切片共新增 21 项行为测试 |
| 最终移动 | 第二次通用构建通过；两端各 1067 项单元、各 1 条既有条件跳过、零失败，iPhone 26.337 秒、iPad 26.691 秒；实际线程回复界面各 1 项通过，iPhone 29.687 秒、iPad 33.040 秒；最终结果为 m4b4a-iphone2/ipad2.xcresult |
| Mac 双架构 | 两次构建均通过；最终修正后复验通过，实际主程序同时含 x86_64、arm64；未安装、启动或发布 Mac 包 |
| 静态门禁 | 本地化 6031/2188/3402、29 组 fixture/48 私有引用、170 请求/1 写结果通过；严格文档与差异检查通过。最初误用脚本目录导致命令未执行，改为上列仓库真实路径后通过 |

`PENDING_USER_VALIDATION`：M4b4b 界面接入后，在专用可丢弃账号/会话使用已记录版本，分别发送文字、线程回复与文件，在创建前后及读回阶段断网、取消、终止 App、重新登录并刷新；没有返回消息编号时不得凭同内容重发。检查历史较多、其他设备编辑/删除、作者/权限变化、附件特殊名称，以及锁屏/低空间保护。只回传版本、权限类别、脱敏步骤、数量和错误类别；不回传正文、真实文件名、路径或凭据。当前共享前置不等于移动持久发送已交付，M4b4/c/d 和 M5–M8 仍未完成。

## 2026-10-05 移动 M4b4b 普通消息、线程与附件发送恢复

M4b4a 共享前置接入移动统一 `MobileChatSendModel/Store/View`，替换普通文字、附件各自的进程内发送，以及不可恢复的线程摘要记录。新增双语发送记录界面与合成发送服务，正式测试覆盖两端界面和真实共享 Repository 调用。独立版本化文件保留未结束草稿正文及受保护附件副本，成功清理；不保存凭据，不改变登录存储、应用身份、权限或最低系统。未访问或写入真实 NAS。

分开的集成复核检查调用收敛、旧无回调移动入口关闭、同账号执行锁与不同账号隔离、终态原子重试及草稿清理；只读对抗复核检查写前保存失败、未知结果不能移除/重发、创建返回身份落盘失败、权限撤回后只读恢复、原始附件消失/副本变化、复制期间切换账号、迟到回调以及发送未结束时编辑/删除原消息的互斥。复核修复恢复目录无效时入口仍可点击、回执与附件描述不匹配、重试后旧失败记录仍可再次点击，以及未结束发送被本机修改/删除的问题。初次聚焦 120 项有 1 项失败，后续根目录检查提前发现故障后更新对应测试的故障归属断言；始终保留零编辑/发送请求与禁止再发送断言。没有删除行为测试或把环境缺失当作通过。

实际命令（仓库根目录）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatSendUITests '-only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复' -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b4b-iphone2.xcresult
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 用相同测试命令，目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`、结果 `m4b4b-ipad2.xcresult`；两端 iOS 26.5。首轮聚焦命令将 only-testing 限定为 `MobileChatSendStoreTests/MobileChatSendTests/MobileChatAttachmentTests/MobileChatInteractionTests/MobileChatModelTests/MobileChatPresentationTests` 六个类；正式全量没有静默跳过新增测试。

| 验证 | 实际结果 |
| --- | --- |
| 构建 | 第 1、3、4、5、6、7、8、9 次通过；第 2 次测试缺少 progress 参数编译失败，补齐后通过。工程由锁定 XcodeGen 2.46.0 生成 |
| 首轮聚焦 | 120 项，1 项失败，4.693 秒；存储目录错误归属问题按上述方式修复 |
| 首轮两端单元 | 各 1090 项、各 1 条既有条件跳过、各 1 条同一旧断言失败；iPhone 26.743 秒，iPad 26.632 秒；全部新增 23 项行为测试通过 |
| 首轮实际 UI | 两端均在第一个用例因系统键盘和聊天按钮同名而定位不唯一，已追加稳定标识；中止剩余重复失败后重新运行，无业务断言删减 |
| 共享全量 | 2614 项 XCTest、172 条既有条件跳过、零失败，37.572 秒；12 项 Swift Testing，0.055 秒通过 |
| Mac 双架构 | 构建通过，实际主程序同时含 x86_64、arm64；未安装、启动或发布 Mac 包 |
| 第二轮两端单元 | 各 1090 项、各 1 条既有条件跳过、零失败；iPhone 25.996 秒，iPad 26.009 秒 |
| 第二轮实际 UI | 两端各 5 项零失败；iPhone 203.295 秒，iPad 210.383 秒；覆盖重启只读恢复、缺回执保持保护、终态移除、中文深色大字号拒绝重试，以及原搜索/线程回复 |
| 截图复核后的窄栏修正 | iPad 竖屏输入框被附件按钮挤窄，改为系统 ViewThatFits 自动把输入框独立成行；删除发送详情重复反馈。新增输入框宽度断言；两端各 14 项展示测试与 2 项实际 UI 零失败（iPhone 73.892 秒、iPad 76.039 秒），截图确认窄栏输入已可用；随后限定工具图标尺寸，保留动态文字和 44 点点击区，补中文大字号实际 UI 回归两端均通过，iPhone 40.537 秒、iPad 42.168 秒 |
| 静态门禁 | 双语 6052/2188/3402、29 组 fixture/48 私有引用、170 请求/1 写结果、严格文档和差异检查通过；初次动态资源键检查失败后改用明确枚举映射 |

最终布局定向复验沿用上列 `test-without-building` 命令，only-testing 为 `DsmMobileTests/MobileChatPresentationTests` 及 `DsmMobileUITests/MobileChatSendUITests/test普通消息发送成功后记录可移除且不会删除聊天消息`、`DsmMobileUITests/MobileChatSendUITests/test中文深色大字号明确拒绝可重新发送并更新唯一记录`，结果为 `m4b4b-iphone3/ipad3.xcresult`。图标调整后的最后一次仅保留上述中文用例，结果为 `m4b4b-iphone4/ipad4.xcresult`。未因纯移动布局变化重复共享或 Mac 构建；其共享源码和资源与已通过版本相同。

真实 NAS、真机锁屏文件保护、系统终止与辅助功能为 `PENDING_USER_VALIDATION`，前提、操作、预期结果与脱敏反馈范围集中在移动主计划 M4b4；远端文件名/大小读取不能证明字节相同。M4b4c 建群恢复、M4c/d 媒体实时与 M5–M8 不计为本切片完成。

## 2026-10-05 移动 M4b4c 群聊分步创建与恢复

范围为共享 Chat 群聊回执、新重载与分步恢复、移动创建模型/独立记录/原生表单、对应双语资源和测试。原单聊恢复保留，移动旧群聊内存草稿与按同名认领路径删除；新旧共享建群调用共用 Named v1 三个实际请求，Mac 原调用及其既有会话复用行为未改为移动恢复语义。没有改动 Mac App、Windows、Android、身份、最低系统版本或登录格式，也没有执行真实 NAS 创建或邀请。

`ChatGroupCreateReceipt` 绑定 UUID、当前用户、标题摘要、成员 ID、创建返回的群聊编号与三步阶段；写前和回执后分别保存。缺编号不能按同名认领；未知加入/邀请只读，明确继续才补安全的剩余步骤，当前已经在群内的成员不重复邀请。移动独立版本 1 `group-creations-v1.json` 暂存未完成标题和成员，原子写入、完整文件保护、排除备份，不保存凭据；终态删除草稿，未提交记录可取消。多记录按账号隔离，相同草稿去重，同账号执行互斥；未知记录不阻止准备其他聊天。切换账号后迟到回执仍归原账号，下一步不自动执行。

完成分开的只读集成与对抗复核，没有使用另一模型进行审查。复核覆盖保存失败零写、回执补保存、修订号合并、三个步骤各自取消/丢回执/拒绝、117 仅适用于加入、原账号/群聊编号/标题/加密状态、缺少成员和本人被移出、能力撤回后只读恢复、跨模型锁与原账号迟到回执。新增单聊/群聊同时未完成的回归：恢复单聊时不被群聊记录选中状态抢占，原群草稿仍保留。新增共享 22 项测试；移动新增 22 项（其中 1 项文件保护设备条件测试）及 4 项实际 UI。

实际命令（仓库根目录；日志和结果前缀 `/tmp/lanstash-release-1.0.15.1x6wUX/m4b4c-`）：

```sh
swift test --package-path apple --jobs 2 --filter DsmChatRepositoryTests
swift test --package-path apple --jobs 2 --filter 'DsmChatRepositoryTests|ChatGroupCreateReceiptTests'
swift test --package-path apple --jobs 2
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatGroupCreationUITests -only-testing:DsmMobileUITests/MobileChatUITests/test新联系人打开单聊并进入会话 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b4c-iphone1.xcresult
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4b4c-iphone2.xcresult
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 两轮对应替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 和 `m4b4c-ipad1/2.xcresult`。首轮聚焦 `m4b4c-focused1` 使用同一 `test-without-building`，选择 MobileChatGroupCreationStoreTests、MobileChatGroupCreationTests、MobileChatModelTests、MobileChatPresentationTests、MobileChatConversationCreationStoreTests。工程始终由锁定 XcodeGen 2.46.0 生成；build1–5 均成功，build4 更新字体检查，build5 加入单聊/群聊并存恢复修正。第 2 轮仅重跑完整单元，未重跑已经通过且界面代码未变的四项建群 UI 和单聊 UI；此前两个失败的源码断言并未被计作通过。

| 验证 | 实际结果 |
| --- | --- |
| 共享聚焦 | 既有 152 项、新增第一轮 170 项、最终 174 项均零失败；最终 0.332 秒 |
| 共享全量 | `m4b4c-shared-full1.log`：2636 项 XCTest，172 条既有条件跳过、0 失败，37.004 秒；12 项 Swift Testing 0.082 秒 |
| 聚焦移动首轮 | 102 项、3 失败：两条既有源码检查误把纯图标固定字号视作文字固定字号，另一个文件保护属性断言在模拟器返回 nil；所有建群行为用例通过 |
| 两端第 1 轮完整单元 | 各 1111 项、各 2 条条件跳过及 2 条字体检查失败；仅豁免发送图标后仍漏掉附件的两个纯图标，故此轮不计通过 |
| 两端第 2 轮完整单元 | 各 1112 项、各 2 条明确条件跳过、0 失败；iPhone 27.219 秒，iPad 26.904 秒。字体检查严格限定三个 24 点纯图标，其余可见文字仍禁止固定字号，并检查 44 点按钮区域 |
| iPhone 实际 UI | 四项新增建群加一项原单聊共 5 项零失败，202.831 秒；包含正常群聊、创建丢回执/新建其他聊天/返回记录、加入中断重启/刷新/主动邀请、中文深色辅助功能 XXXL |
| iPad 实际 UI | 同一组 5 项零失败，232.303 秒；独立系统模拟器，不能以 iPhone 代替 |
| macOS 回归 | `m4b4c-mac1.log` Release 构建通过；`lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 实际返回 `x86_64 arm64` |
| 静态门 | 本地化 Apple 6069 / Android 2188 / Windows 3402；170 个请求 Fixture、1 个写结果、29 组 fixture / 48 项私有 API 文档引用、严格文档与差异空白检查均通过 |

截图从两份第 1 轮结果用 `xcrun xcresulttool export attachments --path ... --output-path ...` 导出。已检查 iPhone 中文深色大字号错误/继续按钮与 iPad 浅色三步进度、中文深色大字号；文字可换行和滚动，三个阶段与恢复操作可达，没有截图中的真实账号或 NAS 数据。临时截图和日志仅在上述临时目录，不提交。

`PENDING_USER_VALIDATION`：真实 NAS 建群/加入/邀请、权限撤回、原群改名或本人被移出、网络切换，以及 iPhone/iPad 锁屏前后文件保护。两个条件跳过为既有照片删除保护及新增建群保护；新增断言以独立系统写入确认模拟器不返回保护属性后明确报告待验，保留真机断言，不能把缺属性解释成保护通过。设备步骤、需回传的脱敏信息和回滚边界见移动主计划 M4b4c。没有安装/启动 Mac 测试包或进行移动分发；M4c/d 媒体/实时及 M5–M8 继续实施。

## 2026-10-05 移动 M4c 语音消息与自适应聊天布局

本波次仅增加移动 Chat 音频模型/原生驱动/界面与必要附件、组合根和导航接线，新增麦克风用途双语说明及四项共享文案、合成音频 fixture、单元/实际 UI 测试。沿用 Post.create v5 单附件、Post.File 读取与 M4b4 发送回执；没有新增私有请求、公开契约、依赖、最低系统版本、主 App 身份、后台音频模式或恢复格式。Mac App、Windows、Android 未改；共享资源执行完整 Apple 测试与 Mac 双架构回归。没有访问真实 NAS 或采集现场声音。

录音只在明确开始后申请权限，AAC 单声道、至少半秒、最长五分钟；停止、试听、暂停、丢弃和发送均为原生操作。录音和消息播放共用单一驱动，后台/音频中断不自动重启，耳机断开暂停；新录音取消尚未完成的下载。临时录音有 0700/0600 权限、完整系统文件保护请求与备份排除，发送先移交原有持久副本；准备失败保留当前录音，已提交未知只进入原发送记录。权限、播放和下载迟到回调均按原代次/账号处理，丢弃后清理旧试听错误。

iPad 按实际聊天宽度与动态文字决定并列详情或导航栈；当前页面通过 UIKit 布局和安全区域回调报告宽度，避免隐藏根几何与重复边距扣减；旋转只重排同一导航层级内的内容。每个详情实例有独立可见性所有者，旧实例退出不能清理新的详情状态或媒体；进入任务包含账号身份。宽度切换保留所选会话，不依赖可能先被退出回调清除的可见标记。21 项新增单元中有 1 项明确设备条件测试；五项新增实际 UI 覆盖系统解码播放、合成 AAC 录制/试听/发送/原字节下载播放、损坏文件恢复、未知发送保留一条记录、中文深色辅助功能 XXXL 与旋转。

完成分开的只读集成与对抗复核，没有使用另一模型审查。复核权限请求时机、无加密媒体读取、同源 Repository 复用、大小与临时文件归属、旧回调、同一播放器互斥、发送复制期间的源保留和未知不重发。截图复核与强化 UI 断言实际发现并修复 iPad 返回竖屏丢失详情、旧实例清除新详情导致重复搜索入口的问题；不是通过删除或放宽断言消除失败。

实际命令（仓库根目录，日志与结果前缀 `/tmp/lanstash-release-1.0.15.1x6wUX/m4c-`）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatAudioUITests -only-testing:DsmMobileUITests/MobileChatUITests/test新联系人打开单聊并进入会话 -only-testing:DsmMobileUITests/MobileChatGroupCreationUITests/test新建群聊选择成员后进入对应会话 -only-testing:DsmMobileUITests/MobileChatSendUITests/test普通消息发送成功后记录可移除且不会删除聊天消息 -only-testing:DsmMobileUITests/MobileChatManagementUITests/test会话多选取消确认和关闭结果 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4c-iphone1.xcresult
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatAudioUITests/test合成录音停止试听暂停发送后显示语音附件 -only-testing:DsmMobileUITests/MobileChatAudioUITests/test语音消息一次点击播放暂停并在旋转后保留会话 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4c-iphone4.xcresult
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 使用相同命令、目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，两端 iOS 26.5。第 2 轮与第 4 轮选择相同完整单元及两项 UI，结果后缀为 2；第 3 轮只选择 `MobileChatAudioTests`、`MobileChatPresentationTests` 和完整 `MobileChatAudioUITests`，结果后缀为 3。首轮聚焦 `m4c-focused1` 选择 Audio/Attachment/Model/Send 四个单元类。最终第 11 轮使用首轮相同的完整单元及九项 UI 选择，结果后缀为 11；第 5/8/9 轮为 iPad 布局定位，相关完整结果见下表。XcodeGen 固定 2.46.0；第 1 次构建因附件大小字段误用 `byteCount` 失败，改用既有 `sizeBytes`；第 2–22 次构建均通过，未改变工具链。

| 验证 | 实际结果 |
| --- | --- |
| 首轮聚焦 | 95 项，0 失败，1.130 秒；当时新增音频 15 项 |
| 第 1 轮完整单元 | 两端各 1131 项、3 条明确条件跳过、0 失败；iPhone 26.999 秒，iPad 26.574 秒 |
| 第 1 轮实际 UI | 新增五项音频加四项既有单聊/建群/关闭/发送，共 9 项各端零失败；iPhone 258.730 秒，iPad 279.050 秒 |
| 第 2 轮完整单元 | 两端各 1131 项、3 条明确条件跳过、0 失败；iPhone 27.511 秒，iPad 27.217 秒 |
| 第 2 轮实际 UI | AAC 原字节上传后下载播放两端通过；iPhone 两项共 64.737 秒零失败；iPad 转回竖屏未重新打开详情，2 项中 1 失败，74.090 秒。不将第一轮存在性检查当作严格横屏/竖屏对齐证明 |
| 第 3 轮聚焦单元 / UI | 两端各 33 项、1 条明确条件跳过、0 失败，iPhone 3.221 秒、iPad 3.141 秒；五项音频 UI 各端零失败，分别 141.421/153.057 秒。随后截图发现旧详情退出清除新详情状态，追加唯一所有者回归与工具栏无重复入口断言 |
| 第 4 轮完整单元 / UI | 两端各 1132 项、3 条明确条件跳过、0 失败，iPhone 26.583 秒、iPad 26.411 秒；两项 UI 为 iPhone 64.293 秒零失败，iPad 66.557 秒含横屏空白详情 1 失败 |
| 第 5–8 轮布局定位 | 第 5 轮两端各 14 项展示检查通过，无动画导航切换仍在 iPad 失败；第 6 轮固定会话导航层级后，iPhone 九项 UI 零失败，iPad 八项通过、双栏断言失败；第 7 轮两端完整 1132 项、3 条跳过、0 失败，iPad 同一双栏断言仍失败。第 8 轮临时数值记录确认外层 490 点已扣除边栏，却又被减去 330 点，且隐藏根不继续报告旋转尺寸；未用降低宽度门槛消除失败 |
| 第 9 轮原生尺寸复验 | 改用当前 UIKit 页面安全区域后，iPad 严格双栏/返回竖屏/播放/单一搜索入口通过，37.464 秒；已移除临时诊断源码及两个模拟器中的诊断文件 |
| 第 10 轮 | 两端各 1132 项、3 条跳过、0 失败；iPad 真正分栏重排时录音窗口消失，新增的录音中旋转断言失败。将表单上移至稳定根容器，以绑定保留录音；新增账号退出仍清理的行为测试，不能把第 7 轮未展开双栏的录音结果当作此场景通过 |
| 最终第 11 轮 | 两端各 1133 项单元、3 条明确条件跳过、0 失败，iPhone 26.822 秒、iPad 27.215 秒；各 9 项实际 UI 零失败，分别 264.714/294.953 秒。包括录音中旋转、真实分栏与再次播放后的稳定双栏断言、原 AAC 字节上传/下载/系统解码、中文深色大字号及原单聊/建群/关闭/普通发送 |
| 共享完整回归 | 2636 项 XCTest、172 条既有条件跳过、0 失败，35.791 秒；12 项 Swift Testing，0.041 秒 |
| macOS 回归 | Release 构建通过，实际主程序经 `lipo -archs` 返回 `x86_64 arm64`；未安装、启动或发布 |
| 静态门 | Apple 6073 / Android 2188 / Windows 3402 双语资源；170 个请求 Fixture / 1 个写结果、29 组 fixture / 48 项私有记录引用、严格文档与差异检查均通过 |

截图由 `xcrun xcresulttool export attachments --path ... --output-path ...` 导出，已检查 iPhone 中文深色大字号、iPad 录音表单、横屏并列与竖屏单列。XCTest 的应用窗口截图在横屏附带旋转/裁切，改用 `XCUIScreen.main.screenshot()` 捕获完整设备；保留原附件，不把裁切附件当作完整布局证据。所有截图、日志、合成媒体和结果包在专用临时目录或隔离模拟器，不提交。

`PENDING_USER_VALIDATION`：真实麦克风授权/撤回、来电、耳机与蓝牙、锁屏/返回、真实 AAC 在双方客户端互播、VoiceOver/键盘/窗口和完整文件保护，具体前置、步骤、预期与脱敏反馈见移动主计划 M4c。三条设备条件跳过分别为照片删除记录、群聊恢复记录与新录音保护；新测试以独立系统写入识别模拟器不返回属性，真机断言仍保留，不能计作保护通过。没有移动分发或真实 NAS 写入；M4d 及 M5–M8 继续实施。


## 2026-10-05 移动 M4d 前台聊天、已读与本地提醒

基线 `7047c62f`；仅移动工作区/Chat/设置接线、原生通知与阅读位置适配、双语资源、合成 fixture、测试和相关文档。没有新增私有字段、公开业务接口、依赖、最低系统、App 身份、推送权限或后台模式；Mac App、Windows、Android 源码不改。新增两个独立通知偏好键，仅保存开关与账号摘要到随机标识的映射，不存正文、地址或凭据，不改变登录配置。

前台工作区维持单一实时连接与 30 秒补读；离开 Chat 页保留发送记录，后台取消订阅/未完成刷新。主会话按最新实际可见消息时间调用已读并核对回读，不把预加载当作阅读、不回退其他设备更晚时间；线程只在最新回复实际可见后同步。历史位置与游标保留，分页缺口通过“最新消息”重新定位。通知只有主动开启才申请权限；初次静默、他人新消息提示和定时提醒都不包含正文，账号切换/退出/权限撤回清理请求；当前会话正在阅读时抑制重复提示。本机最多安排 50 条最近未来提醒，其他客户端在 App 后台期间的取消/改期必须等重新连接才能同步。

实施后分离进行只读集成与对抗复核，不表述为另一模型审查。25 项新增行为测试涵盖实际请求/解析、权限、历史/预加载、迟到读回执、跨账号、跨设备更晚已读、本人消息、线程、重叠分页/缺口、前台其他模块、通知首屏静默、重复/改期/取消、50 条限制、权限撤回与重启定位。UI 通知替身只写内存，显式 UI fixture 不启动真实 Socket，不触碰 NAS、现场麦克风或系统通知；阅读位置则由真实 UIKit 窗口、裁剪、遮挡和点击命中验证。

实际命令（仓库根目录，完整输出与结果使用本轮临时目录 `m4d-*`，不提交）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4d-iphone4.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatRealtimeUITests -only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复 -only-testing:DsmMobileUITests/MobileChatAudioUITests/test语音消息一次点击播放暂停并在旋转后保留会话 test-without-building
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m4d-ipad4.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatRealtimeUITests -only-testing:DsmMobileUITests/MobileChatUITests/test聊天搜索打开原消息并发送线程回复 -only-testing:DsmMobileUITests/MobileChatAudioUITests/test语音消息一次点击播放暂停并在旋转后保留会话 test-without-building
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py --strict
git diff --check
```

| 验证 | 实际结果 |
| --- | --- |
| 移动构建 | 最终第 10 轮 `TEST BUILD SUCCEEDED`；新增文件由锁定 XcodeGen 2.46.0 生成 |
| iPhone / iPad 完整单元，第 4 轮 | 各 1158 项、3 条既有明确设备条件跳过、0 失败；27.359 / 27.079 秒 |
| iPhone / iPad 实际 UI，第 4 轮 | 各 6 项零失败；180.647 / 188.307 秒；四项新增阅读/前台/通知流程、搜索线程回复及语音旋转 |
| 原音频全部五项，第 2 轮 | 两端五项均通过；其中播放旋转又在最终轮通过。相同轮次的两项新阅读 UI 曾失败，不能把该整轮写为通过 |
| 聚焦及三项 UI，第 3 轮 | 两端各 39 项行为/呈现测试零失败，3 项实际 UI 零失败；UI 85.817 / 91.415 秒 |
| 共享 Apple | 2636 项 XCTest、172 条既有条件跳过、0 失败，32.627 秒；12 项 Swift Testing、0 失败，0.033 秒 |
| Mac Release | 两次双架构构建通过，第二次覆盖最终中文 App 名称文案；实际主程序 `lipo -archs` 为 `x86_64 arm64` |
| 静态与契约 | 双语/占位符/硬编码通过：Apple 6084、Android 2188、Windows 3402；170 个请求 fixture、1 个写结果示例、29 组 fixture / 48 项私有 API 引用、严格文档与差异检查通过 |

保留失败与修复记录：第 2 次构建的 Swift 6 通知回调跨 actor 访问失败，改为在主 actor 执行回调；第 3 次构建的测试闭包访问主 actor 失败，改用明确的主 actor 检查。初轮 iPhone 100 项聚焦测试一项精确请求计数失败，是启动补读与故障注入重叠；明确等待启动同步后再注入，保持原计数和状态断言。第 2 轮两端完整单元通过，但 UI 各 9 项中 2 项找不到“最新消息”标识：截图显示按钮可见，页面容器覆盖了子按钮无障碍标识；增加可访问容器后，保留点击、真实末尾可见、未读变化及拒绝后未读保留的断言，第 3/4 轮均通过。没有删除测试、降低断言或把未运行实机项目改成通过。

已查看两端长历史/末尾消息、未读保留、搜索线程以及中文深色超大字号通知恢复截图。实际系统权限弹窗、锁屏通知、系统终止/点击、提醒调度、真实 NAS/多客户端及完整辅助功能为 `PENDING_USER_VALIDATION`，条件、步骤、预期和脱敏反馈见[移动主计划 M4d](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4d-前台实时阅读同步与本地提醒)。M4 源码范围收口；继续 M5–M8，不发布移动安装包，不把后台远程新消息推送列为待设备验证。


## 2026-10-05 移动 M5a1 下载完整目录与详情

基线 `04cad733`。移动 Downloads、新增详情与展示类型、合成 transport、对应单元/UI、双语资源及生成工程；共享公开读取的兼容增量与分页修正。Mac App、Windows、Android 源码不改；未改变身份、权限、最低系统或持久格式。官方 Task.list/getinfo 固定 v1，additional 按指南使用逗号串；Task.edit 字段表要求 v2，而旧 Android 快照仍绑定 v1，本轮单独保留已知偏差并提供 v2 样本，不将其当作已修复实现。

完整目录不再受原 5000 项上限约束，已知总量短页继续读取，重复 ID、错位、漂移、畸形或过早空页拒绝完整结论。公开删除查询复用完整清单，不能把首批 1000 项之外的任务当作已删除；Mac 摘要仍保持原范围，内部备用仍标为受限。统计缺失不补零；详情包含任务内文件、来源站及参与者，Tracker 不展示 userinfo、路径和查询中的密钥，不持久化详情。迟到列表/详情不能覆盖新账号、替换 Repository 或新操作状态。

构建候选前分离执行只读集成复核，并复核涉及共享写结果查询的取消/丢回执路径。本项为当前负责人的独立复核阶段，不声称另一个模型执行。新增 15 项共享测试和 9 项移动行为测试；真实界面覆盖五态、搜索恢复/状态筛选、详情失败重试、文件与安全来源显示、中文深色最大辅助字号与横竖屏。

实际命令（仓库根目录，日志与结果在专用临时目录 `m5a-*`，不提交）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m5a-iphone4.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadInventoryUITests test-without-building
swift test --package-path apple
swift test --package-path apple --filter 'DownloadStationInventoryTests|DsmServiceManagementRepositoryTests'
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
python3 tools/codex/generate_api_reference.py
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py --strict
git diff --check
```

iPad 用相同测试命令，目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`、结果包 `m5a-ipad4.xcresult`。两端 iOS 26.5。首轮选择全部 `DsmMobileTests` 与上述四项 UI，第二/三轮选择 `MobileDownloadInventoryTests`、`MobileDownloadsSafetyTests` 与四项 UI；最终第四轮重新选择全部移动单元及四项 UI。第 1–5 次及第 7–8 次构建使用具体模拟器目标，第 6 次使用 generic 目标。

| 验证 | 实际结果 |
| --- | --- |
| 构建 | 前八次移动构建通过，锁定 XcodeGen 2.46.0 重复生成一致；Mac Release 双架构构建通过，实际主程序经 `lipo -archs` 为 `x86_64 arm64`，未安装或启动 |
| 首轮完整移动单元 | 两端各 1165 项、3 条既有明确条件跳过、0 失败；iPhone 28.040 秒，iPad 28.002 秒 |
| 第二轮聚焦移动单元 | 两端各 18 项、0 失败；iPhone 0.191 秒，iPad 0.209 秒；详情迟到测试直接执行继续下载再交付旧详情，保持状态断言 |
| 共享完整回归 | 2651 项 XCTest、172 条既有条件跳过、0 失败，34.499 秒；12 项 Swift Testing、0 失败，0.035 秒 |
| 共享最终分页/结果聚焦 | 最终 additional 逗号串及两项新增删除分页回归后，165 项、0 失败，0.490 秒 |
| 第四轮完整移动单元 | 两端各 1167 项、3 条既有明确条件跳过、0 失败；iPhone 27.973 秒，iPad 27.965 秒 |
| 最终移动 UI | 第四轮两端各 4 项零失败；iPhone 160.001 秒，iPad 178.727 秒；搜索/筛选、五态、详情失败重试/文件/安全 Tracker 和中文深色大字/旋转均通过 |
| 静态与契约 | 双语、占位符及硬编码通过：Apple 6103 / Android 2188 / Windows 3402；173 个请求 fixture、1 个写结果、29 组 fixture / 48 项私有记录引用通过 |

中间失败如实保留：共享首轮 163 项中的 2 项共 3 处断言失败，其中详情 additional 编码未按官方逗号串、取消检查提前跳过已提交控制的只读结果读取；改正编码并对提交后取消执行独立只读查询，保留原断言，第二轮 163 项零失败。UI 首轮 iPhone 四项中 2 项失败、iPad 四项中 3 项失败；第二轮均四项中 2 项失败。根因为 iOS 26 系统搜索折叠/关闭按钮变化、滚动误选侧栏或弹窗外、部分可见条目被误判为可操作。使用明确详情表单容器、当前列表与可见区域滚动，并保留搜索、剩余值、文件及安全 Tracker 展示断言，不把未通过轮次表述为通过。第三轮两端搜索/筛选、中文深色大字体/旋转及五态通过，但详情重试一项仍失败：滚动测试为底部预留过大固定区域，无法将页面末尾按钮移入判定区域；按实际导航/标签栏位置计算可见范围。随后收尾检查发现执行中才开始的读取可晚于操作完成返回，补充两项实际异步时序测试，并在控制/创建/移除完成时推进代次，第四轮完整单元通过。

已导出并查看两端普通字号浅色的筛选/无结果/任务文件、中文深色最大辅助字号及横屏截图；所有内容来自显式合成 fixture，不访问 NAS。最后本地化、请求目录一致性、契约、严格文档及差异检查均通过。

`PENDING_USER_VALIDATION`：iPhone/iPad 真机、已记录 DSM/Download Station 版本、专用普通及管理员账号，验证超过一页的混合状态任务、搜索/排序、真实零与缺失速度、BT 文件/Tracker/参与者、非 BT 缺少附属内容、读取中取消/断网/切账号，以及另一客户端并发变更目录。预期未知显示 `--`、部分目录明确受限、刷新失败保留旧清单且可重试、旧详情不覆盖新状态；来源站不显示下载密钥。单独补验 VoiceOver、键盘、最大字号与分屏。只回传版本、数量、权限类别、脱敏步骤及错误类别，不提供任务名、路径、地址、响应或凭据。真实 NAS 未参与本轮自动操作；多选控制、持久恢复、设置、编辑/RSS 及文件删除仍属后续 M5 切片，不能记为仅待设备验证。


## 2026-10-05 移动 M5a2 多选下载控制与持久恢复

基线 `8559a1f9`。新增下载任务多选、逐项结果与操作记录，单项暂停/继续复用同一流程；本机独立 `Downloads/controls-v1.json` 只保存账号上下文摘要、任务编号、身份摘要、动作和阶段，不保存名称、路径、下载地址或凭据。记录受文件保护并排除备份，损坏或写前保存失败时不发送。离开页面不撤销已提交项目；未知结果停止余项，重启仅查询，剩余项目需明确继续/取消。取消立即持久保存，切账号后晚到结果只结束原记录；同任务的反向控制与移除不能绕过未结束记录。

共享网络保留原协议签名，新增写前回调、完整只读状态读取及本机终态后的临时记录释放；无新 NAS 参数。首次构建前后分别复核数据来源、原状态与身份、取消/迟到、互斥、保护文件、重启和 UI 恢复入口。独立集成与只读对抗复核由当前负责人分离执行，不声称另一个模型审查。修复取消必须立即保存，以及恢复结束后旧进程内记录误拦下一次同动作的问题；共享和真实 Repository 的移动测试均覆盖后者。Mac App、Android、Windows 源码不改。

实际命令（仓库根目录；日志及结果包为专用临时目录下 `m5a2-*`，不提交）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadControlUITests -only-testing:DsmMobileUITests/MobileDownloadInventoryUITests -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m5a2-iphone1.xcresult
swift test --package-path apple --jobs 2 --filter 'DownloadStationControlRecoveryTests|DsmServiceManagementRepositoryTests'
swift test --package-path apple --jobs 2
swift test --package-path apple --jobs 2 --filter 'DownloadStationControlRecoveryTests|Localization'
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/codex/check_documentation.py --strict
git diff --check
```

iPad 采用同一测试命令，目标为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包为 `m5a2-ipad1.xcresult`。首次聚焦 iPhone 为 Control/Safety/Inventory/WorkspaceIsolation 四组 38 项；正式第一轮两端完整单元 1186 项（各 3 条既有明确设备条件跳过）、0 失败，iPhone 28.142 秒、iPad 28.214 秒。新增行为测试 14 项、恢复存储 5 项、共享控制 7 项。

共享完整回归 2658 项 XCTest、172 条既有条件跳过、0 失败，32.983 秒；12 项 Swift Testing 通过，0.046 秒。最后文案调整后的共享聚焦 7 项与本地化 Swift Testing 6 项再次通过。Mac Release 双架构构建三次通过，实际主程序为 `x86_64 arm64`；没有安装或启动。当前本地化 Apple 6126 / Android 2188 / Windows 3402，双语/占位符/硬编码扫描通过；173 个请求 fixture、1 个写结果、29 组脱敏 fixture / 48 个私有记录引用、参数目录一致性及严格文档检查通过。

中间失败如实保留：第一轮构建因局部函数缺少主线程隔离标注失败，补标注后构建通过；共享首轮 156 项中一项 2 处失败，新增只读恢复入口未拒绝空白/控制字符，修正后第二轮 156 项零失败。iPhone 首次聚焦 38 项中两项共 6 处断言失败，旧竞态样本将“继续任务”同时改变标题，被身份保护正确拦截；改成原任务和结果保持同一身份，迟到读取仍返回过时标题与状态，保留所有原断言，完整两端回归通过。第一轮实际 UI：iPhone 8 项零失败、337.449 秒；iPad 8 项中 1 项失败、373.167 秒，原因是返回选择页时误点外层导航按钮，已限定目标导航栏；其他新流程和原四项目录 UI 通过。截图复核另修正深色选择行的默认按钮着色，文件名与状态恢复正常文字颜色，并为单项未知操作补直接打开记录的入口。

最后第 7 次移动构建通过，前述第 2–6 次构建也均通过，锁定 XcodeGen 再生成完全一致。第二轮使用同一 `test-without-building` 命令，保留 `-only-testing:DsmMobileTests` 与 `-only-testing:DsmMobileUITests/MobileDownloadControlUITests`，移除已通过的 Inventory UI 选择器，结果分别为 `m5a2-iphone2.xcresult`、`m5a2-ipad2.xcresult`。最新两端各 1186 项单元、各 3 条既有条件跳过、0 失败；iPhone 27.556 秒，iPad 27.648 秒。五项新 UI 全部通过，iPhone 197.283 秒，iPad 214.998 秒：批量暂停/继续、未知重启后只读与显式继续、取消后空目录仍可查看记录、中文深色大字及旋转、单项未知直接打开记录。新增权限恢复失败断言确认保留原记录并提示管理员，不因查询失败重发。

已查看第一轮两端合成截图，核实 iPad 表单、逐项结果与 iPhone 大字选择，按截图修正文字颜色；最终已复核 iPhone 中文深色大字选择的正常文字颜色及 iPad 单项结果记录；单项记录没有剩余项目，已移除该提示中不适用的剩余操作说明。单项说明调整后第 8 次移动构建及第 3 次 Mac 构建通过；第三轮仅选择 `-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test单任务结果暂不可用时可直接进入操作记录`，结果为 `m5a2-iphone3.xcresult` 和 `m5a2-ipad3.xcresult`，两端各 1 项零失败，分别 29.452 秒和 32.945 秒。最终本地化检查仍通过。所有截图与响应均为合成数据。文档严格检查曾拒绝将 CI Run ID 写进活动 Android 计划，已将具体 Run ID 保留在本历史页，活动计划只记录问题与提交，复验通过。

`PENDING_USER_VALIDATION`：两种真机、已记录 DSM/Download Station 版本、专用可丢弃混合状态下载任务、普通/管理员账号；测试批量暂停/继续、离页、断网、终止、重连、切账号和其他客户端修改/移除任务。预期逐项状态准确、未知不重放、剩余显式继续/取消、取消决定重启后保留、旧账号结果不进入新页面、恢复完成后可以再次操作。单独验证锁屏文件保护、权限撤销、VoiceOver、键盘、最大字号及 iPad 分屏；仅回传版本、数量、权限类别、脱敏步骤及错误类别，不提供名称、路径、地址、响应或凭据。实际 NAS 未参与自动写测试。创建恢复、设置、任务编辑/RSS、做种与移除/实际文件删除分别继续 M5b/M5c/M5d，不由本切片宣布整个 M5 完成。

云端边界：上一个提交 `8559a1f9` 的仓库与文档检查通过；Android Build `37242202350` 的 1436 项 JVM 中 1 项既有投票样例失败，实际 choices 字符串数组与 `e069cb3d` 起的共享对象数组样例不符。问题已记录在 Android 计划，本轮不改 Android 源码或降低断言；Apple 云端完整检查仍在运行，不能与本机两端验收混为一谈。

## 2026-10-05 移动 M5b 下载设置与分步恢复

基线 `44986a84`。iPhone/iPad 新增默认目录选择、eMule/自动解压、现有限速及两个计划开关，复用原生表单和现有文件夹选择器。共享增量快照明确管理权限及字段存在性；每个分区只保存用户改动且原值仍匹配的字段，HTTP/FTP 共用值成对处理，默认目录需要 Info v2。旧 Mac 设置类型、协议签名和行为保持，Windows/Android 只登记契约影响。新增两个差量请求 fixture，旧全量样本不改。

恢复文件 `Downloads/settings-v1.json` 保存账号上下文摘要、变更字段原值/目标值和常规/计划分区阶段；目录为继续操作所需的受保护数据，不存凭据、主机或下载 URI。写前保存失败不发送，未知只读恢复，未开始分区明确继续/取消。取消立即保存，离页仅关闭，旧账号结果只结束旧记录。已确认字段立即更新本机基线，后续附加刷新失败不让已完成修改再次出现在保存按钮中。生产装配使用 `MobileTransferRecoveryStore.application` 的固定根，不采用测试用随机目录。

独立集成与只读对抗复核由当前负责人分离执行，不声称另一模型参与。逐项检查权限未知/撤销、原值竞争、公开版本、缺失字段、HTTP/FTP 同值、发送前后取消、损坏/写失败、同账号新连接和跨账号迟到、未知恢复及表单操作含义。修正未知权限不能误报无权限、读取取消的加载状态、用户取消不能显示虚假读取错误，以及已保存后附加刷新失败的重复保存提示。没有真实 NAS 自动写测试、第三方依赖、身份/签名权限变更或正式发布。

实际命令（仓库根；日志、截图和结果包均在专用临时目录的 `m5b-*` 中，不提交）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m5b-iphone1.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadSettingsUITests -only-testing:DsmMobileUITests/MobileDownloadControlUITests/test多选暂停与继续分别处理符合状态的任务 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
swift test --package-path apple --jobs 2 --filter DownloadSettingsSnapshotTests
swift test --package-path apple --jobs 2
swift test --package-path apple --jobs 2 --filter 'DownloadSettingsSnapshotTests|Localization'
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/codex/check_documentation.py --strict-release
git diff --check
```

iPad 使用同一测试命令，将目标替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包改为 `m5b-ipad1.xcresult`。移动构建第 1–6 次均通过；新增移动模型/存储行为 13 项，共享实际请求行为 10 项，原生设置 UI 5 项。共享完整 2668 项 XCTest、172 条既有条件跳过、0 失败，35.113 秒；12 项 Swift Testing 通过，0.041 秒。首次共享聚焦 10 项通过；补充差量 fixture 参数逐项断言后的第二次聚焦 10 项通过，0.153 秒；最终资源后的第三次聚焦 10 项 XCTest（0.084 秒）和 6 项本地化 Swift Testing（0.041 秒）通过。Mac Release 两次双架构构建通过，实际程序包含 `x86_64 arm64`，没有安装或启动。

中间失败如实保留：第一轮两端各 1198 项单元、各 3 条既有设备条件跳过、0 失败（iPhone 28.132 秒，iPad 28.048 秒），既有多选暂停/继续 UI 分别通过（39.567 / 45.015 秒）；五项新 UI 首轮各有五项失败（217.820 / 338.281 秒）。实际页面问题是长表单保存后反馈仍在上方不可见，已复用项目原生滚动定位到结果，并将离页按钮改为“关闭”；保存中的状态不再显示为结果暂不可用。测试问题为读取外层容器而非按钮的禁用状态、组合无障碍标签，以及文件夹按钮实际名称为“Choose”。均修正具体定位和结果检查，没有删除流程断言。

第二轮仅选择新设置 UI 和 `MobileDownloadInventoryUITests/test任务搜索无结果后可恢复完整列表`，结果为 `m5b-iphone2.xcresult` / `m5b-ipad2.xcresult`。两端既有搜索/筛选均通过（30.270 / 34.323 秒）；iPhone 新五项因系统溢出菜单不保留工具栏标识而均失败，随后依据实际无障碍树改用菜单保留的双语动作标题。iPad 新五项中四项通过，唯一失败是中文组合标签使用顿号，测试误用了英文逗号；现分别断言业务标题和完整结果，不绑定系统分隔标点。iPad 五项共 259.791 秒，iPhone 133.754 秒。工具栏设置入口置于末尾，保留日常筛选的位置。

第三轮结果为 `m5b-iphone3.xcresult` / `m5b-ipad3.xcresult`，选择完整 `DsmMobileTests` 与五项设置 UI。最终模型含“已确认保存后附加刷新失败”回归，两端各 1199 项单元、各 3 条既有条件跳过、0 失败（iPhone 28.002 秒，iPad 27.980 秒）。iPad 五项 UI 全通过，273.831 秒；iPhone 四项通过，唯一横屏大字滚动定位失败，五项共 365.818 秒。录像显示测试快速滑动反复越过目标，已调整为按目标距离的小幅慢速拖动、停稳，并只采用当前设置页导航栏计算可见区域，保留目标必须进入可见区域的断言。

第四轮只选择 `-only-testing:DsmMobileUITests/MobileDownloadSettingsUITests/test中文深色大字设置与保存结果支持横屏`，结果为 `m5b-iphone4.xcresult` / `m5b-ipad4.xcresult`。两端各 1 项通过、0 失败，iPhone 67.599 秒、iPad 61.084 秒。最终模型对应的两端完整单元均为 1199 项；五项设置 UI 在两端均有通过记录，其中 iPhone 横屏由该聚焦复验收口，不将第三轮描述为全部通过。设置 UI 覆盖默认目录和两分区保存/关闭再开、未知重启后只读/显式继续、中文深色最大字号与旋转、只读/空字段、加载/错误恢复；原搜索/筛选和多选控制已有通过证据。

已查看 iPhone 第一轮大字表单、iPad 第二轮浅色保存/未知分步结果，最终两端中文深色横屏结果均可阅读“常规/下载计划”及各自“已保存”。所有截图和网络响应均为合成数据。最终 XcodeGen 重生成一致（SHA-256 `985e162fe1cddb3123b4091d39d73d823c5c9e1dff6dc0d4d425e427f32bca67`）；本地化 6151 / 2188 / 3402、175 个请求 fixture、1 个结果示例、29 组脱敏 fixture / 48 项私有引用、生成参数目录、严格文档及差异检查通过。

`PENDING_USER_VALIDATION`：两种真机、记录 DSM/Download Station 版本、专用测试 NAS 与可丢弃下载/目录，保存原设置以便恢复；验证管理员的实际默认目录/限速/eMule/自动解压/计划开关、普通账号只读、目的地权限与新建/继续的 HTTP/FTP 限速生效。中途断网、终止、重连、切账号、其他客户端并发修改或撤销权限，预期未改字段不覆盖、未知不重发、已完成不重复、剩余明确继续/取消且取消持久保存。补验锁屏文件保护、VoiceOver、键盘、大字和分屏，只回传版本、权限类别、脱敏步骤与错误类别。真实 NAS 未由 Agent 改动；没有将尚无接口的每周时段编辑伪装为待真机。继续 M5c/M5d 和 M6–M8。

## 2026-10-05 移动 M5c1 下载保存位置编辑与恢复

基线为 `78598ffc`。新增官方 Task.edit v2、严格逐项结果与保存位置回读；移动单项/多项编辑使用现有文件夹选择器、保存按钮及逐项记录，未知只查询，未开始部分明确继续/取消。同任务编辑、控制与移除互相保护；写前持久化失败零请求，表单与文件夹回调冻结连接实例。独立恢复文件只存上下文、任务身份摘要、原/目标位置和阶段，保留原子写、完整文件保护与排除备份。Mac UI 和旧方法签名保持，Windows/Android 只登记影响。真实 NAS 未参与自动写测试，保存位置变化不证明文件已搬迁。

实际验证：

- `swift test --package-path apple --jobs 2 --filter DownloadStationControlRecoveryTests`：7 项通过；`--filter DownloadTaskDestinationTests`：新增 10 项通过（0.047 秒）。覆盖固定 v2、原值/对象变化、逐项错误及 405/402 区分、畸形/重复/错编号结果、写前保存/取消、未知只读、跨动作保护和在途重复。
- `swift test --package-path apple --jobs 2`：2678 项 XCTest，172 条既有条件跳过，0 失败，33.390 秒；12 项 Swift Testing 全通过，0.032 秒。共享与 Mac 源码回归不替代目标构建。
- 锁定 XcodeGen 2.46.0：`/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml`；只生成五个新移动源/测试文件的工程引用。`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：第 1、2、3 轮均通过。第 2 轮包含冻结编辑草稿连接实例，第 3 轮补详情保存位置的无障碍标识与测试定位修正。
- R1 两端分别运行 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<设备编号>' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadEditUITests -only-testing:DsmMobileUITests/MobileDownloadControlUITests/test多选暂停与继续分别处理符合状态的任务 -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m5c1-<iphone或ipad>1.xcresult`；iPhone 编号见构建命令，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。
- R1 两端各 1211 项单元（各 3 条既有条件跳过），新增 `MobileDownloadEditTests` 12 项均通过；iPad 总计零失败（28.584 秒），iPhone 在既有 `MobileChatRealtimeTests/test停止前台会取消未完成刷新且旧事件不再读取` 有 1 项失败（总计 29.018 秒），停止后读取计数从 1 变 2。未降低断言或据此改动聊天代码。
- R1 新 6 项 UI：iPhone 5 通过、1 失败（276.202 秒），iPad 4 通过、2 失败（295.803 秒）。两端中文深色最大字号/横屏、逐项权限拒绝、未知重启后显式继续、取消剩余并重启清理均通过；旧多选暂停/继续回归分别通过，39.626 / 46.524 秒。首轮先改测试为等待控件后定位实际按钮，并按详情保存位置标识断言完整值。R2 仍复现后检查实际辅助功能层次：iPad 任务行中心位于内容空白处，点击未打开详情，补上按钮标签内部的整行点击区域；iPhone 详情位置在列表下方，测试必须滚动后再检查完整值。未删除保存结果或禁用能力断言。
- R2 在上述 `test-without-building` 命令中选择单项编辑 UI（两端）、不支持编辑 UI（iPad）及既有聊天停止测试（iPhone），结果目录为 `m5c1-<iphone或ipad>2.xcresult`。聊天单项通过（0.125 秒），不能据此声称首轮完整零失败；单项 UI 仍失败，iPad 不支持入口测试仍因任务行未打开失败。继续修正整行点击区域与详情滚动定位，不用重试成功掩盖已复现的问题。
- 第 4 轮移动构建通过后，R3 两端选择单项保存与不支持编辑两项 UI，iPhone 另选完整 `DsmMobileTests`，结果为 `m5c1-<iphone或ipad>3.xcresult`。iPhone 完整 1211 项、3 条既有条件跳过、0 失败（29.190 秒），既有聊天停止测试也通过。不支持编辑 UI 两端通过（23.125 / 27.492 秒），验证整行点击确实打开详情；单项保存后详情定位仍失败（129.615 / 139.230 秒）。检查发现标识误加到同名的新建任务位置字段，已将标识移至任务详情字段；保存与回读断言不变。第 5 轮构建通过，按修复范围只复验两端单项保存 UI。
- R4 仅选择 `-only-testing:DsmMobileUITests/MobileDownloadEditUITests/test单任务选择文件夹保存后详情显示新位置`，两端各 1 项通过、0 失败（47.394 / 56.197 秒），结果为 `m5c1-<iphone或ipad>4.xcresult`。六项新 UI 在两端均有通过记录；不将早期失败轮次写成全部通过。最终完整单元为 iPhone R3 / iPad R1，各 1211 项、3 条既有条件跳过、0 失败。工程重生成一致，SHA-256 为 `ab73a3084d1f013b8147ec25f420a70720fc769e5a32353b2c5330dae32274c3`。
- `xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build` 通过；`lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 返回 `x86_64 arm64`，未安装或启动 Mac 包。
- `python3 tools/localization/check_localization.py`：Apple 6162 / Android 2188 / Windows 3402，双语、变量及硬编码检查通过；`python3 tools/request-contract/validate_contracts.py`：175 个请求样本、1 个写结果示例通过；`python3 tools/contract-validation/validate_fixtures.py`：29 组样本和 48 项私有 API 文档引用通过；`python3 tools/codex/generate_api_reference.py --check`、`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。

另行完成当前负责人的只读集成与对抗复核，并修复编辑草稿在账号切换/重连后可能重绑新实例的问题；这不是另一模型审查。检查源对象、目录、账号与原值、未知只读、损坏记录不覆盖、同账号旧请求仍在途及取消持久化。实际查看 iPhone 中文深色大字表单与浅色部分失败、iPad 中文横屏结果截图；都保留清楚的目标位置、逐项结果和恢复操作。系统 VoiceOver、键盘、锁屏保护及真实 NAS 的目录权限/任务状态/文件行为仍按移动主计划 M5c1 的具体 `PENDING_USER_VALIDATION` 执行，不能据合成测试宣布真实 NAS 行为通过。

上个提交 `78598ffc` 的云端文档与 Repository Check 已通过；Android Build [37247498048](https://github.com/yuangy1995/dsm-native-client/actions/runs/37247498048) 仍是既有 `ChatPollRepositoryTest.无附件投票固定v1且写后回读` 失败（1436 项中 1 项），本波没有修改 Android 或放宽共享样本。Apple Build 当时仍在运行，不将代码推送等同全部门禁通过。创建持久恢复、RSS 与 M5d–M8 继续实施，不以本切片宣告整个 M5 完成。

## 2026-10-05 移动 M5c2 下载创建回执与持久记录

基线为 `97c60331`。官方链接创建固定 Task v3，文件按目录使用 v1/v2；仅创建允许成功无 data，普通读取仍严格要求 data。移动创建复用原请求方法，增加写前来源/请求摘要和成功回执保存；已添加不表示已完成下载。文件依据实际内容防重，原始链接、文件名、内容与凭据不进入恢复 JSON。同来源未知跨重启、改名或换目录不重发；当前列表有同名/同链接任务也不认领。链接、搜索结果和任务文件共用创建模型；文件在受保护副本中完成当次发送并清理。Mac 旧 void 创建签名与共享旧任务回读方法保持，Windows/Android 仅登记差异；旧 Android v2 链接样本保留为 sourceReviewed，另建官方 v3 样本。

当前负责人分离执行只读集成与对抗复核，未声称另一模型参与：检查 API 版本/无 data 边界、写前失败、成功回执保存失败、未知相同来源、在途重连/换账号、文件内容摘要、临时副本及存储损坏。复核把输入副本改为创建时即指定完整保护再写内容，并给 iOS 上传正文同样的保护；文件成功字段必须是布尔值，缺二进制上传能力在写前拒绝。损坏记录仍保留，但独立清理已经不在使用的专用输入副本。无真实 NAS 自动写测试、身份/签名权限变更、依赖升级或正式发布。

实际命令及已获得结果（专用临时目录中 `m5c2-*` 日志/结果包，不提交）：

- `swift test --package-path apple --jobs 2 --filter DsmServiceManagementRepositoryTests`：150 项通过，0.162 秒。
- `swift test --package-path apple --jobs 2 --filter DownloadCreationReceiptTests`：第一轮测试闭包捕获非 Sendable XCTestCase 编译失败，改为捕获提前建立的 Repository/请求后，第二轮 9 项通过，0.053 秒。增加上传类型/能力检查后的共享完整 `swift test --package-path apple --jobs 2`：2688 项 XCTest、172 条既有条件跳过、0 失败，34.709 秒；12 项 Swift Testing 通过，0.051 秒；新增创建回执行为共 10 项。
- `/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml`；`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`：第 1、2 轮通过。第 2 轮生成工程摘要为 `ceb698e277c8293048900a9d2469a426fb43ef4a6619129611b381699acb3ef3`。
- 第一轮移动聚焦：`xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<编号>' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileDownloadCreationTests -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m5c2-<iphone或ipad>-focus1.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。iPhone 编号见构建，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`；两端各 11 项通过，0.232 / 0.228 秒。
- R1 使用同一 `test-without-building` 命令，选择 `-only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadCreationUITests -only-testing:DsmMobileUITests/MobileDownloadEditUITests/test单任务选择文件夹保存后详情显示新位置`，结果包为 `m5c2-<iphone或ipad>1.xcresult`。两端各 1222 项单元、3 条既有条件跳过；iPhone 2 条断言失败（31.250 秒），iPad 5 条断言失败（31.434 秒）。两端新增的输入/发送副本保护属性检查失败；iPad 另在既有聊天合并刷新测试发生 3 条断言失败，未改变聊天源码或放宽其断言。
- 本机模拟器的独立系统保护写入不返回属性，现有 Chat/Photos 三项设备条件测试也记录这一限制。文件业务测试继续覆盖复制内容、防重、清理和账号边界；新增独立保护测试只在实际系统支持时断言输入及上传副本均为完整保护。模拟器明确记录 `PENDING_USER_VALIDATION`，不能计作保护验证通过；属性返回按 Foundation 的 String 原值读取。
- R1 创建 UI 四项：iPhone 3 通过、1 失败（238.899 秒），iPad 2 通过、2 失败（240.023 秒）。两端空成功回执/列表/重启/清理与权限拒绝通过；iPhone 中文深色大字/横屏通过，iPad 该项取到弹窗后方复用的同名反馈，实际录像中前景结果可读。测试改为限定当前表单；未知重启测试进入记录详情后误找根页关闭按钮，改为按原生返回再关闭，没有删除未知状态、禁止清除或相同来源不能重发的断言。原单项保存位置 UI 两端通过（56.943 / 98.772 秒）。
- 第 3、4 轮移动构建通过。关闭创建结果改用“关闭”，表单反馈发生变化时自动定位结果，提交时收起键盘；系统文件导入复用同一结果表单，空目录也能看到结果。R2 选择新增 `MobileDownloadCreationTests` 以及前轮失败的未知重启、中文大字/横屏两项 UI（两端），结果包为 `m5c2-<iphone或ipad>2.xcresult`；两端各 12 项聚焦单元、1 条明确系统条件跳过、0 失败（0.289 / 0.268 秒），其余 UI 结果继续记录。
- `xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build` 通过；随后使用 `lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 返回 `x86_64 arm64`，未安装或启动 Mac App。

R2 两项实际 UI 两端均通过、0 失败：iPhone 134.749 秒，iPad 128.129 秒。四项新 UI 均有两端通过证据，未知重启流程包含列表已有新任务仍不认领、只读刷新、不能清除及相同来源仍受保护。不是将 R1 失败轮次改写为通过。

R3 在同一测试命令中只选择 `-only-testing:DsmMobileTests`，结果为 `m5c2-iphone3.xcresult` / `m5c2-ipad3.xcresult`。两端各 1223 项、各 4 条明确设备条件跳过、0 失败，29.796 / 29.798 秒；既有聊天合并刷新测试两端均通过，未修改该测试或聊天实现，R1 失败仍保留。本次新增 11 项业务测试全部执行；第 12 项系统保护测试通过独立系统写入探针明确说明模拟器条件限制，不能以其他平台或静态声明代替真机保护验收。

已查看 iPhone 中文深色最大字号表单、iPad 浅色未知记录及最终中文横屏已添加记录，内容和恢复入口可读。`python3 tools/localization/check_localization.py`（6165 / 2188 / 3402）、`python3 tools/request-contract/validate_contracts.py`（176 个请求、1 个结果示例）、`python3 tools/contract-validation/validate_fixtures.py`（29 组、48 项私有引用）、`python3 tools/codex/generate_api_reference.py --check`、严格文档预检与 `git diff --check` 通过。官方新请求样本遵循占位符脱敏规则，实际调用测试按占位符映射严格比较请求；没有放宽校验器。

具体真实设备/NAS 步骤见移动计划 M5c2 的 `PENDING_USER_VALIDATION`，包括真实提供者、文件保护、当前套件无 data 成功、断网/终止/账号边界。逐次创建目录、文件密码及 BT 搜索转入同一表单继续 M5c2b，RSS 继续 M5c3；这些仍是源码工作，不归入设备待验。没有自动写 NAS 或替换用户资料。

补核 Mac 实际调用后，仅新增旧 void 签名的 v3/空成功回执行为测试，生产源码未再改动；`swift test --package-path apple --jobs 2 --filter DownloadCreationReceiptTests` 最后一轮 11 项通过、0 失败，0.084 秒。前述完整共享 2688 项是新增该项测试前的准确数量，不把聚焦复验改写成再次完整运行。XcodeGen 最终工程摘要保持 `ceb698e277c8293048900a9d2469a426fb43ef4a6619129611b381699acb3ef3`。


## 2026-10-05 移动 M5c2b 创建目录、文件密码与统一表单

基线为 `5852841b`。链接、任务文件和 BT 搜索结果统一进入原生创建表单，用户选择保存位置或使用 NAS 默认目录，文件可填写解压密码，明确提交才创建。表单与目录/系统文件回调冻结连接，同账号重连也使旧草稿失效；取消草稿不写 NAS。复用 M5c2 写前记录/回执/来源摘要，不改变持久结构。共享 Result 创建与文件正文保留目录和密码空格，空字符串才表示省略；带边缘换行/空字符的密码不能被修剪后发送。未知同内容文件更换目录/密码仍禁止重发，记录没有原始密码、目录、文件名或正文。

当前负责人分离执行只读集成和对抗复核：检查旧连接草稿、参数原值、秘密/临时副本、写前零请求、未知防重、缺 File Station 权限时默认位置仍可用，以及选择文件不立即提交。将 BT 按钮辅助标识改为列表序号，避免完整下载 URI 进入标识；不可读取文件提示重新选择，真正的系统选取错误显示恢复提示，普通取消不显示失败。Mac App/Android/Windows 源码未改，不改变权限、签名、身份、工具链或持久格式；没有真实 NAS 自动写入。这不是另一模型审查。

实际命令与结果，专用临时目录为 `/tmp/lanstash-release-1.0.15.1x6wUX`，本切片日志/结果包使用 `m5c2b-` 前缀：

- `swift test --package-path apple --jobs 2 --filter DownloadCreationReceiptTests`：13 项、0 失败，0.061 秒，覆盖 URI 目录原值、文件目录/密码原值及全空格密码、非法密码零请求，以及既有回执/防重/取消。
- `swift test --package-path apple --jobs 2`：2691 项 XCTest，172 条既有条件跳过、0 失败，35.904 秒；12 项 Swift Testing 全通过，0.036 秒。最终短文案另由资源检查、目标构建与对应 UI 复验，不把聚焦验证写成再次完整运行。
- `/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml`，沿用锁定 2.46.0，只增加统一表单的工程引用。移动第 1–8 轮 `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing` 均通过；中间轮次分别纳入正式测试、辅助标识和错误/文案修正。
- 两端完整单元命令：`xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination id=<编号> -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/m5c2b-<iphone或ipad>-units<轮次>.xcresult -only-testing:DsmMobileTests test-without-building`。iPhone 编号见构建，iPad 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，均为 iOS 26.5 模拟器。
- 单元 R1 两端各 1227 项、4 条明确设备条件跳过；两端同一旧静态检查有 3 条断言失败，因表单移至新文件及移除已过时的默认目录教学提示，29.887 / 29.677 秒。把字段无障碍/目的地标签/提交期间关闭限制断言移至实际新表单；保留并补充选择文件/搜索不立即提交、SecureField、旧连接拒绝和不进入界面持久属性的检查，没有删除业务安全断言。
- 单元 R2 两端各 1229 项、4 条明确设备条件跳过、0 失败，30.430 / 30.472 秒；新增不可读取文件零创建、搜索畸形结果显示搜索恢复文案的行为用例。创建测试共 18 项，其中 1 条为既有设备文件保护条件跳过，其余全部执行。
- 界面 R1 使用同一 `test-without-building` 命令，改为 `-only-testing:DsmMobileUITests/MobileDownloadCreationUITests`，结果包 `m5c2b-<iphone或ipad>-ui1.xcresult`。各 8 项，iPhone 4 失败、iPad 3 失败，547.314 / 546.080 秒；四项旧创建/恢复/权限/中文用例中，两端成功回执、未知重启及权限拒绝均通过，中文仅 iPad 通过。新文件表单两端通过，验证取消零创建、SecureField、目录和带前后空格密码经实际受保护副本及二进制上传链路发送；预选输入仅替代系统提供者选取，不能据此声称系统文件选取已经通过。
- R1 失败逐项诊断：BT 合成数据把大小写为字符串，实际 BT 契约为数字，修正 fixture 而非放宽解析；移动收到无效搜索结果时原先引用不相关的上传错误，现使用已有搜索重试文案。原生选择器跟随系统语言，取消实际为“取消”；测试接纳系统双语并验证面板关闭。新任务详情的保存位置在滚动列表下方，测试限定详情并滚动后再查值；中文 iPhone 在空输入框前反向滚动拖动了 sheet，按实际输入→选目录→提交顺序验证。搜索提交主动收起键盘，最大字号默认位置按钮缩短，工具栏保持文字固有宽度。
- `xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build`：共享源码及最终资源后的两轮均通过；`lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 两次均返回 `x86_64 arm64`，未安装或启动 Mac App。
- `python3 tools/localization/check_localization.py` 最终 Apple 6166 / Android 2188 / Windows 3402，双语、变量、引用及硬编码扫描通过；`python3 tools/request-contract/validate_contracts.py` 176 请求/1 结果、`python3 tools/contract-validation/validate_fixtures.py` 29 组/48 私有引用及严格文档预检通过。本切片只明确已有参数原值和交互，不增加 NAS 请求字段或接口。

界面 R2 采用上述测试命令，选择 `MobileDownloadCreationUITests` 的 `testBT搜索结果先进入统一表单且可取消后再选择目录添加`、`test中文深色大字创建结果和横屏记录可以阅读`、`test系统文件选择器取消不创建下载`、`test链接草稿取消不添加且目录可恢复默认再选择提交`、`test预选任务文件表单取消不上传且密码目录通过真实二进制链路提交` 五个方法，结果包为 `m5c2b-<iphone或ipad>-ui2.xcresult`。两端各 5 项全部通过，314.564 / 312.422 秒；最终所选断言仍核对精确保存位置、取消零创建、密码原值经真实二进制链路及结果状态，未降低断言。八项 UI 都有两端通过证据，保留首轮失败记录。

最终截图复核确认中文最大字号的目录、恢复默认及提交入口均可读；iPad 英文取消按钮仍被外层自定义框架裁切，改用项目已有原生工具栏布局。第 9 轮构建通过；R3 仅选择 `-only-testing:DsmMobileUITests/MobileDownloadCreationUITests/test预选任务文件表单取消不上传且密码目录通过真实二进制链路提交`，结果为 `m5c2b-<iphone或ipad>-ui3.xcresult`，两端各 1 项通过、零失败，58.069 / 55.017 秒。再次查看两端最终截图，取消和提交按钮完整显示，密码输入属于系统安全字段。最终重生成工程一致，SHA-256 为 `fd61c7073c5cb2c6bc0b8205d9bf01459b5078c2bee7ed2371a402a0b40b7648`。真实提供者选取（区别于已验证的系统选择器打开/取消）、锁屏、VoiceOver、外接键盘及真实 Download Station 参数处理继续单独设备验收，不与预选合成输入混同。

远端操作前 `git fetch origin main` 返回主分支与 `5852841b` 相同、0/0。该提交的文档与 Repository Check 已通过；[Android Build 37252437372](https://github.com/yuangy1995/dsm-native-client/actions/runs/37252437372) 仍为既有 `ChatPollRepositoryTest.无附件投票固定v1且写后回读` 在 1436 项中 1 项失败，本轮不改变 Android 范围或断言。Apple 云端 `97c60331` 尚在运行，`5852841b` 尚排队，不能据本机结果声称云端全部通过。


## 2026-10-05 Apple CI 历史测试与原生入口修复

基线 `338c15b3`；按用户反馈单独修复 Apple CI，M5c3 RSS 的并行工作区改动不计入本次 CI 提交。已读取 [Apple Build 37219220810](https://github.com/yuangy1995/dsm-native-client/actions/runs/37219220810) 的失败日志和两端测试结果：共享包及构建通过，两端各 1044 项单元（各 1 条既有条件跳过）通过；各 185 项 UI 中 iPhone 24 项、iPad 37 项失败，合计 41 个不同场景。更早的 37215284233 具有相同主要失败群；后续尚未完成的云端运行不能视为绿色。

旧测试与产品缺陷分别处理：

- 文件动作使用系统工具栏溢出菜单，测试先打开实际“更多”菜单；分享结果严格查找当前文件及完成状态，纠正旧断言误用另一文件夹名称。系统分享面板按实际标题/副标题查找文件名，系统搜索关闭接纳系统中英语言。表单开关滚动到 sheet 内的实际可见区域后点击并核对值；拖放在目标处停留，聊天菜单从菜单外关闭，避免窗口中心误选转发。业务结果、危险操作确认及恢复断言保留。
- iPad 文件浏览工具栏被检查器遮蔽，操作栏移至检查器外侧；系统搜索改位置后仍不可见，因此文件模块统一持有原查询绑定，宽屏改用与照片页一致的原生输入栏，窄屏保留系统搜索。键盘提交、按钮提交与清除仍使用同一浏览模型；侧栏行补足整行触控范围。Office 检查器内没有导航工具栏，编辑入口放入已有底部操作区，紧凑宽度/全屏沿用原导航栏。产品变更仅限上述实际入口和点击范围，不变更 API、权限、签名或存储。
- 共享完整回归发现 Mac 缩略图测试依赖固定 10/30 毫秒睡眠，机器繁忙时预取尚未开始。仅修改 `PhotoLibraryModelTests.swift`：等待实际请求事件，用测试控制的暂停点确认取消，再保留精确请求顺序断言；不改 macOS 产品源码。
- 工作流按共享/macOS、iPhone、iPad 分三组，移动端分别运行全部单元和 UI；每组在当前锁定 Xcode 中选择最新可用 iOS runtime，显式启动，构建一次再执行。保留原 `test-and-build` 汇总检查，只有全部组成功才通过；同分支新提交取消过期运行，不把取消算成功。Xcode/XcodeGen、运行器、测试断言和正式发布门禁没有降低。

实际验证使用 Xcode 26.5 / iOS 26.5 的 iPhone 17 Pro（`8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`）及 iPad Air 11-inch M4（`A31ABDE2-186F-43DD-8D40-5EB9511A9289`）。云端继续沿用既有锁定 Xcode 26.6，不能将本机环境写成云端结果。临时日志/结果包前缀 `apple-ci-`，目录 `/tmp/lanstash-release-1.0.15.1x6wUX`。

- 第一轮原样复现文件批量复制两端失败；工具栏修复后两端分别 29.206 / 25.468 秒通过。搜索 iPhone 通过、iPad 仍失败，继续核对原生入口。
- 41 场景回归命令为 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<编号>' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileUITests/<类>/<方法> -resultBundlePath /tmp/lanstash-release-1.0.15.1x6wUX/apple-ci-<iphone或ipad>-affected1.xcresult`，为每个去重失败方法传一条选择项。iPhone R1 为 41 项、38 通过、3 失败；三项是本轮批量替换错误影响复制冲突/删除/恢复断言，已在源码恢复原断言，后续复跑独立记录，不将该轮改写为通过。iPad R1 为 41 项、35 通过、6 失败，1952.643 秒；另三项为 Office 编辑入口、搜索和权限表单定位。iPhone R1 为 1399.826 秒。
- `swift test --package-path apple --jobs 2` 第一轮含当前工作区 RSS 增量，共 2702 项 XCTest、172 条既有条件跳过、1 失败，58.197 秒；失败是上面的 Mac 预取时序。修改后 `swift test --package-path apple --jobs 2 --filter PhotoLibraryModelTests` 13 项、0 失败，0.596 秒；12 项 Swift Testing 第一轮通过。修正后的第二轮完整共享回归为 2702 项 XCTest、172 条既有条件跳过、0 失败，54.788 秒；12 项 Swift Testing 通过，0.612 秒。
- 工作流全部 13 段运行脚本通过 `bash -n`；YAML 解析通过。提取模拟器选择脚本，以新旧 runtime、首选机型和缺失机型的合成清单执行，确认最新 runtime 优先且缺目标设备必须失败。`python3 -m unittest discover -s tools/release -p 'test_*.py'` 32 项通过，5.931 秒。
- 以 `git archive HEAD apple` 建立独立临时候选，只覆盖 CI 涉及的移动源文件/测试，锁定 XcodeGen 2.46.0 重生成后工程与原提交完全一致，SHA-256 `fd61c7073c5cb2c6bc0b8205d9bf01459b5078c2bee7ed2371a402a0b40b7648`。RSS 新文件的工程引用不混入 CI 提交；没有建立验证分支。

后续复验继续使用上述 `test-without-building` 命令；R2/R4/R5 的构建目录改为 `apple/Apps/DsmMobile/build/m5c3-ci`，最终 R6 回到 `apple/Apps/DsmMobile/build/m0-m8`。只改变明确列出的选择项与结果包名称，没有降低业务断言：

- 构建第 1–3 轮通过。第 4 轮加入尚未提交的 RSS 测试后，因测试尝试修改不可变 `NasProfile.usernameHint` 编译失败，改为构造相同 UUID 的新账号配置；第 5–9 轮构建均通过。构建统一使用 `xcodebuild build-for-testing`、`-sdk iphonesimulator`、上述 iPhone 目标、对应构建目录、`-jobs 2` 或 `-jobs 4`、`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。
- R2 选择全部 `DsmMobileTests`，以及 `MobileWorkspaceUITests` 的 Office 系统分享/选择器、批量删除、复制同名冲突、批量恢复、文件搜索、照片文件夹覆盖子目录确认六项。两端各 1240 项单元（包含当前工作区 11 项 RSS 测试）、各 4 条既有设备条件跳过、0 失败，38.866 / 32.201 秒。六项 UI：iPhone 全通过（171.634 秒），iPad 4 通过、2 失败（278.813 秒）；剩余是搜索和权限表单。
- iPad 搜索仅修改原生 placement 的 R3 单项仍失败；将搜索移至模块层的 R4，iPhone 搜索/权限两项通过（59.955 秒），iPad 搜索仍失败、权限已通过（69.031 秒）。权限录像证明最后一行开关已经可见，原测试误取后方侧栏，随后又把弹窗底部 55 点都排除；现明确选择包含开关的表单，以实际可见边界和可点击状态定位，并保留开关值与风险确认断言。iPad 在 R3 前重启测试模拟器，清理已退出系统面板留下的无障碍服务状态，不清空数据或跳过用例。
- R5 使用全部单元及 Office、批量复制、文件搜索、跨 NAS 复制/移动确认四项 UI。两端各 1240 项单元、4 条原设备条件跳过、0 失败，30.992 / 31.232 秒；iPhone 四项通过（104.643 秒），iPad 另三项通过、搜索因普通 TextField 误使用 search 类型提交事件而失败（116.649 秒），已接回原生文本提交事件。没有用只点按钮来绕过键盘提交断言。
- R6 选择 `DsmMobileTests/MobileFileBrowserPresentationTests`，以及 `MobileWorkspaceUITests/test文件搜索无结果保持筛选状态`、`test文件搜索中文深色大字号仍可输入与清除`。两端各 9 项聚焦单元通过（0.109 / 0.101 秒），两项实际 UI 全通过、0 失败（32.223 / 41.248 秒）。宽屏同时验证输入、空结果、清除后恢复原目录；两端英文浅色与中文深色最大辅助字号截图已检查。
- 41 个不同历史失败场景均已有两端通过记录，保留上述中间失败。分轮通过不等于一次完整 UI 套件通过；云端仍运行所有用例。当前负责人另行完成只读集成复核：检查导航与活动页、Office 原账号/原文件边界、搜索绑定与清除、表单目标、所有旧断言恢复、无新增跳过，以及矩阵失败汇总。这不是另一模型审查。
- 最终共享完整 `swift test --package-path apple --jobs 2`：2702 项 XCTest、172 条既有条件跳过、0 失败，44.437 秒；12 项 Swift Testing 通过。RSS 增量仍不在 CI 提交中。Mac Release 双架构两轮构建均通过，`lipo -archs` 为 `x86_64 arm64`；未安装或启动 App。最终本地化完整性/硬编码扫描（6196 / 2188 / 3402）、严格文档检查与 `git diff --check` 通过。

本机修复与分轮回归已完成，云端绿色须等对应提交的全部矩阵完成后单独确认。此次合成测试不写真实 NAS，不代表系统文件提供者、实际 VoiceOver 或真实数据操作已验收。


## 2026-10-05 移动 M5c3 RSS 订阅与更新恢复

RSS 实施基线为 `338c15b3`；期间 Apple CI 的独立修复已提交/推送 `09a1deda`。公开 Site.list/refresh、Feed.list v1 接入既有订阅/条目、搜索、明确更新及统一创建表单；不自动访问订阅来源，也不新增订阅/删除/自动规则接口。更新记录只保存账号/站点身份摘要、原日期、时间和阶段，不保存地址、所有者、条目正文或凭据。接受回执与当前内容分开，未知重启只读；原站点日期前进且更新结束才结束记录，同编号替换或缺失不认作原更新完成。条目创建仍走 M5c2/b 同一来源防重与目录表单。

当前负责人另行执行只读集成和对抗复核（非另一模型），核对公开文档中的 site/sites 差异、必需 id、数字/字符串类型、完整分页、旧对象/账号/连接、写前保存、权限拒绝、未知恢复及旧页面草稿。复核补齐冻结创建/更新连接、按原来源匹配回读，以及读取权限与更新权限的不同恢复提示；不把模拟器或合成 API 提升为真实 NAS 行为证据。Mac App、Windows/Android 源码未改，五端影响写入 API 参考与平台矩阵。

实际验证沿用 Xcode 26.5 / iOS 26.5、iPhone `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`、iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，专用临时目录 `/tmp/lanstash-release-1.0.15.1x6wUX`：

- `swift test --package-path apple --jobs 2 --filter DownloadStationRSSTests`：10 项、0 失败，0.108 秒。覆盖官方两种容器、分页稳定/重复、Feed 字节字符串、更新空回执、未知防重、原站点变化、写前失败/取消、权限及版本。
- `swift test --package-path apple --jobs 2 --filter RequestFixtureContractTests/testRSS`：1 项、0 失败，1.048 秒；真实 Repository 的读取、写前重读、刷新及回读按新增三个官方请求样本严格比较。
- 全部移动单元使用 `xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<编号>' -derivedDataPath apple/Apps/DsmMobile/build/m5c3-ci -parallel-testing-enabled NO -only-testing:DsmMobileTests`，实际结果包同 CI 修复 R2/R5。最新两端各 1240 项、各 4 条既有设备条件跳过、0 失败，30.992 / 31.232 秒；11 项新增 RSS 行为全部执行，涵盖回执不等于完成、重启只读、替换/缺失、实际拒绝、同账号重连/跨账号迟到、记录秘密排除、损坏及写失败。
- 最终共享 `swift test --package-path apple --jobs 2`：2702 项 XCTest、172 条既有条件跳过、0 失败，44.437 秒；12 项 Swift Testing 通过（0.040 秒）。第一轮 Mac 预取时序失败及修复证据见前一节，没有删除或跳过该断言。
- `xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build` 两轮通过；最后 `lipo -archs` 为 `x86_64 arm64`。没有安装或启动 Mac App。
- 移动由锁定 XcodeGen 2.46.0 生成五个 RSS 文件的工程引用，并用 `xcodebuild build-for-testing`、上述 iPhone 目标、`-sdk iphonesimulator`、`-jobs 2` 或 `-jobs 4`、`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 构建。中间第 4 轮的不可变 NasProfile 测试构造错误已记录在 CI 节；RSS 最终第 10–12 轮构建均通过，没有手改生成工程。
- RSS UI 统一使用上述 `test-without-building`，选择 `-only-testing:DsmMobileUITests/MobileDownloadRSSUITests`，结果包为 `m5c3-<iphone或ipad>-ui<轮次>.xcresult`。R1 仅 iPhone 六项：5 通过、1 失败，369.584 秒；误选后方下载页搜索框。R2 两端各六项、各 5 通过/1 失败，342.501 / 316.186 秒；iPad 实际面板没有系统搜索入口，iPhone 清除后键盘仍遮住列表。R3 仅中文大字项，两端仍失败（58.682 / 38.358 秒），保留失败。
- 产品搜索改用面板顶部的原生 TextField，与当前列表绑定；键盘提交/清除后失去焦点，根页加载/空/错误在剩余区域居中。R4 重新跑全部六项，iPad 6 通过（344.637 秒），iPhone 5 通过/1 失败（339.492 秒）；后者已完成搜索与取消创建，但默认向下滑动在横屏误拉下整张 sheet。测试改为依据固定搜索栏与列表交集，在实际内容区域内拖动，保留原筛选、取消零创建和横屏按钮可触达断言。
- R5 仅选择 `MobileDownloadRSSUITests/test中文深色大字筛选条目与取消创建支持横屏`；使用 `build/m5c3-ci`，两端分别通过（59.855 / 66.425 秒），零失败。其余五项已在最终产品布局的 R4 执行。六个场景均有两端通过证据：统一创建/更新、接受后重启防重、未知后只读恢复、中文深色最大字号/横屏、加载/空/错误/不支持、空条目与权限拒绝。
- `python3 tools/localization/check_localization.py`：6196 / 2188 / 3402；`python3 tools/request-contract/validate_contracts.py`：179 个请求、1 个结果样本；`python3 tools/contract-validation/validate_fixtures.py`：29 组、48 项私有引用；`python3 tools/codex/generate_api_reference.py --check` 均通过。新增均为脱敏公开 API 样本，未放宽既有校验器。

具体真实设备/NAS 步骤见移动计划 M5c3 的 `PENDING_USER_VALIDATION`。真实来源读取、NAS 自动规则副作用、权限处理、文件保护与辅助功能仍需设备验收；Agent 未自动操作 NAS。Apple CI `09a1deda` 的 [37261490138](https://github.com/yuangy1995/dsm-native-client/actions/runs/37261490138) 已启动三个独立组，编译/测试仍进行时不能宣称绿色。旧七轮同分支运行（37255101279、37252437350、37249915372、37247498063、37244540417、37242202366、37238872718）已请求取消，避免过期提交重复占用资源；取消不是通过。M5d 仍需开发，用户已要求 M5 完成后暂停原目标并另开会话接续 M6–M8。

## 2026-10-05 移动 M5d 任务移除与文件边界

基线 `214e87d5`。共享新增冻结任务编号/名称/大小/位置摘要的 `DownloadTaskRemoval`，公开 Task.delete/list 固定 v1，逐项回执、完整清单回读、写前保存回调及同任务控制/编辑/移除互斥。旧 void 控制也拒绝未记录的 finish 方法；停止做种沿用 pause/paused，继续沿用 resume。Mac App、Windows/Android 源码未改，不从任务消失推断文件移动或删除。

移动单项和多项使用同一 `removals-v1.json` 队列，提交未知只查询，未开始项明确继续/取消，取消立即保存。原单项内存删除流程及 23 个失效文案删除；本次确认中的名称保留在视图内，恢复文件不保存名称、路径正文、URI 或凭据，重启后仅从当前匹配任务恢复名称。两个危险选项分别说明未完成进度和未完成文件的风险；File Station 入口由用户选择真实对象，不能根据管理员可见下载任务的 destination 猜测文件归属或自动删除。

当前负责人另行执行只读集成与对抗复核（非另一模型）：检查写前目标/位置、写前持久保存、未知/损坏、分页中断、重复与跨动作互斥、取消、同账号重连及跨账号迟到。发现移除成功后的旧详情仍可能提供暂停操作，已要求当前任务存在才开放控制、清理旧控制反馈并显示任务已移除。没有削弱旧业务断言，历史单项删除和迟到列表测试迁入真实 Repository 的合成网络链路。

环境为 Xcode 26.5 / iOS 26.5、锁定 XcodeGen 2.46.0；iPhone `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`、iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`。临时结果目录 `/tmp/lanstash-release-1.0.15.1x6wUX`，没有真实 NAS 写请求。

- `swift test --package-path apple --jobs 2 --filter DownloadTaskDestinationTests`：10 项、0 失败，0.064 秒；随后 `--filter DownloadTaskRemovalTests`：11 项、0 失败，0.072 秒。新共享场景覆盖两种 force_complete 值、明确拒绝、损坏/错位回执、未知恢复、分页错误、编号复用、写前保存失败/取消、旧入口互斥及无 finish 请求。
- `swift test --package-path apple --jobs 2`：2714 项 XCTest、172 条既有条件跳过、0 失败，48.948 秒；12 项 Swift Testing 通过，0.049 秒。包含新增停止做种用 pause 的回归。最后文案调整后的 `--filter AppLanguageTests` 另通过 6 项 Swift Testing（0.045 秒）。
- `xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build` 两轮通过；最后 `lipo -archs .../Release/LanStash.app/Contents/MacOS/LanStash` 为 `x86_64 arm64`。没有安装或启动 Mac App。
- 移动按既定 XcodeGen 工程生成流程增加三个源文件和两个测试文件的引用，共享新类型由 Package 发现。`xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing`：首轮构建期间调整 UI 合成传输入参导致新旧对象的初始化签名不一致、链接失败；第 2–6 轮重新构建通过，没有添加旧初始化兼容层或手改工程。
- 两端 R1 使用 `test-without-building`、相同项目/方案/配置/派生目录、各自 destination、`-parallel-testing-enabled NO`，选择 `-only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadRemovalUITests -only-testing:DsmMobileUITests/MobileDownloadControlUITests -only-testing:DsmMobileUITests/MobileDownloadEditUITests/test单任务选择文件夹保存后详情显示新位置`。结果包 `m5d-phone-r1.xcresult` / `m5d-pad-r1.xcresult`：各 1251 项单元、各 4 条既有设备条件跳过、零失败，32.792 / 33.217 秒；各 12 项 UI 为 11 通过/1 失败，565.285 / 683.639 秒。原 5 项控制与单项编辑均通过；新增 6 项移除中仅中文最大字号失败，原因是列表虚拟化后任务行在屏幕下方，测试没有滚动到目标。已沿用既有列表视口滚动，保留横屏、确认和结果断言。
- 两端 R2 选择全部单元及 6 项移除 UI（`-only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDownloadRemovalUITests`），结果包 `m5d-phone-r2.xcresult` / `m5d-pad-r2.xcresult`。最新两端各 1251 项单元、各 4 条既有条件跳过、0 失败，29.947 / 30.179 秒；各 6 项 UI 为 5 通过/1 失败，286.692 / 300.631 秒。中文最大字号/横屏和原五类业务流程中的对应动作通过，新增的返回详情状态断言未找到独立的纯文本节点；已移除任务的暂停/移除入口不可见断言通过。状态按现有 LabeledContent 的标识、组合文案与实际视口定位补强，R3 保留原状态断言继续复验；没有把该失败删除或当作已通过。

R3 仅选择 `MobileDownloadRemovalUITests/test单项确认取消保持任务随后移除只显示任务结果` 和 `MobileDownloadRemovalUITests/test中文深色最大字号确认与结果支持横屏`，结果包 `m5d-phone-r3.xcresult` / `m5d-pad-r3.xcresult`：两端各 2 项通过、0 失败，136.863 / 125.171 秒。前者包含取消、移除后的原名称和准确状态、返回详情后无暂停/移除入口及主列表不再出现原任务；后者等待真正的中文确认文案后截图，保留最大字号和横屏可达性。6 个新增场景与原 6 个控制/编辑场景均有两端通过证据。

首轮已查看 iPhone 英文确认和部分拒绝截图，随后修正单项数量标题、当次结果名称及精简结果说明。最终另查看两端中文深色最大字号确认页、iPhone 横屏结果及 iPad 移除后详情，确认内容可滚动、风险说明与关闭入口可读、旧操作已隐藏、状态为任务已移除；没有将过渡动画中的父页面截图当作确认页证据。`python3 tools/localization/check_localization.py` 最终 Apple 6192 / Android 2188 / Windows 3402，双语/参数/资源引用/硬编码通过；请求样本 179/1、私有样本/引用 29/48、API 目录一致性、严格文档预检和差异空白检查已通过。真实设备/NAS 条件见移动主计划 M5d 的 `PENDING_USER_VALIDATION`。

交接准备时 `214e87d5` 的 [Apple Build 37264048781](https://github.com/yuangy1995/dsm-native-client/actions/runs/37264048781) 共享/macOS 组已通过，两端全量移动 UI 仍在执行。M5d 本机通过不替代最终提交的全量云端结果；新会话需按交接消息的实际提交和最新运行跟进，并避免持续新推送反复取消唯一完整运行。

最终按锁定 XcodeGen 流程重新生成移动工程，前后内容一致，SHA-256 `2b402a704789a9faf4d7053108d95e4a43e60522dd8afaf916f47786b15b2110`。本切片按既定主分支策略交付，不创建分支或发布安装包；实际提交与云端状态随会话交接提供。

## 2026-10-05 移动 M6a1 NAS 五项读取与入口开放约定

新会话接手基线 `bf68dc962f9796c0f51574c284265589603a8082`，起始工作区干净，main 与 origin/main 一致。完成 Mac 21 页实际源码账本后，先接外接存储、进程/服务组、共享访问、内存压缩和电源计划的读取、筛选与错误恢复；ZRAM/计划保存尚属 M6c，不能由读取页存在宣称完成。唯一修改范围与实际设备待办见[主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m6a1-五项读取与筛选)。

用户在本片补充两项交付条件：已实现功能移除仅因缺少实机证据而固定关闭的限制，保留真实权限/能力/危险确认和防重复；每片分别执行 iPhone/iPad 模拟器交互和截图复核。初步核实 Photos 删除已从移动组合根开放；容器网络默认关闭参数及容器入口强加 DSM 管理员的旧条件随 M7 完整流程修正。该审计没有代替尚未实施的 M6–M8。

环境实读为 Xcode 26.6（17F113），命令行路径 `/Applications/Xcode.app`，本机 iOS SDK 与两台专用模拟器仍为 26.5；与旧交接的 Xcode 26.5 描述不同，本次没有安装、升级或切换工具链。XcodeGen 2.46.0 按 `apple/Apps/DsmMobile/project.yml` 生成工程。移动派生目录仍为 `apple/Apps/DsmMobile/build/m0-m8`，运行测试期间没有重建此目录。结果和日志位于被忽略的 `apple/Apps/DsmMobile/build/m6a1-*`。

本机验证过程如实记录：

- `build-for-testing` 第一轮缺少新增 Debug Fixture 的 `DsmNetwork` 导入；第二轮测试替身未实现 `DsmBinaryHTTPTransport`。分别修正后第三轮构建成功，没有关闭测试目标或削弱断言。
- 第一轮两端测试在新增取消用例停滞：测试替身重复阻塞共享列表第二页。只中断本次两端进程，结果为 `TEST EXECUTE INTERRUPTED`；将阻塞点限制为首个匹配请求后重建。取消后零回写断言保留，没有新增跳过。
- 第二轮两端完整单元均为 1263 项、各 4 条既有条件跳过、零失败；8 项新增实际 UI 各通过 5 项、失败 3 项。失败涉及共享权限缺省被显示为只读、中文未知状态与重试后状态的无障碍文本节点。实际 UI 层次显示 `Status, Enabled` 为同一状态行，不能按独立 `Enabled` 文本假定结构。
- 共享权限修正限定 `DsmFileRepository.listShares`：缺少权限不再从可见性推断只读，普通目录原行为保持；补真实网络适配回归，未新增请求、字段、身份或持久化格式。状态行明确提供无障碍标签和值，测试仍断言具体业务状态。手机详情重复标题已移除。
- 修正后的共享 `swift test --package-path apple --jobs 2` 成功：2715 项 XCTest（172 项既有环境条件跳过）、零失败，另 12 项 Swift Testing 通过；修正前第一轮为 2714 项，同样通过。最终模拟器构建 `m6a1-build-r6.log` 成功。两端第三轮完整单元仍各 1263 项、4 跳过、零失败；界面终态及截图检查在本片结束时补记。

实际命令：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a1-phone-r3.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileNasReadUITests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a1-pad-r3.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileNasReadUITests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

第一次 Mac 回归通过且 `lipo -archs` 为 x86_64/arm64；共享权限修正后再次构建，终态单独补记。未安装或启动该 Mac 产物。独立集成与只读对抗复核由当前负责人另阶段执行，没有虚称其他模型审查：实际网络适配仅触发列表/get/load，覆盖局部失败、未知/零值区别、同配置重连、五页取消迟到、分页、NAS 墙钟与手机时区、共享权限来源；不添加弹出设备或终止进程接口。

交接提交的 [Apple Build 37267487226](https://github.com/yuangy1995/dsm-native-client/actions/runs/37267487226) 已确认 shared-macos 成功，两端完整 UI 尚在运行；本片没有通过推送取消此运行。上一轮 `37264048781` 已取消，不能视为整体通过。新的本机结果不能代替该提交的云端终态。

本片终态补记：

- `m6a1-phone-r3.xcresult` 与 `m6a1-pad-r3.xcresult` 均 `TEST EXECUTE SUCCEEDED`：各 1263 项完整移动单元（各 4 条既有设备条件跳过）与各 8 项新增实际 UI 零失败。第三轮使用深色模式；随后恢复两台模拟器原有浅色模式，`m6a1-phone-light.xcresult` / `m6a1-pad-light.xcresult` 各补跑中文大字号未知开关、共享访问和错误重试三项，均零失败。
- 从 `.xcresult` 导出并实际查看两端页面截图，复核外接设备、NAS 当地电源时间、加载/不可用、共享权限、中文大字状态与系统活动搜索。修正了手机重复标题、英文数量表达和 iPad 窄栏过长搜索提示。最后两项纯界面文案修改后 `m6a1-build-r7.log` 构建成功；`m6a1-phone-final.xcresult` / `m6a1-pad-final.xcresult` 各执行 12 项 `MobileNasReadTests` 与 1 项 `test系统活动搜索能显示与清除无匹配状态`，全部通过，最终搜索截图分别检查。两端浅色补跑使用上方 `test-without-building` 命令，将 `-only-testing` 改为上述三项完整 `DsmMobileUITests/MobileNasReadUITests/<方法名>`；最终聚焦使用 `-only-testing:DsmMobileTests/MobileNasReadTests` 与 `-only-testing:DsmMobileUITests/MobileNasReadUITests/test系统活动搜索能显示与清除无匹配状态`。这是失败修正后的通过证据，不是整组首次零失败。
- 共享修正后的 Mac `m6a1-macos-r2.log` 与最终资源回归 `m6a1-macos-final.log` 均 `BUILD SUCCEEDED`，产物含 x86_64/arm64；仅构建，不安装/启动。最后新增短资源后 `swift test --package-path apple --jobs 2 --filter DsmLocalizationTests` 的 6 项通过。
- `python3 tools/localization/check_localization.py`（Apple 6203、Android 2188、Windows 3402）、`python3 tools/request-contract/validate_contracts.py`（179 请求样本/1 结果）、`python3 tools/contract-validation/validate_fixtures.py`（29 组/48 私有文档）、`python3 tools/codex/check_documentation.py` 和 `git diff --check` 均通过。XcodeGen 2.46.0 重生成工程前后 SHA-256 一致。
- 结束前读取远端 main，仍为交接基线，没有需整合的新提交。旧提交 Apple CI 仍为 shared-macos 成功、两端完整 UI 运行中；本片先留在本地 main，避免推送取消这轮唯一完整云端证据，后续继续跟进。清理本片截图临时导出目录，保留忽略目录中的日志与结果包供复核；未触碰此前正式发布产物。

本片没有真实 NAS 请求或写入，没有新增跳过、修改工具链、身份、权限或存储格式；正式签名、真机/NAS、完整 VoiceOver 与键盘/分屏仍按主计划具体 `PENDING_USER_VALIDATION`。M6a2–M6e、M7、M8 和已实现入口的完整开放审计仍需继续。

## 2026-10-05 移动 M6a2 存储分析硬盘检测与日志

基线为本地 main 的 `f0d8e5fd`（M6a1），工作区起始干净。共享提取既有空间分析到 DsmFileFeature，Mac 只删除原定义并调整引用；移动接卷/池/硬盘详情、七类分析、SMART 确认/启停/历史与独立持久恢复、日志完整分页/本页筛选/正文。共享精确匹配检测类型，补明确原快照和写前保存回调；旧签名保持，卷/池状态与日志总数缺失保留未知。不改 Windows/Android、不写真实 NAS，已实现入口没有仅因缺真机而固定关闭。

当前环境沿用 M6a1：Xcode 26.6（17F113）、iOS SDK/模拟器 26.5、XcodeGen 2.46.0，两台专用模拟器及 `build/m0-m8` 派生目录不变。本片日志和结果包在 `apple/Apps/DsmMobile/build/m6a2-*`，测试运行期间不重建移动派生目录。

验证过程和实际修复：

- 初次构建因 `catch` 的 error 名称遮蔽模型属性而失败，改为明确的 `self.error` 后重新构建通过。后续每次 UI/资源/源码修正均重新 `build-for-testing`；最终 `m6a2-build-r7.log` 为 `TEST BUILD SUCCEEDED`。
- 两端 R1 各 1286 项单元（4 条既有跳过），各 1 失败：未知提交的反馈被随后的读取错误覆盖。模型保留提交未知状态，读取失败不能解除保护。9 项 UI 因列表子节点承载 sheet、加载节点查询方式而未通过；详情改由页面根列表呈现，测试使用实际无障碍状态。聚焦重跑两端各 17 项存储单元及日志分页正文、硬盘启停、空间分析三项 UI 均通过。
- R2 两端各 1289 项完整单元、各 4 条既有条件跳过、零失败；9 项 UI 中 iPhone 5 通过、iPad 6 通过。实际截图发现完整检测确认菜单无可见取消，列表底部按钮露出部分仍被测试当作可点，未知反馈需要滚动。改用系统 alert 的明确取消、将操作记录靠近状态、将可选硬盘资料放入展开区，并让测试在内容视口小幅滚动。没有去掉原断言或增加跳过。
- R4 使用全部单元及 10 项 UI（增加卷/池详情）：iPad 全 10 项 UI 通过；iPhone 9 项通过、中文大字滚动一项失败。两端完整单元仍各 1289 项、4 跳过、零失败。随后只修正测试的大幅滑动越过目标，并补历史时间的 App 语言/秒毫秒/ISO 格式测试；R5 选择 20 项存储单元与整组 10 项 UI，终态在本节后追加。R3 的重复结果路径调用返回 exit 64，未执行测试，不能计为通过。
- 共享最终 `swift test --package-path apple --jobs 2`：2726 项 XCTest、172 条既有环境条件跳过、0 失败，另 12 项 Swift Testing 通过；`m6a2-shared-final2.log` 与收尾 `m6a2-shared-r3.log` 均通过。包含新增 11 项 `NasStorageFlowTests`、原 Mac 分析与管理模型回归。完整移动单元数量与共享数量单独记录，不互相替代。
- 最终 `xcodebuild build` 的 `m6a2-macos-final.log` 为 `BUILD SUCCEEDED`，`lipo -archs` 返回 `x86_64 arm64`；未安装或启动 Mac App。双语/参数/引用/硬编码检查为 Apple 6296、Android 2188、Windows 3402，通过。

实际命令（输出分别重定向至本片对应日志）：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a2-phone-r5.xcresult -only-testing:DsmMobileTests/MobileNasStorageTests -only-testing:DsmMobileUITests/MobileNasStorageUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a2-pad-r5.xcresult -only-testing:DsmMobileTests/MobileNasStorageTests -only-testing:DsmMobileUITests/MobileNasStorageUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

R1/R2/R4 全部移动单元命令将上方存储单元 selector 改为 `-only-testing:DsmMobileTests`；R1/R2 的 UI 组为当时九项，R4 增为十项。当前负责人在独立复核阶段检查权限撤回、身份变更、持久化失败、取消、迟到响应和只读恢复；没有虚称由另一模型审查。真实硬盘负载、NAS 版本/权限、锁屏文件保护及辅助功能另见[主计划 M6a2](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m6a2-存储分析硬盘检测与完整日志)中的具体 `PENDING_USER_VALIDATION`。

收尾结果：

- R5 两端各 10 项实际 UI 全部通过，包括中文大字、卷/池详情、取消、存储/日志各状态、日志分页/正文、启停、未知重启恢复、空间分析及重复文件。iPhone 的 20 项存储单元同时通过；iPad 其中一项过早在记录成功后读取尚未完成刷新的页面状态，实际值为 nil，整轮 exit 65。测试改为等待记录成功、精确状态及刷新结束，再执行原断言；未修改产品逻辑或降低断言。
- 截图发现中文存储状态仍展示 NAS 的 `normal`，移动展示沿用 Mac 已记录状态的双语资源，未知值继续保留原文；`m6a2-build-r8.log` 构建通过。两端 `m6a2-phone-light.xcresult` / `m6a2-pad-light.xcresult` 各 20 项存储单元与 3 项实际 UI 全部通过（各 23 项、0 跳过、0 失败）。命令沿用上方 R5，将结果路径改为 `m6a2-<设备>-light.xcresult`，UI selector 分别为 `test中文大字号硬盘检测入口及确认可操作`、`test日志翻页完整正文与本页筛选`、`test空间分析显示未知容量和重复文件结果`。
- `m6a2-phone-dark-final.xcresult` 单独执行中文大字号确认/取消，1 项通过；先使用 `xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance dark`，完成后恢复 light。iPad R4/R5 深色、两端最终浅色截图均已实际查看，不能用设置命令代替像素证据。已看到可见的开始/取消、完整长正文、未知容量说明和恢复结果。用户询问后另将 Simulator 的 iPad 窗口调到前台，并展示实际 UI 测试截图。
- 最后一张 iPad 浅色日志截图暴露窄栏分页文字折行；改为同样式/点击区域的左右箭头，保留完整无障碍名称。`m6a2-build-r9.log` 构建通过，两端日志翻页/全文/筛选定向复测各 1 项通过，结果为 `m6a2-phone-pagination.xcresult` / `m6a2-pad-pagination.xcresult`，命令只选择上述日志方法。最终两端截图已复核，iPad 窄栏箭头完整可见；没有以测试通过替代截图检查。
- 按现有锁定路径 `/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen`（2.46.0）重生成移动工程，前后 SHA-256 均为 `64547dfc7809e765163b64495105d022ba22444ec48cbc02ecb0eaa6ee7bcb49`。请求样本 179/1、私有样本/文档引用 29/48、本地化资源 6296/2188/3402、文档与差异检查通过。
- 再次 fetch origin/main，远端仍为交接基线。交接提交 [Apple Build 37267487226](https://github.com/yuangy1995/dsm-native-client/actions/runs/37267487226) 仍为 shared-macos 成功、两端完整 UI 运行中；本片不以新推送取消该运行，本机通过不代表当前提交的云端通过。

本片结束时清理临时截图导出目录及一次性当前画面，日志/xcresult 保留在忽略目录以便复核；向用户展示的合成截图副本单独保留在本地 `build/m6a2-preview`，不提交。两台模拟器恢复原浅色设置，未擦除其他模拟器。功能和验证文档作为完整切片在 main 保存；后续继续 M6a3，不宣布整个 M6–M8 完成。

## 2026-10-05 移动 M6a3 DDNS 与交接 CI 修复

本片开始于本地 main 的 `6846bd65`，工作区干净；此前两个 M6 提交尚未推送，以保留交接提交的完整云端运行。实现 DDNS 服务商/记录搜索、新建与编辑、独立连接测试、更新地址、删除、明确确认及账号隔离的持久恢复。移动区域与时间设置尚未实施，不以 DDNS 完成代替整个 M6a3 完成。用户另明确授权修正 Mac 区域设置的结果判断：配置相同不能覆盖校时部分失败、权限拒绝或未知结果；共享层遇到明确拒绝不再尝试用相同配置回读覆盖结论。

DDNS 沿用现有 Provider/Record v1 请求管线，兼容增加确认快照、严格管理读取和写前/接受回执回调；不新增猜测请求。新恢复文件只存摘要、动作与阶段，不存口令、域名、账号或地址正文。仅变更密码但丢失回执时不能凭公开字段匹配冒认成功；瞬时测试/更新无回执保留未知反馈，只允许新的明确操作，不自动重发。编辑使用本次预检读到的网络字段，避免将打开表单时的旧公网地址写回。Windows/Android 只登记影响，不改代码。

交接 [Apple Build 37267487226](https://github.com/yuangy1995/dsm-native-client/actions/runs/37267487226) 已完整结束：shared-macos 成功，iPhone 的 248 项 UI 中 2 失败，iPad 的 248 项 UI 中 11 失败；汇总任务失败。不能将此前的运行中状态或共享成功记作整轮成功。

- 云端 iPad 录像/无障碍位置证实文件搜索栏覆盖首行及其操作按钮，本机压缩场景也重现。改为搜索栏在纵向布局中占用实际空间，相关文件操作新增不重叠断言，保留压缩、解压、权限、挂载、收藏、ZIP 和 Office 原业务断言。
- 云端 BT 目的地按钮点击后未出现目录面板；本机旧实现暂未重现。将 sheet 挂到稳定页面根，后续两端原 BT 测试均通过；仍须最终云端复验。
- Chat 丢回执重启测试误用编辑区的长文案查找详情状态，改为检查实际状态节点及短文案，并保留不能重试/移除的断言。系统 ZIP 分享关闭改为等待面板实际消失，仍要求最终不存在。
- 本机两端 R2 各选择上述 12 个不同失败场景、2 项文件搜索回归和 7 项 DDNS UI。原 CI 相关 12 场景与搜索 2 场景在两端全部通过；不新增跳过或缩减原业务断言。

环境为 Xcode 26.6（17F113）、iOS SDK/模拟器 26.5、锁定 XcodeGen 2.46.0。两台专用模拟器和 `build/m0-m8` 派生目录沿用 M6a1；没有升级工具链、修改 App 身份或安装/启动 Mac App。日志及结果在 `apple/Apps/DsmMobile/build/m6a3-*`。

实际验证过程：

- 新网络回归最初发现未知布尔字符串被默认解释为 false，严格管理解析改为只接受契约明确的值；同时检查必要字符串、完整数组与唯一记录。新增 10 项 DDNS 网络测试、1 项区域权限拒绝测试以及 2 项 Mac 反馈测试。
- 移动首次构建因错误类别枚举没有 `.unsupported` 失败，修正后通过。R1 两端各 1304 项完整单元中 2 失败：连接测试错误套用了仅保存使用的凭据回执条件、页面刷新前过早结束忙碌状态；均修正产品逻辑，保留断言。7 项新 UI 各 6 通过、1 失败，保存按钮灰色的录像与无障碍节点证实测试查到了外层容器，改为准确查询按钮本身。
- R2 两端各 1304 项单元、4 条既有条件跳过，各 1 条静态源码断言未更新：NAS 工具栏已改为统一刷新入口，测试仍要求直接调用健康摘要。改为验证统一调用及实际刷新的四个模型。21 项 UI 中 iPad 全部通过；iPhone 20 通过，DDNS 错误重试测试在详情页查找只位于目录页的工具栏，补原生返回后刷新再进入，仍验证全局刷新取得记录。iPad 的未知恢复期间有系统动画等待，最终通过，未中途取消或将等待当作通过。
- R9 构建因上述静态测试修改位置不正确、局部变量超出作用域失败；将断言放回对应工作区测试，R10 `build-for-testing` 成功。期间没有对仍在执行的模拟器派生目录重建。
- 最终共享 `swift test --package-path apple --jobs 2`：2739 项 XCTest、172 条既有条件跳过、0 失败，另 12 项 Swift Testing 通过（`m6a3-shared-final.log`）。包含最新公网地址变化回归与 Mac 管理模型。最终资源改动再执行 `--filter DsmLocalizationTests`，6 项通过。
- Mac Release 最新共享代码构建成功（`m6a3-macos-final.log`），最终资源构建 `m6a3-macos-resources.log` 成功；架构与两端最终复测结果在下文收尾追加。

实际命令（每次输出写入对应本地日志）：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a3-phone-final.xcresult -only-testing:DsmMobileTests '-only-testing:DsmMobileUITests/MobileDDNSUITests/test已有记录保存开关并可取消或确认删除' '-only-testing:DsmMobileUITests/MobileDDNSUITests/test未知保存重启只恢复原记录而不重新创建' '-only-testing:DsmMobileUITests/MobileDDNSUITests/test空列表加载错误重试不支持和筛选为空各有恢复' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a3-pad-final.xcresult -only-testing:DsmMobileTests '-only-testing:DsmMobileUITests/MobileDDNSUITests/test已有记录保存开关并可取消或确认删除' '-only-testing:DsmMobileUITests/MobileDDNSUITests/test未知保存重启只恢复原记录而不重新创建' '-only-testing:DsmMobileUITests/MobileDDNSUITests/test空列表加载错误重试不支持和筛选为空各有恢复' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
swift test --package-path apple --jobs 2
swift test --package-path apple --jobs 2 --filter DsmLocalizationTests
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

R1 选择 `-only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDDNSUITests`；R2 另加云端失败方法及 `MobileWorkspaceUITests` 的两个文件搜索方法。每次使用独立结果目录，没有覆盖失败证据。当前负责人在实现后独立执行只读对抗复核，检查请求分离、最新权限和原配置、凭据存储、回执丢失、重复点击、账号切换和迟到结果，没有虚称外部模型复核或真实 NAS 验收。DDNS 服务商、真机锁屏、系统辅助功能及 Mac 真实校时结果仍按主计划具体 `PENDING_USER_VALIDATION`，本轮 Agent 没有向真实 NAS 提交操作。

收尾结果：

- `m6a3-phone-final.xcresult`、`m6a3-pad-final.xcresult` 均 exit 0；两端各 1304 项完整单元、4 条既有条件跳过、0 失败，以及上述 3 项实际 UI 全部通过。此前 7 项新 DDNS UI 加最终修正场景在两端均有通过证据，不能把 R1/R2 整轮失败隐去。
- 浅色截图已实际查看 iPhone 记录/删除确认、iPad 中文大字确认。发现系统密码管理器可能弹出保存提示，因此将界面文案明确为“App 不会保存密码或密钥”，不承诺用户主动选择的系统行为。只改中英文资源，再次构建 R11 通过。
- 两端运行 `xcrun simctl ui <设备 ID> appearance dark` 后，沿用上述 `test-without-building` 命令，仅选 `MobileDDNSUITests/test中文大字详情与风险确认可触达并取消`，结果路径分别为 `m6a3-phone-dark.xcresult` / `m6a3-pad-dark.xcresult`：各 1 项通过、0 失败。导出并实际查看两张最终截图，风险内容完整、取消和删除按钮可触达，最终将两台恢复 light。截图和系统提示观察不替代真机辅助功能验收。
- Mac 最终资源构建 `m6a3-macos-resources-final.log` 为 `BUILD SUCCEEDED`；`lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 返回 `x86_64 arm64`。
- 锁定 XcodeGen 2.46.0 重生成前后 SHA-256 均为 `4de1f72514f8447d771b1173829594f89ba878563874afa8be8d0765bb29393c`。双语/参数/引用/硬编码校验 Apple 6340、Android 2188、Windows 3402；请求样本 179/1、私有样本/文档 29/48、文档及差异检查通过。
- fetch origin/main 没有发现远端新增提交。CI 修复作为 `ff90b98` 独立提交，DDNS 与已授权 Mac 反馈修正另作完整提交；在已有 main 授权范围正常推送，下一轮云端终态需继续跟进，本机结果不替代云端全量。没有创建分支/PR、打标签或发布安装包。
- 清理本轮下载的云端结果包、录像和临时截图导出，仅保留忽略目录中的本机测试结果/日志和少量合成展示图片；保留 M6a2 已交付图片和其他原有文件。

后续继续移动区域时间、M6b–M6e、M7–M8 和旧入口固定门审计，当前目标尚未整体完成。

## 2026-10-05 macOS 映像验证短暂占用修复

DDNS 提交 `83af8606` 的 [Apple Build 37300934405](https://github.com/yuangy1995/dsm-native-client/actions/runs/37300934405) 中，shared-macos 的 2739 项 XCTest（172 条既有跳过）、12 项 Swift Testing、发布与签名回归均通过。应用已完成构建、临时签名、库实际加载和 arm64 架构检查，DMG 创建成功后立即执行 verify 时返回 `Resource temporarily unavailable`，打包步骤因此 exit 1；不是源码测试失败，也不能将该组记为通过。两端完整 UI 当时仍在执行，不以新推送取消该轮证据。

`package.sh` 只对这个已经观察到的系统临时占用错误重试验证，最多三次，每次间隔两秒；其他错误立即保留原退出码和诊断，连续占用也必须失败。不重新生成或覆盖映像，不跳过校验、签名、组件加载或架构检查，不修改正式权限及发布流程。

本机实际运行 `python3 -m unittest tools.release.test_macos_signing.MacOSSigningTests.test_disk_image_verification_only_retries_temporary_resource_errors tools.release.test_macos_signing.MacOSSigningTests.test_disk_image_verification_accepts_a_real_synthetic_image`：2 项通过。故障注入分别验证一次成功、临时占用后成功、三次仍占用及损坏错误立即退出；另实际创建小型合成 UDZO 映像并调用同一验证函数，通过后由临时目录自动清理。随后执行 `python3 -m unittest discover -s tools/release -p 'test_*.py'`：34 项全部通过；`bash -n apple/Apps/DsmMac/package.sh` 和 `git diff --check` 通过。日志分别保留于移动忽略目录的 `m6a3-region-dmg-tests.log` 和 `m6a3-region-release-tests.log`。

本次没有安装/启动主应用、操作真实 NAS、创建发布标签或发布产物。云端修复结论仍须看包含该改动的后续运行，不能用合成重试测试代替托管环境最终结果。


## 2026-10-05 移动 M6a3 区域时间与分步校时恢复

从已推送的 `83af8606` 继续区域时间，起始工作区干净。先核实上述云端 DMG 失败并以 `f0432d7` 独立提交修复；两端云端完整 UI 仍运行时不再次推送取消它。区域切片新增九种日期格式、12/24 小时、时区搜索、网络服务器、手动日期时间和单独立即校时；所有入口按实际权限与状态开放，没有缺实机证据的固定关闭常量。

共享沿用原 get/listzone/set/sync 管线，为移动增量增加原配置确认、写前/接受回执/完整配置回读检查点，旧 Mac 签名保持。单独重试校时不重新 set；未主动编辑手动时间使用 NAS 新值，小幅一分钟调整也按明确意图提交。独立受保护记录保存摘要、阶段和明确选择的墙上时间，不保存服务器或账号正文。手动改时无回执不能仅以相近读数恢复成功；网络校时无任务编号，未知不自动重放，新操作需明确确认。具体风险和回滚/真机条件见[主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m6a3-区域时间与-ddns)。

沿用 Xcode 26.6（17F113）、iOS SDK/模拟器 26.5、XcodeGen 2.46.0 和两台专用模拟器。实际记录位于 `apple/Apps/DsmMobile/build/m6a3-region-*`，测试运行期间不重建其使用的派生目录。

- 初次移动构建因错误类别不存在 `.validation` 而失败；按实际 AppErrorCategory 修正后 R2 构建成功。新行为测试首轮 15 项，后补校时权限拒绝为 16 项。
- R1 两端各 1319 项完整单元、4 条既有跳过、0 失败。7 项实际 UI 中 iPhone 6 通过、iPad 5 通过：两端的日期测试误把完整日期按钮当作数字按钮；iPad 时区列表默认没有可见搜索框。导出并实际查看录像/层级，日期控件正常，测试改为选择包含数字的实际日期按钮；时区搜索改为常显。iPhone 编辑页标题截断，改用简短的“区域与时间”标题。
- R2 两端各 1320 项完整单元、4 条既有跳过、0 失败；两项定向 UI 中 iPhone 全通过，iPad 两项失败：测试清空搜索后未重新获取键盘焦点，点击全屏弹窗关闭区域又一并关闭了编辑表单。改为重新点入搜索、点编辑页标题收起日历，并将手动日期场景补全为取消后再次确认保存、检查真实回读日期。没有缩减断言或新增跳过。
- 最新共享 `swift test --package-path apple --jobs 2`（`m6a3-region-shared-r3.log`）：2751 项 XCTest、172 条既有条件跳过、0 失败，另 12 项 Swift Testing 通过。包含 13 项 `NasRegionFlowTests`、原 185 项 NAS 适配测试和 98 项 Mac 管理模型测试；配置与校时中间取消、单独校时权限拒绝均分别判定，没有把配置读取算成新的保存。
- Mac Release 构建 `m6a3-region-macos.log` 及源码稳定后的 `m6a3-region-macos-final.log` 均成功，架构检查与最终 UI 轮次在下文补记。未安装或启动 Mac App。

实际命令（输出写入相应日志）：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a3-region-phone-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileRegionUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6a3-region-pad-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileRegionUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

R2 使用同样命令、独立 `-r2.xcresult` 路径，UI selector 只选择当时的 `test手动时间控件可展开并选择日期后取消保存` 和 `test格式与可搜索时区编辑保存及确认取消`；全部单元仍运行。R4 编译更新后的 UI 测试，手动方法改名为 `test手动日期选择可取消再确认保存`，保留取消断言并增加保存回读。独立集成及只读对抗复核由当前负责人完成，实际 NAS 时间未更改，所有写测试均走合成传输。

收尾结果：

- R3 在两台模拟器设为 dark 后，仅选择中文大字确认/表单、更新后的手动日期保存和格式/时区搜索三项 UI。iPhone 三项全通过；iPad 中文大字和搜索保存通过，日期测试的标题点击位置被日历覆盖，保存按钮未收到点击。已实际查看截图与层级；日期选中正确，测试改为在表单标题栏左侧空白处收起日历，并明确等待日期弹层消失，保留全部取消、保存和回读断言。
- R5 `build-for-testing` 成功，R4 两端仅重跑 `MobileRegionUITests/test手动日期选择可取消再确认保存`：各 1 项通过，结果为 `m6a3-region-phone-r4.xcresult` / `m6a3-region-pad-r4.xcresult`。实际选中七日，先取消保存、再确认保存，检查读回七日及成功记录；没有用构建或程序设置值替代触控操作。七项新 UI 在两端均有通过记录，中间失败保留。
- 深色中文大字确认与编辑表单、最终手动日期回读截图均已实际查看；浅色 iPhone 确认/保存与 iPad 搜索框录像另行复核。系统日历使用完整日期无障碍标签，测试选择其真实日期按钮；正式 VoiceOver 仍待真机。两台模拟器最后恢复原 light 设置。
- 最终 Mac `lipo -archs` 返回 `x86_64 arm64`。双语/参数/引用/硬编码扫描为 Apple 6380、Android 2188、Windows 3402；请求样本 179/1、私有样本/文档引用 29/48、文档和差异检查通过。锁定 XcodeGen 重生成前后 SHA-256 均为 `294198c7f47eec863852c607013b1314ffd4d4ad417ad71c970a6da4aeaf2070`，内容一致。
- 区域代码与文档在 main 完整提交；不在两端云端整轮仍运行时推送，以免取消该证据。已知 shared-macos 映像问题的本地修复与实际发布回归见上一节，仍需后续云端确认。没有分支、PR、标签、正式发布或真实 NAS 写入。
- 清理本片临时 UI 层级、录像和截图导出；本机测试日志/结果包继续保留在忽略目录，少量合成交付图片保留于 `build/m6a3-region-preview`。不删除此前 M6a2/DDNS 的交付图片或其他用户文件。

M6a3 当前环境工作完成；M6b–M6e、M7–M8、已实现入口固定门审计及主计划所列真实系统验证继续进行，不能将本片完成当作整个目标完成。

## 2026-10-05 移动 M6b1 账号与群组管理

从本机 `c28d4993`（main 比 origin 提前两条，工作区干净）继续；云端 `83af8606` 的两端完整 UI 仍运行时未推送取消。读取 Mac 账号/群组模型、表单与 `dsm-account-directory` 后建立 M6b1 账本，当前负责人单独修改移动管理/组合根/路由/资源、共享兼容接口与对应测试；Mac App 文件、Windows/Android 源码未改。

实现账号/群组搜索与目录切换、新建/编辑/删除、账号密码/停用/所属组和独立受保护恢复。普通资料直接保存，密码/停用/组关系等风险修改与删除需明确后果确认；没有仪式式复核勾选。共享固定 v1 管理读、完整原对象/数字身份和群组目录确认，复用旧请求参数构造；创建或改密没有接受回执始终保留未知，普通字段和删除只读恢复，不重发。恢复文件只保存摘要和阶段，不存账号/邮件/成员正文及密码；具体边界见主计划和端点文档。

独立集成与只读对抗复核由当前负责人在实现后单独执行：检查写前/接受回执落盘失败、目录畸形、同名不同身份、组目录漂移、当前账号/保留名、明确拒绝、取消、重复点击、同配置重连及跨账号迟到结果。发现恢复格式可被不一致的创建回执字段误读时，增加字段一致性校验和故障注入回归；未引入自动重放或无条件清除未知操作。用户名写入仍用原始标识，只有保护和防重使用规范化形式。NAS 未提供跨客户端原子比较保证，真实环境验收期间应避免并行修改同一账号或群组。

沿用 Xcode 26.6（17F113）、iOS SDK/模拟器 26.5、XcodeGen 2.46.0。当前本机命令和中间证据：

- `swift test --package-path apple --jobs 2 --filter NasDDNSFlowTests`：10 项通过，先验证兼容编译；日志 `m6b1-shared-compile.log`。
- `swift test --package-path apple --jobs 2 --filter 'NasDirectoryFlowTests|DsmNasAdministrationRepositoryTests'`：首轮 196 项中 9 失败，原因是新 diagnosticTag 使用状态驼峰值而不符合已有安全格式；改为小写后 R2 为 196 项、0 失败，其中新目录请求 11 项、既有 NAS 适配 185 项。日志 `m6b1-shared-focused*.log`。
- `swift test --package-path apple --jobs 2`：2762 项 XCTest、172 条既有条件跳过、0 失败，另 12 项 Swift Testing 通过；包含 Mac 模型回归。日志 `m6b1-shared-full.log`。
- 移动 R1 构建因两个 switch 表达式直接传参失败，修正后 R2 又发现只读详情枚举尚缺 `.accounts` 空分支；完整补齐，R3 `build-for-testing` 成功。生成工程只用锁定 XcodeGen 更新，没有手工修改工程。
- 第一轮两端各运行 1335 项完整单元、4 条既有跳过、2 失败：目录替身重排后错误替换第一项而非指定目标，旧静态检查又把 `.accounts` 导航枚举误当 `.account` 敏感字段。修正替身按名称定位，静态检查使用精确字段边界且增加只读页不得承载管理视图的断言，没有降低权限/未知恢复断言。
- R1 实际 UI 已发现 iPad 大字滚动测试落到文本输入区，改为定位表单容器并在边缘滚动；当前账号禁用按钮断言也必须先滚到真实控件。新建账号流程发现多个输入框共用焦点，改为逐字段绑定；补上已有说明/邮件值的可见标签。全部问题与最终重跑结果在本节后续补记。

实际目标命令（标准输出与错误写入 `apple/Apps/DsmMobile/build/m6b1-*`；各轮使用独立结果包）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b1-phone-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDirectoryUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b1-pad-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDirectoryUITests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

R1 收齐：iPhone 八项 UI 四通过、四失败；iPad 五通过、三失败。两端五态/搜索/重试、明确拒绝、群组创建编辑删除均通过；iPhone 中文大字通过，iPad 当前账号保护及未知重启恢复通过。实际查看 iPad 大字编辑截图、删除后界面和 iPhone 新建失败录像：滚动测试需要避开输入控件；iPad 删除已由回读确认，但嵌套弹窗后表单没有关闭，改为外层绑定控制关闭。输入框采用独立焦点，说明/邮件保留可见标签，滚动可收起键盘；没有因这些 UI 失败修改请求、安全判断或断言目标。

R4 移动构建通过。新增恢复记录一致性测试后，R2 两端完整单元均为 1336 项、4 条既有条件跳过、0 失败；新目录行为测试 16 项全部通过。R2 同时在两台模拟器的 dark 模式运行八项新 UI，最终结果继续补记。共享源码在完整测试后未再改变；Mac Release 构建成功，`lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 返回 `x86_64 arm64`。锁定 XcodeGen 重生成前后工程 SHA-256 均为 `0251ef5c2ee04f5f8dbe75acf52df0c0ccea59aa7b7c86cd2ac1fd2b5bc3ec02`。


R2 深色实际 UI 的中文大字、五态/搜索/重试、当前账号保护、明确拒绝及未知重启恢复均在两端通过；创建手动密码仍失败，iPad 的群组/账号删除完成后关闭仍有竞争。进一步查看 R1 录像第 32/37/40.4 秒确认是系统“使用强密码”建议干预手动测试：退出建议会清空先前字段。因此保留 App 的系统密码支持，测试在每次手动输入前明确关闭该建议，并仍要求两次密码不一致时禁用保存。

R5 构建通过，风险确认使用原生二级表单，确认表单实际关闭后才提交。R3 浅色四项 UI 中，两端中文大字与群组 CRUD 通过；创建已越过密码断言并提交成功，但随后测试读取已关闭表单的滚动区域而失败，账号编辑/删除同样在转场时读取了失效控件。测试改为等待底层列表实际恢复可操作，再断言编辑器消失；表单用操作任务完成（包括刷新）驱动关闭，避免合并的状态更新漏掉结束。后续 R6 构建与 R4 结果补记，不把 R3 局部通过称为完整通过。

用户在本片期间另授权同步修复 Mac 文件服务、终端和代理反馈，范围仅三个结果判断及回归。先执行 `swift test --package-path apple --jobs 2 --filter 'NasAdministrationModelTests/test.*相同缓存不能覆盖'`，三项新测试在六种状态下产生 18 条预期失败（`m6b1-mac-feedback-red.log`），证实缓存匹配掩盖实际结果。删除三个缓存覆盖分支及仅供它们使用的比较函数后，`swift test --package-path apple --jobs 2 --filter NasAdministrationModelTests` 为 101 项通过（`m6b1-mac-feedback-green.log`）。没有改请求、权限或功能范围。

包含该授权修复的 `swift test --package-path apple --jobs 2` 最终为 2765 项 XCTest、172 条既有跳过、0 失败，另 12 项 Swift Testing 通过（`m6b1-shared-final.log`）；Mac Release 最终构建 `m6b1-macos-final.log` 成功，实际 `lipo -archs` 仍为 `x86_64 arm64`。这些结果不替代真实 NAS、正式签名或设备验收。


最终收尾：

- R6 移动构建通过后，R4 两端完整单元均 1336 项/4 条既有跳过/0 失败，但三个 UI 都在测试等待列表容器自身可点击时失败。实际导出创建录像可见新账号、成功记录且编辑器已关闭；容器可见不等于它本身是可点击控件。改为等待真正的新建按钮恢复可操作，保留编辑器必须消失的断言；说明字段以三次点击整段替换并断言精确新值，滚动范围排除软件键盘，避免坐标点击落入键盘或仅删除光标前内容。
- R7 构建成功，R5 深色五项 UI（中文大字风险确认、账号创建/密码匹配、群组 CRUD、账号编辑/所属组/删除确认、未知重启恢复）在 iPhone 与 iPad **各五项全部通过**，结果为 `m6b1-phone-r5.xcresult` / `m6b1-pad-r5.xcresult`。R2 中另外三项五态/搜索/重试、当前账号保护、明确拒绝均有两端通过记录；没有新增 skip 或降低密码、权限、原对象及防重断言。
- 只读复核补齐资料未知的显示：不呈现猜测的默认停用开关、空白编辑资料或密码编辑，而是保留已知名称/编号/组关系并提供 DSM 查看路径。新增第 17 项模型测试和第九项 UI。R8 构建成功，R6 浅色两端 **各 1337 项完整单元、4 条既有条件跳过、0 失败，以及一项只读资料 UI 通过**；结果为 `m6b1-phone-r6.xcresult` / `m6b1-pad-r6.xcresult`。九项新 UI 是跨轮分别取得两端通过证据，不声称最初整组无失败。
- 最新资源检查为 Apple 6434、Android 2188、Windows 3402；双语/参数/引用/硬编码、179 个请求及 1 个写结果、29 组私有样本/48 项文档引用、文档与差异检查通过。新增最后一条资源后 `swift test --package-path apple --jobs 2 --filter AppLanguageTests` 为 6 项 Swift Testing 通过（XCTest 子集为 0，不能误报为六项 XCTest）。
- 深色两端中文大字编辑和完整删除风险表单、浅色新账号成功列表均已实际查看；只读资料截图另保留。图片均为合成数据，位于忽略目录 `build/m6b1-preview`，测试日志/结果包继续保留，临时导出的录像和层级在收尾清理。两台模拟器恢复并确认 light。
- Mac 三处反馈修复以 `ba4dfe6` 独立提交，提交前 `git fetch origin main` 确认远端无新提交。当前移动账户片同样在 main 完整提交；云端 `37300934405` 的两端旧整轮尚未结束时暂不推送取消，已知映像短暂占用修复仍待含修复的新云端结果。没有创建分支、PR、标签、正式发布或真实 NAS 写入。

M6b1 当前环境开发完成。下一片为 M6b2 文件服务、终端及代理；其余 M6、M7、M8 和整体验收仍继续，整个目标保持进行中。

## 2026-10-05 移动 M6b2 文件服务、终端与代理

基线 `553b623e`、main 工作区干净。四个已验证提交尚未推送，避免取消 `37300934405` 的两端完整移动回归；该 run 的 macOS 已知 DMG 短暂占用修复在本地提交，不能视作新云端通过。当前片单一修改移动服务设置、必要组合根/导航/资源/工程/合成测试，共享 Core/Network 的兼容增量与对应文档；Mac App、Android、Windows 未改源码。

实现原生三类设置表单与具体后果确认、完整原值/权限检查及独立服务恢复记录。实际写请求与旧 Mac 调用共用；文件服务逐组记录，终端/代理每次完整请求记为一组。单请求部分字段已生效时保留该事实和整组未知保护；未知不自动补写、未提交后组不认领成功。对抗复核追加最后回读所有已写组，外部改回前组不能仍报告全部成功。详细真实设备条件位于主计划 M6b2。

截至首轮本机验证：

- 共享初次增量编译及 `NasDirectoryFlowTests` 11 项通过（`m6b2-shared-compile.log`）。新增服务测试第一次编译因合成测试将 `Any` 跨 actor 传递被 Swift 6 拒绝；改为 Sendable 值后新 14 项通过（`m6b2-shared-focused-r2.log`）。扩展最终回读和新旧入口互斥后，`swift test --package-path apple --jobs 2 --filter 'NasServiceFlowTests|DsmNasAdministrationRepositoryTests'` 为 201 项/0 失败，其中新服务 16 项（`m6b2-shared-focused-r3.log`）。
- 移动构建 R1 因导航标题文件未导入 DsmCore 失败，补导入后 R2 通过；本地化扫描指出新动态插值资源键无法校验，改为稳定枚举和显式完整资源键，未放宽扫描器。R3 构建和 Apple 6494/Android 2188/Windows 3402 资源完整性、参数、引用与硬编码检查通过。
- R1 两台模拟器完整单元均 **1354 项、4 条既有系统条件跳过、0 失败**，新增 `MobileServiceSettingsTests` 17 项均通过。真实锁屏文件保护按主计划后置，不新增跳过或将模拟器结果称为真机通过。九项新实际 UI 正在执行，最终结果另补。

实际命令（设备同本日既有两台，使用项目当前 Xcode，不升级工具链）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b2-phone-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b2-pad-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests -parallel-testing-enabled NO
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```


M6b2 后续验证记录：

- 完整共享 `swift test --package-path apple --jobs 2` 为 **2781 项 XCTest、172 条既有跳过、0 失败，另 12 项 Swift Testing 通过**（`m6b2-shared-full.log`）。Mac Release 构建通过（`m6b2-macos.log`），实际 `lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash` 为 `x86_64 arm64`；没有安装或启动 Mac 测试包。
- R1 九项 UI：iPhone 六项通过、三项失败；iPad 七项通过、两项失败。两端代理替换及 iPhone 终端端口替换失败源于测试点击合并后的标签/值区域或只选中部分文本；实际输入值断言保留。只读场景最初从无管理员权限启动，NAS 模块未出现，无法进入目标页面；合成场景改成已进入设置后撤销管理权限，保留实际组合根权限读取。
- R4 构建通过。R2 深色定向两端各 17 项本片单元通过；iPhone 五项 UI（中文大字、代理启停、文件服务、终端端口、缺失字段/权限撤回）全部通过；iPad 中文大字和权限撤回两项通过，三个输入相关 UI 因长按未出现系统“全选”菜单失败。导出录像/层级证明 iPhone 长地址标签和值分两行，iPad 有键盘焦点但没有长按菜单。测试改为 iPad 点击可见值末尾并删除原值，再断言完整新值；iPhone 保持已通过的系统全选操作。
- 截图审查发现空设置页残留无用编辑/搜索控件，以及不可用状态重复显示两条说明；本片页面改为隐藏空状态控件，并直接显示具体原因和重试。R5/R6 构建通过；改动仅本片界面和合成测试，不修改网络或权限语义。R3 对两端五态及 iPad 三类输入流程定向复测，结果待收。

两端全部照片均为模拟器合成数据。中文大字深色终端表单/完整风险说明已实际查看，保留在忽略目录 `build/m6b2-preview`；正常、加载、空内容、筛选为空、不可用和文件服务确认/保存截图也已检查。真实锁屏、VoiceOver、iPad 键盘/分屏及 NAS 服务副作用仍按主计划待用户验证。

后续切片只读核对另外发现 Mac `saveEthernetInterface`、`saveSecurity`、`saveHardware` 仍有相同缓存覆盖结果分支；已向用户请求限定为三处反馈及回归的单独授权，未修改这三处。`saveRemoteAccess` 已按实际结果判断，无需纳入该修正。


M6b2 最终收尾：

- R3 深色定向复测：iPhone 五态一项通过；iPad 五态、代理启停、文件服务、终端端口共四项全部通过。九项新 UI 至此均有两端通过证据；R1/R2 的失败已保留，不能把跨轮通过说成最初整组通过。
- 最终审查使搜索基于稳定服务标识，而非翻译后的开关状态；新增实际 SMB 筛选断言。关闭代理只比较开关，保留地址变化不得被记为本次部分生效，现有网络测试补此断言。最终共享 `m6b2-shared-final.log` 仍为 **2781 XCTest / 172 条既有跳过 / 0 失败，加 12 Swift Testing 通过**；Mac `m6b2-macos-final.log` 再次构建成功，实际 `lipo` 为 **x86_64 arm64**。
- R7 最终移动构建成功；R4 最终两端完整单元各 **1354 项 / 4 条既有跳过 / 0 失败**。iPhone 五态/稳定搜索一项 UI 通过，iPad 五态/稳定搜索与代理启停两项 UI 全部通过，结果包为 `m6b2-phone-r4.xcresult` / `m6b2-pad-r4.xcresult`，均 exit 0。R2 的中文大字、权限撤回，以及 R1 的部分保存/明确拒绝/重启恢复等通过证据仍各自保留。
- 同一 XcodeGen 2.46.0 再生成工程前后 SHA-256 均为 `507d0d7a99b53e4c12a75a832a9e8bcd873a011e0fac3b1f48b5e6e8b681f0f9`；最终资源 6494/2188/3402、请求 179+1、私有样本 29/文档引用 48、文档和差异检查通过。
- 已实际检查两端浅色文件服务确认/保存、加载/空内容/筛选/不可用，以及深色中文大字终端编辑/完整风险说明；最终空状态无无用编辑/搜索，不可用只保留一条原因与重试。十张供用户查看的合成截图保留 `build/m6b2-preview`；一次性导出的录像、层级及当前帧清理，正式测试日志/结果包保留忽略目录。
- 提交前再次 fetch，main 与 origin/main 比较为本地领先四条、远端无新增。最新查询 `37300934405` 两台移动全量仍在运行，shared-macos 是旧 DMG 失败；本片在 main 语义完整提交，暂不推送取消唯一全量运行。没有创建分支/PR/标签、正式发布、安装 Mac 包或执行真实 NAS 写入。

最终定向命令（同一派生构建，完整单元及选定 UI）：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b2-phone-r4.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test五态搜索与读取失败恢复 -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b2-pad-r4.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test五态搜索与读取失败恢复 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理 -parallel-testing-enabled NO
```

M6b2 源码与当前环境验收完成，真实 NAS 服务连接、Telnet、代理及真机文件保护/辅助功能仍为具体 `PENDING_USER_VALIDATION`。整体 M6–M8 目标仍在进行。

## 2026-10-06 移动导航等待与聊天停止边界回归

接续 Apple Build `37300934405`（提交 `83af8606`）的 [iPhone 作业](https://github.com/yuangy1995/dsm-native-client/actions/runs/37300934405/job/111733215105) 已于 2026-10-05 15:54 UTC 结束并失败：1304 项单元、4 条既有跳过、0 失败；273 项实际 UI 中两项失败。iPad 当时仍在同一整轮运行，没有取消、重跑或以本地通过替代其结果。已知 macOS DMG 短暂占用修复仍在此前本地提交。

云端两处证据：`MobileDDNSUITests/test已有记录保存开关并可取消或确认删除` 在第 152 行等待 `mobile.navigation.nasSettings` 失败；`MobileDownloadControlUITests/test取消剩余项目后空任务列表仍可查看与清除已结束记录` 在第 111 行等待 `mobile.navigation.downloads` 失败。日志均显示刚点击值为 0 的模块开关，约半秒后仅检查一次目标标签是否存在，随后等待手机布局没有的侧栏标识。改为在原五秒范围内等待标签栏或侧栏的实际目标存在且可点击，再选择呈现出的入口；保存、删除、取消、未知恢复及清理断言均保留，不增加跳过或延长失败超时。完整作业日志保留忽略路径 `build/m6b3-ci-phone.log`。约 1 GB 的结果附件未完整下载，按范围读取附件的尝试网络失败，故不把云端截图当作此次证据；依据实际日志、源码分支及两端本机复测。

本地 M6b3 首轮完整单元另外触发旧 `MobileChatRealtimeTests/test停止前台会取消未完成刷新且旧事件不再读取`：iPhone 停止后会话请求数从 1 变为 2，iPad 同轮通过。新增可控阻塞测试 `test停止前台会等待已取消的会话刷新结束` 在旧实现稳定产生两条失败（提前停止与请求数变化），结果为 `m6b3-chat-red.xcresult` / `.log`。模型原来取消刷新后只等待事件监听；现同时等待已取消的同步任务及其子请求结束，再完成前台停止，不吞旧事件或减弱请求数量断言。

范围限定四个文件：`MobileChatModel.swift`、`MobileChatRealtimeTests.swift`、`MobileDDNSUITests.swift`、`MobileDownloadControlUITests.swift`。沿用用户“核实并修复 Apple CI 实际失败”的授权及 main 提交约定，按 gh-fix-ci 指南取证；没有新 PR、分支、凭据操作或云端重跑。验证工作区同时含独立实施中的 M6b3 远程访问增量，二者分开提交。

修复后 `m6b3-build-r4.log` 构建通过。R2 两端完整单元均 **1364 项、4 条既有跳过、0 失败**，新增阻塞测试及原停止测试均通过；两端各四项实际 UI（上述两项云端失败、离开聊天页仍更新摘要、远程访问中文深色大字）全部通过，结果为 `m6b3-phone-r2.xcresult` / `m6b3-pad-r2.xcresult`，均 exit 0。实际命令：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b3-chat-red.xcresult -only-testing:DsmMobileTests/MobileChatRealtimeTests/test停止前台会等待已取消的会话刷新结束 -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b3-phone-r2.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileDDNSUITests/test已有记录保存开关并可取消或确认删除 -only-testing:DsmMobileUITests/MobileDownloadControlUITests/test取消剩余项目后空任务列表仍可查看与清除已结束记录 -only-testing:DsmMobileUITests/MobileChatRealtimeUITests/test离开聊天页后前台仍更新会话摘要 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程中文大字表单和连接风险可操作 -parallel-testing-enabled NO
```

iPad 使用相同测试选择，destination 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，resultBundlePath 为 `apple/Apps/DsmMobile/build/m6b3-pad-r2.xcresult`。本机回归通过不代表包含修复的新云端整轮已通过；未进行真实 NAS 聊天或后台系统验收。

## 2026-10-06 移动 M6b3 远程访问与连接恢复

从 `eec33fbc` 干净 main 开始，先完成无 Mac 网卡/安全/硬件反馈授权依赖的远程访问。Mac 本页只有 QuickConnect 中继和路由器自动配置，原 `saveRemoteAccess` 已按真实结果与 generation 判断；本片不增加 ID 注册、账号绑定或手工端口映射，不改 Mac App、Windows 或 Android 源码。

复用服务设置模型、原生表单/确认及 `service-operations-v1.json`，增量加入远程访问类型和两个步骤。实际请求继续复用原 QuickConnect v3 `get_misc_config/set_misc_config`、Upnp v1 `get/set` 编码；单项读取失败与字段未提供分开，两项均失败显示错误。旧 Mac 方法保持可选读取返回语义，新管理入口传播结构化证书信任错误并提示重新连接；写前遇到该错误零写，不继续自动读取。中继保护来自实际连接端点，不能由草稿伪造；同一逻辑配置重新解析路线可只读恢复，新地址新配置不认领旧记录。恢复文件不新增真实主机、QuickConnect ID、账号、端口或凭据内容。

独立集成与只读对抗复核覆盖固定方法/版本、原值/未提供字段、当前中继保护、伪造原值与草稿、组间权限撤回、逐步回执、部分/未知、未提交后项、认证/TLS 中断、同逻辑配置实际换路、跨配置隔离及既有记录共同恢复。页面只有两个开关，无额外搜索；加载、空内容、正常、错误和不可用分别验证，筛选为空不适用。

验证结果：

- 新增 8 项网络行为测试，`NasServiceFlowTests` 共 24 项，联合原 185 项 NAS 适配器共 **209 项通过**。首轮测试错误地从 HTTP 传输层抛领域 AppError，客户端按传输未知错误处理，导致认证/TLS 测试六条断言失败；改用真实层级的 DSM 106 响应、URLError 和结构化证书错误，保留错误类别与停止后续请求断言，`m6b3-shared-focused-r2.log` 全部通过。
- `swift test --package-path apple --jobs 2` **2789 项 XCTest、172 条既有条件跳过、0 失败；另 12 项 Swift Testing 通过**（`m6b3-shared-full.log`）。Mac Release `m6b3-macos.log` 成功，最终资源后 `m6b3-macos-final.log` 再次成功，实际 `lipo` 为 **x86_64 arm64**。最后提示文案后 AppLanguageTests 为 **6 项 Swift Testing 通过**（XCTest 子集 0），见 `m6b3-localization-final.log`。
- 新增 9 项移动行为测试，服务设置测试共 26 项；三类旧服务与新类别共同执行，原始请求断言保持。移动 R1/R2/R3 构建均通过；R1 两端完整单元各 1363 项、各 4 条既有跳过，iPad 零失败，iPhone 一条旧聊天停止测试失败；本片六项新实际 UI 两端均 **六项全部通过**。旧聊天问题及新阻塞回归、两项云端 UI 修复已单独以 `b5c27caf` 提交，见前节，不混作远程访问失败。
- R4 构建通过，R2 两端完整单元均 **1364 项、4 条既有跳过、0 失败**；各四项 UI（聊天前台、两项云端失败、远程中文深色大字）全部通过。R5 在当前服务 UI 测试中沿用实际导航就绪等待，并把原值变化提示扩展为包含字段可用性变化；最终 R3 两端远程双项保存/取消/回读及中文深色大字 **各两项全部通过**。结果包分别为 `m6b3-phone-r1/r2/r3.xcresult` 与 iPad 同名结果，R1 iPhone 的整包失败如实保留，最终 R2/R3 均 exit 0。
- 最终资源为 Apple **6502**、Android 2188、Windows 3402；双语/参数/引用/硬编码、请求 179+1、私有样本 29/文档引用 48、文档和差异检查通过。XcodeGen 2.46.0 重生成不改变工程内容，继续使用既有工具链、App 身份及派生构建路径。
- 已实际查看浅色 iPhone 双项影响确认/保存结果、iPad 当前中继保护/路由器独立操作，以及两端最终中文深色大字表单/完整确认。七张合成图保留忽略路径 `build/m6b3-preview`；临时导出目录清理，日志/结果包保留。两台模拟器恢复 light；无真实 NAS/路由器写入、Mac 安装/启动或正式发布。

实际主要命令：

```sh
swift test --package-path apple --jobs 2 --filter 'NasServiceFlowTests|DsmNasAdministrationRepositoryTests'
swift test --package-path apple --jobs 2
swift test --package-path apple --jobs 2 --filter AppLanguageTests
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b3-phone-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程访问双项确认取消保存与回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程中继连接保护和路由器独立操作 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程单项读取失败仍可编辑另一项 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程未知记录重启后只读恢复 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程加载空内容错误不可用及恢复 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程中文大字表单和连接风险可操作 -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b3-pad-r3.xcresult -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程访问双项确认取消保存与回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test远程中文大字表单和连接风险可操作 -parallel-testing-enabled NO
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

R1 iPad 与 R3 iPhone 分别使用相同测试选择，替换对应设备 ID 和结果包前缀；R2 完整命令见前节 CI/聊天修复记录。真实 NAS、路由器、证书变化、重新连接与锁屏/辅助功能按主计划四项具体 `PENDING_USER_VALIDATION`，源码未实现的其他 M6/M7/M8 不归入待验。

本片提交前，旧 Apple Build `37300934405` 的 iPad 于 2026-10-05 17:02:57 UTC 结束并失败，整轮已终止。开始读取 iPad 实际日志，不能因 iPhone 修复已本地通过便推定 iPad 同因；远程访问源码与当前环境验收按本节独立交付，完成剩余 CI 故障核对后再正常推送 main。

## 2026-10-06 移动 iPad 云端等待修复与全量测试分组

Apple Build `37300934405`（`83af8606`）现已完整结束并失败。[iPad 作业](https://github.com/yuangy1995/dsm-native-client/actions/runs/37300934405/job/111733215131)执行 1304 项单元、4 条既有跳过，其中一项产生两条失败断言；273 项实际 UI 中五项失败。iPhone 的两项导航失败及聊天停止边界已由上一节修复；共享 macOS 的 DMG 短暂占用另由 `f0432d7f` 修复。不能把任一本机结果写成旧云端已通过。原 iPad 作业日志保留 `apple/Apps/DsmMobile/build/m6b3-ci-pad.log`，无云端截图下载证据。

本次逐项根因与改动：

- DDNS 瞬时动作测试等到持久记录退出请求阶段就断言，但生产模型随后还要刷新并把未知瞬时动作转为可再次显式发起。测试改等可观察的整个操作结束；仍断言未知结果、允许新的显式操作和仅发送一次原请求。
- 语音断网测试错误地把 iPad 弹窗后方录音入口仍然存在视为弹窗已关闭。现等待原发送按钮实际消失、底层入口恢复可点击；仍断言原发送入口不存在且恢复记录恰好一条。生产录音的记录移交与关闭流程保持原实现。
- 下载批量编辑和工作区三项失败均发生在启用模块后立即判断导航布局。与已修复 iPhone 情况一致，测试在原五秒范围内等待实际入口可点击，再选择标签栏、侧栏或系统“更多”；保留全部业务断言及多模块入口覆盖。

原 iPad 的 UI 部分耗时 19864 秒，含构建和上传接近六小时；当前新增功能已使 UI 数量从 273 增至 304。[GitHub 官方托管作业限制](https://docs.github.com/en/actions/reference/limits)为每项六小时，不能仅把 timeout 调高。Apple Build 现保留一个 shared-macos 作业，每台移动设备各两个互补作业：workspace 运行 `MobileWorkspaceUITests`，modules 运行全部单元及其余 UI。工具链、签名、权限、Runner、失败汇总和测试本身的覆盖范围均不变；每组结果附件使用独立名称。没有为触发验证创建分支或 PR。

`xcodebuild -enumerate-tests` 对已构建测试产物实际枚举：完整 **1668 项 = 1364 单元 + 304 UI**；workspace **159 UI**，modules **1364 单元 + 145 UI**。程序比较两个集合互不重叠且并集严格等于全部 1668 项。三份枚举 JSON 与日志位于忽略目录 `apple/Apps/DsmMobile/build/m6-ci-enumeration-{all,workspace,modules}.*`。新增三项工作流回归直接执行工作流里的命令，通过替身记录参数并校验每台设备的完整类覆盖、测试失败退出码 65 原样保留、未知分组零执行并失败；它们不代替 Xcode 实际测试。`python3 -m unittest discover -s tools/release -p 'test_*.py'` **37 项通过**，YAML 解析、双语资源/硬编码（6502/2188/3402）、请求 179+1、私有样本 29/文档引用 48、文档及差异检查通过。

移动 `m6-ci-final-build.log` 构建成功。两端完整单元均 **1364 项、4 条既有跳过、0 失败**。针对五项云端失败的 UI 加六模块导航，两端均 **6 项全部通过**，两个命令均 exit 0。结果包为 `m6-ci-phone-final.xcresult` 和 `m6-ci-pad-final.xcresult`。此次只修改自动化等待和云端分组，没有新的共享/Mac 业务源码变化；其最新完整回归沿用上一节 M6b3 已完成结果，不声称重新执行。独立集成复核确认等待条件覆盖真实完成边界，未增加跳过、放宽结果断言或隐藏失败；测试分组经实际枚举及失败注入校验。包含全部修复的下一轮云端完整结果仍待运行，代码推送不等同门禁通过。

实际主要命令：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci-pad-final.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileChatAudioUITests/test语音发送断网保留记录并关闭原录音发送入口 -only-testing:DsmMobileUITests/MobileDownloadEditUITests/test多选逐项保存清楚显示部分拒绝 -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test条件相册未知重启限制重复创建 -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片偏好未知重启保留恢复入口与保存限制 -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test默认仅文件与App设置并按当前账号筛选开关 -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test管理员六种模块均需开启且设置始终可达 -parallel-testing-enabled NO
python3 -m unittest discover -s tools/release -p 'test_*.py'
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

iPhone 使用相同测试选择，设备 ID 为 `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`、结果包改为 `m6-ci-phone-final.xcresult`。三组实际枚举命令使用相同 iPhone 目标与派生路径，附 `-enumerate-tests -test-enumeration-style flat -test-enumeration-format json -test-enumeration-output-path <对应结果>`；完整组不添加测试筛选，另两组采用工作流对应参数。

## 2026-10-06 移动 M6c1 内存压缩与电源计划

基线为 `b5a7f42c`，main 与 origin/main 一致且工作区干净。对应 Apple Build `37349262879` 的 shared-macos 已通过，四项移动分组仍在运行；Repository Check 与 Documentation & Quality Preflight 已通过。本片先在本地实施，未用推送取消完整云端回归，云端结果不代表本片已被覆盖。

移动内存压缩与电源计划接入既有服务设置模型和版本 1 摘要恢复文件，新增种类与独立提交步骤，不创建平行恢复实现。共享管理方法复用旧 HardwareEditing 的三种实际请求编码；Mac App 源码、旧调用及公开请求版本不变。内存压缩保存和标记重启后生效分步确认/落盘/回读；后步未提交或明确拒绝时允许用户确认后单独继续，必须仍匹配前步目标。过程不发送重启请求。电源计划使用完整草稿和整体保存，保留两数组、200 条、停用条目也不能重叠等规则；NAS 时区参与原配置和最终摘要比较，不以相同时分误认时区变更后的成功。

独立集成与只读对抗复核检查完整快照、缺失/畸形布尔、能力/权限/取消/连接身份异常、写前与回执落盘失败、两步之间配置变化、只读恢复不认领未提交项、跨账号迟到、空清单/截断/冲突/超量、旧 Mac 互斥字段和恢复隐私。新增 15 项 `NasServiceFlowTests`、12 项 `MobileServiceSettingsTests` 及 9 项实际 UI。原完整服务行为测试同步包含两种新设置，未删除断言或新增跳过。

共享首轮编译曾因新增枚举分支未补全而失败，补齐后原 209 项聚焦通过；新增 14 项后的 223 项聚焦一项失败，原因是测试把“空数组但 total=1”错误视为可展示的不完整列表，而现有严格读取应抛错。改为一条有效记录而 total=2，保留不完整清单不能保存及零写断言，223 项通过。随后独立复核增加保存后 NAS 时区改变回归。源码稳定后的 `m6c1-shared-final.log` 为 **2804 项 XCTest、172 条既有跳过、0 失败，以及 12 项 Swift Testing 全通过**。最终 `m6c1-macos-final.log` 为 BUILD SUCCEEDED，`lipo` 实测 `x86_64 arm64`；未安装或启动 macOS App。

移动构建 R1/R2/R3 均成功。首轮两端完整单元各 **1376 项、4 条既有跳过、0 失败**，13 项 UI 中 iPhone 7 项失败、iPad 5 项失败。共同五项电源计划失败的截图显示条目子弹窗可见，但辅助功能树中没有其控件；弹窗原挂在 Form 的惰性子 Section。将呈现状态和 sheet 移至稳定表单根。iPhone 另两项旧读取测试先等待屏外尚未生成的入口，改为先滚动实际 NAS 分类列表，再等待原入口存在且可点击；保留时间、筛选、空内容、缺少接口和加载断言。两端首轮内存压缩的确认/保存、部分结果继续、重启只读恢复及字段不完整限制已通过。R1 失败日志和结果包保留，不把首轮写成全绿。

主要实际命令（结果目录均为忽略的 `apple/Apps/DsmMobile/build/`）：

```sh
swift test --package-path apple --jobs 2 --filter 'NasServiceFlowTests|DsmNasAdministrationRepositoryTests'
swift test --package-path apple --jobs 2
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6c1-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划空清单新增草稿取消和整体保存 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划启停编辑星期移除还原与清空 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划停用条目也不能与相同时间重叠 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划未知保存重启只读恢复 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test中文大字内存与电源确认可取消 -only-testing:DsmMobileUITests/MobileNasReadUITests/test电源计划保留NAS时间并区分停用项目 -only-testing:DsmMobileUITests/MobileNasReadUITests/test空计划与缺少接口分别展示 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

iPad R2 使用同一测试选择，设备 ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包 `m6c1-pad-r2.xcresult`。R1 使用全部九项新 UI 和旧 `MobileNasReadUITests` 的 NAS 时间/空计划/错误重试/中文大字四项。真实 NAS 写入、实际开关机/压缩效果、锁屏/文件保护和完整辅助功能未验证，具体条件、预期及脱敏反馈记在移动主计划 M6c1 的四项 `PENDING_USER_VALIDATION`，不能由合成结果替代。

R2 两端命令均 exit 0：各 **1376 项完整单元、4 条既有跳过、0 失败，加 8 项实际 UI 全部通过**。覆盖首轮全部电源计划失败、两项旧读取失败及原文件服务保存回归。真实截图与辅助功能定位已确认条目编辑器在表单根呈现后可访问，中文大字下完成/取消可用；新增/编辑时分星期、启停/移除/还原/清空、冲突拒绝、保存确认和未知重启恢复都在两端实际执行。截图保留 `m6c1-preview/`，来自合成场景，不含真实 NAS 资料。

末次界面审查将计划开关标签改为既有“启用”资源，避免关闭时标签仍写“已启用”。旧格式空摘要缺少整体保存依据时，空页改为明确读取限制与刷新/DSM 路径，不能提示不存在的添加操作；既有模型/UI 不完整数据测试各补一个空摘要场景，测试数量不变。生成工程由锁定 XcodeGen 再生成前后 SHA256 一致：`dba8141a52f6294d15d5294ec6a51ed29e2fb15a5a4cd30546f678ba3ee7f08a`，未手改工程。

末次 R4 移动构建成功，深色验证实际使用以下命令；两台设备均执行相同单元和两项 UI 选择，结果包分别为 `m6c1-phone-final.xcresult` 与 `m6c1-pad-final.xcresult`：

```sh
xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance dark
xcrun simctl ui A31ABDE2-186F-43DD-8D40-5EB9511A9289 appearance dark
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6c1-phone-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test中文大字内存与电源确认可取消 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源清单不完整和压缩字段未知保留读取与限制
```

最终静态检查通过：Apple 6507/Android 2188/Windows 3402 条双语资源与硬编码扫描、179+1 请求契约、29 组脱敏 Fixture/48 项私有文档引用及文档/差异检查。共享和 Mac 最终回归后只改移动界面/合成场景与其测试，未再次修改共享或桌面源码，不重复宣称这些检查覆盖真实 NAS 行为。

最终两端命令均 exit 0：各 **1376 项完整单元、4 条既有跳过、0 失败，以及 2 项深色实际 UI 全部通过**；其中不完整数据用例实际覆盖非空截断、旧格式空摘要、未知压缩字段三种场景。两端中文大字编辑/确认及浅色保存回读截图均已实际查看，保留 `m6c1-preview/` 的合成截图；辅助功能树导出和临时附件目录已在检查后清理。两台模拟器均恢复浅色并读取确认。此片没有真实 NAS 写入、正式签名发布、安装 macOS 包或变更 Windows/Android 代码。

## 2026-10-06 移动 M6d1 计划任务管理

基线为本地 `886247d3`，main 领先 origin/main 一项已验证提交，初始工作区干净。前一批 Apple Build `37349262879`（`b5a7f42c`）的共享/macOS 已通过，四组移动完整回归仍在运行，本片先完成本地实现，不以新推送取消该轮。任务管理复用已有 TaskScheduler list v3、get/create/set v4、run/set_enable/delete v3 及 EventScheduler result_list/result_get_file v1 编码；没有新增私有 API、请求参数、依赖、权限或 App 身份变化。

新增任务目录搜索/状态筛选、完整脚本草稿、创建/编辑/启停/运行/删除确认、主动查看记录和选中记录完整输入/输出。保存时保留已有日期与重复策略，无法解释的原星期只可原样保留；启用/脚本运行必须绑定用户预览过的完整详情，只有 v3 时仍允许按目标许可停用，非脚本任务仅按显式运行许可操作。运行接受回执不等于脚本成功，不查询历史冒认本次执行。恢复文件只含摘要、数字身份、动作/阶段/回执及创建前编号集合，写前保存、未知不重放、跨账号迟到和损坏保护均保留。

独立集成与只读对抗复核由当前负责人在实现之外执行：检查旧 Mac 请求兼容与新旧入口同目标互斥、原列表/详情双基线、未知开关、未解释星期保留、v3 停用、非脚本许可、接受/缺回执、编号复用、完整输出绑定、确认后的权限撤销、跨连接代次、提交前后取消、存储失败及 TLS 连接身份异常。新增 **20 项 NasScheduledTaskFlowTests、19 项 MobileScheduledTasksTests 和 10 项 MobileScheduledTasksUITests**；没有删除原断言或新增跳过。创建成功的本地记录也必须保留接受回执，不允许损坏记录解除未知操作保护。

共享新增测试最初编译分别因在 XCTUnwrap 自动闭包中 await、ApiCapability 初始化遗漏 requestFormat 失败，修正测试调用后聚焦 203 项通过；补齐 TLS 与预览/版本门后 205 项通过。最终 `m6d1-shared-full.log` 为 **2824 项 XCTest、172 条既有跳过、0 失败，以及 12 项 Swift Testing 全通过**。`m6d1-macos.log` 为 BUILD SUCCEEDED，`lipo` 实测 `x86_64 arm64`。这些结果覆盖最终共享源码，之后仅调整移动界面、测试定位和移动恢复记录校验；未安装或启动 macOS App。

移动构建 R1 成功；R2 因 UI 测试使用不存在的查询属性 lastMatch 失败，改为从可点击按钮中选择当前弹窗后 R3 成功。首轮两端完整单元各 **1395 项、4 条既有跳过、0 失败**。十项 UI 中 iPhone 一项通过、九项失败，iPad 十项失败。封闭结果包导出的真实截图与辅助功能树证实：iPhone 详情已出现，但测试先等待长正文之后尚未生成的操作按钮；iPad NAS 分类列表的中心被主侧栏覆盖，原滑动落在主侧栏，分类列表未滚动。详情去掉重复身份摘要并把操作移到长正文前，测试等详情实际就绪；分类滑动改用其可见区域。没有把内容可见等同于控件已能操作。

R4 构建成功。第二轮两端完整单元仍各 **1395 项、4 条既有跳过、0 失败**。iPhone 十项 UI 都因测试按首行 storage 定位列表、该行滚出后查询失效而失败；iPad 已能进入并完成常规任务操作，中文大字和屏外结果仍暴露弹窗滚动定位问题。后续给 NAS 分类/任务列表/详情表单增加稳定标识，测试在目标尚未生成时滚动当前可见表单，不在弹窗外操作；脚本预览也先滚入可见区域。完整两端复测结果在下文追加，当前中间轮次不能表述为全通过。

主要实际命令（结果路径均为忽略的 `apple/Apps/DsmMobile/build/`）：

```sh
swift test --package-path apple --jobs 2 --filter 'NasScheduledTaskFlowTests|DsmNasAdministrationRepositoryTests'
swift test --package-path apple --jobs 2
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d1-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileScheduledTasksUITests
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

iPad 使用相同测试选择，目标 ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包改为 `m6d1-pad-r2.xcresult`；首轮两端对应 `r1`。当前静态资源检查为 Apple 6568/Android 2188/Windows 3402 条，双语、占位符和硬编码扫描通过；179+1 请求、29 组脱敏 Fixture/48 项私有文档引用、文档与差异检查通过。真实脚本执行、邮件通知、NAS 权限/断网、锁屏文件保护和完整辅助功能未验证，移动主计划列明四项具体 `PENDING_USER_VALIDATION`。Windows/Android 仅登记语义影响，真实 API 环境证据不提升。

R2 iPad 在七项 UI 已结束（四项通过、三项失败）后主动中断：共同滚动定位缺陷已确认，剩余三项留给修正后完整复测。Xcode 结束时因动作日志三十秒内未封闭而 exit 73，因此不把该结果包作为完整测试报告；文本日志及成功导出的首个失败辅助功能树仍保留证据。树中详情 Form 范围为 x=120…700，而原测试在 x=808 滑动，确实落在弹窗外。R5 构建成功，随后两端使用同一完整测试选择重跑，结果路径改为 `m6d1-phone-r3.xcresult`、`m6d1-pad-r3.xcresult`。

R3 两端完整单元均 **1395 项、4 条既有跳过、0 失败**。十项 UI 中 iPhone 九项通过、一项失败，iPad 四项通过、六项失败，两个命令均 exit 65。iPad 测试错误地用容器本身的 isHittable 过滤可滚动 Form；容器可以不可点击、内部按钮仍能操作，测试因此再次回退到弹窗外。改用辅助功能顺序中当前最上层列表，仍要求最终目标存在且可操作，导航栏按实际范围计算遮挡。iPhone 最后一项停在脚本替换，真实录屏显示长按 TextEditor 空白处只移动光标，没有出现全选菜单；按当前 Xcode SDK 的 iOS 键盘输入接口使用系统 Command-A，继续断言完整替换内容，不降低恢复或未知状态断言。新建测试按表单从上到下填写，保留全部字段、确认/取消和回读检查。

详情中的操作结果同时移到按钮下方、长脚本之前，避免用户滚完整段脚本才能看到结果。锁定 XcodeGen 再生成前后工程 SHA256 同为 `bac52963160de70e49b7afb0cb4c1f06487802f17964d41120f2c71bcde8b4b1`。后续定向复测覆盖这些修改、两端最终完整单元及深色中文大字；已通过的共享/Mac 源码没有变化。

R6 构建成功后两台模拟器设为深色。`m6d1-phone-final` 命令 exit 0，完整单元 **1395 项、4 条既有跳过、0 失败**，中文大字、未知运行、权限拒绝、完整新建和编辑重启恢复 **5 项 UI 全通过**。结合 R3，十项新 UI 均已有 iPhone 通过证据。`m6d1-pad-final` 完整单元同为 **1395 项、4 条既有跳过、0 失败**；中文大字、未知运行、权限拒绝和完整新建四项通过，启停/运行/删除链在脚本预览定位失败，最后的编辑恢复未执行完。该用例出现多次六十秒的模拟器动画等待；实际截图显示编辑页和未知操作记录仍在，但测试把滚动定位到了背景侧栏。主动结束该轮，Xcode 动作日志未及时封闭而 exit 73，不把最后一项或整轮记为通过。

嵌套详情和确认页有相同的脚本字段标识，且全局列表枚举顺序不能代表当前弹窗。最终自动化使用确认页/编辑页/详情页/目录的明确标识，在同一表单内查找和滚动，确认页补唯一容器标识；不再按全局第一个字段或最后一个列表猜测。iPad 文本替换沿用既有表单测试的末尾点击/退格方式，合成单行原值和最终完整文本继续严格断言；iPhone 保留已通过的系统全选。重新启动专用 iPad 模拟器后 R7 构建成功，继续深色定向复测两项编辑/嵌套流程及完整单元，不修改业务请求或降低未知恢复断言。

R6 使用相同完整单元选择，iPhone 的五项 UI 为中文大字、未知运行、权限拒绝、完整新建和编辑恢复；iPad 另加启停/运行/删除链。最终 R7 的实际命令：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d1-phone-focused.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test中文大字编辑与脚本风险确认可取消 -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d1-pad-focused.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test启停运行删除各自确认且运行只显示请求已发送 -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复
```

R7 两端完整单元仍各 **1395 项、4 条既有跳过、0 失败**。iPad 两项定向 UI 全通过，命令 exit 0，启停/运行/删除链 133 秒，编辑未知重启恢复 155 秒；十项新 UI 至此均有 iPad 通过证据。iPhone 中文大字通过，但系统全选快捷键在该轮未选中文本，输入被追加，完整值断言准确拦下，命令 exit 65。最终将单行合成输入统一为已在 iPad 通过的末尾点击/退格，生产源码不再变化；R8 构建成功，只补跑受影响的 iPhone 搜索替换和编辑恢复，保留此前完整单元与所有业务断言：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d1-phone-input.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复 -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test目录五态筛选和未知开关
```

R8 的目录五态/搜索替换通过，编辑用例的完整文本断言发现 iPhone TextEditor 点击后光标仍在原值开头，故该命令 exit 65。最终只对这个已复现的文本输入场景使用方向键明确移至单行原值末尾，再退格输入；普通文本框和 iPad 沿用已通过的方式。R9 构建成功，下列最后一项补验 **通过、命令 exit 0，耗时 143 秒**，没有新增跳过或绕过文本/持久恢复断言：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d1-phone-editor.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复
```

本片十项新实际 UI 在 iPhone/iPad 均有通过证据，不能把多个轮次说成单轮十项全绿，也不代表全部既有 UI 已在本地重跑。最终业务源码的两端完整单元各 1395 项（4 条既有跳过）、共享 2824 项 XCTest（172 条既有跳过）及 12 项 Swift Testing、Mac 双架构均已通过。浅色保存/确认、两端深色中文大字编辑/确认与恢复截图在 `m6d1-preview/` 保留并实际检查；两台模拟器均已恢复浅色并读取确认。真实 NAS 执行、通知邮件、权限/网络、锁屏及完整辅助功能仍按移动账本验收。

结束本片时，上一批 Apple Build `37349262879` 的共享/macOS 与 iPhone-workspace 已通过；iPhone-modules 返回 1364 项单元通过（4 条既有跳过）、145 UI 中 9 项失败，iPad-workspace 也返回失败，iPad-modules 尚运行。新失败的日志/附件另行排查，本片未推送的代码不在该云端运行中，也不能以本机通过覆盖这些云端失败。

最终静态检查再次通过：6568/2188/3402 条双语资源及硬编码扫描、179+1 请求契约、29 组脱敏 Fixture/48 项私有文档引用、文档与差异检查。本片临时辅助功能树、录屏提帧及导出日志已清理；正式测试结果与十二张合成预览保留。新增云端失败的证据保留在独立忽略目录继续排查，没有混入提交或据此声称云端通过。


## 2026-10-06 Apple 分组回归完整结果与后续排查

M6d1 本机交付后，Apple Build `37349262879`（`b5a7f42c`）全部结束，结论失败。共享/macOS 与 iPhone-workspace 通过；iPhone-modules 的 1364 项单元通过（4 条既有跳过），145 项 UI 中 9 项失败；iPad-modules 同为 1364 项单元通过（4 条既有跳过），145 项 UI 中 7 项失败；iPad-workspace 的 159 项 UI 中 15 项失败。总计 31 个设备/用例失败，不代表 31 个独立根因。分组均在各自作业时限内完成，不能将这些失败归为六小时超时，也不能通过取消或跳过用例消除。

下一修复基线为本地 main 的 `34fb9d6e`，另有此前 M6c1 提交尚未推送。当前修复集中于这些失败所涉及的自动化呈现和输入边界，生产侧仅为账号子弹窗补稳定的辅助功能标识。源证据为三个已结束作业的原日志及结果包；分析行号时先核对 `b5a7f42c` 对应源版本，不能套用本地后续已变化的行号。

已确认的排查入口：iPhone 的账号创建/群组确认、四项 NAS 读取导航、存储分析导航及区域页导航；iPad 工作区十四项导航可操作等待与一项目录上传入口；iPad 模块的中文麦克风拒绝、账号保护/群组/恢复、下载剩余项/横屏和代理保存。按精确时间重新提帧后，iPad 导航等待末尾的侧栏和文件内容均已显示；早期默认关键帧中的读取进度层不代表失败时刻，不能用它推断导航被加载遮挡。仍需以实际按钮的可操作状态为准。账号群组用例的失败辅助功能树已经回到列表并显示更新后的说明，但组变更和确认缺失的原因尚未确定；密码用例显示两次输入不匹配，保持一致性检查，不根据掩码字符数量猜测明文。

后续逐项核对实际界面、输入焦点、呈现与完成边界，再执行两端对应回归；保持全部权限、确认、输入一致性和未知结果断言，不增加跳过。完整结果和修正将在同一节继续记录。日志/附件只包含隔离合成场景，保存在忽略目录 `apple/Apps/DsmMobile/build/m6d1-ci-evidence/` 及同前缀日志中；完成排查后清理临时附件。


本轮单一修改范围为共用的 UI 测试导航辅助、上述失败所在的测试类、账号子弹窗标识、合成密码请求检查、锁定工具生成的移动工程及本节记录。现有 NAS 请求、权限、危险确认、密码一致性和持久恢复规则保持；仅凭页面可见、掩码长度或旧结果不能让用例通过。导航辅助收敛原先多处重复的标签/侧栏判断，使用实际 Button，保留可点击断言并留出第二次云端快照的时间；失败附当前层级与截图。四项 NAS 读取的屏外等待已有 M6c1 本地修正，本轮改用稳定分类列表标识，避免首行滚出后查询失效。

账号自动化先在当前群组弹窗操作并断言开关实际选中、返回草稿中包含成员，再要求原风险确认；说明替换不再依赖三击恰好选中整句。密码仍通过真实安全输入控件和系统建议关闭流程输入，合成服务额外要求收到指定测试口令，不能只凭两次错误输入相同而通过。上传在实际目录清单准备完成后才点击，保留文件/目录结果与重启断言。新增文件读取等待时仍可打开本机设置的 UI 回归；这些调整尚待本机执行结果。


本机 R1 的 iPhone 命令 exit 0：完整单元 **1395 项、4 条既有跳过、0 失败**，**11 项 UI 全通过**（九项原云端失败，加读取等待导航和六模块导航）。iPad 命令 exit 65：完整单元同样 **1395 项、4 条既有跳过、0 失败**，24 项 UI 中 **23 项通过、一项代理输入失败**。最后一个失败并非代理保存出错：精确提取的 40.787 秒画面显示地址已清空、灰色占位提示可见、保存被正确禁用；新加的空值断言误将辅助功能返回的占位提示当作残留输入。该断言按既有 TextField 模式识别空值或占位提示，随后仍严格比较完整输入和保存回读结果。

R1/R2 构建均成功；最后仅调整上述测试断言的 R3 构建也成功。没有变更真实代理保存逻辑或把未知结果当成功。新合成密码模式已在 iPhone 界面实际提交并通过，群组开关选中、返回草稿和风险确认的增强断言两端通过；iPad 目录上传准备、十五项工作区原失败、另外六项模块原失败也均通过。最后针对共用 iPad 输入辅助的代理、文件服务和终端三项继续补验。

本轮实际移动构建与 R1 测试命令如下；Xcode 为锁定的 26.6（17F113），两台模拟器系统为 26.5，结果均在忽略的构建目录中：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci2-phone-r1.xcresult -parallel-testing-enabled NO \
  -only-testing:DsmMobileTests \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test创建账号密码不匹配不能保存且成功后显示新账号' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test账号编辑群组选择保存取消及删除确认' \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test共享访问使用当前账号列表且未知权限不当可写' \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test电源计划保留NAS时间并区分停用项目' \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test空计划与缺少接口分别展示' \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test系统活动搜索能显示与清除无匹配状态' \
  '-only-testing:DsmMobileUITests/MobileNasStorageUITests/test空间分析显示未知容量和重复文件结果' \
  '-only-testing:DsmMobileUITests/MobileRegionUITests/test手动日期选择可取消再确认保存' \
  '-only-testing:DsmMobileUITests/MobileRegionUITests/test明确权限拒绝不报告保存成功' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test文件读取等待时仍能打开本机设置' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test管理员六种模块均需开启且设置始终可达'
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci2-pad-r1.xcresult -parallel-testing-enabled NO \
  -only-testing:DsmMobileTests \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test所选照片创建临时分享并设置公开范围' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test新格式部分完成只能补关闭提示' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test条件相册中文建议搜索空结果与选择人物' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test条件相册共享目录选择与空子目录导航' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片全局部分完成重新打开保留剩余修改' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片删除中文大字确认和剩余操作仍可触达' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片后台任务清除记录和打开原目标' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片批量原件交给系统文件面板并能取消' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片智能分类权限与空内容错误和加载状态' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片目录批量删除确认包含照片和文件夹' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片目录目标加载失败等待空内容与取消' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片资料标签读取等待失败与空内容' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test目录上传在活动中显示逐项成功且重启保留' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test相似批量拆组中断重启后不重发并能取消剩余项' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test自动预览设置未知重启后禁止再次保存' \
  '-only-testing:DsmMobileUITests/MobileChatAudioUITests/test麦克风拒绝中文深色大字给出设置入口且不发送' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test当前账号保护和未知所属组仍可查看' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test账号编辑群组选择保存取消及删除确认' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test资料保存未知后重启只读恢复' \
  '-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test取消剩余项目后空任务列表仍可查看与清除已结束记录' \
  '-only-testing:DsmMobileUITests/MobileDownloadEditUITests/test中文深色大字选择和结果支持横屏' \
  '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test文件读取等待时仍能打开本机设置' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test管理员六种模块均需开启且设置始终可达'
```


R3 构建后的 `m6-ci2-pad-services` 三项补验均在完整文本断言失败，命令 exit 65：预期 `8080`、`0`、`65536` 分别得到 `08080`、`00`、`065536`。按零容差提取的录屏显示 iPad 浮动数字键盘正覆盖输入框，清空后重复点击原输入框位置恰好落在数字 `0` 上。这是自动化新增的坐标误触，不能修改端口校验或忽略前导字符来掩盖。最终去掉清空后的重复点击，保留原焦点和分步清空检查，再输入新值；业务源码保持不变。R4 构建后使用相同三项选择再次验证。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci2-pad-services-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test终端端口校验Telnet风险及保存回读
```

上一轮命令只有结果路径为 `m6-ci2-pad-services.xcresult`，测试选择完全相同。共享/Mac 源码在这次 CI 修复中没有变化，沿用 M6d1 的完整共享测试与双架构构建证据，不把它们称为本轮重新执行。


R4 构建成功；`m6-ci2-pad-services-r2` 中文件服务、终端两项通过，代理一项失败（exit 65）。端口完整值 `8080` 此时已通过断言，但浮动数字键盘仍在，底部完成按钮被弹出层拦截；随后测试点击被遮住的保存位置又敲入数字 `1`，失败树显示 `80801`，因此确认页未出现。最终在仍有数字弹出层时点击编辑器标题栏内的空白处，等待该层真正关闭，再使用明确的完成按钮；收起前后都比较完整文本，代理用例另要求保存按钮可用且可点击。该处理只修正真实录屏中已发生的测试动作，不改变产品表单或输入规则。


**最终 R5 构建与两端三项服务 UI 全通过，两个测试命令均 exit 0。** iPhone、iPad 各完成代理地址/端口、文件服务端口、SSH/Telnet 端口的校验、确认取消、保存回读和相关停用流程。结果分别为 `m6-ci2-phone-services-final.xcresult` / `m6-ci2-pad-services-final.xcresult`；真实命令如下：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci2-phone-services-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test终端端口校验Telnet风险及保存回读
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci2-pad-services-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test终端端口校验Telnet风险及保存回读
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

至此上一云端 31 个设备/用例失败均有对应本机通过结果。R1 的 iPad 首轮仍如实保留为 23/24，不改写成单轮全绿；最后的辅助只影响服务表单测试，其三项最终两端全通过，未重跑其他已通过的 1395 项单元或共享/Mac 测试。五次本轮移动构建均通过，双语资源 6568/2188/3402 条及硬编码检查、179+1 请求契约、29 组 Fixture/48 项引用、文档/差异检查通过。锁定 XcodeGen 2.46.0 再生成前后工程 SHA256 同为 `0c284895030dd5365cf0bd379636256c7e396fe7f9b1aaa6c9e9ed078d47030c`。

独立差异复核确认生产侧只有两个账号子弹窗的辅助功能标识，另有仅合成环境的精确密码检查；当前授权、密码一致性、危险确认与未知状态保护未削弱，没有改变工具链、身份、权限或协议。真实两端账号创建、代理确认/关闭截图保留于 `apple/Apps/DsmMobile/build/m6-ci2-preview/`，已实际检查相关画面，两台模拟器恢复浅色并读取确认。新云端整轮须在推送本批 main 后取得真实结果，不能由本地通过推定。M6 余项、M7/M8 和具体真实 NAS 待办继续按移动主计划推进。

本轮临时云端结果下载、辅助功能树、录屏提帧和测试选择文件已按独立目录清理；正式本机日志、结果包与上述五张合成预览保留。


## 2026-10-06 移动 M6d2 连接管理与即时电源

基线为 main 的 `c622d6ca`，与远端一致且开始时工作区干净。完成连接目录/筛选/详情、服务与当前网页连接的具体后果确认、关机/重启独立确认、请求接受与未知状态、跨 App 重启只读恢复及新登录后的明确恢复操作。复用 CurrentConnection v1 与 System v3 的既有请求，Mac 旧调用继续原签名和语义；未自动操作真实 NAS。Windows/Android 只登记兼容影响。

新增记录为独立 `NAS/system-actions-v1.json`，仅保存账号上下文、目标/会话摘要和动作阶段；系统保护并排除备份，不保存账号、地址、连接标识或会话原文。连接断开前重新读取完整目录、核对全部原目标信息及当前管理员权限；部分目录、缺标识、受保护目标、明确拒绝、证书异常与记录失败均不误报成功。电源接受只说明请求被接受，不轮询或推断最终执行；未知不重发，同会话重启不能解除限制，新会话还需明确设备恢复确认及当前权限/info 读取。已批准恢复存储范围内新增，不迁移登录结构，回滚关闭新增入口并保留记录。

初次共享定向编译因测试使用了不存在的请求类型失败，修正为实际 `send(URLRequest)` / body 边界。第二次 200 项定向测试出现 6 条失败：测试直接抛 AppError 被真实 APIClient 包装成一般传输错误，无法表达所需的 NAS 明确拒绝和传输故障；改为真实 105 响应、CancellationError、URLError 超时/证书和结构化证书变更错误，不改产品判断或降低断言。最终定向 200 项全通过；完整共享 **2839 XCTest，172 条既有条件跳过，0 失败，另 12 Swift Testing 通过**。新增 15 条系统操作请求/互斥/断连测试。

移动初次构建因确认源访问 MainActor 模型缺少隔离声明失败，补充 MainActor 并修正 Swift switch 表达式位置后，后续两次构建通过。R1 两端完整 **1413 单元，各 4 条既有条件跳过，0 失败**；新增 18 条覆盖真实适配器、部分/缺标识目录、权限撤销、替换目标、未知与接受后离线、跨账号迟到回执、损坏/无法写入记录、明文不落盘及电源恢复。macOS Release x86_64/arm64 构建通过。完整共享与 Mac 源码已覆盖本片共享改动。

```sh
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d2-phone-r1.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileSystemActionsUITests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d2-pad-r1.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileSystemActionsUITests
```

R1 界面测试最终 iPhone 5/9 通过、4 失败，iPad 7/9 通过、2 失败，两个命令 exit 65。失败对应以下两个测试场景问题：新增 nas-system 合成模式未纳入既有持久测试目录选择，导致重启用例拿到新的临时目录；实际 App 使用 application 恢复根，不受这个合成分类遗漏影响。iPhone 从系统页底部寻找连接入口时只向下滚动，未先回到分类列表。已补合成模式的隔离持久目录与保留参数，以及手机回到列表顶部后按顺序定位的动作；没有放宽风险确认、记录保护或结果断言。另在复核中补上电源恢复入口对当前读取状态的要求、恢复时权限撤销即时禁用及清记录的当前账号校验；这些移动末次更改尚待 R2 重新构建、完整单元和相关 UI 覆盖。


R1 导出的实际截图确认 iPad 重启后已有新目录、旧动作记录缺失，与合成模式目录选择遗漏一致；中文大字当前连接确认的风险正文、取消和确认按钮均可见。独立只读对抗复核进一步发现共享日期解析使用当前设备时区，缺原始标识的相似连接不能因时间解释变化被认定为已消失。新恢复判断不再用连接时间排除该类相似项，记录同时去掉不再需要的时间摘要；写前完整目标预检仍比较当次原始目标信息。新增共享回归和移动重启输入验证“无标识＋时间变化”保持未知且只有一次原写入。因本次实际共享改动，重新执行完整共享测试与 macOS 双架构构建，而非沿用前次结果。

R4 移动构建包括合成目录、手机向上返回定位、末次移动权限/恢复检查、时间边界及双语恢复提示修正。R2 将在两台模拟器深色下重新运行完整单元和本片九项实际 UI；R1 已保留浅色通过截图。当前尚无 R2 结果，不能把修正源码当作通过证据。


R4 移动构建已通过；时间边界修正后的完整共享 **2840 XCTest / 172 条既有跳过 / 0 失败，另 12 Swift Testing 通过**，日志 `m6d2-shared-final.log`。R2 两端完整 **1413 单元 / 各 4 条既有跳过 / 0 失败**。界面复测仍在运行；时间边界改动后的 macOS Release 双架构末次构建已通过（`m6d2-macos-final.log`）。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance dark
xcrun simctl ui A31ABDE2-186F-43DD-8D40-5EB9511A9289 appearance dark
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d2-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileSystemActionsUITests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d2-pad-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileSystemActionsUITests
```


R2 终态为两端 **完整 1413 单元（各 4 条既有跳过）和 9 项新增实际 UI 全部通过，命令均 exit 0**。覆盖服务/当前网页连接独立确认、关机接受、未知断开重启只读恢复、未知电源同会话保护与新登录恢复的取消/确认、权限拒绝、低电源版本不阻塞连接、部分/缺标识/受保护目标及五类页面状态。浅色和深色、中文大字截图均实际导出并复核，确认正文及取消/确认按钮可见；恢复后的旧电源记录仍显示此前未知，而非伪造完成。Mac 末次主 App 与 File Provider 二进制也由 `lipo -archs` 核对为 x86_64/arm64。

最后的权限复核补充：当前管理员检查失败时，即使列表仍可读取，也不能据此把旧未知断开标记为已完成；必须保留原保护，恢复权限并重新取得完整目录后才能结算。新增第 19 条移动行为回归覆盖权限撤销、可读空目录、恢复权限后只读完成和唯一原写；修改仅移动模型与测试，不涉及共享/Mac。R5 构建与两端完整单元、未知断开/明确拒绝两项 UI 定向复测继续验证此边界，其他已通过 UI 不重复。


**最终 R5 构建、两端完整 1414 单元（各 4 条既有条件跳过）及两项定向 UI 全部通过，命令均 exit 0。** 新的权限撤销恢复回归保持旧记录，重新取得权限和完整目录后只读完成，累计仍只有一次原写。最终新源码由 19 条移动行为、16 条共享流程及九项双端实际 UI 覆盖；末次仅移动模型的更改又完整运行两端单元，并重复未知断开恢复及明确拒绝两项 UI，不重复未变化的共享/Mac 或其他已过 UI。最后两端均处于浅色。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d2-phone-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileSystemActionsUITests/test未知断开重启后只读恢复且不能重发或清记录 -only-testing:DsmMobileUITests/MobileSystemActionsUITests/test权限拒绝不显示连接成功或电源接受
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6d2-pad-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileSystemActionsUITests/test未知断开重启后只读恢复且不能重发或清记录 -only-testing:DsmMobileUITests/MobileSystemActionsUITests/test权限拒绝不显示连接成功或电源接受
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

双语资源/硬编码检查为 6612/2188/3402，179+1 请求契约、29 组 Fixture/48 项引用及文档/差异检查通过。两端中文大字深色确认、连接重启恢复、电源恢复保留旧未知的截图已实际查看，预览保留在 `apple/Apps/DsmMobile/build/m6d2-preview/`；截图仅使用合成环境，不冒称真实 NAS。独立集成及只读对抗复核已完成，本片没有修改 Mac/Windows/Android App、签名、权限、最低系统或登录格式，没有真实 NAS 写入。接口的非原子目标预检及真实电源/连接行为保留在主计划具体 PENDING_USER_VALIDATION。


锁定 XcodeGen 2.46.0 再生成工程前后 SHA256 均为 `7683582c35e9dcb762d2fcff3f7e3a5e041cc22ab97670ae12c281a1861f6bcf`。两端模拟器已恢复浅色并读取确认；本片临时附件导出、辅助功能树及录屏目录已精确清理，正式日志/结果包和九张合成预览保留。提交前读取远端 main 与本地基线一致，无远端新提交。前一批 Apple Build 仍有四个移动组运行、共享/macOS 已通过；本片先作语义完整的本地提交，等待这轮完整云端结果后再正常推送，不用推送取消它，也不把本机通过写成新云端已通过。后续继续 M6 套件及其余管理、M7/M8，整体目标尚未完成。


## 2026-10-06 移动 M6e1 套件设置与来源

基线 `7bd01c78`，main 领先远端一个 M6d2 提交，工作区开始时干净；前一批完整云端移动回归仍运行，未推送取消。M6e 拆为设置/来源、已安装控制、安装/更新/SPK 三项完整流程；本片只实现第一项及已安装列表入口。Mac 套件停止把未知状态当停止的基线分支已提出范围决定，未修改 Mac App，也未开始依赖该决定的控制片；不阻塞本片独立工作。

新增移动套件列表/筛选、设置摘要和原生编辑器、默认位置、通知、测试版显示、全局/按套件自动更新、来源添加/编辑/移除。自动安装与来源信任/HTTP 风险各自确认；普通通知保存直接由明确按钮提交；单位置不显示选择器。来源与设置读取独立，未知单套件策略不能补为关闭后覆盖整表。Shared 复用 Setting/Feed v1 与 Package list v2 的原编码、互斥和旧 Mac 签名，新增管理快照与写前/接受回执检查点；丢回应不重发，明确拒绝不被后续匹配缓存覆盖，接受后的读取拒绝保持原写未知，证书异常透传。

新增 `NAS/package-operations-v1.json` 仅保存账号上下文、原/目标设置或来源的摘要、阶段和接受标记，不保存来源名称/地址、明细或会话。系统文件保护并排除备份；写前记录失败零请求，未知跨页面阻止重复，重启只读恢复。来源改地址必须同时看到新目标和旧地址消失，移除不能凭部分目录完成；管理权限失效不结算旧未知记录。该存储属于既有 M0–M8 授权，不迁移登录结构，回滚停用新入口并保留记录。Windows/Android 仅登记影响。

初次原有 31 项套件测试通过；新增定向回归首次共 46 项、11 条失败，其中 10 条因新 MutationResult operation 使用了格式不允许的点号，另 1 条为测试对固定版本不可用错误类别的预期与既有 call 行为不符。改为稳定驼峰操作名，类别按已有 apiUnavailable 行为断言，同时保留低版本零请求/不降级与独立来源读取检查；第二轮 46 项全通过。初次本地化扫描指出两处动态拼接资源键，改为现有枚举的明确键映射后通过，资源为 6630/2188/3402。

随后补充默认位置缺省合法/错误类型拒绝、保存后新增手动更新套件不改变既有自动更新清单，以及丢回执时相同选择的恢复。核对依据是实际发送的最新/重要自动更新清单，不能把无关新增手动套件造成的目录变化变成永久未知。完整共享最终已取得 **2857 XCTest（172 条既有条件跳过、0 失败）及 12 Swift Testing 通过**；来源地址校验收敛到同一既有规则，末次 48 项定向回归通过。再次对照契约，附加信息组保持原 `silent_upgrade/autoupdate/status`，不把响应子字段猜作新请求选择器，并增加精确请求断言；这一末次 48 项参数/流程复测已通过。

移动五次 build-for-testing 均已通过；首个聚焦模拟器命令执行 21 项行为测试通过。增加自动更新清单回归后，R1 两端完整 **1436 单元，各 4 条既有条件跳过、0 失败**。11 项新界面测试正在分别运行，iPhone 浅色、iPad 深色；默认位置界面断言已出现失败，尚待完整结果与实际画面定位，不能称界面全过。实际命令如下：

```sh
swift test --package-path apple --jobs 2 --filter 'NasPackagePreferenceFlowTests|DsmPackageCenterTests'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-unit-first.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobilePackageCenterTests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-phone-r1.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageCenterUITests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-pad-r1.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageCenterUITests
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
```

第一轮及清单判断修正后的 Mac Release 构建均通过；上述末次选择器调整后的最终增量构建也已通过，日志为 `m6e1-macos-final-r2.log`。当前未访问真实 NAS 或外部来源，所有交互测试均使用显式合成模式。


R1 两端均为 **11 项界面中 8 通过、3 失败，exit 65**。失败证据逐项确认：默认位置失败树为 `Default install location, Volume 2` 的组合标签，实际画面已显示 Volume 2 和保存成功；不能按单独 `Volume 2` 节点定位。搜索失败树的值仍是 `no-match`；来源替换录屏在实际 41.898/42.995 秒显示输入框被打入箭头符号，随后只删掉部分符号和原文本。根因是测试把 `XCUIKeyboardKey.rightArrow.rawValue` 交给 typeText，当正文输入；已改为既有用例采用的 typeKey 实际方向键，保留清空检查、完整新值断言及恢复列表断言。生产搜索、地址校验、保存/删除保护没有因此放宽。

第一轮中文大字、五类读取/缺能力、单套件自动更新确认、明确拒绝、普通保存、未知来源重启恢复、未知策略/部分来源/读取独立及未知设置恢复均有两端通过证据。R6 构建后定向复验三项失败、普通设置，以及互换浅深色的中文大字确认；同时两端完整单元覆盖最新已记录选择器请求。临时附件与视频只保留在本片检查目录，完成提取后清理。


R2 的 iPhone **完整 1436 单元（4 条既有跳过）及五项定向 UI 全部通过，exit 0**；来源新增/编辑/移除已完成，三项首轮失败都有 iPhone 通过结果。iPad 完整 1436 单元同样通过，中文大字浅色和默认位置两项 UI 已过；搜索用例连续方向键事件后，XCTest 多次报告 `App animations complete notification not received`，每步等待约 60 秒，实际截图仍为可见的 no-match 输入和正常无匹配页面。确认该进程仍在运行后主动中止这一停滞测试，未把中止当通过；命令最终 exit 73。iPad 的搜索、普通保存及来源完整流程尚待后续定向完成。

已仅将本片测试的 iPad 文本清空改为项目既有的点击输入框可见末尾后删除；iPhone 保留已经通过的 typeKey 处理。清空、新值、完整地址校验、来源信任/HTTP/删除确认和保存结果断言保留，不关闭动画或改变产品交互。R7 构建后仅补 iPad 剩余三项；无业务源码改变，不重复已过单元、共享或 Mac。


R7 构建通过；iPad 三项补验中普通保存和来源新增/编辑/移除通过，搜索在点击输入框最右侧后没有取得键盘焦点，输入事件直接拒绝，命令 exit 65。来源替换同一点击策略已经通过；本次只改搜索的短查询重聚焦为点击输入框本身，继续保留清空检查。R8 构建通过，单独复验 iPad 搜索；其他已通过结果不重复。没有因此修改产品筛选、输入校验或请求实现。


**最终 iPad 搜索单项已通过，exit 0；本片十一项界面均有两端实际通过结果。** R1 的两个 8/11、iPad R2 中止、R7 搜索未获焦点均保留原结论，不改写成整轮全绿。最新完整单元为两端各 1436 项（各 4 条既有跳过），业务源码不再变化；仅测试定位/输入修正按受影响场景复验。两端中文大字来源信任确认的浅/深色和来源移除结果已实际查看，预览保留于 `apple/Apps/DsmMobile/build/m6e1-preview/`。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test中文大字来源信任与未加密风险可取消 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test多位置可以选择并保存默认安装位置 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test套件和来源搜索无匹配后清除可恢复原目录 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test普通设置单位置隐藏选择器且取消保存结果正确 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test来源地址校验信任取消以及新增编辑移除
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-pad-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test中文大字来源信任与未加密风险可取消 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test多位置可以选择并保存默认安装位置 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test套件和来源搜索无匹配后清除可恢复原目录 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test普通设置单位置隐藏选择器且取消保存结果正确 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test来源地址校验信任取消以及新增编辑移除
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-pad-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test套件和来源搜索无匹配后清除可恢复原目录 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test普通设置单位置隐藏选择器且取消保存结果正确 -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test来源地址校验信任取消以及新增编辑移除
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-pad-search-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test套件和来源搜索无匹配后清除可恢复原目录
```

八次本片移动构建通过；锁定 XcodeGen 2.46.0 再生成前后工程 SHA256 同为 `e20b3c421ffe4ac97ede7fbcd4af281accab32c4613f5c5924c170c3b246bf56`。最终 Mac 主 App/扩展二进制均由 lipo 核为 x86_64/arm64；两台模拟器恢复浅色并读取确认。独立集成与只读对抗复核覆盖权限/目标、当前字段类型、旧账号回执、记录损坏/写失败、原来源改址、API 真实选择器、明确拒绝/接受后失败、未知不重放和快照不保存原文。未操作真实 NAS 或外部来源，真实风险按本片主计划四项 PENDING_USER_VALIDATION 验收。

收尾时前一批 `c622d6ca` 云端出现明确结果：[Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37386239845) 共享/macOS 与 iPad 工作区通过，iPhone 工作区 160 项中 159 通过、1 失败，两个模块组仍运行。失败为 Office 预览→分享→文件选择器用例：关闭分享面板后点击导入，等待 Cancel 未出现。仅日志尚不足以判定是面板过渡、控件定位或产品呈现问题；先读取该次界面证据，不放宽断言、不推送取消剩余整组。此失败基于前一批提交，不混作 M6e1 新界面结果。

本片模拟器临时附件、辅助功能树和录屏提帧目录已精确清理；正式日志/结果包与七张合成预览保留。新云端失败证据另行隔离保存供后续排查，尚未宣称其已修复。


## 2026-10-06 Office 云端系统面板等待修正

修复基线为已完成并本地提交的 `166143c2`，main 工作区干净，前两波尚未推送，以保留正在运行的完整云端模块组。[前一批 Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37386239845) 的 iPhone 工作区 160 项中只有 `testOffice预览并交给系统分享及文件选择器` 失败；iPad 工作区与共享/macOS 已通过，两个模块组尚未结束。

原日志显示分享面板关闭后直接点击导入，随后全局查找 Cancel 超时。已读取该云端结果包：失败辅助功能树包含系统 DocumentManager 的导航栏、Cancel、Recents/Shared/Browse 和 No Recents；所以不能断言产品未打开选择器。录屏请求 45.5 秒取得实际 44.683 秒的白色画面，也不足以证明系统远程界面已经完成可交互呈现。没有改动 Office 保存、权限、文件数据或产品面板代码。

唯一代码修改为该界面用例：等待分享面板真正消失，确认实际导入按钮可用/可点击；导入后先等待已观察到的系统选择器导航栏，再在它的范围内查找并点击 Cancel，最后确认选择器已消失且编辑状态仍在。保留 Quick Look 正文、分享文件名、系统选择器与返回状态全部断言，没有新增跳过或静默降级。两端定向复验尚在准备中，不能把修正源码当作云端已通过。


首轮定向构建通过，iPhone 用例通过；iPad 失败树显示系统选择器已就绪，但“取消”在系统侧栏，并不在文件导航栏内。已保留导航栏作为选择器就绪标志，取消按钮改为就绪之后查找可见、可点击且可用的实际按钮，不将 iPhone 的控件层级套到 iPad。没有改变系统面板或业务代码，继续双端同用例复验。


最终两端同用例均通过，两个 test-without-building 命令 exit 0；Quick Look 正文、系统分享文件名、选择器出现/取消/退出与原编辑状态全部有实际通过证据，系统选择器截图已查看并保留在 `apple/Apps/DsmMobile/build/m6e1-office-preview/`。本次仅 UITest 修改，没有重复无变化的 1436 项单元或共享/Mac；相应完整证据沿用 M6e1。两次定向构建均通过，文档与差异检查通过。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-office-ci-phone-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileWorkspaceUITests/testOffice预览并交给系统分享及文件选择器
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e1-office-ci-pad-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileWorkspaceUITests/testOffice预览并交给系统分享及文件选择器
```

首轮两个命令只有结果路径少 `-final`，iPhone 通过、iPad 的取消按钮作用域失败保持原记录。云端旧提交的 iPhone 工作区仍为失败，必须等含本修正的后续云端运行确认，不把本地复验当云端已绿。当前两个模块组仍在运行，继续等待完整结果，不通过推送取消它们。

此次已读云端结果包、临时导出/层级/录屏提帧均已按独立目录清理，正式 CI 日志、本地结果与上述两张模拟器截图保留。


## 2026-10-06 移动 M6e3 套件安装、更新与手动上传

起始基线 `26391a5d`，main 工作区干净、领先远端三个已完成本地提交；旧云端两个模块组仍在运行，未通过推送取消。M6e2 Mac 套件停止反馈与此前三处 Mac 设置反馈仍等待对应范围决定，本片没有修改 Mac App、Windows 或 Android。

本片复用共享目录/计划/上传/安装/取消管线，新增兼容观察检查点；移动目录分类/搜索/详情、依赖与位置确认、许可及原生选项、系统文件选择器、下载/安装进度、受保护摘要记录已接。写前重新授权和保存阶段，接受及每项完成保存失败停止下一副作用；证书和读取权限失败不通过备用读取覆盖，清理或取消只提交一次。恢复文件不含 NAS 任务标识、路径、来源 URL、选项口令或会话，不自动重放跨重启请求或未提交依赖。共享旧 Mac 方法保持调用方式，必要结果文案同步中英。

共享初次原 31 项回归通过；新增 16 项后两轮各 47 项全通过。再补取消时下载恰好完成仅清理本次暂存、状态超时后目录证书错误立即停止，完整共享为 **2875 XCTest、172 条既有跳过、0 失败，另 12 Swift Testing 通过**。随后独立审查补上分步安装最终 check 返回占用/位置变化拒绝，新增一条回归；这一最后共享变化尚需最终复测，不把此前全量当作最新源码证据。

移动首轮 build-for-testing 失败，仅为新测试构造 NasPackage 时漏了必要可选字段；补齐测试参数后第二次构建通过。首轮聚焦安装与原套件设置/来源行为 **43 项通过**。第三次构建通过并包含十项新 UITest；R1 正在两端执行完整单元、十项安装 UI 及原有普通设置 UI，iPhone 浅色、iPad 深色。iPhone 完整单元已取得 **1457 项、4 条既有跳过、0 失败**，完整两端界面结果仍待收齐。

初次本地化命令误用了不存在的 validate_localizations.py，退出 2、没有执行检查；改用项目既有 check_localization.py 后 **6639/2188/3402** 双语、占位符、资源引用与硬编码扫描通过。独立审查随后补上旧账号视图的冻结会话边界与选项键盘完成按钮，需下次移动构建/界面复验；不能将正在运行的 R1 二进制视作已经包含这些修正。

已实际执行的命令：

```sh
swift test --package-path apple --jobs 2 --filter DsmPackageCenterTests
swift test --package-path apple --jobs 2 --filter 'NasPackageInstallationFlowTests|DsmPackageCenterTests'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-phone-unit-r1.xcresult -only-testing:DsmMobileTests/MobilePackageInstallationTests -only-testing:DsmMobileTests/MobilePackageCenterTests -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-phone-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageInstallationUITests -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test普通设置单位置隐藏选择器且取消保存结果正确 -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-pad-r1.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageInstallationUITests -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test普通设置单位置隐藏选择器且取消保存结果正确 -parallel-testing-enabled NO
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
```

本片未访问真实 NAS、套件来源或付费服务。正式真机验收表与最终交付状态将在两端实际结果及独立复核收齐后更新；当前不能把未完成验收写成全部通过。


R1 两端完整单元均为 **1457 项、4 条既有跳过、0 失败**。iPad 十项新界面与一项原设置回归全通过（11/11，exit 0）；iPhone 10/11 通过，唯一失败为中文大字确认按钮定位（exit 65）。该次失败截图显示确认按钮完整可见，辅助功能树中弹窗表单占满剩余区域，按钮框 y=756.7、高 63.7；后台标签栏仍存在于层级，测试却扣除其 90 点，把按钮中心误判在可见范围之外。修正为只有可点击的实际标签栏才扣除高度，保留按钮存在、可用和可点击断言，未修改该页布局。

已查看 R1 iPhone 许可选项浅色、iPad 中文大字依赖确认深色，以及上述失败截图。选项已有值时原 TextField 只显示值而隐藏字段名称，现补上始终可见的字段标签和无障碍名称；在下一轮两端实际 UI 中同时检查标签和原输入控件。系统文件选择器两端均实际出现并可取消；SPK 上传/选项/安装走真实共享适配的合成行为测试，未在系统选择器内选择真实用户文件。

独立复核另补最终位置变化、直接上传的证书错误映射、原账号文件选择/确认隔离、目录能力缺失时独立手动上传与摘要恢复、同版本异步接受不得认领完成，以及新准备失败清除旧成功页面。最新完整共享 **2877 XCTest（172 条既有跳过、0 失败）与 12 Swift Testing 通过**，日志 m6e3-shared-final.log；Mac 初次与最终 Release 构建均通过。R4 移动构建通过，R5 为固定输入字段标签再构建；最新二十七项移动安装行为测试和最终两端 UI 尚待执行。


**M6e3 最终 R2 两端均 exit 0：各 1463 单元（各 4 条既有条件跳过、0 失败）及全部 10 项新 UI 通过。** 新增的 27 条移动行为均在完整目标测试中执行；R1 两端各通过的旧套件普通设置 UI 保留回归证据。R2 为 iPhone 深色、iPad 浅色，中文大字确认、许可字段固定标签、依赖及版本完成、未知重启恢复均已实际检查截图；预览存于 `apple/Apps/DsmMobile/build/m6e3-preview/`，不是真实 NAS 验收。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-phone-r2.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageInstallationUITests -parallel-testing-enabled NO
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-pad-r2.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobilePackageInstallationUITests -parallel-testing-enabled NO
```

R1 编译失败、R2–R5 四次构建通过；首轮 iPhone 中文大字唯一失败不改写成通过。最新共享完整 2877 XCTest/172 跳过/0 失败与 12 Swift Testing，Mac 最终 Release 构建通过，主 App/扩展由 lipo 实核 x86_64/arm64。XcodeGen 2.46.0 再生成前后工程 SHA256 同为 `51b9bf600474760a65d0445c0b55438263f1bd5831e19b2716c3cbd92d4a1449`；两台模拟器均恢复浅色并查询确认。最终本地化 6640/2188/3402、请求 179+1、脱敏 fixture 29/引用 48、文档和差异检查通过。

收尾时，前一批云端 iPhone 模块组已返回 **164 项中 160 通过、4 失败**，均位于 DownloadInventory、NasStorage 两项和 ScheduledTasks 的模块导航步骤；iPad 模块组仍在运行。失败日志已读，正在提取原始合成结果包的界面证据，不提前归因为产品或测试，不把 M6e3 本机通过当作旧云端已绿。此前 Office 唯一工作区失败已有独立本机修复证据。本片只完成安装切片，M6e2、网卡/安全/硬件与 M7/M8 仍不算完成。


## 2026-10-06 Apple 模块组的导航准备、聊天合成列表与表单定位修正

起始基线 `1d7deb14`，main 工作区干净、领先远端四个已完成提交；没有其他人的未提交改动。[前一批 Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37386239845) 已完整结束：共享/macOS、iPad 工作区通过；iPhone 工作区 160 项中 1 项 Office 系统选择器等待失败，已由 `26391a5d` 独立修复并两端本机通过。两个模块组各 164 项、各 4 项失败，本片逐项读取对应原日志、辅助功能树及合成录屏，未通过取消或跳过回避结果。

| 原云端失败 | 实际证据与修正范围 |
| --- | --- |
| iPhone 下载中文深色大字、卷/存储池详情、硬盘未知重启、计划任务中文大字；iPad 公告恢复、部分电源清单 | 四项 iPhone 现场及 iPad 公告失败均仍在设置页，NAS/下载/聊天开关为 0，目标导航入口未出现；部分云端快照只有 Application 根，不能把根快照解释成 App 崩溃。改为从稳定标识的 Toggle 定位实际开关，完成一次按下/抬起，先断言可操作和开启值 1，再使用既有公共导航等待；失败保留开关现场。不新增重试点击、跳过或放宽后续业务断言，也不声称已证明系统漏掉事件的根因。 |
| iPad 移除发送记录后消息消失 | 失败树已回到聊天页，只剩最初两条合成消息。合成服务只在单条回读中返回刚发送的消息，普通列表刷新仍委托给初始数据；生产发送/删除逻辑未改。修正 Debug fixture 的列表、频道/线程范围和分页，保留读取失败场景；新增真实 Repository 回归，断言移除本地记录后列表仍包含原消息且其他聊天不混入。实际 UI 增加主动刷新后消息仍在的断言。 |
| iPad 电源计划未知保存 | 原失败使用“包含结果行的 CollectionView”作为滚动容器；结果行尚未在惰性表单中出现时，容器查询失效。原树仍有电源编辑表单、禁用保存及读取失败说明。改用已有稳定表单标识选择当前滚动容器，保留未知提示、不能重复保存及重启只读恢复全部断言。 |

本机原代码先运行八个云端失败用例：第一批四项在两端全部通过；第二批 iPhone 四项通过，iPad 三项通过，电源未知保存复现同一容器查询失败（exit 65）。不能把其余本机通过当作云端已修复。结果包分别为 `m6e3-ci-{phone,pad}-baseline.xcresult`、`m6e3-ci-{phone,pad}-baseline2.xcresult`，均位于忽略的移动 build 目录。

本次唯一 App 目录源修改为 `#if DEBUG` 合成聊天服务；其余为正式单元/界面测试及验证文档。没有改生产功能、真实请求、会话/文件存储、资源、权限或 Mac/Windows/Android。独立差异复核保留原业务断言、唯一发送和未知保护，没有为云端改宽任何产品权限或固定能力门。

定向构建通过。R1 正在两端运行完整单元及十三项 UI：八项原失败、聊天发送完整四态（含已计入原失败的一项）、中文大字内存/电源与文件服务端口编辑。未完成的结果不记为通过。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```


R1 两端完整单元各 **1464 项、4 条既有跳过、0 失败**，新增“记录移除后列表刷新仍保留消息”测试通过。R1 开始界面阶段后，整行 Toggle 外层点击未开启聊天，新增开启值断言两端直接失败；外层辅助功能框包含整行而不是实际拨动控件，不能采用该点击点。主动中止余下界面批次，保留失败与中止状态，不将整轮称为通过。最终修改为在实际内层开关上按住 0.15 秒后松开，仅一次手势，不自动重试；保持开启值断言及失败附件。


R2 iPhone **13/13 UI 通过、exit 0**；iPad **12/13 通过、exit 65**，仍为电源未知结果的滚动定位。此次原始云端异常查询已消除，但辅助功能将禁用表单标为不可点击，选择器因 `isHittable` 排除了仍可滚动的编辑器，退回整个 App。已查看 R2 录屏实际 108.672 秒画面及事件：弹窗横向范围 120–700 点，测试却在 x=808 点滑动，结果提示始终在折叠区域以下。只移除滚动容器的可点击条件，按稳定且存在的最上层表单选择区域，实际按钮的可点击/可用及结果断言保持。该修改将随 Photos 权限修复的移动构建，在两端重跑四项受影响服务设置 UI；其余 R2 已通过的场景无需重复。


R2 的真实定向命令如下；R1 同组额外执行 `-only-testing:DsmMobileTests`，使用各自 `-r1.xcresult` 结果路径，并保留上述中止结果。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-ci-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileDownloadInventoryUITests/test中文深色大字详情可阅读缺失速度保持横线 -only-testing:DsmMobileUITests/MobileNasStorageUITests/test卷与存储池详情区分明确状态并可以返回 -only-testing:DsmMobileUITests/MobileNasStorageUITests/test硬盘未知结果重启后只恢复状态 -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test中文大字编辑与脚本风险确认可取消 -only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶中断重启仅恢复原操作 -only-testing:DsmMobileUITests/MobileChatSendUITests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源清单不完整和压缩字段未知保留读取与限制 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划未知保存重启只读恢复 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test中文大字内存与电源确认可取消 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6e3-ci-pad-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileDownloadInventoryUITests/test中文深色大字详情可阅读缺失速度保持横线 -only-testing:DsmMobileUITests/MobileNasStorageUITests/test卷与存储池详情区分明确状态并可以返回 -only-testing:DsmMobileUITests/MobileNasStorageUITests/test硬盘未知结果重启后只恢复状态 -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test中文大字编辑与脚本风险确认可取消 -only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶中断重启仅恢复原操作 -only-testing:DsmMobileUITests/MobileChatSendUITests -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源清单不完整和压缩字段未知保留读取与限制 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划未知保存重启只读恢复 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test中文大字内存与电源确认可取消 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读
```


**最终受影响的四项服务设置 UI 在 iPhone、iPad 均通过。** 该补验与下述 Photos 专项共用 `photos-access-{phone,pad}-final.xcresult`，两个命令均 exit 0；精确命令与新增专项测试数分开记在 Photos 条目。本片十三项场景均已有两端实际通过证据，iPad R2 的 12/13 与 R1 的中止仍保留原结果。聊天移除记录后主动刷新、两端电源恢复的截图已检查，保留于 `apple/Apps/DsmMobile/build/m6e3-ci-preview/`。

本地化 6640/2188/3402、文档及差异检查通过。两个临时云端结果包和本片全部导出/层级/录屏提帧已精确清理；正式 CI 日志、本地结果和四张合成预览保留。两台模拟器恢复浅色并读取确认。新云端须由包含修正的后续 main 推送取得，不把旧失败或本机通过写成云端成功。


## 2026-10-06 Photos 独立授权与移动保存会话恢复

用户明确授权修正 Mac 的旧 Photos/File Station 入口权限绑定，并检查 iPhone/iPad；当前 main 基线为前述 CI 修复 `668ea51`。本片只修改 Photos 入口权限读取、必要登录装配/认证反馈及移动保存会话恢复，不扩张其他 Mac 管理反馈范围，不修改 Windows/Android 实现。

Mac 的 `WorkspaceModuleAccessReader.resolve` 原来直接令 photos 等于 files，旧注释把正式 Synology Photos 当作文件视图，确与 `WorkspaceView` 当前入口不符。现在照片按已有 UserInfo/Setting.User/Setting.Admin/Setting.TeamSpace 的 `access()` 独立确认；文件授权或文件能力不决定照片授权，照片拒绝/缺能力不被文件权限覆盖。权限读取使用独立 Repository 实例，不清空正在使用的照片工作区缓存；照片会话失效接入既有重新登录反馈。接口、凭据传递、存储和 App 身份均未改变。

iPhone/iPad 的入口与会话装配原本已独立读取 Photos；进一步检查发现 `restore` 无条件要求文件列表成功，导致仅有 Photos 权限的账号不能恢复已保存登录。现仅在文件权限/能力明确受限时，由 Photos 自身成功读取证明会话可恢复；Photos 拒绝或失效继续失败，文件认证/证书/网络错误与取消不改用 Photos。原保存会话删除条件、连接代次、账号隔离和后续具体操作权限均保留。跨 NAS 文件传输仍使用自身文件授权条件。

Mac 新增六项权限回归，扩展原有照片撤权与 Photos-only 初始偏好用例。首次聚焦 20 项中 1 项失败：新测试用未带 DSM 119 的通用 AppError，却期待既有 119 专用提示；按真实会话失效数据补齐 119/HTTP 200，断言不降低。随后聚焦 **20/20 通过**；完整共享/Mac **2883 XCTest、172 条既有跳过、0 失败，另 12 Swift Testing 通过**。Mac Release 构建通过，主 App 与 File Provider 实际二进制均核为 x86_64/arm64。

移动新增五项行为测试：两项授权/缺能力/撤权偏好、三项保存会话恢复与安全失败。最新构建通过；iPhone、iPad 最终各 **1469 单元、4 条既有条件跳过、0 失败**，以及 **5/5 UI 通过，两个命令 exit 0**。其中一项新 UI 使用已有合成普通账号权限组合，确认“文件应用 false、Photos enabled”可开启并浏览照片，反向组合不出现照片开关和导航；另四项是前述服务设置滚动修正回归。iPhone 深色与 iPad 浅色截图均实际查看，保留于 `apple/Apps/DsmMobile/build/photos-access-preview/`；不把合成 UI 当作真实 NAS 或完整恢复登录的实机证据。

实际命令：

```sh
swift test --package-path apple --jobs 2 --filter WorkspaceModuleAccessTests
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/photos-access-phone-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片入口独立于文件应用授权 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test中文大字内存与电源确认可取消 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源清单不完整和压缩字段未知保留读取与限制 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划未知保存重启只读恢复
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/photos-access-pad-final.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片入口独立于文件应用授权 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test中文大字内存与电源确认可取消 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源清单不完整和压缩字段未知保留读取与限制 -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test电源计划未知保存重启只读恢复
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

最终本地化 **6640/2188/3402**、请求契约 **179+1**、脱敏 fixture **29 组/48 项引用**、文档与差异检查均通过。未新增文件或更改工程清单，不需要重生成工程。独立集成与只读安全复核覆盖入口/登录恢复调用链、照片只读实例隔离、文件/照片相反授权、缺能力、已知拒绝、证书/会话/取消、权限撤回与本机偏好。两台模拟器已恢复浅色并查询确认；临时附件、辅助功能树和录屏提帧已清理，正式日志/结果包与预览保留。

真实普通账号的相反权限组合、权限撤回、保存登录恢复仍按[专项 PENDING_USER_VALIDATION](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-06-photos-入口权限专项审计)执行；Agent 未访问或写入真实 NAS，没有提高任何环境证据等级。仍继续 M6 剩余独立切片与 M7–M8，未把本片权限修复表述为整体完成。

## 2026-10-06 移动 M7a 容器控制与活动详情

起点 `cdc889cc`，main 与 origin/main 一致且工作区干净。当前负责人单独修改移动容器控制/恢复、权限及组合根、活动详情、共享容器管理增量、正式测试、双语资源和相关文档。Mac App、Windows、Android 源码未修改；共享沿用原 Container v1 请求，旧 Mac 方法兼容。当前[Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37413207539) 的共享/macOS 已通过，四个移动工作区/模块组仍在运行，未连续推送取消这轮全量。

实际能力为单项/多项启动、停止、重启，具体服务中断确认、逐项目结果、未知跨进程只读恢复、普通套件账号授权和已有活动记录正文/用户/时间及容器资源字段。详情按可用宽度与文字大小适配，不照搬桌面四列。容器/映像/网络删除、映像拉取、网络创建和 VMM 仍在后续切片；没有把未实现项列为待真机验证。

共享新增 7 项真实适配器测试，容器聚焦共 **41 项、0 失败**；完整 `swift test --package-path apple --jobs 2` **2890 项 XCTest、172 条既有跳过、0 失败，另 12 项 Swift Testing 通过**。早期过窄筛选仅执行 2 项，不作为全容器覆盖。Release macOS 及最新资源增量构建均通过，主 App 和 File Provider 扩展实际为 x86_64/arm64；未打包、安装或启动 Mac App。

```sh
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/PlugIns/LanStashFileProvider.appex/Contents/MacOS/LanStashFileProvider
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

首轮移动编译因 catch 中局部 error 遮蔽模型属性而失败，修正为 `self.error` 后 R2–R7 构建通过；首轮本地化扫描不识别动态拼接键，改显式 switch 后通过，最终新增 32 对资源键。工程由固定 XcodeGen 2.46.0 生成，不直接编辑工程文件。

移动测试轮次保留如下：

- **R1**：两端各运行 38 项聚焦单元（18 项新控制、4 项容器展示、16 项模块权限），各 1 项失败：取消后尚未提交的批次后项错误标为失败；修正取消分支，后项改为未执行。首项中文大字 UI 两端均失败：iPhone 的 ForEach 上 sheet 未稳定呈现；iPad 原四列布局使详情位于屏幕外、宽度为零。已查看实际失败图、辅助功能树和输入事件；改稳定 VStack 承载确认、按实际宽度与动态文字选择单页/分栏。主动中止余下 UI，两个命令最终 exit 73，不能记成整轮通过。首轮过早导出结果包的 Info.plist 尚未完成，等待测试进程退出后导出成功。
- **R2**：两端各 18 项新增行为与两项实际 UI（中文大字确认、非管理员启动）全部通过、exit 0。已实际查看两端确认截图：iPhone 深色、iPad 浅色，风险正文、目标及取消/停止按钮完整可见。
- **R3**：两端完整单元各 1488 项、4 条既有跳过，各 1 条失败：旧活动投影测试仍禁止正文/用户，已经不符合本片授权范围。更新为精确字段集合与五项实际值断言，保留只读清单协议没有写方法的断言，不删除测试或降低安全门。此轮全部十项新容器 UI 与既有六模块开关 UI 继续执行，终态另记。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileContainerControlTests -only-testing:DsmMobileUITests/MobileContainerControlUITests/test中文大字停止确认按钮和正文完整可用 -only-testing:DsmMobileUITests/MobileContainerControlUITests/test普通套件账号可以启动并查看结果
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-pad-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileContainerControlTests -only-testing:DsmMobileUITests/MobileContainerControlUITests/test中文大字停止确认按钮和正文完整可用 -only-testing:DsmMobileUITests/MobileContainerControlUITests/test普通套件账号可以启动并查看结果
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-phone-r3.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileContainerControlUITests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test管理员六种模块均需开启且设置始终可达
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-pad-r3.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileContainerControlUITests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test管理员六种模块均需开启且设置始终可达
```

独立集成及只读对抗复核覆盖套件权限和撤权、原 ID/名称/运行快照、项目托管、状态缺失、重启时间、同名替换与改名、逐项落盘、损坏/写失败、明确拒绝、未知恢复、取消后剩余项以及跨账号迟到。记录采用完整文件保护并排除备份，只保存摘要和阶段，不持久化名称、正文或凭据。测试通过真实 DsmServiceManagementRepository 与合成网络服务执行，Agent 未访问或写入真实 NAS；[具体设备待办](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-06-m7a-容器启停重启与活动记录)不提高真实证据等级，也不以尚无真实验收静态关闭已实现入口。

R3 最终两端均 exit 65。十项容器 UI 中 iPhone 7/10、iPad 8/10 通过，既有六模块开关 UI 两端通过。除上述旧单元断言外，失败为两端批量结果文字计数、两端活动用户文字定位，以及 iPhone 错误恢复场景。已从精确用例导出附件并检查录屏帧/辅助功能树：批量页两项都为 Started；活动详情显示 `User, Sample user` 组合标签且正文完整；iPhone 错误场景实际已呈现容器列表，合成服务把首次并发失败给了其他分区。修正为按包含完成状态的两行逐项断言名称、按真实组合标签核对用户并补返回动作；合成失败固定给 Container.list，不改变生产网络行为。没有放宽结果、数量或恢复断言。实际页面另把 `info` 作为标题的旧细节改为本地化活动标题，并去掉重复分组标题；因此重建后完整重跑十项容器 UI。

**R8 构建与最终 R4 两端测试均 exit 0：每端 1488 单元（4 条既有条件跳过、0 失败）及全部 10 项新容器 UI 通过。** 18 项新控制行为、一项新增套件授权测试及更新后的完整活动字段断言均包含于整轮。实际 UI 覆盖普通账号启动、停止确认/取消/重新确认、重启、两项批量逐行结果、未知跨进程恢复、活动正文/用户与返回、加载/空/错误/恢复/筛选空、托管及缺字段限制、中文大字和横竖屏。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-phone-r4.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileContainerControlUITests
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-pad-r4.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileContainerControlUITests
```

截图复核另发现横屏 `app.screenshot()` 附件出现旋转后的窗口裁切；项目既有聊天 UI 已使用 `XCUIScreen.main.screenshot()` 处理同类采集问题。本片复用该方式，仅更改测试截图帮助方法，R9 构建通过，不改生产布局或断言。两端重新运行旋转用例均 exit 0，实际查看完整设备截图，两端横屏详情及返回竖屏确认正常；旧裁切图已替换，不作为产品布局缺陷。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-phone-rotation.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileContainerControlUITests/test旋转后容器详情和确认仍可操作
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7a-pad-rotation.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileContainerControlUITests/test旋转后容器详情和确认仍可操作
```

最终 XcodeGen 2.46.0 再生成前后工程 SHA256 同为 `7224e543b29b36691571b9cb32f4420fc0fc5bdb3efd59e67830435df0eb273d`。`python3 tools/localization/check_localization.py` **6672/2188/3402**、`python3 tools/request-contract/validate_contracts.py` **179+1**、`python3 tools/contract-validation/validate_fixtures.py` **29 组/48 引用**、`python3 tools/codex/generate_api_reference.py --check`、文档和差异检查均通过。构建/正式结果包保留在忽略的 build 目录；最终两端确认、批量结果、活动详情、重启恢复和横屏预览共十张，位于 `apple/Apps/DsmMobile/build/m7a-preview/`。两台模拟器均恢复浅色并查询确认；本片临时附件、层级、录屏、提帧脚本和诊断图已精确清理。

本片无第三方依赖、最低版本、App 身份、系统权限或登录格式变更，没有真实 NAS 操作。提交前重新读取 origin/main，远端没有新提交；既有云端四个移动组仍运行，先本地提交本片，继续后续独立工作，避免推送取消唯一完整云端运行。整体 M6–M8 尚未完成，下一片为容器映像搜索/下载及恢复，不把未开发删除/网络/VMM/系统扩展记为仅待设备验收。

## 2026-10-06 移动 M7b 映像搜索、下载与恢复

基线为 `27bd34c6`（M7a 已完成本地提交，远端仍为 `cdc889cc`）。本片实现过程记录如下，最终状态在后续结果区补齐，不能把定向测试代替全部界面验收。源码范围、原任务恢复格式和五端边界见[移动主计划](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-06-m7b-映像搜索下载与恢复)。

- 共享沿原 Image/Registry v1 请求，新增摘要恢复与 willSubmit/accepted/rejected 检查点；旧 macOS 调用继续共用同一请求/状态/删除互斥。无回执不猜任务，原回执按原类型保存；恢复以回显目标摘要、原生完成标记和完整映像列表共同判定。移动受保护存储与账号隔离、可见时轮询、原生搜索/标签/记录均已接入。
- 初始 `swift test --package-path apple --jobs 2 --filter ContainerImagePullTests` 通过旧 16 项；新增 9 项后 25 项通过，再补证书错误停止链路后最终 26 项通过。日志依次为 `m7b-shared-initial.log`、`m7b-shared-focused.log`、`m7b-shared-focused-final.log`。最终 `swift test --package-path apple --jobs 2` 为 2900 项 XCTest（172 条既有跳过、0 失败）和 12 项 Swift Testing 通过，日志 `m7b-shared-full.log`。
- Mac Release 通用构建通过，主 App 和 File Provider 二进制实际核实均有 x86_64/arm64；没有安装、启动或发布包。日志 `m7b-macos-build.log`。
- 移动首次构建发现模型 catch 内两处错误变量遮蔽属性，修为 `self.error`；R2/R3 构建通过。新增 16 项移动行为测试在 R1 两端均通过；两项定向 UI 中中文大字下载两端通过，普通选择标签下载两端失败于最终目标断言。导出截图证实用户已选 stable 后返回页面却显示 latest，根因为标签页重新出现时重复执行加载并应用默认值。修复为首次进入加载、返回保留选择，重新读取时也只在原选择不可用时设置默认值；补返回后的完整标签值断言，没有放宽最终下载目标检查。R1 两端均 exit 65，保留真实失败。
- 本地化第一轮通过：Apple 6689、Android 2188、Windows 3402。请求契约 179 个 fixture/1 个结果示例、私有 fixture 29 组/引用 48 项、文档和 diff 检查通过。最初误用了不存在的三个校验脚本路径，退出 2 未执行检查；随后按仓库实际路径重新运行上述检查，不将失败调用记为通过。

实际验证命令（设备 ID 分别为 iPhone `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`、iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，均为授权隔离模拟器）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=<设备ID>' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7b-<phone或pad>-r1.xcresult -only-testing:DsmMobileTests/MobileContainerImagePullTests '-only-testing:DsmMobileUITests/MobileContainerImagePullUITests/test搜索选择标签下载完成并移除记录' '-only-testing:DsmMobileUITests/MobileContainerImagePullUITests/test中文大字下载按钮与风险说明可用' -parallel-testing-enabled NO
swift test --package-path apple --jobs 2 --filter ContainerImagePullTests
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

R4 移动构建通过后，R2 两端运行完整 `-only-testing:DsmMobileTests` 和整组 `-only-testing:DsmMobileUITests/MobileContainerImagePullUITests`。每端 1504 项单元（4 条既有跳过）出现一处旧页面资源键集合失败：新增下载入口的 `mobile.containers.pull.title` 未加入精确预期集合；已补齐该键，保留集合完全相等检查。R2 两端均 exit 65，仅此单元失败；全部八项新增 UI 两端均通过，分别耗时 475.560/465.037 秒。

本轮再次通过本地化 6689/2188/3402、请求契约 179/1、私有 fixture 29/48、API 参数目录一致性和文档检查。API 目录检查曾误用不存在的脚本路径退出 2，随后使用 `python3 tools/codex/generate_api_reference.py --check` 正式通过；二进制核对曾误用中文显示名作为路径失败，随后根据实际产物对 `LanStash.app/Contents/MacOS/LanStash` 及内嵌 `LanStashFileProvider.appex` 成功核实双架构，不将失败路径视为构建失败或有效验证。

R5 移动构建通过，仅补旧单元预期键，未改变业务或 UI。R3 重新运行完整移动单元，两端各 1504 项（各 4 条既有条件跳过、0 失败）均 exit 0；R2 的八项实际 UI 保持最终源码证据，不重复无变更界面测试。没有新增跳过或降低断言。本片未写入真实 NAS，不将模拟器结果提升为私有 API 行为验证。

最终移动单元命令如下，iPad 将目标替换为上方对应 ID，结果包/日志前缀替换为 `m7b-pad-r3`；R2 命令另加 `-only-testing:DsmMobileUITests/MobileContainerImagePullUITests`：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7b-phone-r3.xcresult -only-testing:DsmMobileTests -parallel-testing-enabled NO
python3 tools/codex/generate_api_reference.py --check
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/PlugIns/LanStashFileProvider.appex/Contents/MacOS/LanStashFileProvider
```

锁定 XcodeGen 2.46.0 再生成前后工程 SHA-256 同为 `f0868d2e28f0f675a96cb5afdf16a3202131d5dc63d115118419167cc054c219`。实际查看两端中文大字、非默认 stable 标签、横屏，以及 iPhone 恢复/搜索错误、iPad 无回执保护页面截图，未发现本片布局遮挡。正式合成预览保留在 `apple/Apps/DsmMobile/build/m7b-preview/`；一次性 `m7b-inspection` 目录中的失败截图、录屏、层次文本和导出清单已清理，日志和结果包继续忽略。两台模拟器恢复浅色。

独立集成与只读对抗复核及四项具体 `PENDING_USER_VALIDATION` 见移动主计划。真实下载成功、各版本 1202、权限/锁屏/网络与完整辅助功能仍需用户在专用环境验收；Agent 未写 NAS。没有修改 macOS App、Windows 或 Android 源码，没有签名发布、移动分发或安装 Mac 包。M6 剩余、容器创建/删除、映像删除、网络及 VMM/M8 继续后续实现，不计为仅待真机。

## 2026-10-06 移动 M7c1 映像删除与恢复

基线为 `d2b9311c`；M7a/M7b 已在本地 `main` 提交，远端仍为 `cdc889cc`，没有创建分支。macOS 通用删除反馈的列表消失兜底可能覆盖明确拒绝/未提交，已记录源码证据并单独请求授权；映像路径原本已关闭该兜底，本片继续独立实现，不修改 Mac App。源码、安全及持久化范围见[主计划 M7c1](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#2026-10-06-m7c1-映像删除与恢复)。

- 共享新增固定原目标的删除请求、摘要恢复、逐项结果和写前/接受/拒绝检查点；旧 Mac 与移动共用 Image.delete v1 编码、占用预检及完整列表回读。恢复仅依赖映像读取，标签换 ID 仍未知；明确拒绝不被后来外部删除覆盖，已完成请求编号不能再写同标签。下载/删除的原标签和裸映像交叉保护保留。
- 初始聚焦 42 项通过（旧映像筛选 16 项及下载 26 项）；新增 12 项删除恢复测试后聚焦 54 项通过。随后完整 `swift test` 为 2912 项 XCTest（172 条既有跳过、0 失败）及 12 项 Swift Testing 通过。日志为 `m7c1-shared-initial.log`、`m7c1-shared-focused.log` 和 `m7c1-shared-full.log`。
- Mac Release 构建通过；实际主 App 与内嵌 File Provider 均由 `lipo -archs` 核为 x86_64/arm64。没有安装、启动或打包发布；日志 `m7c1-macos-build.log`。
- 移动 R1/R2 构建通过。R1 两端各 18 项新增行为测试与两项定向 UI（中文大字、两个标签确认/取消后删除并保留其他标签）均通过，两端命令均 exit 0。实际查看两端中文确认截图，目标、风险与按钮完整；iPad 附件额外记录 `UIKitToolbar` 加入 `UIHostingController.view` 的布局警告，不能以通过状态忽略该警告。改为页面内 `.safeAreaInset` 底部操作，并显式设置最终删除按钮红色；R3 构建通过，后续完整移动单元与全部 UI 结果见下方。
- 静态检查通过：Apple 6704、Android 2188、Windows 3402 条资源，双语/参数/引用/硬编码无问题；请求 fixture 179/结果示例 1、私有 fixture 29/引用 48、API 参数目录及文档/差异检查通过。

实际命令（两端设备 ID 与 M7b 一致；R1 仅选择 18 项新单元及上述两项定向 UI）：

```sh
/tmp/lanstash-release-1.0.15.1x6wUX/generator/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
swift test --package-path apple --jobs 2 --filter 'ContainerImageDeletionTests|ContainerImagePullTests|DsmServiceManagementRepositoryTests/test镜像|DsmServiceManagementRepositoryTests/test容器映像'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7c1-phone-r2.xcresult -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileContainerImageDeletionUITests '-only-testing:DsmMobileUITests/MobileContainerImagePullUITests/test搜索选择标签下载完成并移除记录' '-only-testing:DsmMobileUITests/MobileContainerImagePullUITests/test无回执下载重启后保持保护且不能重发' -parallel-testing-enabled NO
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/codex/check_documentation.py
git diff --check
```

iPad R2 替换目标为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包为 `m7c1-pad-r2.xcresult`。R2 两端均 exit 0：每端 1522 项完整单元（4 条既有跳过、0 失败），九项删除 UI 与两项下载回归均通过。两端删除整组耗时 420.717/414.643 秒，含下载回归的十一项共 539.722/530.231 秒。R2 日志没有再出现 UIKitToolbar 警告，删除组附件仅 PNG，没有首轮的警告说明。未进行真实 NAS 删除，不提升私有 API 环境证据。

截图复核另发现重启后的通用名称误用容器资源键，显示 `Container 1/2`。已新增双语“映像”编号，改用正确资源键，并在原部分删除重启用例补上 `Image 1/2` 的实际界面断言；不改业务或恢复数据。R4 移动构建和最终 Mac 资源增量构建通过。R3 两端仅复跑该用例，均 exit 0（64.889/65.192 秒）；最终截图已实际确认显示 Image 1/2。完整单元与其余 UI 保留 R2 证据，不重复无变化场景。最终本地化为 Apple 6705/Android 2188/Windows 3402，完整性和硬编码扫描通过。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7c1-phone-r3.xcresult '-only-testing:DsmMobileUITests/MobileContainerImageDeletionUITests/test部分删除跨重启只恢复剩余结果' -parallel-testing-enabled NO
```

XcodeGen 2.46.0 最终再生成前后工程 SHA-256 同为 `eacbffdfabb194090fde67b6d075c3055d6a85d0ef58ef6ffb1128ebcdb2720b`。实际查看两端中文大字/红色删除按钮、横屏确认、最终重启结果，以及 iPhone 部分完成/下载保护、iPad 裸映像确认。当前合成预览保留在 `apple/Apps/DsmMobile/build/m7c1-preview/`，重启结果图已替换为 R3；不保留仍含错误通用名称的旧未知结果预览。逐轮正式日志与结果包继续忽略，不提交测试生成物。

本片独立集成/只读对抗复核与四项具体 `PENDING_USER_VALIDATION` 已记入移动主计划。Mac 通用删除反馈尚待对应授权，没有顺手修改；创建/编辑容器也未发现现有 Mac 实现及完整契约，需单独明确范围和接口，不凭名称猜实现或计作待真机。M6 其余管理、容器删除、网络/VMM 与 M8 仍需继续，不将本片完成当成总体完成。

本片临时 `m7c1-inspection`（含首轮工具栏警告附件和各轮导出清单）已精确清理；保留当前预览、正式日志和结果包。两台模拟器均已恢复浅色。

本片提交前读取云端 [37413207539](https://github.com/yuangy1995/dsm-native-client/actions/runs/37413207539)：基于 cdc889cc 的共享/macOS 与 iPad 工作区通过，iPhone 工作区失败，两个模块组仍运行。映像删除本机结果独立保存，云端失败另行读取具体日志修复，暂不推送取消仍在执行的组；不将本地提交当作云端通过。

## 2026-10-06 macOS 删除反馈保留明确失败

用户单独明确授权修复 `ServiceManagementModel.performDeletion` 的结果判断及必要回归，随后又授权当前 M6–M8 目标内后续选择自主处理。修改前先以三个模型用例复现旧行为：明确失败/权限拒绝/不支持（分别覆盖已提交与未提交）后模拟其他客户端使列表目标消失；提交前取消但旧选择已经不在页面；部分删除含已知失败项。旧实现因 `confirmedSuccess || isVerified()` 错误显示完成，36 项测试中产生 23 条失败断言，均来自这三项新用例，其他用例继续通过。

修正仅允许“已提交、没有明确失败项、状态为未知/提交后取消/部分成功”的结果沿原刷新路径补充确认；明确失败、未提交或已知失败项保留对应反馈。请求、权限、危险确认、目标选择、持久化及双语资源均未改变。原未知结果和无明确失败的部分结果回读成功仍有通过证据，没有删除旧恢复能力。

```sh
swift test --package-path apple --jobs 2 --filter ServiceManagementModelTests
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/PlugIns/LanStashFileProvider.appex/Contents/MacOS/LanStashFileProvider
```

修正后聚焦 36 项零失败；完整 2915 项 XCTest（172 条既有跳过、0 失败）及 12 项 Swift Testing 通过；Mac Release 构建成功，主 App 和内嵌 File Provider 均实际核实 x86_64/arm64。日志分别为 `m7-mac-deletion-before.log`（预期复现失败）、`m7-mac-deletion-focused.log`、`m7-mac-deletion-full.log`、`m7-mac-deletion-macos.log`，保留在本机构建目录，不提交。

独立复核确认拒绝不再调用页面消失兜底，正常未知读取保留，映像删除原本的严格仓库判断不受影响。没有真实 NAS 删除、签名发布或安装包启动。用户已允许后续真实账号测试，但只能操作 Agent 自行生成的隔离数据；本次缺陷已用模型可靠复现，无需为反馈测试删除真实目标。真实设备/NAS 结论不由本片提升，M6 其余管理及 M7/M8 继续推进。

## 2026-10-06 iPhone 人脸编辑界面等待修复

`cdc889cc` 的 [Apple Build 37413207539](https://github.com/yuangy1995/dsm-native-client/actions/runs/37413207539) 中，iPad 工作区及共享/macOS 通过；[iPhone 工作区](https://github.com/yuangy1995/dsm-native-client/actions/runs/37413207539/job/112106031350) 的 161 项实际 UI 为 160 通过、1 失败。原始日志与原生结果包均确认唯一失败为 `MobileWorkspaceUITests.test人脸触控框选移动与辅助控件保存`，原提交文件第 428 行无法找到姓名输入框，失败发生在首次添加居中框之后、绘制拖动之前。两个模块组当时仍运行，未取消它们。

先在当前工作区核实人脸应用源码及原测试与 `cdc889cc` 一致，再按“中文大字空内容→触控框选”顺序在两端运行；原版两项均通过，不能声称本机复现了同一失败。云端结果包约 656 MB，完整读取较慢，后改为校验过的按需读取，仅取根/测试/失败用例元数据、对应录屏及输入事件。原生解析给出 161/1 的计数；录屏中加载状态切换到原先两个人脸，首次点击未产生新框，之后十二次滚动没有新姓名字段。输入事件坐标为测试画布上方居中添加按钮区域；这些证据指向测试过早点击的就绪时机，未据此推断真实 NAS 或人脸保存 API 故障。

仅修改 UITest：两个人脸用例共用添加步骤，先等画布出现、加载态消失、按钮存在/可点击/可用，再单次点击并等待姓名字段出现；进入绘制模式后等待选中状态，再执行原拖拽并检查新姓名字段。滑块移动、移除、手工绘制、命名、保存与重新打开的原断言全部保留，无固定睡眠、重复添加、跳过或降低断言。应用、共享协议、存储和 NAS 请求均未改。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m7-ci-face-phone-r2.xcresult '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test人脸大字中文空内容仍可命名保存' '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test人脸触控框选移动与辅助控件保存' -parallel-testing-enabled NO
```

iPad 使用目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 和 `m7-ci-face-pad-r2.xcresult`。两次移动构建通过；最终两端两项 UI 均 exit 0，iPhone 为 49.324/49.657 秒，iPad 为 48.784/50.812 秒。原版基线使用 `r1` 结果包，最终使用 `r2`；原始云端日志保存为 `m7-ci-phone-workspace-37413207539.log`。已实际查看 iPhone 保存后重开及 iPad 中文最大字号页面，当前合成预览保留在 `apple/Apps/DsmMobile/build/m7-ci-face-preview/`。

原版和修正后的本机结果均记录了 UIKitToolbar 的系统运行时警告，当前未导致两项用例失败；本次没有扩大修改应用布局，也不宣称该既有警告消失。完整共享/Mac 回归由同日已授权的删除反馈专项执行（2915 XCTest/12 Swift Testing、双架构通过）；本片只有 UI 测试变化，未重复无关整组测试。新的云端执行仍待同步后的完整门禁，不将本机通过等同云端已修复。

临时部分下载、按需读取索引/脚本、原始录屏/输入事件、截帧及导出清单已精确清理，保留五张合成审查图和正式日志/本机结果包。曾尝试普通 Range 请求但服务返回整包，识别后终止该额外下载；随后按服务支持的范围读取并校验所取对象，不将部分结果包误称完整下载。

## 2026-10-06 移动 M6b4 网卡设置与断连恢复

基线 `44bc3243`。两端复用服务设置和恢复模型，补网卡列表、搜索、DHCP/静态 IPv4、掩码、网关、DNS、默认网关、MTU、VLAN 和断连风险确认。每次只能保存一张已有网卡，提交只带一个 configs；管理读取要求已记录的 list v2/get v1/set v1 及完整原配置，缺字段不猜默认值。DHCP 租约、显示名称和连接状态不参与配置比较，其他网卡在保存后变化不认领也不影响原目标恢复。

复用 `NAS/service-operations-v1.json`，只增加目标/配置及原连接配置加账号的摘要，不保存地址、网卡名或凭据。同地址重连只读恢复；改地址后须在原配置重新登录原账号，明确选择原 NAS 才读取原记录，保留旧上下文，不自动探测、不复用旧会话、不重发。不同账号或新建配置不能认领；原账号在途操作继续保护同一配置的新地址。共享保存后遇到权限或证书错误立即停止关联读取，未确定的已提交步骤保留未知，恢复只依据原目标完整配置。

按当日已明确的离线授权，仅修正 Mac 网卡保存反馈中“页面缓存相同即视为完成”的判断。新用例在旧实现中实际复现权限拒绝及不支持两条失败；首轮第三条失败来自测试 stub 的 partialSuccess 计数不合法，随后修正 stub。不能把三条均当作产品缺陷。修正后六种拒绝/失败/部分/未知结果均保留实际反馈，confirmedSuccess 和提交前取消维持原语义。没有改变旧 Mac 请求编码、登录存储或其他平台源码。

实际命令：

```sh
swift test --package-path apple --jobs 2 --filter NasAdministrationModelTests
swift test --package-path apple --jobs 2 --filter 'NasServiceFlowTests|NasAdministrationModelTests'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/PlugIns/LanStashFileProvider.appex/Contents/MacOS/LanStashFileProvider
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b4-phone-r2.xcresult '-only-testing:DsmMobileTests' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡编辑校验风险取消后只保存所选配置' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡静态地址和VLAN表单完整保存' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡未知保存重启后只读恢复且不可重发' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡新地址重新登录后明确恢复原记录' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡加载空内容错误与不支持可恢复' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡搜索无结果与权限限制' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡中文大字表单风险和取消均可触达' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test终端端口校验Telnet风险及保存回读' -parallel-testing-enabled NO
```

iPad 使用目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 和 `m6b4-pad-r2.xcresult`。R1 先各运行 53 项聚焦行为测试和前两项网卡 UI；完整 R2 包含新增 15 项网卡行为、既有 38 项服务行为、其余移动单元和七项新 UI 及原终端回归。共享新增七项覆盖版本/字段、单目标编码、非法多目标、原目标比较和未知不重放。

已确认 Mac 聚焦 102 项、共享聚焦 148 项、完整共享 2923 项 XCTest（172 条既有跳过、0 失败）与 12 项 Swift Testing 通过；Mac Release 构建成功，主 App 与内嵌 File Provider 实际核实 x86_64/arm64。两端 R1 的各 53 项行为通过；R2 完整各 1537 项单元（4 条既有跳过、0 失败）通过。R2 两端七项新网卡 UI 及原终端回归共各八项全部通过，iPhone/iPad 命令均 exit 0。R2 使用 iPhone 浅色、iPad 深色；已实际查看两端表单、确认、保存、未知、新地址恢复、加载、空内容、筛选为空、错误与不支持页面。R3 改为 iPhone 深色、iPad 浅色，仅重复中文最大字号及静态地址/VLAN 两项，均 exit 0；随后实际查看六张反向主题截图，两端已恢复浅色。

首轮共享测试失败是旧 fixture 用 prefix(6) 选择能力而新增 Ethernet 插入头部，改为追加能力，保留原语义。首轮移动构建发现详情模型未穷举新增类别，补齐路由和映射后 R2–R5 构建通过。R1 两端两项 UI 均失败：保存/确认已经出现，断言错误地假定 LabeledContent 的值是独立辅助功能元素；iPad VLAN 输入还留下浮动数字键盘遮住保存按钮。实际读取两端辅助功能树和截图后，测试改用完整标签核对数值，并沿既有方式结束输入，保留风险、取消、保存和回读断言；未削弱断言、重复写请求或加固定等待。

契约检查通过 179 个请求及 1 个结果示例，fixture 29 组/48 项私有引用通过，API 目录生成校验通过，本地化 6727/2188/3402 项通过（双语、占位符、引用及硬编码）。私有契约只增加五端管理和恢复说明，不提升真实证据等级。验证日志与结果包保留在 `apple/Apps/DsmMobile/build/m6b4-*`；生成工程通过既有 XcodeGen 更新。

独立集成及只读对抗复核由当前负责人在实现后分别执行，覆盖原配置变化、单目标、提交/回执边界、拒绝、未知部分生效、重复操作、保存失败、权限/证书停止、原账号迟到、新地址明确恢复及损坏记录；不冒称其他模型或真实 NAS 审查。真实网络变更会影响现有环境，本片未对真实 NAS 写入。设备、网络生效、锁屏保护、VoiceOver 和键盘/分屏按主计划四行 PENDING_USER_VALIDATION 验收；聚合网卡、IPv6、创建网卡及全局 DNS 未实现，不混作仅待真机。

R3 使用上述两端 test-without-building 命令，仅保留 `test网卡中文大字表单风险和取消均可触达` 与 `test网卡静态地址和VLAN表单完整保存` 两个选择器，结果路径分别改为 `m6b4-phone-r3.xcresult`、`m6b4-pad-r3.xcresult`。主题设置及其他门禁命令：

```sh
xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance dark
xcrun simctl ui A31ABDE2-186F-43DD-8D40-5EB9511A9289 appearance light
xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance light
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

最终 UI 精确计数由两端 R2/R3 日志核对：

| 轮次 | 设备 | 场景数 | 结果 |
| --- | --- | --- | --- |
| R2 | phone | 8 | 全部通过；七项网卡和原终端回归 |
| R2 | pad | 8 | 全部通过；七项网卡和原终端回归 |
| R3 | phone | 2 | 全部通过；中文大字 62.985 秒，静态地址/VLAN 73.543 秒 |
| R3 | pad | 2 | 全部通过；中文大字 53.436 秒，静态地址/VLAN 96.639 秒 |

已实际查看并保留 28 张合成审查图于 `apple/Apps/DsmMobile/build/m6b4-preview/`。临时附件导出、清单和导出日志已精确清理，正式日志与结果包保留；没有安装或启动 Mac 包，没有真实网络写入。结束时旧云端两个模块组仍运行，保持原轮次不取消；本片提交尚未取得新云端结果，不将本机通过表述为云端通过。


## 2026-10-06 移动 M6b5 安全设置与防火墙恢复

基线 `6bef197e`。两端新增自动封锁次数、时间与解除期限、逐网卡 DoS、防火墙通知和当前防火墙配置启停。复用服务设置原快照、逐组权限与恢复记录；四组分别保存，开启防火墙必须先获得原任务回执、等待明确终态，再读取原配置。缺少回执、断网或超时不能依据当前开关宣布完成。规则及配置档创建/编辑没有现有 Mac 表单基线，不进入本片。

`NAS/service-operations-v1.json` 仅增加安全摘要、原任务回执和阶段，不保存配置正文、网卡/配置档名称或凭据。持续执行期间，只有原任务结束、重新通过权限/取消检查且清理边界落盘后才调用一次全局清理。重启恢复只查询原任务和配置，不重新应用或补发无目标参数的 stop；已结束但未清理的 DSM 上下文对后续保存的影响列入专用环境待验。明确任务失败不会被后来开启状态覆盖。

按已明确的离线授权修复 Mac 安全保存缓存覆盖实际结果，以及共享旧防火墙 helper 在任务超时后仍清理、清理权限错误被吞掉的问题。新增缓存回归在旧实现中实际出现六条失败，修正后 103 项 Mac 模型测试全部通过。旧任务 helper 两条专项在旧实现中共五条断言失败，修正后通过；共享最终聚焦 170 项及完整 2938 项 XCTest（172 条既有条件跳过、0 失败）与 12 项 Swift Testing 通过。没有修改 Mac 页面布局、会话或持久存储。

实际命令：

```sh
swift test --package-path apple --jobs 2 --filter NasAdministrationModelTests
swift test --package-path apple --jobs 2 --filter 'NasServiceFlowTests|NasAdministrationModelTests|DsmNasAdministrationRepositoryTests/test安全|DsmNasAdministrationRepositoryTests/test开启防火墙|DsmNasAdministrationRepositoryTests/test关闭防火墙'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/MacOS/LanStash
lipo -archs apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/LanStash.app/Contents/PlugIns/LanStashFileProvider.appex/Contents/MacOS/LanStashFileProvider
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6b5-phone-r2.xcresult -parallel-testing-enabled NO -only-testing:DsmMobileTests '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test安全四组编辑输入校验风险取消及完整保存' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test防火墙中断重启查询原任务后恢复保存结果' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test防火墙缺回执重启仍保留保护和刷新入口' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test安全后组拒绝显示部分保存且原值可读' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test安全加载缺字段错误不支持无网卡及权限状态' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test安全中文大字表单和危险确认完整可操作' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test终端端口校验Telnet风险及保存回读'
```

iPad 使用目标 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 与 `m6b5-pad-r2.xcresult`。R1 各运行 66 项聚焦单元及前两项新 UI；新增 13 项安全行为全部通过，旧服务测试因新增类别使实际保存次数由 8 增至 9 而失败，修正准确总数并增加自动封锁只写一次的断言。两项新 UI 均已完成真实保存/重启，但错误期待 Enabled；实际辅助功能树与资源均为 On，已修改为准确资源值并保留全部保存、风险、取消和恢复断言。不是页面未保存或隐藏控件问题。

移动首轮构建漏穷举详情路由，补齐后 R2–R4 构建通过；首轮共享合成 transport 把 DoS 数组写成字符串导致用例后续索引越界，修正合成数据并保留精确请求检查。R2 完整两端各 1550 项单元（4 条既有条件跳过、0 失败）通过。Mac Release 构建成功，主 App 与内嵌 File Provider 均实际核为 x86_64/arm64；没有安装或启动 Mac 包。

独立集成与只读对抗复核由当前负责人在实现后分别执行，覆盖完整原字段、网卡与配置档、固定版本、部分完成、权限撤回、证书中断、原账号迟到、任务回执/终态与清理阶段、存储失败和未知防重。复核不是另一模型或真实环境结论。真实安全配置可能封锁账号或阻断现有连接，本片未对真实 NAS 执行写入；专用网络环境、锁屏文件保护及完整辅助功能按主计划四行 `PENDING_USER_VALIDATION` 验收。


最终 R2 两端六项新安全 UI 及原终端回归全部通过，iPhone 7 项为 759.595 秒、iPad 7 项为 841.729 秒，命令均 exit 0。R2 使用 iPhone 浅色、iPad 深色；R3 交换主题，仅运行同一 `test安全中文大字表单和危险确认完整可操作`，结果包为 `m6b5-phone-r3.xcresult` 和 `m6b5-pad-r3.xcresult`，分别 80.008/89.238 秒通过。R3 前移动增量构建通过（日志 `m6-ci-directory-build-r1.log` 同时包含独立账号输入测试修复，未改变安全实现或测试）。随后两端均恢复浅色。

已实际检查两端原生表单、确认、保存、部分结果、缺回执/原任务恢复、加载、缺字段/错误、不支持、权限受限及无网卡状态，并检查反向主题的中文大字输入和风险确认；保留 38 张合成审查图于 `apple/Apps/DsmMobile/build/m6b5-preview/`。本片临时附件导出、清单和六个导出日志已清理，正式测试日志/结果包保留。

其他门禁命令：

```sh
xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance dark
xcrun simctl ui A31ABDE2-186F-43DD-8D40-5EB9511A9289 appearance light
xcrun simctl ui 8145D5B0-65A7-46E3-A0CF-17850E4EFA3F appearance light
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

请求契约 179 项/结果示例 1 项、fixture 29 组/48 项私有引用、API 目录检查均通过；本地化 6741/2188/3402 项双语、占位符、引用与硬编码扫描通过。工程按既有 XcodeGen 重新生成后内容一致；最终文档检查通过。独立云端账号输入失败与分组调整另作提交，本片不把本机验收当作云端或真实 NAS 验收。


## 2026-10-06 账号输入云端修复与管理测试分组

安全设置提交 `aa88e3b` 后独立收口本片。原运行 [Apple Build 37413207539](https://github.com/yuangy1995/dsm-native-client/actions/runs/37413207539) 的 [iPhone 模块作业 112106031435](https://github.com/yuangy1995/dsm-native-client/actions/runs/37413207539/job/112106031435) 基于 `cdc889cc`，完整 1469 单元（4 条既有条件跳过、0 失败）通过，194 UI 中 192 通过、2 失败。失败为 `MobileDirectoryUITests.test当前账号保护和未知所属组仍可查看`（90.314 秒）和 `test账号编辑群组选择保存取消及删除确认`（73.987 秒），都停在旧第 181 行清空说明的断言。

读取完整原日志、两个失败的活动索引及后一个用例的原始录屏；54/70 秒画面显示屏幕键盘切换，72.8/73.4 秒时仍残留旧说明。证据支持测试的方向键/屏幕输入切换未在清空检查前完成，不能把失败归于 NAS 保存或占位文字。使用按需字节读取与校验获得相关结果对象，没有下载整个 1.12 GB 结果包；不把局部检查称为整包验收。

只修改说明替换 helper：iPhone 使用既有服务测试的实际输入区定位、系统全选和单次删除；iPad 对原单行点到末尾删除。清空（含平台占位值）、精确新值及原有保存、重新打开、群组、取消、删除、当前账号保护、明确拒绝与未知恢复断言全部保留。失败时增加合成界面附件，没有固定等待、重复提交或新增跳过。

原 iPhone 194 UI 耗时 17657.925 秒（墙钟 17658.286 秒）；其中十个 NAS 管理类共 105 项约 10957 秒，其余 89 项约 6701 秒。当前源码另新增 13 项服务与 27 项容器 UI，因此将每设备拆为工作区、其他模块、NAS 管理三个互补组，保留原 Runner、锁定工具链、非并行设备执行和结果上传。共享/macOS 仍为独立组。正式分组回归运行实际工作流参数，逐设备枚举所有源码 XCTestCase 保证每类恰一次、非零退出不被吞掉、未知组失败，3 项通过。

实际命令：

```sh
gh api repos/yuangy1995/dsm-native-client/actions/jobs/112106031435/logs
python3 tools/release/test_apple_ci.py
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci-directory-phone-r1.xcresult -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test当前账号保护和未知所属组仍可查看' '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test明确拒绝保持失败而不是成功' '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test账号编辑群组选择保存取消及删除确认' '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test资料保存未知后重启只读恢复'
```

iPad 目标为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包为 `m6-ci-directory-pad-r1.xcresult`。两端模拟器均为浅色，构建通过；原云端 iPad 模块作业保留执行，未因本地提交取消。共享 2938 XCTest/12 Swift Testing、两端完整各 1550 单元与 Mac 双架构已由同日 M6b5 验收；本片不改变生产代码，不重复无关整组，也不把本机专项通过当作新云端通过。


最终两端四项相关 UI 全部通过，iPhone 248.427 秒、iPad 285.520 秒，两个命令均 exit 0。已查看两端确认、删除完成和重启恢复六张实际截图；`Updated account` 完整值保留，原账号保护和失败断言均通过。另保留原云端失败截帧，共七张合成审查图位于 `apple/Apps/DsmMobile/build/m6-ci-directory-preview/`。按需下载索引、局部结果对象、原始录屏、临时导出、截帧脚本与清单均已精确清理，保留正式本机日志/结果包和原云日志。

独立集成复核检查测试 helper 只操作原说明字段、确认/保存断言未削弱；工作流的十项类清单共用，新增测试类默认仍进入 modules，正式回归保证全量覆盖且失败不被改成通过。本片未对真实 NAS 写入，也未修改生产业务代码。


提交前读取到旧 iPad 模块作业 `112106031303` 从 UTC 04:20:13 开始，UTC 10:21:44 时测试步骤已 cancelled、结果上传仍 in_progress。最终作业原因与已执行用例仍待日志确认；当前没有手动取消，不把终止测试算作通过。新的三组分配尚未获得云端执行结果。提交前 fetch 确认 origin/main 仍为 `cdc889cc`，没有远端新提交；推送等待原结果上传结束，避免损失原始失败证据。


旧 iPad 模块最终为 cancelled，检查注释通过 `gh api repos/yuangy1995/dsm-native-client/check-runs/112106031303/annotations` 取得明确的六小时执行上限说明。`gh api repos/yuangy1995/dsm-native-client/actions/jobs/112106031303/logs` 返回的日志截止 UTC 08:53:56；1469 单元（4 条既有跳过）通过，按 UI 开始/终态行可确认 158 项开始、156 通过、1 失败、1 没有终态。日志未覆盖后续时段，不能视为完整执行统计；artifact 清单未包含 iPad 模块包，上传没有保留下可下载的完整结果。

唯一可见 UI 失败为 `MobileChatManagementUITests.test中文深色大字公告筛选空状态` 的开关值断言。原版在本机 iPad 连续两次都复现（24.354/23.488 秒，exit 65），结果包 `m6-ci-chat-toggle-pad-baseline.xcresult`。实际截图和辅助功能树均显示聊天已经出现在侧栏、新通知区域已插入设置表单，而原功能开关已移出可见列表；持续读取的目标查询只有查询链，没有当前元素。不是聊天实际仍关闭，也不能以根快照推断崩溃。公共 helper 在单次开启后，沿已有设置表单标识滚回原开关，再保留值为 1 的检查；没有第二次开关输入、跳过或放宽后续聊天/筛选断言。修复只涉及 UI 测试及证据文档。


聊天开关修复最终构建通过；iPhone/iPad 各四项专项 UI 全部通过（166.593/167.682 秒，两命令 exit 0），覆盖原失败、公告跨重启恢复、中文大字定时列表/筛选和管理员六模块开关。十二张最终截图已逐张查看，连同一张原版失败图保留在忽略目录 `apple/Apps/DsmMobile/build/m6-ci-chat-toggle-preview/`；全部临时导出、原始录屏和层级文件已清理。极大字号下公告附件按钮出现换行是既有呈现，本片不扩展为聊天页面重排，也不把专项通过称为全面视觉验收。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci-chat-toggle-pad-baseline.xcresult -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test中文深色大字公告筛选空状态' -test-iterations 2
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -resultBundlePath apple/Apps/DsmMobile/build/m6-ci-chat-toggle-phone-r1.xcresult -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test中文深色大字公告筛选空状态' '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶中断重启仅恢复原操作' '-only-testing:DsmMobileUITests/MobileChatTimedActionUITests/test中文深色大字定时列表及筛选空状态' '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test管理员六种模块均需开启且设置始终可达'
```

iPad 最终采用相同四项选择，设备为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果为 `m6-ci-chat-toggle-pad-r1.xcresult`。基线双次运行发生在修改前；命令列表中的构建是随后修正版。独立差异复核确认只在开关离屏时滚动，仍单次输入、精确检查开启值并保留原业务断言。文档检查、本地化资源与硬编码扫描均通过，资源数量 6741/2188/3402；此前测试分组三项正式回归仍有效。fetch 确认 origin/main 没有新提交，旧作业现已结束，可以正常推送本批完成提交触发完整新分组。


## 2026-10-06 移动 M6c2 硬件与 UPS 设置

本片从 `a776993c` 的干净 main 开始，沿既有 M6–M8 与离线自主决策授权实施。新增移动来电启动、亮度、实际风扇模式、提示音、休眠和 UPS 表单，复用服务管理逐步持久恢复。共享管理读取固定已记录 v1，保留缺失与可信空字段；LED 的设置与应用分别保存回执。Mac 仅修正已授权的硬件保存反馈，不扩展桌面功能。Windows/Android 只登记契约影响。

基线新增五项复现测试先出现 16 条断言失败：Mac 页面相等掩盖失败，共享回读认领明确拒绝或未提交组，以及把 LED 暂存亮度误当实际应用。修正后硬件相关 21 项通过，进一步共享服务/硬件聚焦 89 项通过；完整共享为 2954 项 XCTest（172 条既有条件跳过、零失败，73.254 秒）和 12 项 Swift Testing。实际命令及日志前缀：

```sh
swift test --package-path apple --jobs 2 --filter 'test硬件设置(明确拒绝不能|超时只认领|灯光|页面相等)'
swift test --package-path apple --jobs 2 --filter 'test硬件设置|test提示音|test风扇|test硬件休眠|testUPS'
swift test --package-path apple --jobs 2 --filter 'NasServiceFlowTests|test硬件设置|test提示音|test风扇'
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

日志位于忽略目录 `apple/Apps/DsmMobile/build/m0-m8/`，分别为 `m6c2-baseline-before.log`、`m6c2-baseline-after.log`、`m6c2-shared-focused.log`、`m6c2-shared-full.log` 和 `m6c2-mac-build.log`；最终资源变更后增量 Mac 构建记录为 `m6c2-mac-final-build.log`，均真实成功。`lipo -archs` 确認主 App 与内嵌 File Provider 均为 `x86_64 arm64`，没有安装或启动 Mac 包。

首轮移动构建使用 `CODE_SIGNING_ALLOWED=NO`，可构建但 App 只有链接器签名，签名标识为 `DsmMobile` 且未绑定 Info.plist；两端完整 1563 项单元均只有既有 `MobileSecureStoreDefaultsTests.testSimulatorDefaultStoresRoundTripSessionAndPassword` 报 `secureKeyUnavailable`，各 4 条既有跳过，新 13 项硬件行为均通过。两端各执行八项新硬件 UI 和原终端回归：iPhone 九项中 UPS 输入一项失败（合计 1049.558 秒），iPad 九项全部通过（1246.077 秒）。由于单元失败，两条首轮命令均 exit 65；结果包 `m6c2-phone.xcresult`、`m6c2-pad.xcresult`，不能写成整轮通过。

首轮 iPhone UPS 失败停在系统全选菜单。实际截图及辅助功能树显示等待时间长标题换行，控件辅助功能区域包含标题和值，原点击点没有进入最右侧数字输入，键盘未出现。调整为与地址一致的上下布局，并在中文大字用例增加实际等待时间输入，继续保留范围校验、精确输入值、保存后回读与取消零写断言。另将灯光缺回执提示改为通过 DSM 调整，不暗示反复刷新能认领暂存亮度。

正确签名后重新构建，`codesign -dvv` 确認临时签名与应用标识、Info.plist 绑定正常。没有修改任何凭据保护代码或测试断言；R2 两端完整各 1563 项单元（各 4 条既有跳过）零失败，分别 40.688/40.493 秒，原凭据存储测试也通过。R2 iPad 三项专项 UI 全部通过（463.936 秒、exit 0）；iPhone 灯光提示通过，UPS 普通输入与中文大字输入仍停在全选菜单（合计 316.620 秒、exit 65）。两张失败截图都没有数字输入焦点或键盘；不能以布局调整代替交互通过。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath apple/Apps/DsmMobile/build/m0-m8/m6c2-phone-r2.xcresult '-only-testing:DsmMobileTests' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/testUPS网络连接等待时间校验及保存' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test灯光应用缺回执重启仍保护并提供刷新' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test硬件中文大字表单风险和取消均可触达'
```

iPad 使用同一选择与 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包为 `m6c2-pad-r2.xcresult`。首轮均浅色；R2 iPhone 浅色、iPad 深色。独立集成及只读对抗复核由当前负责人在实现后单独执行，检查原配置/范围/权限、逐步保存、LED 两步边界、明确拒绝、未知不重放、记录故障和旧账号迟到响应，不冒称另一模型或真实设备结论。

真实 NAS 没有参与本片写测试；物理风扇/灯光、电源与 UPS 行为、真机锁屏文件保护及完整辅助功能按主计划四行 `PENDING_USER_VALIDATION` 单独验收。已有云端运行 [Apple Build 37450968329](https://github.com/yuangy1995/dsm-native-client/actions/runs/37450968329) 验证的是 `a776993c`，共享/macOS 作业成功，移动各组仍在执行或排队；没有为了本片提前推送而取消该运行。


R3 将测试的独立标题短数字框改为直接点击控件，按原字符数删除并检查清空，再输入精确新值；iPad 原行内数字和其他字段测试路径保持原样。没有跳过范围、保存、回读或取消断言。使用相同签名命令再次构建后，两端只选择 UPS 与中文大字两项 UI，结果均通过：iPhone 233.843 秒、iPad 294.713 秒，两条命令 exit 0。结果包 `m6c2-phone-r3.xcresult` / `m6c2-pad-r3.xcresult`；主题为 iPhone 深色、iPad 浅色。十二张输入/确认/保存和大字截图已逐张检查。

随后按项目普通保存交互约定去掉灯光单独保存的无风险重复确认；“应用已保存亮度”直接触发原记录绑定的单次应用。涉及电源、风扇、声音、休眠或 UPS 的变更仍走原具体后果确认。底层权限、记录、原值绑定与防重复逻辑不变。新增普通亮度保存 UI，并调整三项灯光恢复 UI 检查不出现额外确认；R4 构建成功，两端运行硬件 13 项单元、四项灯光 UI 及中文大字风险确认。R4 最终两端 13 项硬件行为与五项 UI 全部通过：iPhone UI 540.052 秒、iPad UI 643.678 秒，命令均 exit 0。


R4 完整命令如下，iPad 换为同一前述设备并将结果包改为 `m6c2-pad-r4.xcresult`；此前 R3 使用同一命令基础，仅选择 UPS 与中文大字两个用例。R4 为 iPhone 浅色、iPad 深色，最后两端均恢复浅色并回读确认。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath apple/Apps/DsmMobile/build/m0-m8/m6c2-phone-r4.xcresult '-only-testing:DsmMobileTests/MobileHardwareSettingsTests' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test灯光单独保存直接完成且无需额外确认' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test灯光应用被拒绝后可明确继续而不重新设置亮度' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test灯光应用缺回执重启仍保护并提供刷新' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test灯光接受后断线重启只恢复保存状态且主动应用' '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test硬件中文大字表单风险和取消均可触达'
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

九项新增硬件 UI 与原终端回归均已有两端分轮通过证据。逐张检查加载、空内容、错误/缺字段、不支持、权限、未知范围、普通保存、UPS、灯光拒绝与重启恢复、浅深主题和中文大字操作截图，保留最终场景及主题审查图于 `apple/Apps/DsmMobile/build/m6c2-preview/`；临时附件导出、活动索引、导出日志和重复预览已精确清理，正式结果包与验证日志保留。工程用锁定 XcodeGen 重新生成后与当前文件一致；双语 6780/2188/3402 项、契约 179 项/1 项结果、fixture 29 组/48 项私有引用、API 目录、文档和差异检查均通过。提交前 fetch 确认 origin/main 仍为 `a776993c`，没有远端新提交。本片为本机验收完成，未发布安装包，也不代表云端或真实 NAS 验收完成。


## 2026-10-06 移动 M6e2 套件启停卸载与恢复

开始于 `c528eb0e`，main 工作区只有本片新增账本。Mac 页面同状态/目标消失可以覆盖明确拒绝或未知、未知状态可误报停止，先新增两条测试复现 **16 条断言失败**；删除页面覆盖分支后，14 项相关回归通过。仅修已授权的结果反馈，未安装或启动 Mac 应用。新 Swift 测试最初两处编译错误（测试反馈类型不同、只读状态属性赋值）先修正，未当作行为复现证据。

```sh
swift test --package-path apple --jobs 2 --filter 'test套件操作页面相等|test套件停止不能把未知状态'
swift test --package-path apple --jobs 2 --filter 'NasAdministrationModelTests.test套件|NasAdministrationModelTests.test暂停套件|NasAdministrationModelTests.test系统套件'
swift test --package-path apple --jobs 2 --filter 'NasPackageControlFlowTests|NasAdministrationModelTests.test套件|DsmNasAdministrationRepositoryTests.test套件|DsmNasAdministrationRepositoryTests.test启动套件|DsmNasAdministrationRepositoryTests.test卸载套件'
swift test --package-path apple --jobs 2
```

本片日志与结果置于忽略目录 `build/m6e2-*`。共享最初聚焦运行在旧卸载输入缺少新预读的情况下失败，并停在等待尚未到达的写边界，已终止该次进程；调整输入为操作内部预读、保留原断言。新增测试首次辅助构造参数与现有 Repository 初始化签名不符，修正后 R3 聚焦 **41 项通过**。完整共享首轮 **2967 XCTest、172 条既有条件跳过、1 失败**，唯一失败为 `RequestFixtureContractTests.test套件卸载请求与共享Fixture一致` 的旧预先加载输入且缺安装类别；将其改为真实新预读顺序并补合成 `install_type`，请求 Fixture 与精确写参数断言不改。R2 完整 **2967 XCTest（172 条既有跳过）和 12 Swift Testing 通过**。之后独立复核新增 NAS 明确输入拒绝回归，最终完整结果继续记于本节。

移动 `build-for-testing` 两轮均成功，均使用本机临时签名 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，没有修改应用身份、正式权限或凭据保护。工程经既定 XcodeGen 生成。首轮两端完整各 **1578 项单元（各 4 条既有跳过）仅一项失败**：既有损坏记录测试期望存储错误，因新增目录损坏识别发生得更早，后续普通前置判断把提示覆盖成信息变化；零写入断言及新增 15 项控制行为均通过。修正模型保留存储错误归属，未降低既有断言；后续复验见本节续记。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m6e2-phone.xcresult '-only-testing:DsmMobileTests' '-only-testing:DsmMobileUITests/MobilePackageControlUITests' '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test未知设置跨页面禁用且重启只读恢复'
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

iPad 同样选择，设备为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包 `build/m6e2-pad.xcresult`。首轮主题 iPhone 浅色、iPad 深色。命令末尾额外选择的旧设置测试名不存在，所以该选择未执行，不能宣称旧 UI 已覆盖；后续用源码中真实名称分别运行受共用文案影响的三项旧 UI，保留本次新类的实际结果。

本片将新控制 UI 类纳入每设备 administration 组，三组互补覆盖回归 3 项通过；双语资源 6791/2188/3402、179 个请求 Fixture/1 个结果示例、29 组 Fixture/48 项私有 API 文档引用均通过。真实 NAS 套件未参与写测试，实际服务/卸载数据、并发重装及设备锁屏/辅助功能按移动主计划三行 `PENDING_USER_VALIDATION` 单独验收。


最终共享 R3 为 **2968 XCTest（172 条既有条件跳过、0 失败）及 12 Swift Testing 通过**，`build/m6e2-shared-full-r3.log`；Mac Release 构建成功，主 App 和 File Provider 的 `lipo -archs` 均为 `x86_64 arm64`，`build/m6e2-mac-build.log`。未安装或启动 Mac 包。

首轮新控制 UI 两端七项全部通过：iPhone 415.795 秒、iPad 422.858 秒，但因上述单元提示分类失败整条命令 exit 65。实际导出并检查两端 36 张合成截图，确认输入/确认/取消、五态、拒绝和重启恢复；截图另外发现 iPad 双侧栏下空状态与错误标题截断，最后改为完整换行。活动记录补充当前套件名称用于区分目标，未知记录的恢复按钮改用“刷新”，不再误称“刷新设置”。

正确保留存储错误后 R2 两端完整各 **1578 单元、4 条既有跳过、0 失败**，iPhone 49.107 秒、iPad 47.362 秒；两端三项旧套件 UI 与新启动/中文大字两项全部通过，命令均 exit 0。结果包 `build/m6e2-phone-r2.xcresult` / `build/m6e2-pad-r2.xcresult`；主题交换为 iPhone 深色、iPad 浅色。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m6e2-phone-r2.xcresult '-only-testing:DsmMobileTests' '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test未知设置重启后只读恢复且不允许再次保存' '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test未知来源重启后按原目标恢复且不能清记录重发' '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test明确权限拒绝保留失败而不显示保存成功' '-only-testing:DsmMobileUITests/MobilePackageControlUITests/test启动取消零写后确认再停止并查看结果' '-only-testing:DsmMobileUITests/MobilePackageControlUITests/test中文大字详情与风险确认取消均可触达'
```

iPad 替换为相应设备及 `build/m6e2-pad-r2.xcresult`，选择完全一致。最终只针对标题换行、恢复按钮及目标显示的 UI 复验继续记录如下，不无故重复共享/Mac 全量。


R2 五项 UI 的总用例时间为 iPhone **305.773 秒**、iPad **317.868 秒**，24 张实际截图已检查。R4 签名构建后，最终 R3 专项两项 UI 两端全部通过：iPhone **168.301 秒**、iPad **162.321 秒**，两条命令 exit 0；实际 12 张截图确认 iPad 窄列标题没有省略号截断，未知操作显示原套件和“刷新”，重启仍只读恢复。源码/行为层没有后续修改，因此不重复共享/Mac 全量。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m6e2-phone-r3.xcresult '-only-testing:DsmMobileUITests/MobilePackageControlUITests/test列表加载空内容失败恢复和搜索为空' '-only-testing:DsmMobileUITests/MobilePackageControlUITests/test未知启动保持保护重启后只读恢复'
```

iPad 同样选择并使用对应设备/`build/m6e2-pad-r3.xcresult`。各轮共 72 张合成截图均已实际查看，预览保留在 `build/m6e2-preview/`；临时导出目录、清单、导出日志、审查网格和无关实时截图已清理，正式测试结果保留供复核。两端模拟器已恢复浅色。工程重新生成一致，双语/硬编码、契约/Fixture、API 目录、文档和差异检查通过；本片没有真实 NAS 写入，没有正式发布。

## 2026-10-06 移动 M7c2 容器删除与恢复

基线 `645b6f7e`，main 原工作区仅有本片新账本。沿现容器控制记录接入单项/多项删除及原快照观察边界，Mac App 没有新增改动；共享旧批量删除同步区分后项预检/明确拒绝和已发送前项。没有连接真实 NAS 执行写入。

```sh
swift test --package-path apple --filter 'ContainerDeletionFlowTests|DsmServiceManagementRepositoryTests'
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m7c2-phone.xcresult '-only-testing:DsmMobileTests' '-only-testing:DsmMobileUITests/MobileContainerControlUITests'
```

iPad 使用相同选择，设备 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果包 `build/m7c2-pad.xcresult`。iPhone 浅色、iPad 深色；UI 类包含七项新删除和十项旧启停/五态/旋转回归。

首轮共享聚焦 **170 项、2 条断言失败**，实际复现 `containers=[]/total=1` 被误报删除成功。复用原列表完整性检查并补分页类型回归，R2 **171 项通过**，日志 `apple/Apps/DsmMobile/build/m7c2-shared-focused*.log`。完整共享 **2982 XCTest（172 条既有跳过、0 失败）与 12 Swift Testing 通过**，`build/m7c2-shared-full.log`。移动两次构建均成功；第二次包含当前账号内存中的已删除目标名称，不写入恢复文件。两端完整单元均为 **1590 项、4 条既有跳过、0 失败**。Mac Release 构建 exit 0，主 App/扩展 `lipo -archs` 均返回 x86_64 arm64；日志 `build/m7c2-mac-build.log`。两端 UI 最终结果见下文续记。

双语/硬编码检查 6794/2188/3402、请求契约 179 个 Fixture/1 个结果示例、29 组 Fixture/48 项私有 API 文档引用、API 参数目录及文档检查通过。独立集成审查和只读对抗复核由当前负责人在实现后单独执行，结论与三行真实条件见移动主计划，不冒称真实 NAS 或另一模型验证。

两端完整 17 项 UI 均 exit 0：iPhone **697.749 秒**、iPad **753.526 秒**，含七项新删除、十项既有控制/五态/旋转。随后交换主题（iPhone 深色、iPad 浅色），只选择 `test删除明确后果取消零改变再确认删除` 与 `test中文大字删除风险完整可读且取消按钮可用`，每端两项均通过，分别 **68.524 / 68.843 秒**；结果包 `build/m7c2-phone-theme.xcresult` / `build/m7c2-pad-theme.xcresult`。这轮仅用于缺少的主题覆盖，不重复全量。

四个结果包共导出并逐张查看 **66 张合成截图**，确认固定目标和具体删除后果、逐项结果、未知保护、取消、匿名重启恢复、普通套件账号、加载/空/筛选空/错误/正常、中文大字及旋转均可读可操作。预览保留在 `build/m7c2-preview/`；临时附件导出目录、清单与导出日志已清理。两端已恢复浅色。工程经既定 XcodeGen 再生成与已提交生成物一致；本地化、契约、Fixture、API 目录、文档、三组 CI 覆盖测试及差异检查通过。

另行取得旧提交 a776993c 的云端 run `37450968329` 部分终态：共享/macOS 通过，iPhone 工作区 1 项与模块组 3 项失败，均为设置开关或导航阶段；iPad 工作区随后也返回失败，正在读取原日志，其余分组仍在运行。这些失败独立按原云端日志和截图排查，不冒称本片或整个云端已通过，也没有为本片取消当前运行。

## 2026-10-06 功能开关导航与照片表单云端复验

基线为 `40cc0a1`。原云端 [Apple Build 37450968329](https://github.com/yuangy1995/dsm-native-client/actions/runs/37450968329) 验证 `a776993c`：iPhone 工作区 161 项中 1 项失败，模块组 1550 项单元（4 条既有跳过）通过、116 项 UI 中 3 项失败；iPad 工作区 161 项中 1 项失败。共享/macOS 成功，其余三个作业仍运行，不能宣布完整云端成功。

从三个失败作业的正式结果包中只读取必要测试记录与附件，没有导出凭据、上传 NAS 数据或使用真实环境复现。照片人物重启和两个下载场景的失败截图及辅助功能树均显示开关仍为 0，原导航因此没有目标入口。容器映像标签场景的录屏显示点击 App settings 后一直停留 File 页；不是已证实的开关离屏。iPad 格式列表录屏 86 秒处 LEGACY 已被浮动标题遮挡，随后整屏向上滑动，94 秒到了列表末尾，原辅助函数越过了目标。

修改限于三个正式 UI 测试文件及本文档：照片/下载开启步骤复用单次控件按下/抬起与状态检查，保留大字滚动；共用标签/侧栏导航使用 0.15 秒按下/抬起并检查设置页，准备失败保存截图与层级。照片辅助函数只在当前可操作表单内慢拖，并根据行位置反向滚动；进入格式页后先等待导航标题。业务操作、原保存/重启/防重复断言、权限及产品代码均不改变。

修改前分别用两端运行原五项，全部通过：iPhone **260.546 秒**、iPad **270.365 秒**，结果包 `build/ci-navigation-before-phone.xcresult`、`build/ci-navigation-before-pad.xcresult`。因此本机没有复现上述云端失败，不能将原版通过当作根因验证。修改后保留相同五项，并增加中文大字映像下载、中文深色下载横屏、中文深色大字聊天三态和照片最后图库/缓存忙碌限制四项回归。

实际构建命令（初轮及最终增量均成功）：

```sh
xcodebuild build-for-testing \
  -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

实际 iPhone 专项命令；iPad 使用相同九项选择，将设备替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`、结果包替换为 `build/ci-navigation-after-pad.xcresult`：

```sh
xcodebuild test-without-building \
  -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO \
  -resultBundlePath build/ci-navigation-after-phone.xcresult \
  '-only-testing:DsmMobileUITests/MobileContainerImagePullUITests/test标签失败重试空标签与筛选为空' \
  '-only-testing:DsmMobileUITests/MobileContainerImagePullUITests/test中文大字下载按钮与风险说明可用' \
  '-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test取消剩余项目后空任务列表仍可查看与清除已结束记录' \
  '-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test多选暂停与继续分别处理符合状态的任务' \
  '-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test中文深色大字多选与结果支持横屏' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test人物保存中断重启不可重复提交' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片全局格式保留未知项及缓存清理' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片共享最后图库与正在清理缓存保持限制' \
  '-only-testing:DsmMobileUITests/MobileChatUITests/test中文深色大字号新建联系人空列表和加载失败'
```

原五项基线命令使用同样设备/派生目录/禁并行配置，仅选择上面原失败的五项，结果路径如前述。本地化及硬编码检查为 6794/2188/3402 项、文档检查、`python3 -m unittest discover -s tools/release -p test_apple_ci.py` 三项分组检查均通过；没有改动共享或产品源码，不重复前片已通过的共享/macOS 全量。修正后两端专项结果和截图复核续记如下。

首轮九项两端均为 **7 通过、2 失败**；失败均为新照片辅助函数错误要求列表容器本身 `isHittable`。两端录屏显示表单已呈现，随后只在该失败分支补充正式诊断附件，iPhone 原格式用例再次失败（25.186 秒）；其辅助功能树确认当前弹层最后的 CollectionView 包含可操作的格式按钮，但容器自身不可点击。最终定位改为当前弹层的最后列表/导航栏，保留每个目标控件自身的可点击、标题遮挡、位置和反向滚动判断，不把容器属性当作用户操作能力。诊断没有修改产品或降低业务断言。

最终构建仍使用上面的同一命令，日志为 `build/ci-photo-scroll-final-build.log`，结果成功。仅重跑受该辅助函数影响的 `test照片全局格式保留未知项及缓存清理` 和 `test照片共享最后图库与正在清理缓存保持限制`；仍使用上述两端设备、工程、派生目录与禁并行配置，结果包为 `build/ci-photo-scroll-final-phone.xcresult`、`build/ci-photo-scroll-final-pad.xcresult`。其他七项源码没有后续变动，保留首轮已通过结果。

最终两项每端均 **0 失败、exit 0**，iPhone **151.607 秒**、iPad **162.503 秒**；因此九项均有两端分轮通过证据。首轮通过场景每端 13 张截图、最终照片每端 4 张，共 **34 张已逐张检查**：LEGACY 已滚入可操作区域，修改/保存/缓存确认及两项禁止操作状态均正确；下载结果、恢复保护、标签空内容与中文大字/深色/横屏保持可用。必要预览保留在 `build/ci-navigation-preview/`，一次性下载检查脚本、视频帧导出与附件清单在交付前清理。

独立集成审查由当前负责人在实现后单独执行：未修改产品、共享契约、权限、合成传输或业务断言，未增加业务重复提交或失败静默跳过；定位改动由原云端截图/录屏与本机失败层级支持。最终本地化、文档、差异检查通过，CI 分组正式三项回归通过。fetch 确认远端无新提交；旧云端另外三组尚未结束，暂不推送以避免取消其完整验证，不能将本机通过写成修正版云端通过。

## 2026-10-06 移动 M7c3 容器网络管理与 API 文档核查

基线 `ce0f32f3`，main 起始工作区干净。新增移动网络表单、地址/关联详情、单/多删及独立摘要恢复；共享旧 Mac 入口继续同一创建/删除流水线。危险删除绑定原快照、默认/占用限制、单项对象数组、完整列表与逐边界记录；明确拒绝/预检不能被外部状态覆盖。新字段 ipRange 为向后兼容可选只读值，不改变登录、权限、依赖或发布配置。

用户追加的 API 文档核查独立保持只读：Chrome 官方信息中心/套件中心确认 DSM 7.2.1-69057 Update 12、Container Manager 24.0.2-1535、VMM 2.6.5-12202；必要官方 XHR 只保存脱敏字段类型，官方脚本只在内存核对。补容器 profile/内存/端口/项目 CRUD 与流式操作、VMM 固定版本/参数及现有 Apple 内部兼容差距。没有真实写、VM 连接、HAR、用户配置正文或脚本落盘；临时观察器已恢复删除，DevTools 关闭。证据边界及摘要指纹见对应发现记录，未提升历史 lab-a 或任何新增写行为等级。

实际共享与构建命令：

```sh
swift test --package-path apple --jobs 2 --filter 'ContainerNetworkManagementTests|ContainerNetworkCreationTests|DsmServiceManagementRepositoryTests|ServiceManagementModelTests'
swift test --package-path apple --jobs 2
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

工程使用仓库既定 XcodeGen 2.46.0 生成，新文件由工程流程加入。工具旧临时路径已失效，首次命令未开始构建；随后系统 2.45.4 的生成物已经用正式 2.46.0 重新生成替换，没有手改工程文件。中间两次移动编译的枚举类别拼写已纠正；正式单元/UI 测试源码保留，不提交一次性工具。

基线共享三项测试实际复现 **5 条断言失败**（创建拒绝后同名认领、删除拒绝/预检被外部消失覆盖），日志 `build/m7c3-baseline.log`；修复后首轮 16 项和后续 209 项聚焦通过。完整共享中间轮 **2994 XCTest/172 条既有跳过及 12 Swift Testing 通过**。实现后独立集成/只读对抗复核另加两条旧入口回归，丢删除回执用例实际复现 **2 条断言失败**，`build/m7c3-review-baseline.log`。补接受标记后 **211 项聚焦通过**，最终完整共享 **2996 XCTest（172 条既有跳过、0 失败，84.786 秒）与 12 Swift Testing 通过**，`build/m7c3-shared-final.log`。

移动中间轮全量各 1606 项有一条精确资源集合断言失败，原因是共享详情提取后资源引用文件变化；同步原精确集合，未删除/放宽断言，随后两端 **1606 项/各 4 条既有跳过/0 失败**。对抗复核再加“未知删除重启后原 ID 改名”用例，iPhone 在修复前实际出现 **2 条断言失败**：改名后仍能生成删除确认。`build/m7c3-identity-baseline.xcresult/log`。恢复保护同时匹配原 ID/名称后，两端最终 **1607 项/各 4 条既有跳过/0 失败**；iPhone 56.190 秒、iPad 56.284 秒，结果见 final 两端包。

实际完整网络 UI 命令；iPad 使用相同工程/选择，将设备换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`、结果换为 `build/m7c3-pad-ui-r4.xcresult`：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m7c3-phone-ui-r4.xcresult -only-testing:DsmMobileUITests/MobileContainerNetworkUITests
```

最初测试在用户新输入中断时没有形成完整结果包，不能当作通过。R2 两端各 **5 UI 通过/3 失败**；真实截图/层级确认键盘挡住手动 IPv6 输入，表单滑动需以导航栏和键盘之间的可见区域定位；长风险文字触发 XCTest 128 字符 identifier 限制，改为完整 label 谓词。详情显示正确，但 LabeledContent 将字段/值组合为一个无障碍标签；R3 两端各 **2 通过/2 失败**仍复现原错误查找方式，最终改为精确完整“字段, 值”断言，不放宽值或跳过业务流程。输入后字段标签保留，创建按钮缩短。

R4 两端 **8 UI 全通过**，每端 18 张、共 **36 张合成截图逐张复核**，覆盖中文大字/旋转、五态/搜索、自动与手动创建、详情、默认/占用保护、取消/批量、部分权限拒绝、丢回执和跨重启只读恢复。iPhone 深色、iPad 浅色；此前 R2 五个成功场景采用相反主题。截图又发现英文导航标题截断及空输入重复标签，改用已有 Networks 标题资源，字段保持 caption 与单一无障碍 label，移除重复 placeholder。

最后构建成功后，两端全单元加三个受影响 UI 使用下列命令。iPad 同样替换设备与 `build/m7c3-pad-final.xcresult`；单元结果已见上文，UI 与 Mac 最终结果随后续记。

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m7c3-phone-final.xcresult -only-testing:DsmMobileTests '-only-testing:DsmMobileUITests/MobileContainerNetworkUITests/test手动IPv4IPv6与伪装完整填写可创建' '-only-testing:DsmMobileUITests/MobileContainerNetworkUITests/test未知删除重启不重放原网络消失只显示当前结果' '-only-testing:DsmMobileUITests/MobileContainerNetworkUITests/test加载空列表错误重试与搜索为空'
```

已通过本地化/硬编码检查 **Apple 6824、Android 2188、Windows 3402**；请求契约 **179 Fixture/1 写结果示例**；Fixture **29 组**与私有 API 文档引用 **48 项**；API 参数目录和 CI 三项分组回归通过。文档链接与差异在最终交付前再查。真实网络路由/IPv6/伪装副作用、权限/证书/断网竞争、锁屏文件保护与 VoiceOver/键盘/分屏仍按主计划三行 `PENDING_USER_VALIDATION`，不声称模拟器等同 NAS 验收。

2026-10-07 凌晨最终续记：两端三个专项 UI 均 **0 失败、exit 0**，iPhone **344.647 秒**、iPad **389.989 秒**；final 包包含上述各 1607 单元。最后 **16 张截图**已逐张检查，Networks 标题无截断，空地址字段不重复标签，手动创建和重启删除保护保持正确；与 R4 共 **52 张成功场景截图**。R4 完整八项用例时长 iPhone **564.663 秒**、iPad **606.739 秒**。Mac 最终 Release 构建 exit 0，主 App 与 LanStashFileProvider.appex 的 `lipo -archs` 均为 **x86_64 arm64**；日志 `build/m7c3-mac-build-final.log`。

工程以 XcodeGen 2.46.0 再生成，project.pbxproj 字节一致。最终本地化、API 目录、契约/Fixture、文档、CI 分组三项与差异检查通过。截图预览保留于 `build/m7c3-preview/`，正式日志/完整结果包保留；一次性生成工具、视频抽帧脚本、附件导出目录和中断的不完整结果包清理。实际 API 文档核查与所有合成测试没有操作真实用户网络、容器、VM 或文件。

旧云端 `37450968329` 随后全部结束，整体 failure；共享/macOS 通过，六个设备分组均失败（已有五项导航/表单失败在先前专项处理，最后管理/模块组日志继续核查）。这属于旧 a776993c 的结果，不冒称当前未推送变更已通过完整云端。fetch 确认 origin/main 没有新提交，后续同步与新云端结果另记。

## 2026-10-07 剩余管理与下载云端失败复核

基线 `0512125f`，main 工作区干净；沿既有提交/推送、CI 修复及离线自主授权，仅修改正式移动 UI 测试和对应文档。原 [Apple Build 37450968329](https://github.com/yuangy1995/dsm-native-client/actions/runs/37450968329) 对应 `a776993c`，已全部结束且失败；共享/macOS 通过。最后 iPhone administration 三次、iPad administration 四次、iPad modules 两次失败，共九个不同用例；前片五次导航/照片失败已另有修复与证据，不混算。

原完整日志为 `build/ci-a776993c-phone-administration.log`、`build/ci-a776993c-pad-administration.log`、`build/ci-a776993c-pad-modules-final.log`。按需读取 GitHub 测试产物的失败对象、截图、层级和三段录屏，没有下载整份大压缩包，没有输出或保存访问凭据/签名地址。证据结论：

- NAS 读取/区域设置和下载导航失败时，截图/层级的相应开关仍为 0；下载控制沿前片已修，NAS 读取/区域及下载移除改用同一共用导航和单次开关输入/值为 1 的检查，不重试业务操作。
- 账号说明首份值残余 `Samp`，随后保留的层级与截图已经为空；来源地址录屏结束前仍在逐字删除。输入改为等待原字段实际空值及输入后的精确目标值，不把残余文字当作成功，也不追加删除输入。
- 计划任务确认页关闭后，原测试仍引用该旧列表；最终层级已有编辑页和正确未知结果。未知编辑场景明确等待确认页消失，再读取原编辑页中的结果，不改变业务提交/恢复。
- 硬盘恢复的 87 秒与 99 秒画面均已有预期状态文字，原全类型查询却没有返回目标；当前只收敛到相同标识的静态文本并增加失败层级/截图，保留十二秒时限和原状态/防重/重启断言。没有证据证明产品状态错误，也尚不能宣称云端查询原因已完全复现。

修改前九项 iPhone **9 通过、0 失败、784.216 秒、exit 0**；iPad **8 通过、1 失败、819.825 秒、exit 65**，唯一失败是来源流程后段重命名时名称字段未及时清空（原 line 170），与云端地址字段清空属于同一辅助步骤，但不混称同设备重现。结果为 `build/ci-final-before-{phone,pad}.xcresult/log`；其余八项本机未复现云端问题。本机 iPad 失败录屏末帧也确认名称已经清空，定位与删除并未失败，修正使用实际空值等待。必要八张云端/本机失败画面及计划任务层级保留于 `build/ci-final-preview/`，一次性下载/录屏/抽帧/导出已清理。修正版构建 `build/ci-final-build.log` 已成功，十二项两端回归全部通过：iPhone **12/12、958.333 秒、exit 0**；iPad **12/12、1044.074 秒、exit 0**，结果为 `build/ci-final-after-{phone,pad}.xcresult/log`。本专项没有产品源码、契约、权限、NAS 请求、持久记录、依赖、工具链或应用身份变化，不需要重跑未受影响的共享/Mac 验证；前片最终完整结果继续有效。真实 NAS/真机仍按对应功能既有 `PENDING_USER_VALIDATION`，本机聚焦通过不代替修正版完整云端。

实际运行命令（两端分别执行，日志头保留完整参数）：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/ci-final-after-phone.xcresult \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test外接存储切换筛选不把无匹配当设备消失' \
  '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test来源地址校验信任取消以及新增编辑移除' \
  '-only-testing:DsmMobileUITests/MobileRegionUITests/test未知保存重启恢复原设置并保护重复提交' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test当前账号保护和未知所属组仍可查看' \
  '-only-testing:DsmMobileUITests/MobileNasStorageUITests/test硬盘未知结果重启后只恢复状态' \
  '-only-testing:DsmMobileUITests/MobileRegionUITests/test格式与可搜索时区编辑保存及确认取消' \
  '-only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复' \
  '-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test取消剩余项目后空任务列表仍可查看与清除已结束记录' \
  '-only-testing:DsmMobileUITests/MobileDownloadRemovalUITests/test中文深色最大字号确认与结果支持横屏' \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test中文大字号未知开关有独立状态' \
  '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test中文大字来源信任与未加密风险可取消' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test资料保存未知后重启只读恢复'

xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/ci-final-after-pad.xcresult \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test外接存储切换筛选不把无匹配当设备消失' \
  '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test来源地址校验信任取消以及新增编辑移除' \
  '-only-testing:DsmMobileUITests/MobileRegionUITests/test未知保存重启恢复原设置并保护重复提交' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test当前账号保护和未知所属组仍可查看' \
  '-only-testing:DsmMobileUITests/MobileNasStorageUITests/test硬盘未知结果重启后只恢复状态' \
  '-only-testing:DsmMobileUITests/MobileRegionUITests/test格式与可搜索时区编辑保存及确认取消' \
  '-only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复' \
  '-only-testing:DsmMobileUITests/MobileDownloadControlUITests/test取消剩余项目后空任务列表仍可查看与清除已结束记录' \
  '-only-testing:DsmMobileUITests/MobileDownloadRemovalUITests/test中文深色最大字号确认与结果支持横屏' \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test中文大字号未知开关有独立状态' \
  '-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test中文大字来源信任与未加密风险可取消' \
  '-only-testing:DsmMobileUITests/MobileDirectoryUITests/test资料保存未知后重启只读恢复'

python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
python3 tools/release/test_apple_ci.py
git diff --check
```

修改前九项使用上述相同设备/派生目录，结果路径为 `ci-final-before-{phone,pad}.xcresult`，选择器不含追加的 NAS 中文大字、套件来源中文大字、账号重启恢复三项；原命令保留在各 before 日志首行。最终双语资源 6824/2188/3402、文档、CI 分组三项和差异检查均通过。

两端各二十张成功截图已逐张检查并保留于 `build/ci-final-preview/{phone,pad}/`：英文与中文大字、iPhone 深色/iPad 浅色及两端下载深色横屏、账号/硬盘/区域/计划任务恢复均有实际画面。来源移除页 iPhone 的中间标题被系统省略，但完整操作按钮和风险正文可见；作为已有展示细节记录，没有扩大本片产品修改。原八张失败证据保留，一次性附件导出和导出日志清理，正式结果包/日志保留。独立集成审查由当前负责人实现后单独执行：七份测试仅改变导航准备、实际值等待和结果定位，保留权限、危险确认、业务值、防重复及重启断言，未增加业务重试、静默跳过或产品改动。fetch 复核 origin/main 仍为 a776993c，没有远端新提交；同步后云端状态单独记录，不冒称完整门禁或真实 NAS 已通过。

2026-10-07 00:54 同步完成：本片提交 `04d692ab` 与前五个已验证功能/测试提交一并正常推送至 origin/main，远端核对 0 behind / 0 ahead，工作区干净。新 [Apple Build 37499218894](https://github.com/yuangy1995/dsm-native-client/actions/runs/37499218894) 对应该提交，初查 queued；不是发布或云端已通过。

## 2026-10-07 M7d0 虚拟机删除结果归属

基线 `04d692ab` 与 origin/main 一致、工作区干净；仅修 Apple 共享公开 VMM 删除的接受回执与完整清单判断、Mac VMM 结果反馈、两份 Bundle 中英文恢复提示及正式回归。无真实 NAS 写入，没有改变 API 参数、公开契约、身份、权限、存储、依赖或最低版本。

原先公开删除把丢回执后的目标消失计为成功；恢复读取失败又可丢掉原提交状态，Mac 刷新还可覆盖未知/部分结果。先新增六项共享用例中的前四项，并将原错误语义的四个既有测试改为更严格的“无接受证据不得成功”断言；基线十三项实际七个用例失败、四十一条断言失败（`build/m7d0-before.log`，exit 1）。修正接受标记、恢复未知计数、单项写后/批量停止，并复用原列表完整性检查；首轮六十五项聚焦通过（`build/m7d0-focused.log`，exit 0）。随后补齐首项缺回执时停止后项、预检不完整列表零写及 Mac 网络未知不被页面覆盖，全部纳入最终完整测试。

当前最终共享 **3003 XCTest、172 条既有跳过、0 失败**，另 **12 Swift Testing 通过**（`build/m7d0-shared.log`，exit 0）；移动构建成功，两端实际模拟器各 **22 项 VMM 清单/呈现模型测试、0 失败**（`build/m7d0-{phone,pad}.xcresult/log`，均 exit 0）。本片没有新增或修改移动页面，未把这些模型测试当作 UI 操作；前片两端十二项实际 UI 与四十张截图仍属对应 CI 修复证据。Mac Release 双架构构建成功（`build/m7d0-mac-build.log`，exit 0），实际 `lipo -archs` 确认主 App 与嵌入的 File Provider 扩展均为 x86_64/arm64；未打包、安装、启动或发布。

实际命令：

```sh
swift test --package-path apple --jobs 2 --filter 'DsmServiceManagementRepositoryTests/test公开删除|ServiceManagementModelTests/test未确认虚拟机|ServiceManagementModelTests/test部分虚拟机'
swift test --package-path apple --jobs 2 --filter 'DsmServiceManagementRepositoryTests/test公开|ServiceManagementModelTests'
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination generic/platform=macOS -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 "ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination "platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F" -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination "platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F" -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m7d0-phone.xcresult "-only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests" "-only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests"
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination "platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289" -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m7d0-pad.xcresult "-only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests" "-only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests"
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

独立集成与只读对抗复核由当前负责人在实现后单独执行，覆盖接受回执边界、明确拒绝、缺回执/回读失败、完整清单、批量后项停止、原 ID 防重复和 Mac 反馈。没有扩大写权限或弱化确认，没有新增静默跳过。最终本地化、文档及差异检查通过；没有一次性脚本/下载/附件导出残留，正式日志与结果包保留。Mac 标记仍限原仓库实例，真实时序、跨进程条件及尚未开发的移动操作不能视为已完成；具体条件见主计划。

最新读取 [Apple Build 37499218894](https://github.com/yuangy1995/dsm-native-client/actions/runs/37499218894)：对应 `04d692ab`，共享/Mac、iPad 工作区与 iPhone 三组运行中，iPad 管理/模块排队，尚无终态。为保留这一轮完整结果，本片先在 main 保存，不通过重复推送取消刚启动的验证；后续成组同步与云端结论另记。

## 2026-10-07 M7d1 虚拟机控制与移动恢复

基线 `5c81880a`，main 干净且领先 origin/main 一个 M7d0 提交；沿既有离线自主与必要 Mac 修复授权推进。Apple 共享公开/内部电源和 VM 删除共用严格原身份、状态、接受回执和结果流水线；内部 pwr_ctl v1 已使用 poweron/shutdown/poweroff/reboot，Guest.delete v1 已逐项提交。移动详情、多选、危险确认、逐项记录及跨重启只读恢复接入同一路径，独立记录仅保存摘要/阶段、不保存凭据或对象名称明文。工程由锁定 XcodeGen 2.46.0 生成，下载散列与 CI 一致；无依赖、最低版本、身份、系统权限或登录格式变化。

重启完成条件已经过官方静态补核：成功回调只恢复轮询，未消费 task_id；uptime 的类型、单位和重启变化未验证。只认领请求已接受，保留未知与互斥，不把仍 running 判为已完成，不用关开机替代重启。没有真实 NAS 写、真实 VM 正文读取或控制台连接；官方临时源码变量已移除并关闭调试面板，未导出 HAR。

真实中间失败与修正：

- 电源基线三项均失败、14 条断言失败（`build/m7d1-before.log`）：内部命令/回读及公开丢回执误认领。修正后聚焦通过；原取消用例曾把无回执但状态吻合当作成功，现已收紧断言为不得成功。
- 新移动 18 项首次 17 项通过、证书用例一项三条断言失败（`build/m7d1-model-before-phone.xcresult/log`）。共享层再现同一问题，一项三条断言失败（`build/m7d1-trust-before.log`）；修正映射后的 TLS 错误立即抛出、不继续读取或批量后项。最终共享聚焦 50 项全部通过（`build/m7d1-shared-focused-final.log`，exit 0）。
- 第一次共享全量 3013 XCTest 中一项请求快照测试失败：VM 删除预读 fixture 只有 ID，缺原名称和停机状态。只补预读原字段，保留真实 delete 请求精确比较。最终完整 **3013 XCTest、172 条既有跳过、0 失败**及 **12 Swift Testing 通过**（`build/m7d1-shared-final.log`，exit 0）。
- iPhone 第一次混合运行 40 项模型中 39 项通过，一项旧呈现测试仍要求只读资源键；已改成新操作/记录/删除后入口的精确键集合并明确禁止旧只读提示，未放宽集合断言。该运行中的九项实际 UI **全部通过，438.389 秒**（`build/m7d1-after-phone.xcresult/log`；组合进程因旧呈现测试 exit 65）。17 张深色合成截图已逐张检查；浅色补验、iPad 和模型终态见本节后续记录。

实际共享与构建命令：

```sh
swift test --package-path apple --jobs 2 --filter 'DsmServiceManagementRepositoryTests/test公开|DsmServiceManagementRepositoryTests/test内部电源|DsmServiceManagementRepositoryTests/test内部重启|DsmServiceManagementRepositoryTests/test内部虚拟机|DsmServiceManagementRepositoryTests/test虚拟机.*删除|DsmServiceManagementRepositoryTests/test移动电源|DsmServiceManagementRepositoryTests/test移动删除|DsmServiceManagementRepositoryTests/test未知删除'
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination generic/platform=macOS -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests -resultBundlePath build/m7d1-after-phone.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests -resultBundlePath build/m7d1-after-pad.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

实现后的独立集成与只读对抗复核由当前负责人单独执行，覆盖整批/逐项原快照、撤权、取消、存储四阶段、接受与无回执区分、ID 改名、跨账号迟到、记录损坏和 TLS 停止。Mac 仍用原兼容调用，只共享请求修正与资源，不新增持久恢复；Windows/Android 仅记录契约影响。真实 NAS 时序、来宾关机代理、强断/删除副作用和真机文件保护见主计划 `PENDING_USER_VALIDATION`，创建/编辑、资源及控制台仍为未完成源码范围。


M7d1 后续终态补充：iPad 九项实际 UI 全部通过，461.888 秒（`build/m7d1-after-pad.xcresult/log`，exit 0），17 张合成截图已逐张检查。发现原 `AppleInterfaceStyle` 测试参数未覆盖 App 外观，因此 iPad 名为深色的用例实际为浅色；改用既有 `lanstash.mobile.settings.appearance.v1` 设置键，后续单独补验，不能把原场景名称当作深色证据。更新后的移动构建已通过（`build/m7d1-mobile-build-theme.log`），两端三类模型各 **40 项、0 失败**，包括全部 18 项新控制行为。Mac Release 构建 exit 0（`build/m7d1-mac-build.log`），`lipo -archs` 实际确认主 App 与内嵌 File Provider 扩展均包含 x86_64/arm64；未打包、安装、启动或发布。


最终三项主题专项两端均通过：iPhone 114.576 秒、iPad 126.452 秒（`build/m7d1-final-{phone,pad}.xcresult/log`，两个进程均 exit 0），同次两端各 40 项模型全部通过。最终 12 张截图逐张复核，确认实际英文浅色与中文大字深色、风险全文、确认/取消、详情和成功结果可用；连首轮合计 46 张检查，原 iPad 初轮中文场景只算浅色证据。保留四张便于查看的合成图于 `build/m7d1-preview/`；一次性导出、日志和下载的 XcodeGen 工具已清理，正式结果包及构建/测试日志保留。

两端最终实际命令如下（其余参数与本节 build-for-testing 一致）：

```sh
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test普通套件账号开机并查看逐项结果 -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test删除取消保留目标随后删除仍能查看记录 -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test中文大字深色强制断电确认与取消可用 -resultBundlePath build/m7d1-final-phone.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test普通套件账号开机并查看逐项结果 -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test删除取消保留目标随后删除仍能查看记录 -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test中文大字深色强制断电确认与取消可用 -resultBundlePath build/m7d1-final-pad.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

本地化完整性/硬编码扫描通过：Apple 6859、Android 2188、Windows 3402。文档与差异检查通过。
已读取远端 main，没有新提交；最新 `04d692ab` 的 Apple Build 37499218894 共享/Mac 成功，
移动五组运行/一组排队，尚无整轮终态。M7d0/M7d1 先在 main 保存，后续正常成组推送，
避免取消当前完整验证；本机通过不等于该云端已包含本片，也不代表真实 NAS 或正式发布。

## 2026-10-07 M7d2 虚拟机基础设置编辑

从 `53a75fda` 的干净 main 开始，领先远端两个已验证的 VMM 提交；沿离线自主及必要
Mac 基线修正授权实施。新增移动名称/说明、CPU/精确 MiB 内存、五档 CPU 优先级、
三态自动启动编辑；只传变更字段，只有明确停机才允许硬件变更，未知读取不补默认值。
共享内部 get/list 固定 v2、set 固定 v1，保存前比对原快照和完整清单，写前/接受/
拒绝/完成分别落盘；编辑与电源/删除互斥，未知不重发，已接受记录按原身份及字段
摘要只读恢复。Mac 旧调用复用修正但不新增持久恢复，Windows/Android 无源码修改。
工程使用锁定 XcodeGen 2.46.0 生成，只增加新表单文件；无依赖、身份、权限或最低
系统版本变化。移动恢复格式与回滚范围见主计划，不迁移登录配置或已发布 Mac 数据。

实际中间失败保留如下：

- 基线三项测试七条失败断言复现过渡状态仍能改硬件、丢回执重发和编辑/电源交叉
  操作未保护（`build/m7d2-baseline.log`）。修正后共享仓库最终 **182 项全通过**
  （`build/m7d2-shared-focused3.log`）。新增 helper 初次缺参数、随后测试文字替换
  参数标签错误已修正；旧测试预读公开来源/回读缺名称已补准确内部原字段，未降低断言。
- 完整共享首轮 3022 XCTest 只有一份请求 fixture 失败，其能力只声明 Guest v1；
  该用例已补实际读取需要的 v1–v2 范围和原名称，set v1 请求精确断言保持。最终
  **3022 XCTest，172 条既有跳过，0 失败；12 Swift Testing 全通过**
  （`build/m7d2-shared-final.log`，exit 0）。
- 移动首次构建发现 catch 中 `error` 遮蔽模型属性，已修为 `self.error`；第二轮
  **TEST BUILD SUCCEEDED**（`build/m7d2-mobile-build2.log`，exit 0）。两端各
  **47 项 VMM 模型均通过**，含 25 项控制/编辑行为；实际 UI 终态续记于下。

Mac Release 增量构建 **BUILD SUCCEEDED、exit 0**（`build/m7d2-mac-build.log`）；
`lipo -archs` 确认 `LanStash.app/Contents/MacOS/LanStash` 及
`LanStashFileProvider.appex/Contents/MacOS/LanStashFileProvider` 均为 x86_64/arm64。
构建路径为 `apple/Apps/DsmMac/build/m0-m8/Build/Products/Release/`，未打包、
安装、启动或发布 Mac 应用。

实现后独立集成/只读对抗复核覆盖固定版本、严格原字段、原快照、逐阶段持久化、
接受与未知、改名前后名保护、交叉操作、损坏记录、账号切换和证书停止。复核发现
旧账号表单保存会向新账号写错误状态，已把激活身份检查前置，并补正式回归。
复核由当前负责人单独执行，不冒称另一模型或真实 NAS 验收；没有操作现有真实 VM。

实际执行命令：

```sh
swift test --package-path apple --jobs 2 --filter DsmServiceManagementRepositoryTests
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination generic/platform=macOS -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests -resultBundlePath build/m7d2-phone.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests -resultBundlePath build/m7d2-pad.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

首轮实际 UI：iPhone 14 项中 12 通过、2 失败（751.809 秒），iPad 14 项中 13 通过、
1 失败（881.467 秒），两个组合进程均 exit 65；两端 47 项模型均通过不受影响。
旧九项电源/删除 UI 两端全部通过。iPhone 说明清空时键盘事件尚未结束，录屏末段
显示文本仍在递减，旧测试立即读取因而失败；现等待字段确实清空，再输入并核对完整
新值，不重复退格或降低断言。两端错误页重试按钮实际可见，但 ContentUnavailableView
整页标识覆盖了子按钮标识；现把状态标识移到标题，保留按钮独立标识，并补失败层级
与截图附件。没有改请求、权限或恢复语义。

另将共享保存结果提示与移动“操作记录”导航分开：Mac 提示刷新虚拟机，不引用仅移动
存在的操作记录入口。英文和简体中文资源同步，最后六项本地化测试通过
（`build/m7d2-localization-final.log`，exit 0）；移动最终测试构建与 Mac 最终资源
增量构建均 exit 0，分别见 `build/m7d2-mobile-build-final.log`、
`build/m7d2-mac-build-final.log`。首轮 52 张合成截图已逐张复核，覆盖两端正常表单、
512/768 MiB、中文大字深色、取消、记录、恢复及旧控制五态；另检查三张 iPhone 失败
录屏取帧。

最终五项编辑场景两端均 **0 失败、exit 0**：iPhone **332.112 秒**，iPad
**371.760 秒**（`build/m7d2-final-{phone,pad}.xcresult/log`）。最终 20 张截图已
逐张检查，正常/修改表单、中文大字深色、丢回执、接受后恢复、加载与错误重试均
有实际证据；连首轮共 72 张成功场景截图。原九项控制和两端各 47 项模型沿用本轮
首轮通过结果，最后只修改标识/文案/输入等待，不重复无关整组。

最终 UI 的两个实际命令使用本节同一 project/scheme/derivedDataPath、对应设备、
`-jobs 2 -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，
各自结果路径为 `build/m7d2-final-phone.xcresult` 与 `build/m7d2-final-pad.xcresult`，
选择器准确如下：

```sh
-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test编辑丢回执跨重启仍保护原目标
-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test编辑中文大字深色运行中硬件禁用与取消
-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test编辑名称说明与精确内存保存后显示记录
-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test编辑接受后断网跨重启只读恢复
-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test编辑读取加载与错误可关闭重试
```

最终本地化完整性/硬编码扫描通过（Apple 6877、Android 2188、Windows 3402）；
请求契约 179 fixture/1 写结果示例、响应 29 组与 48 私有端点文档引用检查通过。
分别执行 `python3 tools/localization/check_localization.py`、
`python3 tools/request-contract/validate_contracts.py`、
`python3 tools/contract-validation/validate_fixtures.py`；文档及差异检查通过。
重新读取远端 main 无新提交；既有 `04d692ab` 云端共享/Mac 成功，五个移动组运行、
一个排队，尚无整轮结果。继续先在 main 保存本片，后续正常成组同步，不通过推送
取消当前完整回归，也不将本机结果当作云端、真实 NAS 或正式发布结果。

收尾保留八张最终合成预览于 `build/m7d2-preview/`，正式测试结果包和构建/测试日志
继续保留；一次性附件导出、录屏取帧、临时脚本及下载的锁定工程生成工具已精确清理。
两台模拟器系统外观均恢复/读取为浅色；App 最后一项实际场景也为浅色。没有真实
NAS 写入、安装包发布或用户数据修改。

## 2026-10-07 M7d3 虚拟机创建与中断恢复

基线 `41ac8407`，main 领先 origin/main 三个已完成本机验证的 VMM 提交；沿既有
离线自主授权实现本片，不触碰真实 VM/资源。移动新增四步创建表单、精确 MiB 输入、
单空白盘/存储、网络或断开、ISO/固件和启动选项，以及独立受保护摘要记录。
共享创建保留原 UUID/任务/完整参数摘要，通过原任务完成、新 ID 与完整配置匹配
确认结果；丢回执、任务缺失或配置不足保持未知，刷新和重启只读恢复，不按同名认领。
与 VM 编辑/电源/删除和所选资源写入互斥。Windows/Other 预设、ISO 启动字段及
10 GiB 最低磁盘按已有记录修正；Mac 表单只同步最低磁盘值，旧调用保持兼容，
不新增 Mac 持久恢复。Windows/Android 仅更新影响说明。

独立集成及只读对抗复核发现映像需同时匹配存储/主机、创建资源引用需保护，均已补齐；
另用 HTTP 401 负例复现旧流程继续读任务并误完成（1 项测试、2 条失败断言），
修正后认证/OTP/权限错误立即停止后续查询。全部代码与测试只使用合成数据，
没有提升 DSM/VMM 环境的真实证据等级。复核由当前负责人另行执行，不冒称其他模型。

本机实际结果与中间失败：

- 创建基线三个用例四条失败断言复现丢回执重发、同名误成功及低于最低磁盘仍提交；
  修正后新增共享创建流程最终 **13 项**及原服务仓库 **182 项**全部通过，
  `build/m7d3-shared-auth-focused.log`（exit 0）。初次测试的
  `await XCTUnwrap` 自动闭包编译问题已修，不降低原线级请求断言。
- 完整共享最终 **3035 XCTest，172 条既有条件跳过，0 失败；12 Swift Testing
  全通过**，`build/m7d3-shared-reviewed.log`（exit 0，79.362 秒）。
- 首次全新移动派生目录拉取既有 Sparkle 依赖时发生 GitHub HTTP/2 错误，已停止
  该进程并改用现有依赖缓存；没有更改依赖版本。新 UI 测试首次缺少 `@MainActor`
  已补齐。最终移动测试构建 **TEST BUILD SUCCEEDED、exit 0**，日志
  `build/m7d3-mobile-reviewed-build.log`。
- 首轮两端各 60 项模型只有固定资源键集合漏新增创建标题，已准确补键；新 13 项
  创建行为均通过。首轮 UI：iPhone 9 项中 8 通过，iPad 9 项中 7 通过；旧三个
  开机/编辑保存/编辑未知恢复全部通过。中文菜单测试误用 `Windows`，实际资源为
  `Microsoft Windows`；iPad 精确输入完成后原生数字键盘浮层仍在，需先关闭浮层。
  依据截图/层级修正实际测试操作，保留精确 768 MiB 与选项断言。
- 首轮 **42 张**合成截图逐张复核，另有已检查的 iPad 键盘失败层级。输入框重复
  无障碍标签已改为单一标签；摘要的存储后果提示移到顶部，切换步骤回到顶部，
  新增独立标签与风险可见断言。增加 HTTP 登录失效移动行为测试后，两端最终
  **61 项模型、0 失败**。最终六项创建 UI 和未修改的文件批删云端失败用例终态续记。
- Mac 最终 Release 双架构构建 **BUILD SUCCEEDED、exit 0**，日志
  `build/m7d3-mac-reviewed-build.log`；主 App 和内嵌 File Provider 扩展均通过
  `lipo -archs` 确认 x86_64/arm64。未打包、安装、启动或发布应用。
- XcodeGen 2.46.0 下载 SHA256 与 CI 锁定值一致，经正式生成流程更新工程；差异
  只有四个新增源码/测试文件共 16 行。语言完整性/硬编码扫描、请求/响应契约和
  私有引用、文档与差异检查均通过；没有新增依赖、最低版本、身份或系统权限。

最终共享、构建及两端测试实际命令（均在仓库根目录）：

```sh
swift test --package-path apple --jobs 2 --filter 'VirtualMachineCreationWorkflowTests|DsmServiceManagementRepositoryTests'
swift test --package-path apple --jobs 2
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination generic/platform=macOS -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileTests/MobileVirtualMachineCreationTests -only-testing:DsmMobileUITests/MobileVirtualMachineCreationUITests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test批量删除文件和文件夹明确后果且刷新源列表 -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -resultBundlePath build/m7d3-phone-final.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileTests/MobileVirtualMachineCreationTests -only-testing:DsmMobileUITests/MobileVirtualMachineCreationUITests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test批量删除文件和文件夹明确后果且刷新源列表 -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -resultBundlePath build/m7d3-pad-final.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

设备/NAS 前置、步骤、预期结果和最小脱敏反馈见移动主计划 M7d3 的四项
`PENDING_USER_VALIDATION`。当前 Mac 没有既有 VM 磁盘/网卡/ISO 高级编辑及多盘多 NIC
表单，这些不因笼统旧描述扩张本轮范围，两端继续用官方 VMM 网页；明确目标中的
网络/映像资源管理、控制台与 M8 系统集成仍继续源码实施，不算本片已完成或仅待真机。

最终两端组合测试均 **TEST EXECUTE SUCCEEDED、exit 0**。各 61 项模型零失败；
新六项创建 UI：iPhone **432.884 秒**、iPad **477.467 秒**，全部通过。未修改的
文件批删用例本机也通过（分别 **27.473 秒 / 23.565 秒**），所以每端七项 UI
总时长分别 **460.357 秒 / 501.032 秒**；本机未复现云端启动卡住，不能据此声称
云端故障已修复。最终 **36 张**合成截图全部逐张检查，包含中文深色大字摘要/选项、
精确 768 MiB 与键盘关闭、成功/未知/已接受/拒绝、加载/空/重试及两端文件批删结果；
连首轮共 78 张。

收尾保留 10 张合成预览于 `build/m7d3-preview/`，测试结果包与正式验证日志留在
忽略目录；一次性附件导出、下载的工程生成工具和未使用的新派生目录已精确清理。
两台模拟器系统外观已恢复并读取为浅色。提交前读取远端 main，无远端新提交；
当前 04d692ab 云端还有三组运行，先在 main 保存本片，避免推送取消未结束的整轮。
本片本机通过与云端故障分别记录，不将其视为真实 NAS 验收或发布。

## 2026-10-07 云端模块开关读取与文件启动阻塞复核

本片基线 `4a97752`，只修改正式 UI 共用导航测试和证据文档，不改产品代码、NAS 请求、
权限或恢复。按已宣布使用的 gh-fix-ci 工作流核对 main 的实际运行，不创建 PR。
[Apple Build 37499218894](https://github.com/yuangy1995/dsm-native-client/actions/runs/37499218894)
对应 `04d692ab`。当前共享/macOS 与 iPhone 工作区成功；iPhone 模块组 131 项 UI 中
128 通过、3 失败，均是 `MobileContainerControlUITests` 的模块开关准备：
`test多项删除逐项展示完成且托管容器不可选`、`test托管和运行字段缺失均不能提交控制`、
`test批量删除第二项未知保留第一项完成`。原始日志为
`build/m7d3-ci-iphone-modules.log`，原始结果包已下载并导出三个精确用例；三张截图
均逐张检查，开关完整显示且关闭，辅助功能树存在外层标识和内层 Switch，尚无业务写入。

首个失败的复合等待在 28.28 秒开始读取 `exists`，到 34.70 秒才继续定位 Switch，
37.51 秒随即开始捕获失败信息；连续属性读取消耗整个十秒等待窗口。共用 helper
现在只轮询内层开关 `hittable`，完成后另行读取/断言 `isEnabled`，再做一次按下/抬起
并确认外层值变为 1。外层显露和所有业务断言保持，不增加超时或重试，不以截图
代替可点击性断言。两端聚焦构建/交互结果续记于下，云端仍须实际复验。

iPad 工作区只失败 `MobileWorkspaceUITests.test批量删除文件和文件夹明确后果且刷新源列表`：
初始等待 Sample folder 时超时，175.383 秒后结束，未进入删除。原日志
`build/m7d3-ci-ipad-workspace.log`、结果包与失败录屏均已检查；录屏 0.5 秒、20 秒和
168.9 秒三帧分别为启动与持续的 File 加载页。导出 App 诊断后确认 17:49:02 等待
主线程空闲，17:50:34、17:51:07、17:51:38 连续三次报告主线程 30 秒无响应，
直到测试终止阶段才恢复；导出的诊断不含该次阻塞栈，不能断言是产品或 Runner 原因。
同一原用例未修改并在 M7d3 两端本机通过（27.473 秒 / 23.565 秒），故暂不增加
重试、放宽断言或修改文件业务；保留未解决结论，后续完整云端再次运行验证。

调整后测试构建及两端实际测试均 **exit 0**。iPhone 五项 UI **212.004 秒**，
iPad 五项 UI **228.178 秒**，无失败；日志及结果包为
`build/m7d-ci-readiness-{phone,pad}.log/xcresult`，构建日志为
`build/m7d-ci-readiness-build.log`。十六张截图逐张复核，三个云端失败用例均已走到
原业务断言和结果页；中文删除风险、托管限制、字段缺失不能控制、逐项未知保护
均保持。另记录 iPhone 群公告附件按钮最大字号的既有断行裁切，本次只验证导航/搜索，
未据此宣称附件布局完善，也未修改聊天产品。

实际执行命令：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination "platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F" -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test多项删除逐项展示完成且托管容器不可选" "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test托管和运行字段缺失均不能提交控制" "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test批量删除第二项未知保留第一项完成" "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test中文大字删除风险完整可读且取消按钮可用" "-only-testing:DsmMobileUITests/MobileChatManagementUITests/test中文深色大字公告筛选空状态" -destination "platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F" -resultBundlePath build/m7d-ci-readiness-phone.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test多项删除逐项展示完成且托管容器不可选" "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test托管和运行字段缺失均不能提交控制" "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test批量删除第二项未知保留第一项完成" "-only-testing:DsmMobileUITests/MobileContainerControlUITests/test中文大字删除风险完整可读且取消按钮可用" "-only-testing:DsmMobileUITests/MobileChatManagementUITests/test中文深色大字公告筛选空状态" -destination "platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289" -resultBundlePath build/m7d-ci-readiness-pad.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

独立复核只涉及测试条件求值，存在/可点击/未禁用/最终开启及所有业务限制仍有断言；
没有增加等待时长或重试，也没有产品、契约、资源或 Mac 改动，故未重复共享/Mac 门禁。
两端系统外观恢复并读取为浅色。保留正式日志/结果包和 `build/m7d-ci-preview/` 的
十一张合成预览（八张本机结果、三张云端原失败）；一次性 CI 下载、诊断、录屏取帧
及附件导出已精确清理。当前完整云端剩余三组仍运行，不为推送中断，后续再正常
同步已验证的 main 提交。初始文件加载阻塞仍是待云端复验的未解决问题。

## 2026-10-07 M7d4a 虚拟机网络改名、删除与恢复

基线 `43bf176`，沿已批准 M6–M8 和必要 Mac 基线修正范围，单一修改共享网络领域/
仓库、移动详情/改名/单多删/摘要恢复、正式测试、双语资源、生成工程及契约说明。
Mac App、Windows、Android 源码无改动；Mac 原协议调用使用同一共享修正。没有
连接或写入真实 NAS，也没有新增依赖、权限、应用身份或最低系统版本。

Network.list/get 固定 v2，严格原生类型/完整数组/唯一 ID 与名称/冻结/关联数量；
get 没有 ID，结合原 list、名称和数量绑定。仅改名固定 set v1，external 空接口增量
数组、private 原 host_id，不改 VLAN/接口；delete v1 单 ID 逐项提交，未知后停止
后项。写前/接受/拒绝/完成阶段分别落盘，摘要不含名称、地址或凭据明文。没有接受
回执不由外部同名或列表消失认领结果。同名网络、关联 VM 写与引用网络的创建互斥；
已接受且原结果符合后才解除保护。Mac 未改名称保存保留零写行为，普通页面刷新也
追加必要的严格恢复读取，其记录仍限仓库实例；其他分区不因网络恢复读取失败中断。

独立集成及只读对抗复核由当前负责人进行，不冒称另一模型或真实 NAS 验收。
首先用 5 项合成测试复现 8 条旧行为失败断言（冻结仍写、两类改名字段缺失、重复
改名、丢回执删除误报完成）。首次新增 16 项时 HTTP 登录失效误归为普通未知的
断言失败，已修正并保证不继续查询。后续复核补同名/关联 VM/资源互锁；另一个
Mac 普通刷新恢复用例再次复现失败，已将该入口接入原严格读取后通过。

实际验证：

- 共享首轮聚焦 36 项通过；最后对共享服务管理、创建、网络和 Mac 模型运行 252 项，
  全部通过（0.485 秒）。`build/m7d4a-integration-final.log`。
- 最终完整共享 3055 项 XCTest，172 条既有环境条件跳过，零失败（88.746 秒）；
  另 12 项 Swift Testing 通过。`build/m7d4a-shared-final.log`。先前完整 3054 项
  通过属于增加 Mac 普通刷新回归前的结果，不能代替本次最终结果。
- 移动两次测试包构建均通过；最后为 `build/m7d4a-mobile-final-build.log`。
  工程由校验 SHA256 的 XcodeGen 2.46.0 生成，只增加两个产品源文件及两个测试文件。
- 首轮 iPhone/iPad 各 78 项模型全部通过（1.112/1.195 秒）。旧开机和分步创建 UI
  均通过；六项新网络 UI 各五项通过，一项在完成改名和记录检查后查找搜索框失败。
  日志、原层级和截图证明返回列表后 SearchField 不在页面，按既有容器网络模式改为
  常驻导航搜索栏，没有放宽断言。iPhone 八项 UI 总用时 494.734 秒，iPad 574.732 秒。
- 首轮两端各 24 张、共 48 张实际截图逐张复核。中文深色大字号后果/取消、原生弹窗、
  恢复、部分结果、加载/空/错误/冻结均有证据；发现网络选择标签误用 VM 资源键，已
  改为双语“选择网络”，并统一按钮内容的完整点击区域。首轮素材仍不能证明最终搜索
  已修，后续目标复验单独记录。
- 最终两端新增网络模型各 19 项已通过，补充未完成创建保护所引用网络以及创建资源
  排除未完成网络；最终四项网络界面专项各自全部通过，iPhone 193.316 秒、iPad
  211.832 秒，两个结果包均为 23/23 通过。搜索为空、中文大字号、部分结果和接受后
  恢复已实际复验；最终 22 张截图全部复核，连首轮共 70 张。
- 最终 Mac Release 增量构建通过，`lipo -archs` 核对主 App 与 File Provider 扩展
  均实际包含 x86_64/arm64。`build/m7d4a-mac-final-build.log`。没有安装/启动测试包
  或执行正式签名发布。临时下载工具和四份附件导出在交付前清理，正式日志/结果包
  与精选预览保留在本机 build 下。

实际命令（均从仓库根目录执行）：

```sh
swift test --package-path apple --jobs 2 --filter 'VirtualMachineNetworkWorkflowTests|DsmServiceManagementRepositoryTests|VirtualMachineCreationWorkflowTests|ServiceManagementModelTests'
swift test --package-path apple --jobs 2 --skip-build
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination generic/platform=macOS -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileVirtualMachineNetworkTests '-only-testing:DsmMobileUITests/MobileVirtualMachineNetworkUITests/test网络详情改名搜索和完成记录' '-only-testing:DsmMobileUITests/MobileVirtualMachineNetworkUITests/test中文深色大字删除后果和取消' '-only-testing:DsmMobileUITests/MobileVirtualMachineNetworkUITests/test网络多选第二项未知仍保留第一项成功' '-only-testing:DsmMobileUITests/MobileVirtualMachineNetworkUITests/test已接受改名跨重启恢复且解除保护' -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -resultBundlePath build/m7d4a-phone-final.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

iPad 最终使用相同命令，将设备替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，
结果路径替换为 `build/m7d4a-pad-final.xcresult`。首轮包括全部五组 VM 模型、六项
`MobileVirtualMachineNetworkUITests`，以及旧开机和分步创建各一项 UI，使用同一
构建/签名设置，结果为 `build/m7d4a-{phone,pad}.xcresult`。

真实 external/private 网络字段、连接副作用、SR-IOV 拒绝、外部客户端竞态、系统
文件保护/锁屏和完整辅助功能未验证。专用网络及 VM 的前置条件、操作、预期结果
与允许回传的脱敏信息见主计划 M7d4a 的四项 `PENDING_USER_VALIDATION`；不对既有
真实网络测试写入。映像删除、控制台和 M8 仍继续源码切片，不列作本片待设备验证。

## 2026-10-07 M7d4b 虚拟机映像删除与恢复

基线 `0dbf302d`，单一修改共享映像领域/严格读取/逐项删除、移动原生详情/选择/确认/
结果和独立摘要恢复、正式测试、双语资源、生成工程与五端影响说明。Mac App 源码
未改，既有 Mac 协议调用共用修正；Windows/Android 仅记录影响，没有访问或写入
真实 NAS。沿已批准恢复范围新增受保护、排除备份的映像操作摘要文件，不迁移
登录或已发布 Mac 数据；无第三方依赖、权限、应用身份或最低系统版本变化。

公开 Guest.Image list/delete 固定 v1、image_id；内部固定 v2、id/synovmm_ui_id。
内部完整 is_freeze、名称/类型与所有主机/存储副本共同绑定原对象；同位置重复或
身份冲突拒绝写入。ISO 只通过已记录 Guest.list v2/get_setting v1 的 iso_images
检查占用，停止 VM 仍不能删除挂载映像。公开未提供的属性不伪造，仍依赖 NAS
拒绝与完整结果。创建与未完成映像删除双向互锁，Mac 普通刷新只恢复已接受结果。
移动记录只保存原上下文/映像身份/快照摘要、来源、阶段、回执与时间，不含名称、
位置或凭据；未知不重放，第二项未知停止后项，已完成项保留。

当前负责人另做独立集成与只读对抗复核，未冒称其他模型或真实 NAS 验收。覆盖
完整清单/副本、来源变化、挂载、冻结、原确认对象、丢回执和外部删除、接受保存
失败、迟到回执、账号隔离和创建互锁。初始五项测试复现旧实现十三条失败断言
（`build/m7d4b-shared-before.log`）。统一删除流程的取消分支曾导致两个旧 VM
删除测试失败，恢复原取消结果计数后通过；认证/证书异常仍立即停止，不追加读。
最终增加 Mac 普通刷新和内部未完成删除保护创建的回归，全部通过。

实际验证：

- 共享最终聚焦 `DsmServiceManagementRepositoryTests`、创建/网络/映像工作流及
  `ServiceManagementModelTests` 共 266 项通过；新增映像工作流 14 项。
  日志 `build/m7d4b-integration.log`。
- 最终完整共享 3069 项 XCTest，172 条既有环境条件跳过、零失败（81.562 秒），
  另 12 项 Swift Testing 通过。`build/m7d4b-shared-full.log`。
- 移动首次测试包构建因复杂 SwiftUI 根视图类型检查超时失败；将原内容拆为私有
  content 后第二次通过。修正 UI 断言后的最终测试包也通过，日志分别为
  `build/m7d4b-mobile-build-second.log`、`build/m7d4b-mobile-final-build.log`。
  XcodeGen 2.46.0 生成工程，只新增四个移动文件引用，重复生成哈希一致。
- 两端首轮各 74 项 VM 模型全部通过（iPhone 1.444 秒、iPad 1.420 秒），包括
  25 项控制、14 项创建、19 项网络及新增 16 项映像测试。旧分步创建 UI 两端通过。
- 六项新映像 UI 首轮每端五项通过，一项详情断言失败；原层级显示 SwiftUI 将
  LabeledContent 合并为 `Type, Installation image`，而测试错误地寻找独立
  `Installation image`。仅修正完整辅助功能文本定位，不改产品、不放宽结果。
  首轮七项 UI 用时 479.090/600.981 秒，结果在 `build/m7d4b-{iphone,ipad}.xcresult`。
- 最终完整单项删除、完成记录及搜索空态专项两端通过（49.148/54.524 秒），结果
  在 `build/m7d4b-{iphone,ipad}-final.xcresult`。其余五项首轮已覆盖中文深色大字号
  后果/取消、多项部分成功、丢回执重启、接受后断网恢复，以及加载/空/错误/冻结/占用。
  首轮 38 张、最终 10 张，共 48 张实际截图逐张复核。
- Mac Release 增量构建通过，`lipo -archs` 核对主 App 与 File Provider 扩展均含
  x86_64/arm64；日志 `build/m7d4b-mac-build.log`。没有安装、启动或发布 Mac 包。
- 本地化与硬编码检查为 Apple 6972、Android 2188、Windows 3402 键；请求契约
  180 个请求 fixture/1 个结果 fixture，以及 29 个发现 fixture/48 个私有文档引用
  检查通过。文档与差异空白检查通过；内部新增请求 fixture 只用合成 ID。

实际命令（仓库根目录）：

```sh
swift test --package-path apple --jobs 2 --filter 'DsmServiceManagementRepositoryTests|VirtualMachineCreationWorkflowTests|VirtualMachineNetworkWorkflowTests|VirtualMachineImageWorkflowTests|ServiceManagementModelTests'
swift test --package-path apple --jobs 2 --skip-build
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination generic/platform=macOS -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 '-only-testing:DsmMobileUITests/MobileVirtualMachineImageUITests/test映像详情单项删除记录和搜索空态' -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -resultBundlePath build/m7d4b-iphone-final.xcresult
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/codex/check_documentation.py
```

iPad 最终替换目的设备为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果为
`build/m7d4b-ipad-final.xcresult`。首轮同一 test-without-building 命令同时选取上述
四组模型、全部六项 `MobileVirtualMachineImageUITests` 和旧
`MobileVirtualMachineCreationUITests/test分步创建保留精确内存并显示完成记录`。

真实 NAS 删除、ISO 占用、多副本/跨客户端竞态、文件保护/锁屏、权限变化与完整
辅助功能未验证；专用可丢弃目标的四项 `PENDING_USER_VALIDATION` 见主计划 M7d4b。
这些待办不固定禁用已实现入口，也不提升真实 API 等级。映像导入/创建无当前 Mac
产品基线，两端使用官方 VMM；触控控制台与 M8 仍需源码实施。

## 2026-10-07 云端 NAS 模块开关操作复核

基线 `00261f2`、main 工作区干净，只修改 `MobileUITestNavigation` 的模块开启
手势、`MobileDDNSUITests` 的共用导航/开启调用，以及证据文档。产品、NAS 请求、
权限及全部业务断言未改；不增加自动重复触摸，不改变共用等待上限。

旧提交 `04d692ab` 的 [Apple Build iPhone-administration](https://github.com/yuangy1995/dsm-native-client/actions/runs/37499218894/job/112391591908)
共 134 项、132 通过、两项失败：DDNS 已有记录保存/取消/删除在模块开启后找不到
导航，存储卷/池详情在开启后最终值仍为 0。原结果包按精确用例导出截图/层级与
录屏。存储层级及合成事件证明开关可见、启用，触点位于内层开关中心；按下后仍
关闭。DDNS 录屏也停在未开启的设置页。两段录屏各四帧已查看，未读取真实 NAS。
`--only-failures` 导出未得到附件，因为这些诊断附件关联标记为 false；后续改用
精确 `--test-id` 导出，不能把空导出当作没有失败证据。

本机改前直接运行原两项，iPhone 88.733 秒、iPad 117.228 秒，均通过；没有复现
云端单次触摸未生效的底层原因，也不把它归因于产品或宣称已被前片等待修正解决。
本次用内层原生开关从关闭位置到开启位置的一次拖动表达明确目标，再验证值为 1；
DDNS 接既有导航帮助方法，检查设置页已呈现后才开启。独立集成审查确认没有修改
数据或降低断言，失败仍保留层级/截图供下一云端诊断。

实际验证：

- 测试包构建通过：`build/m7d-ci-admin-build.log`。
- 原两项加 DDNS 中文大字号取消、容器中文大字号删除取消、聊天中文深色大字
  公告搜索，共五项 UI 每端全部通过：iPhone 211.747 秒、iPad 247.203 秒；结果为
  `build/m7d-ci-admin-{phone,pad}.xcresult`，日志同名。
- 改前八张与改后十六张，共二十四张实际截图逐张复核。iPhone 群公告最大字号
  附件按钮裁切仍是前片已记录的产品相邻问题，不在本测试操作修正中宣称解决。
- 文档、差异检查通过。本片没有产品/共享源码变化，不重复共享或 Mac 构建，沿用
  紧邻 M7d4b 的真实构建结果；两端 UI 测试包使用本片最终测试源码重新构建。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 '-only-testing:DsmMobileUITests/MobileDDNSUITests/test已有记录保存开关并可取消或确认删除' '-only-testing:DsmMobileUITests/MobileNasStorageUITests/test卷与存储池详情区分明确状态并可以返回' '-only-testing:DsmMobileUITests/MobileDDNSUITests/test中文大字详情与风险确认可触达并取消' '-only-testing:DsmMobileUITests/MobileContainerControlUITests/test中文大字删除风险完整可读且取消按钮可用' '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test中文深色大字公告筛选空状态' -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -resultBundlePath build/m7d-ci-admin-phone.xcresult
python3 tools/codex/check_documentation.py
git diff --check
```

iPad 用相同测试选择，设备替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果
替换为 `build/m7d-ci-admin-pad.xcresult`。改前仅选择原两个失败用例，结果文件名
含 `-before`。云端仍有两组 iPad 作业运行，没有主动取消；此修正尚未经过下一轮
完整云端，不将本机通过表述为云端已修复。后续继续控制台与 M8 源码切片。


## 2026-10-07 M7d5 虚拟机触控控制台与共享安全宿主

开始于 main `4d19f623`，沿用户既有共享提取、必要 Mac 基线修复和两种模拟器授权。
新增 `DsmCore/VirtualMachineConsole`、`DsmNetwork/DsmVirtualMachineConsoleTransport`、
共享 `DsmVirtualMachineConsoleFeature`，移动入口/完整页面/生命周期和合成 UI 场景；
修改原仓库准备、General 能力发现、TLS/HTTP 可选拒绝重定向、Mac 窗口及退出清理、
双语资源和正式生成工程。正式测试覆盖原身份/状态、默认键盘、权限、证书、网页
来源、消息顺序与生命周期；Windows/Android 未改源码。

凭据始终留在原生内存，网页资源和固定 VM/app_id 的 WSS 统一沿既有信任配置。
非持久 WebKit 使用自定义单窗口来源、有限静态文件及语言桥，保留服务器 CSP，
禁止网页直接联网、导航外站、新窗口、frame/object/worker。关闭、切账号与移动
离开前台会停止连接，重连由用户主动发起，不自动重发输入。实际 NAS noVNC/RFB
未连接，不把合成页面或本机 WSS 握手写成真实 VNC 已验证。

验证及中间修正：

- 新共享类型接线过程首轮编译尚未完成；随后修复新组件测试中 await 位于 XCTest
  autoclosure 的编译错误。21 项初轮专项、252 项相关共享/Mac 回归通过。
- 临时生成证书与回环 HTTPS/WSS 初轮 5 项通过；测试 HTTPServer 起初进行了不必要
  的回环反向 DNS，改为固定本机服务名后复验通过。随后加入真实 WSS 重定向及
  HTTPS/WSS 权限拒绝，最终 TLS 7 项通过。密钥与证书只生成在临时目录并自动清理。
- 控制台实际 WK 6 项、Mac 生命周期 2 项、地址策略 5 项、TLS 7 项、传输 7 项、
  准备 5 项，共 32 项纳入最终完整共享 3101 项 XCTest（172 条既有环境跳过）及
  12 项 Swift Testing；全部通过，XCTest 101.543 秒。
- 移动首次使用了新的派生目录，未运行测试即停止；改回原 m0-m8 增量目录。新模型
  测试缺少 try/requestFormat 的编译错误修正后，后续测试包构建均成功。两端各
  101 项 VM 模型通过（1.316/1.280 秒）；首轮各六项 UI 通过（244.125/287.273 秒）。
  截图发现连接后断开仍用首次失败提示，改为“已断开”，两端单项复验通过
  （48.532/53.102 秒）。再补权限/身份恢复后，最终两项 UI 各通过
  （109.470/127.523 秒）。六项新控制台 UI 与原开机 UI 分轮通过，未连接 NAS。
- Mac 外壳绘制首次在 WK 尚未完成时沿用同步 isLoading 断言，三处失败；保留原
  断言并等待真实完成后，一项双语/浅深外壳检查通过（1.454 秒）。移除同一工具栏
  重复“远程控制台”标签。首轮 26 张、最终恢复 8 张、Mac 两轮 8 张共 42 张截图
  已逐张检查；测试图仅含自造内容。
- 本地化/硬编码扫描 6981/2188/3402 通过；180 个请求 fixture / 1 个写结果示例、
  29 组 fixture / 48 个私有文档引用通过；CI 分组覆盖三项测试通过。工程通过
  xcodegen 更新，无手改生成文件。最终 Mac Release 构建通过，lipo 检查主 App 与
  File Provider 扩展均为 x86_64/arm64；未安装、启动或发布正式 App。

主要可复现命令（两设备及结果路径来自日志；每组禁止并行 simulator；工作区绝对前缀以 `$PWD` 脱敏）：

```sh
swift test --package-path apple --jobs 2 --filter 'VirtualMachineConsole'
swift test --package-path apple --jobs 2
xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodegen generate --spec apple/Apps/DsmMac/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:DsmMobileTests/MobileVirtualMachineConsoleTests -only-testing:DsmMobileTests/MobileVirtualMachineControlTests -only-testing:DsmMobileTests/MobileVirtualMachineCreationTests -only-testing:DsmMobileTests/MobileVirtualMachineImageTests -only-testing:DsmMobileTests/MobileVirtualMachineNetworkTests -only-testing:DsmMobileTests/MobileVirtualMachineInventoryModelTests -only-testing:DsmMobileTests/MobileVirtualMachinePresentationTests -only-testing:DsmMobileUITests/MobileVirtualMachineConsoleUITests -only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test普通套件账号开机并查看逐项结果 -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -resultBundlePath build/m7d5-phone.xcresult
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:DsmMobileUITests/MobileVirtualMachineConsoleUITests/test中途断开不会自动重连 -only-testing:DsmMobileUITests/MobileVirtualMachineConsoleUITests/test权限拒绝与身份变化提供准确恢复提示 -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -resultBundlePath build/m7d5-pad-recovery.xcresult
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test控制台窗口双语主题保留非持久网页且不连接设备' bash tools/codex/run_macos_ui_checks.sh "$PWD/build/m7d5-mac-preview-final"
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 -m unittest discover -s tools/release -p test_apple_ci.py
python3 tools/codex/check_documentation.py
git diff --check
```

首轮同组 iPad 将 destination 改为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果为
`build/m7d5-pad.xcresult`；最终恢复同组 iPhone 使用 `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`，
结果为 `build/m7d5-phone-recovery.xcresult`。日志分别为 `build/m7d5-{phone,pad}.log`、
`build/m7d5-{phone,pad}-recovery.log`、`build/m7d5-shared-final.log`、
`build/m7d5-mac-ui-final.log` 和 `build/m7d5-mac-build-final.log`。

当前负责人独立集成及只读对抗复核已完成；真实套件资源、VNC 输入/画面、根反代、
两类真机的前后台/锁屏与辅助功能按主计划 M7d5 的具体 `PENDING_USER_VALIDATION`
执行。非根应用门户当前没有 Apple 配置入口，使用根反代/官方 VMM，不写成待真机。
M8 系统后台、分享扩展与 Files 尚未实现，本片不把它们视为完成或仅待真机。

已清理新增临时派生目录、诊断采样及原始截图导出目录；正式日志/xcresult 保留于忽略的 build，16 张精选合成截图位于 `build/m7d5-preview`。

## 2026-10-07 iPad 云端输入、导航与测试分组

旧 [Apple Build 37499218894](https://github.com/yuangy1995/dsm-native-client/actions/runs/37499218894)
针对 `04d692ab` 最终失败。共享/macOS 与 iPhone workspace 通过，其余失败按前片及
本片证据修正；iPad administration 的 134 UI 全部执行完毕，3 项失败，耗时
20669.735 秒，其中 ServiceSettings 46 项占 9646.153 秒；作业最终 cancelled，
GitHub 注释明确达到 6 小时执行上限。现每设备使用 workspace/modules/administration/
services 四组，服务设置不再重复落入 modules 或 administration。分组覆盖测试同时
检查所有模型/UI 类恰好一次及 exit 65 仍使作业失败，不添加重试或跳过。

实际原始失败证据：存储分析停在可见但未开启的模块开关；计划任务一次混合退格/
输入后名称只剩 `Sampl`，未得到 `Updated Task`；代理第二次保存仍停在确认页，
原通配元素查询命中外层 Other。对应修正使用已存在的功能开关/导航辅助方法、
分开发送退格和新文本并等待完整值、定位确认按钮并等待可点击后按下/抬起一次。
全部业务结果断言保留。投票启用后导航超时改用定向共享导航；另一条初始文件
加载长时间不结束仍未确定根因，本机复跑通过不能证明该云端现象已经根治。

本机原 5 失败场景在改动前分别于 iPhone/iPad 全部通过（449.315/540.175 秒）；
不是靠本片重跑把原云端失败变为通过。随后本片正常签名构建成功，iPhone 的
8 项相关实际 UI 全通过，737.518 秒；iPad 同组八项全通过，833.035 秒。
独立集成审查逐条检查修改范围、完整文字/最终代理状态与恢复断言、四组互补及
失败传播，未修改产品行为、认证或 API。两端各六张精选截图已逐张复核，覆盖中文
深色大字投票、投票/存储错误、任务确认与重启后脚本、代理关闭结果。大字投票及
任务长表单使用滚动内容，实际 UI 已操作滚动后提交；不把视口外内容描述成全部可见。

实际命令：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 \
  -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F'
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:DsmMobileUITests/MobileChatPollUITests \
  -only-testing:DsmMobileUITests/MobileNasStorageUITests/test空间分析加载可取消失败可重试 \
  -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test编辑未知重启后完整回读恢复 \
  -only-testing:DsmMobileUITests/MobileScheduledTasksUITests/test空目录新建完整表单与确认取消再保存 \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理 \
  -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' \
  -resultBundlePath build/m7d-ci-pad-phone-after.xcresult
python3 -m unittest tools.release.test_apple_ci
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

iPad 使用 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，对应结果改为
`build/m7d-ci-pad-pad-after.xcresult`。基线只选上面的两条原失败 Poll 方法和三个管理
方法，结果为 `build/m7d-ci-pad-{phone,pad}-before.xcresult`。3 项分组测试通过；
本片本地化检查 6981/2188/3402 双语资源、参数/引用及硬编码扫描通过，文档检查和
差异检查通过。最初误用 generic/无签名构建触发了不需要的双架构编译，主动中止，
随后改为上述正常签名目标构建；中止不记为构建通过。

旧云端结果已完成取证，原始下载、录像、诊断和一次性提帧工具已清理；六张脱敏
失败截图位于 `build/m7d-ci-pad-evidence`，十二张本机精选位于 `build/m7d-ci-pad-preview`。
正式本机构建/UI 日志与结果仍保留于
忽略的 build。新的完整云端四组结果尚未运行，不以本地通过或代码同步代替。

## 2026-10-07 macOS 工程生成与控制台测试退出等待

完整 Apple 运行 `37549707212` 的 `shared-macos` 作业 `112562018841` 失败于工程生成物检查；共享测试和发布签名回归此前已通过，打包步骤未执行。读取作业原日志确认差异仅为 PBXProject 的两个 target 顺序：本机默认 XcodeGen 为 2.45.4，CI 锁定 2.46.0。使用仓库锁定版本及既定 SHA-256 校验下载后重新生成 Mac/移动工程，两次生成哈希一致；不手改生成文件，不改变工具链版本。

M8a 本机完整共享回归第一次运行卡住。进程采样明确停在 `VirtualMachineConsoleTLSTests.test要求系统信任时不能使用自签名固定证书` 的 `ConsoleLoopbackServer.stop()` → `Process.waitUntilExit()`，对应测试服务进程已不存在。该次运行手动中断（exit 130），不是通过。测试服务器改为启动前安装退出回调、通过 AsyncStream 异步等待退出；成功和抛错均等待并清理自建证书，不修改连接实现、TLS 断言或跳过测试。中断留下的唯一合成证书目录已清理。

实际验证：

```sh
build/m8a-xcodegen/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMac/project.yml
build/m8a-xcodegen/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
swift test --package-path apple --jobs 2 --filter VirtualMachineConsole
swift test --package-path apple --jobs 2
```

- 控制台聚焦 32 项通过；包含真实回环 HTTPS/WSS、临时自签名证书、系统信任要求、证书变化、重定向、权限拒绝和文本帧。
- 完整共享/macOS 3101 项 XCTest（172 条既有跳过）与 12 项 Swift Testing 通过，未新增跳过。
- 生成物复验：锁定 XcodeGen 2.46.0，两端重复生成哈希保持一致；Mac 差异只有两个 target 排序。
- 证据：`build/m8a-ci-shared-job.log`、`build/m8a-console-regression.log`、`build/m8a-shared-final.log`。该修复尚未由下一次云端运行确认；同轮其余移动作业仍在进行，不把本机通过写成云端全绿。

## 2026-10-07 移动 M8a 文件后台传输

基于已完成 M7 的 main，文件下载与上传批次接入系统执行时间。iOS/iPadOS 26 使用用户主动发起的 BGContinuedProcessingTask、真实进度和系统取消，即时提交失败时降级；17–25 使用有限后台时间。保留原网络、同源重定向拦截、证书策略、受保护副本和恢复存储，不使用自动跟随重定向的 Background URLSession。进程被终止后不承诺继续或字节续传。

到期先取消网络并保存恢复阶段，后释放系统资格；旧执行回调不影响后来继续的任务。上传到期同时暂停未开始批次，避免结算后继续写；共享 FileUploadBatch.pause 只增加对未开始批次的暂停支持。系统进度在原结果校验成功后才完成。Info 增加当前 App 的 transfer.* 任务声明与 processing 模式，主 App 身份、最低版本、签名、文件保护和登录结构不变。独立集成及只读对抗复核与设备条件见[专项账本](../../development/APPLE_MOBILE_SYSTEM_TRANSFERS_ZH.md)。

实际命令（iPad 以 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 替换设备 ID；原始结果包名各自独立）：

```sh
build/m8a-xcodegen/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -only-testing:DsmMobileTests/MobileTransferBackgroundExecutionTests -only-testing:DsmMobileTests/MobileTransferStateTests -only-testing:DsmMobileTests/MobileTransferRecoveryTests -only-testing:DsmMobileTests/MobileDocumentTransferTests -only-testing:DsmMobileTests/MobileFileUploadQueueTests -only-testing:DsmMobileTests/MobileActivityPresentationTests -only-testing:DsmMobileUITests/MobileTransferBackgroundUITests -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test多选仅一个文件保持原格式且下载失败能从活动重试 -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -resultBundlePath build/m8a-phone.xcresult
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
python3 tools/localization/check_localization.py
python3 tools/release/test_apple_ci.py
python3 tools/codex/check_documentation.py
```

- 两端各 73 项聚焦单元全部通过；包括 7 项新系统执行管理、4 项新协调器、4 项新队列行为回归，未新增跳过。不是两端全部移动单元。
- 首轮 UI：iPhone 4 项中 2 项失败，iPad 4 项中 1 项失败。失败证据确认 iPhone 系统溢出菜单使用中文“更多”，新测试只查英文；两端中文最大文字表单的文件行在屏幕外，测试未滚动。修正测试读取实际菜单语言并滚动至目标，没有删断言或修改产品来适配测试。
- 针对失败项复测：iPhone 下载分享、中文大字 2 项通过（81.451 秒）；iPad 中文大字 1 项通过（47.296 秒）。首轮两端上传后台/重启结果，以及原下载失败恢复已通过；iPad 下载分享亦已通过。合计两端各四个不同 UI 场景全部取得通过证据。
- 六张最终截图逐张检查：两端浅色上传结果、系统分享、中文深色最大文字。长路径和按钮可换行、滚动后可触达；不宣称所有大字内容同时在一屏显示。测试以真实 UIApplication/BGTaskScheduler 接线切到桌面停留 13 秒后返回，网络为合成响应；不把该结果提升为真机持续调度、锁屏或真实 NAS 通过。
- 共享/macOS 3101 项 XCTest（172 条既有跳过）与 12 项 Swift Testing 通过；Mac Release 主 App 和 File Provider 构建成功，实际检查均含 x86_64/arm64。期间控制台测试服务器退出等待问题已单独修正并记录于前条。
- 本地化 6984 Apple / 2188 Android / 3402 Windows 检查通过；三项 CI 分组完整性测试与文档检查通过。源码无新增第三方依赖，不修改 Windows/Android，实现范围仅文件下载及上传批次。
- 证据：`build/m8a-{phone,pad}.xcresult`、`build/m8a-{phone,pad}-ui-final.xcresult`、`build/m8a-build-ui-fix.log`、`build/m8a-shared-final.log`、`build/m8a-macos.log`；最终六张 PNG 位于 `build/m8a-previews/`。导出录像和临时诊断已清理，正式测试源码与结果保留。

分享扩展、Files/外部编辑写回，以及照片、跨 NAS、Office 等其他独立执行器仍有源码工作；M8 及 M6–M8 总目标未完成。真机正式签名、持续任务授予/资源回收、系统取消、锁屏保护、实际服务器取消/重复保护和辅助功能列为具体 PENDING_USER_VALIDATION，不以这些缺口阻塞独立扩展开发。

## 2026-10-07 移动 M8b 系统分享与账号共享

基于 M8a 的 main，新增独立 DsmShare 扩展，接收系统文件/照片/视频分享，在扩展内选择已登录 NAS 与文件夹，明确上传后保存任务，关闭后由主 App 活动继续处理原记录。文件上传复用 MobileFileUploadQueue/FileUploadBatch；每条分享有独立目录与进程间所有权，不在扩展仍运行时重复接手。账号发布使用独立共享会话编号，去除 DID，不共享密码；退出、删除、取消、身份与证书变化有撤销保护，快照或任务身份损坏不覆盖、不误清理。必要权限、平台差异、独立集成与只读对抗复核见[系统集成账本](../../development/APPLE_MOBILE_SYSTEM_TRANSFERS_ZH.md)。

实际命令（第二次移动测试以 iPad ID `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 替换 iPhone ID，并使用独立结果路径）：

```sh
build/m8a-xcodegen/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMobile/project.yml
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -only-testing:DsmMobileTests/MobileShareTransferTests -only-testing:DsmMobileTests/MobileExtensionAccountTests -only-testing:DsmMobileTests/MobileSessionShellTests -only-testing:DsmMobileTests/MobileDocumentTransferTests -only-testing:DsmMobileTests/MobileFileUploadQueueTests -only-testing:DsmMobileTests/MobileTransferBackgroundExecutionTests -only-testing:DsmMobileUITests/MobileShareExtensionUITests -resultBundlePath build/m8b-final-phone.xcresult
swift test --package-path apple --jobs 2
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild build -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
python3 tools/localization/check_localization.py
python3 tools/release/test_apple_ci.py
python3 tools/codex/check_documentation.py
git diff --check
```

- 两端各 81 项聚焦单元通过：15 共享账号、15 分享任务、15 会话、17 文档、12 上传队列、7 后台资格；无新增跳过。覆盖发布延迟/失败/取消、退休会话清理、退出和删除、跨实例并发、撤销进行中请求、真实附件回调冻结、文件名/符号链接边界、重复提交、锁交接、未知结果只读恢复和损坏身份不误删。
- 两端各四项实际系统 UI 通过，分别为完成上传并回到主 App 清理、关闭后重启明确继续、丢回执后只读恢复、中文深色最大动态文字；iPhone 四项 140.513 秒、iPad 四项 143.943 秒。系统确实启动独立分享扩展并跨进程使用共享 Keychain/App Group；全部网络响应与文件内容为合成数据，不是对真实 NAS 的写测试。
- 首轮两端 57 项相关单元、后续两端 27 项新增单元已取得通过。初次系统 UI 因按按钮/英文名称查找系统 shareCell 失败；根据实际 AX 记录改为中英文 cell 查询。第二次因为 Any 代理的 enabled 值与实际工具栏按钮不同失败；录像确认根目录 Upload 灰色，改为按钮查询并保留禁用断言后通过。中间两处 Swift actor/错误变量遮蔽的编译问题已修正，不把首次失败记成通过。
- 共享/macOS 3101 项 XCTest（172 项既有跳过）及 12 项 Swift Testing 无失败；Mac Release 主 App/File Provider、移动 Release 主 App/Share 扩展构建通过，四个产物均以 lipo 确认包含 x86_64 和 arm64。移动 Release 不编译合成环境。未安装或启动 Mac 成品，没有发布安装包。
- 双语/硬编码扫描覆盖新增 ExtensionShared 与 ShareExtension 目录，Apple 7000、Android 2188、Windows 3402 项检查通过；云端分组覆盖三项测试、文档和差异检查通过。本轮没有变更 NAS 契约、Windows/Android 源码或最低系统版本。
- 已逐张复核两端共 18 张场景截图。活动页上的 NAS 后台任务读取错误来自合成服务未提供该独立接口，本机分享记录仍准确显示且能继续/清理；该截图不代表真实 NAS 的任务读取失败。大字同名选项与路径行随后作布局调整，补充验证单独记录。
- 本地证据：`build/m8b-final-{phone,pad}.xcresult`、`build/m8b-final-build.log`、`build/m8b-shared.log`、`build/m8b-macos.log`、`build/m8b-mobile-release.log`、`build/m8b-previews/`。正式签名、真实来源 App、锁屏文件保护、系统终止时序、真实 NAS 写入、VoiceOver 与外接键盘仍为账本列明的 `PENDING_USER_VALIDATION`。Files 的实现不由本片宣告完成。

布局收尾：返回按钮与完整路径合并，大字模式的同名处理改为原生内联选择。两端针对正常分享和中文大字的两项 UI 再次通过（iPhone 64.454 秒、iPad 71.118 秒，`build/m8b-layout-{phone,pad}.xcresult`）；随后发现跨进程 `isHittable` 可把视口外文件当成可点，补入实际滚动和屏幕坐标断言，两端中文用例再次通过（39.467/39.393 秒，`build/m8b-scroll-{phone,pad}.xcresult`）。最后 20 张场景 PNG 已逐张复核，长内容能滚动到文件名；没有放宽原业务断言。增量构建使用上文 build-for-testing 命令并增加 `-disableAutomaticPackageResolution -skipPackageUpdates -jobs 2`，复测使用相同 test-without-building 命令，仅按上述两个或单个 UI 方法选择，不重复未改动的单元。临时附件导出、录像与提帧脚本已清理；两台模拟器合成分享标记和任务目录亦已清理，保留正式结果包及选取的证据图。


## 2026-10-07 移动 M8d 照片、跨 NAS 与 Office 后台

基线 `dc2f2fb0`，同一工作区另有 M8c Files 共享提取，未据此宣告默认只读系统流程通过。
本片保持 NAS API、认证、文件保护及恢复格式，复用 M8a 的系统执行桥接；只为明确
开始的照片上传/导出、跨 NAS 复制与独立确认的删源、Office 下载/主动覆盖授予时间。
中断先取消实际网络，等待原流程保存未知结果及清理，再归还系统资格；无自动重传。
共享新增上传生命周期/取消与前台暂停入口，Mac 调用行为保持。对齐账本、独立集成与
只读对抗复核、精确命令和五项真机待办见[后台执行器账本](../../development/APPLE_MOBILE_BACKGROUND_EXECUTORS_ZH.md)。

本机最终结果：

- iPhone 135 项八类模型/传输聚焦测试：0 失败，4.528 秒。
- 五项新增实际前后台 UI，iPhone 266.809 秒、iPad 293.593 秒，均 0 失败；覆盖照片上传、
  中文深色最大字号状态、批量导出到系统文件面板、跨 NAS 复制后独立删源和 Office 回传。
  两端 12 张最终截图逐张复核；没有把模拟器后台运行当作真机持续资格已获准。
- 完整共享 `swift test --package-path apple --parallel` 成功结束 3103 项 XCTest 和 12 项
  Swift Testing；最后共享生命周期修正后补跑 260 项 Mac 照片模型/恢复及 2 项适配测试，0 失败。
- Mac Release 主程序/File Provider 及移动 Release 主 App/Share/Files 均构建成功，
  实际二进制检查全部含 x86_64/arm64；移动三组件不含本片合成服务及 Files/Share 调试入口符号。
- 本地化 7049 Apple 键、双语/硬编码扫描、文档链接与差异检查通过。

中间失败如实保留：第一轮合成照片服务把提交后取消当成提交前抛错，2 个未知结果
断言失败；按现有 Repository 契约改回 pendingReview 后通过，未降低断言。首轮实际
前后台 UI 发现照片页在 background 时调用整模块停用，造成三项照片 UI 失败；
改为暂停前台读取/预览并保留已开始传输，两端最终全过。独立复核还发现新 Task
调度前换同 UUID 账号的间隙，以及模型立即退出时未归还资格的收尾问题，已补冻结
身份、持有任务至结束及零写/释放回归。

同轮原云端失败的 DDNS/硬盘状态本机回归另计：两端各 3 UI 通过，不计作新增后台场景；
DDNS 明确拖动后验证真实值，硬盘原用例当时未修改且未复现。随后云端其余 UI 修复和
M8c 默认只读元数据问题另按独立证据继续，不以本片结果冒充完整云端通过。

## 2026-10-07 Apple 云端按钮与开关交互回归

核实运行 `37549707212` 的提交为 `539de49f3b1c533e82179dafb8e20995b711baed`。
两类设备的 services 已成功；iPad administration 的 DDNS、iPhone administration 的
硬盘停止状态，以及 iPhone modules 的 RSS 进入订阅和 VMM 旋转后取消确认存在失败。
逐项读取对应 XCTest 事件和合成场景录像，DDNS 点击后开关仍为原值；RSS 仍停留列表，
VMM 仍显示确认页，硬盘确认页已关闭但最终状态仍为检测中。本机原用例均未复现，
这些证据不能证明产品逻辑有故障，也不能把硬盘问题推定为轮询竞态。

测试修正仅限交互：DDNS 明确拖动一次并先断言真实值再等待原结果消失；RSS 检查目标
可点击并按下 0.15 秒；硬盘两次确认、VMM 该旋转场景的取消按钮各按下 0.15 秒。
没有自动重试危险操作、修改业务实现或放宽最终状态断言。独立复核确认仍检查连接
测试失效、实际硬盘状态、原订阅恢复及确认页消失，失败会直接中止。

修正后 DDNS 两项已在两端通过，见上一节最终结果；随后三个用例分别用下列命令
执行，iPad 使用同一编译产物的 `test-without-building -xctestrun
apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun`，
设备 ID 替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果路径独立。

```sh
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m8d-ci-fixed-phone.xcresult '-only-testing:DsmMobileUITests/MobileDownloadRSSUITests/test更新中断后重启通过读取原订阅恢复' '-only-testing:DsmMobileUITests/MobileNasStorageUITests/test硬盘快速检测和停止均可确认并显示实际状态' '-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test旋转后详情和关机确认保持可用' CODE_SIGNING_ALLOWED=NO
```

iPhone 3 项 165.439 秒、iPad 3 项 175.186 秒，均 0 失败。原云端运行其余作业仍在进行，
本轮修正尚待下一次云端确认；不将两端本机通过记作完整云端门禁通过。

## 2026-10-07 云端模块启用与系统集成结果分段

主功能基线 `2d841fdc` 已同步 main。旧运行 `37549707212` 被后续正常推送替换后，
从已取消作业中继续取回失败事件与合成截图：iPad 的损坏聊天音频恢复和中文深色
大字号消息删除两个场景仍停留在设置页，聊天开关未开启；iPhone 的取消临时相册
分享场景在模块准备阶段超时。后者事件明确记录单次辅助功能快照耗时 10.579 秒，
超过原十秒等待，不将其解释成照片不可用或产品权限错误。

测试统一使用已有模块启用方法进行一次明确拖动并检查实际值；同类聊天、下载和
管理测试的重复准备步骤一并复用该方法。模块可操作等待改为三十秒，保留可点击、
可用和开启值断言；中文删除场景导航复用已有导航方法。没有自动重试或改变产品
业务逻辑、操作次数和业务结果断言。取消作业的部分通过结果不计为完整门禁通过。

三个实际失败场景修正后两端均通过：损坏音频恢复 iPhone 30.925 秒、iPad 37.933 秒；
中文删除场景 109.335/106.070 秒；取消临时分享 41.233/43.245 秒。结果包为
`build/m8e-navigation-{phone,pad}.xcresult`，当前环境仍为 Xcode/iOS 模拟器 26.5。

其他十五个修改过准备步骤的测试类各选一个完整业务场景，在两端分别通过，iPhone
881.725 秒、iPad 1009.891 秒，均 0 失败、0 跳过。覆盖聊天发送/建群/阅读/定时/
联系人/转发、下载订阅/编辑/创建/设置、账号管理、套件设置/控制/安装和系统操作。
合计每端十八个不同界面场景通过；这不是整套 UI 全量运行。独立结果为
`build/m8e-setup-{phone,pad}.xcresult`，iPhone 重新编译测试，iPad 复用该产物。

实际命令如下；iPad 使用 `test-without-building -xctestrun
apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun`，
设备替换为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 并使用独立结果路径。

```sh
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m8e-navigation-phone.xcresult '-only-testing:DsmMobileUITests/MobileChatAudioUITests/test播放损坏音频显示恢复提示并允许重新加载' '-only-testing:DsmMobileUITests/MobileChatDeletionUITests/test中文深色大字号删除选择加载空内容和错误' '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test取消临时分享设置会清理相册并保留原照片' -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
python3 -m unittest tools.release.test_apple_ci -v
python3 -m unittest discover -s tools/release -p 'test_*.py'
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

十五项代表场景的实际 iPhone 命令如下，iPad 按上文替换测试入口、设备与结果路径，
使用同一组方法选择：

```sh
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -destination "platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F" -parallel-testing-enabled NO -resultBundlePath build/m8e-setup-phone.xcresult "-only-testing:DsmMobileUITests/MobileChatSendUITests/test普通消息发送成功后记录可移除且不会删除聊天消息" "-only-testing:DsmMobileUITests/MobileChatGroupCreationUITests/test新建群聊选择成员后进入对应会话" "-only-testing:DsmMobileUITests/MobileChatRealtimeUITests/test阅读历史保留未读跳到最新才清除" "-only-testing:DsmMobileUITests/MobileChatTimedActionUITests/test定时消息创建列表与取消确认" "-only-testing:DsmMobileUITests/MobileChatUITests/test新联系人打开单聊并进入会话" "-only-testing:DsmMobileUITests/MobileChatForwardUITests/test多条消息搜索接收人并转发到已有会话和新联系人" "-only-testing:DsmMobileUITests/MobileDownloadRSSUITests/test订阅条目通过统一表单创建下载并更新订阅" "-only-testing:DsmMobileUITests/MobileDownloadEditUITests/test单任务选择文件夹保存后详情显示新位置" "-only-testing:DsmMobileUITests/MobileDownloadCreationUITests/test链接草稿取消不添加且目录可恢复默认再选择提交" "-only-testing:DsmMobileUITests/MobileDownloadSettingsUITests/test选择默认文件夹与常规计划分步保存" "-only-testing:DsmMobileUITests/MobileDirectoryUITests/test账号编辑群组选择保存取消及删除确认" "-only-testing:DsmMobileUITests/MobilePackageCenterUITests/test普通设置单位置隐藏选择器且取消保存结果正确" "-only-testing:DsmMobileUITests/MobilePackageControlUITests/test启动取消零写后确认再停止并查看结果" "-only-testing:DsmMobileUITests/MobilePackageInstallationUITests/test安装计划可取消再确认并回读完成" "-only-testing:DsmMobileUITests/MobileSystemActionsUITests/test服务及当前网页连接各自确认取消和断开"
```

现有九个 Apple 矩阵作业保持不变；modules 组先运行 Files、分享扩展和普通后台
传输三个系统测试类，生成独立 `-system.xcresult`，之后运行原组的其他全部测试。
首段失败仍执行第二段，两段任一失败均返回失败；没有重试、跳过或缩减覆盖。
先封存系统结果可避免长组取消时只留下无法解析的未完成结果包，上传仍使用原结果
路径通配符。五项实际 shell 参数回归确认两端各测试类恰好执行一次、系统顺序、
结果包分离、前后段失败传播和未知分组拒绝；完整发布脚本 39 项也全部通过。

独立集成复核逐项检查开关调用目标、幂等行为、导航、两段退出码及全部测试类分配；
仅本片测试和工作流有变化，不借此重跑或替代前片的 1846 项移动单元、共享回归与
Release 构建结果。Files 默认只读目录失败仍单独追踪，未改为跳过或待真机占位。

云端 `37572581607` 的 `shared-macos` 已独立成功，实际日志记录 3103 项 XCTest
（172 项既有跳过）、12 项 Swift Testing、当时的 37 项发布脚本回归通过；Mac
临时测试包生成及权限/Sparkle 实际加载校验通过。这一结论只覆盖 `2d841fdc` 对应
共享/Mac 作业，不代表仍在运行的八个移动分组或后续测试修正全部通过。

补充复核被取消的 `37572581607`：iPhone services 在取消前完成 4 项并有 1 项失败，
为 `MobileServiceSettingsUITests.test五态搜索与读取失败恢复`；其余已运行的
iPad modules、iPhone administration、iPad services 没有已结束的失败项，仍不计为
完整通过。失败位于最后的 `nas-services-unsupported` 启动，模块开关最终值仍为 0；
截图中开关完整可见。事件显示控件框为 `(309, 545.7, 63, 28)`，一次触控从
`(324.8, 559.7)` 到 `(356.2, 559.7)`，共 0.33 秒；系统已回报事件完成，但开启值
断言超时。这与此前页面快照十秒超时不同，不能仅靠延长等待解释为已修复。

在当前 `a1b7753d` 测试代码上，用 `xcodebuild test-without-building -xctestrun
apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun
-destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F'
-parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test五态搜索与读取失败恢复'
-resultBundlePath build/m8e-service-five-states-phone.xcresult` 运行完整五态场景；iPad
替换设备为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289` 并使用独立结果路径。iPhone
150.104 秒、iPad 164.588 秒均通过，未改产品或测试源码，也未据此认定云端已解决。
下一证据为正在执行的 `37575438355` 对应 services 作业；暂不凭推测调整手势、
增加重试或绕过模块启用步骤。

`37575438355` / `a1b7753d` 的共享/Mac 作业 `112643551860` 已完成并通过。
实际日志确认 `swift test --package-path apple` 执行 3103 项 XCTest（172 项既有
跳过、0 失败）及 12 项 Swift Testing；`python3 -m unittest discover -s tools/release
-p 'test_*.py'` 的 39 项回归全部通过。Mac 临时测试包构建、权限和 Sparkle 实际
加载检查均成功。八个移动作业另行核对，此记录不代表完整移动云端已通过。

### 同轮 iPhone 服务设置完整结果与触控分发差异

`37575438355` 的 [iPhone services 作业](https://github.com/yuangy1995/dsm-native-client/actions/runs/37575438355/job/112643552111)
完成 46 项 UI：45 项通过、1 项失败，总计 6120.883 秒。失败仍为五态用例，
本轮在第二次启动的 `nas-services-empty` 开启 NAS 模块时失败，83.126 秒结束；
不是旧运行的最后一个 unsupported 场景，也不是页面加载等待超时。
结果包确认云端为 macOS 26.6.2、Xcode 26.6（17F113）、arm64 iPhone 17 Pro，
实际模拟器仍为 iOS 26.5（23F77），不能把 Xcode 版本写成模拟器系统版本。

失败截图和完整层级确认 NAS 开关可见、可操作且保持关闭，没有弹窗遮挡或跳离设置页。
同一用例中成功与失败的合成触控记录完全一致：起点 `(324.75, 559.67)`、终点
`(356.25, 559.67)`，开始按住 0.1 秒、移动 0.126 秒、结束按住 0.1 秒。
系统日志进一步显示：成功操作在请求后 22 毫秒首次进入 App，触控分发跨
369 毫秒、共 10 次；失败操作在请求后 312 毫秒才首次进入 App，后续分发仅跨
71 毫秒、共 3 次。两者均收到系统事件完成回调。录像抽帧没有显示开关中途已开启，
因此不能将失败解释为导航切换或过期的控件查询。

据此仅把共用模块开启手势的起始按住时间从 0.1 秒改为 0.5 秒，为已观察到的
触控分发延迟留出时间；保留坐标、移动速度、结束按住时间、单次操作、可操作性与
开启值断言，以及原五种场景和业务检查。没有加入失败重试、预先开启模块、放宽权限
或更改产品逻辑。该修改针对短合成手势在云端的时序差异，仍需本机和云端复验，
不能由日志相关性宣称已确定系统根因或修复通过。

修改前的旧编译产物在本机 iPhone 连续五轮完整五态场景全部通过，合计 712.755 秒，
说明本机尚未复现云端偶发失败。随后用正常临时签名重新构建新手势测试，iPhone 与
iPad 各执行五轮同一完整场景，遇到首次失败即停止；两端均五轮全过、0 失败、0 跳过，
分别 708.238/757.892 秒。这里是一个场景的五次执行，不是五个不同测试。
新结果包为 `build/m8f-services-{phone,pad}.xcresult`；旧对照结果为
`build/m8e-services-repeat-phone.xcresult`，不得把旧版本通过计为新修改通过。

实际新构建和 iPhone 命令如下；iPad 复用同一新编译产物，设备替换为
`A31ABDE2-186F-43DD-8D40-5EB9511A9289`，结果路径替换为
`build/m8f-services-pad.xcresult`。旧对照在新构建前使用相同测试选择与重复参数，
结果路径为 `build/m8e-services-repeat-phone.xcresult`。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test五态搜索与读取失败恢复' -test-iterations 5 -run-tests-until-failure -resultBundlePath build/m8f-services-phone.xcresult
```

其他五个模块各选一个完整业务流程，两端全部通过：中文深色最大字号聊天删除、
容器启动及结果、下载默认目录与计划保存、虚拟机开机及逐项结果、取消照片临时
分享并保留原件。iPhone 五项 258.195 秒、iPad 五项 257.417 秒，均 0 失败、0 跳过；
结果包为 `build/m8f-modules-{phone,pad}.xcresult`。因此本片每端覆盖六个不同 UI
场景，其中服务五态场景各执行五次；不将重复次数算作不同场景数。

```sh
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileChatDeletionUITests/test中文深色大字号删除选择加载空内容和错误' '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test取消临时分享设置会清理相册并保留原照片' '-only-testing:DsmMobileUITests/MobileDownloadSettingsUITests/test选择默认文件夹与常规计划分步保存' '-only-testing:DsmMobileUITests/MobileContainerControlUITests/test普通套件账号可以启动并查看结果' '-only-testing:DsmMobileUITests/MobileVirtualMachineControlUITests/test普通套件账号开机并查看逐项结果' -resultBundlePath build/m8f-modules-phone.xcresult
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

iPad 同样替换设备和结果路径。双语资源、引用、参数与硬编码检查通过，文档和
差异检查通过。当前负责人另行复核共用方法差异及六种模块调用：仅起始按住时间
变化，仍检查可操作、启用和最终开启值，保留失败截图与层级；没有重试、预开模块
或减少业务断言，没有修改产品、权限及云端覆盖。本片不涉及共享生产代码，不重复
此前已完成的全量单元及 Mac 构建，也不以这些聚焦结果替代完整云端。

本机通过只确认该调整没有破坏上述流程；因为旧版本本机也通过，不能据此宣称已经
消除云端故障。现有云端其余七个移动作业仍在运行或排队，待收齐后统一处理再推送，
避免新推送取消本轮。Files 默认只读目录问题保持原失败记录及权限边界，未在本片解决。

## 2026-10-07 云端工作区结果与启动停顿诊断

继续核对同一 `37575438355` / `a1b7753d`，没有取消或重新启动整轮：

- [iPhone 工作区](https://github.com/yuangy1995/dsm-native-client/actions/runs/37575438355/job/112643552033)
  166 项 UI 全部通过，0 失败，9456.907 秒。
- [iPad 工作区](https://github.com/yuangy1995/dsm-native-client/actions/runs/37575438355/job/112643552105)
  166 项 UI 中 165 通过、1 失败，0 跳过，9515.568 秒。结果包确认 arm64
  iPad Air 11-inch（M4）、iOS 26.5（23F77），构建宿主 macOS 26.6.2。
- [iPad 管理组](https://github.com/yuangy1995/dsm-native-client/actions/runs/37575438355/job/112643552149)
  88 项 UI 全部通过，0 失败，10511.686 秒。其余四个移动作业仍在执行，完整门禁尚未通过。

iPad 唯一失败为 `MobileWorkspaceUITests.test批量复制文件和文件夹逐项成功且源内容保留`，
133.368 秒结束。失败在 `beginCopyMoveBatch` 的初始目录等待，尚未点击目录、选择
对象或提交复制。与旧运行的批删启动失败分别记录，不能归为复制操作丢失来源。

该次启动在 5.27 秒开始等待界面空闲，60 秒后仍未收到回调。原始 App 诊断确认
06:12:16、06:12:46 两次主线程 30 秒无响应；06:12:47 才恢复处理辅助功能请求，
06:12:49 发回空闲信号。录屏按精确时间提取 0.5、30、70、105、131 秒共五帧并逐张
检查：中段一直为文件加载页，131 秒才进入读取状态；随后失败附件中的层级已有目录。
这些证据说明启动阶段确实长期无响应，不能仅因最后层级含目录而放宽存在断言。
现有诊断仍没有停顿期间的调用栈，尚不能确定产品或模拟器根因。

原用例未修改，在本机 iPad 用以下命令通过，21.990 秒、0 失败。它未复现云端停顿，
不据此声明云端已修复；iPhone 同一用例已包含于本轮完整工作区通过结果。

```sh
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test批量复制文件和文件夹逐项成功且源内容保留' -resultBundlePath build/m8g-copy-baseline-pad.xcresult
```

为下一次实际停顿取得调用栈，增加正式 CI 诊断脚本
`tools/release/capture_apple_ui_hangs.py`：原样转发 Xcode 输出，只在出现界面空闲
超时通知后异步采样三秒；通过指定模拟器返回的 App 路径和显式合成环境参数限定
当前进程，同一进程只尝试一次。不按通用进程名采样其他模拟器、真实连接或系统进程；
获取路径或采样被拒绝时只报告未取得诊断，不重试或扩大权限。采样不阻塞日志转发，
结束前等待采样完成；结果随原作业上传。原两段测试、所有选择、断言和失败退出保留。

六项诊断测试及五项现有 CI 实际 shell 参数回归通过；完整发布脚本 45 项通过，
12.337 秒。额外在本机显式合成 App 上实际执行 `HangSampler.capture()`，生成包含
主线程及源码符号的三秒调用栈；这是正常进程的诊断工具验证，不是复现或修复了停顿。
随后终止本次启动的合成 App，并清理临时采样。独立复核确认数据范围仅限测试 App、
未修改生产音频/文件实现，未增加 UI 重试、跳过或超时宽限。

```sh
python3 -m unittest tools.release.test_capture_apple_ui_hangs tools.release.test_apple_ci -v
python3 -m unittest discover -s tools/release -p 'test_*.py'
python3 tools/codex/check_documentation.py
git diff --check
```

本次修正及诊断尚未推送，待收齐当前云端其余作业后统一处理。Files 默认只读目录
仍等待 modules 组的完整系统结果；不将启动诊断能力、本机通过或其他分组通过视为
这两个未解决问题的验收完成。

## 2026-10-07 运行中云端系统段与新增界面失败

通过 GitHub 作业日志接口读取同一 `37575438355` 的已输出内容；作业还在执行，
但先行系统段已明确结束并报告失败。运行中日志是截至各自末行的快照，未输出的
后续测试不算通过，也不能将 HTTP 暂无日志误判成作业已停止。

| 已结束测试段 | iPhone | iPad |
| --- | --- | --- |
| Files 系统集成 3 项 | 1 通过、2 失败；284.031 秒 | 0 通过、3 失败；178.002 秒 |
| 分享扩展 4 项 | 4 通过；197.968 秒 | 4 通过；193.968 秒 |
| 普通文件前后台 UI 3 项 | 3 通过；133.004 秒 | 3 通过；139.058 秒 |
| 全部移动单元 1846 项 | 0 失败、4 项既有条件跳过；77.119 秒 | 0 失败、4 项既有条件跳过；79.996 秒 |

Files 两端默认只读用例分别于 90.884/75.382 秒失败，系统“文件”的层级显示空目录。
这补充了另一云端环境的实际失败证据；尚无对应云端系统日志，不能直接把本机
`cannotSetMetadata` 根因套用到云端。iPhone 可编辑用例于 113.742 秒失败：系统
位置已启用，等目录 20 秒未满足断言，随后层级中已出现 `Shared`，尚未下载或编辑。
iPad 中文位置管理与可编辑用例分别在 62.795/39.826 秒失败，均是添加位置后未出现
成功提示，页面已显示位置更新失败；这是独立的注册问题。详情与权限边界同步到
[Files 账本](../../development/APPLE_MOBILE_FILES_PROVIDER_ZH.md#云端系统阶段结果2026-10-07)。

运行中的 iPhone modules 另已发现
`MobileChatManagementUITests.test置顶公告查看附件并取消公告` 失败（110.983 秒）：
完成附件预览并返回，长按原公告、点取消后，原公告行没有在 8 秒内消失。
iPhone administration 另已发现
`MobileDDNSUITests.test新建连接测试与保存分离且修改输入清除旧测试结果` 失败
（100.582 秒）：开关关闭值断言已通过，但旧连接测试结果未在随后 5 秒内消失。
这两项不能归因于共用模块开启动作；需结合完整结果包的失败录屏和层级核对，
当前未改业务代码、扩大等待或放宽原业务断言。

本机使用现有临时签名产物（含前述共用模块开启按住时间调整）运行两项原业务用例：
公告 iPhone/iPad 分别 45.767/53.579 秒通过，DDNS 分别 68.427/74.325 秒通过，
四次均 0 失败、0 跳过。仅证明本机这些路径仍可用，不代表复现并修复了云端故障。

```sh
gh api repos/yuangy1995/dsm-native-client/actions/jobs/112643552160/logs
gh api repos/yuangy1995/dsm-native-client/actions/jobs/112643552237/logs
gh api repos/yuangy1995/dsm-native-client/actions/jobs/112643552164/logs
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶公告查看附件并取消公告' -resultBundlePath build/m8h-chat-announcement-baseline-phone.xcresult
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileDDNSUITests/test新建连接测试与保存分离且修改输入清除旧测试结果' -resultBundlePath build/m8h-ddns-baseline-phone.xcresult
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶公告查看附件并取消公告' '-only-testing:DsmMobileUITests/MobileDDNSUITests/test新建连接测试与保存分离且修改输入清除旧测试结果' -resultBundlePath build/m8h-cloud-cases-baseline-pad.xcresult
python3 tools/codex/check_documentation.py
git diff --check
```

当前仅新增证据与账本修正。未操作真实 NAS，未修改 Mac、Windows、Android 或
系统权限；保留只读失败用例，不把单元通过替代系统失败，不取消当前四个运行中的作业。


## 2026-10-07 macOS 文件上传合并传输中心

用户明确授权按此前评审方案修改上传重复详情。移除上传后自动弹窗及两个独立
“上传详情”入口；文件页保留上传确认、短提示与“查看传输”。传输中心以可展开批次
显示文件、目录、跳过原因与错误，不再重复显示关联的逐文件任务。暂停、继续、取消
与重试放在批次级。进行中显示百分比和实际字节，跳过项不计入待传字节；结束后
隐藏进度条，分别显示上传、目录、跳过、失败、取消与中断数量。

“清除已结束”按当前 NAS 范围清理，“移除记录”同步清除批次及关联任务；两者只清
记录，不删除 NAS 内容。运行、暂停或未知结果批次不可批量清除。上传中断后自动
进行一次只读恢复，普通刷新可再次读取；重入标记避免回调循环，结果不明不重传。
默认界面去除要求用户核对结果的按钮和常驻开发提示，保留暂停后重新发送未完成
文件的实际限制。上传确认和同名替换风险确认仍保留。

修改集中于 Mac 的 `FileUploadViews.swift`、`WorkspaceModel.swift`、`WorkspaceView.swift`、
两份 Mac 测试、README 及 Apple 双语资源。共享 `FileUploadBatch` 状态机、契约、
持久化结构、其他平台实现及签名配置未改变。旧存储没有跳过状态，因此当前会话
批次保留跳过详情，历史占位不再伪装为成功或取消；重启仍沿用逐文件历史，旧版本
已存为取消的历史不反推为跳过。目录与跳过明细的跨重启保存不在本片范围。

验证结果：

- 13 项上传 XCTest 全部通过（8 项既有、5 项新增），覆盖目录、同名冲突、
  最大并发、未知结果不重发、暂停恢复，以及跳过进度、批次与历史同步清理、活动
  批次不能被清除、自动只读恢复次数及防重入。
- 6 项本地化 Swift Testing 通过；五端双语、参数与硬编码扫描通过，Apple 7074、
  Android 2188、Windows 3402 项。文档检查与 `git diff --check` 通过。
- 两项 Mac 合成界面用例通过，覆盖中英、浅深色、大字号、空内容、暂停、失败、
  完成及清除，断言没有独立弹窗、辅助功能可以展开并读取文件名、清除只影响记录。
  新批次用例的稳定帧复验 10.859 秒通过，开启原生窗口截图后再次 15.226 秒通过，
  生成 20 张原生窗口截图；已复核覆盖四种语言/主题组合的代表画面，明细完整可见。
  一次初始测试误用只读环境属性、旧视图引用及展开坐标，已修正测试宿主与原生
  辅助功能操作；最终断言保留。初始缓存截图的展开动画中间帧未算最终视觉证据。
- Release arm64 独立临时签名包已生成，主 App 深度签名校验、实际 Sparkle 加载、
  arm64 架构和 DMG 完整性验证全部通过。输出为 `build/mac-upload-center-package/` 下的
  `LanStash Test.app` 与 `LanStash-1.0.15-arm64.dmg`；沿用开发版本 1.0.15（25），
  含当前未提交上传改动，不代表正式发布。本机临签流程移除 Finder 挂载扩展，未安装
  或启动成品，也未覆盖旧测试包。首轮在 GitHub 下载 Sparkle 时遇到 HTTP/2
  网络错误，未进入编译；HTTP/1.1 重试取得源码后二进制下载仍停滞，已结束该次构建，
  复用本机既有 Xcode 缓存。两份缓存源码均为锁定的 Sparkle 2.9.6 / `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`，
  二进制缓存校验记录也与包声明一致。只恢复忽略目录中的缓存，不修改依赖、工具链、
  仓库或系统 Git 配置。

```sh
swift test --package-path apple --jobs 4 --filter 'FileUploadWorkflowTests|DsmLocalizationTests'
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test上传批次统一传输中心双语主题与清理|WorkspacePresentationTests/test文件新表单双语浅深色大字与取消不提交' bash tools/codex/run_macos_ui_checks.sh "$PWD/build/mac-upload-center-ui"
LANSTASH_UI_TEST_ISOLATED=1 LANSTASH_UI_ARTIFACTS="$PWD/build/mac-upload-center-ui" LANSTASH_UI_NATIVE_SCREENSHOTS=1 swift test --package-path apple --skip-build --filter 'WorkspacePresentationTests/test上传批次统一传输中心双语主题与清理'
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$PWD/build/mac-upload-center-package" bash apple/Apps/DsmMac/package.sh
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

独立集成与只读对抗复核由当前负责人另轮完成：核对批次与逐项记录的互斥显示、
清理前终态门禁、延迟上传回调、暂停与取消后的恢复、只读检查重入、重启不可自动
重放及同名替换确认。未调用其他模型，未向真实 NAS 发送请求。工作区保留既有
移动端与 CI 改动，本片尚未提交或推送。

`PENDING_USER_VALIDATION`：使用独立测试包与专用可丢弃 NAS 目录，上传含同名文件、
子目录、空目录的批次；预期留在文件页、传输中心只有一条可展开批次，跳过不显示
失败或取消，结束无未满进度条。进行中暂停、继续、取消并尝试清除记录，预期保留
活跃/暂停/中断批次，取消保留已上传文件。另在专用环境中断连接后恢复，预期不会
自动重复覆盖；刷新可恢复结果。真实 NAS、完整 VoiceOver/键盘遍历及降低动态效果
尚未人工验收。仅回传版本、步骤、状态与脱敏截图，不回传主机、账号、路径、文件
正文或凭据；这些实际环境结果不由合成测试代替。

## 2026-10-07 macOS 照片提示、文件多选与多 NAS 容量修复

本片由用户反馈明确授权，保留上一片上传传输中心改动。照片预览底部此前直接读取
全局管理状态，后台自动生成预览或上传时也显示转圈；现将其与当前照片预览进度分开。
照片下载成功、失败和部分完成提示统一在 3 秒后消失，再次操作取消旧计时并重新
计时。错误提示消失不代表下载成功，也不改已有文件覆盖保护或下载权限。

文件宫格以当前窗口实际鼠标事件读取 Command／Shift，支持切换单项、连续范围和
空白处拖动框选；仅系统标记的普通双击打开项目。事件仍交给系统拖放、菜单与滚动，
离开视图移除监听。选中项增加清晰边框、勾选及文件名高亮，辅助功能动作区分选择与
取消选择。列表保留原生多选模型，使用更明显的主题选中色。完整工作区回归复现出
侧栏主题设置越过所属区域覆盖文件表格；现限制为与各背景实际重叠的滚动区域，
同时检查失焦后高亮保留，下载管理与虚拟机表格既有配色不变。

多 NAS 容量问题的可复现链路是：切走工作区取消容量读取，共享目录已经缓存，返回
时跳过原始加载，因而没有补读容量。重新进入时补齐未完成的容量读取；取消刷新不再
清空该 NAS 已有结果。新增测试经过真实 DsmFileRepository 与两份合成传输，检查两台
返回不同容量、请求各自使用所属目标与会话、旧值保留以及关闭文件模块不发容量请求。
没有修改网络会话或凭据存储，也没有访问用户真实 NAS。

当前验证：

- 252 项照片模型、13 项上传、20 项模块权限、2 项容量生命周期、29 项 Mac 外观
  测试通过；6 项本地化 Swift Testing 通过。新增计时用例覆盖成功、失败和旧计时
  不得提前清除新提示。
- 宫格输入检查在浅深主题通过实际 NSEvent 分发验证 Command、Shift、8 段框选及
  双击导航；列表检查经原生 NSTableView 选择接口验证 SwiftUI 绑定、实际行背景和
  失焦选择，不声称合成宿主完成物理鼠标验收。完整工作区、列表复制快捷键、下载/
  虚拟机配色回归通过，修正后的外观与界面一轮为 33 项、零失败。
- 照片预览检查覆盖中英与浅深主题，后台处理仍进行时无错误转圈、下载成功提示
  出现后消失，预览保持打开；生成并检查合成窗口画面。失败提示由模型计时测试覆盖。
- iPhone 模拟器增量构建和 24 项照片导出、22 项 Files Provider 测试通过，共 46 项，
  使用独立的 `mac-three-fixes-mobile-regression.xcresult`。后者同时覆盖此前移动端诊断
  日志变动；这些移动端诊断不属于本次 Mac 发布变更。
- 双语资源、变量及硬编码扫描通过：Apple 7074、Android 2188、Windows 3402。
  文档检查与差异空白检查通过。初版整窗检查发现高亮被侧栏覆盖，未把只读属性或
  局部界面通过当作最终视觉证据；调整作用范围后已复验实际背景和原生窗口截图。

```sh
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/(test文件列表原生多选使用清晰高亮且失焦仍保留选择|test完整工作区文件多选不被侧栏高亮覆盖|test原生文件列表焦点保留复制快捷键|test下载与虚拟机选中行使用低饱和主题色并保留原生选择)|MacAppearanceTests' LANSTASH_UI_NATIVE_SCREENSHOTS=1 bash tools/codex/run_macos_ui_checks.sh "$PWD/build/mac-three-fixes-ui"
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 4 -parallel-testing-enabled NO '-only-testing:DsmMobileTests/MobilePhotoExportTests' '-only-testing:DsmMobileTests/MobileFilesProviderTests' -resultBundlePath build/mac-three-fixes-mobile-regression.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

独立集成与只读对抗复核由当前负责人另轮执行：检查输入监听的窗口/区域与移除时机、
系统拖放不被消费、选择不触发写入、列表跨区观察、提示计时取消与弱引用，以及容量
请求所属 NAS、取消结果和权限门禁。未调用其他模型。未新增依赖、契约、权限或
存储格式；保留既有移动端与 CI 工作区差异。

`PENDING_USER_VALIDATION`：在实际 Mac 上分别使用 Command、Shift 和空白处拖动多选，
切换列表与浅深主题，移开焦点后仍应看清选择；双击只打开目标，拖入文件夹仍使用
已有确认与权限流程。打开照片并下载成功/失败，预期提示约 3 秒消失且可再次下载，
后台生成预览不占用当前照片底部。登录两台以上 NAS，读取期间切走再返回，预期
分别显示各自容量，刷新被取消保留旧值。实际 NAS、物理鼠标/触控板、VoiceOver 和
完整降低动态效果尚待用户验证；仅回传版本、步骤及脱敏错误，不回传私有文件或凭据。

发布前补充验证：用户随后明确授权发布 macOS 新版本并继续 M6–M8。完整共享与 Mac
回归为 3117 项 XCTest、177 项既有条件跳过、零失败；另有 12 项 Swift Testing 通过。
跳过项包括未开启的合成绘制、性能基准和需要真实 QuickConnect 环境的测试，不能
表述为这些场景已通过。发布工具 45 项测试通过；其中移动 CI 诊断测试仅存在于本机
工作区，本次 Mac 发布不携带尚未提交的移动诊断与工作流调整。

修改源码的独立 Release arm64 临时签名包已完成深度签名、实际 Sparkle 加载、架构及
DMG 完整性校验，位于 `build/mac-three-fixes-package/`，保留此前上传中心测试包。
该预发布验证包仍标记 1.0.15（25），未安装、未启动、不含 Finder 挂载扩展。
正式候选随后将主 App 与扩展同步递增为 1.0.16（26），使用锁定 XcodeGen 2.46.0
生成工程，生成差异只有版本与构建号；正式双架构签名、公证、公开发布及更新源结果
须以该版本的云端发布记录为准，不能由本机临签结果替代。

```sh
swift test --package-path apple --jobs 4
python3 -m unittest discover -s tools/release -p 'test_*.py'
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$PWD/build/mac-three-fixes-package" bash apple/Apps/DsmMac/package.sh
build/m8a-xcodegen/xcodegen/bin/xcodegen generate --spec apple/Apps/DsmMac/project.yml
```

## 2026-10-07 云端消失等待与 Files 系统日志复核

同一 `a1b7753d` 的 iPhone modules、iPhone administration 及 iPad services 已结束；
前两组分别在 169/88 项 UI 中各有 1 项失败，iPad services 46 项全部通过。
旧整轮只剩 iPad modules，不能将尚未完成的分组写成通过。

从原结果包导出并实际查看 DDNS 与公告失败录像：DDNS 97 秒画面中开关已关闭、
连接成功提示已消失；公告 106 秒画面已只剩另一条附件公告。逐步活动显示原来对
保留元素执行的 `exists == false` 谓词未及时完成。画面与等待判定不一致是已确认
事实，辅助功能缓存或框架内部原因尚未证明。

两项测试改为重新查询并调用现有 XCTest 的 `waitForNonExistence`；DDNS 继续
限定 5 秒，公告继续限定 8 秒，并仍检查另一条公告存在。没有修改产品业务、增加
重试、扩大期限或取消断言。重新编译后 iPhone 两项 111.493 秒、iPad 两项
118.209 秒均通过，0 失败；这属于本机修正验证，尚不能写成云端修复已通过。

```sh
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 4 -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileDDNSUITests/test新建连接测试与保存分离且修改输入清除旧测试结果' '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶公告查看附件并取消公告' -resultBundlePath build/m8j-current-query-phone.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -parallel-testing-enabled NO '-only-testing:DsmMobileUITests/MobileDDNSUITests/test新建连接测试与保存分离且修改输入清除旧测试结果' '-only-testing:DsmMobileUITests/MobileChatManagementUITests/test置顶公告查看附件并取消公告' -resultBundlePath build/m8j-current-query-pad.xcresult
```

`build/m8j-phone-modules/DsmMobile-iPhone-modules-system.xcresult` 的 10 项系统
UI 仍为 8 通过、2 失败。日志按本扩展及对应测试域筛选，默认只读目录确认在系统
`create-item` 阶段发生 POSIX 1、`cannotCreate/cannotSetMetadata`；请求标记
8119226119、失败标记 8085606151 与本机及无业务依赖的最小扩展相同。可编辑域
06:03:54.330 UTC 已成功创建目录，界面 06:03:56.832 的最后一次检查未找到它，
06:04:00.498 的失败层级才含目录；这次没有只读场景的元数据错误，尚未执行下载
或上传。系统首次加载延迟与只读落盘失败分别追踪，不放宽原等待，不计为通过。
完整边界见 [Files 账本](../../development/APPLE_MOBILE_FILES_PROVIDER_ZH.md)。

独立复核确认此次移动变更只涉及测试等待、合成环境启动采样及固定阶段错误日志。
错误日志不包含描述、userInfo、账号、地址或文件路径；采样只匹配指定模拟器和显式
合成参数的 App。注册顺序、原账号绑定、编辑/删除权限、冲突恢复及失败退出均保留。
Mac 发布前增量移动构建及 24 项照片导出、22 项 Files 管理单元共 46 项通过。
正式结果包保留；附件、原始日志、活动导出和中间图片摘录后清理，不提交用户数据。

发布调度补充：macOS 标签还自动触发了独立 Apple Build 整轮，正式发布作业排队，
其中四个移动作业已在运行。Apple Build 的 push 增加全部分支匹配，保留原有分支
路径过滤、PR 与手动触发；正式发布继续由独立 macOS Release 标签流程负责共享
测试、双架构构建、签名、公证和更新验证。该规则依据
[GitHub 工作流语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushbranchestagsbranches-ignoretags-ignore)：只配置分支时不响应标签，且标签不会应用路径过滤。
调整后原 CI 分组与诊断脚本 11 项回归通过（1.558 秒）；未降低任何测试段失败退出。

## 2026-10-07 发布资源整理与运行中日志误判更正

`macos/v1.0.16` 额外触发的 Apple Build `37611198481` 中四个移动作业在运行、
其余排队；该轮没有包含工作区的新等待修正。普通取消接口两次返回 HTTP 502，
回读仍未取消，随后使用 [GitHub 停止无响应运行接口](https://docs.github.com/en/rest/actions/workflow-runs#force-cancel-a-workflow-run)，
已回读确认九个作业全部 cancelled。它不计为验证通过。正式发布 `37611198664`
于 11:30:27 UTC 获得执行资源；发布结果另外记录，不在此宣告已发布。

旧移动整轮 `37575438355` 的 iPad modules 曾多次从运行中日志接口取得同一份
末行 10:41:33.894 UTC 的片段。负责人据此误判单项长时间停顿，于 11:34 发出
普通取消请求。**封存后完整日志证明测试实际上仍在继续**：11:34:15 和 11:35:21
仍有下载设置用例通过，下一用例在取消时中断。此前“同一界面调用持续停顿近一
小时”的判断撤回；接口片段不更新不能证明测试卡住。这次取消使余下界面覆盖
不完整，必须在新提交重新运行，不计为旧整轮通过。

取消后上传步骤在 11:37:54 UTC 成功，作业于 11:38:35 明确 cancelled。
`LanStash-Apple-mobile-tests-iPad-modules` 结果包已下载并保留，先行系统段的
失败和移动单元的已完成证据继续有效，其他已结束分组不受影响。此判断错误已向
用户明确说明；没有取消正式 Mac 发布，也没有重触发同一发布标签。

基于原误判临时加入的单项 600 秒设置在推送前撤回，维持既有测试期限、选择与
断言。期间只对未推送的当前本地提交更新记录，不改写远端历史或 Mac 发布标签。
后续以明确结束的测试段、封存结果及实际调用栈判断进度；运行中日志仅作片段证据，
不能因观测超时推断运行停止。

## 2026-10-07 iPad Files 扩展发现与只读失败封存证据

旧 iPad modules 的系统结果包已独立封存，10 项为 7 通过、3 失败。默认只读用例
08:30:33 UTC 起在系统 `create-item` 重复报告 POSIX 1、`cannotSetMetadata`，
请求标记 8119226119、失败标记 8085606151，与 iPhone、本机及最小扩展一致。

中文与可编辑场景未到系统浏览：分别在 08:28:27.185、08:29:20.942 点击添加，
系统于 08:28:27.593、08:29:21.309 报找不到调用 App 的提供器。日志直到
08:29:22.983 才记录 Files 扩展注册，第三项只读用例于 08:30:01 可以添加域。
第一次清理合成位置也返回 -2001，内层 -2014；实际 Xcode 26.5 SDK
`NSFileProviderError.h` 将 -2014 定义为没有发现可启动的文件扩展。故前两项
添加失败属于系统扩展发现时序，不能与只读落盘错误或 NAS 权限拒绝合并。

读取命令为 `xcrun xcresulttool get test-results summary/activities --path ...`，
并用 `xcrun xcresulttool export diagnostics` 导出、`log show --archive` 按本 App、
扩展标识和用例时窗筛选。实际保留结果路径为
`build/m8j-pad-modules/DsmMobile-iPad-modules-system.xcresult`；临时 zip、活动与
日志导出摘录后清理。旁边的非系统模块结果缺少 `Info.plist`，不能由
`xcresulttool` 打开，未伪称完整封存或测试全过；已完成的单元段仍有最终作业日志。

移动修正及日志更正已正常同步 `origin/main`，提交 `7fe646b2`；新
[Apple Build 37616066715](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715)
已建立并开始执行。仓库与文档预检通过，移动完整结果仍待完成。Mac 发布继续绑定
独立 `macos/v1.0.16` 的 `9f0ff6e0`，没有移动标签、覆盖公开附件或重复触发发布。

## 2026-10-07 macOS 1.0.16 正式发布与公开回读

用户明确要求修复完成后发布 macOS 新版本，同时继续 M6–M8。正式标签
`macos/v1.0.16` 指向 `9f0ff6e0bca854434f955a47f45a22f0f2c2bc88`，主 App 与
File Provider 扩展均为 1.0.16（26）。发布包含上传批次统一传输中心、照片后台状态
与下载结果三秒消失、图标多选/框选、列表高亮及多 NAS 容量补读；不发布移动端。

[macOS Release 37611198664](https://github.com/yuangy1995/dsm-native-client/actions/runs/37611198664)
全部必需阶段通过，版本于 2026-10-07 12:03:09 UTC 公开，正式更新源随后更新。
共享包、本地化/发布回归、双架构构建签名、公证装订、公开附件回读和候选包封存均
成功。发布前本机完整共享为 3117 项 XCTest（177 项既有条件跳过）与 12 项 Swift
Testing 零失败；具体修复的本机交互与临签包证据见本页对应 Mac 修复记录。

发布后再次从公开版本下载两份 DMG、`appcast.xml`、`SHA256SUMS.txt`，从
`macos-updates` 独立下载更新源。校验清单全部匹配，两处更新源字节一致；按顺序
核对 arm64、Intel 两条版本 26 / 1.0.16、包大小、URL 与硬件条件。解出临时 App，
运行 `bash tools/release/verify_macos_distribution.sh <App> <DMG> <source-commit>`，
两种架构均通过正式签名、权限、主 App/扩展架构、更新组件、Gatekeeper、公证票据
及 DMG 内容检查。两包均记录正确来源，未携带临签库验证例外。

使用包内同一公钥运行 `swift tools/release/verify_update_signature.swift`，两份
DMG 的 Ed25519 签名及签名更新源指定长度的原始内容均验证通过。首次回读重复
挂载同一 DMG 报资源忙，已卸载并改为临时解出 App 后运行既定校验；后次完整通过。
临时解包目录和挂载已清理，公开安装包保留于 `build/mac-1.0.16-public-verify/`。
未安装或启动成品，未移动标签、覆盖已公开版本附件或重复触发正式工作流。

| 公开附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `LanStash-1.0.16-arm64.dmg` | 37663482 | `ed9d0cf94f52d966bce66485a0d6486fa64259e17b9584888982a5f9d89cae31` |
| `LanStash-1.0.16-x86_64.dmg` | 41580966 | `000d196ede0b5a45243c96ef57bf802b083fd22230e89674a79694257889c5fd` |
| `appcast.xml` | 7342 | `19414d941937a240a4483144c6926657553f369ff610a1cf9c7f8931f41917df` |

`PENDING_USER_VALIDATION`：Apple Silicon、Intel/Rosetta 的实际在线升级、Finder 挂载、
真实 NAS 上传与多选操作、照片提示和多 NAS 容量。按本页对应修复操作复验，保留
已有配置和恢复记录；只回传架构/版本、脱敏步骤和错误类别。自动化与签名回读不
代替这些实机结果。M6–M8 和新的移动云端仍独立进行，不能因 Mac 发布成功标为完成。

## 2026-10-07 Files 扩展发现失败的恢复提示

在 `7fe646b2` 基线上处理旧云端已封存的系统错误：系统尚未发现本 App 扩展时，
原页面错误要求检查连接和存储空间，与实际错误层级不符。单一修改移动位置模型、
对应测试及双语资源；没有改变 Files 权限、注册流程、共享运行时、持久化或 NAS 请求。
只在 iOS 17.1 起识别 SDK 明确公开的 `applicationExtensionNotFound`，包括已观察到
的 `providerNotFound` 包裹形式；其他域缺失或同码不同错误域不归入此提示。

新增回归覆盖列表读取失败后的准确提示、零注册请求、不假报成功、保留位置、系统
恢复后手动重试复用原位置且只注册一次，以及其他错误不误归类。iPhone 构建并运行
24 项位置管理测试，0 失败（1.733 秒）；同一产物 iPad 24 项 0 失败（1.685 秒）。
本地化 7075/2188/3402 资源及硬编码扫描、文档与差异检查通过。

```sh
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -disableAutomaticPackageResolution -skipPackageUpdates -jobs 4 -parallel-testing-enabled NO '-only-testing:DsmMobileTests/MobileFilesProviderTests' -resultBundlePath build/m8k-files-recovery-phone.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' -parallel-testing-enabled NO '-only-testing:DsmMobileTests/MobileFilesProviderTests' -resultBundlePath build/m8k-files-recovery-pad.xcresult
python3 tools/localization/check_localization.py
python3 tools/codex/check_documentation.py
git diff --check
```

独立集成与只读对抗复核确认此变化仅映射已知系统错误，不自动重试、重复注册、
输出底层错误资料或改变原账号/权限边界。页面沿用现有错误区域，没有新增界面流程；
此次模型证据不代替云端或真机首次发现失败的完整页面复验。系统首次发现时序与
默认只读目录落盘仍未解决，也未把重启提示当作已验证的修复方案。当前新的完整
Apple Build 继续运行，未因这一未推送的增量改变其验证源码或取消作业。

## 2026-10-07 移动整合提交的共享与 macOS 云端门禁

`7fe646b2` 的 [shared-macos 作业](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569014)
已完成且为 success。终态日志确认 `swift test` 的 3117 项 XCTest（177 项既有
条件跳过）0 失败、12 项 Swift Testing 通过；发布脚本回归 45 项通过。临时包权限
与 Sparkle 实际加载检查、按来源提交核对的临时签名 CI 产物校验均通过，产物上传
成功。此项属于移动整合提交的共享/Mac 回归，与前述正式发布签名和公证分别记录。

移动分组仍在运行，尚不能宣告整轮 Apple Build 通过。Files 恢复提示的后续本机
增量未包含在 `7fe646b2`，不能用此作业替代它的两端聚焦结果；默认只读目录及
首次加载失败仍按 Files 账本追踪。当前设备清单无可连接真机，本机仅 iOS 26.5
模拟器，尚不能进行不同系统版本或正式签名设备对照。

## 2026-10-07 Files 指定系统版本云端对照入口

在本机仅有 iOS 26.5、物理设备均不可连接的条件下，核对 GitHub 官方
[macos-26 执行环境清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md#installed-simulators)，
确认其列有 iOS 26.2 和其他 26.x 模拟器。新增仅手动运行的
`.github/workflows/apple-files-compatibility.yml`，固定原仓库完整提交 SHA，使用
现有锁定 Xcode 26.6（17F113）与 XcodeGen 2.46.0，在指定已安装系统的 iPhone/iPad
执行完整原 `MobileFilesProviderUITests` 类。保持原用例与等待断言、临时签名和
产品权限；没有真实 NAS 请求或正式发布。两个设备串行，结果包失败也上传。

本机已用 Ruby YAML 解析并执行所有 shell 步骤的 `bash -n`，以及选择器的两端
固定版本/缺少版本拒绝替代合成检查，全部通过。独立复核确认该入口只有手动触发、
只读仓库权限，不含取消当前完整 CI、跳过失败或重试测试的设置。此次仅新增独立
工作流与说明，不修改完整 Apple Build 的选择规则，不以小范围对照替代完整门禁。
下一步从 `7fe646b2` 运行 iOS 26.2 原用例；运行结果另记，当前不能宣称任何新的
系统版本已通过。回滚移除该手动入口，不涉及应用、权限或持久化变化。

手动入口与对应说明已在 `6127c427` 正常推送 `main`，没有变更正式标签或完整
Apple Build。[iOS 26.2 对照 37621927965](https://github.com/yuangy1995/dsm-native-client/actions/runs/37621927965)
已建立，参数为 `source_revision=7fe646b29b81ddc6c4756923e399da08ea6f65de`、
`ios_runtime=26.2`；两端将串行执行同一原测试类。完整运行 `37616066715` 仍在
进行，没有被本次提交取消。对照仍待结果，不记为通过。

## 2026-10-07 macOS 1.0.16 照片入口消失回归

用户反馈两个 NAS 的侧栏照片入口与功能设置开关同时消失。定位到 `cdc889cc`
新增的 Photos 权限预检：要求四个访问设置接口的 `selectedVersion` 非空，但真实
`DsmCapabilityDiscovery` 不为 Photos 做全局自动选版；`SynologyPhotosRepository`
原本按方法指定 v1。因此正常的 JSON 接口在发出权限读取前就被误判不可用。
原测试手造 FORM 和已选版本，未经过真实发现解析，掩盖了这个回归。

仅修正 Mac `WorkspaceModuleAccessReader` 的预检，使其与既有 Photos 访问读取
一致：四项接口存在、支持 v1 且为 JSON，然后继续读取 Photos 自身授权。没有回退
继承文件权限，不改 NAS 数据、用户开关、登录存储或五端 API 契约。源码复核覆盖
登录接线、侧栏与设置共同读取的模型状态、权限撤回、会话/证书失败和用户手动关闭
偏好；原有拒绝及停止后续请求逻辑保留。

回归使用合成响应经过真实能力发现、Photos Repository、权限读取与工作区模型，
覆盖文件授权与照片授权的四种组合，并验证每次实际请求的 API/版本/方法和拒绝后
不继续读取设置；另覆盖四项接口分别缺失、不支持 v1 或非 JSON 时零权限读取。
修复前新用例在入口与请求链断言上产生 10 个失败，修复后通过。首次测试编译错误
为测试引用了非公开的端点辅助类型，改用合成 URL 后完成上述红绿验证。

```sh
swift test --package-path apple --jobs 4 --filter WorkspaceModuleAccessTests.test真实能力发现与照片授权决定入口且不依赖自动选版
swift test --package-path apple --jobs 4 --filter 'WorkspaceModuleAccessTests|LoginViewModelTests|SynologyPhotos'
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test受限账号菜单功能设置与多NAS列表双语主题绘制|WorkspacePresentationTests.test无应用权限时保留本机设置并隐藏应用入口' LANSTASH_UI_NATIVE_SCREENSHOTS=1 bash tools/codex/run_macos_ui_checks.sh "$PWD/build/mac-photos-entry-ui"
python3 tools/localization/check_localization.py
```

聚焦登录/照片/模块权限 **930 项 0 失败**，包含 22 项模块权限测试；两项实际原生
UI 测试 0 失败。已查看中英文、浅色/深色四组设置截图，照片入口与开关可见；
无权限两种主题仍隐藏入口。本地化 7075/2188/3402 资源及硬编码扫描通过。
以上使用合成账号和响应，没有读取或修改用户 NAS 资料。

用户随后明确要求修复后发布新 macOS 版本。主 App 与 File Provider 版本同步为
1.0.17（27），由固定 XcodeGen 2.46.0 生成工程，仅版本字段变化。发布说明同步
中英文；不改变正式身份、权限、更新通道或最低系统版本。

新增发布范围验证：`swift test --package-path apple --jobs 4` 为 **3119 项 XCTest、
177 项既有条件跳过、0 失败**，以及 **12 项 Swift Testing 全通过**；
`python3 -m unittest discover -s tools/release -p 'test_*.py'` 为 **45 项通过**。
严格发布文档与差异检查通过。两项原生 UI 已单独显式通过，未用条件跳过代替 UI
证据；完整共享包结果也不能代替真实 NAS 或正式签名升级验收。

本机 1.0.17（27）arm64 Release 独立临时包完成，签名、Hardened Runtime 权限、
Sparkle 实际加载与 DMG 校验全部通过。新构建目录的前两轮依赖获取未完成，已终止；
最终使用与 `apple/Package.resolved` 一致的本地 Sparkle 2.9.6 缓存，未改依赖或打包
源码。仅本次 `xcodebuild` 增加 `-disableAutomaticPackageResolution`、
`-skipPackageUpdates` 与 `-clonedSourcePackagesDirPath`，随后执行原打包签名流程。

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_ROOT="$PWD/build/mac-photos-entry-fix-package" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-entry-fix" bash apple/Apps/DsmMac/package.sh
```

测试成品为 `apple/Apps/DsmMac/dist/photos-entry-fix/LanStash-1.0.17-arm64.dmg`；
沿用既有独立测试身份，不包含本地磁盘挂载扩展，未安装或启动，未覆盖旧成品。
正式双架构签名、公证与更新源必须由 GitHub 发布流程独立完成。

`PENDING_USER_VALIDATION`：使用修复测试包连接原有已授权 Photos 的 NAS，确认
侧栏与设置入口出现、照片时间线可读取；仅照片授权账号应不受 File Station 拒绝
影响，明确拒绝 Photos 的账号应继续隐藏入口。只需回传版本、连接方式类别、
脱敏操作步骤和错误类别；无需导出照片、账户、地址或会话资料。合成回归不代替
这次真实 NAS 复验。发布状态在正式流程完成后另记，不提前把源码修复记为已发布。


## 2026-10-07 本机 iOS 26.2 Files 原用例对照

云端指定系统检查尚在排队，本机临时从 Apple 官方安装 iOS 26.2（23C52），新建
iPhone 17 Pro 与 iPad Air 11-inch（M3）模拟器，保持 Xcode 26.6（17F113）、
SDK 26.5、正常临时签名、既有应用及扩展身份。运行既有编译产物中的原三项 Files
UI，未更改用例、重试或替换权限；产物另包含上节尚未提交的扩展发现恢复提示。

使用 `xcodebuild test-without-building -xctestrun
apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun
-destination 'platform=iOS Simulator,id=<本次专用设备>' -parallel-testing-enabled NO
-only-testing:DsmMobileUITests/MobileFilesProviderUITests -resultBundlePath <结果路径>`，
分别保留 `build/m8k-files-ios26.2-phone.xcresult` 与
`build/m8k-files-ios26.2-pad.xcresult`，两次命令均退出 65。

| 用例 | iPhone | iPad | 本轮实际证据 |
| --- | --- | --- | --- |
| 中文深色最大字号位置管理 | 68.412 秒失败 | 65.097 秒通过 | iPhone 点击添加时录像仍为“正在载入位置”且按钮禁用；失败后已载入为空，没有发出添加成功提示，不能归为系统未发现扩展 |
| 可编辑系统浏览、下载与回传 | 86.501 秒失败 | 67.856 秒失败 | iPhone 系统“文件”已显示 Shared，回到 App 的文档选择器后停在“最近项目”，旧导航只作瞬时查询，未等待“浏览”标签；iPad 在系统目录等待时失败，未进入下载，尚未确认底层根因 |
| 默认只读下载 | 70.816 秒失败 | 64.390 秒失败 | 两端系统创建合成目录时均报 cannotCreate/cannotSetMetadata，请求/失败标记 8119226119/8085606151，与 26.5 一致；不能宣称 Apple 已确认缺陷或真机同样失败 |

原系统日志仅按本测试提供器与用例时间窗提取，未读取 NAS。iPad 可编辑域出现
`failed to clear import cookie`（POSIX 0），该时间窗没有只读域的元数据错误，
不能将两者合并成同一根因。iPhone 添加阶段和选择器导航采用单独的正式测试准备
修正：等待添加按钮启用、需要时滚动使其可点击，以及等待实际“浏览”导航元素；
仍只提交一次，保留原目录加载、下载内容与写回断言。复验结果在完成后追加。

同一完整云端 `37616066715` 的 iPhone 服务组
[112774569143](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569143)
已结束并成功，终态日志为 46 项 UI、0 失败，6972.249 秒；其余分组继续执行，
不能将该组通过当作整个移动门禁通过。

测试准备修正后使用正常签名 `xcodebuild build-for-testing` 成功，再按相同
`test-without-building` 选择中文管理与可编辑完整流程：iPhone 两项通过
（58.231/75.110 秒），iPad 两项通过（52.062/71.841 秒）。结果分别为
`build/m8k-files-navigation-phone.xcresult` 与 `build/m8k-files-navigation-pad.xcresult`。
逐张查看两端各四张关键截图：中文添加成功、移除确认末尾与取消、下载原文、
修改后上传成功。没有产品界面改动，全部为合成测试内容。

当前负责人独立复核仅有测试准备变化及前片准确错误提示，未修改读写权限、注册
算法、重试策略或系统结果断言；未调用另一模型。双语/硬编码扫描和严格文档检查
通过。此次两端复验使用已执行过测试的设备，不能据此宣布全新环境首次加载稳定，
因此再建一台全新 iPad 作同两项对照，结果另记；只读原失败不改写为通过。已摘录
的原始诊断、导出截图和录像已清理，正式结果包保留；前两台临时 26.2 设备已删除。

全新 iPad 复验为中文管理 74.370 秒通过、可编辑流程 67.373 秒失败，命令退出 65，
结果 `build/m8k-files-navigation-fresh-pad.xcresult`。失败仍在首次系统目录等待，
并非添加按钮或选择器导航：22:24:17.385 本扩展根枚举返回一个目录，17.500 子目录
已在本地创建成功、17.606 根目录准备完成；21.077 系统 Files 新建根枚举器，
22.544 开始的原 20 秒等待仍未显示 Shared。该时间窗没有 `cannotSetMetadata`，
说明本轮可编辑首次呈现与只读落盘是不同阶段的问题；尚不能归因或宣告修复。
保留原失败与等待断言，不增加刷新重试、不扩大权限。

三台本轮专用 26.2 模拟器、临时 26.2 系统及下载副本、原始诊断/临时截图均已精确
删除；系统列表确认原有 26.5 仍为 Ready，原有两台测试设备和构建缓存保留。
本片恢复提示与测试准备的实际改动、原失败、复验成功和全新环境剩余失败分别保留，
不能据已通过部分宣告 M8c 或 M6–M8 整体完成。


## 2026-10-07 macOS 1.0.17 正式发布与公开回读

用户明确授权修复照片入口后发布新 Mac 版本。来源为
`155ecab96f84dadc055b01cfc0f5a5ded8cbb86d`，版本标签 `macos/v1.0.17`；
[正式流程 37632652225](https://github.com/yuangy1995/dsm-native-client/actions/runs/37632652225)
已成功，双目标均为 1.0.17（27）。[正式发布页](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.17)
于 14:35:41 UTC 公开，正式 `macos-updates` 更新源于 14:35:43 UTC 更新。
没有修改既有发布身份、权限、更新密钥或门禁开关，没有覆盖旧版本附件。

云端本次来源的完整共享结果为 3119 项 XCTest、177 项既有条件跳过、0 失败，
以及 12 项 Swift Testing 通过；45 项发布/签名脚本回归通过。Apple 7074、Android
2188、Windows 3402 的双语资源与硬编码检查通过；发布来源没有混入移动端随后
新增的错误提示资源。双架构正式签名、公证与工作流内回读全部通过。

发布结束后独立下载公开版本的双 DMG、appcast.xml、SHA256SUMS.txt 及正式更新源：

| 公开文件 | 字节数 | SHA-256 |
| --- | --- | --- |
| LanStash-1.0.17-arm64.dmg | 37589077 | c752a9212c65d34b3db69327d005a77861378d2568bbb4b816238b05b920c18d |
| LanStash-1.0.17-x86_64.dmg | 41582822 | 7276259392eed27a553b69c8c83159373ffc66f68cf531054eee6fcd721953a9 |
| appcast.xml | 4018 | 22cf45e4f11f84efcd1fb28a9e83d64662817060b09cbb19b9f960c987a494c5 |

`shasum -a 256 -c SHA256SUMS.txt` 全部匹配；版本附件与正式更新源逐字节相同。
更新源两个条目均为 1.0.17/27、最低 macOS 14、下载地址及长度匹配；Apple Silicon
条目在前并限定 arm64，Intel 条目在后。将两份 DMG 内应用分别复制到临时目录并卸载
镜像，再运行 `bash tools/release/verify_macos_distribution.sh <临时App> <公开DMG>
155ecab96f84dadc055b01cfc0f5a5ded8cbb86d`，均通过版本/来源、主 App 与扩展架构、
Developer ID、描述文件、权限、Sparkle 组件、Gatekeeper、公证票据及镜像一致性检查。

使用应用内相同公钥和 `swift tools/release/verify_update_signature.swift` 独立验证
两份 DMG 的 Ed25519 签名，以及更新源前 3874 字节的签名，全部通过。验证过程中
没有读取私钥、安装或启动应用；临时解包目录和挂载点已清理。当前正式下载与更新
源已完成核对，不将自动化结果替代用户原 NAS 的照片权限与时间线复验。

`PENDING_USER_VALIDATION`：原来受 1.0.16 影响且具有 Photos 权限的账号升级后，
侧栏“照片”与功能设置开关应恢复；仅有照片权限的账号可正常进入，无照片权限
继续隐藏。真实 NAS、Intel/Apple Silicon/Rosetta 的实际升级、挂载保留和完整辅助
功能仍按原条件验收；只需回传版本、设备/连接类别、脱敏步骤和错误，不提交照片
或凭据。

为保留正在运行的完整移动检查 `37616066715`，本次先按已授权版本标签独立发布；
本机 main 的照片修复、后续 Files 修正及本记录暂未推送主分支，待该轮检查结束后
读取远端并正常同步，不取消检查、不强推、不移动正式标签。发布与主分支同步分开
记录；M6–M8 仍继续处理首次 Files 呈现、默认只读和完整云端结果，尚未整体完成。


## 2026-10-07 Files 首次显示与重新打开的独立诊断

在全新 iOS 26.5 iPad Air 11-inch（M4）上，以当前正常临时签名产物执行原中文
位置管理和一次性同域对照。原中文流程 78.690 秒通过；对照总计 99.774 秒，
明确记录首次 20 秒等待 `Shared` 为 false，关闭并重新打开系统 Files 后为 true。
两张截图分别显示空位置与同一位置中的合成 Shared 目录，期间没有重新注册位置、
改变授权、重新发送 NAS 操作或生成另一测试域。

命令为 `xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj
-scheme DsmMobile -destination 'platform=iOS Simulator,id=<本次专用iPad>'
-derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 -parallel-testing-enabled NO
-only-testing:DsmMobileUITests/MobileFilesProviderUITests/test中文深色大字位置权限确认暂停恢复与取消移除
-only-testing:DsmMobileUITests/MobileFilesProviderUITests/test诊断首次文件目录与重新打开
-resultBundlePath build/m8l-files-first-open.xcresult CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`。
该诊断命令退出 0，只说明记录及重新打开对照完成，不能覆盖首次 false 或替代原
可编辑验收用例。首次设备启动 3 分 38 秒后才构建；中间本机内存压力较高，采样
显示构建仍在扫描工程文件，关闭本任务两个闲置模拟器后继续，未将等待写成构建失败。

[Apple DTS 的目录书签讨论](https://developer.apple.com/forums/thread/797469?answerId=855165022)
提供首次枚举为空的排查线索；其场景与本项目不同，不能提升为已确认同一系统缺陷。
本片没有修改产品或原业务断言；一次性测试方法已经精确移除，原测试文件无差异。
专用设备、导出截图、采样和临时日志清理；原有测试设备只关闭并保留全部数据。
接下来恢复移动 UI 验证前须正常增量重建，移除测试缓存中的诊断方法。用户随后要求
先修 Mac 旋转与提示呈现，移动端保持原云端运行并继续保留此缺口。

同一完整云端 `37616066715` 的两端工作区组终态均成功：
[iPad 112774569093](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569093)
166 项 UI、0 失败，10098.241 秒；
[iPhone 112774569047](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569047)
166 项 UI、0 失败，10438.777 秒。两份终态日志均核对来源 `7fe646b2`；其他组继续
执行，不据此宣布整轮通过。指定 26.2 的云端 iPhone 对照已开始构建，结果另记。


## 2026-10-08 原移动云端门禁新增终态

- `37621927965` 的 iPhone iOS 26.2 对照（job `112794046127`）：原三项系统 Files UI
  总计 279.593 秒、2 通过/1 失败；中文管理与完整可编辑主流程通过，只读目录在
  `MobileFilesProviderUITests.swift:131` 失败。没有改权限、放松断言或重跑覆盖失败；
  iPad 组（job `112794046537`）随后也失败：原 3 项均失败，186.052 秒；中文与
  可编辑用例在来源版本第 121 行等添加结果弹窗失败，只读在第 131 行等 Shared
  失败。已直接核对 `7fe646b2` 对应行号，未把前两项记成系统目录或写回已执行失败。
- 原完整 `37616066715` 的 iPad services（job `112774569073`）：46 项 UI、1 失败，
  总计 9889.750 秒。失败仅为 `test灯光接受后断线重启只恢复保存状态且主动应用`，
  495.222 秒；最终 `reveal` 在第 732 行找不到 `mobile.nas.service.activity.succeeded`。
  其余 45 项通过。仅凭日志尚不能区分成功状态未出现或测试定位问题，保留失败，后续
  读取合成结果附件复核；不取消其他原始分组，不据此宣布整轮成功。

原完整运行的 iPad modules（job `112774569123`）也已结束并保留失败：首先执行的
10 项系统主流程中有 2 项失败（616.010 秒），均为 Files：可编辑用例点按同名 Shared
后找不到 Sample 单元格（后续确认误入系统侧栏，见 M8m；来源第 51 行，110.036 秒），默认只读在第 131 行找不到
Shared（92.257 秒）。后续 169 项模块 UI 全部通过（13567.098 秒）。脚本保留前组
失败并最终退出 65；不能仅引用最后一组的成功输出宣布整组通过。结果附件
`11496435246` 已上传，尚未下载；不取消另外仍在执行的原分组。

## 2026-10-08 M8m 原云端失败结果复核（进行中）

本波单一范围为原 Files 系统主流程与 iPad 灯光恢复失败的证据定位及相应移动正式
测试/必要产品修复，不改 NAS 协议、权限或已有 Mac 修复。原运行 `37616066715`
仍有 iPhone modules、两端 administration 三组执行中，保留原运行，不重新派发。
Mac 旋转/浮层修复已先交付独立测试包；其未提交源码和原移动记录保持在工作区。

已用锁定 Xcode 26.6（17F113）、XcodeGen 2.46.0 执行
`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj
-scheme DsmMobile -destination 'generic/platform=iOS Simulator'
-derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4
-disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，
退出 0。该构建纳入最新 Apple 共享改动并移除前轮已删除的一次性诊断方法缓存；
模拟器系统仍为既有 iOS 26.5，不改变最低版本或权限。

原 iPad services 结果包 `11493032774` 已下载并解压，`xcresulttool` 确认 46 项中
45 通过、1 失败。灯光用例的应用按钮点击有记录，但最终仅见原来的部分完成条目，
新成功状态未出现。已查看前置截图、失败层级和录像；首轮视频解码的默认时间容差
返回了邻近后续帧，已改为记录实际帧时间，不能据后续滚动画面断言点击时按钮被遮挡。
本机仍先执行原用例，尚无新的产品修复结论。提取附件只含云端合成数据，未连接或写入
真实 NAS。

较早系统对照准备：`xcodebuild -downloadPlatform iOS -buildVersion 18.5
-architectureVariant arm64 -exportPath "$PWD/build/m8m-ios18.5-runtime"` 返回
`arm64Only is not available for download`（退出 70）；按提示对应的另一官方架构选项
改为 `universal` 仍不可下载（退出 70）。未安装新运行时，未改变 Xcode、最低版本或
现有模拟器，没有据此声明 iOS 18.5 兼容或不兼容。

本机未修改的灯光原用例 `test灯光接受后断线重启只恢复保存状态且主动应用`
通过（iPad Air 11 / iOS 26.5，355.529 秒，1 项 0 失败）；结果为
`build/m8m-pad-led-baseline.xcresult`。相同逻辑仍待云端复核，不凭本机成功覆盖原失败，
不根据尚未证实的触点假设修改产品或重发亮度操作。

iPad Files 可编辑失败得到新明确证据：原 job `112774569123` 第 51 行失败层级中，
选中的是 `DOC.sidebar.item.Shared`，浏览内容来源是系统 `com.apple.DocumentManager.SharedItems`，
标题为 Shared、内容为 No Shared Files；它不是 NAS 的合成 Shared 目录。
原 `app.staticTexts["Shared"].firstMatch` 在 iPad 分栏中会先匹配系统侧栏同名项。
本波正式测试单一改动范围新增 `MobileFilesProviderUITests.swift`：把目录断言/点击
绑定到非侧栏目录单元格，保持原等待期限、目标内容、下载/写回/权限断言，禁止盲重试。
不改产品源代码或 NAS 权限。两端复验结果另记。

目录定位修正后，同一测试产物分别执行
`xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun
-destination 'platform=iOS Simulator,id=<目标设备>' -parallel-testing-enabled NO
-only-testing:DsmMobileUITests/MobileFilesProviderUITests -resultBundlePath <结果目录>`。
iPad `A31ABDE2-186F-43DD-8D40-5EB9511A9289`：中文权限管理 52.080 秒、可编辑下载/
原位编辑/回传 72.195 秒通过，只读位置 58.939 秒失败；结果
`build/m8m-files-selector-pad.xcresult`。iPhone `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`：
前三项相应为 69.098 秒通过、66.129 秒通过、58.648 秒失败；结果
`build/m8m-files-selector-phone.xcresult`。两次均退出 65，各 3 项中 2 通过/1 失败，
失败都位于新第 135 行真实目录显示断言。两端目录及编辑成功的四张截图已逐张复核。
两端使用自造文件，未连接真实 NAS；没有用编辑成功代替默认只读验收。

本机两端系统“文件”为中文，故另补英文系统的 iPad 原可编辑用例，覆盖云端侧栏和
目录都叫 Shared 的碰撞条件。仅临时调整该专用模拟器语言，原值
`AppleLanguages=[zh-Hans-US,en-US]`、`AppleLocale=zh-Hans_US`，完成后恢复；
不修改用户 Mac 语言、产品资源或用例成功标准。英文结果另记。

英文系统补验使用同一 `xcodebuild test-without-building` 命令，限定原
`MobileFilesProviderUITests/test系统文件位置可浏览下载并从外部编辑后上传`，结果
`build/m8m-files-selector-english-pad.xcresult`：69.202 秒、1 项 0 失败、退出 0。
两张实际截图确认英文系统侧栏 Shared 与 NAS Shared 同时存在，选择器已进入后者，
并完成原文件名/内容、协调编辑及合成 NAS 写回检查。未修改或放宽原用例。
完成后回写并读回模拟器原 AppleLanguages/AppleLocale，随后关闭两台专用模拟器；
没有清空设备、修改主机语言或安装正式 App。

独立集成审查与只读对抗复核：三处查询都限定目录单元格，排除系统侧栏；目录等待、
下载、实际内容、编辑回传、权限、错误传播和清理仍保持原断言。此次只改正式测试，
不修改产品运行时、NAS 契约或读写能力。两端只读失败继续保留，不能因中文和英文
可编辑成功提高默认只读等级。当前没有修改灯光产品或正式用例。
`python3 tools/localization/check_localization.py`、
`python3 tools/codex/check_documentation.py`、`git diff --check` 均通过；
本波未改变用户可见字符串。正式结果包保留，导出的原始附件、视频帧脚本/图片和
临时日志在摘录后清理；Mac 已交付的包与示例图保留，不进入移动提交。

## 2026-10-08 M8n 原云端管理组终态与只读边界复核

原完整运行 `37616066715`、来源 `7fe646b2` 的
[iPhone administration](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569083)
已于 2026-10-07 17:33:12 UTC 结束并成功。直接核对作业状态及完整终态日志，
`xcodebuild test-without-building` 执行 88 项 UI、0 失败，8636.415 秒，最终
`TEST EXECUTE SUCCEEDED`；构建及结果上传均成功。结果附件 `11499374495` 已封存，
本波未重复下载成功组的大型结果包。iPhone modules 和 iPad administration 仍在
执行，继续等待原运行，不因部分通过推送并取消，也不将整轮记作成功。

只读问题再核：当前 SDK 将 capabilities 定义为项目自身允许的界面操作，子项不继承
父目录能力；fileSystemFlags 包含 POSIX 权限，不能将写标志解释为独立的元数据权限。
[Apple 论坛 805882](https://developer.apple.com/forums/thread/805882) 的只读下载问题仅
报告于 Intel macOS 26，发帖者称 macOS 26.5 已修复，未包含当前 iOS 目录创建错误。
本波没有因此修改产品、放宽写权限、重复既有三个元数据实验或下载不可用的旧系统。
M6/M7 范围按主计划再次核对：容器创建/编辑和项目写不属于已声明完成的 Mac 基线，
仍保留其源码缺口说明，不将静态接口记录等同实现或待真机验收。


原完整运行的 [iPhone modules](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569029)
于 2026-10-07 18:41:01 UTC 结束并失败。完整日志确认来源仍为 `7fe646b2`：
先行 10 项系统 UI 中 8 通过/2 失败，595.731 秒；两项均属 Files。可编辑用例
102.134 秒在旧第 168 行失败，AX 来源明确为 `com.apple.DocumentManager.RecentDocuments`，
显示 Recents/No Recents，底部 Browse 已存在；此前三轮瞬时查询结束时导航尚未就绪。
这与 `8e1e4529` 的已验证本机导航准备修正吻合，旧运行并未包含该修正，不冒称云端
已经验证修复。默认只读 91.584 秒在旧第 131 行等 Shared 失败。结果附件
`11503119243` 已封存，终态日志和完整失败 AX 足以定位本次阶段，未重复下载整包。

后续 1846 项移动单元为 0 失败、4 项既有条件跳过（83.349 秒）；随后 169 项
其他模块 UI 为 0 失败（12587.541 秒）。最后一段 `TEST EXECUTE SUCCEEDED`
不能覆盖先行系统段失败，分组脚本实际以 65 退出。分享扩展 4 项及普通文件前后台
3 项已包含在先行成功项中。此时仅 iPad administration 仍运行；原完整运行继续保留，
没有因观察等待时间较长而取消。灯光附件再次只读复核仍未形成新根因，导出临时件
已清理，产品和测试源码无新修改。


原完整运行 `37616066715` 最后一组
[iPad administration](https://github.com/yuangy1995/dsm-native-client/actions/runs/37616066715/job/112774569078)
于 2026-10-07 18:53:18 UTC 结束：88 项 UI、87 通过/1 失败，11507.906 秒。
唯一失败 `MobileNasReadUITests/test中文大字号未知开关有独立状态` 在来源第 101 行
等待首页 Sample folder 失败（108.346 秒）；尚未进入 zram 或未知状态断言，不能
称为未知开关显示错误。日志有主线程空闲通知等待超时，随后启动采样也记录
TimeoutExpired；相关结果附件 `11504491448` 另行下载复核，不据空闲超时直接推断
产品死锁或靠增加业务等待时间掩盖。其余 87 项完成，最终测试段退出 65。

同一运行的九个目标组至此全部终态：5 成功、4 失败；汇总 test-and-build 按实际
失败传播而失败，没有被 Agent 提前取消。原 watch 进程已结束，退出 1 与云端
失败一致；不再将其当作活进程重启。旧来源的两项 Files 测试准备问题已有本机修正，
默认只读和 iPad 灯光/启动失败仍分别处理，完整移动门禁未通过。


iPad 管理结果包已完整下载并安全解压到
`build/m8n-pad-admin/DsmMobile-iPad-administration.xcresult`；`xcresulttool` 确认
87 通过/1 失败。原失败附件的完整 AX 显示文件首页停在 `mobile.page.loading`
“正在加载文件…”及“正在读取…”，不是 zram 页面；压缩包中没有诊断目录或任何
sample 文件。不能仅凭页面加载状态确认主线程死锁，也不能据缺失调用栈判断是哪个
采集步骤超时。

未修改的原用例在既有 iOS 26.5 iPad Air 11 上通过（36.294 秒，1 项 0 失败）：
`xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun
-destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289'
-parallel-testing-enabled NO
-only-testing:DsmMobileUITests/MobileNasReadUITests/test中文大字号未知开关有独立状态
-resultBundlePath build/m8n-pad-launch-baseline.xcresult`。
本机通过不覆盖云端失败，正式用例和业务等待时间没有变化。

为验证诊断组件，在同一专用模拟器用 `simctl launch` 启动明确带 `--ui-fixture`
的 `nas-read-unknown` 合成 App，直接调用现有 `HangSampler.capture()`，只包装
三个子进程调用以记录步骤耗时。定位容器 0.343 秒、读取进程 0.087 秒、采集调用栈
9.591 秒，成功生成指定测试 PID 的 sample 文件。该运行是健康进程下的诊断组件
验证，不是云端停顿复现；未查询其他 App 内存或连接真实 NAS，完成后已终止该
合成 App 并关闭模拟器。

本波新增的唯一源码范围为 `tools/release/capture_apple_ui_hangs.py` 及正式测试：
超时/拒绝信息标明容器定位、进程读取或调用栈采集阶段，仅输出固定阶段和异常类型，
不记录原始命令输出。系统 sample 的三秒仅是采样窗口；本机包含符号整理已耗时
9.591 秒，因此把独立采集上限由 15 调整为 45 秒。定位/进程读取上限不变，仍使用
单后台线程且每个合成测试进程最多采集一次；不增加重试、不扩大进程范围、不放宽
应用测试等待或改变原始退出码。这是补足后续失败证据，未宣告启动问题已修复。

`python3 -m unittest tools.release.test_capture_apple_ui_hangs -v`：7 项通过；新增
三阶段超时分支、原始输出不泄露和原测试结果保留检查。完整
`python3 -m unittest discover -s tools/release -p 'test_*.py'`：46 项通过，17.222 秒。
本地化扫描、文档检查和 `git diff --check` 通过。独立复核确认主线程采样仍严格绑定
所选模拟器、实际 App 路径和显式 fixture 标志，定位拒绝时不改用名称扫描或其他进程。
保留正式 xcresult，原下载包、导出附件、健康进程 sample 与临时日志清理；原 Mac
旋转/浮层源码和已交付包不纳入此次移动诊断提交。


本波 `e1f3c38d` 与此前等待的四个提交已在原完整检查结束后正常推送 `origin/main`；
推送前 fetch 确认远端没有新增提交，未强推、未改写历史。Mac 旋转/浮层的未提交
源码和文档仍保留在工作区，未纳入移动诊断提交，未发布新版本。
新 [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252534)
来源为 `e1f3c38d`，已开始分组执行/排队，尚无完整结论；同提交的
[文档预检](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252484)与
[仓库检查](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252566)均通过。
代码同步、工具回归与新一轮移动云端验收分别记录，M6–M8 整体继续未完成。


## 2026-10-08 M8o 可选上传标记单一对照

当前基线 `e1f3c38d` 已同步 main，新 Apple `37672252534` 保持运行。公开 iOS
ReplicatedExtension 只读实现提供未显式实现 isUploaded 的源码线索，SDK 对回收
条件也明确允许缺省；具体引用见[Files 账本](../../development/APPLE_MOBILE_FILES_PROVIDER_ZH.md#可选上传标记对照2026-10-08)。
本波单一临时源码差异是在 iOS 省略原恒 true getter，Mac 原 getter 保留；所有
能力、原三项 Files UI 和等待期限不变，没有复制第三方代码或增加依赖。

沿既有正常临时签名执行 `xcodebuild build-for-testing`（DsmMobile scheme、generic
模拟器目标、m0-m8 DerivedData、4 jobs、关闭自动包解析更新）成功；随后
`xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun
-destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289'
-parallel-testing-enabled NO
-only-testing:DsmMobileUITests/MobileFilesProviderUITests/test默认只读位置通过系统文件下载
-resultBundlePath build/m8o-readonly-omit-uploaded-pad.xcresult`：
1 项、1 失败、60.176 秒，退出 65；仍在第 135 行真实目录显示断言失败。没有因
实验失败扩大权限或追加重试。源码已精确撤回并通过该文件零差异检查，随后重建
正式测试产物以清除实验缓存；恢复构建结果另记。两台模拟器已关闭，正式失败包保留。

恢复原 getter 后，同一 `xcodebuild build-for-testing` 正常临时签名命令退出 0，
`TEST BUILD SUCCEEDED`；后续正式测试包已不含本次可选标记实验。最终
`git diff --exit-code -- apple/Packages/DsmFileProviderRuntime/Sources/ProviderItem.swift`
通过。文档检查及 `git diff --check` 通过，本波无保留产品源码改动，未提交或推送，
当前云端轮次没有被重发或取消。临时构建/测试日志在摘录后清理，原失败 xcresult 保留。

## 2026-10-08 M8p 原启动失败用例有界复现

开始基线仍为 `e1f3c38d`，Apple `37672252534` 正在运行。当前单一范围是原 iPad
`MobileNasReadUITests/test中文大字号未知开关有独立状态` 的间歇启动诊断及证据记录；
正式产品、测试方法、等待时间和业务断言不改。使用已恢复的正式测试产物，在既有
专用 iOS 26.5 iPad 最多运行 10 次，遇首次失败立即结束，不对失败重试；同时接入
现有合成 App 调用栈采集。目的是取得首页持续加载的现场证据，而非把重复通过
视为原云端故障已经修复。只使用测试替身，不连接或写入真实 NAS；其他源码与
用户 Mac 旋转/浮层改动保持原样。该诊断不提升 macOS、Files 只读或真机验证等级。

实际命令（管道启用 `pipefail` 保留原测试退出码）：

```sh
set -o pipefail
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' \
  -parallel-testing-enabled NO \
  '-only-testing:DsmMobileUITests/MobileNasReadUITests/test中文大字号未知开关有独立状态' \
  -test-iterations 10 -run-tests-until-failure -test-repetition-relaunch-enabled YES \
  -resultBundlePath build/m8p-pad-launch-repetition.xcresult 2>&1 | \
  python3 tools/release/capture_apple_ui_hangs.py \
  --device A31ABDE2-186F-43DD-8D40-5EB9511A9289 --output build/m8p-launch-diagnostics
```

结果：同一用例 10 次全部通过，0 失败、0 跳过，命令退出 0；每次
26.126–40.135 秒，Xcode 测试阶段总耗时 326.127 秒。
`xcrun xcresulttool get test-results summary --path build/m8p-pad-launch-repetition.xcresult`
确认 1 个用例、10 次执行，设备为 iOS 26.5（23F77）iPad Air 11-inch（M2）。
本轮没有空闲通知超时，也未触发 sample；结果仅为有界检查未复现，原云端首页
加载失败仍未找到根因，不记为修复。完成后关闭模拟器并清理临时日志，保留正式
xcresult。新的完整 Apple 检查仍为五组运行、四组排队，尚无新终态；后续收取该轮
结果，不继续重复本机检查来代替失败现场。

## 2026-10-08 M8q 新云端 iPhone 工作区终态

来源 `e1f3c38d` 的 [Apple Build 37672252534](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252534)
首个已结束分组为 [iPhone workspace](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252534/job/112966697287)，
job `112966697287` 于 2026-10-07 22:01:47 UTC 成功完成。通过已完成作业的日志
接口直接读取完整输出，确认移动测试包构建成功，正式 `MobileWorkspaceUITests`
166 项全部通过，0 失败、无跳过，测试用例累计 9294.670 秒；最终
`TEST EXECUTE SUCCEEDED` 与作业结论一致。日志无主线程空闲通知超时，也未触发
启动 sample；不据此宣布其他分组中既有的启动故障已经修复。

实际测试命令在 `apple/Apps/DsmMobile` 执行：

```sh
xcodebuild test-without-building -project DsmMobile.xcodeproj -scheme DsmMobile \
  -destination 'platform=iOS Simulator,id=22452A91-4697-4369-8812-53ADB77EB73B' \
  -derivedDataPath /Users/runner/work/_temp/DsmMobile-build -parallel-testing-enabled NO \
  -resultBundlePath /Users/runner/work/_temp/DsmMobile-iPhone-workspace.xcresult \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests'
```

结果附件 `11514556523`（`LanStash-Apple-mobile-tests-iPhone-workspace`，659370758 字节）
已成功封存；本波读取完整日志即可确认结论，未重复下载该已通过结果包，临时日志
摘录后清理。iPad 管理分组已从排队进入运行；当前一组成功、五组运行、三组排队。
Files、服务、其他管理、iPad 与共享/Mac 的本轮结果仍待收取，不由单组通过宣布
M6–M8 整体完成。本波仅同步证据文档，不改产品/测试源码、不重新派发或取消云端，
用户 Mac 旋转/浮层改动继续保留。

## 2026-10-08 M8r 新云端 iPad 工作区失败与测试准备修正

同一来源 `e1f3c38d` 的 iPhone administration（job `112966697266`）已成功完成：
88 项 UI 全部通过、0 失败、无跳过，10312.214 秒；构建、测试及附件上传成功，
结果附件 `11514862755` 已封存。iPad workspace（job `112966697318`）已失败：
166 项 UI 中 164 通过、2 失败、无跳过，10560.868 秒；结果附件 `11514459976`
另行读取。两端服务组已启动，共享/Mac 仍排队，其余运行保持原样。

失败分别是 `test加入相册候选加载空内容和失败中文可恢复` 在来源第 1756 行未找到
相册加载状态（152.764 秒），以及 `test照片删除中文大字确认和剩余操作仍可触达`
在来源第 3045 行未找到可操作的照片导航（43.387 秒）。第二项尚未进入照片删除；
两项均没有启动空闲通知超时或 sample，不能据名称直接认定删除或相册业务失败。

本波单一范围是两项原失败场景的正式测试准备、加载状态合成替身及必要回归；先读
完整事件、失败界面层级/截图，再在原两端模拟器复验。若证据指向产品缺陷，再据
具体原因最小修正；不延长业务等待、不降低原加载/空/错误与危险删除断言，不用
重复运行成功覆盖云端失败。现有产品、共享层和用户 Mac 改动均保持原样，当前
完整云端不重发、不取消；真实 NAS 不参与自动写测试。

原两项在本机 iPad 不改源码均通过：相册三态 86.682 秒、中文大字删除恢复
32.597 秒，结果为 `build/m8r-pad-workspace-baseline.xcresult`。完整云端附件的
失败 AX 明确显示相册弹窗已有 `Sample album` 候选且没有 loading；合成相册读取
原来只等待 30 秒；云端多次界面查询后，失败时加载态已被成功候选列表替换。
照片导航失败的截图及 AX 则仍停在设置页，照片开关值为 0、侧栏没有
照片入口；此旧用例仍直接短按开关，未复用已有可靠触控与开启状态断言。

据此仅改两个正式测试相关文件：`MobilePhotosUIService.addableAlbums` 的加载场景让
同一次可取消读取持续挂起，直到调用方取消；不把它在固定时间后改成成功内容。
中文大字删除用例复用现有 `openPhotos`，包含当前模块的可操作等待、单次触控
和已开启断言。原加载/空/错误检查、照片删除确认、剩余项取消及所有业务等待
时限保持不变；没有修改产品、共享层或权限。修正后的验证另记，尚未云端复验。

正常本机临时签名 `build-for-testing` 成功。修正后 iPad、iPhone 各运行 11 项
`MobilePhotoAlbumTests` 和上述两项原 UI，均 13 通过、0 失败、0 跳过，两个
`xcresulttool` 摘要与日志一致。iPad 两项 UI 分别为 104.870/35.166 秒，iPhone
为 109.652/40.530 秒；结果为 `build/m8r-pad-workspace-fixed.xcresult` 与
`build/m8r-phone-workspace-fixed.xcresult`。两端共 12 张实际 PNG 已逐张检查：
加载、空相册和错误恢复互不混淆，大字号确认正文/按钮完整，未知删除保留刷新、
禁用继续和可滚动到达的剩余取消操作。没有操作真实 NAS 或移除危险确认。

本机实际构建命令（仓库根目录）：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

两端分别执行以下测试命令，iPhone 使用 `8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`
及 `build/m8r-phone-workspace-fixed.xcresult`；iPad 的实际参数如下：

```sh
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' \
  -parallel-testing-enabled NO \
  '-only-testing:DsmMobileTests/MobilePhotoAlbumTests' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test加入相册候选加载空内容和失败中文可恢复' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片删除中文大字确认和剩余操作仍可触达' \
  -resultBundlePath build/m8r-pad-workspace-fixed.xcresult
```

独立集成复核确认改动仅限 Debug 合成服务和正式测试准备。`MobilePhotoAlbumModel`
取消实际 loadingTask、以原草稿身份隔离迟到结果；现有取消加载回归两端通过。
没有增加请求重试、放宽权限、修改共享/macOS 实现或改写任何业务断言。
`python3 tools/localization/check_localization.py` 通过（Apple 7080、Android 2188、
Windows 3402），`python3 tools/codex/check_documentation.py` 与 `git diff --check`
通过。导出与摘要同时首次读取同一结果包时遇到工具缓存创建冲突，待导出结束后
顺序读取摘要成功；不是测试失败，未重新运行测试或修改结果数据。

保留原云端失败包和三份本机正式结果，下载压缩包、临时日志与导出截图清理，
两台测试模拟器关闭。当前云端仍使用 `e1f3c38d`，尚不包含本波两处修正；两组
成功、一组失败、五组运行、一组排队，完整结果仍待收取。本波未提交或推送，
未取消原运行；Files 默认只读及其他未解决项继续保留，M6–M8 整体仍未完成。

## 2026-10-08 M8s 新云端 iPhone 模块终态

同一 `e1f3c38d` 来源的
[iPhone modules](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252534/job/112966697242)
于 2026-10-07 23:08:36 UTC 失败结束。通过已完成作业的日志接口读取完整输出，
确认先行系统段 10 项中 9 通过、1 失败（609.556 秒）：中文 Files 权限管理
75.853 秒、系统浏览/下载/外部编辑回传 119.648 秒通过，默认只读在目录显示
断言失败（96.562 秒）。该提交的 iPhone 可编辑导航修正已有云端复验，不能由
该结果宣布默认只读或 iPad 通过。

失败 AX 已在 LanStash 提供器根目录，Browse 选中，正文 `LanStash is Empty`，
没有进入文件下载；与旧 Recents 未导航和系统 Shared 误选分别记录。日志没有
新的元数据错误或启动采样，当前只确认只读目录仍为空，不伪造新的底层结论。
分享扩展四项与普通文件前后台三项也包含在先行成功项中。

后续 `DsmMobileTests.xctest` 实际为 1848 项，0 失败、4 项既有设备文件保护跳过，
80.840 秒；不能沿用较早来源的 1846 计数。随后 169 项其他模块 UI 全通过，
12619.974 秒。最后一段成功未覆盖系统段失败，分组脚本最终退出 65；完整计数为
2022 通过、1 失败、4 跳过。结果附件 `11517745240`
（`LanStash-Apple-mobile-tests-iPhone-modules`，997930201 字节）已封存，本波
直接核对日志与完整失败层级，没有重复下载已知失败的整包；临时日志摘录后清理。

共享/Mac 已从排队进入运行；当前两组成功、两组失败、五组运行，没有排队组。
本波仅同步 Files 账本、主计划、进度和本记录，不新增源码改动或重复本机实验。
M8r 两处测试修正仍保留在本地等待后续同步，用户 Mac 改动保持原样，当前完整
云端继续保留；默认只读和其他未结束分组继续阻止整体完成。

## 2026-10-08 M8t 相同大字号照片准备步骤复核

在 M8r 已确认的照片开关未开启失败之后，检查同一正式 UI 类仍有三处完全相同的
中文最大字号准备：缩略图/按日选择/导出入口、相似照片选择与确认、人脸空内容
命名保存。它们仍直接短按开关并立即导航；当前云端这三项通过，不能虚称新增
失败。由于与已观察故障具有相同设置页、字号、控件和准备操作，本波仅统一这些
准备步骤为现有 `openPhotos`，保持后续全部业务断言、触控与截图，不修改模块
开关自身的业务测试、服务设置、生产代码或其他平台。

单一源码范围为 `MobileWorkspaceUITests.swift` 上述三项。M8r 已有修改保留，
不重复其无变化模型/界面回归；本波在正常签名构建后分别运行两端新增受影响的
三项原 UI 并检查实际截图，再更新证据。当前完整云端仍保持原运行，用户 Mac
改动继续保留，不因本波提前推送而取消它。

本波沿 M8r 相同的正常临时签名 `build-for-testing` 命令构建成功，随后两端各
三项原 UI 全通过、0 失败、0 跳过。iPad 的缩略图/人脸/相似照片分别为
35.814/44.783/37.876 秒，总 118.473 秒；iPhone 分别为 40.055/69.881/65.483 秒，
总 175.419 秒。两份正式结果的摘要均确认 3 通过，保留为
`build/m8t-pad-photo-preparation.xcresult` 与 `build/m8t-phone-photo-preparation.xcresult`。
两端各四张实际 PNG 已逐张检查：导出入口、人脸名称与保存、相似选择及确认
正文和取消均可到达；沿用原滚动和业务断言，没有以准备修正提升真实 NAS 验证等级。

本机测试命令如下；iPhone 对应 destination 为
`platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`，结果路径为上文
phone 包，其他参数相同：

```sh
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' \
  -parallel-testing-enabled NO \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test中文大字号缩略图调节及按日选择不隐藏导出入口' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test相似照片中文最大字号选择与确认可触达' \
  '-only-testing:DsmMobileUITests/MobileWorkspaceUITests/test人脸大字中文空内容仍可命名保存' \
  -resultBundlePath build/m8t-pad-photo-preparation.xcresult
```

独立差异复核确认只替换重复准备，未新增辅助抽象、修改控件业务或降低断言；
文档检查及 `git diff --check` 通过。仅 UI 测试准备有新增改动，本片没有重新
运行无变化的模型、共享与 macOS 门禁。临时构建/测试日志、导出截图清理，正式
结果保留，两台模拟器关闭。源码仍在本地，当前 `e1f3c38d` 云端不包含本波修正，
未重新派发、取消或推送；五个尚未结束分组继续按真实终态收取。

## 2026-10-08 M8u 新云端共享与 macOS 终态

来源 `e1f3c38d` 的
[shared-macos](https://github.com/yuangy1995/dsm-native-client/actions/runs/37672252534/job/112966696788)
于 2026-10-07 23:28:28 UTC 成功完成。完整作业日志与逐步结论已核对：

| 实际命令/步骤 | 本轮结果与边界 |
| --- | --- |
| `swift test --package-path apple` | 3119 项 XCTest，零失败、177 跳过，90.902 秒；另 12 项 Swift Testing 全通过。177 项分别为 175 项需独立输出目录的 Mac UI 检查、1 项可选目录性能基准、1 项缺专用测试配置的真实 QuickConnect。条件跳过不算已运行通过，不能沿用较早来源的 3103/172 计数 |
| `python3 -m unittest discover -s tools/release -p 'test_*.py'` | 46 项通过，29.812 秒，包含发布/升级及本轮诊断工具回归 |
| 锁定 XcodeGen 生成工程后 `git diff --exit-code -- DsmMac.xcodeproj/project.pbxproj` | 通过，生成工程与该提交一致 |
| 在 Mac 工程目录执行 `./package.sh`，`LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_BUILD_TYPE=Release`、`LANSTASH_TARGET_ARCH=native`、`LANSTASH_RUN_AFTER_PACKAGE=0` | Release arm64 构建、架构核对与临时签名 App/DMG 成功；本轮不包含 x86_64 构建，未启动成品 |
| `tools/release/verify_macos_unsigned_ci_artifact.sh`，传入该临时 App、DMG 和当前来源提交 | 来源提交、严格签名、DMG 校验和及挂载后 App 比对通过；打包时另有真实 Sparkle 动态库加载成功，不仅是签名静态检查 |

临时包按现有流程不包含 File Provider 挂载扩展，不能替代正式签名、授权文件、
公证、Finder 或真实 NAS 验收。正式发布脚本在缺少候选产物时按预期返回 2，
该负向检查不是正式发布通过，也没有执行发布。App/DMG 比对中出现框架目录链接
循环提示，但比较命令保持非零即失败的门禁，最终校验成功；未忽略失败退出码。

附件 `11518107000`（`LanStash-macOS`，54042532 字节）已封存，本波读取完整
日志而未下载、安装或启动该包，不覆盖用户已交付的 Mac 旋转/浮层独立测试包。
本波仅同步主计划、进度及本记录，临时日志摘录后清理，文档和差异检查通过。
当前共三组成功、两组失败、四组移动测试仍运行；源仍为 `e1f3c38d`，不包含本地
M8r/M8t 测试修正，完整移动验收和 Files 默认只读缺口继续保留。

## 2026-10-08 M8v 新云端 iPad 模块失败复核与测试修正

来源 `e1f3c38d` 的 iPad modules（job `112966697170`）于 2026-10-07 23:57:16 UTC
失败结束，附件 `11518544378` 已封存。完整日志确认四项失败，不能按 iPhone
仅剩默认只读推断 iPad 结果：

- Files 可编辑用例在来源 `MobileFilesProviderUITests.swift:158` 的选择器导航
  准备失败，86.970 秒；失败 AX 已显示系统 Recents 与 `DOC.sidebar.item.LanStash`，
  尚未进入提供器目录，不是此前误点系统 Shared 的同一个断言位置。
- 默认只读用例继续在第 135 行目录显示失败，91.568 秒。
- `MobileArchiveDownloadTests/test同一选择重复点击只启动一个下载且不受文件名影响`
  在辅助等待处失败，4.423 秒；首请求替身使用固定 160 毫秒延迟，具体状态时序
  仍需复现，不能将等待失败直接认定为重复提交保护的产品缺陷。
- `MobileChatGroupCreationUITests/test中文深色大字号邀请拒绝保留已完成步骤并可继续`
  在第 66 行点击继续按钮时无法获取匹配快照，93.678 秒；失败前按钮可用且已有
  截图，须核对事件与后续页面，不先假定邀请或恢复本身失败。

1848 项移动单元为 1 失败、4 项既有条件跳过（77.303 秒），169 项其他模块 UI
为 1 失败（15260.877 秒）；先行系统段两项失败，最终分组退出 65。三个仍在
运行的管理/服务分组继续保留。本波单一范围是上述三个新失败点的测试和必要
生产修正，先读原结果包、做聚焦复现，再按证据修改。M8r/M8t 的已验证改动及
用户 Mac 改动不得覆盖；只读失败不跳过、不扩大写权限，不接触真实 NAS 数据。

结果包正式统计：系统段 10 项（8 通过、2 失败）；主结果 2017 项（2011 通过、
2 失败、4 既有条件跳过）。两包合计 2027 项，不能用日志行匹配代替正式统计。
本机原基线 `build/m8v-pad-baseline.xcresult` 运行同一下载单元、中文群聊 UI 与
Files 可编辑 UI，退出 65：下载单元 0.307 秒通过；群聊 105.758 秒失败在成员
选择的 `isHittable`，Files 186.695 秒失败在 Shared 正文等待 Sample 文件。
二者均不是云端的原断言位置。群聊失败 AX 和视频实际 99.9867 秒帧显示
Sample member 完整可见，键盘在弹窗下方，XCTest 仍报告无有效激活位置；
Files AX 已在当前合成提供器的 Shared 目录，正文持续显示正在载入。
该本机 Files 失败保留，不能因导航等待修正而认定已经解决。

独立修正范围限定为：下载测试替身的完成时序、Files 导航等待的单次快照查询、
群聊表单稳定标识及对应 UI 测试的可见区域操作；产品权限、恢复、请求和安全
语义不变。下载先在原替身中增加 200 毫秒受控间隔作对照，结论及最终修正
以实际测试记录为准；临时对照代码和导出附件不进入提交。

下载受控对照 `build/m8v-archive-controlled.xcresult` 退出 65（1 项、2 断言失败，
3.419 秒）：第二次入队前等待 200 毫秒，首任务已为 succeeded，第二任务随后也为
succeeded，实际请求数 2。这证明原 160 毫秒替身未固定“同时进行”的测试前提；
云端仅有一条辅助等待失败，不能据此唯一确定云端当时等待的是哪一步。正式修正
改为测试显式放行完成回调，重复提交拦截后才完成首任务；取消场景先等 cancelling
再放行迟到结果，原清理及身份隔离断言保留。等待失败现在指向实际调用行。
临时 200 毫秒间隔和输出已移除，两次构建均成功，最终两端聚焦回归进行中。

本机可编辑 Files 的独立系统日志按合成域与用例时间窗进一步确认：08:09:13–19
在尚只读时 Shared 元数据落盘失败；允许编辑后 08:09:30 目录落盘成功。08:10:22
扩展已完成该目录枚举，08:10:31–08:11:19 系统反复报告父目录 materialization
取消，Sample 文件直到 08:11:02 才落盘成功，失败界面仍显示正在载入。该证据
区分“目录/文件已落盘”和“系统选择器已显示”，不能直接证明最终 UI 失败原因，
也不能将初始只读错误误作编辑之后始终无法落盘；尚需后续对照。

最终本机正常临时签名构建通过；随后两端分别运行同一 18 项聚焦检查，均为
17 通过、1 失败、0 跳过，退出 65。结果包为 `build/m8v-pad-fixed.xcresult`
及 `build/m8v-phone-fixed.xcresult`，摘要与逐项结果一致。

| 实际测试范围 | iPad | iPhone |
| --- | --- | --- |
| MobileArchiveDownloadTests 全部 11 项 | 全通过 | 全通过 |
| 中文深色最大字号群聊恢复 | 59.452 秒通过 | 63.054 秒通过 |
| 创建丢回执、加入中断恢复、正常创建三项群聊 UI | 全通过 | 全通过 |
| 中文 Files 管理 | 45.486 秒通过 | 43.512 秒通过 |
| 系统浏览、下载、外部编辑后回传 | 68.053 秒通过 | 67.569 秒通过 |
| 默认只读 Files 目录 | 59.479 秒失败 | 59.473 秒失败 |

默认只读两端仍在 `MobileFilesProviderUITests.swift:135` 失败，失败 AX 均已
进入本合成提供器根目录并显示为空，没有跳过或开放写权限。此次可编辑通过不
抹去原基线持续加载失败，也不证明新测试修正已经云端通过。两端各 12 张关键
截图已逐张复核：成员选择、部分创建/恢复、新会话、系统目录与回传，以及最大
字号下的编辑/删除/移除后果和暂停状态；其余重复中间附件未逐张检查。

实际构建命令（仓库根目录）：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

两端实际测试命令：

```sh
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' \
  -parallel-testing-enabled NO \
  -only-testing:DsmMobileTests/MobileArchiveDownloadTests \
  -only-testing:DsmMobileUITests/MobileChatGroupCreationUITests \
  -only-testing:DsmMobileUITests/MobileFilesProviderUITests \
  -resultBundlePath build/m8v-pad-fixed.xcresult

xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' \
  -parallel-testing-enabled NO \
  -only-testing:DsmMobileTests/MobileArchiveDownloadTests \
  -only-testing:DsmMobileUITests/MobileChatGroupCreationUITests \
  -only-testing:DsmMobileUITests/MobileFilesProviderUITests \
  -resultBundlePath build/m8v-phone-fixed.xcresult
```

独立集成差异复核确认：产品仅为两个群聊表单增加同一稳定 AX 标识；测试滚动
限定当前表单可见区域，排除导航栏与键盘，成员点击增加选中状态断言。Files
等待仍使用原 8 秒期限和最多三次导航，未改权限、系统开关或下载/回传检查。
只读对抗复核保留默认只读失败、取消后迟到回调清理和未知群聊不重复创建检查；
未改变产品请求、存储、身份、签名权限或五端契约，也未触碰既有 Mac 改动。
本波无共享/Mac 实现变化，没有重复其既有回归或将旧结果当新修正验证。
`python3 tools/localization/check_localization.py` 通过（Apple 7080、Android 2188、
Windows 3402，含硬编码扫描）。M8r/M8t 已验证改动继续保留，当前修正尚未提交
推送；源 `e1f3c38d` 的原完整云端继续运行，不取消、不重发。M6–M8 整体未完成。

本波收尾的 `python3 tools/codex/check_documentation.py` 与 `git diff --check` 均通过。
临时日志、活动附件导出、视频帧和取帧脚本已清理，保留原云端两包、原本机基线、
受控对照及两端最终测试共六个正式结果包；两台模拟器已关闭。收尾时 iPad 管理组已成功结束，当前云端为
四组通过、三组失败、两组服务仍运行，后续继续收取原作业结果与处理默认只读缺口。

## 2026-10-08 M8w 新云端 iPad 管理终态

源 `e1f3c38d`、运行 `37672252534` 的 iPad administration（job `112966697064`）
于 00:52:48 UTC 成功结束。直接读取完整终态日志并核对步骤：临时签名测试构建、
88 项实际管理 UI、结果上传均成功；测试 0 失败、0 跳过，9325.854 秒。其他平台
的条件步骤跳过不计为本组测试跳过，不将本组通过替代模块/服务或全量移动验收。
结果附件 `11521651328` 已封存（994282022 字节），本波未下载无失败的完整结果包；
完整日志摘录后清理。当前共享/Mac、iPhone 工作区及两端管理四组通过，两端模块
与 iPad 工作区三组失败，两端服务继续运行。M8r/M8t/M8v 的本机修正仍未进入此
云端来源，不据此宣布新测试修正已经云端通过；默认只读与完整收口继续未完成。

## 2026-10-08 M8x 新云端 iPhone 服务终态

源 `e1f3c38d`、运行 `37672252534` 的 iPhone services（job `112966697384`）
于 01:00:31 UTC 成功结束。直接读取完整终态日志并核对步骤：测试构建、
`MobileServiceSettingsUITests` 全部 46 项真实界面操作和结果上传均成功，
0 失败、0 跳过，8287.176 秒；没有启动等待超时诊断。其余分组及 iPad 服务
不由该结果提升验证等级，本机尚未提交的修正也不包含在该来源中。

结果附件 `11521552740` 已封存（849271778 字节），本波未下载无失败的完整
结果包；日志摘录后清理。本波仅同步状态与验证记录，没有新增源码修改、
测试重跑或真实 NAS 操作。当前共享/Mac、iPhone 工作区、两端管理及 iPhone
服务五组通过，两端模块与 iPad 工作区三组失败，仅 iPad 服务仍在执行。
默认只读 Files 与完整云端收口继续未完成，保留全部已有失败证据及安全边界。

## 2026-10-08 M8y 完整云端终态与代理输入修正

源 `e1f3c38d` 的最后一组 iPad services（job `112966697227`）于 01:08:50 UTC
失败结束；运行 `37672252534` 于 01:08:57 UTC 确认为 completed/failure。
完整一轮为 5 组通过、4 组失败，原跟踪进程也正常报告失败退出，不再有运行中分组。

iPad 服务测试构建和结果上传成功，46 项 UI 中 45 通过、1 失败、0 跳过，
8827.970 秒。唯一失败为 `MobileServiceSettingsUITests/test代理地址校验保存并关闭代理`，
74.612 秒，来源第 645 行：替换地址前按长度退格后仍残留合成文本 `proxy.examp`。
此时尚未输入测试用的无效地址，更没有提交代理设置；不能认定为代理保存或灯光
恢复失败。完整日志确认本轮灯光等其他服务用例通过，保留此前失败历史。

结果附件 `11521149124`（994815426 字节）已封存，完整日志已读取。本片单一
修改范围限定为该输入准备步骤及必要同类 UI 验证，先核对字段、焦点和实际编辑
动作，再决定修正；不改变代理校验、确认、关闭代理或 NAS 请求行为，不扩大
到其他产品功能。已完成的 M8r/M8t/M8v 改动和用户 Mac 改动继续保留。

完整结果包下载进度较慢；完整终态日志已经提供原值替换步骤、退格动作及精确
残留内容，因此主动停止可选附件下载并清理不完整副本。原云端包仍保留在 GitHub，
本波未读取它的截图，不能以本机截图代替云端现场。日志不确定是光标位置还是
连续退格输入丢失，因此修正不依赖该猜测：代理地址两次替换显式复用现有系统
全选路径，其他数字输入分支不变，继续严格比较完整结果文本和保存状态。
测试构建已成功，正在两端验证原代理完整流程及独立标题数字框的 UPS 代表流程。

首轮本机 `build/m8y-pad-proxy-selection.xcresult` 为 1 通过、1 失败：UPS 数字输入
186.216 秒通过，代理在等待全选菜单处 47.957 秒失败。已导出并实际检查截图及
AX：地址已聚焦，光标在文字中间，键盘仅显示底部辅助条，未出现编辑菜单。
因此撤回对长按菜单的依赖，代理地址改用当前 SDK 公开支持的 `typeKey` 全选
快捷键，继续真实输入并核对完整值；非代理字段分支恢复原表达式。此修改仍
仅限测试，后续结果单独记录，不把首轮失败记作通过。

最终键盘全选路径构建成功，iPad 原代理用例 105.088 秒通过，iPhone 原代理用例
87.843 秒通过；无失败或跳过。UPS 非代理数字输入分支行为未改，iPad 首轮已有
186.216 秒通过，iPhone 最终同组为 141.303 秒通过。本波保留三个正式结果包：
`build/m8y-pad-proxy-selection.xcresult`（首轮 1 通过/1 失败）、
`build/m8y-pad-proxy-keyboard.xcresult`（最终代理 1 通过）及
`build/m8y-phone-proxy-keyboard.xcresult`（代理与 UPS 2 通过）。最终摘要分别核实
为 Passed/1 和 Passed/2；首轮失败不改记为通过。

本波沿 M8v 相同的正常临时签名 `xcodebuild build-for-testing` 命令构建两次，
均成功。最终 iPad 实际命令：

```sh
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289' \
  -parallel-testing-enabled NO \
  '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理' \
  -resultBundlePath build/m8y-pad-proxy-keyboard.xcresult
```

最终 iPhone 实际命令：

```sh
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' \
  -parallel-testing-enabled NO \
  '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理' \
  '-only-testing:DsmMobileUITests/MobileServiceSettingsUITests/testUPS网络连接等待时间校验及保存' \
  -resultBundlePath build/m8y-phone-proxy-keyboard.xcresult
```

首轮 iPad 使用上述 iPhone 同两项选择，设备改为 iPad，结果路径为
`build/m8y-pad-proxy-selection.xcresult`。已逐张复核两端各五张成功场景截图
（代理风险/关闭、UPS 表单/风险/保存），另查看首轮代理失败截图一张；没有读取
原云端截图。独立差异复核确认只在原帮助方法中显式选择系统快捷键，两处代理
调用启用；其他字段路径保持原表达式，完整值、非法值拦截、具体确认、取消和
最终状态检查保留。没有新增依赖、产品请求/权限/持久化变化或测试重试。

本地化及硬编码扫描通过（Apple 7080、Android 2188、Windows 3402），文档与
差异检查通过。本波不改共享/Mac 实现，不重复其既有门禁；全程只用本机合成数据。
两台模拟器由测试进程关闭后已实查无启动设备。当前新修正仍待云端复验，
Files 默认只读和首次呈现问题继续保持未解决，M6–M8 整体不计为完成。

## 2026-10-08 M8z 移动测试修正整合与推送

已将 M8r/M8t/M8v/M8y 的 8 个移动源码/测试文件及 4 份移动记录整合为
`c26eb3cce39fca61aa1e6eacd3c13848461d3e26`（修正移动端异步测试状态与界面输入定位），
正常提交并推送 `origin/main`。推送前 fetch 与远端比较为 0/0，推送后独立读取
远端 main 确认同一完整提交；没有强推或改写历史。暂存检查仅 12 个目标文件，
验证历史只暂存移动部分，独立 Mac 旋转/浮层段及其空行共 74 行继续留在工作区，
其余 Mac、共享 Photos、资源和私有接口观察改动均未纳入。

本波本机门禁与中间失败见上述各节；M8y 临时日志、原始附件导出及不完整下载
已清理，三份正式结果保留，两台模拟器已关闭。新
[Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37713732061)
来源确认为 `c26eb3cc`，已开始执行/排队，尚无完整结论；此前 `e1f3c38d` 的完整
检查已经全部结束并失败，不会被新推送中断。代码同步不等于云端通过或发布，
默认只读 Files、首次呈现和真实设备边界继续保留。

同提交的 Repository Check（`37713732041`）及 Documentation & Quality Preflight
（`37713732046`）均已完成且通过；Apple 各目标仍在执行/排队，不能据预检通过
替代目标平台测试。以上推送后状态记录先留在本机，随后续验收结果一并维护。

## 2026-10-08 M8aa 非复制式文件扩展隔离对照

当前来源仍为 `c26eb3cc`，完整云端 `37713732061` 正在运行，本波不取消或重启它。
此前独立复制式扩展已复现只读目录落盘失败；本次仅验证另一种公开扩展方式是否
值得进一步研究，不以替换框架、放宽权限或缩小正式验收范围预设成功。

依据 Apple [File Provider](https://developer.apple.com/documentation/fileprovider) 与
[非复制式扩展](https://developer.apple.com/documentation/fileprovider/nonreplicated-file-provider-extension)
公开说明，`NSFileProviderExtension` 仍提供 iOS 枚举、占位、下载与文件操作入口；
当前 SDK 的对应类没有整体弃用标记。它由扩展负责本地副本，不能直接视为复制式
实现的等价替换；若后续采用，缓存、原位写回、冲突、删除与会话撤销仍须完整评估。

本波单一修改范围是忽略目录中的独立临时 App/扩展/UI 对照及本节证据。使用独立
测试身份、共享容器与临时签名，只返回 `Shared/Probe.txt` 固定合成内容，不引用
产品 Package、不联网、不访问 NAS 或用户文件。先在 iPhone 进行目录首次呈现及
选择器原位读取；取得有意义结果后再作 iPad 对照。目录与文件均只报告读取能力，
所有数据写回调拒绝；保持原正式只读用例的等待和内容检查要求。

产品身份、权限、数据格式、共享运行时、Mac 与原正式测试均不改。临时工程与设备
内容在取证后清理，保留可复核的结果包和脱敏结论；本机结果不能提升为真实设备
或完整云端通过，也不能单凭最小对照宣布 M8c 已完成。

首轮 iPhone 对照构建成功，实际 UI 于 64.445 秒失败：位置注册成功，但系统在
点击位置后显示要求打开测试 App 的提示，未进入目录/内容验收。系统记录中的新域
仍为关闭状态，独立帮助方法在侧栏开关已经显示开启时跳过了切换；原正式用例则
始终先关再开本测试位置。下一轮仅对齐这一准备步骤并增加固定回调诊断，原 20 秒
目录等待和完整文本/零数据写检查保持不变。首轮结果包独立保留，不将该失败直接
解释为非复制式只读能力失败；目前只有 AX 与日志，未取得首轮像素截图。

第二轮构建成功，原 iPhone 在 51.135 秒完成整个独立只读流程，1 通过、0 失败、
0 跳过。已逐张查看三张截图：系统目录和选择器均明确显示“只读”，固定文本完整
读出，数据写回调计数为 0。为区分准备修正与已有设备状态的影响，随后以同一最终
产物在全新 iPhone/iPad 模拟器分别作首次安装对照，均通过；原失败结论保留，
零写回调计数不表述为已执行破坏性写入攻击测试。

| 对照 | 实际结果 | 正式结果包 |
| --- | --- | --- |
| 原 iPhone 首轮 | 1 失败，64.445 秒；系统要求打开 App，未进入目录验收 | `build/m8aa-nonreplicated-phone.xcresult` |
| 原 iPhone 准备修正后 | 1 通过，51.135 秒；完整只读流程，0 跳过 | `build/m8aa-nonreplicated-phone-r2.xcresult` |
| 全新 iPhone 17 Pro / iOS 26.5 | 1 通过，60.664 秒；首次目录、原位文本读取、零数据写回调，0 跳过 | `build/m8aa-nonreplicated-fresh-phone.xcresult` |
| 全新 iPad Air 11-inch（M4）/ iPadOS 26.5 | 1 通过，58.330 秒；相同完整只读流程，0 跳过 | `build/m8aa-nonreplicated-fresh-pad.xcresult` |

已逐张查看三次成功运行的九张截图：实际系统目录、选择器和主 App 读回内容均
正确，系统标明“只读”。未改变原等待、完整文件名/文本及零数据写回调断言。
只读对抗复核确认临时 App 没有网络实现，读权限没有混入新增子项、重命名或删除；
缓存的固定文本设置为本机只读。此复核不是外部 App 写入攻击或真实 NAS 权限验证。

实际生成/构建命令（同一构建命令在准备修正前后各成功一次）：

```sh
build/m8a-xcodegen/xcodegen/bin/xcodegen generate --spec build/m8aa-nonreplicated-probe/project.yml
xcodebuild build-for-testing \
  -project build/m8aa-nonreplicated-probe/NonreplicatedProbe.xcodeproj \
  -scheme NonreplicatedProbe -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' \
  -derivedDataPath build/m8aa-nonreplicated-probe/DerivedData -jobs 2 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building \
  -xctestrun build/m8aa-nonreplicated-probe/DerivedData/Build/Products/NonreplicatedProbe_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=F371A072-D764-4981-80AC-597E24D639E3' \
  -parallel-testing-enabled NO \
  -resultBundlePath build/m8aa-nonreplicated-fresh-phone.xcresult
```

全新 iPad 使用同一测试命令，设备为 `E772A89A-0707-4800-A4E4-C9A4B0E3B7BC`，
结果路径改为表中的 iPad 包；前两轮使用原 iPhone ID 与各自表中结果路径。
生成器实查为锁定的 2.46.0，未使用全局旧版本；不改变产品工程、工具链或身份。

结论是非复制式最小只读路径在当前两种模拟器上可工作，提供了新候选方向；现有
产品的复制式路径仍未修复。下一切片须先核对原位写回的基线版本、冲突/未知恢复、
缓存回收、目录删除与位置移除的等价性，再决定完整适配，不能只交付只读子集。
本波未改共享/Mac 源码，不重复其已有门禁，也不据最小对照提升整轮云端结论。

收尾已删除两个专用模拟器，并从原 iPhone 卸载本波测试 App 与 Runner；独立回读
确认测试身份不存在且没有启动中的模拟器。临时工程、构建/测试日志、原始诊断和
导出截图已精确清理，仅保留上表四个结果包。文档与差异检查通过，产品源码与暂存区
均无本波改动；四份移动记录仍未提交，用户 Mac/共享 Photos 等原改动完整保留。
北京时间 11:38 的云端复核仍为五组测试运行、四组排队，尚无测试步骤或作业终态。


## 2026-10-08 M8ab 正式移动文件扩展适配与回归

基线为 `c26eb3cc`，本波使用现有 main。单一修改范围为移动 Files 平台入口、
共享模块内仅 iOS 的本地副本/桥接、原枚举器的可选转换、位置恢复与对应测试；
另按实际云端失败修正套件搜索测试的清空方法。用户已有 Mac/共享 Photos/资源、
契约与观察记录保留，不归入本波代码。无真实 NAS 请求、发布或身份/签名变更。

正式扩展改用 `NSFileProviderExtension`，仍调用同一 `ProviderRuntime`。本地副本
元数据保存在既有移动共享容器，完整文件保护并排除备份；记录取回时版本与摘要，
远端列表刷新不能更新脏副本的原版本。系统编辑先冻结到原写回记录，再经原权限、
互斥、版本和结果回读路径处理；未知结果不重发。主 App 的恢复页明确继续同一
记录；删除和位置移除先检查本机未保存修改及原未完成记录。旧开发位置不自动
迁移或删除，回滚保留副本。完整范围与设备条件见[Files 账本](../../development/APPLE_MOBILE_FILES_PROVIDER_ZH.md)。

独立集成及只读对抗复核由当前负责人在实现后进行：检查 Mac 仍使用默认空转换、
原运行时写前/写后门、账号绑定、原位副本与冻结副本、变更版本、符号链接和位置
身份隔离、删除及移除。新增桥接测试实际验证远端冲突零上传、未知上传重启只读
恢复且不覆盖后来编辑。复核发现根项目不参与子项枚举，原初始化只读能力会挡住
已授权目录创建；已按位置范围/授权刷新，并增加与共享运行时相等的对照测试。

中间结果如实保留：首轮新类型属性与系统协议同名导致构建失败，修正名称；另一次
测试的可选能力缺少解包导致编译失败，使用严格解包修正。R4 八项本地存储行为通过；
R5 增加位置隔离后的全部 1857 项单元通过（4 项既有设备保护条件跳过）。原 iPhone
的中文 Files 管理通过，但另外两项在系统导航阶段失败，尚未进入 NAS 目录。
原扩展采样只有加载器帧，不能据此宣称业务死锁。R6 明确未配置默认入口，Debug
清理只移除本测试 UUID 的系统副本，再用全新设备对照；二者同时改变，不能将
导航失败的唯一原因归于默认入口。最终正式测试没有放宽等待或断言。

| 运行 | 实际结果 | 结果包 |
| --- | --- | --- |
| R4 iPhone 本地存储 | 8 通过、0 失败/跳过 | `build/m8ab-local-storage-phone.xcresult` |
| R5 原 iPhone 全单元及 Files | 单元 1857 项 0 失败/4 既有跳过；UI 1 通过、2 系统导航失败 | `build/m8ab-phone-full-unit-files.xcresult` |
| R6 全新 iPhone 原 Files 三项 | 中文权限 49.056 秒、编辑回传 72.080 秒、默认只读 55.404 秒；3 通过、0 失败/跳过 | `build/m8ab-fresh-phone-files.xcresult` |
| R6 全新 iPad 全单元及原 Files 三项 | 共 1860 项：1856 通过、4 既有跳过、0 失败；三项 UI 全通过 | `build/m8ab-fresh-pad-full-unit-files.xcresult` |
| R7 iPad 恢复及云端原失败对照 | 79 单元与 4 UI，83 通过、0 失败/跳过 | `build/m8ab-pad-recovery-cloud-regression.xcresult` |
| R8 iPad 根目录修正后 | 61 项缓存/写回单元与原 3 项 Files UI，64 通过、0 失败/跳过 | `build/m8ab-final-pad-files.xcresult` |
| R9 iPad 删除恢复修正后 | 62 项缓存/写回单元，全部通过、0 失败/跳过；同时覆盖文件与目录删除 | `build/m8ab-final-pad-recovery.xcresult` |
| R9 iPhone 最终整合 | 1861 单元零失败/4 既有跳过，Files 三项及套件搜索一项 UI 全通过；总计 1865 项、1861 通过、4 跳过 | `build/m8ab-final-phone-unit-files.xcresult` |

R7 的四项 UI 是套件与来源搜索清空、日志翻页及本页筛选、无权限批量删除、未知
批量删除重启不重放。套件清空用系统全选加删除，保留完整空值与恢复目录断言；
其余三项原用例本机直接通过，未据此改写云端失败或宣称产品已修复。
云端另有回调授权测试 `CancellationError`、人脸归属测试准备超时；两类原单元
在本次完整单元及 R7 聚焦对照均通过，当前没有足够证据修改其产品行为。

已逐张复核十张关键截图（两端各五张）：系统目录、只读正文、编辑回传、中文
深色最大字号编辑/移除风险及取消入口。iPhone 另确认长正文可滚动至保留 NAS
原件说明。结果属于真实模拟器系统交互，不提升为实际 NAS、正式签名或真机结论。

实际构建命令如下；R7/R8/R9 使用表中 iPad，均构建成功。R6 使用下方原 iPhone
ID，其余参数相同，也构建成功：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=051F696E-AD5C-47D8-8C7A-5EE61B88D13E' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=051F696E-AD5C-47D8-8C7A-5EE61B88D13E' \
  -parallel-testing-enabled NO -resultBundlePath build/m8ab-fresh-pad-full-unit-files.xcresult \
  -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileFilesProviderUITests
```

全新 iPhone ID 为 `647DEBA5-2BAA-49C6-9510-EC801436DE99`，原 iPhone 为
`8145D5B0-65A7-46E3-A0CF-17850E4EFA3F`。R7 使用同一测试命令，选择
`ProviderWritebackTests`、`ProviderLocalStorageTests`、`MobileVFSCloudAuthorizationTests`、
`MobilePhotoRecognitionTests` 四个单元类，以及上述四个原 UI 方法，结果路径见表。
R8 根项目修正后 iPad 原三项系统 UI 再次通过。后续对抗复核发现两个删除恢复
衔接问题：递归恢复会被自己的原删除记录阻止，已确认删除的旧错误标记会阻止
本地清理。R9 仅允许同一删除越过自身待处理记录，位置移除和其他未完成写仍阻止；
只有已确认原删除可越过旧错误，当前内容变化继续阻止回收。恢复前重新检查本机
编辑。默认删除通知复用原依赖注入，并将仅 iOS 域构造对齐实际相对目录，Mac
分支不变。新增行为测试覆盖文件/目录丢失回执、一次删除、后来编辑保留及最终
清理，R9 全部 62 项通过。iPhone 最终整合也已通过，结果见表。

`swift test --package-path apple --jobs 4` 已通过：3124 项 XCTest、179 项既有条件
跳过、0 失败，另 12 项 Swift Testing 通过。此运行包含用户当前 Mac/共享 Photos
工作区；其后仅 iOS 的域/删除适配与测试变化不影响 Mac 编译分支。
双语完整性、资源引用、参数与硬编码扫描已通过（Apple 7080、Android 2188、Windows 3402）。

旧来源 `c26eb3cc` 的 Apple Build `37713732061` 不含本波 Files 修正。已确认
共享/Mac 与 iPhone 工作区通过；两端 modules、iPad 工作区和 iPad 管理失败。
两端 modules 的其他模块 UI 段各 169 项均通过，但系统 Files 段仍有旧失败；
另有上述单元准备/取消失败。iPad 工作区 166 项 UI 中 2 项启动后 AX 查询超时，
iPad 管理 88 项中日志 AX 查询与套件搜索清空各失败 1 项。诊断脚本定位应用超时，
没有取得挂起调用栈；不把日志中的等待时间当作业务死锁证据。其余作业尚无最终
结果；本机通过、代码同步和完整云端通过必须分别报告。


最终构建与收尾：

```sh
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=647DEBA5-2BAA-49C6-9510-EC801436DE99' \
  -parallel-testing-enabled NO -resultBundlePath build/m8ab-final-phone-unit-files.xcresult \
  -only-testing:DsmMobileTests -only-testing:DsmMobileUITests/MobileFilesProviderUITests \
  -only-testing:DsmMobileUITests/MobilePackageCenterUITests/test套件和来源搜索无匹配后清除可恢复原目录
xcodebuild build -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=NO
```

以上均成功退出 0。`lipo -archs` 确认移动主 App、Share、Files 以及 Mac 主 App、
File Provider 全部包含 arm64/x86_64；移动 Release 符号检查无合成 Files/Share
测试入口。Mac 仅工程回归构建，未安装、启动或发布。iPhone 最后实际 UI 为中文
权限 46.278 秒、编辑回传 69.772 秒、默认只读 59.356 秒及套件搜索清空；四项全通过。
另查看两端套件与来源清空后的四张实际截图，本波共查看十四张成功截图。

本片源码、两端实际系统流程、恢复自动化、共享及 Mac 回归已完成。完整云端仍需
在包含新适配的提交复验，不把旧源码的失败改写为成功。旧轮已有确定失败，且三个
未结束分组不含本次 Files 修正；本机验收后优先同步新代码，允许既定并发规则中止
旧轮剩余分组，保留其已完成结果和未完成边界，避免继续等待旧代码。同步结果另记。

本波两个专用模拟器已删除并独立回读确认；精确清理 40 项临时日志、采样和截图
导出，仅保留表中八份正式结果包。原模拟器、用户 Mac 测试包及其他任务资料保留。
最终严格文档、本地化与差异检查通过。

同步结果：本波 20 个文件已提交为 `4cad5e287d7325ec8ec451d420a5d50e5d605be1`
（修复移动 Files 只读浏览并保留编辑与删除恢复），正常推送 `origin/main`，远端
独立回读一致。推送前再次 fetch，比较为 1/0，无远端新提交；未强推、建分支或 PR。
Mac/共享 Photos/资源、契约与观察改动全部保留；验证历史的独立 Mac 74 行与平台
矩阵的 Mac 两行未暂存。

新 [Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/37738588086)
来源为该提交，已开始执行/排队，尚无平台测试结论。Repository Check `37738588127` 与
Documentation & Quality Preflight `37738588055` 已通过。为释放新代码验证，已明确请求停止旧轮并回读其终态为 `cancelled`；
既有四个失败组与两个成功组保留，三个未结束分组不计通过。此推送后记录暂留本机，
随新云端结论维护；代码同步不等于全量云端通过或发布。

## 2026-10-08 移动服务输入与共享计时回归

M8ac 至 M8ae 基线为 main `9467712c`，当前云端产品来源为 `4cad5e28`；
二者之间没有 Apple 产品源码差异。本波未取消或重跑
[Apple Build 37738588086](https://github.com/yuangy1995/dsm-native-client/actions/runs/37738588086)，
已结束作业的日志及失败附件分别核对，结果如下：

| 作业 | 已结束的真实结果 | 失败范围 |
| --- | --- | --- |
| iPhone 工作区 `113184820588` | 166 UI 全通过 | 无 |
| iPad 工作区 `113184820433` | 165 通过、1 失败 | 照片后台上传用例启动后等待首页失败，尚未进入照片页；AX 和原录像仍为文件页加载，没有可用挂起调用栈 |
| iPad 服务 `113184820468` | 45 通过、1 失败 | 网卡新地址恢复用例清空 MTU 时连续退格后残留 `1`，尚未提交保存 |
| iPhone 管理 `113184820460` | 87 通过、1 失败 | 账号群组开关短按后仍关闭；原五秒开启断言失败，AX 与录像一致 |
| 共享/Mac `113184820565` | 3119 XCTest 中 1 失败、177 既有跳过；12 Swift Testing 通过 | 照片保存提示测试固定等待 3.15 秒后仍有提示，后续 Mac 构建因测试失败未执行 |

上述不代表整轮终态；两端模块、iPhone 服务和 iPad 管理继续运行。
当前没有完整的新云端 Files 结论，不能以本机结果冒充其通过。

M8ac 仅修改 `MobileServiceSettingsUITests` 的已有输入帮助方法。首轮改用全选
快捷键在全新设备未稳定生效：iPhone 四项中一项失败，iPad 八项中六项失败。
未修改的代理快捷键分支也失败；iPhone 已结束后，iPad 仍出现相同问题，因此
没有把失败归因于并行。该方案已撤回，保留正式失败结果包。最终定位输入末尾，
逐次完成退格，再输入新值；保留清空、输入后、收起键盘后的原完整值断言。
长代理地址也进入同一输入分支，不依赖硬件全选键，不增加重试、跳过或期限。

M8ad 仅为共享照片模型增加默认仍等待三秒的 `saveMessageDelay` 初始化参数，
沿用已有延迟注入方式；参数放在原末尾 `slideshowDelay` 之前，保留原尾随闭包
调用语义。原任务取消、弱引用及取消后禁止清提示的检查不变。两个 Mac 测试
复用已有可控时钟，明确等到当前计时注册且旧计时已取消后推进，继续断言提示、
预览和保存内容。没有通过扩大固定等待时间掩盖竞态，也未修改用户的旋转功能。

M8ae 仅修改账号编辑原 UI 用例：选择真实开关子控件，沿用已有模块开关的单次
按住拖动手势；保留原五秒开启断言及后续保存、取消、删除确认和列表结果。
原录像精确取帧后可见短按前后开关均关闭；不能将它解释为已开启但断言误报。

| 本机结果包 | 实际结果 |
| --- | --- |
| `build/m8ac-phone-service-input.xcresult` | 首轮全选方案：3 通过、1 失败，保留 |
| `build/m8ac-pad-service-input.xcresult` | 首轮全选方案：2 通过、6 失败，保留 |
| `build/m8ac-pad-individual-delete.xcresult` | 原 MTU 新地址恢复 93.972 秒、文件服务端口 110.720 秒，2 项全通过 |
| `build/m8ac-phone-final-input.xcresult` | UPS 143.923 秒、代理 101.657 秒、中文大字硬件 90.382 秒，3 项全通过 |
| `build/m8ad-pad-input-workspace.xcresult` | 代理 128.106 秒、中文大字硬件 113.670 秒、静态 IP/VLAN 116.367 秒；原照片后台用例 52.349 秒，4 项全通过 |
| `build/m8ae-phone-group-selection.xcresult` | 原账号编辑/群组/取消/删除完整用例 92.274 秒通过 |
| `build/m8ae-pad-group-selection.xcresult` | 同一完整用例 107.466 秒通过 |

最终通过的以上 UI 均无跳过。iPad 照片后台用例没有源码改动，本机通过仅为
原失败对照，不宣称修复云端首页加载；其余输入/手势修正仍需新来源云端复验。
已复核两端十五张成功关键截图，覆盖数字/地址、中文大字风险、网卡恢复、
后台上传完成、群组选中与账号保存确认；另检查原失败 AX 和录像，不只依赖日志。

实际命令使用下列构建与测试参数。专用 iPhone 为
`DB11DD7B-338E-4910-B049-EE536E34CC47`，专用 iPad 为
`C0650D56-F3DA-4175-A847-157C43D51414`，均为 iOS 26.5；Phone 为 17 Pro，Pad 为 Air 11 M4。

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=DB11DD7B-338E-4910-B049-EE536E34CC47' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=DB11DD7B-338E-4910-B049-EE536E34CC47' \
  -parallel-testing-enabled NO -resultBundlePath build/m8ac-phone-final-input.xcresult \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/testUPS网络连接等待时间校验及保存 \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test硬件中文大字表单风险和取消均可触达 \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=C0650D56-F3DA-4175-A847-157C43D51414' \
  -parallel-testing-enabled NO -resultBundlePath build/m8ad-pad-input-workspace.xcresult \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test代理地址校验保存并关闭代理 \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test硬件中文大字表单风险和取消均可触达 \
  -only-testing:DsmMobileUITests/MobileServiceSettingsUITests/test网卡静态地址和VLAN表单完整保存 \
  -only-testing:DsmMobileUITests/MobileWorkspaceUITests/test照片上传离开前台完成后仍能清理本机记录
```

iPad 两项退格对照使用同一 iPad/测试参数，结果为表中的
`m8ac-pad-individual-delete.xcresult`，选择
`MobileServiceSettingsUITests/test网卡新地址重新登录后明确恢复原记录` 与
`MobileServiceSettingsUITests/test文件服务端口校验确认取消和保存回读`。
两端账号用例同样使用对应设备和表中结果路径，唯一选择为
`-only-testing:DsmMobileUITests/MobileDirectoryUITests/test账号编辑群组选择保存取消及删除确认`。

共享与构建命令：

```sh
swift test --package-path apple --jobs 2 --filter 'SynologyPhotosModelTests/(test照片保存成功提示自动消失且不关闭预览|test保存失败提示自动消失且从新提示出现时重新计时|test幻灯片自动推进暂停取消计时并恢复且关闭不再读取)'
swift test --package-path apple --jobs 3
xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 3 CODE_SIGNING_ALLOWED=NO
xcodebuild build -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/Apps/DsmMobile/build/m8ad-release -jobs 3 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

三个聚焦测试全部通过；最终当前工作区完整回归为 3124 项 XCTest、179 项既有
条件跳过、0 失败，另 12 项 Swift Testing 通过。该本机工作区包含用户未提交的
Mac/Photos 改动，与云端原来源 3119 项分别记录。Mac 与移动 Release 构建均退出 0，
`lipo -archs` 确认 Mac 主 App/扩展、移动主 App/分享/Files 五个组件都有 arm64/x86_64；
移动 Release 的 `nm -gU` 未检出两个 Files/分享合成入口符号。未安装、启动或发布 Mac 包。

独立集成复核检查了输入断言/风险取消未削弱、手势只执行一次、计时取消/弱引用、
初始化参数默认值及原尾随闭包语义；未改 NAS 请求、权限、账号/存储身份、正式签名、
依赖或其他平台。真实 NAS、正式设备和系统生命周期仍按原 `PENDING_USER_VALIDATION`
账本验收。本波完整目标仍未完成，继续处理同轮其余云端结果。

本波收尾：严格文档、本地化完整性/参数/引用/硬编码扫描及差异检查通过；资源数
为 Apple 7080、Android 2188、Windows 3402。两台专用模拟器已删除并重新读取
清单确认；精确清理 43 项本波日志、云端下载副本、截图导出及独立 Release 缓存，
保留表中的七份正式结果包。原设备、既有结果、用户 Mac 测试包和用户未提交
改动保留。上述独立收尾时源码与证据尚未提交，随后与 M8af 一并整合，具体同步另记。

## 2026-10-08 M8af Files 分步导航与两端复验

来源 `4cad5e28` 的 iPhone 模块作业 `113184820324` 已结束失败。系统结果包
10 项中 9 通过、1 失败；正式默认只读 92.355 秒、中文权限 82.233 秒通过。
唯一失败为可编辑用例的系统导航，尚未进入 NAS 目录。主结果为 2030 项中
2026 通过、4 既有跳过、0 失败，包含 1861 项移动单元和 169 项其他模块 UI；
不能用主结果成功覆盖先行系统段失败。已读取两个正式结果包的 summary。

原日志显示，导航等待已完成一次，随后点击 Browse 标签；下一步出现 On My iPhone
和返回 Browse 的按钮时，三个步骤共用的八秒截止期限已经耗尽。AX 与精确取帧
一致；同一用例先前在系统 Files 中已成功显示提供器的 Shared 目录。这不是只读
元数据重新失败，也没有足够依据修改正式提供器。本波唯一源码变化为原
`MobileFilesProviderUITests.openLocation`：使用系统 `waitForExistence`，每个实际
导航步骤各为八秒、仍最多三步。总等待不再跨不同页面共用；位置启用、目录、
下载正文、真实原位编辑回传和权限确认断言保持不变，没有业务写重试。

| 设备 / 结果包 | 中文权限 | 可编辑系统流程 | 默认只读 | 汇总 |
| --- | --- | --- | --- | --- |
| iPhone 17 Pro / `build/m8af-phone-files.xcresult` | 50.127 秒 | 71.675 秒 | 56.027 秒 | 3 通过、0 失败/跳过 |
| iPad Air 11 M4 / `build/m8af-pad-files.xcresult` | 54.876 秒 | 67.202 秒 | 57.800 秒 | 3 通过、0 失败/跳过 |

两端使用本波新建的 iOS 26.5 模拟器。实际命令如下：

```sh
xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj \
  -scheme DsmMobile -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=B3DAE355-801E-4942-B401-128FAA5BBDD1' \
  -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=B3DAE355-801E-4942-B401-128FAA5BBDD1' \
  -parallel-testing-enabled NO -resultBundlePath build/m8af-phone-files.xcresult \
  -only-testing:DsmMobileUITests/MobileFilesProviderUITests
xcodebuild test-without-building \
  -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun \
  -destination 'platform=iOS Simulator,id=47AFF234-02AF-4230-BD36-512C673DACEC' \
  -parallel-testing-enabled NO -resultBundlePath build/m8af-pad-files.xcresult \
  -only-testing:DsmMobileUITests/MobileFilesProviderUITests
```

三条命令均退出 0。已逐张查看八张成功关键截图（两端各四张：实际目录、只读
正文、编辑回传、中文深色最大字号移除说明末尾及取消）和两张原云端画面。
独立复核确认只改测试等待边界，没有改变提供器、共享代码、权限或 NAS 接口；
本片不重复上一片已经完成且源码未变的共享/Mac/Release 门禁。

整合决定：当前轮次已有五组失败，四项可定位的问题已经修正并完成本机复验；
另外的 iPad 首页加载原用例本机通过，仍无产品根因结论。优先同步 M8ac 至 M8af
并验证新来源，允许既定 main 并发规则中止旧轮其余三组；旧一组通过与五组失败
保留，中止分组不计通过。新来源的完整云端结果另记，M6–M8 整体未完成。

M8af 收尾：两端专用模拟器已删除并重新读取清单确认；精确清理 11 项本片日志、
云端下载副本和截图导出，保留两份正式结果包。严格文档、本地化与差异检查通过。
