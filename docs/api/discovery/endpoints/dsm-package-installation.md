# DSM 套件安装与升级内部 API 边界

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-package-installation` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 套件中心 |
| 能力名称 | 已安装套件升级提示；套件来源、安装与升级候选 |
| 分类 | `internal` |
| 操作性质 | 只读提示 / 写入候选 |
| 风险等级 | `high` |

## 已实现的只读边界

客户端继续使用 `SYNO.Core.Package.list` 读取已安装套件，并在 `additional` 中请求
`available_operation`。只有服务端明确返回 `upgrade` 时，领域模型才设置
`isUpgradeAvailable=true`。

该字段只表示 DSM 套件中心报告存在升级操作，不证明以下条件已经满足：

- 升级包来源可信、签名与校验通过；
- 当前型号、DSM build、套件版本和架构兼容；
- 依赖套件、磁盘空间、存储状态与服务停机条件满足；
- 当前账号具备安装权限；
- 升级可以立即执行或不需要重启。

因此 `canUpgrade` 继续固定为 `false`。macOS 只显示“DSM 中有可用更新”的非交互标签，
并提示用户前往 DSM 套件中心查看要求和安装。标签同时使用图标与文字，不依赖颜色表达
状态，也不会触发网络写请求。

## 尚未实现的内部候选

静态 API 目录包含：

| API | 方法 | 当前证据 |
| --- | --- | --- |
| `SYNO.Core.Package.Server` | `list` | 只有 API 与方法名 |
| `SYNO.Core.Package.Installation` | `install`、`status`、`get_queue`、`cancel` | 只有 API 与方法名 |

当前没有可信的版本、路径、请求格式、参数、响应结构、来源标识、任务 ID、队列状态、
取消语义、权限错误或最终版本回读证据。客户端不在能力发现中声明这些接口，也不调用
它们。

## 后续安装安全门槛

开放安装或升级前必须取得版本化契约并完成专用测试环境验证：

1. 套件来源、频道、包标识、目标版本、架构、校验和签名字段；
2. 依赖、冲突、空间、DSM 版本、型号、许可证和维护状态预检；
3. `install` 的最小参数与服务端幂等标识；
4. `get_queue` / `status` 的任务 ID、阶段、进度、失败与完成结构；
5. `cancel` 在下载、解包、迁移、启动等阶段的真实语义；
6. 安装期间服务中断、配置迁移、可能重启和失败回滚提示；
7. Repository 与 UI 全局/同套件防重复、提交前确认、提交后只查状态不重放；
8. 最终通过 `Package.list` 回读稳定套件 ID 和版本，只在版本确认后显示完成。

上传本地套件还需要文件大小、格式、签名、临时文件权限、上传取消和清理边界，不能复用
普通文件上传直接提交。

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | `Package.list` 与 `available_operation` 已进入只读解析；未读取或提交真实升级 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | `Package.Server` 与 `Package.Installation` 只有方法名证据，保持关闭 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成响应测试只证明 `upgrade` 标志被解释为只读提示、`canUpgrade` 仍为假以及模型拒绝写
请求；不能把安装或升级提升为 `behavior-verified`。

## 能力探测与降级

- `available_operation` 缺失、为空或不包含 `upgrade` 时不显示升级提示。
- 只读提示不要求发现 `Package.Server` 或 `Package.Installation`。
- 套件图标加载和启动/停止状态刷新必须保留只读升级标志。
- 防御性 `.upgrade` 调用返回不可用且不可重试，不进入 Repository。
- 新 DSM build 上可继续解析显式只读标志；安装写入口默认关闭。
- 该能力失败只影响套件页，不阻断文件、照片、消息或其他 NAS 设置。

## 客户端与测试

- Apple 领域：`NasPackage.isUpgradeAvailable` 与独立的 `canUpgrade`。
- Apple Adapter：`DsmNasAdministrationRepository.loadPackages()`。
- macOS：卡片和列表行显示非交互升级标签及 VoiceOver 提示。
- Android：套件列表只在服务端明确返回 `upgrade` 时显示非交互提示；iPhone 与 iPad 尚未迁移。
- Windows：严格套件读取保留明确 upgrade 标志，NAS 详情行使用双语非交互标签和
  辅助功能说明提示前往 DSM 套件中心，canUpgrade 固定为 false；不发现或调用安装接口。
- 自动化测试覆盖显式 `upgrade`、缺失标志、图标装配字段保留、模型拒绝升级和零写请求。

## 安全与隐私

- 不读取或保存第三方套件源、下载地址、许可证、账号或凭据。
- 不记录真实套件列表、版本、NAS 地址、Cookie、SID 或 SynoToken。
- 本批没有安装、升级、下载、上传、取消或服务重启副作用。

## 未验证事项

- 不同 DSM build、系统套件、第三方套件、手动安装套件与架构差异下
  `available_operation` 的真实形态尚未逐项验收。
- 可用版本号、更新说明、依赖、空间和重启要求没有稳定只读字段。
- 安装队列、取消、回滚和最终状态均未验证且保持关闭。
