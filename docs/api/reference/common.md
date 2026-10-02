# API 通用标准

适用于 macOS、iPhone、iPad、Android 和 Windows 的调用层；本页定义项目语义，不改变群晖协议。先读本页，再进入[功能目录](../README.md)。

## 分层与单一事实来源

原生 UI → 平台状态模型 → Repository → 请求/响应适配 → HTTPS/会话。跨端对齐输入、输出、权限和失败后的行为，不复制 SwiftUI/AppKit 或平台持久化格式。

| 事实 | 唯一维护位置 |
| --- | --- |
| 当前 Apple 请求编码 | [DsmRequest.swift](../../../apple/Packages/DsmNetwork/Sources/DsmRequest.swift) |
| HTTP/DSM 响应信封 | [DsmAPIClient.swift](../../../apple/Packages/DsmNetwork/Sources/DsmAPIClient.swift) |
| 能力名称和已支持区间 | [DsmCapabilityDiscovery.swift](../../../apple/Packages/DsmNetwork/Sources/DsmCapabilityDiscovery.swift) |
| 错误分类 | [DsmErrorMapper.swift](../../../apple/Packages/DsmNetwork/Sources/DsmErrorMapper.swift)、[错误契约目录](../../../contracts/error-codes/) |
| 写入结果 | [MutationResult.swift](../../../apple/Packages/DsmCore/Sources/MutationResult.swift)、[Schema](../../../contracts/schemas/mutation-result.schema.json) |
| 原始字段的精确样例 | [请求参数目录](requests.md)和其中的 JSON 链接 |
| 私有接口真实证据 | [发现记录](../discovery/README.md)和[兼容索引](../../../contracts/private-api/compatibility.json) |

## 地址、发现与版本

- NAS 业务使用 HTTPS。请求入口为已验证基础地址下的 `/webapi/<path>`；拒绝外部绝对地址、点目录、查询或片段混入 API path。
- 无凭据调用 `SYNO.API.Info` v1 `query`，参数 `query` 是所需 API 名称的逗号分隔串。先使用 `entry.cgi`；仅 HTTP 404/410 或 DSM 102/103 时回退 `query.cgi`，不因认证、TLS 或任意超时改入口。
- 返回值是以 API 名称为键的对象，记录 `path:String`、`minVersion:Int`、`maxVersion:Int`、`requestFormat:String`。路径必须规范化；范围无效时拒绝。
- 初始 `selectedVersion` 为 NAS 区间与客户端已支持区间交集的上界。**具体操作要求固定版本时，必须再次确认该版本位于能力区间，并发送该版本**；不能对所有操作直接使用 `maxVersion`。
- `requestFormat=JSON` 说明业务参数的值需要 JSON 编码，通常仍是表单 HTTP 请求，不等于整个正文改成 `application/json`。
- 缺少一个 API 只禁用依赖它的功能；不能把权限拒绝解释为空列表或伪造成功。

## 请求编码

默认 `POST`、`application/x-www-form-urlencoded; charset=utf-8`，固定控制字段为 `api`、`version`、`method`。值按 UTF-8 百分号编码，不手工拼接 JSON 引号。

| 业务类型 | FORM 值 | JSON 参数格式的值 |
| --- | --- | --- |
| 字符串 | 原字符串 | JSON 字符串，含引号和正确转义 |
| 整数、布尔 | 十进制、`true/false` | 相应 JSON 标量 |
| 字符串/整数数组 | JSON 数组文本 | JSON 数组文本 |
| 对象、对象数组 | JSON 文本 | JSON 文本 |

multipart、二进制下载、Range 和 WebSocket 由各功能适配器处理，不套用 JSON 响应解码。服务端返回 JSON 错误时不能把它当成下载文件保存。

## 会话与隐私

POST 业务请求按当前实现同时使用内存构造的 `Cookie: id=…` 和正文 `_sid`；两者来自同一会话。可用 SynoToken 时，发送正文 `SynoToken` 和请求头 `X-SYNO-TOKEN`。GET 只通过请求头认证，秘密不能进入 URL。

请求绑定 NAS/profile、会话和证书。重定向、媒体流、下载及控制台不能将凭据带到未授权源站；QuickConnect 中继强制系统证书信任。平台安全存储的具体形式见[安全基线](../../security/SECURITY_BASELINE.md)，不要照搬 macOS 的本地文件布局到其他端。

## 响应与错误

JSON 成功信封为 `success:true` 与 `data`；失败含 `success:false`、`error.code`。HTTP 成功不等于业务成功；批量请求和异步任务还要检查内层结果与最终状态。领域 Schema 描述适配后的模型，不能拿它直接解码 DSM 原始信封。

| 条件 | 当前公共分类 | 调用方行为 |
| --- | --- | --- |
| DSM 102/103、104 | `apiUnavailable`、`versionUnsupported` | 关闭对应能力，必要时重新发现；不循环换参数试探 |
| DSM 105；一般 HTTP 403 | `permissionDenied` | 显示权限限制；不自动换账号或升权 |
| DSM 106/107/119；HTTP 401 | `authenticationRequired` | 结束旧会话使用并引导重新登录 |
| DSM 109/110/111/117/118、HTTP 5xx | `serverBusy` | 读取可受控重试；写入先判断是否已提交 |
| DSM 150 | `networkUnavailable`，不可直接重试 | 核查网络或源地址变化 |
| 网络超时/中断 | `timeout` / `networkUnavailable` | 写请求可能已生效，先查询结果 |
| 解码、响应大小、请求构造错误 | `invalidResponse` | 保留失败；不要补空集合、零值或默认关闭 |

认证与 File Station 有单独错误上下文，例如 DSM 登录错误码 403/406 表示 OTP 要求，不能照搬一般 HTTP/DSM 权限分类。完整码表以 `DsmErrorMapper` 为准。`isRetryable` 只描述错误，不授权自动重发危险或结果未知的写请求。

## 写操作结果

写 API 可返回统一 `MutationResult` 或功能专用结果对象；各端必须保留同等状态，不强行压成成功/失败布尔值。

| 状态 | 意义 | 下一步 |
| --- | --- | --- |
| `confirmedSuccess` | 所需最终证据已满足 | 更新列表，可结束操作界面 |
| `confirmedFailure` / `permissionDenied` / `unsupported` | 明确失败或未获准 | 显示原因，按真实条件允许用户修正 |
| `submittedButUnverified` | 可能已提交，最终状态不明 | 使用原操作身份只读查看；禁止盲目重发 |
| `partialSuccess` | 部分已完成 | 保留逐项结果，只处理未完成目标 |
| `cancelledBeforeSubmission` | 未发送前取消 | 不宣称产生远端效果 |
| `cancellationRequestedAfterSubmission` | 已请求取消，最终效果未定 | 继续查明已完成部分，不自动回滚或重发 |

必须保存稳定目标、原始基线和操作身份，先检查权限与当前目标，再保护重复提交，最后按功能核对结果。普通按钮可以构成明确操作确认；具体危险后果才追加风险确认。异步任务已接受、任务已结束、实际业务成功是不同结论。

## 每个功能文档必须回答

功能文档统一给出：用户结果及领域入口、官方/内部分类、API/method/版本规则、请求字段/编码、原始响应到领域结果的映射、权限与副作用、失败及恢复、源码/快照/证据链接、目标平台范围。未知字段或方法明确标未验证；不得用另一个版本的结果填空。

维护私有接口时保留版本化证据；本目录只引用，不复制。跨端新增能力按[平台矩阵](../../progress/PLATFORM_MATRIX.md)和目标平台计划推进，禁止将 macOS 的已实现状态直接填到其他端。

## 跨端迁移与回归要求

新增或修改公开模型/Repository 签名必须单独评估五端影响、增量迁移和回滚并取得授权；文档归并不构成该授权。请求 fixture、领域 Schema、原始响应和运行结果各自承担不同证据，不能用一个合成样例推定所有 NAS 字段必需。

每个写操作至少验证提交前失败、提交且回读成功、提交后网络失败、回读失败、部分成功、提交后取消；同一操作身份重复请求不得产生第二次副作用。校验器必须拒绝真实秘密/环境数据、未知字段以及危险写的自动重试配置。

### SEC-002 认证位置例外

Apple 的 File Station GET/上传已把认证移出 URL；现有 `file-station.upload.synthetic-overwrite` 共享样例仍保留 URL 认证位置的历史约束。Android 等目标实现须单独核查，不能把 Apple 安全收敛表述为全端已完成，也不能直接改 fixture 来掩盖差异。迁移须同时更新目标实现/测试、共享 fixture、Apple/Windows 回归和五端矩阵；在此之前保留业务参数一致性与 Apple URL 无凭据断言。

静态资料仅有名称、缺少版本/路径/参数的接口保持零猜测请求。例如 Printer BonjourSharing 和 SecurityScan.Status 不因同名字段或其他组件的响应而建立可调用契约。后续证据仍走私有接口发现流程。
