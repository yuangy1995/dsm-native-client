# Windows 对齐 macOS 功能开发计划

- 状态：实施中；认证、Files、Photos、Chat、Download Station 与本地设置已形成多批可用闭环，当前事实与验证等级以 `STATUS.md` 为准
- 上位计划：[macOS 功能对齐总控计划](MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)
- 目标技术栈：C#、WinUI 3、HttpClient、Windows Cloud Files API

## 1. 目标

在不修改 macOS 和 Android 的前提下，把 macOS 当前版本已有的业务能力、安全语义和失败恢复完整迁移到 Windows，并保持 Windows 用户熟悉的窗口、键鼠、触控、通知区域和文件资源管理器体验。

Windows 完成标准不是“Shell 中出现入口”，而是对应工作流达到总控计划定义的业务、安全、平台、状态、质量和验证六项等价。

## 2. 第 0 波立项时的 Windows 基线（历史快照）

本节保留计划启动时的源码库存，不代表当前工作树。当前 Windows 已完成的功能、最新 CI
与真实设备缺口见 `STATUS.md`、本计划后续里程碑和跨端账本；不得用本节的“浅层/未对齐”
覆盖后续已经验证的实现。

### 2.1 已有基础

| 领域 | 当前证据 | 已有边界 | 本计划起始证据等级 |
| --- | --- | --- | --- |
| 工程 | `LanStash.Domain`、`LanStash.Infrastructure`、`LanStash.App`、`LanStash.Tests` | 分层存在，但领域模型、Repository 和通用工作区仍是大文件 | 静态源码存在；本次未构建 |
| 登录 | `AppViewModel.cs`、`DsmConnectionResolver.cs`、`NasAddressParser.cs` | HTTPS、地址解析、OTP、资料恢复、自动登录 | 源码/测试路径存在；本次未复验 |
| QuickConnect | `DsmQuickConnectResolver.cs` | 直连/中继、官方域名限制和中继身份核对已有代码 | 源码/测试路径存在；Windows 设备未验证 |
| 安全存储 | `CredentialSessionStore.cs`、`CredentialPasswordStore.cs` | 会话和可选密码进入 Credential Locker，非秘密资料单独保存 | 源码/测试路径存在；Windows 运行时未验证 |
| 本地化 | `LocalizationService.cs`、英语/简中 `.resw` | 系统语言、App 内选择、回退英语和持久化已有 | 源码/资源存在；本次未复验 |
| Shell | `ShellPage.xaml` | `NavigationView` 与模块入口、退出确认 | 静态源码存在；UI/设备未验证 |
| 文件 | `DsmRepository.cs`、`WorkspaceViewModel.cs` | 共享/目录列表、搜索、新建文件夹、重命名、单项删除的基础切片 | 浅层源码，未对齐 |
| Photos | `WorkspaceViewModel.cs` | 只筛出 `/photo` 第一页非目录项目，不是照片管理实现 | 占位/浅层源码 |
| Chat | `LoadConversationsAsync` | 只有会话列表，没有消息工作流 | 占位/浅层源码 |
| Download Station | `DsmRepository.cs` | URL 创建、列表、暂停/继续/删除的基础切片 | 浅层源码，未对齐 |
| Container/VMM | `DsmRepository.cs` | 通用列表与少量生命周期/删除/网络操作；无完整详情或向导 | 内部 API 浅层源码；设备写未验证 |
| NAS 设置 | `LoadNasSettingsAsync` | 少数类别的浅层只读聚合 | 浅层源码，未对齐 |
| 写结果 | `MutationResult.cs` | 类型已存在，尚未完整接入实际 Repository 调用链 | 类型存在，未形成端到端证据 |
| Cloud Files | `CloudDrive/**`、`DesktopCloudDrive*.cs` | 同步根、占位、分段读取、固定/释放、缓存、名称兼容与恢复原型；普通应用创建/修改是否安全失败尚未证明 | 源码/部分测试路径存在；Explorer/设备未验证 |
| 窗口生命周期 | `MainWindow.xaml.cs`、`TrayIcon.cs` | 关闭隐藏到通知区域、打开、云盘暂停/恢复和显式退出 | 静态源码存在；Windows 生命周期未验证 |

`windows/README.md` 中“已接入”的模块描述只代表入口或基础切片，不能据此标记为 macOS 对齐。实时测试数量以 `docs/progress/STATUS.md` 为准，但 README、STATUS 或平台矩阵都不能在没有可复现命令/设备记录时自行提升验证等级。

### 2.2 结构性问题

- `Models.cs`、`IDsmRepository`、`DsmRepository.cs`、`WorkspaceViewModel.cs` 和 `WorkspacePage` 聚合过多领域，不利于 typed model、专项状态和多 agent 并行。
- 多个模块使用 `ResourceItem + Metadata` 或宽松 JSON 猜测，容易丢失权限、状态和字段白名单语义。
- 现有页面主要只有“加载/消息/列表”，没有加载、空内容、筛选空、错误、正常五态。
- `MutationResult` 没有贯穿确认、提交、防重复、回读和部分成功。
- Cloud Files 的 Range 读取需要补齐 `206 Content-Range`、起点、总长度和内容版本一致性校验，避免远端变化时拼接不一致。
- 当前 WinUI 工程是 unpackaged，`WindowsPackageType=None`；安装、更新、通知激活、启动注册和卸载清理必须按当前发布形态分别验证。

## 3. 不变量与非目标

### 3.1 必须保持

- `profileId` 是凭据、证书、能力、模块、导航、缓存、传输和本地状态的隔离边界。
- API 固定选择已验证的版本；不能简单使用能力返回的最高版本。
- 官方公开 API 与内部 API 使用不同 Adapter 或至少物理文件边界。内部只读必须有兼容记录和能力探测，失败时独立降级；内部写在未知 DSM build/套件版本默认关闭。QuickConnect 按登录前服务契约、官方域名和身份校验单独管理，不能套用登录后 DSM build 门。
- 批量写操作只移除已确认成功的选择；部分成功、提交未确认和取消后复查必须保留。
- Cloud Files 的目标仍是只读，但当前尚未证明普通应用创建/修改会安全失败；W1-C 补齐并实机证明创建、写入、改名、删除均不会写回 NAS 前，不能宣传为完整只读同步根或双向同步。
- 凭据和远端真实路径不得进入 UI 诊断、通知、剪贴板、同步根 identity 或普通设置。

### 3.2 当前不做

- 不实现 macOS 尚未完成的完整 Container 创建/Compose/终端、VMM 高级迁移、Chat 加密等候选能力。
- 不在本计划中改为 MSIX、改变 Identity、签名或最低版本；若发布验收证明 unpackaged 形态无法满足需求，单独提交必要性、迁移和回滚方案取得用户批准。
- 不新增第三方 UI、MVVM、媒体或测试依赖。确需新增时先走审批，不以“提高效率”为由默认引入。
- `LanStash.Application` 已在第 0 波因 WinUI 可执行工程无法作为稳定 xUnit 宿主而建立：它是 Windows 目标的非 WinUI 应用逻辑程序集，只引用 Domain 与 Windows App SDK，App 和 Tests 单向引用它；不得反向引用 Infrastructure，也不得成为第二套平台资源或 Repository 实现。`LanStash.CloudFiles` 仍不新建，进一步物理迁移源码需单独整理并保持工程边界测试。

### 3.3 功能优先与后置 Windows 验证

每个切片先交付用户可完成的主流程、必要状态、双语资源和聚焦自动化，再补不影响主流程的边缘场景、体验微调与性能强化。只实现当前契约和已知故障要求的校验；不为假设中的罕见环境预先增加平行 Adapter、重复 fallback 或大范围抽象。

真实 Windows 10/11、ARM64、Explorer、Office/记事本自动保存、通知注册、托盘生命周期、外置磁盘、安装生命周期和真实 NAS 才能完成的调试，统一记为 `PENDING_USER_VALIDATION`。该标签只是账本待办，不是验证等级；当前可执行的源码审查、合成 fixture、xUnit、XAML/目标架构构建完成后，不依赖这些结果的功能可以继续。用户后续按第 9 节集中测试，Agent 根据可复现结果优先修复并补回归。

凭据、证书、Cloud Files 内容完整性和危险写规则不后置。未经真实验证会造成数据损坏或系统副作用的入口保持关闭或受能力开关保护，但只阻塞该入口启用、`DEVICE_VERIFIED` 和发布声明，不阻塞 Files、Photos、Chat 等独立功能。

## 4. 目标代码结构

在保持当前 solution 分层的前提下，逐步形成以下目录边界：

```text
windows/src/LanStash.Domain/
  Auth/ Files/ Photos/ Chat/ Downloads/ Containers/ VirtualMachines/ NasAdmin/
  Mutations/ Transfers/ DesktopCloudDrive/

windows/src/LanStash.Infrastructure/
  Transport/ Auth/ Capability/
  Features/<同名领域>/PublicApi/
  Features/<同名领域>/PrivateApi/
  Storage/

windows/src/LanStash.Application/
  非 WinUI 的 ViewModel、状态、协调器与可测试应用逻辑
  仅依赖 Domain；Windows 平台适配通过窄接口注入

windows/src/LanStash.App/
  Shell/
  Features/<领域>/Pages/
  Features/<领域>/ViewModels/
  Platform/Pickers/
  Platform/Notifications/
  Platform/Windowing/
  Platform/DragDrop/
  CloudDrive/

windows/tests/LanStash.Tests/
  Auth/ Files/ Photos/ Chat/ Services/ NasAdmin/ Transfers/ CloudDrive/
```

实施约束：

- `IDsmRepository` 在 W1 先以兼容 facade 保留，新增聚焦接口后再逐调用方迁移；不能一次性重写全部调用链。
- `LanStash.Application` 与 App 的源码归属清单必须由工程边界测试保持一一对应；生产本地化只走 PRI/`ResourceLoader`，无宿主测试使用注入的测试平台，不得嵌入第二份 `.resw` 作为生产 fallback。
- 大类可以改为 `partial` 并先做无行为变化的机械拆分；机械拆分和功能改造不得混在同一切片。
- UI 只依赖 typed ViewModel 状态，不直接解析 JSON 或调用 DSM API。
- Cloud Files 回调不引用 WinUI 控件，只向平台无关协调器报告状态。
- 所有写操作进入统一协调器：能力检查 → 权限/存在性/状态预检与影响摘要 → 仅危险操作确认 → 获取稳定目标锁 → 再次预检 → 单次提交 → 持久记录“已提交、禁止自动重放” → 最终状态回读 → `MutationResult`。不得在等待用户确认时长期占锁。
- App 字节传输与 NAS 服务器后台任务使用不同数据源，展示层再统一到活动中心。

## 5. WinUI 原生体验映射

| macOS 交互 | Windows 方案 |
| --- | --- |
| 工作区侧栏 | `NavigationView` 左侧 Auto 模式，按“内容、消息、任务与服务、NAS、设置”分组；不随页面重建 |
| 路径与返回 | `BreadcrumbBar` + BackStack；支持 `Alt+Left`、`Alt+Up`，返回恢复选择、滚动、排序和筛选 |
| 文件列表/图标 | 采用锁定 Windows App SDK 可用的原生虚拟化控件；列表/网格共用选择模型，禁止两套状态 |
| 工具栏 | `CommandBar`，当前场景主操作可见，低频动作进入 overflow；危险动作与普通动作分隔 |
| 多选 | `Extended` 选择、Ctrl/Shift/Ctrl+A、触控“选择”入口；右键不破坏已有多选 |
| 上下文菜单 | 指针右键是快捷入口，所有关键动作同时存在于命令栏或详情面板 |
| 拖放 | 进程内只传 opaque token；目标高亮，落下后才做权限、同名和父子路径检查 |
| 文件导入导出 | Windows 系统文件/文件夹选择器；系统拖入只接收用户授权的 `StorageItem` |
| 详情/属性 | 宽窗口右侧 Inspector，窄窗口使用对话框或独立窗口；技术字段默认折叠 |
| 图片/媒体预览 | 独立 `AppWindow` 或宽窗详情区，支持键盘前后、缩放、旋转、全屏和明确关闭 |
| VMM 控制台 | 短生命周期独立 `AppWindow`；连接状态、键盘捕获和退出路径可见，token 不进入 URL/日志 |
| 通知 | 原型验证后使用 Windows App SDK App Notification；正文只显示通用结果，点击恢复到活动中心 |
| 后台 | 首版为通知区域驻留 + 安全任务持久化/启动恢复，不把驻留进程宣传成系统后台任务 |
| 动效 | 使用 Fluent 原生导航和内容过渡，通常 150–250ms；遵循系统关闭动画设置，无装饰性循环 |
| 无障碍 | Narrator 名称/角色/状态、可见焦点、高对比度、键盘完整可达和 100–200% 缩放 |

`ui-ux-pro-max` 生成的 Web 字体、Bento 营销布局、GSAP 和夸张大标题与 WinUI 冲突，明确舍弃。界面使用系统字体、Fluent 主题资源和系统图标，不新增运行时设计依赖。

## 6. 分阶段实施 DAG

```text
W0 基线、账本与 ZIP/安装器决策门
  └─ W1 机械拆分 + Auth/Capability/Mutation/Workspace 基础
       └─ W1-R FileRangeReadResult / 内容版本契约冻结
            ├─ W1-C Cloud Files 完整性与回归护栏
            └─ W2 Files + Transfers + Pickers
                 ├─ W3-A Preview + Photos
                 ├─ W3-B1 Chat 核心
                 ├─ W4-A Download Station + Container Manager
                 ├─ W4-B VMM + Console
                 └─ W4-C NAS Administration
  W2 + W3-B1 + 必要预览接口冻结 ─ W3-B2 Chat Attachments
  各功能自动化出口 ─ W5-A 页面级 Windows 体验收口（可逐功能并行）
  W1-C + 系统集成代码 ─ W5-B Cloud Files / 通知 / 托盘开放门
  W5-A + W5-B 自动化出口 ─ W6 后续用户双架构、交付生命周期与发布验收
```

### W0：冻结事实基线

工作项：

- 从总控计划复制本次 Windows 对齐账本，逐行补 macOS 源码/测试、API 类型、证据等级和 Windows 当前状态。
- 对 Windows 当前请求做合成快照，确认 API 名、版本、方法、路径、参数、认证材料位置和安全策略。
- 给现有入口标记“完整、部分、占位、关闭”，纠正 README 或进度中的模糊描述。
- 为所有共享热点指定 owner，记录用户现有工作区改动。
- 冻结交付形态：默认仍是 framework-dependent ZIP 的解压部署/覆盖更新/用户主动清理；若希望 installer、self-contained 或 MSIX，先提交依赖、Identity、迁移、回滚和签名方案并取得用户批准。

出口：每个切片都能追溯到固定 macOS 基线；默认 ZIP 与术语边界已冻结，没有把内部候选或未实机功能当稳定功能。干净机安装、覆盖和清理验证留到 W6，不阻塞 W1。

### W1：基础分层、认证与写操作结果

工作项：

- 先对大文件做有测试保护的机械拆分，建立功能目录和聚焦 Repository 接口。
- 补自签名证书审阅、按 profile 指纹绑定、证书变化阻断和系统信任优先；只有结构/有效期合格的叶证书可固定，变化时展示旧/新指纹，QuickConnect relay 只走系统信任，路由发现阶段不发送登录凭据。
- 在 Shell 中加入多 NAS 新建、切换、管理和当前连接方式提示；切换与退出登录分离。
- 固定已验证 API 版本、typed response、响应大小/字段白名单和错误映射。
- 将 `MutationResult` 接入至少一个低风险和一个高风险试点，再迁移其余写操作。
- 建立按 profile 隔离的 NavigationState、ModuleAvailability 和恢复模型。

出口：

- 登录、OTP、取消、恢复、证书首次核对/变化、QuickConnect 身份不匹配均有单元测试。
- 能力不可用有用户原因和下一步，不静默隐藏。
- 成功、部分成功、权限拒绝、提交未确认和取消后复查可由 ViewModel 稳定呈现。
- 有可用 Windows 环境或 CI 时完成 x64/arm64 目标编译；当前无法执行时记录“尚未取得 `BUILD_VERIFIED`（待 Windows CI/环境）”，不阻塞仅依赖已冻结接口与聚焦测试的 W1-R/W2；没有改变发布身份或包形态。只有需要用户设备操作的项目才标记 `PENDING_USER_VALIDATION`。

第 1 波已完成并合并 W1 证书主链：每个连接尝试独立 handler/client，合格自签名首次核对、按 profile 指纹、变化阻断、relay 仅系统信任、稳定连接来源、全部 NAS 请求的 profile/source 上下文，以及原生可访问核对对话框。未参与实现者的源码对抗终审无开放 P0/P1；最终第 1 波提交已通过 GitHub Windows Build，xUnit 与 WinUI x64/arm64 构建均通过。真实 Windows 设备、证书环境与真实 NAS 仍为 `PENDING_USER_VALIDATION`。

### W1-R：Range 与内容版本契约冻结

- 由 `windows/src/LanStash.Infrastructure/DsmApiClient.cs` 唯一 owner 建立 typed `FileRangeReadResult`，至少包含状态码、请求/响应 Range 起点与长度、总长度、实际字节数及服务端可证明的内容版本。
- 删除“非 206 后在客户端跳过字节”的宽松语义；状态码、`Content-Range` 或长度不一致必须失败。
- 若公开响应无法提供跨分段一致性依据，契约返回明确“不可安全分段”，调用方只能整段读取或降级，不能从路径、时间或本地缓存推断版本。
- 先冻结接口、合成 fixture 与测试，再允许 Cloud Files owner 实施 W1-C，避免 Auth/Transport 与 Cloud Files 同时修改同一文件。

出口：契约审查和请求测试通过；所有消费方只依赖冻结结果，不再解析原始响应。

### W1-C：Cloud Files 完整性护栏

此切片和普通 Files UI 分开，由独占 owner 处理：

- 严格验证 `206`、`Content-Range` 起点/总长度、实际字节数和远端内容版本。
- 远端版本改变时终止本次水合，不能把不同版本片段拼成一个文件。
- 若 W1-R 判断当前公开响应不能证明跨分段版本一致，停止多段水合并明确降级。
- 以合成状态机回归同步根、占位分页、取消、固定/释放、空间预检、LRU、非法名称、大小写冲突和恢复事务；外置 NTFS、拔插、Explorer/系统重启移入第 9 节用户实测。
- 补齐本地创建、普通写入/截断、自动保存、改名、删除的安全拒绝；不得留下用户可见且无法同步的本地分叉，任何路径都不能产生 NAS 写回副作用。实现所需临时区只能保存可清理且不向用户冒充已同步的数据。
- 最小共享会话不得包含密码，诊断不得包含同步根真实路径或远端路径。

代码安全出口：领域测试和当前可用架构验证 P/Invoke 结构体大小/偏移、常量、确定的回调序列和 `CfExecute` 终态恰好一次；W1-R 无法证明跨段版本一致时禁用多段水合。该出口通过后可继续 W2 等独立模块。

实机开放出口：Word、记事本和直接 Win32 在真实 Explorer 同步根执行创建、写入、自动保存、改名、删除均安全失败且 NAS 无副作用；真实 ARM64、重启和磁盘拔插另行记录。缺少这些证据时标记 `PENDING_USER_VALIDATION`，Cloud Files 不默认注册、不宣传可安全使用，也不能取得 `DEVICE_VERIFIED`；该限制不阻塞其他功能。

### W2：File Station 与传输闭环

工作项：

- 分页、目录历史、面包屑、列表/网格、排序、分组、筛选、递归搜索。
- 收藏、最近、回收站、远程位置、分享链接和当前账号可见空间；公开 VirtualFolder 浏览与内部挂载管理分离，内部创建/修改/断开在未知环境关闭。
- 系统选择器上传、文件/文件夹/批量下载、取消和可解释恢复。下载仅在严格 Range 验证后续传；公开上传没有 offset 契约时暂停后只能“从头重试”，不得显示断点继续。
- 复制/移动、跨 NAS 有界流、同名预检、跳过/替换、拖放和限时撤销。
- ZIP/7z 压缩解压、密码、编码、目录结构和覆盖保护。
- 新建/重命名/删除/恢复/分享全部接入统一写操作协调器。
- App 传输与 NAS 后台任务进入同一活动中心但保留来源和不同控制能力。

出口：核心文件工作流达到总控账本范围；用 fake/合成 fixture 自动覆盖 profile 隔离、超时、权限结果、部分成功、提交未知和禁止重放，UI 五态完整。真实多 NAS、弱网、服务端权限和副作用列入第 9 节用户验证，不用 mock 冒充环境结论。

第 1 波已完成 W2 中 FILE-03 的单项新建文件夹/重命名：固定公开 CreateFolder/Rename v2 与 CheckPermission v3，完整严格列表预检、源/目标互斥、一次提交、独立回读、session review blocker、remote/recycle/`#recycle` 三层零写门和 WinUI 原生表单。该结果不包含复制移动、删除、恢复或批量写；云端 Windows 构建已随第 1 波通过，真实 NAS 行为和 Windows 设备交互仍为后置验证。

第 2 波已完成 W2 中 FILE-05 的单文件同 NAS 复制/移动：固定 CopyMove v3、普通本地共享根写前门、完整源/目标预检、无覆盖、一次提交、任务轮询、独立回读和跨页面 review blocker；WinUI 使用独立 partial 与 ViewModel 选择目标目录。最终提交 `1c7ee4851feb00903327b0599a0d29ea421be8c9` 的 Windows Build 已通过 815/815 xUnit，WinUI x64 与 ARM64 均 0 警告、0 错误；目录、批量、跨 NAS、覆盖、删除和恢复仍关闭，真实 NAS 与 Windows 设备交互继续后置验收。

FILE-05 单文件夹增量切片已完成源码、本机与云端构建闭环：继续使用同一公开 CopyMove v3，不新增 NAS 请求或平行写协调器。源文件夹必须是普通本地可变路径，复制/移动目标必须位于同一 NAS 的普通本地可写目录；目标选择器排除源文件夹及其后代，Repository 也在提交前拒绝相同目标和后代目标。写前仍执行本地挂载、完整源/目标、权限和同名预检；越过 start transport 后仍只提交一次，取消、断线或未知结果只做独立回读并保留会话 blocker。目录身份冻结使用路径、名称、类型和修改时间，复制回读要求源目录与目标目录同时存在，移动回读要求源目录消失且目标目录存在；不使用非稳定目录大小证明结果。本机 Files CopyMove 聚焦 42/42、Release 完整 xUnit 979/979、本地化检查、RESW/XAML XML 解析和差异检查已通过；GitHub Windows Build run `31460563136` 通过 979/979 项 xUnit 与 WinUI x64/ARM64 0 警告、0 错误构建，Repository Check run `31460563100` 已通过。批量、跨 NAS、覆盖、拖放、撤销、目录回收站操作以及真实 NAS 递归副作用不在本切片；真实 Windows/Narrator/高对比/缩放/窄窗口/键盘/触控继续记为 `PENDING_USER_VALIDATION`。

FILE-05 有界多项同 NAS 复制/移动在既有单项安全链上形成源码、本机与云端构建闭环：Windows Files 通过独立命令进入原生多选，在当前已加载目录选择 1～20 个普通文件或文件夹，一次选择同 NAS 普通本地可写目标后严格串行复用公开 CopyMove v3；不新增 NAS 请求、批量 transport 或平行写协调器。选择冻结完整 `FileItem` 快照，拒绝重复路径、目标不区分大小写同名、不可删除移动项、父子同时选择、当前源父目录，以及任一源文件夹自身或后代目标；Repository 继续对每项执行普通本地挂载、源身份、目标同名、权限、一次提交、任务轮询和独立回读。明确成功继续下一项，明确失败/权限不足/不支持计入失败后继续；提交未知、提交后取消、部分结果或异常写入现有会话 review blocker 并立即停止余项，绝不重放。提交前取消同样停止余项；结束以已选、确认、待核对、失败、取消和未开始六类守恒计数反馈，当前源目录最多刷新一次。WinUI 使用 CommandBar、ContentDialog、48 px 操作目标、键盘可达目标树和独立 polite/assertive live region；文案已进入英语与简体中文资源。本机 CopyMove/页面聚焦 61/61、Release 完整 xUnit 1119/1119、本地化、XAML/RESW XML 与差异检查已通过；本机 App 构建完成 Domain/Infrastructure/Application 后按预期停在 macOS 无法执行 Windows `XamlCompiler.exe`，不写成 WinUI 构建通过。GitHub Windows Build `31499596428` 已通过 1119/1119 项 xUnit，WinUI x64/ARM64 均为 0 警告、0 错误，Repository Check `31499596365` 已通过。跨目录来源选择、超过 20 项、跨 NAS、覆盖/自动改名、并行、拖放移动、撤销、后台/跨重启恢复和自动重试不在本切片；真实 NAS 部分副作用、断线/取消竞态、Narrator、高对比、200% 缩放、窄窗口、键鼠和触控为 `PENDING_USER_VALIDATION`。

FILE-09 单文件夹回收站增量已补齐：Windows Files 允许单个普通本地文件夹移入已发现的同共享 `#recycle`，并允许在回收站中恢复可解析原路径的单个文件夹。实现复用既有公开 Delete v2、CopyMove v3、List/GetInfo v2 与 CheckPermission v3，不改变 transport 或公共请求 fixture。确认前冻结 profile、源路径、名称、目录类型、修改时间、当前父目录和 recycle location；Repository 提交前重新读取源目录和当前删除权限，恢复另检查原父目录及目标写权限，同名目标、身份变化或权限消失均零写入；父文件夹与后代项目按路径祖先关系互斥，兄弟项目不受影响。越过 start transport 后仍只提交一次，取消、断线和任务或回读异常进入 session blocker，只做独立回读而不重放。确认成功要求源路径消失、目标路径出现同名同类型且修改时间一致的目录；目录大小不作为递归内容证明。WinUI 使用原生命令栏和 ContentDialog，文件夹确认文案明确其内容会一同移动或恢复，并提供双语 Narrator 名称。本机 Files Recycle 聚焦 21/21、Release 完整 xUnit 985/985、本地化检查、RESW/XAML XML 解析和差异检查已通过；首次完整运行的无关 Preview 时序测试单项与整套原样重跑通过，未修改 Preview 源码。GitHub Windows Build `31462403976` 已通过 985/985 与 WinUI x64/ARM64 0 警告、0 错误，Repository Check `31462403992` 已通过。Apple 移动端与 Photos 保持首片普通文件范围；永久删除、清空回收站、批量、覆盖恢复、跨 NAS 和递归内容逐项验证不在本切片。真实 NAS 目录副作用、同名策略及真实 Windows/Narrator/高对比/缩放/窄窗口/键盘/触控继续记为 `PENDING_USER_VALIDATION`。

FILE-09 有界多项移入回收站已形成源码、本机自动化与云端构建闭环：Windows Files 允许从当前已加载的普通本地目录选择 1～20 个有删除权限的普通文件或文件夹，一次确认后严格串行复用现有 `IFileRecycleRepository.MoveToRecycleAsync`，不新增 NAS 请求或批量 transport。选择冻结完整 `FileItem` 与已发现的同共享回收站位置，拒绝重复路径、不区分大小写同名、父子同时选择、混合父目录、远程/回收站来源和缺失回收站位置；Repository 继续逐项执行身份、权限、同名、一次提交、任务轮询与独立回读。明确失败、权限不足或不支持计数后继续；提交前取消停止；提交未知、提交后取消、部分结果、畸形成功或异常写入现有会话 blocker 并立即停止余项，不重放。WinUI 复用原生多选和 ContentDialog，提供一次确认、确定进度、取消及已选/确认/待核对/失败/取消/未开始六类守恒汇总，当前源目录最多刷新一次。本机 Recycle 聚焦 38/38、Release 完整 xUnit 1139/1139、本地化、XAML/RESW XML 与差异检查已通过；GitHub Windows Build `31503017192` 已通过 1139/1139 项 xUnit，WinUI x64/ARM64 均为 0 警告、0 错误，Repository Check `31503017593` 已通过。批量恢复、永久删除、清空回收站、覆盖、跨目录/跨 NAS、并行、撤销、自动重试和后台恢复不在本切片；真实 NAS 文件夹递归与部分副作用、取消/断线竞态，以及真实 Windows/Narrator、高对比、200% 缩放、窄窗口、键鼠/触控为 `PENDING_USER_VALIDATION`。

FILE-07 分享链接管理增量已补齐：Windows Files 复用既有公开 Sharing v3 `list`/`delete` 合成契约与创建链接的严格解析，不新增私有 API 或 NAS 请求类型。管理对话框覆盖加载、空、错误、不可用、列表、确认、删除中和八态结果，本地每次展开 100 条，最多处理严格分页读取的 5,000 条；列表只显示路径、密码保护状态和到期日，密码本身不进入领域模型、界面、剪贴板或日志。单条撤销冻结稳定 ID、路径、URL、密码状态和到期日，提交前重新读取完整列表；目标缺失或变化零写入，同 ID 在途互斥，传输层固定 v3 form 且只执行一次 `SendAsync`。提交后取消、网络或响应不明进入按 API 会话/profile/稳定 ID 保存的内存复核门，跨页面或 Repository 重建只读列表，绝不重放；只有稳定 ID 已消失才确认成功。复制继续复用 Windows 不漫游、默认不进入历史的剪贴板实现。本机 Files Sharing 聚焦 113/113、Release 完整 xUnit 1002/1002、本地化、RESW/XAML XML 与差异检查已通过；GitHub Windows Build `31465173331` 已通过 1002/1002 与 WinUI x64/ARM64，Repository Check `31465173335` 已通过。批量撤销、编辑密码/到期日、跨 NAS 汇总、Photos 管理入口与 Apple 移动端扩展不在本切片。真实 NAS 撤销传播/权限/断线及真实 Windows/Narrator/高对比/200% 缩放/窄窗口/键盘/触控继续记为 `PENDING_USER_VALIDATION`。

FILE-04 有界多文件上传增量在既有单文件闭环上继续推进：Windows Files 的当前窗口系统选择器和 Explorer 拖放可一次接收 1～20 个具有真实本机路径的普通文件。整批开始前冻结 profile、目标目录与路径快照，并原子检查数量、路径、同名目标和既有在途目标；任一冲突均零上传。上传严格串行，每次只打开一个只读共享源流，继续使用 `overwrite=false`、ForegroundTransfer、一次 `UploadFileAsync` 和 typed `MutationResult`；每个文件拥有独立 Activity 与取消入口，提交前或提交后取消均停止余项，提交后取消仍计入待核对且绝不重放，普通失败继续下一项。批次结束显示所选、成功、待核对、失败、取消和未开始计数，确认成功时只对未变化的当前目录刷新一次。非目标仍是文件夹上传、覆盖、并行洪泛、跨 NAS、后台/重启恢复、自动重试和断点续传。本机聚焦 53/53、Release 完整 xUnit 1049/1049、本地化、XML 与差异门禁已通过；既有 Preview 时序测试首次整套失败后原样单项及整套重跑通过，未修改 Preview 源码。GitHub Windows Build run `31487335182` 已通过 1049/1049 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31487335222` 已通过。真实 Explorer、在线占位文件、逐项取消、Narrator、高对比、100/150/200% 缩放、窄窗口、键鼠/触控和真实 NAS 为 `PENDING_USER_VALIDATION`。

FILE-04 有界文件夹上传增量继续复用公开 CreateFolder v2 和既有单文件上传链，不新增 NAS 请求：Windows Files 的当前窗口 FolderPicker 与 Explorer 拖放可接收一个具有真实本机路径的小文件夹；本地完整规划最多包含 20 个普通文件、20 个目录（含根目录）和 8 层（根目录为第 1 层），保留根目录、空目录和相对层级。确认前拒绝缺失或不可完整读取的来源、重解析点、非法名称、仅大小写不同的目标冲突及规划后变化；确认后按父目录优先创建，再严格串行上传文件，所有目录和文件目标提前预留且保持 `overwrite=false`。目录创建只有 typed 回读精确确认名称、路径和目录类型才继续；提交未知、异常或提交后取消立即停止余项并留下会话复核门，不自动回滚、重放或覆盖已确认项目。页面限制同一时刻一个文件夹批次，提供双语确认、批次取消与分类计数，文件仍进入 Activity，确认成功后当前目标最多刷新一次。本机规划、批次状态机与源码契约聚焦测试 76/76、Release 完整 xUnit 1072/1072、本地化、XAML/RESW/工程 XML、请求契约、脱敏 Fixture 与差异检查已通过；首次整套运行的既有 Preview 非协作读取时序测试失败，未修改 Preview 源码，原样单项及整套重跑均通过。macOS 上 WinUI App 构建按预期停在不可执行的 Windows `XamlCompiler.exe`，不能记为本机构建通过。功能分支 GitHub Windows Build run `31490234934` 已通过 1072/1072 项 xUnit 与 WinUI x64/ARM64 0 警告、0 错误构建，Repository Check run `31490234897` 已通过。多文件夹、更大目录树、符号链接、并行、后台/重启恢复、自动回滚、自动重试和断点续传不在本切片。真实 FolderPicker/Explorer 文件夹拖放、在线占位、取消和部分副作用、Narrator、高对比、100/150/200% 缩放、窄窗口、键鼠/触控及真实 NAS 为 `PENDING_USER_VALIDATION`。

FILE-04 有界多文件下载增量复用既有公开 Range 读取、强内容版本检查、ForegroundTransfer 与 Windows 事务目标，不新增 NAS 请求：Files 普通浏览仍保持单选，用户主动进入下载选择模式后可在当前已加载位置通过原生 ListView/GridView 复选 1～20 个普通文件；目录、重复远端路径、Windows 非法名称、不区分大小写的同名目标和越界选择均拒绝。导航、刷新、筛选、排序和位置切换会退出模式，列表/网格切换按远端路径恢复选择；模式内单项新建、重命名、复制移动、回收站、上传、预览和分享命令关闭。FolderPicker 返回后先检查目标目录中任一同名文件或文件夹，并原子预留全部本地目标；任一冲突时零 NAS 读取。有效批次严格串行，每项继续使用 4 MiB 有界 Range、固定总长度、强版本验证、事务 staging 和独立 Activity；批量提交固定 `FailIfExists`，即使预检后出现外部竞态也不覆盖。普通失败继续下一项，当前 Activity 或批次取消会停止余项；若取消发生在不可中断的本地原子提交阶段，当前文件按真实已保存结果计数但仍停止后续。批量下载使用独立 live region，不与上传状态或取消入口相互覆盖；页面提供双语选择计数、上限提示、批次取消和完成/失败/取消/未开始汇总，不刷新 NAS 列表。本机聚焦测试 67/67、Release 完整 xUnit 1084/1084、本地化、XAML/RESW/工程 XML、请求契约、脱敏 Fixture 与差异检查已通过；macOS 上 App 构建按预期停在不可执行的 Windows `XamlCompiler.exe`，不写成本机构建通过。GitHub Windows Build run `31492927848` 已通过 1084/1084 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31492927920` 已通过。文件夹/递归下载、覆盖/自动改名、并行、后台/跨重启恢复、自动重试和断点续传不在本切片；真实 FolderPicker、网络盘/可移动盘、目标竞态、取消、Narrator、高对比、200% 缩放、窄窗口、键鼠/触控和真实 NAS 为 `PENDING_USER_VALIDATION`。

FILE-04 单文件夹 ZIP 下载增量复用官方 `SYNO.FileStation.Download` v2，不调用 Compress、Search 或私有 API：用户在 Files 选中一个文件夹后使用既有下载按钮或 `Ctrl+S`，当前窗口 FileSavePicker 建议 `<文件夹名>.zip`，普通文件保存语义保持不变。Transport 固定 GET `download`、单元素 JSON 路径数组和 `mode=download`，能力覆盖 v2 才发送且不会随更高 MaxVersion 自动升级；不发送 Range、不自动重试。响应只接受 HTTP 200 的 `application/zip` 或 `application/octet-stream`，在首次本地写入前验证 ZIP 起始签名，并以 1 MiB 有界缓冲转发。内容先写同目录唯一 staging，传输结束后用 `ZipArchive` 读取并校验中央目录和条目起始结构，只有验证成功才沿用 SavePicker 已确认的替换语义一次发布；提交开始前取消、截断、错误媒体类型、无效 ZIP、磁盘或提交失败均清理 staging 并保留原目标。中央目录验证和原子发布进入不可取消阶段后按实际落盘结果结算，可能完成保存，但不会因迟到取消删除已发布目标。Activity 使用不确定进度、稳定显示名和既有取消入口，档案切换与 Dispose 继续传播取消。请求 Fixture、transport、事务服务和页面源码聚焦测试 84/84、Release 完整 xUnit 1107/1107、本地化、请求契约和差异检查已通过；本机 App 构建完成 C# 编译后按预期停在 macOS 无法执行的 Windows `XamlCompiler.exe`，不写成 WinUI 构建通过。首轮 GitHub Windows Build run `31495912902` 已通过 1107/1107 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31495912916` 已通过。多文件夹/混合选择、服务端 ZIP 断点续传、后台/跨重启恢复、自动重试、解压、密码和归档内容编辑不在本切片；真实 FileSavePicker 覆盖确认、空/超大/深层目录、DSM ZIP MIME 与分块响应、取消、截断、网络盘/可移动盘、磁盘满、Narrator、高对比、200% 缩放、键鼠/触控和真实 NAS 为 `PENDING_USER_VALIDATION`。

### W3-A：预览与文件系统照片库

工作项：

- 建立有界缩略图/预览缓存、可见窗口优先加载和离页取消。
- 图片、PDF、UTF 文本、Range 音视频预览；文本编辑、格式整理和未保存保护。
- 通过公开 File Station 扫描 `/home/Photos` 与 `/photo`，实现个人/共享空间、文件夹、时间线、文件夹式相册、分页、搜索和年/月定位。
- 已接入 Photos 文件夹/时间线媒体打开、右侧预览、前后切换、基础文件元数据、图片/基础视频尺寸、拍摄时间、相机品牌/型号、基础视频时长和保存副本；基础查看器提交 `4e1272e` 已通过 Windows xUnit、WinUI x64/ARM64 和 Repository Check。本地媒体元数据白名单切片不新增 NAS 请求，不读取位置、厂商私有、设备序列或镜头序列类隐私元数据；GitHub Windows Build run `31410536634` 已通过 943/943 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31410536680` 已通过。页面内沉浸式查看已提供 F11、左右方向键、Esc、焦点恢复、Ctrl+S 和双语自动化名称；该历史切片当时未使用系统级 `AppWindow` 全屏 presenter，GitHub Windows Build run `31414591711` 与 Repository Check run `31414591262` 已通过。
- PHOTO-02 系统全屏与媒体恢复增量已完成源码：F11 现在进入系统级 `AppWindow` 全屏，退出、关闭、离页、语言重建、注销、托盘隐藏和释放页面都会幂等恢复进入前的普通或最大化窗口状态；隐藏到托盘会暂停视频，恢复窗口不自动播放。媒体失败只在当前查看代次进入既有可恢复错误态，切换、关闭和释放都会退订并清理播放器。HEIC/HEIF/WebP 与 MKV/WebM 已进入安全预览白名单，缺少系统编解码器时仅显示不可用，仍可重试或保存副本；不新增 NAS 请求、第三方编解码器、编辑或智能照片能力。本机聚焦测试 100/100、Release 全量 xUnit 1164/1164、本地化和差异检查通过；GitHub Windows Build run `31513964648` 已通过 1164/1164 与 WinUI x64/ARM64 构建，Repository Check run `31513964640` 已通过。真实多显示器全屏、托盘暂停、格式/编解码器、Range 播放、Narrator、高对比、100/150/200% 缩放、窄窗口和键鼠/触控为 `PENDING_USER_VALIDATION`。
- PHOTO-03 单项普通媒体移入回收站增量已完成源码：Photos 文件夹网格和主动时间线只在当前 profile、普通图片/视频、稳定大小、Delete v2、已发现同共享回收站入口均有效且源不在 `#recycle` 时显示命令。页面每次重新进入都刷新既有只读位置快照，不自行拼接目标；位置发现失败显示双语重试。用户确认后先关闭预览，再核对选择、profile 和冻结映射；权限与源身份重读、一次提交、取消、提交未知只回读不重放及最终结果核对全部复用 FILE-09 typed 链，确认成功只刷新仍匹配的文件夹或时间线。本机相关聚焦 138/138、Release 全量 xUnit 1165/1165、本地化、XAML/RESW XML 和差异检查通过；GitHub Windows Build run `31516242228` 已通过 1165/1165 与 WinUI x64/ARM64 构建，Repository Check run `31516242282` 已通过。批量、永久删除、清空回收站、系统图库删除、跨 NAS、收藏写和查看器内独立动作不在本切片；真实 Windows/NAS 副作用、Narrator、高对比、200% 缩放和键鼠/触控为 `PENDING_USER_VALIDATION`。
- PHOTO-03 有界批量普通媒体移入回收站已完成源码和本机自动化：Photos 文件夹网格与主动时间线使用原生多选和同一确认/进度/汇总呈现，固定 1～20 项。文件夹模式保持同父目录规则；时间线显式使用照片空间根范围，允许混合父目录和不同目录同名，只接受根目录严格后代，并逐项消费自身已发现的回收站位置。确认前再次核对 profile、空间、选择、完整媒体版本和冻结位置；底层继续严格串行复用 FILE-09，每项一次提交，明确失败继续，未知、异常或提交后取消停止余项并写入会话复核门。切换空间、模式、搜索、筛选、刷新或离页会退出选择，不保留隐藏项目。本机聚焦 52/52、Release 完整 xUnit 1182/1182、本地化、XAML/RESW XML 与差异检查通过；本机 WinUI App 构建按预期停在不可执行的 Windows `XamlCompiler.exe`。Windows Build run `31537462070` 已通过 1182/1182 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31537463067` 已通过。批量恢复、永久删除、系统图库删除、跨 NAS、撤销和后台恢复不在本切片；真实 NAS/Windows、Narrator、高对比、200% 缩放、窄窗口和键鼠/触控为 `PENDING_USER_VALIDATION`。
- PHOTO-03 单项普通媒体同 NAS 移动增量已完成源码、本机自动化与云端构建：Photos 文件夹网格和主动时间线复用 W2/FILE-05 CopyMove v3 与同一原生目标文件夹选择器，只允许一个普通图片或视频移到同 NAS 普通本地可写文件夹，不新增请求、传输或平行协调器。真正提交前关闭预览并重核 profile、资料库、来源父目录、身份、删除权限、选择及完整版本；Repository 继续执行本地挂载、目标权限、同名冲突、防重复、一次提交、任务轮询和最终回读，提交未知只回读、不重放，确认成功只刷新仍匹配的来源视图。本机聚焦 110/110、Release 全量 xUnit 1168/1168、本地化、23 个 XAML/RESW XML 和差异检查通过；App 构建在 C# 依赖层后停于 macOS 无法执行 Windows `XamlCompiler.exe`，不写成本机构建通过。GitHub Windows Build run `31519022162` 已通过 1168/1168 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31519022189` 已通过。批量、复制、跨 NAS、覆盖、自动改名、撤销、后台/跨重启恢复、系统图库移动和查看器独立写入口不在本切片；真实 NAS/Windows、冲突与权限变化、断线取消、Narrator、高对比、200% 缩放、窄窗口和键鼠/触控为 `PENDING_USER_VALIDATION`。
- PHOTO-03 有界批量普通媒体同 NAS 移动已完成源码、本机自动化与云端构建：Photos 文件夹网格与主动时间线把移动/回收统一为一个原生多选会话，固定 1～20 项。文件夹模式保持当前目录；时间线显式冻结当前照片空间根并允许混合父目录，但同一目标下的大小写不敏感同名项目会拒绝。目标选择、无覆盖、来源/目标权限、同名冲突、防重复、一次提交、任务轮询和最终回读继续复用 FILE-05；批量层严格串行，明确失败继续，未知、异常或提交后取消停止余项并写入会话复核门。提交前重新核对 profile、空间、模式、来源根、完整媒体版本和当前选择；切换空间、模式、搜索、筛选、刷新或离页会清理选择。本机聚焦 56/56、Release xUnit 1193/1193、本地化、XAML/RESW XML 与差异检查通过；macOS WinUI App 构建停在不可执行的 Windows `XamlCompiler.exe`，不记为本机通过。Windows Build run `31540041995` 已通过 1193/1193 与 WinUI x64/ARM64 构建，Repository Check run `31540042025` 已通过。跨 NAS、覆盖、自动改名、撤销、后台恢复和系统图库移动不在本切片；真实 NAS/Windows、Narrator、高对比、200% 缩放、窄窗口和键鼠/触控为 `PENDING_USER_VALIDATION`。
- PHOTO-03 有界批量普通媒体同 NAS 复制已完成源码、本机自动化与云端构建：Photos 文件夹网格与主动时间线把复制/移动/回收统一为一个原生多选会话，固定 1～20 项。时间线仍只接受当前照片空间根的严格后代并允许混合父目录；同一无覆盖目标下的跨目录同名会拒绝。复制严格串行复用 FILE-05 的普通本地可写目标、权限/同名预检、防重复、一次提交、任务轮询和最终回读，不要求来源删除权限，也不刷新来源；明确失败继续，未知、异常或提交后取消停止余项并阻断重放。提交前重核 profile、空间、模式、根、版本和选择。本机聚焦 57/57、Release xUnit 1194/1194、本地化、XAML/RESW XML 与差异检查通过；Windows Build run `31541423773` 已通过 1194/1194 与 WinUI x64/ARM64 构建，Repository Check run `31541423774` 已通过。跨 NAS、覆盖、自动改名、撤销、后台恢复和系统图库复制不在本切片；真实 Windows/NAS、Narrator、高对比、200% 缩放、窄窗口和键鼠/触控为 `PENDING_USER_VALIDATION`。
- HEIC/MOV/Live Photo 能力探测与可解释降级，EXIF 只展示白名单字段。
- 上传、导出、分享、移动、删除和恢复复用 W2 传输/写操作。

PHOTO-02 图片预览控制增量已完成源码、本机与云端构建闭环：共享 `FilePreviewPane` 仅在图片准备完成后显示原生紧凑命令栏，提供 25%～400% 放大/缩小、适应查看区域、向左/向右 90 度旋转，以及 `Ctrl+加号/减号/0/L/R` 键盘入口；缩放百分比和旋转角度使用当前 App 语言格式并作为 polite live region 更新。切换项目、关闭或失败会复位缩放、滚动位置和角度；所有变换只存在当前预览内存，不修改本地临时产物或 NAS 文件，不新增 NAS 请求，也不影响视频、PDF 或文本预览。本机 .NET 10 已通过 Preview/Photos 聚焦 27/27、Release 全量 xUnit 1003/1003、本地化门禁和 XAML/RESW XML 解析；macOS 无法运行 WinUI `XamlCompiler.exe`，不把本机 App 构建写成通过。GitHub Windows Build run `31470288572` 已通过 1003/1003 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31470288573` 已通过。真实 Windows、Narrator、高对比、100/150/200% 缩放、窄窗口、鼠标滚轮、触控板和触屏为 `PENDING_USER_VALIDATION`。

PHOTO-03A 桌面拖放单项导入增量已完成源码、本机与云端构建闭环：Photos 文件夹与时间线页面只接受一个由 Windows 提供真实本机路径的 `StorageFile`，且扩展名必须属于既有图片/视频白名单；拖入有效项目时显示使用系统主题资源的原生投放框，无效的文件夹、多项目、无本机路径或非媒体项目零上传并给出双语恢复提示。页面仅把路径交给既有 `PhotoImportCoordinator`，继续冻结 profile、Repository、空间、目标路径、上下文代次和 Activity ID；传输层仍以只读共享打开单一源文件，`overwrite=false`，复用 ForegroundTransfer、一次上传、取消和 typed `MutationResult`，提交未知只进入 Activity 核对而不重放，确认成功只刷新未变化的原目标。该切片不新增 NAS 请求、批量/文件夹拖放、覆盖、后台上传或跨重启恢复。本机 .NET 10 已通过 Photo Import/Picker 聚焦 30/30、Release 全量 xUnit 1007/1007、本地化门禁、XAML/RESW XML 和差异检查；macOS App 构建按预期停在不可执行的 WinUI `XamlCompiler.exe`，不写成本机通过。GitHub Windows Build run `31472759838` 已通过 1007/1007 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31472759859` 已通过。真实 Explorer 拖放、在线占位文件、Narrator、高对比、100/150/200% 缩放、窄窗口、触控和真实 NAS 为 `PENDING_USER_VALIDATION`。

语义要求：界面必须称为文件系统照片库；真正 Synology Photos 相册、人物、地点、标签等内部能力仍关闭。

出口：大目录/大图库不在 UI 线程解码；缓存有上限；图片、视频、PDF、文本和不可支持格式均有状态测试。

### W3-B1：Chat 核心

工作项：

- typed 会话、用户、消息、成员和分页模型；首次单聊与非加密私人群聊。
- 草稿、本地置顶/已读、文字/Emoji、失败重试、删除本人消息和关闭会话。
- 消息转发、服务端消息置顶/取消置顶按各自内部能力 gate；语音发送和完整加密实现不在当前 parity 范围。
- Socket.IO 前台实时与轮询降级，离线/恢复/重复事件去重。
- 提醒、纯文字定时消息、投票当前 macOS 范围；每个内部写能力独立 gate。

出口：未记录 DSM build + Chat Server 完整版本时写入口关闭；Bot/Webhook 不替代普通用户 Chat；加密会话明确不支持而非明文降级。核心出口不依赖附件 UI。

CH7 局部进展：Windows Chat 已补入本地会话置顶/取消置顶，作为不依赖真实 Chat Server 的低风险源码闭环。用户目标是让常用会话在当前 NAS 档案下优先显示；移动到 Windows 的交互替代为会话列表行内图钉按钮、详情标题栏按钮和 `Ctrl+Shift+P` 快捷键，而不是 macOS 右键菜单的唯一入口。实现只在本机应用数据目录保存版本号和按 profile 隔离的会话 ID 顺序，不保存会话标题、成员、消息、路径、主机或响应正文；退出登录不清除偏好，删除 NAS 档案时清理对应置顶文件。官方 Star、群公告 `Post.pin/unpin`、消息置顶、服务器已读、实时 Socket.IO、成员管理、删除/关闭会话等仍按后续契约批次处理，不在本切片暗中开放。本机已安装 .NET 10 SDK，macOS 以 `AppxGeneratePriEnabled=false` 跑通完整 xUnit 957/957；未临时禁用 PRI 生成时 Windows SDK `MakePri.exe` 不能在 macOS 执行，App 项目本机构建进一步确认 WinUI `XamlCompiler.exe` 也不能在 macOS 执行。本切片 GitHub Windows Build run `31448827122` 已通过 957/957 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31448827088` 已通过；真实设备的 Narrator、高对比、缩放、窄窗口、触控和真实 Chat Server 刷新仍为 `PENDING_USER_VALIDATION`。

CH7 群成员只读切片已完成源码与云端构建闭环：Domain 新增独立 `Members` 读取能力和 typed Repository 方法，Infrastructure 仅在运行时发现 `SYNO.Chat.Channel.Member` 且版本覆盖 v1 时开放，固定发送一次 `get(channel_id)`，排除 `broken_user_ids` 并复用用户目录补齐名称、当前账号和停用状态。群聊标题栏提供成员按钮和 `Ctrl+Shift+M`，原生 ContentDialog/ListView 覆盖加载、空内容、错误、重试/刷新和正常列表，并提供双语 ToolTip 与 Narrator 名称；单聊或能力缺失时隐藏入口。成员按 profile/会话仅驻留内存，切换会话、档案或关闭页面会取消旧读取并拒绝迟到结果，成员失败不影响消息历史。该切片不新增头像二进制、持久化或写请求，不开放建群、邀请/移除、角色管理、官方 Star、群公告、服务器已读或实时同步。本机 .NET 10 已通过 Chat 聚焦 117/117 和完整 xUnit 968/968，XAML/RESW 解析也已通过；macOS 无法执行 WinUI `XamlCompiler.exe`，因此本机未运行 WinUI 应用构建。GitHub Windows Build run `31456211425` 已通过 968/968 项 xUnit 与 WinUI x64/ARM64 0 警告、0 错误构建，Repository Check run `31456211422` 已通过。真实 Windows、Narrator、高对比、100/150/200% 缩放、窄窗口、键盘/触控、成员权限差异、`broken_user_ids` 与真实 Chat Server 为 `PENDING_USER_VALIDATION`。

CH7 群公告只读切片已完成源码、本机与云端构建闭环：Domain 新增独立 `PinnedMessages` 能力和不含附件的 typed 公告模型，Infrastructure 仅在基础 Chat 可读且 `SYNO.Chat.Post` 精确覆盖 v5、请求格式为 FORM 时开放；固定发送一次 `search(channel_id, offset=0, limit=100, has=["pin"], sort_by=last_pin_at)`，兼容已记录的 `search_results`/`posts` 容器，拒绝显式跨会话记录，并按置顶时间倒序。入口只对未加密群聊显示，标题栏按钮、`Ctrl+Shift+N` 和原生 ContentDialog/ListView 覆盖加载、空、错误、重试/刷新与内容态。公告只在 profile/会话内存缓存中保留消息 ID、会话 ID、发送者、正文、发送时间和置顶时间；切换会话/档案、关闭弹窗或销毁页面会取消旧读取并拒绝迟到结果，失败不影响消息历史。不读取头像或附件，不持久化原始响应，不调用 `pin/unpin`，不开放公告管理、实时刷新或 Apple 移动端服务端置顶。本机 .NET 10 已通过 Chat 聚焦 124/124、Release 全量 xUnit 975/975、本地化门禁和 XAML/RESW XML 解析；GitHub Windows Build run `31459279684` 通过 975/975 项 xUnit与 WinUI x64/ARM64 0 警告、0 错误构建，Repository Check run `31459279618` 已通过。本机 macOS 未运行 WinUI `XamlCompiler.exe`。当前私有契约仍是 `observed/degraded`，真实 Chat Server 权限、空列表、排序、附件型公告和撤销后刷新，以及真实 Windows/Narrator/高对比/缩放/窄窗口/键盘/触控为 `PENDING_USER_VALIDATION`。

CH7 前台自动刷新切片已完成源码与聚焦自动化：`ChatPage` 仅在页面已加载且窗口可见时启动，首次进入沿用初始化读取，重新进入或从托盘恢复立即读取，此后每 30 秒严格单飞刷新会话，并在当前选择为未加密会话时顺序刷新消息。离页、窗口隐藏、切换 profile 或释放页面会取消会话与消息请求；代次门禁止旧会话阶段继续触发消息读取。失败保留已加载内容并沿用现有 InfoBar 与手动重试，不增加新文案。该切片复用现有只读端点，不接 Socket.IO、后台常驻、系统通知、服务器已读、成员/公告自动刷新或新 NAS 请求。本机 macOS 使用 .NET 10 且关闭 PRI 生成后 Chat 聚焦 63/63、Release 全量 xUnit 1178/1178 通过；GitHub Windows Build run `31531069884` 通过 1178/1178 项 xUnit 与 WinUI x64/ARM64 0 警告、0 错误构建，Repository Check run `31531069860` 已通过。真实 Chat Server、窗口/托盘生命周期、Narrator、键盘、高对比、200% 缩放、窄窗口和触控为 `PENDING_USER_VALIDATION`。

### W3-B2：Chat 附件

- 已在第 5 波按冻结的 `Post.create` v5 / `Post.File` v2 契约接入单附件上传/保存、按需图片缩略图和原生预览；不等待 W3-A 全部照片与格式验收。
- 取消和核对复用统一结果语义，不重复发送；临时文件、通知和诊断不得泄露消息、路径或附件正文。GitHub Windows Build `31384177338` 已通过 921/921 项 .NET xUnit 与 WinUI x64/ARM64 构建；真实 Chat Server、系统选择器和辅助功能仍待验收。

自动化出口：用 fake/合成 fixture 覆盖超时、取消、失败重试、会话切换、App 状态重建、去重和禁止重放，不遗留无界临时文件。真实弱网、服务端附件副作用和重启生命周期列入第 9 节 `PENDING_USER_VALIDATION`。

### W4-A：Download Station 与 Container Manager

Download Station：

- 列表/筛选/详情/进度/速度/目标和任务文件；任务文件导入必须复用已验收的 W2 Picker/Transfer 边界。
- URL/magnet/torrent/nzb/txt 创建、NAS 目标目录选择。
- 已完成单任务暂停/继续、URL/磁力与任务文件创建和只移除任务；均使用稳定任务基线、一次提交、独立回读与未确认结果不重放。删除已下载数据、批量控制、RSS/文件优先级/BT 协议高级和设置写继续独立后置。

在既有常用单任务流程之上，官方 `SYNO.DownloadStation.BTSearch` v1 的 Domain、Infrastructure、ViewModel 与 WinUI 闭环也已完成：能力门、原生 ContentDialog、`Ctrl+B`、提供方/类别/排序/方向、会话内隐私、取消/关闭、零提供方、空/筛选空/错误/结果态、迟到结果隔离和单结果创建均已接入；61 项英中资源与 8 项 Repository、15 项 ViewModel、3 项 source-contract 专项测试已落盘，共 26 项。正式提交 `5850f4c` 的 Windows Build run `31356270192` 已通过 886/886 项 .NET 10 xUnit，WinUI x64 与 ARM64 均 0 警告、0 错误。真实 NAS、Narrator、键盘、高对比和窗口缩放继续列入 `PENDING_USER_VALIDATION`。RSS、文件优先级、BT 协议高级和设置写不随该切片开放。

Container Manager：

- 概览、容器、映像、网络、项目、事件的 typed 页面。
- 生命周期/删除、Registry 搜索/标签/拉取、映像删除、网络创建/删除。
- 每个分区读失败独立降级，不阻断其他分区。

出口：官方 API 优先；`download-station2-fallback` 当前为 `observed:degraded`，任务文件上传/设置写未行为验证；`container-manager-internal` 当前为 `observed:degraded`，镜像拉取曾在发送前终止且写未验证。完整 Compose、终端和日志流不属于本阶段。

### W4-B：VMM 与控制台

- 机器、主机、存储、网络、映像、保护和事件 typed 页面。
- 三步基础创建、停止态常规编辑、电源、删除、网络编辑/删除和映像删除。
- 独立控制台窗口使用 WebView2 非持久配置和精确 NAS origin allowlist；SID 仅以内存 Cookie 注入，不落盘、不进 URL/日志/历史/诊断，禁止外部导航和新窗口，退出时清理。WebView2 Runtime 缺失时提供通俗降级，不绕过安全策略。
- 电源和删除操作使用稳定目标锁、确认与最终状态复查。

出口：`vmm-internal` 只读证据当前为 `read-verified:degraded`，创建/修改/网络写/删除未行为验证；未知 VMM 版本所有内部写关闭。只读资源页和禁用态可先完成；控制台安全原型通过自动化后仍保持关闭，真实会话与退出清理列入 `PENDING_USER_VALIDATION`，只阻塞控制台开放。高级磁盘/迁移/克隆等继续排除。

### W4-C：NAS 管理与统一存储

- 概览、性能、更新检查/说明、存储/硬盘/SMART、外接存储、ZRAM。
- 文件服务、SSH/Telnet、代理、接口、硬件/休眠、UPS、远程访问、安全、区域时间、DDNS。
- 套件、计划任务、账号/群组、当前账号共享访问、进程、日志分页和连接。
- 共享/类型/所有者/大文件/时间/重复内容的可取消统一存储分析。

边界：外接存储、ZRAM、电源计划、进程和当前账号共享访问保持只读；系统升级安装、套件安装/升级和管理员 ACL 矩阵继续关闭，除非后续获得稳定契约与独立授权。

出口：只读页面和禁用态先完成聚焦自动化；危险操作均有影响说明、权限/状态预检、防重复和回读。可能断网、改时、重启/关机的入口在用户明确授权的专用 `lab-*` 环境验证前保持关闭，并列入 `PENDING_USER_VALIDATION`，不阻塞只读 NAS 模块。

### BTSearch 后的近期实现顺序

1. **ACT-01 统一活动中心前台刷新增量已完成源码和本机闭环**：在正式提交 `2491212` 的 App/NAS 分源投影上，Activity 进入可见状态后立即通过公开 `SYNO.DownloadStation.Task` v1 读取前 100 项，并在可见期间每 5 秒严格单飞刷新；`F5` 和原生按钮可手动刷新，离页、窗口隐藏到托盘、退出或释放会取消并等待在途读取，窗口恢复或快速返回页面会启动新一代立即读取，迟到结果按代次拒绝。读取失败保留上次 NAS 快照和全部 App 传输，能力缺失零请求，超过 100 项只提示截断；不调用 Statistic 或完整 Snapshot，也不新增写操作、后台常驻、自动重试、系统通知或托盘联动。本机 .NET 10 聚焦 12/12、Release 全量 xUnit 1148/1148、本地化与 XML 门禁已通过；macOS 上 WinUI App 构建按预期停在不可执行的 Windows `XamlCompiler.exe`，GitHub Windows Build run `31510553951` 已通过 1148/1148 项 xUnit 与 WinUI x64/ARM64 构建，Repository Check run `31510553731` 已通过。真实 NAS 状态字段、断线重连、Narrator、键盘、高对比、200% 缩放和窄窗口为 `PENDING_USER_VALIDATION`。
2. **CHAT-02/03 前台消息主流程**：Windows 已完成文字、单附件及可见时立即读取、30 秒单飞刷新闭环；本切片 GitHub Windows Build run `31531069884` 与 Repository Check run `31531069860` 已通过。真实 Chat Server、系统选择器、托盘切换和辅助功能验收继续后置；Socket.IO、服务器已读、后台即时消息和通知保持关闭。
3. **NAS-01/NAS-02/NAS-04 有界只读详情已扩展为九区**：专用 `NasDetailsPage` 与 typed Repository 现提供系统概览、存储健康、系统更新、当前账号共享访问、系统活动、套件、计划任务、日志和当前连接。系统活动仅在运行时发现 `SYNO.Core.System.Process` v1 时单次读取 `start=0, limit=500`，只向领域层交付前 50 个进程的本地 ID、数字 PID、清理后的名称、可选状态和受限服务组标识；命令、路径、工作目录、账号、环境变量、端口、地址和原始响应始终丢弃。`System.ProcessGroup.list` v1 是可选补充，缺失、失败或列表不完整时保留进程并明确提示服务详情暂不可用；`service_info`、结束进程、服务控制和持续轮询保持关闭。共享访问继续固定公开 `list_share` v2 和 500 项源上限。九区独立表达失败、不可用、空内容、截断和正常状态。本机已通过系统活动/NAS 聚焦 28/28、Release xUnit 1035/1035、本地化、请求/Fixture 契约、XML 解析与差异检查；功能分支 Windows Build `31484643296` 已通过 1035/1035 与 WinUI x64/ARM64 构建，Repository Check `31484643292` 已通过。macOS App 构建按预期停在不可执行的 Windows `XamlCompiler.exe`，不写成本机通过。系统活动真实 API 仍只有静态证据，真实 NAS 的字段、权限、500 项边界及服务组降级，以及 Narrator、键盘、高对比和 200% 缩放继续后置验收。
4. Download RSS、文件优先级、BT 协议高级设置以及 Container/VMM 高风险写不进入这一波；没有公开或已记录契约的能力继续关闭。

### W5-A：页面级 Windows 体验收口

- Shell、BackStack、窗口大小、选择/滚动/筛选和多 NAS 状态恢复。
- 键盘快捷键、触控入口、拖放、右键、多窗口预览和控制台。
- 深色、高对比、文本缩放、关闭动画和所有页面五态；以 XAML 编译、ViewModel 状态测试、资源与自动化属性审查作为当前自动化证据。

每个已实现页面都可随功能波次完成 W5-A，不等待全部业务分支。Narrator、真实触控、DPI/多显示器和 Accessibility Insights 人工检查列入第 9 节。

### W5-B：Windows 系统集成开放门

- App Notification 原型验证注册/注销、点击激活、重启恢复和隐私正文；当前 unpackaged 形态可用性以实测记录，不预设必须迁移 package identity。
- 托盘驻留、显式退出、安全任务保存和下次启动恢复。
- Cloud Files 的默认注册和对用户开放必须同时满足 W1-C 的代码安全出口与实机开放出口；后者未完成时只保留禁用的实现路径，不注册同步根，也不宣传为可安全使用。

自动化出口：关键流程有键盘/触控可见替代，通知被拒绝不影响 App 内结果，显式退出状态机不会留下可自动重放的写操作。真实注册、点击激活、驻留和系统重启列入 `PENDING_USER_VALIDATION`，只阻塞相应系统集成开放。

### W6：后续用户双架构与交付验收

- x64、真实 arm64。
- Windows 10 2004 与项目支持的 Windows 11。
- 默认 framework-dependent ZIP：在干净机器核对 Windows App Runtime/.NET 运行时前提，完成解压、首次启动、覆盖更新、重装和用户主动清理；不能称作安装包、自动更新或卸载器。
- 若用户另行批准 installer、self-contained 或 MSIX，再按获批方案增加安装、原位升级、卸载与回滚验收，不得由本计划默认改变发布身份。
- 无论采用哪种交付，验证 Run 与通知激活的注册/注销、同步根注销、Credential Locker、缓存及已水合普通文件的保留/清理边界。
- Explorer 与 Cloud Files 的注册、重启、睡眠、离线、外盘和清理。
- 受控真实 NAS 的权限、版本、弱网和危险操作矩阵。
- 核对 W0 已冻结的交付决策；需要变化时回到审批门，不在 W6 临时改变。

出口：用户按第 9 节回传可复现结果后，每项功能取得准确验证等级；当前 ZIP 交付和任何另行获批的安装方案分别记录，不混用“安装/卸载”术语；所有 `SIGNING_REQUIRED`、`DEVICE_VERIFIED` 缺口和回滚步骤完整。W6 阻塞发布就绪声明，不回溯阻塞此前无依赖功能实现。

## 7. Codex 子 agent 文件所有权

### 7.1 拆分前热点

以下文件在 W1 机械拆分完成前只允许一个 agent 修改：

- `windows/src/LanStash.Domain/Models.cs`
- `windows/src/LanStash.Infrastructure/DsmRepository.cs`
- `windows/src/LanStash.App/ViewModels/AppViewModel.cs`
- `windows/src/LanStash.App/ViewModels/WorkspaceViewModel.cs`
- `windows/src/LanStash.App/Views/ShellPage.*`
- `windows/src/LanStash.App/Views/WorkspacePage.*`
- `windows/src/LanStash.Infrastructure/DsmApiClient.cs`
- `windows/src/LanStash.App/App.xaml*`
- `windows/src/LanStash.App/MainWindow.xaml*`
- `windows/src/LanStash.App/TrayIcon.cs`
- `windows/src/LanStash.App/app.manifest`
- 两份 `Resources.resw`
- `windows/Directory.Build.props`、`windows/package.ps1`、`.csproj`、`.slnx` 和 CI

先由一个基础 agent 做机械拆分并跑回归，主 agent 验收行为未变化后，才允许按功能目录并行。

### 7.2 推荐波次

| 波次 | Agent A | Agent B | Agent C |
| --- | --- | --- | --- |
| 0 | 单一 owner：热点机械拆分 | 只读基线/测试盘点 | 只读安全审查 |
| 1 | Auth/证书/能力；独占 Transport 契约 | Workspace/Shell/状态 | W1-R 通过后才做 Cloud Files |
| 2 | Files/Transfers | Chat 核心（不接附件） | 独立 Container/NAS 只读模型 |
| 3-A | Preview/Photos | Download/Container 写流程 | W3-A/W3-B1 出口只读复核 |
| 3-B | Chat 附件 | 对应 Preview/Chat 回归测试 | 独立 QA；不得抢改生产文件 |
| 4 | VMM/Console | NAS Admin/Storage Analysis | 系统集成唯一 owner |
| 5 | 页面 owner 修复键鼠/触控/动效 | 无障碍/主题/本地化只读审查 | 发布/恢复只读审查 |

共享 `.resw`、工程文件、Shell 路由、契约和进度文档始终由单一集成 owner 串行修改。功能 agent 在任务开始前拿到现成资源键；若缺键，只提交“键、英语、简中、参数”清单，不抢改资源文件。

测试 agent 可拥有对应功能的新测试目录，不能修改生产代码或降低既有断言。高风险模块由未参与实现的 agent 做只读对抗审查。无障碍审查 agent 不直接修改各功能 XAML，问题交回该页面唯一 owner，避免与输入/窗口切片重叠。

## 8. 自动化与构建门禁

每个切片先运行受影响项目的聚焦测试和可用架构构建；阶段里程碑、共享契约变更和 W6 候选再运行下列完整门禁。命令从仓库根目录在 Windows 环境执行，实际结果必须原样记录：

```powershell
dotnet restore .\windows\LanStash.slnx
dotnet test .\windows\tests\LanStash.Tests\LanStash.Tests.csproj -c Release --no-restore
dotnet build .\windows\src\LanStash.App\LanStash.App.csproj -c Release -r win-x64 --no-restore
dotnet build .\windows\src\LanStash.App\LanStash.App.csproj -c Release -r win-arm64 --no-restore
dotnet build .\windows\src\LanStash.App\LanStash.App.csproj -c Debug -r win-x64 --no-restore

python .\tools\localization\check_localization.py
python .\tools\contract-validation\validate_fixtures.py
python .\tools\request-contract\validate_contracts.py
git diff --check
```

W6 还必须在 Windows 干净工作区用脚本已有的非交互模式生成当前 ZIP 交付物，并记录产物启动结果：

```powershell
$env:LANSTASH_NON_INTERACTIVE='1'
$env:LANSTASH_TARGET_PLATFORM='both'
$env:LANSTASH_RUN_TESTS='1'
$env:LANSTASH_LAUNCH_AFTER='0'
.\windows\package.ps1
```

CI 后续应覆盖：

- x64 与 arm64 编译；
- `contracts/**` 改动触发 Windows 测试；
- 分域请求 fixture、状态机和 ViewModel 测试；
- Cloud Files P/Invoke 独立编译；
- XAML 编译 + 不依赖真实 NAS 的 ViewModel 五态测试。

当前仓库只有 xUnit，没有 WinUI UI test harness。新增 XAML 加载/UI 自动化工程或框架若带来第三方依赖或工具链变化，先取得用户批准；在此之前以 XAML 编译、ViewModel 五态测试、资源与自动化属性审查作为当前门禁，不虚构页面自动化覆盖。人工 Accessibility Insights、Narrator 和真实输入设备检查列入第 9 节 `PENDING_USER_VALIDATION`。

当前没有 Windows 主机或 CI 时，不用 macOS 结果代替 XAML、x64/arm64 构建；将其记录为“尚未取得 `BUILD_VERIFIED`（待 Windows CI/环境）”后继续源码、合成测试和无依赖功能。需要用户设备、Explorer 或真实 NAS 操作的项目才记录 `PENDING_USER_VALIDATION`。不得跳过当前环境本来可以运行的相关测试，也不得为等待全量门禁而堆积多个未验证功能切片。

## 9. 后续用户 Windows 实机验收矩阵

本节不是普通功能开发的前置条件。主 agent 在每个切片交付时只摘出受影响项目，给出条件、操作步骤、预期结果、应提供的脱敏错误信息和受影响入口；用户可在功能批次完成后集中测试。未回传结果前保持 `PENDING_USER_VALIDATION`，不得声称通过。

- x64 和真实 ARM64 设备。
- 鼠标、键盘、触控、Narrator、高对比、100%/150%/200% 缩放与系统关闭动画。
- 窄窗口、常规窗口、最大化、多显示器和 DPI 切换。
- 局域网、公网直连、QuickConnect 中继、网络切换、会话过期、自签名首次核对和证书变化。
- 窗口关闭驻留、通知点击、显式退出、系统重启、睡眠/唤醒和任务恢复。
- Cloud Files 固定/释放、Explorer/系统重启、空间不足、外置 NTFS 拔插、长路径、非法名称、大小写冲突。
- Word、记事本等应用尝试创建、自动保存、改名和删除时必须安全失败，且 NAS 无写回。
- ZIP 解压/覆盖/主动清理后同步根、缓存和凭据行为可预测；若另行批准安装器，再增加安装/升级/卸载矩阵。
- 危险写仅用专用测试 NAS 和虚构数据，覆盖普通账号、受限管理员、权限拒绝、超时、部分成功、提交未知和取消。

## 10. 风险与决策门

| 风险 | 处理 |
| --- | --- |
| 私有 API 范围大 | 内部只读按兼容记录探测并可失败降级；内部写绑定 DSM build + 套件版本，未知环境默认关闭；QuickConnect 单独管理 |
| 当前写操作只靠页面忙碌锁 | 迁移到稳定 profile/操作/目标 key 的协调器，并以回读决定结果 |
| Credential Locker 与证书信任不对齐 | W1 先完成证书模型；密码永不共享给 Cloud Files |
| Cloud Files Range/版本不足 | 先冻结 W1-R 契约；代码安全出口阻塞 Cloud Files 实现，实机开放出口只阻塞其注册、宣传和发布，不阻塞其他模块 |
| unpackaged 发布生命周期 | W5-B 原型验证；MSIX/Identity/签名单独审批 |
| x64 结果被当作 arm64 | 两个 Runtime 与真实设备分别记录；自动化只断言结构布局、常量、确定回调序列和终态次数，真实 ARM64 后置用户验证 |
| 通用页面继续膨胀 | W1 后禁止向 `WorkspacePage` 增加新领域行为，改用功能专页 |
| macOS 基线继续变化 | 每个大阶段结束做一次受控增量盘点，不在切片中途追逐变化 |
| ZIP 被误当安装器 | 默认只验收解压/覆盖/主动清理；installer、self-contained 或 MSIX 必须另行批准 |

## 11. 参考资料

- [macOS 功能对齐总控计划](MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)
- [平台功能矩阵](../progress/PLATFORM_MATRIX.md)
- [请求契约与写操作结果计划](REQUEST_CONTRACT_AND_MUTATION_RESULT_PLAN_ZH.md)
- [桌面云盘专项计划](NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)
- [Microsoft NavigationView](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/navigationview)
- [Microsoft Windows Controls](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/)
- [Microsoft Cloud Files Functions](https://learn.microsoft.com/en-us/windows/win32/cfapi/cloud-files-functions)
- [Microsoft CfRegisterSyncRoot](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfregistersyncroot)
- [Microsoft unpackaged App 部署责任](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/deploy-unpackaged-apps)
- [Microsoft Windows App SDK 通知](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/)
