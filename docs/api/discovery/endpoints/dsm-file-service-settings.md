# DSM 文件服务设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-file-service-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板文件服务 |
| 能力名称 | SMB、NFS、FTP/FTPS、SFTP、局域网发现与 Time Machine |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

| API | 版本 | 读取方法 | 写入方法 | 写入参数 |
| --- | --- | --- | --- | --- |
| `SYNO.Core.FileServ.SMB` | v1-v3 | `get` | `set` | `enable_samba` |
| `SYNO.Core.FileServ.NFS` | v1-v3 | `get` | `set` | `enable_nfs` |
| `SYNO.Core.FileServ.FTP` | v1 | `get` | `set` | `enable_ftp`、`enable_ftps`、`portnum` |
| `SYNO.Core.FileServ.FTP.SFTP` | v1 | `get` | `set` | `enable`、`portnum` |
| `SYNO.Core.Web.DSM` | v2 | `get` | `set` | `enable_ssdp`、`enable_avahi` |
| `SYNO.Core.FileServ.ServiceDiscovery` | v1 | `get` | `set` | `enable_smb_time_machine` |

所有路径均通过 `SYNO.API.Info` 运行时发现，请求使用 `POST` 和表单编码。会话与令牌只
按客户端既有鉴权位置发送，不记录具体值。客户端将同一保存动作拆成六个稳定逻辑子操作；
同一 API 组内只提交一次请求，只有实际变化的 API 组会进入提交序列。

保存前必须完成：

- 读取当前全部可用设置并计算实际差异；
- 验证 FTP 与 SFTP 端口位于 1 到 65535；
- 启用中的 FTP/FTPS 与 SFTP 不得使用相同端口；
- 已知 SMB 为关闭时不得开启 Time Machine 共享；
- 一次性确认全部待提交子操作的 API 与所需版本，避免先写后发现后续能力缺失。

## 响应、错误与恢复

读取响应分别返回上述字段。写请求只接受 DSM 明确成功响应；提交开始后无论中途失败
还是全部请求已接受，都整体重新读取所有可用文件服务设置。

| 场景 | 结果语义 | 恢复方式 |
| --- | --- | --- |
| 输入或依赖校验失败 | 提交前确认失败 | 修正端口、SMB 或 Time Machine 设置 |
| 任一所需 API 或版本缺失 | 不支持 | 不发送任何写请求，隐藏或只读降级 |
| 权限不足 | 权限拒绝 | 使用具备系统服务管理权限的账号 |
| 前序子操作已生效、后续失败 | 部分成功 | 重新读取全部设置并逐项核对 |
| 提交断网、超时或响应无效 | 当前子操作结果未知 | 不自动重放，先重新读取 |
| 回读失败或提交后取消 | 已提交结果未确认 | 等待连接恢复后重新读取 |
| 同时再次保存 | 重复提交冲突 | 等待当前保存结束 |

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 读取结构、网页请求和能力范围已有记录；写入只完成合成请求、故障注入与模型测试，未执行真实行为验收 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成 Fixture 与源码测试只证明当前客户端序列化和恢复语义稳定，不将当前环境提升为
`behavior-verified`。

## 能力探测与降级

- 未发现任一文件服务 API 时，整个页面按不可用处理。
- 单个 API 缺失时，其字段保持 `nil`，界面不显示对应控件，也不提交猜测值。
- 新 DSM build 或未记录版本上的内部写入口默认保持关闭，直至完成版本化验证。
- 提交前读取失败不发送写请求；提交后读取失败返回未确认，不自动再次保存。
- 文件服务设置失败不阻断文件浏览、照片、消息或其他 NAS 设置。
- 当前项目未找到覆盖这些 DSM 控制面板设置的统一公开写 API。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- Android Adapter：`DsmRepository.fileServiceSettings` 与 `saveFileServiceSettingsResult`；六组能力在首个写请求前一次性预检，只提交实际变化组，提交开始后整体回读并按组统计确认、部分成功或未知结果。
- Windows：六组固定版本 get 已迁移，新增字段可用/失败位图及独立 FTPS 开关；单组
  失败不伪造关闭，认证失败与取消传播，无任一 API 时不可用。原生只读文件服务表单
  已接入服务设置菜单及基线绑定的六组保存核心：先完整预检、仅提交变化组，中途异常
  停止后续组并整体回读，同请求只核对、不重发。已有合成 HTTP 与表单校验/确认回归；
  生产行为门独立关闭，未执行真实写。FORM/JSON 的布尔/整数业务参数按 fixture 编码，
  不提交未知字段、代理字段或旧猜测聚合请求。
- iPhone 与 iPad：设置调用链尚未迁移。
- 脱敏 Fixture：
  - `contracts/request-fixtures/file-services/set-smb/synthetic-settings/request.json`
  - `contracts/request-fixtures/file-services/set-nfs/synthetic-settings/request.json`
  - `contracts/request-fixtures/file-services/set-ftp/synthetic-settings/request.json`
  - `contracts/request-fixtures/file-services/set-sftp/synthetic-settings/request.json`
  - `contracts/request-fixtures/file-services/set-web-discovery/synthetic-settings/request.json`
  - `contracts/request-fixtures/file-services/set-time-machine/synthetic-settings/request.json`
- 自动化测试覆盖六类请求确认成功、一次性能力预检、冲突端口、部分成功、断网后回读
  失败、全局重复提交、提交后取消和 macOS 用户反馈；Android
  `NasServiceSettingsMutationTest` 另覆盖六组固定参数/版本、只提交变化组、后续能力缺失
  零写请求、前序生效后断线的部分成功以及 Time Machine 依赖。

## 安全与副作用

- 开启服务会增加可连接入口，关闭服务会中断使用该协议的客户端。
- 不记录共享目录、账号、密码、主机、端口扫描结果、会话或完整 DSM 响应。
- Repository 与 macOS 模型共同阻止并发保存。
- 所有提交后异常均要求先回读，不允许自动重试写请求。
- 当前批次不改变共享权限、防火墙规则、路由器端口映射或 NAS 账号。

## 未验证事项

- 六类写操作在目标 DSM build、不同权限和活跃客户端连接下的真实副作用尚未验证。
- SMB 与 Time Machine、FTP/FTPS 与 SFTP 端口约束在不同 DSM build 上的服务端错误
  细节尚未收集。
- Android 调用链已迁移但尚未做设备及真实 DSM 写行为验收；Windows 已有读取/原生
  表单及六组安全写核心的源码与合成回归，生产行为门仍关闭；iPhone 与 iPad 设置调用链未迁移。
- Windows 实机读取为 `PENDING_USER_VALIDATION`：核对可用协议开关、端口、缺失能力
  与权限失败，不能将静态/合成通过提升为行为验证；不启停真实服务，不回传原始响应。
