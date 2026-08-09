# 当前开发进度

> 最后更新：2026-08-10
> 当前里程碑：`五种设备形态的原生客户端对齐、分平台验收与桌面云盘位置`

本文是功能完成情况、自动化结果、下一步和阻塞项的唯一事实来源。路线图、平台矩阵和专项计划不重复维护实时状态；发生冲突时以本文和同一源码版本的可复现验证结果为准。

当前状态只记录本仓库可见源码和可复现证据，不推测尚未进入工作区的实现。Android
当前由专项计划维护稳定目标账本；本文只保留最新验证快照、跨平台事实和阻塞，不重复
保存每个历史切片的目标清单。

“已实现”“构建通过”和“真实设备通过”不是同义词。发布判断统一使用
[功能实现与验证等级](../quality/VERIFICATION_LEVELS_ZH.md)；没有正式签名或真实
设备证据时，不得从源码、单元测试或无签名构建推断系统集成已经可用。

## 总体状态

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 单仓库与文档 | 已完成 | 契约、架构、安全、兼容和平台目录已经建立 |
| 请求契约与统一写操作结果 | RC0/MR0 已实现，RC1 第二十二批、RC2 首批和 MR2 Chat 会话创建批次已测试 | 请求 Fixture Schema、敏感参数仅记录存在、隐私/危险重试门禁和 CI 已接入；Apple 已对照 File Station、账号/群组、套件、容器/VMM、Download Station、QuickConnect、物理网卡、S.M.A.R.T. 检测、安全、硬件、远程访问、文件服务、远程终端、互联网代理、区域与时间、DDNS 设置及 NAS 电源动作四十八份请求快照，主要危险操作已贯通统一结果语义；官方 File Station 后台任务列表 v3 的 Apple 共享实现与 macOS 传输中心界面已完成并通过 13 项聚焦测试，真实 DSM 只读响应尚未验收，`clear_finished` 保持关闭。当前契约校验器通过 92 份请求 Fixture 与 1 份写结果示例；Android 统一断言此前覆盖 79 份公共请求 Fixture；第 78 批新增 Download Station `Task.edit` v1，第 79 批新增公开 VMM `Guest.Image.create` v1，第 80 批新增公开 VMM `Task.Info.clear`、Download Station BTSearch 目录/列表与 Statistic 当前活动请求。请求方法校验器最小支持官方 lowerCamelCase，仍拒绝首字母大写和非法字符。Android 已从 Repository 实际调用链验证 File Station、容器和公开 VMM 删除，公开 VMM 仅发送 `guest_id`，旧内部接口保留兼容参数；Android Chat 文字、单附件、首次单聊、私人群聊、消息提醒、纯文字定时消息与无附件投票创建已接入稳定结果、防重复及断线/取消后只回读不重放；Windows 当前契约测试已纳入 691 项 .NET 10 xUnit 云端门禁并全部通过，未验证的危险写入口继续保持关闭。打印机 Bonjour 共享和安全扫描状态因证据不足保持关闭 |
| 五端双语本地化 | 已实现 | 英语与简体中文资源、跟随系统、英语回退、用户指定语言、本机持久化和跨端资源校验已接入 |
| API 参考 | 进行中 | 官方与内部 API 已分类；随实机差异继续补充 |
| 社区兼容性计划 | 第一阶段契约与维护者辅助流程已实现，macOS 草稿导出已实现 | `schemaVersion` 2 必须记录受限源码提交，并以固定 `stage`、错误类别、API 名称/版本、HTTP 状态、是否重试和 `rawResponseIncluded=false` 描述失败，禁止错误正文和原始响应；`testSuiteVersion` 1/2 分别固定 14/19 项能力，报告必须完整列出对应版本全部结果；非 macOS 的桌面云盘结果强制为 `not-supported`。独立 submission 草稿契约不含报告编号、来源和审核状态，macOS 设置页通过字段白名单、预览和隐私确认后原子导出；只读候选工具只向标准输出生成报告和双语矩阵差异，正式报告可用 `supersedes` 建立人工审核的取代链；重复身份和无效关系阻断，相同环境匹配、冲突与状态不一致形成警告。Issue 表单、双 Schema、自定义校验器和固定 `jsonschema 4.25.1` 的 Draft 2020-12 CI 已同步，当前尚无已审核社区报告 |
| Apple 共享工程 | 进行中 | Swift Package、macOS App、iPhone/iPad 通用 SwiftUI App 和 Apple CI 已建立 |
| macOS 文件客户端 | 需要验证 | 主要功能已实现并通过自动化测试，正在收集真实 NAS 兼容证据 |
| 桌面云盘位置 | `IMPLEMENTED`、`UNIT_TESTED`、`BUILD_VERIFIED`、`SIGNING_REQUIRED` | 双平台只读源码已完成：按需读取、文件/目录离线保留、递归空间预检、分项缓存、LRU、缓存卷、后台驻留和恢复均已接入；macOS 创建/移除已接入可恢复事务，覆盖启动续清理、系统盘 domain 补注册、外接卷保护、孤立 domain 清理、单条 runtime 损坏隔离、配置最后成功只读快照、运行时状态转换约束、恢复最终提交/连续写失败、共享会话重新认证及 profile 级待清理续办；主 App 与 Extension 已通过 fake/单元测试覆盖初始、逐任务、8 MiB 进度阈值和轮询容量复查、已完成字节扣除、并发软上限准入式临时 LRU 与在途额度预留、完整 staging 准入、下载 Task 取消、partial 清理、确定性超时及主要本地提交补偿，外接卷探针已有单元测试，诊断摘要已有固定字段白名单和敏感值/禁止键结构测试；继续使用应用内 AES-GCM，只有存在映射时才共享不含密码的最小会话；仍需正式签名 Finder、真实卷容量/释放、系统传输取消、App Group、共享 Keychain 与真实 NAS 验收 |
| 照片管理模块 | 进行中 | 文件夹扫描已获实机确认；macOS 时间线、搜索筛选、预览、详情和基础管理源码已实现，等待完整实机与性能验收 |
| Synology Chat 模块 | 进行中 | macOS 与 Android 均已接入首次单聊、单附件收发、提醒管理、纯文字定时消息、无附件投票创建和 Socket.IO 实时刷新；Android 另具私人群聊创建、本地置顶、未读汇总、图片与视频预览及有界轮询降级，首次单聊和私人群聊已接入稳定结果、防重复、成员回读与取消后不重放。当前源码新增 iPhone/iPad 与 Windows 受限纯文字发送：固定 Chat Post v5，成功必须回读确认，提交未知进入核对且不自动重放；Apple 聚焦测试已通过，Windows 本地轻量门已通过但待 GitHub Windows Build。服务器已读、投票参与/关闭、附件、实时、语音、加密和真实 Chat Server 行为仍待后续切片或实机验收 |
| NAS 设置模块 | 需要验证 | 已接入存储、USB/eSATA 外接存储与内存压缩只读摘要、套件、任务、账号、系统活动、电源计划只读摘要、日志、连接、文件服务、远程终端、代理、物理网卡、DDNS、区域时间、远程访问、防火墙基础控制、安全防护、局域网发现、风扇/提示音、休眠节能及 UPS；系统活动最多保留 500 项白名单快照，电源计划最多保留 128 条并拒绝歧义星期，外接存储每种连接最多保留 64 项且只解释明确字节字段，内存压缩只保留启用状态、明确字节容量和算法白名单；四者真实 DSM API 响应尚未验证，内存压缩仅在官方页面完成只读观察，电源计划保存、USB 安全弹出和内存压缩设置保持关闭；Android 的文件服务、远程终端、互联网代理、区域与时间、远程访问、当前连接断开、物理网卡、DDNS、安全防护及硬件/休眠/UPS 十类界面已保留八类原始结果、三项计数、异常和草稿/目标，并以共享原子门闩、持久状态卡与专项刷新门禁保护重复提交和未确认结果；远程访问固定使用 QuickConnect v3 与 UPnP v1，严格 Boolean 读取，单端失败保留另一端并以 null 降级；只有已记录环境开放写入，可信中继连接禁止关闭中继，写入使用全局互斥，取消或断线后只回读且不重放；只有本次实际变更字段均回读为明确 Boolean 才完成专项刷新，危险结果核对前阻止切换 NAS 或退出登录；第 53 批又将账号/群组删除与套件启动、停止、卸载迁移为独立持久结构化反馈，Repository 使用完整稳定目标作严格写前基线，写后按操作执行严格专项列表读取，读取失败不折叠为空列表；进行中写入、专项刷新及尚未核对的危险结果会阻止切换 NAS 或退出登录，不能借离页绕过结果门禁；DDNS 测试、保存、立即更新与删除互不隐式串联，密码在请求接管时立即从状态清除，测试不保存，保存/删除模糊结果只回读不重放；安全和硬件设置使用原始双基线、固定版本、字段可信门禁及整体回读，UPS 明确空地址与缺失字段不会混淆，未知原始字段禁止写入；物理网卡另严格校验固定 v1/v2、完整详情、稳定身份和编辑前原始基线，读取失败不再伪装为空列表，刷新后继续编辑会重建最新基线；区域配置与立即校时分阶段确认，当前连接按原始身份专项回读且连接列表读取失败不再伪装为空列表；套件启动/停止/卸载、账号/群组删除、物理网卡、安全设置、S.M.A.R.T. 检测启停、硬件、远程访问、文件服务、远程终端、互联网代理、区域与时间、DDNS 设置及 NAS 关机/重启已区分确认成功、明确拒绝、部分成功、提交未确认与取消，未知结果会要求重新连接、读取相关设置或检查设备后核对，且不自动重放；套件操作会先确认当前状态、许可和影响，写后只通过列表核对，不把请求响应冒充最终状态；DDNS 测试不会隐式保存或立即更新，电源动作接受结果不冒充最终设备状态，模糊电源提交在重新连接并检查 NAS 前不能关闭反馈或再次操作；真实写操作等待专用测试目标实机验收 |
| iPhone/iPad 客户端 | Download 单任务控制与 URL/磁力创建 UI 已接入；云端门禁已通过，待真实 NAS 与真机验收 | 在前两波 Files/位置/分享/预览、新建/重命名和 PHOTO-01/02 基础上，第 2 波新增 FILE-05 单个普通本地文件同 NAS 复制/移动与 PHOTO-03A PhotosPicker 单项主动导入；第 3 波 FILE-09 已在 Files 中接入单个普通本地文件“移到回收站”和回收站位置“恢复”，并在 Photos 网格、时间线和查看器中只对 `#recycle` 普通文件复用同一恢复流程；使用共享 `moveToRecycleResult` / `restoreFromRecycleResult`，提交未知跨页面 blocker 防重放。第 4 波 `codex/wave4-download-control` 已新增 Download Station 单任务暂停/继续结果契约，固定官方 `SYNO.DownloadStation.Task` v1，移动端详情页只显示当前任务可用的暂停或继续操作，提交未知要求刷新核对且不自动重放；当前源码又接入 URL/磁力链接创建入口，复用共享 typed 结果契约和官方 v1 `create`，通过原生 Sheet 输入单个链接，成功时插入确认任务，提交后取消、断线、缺失 task id 或回读不一致均要求核对并防止自动重放；任务文件创建、删除、批量、RSS/BT 高级和设置写继续关闭。本机已通过共享 `DsmServiceManagementRepositoryTests` 59/59、请求契约校验 92 份 Fixture、下载创建契约 GitHub Apple Build、本次 `MobileDownloadsSafetyTests` 5/5 聚焦测试，以及主线提交 `5630c0a` 对应的 GitHub `Apple Build` run `31330832563` 与 `Repository Check` run `31330832619`；当前主机无 iPad Simulator，不把 iPhone 模拟器结果冒充 iPad 或真机结论。真实 NAS 的任务状态、权限、取消时机、iPad 交互和真机仍待验证。 |
| Android 客户端 | 开发目标完成，需设备验收 | 第 89 批经用户明确授权按移动端场景最终冻结目标：A0–A8 为 187/187（100%），剩余 0 项。三路独立审计与已登录 DSM 复核确认，Chat 服务器已读、Download 单文件优先级、Container 详情/资源/近期日志、单镜像拉取和平板 noVNC 均缺少可复验私有契约、稳定身份或 Android 非持久会话隔离，因此保留为“版本化契约后再评估”，不冒充已实现，也不以猜测请求阻塞当前移动端范围。NAS 级下载配置、容器详细运维、VMM 控制台与高级管理使用 DSM Web/桌面端。纯设备矩阵迁入 A9 并保持 `PENDING_USER_VALIDATION`；Photos 共享空间根目录使用 opaque 令牌、公开 `getinfo` 重读和权限拒绝恢复。 |
| Windows 客户端 | Download 单任务控制与 URL/磁力创建 UI 已接入；云端门禁已通过，待真实 Windows/NAS 验收 | 在前两波 Application 边界、Files/位置/预览/传输/分享、PHOTO-01、自签证书和 FILE-03 基础上，第 2 波新增 FILE-05 单文件同 NAS CopyMove v3 与 PHOTO-03A 单项媒体导入；第 3 波 FILE-09 已在 Files 页面接入单个普通本地文件“移到回收站”和回收站位置“恢复”，并在 Photos 文件夹和时间线中只对 `#recycle` 普通文件复用同一恢复流程；复用 `IFileRecycleRepository`、WinUI ContentDialog、普通来源/回收站来源双门与进程会话 blocker。第 4 波 `codex/wave4-download-control` 已在 Windows Domain/Infrastructure/ViewModel/WinUI 页面接入 Download Station 单任务暂停/继续，固定官方 `SYNO.DownloadStation.Task` v1，使用稳定任务基线、单次提交、独立回读和进程会话 review blocker；当前源码又在 WinUI Download Station 页面接入 URL/磁力链接创建入口，复用 typed 结果契约和官方 v1 `create`，通过 ContentDialog 输入单个链接，成功时刷新并呈现确认任务，提交后取消或缺少 task id 进入核对提示并防重放；任务文件创建、删除、批量、RSS/BT 高级和设置写继续关闭。本机已通过请求契约校验、差异格式、源码形态、XAML/resw XML、本地化、C# 形态和新增 xUnit 源码护栏；下载创建契约已通过 GitHub Windows Build 的 xUnit、WinUI x64 与 WinUI ARM64 构建以及 Repository Check，本次 UI 已随主线提交 `5630c0a` 通过 GitHub `Windows Build` run `31330832524` 与 `Repository Check` run `31330832619`。真实 NAS、Narrator、键盘、系统生命周期和任务控制副作用仍待验收。 |

### 第 2 波已合并（单一简体中文功能提交已全绿）

- 基线：`641852b408ae24f8819e4a49cd70df4c8d9e5011`；功能对齐账本见[第 2 波账本](../development/CROSS_PLATFORM_PARITY_WAVE_2_LEDGER_ZH.md)。
- 最终提交：`1c7ee4851feb00903327b0599a0d29ea421be8c9`（`完善跨端文件复制移动与照片导入`），已在 `main` 与 `origin/main`。
- Apple：本机六组移动聚焦 45/45、共享 FILE-05 聚焦 103/103；最终提交对应 GitHub `Apple Build` run `31313485832` 通过共享 Package 655 项 XCTest（2 项按环境跳过）、Swift Testing 10 项、iPhone/iPad 通用应用构建和 macOS 打包。
- Windows：同一提交的 GitHub `Windows Build` run `31313485833` 通过 815/815 xUnit，WinUI x64 与 ARM64 均 0 警告、0 错误。
- Android：本波未修改 Android 业务源码；同一提交的 GitHub `Android Build` run `31313485840` 完成完整构建与静态门禁，用于证明新增公共请求 Fixture 未破坏既有目标。
- 仓库：同一提交的 `Repository Check` run `31313485899` 通过；本地请求契约为 92 份 Fixture 与 1 份写结果示例，引用 Fixture 为 3 组/19 项，双语资源为 Apple 3297、Android 1985、Windows 893。
- 临时修正历史已整理为一条简体中文功能提交；本地与远端临时分支已清理。真机、系统选择器和真实 NAS 副作用仍按 `PENDING_USER_VALIDATION` 后置。

### 第 3 波 FILE-09 当前进展

- 基线：`1c7ee4851feb00903327b0599a0d29ea421be8c9`；功能对齐账本见[第 3 波账本](../development/CROSS_PLATFORM_PARITY_WAVE_3_LEDGER_ZH.md)。
- 当前目标：Windows/iPhone/iPad `FILE-09` 单个普通文件移入回收站与从回收站恢复。永久删除、清空回收站、目录或批量恢复、跨 NAS 恢复、覆盖恢复和内部回收站清理接口继续关闭。
- 当前进展：Apple 共享层已新增 `moveToRecycleResult` 与 `restoreFromRecycleResult`，固定 Delete v2 / CopyMove v3，并通过 `DsmFileRepositoryTests` 107/107 与共享 Package 全量；Windows 已新增 `IFileRecycleRepository`、Delete v2 transport、Repository 结果链和 `Files/Recycle` 测试。Apple/Windows Files UI 已接入单个普通本地文件移入回收站和回收站位置恢复；提交 `ba34f7af81e0638e1347ba6189fbdba1aa951e37` 的 GitHub `Apple Build` run `31318490495`、`Windows Build` run `31318490511` 和 `Repository Check` run `31318490509` 均已通过，其中 Windows 为 830/830 xUnit 且 WinUI x64/ARM64 0 警告、0 错误。Photos 受限恢复入口已在 iPhone/iPad 网格、时间线、查看器和 Windows Photos 文件夹/时间线中复用同一恢复流程；本机已通过 Apple 聚焦 `MobileFileRecycleActionPresentationTests` / `MobilePhotoViewerPresentationTests`、Windows XAML/XML、本地化、C# 形态和差异静态门。已整理为单条简体中文功能提交，并通过 GitHub `Apple Build`、`Windows Build` 和 `Repository Check`。真实 NAS 回收站策略和真机交互仍需后置验证。

### 当前 Chat 文字发送切片

- Apple 共享层与 iPhone/iPad Chat 已接入受限纯文字发送：固定 Chat Post v5，使用 `ChatMessageSendOutcome` 表达确认、权限失败、提交未知和取消边界；发送成功必须通过消息回读确认，提交未知会保留核对状态并阻止自动重放。附件、实时、建群、删除、提醒、定时、投票、语音和加密不进入本切片。
- Windows Chat 已接入同义受限纯文字发送源码：Domain typed outcome、DsmRepository 固定 v5 发送与回读核对、WinUI 底部 composer、进程会话 review blocker、权限/提交未知/取消反馈和无障碍文案已完成。本地已通过 Chat XAML/resw XML、本地化、差异格式、C# 形态和源码护栏；本机无 `dotnet`，Windows 编译与 xUnit 需 GitHub 验证。
- 已运行验证：`swift test --package-path apple --filter DsmChatRepositoryTests` 31/31 通过；DsmMobile `MobileChatModelTests` 与 `MobileChatPresentationTests` 聚焦 34/34 通过；双语资源校验通过，当前统计 Apple 3380、Android 1985、Windows 985。真实 Chat Server、iPad/真机、Windows Narrator/键盘和系统生命周期仍为 `PENDING_USER_VALIDATION`。

## 当前跨端对齐波次验证快照

- 基线：`21172ac`；当前异步验证分支：`codex/cross-platform-parity-wave-0`。
- Windows：提交 `b0f0334` 的 GitHub Actions `Windows Build` run `31301134782` 通过 691/691 xUnit、WinUI win-x64 与 win-arm64 Release 构建，0 警告、0 错误。该证据是 `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64`，不等同真实 x64/ARM64 设备运行。
- Apple：同一提交的 `Apple Build` run `31301134776` 通过共享 Package 636 XCTest（2 项按环境跳过）、Swift Testing、iPhone/iPad 通用应用构建与 macOS 回归打包。iPhone 17 Pro iOS 26.5 模拟器仍是最新聚焦设备；最新完整 iPad 模拟器、真机与真实 NAS 仍未验证。
- Android：同一提交的 `Android Build` run `31301134788` 完成单元测试、Debug、Release、R8、仪器测试 APK 编译与 Debug lint；本波未修改 Android 业务源码，该运行用于证明共享契约与资源没有破坏既有目标。
- 仓库：`Repository Check` run `31301134780` 通过必要文件、JSON、请求契约、隐私、双语资源与硬编码扫描。
- 共同轻量门禁：双语资源校验当前统计 Apple 3209、Android 1985、Windows 794；请求契约校验 88 个 Fixture 与 1 个写结果示例；差异格式和项目 XML 检查通过。
- 第 0 波并非长期计划完成；原定的 Windows 证书、Apple/Windows FILE-03 和 PHOTO-02 已进入下述第 1 波候选。待本波云端全绿并合并后，继续按账本推进 Files 有界复制/移动、回收站写、PHOTO-03 主动导入及 Chat/Download 受限控制；其他危险写继续使用独立契约切片。

### 第 1 波当前候选（候选云端门禁已通过，待单提交最终复验）

- 基线：`bd809f8b6854258ac3c0d9370468b82536b7c34d`；功能对齐账本见 [第 1 波账本](../development/CROSS_PLATFORM_PARITY_WAVE_1_LEDGER_ZH.md)。
- Apple：FILE-03/PHOTO-02 移动聚焦 60/60；共享 Package 645 项、2 项按环境跳过、0 失败。当前主机无 iPad Simulator，不把 iPhone 模拟器结果冒充 iPad 或真机结论。
- Windows：证书 C0–C3 与 FILE-03 F0–F4 源码完成；两轮未参与实现者对抗终审均无开放 P0/P1。`Windows Build` run `31306947634` 在候选 `f25508b` 通过 756/756 xUnit，WinUI x64/ARM64 均为 0 警告、0 错误。
- 共同轻量门：请求契约 90 个 Fixture 与 1 个写结果示例通过；双语资源 Apple 3255、Android 1985、Windows 849；Apple strings、Windows resw/XAML XML、本地化、硬编码和 `git diff --check` 通过。
- 候选 GitHub 结果：`Apple Build` run `31306484946` 与 `Android Build` run `31306484965` 在 `e5ac397` 通过；`Windows Build` run `31306947634` 与 `Repository Check` run `31306947631` 在修正后的 `f25508b` 通过。CI 修正记录将整理为一条简体中文功能提交；最终精确 SHA 仍须重新通过四组工作流，全绿前不更新为已合并。

## macOS 功能状态

| 领域 | 当前状态 | 待完成 |
| --- | --- | --- |
| NAS 配置与安全连接 | 已实现多 NAS、证书核对、能力发现、局域网/公网/QuickConnect 连接方式识别 | 按 DSM build 和证书类型完成回归 |
| 登录与会话 | 已实现密码、OTP、会话兼容、本地 AES-GCM 加密存储、记住密码和自动登录 | 验证会话过期、密码变化、OTP 和显式退出 |
| 文件浏览 | 已实现共享目录、分页、图标/列表视图、排序、分组、面包屑和空目录状态 | 验证大目录、深层路径、中文和特殊字符 |
| 搜索与快捷访问 | 已实现当前目录/子目录搜索、正则筛选、收藏和最近访问；远程位置浏览本批收敛为由 `Info.get` 的 `support_virtual_protocol` 驱动官方 `VirtualFolder.list` v2 的 `cifs`/`nfs`/`iso` 分协议只读枚举，以“协议 + 路径”去重；单次请求最多 500 条、每协议读取窗口最多 5,000 条，最终返回最多 5,000 个结果并明确提示截断（三协议最坏排序前处理 15,000 条），不发送 `type=all`，ISO 只显示 | 验证协议大小写、空能力、失效路径、跨协议同路径、分页、权限、隐私清理和大量记录；不得把自动化结果写成实机结论 |
| 账号可见空间 | 已实现侧栏总量、已用量、剩余量和多卷去重；只读取当前账号可见共享 | 验证配额账号、多共享同卷、多卷和 DSM 字段差异 |
| 远程位置管理 | 已实现 SMB/NFS 创建、修改、删除、重复提交保护和结果复查；内部接口由能力发现控制；ISO 不提供编辑或删除，`VFS.Connection` / `Entry.Request` 继续关闭且未验证 | 必须按 DSM build 验证权限、错误凭据、只读、修改回滚和删除语义；内部关闭能力不得作为降级路径 |
| 文件详情 | 已实现文件详情、文件夹内容与大小统计；官方 `List.getinfo` v2 按输入路径字符串去重并保持首次输入顺序，每批最多 100 条且只请求最小字段；文件夹属性优先使用官方 DirSize v2，支持显式计算/重新计算/取消，窗口关闭后台继续，模块关闭或断连时取消，仅能力缺失才回退客户端递归 | 使用真实 DSM 验证大批量缺项/乱序、普通用户、超大目录、远程挂载、计数/字节语义、长任务、取消、任务丢失和错误恢复；100 条不是官方上限，路径与任务 ID 不得进入领域结果、错误或持久化 |
| 图片与视频缩略图 | 已实现网格缩略图与缓存 | 验证大目录并发、缓存占用和网络切换 |
| 图片预览 | 已实现前后切换、旋转、滚轮缩放、窗口缩放和无白边全屏 | 验证不同尺寸、色彩空间和超大图片 |
| 文本预览与编辑 | 已实现常见文本/代码文件编辑、覆盖保存、未保存保护和安全格式整理 | 验证编码、空文件、并发修改和权限错误 |
| PDF、音频和视频预览 | 已实现 Range 读取、实时速度、资源释放和内容签名识别 | 验证编码兼容、Range 缺失、慢速网络和窗口关闭 |
| 文件上传 | 已实现系统选择器、覆盖上传、进度、取消和从头重试 | 公开 API 不支持字节续传；继续验证同名与权限 |
| 文件下载 | 已实现文件、文件夹 ZIP、保留目录结构下载、严格 Range/响应体完整性校验、普通文件暂停/继续、保存请求重建恢复和 SAF 授权终态清理 | 验证真实 NAS 大文件/ZIP、深层目录、不同文档提供程序、云盘、只读/撤销授权、真实网络切换、Doze 和磁盘空间不足 |
| 复制、移动与重命名 | 已实现同 NAS 任务、跨 NAS 有界内存流、公开 API 重命名、图标/列表拖拽、框选和限时撤销；Android 文件夹跨 NAS 移动因递归删除竞态保持关闭 | 验证多层目录、同名冲突、跨 NAS 中断和结果校验；补齐 Android 文件夹安全移动方案 |
| 粘贴冲突 | 已实现直接粘贴，仅在实际存在同名项目时提示跳过或替换 | 验证批量项目中的部分冲突和取消行为 |
| 压缩与解压 | 已实现 ZIP/7z 创建、常见压缩包解压、密码重试、文件名编码和覆盖确认 | 验证不同 DSM、加密算法、中文编码和权限错误 |
| 分享链接 | 已实现创建、密码、有效期、复制、列表和取消分享 | 验证 DSM 版本差异、过期和批量项目 |
| 传输中心与通知 | 已按 NAS 隔离展示任务，已实现速度、剩余时间、操作任务和成功/失败系统通知；App 传输与 NAS 文件任务采用独立数据源，NAS 任务支持全部/进行中/已结束筛选、刷新、有限分页及加载/空/筛选空/错误/正常五态 | 验证通知权限、应用切换和应用退出，并使用真实 File Station 响应验收 NAS 文件任务的权限、分页和结束状态语义 |
| 应用存储管理 | 已实现占用统计和可再生缓存清理，受保护数据不参与清理 | 验证清理期间的并发预览与传输 |
| 桌面云盘位置 | 已实现整个 NAS/目录映射、只读占位、按访问读取、文件/目录离线保留、递归空间预检、缓存分项、LRU、缓存卷、关闭窗口后台驻留，以及 runtime/会话/失败状态的显式恢复；主 App 与 Extension 的容量、下载、软上限、时钟、外接卷和 Store 边界已可注入并完成代码级故障测试 | 按正式签名验收矩阵完成 Finder、真实卷与系统取消验收，以及 Windows x64/arm64 完整构建、资源管理器、重启和安装/卸载验收 |
| 安全删除 | 已实现确认、已知权限检查、父子路径重复提交保护、任务轮询、逐项回读、部分成功、提交未确认和取消后复查语义；未确认任务不提供立即重试 | 完成不同共享目录回收站设置、弱网、权限和取消时机的真实验证 |
| 回收站恢复 | 已实现候选路径和受兼容开关保护的恢复流程 | 必须按 DSM build 验证后才能标记完成 |
| NAS 设置 | 已实现单一开关、关闭即停止请求、性能趋势、真实系统更新检查与发布说明、存储详情、S.M.A.R.T. 检测、USB/eSATA 外接存储、内存压缩、套件及 DSM 升级提示、任务及运行记录、账号/群组、当前账号共享访问、隐私白名单保护的系统活动、电源计划、系统日志、当前连接、文件服务、物理网卡、DDNS、区域时间、防火墙基础控制和 UPS；系统活动、电源计划、外接存储和内存压缩只读响应仍待真实 API 验证，内存压缩仅观察到官方设置控件；系统更新及套件安装/升级、电源计划保存、USB 安全弹出和内存压缩设置入口保持关闭，共享访问只使用公开 File Station 有效权限，危险操作具备能力/状态检查、确认、防重复和结果复查 | 使用专用测试目标验证新增只读摘要、可能断网/改时/停电联动的写操作、普通账号与 QuickConnect；系统更新安装、套件安装/升级、管理员共享权限矩阵和完整共享文件夹复合管理、防火墙规则编辑、电源计划保存、USB 安全弹出与内存压缩设置仍需版本化契约、原子流程和专用目标验收 |
| 统一存储管理（新增组合功能） | 由群晖“存储管理器”与“存储空间分析器”两个官方组件合并而成；macOS 已在一个入口提供容量/健康、卷/存储池/硬盘、共享文件夹、类型、所有者、大文件、文件时间和重复内容分析 | 验证大目录、取消、权限、QuickConnect 和官方 MD5 任务；套件历史报告与计划任务待取得版本化契约 |

## 已识别但未实现的能力

以下能力已从源码、接口文档和 DSM Web API 参考中梳理出来，尚未进入当前里程碑：

### File Station 扩展
- `SYNO.FileStation.VFS.Connection` / `SYNO.Entry.Request` 批量与 VFS 扩展：公开指南无稳定契约，当前继续关闭且未验证，不作为 `VirtualFolder.list` 或 `List.getinfo` 的降级路径

### 其他 DSM 套件与功能
- **打印机 Bonjour 共享**：已建立 `static/candidate` 稳定记录；当前只有 API 名称与
  `get` 方法，版本、参数和响应未知，客户端不发请求，也不推断打印机或队列信息
- **安全扫描状态**：已完成静态边界审计；组件归属、版本、参数和响应未知，客户端不
  调用 `rule_get` / `system_get`，也不与现有可写安全设置或日志模型混用
- **Download Station 移动端边界**：Android 已接入任务文件/Tracker/Peer 详情、RSS 浏览与官方单站点刷新、BT 搜索、活动摘要和搜索结果创建任务。单文件优先级缺少稳定文件身份与公开写参数，RSS/BT/NZB 高级配置均由 DSM Web/桌面端管理；取得版本化契约后再评估。
- **Virtual Machine Manager 移动端边界**：Android 已用官方 v1 契约接入创建、常规设置、生命周期、映像管理、硬件只读摘要和任务中心。noVNC 与高级磁盘/网络、迁移、克隆和整机导入导出使用 DSM Web/桌面端；只有可证明非持久会话隔离后才重新评估 Android 控制台。
- **Container Manager / Docker 移动端边界**：Android 已只读接入容器、镜像、网络、项目、事件及 Registry 搜索/标签。详情资源/容器日志缺少字段白名单，镜像拉取缺少任务及最终回读契约；详细运维、终端、创建/编辑、Compose、更新与清理使用 DSM Web/桌面端。
- **系统与硬件**：系统、存储、USB/eSATA 外接存储、内存压缩、套件、计划任务、账号、当前账号共享访问、系统活动、电源计划、日志和连接已统一进入 NAS 设置模块；系统活动只读取最多 500 项字段白名单快照，电源计划只读取最多 128 条动作、时间、重复和状态摘要，外接存储每类只读取最多 64 项受限名称、状态与明确字节容量，内存压缩只读取启用状态、明确字节容量和算法白名单，均不展示命令、设备/挂载路径、序列号、账号或网络地址，且不提供结束进程、保存计划、安全弹出或内存压缩设置操作；四项真实 DSM API 响应仍待验证，内存压缩仅在官方页面完成只读观察；Android 已接入性能趋势、硬盘检测、真实更新检查和主要安全写操作，仍待真实 NAS 验收；套件列表会把 DSM 明确返回的 `upgrade` 显示为非交互提示，安装/升级仍关闭；共享访问使用公开 `list_share`，不把不可见条目推断为拒绝访问；文件服务、SSH/Telnet、互联网代理、物理网卡、DDNS、区域时间、QuickConnect、断电恢复、设备灯光、风扇/提示音/休眠、UPS 与防火墙基础控制已接入正式客户端读写调用链与回读复查，但真实写行为仍待专用目标验收；套件安装/升级、存储修复/擦除、电源计划保存、USB 安全弹出、内存压缩设置、完整防火墙规则以及管理员共享权限矩阵和共享文件夹的加密/权限/WORM/配额复合管理仍需独立原子流程
- **Synology Chat**：已建立普通用户聊天契约与独立内部适配器；公开 `SYNO.Chat.External` 不用于普通用户聊天。第一批 `SYNO.Chat.*` 能力已按运行时发现接入，首次单聊、单附件上传/缩略图/保存、图片单击预览、HEIC/HEIF 本机预览兜底、工作区级未读同步、会话本地已读、按 NAS 持久化的本地会话置顶、Socket.IO 实时刷新及轮询降级、提醒设置/列表/取消、纯文字定时消息及无附件投票创建已实现，真实行为待验收；官方云端 Star 写入契约、服务器已读回写、语音、投票参与和加密仍待实现
- **其他套件**：Audio Station、Video Station、Note Station、Synology Drive、Calendar、Contacts、Surveillance Station、Hyper Backup / Active Backup、Synology Office

### 平台实现
- iPhone、iPad、Android 与 Windows 原生工程已初始化；当前实现覆盖文件、照片列表、消息会话、下载、容器、VMM 和 NAS 设置主入口
- 完整编辑、释放设备空间和更广泛的离线任务恢复仍待按平台补齐；Android 已为用户明确授权的照片或目录建立约束后台上传和周期发现

状态：Download Station、Virtual Machine Manager 与 Container Manager 已进入 macOS 第一阶段实现。Android 按第 89 批移动端范围只继续五个最终目标，不再机械复制桌面端配置与编排功能；未经版本化行为验证的写入口保持关闭。内部写操作只有同时具备兼容记录、单次提交/防重复/写后回读和专用测试目标行为验证后才能开放。

## 自动化验证

- Apple 共享包完整测试和 `DsmMac` Debug、无代码签名构建持续验证。
- macOS 0.2.6 (7) 崩溃报告已核实为旧包问题：DDNS 服务商列表包含重复 ID 时由 `Dictionary(uniqueKeysWithValues:)` 触发断言；当前源码已改为稳定顺序去重、忽略无效项并保留更友好的显示名称。重复 ID 精确回归 1/1、Apple 全量 536 项 XCTest（2 项跳过）与 4 项 Swift Testing、`DsmMac` Debug 无签名构建均通过；按用户指示归档，不再重复投入 Android 目标时间复验。
- `DsmMobile` iPhone/iPad 通用目标已通过 5 项测试（含冷启动资料恢复与自动登录）、无签名 Release 模拟器构建、iPhone 测试启动和 iPad Release 安装启动。
- Windows Domain、Infrastructure 和桌面云盘领域既有 38 项测试已使用 .NET 10 验证，Cloud Files 核心源码独立编译通过；该批新增的 4 项共享删除请求契约测试已由后续 Windows CI 执行。当前完整门禁为 691/691 xUnit，WinUI x64 与 ARM64 Release 均构建通过；真实设备、Explorer 与系统交互仍待后续验收。
- 本地化检查覆盖 Apple、Android、Windows 的双语键、格式参数、资源引用、英语资源残留中文和生产界面硬编码；当前统计为 Apple 2,782 个、Android 1,781 个、Windows 262 个双语资源项。
- Apple 共享包 585 项 XCTest 通过（2 项按条件跳过），10 项 Swift Testing 通过，`DsmMac` Debug 无签名构建通过；其中桌面云盘配置、事务、主 App 与 Extension 系统边界覆盖最后成功快照、状态机、会话待清理、恢复最终提交与连续写失败、逐项释放、多时点容量、并发软上限准入与在途额度预留、完整 staging 准入、下载 Task 取消、partial 清理、确定性超时、外接卷和本地提交补偿，File Station 删除/移动已通过 Repository 真实调用链对照共享请求 Fixture。社区兼容性工具 67 项测试、正式报告与本地草稿双 Schema、macOS 白名单草稿导出、只读候选差异、重复/冲突警告、显式取代链、schemaVersion 2、testSuiteVersion 1/2、Issue 表单字段/能力一致性、Draft 2020-12 Schema 与矩阵生成检查通过；既有临时签名 Release 打包启动结果保持有效。
- Android 2026-08-04 第 56 批状态：Download Station 暂停、继续、仅移除任务及移除任务并删除文件已迁移到持久结构化反馈。Repository 只接受完整稳定任务基线，严格分页拒绝畸形、重复、总数漂移和截断；同目标跨动作原子防重复，提交取消、断线和歧义失败只回读不重放。危险删除必须显式确认，旧字符串旁路已移除；删除文件按任务移除和文件删除两个效果计数，任务消失不冒充文件已删除。严格刷新证据绑定 Repository、NAS、稳定目标与代次，危险或未知结果核对前不能清除、切换 NAS 或退出登录。专项 49 项 JVM 与 24 项 Compose 测试通过；Android 共 857 项 JVM 测试，完整 Debug/Release/R8、仪器测试 APK、Debug lint 和 1616 个双语资源项均通过。71 份请求 Fixture、1 份结果示例、3 组响应 Fixture、103 份 contracts JSON 及社区检查 19 项通过、0 项失败。标准 API 35 XML 共 263 项，其中 257 项通过、6 项按既有条件跳过、0 项失败。Android A0–A8 叶子开发目标经代码审计为 175/202（86.6%），剩余 27 项；A9 真实环境与发布验收单列。真实媒体删除、外部深链、真实进程死亡、平板/折叠屏/OEM 分屏、真机 TalkBack、API 34+ 真机预测手势及真实 NAS/SAF/Doze/弱网仍待验收；本批未操作浏览器或真实 NAS，未执行真实暂停、继续、任务移除或文件删除，不把源码或自动化结果冒充实机结论。
- Android 2026-08-04 第 58 批状态：Download Station 设置严格读取基础与计划字段，拒绝缺失、畸形、越界及 HTTP/FTP 分歧；正式保存入口必须携带用户所见基线，锁内二次读取发现漂移时零写入，只提交实际变化的基础或计划组件，组件间取消与逐组件回读可表达部分成功、提交未确认和未知结果，绝不自动补写。ViewModel 持有内存草稿、基线和八态反馈，设置与任务创建、任务控制、模块导航、切换 NAS、退出登录共用原子协调边界；普通重载不能清除证据，未知或异常结果严格刷新后仍需明确关闭。界面将 HTTP/FTP 合并为单一限速字段并覆盖 48dp、live region、深色、2× 字体和小屏滚动。Repository/契约/状态策略 27 项 JVM 与 API 35 Compose 4/4 通过；完整 120 组 JVM XML 共 892 项、0 失败/0 跳过，Debug/Release/R8、仪器测试 APK、Debug lint、1659 项双语资源、本地化、计划统计与差异门禁通过，三路复核最终无 P0/P1。A0–A8 保持 175/202（86.6%）、剩余 27 项，因为本批完善既有能力且 A1 仍有 VMM 等链路，不重复计分；未操作浏览器或真实 NAS，真实字段、权限、断线及两端点非原子副作用仍待专用测试环境验收。
- Android 2026-08-04 第 59 批状态：VMM 创建、常规设置和公开生命周期已迁移为持久结构化反馈。创建只接受严格终态 task 返回的 `guest_id`，名称回读不取得归属；缺 ID、取消、模糊、task 异常或配置未严格核对时不重放、不 `set`、不清理任务证据。设置使用用户所见完整基线，锁内复读拒绝漂移，no-op 零写并只发送变化字段；启动与关机携带确认时状态基线。内部 Guest/Action/Image/Network 写 fallback 和网络写 UI 已关闭。Workspace 保存创建步骤/草稿、设置基线/草稿、生命周期确认、八态结果、计数、异常、专项刷新和四态核对，未提交结果可继续编辑，编辑/确认/危险结果进入导航、切 NAS 与退出门禁。Repository 39 项、状态策略 19 项、API 35 Compose 21 项通过；完整 121 组 JVM XML 共 938 项、0 失败/0 跳过，Debug/Release/R8、仪器测试 APK、Debug lint、1705 项双语资源、请求契约、Fixture、104 份 contracts JSON 与计划统计通过，多轮复核最终无 P0/P1。A0–A8 保持 175/202（86.6%）、剩余 27 项；未操作浏览器或真实 NAS，未执行真实 VMM 写操作，真实权限、任务字段、断线、取消、版本差异和副作用仍待专用测试环境验收。
- Android 2026-08-04 第 60 批状态：File Station 创建文件夹、重命名、收藏、复制/移动、回收站恢复和共享链接创建/删除已迁移为统一 Workspace 持久结构化反馈。草稿、稳定目标、可见基线、确认、八态结果、计数、异常、专项刷新和四态核对均可跨 Activity 配置重建；未提交结果可继续编辑，复制/移动取消确认会返回并保留目的地。模糊提交只回读不重放，过期回调按 Repository、NAS、目标和代次隔离；文件核对比较类型及文件大小/修改时间，共享创建只按本次确认的稳定 ID 与路径归属。Photos 收藏、分享和恢复使用同一反馈承载。最终定向 JVM 17 项、API 35 Compose 11/11 通过；完整 123 组 JVM XML 共 955 项、0 失败/0 跳过，Debug/Release/R8、仪器测试 APK、Debug lint、1735 项双语资源、请求契约、Fixture、104 份 contracts JSON 与计划统计通过，终审无 P0/P1。A0–A8 保持 175/202（86.6%）、剩余 27 项；未操作浏览器或真实 NAS，未执行真实文件写入。Photos 移动和删除的旧瞬时反馈列入第 61 批，真实权限、任务字段、断线、取消、版本差异和副作用仍待专用测试环境验收。
- Android 2026-08-04 第 61 批状态：Photos 单项移动与删除已迁移到 File Station Workspace 持久结构化反馈。移动使用完整源文件与目的地目录基线，删除使用完整文件基线；确认、八态结果、计数、提交前后取消、任务轮询、模糊提交只回读不重放、相册专项刷新、配置重建和退出门禁均复用共同核心。确认取消会返回并保留目的地选择器；空间根在公开 `fileInfo` 返回可写稳定基线后可选；明确丢弃提交前失败会清理草稿；不可删除项目不显示移动入口。聚焦 JVM 49/49、API 35 Compose 16/16；完整 123 组 JVM XML 共 962 项、0 失败/0 跳过，Debug/Release/R8、仪器测试 APK、Debug lint、1735 项双语资源、请求契约、Fixture、104 份 contracts JSON 与计划统计通过，三路终审无 P0/P1/P2。A0–A8 保持 175/202（86.6%）、剩余 27 项，因为本批完善既有能力，不重复计分；未操作浏览器或真实 NAS，未执行真实照片移动或删除，真实权限、任务字段、断线、回收站、套件版本和文件副作用待用户统一实机验收。
- Android 2026-08-04 第 62 批状态：File Station 文件浏览器单项/批量删除已从路径列表和瞬时消息迁移为完整多 `FileItem` 基线与 Workspace 持久结果。正式入口在同一 claim 内逐项复核身份和删除权限，任一漂移或拒绝整批零写；任务状态失败与模糊提交均只逐项回读，不重放。批量数量/影响确认、八态计数、专项刷新、配置重建、选择清理、Files/Photos 模块隔离和危险退出门禁已接入；删除不再提供复用旧基线的“继续编辑”。聚焦 JVM 42/42，API 35 两批交叉 22/22；完整 123 组 JVM XML 共 969 项、0 失败/0 跳过，Debug/Release/R8、仪器测试 APK、Debug lint、1735 项双语资源、请求契约、Fixture、104 份 contracts JSON 与计划统计通过。终审发现的 1 个 P1、2 个 P2 均已修复；A0–A8 保持 175/202（86.6%）、剩余 27 项，因为本批纠正既有已计分能力，不重复计分。未操作浏览器或真实 NAS，真实权限、任务字段、断线、回收站、版本和文件副作用待用户统一实机验收。
- Android 2026-08-04 第 63–65 批状态：Chat 首次单聊、私人群聊、提醒设置/删除、定时消息创建/删除、投票创建，以及逐消息文字/单附件发送均迁移到同一持久结构化 Workspace。管理写操作保留稳定目标、完整删除基线、八态、计数、异常、专项刷新和模块/切 NAS/退出门禁；文字、投票和附件使用不可逆指纹与 120 秒提交时间窗归属，上传进度和最终结果按 Repository、NAS、目标及代次拒绝迟到回调。九个旧瞬时状态字段和本地化错误字符串旁路已删除，API 35 首次发现的 DEX `VerifyError` 随平行事实源移除而修复；最终审计补齐 A→B 会话迟到结果的可见页隔离、未知结果回读后的原子移除/继续编辑、附件预处理离页 ABA，以及成功、明确移除或工作区销毁后的 URI 权限释放，选择失败也进入提交前结构化结果，Retry 统一从 entry 状态派生。Repository 57 项、状态策略 19 项、API 35 Chat 交叉 25 项，共 101 项聚焦测试通过；Kotlin/AndroidTest 编译、1755 项 Android 双语资源、本地化、71 份请求 Fixture、1 份结果示例、3 组响应 Fixture、计划统计、YAML 和差异门禁通过。GitHub [Android Build 30924874267](https://github.com/yuangy1995/dsm-native-client/actions/runs/30924874267) 完成 990 项 JVM（0 失败、0 跳过）、Debug/Release/R8、仪器测试 APK、Debug lint 和四组 APK/报告产物上传，[Repository Check 30924872048](https://github.com/yuangy1995/dsm-native-client/actions/runs/30924872048) 同步通过。首轮 CI 暴露的网卡在途取消竞态断言已按既有契约收敛，未放宽写入次数或刷新门禁。A0–A8 保持 175/202（86.6%）、剩余 27 项，不重复计算既有 Chat 能力；未操作浏览器或真实 NAS。
- Android 2026-08-04 第 66 批第一阶段状态：普通文件上传预检与前台任务按 Repository、NAS、File Station、目标目录和单调代次建立接管门禁；模块离开、切换 NAS 和退出会取消未接管预检，已取得的 URI 授权在持久任务接管失败时恰好释放，取消预检不会遗留全局 busy。前台上传只保留一个正式执行入口。压缩/解压 SERVER 任务按 Repository 与 NAS 隔离进度和结果，跨模块不再写全局消息，运行中或待刷新任务进入退出门禁。Android 已接入官方只读 `SYNO.FileStation.BackgroundTask.list` v3：固定 1…100 有限分页、创建时间降序和 CopyMove/Delete/Extract/Compress 四类过滤，严格丢弃任务参数、路径、处理路径和消息；`finished` 只归一为“已结束”，不推断成功，`clear_finished` 零入口。Workspace 支持刷新、追加页、分页错误保留旧页、Repository/NAS/模块/代次迟到回调隔离；传输中心将 App 传输和 NAS 文件任务分源，NAS 文件任务具备加载、空、筛选空、错误、正常五态、刷新、分页、live region 和 320dp/2× 字体布局。21 项聚焦 JVM、API 35 七项专项、Kotlin/AndroidTest 编译、1775 项双语资源、72 份请求 Fixture、本地化与契约门禁通过；首轮 API 35 两项测试因筛选标签和任务状态同名造成节点选择歧义，收紧为带 live region 的任务状态后 5/5 重跑通过，未修改产品语义。GitHub [Android Build 30931810496](https://github.com/yuangy1995/dsm-native-client/actions/runs/30931810496) 完成 1006 项 JVM（0 失败、0 跳过）、Debug/Release/R8、仪器测试 APK、Debug lint 和四组产物上传，[Repository Check 30931810284](https://github.com/yuangy1995/dsm-native-client/actions/runs/30931810284) 同步通过。未访问浏览器或真实 NAS，BackgroundTask 字段形态和权限范围仍是未验证；文本保存的持久原始结果/专项核对以及压缩/解压目标目录核对列入第 67 批。A0–A8 保持 175/202（86.6%）、剩余 27 项。
- Android 2026-08-05 第 67 批状态：文本覆盖保存已统一进入 File Station Workspace，使用完整文件基线、不可逆内容摘要和字节数保存确认目标，保留原始八态结果、异常、继续编辑、专项 Range 回读、配置状态和退出门禁，旧独立保存 job/generation 已删除。压缩/解压正式入口携带源项、目标目录及挂载类型基线，在同一路径锁内复读后才允许提交；解压在归档内容列表前取得锁。SERVER TransferTask 保留 Repository/NAS/目标/代次、预期顶层输出、原始结果、异常、刷新和四态核对，传输中心只在未确认任务显示“打开并刷新受影响文件夹”；压缩确认要求目标非目录且非空，解压只按顶层路径与类型核对，不声称递归内容或校验和已验证。终审发现的目录恢复基线、挂载类型读取不对称、只读浏览被基线读取绑死、零字节误判、解压证据断链、旧异常永久门禁、动态播报范围、配置重建覆盖和旧任务误清新选择均已修复。聚焦 JVM 53/53、API 35 交叉 34/34、Debug/AndroidTest Kotlin 编译、1781 项双语资源、72 份请求 Fixture、1 份结果示例、3 组响应 Fixture、计划统计和差异门禁通过；GitHub [Android Build 30964477119](https://github.com/yuangy1995/dsm-native-client/actions/runs/30964477119) 完成 1021 项 JVM（0 失败、0 跳过）、Debug/Release/R8、仪器测试 APK、Debug lint 与四组产物上传，[Repository Check 30964477135](https://github.com/yuangy1995/dsm-native-client/actions/runs/30964477135) 同步通过，三路终审最终无 P0/P1/P2。A0–A8 保持 175/202（86.6%）、剩余 27 项，不重复计算既有能力；未访问浏览器或真实 NAS，未执行真实文本覆盖、压缩或解压。
- Android 2026-08-05 第 68 批状态：Download Station RSS 单站点刷新已从瞬时字符串迁移为持久结构化反馈；目标保存刷新前更新时间，写后只有更新时间前进且站点结束更新才标记匹配，站点/条目普通可读不再冒充刷新效果。提交前后取消、异常、更新中、不一致、消失和不可用均保留独立状态，再次核对只读且不重发；弹窗关闭、主刷新按钮、Download 创建/控制/设置、模块切换、切换 NAS 与退出登录共享门禁。`download-station2-fallback` 与 `vmm-internal` 已建立独立稳定记录，兼容索引证据保持 `observed/degraded` 与 `read-verified/degraded`；校验器要求新内部端点引用存在且声明对应标识的稳定文档。RSS 状态 JVM 7/7、API 35 RSS/发现 UI 8/8、Kotlin/AndroidTest 编译、双语/契约轻量门禁通过；合并批次的 GitHub [Android Build 30968764080](https://github.com/yuangy1995/dsm-native-client/actions/runs/30968764080) 与 [Repository Check 30968764054](https://github.com/yuangy1995/dsm-native-client/actions/runs/30968764054) 均通过。未访问浏览器或真实 NAS，A0–A8 保持 175/202（86.6%）、剩余 27 项。
- Android 2026-08-05 第 69 批状态：经用户明确授权，`PersistedUpload` 增加目录准备与文件上传两阶段稳定结果，所有新增字段有默认值；旧加密 JSON 缺字段可读，旧版本通过未知字段忽略保持回滚兼容。WorkManager 普通上传和照片备份直接消费 `ensureSubdirectoryResult`/`uploadResult`，按当前 Work ID 保存八态、提交边界、实际写入边界、计数、错误类别和刷新要求；多级目录逐层最多提交一次，失败后只读核对。恢复到运行中任务时保留提交未确认并停止自动覆盖重传；系统重新排队不把已运行任务降回可重放状态，登出保留可能已到达 NAS 的证据，未确认终态不可被“清除已完成”删除，备份可显式回读或重试，通知区分失败、取消与待核验。传输中心可从加密记录恢复阶段、结果和计数。聚焦 JVM 43/43（与 RSS 状态组合门禁共 50/50）、API 35 上传 UI 2/2（与 RSS/发现组合共 10/10）、1818 项 Android 双语资源、3 组 Fixture 与 19 项私有 API 引用通过；Debug 与 AndroidTest Kotlin 编译通过，两轮终审报告的 P1/P2 已闭环；GitHub 完整门禁完成 1048 项 JVM（0 失败、0 跳过）、Debug/Release/R8、仪器测试 APK、Debug lint 和报告/安装包上传。真实进程死亡、Doze、设备重启、网络切换、不同 SAF 提供程序和真实 NAS 按用户安排留待打包验收；完成度保持 175/202（86.6%）。
- Android 2026-08-05 第 70 批状态：全局动效审计确认生产 UI 唯一显式时间动效为 Workspace 预测返回取消后的 150ms 视觉回弹，手势进度和回弹均遵守系统动画开关；新增审计矩阵、精确静态门禁与 4 项专项测试，`tools/codex` 8/8 通过。真实预测返回、OEM 动画和触控体验继续留在独立设备验收项，不由源码审计替代。本叶子完成后 A0–A8 为 176/202（87.1%），剩余 26 项；GitHub 完整门禁待与当前 A3 持久化批次一并触发。
- Android 2026-08-05 第 71 批状态：App 发起的压缩/解压 NAS 任务已迁移到现有 Keystore 保护的加密传输存储，提交前、提交中、已取得 task ID 和终态边界同步落盘；重建后仅在 task ID 与预期输出完整时继续只读轮询，否则按“明确未提交”或“已提交但未确认”收敛，绝不自动重发。恢复观察不提供虚假的 NAS 任务取消操作，持久写失败会退出刷新中状态，损坏目标记录按新结构迁移规则隔离清除。官方 BackgroundTask 仅持久化不含路径、参数、消息和响应正文的脱敏摘要，旧快照在传输中心明确标注并刷新。Kotlin、AndroidTest 编译、39 项聚焦 JVM、API 35 Compose 13/13、1822 项双语资源、动效门禁和 `tools/codex` 8/8 已通过；GitHub Android Build `30971830208` 完成 1062 项 JVM、Debug/Release/R8、仪器测试 APK、Debug lint 和四组产物上传，Repository Check `30971830214` 同步通过。真实进程死亡、设备重启、NAS 状态和 OEM 后台限制按用户安排留待打包验收。本叶子完成后 A0–A8 为 177/202（87.6%），剩余 25 项。
- Android 2026-08-05 第 72 批状态：生产 UI 27 处自定义点击、长按、开关和单选目标已全量收敛到至少 48dp 双向尺寸、正确语义和原生按压反馈；新静态门禁拒绝 47dp、缺边尺寸、关闭反馈或未审计手势点击。登录与 Chat 移除嵌套重复点击，归档格式补齐单选组。静态扫描 27/27、Python 触控专项 9/9、API 35 交叉 44/44 通过。同批建立 60 个 `AppViewModel` 生产 `*Result` 调用（含固定关闭与只读恢复）的机器可读测试矩阵，并补齐收藏新增/移除的取消、断线和回读失败证据，聚焦 JVM 14/14 通过；仍有 14 个写入族缺测，A1 保持未完成。实体机、TalkBack、OEM 显示缩放和触控精度按用户安排留待打包验证；A0–A8 为 178/202（88.1%），剩余 24 项。
- Android 2026-08-05 第 73 批状态：60 个生产 `*Result` 调用的适用写操作测试证据全部闭环，补测覆盖文件归档/复制/恢复、Download 创建/RSS、DDNS、硬件/电源、账号/群组删除、套件卸载和 VMM；矩阵门禁无缺口，A1 写操作测试叶子完成。跨 NAS 以 12 MiB 管道接入文件复制/移动与文件夹复制，覆盖背压、取消、上传预检拒绝、同名冲突、权限和源基线变化；文件夹移动因递归删除竞态在提交前安全关闭。页面五态矩阵覆盖 29 个生产页面/弹窗，通用 API 35 测试 5/5 通过，但仍有 2 个生产状态缺口和 27 个页面级自动化缺口，A8 不勾选。实体机、TalkBack、OEM、真实 NAS 和签名验收按用户安排跳过；A0–A8 为 179/202（88.6%），剩余 23 项。
- Android 2026-08-05 第 74 批状态：当前所有已开放服务端写入口均使用稳定 `*Result` 并进入持久 Workspace/transfer/加密 Worker 边界；无调用者的 `action`/`nasSettingsMutation` 已删除。新门禁经两轮对抗复核后不再猜测结果数据流，改为扫描全部生产 Kotlin 并锁定 `AppViewModel`、跨 NAS 协调器和照片备份 Worker 三个已审文件的 SHA-256 与调用数量，任何新增调用文件或既有文件变化都会要求人工复核；同批补入此前遗漏的备份目录 `ensureSubdirectoryResult` 矩阵及断线不重放证据，当前覆盖 71 个调用点、61 个唯一方法。共享权限和系统更新等缺少稳定契约的未来能力继续关闭且不删除目标。Download Station 模型与纯 Workspace 状态策略从两个集中式文件机械拆出 671 行。日志请求失败不再冒充源空，共用日志列表已区分局部错误、源空、筛选空和正常内容，并补重试、筛选选中语义、稳定搜索标签、双语提示与礼貌播报；29 个生产页面的状态分支缺口降为 0，27 个页面仍缺完整页面级五态自动化，A8 不勾选。`tools/codex` 48/48、Download 状态 52/52、备份目录 Repository 7/7、日志 Repository 4/4、API 35 日志 UI 5/5、Kotlin/AndroidTest 编译、本地化及轻量门禁通过，[Android Build 30979473636](https://github.com/yuangy1995/dsm-native-client/actions/runs/30979473636) 与 [Repository Check 30979473640](https://github.com/yuangy1995/dsm-native-client/actions/runs/30979473640) 均通过完整门禁；实体机与真实 NAS 按用户安排跳过并保持未验证。A0–A8 为 180/202（89.1%），剩余 22 项。
- Android 2026-08-05 第 75 批状态：三组页面矩阵测试直接渲染生产 Composable，补齐 29 个生产页面/弹窗文件的全部适用状态；DDNS 抽出由生产宿主复用的根组件，未复制业务判断。API 35 迭代发现并修复 NAS 日志、Container 事件与 VMM 日志内容区被页签裁切的问题，最终 `Medium_Phone_API_35` 56/56、0 跳过、0 失败，生产与 AndroidTest Kotlin 编译通过。A8 页面五态叶子完成，A0–A8 为 181/202（89.6%）、剩余 21 项。2× 字体审计仍有主页面、确认框和反馈卡缺口；实体机、TalkBack、OEM、真实 NAS 和签名按用户安排跳过并保持未验证。
- Android 2026-08-05 第 76 批状态：严格使用 `fontScale=2f` 补齐 21 个主页面/页根、16 个确认场景和 15 个生产持久反馈组件族的证据；新增测试直接渲染生产 Composable，两个内联确认通过真实 File Station 父页面驱动，所有确认操作核对可见、启用和点击语义。12 个反馈矩阵方法直接覆盖 12 个组件族及共享上下文，Download 创建、RSS 和 VMM 由三个既有精确 2× 方法覆盖，映射已写入 UI 审计矩阵。主页面使用 360dp 宽度，反馈卡使用 320dp × 480dp 可滚动视口；独立 Dialog 只记录 2× 字体，不把宿主尺寸冒充小屏对话框验证。API 35 `Medium_Phone_API_35` 六类测试最终 47/47、0 跳过、0 失败，AndroidTest Kotlin 编译通过。A8 2× 字体矩阵叶子完成，A0–A8 为 182/202（90.1%）、剩余 20 项；实体机、TalkBack、OEM、真实 NAS 和签名按用户安排跳过并保持未验证。
- Android 2026-08-05 第 77 批状态：按生产调用边界完成结构收敛，不改变公开契约或业务语义。共享 `Models.kt` 的 89 个类型及 1 个内部 helper 等价迁入 5 个领域文件；`AppViewModel.kt` 从 17,638 行降至 15,224 行，2,414 行类外状态和纯策略迁入 5 个功能状态文件；Container 总览、附属分区、Registry 和现有写门禁迁入内部 `ContainerRepository`，原 10 个 API 继续由 `DsmRepository` 唯一转发，未验证写入口保持关闭。Kotlin 三类编译、完整 JVM 1115/1115、API 35 Container/主页面矩阵 31/31、工具测试 48/48、本地化、页面与写矩阵、计划统计和差异门禁全部通过，独立终审无 P0/P1/P2；GitHub 完整门禁结果在本批交付中记录。A0 模块边界叶子完成，A0–A8 为 183/202（90.6%）、剩余 19 项；其中实体机/真实系统环境与缺少稳定契约或专用写环境的目标均未被缩减或冒充完成。
- Android 2026-08-05 第 78 批状态：Download Station 单任务保存位置使用官方 Task.edit v1，写前复核完整任务和可写目录基线，只提交一次 `id`/`destination`，断线或取消后严格回读且不重放；确认、八态结果、专项刷新及退出门禁进入 Workspace。VMM Guest v1 `additional=true` 增加磁盘/网卡只读详情，Task.Info v1 最多读取 100 项任务，仅显示完成状态和进度；附加读取失败回退普通主列表，畸形硬件不遮蔽主列表，MAC、资源/任务 ID、内部状态与消息不进入模型或界面。VMM 相关 JVM 56/56、Download 新链路 36/36、Kotlin 三类编译、API 35 VMM 7/7 与 Download 整类 27/27、1870 项双语资源和 73 份请求 Fixture 已通过；独立终审发现的 1 个 P1 和 1 个 P2 已修复。已登录 Chrome 只读确认套件入口可见，但网络观察能力超时，没有形成新契约证据。实体机与真实 NAS 按用户安排跳过；A0–A8 保持 183/202（90.6%）、剩余 19 项。
- Android 2026-08-05 第 79 批状态：VMM 从 NAS 既有文件创建映像已接入官方 `Guest.Image.create` v1 与 `Task.Info.get/clear` v1。源文件、存储和同名基线在提交前复核，创建只提交一次；提交后仅按本次 `task_id` 观察，以稳定 `image_id`、名称和类型严格回读，终态任务清理与本地证据清除在总览刷新前收敛，断线、取消或结果不明确时不重放。Workspace 保留配置重建所需的草稿、任务证据、结构化结果、专项刷新和退出门禁，服务端任务未清理时即使结果已确认也禁止关闭或退出，并以 Repository、NAS、目标和双代次隔离迟到回调。映像表单具备双语加载、空、错误、正常及提交状态；三个目录选择器的系统返回在子目录先返回上级，VMM 创建向导先返回上一步。聚焦 JVM 34/34（映像 Repository 10、VMM 状态策略 20、目录返回策略 3、下载目标目录状态 1）、API 35 映像导入 5/5 与 VMM 创建返回 5/5、74 份请求 Fixture 本地门禁通过。实体机、真实 NAS、真实 VMM 权限/任务字段/副作用及进程死亡恢复按用户安排跳过并保持未验证；本批 GitHub 完整门禁待触发，最新已完成云端记录仍为第 78 批。VMM 高级管理与完整外部深链/深层返回栈等父组合目标仍未完成，不修改或缩减目标；A0–A8 保持 183/202（90.6%）、剩余 19 项。
- Android 2026-08-05 第 80 批状态：Download Station 使用官方 BTSearch v1 读取模块与类别目录，支持全部、已启用或指定提供方、类别、标题过滤、七类排序字段与升降序；正式提交与界面共用当前目录归属策略，拒绝空目录、陈旧标识、错误范围组合和无启用提供方。搜索任务在成功、失败或取消后均尝试清理本次临时任务，清理失败不冒充记录已移除。Statistic v1 独立读取标准和 eMule 四项当前聚合速率，局部失败与独立重试不遮蔽任务列表。发现页可见性、标签、搜索输入和目录标识只驻留 Workspace 内存，关闭即清除。VMM Task.Info v1 增加已结束任务受保护清理：服务端令牌只驻留内存且界面仅使用单向摘要；写前无序复核完整任务基线，只清理基线中的已结束任务，进行中任务零写；异常或取消后只回读一次且不重放。两轮独立终审发现的 Download 目录归属/空目录/2× 字体问题，以及 VMM 部分提交计数、取消证据和反馈标题问题已经修复。本地 Download JVM 22/22、VMM JVM 39/39、API 35 12/12；GitHub [Android Build 31003142582](https://github.com/yuangy1995/dsm-native-client/actions/runs/31003142582) 完成完整 JVM 1174/1174、Debug/Release/R8、仪器测试 APK、Debug lint与产物上传，[Repository Check 31003142578](https://github.com/yuangy1995/dsm-native-client/actions/runs/31003142578) 完成1924 项双语资源、79 份请求 Fixture、1 份结果示例、3 组响应 Fixture及 19 项私有 API 引用等仓库门禁。实体机与真实 NAS 按用户安排跳过；两个父组合叶子仍含 RSS/文件优先级/BT 协议高级设置及 VMM 高级硬件/迁移/克隆/导入导出等未实现能力，A0–A8 保持 183/202（90.6%）、剩余 19 项。
- Android 2026-08-05 第 81 批状态：外部 `lanstash://open/<module>` 仅允许固定模块根页并拒绝 NAS、路径、查询、会话、任务和凭据载荷。VMM 创建支持最多 8 块空白/映像混合磁盘、多网卡和未连接网卡；因公开 `Guest.get` 无源映像 ID，含映像盘结果保持需刷新核对。任务中心仅在页面可见、VMM 可用且仍有未结束任务时每 2 秒刷新 Task.Info，离页、完成或归属变化即停止。本机映像通过 `OpenDocument` 持久只读授权，依次执行 File Station 无覆盖暂存、`Guest.Image.create`、Task.Info、映像严格回读、任务清理和完整基线临时文件删除；加密记录支持跨进程只读恢复，不重放不明确上传/创建/清理，同名首次记录原子领取，入队异常比较 owner 后回滚；安全读取瞬时失败保留原阶段重试，映像暂未出现在列表时继续等待，同 ID 内容冲突才要求人工核对。本批聚焦 JVM 140/140（0 失败、0 跳过）、Debug/AndroidTest Kotlin 编译、1974 项双语资源、82 份请求 Fixture、页面五态、触控、动效、写矩阵、计划统计和差异门禁通过。实体机、真实 NAS、系统文件提供程序及真实权限/字段/副作用按用户安排跳过。组合叶子仍有高级硬件编辑、迁移、克隆、映像编辑/导出、任意业务对象外部深链等缺口，A0–A8 不变，仍为 183/202（90.6%）、剩余 19 项。
- Android 2026-08-05 第 82 批状态：新增唯一固定无载荷深页 `lanstash://open/containers/registry`。BROWSABLE 解析继续拒绝查询、片段、用户信息、端口、编码路径、对象标识和其他层级；`ACTION_VIEW` 永远先走 URI 白名单，不能用内部通知 extra 绕过。待处理状态只保存目标枚举，Workspace 未就绪、Activity 重建和第 81 批旧 Bundle 都可恢复最新请求；Registry 能力与模块可用性在切换前检查，同模块 `containers` 根入口会关闭已打开的 Registry。成功或拒绝后均消费并清除 URI，返回复用既有 `ModuleRoot(CONTAINERS) → ContainerRegistry` 栈。三路审计确认 Container Compose/部署、`pull_start` 及 VMM 高级硬件、迁移、克隆和导出仍缺行为验证，继续关闭且不新增伪入口。另将 `Guest.Image.delete` Fixture 的 `readbackPolicy` 从错误的 `taskPoll` 改为 `required`，与生产 Image.list 回读一致并增加精确守护。60/60 聚焦 JVM、Debug 与 AndroidTest Kotlin 编译、49/49 工具测试、82 份请求 Fixture及13/13 请求契约工具测试通过；对抗复核发现的 1 个 P1、3 个 P2 均已修复。GitHub [Android Build 31018613142](https://github.com/yuangy1995/dsm-native-client/actions/runs/31018613142) 完成 1238/1238 JVM、Debug/Release/R8、仪器测试 APK、Debug lint 与产物上传，[Repository Check 31018611379](https://github.com/yuangy1995/dsm-native-client/actions/runs/31018611379) 同步通过。实体机与真实 NAS 按用户安排跳过；A0–A8 保持 183/202（90.6%），剩余 19 项，原目标未删除、拆分或降级。
- Android 2026-08-05 第 83 批状态：按“多项一批”并行完成套件更新提示、真实套件图标和 Container Registry 官方来源标识。更新提示只投影 `available_operation` 中明确的 `upgrade`，不开放安装/升级；图标使用已登记内部只读 `Package.Thumb.get` v1，认证不进入 URL/磁盘，响应最多 2 MiB，只接受常见位图签名并解码，按 NAS/套件/版本/尺寸使用 4 MiB 内存 LRU，失败回退本地图标且不遮蔽套件列表；Registry 只信任既有 `isOfficial`，不从 trusted/automated 推断。套件与 Registry JVM 51/51、Debug 与 AndroidTest Kotlin 编译、1976 项 Android 双语资源、82 份请求 Fixture、页面/触控/动效/写矩阵、49 项工具测试及契约/Fixture 工具通过；独立终审发现的文档漂移和失败图标重组重复请求两项 P2 已修复，最终无未解决 P0/P1/P2。GitHub [Android Build 31022870159](https://github.com/yuangy1995/dsm-native-client/actions/runs/31022870159) 完成 1245/1245 JVM、Debug/Release/R8、仪器测试 APK、Debug lint 与报告/安装包上传，[Repository Check 31022869808](https://github.com/yuangy1995/dsm-native-client/actions/runs/31022869808) 同步通过。无连接设备，设备用例按用户安排留待统一验证。三项均完善既有组合目标，不重复计分；A0–A8 仍为 183/202（90.6%），剩余 19 项。
- Android 2026-08-06 第 85 批状态：VMM 只在 STOPPED 显示启动、RUNNING 显示正常与强制关机，`poweroff` 使用红色风险确认并继续执行状态预检、单次提交和停止态回读；Container 附属读取与日志固定 v1，取消/会话过期/认证失败不再被降级吞掉，概览清除详情与动态元数据。下载任务记录与照片备份来源在 WorkManager 入队边界同步落盘，普通下载进度仍异步写入；超 10,000 项扫描零部分入队，以兼容旧记录的 `needsAttention` 暂停来源并提示选择更小文件夹。图片预览和详情覆盖 EXIF 1–8，非嵌入全屏预览内容避开安全绘制区与 IME。本地 78/78 聚焦 JVM、Debug 与 AndroidTest Kotlin 编译通过；独立终审发现的周期任务 UUID 与截断时序 P1 已修复，最终无未解决 P0/P1。GitHub [Android Build 31036318092](https://github.com/yuangy1995/dsm-native-client/actions/runs/31036318092) 完成完整 JVM 1265/1265、Debug/Release/R8、仪器测试 APK、Debug lint 与产物上传，[Repository Check 31036318979](https://github.com/yuangy1995/dsm-native-client/actions/runs/31036318979) 同步通过。实体机、真实进程死亡、DocumentsProvider、HEIF/OEM EXIF、刘海/IME、TalkBack 及真实 NAS/VMM 写入按用户安排留待统一验证。以上均完善既有组合目标，不重复计分；A0–A8 仍为 183/202（90.6%），剩余 19 项。
- Android 2026-08-05 第 84 批状态：VMM Task.Info v1 的 2 秒轮询从整个模块可见收紧为任务分区真实可见、能力可用且仍有未结束任务；切换分区、返回根页、离开模块、任务完成或归属变化立即停止。新增 `lanstash://open/virtual-machines/tasks` 与 `lanstash://open/nas-settings/performance` 两个固定无载荷深页，严格区分协议和主机大小写并继续拒绝查询、片段、端口、用户信息、编码路径、额外层级和业务对象；Task.Info 或 System.Utilization v1 缺失时先验拒绝。Workspace 未就绪、Activity 重建、最新请求覆盖、根页收口、确定消费和系统返回沿用强类型枚举状态；性能迟到回调按代次、NAS、Repository、可见性和页签隔离。首轮测试发现直接扩展 `WorkspaceState` 会超过 JVM 构造函数参数上限，新增状态已收敛进既有 VMM 状态和单一性能内存状态，不改变持久结构。聚焦 JVM 19/19、Debug 与 AndroidTest Kotlin 编译、1976 项 Android 双语资源、82 份请求 Fixture、页面/触控/动效/写矩阵、49 项工具测试及契约/Fixture 工具通过；独立终审发现的两项 P1 与一项 P2 均已修复，第二轮无未解决 P0/P1/P2。GitHub [Android Build 31028760878](https://github.com/yuangy1995/dsm-native-client/actions/runs/31028760878) 完成完整 JVM 1248/1248、Debug/Release/R8、仪器测试 APK、Debug lint 与产物上传，[Repository Check 31028761405](https://github.com/yuangy1995/dsm-native-client/actions/runs/31028761405) 同步通过。无设备，实体机用例按用户安排留待统一验证。三项均完善既有组合目标，不重复计分；A0–A8 仍为 183/202（90.6%），剩余 19 项。
- Android 2026-08-06 第 88 批状态：VMM Guest 现可从机器动作弹窗进入独立只读详情，并通过官方 `Guest.get` v1 精确重读后签发/恢复不透明对象链接；返回只关闭详情，原启动、编辑、关机和删除入口保持不变。外链请求前后均拒绝覆盖活跃 VMM 写流程，能力缺失、ID 不一致或名称缺失时关闭，不显示 Guest、磁盘、网卡等内部 ID。聚焦 JVM、Debug 与 AndroidTest Kotlin 编译、31 页五态矩阵、49 项工具测试、1985 项 Android 双语资源、触控/动效/写矩阵通过；独立终审发现的两个 P1 和一个 P2 均闭环。GitHub [Android Build 31064773022](https://github.com/yuangy1995/dsm-native-client/actions/runs/31064773022) 与 [Repository Check 31064773033](https://github.com/yuangy1995/dsm-native-client/actions/runs/31064773033) 通过。真实 NAS、外部 App、进程死亡、预测返回、TalkBack/大字体和实体机仍未验证；本批不拆分或提前勾选 A0 混合叶子，A0–A8 保持 183/202（90.6%），剩余 19 项。
- Android 2026-08-06 第 89 批状态：经用户明确授权按移动端场景最终冻结目标，A0–A8 复算为 187/187（100%）、剩余 0 项。三路独立契约审计和已登录 Chrome 复核确认最后五项缺少足以安全上线的版本化契约、稳定身份或非持久 WebView 隔离；它们保留为“版本化契约后再评估”，不标记已实现，不新增伪入口，DSM Web/桌面端是当前替代。纯设备矩阵完整迁入 A9 并保持 `PENDING_USER_VALIDATION`。跨 NAS 文件夹只提供复制并核对，不自动递归删除源。Photos 共享空间根目录改用 opaque 令牌，打开前经公开 `getinfo` 重读；不可读目标拒绝且不切换空间。相关 JVM 40/40、AndroidTest Kotlin 编译、写矩阵、本地化与差异检查通过；GitHub 完整门禁以第 89 批最终功能提交为准。真实设备/NAS 仍未验证。
- 第 72 批五态局部补证：性能页首次加载/无样本空态与存储页内容分析局部失败 API 35 测试 7/7 通过；存储分析失败不再在测试中被写成整页失败。其他页面仍有状态缺口，A8 整页五态目标不计完成。
- Android GitHub Actions 已配置自动及手动构建门禁：Android 或其直接消费的共享 Fixture 变化时运行当前 JVM 测试集、Debug、debug 测试签名的 Release/R8、仪器测试 APK 编译和 Debug lint；增加 45 分钟超时、`--no-parallel`、同分支旧运行取消，并上传 Debug、Release、AndroidTest APK 与 JVM/lint 报告。仓库检查拒绝跟踪任意路径的 `keystore.properties`。CI 不执行设备仪器测试，正式签名、设备矩阵和发布材料仍未完成；临时 CI 提交将在功能完成后压成一个功能提交再合并 `main`。
- Android 第 80 批 GitHub 完整门禁已通过：[Android Build 31003142582](https://github.com/yuangy1995/dsm-native-client/actions/runs/31003142582) 完成 1174/1174 JVM、Debug/Release/R8 APK、仪器测试 APK、Debug lint和四组产物上传；[Repository Check 31003142578](https://github.com/yuangy1995/dsm-native-client/actions/runs/31003142578) 通过 79 份公共请求 Fixture、写矩阵、计划统计、页面/触控/动效、本地化与兼容门禁。本地聚焦 JVM 61/61、API 35 12/12 同步通过。实体机、TalkBack、OEM 显示缩放、真实 NAS 权限/版本/副作用及进程死亡恢复仍按用户安排留待打包验收。
- 自动化通过不替代真实 NAS 权限、网络、套件版本和回收站行为验证。

## 照片管理进度

| 里程碑 | 状态 | 下一出口 |
| --- | --- | --- |
| PH0 契约与实机探测 | 进行中 | 照片 Schema、Swift 模型和 Adapter 边界已实现；仍需补充 DSM build 和照片套件版本的脱敏记录 |
| PH1 基础照片库 | 已实现，部分实机确认 | 个人/共享空间、文件夹浏览、分页、可视范围优先缩略图、HEIC/MOV 本机兜底、刷新、空内容和错误恢复已实现；用户已确认文件夹可正常扫描，待格式兜底实机验收 |
| PH2 时间轴与查看器 | 基础能力已实现 | 已实现按天时间线、搜索筛选、异常子文件夹容错、完整预览器、EXIF 详情（尺寸、拍摄时间、相机、镜头、ISO、光圈、快门、焦距、位置）和年/月快速定位菜单；待大图库性能验收和实机元数据读取验证 |
| PH3 管理与分享 | 基础能力已实现 | 已接入上传、批量导出、删除、分享、收藏（File Station Favorite）和移动（照片内文件夹选择器）；照片页和预览窗口已增加回收站恢复入口（识别 #recycle 路径并调用恢复流程）；待基础相册入口和实机危险操作验收 |
| PH4 智能照片库 | 未开始 | 内部增强能力按 DSM 和套件版本验证，并可逐项降级 |
| PH5 macOS 发布验收 | 未开始 | 自动化、实机、安全、缓存、键盘、VoiceOver 和深色模式出口通过 |
| PH6 iPhone/iPad 与自动备份 | 未开始 | 完成后台备份、任务恢复和释放设备空间保护 |
| PH7 Android 对齐 | 进行中 | Compose 照片浏览、查看、管理和用户选定项目的安全移动备份调用链已建立；“释放设备空间”仅建立五项全真的 fail-closed 门禁，仍无 UI、媒体删除权限和本机删除执行器；待设备格式、大图库、真实 NAS 写操作及未来独立释放空间流程验收 |
| PH8 Windows 对齐 | 未开始 | WinUI 照片浏览、管理和桌面导入导出符合共同契约 |

照片模块按[照片管理开发计划](../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)推进。基础照片主流程已建立；下一步集中验证大图库、权限、弱网和写操作，并继续补齐相册与智能能力。

## Synology Chat 进度

| 里程碑 | 状态 | 下一出口 |
| --- | --- | --- |
| CH0 协议与会话探测 | 进行中 | 已脱敏记录 DSM 7.2.1-69057 Update 12 与 Chat Server 2.4.1-22111，并确认首次单聊、文件上传/读取、提醒、投票、定时消息及 Socket.IO 静态契约；下一步完成写入和二进制响应验收 |
| CH1 macOS 一对一文字聊天 | 需要验证 | 首次匿名会话已按 v2 契约实现创建前查重、提交和创建后复查；其余用户、气泡、分页、草稿、失败重试、轻量刷新、删除/关闭已实现，待双账号和管理员策略实机验收 |
| CH2 macOS 私人群聊 | 需要验证 | 已接入命名私人群聊创建、加入、邀请、重复提交保护和成员复查；下一出口是至少三个专用测试账号完成建群和多人收发验证 |
| CH3 macOS 媒体、文件和语音 | 需要验证 | 图片、视频和文件支持单个上传、进度、取消、重试和另存为；图片支持按需缩略图与单击纯图片预览，已移除重复的“打开附件”入口；下一出口是实机响应、大文件、视频内嵌播放、批量附件和语音消息 |
| CH4 macOS 提醒、定时消息与投票 | 需要验证 | 提醒设置/列表/取消、纯文字定时消息创建/列表/取消、投票创建与历史结构解析已实现。到期通知、定时消息修改/附件、投票参与/关闭/附图/截止/实时结果待实现 |
| CH5 macOS 加密会话 | 未开始 | 密钥生命周期、安全评审和跨设备验证通过，无明文降级 |
| CH6 macOS 发布验收 | 未开始 | 稳定性、兼容、安全、性能与可访问性出口通过 |
| CH7 其他平台对齐 | 进行中 | Android 已建立会话、消息、发送、附件、实时降级与多类稳定写结果，仍待服务器已读契约、真实 Chat Server 行为和设备验收；iPhone/iPad、Windows 按各自计划推进 |

Chat 模块按[Synology Chat 原生聊天功能开发计划](../development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)推进。基础契约、Apple 领域模型、能力保护适配器、首次单聊、文字、单附件发送和无附件投票创建已经建立；每项内部写能力仍须按 DSM build 与 Chat Server 版本分别验收，静态契约确认不能替代真实行为验证。

## 下一步

1. 补充当前测试 NAS 的 File Station 版本，并继续只记录脱敏后的版本、证书类型和连接方式。
2. 按[当前开发与验收计划](../development/NATIVE_DSM_FILE_APP_DEVELOPMENT_PLAN_ZH.md)完成登录、浏览、预览、传输和写操作回归。
3. 将实机结果写入[DSM 兼容矩阵](../compatibility/DSM_COMPATIBILITY_MATRIX.md)。
4. 修复验证中发现的问题，并为关键回归补充正式自动化测试。
5. 完成 macOS 发布前的无障碍、签名、公证、隐私和性能检查。
6. 使用专用测试照片完成 PH0/PH1 只读实机验收，并补充完全脱敏 fixture 和版本记录。
7. 使用专用测试账号和虚构数据验收首次单聊、附件收发、提醒、定时消息和投票创建；随后分析投票参与、实时同步和加密会话。
8. 使用正式签名验证 macOS Finder 域，并在 Windows x64/arm64 完成 Cloud Files 编译、安装、资源管理器重启和卸载恢复验收。

## 阻塞项

- 关键能力尚未形成覆盖目标 DSM build 的完整实机证据。
- 回收站恢复仍需按共享目录配置和 DSM build 验证。
- 正式分发方式、签名与商店/安装包发布流程尚未确定；仓库源码许可证已明确为 Apache-2.0。

## 状态定义

```text
未开始：尚未进入开发
进行中：已经开始且仍有明确开发工作
已实现：源码和自动化测试路径已经建立，但可能尚未完成实机验收
需要验证：实现已经存在，当前主要工作是收集真实环境证据
已完成：满足验收条件并完成文档记录
阻塞：需要外部决定、权限或环境
```
