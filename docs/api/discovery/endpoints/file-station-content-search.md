# File Station 文件内容搜索

## 标识、来源与版本

端点组 `file-station-content-search`，组件 file-station，internal / read / low。来源为[2026-10-02 官方网页观察](../environments/2026-10-02-file-station-live-observation.md)：DSM 7.2.1-69057 Update 12，File Station 1.4.1-1559；匿名设备待归属，不挂靠既有 lab-a。

官方前端静态条件 `supportfileindex` 决定内容搜索复选框，当前网页实际显示。官方高级搜索产生的 POST `entry.cgi` 已只读核对，Search/start v2 返回 HTTP 200、业务成功、任务编号与原生布尔 `has_not_index_share=true`。只有请求形态和未索引提示达到 read-verified；合成无命中查询不能证明真实文档正文召回。

## 请求与响应

- `SYNO.FileStation.Search/start v2`：保留公开高级条件，增加 `search_content: true`、`search_type: "advance"`。pattern 是用户的内容关键词；不下载文件替代索引。
- 返回 `taskid: string`、`has_not_index_share: bool`。true 表示部分位置未建索引，不等于读取失败，也不代表所有位置未索引。
- `list/stop/clean v2` 沿用公开契约，完整分页；取消/异常只停止和清理本次任务，不能操作其他任务。
- 使用绑定的 DSM 会话及已发现相对路径、编码方式；所有搜索词、目录、任务编号仅留当前会话，不日志化。

## 能力、失败与客户端

需要 Search v2。正文请求若未返回索引状态则明确不可用并清理，不回退为名称结果。权限/读取错误不得当零命中；普通名称搜索不受影响。未知 DSM 版本只尝试可失败的只读搜索，不据此开放任何写能力。

Apple 在 FileSearchRequest 中增加默认 false 的 searchesContents；searchWithReport 返回结果与索引覆盖状态，旧 search 签名复用同一实现。macOS 内容结果不再按文件名二次剔除，名称正则与正文搜索分别使用。合成测试位于 FileStationParityTests 与 FileStationSearchWorkflowTests；真实正文命中、普通账号/管理员和多位置覆盖仍为 PENDING_USER_VALIDATION。

五端：macOS 实现；iPhone/iPad 只编译共享增量，移动入口另行评估；Android/Windows 只记录契约影响。本次没有改变其他四端功能。
