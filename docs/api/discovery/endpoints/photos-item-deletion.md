# Photos 原件与目录删除

端点组：`photos-item-deletion`；内部接口，风险 critical。个人和共享来源分别使用 Foto / FotoTeam，禁止以 File Station 删除替代。

## 请求与完成条件

- `BackgroundTask.File.delete` v1，POST，JSON 业务值装入表单；`item_id` 与 `folder_id` 均为整数数组。单张照片传单元素 item_id 与空 folder_id；混选传固定照片和目录编号。
- 返回 `data.task_info.id`。使用统一 `SYNO.Foto.BackgroundTask.Info.get_status` v1、`id=[任务编号]` 查询同一任务；共享任务也不改用 FotoTeam.Info。
- 已观察单张删除初态为 waiting、completion=0、total=1，终态 done、completion=1、total=1、error=0、skip=0。接受回执或任务消失均不单独证明原件删除。
- 单张照片必须以同空间 `Browse.Item.get` v5 的成功空 list 确认不存在；权限拒绝、解析失败或非空结果不能当成功。
- 混选需任务 done 且 error/skip/overwrite 为零，再回读原父目录身份和访问权、完整分页确认目标目录不再列出，照片逐项成功空回读。目录读取按100条分页，重复页或错误父编号拒绝；不声称直接验证所有后代文件。
- `Browse.Folder.delete` 静态 helper 不是官方主界面的混选流程，不能替代上述任务接口。

## 身份、权限与不确定结果

预检固定 profile/账号/空间/照片编号、文件名、大小、拍摄和索引时间、目录、媒体类型；读取最小身份，不依赖 EXIF、地址或转换详情。写前重新核对目录 view/manage；共享 entry 需要实际目录管理权，upload 不等于删除权。管理角色只在相应共享范围生效。

目录必须非根、同一空间与父目录，有完整原始路径/父编号，目标不能重复；混选照片位于该父目录且无相册上下文。确认明确目录全部内容及相册引用受影响，恢复取决于 NAS 配置。能力、权限、确认、去重与结果处理遵循[通用标准](../../reference/common.md)，不按精确 DSM/Photos 版本白名单决定入口。

同一操作标识绑定固定目标且只提交一次。明确 DSM 105/106/107/119 拒绝与 117、网络中断、畸形回执、提交后取消的未知结果区分；未知只读查询原目标，不重发，不按名称认领新对象。取消未提交项目不回滚已提交项。任务存在 skip/error 时保留部分结果，没有逐目录结果就不能猜测哪些目录已删除。

完成只移除已确认目标并修正原查询分页，保留月份/目录与选择；旧分页响应不能使已删除目标重现。若当前目录被删，返回存活父目录。恢复是否跨进程属于平台实现范围，不能由 NAS 任务能力推断。

## 证据与范围

[2026-09-10 记录](../environments/INDEX.md#2026-09-10-photos-deletion-observation)在 DSM 7.2.1-69057 Update12 / Photos1.8.2-10090 对唯一合成 PNG 单次删除、任务完成和刷新后空回读提供 behavior-verified；设备归属未知。共享删除、目录混选、断网/重启与其他版本没有因此通过。共享命名空间与混选流程为官方脚本 static 证据。

当前实现与未完成验证只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。
