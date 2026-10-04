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
