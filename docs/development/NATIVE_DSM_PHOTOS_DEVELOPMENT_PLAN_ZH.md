<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-04 -->

# Synology Photos 当前实现与跨端计划

## 当前范围

五端正式照片入口使用 Synology Photos；File Station 的图片扫描/文件备份组件不作为照片库降级。macOS 是当前完整管理语义参考，iPhone/iPad 已授权按移动 M3 完整管理范围实施，当前实现和差距以移动账本为准，Android 与 Windows 只具备各自已接入的范围，不能从共享模型或菜单数量推定全端完成。

2026-10-02 已登记的 macOS Photos 网页对齐开发与本机可执行验证完成。真实 NAS 权限、写入、断网/重启，正式签名沙盒书签恢复与完整辅助功能均为 `PENDING_USER_VALIDATION`；接口证据不因此升级。具体 API、版本、参数和平台限制只维护在[照片 API](../api/reference/photos.md)、[管理端点](../api/discovery/endpoints/photos-management.md)与[环境索引](../api/discovery/environments/INDEX.md)。

## macOS 功能对齐账本

| 功能组 | 覆盖的管理能力 | 当前实现链与行为 |
| --- | --- | --- |
| 照片资料与角色 | metadata、rotation、tags、tagCreation | PhotoManagementPanel、预览更多、canEditPhoto/prepareMutationTarget；评级/说明/绝对与相对日期、标签、旋转及来源身份回读 |
| 普通、条件与冻结相册 | albums、conditionAlbums、frozenAlbums | 相册创建/修改/删除/成员/封面、条件编辑、冻结恢复/重建；原相册身份和新相册结果核对 |
| 目录与传输 | folders、folderDeletion、folderCover、folderSorting、folderSharing、fileTransfer | 独立建目录、重命名/删除、封面、排序/权限、移动/复制/拖放；后台任务与目标结果回读 |
| 上传 | upload | enqueueUploads/startUploadQueue、PhotoUploadQueuePanel、PhotoUploadRecoveryStore、performRecoverableUpload；相册/目录上传、重复策略、取消重试和跨重启恢复 |
| 分享与收集 | sharing、photoRequests | PhotoSelectionSharingPanel、分享表单与请求管理；具名成员、公开范围、密码/有效期、临时分享取消/保留副本及创建/修改/删除照片请求 |
| 人物与主题 | peopleNames、peopleMerge、peopleFaces、peopleCover、peopleVisibility、conceptVisibility、conceptCover、conceptItems、manualFaces | 人物命名/合并/移出/重新分配/封面/显示、手工人脸框、主题封面/移出/显示；固定集合和本人提供者资格 |
| 相似照片 | similarGroups | 相似组详情、推荐照片、移出/解散/撤销及保留选中删除其余；按完整成员快照操作 |
| 预览与转换 | previewRegeneration、automaticPreview、automaticPreviewSettings、codecPrompt | 手动重建、本机预览转换、自动候选/失败状态、设置和新格式提示；PhotoPreviewRecoveryPanel与对应转换/事件回归 |
| 后台与整库维护 | backgroundTasks、libraryMaintenance | PhotoBackgroundTasksPanel、错误详情与目标导航、取消/清理、PhotoLibraryMaintenancePanel；提交与完成分开核对 |
| 共享空间与全局设置 | sharedSpaceSettings、sharedMembers、globalSettings、conversionCache | PhotoSharedSpaceSettingsPanel、PhotoSharedMembersPanel/PhotoMemberFolderPermissionsPanel、PhotoGlobalSettingsPanel；读取/确认/差量提交/回读 |
| 识别、显示、重复与排序 | recognitionSettings、displaySettings、duplicateSettings、albumSorting、albumListSorting、albumListDisplay | 识别/显示/重复策略面板、相册内与列表排序/显示；保存后保留浏览位置与选择 |


读取与非管理流程还包括个人/共享空间、时间线/月定位/完整分页、分类和筛选、按日/范围选择、逐项删除、批量/整册/目录下载、原件/JPEG 导出、照片/视频/实况预览、缩略图大小、幻灯片和预览直接操作。

## 必须保留的业务语义

- 身份绑定 profile、空间、照片/相册/目录及操作身份；仅有列表权限不代表拥有原件、编辑或管理权限，分享贡献者与拥有者需分别判断。
- 分享与相册、人物/相似组、目录权限等集合操作固定完整成员快照；保存前确认基线，不能因成员变化扩大写入范围。
- 相对日期按首次原始快照计算固定绝对目标，恢复时不重复累加；多阶段上传、相册加入、临时分享清理分别保留阶段与结果。
- 删除后只移除已确认项并修正分页，保留历史月份、筛选和选择；读取失败显示恢复入口，不能冒充空照片库。
- 上传恢复保存最小任务元数据与用户授权的文件书签；跨重启先核查旧上传，只继续未开始项或补未完成的加入相册，不盲目重发未知写请求。
- 预览操作只绑定当前照片；自动预览与原件上传分阶段处理，角色不满足时不获取无权原件。
- 用户已明确授权 macOS 新管理能力按实际接口支持和权限开放；确认、防重复、目标核对和结果回查继续生效。开放不是跨版本行为验收，也不授权其他端直接打开新写入口。

## 各端范围与交互转换

| 平台 | 当前范围 | 后续与非目标 |
| --- | --- | --- |
| macOS | 上表管理能力及原生时间线、预览、保存、任务和恢复 | 按真实使用反馈补兼容与系统验收；不承诺 Drive 协作锁、任意视频编码或全部版本行为。 |
| iPhone / iPad | M3a–M3h3a 已接上传恢复、普通/条件/冻结相册、分享/收集、资料/目录/权限、人物/主题/手工人脸、预览任务/设置、原件批量删除、相似分组/撤销、批量/整集合导出与幻灯片浏览；两端单元和实际 UI 分别验证 | 旧图库清理继续 [M3h3b](APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)；两端业务范围相同，真机/NAS 按主计划另验。自动备份仍非本轮目标。 |
| Android | 当前 SynologyPhotos 门面、会话、浏览/筛选/保存及已接入动作；文件照片备份仍独立 | macOS 新管理能力只是后续接口参考；保留 SAF、WorkManager 与权限生命周期，需单独授权实施。 |
| Windows | 既有 SynologyPhotosPage/Workspace 的时间线、筛选、共享读取、预览、保存与个人单项删除 | 2026-09-29 至 10-02 新管理能力尚需逐功能 WinUI 实现，不能记作仅待真机验证。 |

## 验证与后续执行

聚焦自动化使用 `swift test --package-path apple --skip-update --jobs 4 --filter SynologyPhotos`；共享协议变更还需完整 Apple 回归及 iPhone/iPad 模拟器。界面用 `tools/codex/run_macos_ui_checks.sh` 的对应 Photos 正式场景，双语与契约检查沿[API 维护要求](../api/README.md)。历史命令、结果与包见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)，不是本次文档整理重新执行的测试。

| PENDING_USER_VALIDATION 条件 | 操作与预期 | 影响 |
| --- | --- | --- |
| 专用 NAS、可丢弃照片/相册与不同权限账号 | 浏览/分页/保存；上传、相册、分享、元数据、人物、目录、相似组与管理逐项提交和最终回读 | 只验证明确授权目标；不足权限零写入，结果未知只核对。 |
| 可安全中断的上传和多阶段任务 | 上传后断网、关闭、重启，再恢复 | 旧上传不重复；只继续未开始项或补缺少的后续阶段。 |
| 正式签名 App、用户选定本机文件 | 重启后恢复书签、替换/移动/撤销访问 | 无权或来源变化时停止并请求重新选择，不越权扫描。 |
| 支持的真实媒体与输入设备 | 视频/实况、滚动月份、大字号、VoiceOver、键盘焦点 | 编码可播放性和系统辅助功能独立验收，不由合成图片推断。 |

回传环境类别/版本、步骤、实际与预期结果及脱敏错误；不发送照片、路径、凭据或原始响应。未列入移动范围的能力不是移动待真机项。
