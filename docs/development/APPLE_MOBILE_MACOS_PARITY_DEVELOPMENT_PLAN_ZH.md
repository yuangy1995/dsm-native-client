<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-10 -->

# iPhone 与 iPad 业务对齐计划

本页维护 2026-10-04 确认的 M0→M8 当前范围、功能账本与剩余验收。两种设备业务范围一致：iPhone 使用单栏导航和分步表单；iPad 按可用宽度提供分栏、并列详情、键盘和拖放。macOS 是业务与安全语义参考，不照搬悬停、右键、菜单栏和常驻进程。

## 当前交付边界

M0–M7 的批准范围及 M8 普通文件、照片、跨 NAS、Office 后台时间、系统分享和 Files 已接入源码，并有分片自动化、两端实际 UI 和构建证据。**源码范围收口不等于完整云端、真机或真实 NAS 验收完成。**

`5019da83` 的完整云端仍为失败记录；`7f411313` 已修正相关测试查询、选择和清理生命周期。原六项失败按原机型在本机全部通过，用户已要求跳过本次等待完整云端结果，故完整云端验收延期。该来源共享/macOS 分组已通过；本机未复现不证明云端根因消失，也不排除并发、时序或系统读访问占用风险。精确命令、来源和原结果见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。

当前后续工作是处理真实反馈、完成获授权的云端复验和下列设备待办；不再从 M0 重做，也不将已实现功能列为待开发。逐轮施工、历史失败和旧会话交接集中在[实施历史](../archive/2026-h2/APPLE_MOBILE_IMPLEMENTATION_HISTORY.md)。

## 固定基线与授权

- 对齐起点为 macOS 1.0.15（25）`e3bd3480973b325fb76c75783c2f26b682e64f5f`；它是固定语义基线，不是当前最新正式版本。后续增量按功能账本单独核对。
- 保持现有 `main`、主 App 身份、iOS/iPadOS 17、Swift 6、SwiftUI、英语和简体中文、登录配置格式。工程按锁定版本生成；当前工具链见[Apple 构建工作流](../../.github/workflows/apple-build.yml)。
- 移动端尚未发布，使用当前开发数据结构，不为旧开发数据维护迁移或平行兼容实现；保留当前操作的账号隔离、持久恢复和防重复。macOS 已发布格式与实际行为必须独立回归。
- 已确认的移动功能按运行时能力、当前账号与对象权限、具体危险确认、防重复及恢复提供给用户主动测试；不得以 `PENDING_USER_VALIDATION` 标签替代这些检查或虚报已验证。高风险入口仍遵守项目规则及对应功能的明确授权。
- 每片分别操作 iPhone、iPad 模拟器并检查实际页面；静态断言和普通构建不能替代 UI 结果。正式签名、真机和真实 NAS 另列待办。
- 共享增量保持 Mac 调用和数据兼容；新依赖、身份、权限、存储或契约变化遵守 `AGENTS.md`。历史会话的离线自主决策与临时暂停记录只留档，不成为新任务授权。TestFlight 和移动正式发布需另行授权。

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
| M1 旧图库清理 | SynologyPhotosView | 主路由已为 MobileSynologyPhotosView；兼容 | M3h3b 已删除 14 个旧源文件并迁移有效回归，设置仅清理正式照片缓存；开发记录不保留旧格式兼容 |
| M2 浏览、分页及高级搜索 | FileAdvancedSearchView、WorkspaceModel | 触控筛选，iPad 并列详情；List/Search/索引；只读 | M2b 已接多目录/类型/扩展名/大小/日期/所有者/正文条件；搜索沿用共享完整分页，保留正文覆盖不足；两端单元和实际 UI 已通过，证据见 M2b 记录 |
| M2 批量与目录上传 | FileUploadPlan、FileUploadBatch、FileUploadViews | 选择器、多选工具栏、逐项结果；Upload/CreateFolder/复制移动；写 | M2a 已接多选/目录上传及恢复；M2h1 已补文件/文件夹混合复制移动、逐项结果与重启防重放，两端自动化通过；M2h2 已补批量删除/恢复及文件夹支持；M2h3 已接文件夹/多项 ZIP 下载、系统保存/分享与恢复 |
| M2 分享与收集 | FileShareCreationView、FileShareManagementView、FileShareAdvancedView | 详情表单/系统分享；Sharing 密码/日期/权限；外部可见写 | M2d 已接批量创建、全部链接编辑/撤销、访问对象/次数、收集和二维码；两端验证通过，未知写保留隔离限制 |
| M2 压缩、解压、归档浏览 | ArchiveExtractionView；共享 DsmFileFeature/FileArchiveBrowserModel | 包内列表/选择目标与条目；Compress/Extract；数据写 | M2c 已接多项压缩、包内选择/分页及解压、持久记录、取消和输出回读；两端单元/实际 UI 及 Mac 回归通过 |
| M2 ACL 与所有者 | FilePermissionEditor、FileStationPrincipalPicker | 分步权限/成员选择；原对象与权限快照；高风险写 | M2e 已接显式/继承权限、所有者/群组、具体后果确认和持久未知目标限制；两端单元/实际 UI 与 Mac 回归通过 |
| M2 远程位置与 ISO/VFS | FileVFSViews、FileVFSForm、FileISOMountView | 原生列表/连接表单；SMB/NFS/VFS/ISO/云授权；凭据与内部写 | M2f 已接连接管理/原始 URI 浏览下载、ISO 与系统云授权；两端模型及实际 UI、共享与 Mac 回归通过，真实云回调仍待设备验收 |
| M2 收藏与 File Station 设置 | WorkspaceModel.toggleFavorite、FileStationSettingsView、FileStationBandwidthView | 文件菜单/位置列表、分步设置表单；Favorite、Setting、Mount、Bandwidth、SharingDownload；普通写/内部管理写 | M2g1 收藏与 M2g2 常规/账号/限速/分享页面设置已接入并通过两端单元/实际 UI；保留权限、原快照回读与未知防重放，真实 NAS 待用户验证 |
| M2 NAS 任务 | FileBackgroundTaskActions | Activity 绑定 NAS/原任务；状态及取消；写 | M2c 完整分页、原任务停止/清除、未知控制恢复已接；两端单元/实际 UI 通过，真实 NAS 待验 |
| M2 跨 NAS 传输 | WorkspaceModel | 源/目标明确绑定；复制后核对目标再确认源删除；高风险 | M2h4 已接两端独立会话、目录/文件复制、内容比对、活动恢复与独立确认删源；两端单元和实际 UI 通过，目标未核对不得删源，未知及已完成步骤不重放 |
| M2 Office 编辑 | OfficeDocumentPreview、OfficeDocumentEditing | Quick Look→系统编辑/分享→主动回传；数据写 | M2i 已接六种格式预览、系统编辑副本、主动回传及冲突/未知恢复，两端自动化通过；M8c 已接 Files 原位写回与冲突恢复，M8ab 正式适配后的默认只读及编辑系统流程两端通过，完整云端待新源码复验 |
| M2 可恢复活动队列 | WorkspaceModel | 独立版本化任务、来源/目标身份与进度；持久化 | M2a 接独立受保护记录/副本；重启后暂停未提交项，未知上传只查询，下载可从头恢复；M8a/M8d 已接系统执行时间与到期取消，不承诺进程终止后继续 |
| M3 Photos 上传 | SynologyPhotosModel、SynologyPhotosView | Photos/Files 选择与队列；上传/相册加入；写 | M3a 已接系统多选、受保护副本及队列恢复；两端单元/实际 UI 通过，相册加入失败只补后一步，真实 NAS 待验 |
| M3 批量及资料 | PhotoManagementPanel | 多选、标签/日期/资料表单；原件权限；写 | M3c 已接评分/描述/日期/时间偏移与标签创建/添加/移除，M3f1 补齐预览旋转；多选及单张预览、版本 7/10 摘要恢复均经两端单元/实际 UI；原件权限与相册贡献权限分别检查 |
| M3 目录及移动复制 | PhotoFolderDestinationPicker、PhotoManagementPanel | 分步目的地选择、图库内拖放；Folder/Move/Copy；数据写 | M3d 已接目录创建/重命名/排序/封面、混合移动复制/删除及版本 8 恢复；两端单元与实际 UI 通过；M3e 已接共享目录权限、成员/密码/子目录确认和完整任务控制及版本 9 恢复 |
| M3 普通/条件相册与分享 | SynologyPhotosView、PhotoManagementPanel | 相册/条件/分享表单；Album/Sharing；外部可见写 | M3b1 普通相册及 M3b2 访问范围/成员/保护设置已接入并通过两端回归；M3b3 临时分享生命周期、M3b4 照片收集及 M3b5 条件相册也经两端回归；M3b6 冻结相册普通恢复/重建及重启只读也经两端回归，权限保持独立 |
| M3 人物、相似组 | SynologyPhotosModel、PhotoManagementPanel、PhotoFaceEditor | 触控分组列表、人物编辑及人脸画布；People/Concept/Similar；写 | M3g 已接人物/主题管理、手工人脸及版本 14 恢复，两端单元/实际 UI 与 Mac 回归通过；M3h2 已接相似分组/代表照片/移出/拆组/撤销及批量持久恢复，两端回归通过；不推断未识别人脸的身份 |
| M3 预览任务及设置 | SynologyPhotosModel | 任务列表、取消及设置；预览转换/Settings；内部写 | M3e 已接移动复制任务列表/筛选、取消、逐项清除、错误详情与原目标导航，两端自动化通过；M3f1 已接重复文件/显示/个人分类设置、上传默认策略和旋转及版本 10 恢复，两端单元/实际 UI 通过；M3f2 已接手动预览重建/未完成列表及版本 11 恢复，两端回归通过；M3f3 已接自动预览设置/前台生成、图库维护与新格式提示及版本 12 恢复，M3f4 已接共享/全局设置、缓存及成员/两层目录权限和版本 13 恢复，两端回归通过 |
| M3 导出、幻灯片及浏览控制 | PhotoDownloadMenu、PhotoArchiveDownloadMenu、PhotoSlideshowView、PhotoThumbnailSizeControls | 系统多项保存/分享、原件/JPEG/完整集合 ZIP，全屏触控播放与键盘；媒体读取/本机副本 | M3h3a 已接完整目标导出、实际格式与同名保护、部分失败/取消、独立分页播放、日/月和范围选择、缩略图大小；两端单元/系统 UI、共享及 Mac 回归通过，M3h3b 旧图库已清理 |
| M4 搜索、本人编辑、线程 | ChatWorkspaceModel、ChatWorkspaceView | 搜索、消息菜单、线程导航；Post search/update/thread；写 | M4a 已接全局/当前聊天搜索、本人编辑、线程完整分页与回复，未知摘要持久恢复；两端单元/实际 UI、共享及 Mac 回归通过，真实 NAS 待验 |
| M4 投票、提醒、定时 | ChatWorkspaceView、ChatWorkspaceModel | 原生表单；投票对象/props.vote 及提醒定时字段；写 | M4b1 投票与 M4b2 提醒/文字定时创建、管理和持久恢复均通过两端回归；未知不重发，取消须匹配原对象，过发送时间不凭消失推断取消 |
| M4 转发、置顶、会话管理 | ChatWorkspaceModel | 目标会话选择、菜单；Post.search 数字 in 数组；写 | M4b3a 已接公告设置/取消、完整原内容/附件预览及单项/多项关闭和持久恢复；两端单元/实际 UI、共享及 Mac 回归通过；M4b3b 已接批量转发/多接收人与恢复；M4b3c 本人消息单条/批量删除与持久恢复已通过两端回归 |
| M4 发送与建群持久恢复 | ChatWorkspaceModel、DsmChatRepository | 系统选择器、发送记录、原生建群表单与分步恢复；内部写 | M4b4a/b/c 已完成文字/线程/附件与建群持久恢复，返回编号归属、分步保存、只读刷新和主动继续，两端自动化与 Mac 回归通过；真实 NAS/锁屏待验 |
| M4 语音与录制 | ChatNativeMedia | 消息内播放暂停、首次录制申请麦克风；媒体/权限 | M4c 已接播放/暂停、录制/试听/发送与既有发送恢复；两端系统解码、录音中旋转及自适应分栏通过，真实麦克风/来电/蓝牙/锁屏与 NAS 待验 |
| M4 实时与阅读同步 | ChatNotificationService、ChatWindowActivity | App 前台工作区连接、真实可见位置、本地提醒；生命周期 | M4d 已完成前台工作区单一连接、实际可见位置已读、通知设置与本地定时提醒；两端各 1158 项单元及六项最终实际 UI 通过，真实系统/NAS 待验 |
| M5 详情、编辑、批量 | ServiceManagementView、ServiceManagementModel | 多选、详情/编辑表单；Download Station Task；写 | M5a1 完整目录/详情、M5a2 多选暂停/继续与 M5c1 单项/多项保存位置编辑及持久恢复已验证；M5d 已接停止做种及移除恢复 |
| M5 RSS、设置与搜索创建 | ServiceManagementView | RSS/设置/搜索创建表单；现有共享 Download 协议；写 | M5b 下载设置与分步恢复、M5c2 链接/文件与搜索创建的持久记录已验证；M5c2b 统一表单、逐次目录/文件密码及 M5c3 已有 RSS 订阅/条目、更新与创建已通过两端回归 |
| M5 删除与数值 | ServiceManagementModel | 记录删除与文件删除分别确认；数据删除 | M5a1 已统一缺失数值为 --；M5d 单项/多项任务移除与恢复、结束并移出未完成文件均通过两端回归；实际文件由用户进入既有 M2 文件管理另行选择，不自动关联删除 |
| M6 21 页读取与普通设置 | NasAdministrationView、NasAdministrationModel | 分类设置/并列详情；系统日志存储区域代理等；内部写 | M6a1–M6a3 已接五项读取、存储/日志及区域时间/DDNS，M6b2 服务设置及其余 M6 分组见下列行；21 页范围已接入，仅编辑实际支持字段，真实 NAS 行为另验 |
| M6 账号、群组、网络、安全 | NasAdministrationView | 分步表单/当前账号保护；User/Group/Ethernet/FileServ/Security；高风险 | M6b1 账号/群组与 M6b2 文件服务/终端/代理已接并通过两端验收；M6b3 远程访问、M6b4 网卡原配置编辑与断连恢复、M6b5 安全四组保存与原防火墙任务恢复已完成当前环境验收 |
| M6 硬件、UPS、内存、电源计划 | PowerScheduleEntryEditor、NasAdministrationView | 原生编辑器；Hardware/UPS/ZRAM/PowerSchedule；系统写 | M6c1 内存压缩/电源计划与 M6c2 硬件/UPS 已接并完成两端本机验收；六组独立结果、灯光两步回执和主动续接，未知字段不补 false |
| M6 计划任务、连接、电源 | NasAdministrationModel | 后果确认与断连恢复；TaskScheduler/CurrentConnection/System；高风险 | M6d1 计划任务及 M6d2 连接/即时电源已接完整管理与持久恢复。接受不代表脚本完成或已重启，未知不重发 |
| M6 套件中心 | PackageCenterView、PackageInstallationSheet、PackageCenterSettingsView | 安装准备/卷/许可/进度、更新/SPK/设置；Package；内部写 | M6e1 设置/自动更新与来源、M6e3 目录/安装/更新/SPK 和分步恢复已接并完成当前环境验收；M6e2 启停/卸载及持久恢复已接，共享/Mac、两端完整单元及实际 UI 已通过，提交前取消与提交后恢复分别处理 |
| M7 容器生命周期/日志 | ServiceManagementView、ServiceManagementModel | 详情及操作确认；Docker 稳定身份；高风险 | M7a 单项/多项启停重启、逐项恢复、活动正文/用户和现有资源字段已完成两端回归；按明确套件授权开放；M7c2 单项/多项删除和同一记录中的只读恢复已完成两端验收 |
| M7 映像、网络、项目 | ContainerImagePullModel、ServiceManagementView | 搜索/tag/拉取、网络表单与项目状态；Registry.search v1；内部写 | M7b 搜索/标签/下载及跨重启恢复已通过两端单元和实际 UI；读取暂失保留原任务，明确 1202 失败结束。M7c1 单项/多项映像删除与恢复已通过两端回归；M7c3 网络表单/详情/单多删与持久恢复已实现并有两端 UI 证据；项目写及容器创建编辑已补官方静态字段，产品基线/源码缺口仍单独记录 |
| M7 VMM 操作与创建 | ServiceManagementView、ServiceManagementModel | 分步配置/稳定目标；Virtualization；高风险 | M7d1 电源/删除与摘要恢复已完成本机验证；M7d2 基础编辑、摘要恢复、共享全量与两端模型/五项实际 UI 已通过；M7d3 分步创建、原任务/完整配置关联与独立持久恢复已完成共享/Mac/两端模型及六项创建 UI 验收；同名不认领，归属/配置不足保持未知 |
| M7 VMM 网络/映像/控制台 | ServiceManagementView | 资源表单及触控 WebKit；控制台会话；凭据/内部写 | M7d4a 网络详情/改名/单多删与 M7d4b 映像详情/单多删及独立摘要恢复已完成本机验收，保留关联 VM/创建引用互斥、回执与只读恢复；M7d5 已接触控控制台、关闭/手动重连与前后台清理，共用受限原生资源/WSS 及非持久 WebKit，网页不持有会话凭据；两端合成组件/UI 和 Mac 回归通过，真实 noVNC/RFB 另验 |
| M8 系统后台传输 | WorkspaceModel（业务语义） | 系统持续任务、受保护文件及恢复；后台/凭据 | M8a 普通文件与 M8d 照片上传/导出、跨 NAS 复制及独立删源、Office 下载/主动回传已接系统时间；聚焦回归和两端前后台 UI 通过。保留原证书/同源保护、旧系统有限时间和未知写恢复，不承诺进程终止续传；见[普通传输账本](APPLE_MOBILE_SYSTEM_TRANSFERS_ZH.md)与[其他执行器账本](APPLE_MOBILE_BACKGROUND_EXECUTORS_ZH.md) |
| M8 分享扩展 | FileUploadPlan（上传语义） | 分享→NAS/位置→持久任务；独立扩展最小共享权限 | M8b 已实现扩展内选择与上传、最小共享会话撤销、独立持久记录及主 App 接手；两端聚焦单元及实际系统分享 UI 通过，正式签名/真实 NAS 另验，见[专项账本](APPLE_MOBILE_SYSTEM_TRANSFERS_ZH.md) |
| M8 Files 与外部编辑 | DesktopCloudDriveManager；Mac FileProviderExtension | iOS File Provider 先读/下载/缓存，再写回/冲突/删除；系统集成 | M8c 已提取共享运行时并实现移动注册、缓存、原位编辑/冲突恢复及独立删除授权；M8ab 正式非复制式适配后，两端原三项系统流程通过，包含默认只读及编辑回传。新增四项桥接/九项缓存行为、最终两端回归与移动/Mac 双架构构建通过；旧复制式失败保留，新源码完整云端待复验。见[Files 账本](APPLE_MOBILE_FILES_PROVIDER_ZH.md)；正式权限/真机另验 |

## 顺序、所有权与质量门

M6 的逐页范围以 `NasAdministrationModel.NasSettingsPage` 为准：总览与更新检查、存储/空间分析/SMART、外接存储、内存压缩、文件服务、终端、代理、网卡、硬件/UPS、电源计划、远程访问、安全、区域时间、DDNS、套件、计划任务、账号/群组、共享权限摘要、进程、日志、连接。读取不支持和空内容分开；只读基线（例如外接存储/进程）不虚构弹出或终止动作。

M1 隔离依据与修正：`saveProfile` 会在相同 UUID 下替换账号/地址，而 Chat/NAS/Activity 等部分缓存只按 UUID 索引。已补上下文变化后的缓存失效、选择器回调身份及任务账号隔离，两端目标回归已通过；普通重连和改显示名称不应冒充另一个账号。模拟器登录页另已检查空地址提示和语言菜单，已修正切换语言后的旧错误残留、重复应用名及英文账号字段，原生 UI 测试已通过。

M0 补充查证：Download Station 的 `removeData` 是共享接口历史参数名，实际发送 `force_complete`（结束并移出未完成文件），并非删除下载文件；Mac 的 `finish` 控制也不产生请求。M5 必须把移除任务、结束做种和实际文件删除按各自真实结果分开，不把旧名称直接移植。RSS/任务编辑等额外入口先补足明确契约与结果核对，不能把请求缺口包装成可用按钮。M7 的 Mac 项目页目前读取项目状态与错误，未发现项目写方法；移动对齐先保留该实际语义；2026-10-06 已补官方项目静态接口及流式构建定义，尚未实现或行为验证，不再将其笼统表述为完全没有接口线索。

固定顺序 M0→M1→M2→M3→M4→M5→M6→M7→M8。先完成可使用主流程、错误恢复、聚焦自动化，再分别执行两台模拟器测试与构建。M2/M4/M7/M8 可形成候选收口，但不替代后续阶段。当前负责人单独修改 Shell、共享协议、工程、双语资源和进度文档，不与其他任务交叉修改热点。

- 每阶段执行差异检查、文档/契约/本地化门禁、行为测试和独立集成审查。
- 共享变化运行 `swift test --package-path apple`（含 Mac 回归），移动与 Mac 目标项目另构建，互不替代。
- 锁定 XcodeGen 2.46.0 生成工程；iPhone/iPad 独立 `xcodebuild test` 并保留各自结果。
- 页面五态、中英文、浅深色、动态文字、触控、键盘、VoiceOver、降低动效逐项审查；静态扫描仅为结构护栏。
- 私有写、认证、跨 NAS、后台、File Provider 另做只读对抗复核；不自动改现有 NAS 文件、聊天、套件、网络、容器或 VM。

## PENDING_USER_VALIDATION

以下仅为后续设备验收条件，不能据此把未实现行标为完成。

| 条件 | 操作与预期 | 允许回传及影响 |
| --- | --- | --- |
| 真机、专用可丢弃账号/目录 | 两端登录、网络/前后台切换、逐功能操作；不串账号、不重复写，结果与 NAS 一致 | App/OS/DSM/套件版本、脱敏步骤/错误类别；不回传凭据、真实路径或正文 |
| 媒体和辅助功能 | 选择器、麦克风允许/拒绝、播放、动态文字、VoiceOver、iPad 键盘分屏 | 型号/OS、控件和复现步骤；相应系统交互待验，不阻塞独立源码 |
| 正式扩展签名和系统注册 | 分享/Files 注册、锁屏、系统终止、重登、冲突与删除 | 脱敏系统错误和任务状态；高风险系统入口验证前保留能力保护 |

## 明确非目标

不新增 macOS 尚未实现的加密聊天、实时通话、自动照片备份、推送服务器、iPad 多窗口，不模拟桌面常驻进程。远程通知依赖配套 APNs 服务，本轮只实施前台实时及本地提醒。DSM 更新仅检查，实际固件安装不属于当前业务基线。未实现与待设备验证严格分开。

## M6 NAS 与套件逐页账本

本阶段按 `NasAdministrationModel.swift` 的 `NasSettingsPage` 21 项推进。证据前缀为 `apple/Apps/DsmMac/Sources/`；`NasAdministrationView.swift`（下表简称 View）与 `NasAdministrationModel.swift`（Model）共同确定实际能力。接口只复用 `NasSettingsRepository` / `FileStationShareAccessRepository` 和已有端点记录，未发现方法不得猜测。两端业务一致，iPhone 导航栈、iPad 可用宽度分栏，编辑采用触控表单。每页保留独立加载、空内容、筛选空、错误和重试。

| Mac 页 / 证据 | 移动等价结果与交互 | 契约 / 安全 | 当前切片与证据 |
| --- | --- | --- | --- |
| overview / View 仪表板、Model.activate | 总览、性能、更新检查；独立确认电源操作 | System/Utilization/Upgrade；只读及电源高风险 | M6d2 关机/重启独立确认、接受/未知及新会话恢复已接；真实电源行为待验 |
| storage / Model.beginStorageAnalysis、磁盘详情 | 卷/池/磁盘、空间分析、SMART 进度与控制 | Storage/FileStation/SMART；读取及磁盘写 | M6a2 已接详情/分析/SMART 与恢复，两端实际交互通过 |
| externalStorage / View 外接存储 | USB/eSATA 筛选、容量、局部不可用与截断 | dsm-external-storage；只读 | M6a1 读取/两端交互通过；弹出明确非目标 |
| zram / Model.saveZRAM | 已知开关与可选容量；编辑独立确认重启后生效 | dsm-zram；读取/系统写 | M6c1 完整管理与恢复已接，两端实际 UI、共享及 Mac 回归通过 |
| fileServices / Model.saveFileServices | 原字段表单及差量保存 | dsm-file-service-settings；管理写 | M6b2 六组差量保存与逐组恢复已接，两端实际 UI/共享及 Mac 回归通过 |
| terminal / Model.saveTerminal | SSH/Telnet/端口及风险说明 | dsm-terminal-settings；管理写 | M6b2 完整编辑、风险确认与未知恢复已接，两端实际 UI/共享及 Mac 回归通过 |
| network / Model.saveProxy | 代理开关/地址/端口；未知字段不可编辑 | dsm-proxy-settings；网络写 | M6b2 启用/停用与配置编辑恢复已接，两端实际 UI/共享及 Mac 回归通过 |
| interfaces / Model.saveEthernetInterface | 网卡详情/原配置编辑与断连恢复 | dsm-ethernet-settings；高风险网络写 | M6b4 已接列表/搜索、DHCP/静态地址、MTU/VLAN、单目标保存、明确新地址恢复；两端单元/实际 UI、共享/Mac 回归通过，真实网络另验 |
| hardware / Model.saveHardware | 风扇/灯光/蜂鸣/休眠/UPS 原字段编辑 | dsm-hardware-settings；系统写 | M6c2 六组保存、灯光分步回执和明确续接已完成两端本机验收；真实物理行为另验 |
| powerSchedule / View 电源计划编辑器 | NAS 当地时间、筛选、完整清单草稿及整体保存 | dsm-power-schedule；高风险写 | M6c1 完整管理与恢复已接，两端实际 UI、共享及 Mac 回归通过 |
| remoteAccess / Model.saveRemoteAccess | QuickConnect/路由设置及中继断连保护 | dsm-remote-access-settings；网络写 | M6b3 两项管理/当前中继保护/持久恢复已接，两端实际 UI、共享及 Mac 回归通过 |
| security / Model.saveSecurity | 自动封锁/DoS/防火墙原状态及差量 | dsm-security-settings；权限/高风险写 | M6b5 四组保存/部分结果/原任务恢复已接；两端完整单元及六项新 UI、共享/Mac 回归通过，真实安全设置另验 |
| region / Model.saveRegion | 区域格式/时区/时间源/校时 | dsm-region-time-settings；管理写 | M6a3 已接完整表单与分步恢复，两端实际操作及当前环境验收通过 |
| ddns / Model.saveDDNS、testDDNS | 服务商/条目及明确提交；不持久保存口令 | dsm-ddns-settings；凭据/网络写 | M6a3 已接完整管理与恢复，两端实际交互通过 |
| packages / PackageCenterView、PackageInstallationSheet、PackageCenterSettingsView | 列表/目录、卷、许可、SPK、更新、进度、来源和设置 | dsm-package-control/installation；套件写 | M6e1 设置/自动更新与来源、M6e3 目录/安装/更新/SPK 及恢复已完成当前环境验收；M6e2 三动作及持久恢复已接；共享/Mac、两端完整单元与七项新 UI 已通过，最终窄列标题与恢复显示也已复验通过 |
| tasks / Model.saveTask、runTask、loadTaskResults | 草稿、启停/执行/删除、结果与输出 | dsm-task-scheduler；脚本高风险写 | M6d1 完整管理、记录/输出和恢复已接，十项新实际 UI 两端都有通过证据；真实执行待验 |
| accounts / Model.saveAccount、saveGroup | 账号/群组表单与当前账号保护 | dsm-account-directory；权限高风险写 | M6b1 完整管理与恢复已接，两端单元/实际 UI 及共享/Mac 回归通过 |
| shareAccess / View 共享访问 | 当前账号可见共享权限摘要与搜索 | FileStation.List / dsm-share-access；只读 | M6a1 读取/两端交互通过；不冒充完整 ACL 管理 |
| processes / View 系统活动 | 进程/服务组快照、搜索、局部失败与截断 | dsm-system-processes；只读 | M6a1 读取/两端交互通过；终止/信号明确非目标 |
| logs / Model.fetchLogs | 分页、筛选与条目详情 | 已有日志读取契约；只读 | M6a2 已接完整分页/筛选/正文，两端实际交互通过 |
| connections / Model.disconnectConnection | 当前连接保护、明确目标、断开与只读恢复 | dsm-current-connection；高风险写 | M6d2 搜索/详情、独立确认、原目标回读及重启恢复已接，两端实际 UI 有通过证据 |
