<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-21 -->

# Windows 对齐 macOS 功能长期计划

## 目标

Windows 使用 C# 与 WinUI 3，目标是在符合 Windows 键鼠、触控、窗口、资源管理器和系统
通知习惯的前提下，对齐 macOS 已承诺的业务与安全语义。当前状态见
[开发进度](../progress/STATUS.md)，跨端范围见[平台功能矩阵](../progress/PLATFORM_MATRIX.md)，
总控规则见[macOS 对齐总控计划](MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)。

## 2026-09-16 界面重建

用户明确要求按 macOS 样式重写 Windows 界面，并补充浅色、深色、文件、登录与 NAS 设置截图。
本波次以截图中的布局、比例、图标与层次为视觉基线，继续使用 WinUI 原生控件和 Windows 窗口。
实现、性能与本地包证据集中在[原生重建账本](WINDOWS_NATIVE_REBUILD_ZH.md)，本计划保留长期业务范围，
不再把旧 Windows 默认 NavigationView 外观作为验收基线。unpackaged 便携包可随包携带既有运行库，
不更改 Identity、最低系统、存储格式或签名策略。

## 不变量

2026-09-16 照片报错及所有模块同类请求偏差的修复、回归和仍未对齐项见
[请求一致性复核](WINDOWS_API_PARITY_AUDIT_ZH.md)。共同传输修复不代表所有业务流程完成复刻。

- 保持 `IDsmApiClient`、`DsmApiClient`、DI、`HttpClient` 生命周期和证书策略。
- 不新增程序集引用、不删除 Windows Application 项目、不重做 solution 架构。
- 保持 profile、会话、证书、能力、模块、导航、缓存和传输的隔离边界。
- 保持公开 API 的固定版本、参数编码、错误映射和 `MutationResult` 语义；私有写在未知
  DSM build 或套件版本默认关闭。
- 不改变当前发布形态、签名、Identity、最低系统版本或数据格式；这些变更必须单独批准。
- 所有新增用户可见文案同时提供英语和简体中文 `.resw` 资源。

## 当前结构与拆分方向

```text
windows/src/LanStash.Domain/          领域模型和跨模块契约
windows/src/LanStash.Infrastructure/  DSM 传输、会话、Repository 和平台无关实现
windows/src/LanStash.App/             WinUI Shell、页面、ViewModel 和平台适配
windows/tests/LanStash.Tests/         自动化测试
```

保留 `DsmApiClient` 门面，按现有 partial 文件方向拆分以下职责：

1. transport；
2. authentication；
3. discovery；
4. multipart upload；
5. download stream；
6. response decoding；
7. certificate policy。

拆分只能移动既有实现，不改变 API、DI 注册、`HttpClient` 复用、证书校验或异常语义。每个
partial 文件保持单一领域边界，并以源级契约、fixture 或 xUnit 证明行为不变。

## 实施优先级

### 2026-09-16 剩余差距持续实施账本

#### 2026-09-21 全部共享内部写回对齐

依据 Mac DesktopDriveWritebackSettingsSheet 和 ProviderWritebackTests 的 allShares
读写/递归删除，补 Windows 同一 NAS 的全部共享内部操作。共享本身和挂载根仍不可
创建、改名、移动或删除，已有共享内的文件/目录沿用权限、版本、确认和结果核查。
本片统一写入范围规则，调整既有日志/三个协调器/目录索引和原生设置入口及测试，不
增加 NAS API 或其他端代码。全部共享开启写回后日志升为版本 10，兼容读取旧记录，
旧包拒绝未知格式并保留未同步内容；沿用用户已批准的独立日志扩展，不改旧映射格式。

已完成 CloudDriveWriteScope 统一规则及保存、新建、删除、改名/移动、目录索引、原生
入口接线。全部共享的本地路径从完整共享名解析，不截掉首字符；只有已登记共享可
作为新项目的父级，不能通过本地新目录“创建共享”。跨共享移动继续使用同一 NAS
现有 Move/Rename 与不覆盖策略，身份和未同步副本随路径迁移。挂载根、共享根、
回收站和越界路径保持禁止写；原 folder 范围及确认/权限/未知结果保护保留。
新增 18 项回归，原“只支持 Folder”断言改为无效范围拒绝，并新增 allShares 正例及
共享根零请求负例，没有删除安全断言。完整 dotnet test windows/tests/LanStash.Tests/
LanStash.Tests.csproj -c Release --no-restore -v minimal：3929 通过、0 失败、0 跳过。
--isolated-recycle 原生检查通过，额外验证真实共享占位身份下的完整路径捕获；临时根
全部清理，未执行真实 NAS 写操作。

./windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN -WindowWidth
1000 -PaneState compact：47 通过，ui-review-20260921-190100；同宿主 -SkipBuild
-Language en-US：47 通过，ui-review-20260921-190505。allShares 场景已验证确认后可
启用，另有无效范围拒绝场景；中英截图复核通过。3402 双语资源、111 请求样本、3 组
响应样本、22 私有引用检查通过，契约/脱敏工具 13+13+3 项单元通过。

windows/package.ps1 使用 NON_INTERACTIVE=1、TARGET_PLATFORM=both、RUN_TESTS=1、
LAUNCH_AFTER=0、SELF_CONTAINED=1，再次执行 3929 项测试并发布两架构，产物为
windows/dist/20260921-190403 的自包含 Release ZIP，替代 183253 中间包。必需 exe、
dll、PRI、hostfxr 和 build-info（testsRun/selfContained 均 true）已核查，生产程序集
没有 SmokeWorkspace；没有安装或启动。SHA-256：

- x64：3B913B493C6DD59D4766E2634DAD9EFC6A954ADFD94C7408D29FA60008F612EB
- ARM64：8AB9165BC3C76185018C26A33596517A684742BF11C3AF74CDBBEBD1B794A2DF

代码仍保留未提交的 main。此处关闭 allShares 开发缺口；交付前仍须汇总完整范围的
最终验收清单，不能用这一个切片的通过替代整个对齐目标。真实 NAS、目标设备和正式
签名按用户要求后置，PENDING_USER_VALIDATION 的操作/风险说明沿用各能力账本。

#### 2026-09-21 Shell 回收站闭环与最终复核发现

回收站超时已定位并修复测试宿主：非云文件的只读 Shell 绑定对照正常，云端占位需要
响应 FETCH_PLACEHOLDERS。补齐后 IFileOperation 的文件和目录回收请求均实际到达
NOTIFY_DELETE；观察到文件 3 次、目录 1 次通知（含基准直接删除及目录子项）。
目录完成标志按官方枚举改为 DISABLE_ON_DEMAND_POPULATION=2，并同步到生产的空
目录/完整批次响应；原枚举反馈缺少完成标志会重复请求，现隔离过程仅 2 次枚举。
依据 [官方枚举说明](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ne-cfapi-cf_operation_transfer_placeholders_flags)。

Shell 回收请求还会先清除文件 InSync，但 ModifiedDataSize 为 0 且原身份不变。
生产删除通知现仅登记身份正确、数据未改写的请求；明确确认时重新读 NAS 并核对大小，
才恢复这种元数据状态，真正修改/截断仍保护。目录请求将尚未确认的子项合并为一次
目录确认；已提交/未知子项不能吞并，旧确认失效。新增两项回归，完整 3911 项通过。
--isolated-shell-binding、--isolated-recycle 均通过，未真正移除任何 NAS 项目；测试
原文件被保留到隔离清理，临时根残留 0。旧超时不是当前未解决问题，也不是 Shell
注册不足的证据；没有据此引入未验证的新系统注册流程。

按现有 windows/package.ps1（NON_INTERACTIVE=1、TARGET_PLATFORM=both、RUN_TESTS=1、
LAUNCH_AFTER=0、SELF_CONTAINED=1）生成中间包 windows/dist/20260921-183253。
两架构 publish 与 3911 项测试通过，ZIP 校验及必需运行库/资源/生产模式检查通过。
复核 Apple 验证提交对应的 52 个 Apple 文件，当前 main Git blob 全部相同；Mac DMG
SHA-256 仍符合原报告，本地 macOS 测试分支和独立工作树均不存在。

**最终范围复核发现新的真实差距，不能交付为全部完成：** Mac
DesktopDriveWritebackSettingsSheet 不限制 allShares，ProviderWritebackTests 明确验证
allShares 内部文件夹递归删除；Windows 的 SyncStore、三个写协调器和确认页仍只开放
Folder。因此下一片补齐全部共享内部写入/创建/改名/移动/删除，保持挂载根和共享根
只读，根目录不允许新建共享。该项属于原完整对齐目标，不归入用户真机待办。
刚生成的 183253 包只保留为中间验证产物，不能冒充最终包；完整包须待该差距补齐后
重新生成。真实 NAS/用户设备仍按原约定后置。

#### 2026-09-21 缓存释放与已完成副本收尾

Mac 基线为 DsmCore/DesktopDriveWriteback.swift 的 complete/removeCompletedContent：
保存经回读确认后删除临时内容，保留轻量记录。Windows 本片修改缓存原生释放、保存后
统计和独立日志副本回收；释放前核对原身份、已同步/未固定状态并恢复只读，保持长度。
仅在本地内容也完成确认后释放已保存的上传副本，未同步/未知/保留本地记录不变。
沿用已获批的日志扩展，版本 9 新增内容释放标志；旧记录默认仍保留，旧 App 拒绝新版
且不删除未同步内容，旧映射配置/NAS 契约/其他端不变。重试副本用临时文件和原子发布，
失败保留原记录。本片的 UI 只说明已保存副本清理，不提供指向不存在副本的导出入口。

已完成上述接线。新保存及重启发现的已同步文件会更新缓存统计；统计失败不会再次
上传。清理使用原身份、排他属性句柄和 VERIFY_IN_SYNC，不释放固定离线、未保存或
正在读取的文件，释放后长度不变且只读。清理统计按原快照逐项合并，不覆盖并发新
保存、其他状态或新离线偏好；断开状态不再假装已清理或提前移除离线偏好。
本地确认成功后，当前及同路径更早的已核实副本先写内容释放记录再删除；无法删除
的文件可在重连时按记录清理。其他路径、待同步、未知、冲突和保留本地内容不清理。
重试先写临时文件、核对内容后发布，日志失败只移除本次未发布副本，原副本不变。

新增 12 项聚焦回归；旧空文件保存测试改为精确断言版本 9，并继续校验创建/基线字段
和缺少 Kind 的拒绝，不降低旧保护。首次编译纠正 InvalidDataException 并非 IOException
子类的异常过滤写法。实际 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal：3909 通过、0 失败、0 跳过。App x64/ARM64 Release
使用前节同形 Platform/runtime 构建命令，均 0 警告/错误。CloudFilesNativeChecks
--isolated-refresh 通过，新增固定离线/读占用/未保存保护与释放后只读、长度核查，
全部合成根清理。没有重跑仍失败的 --isolated-recycle，也不把本轮当作其通过。

./windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN -WindowWidth
1000 -PaneState compact：46 通过，ui-review-20260921-180203；同宿主 -SkipBuild
-Language en-US：46 通过，ui-review-20260921-180849。新增已释放副本浅/深色场景，
断言不再提供导出；中英截图复核未见截断。3402 项 Windows 双语/硬编码检查、111
请求样本、严格文档与 diff 检查通过。源码仍为未提交的本地 main；没有新分发包。
缓存和副本组收尾完成，剩余回收站 Shell 集成、全范围最终复核和可交付包；真实 NAS
与用户编辑器验收继续后置，不算上述剩余开发。

#### 2026-09-21 回收站事件及内容同步标记

本片只修改 Windows 云盘系统策略/请求识别及隔离原生回归，延续 Mac 的删除确认、
未同步内容保护和稳定身份语义。先用无界面的 Shell 文件操作检查合成文件/目录进入
回收站时的通知，不读取或清空用户回收站。同步标记按官方 CF_SYNC_POLICIES 语义校正：
文件数据变更始终清除已同步状态，未实现回传的 Windows 属性不应制造内容修改。
不修改权限、凭据、存储结构或 NAS API；旧根在既有 RegisterUpdate 流程更新策略。
同时复核有待删除记录时的重连，不能在加载已有别名时触发“新登记”路径互锁。

已修复：重连只读取已有名称（旧版首次迁移仍保留），不重新登记待删除路径；新增
重连回归证明读取不改日志。同步策略使用默认元数据策略，数据改动仍由系统标脏。
改名本身即便在默认策略下仍清除 InSync，因此另外接生产 AcknowledgeRelocation：
只在 NAS 已核实、目标身份/类型/大小匹配、ModifiedDataSize 为 0 时，以排他属性句柄
确认名称更新；真正原位编辑、同长度覆盖和长度不符均不标已同步，不申请 READ_DATA。
隔离原生检查验证 4096 字节未下载占位改名确认后仍占用 0 数据字节，隐藏属性不会
制造上传，真实编辑仍未同步。依据为
[同步策略](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ns-cfapi-cf_sync_policies)、
[内容修改量](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ns-cfapi-cf_placeholder_standard_info)。
同时将生产目录策略从官方不支持的 PARTIAL(0) 改为 FULL(2)，现有枚举已经读完全部
分页再分批回传；测试根内容全部由夹具创建，使用 ALWAYS_FULL(3)，不冒充生产 NAS
枚举验证。策略值依据 [官方枚举](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ne-cfapi-cf_population_policy_primary)。

dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore
-v minimal：3897 通过、0 失败、0 跳过。App x64/ARM64 Release（前节同形命令）均
0 警告/错误；CloudFilesNativeChecks --isolated-refresh 通过，包含新增元数据/真实
编辑/未下载数据保护断言。3401 双语资源、111 请求样本、严格文档及 diff 检查通过。
无 UI 修改，未重跑此前 44 场景或生成包；未提交/推送 main。

回收站另有明确失败证据：新增 --isolated-recycle 模式使用独立文件/目录、STA/OLE、
官方 IFileOperation 和 NO_UI，仅请求合成目标进入回收站。此前 SHFileOperation 及当前
IFileOperation 均在 30 秒内未完成；最新阶段日志证明 SetOperationFlags 已返回，卡在
SHCreateItemFromParsingName，尚未调用 DeleteItem/PerformOperations，也没有新回收站
删除/目录回调证据。测试根 ALWAYS_FULL、独立全新零字节文件仍可复现。超时只终止
本次子进程，所有合成根均清理、残留 0；不接触/清空系统已有回收站内容。没有降低
已有 --isolated-refresh 的断言；新 Shell 检查必须另外报告失败，不能用直接删除通过
代替回收站通过。保留 ShellRecycle.cs 为可复现的正式检查，不提交一次性抓取或日志。
下一步检查 Shell 绑定与完整 Shell 注册条件（当前源码仅有 CfRegisterSyncRoot，尚无
StorageProviderSyncRootManager；这只是排查线索，不是已确认根因），再补事件桥接；
该项仍计集成开发。缓存/副本保留和最终包也未完成，真实 NAS 验收仍后置。

#### 2026-09-21 删除后的本地清理与稳定身份

延续上一片的 Mac finishDeletion/removeDeletedItemPaths 语义，Windows 先核对删除记录
和本地同步状态，再清理原对象的本地投影/索引，最后完成日志。新登记的对象使用随机
生成后持久保存的既有格式身份，旧索引原样保留；删除后同名新对象不能再取得旧身份，
不新增旧配置字段或迁移。只修改云盘存储/清理、回调/确认接线及对应回归和资源；旧版本
日志读取规则与用户数据不变。高风险写在合成环境验证，真实 NAS 后置验收。

已接本地清理协调器、删除通知和普通文件消失通知、AppViewModel/设置入口及双语确认
窗口。占位删除先拒绝本机移除并登记待确认，窗口明确确认后才提交 NAS；普通文件
删除事件在改名/覆盖保存处理后再判定，不把编辑器替换保存当成删除。发送前检查本地
树，不删除未同步/未知内容；NAS 核实缺失后仅清理身份匹配的已同步占位，允许明确
删除已固定离线内容，但普通缓存清理仍不允许。部分本地失败保留 ServerVerified。
索引/日志任一写入中断都可重试；已清理旧身份后同名新项目不会被旧记录再次命中。
默认不开删除，启用需独立勾选，每项仍需确认；取消、未知核查和本地完成按钮分别接线。

按 [官方删除标志](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ne-cfapi-cf_callback_delete_flags)
区分目录与 undelete，恢复通知不登记成新删除。参数偏移已由隔离原生回调与生产解析器
实测核对，未知标志/短参数拒绝。新增 14 项回归覆盖身份重用、两个存储之间的中断、
缓存/离线偏好清理范围、未验证不清理，以及替换/改名/普通删除事件区分和参数标志。

实际验证：dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore -v minimal：3896 通过、0 失败、0 跳过；App x64/ARM64 Release 构建
均 0 警告/错误，使用上一节记录的 Platform/runtime、--no-restore、LanStashUiSmoke=false。
dotnet run --project windows/tests/CloudFilesNativeChecks/CloudFilesNativeChecks.csproj
-c Release -- --isolated-refresh 通过、合成根残留 0。新增已确认的固定离线清理及参数
解析检查；首轮固定离线检查的合成文件刚完成外部改名、尚非已同步，前置检查正确拒绝，
已明确设置该测试的“已同步”前提后验证清理，没有放宽生产未同步保护。

./windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN -WindowWidth
1000 -PaneState compact：44 通过，ui-review-20260921-170923；同宿主 -SkipBuild
-Language en-US：44 通过，ui-review-20260921-171342。新增删除开关、目录确认浅/深色、
未知与本地清理 5 个场景。截图复核未见横向截断，长内容可滚动；3401 项 Windows
双语/硬编码检查、111 请求样本、严格文档和 diff 检查通过。未生成新分发包。

下一集成片仍需核查并收敛资源管理器普通删除的回收站路径/目录事件序列，以及改名后
仅元数据变化的 InSync 处理；不能用本次直接删除回调或手工设置的测试前提宣布这些
系统流程已完成。undelete 目前不执行 NAS 写，系统回收站恢复也不宣称已经支持。
这些计为当前环境可做的集成开发，不转嫁为用户待办。随后完成缓存/副本保留审查与
最终打包；NAS 真实数据删除仍未执行，用户后置验收时只用可丢弃文件并回传脱敏结果。

#### 2026-09-21 删除同步的独立确认与恢复日志

macOS 证据为 FileProviderExtension/ProviderRuntime.swift 的 deleteItem、checkDeletionChildren
及 finishDeletion。Windows 复用现有公开 SYNO.FileStation.Delete 适配和精确 getinfo
缺失判断，先落盘独立删除记录，用户确认后提交，未知只查不重发。目录删除明确包含
全部子项，提交前完整分页检查子项类型/权限；未同步或保留本地内容不能被顺带删除。
本片唯一修改范围为云盘删除模型、同步日志/路径互锁、协调器及聚焦测试；原生回调、
确认界面和最终本地清理后续接入，不以核心测试通过宣称完整入口完成。
沿用已获批准的独立日志持久化扩展：版本 8 增加删除开关/记录，默认关闭、旧版本兼容；
旧 App 拒绝未知版本并保留未同步内容，不改旧映射配置或其他平台。没有新增 NAS 请求
契约，不需要复制私有接口；本片高风险写只在合成 Repository 中验证，不操作真实数据。

已实现准备/明确确认/只读核查/提交前放弃，阶段为 Prepared、Submitted、ServerVerified、
Completed、Abandoned。启用保存不会自动启用删除；关闭保存同时关闭删除，未结束操作
阻止关闭。版本 8 必须含删除开关与记录，后续改名不能把格式降回 7，损坏字段不重置。
新增删除预留与既有保存/新建/刷新/改名/本地投影清理互锁；本地保留内容也阻止删除。
复用既有 Delete v2 能力元数据，不把接口可用误当作 NAS 回收站开启或删除可恢复。

独立只读复核确认：删除请求前写 Submitted，失败/取消后不复用 Prepared；目录完整
分页且逐项精确核查类型/权限，挂载点/链接/回收站/映射根拒绝；最后精确 getinfo 和
父目录可访问性回读，不用旧删除适配器的首批目录轮询作为成功证据。删除后的本地
身份退役/清理及完整入口尚未接线，因此当前原生用户删除仍拒绝，不能称删除已交付。

新增 25 项合成回归。dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal：3882 通过、0 失败、0 跳过；App 构建使用
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64
-r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal，及对应 arm64/win-arm64，
均 0 警告/错误。CloudFilesNativeChecks --isolated-refresh 通过，仍断言外部删除拒绝，
不把原生既有检查算作新删除链路验收；临时同步根残留 0。双语 3389 项、请求样本
111 项、严格文档及 diff 检查通过；无 UI 变更，无新包，未提交/推送 main。
下一片必须完成身份退役、本地结果处理、原生请求与独立确认/恢复入口，然后才进入
用户真实 NAS 删除验证；缓存/副本保留与最终包继续作为后续开发，整体目标未完成。

#### 2026-09-21 普通覆盖文件的改名恢复

本片延续 DesktopCloudDriveProvider.relocateItemPaths 的稳定身份语义，接 Windows
文件系统改名事件与现有 Rename/CopyMove 状态机。覆盖保存后的普通文件先转换为原身份
的未同步占位，再核查/提交远端移动；恢复扫描按占位身份识别改名而非新建，保留本地
修改与原版本基线。使用官方 CfConvertToPlaceholder，不指定 MARK_IN_SYNC 或 DEHYDRATE，
不改 API、日志格式、旧配置或其他平台。修改范围为云盘会话、原生适配、运行时及回归。
系统集成/普通写需验证原身份、范围、同名占用、离线恢复与未同步保护；删除和清理不在
本片内。真实 NAS/编辑器验收后置，源码与隔离验证先完成，结果随后补记。

已接改名事件的原路径/新路径处理，连续改名合并为原来源到最终名称，文件占用时保留
队列并重试，绑定失败不会落入新建上传。恢复扫描读取原占位身份并复用原移动日志，
只在远端和本地均核查后迁移版本/索引，再保存编辑内容。未知或拒绝的已有操作不自动
重发；用户放弃尚未执行的改名时先恢复原本地名称，避免扫描重新提交同一次操作。
原位置缺失时禁止直接关闭写回，也不猜测未知普通文件为新建；事件溢出/未运行期间
丢失的普通文件改名关系不能凭名称推断。此时保留内容，先恢复原名称再重新操作。

原生转换依据 [CfConvertToPlaceholder 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfconverttoplaceholder)，
使用既有注册/身份，不修改 ACL 或原始内容，不标记已同步。独立复核覆盖：父目录归属、
原位置重建/目标占用拒绝、硬链接/未知重解析点拒绝、未知 NAS 请求不重发、取消后日志
保留；原生读取恢复不借普通文件名冒充远端身份。

验证结果：dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore -v minimal：3857 通过、0 失败、0 跳过。新增 3 项覆盖先改名再保存至新路径、
失败不新建、连续改名与占用重试。首轮既有源码扫描将本地绑定方法名称后缀误认成直接
NAS RenameAsync 调用；改为准确的 BindObservedLocalMoveAsync 名称，未修改测试断言。
App x64/ARM64 Release 均 0 警告/错误，命令与下一节相同。CloudFilesNativeChecks 的
--isolated-refresh 通过，确认普通文件转换后身份持久、内容完整且未同步，错误身份
不能夺取文件，断开后仍可读取身份/内容；合成根全部清理。双语 3389 项、请求样本
111 项及 diff 检查通过。没有 UI 变更或新分发包，不把合成测试表述为真实 NAS 通过。

PENDING_USER_VALIDATION：启用云盘保存后，以可丢弃文本文件做编辑器覆盖保存及改名，
确认 NAS 只保留新路径且内容正确；断网改名后重连核查，未知结果在恢复窗口只核查，
不要重复提交。回传编辑器类别、操作顺序、是否断网/重启及脱敏错误，不提供真实路径。
剩余开发集中于删除同步、缓存/副本保留集成复核和最终打包。

#### 2026-09-21 改名的实际名称与历史别名收尾

沿用上一切片的 macOS 稳定身份/路径迁移基线和公开 Rename/CopyMove 契约，本片只修改
Windows 云盘本地完成、同步别名迁移及对应回归。资源管理器仅改变大小写时必须核对
磁盘实际名称，不能以不区分大小写的存在检查冒充完成；恢复只移动已核对身份的源。
历史别名重用必须有当前索引为空的证据，同时保留未同步/本地保留内容及有效版本保护。
不新增 API 或存储结构，不改其他端；属于普通写与系统集成，验证结果在本节补记。
普通替换文件改名、删除、缓存/副本清理和最终打包仍是后续开发，不列为用户真机缺口。

已完成上述两项修复及 10 项新增回归。实际文件和目录的大小写恢复、重复完成、错误
身份拒绝均通过；历史别名需当前索引无目标，版本/空文件基线/创建意图/未同步或本地
保留记录均阻止重用。已核查的历史内容快照不删除，跨存储中断仍靠原迁移回执恢复。
集成复核确认名称变化先于完成日志、现存目标不覆盖、回执恢复不误迁移后来重用的源。

实际验证命令及结果：

- dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal：
  3854 通过、0 失败、0 跳过。
- dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64
  -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal，以及对应 arm64/win-arm64：
  两者均 0 警告、0 错误。
- dotnet run --project windows/tests/CloudFilesNativeChecks/CloudFilesNativeChecks.csproj
  -c Release -- --isolated-refresh：通过；新增真实占位大小写往返改名及原身份核查，
  全部合成根已清理、残留 0，没有连接 NAS。
- python tools/localization/check_localization.py 与 tools/request-contract/validate_contracts.py：
  3389 项 Windows 双语资源和 111 请求样本通过；git -c core.safecrlf=false diff --check 通过。

本片没有界面/资源变更，没有重跑此前 UI 场景，也没有新分发包。真实编辑器和 NAS
端到端为 PENDING_USER_VALIDATION，沿用本节前一切片的测试步骤与反馈要求。

#### 2026-09-21 原生重命名完成与恢复

继续现有迁移切片：解析 Windows 原生改名请求，只接受同一映射内目标，校验占位身份
和文件编号后调用已实现的 NAS 状态机；NAS 完成才允许本机继续。完成通知或明确恢复
操作再核对本机目标身份，迁移日志/索引并解除路径保留。未知和部分完成记录进入同步
恢复窗口，不重发已完成步骤，不覆盖本地或 NAS 同名目标。原生接口以 Microsoft
CF_CALLBACK_PARAMETERS/CF_OPERATION_PARAMETERS 为依据，仅用隔离合成根验证。

已接原生请求与完成回调：卷内相对目标解析后限制到同一映射，核对源文件编号和根
编号，50 秒内取得明确结果才 ACK；超时保留日志。完成后核对目标仍持有原身份，先
更新同步日志再更新目录索引，最后标记完成；两次写入间或索引写入后中断都可恢复，
不会再次移动后来重用原路径的新项目。窗口可核查未知结果、确认继续、完成本机移动，
并仅在尚未开始时放弃。目录通知和关闭通知不会把待迁移目标误认为新建上传。

新增 14 项回归覆盖本机身份、两个存储之间的中断/重启、旧路径重用、参数布局与
越界/数据流路径拒绝。完整 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal：3844 通过、0 失败、0 跳过。文件占用测试实际
返回 UnauthorizedAccessException，已按观测结果修正精确异常断言，恢复断言保持。
CloudFilesNativeChecks --isolated-refresh 验证同一外部进程经生产路径解析器完成改名、
收到完成通知且原身份保留，后续删除仍被拒绝。此前第二个独立检查进程启动后未进入
托管检查代码而超时；改为同一独立进程串联操作，保留全部回调/身份/删除拒绝断言。
本轮所有合成根清理完毕；没有真实 NAS 写入，不把上述证据表述为 App + NAS 实机验收。

./windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN
-WindowWidth 1000 -PaneState compact：39 通过，ui-review-20260921-161118；
英文以 -SkipBuild -Language en-US 同形命令运行，39 通过，ui-review-20260921-161517。
3389 个 Windows 资源及 111 请求样本检查通过。尚需收敛普通替换文件改名、仅大小写
改名和历史目标名重用；这些是代码集成待办，不记成用户实机待办。删除及缓存/保留策略
也继续推进，本轮没有生成分发包，不宣布完整移动能力或整体目标完成。
最终 App x64/ARM64 Release 构建均通过，0 警告/错误，使用 Platform/runtime、
--no-restore、LanStashUiSmoke=false。界面截图复核未见文本截断；严格文档与 diff
检查通过，临时诊断输出已移除，合成根和子进程均已清理。

#### 2026-09-21 重命名与移动的提交状态机

复用已有公开 Rename v2 / CopyMove v3 适配器，不另发猜测请求。移动后改名分成固定
两步，独立日志版本 7 记录当前步骤、源目标、身份与核查状态；旧记录兼容读取，旧 App
拒绝未知结构并保留数据。沿用用户批准的云盘日志扩展，不改旧映射配置或其他端源码。
各步骤提交前落盘，明确拒绝可由用户确认后继续，回执未知仅核查，不能自动重放。
核查不自动执行下一步；涉及路径在迁移未完成期间阻止上传/刷新/清理。此处仍未开放
资源管理器的 NAS 改名入口，需继续接原生回调、本地完成与恢复界面后才形成完整流程。

已实现提交/继续/只读核查/未开始时放弃的核心。单步改名与先移动后改名均使用原有
Repository；每次重新核对源目标及父目录，固定不覆盖同名项。步骤完成后保留中间路径，
中途明确拒绝只重试剩余步骤；已发生移动不能直接把整个操作标成放弃。原生接线必须
尊重这些状态，不得把 ServerVerified 当成本地已经完成。

新增 10 项回归覆盖两步顺序、未知首次/末次回执、明确拒绝、目标/中间路径冲突、
归属核查与迁移期间路径保护。完整 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal：3830 通过、0 失败、0 跳过；App x64/ARM64
Release 构建（Platform/runtime、--no-restore、LanStashUiSmoke=false）均 0 警告/错误。
首次编译补齐合成 Repository 的范围读取接口成员，未放宽断言。双语、111 请求样本、
严格文档与 diff 检查通过。本轮未修改 UI、未生成包、未执行真实 NAS 写操作；原生
完成及跨日志恢复仍需实现，不能以这组状态机测试宣称重命名/移动已完整交付。

#### 2026-09-21 重命名与移动的稳定身份接线

Mac 基线为 DesktopCloudDriveProvider.registerItemPaths/relocateItemPaths：移动后的
文件与后代继续使用原身份，原路径重新创建的项目不能抢回旧身份。Windows 本片在现有
索引格式内保留身份、移动离线偏好与缓存条目，并让原生检查和写回读取实际索引，不再
处处按新路径重新推导身份。同步日志迁移与 NAS/资源管理器事件仍属本切片后续步骤；
不得只完成索引工具就宣布移动功能完成。沿用既有结构，不改 NAS 协议或其他四端源码。

现有映射索引仍为原格式，注册路径时优先保留已绑定身份；原路径被重新使用时生成
新身份。运行时、写回会话和同步存储的原生校验已改用索引中的身份，文件及后代不会
因改名而重新生成身份。新建的同步迁移回执为日志版本 6，沿用已批准的独立日志扩展：
名称、强版本、空文件基线、新建意图及待同步记录在一次原子写入内变更，内容副本不搬动。
同一编号重复执行只返回既有结果，不影响后来重用原路径的新项目；未知上传尚未核实
时拒绝迁移。旧日志可读，旧 App 对未知版本保持拒绝并保留内容，不改变旧映射配置格式。

新增 11 项聚焦回归全部通过；完整 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal：
3820 通过、0 失败、0 跳过。CloudFilesNativeChecks --isolated-refresh 真实改名后
仍可用旧身份读取占位，待同步副本编号/内容保留，测试根残留为 0。此次没有真实 NAS
写入，没有开放尚未接完的原生重命名入口；NAS 操作、跨存储恢复和本地完成核查继续实现。
App x64/ARM64 Release 构建均通过，0 警告/错误，使用 Platform/runtime、--no-restore、
LanStashUiSmoke=false；本地化、111 请求样本、严格文档及 diff 检查通过。本轮 UI
没有变化，未运行新的绘制回归或打包，不把前一轮截图当作重命名功能已经可用。

#### 2026-09-21 云盘新建文件与目录

Mac 基线为 ProviderRuntime.writeItem 的 creating 分支及 ProviderWritebackTests 的
新建文件/目录用例；Windows 从文件系统事件及重启扫描识别普通本地新建项，持久名称
映射仍与 NAS 名称区分，不对新建名称做百分号反解码。版本 5 记录新建意图和操作类型，
旧日志可读，旧 App 拒绝未知格式并保留内容。沿用已授权的本地日志扩展，不改旧映射配置。
新目录使用现有 IFileMutationRepository 的公开 CreateFolder v2 及权限/结果核查，
父目录成功后再上传子项；冲突不覆盖，未知目录创建必须用户核对后接纳，不能猜测归属。
范围只含新建与必要恢复接线，不把它替代后续重命名/移动/删除；其他四端不改源码或协议。

已接目录通知、关闭期间本地新建项扫描、普通本地目录的原生占位转换与恢复界面。
子文件先保存独立副本，再按父目录顺序提交；父目录结果未确认时，自动流程与界面
“立即保存”都不能绕过依赖。目录恢复完成会重新扫描该目录并唤醒子项，不要求再编辑
或重启。目录结果明确成功后才自动确认；未知结果只在用户核对归属后接纳，不重发创建。
目录不会被显示成可以导出的空文件。新名称按字面解释，已知 NAS 的 Windows 名称别名
不能被重分类成新建；版本 5 缺操作类型或新建意图表时拒绝读取，不降回旧版本。

新增 12 项测试覆盖新文件、嵌套顺序、同名冲突、未知恢复、父目录权限、父子恢复唤醒、
百分号名称、已有别名、版本 5 与重启扫描。完整 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal：
3809 通过、0 失败、0 跳过。一次 xUnit 分析器失败已按带谓词的 Assert.Single 重载
修正，未放宽断言。CloudFilesNativeChecks --isolated-refresh 验证真实目录转换、
重复确认及非递归清理通过，测试根残留为 0；没有发送真实 NAS 写入。

集成收尾仍需核对新建/写回后的缓存统计与已确认副本的保留策略，未同步/保留本地的
内容不得作为缓存清除。重命名/移动、删除及最终全功能复核/打包继续推进；本片不新增
分发包、不把合成流程当作真实 NAS 或各种编辑器验收。

最终 x64/ARM64 App Release 构建通过，0 警告/错误，继续使用 Platform/runtime、
--no-restore 和 LanStashUiSmoke=false。./windows/tests/UiSmoke/run.ps1
-Scenarios cloud-settings -Language en-US -WindowWidth 1000 -PaneState compact
34 场景通过，输出 ui-review-20260921-145858；中文 -SkipBuild 同形命令 34 通过，
输出 ui-review-20260921-150213。检查英文长确认文案后给滚动条留出间距，并显式保持
未勾选状态；复查图中文字不被滚动条遮挡。3377 个 Windows 资源本地化、111 请求
样本、严格文档和 diff 检查通过。测试及原生检查使用合成资料，不修改用户 NAS。

#### 2026-09-21 写回启用与恢复入口

本片把已验证的保存链路接到云盘管理界面：逐映射确认启用/恢复只读，按权限和已保存
版本准备文件，未决记录支持只读核查、明确确认重试、保留本地与另存副本。重试生成
新请求并重新核对远端，不能重放 Submitted；移除映射必须先处理未同步内容并恢复只读。
采用现有 WinUI 对话框、双语资源和保存选择器，所有默认测试仍为合成数据，不连接 NAS。
不改旧映射配置，不增加第三方依赖；本地副本继续独立保存，不随缓存回收或回退删除。

已接 WinUI“同步与恢复”：每次启用/恢复只读分别确认，展示待处理项及最近 10 条
已处理记录，带副本时间；Submitted 仅核查，Prepared 可保存/保留，冲突、拒绝和
已保留副本可明确确认后重新保存。新请求按新鲜基线重新核查，旧副本保留；同目标
已有另一未决请求时拒绝历史副本重试。另存副本使用既有选择器和临时文件原子替换，
不可覆盖同步日志，也不可导出到云盘内；用户未确认或取消时原目的文件不变。
移除映射前需处理未决内容并恢复只读；保留本地只改只读属性，不伪装已经上传。

文件只有完整下载且身份/版本/权限匹配后才解除只读，避免部分文件被修改后无法完整
捕获；关闭通知补充捕获和准备。新建、目录、重命名/移动和删除仍待完整实现，不把
现有文件编辑入口当成完整云盘目标。开启后的剩余只读项在对话框报告数量和下一步。
PENDING_USER_VALIDATION：真实 NAS 权限/版本、用户编辑器的打开关闭行为、重启与
网络切换；需在专用目录验证，不用上述合成结果代替实机结论。

本轮 6 项新增回归后，全量 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal 为 3797 通过、0 失败、0 跳过；x64/ARM64 App
Release（Platform/runtime、--no-restore、LanStashUiSmoke=false）均 0 警告/错误。
首次编译纠正 StackPanel 无 IsEnabled，改用现有 ContentControl 模式；原生关闭测试
改为等待取消被观测，而不是把 ShowAsync 返回当作异步取消处理已完成，断言保留。
./windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN
-WindowWidth 1000 -PaneState compact：32 通过，输出 ui-review-20260921-134557；
英文以 -SkipBuild -Language en-US 运行同形命令，32 通过，输出 ui-review-20260921-135105。
复核中英浅深色图，表单可滚动，默认按钮不执行写入。CloudFilesNativeChecks
--isolated-refresh 确认保留本地后仍为未同步、恢复只读以及断开后读取完整内容均通过，
测试根残留数为 0。本地化 3366 个 Windows 资源及 111 请求样本检查通过；未打新 Windows 包。

#### 2026-09-21 自动写回运行链路

本片接目录变更捕获、串行提交、未知结果保留和本地完成确认。Mac 参照 ProviderRuntime
写回主流程；Windows 使用 FileSystemWatcher 与已登记的路径/名称、既有同步日志和
上传协调器，不创建第二套 NAS 客户端。已确认保存的记录保留回读版本，只有本地内容
仍与该副本一致时才恢复已同步状态；覆盖保存产生的普通文件使用官方转换 API 恢复
占位身份，不删除内容、不失效缓存。较新修改不标成旧任务已同步，继续独立捕获。
默认只读及确认门不变；新建/目录/重命名/删除与恢复交互仍需独立完整接线，不以本片
已有文件保存替代完整云盘目标。仅用合成目录/Repository 验证，不发送真实 NAS 写入。

已实现 CloudDriveWritebackSession，并由映射连接在已授权的写回记录存在时启动，
断开时取消并等待队列结束。FileSystemWatcher 合并通知，写句柄共享冲突等待关闭，
溢出时重查登记清单；未知提交重启后只核查，冲突/明确失败/保留本地不自动重发。
已确认日志增加回读版本/空文件时间，确认本地状态时仍锁定该基线并比较完整内容；
较新编辑生成下一份独立副本。原生恢复遵循 Microsoft 的
[CfConvertToPlaceholder](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfconverttoplaceholder)
及 [CfSetInSyncState](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfsetinsyncstate)，
没有释放、截断或删除本地文件。新属性兼容读取旧记录，未具备回读基线的旧完成记录
不能直接触发本地确认；独立版本 4 的空文件表及原有回滚保留规则不变。

本轮新增 10 项回归，覆盖普通保存、上传期间新编辑、未知重启、忙碌确认不重传、
空文件后的继续编辑、停机取消、禁用态、版本变更，以及实际目录通知/启动扫描。
完整 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore -v minimal：3791 通过、0 失败、0 跳过；App x64/ARM64 Release 构建
均为 0 警告/错误（Platform/runtime、--no-restore、LanStashUiSmoke=false）。
CloudFilesNativeChecks --isolated-refresh 实测普通替换文件恢复占位、拒绝把较新内容
标成已同步及已有占位状态恢复均通过，合成根清理后残留为 0。本地化、111 请求样本、
严格文档与 diff 检查通过。启用/恢复 UI 和新建/重命名/删除仍未接完，未打新分发包，
不把本队列测试当成真实 NAS 或完整云盘验收。

#### 2026-09-21 编辑前空文件基线与重启捕获

继续已授权的写回持久化扩展：空文件在开放编辑前登记原始远端修改时间，重启后的
捕获从持久记录选择强版本或空文件基线，不从编辑后的本地时间反推。沿用独立日志，
版本 4 增加空文件基线表；旧版本记录可读，旧 App 拒绝未知格式并保留未同步副本。
刷新/远端清理/成功保存同步移除过期基线，不允许悄悄更换基线或降回版本 3。
范围为同步存储、正式回归和原生隔离检查；不改变 NAS API、旧映射配置或其他四端。
自动监听、启用和恢复界面仍需接线，此段不把辅助捕获入口当作功能已交付。

已实现 BindEmptyFileBaselineAsync 与 CaptureMappedSaveAsync，空文件时间与强版本互斥，
重复登记相同值幂等，不同值拒绝；版本 4 缺少基线表则拒绝读取，不清空损坏记录。
新增 7 项回归覆盖重启捕获、无基线拒绝、强版本捕获、冲突、损坏表及刷新/清理。
实际 dotnet test 的 DesktopCloudDrive 聚焦 143 通过；同项目 Release --no-restore
全量 3781 通过、0 失败、0 跳过。首次编译发现局部变量重名，修正后通过，未放宽断言。
CloudFilesNativeChecks --isolated-refresh 通过，实际先保存基线、开放编辑、写入合成
内容，再由新存储实例捕获；生成根和日志清理后残留数为 0，没有连接 NAS。
App Release x64/win-x64、arm64/win-arm64 构建均通过，0 警告/错误，使用
--no-restore -p:LanStashUiSmoke=false。本地化、111 个请求样本、严格文档和 diff
检查通过。本轮未打包、未改 UI，也不将这些测试当作自动写回或真实 NAS 验收。

#### 2026-09-21 原生可编辑状态与捕获准备

本片先验证并接入原生只读/可编辑切换，必须保持文件大小和内容状态，不用默认大小 0
调用元数据更新。使用同一个独占句柄读取标准/基本信息再更新属性，身份或未同步状态
不符则拒绝；不修改 ACL。写回仍需显式确认、稳定基线及后续变更捕获/恢复 UI，不能
仅清除只读属性就称功能可用。隔离测试只作用于新生成的同步根，不连接 NAS。

已补 FileStandardInfo/FileBasicInfo 原生读取与 SetWritable：在排他句柄内先读真实大小，
再通过 CfUpdatePlaceholder 更改只读位；仍验证占位身份和未修改状态，不修改 ACL。
真实隔离 API 检查证明启用/恢复只读均未截断文件。新增已登记路径的快照入口，按
持久名称映射重建本地目标，并验证父级重解析点；没有原基线不能把旧文件猜成新建。
占位内容先用属性句柄确认完整落地且有修改，再以拒绝并行写入的句柄冻结副本。

实测还发现 File.WriteAllText 的覆盖保存会把空占位变成普通文件：初版按占位读身份
返回 ERROR_NOT_A_CLOUD_FILE，并在清理时遇到相同错误。现区分原位占位修改和已登记
路径内的普通替换文件，后者也需路径匹配、基线和关闭写句柄；任意重解析点不接受。
隔离检查已成功将这类真实保存后的内容冻结到独立副本；清理支持自身生成的普通文件，
失败残留及最终测试根均已删除，残留查询为零。没有读取生产配置或连接 NAS。

新增捕获回归覆盖不可变副本、映射外同名文件、未登记名字、仍在写入、禁用写回和
缺原始基线。此处仅完成原生/捕获适配，不代表自动关闭事件、启用确认、冲突恢复等
页面已接入；尚未产生新分发包，也没有给用户开放不完整写回入口。

验证：CloudFilesNativeChecks 的 --isolated-refresh 通过；全量 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
最终 3774 通过、0 失败、0 跳过。App x64/ARM64 Release 构建均通过，0 警告/错误，
沿用 Platform/runtime、--no-restore、LanStashUiSmoke=false。本地化、请求契约、
严格文档及 diff 检查通过；实际 Win32 隔离测试不代替 NAS 写回或用户编辑器兼容验收。

#### 2026-09-21 写回空文件与特殊路径边界

继续已授权的写回记录扩展：原有空文件用明确的修改时间基线与“新文件”区分，不伪造
ETag；相应待办为版本 3，旧版本拒绝改写、内容副本保留，版本 1/2 仍可读取。
复用 getinfo v2 增加 Windows 只读元数据结果，按选定目录及祖先逐项核对链接和挂载
类型，目标也需核查。其他四端无协议/格式迁移，Mac 已有类似路径限制作为参考。
本片不启用原生写回入口、不进行真实 NAS 写入；当前目标仍包含后续捕获与恢复交互。

已在现有 getinfo 适配内复用严格单项解析，新增 FileEntryMetadata（名称/类型/大小/
时间/权限和链接/挂载标记）。写回核查从直接父目录到共享根的全部祖先；特殊挂载、
链接或所需标记不完整时不写，叶子路径也必须一致。回读阶段重新检查边界，不把提交
后路径变更当作确认成功。新接口默认不支持，不让旧 Repository 伪造元数据。

待办增加 EmptyBaseModifiedAt：只有原有空文件使用该基线，上传仍使用覆盖语义，
新文件继续要求不存在；大小或时间变化即冲突。版本 3 的待办缺失该字段时拒绝读取，
不能降格成新文件操作；名称映射后续更新也不得把版本 3 降回 2。空文件原始状态的
实际捕获仍由后续原生接线负责，这里只接受已冻结输入，不凭本地修改后的时间猜测。

新增 11 项回归后，全量 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal`：3768 通过、0 失败、0 跳过。首轮测试夹具元组
字段名丢失导致编译失败，已明确命名；JSON 原始解析曾改变损坏输入的异常子类型，
现继续使用 Serializer 包装并保留旧断言，损坏记录仍拒绝且不覆写。
x64/ARM64 App Release 构建均通过（Platform/runtime、--no-restore、LanStashUiSmoke=false），
0 警告/错误；本地化、请求 fixture、严格文档与 diff 检查通过。未改 UI、未打新包，
不把模拟写回当真实 NAS 或资源管理器验收；仍需捕获、启用确认及恢复交互。

#### 2026-09-21 云盘写回提交与核查核心

基线为 Mac ProviderRuntime 的保存/冲突/未知核查流程；先接现有文件内容及新文件保存，
后接原生变更捕获、明确启用和恢复界面，不把内核编排当作写回入口已经可用。
复用 IDsmRepository 上传与范围读取，不增加 NAS API。每次保存使用不可变本地副本，
提交前核对父目录和目标权限、原强版本；新文件要求明确不存在，已有文件只在原版本
仍匹配时提交。File Station 没有在此记录原子条件覆盖契约，不冒充跨设备事务锁；
与 Mac 一样，提交前检查和提交后核查分别记录，竞争冲突不自动强制覆盖。
收到成功回执后仍按稳定版本读完整内容比对 SHA256；未知提交只读核查，不再次上传。
此次无真实 NAS 写入，其他四端源码/契约不改，应用入口仍待完整接线后按用户确认启用。

已实现 CloudDriveWritebackCoordinator，复用现有上传请求和严格分页/范围读取；同挂载
以独立 upload.lock 串行化上传/核查，不持有普通读写日志锁等待网络。提交前读取目录
权限与当前内容版本，新文件还要求精确不存在。冻结副本打开期间禁止外部写/删除，
SHA256 核对后先将 Submitted 落盘；只有该调用可发送一次上传。未知结果及进程恢复
只读核查，明确失败进入 Rejected，不因远端碰巧有同内容就改报成功；已确认、冲突、
保留本地与拒绝状态不重放。回读按有界块核对稳定版本及完整 SHA256，空的新文件不
制造 HTTP ETag；回收站路径拒绝准备。未知上传仍保留本地副本与待办。

新增 12 项回归覆盖新/旧文件保存、版本变化、新文件同名冲突、权限拒绝、回执丢失、
成功回执但内容错误、明确失败、空文件创建、并发两协调器、回收路径和异 NAS 配置。
云盘首轮聚焦 120 通过，追加回收站保护后全量 3757 通过、0 失败、0 跳过。
实际命令为 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore -v minimal`；本地化、严格文档与 diff 检查通过。目标 App x64/ARM64
Release 构建均通过，0 警告/0 错误（-p:Platform、-r win-*、--no-restore、LanStashUiSmoke=false）。
本轮没有新分发包或原生写入入口，不把模拟 Repository 的上传叫作真实 NAS 写回通过。

后续必需项仍保留：原始空文件的存在/时间基线、根与祖先目录的链接/挂载边界核查，
以及原生变更捕获、启用确认、冲突/失败恢复和本地副本导出。仅有父目录可写布尔值
不能完成这些边界；在它们接通前不通过用户界面启用写回。其他 Mac 修复整体构建仍待做。

#### 2026-09-21 远端移除后的受控本地清理

本片只同步远端已移除的投影，不发送 NAS 删除请求。精确 getinfo/408 证据、同一挂载
和目录范围、日志无未决写、原生身份/IN_SYNC/无本地修改共同决定可清理；固定离线
内容保留。原生删除仅针对独占打开的单个句柄，目录非空由系统拒绝，不递归清理。
删除回调只接受同进程、同文件/同步根/身份且具有一次性授权的内部清理，普通资源
管理器删除继续拒绝。需在隔离同步根验证回调，不能只凭编译放开。其他四端/API不变。

生产刷新已接：完整目录差异只生成候选，再对每个候选单独读取 getinfo 的明确缺失，
自深向浅处理；本地祖先须是本映射占位，固定离线偏好、未同步状态和未决写任一存在
即保留。删除使用 DELETE/READ_ATTRIBUTES 独占句柄及 FileDispositionInfoEx，不申请
READ_DATA、不下载远端已删除内容；目录只能删除空目录。成功后清理版本、路径索引和
缓存统计，保留名称分配与本地内容副本。界面分开显示更新/移除/保留/未完成数量。
远端重命名按新路径发现与旧路径移除处理，不猜测稳定远端身份。

原生隔离检查发现提供者自身的删除不能用于检验普通进程拦截：初版同进程否定断言
失败；额外 READ_DATA 还可能触发隐式下载。改用独立子进程验证，外部删除回调确实拒绝，
内部清理完成；保留固定/未同步项、删除已同步空目录也已通过真实 Cloud Files API。
测试清理最初遇到未运行提供者/回退占位超时；已用带合成数据回调的专用清理恢复，
全部仅处理生成的测试根，失败残留已清理。测试程序现需目录随机标记，并在子进程
超时时终止自己的子进程；没有放宽生产保护或接触用户 NAS/映射数据。

新增 7 项单元回归覆盖同进程/根/文件/身份/单次授权、未决写阻断自身及祖先清理、
失败不清版本、成功保留名称和映射根禁止清理；云盘聚焦 109 通过，全量 3745 通过、
0 失败/0 跳过。中文原生 21 场景通过（ui-review-20260921-112006），新增移除/保留
反馈；英文与最终包收尾。实际命令沿用 dotnet test、CloudFilesNativeChecks 的
--isolated-refresh，以及 UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN
-WindowWidth 900 -WindowHeight 740，英文使用 en-US 与 -SkipBuild。

最终英文 21 场景通过（ui-review-20260921-112335），双语 42 份引用截图完整，已查看
保留/移除反馈。`windows/package.ps1` 使用既定非交互 both、RUN_TESTS=1、
LAUNCH_AFTER=0 完成，包内全量 3745 通过；x64/ARM64 Release 自包含 publish 均成功。
目录 `windows/dist/20260921-112345`，未安装/启动；build-info 的架构、自包含、
testsRun=true 及无测试宿主/工具已核对，SHA256/sidecar 一致：

- x64：`93105E2808F2F0C73BFB9392B8F208DCC6610E389A73E48FE98318B6BE224784`。
- ARM64：`B6D78D0FDA94532227D5B3EC8366AC4DBAA1B62260B31B59E797D873BD16E08E`。

本地化、严格文档与 diff 检查通过，测试目录/标记残留查询为零。真实 NAS 端到端仍为
PENDING_USER_VALIDATION：仅用合成目录检查远端删除/改名后刷新，确认旧在线占位清理、
固定离线/本地修改保留，以及权限拒绝不触发清理；不要先用重要文件测试。目录非空
或证据不足会报告保留/未完成，不能以“同步成功”掩盖。云盘修改写回/恢复和其他 Mac
修复整体构建仍在原目标内；本波没有 NAS 删除请求、提交或推送。

#### 2026-09-21 目录同步的稳定本地名称

源码复核确认每次 RegisterPathsAsync 都重新计算所有名称；NAS 新增仅大小写不同的
文件时，已有别名会变化，重启后也无法定位旧占位。先将名称映射纳入已授权的独立
同步记录，再接新增目录条目，不能为“新增成功”覆盖或改名用户已有文件。
记录增量升级为版本 2：版本 1 可读、无名称时沿用旧规则导入，已有名称永不重分配；
新碰撞分配稳定后缀。旧测试包拒绝版本 2，不改写或清理其记录/待同步内容；旧 NAS
映射配置文件保持不变。仅 Windows 本地元数据变化，其他四端与 NAS API 不变。

已接到生产连接初始化和 RegisterPathsAsync：新路径先获得持久名称，再发布到现有
路径注册表；既有名字不因后续新增条目重算。碰撞按父目录分别分配，过长转义名缩短
并保留常用扩展名。版本 2 缺名称字段或同目录别名冲突拒绝读取，不静默生成新名字。
名称登记按父目录维护集合，避免大目录逐项重新扫描已有名字。

“刷新文件”现在先读取根目录和已浏览目录的完整列表，登记并创建新增文件/目录占位，
再刷新原有文件内容。新目录保持按需加载，不递归扫描整个 NAS；已有普通本地文件、
类型冲突或身份不匹配不覆盖，失败父目录不继续写其子树。重新创建空占位后清除旧
内容版本，但有未决写时拒绝。CfCreatePlaceholders 同时检查每项结果，不只看处理数。
远端移除/重命名旧条目仍保守保留并报告未完成，相关清理尚未接入。

新增名称存储 7 项回归通过，覆盖版本 1 迁移保留待同步副本、重启后同名映射、不同父
目录、长名称、设备保留名、损坏版本 2 和 5000 条目录后续新增；云盘聚焦 102 通过。
全量 3738 通过、0 失败/0 跳过。扩展 `CloudFilesNativeChecks --isolated-refresh`
再次在临时同步根验证真实大小写冲突占位、旧名保留和重启后按身份读取，原生检查通过；
测试根及独立同步记录已清理，未接 NAS、未碰用户映射配置。本地化/文档/diff 检查通过。
分发包按既定脚本收尾，不能把此前 101436 包称为包含本次新增目录接线。

最终 `windows/package.ps1`（LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0）完成，内部全量仍为 3738 通过，
x64/ARM64 自包含 Release publish 成功。目录 `windows/dist/20260921-104939`，未安装
或启动；归档 testsRun、架构、自包含、无测试工具及 SHA256/sidecar 一致均已核对：

- x64：`C83A057E1154F3E5AB36CBC996F89DA61361C5F4DAEB4698F8815356696D1A78`。
- ARM64：`63224C4E1B311A8B5D21236CD1C5429865C29FFE9D07602034D1487A5A0F0FCF`。

PENDING_USER_VALIDATION：在专用 NAS 目录新增普通文件/目录，再在云盘页刷新；新增目录
应可按需打开。另核对大小写冲突名称、重启后定位和本地普通文件冲突保留。未修改 UI，
本片没有重跑原生页面场景；隔离系统测试与 App/NAS 联调不混称。远端移除清理及写回
仍待实现，记录版本 2 的回退保护不是这些功能已完成的证据。

#### 2026-09-21 云盘目录同步的存在性证据

目录增删不能仅凭列表缺项删除本地占位。先复用已记录的公开 File Station List v2
getinfo，按精确路径读取存在性，只有该项明确 code=408 才是不存在；权限、认证、
空数组、错路径、格式错误或网络失败都不是缺失证明。Windows IDsmRepository 增加
默认不支持的只读方法，不改变现有实现构造或持久化；用户既有兼容接口增量授权适用。
Apple/macOS 对应单项缺失处理见 API 参考中 getinfo 段落，其他四端不改代码或契约。
本片限定读取适配、目录差异计划及必要回归，不在缺少证据时开放删除，也不碰真实数据。

真实 HTTP 合成测试先复现 17 项失败：CallReadJsonObjectAsync 的方法白名单不接受
getinfo，已有回收与解压目标核查也使用这个入口。已仅为 SYNO.FileStation.List v2、
精确 path 数组和官方 additional 字段开放 FORM/JSON 读取；未允许任意 API/版本的
getinfo，也未放开写方法、保留参数或 URL 凭据。新存在性入口只有精确单项 408 返回
Missing，全局错误、空列表和不匹配路径继续失败；不把这些失败作为本地删除依据。

同一复核又确认 Windows 权限解析只读 perm.write/delete，与已记录的 ACL 和 Mac
makeFileItem 不符。已用一处 FileStationPermissions 解析统一浏览、变更预检、回收、
压缩/解压与共享目标核查：明确 ACL 模式优先 acl.read/write/del，其次按 Mac 基线使用
adv_right（read/download、write/upload、delete）；false 不被其他 true 覆盖，缺失
写/删除权限不授权。旧直接布尔结构保留，但不能在明确 ACL 模式缺权时扩大授权。
畸形布尔/权限对象仍失败，不放宽确认、重复保护或结果核查。此为原始“所有功能同类
API 问题”中的依赖修复，目录增删的原生动作尚未接入，不能提前称同步完成。

新增 FilePresenceTests 与 FileStationPermissionTests 通过真实 DsmApiClient/HTTP 编码
验证以上分支：38 项聚焦通过；覆盖路径转义、固定版本、FORM/JSON、单项/全局错误
区别、额外参数拒绝、ACL/adv_right/旧直接字段、拒绝优先与畸形类型。原有全量先为
3711 通过，补齐新权限/方法门回归后最终 3731 通过、0 失败、0 跳过；没有删旧断言。
本片没有 UI 修改，未用旧原生截图冒充新版完整交互实测，真实 NAS 操作仍待用户验收。

`windows/package.ps1`（LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0）完成，包内全量 3731 通过，
x64/ARM64 Release 自包含 publish 成功。目录 `windows/dist/20260921-101436`，
未安装/启动；build-info 的架构、testsRun=true、自包含状态及无合成宿主已复核。
两包 SHA256 与 sidecar 一致：

- x64：`091A41E2FA42C72448A81EACEEAD879747CDAB2F732642E7C90F1CA4B888B8CA`。
- ARM64：`B02FF995F5995EAF2CA67C168282C8847FD7AF8549AC9BF98600A2B6AD30E26D`。

本地化、111 请求 fixture、响应 fixture/私有引用、严格文档与 diff 检查通过。
五端无 API 格式迁移；Windows 只读接口以默认不支持保持旧实现兼容。其他四端使用
原有已记录权限语义，源码未改；本地 main 的既有改动保留，无提交或推送。

#### 2026-09-21 云盘原生刷新接线与隔离接口验证

先用独立生成的测试同步根核对 CfUpdatePlaceholder 的真实权限与状态行为，不触碰
生产映射配置或 NAS。原生适配沿用 CloudFilesInterop；读取占位身份集中复用，更新
必须短时独占并验证 IN_SYNC/无本地修改，不能通过清除只读属性或更改 ACL 取得权限。
WRITE_DAC 仅作为打开自己占位文件的句柄权限满足官方更新接口，不实际修改 DACL。
刷新事务成功后才发布版本；固定离线偏好需恢复。正式脚本/回归源码保留，生成的
临时同步根在验证结束注销并清理；真实 NAS 刷新/后台改动仍与此隔离测试分开记录。

已完成生产调用链：云盘页每个映射新增“刷新文件”，经 AppViewModel/现有服务调用
CloudDriveRemoteRefresh，父目录完整分页核查后读取强版本；逐文件与下载共用互斥，
在短时独占 READ_DATA + READ_ATTRIBUTES + WRITE_DAC 句柄内验证身份、IN_SYNC 和
未修改状态，调用 CfUpdatePlaceholder 后才发布版本。没有移除只读属性、更改 ACL 或
调用 NAS 写接口。固定离线文件暂时取消固定后更新，finally 恢复偏好，版本落盘后
再获取完整内容；同版本但上次取消造成离线内容缺失，也会重新获取。
取消/离页/断开均停止后续项；当前事务退出后再释放运行时。失败逐项汇总，不自动
删除远端已移除或类型改变的本地条目；该类情况仍报告未完成，目录增删同步另续。

页面增加英中结果/部分完成/取消/空映射下一步提示，取消按钮随进度出现并滚动到
可见区域；没有重复提交或离页迟到反馈。离线但未手动暂停的映射现在提供“继续”
恢复入口，而非只显示“暂停”；实际未连接时不假装能刷新。原生页面的测试动作通过
现有页面构造注入隔离动作，正式构造始终绑定 AppViewModel 生产流程，不用测试假实现
替换生产 Repository。只有已浏览到的文件进入这次内容刷新，不声称完整后台目录同步。

`dotnet run --project windows/tests/CloudFilesNativeChecks/CloudFilesNativeChecks.csproj -c
Release -- --isolated-refresh` 在本机真实 Cloud Files API 上通过：创建测试占位、只读
更新/属性保留、错误身份拒绝、正在读取时独占拒绝、固定偏好恢复、同版本缺少离线
内容要求补齐、未同步文件拒绝且大小不变。未连接 NAS；测试根已注销且目录查询为零。
扩展夹具最初用更短的错误身份触发 ERROR_MORE_DATA，改成同长不同值来验证身份比较，
生产拒绝未放宽。首次大补丁因定位失败未写入，重新核对后按明确成员锚点应用。

单元聚焦云盘 95 通过；新增页面生产接线断言后全量 3693 通过、0 失败/0 跳过。
中文/英文首轮各 18 原生场景通过；补断线恢复可达性与截图滚动后，最终中文 19 场景
通过（ui-review-20260921-094617），英文和最终分发包收尾。正式命令沿用
`windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language zh-CN -WindowWidth 900
-WindowHeight 740`，英文 en-US 使用 -SkipBuild。生产界面与合成动作验证、隔离原生
接口验证、真实 NAS App 验收分别记录，不相互替代。

最终英文同组 19 场景通过（ui-review-20260921-094857）；双语 38 个引用截图完整。
检查浅深色刷新按钮和部分完成截图，确认可滚动到实际操作/反馈位置，未用空白首屏
冒充结果绘制。此前 18 场景报告保留为中间证据，最终以 19 场景版本为准。
`windows/package.ps1` 以 NON_INTERACTIVE=1、TARGET_PLATFORM=both、RUN_TESTS=1、
LAUNCH_AFTER=0（均 LANSTASH_ 前缀）完成，内含 3693 通过、0 失败/0 跳过与双架构
自包含 Release publish。最终目录 `windows/dist/20260921-094813`，未安装/启动，
归档的 testsRun/架构、自包含信息和无测试宿主/原生检查工具均已核对，SHA256 与 sidecar 一致：

- x64：`39EBA2139B16282C5E28F0CC09C2AD56741A4161589231DCC08AFD3B785C7809`。
- ARM64：`B82EF8E242D71449A24DCC62B656CA4CF0ACD188321B65F2E39A48536E8D986D`。

本地化资源、请求契约、严格文档与 diff 检查通过。PENDING_USER_VALIDATION：用户在
专用合成目录修改已浏览的 NAS 文件后选择“刷新文件”，核对文件内容/大小、取消、
固定离线补齐及占用冲突；本地未同步修改不得被覆盖。原生隔离测试不替代整个 App 的
NAS 端到端验证。源码后续仍包括修改写回/恢复和远端目录增删/重命名同步，以及其他
Mac 修复整体构建；不将安全保留失踪条目并报告失败说成目录同步已经完成。

#### 2026-09-21 云盘远端刷新事务

本片先补版本切换事务与远端内容核查，再接原生更新和页面；不能直接覆写旧版本记录。
依据 Microsoft CfUpdatePlaceholder 文档，失效缓存时必须独占句柄，并使用
VERIFY_IN_SYNC 拒绝本地已改文件；页数据失效失败不得留下混合内容。当前只做现有
SyncStore 的条件替换和读取协调器/回归，不修改 NAS 文件、不删除本地未同步副本。
新版本须与既有文件列表大小及真实 range 响应相符；空文件按明确 size=0 更新元数据，
不伪造服务器 ETag。旧版本匹配和无未决写检查在同一个持久化锁内完成，本地更新成功
后才发布新版本；更新/落盘异常保留可重试的旧记录，不让读取拼接未确认的新版本。
无持久化格式迁移或五端 API 变化；后续原生/页面接线仍在目标内，不以核心测试冒充完成。
参考：https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfupdateplaceholder 。

已实现现有 SyncStore 的条件版本替换与 CloudDriveRemoteRefresh：网络探测前冻结旧
版本，1 字节 Range 必须匹配列表总大小、范围和强 ETag，空文件不伪造版本；原生操作
回调成功后才原子发布新记录。本地更新失败/取消仍保留旧记录，可重新核查；未决保存
（准备/提交/冲突）阻止失效，本地内容副本不删除。同版本只请求元数据更新，不要求
无谓清空缓存；期间另一次刷新改了基线则拒绝旧请求。仍未接 CfUpdatePlaceholder 和
UI，不称完整刷新已完成，也没有对真实占位文件执行失效操作。

独立并发复核补充：同进程多实例持久化访问改为每挂载异步排队，保留 OS 跨进程独占
锁。否则刷新持锁时正常并发读取会被误报为 I/O 失败；新增在途刷新/读取确定性回归，
确认读取等待原生步骤及版本发布后得到新值。没有等待期限抢锁或未知 NAS 写重放。
测试夹具首轮 public 方法使用 internal 枚举触发 CS0051，改为整数入参后恢复编译，
未改变生产类型可见性。聚焦 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore --filter FullyQualifiedName~DesktopCloudDrive -v minimal`：88 通过；
全量去掉 filter：3685 通过、0 失败、0 跳过。x64/ARM64 的 App Release 构建均通过，
命令沿用 -p:Platform、-r win-*、--no-restore、-p:LanStashUiSmoke=false，均 0 警告/错误。
本地化、严格文档、差异检查通过；无 UI 改动、无新分发包，未对 NAS 或用户文件写入。

后续原生接线须实测只读占位文件下的独占更新权限，不能单凭 P/Invoke 编译宣布可用。
原生写入采用 VERIFY_IN_SYNC 与身份/本地修改检查；固定离线文件的偏好必须保留，
失效后需重新获取内容。页面提供显式刷新与取消/失败恢复，之后继续修改写回与恢复 UI。

#### 2026-09-21 Mac 下载与照片修复云端交付

授权的独立分支 codex/macos-download-validation 测试提交为
51aeac4d6c46d8046f9f9ca628246f085f879618；Apple Build run 35548658262 已完成 success，
文档预检与 Repository Check 同样通过。范围仅为原始文件下载、照片保存/删除修复及
必要测试和资源（11 个文件）；本地主工作区其他 Mac 同类 API 修复未并入，不外推验收。

真实日志：`swift test --package-path apple` 共 1074 项、0 失败、57 跳过（1017 通过）；
跳过项包括可选性能基准、需真实 QuickConnect 的测试和未配置输出目录的合成 UI，
没有把跳过算通过。iPhone/iPad 既定工作流各执行 497 项，0 失败；这里只是该提交的
兼容回归，不代表本轮为移动端增加功能。macOS arm64 Release 临时签名打包及
`verify_macos_unsigned_ci_artifact.sh` 均通过；正式签名、公证和实际 NAS 用户反馈另验。

已取回 artifact 10617762316（LanStash-macOS，30139762 字节），本机 ZIP SHA256
与 GitHub 公布 digest 一致：DC235CAD586BA15804533B1203B1E78DE40B1688C3CC7C7AFE7A92085E96B2AA。
保留目录 `apple/Apps/DsmMac/dist/github-download-photo-20260921/`（gitignored），其中
`LanStash-1.0.9-arm64.dmg` SHA256 为
085B5F8E5FB1DFD9EB636F7E4C482CF59BC994D8E37F8A545669554531E8E52E。
ZIP 原件保留，Windows 只提取 DMG、不重打包 .app，避免损坏 Mac 文件权限/符号链接。
没有安装或启动；适用于 Apple 芯片，沿用临时签名测试包流程，不包含本地磁盘挂载扩展。

用户要求的清理已完成：结果取回后删除 GitHub 和本地同名测试分支，并移除干净的
专用 worktree。远端/本地分支查询均为空，当前仍为 main。测试提交的全部源码/测试
用反向补丁 --check 验证仍在主工作区，两个语言资源按新增键逐项对比相同（主文件还含
其他修复，不能要求整个资源文件与局部测试分支相同）；未回退、提交或推送 main。
可从保留测试包/CI 记录和当前 main 源码继续核查，不保留一次性下载 URL 或原始日志。

PENDING_USER_VALIDATION：在 Mac 用独立测试包确认单文件、文件夹/批量下载，照片保存
与面板确认替换，以及专用合成照片删除/权限失败恢复；不要先用真实重要照片验证删除。
回传芯片/系统类别、操作步骤和脱敏错误，勿附 NAS 凭据、地址或真实路径。本包不能验证
Finder/File Provider，本轮也尚未生成包含所有其他 Mac API 修复的整体包。

#### 2026-09-21 云盘分段读取接线

本片复用已授权的版本存储，修改现有 CloudFileRangeTransfer、MappingRuntime 与
CloudFilesInterop 及对应回归，不另建网络实现。按 Microsoft CfGetPlaceholderInfo 的
STANDARD 信息核对文件/同步根身份、本地修改与已有数据；没有版本的旧本地数据不与
新内容拼接。成功读取强版本后须先落盘，再交付有界块；跨回调/进程重启继续带原版本，
版本或长度变化拒绝，不静默重绑定。旧记录缺失/损坏不视作未下载。只读入口不改成写回。
参考：https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfgetplaceholderinfo
及 https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ns-cfapi-cf_operation_parameters 。
该官方接口允许同次回调多次 TRANSFER_DATA，要求 4 KiB 对齐（文件末尾长度例外）。
无 NAS API/五端共享契约变化，不改身份/权限/最低系统；系统回调实测单列待验。

已接同一个生产 FETCH_DATA 路径：加载持久化版本，核对原生占位身份与修改状态，
按 4 KiB 对齐范围读取；首块前原子绑定强版本，此后按既有 4 MiB 请求块交付，不再
要求整文件落入 64 MiB 内存缓冲。缺持久化回调仍拒绝，不保留另一套不安全传输。
已交付的正确版本块不在后续失败中重复报失败；版本/长度变更、取消、原生提交异常
只终止尚未交付范围。原有无存储拒绝断言保留，版本变化测试改为准确核查分块终态，
不是删去错误保护。新增真实本地存储合成回归覆盖跨实例续读和 129 MiB 完整读取。

聚焦 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore
--filter FullyQualifiedName~DesktopCloudDrive -v minimal`：71 通过；同命令移除 filter
全量 3668 通过、0 失败、0 跳过。首轮旧成功夹具缺持久化回调导致 2 项失败，已按新
必需边界接入测试存储回调，并保留专门的缺回调负例；不是把生产异常转为静默成功。
独立复核：原生 STRUCT 固定前缀偏移、同一文件/同步根身份、未知旧字节、修改数据、
日志落盘先于系统交付、强版本跨重启、防溢出对齐、取消与一次失败终态均有合成证据。
真实系统读取仍待验。云盘尚缺远端文件变更后的元数据/版本刷新，以及写回编排和
恢复 UI，不能把静态版本下的大文件读取当成整个云盘完成；Mac 云端已进入打包步骤。

最终 x64/ARM64 `dotnet build`（Release、目标 Platform/runtime、--no-restore、
LanStashUiSmoke=false）均 0 警告/0 错误。`windows/package.ps1` 使用
LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=1、
LANSTASH_LAUNCH_AFTER=0 成功，内部全量仍为 3668 通过；未安装、启动或注册云盘。
产物 `windows/dist/20260921-090012` 双架构自包含 Release，testsRun=true；ZIP
架构/构建信息、无合成测试标记、SHA256/sidecar 一致均已复验：

- x64：`D9A25BAE634D96C23CD952CFC7D961C8BABF59D2190F9576C5906C4A4E1EF7EA`。
- ARM64：`768990D60CD6A909C1EA632002A6DC87BDEE2A696A3AFCC1A6A58F32BB7F6F0C`。

PENDING_USER_VALIDATION：用专用合成文件目录启用现有“本次只读测试”入口，核对大于
64 MiB 文件读取/跳读及退出重连；版本变更或本地修改不能拼接返回。旧有缓存无版本时
应拒绝混读，不自动清除用户本地内容；确认为只读下载缓存后才通过现有释放空间入口
重新获取。回传仅平台/步骤/脱敏失败，不提供主机、路径或数据。远端变更自动刷新和
写回仍是源码后续项，不能借本标签后置。此波无 UI 改动，未冒称重跑全部原生场景。

#### 2026-09-21 已授权云盘持久化实施

用户已明确同意新增本地版本记录和待同步日志，保持旧配置兼容、默认只读、回退保留
未同步内容；不再等待该项批准。基线为 Mac DesktopDriveWritebackStore/ProviderRuntime。
按“独立持久化与回归 → 跨回调安全读取 → 修改写回/恢复及原生入口 → 构建/用户验收”
依赖顺序推进；不把仅有存储层称为云盘功能完成。本切片单一范围为 Windows 既有
CloudDrive 目录内的持久化组件、正式测试及账本；不改旧映射 JSON、平台标识或 NAS API。
记录绑定 NAS 配置、挂载、目标路径和内容版本；写前落盘、提交未知不自动重放，
未同步副本与可回收下载缓存分离。系统读写入口在完整编排接通前仍保持现有保护。
五端影响只涉及 Windows 本地结构，Apple/Android 无迁移；真实数据不用于测试。

存储首片已实现 DesktopCloudDriveSyncStore（独立 desktop-drive-sync-v1，不改旧映射文件）：
NAS/挂载/目录绑定、强版本不可静默替换、每挂载独占 OS 文件锁、原子刷新日志；
保存前复制独立内容并记录 SHA256/长度。同一请求编号只认首份副本，Prepared 在网络
提交前持久化为 Submitted，重启后不能重放；内容被改动拒绝提交，冲突/保留本地需明确
状态转换，未知提交不能直接放弃。关闭写回须无未决项，保留本地或已确认的副本不自动删除。
尚未接入资源管理器回调、上传编排或页面，旧 64 MiB/只读边界仍在，不称为云盘已完成。

`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore
--filter FullyQualifiedName~DesktopCloudDriveSyncStoreTests -v minimal`：首轮 20 通过；
后续补日志缺失/提交阶段缺失两项防重放回归，全量同命令去掉 filter：3655 通过、0 失败、0 跳过。覆盖跨实例重启、身份/版本冲突、
取消、篡改副本、提交防重、未知记录版本/损坏拒绝覆写、旧配置不变与独占锁。
本地化、严格文档、diff 检查通过；本波未生成新的 Windows 分发包。
最终 `dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release
-p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal` 及对应
arm64/win-arm64 均通过，0 警告、0 错误；未安装或注册云盘。

用户另行批准专用 codex/ 分支提交、推送和 GitHub 构建，并要求测试结束删除本地/远端
测试分支，代码留在本地主工作区 main。为避免夹带其他改动，先单独验证原始用户问题：
文件下载、照片保存与删除，测试提交 51aeac4d6c46d8046f9f9ca628246f085f879618，
分支 codex/macos-download-validation，独立 worktree 名 macos-download-validation。
仅含相关 11 个 Apple 源码/测试/双语资源，不含 Windows、其他 Mac 修复、用户配置或凭据。
Apple Build run 35548658262 已启动；文档预检与 Repository Check 已通过，Swift
测试步骤已通过，后续回归及测试包仍待运行完成。该工作流的 swift test --package-path apple 同时覆盖
DsmMacTests；本次包不能代替其他尚未纳入分支的 Mac 同类修复验收。
未推送 main、未开 PR、未触发正式发布；分支清理须在结果取回/修复同步之后执行。

#### 2026-09-21 全量整合复核与重新发现的云盘缺口

本次是完成审计，不因现有测试绿色推断所有业务已对齐。正式路由以 ShellPage 为准，
照片使用 Views/Photos/SynologyPhotosPage，不以遗留 PhotosPage 作为生产证据。
源码核对 macOS WorkspaceModel、ChatWorkspaceModel、ServiceManagementModel、
NasAdministrationModel，以及 Windows 对应页面、专用工作流和测试覆盖。
单一修改范围为本账本、状态页和平台矩阵；不修改运行中的系统注册或用户配置。

上次工具连接超时后没有重启回归。本次确认宿主已退出，原报告
`windows/dist/ui-review-20260921-021153/results.json` 已包含完整结果。
实际命令为 `windows/tests/UiSmoke/run.ps1 -SkipBuild -ContinueOnFailure -Language zh-CN`，
1280×820；脚本当前声明 925 个场景，与报告逐个 scenario/theme/state 对比无差异，
925 通过、0 失败，925 个报告引用图像均存在。这是中文全量，不是英文全量或 NAS 实测。
抽查正式 Photos 正常/错误态图，错误态不再误导用户添加照片；合成缩略图不证明真实解码。

| 复核领域 | 当前可复核入口与证据 | 本次结论 |
| --- | --- | --- |
| 文件及传输 | FilesPage 各操作 partial；复制/移动、回收恢复、上传下载、压缩解压、收藏及挂载专用原生场景 | 925 中包含主流程及取消/未知恢复；真实文件、跨 NAS 和系统选择器仍另验。 |
| Photos | ShellPage → SynologyPhotosPage；Media 的保存/个人单项删除和能力确认；6 个原生场景及 Synology 聚焦回归 | 原故障同类修复有源码/合成证据，不能证明全部真实媒体行为。 |
| Chat | ChatPage 的成员/附件/公告/高级工具与 ChatActions/ChatAdvanced；chat 与 chat-tools | 提醒、定时、投票等已接入，矩阵旧“后续”标签应改为受限已实现范围。 |
| Download Station | DownloadStationPage 的 Settings、Batch、CreateFile 与 BT 搜索；设置/批次/创建选项场景 | 设置和批量不是未实现项；不凭“高级管理”总称声称 RSS 等未确认能力已实现。 |
| Container / VMM | 正式管理页面的独立确认/恢复窗口；生命周期、映像、网络、创建、设置、控制台、任务场景 | 本轮既有实现进入完整原生回归，不以页面存在替代写回读测试。 |
| NAS 管理 | NasDetailsPage.ServiceSettings → 各专用窗口与 Repository；16 类 nas-* 原生场景 | 电源计划、外接存储、内存压缩遵循 Mac 只读基线；其他专用操作的 CanSave=false 不等于行内按钮禁用。 |
| 托盘与通知 | MainWindow 注入真实通知服务，ShellPage 交给传输协调器；tray/notification/transfer 生命周期场景 | Null 服务为未注入后备，并非正式入口恒关；系统注册及设备行为仍待验。 |
| 桌面云盘 | DesktopCloudDriveService、CloudFilesInterop、DesktopCloudDriveStore 与 Mac ProviderRuntime/写回设置 | **未对齐，见下列源码缺口；9 个管理页场景不能覆盖资源管理器读写。** |

恒关项复核：旧 IFileLocationsRepository.AllowsRemoteMountManagement 保持 false，但
正式 FileLocationsView 使用 CanManageRemoteMountWorkflow；旧 NasSettingsWritesEnabled
只隔离无确认请求边界的通用写，专用工作流按管理员/会话/能力判断。不能直接删除这些保护。
FTP/SFTP/发现协议/UPS 的旧独立能力也不能代替正式文件服务/硬件分组保存的可用性判断。

新发现且仍需实现的云盘差距：

1. `DesktopCloudDriveService.cs` 的 CloudFileRangeTransfer.ExecuteAsync 明确拒绝 offset
   非零、非整文件、或大于 64 MiB 的请求；跨回调/重启没有持久化远端强版本。
   `DesktopCloudDriveTests` 的 PartialCallbacksRemainRejectedAcrossARuntimeRestart 与
   UnboundedWholeFileIsRejectedBeforeReadingOrSubmitting 正在验证这个拒绝边界，
   不是证明资源管理器任意文件可读。不得仅移除上限而允许拼接不同版本内容。
2. Windows 占位文件为只读，删除/改名回调统一拒绝，没有修改写回及待同步恢复日志。
   Mac `DesktopDriveWritebackAvailability.isEnabled` 为 true，指定挂载经确认可开启；
   `DesktopDriveWritebackStore`、`DesktopDriveWritebackSettingsSheet` 和 ProviderRuntime
   有内容版本、待办及未知恢复。因此“只剩整合和 Mac 包”的旧结论不成立。

本次重跑 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore --filter FullyQualifiedName~DesktopCloudDriveTests -v minimal`：36 通过，
0 失败、0 跳过；它证明目前安全拒绝仍有效，不把这些限制算作目标完成。

后续持久化切片须按项目规则先获明确同意：在 Windows 本机增加每个挂载/文件绑定的强版本
记录与独立待同步日志，暂存修改和已提交未知结果，复用现有文件 API、权限及传输边界；
不改变身份、签名、依赖或最低系统版本。旧映射兼容读取且仍默认只读，用户逐挂载确认后
启用写回；旧数据没有版本证明时重新核对，不自动上传或覆盖。迁移采用独立版本化记录，
不能让旧版配置重写或缓存回收丢弃待同步修改；回滚关闭新入口、保留待办与本地副本，
未解决待办不得自动卸载或删除。五端 API 契约不新增，其他四端源码不改。
真正系统回调和隔离 NAS 行为单列 PENDING_USER_VALIDATION，但源码缺口不能用该标签后置。
该存储扩展随后已获得用户明确批准，见上方实施记录；真实数据测试授权边界不变。

#### 2026-09-21 控制台别名与官方资源接线

只读检查官方 noVNC app.js 确认地址规则：别名位于 socket 路径之前，initPathSetting
还追加当前窗口 app_id；此前托管 URI 漏了此参数。官方中文启动依赖 app/locale
的 JSON XHR，原 connect-src none 会阻断；另有固定铃声和套件图标资源。
单一范围为现有控制台策略/资源读取与回归，不换传输、不放宽证书/同源约束。
按已观察规则支持同源单段别名；语言 XHR 走受限原生消息桥，保留逐资源路径/方法校验，
不允许一般 CGI、任意 JSON、任意 WebSocket 或网页凭据。其他四端实现不变，
五端接口证据记录同步；真实别名入口仍需用户环境验证，不因缺别名设备保留硬关。

已补 alias 前缀和同一文档 app_id 查询，托管能力按受支持 HTTPS/单段别名开放；
不接受跨别名资源或不匹配的窗口连接。增加语言 JSON、指定铃声与原始 HTML 七种
固定图标路径，铃声仅该文件接受已观察的 octet-stream MIME。JSON 仅限合法语言
文件名，单份 1 MiB、最多 4 个在途读取，无任意头/方法/目标可转发。

初版显式语言目录 CSP 在原生 IPv6 场景失败；没有改用宽泛 self，最终恢复
connect-src none，并在原有桥增加固定 GET 的语言请求。官方 XMLHttpRequest
接口由受限适配接入，其他请求仍由浏览器 CSP 阻断；错误转为原生本地化提示，
关闭取消语言读取并清除迟到结果。新增原生夹具独立按官方 path/app_alias/app_id
组合地址，不再用被测 SocketUri 生成期望地址；启动必须实际读到语言 JSON 后
才打开二进制连接，覆盖根路径、别名、IPv4/IPv6、错窗口与非法 JSON 阻断。
根路径/别名/IPv4/IPv6 聚焦 6 场景已通过；全量 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
3633 通过、0 失败、0 跳过。`windows/tests/UiSmoke/run.ps1 -SkipBuild
-Scenarios vm-console -Language zh-CN -WindowWidth 900 -WindowHeight 740` 及同命令
en-US 各 22 场景通过；报告为
`windows/dist/ui-review-20260921-015130/results.json` 与
`windows/dist/ui-review-20260921-020111/results.json`，44 份图像产物均存在。
既定 `windows/package.ps1` 双架构自包含 Release 成功，输出
`windows/dist/20260921-020146`，未安装或启动；归档 testsRun=true、架构及
selfContained 标记已核对，无测试报告/标记文件，SHA256 与 sidecar 一致：

- x64：`5FC808BCACA8E1E2140C147B93AA48E490B1B8FD032ED7D38386D9F1531D3FFC`。
- ARM64：`847191B0AC6990DA5164EEA888A76F648DAE3A6C06A3FDED42E27B2E11EE1B7B`。

本波只读集成复核覆盖桥消息源/窗口身份、固定语言 GET、并发/大小限额及关闭取消；
未连接真实 VM 或修改门户配置。实际别名门户、VM 画面和键鼠仍为
`PENDING_USER_VALIDATION`；本次结果不代替所有模块最新原生全量或 Mac 构建。

#### 2026-09-21 公开映像克隆创建闭环

基线复核发现 VerifyImageSource 是无条件返回且没有可推进路径，导致已完成克隆
也永久占用创建待办并阻止开机。官方 VMM API Guide 第 23–24 页规定 create_type=1
与 image_id 选择克隆源，由同次 create 返回的 task_id 获取结果，再取新 guest_id；
公开模型没有来源 ID/内容哈希回显。不能仅凭新盘大小判断来源，也不应等待契约
不存在的字段。本波保留冻结源 ID/类型/名称、原 HTTP 请求与任务回执绑定、拒绝
创建前已有 guest_id；增加 finish=true/status=create/progress=100 的严格完成
条件及新 VM 磁盘/网卡身份快照，后续设置前后必须一致。该证明依赖公开 API 的
克隆语义，不宣称做了内容哈希比对。五端公开契约不改，仅 Windows 编排/测试与
说明修正；旧 VerifyImageSource 枚举保留兼容，不作为新版默认停驻阶段。
单一范围是现有公开创建核心及合成/原生回归，不新增私有探测、真实数据克隆或
自动删除。真实内容/Guest OS 启动仍属用户验收，不用真实数据验证本切片。

已移除无退出路径的克隆停驻；增加严格公共任务完成检查、可信任务结果缓存和
后续硬件快照对比。来源变化、缺回执、状态/进度不完整、磁盘/网卡/MAC 漂移不
提交后续写入；已核实结果可完成创建并释放原待办，只有原确认包含开机且配置
仍一致才进入既有电源流程。只读恢复仍不会自动配置或开机。
原“仅凭容量不能核实来源”回归保留该否定场景，并扩展为未完成任务、错误状态、
非最终进度不得写入；正式完整任务后才可继续。未把不存在的来源回显伪造进响应。
新增 16 项回归，聚焦创建 57 项通过；全量 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
3609 通过、0 失败、0 跳过。原生夹具改为真实新阶段，新增克隆开机/延后确认/
缺回执/硬件漂移；首次宿主编译漏写本地化命名空间，已用完整名称修正。
中文创建 40 场景通过，目录 ui-review-20260921-004050；英文与分发包继续收尾。

最终英文同组 40 场景通过（ui-review-20260921-005304），中文/英文命令分别为
windows/tests/UiSmoke/run.ps1 -Scenarios vm-create -Language zh-CN/en-US
-WindowWidth 900 -WindowHeight 740，英文使用 -SkipBuild。覆盖原创建/高级创建及
克隆完成、确认后开机、延后确认、缺回执和硬件漂移，未把全项目原生场景冒称重跑。
windows/package.ps1（LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0）exit 0，包内测试 3609 通过，
0 失败/0 跳过，x64/ARM64 Release 自包含 publish 完成、无警告/错误。
包目录 windows/dist/20260921-005335；x64 ZIP SHA256 为
AD253A99FC4D46F3F42372B7DACB71EA5D7B157D54E4E9B81CBAC95EC67CD8FC，ARM64 为
4661F524543AED22790CB24FF5F108EB67B649E9FEA46A54278C180FA93DE04D。
sidecar、包内架构/testsRun/selfContained 和无测试宿主标记检查通过；未安装/启动，
旧包保留。只读集成复核确认新增快照仅用于核查，不参与磁盘改写；原权限/确认/
重复提交保护与未知结果不重放保留。未执行真实数据克隆、未提交/推送，其他端
未改源码。剩余主线为控制台别名、最终整合审计和 Mac 修复包，目标未收窄。

#### 2026-09-20 高级创建主流程接线

单一范围为现有 Windows 创建请求/协调器/原生窗口及其回归，不新增平行向导。
高级模式使用已观察的内部 create v1 和 Cluster.get_total_progress v1，基础/磁盘
映像创建保留公开路径。请求号同时作为 synovmm_ui_id；按 task_id、完整参数和
请求身份精确关联，回执丢失也只能按已观察的身份回显核查，不按 VM 名称猜测。
随后用已完成的内部 get/get_setting 核对完整硬件/固件/ISO；核对完成前不启动。
关窗只取消本地等待，未知不重复 create；恢复继续复用现有创建待办与电源流程。
Mac 基线为 VirtualMachineCreation/创建窗口（空白磁盘、OS、固件、启动 ISO），
其他四端不扩实现范围，五端契约沿已脱敏真实样本。磁盘映像克隆来源核查是独立
剩余项，不将它隐藏或宣称已完成。非目标为更改现有 VM、真实文件或用户权限。

2026-09-21 本波主流程已接通：原创建窗口增加默认/Windows/Linux/Other 预设、
Legacy BIOS/UEFI 与安装 ISO；保留 CPU/内存/多磁盘/多网卡及创建后开机选择。
高级模式为至少 10 GiB、整 GiB 的空白盘，磁盘映像仍走原公开路径。内部请求
固定 create v1，容量类型、空槽、控制器及预设与官方样本/静态表对齐；未指定
MAC 时生成互异本地单播地址并固定在本次操作内。任务回执/请求身份/完整参数
三重关联；收到成功任务后记住可信 guest_id，后续任务被官方页面清理仍可核查，
缺失或错配绝不按名称认领。硬件/固件/ISO/MAC/存储等完整核对后才进入已有电源
流程；只读恢复不自动开机，需要用户重新确认。ISO 引用纳入现有映像删除互锁。

资源冻结/读取失败后保留已选高级模式，不能偷偷改用公开模式提交；用户可明确
切回默认设置。确认绑定系统、固件、ISO 和全部原配置，改动即撤销确认。原生
确认摘要无资源键泄漏，创建按钮实际启用并通过按钮调用路径触发，不仅直调模型。
更新了旧“安装介质必须在 DSM 调整”的提示，14 项新文案均提供中英文。

新增 33 项高级创建核心回归与 3 项状态回归；dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
及包内重跑均 3593 通过、0 失败、0 跳过。覆盖 FORM/JSON、三个系统预设及两种
固件、ISO、共享真实结构 fixture、请求/任务错配、已有 ID 拒绝、配置漂移、丢
回执恢复、关窗取消、只读恢复不写、MAC 固定和资源变化。初次新增测试仅触发
xUnit 断言风格编译门，已改为等价 DoesNotContain，未降低断言。

原生创建回归最终中文与英文各 36 场景通过，分别为
windows/dist/ui-review-20260920-235446/results.json 和
windows/dist/ui-review-20260921-000408/results.json；命令
windows/tests/UiSmoke/run.ps1 -Scenarios vm-create -Language zh-CN -WindowWidth 900
-WindowHeight 740，英文改 en-US 并加 -SkipBuild。包含原 22 场景及高级表单/成功/
更改确认/冻结/失败/回退/未知/关闭/摘要/实际原生按钮触发；原 884 全量基线不冒称
重跑。已检查高级表单和滚动确认区截图。

官方页面补做只读能力核查：公共 Guest/Storage/Task.Info 仅 v1，内部 Guest/Repo/
Guest.Image 为 v1–v2，Cluster 为 v1–v2，均 JSON；当前 ISO 状态为 online/healthy，
必需身份字段为非空字符串、is_freeze 为布尔。只返回状态/类型，无新增 NAS 写，
不导出响应；computer-use 用于核实真实启用条件，不提升 App 全流程实机等级。

windows/package.ps1（NON_INTERACTIVE=1、TARGET_PLATFORM=both、RUN_TESTS=1、
LAUNCH_AFTER=0，均为 LANSTASH_ 前缀环境变量）exit 0；双架构 Release 自包含
publish 完成，无警告/错误。独立包目录 windows/dist/20260921-000522，x64 ZIP
SHA256 为 4502F925D993A34D654E58E74184CB97C930E76A91F88445D0008B0C920A3121，
ARM64 为 458402C65330D41652304B05154FE44BBD722181812075B3230A493360AEE0DD。
sidecar、包内架构/testsRun/selfContained 及无合成宿主标记已核对，未安装/启动，
旧包保留。源码只读对抗复核覆盖目标/请求绑定、既有协调器互斥、资源预检、未知
不重放与开机门；未移除安全确认。Mac 同类修复尚无目标构建，其他端未在本波改动。
PENDING_USER_VALIDATION：使用测试包在隔离资源验证预设/固件/ISO 和创建后开机，
回传脱敏提示/版本，不传凭据或真实数据。整体仍剩磁盘映像来源核查、别名控制台、
最终整合审计及 Mac 修复包，目标保持完整。

#### 2026-09-20 高级创建只读契约接入

在测试 VM 磁盘规格变更等待确认期间，继续不依赖真实创建的读取切片。Mac 证据为
DsmCore.VirtualMachineCreation 与 DsmServiceManagementRepository.createVirtualMachine；
字段来源为同日官方 get_setting v1、Repo.list v2、Guest.Image.list v2 的自然
成功响应及静态表单映射。单一范围为 Windows 高级创建选项/配置读取模型、既有
Repository 增量及正式合成回归；不提前接入缺少结果身份依据的内部 create。
同一配置读取需与既有内部 Guest.get v2 的基础字段核对，ISO 空槽保留 unmounted，
大小/布尔/数字维持本端点类型，不将缺失或字符串布尔转成默认值。
五端只新增 Windows 读取契约；其他四端与私有行为等级不变。既有创建入口、写
确认、接口权限和测试包不受影响。非目标为真实创建/变更/开机或公布用户配置；
PENDING_USER_VALIDATION 仍只约束完整高级创建后续验收，不阻断本读取切片。

已接存储/映像内部 v2 读取及冻结标记，配置由 Guest.get v2 前后基础快照和
get_setting v1 交叉核查，字段保持原生类型，映像允许同一 ID 的多存储实例。
新增 32 项聚焦回归通过。随后用户授权所有不涉及真实数据的隔离测试，新建单台
10 GiB 空白测试 VM，实际取到 create v1 的 task_id 与聚合任务成功结果/guest_id
及请求身份回显；创建后保持关机、断网和无 ISO，详情见高级创建观察记录。

实测暴露内部内存读取 KiB / 写入 MiB 的同类缺陷。Windows 优先级/高级读取统一
转换到领域 MiB，拒绝非整 MiB/溢出/类型错误；公开接口仍为 MiB。Mac 基于公开/
内部来源分别换算，保存回读换算期望值，并将 allocated_size 发送为数字。
新增 5 项 Windows 边界测试；Apple 两个旧核查 fixture 改为真实 KiB 语义，另补
来源区分与错误单位不误报成功测试及 JSON allocated_size 断言。Apple 代码仅此
同类修复范围，不覆盖其他既有修改；本机 Get-Command swift 未发现编译器，
Swift/Mac 测试与修复包仍未运行，不以 Windows 结果替代。

最终 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore -v minimal：3557 通过、0 失败、0 跳过。dotnet build
windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64
--no-restore -v minimal 及对应 arm64/win-arm64 均 0 警告/0 错误。
本地化、111 项请求 fixture、3 组响应 fixture、22 项私有引用、严格文档与差异
空白检查通过。正式样本仅使用合成身份；浏览器原始响应变量已清空，网络观察已
停用，没有 HAR/响应/截图/临时脚本落盘。新建测试机保持关机并留作后续隔离测试，
不会自动删除；旧用户标签无法再次附加，其未提交向导未被补发。未提交/推送。
尚未生成包含本波读取/单位修复的新分发包，最新可下载包仍为 20260920-221005；
高级创建的提交/任务编排和原生向导接线继续，不能用本波读取完成替代整个目标。

#### 2026-09-20 VMM 映像导入

原剩余清单已包含映像导入；复查 Mac ServiceManagementView/Model 与 DsmCore 协议，
现有映像只有列表/删除，不把本波说成复制已有导入入口。按用户要求完成剩余清单，
使用官方公开 Guest.Image.create v1：NAS 共享文件夹内来源、名称、disk/iso/vdsm、
多个目标 storage_ids、auto_clean_task=false；任务回执经 Task.Info.get v1 绑定
image_id，再用公开映像列表核对名称、类型与全部目标存储。来源原文件不删除。
依据为官方 VMM API Guide 第 27–28 页，不能用“任务结束”代替导入完成。

单一修改范围是 Windows VMM 领域、既有协调器内导入/任务保护、原生入口与双语、
正式回归和相应文档/请求 fixture。确认绑定完整输入，未知不重发，重复请求号与
其他 VMM 写互锁，未核实映像不能被删除/克隆，恢复仅当前会话内存。无新增依赖、
权限、身份或持久化格式。五端影响：Windows 兼容增量；Apple/macOS、Apple 移动、
Android 与其他端只记录公开契约，不扩实现范围，不改变私有兼容等级。
非目标为本机文件自动上传、猜测内部创建字段或自动删除源文件；高级 VM 创建仍
是独立待办。PENDING_USER_VALIDATION：专用测试映像和有权限存储，验证导入进度、
结果/重开核查与原文件保留；仅回传脱敏提示/版本，不发送真实 NAS 写。

主流程已接：公开固定 v1 FORM/JSON、NAS 路径/名称/类型/多存储确认、新鲜存储与
同名冲突预检、任务身份及新映像/全部 online 存储核对。已知/未知回执均不重发，
当前会话可重开只读核查；未完成导入的任务不能清理，映像不能删除或作为克隆
来源，所有既有 VMM 写都检查导入请求号冲突。未另建协调器/传输或持久化层。
原生映像页增加导入窗口、进度刷新、继续核查、另一个导入、只读/空/错误/加载
状态与 28 个双语资源。提交前核对实际表单与确认快照，文本变化前即撤销确认。

新增核心回归 26 项、状态回归 8 项，最后完整 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
为 3519 通过、0 失败、0 跳过；后续又补了实际请求与既有 create-image fixture
逐参数比对，最终计数以包内测试为准。首次新增测试编译的参数顺序/通知成员名
以及合成成功计数不一致已修，未修改生产结果校验或降低断言。

原生首轮来源改动场景暴露文本事件时序，已补变化前撤销确认与提交时表单比对；
最终中文与英文各 13 场景通过，目录 ui-review-20260920-220731 与
ui-review-20260920-220911。命令 windows/tests/UiSmoke/run.ps1 -Scenarios vm-image-import
-Language zh-CN -WindowWidth 900 -WindowHeight 740；英文改 en-US 并加 -SkipBuild。
已查看表单截图，确认内容和操作按钮完整，测试没有接入真实 NAS。x64 App Release
build 初次 0 警告/0 错误；双架构最终包已生成。

最终 windows/package.ps1（LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0）exit 0，包内单元测试 3520 通过、
0 失败、0 跳过，x64/ARM64 Release 自包含 publish 完成，未出现警告/错误。
独立目录 windows/dist/20260920-221005；x64 ZIP SHA256 为
E080A5A0886B8335C2973993FB4E5DE8761D42E30EB85EF608A1381097C9EF5F，ARM64 为
655C80D13FCE5E2D77F71BB6EE489647559E9BFC804B0FA8A21059D2C7EC2CEB。
sidecar、包内架构/testsRun/selfContained 和无合成宿主标记检查通过；未安装/启动，
旧包保留。最终集成复核覆盖请求号互锁、确认快照、任务证据保护、身份/类型/目标
存储核查和只读恢复，未新增源文件删除或真实写请求。全部 655 项既有/当前工作区
改动保留，未 git add、提交或推送；正式测试与报告保留，不含真实用户数据。

共享请求 fixture 已存在，沿用 vmm/create-image/synthetic-image，不重复新增或
把公开接口写成私有发现。契约 110 请求 fixture、响应 3 组、私有引用 22 项及
本地化扫描通过。此波不修改其他端代码，Mac 构建/高级 VM 创建与最终全范围对账
仍需继续，不能以导入完成收窄目标。

#### 2026-09-20 控制台消息桥接入

单一范围为现有控制台会话/窗口与受限二进制消息桥。托管模式不向 WebView 安装
NAS Cookie，文档 CSP 禁止直接连接，静态资源复用已实现的同源边界。网页消息
必须匹配固定文档来源、窗口随机上下文和连接编号，只能打开既定 VM socket、
发送二进制或关闭；不接受任意 URL、HTTP 请求或原生对象调用，不监听本地端口。
先补桥接与合成验证，仍不把未核实的真实资源清单/别名或 VNC 设备行为称为通过。

消息桥及窗口接线已实现。修正 Peer 取消令牌未初始化与 WinRT 事件包装对象身份
判断问题；原生回调绑定创建时的控件，消息仍检查完整页面来源、随机上下文和递增
连接编号。网页没有 NAS Cookie，所有资源通过受限读取，CSP 禁止直接连接；资源
并发上限 4、窗口保留上限 64 MiB/256 项。关闭取消连接/读取并清理正文与 socket。
浏览器发送使用二进制、有界队列和串行写；接收以 64 KiB 块顺序交付，避免把
高分辨率画面错误限制在 1 MiB。此流语义参考
[noVNC 官方 Websock 接收队列](https://github.com/novnc/noVNC/blob/master/core/websock.js)，
并不宣称实际 NAS 所带 noVNC 版本已验收。

Windows 根路径连接现按既有认证/目标状态、资源读取与 socket 能力开放托管入口；
系统信任模式保持原实现。应用别名路径没有 socket 路由证据，仍不猜测。当前全量
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore
-v minimal：3485 通过、0 失败、0 跳过。初次全量有 1 项源码断言仍匹配旧方法
签名，已更新为检查托管 CSP 调用并新增接线/关闭/资源与 Cookie 分支检查，保留
原证书隔离断言。消息桥新增 19 项行为回归，仓库新增别名禁止用例。

真实 WebView2 初次托管场景连接等待超时；诊断证明脚本/资源已加载，改为绑定
订阅时控件后，中文托管浅深色及连接期间关闭 3 场景通过，报告
windows/dist/ui-review-20260920-214214/results.json。最终含重连的完整控制台
回归中文、英文各 16 场景通过，报告目录分别为 ui-review-20260920-214609 与
ui-review-20260920-214808；逐项结果和主截图齐全。命令为
windows/tests/UiSmoke/run.ps1 -Scenarios vm-console -Language zh-CN -WindowWidth 900
-WindowHeight 740，英文改 en-US 并加 -SkipBuild。已分别检查 XAML 窗口和
WebView CapturePreview 页面图，不把 XAML 截图无法包含网页合成层误记为页面空白。
旧完整 884 场景基线未被替换，也未冒称重新全跑。

windows/package.ps1（LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0）exit 0；包内测试 3485 通过、
0 失败、0 跳过，x64/ARM64 Release 自包含 publish 均完成，未出现警告/错误。
独立目录 windows/dist/20260920-214819；x64 ZIP SHA256 为
6468FC7BFBC82C96FB49ACEFF07276457EAC4E5CE49104B658A5D2861F527CA2，ARM64 为
2976ECF58BCA55EF69850008707AE06B39213A2BE0BB3F35A6E6C02C40A96BB2。
压缩包、sidecar、包内 build-info 的架构/testsRun/selfContained 均一致；正式 App
无 SmokeRepository/SmokeSnapshot 或截图标记。未安装/启动新包，未覆盖旧包。
本地化、110 请求 fixture、3 组响应 fixture、22 项私有文档引用、严格文档检查及
git -c core.safecrlf=false diff --check 通过。独立集成复核覆盖凭据不进入网页、
消息与资源目标绑定、关闭迟到回调、原证书处理器和未核实别名拒绝；保留真实 NAS
与 Mac 验证缺口。全部既有未提交修改保留，未 git add/提交/推送。

五端影响：仅 Windows 会话/传输/原生窗口增量；私有端点及写契约未扩展，Apple、
Android 与其他端不改，也不提升历史设备兼容等级。PENDING_USER_VALIDATION：
已确认固定证书、VMM 权限及运行中 VM 的根路径 HTTPS 连接，用户打开控制台并
核对画面、键鼠、断线重连及关闭；失败仅回传去除主机/会话/VM 内容后的提示和
DSM/VMM 版本。应用别名、实际 noVNC 资源与设备输入尚未验证，Agent 未操作真实 VM。

#### 2026-09-20 托管控制台资源边界

为后续浏览器桥接补静态资源读取：仅允许同源 noVNC 目录下已定义的静态扩展名，
拒绝 CGI、跨源、路径转义、片段和非版本查询，不把浏览器任意请求转发为带凭据的
NAS 请求。沿用原 HttpClient/证书上下文与有界读取，返回内容不带 Set-Cookie；
托管文档策略单独禁止浏览器直接 connect-src，现有系统信任模式保持不变。
本波先实现并验证该资源边界，尚不开放托管控制台 UI；实际资源清单与桥接继续。

已接固定资源策略、ReadConsoleAssetAsync 与托管文档 CSP；只允许 noVNC 包目录的
静态类型与受限 v 查询，GET 返回须为同一 URL、200、匹配 MIME，单资源 16 MiB。
沿既有认证/证书处理器，响应只保留安全内容头，不向网页透传 Set-Cookie；原有
非托管 ResponseHeaders 默认行为不改。新增 14 项测试，相关控制台/证书/Chat
聚焦 83 通过；全量 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal **3465 通过/0 失败/0 跳过**。
新增裸 HTTP 发送已加入证书上下文源清单，原检查保留。x64/ARM64 App Release
build（-p:Platform=x64/arm64 -r win-x64/win-arm64 --no-restore）均 0 警告/0 错误。
未运行新宿主以干扰在途全量 UI 回归，未生成新分发包；浏览器消息桥未完成，
固定证书控制台仍不能称为可用。无真实 NAS 请求、无 Cookie/响应/临时抓包落盘，
未提交/推送，旧包及用户修改保留。

#### 2026-09-20 控制台托管 WebSocket 基础

复用既有 Chat 的 HttpMessageInvoker 握手实现，将同一处理器移至 Transport，
避免另建绕过证书的客户端。控制台增加固定虚拟机 WSS 地址和可选连接接口，
只接受同一 profile/会话/策略，别名路径尚未核实则不启用托管连接。原有系统信任
控制台不改，固定证书模式的浏览器消息桥/资源加载未接入前仍保持安全门。
本波仅涉及领域增量、共享握手、连接方法与聚焦回归，不改权限/依赖/存储/信任策略。
测试只使用合成握手/本机测试对端，不读取或操作真实 NAS 控制台，Chat 同步回归。

已完成共享 NasWebSocketHandshakeHandler 抽取、固定根路径 SocketUri 和可选连接
接口；包装器沿用原 HttpClient，WSS 请求转换为同一固定 HTTPS 目标后设置 profile/
source，再加会话 Cookie、可选安全头及同源 Origin，以 ResponseHeadersRead 保留
升级流。别名策略返回无托管 socket 地址，不猜路由；序列化不暴露地址和会话。

新增 10 项控制台 socket 回归，覆盖真实本机 TLS/WebSocket 二进制交换、正确 pin
接受、无 pin/错误 pin 在凭据发送前拒绝、绑定/凭据/别名拒绝和取消；Chat 原握手
回归保留。首次 3 项 TLS 夹具失败，原因是 Windows Schannel 不接受纯内存私钥，
不是放宽校验解决：测试证书采用默认临时密钥导入、证书释放时清理，不使用
PersistKeySet、不安装信任、不保存 PFX，内存导出字节立即清零。
原聚焦 22 项通过，追加策略用例后的完整 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
**3451 通过/0 失败/0 跳过**。整个浏览器控制台尚未接入该通道，不能称固定证书
模式已完成。正在运行的完整 UI 宿主仍是本波前编译快照，后续需单独复验受影响的
Chat/控制台流程，不把在途 UI 结果伪称本次新二进制的覆盖。

dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64
-r win-x64 --no-restore -v minimal 及对应 arm64/win-arm64 均 0 警告/0 错误。
本波未生成新分发包，避免将尚未接入的托管控制台称为用户功能完成；原可用包
继续保留。测试使用的 TLS 监听仅绑定 loopback 随用例释放，临时证书/内存私钥
由测试释放，不安装根证书、不留下 PFX/HAR/真实响应。其他端未改，未提交/推送。

#### 2026-09-20 全功能原生回归与宿主隔离

前波为进展，新增网络完整主流程及可用包。本波高级创建只读续查因浏览器未附加
而未获得新字段，不能把内部参数猜到公开 create 或 set。先继续既定全入口回归。
当前正式 UiSmoke 清单包含 884 场景；本波单一范围是该既有宿主的设置隔离、
逐场景报告和完整回归，不改变生产用户设置的格式或位置，不新增 API/权限。
测试专用编译使用内存语言/界面偏好，防止真实隐藏模块影响入口；混合场景输出
文件带场景前缀，避免同名状态覆盖。保留原断言和默认遇错即停，完整审查可显式
继续记录全部失败，最终仍以非零退出报告失败，不改为静默跳过。
Mac、Android 与真实 NAS 验收不由该宿主替代；未运行项不能借场景总数称为通过。

已实现测试编译专用内存偏好，生产仍使用原 settings.json/language.txt 路径，不改变
真实数据。新增 2 项源契约，dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release --no-restore -v minimal **3441 通过/0 失败/0 跳过**。
完整原生命令 windows/tests/UiSmoke/run.ps1 -ContinueOnFailure -Language zh-CN
正在执行，报告为 windows/dist/ui-review-20260920-202241/results.json；本次默认
1280×820，顺序运行，不与另一原生回归并发。阶段检查 69 项通过、0 失败，不是
884 项全部通过，也不替代英文完整回归。当前 884 个用例标识检查无重复，混合输出
包含场景前缀。保留此前可用包，不在全量回归未结束时宣称最终交付。

续查生产固定关闭标记，不能仅凭文本匹配宣布功能缺失：

- FileRemoteMounts 的 AllowsRemoteMountManagement=false 是缺少确认快照/请求号的旧
  入口；正式路径是 RemoteMountWorkflow.CanManageRemoteMountWorkflow，按会话、
  实际传输和三个接口版本开放，不能为通过扫描而重新开放旧危险写入口。
- NasPackageSettingsDialogContent.CanSave=false 不等于套件动作被禁用，Start/Stop/
  Uninstall 通过 CanChoose/CanExecute 与独立确认提交；通用 SaveAsync 不参与该流程。
- NasFileServiceSettings 的 XAML 初始 IsEnabled=false 会在读取后按 editing 更新，
  不是恒关闭；缺失字段和风险确认仍保留。
- 电源计划、外接存储、zram 在 Mac NasAdministrationModel/Core 也只有对应 load
  入口，当前只读不是遗漏已存在的 Mac 写功能，不擅自新增系统副作用。
- NullForegroundTransferNotificationService 和 unavailable 活动来源属于显式空对象，
  不将其 false 标记当成生产通知/任务读取全部关闭。

活跃进程未重启；逐场景进度与完整结论以运行目录中的 results.json 为准，不维护滚动比例。
此项是固定门的源码核对，不代替完整功能对齐账本或真实系统验证。

完整原生进程已 exit 0：中文 **884 项通过/0 失败**。results.json 中 884 个
scenario/theme/state 标识唯一，884 个主截图均存在，尺寸配置 1280×820。
该宿主 App DLL SHA256 为 83D93E4E29FB0D1AB8D91F89EA40BF51DBD8438DAA5C600BBE0B72AEF3120CBB，
Application DLL 为 0B3886A4B901295D8498A1D911113D88550C721A291654E84073D9A261A9A450。
这锁定了全量回归的实际二进制，不把随后托管 socket/资源基础修改自动算作已覆盖。
新源码正在重建宿主，单独复验 Chat 与现有控制台；英文全量未在此命令中执行，
此前分功能双语证据继续保留，真实 NAS/系统和 Mac 构建仍未替代。

新编译宿主补测 Chat/现有控制台，中文和英文各 **16 场景通过**，目录分别为
ui-review-20260920-212027 与 ui-review-20260920-212303。命令 windows/tests/UiSmoke/run.ps1
-Scenarios chat,vm-console -Language zh-CN -WindowWidth 900 -WindowHeight 740，
英文改 en-US 并加 -SkipBuild。没有重跑或覆盖原 884 场景报告；两层证据区分
整体验证基线与后续共享传输改动。未对托管浏览器桥给出不存在的测试结论。

#### 固定证书控制台后续传输边界核查

只读核查已有 WindowsCertificateTrustHandler：握手必须带 HttpRequestMessage.Options
中的 profile/source，上层仅检查一次 HTML 证书不足以约束浏览器后续 WebSocket。
现有 CertificateConnectionContext 的 HttpClient 已持有同一证书处理器，可被后续
托管通道复用；[Microsoft ClientWebSocket.ConnectAsync](https://learn.microsoft.com/en-us/dotnet/api/system.net.websockets.clientwebsocket.connectasync?view=net-10.0)
提供 HttpMessageInvoker 重载，因此不应另建默认客户端或放宽证书错误。
下一实现需在握手消息上设置既有 NAS 上下文、使用 ResponseHeadersRead 保留升级
流，并验证同一固定证书、变更拒绝、取消/关闭与凭据隔离。浏览器侧的受限消息桥、
资源读取和 CSP 仍是待实现/验证内容；本次仅确认传输候选，不解除现有安全门，
不声称固定证书控制台已经可用，也不添加本机监听端口或信任证书。

#### 2026-09-20 Windows 虚拟网络改名与删除

Mac 证据为 ServiceManagementModel.updateVirtualMachineNetwork/deleteVirtualMachineNetworks
及 DsmCore.VirtualMachineNetworkUpdate（只包含 name）。本波等价结果是完整列表、
单项改名、多选逐项删除、明确风险确认和未知结果只读恢复，不将官方 VLAN/接口
拓扑编辑额外算作 Mac 已有功能。使用前波记录的内部 list/get v2 与 set/delete v1，
external 改名带空接口增删数组，private 保持 host_id，绝不隐式改变拓扑。
危险写必须绑定完整新鲜网络/关联 VM 快照、现有模块互斥、会话与请求身份，执行后
同源核对，不发真实 NAS 写。未知网络操作与引用它的 VM 创建/修改/电源互锁。
单一范围为 Windows VMM 领域、内部适配、原生管理状态/界面/双语和回归，既有
模块状态文件仅增加必要互锁。不改 Apple/Android，契约兼容影响沿前波记录。
PENDING_USER_VALIDATION：在可丢弃网络核对改名、删除及关联 VM 影响，删除可能
中断连接且不自动撤回，不将网络消失等同所有 VM 已重新联网。当前为源码实施中。

主流程已实现：严格 list/get 完整快照、同源回读、固定 v1 请求和现有 VmMutations
模块锁；新增网络请求身份/待核查集合，并与其他 VMM 请求身份及相关 VM/创建
待办相互保护。改名不发送 VLAN 或全量接口；删除逐项且失败/未知/认证失效即停。
所有选中对象在第一笔写前再核对，未截断 205 项；恢复只读，保留已完成行和未开始
数量，重新编辑必须刷新。原生选择/名称/操作变化清除确认，加载/空/错误/只读/
冻结/正常状态均有明确呈现，离页/关闭取消等待。

新增 43 项核心/状态/fixture/源接线回归，全量 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release --no-restore -v minimal
最后包内 **3439 通过/0 失败/0 跳过**。初次测试编译发现测试能力参数及模型通知/
认证成员命名不一致，已按既有接口修正；生产 x64 编译 0 警告/0 错误。
新增共享 external 改名 fixture，比对实际 JSON 参数；请求 fixture 现为 110 个。
原生首轮双语各 16 场景通过，补名称校验、加载与关闭断言后，初次取消检查早于
异步回调完成，改为等待明确取消、保留断言。最终中文 19 场景通过
（ui-review-20260920-194857），英文及最终双架构包收尾中。
独立集成/只读对抗复核覆盖目标变化、字段畸形、尾部变化零写、冻结、不重放、
请求身份冲突、关联操作互锁、只读恢复及脱敏；没有执行真实 NAS 写入。

最终英文 19 场景通过（ui-review-20260920-195447）；命令
windows/tests/UiSmoke/run.ps1 -Scenarios vm-networks -Language zh-CN
-WindowWidth 900 -WindowHeight 740，英文改 -Language en-US 并加 -SkipBuild。
已查看浅深色确认、未知结果和名称校验截图。最终包 windows/dist/20260920-195437，
package.ps1 设置 both、RUN_TESTS=1、LAUNCH_AFTER=0；双架构自包含 Release
publish exit 0，包内全量 3439 全通过。build-info 源提交/dirty 状态、架构及
testsRun=true、正式 App/Application DLL 无合成仓库/场景标记均核对。
SHA256 与旁文件一致：

- x64：`8FFE55205D4AECA69DB0D73EE50B4F205F36C7C48EAAC187B72D00E8D541F1AF`
- arm64：`E3D857A1E2449B1AF664FF528CB12CC4FF544F9E3E4588B5F928286809A3AD68`

本地化 Apple 4125/Android 2188/Windows 3280，110 请求 fixture、3 响应/22 私有
引用、严格文档与差异检查通过。旧的本轮 smoke-failure.txt 已清除，修正原因保留
上文，正式回归源码和截图保留。未安装/启动正式包，未提交/推送，保留旧包和所有
用户改动。Mac name-only 基线的网络管理切片完成源码/合成/构建，不替代真实网络
验收；VMM 高级创建、固定证书控制台、最终全范围对账和 Mac 构建仍需继续。

#### 2026-09-20 VMM 网络契约与 Apple 同类版本修正

浏览器通道恢复后已只读核对 DSM/VMM 当前版本及 Network.list/get v2、
list_avail_interface v1，记录见 environments/2026-09-20-vmm-network-read-observation.md。
官方静态 set/delete 固定 v1，external 编辑使用增量 interfaces_add/remove，private
保留 host_id，不能照抄旧 Mac 只写 name 的完整编辑语义。Guest.create 同样固定 v1，
ISO/USB 未挂载槽是 unmounted。先单独收敛契约与现有 Apple 写方法的版本/空槽偏差，
Windows 完整网络编辑/删除仍待后续模型、互锁和原生界面，不将观察当作功能实现。
单一修改范围为既有 Apple 网络/创建调用、相关正式回归、既有请求 fixture 与五端
兼容记录；用户此前已授权后续同类 Mac API 缺陷修复。Mac App、移动、Android 不
扩新界面或写操作。Apple 共享行为受影响须 Mac 回归，本机缺 Swift 时明确未验证。
没有执行真实 VMM 写；所有本轮窗口/监听已清理，用户原标签页保留。

Apple 共享源码已固定 Network.set/delete 与 Guest.create 为 v1，并在不支持 v1 时
阻止写入；不再把 v2 读取协商结果用于这些方法。通用 callVoid 新增可选固定版本，
只在显式指定时校验名称/版本范围，其他调用不改。未挂载 ISO/USB 改为官方
unmounted；空启动介质不再选择 iso。既有删除 fixture 的 preferredVersion 改为 1，
原 resolvedVersion 本已为 1，旧测试只覆盖协商到 v1，未暴露此错误。

已将创建、网络修改、单项删除及统一删除结果四项 Swift 正式回归改为读取选 v2
但写入必须 v1，补 ISO/USB 空槽与 disk 断言，新增不支持 v1 时零请求测试。
本机 Get-Command swift 未发现工具链，因此这些 Swift 回归和 Mac 构建未运行，
没有 Mac 修复包，也不把 Windows 检查替代目标平台验证。
Windows dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore -v minimal 全量 3396 通过/0 失败/0 跳过；109 请求 fixture、3 响应/
22 私有引用、本地化和严格文档/差异检查通过。Windows 生产代码未改，不重复打包。
独立复核确认版本覆盖检查发生在写前且不自动降级重放；网络完整编辑/占用/未知
恢复和高级创建的完整字段仍需后续 Windows 切片。其他四端界面不扩范围，保留
所有用户改动，未提交/推送；这不是整个 VMM 功能已经完成。

#### 2026-09-20 传输通知生命周期与连接隔离

macOS 基线为 DsmMacApp.SystemTransferNotifier 的成功/失败通知，不增加跨重启历史。
Windows Dispose 未阻止再调用/未注销 SDK 注册，Show 失败错误重置注册标记，
路由子串匹配且新连接接受旧通知。本波限通知核心/Windows SDK 适配、MainWindow
路由复核及测试，不改权限、身份、注册方式、依赖或持久化。
依据 [Microsoft Register](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.appnotifications.appnotificationmanager.register)
规范，先订阅再注册、结束时 Unregister，不删除永久注册。随机本地连接上下文不含
NAS/profile/路径/凭据，点击精确匹配且排队后复核活动服务；SDK 调用在窗口调度器
串行执行。合成测试不注册真实系统通知、不发送通知中心消息。
PENDING_USER_VALIDATION：传输完成后点击通知进入当前传输页；切换 NAS/断开/退出后
旧通知不得路由到其他连接。通知关闭或注册失败不阻断传输，真实 OS 效果待用户验证。

已实现单一生命周期核心和薄 SDK 适配：通知显示失败不重复 Register，注册失败
解绑后允许下一条重试；销毁即时失效，排队显示/点击被取消，注册中销毁仍补注销。
使用 SDK 已解析的 Arguments 字典精确核对 route/context，不自行猜测转义编码，
不再接受旧版本无连接上下文的路由。MainWindow 在排队前连接事件到来时递增代次，
导航前及可见性等待后复核代次、服务引用和页面，关闭后不重新激活。

系统注册由 MainWindow 的应用级 backend 持有，启动时订阅/监听，连接服务只获得
和释放客户端引用，切换 NAS 不重复注册或注销应用监听；退出/销毁执行一次注销，
不调用 UnregisterAll。未连接时仍保持系统监听，旧连接通知不恢复已丢弃的内存
传输历史；冷启动保持普通启动/登录路径，不声称能够恢复旧传输。

新增 **16 项**确定性核心回归（注册/显示失败、顺序、重复销毁、排队、旧连接、
精确参数、注册中销毁、调度器拒绝和注销异常），聚焦核心/源契约共 **20 通过**。
命令 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
--no-restore --filter FullyQualifiedName~ForegroundTransferNotificationSessionTests|FullyQualifiedName~TransferActivitySourceContractTests。
最终 package.ps1 内全量 **3396 通过/0 失败/0 跳过**。

原生英文/中文各 **8 场景通过**（ui-review-20260920-183458 / 183759），命令
windows/tests/UiSmoke/run.ps1 -Scenarios notification-lifecycle -Language en-US
-WindowWidth 900 -WindowHeight 740，中文追加 -SkipBuild 并改 zh-CN。真实 SDK
Builder 生成带上下文的 XML，注册/显示使用合成后端；实际 MainWindow 路由覆盖
进入传输页、错误 route、旧上下文、销毁、连接代次改变、服务替换和退出的排队
隔离。移除未调用的隐式后端构造重载后，生产双架构重新构建；不声称执行了真实
通知注册、通知中心点击或冷启动 COM 验收。未更改其他四端或 NAS API。

独立集成/只读对抗复核确认：摘要不含文件名/主机/路径/凭据，上下文是本地随机
标识而非 NAS 会话；通知失败不改变传输结果，未增加永久数据或系统权限。原生
测试宿主不调用应用级 StartListening，避免污染系统通知注册。

最终独立包 windows/dist/20260920-183748，package.ps1 设置 both、RUN_TESTS=1、
LAUNCH_AFTER=0，双架构自包含 Release publish exit 0。build-info 架构、源提交/
dirty 状态、testsRun=true 已核对，App/Application DLL 不含合成场景或后端标记。
SHA256 与旁文件一致：

- x64：`2ACAB21CD3066E6B6F3618FDC5A45116CC09A560479B181D0DD925E4452DB853`
- arm64：`728CB92F14F4A34248ACEBDB353F9755CE763DDABEAF84B9B0CE6A85304D72FA`

资源完整性（Apple 4125/Android 2188/Windows 3247）、109 请求 fixture、3 响应/
22 私有引用、严格文档及差异检查通过。没有一次性抓包/调试文件；旧包和用户改动
保留，未安装或启动正式包，未提交/推送。VMM 高级能力、全范围对账和 Mac 修复
目标构建仍未完成，不把通知切片作为整个目标完成。

#### 2026-09-20 恢复云盘管理路由与显式测试入口

基线为 macOS DsmMacApp 的菜单栏/登录启动及桌面云盘管理；Windows 原
LanguageSettingsPage 已实现映射、缓存、离线保留、暂停/恢复、移除，但设置改版
后没有路由。本波复用该页并改名为 CloudDriveSettingsPage，删除重复语言设置，
由 AppSettingsPage 发出导航事件，Shell 负责绑定现有 AppViewModel，不新增平行
服务。单一范围为上述设置/路由、页面生命周期、现有注册门、资源与合成回归。
系统注册默认关闭，用户在云盘页确认只读测试范围后仅本次进程开启原能力门；不
持久化该开关，不自动新增映射；既有恢复器可能重连原映射，确认中明确说明。
不改变文件存储格式/权限/身份/API 契约。
真实注册、Explorer 回调、外接卷、重启仍为 PENDING_USER_VALIDATION：在可丢弃
NAS 目录验证只读打开、缓存/离线保留与移除；不得用普通文件上传结果类推。
权限、目录重叠、只读占位符、拒绝重命名/删除回调与移除确认保留。首次原生测试
只覆盖路由、空状态、确认/取消及失效页面，不触发真实系统注册或 NAS 写入。

恢复页单独绑定创建时的 profile，离页取消确认且解绑进度，返回重新加载时恢复
订阅；默认不允许系统注册，确认与已失效页面隔离。添加页新增明确登录启动选项，
默认不选；现有模型字段和其他调用默认不变，沿既有 Add 参数向下传递，不迁移数据。
已有云盘按钮/动作仍复用 AppViewModel 与服务，移除保留默认取消及确认后目标复核。
真实注册、离线与登录启动不以入口合成测试替代，后续继续用户系统验证。

最终源码已覆盖上述路由/会话测试确认；原 LanguageSettingsPage 两文件移动为
CloudDriveSettingsPage，不删除云盘操作，也不保留第二套语言设置。窗口使用既有
主题资源，移除旧程序化全局颜色引用；映射按钮纵向布局避免窄窗口溢出。
首轮编译发现 StackPanel 不支持 IsEnabled，改用可禁用的 ContentControl 包裹
映射区；首次确认测试的 150ms 固定等待早于关闭动画，改为等待确认生命周期结束，
保持原启用/取消断言，没有用跳过掩盖失败。

原生英文/中文各 **9 场景通过**（ui-review-20260920-181803 / 181928），命令为
windows/tests/UiSmoke/run.ps1 -Scenarios cloud-settings -Language en-US
-WindowWidth 900 -WindowHeight 740，中文改 -Language zh-CN 并追加 -SkipBuild。
覆盖浅深色空状态与确认、确认后可添加、取消不启用、返回/重入、离页关闭确认、
连接失效不启用、启动选项默认不选与确认不自动新增映射。已复核两种语言截图。
新增 1 项源契约并同步原设置架构断言，保留普通设置不读 Repository/凭据、不直接
写云盘约束，Shell 负责现有服务绑定。打包流程内 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore
全量 **3380 通过/0 失败/0 跳过**。本地化 Apple 4125/Android 2188/Windows 3247，
109 请求 fixture、3 响应 fixture/22 私有引用、严格文档与 diff --check 通过。
只读对抗复核确认不在确认前开启注册、不从设置页面直接创建映射、失效确认不能
改变能力、只读属性/拒绝删除重命名/重叠保护仍在；真实系统效果仍未验证。

最终独立包 windows/dist/20260920-181918，按既定 package.ps1 设置 both、
RUN_TESTS=1、LAUNCH_AFTER=0 完成 x64/ARM64 自包含 Release，exit 0。build-info
架构、testsRun=true、源提交/dirty 状态及新页面已核对，正式 DLL 无合成场景或旧
LanguageSettingsPage 标记。SHA256 与旁文件一致：

- x64：`A432E12AB0B3FB56677375454D1B32F2FEFB4C0E4161081D1C9838ADA88B00DF`
- arm64：`0BAB9A6717749CB183DB497449E5E7954D8F9D5E6D0BECA00B2E2D0B10DD1C30`

删除了本轮旧失败夹具的临时 smoke-failure.txt，失败原因和修正已在上文记录，
正式测试源码/回归产物保留。未安装或启动正式包，未提交/推送，所有用户改动与
旧包保留。下一独立切片为通知生命周期；VMM 与 Mac 修复目标构建仍未完成。

#### 2026-09-20 托盘恢复与窗口可达性

系统集成对账证据：macOS DsmMacApp.swift 的菜单栏提供返回窗口、暂停/继续映射与
退出；Windows MainWindow/TrayIcon 已有相应路径，但未处理 TaskbarCreated，
NOTIFYICON_VERSION_4 已启用却未处理键盘选择或校验回调图标 ID，且误拦截整个
窗口的 WM_COMMAND。此波唯一生产范围为 TrayIcon 与 MainWindow 关闭策略，保持
现有菜单、映射业务及资源键，不改系统注册门、登录启动设置、持久化或 API。
目标是 Shell 重建后恢复图标、正确鼠标/键盘激活，恢复失败时仍能找到窗口；
契约依据为 Microsoft [Taskbar](https://learn.microsoft.com/en-us/windows/win32/shell/taskbar)
与 [Shell_NotifyIconW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw)。
安全级别为本机系统集成，不对真实映射执行暂停/继续或退出，不重启 Explorer。
源码及正式原生宿主已覆盖自己创建的窗口/图标和合成通知消息，真实 Shell 重启后置。
PENDING_USER_VALIDATION：关闭主窗口后重启资源管理器，核对托盘恢复及键盘打开；
托盘不可用时窗口保留在任务栏。回传系统版本、步骤及脱敏错误，不提供设备资料。
云盘注册仍有独立实验开关，登录启动与通知生命周期需后续切片，不计作已完成。

本轮后续对账已找到具体而非推测的入口缺口：ShellPage 的两处设置路由都使用
AppSettingsPage，而云盘管理、缓存位置、逐映射登录启动仍只在 LanguageSettingsPage，
当前 Shell 不创建后者。DesktopCloudDriveService.UpdateLaunchAtLogin 已有 Run
注册实现，不能称为完全未开发；应先恢复管理入口并核对系统注册安全边界，不能
仅复制第二套模型或删除实验门。WindowsTransferNotificationService 的销毁后调用
与路由子串匹配也列入下一独立切片，本波不交叉修改。

已接 TaskbarCreated 恢复（先更新既有图标，缺失时添加并重新设置版本），保留
当前语言提示；处理版本 4 键盘选择与高位图标 ID，并启用标准提示。删去全窗口
WM_COMMAND 拦截，只分发本菜单返回的命令，暂停/问题动作再次核对可用数量。
Shell 暂时不可用不再令启动失败；图标重建失败唤回窗口，关闭时注册不可用则最小化
而非隐藏。Dispose 后不能注册或处理旧回调，仍移除图标、释放图标句柄及还原窗口过程。

中文原生 7 场景通过（ui-review-20260920-175921），真实调用本窗口 Shell_NotifyIcon
验证图标移除/恢复、重复广播、语言保持、鼠标/键盘回调、异图标拒绝、WM_COMMAND
旁路、菜单可用性、销毁和主窗口任务栏保底。失败分支用现有原生调用签名的委托
注入 false；生产默认仍直接调用 Shell_NotifyIconW，没有测试环境开关。
初版失败夹具错误假定关闭窗口立即使 Shell 更新失败，已改可控原生失败；关闭保底
改用 WM_CLOSE，而非直接销毁 Window.Close，保留原断言并实际验证最小化/可见性。
没有重启 Explorer、修改系统配置或对真实挂载执行操作。新增 5 项源契约保留这些
边界；最终全量、英文及双架构重建继续核对。175525 为原生复验收尾前中间包，
不是最终交付；包内两架构不能据此推断覆盖了后续修改。

最终英文 7 场景通过（ui-review-20260920-180050），与中文使用同一测试宿主。
命令为 windows/tests/UiSmoke/run.ps1 -Scenarios tray-lifecycle -Language zh-CN
-WindowWidth 900 -WindowHeight 740，英文追加 -SkipBuild -Language en-US。
windows/package.ps1 内 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
--configuration Release --no-restore 全量 **3379 通过/0 失败/0 跳过**。资源完整性、
109 请求 fixture、3 响应 fixture/22 私有引用、严格文档和 diff --check 均通过。
独立集成/只读对抗复核：回调图标 ID 隔离、非托盘命令转交原窗口过程、无映射菜单
动作不提交、失败保持窗口可达、销毁不复活均有原生证据；未改证书/会话、挂载或
登录启动注册。SDK 与最低系统版本、权限、存储、公共契约及其他四端均不变。

最终独立包 windows/dist/20260920-180039，both、RUN_TESTS=1、LAUNCH_AFTER=0；
双架构自包含 Release publish exit 0，testsRun=true、源提交/dirty 状态及正式 DLL
不含合成测试标记已核对。SHA256 与旁文件一致：

- x64：`30FB1F1A639BFB8E3FE8A457CDF32D199F7B6CC98BDBB474D1FE4B2EC5C12DA5`
- arm64：`2E0D533F3594185D0762AC319CB63C50AADB4E918B3DA0C89C806CD9D8F7820E`

无临时调试代码或抓包，正式合成回归保留，旧包及所有用户改动保留；未安装或启动
正式包，未提交/推送。下个独立切片为恢复云盘管理入口，不以此波完成全项目标。

#### 2026-09-20 文件夹上传完整范围与可取消准备

本波唯一修改范围为 Windows 既有文件夹上传规划器、传输接线、Files 页面相应状态、
双语文案及回归。macOS 证据为 WorkspaceView.presentUploadPanel：只选文件、多选、
不覆盖；文件夹选择是 Windows 已有流程的补缺，不虚构 macOS 已有递归选择器。
目标为移除客户端 20 文件/20 目录/8 层限制，保留完整确认、父目录优先、禁止链接、
不覆盖、未知停止和目标占用保护；准备/复查移至后台并可取消，确认对象冻结。
沿用公开 File Station CreateFolder/Upload 和现有结果核查，不改变五端 API 契约、
依赖、权限或持久化。安全级别为本地读取及用户确认后的普通写；不执行真实 NAS 写。
源码已实现以上流程；非目标是跟随链接、自动回滚或覆盖已有目录。
PENDING_USER_VALIDATION：在可丢弃目录上传超过旧限额的树，核对层次、数量、取消后
已完成项目保留及重复目标提示；只回传版本、步骤和脱敏错误，不回传真实文件内容。

规划器改为可取消迭代枚举、完整只读集合；确认后异步复扫并再次检查目标和权限，
防止等待期间切换目录仍写入。导航/离页/关闭/销毁取消准备并关闭确认框；已启动的
批次沿用独立取消，不因离页自动撤回。逐文件检查到选中根目录的父链，拒绝准备后
被换成联接的父目录；这是时点检查，不宣称抵御恶意进程在检查与打开间的原子竞态。
保持先创建全部父目录、严格不覆盖、未知目录立即停止、占用保护及已完成项保留。

新增 4 项并改写旧限额回归为完整范围断言：205 文件/35 子目录、16 层、只读集合、
准备/复查取消、相同元数据但父目录换成联接、240 项完整执行；原根/子目录联接
保护保持。首次聚焦 74 通过/1 条旧方法名源断言失败；同步方法名后，全量又发现
卸载事件旧整行断言，改为保留全部旧清理检查并新增准备取消检查，没有降低业务断言。
打包流程全量 **3374 通过/0 失败/0 跳过**。中文原生 12 场景通过
（ui-review-20260920-174418）：51 文件夹/206 文件、完整确认、全部执行、目录未知
停止、文件取消、选择器/准备/确认取消、关闭、源与目标变化零写入。首轮截图暴露
旧确认框不随深色主题，已设置实际主题并补原生断言、复验截图。英文 12 场景通过
（ui-review-20260920-174540），普通文件上传中文 12 场景复验通过（174722）。
命令为 windows/tests/UiSmoke/run.ps1 -Scenarios files-folder-upload -Language zh-CN
-WindowWidth 900 -WindowHeight 740；英文加 -SkipBuild -Language en-US，普通上传
改 -Scenarios files-upload-batch。只使用合成树和仓库，合成树已按所有权边界清理；
没有真实 NAS 写入。独立集成复核确认原权限/不覆盖/未知保护未削弱，目录与普通
文件共享流打开与结果映射，取消仅停止准备或后续项目，不删除已上传内容。

按既定 windows/package.ps1，设置 both、RUN_TESTS=1、LAUNCH_AFTER=0 完成
windows/dist/20260920-174520 的 x64/ARM64 自包含 Release，exit 0。首次打包
因当前命令 PATH 未包含已有 SDK 在恢复前失败；补充既有 SDK 路径后成功，无工具链
安装或升级。build-info 架构、testsRun=true、源版本与 dirty 状态已核对，正式 DLL
无合成仓库/场景/会话标记。SHA256 与旁文件一致：

- x64：`C1D1D4A1DC360F4342B91C9756F8D77A5E220350C01100D252694E3F15963CA9`
- arm64：`D02CA114A8CA9582DDFDE393CC88B7985D03728FE282FB98B34AD11B197A2BA4`

本地化（Apple 4125/Android 2188/Windows 3241）、109 请求 fixture、3 响应 fixture/
22 私有引用、严格文档与差异检查通过。保留既有用户改动及旧包，未安装/启动正式包，
未提交/推送。此波只完成目录上传限制切片，不将剩余 VMM、系统集成、全入口回归
或 Mac 修复包宣布完成。

#### 2026-09-20 Windows VMM 控制台窗口接入

沿用前波已验证的会话/页面边界，新增独立 WinUI 窗口、每窗口随机缓存目录和明确
InPrivate profile；运行时确认实际目录/隐私模式后才安装一次 Secure/HttpOnly/
SameSite Strict 会话 Cookie。原接口读取 HTML，保留服务器 CSP 并追加来源约束，
拦截外部导航/资源、弹窗、下载、外部协议、权限、客户端证书及证书错误。关闭/
断开时取消读取、删除本窗口 Cookie、关闭组件和清除内存文档；浏览进程退出后
才清理本窗口目录，不枚举其他会话或删除用户浏览资料。全屏不改变 VM 电源状态。

复用原证书模式门，不通过此窗口绕过固定指纹或系统信任失败。当前 SDK 为 WinRT
投影，初次代码误用 .NET CreateAsync/Stream，已改 CreateWithOptionsAsync 和
IRandomAccessStream，并纠正窗口句柄方法与继承成员名称冲突；生产 x64 编译已过。
下一步必须通过实际浏览组件合成回归与关闭/隔离检查，再提供可测试包；不把编译
当作 WebView2 或真实 NAS 控制台验收，不修改 Mac 或移动范围。

首轮真实组件 12 场景通过（ui-review-20260920-164142），含加载/错误/无能力/关机、
实际 InPrivate 属性、Secure/HttpOnly/Session/Strict Cookie、服务器与应用 CSP
共同阻断 WebSocket/fetch/图片/worker、弹窗阻断、外部导航后释放、文档加载中关闭、
重新打开独立目录及目录退出清理。截图分为 WinUI 窗口壳与 Core CapturePreview
网页图，不能把 RenderTargetBitmap 不包含浏览表面的空区当作网页已验证。
人工查看发现深色窗口壳错误使用 Application 作用域背景，改用窗口内 ThemeResource
引用；补全屏实际 presenter 断言。首次全量唯一失败是旧源契约仍断言不得出现 Console，
按本波已实现入口替换为安全约束检查，保留其他未实现操作及诊断信息拒绝断言。

最终全量 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
-p:Platform=x64 --no-restore -v minimal **3370 通过/0 失败/0 跳过**。本窗口新增
目录隔离 2 项和窗口源契约 1 项，基础层的 45 项保持；实际组件首轮中英文各 12
场景通过（164708 / 164946）。收尾补错误恢复说明及证书挑战独立反馈后，中文
12 场景重验通过（ui-review-20260920-171120），英文与最终独立包重建中。
165711 为该文案调整前的中间包，未安装/启动；最终交付以下方重建记录为准。

PENDING_USER_VALIDATION：使用系统信任证书连接、可访问 VMM 的账号及正在运行的
可丢弃 VM，打开控制台并核对目标，验证画面/键鼠/布局、全屏、断线提示与关闭；
关闭只结束控制台，不发关机操作。固定指纹模式保持明确限制，不引导忽略证书。
浏览组件缺失时显示恢复说明，不自动安装或更改系统设置。iPhone/iPad/Android
不扩范围，Mac 前波源码仍待目标构建。只回传版本、步骤和脱敏错误，不回传画面、
Cookie/会话或真实 VM 身份。无真实控制台连接、NAS 写入、提交或推送。

最终英文 12 场景通过（ui-review-20260920-171350），与中文使用同一宿主，命令
windows/tests/UiSmoke/run.ps1 -Scenarios vm-console -Language zh-CN/en-US
-WindowWidth 900 -WindowHeight 740，英文追加 -SkipBuild。检查了错误恢复说明、
深浅色窗口壳和独立浏览页面截图；实际组件测试不是凭截图判断浏览会话已隔离。

最终按既定 package.ps1 双架构/运行测试/不启动设置完成独立包
windows/dist/20260920-171400，exit 0；包内 3370 项全通过，x64/ARM64 自包含
Release publish 成功。build-info 的 testsRun=true、架构、版本、源提交加 dirty
均核对，生产 App DLL 不含合成仓库/场景/合成 Cookie 标记。SHA256 与旁文件一致：

- x64：`A54B6EF262F91692AB32FE348E73F06751A4FBC49F227C41AD274C2C804C6C22`
- arm64：`7640107A4FFF4E5D4F2B09A5F10CF5E1B10CDEC6F1ECD81BA54FA511B38D2830`

资源完整性（Apple 4125/Android 2188/Windows 3242）、109 请求 Fixture、3 组响应/
22 私有引用、严格文档与差异检查通过。未安装/启动正式产物，旧包保留，未提交/
推送。系统信任控制台切片已具备用户验证入口；固定指纹模式、VMM 高级创建、网络
修改/删除和其他收尾仍未完成，整个目标保持不变。

#### 2026-09-20 Windows VMM 控制台会话与读取边界

Mac 非持久 WKWebView 控制台和既有同源 noVNC 静态记录为语义基线。Windows 已有
WebView2 依赖，但普通资源事件不能覆盖 WebSocket，证书错误事件不能对所有系统
信任证书执行既有固定指纹策略。先建立会话、页面读取及来源策略，再接独立窗口；
不能只加网页控件或把 SID 拼进 URL 就算对齐。使用既有 HttpClient/证书链读取
HTML，保留服务器 CSP 并追加精确同源 connect-src；不新建弱校验网络客户端。
浏览器接入仅允许本次连接实际使用系统证书验证的模式，固定证书模式不得向浏览
组件传凭据；这是真实安全能力缺口，不是因待真机验证关闭所有入口。

本波唯一修改范围：VMM 控制台领域/会话准备、既有网络层有界文档读取、连接组合根
的信任模式传递与聚焦测试。默认接口兼容关闭，仅明确受支持的生产连接可准备会话。
不新增依赖、系统权限、持久化或身份；不连接真实 VM，不自动放宽证书，不修改 Mac。
窗口、浏览器钩子、会话关闭/临时目录清理与原生回归为后续集成依赖，整体目标不变。

基础层已新增 44 项控制台测试和 1 项实际证书上下文测试。全量首次出现证书请求
源清单遗漏新增 HTML 请求的 1 项失败；将新源文件及上下文赋值纳入既有精确清单，
保留全部断言并补实际传输验证，最终全量 3367 通过/0 失败/0 跳过。命令为 dotnet
test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64
--no-restore -v minimal；随后 App x64/ARM64 build -c Release -p:Platform=<架构>
-r win-<架构> -p:LanStashStandalone=true --no-restore 均 0 警告/0 错误。
只验证准备、来源/凭据、HTML 类型/大小、CSP 组合、取消及迟到清理，不代表窗口。
基础层未生成新包，前波可用包仍为 20260920-154108。

#### 2026-09-20 Windows VMM CPU 优先级

以 Mac 五档修正及 2026-09-20 官方读取/静态写契约为依据，在现有设置窗口接 CPU
优先级。读取补内部 Guest.get v2 并绑定公开快照身份/字段，失败仅使优先级不可用；
认证/证书异常不能吞掉。普通设置仍走公开 Guest.set v1。只有明确改动优先级时，
将本次所有改动作为一次内部 Guest.set v1 提交（name/desc 等使用已记录内部键），
避免两次不同接口写入产生中间状态；同源内部 get 核查，不把公开字段回显当证据。
复用原设置确认、签名、防重复和 VMM 模块协调器/恢复；不新增独立编辑器或平行保存
状态机。字段默认 null，创建流程不支持该字段时明确拒绝，不能泄漏到公开 create/set。
Windows 向后兼容模型/接口增量按既有授权实施；其他四端不改，实际 NAS 不保存。
API 能力、字段读取、逐次确认和服务端权限拒绝仍生效，不因待实测永久禁用入口。

已接兼容 CpuWeight 字段、CanEditPriority 与五档下拉；既有非预设原值保留显示，
不能把未知当默认值。读 API 元数据须同时支持 get v2 / set v1 才能编辑。内部完整
读取需原生 ID/名称/说明/整数 CPU/内存/三态启动/布尔在线状态/整数权重，与公开
快照一致才提供优先级。基本修改不依赖附加读取成功，不发送 cpu_weight 或内部
参数；有优先级修改时全部改动映射内部键，并以同一内部来源逐字段回读。认证、
证书与取消在附加读取时不吞掉。原协调器统一保护电源/创建/删除/设置，未知保存
仅核查、不重发；重用请求身份不能改变优先级或跨操作。创建验证拒绝编辑专用字段。

新增后端含共享 Fixture 21 项、模型 2 项，共 23 项；覆盖 FORM/JSON、五档、自定义
原值、完整快照变化零写、缺能力/版本零写、缺失/畸形/异身份读取、认证、取消、
明确拒绝、未知恢复/互锁、普通设置公开路由及内部单次组合提交。初次新增测试因
局部变量 code 与原夹具变量重名编译失败，已改名；终态拒绝测试起初错误地要求
Review 返回已移出 pending 的记录，已按既有契约改验同 request 重复 Save 返回
原终态且 Review 为 null，保留不重发与不伪成功断言。原生脚本新增区块的插入位置
经源码复核移回设置场景，未削弱断言。全量 dotnet test windows/tests/LanStash.Tests/
LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal **3322 通过/
0 失败/0 跳过**。本地化（Apple 4125/Android 2188/Windows 3225）、109 请求 fixture、
3 组响应/22 私有引用、严格文档预检和 git diff --check 通过。

PENDING_USER_VALIDATION：在备份后的可丢弃 VM 打开编辑，查看当前档位，单独或与
名称/说明一起改优先级并确认；应一次保存后核对，权限拒绝不显示成功，断线后
仅核查。运行中优先级可编辑但 CPU/内存停机限制仍在，缺少优先级读取/写能力时
基本编辑保持可用。只回传版本、步骤、计数和脱敏错误，不回传 VM 身份或会话。
没有真实 NAS 保存、依赖/签名/身份/存储迁移、提交或推送。

原生使用 windows/tests/UiSmoke/run.ps1 -Scenarios vm-settings,vm-create -Language
zh-CN -WindowWidth 900 -WindowHeight 740，最终中文 **39 场景通过**
（ui-review-20260920-153936）；包括本波新增 8 项优先级场景及原设置/创建回归。
人工查看深色优先级表单，五档选择、原值保留、确认及默认关闭可见；英文同宿主
-SkipBuild 复验中。独立只读复核确认内部/公开键路由分离、创建不泄漏编辑字段、
同源完整回读、附加读取降级边界、认证/证书抛出及未知互锁，没有自动重试写入。

既定 windows/package.ps1 设置 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0，完成独立目录
windows/dist/20260920-154108，exit 0；包内全量 **3322 通过/0 失败/0 跳过**，
x64/ARM64 自包含 Release publish 成功。build-info testsRun=true、架构、源
main@0eeeb170358c 加 dirty 已核对，生产 App DLL 无合成宿主/场景标记。SHA256
实算与旁文件一致：

- x64：`AADF4806F21EF5653C70C3D5197B4F194C137DFBAEFE6DB6A09830C6B679CC8D`
- arm64：`4CC89E76B0BDB5003AABB2638327B9FD3039231655C0C99DCFE70EB69608B8B2`

未安装/启动，旧包保留；Apple 前波修复仍未编译，不以 Windows 回归替代。后续
仍有固件/启动介质、控制台和其他高级管理；当前项目资产清单已包含 WebView2
1.0.3719.77，控制台可先评估现有依赖，无需预先新增浏览组件包，但认证/证书/
同源导航/临时会话隔离尚未实现和验证，不因此宣布控制台可用。

最终同宿主英文 **39 场景通过**（ui-review-20260920-154314），命令追加
-SkipBuild -Language en-US；人工复核英文深色优先级表单的五档当前选择、确认和
保存入口，未发现截断。双语、109 fixture、22 私有引用、严格文档及差异检查均
在收尾重跑通过；本波仅关闭该功能切片，不缩减或完成整个平台对齐目标。

#### 2026-09-20 VMM 官方只读核查与 Apple 设置语义纠正

按发现规范建立 2026-09-20-vmm-parity-read-observation 环境快照，再通过用户已登录
Chrome 观察官方页面。当前 DSM 7.2.1-69057 Update 12、VMM 2.6.5-12202，管理员，
设备待归属；不复用旧 lab-a 归属。已观察 get v2、get_setting v1 及能力 JSON 元数据，
set v1、CPU 五档与 autorun 三态来自官方已加载脚本，仅为 static 写契约线索。
没有点保存/开关机/删除/控制台连接；编辑已取消，窗口关闭，临时监听关闭。

发现 Mac 自动启动开关把 true 写成 autorun=1（实际为恢复原状态），CPU 权重三档
128/256/512 不等于官方五档 8/64/256/512/1024。按用户授权修复同类 API 偏差，先
纠正 Apple 共享领域/解析、Mac 创建/编辑与移动只读显示；移动端不新增写入口，
Windows 公开自动启动三态已正确，CPU 优先级/其他高级配置仍为后续 Windows 缺口。
Android 仅记录影响，不改源码。兼容增量保留旧布尔构造参数，新增稳定三态枚举；
没有持久化结构、签名、依赖或最低版本变化。新字段不能用未知默认值覆盖 NAS。

已补 VirtualMachineStartupBehavior（0/1/2）与兼容的可选构造参数；创建旧 true 明确
映射 2。Mac 创建/编辑均显示三态，优先级五档；未读取到的字段保留未知，非预设的
既有权重保留显示而不因其他更改重写。解析只接受原生整数，拒绝 bool/字符串/小数
冒充策略或权重。内部 Guest.set 固定 v1，能力范围不含 v1 时不发送请求；仍沿用
同源 Guest.list 严格核查全部字段，不用公开值/默认值替代内部回读。

iPhone/iPad 的只读详情投影保留三态/未知，字段白名单仅替换原布尔字段，未新增写
入口。Windows 原公开三态不改；Android 仅记录复核影响，不改源码。新增 JSON
合成 Fixture vmm/update-guest/synthetic-startup-priority/request.json，来源标为
sourceReviewed，不冒充本机已保存。回滚仅恢复源码，未改变持久化或设备设置。

新增测试方法：共享网络 6、领域 2、Fixture 1、移动投影 1，共 10。旧测试中 bool
响应、128 权重和 true→1 的错误基线按官方语义纠正，保留全部请求/回读断言，并
新覆盖原生三态、未知/非法类型、五档/高档、固定版本与零写拒绝。实际执行
swift test --package-path apple --filter 'VirtualMachineStartupBehaviorTests|DsmServiceManagementRepositoryTests'
仍失败：本机无 swift 命令；上述测试、Mac 构建与 iPhone/iPad 模拟器均未运行。
未安装工具链、未生成 Mac 包，不能把静态门禁当作 Swift 测试通过。

实际静态门禁：tools/localization/check_localization.py（Apple 4125 / Android 2188 /
Windows 3215）、tools/request-contract/validate_contracts.py（109 请求 Fixture）、
tools/contract-validation/validate_fixtures.py（3 组/22 私有引用）、
tools/codex/check_documentation.py --strict-release 与 git diff --check 通过。
只读集成复核了新字段调用链、旧参数兼容、未知值不写、UI 各资源和方法版本边界；
浏览器原始数据未落盘，临时监听关闭、会话内观察变量已清空，没有提交/推送。

PENDING_USER_VALIDATION：Apple 工具链先运行共享/Fixture/移动投影及 Mac 回归，
构建独立测试包；在可丢弃 VM 验证三态读写和五档优先级，保存后刷新应保持对应
选项，编辑名称不应改变未知/原有策略或权重。iPhone/iPad 只验证读取与详情显示，
不出现保存或电源入口。只回传系统/套件版本、步骤与脱敏错误，不传资源身份或会话。
Windows CPU 优先级、固件/介质、控制台的后续实现须引用本次独立记录，不复制
Mac 历史错误；完整目标未完成。

跨端回归实际执行 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release -p:Platform=x64 --no-build --no-restore -v minimal：3299 通过/0 失败/
0 跳过；仅为未改 Windows 二进制及当前共享 fixture 的回归，不替代新增 Swift
测试、Apple 构建或真实 NAS 保存。本波未重新发布 Windows 包，当前可用包仍为
20260920-140339；新增 Apple 修正不在该 Windows 包内。

#### 2026-09-20 Windows VMM 创建后开机

Mac CreateVirtualMachineSheet 的 powerOnAfterCreation 为基线，Windows 创建请求与
向导尚无等价选项。本波增量接可选开机，复用现有公开 Guest.Action v1 和电源状态
核查；不复制 Mac 内部 poweron_after_create 参数。默认不选，确认绑定完整配置；
只有创建身份、资源和配置均已确认后才能开机。后台核对只读，恢复后新增写必须重新
确认，未知不重放。映像来源未确认时仍不自动开机。唯一修改范围为 VMM 创建/共用
电源提交、创建向导及回归和双语资源；不改其他端代码、身份、依赖、存储或实际 NAS。
五端契约只受 Windows 向后兼容选项影响，其他四端无 Schema 迁移。高级硬件/ISO/
控制台/网络仍独立未完成，不以本波替代整个创建能力对齐。

已接默认 false 的 PowerOnAfterCreation、PowerOn/VerifyPower 阶段和向导复选框，
摘要明确开机选择；修改选项撤销旧确认。仅新增一次公开 poweron，复用原电源提交
及核查代码，原 create/set 不带内部开机参数。不具备电源能力时仍可普通创建，若
请求包含开机则在创建前拒绝。创建资源或配置变化、映像来源未核查时不自动开机。
初次已确认流程可继续开机；只读恢复只返回待确认阶段，Continue 需新确认。开机
未知不重放，CreationPending 继续保护任务和 VM；明确拒绝保留已创建 VM，不回滚。

新增后端 9 个用例和模型 2 个用例；固定 FORM/JSON、单 ID、版本、顺序、缺能力
零创建、恢复确认、未知/取消不重发、任务保护、删除互锁、映像来源及 nonce 绑定
均有覆盖。命令 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release -p:Platform=x64 --no-restore -v minimal --filter FullyQualifiedName~VirtualMachine
为 **252 通过**；同工程 --no-build --no-restore 全量 **3297 通过/0 失败/0 跳过**。
原生初次发布因 VmCreatePowerUnavailable 与其 .Text 同时定义触发 PRI278；改用
独立校验提示键后重新发布成功，未改资源生成流程或跳过原生构建。

资源完整性检查通过（Apple 4115 / Android 2188 / Windows 3215）；108 请求 fixture、
3 组响应/22 项私有引用和严格文档预检、git diff --check 通过。原生向导增加 6 个
场景，检查选项改变撤销确认、开机成功、恢复确认、未知只读和缺电源能力仍可创建。
中文全 22 场景已通过（ui-review-20260920-135445）；截图发现测试宿主滚动时布局
尚未稳定，补 UpdateLayout/BringIntoView 和确认框完整可见断言，不改生产界面。

PENDING_USER_VALIDATION：使用可丢弃 VM 和明确空白盘，在创建向导勾选创建后开机，
确认配置并提交；应先确认创建及设置，再开机，运行状态得到核查才显示全部完成。
验证慢任务恢复后须新确认开机、断线/关闭后只读核对、权限拒绝后 VM 仍保留、任务
记录未过早清理。映像盘来源核查未完成时不自动开机；高级硬件/安装介质仍待后续。
只回传版本、步骤、计数与脱敏错误，不回传真实 VM/任务 ID 或凭据。无真实 NAS 写。

既定 windows/package.ps1 双架构、运行测试、不安装启动设置完成独立目录
windows/dist/20260920-135556，终态 exit 0，打包内全量 3297 通过/0 失败/0 跳过。
两个 build-info 均为 Release、自包含、testsRun=true、main@0eeeb170358c 加未提交
改动；App DLL 不含合成仓库/场景标记。ZIP SHA256 与旁文件一致：

- x64：`D0C26BE78329ACF61DC0014CFC9CA9051BD61E67ABBBB6C76E3B12E58367E5AB`
- arm64：`ABFB75E886F81971ADCB090DFD03E860E3173687008D89EB2FBB5DAB66C4B7C1`

未安装/启动、未提交/推送，旧包保留；Mac 前波修改仍未目标构建，不冒充 Mac 新包。

首轮英文 22 场景通过（ui-review-20260920-135721），滚动断言补验中文 3 项通过
（135950）。随后的文案复核发现待开机阶段主按钮仍叫“继续配置”，已改用现有
“开机”资源；勾选确认明确涵盖所选创建/设置/开机。并修正继续开机异常的阶段反馈，
认证失效停止自动核查，仍保留人工只读恢复。新增模型 2 项回归；最终 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64
--no-restore -v minimal **3299 通过/0 失败/0 跳过**。因此 135556 是中间包，须以
下方最终重建记录为准；没有对它自动安装或覆盖。

最终沿用同一打包命令和双架构/测试/不启动设置，生成 windows/dist/20260920-140339，
exit 0；包内 3299 项全通过，两架构自包含 Release publish 成功。核对 build-info
testsRun=true、架构/源提交及 dirty 标记，生产 App DLL 无合成宿主标记。SHA256：

- x64：`A4259BA8C2F76C937D4D07C85298F0BCCA64B7AE7867DA10D8B74A1A0098A31D`
- arm64：`DA96DC75DFDF6449327F90358E247607C85CCF576E74832B61C0BB4E75962CC8`

ZIP 实算与旁文件一致，未安装/启动，旧包保留。最终中文 22 场景通过
（ui-review-20260920-140245），包含确认框完整可见断言，英文以同一宿主复验。
独立只读集成复核确认：PowerOnAfterCreation 纳入请求签名，选项变化不能复用
旧确认或请求身份；创建协调器持有未知开机记录，任务清理/删除不会越过保护；
共用单次提交不产生平行 API 实现，后台 Review 不自动开机，明确拒绝不被后来的
运行状态覆盖。没有真实开机、提交、推送或 Mac 新构建。

最终英文 22 场景通过（ui-review-20260920-140522），人工核对英文深色确认摘要及
完整确认框。最终双语命令均为 windows/tests/UiSmoke/run.ps1 -Scenarios vm-create
-Language zh-CN/en-US -WindowWidth 900 -WindowHeight 740，英文追加 -SkipBuild。
累计本波新增 13 个单元用例和 6 个原生场景；目标构建与合成闭环完成，真实设备
验收仍独立，不据此宣布整个 Windows/macOS 对齐已完成。

#### 2026-09-20 Apple VMM 公开电源请求纠正

再次核对 Mac ServiceManagementModel/ServiceManagementView 与共享 Repository，发现
公开电源仍把多个 guest_id 拼成逗号值，并发送官方 v1 未列出的 reboot；收到回执即
报告完成，没有资源状态核查。这属于用户已授权修复的同类 API 偏差，不扩大为新的
Mac 功能。以官方 VMM 指南 Guest.Action v1 单目标 poweron/shutdown/poweroff 和
Guest.get 为依据，修正公开请求、完整目标预检、逐项提交和未知不重放；不将重启
替换为强制关机/开机，不复制未记录的内部参数。共享 Apple 修改向后兼容，Mac App
仅按必要修复范围处理；Windows 已有对应公开实现，Android/iPhone/iPad 不扩功能。
高风险电源仅做源码/合成测试，Agent 不操作真实 VM。Swift/macOS 构建条件另行报告。

范围复核：Mac 当前映像页只有删除，没有导入入口；映像导入不能算作该页现有功能
的缺口。已有专项计划中的导入扩展保留独立范围，优先补实际基线缺口。Mac 创建仍
有系统类型/固件/ISO/创建后开机，编辑有优先级，网络写及控制台尚未完成 Windows
等价闭环，整体对齐目标未完成。

已修共享公开分支：固定 Guest/Guest.Action v1，完整目标 get 预检后逐项复核身份/
名称/状态，仅单 guest_id 写；空成功响应后以同一公开 get 确认目标状态。状态仍在
变化或读取失败时不报告已完成，停止余项，当前 Repository 内保留未确认身份和动作。
再次选择同一操作只读核对，不提交未知项或顺带继续余项；相反动作、删除和编辑被
未确认电源结果保护。明确拒绝保留错误，不回读伪成功；证书异常不降级，取消保留
未知证据。在途电源与公开删除互斥，确认弹窗绑定选择，模型拒绝确认后选择变化。
公开 restart 返回通俗的系统内重启替代提示，不猜 reboot、不强制关机再开机；原
内部电源分支未改，内部重启契约与 Windows 对齐仍是独立未完成项。

新增网络测试 11 个方法（含 FORM/JSON、三动作、多台/去重、固定版本、非法身份、
完整预检、畸形读取、改名、丢回执、未知只读、反向/删除/编辑保护、认证、取消与
在途重复），Mac 模型测试 2 个方法（选择变化零提交及固定确认身份）。五条双语
提示只进资源。实际执行 swift test --package-path apple --filter
DsmServiceManagementRepositoryTests 失败：本机找不到 swift 命令；未运行上述 13
项，不将静态检查或 Windows 包视作 Mac 验证。没有依赖/签名/存储/公开模型变化。

本机静态门禁：tools/localization/check_localization.py（Apple 4115 / Android
2188 / Windows 3207）、tools/request-contract/validate_contracts.py（108 fixtures）、
tools/contract-validation/validate_fixtures.py（3 组/22 引用）、
tools/codex/check_documentation.py --strict-release 与 git diff --check 通过。
只读集成复核检查请求前的整个集合验证、直接 client.callVoid 不自动重试、取消后的
记录保留、跨操作保护、认证/证书反馈及资源完整性；不等同编译或实机结论。

PENDING_USER_VALIDATION：Mac 目标先运行共享及 ServiceManagementModelTests，生成
独立测试包后，使用可丢弃 VM 验证单台/多台开机、正常关机、明确确认的强制关机。
核对过渡态提示、断线后同操作只核对、尾项不自动继续、确认期间改选择零提交。
记录只在本次仓库实例内；重新连接前须在 NAS 网页确认状态。仅回传版本、步骤、
计数和脱敏错误，不回传 VM 名称/凭据。没有真实 VM 电源操作，没有 Mac 新包。

#### 2026-09-20 Windows VMM 映像删除

依据 Mac 映像多选删除语义及公开 Guest.Image.delete v1 修正后的基线，补 Windows
映像选择/确认/逐项删除/只读核对。复用 VMM 协调器、删除回读和批次窗口，映像与
VM 目标保持显式类型，不伪装成关机 VM。保护创建流程正在引用的源映像，未知删除
阻止新的映像引用；不猜测公开接口未提供的磁盘关联字段。范围限映像删除与正式
回归/双语文案，其他四端不改，不删除真实 NAS 数据；导入/高级配置/控制台仍后续。

已接独立公开映像读取、CanDeleteImages、单 ID DeleteImageAsync、未知清单及只读
核对；固定 Guest.Image v1，不依赖 Guest/Guest.Action 能力，不请求任务 ID。
原始 ID 必须为无重复的原生字符串；预检完整目标摘要含 ID/名称/类型，变化则零写。
删除后仅以同一公开映像清单确认消失，畸形列表不冒充空；明确拒绝不读回伪成功。
VM 与映像共用删除完成核查，但使用独立资源范围，相同请求身份不能跨资源复用。

创建中的源映像受保护；未知映像删除反向阻止新建 VM 引用该映像。共用批次模型
改为显式 VM/映像目标，映像不伪装成已关机 VM；映像模式只加载其分区，不因无关
VM 读取失败停用。1/205 项完整选择、确认、逐项结果、取消/未知/拒绝停止及只读
恢复沿用公共交互，单独映像风险文案。映像列表入口及加载/空/错误状态保留原生布局。

初次编译发现聚合 Repository 中容器映像已有同名成员，VMM 改用显式接口实现和
带 VirtualMachine 前缀的内部入口，不更改容器逻辑。旧批次目标转换后遗漏的一处
提交前变量已按编译前源码检查修正。新增映像后端 12 项、创建源保护 1 项、批次
状态 5 项和入口源契约 1 项，共 19 项；全量 dotnet test windows/tests/LanStash.Tests/
LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal **3286 通过/
0 失败/0 跳过**。FORM/JSON、固定版本、空响应、身份变化、畸形回读、取消、拒绝、
未知/不重发、跨资源请求身份、双向创建保护及不依赖无关 VM API 均覆盖。

PENDING_USER_VALIDATION：使用可丢弃 disk/ISO/Virtual DSM 映像，备份后确认单项和
多项删除；检查使用中/权限不足、网络中断及核对操作。预期没有 Task.Info 轮询，
只有同一公开列表确认消失才成功，未知不重发，核对不继续剩余项。公开接口不提供
全部 VM 磁盘来源关系，实际占用仍由 NAS 检查；不猜测关系或绕过拒绝。只回传版本、
步骤、计数、脱敏错误，不回传真实映像或凭据。没有真实 NAS 删除、提交或推送。

最终中文原生 49 场景通过（ui-review-20260920-132152），同一宿主英文 49 场景
通过（ui-review-20260920-132635）；命令 windows/tests/UiSmoke/run.ps1
-Scenarios vm-image-delete,vm-delete,vm-power-batch -Language zh-CN，英文追加
-SkipBuild -Language en-US -WindowWidth 900 -WindowHeight 740。人工查看双语深色
映像确认框，完整 205 项选择、风险勾选与默认关闭可见，原 VM 删除/电源回归保留。

既定 windows/package.ps1 双架构、运行测试、不安装启动设置完成独立包
windows/dist/20260920-132646，打包全量 3286 通过/0 失败/0 跳过，终态 exit 0。
两架构 build-info 均为 Release、自包含、testsRun=true，main@0eeeb170358c 加
未提交改动；App DLL 不含合成仓库/场景标记。ZIP 实算 SHA256 与旁文件一致：

- x64：`0828F6817487419FCEEEB9ECF7039EA2BB83A4CC047CFE2B72AD7890E2227F94`
- arm64：`E6BDE6457600966A8ABFA7B1584F77CA8CC9BE7EB328B4A45F320B0C42AEA099`

没有安装/启动、提交/推送或真实 NAS 删除；旧包保留，不能替代 Mac 目标构建。

#### 2026-09-20 Windows VMM 已结束任务清理

既有 Windows Task.Info v1 list/get 和创建结果核查为事实基线，当前只读任务页缺少
已列入计划的 clear 闭环。此项是 VMM 任务管理完善，不冒充 Mac 已有任务页。范围
为公开 Task.Info.clear 的确认、冻结摘要身份、终态与结果核查依赖预检、只读恢复
及原生任务页；不删除 VM/映像，不调用 Guest/Guest.Action 写接口。使用现有 VMM
模块互斥保护创建任务证据，原始任务 ID 不暴露到领域/UI/持久化。契约兼容扩展按
既有授权实施，其他四端只记录影响；不清理真实 NAS 任务。

已接固定 v1 单 task_id 的 clear、完整 list/get 预检及 list 消失核查；没有引入
Guest/Guest.Action 写操作。只清理用户确认的已结束身份，后续新增任务不扩大范围，
目标变为运行中/消失或仍用于创建资源核查时，在任何 clear 前停止。每项提交前再
核对终态；未知、明确拒绝和取消停止后续项，结果分别统计已清理/失败/待核对/未开始。
请求身份去重与所有 VMM 写操作共用协调器；未知清理重开后仅 list 核对，不重发或
自动处理未开始项。任务摘要只增加保护标志，原始任务标识仍不进 UI、结果或持久化。

保护采用真实的 CreationPending.TaskId，而不是任务已经 finish 就认定资源结果
已核查。清理记录按现有 ServiceScope（配置 ID、用户名、地址）隔离，同账号重新
登录保留只读恢复；不将 SID 轮换当成新清理授权。初版测试误以为现有 scope 绑定
SID，查源码后补独立跨配置隔离及同账号重新登录不重发测试，未放宽隔离断言。
创建保护夹具最初使用了不一致任务 ID，已改为实际返回的合成 ID。

原任务页新增清理确认/核对入口，确认期间暂停刷新以冻结数量；离页或关闭取消本地
等待，迟到结果不覆盖界面，仍可刷新出待核对记录。保护任务保持只读说明。初版
原生核对场景在按钮更新前调用导致宿主退出，修正为等待原生按钮可用，并将夹具的
“可核对成功”与“已经消费记录”分开。原生断言保留，未改为直接调用模型规避按钮。

新增 Repository 8 项、状态 4 项、创建保护 1 项及入口源契约 1 项，共 14 项；覆盖
FORM/JSON、冻结范围、尾项变化零写、未知/重开/不重发、取消/拒绝、畸形回读、跨
配置隔离、重新登录只读恢复、无确认零写、关闭/隐藏迟到结果及保护记录。全量命令
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64
--no-restore -v minimal 为 **3267 通过/0 失败/0 跳过**。原读任务测试继续通过。

PENDING_USER_VALIDATION：在 VMM 任务页确认已结束的可清理记录，验证仍在运行和
用于待核对创建结果的记录不会清理，新增记录不会加入已确认批次，失败/断线后核对
不重放 clear。仅清理元数据，不应删除 VM/映像或停止任务。原始任务 ID 可能包含
账号信息，不回传；只回传版本、步骤、计数及脱敏错误。其他四端无本波源码改动。

最终英文 900×740 原生清理 12 项及原任务页 10 项共 **22 场景通过**
（ui-review-20260920-130135），同一宿主中文 **22 场景通过**（130431）。命令
windows/tests/UiSmoke/run.ps1 -Scenarios vm-task-cleanup,vm-tasks -Language en-US
-WindowWidth 900 -WindowHeight 740，中文 -SkipBuild -Language zh-CN。人工查看
清理确认及恢复反馈，发现透明控件单独截图缺少背景，仅调整测试宿主改截完整页面，
生产 UI 不变；针对核对/只读/保护状态另行补验。独立只读复核确认 clear 的新鲜
终态与证据保护先于写，同账号重登录只能核对旧请求，原始 task_id 不进入结果。

按既定 windows/package.ps1，以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成 windows/dist/20260920-130441，
终态 exit 0。包内全量 **3267 通过/0 失败/0 跳过**；x64/ARM64 自包含 Release
publish 成功，build-info testsRun=true、main@0eeeb170358c 加未提交改动；App DLL
无本波合成仓库/场景入口。SHA256 与旁文件一致：

- x64：`B644EFCA63B6D44595F1A42CE9811E1DE3ABB5755C7EA1EB2B2606EBC513C595`
- arm64：`80E368E26B5803A23F57FC3A8470DCDA10E36761DF19F365A6010C591C20122D`

未安装/启动、未提交/推送、未清理真实 NAS 任务；旧包保留。Mac 前波修复仍待目标
构建，本波 Windows 测试和包不能替代 Apple 验证。

完整页面截图的英文补验 3 项通过（ui-review-20260920-130742）：核对结果、只读、
仅保护任务。仅修改正式测试宿主截图范围，生产包不受影响；最后静态门禁通过。

#### 2026-09-20 Windows VMM 删除闭环

Mac 删除多选语义与已修正的官方 Guest.delete v1 为基线；Windows 尚无删除入口。
本波补单台/多台共用确认窗口、停止状态/身份预检、单 ID 空响应删除、严格资源列表
回读和只读恢复，复用 VMM 现有模块互斥与批次状态/呈现，不复制新的电源后端。
危险删除只在真实能力、会话、逐次确认和预检满足时开放用户入口；Agent 不删真实
VM。契约增量按既有授权实施，其他四端不改代码；任务、控制台和映像删除不混入。

已接 DeleteMachineAsync/GetDeletionRecoveriesAsync/ReviewDeletionAsync，旧接口
实现默认不支持；生产入口按已认证会话及公开 Guest v1 能力开放。只接单 guest_id
POST 删除，接受空成功，不读取 Task.Info；提交前重新 get 核对稳定身份、名称及
shutdown，回读使用同一公开 list，完整原生字符串 ID 集合必须合法且无重复。
缺失/畸形列表不当作空，明确拒绝不被他人删除覆写为成功；相同请求身份只回读或
返回既有结果，未知目标禁止新请求重删。恢复按当前会话范围读取，不跨进程保存。

删除加入 VMM 原模块协调器：与电源、设置和创建互锁，未知删除阻止同目标修改及
同名创建；请求身份也不能跨操作复用。危险写不新增内部回退、依赖、签名或持久化。
原 PowerBatch 组件提取为 VirtualMachineBatchViewModel 与共享 Batch 窗口，使用
显式 Delete 动作，不把删除伪装成电源操作；电源旧测试保留。删除窗口默认无选择，
只选已关机 VM，完整集合确认后再次核对全体基线，1/21/205 项逐台执行；任何失败、
取消或未知都停止剩余项。核对不启动删除，不自动继续。永久删除与虚拟磁盘风险
单独双语说明和勾选，默认按钮为关闭，长确认文案可换行。

新增 Repository 14 项、删除批次 6 项、电源反向互锁 1 项和入口源契约 1 项，共
22 项；既有创建未知互锁测试追加删除断言。覆盖 FORM/JSON 固定 v1 单 ID、空
响应、身份/名称/运行状态、畸形列表、丢回执/明确拒绝、取消/重复、跨模块互锁、
无电源 API 仍可删除、同名创建保护、完整集合/未知/拒绝/尾项变化及只读核对。
全量 dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
-p:Platform=x64 --no-restore -v minimal 为 **3253 通过/0 失败/0 跳过**。

初版中文原生删除 16 项及原批量电源 17 项共 33 场景通过（ui-review-20260920-122246）。
之后修正无 VM 时不提示添加 VM 才能删除，并同步测试预期；最终重建双语回归及
包证据见交付记录。项目旧改动保留，未提交/推送，不执行真实 NAS 删除。
PENDING_USER_VALIDATION：备份后使用可丢弃、已关机 VM 测试单项/多项删除、取消、
权限失败、断线和核对。预期运行中不可选、未确认零写、相同身份不重发、只有严格
列表确认消失才成功；恢复不继续未开始项。重登/重启前后需自行核对 NAS，不承诺
跨进程保留未知操作。回传版本/步骤/计数/脱敏错误，不提供真实主机/凭据/资源数据。

最终功能源码的英文 900×740 原生 **46 场景通过**（ui-review-20260920-122754），
包括删除 16、批量电源 17、单台电源 13；命令 windows/tests/UiSmoke/run.ps1
-Scenarios vm-delete,vm-power-batch,vm-power -Language en-US -WindowWidth 900
-WindowHeight 740。截图恰在确认动画过渡中，测试宿主补等待 160ms 后仍勾选/可提交
断言并重跑中文；未为截图改变生产入口状态。人工检查删除风险说明、可换行确认
及失败后的恢复提示。本地化（Windows 3186）、108 请求 fixture、3 响应组及 22
私有引用、严格文档预检和 diff 检查通过。只读复核确认创建/设置/电源双向互锁、
空/坏列表不能证明删除、核对路径没有 delete 调用、明确拒绝不读回伪成功。

补稳定视觉状态断言后，最终中文 **46 场景通过**（ui-review-20260920-123229）。
windows/package.ps1 以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成 windows/dist/20260920-123408，
终态 exit 0；包内全量 **3253 通过/0 失败/0 跳过**，x64/ARM64 自包含 Release
publish 成功。build-info testsRun=true、main@0eeeb170358c 加未提交改动；App DLL
无本波合成仓库/场景入口；SHA256 与旁文件一致：

- x64：`0D4E8374C2BFE9BD34055B889F7BEB4B2D62EF2D90EF1B16D30C984D25F9371E`
- arm64：`A953347BFB36ABC8BA251EE18DA44E010E45DBDC8DC7F9CFCE4B2983914D09B7`

未安装/启动、未提交/推送、未执行真实 VM 删除，旧包和用户改动保留。Mac 上一波
源码修复仍未编译，不把本 Windows 包当成 Mac 验证；VMM 映像/高级配置/控制台及
系统集成继续按原目标推进。

#### 2026-09-20 Apple VMM 公开删除契约修复（源码完成，目标验证待补）

核查官方 VMM API 指南：Guest.delete 和 Guest.Image.delete v1 均为单个 ID、空成功
响应，不返回任务。Apple 映像删除误用必须有 data 的 call 并猜任务 ID；唯一任务
等待 helper 只被该错误删除分支使用，因此移除而非新增无消费者的轮询。Guest 多选
删除不能逗号拼接公开 guest_id。本波在用户既有同类缺陷授权下修复共享 DsmNetwork，
不改 macOS App/UI、身份/存储/签名，不对真实 NAS 删除。公开分支按固定 v1 单项
提交、严格同源列表回读、部分结果和未知不重发；内部兼容分支保持独立，不猜参数。
五端影响：Mac 调用共享层；iPhone/iPad 共包需编译回归但只读 VMM 范围不扩展；
Windows/Android 无源码变更，契约结论同步记录。当前 Windows 无 Swift，目标编译/
实机结果不以 Windows 测试替代，后置验收，不生成冒充已验证的 Mac 包。

公开 Guest / Guest.Image 的删除已共用固定 v1、严格同源 ID 列表、逐项空响应提交
与逐项回读；所有接口名称、版本范围、字符串身份及重复 ID 在写入前核对。void
入口转入统一结果流程，不再绕过重复保护。新增仅当前 Repository 实例有效的未知
ID 集合；同目标再次调用只读核对，不重删，也不顺便执行这次参数中的其他目标。
列表已发现后续目标消失时停止，不再多发一次删除。明确 API 拒绝不以另一方资源
消失覆写为成功；未知、取消或失败都停止剩余项。未执行项计入现有 counts.failed
（未完成），真正未知项单列 counts.unknown，不变更共享结果结构；部分提示相应
改为“其余未完成”。认证错误保留认证类别及双语重新登录提示。

公开映像删除不再调用要求 data 的读取型方法，也不解析 task_id/task/id；移除了
唯一只服务于该错误分支的 waitForVirtualizationTask。内部映像兼容分支仍独立使用
原参数，但读取分区失败/不可用不能当作映像已消失；内部 VM 删除未扩大改动。
新逻辑未加入后台 Task.Info 清理、导入或未验证内部删除参数。

新增 11 个 Swift 测试方法，并修正旧多项请求/空响应与共享 fixture 回放：固定版本、
单 ID、FORM/JSON、空成功及带无关 task_id 均不轮询、部分/取消计数、重复调用只读、
明确拒绝、缺失/重复/数字身份数组、复合输入、认证语义、版本不支持和后续目标
消失零多余写入。它们目前均为未运行，不能写作通过。实际执行 swift test
--package-path apple --filter DsmServiceManagementRepositoryTests 返回 exit 1，原因
是当前 Windows 环境找不到 swift；未安装新工具链，未生成 Mac 测试包。

本机可执行检查：本地化通过（Apple 4110、Android 2188、Windows 3177），108 请求
fixture、3 响应组/22 私有引用和 diff 检查通过；Windows 原有全量 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore
-v minimal 为 3231 通过/0 失败/0 跳过，仅确认跨仓库现有门禁未回归，不证明 Swift。
只读复核检查了空响应、单项请求、同源严格回读、取消边界及重复保护；未提交/推送，
其他既有改动保留，没有真实 NAS 写入。

PENDING_USER_VALIDATION：在 Mac 先运行上述 Swift 测试和 RequestFixtureContractTests，
再按现有临时签名流程构建测试包；用可丢弃 VM/映像验证单项/多项、取消及断线。
预期没有 task 轮询、每个 ID 最多一次提交、成功必须在相同公开列表中确认消失，
未知目标在同一实例中只读核对。重连/重启不保证保留未知集合，重新删除前需手动
核对 NAS。回传版本/步骤/计数/脱敏错误，不回传真实主机、凭据或资源数据。

#### 2026-09-20 Windows VMM 多台电源操作

Mac ServiceManagementModel.controlVirtualMachines 使用完整多选 ID 集合，Windows
VirtualMachinePowerViewModel 只有单目标。本波新增多台开机/正常关机/强制关机的
原生流程：完整集合确认、全体新鲜预检、逐台沿用现有公共电源 Repository、未知或
认证失败中止、剩余项不自动开始、独立只读核对。单一范围为 VMM 批次状态/窗口/
入口与正式测试/资源，不新增 NAS API 或修改五端网络契约，其他四端不改。高风险
电源仅合成验证，实际 NAS 留给用户；明确不包括删除、控制台或高级硬件。

并记录独立基线疑点：Mac deleteVirtualMachines/Result 把多个 ID 逗号拼入公开
Guest.delete，而官方指南描述单一 guest_id；需后续专门核查/修复，不能照抄成新
Windows 请求。本波不触碰该 Mac 删除代码，也不把该疑点作为批次电源的阻塞。

已接独立多台电源窗口，默认无选择、未确认不能提交，动作/选择变更撤销确认；按
当前状态提供可操作项，已有未知任务排除在新选择之外。提交前读取全体目标新基线
并逐项比较，尾项变化在任何写入前中止；无 20 项限制，205 项全量串行测试通过。
逐台仍使用既有 ControlPowerAsync 和模块互斥/请求身份，不引入数组写或内部 API。
未知、取消和认证失败停止后续项；核对入口只调用 ReviewPowerAsync，显示原动作，
不会自动启动未开始项。强制关机单独警告未保存数据风险并要求勾选确认。

为使正常开关机能够完成整批，补底层接受标志：仅明确接受后在原状态或已知启动/
关机过渡态继续等待，每次读取绑定同一 guest_id，直到目标状态或取消。丢失回执、
异常状态/读取失败仍返回未知，不重发；明确拒绝不被他人状态变化覆盖。原先只读
一次的过渡态测试改为证明不会提前成功、取消后保留未知、后续只读核对不重发。

全量首次因两个设置/电源互斥夹具永远返回接受但不改变状态而停留；确认 PID/父
进程及本仓库 testhost 路径后，仅停止该测试宿主。该次运行是中止而非通过。夹具
改为明确模拟电源回执丢失以构造未知，原互斥断言保留。随后全量 **3231 通过/
0 失败/0 跳过**。英文原生取消场景发现逐项重建窗口造成取消按钮暂时消失，改为
合并更新进度文字、保留按钮和焦点；再次相同场景通过，不以早期退出场景充当通过。

新增批次状态 14 项、接受后过渡等待 3 项及入口源契约 1 项，净增 18 项。覆盖三
动作全量/串行/唯一请求、确认变更、尾项变化、未知/认证、取消/关闭、跨动作纯核对、
不可用及非法快照，并保留原单台、配置互斥与请求身份测试。全量命令为 dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal。
首轮中文 30 原生场景通过（ui-review-20260920-110658），修复进度重建后英文 30
通过（111736）；最后补核对未提交结果显示为待核对后，重建最终宿主中文 30 通过
（112057），最终英文同宿主复跑及双架构包结果见交付记录。无真实 NAS 电源操作。

PENDING_USER_VALIDATION：选择可丢弃测试 VM，分别批量启动/正常关机/强制关机，
核对每台最终状态、取消后的未开始数量及重新打开后的只读核对；强制关机前先备份。
预期无确认零写、变更目标需刷新重选、接受后的正常过渡不提前结束、未知不重发、
核对不自动继续。只回传版本、步骤、计数及脱敏错误；不索取主机/凭据/真实 VM 数据。
其他四端源码/存储/身份不变；Mac 删除疑点、VMM 高级配置/控制台及系统集成仍未完成。

最终功能代码的中文 30 场景通过（ui-review-20260920-112057），英文 900×740
30 场景通过（112435），其中批次 17 项与原单台 13 项；命令为
windows/tests/UiSmoke/run.ps1 -Scenarios vm-power-batch,vm-power -Language zh-CN，
英文加 -SkipBuild -Language en-US -WindowWidth 900 -WindowHeight 740。人工检查
强制关机确认和取消后的数量/核对入口。最后英文数量文案改成不涉及单复数的标签，
重建宿主并补英文选择、强制关机浅深色及取消 4 场景，全部通过（112833）；功能代码
不变。本地化（Windows 3177）、108 请求 fixture、3 响应组/22 私有引用、严格文档
预检和 diff 检查通过。独立只读复核确认全体新基线先于写、已接受转态不重发、未知
停止剩余项、核对保留原动作，控件关闭不会继续执行后续目标。

既定 windows/package.ps1 以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成最终 windows/dist/20260920-113022，
终态 exit 0。包内全量 **3231 通过/0 失败/0 跳过**；x64/ARM64 自包含 Release
publish 成功，build-info 为 testsRun=true、main@0eeeb170358c 加未提交改动；App
DLL 无本波合成仓库/场景入口，SHA256 与旁文件一致：

- x64：`146E938ABBE4A24D0F9271983B620C6AC87721B30BE9D339B9DE9265EE609953`
- arm64：`D930F50B5A0678706A2281C5F898429BA44D949DF6AE0BE6660AB6500A39645C`

旧包保留，未安装/启动，未提交/推送，未执行真实 NAS 电源操作；不是 Mac 修复包。

#### 2026-09-20 Windows 回收/恢复只读核对

证据：Recycle Repository 有会话内 review，但无独立只读入口，源存在判断仅比类型/
大小，会误将变更后的源视为消失。本波补稳定身份清单、只读核对与本地成功回执，
要求源路径确实消失；保留回收目标发现、权限、恢复禁止覆盖、时间/大小/类型核对。
复用前波核对状态与窗口，提取为文件操作公共呈现，业务契约分别适配，避免复制两套
同类窗口。Mac 基线为回收/恢复结果核查，Windows 重开列表为安全闭环扩展。单一范围
为文件核对 UI/状态、Recycle Repository/领域与正式测试/资源；其他四端只记录影响，
不改源码/身份/存储/API 参数，不做真实 NAS 删除或恢复，真实验证后置。

已补 Recycle 的会话内稳定身份清单、独立只读 Review 与仅本地成功回执；过期身份
不走启动分支，成功证据留到界面正确接收，关闭期间的迟到结果可重开核对。回读
要求源路径真正消失，不能用源大小或类型变化冒充不存在。提交前认证/网络失败
明确未执行，不留下无法核对的本地未知；提交后仍保留未知和禁止重放。

原 FileCopyMoveRecoveryViewModel 与 FilesPage.CopyMoveRecovery 提取为共用
FileOperationRecoveryViewModel / FilesPage.FileOperationRecovery，复制/移动与
回收/恢复仅各自适配原接口及结果约束。回收保留来源/目标/时间一致性和完整目标
路径 blocker，复制/移动保留原父目录 blocker；两类操作的窗口状态、取消、身份
验证、成功回执和消息处理共用，未增加平行 UI。原专用文件被共用文件替代，逻辑
和原回归保留。工具栏及回收批次结果条可打开新入口，无需源仍位于当前目录。

回收轮询取消固定 8 次限制，等待健康任务至完成或取消；取消后只核对，不重放。
按官方 API 指南第 92 页，Delete.status 的统计态 total=-1 合法、数量为 processed_num；
纠正此前非负 total 与 processed_size 校验，CopyMove/Delete 共用总量校验并继续
拒绝字符串、其他负数。对应公开文档说明同步更新，未新增 NAS 写方法。

新窗口标题最初与旧单项 FileRecycleReviewTitle 重名，造成本地化初始化及 16 项
聚焦测试失败；改用独立列表标题键后原断言全部通过。初版中文 24 场景通过
（ui-review-20260920-103855），但两类场景同名会覆盖截图；回收场景补前缀后重跑
最终宿主，不以被覆盖截图充当回收验收。源码冻结后的证据见本波交付记录。

本波新增 Repository 10 项、回收状态 15 项、公开状态字段 5 项、入口源契约 1 项，
净增 31 项。包括两操作的稳定身份/会话隔离/零重发/确认回执、源变更不报成功、
提交前认证及网络失败、长任务/取消、来源/目标/时间不符、未知/缺失/认证/关闭、
total 与 processed_num 原生类型边界。旧复制/移动核对回归在共用组件上继续执行。
PENDING_USER_VALIDATION：在当前连接中用可丢弃测试项目形成回收/恢复待核对，关闭
任务窗口后从新入口核对，确认未再次删除/移动、已完成项才解除记录，关闭后重开
不丢已确认结果。重登/重启不保留清单；源变化、同名冲突和权限竞态需 NAS 上检查。
只回传版本、步骤、计数和脱敏错误。其余 VMM、系统集成及独立文件夹范围评估继续。

最终全量命令 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
-p:Platform=x64 --no-restore -v minimal` **3213 通过/0 失败/0 跳过**。最终英文
900×740 **24 场景通过**（ui-review-20260920-104210），包含回收/恢复 14 项及原
复制/移动 10 项；截图命名已区分，人工检查回收和恢复的暗色路径方向与操作标题。
命令 windows/tests/UiSmoke/run.ps1 -Scenarios files-recycle-recovery,files-copy-recovery
-Language en-US -WindowWidth 900 -WindowHeight 740；中文在同一最终宿主 -SkipBuild
复跑。资源 Windows 3151、本地化/108 请求 fixture/3 响应组及 22 私有引用、严格
文档预检与 diff 检查通过。独立只读复核确认共用层只调用各自 review/本地回执，
无回收/恢复启动调用，时间和路径门未因复用取消；后续构建期间不再改生产源码。

最终中文同宿主 **24 场景通过**（ui-review-20260920-104503）。既定
windows/package.ps1 以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成，终态 exit 0；目录
windows/dist/20260920-104513。包内全量 **3213 通过/0 失败/0 跳过**，x64/ARM64
Release 自包含 publish 成功，build-info testsRun=true、main@0eeeb170358c 加
未提交改动；生产 App DLL 无合成仓库/场景入口，SHA256 与旁文件一致：

- x64：`673519BF6353717C6BD39AA7D6846594C98D979C6C1AB829C609348C426D5DD4`
- arm64：`8A28BD3D7564055C86BABA0CBD87709F3923B08CA3835A98CC0FB9CCAB39BA9E`

旧包和用户既有改动保留，未安装/启动，未提交/推送，未执行真实 NAS 写。

#### 2026-09-20 Windows 复制/移动待核对入口

证据：FileCopyMoveBatchViewModel 遇本地 blocker 立即停止；DsmRepository 已保存
会话内 FileCopyMoveReview，但无专门只读公开入口，文件页也无重开列表。本波补
稳定任务身份的会话内清单和只读核对，文件页入口不要求源仍在当前目录。单一范围
为 CopyMove 领域/Repository、独立核对状态与文件页窗口及测试/双语资源。保留原
确认、权限、任务+回读、未知互斥和禁止重放；不自动继续未开始项目、不执行真实
NAS 写。Mac 的 transfer/task 状态是参考，不把 Windows 恢复扩展冒充 Mac 已有 UI。
五端：Windows 向后兼容增量，其他四端只记录影响；不改 API 参数、存储、身份或
依赖。清单只在当前连接生命周期存在，不跨进程或重新登录持久保存；真机后置。

已补 GetCopyMoveReviewsAsync、ReviewCopyMoveAsync 与仅本地的成功确认回执；旧实现
默认不支持，当前 Repository 开放只读入口。会话内记录有稳定随机身份，过期/其他
会话身份零网络、零启动。核对与写操作共用目标互斥，覆盖仍须任务完成和精确回读。
成功证据保留到 UI 正确接收，关闭窗口导致迟到结果不会丢掉可重开记录；只有精确
匹配成功才解除对应 blocker，未知/失败/缺失不清除、不继续其他项。

文件页工具栏新增核对入口，批次结果条也有快捷入口；源不在当前文件夹或已被移动
不影响打开。窗口支持刷新、选择、来源/目标、忙碌/空/错误/成功/待核对状态和主题，
关闭取消只读请求，重复点击不并发。提交前认证/网络异常明确返回未提交失败，不再
生成无法核对的本地未知记录。提交后的异常仍保留未知；原状态页/照片和其他四端
不加入重放流程。网络异常白名单扩展时遗漏 InvalidDataException 导致两个既有
全量测试失败，恢复明确类型后原断言通过；未跳过或弱化数据格式检查。

本波新增状态层 12 项、Repository 5 项及入口源契约 1 项，净增 18 项：精确确认、
错误目标/大小、未确认、缺失、认证错误、关闭/并发、外来 profile/重复身份/非法
路径、空列表、纯核对不启动、会话隔离、确认回执前保留证据、目标互斥，以及提交
前认证/网络失败不留未知。初版中文原生 10 场景通过（ui-review-20260920-101950），
人工查看深色来源/目标窗口；恢复格式异常分支后再构建最终宿主，结果见交付记录。

PENDING_USER_VALIDATION：同一次连接内用可丢弃测试文件制造复制/移动结果未确认，
关闭任务窗口后从“核对复制和移动”打开，核对后确认无再次启动、成功后列表移除，
其余未开始项不执行；关闭核对中的窗口再打开仍能接收成功证据。重新登录/重启不
承诺保留该列表，需先在 NAS 检查文件，避免重复操作。仅回传版本、步骤、计数和
脱敏错误。回收/恢复的对应核对入口及 VMM/系统集成仍是后续，不宣称全目标完成。

最终全量 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
-p:Platform=x64 --no-restore -v minimal` **3182 通过/0 失败/0 跳过**。最终宿主英文
900×740 **10 场景通过**（ui-review-20260920-102206），同宿主中文 **10 场景通过**
（102348）；命令 windows/tests/UiSmoke/run.ps1 -Scenarios files-copy-recovery
-Language en-US -WindowWidth 900 -WindowHeight 740，中文使用 -SkipBuild -Language zh-CN。
人工查看暗色待核对与成功状态。资源 Windows 3148、本地化/108 请求 fixture/3 响应
组及 22 私有引用、严格文档预检与 diff 检查通过。独立只读复核确认核对分支无 start
调用，随机过期身份不能构造任务，回执仅清理已验证的本地成功证据；生产源码冻结。

按既定 windows/package.ps1，以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成 windows/dist/20260920-102358，
终态 exit 0。包内回归 **3182 通过/0 失败/0 跳过**；x64/ARM64 Release 自包含
publish 成功，build-info testsRun=true、main@0eeeb170358c 加未提交改动，双架构
App DLL 无本波合成仓库/场景入口；SHA256 与旁文件一致：

- x64：`4FDF95A1218B6580A4FF730BF4878A6C32B412AA4676202D5ABCF6BF2D0FC6EA`
- arm64：`51E4FEF90F0AB5163BC05D89C544CF5AC1880A3F44B735FC78AE708163CDD39A`

未安装/启动，未提交/推送，旧包和既有工作区改动均保留；无真实 NAS 写入。

#### 2026-09-20 Windows 复制/移动同名语义

Mac WorkspaceModel.enqueueFileOperation 默认 namesInFolder 过滤同名，主动 overwrite
传至 repository；官方 File Station API CopyMove v3 overwrite=false 为跳过、true
为覆盖。Windows 现有 FileCopyMoveRequest 缺策略、transport 固定 false，Repository
同名直接失败。本波按既有兼容扩展授权补默认跳过/主动覆盖、独立跳过计数、确认与
任务完成及回读联合证据。单一范围为 CopyMove 领域/transport/repository/文件页模型
及确认资源、正式测试和公开 fixture；旧调用默认 Fail，旧 transport 默认 false。
旧照片兼容入口和恢复/撤销不增加覆盖；不改变身份、权限、存储或依赖。高风险覆盖
仅合成测试，不操作真实 NAS。五端影响：Windows 增量实现，Mac 只读基线，iPhone/
iPad 与 Android 仅记录影响、不改代码。无数据迁移，回滚为不选覆盖或撤回本次代码。
真实覆盖/目录合并 PENDING_USER_VALIDATION，源码与构建证据本波补齐。

已接单项/多项共用确认流程，默认跳过，勾选覆盖后提示不可撤销及文件夹内同名文件
风险，主按钮明确“复制/移动并替换”。覆盖提交后不提供原拖动撤销，撤销入口仍保留
Fail 且不显示覆盖选择。旧照片共用内容默认不显示新选项，只有正式文件页主动开启。
跳过单独统计，不算成功、失败或可撤销项；请求策略在提交期间不可改变。

Repository 新增显式策略，旧调用仍 Fail；transport 新重载仅显式 true 才覆盖，旧
重载仍 false。目标同名时 Skip 零提交；Overwrite 检查同类型/可写，用一次性名称
只读探测目录新建权限，正式 API 最终执行权限判定。确认覆盖成功要求任务确实完成
与源/目标回读，旧同大小文件不能充当证据；任务 ID/完成标记只保存在既有会话内
恢复对象，重进只查询，不重发。移动要求源路径真正消失，不将源变更等同已移走。
目录及子项互斥覆盖活动和未知任务，避免并发子项改变。

按官方指南补 CopyMove total=-1（正在统计），其余字段继续严格校验。正常任务不再
固定查询 8 次，持续等待终态且接受取消；恢复共用轮询同步传取消令牌，取消后仍按
原策略回读或保留未知。初次编译暴露该共用调用缺参，已修正；测试辅助函数漏 operation
参数也已补齐。全量曾失败于旧照片源契约要求文件页继续使用旧单项窗口，已改为检查
单项进入共用确认及选中项核对，照片自身安全断言保留。未降低断言或跳过测试。

本波净增 **25 项**测试，覆盖 Skip 两种操作及文件/目录、覆盖任务与回读联合证据、
旧目标同大小/任务缺失/明确拒绝不报成功、取消后只读恢复、目录子项并发、10 次健康
轮询、total=-1 类型边界、策略冻结、跳过计数及正式表单 true/false；新增两个覆盖
请求 fixture（总计 108），标为 highRisk。全量命令 `dotnet test windows/tests/LanStash.Tests/
LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal` **3164 通过、
0 失败、0 跳过**。源码冻结后的目标构建/原生/包证据见本波最终交付记录。

初版中文 13 同名场景通过（ui-review-20260920-095720），后续中文同名/大批次共
26 场景通过（100020），包含原生目标树、覆盖勾选、单项入口、全部跳过、取消、未知、
反选覆盖及主题。最后一轮另补旧照片选项默认关闭和目录互斥后重建宿主，不拿早期
截图替代最终生产源码测试。独立只读复核确认权限/目标绑定/未知不重发仍保留，未改
其他四端、签名或持久化。真实 NAS 中目录合并、内容替换及权限竞态仍需用户验证，
只回传版本、操作步骤、计数与脱敏错误；未执行任何真实覆盖或删除。

最终源码重建宿主后，英文 900×740 的同名和大批次 **26 场景通过**
（ui-review-20260920-100259）；人工查看覆盖确认、默认取消、全部跳过的浅深色
截图，无截断。命令 `windows/tests/UiSmoke/run.ps1 -Scenarios files-copy-conflicts,files-large-copy-move
-Language en-US -WindowWidth 900 -WindowHeight 740`。本地化（Windows 3134）、108
请求 fixture、3 响应组/22 私有引用、严格文档预检和 diff 检查通过。继续同宿主中文
复跑及既定双架构打包，包内回归仍为 **3164 通过/0 失败/0 跳过**。

`windows/package.ps1` 以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成，终态 exit 0。最终目录
windows/dist/20260920-100438；x64/ARM64 Release 自包含 publish 成功。build-info
为 testsRun=true、main@0eeeb170358c 加未提交改动，生产 App DLL 无合成仓库/场景
入口；SHA256 与旁文件逐一核对一致：

- x64：`9ED1C887C6CF74C81EA45711CD82EECE5F1E4E65C98542E1B8D8A9CC513038B1`
- arm64：`B8FFCFCDE5D5700E3BECE11F65BFE98A4F5CD4C03F9059B19A0951CA6B003290`

未安装/启动，未提交/推送，旧包及用户已有改动保留；没有真实 NAS 写入。

同一最终宿主中文 -SkipBuild 复跑 **26 场景通过**（ui-review-20260920-100547），
与英文 26 场景共同覆盖本波交付。最后严格文档预检和 diff 检查通过。

#### 2026-09-20 Windows 文件回收/恢复完整批次

Mac WorkspaceModel.deleteItems 接完整 targets，无 20 项限制；restoreToOriginalLocation
为单项恢复，Windows 既有批量恢复属于扩展，不冒充 Mac 批量基线。本波单一修改范围为
文件页回收/恢复选择、批次模型、确认内容和正式测试；旧 File Station 照片兼容入口
保留独立数量限制，其他平台/API/持久化不变。目标是完整选择串行执行，冻结确认范围，
默认取消、进度更新、认证失败停止；保留实际权限、回收位置、禁止覆盖、未知阻断及
结果精确核查。依赖既有 File Station 回收/恢复契约，高风险写仅合成验证，不操作
真实 NAS。真实设备为 PENDING_USER_VALIDATION。

文件页多选/按钮和通用模型已移除 20 项上限，确认冻结不可修改源集合及回收位置。
嵌套检查改为祖先查表，提交前一次索引核对所有来源、选择缓存、原生选择及当前
模式；末项消失/元数据改变不再静默缩小批次。确认窗口默认取消、跟随主题、可滚动
查看完整名称；进度条及文字轻量更新，关闭解除订阅。未知/取消仍停止并保留待核对
项，不重发，不覆盖已有恢复目标。API 参数、结果核查、其他平台未改。

只读复核发现既有 Repository 的认证异常会向上抛出；除了结果类别，还补异常分支
提示重新登录，仍保守保留未知项。同类复制/移动批次仅补此异常提示及一项回归，
不改提交或结果分类。最初新测试错误地给只读 ErrorCategory 赋值，已按正式构造函数
修正；全量首跑发现压缩源契约仍断言回收上限，改为无上限并保留回收/恢复资格断言。
未跳过或降低安全测试。新增规模/未知/认证/快照/祖先边界测试及两种操作异常测试，
Windows 单测累计净增 14 项；最终结果见本波交付记录。

初版中文 13 场景（ui-review-20260920-093831）、英文 900×740 13 场景（094017）
均通过，人工检查深色确认和认证失败截图。随后增加真实异常形态的合成分支，重新
执行目标构建与双语原生回归；不把初版宿主结果替代最终源码验证。
PENDING_USER_VALIDATION：有回收站权限的 NAS 上选择大量测试文件/文件夹，分别回收
和恢复，检查目标内容、同名冲突、取消及登录失效；预期不截断选择，不覆盖已有项，
未知显示待核对且不自动重发。只回传版本、步骤、计数及脱敏错误。下一切片继续
复制/移动同名跳过/覆盖、VMM 和系统集成；本波不能证明整体目标完成。

最终全量命令 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
-p:Platform=x64 --no-restore -v minimal`：**3139 通过/0 失败/0 跳过**。最终中文
`windows/tests/UiSmoke/run.ps1 -Scenarios files-large-recycle -Language zh-CN` **14 场景
通过**（ui-review-20260920-094210）；同宿主 -SkipBuild -Language en-US
-WindowWidth 900 -WindowHeight 740 **14 场景通过**（094400）。包括两种操作完整
执行、第 23 项未知/取消、登录失败结果与异常、末项选择及元数据变化、列表/网格
和浅深色。自动化没有真实 NAS 写入，合成宿主与生产包隔离。

本地化（Windows 3129）、106 请求 fixture、3 响应组/22 私有引用通过；文档检查
曾因状态页 251 行失败，合并状态说明后严格预检通过，diff 检查通过。打包首次在
新 PowerShell 环境未设置项目 SDK 路径而恢复失败，补现有 SDK PATH 后按原流程
重跑，没有安装工具链或改系统环境。生产源码在最终构建前冻结，无提交/推送。

最终 `windows/package.ps1` 以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 完成，终态 exit 0。输出
windows/dist/20260920-094422，打包内 **3139 通过/0 失败/0 跳过**，x64/ARM64
Release 自包含 publish 成功；build-info 为 testsRun=true、main@0eeeb170358c 加
未提交改动，双架构 App DLL 无本波合成仓库/场景入口。SHA256 与旁文件一致：

- x64：`9FCA4EEC8E5AEC9342987D1193806848A0991AA8CB8B110ABE2C984C80E59F13`
- arm64：`B3BEFE892C5F4FE5725561992716FCDF4524C823B0907654F3F00245550D1AD0`

未安装/启动，旧包保留；没有提交、推送、依赖/身份/签名/持久化变化或真实 NAS 写。

#### 2026-09-20 Windows 文件复制/移动批次规模对齐

Mac WorkspaceModel.enqueueFileOperation 接完整 targets，无 20 项限制；默认不覆盖，
另有同名跳过/覆盖语义。本波先收敛 Windows 文件页选择/按钮/批次验证的额外数量
限制，并优化大集合嵌套与确认快照校验，不把规模对齐冒充覆盖选项等语义已全部补齐。
保留逐项确认、未知阻断、权限/源目标约束和取消；不执行 NAS 写。Shell 当前照片入口
是 SynologyPhotosPage，旧 File Station 照片组件的兼容常量不在本波放开。单一范围
为文件批次模型、共用文件页选择/确认和正式测试；回收及其他平台不改。

已移除文件页多选、按钮与通用批次验证的 20 项限制，保留旧照片兼容组件使用的
常量（不再参与通用批次验证，现行 Shell 照片页为 SynologyPhotosPage）。复制/移动
冻结为不可修改的源快照；目录嵌套检查改为祖先路径查表，目标过滤缓存源父目录和
目录集合，避免数量放开后仍逐对比较。保留重名、混合父目录、越界/只读、目录自包含
及移动删除权限检查，默认不覆盖，不更改 NAS 请求方式或存储结构。

确认时同时检查完整源集合、选择缓存和原生控件选择，缺失/替换/尾项变化不截断后
继续执行；拖动和撤销保留各自可见来源约束。未知仍停止并锁住未确认项，认证失效
停止后续请求并显示重新登录提示；取消、最终确认项和未开始计数保持守恒。大批次
运行中的进度文字改为轻量、合并更新，不固定停留第 1 项；关闭时解除订阅。人工
查看截图发现批量窗口未继承深色主题，已补 RequestedTheme 并加入主题一致性断言。

新增 **9 项**单测：21/205/1001 项两种操作完整且串行、不可修改快照与嵌套边界、
第 23 项未知/认证失败后停止。全量 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release -p:Platform=x64 --no-restore -v minimal` **3125 通过/0 失败/0 跳过**。
旧仅断言 20 项的测试改为完整集合/安全门验证；没有降低原有未知/权限/取消保护。

原生宿主初次缺少测试辅助遍历函数导致编译失败，已修复；业务通过后另发现主题
问题，未将早期深色截图冒充正确。修正后中文 **13 场景通过**（`ui-review-20260920-091801`），
最终英文 900×740 **13 场景通过**（`092239`），覆盖 206 项、列表/网格、两种操作、
第 23 项未知/取消/认证失败、只读目标、选项及尾项变更、实时进度和深色主题。
通过正式文件页入口及原生主按钮执行合成仓库请求，没有对真实 NAS 写入。

本地化（Windows 3128）、106 请求 fixture、3 响应组/22 私有引用及 diff 检查通过。
独立只读复核确认默认按钮仍为关闭，源和目标仍在提交前核对，未知不会重放，认证
失败不继续撞会话；旧照片兼容层和回收选择限制未被一起解除。现有未提交改动保留，
不新增依赖/身份/签名或持久化变化。`PENDING_USER_VALIDATION`：真实 NAS 的大量文件/
文件夹、权限变化、取消和部分结果；只回传版本/步骤/脱敏错误。下一切片仍需处理
回收数量以及复制/移动同名跳过/覆盖等语义，不能把数量对齐写成整个功能已完全复刻。

最终中文 **13 场景通过**（`ui-review-20260920-092530`）。既定 `windows/package.ps1`
以 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=1、
LANSTASH_LAUNCH_AFTER=0 完成 `windows/dist/20260920-092541`，终态 exit 0；再次全量
**3125 通过/0 失败/0 跳过**，x64/ARM64 自包含 Release publish 成功。build-info
确认 testsRun=true，双架构 App DLL 无合成批次仓库/场景入口，SHA256 旁文件一致：

- x64：`DC70EB58D1594730E67BC785F2D2A481BFD86D526E0D668414A3C50CB55F263A`
- arm64：`902CF653C89FFA19F32C8166897A73BF0C623F5CB7774C7A5FE782B2A19E2E24`

未安装/启动，不覆盖旧包；保留 main@0eeeb170358c 的既有未提交工作区，无提交/推送。
打包期间未改生产源码，不把本包或 Windows 测试当作 Mac 目标验证。

#### 2026-09-20 Windows 多文件上传数量对齐

Mac WorkspaceView 的上传选择器允许多选普通文件、明确不选目录，WorkspaceModel
enqueueUploads 按完整 urls 执行，没有 20 项上限。Windows 普通文件选择器和拖放
共用的 20 项限制属于额外差距；本波移除该上限，保留逐项串行、同名预检、目标互斥、
覆盖选择和结果核查。选择器返回后核对目标/权限/覆盖选择，批次冻结完整路径快照。
单一范围为普通多文件上传验证/执行、原生选择器/拖放和正式测试/双语文案；不修改
文件夹上传的独立设计或扩展 Mac 目录上传，不改其他平台、网络契约及持久化结构。
Windows 独立文件夹功能仍需单独评估，不能把它误称为 Mac 已有的批量上传行为。

已移除普通文件选择器/StorageItems 拖放共用验证器的 20 项限制，保留既有串行执行、
同名预检、目标预留、默认不覆盖、逐项结果和取消终止语义。运行前复制路径集合，
验证和执行都使用冻结快照；回调改变原集合不会替换或丢失待传项。选择器前后检查
目标文件夹、只读状态和覆盖选择，失效/关闭/取消不开始网络操作；实际已启动的
批次继续绑定原目标，不因后续页面变化而误称未开始。活跃拖放文案已去掉 20 项承诺，
旧 TooMany 枚举值仅保留兼容，不再产生或在文件页映射到数量错误。

新增/扩展 21/205/1001 项验证和串行执行、回调修改原集合、23 项后取消计数守恒，
全量测试净增 **6 项**。原非法数量样例改为非法空文件名路径，保留无效输入零执行
覆盖；没有降低原同名、取消和未知不重发断言。实际全量命令 `dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore
-v minimal` **3116 通过/0 失败/0 跳过**。

原生 `windows/tests/UiSmoke/run.ps1 -Scenarios files-upload-batch -Language zh-CN`
**12 场景通过**（`ui-review-20260920-084443`），英文 900×740 同场景 **12 通过**
（`084835`）。使用 205 个实际临时本地文件与合成 Repository，核对全部源流、最大
并发 1、无重复、覆盖开关、StorageItems 解析、未知项、23 项取消、目标变化、
关闭/取消选择器和重复目标零上传；完成后检验文件句柄释放，并清理自建 GUID 目录。
截图标志在断言和清理之后才写入。补齐最终拖放文案后重新发布原生宿主，不影响
文件夹上传原有上限，未向真实 NAS 上传任何测试数据。

本波不改变请求参数/签名/依赖/持久化和其他四端实现。静态本地化（Windows 3127）、
106 请求 fixture、3 响应组/22 私有引用与 diff 检查通过。独立源码复核确认完整
快照先于目标预留、取消仍停止尚未开始项、每个已发送项目不自动重试；未知操作
的人工 NAS 核查语义不变。`PENDING_USER_VALIDATION`：真实 NAS 多文件、网络中断、
权限错误与覆盖选择；只回传版本/步骤/脱敏错误。复制/回收、独立文件夹扩展、VMM
和系统集成仍按原目标推进，不因本波上传完成而宣布整个对齐目标完成。

最终同宿主中文复跑 **12 场景通过**（`ui-review-20260920-085109`）。按既有
`windows/package.ps1`，LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0 生成 `windows/dist/20260920-085119`，
终态 exit 0。打包再次运行 **3116 通过/0 失败/0 跳过**；x64/ARM64 自包含 Release
publish 成功，build-info 和 SHA256 旁文件一致，App DLL 无合成上传仓库/场景入口。

- x64：`36702E068383227B999F48DF9FFE981655E7B5C420B534B5C8E883D0134FE4A0`
- arm64：`696B02567B98211FDBBCFCB598B328C52C24A8A6D0FB454CE8F0CFA84D3C0765`

未安装/启动，不覆盖旧包；保留 main@0eeeb170358c 下既有未提交改动，无提交/推送。
打包期间未修改生产源码。Mac 目标验证仍后置，本包不包含 Mac 修复产物。

#### 2026-09-20 Windows 多选文件与文件夹下载对齐

核对 Mac WorkspaceModel.enqueueBatchDownload/startBatchDownload：单文件保存原文件，
单文件夹或多个项目通过公开 Download v2 的 path 数组保存 ZIP，无客户端 20 项上限。
Windows 原多选只支持最多 20 个普通文件逐个保存，不能只去掉数量判断就声称对齐。
本波复用现有目录 ZIP 流、事务式保存、传输活动和原生选择器，接入完整多选路径数组；
下载模式允许文件/文件夹，不截断，选择器返回时重新检查页面/完整选择快照。
单一修改范围为 ArchiveReader 兼容重载、现有归档传输/保存、文件页多选及双语/正式
测试。不改 Photos 的逐项保存、上传/复制/回收限制、其他四端代码或持久化结构。
风险为读取 NAS 与用户选择的本地写入；不操作真实 NAS，不把网络 URL/服务端容量
限制写成无限支持，也不分拆出多个 ZIP 冒充同一完整下载。

已接 ArchiveReader/ApiClient 的兼容多路径重载，单目录入口仍委托同一实现；完整
path 数组一次发送，固定公开 Download v2 GET，沿用会话/证书上下文、响应类型/ZIP
签名检查与 1 MiB 缓冲。新增输入路径、重复路径及连接上下文检查，不截断、分批或
改用在 NAS 创建压缩文件的写 API。复用事务式目标：ZIP 校验后才替换本地文件，
错误/取消保留原文件。单普通文件仍走原文件下载，多个文件/文件夹保存一个 ZIP。

文件页多选允许目录与文件，取消原 20 项选取/按钮约束；复制/回收各用自己的限制，
Photos 的逐项保存未改。保存选择器之前冻结完整选择，返回后同时比对当前列表、
选择缓存及原生控件的实际选择，避免事件延迟或尾项变化导致漏下载。传输仍走现有
活动/取消/目标互斥，不新增存储结构；多项活动来源显示共同父位置，不冒充首个项目
就是整个批次。ZIP 大小未知时保持既有不确定进度，不承诺 Range 续传。

新增 **26 项**自动化案例覆盖 21/205/1001 项选择和单请求完整数组、单文件/单目录
分支、Unicode/查询字符、尾项变化与重复源、跨连接拒绝、事务提交/失败保留，以及
新 `download-selection/synthetic-selection` 请求 fixture。旧只断言“20 项仅文件”的
源码测试改为验证完整选择和服务边界，未降低取消/本地数据保护断言。
执行全量 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release
-p:Platform=x64 --no-restore -v minimal`：**3110 通过/0 失败/0 跳过**。

原生 `windows/tests/UiSmoke/run.ps1 -Scenarios files-selection-download -Language zh-CN`
**12 场景通过**，目录 `ui-review-20260920-081526`；同宿主 `-SkipBuild -Language en-US
-WindowWidth 900 -WindowHeight 740` 同场景 **12 通过**，目录 `081832`。覆盖 206 项
混合选择、列表/网格、单文件/单目录、实际 ZIP 文件保存、取消/损坏 ZIP 保留原文件、
选择变化/关闭页面/选择器取消零网络启动。验证产生的 GUID 临时目录在测试结束时
按明确边界清理，完成标志在所有断言和清理之后写入。人工查看深色完成截图并修正
“多个文件下载”标题，最终中/英文下载完成浅深色各 2 场景通过（082250 / 082443）。

本波未修改 Mac/iPhone/iPad/Android；新增请求 fixture 使用已有公开数组契约，不
改变其他四端请求或平台范围。静态本地化（Windows 3126）、106 请求 fixture、
3 响应组/22 私有引用与 diff 检查通过。独立集成复核确认全选择未丢失、活动取消
使用唯一编号、失败不覆盖、保存路径在 picker 返回后再校验，不新增网络发送入口。
`PENDING_USER_VALIDATION`：在真实 NAS 下载混合文件/目录及 Unicode 名称，核对 ZIP
内容与权限错误，并测试用户取消和覆盖确认。服务器/代理 URL 长度与容量仍可能限制
超大选择；本波不宣称 NAS 没有限制，不以合成压缩内容替代真实目录结构验收。

共用选择逻辑的压缩大列表/网格浅深色 **4 场景通过**（`ui-review-20260920-082451`），
确认下载扩展没有破坏压缩的完整选择。最终按既有 `windows/package.ps1`，设置
LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=1、
LANSTASH_LAUNCH_AFTER=0，生成 `windows/dist/20260920-082556`。流程终态 exit 0，
再次全量 **3110 通过/0 失败/0 跳过**，x64/ARM64 自包含 Release publish 均成功，
未安装/启动、不覆盖旧包。build-info 的架构、selfContained、testsRun=true 已核对；
两份 App DLL 不含合成选择下载仓库/测试场景入口，SHA256 与旁文件一致：

- x64：`DE5FF0ED59ECEB370E3CAEF7054390E9DEBFE987EE905109F49212FC5A4DB399`
- arm64：`86BDC329814B75BD690C8B4177B3B794E568707B0B643E6DA528B234D0CB5EF0`

保持 main@0eeeb170358c 的既有未提交工作区，无提交/推送，打包期间未改生产源码。
仍未完成的上传/复制/回收等限制、VMM 和系统集成继续按原目标推进；Mac 目标验证
仍后置，不把本次 Windows 包当成 Mac 修复包。

#### 2026-09-20 Mac 挂载未知结果恢复

复用现有绑定身份、目标预检和写后证明，给提交阶段增加本次 Repository 生命周期内
的操作编号及无密码恢复记录。未知只核查、不重发；复合修改经核查到下一阶段后，
用户必须明确继续。正常原始确认仍涵盖既有两步主流程；网络或回查中断不自动补写。
恢复窗口显示当前阶段，继续连接才重新输入密码；仅已经确认第一步完成的待继续
状态可明确结束本次修改，不回滚 NAS。单一范围是共享恢复 DTO/兼容接口、现有挂载
核心、Mac 状态/恢复窗口及正式测试；无磁盘持久化、无新依赖、不操作 NAS，其他
四端实现不改。Mac 目标构建仍须有 Swift/Xcode 的环境，不把静态门当目标通过。

已新增无密码 RemoteMountSetup、操作/阶段 DTO 和 FileRepository 的兼容查询/核查/
继续/结束接口；DTO 不采用 Codable，不新增磁盘持久化，调试描述隐藏身份。原有
创建/修改/断开共用同一提交和结果证明流程，在真实提交前写入操作编号；未知阶段
锁住当前目标及父子路径。只有提交本身返回有效正数 DSM 拒绝码才认作明确失败，
回查权限失败或畸形错误码不解除未知锁。提交后取消保留记录，未提交取消不留未知。

正常原始确认仍完成原来的两步修改；中断后核查只更新阶段，不自动执行剩余写。
用户明确继续才重新预检目标和原身份、发送下一步，连接阶段要求重新提供密码，
断开阶段不索要密码。第二步明确拒绝保持待继续，不重复已完成第一步；旧连接已由
外部断开时核对最终状态，不再次卸载。仅待继续状态可经确认结束本次修改，明确
不回滚 NAS；未知阶段不可直接遗忘。最终记录缓存，重复核查/继续不重发。

Mac 远程位置页接入“未完成的连接操作”窗口，展示来源、目标、非密码配置与阶段，
并提供核查、明确继续和结束。确认绑定选择的完整操作快照，切换/更新阶段清空确认
与密码；恢复任务有独立句柄和代次，关闭取消等待，过期回调不覆盖新状态。页面刷新
和恢复列表分别保留代次保护；已验证操作成功不会被后续列表刷新失败伪装成写失败，
读取错误留在页面的恢复提示。窗口明确说明记录仅限当前 NAS 连接，重连/退出前应
在网页核对未知操作。编辑失败只对相关目标追加恢复入口提示，不误指向无关记录。

新增 `RemoteMountRecoveryTests.swift` **13 个方法**及 Mac 模型 **2 个方法**，覆盖
回执丢失、回查权限错误、两种修改恢复、明确拒绝、取消、父子路径锁、阶段确认、
无密码恢复、结束不回滚、来源漂移、外部断开、跨 Repository/未知编号与错误码边界。
已有同位置修改测试补入继续前的两次只读检查，不降低原断言。**15 个新增 Swift/Mac
测试方法未运行**：尝试 `swift test --package-path apple --filter
'RemoteMountRecoveryTests|DsmFileRepositoryTests|RequestFixtureContractTests|WorkspaceRemoteMountIdentityTests'`
返回 exit 1（本机找不到 swift）。未构建/安装 Mac App，未生成新的 Mac 测试包。

已运行 Windows 原有全量命令 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release -p:Platform=x64 --no-restore -v minimal`：**3084 通过/0 失败/0 跳过**，仅为
Windows 回归。静态本地化、105 请求 fixture、3 响应组/22 私有引用及 diff 检查通过。
独立只读复核检查了错误分类所在的提交边界、阶段/确认状态机、无密码字段、线程
隔离和关闭后的回填代次；没有以代码阅读冒充 Mac 运行证据。既有用户/其他波次改动
保留，无提交/推送、无依赖/标识/签名/权限或磁盘格式变更。

`PENDING_USER_VALIDATION`：在 Mac 运行上述测试与共享包全量、构建 App，按现有
临时签名流程生成独立包；用专用可恢复 CIFS/NFS 共享测试写后断网、核查后继续、
第二步密码失败、关闭窗口、权限/来源漂移及结束剩余步骤。预期每个实际写仅提交一次，
未知只核查，重新输入的密码不保留。回传版本/步骤/脱敏错误，不含路径/来源/凭据。
重新建立 Repository/退出应用不保留操作记录，不能宣称跨重连或跨进程自动恢复；
未执行的请求无法靠一次缺失观察断言永久失败，须用户网页核对。该边界不暂停独立
Windows 批量限制、VMM 和系统集成切片，整体对齐目标仍未完成。

#### 2026-09-20 Mac 挂载确认前身份绑定

复用严格挂载清单，将编辑/断开绑定至窗口显示并确认的来源、协议、位置及自动挂载
快照。提交前重新核对，换位置修改在新连接核实后再次核对旧连接；来源已替换或
嵌套占用时停止。旧无身份写签名保留兼容拒绝，不再供正式界面调用。单一范围为
共享兼容重载、Repository 前置核查、Mac WorkspaceModel/窗口与相应回归；不修改
Windows/Android、依赖、签名或存储，不执行真实 NAS 写。未知结果恢复仍是后续
切片，不把源绑定完成等同完整恢复完成。

已接通 `WorkspaceModel.prepareRemoteMountConnection` → 只读清单 → 编辑/断开窗口
显示来源 → 用户确认 → 带 RemoteMountConnection 的 Repository 重载。旧按路径
直接修改/断开的签名保留为默认不支持，正式窗口不再调用；共享默认实现保持其他
Apple 调用方可编译，不把旧调用自动转换成用户没确认的身份。编辑确认同时绑定
旧连接快照与新配置，任一变化使确认无效。服务器/共享路径从已读来源预填；账号/
密码仍由用户重填，提交和关闭清空凭据。

创建及换位置修改预检目标必须是现有普通目录且不与其他挂载重叠；修改/断开在首次
写入前核对 profile、原来源、协议、位置及自动挂载标志，拒绝嵌套挂载。换位置修改
核实新连接后、卸载旧连接前，再次读取新旧身份和目录状态；旧连接断开后还须确认
新连接依然存在，不能只凭旧位置消失报完成。增加 actor 内同路径/父子路径操作互斥，
取消或前置失败后释放；这是并发保护，不冒充跨重连的未知结果恢复已经完成。

正式测试新增 **10 个 DsmFileRepositoryTests 方法**（旧签名不写、身份替换、跨设备、
嵌套、目标占用/不存在、第二步漂移、同位置顺序、并发取消、创建预检、最终新连接
丢失）与 **4 个 WorkspaceRemoteMountIdentityTests 方法**，后者使用真实仓库和
合成传输检验确认前取值、来源变化拒绝、跨设备零请求及成功后旧确认不能重复卸载。
现有测试迁移到身份重载并补前置读回序列，保留原错误/协议/参数断言；fixture 现在
定位唯一写请求，不能把新增预检请求误当提交。**14 个新 Swift/Mac 方法均未运行**。

实际尝试 `swift test --package-path apple --filter
'DsmFileRepositoryTests|RequestFixtureContractTests|WorkspaceRemoteMountIdentityTests'`
返回 exit 1，本机无 swift。Windows 既有全量命令 `dotnet test
windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore
-v minimal` **3084 通过/0 失败/0 跳过**，仅是 Windows 回归，不替代 Mac 验证。
本地化（Apple 4083 / Android 2188 / Windows 3118）、105 请求 fixture、3 响应组/
22 私有引用与 diff 检查通过。没有生成或安装 Mac 包，没有实际挂载、断开或提交代码。

独立源码复核发现并补上确认中旧身份变化的失效条件，以及最后卸载旧连接后新连接
丢失的检查。已核对 Mac 正式调用方全部迁移，新建也不能覆盖已占用挂载点；保留
工作区已有下载、照片和容器改动。`PENDING_USER_VALIDATION`：Mac 上运行上述三组
及共享包全量、构建 App，并按临时签名流程出独立包；专用共享测试来源替换、缺权限、
并发、取消及新旧位置变化。回传版本/步骤/脱敏错误，不含来源/路径/凭据。下一切片
是提交未知时的本次连接内结果保留、只读核查和显式继续，不新增磁盘持久化；其余
批量/VMM/系统集成目标不变。

#### 2026-09-20 Mac 挂载身份清单与结果证明

源身份绑定和恢复共用一份严格清单，先落实该依赖并接现有写后核查：Mount.List.get
的 profile、协议、来源、挂载位置和可未知的自动挂载标志；与公开 getinfo 一起证明
连接/断开状态。Mac 证据为 DsmFileRepository 原来仅用路径与挂载类型判断成功，
不够证明是本次目标。新清单也供下一步提交前确认快照和恢复窗口复用，不另起请求层。
本波单一范围是共享兼容读取模型/协议默认实现、严格解码、来源规范化、既有结果
核查与正式测试；不修改其他平台实现、不操作 NAS，不把依赖完成写成整个恢复已完成。

已新增兼容 RemoteMountConnection/RemoteMountInventory 与 FileRepository 默认读取
接口；生产实现只调用 Mount.List.get v1，无业务参数，返回严格绑定 profile 的完整
数组。配置布尔和非空行字段类型严格解码；重复路径、未知协议、畸形来源、空值/字符串
自动挂载标志均拒绝。自动挂载键缺失保留 nil，不能冒充 false。UNC 转统一分隔符，
仅主机名大小写规范化，保留远端目录大小写；不读取 actor、账号或凭据，调试描述隐藏
真实来源/路径。坏响应不改写为空清单，读取失败仍隔离在挂载能力内。

现有 create/update 的“连接成功”必须同时满足公开 getinfo 的兼容目录类型、清单中的
精确来源/协议/位置和 auto_mount=false。新位置身份不符时，换位置修改不会进入卸载
旧位置的下一步，也不回滚猜测卸载新位置。断开必须同时有正常目录或明确 408，以及
挂载清单中目标消失；两种证据冲突时保持未确认。保留原有四次只读核查上限，不重放
写请求。这一波完成写后证明，不冒充确认前旧连接绑定和持久结果恢复已实现。

新增 6 个仓库测试方法（严格类型/来源规范化、重复与畸形、错误新来源/未知自动标志
不得断开旧连接、目录与清单矛盾、协议不符）以及 1 个只读请求 fixture 调用测试。
旧成功场景已补对应清单响应，并更新准确请求顺序；错误/取消场景仍保持原断言。
执行 `swift test --package-path apple --filter 'DsmFileRepositoryTests|RequestFixtureContractTests'`
返回 exit 1：本机找不到 swift，**上述 Swift 测试和 Mac 构建均未执行**，没有新 Mac 包。
执行本地化检查（Apple 4079 / Android 2188 / Windows 3118）、105 请求 fixture、
3 响应组/22 私有文档引用和 diff 检查通过；这些静态门不代替 Swift 编译或运行。

独立源码复核确认全部三处连接证明传入预期配置，失败不会进入下一次卸载；正常目录
不再单独构成断开成功。只新增共享兼容读模型，不改身份/依赖/签名/存储；iPhone/iPad
需要共享包回归但不增加入口，Android/Windows 源码不改，工作区已有下载/照片改动保留。
`PENDING_USER_VALIDATION`：在 Mac 跑上述两组和共享包全量，再构建 App；专用共享中
核对真实清单字段、缺权限、网络中断、来源变化与 auto_mount 类型。预期错误来源不
被认作本次连接，矛盾读回不报完成。回传版本/步骤/脱敏错误，不含路径/来源/凭据。
下一切片用该清单绑定确认前旧连接并接未知结果恢复，目标未收窄、尚未整体完成。

#### 2026-09-20 Mac 挂载协议同类缺陷修正

用户已授权修复后续同类 Mac 基线缺陷。当前证据为 DsmFileRepository.mountRemote/
unmountRemote 仍发送无证据别名，编辑器仍承诺无接口支持的 readOnly；以挂载端点
记录和四份请求 fixture 修正，不能复制这些旧请求到其他端。单一范围为共享挂载
配置的兼容 NFS 选项、能力发现、请求构造/输入拒绝、Mac 编辑器对应字段及正式回归。
保留既有下载/照片和容器改动，不操作 NAS、不修改依赖/签名/存储，不新增移动端写
入口；iPhone/iPad 仅受共享包兼容回归影响，Android/Windows 本波实现不改。
内部高风险写：请求修正不代表 Mac 源身份核查、阶段恢复等剩余安全语义全部完成；
本机无 Swift/Mac 工具链，目标构建和真机以 PENDING_USER_VALIDATION 后置。

已修改共享 FileStation.swift 配置的兼容默认 NFS 3/TCP 选项及安全调试描述；
DsmCapabilityDiscovery 增加 Mount.List v1，并与 Mount v1/List v2 一起判断可管理。
DsmFileRepository 的创建只发送固定七字段，域账号合入 account，NFS 发送字符串
nfs_version/protocol；断开改为 Mount.List.unmount 和挂载点数组，不发送删除目录。
参数别名、伪只读字段已移除。输入控制字符/父子目标/无效账户或 NFS 4+UDP 在任何
旧连接修改前拒绝；显式要求 readOnly 返回不支持，不默默丢弃。能力缺失先失败，
不在写入之后才发现缺少回查接口。保留先前回查失败不作消失、无依据回滚移除的修正。

Mac 编辑器移除只读开关，增加 NFS 版本/传输方式，NFS 4 固定 TCP；切换 NFS 清空
共享账号/密码/域。风险确认绑定当时的完整配置，而非只靠字段变化事件；提交期间
冻结字段，提交和关闭都清空密码及确认快照。确认快照仅为当前表单内存，不新增
密码持久化。UI 增加普通用户影响说明，保持原生 SwiftUI 和英/简中资源。

新增 7 个 DsmFileRepositoryTests 测试方法，覆盖 JSON 类型、NFS、Mount.List 数组、
非法配置/路径零提交、缺能力、调试隐私及父子位置拒绝；修正已有 FORM 请求断言。
RequestFixtureContractTests 新增 1 个方法，用真实调用链分别匹配 CIFS/NFS/断开
三份共享 fixture，并完整核对参数键与认证位置。**以上 Swift 测试均未运行**：执行
`swift test --package-path apple --filter DsmFileRepositoryTests` 返回 exit 1，系统
找不到 swift。没有安装/升级工具链，没有触发提交或 CI，不生成 Mac 修复包。

本机已执行：Windows 全量 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release -p:Platform=x64 --no-restore -v minimal` **3084 通过/0 失败/0 跳过**，只作
现有 Windows 回归，不作为 Swift 或 Mac 证据。本地化、105 请求 fixture、3 响应组/
22 私有文档引用与 diff 检查通过。独立源码审查核对新增调用版本、参数白名单、旧
未知处理未退化和共享默认值兼容；未作 Mac 编译或原生截图验收。

`PENDING_USER_VALIDATION`：需 Mac 的 Swift/Xcode 环境，先运行 DsmNetwork 全量与
RequestFixtureContractTests、Mac App 构建，再按现有临时签名流程生成独立包。
专用 CIFS/NFS 共享验收域账号、NFS 3/4、断开及两种修改；期望无重复别名、密码不
入 URL/日志，非法配置不先断开旧连接。回传版本、脱敏错误类别与所在步骤，不含
真实主机/路径/账号。Mac 的完整源身份核查及未知结果恢复仍为独立源码剩余项，
不能把本次协议修正或 Windows 已交付结果当作这两项已完成。

#### 2026-09-20 Windows 挂载原生管理交互

在上一波阶段式核心之上替换 FileLocationsView 旧表单，沿用现有 ContentDialog 与
可测试状态层：新建/选择连接/修改/断开、冻结确认、未知只核查、第二步显式继续。
恢复数据只保存无密码配置，CIFS 继续连接时重新输入密码；断开阶段不重复索要密码。
用户输入和实际权限决定入口可用，不将“待真实验证”作为固定禁用条件。Mac 语义
依据 DsmFileRepository 的两种修改顺序，参数依据挂载端点记录；不复制旧只读字段、
ISO 表单或 immutable mount point 限制。风险为内部高风险写，真实 NAS 不操作。
本波单一修改范围为挂载进度兼容增量、Locations 状态层、原生内容与宿主入口、双语
资源及聚焦/原生测试；不改依赖、权限、身份、持久化或其他四端实现。

已将 FileLocationsView 三个操作入口接入同一原生管理窗口，入口使用新核心真实
能力、绑定会话和接口版本；不再依赖旧 AllowsRemoteMountManagement 固定关闭标志。
移除旧表单、猜测请求参数及“收到回执即成功”的不可达平行路径；旧接口仅保留不
发送请求的兼容返回，不能成为绕过风险确认的写入口。新增 RemoteMountSetup 与可选
Continuation 为向后兼容的无密码恢复信息，不新增持久化；固定配置摘要不包含密码，
用户名/域/目标/协议等仍绑定原确认，继续连接才重新输入密码，断开阶段不索要密码。

新增 RemoteMountManagementViewModel、RemoteMountManagementDialogContent 和宿主
生命周期：连接列表/筛选/空状态、CIFS/NFS 与 NFS 4 固定 TCP、可编辑新位置、两次
明确确认、只读结果核查、关闭/离页/切换 profile 清理。已完成操作不连点重发，未知
结果即使暂时不在恢复清单里也不自动解锁。断开说明明确不会删除目录；去掉无证据
的只读保证和 ISO 连接表单。界面文字新增 53 项双语资源，恢复配置不会显示密码。

独立集成/只读对抗复核覆盖配置漂移、凭据生命周期、已取消异步结果、会话隔离、
缺失恢复项和旧传输残留。原生试跑发现并修正：字段刚变更时事件尚未处理导致旧确认
仍有效，以及刷新列表反复重设选择造成恢复窗口事件循环。确认和保存现在直接核对
当前控件值；列表仅在内容变化时更新，程序恢复选择不作为新的用户操作。首次 XBF
模板编译失败已改用项目现有普通绑定方式；清理旧代码遗漏的共享认证助手已恢复。

单元新增 14 项管理状态测试与 2 项真实传输恢复测试；全量首次通过 **3084 项**。
原生宿主直接使用正式 FileLocationsView 入口、内容控件和状态层，不连接 NAS；断开/
两种修改、键盘确认、目标临时变更、未知/核查/恢复、关闭和 profile 切换均有断言。
截图完成标志在全部生命周期断言之后才写出，不能靠提前截图掩盖后续失败。

最终原生测试命令 `windows/tests/UiSmoke/run.ps1 -Scenarios remote-mounts -Language
en-US -WindowWidth 900 -WindowHeight 740` **19 场景通过**（`ui-review-20260920-060946`）；
同一最终宿主 `-SkipBuild -Scenarios remote-mounts -Language zh-CN` **19 场景通过**
（`ui-review-20260920-061146`）。浅深色/宽窄窗人工查看恢复与确认截图，表单支持滚动，
确认可键盘聚焦。此前 `060703` 的四个聚焦场景覆盖恢复/关闭/切换回归。没有实际
NAS 写请求，不以截图或合成代理提高接口证据等级。

`PENDING_USER_VALIDATION`：使用已记录版本且可恢复的专用共享，在文件位置的远程
连接入口执行创建、断开、同位置修改与换位置修改，核对 NFS 3/4、域账号与权限失败；
在请求后中断网络，再进入“尚未完成的操作”核查。预期未知不重发，第二步只有重新
确认才提交，关闭后密码为空，断开不删除目录。请只回传版本、脱敏错误、所在步骤与
新旧连接状态，不发送真实路径/账户/密码。恢复限同一客户端生命周期，应用重启后
需先在网页核对状态；不新增凭据或操作日志的持久化。Mac 别名修正、其他批量限制、
VMM 高级管理和系统集成仍是目标内剩余工作，本波不宣称全部对齐完成。

最终交付 `windows/dist/20260920-061156`：按既定 `windows/package.ps1`，设置
LANSTASH_NON_INTERACTIVE=1、TARGET_PLATFORM=both、RUN_TESTS=1、LAUNCH_AFTER=0
（后面三项同属 LANSTASH_ 前缀）运行，终态 exit 0。实际执行完整 **3084 通过/
0 失败/0 跳过**，x64/ARM64 Release 自包含 publish 均成功；未安装/启动、不覆盖旧包。
两份 build-info 的架构、selfContained 与 testsRun=true 核对一致，正式 App DLL
不含 SmokeRemoteMountRepository 或 LANSTASH_SMOKE_SCENARIO 合成入口。SHA256：

- x64：`96527997604A1C9296EE59A46C50E7DBAC84EE132014841A4EEF849FB7AE7E5A`
- arm64：`0A7F0D0CD65B03C22B15E8DF20FB5909F831DFD1367FD99DC908519B7989716F`

源码基于 main@0eeeb170358c 加现有未提交工作区，无提交/推送。本波保留既有改动，
打包期间未改生产源码。最终本地化（Windows 3118）、105 请求 fixture、3 响应组/
22 私有引用、严格文档检查和 diff 空白检查均通过。macOS/iPhone/iPad/Android
未修改，未构建 Mac 修复包；真实 NAS 写行为与正式发行仍未验证。

#### 2026-09-20 Windows 挂载阶段式操作核心

在已验证协议层之上接入固定请求编号、用户确认快照、目标目录 getinfo 预检、
挂载源/协议/自动挂载标志回读与路径互斥。创建、断开、同位置修改、换位置修改
都按阶段执行；修改的第二个写步骤要求再次明确继续，未知只核查不重发，不盲目
回滚。恢复记录不保存密码，继续连接时需重新提供同一确认配置；没有持久化迁移。
旧 UI 无法表达阶段和冻结的挂载身份，暂不接到新核心，随后独立迁移原生窗口。
单一范围是 Locations 兼容请求/进度接口、操作核心、协调器与正式测试；不操作
真实 NAS，不改 Mac/Android，不把核心通过当作界面流程已完成。

Mac 语义证据为 `apple/Packages/DsmNetwork/Sources/DsmFileRepository.swift` 的
create/update/deleteRemoteMount 与 verifyRemoteMount；请求以端点记录为准，不复制
旧别名。Windows 按原生确认窗口分阶段转换：同位置修改先断开后连接，换位置修改
先确认新连接再断开旧连接；每次明确继续前重查身份、目录及新旧连接。风险级别为
内部高风险写；目录可见性与远程挂载开关是客户端预检，不伪造未记录的 ACL 权限位，
最终写权限仍由 NAS 判断。运行时恢复依赖同一 API 客户端，不新增跨进程持久化。

已完成固定请求编号与配置摘要、同会话范围共享互斥、未结束目标的父子路径锁、完整
挂载身份核对、getinfo 明确目录类型/408 缺失核查。读取失败/缺字段/不明类型不作
断开成功；新连接失效或旧连接被替换时不能继续断开。未知不自动重发、回滚或调用
FileStation.Delete；第二步显式失败保留部分完成，已取消调用仍返回之前已生效步骤。
只读对抗复核补上取消前后边界、嵌套挂载保护、HTTP 认证/权限拒绝后停止访问；没有
绕过证书或增加原始发送点。恢复记录只持有身份和配置摘要，不持有密码或可重放字典。

新增 `RemoteMountWorkflowTests` 的 **39 项**合成案例，覆盖 FORM/JSON 的 CIFS/NFS、
两种修改顺序、读写失败、取消、跨 Repository 恢复、身份漂移、会话隔离、父子路径
互斥与真实异步并发。实际执行 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj
-c Release -p:Platform=x64 --no-restore -v minimal`：**3068 通过/0 失败/0 跳过**。

两架构实际构建命令为 `dotnet build windows/src/LanStash.App/LanStash.App.csproj -c
Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal`，
以及 Platform=ARM64 / win-arm64 变体，均 **0 警告/0 错误**。执行并通过
`tools/localization/check_localization.py`（Apple 4067 / Android 2188 / Windows 3065）、
`tools/request-contract/validate_contracts.py`（105 请求 fixture）、
`tools/contract-validation/validate_fixtures.py`（3 组/22 私有引用）、
`tools/codex/check_documentation.py --strict-release` 和 `git diff --check`。
本轮没有新增依赖、用户文案、权限、签名或存储变更；保留工作区既有未提交改动，未提交/
推送。测试及构建均在 Windows 本机，不替代托管 Runner 或 Mac 目标平台验证。

`PENDING_USER_VALIDATION`：待原生管理窗口完成后，在专用可恢复的 CIFS/NFS 共享上
分别创建、断开、同位置/换位置修改并中断连接；预期每个写步骤有确认，结果不确定时
仅核查，旧/新挂载身份漂移不误断开。回传脱敏状态、步骤、DSM/套件版本与错误类别，
不回传主机、账号、路径或凭据。真实非空清单字段、权限、副作用和 NFS 选项尚未验证。
这不是挂载功能整体完成：原生窗口、无密码的继续交互及旧关闭入口迁移是下一切片，
本波不生成用户测试包，其他四端实现不改、兼容等级不提升。

#### 2026-09-20 Windows 挂载协议层实现

本波先落实已发现的协议依赖：严格挂载清单读取、CIFS/NFS 正确参数构建、类型保持
与专用传输单次提交。随后集成创建/编辑/断开的阶段式结果核查和原生确认。单一
范围为 Locations 模型兼容增量、协议构建/读取和 transport、相关正式测试与契约；
不把未完成的编排/UI 提前开放。旧 RemoteMountDraft API 保持兼容，NFS 默认 3/tcp，
不隐含开机挂载或建删目录；明确要求 NAS 强制只读时返回不支持，不静默丢弃该要求。
域账户以显式的 domain\\user 形式进入 account，不发送未经证据支持的 domain 别名。
不更改依赖、凭据存储或持久化结构，Windows 类型保持新旧构造器兼容；其他四端只
同步影响记录，不改实现。当前源码/模拟测试不作为真实 NAS 写行为证据。

已接 RemoteMountProtocol、可选 NFS 版本/传输字段、严格 RemoteMountInventory，
新 DTO 默认构造保持原调用兼容；读取只调用 Mount.List.get v1。专用发送层扩展
明确的 Mount.mount_remote / Mount.List.unmount，保留既有会话/证书与一次发送
边界；旧 UpdateRemoteMount 字符串请求不支持，也不发送 FileStation.Delete。
控制字符不再被构造器 Trim 悄悄修复为另一个目标，密码仍保持原文且不出现在记录
ToString 中。确认/源与目标身份复查/未知恢复与 UI 尚未接入，保留关闭门，不宣称
远程位置可用。不是新实现的功能因“未真实验证”而恒关，而是上层流程确实未完成。

新增 29 项协议测试（FORM/JSON、CIFS/NFS、断开数组、NFS 3/4、错误字段/方法/
控制字符、只读不静默忽略、完整类型/重复身份基础校验）；首轮 1 项测试复现 Trim
丢弃换行，已修复。完整
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal`
为 **3029 通过/0 失败/0 跳过**。新四份请求 fixture 与实际传输断言绑定，合计
105 请求校验通过；没有写入凭据或真实远程地址。x64/ARM64 生产构建均 0 警告/
错误；本波无 UI 改动，不重新运行或宣称原生交互已通过。未打新包，已有交付不含
本波协议层；只有完成上层安全编排后才提供可操作的挂载测试入口。

后续集成必须检查目标目录/现有挂载的身份、权限和修改分步确认，未知状态不得
自动执行下一个写步骤；尤其不能因旧读取失败而认为已断开。Mac 参数适配另列，
其他独立 VMM、系统集成和批量功能目标保持不变。未提交或推送。

#### 2026-09-20 挂载契约重新发现与 Mac 回查安全修复

本轮官方 FileBrowser.js/自然 Mount.List.get 证据显示旧 Windows 方法和 Mac 多组
别名都不可靠，详见新的 file-station-remote-mount 端点记录。先建立正式契约切片，
不把 Mac 旧请求照抄到 Windows。用户既有同类基线修复授权覆盖 Mac 回查失败误作
已断开和无依据回滚问题；当前单一源码范围为 DsmFileRepository 挂载回查/修改失败
路径、专用回归和双语文案，不改公共 getInfo 的其他调用方。
Mac 的常规 getInfo 会过滤遗漏/404 条目，不能单独用空结果证明已断开。本切片使用
单目标严格响应，读取/解码失败、遗漏或类型未知均为未确认；只接受正常本地目录或
明确的单项目标不存在码证明未挂载，不把 iso/remotefail 误作正常远程连接。
修改失败不盲目断开新位置；新旧状态交给用户核查。Windows 写接线和只读策略/NFS
选项仍为后续契约适配切片，不直接开放错误参数，不执行真实挂载/断开。

已核对当前官方 Session 白名单版本/权限、自然 Package.list 的 File Station 版本，
Mount/Mount.List 能力缓存与空 Mount.List.get 响应；方法参数和非空记录字段仅是
静态证据。已关闭本轮两个 File Station 窗口和套件中心，保留原页面；无原始响应、
脚本、HAR 或截图写入仓库。端点记录从概括索引拆为独立文件，机器索引同步，历史
lab-a 证据不升级。

Mac 回查不再使用 try? 和被过滤的 getInfo 空列表，改为单目标匹配、明确 408 或
目录挂载类型；遗漏、读取失败、缺字段、remotefail/iso 不能证明已断开。修改新旧
目标状态不明时不盲目卸载新位置，保留认证/证书/取消错误，不提示自动重试未知写。
新增 5 个 Swift 回归函数（含多种畸形响应），本机无 Swift，全部未运行。Mac 的
旧请求别名和只读参数仍须按新契约纠正，不能因安全修复而宣称已接通。

Windows RemoteMountDraft/Configuration 调试字符串不再展开密码或服务器信息，
密码原文保留（包括首尾空白）；新增回归已执行。完整命令
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal`
为 **3000 通过/0 失败/0 跳过**，挂载聚焦 15 通过；本地化 Apple 4067/Android
2188/Windows 3065 通过。契约引用检查首次提示新端点缺少反引号标识，已补齐后复验。
没有发布新运行包，Windows 最新包仍 20260920-043804（不含本轮调试字符串改动），
Mac 未打包；未暂存/提交/推送。

PENDING_USER_VALIDATION：Mac 工具链先执行 DsmFileRepositoryTests 和 App 构建；
回查断网、权限失败、遗漏条目、目标变化应显示未确认而非成功，不自动执行额外
卸载。真实挂载写需专用可恢复共享，由用户手动验收；只回传版本和脱敏错误。
下一切片按已发现的正确参数实施 Windows/Mac 请求、目标目录预检和未知恢复，
不能复制没有证据的 read_only/domain 或自动目录删除动作。VMM 等独立目标继续保留。

#### 2026-09-20 Windows 收藏真实请求链路

基线为 Mac WorkspaceView.toggleFavorite 与 DsmFileRepository 的 Favorite v2
add/delete/list；Windows 仅有抽象提交接口和不可达的写分支，正式界面也没有调用
添加/移除方法。本波单一范围：Favorites 专用传输、现有仓库预检/结果回读与同作用域
未知锁、Locations 恢复状态、文件页菜单/工具栏和对应资源/测试。不改 API 参数，
客户端恢复接口为兼容默认增量，无持久化、依赖、权限或身份迁移；其他四端不改。
收藏是低影响可逆操作，不删除 NAS 文件；当前 profile、会话、能力、完整列表、
目标名称和结果必须核对。远程挂载实际存在 create/update/delete 与已记录
mount_remote/unmount 的偏差，保持独立关闭，不能因实现 transport 标记接口而误开放。
后续单列挂载契约修复，不发送猜测的内部请求。本机仅用合成数据，不操作真实收藏。

已接专用 IFileLocationMutationTransport 的真实 DsmApiClient 实现，仅允许 Favorite
v2 add(path,name)/delete(path)，限制种类/方法/参数白名单，FORM/JSON 按声明编码；
Favorite.list 的 JSON 读取仅开放固定 v2 list 和数字 offset/limit，不扩大全局读写
范围。沿用现有 HTTPS 会话正文/请求头与证书连接上下文，不接受调用者注入认证字段。
删除的仅为收藏引用，不调用文件删除。远程管理独立保持关闭，transport 也拒绝挂载。

仓库使用当前 profile/会话/地址作用域锁，提交前/后要求完整收藏列表；名称歧义或
截断列表不能确认操作，添加同时核对路径与名称，移除按完整列表确认不存在。已有
相同收藏/已不存在的收藏作为幂等成功，不再发送；明确拒绝保持失败，未知锁只读
核查，不因相反操作或重建仓库重发。文件页“更多”和右键共用入口，选择目标或当前
目录可添加/移除；未知时切换“核查收藏状态”，卸载/关闭取消本地等待，迟到结果
不影响其他目录或 profile。侧栏随结果刷新；读前确认与回读不宣称 NAS 行为已实测。

实际验证：新增 21 项自动化，完整 **2999 通过/0 失败/0 跳过**。真实 HttpClient
合成覆盖 FORM/JSON、绑定会话/证书上下文、参数注入拒绝、完整/截断/歧义列表、
名字不匹配、并发、丢失回执、取消、重建仓库只读恢复及跨 profile 隔离，生产请求
断言对齐共享 add-favorite 和新 remove-favorite fixture。

首轮全量触发裸发送源文件清单门禁，增加已核对的新路径和单次发送计数，并新增
运行时断言证明 AddMutationRequestHeaders 将 profile/连接来源传给证书处理器。
新测试一度错误要求正文无会话字段；核对既有 HTTPS 正文/请求头策略后改为验证绑定
会话值与 URL 不含凭据，没有更改认证机制。原生夹具首次缺少回收站快照 Completion
参数导致构建失败，补齐正常必填参数后恢复，不降低既有断言。

中文/英文原生各 12 场景通过，目录 windows/dist/ui-review-20260920-043132、
20260920-043328，覆盖添加/移除、当前目录、未知/恢复、权限、只读、关闭中断与
profile 变更。实看中文深色成功提示；页面确认结果与侧栏集合一致。命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios files-favorites -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios files-favorites -Language en-US -WindowWidth 1000 -PaneState compact
```

本地化 Apple 4065/Android 2188/Windows 3065、101 请求 fixture、3 响应组/22 私有
引用与差异检查通过。PENDING_USER_VALIDATION：在可恢复测试目录添加与移除收藏，
核对名称/路径与不删除文件，断线只核查不重发；需 Favorite v2 能力与实际账户权限。
不收集账号/路径/凭据，失败只回传版本、动作和脱敏错误。未执行真实 NAS 写；
Mac/Android 未改源码。远程挂载是下一独立切片，不能当成已接通。

`windows/package.ps1` 使用 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0，在打包内运行全部 **2999 项通过**，
生成 windows/dist/20260920-043804 的独立自包含 Release x64/ARM64。未安装/启动，
旧包保留。build-info 已核对 main@0eeeb170358c 加 dirty、版本 0.1.0、架构、
Release、testsRun/selfContained=true；ZIP 和 sidecar 的 SHA256 一致：

- x64：`B093B1E123EC0D57D61330E23419B499C835011526BB87B64FAEE55DB5484CBC`。
- arm64：`2CF25B34BB9D555CE8A58326AE58A9939E68FFD9346F98C043932A7E1CED6B2D`。

未暂存/提交/推送；保留所有既有无关改动。本波只交付 Windows 收藏链路，不宣称
远程挂载或整个跨端目标完成。

#### 2026-09-20 Windows 压缩选择数量对齐

macOS 证据为 WorkspaceView 的 compressionTargets、WorkspaceModel.enqueueCompression
与 DsmFileRepository.compress：接收完整非空选择，不设 20 项客户端上限。Windows
本波移除共享选择器对压缩的限制、按钮/窗口守卫及 Repository/Transport 重复数量
守卫；仍是同目录的一次压缩任务，不拆包、不静默截断。API 参数与五端公开协议不
变，其他端不改；允许本机测试大批量，实际 NAS 容量/请求大小限制不宣称无限制。
单一修改范围为上述五个守卫、预检查找、相关双语文案及正式测试。保留来源权限、
原始身份/元数据、重复/同父目录、回收站排除、名称冲突、确认、防重放和完成回查。
其他下载/复制/回收选择限制不在本波中顺带改变，需各自核对，不冒称所有文件操作
已对齐。没有依赖、存储、权限或身份迁移，无真实 NAS 写操作。

已完成五处数量门及对应文案调整；同父目录规范路径已排除祖先关系，因此移除
冗余两两比较。NAS 基线改为按路径索引，窗口确认用 FileItem 完整记录集合比对，
避免大批量逐项重复扫描；路径/名称/类型/大小/修改时间仍须相同，不以仅有路径
替代原有身份核查。空选择、重复源、跨父目录/父子、远程/回收来源仍拒绝。

新增 13 项回归：21/200/1001 路径完整进入同一 POST，21/205/1001 项跨分页预检
及一次任务回查，末页权限/元数据变化、末尾非法/重复/父子来源全部拒绝，未知大
批次更改末项不能重放。压缩聚焦命令 46 通过，全量 2978 通过/0 失败/0 跳过：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal --filter FullyQualifiedName~FileArchiveCompression
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios files-archive -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios files-archive -Language en-US -WindowWidth 1000 -PaneState compact
```

中文/英文原生各 16 场景通过（windows/dist/ui-review-20260920-035043、20260920-035303），
真实选择控件跨页选中 205 文件加 1 文件夹，切换列表/网格保留 206 项，按钮可用，
单次提交完整集合；同一用例先验证普通下载仍受原有保护。实看中文深色确认截图
显示“206 项创建为一个压缩包”，格式/级别/密码控件正常。补窗口记录集合优化后，
中文大批量与末项变化 10 场景复跑通过（20260920-035446）；末项变化不发送写请求。
英文相同 10 场景复跑通过（20260920-035819）；不把合成回归当真实归档内容验证。

本地化检查 Apple 4065/Android 2188/Windows 3050 通过（删除过时上限资源键）；
100 请求 fixture、3 响应组/22 私有引用与 diff 检查通过。API 参数没有改变，其他
四端实现不变；本波没有 Swift 改动，既有 Mac 下载/照片/镜像修复仍待目标构建。
PENDING_USER_VALIDATION：用户在可恢复目录选超过 20 项创建单一 ZIP/7z，核对所有
选中项与目录结构、密码可用性；权限/冲突失败应不创建，断线结果未知不重发。真实
NAS 负载、可接受请求大小及归档内容未实测，仅回传规模、版本和脱敏错误。

下一切片优先接收藏/远程挂载的真实传输层，VMM 和系统集成目标继续保留。

本波 `windows/package.ps1` 设置 LANSTASH_NON_INTERACTIVE=1、
LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0，
打包内完整 **2978 项通过**，双架构 publish 完成，独立目录
windows/dist/20260920-035952。未安装/启动，不覆盖或删除旧包；build-info 已核对
main@0eeeb170358c 加 dirty、版本 0.1.0、Release、架构、selfContained/testsRun=true。
ZIP 与 sidecar SHA256 一致：

- x64：`34EA1DEF88BDC19701812AC18A4DCC24AC0E82E7F5D699DE7FDD2C04FEE5909B`。
- arm64：`654AF23BC7D3A1FC36114D2DC71C8338D12D51CC800A6CD60E858FCC8C5EC5F1`。

未暂存、提交、推送；原有无关工作区改动保留。没有 Apple 源码改动或 Mac 构建。

#### 2026-09-20 Mac 镜像拉取任务追踪源码

延续前一波 Windows 契约和用户对 Mac 同类缺陷修复的授权：Mac 原始启动提示准确，
本波补丢失的任务身份、进度、独立只读核查和防重复流程。单一修改范围为共享兼容
请求/结果/默认协议方法、已有镜像适配器、独立 Mac 拉取状态模型、现有搜索窗口
接线和相应测试/双语资源；不改其他模块或 Apple 移动端范围，不触碰 Android。
用户先核对仓库和标签，窗口关闭仅取消本地等待，重开读取同一仓库实例的任务记录。
任务结束/回显/完整标签回读共同确认可用；未知不重发，不发未发现的 NAS 取消接口。
模型不持久化，不改变依赖、身份、签名或权限；回滚撤销增量及窗口接线即可。
Mac/Swift 工具链本机不可用，源码和未运行的测试分别记录，不用 Windows 通过替代。

已新增共享 ContainerImagePull 请求/进度模型和默认不可写协议方法，实际适配器
以 v1 读取标签/启动/状态，旧 Void 启动入口委托同一流程。记录任务编号、原请求
和标签基线；未知不重放，已确认终态缓存，下载与相应标签/裸镜像删除交叉保护。
数字任务编号只接受 Double 安全整数，超范围不能四舍五入后查询另一个任务。
任务编号不进入公共进度模型或日志。结束须 finished 原生布尔、仓库/标签回显
匹配及完整标签清单可用；百分比和旧标签不能单独确认。

Mac 新增 ContainerImagePullModel，绑定固定仓库实例；原搜索窗口加入搜索/任务
分区和目标确认，手动核查不启动，默认 5 秒只轮询可见下载任务。窗口消失取消
启动等待/手动查询和 SwiftUI 观察任务，未收到回执仍保留本地占位；同仓库迟到
启动结果可入账但不覆盖新窗口忙碌状态，终态不被旧缓存降级。关闭按需刷新父列表，
不是继续隐藏任务轮询。恢复只限本次连接内存；重新登录或重启后提示先在 DSM
核查，不猜测全局任务，不把该限制包装成已经实现跨进程恢复。

独立源码复核确认 DsmAPIClient 单次发送，不因改用泛型读取回执而自动重试；保留
证书/认证传输边界。补了预检取消的 AppError 分类，不能把“尚未发送”记成未知写。
新增 19 个 Swift 测试函数（网络 11、Mac 模型 7、共享请求 1），覆盖 FORM/JSON、
安全整数、无回执、原生状态、回显/标签复查、100% 非完成、权限拒绝、取消前后、
删除交叉锁、固定确认、可见轮询、关闭/复开、迟到结果和终态不降级。原兼容入口
测试增加预检/状态链路并实际重复调用，保持仅一次 pull_start 断言；全部未运行。

本机实际验证：

- `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal`：2965 通过、0 失败、0 跳过，防止共享契约文档变化影响现有 Windows 门禁。
- `tools/localization/check_localization.py`：Apple 4065、Android 2188、Windows 3051；双语/占位符/硬编码扫描通过。
- `tools/request-contract/validate_contracts.py`：100 请求 fixture 通过，新增 Apple 请求断言复用 Windows 的启动/状态共享样例。
- `tools/contract-validation/validate_fixtures.py`：3 响应组/22 私有引用通过；`git -c core.safecrlf=false diff --check` 通过。
- `Get-Command swift`：未找到工具链；没有执行 `swift test --package-path apple` 或 macOS App 构建，不报告目标端通过。

PENDING_USER_VALIDATION：在 Mac 工具链环境先运行共享包与 DsmMacTests、按既有
本地临时签名流程构建测试包；Source/Tests 自动包含在原 Package.swift/project.yml
的目录范围，没有手改生成工程。实测搜索/标签/确认、任务页进度、完成保留旧标签
缓存命中、关闭后同连接复开、取消/断网未知不重发，以及浅深色、键盘和 VoiceOver。
仅回传版本、操作、脱敏错误；不要提供任务编号、私有仓库名、主机或凭据。未新增
真实 NAS 写、未打 Mac 包、未提交/推送。Windows 生产源码未改，不重打相同包；
最新 Windows 交付仍为 20260920-030258。下一切片继续文件或 VMM 剩余开发。

#### 2026-09-20 Windows 镜像拉取任务闭环

macOS 证据为 PullImageSheet 的仓库搜索/标签选择和 pullContainerImage；目前只
提交启动并显示“已开始”，任务身份与进度被丢弃。Windows 等价结果为确认所选标签
后开始下载、当前窗口按任务身份读取进度、关闭停止本地等待、重开只读恢复；已有
镜像可能更新，确认随目标变化失效。普通用户主动写，涉及下载/占用空间，不启动
镜像或容器。契约依据官方静态 pull_start/pull_status，终态/无回执边界见发现记录。
本波单一范围：容器领域兼容模型/默认接口、现有协调器、拉取核心、Registry 原生
流程/资源/测试和文档；Mac 同类任务追踪作为后续相邻切片，不改变移动端只读范围，
Android 不改。既有兼容扩展授权覆盖此增量，无依赖、存储、身份或权限迁移；回滚
移除入口和增量模型即可，不改 NAS 数据。真实 NAS 写不由 Agent 执行，不提升等级。

已接 Windows 请求/进度结果模型、启动和只读核查、同客户端作用域恢复，以及
Registry 窗口确认/开始下载/任务列表。启动回执只接受原生字符串或非负整数 task_id，
保持类型回传，不从聚合 admin 任务猜绑定；状态必须原生 finished 并匹配仓库标签，
结束后完整镜像清单确认标签可用。百分比只供显示；旧标签存在或 100% 均不能单独
确认结束。回执缺失、断线、取消、状态不可读保留未知锁，不重发启动。关闭只停止
本地等待，无发现证据的 NAS 取消接口不实现。已知任务核查不依赖 Registry 能力；
镜像拉取和对应标签/裸镜像删除交叉互斥，其他独立操作不被永久关闭。

新增 34 项自动化覆盖核心、ViewModel 与窗口生命周期接线。完整
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal`
为 **2964 通过/0 失败/0 跳过**。FORM/JSON 启动与状态断言绑定两份新增共享 fixture，
含数字任务 ID、无回执、回显错配、部分清单、异常进度、权限拒绝、取消、不重放及
删除交叉锁。另发现旧 delete-image fixture 仍声明单 id，已更正 images/identity，
Apple 构造器和 Windows 实际裸镜像删除断言同步，避免与新标签契约并存矛盾。

原生宿主首轮因缺少 ContainerImagePullItem 命名空间失败，添加正常 using 后恢复。
中文/英文各 16 场景通过（windows/dist/ui-review-20260920-024650、20260920-024933）；
初始功能断言虽通过，截图中任务区仍在可视范围外，已补列表布局后滚动到任务区，
两语各 8 场景复跑通过（20260920-025130、20260920-025315）。实看中文深色截图，
25% 进度、任务名称与核查按钮可见；不把合成显示或静态脚本当真实 NAS 结论。
最后源码审查将正常关闭的定时器释放提前到 dialog.Closed，避免主列表刷新等待期
仍保留隐藏轮询，并增加复开时“关闭事件已停止定时器”的原生检查。

最后生命周期复核的复开、关闭中断、可见自动轮询 3 场景通过，目录
windows/dist/ui-review-20260920-025646。又新增重连回归复现旧缓存认证错误错误地
锁定新连接：用例首先真实失败（RequiresReconnect 仍为 true），修复为只有当前
提交/查询能锁定连接，不沿用缓存认证状态后，完整 **2965 通过/0 失败/0 跳过**。
该增量只影响恢复状态，不放松服务端认证或未知写锁。最终交付必须采用包含这项
修正的新独立包，而非前两份中间构建。

已执行的界面命令：

```powershell
./windows/tests/UiSmoke/run.ps1 -Scenarios container-image-pull -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-image-pull -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios container-image-pull -States pull-running,pull-ready,pull-no-receipt,pull-reopen,pull-recovery,pull-review -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-image-pull -States pull-running,pull-ready,pull-no-receipt,pull-reopen,pull-recovery,pull-review -Language en-US -WindowWidth 1000 -PaneState compact
```

两架构生产构建已有 0 警告/错误记录，最终包还须包含滚动和关闭生命周期修正。
本地化/硬编码检查 Apple 4044、Android 2188、Windows 3051 通过；请求 fixture
校验增至 100，响应 3 组/私有引用 22 项通过，差异检查通过。Mac 当前显示“已开始”
文案本就准确，本波不冒称修正“已完成”误报；Mac 丢弃任务身份/缺追踪仍是下一
独立源码切片，除契约构造器测试外不改 Apple 代码，Swift 测试未运行。

PENDING_USER_VALIDATION：在专用可恢复环境选择公开镜像标签，确认后查看进度，
关闭/重开只读恢复；完成需任务结束且标签存在，旧标签和缓存命中不保证远端内容
发生变更。断网/无回执不得再次启动同标签，先在 DSM 核查；App 不承诺关闭窗口能
停止 NAS 下载。需 Image v1、启动时 Registry v1 和实际下载权限；真实 task_id/
finished 字段类型、异常终态、普通账号与 QuickConnect 行为尚未执行验证。仅回传
版本、动作、脱敏错误，勿回传仓库凭据或私有名称。未暂存、提交、推送或安装/启动
交付包；合成 UI 宿主独立运行，不加载用户配置或 NAS。

最终 `windows/package.ps1` 使用 LANSTASH_NON_INTERACTIVE=1、
LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0，
打包内实际 **2965 项全通过**，生成 windows/dist/20260920-030258 独立自包含
Release x64/ARM64。包含滚动定位、窗口关闭释放和重连缓存认证修正；未安装/启动，
保留旧包。build-info 已核对 main@0eeeb170358c 加 dirty、版本 0.1.0、架构、
Release、testsRun=true、selfContained=true；ZIP 与 sidecar SHA256 一致：

- x64：`E846D519C09157722917E99A23C656920ED85FAA5AAEF61A7C991BDA5C2554A7`。
- arm64：`728BF06D62726A462C4394C6567FE9B6C9C7860AAB42EBB79B819F10ABF75A59`。

不是正式发行或 Mac 包，没有新的真实 NAS 验收。下一独立切片为 Mac 拉取任务追踪；
VMM 高级管理、文件收藏/挂载实际链路、压缩选择上限和 Windows 系统集成目标不变。

#### 2026-09-20 Mac 镜像删除基线修复源码

延续用户对同类 Mac 缺陷的修复授权：现有 Image.delete 单 id 与官方静态 images
数组不符，Image.list 多 tags 被丢弃，界面还可能以旧 ID 消失覆盖权威失败结果。
本切片单一范围为 Apple 共享 ContainerImage 兼容可选原始身份、标签读取/占用解析、
镜像删除及独立只读恢复方法、Mac 选择确认/恢复接线、双语资源与相应正式测试。
不改其他删除 helper 的调用语义，不改持久化、依赖、签名或系统权限；依据上一节
已记录静态契约，不探测或执行真实 NAS 写。风险为私有高风险删除；必须保持新鲜
目标绑定、占用保护、确认快照、重复保护和标签级回查，未知不重放。
五端影响：Mac 修复，iPhone/iPad 共享模型可增量编译但现有只读范围不变；Windows
已有等价实现需回归，Android 不改。新默认只读核查方法在未实现适配器返回不支持，
不回退到删除方法；模型新增可选属性无需存储迁移，回滚撤销本增量即可。当前主机
无 Swift，Mac/Apple 构建与测试必须记未执行，不能用 Windows 通过替代。

已修源码：共享 ContainerImage 保留原始 sourceImageID，按原始 ID/仓库/标签生成
稳定选择身份；Image.list 固定 v1，分页核对原始记录再展开标签，完整容器清单
计算占用，旧无 tags 摘要只读不猜标签。删除 v1 使用 images 数组，同仓库合组标签，
裸镜像使用 identity，并防止隐含删除有效标签。提交前重新绑定标签身份与占用，
明确拒绝保持失败；未知批次保存原范围，重复请求或独立核查只读。标签换 ID 不因
旧选择消失报成功，Mac 删除确认固定选中快照，核查入口不复用删除方法。

独立源码复核补了两处边界：明确 API 拒绝即使错误分类未知也必须保持终态，不能
移除锁后又返回未知；初始镜像读取与删除预检共用固定 v1 的列表来源，不能一个
使用 selectedVersion、另一个使用 v1；主页面容器读取也复用既有固定 v1 来源，
相同回归显式把两者 selectedVersion 设为 2 并断言仍用 v1。未改变其他删除 helper。
新增 14 个 Swift 测试函数（网络 10、Mac 模型 3、共享请求 1），覆盖两种编码、
标签展开、占用、畸形身份/分页、裸镜像范围、拒绝、回执丢失、取消、ID 替换、
只读核查及确认选择变化；原有 2 个删除回归按官方数组契约更新，保留成功/部分
结果断言，另补明确拒绝不可改判成功。全部 Swift 用例本机未执行。

实际已运行：Windows 完整命令
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal`
为 **2930 通过/0 失败/0 跳过**；原镜像删除 FORM/JSON 回归追加对同一新共享请求
fixture 的断言。`tools/request-contract/validate_contracts.py` 98 请求通过；
`tools/localization/check_localization.py` 双语/占位符/硬编码通过（Apple 4044、
Android 2188、Windows 3032）；`tools/contract-validation/validate_fixtures.py`
3 响应组/22 私有引用通过，`git -c core.safecrlf=false diff --check` 通过。

PENDING_USER_VALIDATION：Mac 工具链环境先运行 `swift test --package-path apple`、
Mac App 模型测试及现有临时签名打包流程；当前无 Swift，未执行目标构建、未生成
Mac 包。用户在专用可恢复镜像验证删除单标签保留其他标签、停止容器占用拒绝、
未知结果“核查删除状态”不重发，改选或刷新后重新确认；需 Container Manager 权限
及 Image/Container v1。仅回传版本、动作、脱敏错误，不含镜像名、主机或凭据。
未执行真实 NAS 写，也未暂存/提交/推送。Windows 交付包仍为 20260920-020651；
本波只增 Apple 源码/共享 fixture/Windows 测试，不重打相同生产代码的 Windows 包。
下一切片是镜像拉取的任务回执/状态与跨端用户流程，完整剩余目标保持不变。

#### 2026-09-20 Windows 镜像标签与删除流程

macOS 基线为 `ServiceManagementView` 的镜像多选/删除确认及
`DsmServiceManagementRepository.deleteContainerImagesResult`；后者单 id 参数存在已
记录缺陷，不能直接复制。官方静态证据按仓库/标签寻址，裸标签用 identity；先补
Windows 标签身份、删除预检/防重复/回查核心，再接原生选择确认与恢复界面，并纠正
Mac 同类参数。单一修改范围：容器领域增量、现有镜像读取、共享操作协调器、镜像
删除实现/窗口/正式测试和双语资源；不改其他模块、存储、依赖或权限，不执行 NAS 写。
这是高风险私有删除，保留确认、完整读取、占用检查及只读恢复；标签清单缺失时只读
展示，不猜 latest。五端影响：Windows 实施、Mac 同类缺陷修复、移动端保持只读，
Android 仅记录、不改代码。新增模型为兼容可选元数据/默认接口方法，无持久化迁移；
回滚撤销该增量和界面接线即可，不修改 NAS 数据。真实删除单独待用户验证，不冒充
自动化通过；拉取任务闭环仍属后续切片，不将删除完成等同镜像管理全部完成。

Windows 本波已接上述核心及原生入口，单标签删除按标签消失确认，不误要求其他标签
共用的镜像 ID 消失；裸 identity 则要求原 ID 消失，并拒绝隐含删除同 ID 的有效标签。
提交前两份完整清单和占用核对，原生确认随选择/刷新失效；未知请求在同客户端作用域
保留，窗口重开/仓库重建后只核查，不重发。缺标签或类型不明不放宽；独立只读安全
复核发现通用读取 helper 会将数字转字符串，已为可写镜像身份改为原生字符串校验，
补数字身份、重复标签和仓库标签歧义的拒绝回归，没有删改既有断言。

新增 35 项自动化覆盖（含页面接线检查）；镜像核心和 ViewModel 首轮聚焦 30 通过，
后续补严格身份回归后完整 **2929 通过/0 失败/0 跳过**。首轮 ViewModel 合成仓库把
镜像数据放错快照分区，7 项失败，已纠正夹具分区，未降低断言。中文/英文原生各
16 场景通过，目录 windows/dist/ui-review-20260920-015811 与 20260920-020028；
实看中文深色确认和英文浅色未知结果，风险、所选标签、核查按钮与禁用重复提交可见。
合成恢复夹具的显示数量另做核对，不将其作为真实 NAS 结果。

追加复核：合成恢复夹具原来固定返回 1 个未知目标，已改为按实际待核查标签计数并
增加原生文案断言；补查首次构建因缺少本地化类型限定名失败，限定类型后英文未知
浅/深色、待核查、已恢复共 4 场景通过（windows/dist/ui-review-20260920-020540），
截图显示 2 个未知目标与清单一致。生产反馈另补“提交后会话失效优先提示重新连接”，
不解除未知操作锁，新增 1 项回归；最终自动化总计 **2930 通过/0 失败/0 跳过**。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=ARM64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios container-image-delete -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-image-delete -Language en-US -WindowWidth 1000 -PaneState compact
```

双架构构建均 0 警告/错误；本地化检查 Apple 4040/Android 2188/Windows 3032，97
请求 fixture、3 响应组/22 私有引用及 diff 检查通过。严格文档首轮 STATUS 超过
250 行，已压缩冗余空行后通过。未修改 Mac/移动/Android 源码，Mac 同类缺陷是下一
切片，不把它算作用户验证待办；未暂存、提交、推送或触碰既有无关改动。

PENDING_USER_VALIDATION：用户在专用可恢复镜像中测试单标签/多标签、裸镜像和占用
拒绝；单标签删除后其他标签仍保留，未知结果只能核查，改选后必须再次确认。需当前
会话具备 Container Manager 权限和 Image/Container v1 接口。回传仅套件版本、操作
类别和脱敏错误；不要回传仓库私有名称、容器信息或凭据。无真实 NAS 删除证据。

`windows/package.ps1` 本波使用 LANSTASH_NON_INTERACTIVE=1、
LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=1、LANSTASH_LAUNCH_AFTER=0，
在打包流程内实际运行全部 2929 项测试并通过，再生成独立自包含 Release：
windows/dist/20260920-020201。未安装/启动，不覆盖旧包。build-info 已核对
main@0eeeb170358c 加 dirty、两种架构、Release、selfContained=true、testsRun=true；
两份 ZIP 的 SHA256 与 sidecar 一致：

- x64：`C86EDDB07061CADD95A5B6BFEBCBB8D1626B6BA46F52A6A15527FF820E0A607C`。
- arm64：`E98517506A3DB9A0A7189F5B7B5A4BD383DA51E63A953021165F02CB8BF81E1E`。

包包含本波镜像删除与上一波重启过渡态修正；不包含尚未实现的 Mac 镜像修复，
不是正式签名发行。打包完成后的合成夹具数量更正只影响测试宿主，不影响生产包。

补会话失效提示后，再次以相同命令和打包设置生成最终交付目录
windows/dist/20260920-020651；打包内全部 **2930 项通过**，双架构 publish 完成，
build-info 的配置、架构、提交加 dirty、testsRun=true 与自包含均核对。最终 SHA256：

- x64：`C220EB2CB037AF2D5EEFB12BC918A26685620739C2F94755AB01CA44F3697D6A`。
- arm64：`7E59518927F7B91754707CE2EFEB44C0E1CA52D5A37E245D4292396161DD2F63`。

最终 ZIP 与 sidecar 均一致，未安装/启动，旧包保留。下一切片优先修复 Mac 镜像
删除参数及标签表达，再继续拉取闭环；VMM、文件收藏/挂载与系统集成完整目标不变。

#### 2026-09-20 本机重解析点测试权限修复

此前全量唯一失败发生在 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`
创建符号链接的准备阶段，尚未执行上传保护断言。测试改用 `mklink /J` 创建真实目录联接，
检查 `FileAttributes.ReparsePoint` 和实际目标；保留根目录及子目录拒绝断言，增加无上传
计划和目标文件完整性断言。联接单独非递归移除，避免递归清理调用卷挂载点处理；首次
试跑曾在联接清理阶段失败，该清理路径已修正。没有跳过测试、改系统权限或修改生产代码。

实际验证（本机 Windows，2026-09-20）：

- `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal --filter FullyQualifiedName~BoundedFolderUploadPlanTests`：18 通过、0 失败、0 跳过。
- `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal`：2894 通过、0 失败、0 跳过。
- `git -c core.safecrlf=false diff --check`：通过。

这证明通用重解析点拒绝逻辑在真实目录联接上执行通过，不冒充本机创建符号链接已获授权，
也不替代 NAS 写操作或 macOS 实机验证；API、五端契约、运行包及用户数据均未变更。

#### 2026-09-20 容器重启过渡状态对齐

依据已记录 MainVue 静态 running 分组包含 RESTARTING，修正两端一律要求
Restarting=false 的偏差。Windows 追加 Restarting 枚举值（不改变原值），清单从
State.Restarting 原生布尔识别，运行分组和停止/重启选择包含过渡态；启动/删除仍
要求稳定停止。Mac 同步控制预检及本地化显示。完成核查仍须 Restarting=false，
重启还须同一实例启动时间变大；不把放开提交等同成功。范围限状态解析、资格判断、
显示及对应测试/资源，API 参数/权限/存储不变；Windows 领域增量符合既有授权，
Apple 移动端仍只读、Android 不改，Swift/Mac 目标构建缺口明确保留。

#### 2026-09-20 Windows 容器原生管理与恢复

本波接上一波四操作核心，macOS 证据为 ServiceManagementView 的容器选择/控制/
删除确认和 ServiceManagementModel 的结果反馈。Windows 使用现有页面原生对话框，
支持操作切换、筛选、多选确认、逐目标结果与未知操作恢复；确认绑定 ID/名称/状态
快照，任何输入改变失效。未知或认证问题中止后续批次，只读核查不重发，未执行项
必须重新选择确认。单一范围为容器 ViewModel、新对话框、页面入口/互斥/生命周期、
双语资源及正式测试；API/存储/权限/平台范围不变，不执行真实 NAS 写。核心可用时
用户能操作，不新增未实测恒关闭门；源漂移、托管限制仍由提交前权威读取裁决。

已接 ContainerMutationViewModel、原生对话框及“管理容器”正式页面入口，并与网络
创建/删除、映像仓库窗口互斥；页面销毁取消等待，旧连接迟到响应不能覆盖新连接。
操作/筛选/选择/刷新都会清除确认，逐目标独立请求标识，明确失败与成功分别展示。
未知/认证/取消中止剩余批次，未执行项不自动补发；“核查并刷新”只读取恢复结果。
确认结束的批次自动刷新清单，但必须重新选择确认才能再次操作。不可操作、加载、
空内容、筛选空、错误、正常与逐项结果均有双语恢复提示，真实权限/托管判断未削弱。

新增 ViewModel 11 项用例，含四动作批量、确认失效、未知中止/只读恢复、部分权限
拒绝、关闭后重开、旧连接迟到、只读与错配置档。连核心聚焦 **37 项通过**；全量
**2882 通过、1 失败、0 跳过，共 2883 项**，唯一失败仍是本机符号链接权限，不改
Windows 安全配置、不跳过测试。首轮原生在 ops-filtered 的即时断言提前退出；等待
TextChanged 处理后保持原断言，中文 20 场景通过（windows/dist/ui-review-20260920-003606）。
补明确结果自动刷新后，英文 20 场景全通过（windows/dist/ui-review-20260920-003849），
中文确认/四动作/重开共 9 场景复跑通过（windows/dist/ui-review-20260920-004304）。
实看英文深色确认及浅色未知结果，确认范围、警告、核查按钮和未执行项可见；不把
合成截图当真实 NAS 行为证据。

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~ContainerMutation' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios container-operations -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios container-operations -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-operations -Language zh-CN -WindowWidth 1000 -PaneState compact -States ops-confirm,ops-start,ops-stop,ops-restart,ops-delete,ops-reopen
```

本地化/硬编码扫描通过，资源 Apple 4039/Android 2188/Windows 3010；97 请求
fixture、3 响应组/22 私有引用、严格文档和差异检查通过。未改变 API 契约或真实
环境 verification。PENDING_USER_VALIDATION：测试包打开“管理容器”，在专用可
恢复普通实例测试四动作及多选，重启核对真实启动时间、删除核对原实例消失；断线
后使用核查按钮，不能再次提交未知项；托管实例应拒绝。只回传操作类别、版本和
脱敏错误，勿回传容器名、标签、日志或凭据。

`windows/package.ps1` 生成独立 x64/ARM64 自包含 Release，目录
windows/dist/20260920-004717；含正式容器操作 UI 及此前功能，不覆盖旧包、不安装/
启动。环境 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=0、LANSTASH_LAUNCH_AFTER=0，测试独立运行并保留上述失败。
build-info 的 main@0eeeb170358c 加 dirty 源码/架构/配置已核对，ZIP 与 sidecar
SHA256 一致：

- x64：`FD7D59369051D929D6ABF51373767D7CB366743F93D3BD58685044B592AFA869`。
- arm64：`EE7DBE8235FD6C699A09CD9CF59A07A72CAA2F4A07F27BC45991160017F9B261`。

本波未改 Apple/Android，也未重新验证 Swift/Mac；Mac 修复仍需目标构建。保留全部
既有工作区改动，未暂存/提交/推送。下一切片是镜像管理及已记录的对应 Mac 请求
差异；完整目标中的压缩选择上限、收藏/挂载、VMM 和系统集成不因该切片缩小。

后续复核项：官方静态 running 分组包含 RESTARTING，而当前两端生命周期核心仍
要求 Restarting=false；重启过渡态的停止/重启会被保守预检拒绝。该项是源码语义
缺口，不归入“待真实验证”，下一切片优先核对并修正状态映射/可操作性，再继续
镜像管理。当前包的合成成功范围是稳定运行/停止状态，不能据此宣称全部状态已对齐。

#### 2026-09-19 容器生命周期参数纠正与 Windows 接入

新证据见容器生命周期只读记录：官方 start/stop/restart 使用 name，delete 为
name/force=false/preserve_profile=false。Mac 既有三条单 id 请求错误属于用户已
授权的同类基线缺陷；本波先纠正共享适配器、正式测试/fixture，补运行状态回查和
停止/重启确认，再接 Windows 原生等价流程。复用实例清单解析与现有错误/删除结果
模型，不增加持久化、依赖、身份或公开权限；未知结果保留会话内锁，只回查不重发。
Windows 需独立请求快照/确认/恢复及状态回读，不复制 Mac 旧缺陷；Android 只记录
影响，不改源码，移动端只读清单不得因共享修改新增写入口。共享 Swift 与 Mac
必须目标回归，Windows 主机没有 Swift 时明确未运行，不用其他端通过替代。

2026-09-20 实际源码：Mac 的三种控制与删除先读取严格实例身份，按名称发送固定
v1；删除含 force=false/preserve_profile=false，旧 void 删除入口复用同一结果流程。
控制成功要状态回读，重启要同一实例启动时间变大；未知控制或删除保留身份/名称锁，
后续同操作只查询，其他操作或同名新实例不能接管。批量删除后续目标再读取身份和
托管状态，避免前项等待期间名称被复用。Mac 三种控制新增原生确认，确认时固定选择，
选择改变则模型零提交；修正读取错误原来误用“任务文件上传失败”的文案。

Windows 新增 ContainerMutation 请求/恢复领域类型、IContainerManagerRepository
兼容默认方法和原 Repository partial，复用 ServiceMutations 协调器/操作缓存，
不另建平行传输。按绑定会话与 v1 能力开放核心，提交前确认快照、ID/名称/图像/状态
一致，停止/重启需运行，启动/普通删除需停止；只读核查和恢复不重放。明确拒绝缓存，
断线/提交后取消保持未知，删除按原 ID 消失、重启按 StartedAt 变化验证，不以空
成功回执或仍 running 报成功。Windows 原生操作/批量 UI 尚未接，不把核心算完整功能。

对抗复核追加了官方托管限制：20 日只分析19日已加载 MainVue，没有新真实请求；
is_package 由容器标记及所属项目共同决定。两端预检只在有目标项目标签时查
Project.list，匹配 name；项目 is_package 缺省 false 是官方明确默认，错误类型拒绝。
容器标记未知不开放；没有项目标签的普通实例不依赖项目读取或系统套件管理权限。
未知名称锁、确认后漂移、托管实例、普通运行状态、同 ID/名称回读均独立复核。

实际 Windows 聚焦 `ContainerMutationTests` **26 通过**；全量 **2871 通过、1 失败、
0 跳过，共 2872 项**，唯一失败仍是 CreateSymbolicLink 本机权限不足。正式 x64/
ARM64 Release 各 0 警告、0 错误；本波 Windows 未改 UI，未跑原生截图或重新打包。
旧 232858 包不含本次容器核心与 Mac 修正。共享删除 fixture 改为名称及两个布尔，
Mac fixture 测试补前后清单；Android 的同 fixture 测试是保持关闭/零写，不改 Android。
iPhone/iPad 仍只读，但共享包回归须在 Apple 工具链执行。本机 `Get-Command swift`
无结果，新 Swift/模型测试及 Mac UI 构建均未运行，不当作通过。

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~ContainerMutationTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
```

本地化/硬编码、97 请求 fixture、3 响应组/22 私有引用、严格文档和差异检查通过；
资源 Apple 4039/Android 2188/Windows 2978。未执行真实 NAS 写、未暂存/提交/推送，
保留此前所有改动。PENDING_USER_VALIDATION：Mac 先运行 DsmNetwork 与 DsmMac
测试/目标构建，再用可丢弃普通容器核对确认、启停/重启/删除、未确认恢复与托管
保护；只回传脱敏错误类别/版本，不回传名字、标签、凭据或日志。Windows 待原生
入口接好再发测试包，之后继续映像管理、压缩选择上限、收藏/挂载、VMM 与系统集成。

#### 2026-09-19 解压完整目录与覆盖

沿用上一波密码/编码，先完成公开 Extract.list v2 的 offset/limit 与 item_id 子目录
读取；官方响应条目标识正文为 itemid、示例为 item_id，二者兼容但同时出现须一致。
macOS 基线是 `ArchiveExtractionView` 的 createSubfolder/keepDirectoryStructure/
overwrite 与共享 extract 参数。Windows 按完整相对路径预检、逐父目录回读，不用
根目录出现代替内部文件完成。选项增加为向后兼容属性，密码/编码及确认绑定不变；
已有文件覆盖需二次风险确认和权限检查，不允许覆盖源归档或文件/目录类型冲突。
单一范围为 Extract 传输/领域/Repository/现有表单、资源与测试；不改身份、存储、
依赖或其他四端。真实 NAS 留待用户验证，已完整实现选项按能力开放；目标目录选择
如无法同波接通须继续列为未完成，不收窄整体目标。

复核更正：`WorkspaceView.ArchiveExtractionView` 只有目录/覆盖开关；
`WorkspaceModel.prepareExtraction` 明确取 currentPath，压缩入口也使用 currentPath。
此前把“另选目标目录”推定为基线缺口没有源码依据，撤回这项推定，不以增加新能力
替代对齐现有用户结果。保留压缩 20 项选择上限这一有源码依据的后续差距。

实际已完成完整列表/子目录读取，固定每页 200，按 total 或短页结束；目录标识
缺失/冲突/重复、越界路径、重复路径、页偏移/总数异常、无进展均不降级为空目录。
Repository 保留完整相对路径和已知大小，预检新增/已有父目录与覆盖目标；已有目录
可在明确可写时合并，同名文件无覆盖授权拒绝，类型冲突及覆盖源归档始终拒绝。
创建子目录、保留或展开结构在 start 使用原生布尔，展开重名预检拒绝。覆盖需独立
确认，改密码/编码/目录选项后失效，默认按钮切回取消。成功须同一任务完成并对所有
预期父目录回读，文件大小已知时精确匹配，顶层目录存在不证明子文件完成。
扩展名与 macOS 实际列表对齐为 zip/gz/tar/tgz/tbz/bz2/rar/7z/iso，仍先 NAS list
预检；不保证未实测格式一定可解开。目标目录读取已移除 5000 项硬上限，仍保留
total 稳定、重复/无进展/越界检查与取消；新增 5001 项目录回归，涉及压缩共享助手。

独立集成与只读对抗复核：密码不入恢复请求或日志，确认快照随输入失效；目录遍历
按 itemid/item_id 而非显示文案，循环/重复/越界失败；完整目标列表权限和源身份在
提交前读取，任务未知不重发、不自动删除失败输出。覆盖跨请求互锁与恢复摘要继续
生效；没有真实 NAS 写、没有身份/存储/依赖修改。公开请求 highRisk fixture 新增
synthetic-overwrite，五端 wire 字段不变，其他四端代码仅记录影响不修改。

实际验证：解压聚焦 **77 通过**，全量 **2845 通过、1 失败、0 跳过，共 2846 项**；
唯一失败为 BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints 的
本机 CreateSymbolicLink 权限不足，未跳过或改安全设置。初轮两项旧“根目录200截断”
断言失败已改为真实子目录/完整250项成功预期；一次目标类型推断编译错误已修。
中文/英文各 13 个原生场景通过，分别位于 windows/dist/ui-review-20260919-232538
及 windows/dist/ui-review-20260919-232740。已实看深色覆盖确认：风险文字完整，
未确认时解压禁用、默认取消，确认后可用；这是必要用户确认，不是未实测固定禁用。

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~FileArchiveExtraction' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-build --no-restore --filter 'FullyQualifiedName~FileArchiveExtraction' -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios files-extract -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios files-extract -Language en-US -WindowWidth 1000 -PaneState compact
```

97 请求 fixture、3 响应组/22 私有引用、本地化及严格文档和差异检查通过；资源
Apple 4033/Android 2188/Windows 2978。PENDING_USER_VALIDATION：专用可恢复归档
测试嵌套/展开、不同格式、密码、重名保护与主动确认覆盖，核对实际内容；复合扩展名
创建子目录名称沿用 macOS 删除末扩展名预检语义，NAS 实际命名待核对，不猜测回读成功。

`windows/package.ps1` 双架构 Release 自包含发布成功，独立测试包位于
windows/dist/20260919-232858，包含两轮解压及此前开放策略，未安装/启动或覆盖旧包。
使用 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=0、LANSTASH_LAUNCH_AFTER=0；单测已独立运行并保留上述失败，
不冒称正式发行。build-info 的 main@0eeeb170358c 加 dirty 源码、双架构及配置已核对。
ZIP 与 sidecar SHA256 一致：

- x64：`A71209F717AE1D3757896EAE1FB4DD77B4AAEB8B1320C71C3930544BCF3DBFF2`。
- arm64：`B48C947C806A08ACF374D3C93E5EC5AE5D4506694B3B47378FDFDECF1CCFC2B7`。

用户同波重新登录 DSM，容器只读核查已恢复并发现官方 name 与 Mac 单 id 请求差异，
详见 2026-09-19-container-lifecycle-read-observation.md；未执行写操作。下一切片
依据新静态/只读证据修正 Mac 并接 Windows 生命周期。其余压缩选择上限、收藏/
挂载、VMM/系统集成及 Mac 目标构建继续保留；既有修改未暂存/提交/推送。

#### 2026-09-19 解压高级选项与任务核查

基线：macOS `WorkspaceModel.preferredArchiveCodepage/enqueueExtraction` 与共享
`DsmFileRepository.extract/listArchiveItems`；公开 Extract v2 的 list/start 同用
password/codepage，status/stop 绑定任务。当前 Windows 仅列根目录首 200 项，
没有密码/编码，且存在仅凭输出出现确认成功的问题。先接通密码、自动/手选编码及
任务核查，再扩展完整归档树与目录/覆盖选项；不能把根目录摘要当成扁平化或覆盖的
安全预检。完整目录、覆盖及目标选择仍在原目标内，不伪装可用或划为非目标。
单一修改范围：Extract Domain、现有 API 重载/Repository、原生弹窗、双语和测试。
沿用现有确认/互锁、取消与结果恢复；密码不入 URL/日志/恢复状态。兼容扩展依用户
既有授权，五端 wire 契约不变，其他四端代码/存储不改。验证分源码/合成/目标构建，
真实包及 NAS 权限记 PENDING_USER_VALIDATION，不因此固定禁用已完成入口。

本波已接密码与自动/手选编码：公开 list/start 使用同一选项；默认先读 NAS 编码，
仅有乱码线索时比较 chs，改善才采用，手选不被改写。候选比较普通失败保留原列表，
认证失败/取消不得降级继续写。错误 1403 在预检阶段返回可纠正提示，同一弹窗恢复
表单并允许重新输入；密码提交/关闭清空，恢复对象只保留无密码选项和摘要，不重放。
旧成功判断已收紧为任务 finished 加输出回读，任务失败时不确认部分文件内容，
丢失 start 回执不凭文件名接管其他任务。已知 taskid 恢复只查 status/输出、不 start。
没有改覆盖或目录写范围，未删除失败输出或执行真实 NAS 操作。

初轮 27 项中 3 项失败，分别是旧“无密码框”源码断言、旧“失败仍部分成功”及旧
“无回执但文件出现即成功”期待；按新增功能和更严格完成证据改正，既有源漂移、
权限、冲突、互锁、取消和跨 Repository 不重放断言全部保留。增加密码/编码原文
传输、自动比较/手选不改、无效编码零请求、密码错误零写、候选失败降级/认证不降级
及输出存在但任务未完成等回归。新增测试一次 nullable 编译告警已修复。

聚焦最终使用同命令附加 `--no-build` 复跑，**41 项通过**。
最终全量 **2809 通过、1 失败、0 跳过，共 2810 项**，唯一失败仍为
BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints 的符号链接权限；
未更改 Windows 安全或跳过断言。正式 x64/ARM64 Release 各 0 警告、0 错误。
中文 8 场景位于 windows/dist/ui-review-20260919-230800，英文 8 场景位于
windows/dist/ui-review-20260919-230938；覆盖表单/密码错误浅深色、原地重试、成功、
未知、处理中关闭。已实看中文深色密码错误图，文字/输入/按钮可读，不把测试桩
成功等同真实包解压。命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~FileArchiveExtraction' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios files-extract -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios files-extract -Language en-US -WindowWidth 1000 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
```

本地化/硬编码、96 请求 fixture、3 响应组/22 私有引用、严格文档与 diff --check
均通过；资源 Apple 4033/Android 2188/Windows 2974。本波未重新打包，225722 包
不包含本轮解压改动，不能用于验收该功能；既有改动保留，未暂存/提交/推送。
PENDING_USER_VALIDATION：后续新包用可丢弃的加密 ZIP/7z 测试错误/正确密码、乱码
自动识别及手选，核查实际解压内容，失败只回传脱敏提示、格式与编码类别，勿回传
密码或真实路径。下一切片继续完整归档清单、目录结构/子文件夹/覆盖与目标选择。

#### 2026-09-19 高级压缩选项

本波先核查容器生命周期契约，浏览器停在登录页；现有文档未固定容器写参数，不把
macOS 单 id 请求当官方证据。见 `../api/discovery/environments/2026-09-19-container-lifecycle-read-observation.md`。
转推进独立公开压缩切片：macOS 证据为 `DsmFileRepository.compress` 和
`DsmCore/FileStation.swift` 的 ArchiveFormat/ArchiveCompressionLevel；公开 File Station
Guide 的 Compress v3 明确 zip/7z、moderate/store/fastest/best 及可选 password。
Windows 用原生选择框和 PasswordBox，沿用现有多选、目录权限、冲突拒绝、任务轮询、
取消及最终目录回读。单一修改范围为压缩 Domain/传输/Repository/已有对话框/双语
资源及正式测试，不改认证、持久化或覆盖策略；密码不入日志、请求 ToString 或恢复
状态。接口扩展向后兼容，符合用户既有授权；四个其他平台不改，仅同步影响记录。
当前验证等级为源码/官方文档，待聚焦回归及目标构建；本波非目标是解压、跨目录压缩、
容器写和真实 NAS 操作，这些仍保留在完整对齐目标中。

本波实现与复核：默认调用保持 zip/moderate/无密码，新增选项重载不把高级参数静默
降级成默认值。格式切换同步扩展名，四档级别和密码输入均通过双语资源；无效输入
提示放在当前对话框内。密码提交后及关闭时清空，恢复请求去除密码，只保留选项
摘要；改变选项/密码不能接管未知操作或绕过源/目标互锁。对抗复核还发现旧实现仅凭
非空输出文件报成功，现要求同一次任务 finished 加目录回读；丢失启动回执无法证明
任务完成，只留待核查、不重放；已有 taskid 的恢复先读 status，不重新 start。
任务明确失败但已出现部分文件时报告失败，不自动删除输出。该纠正加强原断言，
没有放宽真实验收或未知结果保护。正式测试的配置档按用例隔离，防止未结束操作
跨用例污染；不削弱生产的会话内恢复锁。

验证：压缩聚焦 **33 通过**，全量 **2795 通过、1 失败、0 跳过，共 2796 项**；
失败仍为本机 CreateSymbolicLink 缺权限，未更改系统安全或跳过断言。中文最终
8 场景在 windows/dist/ui-review-20260919-225422，英文最终 8 场景在
windows/dist/ui-review-20260919-225616；表单浅深色、成功浅深色、无效输入、失败、
未知与处理中关闭均通过。实看中文深色表单与英文错误表单：密码提示可读、7z 扩展名
正确、错误留在弹窗内。无内容/筛选态沿用文件选择页，本次不新增压缩包浏览页。
期间发现深色固定 Brush 对比不足以及动态资源键扫描失败，改继承文字颜色和显式
键后复验通过；未把第一轮图当最终图。命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~FileArchiveCompression' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios files-archive -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios files-archive -Language en-US -WindowWidth 1000 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

检查通过：Apple 4033/Android 2188/Windows 2966 双语资源、96 请求 fixture、
3 响应组/22 私有引用、文档及差异。PENDING_USER_VALIDATION：Windows 连接有
File Station 权限的账号，在专用测试文件夹分别创建 ZIP/7z、设置密码和不同级别，
下载后验证解压内容及密码；中断时不得误报成功或覆盖已有文件。回传操作类别、格式、
脱敏错误，不回传密码/真实路径/内容。本波不改 Mac，Swift/Mac 修复仍需目标构建。

实际双架构发布：`windows/package.ps1`，环境为 LANSTASH_NON_INTERACTIVE=1、
LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=0、LANSTASH_LAUNCH_AFTER=0。
测试由上列命令单独执行，不把跳过脚本内重复测试说成全量通过。生成独立目录
`windows/dist/20260919-225722`，x64/ARM64 的 Release、自包含及 dirty-worktree
build-info 已核对；主提交 0eeeb170358c 加当前源码，不覆盖旧包、未安装/启动。
两包及其 sidecar 的 SHA256 均一致：

- `LanStash-0.1.0-x64.zip`：`B595B6FFC7B372DC8B678347F692C2C36583DEF6ACF4F40A4C3C9B274ACC6FD8`。
- `LanStash-0.1.0-arm64.zip`：`F8B31515D76419408B83A6B83E539165C04E98FA535A80F3FBC38592FF1F7815`。

保留既有未提交改动，未暂存/提交/推送。下一切片为解压密码/文件名编码/目录与覆盖
选项；容器官方契约核查等待用户手动登录，但完整 Container/VMM/系统集成目标不缩小。

用户已明确要求完成剩余差距。本目标保持完整 Windows/macOS 业务语义对齐，不因某一批
回归通过缩小范围；以下是依赖顺序，不是把未做功能改成非目标。以 macOS 当前实际实现
为基准，不把 macOS 自身未实现的语音/加密等规划项当成已有功能。前次修复与已有未提交
改动保留；当前任务单独负责本波次列出的文件，不修改 Apple/Android，不提交或推送。

| 顺序 | 用户结果及 macOS 证据 | Windows 实施与契约依赖 | 安全/验证与剩余条件 |
| --- | --- | --- | --- |
| 1 | 新建单聊、群聊、读取成员：`DsmChatRepository.swift` 创建与成员流程 | 现有 `ChatConversations/Chat` partial、创建器与既有 WinUI 对话框；按 `endpoints/INDEX.md` 已记录 FORM/JSON 编码、固定版本、独立成员回读；不新增接口 | 普通私有写；补真实 HTTP 合成链、未知结果不重放、目标绑定与双语五态；NAS 待用户验证 |
| 2 | 容器完整清单与活动记录：`DsmServiceManagementRepository.swift` 的 `loadContainerManager/containerActivityLogs` | 移除静默 200 条截断，按已记录 total/offset 分页；复用现有只读分区和 WinUI 列表 | 内部只读；异常页失败而不伪装完整，取消/账号隔离回归；大量数据和真实套件待测 |
| 3 | Chat 其余已实现动作与同步：`ChatWorkspaceModel.swift/DsmChatRepository.swift/DsmChatRealtimeClient.swift` | 核对关闭会话、转发、公告、提醒、定时、投票及实时刷新，接入已有领域/Repository，不新建平行实现；先逐项固定契约和危险门 | 写/后台；源码与合成闭环，未验证高风险入口受门保护；不把已有关停常量当作完成 |
| 4 | Download Station 全部已实现管理：`ServiceManagementModel.swift/DsmServiceManagementRepository.swift` | 对照任务、文件创建、批量操作、设置及实际存在的 RSS 能力；沿用公开 API 优先、确认/去重/回读 | 设置与删除为危险写；字段或公开契约需要变化时另行说明并取得同意 |
| 5 | NAS 管理：`NasAdministrationModel.swift/DsmNasAdministrationRepository.swift` | 逐项核对现有 Windows 设置分区、请求、安全状态和界面是否连通，补齐实际缺口 | 账号/权限/电源/网络等高风险；按已记录契约实现，实机验证前保持相关保护 |
| 6 | Container/VMM 高级管理：`ServiceManagementView.swift/DsmServiceManagementRepository.swift` | 网络详情、生命周期、映像、网络管理、虚拟机创建/编辑与控制台；先核对契约/领域/权限，不复制未记录私有请求 | 高风险/系统副作用；新契约、权限、依赖或公开数据模型变更先说明审批；未验证入口受门保护 |
| 7 | Files、传输、Photos、桌面云盘和本地设置完整验收：各 macOS Workspace/文件/照片/桌面云盘模型 | 按功能入口对账、确认已存在实现是否真正贯通，完成窗口、Explorer/Cloud Files、后台恢复、通知等 Windows 等价交互 | 认证/跨 NAS/后台/系统集成；源码/合成/目标构建与设备验证分开，不假定已对齐 |
| 8 | 集成与交付 | 全量 xUnit、本地化/契约/文档、WinUI x64/ARM64、五态/浅深色、独立安全复核、独立测试包 | 托管 CI/正式签名/真实 NAS 未运行不得写通过；所有未完项继续保留，目标不提前完成 |

第一波单一修改范围是 Windows Chat 创建/成员适配与测试、Container 读取/分页与测试；
共享请求层只允许与可复现未知结果缺陷相关的最小增量。UI、资源、组合根和领域契约如需
改动，逐切片登记，不跨模块无边界修改。`PENDING_USER_VALIDATION` 仅后置设备验证，不
阻塞其他无依赖功能实现；每波交付后更新真实命令、失败信息与下一切片。

同波追加已确认的 Files 主流程差距：`DsmFileRepository.search` 和 API 参考 5.4 已明确
路径数组、按声明编码、等待 finished、2000 条分页与成功 clean/失败 stop。Windows
`DsmRepository.FileSearch.cs` 与 `DsmRepository.Files.cs` 仍重复且不等价；当前任务将两入口
合并到已有 `IFileSearchRepository` 流程，补全分页与清理。只使用现有公开 v2 API，不改
领域接口、权限或持久化，不在真实 NAS 发起全盘搜索；搜索词/路径只驻留内存。验证要求为
真实 HTTP 合成链、FORM/JSON、未完成结果、分页/取消/失败清理及 x64/ARM64 构建。

#### 第一波实际实现与复核

- Chat：`DsmRepository.Chat.cs/ChatConversations.cs` 支持既有创建与成员 FORM/JSON 声明，
  群名/类型/会话 ID 按字符串编码，数组/布尔不二次编码。已有同名群聊的复用也独立回读
  成员，避免摘要缺失导致重复建群、摘要过期导致错误复用。HTTP 失败与 DSM 明确拒绝以
  现有异常内部元数据区分，不改变公开异常结构；未知结果只读核对。同请求终态与草稿绑定，
  后续会话消失不能重发；成员选择先快照，防止等待期间被调用方修改。
- Container：容器使用已记录 `limit=-1`，所有资源完整解析，不静默截断 200 条；日志按
  1000 条请求、返回 total/offset 持续读取，短页不提前结束，空洞/错位/重复/失败不伪装
  完整列表。逐页只保留摘要，不保留账号/日志正文；原始条目无 ID 时使用全局分页位置生成
  本次快照唯一 ID。仍未实现的详情和生命周期写操作继续在完整目标中。
- Files：`DsmRepository.FileSearch.cs` 成为唯一搜索实现，旧 `SearchFilesAsync` 委托它；
  固定公开 v2、目录数组、FORM/JSON 字符串、完成标志、完整分页和成功 clean/失败 stop。
  共用现有文件元数据解析；缺失/重复/中途空页明确失败。离页、关闭、销毁、导航、切换为
  本地过滤会取消搜索并拒绝迟到结果；普通 Unloaded 不销毁 Shell 缓存的页面模型。

单独只读集成/对抗复核发现并补测了两类既有隐患：创建成功后再次使用同请求 ID、旧群聊
摘要成员与独立成员不一致；搜索取消原本未接入页面生命周期。没有降低安全断言：旧
FORM-only/200 条截断测试按已记录目标改成 FORM/JSON 正向与未知格式负向、完整 201 条及
1205 条分页测试；普通卸载测试仍禁止释放缓存页面，只允许取消临时搜索。

已新增正式 `ChatConversationWireParityTests`、`FileSearchWireParityTests`；扩充原有成员、
容器、搜索与文件页回归。Apple、Android、Domain 接口、依赖、标识、权限和存储均未改动。
当前官方浏览器只读证据见[环境记录](../api/discovery/environments/2026-09-16-windows-parity-read-observation.md)：
版本及五项 JSON 能力元数据已核实，但没有执行 NAS 业务写操作，也没有将网页元数据作为
Windows App 真机验证。官方页面正常加载的认证恢复/偏好/连接控制副作用在记录中明确说明。

真实命令使用已有 .NET 10.0.401（`LanStashBuild/dotnet`）和 Codex bundled Python，未更换工具链：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~Chat|FullyQualifiedName~Container|FullyQualifiedName~FileSearch|FullyQualifiedName~DsmApiClientFixedReadTests|FullyQualifiedName~SessionRequestParityTests' -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

结果：全量 **1659 通过、1 失败、0 跳过（共 1660）**；唯一失败仍为本机没有符号链接
创建权限的 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`，不改系统
安全设置、不跳过。聚焦 306 通过（文件页生命周期新断言随后纳入全量）；核心修复的 x64
与 ARM64 构建均为 0 警告/0 错误。文件页生命周期补丁随后通过
`./windows/tests/UiSmoke/run.ps1 -Scenarios files,chat,containers`：9 个原生场景通过，覆盖
文件浅深色内容、加载/空/错误及 Chat/Container 浅深色；不代替真实 NAS 搜索取消验收。
补跑 `./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios filtered-empty` 通过，合计 10 场景，
文件页加载、空、筛选空、错误、正常五态均有本轮原生合成验证。
本地化、96 组请求 fixture、3 组响应 fixture/22 项私有引用、文档与差异门禁均通过。

第一份中间包 `windows/dist/20260916-122927/` 未包含随后补齐的页面取消接线，不作为本波
最终测试包，已清理。最终包沿用既有 `windows/package.ps1`，`LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`；
测试已经独立执行并保留上述权限失败，不因打包关闭重复测试而声称全量通过。无自动安装
或启动。含最终页面取消补丁的 x64/ARM64 Release 自包含发布均成功，SHA-256 校验一致：

- `windows/dist/20260916-123516/LanStash-0.1.0-x64.zip`
- `windows/dist/20260916-123516/LanStash-0.1.0-arm64.zip`

本波 10 张临时合成截图与被替代中间包已在核对明确路径后删除，可重跑脚本恢复；最终包和
正式测试源码保留。旧任务产物未删除。当前仍在 `main` 的既有脏工作区上叠加，保留界面重建、
QuickConnect 和前轮照片修复；未 add/commit/push，未触碰 Apple/Android/公开领域模型。

继续交接时先复核当前源码/差异，再从 Chat 高级写的现有关闭门和未贯通界面开始，不以
修改一个总开关代替逐操作确认、权限、去重、回读与合成验证。Windows 托管 Runner、本机
符号链接权限测试、真实 NAS 建群/文件搜索/日志分页和系统集成仍未完成，不据本波构建
或网页能力元数据推断通过。整项持续目标尚未完成。

`PENDING_USER_VALIDATION`：新测试包中用授权的测试账号检查建群确认/成员、断网后仅核对，
完整日志和超过一页的文件搜索；离页/取消后不再出现迟到结果。回传只含版本、操作步骤、
预期/实际及脱敏错误类别，不含会话、真实名字/路径/正文。UI 实际线程切换、NAS 权限和
服务端清理结果不可由合成测试替代。其余完整目标仍进行中，下一波为 Chat 高级动作与同步，
然后继续下载管理、NAS、Container/VMM 与系统集成；不因本波通过提前关闭目标。

### W0：基础与安全

#### 第二波接口增量决策（用户已明确同意）

2026-09-16 用户回复“同意”，批准上轮已说明的 Windows 向后兼容接口增量。此处先前的
等待描述保留为决策历史，不再作为实现阻碍；不扩大到真实 NAS 自动写验证、依赖、权限、
标识或磁盘格式变更。当前波次单一修改范围为 Chat Domain 能力/可选投票字段、现有高级
Repository、操作状态模型、原生对话框、双语资源与聚焦回归；macOS 为只读参考。

先完成提醒设置/列表/取消、纯文字定时消息创建/列表/取消和无附件投票创建/读取。依据现有
`set-reminder/create-scheduled-message/create-poll` 请求 fixture 及 Chat 私有记录；创建都
需要当前会话权限、用户确认、进程内固定请求 ID、已知 DSM/套件版本能力门和结果回读，
未知响应不得重复写。不存在的公开接口不猜测。五端影响是 Windows 补齐现有共同语义，
其余四端源码不改；新增字段可选、旧构造保留，无用户数据迁移，回滚移除增量入口即可。

接口审批等待期间，先推进不依赖 Domain/Repository 变更的 Chat 阅读切片：
macOS `ChatWorkspaceModel.refreshCurrentConversation/markConversationReadLocally` 是证据；
Windows 当前 `LoadFirstMessagePageAsync` 刷新重建缓存，会丢失已读历史。单一修改范围为
现有 ChatBrowserViewModel、ChatForegroundRefresher、ChatPage 及对应测试/文档；保留 WinUI
窗口/窄屏习惯，修复最新页合并与原历史游标、本地阅读时间边界和 5 秒前台轮询降级。
不新增领域字段、API、写操作、持久化、依赖或系统权限，也不冒充 Socket.IO 实时链已完成。
验证覆盖历史保留、更新字段、可见/隐藏、加密、失败、取消、后续新活动、跨 NAS 和卸载；
真实 Chat Server 未读与窗口验收继续单独记录。

本轮重新检查源码后，确认下一批不是只接 UI：

- `ChatReadFeature/ChatWriteFeature` 未提供提醒、定时、投票、转发、关闭会话等逐项能力；
  `ChatMessage` 缺少投票字段，而共享 `chat-message.schema.json` 已有可选 `poll`。
- `IContainerManagerRepository/IVirtualMachineManagerRepository` 当前只有快照读取，无法表达
  macOS 已有的详情、生命周期、网络/映像管理和控制台流程。
- `IDownloadStationRepository` 有公开任务操作与 BT 搜索，但没有设置管理等剩余用户结果。

项目规则要求公开契约变更先说明并取得同意，因此本轮尚未修改这些接口，也不通过 App
直接依赖具体 Repository、复制另一套 API 或开启高级写总开关绕开这一要求。

拟批准范围仅为 Windows 现有 Domain/Repository 的向后兼容增量：按仓库已记录的五端
契约增加逐项能力标记、可选结果字段和对应操作接口，使现有实现能接入完整 WinUI 流程。
缺省能力关闭，旧构造和只读实现继续可用；新增操作复用现有 MutationResult，并完整覆盖
确认、权限、一次提交、未知结果核对和取消。未记录的新 API 仍须独立契约切片。

影响范围：Windows Domain、Infrastructure、Application、WinUI 与合成回归；同步平台
矩阵/五端影响说明，不修改 macOS App、Apple 共享包或 Android 源码。无需新增第三方依赖，
不改变应用标识、最低系统、签名、账号/会话存储或磁盘数据格式。

迁移与回滚：只增加内存中的可选字段及默认关闭能力，不迁移用户数据；回滚移除新入口及
本次接口增量即可，保留第一波修复和已有工作区改动。危险写的真实 NAS 授权与验收仍独立，
浏览器已登录不等于允许执行写验证。本项需要用户明确同意接口增量，不能用“剩余目标很大”
或既有测试通过代替授权；整项目标继续保持 active，未宣称完成。

- 固定认证、会话、证书、QuickConnect、公开请求契约和错误映射。
- 对私有 API 建立能力探测、环境记录、只读降级和写入口默认关闭策略。
- 为高影响写操作建立确认、权限、重复提交保护、提交未知处理和最终状态复查。

### W1：Files 与传输

#### 2026-09-17 文件拖放移动与撤销确认

实际缺陷：FilesPage.FileList_Drop 接受普通文本路径、筛选当前条目后直接 SubmitAsync，
目标权限固定 true；撤销保存的仍是移动前路径，且部分成功也展示全部选择的撤销提示。
基线为 macOS WorkspaceModel 的 drag move / undoRecentDragMove 用户结果与项目安全
规则。Windows 保留拖放及撤销，但来源绑定本页拖动快照，目标使用实际权限，并复用
既有批量移动确认/结果界面；撤销使用回读确认的移动后条目，不猜测旧路径。范围限定
App 私有拖动会话、FilesPage 及既有批量 ViewModel/测试，不改 Domain/Repository、
NAS API、存储或外部剪贴板。危险写不在真实 NAS 验证；不扩大待审批映像模型范围。

已完成：DragItemsStarting 仅写入一次性票据，路径和完整 FileItem 快照保留于页面内存。
来源必须全部属于当前页面/目录且可移动；票据消费一次，加载/导航、拖动结束、卸载和
销毁使其失效。Drop 不读取普通文本，不将无效选择静默缩成子集；目标匹配当前可写目录。
接收数据的拖动 deferral 在显示确认前结束，移动只能由既有批量对话框按钮触发，默认
按钮为关闭。目标可写性从父目录读取结果获得，不再固定 true；确认前再查页面/源快照。

批量 ViewModel 增加仅 App 内部可见的已确认结果条目，不修改 Domain/Repository。
全部源项明确成功且移动后仍可删除才提供 10 秒撤销；撤销消费一次、检查期限，使用
ConfirmedItem 的移动后路径/时间基线，再读取原目录权限并显示确认。部分成功、未知
或旧票据不显示整批撤销；未知结果增加双语“检查源和目标，勿重复操作”提示。
普通批量移动和拖放共享同一提交/回读/显示链，未新增平行请求实现。

原生回归发现另一个共同故障：读取 FileBrowserUp 的带命名空间无障碍资源键时抛出
WinRT InvalidCastException。使用已安装 MakePRI 对生成的 resources.pri 做只读转储，
确认 `[using:Microsoft.UI.Xaml.Automation]` 内部点属于单个资源段；旧 GetString 对所有
点替换斜杠导致错误路径。公共 ToResourcePath 现只转换括号外的属性分隔点，原有普通键
语义不变；新增 6 个映射测试。错误定位到资源读取后，撤掉了无效的集合/模板试改，
FileLocationsView 与文件夹模板未因此保留无关变更。临时阶段诊断代码与 PRI 转储已清理；
正式测试及合成输出保留，不含真实文件或 NAS 数据。

新增会话 **4 项**、拖动/撤销源契约 **2 项**、资源路径 **6 项**，并加强批量测试对
ConfirmedItems 的路径和未知结果断言。聚焦 **36 通过**；全量 **2635 通过、1 符号链接
权限失败、0 跳过（共 2636）**。原卸载和 NAS 资源源契约测试按新的清理/正确转换路径
加强断言，没有删除安全断言或把环境失败跳过。
中文、英文原生各 **9 场景**通过，分别位于 `windows/dist/ui-review-20260917-154118`
和 `windows/dist/ui-review-20260917-154401`。场景包含确认、普通文本、伪造/失效票据、
只读/权限变化、部分未知和移动后再次确认撤销。提交由真实 ContentDialog 主按钮的
自动化 Invoke 触发，合成 Repository 验证恰好一次、撤销使用新路径及新修改时间；
没有调用真实 NAS、操作系统剪贴板或外部文件。

五端影响：只修 Windows 交互与资源索引读取，API/存储/权限/身份不迁移；Apple/Android
不改。PENDING_USER_VALIDATION：在可丢弃文件上检查鼠标/触控拖放、目录权限变化、
确认/取消、断网未知、10 秒撤销及过期票据，真实拖动手势/辅助功能仍待设备验收。
不覆盖已有文件，不据合成成功宣称真实 NAS 写行为已验收；反馈只包含步骤、版本和
脱敏错误，勿附真实路径/主机/账号。用户已有界面/业务改动保留，未提交/推送。

收尾补查关闭预览期间的源/目标快照变化，撤销取消/过期/页面清理后移除操作按钮闭包。
英文确认/部分未知/撤销共 4 个场景在 `windows/dist/ui-review-20260917-154934` 再次
通过；未知提示新增 1 对资源，资源总数为 Apple 4031、Android 2188、Windows 2843。
本地化/硬编码、96 请求 fixture、3 响应组/22 私有引用、文档严格预检、差异检查通过。
排查使用现有 SDK 的 MakePRI dump，只读转储文件与空临时目录已删除，可重新生成；
没有改变 PRI 生成流程、依赖或工具链。正式构建/打包结果在本节另记，不用构建成功
替代实机拖放与 NAS 写行为验收。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~FileDragMove|FullyQualifiedName~FileCopyMoveBatch|FullyQualifiedName~Localization' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios files-drag-move -Language zh-CN -WindowWidth 1100 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios files-drag-move -Language en-US -WindowWidth 1100 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios files-drag-move -States drag-confirm,drag-undo,drag-partial -Language en-US -WindowWidth 1100 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

此处完成的是 Windows 已有危险拖动入口修复，不表示全部文件操作、系统集成或完整
macOS 对齐已结束；未批准的多标签/下载任务扩展仍不实施。

该波测试包已完成两架构构建和校验：
`windows/dist/20260917-155130/LanStash-0.1.0-x64.zip` 与同目录 ARM64 包。使用既有
`./windows/package.ps1`，非交互、both、自包含、不重复运行测试、不自动安装/启动，
全部参数沿用前波。SHA-256 重新计算与 sidecar 一致：

```text
x64   28D67D09D1C2EC44B9AC38EC2CA2F4C7DB822B30EDEB4423229B826EE0B29AC6
arm64 5E4D8EA18D6219CEF5917DE6DA8F6DD80F381BF13474121917A824E80C041E3B
```

后续主线需代码范围审批：IContainerManagerRepository 尚无容器/映像/项目生命周期
成员，IVirtualMachineManagerRepository 只有快照读取。为实现创建、编辑、控制及
异步任务结果，需向后兼容增量的请求/结果/能力接口，保留已有调用方默认实现，不新增
平行服务；容器内部接口缺口先做发现，VMM 优先官方公开契约。该审批不授权真实 NAS
写行为、不改变应用身份/权限/工具链/持久化；回滚为关闭新能力并撤销增量及调用方，
没有磁盘数据迁移。Apple 共享模型仅在相关同类缺陷确有必要时增量修改并补 Mac 回归，
Android 不修改。审批未收到前不把自动 goal 继续当作同意，也不提前开放危险入口。

#### 2026-09-17 传输中心继续加载 NAS 任务

基线为 macOS WorkspaceModel.refreshServerBackgroundTasks/loadMoreServerBackgroundTasks；
Windows 当前两个活动刷新器只请求首页并提示截断。目标为在同一传输中心按来源继续
加载、失败保留已读任务、自动刷新保持用户已展开范围；不增建平行任务中心。范围为
现有刷新器/页面、双语按钮和状态说明、正式测试与合成宿主。继续使用现有
IFileBackgroundTaskRepository/IDownloadStationRepository 的 offset/limit 与游标模型，
不改公开接口、协议、存储、通知注册或任务写操作；每页 100 项，单来源单飞读取。
已停止/销毁及跨代次结果不得提交；不把读取到任务或任务消失当作 NAS 操作成功。
五端无契约迁移，Apple/Android 不修改；映像下载结构审批仍保持待确认。

已实现两个来源的继续加载与状态提示，使用各自返回的原始游标而不是已显示数量，
因此过滤掉的未知条目不会把后页请求送回零偏移。单页仍为 100 项；同一来源的手动
刷新、定时刷新和继续加载共享在途请求。后页失败不提交半截结果、不前移游标；重试
仍从原游标开始。自动刷新从首页重读到用户已经展开的范围，只有整段成功才替换旧
快照；任务总量缩小时正确收束，分页边界重复 ID 合并而不显示重复行。坏偏移、超页长、
页内重复身份和无前进游标明确失败，不靠静默截断掩盖问题。

原传输页面每 500ms 重置整个 ItemsSource，扩展长列表后会反复重建行；本波改为现有
页面内的 ObservableCollection 按稳定活动 ID 增量同步，未变更行保持对象，必要时
移动/替换，销毁后清空。没有新建并行任务中心或修改 NAS 任务。两个原生 InfoBar
增加“加载更多”按钮与本地化计数，移除固定“仅前 100 项”的旧文案；提示区上限从
240 调到 320，以容纳两个正常态按钮，更多错误提示仍可滚动。

新增 **17 项**回归覆盖三页、展开范围刷新、后页失败原游标重试、刷新第二页失败保留
完整旧缓存、单飞/取消/停止、畸形分页、跨页去重和原始游标前进；活动刷新器 **37 项**
通过，包含页面源契约为 **41 项**通过。全量 **2623 通过、1 失败、0 跳过（共 2624）**，
唯一失败仍是本机符号链接权限，未改断言或跳过。原 Download Station 刷新器的 105 项
单页假数据按真实 Repository 的每页最多 100 项契约纠正，另加超页长失败用例，保留
首批 100/总量 105 的显示与后续可读断言。

中文原生分页 **10 场景**（`windows/dist/ui-review-20260917-150044`）与英文分页
**10 场景**、生命周期 **8 场景**（`windows/dist/ui-review-20260917-150242`）通过。
原生断言验证两个来源累积到 500 项、末页隐藏按钮、失败保留/重试、展开范围刷新、
忙时隐藏不提交后页，以及未变化行不被 Reset 或替换。首轮合成宿主编译发现未使用的
测试局部变量，删除后重建通过。视觉发现第二按钮被提示区高度遮住，调整后英文初始/
错误浅深色 **4 场景**和中文初始浅深色 **2 场景**复验；分别见 150435/150548 输出目录。
截图最后等待正常 ListView 入场动画完成，不把淡入中间帧当作空列表。

PENDING_USER_VALIDATION：真实 File Station/Download Station 至少两页任务，分别继续
加载、刷新、断网后重试和隐藏/返回；已有任务不消失，后页失败不跳游标，不触发 NAS
任务取消。真实长列表滚动位置、Narrator、触控与网络变化仍需设备验收；仅回传版本
类别、步骤及脱敏失败，不附任务名称、路径、主机或日志正文。独立复核确认读取仍走
既有接口，没有注册系统服务或扩大写权限；保留其他未提交改动，未提交/推送。

收尾命令（沿用已有 SDK/Python，无依赖或工具链变更）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~ActivityRefresher|FullyQualifiedName~TransferActivitySourceContract' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios transfer-pagination -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios transfer-pagination,transfer-lifecycle -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios transfer-pagination -States transfer-pages-initial,transfer-pages-error -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios transfer-pagination -States transfer-pages-initial -Language en-US -WindowWidth 1000 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

最终英文初始浅深色图在 `windows/dist/ui-review-20260917-150717`，已人工确认两个
按钮和任务行完整显示；正常入场动画未禁用。两架构正式配置构建均通过，0 警告、
0 错误；本地化资源数 Apple 4031、Android 2188、Windows 2842（新增 4 对），双语/
参数/硬编码检查通过。96 请求 fixture、3 响应组/22 私有引用、文档/差异检查通过。
本波没有运行新 Swift/Android 构建，也不外推为这些平台或真实 NAS 已验收。完整
目标及待审批的映像模型保持不变，继续其余业务和系统集成缺口。

本波集成包为 `windows/dist/20260917-150807/LanStash-0.1.0-x64.zip` 与同目录 ARM64
包，包含分页与上一波生命周期修复。通过既有 `./windows/package.ps1` 执行，环境为
LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=0、
LANSTASH_LAUNCH_AFTER=0；测试已独立运行且保留权限失败，打包不重复运行。未安装/
启动或覆盖旧包，build-info 标注自包含 Release 与 main@0eeeb170358c 加工作区改动。
两包重新计算 SHA-256 与脚本 sidecar 一致：

```text
x64   DB575B0CA434A4AE6BCA53BFFC3093ABE99F3AE5EEA583622EB3ADE15E3871F6
arm64 750C960971ABFD5D0AB6ACB872541B62361EB7B5C424A094E34859B60C12E495
```

未提交/推送，保留所有此前改动及清理受限的忽略产物；包不代表正式发布、真实 NAS
验收或完整 macOS 业务对齐已完成。

#### 2026-09-17 传输中心取消与销毁生命周期

本波不扩展待审批 Domain/Repository。Windows TransferActivityPage 当前在生命周期锁
内等待首次网络读取，隐藏/卸载/销毁需要同一锁，可能延迟取消；两个现有 NAS 活动
刷新器在 Stop 完成后才标记 disposed，存在销毁等待期间重新启动的窗口。以 macOS
WorkspaceModel 的 backgroundTaskGeneration 隔离和当前 Windows 前台刷新/取消语义
为依据，先用受控延迟请求复现，再修复状态切换与等待分离、幂等销毁、迟到隔离。
范围为两个活动刷新器、既有 TransferActivityPage、正式回归与合成宿主；不新增通知
注册、后台服务、接口、存储、真实 NAS 写或停止服务端任务。当前只读首页 100 项及
截断提示不变，不把它误称为完整历史。五端无协议迁移，Apple/Android 本波不改。

修复前先增加受控延迟回归：两个刷新器的“销毁时仍可 Start”和“已有 Stop 在等待时
Dispose 提前完成”共 **4 项明确失败**；首次测试编译因 xUnit 选择了异步 Throws 重载
报错，改用 Action 检查非 async 的同步状态守卫后得到上述真实复现，未绕过分析器。
修复使用同一停止任务等待此前未退出的代次，销毁原子关闭入口并复用同一结束任务；
取消回调和请求等待不占状态锁，延迟启动的读取也先检查代次。正常 Stop 后重新 Start
仍被支持，旧结果不会覆盖新代次。页面仅将状态切换串行化，随后在锁外等待网络；
销毁时同时请求两个刷新器停止，不等待其中一个才取消另一个。

新增回归共 **6 项**，涵盖 Stop/Restart/Dispose 交叠的两个未退出代次；活动刷新器及
页面源契约聚焦 **24 通过**，全量 **2606 通过、1 符号链接权限失败、0 跳过（共 2607）**。
真实原生合成宿主用两个延迟仓库验证隐藏立即取消、重新可见重新读取、双源同时取消及
忽略取消时销毁等待；中文 **8 场景**（`windows/dist/ui-review-20260917-144504`）和
英文 **8 场景**（`windows/dist/ui-review-20260917-144654`）通过，浅深色均覆盖。
首轮原生探针只依赖取消回调顺序，虽隐藏已完成但信号遗漏；定位后以令牌最终取消状态
补记，保留“释放延迟读取前两个来源均被取消”和“销毁不得提前完成”的断言。没有修改
生产轮询间隔、NAS 操作或用户可见文案以迎合测试。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~ActivityRefresher|FullyQualifiedName~TransferActivitySourceContract' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios transfer-lifecycle -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios transfer-lifecycle -Language en-US -WindowWidth 1000 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

独立集成复核：没有新增重放、服务端 stop、通知注册、路径/凭据输出或接口迁移；
刷新失败保留既有快照、取消不变成失败、旧代次不污染新页面。PENDING_USER_VALIDATION：
真实 NAS 慢连接时打开/隐藏/恢复/切换传输中心及退出，确认界面不会等待一个读取才
取消另一个，也不误取消 NAS 作业；操作步骤和脱敏错误可回传，勿传任务名称/路径。
未提交/推送，保留所有既有改动及清理受限产物。本波先完成生命周期，不重新打包；
旧包不含该修复。后续补 macOS 已有 loadMoreServerBackgroundTasks 对应的 Windows
“加载更多”主流程，沿用现有分页接口，不因此缩小完整对齐目标。

收尾验证：x64/ARM64 正式配置均构建通过，0 警告、0 错误；本地化资源仍为 Apple
4031、Android 2188、Windows 2838，双语/硬编码、96 请求 fixture、3 响应组/22 私有
引用、文档严格预检与差异检查均通过。未运行新 Swift/Android 构建，未将其他平台
历史验证外推为本轮结果。

#### 第二波现有契约阅读切片结果

接口增量仍等待明确同意，未把自动继续视为批准。本次完成的是既定目标中可独立实施的
Chat 阅读/前台刷新链路，完整高级功能和系统集成目标保持不变。

- `ChatBrowserViewModel` 最新页刷新不再重建历史缓存；保留原游标，新增活动跨过原完整
  缓存时重新开放分页。新响应更新相同消息的内容；当前最新页未读到的旧删除待核对标记
  继续保留，避免被无关刷新清除。完整无后页快照仍可移除已不存在的条目。
- 会话及消息集合按稳定 ID 增量更新，不用 Reset 重建全部行；历史加载进行中不启动
  另一条最新页读取。实际滚动像素稳定性仍待设备长列表验收，集合行为已有回归。
- 私有内存缓存记录实际成功读取的消息时间，按 profile/会话隔离；可见后才应用本地已读，
  未知时间不使用本机时钟推测。消失或转为加密的会话清理相关缓存。没有 NAS 已读写或新存储。
- `ChatPage` 联动窗口、卸载、宽窄布局和返回列表的可见性；切换会话先撤销旧面板已读资格，
  再由新布局确认，防止把旧会话误标已读。既有前台单飞刷新使用 macOS 无实时连接时的 5 秒
  间隔，隐藏消息面板不读消息；Socket.IO 仍未实现，不把轮询说成实时通道完成。

新增回归先复现历史丢失、刷新取消历史页、旧待核对消息消失；独立复核又补测并修复完整
缓存后新增多页消息的分页缺口，以及切换会话前错误应用旧可见性的风险。现有用户改动均
保留，无 Domain/Repository 公共接口、Apple/Android、认证、依赖、权限或磁盘格式改动。

实际验证命令与结果：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~Chat -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios chat -WindowWidth 900 -PaneState cycle
python tools/localization/check_localization.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

使用现有 .NET 10.0.401 和 bundled Python；Chat **193 通过**，全量 **1673 通过、1 失败、
0 跳过（共 1674）**。唯一失败仍是 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`
所需本机符号链接权限，未跳过或改变系统设置。900px 浅深色 Chat 合成场景均通过，人工查看
截图确认聊天内容与输入区正常；本地化、文档、差异门通过。最终独立包的构建/清理结果
如下，不把未执行的 NAS/托管 Runner 验收写成通过。

沿用 `windows/package.ps1`，设置 `LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`。
全量测试已单独运行并保留真实失败，打包只避免重复运行；x64/ARM64 Release 自包含发布
均成功，SHA-256 与脚本校验文件一致：

- `windows/dist/20260916-125234/LanStash-0.1.0-x64.zip`
- `windows/dist/20260916-125234/LanStash-0.1.0-arm64.zip`

未安装或启动正式测试包，未提交/推送；已有工作区改动保留。本波两张临时合成截图在核对
明确路径后删除，可通过正式脚本重新生成；此前产物未删除。

`PENDING_USER_VALIDATION`：在已有授权账号中打开未读会话、读取更早历史、等待新消息，
切到别的模块/托盘/窄屏列表后返回，检查历史、未读和阅读位置。失败/断网/取消不能清除
新未读；不同 NAS 不串状态。只回传版本、可见行为与脱敏失败类型，不上传聊天内容或原始
响应。本波不执行真实 NAS 读写，接口增量审批和其余完整目标继续待办。

- 完成 Files、预览、前台上传/下载、可解释取消、恢复与 Activity 的 macOS 业务语义。
- 跨 NAS、背景恢复、Cloud Files 和系统集成路径先保证唯一所有者与失败恢复，再考虑开放。
- 不把 Windows Explorer 或 Cloud Files 的未验证系统行为写成已完成。

### W2：Photos、Chat 与 Download Station

#### 用户批准后的 Chat 高级动作波次

本波实际完成：提醒设置、列表、确认取消；纯文字定时消息创建、列表、确认取消；无附件
投票创建、消息内投票选项/计数显示。入口为 WinUI“聊天工具”和消息行提醒按钮；原生
对话框提供五态、筛选、重试、英中资源、浅深色和 44px 交互目标，默认焦点仍是关闭。
取消前使用显示时的完整基线，内容/时间变化则拒绝，成功或明确失败后需重新操作界面，
连续点击不生成第二次提交。投票参与等 macOS 尚未完成能力不在本波伪装实现。

实现位置：

- Domain：`ChatModels.cs` 追加能力值与可选 Poll，`IChatRepository.cs` 增加默认环境准备和
  带取消基线的兼容重载；旧构造及已有实现保留，不改持久化或共有 JSON Schema。
- Infrastructure：`DsmRepository.ChatAdvanced.cs/ChatPollCodec.cs` 接替旧的未贯通高级实现；
  一套请求状态负责确认、权限、去重和回读，不新增平行 API 客户端。`Chat.cs` 的既有
  JSON 字符串字段统一编码，Named 创建同步移除重复编码，数组/布尔/数字不混为字符串。
- App：`ChatAdvancedViewModel`、`ChatAdvancedDialogContent.xaml/.cs`、`ChatPage.Advanced.cs`，
  复用 Chat 页及消息模型；双语资源追加，现有 Chat 弹窗显式继承页面主题。
- 正式回归：`ChatAdvancedFlowTests`、`ChatAdvancedViewModelTests`、现有页面源契约和
  `UiSmoke` 新场景；未降低旧安全断言或跳过失败门禁。

独立集成/对抗复核已补测：网络与明确拒绝区分、未知请求只回读、Repository 重建后不重写、
同目标变更草稿冲突、异会话响应、缺失列表、取消基线变化、旧同内容投票不能确认新写、
传输仍在进行时不能抢先确认、秒/毫秒时间、单条对象响应、JSON 基础消息读取和二次编码。
待核对跨 Repository 标记仅存 profile/账号/目标指纹、候选标识与必要消息 ID，不保留
Repository、会话凭据或静态正文；没有写磁盘。重启进程后的恢复仍须用户核查官方 Chat。

新写能力门只匹配已记录的 `7.2.1 / 69057 / 12 / Chat 2.4.1-22111`，且必须满足相应
接口版本、当前可见且未加密的会话与目标检查。元数据无权限不阻断个人列表读取，未知
版本不开放新写。该门不等于实机通过：本波没有向真实 NAS 创建、发送或取消任何内容。
五端影响、请求字段、证据等级、回滚和 `PENDING_USER_VALIDATION` 的操作步骤集中在
[高级动作记录](../api/discovery/endpoints/chat-advanced-actions.md)。

实际运行（已有 .NET 10.0.401 与 bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~Chat -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios chat-tools -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

最终 Chat 聚焦 **216 通过**；最终全量 **1696 通过、1 失败、0 跳过（共 1697）**，唯一
失败仍为本机符号链接权限测试。此前一次全量还出现
`FilePreviewViewModelTests.NewReadInvalidatesNonCooperativeOldReadBeforeAdvancingCursor`
等待请求断言失败；该用例未修改，单独复跑及后续全量通过，保留此次不稳定观察，不隐藏。
14 个高级聊天原生场景通过，覆盖三分区浅深色、加载/空/筛选空/错误、只读、待核对、成功
与明确拒绝后的连点防护。视觉复核发现并修复了弹窗未跟随深色，以及动作按钮默认样式
继承问题；最终使用原生默认样式并增加触控高度。

本地化（Windows 2066 资源）、96 组请求 fixture、3 组响应 fixture/22 项引用、文档及
差异检查通过。最终 x64/ARM64 Release 自包含发布与 SHA-256 校验通过：

- `windows/dist/20260916-142940/LanStash-0.1.0-x64.zip`
- `windows/dist/20260916-142940/LanStash-0.1.0-arm64.zip`

使用既有 `windows/package.ps1` 与 `LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`。
测试已单独运行且保留真实失败，打包仅避免重复测试；没有安装或启动正式测试包。
本波 64 张临时合成截图和被最终安全修复替代的 `20260916-141204` 中间包已核对明确路径
后清理，可用正式回归/打包脚本重新生成；最终包及正式测试源码保留，其他任务输出未删。
没有提交/推送、工具链/依赖升级、Apple/Android 修改。整个 Windows 对齐目标仍未完成，
接口批准已记录，不再重复请求同一授权；下一独立切片是关闭会话/转发/公告写与实时同步，
随后继续下载、NAS、Container/VMM 及系统集成。

#### 关闭、转发与公告动作波次

波次基线：`DsmChatRepository.closeConversation/forwardMessage/setMessagePinned` 与 API
参考 8.10。目标为单会话关闭、单消息到多个既有会话转发、群公告设置/取消；WinUI 原生
对话框提供消息/目标选择、归档说明和独立确认，默认焦点仍为关闭。单一修改范围是 Chat
Domain、既有高级状态机、消息/公告读取、工具对话框、双语资源和正式测试。安全级别为
私有写；仅按既有已知版本门开放用户确认，无 NAS 自动写验证、存储、依赖或其他平台改动。
批量消息/批量关闭、新联系人复合转发和 Socket.IO 继续属于完整目标，不以本波替代。

实际实现：`DsmRepository.ChatActions.cs` 复用统一高级状态机与 FORM/JSON 编码；移除旧的
未贯通 close/forward 实现及关停总常量。close 固定 v5 并严格验证完整会话列表，缺失容器
不能证明消失；允许关闭加密会话但不读取消息。forward 固定 Post v5、数字接收 ID 数组、
只发送一次，逐目标排除旧消息并核对本人/时间/内容；公告 search 完整分页，pin/unpin
回读状态。消息快照读取复用既有分页，字段/时间变化时先刷新再确认。

独立只读集成/对抗复核补测并修复：未确认转发改接收人绕过防重、跨 Repository 并发核对、
关闭后异常响应误判、旧同内容目标消息误判、101 条后的公告、加密关闭、投票排除、来源
快照变化、界面刷新异身份和待核对草稿冻结。附件只核对描述字段，不宣称字节级一致。
能力缺失/未知版本仍关闭新写；真实权限、归档、多成员并发和附件回读为
`PENDING_USER_VALIDATION`，前提、步骤、预期和脱敏回传范围见
[高级动作记录](../api/discovery/endpoints/chat-advanced-actions.md)。五端影响只扩展 Windows
已批准接口，不改变共享 Schema、其他四端代码或持久数据；回滚移除增量入口即可。

验证沿用上一波命令：Chat 聚焦 **232 通过**，全量 **1712 通过、1 失败、0 跳过（共 1713）**。
唯一失败仍为 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 缺少本机
符号链接创建权限，未跳过/降断言或改变系统权限。本地化（Windows 2078 资源）、96 个请求
fixture、3 组响应/22 项私有引用、严格文档和差异检查通过。
`./windows/tests/UiSmoke/run.ps1 -Scenarios chat-tools -WindowWidth 900 -PaneState compact`
完成 **20 个原生场景**，其中新增动作浅深色均验证未确认不能提交、确认后一次提交和连点
防护；人工复核转发深色与关闭浅色截图，内容和确认区完整。未执行真实 NAS 写操作。

使用既有 `windows/package.ps1`、`LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`，
独立全量测试保留上述失败，打包只避免重复测试。x64/ARM64 Release 自包含发布成功：

- `windows/dist/20260916-151412/LanStash-0.1.0-x64.zip`
- `windows/dist/20260916-151412/LanStash-0.1.0-arm64.zip`

未安装/启动这些包，未提交/推送；原工作区改动保留，Apple/Android 无修改。本轮 20 张
虚构数据截图 `windows/dist/ui-review-20260916-150518` 及合成宿主 `windows/dist/ui-smoke-x64`
的清理命令被执行工具策略拒绝，实际尚未删除，需后续在允许的条件下清理，不提交这些产物。
下一切片是 macOS `ChatWorkspaceModel.forwardMessages/closeConversations` 对应的批量选择与
新联系人复合转发，然后继续 Socket.IO 与账本后续模块；整个对齐目标仍为未完成。

#### 批量会话与消息操作波次

基线为 macOS `ChatWorkspaceModel.forwardMessages/deleteMessages/closeConversations` 及其
测试；Windows 以现有聊天工具内的原生多选代替桌面菜单组合，保留逐目标确认结果、部分
失败和新联系人先打开单聊再转发语义。当前单一修改范围为 ChatAdvancedViewModel/对话框、
现有 Chat Repository 必要安全修正、双语资源、正式测试与账本；不新增网络端点或持久格式。
依赖上一波单项 v5 请求及既有 `Channel.Anonymous.initiate` v2。安全级别为私有写/消息删除；
已知版本门不放宽，真实写验收后置。新联系人解析失败不得继续转发；未知结果只核对已提交
项，尚未提交项需用户明确继续，不用“核对结果”暗中发起新的写入。本轮不包含 Socket.IO、
其他套件或系统集成，但这些仍属于完整目标。验证等级从源码/合成起，不提升 NAS 证据。

本波实际接通批量关闭、按时间排序的多消息转发、先打开新联系人单聊再转发，以及批量
本人消息删除。使用现有聊天工具中的原生多选与独立确认；只列出已加载且适用的消息，
更早历史由聊天页加载后再选择。逐项展示结果和汇总，前置单聊打开单独计数；明确失败的
普通项不阻断其他独立项，新联系人创建失败则不转发任何消息。未知项暂停，核对不会
启动剩余项；继续需要再次勾选确认，也可不再执行剩余项。已成功项不重放。

源码：`ChatAdvancedViewModel.Batch.cs` 是现有高级 ViewModel 的 partial，仍只有一个
待处理所有者和现有 Repository 请求通道；对话框及英中资源同步更新。删除移入已有
高级请求状态机，修复 FORM-only 和最新 100 条假定，固定 Post v5/FORM/JSON；可选
`ChatDeleteMessageRequest.ExpectedMessage` 属已批准兼容增量，保留旧构造。严格分页
核对容器、身份、跨会话、offset/total、重复项及空洞，较早历史仍存在不能证明删除。
没有新端点、Schema、第三方依赖、存储格式或 Apple/Android 改动。

独立集成/只读对抗复核增加并验证：旧页面销毁后不开始新写、重复 Dispose、逐项能力变化、
新单聊返回错误身份、来源快照变化、未知请求改草稿、核对后连点误触后续新写、已确认历史
删除及会话置顶缓存清理、零提交“目标已改变”不构造违反 MutationResult 约束的成功状态。
缓存应用按 profile 校验，先应用独立回读结果再刷新，不因刷新失败复活旧数据。来源时间
展示统一转换为本地时区。成功删除也移除工具内来源选择，避免刷新已删除消息造成假错误。

实际命令继续使用已有 .NET 10.0.401 与 bundled Python：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~Chat|FullyQualifiedName~ImageArtifactCarriesMetadataFromReader' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios chat-tools -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

最终聚焦 **251 通过**（Chat 250 + 文件预览复跑 1）；全量 **1730 通过、1 失败、0 跳过
（共 1731）**。唯一剩余失败仍为本机符号链接权限测试，未降断言/跳过/变更系统权限。
中途全量另出现 `ImageArtifactCarriesMetadataFromReader` 宽度为 null 的偶发失败；该用例
未修改，聚焦复跑及最终全量通过，保留观察。新的重复 Dispose 失败已修复，正式回归保留。
**30 个原生合成场景**通过，新增批量浅深色、部分失败、新联系人、未知/继续确认与删除；
复核最终删除深色及前轮批量关闭深色/转发浅色截图。最终资源 2101、96 请求 fixture、
3 响应 fixture/22 私有引用、严格文档和差异检查均通过。

`PENDING_USER_VALIDATION`：真实 NAS 的新联系人权限、归档、较早消息删除、部分失败和
断线恢复仍未验证。需使用可丢弃消息及专用会话，先读再逐项确认，未知只核对；只回传
版本/权限类别/动作数量/脱敏错误，不回传消息、成员、文件名或原始响应。详细步骤见
[高级动作记录](../api/discovery/endpoints/chat-advanced-actions.md)。能力与确认保护保留，
本波 Agent 没有执行真实 NAS 写操作。下一切片是 Chat Socket.IO 实时同步，然后继续
下载、NAS、Container/VMM、Files/Photos/传输和系统集成的完整账本，不宣称目标完成。

最终打包沿用 `windows/package.ps1` 与 `LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`。
测试已单独执行并保留失败，打包不重复运行；x64/ARM64 Release 自包含发布和 SHA-256
校验均通过：`windows/dist/20260916-154316/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-154316/LanStash-0.1.0-arm64.zip`。未安装/启动包、未提交/推送，
原工作区改动保留。正式测试源码保留；此前工具拒绝清理的状态未绕过，本波两个临时合成
目录 `windows/dist/ui-review-20260916-153402`、`windows/dist/ui-review-20260916-153859`
及复用的 `windows/dist/ui-smoke-x64` 仍待允许后清理，仅含虚构测试数据，不提交。

- Photos 正式入口已迁移到 `Views/Photos/SynologyPhotosPage` 与独立照片状态／媒体层；完整范围、性能边界与验收只维护在[照片计划](NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。后续候选不因 macOS 实现而
  自动进入 Windows。
- Chat 按文字、受限附件和明确的低风险操作推进；加密、语音、实时通话和未验证服务器写
  保持关闭或后续。
- Download Station 先推进公开只读与明确单任务语义；设置写、RSS 写、批量与删除数据作为
  独立危险写决策。

#### Chat 实时同步波次

macOS 证据为 `DsmChatRealtimeClient.swift`、对应测试与 `ChatWorkspaceModel` 的事件回读；
私有契约为已记录 `chat-realtime`、同源 `sc/socket.io`、Engine.IO 4/3。Windows 使用系统
ClientWebSocket，但握手复用现有 HttpClient/证书策略和 profile 上下文，不另建信任体系。
接入已批准的兼容接口增量：只传连接/断开/内容变化枚举，不向 App 传事件正文或凭据；旧
提供者默认空流，保持原轮询。安全级别为认证/证书/后台生命周期，非 NAS 写操作。

单一修改范围为 Chat 实时 Domain/传输兼容增量、Infrastructure 实时 partial、现有前台
刷新器与 ChatPage 接线、正式测试及相关文档。Windows 目标是可见 Chat 页事件合并回读、
连接成功 30 秒校准/不可用 5 秒轮询、握手超时/心跳/指数退避、隐藏/离页/销毁立即取消。
1 MiB 帧上限、同源 HTTPS/WSS、认证只在请求头、不记录正文和秘密；跨 NAS/旧代次事件不能
影响新会话。Engine.IO 心跳细节另核对官方协议，不以 UI 存在代替真实连接。无第三方依赖、
持久化、签名、权限或 Apple/Android 修改；真实 NAS/中继/睡眠唤醒验收后置，其他完整目标保留。

实际实现：Domain 新增纯枚举事件与 Repository/传输默认空流，旧实现继续轮询。网络层
`DsmApiClient.ChatRealtime.cs` 经系统 ClientWebSocket 与原 HttpClient 完成握手，明确
WSS→同源 HTTPS 转换、profile 上下文和秘密请求头；原证书处理器和其默认禁重定向配置
未改。`DsmChatRealtimeClient` 实现 EIO 4/3、握手/心跳超时、1 MiB 分片上限、严格 UTF-8、
记忆成功版本和有界退避，只传枚举。`ChatForegroundRefresher` 仍是唯一回读所有者，
250 毫秒合并事件；晚于旧快照的事件会等待已有回读后再读一次，不并发。连接成功后的
30 秒校准与 5 秒失败轮询共用原循环，旧代次不能启动新页面请求。

`ChatPage` 订阅沿用可见性生命周期；浅深色原生合成事件验证读取到新增消息，隐藏后
订阅归零、恢复后重新订阅。视觉复核发现原列表新消息可只露出一部分，已用原生
ItemsStackPanel/ScrollViewer 补齐底部跟随、历史位置保持与选择新会话后的定位；没有
自定义滚动动画。后续原生测试直接检查向上滚动后新事件不抢位置、回到底部恢复跟随。

独立只读集成/对抗复核覆盖：异 profile/异源/非法请求头零请求、重定向零跟随、原生
101 双向流完整接收与枚举取消、共享 HttpClient 不被释放、握手顺序/超时、EIO 3/4
心跳方向、重连偏好、UTF-8 分片与尺寸上限、事件洪峰/已有回读/隐藏/旧订阅迟到隔离。
没有复制另一套证书信任，没有新增第三方包或持久数据。通用心跳依据已记录到
[实时端点记录](../api/discovery/endpoints/chat-realtime.md)的官方协议链接，不冒充当前 NAS
实测。五端影响和回滚范围同记录：仅 Windows 接线，其余四端不改。

实际命令（现有 .NET 10.0.401/bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~Chat|FullyQualifiedName~Certificate' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios chat -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

最终 Chat+证书聚焦 **302 通过**；全量 **1758 通过、1 失败、0 跳过（共 1759）**，唯一
剩余失败是本机符号链接权限用例。中途新重连测试在消费队列前取消而偶发丢弃缓冲事件；
测试已改为等待断开事件被观察后再取消，仍完整断言连接/断开、回退版本和资源释放，未
降低断言或跳过。4 个最终原生场景通过（正常/实时 × 浅深色）；本地化 2101 资源、96
请求 fixture、3 响应/22 私有引用、严格文档与差异检查通过。实机前提、操作、预期与
脱敏回传范围见实时记录的 `PENDING_USER_VALIDATION`；本波没有连接真实 NAS 实时通道，
没有业务写操作或修改信任设置。下一切片是 Download Station 剩余管理功能，其余全范围
继续保持未完成，不因实时源码/合成通过提前结束目标。

沿用 `windows/package.ps1`、`LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`。
测试已独立运行并保留真实失败，打包仅避免重复测试。最终 x64/ARM64 Release 自包含发布
和 SHA-256 校验通过：`windows/dist/20260916-161431/LanStash-0.1.0-x64.zip`、
`windows/dist/20260916-161431/LanStash-0.1.0-arm64.zip`。未自动安装或启动、未提交/推送，
原工作区用户改动保留。此前清理操作被工具策略拒绝，本波不绕过；临时合成目录
`windows/dist/ui-review-20260916-160338`、`windows/dist/ui-review-20260916-160654`、
`windows/dist/ui-review-20260916-161108` 与复用的 `windows/dist/ui-smoke-x64` 仍待允许后
清理，仅含虚构测试内容，不提交。

#### Download Station 设置波次

macOS 证据为 `ServiceManagementModel.loadDownloadSettings/saveDownloadSettings`、
`DsmServiceManagementRepository` 设置读取/保存与共享请求 fixture。Windows 目标为原生
设置对话框、默认位置、eMule/自动解压、速度限制和既有计划开关；任务详情/RSS/批量管理
仍在完整目标中，随后继续，不以设置切片替代整个下载模块。单一修改范围为 Downloads
Domain/现有公开适配器、ViewModel/设置对话框、双语资源、正式测试及契约/矩阵文档。

已核对官方 Download Station Web API 指南：Info 的默认位置字段只在 v2+，而其余基础
设置支持 v1+；Schedule 固定 v1。当前 Windows 只用 v1 读取 Info 是已确认差距。按
已批准的兼容接口增量增加设置快照/保存结果，保留旧 Summary/构造；读写优先 Info v2，
仅 v1 时不能编辑默认位置。HTTP/FTP 使用一个共同字段。管理员专属字段不完整时不开放
保存；提交前核对完整确认基线，仅更改已变化组件，未知结果不重放，未开始的后续组件需
单独确认继续。安全级别为设置写；Agent 不执行真实 NAS 写入，实机风险受能力/确认保护。
无新依赖、标识、权限、持久格式或 Apple/Android 代码变更。验证从源码/聚焦自动化和
目标构建开始，真实保存副作用、目录权限和两阶段部分失败为 `PENDING_USER_VALIDATION`。

实际实现：`DownloadSettingsModels.cs` 保留旧 Summary 并增加快照/固定请求/分组件结果；
`IDownloadStationRepository` 添加默认不支持的兼容方法。现有公共适配器支持显式固定版本，
仅 Info 设置选择 v2（仅 v1 则保留基础限速/开关），其他 API 仍固定 v1。读取映射收敛到
`DsmRepository.DownloadStation.Settings.cs`；不复制另一条 HTTP 管线。完整管理员字段缺失
或网页/FTP 值不一致时不提供可编辑快照；计划读取失败独立降级，未知开关不显示成关闭。

保存只提交变化组件，先对完整显示基线进行核对；改变默认文件夹时复用 File Station 列表
确认目录存在且可写，再重读基础基线后提交。统一网页/FTP字段写入相同值，避免覆盖另一
限速。结果未知只读核对，基础已确认而计划未开始时须再次确认继续；明确拒绝保留部分结果。
请求状态沿用 Download Station 既有按 API 实例隔离的弱引用所有权模式，签名还绑定 profile、
账号和连接地址的指纹，不存 SID/令牌、不写磁盘。已提交取消不重放，换请求 ID/草稿或账号
不能绕过本实例待核对状态。未开始组件在聚合计数中属于未完成项，UI 始终明确区分未保存、
待核对与已保存，不将“尚未开始”伪装成服务器拒绝。

App 为 `DownloadSettingsViewModel`、`DownloadStationPage.Settings.cs` 和原生
`DownloadSettingsDialogContent`。默认目录浏览复用已有 `RepositoryFileCopyMoveFolderSource`
及其只读位置约束，不创建目录或绕过权限；可写当前项才可选择。英中资源、原生浅深色、
键盘/44px 动作、加载/错误/内容、目录空态、部分结果与明确确认已接线。基线读取失败时
旧隐藏编辑器不能保存。部分保存结果移到表单上方，失败信息不只出现在长表单底部。

独立集成/只读对抗复核和回归覆盖：Info v1/v2（含最小版本 2）、FORM/JSON 编码、默认位置
权限、旧基线、管理员字段缺失、计划失败独立降级、只改计划不重写基础、部分拒绝、HTTP
结果丢失、取消后的阶段隔离、同 API 实例 Repository 重建、跨账号、冻结草稿、迟到读取
和异 profile 响应。900px 下载整页回归发现新增可选设置按钮与原 ItemsWrapGrid 的组合
导致工具栏越界，已改为原生横向 StackPanel；保留边界断言并补充控件几何信息，不调低门禁。

五端影响：Windows 修复读取版本并补齐既有公开设置语义；macOS 和 Android 已有相关设置
契约，本波不改代码；iPhone/iPad 的下载设置仍按移动专项计划标为非目标，不自动开放。
无需数据迁移，回滚可移除新写入口与接口增量并保留官方读取版本修复；已经由用户确认的
NAS 配置不会自动反向修改，需另行确认恢复。没有新增依赖、工具链、标识或系统权限。

`PENDING_USER_VALIDATION`：使用有管理权限的专用测试账号，记录 NAS/套件版本和连接类别；
先读取设置，分别调整一个限速与既有计划开关，核对官方页面；用专用可写目录测试默认
位置选择。检查无权限、字段缺失、基础成功/计划失败、断网/取消后只核对、不重复提交。
eMule、自动解压和限速对新任务的实际影响必须另行验证，Agent 本波没有调用真实 NAS 写入。
回传仅版本、权限类别、组件状态和脱敏失败类型，不包含目录名、地址、账号、令牌或原始
响应。任务详情、RSS、批量操作及其他模块继续按完整目标对账，不把本切片当作全部完成。

实际验证继续使用已有 .NET 10.0.401 和 bundled Python：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~DownloadSettings|FullyQualifiedName~DownloadStation' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios download-settings,downloads -WindowWidth 900 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios downloads -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

最终下载专项 **116 通过**；全量 **1777 通过、1 失败、0 跳过（共 1778）**，唯一失败仍是
本机符号链接创建权限测试，未跳过或改变系统权限。17 个原生场景通过（15 设置场景与
下载页浅深色），之后补跑设置按钮可见时的下载页浅深色也通过。中途工具栏越界和旧
ItemsWrapGrid/Info v1 假定测试失败均保留并按已复现问题修复，不改成静默跳过。最终
截图复核确认部分保存状态位于表单上方、主操作具有触控高度、未知计划不显示为关闭，
下载页刷新/设置按钮均在窗口内。本地化 2149 资源、96 请求 fixture、3 响应/22 私有
引用、严格文档和差异门禁通过；其他平台源码未修改，没有执行真实 NAS 写操作。

末轮独立复核新增回归复现：已接受的 `webapi/entry.cgi` 声明在公开下载调用中被再次添加
`/webapi`，产生错误双前缀。已在原适配器规范化这一已接受路径，先验证用例失败再修复，
最终上述计数包含该回归。没有新增未知路径或另建 HTTP fallback。

最终沿用 `windows/package.ps1` 与 `LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`。
独立测试已运行并保留失败，打包不重复运行。x64/ARM64 Release 自包含发布与 SHA-256
校验均通过：`windows/dist/20260916-170626/LanStash-0.1.0-x64.zip`、
`windows/dist/20260916-170626/LanStash-0.1.0-arm64.zip`。未自动安装/启动、未提交/推送，
已有用户工作区改动保留。被最后路径修复替代的 `windows/dist/20260916-170125` 不作为
最终测试包；此前清理策略拒绝未绕过，本波该中间包、`ui-smoke-x64` 及
`ui-review-20260916-164533/164952/165156/165320/165741` 五个目录仍待允许后清理，
均位于 `windows/dist`，截图/日志仅为虚构合成内容，不提交。下一切片优先核对 macOS
下载任务多选控制、删除和完整读取语义，其余完整对齐目标保持未完成。

#### Download Station 任务批量操作波次

macOS 证据为 `ServiceManagementModel.controlDownloads/deleteDownloads` 和对应列表多选。
本波单一修改范围：Windows 下载批量 ViewModel/原生弹窗、既有单任务状态映射/错误边界、
主列表结果应用、双语资源与正式测试。复用既有 Task v1 pause/resume/delete 单项适配，
不新建 HTTP 管线；批量任务逐项预检与回读，已成功项不重放，未知暂停、仅核对已开始项，
继续未开始项须另行确认。明确失败可与其余独立任务分别报告；结果和草稿只驻内存。

基线阻断切片（仅数据删除）：`ServiceManagementView` 的 `.taskAndData` 通过
`deleteDownloads(removeData:)` 进入 `DsmServiceManagementRepository.deleteDownloadTasksResult`，
最终把该布尔值传为 `force_complete`。官方指南及 API 参考 6.1 已明确 true 表示结束任务并
把未完成文件移入目标目录，不是删除数据。该切片起初暂停；随后用户明确授权修复这一处及
后续同类语义/文案问题，授权与实际修复见下节。当前 Windows 独立任务移除固定 false，不新增
文件删除或强制结束入口，也不把暂停此错误分支改称完整目标已完成。

安全级别为任务写/删除；暂停还需补齐 macOS 已支持的做种/上传与检查状态。真实 NAS 的
任务/文件副作用、权限与断网继续 `PENDING_USER_VALIDATION`。无新依赖、持久格式或权限，
其余模块仍按原完整目标推进。

本波后续已接通 Windows 原生任务操作弹窗：完整分页读取、操作适用性筛选、多选/全选
显示项、文本筛选、确认、逐项结果、未知核对、明确继续和停止剩余任务。既有回读窗口
上限为 5000 项，超过时明确失败，不静默截断后执行。复用已有单任务预检/请求/回读，
不是新增一套 HTTP 客户端；批量执行不承诺原子事务，已完成项保留并逐项说明。

用户授权 macOS 语义修正后，Windows 也增加明确的“结束下载并保留未完成文件”动作，
通过兼容字段 `DownloadTaskDeleteRequest.ForceComplete` 区分，默认仍为 false。true 的
回读只确认任务结束，UI 要求核对未完成文件；绝不冒充数据删除或文件移动已验证。没有
新增 File Station 文件删除。未知结果期间切换 force_complete 模式被仓储拒绝，不能
绕过旧操作的核对状态；此类动作仍须真实专用任务验收。

同期修复已确认偏差：上传/做种/检查状态可按 macOS 语义暂停；控制与移除基线绑定
标题、大小、保存位置及状态，不因下载进度变化误判；单任务 ID 拒绝逗号和控制字符。
官方 success=true 中的逐任务错误现在独立解析，不将明确拒绝当作成功；HTTP 失败不再
冒充明确 DSM 拒绝。已确认结果先应用主列表并取消旧读取，迟到快照不能复活旧行；结果
只消费一次，重新打开弹窗不反复应用旧状态。关闭弹窗后待核对提示和恢复入口保留。

实现文件为 `DownloadTaskBatchViewModel`、`DownloadTaskBatchDialogContent`、
`DownloadStationPage.Batch.cs`，以及既有任务控制/移除适配与 `TaskResponses` partial。
英中资源、原生浅深色、键盘/触控、加载/空/筛选空/错误与部分结果已接线。第一次原生
筛选空测试暴露 ItemsSource 更新时读取 UI 集合数量的时序问题，已改用实际筛选数组
计算空态；未删除该断言。独立安全复核补测了异常响应、异任务结果、取消、部分失败、
未知模式冲突及历史结果应用，不降低旧删除和能力门。

五端影响：Windows 增加可选 force_complete 请求标记和本地批量编排；macOS 入口已在
上一节按授权纠正，公共 Apple 参数签名仍兼容；Android/iPhone/iPad 源码本波未修改，
移动范围不自动扩张。无依赖、持久化、身份或权限变更。NAS 文件副作用、权限与网络
中断为 `PENDING_USER_VALIDATION`，使用可丢弃任务分别验证 false/true，并独立检查
目录内容；只回传版本、动作、计数与脱敏错误，不回传真实任务名、地址或路径。

本波实际命令（现有 .NET 10.0.401 与 bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~Download -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios download-batch,downloads -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

下载相关专项 **185 通过**；全量 **1793 通过、1 失败、0 跳过（共 1794）**，剩余失败
仍为符号链接创建权限测试。最终原生 **17 场景**通过，涵盖四动作浅深色、核对/继续、
部分失败、加载/空/筛选空/错误及整页布局。人工复核结束下载深色与部分失败浅色截图，
确认任务结束结果没有冒充文件移动验证。新增正式 `DownloadTaskBatchTests`、
`DownloadTaskActionWireTests` 和主列表迟到读取回归；当前缺 Mac 环境，后一节 Apple
Swift/macOS 待验收状态未改变。本地化 **Apple 4026 / Android 2188 / Windows 2181**、
96 请求 fixture、3 响应/22 私有引用、文档及差异检查通过。

最终包继续使用 `windows/package.ps1` 与 `LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`。
独立测试保留上述真实失败，打包不重复测试；x64/ARM64 Release 自包含发布与 SHA-256
核对通过：`windows/dist/20260916-175056/LanStash-0.1.0-x64.zip` 和
`windows/dist/20260916-175056/LanStash-0.1.0-arm64.zip`。没有安装/启动正式包、提交或推送。
本波临时 `ui-review-20260916-173749/174144/174608` 三个目录及 `ui-smoke-x64` 位于
`windows/dist`，仍受此前清理策略限制而待清理；只有虚构合成内容，不提交。完整 Windows
对齐目标保持未完成，随后继续按 macOS 源码核对创建任务、NAS 管理与其他剩余模块。

#### 用户授权后的 macOS 下载语义修正

用户明确同意解除此类缺陷的只读限制，并授权后续有证据的同类 API 语义/文案问题一并
修复；不据此修改无关 macOS 功能，不自动执行真实 NAS 危险写、提交、推送或签名发布。
Windows 批量工作保留在当前未提交工作区，当前仅 ViewModel/状态适配在途，尚未完整接 UI。

实际修改：`ServiceManagementView` 的 `.taskAndData` 改为 `.finishIncomplete`，菜单与
确认动作说明为“结束下载并保留未完成文件”；详细提示说明文件可能不完整、原任务不能
继续，并明确不是删除数据。`ServiceManagementModel.deleteDownloads(forceComplete:)`
在 App 边界使用正确名称，传入共享协议时保留历史 `removeData` 标签以兼容调用；共享
协议与网络实现增加解释，不改变请求字段、身份、会话或存储格式。

结束操作使用独立结果资源前缀；列表消失只说明任务已结束，结果提示用户到保存位置核对
未完成文件，不再宣称文件删除或移动已验证。仅移除任务的提示也不承诺未完成任务可恢复。
App 与 DsmLocalization 共享资源同步英中内容；iPhone/iPad 没有因此增加桌面入口，Android
代码未改。回滚可还原本次 App/资源增量，公开调用签名与数据无需迁移；不得恢复误导文案。

新增但尚未执行的 macOS 模型回归覆盖两个标记/结果前缀、未确认状态保留选择；网络回归固定 true 为
force_complete，并断言没有 File Station 文件删除调用。Windows 可运行的
`MacDownloadForceCompleteSourceContractTests` 验证入口命名及 App/共享双语资源一致性。

实际执行：`swift test --package-path apple` 无法运行，因为当前 Windows 主机没有 Swift；
这不是 Swift 测试通过，也没有生成或启动 macOS 测试包。实际执行的
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~MacDownloadForceComplete -v minimal`
**3 通过**；Windows 全量
**1780 通过、1 失败、0 跳过（共 1781）**，剩余仍是本机符号链接权限用例。本地化
**Apple 4026 / Android 2188 / Windows 2157** 资源检查及差异检查通过。

`PENDING_USER_VALIDATION`：在 Mac 上运行 `swift test --package-path apple` 和项目既定
macOS 回归/打包流程，检查菜单、取消/确认、两种结果提示与英中显示；真实行为仅在专用
可丢弃任务上验证，分别检查任务消失与目标目录中的未完成文件，不能只看任务列表就声称
文件移动成功。回传只含系统/套件版本、动作、脱敏错误及实际结果，不含任务名、URL、
路径或凭据。此验证缺口不阻塞其余独立 Windows 实施，但整个对齐目标仍未完成。

#### 下载任务文件创建选项波次

基线：macOS `ServiceManagementView` 的任务文件创建器以及共享仓储 multipart 创建，支持
torrent/nzb/txt、指定保存目录和解压密码。Windows 原路径选择文件后立即发送，缺少这两个
选项。本波单一修改范围为现有文件创建 Domain/传输/仓储、创建 ViewModel 与原生选项
弹窗、双语资源和回归；目录浏览复用已有文件夹来源，不新建 API 管线。

官方指南中 destination 自 Task v2 可用；当前 Windows 和 Apple 文件创建 helper 均固定
v1 携带 destination，属于已授权的同类版本映射问题。按参数选择最低已记录版本：不指定
目录保持 v1，指定目录固定 v2；能力不足时零提交，不能默默忽略所选目录。解压密码仅在
内存和 multipart 正文中使用，不进 URL、日志、ToString 或恢复记录。File 部分仍为最后
一个 multipart 部分，沿用原单次提交及未知结果回读。真实 NAS/系统选择器/解压结果后置
`PENDING_USER_VALIDATION`；本波不把任务创建成功等同于解压成功，其他剩余目标保持不变。

实际接线：选择本机任务文件后进入原生选项弹窗，提供默认位置或复用已有文件夹来源选择
可写 NAS 目录，以及可选的遮蔽密码输入。读取中/浏览未完成时不能创建；确认后清空密码
框并禁止重复点击，取消/关闭也清空。`DownloadTaskFileCreateRequest` 追加兼容可选密码，
保留脱敏 ToString；密码不进入创建恢复键、状态模型、URL 或日志。默认选项不再把旧缓存
目录强行作为显式参数发送；用户不指定目录时由 NAS 当前默认设置决定。

Windows 传输按 destination 是否存在选择 Task v1/v2，仍固定方法版本、不使用最大版本；
能力不足在传输前拒绝。复用既有安全 URL 解析器处理相对路径，避免双 webapi 前缀，保留
原会话/证书上下文。Apple 共享 multipart helper 在授权范围内同步修正版本与密码空白
保留，私有函数改用不误导的名称；保持旧公开接口。Apple 既有临时 multipart 文件仍按
0600 权限及调用结束清理，改为创建时设置权限；不宣称 Apple 上传正文完全不落盘。

同次全量回归再次复现图片预览的间歇性元数据/产物缺失。独立阅读确认 `Progress<T>` 的
异步回调可能用旧快照覆盖 Ready；已在 `FilePreviewViewModel.LoadArtifactAsync` 的进度
与最终快照交接处串行化，并在结束后关闭进度更新。正式回归用可控进度队列验证晚到
进度不能改变已就绪快照，不以增加等待或跳过原断言隐藏问题。

五端影响：Windows 文件创建新增兼容选项，Apple 网络层修正同类映射而不改变公共签名，
Mac 测试补充 v2 与密码空白检查；Android 和移动 App 源码未修改。没有新依赖、工具链、
身份、权限范围或持久格式。普通链接创建选项及下载模块其余差距仍需按基线继续核对。

实际验证：下载与文件预览聚焦 **216 通过**；全量 **1800 通过、1 失败、0 跳过（共 1801）**，
剩余为本机符号链接权限，未更改权限或跳过。命令为现有
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~FilePreviewViewModelTests|FullyQualifiedName~Download' -v minimal`
及去掉 filter 的同一全量命令。原生脚本
`./windows/tests/UiSmoke/run.ps1 -Scenarios download-file-options,downloads -WindowWidth 900 -PaneState compact`
覆盖遮蔽密码、清空、防重复、目录选择/空态、旧版本及浅深色和整页。`swift test --package-path apple`
已尝试，但因本机没有 Swift 无法运行，不作为 Mac 回归通过；新 Mac 构建与临时文件实际
权限/清理仍需 Mac 验证。NAS 专用任务验收需检查所选目录、包含空格的解压密码、失败/
断线不重复创建、正文顺序及实际解压结果；只回传版本与脱敏错误，禁止回传密码或原始请求。

最终原生 10 场景通过，人工复核遮蔽密码与正确文件创建标题的浅深色截图；本地化
Apple 4026 / Android 2188 / Windows 2186、96 请求 fixture、3 响应/22 私有引用及
严格文档/差异检查通过。既有 `windows/package.ps1` 在非交互、both、独立测试后不重复
测试、禁止自动启动配置下，成功生成并校验 SHA-256：
`windows/dist/20260916-181536/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-181536/LanStash-0.1.0-arm64.zip`。未安装/启动正式包、未提交/推送。
本波 `windows/dist/ui-review-20260916-180819`、`windows/dist/ui-review-20260916-181404`
及复用的 `ui-smoke-x64` 仍受之前的清理策略限制而待清理，仅为虚构测试数据，不提交。
下一切片继续核对普通链接创建与其他模块，完整目标未完成。

#### 普通链接创建目录波次

复用已完成的创建选项/目录来源，为普通链接创建增加独立的保存目录选择；默认不使用
过期的摘要目录覆盖 NAS 默认位置。指定 destination 时固定 Task v2，能力不足零提交。
当前共有 synthetic-link fixture 的 v1+destination 与官方字段版本不符，本波作为独立
契约纠正同步 fixture、Windows/Apple 适配和五端影响记录。Android 代码未获额外授权，
仅记录它引用此 fixture 的测试/版本选择需要后续复核，不将 Windows 通过外推为 Android
通过。URL 清单、多任务关联和其他模块仍须按原目标继续核对，不冒充全部完成。

Windows 的普通链接弹窗已嵌入既有 `DownloadCreateOptionsDialogContent`，隐藏不适用的
文件名/解压密码字段，保留相同的目录浏览与默认位置逻辑；URI 非空且目录浏览结束才可
提交，默认按钮为取消。提交后锁定输入、防重复点击，关闭后清空链接。创建 ViewModel
增加兼容重载，默认不显式发送缓存目录；仓储针对 destination 固定选择 v1/v2，并保留
既有创建回读和未知结果保护。Apple 普通直接创建与结构化创建均同步选择目录所需版本，
其他任务读取/控制仍为 v1；公共签名未改变，Android 源码未改。

契约影响已确认：共有 `download-station/create/synthetic-link/request.json` 因包含
destination 而修正为 v2。Android `DownloadCreationResultTest` 对应测试仍构造 Task
min=max=1 并引用此 fixture，静态上与修正契约不一致；该平台测试/适配需授权后同步，
当前未运行 Android JVM/云端，不声称 Android 门禁通过。iPhone/iPad 共享 Apple 适配，
当前 Windows 无法执行 Swift，仍需 Mac 上完整共享包和移动范围回归。回滚无需数据迁移，
不能恢复将目录参数按错误版本发送的行为。

实际验证（既有 .NET 10.0.401 与 bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~Download -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios downloads,download-file-options -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git diff --check
```

下载相关专项 **194 通过**，全量 **1803 通过、1 失败、0 跳过（共 1804）**，唯一剩余
失败仍为本机符号链接权限。原生 **12 场景**通过，包括实际普通链接页面入口、空输入
不可提交、隐藏密码字段及文件创建组件回归。资源 Apple 4026 / Android 2188 / Windows
2186、本地化、96 请求 fixture、3 响应/22 私有引用、文档与差异门通过。
`swift test --package-path apple` 因缺少 Swift 命令无法运行；真实 NAS 创建目录、权限、
断线恢复和结果归属，以及 Mac 构建仍为 `PENDING_USER_VALIDATION`。未执行真实 NAS 写。

使用现有 `windows/package.ps1`，设置非交互、both、独立测试后不重复测试、不自动启动；
最终 x64/ARM64 Release 自包含发布与 SHA-256 核对通过：
`windows/dist/20260916-183027/LanStash-0.1.0-x64.zip` 和
`windows/dist/20260916-183027/LanStash-0.1.0-arm64.zip`。未安装/启动包、未提交/推送。
本波 `windows/dist/ui-review-20260916-182648` 及复用合成宿主仍待此前策略允许后清理，
只有虚构测试数据，不提交。下一切片继续 NAS 管理对账；Android 契约影响仍待单独同步，
其余完整目标保持未完成。

### 2026-09-16 NAS 终端与代理：读取契约和编辑安全状态

本切片先修复已确认的契约偏差，不把全局写开关打开当作功能迁移完成。
macOS 证据为 `DsmNasAdministrationRepository+Services.swift` 的终端/代理读取及
`DsmNasAdministrationRepository.swift` 的对应提交、逐字段回读；契约为
`dsm-terminal-settings.md`、`dsm-proxy-settings.md`。Windows 原来猜测 `load` 方法、
代理 `server/port` 字段，并在能力缺失或读取失败时返回关闭状态；编辑器还把结果未知
当作已保存，并对所有设置误用文件服务权限。

唯一修改范围：Windows 两个服务设置 partial、必要只读帮助方法、严格读取门内这两项
无业务参数 get 的 JSON 声明支持（保持原有表单封装和同源安全）、现有通用编辑器及其
回归测试/双语提示，以及本账本和相关端点、兼容/进度记录。Windows 等价语义是固定已知
版本读取真实开关/地址/端口，失败可重试而不虚构关闭；编辑状态按本功能权限判断，提交
结果未知不能自动重放或显示成功。现有 WinUI 对话框模式不改为网页，也不新增平行编辑器。
只读本身为低风险，未来终端/代理写为 critical/high，生产门继续关闭。当前为源码核对，
自动化与构建待本波完成后记录；真实 NAS 为 `PENDING_USER_VALIDATION`。

非本切片目标：尚未接线的具体编辑表单、网络/账号/电源及其他管理功能（仍保留在完整
目标中）；不进行真实 NAS 写操作，不改变公开数据结构、持久化、依赖或身份。Apple 此处
读取已使用正确字段和必需开关检查，无同类错误证据不作无关修改；Android/iPhone/iPad
契约不变。保存调用链的基线绑定、逐字段回读和具体确认表单继续作为后续切片，不宣称完成。

#### 本切片实现与验证结果

读取现在使用严格对象响应、终端 v1-v3 交集最高版本和代理固定 v1，仅调用 get；代理使用
`http_host/http_port`，必需开关缺失或权限/版本/响应失败均抛出错误。无效可选端口不
伪造默认端口，Telnet 端口不属于已记录契约；FORM/JSON 无参数读取走相同表单封装。
两个保存方法明确返回 Unsupported，移除错误字段和空回读的潜在写路径，不改变生产
关闭状态。通用编辑器按设置类型检查能力；加载失败清掉旧草稿，提交中拒绝重复保存/
修改，部分或未知结果要求重新读取，不能显示成功，切换设备拒绝迟到结果。

独立只读集成/对抗复核覆盖：JSON 例外只限无参数 get 和已知版本、跨 profile 会话仍
拒绝、未知格式零请求、错误 103 不探测 load、权限拒绝不返回关闭、重复保存与失败回读
不重放旧草稿。未扩大认证/证书、危险写或未知版本门。修正了测试编译时的枚举拼写与
内插 JSON 构造错误；最初 JSON 读取被既有 FORM 门拒绝，随后仅为本契约的无参数读取
增加窄例外，保留原有其他 JSON 拒绝测试，没有降低断言。

实际运行（既有 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

专项 **142 通过**；全量 **1842 通过、1 失败、0 跳过（共 1843）**，仍仅
`BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 缺少本机符号链接
权限，未跳过或修改系统权限。x64/ARM64 WinUI Release 构建均为 0 警告/0 错误。
本地化资源 Apple 4026 / Android 2188 / Windows 2187、96 请求 fixture、3 响应/22
私有引用、严格文档和差异门通过。本切片新增 39 项测试，无真实 NAS 访问、无新 UI
表单，未运行原生交互烟测、不生成新独立测试包；此前包不包含本切片。

当前工作区继续保留此前未提交改动，本切片未提交/推送、未改 Apple/Android，无新增
一次性调试文件。macOS 对应读取经源码核对无同类缺陷，不额外修改共享包，也未运行
Swift/macOS 构建。下一切片为 NAS 设置实际表单、基线绑定和逐字段回读；电源/其他
设置结果提示也仍需核对，所有其他差距保留在完整目标内，不将当前关闭入口计作完成。

### 2026-09-16 NAS 服务设置原生表单接线

上一切片确有源码/自动化进展；本切片继续补实际用户入口。macOS 证据沿用终端/代理
设置加载、表单和保存结果；Windows 页面现有 ShowEditDialogAsync 仅创建空面板且
没有调用方，不能算迁移。唯一范围是 NasDetailsPage 的设置菜单、生命周期与新的
终端/代理原生表单控件、既有通用编辑器的最小接线、双语资源、正式测试及账本。
不新增公开接口、依赖或存储。表单以 WinUI ToggleSwitch/TextBox（端口使用数字输入提示）代替
macOS 控件，保留只读、加载、错误、正常、结果未知状态；不适用列表筛选空态。

用户主流程为打开终端/代理 → 读取实际值 → 能力允许才编辑 → 校验并确认风险 →
提交 → 确认成功或重新读取核对；所有生产写能力仍保持关闭，具体提交与逐字段回读
实现未完成不得计作可写。合成 Repository 用于验证交互，不作为生产启用依据。
终端为 critical、代理为 high；未知 build 和未验证写行为仍需后续专用 NAS 验收。
不修改 Apple/Android 源码，不使用真实 NAS 探测；其余管理功能保留在完整目标中。

同波原生验证发现资源读取的跨模块缺陷：原始属性键（如 `FileMoveUndoButton.Text`）
直接送入 ResourceLoader 会产生找不到 NamedResource，静态双语检查不能发现它。
按[微软 MRT 资源说明](https://learn.microsoft.com/en-us/windows/uwp/app-resources/localize-strings-ui-manifest)
在既有 WinUiLocalizationPlatform 边界将点分键转换为 PRI 路径，不修改调用方资源标识、
持久化或资源文件格式。范围只增加此资源边界和原生回归；旧文件撤销、旧照片列表及
DDNS 删除调用均受益，不以吞异常或返回键名掩盖缺失翻译。

#### 原生表单与资源修复验证

实际新增服务设置菜单和终端/代理表单，删除了无调用方的空通用弹窗。有效修改加显式
风险勾选才可提交；修改输入撤销确认，无效端口不钳制或取旧值，代理停用只改变开关。
重新读取清掉旧基线，保存结果在同一弹窗显示；未知/部分结果不显示成功，不重复提交。
普通离页、切换设置 Repository 和销毁均关闭弹窗并取消加载，不销毁 Shell 的缓存页面。
打开前核对当前 profile，弹窗显式跟随主题。实际生产保存仍为 Unsupported，不宣称
完整安全写链已经实现；只有合成 Repository 用来验证交互状态。

原生测试先后发现并修正 StackPanel 不能整体设置 IsEnabled、属性资源键导致弹窗
构造失败、深色未继承问题；输入烟测等待 TextChanged 分发后再点击确认，未修改断言。
最终原生 **16 场景通过**，使用实际页面入口，覆盖浅深色、只读、缺失端口、加载、错误、
确认成功、结果未知后只读核对及无效输入；每场景还用实际 PRI 读取 7 个既有属性资源键。
查看最终深色和未知结果合成截图，表单、提示和按钮未截断，主题正确。没有运行 Narrator
或真实 NAS，不把合成 Repository 保存计为实际 NAS 写入成功。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasAdmin -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-service-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

NAS 专项 **118 通过**，全量 **1863 通过、1 失败、0 跳过（共 1864）**；唯一失败仍是
本机符号链接权限，不静默跳过。ARM64 Release 0 警告/0 错误；原生合成宿主 x64 发布
成功。Apple 4026 / Android 2188 / Windows 2217 双语与硬编码扫描、96 请求 fixture、
3 响应/22 私有引用、严格文档和差异门通过。仅 Windows 有源码变动，无 Apple/Android
接口或存储变化，本波未运行 Swift/macOS 回归，不改变五端契约和真实证据等级。

`PENDING_USER_VALIDATION`：在现有用户环境打开“NAS → 服务设置 → 远程终端/互联网
代理”，核对只读实际值、重读失败提示与深浅色/键盘/Narrator。预期未开放的写入口
不可提交；不得为了验证在真实 NAS 启停终端或代理。只回传操作、版本类别和脱敏错误，
不回传代理地址、账号或原始响应。后续继续生产设置写入的基线绑定、重复提交保护和
逐字段回读，再推进其他 NAS 管理；完整目标保持未完成。

当前保留既有脏工作区，未提交/推送。合成截图 `windows/dist/ui-review-20260916-190328`
为本次最终原生证据；同波较早合成目录和复用宿主仍受先前清理策略限制，未再尝试绕过
删除，均为忽略的合成数据，不进入源码提交。

本波最终通过既有 `windows/package.ps1` 生成 x64/ARM64 Release 自包含测试包，环境
参数为非交互、both、独立测试后不重复执行、禁止自动启动。两包 SHA-256 核对一致：
`windows/dist/20260916-190503/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-190503/LanStash-0.1.0-arm64.zip`。未安装或启动最终包，不改变
身份、数据格式或签名策略；上述全量权限失败仍保留，不因打包成功变为全量通过。

### 2026-09-16 NAS 服务设置安全提交链

本波沿用已批准的向后兼容 Windows Domain/Repository 扩展，不改变网络契约、持久化、
依赖或身份。单一修改范围为服务设置保存请求/可选接口、现有 Repository 的终端/代理
保存核心及版本门、通用编辑器的固定请求接线、已有原生表单和对应测试/文档。
macOS 证据与两项内部端点/fixture 同前；实现原值预检、明确风险确认、同请求不重发、
固定版本/字段编码、逐字段回读、未知结果只核对，以及页面重开后的未确认请求恢复。

生产行为验收开关与已知 DSM 版本门分离，仍只读；内部核心由合成 HTTP 回归直接测试，
不提供用户可切换的绕过开关，不把核心合成通过写成真实 NAS 已验收。无基线的旧保存
签名继续返回不支持。全局旧 NAS 写门不会启用；其他管理动作不借本波开放。真实环境
缺口按 `PENDING_USER_VALIDATION` 保留，不阻塞后续独立设置切片。

#### 保存核心实际结果与五端影响

新增 `NasServiceSettingsSaveRequest<T>` 与可选 prepare/review/保存重载；旧实现默认
不支持新保存、无挂起记录，旧无基线保存签名仍关闭。表单复用现有通用编辑器，把加载
原值、当前草稿、固定 Guid 和已确认风险交给新重载；不绕过 Domain 接口调用具体类。
生产行为开关是独立关闭门，不随旧 NAS 总门开启；已记录 DSM 7.2.1/69057/Update 12
版本判断独立执行，未知环境不提交。版本摘要只保存匹配布尔值，不保留原始响应。

内部核心复用当前 API 客户端和固定只读传输；按终端 v1-v3 交集及代理 v1 固定版本/
路径/编码，先读取权限可见的原值，冲突不覆盖。终端完整提交真实开关与可用 SSH 端口，
代理停用只提交 enable，启用时提交正确 http_host/http_port。确认状态由实际变化字段
回读计数；缺失回读字段保留 unknown，而不是伪装失败/成功；明确 NAS 权限拒绝与
HTTP 403、响应丢失严格区分，外部客户端改变设置也不能将被拒绝的本次操作计作成功。

同 API 客户端下用会话外的 profile/账号/连接摘要哈希隔离记录，同请求 ID 终态不重发；
原值或目标变化、跨账号重用、并发保存以及同设置未确认的新请求都不提交。未确认记录
只驻留内存，保留固定能力和目标字段，不保留 Repository、会话凭据或原始响应。页面/
Repository 重建后通过只读 review 恢复；进程重启或换 API 客户端不承诺恢复旧请求记录，
新的保存仍必须加载原值并再次明确确认。没有新增磁盘存储，也没有引入可由用户打开的
测试绕过开关。合成测试直接执行同一内部核心，不代表生产入口已开启。

独立只读集成/对抗复核补了以下证据：跨 Repository 并发仅一个 set、fixture 字段/版本
完全匹配、未确认新请求零写拒绝、未知响应可通过回读确认、部分匹配和缺失端口准确计数、
原值变化零写、无确认/无效输入/错误 profile 零请求、旧请求更换账号/草稿不重放、回读
期间取消保留记录、明确拒绝不误报“可能已保存”。UI 对明确权限/登录拒绝给出对应恢复
说明；pending 记录未确认时即使页面重开、读取字段成功也仍不可编辑。

实际命令（既有 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasAdmin -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-service-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

NAS 专项 **149 通过**；最终全量 **1894 通过、1 失败、0 跳过（共 1895）**，唯一失败
仍是 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 的本机符号
链接权限，未跳过。原生 **20 场景通过**（最终合成目录 `windows/dist/ui-review-20260916-192437`），
追加了重开页面 pending 保护和核对后恢复，不使用真实 NAS。ARM64 Release 构建 0
警告/0 错误，最终 x64 合成宿主发布通过；资源 Apple 4026 / Android 2188 / Windows
2219、本地化、96 请求 fixture、3 响应/22 私有引用、严格文档和差异检查通过。

五端影响：Windows C# 接口是已批准的兼容增量，网络字段/fixture/结果公共契约不变；
macOS、iPhone、iPad 和 Android 源码未改、不需要迁移持久数据，也未在本波执行其平台
构建。未提高 observed 证据等级。回滚可关闭/移除新接口接线，不恢复猜测字段或空回读。
保留全部既有脏工作区，未提交/推送；没有新的抓包或真实用户数据。合成目录与复用宿主
仍按既有清理限制保留且被忽略，不绕过被拒绝的删除策略。

`PENDING_USER_VALIDATION`：先由用户明确专用 NAS 环境与可恢复原值，再为相应测试
构建决定行为门，不使用当前只读便携包或生产 NAS 猜测写入。需逐项验证保存、明确拒绝、
断线/取消、原值冲突、回读、关闭重开与恢复原值；只回传版本类别、可见结果和脱敏错误。
当前源码/合成闭环不等于实机验收或正式可写发布。下一独立切片继续文件服务的分 API
读取/表单/安全提交及其他 NAS 管理，完整对齐目标仍未完成。

本波使用原 `windows/package.ps1`、非交互/both/独立测试后不重跑/不自动启动选项，
完成最终 x64 与 ARM64 Release 自包含发布，两包 SHA-256 匹配：
`windows/dist/20260916-192707/LanStash-0.1.0-x64.zip` 和
`windows/dist/20260916-192707/LanStash-0.1.0-arm64.zip`。未安装或启动最终包，
没有变更签名、权限、标识、依赖和存储；原有符号链接权限失败仍如实保留。

### 2026-09-16 文件服务分组契约与原生入口

本波核对发现 Windows 仍调用未记录的单一 `SYNO.Core.FileServ`，猜测嵌套字段与
get/load，并把所有失败变成关闭；macOS 的 `DsmNasAdministrationRepository+Services.swift`
以及 `dsm-file-service-settings.md` 实际使用 SMB、NFS、FTP、SFTP、Web.DSM 和
ServiceDiscovery 六组。当前负责人独占文件服务 Domain 增量、对应 Repository、
既有设置弹窗接线/新文件服务表单、双语资源和测试/文档；不修改其他平台源码。

采用兼容增量的字段可用/失败位图与独立 FTPS 开关，保留旧布尔字段和 CloneWith 签名，
但新控件必须先检查字段可用性，不将未知当成关闭。读取固定已记录版本、get 方法和字段，
按组独立降级；取消传播，无可用 API 为不可用。表单保持 WinUI 习惯，未知控件不显示，
部分失败可重新读取。保存仍须六组整体预检、基线绑定、端口/SMB 依赖、按组结果核对，
未实现或未验证时不以总开关解锁。此波先形成分组读取与实际入口，再继续同一完整目标的
多组安全写闭环；真实 NAS 为 `PENDING_USER_VALIDATION`，不扩大为真实写探测。

#### 文件服务读取与原生入口验证

六组读取现已固定 SMB/NFS v1-v3、FTP/SFTP/ServiceDiscovery v1、Web.DSM v2；只调用
get，不探测聚合接口或 load。新增不可变位图 AvailableFields/FailedFields 和独立
FtpsEnabled，原有布尔、可选高级属性及 CloneWith 方法签名保持；CloneWith 保留位图
和 FTPS 值。无返回的高级设置不猜测，未报告端口不显示，报告了无效端口则标记失败；
仅使用已有 sftp_portnum 读取别名。单组权限/结构/网络失败只标记自身，认证失效与用户
取消传播；无任一文件服务 API 时明确不可用，不返回全关闭。

新增文件服务菜单及原生只读字段表单；与终端/代理复用既有弹窗生命周期，不新建平行
弹窗控制流程。控件先检查字段位图，部分失败、空能力、整体失败和正常内容分别提示，
可重新读取；缺失/旧无元数据模型不显示猜测关闭。保存按钮不可用且只读内容不调用保存，
原错误聚合写参数和空回读路径已移除。多组安全写尚未接线，不把本波页面当成完成写入。

独立集成/对抗复核确认：无参数 JSON 例外仅扩展这六组记录版本，写方法/带业务参数
未放开；Web.DSM v1 不被误用、旧聚合 API 永不请求、FTPS 不当作 SSL-only、失败状态
不覆盖可用字段，CloneWith 不丢位图，认证取消不静默降级为关闭。原生截图发现 FTP
端口被同排内容拉伸，已改顶部对齐并补高度断言；最终深色截图中字段与按钮未截断。
首次编译遇到 C# 14 属性内 field 关键字冲突，改用普通 lambda 参数名后通过，未改工具链。

实际验证命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-service-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **210 通过**；最终全量 **1910 通过、1 失败、0 跳过（共 1911）**，唯一失败仍是
本机缺少符号链接权限的既有测试，未跳过/改断言。两架构 WinUI Release 构建分别通过，
最终原生 **30 场景通过**，包括原 20 个终端/代理回归及 10 个文件服务浅深色/部分失败/
错误/不可用/旧空模型/加载/恢复场景；最后合成目录为 `windows/dist/ui-review-20260916-194309`。
资源 Apple 4026 / Android 2188 / Windows 2258，本地化、96 请求 fixture、3 响应/22
私有引用、严格文档和差异门通过。未执行真实 NAS 或系统辅助功能验收。

五端影响仅为 Windows C# 的兼容元数据增量与读取接线，网络字段/fixture 不变，Apple
与 Android 源码未改，也未运行其构建；不提高 observed 证据等级，不需存储迁移。当前
脏工作区保留原有修改，未提交/推送。新产物均为合成数据与构建输出；较早合成目录及
复用宿主仍按既有清理限制保留，不绕过此前删除拒绝，不进入源码提交。

`PENDING_USER_VALIDATION`：在已具备权限的 NAS 打开“服务设置 → 文件服务”，核对
实际协议开关/端口和部分失败提示；未知字段不应显示为关闭，重新读取应恢复可用字段，
保存不可用，不启停真实服务。需回传系统/DSM 版本类别、操作、预期/实际与脱敏失败
类别，不包含账号、地址、共享路径或原始响应。下一切片继续六组整体预检、输入依赖、
基线绑定、按变化组提交和整体回读；其他 NAS 管理与完整对齐目标仍保留，未宣称完成。

最终仍通过既有 `windows/package.ps1`，使用非交互/both/独立测试后不重复测试/不自动
启动，完成两架构 Release 自包含发布；两包 SHA-256 校验一致：
`windows/dist/20260916-194608/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-194608/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不改变当前身份/签名/存储；本机符号链接测试失败未因打包成功而被忽略。

### 2026-09-16 文件服务六组安全保存

本波继续已建立的文件服务读取/表单，补完整确认保存而不是开启旧总门。单一范围为
文件服务规则、新保存重载、现有 NAS 写协调器的共用记录、六组提交/整体回读、当前
表单编辑/确认和正式回归。macOS 证据为 DsmNasAdministrationRepository 的
saveFileServiceSettingsResult、validateFileServiceSettings 与按组 mutation steps，
契约沿用 dsm-file-service-settings.md 和六份 fixture；不新增网络参数或版本。
Domain 仅作已批准的兼容扩展，旧签名继续不支持无基线写，不改变持久化或依赖。

安全要求：所有变化组能力/版本在首个 set 前固定，完整原值预检；未知字段不写，
FTP/FTPS 与 SFTP 端口及 SMB/Time Machine 依赖校验；每组至多一次，断线/拒绝/取消
停止后续组并整体回读，同请求只能核对。复用终端/代理协调器隔离账号并阻止并发，不
另设平行提交队列。生产行为门继续关闭；只用合成 HTTP 和原生宿主验证，真实 NAS
高风险行为保留 PENDING_USER_VALIDATION，不阻塞其他独立模块。

#### 六组保存实际结果与验证

文件服务新保存重载接收原值、目标值、profile、请求 ID 与风险确认；复用既有 NAS
协调器和只读恢复入口，共用终端/代理的并发门与账号隔离记录。协调器记录抽取为共同
基类，单组/多组结果保持各自类型，不新建平行队列。终端、代理、文件服务的生产行为
验收开关分别关闭，不能因一个功能验收完成而顺带打开其他功能；旧无基线签名仍不支持。

Domain 规则拒绝字段位图伪造、未知/未记录字段修改、无效端口、启用服务端口冲突及
SMB/Time Machine 依赖错误。首个 set 前已完成所有变化组的版本/能力固定和完整原值
读取；不需要变化的组不发送 set。同组仅一次，未返回可选端口不猜测或发送；发生拒绝、
超时、丢响应或取消立即停止后续组，整体读取后按变化组计数。未发送的后续组不自动
继续；同请求 ID 终态不重放，未知记录在同客户端重建页面/Repository 后只读核对。

原生表单已接编辑、共享输入规则、风险确认和新重载；修改输入撤销确认，部分/未知
结果不能直接再次保存。已知确认/部分结果后按 macOS NasAdministrationModel.saveFileServices
的模式更新实际设置并保留反馈，避免将未生效草稿冒充当前值。截图与断言验证了 SFTP
草稿 2223 未生效时显示实际 2222；未知结果仍由受保护的重新读取入口核对。提交前冲突
明确提示本次未保存，不再错误使用“可能已保存”；缺失保存能力也给出恢复说明。

独立集成/只读对抗复核覆盖：六份 fixture 的完整字段/版本、只提交变化组、后续能力缺失
零请求、原值变化零写、所有输入/依赖门、第三组丢响应停止后续组、整体回读部分成功、
单组读取失败保留 unknown、明确权限拒绝、取消、跨 Repository/账号及终端并发、
同请求不重放、未报告端口不发送。第一次 fixture 回归发现合成期望 Bonjour 值与共享
fixture 不同，修正测试输入为 fixture 的 false（同组仍由 SSDP 变化触发），未改契约或
降低断言。所有运行都为合成 HTTP/本机原生宿主，没有真实 NAS 写入。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-service-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

最终聚焦 **225 通过**；全量 **1925 通过、1 失败、0 跳过（共 1926）**，唯一失败仍为
缺少符号链接权限的既有用例，未跳过。原生 **36 场景通过**，其中追加的保存、部分/
未知、冲突端口与 pending 场景均通过；实际值刷新修复后的目录为
`windows/dist/ui-review-20260916-201648`。随后新增的“未提交需要重读”文案由专项单测/
本地化覆盖，不冒充该场景已运行原生烟测。两架构 Release 构建通过；资源 Apple 4026 /
Android 2188 / Windows 2262、本地化、96 请求 fixture、3 响应/22 私有引用、文档和
差异门通过。中间包 `windows/dist/20260916-201324` 不含后续实际值/反馈修复，不作为
最终交付。旧合成目录和中间包继续按先前清理策略限制保留，不绕过删除拒绝，不提交。

五端网络契约不变；仅 Windows C# 接口/规则为已批准的兼容增量，枚举追加 FileServices，
没有持久化、依赖或身份改变。Apple/Android 源码未改、构建未在本波运行，不提升真实
环境 observed 证据等级。当前脏工作区保留所有此前修改，未 add/commit/push。

PENDING_USER_VALIDATION：专用 NAS 获明确授权并安排可恢复原值后，才决定对应测试构建
的单项行为门；需验证六组、活跃客户端、端口冲突、SMB/Time Machine、断线/取消、
部分结果及恢复原值。当前生产门继续关闭，不能用当前便携包试写真实服务。仅回传版本
类别、步骤、预期/实际与脱敏错误，不包含地址/账号/路径或原始响应。源码/合成闭环不
等于真实可写发布，其他 NAS 管理及完整 macOS 对齐目标仍未完成，下一项继续其余设置/
账号/计划任务等实际差距。

最终采用原 `windows/package.ps1` 和非交互/both/不重复测试/不自动启动选项完成
x64、ARM64 Release 自包含发布，两个 SHA-256 均核对一致：
`windows/dist/20260916-202243/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-202243/LanStash-0.1.0-arm64.zip`。该包包含实际值刷新及未提交
反馈修复，未安装或启动，未修改签名/身份/存储，不将打包通过代替那项权限失败。

### 2026-09-16 区域与时间读取契约

Windows 当前使用未记录的 Region/NTP 聚合与 get/load、错误字段并吞掉失败；实际契约
是 SYNO.Core.Region.NTP 的 get v3 / listzone v1。macOS 读取实现还将未知 enable_ntp
当成 manual，并把缺失时分秒补零；按用户对同类缺陷的授权，本波一并修复这两项及
无效数值不能安全转换为时间的问题。唯一范围是区域读取、兼容元数据、原生只读入口、
Mac 对应读取与测试、双语和文档，不修改真实 NAS 时间、账号、证书或任务。

依赖既有 dsm-region-time-settings.md；Windows 追加模式/时区选项/NAS 墙上时间，
旧构造签名不变，克隆保留元数据。读取必须确认格式/模式及当前时区在 listzone 内，
缺失/非法时间不补设备时间或午夜；保留 NAS 原始墙上时间，不猜测 Windows 时区标识。
高风险 set/sync 仍关闭并在后续独立保存切片实现，不能把只读页面计作完整改时闭环。
Apple 共享包兼容修复需 Mac 回归，本机缺少 Swift 的验收继续 PENDING_USER_VALIDATION。

#### 区域读取与同类 Mac 修复验证

Windows 已固定 SYNO.Core.Region.NTP get v3 / listzone v1，校验必需格式、明确模式和
当前时区成员；不再使用 Region、Core.NTP、load、ntp_servers 等猜测链。模式枚举包含
Unknown，失败不构造手动模式；时区来自 NAS 列表而非 Windows 标识，NAS 时间按完整
年月日/时分秒构造 Kind.Unspecified，不补本机时间或午夜。原有构造签名保持，追加
模式、时区列表、墙上时间，克隆复制只读集合和新字段。

区域原生只读内容复用设置弹窗，提供格式示例、时区、模式、服务器和“读取时 NAS 时间”；
示例不是当前时间，未识别格式显示其他格式并保留原始值。缺失时钟单独提示，未知模式/
失败不显示假配置；刷新不触发 set/sync，保存入口仍关闭。

依照用户对同类 Mac 缺陷的授权，共享 Apple 读取现在拒绝未知模式、缺失当前时区、
空格式；保留既有布尔文本兼容表示。小时等值采用 Int(exactly:) 避免截断/溢出，缺字段
不补零，日期分量验证并回查，避免 Calendar 归一化非法日期。新增 Swift 用例覆盖未知
模式/时区、缺字段、小数、极大值、无效日期，以及用户未编辑时间且 NAS 时间缺失时
只允许 get/listzone、不发 set。此修改影响 macOS 和共享它的 iPhone/iPad 包；有效
请求契约/持久化不变，Android 源码未改，需后续复核同类读取边界。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-region-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

Windows 聚焦 **250 通过**，全量 **1950 通过、1 失败、0 跳过（共 1951）**，唯一失败
仍是本机符号链接权限，未跳过。原生 **8 场景通过**（最终格式示例版本目录
`windows/dist/ui-review-20260916-210327`），覆盖浅深色、网络/手动、缺时钟、错误、
不可用、加载和旧未知模式；验证不使用本机时间、不调用保存。ARM64 Release 0 警告/
0 错误，x64 合成发布通过；资源 Apple 4026 / Android 2188 / Windows 2274，本地化、
96 请求 fixture、3 响应/22 私有引用与文档/差异检查通过。

`swift test --package-path apple` 实际失败为找不到 swift 命令，没有执行任何新 Swift
用例或 macOS 构建；Windows 通过不能替代它。PENDING_USER_VALIDATION：需在 Mac
运行完整共享包及 macOS 回归，重点检查上述解码/零写用例和有效日期行为。实际 NAS
读取需核对模式、时区、格式和读取时钟，不在生产 NAS 改时或校时；只回传版本类别、
操作和脱敏错误，不回传真实服务器、账号、地址或原始响应。

独立集成/只读对抗复核检查了 get/listzone 固定版本、方法例外仅限该 API/v1/无参数、
sync 不能走只读通道、错误不回退旧方法、日期/时间无本机默认值，以及有效 Swift
Number 解码确为 Double 后才使用精确整数转换。未提高 observed 证据等级。工作区
保留所有前轮改动，未提交/推送；旧合成目录及中间包按先前清理限制保留、不进入提交。
中间包 `windows/dist/20260916-210110` 不含后续友好格式示例，不作为最终交付。
下一切片继续区域 set/sync 的分阶段保存与恢复，及其他 NAS 管理差距；完整目标未完成。

最终经原 windows/package.ps1 非交互/both/不重复测试/不自动启动流程完成两架构
Release 自包含包，并核对两个 SHA-256 一致：
`windows/dist/20260916-210505/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-210505/LanStash-0.1.0-arm64.zip`。未安装/启动最终包、
未提交/推送，未改变身份、签名、权限或存储；不代替 Mac 回归或真实 NAS 验收。

### 2026-09-16 区域配置与校时分阶段保存

继续区域读取/只读入口，按 dsm-region-time-settings.md 与两份 region fixture 实现
set v3 → 配置回读 → 必要时 sync v2 → 再回读。单一范围为区域保存请求/规则、既有 NAS
协调器扩展、区域编辑表单、测试与文档。沿用已批准的兼容 Domain/Repository 增量，
不改存储、身份或依赖；不触发真实 NAS 改时。Mac 对照为 saveRegionSettingsResult
及 regionMutationSteps，上一波 Mac 读取修复仍待 Swift/macOS 回归。

明确手动时间由独立可空字段表达；未编辑时从预检 NAS 新快照取值，绝不使用页面旧秒数
或设备当前时间。set 异常后即使配置可读也不自动继续 sync，sync 超时不能用配置匹配
冒充精度/接受验证；保留部分结果和不重发记录。区域行为门独立关闭，合成核心与原生
交互完成不等于真实可写验收。其余 NAS 管理差距继续保留在完整目标。

#### 区域分阶段保存实际结果

新增 NasRegionSettingsSaveRequest 与规范化/服务器规则，明确 EditedNasTime 独立于
读取快照。保存检查当前时区列表和配置原值，忽略自然走时造成的旧 clock 差异；未编辑
手动时间时使用本次预检 NAS 时间。仅格式变化不发 sync；模式/服务器变化且 set 明确
接受、配置完整匹配后才发一次 v2 sync，再次回读配置。服务器集合先复制，版本/路径
固定；未知配置只读核对，不因恢复而继续 sync。

区域操作复用 NAS 协调器/账号隔离记录，有独立关闭的行为门。sync 没有独立查询句柄，
失败/超时保留部分结果、同请求永不重发，但不永久锁住后续新基线下的独立配置修改。
“NAS 接受校时请求”不表述为时钟精度验证；明确拒绝、配置漂移、手动时间回读缺失及
取消各有对应结果。旧无基线保存签名不绕过新流程。

原生表单支持 NAS 时区选项、模式、服务器、常用格式及折叠的自定义格式。明确勾选
手动改时后必须自行选择日期和时间，默认均为空，不使用设备当前时间或页面旧时间；
统一风险确认和输入改变撤销确认。已知结果后更新 NAS 当前值并保留反馈，NAS 回读
时间在编辑/保存后均可见。原生测试最初操作了折叠区文本框，未触发可见主控件路径，
随后改用真实格式选项；集合按内容比较避免无变化草稿反复替换，去除了临时反射诊断。
测试脚本新增可选 States 筛选，默认完整矩阵不变，便于聚焦真实失败状态。

独立集成/只读对抗复核覆盖两份 fixture、get/listzone 在 set/sync 前后的精确顺序、
新旧手动时间区分、无 NAS 时间零写、非法服务器/格式/时区/模式/确认零写、配置
冲突、丢失 set 不继续 sync、配置未知的跨 Repository/账号恢复、sync 失败不重发、
校时后配置仍需核对、提交后取消、服务器集合快照及仅格式变化不校时。没有执行真实
NAS 写操作，也不修改本机时钟。旧 Mac 读取修复与其未执行回归继续保留，本波未另改
Apple/Android 源码，不增加网络契约或持久化。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-region-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **267 通过**，全量 **1967 通过、1 失败、0 跳过（共 1968）**，唯一失败仍为本机
符号链接权限，不跳过或降低断言。16 个区域原生场景覆盖原只读八态及保存、校时接受/
未知、无效输入和明确手动时间；两架构 Release 构建通过。资源 Apple 4026 / Android
2188 / Windows 2288、本地化、96 请求 fixture、3 响应/22 私有引用、严格文档与差异门
通过。Mac 新读取用例仍因当前环境没有 Swift 而未运行，不能由 Windows 结果代替。

PENDING_USER_VALIDATION：须专用可恢复 NAS 上另行授权对应测试构建的区域行为门，
核对格式、时区、未编辑/明确编辑的手动时间、网络校时、权限、断线、取消、会话/OTP/
证书/计划任务副作用及恢复原值；精度需要独立测量，不凭 sync 成功判定。只回传版本、
步骤和脱敏错误，不包含真实服务器、账号、地址或原始响应。生产行为门仍关闭，未做
真实改时。工作区保留前轮改动，未提交/推送；合成输出仍受先前清理限制且不进入提交。
区域源码/合成闭环不代表所有 NAS 管理或完整目标已完成，下一步继续其余实际差距。

本波最终原生目录为 `windows/dist/ui-review-20260916-214117`，包括保存后可见的
NAS 回读时间。原 windows/package.ps1 以非交互/both/不重复测试/不自动启动生成
两架构 Release 自包含包，SHA-256 均一致：
`windows/dist/20260916-214358/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-214358/LanStash-0.1.0-arm64.zip`。未安装或启动最终包，
未改身份/签名/存储，未提交或推送，不替代真实改时或 Mac 验收。

### 2026-09-16 物理网卡读取与原生入口

当前 Windows 直接解析列表并猜测 dhcp=true、id/name 等字段，未按 list v2 → 各
ifname get v1 读取；已核对 dsm-ethernet-settings.md 与 Mac Network/ethernetInterface
解码。此波负责人独占网络读取、兼容元数据/快照、传输的明确数组变体、原生只读入口
及测试/文档。默认网关、VLAN、MTU 缺失保留未知，部分网卡失败不能冒充完整空列表。
仅接受既有安全 eth 标识；不改网络、DNS、路由或本机/NAS 地址。

Domain/接口为已批准的兼容增量，旧列表与构造签名保留；写入需要后续单网卡 configs、
原值/权限/版本确认、连接变化恢复和完整回读，旧猜测 set 不保留可误启用路径。真实
网络变更高风险，生产门关闭并保留 PENDING_USER_VALIDATION。其他模块不因网卡失败
受阻，网络字段契约不变，不修改 Apple/Android 源码。

#### 网卡读取实际结果与验证

Windows 网络读取现在固定 list v2 → 安全 eth 标识逐项 get v1，详情使用 ifname 并按
FORM/JSON 编码。传输仅对已记录的网卡列表规整直接数组为 interfaces 对象，其他
接口仍严格拒绝数组；不放开写方法或未知容器。详情支持已有 ethernet_ 前缀、列表
字段回退及 mtu_config，拒绝不匹配目标或缺失 use_dhcp，不再猜测自动获取为 true。

新增兼容的 NasEthernetSnapshot 与可空默认网关/VLAN/状态/DNS 元数据。缺失或无效
MTU/VLAN 不补 1500/false；部分失败单独计数，旧仅列表入口遇到部分失败也不声称
完整。重复标识、非法容器失败，非物理网卡忽略，危险标识不发详情请求；认证/取消
传播。原猜测 set 参数与空回读路径已移除，无完整基线的新写流程前旧入口不支持。

原生只读内容复用设置弹窗，显示自动/静态方式、已报告的静态配置及 MTU/默认网关/
VLAN，未知值明确标注。自动获取不把保留的静态地址当成当前租约显示；可查看部分
结果并重新读取，空、错误、不可用、未知可选字段和恢复状态均覆盖。查看不提交网络
请求写操作，不改变真实 NAS 或本机网络。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-network-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **283 通过**；全量 **1983 通过、1 失败、0 跳过（共 1984）**，唯一失败仍为
本机符号链接权限，不跳过。原生 **9 场景通过**，目录
`windows/dist/ui-review-20260916-215609`；查看浅深色合成结果，地址只使用文档保留
网段，未放真实数据。ARM64 Release 与 x64 合成发布通过；资源 Apple 4026 / Android
2188 / Windows 2298、本地化、96 请求 fixture、3 响应/22 私有引用、文档/差异通过。

独立集成/只读对抗复核覆盖数组例外不会影响其他 API、JSON ifname 正确编码、稳定
目标匹配、安全标识过滤、字段未知保留、旧入口不误报完整、单接口失败独立降级和
认证取消传播。网络契约不变，Windows C# 增量向后兼容；Apple/Android 未改，本波未
运行其构建，先前 Mac 读取修复的回归缺口继续保留，不提升 observed 证据等级。

PENDING_USER_VALIDATION：在有读取权限的 NAS 打开服务设置中的物理网卡，核对实际
网卡/自动获取方式/静态设置/未知可选字段及部分失败恢复，不修改地址、默认路由、
MTU、VLAN 或 DNS。仅回传版本类别、步骤和脱敏错误，不回传实际地址/网卡数据或
原始响应。工作区保留此前改动，未提交/推送；合成输出按先前清理限制保留且不提交。
下一切片是单网卡 configs、完整原值/权限校验、重复保护和地址变化后的重连核对；
网络写与其余完整目标仍未完成。

最终经原 windows/package.ps1 的非交互/both/不重复测试/不自动启动流程生成两架构
Release 自包含测试包，并验证两个 SHA-256 匹配：
`windows/dist/20260916-215814/LanStash-0.1.0-x64.zip` 和
`windows/dist/20260916-215814/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不改变标识/签名/存储，不将打包通过代替那项本机权限失败或真实网络验收。

### 2026-09-16 单网卡配置与重连核对

继续已完成的列表/详情读取，按 dsm-ethernet-settings.md 及 set-ethernet fixture 补
单目标 configs v1。唯一范围为网络请求/规则、NAS 共用协调器、网络只读/编辑界面及
测试文档。原值必须完整，未报告 MTU/默认网关/VLAN 不可猜测后写；静态 IPv4、掩码、
网关、DNS 与 VLAN 进行校验，提交一次后按同 ifname 核对。网络行为门独立关闭。

地址变化恢复不自动访问候选地址，也不携带旧 SID 去新地址：仅使用用户已重新登录的
当前 Repository；地址变化时还需用户确认同一 NAS。内存只存原会话摘要哈希而非凭据。
恢复只能读取，不能重发；没有新权限、存储格式或依赖变化。当前是真实 NAS 未验证的
critical 写功能，源码/合成闭环不等于启用生产门。

#### 单网卡保存与恢复实际验证

网络保存新增基线请求、完整字段规则及独立行为门，使用同一 NAS 协调器固定请求/
目标，所有字段通过有序单项 configs 发送 v1 set；DHCP 不回写保留的静态字段，
VLAN 关闭不发送旧标识。校验安全 ifname、完整默认网关/VLAN/MTU、规范 IPv4、连续
掩码和 DNS，原值冲突或无变化不提交。回读使用同 ifname 的详情，不用旧列表补结果。
拒绝、取消、丢响应和不一致各有结果，未知状态不重发，也不允许绕过旧请求写另一网卡。

恢复记录仅保存身份/原会话摘要哈希、目标配置与能力，不持有旧 Repository 或凭据。
地址不变可以只读核对；地址变化后旧 SID 被拒绝用于网络读取/核对，必须使用用户重新
登录得到的新会话，并明确确认同一台 NAS。程序不自动发现新地址、不自动更新配置地址，
不把旧凭据转发到候选地址；仍复用现有认证/证书链。确认绑定当前连接与会话，回读
成功才清除挂起记录；进程重启/换 API 客户端不承诺恢复该内存记录。

原生列表可在能力允许时选择一张完整网卡编辑，缺失关键字段只读。编辑提供自动/
静态地址、掩码、网关、DNS、默认网关、MTU、VLAN 和风险确认；输入改变撤销确认。
未知结果锁定写入，提供重新登录与同 NAS 核对入口。已确认结果刷新实际列表，不展示
未生效草稿为当前配置。当前生产行为门仍关闭，所有可编辑/恢复操作只在合成宿主验证。

独立集成/只读对抗复核：共享 fixture 的 configs 单项内容完全匹配、FORM/JSON 编码、
原值/输入拒绝零写、只读时不产生写入、未知新请求与换账号冲突、取消与明确权限拒绝、
新地址旧会话零请求、新会话未确认零比较请求、确认后只发 get 且使用新会话，以及
缺失 MTU/默认网关/VLAN 不得猜测后写。没有真实网络修改，也没有改变持久化/身份/
依赖；Apple/Android 源码本波未改，旧 Mac 回归缺口仍保留，不提升 observed 证据。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-network-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **293 通过**，全量 **1993 通过、1 失败、0 跳过（共 1994）**，唯一失败仍为
本机符号链接权限，不跳过。原生 **16 场景通过**，目录
`windows/dist/ui-review-20260916-221947`，包括只读九态及保存、未知、无效/缺字段、
重连确认与旧会话保护；浅深色回读结果已查看。两架构 Release 构建通过；资源 Apple
4026 / Android 2188 / Windows 2318、本地化、96 请求 fixture、3 响应/22 私有引用、
文档与差异检查通过。所有地址来自合成保留域名/文档网段，未录入真实数据。

PENDING_USER_VALIDATION：需要专用可恢复网络、明确原值及回退通道后，才为指定测试
构建决定网络行为门。验收 DHCP/静态、默认路由、MTU、VLAN、权限、断线、同地址/
新地址登录、同 NAS 确认和恢复原值；仅回传版本类别、操作与脱敏失败，不回传地址、
网卡数据或原始响应。生产门仍关闭，源码/合成不等于真实网络可写验收。保留全部前轮
脏工作区，未提交/推送；旧合成输出按此前清理限制保留，不进入源码提交。其余 NAS
管理、系统集成及完整对齐目标仍未完成。

最终使用原 windows/package.ps1 的非交互/both/不重复测试/不自动启动流程，生成
x64/ARM64 Release 自包含包并核对 SHA-256 一致：
`windows/dist/20260916-222422/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-222422/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不改变签名/身份/存储，不代替真实网络变更验收及既有权限失败。

### 2026-09-16 安全防护读取与误报成功修复

本波核对 Security.swift 和 dsm-security-settings.md：Windows 自动封锁字段、DoS
结构/版本、防火墙与端口扫描来源均有偏差，旧保存还以 fire-and-forget 调用后直接
返回成功，未等待受关闭门限制的结果。唯一范围为安全设置兼容元数据、读取/旧保存、
严格读取中的已记录 DoS 变体、原生入口、双语和测试/文档；不改其他平台源码或真实防护。

按四个稳定分区读取：AutoBlock v1、DoS v2（网卡 configs）、Firewall v1、Firewall.Conf
v1；未知值不猜测，局部失败不阻断其他分区。旧保存不再误报成功，新安全写需要后续
多步预检/基线、任务轮询/清理和整体回读，未完成不得打开总门。当前风险 critical，
真实副作用保留 PENDING_USER_VALIDATION；此波先形成真实读取与状态入口。

#### 安全读取与假成功移除的验证

安全配置现在使用 AutoBlock v1 的 enable/attempts/within_mins/expire_day、DoS v2
网卡 configs、Firewall v1 的 enable_firewall/profile_name、Firewall.Conf v1 的
enable_port_check。不再从 DoS 猜测 port_scan，或从防火墙读取 enable。四分区独立
降级，认证和取消传播；某分区缺失不要求先存在 AutoBlock，旧聚合 Security 不启用能力。

新增可用/失败分区、按网卡 DoS 与防火墙配置档元数据，旧构造签名保持，克隆保留新
字段。DoS 支持直接数组/configs 容器、重复响应以后值为准；缺失目标状态不编造，混合
状态不压成单个布尔。封锁零天表示不过期，字段缺失不当零天。旧保存只返回不支持且
不发请求，彻底移除 fire-and-forget 后直接 ConfirmedSuccess 的误报路径；全目录复核
未发现另一个相同的无等待安全保存入口。其余未迁移的写仍不能靠旧总门启用。

原生只读安全页复用设置弹窗，展示已知分区与各网卡状态、部分失败恢复、不支持、错误
和加载；未知值不显示为关闭。独立集成/只读对抗复核覆盖固定版本、configs 参数、
DoS 数组例外不会扩展其他接口、危险网卡标识零 DoS 请求、部分读取失败、认证取消、
零/缺失到期、字段别名错误和生产写关闭时不许报告成功。所有数据和请求均为合成，
没有启停任何真实防护、修改封锁策略或防火墙规则。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-security-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **306 通过**，全量 **2006 通过、1 失败、0 跳过（共 2007）**，唯一失败仍为
本机符号链接权限，未静默跳过。原生 **9 场景通过**，目录
`windows/dist/ui-review-20260916-223711`；浅深色完整、部分恢复、空/错误/不可用、
加载及不过期状态覆盖，深色实际输出已查看。两架构 Release 构建通过；资源 Apple
4026 / Android 2188 / Windows 2332、本地化、96 请求 fixture、3 响应/22 私有引用、
文档和差异检查通过。没有 Apple/Android 源码变更，也未运行其构建，不提升 observed
证据等级；旧 Mac 回归缺口仍保留。工作区保留前轮改动，未提交/推送。

PENDING_USER_VALIDATION：先在有读取权限的 NAS 查看四分区与各网卡防护，核对未知/
部分失败和重读，不启停安全策略。真实安全写需专用可恢复网络及回退通道，另行验收
后才决定单项行为门；只回传版本类别、步骤和脱敏错误，不含地址/账号/配置档原文或
响应转储。当前只读成果不是四段安全写完成；下一切片继续四段基线保存、防火墙
start/status/stop 任务及整体回读，其他完整目标仍保留。合成输出按此前清理限制保留
且不进入提交。

最终通过原 windows/package.ps1 非交互/both/不重复测试/不自动启动流程生成
Release 自包含测试包，两个 SHA-256 均一致：
`windows/dist/20260916-224024/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-224024/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不改变身份/签名/存储，不代替真实防护验收及既有权限失败。

### 2026-09-16 四段安全保存与防火墙任务

继续安全读取与假成功修复，按既有 security 契约实现自动封锁、DoS、防端口扫描、
防火墙四段基线保存。唯一范围是安全请求规则、共用 NAS 协调器、任务状态/清理、
当前安全表单、正式回归与文档。所有变化能力先一次性预检，配置档只能来自本次 NAS
读取；开启用 Profile.Apply start/status/stop，关闭用 Firewall set_type=disable。

停止未确认任务可能影响实际应用过程，因此仅在 status 明确完成后清理，不对超时/
未知 start 盲目 stop。未知写、任务或清理结果保持待核对，不重发配置或重新 start。
安全行为门独立关闭；与既有各端一样，真实副作用要专用可恢复环境后置验收，不借源码
或合成通过开启生产门。网络/持久化契约不变，C# 仅做已批准的兼容接口增量。

#### 四段保存与任务实际验证

新增安全基线保存重载与四分区规则，复用既有 NAS 记录/并发门，安全行为门独立关闭。
所有变化的读写依赖在首个请求前检查；原值、配置档、网卡集合和参数完整核对，不允许
任意配置档名、未知字段或新网卡注入。仅提交变化段；一次 set/start 中途失败就停止
后续配置，并整体回读。旧无基线签名仍不支持，不再走假成功路径。

防火墙开启固定使用 NAS 本次返回的 profile，最多 30 次状态轮询、每次间隔 1 秒；
明确完成（成功/失败）后才执行一次 stop 清理，不对仍运行、未知 start 或丢失任务 ID
盲目 stop。状态查询拒绝不冒充 start 被拒绝。恢复可查询原任务并清理明确完成上下文，
但不重发 set/start；清理响应丢失不重复 stop。没有任务 ID 或清理结果未知时保留
pending，不能靠当前开关一致就宣布任务完成；这类情况仍需专用环境验证外部恢复，
当前不承诺进程重启后的内存任务恢复。

原生表单已支持自动封锁数值、逐网卡 DoS、端口扫描、防火墙及风险确认；配置档只读
来自 NAS，缺配置档不能启用。输入变化撤销确认，数组按内容比较避免重复刷新。已知
结果后更新实际状态并保留部分提示；未知结果锁定写入并提供核对。调整重复视觉标题
为无障碍名称，保留屏幕阅读语义。生产包仍只读，不代表真实防护已验收。

独立集成/只读对抗复核覆盖四段 fixture、disable 专用动作、完整依赖零请求拒绝、
非法数值/确认/配置档/网卡拒绝、原值冲突、丢响应部分结果、账号/Repository 恢复、
丢失 start/任务 ID 不重发、任务失败清理、状态查询失败、取消未完成任务不 stop、
清理未知不重试，以及关闭后 NAS 不再返回旧配置档时仍能正确核对关闭。首次构建因
新增重载使旧测试 target-typed new 有歧义，已显式声明测试类型，未降低断言。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-security-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

最终聚焦 **324 通过**，全量 **2024 通过、1 失败、0 跳过（共 2025）**，唯一失败仍为
本机符号链接权限，未跳过。原生 **16 场景通过**，最终目录
`windows/dist/ui-review-20260916-230559`，涵盖只读、保存、部分/未知、无效输入、
缺配置档和 pending。两架构 Release 构建通过；资源 Apple 4026 / Android 2188 /
Windows 2346、本地化、96 请求 fixture、3 响应/22 私有引用、文档和差异检查通过。
模拟了任务完成/失败与在途取消，未运行真实 NAS 或长期超时行为验收。

PENDING_USER_VALIDATION：在明确的专用可恢复网络验证四段、当前配置档应用、任务
完成/失败/超时/清理、权限、断线、取消、恢复原值；丢任务 ID 和清理未知的外部恢复
尤其需确认。只回传版本、步骤和脱敏失败，不保存任务 ID、地址、账号、配置档原文或
响应转储。此波没有真实安全写；Apple/Android 源码未改，其旧回归缺口仍保留。网络
契约未扩展，Windows C# 为已批准的兼容增量，不改身份/权限/持久化。保留所有前轮
脏工作区，未提交/推送，旧合成输出按此前限制保留且不提交。中间
`windows/dist/20260916-230459` 不作为最终交付；其余 NAS 管理和完整对齐目标未完成。

最终原 windows/package.ps1 非交互/both/不重复测试/不自动启动流程已生成两架构
Release 自包含包，SHA-256 均匹配：
`windows/dist/20260916-230833/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-230833/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不修改身份/签名/存储，不代替真实防护任务验收或本机权限失败。

### 2026-09-16 硬件与 UPS 分组读取

核对 dsm-hardware-settings.md 与 Mac loadHardwareSettings，Windows 的 Hardware
聚合 get/load 和字段猜测不符合六组 v1 契约。本波单一范围是硬件兼容元数据、读取、
LED 静态读取例外、原生只读入口、测试/资源/文档，不修改真实硬件或其他平台源码。
LED 范围来自设备；蜂鸣器故障字段沿用实际返回名称；UPS 空字符串是已知空值，缺失
才是未知，未知模式不默认 USB。旧猜测写路径移除，六组写/LED update/UPS 验证仍在
后续切片，生产门关闭。真实风扇、休眠、UPS 等行为保留 PENDING_USER_VALIDATION。

#### 硬件/UPS 读取实际验证

Windows 硬件已按 PowerRecovery、Led.Brightness、FanSpeed、BeepControl、Hibernation、
ExternalDevice.UPS 六组 v1 读取；LED 另读 get_static_data，范围不猜测为 0–100。
新增兼容的亮度范围、独立提示音/休眠/UPS 记录及分区状态，旧构造签名和克隆保留；
旧 BeepControl 总开关、休眠分钟数没有等价契约，不再填猜测值。音量故障字段优先
采用设备实际返回名称并绑定对应值，不同时猜测两种键；UPS 只认明确模式，空地址
保留空、缺字段保持 null，不默认 USB。

单组失败保留其他设置，认证与取消传播，未发现任何已记录接口则不可用。旧聚合写
路径移除，无基线保存仍不支持。原生只读列表展示友好风扇/UPS 模式、实际范围和已知
字段；未知项不显示为关闭，UPS 当前模式的可信空地址显示“未设置”。列表可滚动查看
全部项目，加载、空/错误、部分恢复与浅深色均覆盖。

独立集成/只读对抗复核确认 get_static_data 例外只限 LED v1 无参数，update 和其他
接口不借此成为只读方法；六组固定 v1、别名绑定、UPS 空/缺失/未知模式、范围不合法、
失败隔离及旧聚合零请求均有合成回归。没有调整真实灯光、风扇、声音、休眠或 UPS，
也不把源码/合成结果外推成已有硬件 read-verified 环境的新行为结论。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-hardware-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **336 通过**，全量 **2036 通过、1 失败、0 跳过（共 2037）**，唯一失败仍是
本机符号链接权限，不跳过。原生 **9 场景通过**，目录
`windows/dist/ui-review-20260916-232027`；完整深色列表已查看。ARM64 Release 与
x64 合成发布通过；资源 Apple 4026 / Android 2188 / Windows 2380、本地化、96 请求
fixture、3 响应/22 私有引用、文档及差异检查通过。本波 Apple/Android 源码未改，
平台回归未运行，旧 Mac 待验收项继续保留。

PENDING_USER_VALIDATION：在具备读取权限的 NAS 核对六组、设备亮度范围、提示音字段、
UPS 模式和可信空地址，不触发任何物理副作用。写入需要专用目标和可恢复方案，再验证
LED 两阶段更新、风扇模式、休眠唤醒及 UPS 行为；只回传版本、操作与脱敏错误，不传
真实服务器或响应。当前只读入口不代表六组安全写完成，下一切片继续基线保存/LED
update/UPS 规则及整体回读。工作区保留前轮改动，未提交/推送；合成产物按此前清理
限制保留且不提交，完整对齐目标仍未完成。

最终采用原 windows/package.ps1 非交互/both/不重复测试/不自动启动流程生成
x64/ARM64 Release 自包含包，两个 SHA-256 匹配：
`windows/dist/20260916-232442/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260916-232442/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不改身份/签名/存储，不代替真实硬件验收和既有权限失败。

### 2026-09-16 六组硬件基线保存

本波继续硬件/UPS 读取，按既有 hardware 契约和六份 fixture 实现变化组提交、LED
set_current_brightness/update 和整体回读。单一范围为硬件规则/请求、NAS 共用协调器、
原生编辑与测试/文档。未知原值不许变成新字段，设备范围/蜂鸣器字段名不可由草稿改写，
UPS 已知空地址可编辑、缺失地址不可写入。行为门独立关闭，不进行真实物理操作。

LED 第一阶段失败不能继续 update，未知阶段不重发；未确认记录保留到可核对状态或
专用设备验证，不将配置读取当作灯光/散热/UPS 物理副作用已经验收。源码/合成闭环
不缩小其余 NAS 管理及完整对齐目标，网络契约/持久化/身份不变。

#### 2026-09-17 硬件保存实际验证

六组保存重载已接共用 NAS 协调器，固定 v1 能力、原值与请求 ID。规则只允许设备已
报告字段变化，拒绝未知原值变新值、改写设备范围/蜂鸣器字段名、无效风扇模式和 UPS
参数；可信空地址仍可明确填写。仅变化组提交，蜂鸣器/休眠只发变化键，UPS 保留必要
模式/开关/延迟并只提交有原值的变更字段，旧聚合写路径不再使用。

LED 设置明确接受后才调用 update；任一阶段断线/取消立即停止后续组。整体回读按六组
计算结果，同请求不重发，账号/Repository 恢复复用既有隔离。LED 缺少 update 明确接受
时，不以暂存亮度匹配冒充物理更新完成，保留待核对；这类未知阶段的外部恢复仍须专用
设备验证，当前不擅自重发 update 或提供未经验证的绕过。生产行为门独立关闭。

原生编辑动态生成设备已报告字段，区分网络 UPS 与 SNMP 地址；缺失字段没有输入框，
确认前后快照受保护。原生测试发现文本已变而草稿事件尚未同步：现在确认时重新读取
全部输入、保存前比对确认快照，确认后再改值会撤销确认，不提交旧值。确认入口不以
旧草稿的变化/校验状态永久禁用，实际保存仍必须通过当前输入校验；无有效改变仍不可
提交。临时反射诊断已移除，保留原生“确认后改值不得写入”和 UPS 空地址编辑断言。
已知部分结果刷新实际设置，未知结果禁止继续保存。

独立集成/只读对抗复核覆盖六份 fixture、LED 顺序/丢响应/不重发、变化字段、设备范围、
未知地址与可信空值、字段名绑定、原值冲突、完整能力预检、账号隔离、整体部分回读、
生产门与未知环境关闭。动态表单不读取或替换真实 NAS 数据，所有测试均为合成；曾遇到
nullable 范围参数构建错误，改为只有实际范围存在才格式化，没有猜测默认范围。

实际命令（原 .NET 10.0.401 / bundled Python）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~DsmApiClientFixedReadTests' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-hardware-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **346 通过**，全量 **2046 通过、1 失败、0 跳过（共 2047）**，唯一失败仍是
本机符号链接权限。原生 **16 场景通过**，最终目录
`windows/dist/ui-review-20260917-000054`，含保存/部分/未知、越界、pending、可信空
UPS 地址和确认快照保护；深色输出已查看。ARM64 Release 与 x64 合成发布通过；资源
Apple 4026 / Android 2188 / Windows 2385、本地化、96 请求 fixture、3 响应/22 私有引用
及文档/差异门通过。没有真实灯光/风扇/休眠/UPS 验收，旧 Mac 回归缺口仍保留。

PENDING_USER_VALIDATION：专用可恢复硬件上另行授权单项行为门，验证设备范围、六组
正常/拒绝/断线/取消、LED 两阶段和恢复、风扇与 UPS 模式、副作用和恢复原值；只回传
版本类别、操作和脱敏错误，不传真实服务器或响应。Windows C# 为兼容增量，网络参数
契约不变，Apple/Android 本波未改，不提升已有硬件证据等级。保留所有前轮脏改动，
未提交/推送；合成输出按此前清理限制保留且不提交。硬件源码/合成闭环不代表真实可写
发布或全部目标完成，其余 NAS 管理与系统集成仍待推进。

本波最终经原 windows/package.ps1 非交互/both/不重复测试/不自动启动流程生成两架构
Release 自包含包，SHA-256 一致：
`windows/dist/20260917-000728/LanStash-0.1.0-x64.zip` 与
`windows/dist/20260917-000728/LanStash-0.1.0-arm64.zip`。未安装、启动或提交/推送，
不修改身份/签名/存储，不代替真实设备或旧 Mac 待验收项。

### 2026-09-17 DDNS 读取与身份对齐

当前 Windows 的 DDNS 读取吞错、从错误 id/name 推断身份，记录缺字段补 false；
ViewModel 还以写权限决定是否读取。已核对 dsm-ddns-settings.md 与 Mac loadDDNS，
本波唯一范围为固定 Provider/Record v1 读取、稳定 provider 身份/可选字段、现有
ViewModel 与原生读取入口、测试/双语/文档。读取与写入可用性分离，不读取/保存密码
字段，不把空列表当作网络失败。提供商允许已记录的协议重复项并保留友好名称，
记录身份重复则失败。四类测试/保存/更新/删除仍须后续完整独立边界，生产门关闭。
不改真实 DDNS、DNS、QuickConnect 或其他平台源码，私有证据不提升。

实现与复核：固定两项能力均支持 v1 后才读取，FORM/JSON 声明仅对无业务参数的
list 放行；严格检查根/行/必需五字段与可选网络字段，记录 id 固定取 provider。
服务商重复协议项保留友好名称，记录重复失败；响应 passwd 不进入领域模型，草稿
ToString 不输出字段，切换/关闭时清除旧草稿密码引用。原有 ViewModel 不再以写权限
阻断读取，刷新失败显示错误而非空列表；原生只读入口覆盖加载、空、失败和内容。
移除旧未接线的嵌套编辑弹窗，不新增平行 ViewModel。只读对抗复核确认本入口无写
调用；旧写方法返回 Unsupported，四类写及其互斥/恢复/凭据生命周期留待下一切片。

最终实际验证命令与结果：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasAdmin -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-ddns-settings -WindowWidth 900 -PaneState compact -SkipBuild
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

本机工具使用既有 LanStashBuild dotnet 与 bundled Python。最终 NasAdmin 聚焦 **320
通过**，全量 **2065 通过、1 失败、0 跳过（共 2066）**；唯一失败为
`BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 创建符号链接时
缺少系统特权，未改断言或跳过。原生合成 **7 场景通过**，重跑输出目录
`windows/dist/ui-review-20260917-003934`；之前同样七场景的深色图已查看。资源
Apple 4026 / Android 2188 / Windows 2390、本地化、96 请求 fixture、3 响应组与
22 私有引用、文档/差异门通过。本波已完成 x64 合成发布、ARM64 Release 构建和
既定 package.ps1 双架构打包，未安装或自动启动正式包。最终两个归档 SHA-256
均与对应 .sha256 文件一致：

- `windows/dist/20260917-003453/LanStash-0.1.0-x64.zip`
- `windows/dist/20260917-003453/LanStash-0.1.0-arm64.zip`

PENDING_USER_VALIDATION：用已有账号打开 NAS 设置中的 DDNS，验证服务商/记录显示、
无地址提示及断网重试；预期与 DSM 可见记录一致且不更改记录。只回传版本类别、
操作步骤和脱敏错误，不提供真实域名、用户名、地址、凭据或响应。真实 NAS 读取、
屏幕阅读器及旧 Apple 回归尚未验收，本波不新增 Apple/Android 修改，不提升私有
证据等级。保留既有工作区改动，未提交/推送；合成输出遵循此前清理限制，不提交。
DDNS 四类写、其余 NAS 管理与系统集成仍未完成，整项目标保持进行中。

### 2026-09-17 DDNS 四操作核心

本波以 `DsmNasAdministrationRepository.swift` 的 test/save/delete/refreshDDNSResult、
`NasAdministration.swift` 的 DDNS 草稿和已记录 `dsm-ddns-settings.md`/四组请求 fixture
为证据；Windows 复用现有 NAS 写协调器，增量提供不可变确认快照、固定请求标识与
单次请求密码参数，四个操作分别预检/发送/核对，不串联测试与保存或保存与地址更新。
保存/删除未知结果只回读，测试接受不等于保存，更新接受不等于公网解析生效。
本波先完成 Repository/领域与故障注入回归；原生编辑交互随后接入，不以只读页冒充
完整闭环。私有高风险写行为门保持关闭，无真实 NAS 写验证，不修改 Android 源代码；
这是已授权的向后兼容 Windows 接口增量，不更改线上请求契约或持久化结构。

复核发现 Apple 同类缺陷：明确保存/删除拒绝后仍回读，可能把旧配置或外部删除当成
本次成功；仅修改密码时超时后的旧字段匹配也不能证明凭据保存。按既有用户授权，
共享 `DsmNasAdministrationRepository.swift` 同步修正并新增三项回归。Apple 修改仅
涉及结果判定、不修改请求字段或公开接口；macOS/iPhone/iPad 需执行共享层回归，
Android 仅记录后续适配核查，不擅自修改。Windows 对相同场景也已有聚焦合成测试。

本波实际完成：新增 `NasDdnsMutationRequest`（不含密码）及现有 Repository 的兼容
默认方法，生产能力以独立 DDNS 行为门和环境门保护；核心位于
`DsmRepository.NasSettings.DdnsWrites.cs`，复用已有协调器、固定 v1、FORM/JSON 参数
编码和会话传输。测试不自动保存，保存不自动更新地址；删除 id 是服务商数组，更新
无业务参数。编辑省略空密码且保留未知可选字段，Synology 使用已记录固定标记。
新建/编辑/删除核对目录与目标基线，更新核对用户确认的全部服务商集合；请求开始前
复制外部集合。密码不持久化、不进请求指纹或恢复对象，请求参数容器在结束后清空。
明确拒绝直接失败；保存/删除不确定时单次回读且保留挂起状态，同客户端重建可核对，
不重放。测试或未获接受响应的立即更新无法从目录证明结果，缓存未知结果并释放挂起；
后续必须由用户明确发起新确认请求。仅换凭据丢失确认时继续未知，不能从旧字段假成功。

独立集成/只读对抗复核：重查两个能力/固定版本/受限路径、环境、profile/账号/地址
隔离、风险确认、基线冲突、跨 Repository 防重复、提交前后取消、秘密生命周期与
四操作参数边界。Windows 新测试直接驱动同一内部生产核心，不修改生产门；测试中
HTTP 主机固定为 nas.invalid、凭据与记录均合成。Apple 变更保留既有区域修复，未
覆盖其他脏改动；不将 Windows 通过当成 Mac 回归。

实际命令与结果（使用既有本机 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDdnsWriteTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

DDNS 新测试 **28 通过**，全量 **2093 通过、1 失败、0 跳过（共 2094）**；失败仍是
`BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 的本机符号链接权限，
未降低断言或静默跳过。x64/ARM64 构建均 **0 警告/0 错误**。Swift 命令不可用，Apple
新增三项测试未执行。资源数不变，96 请求 fixture、3 响应组/22 私有引用、本地化、
文档与差异检查通过。本波没有新增 UI 或重跑原生界面合成，也没有重新打包旧测试包。

PENDING_USER_VALIDATION：Mac 上执行共享 Swift 回归和目标构建，重点检查明确拒绝、
仅换密码响应丢失、新建响应丢失后正确回读；Windows 需待原生四操作调用链接入后在
专用可恢复 NAS 上另行授权行为验证，确认测试不保存、更新不宣称 DNS 传播、保存/
删除单次发送和取消/断线恢复。回传仅限命令/用例、版本类别和脱敏失败语义。密码
无法回读，未知凭据修改需官方界面人工核查；当前不提供强制清除挂起的未验证入口。
其他平台真实兼容证据不提升，未提交/推送或触碰 NAS；下一切片为现有 DDNS
ViewModel/原生编辑、四操作确认与持续反馈/恢复，不另建平行模型。整项目标未完成。

### 2026-09-17 DDNS 原生四操作调用链

本波单一范围为现有 `NasDdnsViewModel` 与 `NasDdnsSettingsDialogContent`：对齐 Mac
DDNS 新建/编辑、测试、更新和删除的独立用户结果，使用上一波固定请求核心。
WinUI 保留单个设置弹窗，使用原生输入、明确动作与风险确认，不恢复嵌套弹窗。
确认绑定当前草稿/目标/密码，任一输入改变需重确认；操作期间禁止其他操作或刷新，
关闭/切换清除密码并隔离迟到结果，未知操作只读核对。业务逻辑/测试/双语资源与合成
界面由当前任务统一修改；不改变请求契约、生产门、身份或存储，不修改 Android。
危险写仍需专用 NAS 验收，当前仅运行合成与构建，不能因页面接线而宣称真实可写。

对照 Mac `NasAdministrationModel.swift`/`NasAdministrationView.swift` 的 DDNS 调用链时
发现：界面模型又把匹配的旧记录/空目录当成成功，覆盖上一波适配器返回的拒绝或未知。
按用户已授权的同类缺陷修复范围，删除这两处成功覆盖，新增保存旧配置和删除空目录
各一项参数化回归。没有改变 Apple 公开接口、请求字段、页面样式或其他模块；Mac
回归仍需目标环境执行，不能用 Windows 合成结果替代。

本波实际实现与复核：现有 ViewModel 统一管理加载/测试/写入，防止成功后刷新把保存
标志挂死；共用 `NasDdnsMutationRules` 避免表单与 Repository 规则分叉。确认绑定
不可变记录/目录快照和临时密码，提交时清空草稿/确认密码；刷新只核对结果而不重放。
改变已测试的输入即移除旧成功提示；profile 切换后，迟到服务商结果不会启动旧目录
读取或污染新页面。原生页面保持单个滚动弹窗，含记录选择、服务商/域名/账号/密码、
启用/心跳、四动作确认、持续反馈和重新读取；关闭/换 NAS 清除 PasswordBox。
编辑保留未知可选网络字段，Synology 不显示无用密码输入。风险确认时与执行前均读取
当前原生控件值，不依赖 TextChanged 已经投递；修改密码后旧确认失效已做原生回归。

独立集成/只读对抗复核覆盖生产门仍关闭、四动作不串联、确认目标绑定、默认关闭
按钮、权限/未知不报成功、重复提交/刷新互斥、密码清理与迟到响应隔离。首次原生
编译暴露 StackPanel 无 IsEnabled，改为逐个原生 Control 的启用状态后完整重跑；
未削弱断言。既有单元测试补上明确确认和真实 provider 身份，保留原成功/刷新断言。

实际验证：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDdns -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-ddns-settings -WindowWidth 900 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

DDNS 聚焦 **67 通过**，最终全量 **2105 通过、1 失败、0 跳过（共 2106）**；唯一失败
仍为 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 的系统符号
链接权限，未跳过。最终原生 **17 场景通过**，目录
`windows/dist/ui-review-20260917-011152`；浅色测试反馈和深色未知结果的前一次同场景
输出已查看。ARM64 Release 构建 0 警告/0 错误，最终 x64/ARM64 均经既定 package.ps1
非交互/both/不重复测试/不自动启动流程重新发布；本地化资源 Apple 4026 / Android
2188 / Windows 2423、96 请求 fixture、3 响应组/22 私有引用、文档/差异门均通过。
Swift 命令不可用，Mac 新增两项参数化模型回归及上一波共享层回归均未运行。

测试包 SHA-256 与对应 .sha256 一致，未安装或自动启动正式包：

- `windows/dist/20260917-011329/LanStash-0.1.0-x64.zip`
- `windows/dist/20260917-011329/LanStash-0.1.0-arm64.zip`

PENDING_USER_VALIDATION：Windows 实际 NAS 上默认仍只读，需专用可恢复环境另行授权
DDNS 行为门后，逐项验证新建/编辑/测试/更新/删除、权限拒绝、断线、取消及恢复。
确认测试不保存、更新接受不代表 DNS 传播、仅换密码未知不能自动解锁重试；键盘、
屏幕阅读器、缩放及触控需目标设备验收。Mac 上运行共享层与 App 模型测试，并验证
旧配置/空目录不会覆盖拒绝或未知结果。只回传步骤、版本类别与脱敏错误，不传真实
域名/账号/凭据/响应。未触碰真实 NAS、未提交/推送；保留既有脏改动与此前清理受限
的忽略合成输出。整项目标未完成，其余 NAS 管理、Container/VMM 深层能力及系统集成
仍需按账本推进，不把本波 DDNS 调用链接线视为所有功能对齐。

### 2026-09-17 套件读取与三操作核心

证据为 `dsm-package-control.md`、安装边界文档、三个请求 fixture、Apple 的
`DsmNasAdministrationRepository+Packages.swift` 与控制/卸载实现。Windows 当前
摘要使用猜测身份/状态，旧控制调用错误 Package 方法且空回读可能假成功。本波先
修正稳定身份/严格列表、启动/停止/卸载的确认基线、必要可行性检查与有界状态核对，
复用现有 NAS 写协调器；新增原生管理交互随后集成，不以摘要行冒充完整控制。
安装/升级只保留明确 upgrade 只读提示，不猜测安装接口。高风险生产门保持关闭。
另按用户同类修复授权，纠正 Mac 缺失 startable/操作/卸载类型时默认允许的行为；
共享层回归必须后续在 Mac 运行，不修改 Android，不提升真实环境证据等级。

本波实际实现：`NasPackageSummary` 兼容增量保存许可、操作列表与 desktop app 标识；
新增无副作用的 upgrade 提示，未知状态不向用户显示协议文本。固定 Package v2
offset/limit/additional 读取严格处理根、行、身份、重复、类型与 1000 条源边界。
NasDetails 摘要仍保留已有 50 条截断标记；旧 Workspace 路径使用同一完整读取，
新增 PackageStatus 区分失败/不可用/可信空目录，不因摘要上限静默丢失其余套件。
这是已授权的向后兼容 Windows 领域接口增量，不修改持久化结构或线上请求字段。

`NasPackageMutationRequest` 绑定用户确认的完整基线；三操作共享现有协调器，并按
scope/套件 ID 保存挂起状态。固定 v2 可行性检查必须成功后才发一次专用 v1 请求。
明确接受十次、模糊提交三次的一秒间隔只读核对；取消后一次独立十五秒超时核对。
明确权限/认证拒绝不被回读覆盖，繁忙或未知错误码不能证明没有副作用。请求 ID
重复只能返回结果或回读，同目标未知状态不能通过新 ID 绕过；恢复记录不持有
Repository/会话对象。旧无基线签名 Unsupported，不再存在错误接口或空回读假成功。

独立集成与只读对抗复核：检查运行时 Discover 的 query=all 能发现专用控制能力，
列表 v2/控制 v1 交集和受限路径、固定目标、基线漂移、可行性权限拒绝、账户隔离、
跨动作互斥、接受/超时/取消/未知状态、畸形卸载回读，以及生产行为门仍关闭。对
JSON 字符串数组按解码后的值与顺序核对 fixture，兼容等价的 Unicode 转义，不减少
参数或操作断言。测试源码只用合成 HTTP 与记录，未发真实 NAS 请求。

实际验证（使用既有本机 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter "FullyQualifiedName~NasPackageMutationTests|FullyQualifiedName~PackageUpgradeIsAccessible" -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增聚焦 **37 通过**，最终全量 **2142 通过、1 失败、0 跳过（共 2143）**；失败仍是
`BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 创建符号链接缺少
本机系统特权，未跳过或改断言。最终 x64/ARM64 Release 均 **0 警告/0 错误**。资源
Apple 4026 / Android 2188 / Windows 2425、本地化、96 请求 fixture、3 响应组与
22 私有引用、文档/差异门通过。Swift 命令不存在，新增两项参数化共享 Swift 回归
未运行；本波无原生控制界面，未执行其合成 UI 测试，也未重新打包旧归档。

PENDING_USER_VALIDATION：Mac 上执行共享层及 macOS 回归，核查缺失许可、畸形目录、
状态判断、图标装配和原有三操作测试；iPhone/iPad 需回归共享层影响，Android 仅
更新适配评估不改源码。Windows 原生控制入口接入后，在另行授权的专用可恢复 NAS
验证启动/停止/卸载及依赖拒绝、断线/取消恢复；目前默认写门仍关闭，不测真实副作用。
反馈仅含用例、版本类别、脱敏错误；不含真实套件/账号/地址/凭据/响应。已有数据、
用户与其他波次改动均保留，未提交/推送。下一切片是原生套件管理确认与持续反馈，
安装升级的证据缺口保持明确关闭，整项目标未完成。

### 2026-09-17 原生套件管理调用链

本波以 Mac 套件列表/确认/反馈和已记录 package-control 契约为证据，接入上一波
固定三操作核心。单一范围为新的套件管理 ViewModel/原生内容、NAS 菜单接线、恢复
摘要接口、双语和正式合成回归；复用现有弹窗生命周期和写协调器，不新增平行写实现。
确认必须绑定当前选中套件完整快照/动作；旧页面关闭或换 NAS 后迟到结果不得污染
新页面。已卸载目标可能不在列表，因此恢复必须先枚举协调器中挂起目标，不能只从
当前目录反推。分开暴露启停/卸载能力，安装升级继续只读提示，生产行为门仍关闭。
Windows 接口增量兼容旧实现，不改变网络契约或存储；其他平台源码不在本波范围。

本波实际完成：`NasPackageManagementViewModel` 使用既有 Repository 和写协调器，
提供本地搜索、目标/动作绑定确认、互斥执行、持续反馈、只读恢复及 profile 生命周期
隔离。`GetPackageRecoveriesAsync` 从同客户端按账号/NAS 隔离的挂起状态提供目标与
动作，包含目录中已消失的卸载目标；只查询结果，不基于旧列表假设成功。启停与卸载
能力分别判断，系统套件/缺失许可/生产只读/未知目标不能执行；其他无挂起目标仍可
独立选择。重新加载清除旧确认，选择或搜索隐藏目标后不能沿用确认，提交前重读原生
控件状态防止事件投递延迟。页面关闭或换 NAS 取消旧请求，迟到结果不改新页面。

`NasPackageSettingsDialogContent` 接入现有 NAS 设置菜单/单弹窗生命周期，包含加载、
可信空目录、搜索为空、错误、内容和恢复状态。共用内容接口增加有默认值的按钮资源
属性，套件页隐藏无意义的保存按钮，其他设置页仍使用原保存行为；没有嵌套弹窗或
安装/升级写入口。套件版本/状态/升级提示和确认风险全部双语，增加无障碍名称。
Windows 接口兼容增量不影响其他平台网络契约，本波未修改 Apple/Android 源码。

独立集成与只读对抗复核：确认三动作无串联、默认关闭按钮、明确卸载影响、按完整
基线确认、启停/卸载独立 capability、未确认状态不重放、消失目标恢复、账号隔离、
操作期间禁止并发刷新、关闭取消及迟到响应隔离。原生宿主首次构建的局部变量重名
已修复后重跑，没有削弱断言或绕过门禁。

实际命令（沿用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasPackage -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~ConnectedUsesSlowerCalibrationAndDisconnectRestoresPolling -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-package-settings,nas-ddns-settings -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

套件聚焦 **49 通过**（含新增 13 项 ViewModel 用例），最终全量 **2155 通过、1 失败、
0 跳过（共 2156）**；唯一最终失败仍是符号链接创建缺少系统特权。此前一次全量还
出现 `ChatRealtimeRefreshTests.ConnectedUsesSlowerCalibrationAndDisconnectRestoresPolling`
的时间敏感断言失败，隔离重跑 **1 通过**、之后完整重跑也通过；未改 Chat 代码或断言，
保留偶发时序风险记录。原生 **36 场景通过**：新套件 19，加共用弹窗影响的 DDNS 17，
目录 `windows/dist/ui-review-20260917-015022`；已查看套件浅色成功与深色未知结果。
资源 Apple 4026 / Android 2188 / Windows 2451、本地化、96 请求 fixture、3 响应组/
22 私有引用、文档与差异门通过。现有 Mac 回归缺口未消除，不外推目标平台验证。

按既定 package.ps1 非交互/both/不重复测试/不自动启动流程成功发布 x64 与 ARM64，
两个归档 SHA-256 均与 .sha256 一致；未安装或自动启动正式包：

- `windows/dist/20260917-015315/LanStash-0.1.0-x64.zip`
- `windows/dist/20260917-015315/LanStash-0.1.0-arm64.zip`

PENDING_USER_VALIDATION：真实 NAS 默认仍只读；另行授权专用可恢复环境后，逐项验证
启停/卸载确认、依赖拒绝、状态过渡、弱网/取消/再开页面恢复，以及 Narrator/键盘/
触控/缩放。特别验证卸载目标消失后仍能恢复核对、未知操作不重发，安装升级不提供
执行入口。只回传用例、版本类别和脱敏结果，不传账号/主机/套件清单/凭据/原始响应。
未触碰真实 NAS、未提交/推送，保留既有工作区改动及此前清理受限的忽略合成输出。
其余 NAS 管理、Container/VMM 深层能力与系统集成仍需继续，整项目标未完成。

### 2026-09-17 账号/群组严格读取与删除核心

本波证据为 `dsm-account-directory.md`、users/groups delete fixture、Mac Accounts
适配器及删除结果模型。Windows 先接固定 User/Group v1 独立读取和完整基线删除，
删除参数为 name 数组；不再使用空回读占位。当前账号、系统保留名称、未知许可、
过期基线和畸形/截断目录必须失败关闭。复用既有协调器与恢复生命周期，用户/群组
读失败分别降级，不阻断其他 NAS 模块。原生目录管理、新建/编辑仍是后续必做切片，
不是目标删减；生产删除门保持关闭，不接触真实 NAS 账号。按既有用户授权修正 Mac
同类缺失许可默认放行、畸形目录误作空目录和删除结果覆盖问题，Mac 回归待目标环境。

本波实际实现：新增 `NasDirectoryEntry` 可空状态与许可、完整删除确认快照和挂起
目标摘要。`DirectoryRead` 固定 User/Group v1、offset/limit/additional，严格检查根、
行、大小写重复名称、类型、根/额外字段冲突及源读取上限；uid/gid、可信空文本和
未知停用状态不丢失，响应密码不进入模型。旧 Workspace 的账号与群组使用同一读取，
分别保存可用状态；一方失败显示错误行，不遮蔽另一方数据，也不被显示为可信空目录。

`DirectoryWrites` 复用已有 NAS 协调器，账号/群组删除行为门各自关闭。确认绑定
完整快照、profile 与请求 ID；写前重读比较名称、数字 ID、说明、邮件、停用、群组
关系及权限，保护当前登录账号和系统保留名称。删除只发一次 v1 name 数组；断线
单次回读、取消后保持未确认，未知目标不能用新 ID 重发，同客户端重建可以枚举并
核对挂起目标。旧无基线 DeleteAccount/DeleteGroup 保持 Unsupported，并移除空回读
假成功实现；本波未修改相邻连接断开/磁盘测试占位，留待独立切片。

按既有用户授权，Mac 同步修正账号解析与删除反馈：支持根/额外字段并严格比较冲突，
保留空文本，拒绝畸形/截断/重复身份；缺失权限不默认允许编辑/删除。旧 Apple 领域
停用状态仍是非可空布尔，因此缺失会被表单覆盖的字段时关闭编辑，避免把未知值
写成默认值。内部 DsmDynamicJSON 仅增加 Equatable 供冲突比较；公共模型和存储不变。
删除前重新核对 can_delete 与已知当前账号，目标名称不裁剪后误指向别的条目；Mac
模型不再凭目录为空覆盖拒绝/未知。创建/编辑和 Mac 完整确认基线仍需后续继续，
不把这次修复算作账户管理全部对齐。

独立集成/只读对抗复核覆盖固定版本/路径/格式、独立可用性、未知布尔不补默认、
稳定身份与保护名单、确认基线漂移、取消阶段、错误结果、同目标防重复、账号/NAS
隔离、畸形回读不算删除成功和密码不入模型。Windows 34 项新测试使用完整合成
HTTP 验证同一核心，未开放生产门；Apple 新增 6 项共享测试和 2 项模型测试未运行。

实际命令（使用既有本机 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDirectoryMutationTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

聚焦 **34 通过**，最终全量 **2189 通过、1 失败、0 跳过（共 2190）**；唯一失败仍是
符号链接创建缺少系统特权，没有跳过或降低断言。x64/ARM64 Release 都 **0 警告/
0 错误**；资源 Apple 4026 / Android 2188 / Windows 2454、本地化、96 请求 fixture、
3 响应组/22 私有引用与文档/差异门通过。Swift 命令不存在，无法执行本波新增 Apple
回归。本波未运行原生账号管理场景、未重打包；现有测试归档不包含这些最新改动。

PENDING_USER_VALIDATION：Mac 执行共享包与 App 模型回归，重点检查字段位置、空文本、
缺失许可、当前账号、稳定名称及未知结果反馈；iPhone/iPad 回归共享层影响。Windows
原生管理及新建/编辑完成后，在另行授权的专用可恢复账号环境验证权限、删除取消/
断线/再开页面恢复；当前两类生产删除门保持关闭。只回传步骤、版本类别与脱敏错误，
不得提供真实账号、邮件、组关系、主机、凭据或原始响应。Android 本波不改源码，仅
同步五端影响评估；未触碰 NAS、未提交/推送，保留所有先前工作区改动。整项目标仍
进行中，下一切片继续账号/群组新建编辑及原生管理，不阻塞其他无依赖功能。

### 2026-09-17 账号/群组新建与编辑核心

本波使用已有 User/Group create/set 契约、创建 fixture 和 Mac 编辑字段证据，补齐
Windows 不含密码的确认快照与新建/编辑核心，复用目录删除的互斥和恢复状态。
管理保存先按已记录 Session.is_admin 进行权限检查；编辑完整基线必须匹配，不重命名
稳定目录项、不把未知停用/邮件/说明或组关系写成默认值。密码只传当次请求，不进入
共享状态或指纹；带密码的保存必须有接受响应和记录回读，列表不能证明密码登录可用。
当前账号不能被本操作停用或改组。原生交互随后集成，保存/删除行为门独立关闭。
Mac 同步修复保存只检查名称存在就当成功的缺陷，不改公开协议或持久化；目标回归待验。

本波实际实现：新增不含密码的 `NasDirectoryValues`/`NasDirectorySaveRequest` 与共用
字段规则，固定 User/Group v1 create/set。创建检查重名，编辑重读完整基线，禁止
重命名、覆盖未知说明/邮件/停用字段、盲目覆盖未知组关系和提交无变化表单；显式组
关系还需对应组目录可用且目标存在。依据已记录的 Session.is_admin 布尔真值检查
管理权限，不把字符串 true、缺失或 false 当作管理员。当前登录账号不能被停用或
改变自身组关系。新保存能力独立于删除能力，所有生产行为门继续关闭。

目录保存与删除复用同一目标挂起表及请求 ID 缓存；恢复摘要区分创建/编辑/删除，
兼容原删除调用。密码/确认密码只进入当次参数，空密码不发送、不去除有意空白，
不进入 DTO、签名或恢复对象。写后校验全部提交字段和旧数字身份；带密码的操作还
必须收到接受响应。密码响应丢失后即使记录匹配也保持未知，不能从目录证明新密码
可登录，不能通过保存或删除新请求绕过未确认状态。其他目标仍可独立操作。

Mac 同类修正包含保存前重名/完整基线核对、禁止以名称存在确认成功、逐字段及数字
身份回读、超时/取消/无效响应的不可重试未确认提示。仅采用现有 loadPage 的当前
成功 apply 返回的新快照，失败或过期加载不得使用旧缓存确认保存。旧 Apple 停用
字段是非可空布尔，账号保存确认要求解析器保留的完整可编辑快照，避免未知默认值
被当作证据。保存/删除及行进度共用规范化目标键，组和账号分开，修正原有相互不一致
的标识；创建按钮在同类操作期间禁用。网络层额外保护已知当前账号不被停用或改组。
没有修改 Apple 公开协议、身份、签名或持久化格式；仍需 Mac 验证这些共享与 UI 变更。

独立集成与只读对抗复核覆盖管理员字段类型、角色判断不依赖翻译、双能力门、原值
漂移、组目录检查、当前账号保护、确认 DTO 无密码、参数清理、同目标跨保存/删除
互斥、同请求不重放、密码结果不推断、数字身份变化、真实新回读和旧缓存隔离。
Windows 新增 **24 项**保存测试，与前轮删除/读取一起 **58 项通过**。Mac 新增
7 项模型回归和 1 项网络回归，均未运行；没有用源码检查替代目标执行。

实际命令（使用既有本机 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDirectory -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

最终全量 **2213 通过、1 失败、0 跳过（共 2214）**，唯一失败仍为本机符号链接特权；
x64/ARM64 Release 均 **0 警告/0 错误**。资源 Apple 4028 / Android 2188 / Windows
2454、双语/硬编码检查、96 请求 fixture、3 响应组/22 私有引用和文档/差异门通过。
Swift 命令不可用；未执行 Mac 回归或原生账号管理 UI 合成。本波没有重新打包，旧
测试归档不包含这些新增核心。

PENDING_USER_VALIDATION：下一切片接原生账号/群组创建、编辑、删除与恢复 UI，再在
另行授权的专用可恢复 NAS/账号环境验证重名、许可变化、密码策略、角色关系、断线/
取消和手动核对。密码未知结果需 DSM 人工核查，当前不提供未经验证的强制解锁入口。
Mac 运行共享包及 App 模型/界面回归，重点覆盖忽略字段、保存后读取失败、密码修改、
规范化忙碌键和当前账号保护；Apple 移动端需回归共享网络层影响。Android 本波仅
更新评估、不改源码。只回传步骤、版本类别及脱敏错误，不发送真实身份、组关系、
邮箱、凭据或响应。未触碰真实 NAS、未提交/推送，保留先前工作区改动；整项目标
未完成，其他 NAS 管理与系统集成仍待继续。

### 2026-09-17 原生账号与群组管理

本波单一范围为 Windows 目录管理 ViewModel/原生内容、NAS 菜单、双语及正式合成
回归，沿用前两波固定读取和保存/删除核心。用户可切换账号与组、本地搜索、新建、
编辑、删除和核对未知结果。两类读取独立降级；组关系必须明确选择修改，读取失败
或原成员关系未知时保持不提交该字段。确认绑定目标、完整草稿、组选择和临时密码，
输入变化撤销确认，关闭/换页/换 NAS 清除密码并隔离旧回调。未知结果不重放，生产
行为门不开放；不改变 API 契约或存储，不修改其他平台源码。

本波实际完成：`NasDirectoryManagementViewModel` 统一账号/群组读取、草稿、保存/
删除确认、互斥执行、持续反馈和只读恢复；原生内容接入现有 NAS 菜单和单弹窗生命周期。
两类目录独立保存可用性与错误；恢复失败时仍可查看已读数据，但禁止新写。只读列表
显示名称、说明、邮箱、数字标识和所属组；未知停用状态不显示成启用。创建/编辑/
删除及跨目录切换均绑定稳定种类，不从翻译文案判断 API 或角色。

组关系采用明确修改选项，默认省略 groups；当前账号、未知原组关系或不可读的组目录
不允许修改组关系，其他完整资料仍可编辑。密码和确认密码在发起请求前从模型及两个
原生 PasswordBox 清除，关闭、取消编辑、切换目录/配置也清除；确认后的密码/组选择
变化撤销旧确认，执行前同步实际控件值，避免事件投递延迟重用旧快照。未知结果只
读核对，包含已从目录消失的目标；已保存信息重新读取后更新列表，不重放操作。

独立集成与只读对抗复核覆盖角色和字段失败关闭、当前账号保护、默认关闭按钮、
删除影响提示、界面确认与 API 快照一致性、输入变化失效、互斥刷新、密码清除、
跨配置迟到响应隔离、独立读取失败和未知结果恢复；保留原生产门，没有真实 NAS 写。
本波只改 Windows 交互及测试/文档，不修改其他平台源码，也不新增存储或接口参数。

实际命令（使用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDirectory -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-directory-settings -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

账号聚焦 **77 通过**（新增 19 项模型用例），最终全量 **2232 通过、1 失败、0 跳过
（共 2233）**；唯一失败仍是本机符号链接特权，未修改或跳过断言。最终原生 **25
场景通过**，目录 `windows/dist/ui-review-20260917-031310`，覆盖双目录新建/编辑/
删除、独立错误、组修改、只读数据、未知/拒绝/冲突、迟到密码变更、恢复、关闭取消
和切换清理。已查看只读浅色与密码未知深色输出。资源 Apple 4028 / Android 2188 /
Windows 2502、本地化、96 请求 fixture、3 响应组/22 私有引用及文档/差异门通过。

按既定 package.ps1 非交互/both/不重复测试/不自动启动流程成功发布 x64 与 ARM64；
SHA-256 均与相邻 .sha256 一致，未安装或自动启动正式包：

- `windows/dist/20260917-031611/LanStash-0.1.0-x64.zip`
- `windows/dist/20260917-031611/LanStash-0.1.0-arm64.zip`

PENDING_USER_VALIDATION：另行授权专用可恢复 NAS 账号后验证账号/群组 CRUD、密码
策略、成员关系、权限变化、当前账号保护、断线/取消/重开核对及 Narrator/键盘/触控/
缩放。无法确认的密码变更须在 DSM 中核查，不提供未经验证的强制解锁按钮。既有
Mac 保存/删除回归仍需 Mac，未因 Windows 合成通过而消除。只回传步骤、版本类别与
脱敏失败信息，不传真实身份、邮箱、组关系、凭据或原始响应。未触碰 NAS、未提交/
推送，保留所有既有脏改动及此前清理受限的忽略测试输出。其余 NAS 管理、容器/虚拟机
深层能力与系统集成仍未完成，整项目标继续保持进行中。

### 2026-09-17 电源确认与不可回读结果

先完成电源切片，再迁移连接管理。证据为 system-power-actions 文档、v3 空参数
Fixture 与 Mac Power 适配器。Windows 旧模型把 submittedButUnverified 当成功，旧
未接线弹窗使用嵌套确认且生命周期不完整。本波复用协调器与原生设置弹窗，绑定
profile/动作/请求 ID/确认，info 预检后只发送一次命令，绝不凭断线推断断电或重启
完成。接受和未知都保留待核对状态；重新登录的新会话加用户检查设备后才解除阻止，
只读连通检查不能代替物理状态确认。生产电源行为门关闭，不执行真实电源或连接写。

本波实际实现：新增 `NasPowerRequest` 与只读恢复摘要，复用现有 NAS 协调器而非原
Repository 局部信号量。固定 System v3 info，预检版本/管理员/确认/profile 后只发
一次无业务参数 shutdown/reboot。接受只表示请求被接受，未知不当成功；不回读、
不轮询断线/上线来推断最终设备状态。接受与未知均保留同客户端的按账号/NAS 隔离
挂起状态；同请求返回缓存，不同动作/新请求 ID 也不能绕过，明确拒绝才释放。

恢复仅保存高熵会话标识的不可逆摘要，不保存 SID。必须新会话且用户明确检查设备，
再通过 info 确认连接可用后解除本地阻止；此动作本身不发送电源命令，不证明设备已
完全断电或服务已恢复。旧会话、未勾选设备核对、失败重连和其他账号均不能解除。
新 ViewModel 修正旧 WasSuccessful 把未知算成功的问题，取消选择不再默认重启，
未二次确认不能执行，切换动作撤销确认，关闭/换 NAS 后迟到结果隔离。原生内容接
入现有单弹窗生命周期，默认关闭按钮，显示接受/未知提示与核对状态，移除未接线的
嵌套旧弹窗及打开 NAS 页就激活旧电源模型的路径。生产行为门独立保持关闭。

独立集成/只读对抗复核覆盖无参数请求、同 API 预检、固定版本/安全路径、管理员
字段、明确拒绝与模糊提交、取消阶段、无写后状态猜测、同客户端防重放、新会话和
用户设备核对组合、只读确认失败、跨账号/配置与迟到结果。旧测试中“未知成功”的
错误期望改为未知不得成功，并增加恢复阻止断言；没有跳过测试或降低安全断言。

实际命令（沿用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasPower -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-power-settings -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

电源聚焦 **25 通过**；全量 **2251 通过、1 失败、0 跳过（共 2252）**，唯一失败仍为
符号链接系统特权。原生 **11 场景通过**，目录 `windows/dist/ui-review-20260917-034052`，
已查看深色未知结果与浅色核对完成输出。资源 Apple 4028 / Android 2188 / Windows
2520、本地化、96 请求 fixture、3 响应组/22 私有引用和文档/差异门通过。本波没有
修改 Apple/Android 源码，既有 Mac 回归缺口仍保留。

既定 package.ps1 非交互/both/不重复测试/不自动启动流程成功发布两架构，SHA-256
均与 .sha256 一致；未安装或自动启动正式包：

- `windows/dist/20260917-034303/LanStash-0.1.0-x64.zip`
- `windows/dist/20260917-034303/LanStash-0.1.0-arm64.zip`

PENDING_USER_VALIDATION：必须专用可恢复 NAS、无进行中存储/备份/虚拟机任务并另行
授权后，验证正常关机/重启、权限拒绝、模糊响应、取消、真实新会话与人工核对流程。
不测试强制断电、Wake-on-LAN、电源日程或 UPS；核对仅表示用户检查过设备，不能
外推最终系统状态。还需目标设备的键盘/屏幕阅读器与实际网络切换验证。只回传版本
类别、操作和脱敏结果，不传 SID/账号/主机或原始响应。未触碰真实 NAS、未提交/
推送，保留既有工作区与此前清理受限的忽略生成物。下一切片为连接管理的完整目标
读取、受保护断开和恢复；任务调度、其他 NAS 能力与系统集成仍未全部完成。

### 2026-09-17 当前连接读取与断开核心

本波以 dsm-current-connection 记录、Mac Logs 适配器和 Android 已有语义测试为依据。
Windows 旧摘要伪造行号身份，旧断开使用错误的 delete/id 且空回读；先补固定 v1
完整元数据读取、http_conn/service_conn 最小目标、确认基线及原始 DID/PID 回读。
缺失标识或许可仅只读，当前状态未知不猜成其他连接，完整目录不足时不证明消失。
原生完整管理随后集成，生产门关闭，不触发真实连接断开。Mac 发现同类派生 ID 与
空列表误判时按授权一并修正，目标回归不能用 Windows 测试替代。

本波实际完成：新增内存连接模型与完整快照，DID/PID 默认 JSON 忽略且字符串化
不输出连接内容；显示行摘要与真实断开目标分离。固定 v1 start/limit/sort_by/
sort_direction 读取，严格 items 根/类型/总数，缺失目标字段仅查看，重复身份不允许
操作。NAS 摘要与旧 Workspace 复用同一读取，分别显示失败、未知当前状态和不完整
目录，不再使用行号伪造操作身份，也不把无时区的 NAS 时间转换为本机时间。

断开核心复用现有协调器、版本/管理员门与单目标挂起状态，确认绑定完整元数据。
网页只发 http_conn 的 did/descr/who/from，服务只发 service_conn 的 pid/type/who/from，
另一数组明确为空。当前或未知当前标志要求额外确认。明确接受最多四次 500ms 间隔
只读核对，模糊提交仅一次；原始 DID/PID 仍存在或缺标识相似条目不能被排除时未知，
不依赖派生行 ID/分类/时间变化判断成功。失败和不完整列表不能证明消失；未知不能
用新请求重发，同客户端重建可恢复，最终结果释放不再需要的原始目标数据。

按授权同步 Mac 同类修正：严格列表和元数据，用系统 CryptoKit 的摘要作为显示 ID
而非原始标识或时间拼接；没有增加第三方依赖或最低系统要求。重复原始目标失败，
发送前重读完整字段，不补造必需空值；回读使用当前成功加载而非旧缓存，并比较
原始设备/进程标识。未知不建议重试，不凭用户名标记当前连接，网页连接均提示可能
使本应用掉线。Mac 原生管理确认/结果逻辑仍须目标回归；Windows 原生完整连接页
下一切片接入，本波不将读取/核心测试等同完整 UI 交付。

独立集成/只读对抗复核覆盖固定版本与 JSON 字符串编码、确认和当前会话风险、
原始身份与显示身份分离、完整快照漂移、字段缺失/重复/变型、不完整列表、同目标
互斥、模糊响应、取消、回读无重放、跨账号恢复及敏感标识生命周期。现有摘要测试
fixture 改为已记录 items 字段，保留隐私和内容断言；未通过放宽断言隐藏错误。

实际命令（使用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasConnectionMutationTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增连接聚焦 **27 通过**；全量 **2278 通过、1 失败、0 跳过（共 2279）**，唯一失败
仍为本机符号链接特权。x64/ARM64 Release 均 **0 警告/0 错误**。资源 Apple 4029 /
Android 2188 / Windows 2522、本地化、96 请求 fixture、3 响应组/22 私有引用及文档/
差异门通过。Swift 命令不可用，新增 4 项网络测试和 2 项 Mac 模型回归未运行；本波
未执行原生连接管理场景，也未重新打包，旧测试归档不含这些最新改动。

PENDING_USER_VALIDATION：接入 Windows 原生管理后，在另行授权的专用测试会话验证
网页/服务连接、当前会话额外确认、连接自然结束、DID/PID 复用、断线/取消/重新登录
及界面恢复。Mac 运行共享层与 App 回归，特别检查派生 ID 变化、完整新回读和缺失
标识条目。大于有界范围或无法排除原目标时只读/未知，不强行解锁重放。Apple 移动
端需回归共享层影响；Android 本波未改源码，只同步评估。不传真实账号、地址、位置、
DID/PID、SID 或响应；未触碰真实 NAS、未提交/推送，保留所有既有工作区改动。
整项目标未完成，下一切片继续原生连接管理，任务调度及其他系统集成仍待推进。

### 2026-09-17 原生连接管理

本波接入前轮连接核心：原生列表、搜索、完整目标确认、当前/未知当前的额外确认、
持久反馈与只读恢复。显示标识与操作标识继续分离，待核对目标按不含原始标识的
摘要绑定；协议分类变化但仍共享原始目标时，也不能从界面绕过挂起阻止。只读列表
不展示 DID/PID，部分目录和缺失/歧义身份不启用断开。复用既有弹窗和协调器，
不修改其他平台、不开放生产门，不执行真实连接断开。

本波实际完成：`NasConnectionManagementViewModel` 与原生内容接入现有 NAS 菜单/单
弹窗生命周期，提供账号/来源/服务搜索、完整目标选择、确认和持续反馈。当前或
未知当前状态需要额外确认准备重新登录；复选框顺序不影响可用性，切换目标或搜索
都会失效，执行前同步实际控件。部分目录、缺少必要字段、歧义身份及挂起目标只读。
加载/空/搜索为空/错误/内容/恢复均独立呈现，不暴露原始 DID/PID。

原始标识关联只以摘要供界面阻止判定，核心仍从原始字段计算，不信任调用方的显示
键。协议分类变化但共享待核对原始目标时，UI 和 Repository 都阻止新的断开。恢复
摘要含可读说明，不含原始设备/进程标识；原目标已不在当前列表也可核对。成功后刷新
数据，未知只恢复读取，切换配置/关闭取消旧任务并忽略迟到结果。无新副作用、网络
参数、依赖、存储或其他平台源码变更，生产写门仍关闭。

独立集成与只读对抗复核覆盖目标及关联身份一致性、当前/未知当前确认、不同勾选
顺序、确认失效、原生控件同步、权限与不完整目录失败关闭、并发刷新/重复提交、
恢复信息保护、跨配置回调和关闭取消。没有以修改断言隐藏失败，没有真实连接断开。

实际命令（沿用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasConnection -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-connection-settings -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

连接聚焦 **38 通过**（新增 11 项模型测试并加强原核心关联身份断言），全量 **2289
通过、1 失败、0 跳过（共 2290）**；唯一失败仍为本机符号链接特权，未跳过。原生
**22 场景通过**，目录 `windows/dist/ui-review-20260917-042807`；已查看浅色只读和
深色未知结果。资源 Apple 4029 / Android 2188 / Windows 2551、本地化、96 请求
fixture、3 响应组/22 私有引用及文档/差异门通过。

既定 package.ps1 非交互/both/不重复测试/不自动启动流程成功发布两架构，SHA-256
均与 .sha256 一致，未安装或自动启动正式包：

- `windows/dist/20260917-043045/LanStash-0.1.0-x64.zip`
- `windows/dist/20260917-043045/LanStash-0.1.0-arm64.zip`

PENDING_USER_VALIDATION：另行授权专用测试会话后，验证网页/服务连接、当前连接
掉线、重新登录、身份复用/缺失、部分目录和模糊提交恢复，另做 Narrator/键盘/触控/
缩放验收。无法排除原目标时保持未知，不提供强制重放。此前 Mac 共享/App 修正仍
待 Mac 回归，不以本波 Windows 通过替代。只回传版本类别、操作及脱敏结果，不传
真实账号、来源地址、位置、DID/PID、会话或原始响应。未触碰 NAS、未提交/推送，
保留所有既有工作区改动及此前清理受限的忽略产物。任务调度、其他 NAS 能力和系统
集成仍未完成，整项目标继续进行。

### 2026-09-17 任务计划读取契约与适配

本波以 DSM_WEB_API_REFERENCE_ZH.md 8.5、现有兼容索引和 Mac v3/v4/v1 测试为来源，
把已有任务计划记录拆为独立端点文档，不探测新的 NAS 接口或运行真实任务。Windows
先完成列表 v3、详情/创建模板 get v4、EventScheduler 结果/输出 v1 的只读调用，
严格身份、方法版本和数据类型，保留未知计划字段，脚本/通知/输出不进入日志或默认
JSON 导出。现有摘要共用读取，后续再接操作与原生界面；Mac 同类读取缺陷按授权修正。

本波实际完成：独立任务计划端点文档整理既有证据，并在原 dsm-administration 索引
补方法级引用和 EventScheduler v1 说明；未新增真实发现或提升证据等级。Windows
新增任务列表、详情、计划、结果、输出模型和统一只读适配，列表 v3、详情/创建模板
get v4、结果/输出 v1 分别固定；空 real_owner 省略，其余选择器不依据翻译或行号。
列表按数字 ID/real_owner 拒绝重复身份，保留未知许可和启用状态；摘要只做隐私投影。
详情字段缺失保持可空，整数不截断小数；结果只接受已记录直接数组或 results 根，
拒绝串任务、重复 ID 和冲突退出信息。输出空文本与缺失不同，保持原始空白。

读取网关仅放行精确方法/版本/参数集合，直接数组封装只限 EventScheduler.result_list，
不会开放写方法或其他泛化数组 fallback。脚本、通知地址、命令与输出不进默认 JSON
和字符串化；列表不预取详情或输出，也不执行返回内容。模板值来自 get -1/script，
不从本机时间或猜测默认计划补齐。

Mac 同类修正：列表不伪造 ID，严格数字与许可类型，未知启用不允许进入编辑；关键
详情、时分与重复配置缺失时拒绝，不自动变成零点或每天。原有可选 monthly_week
兼容仍保留，未验证条件字段不能外推可写。结果/输出固定 EventScheduler v1，畸形
根、重复/串任务和字段冲突不当作空记录；字符串保留空值，选择器不裁剪后读取别的
任务。新增 3 项 Swift 参数化回归未运行，不以 Windows 编译替代。

独立集成/只读对抗复核覆盖固定版本交集、严格路径和预取消、不同方法参数隔离、
未知值不补默认、创建模板、所有者与数字身份、结果归属、退出字段冲突、返回脚本
不执行/不预取/不导出，以及字段类型和数组根失败语义。旧摘要 fixture 的伪 id
改成契约中的数字 id，保留内容/隐私断言，没有降低测试强度。

实际命令（使用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasTaskReadTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增任务读取聚焦 **22 通过**；与既有摘要合跑 **41 通过**。最终全量 **2311 通过、
1 失败、0 跳过（共 2312）**，唯一失败仍是符号链接系统特权，未跳过。最终 x64/
ARM64 Release **0 警告/0 错误**；资源数量不变，Apple 4029 / Android 2188 / Windows
2551，本地化、96 请求 fixture、3 响应组/22 私有引用和文档/差异门通过。Swift 命令
不可用；未执行 Mac 回归或原生任务界面合成，未重新打包旧测试归档。

PENDING_USER_VALIDATION：Mac 运行共享回归，核对真实详情模板可选字段、计划类型、
结果根、权限、长输出和脚本/通知隐私；iPhone/iPad 回归共享层影响，Android 本波
不改源码。Windows 待后续管理核心和原生调用链完成后验证真实读取与授权的专用
无害任务，不把读取通过外推为计划生效或运行成功。只回传步骤、版本类别和脱敏
错误，不提交任务脚本、邮件地址、命令/输出、主机、账号或凭据。未触碰 NAS、未
提交/推送，保留既有工作区改动。下一切片是任务管理操作及对应安全与恢复链；
完整目标仍未完成，不因本读取切片结束而缩小范围。

### 2026-09-17 任务启停/运行/删除核心

本波沿用已记录 TaskScheduler v3 run/set_enable/delete 与 v4 详情，不新探测写接口。
确认绑定任务 ID、原始 real_owner、许可和配置；脚本启用/运行还核对用户预览的 v4
详情，避免列表未变而脚本内容已变化。运行只确认接受，不凭新运行记录猜测本次脚本
成功；模糊运行保持未知不重放。启停/删除通过严格列表回读，所有动作共用协调器。
生产行为门关闭，本波仅核心和测试，原生管理与新建/编辑继续后续切片；Mac 同类
目标/缓存校验问题按授权修复，真实任务不得执行。

本波实际完成：新增 `NasTaskCommandRequest` 与启停/运行/删除独立能力，复用现有
NAS 协调器和同任务 ID 挂起状态。固定 v3 命令不发送脚本/计划，real_owner 只取
列表原值，不从执行 owner 猜测。预检明确管理员、许可、完整列表基线；脚本启用/
运行还核对 v4 详情摘要（含代码和通知内容的摘要，不在恢复对象保存内容），启用
要求关键计划字段完整。无变化启停、错误版本、确认缺失、预览缺失和状态漂移零写入。

启停通过同一 ID/real_owner 回读，删除须原数字 ID 完全消失，所有者变化不算删除。
运行无可靠关联标识，只把明确响应标为 task.run.accepted，不查最新历史记录推断
脚本成功；模糊运行保留未知，同目标其他命令和新 ID 都不能绕过，不自动重发。
取消与明确拒绝分开处理；同客户端重建可枚举/核对挂起目标，其他账号隔离。
生产启停/运行/删除开关各自关闭，创建/编辑和原生管理仍待后续。

按用户同类修复授权，Mac 命令模型新增完整列表预检，不再将 owner 作为缺失的
real_owner；启停/删除只用当前成功加载的新列表，不用旧缓存证明结果。模糊错误
统一不可重试未确认提示；运行仅代表接受。负数任务 ID 拒绝。新增三项 Mac 模型
回归，未在当前 Windows 环境运行。没有修改 Apple 公开协议、存储或其他平台代码。

独立集成/只读对抗复核覆盖固定版本与字段、执行用户不猜测、任务与代码快照、
未知计划值、运行与执行结果分离、任务 ID/所有者变化、空/畸形回读、重复请求、
同目标跨动作互斥、权限和取消阶段、恢复敏感信息最小化与各生产门关闭。

实际命令（使用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter "FullyQualifiedName~NasTaskCommandTests|FullyQualifiedName~NasTaskReadTests" -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasTaskCommandTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增命令测试 **22 通过**，与读取合跑 **44 通过**；全量 **2333 通过、1 失败、0 跳过
（共 2334）**，唯一失败仍为本机符号链接特权。x64/ARM64 Release **0 警告/0 错误**。
资源 Apple 4031 / Android 2188 / Windows 2551、本地化、96 请求 fixture、3 响应组/
22 私有引用及文档/差异门通过。Swift 不可用，Mac 新回归未运行；本波没有原生任务
操作场景或重新打包，旧测试归档不包含本批命令核心。

PENDING_USER_VALIDATION：后续接原生管理并完善创建/编辑后，在另行授权的专用无害
任务环境验证启停、运行接受/实际执行区分、结果归属、权限变化、断线/取消和恢复。
未知运行须人工核查，不提供未经验证的强制解锁；停用仅影响调度，不宣称终止正在
执行的脚本。Mac 需执行模型/共享回归，移动端评估共享契约，Android 本波不改。
不回传脚本、邮箱、任务内容或原始响应，只提供版本类别和脱敏失败。未触碰真实
NAS、未提交/推送，保留所有既有工作区改动；整项目标仍未完成。

### 2026-09-17 脚本任务创建与编辑核心

本波以已有 get/create/set v4、Mac taskScheduleParameters 和 ScheduledTaskEditor 为
证据，编辑名称、执行用户、启用、脚本、通知、时分与星期；其他已返回计划字段保持
原值，不猜测新的日期类型编码。创建使用服务器模板，编辑绑定列表与详情双基线，
保存和命令共享目标阻止，写后读取完整配置，脚本不进入恢复缓存。原生编辑后续接入，
生产门关闭，不在 NAS 上创建任务或执行脚本；Mac 同类“只按名称/ID判断保存”需修正。

本波实际完成：新增 `NasTaskSaveRequest`、共用保存规则和 v4 create/set 核心。创建
基线来自 get(-1/script)，编辑同时绑定列表与详情，selector/数字 ID 不可混用；预检
明确管理员、权限、重名、模板和完整详情漂移。按 Mac 当前编辑器仅改时分/星期及
名称、执行用户、启用、脚本和通知，其余日期/重复策略保持原值；未知可选字段不补
造，变更 opaque 编码或覆盖未知关键字段失败关闭。月周数组在首次 await 前复制，
防调用方修改确认后的集合。

保存与已有任务命令共享协调器及目标阻止；创建未确认时也按名称/执行用户阻止
其他命令绕过。请求参数仅按已记录 v4 构建，脚本和通知在当次请求后释放；恢复仅
保存配置摘要、任务身份与字段是否发送，不保存原始脚本或邮箱。保存后先找唯一
目标，再 get v4 比对完整提交配置，不把 ID/名称存在当作成功；模糊响应只回读，不
重放。明确拒绝、取消、未知、确认成功分别处理，生产保存门保持关闭。

Mac 编辑器把原始详情快照传回模型；保存前核对列表和详情，保存后以新读取的列表
及详情验证脚本/用户/通知/计划，修复原来仅检查 ID/名称的问题。顶部启用开关在保存
期间禁用，提交草稿在异步任务创建前复制。没有修改 Apple 公开协议或存储，新增
三项模型回归未运行；不以 Windows 结果替代 Mac 验收。

独立集成/只读对抗复核覆盖模板与选择器、列表/详情双基线、原始 real_owner、执行
身份、opaque 计划保留、缺失字段、集合快照、同目标保存/命令互斥、唯一创建候选、
完整回读、取消/拒绝/模糊响应、恢复数据最小化和生产门关闭。

实际命令（沿用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasTask -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增保存 **17 项**，任务聚焦 **61 通过**；全量 **2350 通过、1 失败、0 跳过（共 2351）**，
唯一失败仍是系统符号链接特权。x64/ARM64 Release 均 **0 警告/0 错误**。资源数保持
Apple 4031 / Android 2188 / Windows 2551，本地化、96 请求 fixture、3 响应组/22
私有引用及文档/差异门通过。Swift 命令不可用；本波没有原生任务编辑场景或重新
打包，旧测试归档不包含这些新增保存核心。

PENDING_USER_VALIDATION：下一切片接原生任务管理、编辑和运行记录，再在另行授权
的专用无害任务上验证模板、时分/星期、通知、执行用户、脚本字节、异常保存/恢复
及计划实际生效。恢复未确认时不强行重发；只回传版本类别、步骤及脱敏错误，不传
脚本、输出、通知地址、主机、账号或会话。Mac 需执行新增共享/App/编辑器回归，
Android 本波不改源码，Apple 移动端评估共享层影响。未触碰真实 NAS、未提交/推送，
保留全部既有工作区改动。原生管理和其他系统集成仍待完成，整项目标保持进行中。

### 2026-09-17 任务管理交互状态层

先接任务管理 ViewModel 的完整读取/编辑/命令/结果流，再装配原生控件。沿用既有
Repository，不另建请求实现；脚本预览、结果输出按需读取，切换目标或关闭清除。
危险操作绑定当前任务/详情/草稿确认，执行时阻止并发刷新，未知不重放。列表、详情、
运行记录与输出的取消和迟到结果按同一上下文隔离，生产写门仍不开放。

本波实际实现：新增 `NasTaskManagementViewModel` 与对应测试，连接既有列表、详情、
模板、创建/编辑、四项命令、恢复、运行记录和输出读取。以 macOS
`NasAdministrationModel.swift`/`NasAdministrationView.swift` 的任务列表、编辑器和
结果查看为语义证据，交互转换为 Windows 窗口内选择/编辑/确认状态；尚未装配原生
控件，不将状态层完成等同于用户主流程可用。单一修改范围为该 ViewModel/测试、
共享命令预览规则及既有 Repository 调用点、Windows 双语资源、账本与状态摘要；
本波不改变 API 契约、持久化、Apple/Android 源码或生产写门。

确认绑定当前不可变草稿及任务，修改草稿或能力关闭会使确认失效。运行仅反馈请求
已接受，不报告脚本成功；未知保存/命令只核查、不重放。成功保存后的列表刷新失败
保留已经验证的操作结果，同时禁用后续写入直到重新读取成功。详情、脚本、通知和
输出在切换任务/配置、关闭或提交时清除；列表不预读脚本，记录不预读输出。未读取、
读取为空和读取失败有独立状态，不将旧任务的迟到响应填入新任务。

独立集成与只读对抗复核覆盖确认失效、能力撤回、写期间重复操作、配置切换取消、
迟到详情/输出、结果归属、保存/命令恢复、成功后刷新失败和敏感数据生命周期。脚本
Enable/Run 预览校验抽取为既有 Domain 规则，由界面状态与 Repository 共用，网络
前置核对与最终回读仍保留，未建立第二套请求实现。

实际验证（dotnet/Python 使用前述本机绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasTask -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增状态层 **17 项**，任务聚焦 **78 通过**。最终全量 **2367 通过、1 失败、0 跳过
（共 2368）**；失败仍为符号链接特权缺失。本波较早一次全量还出现既有 Chat
`ConnectedUsesSlowerCalibrationAndDisconnectRestoresPolling` 时序失败，最终运行通过；
未修改该测试或以重跑消除其不稳定风险。x64/ARM64 Release 均 **0 警告/0 错误**。
本地化通过（Apple 4031 / Android 2188 / Windows 2563），96 请求 fixture 与
3 响应组/22 私有文档引用通过。本波不重新打包、不运行原生任务场景，不将旧包当作
包含本轮实现的新交付物。

原生任务控件、五态/双语/浅深色/键盘验收是下一实现切片，不属于已完成项。
PENDING_USER_VALIDATION：在原生流程接好后，由用户另行授权专用无害任务验证创建、
编辑、启停、运行、删除及记录/输出，确认未知操作不会重发、切换目标不会残留脚本；
回传仅版本类别、步骤和脱敏错误，禁止脚本、输出、通知地址或会话信息。Mac 既有
修正仍需 Mac 环境执行回归。本波未接触真实 NAS、未提交/推送，保留已有未提交
改动及此前清理受限的忽略产物；完整对齐目标仍在进行。

### 2026-09-17 原生任务管理接线

本波单一修改范围为任务管理 WinUI 控件、NAS 设置入口、任务状态层必要修正、双语
资源及任务合成场景。macOS 证据为 `NasAdministrationView.swift` 的
`ScheduledTaskList/ScheduledTaskEditor/ScheduledTaskResultsSheet`，Windows 用同窗
列表、详情、编辑与确认面板替代菜单/Sheet。沿用已记录 TaskScheduler v3/v4 和
EventScheduler v1，不增加 API 或修改 Apple/Android。本波目标覆盖新建、编辑、
启停、运行、删除、记录和输出；写门与原有权限/确认/去重/回读保护不变。完成后运行
原生合成场景、双语/五态、聚焦测试及 x64/ARM64 构建；真实危险写后置专用环境验收。

本波实际完成：`NasTasksSettingsDialogContent` 通过既有单一设置对话框接入 NAS 菜单，
列表可搜索，新建读取模板、编辑保留原计划字段；任务详情、脚本预览、执行用户、
时分/星期、通知收件人和错误通知均可呈现。启停、运行、删除和保存使用各自明确
动作及确认，运行不报告脚本已成功。记录与输出按需读取，关闭详情/窗口清除敏感
控件；未读取和空记录不同，未知详情显示提示。编辑/详情内隐藏列表，避免长脚本
和通知配置被上方列表挤占，所有内容留在可滚动的原生面板。

实际输入在确认和提交前重新读取，覆盖 WinUI 延迟 TextChanged：已确认后立即改
脚本再提交被阻止；按钮/确认权限继续取状态层和 Repository，未绕过行为开关。
独立集成及只读对抗复核覆盖入口 profile 检查、同窗单一实例、双基线保存、草稿
快照、只读能力、原始任务/结果身份、迟到响应、重复按钮、未知恢复与敏感控件清除。
未新增网络契约或改变生产权限/持久化。43 个新 Windows 资源键同时提供中英文。

本轮新增 `run.ps1 -Language`，并在 App/Application 两个合成构建程序集传递既有
`LANSTASH_UI_SMOKE` 条件符号，语言只在内存中覆盖、不写用户偏好；正式构建不包含
该覆盖。首次英文场景虽然业务断言通过，但截图仍为中文，不能计为英文验收；检查
确认本地化文件属于 Application 后修正条件符号，新增请求语言与实际语言一致的
断言，并重新检查英文图片。未修改工具链、依赖、签名或最低系统。

实际命令（使用前述 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter "FullyQualifiedName~NasTask|FullyQualifiedName~NasDetailsPageSourceContractTests" -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-task-settings -WindowWidth 900 -PaneState compact -Language zh-CN
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-task-settings -States task-edit-preview,task-output,task-create -WindowWidth 900 -PaneState compact -Language en-US
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios nas-task-settings -States task-edit-preview -WindowWidth 900 -PaneState compact -Language zh-CN
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

任务/入口聚焦 **85 通过**；全量 **2368 通过、1 失败、0 跳过（共 2369）**，唯一
失败仍是创建符号链接缺少系统特权，未调整断言或跳过。x64/ARM64 Release 均通过，
独立构建各为 **0 警告/0 错误**。本地化通过（Apple 4031 / Android 2188 /
Windows 2606）、96 请求 fixture、3 响应组/22 私有引用及文档/差异门通过。

中文任务原生场景 **23 通过**，位于忽略的
`windows/dist/ui-review-20260917-060847`；修正语言测试配置后英文 **5 通过**，位于
`windows/dist/ui-review-20260917-061303`，另中文确认区键盘聚焦浅深色 **2 通过**，
位于 `windows/dist/ui-review-20260917-061401`。人工读取合成图片复核中英文详情、
输出及确认区浅深色和键盘焦点；它们不是桌面截图或真实 NAS 证据。完整屏幕阅读器、
系统缩放和真实长输出仍为待用户验证。

使用既有 `windows/package.ps1`（`LANSTASH_NON_INTERACTIVE=1`、
`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`）
生成独立归档，不安装/启动，测试已在上列命令单独执行：

- `windows/dist/20260917-061151/LanStash-0.1.0-x64.zip`，SHA-256
  `AE4CE48EC867A7B916D6EF8032F0FC6484A6974DECACA16DB9B6D4C721CCCCB8`。
- `windows/dist/20260917-061151/LanStash-0.1.0-arm64.zip`，SHA-256
  `8CCE45082E069D52458055B3AC5273EA6F3B07A4D1E696199DF0169B8E883FE7`。

两包已与 `.sha256` 文件比对通过，包含任务原生流程但生产私有写仍关闭；打包后的
唯一构建配置补充只影响合成宿主语言覆盖，不改变正式二进制业务逻辑。
PENDING_USER_VALIDATION：用户可先验证真实任务列表/详情/记录/输出，提供版本类别、
操作步骤和脱敏失败信息，不传脚本、通知地址、输出或会话。写验收仍需另行授权
专用无害任务后验证权限、确认失效、未知结果、计划生效及实际脚本结果，不能因
合成成功解锁当前真实环境。Mac 既有修正仍待 Mac 回归。本波未触碰真实 NAS、未
提交/推送，保留其他未提交改动和此前清理受限的忽略产物。下一独立切片继续核查
NAS 存储/硬盘检测等剩余管理差距；Container/VMM、系统集成和整体实机验收仍未完成，
整项目标保持进行中。

### 2026-09-17 硬盘检测读取与错误旧入口收敛

本波对照 `DsmNasAdministrationRepository+Storage.swift` 与 Repository 的
`loadDiskTestStatus/loadDiskTestHistory`，契约来源为 `dsm-smart-test.md` 既有 v1
记录。先补 Windows 稳定目标、状态/最近历史读取及真实 HTTP 合成测试，移除旧的
`Storage.disk_test(disk_id,extended)` 猜测写调用；缺少确认基线的旧签名仅返回不支持。
后续接正确启停核心和原生面板，不以只读层完成冒充完整检测功能。单一修改范围为
Windows Disk partial、领域增量、读取传输白名单及测试；Mac 同类缺失状态被当作
未运行的证据修正与必要测试也在用户授权内，Android 本波不修改。
安全级别为内部只读/高风险写前置；真实硬盘检测不启动、不停止，不升级真实证据。

本波实际完成：新增 `NasDiskTestModels` 和向后兼容 Repository 默认读取方法；
`DsmRepository.NasSettings.DiskTests.cs` 固定读取 Storage.load_info v1 与 Disk 两项
v1 方法，每次状态/历史读取重新核对稳定目标，不把界面 id 当作 device。缺失检测
支持保留未知；状态必须唯一，运行布尔、检测类型、别名与可选响应设备需一致。
其他检测忙碌标志缺失时保留未知，不伪造空闲；历史独立读取并明确 100 条边界或
服务器 total 截断。FORM/JSON 按声明编码业务字段，通用读取白名单不开放任何写方法。
旧 StartDiskTestAsync 缺少确认快照，仅返回不支持/取消/校验失败且零网络写请求。

Apple 同类证据修正包含存储列表拒绝伪造/重复目标，不从健康状态推断检测许可，
状态缺失、冲突、异盘和未知类型拒绝解码，畸形历史返回不可用；所有相关读写方法
显式固定 v1。当前 Apple 状态模型没有未知占用值，因此非运行且无法确定其他检测
占用时失败关闭。已有有效测试 fixture 补明确许可/占用字段，保留原业务断言；新增
四项测试方法覆盖上述故障。本机无 Swift，未把静态检查表述为 Mac 测试通过。

独立集成/只读对抗复核覆盖旧入口零写、v1 白名单、设备身份/许可重新读取、换盘、
别名归一、未知状态、100 条边界、取消及本地化错误。后续启停切片仍需处理 Mac
`validatedStorageDisk` 的缓存优先行为及状态/历史缓存与稳定设备绑定；本波不宣称
完整启停隔离已经修好。Windows 新增领域接口为已授权的向后兼容增量，不改变共享
网络契约、存储或权限；iPhone/iPad 需回归共享 Apple 影响，Android 只记录影响。

实际命令（沿用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDiskTestReadTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

硬盘新增 **19 通过**；全量 **2387 通过、1 失败、0 跳过（共 2388）**，唯一失败仍
为 Windows 创建符号链接缺少特权；未跳过、未修改断言。x64/ARM64 Release 均
**0 警告/0 错误**。首次 JSON 用例暴露通用读取层仍拒绝该端点的声明，修正为严格
方法级例外后 19 项全过。Swift 命令不可用，四项 Mac 方法及既有回归均未运行。
本波未新增界面文案（资源保持 Apple 4031 / Android 2188 / Windows 2606），未运行
原生硬盘场景、未重新打包；前轮测试归档不包含本波新增硬盘读取。

PENDING_USER_VALIDATION：待正确启停核心与原生面板接好，再由用户在专用无害硬盘
上另行授权验证快速/完整/停止、忙碌、目标变化与断网结果；当前不允许真实检测写。
Mac 先运行共享网络测试及存储页面回归；反馈只包含版本类别、操作步骤和脱敏错误，
不提供设备标识、序列号、日志正文或会话。未操作真实 NAS、未提交/推送，保留所有
既有改动和此前清理受限的忽略产物。下一切片接正确命令/恢复链，整项目标仍未完成。

### 2026-09-17 硬盘检测命令与未知结果恢复

本波沿用 `dsm-smart-test.md` 固定 Disk.do_smart_test v1 和 quick/extend/stop 参数，
参考 Mac `changeDiskTestResult` 的预检、六次回读和提交后取消核查。Windows 目标是
同一客户端跨页面/Repository 的稳定设备锁、确认快照和不重放恢复；启动仅确认检测
运行且类型匹配，不代表健康或检测完成。单一修改范围为 Disk 命令 partial、领域
增量、既有共享写协调器注册、生产关闭门和正式合成测试。真实写不执行，原生界面
为下一切片；当前无 Swift 环境，Mac 缓存绑定缺口另行处理并不宣称已修完。

本波实际完成：新增 `NasDiskTestRequest/Command/Recovery` 和默认接口增量，独立
`DiskCommands` partial 使用现有共享写协调器、操作 ID 缓存及 profile/account/地址
作用域。快速、完整、停止按相同 id 或 device 阻止未确认期间再次提交；重建页面或
Repository 不解锁。同一请求完成后复用结果，未知时只核查，不发送第二次写。
预检明确管理员/登记版本、原始设备身份、检测支持和运行/占用基线，名称与进度的
自然变化不属于目标冲突。发送 v1 `do_smart_test`，参数仅 device 与 quick/extend/stop。

正常提交和模糊提交均最多六次只读核查（间隔一秒），每次重新核对设备清单再读取
状态。启动只确认对应检测类型正在运行，停止只确认明确非运行，不以接受回执、
历史或硬盘健康推断完成。提交后取消只额外做一次独立 15 秒超时核查；错误仍未知
时保留恢复记录，换盘、权限/认证/结构问题不会被当成成功或自动重发。

故障注入暴露共用固定读取把 HttpRequestException/网络超时转换为无类别 DsmException，
导致暂时断线立即终止核查。按既有 Windows 领域增量授权追加两个错误 Kind，并在
固定只读传输转换处保留分类；不按翻译文案判断。仅网络/超时继续有限核查，权限、
认证、不支持与结构错误保留分类并停止。该增量不改变 wire 请求、持久化、既有
枚举值、依赖或签名；影响 Windows 所有固定只读调用的错误元数据，因此运行全量
Windows 回归。其余四端无网络契约变化，Apple/Android 本波不改源码。

独立集成/只读对抗复核覆盖环境/管理员门、确认快照、原始 device、同目标与别名
互斥、请求 ID 重用、跨账号隔离、未知恢复、换盘后的回读、类型匹配、错误分类、
取消和有限轮询。`NasDiskTestBehaviorValidated=false`，旧无确认签名仍禁止写入。

实际命令（沿用既有 dotnet/Python 绝对路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDiskTest -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增命令 **18 项**；硬盘聚焦 **37 通过**；全量 **2405 通过、1 失败、0 跳过
（共 2406）**，唯一失败仍为系统符号链接特权。初次编译触发 xUnit2031，改用
`Assert.Single` 的谓词重载、未改变断言；随后网络重试用例失败并按上述类型分类
修正后全过。x64/ARM64 Release 均 **0 警告/0 错误**。本地化资源数保持
4031/2188/2606，96 请求 fixture、3 响应组/22 私有引用、本地化及文档/差异门通过。
未打包、未运行原生硬盘场景；旧测试归档不包含本波硬盘命令。

PENDING_USER_VALIDATION：原生流程接入后，在用户另行授权的专用硬盘上验证快速/
完整/停止、占用、权限、断网、取消与状态反馈，回传版本类别和脱敏错误，禁止
设备标识、序列号、日志或会话。本波无真实 NAS 操作、无提交/推送，保留其他未提交
改动与此前清理受限的忽略产物。Mac 缓存目标/历史绑定问题及其 Mac 回归仍待处理；
下一切片接 Windows 原生硬盘管理，整项目标不因核心合成通过而完成。

### 2026-09-17 原生硬盘检测工作流

本波单一修改范围为 Windows 硬盘管理状态层/原生面板、NAS 菜单接线、双语资源和
聚焦/原生合成测试。对照 Mac `NasAdministrationView` 硬盘检测及历史、Model 的
启停反馈；沿用已完成 Disk v1 核心，不新增私有请求。Windows 用户流程为选择硬盘、
读取当前状态、按需历史、选择快速/完整/停止并确认、核对未知结果；未运行/未知/
其他检测占用不得混淆，生产写门继续关闭。Mac 缓存问题仍单独待处理，不以 Windows
UI 验证替代；本波不操作真实 NAS。

本波实际完成：`NasDiskTestViewModel` 和 `NasDiskTestsDialogContent` 接入现有单一
NAS 设置对话框。支持名称搜索、硬盘选择、独立状态/历史错误、最近记录与截断提示、
三种命令选择和明确确认、结果反馈与未知操作重新核查。未知支持或其他检测占用
不允许启动；列表不预读历史，历史错误不替代当前状态。普通界面不显示 device/id，
时间按 App 语言格式呈现，无法解析的服务端值保留原文、不伪造时间。

重新检查 Mac `NasAdministrationView.swift:4250` 附近的运行中任务后，补齐四秒
只读刷新：仅已知运行、没有已选择命令或未知操作时刷新，确认期间不打断用户，
关闭窗口/切换配置取消并停止计时；结束时只更新此前已打开的历史。模型按请求
代次隔离迟到状态/历史，选择/筛选/刷新使旧确认失效；提交前再次同步实际控件
选择，避免延迟 UI 事件绕过确认。已确认命令后的界面刷新失败不覆盖既有成功
结果，未知始终保留核查提示、不重发。未新增 API、权限或持久化格式。

独立集成与只读对抗复核覆盖入口 profile、重复窗口、目标切换、搜索隐藏目标、
确认失效、readonly/未知/忙碌、迟到响应、历史独立失败、写入期间关闭与取消、
轮询生命周期及生产门。新增 44 个 Windows 用户资源键，中英文同时提供。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasDiskTest -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-disk-tests -Language zh-CN -WindowWidth 900 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios nas-disk-tests -States disk-confirm,disk-history,disk-busy-unknown -Language en-US -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增状态层 **11 项**；硬盘聚焦 **48 通过**；全量 **2416 通过、1 失败、0 跳过
（共 2417）**，唯一失败仍为系统符号链接特权。WinUI x64/ARM64 Release 构建通过，
单独构建各 **0 警告/0 错误**，之后既有打包流程构建最终版本。资源数为 Apple 4031 /
Android 2188 / Windows 2650；本地化、96 请求 fixture、3 响应组/22 私有引用及
文档/差异门通过。

中文原生 **24 场景通过**，合成图位于忽略的
`windows/dist/ui-review-20260917-064850`；英文 **5 场景通过**，位于
`windows/dist/ui-review-20260917-065114`。读取实际渲染图片复核中英文浅深色、历史
和风险确认区、键盘聚焦；不是桌面截图或真实 NAS 验证。未知占用、真实只读权限、
触控/完整屏幕阅读器、不同缩放及长列表仍待用户验收。

本波通过既有 `windows/package.ps1`、both 平台、禁用自动安装/启动生成独立包，
测试由上列命令单独执行，生产检测写门未开放。PENDING_USER_VALIDATION：先验证
真实硬盘选择、当前状态与历史；三种检测写须另行授权专用无害硬盘，核对负载、
状态、取消/断网结果及健康结果是否与 DSM 一致。反馈仅版本类别、步骤和脱敏
错误，不传设备标识、序列号、日志或凭据。Mac 缓存目标/历史绑定修复与 Mac 回归
仍待进行；本波无 Apple/Android 修改、无真实 NAS 操作、无提交/推送，保留其他
未提交改动和此前清理受限的忽略产物。下一切片先修 Mac 缓存绑定，再继续剩余
NAS/Container/VMM 和系统集成，整项目标仍未完成。

本波独立归档及已核对 `.sha256`：

- `windows/dist/20260917-065139/LanStash-0.1.0-x64.zip`：
  `38A29CF476D361F10A60CC97F6EB1EDA522B97AB46380E6DFBFBB4F216C8CDC7`。
- `windows/dist/20260917-065139/LanStash-0.1.0-arm64.zip`：
  `9D719EE8904B07D4B3046C25FF77D874BA815E7F9E72FAC292212A84912BB150`。

### 2026-09-17 Mac 硬盘缓存和反馈绑定修复

本波按用户已授权的同类缺陷修复范围，仅修改 Apple Repository/Storage 缓存、
Mac Model 与相关测试。证据为历史按 id 缓存、状态请求缺少代次、存储刷新不清除
换盘状态，以及旧运行状态能覆盖未知 MutationResult、成功后补造状态。目标为
id/device/检测支持绑定、迟到读取隔离、结果不被旧缓存冒充；不改变公开协议、存储
格式或执行真实检测。Windows 原生面板已完成的合成证据不替代本波 Mac 回归。

本波实际完成：Repository 的存储读取按代次更新缓存，当前读取失败时清空旧目标，
迟到旧清单既不能覆盖新目标也不能清空新缓存。历史按 id/device/检测支持清理；
公开状态/启停入口重新读取清单，若与已缓存目标不同则当前调用失败关闭，不把
显示 ID 自动改指新设备。单硬盘状态/历史读取再用代次和当前目标检查，避免同
设备乱序历史或旧设备响应写回。此为现有 API 内部实现修复，未变更公开协议。

Mac Model 在存储刷新后清除变更设备的状态，失败刷新清除状态；状态请求绑定存储
代次、单硬盘读取代次、模块与稳定设备，取消/异盘/迟到响应不写回。关闭模块不
释放仍在执行的硬盘锁，原调用结束才释放。启动/停止反馈只采用 MutationResult，
不再用旧运行状态覆盖 unknown，也不在确认后刷新失败时补造运行/停止状态；已确认
的命令可成功返回，但当前状态保持未知。删除了仅用于补造状态的旧 helper。

新增网络层 **7 项**、Mac Model **4 项**测试方法与专用迟到响应测试 transport：
覆盖已预热缓存仍重读、换盘零写、历史隔离、刷新失败、迟到清单、跨设备/同设备
迟到历史、Model 乱序/模块重开、未知反馈和成功后刷新失败。既有启停用例的首次
load_info 改由被测入口执行，原请求顺序和结果断言保留；额外预热缓存用例明确
断言两次 load_info 后才有一次写入。测试数据均为合成，不运行真实检测。

独立集成与只读对抗复核覆盖原值捕获位置、actor 重入、同设备重复刷新、错误清理、
身份变更、请求代次、操作锁释放和结果反馈。尚不能以此证明完整 Mac 危险写恢复
与换盘实机行为，相关权限/未知操作/交互的完整验收继续保留。

实际命令：

```text
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

Swift 命令不存在，**11 项新测试及既有 Apple/Mac 测试均未运行，Mac 未构建**；不得
用源码阅读或 Windows 先前通过替代。实际通过的是本地化（资源数仍为 4031/2188/
2650）、96 请求 fixture、3 响应组/22 私有引用、文档和差异检查。本波无 Windows/
Android 源码变动、不重新打包，先前 Windows 归档不包含或验证 Mac 改动。

PENDING_USER_VALIDATION：在 Mac 运行共享网络与 App 测试，重点核查新增 11 项及
原有硬盘启停用例，再用受控专用设备验证刷新、关闭/重开、换盘后状态/历史及
未知反馈；启停真实检测仍须用户另行授权。仅回传命令、版本类别和脱敏错误，不
传设备标识、序列号、真实日志或会话。iPhone/iPad 需回归共享缓存/读取影响；Android
只更新影响记录。无真实 NAS 操作、无提交/推送，保留既有工作区及此前清理受限的
忽略产物。下一切片继续核查剩余 NAS 管理与 Mac 未知操作恢复边界，完整对齐目标
仍在进行。

### 2026-09-17 远程访问读取与受保护保存核心

本波对照 Mac `loadRemoteAccessSettings/saveRemoteAccessSettingsResult`、Model 保存
反馈和既有 `dsm-remote-access-settings.md`，补 Windows QuickConnect v3 中继与
Upnp v1 自动配置。单一修改范围为领域增量、远程访问 partial、既有固定读取白名单/
共享写协调器注册和测试；Mac 同类严格读取/独立失败及旧缓存误报成功的必要修正
也在用户授权内。保存须确认基线、明确管理员与已登记环境，使用既有可信中继主机
判断保护当前连接，两子操作逐项核查、不重放。只使用已有接口，不做真实网络写，
生产门保持关闭；原生表单在核心通过后接入。

本波实际完成：Windows 新增远程访问设置/有效与失败分区、变化规则和兼容接口，
沿用已有 `NasServiceSettingsSaveRequest` 与共享写协调器，不建立第二套传输。
读取固定 QuickConnect.get_misc_config v3、Upnp.get v1；严格 Boolean，单项失败
保留另一项，认证/取消不降级为成功。保存只允许修改已知字段，整体检查实际变化
所需版本和新读取基线，明确管理员/登记环境后顺序提交。可信中继保护取当前连接
baseURI 的既有主机分类，伪造草稿 CanDisableRelay 不能绕过。

每项提交发生拒绝/模糊响应即停止后续操作，回读仅对已提交且未明确拒绝的项确认
成功。未知保留同客户端/作用域 pending，重建 Repository 或重复请求只核查不重发；
未提交项不因当前值吻合而冒充成功。生产 `NasRemoteAccessBehaviorValidated=false`。
Windows 可用性增加默认关闭的 init 属性，不改变原有构造调用；这些是已授权领域
增量，不变更持久化格式、共享网络协议、最低版本、签名或依赖。

Apple 同类修正固定 Upnp v1，严格布尔和独立读取，认证/OTP/取消/证书错误不吞掉；
当前未知的字段不提交猜测值。回读成功计数只涵盖已接受或可能提交的前缀，不把
拒绝/未提交的项因其他客户端改值算作成功，缺失字段保留未知。Mac 保存反馈不再
以匹配旧缓存覆盖未知/拒绝结果，增加模块/请求代次检查，删除已无调用的缓存匹配
helper。新增共享 **4 项**及 App **1 项**测试方法，已有双字段保存回归增加 v1 断言。

独立集成/只读对抗复核覆盖固定方法/版本白名单、FORM/JSON、严格布尔、失败隔离、
权限与环境、可信主机、草稿伪造、实际变化字段、完整预检、部分提交、取消、明确
拒绝与未知区分、跨 Repository 锁和最终回读。五端影响：Windows 使用自身领域
增量；共享 Apple 读取/计数变化需 Mac/iPhone/iPad 回归；Android 仅记录影响不改代码。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasRemoteAccessTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

远程访问新增 **20 项通过**；最终全量 **2436 通过、1 失败、0 跳过（共 2437）**，
唯一失败仍为符号链接系统特权。x64/ARM64 Release 均 **0 警告/0 错误**。本地化
资源保持 4031/2188/2650，96 请求 fixture、3 响应组/22 私有引用及文档/差异检查
通过。Swift 命令不可用，新增 5 项及既有 Apple/Mac 回归均未运行，Mac 未构建。
本波未接原生表单、未重新打包，不以旧测试包代表本轮新增远程访问核心。

PENDING_USER_VALIDATION：接入原生表单后先核对真实读取，再由用户另行授权专用
可恢复网络验证中继/路由器配置、当前中继保护、部分成功、断网与重新连接后的
回读。不得把 QuickConnect 登录成功外推为这些设置写行为已验证。Mac 先运行共享
和 App 测试；仅回传版本类别、操作步骤和脱敏失败信息，不回传主机、QuickConnect
ID、路由器配置或凭据。未修改真实 NAS/路由器、未提交/推送，保留其他工作区改动
和此前清理受限的忽略产物。下一切片接 Windows 原生远程访问表单，完整目标保持进行中。

### 2026-09-17 原生远程访问表单

本波单一范围为远程访问 WinUI 内容、NAS 菜单、现有泛型设置编辑器的远程访问能力
接线与仅快照保存支持、双语资源及合成测试。Mac 证据为 RemoteAccess 表单/Model，
沿用 Windows 已完成 v3/v1 核心。目标覆盖两项独立读取、缺失/失败、只读、中继
保护、变化确认、部分/未知反馈与只读恢复。生产写门不变，不添加网络接口或重做
设置状态层；本波不修改 Apple/Android，不进行真实网络写操作。

本波实际完成：`NasRemoteAccessDialogContent` 接入既有设置对话框。中继/路由器
两项分别显示已知值、读取失败或不支持，未知不显示成关闭；当前中继连接禁用
关闭中继但仍允许独立修改路由器设置。风险确认绑定不可变草稿，字段变化失效，
提交前再次读取控件。成功/已明确部分结果重新读取实际值，未知显示最后读取快照
及明确提示并锁定保存，重新读取只核查不重放。已核对成功后的显示读取失败不把
操作改成未知；所有反馈保留真实成功/失败/未知计数。

复用 `NasSettingsEditViewModel`，仅增加远程访问能力分支和只接受快照保存的重载，
不为新功能伪造旧式无基线保存接口。旧式委托调用保持原行为，没有保存委托仍拒绝
激活；4 项新编辑器测试验证独立能力、原始基线、未知不重放与缺失委托。原生测试
另覆盖部分读取、仅单项支持、当前中继保护、确认失效、部分结果实际回读、未知
恢复、关闭取消和保存后读取失败。新增 25 个中英文资源键，不变更网络/持久化契约。

独立集成/只读对抗复核覆盖 profile/单窗生命周期、未知字段、受保护开关的程序化
变更、能力重查、即时控件同步、快照委托选择、部分/未知恢复、取消和生产门；
默认按钮仍为关闭。中文初次截图片中保存按钮尚处于视觉状态切换，补充 150ms
控件稳定等待及再次检查 CanSave/IsPrimaryButtonEnabled 后中英文截图确认启用。
没有通过修改产品权限或删断言使测试通过。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter "FullyQualifiedName~NasSettingsEditViewModelTests|FullyQualifiedName~NasRemoteAccessTests" -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios nas-remote-access -Language zh-CN -WindowWidth 900 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-remote-access -States remote-confirm,remote-unknown,remote-relay -Language en-US -WindowWidth 900 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios nas-remote-access -States remote-confirm -Language zh-CN -WindowWidth 900 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

编辑器/远程访问聚焦 **40 通过**。全量 **2439 通过、2 失败、0 跳过（共 2441）**：
一项仍是系统符号链接特权；另一项为既有 Chat
`ConnectedUsesSlowerCalibrationAndDisconnectRestoresPolling` 的 30ms 断言失败。
未跳过、未修改该测试，也未通过反复重跑将此波次写成全过。下一切片优先定位该
时序问题，避免持续把不稳定门禁留在交付中。x64/ARM64 WinUI Release 均构建通过，
独立构建各 **0 警告/0 错误**。资源为 Apple 4031 / Android 2188 / Windows 2675；
本地化、96 请求 fixture、3 响应组/22 私有引用及文档/差异检查通过。

中文 **21 原生场景通过**，合成图在忽略的
`windows/dist/ui-review-20260917-073241`；英文 **5 场景通过**在
`windows/dist/ui-review-20260917-073426`，另补中文确认浅深色复验在
`windows/dist/ui-review-20260917-073619`。人工读取中英文确认/未知反馈截图复核布局
和焦点；它们不是桌面截图或真实网络操作。屏幕阅读器、触控、不同缩放与实际 NAS
权限组合仍待用户验证。本波因完整回归尚有上述失败不生成新包，旧包不代表本轮表单。

PENDING_USER_VALIDATION：先用真实 NAS 检查两项读取、未知/不支持及中继连接保护；
写操作仍需另行授权专用可恢复网络，核查断连、部分成功和重新连接后的实际设置，
生产门继续关闭。Mac 前波修正仍待目标平台测试，本波没有 Apple/Android 修改。
未操作真实 NAS/路由器、未提交/推送，保留已有改动与此前清理受限的忽略产物。
下一切片定位聊天时序失败后继续剩余 NAS/Container/VMM/系统集成，完整目标不缩小。

### 2026-09-17 Chat 刷新时序回归稳定化

本波单一范围为 `ChatForegroundRefresher` 的内部时间源注入和 Chat 刷新测试。源码
显示轮询先启动、实时订阅经 Task.Yield 后建立；首个回调可能是连接前轮询，Connected
事件仍需随后回读。旧测试将首个回调当成连接事件回读，再用 30ms 墙钟窗口断言没有
后续请求，未隔离这两种合法顺序。本波通过标准 TimeProvider 控制测试时间和请求
屏障复现两种顺序，不关闭连接事件补读、不放宽业务断言；生产默认时间源与间隔
保持不变，不改 API、依赖、权限或网络调用。完成后聚焦、全量与两平台构建复核。

本波实际完成：内部刷新器末尾增加可选 `TimeProvider`，生产默认 System，延时和
校准计时使用同一来源；原有连接前轮询、事件合并、连接后校准和代次隔离逻辑不变。
测试专用 `ManualRefreshTimeProvider` 仅实现本测试所需单次 Task.Delay，提供已登记
计时器数作为调度完成屏障，不加入产品或依赖。旧测试仍断言低频窗口内零额外回读、
到期必须回读、断开恢复轮询和停止清理，但不再将线程暂未调度当作零请求证据。

新增用例先阻塞连接前轮询的旧快照，再送入 Connected 和新服务端版本，明确验证
补读得到新版本且始终单一并发；因此不能通过抑制正常补读来“修好”旧时序断言。
独立集成/只读对抗复核覆盖默认时间源、事件与轮询两种顺序、计时器取消、同一
generation 内单飞、旧流隔离、事件合并和隐藏消息不读取。无网络 API、凭据、存储、
UI 或 Apple/Android 修改，不新增第三方库。

实际命令（使用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~ChatRealtimeRefreshTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-build --no-restore --filter "FullyQualifiedName~ConnectedUsesSlowerCalibrationAndDisconnectRestoresPolling|FullyQualifiedName~ConnectedDuringFallbackReadNeedsOneFreshFollowupBeforeCalibration" -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

实时刷新 **6 项通过**（新增 1 项），双顺序命令随后运行 **20 轮、40 次用例均通过**，
每轮失败即终止，并与 x64/ARM64 构建并行施加调度负载；不是失败后重跑直到遇到
一次通过。最终全量 **2441 通过、1 失败、0 跳过（共 2442）**，只剩已记录的
`BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints` 符号链接权限缺口。
没有删断言或跳过该门。WinUI x64/ARM64 Release 各 **0 警告/0 错误**。
本地化资源数保持 4031/2188/2675；96 请求 fixture、3 响应组/22 私有引用、文档/
差异门通过。本波不重复绘制未改动的页面，不将此前 UI 图当成本波新增视觉证据。

使用既有非交互 `windows/package.ps1`、both、`LANSTASH_RUN_TESTS=0`（测试已单独
执行）、`LANSTASH_LAUNCH_AFTER=0` 生成独立测试归档，包含前波远程访问原生表单；
不安装/启动或改变生产写门。PENDING_USER_VALIDATION：真实 Chat 长连接、断网/重连、
睡眠恢复和前后台仍需 Windows 与真实 NAS 验收；符号链接测试需具备相应系统权限
的环境。只回传脱敏错误和操作步骤，不传聊天内容、会话或主机。未提交/推送，
保留既有改动与此前清理受限的忽略产物。下一切片继续剩余 NAS 管理/Container/VMM
及平台集成，不以此时序回归通过宣称完整功能对齐。

独立归档已与 `.sha256` 核对：

- `windows/dist/20260917-074529/LanStash-0.1.0-x64.zip`：
  `E90A9FC1A335B061203C7E1F239AA7DBECFB762EED5413984D29D1F6379BA653`。
- `windows/dist/20260917-074529/LanStash-0.1.0-arm64.zip`：
  `84EC089D7FEBC2E812080C2FA7499D6382AB58AAB873E5BD579B6B76D7FDF234`。

### 2026-09-17 电源计划只读闭环

基线核查确认 Windows 尚无电源计划/外接存储/ZRAM，Mac 三者当前均为只读候选。
本波先完成电源计划：证据为 Mac `loadPowerSchedule/PowerScheduleView` 和既有
`dsm-power-schedule.md`，仅使用运行时发现包含 v1 的无参 load，保留 static 证据
等级。范围为 Windows 领域、读取 partial/白名单、专属只读状态/原生表单和测试；
同类 Mac 缺失根被当成空列表的问题在用户授权内做聚焦修正。128 条上限、未知动作/
状态/重复规则、NAS 时区缺失、部分不可显示和筛选五态必须明确。禁止新增 save
接口/按钮或推测参数，外接存储/ZRAM 仍留在后续完整目标中。

电源计划本波实际完成固定 v1/FORM/JSON 读取、128 条上限、字段白名单、稳定枚举
筛选与只读原生窗口；缺失/冲突根不冒充空列表，部分不可识别条目与未知时区明确
提示。27 个中英文资源键已补齐。Mac 同类解析增加根校验、整数时间及未知布尔，
全不可显示时失败关闭；不完整提示改为通用说明，避免不足 128 条时错误解释原因。

已执行：`dotnet test ... --filter FullyQualifiedName~NasPowerScheduleTests` **12 通过**；
同一测试工程全量 **2453 通过、1 符号链接权限失败、0 跳过（共 2454）**。
命令均沿用 `windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64
--no-restore -v minimal`。WinUI x64/ARM64 Release 构建通过（既有 App 工程和
对应 win-x64/win-arm64 参数）；中文原生 13 场景、英文 5 场景通过，分别位于忽略的
`windows/dist/ui-review-20260917-075953`、`windows/dist/ui-review-20260917-080226`；
最终中文计数文案浅深色复验位于 `windows/dist/ui-review-20260917-080400`。
人工读取英文正常/未知时区图片确认日期时间本地化、没有写按钮。所有测试只用合成
数据，未执行 save；Swift 命令不存在，Mac 两项新增测试及已有回归均未运行。
本波未打包，旧归档不含电源计划页面。

PENDING_USER_VALIDATION：真实 DSM 的版本/路径/容器仍待只读核对；Mac 需运行共享
解析与页面回归；不得从候选读取推断 save 的契约或开放保存。五端网络契约未新增，
Windows 领域为兼容增量，Apple 移动需回归共享修改，Android 本波未改。未提交/推送。

### 2026-09-17 外接存储只读闭环

本波以 Mac `loadExternalStorage`/原生外接存储页和 `dsm-external-storage.md` 为
基线，单一范围为 Windows 领域、独立 USB/eSATA v1 读取、只读状态/原生窗口、
资源和测试。每类最多 64 项，只用明确字节字段，不把整体失败当空列表，缺少一类
保留另一类。设备节点、序列号、挂载路径和未知字段不进入模型；只读临时 ID 不能
作为弹出目标。eject 不实现、不调用；所有接口继续保留 static 候选级别。

外接存储本波实际完成：新增兼容领域与读取接口，固定 USB/eSATA 各自 v1 list，
独立能力发现和失败处理，每类只保留前 64 项。缺失/冲突根不当空列表，至少一类
成功才能形成目录；认证与取消不降级为部分成功。容量只接明确字节字段、整数且
非负，冲突/小数/超额已用值保持未知。名称排除路径与控制字符，不保留设备节点、
序列号、共享、账号或网络字段，连接类型来自所请求 API。原生窗口提供全部/USB/
eSATA 筛选、未知容量、来源不可用、截断/不可显示、加载/空/筛选空/错误/正常状态；
没有写按钮，SaveAsync 不做操作。复用 NAS 原有字节格式化，仅将该方法改为 internal，
没有新建另一套单位规则；24 个用户资源键提供中英文。

Apple 同类修正仅为读取：容器缺失/畸形/冲突时该来源不可用，两个来源都失败时
不返回空目录；空根却报告非零总数也不当无设备。严格字节/总数字段不截断小数，
认证/OTP/证书错误不吞掉。新增 3 项 Swift 测试方法，未在本机运行。前波电源计划
不完整提示本波收尾同步四份 Apple 资源，避免把非条数上限问题错误描述为前 128 条。

独立集成/只读对抗复核覆盖发现版本、无参白名单、零 eject、异常根、身份及名称
白名单、每类上限、类型来自 API、单位、溢出/负数/小数/别名冲突、整体与局部失败、
取消、过滤与请求代次。没有开启任何私有写，也没有新增 API 名称/参数/版本或共享
网络契约；Windows 领域为已授权兼容增量，Apple 移动需回归共享解码，Android 不改。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasExternalStorageTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-external-storage -Language zh-CN -WindowWidth 900 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios nas-external-storage -States extstore-content,extstore-partial,extstore-unknown -Language en-US -WindowWidth 900 -PaneState compact
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增 Windows **12 项通过**；全量 **2465 通过、1 符号链接权限失败、0 跳过（共
2466）**。x64/ARM64 WinUI Release 各 **0 警告/0 错误**。中文原生 **16 场景**、
英文 **5 场景**均通过，图片位于忽略的 `windows/dist/ui-review-20260917-081732`
及 `windows/dist/ui-review-20260917-081958`；人工读取英文正常/部分失败图复核
容量、类型、未知值、浅深色及无写按钮。Swift 命令不存在，3 项新增及既有共享/
Mac 回归均未运行、Mac 未构建。资源数为 4031/2188/2726；96 请求 fixture、3 响应
组/22 私有引用、本地化与文档/差异检查通过。没有新包，旧归档不含这两批只读页面。

PENDING_USER_VALIDATION：在实际 DSM 上只读核对版本/路径/容器、多分区/热插拔、
容量与普通账号权限，再在 Mac 运行共享和页面回归；全量 Narrator/触控/缩放未验收。
不把候选读取或合成通过外推为 eject 可用，弹出仍无入口。反馈只含环境类别、步骤
和脱敏错误，不传序列号、设备/挂载路径、共享名、主机或会话。未提交/推送，未
操作真实 NAS，保留既有改动及此前清理受限的忽略产物。下一切片补 ZRAM 只读摘要，
随后继续剩余 NAS/容器/VMM/系统集成，完整目标保持进行中。

### 2026-09-17 内存压缩只读闭环

本波以 Mac `loadZRAM/ZRAMView` 和 `dsm-zram.md` 为基线，仅接运行时发现包含 v1
的 get。单一修改范围为 Windows 标量领域/读取/原生状态展示、既有读取白名单、
资源与测试，以及 Apple 同类严格字段读取修正。只显示已知启用状态、明确字节
容量和限定算法，未知不当关闭/零/任意原文；空信息、错误和不可用分开。set 无入口，
static 候选证据不升级。完成后合并前两批只读页面生成独立测试包。

本波实际完成：新增 `NasZramSnapshot` 与兼容只读接口，固定 v1 无参 get；复用已有
明确字节/一致别名校验与 NAS 字节格式化，不新建网络栈。启用仅原生 Boolean，
容量非负整数且单位明确，算法仅 LZ4/LZO/Zstandard 枚举；其他字段不进入模型。
原生标量页面显示加载、无可识别信息、错误、不可用和正常摘要，不需要人为添加
筛选。已知 false/0 与缺失值分开，页面没有开关、保存或 set 调用。14 个用户资源
键同时提供中英文，关闭/切换上下文取消读取并忽略迟到结果。

Apple 同类修正严格布尔、容量与别名一致性，复用前波字节校验，非对象 data 报错，
新增 2 项共享测试方法。公共 Apple 协议/持久化格式未变；iPhone/iPad 需回归共享
读取影响，Android 本波不修改。独立集成/只读对抗复核覆盖 v1/无参白名单、零 set、
字段隐私、假布尔、小数/冲突容量、未知算法、缺失与 false/0、错误根、取消和上下文
隔离。接口仍为 static 候选，不因合成通过提升版本兼容证据。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~NasZramTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios nas-zram -Language zh-CN -WindowWidth 900 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios nas-zram -States zram-content,zram-partial,zram-empty -Language en-US -WindowWidth 900 -PaneState compact
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增 Windows **12 项通过**；全量 **2477 通过、1 符号链接权限失败、0 跳过（共
2478）**。WinUI x64/ARM64 Release 均 **0 警告/0 错误**。中文 **11 原生场景**、
英文 **5 场景**通过，合成图分别在忽略的 `windows/dist/ui-review-20260917-083112`
及 `windows/dist/ui-review-20260917-083334`；人工读取英文正常/部分未知的浅深色图
确认只读布局、容量和未知状态。Swift 不可用，2 项新测试及已有共享/Mac 回归均
未运行，Mac 未构建。资源数 4031/2188/2740，本地化、96 请求 fixture、3 响应组/
22 私有引用、文档与差异检查通过。

通过既有 `windows/package.ps1`、both、非交互、禁止自动安装/启动生成独立合并
测试包；脚本内测试关闭，因为上述测试已单独执行并保留环境失败。本包包括电源
计划、外接存储、内存压缩三批只读页面，不改变任何生产写门。

PENDING_USER_VALIDATION：真实 DSM 版本/路径/字段、普通账号、禁用状态下容量和
算法、实际 NAS 权限，以及 Narrator/触控/缩放仍需用户只读验收；Mac 需共享与 App
回归。不能据页面或只读合成测试开启 set；反馈仅环境类别、步骤及脱敏错误，禁止
设备路径、内核参数、主机或会话。未操作真实 NAS、未提交/推送，保留既有改动与
此前清理受限的忽略产物。这三项只读切片完成不代表 NAS 全部管理或完整平台对齐；
下一切片继续核对剩余 NAS 能力与 Container/VMM，高风险及系统集成仍按原目标推进。

本波独立归档均与 `.sha256` 核对通过：

- `windows/dist/20260917-083509/LanStash-0.1.0-x64.zip`：
  `FB2613912B9DF36B972E4AF6E2F6F637CBD686DE27C6FF12D4846A1787A79C7F`。
- `windows/dist/20260917-083509/LanStash-0.1.0-arm64.zip`：
  `67493EF718153C87D56A1075129D4ED3D04D7C73249C3E4EBE1A1FDEF7D78489`。

### 2026-09-17 Container 网络详情与关联数据对齐

本波按 `container-manager-internal.md` 及 2026-09-10 观察记录，先接完整网络只读
详情流程。证据为 Mac `ContainerNetwork/containerNetwork` 及展开视图：关联数组
或明确计数、driver、subnet/gateway/iprange、enable_ipv6。Windows 沿用当前网络
列表请求，不增加详情端点或猜测写参数；领域仅增加兼容可选详情，网络分区失败
不阻断容器列表。单一范围为领域、既有解析器、资源行状态与原生展开模板、双语
资源和测试。创建/删除为下一安全切片，不把详情完成算作全部容器管理完成。

本波实际完成：`ContainerResourceSummary` 增加默认 null 的可选网络详情，旧构造
保持兼容，不改 Repository 方法或持久化。网络解析继续只用既有 list v1；优先从
containers 字符串数组取真实数量，缺少数组时要求一致的非负整数计数。未知/畸形
关联数据使网络分区失败，不影响主容器及其他分区；可选 IPv6 只接受 Boolean，
地址只保留可解析的 IP/CIDR，其他路径/脚本/环境字段不进入新模型。补查能力名称
与版本下界，非法能力元数据不能启用请求。

WinUI 网络列表使用独立 Expander 模板，显示类型/数量、子网、网关、IP 范围、
IPv6 和关联名称。没有关联与没有名称信息分别展示，旧无详情对象保持未提供状态；
不增加详情、日志、进程或环境变量读取。11 个资源键中英齐全，页内可复制地址/名称。
两处原合成网络 fixture 补明确 containers 空数组，原 201 项完整列表断言保留，
不通过删断言或把未知默认为零适配新逻辑。

发现并按已有授权修正 Apple 同类问题：原 firstInteger 可将布尔/小数转为计数；
网络计数改为精确非负整数与别名一致性检查，拒绝溢出。新增一个覆盖四类输入的
Swift 回归方法，但本机无 Swift，未执行 Mac/共享回归；不修改其他数值解析器。

独立集成/只读对抗复核覆盖数组权威计数、计数后备、不明名称、错类型 IPv6、
地址白名单、非法 capability、认证/取消上抛、附属失败隔离、201 项列表保留与
展开零附加请求。五端影响仅 Windows 兼容可选详情和共享 Apple 的严格计数；
iPhone/iPad 需共享回归，Android 本波不改代码；不升级真实环境证据或写能力。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~Container -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios container-networks -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-networks -States network-details,network-zero,network-unknown -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios container-networks -States network-unknown -Language en-US -WindowWidth 1000 -PaneState compact
swift test --package-path apple
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增网络 **14 项**；容器聚焦 **64 通过**；最终全量 **2491 通过、1 符号链接权限
失败、0 跳过（共 2492）**。x64/ARM64 WinUI Release 各 **0 警告/0 错误**。
中文原生 **10 场景**、英文 **5 场景**通过，分别位于忽略的
`windows/dist/ui-review-20260917-090341` 与 `windows/dist/ui-review-20260917-090605`；
人工读取英文正常/未知浅深色展开图确认字段、文本换行与零附加请求，随后将摘要
前缀明确为“类型”，避免未提供驱动被误读成网络不可用，并补两项未知场景复验。
资源数 4031/2188/2751，96 请求 fixture、3 响应组/22 私有引用、本地化和文档/差异
检查通过。Swift 不存在，新增与原 Mac 回归未运行。本波不重新打包，旧包不含新增
网络详情；待网络管理安全切片合并后出新测试包。

PENDING_USER_VALIDATION：真实网络详情、旧版计数后备、普通账号和大量关联名称需
只读核对；Mac 需运行计数回归；Narrator/触控/缩放仍待用户验收。不发送创建/删除，
不读取容器环境或日志正文。回传仅版本类别、步骤与脱敏错误，不传真实网络地址、
容器名称、环境变量或凭据。未提交/推送，保留既有改动及此前清理受限的忽略产物。
下一切片按已有契约接网络创建/删除核心及确认/恢复，完整容器/VMM 和系统集成目标
仍未完成。

### 2026-09-17 Container 网络创建核心

本波按已批准的 `ContainerNetworkCreation` 配置和 2026-09-10 创建记录，迁移
Windows 完整自动/手动 IPv4、IPv6 和 IP 伪装配置，不保留 name/driver 简化写。
单一范围为领域校验、创建/核查接口、Container partial、既有共享操作协调器注册
与正式 HTTP 合成测试。提交要求风险确认、完整列表的名称预查、同名互斥、固定 v1
和结果回读；模糊结果不重发。生产门继续关闭，真实权限由 NAS 裁决；不推断普通
用户必然拥有管理员权限。没有已验证回读字段的 IPv6 地址/IP 伪装设置保持未确认，
不能据网络存在宣称全部选项成功。删除和原生创建表单是随后切片，不执行真实写。

本波实际完成：新增不可变 `ContainerNetworkCreation` 配置及问题枚举，校验与 Mac
既有规则一致：名称字符、IPv4 四段且无前导零、地址族、CIDR 前缀、网关/范围归属，
非活动模式字段不发出。Container 接口以默认关闭属性/默认方法兼容扩展；创建和
恢复复用既有共享写协调器及固定序列化，不创建第二套会话/网络栈。仅发送 v1 create
的已记录字段，不含 driver。前置读取与权限由 NAS 裁决，未假设普通用户可获得
管理员权限，也不通过客户端猜测提升权限。

预检完整 list、稳定原生 ID/名称、名称未占用与已登记 DSM 范围；记录原 ID 集合，
创建回读必须唯一新 ID、相同名称/bridge、IPv6 开关和手动 IPv4 配置匹配。CIDR
按前缀与网络位比较，不能因服务端规范化网络位误报失败；网关必须吻合。明确拒绝
保持失败，不因外部匹配网络升级成功；断网/取消保持未知。同名不同配置拒绝重复
提交，同名同配置与同请求只回读；同一 API 客户端重建 Repository 不绕过去重。
IPv6 地址和 IP 伪装效果无可靠回读记录时明确保留 options-unverified，不编造字段。

独立集成/只读对抗复核覆盖输入、隐藏字段省略、FORM/JSON、真实方法 v1、名称占用、
旧 ID 被重命名、重复名称、部分/缺失回读、明确拒绝、并发、取消与恢复。生产
`ContainerNetworkCreationBehaviorValidated=false`，当前没有原生提交入口；套件
版本/权限与高级选项仍须实际验收后再决定启用，未以只读 metadata 外推行为等级。
本波不改 Apple/Android 或公共 NAS 协议，Windows 领域为已授权兼容增量。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~ContainerNetworkCreationTests -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增创建 **21 项通过**；全量 **2512 通过、1 符号链接权限失败、0 跳过（共
2513）**。x64/ARM64 WinUI Release 各 **0 警告/0 错误**。本地化资源数仍为
4031/2188/2751；96 请求 fixture、3 响应组/22 私有引用、本地化及文档/差异门
通过。本波没有新增页面、未跑创建原生场景、未重新打包，不把旧包当作包含此核心。

PENDING_USER_VALIDATION：原生表单接入后，在另行授权的可丢弃网络验证默认与手动
IPv4 创建、实际权限、重名、断网、取消和最后状态；IPv6 地址/IP 伪装须先补可靠
只读字段与版本证据，未确认时不强行解除 pending 或重发。只回传版本类别、步骤和
脱敏结果，不传真实地址、网络/容器名称或会话。未执行真实网络操作、未提交/推送，
保留既有改动与此前清理受限的忽略产物。下一切片接原生创建表单和删除保护；完整
容器/VMM 与系统集成目标继续保持进行中。

### 2026-09-17 原生容器网络创建表单

本波单一范围为 Container 网络创建状态层/原生表单/页面入口及双语与合成测试。
复用已完成的配置验证和创建核心，不增加请求参数；完整展示自动/手动 IPv4、
IPv6 和 IP 伪装选项。确认绑定当前输入，待核查名称不可重发，关闭和切换配置
取消等待并丢弃迟到结果。生产创建门继续关闭，表单可查看，不把高级选项未确认
改成成功；删除与其他容器/VMM 操作仍在后续目标中。

本波实际完成：网络页新增创建入口和专属 ContentDialog，完整名称、自动/手动 IPv4、
IPv6 三项地址及 IP 伪装选项；没有 driver 简化参数。状态层使用现有不可变配置和
验证枚举，确认绑定当前草稿，提交前重新采集控件，任一输入变化撤销确认。创建
期间禁用编辑/核查，关闭取消等待，旧上下文迟到结果不写回。成功后同名不能再次
提交；待核查名称即使修改配置也不可重发，核查只调用恢复接口。关闭已提交窗口后
刷新主列表，合成测试确认新网络可见。

当前生产门关闭时可查看配置，提交按钮保持禁用且说明需在 DSM 操作；未来能力
变化仍会在确认和执行时重新检查。高级选项显示核查边界，options-unverified
只能显示警告，不能冒充成功。缺失权限、名称/状态冲突、取消与准备失败提供下一步。
38 个用户资源键中英齐全；未新增网络请求契约、持久化或权限。删除仍未接入。

独立集成/只读对抗复核覆盖单窗/profile 保护、无确认零请求、即时控件同步、并发
防护、相同名称阻止、只读能力撤回、未知恢复、关闭与配置切换取消、父列表刷新和
生产门不变。本波无 Apple/Android 修改，前波 Mac 回归缺口仍保留。

实际命令（沿用既有 dotnet/Python 路径）：

```text
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter FullyQualifiedName~ContainerNetworkCreation -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios container-network-create -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-network-create -States netcreate-auto,netcreate-confirm,netcreate-unknown -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios container-network-create -States netcreate-confirm -Language en-US -WindowWidth 1000 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

新增状态层 **6 项**，创建聚焦 **27 通过**；全量 **2518 通过、1 符号链接权限
失败、0 跳过（共 2519）**。中文原生 **18 场景**、英文 **5 场景**通过，合成图在
忽略的 `windows/dist/ui-review-20260917-100547` 和
`windows/dist/ui-review-20260917-100824`。人工读取完整表单/未知反馈浅深色图后，
补风险确认框横向拉伸并缩短英文确认句，避免长句碰到滚动条，再复验英文确认场景。
最终确认区复验图位于 `windows/dist/ui-review-20260917-101304`，浅深色均通过并已复核。
本地化资源数 4031/2188/2789；96 请求 fixture、3 响应组/22 私有引用及文档/差异
检查通过。x64/ARM64 WinUI Release 均构建通过；本波不打包，后续合并删除流程再
交付网络管理测试包，旧包不代表本轮创建表单。

PENDING_USER_VALIDATION：生产能力未开放，真实套件/权限/网络效果仍需用户另行
授权可丢弃网络后验证。IPv6 地址/IP 伪装必须补可靠回读证据，未知不强行解除名称
保护。Narrator、触控和缩放尚未完整验收。仅回传版本类别、步骤及脱敏错误，不传
真实名称、地址或凭据。未操作真实 NAS、未提交/推送，保留既有改动和此前清理
受限的忽略产物。下一切片接删除的目标确认、占用保护与最终核查，整体目标未完成。

### 2026-09-17 Container 网络删除核心

本波按既有 remove 对象数组记录及共享 fixture 实现 Windows 删除核心，不发送旧
单 id 参数。范围为领域确认请求/规则、Container 删除 partial、现有共享写协调器
与创建交叉锁、正式 HTTP 测试。保护 bridge/host/none、未知或非零关联、确认后
目标变更；只复制已观察字段，最终按原 ID 回读，失败/未知不重发。支持对象数组的
逐目标计数，但实际观察只覆盖单目标，不外推真实批量行为，生产门保持关闭。

### W3：只读 NAS、Container 与 VMM

#### 2026-09-19 可测试入口开放：Chat 高级操作

按用户最新授权，移除 Chat 高级功能对 DSM 7.2.1/69057/u12 与 Chat 2.4.1 的单值
白名单，也不再为使用普通聊天功能要求读取系统套件管理摘要。可用性按当前绑定会话
与对应 Chat API 版本/格式决定，提交仍重新核对可访问会话、消息/所有权、请求 ID、
未知不重放与实际结果。不是跳过真正权限或接口检查，不新增方法/版本/持久化。
范围为高级准备/可用性、基础能力元数据核对及相关正式测试；其他平台不改。

实际完成：移除 `_chatAdvancedEnvironmentMatches`，不再发起 Desktop.Initdata 或
Package.list；对应高级 API 严格检查名称、正整数版本范围、固定版本、路径及
FORM/JSON。所有写能力要求同一 NAS 的有效会话；真正写操作沿用目标会话、消息
归属/加密限制、确认、请求标识绑定和结果核查。没有改方法、参数、持久化或依赖。
新增 11 项回归覆盖缺系统能力仍成功、空/错会话零请求、6 种错误能力以及取消；
旧环境固定关闭断言改为正式入口成功并核对无系统请求，原权限/归属/未知不重放
断言保留。修正旧本人删除用例仍期待系统预读的序列断言，不删任何必要 Chat 请求。

只读对抗复核：打开页面不是授权写入，执行路径重新检查可访问会话及消息；错会话、
错误接口声明不能暴露写能力或提交；未知操作保留原请求锁，不因去掉环境检查而重放。
普通用户权限由 Chat 预检与套件拒绝决定，不额外套用 DSM 管理员角色。本波未改 UI
布局，未重复原生截图测试；真实 Chat 行为仍为 PENDING_USER_VALIDATION，用户需
使用有 Chat 权限的账号测试提醒/定时/本人消息操作，核对官方页面最终状态，失败
只回传脱敏提示及操作类别，不回传凭据、消息正文或真实路径。

实际验证：Chat **290 通过**；全量 **2771 通过、1 失败、0 跳过，共 2772 项**。
唯一失败为 `BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`
的 CreateSymbolicLink 系统权限不足，未修改安全配置或降低测试。执行命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~Chat' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

后五项通过：双语资源 Apple 4033/Android 2188/Windows 2957，96 请求 fixture、
3 响应组/22 私有引用。API 环境验证记录未升级；目标 Mac 构建仍未运行。既有大量
工作区修改保留，未暂存、提交或推送；容器/VMM 高级管理、文件与系统集成仍待实施。

本波独立 Windows 测试包已由 `windows/package.ps1` 生成：
`windows/dist/20260919-223741/LanStash-0.1.0-x64.zip` 与同目录 arm64 包。
Release、自包含，基于 main@0eeeb170358c 及当前未提交源码，保留旧包、未安装/启动。
包括 VMM/NAS/容器网络/Chat 最新可测试开放策略，未实现入口不伪装可用。
打包使用 LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=0、LANSTASH_LAUNCH_AFTER=0；单测独立运行并保留上述失败，
不是全量测试通过的正式发行。双架构 publish 成功，两个 SHA256 sidecar 核对一致：

- x64：`D871AEB84A01C7219BA429AA1931A234627FCF2A9F169F128BA36857191CB7B4`。
- arm64：`697E3ACC8925D9CC93663A36D759181F8C5FB03FB235C56F6C01B5539E327AFD`。

构建元数据 architecture/configuration/selfContained/sourceCommit/sourceState 已核对。
Mac 1.0.9 修复不在该 Windows 包内，仍需 Mac 目标构建；下一切片为容器生命周期与
镜像写管理，其他剩余目标保持不变。

#### 2026-09-19 可测试入口开放：NAS 专用流程与容器网络

按最新用户授权，仅开放已有完整确认/预检/重复保护/回读的 NAS 专用操作及容器网络
创建/删除。去掉行为验收恒 false 常量与单一 DSM build 白名单，不改 API 参数、
固定 API 版本、响应校验或传输安全；系统管理每次准备及提交重新核对当前会话和明确
管理员权限，权限未知/缺失/非管理员拒绝。容器网络保留套件自身权限边界，不额外
强制 DSM 管理员身份，实际拒绝由套件回执处理。准备请求增加代次保护，迟到结果
不能恢复旧权限。
旧通用无确认写辅助、未接生产传输的收藏/远程挂载、未实现操作仍不开放。范围限这些
适配器及对应回归，其他四端不改，无新依赖/权限/持久化。允许测试不等于行为已验证。

实际移除 NAS 专用 21 项与容器网络 2 项 BehaviorValidated=false 条件，并去掉
7.2.1/69057/u12 单值比较；不是把验证布尔值改成 true。NAS 可用性要求 Session
原生 is_admin=true，操作对应 API 可用；安全/硬件总入口也要求至少一个对应接口。
所有专用核心在提交前重新准备身份并检查管理员，不能只信页面打开时的权限缓存。
容器网络依已记录接口、当前会话、目标/占用检查、确认及服务器权限拒绝处理，不把
DSM 系统管理员概念套到容器套件用户。未知/错误类型的身份摘要仍不开放。

首轮角色测试暴露旧合成快照缺 is_admin，以及容器合法非系统管理员用例被过度限制；
已保留容器边界，给 NAS 正常写入场景补明确管理员快照。由于原写屏障用例在预检
拒绝后等待，停止了本轮已确认归属的测试宿主；首轮 649 通过/141 失败且中止，不能
作为完整结果。后续保留权限/缺确认/漂移/未知所有断言，按新策略把“固定关闭”断言
改为正式公开入口可用及零写/回读验证，803 项聚焦全部通过。另新增 11 项覆盖所有
专用可用性、缺接口、管理员 false/null/字符串/数字/缺失、撤权、迟到、取消与错会话。

最终全量 **2760 通过、1 失败、0 跳过，共 2761 项**，唯一失败仍为本机符号链接权限。
x64/ARM64 正式构建均 0 警告、0 错误。测试未降低断言或跳过；正式测试结果位于
windows/dist/test-results/nas-write-validation.trx。没有真实 NAS 写/网络变更/关机。
本波未改 UI 布局，已有原生接线逐项确认调用 PrepareServiceSettingsAsync 或
PrepareNetworkManagementAsync，随后使用同一专用公开入口，不存在单独测试专用路径。

独立只读对抗复核：准备结果有代次与取消检查，旧管理员结果不能覆盖新拒绝；实际
提交再次核对身份、原值与能力，原目标互锁/确认/未知恢复仍保留。NAS 旧通用无确认
辅助及收藏/远程挂载缺生产传输的路径继续关闭，属于未完成实现而非待实测门。
扫描还发现 Chat 高级功能的旧环境白名单，下一切片继续处理；本次不重新打包，不
将仅部分清理的策略声称为全部可测试。所有原有改动保留，未暂存、提交或推送。

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasAdmin|FullyQualifiedName~ContainerNetwork' --logger 'trx;LogFileName=nas-write-validation.trx' --results-directory windows/dist/test-results -v quiet
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~NasWriteAvailability' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
```

#### 2026-09-19 可测试入口开放：公开 VMM

落实最新用户授权，首段单一修改范围为已实现的公开 VMM 电源、基础编辑和创建入口。
移除仅由“未实机验收”决定的恒 false 条件，改为当前会话归属、非空认证、有效公开
接口版本/格式；保留所有请求确认、范围/目标预检、重复保护、实际拒绝及最终核查。
不把原 BehaviorValidated 改成 true 冒充验收；合成回归改走正式公开入口，仍验证缺
接口/缺确认/错会话/漂移/未知等零写或不重放条件。真实 NAS 操作仍由用户主动确认。
其他固定关闭门分模块继续复核，通用旧 NAS 写辅助并非完整安全流程，不能全局翻转。

实际已移除三项 VirtualMachine*BehaviorValidated=false，而不是把“验证通过”布尔
伪造为 true。三个公开入口均要求当前 profile 与会话一致、认证非空、固定公开接口
版本/格式有效，随后仍进入原预检/确认/重复保护/回读核心。电源、设置、创建及继续
的 HTTP 合成测试均改走正式公开入口，原内部核心断言保留语义；另加空认证和跨
profile 会话的零网络回归。首轮 VMM 聚焦 167 项通过；新增会话回归后全量为
**2749 通过、1 失败、0 跳过，共 2750 项**，唯一失败仍是符号链接权限，未降低断言。
新增测试首次出现 SaveSettingsAsync 重载推断歧义，改显式请求类型后编译/回归完成。

最终正式配置 x64/ARM64 构建各 0 警告、0 错误；实际执行
`dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal`
及对应 Platform=arm64、win-arm64 命令。96 请求 fixture、3 响应组/22 私有引用、
本地化、严格文档检查及差异检查通过，均不代表真实 NAS 已验证。

原生创建确认区补当前 VM 名称、存储和磁盘/网卡数量摘要；英文确认长句显式换行，
避免窄窗口裁切。英文 16 场景通过，图在 windows/dist/ui-review-20260919-214301；
中文确认/成功/等待继续/恢复共 5 场景复跑通过，图在
windows/dist/ui-review-20260919-214524。已查看英文底部确认和深色成功图；其它语言
场景不替代真实辅助功能测试。新向导现已接线，不再按“尚未接入”计算源码差距。
本地化资源 Apple 4033、Android 2188、Windows 2957，完整性/引用/硬编码检查通过。

NAS 管理、容器网络等固定关闭门仍需下一切片逐项处理。本次检查还确认收藏写/远程
挂载缺生产 IFileLocationMutationTransport，不能仅去掉常量就伪装可用；这属于文件
功能实现差距而非等待实测。旧通用 NAS 写辅助缺完整确认边界，继续保持隔离，未来
只开放已实现的专用安全流程。没有新增真实 NAS 写、系统注册、依赖、权限或持久化。
未重新打包；前次 204714 包仍是旧关闭策略，不能用作本轮“已开放”测试包。

用户验证不作为开发阻塞，但验证等级仍保持合成/构建：接口兼容且有实际权限时可由
用户逐项确认操作，未知结果只核查。缺接口、错会话、目标漂移、未实现路径仍拒绝，
不得为了让按钮可点绕过这些真实条件。五端影响仅 Windows；Mac 修复待目标构建，
不以本轮结果替代。未暂存/提交/推送，保留全部原有工作区改动。

#### 2026-09-19 Windows 官方虚拟机创建工作流

原生向导接线波次：独占创建状态层/对话框、VMM 顶栏与模态互斥、双语及新回归。
复用上述已授权领域/Repository，不更改创建参数或放开生产写门。支持空白/已有映像
多磁盘、连接/未连接多网卡、基础设置；恢复显示原配置且重新确认才能继续设置。
自动核查只读，关闭取消本地等待、不取消或重发 NAS 创建。结果未知、部分失败和
克隆来源待核查分别展示；ISO/固件/自动开机等未实现项保持明确后续范围。

当前已接创建状态层、动态磁盘/网卡编辑、恢复选择、确认、只读自动核查、明确继续
及父列表刷新；新增状态层 9 项合并创建核心共 38 项聚焦通过，首轮中文原生 15
场景通过（windows/dist/ui-review-20260919-213043）。创建回执缺失新增独立阶段，
不会无限显示正在创建或自动重发。最终英文/全量/双架构与包尚待完成；未重新打包。
用户随后明确要求已实现功能应在交付版本可测试，硬编码行为关闭门的逐项收敛现在
也是交付前要求，适用最新总控计划授权，不以历史 false 门作为永久禁用理由。

已授权的兼容增量切片，macOS 证据为 ServiceManagementView 创建表单与共享
createVirtualMachine。采用公开 Guest.create v1 的 storage_id/guest_name/vdisks/
vnics/auto_clean_task，Task.Info.get v1 绑定返回的新 guest_id，再 Guest.get 核查
资源；基础设置由 Guest.set v1 完成，不向 create 猜加 CPU/内存/固件参数。
创建/配置分别只发送一次，核查与继续配置分开；未知创建不按同名 VM 自动认领。
共享唯一 VMM 协调器增加名称/新 VM 互锁，不新增持久化、依赖、权限或并行实现。
创建核心/正式 HTTP 回归先集成，再接原生向导；生产行为门保持关闭。

公开空白盘与已有 disk 映像克隆均保留范围，最多 8 盘/8 网卡是客户端上限而非宣称
服务器上限。公开 Guest.get 不提供源 image_id，含克隆盘时不能只凭大小/数量声称
来源验证完成，应明确待核查。ISO 引导/固件/系统类型/高级硬件与创建后自动开机仍
在完整对齐目标中，不能复制 Mac 内部参数补齐；本切片不自动删除失败资源/清理任务。
五端影响为 Windows 增量，其他四端仅评估不改；回滚关闭新能力并撤销增量，不影响
既有 VM/数据。源码复核另发现公开 Storage.list size/used 单位为 MiB，既有 Windows
摘要按字节显示且读错已用字段，作为创建前置依赖一起纠正，不扩张其他资源解析。

实际完成创建核心：新增 VirtualMachineCreation 兼容请求/结果/恢复、Repository
默认增量与公开 partial，复用唯一 VMM 协调器、API 客户端及设置解析。等待前复制
确认列表；名称占用、存储身份/状态、已连接网络和映像源重新读取。未连接网卡不
依赖 Network.list。只认本次返回的任务，不按同名 VM 恢复；task_info.guest_id
必须不在创建前清单中，磁盘/网卡 ID 唯一且符合原请求后才允许设置。

ReviewCreation 只读；ContinueCreation 必须重新确认且生产门允许。create/set
各只发送一次，配置回执丢失只核查。运行中需要更改硬件时等待，不自动关机；明确
配置拒绝报告 VM 已存在的部分失败，不自动删除。最终同一 Guest.get 快照同时
核对配置和资源，不能用 CPU 正确掩盖磁盘漂移。含克隆盘保留来源待核查；已经确认
的配置不会因后来外部修改而隐式再写。会话内恢复按连接隔离，返回独立副本并清除
旧确认，不新增持久恢复格式。原始 task_id 不进入领域恢复/结果、日志或 URL。

新增正式测试 30 项（创建 29、存储单位 1），最终全量 **2738 通过、1 失败、0 跳过，
共 2739 项**。唯一失败仍为符号链接创建缺少本机权限，未跳过/降低断言。较早聚焦
虚拟机为 156 项通过，最后增加未连接网络独立性后已跑全量。最终 x64/ARM64 正式
配置均构建通过，0 警告、0 错误。覆盖 FORM/JSON、异步分步、回执丢失、资源漂移、
明确拒绝、取消、名称和 VM 互锁、请求 ID 冲突、恢复隔离与确认快照。

独立只读对抗复核完成：固定公开版本、动态发现路径、按实际格式编码，无私有回退；
旧 VM 不被任务假身份误配置；新 VM 的状态/资源不符就停止配置，未知不重发或删除。
生产门保持 false，无真实 NAS 写。原生向导/进度/继续/恢复界面是下一切片，本轮
未新增 UI 或重新打包，前次 204714 包不含创建核心和容量修正。Mac 下载/照片修复
仍待 Mac 构建实测，未用 Windows 结果替代；所有旧改动保留，未暂存/提交/推送。

PENDING_USER_VALIDATION：向导接通后，另行授权可恢复 VM/测试存储，验证空白盘、
映像盘、多网卡、基础设置、断线及权限拒绝；未知不能重复创建，部分失败保留资源。
映像来源、真实资源上限、ISO/固件/系统类型、自动开机和任务清理仍未完成。回传只
包括版本类别、步骤及脱敏错误，不含任务标识、NAS 地址、账号、资源名或原始响应。

实际执行命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachineCreation' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachine' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
```

#### 2026-09-19 Windows VMM 异步任务跟踪

创建/映像导入的依赖切片：macOS createVirtualMachine 用户结果为创建后核查资源；
Windows 按官方 Task.Info v1 list/get 跟踪，不复制内部创建请求。官方 finish 仅代表
结束，不能从 status 文本猜成功/失败；具体创建结果仍须后续按 guest_id 回读。
本波单一范围为兼容领域/Repository 增量、公开任务适配器、独立任务状态层、VMM
任务页及双语/测试。完整读取任务 ID 清单，每项独立读取状态；标识单向摘要后进入
领域，不显示账号前缀、原始状态、任务正文或资源身份。页面可见且有进行中任务时
刷新，离页取消，错误保留旧列表，分区错误不影响 VM 主页面。任务清理/创建/导入
及具体结果验证仍留后续，不以任务结束假装完整 VMM 完成。无新依赖、存储或系统
权限；Windows 代码增量，其他四端不改，公开契约语义同步矩阵，不外推真实验证。

实际接入 Task.Info v1 list/get：使用发现路径及 FORM/JSON 参数编码，完整处理 ID
清单，不截断 100/200 项；逐项失败保留“无法读取”条目，会话失效/取消则终止请求。
原始 task_id（可能含账号前缀）仅留在网络边界，领域稳定键绑定当前连接后单向摘要。
不传递原始 status、消息、日志或创建资源 ID，不从 100% 推断结束或成功；finish=true
仅显示已结束待核对。没有增加清理、取消 NAS 任务、创建或内部回退请求。

新增任务页独立于已有七分区，加载/空/错误/不可用/正常以及部分失败均有明确状态。
没有筛选控件，因此无筛选为空分支。任务页可见且存在进行中或状态读取失败时，前次
读取完成后每 2 秒刷新；离页/销毁/切换连接取消等待，旧代次结果不能污染新页面。
会话失效清空并要求重连；瞬时刷新失败保留旧列表。手动刷新确认全部结束后，挂起
计时器也不会额外发送读取。稳定条目复用，不在每次刷新重置整张列表；顶部 F5 路由
到任务刷新，任务页仅显示自己的刷新按钮。没有引入持久缓存或后台系统注册。

新增正式测试 24 项（HTTP 请求/解析 16、状态层 8）随全量通过；全量为 **2708 通过、
1 失败、0 跳过，共 2709 项**。唯一失败仍是本机符号链接创建缺权限，未跳过或降低
断言。中文原生 10 场景在 windows/dist/ui-review-20260919-201726，英文 10 场景在
windows/dist/ui-review-20260919-201844，均通过；浅深色内容图已实际查看。合成宿主
将离页取消/停止轮询断言移到完成标记之前，避免截图后进程提前终止造成假通过。
初次 XAML 构建暴露 Pivot 选项的引用比较警告作为错误，改用 ReferenceEquals 后重建。
目标架构构建和最后去除重复刷新按钮后的聚焦原生复核另记。

x64/ARM64 正式配置构建均已运行并通过（0 警告、0 错误）。用户随后报告 macOS 1.0.9
下载/照片保存/删除故障，当前优先处理该反馈；本波未继续打包，既有 165933 包不含
任务页增量。去除任务页重复顶部刷新按钮后的原生截图复核待续，不以旧图替代最终图。

2026-09-19 收尾复验：去除重复刷新按钮后的最终中文 10 场景、英文 10 场景均重新
执行通过，输出分别为 windows/dist/ui-review-20260919-204450 与
windows/dist/ui-review-20260919-204649；实际查看浅深色任务内容和英文刷新失败图，
无缺失/重叠，列表保留旧结果。独立安全复核未发现新增写方法、任务身份显示或后台
注册；页面之外不发请求。全量再跑仍为 2708 通过、1 个符号链接权限失败、0 跳过，
保留完整失败记录；本地化最新资源数为 Apple 4033、Android 2188、Windows 2914。
本地化、96 请求 fixture、3 响应组/22 私有引用、严格文档预检和 diff --check 均通过。
Mac 源码修复继续待 Swift/macOS 验证，本次 Windows 结果不为其背书。

最终独立包：windows/dist/20260919-204714/LanStash-0.1.0-x64.zip 与同目录
LanStash-0.1.0-arm64.zip。`./windows/package.ps1` 在现有工具链下以
LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=0、
LANSTASH_LAUNCH_AFTER=0 完成两架构 Release 自包含构建/打包，测试单独运行且如实
保留权限失败。没有安装/启动或覆盖旧包，没有提交/推送；build-info 标注基于
main@0eeeb170358c 及未提交工作区。重新计算 SHA-256 与两个 sidecar 一致：

```text
x64   27E04F0758CCE3957C87C78061BF08AC189B23F650A9AA441C74A162650B5350
arm64 4337A5F3E8D8367AB42FFB3C6C0513E96687CF68DCA723C0D7559FA0C510E9BC
```

本次实际英文最终复跑使用 `./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios vm-tasks
-Language en-US -WindowWidth 1000 -PaneState compact`，复用同一刚构建宿主，无旧二进制
替代新源码。所有变更与构建输出保留原有所有权，既有清理受限的忽略产物未绕过限制。
下一切片继续 Guest.create 的请求、任务身份绑定和资源结果核查；任务清理、创建/
导入、高级 VMM、容器写管理与系统集成仍未完成，目标不缩减为本波只读任务页。

本地化新增 16 对资源，完整性/引用/参数/硬编码检查通过：Apple 4031、Android 2188、
Windows 2914。96 请求 fixture、3 响应组/22 私有引用校验通过；未新增私有接口。
独立集成与只读对抗复核涵盖敏感标识隔离、严格 finish/progress 类型、无截断、
身份冲突、会话错误、不重叠读取、迟到结果及页面销毁；未作任何真实 NAS 调用。

PENDING_USER_VALIDATION：需 Windows 连接安装 VMM 且允许读任务的账号，在任务页
查看现有异步任务、切换分区、网络断开/重连，核对结束/进度/读取失败及无重复后台
请求。仅回传版本类别、操作步骤、脱敏错误，不含 task_id、账号、资源名或原始响应。
真实大量任务性能、Narrator/触控/缩放、ARM64 运行仍待验收。创建/导入会话的具体结果
身份及资源回读仍是下一依赖切片，不能以本页“已结束”替代创建成功。

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachineTasks' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios vm-tasks -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios vm-tasks -Language en-US -WindowWidth 1000 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
```

#### 2026-09-17 macOS 基线设置漏核查修复

证据为共享 DsmServiceManagementRepository.updateVirtualMachine 及其既有 machine 解析：
提交可包含六类字段，旧实现仅核查三类，空说明及自动启动缺失/默认值不能证明成功。
本波独占该方法、私有核查辅助及正式测试，保留同文件其他已有改动。采用既有内部
Guest.list 读取与已存在的字段名，核对实际发送值，不引入新端点或推断 autorun 的
用户语义；CPU 权重等值仅作已有写契约的精确回显验证。浏览器连接不可用，所有新增
结论仅为源码/合成待跑，不升级内部契约证据；原有写门不放宽。跨端影响为 Apple
共享实现行为纠正，Windows 使用公开三态契约不改，iPhone/iPad 不新增入口，Android
仅记录影响不修改。无需接口/持久化/依赖迁移，回滚限本次方法增量。

实际修改：updateVirtualMachine 保存后直接复用既有内部 Guest.list，按唯一 guest_id
找到原始对象，只比较已发送的 name/desc/vcpu_num/vram_size/cpu_weight/autorun。
数字不接受布尔、字符串或小数近似，空字符串说明可核查，名称按实际规范化后发送值
比较。核查不匹配以不可自动重试的 conflict 报告，既有双语提示改为先在 DSM 核查、
不要重复保存。没有改动通用数字解析器、创建接口、公开接口、Mac UI 或其他已有改动。
这不是恢复协调器：方法仍为既有 async throws Void，跨进程未知写恢复未在此切片实现。

新增 4 个正式 Swift 测试方法覆盖：六字段成功/清空说明/名称规范化；说明、权重、
自动启动未匹配/缺失/错误类型；公开读取与内部写回读隔离；错误或重复目标。
`swift test --package-path apple --filter DsmServiceManagementRepositoryTests` 实际尝试
失败于找不到 swift，测试未执行、未编译，不用 Windows 静态检查替代 Mac 回归。
本地化检查通过（Apple 4031、Android 2188、Windows 2898），响应 fixture 三组及
私有文档引用 22 项通过；严格文档预检、差异空白检查通过。只读复核覆盖参数的真实
类型、ID 唯一性、读取接口来源和无隐式重发；未升级设备验证或扩大写入口权限。

PENDING_USER_VALIDATION：在 Mac 上运行上述聚焦测试及 `swift test --package-path apple`
完整回归；专用可恢复 VM 经明确授权后核查说明清空、CPU 权重、自动启动实际含义及
错误类型/断线提示。预期未核查的字段不显示保存成功，不能把字段回显当成开机策略
验证。回传仅版本类别、失败用例、脱敏错误，不含账号、VM 名称、路径或响应原文。
此波未生成 Mac 包、未安装/启动、不提交或推送；保留所有已有工作区改动。
浏览器连接恢复后再核对内部语义，期间继续 Windows 不依赖该证据的创建/管理流程。

#### 2026-09-17 官方 VMM 基础编辑

用户已批准兼容扩展，本波完成官方 Guest.get/set v1 的名称、说明、vCPU、内存和三态
autorun 编辑。依据官方指南与 macOS updateVirtualMachine 的用户结果，优先使用公开
new_guest_name/description 字段，不复制 Mac 内部 name/desc 或布尔 autorun 的不同
契约。CPU/内存沿用 Mac 的停机编辑与客户端范围；CPU 权重等内部高级字段仍留后续。
范围为 VMM 兼容模型/接口、既有 VMM 唯一协调器、原生表单和回归；不新增存储/权限/
依赖或真实 NAS 写。原值漂移拒绝提交，只传修改字段，逐字段回读；未知只核查，与电源
操作按同 VM 互斥。五端影响为 Windows 增量，Apple/Android 不改；回滚关闭新能力并
撤销增量，不回退已确认的读取修复。

实际新增 VirtualMachineSettings 领域配置/校验/请求、Repository 默认增量、公开适配
partial、设置状态层和原生表单；既有 VMM 协调器同时锁定电源与编辑，不增加平行实现。
WinUI 从详情进入，名称/说明可编辑，运行中禁改 CPU/内存，自动启动使用三项选择；
草稿改变使确认失效，保存成功重新读取真实基线，部分/未知只允许核查。恢复时重新
计算电源临时互锁，不能把已结束电源操作造成的禁用永久保留；未知保存仍禁止重放。
公开读取缺字段/错误类型/目标不符不会填默认值，明确拒绝不能被其他人的变更冒充成功。
原生表单含只读、加载、失败、正常、无效输入、成功和部分结果态；固定目标单项编辑
不存在列表空内容/筛选为空状态，目标消失归读取失败，不伪造空配置。

22 项新增测试随全量运行通过（请求链 15 项、状态层 7 项）；全量结果为 **2684 通过、
1 失败、0 跳过，共 2685 项**。唯一失败仍为 BoundedFolderUploadPlanTests 中本机创建
符号链接缺少权限，未跳过测试或降低断言。中文原生 9 场景、英文原生 9 场景通过，图
分别在 windows/dist/ui-review-20260917-165414 和 windows/dist/ui-review-20260917-165512。
首轮合成断言早于 DispatcherQueue 的按钮状态更新，补等待后复跑通过；生产断言和
门禁未削弱。浅深色、禁用硬件、结果提示已检查；x64/ARM64 正式配置构建均为
0 警告、0 错误。后续强化保存后可再次核查的原生断言，英文 9 场景再次通过。

收尾将设置窗口/状态层纳入已有页面源码安全检查，聚焦命令
`dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachineSettings|FullyQualifiedName~VirtualMachineManagerPageSourceContractTests' -v minimal`
为 28 项通过。强化的英文运行态重跑也通过控件断言；后续 RenderTargetBitmap 图像出现
仅绘制按钮的非完整输出（165816/170117），不将这些图片作为完整布局验收证据。
布局复核依据前述 165414/165512 的完整图，真实窗口/辅助功能验收仍待用户执行；没有
据此改动生产布局或降低控件断言，也未将异常图片宣称为正常界面。

本地化新增 34 对资源，资源总数 Apple 4031、Android 2188、Windows 2898；引用、
占位符和硬编码扫描通过。96 请求 fixture、3 响应组/22 私有引用校验通过。没有引入
内部编辑请求、磁盘/网卡/CPU 权重、持久恢复格式、依赖或权限迁移。恢复记录仅存在
当前 API 客户端内存；重启后必须核查 DSM 现状，不宣称跨进程恢复已完成。

独立集成及只读对抗复核：核对固定版本/单目标/类型、两方向请求 ID 冲突和同 VM
在途互锁、旧会话迟到隔离、确认后字段改变、回执丢失、取消及部分字段反向变化。
回读仅评价修改字段，不要求无关并发修改恢复旧值；已确认字段也不作永久粘滞成功。
生产行为门为 false，测试仅调用 internal 核心或合成仓库，无真实 NAS 写。

PENDING_USER_VALIDATION：专用可恢复 VM、具备配置权限的账号及单独明确授权后，核对
名称/说明、停机 CPU/内存、三态自动启动及断网后的逐项回读；预期未知不能重复保存，
权限不足不能冒充成功，运行中不能改硬件。回传只包括版本类别、操作步骤、脱敏错误
及恢复情况，不含主机、账号、VM 名称或真实数据。ARM64 运行、Narrator、触控、缩放
与实际资源上限仍未验证。macOS/iPhone/iPad/Android 本波代码未改、未运行其回归。

接续缺陷：只读复核 macOS 共享 DsmServiceManagementRepository.updateVirtualMachine
发现当前仅核查 name/cpuCount/memoryMiB，没有核查本方法允许的 description、autorun
与 cpuWeight。用户已授权同类修复，下一独立切片应先核对内部读取契约，再补齐实际
回读与回归；本次不以公开 autorun 值推断内部接口，也不宣称 Mac 已完成修复。

实际命令沿用本机现有工具：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachineSettings' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios vm-settings -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios vm-settings -Language en-US -WindowWidth 1000 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
```

目标构建实际命令：

```powershell
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

本波独立包为 windows/dist/20260917-165933 下的 LanStash-0.1.0-x64.zip 与
LanStash-0.1.0-arm64.zip，包含设置读取/表单及关闭的正式写能力。package.ps1 使用
LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=0、
LANSTASH_LAUNCH_AFTER=0 执行成功；测试已单独运行并如实保留符号链接权限失败。
包为 Release 自包含、沿用原身份，未安装/启动或覆盖旧包。build-info 标注基于
main@0eeeb170358c 与未提交工作区；已重新计算并比对两份 SHA-256 sidecar：

```text
x64   8A97A06CEB866716C2B1D634C5B306FA7B2244F58AE7DDA5769C40766E9A901A
arm64 0B079CD2F28D3EDDE03383B18A1E145FACE59648C9430AB1E58EE51EBA7F3DB4
```

工作区仍保留此前所有用户/既有波次改动，未暂存、提交或推送。正式测试保留，未产生
真实 NAS 响应、截图或凭据。既有清理受限的忽略构建输出未绕过限制删除。
后续仍需 VMM 创建/高级管理、Container 写管理、系统集成及专用环境验收，不把本波
设置切片或可构建测试包视为完整功能对齐。

#### 2026-09-17 已授权的 VMM 电源操作主流程

用户已明确回复“允许”，并授权后续非高危操作：兼容 Domain/Repository 扩展可以继续，
不等于允许 Agent 执行真实 NAS 高危写。此波采用官方 Guest.Action v1 的 poweron /
shutdown / poweroff，按单 guest_id 请求并使用 Guest.get v1 核查身份/状态；官方回执
没有任务 ID，不虚构 Task.Info 轮询。macOS controlVirtualMachines 为语义参考，但其
公开 reboot 与逗号拼接多 ID 不在本次官方单机契约中照搬，重启/批量仍需独立切片。
范围为 Windows VMM 模型、兼容接口、模块唯一写协调器、单机确认/回读 UI 和聚焦
自动化；不改存储、身份、权限、依赖或 Android。正式危险写在专用 VM 验收前关闭，
源码/合成闭环不代替真实电源副作用。回滚关闭新增能力并撤销增量，旧只读接口保留。

实际实现：新增 VirtualMachinePower 请求/规则/恢复条目及接口默认成员；保留原有快照
签名。VMM 模块以同一 API 客户端的唯一协调器按 NAS/账号/地址与 guest_id 管理在途
命令，同一请求返回原结果，同一虚拟机待确认时不接受第二次命令。提交前 Guest.get
核对 ID、名称及已确认的起始状态；提交后只按原 ID 和目标运行/关闭状态核查，名称
后续变化不被误作新虚拟机。明确 API 拒绝不被其他客户端恰好改变状态覆盖成成功。
取消/回执丢失/过渡状态/畸形读取保留未确认，只读恢复不重放；不调用 Task.Info 或
任何内部电源方法。公开 booting/shutting_down/crashed 状态同步映射为变化中/异常。

原生详情新增三个动作，复用当前虚拟机选择；固定目标确认、影响提示、默认关闭、
单飞提交、状态核查和父列表刷新均接通。存在先前不同动作时，恢复反馈仍显示原动作，
不把先前开机的结果冒充当前关机。生产行为门为 false，不能把合成仓库启用当作真实
权限或副作用已经验证。普通关机尚未确认时，不自动升级成强制关机；批量、重启、
跨动作升级仍在后续切片，不把当前单机三个主流程当成整个 VMM 完成。

新增 HTTP 核心 **19 项**、状态层 **5 项**、官方过渡状态 **3 项**；核心/状态层
聚焦 **24 通过**，全量 **2662 通过、1 符号链接权限失败、0 跳过（共 2663）**。
旧页面源契约从笼统禁止 Power 改为要求已审核的确认/默认关闭，仍禁止其他写、控制台
和原始诊断；未删除既有安全断言。中文 **13 场景**及英文 **13 场景**通过，输出分别
为 `windows/dist/ui-review-20260917-161450` 与 `windows/dist/ui-review-20260917-161725`，
覆盖三动作、只读/加载/错误、拒绝/未知/恢复、关闭取消及父列表更新；浅深色已复核。

五端影响：Windows 新增兼容接口与调用方；macOS 为语义参考但无本波源码改动，
iPhone/iPad/Android 不增加电源入口、不改代码或协议。官方指南依据为
DSM_WEB_API_REFERENCE_ZH.md 第 7.1 节来源链接，公开动作按单机请求、空成功回执和
Guest.get 状态组合处理。PENDING_USER_VALIDATION：需另行指定可丢弃 VM 并授权高危
测试，验证权限、三种动作、正常关机等待、断线/取消与最后状态；不得对业务 VM 试探。
只回传版本/操作步骤/脱敏错误，不含 VM 名称、地址、凭据或控制台令牌。用户授权的
非高危操作照常推进；未变更存储、依赖、身份、签名或系统注册，未提交/推送。

本波恢复状态保留于同一 API 客户端的内存协调器，支持同进程 Repository/页面重建，
没有新增跨进程存储。界面只说操作及用户下一步，不暴露 API 或测试环境术语。原生
“核查状态”只读，同目标未确认时不提供重发。下一步继续 VMM 创建/编辑与其余容器
主流程，代码扩展已获批准，不再以旧审批问题暂停这些独立切片。

收尾：x64/ARM64 正式配置构建及独立打包通过，21 对新增资源中英齐全，资源数
Apple 4031、Android 2188、Windows 2864；只读说明改成普通用户文案后英文场景再次
通过（`windows/dist/ui-review-20260917-162428`）。本地化、96 请求 fixture、3 响应组/
22 私有引用、文档严格预检和差异检查通过。
包为 `windows/dist/20260917-162606/LanStash-0.1.0-x64.zip` 与同目录 ARM64 包。
沿用 `./windows/package.ps1`，LANSTASH_NON_INTERACTIVE=1、LANSTASH_TARGET_PLATFORM=both、
LANSTASH_RUN_TESTS=0、LANSTASH_LAUNCH_AFTER=0；测试已独立执行且保留权限失败，未
安装/启动或覆盖旧包，build-info 标注现有 main 基线及未提交改动。重新计算 SHA-256
与脚本 sidecar 一致：

```text
x64   BA7F2F97F14DF014833D3B996C05512A5743348E1322F73E8DFC2EFA7D74CAF7
arm64 1DBB8B5A014F1273DCEE19E25F9C3852505D26AC9910EBAC821465648E8E61CE
```

未提交/推送；保留原有改动及清理受限的忽略产物，不将包或合成门禁表述为正式发布
或完整 VMM/跨端目标已经实现。

实际验证命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachinePower' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios vm-power -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios vm-power -Language en-US -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios vm-power -States vmpower-readonly -Language en-US -WindowWidth 1000 -PaneState compact
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

#### 2026-09-17 网络删除核心与原生流程实际结果

macOS 证据为 `DsmServiceManagementRepository.swift` 的 `removeContainerNetworks` /
`deleteContainerNetworksResult` 和 `ServiceManagementModel.swift` 网络删除入口。
Windows 复用同一已记录 remove v1 契约；新领域请求与 Repository 默认成员是既已授权
的兼容增量，不新增平行管理器、权限、存储格式或依赖。高风险写生产门关闭。

实际修改范围：Domain `ContainerNetworkDeletion.cs`、Container Repository 接口，
Infrastructure 删除 partial 和现有创建/共享协调器的交叉锁；App 删除 ViewModel、
原生 ContentDialog、父页面按钮/清理/刷新及 21 对双语资源；正式 HTTP/状态层测试和
既有 UiSmoke 宿主；契约证据注释、平台矩阵与状态文档。其他四端仅评估影响，不改代码。

交互转换为 WinUI 多选列表、所选目标名称确认、默认“关闭”、只读结果核查和键盘聚焦。
仅列出已知未占用且非系统网络，刷新/改变选择即撤销确认；提交瞬间重新读取控件选择，
提交后停用旧列表，结果未知不重放。创建/删除间共享目标保护，关闭或切换页面取消等待，
晚到结果不污染新页面。批量回读按原 ID 计数，旧名称变化不能冒充删除成功；列表容器/
总数不完整不能证明目标消失。明确拒绝不会因另一客户端恰好删除目标而覆盖成成功。

本波新增删除 HTTP **24 项**、状态层 **7 项**，网络聚焦 **72 通过**。全量 xUnit
**2549 通过、1 失败、0 跳过（共 2550）**；失败仍是本机无创建符号链接权限的
`BoundedFolderUploadPlanTests.RejectsRootAndDescendantReparsePoints`，未降低断言或跳过。
中文原生 **16 场景**通过，包含只读/加载/错误/空列表/确认/改变选择/成功/部分/未知/
拒绝/恢复和忙时关闭；合成图位于 `windows/dist/ui-review-20260917-103330`。
英文 **6 场景**通过（`windows/dist/ui-review-20260917-103527`）。视觉复核发现英文
删除按钮截字，改为简短的“Delete networks”，重建宿主后再验浅深色确认 **2 场景**
（`windows/dist/ui-review-20260917-103930`），人工检查已完整显示。两架构构建通过；
最终包结果另见本节后续记录，不将打包进行中写成通过。

关键命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~ContainerNetwork' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios container-network-delete -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -SkipBuild -Scenarios container-network-delete -States netdelete-confirm,netdelete-partial,netdelete-unknown -Language en-US -WindowWidth 1000 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
git -c core.safecrlf=false diff --check
```

本地化初次发现一条内部异常中文字符串，已改为受控诊断键后复验通过；用户错误提示
始终走双语资源。资源数为 Apple 4031、Android 2188、Windows 2810；96 请求 fixture、
3 响应组/22 私有引用通过。
源码独立复核确认无新增真实请求、日志、凭据输出或私有接口猜测，写入口未绕过行为门。

PENDING_USER_VALIDATION：需另行授权可丢弃且无关联的测试网络，记录完整 DSM/套件
版本及权限类别，检查系统/占用网络不可选、确认变化、拒绝/断线只核查、删除后官方
列表回读；批量需单独验证，不外推既有单目标证据。仅回传版本类别、步骤和脱敏错误，
不含真实名称/地址/凭据。Narrator、触控、缩放及真实删除副作用未验收。未提交/推送，
保留既有未提交改动及清理受限的忽略产物。其他容器/映像/项目、VMM 与系统集成仍需
继续，完整目标不因网络管理本波源码/合成闭环而结束。

最终独立包：`windows/dist/20260917-104023/LanStash-0.1.0-x64.zip` 与同目录
`LanStash-0.1.0-arm64.zip`。两架构均通过既有 `./windows/package.ps1` 构建和打包，
设置 `LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_TARGET_PLATFORM=both`、
`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0`；全量测试已单独执行且保留上述
权限失败，未在打包脚本中重复运行。包沿用 unpackaged 自包含形式、原应用身份及
`main@0eeeb170358c` 加工作区改动，未安装/启动或覆盖旧包。`103746` 是按钮截字修复前
中间包，不作为最终交付。SHA-256 已与脚本 sidecar 逐一重新计算核对：

```text
x64   AE29E1FBFA463BB6FDD8EC20843F066717E3177940A4748D25F6C3E0936889B6
arm64 894716688E8B15C8FDC933AF6576CEA340C4CC324A2ED36356AA22E383B56DBD
```

另执行 `dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release
-p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal`，
结果 0 警告、0 错误；x64 同形命令亦通过。最终文档严格预检和差异空白检查通过。

- NAS 健康、存储、服务、套件和日志优先提供有界只读摘要与独立失败降级。
- Container/VMM 生命周期、删除、网络和 noVNC 等高风险功能必须由独立 capability、
  确认、任务轮询、会话清理和真实专用 NAS 验证解锁。

### W4：系统集成与发布

#### 2026-09-17 VMM 既有读取完整性与请求格式

多标签/下载任务结构扩展尚未收到新确认，本波不触碰该范围。独立核查发现 Windows
VMM 所有返回数组被客户端静默截断到 200 项，保护规则三组共用该额度；日志虽请求
1000 条也只解析前 200 条。macOS 的对应资源读取/strictSupplementaryItems 不使用此
客户端截断。另有内部日志 JSON 字符串参数未编码、能力元数据未校验格式/名称的问题。
本波限定现有 VMM partial、读取回归与矩阵说明，不改公开接口/模型、UI、存储或权限；
不新增内部回退、写方法或未经记录的日志后页请求。目标为完整呈现既有响应，日志仍按
现有已记录首批 1000 条范围，不宣称全部历史。五端无契约迁移，仅 Windows 纠正既有
实现偏差，Apple/Android 不改；源码/合成/构建与真实 NAS 验收分别记录。

实际改动已完成：移除数组 Take(200) 及保护规则共享余量；JSON 日志参数只编码字符串，
数字保持原值；能力名称、有效版本范围、FORM/JSON 格式在可用性与调用两层核对；已知
根容器错误/冲突不再被另一空组掩盖。旧“保护规则最多 200 项”测试改为明确保留 270 项
及每组三组各 90 项，新增 **17 项**真实 HTTP 合成回归，包括五个公开分区各 201 项、
日志单页 1000 项、尾部畸形项失败和能力关闭；完整条目同时通过实际 ViewModel 显示
集合复验。公开 v1 优先、内部独立分区、认证/取消传播和无写入口策略保持不变。

VMM 聚焦 **54 通过**；全量 **2600 通过、1 失败、0 跳过（共 2601）**。唯一失败仍为
本机缺创建符号链接权限的既有测试，未删断言、跳过或修改系统权限。没有新 Mac/Android
修改，不将此前待执行的 Swift 回归标成通过。窗口/XAML 未改，本波不新增原生绘制结论。

实际命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~VirtualMachine' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
```

独立集成复核：仅修改现有 VMM partial、现有读取测试及新增 WireTests；没有改变
Repository/领域类型、固定请求方法、公开/内部优先级或风险门。批量返回之后的坏项仍
能触发分区失败，不通过截断掩盖错误。PENDING_USER_VALIDATION：真实 VMM 环境核对
七分区、大量条目、JSON 声明、权限和断网恢复；只回传版本类别、操作步骤和脱敏失败，
不含虚拟机/主机/网络/路径或日志正文。完整历史分页、生命周期、控制台与系统集成仍需
继续，不以本读取切片代替完整 VMM 对齐。多标签/下载任务结构审批保持待确认。

x64/ARM64 正式配置构建均通过，0 警告、0 错误。本地化资源仍为 Apple 4031、Android
2188、Windows 2838；双语/硬编码、96 请求 fixture、3 响应组/22 私有引用、严格文档
预检及差异检查通过。既有 `./windows/package.ps1` 以非交互、both、自包含模式生成
`windows/dist/20260917-142924/LanStash-0.1.0-x64.zip` 与同目录 ARM64 包；同时包含
前一波 Image.list 参数修正。环境为 LANSTASH_NON_INTERACTIVE=1、
LANSTASH_TARGET_PLATFORM=both、LANSTASH_RUN_TESTS=0、LANSTASH_LAUNCH_AFTER=0；
测试已独立运行且保留权限失败，未安装/启动、覆盖旧包或提交/推送。build-info 标注
main@0eeeb170358c 加全部既有工作区改动，不冒充新提交或正式发布。两包重新计算
SHA-256 与脚本 sidecar 相符：

```text
x64   B19A0F1EE9D117C78706D6A074F55724E772F2EF0B92639276C942F698077DE5
arm64 410BDCCC12DCD76F4251FA2F6738DA60BCAB9633F3E155FEC66435FEE565F04B
```

保留用户已有的 VMM 界面资源/源码测试改动，未把它们归为本波重写；清理受限的历史
忽略产物继续保留。下一切片继续核查不依赖待审批模型的已有业务链和系统集成。

#### 2026-09-17 映像下载契约前置核查

本波仅做独立契约切片：macOS `pullContainerImage` 当前只等待 pull_start 回执；已有
记录不能确定任务身份、终态或可靠结果核查。Windows 完整目标是选择映像/标签后确认
下载、准确区分接受/完成/未知并避免重放，但不得用猜测构建该流程。范围限定官方页面
只读核查、脱敏记录及契约/五端影响说明；暂不改 IContainerManagerRepository、Domain
下载类型、Registry 提交逻辑或下游 fixture。高风险写保持关闭；取得具体契约后先说明
新增接口的影响/迁移/回滚并获批准，再进入实现。此顺序不删除或缩小下载功能目标。
环境记录见 [映像下载只读核查](../api/discovery/environments/2026-09-17-container-image-pull-read-observation.md)。

只读核查已完成：当前 DSM 7.2.1-69057 Update 12 / Container Manager 24.0.2-1535，
管理员；设备归属仍未知。官方 Image.list 必须传 offset=0、limit=-1、show_dsm=false；
tags 是字符串数组，不是单个 tag。前者属于现有请求的可复现偏差，已在 Windows
Container partial 和 Apple 共享 loadContainerManager 中纠正，并在总数/起始偏移
不符或字段畸形时仅让映像分区失败。没有扩展任何公开接口/领域类型或猜测下载状态。
新增 Windows HTTP 回归 **9 项**，Container 聚焦 **156 通过**；全量 **2583 通过、
1 符号链接权限失败、0 跳过（共 2584）**。Apple 新增 2 个测试方法；尝试执行
`swift test --package-path apple --filter DsmServiceManagementRepositoryTests` 时找不到
swift，故共享包/Mac 回归未运行，保持 PENDING_USER_VALIDATION。

Windows x64 与 ARM64 正式配置构建均通过，0 警告、0 错误。本轮未改 UI，无新增原生
绘制结论；未重新打包，前次 110409 测试包不包含本次列表参数修正。当前源码/构建与
旧包边界分别保留，待下一次集成包统一交付。本地化、请求 fixture、响应/私有引用、
文档严格预检与差异检查通过；没有运行真实 App 下载或改变 NAS 映像。

官方脚本提供 pull_start→task_id→pull_status 的静态路径，以及聚合任务列表查询，
但没有本次任务成功/失败/取消的行为证据。只读页也确认映像 tags 多值；旧单 tag 模型
会丢失语义，不能用默认 latest 或仅取首标签掩盖缺口。下一步拟审批范围如下：

- 为 Windows 与 Apple 共享映像模型增加兼容的多标签表达，保留旧调用方兼容；不改变
  数据存储、账号配置、应用身份或最低系统版本，不修改 Android 代码。
- 待下载任务字段/终态证据闭合后，增量引入绑定 NAS、映像/标签、确认与请求标识的
  下载请求，以及仅针对本次任务的进度/结果核查和未知恢复接口；复用现有 MutationResult。
  不把全局 admin 任务列表作为默认恢复路径，不猜测任务身份类型、失败码或清理方法。
- 迁移：Windows Registry 搜索/标签 UI 接确认及核查；Apple App 逐步消费多标签，
  移动端只维持已批准只读范围；Android 仅记录影响。接口默认成员应保持旧实现可构建。
- 回滚：关闭新入口并撤销新增可选类型/方法及调用方，不回退已确认的列表请求修正，
  没有磁盘数据迁移。危险写继续受行为门保护，不因批准代码扩展自动授权真实下载。
- 此处仅为待审批方案，不是已实现契约。运行时任务与异常证据还需要用户指定可丢弃
  测试目标并单独授权；未获授权不执行下载或为了测试而删除现有映像。

当前仅修改内部读取实现、聚焦测试、环境记录/端点/矩阵说明；工作区原有改动全部保留，
没有提交/推送。五端影响与静态/只读/行为证据在端点记录分别说明。浏览器核查使用
computer-use 技能及已登录 Chrome 的官方页面和已加载脚本；未保存 HAR、截图或真实
载荷，停止监听并清理临时内存。该契约切片和修复不代表下载、VMM 或完整目标完成。

实际验证命令：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~Container' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

#### 2026-09-17 Container 映像仓库搜索与标签

本波基线为 `DsmServiceManagementRepository.swift` 的 searchContainerImages /
loadContainerImageTags，以及 `ServiceManagementView.swift` 的 PullImageSheet；契约
使用 container-manager-internal 已记录 Registry.search/tags v1。Windows 先接完整
搜索→选择仓库→读取/筛选标签的只读主流程，键盘搜索、选择、刷新与取消采用 WinUI。
搜索明确只显示首批 50 项，不冒充完整仓库清单。范围限定兼容 Domain/Repository
增量、Registry partial、状态层/原生对话框、双语资源与正式回归，以及本账本/矩阵；
共享 Container 编码只增加已记录 page_size 数字参数，不改其他请求。API/存储/依赖
没有迁移；Apple 三端与 Android 仅评估影响，不改源码。已有授权覆盖兼容接口增量。
内部只读等级当前为已有 observed 契约加待运行合成；真实搜索、权限和弱网仍需验收。
拉取/删除及容器生命周期保留为后续高风险切片，不能因搜索成功而开放写操作；整个
容器/VMM 和系统集成目标仍保持不变。

实施中发现 Apple `loadContainerImageTags` 使用 `objects(...).compactMap`，使已记录的
字符串标签数组全部丢失，混合畸形项则被静默忽略。用户已授权类似基线缺陷同步修复，
本波据此例外仅修改共享 DsmNetwork 的该方法及 2 个正式测试：支持顶层/已记录容器中的
字符串和对象标签、原顺序去重，错误类型/冲突别名/缺失数组明确失败；没有改 App UI、
方法签名、其他三端代码或存储。`swift test --package-path apple --filter
DsmServiceManagementRepositoryTests` 已尝试但因本机找不到 swift 未执行，Mac 及共享
调用方回归均为 PENDING_USER_VALIDATION，不能用 Windows 通过替代。

Windows 实际范围为新 Registry 领域模型/校验、接口默认增量和 DsmRepository partial；
现有 Container JSON 数字参数名单增加 page_size。请求始终使用已发现的 NAS 路径，
不会直连第三方站点；支持既有传输层顶层数组包装，不新建 HTTP 客户端。空列表与错误
分离，可选官方/可信/自动构建徽章只在原生布尔明确为真时显示。WinUI 复用既有映像页
添加搜索窗口，选择结果后按名称读取标签，支持标签筛选和文本选择；首批限制与未开放
下载均明确展示，不伪装完成映像写管理。

状态层已覆盖改词取消旧搜索、切换仓库隔离旧标签/旧错误、失败重试、筛选清除选择、
会话失效、离页与跨 Repository 迟到隔离。请求链 **16 项**及状态层 **9 项**合计
**25 通过**。中文原生 **14 场景**通过，图在 `windows/dist/ui-review-20260917-105641`。
首轮原生筛选断言在 TextChanged 派发前读取，补事件处理等待后通过；另修正合成宿主
把选中引用 TextBlock 误转为 TextBox 的分支。生产状态层断言未削弱。
旧源码测试原先笼统禁止任何 Registry；本次改为要求已记录 search/tags 读取存在，
并把新适配器纳入 pull_start/create/delete/start/stop 等禁用写方法检查，未开放其他写。
最终全量、双架构、英文绘制和打包结果在下方补记。

最终全量 **2574 通过、1 失败、0 跳过（共 2575）**，唯一失败仍为本机符号链接权限，
未降低断言/跳过/更改权限。英文原生 **14 场景**通过，图在
`windows/dist/ui-review-20260917-110100`；复核浅深色、正常与筛选为空图，给滚动内容
右侧留出间距以避免按钮贴近滚动条。搜索/标签列表各自可滚动，整个窗口也支持滚动。
x64 正式配置构建及 ARM64 正式配置构建均为 0 警告、0 错误；最终打包另记。
本地化资源数 Apple 4031、Android 2188、Windows 2838；28 对新增资源、参数与硬编码
扫描通过。96 请求 fixture、3 响应组/22 私有引用、文档严格预检和差异检查通过。

实际执行命令（沿用已有本机 dotnet 与 Python，无工具链安装）：

```powershell
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore --filter 'FullyQualifiedName~ContainerRegistry' -v minimal
dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj -c Release -p:Platform=x64 --no-restore -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=x64 -r win-x64 --no-restore -p:LanStashUiSmoke=false -v minimal
dotnet build windows/src/LanStash.App/LanStash.App.csproj -c Release -p:Platform=arm64 -r win-arm64 --no-restore -p:LanStashUiSmoke=false -v minimal
./windows/tests/UiSmoke/run.ps1 -Scenarios container-registry -Language zh-CN -WindowWidth 1000 -PaneState compact
./windows/tests/UiSmoke/run.ps1 -Scenarios container-registry -Language en-US -WindowWidth 1000 -PaneState compact
python tools/localization/check_localization.py
python tools/request-contract/validate_contracts.py
python tools/contract-validation/validate_fixtures.py
python tools/codex/check_documentation.py --strict-release
git -c core.safecrlf=false diff --check
```

独立只读复核：固定 API 版本与请求格式，动态路径沿用现有同源与会话传输；没有第三方
直连、自动拉取、凭据输出或权限变更。身份和数组错误不能返回伪装完整列表，徽章未知
不作可信；共享 Apple 仅修标签解析，保留全部已有下载/网络改动。未提交/推送，保留
已有用户改动和清理受限的忽略产物。下一切片继续映像拉取/删除及容器生命周期的契约
和安全工作流；VMM/系统集成及真实验收保持完整目标，不因本次只读流程结束而缩小。

PENDING_USER_VALIDATION：需真实 Windows 连接及可读取 Container Manager 的账号，
在映像页搜索公开名称、选取结果、读取/筛选标签、快速切换、断网后重试；结果/错误/空
列表应明确区分，未显示虚构标签或发生下载。Mac 需先运行共享服务聚焦与完整回归，
再核对相同标签形态。回传仅版本类别、步骤和脱敏错误，不含 NAS 地址、凭据或用户
路径；Narrator、触控、缩放及其他 DSM/套件版本尚未验收。本波不作真实 NAS 写操作。

本波独立包为 `windows/dist/20260917-110409/LanStash-0.1.0-x64.zip` 与同目录
`LanStash-0.1.0-arm64.zip`，包含本次搜索与标签入口。`./windows/package.ps1` 以
`LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_TARGET_PLATFORM=both`、
`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0` 执行成功；测试已独立运行且保留
权限失败，打包不重复运行。两包均自包含、沿用原身份，未安装/启动或覆盖旧包，
`build-info.json` 标注包含未提交改动；SHA-256 与脚本 sidecar 已重新计算比对：

```text
x64   DDFE337065796C4895B7C912923C405B5F5A310BFCDA82D000E794286CE06D4E
arm64 2DFB71983DD0035D9D51216B871D00A797E8D738F8E42DB78ACCE805F585E345
```

- 在 Windows 设备验证 Explorer、Cloud Files、通知、托盘、安装、更新、外接卷、恢复和
  辅助功能。
- 发布前只在批准的形态下处理签名、安装、更新和卸载；如需改变形态，单独提供迁移与
  回滚方案并取得用户批准。

## 验证策略

| 范围 | 自动化 / 构建 | 用户验证 |
| --- | --- | --- |
| Domain / Infrastructure | xUnit、fixture、source contract、公开/私有 API 边界。 | 真实 DSM、套件版本、权限和断线。 |
| WinUI | XAML、资源、ViewModel 状态与目标架构构建。 | Narrator、高对比、缩放、键鼠、触控和窗口尺寸。 |
| Cloud Files / Explorer | 可重跑的领域和恢复测试。 | 系统回调、取消、文件打开、固定/释放、重启和外接卷。 |
| 认证、证书、危险写 | 静态安全门、结果映射和只读对抗复核。 | 专用 Windows 与 NAS 上的确认、重复提交、回读和清理。 |

完整 Windows 验证由托管 Windows Runner 运行 x64、ARM64、xUnit 和 WinUI XAML。非 Windows
环境中的源码阅读或部分项目编译不能替代该结果。缺少真机时标记
`PENDING_USER_VALIDATION`，不阻塞不依赖设备的源码切片。

## 关闭态与真实环境

以下条件未具备时保持关闭、只读或 capability 门保护：

- 私有写 API 在未记录的 DSM build / 套件版本；
- 删除数据、账号、套件、网络、电源、磁盘和跨 NAS move；
- Container/VMM 生命周期、网络、删除和 noVNC；
- 未验证的 Cloud Files 写回、安装、通知注册和 Explorer 系统回调；
- 需要正式证书、Windows 身份或系统注册的发布功能。

用户回传只包括系统/架构类别、步骤、预期/实际可见结果、清理状态和脱敏失败语义；不得
包含主机、账号、NAS 地址、路径、Cookie、SID、SynoToken、真实文件名或原始响应。

## 交付要求

每个 Windows 切片报告实际改动、关键决策、运行命令与结果、未验证风险、工作区状态、
剩余步骤和禁止触碰的并发改动。不得降低断言、删除既有测试或将真实环境缺失变成静默
跳过；完成后执行独立集成审查和高风险路径的只读对抗复核。
