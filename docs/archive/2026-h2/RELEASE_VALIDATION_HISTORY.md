<!-- doc-role: archive -->
<!-- last-reviewed: 2026-08-20 -->

# 发布与手工验收历史（2026-H2）

本文件收敛无法由 CI 重建的脱敏手工验收结论与待验收边界。它不是发布批准，不能用
源码阅读、模拟器或自动化构建替代正式签名包、真实设备或真实 NAS 的结果。

当前发布条件与执行步骤仍以以下保留文档为准：

- [macOS 桌面云盘发布与升级验收](../../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [macOS 桌面云盘正式签名验收执行矩阵](../../development/MACOS_DESKTOP_CLOUD_DRIVE_SIGNED_ACCEPTANCE_MATRIX_ZH.md)
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
