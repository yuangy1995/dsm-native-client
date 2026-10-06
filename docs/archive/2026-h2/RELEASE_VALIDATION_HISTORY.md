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
