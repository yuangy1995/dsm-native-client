# Container Manager 映像下载契约只读核查

按环境模板建立；本次先核查官方只读线索，不触发下载或其他写操作。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不建立 current 基线 |
| 匿名设备别名 | 未确认，不根据页面名称或相同版本推断 lab-a |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-09-17 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12，当前官方 get_user_service 的 Session 白名单字段 |
| 设备架构类别 | 未验证 |
| 连接方式 | 已登录 Chrome 官方 DSM，QuickConnect；直连/中继类别未验证 |
| 证书类别 | 未验证 |
| 账号权限类别 | 管理员，当前官方 Session.is_admin=true |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| container-manager | Container Manager | 24.0.2-1535 | 官方页面可打开 | 当前官方 Package.list 的版本字段 |

## 证据来源

- 既有端点记录：`endpoints/container-manager-internal.md`。
- 本轮只观察官方页面/已加载静态资源和自然读取请求；未导出原始 HAR。
- macOS 源码及合成测试只作为定位线索，不证明真实下载的完成/失败语义。

## 发现范围

- 目标：核实 Image.pull_start 启动回执、任务身份、完成/失败/取消与最终映像回读间的关系。
- 不执行：下载映像、删除映像、启动/停止容器、创建网络、修改套件或权限。
- 限制：只有 repository/tag 请求候选已经记录，不能用映像名称出现或旧标签存在推断本次下载完成。

## 安全检查

- 只保存 API 名称、参数/响应结构与必要版本，不保存会话、主机、账号或真实映像清单。
- 不读取 Cookie、SID、SynoToken、DID、密码，不保存截图或原始响应。
- 若缺少可观察的完成语义，记录契约缺口；不新增推测的 Domain/Repository 公开接口。

## 实际只读证据

打开 Container Manager 后，官方 Image.list v1 请求为 `offset=0`、`limit=-1`、
`show_dsm=false`，后者为原生布尔编码。成功响应 `data` 为对象，包含 `images` 数组及
数值 `offset/limit/total`；本次响应 total 与数组长度一致，不保存真实条数或映像名称。
数组元素字段类型如下，仅证明本环境只读形态：

| 字段 | 类型 |
| --- | --- |
| id / repository / description / digest / remote_digest | string |
| tags | array of string |
| created / size / virtual_size | number |
| upgradable | boolean |

官方页面刷新自然产生 API.Info、get_user_service 和 Package.list，白名单元数据表明：
Image v1、Registry v1–v2、Entry.Request.Polling v1 均为 entry.cgi、JSON 格式。
版本/权限和映像列表响应属于本轮 `read-verified`；不归入旧 lab-a verification。

## 下载任务静态线索

已加载官方 `webman/3rdparty/ContainerManager/MainVue.js` 中存在下列代码路径，证据
严格为 `static`，本轮未主动调用下载、状态查询或任务枚举，未取得后二者的响应证据：

- Registry 选择标签后的启动路径向 Image.pull_start v1 传 repository/tag。
- URL 导入路径另传 registry/username/password；只记录字段名，未读取或输入真实值。
- 一条调用路径解构启动回执的 task_id，并向 Image.pull_status v1 传该 task_id。
- 状态消费字段包括 finished、repository、tag、downloaded，另一处另读 current/total；
  前端以 finished 判断结束、以 current/total 计算进度，并将 downloaded 乘 1024²用于
  展示。字段实际类型、单位和“结束是否成功”尚未取得运行时证据，不据此建强类型契约。
- 全局任务轮询路径调用 Entry.Request.Polling.list v1，参数为
  task_id_prefix="SYNO_DOCKER_IMAGE_PULL"、extra_group_tasks=["admin"]；读取 admin
  数组并分别查询 pull_status。列表为空仅说明此聚合列表无任务，不能证明某次下载成功。
- 官方 Image.list 同样以 offset=0/limit=-1/show_dsm=false 更新最终列表。
- 未找到足以证明失败终态、任务消失、取消、回执丢失后的唯一任务绑定、其他账号可见性
  的已验证契约。不能从静态前端恰好显示提示推导稳定业务语义。

## 结论与处置

- 修正 Windows/macOS 已有 Image.list 的缺参及不完整页误作完整清单问题，不新增公开
  Domain/Repository 成员；五端影响为 Windows/macOS 读取修正、Apple 共享包回归待验，
  Android 仅记录后续影响，不改代码。
- `tags` 为数组与 macOS 旧单 tag 模型存在表达缺口；多标签/任务状态模型必须单列兼容
  扩展审批，不能暗中只取首标签或默认 latest。
- 下载公开接口暂不实施。后续须提出请求/进度/结果/恢复模型的必要性、迁移与回滚，
  获批准后再实现；真实下载及终态/异常证据仍需专用可丢弃目标的单独授权。
- 本轮未执行下载、删除或容器控制；官方刷新自然产生初始化/用户设置等请求，不声称
  网页加载本身绝无副作用。未提取这些非目标载荷。
- 观察完成已关闭 Network/Debugger 监听、清空脚本和原始请求/响应变量；无 HAR、截图
  或临时响应落盘。保留用户原标签，不更改信任或登录状态。

## 2026-09-20 静态任务分支复核与实施边界

只读此前已加载的同版本 MainVue.js（沿用 2026-09-19 待归属环境信息），未产生 NAS
请求。官方按 pull_start 回执 task_id 绑定 pull_status；定时 5 秒，立即首次读取。
状态请求成功且 finished 为真时，标签选择路径结束等待并返回 repository:tag；请求
失败时注销轮询。全局列表另计算 current/total 百分比，不以下载字节量证明成功。
URL 导入路径只发启动请求就关闭窗口，不证明下载完成。Mac 当前文案确为“已开始”，
不是“已完成”；缺口是丢弃任务身份、没有进度/结果恢复，而非该文案误报完成。

按后续已批准的兼容扩展实现请求、任务结果和恢复模型；不改变历史 read-verified
边界。客户端只接受原生字符串或非负整数 task_id，并保持原类型回传；finished
采用严格原生布尔，current/total 仅在有限非负数且范围有效时展示。此为客户端的
严格解析范围，不声称实际字段类型已获得运行时验证。完成采用同一任务成功状态、
finished、回显仓库/标签绑定与完整镜像清单的所选标签可用四项证据；不因旧标签
存在、100% 或聚合任务列表为空就报完成。旧标签同 ID 可表示缓存命中，不推断内容
必定改变；界面用“任务已结束，镜像可用”，不宣称验证了远端最新内容或完整性。

无回执不能凭仓库名重绑全局任务；状态请求失败/消失保持待核查，不猜失败终态或
重发。关闭本地等待不等于取消 NAS 下载。未发现可靠取消契约，不发臆造取消接口。
不读 admin 聚合任务，不读取/传入 registry 凭据；认证仓库设置不在 Mac 当前搜索
下载基线范围。真实完成/失败、权限和弱网仍待用户专用目标验证。
