<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-16 -->

# Windows 照片加载与跨模块请求一致性复核

本文主体为第一轮缺陷审计及交付记录。用户随后要求完成剩余差距，持续目标与最新波次证据
维护在[Windows 对齐计划](WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。后续已补齐 Chat
JSON 创建/成员与重复提交保护、Container 完整清单/日志分页、文件搜索编码/完整分页/清理；
下表中的历史“未同步/200 条摘要”不再代表这些切片的最新源码状态，其他差距仍继续实施。

## 目标与边界

用户反馈照片月份存在、列表加载失败，并要求检查所有功能的同类问题。以仓库 macOS
实现与已记录契约为证据，检查 Windows 请求、会话、日期边界、解析与页面错误状态。
当前工作区已有大量界面重建及 QuickConnect 未提交改动，全部保留；不提交或推送。
本轮不改 macOS、Apple 共享层或 Android，不新增 API、权限、依赖、持久化格式，
也不开放新的危险写操作。不以静态对照或合成测试宣称真实 NAS 全功能验收完成。

## 波次账本

| 切片 | macOS 证据 | Windows 等价语义与交互 | 契约、安全级别 | 初始验证 |
| --- | --- | --- | --- | --- |
| 照片加载 | `apple/Apps/DsmMac/Sources/SynologyPhotosModel.swift` 的 `timeRange`；`apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift` | 采用同等跨时区初始范围、非负下限；保留 WinUI 分页与月份跳转 | `photos-library-read`，内部只读；删除保护不变 | 源码确认本机日期边界偏差；截图具体触发原因未验证 |
| 会话传递 | `apple/Packages/DsmNetwork/Sources/DsmRequest.swift` | 已认证 POST 同时使用表单会话令牌和请求头，GET 凭据仍不进入 URL | 既有认证传输语义；认证/私有 API | 源码确认多个 Windows 表单入口仅传 Header 令牌 |
| 页面五态 | `apple/Apps/DsmMac/Sources/SynologyPhotosView.swift` | 加载失败显示恢复操作，不显示空图库添加提示；英语/中文资源 | 只读展示，不改变协议 | 截图及源码确认错误提示混用空状态说明 |
| 全模块同类审计 | `apple/Packages/DsmNetwork/Sources/` 各 Repository 与请求构造器 | 覆盖认证、Files、传输、Photos、Chat、Download Station、NAS 管理、Container、VMM；本地设置与系统集成核对是否经过同一网络入口 | 固定版本、业务编码、会话与响应语义；写门保持原状 | 待合成回归与集成复核 |
| Container 读取 | `DsmServiceManagementRepository.swift` 的 `containerActivityLogs/containerProjects` | 补齐日志参数、按能力编码 JSON 字符串，项目分区接受官方对象响应；保留当前 200 条摘要边界 | `container-manager-internal`，内部只读 | 新回归先复现 4 项失败，修复后通过 |

单一修改范围：当前任务负责上述 Windows 网络公共入口、照片状态/错误展示及对应测试，
只在已有 UI 改动上做最小增量。照片专项账本仍为
[照片计划](NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)，本文件记录此次跨模块缺陷复核。

## 已修复与审计结论

1. 照片初始时间范围改用 macOS 的 UTC 日历边界：最早日减一天并取非负值，最晚日加两天。
   原实现在 UTC+8 的 1970-01-01 得到负时间，`TimelineAsync` 成功后 `PhotosAsync` 被本地拒绝；
   新测试经过真实 Windows Repository/HTTP 编解码（合成响应）复现，修复后可加载。
   搜索、筛选保留日期交集，月份后续分页规则不扩张。
2. 全部 17 个 form-urlencoded 构造入口共用会话表单构造；File Station 上传及下载任务文件
   上传补齐 multipart 令牌。Chat 附件上传原本已包含该字段，不重复添加。GET 不改，凭据不入 URL。
3. 通用错误 106/107/119 与 macOS 一样标记登录失效；104 是不支持版本，不能误判登录失效。
   照片区分登录过期、权限、不可用与普通加载失败，错误态不再显示“先添加照片”。
4. Container 日志补齐 action/sort_by/sort_dir/loglevel/filter_content/datefrom/dateto；
   FORM 保持原值，JSON 字符串加正确编码。项目 `{}` 和 ID 到对象映射只在项目分区接受，
   不放宽容器/映像/网络的数组校验，不保存日志正文或账号。

| 模块 | 实际检查与结果 | 仍不能宣称完成的部分 |
| --- | --- | --- |
| 登录与会话 | 对照 Apple `DsmRequest.swift/DsmErrorMapper.swift`；登录/发现无会话，认证后的请求补令牌、纠正错误分类；合成检查跨请求不串凭据 | 不同 DSM 版本、OTP、网络与证书实机 |
| Files、上传下载、跨 NAS | 核对 `DsmApiClient` 的固定读取、变更提交、上传、Range 入口；统一修正 POST，GET 与提交次数/未知结果策略不改；全量现有回归执行 | 符号链接权限测试未通过；真实传输与危险写验收 |
| Photos | 初始范围、固定版本、JSON 业务值、列表解析、筛选、预览、保存/删除保护及页面错误态；相关回归通过 | 截图故障的真实 NAS 唯一根因仍未确认，不把合成复现说成现场诊断；媒体解码与共享非空内容待测 |
| Chat | 核对通用读取、会话创建与附件请求入口；通用 POST 修正，附件已有 multipart 令牌；全量 Chat 现有回归执行 | `HasChatWriteCapability` 仍限定 FORM，会话创建的 JSON 能力支持尚未同步；不能因共用传输修复称创建/高级写已对齐，需独立写安全切片 |
| Download Station | 核对公开 v1 固定请求、单任务控制及种子文件上传；修复共同表单与 multipart 令牌 | 不等于 macOS 设置、RSS、其他高级管理能力完成 |
| NAS 管理 | 核对固定读取与各设置调用公共传输；补令牌与登录失效传播；既有分区隔离不变 | 不等于所有 macOS 管理/危险写已完成或实测 |
| Container Manager | 上述日志参数、项目对象响应与 JSON 编码修复 | 仍是最多 200 条的只读摘要，未等价 macOS 完整日志分页、网络详情及生命周期写操作 |
| VMM | 核对公开 v1 清单和内部保护/事件入口；通用 POST 修复，版本门不变 | 仍是受限清单，不等价 macOS 生命周期/控制台 |
| 设置、传输中心、桌面云盘 | 本地设置/中心显示不使用 Photos 时间查询；云盘复用文件传输，注册门未变 | Explorer/Cloud Files 回调、系统注册和写回不是本次合成 API 测试的验证对象 |

结论是“已修复可复现的同类偏差”，不是“所有功能均无问题”或“Windows 完整复刻完成”。
需要继续的优先切片是 Chat JSON 会话创建的安全对齐、Container 完整只读分页及现有矩阵
中其他业务缺口；不因 macOS 有实现就绕过请求契约或安全门。

## 集成复核与验证

实现后单独进行只读差异复核与认证/内部 API 对抗检查：未改 GET URI、证书处理、同源校验、
账号隔离、固定 API 版本、删除确认、重复提交门和提交未知结果语义；新令牌来自当前会话，
不记录日志、不写入持久化。没有触发真实 NAS 写操作，没有改 Apple/Android 源码或公开契约。
五端影响：仅 Windows 修复既有契约的实现偏差，其余四端无接口/存储迁移；回滚为撤销本次
Windows 增量，不回退工作区已有改动。

实际 SDK：本机已有 `LanStashBuild/dotnet` 中的 .NET 10.0.401；默认 PATH 的 `dotnet test`
最初失败为找不到 SDK，之后使用既有 SDK 绝对路径执行，没有安装或升级工具链。

| 命令（仓库根目录） | 实际结果 |
| --- | --- |
| `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal` | 修改前 1595 通过、1 失败；修改后 1624 通过、1 失败、0 跳过，共 1625。唯一失败始终为 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`，本机缺少创建符号链接权限；未删断言/跳过/修改系统权限。 |
| 同上加 `--filter 'FullyQualifiedName~ContainerManagerRepositoryContractTests\|FullyQualifiedName~SessionRequestParityTests\|FullyQualifiedName~SynologyPhotos\|FullyQualifiedName~Photo\|FullyQualifiedName~FileUploadContractTests\|FullyQualifiedName~DownloadStationFileCreateTransportTests'` | 252 项聚焦测试通过；该次命令的 `\|` 表示 Markdown 表格转义，Shell 参数实际为 `|`。 |
| `dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal` | 成功，0 警告、0 错误。 |
| `./windows/tests/UiSmoke/run.ps1 -Scenarios photos,chat,downloads,containers,vms` | 14 场景通过：5 模块浅深色正常态，以及照片浅深色错误态、加载态和空态；人工检查错误截图不再提示添加照片。测试宿主不加载真实配置和凭据。 |
| `python tools/localization/check_localization.py` | 双语资源、引用与硬编码扫描通过，Windows 2024 个资源。 |
| `python tools/request-contract/validate_contracts.py` | 96 组请求 fixture 与 1 组写结果示例通过。 |
| `python tools/contract-validation/validate_fixtures.py` | 3 组 fixture 与 22 组私有 API 引用通过。 |
| `git diff --check` | 通过。 |
| `python tools/codex/check_documentation.py --strict-release` | 链接、标题锚点、角色、时效、动态证据与状态页行数通过。 |

Python 使用 Codex 已有 bundled runtime。独立测试包沿用 `windows/package.ps1`，关闭脚本内
重复测试（上表已独立执行且明确存在环境失败），不自动启动或安装，不覆盖旧包。
实际执行命令为 `./windows/package.ps1`，环境变量为 `LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`，
PATH 临时指向上述已有 SDK。x64 和 ARM64 Release 自包含包均成功，未编译合成宿主：

- `windows/dist/20260916-114206/LanStash-0.1.0-x64.zip`
- `windows/dist/20260916-114206/LanStash-0.1.0-arm64.zip`

产物带脚本生成的 SHA-256 和 `build-info.json`，明确为 `main@0eeeb170358c` 加工作区改动；
包含用户已有的界面重建改动，并非新的提交。包是本次交付，保留；本轮生成的 14 张合成 UI
临时验收截图已检查，清理请求被执行环境策略拒绝，仍位于忽略目录
`windows/dist/ui-review-20260916-114021/`，未提交；需要用户手动清理，可用正式合成脚本重跑。
保留全部源码测试和已有构建目录，未删除其他任务输出。未提交、推送、启动或安装；
不代表正式签名、托管 Runner 或真实 NAS 验收。

## PENDING_USER_VALIDATION

前置条件：新 Windows 构建、已获授权的 NAS 账号和 Photos 套件。
操作：刷新照片、月份定位、搜索、筛选、文件夹、相册、共享读取；检查其他模块正常读取。
预期：月份和照片可加载；失败时有正确恢复说明，不误报空图库。危险写仅在既有明确授权的
专用测试内容上单独验收，不为排错触发写请求。
回传：App/DSM/套件版本、权限类别、操作步骤及脱敏错误类别；不发送地址、账号、真实文件名、
日期元数据、原始响应或任何会话凭据。截图本身不能确认这次错误的唯一根因。
