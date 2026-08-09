# Windows / Apple 移动端功能对齐账本：第 2 波

> 状态：整理后的单一简体中文功能提交已合并到 `main`，四组云端门禁通过，真机与真实 NAS 验收后置
> 基线提交：`641852b408ae24f8819e4a49cd70df4c8d9e5011`（`完善跨端证书安全、文件操作与照片查看`）
> 当前范围：Windows/iPhone/iPad `FILE-05 单文件同 NAS 复制与移动`、Windows/iPhone/iPad `PHOTO-03A 用户主动导入单项照片或视频`
> 禁止范围：`android/**`、`apple/Apps/DsmMac/**`；目录复制、批量或跨 NAS 复制移动、覆盖、回收站恢复或永久删除、自动照片备份、整库照片权限、后台扫描、Chat 写和 Download 写

## 1. 账本口径

- `完整`：源码、聚焦自动化与目标平台构建覆盖用户主流程；只能依赖真机、系统选择器或真实 NAS 的验收另记 `PENDING_USER_VALIDATION`。
- `部分`：已有可用流程，但契约、状态、错误恢复、自动化或目标平台构建证据仍不完整。
- `关闭`：缺少稳定契约、行为证据或本波授权，生产入口保持隐藏、只读或能力门关闭。
- 复制与移动只有在稳定源/目标、写前基线、一次提交、真实提交边界、独立写后回读和提交后零自动重放均成立时才允许进入 UI。
- 主动导入只复用现有上传、临时 artifact 与 Activity 结果链，不建立平行上传实现；系统选择取消不得改变页面基线。
- 本地只执行形态、资源、请求契约和聚焦低负载测试；Windows x64/ARM64、Apple iPhone/iPad、共享 Package/macOS 回归与 Android 未改动回归交给 GitHub 分支门禁。
- 同一功能的验证修正可以产生临时提交；正式历史必须整理为一条语义完整的简体中文提交，最终精确 SHA 重新跑全量门禁后才能合并 `main`。

## 2. 本波用户结果与边界

| 用户结果 | 事实来源 | 当前基线 | 本波目标 | 安全与数据边界 | 明确非目标 |
| --- | --- | --- | --- | --- | --- |
| Apple/Windows 单文件复制 | 总控 `FILE-05`、公开 File Station CopyMove v3、FILE-03 统一写结果 | Apple 只有旧 `void` copy/move；Windows 无结果型 copy/move；两端生产入口关闭 | 选择一个普通本地文件和同 NAS 普通本地目标目录；无覆盖；独立回读确认目标同类型/大小且源仍存在 | profile/repository/源/目标/generation 冻结；源与目标锁；提交一次；提交后取消、断线或坏回读只核对不重放 | 目录、批量、跨 NAS、覆盖、remote/virtual/recycle/`#recycle`、后台队列 |
| Apple/Windows 单文件移动 | 同上 | 同上 | 与复制共用目标选择和状态机；独立回读确认目标同类型/大小且源消失 | 移动前冻结源身份；目标路径不得等于源；普通本地来源和目标双门；未确认结果跨页面重建保持 blocker | 复制后递归删除模拟移动、永久删除、回收站恢复、跨卷行为承诺 |
| iPhone/iPad 主动导入照片或视频 | Apple `PHOTO-03`、系统 `PhotosPicker`、现有 M2 上传/Activity | Photos 已支持浏览、预览、保存和分享；没有 PhotosPicker 导入 | 用户选择一项图片或视频，明确目标后以无覆盖上传；选择取消静默；成功后仅在仍处于同一目标时刷新 | 单项、用户主动、受控临时 artifact；不申请整库权限；profile/目标/repository/generation 门；Activity 接管后零重放 | 自动备份、后台整库扫描、多选、删除系统照片、照片编辑、私有 Foto API |
| Windows 主动导入照片或视频 | Windows `W3-A`、原生 FileOpenPicker、现有 ForegroundTransfer/Activity | Photos 已支持浏览、时间线、预览和保存；通用上传选择器只在 Files 流程使用 | 从 Photos 页选择一项图片或视频，导入当前普通本地照片目录；宽窄布局、键盘和 Narrator 可完成主流程 | 复用同一 picker/transfer/upload 结果链；timeline 使用当前空间根并明确显示目标；remote/recycle/`#recycle` 零入口 | 新上传协议、后台文件夹监听、批量选择、Cloud Drive、自动图库同步 |

## 3. 交互转换

### 3.1 iPhone

- Files 单项菜单提供“复制到…”和“移动到…”，随后使用原生 Sheet 选择普通本地目标目录并显示冻结的源与目标。
- 提交中只显示一个进行中的操作和取消请求；只有明确 `CancelledBeforeSubmission` 才允许安全返回表单。
- 结果未确认时显示需要核对，不自动重放；关闭后同 profile、同操作与同目标仍受 blocker 保护。
- Photos 工具栏和空状态均提供可见“导入照片或视频”；PhotosPicker 取消静默，导入成功后保留模式、筛选与滚动基线。

### 3.2 iPad

- 复用现有 regular-width Shell，不嵌套新的顶级 `NavigationSplitView`；目标目录选择在 Sheet/Inspector 中完成。
- 拖放可作为后续快捷方式，但本波可见按钮、菜单和键盘路径必须独立完成全部操作。
- 导入状态在内容区或 Sheet 中显示准备、上传、取消与需核对；不会因为成功导入到不可见目录而偷偷改变导航。

### 3.3 Windows

- Files 继续使用专用页面；复制/移动业务放入新的 partial 文件和独立 ViewModel，不回填到主 code-behind。
- 目标选择使用原生 ContentDialog/页面内目录选择，48px 最小目标、可见标签、合理 Tab 顺序、Escape 安全取消、状态使用 Narrator polite live announcement。
- Photos 在现有页面命令区提供“导入照片或视频”；文件夹模式目标为当前 canonical 路径，时间线模式目标为当前照片空间根，并在提交前显示通俗目标说明。
- 系统选择器取消不显示错误；成功后若 profile 与目标仍匹配则刷新，否则只保留 Activity 结果，不切换页面。

## 4. 冻结契约与实现顺序

1. **Apple FILE-05 契约**：向后兼容新增操作、请求与结果型接口；Dsm concrete 固定公开 v3/FORM，复杂协调逻辑放入独立内部文件，聚合 Repository 只保留薄接线。
2. **Windows FILE-05 契约**：新增独立 Domain/Transport/Infrastructure 功能目录，复用 `MutationResult`，不扩展旧 Workspace 写入口。
3. **两端 PHOTO-03A**：只在 App 层适配系统选择器并复用现有上传/Activity；不修改 NAS 协议。
4. **两端 FILE-05 UI**：契约冻结后建立独立 state/model/view 或 ViewModel/partial，最后由唯一集成 owner 接 Shell/AppModel 生命周期。
5. **资源、工程与文档**：双语资源、XcodeGen、Shell/AppModel/Session、状态与平台矩阵由主 agent 串行收口。
6. **复核与云端出口**：未参与实现者只读对抗复核；本地轻量门；`codex/` 临时分支运行 GitHub 全量；全绿后整理单条简体中文提交并合并、复验、清理分支。

## 5. 文件所有权

| 热点 | 唯一 owner | 其他 owner 约束 |
| --- | --- | --- |
| Apple `DsmCore/FileStation.swift`、FILE-05 Network协调/薄接线与共享测试 | Apple FILE-05契约 owner | 不修改 Mobile、资源、工程、macOS App、Windows、文档 |
| Windows FILE-05 Domain/Transport/Infrastructure 与契约测试 | Windows FILE-05契约 owner | 不修改 App/UI/Shell/资源/文档 |
| Apple PhotosPicker adapter、Import feature 与照片聚焦测试 | Apple PHOTO-03A owner | 不修改共享 Package、资源、工程、Shell/Session热点 |
| Windows照片导入 feature、`PhotosPage.Import.cs` 与聚焦测试 | Windows PHOTO-03A owner | 不修改 Domain/Infrastructure、Shell、资源、文档 |
| Apple/Windows FILE-05 App/UI功能目录与页面最小接线 | 对应平台 UI owner；契约冻结后串行开始 | 不修改另一平台、共享契约、资源、文档 |
| Shell/AppModel/Session、双语资源、工程生成、账本、状态矩阵和最终Git集成 | 主 agent | 其他 owner 只交资源键与接线需求，不提交或推送 |

## 6. 必须自动化的门禁

### 6.1 FILE-05 契约

- 官方 CopyMove v3、FORM、单源/单目标、`overwrite=false` 的请求形态精确。
- canonical 路径、普通本地来源和目标、profile/repository identity、文件类型与大小基线严格。
- same target、目标位于源后代、remote/virtual/recycle/`#recycle`、目录、多项与覆盖请求在发送前拒绝。
- 同目标并发互斥；提交调用恰好一次；提交后取消、网络异常、解析失败、意外异常与坏回读均建立 blocker。
- copy 回读源保留且目标同类型/大小；move 回读源消失且目标同类型/大小；同 session 重建后未确认目标只回读、零二次写。

### 6.2 FILE-05 UI

- 选择、目标、操作、profile、repository 与 generation 冻结；迟到结果零回写。
- remote/recycle/`#recycle` 在 UI、handler 与模型三层零入口；预览、保存副本和只读分享不受影响。
- 关闭、切 profile、注销或销毁页面时取消请求并保持未知结果 blocker；明确 pre-submit cancel 才可安全重试。
- 44pt/48px、键盘/系统返回、VoiceOver/Narrator、Dynamic Type/200%、深浅/高对比和 Reduce Motion 均有源码或聚焦证据。

### 6.3 PHOTO-03A

- fake picker 覆盖选择、系统取消、读取失败、类型过滤与临时 artifact 生命周期。
- 单项图片/视频；普通本地目标；overwrite false；profile/repository/目标/generation 严格。
- 提交前取消清理 artifact；Activity 接管后不自动重放；成功只刷新仍匹配的当前目标。
- 空、筛选空、加载、错误、内容五态不隐藏导入入口；状态与错误有可访问名称和 live announcement。
- 生产源码不出现整库 PhotoKit 权限、后台备份、私有 Foto 请求或新的平行上传实现。

## 7. PENDING_USER_VALIDATION

- iPhone/iPad 真机：iCloud-only 图片/视频准备、PhotosPicker 取消、后台/前台切换、最大动态文字、VoiceOver、分屏与外接键盘；只回传脱敏错误类别，不回传照片内容或真实路径。
- Windows 10/11 x64 与 ARM64：FileOpenPicker、Narrator、高对比、200% 缩放、窄宽窗口、键盘与 Activity 生命周期。
- 真实 NAS：CopyMove v3 的权限、同卷/跨卷、任务字段、断线、提交后取消和回读延迟；照片上传权限与文件名冲突。未确认结果不得自动重放。
- 缺少真机或真实 NAS 不阻塞源码、合成测试和云端构建；目录/批量/跨 NAS/覆盖/回收站写入口继续关闭。

## 8. 当前验证证据

- Apple 移动端最新源码在 iPhone 17 Pro、iOS 26.5 Simulator 上完成 FILE-05 与 PHOTO-03A 六组聚焦测试：45/45 通过，0 失败、0 跳过；当前主机没有 iPad Simulator，不把该结果冒充 iPad 运行结论。
- Apple 共享层的 FILE-05 结果型 CopyMove v3 契约、会话级目标互斥、提交未知 blocker、独立回读及源大小/修改时间冻结已完成；最新 `DsmFileRepositoryTests` 为 103/103 通过。最终提交的 GitHub Apple Build 已复验共享 Package、DsmMac 与 File Provider 打包路径。
- Windows FILE-05 的 Domain、Transport、Infrastructure、WinUI 与 PHOTO-03A 复用 Activity 的源码和聚焦测试已完成；本机缺少 .NET/Windows SDK，因此只完成 XML、资源、请求契约、源码安全门和差异格式检查，明确标记 `BUILD_UNVERIFIED_WINDOWS_SDK_UNAVAILABLE`。
- 请求契约校验通过 92 份请求 Fixture 与 1 份写结果示例；引用 Fixture 校验通过 3 组、19 个引用；双语资源校验通过 Apple 3297、Android 1985、Windows 893 个键。
- FILE-05 继续只允许单个普通本地文件、同 NAS 普通本地目录与 `overwrite=false`。未知挂载类型、remote/virtual/recycle/`#recycle`、目录、批量、跨 NAS 和覆盖均在提交前拒绝。
- 未参与实现者对 PHOTO-03A 和 FILE-05 的最终只读终审结论为 P0/P1/P2 均为 0；最终提交已具备 GitHub `BUILD_VERIFIED` 证据，但不等同真机、系统选择器或真实 NAS 副作用验证。
- 整理后的单一功能提交 `1c7ee4851feb00903327b0599a0d29ea421be8c9`（`完善跨端文件复制移动与照片导入`）已合并到 `main` 并推送。云端证据：Apple Build run `31313485832` 通过共享 Package 655 项 XCTest（2 项按环境跳过）、Swift Testing 10 项、iPhone/iPad 通用应用构建及 macOS 打包；Android Build run `31313485840` 通过完整构建与静态门禁；Windows Build run `31313485833` 通过 815/815 xUnit，WinUI x64 与 ARM64 均 0 警告、0 错误；Repository Check run `31313485899` 通过。

## 9. 云端与提交策略

- 本波已按 `codex/` 临时分支策略完成验证、整理、合并与本地/远端临时分支清理。
- GitHub 已在最终提交上运行 Repository Check、Windows x64/ARM64、Apple iPhone/iPad/共享 Package/macOS 回归和 Android 未改动回归。
- 后续波次继续沿用同一策略：临时修正提交必须整理为一条简体中文功能提交；最终精确 SHA 全绿且 `main` 无未知新提交后才合并并推送。

## 10. 本波完成后继续对照的剩余项

- Windows：FILE-09 回收站恢复、文件夹/受限批量传输、Chat 核心与附件、Download 创建与低风险单任务控制、NAS 管理、统一 ModuleAvailability 和 W5/W6 系统集成。
- iPhone/iPad：FILE-09 回收站写、PHOTO-03 受限 NAS 内管理、Chat 文字/附件、Download 创建与单任务控制，以及 M8/M9 其余生产力与自动化。
- 两端：目录复制移动和跨 NAS 操作必须另建有界契约；回收站恢复必须证明不会退化为永久删除；没有版本化证据的内部写继续关闭。
