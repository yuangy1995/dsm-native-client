# Synology Photos 后台任务中心

## 标识与环境

端点组 `photos-background-tasks`，组件 `synology-photos`，内部混合读写接口，风险 medium。首次静态发现及本次复核日期2026-10-01，来源为已登录官方Photos页面加载的react_bundle.js；[环境快照](../environments/2026-10-01-photos-remaining-observation.md)尚未确认DSM/build/Update及Photos版本，不归入lab-a或任何已验证基线。证据仅static，未列出或修改真实NAS任务。

## 请求契约

统一 `SYNO.Foto.BackgroundTask.Info` v1，POST JSON，路径来自能力发现（候选 `/webapi/entry.cgi`）；沿现有会话认证，凭据不保存于任务快照。不使用FotoTeam替换，即使目标是共享空间。

| 方法 | 参数 | 结果/副作用 |
| --- | --- | --- |
| list_user_task | 无 | 当前用户任务，data.list数组 |
| get_status | id整数数组 | 已知任务状态，data.list；任务可能消失 |
| abort_task | id整数数组 | 停止未处理部分；已完成复制/移动保留；接收回执不代表已经停止 |
| clear_completed_task | 单项id整数标量；网页全部清理无参数 | 清理终态任务记录，不删除照片或文件夹 |
| get_error_detail | id整数标量 | data.list包含type、id、reason |

list字段：id整数；operation字符串copy/move；status字符串waiting/processing/aborting/done；total、completion、error、skip、overwrite整数；create_time时间戳；可选target_folder含id和owner_user_id。owner_user_id=0为共享，等于当前用户为个人；其他值不推断可导航空间。extra_info为JSON字符串，version1包含source_folder_ids，version2增加source_library；客户端当前不靠该字段推断错误照片身份。

completion是已处理数并包含失败；成功数completion-error；done且completion<total表示取消后终态。done且全部失败不能显示成功，aborting仍在途。未知类型/状态保留可读摘要，不开放取消或清理。无效计数、重复编号、缺必需字段明确失败，不静默当成空列表。

错误reason：quota_full账户配额；space_full存储满；skipped目标在来源子目录；not_existed原项目不存在；target_not_existed目标不存在；excluded_extension排除类型。其他值保留为未知原因，不直接给用户显示原始码。type为item/folder，未知type不能借类型猜测原件路由。官方详情通过目标library的Item.get(additional=folder)或Folder.get补姓名/路径；客户端沿官方目标library路由补名称/目录，并按编号匹配，不依赖返回顺序；原件已不存在或无权读取时仍保留错误原因。跨空间错误来源仅有static证据，真实NAS需验证，不推断另一来源空间。

## 权限、确认与结果核对

读取依赖Photos登录用户身份和Info v1能力，允许个人空间关闭但统一Photos入口可用的用户查看任务。任务快照绑定NAS profile UUID、Photos用户ID、任务ID、创建时间、操作、总数和目标；prepare及提交前重新读取当前用户任务列表，身份变化拒绝写入，进度变化允许。所有写操作以原生确认冻结快照。

取消和清理复用既有mutation操作编号去重、拒绝处理与只读回读。取消回读done或记录消失才结束核对；未知回执不重发。清理全部使用确认快照逐项标量请求，不调用无参数范围接口，因此随后完成的新任务不会被清掉。中途失败只核对已尝试项；确认部分成功后剩余记录保留并允许重新选择。

后台控制允许取消本App尚待核对的复制/移动；独立保留控制操作编号，不替换原搬移操作。原搬移done但未全部处理时返回partial；不能提前清理本会话仍待核对的任务记录，以免删除唯一终态证据。旧适配器默认明确不支持新增读取，其他端不会静默执行。

窗口关闭停止刷新而不取消NAS任务。目标跳转沿实际目录权限和父链，重复父节点/账号变化拒绝跳转；不能凭任务目标获得新的文件访问权限。错误或不支持不阻断普通图库。

## 源码、验证与五端影响

- Core：apple/Packages/DsmCore/Sources/SynologyPhotosManagement.swift、SynologyPhotos.swift。
- Adapter/自动化：apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift及Tests/SynologyPhotosRepositoryTests.swift。
- macOS：SynologyPhotosModel.swift、PhotoManagementPanel.swift、SynologyPhotosView.swift及双语资源。
- macOS既有实现通过780项相关XCTest、6项本地化及2项原生UI测试（56张合成截图）；独立Release、严格签名、Sparkle实际加载及DMG校验通过。这些历史结果不代表其他端或真实NAS验收。
- Android A4s接入`SynologyPhotoBackgroundModels`、`SynologyPhotosBackgroundRepository`、现有相册操作存储、`SynologyPhotoBackgroundModel`与`SynologyPhotoBackgroundTasks`。Info v1统一Foto，停止数组、逐项清理标量；创建时间保留小数，确认固定身份但允许进度推进。详情Item v5每批不超过100项，按ID补名称；Folder v2检查实际权限与完整父链。关闭页面/切换记录取消读取，晚到结果不重新显示；已发送控制独立保存，恢复仅检查已尝试且未明确拒绝的项目。
- Android加密记录沿用版本1并追加可选后台控制字段/动作，旧记录继续读取，无数据迁移；旧包不认识新增动作，回退前须保留记录并只读处理未决操作。控制任务与原复制/移动分别恢复，原搬移终态证据未保存时不得清理。2026-10-13110项聚焦JVM回归及Debug/仪器APK通过，最终同包手机中文/平板英文浅色标准字号与深色二倍字号四配置各16项原生流程通过（任务中心8项、原文件操作回归8项）；详见[验证历史](../../../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)与[Android A4s账本](../../../archive/2026-h2/ANDROID_REWRITE_IMPLEMENTATION_HISTORY_ZH.md#a4s-photos-后台任务中心账本)。证据仍仅static，未新增真实NAS兼容结论。
- iPhone/iPad/Windows仅登记影响，本片未修改其源码或运行其构建。Android无新增依赖、权限或工具链；回滚不回滚NAS实际已完成的复制/移动。

PENDING_USER_VALIDATION：在有复制/移动任务的专用验收场景查看waiting/processing/aborting/done、部分失败和取消后的已完成部分；取消确认后逐步停止，关闭窗口不停止任务；清理只消除选定记录，照片保留；同时网页完成的新任务不得误清。断网后重新连接仅核对原操作，重复点击不重复提交；同账号个人/共享空间以及个人空间关闭条件分别测试，目标失权不可跳转。错误详情以实际返回为准。只回传脱敏版本、步骤和提示，不回传地址、任务原文、照片名/路径或凭据。
