# iPhone 与 iPad 移动精选功能开发计划

- 状态：实施中；第 0～4 波核心/受限切片已持续落地，当前事实与验证等级以跨端账本和 `STATUS.md` 为准
- 上位计划：[macOS 功能对齐总控计划](MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)
- 目标技术栈：Swift 6、SwiftUI、URLSession、Apple 系统框架
- 最低系统基线：保持当前 iOS/iPadOS 17，不在本计划中提高

## 1. 为什么共用一份计划

当前 `DsmMobile` 是一个 Universal Target：

- `TARGETED_DEVICE_FAMILY` 同时包含 iPhone 与 iPad；
- 使用同一个 Bundle ID、源码目录、Keychain、安全会话和本地化资源；
- 共同依赖 `DsmCore`、`DsmNetwork`、`DsmLocalization`；
- 业务契约、权限、安全写操作和网络行为不应按设备复制两套。

因此本文使用三条泳道：

1. **共享业务与平台能力**：领域、Repository、任务、权限、安全和状态恢复。
2. **iPhone 紧凑体验**：五个顶层入口、单列导航、触控与全屏内容。
3. **iPad 增强型移动工作台**：多栏、键盘、指针、拖放与动态宽度；不是缩小版 Mac 运维控制台。

同一份计划不代表 iPhone、iPad 或 macOS 功能范围相同。只有第 3.3 节明确标为“核心”或“受限”的能力才进入当前交付；其中共享业务出口和对应设备形态出口必须分别通过，不能用 iPhone Simulator 代替 iPad Simulator。开发先完成两种模拟器宽度下的主流程，只能由真机取得的当前范围证据按第 13 节后置。

## 2. 第 0 波立项时的 DsmMobile 基线（历史快照）

本节记录第 0 波开始前的源码库存，不代表当前分支状态。当前完成度、验证等级、已收窄范围和后续缺口以 [第 0 波跨端对齐账本](CROSS_PLATFORM_PARITY_WAVE_0_LEDGER_ZH.md) 为准。

### 2.1 已有能力

- HTTPS/QuickConnect 登录、OTP 字段、资料保存、Keychain 可选密码、会话恢复和自动登录基础链路。
- 九个模块入口：文件、照片、Chat、Download Station、Container、VMM、NAS、传输、设置。
- iPhone 使用 `NavigationStack`，常规宽度使用基础 `NavigationSplitView`。
- 文件基础列表/搜索/新建文件夹/重命名/单项删除。
- Download Station 基础列表、URL 创建、暂停/继续/删除。
- Container/VMM 基础资源列表和少量操作。
- NAS 概况、存储、套件、账号、日志、连接的浅层只读摘要。
- 英语/简中共享资源和基础可访问性标签。

### 2.2 当前能力库存与产品处理

当前主要源码集中在 `MobileRootView.swift`、`MobileAppModel.swift`、Keychain 和 App 入口，测试主要覆盖入口与登录恢复。下表是能力库存，不是要求把所有 macOS 差距补齐：

| 模块 | 当前缺口 | 本计划处理 |
| --- | --- | --- |
| 登录/安全 | 缺证书核对、按 NAS pin、变化阻断、可取消连接和能力不可用原因 | **核心**，必须补齐安全语义 |
| Files | 分页、预览、单文件导入导出与基础管理尚不完整；桌面还包含跨 NAS、归档、MD5 等长流程 | 补齐核心/受限子集；复杂桌面流程当前不做 |
| Photos | 只是按扩展名筛选 `FileItem` 并显示占位图 | 补齐 NAS 照片浏览、查看、主动导入/分享与有限管理；自动备份后续 |
| Chat | 只有会话列表 | 补齐文字 Chat 核心和单附件受限能力；高级消息能力不作为当前出口 |
| Activity/Download | 活动为空状态，Download 缺详情和完整结果语义 | 活动核心；Download 单任务查看与常用控制受限实现 |
| Container/VMM | 已有浅层资源入口，缺完整桌面管理和控制台 | 只做受限只读摘要；写操作和 VMM 控制台不是当前缺口 |
| NAS | 只有少量只读摘要，远少于 macOS 21 类管理页 | 只补健康与必要只读诊断；配置、电源、账号和长时分析不是当前缺口 |
| iPad | 只按 horizontal size class 分支，缺实际宽度、键盘、指针和拖放设计 | 补齐当前范围的自适应生产力；多窗口后续 |

立项时的静态源码中尚未形成完整的 PhotosPicker、系统文件导入导出和 QuickLook/AVKit/PDFKit 移动查看器。当前已完成系统文件导入导出、分享、QuickLook/PDFKit/AVKit 只读预览、FILE-02 位置、FILE-07 分享链接创建/复制/系统分享与 Files 单项管理撤销、FILE-03 新建/重命名、FILE-05 单文件同 NAS 复制/移动、FILE-09 回收站受限写、PHOTO-01 有界时间线、PHOTO-02 基础查看器与元数据、PHOTO-03A PhotosPicker 单项导入、Chat 只读消息、受限纯文字与单附件发送、Chat 本地会话置顶及前台实时/轮询降级、Download 单任务详情、暂停/继续、URL/磁力创建、任务文件创建、单任务删除、当前活动摘要和 BTSearch v1、NAS 健康、NAS-02/NAS-04 四分区有界只读详情、VMM Guest、Container 实例和本地设置闭环。BTSearch 包含 Apple 共享契约、移动端搜索 Sheet、会话内隐私、条件迟到隔离、独立清理、零提供方恢复态、结果创建链和 48 项英中资源；本机共享聚焦 65/65、共享全量 675 XCTest（2 跳过）+10 Swift Testing、移动端 11/11，正式提交 `5850f4c` 的 Apple Build run `31356270194` 又通过同规模共享包测试、iPhone/iPad 通用应用构建和 macOS 打包。FILE-07 管理切片已让 Files 单个文件/文件夹可按完整路径列出既有公开 Sharing v3 链接、复制、系统分享并二次确认撤销；撤销固定稳定 ID、完整链接基线、单次提交、结果未知只核对不重放和删除后回读确认，本机 iPhone 模拟器聚焦 20/20、共享包 111/111、本地化与差异检查已通过。ACT-01 首片已合入正式提交 `2491212`，把 Download Station 已加载任务快照投影到 Activity 的独立 NAS 来源，新增暂停态与 NAS 项只读控制边界；本地 Activity 聚焦测试已通过，GitHub Apple Build run `31360092209` 通过共享包 675 项 XCTest（2 跳过）+10 Swift Testing、iPhone/iPad 通用应用构建和 macOS 打包，真机与真实 NAS 待验收。Chat 本地会话置顶只保存 profile 绑定会话 ID 顺序，列表滑动操作和详情工具栏可完成置顶/取消置顶，本机 iPhone 模拟器 Chat 聚焦 38/38 通过，GitHub Apple Build run `31450710918` 和 Repository Check run `31450710909` 已通过。Download RSS/文件优先级/BT 高级/设置写、Activity 主动后台轮询、后台 URLSession/BGTask、本地通知、File Provider、WKWebView 控制台和多窗口仍属于后续候选或当前排除项。

## 3. 移动范围与 macOS 语义基线

### 3.1 macOS 是行为基线，不是移动页面模板

对于已经纳入当前范围的能力，移动端必须保留：

- 用户可以完成的目标；
- API 能力和版本门控；
- 权限、确认、防重复、取消和回读；
- 部分成功、未知结果、网络中断和会话过期的语义；
- 按 NAS 隔离的资料、状态、草稿、缓存和任务。

当前范围的桌面交互需要替换为：

- 侧栏/菜单栏 → Tab、Stack、SplitView 和 Profile 菜单；
- 右键/悬停/双击 → 可见按钮、上下文菜单、长按与标准点按；
- 框选/Ctrl 多选 → Edit 模式与底部动作栏；
- 可调整预览窗口 → iPhone 全屏查看器、iPad 详情区；
- Finder/常驻进程 → App 内浏览、Document Picker/Exporter、分享与可恢复的前台任务；
- 桌面大表格/横向标签 → 分组钻取列表、摘要卡、筛选和详情 Inspector。

### 3.2 必须如实保留的 macOS 边界

- **照片**：macOS 当前通过公开 File Station 扫描个人/共享照片目录，提供时间线和文件夹式相册；不等同完整 Synology Photos。人物、地点、标签和真正相册实体等内部候选继续关闭。
- **Chat**：内部能力当前仍是 degraded；加密会话拒绝明文降级，语音未进入完整发送流程。移动端不能扩张为已支持。
- **Container**：全部属于内部 API，当前证据 degraded；未知环境写入口关闭。
- **VMM**：读取和少量写有内部契约边界；创建、编辑、网络写和删除不能因 macOS 有 UI 就宣称已实机可用。
- **NAS 管理**：多项危险写缺行为验证；外接存储、ZRAM、进程、电源计划摘要等保持只读，系统升级安装、套件安装/升级和管理员 ACL 矩阵保持关闭。
- **File Provider**：macOS 是只读枚举、按需读取和离线缓存，创建/修改/删除不支持，也没有远端增量同步承诺；Apple 移动端当前使用 App 内浏览与系统选择器，File Provider 只作为后续独立产品决策。

### 3.3 iPhone / iPad 产品范围矩阵

范围标签是长期产品承诺，不是验证等级，也不是第 0 波完成清单。第 0 波实际状态以跨端账本第 4 节及最新追加集成结果为准；尚未取得严格写契约、内部 API 版本门或聚焦自动化的受限能力不得由本表推断为已实现或待真机验收：

- **核心（`MOBILE_CORE`）**：当前交付必须完成。
- **受限（`MOBILE_LIMITED`）**：只完成表内明确子集，未列出的 macOS 动作不是缺口。
- **后续（`MOBILE_FUTURE`）**：不进入当前 DAG，需重新确认产品价值、权限、契约和验收成本。
- **当前不做（`MOBILE_EXCLUDED`）**：本轮明确排除，并给出替代路径。

| 功能 ID | iPhone | iPad | 当前交付边界 / 替代路径 |
| --- | --- | --- | --- |
| FND-01～04、NAV-01 | 核心 | 核心 | 登录、证书、资料/NAS 切换、能力说明、五 Tab/自适应导航和单窗口状态恢复；安全语义不得裁剪 |
| FILE-01 | 核心 | 核心 | 共享目录、分页、搜索、排序/筛选、列表/网格、返回后状态恢复 |
| FILE-02 | 受限 | 受限 | 收藏、最近、回收站与分享入口；公开远程位置可只读，挂载创建/修改/断开当前不做 |
| FILE-03 | 受限 | 受限 | 新建文件夹、重命名和基础详情；空文件、递归目录统计、MD5 当前不做 |
| FILE-04 | 核心 | 核心 | 用户选择的单文件上传、下载/导出、系统分享与取消；文件夹/大批量和常驻后台传输当前不做 |
| FILE-05 | 受限 | 受限 | 有明确上限的同 NAS 复制/移动；iPad 增加拖放快捷方式；跨 NAS 和大批量交给 Mac App 或 DSM Web |
| FILE-06 | 当前不做 | 当前不做 | 密码/编码/覆盖组合的压缩解压交给 Mac App 或 DSM Web |
| FILE-07 | 核心/受限 | 核心/受限 | 创建、复制、系统分享链接为核心；Files 单项既有链接列表、复制、系统分享和二次确认撤销已按公开 Sharing v3 受限开放；批量撤销、编辑密码/到期日、Photos 管理入口和私有照片分享当前不做 |
| FILE-08 | 核心 | 核心 | 图片、PDF、文本只读、音视频预览与分享；iPad 并列详情；文本编辑/格式整理当前不做 |
| FILE-09 | 受限 | 受限 | 移入回收站与恢复；永久删除当前不做 |
| ACT-01 | 核心 | 核心 | App 前台传输与 NAS 任务分源显示、进度、取消和可解释结果；不承诺常驻后台 |
| PHOTO-01～02 | 核心 | 核心 | 个人/共享空间、文件夹、前台可取消且有上限的用户主动时间线、搜索、缩略图、查看、分享与基础元数据 |
| PHOTO-03 | 受限 | 受限 | PhotosPicker 主动导入、导出/分享、有上限的 NAS 内移动/回收站；不删除系统照片图库项目 |
| CHAT-01～02 | 核心 | 核心 | 会话、首次单聊、非加密私人群聊、成员、分页、草稿、文字/Emoji、失败恢复、前台实时与轮询降级 |
| CHAT-03～04 | 受限 | 受限 | 单附件收发/保存及少量常用消息动作；提醒、定时、投票、服务端置顶、语音与加密不作为当前交付 |
| DS-01～02 | 受限 | 受限 | 单任务列表/详情、URL/任务文件创建、暂停/继续；批量、删除数据和高级设置交给 Mac App 或 DSM Web |
| CM-01 | 受限 | 受限 | 容器、映像、网络、项目与事件的隐私白名单只读摘要 |
| CM-02 | 当前不做 | 当前不做 | 生命周期、删除、Registry 拉取和网络写交给 Mac App 或 DSM Web |
| VM-01 | 受限 | 受限 | 虚拟机、主机、存储、网络、映像、保护与事件的只读健康摘要 |
| VM-02 | 当前不做 | 当前不做 | 创建/编辑/删除、网络/映像写、电源操作和远程控制台交给 Mac App 或 DSM Web |
| NAS-01 | 核心 | 核心 | 系统、连接、容量、硬盘与性能的只读健康摘要；更新只显示检查结果和说明，不安装 |
| NAS-02、NAS-04 | 受限 | 受限 | 只读连接/配置、套件、任务、日志和当前连接摘要；隐私字段白名单保持严格 |
| NAS-03、NAS-05 | 当前不做 | 当前不做 | 硬件/UPS/防火墙/电源写、账号/ACL、设置写和全 NAS 存储分析交给 Mac App 或 DSM Web |
| SET-01 | 核心 | 核心 | 语言、主题、模块偏好、可再生缓存清理和隐私诊断边界 |
| SYS-01 | 后续 | 后续 | 当前使用 App 内浏览、Document Picker/Exporter 与分享；File Provider 需独立审批和可信远端变化契约 |

FILE-01 当前账号可见容量增量已接入 iPhone/iPad Files 共享根：复用公开 `list_share` 契约，容量与文件列表独立并发刷新，只展示总量、已用、可用、比例和可见存储空间数。首次失败不阻断浏览，刷新失败保留旧值；切换 NAS、离开共享根或页面拒绝迟到结果。分页不完整、本地卷容量缺失/畸形、同卷冲突或溢出时不发布部分结果；远程挂载不计入。不展示卷标识、真实路径或管理员物理存储，不新增写操作、后台轮询或新 API。本机聚焦 34/34、DsmMobile 全量 460/460、共享包 699 项（2 项跳过）、通用模拟器构建、本地化与契约门禁已通过；功能分支 Apple Build run `31569016908` 和 Repository Check run `31569017056` 已通过。真实设备、VoiceOver、最大动态文字和真实 NAS 为 `PENDING_USER_VALIDATION`。

除表中已经指定系统 App 的替代项外，受限能力中被明确裁掉的桌面工作流统一交给 Mac App 或 DSM Web，并以对方实际支持的能力和权限为准；本计划不承诺深链、单点登录或自动传递会话。

另外三个后续候选是系统照片自动备份、iPad 多窗口和经实机验证的后台文件传输。它们不阻塞当前移动范围完成。macOS 后续新增功能默认进入“后续”，不得仅因共享代码可用就自动进入 iPhone/iPad。

## 4. 审批门与平台权限

以下能力会修改权限、entitlement、Target、Info.plist、签名边界、数据格式或持久化结构。表中的后续候选不进入当前实现；未来若要开启，必须单独说明必要性、影响、迁移和回滚，并取得用户明确同意：

| 决策门 | 当前范围 | 可能变更 | 未批准时的处理 |
| --- | --- | --- | --- |
| 自动照片备份 | 后续 | PhotoKit 使用说明、照片权限、后台处理标识/模式 | 只提供 `PhotosPicker` 主动选择导入 |
| 后台文件传输 | 后续 | 后台 `URLSession` identifier、任务映射与恢复状态 | 保持前台传输；离开前说明影响，不伪装后台运行 |
| 照片发现/准备 | 后续 | `BGTaskSchedulerPermittedIdentifiers`、Background Processing mode | 不做自动发现或整库扫描 |
| Files App 集成 | 后续 | File Provider Target、App Group、共享 Keychain access group、entitlement、签名 | App 内浏览 + 系统导入导出与分享 |
| 本地通知 | 后续增强 | 通知授权与隐私文案 | App 内活动中心和状态反馈正常工作 |
| 当前范围持久化 schema | 按需审批 | 单窗口导航、任务和草稿的版本化数据格式 | 未批准时先用内存状态，不扩大范围 |
| 多窗口 | 后续 | `WindowGroup`/`openWindow`、Scene manifest、restoration activity | iPad 保留单窗口自适应 SplitView |

不新增第三方依赖。上述审批只允许实现计划中明确的能力，不授权真实 NAS 危险写或改变 Bundle ID/最低系统版本。

持久化 schema 决策必须先记录版本、迁移、回滚、旧版本兼容、损坏恢复，以及卸载、删除 profile、退出登录时分别清理什么。若未来开启 File Provider，其 App Group 只保存 opaque domain/profile 元数据；SID、Token、Cookie、证书 pin 和密码只能进入共享 Keychain access group，不能进入 App Group、URL 或日志。

### 4.1 功能优先与后置用户真机验证

移动端按“当前核心/受限业务主流程 → iPhone/iPad Simulator 的相关状态与聚焦自动化 → 后续用户真机/真实 NAS 验证”推进。实现先解决用户结果、必要错误和移动交互转换；不为尚无契约、可复现故障或明确风险的罕见场景预建重复校验、平行 fallback 或大范围抽象，也不提前为后续/当前不做项搭空壳。

当前范围中的系统选择器、系统终止后的状态、旋转/分屏、外接键盘/指针、正式签名以及真实 NAS 行为可记录为 `PENDING_USER_VALIDATION`。该标签只是账本待办，不是新的验证等级；每项写明设备/系统条件、用户步骤、预期结果、需回传的脱敏失败信息和影响范围。多窗口、File Provider、自动照片备份等后续项不使用该标签，除非未来经审批正式进入实现。

Keychain、证书信任、后台文件完整性、危险写和内部 API gate 仍是代码硬门禁。未经真机或真实环境验证可能造成泄密、数据损坏或不可逆副作用时，只让相关入口保持关闭、只读或降级到已验证的 App 内路径；不得因此暂停其他模块。

## 5. 目标信息架构

### 5.1 iPhone：五个顶层入口

使用最多五个带图标与文字的顶层 Tab，每个 Tab 有独立 `NavigationStack`、路径、筛选、滚动和草稿状态：

1. **文件**：共享目录、收藏/最近、分享链接和回收站；远程位置仅在公开只读能力可用时显示。
2. **照片**：个人/共享空间、时间线、文件夹式相册。
3. **Chat**：会话、消息和成员/会话详情。
4. **活动**：App 传输、NAS 文件任务、Download Station，以来源分段而非混成同一种任务。
5. **更多**：NAS 健康、Container/VMM 只读摘要和应用设置。

全局搜索不能在各模块之间偷换语义；每个 Tab 自己管理搜索和筛选。Profile 菜单是 NAS/profile 切换、连接状态和退出登录的唯一入口；“更多”负责应用设置和管理模块。危险操作不放在主导航旁边。

### 5.2 iPad：按实际可用宽度自适应

- 常规宽度使用 `NavigationSplitView`：模块/位置侧栏 → 列表或内容 → 详情/Inspector。
- 紧凑宽度（Split View、Slide Over 或较窄 Stage Manager 窗口）自动折叠成 Stack；不能用 `UIDevice.userInterfaceIdiom == .pad` 决定多栏。
- 同一层级不同时堆叠 Tab Bar 与 Sidebar；共享 RouteModel 将同一目的地映射到紧凑或常规容器。
- 当前只交付单窗口自适应布局；多窗口是 DAG 外后续候选，不以 Stage Manager 能力推导复杂运维功能适合 iPad。

### 5.3 交互映射

| 用户目标 | iPhone | iPad |
| --- | --- | --- |
| 浏览深层目录 | 单列 Stack、系统返回、可点路径菜单 | Sidebar + 列表 + 详情，紧凑时自动折叠 |
| 多选文件/照片 | Edit + 底部动作栏，选择计数可读 | 同左，另支持键盘 Shift/Command 与指针 |
| 复制/移动 | 目标目录选择 Sheet | 目标选择器 + 可选拖放；拖放始终有可见替代 |
| 项目菜单 | 44pt 更多按钮/长按菜单 | 上下文菜单、键盘命令和 Toolbar |
| 图片/媒体预览 | 全屏、捏合、左右切换、底部工具栏 | 详情区或全屏查看，支持键盘前后与 Inspector；不新增独立窗口 |
| 属性/元数据 | 分组 Sheet | 右侧 Inspector，可收起 |
| 当前范围的短表单 | 全屏或中型 Sheet，逐步披露 | Form Sheet 或详情列，保留步骤状态 |
| 桌面级长向导/危险管理 | 引导到 Mac App 或 DSM Web，不复制入口 | 同左；键盘和宽屏不改变产品范围 |
| VMM 控制台 | 当前不做，改用 Mac App 或 DSM Web | 当前不做；未来评估时建立独立安全与产品决策 |
| 系统分享 | ShareLink/Activity Sheet | 同左，可使用拖放到其他 App |

### 5.4 全局交互与动效合同

- 所有触控目标至少 44×44pt，相邻目标保留足够间距；主操作不被 Safe Area、键盘或底部 Sheet 遮挡。
- 只使用系统字体、SF Symbols、语义颜色和系统材质；普通文字对比度至少 4.5:1，状态不能只靠颜色表达。
- 动效优先 SwiftUI 原生转场，通常 150–300ms、可中断且只表达层级或操作因果；优先动画 `opacity`/`transform`，避免大范围布局抖动。
- 开启 Reduce Motion 时取消视差、弹跳和空间位移，以短淡入淡出或无动画替代；动画不能阻断输入。
- 长按、Swipe、拖放和捏合都必须有可见按钮、菜单或键盘命令作为等价路径；不能把隐藏手势作为唯一入口。
- 每个子 agent 都要在相关 iPhone/iPad Simulator 尺寸覆盖主流程、五态、浅色/深色、Dynamic Type 和紧凑/常规宽度；不要求每个小切片穷举全部组合。真机 VoiceOver、旋转、键盘/指针和 Stage Manager 单窗口缩放进入第 13 节，自动化可及的问题仍在当前切片修复。

## 6. 目标代码结构与状态边界

先在 DsmMobile App 内建立功能目录，不立即改变 Swift Package target：

```text
apple/Apps/DsmMobile/Sources/
  AppShell/
    AdaptiveShell.swift
    AppDestination.swift
    MobileWorkspaceState.swift
  Session/
    MobileSessionCoordinator.swift
    CertificateReviewState.swift
    ProfileWorkspaceStore.swift
  CommonUI/
    PageStateView.swift
    MutationFeedbackView.swift
    AdaptiveInspector.swift
  Features/
    Files/
    Photos/
    Chat/
    Activity/
    Services/Downloads/
    Services/Containers/
    Services/VirtualMachines/
    Administration/
    Settings/
  Platform/
    Documents/
    Photos/
```

规则：

- `MobileAppModel` 在 M0 先由单一 agent 机械拆分；迁移期间可保留兼容 facade，但新功能不得继续塞入全局模型。
- 每个 Feature 有自己的 `@MainActor` ViewModel、Route、PageState 和测试，不直接持有其他 Feature 的 UI 状态。
- 进程级 actor 负责安全会话、稳定目标写操作锁和任务注册；当前单窗口状态只保存当前 NAS、导航、选择、筛选与草稿引用。
- Profile 切换前由任务协调器判断哪些前台任务可以取消、完成或必须阻止切换；退出登录与切换 NAS 保持不同语义。
- `DsmCore`/`DsmNetwork` 只做向后兼容扩展。若至少两个 Apple 客户端确需共享纯业务编排，再评估启用现有 `DsmFileFeature`/`DsmTransferFeature` 目录；修改 `Package.swift` 前先取得工具链变更批准。
- App UI 不解析原始 JSON，不读取翻译来判断状态，不直接拼接 API 参数。

## 7. 共享安全协调器

当前全局 `actionInProgress` 只能阻止一个页面同时操作，不能作为危险写保护。目标流程统一为：

```text
能力/版本检查
  → 权限、目标存在和当前状态预检
  → profile + operation + stableTarget 锁
  → 展示目标与影响并确认
  → 只提交一次
  → 处理提交前/提交后取消
  → 最终状态或语义回读
  → MutationResult + 通俗反馈
```

要求：

- 提交未确认、网络超时或取消发生在提交后时，只刷新最终状态，绝不自动重放。
- 批量操作保留失败或未知目标，只有确认成功项从选择中移除。
- 当前文件复制/移动只允许有上限的同 NAS 目标；跨 NAS 不建立移动写路径。
- 当前不提供重启/关机、VMM 电源或其他不可逆运维入口；未来重新纳入时仍须建立专用安全模型和独立验证。
- 内部只读失败只影响当前分区；内部写在未知环境默认关闭。

## 8. 后台、通知与隐私边界

### 8.1 客户端字节传输

- 当前只承诺用户明确发起、App 在前台可观察的单文件上传/下载；Activity 展示进度、取消和最终结果。
- 离开 App 前说明可能中断，不把普通前台任务冒充后台继续；恢复时只根据可证实状态展示，不盲目重放写请求。
- File Station 上传如果没有官方 offset 契约，只能提供“从头重试”；下载仅在严格验证 Range 和片段后提供继续。
- 后台 `URLSession`、跨重启任务关联和系统通知属于后续候选；未来获批后必须使用文件型上传、稳定 identifier、按 profile 隔离和受控验证，不能反向复杂化当前前台引擎。

### 8.2 NAS 服务器任务

Download Station 和 File Station BackgroundTask 在 NAS 上运行，App 只轮询状态。它们与本地字节传输分源持久化；不能把“NAS 仍在处理”显示成本机后台上传。

### 8.3 通知

- 成功/失败通知默认不显示 NAS 名称、账号、文件名、路径、Chat 正文或附件。
- 用户拒绝通知时，活动中心仍完整工作。
- 无 APNs 服务端或 NAS 推送整合时，Chat 只保证前台 Socket.IO 和轮询降级；BGRefresh 是尽力而为，不能承诺后台即时消息。
- 当前不以提醒到期通知作为 Chat 完成条件。未来若开启本地通知，到期内容默认隐私化，点击只携带不含秘密的 opaque route ID。

## 9. 当前范围实施 DAG

```text
M0 冻结产品范围、黄金测试、机械拆分
  └─ M1 Session + Adaptive Shell + 单窗口状态
       └─ M2 安全写协调器 + 前台单文件传输 + Activity
            ├─ M3 Files 精选闭环 + Preview
            │    └─ M4 Photos 精选闭环 + PhotosPicker 主动导入
            ├─ M5-A 文字 Chat 核心
            │    └─ M5-B 单附件与少量消息动作（受限）
            ├─ M6 Download Station 受限任务
            └─ M7 NAS 健康 + Container/VMM 只读摘要
  M3–M7 当前范围出口
       └─ M8 iPad 自适应生产力收口
            └─ M9-A iPhone/iPad 当前范围自动化收口

当前范围的 PENDING_USER_VALIDATION
  └─ M9-B 后续用户真机 / 真实 NAS / 发布验收

自动照片备份 / 后台常驻传输 / 多窗口 / File Provider
  └─ DAG 外 MOBILE_FUTURE；另行决策后才能建立新里程碑
```

### M0：范围冻结、测试护栏与机械拆分

- 把第 3.3 节逐项写入功能账本；iPhone/iPad 分别记录核心、受限、后续、当前不做和替代路径。
- 为现有登录、模块选择和基础写操作补行为测试，防止拆分时回退。
- 单一 owner 拆分 `MobileRootView.swift` 与 `MobileAppModel.swift`，只移动代码和建立注入点，不同时新增功能。
- 在 `project.yml` 中由唯一工程 owner 增加必要的单元/UI 测试 Target；不手改生成工程。
- 建立 CommonUI 五态容器、语义颜色/间距/动效 token 和双语资源键流程。
- 为当前不做项建立“入口不可见或明确转交、零危险请求”的回归；不为后续项预建空页面。

出口：当前范围和非目标已冻结，现有行为测试不退步，生产源码按功能目录分离，Shell/资源/工程文件都有唯一 owner。

### M1：会话、安全与自适应 Shell

- 多 NAS 新建/删除/选择/重命名/排序，切换 NAS 与退出登录分离。
- QuickConnect 路由提示、可取消连接、会话恢复和能力不可用原因。
- 自签名证书首次核对、按 profile pin、证书变化阻断；只有结构/有效期合格的叶证书可固定，relay 只接受系统信任，路由发现阶段不发送登录凭据。
- iPhone 五 Tab，每个独立 Stack；iPad 单窗口 SplitView 按实际宽度折叠。
- 按 profile 隔离导航、筛选、选择与草稿；不在当前阶段建立多 Scene 架构。

自动化出口：紧凑/常规宽度、系统返回、会话过期、证书变化和切换 NAS 均有测试；模拟器最大动态文字不丢主操作。

### M2：安全写、前台传输与 Activity

- 实现稳定目标级 `MutationCoordinator` 和 `MutationResult` UI；危险写继续遵守权限、确认、防重复、一次提交与最终回读。
- 建立 App 前台字节任务与 NAS 服务任务的分源模型、取消/有限重试状态机、合成 fixture 和错误映射。
- 接入 Document Picker/Exporter、分享 Sheet 与受控临时文件生命周期；当前只做单文件前台传输。
- Activity 展示来源、进度、取消和最终结果，不宣称后台常驻或虚构断点续传。

出口：受控服务覆盖取消、提交未确认、空间不足和会话失效；未获批准的后台 URLSession、BGTask 和通知没有运行时入口。

### M3：Files 精选闭环与预览

- 核心：共享目录、分页、层级返回、列表/网格、排序/筛选、搜索、状态恢复、单文件导入/导出/分享。
- 受限：收藏/最近/回收站、分享链接、新建文件夹、重命名、基础详情、有上限的同 NAS 复制/移动、移入回收站与恢复。
- 预览：图片、PDF、文本只读、音视频、图片切换/缩放和系统分享；iPad 提供并列详情/Inspector。
- 明确不做：内部远程挂载写、空文件、递归统计/MD5、批量目录/大批量传输、跨 NAS、复杂压缩解压、文本编辑/格式整理和永久删除。

出口：五态、分页、大文件上限、格式不支持、写结果和“排除项零请求”有聚焦测试；真实系统选择器与 NAS 副作用列入当前范围的 `PENDING_USER_VALIDATION`。

第 1 波候选已完成 FILE-03 的首个受限写闭环：公开 v2/FORM、父目录/源目标基线、同类型回读、目标互斥、一次提交、提交未知 blocker，以及 remote/recycle/`#recycle` 零入口；移动端只在严格确认后关闭表单并刷新父目录。共享与移动聚焦测试已通过；GitHub `Apple Build` run `31306484946` 进一步通过共享 Package 645 项 XCTest（2 项按环境跳过）、iPhone/iPad 通用应用构建与 macOS 回归。真实 NAS 写入仍为 `PENDING_USER_VALIDATION`，FILE-05/09 不因本项完成而自动开放。

第 2 波已实现 FILE-05 的首个受限闭环：单个普通本地文件、同 NAS 普通本地目标、`overwrite=false`，公开 CopyMove v3/FORM、源大小与修改时间冻结、源/目标互斥、一次提交、不可取消独立回读，以及提交未知跨页面 blocker。iPhone/iPad 使用原生目标选择 Sheet；目录、批量、跨 NAS、覆盖、remote/virtual/recycle/`#recycle` 均保持关闭。最新移动聚焦 45/45、共享 FILE-05 聚焦 103/103 通过；最终提交 `1c7ee4851feb00903327b0599a0d29ea421be8c9` 的 Apple Build 已通过共享 Package、Swift Testing、iPhone/iPad 通用应用构建和 macOS 打包；真实 NAS 副作用与真机交互仍待验收。

FILE-05 有界批次增量已把同一当前目录内 1～20 个普通本地文件纳入 iPhone/iPad 主流程。用户在列表或网格进入原生选择模式，只选择一次普通本地可写目标；模型冻结选择并严格串行复用现有 CopyMove v3 typed 结果链，固定 `overwrite=false`。明确失败继续，写前取消停止；提交未知、部分结果、异常和回读不一致停止余项，以 `profile + operation + sourcePath + destinationFolderPath` 稳定身份阻断重放。完成摘要保持确认、失败、待核对、取消和未开始计数守恒，并列出失败或取消项目及原因；选择状态、不可选和上限提供 VoiceOver 值。本机聚焦 30/30、DsmMobile 全量 470/470、本地化与差异检查通过。批量目录、跨目录来源、跨 NAS、覆盖、自动改名、并行、拖放、撤销和后台恢复仍关闭；真实设备、真实 NAS、VoiceOver、最大动态文字、窄屏、旋转与 iPad 外接输入为 `PENDING_USER_VALIDATION`。

FILE-05 单文件夹增量已把 Files 中的单个普通本地文件夹纳入 iPhone/iPad 复制/移动主流程：单项菜单复用既有原生目标 Sheet 和公开 CopyMove v3 typed 结果链，目标浏览排除源目录整棵子树，提交仍固定 `overwrite=false`、一次提交、提交未知只回读不重放。共享 Repository 和移动模型对目录只核对路径、名称和类型，不依赖 DSM 非稳定目录大小；普通文件仍继续核对大小和修改时间。批量目录、跨目录来源、跨 NAS、覆盖、自动改名、拖放、撤销、后台恢复和递归内容逐项校验仍关闭。本机 iPhone 17 Pro 模拟器 CopyMove 聚焦 23/23、共享 `DsmFileRepositoryTests` 112/112、`RequestFixtureContractTests` 29/29、本地化和差异检查已通过；真实 iPhone/iPad、真实 NAS 目录副作用、VoiceOver、最大动态文字、窄屏、旋转与 iPad 键盘/指针为 `PENDING_USER_VALIDATION`。

FILE-09 单文件夹回收站增量已把 Files 中的单个普通本地文件夹纳入 iPhone/iPad 主流程：用户可用既有原生确认 Sheet 将文件夹移入同共享 `#recycle`，也可从回收站恢复到严格反推的原位置。实现复用既有 Delete v2 / CopyMove v3 结果链，不新增 API 契约；入口要求当前 profile、普通本地位置、可见列表项、完整路径和已发现回收站位置，symlink/unknown、远程位置、回收站内移入、普通浏览恢复仍零入口。目录成功只核对路径、名称和类型，不依赖 DSM 非稳定目录大小；文件仍继续核对大小。确认文案已明确文件夹内容会一起移动或恢复。本机 Recycle 聚焦 11/11、本地化与差异检查通过。批量、永久删除、清空回收站、覆盖恢复、跨 NAS 和递归内容逐项校验不在本切片；真实 iPhone/iPad、真实 NAS 目录副作用、权限变化、同名恢复策略、弱网取消、VoiceOver、最大动态文字和 iPad 键盘/指针为 `PENDING_USER_VALIDATION`。

### M4：Photos 精选闭环与主动导入

- 使用共享 `PhotoLibraryRepository`，实现个人/共享空间、文件夹、前台可取消且有上限的用户主动时间线、分页、搜索和年/月定位；不在后台整库扫描。
- 真实缩略图、可见窗口优先和有限预取；滚动/离页/切换 NAS 释放旧任务。
- 图片/视频查看、基础 EXIF 白名单、分享；不宣传人物、地点、标签或真正 Synology Photos 相册。
- 使用 `PhotosPicker` 主动选择明确项目，原图进入受控临时文件后复用 M2 传输；不索取整库权限。
- 受限提供有上限的 NAS 内移动、移入回收站和恢复；不删除系统照片图库项目。

出口：浏览、查看、主动导入和受限 NAS 管理的五态与临时文件清理有测试；真实系统图库选择器和格式矩阵后置用户验证。自动扫描/备份不进入本里程碑。

第 1 波候选已完成 PHOTO-02 只读查看增强：冻结当前可见快照、前后导航、iPhone 全屏、iPad Inspector、保存/分享绑定当前 canonical 项目，以及只从已验证本机预览产物读取尺寸、拍摄时间和相机品牌/型号白名单；GPS、MakerNote、设备序列号、私有 Foto 与新增 NAS 请求保持关闭。当前 iPhone 模拟器聚焦 60/60 通过，GitHub `Apple Build` run `31306484946` 已通过 iPhone/iPad 通用应用构建；iPad 运行交互与真机格式矩阵仍待验证。

第 2 波已完成 PHOTO-03A 主动单项导入：只用 `PhotosPicker` 选择一项图片或视频，受控临时产物复用既有上传与 Activity，选择取消不改变页面，完成时重新核对 profile、repository、空间、根目录、模式与路径后才刷新。最终提交已通过 Apple Build；未新增 PhotoKit 整库权限、自动备份、私有 Foto 或平行上传实现；iCloud-only、iPad 真机与真实 NAS 上传仍为 `PENDING_USER_VALIDATION`。

PHOTO-03 受限 NAS 管理继续完成单项普通媒体同 NAS 移动源码闭环：文件夹网格和主动时间线只对已知大小、非回收站的单个图片或视频开放“移动到…”，复用 FILE-05 的 `MobileFileCopyMoveModel`、原生目标 Sheet 与共享 CopyMove 协调器，不新增照片专用写契约。目标仍限普通本地可写文件夹，固定无覆盖；提交前后继续执行身份、来源删除权限、目标权限、冲突、一次提交、未知结果只回读不重放和最终回读。切换 profile、Repository 或离页会撤销旧上下文，成功后只刷新当前照片来源。本机 iPhone 17 Pro 模拟器双架构构建与 Photos/CopyMove 聚焦 16/16 已通过；Apple Build run `31521369954` 与 Repository Check run `31521369961` 已通过。复制、批量、跨 NAS、覆盖、自动改名、系统照片图库移动、查看器独立写入口和自动备份不在本切片；真实 iPhone/iPad、真实 NAS 副作用、VoiceOver、最大动态文字、iPad 键盘/指针、弱网和取消为 `PENDING_USER_VALIDATION`。

PHOTO-03 继续补齐单项普通媒体移入回收站源码主流程：Photos 会在自身激活时并发加载公开 FILE-02 回收站位置，不要求用户先打开 Files，也不阻塞照片空间与文件夹首屏；回收站白名单按 Repository 身份绑定，重连会先清空旧入口并重新发现，发现失败保持零入口。文件夹网格、主动时间线和当前查看器只对当前可见快照内、已知大小、非远程、非 `#recycle` 且已发现同共享回收站的一个图片或视频开放破坏性动作，查看器先关闭后再显示既有原生确认 Sheet。实现复用既有 FILE-02 位置发现、FILE-09 的 `MobileFileRecycleActionModel` 和共享 Delete v2 结果链，不新增 API 契约或照片专用写请求；共享协调器继续负责身份与删除权限重读、目标冲突、路径互斥、一次提交、提交未知只回读不重放和最终回读。确认 Sheet 冻结 Repository 身份，成功刷新前必须精确匹配当前 profile 与 Repository。本机 iPhone 17 Pro 模拟器 Photos/Recycle/Locations 聚焦 43/43、DsmMobile 全量 429/429、共享包 685 项 XCTest（2 项按环境跳过）与 10 项 Swift Testing、arm64/x86_64 通用模拟器构建、本地化和 Repository Check 同义脚本均已通过；GitHub Apple Build run `31527045156` 与 Repository Check run `31527045155` 已通过。批量、永久删除、清空回收站、系统照片图库删除和自动备份不在本切片；真实 iPhone/iPad、真实 NAS 副作用、弱网取消、VoiceOver、最大动态文字及 iPad 键盘/指针为 `PENDING_USER_VALIDATION`。

### M5-A：文字 Chat 核心

- 会话/用户/消息/成员 typed 状态、首次单聊与非加密私人群聊。
- 消息分页、草稿、文字/Emoji、发送失败恢复、本地已读和可解释未读。
- 前台 Socket.IO + 轮询降级，重连去重，进入后台后释放不必要连接。
- iPhone 会话 → 消息 Stack；iPad 会话列表 + 消息 + 可选详情，返回保持草稿和滚动锚点。
- 本地会话置顶只作为移动本机偏好，使用列表滑动操作和详情工具栏按钮完成，不接 Chat Server 官方置顶/Star 写入。

出口：未记录 DSM build + Chat Server 完整版本时内部写入口关闭；无 APNs 时不承诺后台即时消息。核心出口不依赖附件或高级消息动作。

CHAT-01～02 群成员只读切片已完成源码与云端构建闭环：移动适配器只在共享 Repository 明确宣告 `.groupMembers` 时透传能力，群聊详情工具栏打开原生 Sheet/List，展示显示名、当前账号和停用状态，并覆盖加载、空内容、错误、重试/刷新和正常列表。成员按 profile/会话仅缓存在内存，关闭页面、切换会话或切换 profile 会取消旧读取并拒绝迟到结果；失败只留在成员 Sheet，不影响消息列表。该切片固定复用既有 `Channel.Member.get` v1 和用户目录，合成契约会排除 `broken_user_ids`，成员补名固定关闭头像读取；不新增 API 契约或持久化，只在用户打开列表时发起成员读取，也不开放建群、邀请/移除、角色管理、群公告、官方 Star、服务器已读或实时同步。本机已通过双语资源门禁、Apple 共享包 685 项 XCTest（2 跳过）+ 10 项 Swift Testing、移动 Chat 聚焦 44/44、工程生成、iPhone/iPad 通用模拟器构建及 macOS 共享资源回归构建；GitHub Apple Build run `31456211435` 已通过同组 685 项 XCTest（2 跳过）+ 10 项 Swift Testing、工程生成、iPhone/iPad 通用应用构建、macOS 打包和产物上传，Repository Check run `31456211422` 已通过。真实 iPhone/iPad、VoiceOver、最大动态文字、键盘/触控、成员权限、`broken_user_ids` 真实响应与真实 Chat Server 为 `PENDING_USER_VALIDATION`。

CHAT-01～02 群公告只读增量已完成源码、本机与云端构建闭环：移动适配器仅在共享 Repository 明确宣告 `.pinnedMessages` 时开放，并复用既有 `SYNO.Chat.Post` v5 `search` 有界读取，最多接收 100 条；不新增或猜测契约。入口仅对未加密群聊显示，使用详情工具栏 `megaphone` 和原生 SwiftUI Sheet/List，覆盖加载、空内容、错误、重试/刷新和正常列表。移动边界会再次核对会话 ID、置顶时间和非加密状态，并只保留消息 ID、会话 ID、发送者、正文、发送时间和置顶时间，强制清空附件、投票和客户端请求 ID；结果按 profile/会话仅驻留内存，关闭 Sheet、切换会话或 profile 会取消旧读取并拒绝迟到结果，失败不影响消息历史。该切片不调用 `pin/unpin`，不开放公告管理、附件展示、实时刷新、单聊/加密群入口或持久化。本机已通过 Apple 共享包 685 项 XCTest（2 跳过）+ 10 项 Swift Testing、移动 Chat 聚焦 48/48、DsmMobile 全量 419/419、本地化门禁、工程生成和 iPhone/iPad 通用模拟器构建；GitHub Apple Build run `31467502691` 已通过共享包测试、工程生成、iPhone/iPad 通用应用构建、macOS 打包和产物上传，Repository Check run `31467502719` 已通过。真实 iPhone/iPad、VoiceOver、最大动态文字、键盘/触控，以及真实 Chat Server 的权限、空列表、排序、附件型公告和撤销后刷新为 `PENDING_USER_VALIDATION`。

CHAT-02 前台实时与轮询降级已形成源码、本机模拟器与云端构建闭环：移动适配器只透传共享 Repository 已有的 `realtimeEvents/startRealtime/stopRealtime`，不解析或持久化 Socket.IO 事件载荷；只有 App 处于 active、已连接且当前显示 Chat 模块时才建立实时通道。`.contentChanged` 在 200 ms 内合并后复用既有会话列表与当前未加密会话消息回读，连接建立前或断开后每 30 秒执行一次单飞轮询；`.connected` 立即停止轮询。离开 Chat、进入后台、切换或删除 profile 会取消事件、合并、轮询和回读任务，等待旧连接停止后才允许重新启动；稳定消息 ID 继续负责结果去重，迟到结果不得写入新 profile 或会话。该切片不刷新成员/公告，不新增 NAS 请求、后台保活、APNs、服务器已读、通知或高级消息写。本机 iPhone 17 Pro iOS 26.5 模拟器 Chat 聚焦 52/52、DsmMobile 全量 423/423、共享包 685 项 XCTest（2 跳过）+ 10 项 Swift Testing 已通过；GitHub Apple Build `31505887860` 已通过共享包测试、工程生成、iPhone/iPad 通用应用构建、macOS 打包与产物上传，Repository Check `31505887864` 已通过。真实 iPhone/iPad 前后台切换、弱网/断线/重连、真实 Chat Server Socket.IO 3/4、VoiceOver、最大动态文字和外接键盘为 `PENDING_USER_VALIDATION`。

CHAT-01 本地已读切片已完成源码与聚焦自动化：`MobileChatProfileState` 按 profile/会话仅在内存保存实际成功读取消息的最大 `sentAt`，`MobileChatMessagesView` 明确登记详情可见生命周期；只有当前未加密会话详情可见且最新页读取成功才清零。会话列表刷新以 `lastActivityAt <= readThrough` 压制旧未读反弹，更晚活动恢复服务端未读；返回 iPhone 列表后即使前台同步成功也不会代替用户清零。读取失败/取消、加密会话、历史分页和缺少可靠时间边界不改变未读；消失会话和 profile 清理会删除基线。本切片不持久化已读、不新增文案、NAS 请求或服务器已读写。本机模型与展示聚焦 56/56、DsmMobile 全量 433/433 通过，GitHub Apple Build run `31533388602` 通过共享包 685 项 XCTest（2 跳过）+ 10 项 Swift Testing、iPhone/iPad 通用构建和 macOS 打包，Repository Check run `31533388647` 已通过；真实 iPhone/iPad、Chat Server 未读字段、VoiceOver、最大动态文字、键盘和分屏为 `PENDING_USER_VALIDATION`。

CHAT-01～02 首次单聊与非加密私人群聊创建已完成源码主流程：移动端以工具栏和带搜索/筛选空态的原生 Sheet/Form 提供单选联系人或群名加至少两位成员的入口，成功后按 iPhone 导航栈或 iPad 双栏进入新会话。共享 Repository 固定 `Channel.Anonymous.initiate` v2、`Channel.Named.create/join/invite` v1 和 `Channel.Member.get` v1，并以精确 FORM 能力、创建前用户/会话重读、当前/停用用户过滤、群成员独立回读和进程内串行保护写链。typed outcome 区分确认成功、明确失败、提交未知和取消边界；未知结果保留原请求与完整草稿，后续只回读，不重放已执行阶段，群 ID 产生后的加入/邀请失败也不误判为终态失败。重连和在途重绑会在当前提交结束后换绑 Repository，待核对草稿只读取会话/成员，联系人读取以代次拒绝旧结果，迟到成功按来源 profile 拒绝跨连接写入。本机 Apple 共享包 695 项 XCTest（2 跳过）+ 10 项 Swift Testing、共享 Chat 聚焦 51/51、移动 Chat 聚焦 63/63、DsmMobile 全量 442/442、双语资源门禁、通用模拟器构建和 macOS 共享回归构建已通过；云端结果不得预支。真实 iPhone/iPad、三账号真实 Chat Server、权限/弱网、VoiceOver、最大动态文字、键盘/触控和 iPad 分屏为 `PENDING_USER_VALIDATION`。

### M5-B：单附件与少量消息动作（受限）

- 接入 Photos/Files 单附件选择、上传进度/取消/失败恢复、保存和图片预览。
- 删除本人消息已进入当前受限范围；转发、关闭会话等仍只在范围账本明确列出且端点已验证时逐项开放。
- 提醒、定时消息、投票、服务端置顶、官方 Star、语音和完整加密不作为当前交付；未实现入口不得出现。

出口：选择器状态、取消、失败恢复和去重有独立测试；附件能力不能反向阻塞纯文字 Chat。

CHAT-04 本人消息删除已完成源码主流程：移动适配器仅在共享 Repository 明确宣告 `.deleteOwnMessage` 时透传能力；SwiftUI 消息行只对当前未加密会话内本人已发送且仍在当前快照中的消息显示滑动删除、上下文菜单和 VoiceOver 动作。删除必须经过原生二次确认，Repository 链提交前先读取确认消息存在且属于当前用户，提交后再次读取并确认消息消失；提交未知、回读不一致或权限变化会把同一消息标记为需刷新核对，刷新前不自动重放。切换会话、profile 或 Repository 会取消在途任务并拒绝迟到结果。本机 iPhone 17 Pro 模拟器移动 Chat 聚焦 66/66 通过；关闭会话、转发、提醒、定时、投票、服务端置顶、官方 Star、语音和加密仍关闭。真实 iPhone/iPad、真实 Chat Server 删除权限/管理员策略、弱网取消、VoiceOver、最大动态文字和 iPad 键盘/指针为 `PENDING_USER_VALIDATION`。

### M6：Download Station 受限任务

- 已提供单任务列表/筛选/详情、URL/magnet 与任务文件创建、目标目录选择、暂停、继续和只移除任务；删除已下载数据仍关闭。
- 官方 BTSearch v1 的提供方/类别、七类排序、有界结果、取消/清理、零提供方状态与单结果创建已完成源码闭环；真实 NAS、iPad/Windows 交互按专项 PUV 验收。
- ACT-01 已在 Download Station 当前已加载快照之外补齐 File Station 前台主动刷新：Activity 可见且 App 处于前台时，立即通过既有公开 `SYNO.FileStation.BackgroundTask.list` v3 读取前 100 项复制/移动、删除、压缩和解压任务，每 30 秒严格单飞刷新；超限明确提示截断，失败保留旧 NAS 快照与 App 传输，离页、profile/Repository 切换或 App 进入后台会取消读取并隔离迟到结果。展示层不暴露路径、参数或任务 ID，结束态只提示核对而不冒充成功；NAS 项不提供取消、清理或重试，`clear_finished` 保持关闭。系统通知、后台常驻和跨重启恢复继续后置。本机 Activity 聚焦测试 12/12 通过，真实 iPhone/iPad、真实 NAS 字段与无障碍为 `PENDING_USER_VALIDATION`。
- 独立审查后已补齐离页取消、同 profile 新旧 Repository 观察代次隔离、缺省字节组合的进度回退和 VoiceOver 重复标题修正；最终 Activity 聚焦 14/14、DsmMobile 全量 450/450 通过。GitHub Apple Build run `31562039103` 已通过共享包测试、iPhone/iPad 通用应用构建、macOS 打包和产物上传，Repository Check run `31562039118` 已通过。
- 当前不做批量命令、删除已下载数据、RSS、文件优先级、BT 协议高级设置和设置写；交给 Mac App 或 DSM Web。

出口：每项写操作按能力和版本 gate；创建、暂停、继续和只移除任务分别具备稳定目标、防重复与回读测试，提交未知不重放。BTSearch 的临时搜索任务只做一次独立 best-effort 清理，清理失败不覆盖原始结果。

### M7：NAS 健康与服务只读摘要

- 核心：系统、连接、性能、容量、硬盘健康、更新检查与发布说明的只读摘要。
- 受限：套件、任务、日志、当前连接，以及 Container/VMM 资源健康的隐私白名单只读列表与详情。
- 当前不做：NAS 网络/时间/安全/硬件/账号/套件配置写，重启/关机，全 NAS 存储分析，Container/VMM 生命周期、删除、拉取、网络/映像写、VM 创建/编辑和控制台。
- iPhone 使用摘要 → 分类 → 详情；iPad 使用 Sidebar + 列表 + 详情。图表提供精确值、单位、图例和屏幕阅读器摘要。

出口：各只读分区独立降级，未知字段不泄密；所有排除的危险入口不可见或明确转交，并通过 Repository 零写请求测试。

### M8：iPad 当前范围生产力收口

- 仅对 M1–M7 已纳入的 iPad 能力完成紧凑/常规宽度切换，模拟器窄/宽窗口变化不丢状态。
- 为浏览、有限多选、Chat 撰写和只读详情提供键盘命令、指针状态、上下文菜单、拖放及触控可见替代动作。
- 单窗口为当前产品边界；不因键盘、指针或大屏存在而加入 VMM 控制台、长向导、批量运维或 NAS 设置写。

自动化出口：iPad Simulator 覆盖窄/宽布局、SplitView 折叠、焦点、键盘命令与拖放替代动作；真实分屏、旋转和外接输入列入 `PENDING_USER_VALIDATION`。

### 当前 DAG 外的后续候选

- **自动照片备份**：需重新评估整库权限、增量游标、后台准备、去重和 iCloud 语义；当前只有 PhotosPicker 主动导入。
- **后台文件传输与通知**：需审批后台 session、持久化 schema、隐私文案和真实系统调度；当前保持前台任务。
- **iPad 多窗口**：只在有明确独立窗口用户目标时开启，VMM 控制台不因此自动进入范围。
- **File Provider**：需独立 Target/entitlement/签名审批和可信远端变化契约；当前 App 内浏览与系统选择器是正式路径。

后续候选只有经用户明确批准、范围账本升级并建立独立里程碑后才实施；它们不是当前 `PENDING_USER_VALIDATION`，也不阻塞 M9-A。

### M9：自动化收口与后续用户发布验收

#### M9-A：当前范围自动化收口

- iPhone/iPad Simulator Debug/Release 构建、聚焦/全量测试与启动检查。
- 当前核心/受限页面的双语、本地化格式、五态、无障碍属性、Dynamic Type、减少动态效果、浅/深色。
- 用合成数据覆盖大目录可见窗口、大图库索引、长会话、长时间媒体、缓存上限和取消。
- 对当前不做项验证入口不可见或替代说明准确，并保证零危险请求。

#### M9-B：后续用户真机、真实 NAS 与发布验收

- Archive、正式签名、安装、启动、升级和当前范围的真机生命周期。
- VoiceOver、系统选择器、旋转/分屏、外接键盘/指针，以及当前范围内的前后台状态。
- 真实 NAS 的连接方式、权限、套件版本、受限写和未知结果。

M9-A 先完成；M9-B 由第 13 节生成用户测试清单。外部证据只阻塞相应能力的 `DEVICE_VERIFIED` 与发布声明，不回溯阻塞已完成的源码；DAG 外候选不混入本清单。

## 10. Codex 子 agent 文件边界

### 10.1 主 agent 监管、唯一集成 owner 写入

主 agent 不与实现 agent 同时写这些热点；每一波只可明确委派一个集成 owner，主 agent 负责独立复核和最终验收：

- 能力账本、阶段 DAG 与验收结论；
- `project.yml`、Info.plist、entitlements、Target、Package.swift 和生成工程；
- AppShell 路由与组合根；
- 共享领域/Repository 协议、请求契约和持久化 schema；
- 两份 Apple 本地化资源及跨端进度/平台矩阵；
- 全量构建、Mac 回归和最终差异审查。

### 10.2 推荐并行目录

| 波次 | Agent A | Agent B | Agent C |
| --- | --- | --- | --- |
| 1 | `Session/**` | 被委派的唯一集成 owner：`AppShell/**` + 单窗口状态 | `CommonUI/**` + 只读测试审查 |
| 2-A | 本波唯一集成 owner：Mutation/前台 Transfer 接口与 fixture | 状态机和结果语义 Tests | 独立安全审查；通过出口后才开 2-B |
| 2-B | M2：Activity/前台 Transfer/Platform Documents | M3：Files/Preview | M5-A：文字 Chat 核心 |
| 3-A | M4：Photos + PhotosPicker adapter | M6：Download Station | M7：只读 NAS/Container/VMM 摘要 |
| 3-B | M5-B：Chat 附件 | 对应 Photos/Chat/Transfer 回归测试 | 独立 QA；不得抢改生产文件 |
| 4 | iPad commands/drag/drop/宽度适配 | 当前范围集成测试 | 可访问性/本地化/性能只读复核 |

在 M0 拆分前，不得让多个 agent 同时修改 `MobileRootView.swift` 或 `MobileAppModel.swift`。本地化 agent 是资源文件唯一 owner；功能 agent 先获得资源键或提交键值清单。工程 owner 只通过 `project.yml` 更新生成配置。

当前范围中的证书、NAS 照片回收站和 Chat/Download 内部写必须由未参与实现的 agent 做只读对抗复核。若未来重新开启后台、跨 NAS、File Provider、Container/VMM/NAS 写，仍须另建高风险切片，不能复用本轮“只读/当前不做”的验收结论。

## 11. 自动化与构建门禁

每个切片先执行与改动直接相关的聚焦测试和可用模拟器构建；阶段里程碑、共享契约或 `apple/Packages/**` 变更再执行受影响的完整门禁。从仓库根目录执行共享检查：

```bash
git diff --check
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
swift test --package-path apple
```

由唯一工程 owner 生成并构建移动工程：

```bash
(
  cd apple/Apps/DsmMobile
  xcodegen generate

  xcodebuild \
    -project DsmMobile.xcodeproj \
    -scheme DsmMobile \
    -sdk iphonesimulator \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build
)
```

单元/UI 测试分别选择当前 Xcode 实际安装的 iPhone 与 iPad Simulator，不在文档锁死可能过期的设备名：

```bash
xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -destination 'platform=iOS Simulator,name=<available iPhone>' test

xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile \
  -destination 'platform=iOS Simulator,name=<available iPad>' test
```

若修改 `apple/Packages/**`，还必须执行以下无签名 DsmMac App + File Provider Extension 构建，证明只读基线没有被共享代码破坏：

```bash
xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj \
  -scheme DsmMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

模拟器通过不能替代当前范围的真机、签名、系统选择器和真实 NAS 验收。缺少设备或正式材料时记录 `PENDING_USER_VALIDATION` 后继续无依赖功能，不得把未运行项目写成通过，也不得跳过当前环境本可执行的相关测试。后台、File Provider、多窗口和自动备份未进入当前范围时不生成伪待办。

## 12. 自动化覆盖要求

### CM-01 / VM-01 多分区只读增量

CM-01 当前源码已覆盖容器、映像、网络、项目与事件五分区；VM-01 已覆盖虚拟机、主机、存储、网络、映像、保护与事件七分区。交互按移动端转换：iPhone 使用分区列表进入资源页，iPad 常规宽度使用侧栏与详情；容器和虚拟机主分区继续提供稳定枚举筛选，筛选后为空使用独立状态。每个附属分区独立呈现内容、空内容、不可用与失败，刷新失败保留旧成功值；Repository 换绑、profile 切换、离页与缓存清理均使用代次门拒绝旧结果。

共享 snapshot 只增加向后兼容的 unavailable/failed 分区集合，移动 wrapper 只保存窄 `@Sendable` 读取闭包。共享层严格校验命名根数组、项目完整性和稳定身份唯一性；主分区畸形整体失败，附属分区畸形只标记对应分区失败。认证与 OTP 进入明确的重新连接状态并阻断继续刷新。移动层不显示事件正文、绑定、真实路径、账号、内部 ID 或原始诊断，不新增 NAS 请求，不开放生命周期、删除、创建、映像/网络写或控制台。本机共享包 705 项 XCTest（2 项环境跳过）与 10 项 Swift Testing、DsmMobile 480/480、iPhone 模拟器测试构建、本地化、差异检查和 macOS App + File Provider 无签名回归构建已通过；最终功能分支 GitHub Apple Build run `31672028838` 已通过共享包测试、iPhone/iPad 通用应用构建、macOS 打包与产物上传，Repository Check run `31672028862` 已通过。真实 iPhone/iPad、真实 NAS、VoiceOver、最大动态文字、iPad 分栏、键盘与指针为 `PENDING_USER_VALIDATION`。

- 当前核心/受限 Feature 的状态机、分页、筛选、取消、恢复和错误映射单元测试。
- 当前范围内每个写操作的成功、部分、拒绝、提交未确认、提交后取消和回读不一致。
- 合成请求 fixture 验证 API 名、版本、方法、路径、参数、认证材料位置和 no-retry 策略。
- iPhone/iPad UI 测试覆盖五态、导航返回、Tab/Sidebar 状态、确认框和动态文字主流程。
- PHOTO-03A 的 PhotosPicker adapter 已用 fake 覆盖选择、取消、临时文件形成与清理；整库 PhotoKit 授权、增量游标和自动备份仍属 DAG 外候选，不建立伪自动化出口。
- 当前单窗口状态测试证明切换 profile 后 Route、筛选、选择和草稿不串用。
- 性能测试覆盖大目录可见窗口、合成照片索引、长聊天、缓存上限和快速滚动取消。
- 对 `MOBILE_EXCLUDED` 项验证无入口或有准确替代说明，并在 Repository/请求层断言零危险请求；不为其建立完整功能测试套件。
- 后台 URLSession、File Provider、多窗口和自动备份的测试要求只有在未来范围账本升级后才生效。

## 13. 后续用户真机与真实环境验证矩阵

本节只覆盖当前核心/受限能力，由主 agent 按功能批次转成短清单交给用户，不作为普通功能实现的前置条件。每项清单必须包含设备/系统/NAS 前提、编号步骤、预期结果、需回传的脱敏错误信息和受影响入口；未测试项保持 `PENDING_USER_VALIDATION`，不得声称通过。DAG 外候选不在此排队。

### 13.1 设备与界面

- 小屏与大屏 iPhone，纵屏和横屏。
- iPad mini 级、常规 11 英寸级和大屏级；纵/横屏。
- 当前系统支持的分屏比例与窄/宽布局；Stage Manager 只检查单窗口缩放，不验收多窗口。
- 浅/深色、英语/简中、最大动态文字、粗体文字、按钮形状、减少动态效果和 VoiceOver。
- iPad 外接键盘、指针、拖放、Command 菜单和焦点顺序。

### 13.2 生命周期与权限

- 前台/后台、系统挂起、系统终止、用户强制结束、设备重启和 App 升级；未完成的前台传输不得在重启后被自动重放。
- Wi-Fi/蜂窝切换、低数据、低电量、无网、慢网和存储不足。
- 已实现的 Document Picker/Exporter、分享 Sheet、QuickLook/PDFKit/AVKit、FILE-07 系统分享与管理链接系统分享，以及 PHOTO-03A PhotosPicker/iCloud-only 主动导入；分别验证完成、取消、授权失效和临时文件清理。
- 同一窗口切换 NAS 后，任务、选择、筛选和草稿不串用。

### 13.3 DSM

- 局域网、公网直连、QuickConnect 中继和证书变化。
- 普通账号、受限管理员、功能无权限、套件未安装和 capability 缺失。
- 当前记录的 DSM build + 套件完整版本；未记录环境的内部写必须关闭。
- 对已经实现的单文件上传、FILE-07 单对象分享链接创建、复制、系统分享、管理列表和单条撤销、FILE-03 单项新建文件夹/重命名、FILE-05 单文件/单文件夹同 NAS 复制/移动、FILE-09 单个文件/文件夹移入回收站与恢复、PHOTO-03A 单项导入、Chat 纯文字发送、Chat 本人消息删除，以及 Download 单任务创建/暂停/继续/只移除任务，验证成功、权限拒绝、冲突、超时、提交未知、取消后复查和回读不一致；未确认结果在核对前不得重放。永久删除、删除已下载数据、Chat 转发/关闭/提醒/定时/投票/服务端置顶、NAS 写和 Download 高级设置不进入本矩阵。

## 14. 关键风险

| 风险 | 处理 |
| --- | --- |
| 单体模型无法支持多模块 | M0 先机械拆分，之后才允许功能并行；不提前为多 Scene 扩张架构 |
| 移动范围再次膨胀为桌面清单 | 每个切片先核对第 3.3 节；后续/当前不做项无入口，新增 macOS 功能默认后续 |
| 前台传输被误认为后台常驻 | UI 明示离开 App 的影响；只恢复可证实状态，不能承诺无限运行 |
| Photos 权限过度 | 当前单次导入只用 PhotosPicker；自动备份另行产品与权限审批 |
| 把 iCloud 照片删除误作“释放本机空间” | 不实现该入口；交由系统“优化储存空间”，后台永不自动删除系统照片图库项目 |
| iPad 只按机型适配 | 依据实际宽度/size class；模拟器强制覆盖 Split View/宽度变化，Stage Manager 后置用户真机验证 |
| File Provider 被误作当前必做 | 当前正式路径是 App 内浏览和系统选择器；未来获批后仍只能按已验证只读契约实现 |
| 真机矩阵拖慢主功能 | 模拟器与聚焦自动化先形成闭环，外部项目记为 `PENDING_USER_VALIDATION`；只让未验证的高风险入口保持关闭 |
| Chat 后台即时承诺 | 无 APNs/NAS 推送时只保证前台实时和轮询降级 |
| 内部 API UI 先行导致误开放 | capability + compatibility + 版本 gate 在 ViewModel 之前完成 |
| 共享 Package 影响 macOS | 只做兼容增量并运行 Mac 回归；需要改 Mac App 时停止请求授权 |

## 15. Apple 官方平台依据

以下资料同时包含当前范围和 DAG 外候选所需的系统约束；列在此处不代表对应候选已经进入实现。

- [NavigationSplitView 在紧凑宽度自动折叠](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [SwiftUI WindowGroup 与多窗口](https://developer.apple.com/documentation/swiftui/windowgroup)
- [Replicated File Provider 可用于 iOS/macOS](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)
- [File Provider 变更跟踪](https://developer.apple.com/documentation/fileprovider/tracking-your-file-provider-s-changes)
- [后台 URLSession 下载与重建限制](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [后台 URLSession 任务取消原因](https://developer.apple.com/documentation/foundation/url-session-background-task-cancellation-reasons)
- [BGProcessingTask 由系统调度且可中断](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask)
- [选择后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [PhotosPicker 选择照片与视频](https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios)
- [PhotoKit 有限照片库隐私模型](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [iCloud Photos 删除与“优化储存空间”的系统语义](https://support.apple.com/en-us/104967)
- [iPad 多窗口支持](https://developer.apple.com/documentation/uikit/supporting-multiple-windows-on-ipad)
- [系统文档选择器访问沙盒外文件](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)
- [本地通知调度](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
