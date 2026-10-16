# Download Station 2 内部降级接口

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `download-station2-fallback` |
| 项目组件标识 | `download-station` |
| 所属范围 | Download Station |
| 能力名称 | 官方接口不足时的任务、统计、位置和 RSS 降级 |
| 分类 | `internal` |
| 操作性质 | `mixed` |
| 风险等级 | `high` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.DownloadStation2.Task`、`SYNO.DownloadStation2.Task.Statistic`、`SYNO.DownloadStation2.Settings.Location`、`SYNO.DownloadStation2.RSS.Feed` |
| 路径 | 由 `SYNO.API.Info` 在运行时返回，不固定拼接 |
| HTTP 方法 | `POST` |
| API 版本 | `Task` 为客户端范围 v1-v2；其余三个 API 为客户端范围 v1 |
| 鉴权机制 | DSM 会话 Cookie 与可选安全请求头；值不得进入 URL、日志或诊断导出 |
| 内容类型 | 由能力发现与当前 DSM 客户端适配器决定 |

当前记录只固化已有资料明确列出的方法，不补写尚无证据的参数：

| API | 已记录方法 | 用途与边界 |
| --- | --- | --- |
| `SYNO.DownloadStation2.Task` | `list`、`get`、`create` 以及动态动作方法 | 任务列表、详情、创建和控制；创建与控制没有形成真实目标行为验证结论 |
| `SYNO.DownloadStation2.Task.Statistic` | `get` | 速率统计读取 |
| `SYNO.DownloadStation2.Settings.Location` | `get` | 下载位置读取 |
| `SYNO.DownloadStation2.RSS.Feed` | 当前稳定证据未固化方法与参数 | 仅保留 v1 能力登记，不根据公开 RSS API 推断内部契约 |

既有静态目录还记录了 `Task.List`、`Task.List.Polling` 和 BT Tracker/Peer/File，但它们未进入本端点组的稳定兼容能力表，因此不属于本记录的发布契约。

## 响应与错误

当前只依赖 DSM 响应的稳定外层：

```json
{
  "success": true,
  "data": {}
}
```

- 任务、统计、位置和 RSS 的内部字段结构不得从公开 `SYNO.DownloadStation.*` 响应模型推断；两套模型必须隔离。
- 能力未发现、版本不覆盖或字段无法解析时，关闭对应增强能力，不阻断可由公开 API 完成的主流程。
- 登录失效、证书变化和权限错误应保留其原始语义，不得降级为空列表或零速率。
- 写请求提交后断线、超时或取消时结果未知，不自动重放；只有回读最终状态后才能报告完成。

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | `Task` 客户端范围 v1-v2；`Task.Statistic`、`Settings.Location`、`RSS.Feed` 客户端范围 v1 | `degraded`；Download Station `4.1.2-5012`，文件上传和设置写入尚未在真实目标执行 | 2026-07-27 | `docs/api/discovery/environments/INDEX.md`、`docs/compatibility/DSM_COMPATIBILITY_MATRIX.md` |

`observed` 只表示当前证据中观察到了接口或请求形态，不等同于读取或写入已经通过行为验证。

## 能力探测与降级

- 默认优先使用公开 `SYNO.DownloadStation.*`。
- 只有运行时能力发现明确返回目标 `DownloadStation2` API，且公开 API 缺少必要能力时，才启用相应内部降级能力。
- 内部 API 缺失或不兼容时关闭对应增强能力，不使用猜测路径、版本、参数或公开 API 响应模型替代。
- 内部降级必须有明确的请求契约和实际接口能力，不按DSM或Download Station精确版本禁用。
- 公开接口可以满足的任务、统计和 RSS 能力继续走公开适配器。

## 安全与副作用

- 下载地址、磁力链接、任务名称、目标目录、Tracker 和 RSS 内容可能包含隐私，不得写入日志、诊断导出或文档。
- `Task.create` 与动态动作方法可能创建、暂停、恢复或删除任务；未形成行为验证前不得作为兼容写能力开放。
- 设置写入和文件上传尚未在真实目标执行，不得由读取证据推断其方法、参数或成功语义。
- 后续开放写能力时必须具备确认、权限检查、防重复提交和写后回读；结果未知时禁止自动重试。

## 未验证事项

- 四个稳定登记 API 的完整参数、响应 Schema、权限与错误码。
- `SYNO.DownloadStation2.RSS.Feed` 的方法与参数。
- 文件上传、设置写入、任务创建和动态动作在真实专用目标上的行为。
- 不同 DSM build、Download Station 版本、账号权限与连接方式下的兼容性。
