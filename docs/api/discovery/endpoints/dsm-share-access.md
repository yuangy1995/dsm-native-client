# DSM 共享文件夹访问权限契约

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-share-access` |
| 私有兼容索引条目标识 | `dsm-share-permission-matrix` |
| 项目组件标识 | `file-station` / `dsm-core` |
| 所属范围 | 当前账号共享文件夹访问、管理员共享权限矩阵 |
| 能力名称 | 当前账号有效访问读取；管理员权限矩阵候选 |
| 分类 | 公开读取 / 内部候选 |
| 操作性质 | `read` |
| 风险等级 | `medium` |

## 已实现的公开读取契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.FileStation.List` |
| 方法 | `list_share` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | 客户端选择能力发现范围内的版本，当前测试使用 v2 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

客户端按 `offset`、`limit` 分页读取，并请求 File Station 的附加权限字段。页面只显示当前
登录账号可见的本地共享文件夹，排除回收站路径和 CIFS/NFS 等远程挂载。相同运行时条目
按稳定 ID 去重，权限解释如下：

| 返回字段 | 客户端语义 |
| --- | --- |
| `adv_right.write=true` | 可读取和修改 |
| `adv_right.read=true` 且不可写 | 仅可读取 |
| `adv_right.delete=true` | 另行显示可删除 |
| 权限字段缺失或无法解释 | 权限未知，不推断为拒绝访问 |

`list_share` 返回的是当前账号可见集合。某个共享文件夹没有出现在结果中，既不能证明它
存在，也不能区分隐藏、无权限、套件不可用或其他服务端策略；因此界面明确标注这不是
完整的管理员权限矩阵。

## 尚未实现的内部候选

静态 API 目录仅发现 `SYNO.Core.Share.Permission.list_by_user` 方法名。目前没有可信的
版本、参数、响应结构、权限要求或失败语义证据，客户端不调用该接口，也不在能力探测中
声明支持。

共享文件夹创建、修改、删除、加密、WORM、配额、移动和权限写入继续保持关闭。增加任何
写入口前必须取得并版本化记录：

1. `SYNO.Core.Share.validate_set` 或等价完整预检；
2. 用户与群组权限的复合提交参数及继承/拒绝优先级；
3. 加密、WORM、配额与权限之间的约束；
4. 移动任务 ID、轮询、取消和最终状态；
5. 权限检查、确认、稳定目标标识、防重复、写后回读及部分成功语义。

## 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | 公开 `list_share` 契约已由既有 File Station 路径和合成响应覆盖；本批未读取或修改真实共享权限 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 仅发现内部 `list_by_user` 方法名，管理员矩阵保持关闭 | 2026-07-31 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

合成响应与源码测试只能证明客户端分页、解析、去重、远程挂载过滤和降级行为，不能把
当前环境的管理员权限读取或写入提升为 `read-verified` / `behavior-verified`。

## 能力探测与降级

- 公开视图仅要求运行时发现 `SYNO.FileStation.List`；能力缺失、无权限或 File Station
  不可用时，页面独立显示错误和重试，不阻断其他 NAS 设置。
- 空结果只表示当前账号没有收到可显示的共享文件夹，不推断 NAS 没有共享文件夹。
- 权限位缺失时显示“暂时无法判断”，不把默认值或路径可见性冒充完整 ACL。
- 内部 `SYNO.Core.Share.Permission` 在取得版本化契约前保持禁用；不得根据方法名猜测
  参数。
- 新 DSM build 或 File Station 版本必须重新验证分页、附加字段和权限解释。

## 客户端与测试

- 共享领域：`NasShareAccessDirectory`、`NasShareAccessEntry`。
- 公开适配：`FileStationShareAccessRepository`，复用 `FileRepository.listShares`。
- macOS：NAS 设置增加“共享访问”只读页面，覆盖加载、空内容、错误、正常和权限未知
  状态；权限以文字和图标同时表达，并提供 VoiceOver 行描述。
- iPhone、iPad、Android 与 Windows：尚未接入该页面。
- 自动化测试覆盖分页、稳定 ID 去重、远程挂载过滤、权限映射、缺少 File Station 时的
  明确降级，以及 Model 加载。

## 安全与隐私

- 页面不显示物理路径、账号 SID、群组明细或内部权限位原文。
- 测试只使用合成共享名、保留地址与脱敏会话占位符。
- 不记录或提交真实共享名、路径、账号、权限响应、Cookie、SID 或 SynoToken。
- 本批没有权限写入、副作用操作或管理员权限提升。

## 未验证事项

- 当前 DSM build 下管理员、普通账号、隐藏共享、只读共享、回收站差异和 QuickConnect
  中继的真实结果尚未逐项验收。
- 不同 DSM/File Station 版本是否始终返回相同 `adv_right` 字段尚未验证。
- 内部管理员矩阵的版本、参数、响应、继承、显式拒绝和权限要求均未验证。
- 五端 UI 与跨平台契约尚未全部迁移。

## 2026-10-05 移动 M6a1 接入

iPhone/iPad M6a1 接入既有 FileStationShareAccessRepository 的分页与权限摘要。实际 UI 暴露 Apple listShares 缺少权限时默认可读、误显示只读的问题，已修正：共享根缺少权限保持未知，普通目录原行为保留；没有新增 NAS 请求、权限或存储字段。该共享修正同时影响 macOS，执行共享与桌面回归；Windows/Android 仅记录语义参考，不改代码。当前环境命令与两端页面验证集中在[移动主计划](../../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m6a1-五项读取与筛选)及其验证历史；真实 NAS 证据不提升。
