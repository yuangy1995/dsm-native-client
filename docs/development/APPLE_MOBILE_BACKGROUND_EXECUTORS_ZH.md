<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-10 -->

# M8d 照片、跨 NAS 与 Office 后台实施账本

M8d 已接照片上传/导出、跨 NAS 复制与独立删源、Office 下载与主动回传的系统执行时间，并完成本机分片回归。系统是否继续运行、锁屏文件保护及真实 NAS 仍按本页末尾条件验收，不承诺进程终止后继续。

Files 是独立系统入口，默认只读和编辑回传已有两端本机通过证据，历史系统读访问占用及云端清理失败仍保留；完整云端复验按用户要求延期，见 [Files 账本](APPLE_MOBILE_FILES_PROVIDER_ZH.md)。本页的最初来源与逐轮测试仅为历史，不替代当前交付结论。

## 基线、范围与单一修改所有者

| macOS/共享证据 | iPhone/iPad 等价结果和交互 | 依赖、安全与当前状态 |
| --- | --- | --- |
| `SynologyPhotosModel.startUploadQueue/stopUploadQueue`、Mac 照片上传队列 | 用户开始照片上传后切换 App，系统允许时继续当前批次；时间到期取消在途上传并停止后项，保留未知结果供原恢复流程处理 | 沿用原照片上传、目录及相册写入契约和恢复记录；数据写与后台高风险。已接系统执行时间，到期取消与恢复受原上传队列约束 |
| Mac 照片下载/分享与移动 `MobileSynologyPhotosSession.beginExport` | 已明确选取的照片、相册打包下载可在系统允许的时间内完成；回前台交给既有保存/分享面板，取消/到期结束本次读取 | 沿用现有下载、部分结果与受保护临时目录；不在后台自动打开系统面板，不改原件。已接系统执行时间，到期清理临时资源并保留真实部分结果 |
| `WorkspaceModel` 跨 NAS 传输语义、移动 `MobileCrossNASQueue` 的复制与独立删源阶段 | 已冻结两端和清单的复制可继续；系统到期停止当前请求，保留逐项结果。移动仍须复制完成后另行确认删源，后台资格不触发新的删源操作 | 两端账号/证书、目标重名、内容比对、非递归删源、未知结果不重放；跨 NAS/危险写高风险。现有 Task 可取消，但未获得系统时间 |
| Mac `OfficeDocumentEditing` 的稳定副本/版本检查、移动 `MobileOfficeModel.prepare/save` | 预览副本下载和明确“保存到 NAS”的覆盖回传可继续；到期取消在途请求，保存中的未知结果保留原副本与只读恢复 | 原文件/账号、权限、内容摘要、写前保存及回读；覆盖写高风险。当前只有 generation 作结果隔离，没有完整持有并取消网络任务的系统时间接线 |

当前负责人单一修改上述移动执行器、照片会话、必要共享上传取消入口、组合根、
现有系统执行桥接、双语资源、正式单元/UI 测试及生成工程。M8c 文件属于同一负责人
的未提交工作，保持独立差异，不能覆盖或借机改动其权限和失败断言。Windows、Android、
NAS 请求及其他管理模块不进入本片；云端 DDNS 失败另按独立证据复核。

## 执行与安全决策

复用 M8a 的 `MobileTransferBackgroundExecution`：iOS/iPadOS 26 在用户前台开始时
请求持续后台时间；系统拒绝及 17–25 使用有限后台时间。保留现有传输和证书/同源
拦截，不切换到会自动跟随重定向的后台 URLSession。进度来自真实传输或实际完成
的项目，不用计时器制造进度；最终内容核对和记录保存完成之后才结束为成功。

系统结束只取消它绑定的执行，等待现有流程保存恢复结果后归还资格。每次继续具有
新执行身份，旧到期回调不能取消后来操作；换账号或关闭原模块取消旧网络，旧完成
不能写到新状态。照片只停止上传队列，不借取消上传去重置无关相册/浏览状态。
跨 NAS 到期不能开始后续文件或自动删源；Office 已开始覆盖后取消仍按未知结果处理。

不增加第三方依赖，不改变最低系统版本、应用身份、权限、NAS API、登录格式或
已有恢复文件格式。保持每种已有副本的文件保护等级和备份排除，不为后台执行降低
保护。共享上传取消入口只能是向后兼容的增量，macOS 仍保持原主动操作行为并回归。
回滚停用本片执行器的系统时间接线，保留原队列、副本和显式恢复，不自动删记录。

## 实施顺序与验收

1. 固定每个执行器的开始、字节/项目进度、取消、未知结果落盘和结束边界，接现有
   系统管理器；复用原算法，不维护另一套上传、跨 NAS 或覆盖回传流程。
2. 聚焦测试系统拒绝、到期、前后台切换、迟到回调、账号变更、提交前/后取消及
   重启恢复；保证未知写不重放和未开始项不继续。
3. 独立集成审查和只读对抗复核后，两端实际 UI、移动构建、共享与 Mac 回归、
   本地化/硬编码和文档检查；每个结果按真实运行记录，不由页面存在推断通过。
4. 真机持续任务授予/拒绝、锁屏、系统取消、强制退出、实际 NAS 和其他 App 交互
   最后列入具体 `PENDING_USER_VALIDATION`；不能承诺系统永久后台运行或强制退出后续传。

源码接线、两端 UI、共享回归与移动/Mac Release 构建均已通过本机验收。两端业务范围相同；自动照片备份、系统
日后自动重放上传、后台自动打开编辑器、桌面常驻监听和自动开启跨 NAS 删源均为非目标。

## 实施记录与独立复核（2026-10-07）

- 系统活动新增仅内存使用的 `MobileTransferBackgroundActivity`，跨 NAS 复制和删源
  各有双语标题；持久记录继续使用原 `MobileTransferDirection`，没有迁移格式。
- CrossNAS 从清单准备开始申请，复制与独立确认的删源各有执行身份。到期取消准备和
  实际执行并等待收尾；每项写前记录、非递归删除、摘要/目录回读及未知结果限制不变。
- Office 下载/覆盖由可取消的实际 Task 承载；到期和换账号取消旧请求。独立复核发现
  新 Task 尚未开始时存在同 UUID 换账号的调度间隙，已在进入 Task 前冻结 generation，
  并新增零旧/新账号下载断言。进度完成后仍等待版本检查和恢复记录落盘。
- Photos 共享模型仅增量提供上传生命周期通知、只取消上传并等待收尾的入口，以及
  暂停前台工作入口。移动观察者绑定旧模型，旧队列结束才释放资格，不影响新会话。
  导出保持原部分结果语义，系统整批成功只在全部文件交付时成立；取消清理整批临时文件。
- 首轮实际前后台 UI 发现照片页原 `scenePhase == background` 调用了完整停用，导致
  已开始的上传和导出一起取消。现改为暂停图库/预览/前台管理并保持传输，换模块、
  退出和换账号仍完整停用；新增主流程 UI 和会话级回归均已复验通过。
- 只读对抗复核覆盖写前取消、写后未知、后项不继续、旧回调、账号切换、记录落盘失败
  和部分导出。实际网络/恢复接口未改变，未新增后台自动删源、自动重传或永久执行承诺。

已运行：首轮 Office/CrossNAS/后台管理/普通上传下载 83 项通过；照片初轮 48 项中，
合成服务错误地在提交后抛出取消、违反现有 Repository 的未知结果契约，导致 2 个断言失败。
修正合成服务为提交后返回 pendingReview 后，同组 48 项全部通过，没有降低断言。
之后新增的调度间隙与照片页面生命周期修复另有下方最终回归；上述较早结果不能替代它们。
本地化扫描在当前新增两条活动标题后通过（Apple 7049 键）。

生命周期修复与调度间隙回归后的最终聚焦组已在 iPhone 模拟器通过 135 项。
完整共享测试 `swift test --package-path apple --parallel` 已通过 3103 项 XCTest 与
12 项 Swift Testing；最后修改前台暂停/持有任务后，补跑
`swift test --package-path apple --filter 'SynologyPhotos(Model|UploadRecovery)Tests'`
通过 260 项，并单独通过 Photos Feature 的 2 项恢复适配测试。Mac Release 主程序与扩展均构建通过，并核实为 x86_64/arm64。两端各五项新增
前后台 UI 全通过（iPhone 266.809 秒，iPad 293.593 秒），12 张最终截图逐张复核。
实际前后台使用合成传输；这些结果不能替代正式签名、持续后台资格和真实 NAS 验收。

## PENDING_USER_VALIDATION（本片不以模拟器代替真机）

| 前置条件 | 操作与预期 | 回传的脱敏失败信息与影响 |
| --- | --- | --- |
| 正式签名的 iPhone/iPad；iOS/iPadOS 26 与至少一台 17–25 设备；仅专用测试 NAS/自造文件 | 启动照片上传、照片/相册导出、跨 NAS 复制与 Office 保存，立即切到另一 App；26 获准时持续，拒绝/旧系统使用有限时间。回前台显示真实成功或原恢复状态 | 系统版本、是否获准、任务类别、切换前后业务状态；不得回传连接地址、凭据、路径或媒体。影响后台可用时间，不承诺永久运行 |
| 同上，测试照片/Office 副本可重复生成 | 传输中锁屏、系统取消或耗尽时间，再解锁返回。文件保护阻止访问时停止并保留副本/未知结果，不重复上传或自动继续后项 | 锁屏/解锁顺序、业务错误、重复请求计数（若可安全取得）；影响锁屏后的可用性与恢复 |
| 两个独立测试 NAS 与两个测试账号；少量合成目录和空文件 | 跨 NAS 复制中断后只读恢复；复制完成后另行确认删源，再中断删源。只处理明确清单，原结果未知时不能重删或以同名目录猜测成功 | 哪个阶段中断、原/目标的计数与摘要是否一致、是否出现重复项；涉及数据完整性，不能用真实文件演练 |
| 合成 Office 文档与受支持的系统编辑器 | 修改副本并主动保存；保存期间改写 NAS 原件或断网，必须阻止冲突覆盖或保持未知，旧/新副本均可保留，恢复只读比对后才更新状态 | 文档类型、编辑器、操作顺序、业务状态及脱敏摘要；涉及覆盖写保护 |
| 同一 App 配置两个测试账号，包含同一配置 UUID 更换账号的场景 | 上传/导出/保存/跨 NAS 进行中切换账号或关闭模块，再回原账号。旧请求停止，旧回调不更新新账号，不因系统授时继续新写 | 切换顺序、两端任务数与状态；涉及账号隔离。强制退出后只恢复已有记录，不宣称系统自动续传 |

上述测试只使用自造数据。真实凭据、NAS 地址、用户目录和媒体不进入测试报告或仓库。

移动 Release 主 App、Share 与 Files 扩展均含 x86_64/arm64，且经符号检查未包含本片 Photos/Office/CrossNAS 及 Files/Share 合成入口。

## 可复现验证命令

- `swift test --package-path apple --parallel`：3103 项 XCTest 与 12 项 Swift Testing 通过。
- `swift test --package-path apple --filter DsmPhotosFeatureTests`：最后共享修改后的 2 项恢复适配测试通过。
- `swift test --package-path apple --filter 'SynologyPhotos(Model|UploadRecovery)Tests'`：最后共享修改后的 260 项 Mac 照片模型/恢复测试通过。
- `xcodebuild build -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath apple/Apps/DsmMac/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`：主程序与扩展双架构通过；未打包、安装或启动 Mac 成品。
- `xcodebuild build -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 2 CODE_SIGNING_ALLOWED=NO`：主 App、Share、Files 三组件双架构通过。
- `python3 tools/localization/check_localization.py`：Apple 7049 键及双语、占位符、引用、硬编码扫描通过。
- `python3 tools/codex/check_documentation.py` 与 `git diff --check`：通过。

移动通过 `xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile`
执行，固定 `-derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO`。
135 项模型回归分别选择 `DsmMobileTests/MobileOfficeTests`、`MobileCrossNASTests`、
`MobileTransferBackgroundExecutionTests`、`MobileTransferStateTests`、`MobileFileUploadQueueTests`、
`MobilePhotoUploadTests`、`MobilePhotoExportTests` 和 `MobileSynologyPhotosTests`；每个类用独立
`-only-testing:DsmMobileTests/<类名>` 参数。iPhone 运行结束后，iPad 使用同一最新产物的
`xcodebuild test-without-building -xctestrun apple/Apps/DsmMobile/build/m0-m8/Build/Products/DsmMobile_iphonesimulator26.5-arm64.xctestrun`。
本机目标分别为 `-destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F'`
与 `-destination 'platform=iOS Simulator,id=A31ABDE2-186F-43DD-8D40-5EB9511A9289'`。

两端 UI 均逐项选择 `-only-testing:DsmMobileUITests/MobileWorkspaceUITests/<方法名>`：

1. `test照片上传离开前台完成后仍能清理本机记录`
2. `test照片导出离开前台后返回系统文件面板`
3. `test跨NAS后台复制后另行确认后台删源`
4. `testOffice覆盖回传离开前台后显示实际保存结果`
5. `test照片后台上传中文深色大字完成状态可读`

同轮另有两项 DDNS 和一项硬盘状态 UI 回归，两端均通过；它们不计入本片五项后台场景，
也不以本机通过宣告旧云端失败已经消失。iPad 本轮只运行指定 UI，没有冒称也运行了 135 项模型测试。

### 最终整合的全部移动单元

在 M8c/M8d 与四类云端交互修正合并的工作区，额外运行两端全部移动单元。首轮发现
两条旧界面源码检查仍要求后台完整停用照片会话、并要求无后台依赖的初始化表达式，
共 3 个断言失败。按 M8 已实现的生命周期更新为后台保留传输、主动离开仍停用及
共享系统执行器接线；原上传/导出行为检查均保留，没有跳过失败场景。

最终 iPhone 1846 项、59.148 秒，iPad 1846 项、57.809 秒，均 0 失败。
每端 4 项既有文件保护检查因模拟器独立系统写入不返回保护属性而跳过，继续真机待办，
不是通过或新增跳过。实际命令如下；iPad 用同一编译产物的 `test-without-building`
及上文 xctestrun 路径，仅替换目标设备与结果路径。

```sh
xcodebuild test -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -parallel-testing-enabled NO -resultBundlePath build/m8-mobile-allunits-final-phone.xcresult -only-testing:DsmMobileTests -disableAutomaticPackageResolution -skipPackageUpdates -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

结果为 `build/m8-mobile-allunits-final-{phone,pad}.xcresult`；所有移动模型和共享 File Provider
测试在该组内。此结果不替代独立的 Files 默认只读系统 UI 失败，也不提升尚未完成的云端门禁。
