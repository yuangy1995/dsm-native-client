# Container 生命周期契约只读核查

按环境模板建立；先核查官方静态线索，不触发容器启停、重启或删除。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不建立 current 基线 |
| 匿名设备别名 | 未确认，不按页面名称或版本推断 lab-a |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-09-19 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12，本轮官方 System.info 的 firmware_ver |
| 设备架构类别 | 未验证 |
| 连接方式 | 用户登录的 Chrome 官方 DSM，经 QuickConnect；直连/中继未验证 |
| 证书类别 | 未验证 |
| 账号权限类别 | 管理员，官方当前页面 Session.is_admin 原生布尔为 true |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| container-manager | Container Manager | 24.0.2-1535 | 官方页面正常打开 | 当前官方 Package.list v2 的版本字段 |

## 证据来源

- `endpoints/container-manager-internal.md` 现有记录未固定容器写参数。
- macOS `DsmServiceManagementRepository.swift` 以 action.rawValue/delete 与单 id 调用；仅源码线索，不是官方契约证据。
- 本轮只读官方已加载页面、自然网络请求及静态资源，不导出原始 HAR 或保存原始响应。

## 发现范围

- 目标：固定容器启动、停止、重启、删除的参数、回执与可用回读边界。
- 不执行：任何 NAS 写操作，不读取环境变量、挂载路径或日志正文。
- 限制：重启前后均 running 不足以证明重启已完成，不猜测完成语义。

## 安全检查

- 不读取或保存凭据、主机、账号、真实容器名称/标识及其他用户数据。
- 仅保留接口结构和必要版本；不把客户端源码或静态线索提升为行为验证。

## 结论

- 最初 Chrome 为登录页，未读取凭据或尝试登录；用户随后手动登录并明确允许继续核查。
- 官方 `ContainerManager/MainVue.js` 的以下写参数已静态确认，没有发出写请求：

| API v1 / 方法 | 静态参数 | 边界 |
| --- | --- | --- |
| Container.start / stop / restart | `name:string` | 不是 `id`；必须用新鲜清单把用户选择 ID 绑定到名称 |
| Container.signal | `name:string, signal:9` | 官方强制停止线索，不等于用户已授权执行 |
| Container.delete | `name:string, force:false, preserve_profile:false` | 普通删除；重置为 preserve_profile:true，二者不可混用 |
| Image.delete 单标签 | `images:[{repository:string,tags:[string]}]` | 仓库/标签级，不是单 id |
| Image.delete 批量 | `images:[{repository:string,tags:[string]} 或 {identity:string}]` | 官方把同仓库标签合组；裸标识变成 identity |

- 官方自然 `Container.list` 请求已观察并成功读取：POST `/webapi/entry.cgi`，v1，
  `offset=0,limit=-1,type="all"`，其中 type 为 JSON 字符串编码。响应 containers 数组：
  id/name/image/status 为字符串，State 为对象；仅核查必要字段类型，不保存实际目标。
- State.Running/Paused/Restarting 为布尔，State.ExitCode 为数字，State.Status、
  State.StartedAt/FinishedAt 为字符串；后两者符合 ISO 日期开头。启动时间可作为后续
  重启核查候选，尚未触发重启，不宣称已经证明时间随重启变化或其他状态组合有效。
- Image.pull_start / pull_status 的任务绑定在静态代码中再次出现，但真实完成/失败/
  取消语义仍未验证，沿用 2026-09-17 发现限制，不从本轮清单成功推导拉取完成。
- macOS 当前 controlContainers/deleteContainers/deleteContainersResult 发送单 id，
  与官方静态 name 参数不符；需要修正并补回归。Windows 不得复制该错误。
- 只把上述写方法记为 static，Container.list 字段类型记 read-verified（待设备归属）；
  未提升任何既有 lab-a verification。未采集环境变量、挂载路径、日志正文或凭据。
- 核查后关闭临时打开的套件中心，停止网络观察并清除响应引用；保留用户浏览器与
  Container Manager 页面，无原始响应、HAR、脚本副本或截图写入文件系统。

## 2026-09-20 静态归属限制补充

对同一已加载官方脚本做只读静态分析，没有新增网络请求或写操作。容器 startable/
stopable/deletable 都要求 !is_package；restartable 复用 stopable。该 is_package
不仅取容器 summary.is_package，还包含所属项目的 is_package。项目归属通过
Labels[com.docker.compose.project] 与 Project.list 中 name 匹配；项目列表为空或
没有匹配名称则没有托管项目，项目 is_package 缺省 false，错误类型不当作 false。
Windows/macOS 写入预检必须同时核对容器及项目托管状态，不能只看容器行的标记。
这仍为 static 限制，不代表托管实例上的拒绝行为已经执行验证；没有读取真实标签值。

## 2026-09-20 镜像删除静态范围补充

继续只读此前已加载的同一 MainVue.js，没有新请求或真实删除。官方 Image.list 的
每项 tags 数组按标签展开；同一镜像 ID 可对应多个仓库/标签，不可用单 ID 冒充标签
身份。`<none>` 标签的名称附带原始 ID，批量删除走 identity；普通标签按 repository
合组并传 tags 数组。官方在确认后检查镜像关联的所有容器（不只运行中），有占用则
拒绝删除。关联读取 Container.list 的 image、Image、ImageID；裸 sha256 和摘要引用
使用 ImageID 对应镜像，普通名称按仓库/标签归一，省略标签默认为 latest，docker.io
与 index.docker.io 前缀按官方规则去除。不能从这些静态映射推断不存在并发占用。

Windows 后续按标签绑定用户确认，提交前回读完整镜像及容器清单，保留原始 ID，
占用/字段不明不提交，回读必须验证相应标签消失；删除单标签后镜像 ID 仍存在不应
误报失败。裸 identity 删除还需原 ID 消失。权限由 NAS 裁决，未知结果不重放。
这里仍只有 static 证据；不新增或提升任何环境的行为验证等级。
