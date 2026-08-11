# Windows / Apple 移动端功能对齐账本：第 3 波

> 状态：A0/W0 共享契约、A1/W1 Files 受限入口和 A2/W2 Photos 受限恢复入口已落盘；Files 基线已通过 GitHub Apple/Windows/Repository 门禁，Photos 入口已整理为单条简体中文功能提交，并通过 Apple/Windows/Repository 最终云端门禁
> 基线提交：`1c7ee4851feb00903327b0599a0d29ea421be8c9`（`完善跨端文件复制移动与照片导入`）
> 当前范围：Windows/iPhone/iPad `FILE-09 移入回收站与从回收站恢复`；Windows 后续增量包含单个普通本地文件夹
> 禁止范围：`android/**`、`apple/Apps/DsmMac/**`；永久删除、清空回收站、Apple 移动端目录、批量恢复、跨 NAS 恢复、覆盖恢复、猜测原路径、内部 Core RecycleBin 清理接口、Chat/Download/NAS 写操作

## 1. 账本口径

- `完整`：源码、聚焦自动化和目标平台构建覆盖单项文件主流程；只能依赖真机、系统选择器或真实 NAS 的验收另记 `PENDING_USER_VALIDATION`。
- `部分`：已有可用流程，但结果型契约、状态、错误恢复、自动化或目标平台构建证据仍不完整。
- `关闭`：缺少稳定契约、行为证据或本波授权，生产入口保持隐藏、只读或能力门关闭。
- “移入回收站”只允许在已发现的同共享 `#recycle` 入口存在时提交；首片只支持单个普通文件，成功必须同时回读确认原路径消失、回收站目标文件出现。
- “恢复”只允许对可解析的 `/share/#recycle/...` 单个普通文件恢复到同一共享的原位置；无法推导原位置、目标已存在或目标不可写时拒绝提交。
- Windows 后续增量允许上述两条中的单个普通本地文件夹，沿用同一 Delete v2/CopyMove v3 安全链；目录只按顶层源消失与目标同类型存在确认，不声称逐项验证递归内容。Apple 移动端与 Photos 不随此增量扩围。
- 本地只执行形态、资源、请求契约和聚焦低负载测试；Windows x64/ARM64、Apple iPhone/iPad、共享 Package/macOS 回归与 Android 未改动回归交给 GitHub 分支门禁。
- 同一功能的验证修正可以产生临时提交；正式历史必须整理为一条语义完整的简体中文提交，最终精确 SHA 重新跑全量门禁后才能合并 `main`。

## 2. 本波用户结果与边界

| 用户结果 | 当前事实 | 本波目标 | 安全与数据边界 | 明确非目标 |
| --- | --- | --- | --- | --- |
| Apple/Windows 单项移入回收站 | Apple 共享层已有 `moveToRecycleResult`、Delete v2 任务、已发现回收站入口校验和精确回读；Windows W0 已新增 `IFileRecycleRepository`、Delete v2 transport、Repository 源码与契约测试，并通过 GitHub Windows Build | 在 Files 中对单个普通本地文件显示“移入回收站”；提交一次；通过独立回读确认原路径消失且 `#recycle` 目标文件出现后才显示成功 | profile/repository/canonical item/generation 冻结；权限、已发现回收站入口与普通本地来源门；提交未知进入核对 blocker；目录、`#recycle`、remote、virtual 和回收站后代不允许再次移入回收站 | 永久删除、清空回收站、目录删除、多项批量删除、后台队列、删除后立即自动恢复 |
| Apple/Windows 单项恢复 | Apple 共享层已有 `restoreFromRecycleResult`，复用 CopyMove v3 `remove_src=true`、`overwrite=false` 与独立回读；Windows W0 已新增同义 Restore 结果链与二次提交 blocker，并通过 GitHub Windows Build | 在只读回收站位置中对单个可解析普通文件显示“恢复”；使用受限结果型契约将文件移回同共享原位置；严格回读确认回收站源消失且目标出现 | 只接受同共享根、单个普通文件、无覆盖、普通本地原目标；提交后取消、断线或坏回读只核对不重放；未确认结果跨页面重建保持 blocker | 猜测被移动过的原目录、跨共享恢复、覆盖恢复、恢复目录、恢复到用户另选目录、永久删除 |
| Photos 回收站入口 | Photos 已有文件夹、时间线、预览、导入和只读回收站位置；本切片已在 iPhone/iPad 网格、时间线和查看器，以及 Windows 文件夹/时间线视图中仅对 `#recycle` 普通文件接入恢复 | 首片只让 Photos 中位于回收站路径的普通文件复用同一恢复结果链；普通照片删除/批量管理可后续拆分 | 复用 Files 的结果型恢复契约和当前 photo item canonical revision；Windows 复用同一 `FileRecycleViewModel` 与 session blocker；不新增 Foto 私有 API | 删除系统图库项目、目录或批量恢复、整库管理、智能相册回收站、批量照片恢复 |

## 3. 交互转换

### 3.1 iPhone

- Files 单项菜单提供“移入回收站”；首片只在已发现回收站入口覆盖的普通本地文件来源显示。
- 回收站位置中的可恢复项提供“恢复”；不可解析原路径时只显示说明，不出现提交按钮。
- 提交中禁止下滑关闭；只有明确写前取消才回到表单，其余未知结果进入核对态。
- 成功后刷新仍匹配的当前父目录或回收站目录；不会自动跳转到原位置。

### 3.2 iPad

- 复用现有 Files/Photos regular-width 布局，不新增顶级分栏。
- 菜单、键盘路径和触控路径都能完成主流程；右键或指针菜单不是唯一入口。
- 回收站恢复核对态在当前 Sheet/Inspector 内显示，不弹出开发者术语。

### 3.3 Windows

- Files 继续使用专用页面；FILE-09 业务放入新的 partial 和独立 ViewModel，不回填到主 `FilesPage.xaml.cs`。
- 移入回收站和恢复使用原生 ContentDialog，48px 最小目标、可见标签、合理 Tab 顺序、Escape 安全取消和 Narrator polite live announcement。
- Remote/Recycle source 的写入口必须精确区分：普通回收站来源允许“恢复”，但隐藏上传、创建分享链接、复制/移动到回收站等不适合动作。
- Photos 若接入恢复，只复用同一个结果型恢复 ViewModel，不建立照片专用写协议。

## 4. 冻结契约与实现顺序

1. **A0/W0 共享结果型契约**：Apple 新增 `moveToRecycleResult` 与 `restoreFromRecycleResult`，Windows 新增独立 `IFileRecycleRepository`；旧 void delete 保留兼容但 UI 不调用。
2. **A0/W0 生产 Repository**：移入回收站固定公开 `SYNO.FileStation.Delete` v2，并要求已发现回收站目标精确回读；恢复复用公开 `SYNO.FileStation.CopyMove` v3 `remove_src=true`、`overwrite=false`，且必须证明不会退化为永久删除或覆盖。
3. **A1/W1 Files UI**：契约冻结后建立独立 state/model/view 或 ViewModel/partial，接入 Files 单项菜单和回收站位置菜单。
4. **A2/W2 Photos 受限入口**：只在回收站路径项目上复用恢复流程；普通照片删除另切片。
5. **资源、工程与文档**：双语资源、XcodeGen、Shell/AppModel/Session、状态与平台矩阵由主 agent 串行收口。
6. **复核与云端出口**：未参与实现者只读对抗复核；本地轻量门；`codex/` 临时分支运行 GitHub 全量；全绿后整理单条简体中文提交并合并、复验、清理分支。

## 5. 文件所有权

| 热点 | 唯一 owner | 其他 owner 约束 |
| --- | --- | --- |
| Apple `DsmCore/FileStation.swift`、DsmNetwork 删除/恢复结果链与共享测试 | Apple FILE-09 契约 owner | 不修改 Mobile、资源、工程、macOS App、Windows、文档 |
| Windows FILE-09 Domain/Transport/Infrastructure 与契约测试 | Windows FILE-09 契约 owner | 已落盘并由 GitHub Windows Build 验证；未修改 App/UI/Shell/资源 |
| Apple Files/Photos FILE-09 移动 UI 与聚焦测试 | Apple FILE-09 UI owner | 不修改共享 Package、资源、工程、Shell/Session 热点 |
| Windows Files/Photos FILE-09 App/UI 与聚焦测试 | Windows FILE-09 UI owner | 不修改 Domain/Infrastructure、Shell、资源、文档 |
| Shell/AppModel/Session、双语资源、工程生成、账本、状态矩阵和最终 Git 集成 | 主 agent | 其他 owner 只交资源键与接线需求，不提交或推送 |

## 6. 必须自动化的门禁

### 6.1 移入回收站契约

- 官方 Delete v2、FORM、单文件请求形态精确，任务轮询和独立目标回读不可省略。
- canonical 路径、普通本地来源、已发现回收站入口、profile/repository identity 和文件类型/大小/修改时间基线严格。
- 目录、remote/virtual/recycle/`#recycle`、根目录、空路径和多项请求在首片 UI 发送前拒绝。
- 同目标并发互斥；提交调用恰好一次；提交后取消、网络异常、解析失败、意外异常和坏回读均建立 blocker。
- 成功必须表示目标离开原父目录且同共享 `#recycle` 目标文件出现；如果真实 DSM 对同名回收站路径有额外命名策略，需在真实 NAS 验收中记录并另切片适配。

### 6.2 恢复契约

- `RecycleLocation` 只能接受共享根下第一层 `#recycle`；拒绝 `/share/archive/#recycle/...` 这类伪路径。
- 恢复目标为同共享原位置，`overwrite=false`，写前确认目标不存在且父目录可写。
- 恢复提交后独立回读必须同时确认回收站源消失、原目标出现且类型/大小匹配。
- 成功响应但回读不一致、任务状态未知、提交后取消和网络断开均进入核对态，不自动重放。
- 未确认恢复结果在同 profile、同源回收站路径和同目标路径下跨页面重建仍只回读。

### 6.3 UI

- 选择、目标、操作、profile、repository 与 generation 冻结；迟到结果零回写。
- 移入回收站与恢复必须具备普通确认、提交中状态、取消、需核对、权限不足、目标冲突和不支持状态。
- 写入口可见性与 handler/model 双门一致；预览、保存副本和只读分享不受影响。
- 44pt/48px、键盘/系统返回、VoiceOver/Narrator、Dynamic Type/200%、深浅/高对比和 Reduce Motion 均有源码或聚焦证据。

## 7. PENDING_USER_VALIDATION

- iPhone/iPad 真机：Files 与 Photos 菜单、确认弹窗、下滑取消、最大动态文字、VoiceOver、分屏与外接键盘。
- Windows 10/11 x64 与 ARM64：ContentDialog、Narrator、高对比、200% 缩放、窄宽窗口、键盘与页面生命周期。
- 真实 NAS：共享目录启用/关闭回收站时 Delete v2 行为、权限拒绝、断线、提交后取消、回读延迟、同名回收站路径策略、恢复到原目录的 CopyMove 任务字段和同名冲突。
- 未验证真实 NAS 前，入口必须清楚显示“移入回收站”而不是“永久删除”；永久删除和清空回收站继续关闭。

## 8. 当前验证证据

- 当前基线提交 `1c7ee4851feb00903327b0599a0d29ea421be8c9` 已通过第 2 波四组云端门禁，但该证据只覆盖 FILE-05 与 PHOTO-03A。
- Apple 共享层已新增 `moveToRecycleResult` 与 `restoreFromRecycleResult`，并通过 `DsmFileRepositoryTests` 107/107；`RecycleLocation`、`discoverRecycleLocations()` 和 FILE-05 `copyMoveResult` 继续作为契约事实来源。Apple Files UI 已接入单个普通本地文件移入回收站与回收站位置恢复，本机 iPhone 17 Pro iOS 26.5 模拟器聚焦 42/42 与完整 DsmMobile 375/375 通过；提交 `ba34f7af81e0638e1347ba6189fbdba1aa951e37` 的 GitHub `Apple Build` run `31318490495` 已通过共享包测试、工程生成、iPhone/iPad 通用应用构建和 macOS 打包。Photos 受限恢复入口已在网格、时间线和查看器中复用同一恢复流程，本机聚焦 `MobileFileRecycleActionPresentationTests` 与 `MobilePhotoViewerPresentationTests` 通过；单条功能提交已通过 GitHub `Apple Build`。真实 iPad 交互、真机和真实 NAS 回收站行为仍待验收。
- Windows 已新增 `IFileRecycleRepository`、`FileRecycle*` 领域模型、Delete v2 start/status transport、`DsmRepository.FileRecycle` 与 `Files/Recycle` 聚焦测试源码；Windows Files UI 已接入 WinUI ContentDialog 受限入口、普通/回收站来源门和 session blocker，并通过本机 XAML/resw XML、本地化和源码形态静态门。提交 `ba34f7af81e0638e1347ba6189fbdba1aa951e37` 的 GitHub `Windows Build` run `31318490511` 已通过 830/830 xUnit，WinUI x64 与 ARM64 均 0 警告、0 错误；同提交 `Repository Check` run `31318490509` 通过。Photos 受限恢复入口已在文件夹视图、时间线选择和 Shell profile 门中复用同一恢复 ViewModel 与对话框；单条功能提交已通过 GitHub `Windows Build` 与 `Repository Check`。真实 Windows 设备、Narrator、键盘、系统生命周期和真实 NAS 副作用仍待验收。
- Windows 单文件夹增量已扩展同一 `FileRecycleTarget`、Repository 回读、ViewModel 来源门与 ContentDialog：目录写前重读类型、修改时间和当前删除权限，恢复另复用目标权限检查；同名或权限变化零写入，父文件夹与后代项目路径互斥，结果回读匹配目录类型与修改时间，未知结果继续阻断重放。文件夹专用确认与结果文案已加入英中资源，本机 Files Recycle 聚焦 21/21、Release 完整 xUnit 985/985、本地化、XML 与差异检查通过；GitHub Windows Build `31462403976` 已通过 985/985 与 WinUI x64/ARM64 0 警告、0 错误，Repository Check `31462403992` 已通过。
- Windows FILE-07 分享链接管理增量复用公开 Sharing v3 `list`/`delete` 契约，新增严格有界列表、复制和单条确认撤销。删除以完整链接基线和稳定 ID 预检，同 ID 防重复，固定一次提交；取消、断线或未知结果保存在 API 会话/profile 级内存复核门，跨 Files 页面与 Repository 重建只回读不重放，ID 消失才确认成功。WinUI 以次级命令和原生 ContentDialog 覆盖加载、空、错误、不可用、列表、确认、删除中及结果状态，每次本地展开 100 条；密码仅展示保护状态，不进入界面、剪贴板或日志。本机 Files Sharing 聚焦 113/113、Release 完整 xUnit 1002/1002、本地化、XML 与差异检查通过；GitHub Windows Build `31465173331` 已通过 1002/1002 与 WinUI x64/ARM64，Repository Check `31465173335` 已通过。Apple 移动端范围未变，批量撤销与编辑链接不在本切片。
- 请求契约已有 `contracts/request-fixtures/file-station/delete/synthetic-task/request.json`；恢复首片复用现有 CopyMove v3 合成形态，Windows W0 已新增 Delete start/status typed transport 与契约测试。

## 9. 本波完成后继续对照的剩余项

- Windows：文件夹/受限批量传输、Chat 核心与附件、Download 创建与低风险单任务控制、NAS 管理、统一 ModuleAvailability 和 W5/W6 系统集成。
- iPhone/iPad：PHOTO-03 其余 NAS 内管理、Chat 文字/附件、Download 创建与单任务控制，以及 M8/M9 其余生产力与自动化。
- 两端：目录复制移动和跨 NAS 操作必须另建有界契约；永久删除、清空回收站和覆盖恢复必须另建危险写契约；没有版本化证据的内部写继续关闭。
