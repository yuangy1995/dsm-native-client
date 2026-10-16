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
| 目录、相册、分类与共享 | 对应 `Browse.Folder/Album/Category/Person/Concept/Geocoding/GeneralTag` | 以各方法固定版本与上下文为准 | [读取字段与版本记录](../discovery/endpoints/photos-library.md#photos-library-read) |

项目页没有通用 `total/has_more` 承诺：当前适配器以原始 `list.count` 推进 offset，满页继续、短页/空页结束。不能用筛选后的显示数量推进分页，也不能默认第一批就是完整集合。

原始项目的 `id/filename/filesize/time/indexed_time/folder_id/type/additional` 映射为领域对象；`time` 是 Unix 秒，`indexed_time` 是 Unix 毫秒，必须保留非整秒精度，不能按数值大小猜单位。2026-10-16 已通过官方脚本与 Windows 真实只读链路纠正原文将两者均视作秒的错误，详见[观察记录](../discovery/environments/INDEX.md#2026-10-16-windows-read-regression)。相册、目录、分类可能使用不同返回容器，不以“字段名相似”建立通用解码。

## 缩略图、原件、预览与下载

当前缩略图适配使用同源 `synofoto/api/v2/p|t/Thumbnail/get`，参数包括 `id/cache_key/type` 及按场景需要的尺寸/上下文。缓存键按 JSON 字符串编码；会话只在头部，不能拼成带令牌的 URL。来源、相册和当前会话必须重新验证。

原件、视频、实况、压缩包及原尺寸 JPEG 分别使用已记录的 Download/Streaming 或转换流程；保持实际照片/目录身份、预览变体和本机导出冲突保护。原尺寸 JPEG 取决于服务端转换条件，不等同于下载一个大缩略图。

下载与交付语义：纯照片选择逐项下载，相似组先读取完整成员；ZIP 仅用于完整相册、目录或含子目录的同级混合选择，不新增照片数组打包参数。相册下载权限与原件来源分别检查，原尺寸 JPEG 仍限符合能力和格式条件的单张。客户端按实际返回格式决定扩展名，并在受保护临时目录中处理重名与部分失败，再由系统保存/分享面板交付。幻灯片复用独立分页和受保护范围读取，视频结束回调绑定当前播放项。合成测试不提升目标 NAS 的证据等级。

自动预览、本机视频/图片转换、ConvertedFile 上传与预览事件分别维护状态；候选消失不等于上传完成。失败可继续其他目标，未知上传不能自动重传。完整参数只维护于[高级管理记录](../discovery/endpoints/photos-management.md#photos-advanced-management)和当前 Repository。

## 管理功能分组

| 用户结果 | 原始接口组 | 跨端必须保持的约束与详细记录 |
| --- | --- | --- |
| 资料、评级、时间、标签、旋转 | `Browse.Item/GeneralTag` | 固定原件快照和目标值；相对日期在客户端转成固定绝对时间，未知不重复累加；[基础管理](../discovery/endpoints/photos-management.md#photos-management) |
| 普通、条件、冻结相册 | `Browse.Album/NormalAlbum/ConditionAlbum` | 相册所有者/贡献者分开；成员完整集合及原相册身份保护；恢复/重建不是原地假成功；[高级管理](../discovery/endpoints/photos-management.md#photos-advanced-management) |
| 目录、封面、排序、移动/复制 | `Browse.Folder`、`BackgroundTask.File` | 不用照片编号冒充目录，保留父目录、来源和目标权限；跨来源/混选按原件分别核对 |
| 上传与相册加入 | `Upload.Item`、`NormalAlbum.add_item` | 先确认上传，再加入相册；加入失败只补该步，不重传文件；重复策略、稳定本机输入与恢复检查点分别维护 |
| 分享、具名成员、密码、有效期、临时分享、收集 | `Browse.Album`、`Sharing.*`、`PhotoRequest` | 读取现状不创建链接；公开/受邀/下载权限与贡献权限分开；临时副本确认后才停止原分享 |
| 人物、主题、手工人脸 | `Browse.Person/Concept`、`Upload.Face` 等 | 固定组/成员/原件，贡献者仅在实际允许的场景操作；不把公开相册当共享原件管理权 |
| 相似组整理 | `Browse.Similar/SimilarItem/SimilarTimeline` | 完整组快照、推荐和移出/拆分/撤销的目标绑定；[相似记录](../discovery/endpoints/photos-library.md#photos-similar-items) |
| 预览重建、自动预览、新格式提示 | `RegeneratePreview`、`Upload.ConvertedFile`、`Browse.Unit`、设置组 | 接受任务与生成完成分开；角色资格、失败状态及只读核对保留 |
| 后台任务及整库维护 | `BackgroundTask.Info/File`、维护接口 | macOS与Android接入当前用户列表、停止、固定快照逐项清理、错误详情与目标跳转；停止保留已完成部分，清理只移除记录，不能清掉仍用于证明结果的任务；[后台记录](../discovery/endpoints/photos-library.md#photos-background-tasks) |
| 共享成员、目录权限、全局/识别/显示/重复偏好 | `Setting.*`、`Sharing.Misc`、`FotoTeam.Sharing.*` | 差量保存、当前来源权限、读取失败不作默认值；共享管理员与普通成员范围不同 |

上表是能力分类，不省略每个方法的字段校验；原始方法名、固定版本、嵌套对象和各角色条件必须从所链接的稳定记录及 Repository 对照。`SynologyPhotosManagementFeature` 是当前领域枚举，各端不能因存在枚举就宣称功能已实现。

## 写入可用性与版本策略（五端统一）

五端均按实际接口能力、当前账号/对象权限、必要确认、防重复提交和结果复查开放操作；不匹配DSM/build/套件或客户端类型版本白名单，也不为版本匹配要求额外系统管理读取权限。未实测版本不标为已验证，但不据此关闭功能。

普通Photos/Chat账号可按套件与对象实际授权使用写入；文件设置、权限、挂载和系统管理仍保留功能本身要求的权限。能力缺失、参数或原对象变化、实际权限拒绝仍会停止对应操作；未知提交只读恢复，不自动重放。

版本记录用于追踪证据和排障，不构成功能白名单。

## 删除与写入结果

删除主流程为个人/共享 `BackgroundTask.File.delete` v1，参数 `item_id:Int[]`、`folder_id:Int[]`；不能用未经主流程确认的目录 helper 替代。单张与混合目录删除有不同结果证据，完整规则见[删除记录](../discovery/endpoints/photos-management.md#photos-item-deletion)。

权限/会话拒绝不能当作“照片已不见”；任务 done 还需检查错误及最终目标。未知结果绑定原操作，自动行为只允许读取状态，不重放写入。目录删除可能涉及后代内容，不能承诺原子性或必然可恢复。

上传与管理命令使用专用结果和恢复记录，不能直接套一个 Bool。跨重启恢复必须先恢复原文件授权、当前 profile 和原始任务/照片身份，再继续未开始项；不能重复已提交步骤。领域持久化版本与平台书签/文件许可是另一类契约，移植前按仓库规则评估迁移。


## 实现与验证范围


当前 Apple 移动端相册检查点仅接受 `SynologyPhotosAlbumCheckpoint.currentVersion = 16`，不读取开发阶段 1–15；原记录不自动迁移或重放。依据 `apple/Packages/DsmCore/Sources/SynologyPhotosAlbumRecovery.swift` 的构造与恢复校验。它是本地恢复格式，不是 NAS API 版本。

`Item.list.time` 为秒，`indexed_time` 为毫秒。Windows 已按该契约修正；Apple 和 Android 的部分调用仍存在秒单位解释缺口，详见[已知限制](../../progress/KNOWN_LIMITATIONS.md)，不能视为五端已对齐。
