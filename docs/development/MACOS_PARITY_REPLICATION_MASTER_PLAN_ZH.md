# macOS 基线下的 Windows 对齐与 Apple 移动端精选交付总控计划

- 状态：持续实施中；当前以分波账本、源码和可复现验证结果为准
- 编制日期：2026-08-03
- 源码参照：`01cd28001c0fade20462a62b9c311e2f50ec5bf1`

## 1. 决策摘要

本次采用三份计划文档：

1. 本文负责范围、功能对齐账本、依赖顺序、跨端共同出口和 Codex 多代理编排。
2. [Windows 专项计划](WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)负责 WinUI 3、Windows 系统集成和 x64/arm64 验收。
3. [iPhone/iPad 专项计划](APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)负责 SwiftUI 通用 App，并在同一文档内分别设置 iPhone 与 iPad 验收轨。

iPhone 与 iPad 不拆成两份计划。当前仓库已经使用同一个 `DsmMobile` Target、Bundle ID、共享 Package、Keychain 和本地化资源；拆成两份会让业务语义、危险写保护和进度状态发生漂移。两种设备只在信息架构、窗口宽度、输入方式、并列详情和系统集成上分轨。

## 2. 目标与完成定义

目标不是复制 macOS 截图。Windows 继续获得 macOS 已承诺范围内相同的用户结果、权限边界、失败语义和恢复路径；iPhone/iPad 则以 macOS 作为业务与安全语义基线，只交付适合移动场景的明确范围。共享 Target 或共享 Repository 不代表两个移动设备必须承接全部桌面能力。

Windows 的功能只有同时满足以下六项才能标记为“平台对齐”；Apple 移动端只对专项范围矩阵中标为“核心”或“受限”的明确子集使用相同门槛，并称为“移动范围交付完成”，不能称为完整 macOS 对齐：

1. **业务等价**：读写范围、排序分页、冲突处理、取消和最终状态与 macOS 基线一致。
2. **安全等价**：能力与权限检查、危险确认、父子目标防重复、提交后不自动重放及写后复查均未弱化。
3. **平台等价**：使用 WinUI/Fluent 或 SwiftUI/iOS/iPadOS 原生导航、选择器、分享、通知和辅助功能，而非移植桌面手势。
4. **状态完整**：对 macOS 基线、已记录契约、可复现故障或明确安全/数据完整性风险所要求的加载、空内容、筛选后为空、错误、正常内容，以及离线、会话过期、功能不可用和部分成功状态提供恢复动作；没有证据的情形不得为了清单完整性新增猜测性校验、平行降级、吞错或不可达分支。
5. **质量完整**：英语与简体中文、浅色/深色、高对比度或系统对比度、键盘/触控、屏幕阅读器、动态文字或缩放、减少动态效果均有证据。
6. **验证完整**：至少达到 `IMPLEMENTED`、`UNIT_TESTED` 和目标工程的 `BUILD_VERIFIED`；依赖签名、真实设备或 DSM 的能力继续明确标记为 `SIGNING_REQUIRED` 或“未验证”，不得提前称为完成。移动端“后续”与“当前不做”不是验证缺口，不进入当前完成计算。

验证等级以[功能实现与验证等级](../quality/VERIFICATION_LEVELS_ZH.md)为准，实时测试数量只写入[当前开发进度](../progress/STATUS.md)，不在本计划复制容易失效的数字。

### 2.1 功能闭环与最终对齐分层

实施按“用户可完成的主流程 → 必要错误处理与聚焦自动化 → 当前环境可执行的构建 → 后续用户真机/真实环境验证”推进。源码、合成 fixture、单元/集成测试和可用模拟器或 CI 构建达到切片出口后，即可继续不依赖外部验证的下一功能；不得为了罕见假设先扩张抽象、校验或 fallback，也不得把体验微调和极端场景放在主流程之前。

真机、正式签名、entitlement、系统注册、特定硬件或真实 NAS 才能取得的证据写为 `PENDING_USER_VALIDATION`。这是账本待办标签，不是新的验证等级，也不替代 `SIGNING_REQUIRED`、`BUILD_VERIFIED` 或 `DEVICE_VERIFIED`。待办必须写明条件、用户操作步骤、预期结果、失败时需回收的日志类别和影响范围；缺少这些条件不能称“平台对齐”或“发布就绪”，但也不能把无依赖切片标为 `BLOCKED`。

后置验证不得削弱凭据、证书、危险写和数据完整性门禁。若某项能力未验证就可能造成泄密、越权、数据损坏或不可逆副作用，只让该入口保持关闭、只读或受能力开关保护，直至用户回传结果；其余功能继续开发。

## 3. 范围边界

### 3.1 本计划包含

- 以 macOS 已有源码入口为 Windows 完整对齐基线，并作为 Apple 移动端产品取舍、业务语义与安全门禁的证据来源。
- Windows 对应的资源管理器 Cloud Files、通知区域常驻、窗口与键鼠体验。
- iPhone/iPad 当前范围中的登录、Files、Photos、Chat、活动、Download Station 受限任务、NAS 健康、Container/VMM 只读摘要、设置、系统分享与 iPad 生产力体验。
- 为 Windows 对齐或 Apple 移动范围交付所必需的目标平台领域模型、Repository、UI、合成 fixture、自动化测试和文档更新。

### 3.2 本计划明确排除

- 修改 `apple/Apps/DsmMac/**`。发现 macOS 缺陷时只记录证据并请求新的范围授权。
- 修改 Android 源码、资源或测试。若公共契约变化，只记录 Android 影响并遵循五端评估规则。
- 把 macOS 尚未实现的候选能力顺带加入目标端，例如完整 RSS 编辑、Container Compose 编辑/终端/日志流、VMM 迁移/克隆/高级磁盘、Chat 加密和其他尚未进入 macOS 的套件。
- 把完整桌面运维、跨 NAS/大批量文件工作流、复杂归档、VMM 控制台、Container/VMM 高风险写、NAS 配置或电源写、全 NAS 存储分析、File Provider、多窗口和自动照片备份自动视为 Apple 移动端当前承诺；这些能力按 Apple 专项计划分别标为“后续”或“当前不做”。
- 为了“看起来一致”自行猜测内部 API、改变安全策略或绕过目标平台限制。
- 未经批准增加第三方依赖、提高最低系统版本、改变 Bundle ID/MSIX Identity、签名、entitlement、包格式、持久化结构或公开契约。
- 本计划本身不授权在真实 NAS 上执行创建、修改、删除、断网、重启、关机或权限变更。

### 3.3 macOS 只读与共享 Package 边界

`apple/Apps/DsmMac/**` 在实施期间保持只读。`apple/Packages/**` 可在以下条件全部满足时做向后兼容增量修改：

- 目标能力已有 macOS 行为和 Repository 契约证据；
- 不要求 macOS App 改用新的 UI 或状态模型；
- 新接口不会改变既有请求、持久化或错误语义；
- Apple 共享测试和 macOS 无签名构建继续通过；
- 若需要把现有目录正式加入 Swift Package target，先按工具链变更规则取得用户同意。

## 4. 事实来源与基线冻结

发生冲突时按以下优先级重新核查，不采信模型记忆或旧总结：

1. 根目录 `AGENTS.md`、适用的契约、ADR 和安全基线；
2. macOS 源码与同一版本测试；
3. `docs/api/discovery/` 中对应环境和证据等级；
4. [平台功能矩阵](../progress/PLATFORM_MATRIX.md)与专项计划；
5. [当前开发进度](../progress/STATUS.md)中的实时验证结论。

平台矩阵和 `STATUS.md` 只负责汇总进度，不能自行提升证据等级。没有可复现命令输出，或没有 `contracts/private-api/compatibility.json` 与对应发现记录支持时，任何切片都不得仅凭进度文档标成“已验证”。

本文编制时 Apple 与 Windows 源码没有未提交差异，但契约、专项计划和 Android 存在用户进行中的改动。正式实施每个波次前必须重新执行：

```bash
git status --short --branch
git diff -- apple windows contracts docs/development AGENTS.md
git log -1 --oneline -- apple/Apps/DsmMac apple/Packages
```

若 macOS 在计划编制后新增功能，主 agent 先把新增行为加入对齐账本。Windows 再决定插入当前波次还是后续增量波次；Apple 移动端默认标为“后续”，只有完成 iPhone/iPad 场景、交互与替代路径评审后才能升为“核心”或“受限”。不得静默改变正在验收的范围。

## 5. 对齐状态与账本格式

每个平台、每个功能 ID 使用以下状态之一：

这些是执行流状态，不替代 `VERIFICATION_LEVELS_ZH.md` 的证据等级；账本必须同时记录两者。尤其 `AUTO_VERIFIED` 只是阶段出口，仍需分别留下 `UNIT_TESTED`、`BUILD_VERIFIED` 等可复现证据。

| 状态 | 含义 |
| --- | --- |
| `NOT_STARTED` | 已有基线和目标，但未开始实现 |
| `IN_PROGRESS` | 已分配明确 owner，仍有开发或测试工作 |
| `CODE_COMPLETE` | 源码路径完整，但自动化或目标构建尚未全部通过 |
| `AUTO_VERIFIED` | 单元/集成/UI 自动化及目标工程构建通过 |
| `DEVICE_VERIFIED` | 目标设备和脱敏真实环境已验证 |
| `BLOCKED` | 当前切片在安全范围内已无可继续的实现、测试或替代工作，且具体外部条件或用户决策直接阻塞；仅缺真机、签名或真实 NAS 不足以阻塞无依赖切片 |
| `NOT_APPLICABLE` | 平台不存在同类用户目标，且主 agent 已记录理由与替代路径 |

Apple 移动端另使用以下**产品范围标签**，它们不替代上述执行状态，也不是验证等级：

| 移动范围 | 含义 |
| --- | --- |
| `MOBILE_CORE`（核心） | 当前交付必须完成的移动用户结果 |
| `MOBILE_LIMITED`（受限） | 当前只交付明确列出的移动子集；未列出的桌面动作不是缺口 |
| `MOBILE_FUTURE`（后续） | 有移动价值但不进入当前 DAG，需单独产品/权限/契约决策后再开启 |
| `MOBILE_EXCLUDED`（当前不做） | 当前明确排除，必须记录不适合原因和 Mac App、DSM Web 或系统 App 替代路径 |

只有在移动端不存在同类用户目标时才使用 `NOT_APPLICABLE`。有目标但主动延后或取舍时使用 `MOBILE_FUTURE` / `MOBILE_EXCLUDED`；`PENDING_USER_VALIDATION` 只属于已经进入 `MOBILE_CORE` 或 `MOBILE_LIMITED` 的实现，不能用来掩盖产品范围未决。

每个切片必须记录：

```text
功能 ID：
macOS 证据路径与验证等级：
目标平台用户结果：
Apple 移动范围：MOBILE_CORE / MOBILE_LIMITED / MOBILE_FUTURE / MOBILE_EXCLUDED；iPhone 与 iPad 分别记录
原生交互转换：
明确排除与替代路径：
公开/内部 API 与能力开关：
危险等级与重复提交策略：
owner 与允许修改文件：
自动化命令和结果：
功能闭环边界与当前证据：
外部验证待办：无 / PENDING_USER_VALIDATION；条件、步骤、预期、失败证据与影响范围
若包含真实或危险写：用户明确授权的专用测试环境、允许操作范围、确认方式与写后复查要求
状态与下一出口：
```

## 6. macOS 功能基线与跨端目标账本

以下是实施入口，不把“源码存在”表述为真实 DSM 已验证。详细验证边界继续以 `STATUS.md` 和专项计划为准。ID 后的证据标签含义如下，本次规划没有重新执行其既有测试：

- `A`：仓库中存在源码和对应自动化证据，只证明实现与测试路径存在。
- `B`：存在源码，但系统集成、专门自动化或目标环境证据仍不足。
- `C`：依赖内部 API，当前兼容结论仍是 degraded 或写操作未行为验证；未知环境默认关闭。
- `D`：macOS 明确未实现或禁用，不得算入本轮对齐完成；表格只在说明边界时提及。

登录安全还必须满足同一条不可弱化的链路：先使用系统信任；只有结构与有效期检查合格的叶证书才允许用户固定；QuickConnect relay 必须通过系统信任；路由发现阶段不得发送登录凭据；证书变化时同时展示旧、新指纹并要求重新确认。证据位于 `apple/Packages/DsmNetwork/Sources/DsmCertificateTrust.swift`、`apple/Packages/DsmNetwork/Sources/DsmQuickConnectResolver.swift` 及对应测试。

以下内部能力的当前验证边界必须直接进入各平台账本，不能因为 macOS 已有界面而省略：

- `download-station2-fallback`：`observed:degraded`；任务文件上传与设置写尚无行为验证。
- `file-station-remote-mount`：`observed:candidate`；内部挂载创建/断开尚无专用目标写行为验收，未知环境关闭。
- `container-manager-internal`：全部为内部 API，`observed:degraded`；镜像拉取请求曾在发送前终止，其他写操作未验证。
- `vmm-internal`：`read-verified:degraded`；创建、修改、网络写和删除未形成行为验证结论。
- `chat-internal` 与 `chat-realtime`：`observed:degraded`；各项读写按端点分别 gate，完整跨版本、睡眠唤醒和中继矩阵未验证。
- NAS 管理相关内部端点总体仍为 `observed:degraded`；外接存储、ZRAM、电源计划、进程、当前账号共享访问保持只读，系统升级安装、套件安装/升级和管理员 ACL 矩阵保持关闭。SMART、账号、网络、DDNS、电源等危险写必须逐端点取得权限、重复提交与写后复查证据。
- `photos-internal-candidate`：`static:disabled`；人物、地点、标签和真正相册实体不在本轮范围。

上述端点 ID 与证据等级以 `contracts/private-api/compatibility.json`、`docs/api/discovery/endpoints/INDEX.md` 和稳定端点记录为准。表中只写文件名时，App 类型位于 `apple/Apps/DsmMac/Sources/`，共享类型位于 `apple/Packages/*/Sources/`；请求证据位于 `contracts/request-fixtures/` 及 `apple/Packages/DsmNetwork/Tests/RequestFixtureContractTests.swift`，不得把类型名或“有 fixture”本身当作环境验证。

Apple 列只用于建立候选映射，是否进入当前开发以 [iPhone/iPad 专项范围矩阵](APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#33-iphone--ipad-产品范围矩阵)为准。现有入口、共享契约或“可转换”都不能自动升级为移动承诺。

下表是产品能力映射，不表示当前完成度。第 0 波实际源码、验证等级、已收窄范围和下一波缺口以 [第 0 波跨端对齐账本](CROSS_PLATFORM_PARITY_WAVE_0_LEDGER_ZH.md) 为准；Apple 长期“核心/受限”项若尚无对应实现切片，不得从本表推断为已实现或仅待真机验收。

| ID | macOS 用户能力基线 | Windows 等价目标 | Apple 移动候选映射（范围以专项矩阵为准） | 主要证据 |
| --- | --- | --- | --- | --- |
| FND-01 · A | 多 NAS 资料、新建/删除/重排、OTP、可选保存密码、自动登录、会话恢复与退出 | Credential Locker、资料选择与独立“切换 NAS/退出登录” | **核心**：Keychain、资料选择器、独立切换与退出 | `LoginViewModel.swift`、`DsmAuthenticationService.swift` |
| FND-02 · A/B | HTTPS 地址、可选端口、QuickConnect 直连/中继、连接方式提示 | 保持身份核对、官方中继域限制和路由提示 | **核心**：共享网络契约；网络变化后安全恢复 | `DsmQuickConnectResolver.swift`、`DsmCertificateTrust.swift` |
| FND-03 · A | 自签名证书指纹复核、按 NAS 绑定、证书变化阻断 | Windows 原生证书对话与 Credential Locker 分离 | **核心**：触控友好安全核对；技术指纹置于次级详情 | `LoginView.swift`、安全基线 |
| FND-04 · A/C | 模块能力发现、不可用提示、内部 API 按环境关闭 | 页面说明原因和可恢复动作，不静默隐藏 | **核心**：只对当前移动范围保持可发现并解释不可用原因 | `ApiCapability.swift`、私有 API 兼容矩阵 |
| NAV-01 · A | 侧栏分组、详情区、模块返回后保持目录/筛选/历史 | `NavigationView` + 模块专用页 + BackStack；窗口缩放不丢状态 | **核心**：iPhone 五入口 Tab/Stack；iPad 自适应 SplitView；单窗口状态恢复 | `WorkspaceSection`、`WorkspaceNavigationTests.swift` |
| FILE-01 · A | 共享目录、文件夹分页、列表/图标、排序/分组、面包屑、搜索 | 列表/网格切换、BreadcrumbBar、键盘搜索、多选 | **核心**：层级浏览、分页、排序/筛选、搜索与状态恢复 | `WorkspaceView.swift`、`DsmFileRepository.swift` |
| FILE-02 · A/C | 收藏、最近位置、回收站、远程位置、分享链接入口；公开 VirtualFolder 只读浏览与内部挂载管理分开 | 左侧位置集合与上下文菜单；内部创建/修改/断开在未知环境关闭 | **受限**：收藏/最近/回收站和分享入口；远程挂载管理当前不做 | `WorkspaceModel.swift`、`file-station-remote-mount` |
| FILE-03 · A | 新建文件夹/空文件、重命名、详情、文件夹统计和 MD5 | 命令栏、F2、属性面板、触控菜单 | **受限**：新建文件夹、重命名和详情；空文件、递归统计与 MD5 当前不做 | `WorkspaceModel.swift`、`FilePropertiesView` |
| FILE-04 · A/B | 系统选择器上传、覆盖确认、文件/文件夹/批量下载、取消，以及有恢复元数据时的继续/重试；上传重启发送，已知大小普通下载才用严格 Range 分片继续 | FileOpenPicker/FolderPicker/FileSavePicker；Files 已接 1～20 个文件及一个最多 20 文件、20 目录、8 层的小文件夹有界前台上传，并接 1～20 个普通文件的显式多选、目标文件夹无覆盖预检与严格串行事务下载；单文件夹可用公开 Download v2 生成 ZIP 流，经事务暂存和 ZIP 中央目录结构校验后保存；后台传输和系统通知仍后置 | **核心**：用户选择的单文件导入、导出、分享、取消；文件夹/大批量与常驻后台当前不做 | `WorkspaceModel.swift`、`DsmFileRepository.swift` |
| FILE-05 · A/B | 同 NAS 复制/移动、跨 NAS 有界流、粘贴冲突、拖拽移动和限时撤销 | 剪贴板、拖放、键盘快捷键、Undo InfoBar；Files 已接当前目录最多 20 个文件/文件夹的同 NAS 单目标严格串行复制/移动，保持无覆盖和逐项结果 | **受限**：有上限的同 NAS 复制/移动；跨 NAS 与大批量当前不做 | `AppModel`、`WorkspaceModel.swift` |
| FILE-06 · A | ZIP/7z 压缩、常见格式解压、密码、编码和覆盖确认 | 分步 ContentDialog/任务中心 | **当前不做**：复杂归档交给 Mac App 或 DSM Web | `WorkspaceModel.swift`、请求 fixture |
| FILE-07 · A | 创建/复制/列出/删除（撤销）分享链接，支持密码和有效期 | 系统剪贴板/分享、管理表格 | **核心/受限**：创建、复制和系统分享为核心；管理动作按已验证端点受限开放 | `WorkspaceModel.swift` |
| FILE-08 · A/B | 缩略图、图片/PDF/文本/音频/视频预览、图片切换缩放、媒体 Range、文本编辑与格式整理 | 原生媒体/文档控件、可调整预览区或独立窗口 | **核心**：系统原生预览与分享；文本编辑/格式整理当前不做 | `FilePreviewView.swift` |
| FILE-09 · A/C | 安全删除、回收站发现与受兼容开关保护的恢复 | 权限摘要、强化确认、结果分级与刷新 | **受限**：移入回收站和恢复；永久删除当前不做 | `WorkspaceModel.swift`、`MutationResult.swift` |
| ACT-01 · B | App 传输与 NAS 后台任务分源、速度/剩余时间、筛选、分页、通知 | 活动中心、Toast/系统通知、托盘摘要 | **核心**：前台传输与 NAS 任务分源状态；系统后台与通知仅在后续获批时增强 | `ActivityTask.swift`、`WorkspaceView.swift` |
| PHOTO-01 · A/D | 基于公开 File Station 扫描 `/home/Photos` 与 `/photo` 的个人/共享空间、文件夹、时间线、文件夹式相册、分页、搜索筛选、年/月定位；人物/地点/标签/真正相册实体未实现 | 自适应照片网格和时间线 | **核心**：内容优先网格、文件夹和用户主动时间线；不宣传智能相册 | `PhotoLibraryModel.swift`、`PhotoLibraryView.swift`、`photos-internal-candidate` |
| PHOTO-02 · A/B | 缩略图缓存、完整查看、HEIC/MOV/Live Photo 兜底、EXIF 详情 | 查看器、键盘前后切换、元数据面板 | **核心**：沉浸查看、分享和基础元数据；iPad Inspector；受控内存上限 | `PhotoLibraryModel.swift`、`FilePreviewView.swift` |
| PHOTO-03 · A/C | 上传、导出、删除、分享、移动和照片页回收站恢复 | 多选命令栏、拖放导入导出 | **受限**：主动导入/导出/分享和有上限的 NAS 内移动/回收站；不删除系统图库 | `PhotoLibraryModel.swift` |
| CHAT-01 · C | 会话、用户、首次单聊、私人群聊、成员与未读/置顶/本地已读 | 会话-消息-详情布局、通知入口 | **核心**：会话、成员、可解释未读；iPhone Stack、iPad 双栏 | `ChatWorkspaceModel.swift`、`DsmChatRepository.swift` |
| CHAT-02 · C | 消息分页、草稿、发送/失败重试、实时 Socket.IO 与轮询降级 | 键盘发送、连接状态与可恢复错误 | **核心**：文字/Emoji、草稿、分页、失败恢复与前台实时 | `ChatWorkspaceModel.swift`、`DsmChatRealtimeClient.swift` |
| CHAT-03 · C | 单附件上传/保存、缩略图、图片预览；提醒、定时消息与投票第一阶段 | 文件选择器、详情窗格、任务反馈 | **受限**：单附件选择、上传/保存与预览；提醒、定时和投票不作为当前完成条件 | `ChatWorkspaceView.swift`、Chat 请求 fixture |
| CHAT-04 · C | 删除本人消息、关闭会话、消息转发、服务端消息置顶/取消置顶；语音发送和完整加密实现不存在 | 可发现的消息/会话菜单与结果回读 | **受限**：少量常用消息动作按端点开放；高级管理、语音和加密当前不做 | `ChatWorkspaceModel.swift`、`DsmChatRepository.swift` |
| DS-01 · A/C | 下载任务列表、详情、进度/速度、网址或任务文件创建、目标目录 | 专用任务页、筛选与多选命令 | **受限**：列表/详情和单任务创建；不承接复杂批量任务 | `ServiceManagementModel.swift`、`ServiceManagementView.swift` |
| DS-02 · A/C | 暂停/继续/开始/删除，删除数据分支；官方基础设置 | 批量命令、设置页、结果回读 | **受限**：单任务暂停/继续；删除数据、批量与高级设置当前不做 | 同上 |
| CM-01 · C | 概览、容器、映像、网络、项目、事件 | 模块专用分页/详情、键盘与多选 | **受限**：只读健康与资源摘要；iPad 列表-详情，iPhone 分层导航 | `ContainerManagerPane`、服务管理 Repository |
| CM-02 · C | 容器生命周期/删除、映像删除、网络创建/删除、Registry 搜索/标签/拉取 | 分步对话、后台任务状态 | **当前不做**：生命周期、删除、拉取和网络写交给 Mac App 或 DSM Web | `ServiceManagementModel.swift` |
| VM-01 · C | 虚拟机、主机、存储、网络、映像、保护与事件读取 | 数据视图、详情与多选操作 | **受限**：只读健康与资源摘要；iPad 多栏，iPhone 摘要优先 | `VirtualMachineManagerPane` |
| VM-02 · C | 基础创建/修改、电源/删除、网络修改/删除、映像删除、独立远程控制台 | 分步向导和可调整控制台窗口 | **当前不做**：创建/编辑/删除/网络写/电源与控制台交给 Mac App 或 DSM Web | `ServiceManagementModel.swift`、`ServiceManagementView.swift` |
| NAS-01 · A/C | 系统概况、性能趋势、更新检查/发布说明、存储/硬盘/外接存储/ZRAM | Dashboard + 原生图表/数据表 | **核心**：系统、连接、容量与健康只读摘要；更新仅查看说明 | `NasAdministrationModel.swift` |
| NAS-02 · A/C | 文件服务、终端、代理、接口、DDNS、区域时间、QuickConnect | 分类设置页、表单验证与写后回读 | **受限**：只读连接/配置摘要；所有设置写当前不做 | `NasAdministrationView.swift`、NAS Repository |
| NAS-03 · A/C | 硬件/休眠、UPS、防火墙基础控制、电源操作 | 危险操作与普通设置空间分离 | **当前不做**：硬件、防火墙与电源写交给 Mac App 或 DSM Web | 同上、私有 API 记录 |
| NAS-04 · A/C | 套件、任务与运行记录、账号/群组、当前账号共享访问、进程、日志和连接 | 模块化表格、分页、筛选和详情 | **受限**：套件/任务/日志/连接的隐私白名单只读摘要；账号与 ACL 写当前不做 | `NasSettingsPage`、NAS Repository |
| NAS-05 · A/B | 容量健康与共享/类型/所有者/大文件/时间/重复内容的统一存储分析 | 可取消分析、表格/图表与导出 | **当前不做**：长时全 NAS 分析交给 Mac App | `StorageAnalysisEngine` |
| SET-01 · A/B | 模块开关、语言、传输分块、本地占用与可再生缓存清理、诊断边界 | 设置页、系统主题、高对比与缓存管理 | **核心**：Settings/Profile、语言、主题、可再生缓存与隐私诊断边界 | `SettingsView`、本地化契约 |
| SYS-01 · A/B | Finder 只读云盘、按需读取、离线保留、缓存与后台驻留；`createItem`、`modifyItem`、`deleteItem` 返回 `featureUnsupported`，`enumerateChanges` 不承诺远端增量 | Cloud Files/资源管理器等价，延续当前实现并完成实机出口 | **后续**：当前使用 App 内浏览、Document Picker/Exporter 与分享；File Provider 需独立产品、契约、签名决策 | `apple/Apps/DsmMac/FileProviderExtension/` |

## 7. UI/UX 共同设计系统

`ui-ux-pro-max` 检索结果只作为开发期输入。其 Web 字体、Bento 营销布局、GSAP 和夸张标题建议与本项目原生技术栈冲突，明确不采用；保留以下适合工具型 NAS 客户端的原则：

- 系统字体、系统图标和语义颜色优先，不引入 Web 字体或运行时设计依赖。
- Windows 采用 Fluent/WinUI 主题资源；Apple 采用 SwiftUI 系统材质与 SF Symbols。品牌色只用于主操作、选择和状态强调。
- 页面信息层级清楚，桌面可高密度但不可拥挤；移动端内容优先，次级技术信息渐进披露。
- 普通文本对比度至少 4.5:1；颜色之外同时使用文字、图标或形状表达状态。
- Apple 触控目标至少 44×44pt；Windows 同一界面同时支持鼠标、键盘、触控与可见焦点。
- 微交互通常 150–300ms，复杂转场不超过 400ms；动画表达层级或因果关系、可中断、不阻断输入，并服从系统“减少动态效果/关闭动画”。
- 超过约 300ms 的操作提供即时反馈，超过约 1 秒的内容加载使用稳定占位或分区进度，避免界面跳动。
- 所有新页面逐一验收加载、空内容、筛选空、错误和正常内容五态；错误必须说明发生了什么和下一步怎么做。

## 8. 总体架构与依赖顺序

```text
P0 基线冻结与功能账本
  └─ P1 请求 fixture、结果模型、领域接口与安全门
       ├─ Windows：Shell → Files/Photos/Chat/Services/NAS → Cloud Files/系统集成
       │                                      └─ Windows 完整语义对齐验收
       └─ Apple：Session/Shell → 当前 MOBILE_CORE + MOBILE_LIMITED
                               ├─ iPhone 随身伴侣出口
                               └─ iPad 增强型移动工作台出口
                                      └─ Apple 当前范围自动化收口

Apple MOBILE_FUTURE / MOBILE_EXCLUDED
  └─ 不进入当前 DAG；只有独立决策后才能建立新切片

两轨已交付能力的 PENDING_USER_VALIDATION
  └─ 后续用户真机 / 真实环境 / 发布验收
```

依赖规则：

- P1 未稳定前不得并行复制写操作；UI agent 只能使用已验收的 mock/接口。
- Files/传输先于 Photos、Chat 附件和 Download 任务文件，因为后三者复用二进制、选择器、缓存和任务语义。
- 系统集成单独收口，不能和普通 UI 切片一起改 entitlement、工程文件或安装生命周期。
- Windows 与 Apple 轨可以并行，但 `contracts/**`、公共文档和本地化完整性检查由单一集成 owner 处理。
- Apple 当前出口只依赖专项矩阵中的 `MOBILE_CORE` 与明确列出的 `MOBILE_LIMITED` 子集；不能因共享 Repository 已存在而把 `MOBILE_FUTURE` / `MOBILE_EXCLUDED` 接回主 DAG。
- 自动照片备份、多窗口、File Provider、复杂后台常驻能力属于移动后续候选；无论是否实现都不影响 Apple 当前范围交付。
- 真机、签名、系统注册或真实 NAS 验证不是当前源码切片的全局前置条件。只有确定的代码/契约依赖可以阻塞下游实现；外部验证缺口进入后测账本，若涉及高风险能力则只阻塞该入口启用及最终发布声明。

## 9. Codex 多代理执行协议

### 9.1 主 agent 职责

主 agent 负责：

- 阅读规则、确认基线和维护本账本；
- 把工作拆成互不重叠的文件所有权；
- 先验收共享接口，再放行上层实现；
- 自己检查 `git diff`、请求 fixture、安全结果模型和所有测试输出；
- 让未参与实现的 agent 复核高风险切片；
- 优先验收当前功能的主流程和最小充分证据，不把推测性的防御分支、无关重构或后置真机调试塞入实现切片；
- 只在证据满足完成定义时更新平台矩阵和状态。

主 agent 可以直接修改组合根、路由、共享资源或处理集成冲突，但不应在可独立委派时同时承担大块功能实现。

### 9.2 推荐波次

在四个并发槽（主 agent + 最多三个子 agent）下，推荐：

1. **调查波次**：三个子 agent 分别核查 macOS 基线、目标平台现状、契约/测试，全部只读。
2. **实现波次**：两个或三个子 agent 各自拥有独立功能目录和测试文件；共享接口、Shell 和资源由主 agent 或单一集成 agent 持有。
3. **验证波次**：至少一个未参与实现的 agent 做只读差异审查，一个 agent 运行目标测试；主 agent 复核结果并决定返工或合并下一波次。

若本地化资源仍是单文件，先由资源 owner 分配并写入双方资源键，功能 agent 只引用已经存在的键。不得让多个 agent 同时编辑同一 `.strings` 或 `.resw`。

### 9.3 子 agent 任务模板

```text
目标：一个可独立验收的用户结果
基线：macOS 源码/测试/契约的精确路径
允许修改：逐个列出文件或独占目录
禁止修改：Mac、Android、共享热点及用户现有改动
前置接口：已冻结的协议、模型、fixture 和资源键
安全要求：确认/权限/防重复/回读/取消语义
功能闭环：本切片必须可完成的用户主流程、必要状态与明确非目标
完成条件：代码、相关五态、双语、可自动验证的无障碍和聚焦测试
必须运行：当前环境可执行的精确命令
待用户后测：无 / PENDING_USER_VALIDATION；条件、步骤、预期、失败证据与受影响入口
若包含真实或危险写：用户明确授权的专用测试环境、允许操作范围、确认方式与写后复查要求
交接：改动、决策、结果、失败、风险、下一步、git status
```

## 10. 跨端共同验收矩阵

下表用于 Windows 最终对齐，以及 Apple **当前核心/受限范围**的发布验收；不要求在每个功能切片结束时一次跑完。移动后续/当前不做项不进入矩阵，也不能以缺少真机为由重新变成当前承诺。当前环境可自动验证的项目随切片完成；真机、签名、硬件和真实 NAS 项整理为 `PENDING_USER_VALIDATION` 清单，待用户集中测试后补证据和修复。

| 维度 | Windows | iPhone | iPad |
| --- | --- | --- | --- |
| 构建 | Windows SDK 下 Debug/Release，x64/arm64 | 无签名模拟器 + 正式签名真机 | 同 iPhone，另含当前范围在分屏/台前调度中的单窗口宽度适配；多窗口仅在未来获批后加入 |
| 输入 | 鼠标、键盘、触控、快捷键、拖放 | 触控、系统返回、分享、旋转 | 触控、键盘、指针、拖放、分屏/台前调度 |
| 可访问性 | Narrator、键盘焦点、高对比、100–200% 缩放、Accessibility Insights | VoiceOver、最大动态文字、按钮形状、减少动态效果 | 同 iPhone，另检查多栏焦点与硬件键盘 |
| 视觉 | 浅色/深色、高对比、窄/宽窗口 | 小/大屏、浅/深色、纵/横屏、安全区 | 纵/横屏、紧凑/常规宽度、并列 App |
| 生命周期 | 窗口隐藏/恢复、托盘、休眠、重启、安装/卸载 | 当前范围的前后台、系统终止、低电量、网络切换 | 同 iPhone；多个 Scene 仅在未来获批后加入 |
| 网络 | 局域网、公网直连、QuickConnect 中继、证书变化 | 当前范围前台流程的 Wi-Fi/蜂窝切换；后台调度仅在未来纳入后验收 | 同 iPhone |
| DSM | 普通/管理员、套件有/无、只读/可写、当前记录 build | 只验收专项矩阵当前核心/受限模块所需的账号、套件与 build | 同 iPhone |
| 写操作 | 成功、部分成功、权限拒绝、提交未确认、取消后复查 | 只覆盖当前受限写子集，不包含 Container/VMM/NAS 管理写 | 同 iPhone，另验证键盘/拖放不能绕过确认 |

任何平台通过都不能替代另一平台或另一 DSM build 的验证。Apple 的验收以各设备被承诺的范围为准，iPad 输入增强不能把复杂桌面运维升级为移动必做。缺少某项外部证据只阻塞对应的 `DEVICE_VERIFIED`、能力开放或发布声明，不回溯阻塞无依赖的源码实现。实机记录只使用 `lab-a`、`lab-b` 等稳定别名并遵循最小披露。

## 11. 每阶段质量门

每个功能切片进入下一代码切片前，主 agent 至少运行 `git diff --check`、与改动直接相关的聚焦测试和当前环境可执行的构建。下列共享命令是按影响选取的完整门禁清单；里程碑、公共契约或共享 Package 变更时再执行对应全量项，不为无关平台重复运行：

```bash
git diff --check
python3 tools/localization/check_localization.py
swift test --package-path apple
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

只改 Windows 时可以不执行 Apple 构建。仅改移动 App 且未触碰共享 Package 时，可不执行上面的 DsmMac 构建；公共契约或 `apple/Packages/**` 改动必须同时执行共享测试和 DsmMac App + File Provider Extension 的无签名构建。Windows 的 .NET/WinUI 构建优先交给可用 Windows 环境或 CI；Apple 移动端优先分别使用 iPhone 与 iPad Simulator。当前没有目标主机、模拟器、签名或真机时，如实记录 `PENDING_USER_VALIDATION` 或相应验证等级缺口并继续无依赖功能，不得用其他平台结果冒充，也不得跳过当前环境本可执行的相关测试。

涉及用户可见文案、语言资源或界面状态的切片，无论是否为里程碑，都必须运行 `python3 tools/localization/check_localization.py` 及项目既有硬编码扫描；不得以 `PENDING_USER_VALIDATION` 代替当前环境可执行的本地化检查。

质量门还包括：

- 没有硬编码用户文案、秘密、真实路径或未脱敏响应；
- 没有用 UI 字符串、翻译或图标判断业务状态；
- 没有新增无限列表、无界缓存或主线程大文件解码；
- 高风险操作没有自动重试，提交未确认时只刷新最终状态；
- 内部只读失败不阻断无关模块，内部写在未知环境默认关闭；
- 没有为未记录契约、可复现故障或明确风险添加推测性校验、重复 fallback 或平行实现；
- 没有通过跳过测试、降低断言或删除回归来制造通过。

## 12. 文档同步与交付

每个达到新验证等级，或新增/关闭 `PENDING_USER_VALIDATION` 的切片，按实际影响更新：

- 本文的功能账本状态；
- 对应 Windows 或 Apple 移动专项计划；
- [平台功能矩阵](../progress/PLATFORM_MATRIX.md)；
- [当前开发进度](../progress/STATUS.md)中的实时结果；
- 相关功能专项计划、请求 fixture、私有 API 兼容矩阵和 DSM 兼容矩阵。

如果任务未完成需要交接，除根 `AGENTS.md` 规定内容外，还必须指出当前功能 ID、功能闭环边界、账本状态、已冻结接口、待用户后测清单、下一 owner 的允许文件和不能触碰的用户改动。

## 13. 参考资料

- [总体架构](../architecture/ARCHITECTURE.md)
- [原生技术栈 ADR](../architecture/decisions/0002-native-stacks.md)
- [官方 API 优先 ADR](../architecture/decisions/0003-official-api-first.md)
- [安全与隐私基线](../security/SECURITY_BASELINE.md)
- [请求契约与写操作结果计划](REQUEST_CONTRACT_AND_MUTATION_RESULT_PLAN_ZH.md)
- [桌面云盘专项计划](NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)
- [Apple Replicated File Provider](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)
- [Apple 后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Microsoft WinUI NavigationView](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/navigationview)
- [Microsoft Cloud Files API](https://learn.microsoft.com/en-us/windows/win32/cfapi/cloud-files-functions)
