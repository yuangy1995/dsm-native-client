# Container Manager

分类：`SYNO.Docker.*` 为内部接口，当前 Apple 能力范围为 v1。主实现：[DsmServiceManagementRepository](../../../apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift)；详细原始字段和版本证据：[容器端点组](../discovery/endpoints/container-manager-internal.md)。

## 接口与输入输出

| 用户结果 | API / 方法 | 关键参数 | 结果与校验 |
| --- | --- | --- | --- |
| 容器清单 | `Container.list` | `offset=0,limit=-1,type="all"` | 稳定 ID/name 与原始 State；Running/Paused/Restarting 等不能由展示文案推断 |
| 映像清单 | `Image.list` | `offset=0,limit=-1,show_dsm=false`，布尔不编码为字符串 | ID、仓库、标签分别保留；原始条目数与展开后的标签数不同 |
| 网络 / 项目 / 事件 | `Network.list`、`Project.list`、`Log` 已接读取 | 实际能力、分页和排序按对应实现 | 各分区独立可用，关联数缺失不补成零 |
| 仓库搜索 | `Registry.search v1` | `q:String,offset=0,limit=50,page_size=50` | 固定 v1，v2 实测返回 103；data.data 严格数组，畸形不冒充空结果；当前首批结果 |
| 仓库标签 | `Registry.tags v1` | `repo:String` | 标签原值；不猜测缺失的 latest |
| 拉取映像 | `Image.pull_start/pull_status` | 启动 `repository/tag`；查询 `task_id` | `ContainerImagePullProgress`；接受请求不等于映像可用，轮询及清单核对分别执行 |
| 启动 / 停止 / 重启 | `Container.start/stop/restart` | `name`，先按稳定 ID 核对名称及当前状态 | 操作互斥，身份变化拒绝；回读状态，不把 HTTP 成功当转态完成 |
| 删除容器 | `Container.delete` | `name,force=false,preserve_profile=false` | 与保留配置的“重置”不同；确认全选目标并检查消失 |
| 删除映像 | `Image.delete` | `images:[{repository,tags:[…]}]` 或裸标识 `{identity}` | 标签地址与映像 ID 分开，检查包括停止容器在内的占用；未知只回查 |
| 创建网络 | `Network.create` | `name,enable_ipv6,disable_masquerade`；手动 IPv4 加 `subnet/iprange/gateway`，启用 IPv6 加对应三字段 | 输入模型校验、重名检查和配置回读；结果未知不重复创建 |
| 删除网络 | `Network.remove` | `networks` 对象数组，精确结构见快照 | 目标及关联容器基线固定，不扩大到其他网络 |

精确编码和执行策略见[容器请求快照](requests.md#container-manager)。请求字段以当前 Source/Fixture 为准，不照搬历史端点记录中标为候选或已被后文更正的例子。

## 领域边界

- [ServiceManagement](../../../apple/Packages/DsmCore/Sources/ServiceManagement.swift) 保存容器、映像、网络、项目及模块摘要；[ContainerImagePull](../../../apple/Packages/DsmCore/Sources/ContainerImagePull.swift) 和 [ContainerNetworkCreation](../../../apple/Packages/DsmCore/Sources/ContainerNetworkCreation.swift) 保存专用操作语义。
- 名称、ID、仓库和 tag 是不同标识。删除一个标签不表示底层映像 ID 必须消失；裸 ID 删除也不能扩大到未确认的其他标签。
- 部分失败保留已执行目标，明确拒绝不因其他客户端恰好改变状态而变成成功。运行中、重启中、暂停中与停止状态不混用。
- “项目列表可见”不代表 Compose 编辑、项目部署或完整容器创建已经接入。只有 Repository 和原生入口均存在且有对应证据的操作才能标为可用。

## 移植与验证

保留实际能力、账号权限和操作确认，不能把静态发现直接当作所有版本可写，也不能复制历史关闭开关来推断当前所有端的开放状态。最新能力以目标端代码和[平台矩阵](../../progress/PLATFORM_MATRIX.md)为准。

测试入口：[DsmNetwork/Tests](../../../apple/Packages/DsmNetwork/Tests/)、[DsmMac/Tests](../../../apple/Apps/DsmMac/Tests/) 的容器生命周期、映像标签删除、网络创建/删除及拉取任务回归。真实 NAS 的运行影响、占用变化、权限撤销和任务长断线仍须专用目标验收。

2026-10-03 修复：macOS 下载状态暂时读取失败后继续自动查询原 task_id；1202 明确 Docker 失败保存为失败终态，不再停留在“检查下载状态”。无回执不按名称猜测或重发。真实受控下载已复现 NAS 下载失败，成功结束路径仍待验证；见[当日记录](../discovery/environments/2026-10-03-container-image-pull-observation.md)。

## 2026-10-14 Android A8 实现进度

Android 已接原生容器单项/批量控制与删除、映像下载/标签删除、网络完整创建表单/删除，以及独立加密恢复。写入使用固定 v1、当前账号授权与原对象；不按DSM/Container Manager精确版本禁用，旧无原快照门面仍不可写。来源、阶段和任务号归属独立于界面，未知只读恢复、不自动续批次或重发。

容器重启必须观察同一身份的启动时间增加。映像删除保留原标签与源 ID，下载只跟踪原 task_id 并保留字符串/数字类型；无回执不以旧标签认领结果。网络 remove 发送单项对象数组并核对 failed；无创建回执时，同名网络仅表示当前已经存在。日志进入活动记录页才完整分页读取，保留未附时区的 NAS 当地时间，离开页即取消读取。

当前Debug/仪器包构建、82项聚焦JVM及同包手机中文浅色/平板英文深色二倍字号各20项原生通过；真实NAS、物理辅助功能及系统进程回收尚未验收，VMM继续后续实施。精确来源、剩余工作及测试环境要求见[Android A8账本](../../archive/2026-h2/ANDROID_REWRITE_IMPLEMENTATION_HISTORY_ZH.md#a8-容器与虚拟机整模块功能对齐账本实施中)。其他四端不变，没有新增环境验证等级。
