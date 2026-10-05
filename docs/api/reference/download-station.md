# Download Station

主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)；领域：[ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift)。公开 `SYNO.DownloadStation.*` 优先，只有对应公开能力不可用时才采用已记录的内部 `SYNO.DownloadStation2.*`。

## 操作标准

| 用户结果 / 入口 | API / 方法 | 输入及版本 | 返回 / 核查 |
| --- | --- | --- | --- |
| 任务摘要 `loadDownloadStation` | `Task.list`；`Statistic.getinfo` | 公开 Task 支持区间 1…3；当前快照读取首批 `offset=0,limit=1000,additional=[detail,transfer]` | 原始 `tasks` 等已支持容器 → `DownloadStationSnapshot`，来源、统计可用性与任务状态分开 |
| 完整移动目录 `loadDownloadStationInventory` | 公开 `Task.list` v1 | 每页 500；`additional=detail,transfer`；同总量继续短页，无总量以短页结束 | 只有完整结束才标记 `isComplete`；重复身份、偏移/总量漂移、中途空页或畸形容器返回错误，旧界面数据保留 |
| 单项详情 `loadDownloadTaskDetails` | 公开 `Task.getinfo` v1 | 单一稳定 `id`；`additional=detail,transfer,file,tracker,peer`，按官方要求逗号分隔 | 严格匹配唯一任务；文件名不当作 NAS 绝对路径；Tracker 只展示源站，统计缺值保持未知 |
| 内部备用摘要 | `DownloadStation2.Task.list`、`Task.Statistic.get`、`Settings.Location.get` | 各自 v1/v2 能力，不能复制公开请求字段猜内部行为 | [备用接口记录](../discovery/endpoints/download-station2-fallback.md) |
| 链接创建 `createDownloadTaskResult` | 公开 `Task.create` | 链接固定 v3（`uri` 自 v3）；`destination` 按 NAS 契约传递，不按目录降成 v1/v2 | 旧调用保留稳定任务回读；移动回调先保存摘要、再保存官方接受回执；未知不自动重发 |
| 任务文件 `createDownloadTaskFileResult` | 公开 `Task.create` multipart | `.torrent/.nzb/.txt`；同样按 destination 选择 v1/v2，密码只在当次发送 | 同创建结果，不把成功上传请求当作所有下载已完成 |
| 暂停、继续 | `Task.pause/resume` | 使用稳定任务 ID 和确认时快照；固定版本见[参数目录](requests.md#download-station) | 单项/批量结果逐项核对，部分成功保留；旧 `finish` 枚举当前不产生请求 |
| 移动控制恢复 `loadDownloadTaskControlState` | 公开 `Task.list` v1 | 完整分页、单一合法任务编号 | 仅查询，匹配原身份及目标状态；本机终态保存后 `acknowledgeDownloadTaskControlResult` 清理进程内旧保护，不产生 NAS 请求 |
| 保存位置编辑与恢复 | 公开 `Task.edit` v2、`Task.list` v1 | 单项 `id,destination`；完整目录重读原身份与原位置，能力需同时含读取 v1 与编辑 v2 | 返回必须有唯一同编号 `error`；成功还要回读目标位置，未知只查询，未开始项显式继续/取消 |
| 删除任务／结束并移出未完成文件 | `Task.delete` | `id`、`force_complete`；共享旧参数名 `removeData` 仅为调用兼容 | `false` 移除任务，`true` 请求把未完成文件移入目标目录；不是删除下载数据，列表消失也不能证明文件已移动 |
| BT 搜索 | `BTSearch.getModule/getCategory/start/list/clean` | v1；模块、关键词、分类、排序、分页和任务 ID | 仅管理本次搜索任务，取消/结束清理自己的任务 |
| 设置 | `Info.getinfo/getconfig/setserverconfig`、`Schedule.getconfig/setconfig` | 新移动路径 `loadDownloadSettingsSnapshot/changeDownloadSettings/reviewDownloadSettings`；Info 优先 v2，能力仅含 v1 时不编辑默认目录；Schedule v1 | 当前管理权限、字段存在性、原值比较、分区差量及只读恢复；旧 Mac 全量设置签名不变 |

上述 1000 项是当前 macOS 摘要入口的读取范围，不代表 NAS 永远只有 1000 项或已经读取全量。若目标端需要完整任务目录，应按已记录分页契约实现独立切片，不能在文档中把当前限制改写为已解决。

移动 M5a1 已接独立完整目录，macOS 页面仍使用原摘要。共享公开创建/控制/任务删除的结果读取统一复用完整分页，不再以 5000 项硬截断或首批 1000 项判断对象不存在；这不改变 `force_complete` 的含义。内部备用摘要保留 `isComplete=false`，其写入结果与完整分页仍须在 M5 后续切片收敛，不能把公开分页测试当作内部协议证据。移动速度、分享率和剩余时间缺失显示 `--`，真实零速度保留零；暂停、做种等非下载状态不估算剩余时间。

移动 M5a2 将单项和多项暂停/继续统一到独立持久队列。共享原协议方法保持原签名，新增带 `willSubmit` 的兼容重载；只有最新状态通过后才调用保存回调，保存失败或发送前取消不产生控制请求。已提交未知项仅用完整目录读取恢复，不能转调暂停/继续来探测；确认结束并持久保存后才清理同一连接中的旧回读保护，避免影响下一次用户操作。恢复结构记录账号上下文摘要、任务编号、名称/大小/目标摘要、动作与逐项阶段，不记录原名称、路径、URI 或凭据。

五端影响：iPhone/iPad 同一多选与恢复语义；macOS 原协议调用及界面不变，共享新增路径需完整回归。Windows/Android 本轮没有实现变化，后续应遵守写前保存、逐项结果、未知只读、剩余显式继续/取消和跨动作重复保护；不得仅新增一组批量按钮就宣称已具备重启恢复。所有请求参数、能力与权限要求保持原契约，本阶段仍没有真实 NAS 写入证据。

## 移动设置的差量与恢复

M5b 依据同一官方指南第 17–20 页：`Info.getinfo.is_manager` 只接受明确布尔值；常规配置和计划为管理员设置，管理权限未知时不发送。配置字段缺失或类型不符不补 false/0；v1 不开放默认目录，Schedule 暂不可用只影响计划分区。新 `DownloadSettingsSnapshot` 与旧 `DownloadStationSettings` 并存，旧 Mac 调用未改；不能据此把旧全量模型的默认值标为字段存在证据。

`Info.setserverconfig` 官方示例仅发送两个字段，`Schedule.setconfig` 示例仅发送 `enabled`，因此新移动路径按用户实际差量保存。HTTP/FTP 在官方限制中共用一个值，UI 统一编辑且两项原值必须存在并一致；同时发送相同目标值，不以 FTP 覆盖 HTTP 的顺序暗改另一字段。新限速仅影响新建/继续的 HTTP/FTP 下载，原下载不中断。默认目录复用 File Station 文件夹选择，保留名称空格并只去掉选中绝对路径的首个根分隔符；不能从浏览权限推断保存权限。

每个分区发送前重读当前权限与变更字段原值，只有写前持久化成功才发送。常规与计划分开记录，已完成不重放；未知只查询原变更，匹配目标才结束，原值未变也不能证明请求未发送。未执行分区必须显式继续或取消。`Downloads/settings-v1.json` 只存上下文摘要、字段原值/目标值和阶段，目录受完整文件保护、原子写和排除备份，不存凭据或主机；损坏/写失败保持限制，不覆盖原文件。账号切换后迟到结果只落原记录，不进入新页面。

五端影响：iPhone/iPad 共享以上语义并分别做目标验证；macOS 旧全量设置行为保持，共享兼容增量必须回归；Windows/Android 本次只登记差量、缺失字段、当前权限及两分区恢复要求，不改源码。新增 `save-settings/save-schedule` 的 `synthetic-delta` 请求样本独立于旧全量样本。上述均为官方文档、源码与合成证据，没有真实 NAS 设置写验收；每周时段编辑未见于公开字段及 Mac 基线，不在此切片。

## 创建回执与移动恢复

官方指南第 24–25 页规定 URI 自 v3、文件自 v1、目录自 v2；创建成功允许没有 data 或任务编号。共享公开链接改用 v3，只对创建放宽成功 data 的存在要求，普通读取仍不能把无 data 当作空列表。任务文件仍按目录选择 v1/v2。旧任务回读接口保留其稳定编号语义；移动新增写前摘要与接受回执回调，`requestAccepted` 表示请求已被接受，不表示下载完成或任意任务的归属。带回调创建复用同一校验/请求，不调用内部备用创建。

移动 `Downloads/creations-v1.json` 只保存账号上下文、来源/请求 SHA-256 摘要、类型、时间和阶段；写前持久化失败零请求，成功回执落盘失败保留未知保护。来源摘要排除目标目录；文件来源依据实际内容，改名/换目录不会解除同来源未知保护，同名同大小不同内容不会被混淆。原始 URI、文件名、内容及凭据不进入该记录，文件只保留当前发送的受保护副本并清理，不跨重启自动续传输入。

已知拒绝与明确未发送可结束记录；未知只能刷新当前任务列表，不能根据名称、目录、同链接、新编号或任务消失认领成功，也不能清除记录解锁重发。官方无操作查询编号，因此丢失全部成功回执后的精确归属仍未知；当前列表可继续使用，其他来源创建不受该条记录阻塞。跨账号迟到回执只写原记录，同账号新连接仍受原来源保护。

五端影响：iPhone/iPad 共用持久创建流程并分别验证；Mac App 未改，共享链接版本与文件内容摘要修正需全量及双架构回归，旧调用未新增持久恢复。Windows/Android 只登记语义；Android 当前链接仍按目录选 v1/v2，旧 `create/synthetic-link` 留为 `sourceReviewed`，新增 `synthetic-link-v3` 官方请求样本，不通过改动旧断言掩盖 Android 差异。实际 NAS 创建、下载运行和完成须分别由设备验收。

## 编辑与 RSS 的官方证据边界

来源为 [Synology Download Station Web API 指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/DownloadStation/All/enu/Synology_Download_Station_Web_API.pdf)（2014-03-26）。第 26–27 页 Task.edit 的请求及响应字段要求 v2 及以后，示例 URL 中的 v1 不作为版本门禁依据。新的目的地编辑请求应固定 v2，能力不包含 v2 时不发送。现有 Android 实现仍发送 v1，旧合成样本保留为 `sourceReviewed`，另新增 v2 官方样本；这是待修正源码差异，不是“仅待真机”。本 M5 波次不修改 Android 源码或放宽其测试。

第 32–35 页仅提供公开 RSS.Site.list/refresh 与 RSS.Feed.list。Site 标识为整数，Feed.list 必须指定站点 `id`；尺寸和时间需按文档保留整数/数字字符串差异。不能推定订阅创建/删除方法。M5c 后续实现既有订阅查看、刷新和条目创建下载；当前仅 M5c1 已接保存位置编辑，RSS 仍未实现。所有以上说明仍是公开文档、源码及合成证据，没有新增真实 NAS 行为结论。

## 移动任务保存位置编辑与恢复

M5c1 只编辑公开字段 `destination`，不猜测优先级、Tracker 或种子选项。每个任务分开发送，写前完整读取并匹配编号、名称/大小摘要及原位置；位置不进入稳定身份摘要，以便正确匹配已保存的新位置。目录从现有 File Station 选择器取得，只去掉绝对路径首个 `/`，拒绝 NAS 根路径、空段、`.`/`..` 和控制字符，保留合法名称空格。目录可浏览不代表可写，实际编辑权限由 NAS 的当前账号授权及返回值判定，不要求普通任务编辑具备管理员身份。

`Task.edit` 的 data 必须是单一同编号结果数组，`error=0` 后还需查询到目标位置；缺条目、重复/错编号、错误类型、未知错误或断网均保留未知。官方 105/402 分别对应会话无权限与目标目录拒绝，404 为任务编号无效，405 是无效任务操作，407 是设置位置失败，不能把 405/407 误译成权限问题。明确拒绝可保留该项失败并继续其他项目，未知停止后续提交。

`Downloads/edits-v1.json` 保存账号上下文、任务编号/身份摘要、原位置/目标位置和逐项阶段；完整文件保护、原子写及排除备份，不保存名称正文、URI、主机或凭据。发送前记录保存失败零请求，提交后只读恢复，原位置未变不证明此前未执行。未开始项需明确继续或取消，取消立即持久保存；结束记录可清除，未知记录不能删除以解锁重发。编辑与同任务暂停/继续/移除互相保护，表单冻结打开时的连接身份，切账号/重连后旧回调失效。

五端影响：iPhone/iPad 新增同一单项/多项原生流程和独立设备测试；Mac 保持旧 UI/调用，共享增量需完整回归及双架构构建；Windows/Android 仅同步以上结果和恢复要求，没有源码变更。沿用已建立的 `edit-destination/synthetic-task-v2` 请求样本。真实 NAS 尚未验证；任务位置字段更新不证明既有文件实际搬迁，文件归属和删除仍由 M5d 单独处理。

## 关键语义

- `force_complete` 不是删除数据开关，也不是单独的完成做种方法。当前 macOS 提供删除任务和“结束并移出未完成文件”两种选择；移动 M5 不得照旧参数名误译为删除文件。任务编辑、RSS 或额外控制能力需核对实际 Repository 与独立契约，不由本表笼统推定已实现。
- 目标目录创建使用其真实支持版本；有 destination 的请求不得降成 v1 后静默忽略目录。
- 原始任务状态、正在执行的控制请求和最终结果分别呈现；错误、正在进行、已结束不互相替代。
- 上传任务文件、下载任务运行、实际内容完成是不同阶段。网络中断后先查询原创建/控制结果，禁止为了“重试”制造重复任务。

精确字段、参数格式、会话位置和策略见[请求参数目录](requests.md#download-station)；相关测试在 [DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/) 的 `DsmServiceManagementRepositoryTests` 和请求快照回归。界面主入口为 [ServiceManagementView](../../../apple/Apps/DsmMac/Sources/ServiceManagementView.swift)。

其他端对齐领域结果与安全行为，任务通知、文件选择、下载位置权限及后台执行采用目标平台实现。公开/内部降级、权限不足、目的地版本不足、部分失败、未知回执和真实 NAS 任务完成均需分别验收。
