# Photos 单项原件删除（macOS 按能力开放）

## 标识与证据

- 端点组：`photos-item-deletion`；组件 synology-photos；内部写接口；风险 critical。
- 2026-09-10 官方前端静态代码明确调用 BackgroundTask.File.delete，参数 item_id、folder_id；随后使用 task_info.id 跟踪任务。
- SYNO.API.Info 只读声明确认 SYNO.Foto.BackgroundTask.File：entry.cgi、JSON、minVersion=maxVersion=1。
- 2026-09-10 在用户明确授权并最终确认后，只对本次新增的一张合成 PNG 提交一次删除。任务完成、单项回读为空、网页刷新后仍为空；该受控正常路径有行为证据，不代表其他媒体、权限或异常路径通过。
- 精确环境为 DSM 7.2.1 / build 69057 / Update 12、Photos 1.8.2-10090；删除前重新核对目标身份和目录 view/manage 权限。见 [受控验证记录](../environments/2026-09-10-photos-deletion-observation.md)。设备匿名归属仍待确认，机器索引不冒用既有基线。

## 请求与语义

- POST /webapi/entry.cgi，api=SYNO.Foto.BackgroundTask.File、method=delete、version=1。
- 业务参数采用 JSON 编码：item_id=[照片项目 ID]，folder_id=[]；不接受路径，不使用 File Station 删除。
- 这是原件删除，不是 NormalAlbum.delete_item 的“从相册移除”。恢复能力由 NAS 配置决定，不能保证可恢复。
- 未知响应、错误、取消、任务尚未完成均不能视为确认成功。静态任务回执仅证明可能提交，不证明目标已消失。
- 本次实际回执为 data.task_info，初始 status="waiting"、completion=0、total=1。随后 SYNO.Foto.BackgroundTask.Info.get_status v1、id=[任务标识] 返回 data.list 中 status="done"、completion=1、total=1、error=0、skip=0。

## 客户端安全边界

- 用户进一步授权未逐一验证的版本也开放；macOS 显式启用个人空间单项删除，不按 DSM／Photos 版本白名单拦截。接口必须声明支持 v1 与 JSON，Repository 默认关闭，其他端及共享空间不自动开放。
- 预检和确认后重新核对照片 ID、账号／空间、名称、大小、拍摄与索引时间、文件夹、媒体类型，以及文件夹 view/manage 权限。
- 同一目标串行处理，操作标识绑定目标；一旦开始提交就保留待核对状态，提交异常不自动重放。
- 核对仅通过成功的 Item.get 空列表确认目标不存在；权限错误、失败和非空结果不算成功。本次已核实该版本删除后的 Item.get v5 返回 success=true、data.list=[]，网页刷新后再次读取仍一致。
- UI 已提供右键与预览删除、确认及核对结果入口；已按用户授权开放，不把开放状态表述为所有环境已验证。
- 当前待核对状态只在会话内，未建立跨进程恢复记录。本轮按用户要求跨 DSM／Photos 版本依接口能力开放供测试，不变更持久化结构；App 重启、权限变化和断网仍需测试，结果不明时先在官方 Photos 核对，不重复删除。

## 测试与待验收

- 合成测试覆盖默认关闭、接口不支持或管理权限缺失拒绝、只提交一次、成功空响应、提交后错误不重放、权限错误不能确认删除。
- 自动化使用合成目标，不代替真实版本验证；真实受控删除证据单独记录。
- PENDING_USER_VALIDATION：用新测试包和另行选定的可丢弃照片检查确认取消、单次删除、刷新与重启；预期取消不删除、成功后原件不再显示。权限变化、取消／断网和实际恢复行为仍未验证；网页刷新不能代替 App 重启。后续 Agent 写测试必须另外明确目标与授权，不复用已删除的项目。仅回传版本、步骤和脱敏错误，不能提供凭据或真实照片。
