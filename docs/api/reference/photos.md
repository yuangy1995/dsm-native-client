# Synology Photos

分类：本项目使用的 `SYNO.Foto.*` / `SYNO.FotoTeam.*` 为内部接口。主实现：[SynologyPhotosRepository](../../../apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift)；领域：[SynologyPhotos](../../../apple/Packages/DsmCore/Sources/SynologyPhotos.swift)、[管理模型](../../../apple/Packages/DsmCore/Sources/SynologyPhotosManagement.swift)、[上传恢复模型](../../../apple/Packages/DsmCore/Sources/SynologyPhotosUploadRecovery.swift)。

## 命名空间与身份

- 个人来源通常使用 `SYNO.Foto`，共享来源通常使用 `SYNO.FotoTeam`；照片身份必须包括 profile、space、unit ID，不能只保存整数编号。
- 相册列表/成员是统一 `SYNO.Foto` 入口。相册项目的 `owner_user_id` 决定原件来源：0 为共享，其他为个人；`provider_user_id` 用于贡献者角色，不能与系统 uid 或 Photos user ID 混用。
- Photos 不可用时不回退 File Station 扫描，不读取旧 File Station 照片缓存假装 Photos 已接入。
- 具体操作要求的 API 版本及 JSON 参数格式必须同时满足；取得 DSM 管理员身份不等于取得所有照片或所有相册的管理权。

## 读取标准

| 领域入口 | API / 方法与版本 | 关键请求 | 原始响应与领域结果 |
| --- | --- | --- | --- |
| `access` | `UserInfo.me` v1；`Setting.User/Admin/TeamSpace.get` v1 | 当前会话 | `enabled`、home 服务、team 权限、管理员与设置；映射 `SynologyPhotosAccess`，重新读取时先撤销旧授权 |
| `timeline` | `Browse.Timeline.get` v5 | `timeline_group_unit="day"` | `section[].list[]` 的年月日与 `item_count` → 天/月定位 |
| 搜索时间线 | `Search.Search.get_search_timeline` v2 | `keyword`、day 分组 | 同时间线结构；关键词不持久化为协议状态 |
| 时间线/目录项目 | `Browse.Item.list` v4 | `offset/limit`、时间范围或 `folder_id`、排序、`additional` | `list[]` → `SynologyPhotoPage`；照片 ID、目录 ID、大小必须有效 |
| 相册项目 | `SYNO.Foto.Browse.Item.list` v4 | `album_id`、排序、分页，保留 provider 信息 | 逐项解析原件来源与相册上下文，不能按当前界面来源批量猜测 |
| 搜索照片 | `Search.Search.list_item` v1 | `keyword/start_time/end_time/offset/limit` | 项目页 |
| 条件筛选 | `Browse.Item.list_with_filter` v2 | 已定义筛选条件；没有其他时间条件时发送 `time` 对象数组 | 项目页；能力与条件分别校验 |
| 最近添加 / 相似 | `Browse.RecentlyAdded.list` v1；`Browse.SimilarItem.list_similar` v1 | 当前来源及时间/分页 | 相似组必须包含当前照片，保留完整成员身份 |
| 目录、相册、分类与共享 | 对应 `Browse.Folder/Album/Category/Person/Concept/Geocoding/GeneralTag` | 以各方法固定版本与上下文为准 | [读取字段与版本记录](../discovery/endpoints/photos-library-read.md) |

项目页没有通用 `total/has_more` 承诺：当前适配器以原始 `list.count` 推进 offset，满页继续、短页/空页结束。不能用筛选后的显示数量推进分页，也不能默认第一批就是完整集合。

原始项目的 `id/filename/filesize/time/indexed_time/folder_id/type/additional` 映射为领域对象；时间是 Unix 秒。相册、目录、分类可能使用不同返回容器，不以“字段名相似”建立通用解码。

## 缩略图、原件、预览与下载

当前缩略图适配使用同源 `synofoto/api/v2/p|t/Thumbnail/get`，参数包括 `id/cache_key/type` 及按场景需要的尺寸/上下文。缓存键按 JSON 字符串编码；会话只在头部，不能拼成带令牌的 URL。来源、相册和当前会话必须重新验证。

原件、视频、实况、压缩包及原尺寸 JPEG 分别使用已记录的 Download/Streaming 或转换流程；保持实际照片/目录身份、预览变体和本机导出冲突保护。原尺寸 JPEG 取决于服务端转换条件，不等同于下载一个大缩略图。

自动预览、本机视频/图片转换、ConvertedFile 上传与预览事件分别维护状态；候选消失不等于上传完成。失败可继续其他目标，未知上传不能自动重传。完整参数只维护于[高级管理记录](../discovery/endpoints/photos-advanced-management.md)和当前 Repository。

## 管理功能分组

| 用户结果 | 原始接口组 | 跨端必须保持的约束与详细记录 |
| --- | --- | --- |
| 资料、评级、时间、标签、旋转 | `Browse.Item/GeneralTag` | 固定原件快照和目标值；相对日期在客户端转成固定绝对时间，未知不重复累加；[基础管理](../discovery/endpoints/photos-management.md) |
| 普通、条件、冻结相册 | `Browse.Album/NormalAlbum/ConditionAlbum` | 相册所有者/贡献者分开；成员完整集合及原相册身份保护；恢复/重建不是原地假成功；[高级管理](../discovery/endpoints/photos-advanced-management.md) |
| 目录、封面、排序、移动/复制 | `Browse.Folder`、`BackgroundTask.File` | 不用照片编号冒充目录，保留父目录、来源和目标权限；跨来源/混选按原件分别核对 |
| 上传与相册加入 | `Upload.Item`、`NormalAlbum.add_item` | 先确认上传，再加入相册；加入失败只补该步，不重传文件；重复策略、稳定本机输入与恢复检查点分别维护 |
| 分享、具名成员、密码、有效期、临时分享、收集 | `Browse.Album`、`Sharing.*`、`PhotoRequest` | 读取现状不创建链接；公开/受邀/下载权限与贡献权限分开；临时副本确认后才停止原分享 |
| 人物、主题、手工人脸 | `Browse.Person/Concept`、`Upload.Face` 等 | 固定组/成员/原件，贡献者仅在实际允许的场景操作；不把公开相册当共享原件管理权 |
| 相似组整理 | `Browse.Similar/SimilarItem/SimilarTimeline` | 完整组快照、推荐和移出/拆分/撤销的目标绑定；[相似记录](../discovery/endpoints/photos-similar-items.md) |
| 预览重建、自动预览、新格式提示 | `RegeneratePreview`、`Upload.ConvertedFile`、`Browse.Unit`、设置组 | 接受任务与生成完成分开；角色资格、失败状态及只读核对保留 |
| 后台任务及整库维护 | `BackgroundTask.Info/File`、维护接口 | 取消不回滚已完成部分，清理只删除记录，不能清掉仍用于证明结果的任务；[后台记录](../discovery/endpoints/photos-background-tasks.md) |
| 共享成员、目录权限、全局/识别/显示/重复偏好 | `Setting.*`、`Sharing.Misc`、`FotoTeam.Sharing.*` | 差量保存、当前来源权限、读取失败不作默认值；共享管理员与普通成员范围不同 |

上表是能力分类，不省略每个方法的字段校验；原始方法名、固定版本、嵌套对象和各角色条件必须从所链接的稳定记录及 Repository 对照。`SynologyPhotosManagementFeature` 是当前领域枚举，各端不能因存在枚举就宣称功能已实现。

## 删除与写入结果

删除主流程为个人/共享 `BackgroundTask.File.delete` v1，参数 `item_id:Int[]`、`folder_id:Int[]`；不能用未经主流程确认的目录 helper 替代。单张与混合目录删除有不同结果证据，完整规则见[删除记录](../discovery/endpoints/photos-item-deletion.md)。

权限/会话拒绝不能当作“照片已不见”；任务 done 还需检查错误及最终目标。未知结果绑定原操作，自动行为只允许读取状态，不重放写入。目录删除可能涉及后代内容，不能承诺原子性或必然可恢复。

上传与管理命令使用专用结果和恢复记录，不能直接套一个 Bool。跨重启恢复必须先恢复原文件授权、当前 profile 和原始任务/照片身份，再继续未开始项；不能重复已提交步骤。领域持久化版本与平台书签/文件许可是另一类契约，移植前按仓库规则评估迁移。

## 验证与其他端入口

[请求示例](requests.md#photos)只覆盖已有快照场景，远少于完整 Photos 功能；主要自动化见 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `SynologyPhotos*` 和 [DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/) 的 Photos 模型/界面回归。完整来源仍是版本化证据，不把合成行为升级为 NAS 实测。

移动端采用系统 Photos/Files、分享和前后台模型，不照搬常驻转换、桌面编辑器或 Finder 行为；Windows、Android 对齐进度和明确非目标见[Photos 长期计划](../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。

iPhone/iPad 选择上传与恢复通过移动适配器提供受保护的稳定副本，复用共享上传/相册加入及版本 1 回执；替换会话后旧写入者冻结，未知结果不重发。两种选择器、目录层次、重名策略和相册贡献权限沿当前模型分别处理。具体实现与验证见[移动主计划 M3a](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)，后台传输仍由 M8 单独实施。

移动普通相册使用同一 Album/NormalAlbum 接口与对象权限；独立版本 1 回执用于重启后只读恢复，创建没有回执编号时不按名称确认。个人图库关闭不等于失去相册管理能力，原件编辑与相册关系继续独立判断。M3b2 接入原有相册分享范围、成员、密码及日期，分享恢复使用不含秘密的版本 2 意图/回执；未知密码更新不凭已有保护状态确认。M3b3 临时分享补充选片创建、配置、停止与保留普通相册，以及版本 3 操作/版本 1 流程恢复。M3b4 收集创建/编辑/删除复用已有 PhotoRequest 契约：当前所有者快照、目标目录上传权限、可加入相册、精确有效期/大小和结果回读仍由共享 Repository 检查。收集标识就是访问口令，独立版本 4 恢复仅保存标识与设置摘要，创建丢回执不按名称寻找；删除必须完整分页确认原标识消失，权限失败和分页异常不能作成功。该恢复格式只影响 Apple 客户端，不改 NAS 请求；Mac 未装配新记录，Windows/Android 仅记录影响。M3b5 条件相册沿用原有 ConditionAlbum 创建/修改/建议/预览读取，规则归一化由请求与版本 5 恢复共用，恢复记录仅保存来源、相册编号及名称/规则摘要，创建缺少返回编号保持未知。未知规则顺序和缺名引用不因编辑其他规则而丢失；真实权限及目录访问仍在共享层预检。M3b6 冻结相册复用既有快照、NormalAlbum.set_unfreeze、ConditionAlbum.create 与 Album.delete；版本 6 仅保存名称/规则/快照摘要、编号和删除阶段，重启恢复不发送删除。删除尝试必须先保存，失败保留旧册；普通恢复不依赖个人图库开放。旧 1–5 版本仍可读取，Mac 未装配新记录时沿用原调用行为，Windows/Android 请求契约不变。其他管理继续后续切片。

M3c 两端接入评分、描述、绝对日期/相对偏移与标签创建/添加/移除，沿用已有 Item.set、add_tag/remove_tag 和 GeneralTag.create/list。版本 7 独立记录以照片身份及目标值摘要保存逐空间/逐项提交阶段，标签必须绑定返回编号；重启不重放写入，部分恢复不把摘要生成重试内容。相册读请求保留 album_id 与提供者身份，混合来源只有评分/日期沿既有管理权限开放；其他端网络契约不变，Mac 无恢复适配时原调用保持。旧 1–6 记录继续可读，移动源码/自动化/真机等级见主计划及验证历史。

M3d 移动端复用已有 Folder create/rename/set_order/set_cover、BackgroundTask.File move/copy/delete 与 BackgroundTask.Info 查询，补齐目录操作和混合选择。独立版本 8 记录保存必要目录/照片快照、任务/创建编号、目标总数及封面成功回执，沿既有受保护文件保存，兼容版本 1–7。恢复只查询，缺少任务/创建编号不能猜测成功，封面仍需成功回执与可解码自定义封面，目录移动同时检查原目录最终父编号；跨来源及目录任务保持既有目标权限、计数和部分完成语义。不新增 NAS 参数或降低权限门，Mac 无持久适配时原行为不变，Windows/Android 无请求契约变更。

M3e 移动端沿用 FolderPermission.update/set_config 及 BackgroundTask.Info.list_user_task/abort_task/clear_completed_task/get_error_detail 既有契约，接入共享目录权限、任务取消/清除/错误详情和原目标导航。版本 9 摘要将原权限快照转为摘要，只保留成员类型/编号/角色、密码操作种类、必要目录及任务身份；密码、链接及成员名称不保存。权限更新回执在后续默认选项写入前保存，应用子目录或设置新密码需要明确回执；任务逐项清除先持久保存尝试范围，重启不重发。任务控制恢复使用独立文件，保留原移动复制的查询证据。旧版本 1–8 仍可读；不新增 NAS 参数或修改五端请求契约，Windows/Android 仅记录适配影响，Mac 未配置恢复文件时维持原业务流程。

M3f1 移动照片偏好与旋转复用既有 Setting.User.get/set 和 Browse.Item.set（rotate_action），不新增请求或字段。版本 10 恢复保存偏好稳定枚举/布尔值与旋转原件身份、方向、尺寸；重启只回读最终值，旋转必须同时匹配预期方向、互换尺寸和原件身份。旧 1–9 记录继续可读，保存失败零写。新增 Codable 仅服务 Apple 独立恢复文件，不迁移 NAS/登录配置；Mac 未配置该恢复适配时调用不变，Windows/Android 无请求契约改动。

M3f2 移动手动预览修复复用既有 RegeneratePreview 队列/转换/恢复标记、转换事件与 ConvertedFile 上传，未增加请求字段或放宽原件/相册提供者权限。Apple 恢复版本 11 保存必要原件身份、旧预览版本及各阶段回执，兼容 1–10；在每次写之前保存，重启只读，不把队列消失单独视为成功。已标记但尚未转换的项目结束原操作后可由用户从队列继续；转换已明确失败的清理只结束失败，不能报成功。移动本机转换临时文件受系统保护并排除备份；Mac 未装配恢复记录时仍使用原有同步流程。Windows/Android 契约不变，真实环境验证等级不因此提升。

M3f3 两端接入自动预览设置、前台转换、整库维护和新格式提示，沿用现有 Setting.User、Index、Setting.Wizard、ConvertedFile 与媒体读取参数。版本 12 恢复仅新增 Apple 本机结构，包含稳定设置/身份/动作/回执、三档图片 SHA-256 和视频编码轨道摘要；不保存媒体或会话。转换上传与失败标记均先落盘，未知上传必须匹配本次内容，维护缺少明确接收回执不能用计数归零追认。生成已接受而关闭提示失败时，独立同版本记录保留已接受证据，重启只继续关闭提示；该后续记录与其他管理操作分开，防止被新操作覆盖。兼容旧 1–11 记录，Mac 无恢复适配时仍使用原流程并回归；Windows/Android 无 NAS 契约变更。前台能力不代表系统后台执行，真机/NAS 验证等级不因此提升。

M3f4 两端接入共享图库设置、全局设置/缓存与共享成员目录权限，复用既有 TeamSpace、Setting.Admin/User、Download 和 FolderBatchPermission 请求。版本 13 仅扩展 Apple 本机恢复，保存管理员/目标身份、最小设置和目录原权限、每一步尝试/回执/拒绝状态，不保存成员显示名称、凭据、链接或媒体。多步骤操作先落盘再提交，前一步接收回执保存后才允许下一步；跨实例只回读，不自动补发。保留版本/管理员/原始快照/候选成员/受保护群组/目录父子和公开最低权限检查，缓存没有提交记录时不能按空缓存追认成功。兼容版本 1–12；Mac 仅共享纯目录草稿逻辑且保持原行为，Windows/Android 无源码或 NAS 参数变更。真实 DSM/Photos 权限与操作结果仍须按目标版本验收。
