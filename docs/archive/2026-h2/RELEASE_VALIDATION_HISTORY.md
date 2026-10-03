<!-- doc-role: archive -->
<!-- last-reviewed: 2026-10-04 -->

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
