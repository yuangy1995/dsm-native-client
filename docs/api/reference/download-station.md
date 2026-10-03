# Download Station

主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)；领域：[ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift)。公开 `SYNO.DownloadStation.*` 优先，只有对应公开能力不可用时才采用已记录的内部 `SYNO.DownloadStation2.*`。

## 操作标准

| 用户结果 / 入口 | API / 方法 | 输入及版本 | 返回 / 核查 |
| --- | --- | --- | --- |
| 任务摘要 `loadDownloadStation` | `Task.list`；`Statistic.getinfo` | 公开 Task 支持区间 1…3；当前快照读取首批 `offset=0,limit=1000,additional=[detail,transfer]` | 原始 `tasks` 等已支持容器 → `DownloadStationSnapshot`，来源、统计可用性与任务状态分开 |
| 内部备用摘要 | `DownloadStation2.Task.list`、`Task.Statistic.get`、`Settings.Location.get` | 各自 v1/v2 能力，不能复制公开请求字段猜内部行为 | [备用接口记录](../discovery/endpoints/download-station2-fallback.md) |
| 链接创建 `createDownloadTaskResult` | 公开 `Task.create` | 无 destination 固定 v1；带 destination 固定 v2；`uri` 为已允许的链接类型，目录按 NAS 契约传递 | 专用创建结果；固定输入和创建身份，未知不自动重发 |
| 任务文件 `createDownloadTaskFileResult` | 公开 `Task.create` multipart | `.torrent/.nzb/.txt`；同样按 destination 选择 v1/v2，密码只在当次发送 | 同创建结果，不把成功上传请求当作所有下载已完成 |
| 暂停、继续 | `Task.pause/resume` | 使用稳定任务 ID 和确认时快照；固定版本见[参数目录](requests.md#download-station) | 单项/批量结果逐项核对，部分成功保留；旧 `finish` 枚举当前不产生请求 |
| 删除任务／结束并移出未完成文件 | `Task.delete` | `id`、`force_complete`；共享旧参数名 `removeData` 仅为调用兼容 | `false` 移除任务，`true` 请求把未完成文件移入目标目录；不是删除下载数据，列表消失也不能证明文件已移动 |
| BT 搜索 | `BTSearch.getModule/getCategory/start/list/clean` | v1；模块、关键词、分类、排序、分页和任务 ID | 仅管理本次搜索任务，取消/结束清理自己的任务 |
| 设置 | `Info.getconfig/setserverconfig`、`Schedule.getconfig/setconfig` | 已支持版本与原设置基线 | 部分分区不可用不当作默认值；保存后核对实际设置 |

上述 1000 项是当前 macOS 摘要入口的读取范围，不代表 NAS 永远只有 1000 项或已经读取全量。若目标端需要完整任务目录，应按已记录分页契约实现独立切片，不能在文档中把当前限制改写为已解决。

## 关键语义

- `force_complete` 不是删除数据开关，也不是单独的完成做种方法。当前 macOS 提供删除任务和“结束并移出未完成文件”两种选择；移动 M5 不得照旧参数名误译为删除文件。任务编辑、RSS 或额外控制能力需核对实际 Repository 与独立契约，不由本表笼统推定已实现。
- 目标目录创建使用其真实支持版本；有 destination 的请求不得降成 v1 后静默忽略目录。
- 原始任务状态、正在执行的控制请求和最终结果分别呈现；错误、正在进行、已结束不互相替代。
- 上传任务文件、下载任务运行、实际内容完成是不同阶段。网络中断后先查询原创建/控制结果，禁止为了“重试”制造重复任务。

精确字段、参数格式、会话位置和策略见[请求参数目录](requests.md#download-station)；相关测试在 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmServiceManagementRepositoryTests` 和请求快照回归。界面主入口为 [ServiceManagementView](../../../apple/Apps/DsmMac/Sources/ServiceManagementView.swift)。

其他端对齐领域结果与安全行为，任务通知、文件选择、下载位置权限及后台执行采用目标平台实现。公开/内部降级、权限不足、目的地版本不足、部分失败、未知回执和真实 NAS 任务完成均需分别验收。
