<!-- doc-role: validation-report -->
<!-- last-reviewed: 2026-09-21 -->

# Windows 对齐与 Mac 修复最终范围核对

## 当前结论

本次已承诺范围内的源码开发、本地验证与 Windows 托管门禁已完成。用户明确授权的
专用分支 Windows Build **35601196998** 成功，3929 项测试通过，x64/ARM64 构建均
0 警告、0 错误；仓库及文档门禁同时通过。测试分支与隔离工作树已删除，全部源码仍在
本地 main 工作区，未提交或推送 main；不把开发完成等同于真实设备验收或正式发布。

范围仍是 Windows 对齐 macOS 已承诺的用户结果、照片及同类请求修复、用户反馈的
macOS 1.0.9 文件下载/照片保存删除修复、测试入口和交付包。真实 NAS、正式签名和
用户设备验收按用户要求后置；不把缺少这些证据改写成实现完成或实机通过。

## 按范围核对源码和证据

| 范围 | 当前入口与可复核源码 | 证据与边界 |
| --- | --- | --- |
| 认证、多 NAS、QuickConnect、证书 | `Features/Authentication`、`DsmApiClient`、Shell 连接上下文 | Authentication/SessionRequestParity/QuickConnect/Certificate 测试进入完整 xUnit；不同真实网络另验。 |
| Files、传输、复杂操作 | `FilesPage` 各 partial、`Features/Files`、`Features/Transfers` | 搜索、上传下载、目录/批量、文本预览编辑、压缩解压、分享、回收恢复、跨 NAS、拖放及撤销有专用测试和原生场景；真实数据副作用另验。 |
| Photos | `ShellPage → SynologyPhotosPage`、`SynologyPhotosWorkspace`、Synology Repository | 初始 UTC 范围、1970 下限、分页、筛选、保存/个人单项删除和错误恢复回归；错误不再假装空图库。当前 Mac 无自动备份/RSS 等新承诺，不据总称扩张范围。 |
| Chat | `ChatPage`、`ChatBrowserViewModel`、ChatAdvanced/Actions/Realtime | 消息、附件、成员、公告、提醒、定时、投票及已实现高级动作接入；未知结果不重发。Mac 尚未实现的加密/通话不伪装已实现。 |
| Download Station | `DownloadStationPage`、Settings/Batch/CreateFile/BtSearch | 设置、批量、任务文件创建与选项已接；`force_complete` 按保留未完成文件的语义处理，不冒充删除数据。 |
| NAS 管理 | `NasDetailsPage` 与 `Features/NasAdmin` 专用编辑/确认/恢复 | 系统、账号群组、网络、安全、硬件、电源、套件、计划、连接、硬盘和远程访问按已记录契约接入。电源计划、外接存储、内存压缩遵循 Mac 只读基线。 |
| Container/VMM | 两个正式管理页及 `Features/Containers`、`Features/VirtualMachines` | 生命周期、映像、网络、创建、设置、控制台、任务和恢复均有专用测试/原生场景；实际 VM/容器及控制台画面另验。 |
| 云盘 | `DesktopCloudDriveService`、SyncStore、三组协调器、`CloudDriveWriteScope`、设置/恢复窗口 | 分段读取、版本、保存、新建、移动/改名、删除、缓存和已完成副本回收已接；指定文件夹与全部共享内部均支持，挂载/共享根仍保护。日志版本 10 向后读取、旧包拒绝新格式并保留内容。 |
| 托盘、通知、本地设置 | `MainWindow` 注入 WindowsTransferNotificationService，Shell/生命周期及设置入口 | Null 服务仅作未注入后备，不是生产恒关；对应生命周期测试与原生场景存在。系统通知、外接卷、辅助功能及安装升级由用户后置验证。 |
| Mac 1.0.9 及同类修复 | Apple 共享 Repository、Workspace/SynologyPhotos/ServiceManagement/NasAdministration | Apple Build 35564520773 成功；当前 52 个 Apple 文件 Git blob 与该验证提交相同，详见 Apple 集成报告。 |

上述源码相对路径位于 `windows/src/LanStash.App`，网络适配位于
`windows/src/LanStash.Infrastructure`；测试位于 `windows/tests/LanStash.Tests`。
具体 API、权限、迁移与每轮命令见[持续账本](WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。

## 实际验证与包

- GitHub [Windows Build 35601196998](https://github.com/yuangy1995/dsm-native-client/actions/runs/35601196998)：
  提交 `c54acdc943c28a4b14f524a4d7b05714485cc3c6`，job `106337449127`。
  执行 `dotnet restore LanStash.slnx`、`dotnet test tests/LanStash.Tests/LanStash.Tests.csproj
  --configuration Release --no-restore --logger "console;verbosity=normal" --blame-hang
  --blame-hang-timeout 2m`，3929 项全部通过；随后分别执行
  `dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release
  --runtime win-x64 --no-restore` 与 `--runtime win-arm64`，两次均 0 警告/0 错误。
  Repository Check **35601196962**、Documentation & Quality Preflight **35601196969** 成功。
  664 个源码/契约/工具文件的 Git blob 与本地 main 一致，两项已删除页面亦一致；没有 CI
  修复提交，仅一个 Windows 语义完整提交，基于此前已整理并通过 Apple 验证的修复提交。
- `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal`：
  最新 3929 通过、0 失败、0 跳过，既有符号链接权限失败不再存在；打包脚本又运行同一完整测试。
- `windows/package.ps1`：NON_INTERACTIVE=1、TARGET_PLATFORM=both、RUN_TESTS=1、
  LAUNCH_AFTER=0、SELF_CONTAINED=1，x64/ARM64 自包含 Release 发布成功，未安装/启动。
- 重新读取旧中文全模块原生报告 `ui-review-20260921-021153/results.json`：925 通过，
  0 失败，925 张引用图像存在；这是此前完整波次，不冒充本轮重跑全部 925 场景。
- 最新云盘原生：中文 `ui-review-20260921-190100`、英文 `ui-review-20260921-190505`，
  各 47 通过；覆盖 allShares 确认后启用、无效范围拒绝、删除恢复、已释放副本等。
- CloudFilesNativeChecks 的 `--isolated-shell-binding`、`--isolated-recycle` 已通过。
  Shell 超时实为测试宿主未响应目录枚举，补齐并采用完成标志后文件/目录通知到达。
  检查包含真实占位身份、修改保护、元数据确认、部分内容、缓存释放及全部共享路径。
- 本地化 3402 Windows/4125 Apple/2188 Android 资源通过；111 请求样本、3 响应组、
  22 私有引用通过；契约/脱敏工具单元 13+13+3 通过；严格文档和 diff 检查通过。

当前 Windows 包位于 `windows/dist/20260921-190403`；ZIP 已重算 SHA-256、核查
exe/dll/PRI/hostfxr、build-info 的 testsRun/selfContained，以及生产程序集不含合成宿主：

| 包 | SHA-256 |
| --- | --- |
| LanStash-0.1.0-x64.zip | 3B913B493C6DD59D4766E2634DAD9EFC6A954ADFD94C7408D29FA60008F612EB |
| LanStash-0.1.0-arm64.zip | 8AB9165BC3C76185018C26A33596517A684742BF11C3AF74CDBBEBD1B794A2DF |

Mac Apple Silicon 包在 `apple/Apps/DsmMac/dist/github-parity-integration-20260921/`，
临时签名且不包含磁盘挂载扩展；DMG SHA-256 为
`E59864682FAFA3CA2600D4231135C636DC8D5FFB0D01A9B7EAD4E7D6FD3E89E7`。
云端测试详情及 57 项既有条件跳过见 [Apple 集成验证](APPLE_PARITY_INTEGRATION_VALIDATION_ZH.md)。

## 可测试入口、安全和清理

NAS 专用写入口不是因为未实测而永久禁用；`NasWriteAvailabilityTests` 验证另一 DSM
build 上，管理员及实际接口满足时可操作，权限不明/撤销或接口缺失仍拒绝。旧无确认
通用入口的 false 不能当作正式专用入口关闭，也不能为了“全部开放”移除这些保护。
云盘需在设置中明确允许本次系统集成，再在“同步与恢复”启用编辑；删除另外确认。

全部源码保留在本地 main（大量未提交改动保持原样），没有提交/推送 main。
本次 macOS 及 Windows 验证分支与隔离工作树已清理；Windows 远端删除使用精确提交
lease，清理前检查工作树干净且源码已保留。此前远端复核仅发现另一个历史分支
`codex/macos-parity-native-20260915`，未擅自删除不属于本次 CI 清理范围的分支。
合成 Cloud Files/Shell 临时根已清理，正式测试和可交付包保留。
此前获准创建的专用 NAS 测试 VM 按当时记录暂保留、不自动删除；本轮未重新读取其状态。

## 后置用户验证与范围外问题

PENDING_USER_VALIDATION：真实 DSM/套件权限、断网/重启、文件编辑器、媒体解码、
系统选择器/通知/外接卷、辅助功能，以及正式 Apple 签名/File Provider。使用可丢弃
文件和专用测试资源，先看权限和确认范围，未知结果只核查，不重复提交；只反馈版本、
操作步骤和脱敏错误，不传 SID、Cookie、主机、真实路径或原始响应。

本次 Windows/Mac 修复范围内不再有待完成的源码或云端门禁；上述用户验收仍未验证。
共享契约触发其他平台流水线，不表示已获得修改 Android 的授权。此前 Android
35561277878 中，下载目标目录创建调用仍用 v1，与已纠正为官方 v2 的 fixture 不一致，
有 1 项测试失败；本轮未修改 Android，不能宣称全仓五端 CI 全绿。Windows 分支同时
自动触发的 Apple 35601196965 和 Android 35601196971 在本次清理时仍运行中，不作为
Windows 通过依据；Mac 仍引用此前已完成的 Apple Build 35564520773。
