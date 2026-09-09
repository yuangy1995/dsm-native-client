# macOS 界面密度、弹窗主题与挂载缓存（2026-09-09）

## 本次范围

保留工作区中已完成的外观修复和本地测试包隔离，不提交、不推送；延续现有 App 按钮、主题和原生交互。

| 用户需求 | 基线与实施位置 | 验收重点 |
| --- | --- | --- |
| 登录底栏并排 | `LoginView.profileSidebar` | 添加 NAS 与语言选择不再纵向堆叠 |
| 加载背景 | `FileBrowserView` 覆盖层 | 加载、刷新、搜索均使用主题色，不出现白色遮罩 |
| 侧栏间距 | `SidebarView` 设置入口与分隔线 | 有稳定上下留白 |
| 文件网格大中小 | `MacFilePresentation`、`FileGridCell` | 文件夹、文件图标、图片缩略图及单元格同步缩放；默认中等 |
| 紧凑文件详情 | `FilePropertiesView`、`FileSelectionInspector` | 统一标题与信息行，文件夹自动计算，取消/错误/重试可用 |
| 排序与更多按钮 | `FileSortMenu`、`FileBrowserView` | 复用现有圆角按钮外形，菜单语义不变 |
| 缓存统计和清理 | `AppStorageInspector`、`DesktopCloudDriveManager` | 统计挂载缓存，区分可释放与离线保留，复用系统安全释放 |
| 聊天背景 | `ChatConversationView` | 消息区、头尾工具栏随主题 |
| 弹窗统一 | `MacAppearance` 与所有 macOS sheet 入口 | 独立呈现背景不继承工作区的透明叠色假设；表单与空态不露白 |
| 后续补充：统一选中态 | 原生 List/Table、分类侧栏、页签和网格 | 取消高饱和蓝色和脱离主题的灰色块，使用低饱和主题叠色；保留焦点、多选和键盘操作 |

## 安全边界

- 文件夹自动统计复用既有目录大小接口，不新增 DSM 契约；只在查看详情时触发，不对整页所有文件夹后台统计。
- 缓存清理不删除挂载目录、不移除映射、不清除凭据、不触发 NAS 文件删除；离线保留、未上传与占用中的内容必须受保护。
- 使用既有 `NSFileProviderManager.evictItem`。Apple 文档明确指出未上传修改、不可释放项目和打开中的文件会拒绝释放；本次不增加强制删除回退。[Apple 缓存释放文档](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:))
- 本地测试包仍保持数据隔离、无挂载扩展、不自动启动；真实挂载缓存验收需正式授权环境，记为 `PENDING_USER_VALIDATION`。
- 不修改正式应用标识、权限、会话存储、既有持久化结构和其他平台；网格大小沿用现有本机偏好保存方式。

## 验证记录

- `swift test --package-path apple --skip WorkspacePresentationTests`：847 项 XCTest 中 845 项通过，2 项既有环境测试未运行；另有 12 项 Swift Testing 通过。未运行项是需要真实 QuickConnect 资料及显式开启的挂载性能基准。
- `bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-ui-density.zQR961`：完整 41 项合成界面回归通过。覆盖双语、浅深主题、五态、窗口、弹窗、原生选择/焦点、三档网格及自动目录大小；过程中发现并修复 SwiftUI 同步选择时抑制原生通知导致底色丢失的问题，未降低测试断言。
- 新增挂载缓存回归：跨 NAS 汇总实际分配字节、保护离线目录、系统拒绝未上传内容时保留记录、批量清理重复提交保护。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：21 项通过。
- `python3 tools/localization/check_localization.py` 与 `git diff --check` 均通过。新增界面键同时提供英语和简体中文。
- 使用既有 `package.sh`，参数为 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0`；本次使用独立临时构建目录及 `dist/density-theme-20260909.9yDhvJ` 输出目录，不覆盖旧包。
- 最终 arm64 Release 构建、隔离标识、临时签名权限、Sparkle 实际加载及 DMG 校验全部通过；最终完整 UI 复跑 41 项通过。安装包为该目录下的 `LanStash-1.0.1-arm64.dmg`，包内是沿用既有隔离身份的 `LanStash Test.app`，未自动安装或启动。

## 集成复核与明确非目标

- 所有 40 处 App 内 sheet 入口复用主题封装，独立表面不再沿用工作区透明叠色；原生文件选择器、系统安全授权框保留平台交互。
- 选中态只替换绘制，不改变 List/Table 绑定、导航、焦点和多选；原生列表绑定变化、滚动复用以及焦点切换均保留浅深主题色。未把主操作按钮、聊天作者气泡或警告图标改成选中态颜色。
- 目录大小在详情打开时自动刷新，既有正在进行的任务继续复用；不为整页目录自动启动统计。失败保留提示与重试，取消仍走既有任务取消逻辑。
- 挂载缓存批量操作逐项调用现有系统释放边界，只在成功后移除对应缓存记录；不可用映射、恢复中/移除中的映射不会强行释放，错误不会改为成功。未修改共享会话、凭据、File Provider 扩展实现或 DSM 请求契约。
- 本轮仅修改 macOS 展示/协调代码、对应双语资源与回归测试；此前未提交的外观和隔离测试包改动均保留。

## PENDING_USER_VALIDATION

| 前置条件 | 操作 | 预期与回传 |
| --- | --- | --- |
| 新隔离测试包 | 在浅色/深色下检查登录底栏、文件加载、聊天、创建虚拟机、缓存弹窗 | 无独立白底；语言选择与添加 NAS 并排；按键和关闭正常 |
| 有足够文件的目录 | 文件页“更多 → 图标大小”选择小/中/大；打开目录详情，再关闭重开 | 文件/文件夹/缩略图同步变化；选择不丢失；目录大小自动刷新，无需先点击计算 |
| 有下载任务与虚拟机 | 选中、切换焦点、滚动、清除选择 | 使用低饱和主题底色，不出现原生高饱和蓝或灰块；文字仍可读 |
| 正式签名且带挂载扩展的专用测试环境 | 准备已同步临时缓存、离线保留文件、正在使用/未上传的测试文件；在存储页确认清理挂载缓存 | 只释放允许清理的临时缓存；保留离线内容及未上传修改；不删除 NAS 文件。缓存统计更新，部分失败有提示 |
| 其他受支持 macOS、Intel、VoiceOver/增强对比度 | 重复上述界面检查 | 当前仅完成本机 arm64 构建和合成测试，不宣称跨设备或真实 NAS 验收通过 |

失败时回传 macOS 版本、主题、滚动条/无障碍设置、复现步骤和脱敏截图；不回传账号、地址、真实文件路径、消息正文或登录资料。隔离测试包不包含挂载扩展，因此不能用该包验收真实挂载缓存；保留该能力门禁，不自动安装或启动 App。

## 后续补漏：卡片自身的背景

用户实机反馈连接卡片和容器总览统计卡片仍偏白。本轮扩大检查到形状的 `fill`，不只检查页面级 `background`，确认是卡片直接使用系统控件底色导致。

- 在现有外观调色板增加轻量卡片色，`MacCardFill` 从当前主题及对比度设置解析颜色，不另建主题配置。
- 替换 18 处同类卡片/分组背景：连接卡片、容器统计、传输任务、设置分组、磁盘信息、计划任务及账号编辑等；保留布局、图标状态色、按钮和业务操作。
- 图片/PDF 的实际内容、播放器浮层和输入控件等独立用途背景不进行无差别替换。
- 新增真实卡片渲染测试：实际点击连接页的卡片切换按钮，确认列表切换为网格；对连接卡片和容器统计卡片进行浅深主题截图与颜色采样，检测白底回归。原先空连接列表的通用页面测试不足以覆盖卡片模式，此次补上了非空样例。
- 新包输出到 `apple/Apps/DsmMac/dist/card-theme-20260909.arVjXC`，仍使用隔离测试身份；不会覆盖前一测试包或正式版。
- 本轮验证：`swift test --package-path apple --skip-build --skip WorkspacePresentationTests` 共 848 项 XCTest，846 通过、2 项既有环境测试跳过，另有 12 项 Swift Testing 通过；`bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-card-ui.OuvsRD` 的 42 项全部通过。`python3 tools/localization/check_localization.py`、`git diff --check` 通过。
- 本轮 arm64 Release 打包、隔离标识/签名权限检查、Sparkle 实际加载及 DMG 校验均通过；未自动安装或启动。临时构建与合成截图在验证后清理，保留回归测试和安装包。
- `PENDING_USER_VALIDATION`：在原问题电脑检查连接卡片、容器统计卡片和同类分组，分别切换雾白/烟墨及透明度。预期卡片与页面同色系，仅有轻微层次差异；断开、启动、停止等操作未修改，也未使用真实设备执行验证。
