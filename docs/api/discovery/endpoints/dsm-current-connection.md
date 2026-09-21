# DSM 当前连接内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-system-observability` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 资源监控与连接管理 |
| 能力名称 | 当前连接列表与受保护的连接断开 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `high` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.CurrentConnection` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| 方法 / 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- |
| `list.start` / `limit` | `integer` | 是 | 有界分页 | `0` / `500` |
| `list.sort_by` / `sort_direction` | `string` | 是 | 按连接时间倒序 | `time` / `DESC` |
| `kick_connection.service_conn` | `objectArray` | 是 | 非网页连接目标，包含 `pid`、`type`、`who`、`from` | `<synthetic-service-connection>` |
| `kick_connection.http_conn` | `objectArray` | 是 | 网页连接目标，包含 `did`、`descr`、`who`、`from` | `<synthetic-http-connection>` |

网页连接只允许使用列表返回的非空 `did`；其他服务连接只允许使用非空 `pid`。目标必须
来自刚刚重新读取的列表，且 `can_be_kicked=true`。不得由显示文本、列表行号、用户名或
来源地址单独拼接写请求。

## 响应与错误

列表只保留 `pid`、`did`、`who`、`from`、`location`、`protocol`、`type`、`time`、
`descr`、`is_current_connected` 和 `can_be_kicked` 白名单字段。写响应的 `success=true`
只表示请求被接受；必须重新读取列表并确认同一设备或进程标识已经消失。

| 场景 | 错误语义 | 是否自动重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或标识缺失 | 不支持/目标不可确认 | 否 | 保留只读列表，关闭断开入口 |
| `can_be_kicked` 不为真 | 权限或受保护目标 | 否 | 不发送写请求 |
| 当前会话 | 可能使本应用掉线 | 否 | 使用更强确认，说明需重新登录 |
| 权限不足或会话失效 | 明确拒绝 | 否 | 提示使用具备权限的账号或重新登录 |
| 提交后目标消失 | 确认成功 | 不适用 | 更新连接列表 |
| 提交超时、断线或回读失败 | 结果未确认 | 否 | 重新连接并刷新列表后核对 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `read-verified`（仅列表） | v1 | `list` 字段已核对；`kick_connection` 仅有官方网页请求线索和源码/合成测试，本环境未执行写行为 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

列表证据不得提升断开操作的证据等级；连接断开保持“已实现、未实机验证”。

## 能力探测与降级

- 必须发现 `SYNO.Core.CurrentConnection` v1。
- 新 DSM build 在完成版本化写行为验证前，只能依据能力、列表显式许可和用户确认谨慎开放；无法取得完整目标字段时关闭。
- 列表失败仅影响连接页，不阻断文件、照片或其他 NAS 设置。
- 当前没有覆盖 DSM 会话与服务连接统一断开的公开 API。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository.loadConnections` / `disconnectConnection`。
- Android Adapter：`DsmRepository.disconnectConnectionResult` 已使用 `kick_connection`、完整目标元数据、同目标防重复和列表回读；旧 `disconnect(id)` 已删除。
- Windows Adapter：固定 v1 有界读取、完整目标断开核心与原生管理入口已接。
  使用 start=0、limit=500、sort_by=time、sort_direction=DESC；JSON 声明下排序字符串
  按业务 JSON 编码，外层仍为表单。根必须为 items 数组，条目和字段类型严格检查。
  总数/边界不足以证明完整目录时保留只读；缺少 DID/PID 或必要目标字段时不允许断开，
  重复原始标识的行可查看但不能操作。未知当前标志保留为未知并要求更强确认。
- Windows 断开先重读完整基线、明确管理员与 can_be_kicked，再只发送一次目标对象；
  旧 delete/id 及空回读占位已移除。明确接受后最多四次、间隔 500ms 只读核对，模糊
  提交单次核对；原始 DID/PID 仍在（即使分类或派生行 ID 改变）或相似条目缺少标识，
  都保留未知。未确认目标跨 Repository 重建可恢复，不接受新请求 ID 重放。
  默认 JSON 不导出 DID/PID，字符串化不输出连接内容，最终结果缓存释放原始目标。
  NAS 摘要和旧工作区共用严格读取，不把失败当空列表；生产断开行为门关闭。
- Windows 原生界面支持账号/来源/服务本地搜索、目标确认、当前或未知当前会话的
  额外确认、关闭取消与迟到结果隔离。确认复选框可按任意顺序勾选，切换目标或搜索
  会撤销确认，执行前重新同步原生控件。部分目录、缺失身份、歧义或挂起目标只读。
  恢复保留可读目标说明，但不展示 DID/PID；身份摘要同时覆盖关联原始标识，分类
  改变但仍共享未确认目标时不能绕过阻止。恢复只查状态，不重发断开。
- Mac 同类修正：严格 items 根、行和字段，显示标识改为原始目标的摘要而非时间/行号，
  不包含原始设备标识；重复目标失败，不再凭用户名推断当前连接。所有网页连接都给出
  可能导致本应用掉线的确认提示。发送前重读完整目标，必需元数据不补空值；回读必须
  是当次有效加载且核对原始标识，不使用旧缓存或派生 ID 变化报告成功。未确认错误
  不建议立即重试。新增 Swift 回归未在 Windows 执行，仍需目标平台验证。
- 脱敏 Fixture：尚无独立请求 Fixture；`ConnectionDisconnectMutationTest` 使用语义合成目标覆盖网页/服务参数、保护拒绝、权限拒绝、模糊提交回读和同目标防重复。
- 产品兼容矩阵：`docs/progress/PLATFORM_MATRIX.md` 的 NAS 设置与套件/任务/日志/连接条目。

## 安全与副作用

- 连接数据可能包含账号、来源地址、位置、设备和进程标识，不持久化、不遥测、不写日志。
- 断开当前会话会让应用失去连接；其他服务连接可能中断文件传输或后台任务。
- 同一设备/进程目标必须防重复；提交异常只回读，不自动重放。
- 写后只比较内存中的原始目标标识；诊断标签不得包含账号、地址、`did` 或 `pid`。

## 未验证事项

- 管理员/普通账号、当前会话、HTTP/HTTPS 与其他服务连接的真实权限及错误码未验证。
- QuickConnect 中继、目标自然结束、列表延迟和写后断线行为未验证。
- 当前没有专用测试目标授权，因此未通过浏览器或客户端触发真实连接断开。
- Windows 原生管理只有源码和合成证据。大于有界读取范围、
  原始标识缺失/复用、当前会话断开后重登等情况仍需专用 NAS 验证；无法证明目标
  消失时继续保留未知，不提供强制重放入口。Apple 移动端需评估共享解析变更，
  Android 本波未改源码，五端真实兼容结论均不提升。
