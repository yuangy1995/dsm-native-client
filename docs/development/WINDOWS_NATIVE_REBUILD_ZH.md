<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-16 -->

# Windows 原生工作区重建账本

## 授权与基线

2026-09-16 用户要求推翻 Windows 旧界面，复刻 macOS 的样式和功能，以 Windows 原生技术实现，整理文档、检查性能并提供本地测试包。此次授权覆盖界面重建与必要合并、删除；高风险 NAS 写入、正式发布和 Git 历史操作不因此获得授权。

开始时 `main` 工作区干净。macOS App、Apple 共享包和 Android 为只读范围。沿用 C#、WinUI 3、现有 Domain / Application / Infrastructure 与认证安全边界。重建产品界面不等于删除经验证的协议和数据保护实现。保持标识、权限、数据格式、最低系统版本及依赖版本。

旧计划中的“不做 macOS 视觉克隆”由本次明确需求更新：布局、分组、密度、侧栏、工具栏、内容面板向 macOS 对齐；窗口控制、菜单、字体、键盘、无障碍与主题采用 WinUI 原生实现。

## 修改范围与顺序

本任务单一负责人修改 Windows Shell、主题、页面、相关性能实现、聚焦测试、打包和 Windows 文档；不与其他实现并行写同一文件。

1. 核对 macOS 与 Windows 源码，建立账本与构建基线。
2. 重建原生窗口、设备侧栏和内容面板，整合既有业务入口。
3. 重建文件浏览及主要模块呈现，保持五态和中英文资源。
4. 修复可复现的性能问题，进行回归和只读安全复核。
5. 运行本地 x64、ARM64 构建和测试，生成可检查的本地包，记录真实结果。

## 功能对齐账本

| 切片 | macOS 证据（均位于 `apple/Apps/DsmMac/Sources/`） | Windows 等价结果与交互 | 契约 / 安全 | 当前验证 |
| --- | --- | --- | --- | --- |
| 窗口与工作区 | `WorkspaceView.swift`、`MacAppearance.swift` | 设备侧栏、分组模块、底部活动与设置、圆角内容面板、浅深色与高对比 | 既有模块 / 只读呈现 | 已重建；本机 x64 WinUI 合成运行覆盖浅深色 |
| 登录与设备 | `LoginView.swift`、`LoginViewModel.swift` | 原生设备列表、连接表单、取消、证书确认、设备切换 | 既有认证 / 认证证书 | 既有认证保留；新布局已有本机合成运行 |
| 文件与传输 | `WorkspaceView.swift`、`WorkspaceModel.swift`、`FilePreviewView.swift` | 导航、网格 / 列表、筛选、预览、上传下载、整理、分享与活动 | 官方 File Station；所有写操作沿用确认、权限、去重与结果复查 | 自动化与原生文件五态已运行；NAS 与系统选择器待用户验证 |
| Photos | `SynologyPhotosView.swift`、`SynologyPhotosModel.swift` | 时间线、文件夹、相册、共享、筛选、预览与原件保存 | 既有 Photos 私有契约；个人删除沿用能力门 | 既有业务回归已运行；真实 NAS 待用户验证 |
| Chat / 下载 | `ChatWorkspaceView.swift`、`WorkspaceView.swift` | 会话分栏、消息 / 附件；任务列表与活动 | 既有 Chat / Download Station 契约与写门 | 既有业务回归已运行；已统一顶部栏与会话分栏；本机合成会话、双向气泡与下载内容运行通过 |
| NAS / 容器 / 虚拟机 | `NasAdministrationView.swift`、`ServiceManagementView.swift`、`WorkspaceView.swift` | 原生列表详情与管理入口 | 已有只读与能力门；未知私有写保持关闭 | NAS 导航与容量卡片已有合成运行；容器总览与虚拟机顶层资源标签已重建，合成内容运行通过 |
| 桌面云盘 | `DesktopCloudDriveManager.swift` | Windows Explorer / Cloud Files 等价结果 | 系统集成与后台，高风险入口保留既有门禁 | `PENDING_USER_VALIDATION` |
| 性能 | 文件列表分页、模块生命周期、照片缩略图 | 避免重复集合重建、分页二次方去重、非活动页面刷新 | 不变更 API / 持久化 | 已运行 2 万项文件合成性能回归；真实网络与媒体负载未测 |

## 追加截图波次（2026-09-16）

用户补充消息、照片、下载、容器总览与虚拟机页面截图。此波次依次完成主要内容布局、状态与主题回归，再重打本地包；截图中的账号、会话、文件及数值不作为测试资料。消息依据 `ChatWorkspaceView.swift`，照片依据 `SynologyPhotosView.swift`，下载／容器／虚拟机依据 `ServiceManagementView.swift`；沿用 Windows 已记录的契约与安全门。本波次的验证目标是有内容时可读可操作、详情可返回、筛选及原操作处理器仍有效；未知私有写不属于可启用范围。

### 导航裁切修复

用户指出消息图标右侧被裁切、紧凑侧栏不完整。检查确认 24 单位图标路径超过 22 单位视口，紧凑栏还沿用了展开时的左右边距。固定几何现按 20/24 缩放，紧凑栏改为 64 DIP 并取消展开边距；设备详情随展开显示，容量信息移入原生 PaneFooter，保留传输与设置导航。使用原生展开按钮，所有模块都有恢复展开的入口，图标同时提供本地化名称与提示。合成回归新增路径边界、侧栏边界与紧凑详情隐藏断言，并覆盖主动收起／展开循环和 900 DIP 窗口。

### 标题栏与文件工具栏修复

深色合成宿主原先仅在 RootFrame 切换主题，窗口根部保持浅色，旧截图也没有覆盖标题栏。现主题应用于窗口根部，快照覆盖完整自绘标题栏，并检查窗口与页面实际主题及 AppWindow 系统标题栏按钮的前景／透明背景一致。原生关闭、最大化、最小化仍由系统提供；它们不属于 RenderTargetBitmap 输出，未把自绘图像当作系统非客户区截图。

文件页将压缩的 AppBarToggleButton 换为原生 ToggleButton，将左侧同类图标动作换为 Button，统一为 38 DIP、零内边距、图标水平垂直居中。沿用默认原生状态模板和既有点击处理器，保留双语无障碍名称，标签迁移为工具提示。选中背景按浅深主题提供，新增实际图标中心对齐断言。当前设备 RasterizationScale=1；900 与 1280 像素窗口已覆盖，125%／150%／200% 系统 DPI 和跨显示器拖动仍待用户验证，不修改系统缩放设置。

## 验收边界

真实 NAS、Cloud Files 系统回调、通知、跨 NAS、危险写、触控、Narrator 与设备差异使用 `PENDING_USER_VALIDATION`。前提为专用 Windows 设备与受控 NAS；步骤为连接后逐模块执行读取、取消、重试与允许的单项写，再刷新复查；预期为状态正确、切换设备隔离、未授权写不可执行。仅反馈系统与套件版本类别、操作步骤、预期 / 实际结果和脱敏错误，不能回传地址、账号、真实路径或凭据。

非目标：修改 macOS / Android、正式签名发布、探测私有写接口、真实数据破坏性操作。UI 或构建通过不能作为这些能力的验收。

## 实际验证与交付

### 已修改

- 用主题资源、固定几何图标、设备卡片、底部传输／设置／容量／退出重建 Shell。文件页采用单行工具栏、独立路径行、默认网格、常驻属性栏与状态栏；位置面板按需打开。
- 保留现有文件操作处理器；低频操作移入更多菜单，右键复用原处理器。右键空白处不沿用旧选中项执行文件写操作。退出确认独立于导航选择，取消后可再次操作。
- 登录使用设备列表、底部语言选择、分组表单；NAS 详情采用持续可见的分类侧栏、容量与健康卡片。卡片只汇总完整的 Volume 数据，不把 Pool／Drive 重复计入；缺字段显示未知。
- 删除文件页旧大标题与多行主命令布局；原有传输入口合并到设备侧栏底部；存储三态和无障碍进度统一移入侧栏，删除隐藏的重复容量弹层。照片重排为单行标签、搜索、筛选、无文件名方形网格与右侧月份栏；消息使用会话栏和双向气泡，保留原附件与删除处理器，发送框改为输入行及底部动作行。下载改为通栏任务卡片、顶部筛选与任务动作，种子／BT 搜索／高级摘要移入更多菜单；虚拟机改为顶层七类标签、通栏机器列表与详情返回；容器新增四类总览卡片并可进入对应资源标签。保留既有真实业务，不宣称已经全面复刻。
- 修复 unpackaged 启动时的语言 API、缺失 `resources.pri` 和无效 WinUI 图标枚举。发布继续使用原 Identity 与 unpackaged 形态，随包携带既有运行库。
- 分页使用路径 HashSet 去重，保留未改变的行容器；历史页面按真实访问顺序限于 12 个位置／合计 4096 条缓存，大目录可以浏览但不驻留历史缓存。页面状态刷新合并到 UI 队列，离开 Photos／Chat／传输页暂停其可见性刷新。
- 修复容量格式漏数值、NAS 分类恢复选择导致的重复重建。原生运行还发现消息编辑器配置通知引起页面刷新循环、下载与容器筛选在 XAML 初始化期间访问未赋值字段；分别改为抑制同步配置回声并合并通知、先建立模型并使用事件来源控件。新增合成 WinUI 宿主、正式截图回归脚本和相应单元回归；修复本地化扫描误读 `bin/obj` 中 XAML 目录的问题。

### 实际命令与结果

在 Windows x64、现有 .NET 10 工具链上运行，新增 SDK 位于用户构建工具目录，没有升级项目依赖。

```powershell
# 仓库根目录
 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64
 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-build --filter FullyQualifiedName~FileBrowserPerformanceTests --logger "console;verbosity=detailed"
 ./windows/tests/UiSmoke/run.ps1
 python tools/localization/check_localization.py
 python tools/codex/check_documentation.py
```

- 完整 xUnit 最新运行：1595 通过、1 失败、0 跳过（包含本次 8 项 QuickConnect 转介回归）。失败为 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`，在创建测试符号链接时报告账号缺少特权，未执行到目标安全断言；不得记为安全验证通过。保留原测试，不启用 Developer Mode 或修改系统权限。
- 此前排除上述环境受限测试的运行已通过；最终完整运行仍如实保留失败。新增容量、设备根路径、LRU 缓存、集合通知和 NAS 分类回归通过。
- 2 万项分页与筛选的独立合成运行70.1 ms，分配 19.64 MiB；分页阶段零 Reset，筛选切换允许 Reset。该测量只覆盖模型操作，不是网络吞吐、渲染帧率或大媒体体验结论。
- x64 和 ARM64 Release 自包含发布均已在本机完成；只有 x64 进行了原生运行。ARM64 仅交叉构建，实机启动未验证。
- UI 宿主 21 组检查通过，覆盖文件五态、浅深色、选中详情、列表、登录、NAS 存储、照片时间线、消息会话内容，以及下载／容器／虚拟机合成内容（早期回归另覆盖不可用状态）。每组进入预期状态后输出自身 XAML 图片；完成时间约 3–6 秒，包含刻意等待渲染稳定的时间，不作为冷启动指标。消息回归在修复前 30 秒内不能完成，修复后约 3.7 秒完成。图片全部使用合成数据，未使用用户截图中的设备名、真实目录或容量作为 fixture。
- 追加导航回归：21 组常规状态、10 组 900 DIP 窗口展开／收起循环均通过；消息页浅深色另行复查图标路径和紧凑栏边界。
- 双语、参数、资源引用、硬编码扫描及文档检查已通过。
- 自动审批以策略拦截拒绝清理旧构建目录；过期生成物保留在已忽略的 dist 中，不纳入源码或最终包。

打包使用 `windows/package.ps1`，非交互参数为 `LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`；测试已单独运行，包内 `build-info.json` 如实记录此标志。最终输出为 `windows/dist/20260916-110852/` 中的 x64／ARM64 ZIP 与 SHA-256，不覆盖旧包。两个 ZIP 均通过 CRC、必要运行文件、无合成测试类型和 SHA-256 校验。此前 103413 x64 正常包已实际启动，并通过原生可访问树确认进入空设备登录页；最新 110852 包完成双架构构建及包校验，其对应源码通过本轮原生合成登录运行。没有使用账号密码登录 NAS 或保存凭据。源码处于 `main` 的未提交工作区；没有 add、提交、推送或合并 Git 历史。

标题栏修复后的文件回归另通过 6 组常规窗口和 5 组窄窗口状态，包括浅深色、列表、加载、空与错误；选中详情浅深色在前一轮通过。原生 UI 工具可读取控件树，但鼠标注入返回 `coordinate input geometry is unavailable`，因此没有把实际鼠标点击标为通过；展开／收起验证来自测试宿主的原生控件状态循环。

### 独立集成与只读对抗复核

界面重建波次复核了认证／证书、文件写菜单、设备切换、后台页生命周期与打包边界：该波次没有新增 NAS 请求、改变请求契约、移除写门或改变凭据格式；右键仍使用原确认和结果回读。合成 Repository 仅在 `LanStashUiSmoke=true` 编译，正常打包明确设置 false。检查了 macOS 与 Android 无生产源码差异。

### 尚未完成的业务与视觉对齐

本交付是可运行的原生重建预览，**不能标为用户要求的完整 macOS 功能复刻已完成**。

- NAS 设置尚未形成截图中全部控制面板分类的等价用户流程；当前容量卡片来自现有存储读取，不包含截图中的历史容量趋势。
- Photos、Chat、Download Station、容器、虚拟机和传输页继续使用现有业务实现；本轮根据追加截图重建主要内容布局；现有契约未提供的写入、部分工具动作以及全部 macOS 交互仍有缺口，不以相似界面代替功能完成。
- 容器／虚拟机管理写入、更多 NAS 管理和其他尚未接入的私有写能力属于实施缺口，不写成只差真机验收。应按现有长期计划和私有契约逐项实现，不能用静态按钮代替。
- 系统选择器、真实上传下载／预览、跨 NAS、Cloud Files、通知、证书异常、触控／Narrator／高对比和 ARM64 实机为 `PENDING_USER_VALIDATION`；所需环境、操作和脱敏回传方式见上文。未经证据允许的高风险入口继续关闭。

后续继续补上述独立页面尚缺的交互与视觉，再逐项补受契约限制的业务；不修改 macOS／Android，也不把未知私有 API 接口猜测写入实现。

## 登录故障波次（2026-09-16）

macOS 参考为 `LoginView.swift`、`LoginViewModel.swift` 与共享 `DsmQuickConnectResolver.swift`；Windows 的等价主流程为地址识别、可信控制面发现、直连／中继、证书确认与认证。此次真实只读复验确认 sites 转介被忽略导致误报未找到；详见[控制面记录](../api/discovery/endpoints/quickconnect-relay-control.md)。登录界面改为品牌、可滚动字段和固定反馈／连接动作三行布局，小窗口保留连接与取消入口。认证及凭据门禁不变。后续验收区分模拟请求、真实未认证发现和用户完成账号登录，不能互相替代。

本波次验证：新增 8 项转介测试通过，完整 xUnit 为 1595 通过 / 1 项原有符号链接权限失败；真实登录前发现测试显式设置本次 ID 后运行通过（不发送凭据，不将测试 ID 写入源码或文档）。最终登录正常／错误的浅深色在 1280×820 与 900×650 原生窗口各 4 组通过，图片位于 `windows/dist/ui-review-20260916-110507/` 与 `windows/dist/ui-review-20260916-110543/`。验证码与自定义端口放在有明确标注的展开区，反馈与动作不随字段区滚走；未填完整时连接按钮禁用，启用后的前景使用主题强调色文本。凭据及 OTP 提交处理器保持不变。双语、文档与 22 项私有 API 文档引用检查通过。

聚焦复验命令（仓库根目录；真实发现仅在进程中设置 `LANSTASH_QUICKCONNECT_TEST_ID`）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~QuickConnectReferralTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-build --filter FullyQualifiedName~OptionalRealQuickConnectDiscoveryDoesNotSendCredentials
./windows/tests/UiSmoke/run.ps1 -Scenarios login -WindowWidth 1280 -WindowHeight 820
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios login -WindowWidth 900 -WindowHeight 650
python tools/contract-validation/validate_fixtures.py
```

登录切片的只读复核检查了控制主机白名单、循环转介上限、取消、无直连时的中继分支和凭据隔离。未改变证书信任、认证请求、持久化格式或危险写门禁。真实账号登录继续为 `PENDING_USER_VALIDATION`：使用自己的 NAS 在新包输入登录资料，预期完成连接并进入文件页；如失败，仅提供脱敏提示、连接方式类别及操作步骤，不回传凭据。
