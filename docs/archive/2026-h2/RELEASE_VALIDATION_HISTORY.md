<!-- doc-role: archive -->
<!-- last-reviewed: 2026-10-02 -->

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

## macOS 1.0.13 发布准备（2026-10-02）

用户明确授权提交当前功能与文档整理，并发布 macOS 新版用于升级体验。目标为 `macos/v1.0.13`、主 App/扩展 1.0.13 (23)，专用分支 `codex/macos-1.0.13-release`；保持既有正式签名、应用身份、最低系统和更新密钥。

只读查询确认 1.0.12 的[发布运行](https://github.com/yuangy1995/dsm-native-client/actions/runs/36896115537)失败：Apple 公证凭据检查返回 403，原因是账号缺少生效协议；当时未创建 1.0.12 Release。1.0.13 更新说明同时覆盖此前未公开的 Photos 增量与本轮 File Station、Office、远程连接及界面修复。协议须由账号持有人处理，不能跳过签名、公证或更新验收门禁。

最终提交、云端检查与正式发布结果以完成后的记录为准；当前准备状态不表示已发布。真实 NAS、外部编辑器、正式沙盒恢复和完整辅助功能继续按对应计划由用户验收。
