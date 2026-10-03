# Container Manager 映像搜索与下载故障观察

按环境模板建立。开始只读，用户随后明确授权必要的 Chrome NAS 网页下载测试；仅选择未存在的官方小体积镜像固定版本，不运行容器，不替换现有标签，不删除用户数据。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 / 匿名设备 / 基线状态 | 待归属观察；未确认设备别名，不根据版本推断 lab-a，不建立 current 基线 |
| 替代旧基线 | none |
| 日期 | 2026-10-03 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12 |
| 设备架构类别 | 未验证 |
| 连接方式 | 已登录 Chrome 官方 DSM，QuickConnect；直连与中继未验证 |
| 证书类别 | 未验证 |
| 权限类别 | 管理员；当前官方 Session.is_admin=true |

## 相关套件

| 项目组件 | 套件 | 完整版本 | 状态 |
| --- | --- | --- | --- |
| container-manager | Container Manager | 24.0.2-1535 | 页面可打开，读取及下载启动可用 |

元数据来自本次官方 Session 白名单字段和 Package.list。只使用官方网页请求入口，未读取或记录会话凭据。

## 发现结果与证据等级

1. `Registry.search` **read-verified / failed**：固定公开关键词，v1 成功，v2 返回 103。成功数据是对象，含 `data` 数组、数值 `offset/limit/page_size/total`。元素含 `name/registry/description`、`star_count` 和三个布尔字段。官方 MainVue.js 也固定使用 search v1。Registry 整体声明支持 v2 不代表 search 支持 v2。
2. `Registry.tags` **read-verified**：v1，`repo`，本次为数组；用于从实际返回的标签中选择固定测试版本。最终 Image.list 使用 `offset=0,limit=-1,show_dsm=false`，响应 total 与数组长度一致，所选标签下载前不存在。
3. `Image.pull_start` **observed**：只发送一次 `repository/tag`，成功回执 `task_id` 为字符串。立即以原类型查询此 task_id，不重发启动，不借聚合任务按名称绑定。
4. `Image.pull_status` **read-verified**：运行中 data 含 `repository/tag/description` 字符串、原生布尔 `finished=false`、数值 `downloaded=0`。这次没有 current/total；客户端必须允许不定进度，不能因缺少百分比字段报错。
5. 下载失败 **failed（受控行为观察）**：同一任务随后返回 `success=false,error.code=1202`，没有可用错误正文。官方代码常量为 `WEBAPI_ERR_DOCKER_UNKOWN`。完整 Image.list 中所选标签仍不存在；任务聚合列表中原 task_id 已消失。没有足够证据把失败原因指定为 DNS、网络超时、证书、限流、权限或空间不足。
6. 较早读取既有任务先收到 1202，再收到 117/errors=508；未保存该任务标识、仓库或用户数据。后续的通用读取错误不能覆盖首次明确的 Docker 下载失败。本次受控任务只读到 1202，没有再次读取消失任务。
7. `Entry.Request.Polling.list` **read-verified**：v1，`task_id_prefix="SYNO_DOCKER_IMAGE_PULL",extra_group_tasks=["admin"]`，data.admin 为字符串数组。本次只用于诊断任务生命周期；不接入产品的跨账号任务恢复，也不把空列表当成下载成功。

## 实施与限制

- 搜索固定 v1，畸形成功响应不当作空结果；标签错误可直接重新加载。
- 已绑定任务遇到 1202 显示下载失败并保存终态；传输错误、暂时读取错误仍自动读取同一 task_id。无回执继续阻止重复提交，不能凭名称重绑。
- 完成仍要求同一 task_id 的 `finished=true`、仓库/标签匹配与完整映像清单可用三项证据。本轮没有成功下载，不能提升成功结束路径为行为验证。
- 关闭窗口只停止本地等待。未探测取消接口；测试未创建或运行容器，失败后没有新增测试镜像可清理。
- 共享 Apple 网络层受影响；macOS 界面修复；iPhone/iPad 做构建回归；Windows/Android 仅记录同类风险，不改代码、不声称通过。
- 尚待用户验证：NAS 恢复下载能力后的成功下载，关闭后重开、长时间弱网、权限撤销及普通账号。见 `docs/development/MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md`。

## 隐私与清理

不保存原始 HAR、响应、主机、账号、任务编号、用户镜像清单或日志正文；只记录结构、版本、错误码与合成回归。官方事件日志仅对测试镜像过滤并输出错误类别布尔值，未取得更具体失败原因。浏览器临时变量和调试控制台在核查结束后清理。
