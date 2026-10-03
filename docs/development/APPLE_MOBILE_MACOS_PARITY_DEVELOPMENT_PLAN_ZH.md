<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-04 -->

# iPhone 与 iPad 完整业务对齐实施计划

本页是 2026-10-04 用户确认的 M0→M8 唯一实施主线，取代旧“移动精选／只读管理”范围。两种设备业务范围一致：iPhone 使用单栏导航和分步表单；iPad 按可用宽度提供分栏、并列详情、键盘和拖放。macOS 是业务与安全语义参考，不照搬悬停、右键、菜单栏和常驻进程。计划纳入不代表已经实现或验证。

## 固定基线与授权

- macOS 1.0.15（25）正式基线为 `e3bd3480973b325fb76c75783c2f26b682e64f5f`，标签 `macos/v1.0.15`；[正式工作流](https://github.com/yuangy1995/dsm-native-client/actions/runs/37141445406)。正式流程及公开双架构附件/更新源回读已通过，结果记入[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。
- 允许渐进重构、必要共享逻辑提取和 macOS 引用/平台适配调整，保持其用户行为及数据兼容；不扩展无关桌面功能。
- 保持 `main`、现有主 App 身份、iOS/iPadOS 17、SwiftUI、Swift 6、英语与简体中文、登录配置格式。
- 用户授权必要的隔离测试及模拟器操作，禁止影响 NAS 真实数据；官方已登录页面只作必要只读核对。TestFlight 和移动正式发布不在本次发布范围。
- 共享目标不增加第三方依赖；恢复队列独立版本化，不迁移旧配置、不存明文凭据；回滚停用新增入口并保留原配置。M8 的扩展身份、共享权限及存储在实施前列明必要性、影响和回滚。

## 证据与安全门

实现、自动化、目标构建和真机证据分别记录。`PENDING_USER_VALIDATION` 只是有明确步骤的设备待办；静态源码断言、合成网络结果、系统 UI 测试和真实 NAS 行为不能互代。未开发能力不得写成仅待实机。

公开与内部写保留实际权限、稳定目标、明确确认、防重复、未知结果只查询和最终状态核对。未验证且可能导致数据丢失、凭据泄露、越权或不可逆副作用的入口单独受保护，不阻塞无依赖切片。契约只维护在[API 目录](../api/README.md)，变更同步五端影响，不改 Windows/Android 实现。

## 功能对齐账本

Mac 源路径前缀为 `apple/Apps/DsmMac/Sources/`，移动为 `apple/Apps/DsmMobile/Sources/`。共享协议和 Repository 位于 `apple/Packages/DsmCore/Sources/`、`apple/Packages/DsmNetwork/Sources/`。每行验收包含断网、取消、重复点击和跨账号迟到响应；当前差距以源码检查为依据，不使用页面数量作为完成标准。

| 编号／用户结果 | macOS 证据 | 两端交互、契约及安全级别 | 当前差距与验收 |
| --- | --- | --- | --- |
| M0 基线与范围 | 发布标签；WorkspaceView、ServiceManagementView、NasAdministrationView | 路由→模型→Repository，校正文档/矩阵；只读 | 已完成基线与差距核对，正式发布及两端基线均通过 |
| M1 会话与导航 | LoginViewModel、WorkspaceModel | 现有 AppShell/Session；单栏/分栏；认证 | 下载已拆为独立模型，配置账号/地址进入隔离身份；两端与迟到回调回归通过，详见验证历史 |
| M1 共用照片状态 | SynologyPhotosModel、PhotoUploadRecoveryStore | 内部 DsmPhotosFeature；平台文件访问/恢复/导出适配；共享 | 已迁入 `DsmPhotosFeature`，Mac 书签适配及旧队列版本保持；两端和 Mac 回归通过，详见验证历史 |
| M1 旧图库清理 | SynologyPhotosView | 主路由已为 MobileSynologyPhotosView；兼容 | 迁移有效行为后删除旧 File Station 图库路径，保留缓存清理 |
| M2 浏览、分页及高级搜索 | FileAdvancedSearchView、WorkspaceModel | 触控筛选，iPad 并列详情；List/Search/索引；只读 | M2b 已接多目录/类型/扩展名/大小/日期/所有者/正文条件；搜索沿用共享完整分页，保留正文覆盖不足；两端单元和实际 UI 已通过，证据见 M2b 记录 |
| M2 批量与目录上传 | FileUploadPlan、FileUploadBatch、FileUploadViews | 选择器、多选工具栏、逐项结果；Upload/CreateFolder/复制移动；写 | M2a 已接共用上传计划、多选/目录、同名跳过/替换确认、逐项结果与暂停恢复；两端验证记录见后文，其他文件管理仍在实施 |
| M2 分享与收集 | FileShareCreationView、FileShareManagementView、FileShareAdvancedView | 详情表单/系统分享；Sharing 密码/日期/权限；外部可见写 | M2d 已接批量创建、全部链接编辑/撤销、访问对象/次数、收集和二维码；两端验证通过，未知写保留隔离限制 |
| M2 压缩、解压、归档浏览 | ArchiveExtractionView；共享 DsmFileFeature/FileArchiveBrowserModel | 包内列表/选择目标与条目；Compress/Extract；数据写 | M2c 已接多项压缩、包内选择/分页及解压、持久记录、取消和输出回读；两端单元/实际 UI 及 Mac 回归通过 |
| M2 ACL 与所有者 | FilePermissionEditor、FileStationPrincipalPicker | 分步权限/成员选择；原对象与权限快照；高风险写 | M2e 已接显式/继承权限、所有者/群组、具体后果确认和持久未知目标限制；两端单元/实际 UI 与 Mac 回归通过 |
| M2 远程位置与 ISO/VFS | FileVFSViews、FileVFSForm、FileISOMountView | 原生列表/连接表单；SMB/NFS/VFS/ISO/云授权；凭据与内部写 | M2f 已接连接管理/原始 URI 浏览下载、ISO 与系统云授权；两端模型及实际 UI、共享与 Mac 回归通过，真实云回调仍待设备验收 |
| M2 收藏与 File Station 设置 | WorkspaceModel.toggleFavorite、FileStationSettingsView、FileStationBandwidthView | 文件菜单/位置列表、分步设置表单；Favorite、Setting、Mount、Bandwidth、SharingDownload；普通写/内部管理写 | M2g1 收藏与 M2g2 常规/账号/限速/分享页面设置已接入并通过两端单元/实际 UI；保留权限、原快照回读与未知防重放，真实 NAS 待用户验证 |
| M2 NAS 任务 | FileBackgroundTaskActions | Activity 绑定 NAS/原任务；状态及取消；写 | M2c 完整分页、原任务停止/清除、未知控制恢复已接；两端单元/实际 UI 通过，真实 NAS 待验 |
| M2 跨 NAS 传输 | WorkspaceModel | 源/目标明确绑定；复制后核对目标再确认源删除；高风险 | 未实现；目标未核对不得删源，恢复不重放已完成步骤 |
| M2 Office 编辑 | OfficeDocumentPreview、OfficeDocumentEditing | Quick Look→系统编辑/分享→主动回传；数据写 | 有预览/导出，缺冲突与主动回传；M8 接 Files 写回 |
| M2 可恢复活动队列 | WorkspaceModel | 独立版本化任务、来源/目标身份与进度；持久化 | M2a 接独立受保护记录/副本；重启后暂停未提交项，未知上传只查询，下载可从头恢复；后台执行仍属 M8 |
| M3 Photos 上传 | SynologyPhotosModel、SynologyPhotosView | Photos/Files 选择与队列；上传/相册加入；写 | 缺入口；加入相册失败只补后一步，不重传原件 |
| M3 批量及资料 | PhotoManagementPanel | 多选、标签/日期/资料表单；原件权限；写 | 缺编辑/批量；列表可见不代表可改/删 |
| M3 目录及移动复制 | PhotoFolderDestinationPicker | 分步目的地选择；Folder/Move/Copy；数据写 | 缺管理；绑定对象、空间与角色，保留部分成功 |
| M3 普通/条件相册与分享 | SynologyPhotosView、PhotoManagementPanel | 相册/条件/分享表单；Album/Sharing；外部可见写 | 当前主要浏览；照片、相册、目录、分享权限独立 |
| M3 人物、相似组 | SynologyPhotosModel | 触控分组列表、人物编辑；People/Similar；写 | 缺管理流程；不推断服务端未识别的人物 |
| M3 预览任务及设置 | SynologyPhotosModel | 任务列表、取消及设置；预览转换/Settings；内部写 | 缺流程；支持不足只限制相关入口 |
| M4 搜索、本人编辑、线程 | ChatWorkspaceModel、ChatWorkspaceView | 搜索、消息菜单、线程导航；Post search/update/thread；写 | 包装器未转发新增能力；本人/会话绑定，历史完整分页 |
| M4 投票、提醒、定时 | ChatDetailsViews | 原生表单；投票对象/props.vote 及提醒定时字段；写 | 缺完整接入；未知不重发，撤销核对原对象 |
| M4 转发、置顶、会话管理 | ChatWorkspaceModel | 目标会话选择、菜单；Post.search 数字 in 数组；写 | 有部分低风险操作；包装器截断/字段投影需复核 |
| M4 语音与录制 | ChatNativeMedia | 消息内播放暂停、首次录制申请麦克风；媒体/权限 | 缺录音；一击加载播放、取消清理临时文件 |
| M4 实时与阅读同步 | ChatNotificationService、ChatWindowActivity | App 前台工作区连接、真实可见位置、本地提醒；生命周期 | 当前只在 Chat 页激活；本人无残留未读，旧历史不提前读新消息 |
| M5 详情、编辑、批量 | ServiceManagementView、ServiceManagementModel | 多选、详情/编辑表单；Download Station Task；写 | 有创建/暂停继续/记录删除，缺全详情、编辑、批量及完成做种 |
| M5 RSS、设置与搜索创建 | ServiceManagementView | RSS/设置/搜索创建表单；现有共享 Download 协议；写 | 有 BT 搜索基础，缺完整设置/RSS；离页保留长任务身份 |
| M5 删除与数值 | ServiceManagementModel | 记录删除与文件删除分别确认；数据删除 | 缺数据删除逐项结果；未知速度/剩余时间显示 --，读取失败不算成功 |
| M6 21 页读取与普通设置 | NasAdministrationView、NasAdministrationModel | 分类设置/并列详情；系统日志存储区域代理等；内部写 | 当前仅摘要及部分详情；仅编辑实际支持字段 |
| M6 账号、群组、网络、安全 | NasAdministrationView | 分步表单/当前账号保护；User/Group/Ethernet/FileServ/Security；高风险 | 缺操作；管理员/原快照/差量/防重复/回读 |
| M6 硬件、UPS、内存、电源计划 | PowerScheduleEntryEditor、NasAdministrationView | 原生编辑器；Hardware/UPS/ZRAM/PowerSchedule；系统写 | 未实现；纠正 API 旧只读说明，未知字段不补 false |
| M6 计划任务、连接、电源 | NasAdministrationModel | 后果确认与断连恢复；TaskScheduler/CurrentConnection/System；高风险 | 缺操作；接受不代表脚本完成或已重启，未知不重发 |
| M6 套件中心 | PackageCenterView、PackageInstallationSheet、PackageCenterSettingsView | 安装准备/卷/许可/进度、更新/SPK/设置；Package；内部写 | 只有只读列表；提交前取消丢弃迟到结果，提交后关闭不撤销任务 |
| M7 容器生命周期/日志 | ServiceManagementView、ServiceManagementModel | 详情及操作确认；Docker 稳定身份；高风险 | 只有只读投影；套件权限不等同 DSM 管理员，写后回读 |
| M7 映像、网络、项目 | ContainerImagePullModel、ServiceManagementView | 搜索/tag/拉取、网络/项目表单；Registry.search v1；内部写 | 缺入口；读取暂失保留任务，明确 1202 失败不再卡住 |
| M7 VMM 操作与创建 | ServiceManagementView、ServiceManagementModel | 分步配置/稳定目标；Virtualization；高风险 | 只有只读包装器；先修正同名即成功不足，创建归属和配置不足保持未知 |
| M7 VMM 网络/映像/控制台 | ServiceManagementView | 资源表单及触控 WebKit；控制台会话；凭据/内部写 | 缺入口；临时隔离 Cookie、限定源站，URL 禁止原始会话秘密 |
| M8 系统后台传输 | WorkspaceModel（业务语义） | Background URLSession、受保护文件及恢复；后台/凭据 | 未实现；自动重定向不能弱化证书/源站约束，不适用路线维持前台恢复 |
| M8 分享扩展 | FileUploadPlan（上传语义） | 分享→NAS/位置→持久任务；独立扩展最小共享权限 | 未实现；账号隔离、取消、重复接收及系统终止恢复 |
| M8 Files 与外部编辑 | DesktopCloudDriveManager；Mac FileProviderExtension | iOS File Provider 先读/下载/缓存，再写回/冲突/删除；系统集成 | 未实现；不复制 Mac 外壳；正式 entitlement 与真机另验 |

## 顺序、所有权与质量门

M6 的逐页范围以 `NasAdministrationModel.NasSettingsPage` 为准：总览与更新检查、存储/空间分析/SMART、外接存储、内存压缩、文件服务、终端、代理、网卡、硬件/UPS、电源计划、远程访问、安全、区域时间、DDNS、套件、计划任务、账号/群组、共享权限摘要、进程、日志、连接。读取不支持和空内容分开；只读基线（例如外接存储/进程）不虚构弹出或终止动作。

M1 隔离依据与修正：`saveProfile` 会在相同 UUID 下替换账号/地址，而 Chat/NAS/Activity 等部分缓存只按 UUID 索引。已补上下文变化后的缓存失效、选择器回调身份及任务账号隔离，两端目标回归已通过；普通重连和改显示名称不应冒充另一个账号。模拟器登录页另已检查空地址提示和语言菜单，已修正切换语言后的旧错误残留、重复应用名及英文账号字段，原生 UI 测试已通过。

M0 补充查证：Download Station 的 `removeData` 是共享接口历史参数名，实际发送 `force_complete`（结束并移出未完成文件），并非删除下载文件；Mac 的 `finish` 控制也不产生请求。M5 必须把移除任务、结束做种和实际文件删除按各自真实结果分开，不把旧名称直接移植。RSS/任务编辑等额外入口先补足明确契约与结果核对，不能把请求缺口包装成可用按钮。M7 的 Mac 项目页目前读取项目状态与错误，未发现项目写方法；移动对齐先保留该实际语义，不虚构项目创建/部署接口。

固定顺序 M0→M1→M2→M3→M4→M5→M6→M7→M8。先完成可使用主流程、错误恢复、聚焦自动化，再分别执行两台模拟器测试与构建。M2/M4/M7/M8 可形成候选收口，但不替代后续阶段。当前负责人单独修改 Shell、共享协议、工程、双语资源和进度文档，不与其他任务交叉修改热点。

- 每阶段执行差异检查、文档/契约/本地化门禁、行为测试和独立集成审查。
- 共享变化运行 `swift test --package-path apple`（含 Mac 回归），移动与 Mac 目标项目另构建，互不替代。
- 锁定 XcodeGen 2.46.0 生成工程；iPhone/iPad 独立 `xcodebuild test` 并保留各自结果。
- 页面五态、中英文、浅深色、动态文字、触控、键盘、VoiceOver、降低动效逐项审查；静态扫描仅为结构护栏。
- 私有写、认证、跨 NAS、后台、File Provider 另做只读对抗复核；不自动改现有 NAS 文件、聊天、套件、网络、容器或 VM。

## 当前验证记录

- 2026-10-04：专用 iPhone 17 Pro、iPad Air 11 模拟器（iOS 26.5）均已创建、启动并检查主屏幕；未擦除用户旧模拟器。基线 `build-for-testing` 通过，随后 iPhone 与 iPad 分别 `test-without-building`，均通过，精确数量见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m0-基线)；另分别启动 App 并原生检查登录页。未登录或写入真实 NAS。
- 实际命令：`xcodebuild build-for-testing -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=8145D5B0-65A7-46E3-A0CF-17850E4EFA3F' -derivedDataPath apple/Apps/DsmMobile/build/m0-m8 -jobs 4 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`；随后两端分别运行 `test-without-building`，iPad ID 为 `A31ABDE2-186F-43DD-8D40-5EB9511A9289`，关闭测试并行。结果分别为 `build/m0-m8-baseline-iphone.xcresult`、`build/m0-m8-baseline-ipad.xcresult`（忽略的本地构建目录）。
- `python3 tools/codex/check_documentation.py` 与 `git diff --check` 通过。
- `MobileChatPresentationTests` 包含源码文本断言；更新过时范围限制时保留安全语义并补实际行为/界面测试。
- M0 已核对照片主路由、组合根下载状态、进程内任务队列、Chat/NAS/Container/VMM 包装器以及 Mac 管理入口。M1 共享提取、下载模型、身份隔离与原生导航回归已通过；旧图库清理随 M3 完成，M2–M8 新范围尚未实现。

## PENDING_USER_VALIDATION

以下仅为后续设备验收条件，不能据此把未实现行标为完成。

| 条件 | 操作与预期 | 允许回传及影响 |
| --- | --- | --- |
| 真机、专用可丢弃账号/目录 | 两端登录、网络/前后台切换、逐功能操作；不串账号、不重复写，结果与 NAS 一致 | App/OS/DSM/套件版本、脱敏步骤/错误类别；不回传凭据、真实路径或正文 |
| 媒体和辅助功能 | 选择器、麦克风允许/拒绝、播放、动态文字、VoiceOver、iPad 键盘分屏 | 型号/OS、控件和复现步骤；相应系统交互待验，不阻塞独立源码 |
| 正式扩展签名和系统注册 | 分享/Files 注册、锁屏、系统终止、重登、冲突与删除 | 脱敏系统错误和任务状态；高风险系统入口验证前保留能力保护 |

## 明确非目标

不新增 macOS 尚未实现的加密聊天、实时通话、自动照片备份、推送服务器、iPad 多窗口，不模拟桌面常驻进程。远程通知依赖配套 APNs 服务，本轮只实施前台实时及本地提醒。DSM 更新仅检查，实际固件安装不属于当前业务基线。未实现与待设备验证严格分开。


## M1 实施边界与迁移说明

当前单一修改范围为移动 Shell/会话/下载模型、相关文件选择与活动身份、Photos 共用逻辑、双语资源、工程和测试。Mac 仅调整照片模块引用与文件授权适配。`DsmPhotosFeature` 是内部 Swift 模块，未增加第三方依赖或改变 NAS 请求；Windows/Android 只记录该无协议变化的影响。

照片恢复继续使用原 JSON 版本与字段；Mac 使用原安全范围书签，iOS 使用独立选择器书签适配。新的移动恢复队列及后台能力仍在 M2/M8，不能由公共模型出现推定已完成。回滚可恢复原模块引用，现有照片队列仍可读取，主 App 身份、登录偏好和凭据格式不变。

旧 File Station 图库已无正式导航入口，其缓存兼容清理暂保留；相关行为/测试迁移和删除在 M3 完整上传/浏览流程接入后统一收敛，仍是本次 M1–M3 的未完成工作，不计作仅待设备验证。


M1 凭据边界补充：修改已有连接的地址、端口或账号时，表单清空旧密码并为新连接生成独立配置身份，原配置及其安全存储保持可用；只改显示名称保持身份。迟到密码读取必须仍匹配原输入目标且不得覆盖手动输入。此变化不迁移配置/凭据格式；用户可直接选回旧连接，不向新地址试用旧会话。


M1 验证结果与只读对抗复核见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m1-共享结构会话与导航)。基础结构门已通过，下一切片为 M2 文件、传输及活动中心；旧图库清理和设备待验仍按上文分别追踪。

## M2 当前切片与存储边界

本切片先落实可恢复传输、多文件与目录上传，再接高级搜索、归档、分享管理和高级文件操作。沿用现有 FileRepository、文件批量操作模型和活动协调器；不另建平行文件服务。单一修改范围为移动 Files/Activity/Documents、必要的共享文件逻辑、双语资源、工程和相关测试。

恢复记录使用独立版本 1，位于应用支持目录；与登录配置分离，只保存任务身份、账号上下文摘要、来源/目标路径及阶段，不保存凭据。受控文件与记录使用系统文件保护并排除备份。开始实际写请求前先落盘；保存失败则不提交。进程中断后，未提交项由用户继续，已经提交的上传只查询结果，不自动重传；下载可从头恢复。未知版本或损坏记录保留原件并提示恢复失败，不以空记录覆盖。回滚停用新增队列，旧账号配置不变；该新增存储在 M0–M8 批准范围内，不迁移既有格式。

Mac 参考为 `FileUploadPlan.swift`、`FileUploadBatch.swift`、`WorkspaceModel.swift`；目录层次、同名冲突、部分成功、取消及未知结果按其业务语义实现。iPhone/iPad 均通过系统文件选择器及原生活动列表操作，不引入桌面常驻运行假设。当前尚在实现，不能据此提升验证等级。


M2a 的恢复队列、多文件/目录上传、独立两端 UI 和 Mac 回归已通过，详见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2a-可恢复传输与目录上传)。高级搜索、归档和 NAS 任务已由 M2b/M2c 补齐；M2d 已补分享/收集；M2e 已补 ACL/所有者；M2 仍须完成跨 NAS、目录批量管理与 Office 主动回传，不能以本切片替代整波验收。


### M2b 高级搜索与目录选择

当前单一修改范围为移动 Files、只读目录选择器、共享搜索值类型及相关语言资源/工程/测试；不改变 NAS API 或登录存储。高级搜索对齐 `FileAdvancedSearchView` 的多目录、名称/正文、类型、扩展名、大小、日期和所有者条件；iPhone/iPad 均用原生表单及逐层目录选择，不用手输路径代替选择。缓存绑定完整条件，正文覆盖不足明确提示。目录选择复用浏览模型的分页与请求隔离；iPhone 工具栏保留筛选，将其余操作收进“更多”，iPad 额外直接显示上传与新建文件夹。文件变更使相关多目录搜索缓存失效；共享根禁止上传。归档和分享仍是下一切片，不能由搜索完成推定完成。验证见[历史记录](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2b-高级搜索与目录选择)。

### M2c 归档与 NAS 任务

本切片单一修改范围为 Files 归档表单/任务记录、Activity 的 NAS 分页与控制、组合根、双语资源及工程/测试。`FileArchiveBrowserModel` 迁入现有 `DsmFileFeature`，Mac 仅调整引用与原编码评分入口，保持请求和行为。依据 `ArchiveExtractionView`、`WorkspaceModel.enqueueCompression/enqueueExtraction` 和 `FileBackgroundTaskActions`，两端均提供压缩格式/级别/密码、包内分页与选择、目录选择和任务状态；iPhone 分步表单、iPad 自适应表单，不迁移桌面窗口行为。

归档记录使用独立版本 1 的受保护文件，只存账号上下文、输出清单、操作阶段和完成回执，不保存密码或请求凭据，不迁移既有配置。提交前保存，重启或断连后只读取，不自动重发；同一未结束输出禁止再次提交。回滚可停用新入口并保留记录。沿用现有公开 Compress/Extract/BackgroundTask 契约；Windows/Android 无请求变化。覆盖和取消须说明具体后果，最终输出与快照核对，NAS 原任务身份和账号不得替换；真实 NAS 写入未验证，仍按设备待办执行。共享回归、Mac 双架构工程构建及 iPhone/iPad 全部单元与实际 UI 测试均通过；详见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2c-归档与-nas-任务)。


### M2d 分享与文件收集

当前单一修改范围为移动 Files/Sharing、成员选择器、组合根、双语资源和测试/工程。基准为 `FileShareCreationView`、`FileShareManagementView`、`FileShareAdvancedView` 及共享 `DsmFileRepository` 的分享结果方法；两端提供批量创建与逐项结果、全部链接筛选和选择、日期/密码编辑、访问对象与次数、收集信息、二维码和系统分享。iPhone/iPad 均采用触控列表与原生表单，二维码在本机生成；不迁移桌面窗口。

沿用现有公开 Sharing 和已记录的内部高级分享/账号契约。外部可见写必须绑定完整原对象，保留实际权限、扩大访问/移除密码/收集上传的具体后果确认、未知结果防重放与回读；不以截断列表中的缺失推定撤销成功。独立版本 1 恢复记录仅存上下文及未完成操作身份、不保存密码；提交前保存，重启后只读恢复，回滚停用新入口而保留记录，既有登录格式不变。此项存储属已批准 M0–M8 恢复范围。M2d 两端单元/实际 UI、共享及 Mac 构建回归已通过，详见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2d-分享与文件收集)。真实 NAS 不参与自动写测试，Windows/Android 无请求变化，ACL/远程连接/跨 NAS/Office 在后续 M2 切片。


### M2e 所有者与权限

当前单一修改范围为移动权限模型/原生表单、现有成员选择器、Files 入口、组合根、双语资源及对应测试/工程；不改变共享 API 请求或 Mac 行为。参考 `FilePermissionEditor.swift`、`DsmFileRepository+Permissions.swift` 和已记录的内部权限端点。两端均展示所有者、显式/继承规则与基础权限；继承项只读，普通目录以原生展开表单编辑，保存前展示变更对象和具体后果。共享根、回收站、挂载位置和实际授权不足保持只读。

高风险写继续由现有 Repository 执行完整路径映射/权限快照重读、成员存在性、自锁检查及最终状态回读。移动端仅增加独立版本 1 的受保护未结束目标记录，内部映射路径、权限快照和凭据不落盘；写前保存失败零提交，未知请求禁止重放。同一会话保留原请求用于只读查询；重启后保留未知目标限制与当前权限读取，不凭根项目相同断言整棵目录完成。回滚停用新增入口并保留记录，原配置不变。模型/表单、具体后果确认和恢复记录已接入；权限变化使当前账号旧目录与搜索权限缓存失效。两端各 586 项单元及全部 17 项实际 UI 均已有通过证据，共享和 Mac 回归通过；精确命令、iPad 中间失败与补测见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2e-所有者与权限)。真实权限写仅列后续用户验证，不访问 NAS 真实数据。

### M2f 远程位置、ISO 与云连接

当前单一修改范围为移动远程位置管理/浏览/表单、Files/Locations 入口、组合根、独立恢复记录、双语资源、工程与测试；共享 `DsmFileFeature` 仅提取原 `FileVFSForm` 和 `FileVFSCloudAuthorizationSession`，Mac 同步引用及回归，不改既有网络请求。证据为 Mac `RemoteMountEditorView`、`FileVFSViews`、`FileVFSBrowserView`、`FileISOMountView`，共享 `RemoteMountOperation`、`DsmFileRepository+VFS/+ISO` 以及[远程挂载](../api/discovery/endpoints/file-station-remote-mount.md)/[云连接](../api/discovery/endpoints/file-station-vfs-connections.md)契约。

两端均以位置列表、触控表单和系统目录选择完成创建/编辑/连接/断开、ISO 加载/卸载及远程目录分页/下载；iPhone 单栏推进，iPad 自适应表单。SMB 编辑保留先连接新位置、再断开旧位置的既有顺序，同位置修改保留断开后继续阶段；未知结果只读查询，继续或放弃只作用于原任务。ISO 目标必须为空目录；VFS 保留完整原始 URI 和连接快照，不能转换成本地路径。普通连接由明确按钮确认；断开、移除已保存连接与明文传输显示具体后果。

新增独立版本 1 恢复记录只存账号上下文、操作/目标身份，不存密码、云令牌或完整授权回调；提交前落盘，失败则零提交，损坏保留，重启后的未知请求不自动重放。原配置/身份/权限不迁移，回滚停用新入口并保留恢复记录。云授权复用一次性 IPv4 loopback 回调与字段白名单；移动以系统 Safari 浏览界面在 App 内全屏呈现，避免外部浏览器使监听随 App 挂起。Safari 覆盖原表单不视为取消，只有明确关闭、账号切换或宿主被移除才清理授权；关闭后的迟到准备结果不可重新呈现。按 [Apple 文档](https://developer.apple.com/documentation/SafariServices/SFSafariViewController)使用模态呈现，不读取登录表单或浏览器 Cookie。监听取消即关闭，账号/请求/协议不匹配拒绝；实际云服务跳转和真机前后台行为留作用户验证。

本切片已完成凭据、身份/原请求绑定、提交前保存、未知防重放、晚到回调及共享单一实现的独立集成与只读对抗复核。两端各 606 项单元通过，5 项新增实际 UI 及 3 项原有导航/文件回归均有两端通过证据；共享 2427 项 XCTest（172 项既有跳过）及 12 项 Swift Testing、Mac Release 双架构构建通过，精确命令和中间修复见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2f-远程位置与云连接)。共享请求/版本不变，Windows/Android 只记录无契约变化；收藏维护与 File Station 设置由 M2g 完成；跨 NAS、批量目录管理和 Office 主动回传仍按后续切片处理。

### M2g 收藏维护与 File Station 设置

本切片单一修改范围为移动收藏/设置模型、原生表单、Files/Locations 入口、组合根、独立恢复记录、双语资源、工程及相关测试；共享 Repository 复用现有能力，新增兼容的移除收藏结果方法并修正截断回读，不改变 NAS 请求、字段或版本；旧方法保持，Mac 执行共享回归，Windows/Android 只记录影响。收藏对齐 `WorkspaceModel.toggleFavorite` 的文件/文件夹收藏和移除；位置列表中目录继续导航，文件通过现有预览打开。设置对齐 `FileStationSettingsView`、`FileStationBandwidthView` 的常规选项、挂载使用范围/账号、全局和逐账号带宽/时间表、分享页面主题。iPhone/iPad 功能一致，采用触控分步表单和原生成员/文件选择，不复制桌面窗口。

收藏完整读取至共享层现有 5000 项上限，截断时不得以缺失推断移除成功或安全新增。设置写保留管理员与 File Station 实际权限、原快照重读及提交后回读；放宽访问与主题图片上传分别说明具体后果。两类未完成操作分别用独立版本 1 受保护记录保存账号上下文与目标身份，设置快照/图片及凭据不落盘；保存失败零提交，重启不重放原写。该存储属已授权 M0–M8 恢复范围，不迁移登录结构；回滚停用入口并保留记录。收藏与设置均已完成当前环境可执行的自动化和构建；真实 NAS 行为未验证，完成证据见后文。真实 NAS 不参与自动写测试，Windows/Android 无请求变化。


M2g1 收藏维护已完成 8 项新增模型、两端各 614 项单元及 2 项新增/3 项原有实际 UI；共享完整回归和构建记录集中于[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2g1-收藏维护)。M2g2 File Station 设置的实现及验证在下段单独记录。


### M2g2 File Station 设置

单一修改范围为移动 Files/Settings、文件页入口、组合根/账号清理、双语资源、Debug 合成响应、工程与测试。Mac App、共享网络请求、版本字段和既有登录配置保持不变。对齐现有常规设置、分享/收集具名账号、远程挂载访问范围及本机/域/LDAP 名单、六类账号限速和每周时间表、分享页布局/颜色/页脚及 NAS/历史/本机/内置图片来源。各类设置独立保存；iPhone/iPad 都采用原生表单、名单分页和按星期/小时触控编辑，不复制桌面 168 格密集表格。未配置的账号限速保留群组继承/未配置语义，禁止当作不限速回写。

保存沿用共享 Repository 的管理员、实际 File Station 权限、原快照重读、具名账号存在性与提交后回读。普通保存由按钮确认，扩大分享/收集/账号可见范围、远程连接或 ISO 权限时分别说明具体后果；取消不提交。成功后回读并更新表单基线，保留滚动位置以显示结果。恢复记录位于受保护且排除备份的独立 `FileSettings/settings-v1.json`，只存配置 ID、账号上下文摘要、操作 ID 和目标摘要，不存账号名单、设置快照、路径、页脚、图片或凭据。保存失败零请求；未知仅查询原请求，同会话可结束，重启/重连缺少原回执时继续限制该目标，其他设置仍可使用。图片上传失败保守保留图片摘要，用户可读取历史并选取已有图片，不自动重传。新记录属于已批准恢复范围，不迁移旧配置；回滚停用新入口并保留记录。

已完成独立集成及只读对抗复核，覆盖旧账号草稿延后执行、迟到读取/写入、Repository 更换、重复点击、损坏/无法保存记录、未知结果、目录来源绑定、图片摘要隔离及共享校验复用。13 项新增单元在 iPhone/iPad 各 627 项全部单元中通过；完整共享回归和 Mac 构建已通过。两端各 6 项新增及 3 项原有实际 UI 均已有通过记录，精确命令、首轮失败及修复和结果包见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2g2-file-station-设置)。

`PENDING_USER_VALIDATION`：两种真机和专用可丢弃管理员/普通账号，逐类保存并从 DSM 读取结果；检查账号名单分页、域/LDAP 及管理员不可修改项、NAS 时区与限速继承、四种图片来源及最终分享页、另一管理员同时修改、提交/回读断网、重连和重启。预期不覆盖新快照、不重复提交、不误报换图成功，未知上传可从历史选择；实际权限、速度/时间表、生效页面和系统文件选择尚未验证。VoiceOver、大字号、外接键盘继续在真机验收，只回传 App/OS/DSM/套件版本、脱敏步骤和错误类别。未访问真实 NAS 或执行真实设置写入；下一切片为批量/目录管理、跨 NAS 与主动文档回传。
