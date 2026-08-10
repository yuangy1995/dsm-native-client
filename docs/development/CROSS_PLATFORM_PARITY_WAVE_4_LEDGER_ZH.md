# Windows / Apple 移动端功能对齐账本：第 4 波

> 状态：ACT-01 首片源码已在当前分支落盘，并通过本地轻量门禁与 GitHub Apple/Windows/Repository 云端门禁；真机和真实 NAS 仍待用户验收
> 基线提交：`5850f4c0a7d35923e990f2cb5c48191cc160fd4e`（`接入跨端下载站 BT 搜索并更新进度文档`）
> 当前范围：Windows/iPhone/iPad `ACT-01 统一活动中心首片`，把 App 前台传输与已加载的 Download Station 任务快照按来源投影到 Activity
> 禁止范围：`android/**`、`apple/Apps/DsmMac/**`；系统通知、后台常驻、跨重启恢复、Activity 主动轮询 NAS、NAS 文件后台任务、任务暂停/继续/删除、RSS、文件优先级、BT 高级设置和 Download 设置写

## 1. 账本口径

- `完整`：源码、聚焦自动化与目标平台构建覆盖当前用户主流程；只能依赖真机、系统选择器或真实 NAS 的验收另记 `PENDING_USER_VALIDATION`。
- `部分`：已有可用流程，但跨平台构建、真实设备或真实 NAS 证据仍不完整。
- `关闭`：缺少稳定契约、行为证据或本波授权，生产入口保持隐藏、只读或能力门关闭。
- 本波只做“同一 Activity 入口中的来源分层展示”：App 自己发起的前台上传/下载继续保留取消、待核对和从头重试语义；NAS/Download 任务只显示最近加载的 Download Station 快照，不提供 Activity 内控制按钮。
- 本波不让 Activity 自己新增后台轮询或长期刷新职责。Download Station 页面成功加载、创建、暂停/继续、只移除任务或删除后，会把当前任务快照同步给 Activity；Activity 显示的是该 profile 当前进程内的最新已知快照。

## 2. 本波用户结果与边界

| 用户结果 | 当前事实 | 本波目标 | 安全与数据边界 | 明确非目标 |
| --- | --- | --- | --- | --- |
| Apple Activity 显示 Download Station 任务 | M2 前台传输 Activity 已有；Download Station 单任务、当前活动摘要和 BTSearch 已完成；`MobileTransferCoordinator` 曾保留通用 NAS task 类型但无生产同步 | 将当前 profile 的 Download Station 任务快照同步为 `source = .nas` 的 Activity 项，保留进行中、暂停、成功和失败状态，重复刷新不制造重复项 | 按 profile 隔离；Download 任务使用稳定 source identifier；NAS 项没有取消/重试入口；切换 profile 只显示对应 profile 的任务 | Activity 内暂停/继续/删除任务；Activity 主动请求 NAS；系统通知；后台 URLSession 或跨重启恢复 |
| Windows Activity 显示 Download Station 任务 | ForegroundTransferCoordinator 只展示 App foreground transfer；DownloadStationViewModel 已有任务快照和安全控制链 | Download Station ViewModel 在任务列表成功加载或本机安全操作更新后，把任务快照同步给 ForegroundTransferCoordinator；Activity 页面显示来源标签、暂停状态和只对 App 任务可见的取消按钮 | NAS 项 `Source = Nas`，取消按钮只对 `Source = App` 的 running 任务显示；profile 切换不会把 NAS 任务误标为本机已取消 | Activity 内任务控制；主动后台刷新；托盘/系统通知；真实设备系统集成 |
| 文档与验收边界 | 旧进度段落需要跟随源码更新 | 将状态更新为“ACT-01 首片源码已落，本地轻量门与云端门禁通过，真机/真实 NAS 待验收” | 不把云端构建冒充真实 NAS 或设备交互；不提升 Download Station 真实兼容等级 | 不把系统通知、NAS 后台文件任务和完整 Activity 中心写成已完成 |

## 3. 交互转换

### 3.1 iPhone / iPad

- Activity 列表继续使用现有来源、方向、进度和状态文案；新增“已暂停”状态。
- App 来源任务保留取消和安全从头重试；NAS/Download 来源任务只展示状态，不显示取消或重试。
- Download Station 页面成功更新当前快照后，同步给 Activity。若用户从未加载 Download Station，Activity 不伪造 NAS 任务。
- iPad 复用同一 SwiftUI 通用视图，不新增独立导航或后台轮询。

### 3.2 Windows

- Activity 页面新增来源文案：App 传输 / NAS 下载任务。
- 取消按钮继续只出现在 App 自己发起的 running 任务上；NAS 暂停任务显示“已暂停”，但不在 Activity 中提供控制。
- Download Station 页面创建、删除或刷新任务列表后同步 Activity；同步仅使用当前已加载快照。
- Shell 继续把同一个 `ForegroundTransferCoordinator` 注入 Download Station 与 Activity 页面，避免出现两个彼此不知情的活动列表。

## 4. 实现顺序与文件所有权

1. **Apple Activity 模型**：为 Activity task 增加稳定来源标识与暂停状态；NAS task 禁用取消/重试。
2. **Apple Download 同步**：Download Station snapshot 在加载和任务变更后同步到 Activity coordinator。
3. **Windows Activity 模型**：Foreground transfer 增加 App/NAS 来源、source identifier 和 paused 状态。
4. **Windows Download 同步**：DownloadStationViewModel 把当前 profile 的任务快照同步到 ForegroundTransferCoordinator；Shell 使用同一个 coordinator。
5. **资源、测试与文档**：补英中来源/暂停文案、聚焦行为测试、source contract、状态文档和平台矩阵。
6. **云端出口**：当前分支本地轻量门通过后，通过 GitHub Apple/Windows/Repository 门禁；全绿后整理为单条简体中文提交。

## 5. 必须自动化的门禁

- Download Station 同一任务 ID 多次同步不会重复创建 Activity 项。
- 新快照缺失的 Download Station 任务会从当前 profile 的 NAS Activity 投影中移除。
- NAS/Download 投影项不会显示取消或从头重试。
- profile 切换不会把 NAS 下载任务误标为 App 取消结果。
- Windows Activity 取消按钮源码门必须同时检查 `Source == App` 与 running 状态。
- Shell/Download 页面必须注入同一个 Activity coordinator。
- 双语资源必须覆盖“App 传输 / NAS 下载任务 / 已暂停”，占位符一致。

## 6. 当前验证证据

- Apple：`MobileActivityPresentationTests` 已新增 Download Station 快照同步和移除测试；本机 iPhone 17 Pro 模拟器聚焦 `MobileActivityPresentationTests` 通过。GitHub `Apple Build` run `31358741106` 通过共享包 675 项 XCTest（2 跳过）+ 10 项 Swift Testing、工程生成、iPhone/iPad 通用应用构建、macOS 打包与产物上传。
- Windows：`ForegroundTransferCoordinatorTests` 已新增 Download Station NAS 投影、去重、移除和 profile 切换测试；`TransferActivitySourceContractTests` 已新增来源标签、暂停状态、取消按钮和 Shell 注入源码护栏。GitHub `Windows Build` run `31358741100` 通过 889/889 项 .NET xUnit，并完成 WinUI x64 与 ARM64 构建。
- 共同轻量门：本地化检查已通过，当前双语资源统计为 Apple 3,462、Android 1,985、Windows 1,074；`TransferActivityPage.xaml` 与 Windows 双语 resw XML 可解析；`git diff --check` 通过。
- 仓库门禁：GitHub `Repository Check` run `31358741044` 通过。上述云端证据不等同真机、系统无障碍或真实 NAS 字段验收。

## 7. PENDING_USER_VALIDATION

- iPhone/iPad：Activity 页面中 Download Station 进行中、暂停、完成和错误任务的展示；VoiceOver、动态文字、深浅色和横竖屏；切换 profile 后不显示旧 profile 任务。
- Windows 10/11 x64 与 ARM64：Activity 页面来源标签、暂停状态、取消按钮只对 App 任务可用；Narrator、高对比、200% 缩放、窄宽窗口和键盘路径。
- 真实 NAS：Download Station 任务状态、大小、下载字节、暂停和错误字段在真实 DSM/Download Station 版本中的表现。真实任务控制仍在 Download Station 页面验收，不通过 Activity 新增控制。

## 8. 本波完成后继续对照的剩余项

- ACT-01 后续：Activity 主动刷新 NAS/Download 任务、NAS 文件后台任务分区、系统通知、托盘/通知中心联动、长期后台和跨重启恢复。
- CHAT-03：Apple 单附件 typed outcome 与 Windows 上传、缩略图、下载 typed 契约，再接附件 UI。
- NAS-02/NAS-04：有界只读套件、计划任务、日志和当前连接详情；不接断开连接、套件生命周期、任务执行或设置写。
- Download Station：RSS、文件优先级、BT 协议高级设置、设置写和删除已下载数据继续关闭。
