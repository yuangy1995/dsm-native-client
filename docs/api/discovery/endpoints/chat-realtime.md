# Chat 实时事件通道

稳定端点组：`chat-realtime`。内部、只读提示通道，业务消息始终通过既有 Chat API 回读。
NAS 专属路径/认证证据来自已有环境基线和 Apple Adapter；通用协议细节参考
[Engine.IO 官方协议](https://socket.io/docs/v4/engine-io-protocol/)及
[Socket.IO 官方协议](https://socket.io/docs/v4/socket-io-protocol/)。
本记录新增 Windows 源码与合成证据，不新增真实 NAS/Chat Server 验证结论。

2026-09-17 刷新时序回归：连接前轮询和 Connected 后补读可能先后发生，不能把
第一个回调一律视为连接后的刷新。Windows 内部使用可注入的标准 TimeProvider，
生产仍默认系统时间和既有 5 秒/30 秒/250ms 间隔；测试以手动时间和请求屏障分别
验证两种顺序、连接后低频校准、断开后轮询和停止清理，不以 30ms 墙钟等待判断
没有回读。未修改网络协议、事件内容或安全策略。

## 请求与协议

| 项目 | Windows 实现 |
| --- | --- |
| 地址 | 当前 HTTPS 源站及既有基础路径下的 `sc/socket.io/`，WebSocket 使用 WSS。 |
| 方法 | 原生 WebSocket GET 升级；查询仅 `EIO=4` 或 `3`、`transport=websocket`。 |
| 认证 | 复用当前会话 Cookie 和令牌请求头；不得在 URL、事件对象、日志或遥测中出现秘密。 |
| 来源 | Origin 仅当前源站 authority；拒绝用户信息、额外查询/fragment 和异 profile 会话。 |
| TLS | 使用现有 HttpClient 和 WindowsCertificateTrustHandler，上下文继续绑定 profile；不新建证书回调、不绕过中继系统信任。 |
| 生命周期 | 订阅归属已连接工作区；离开页面或切换当前 NAS 保留独立订阅。关闭模块、断开该 NAS 或销毁工作区时结束订阅；可见范围只控制消息刷新和已读同步。 |

源码证据：`apple/Packages/DsmNetwork/Sources/DsmChatRealtimeClient.swift` 与测试；Windows
`DsmApiClient.ChatRealtime.cs`、`DsmChatRealtimeClient.cs`、`DsmRepository.ChatRealtime.cs`。
现有环境范围见 `contracts/private-api/compatibility.json` 的原 `chat-realtime` 条目，不覆盖
历史版本。当前适配记录覆盖 EIO 4/3，但各 NAS/代理版本的实际协商仍待用户验证。

Windows 系统 ClientWebSocket 的自定义 invoker 接收 WSS 请求。适配器核对完整预期地址后
将其转换为同源 HTTPS，再走既有 HttpClient；不是跨源跳转。保留 App 原来禁用自动重定向
的处理器配置。握手拒绝/重定向的合成测试验证一次请求且不跟随异源地址；成功 101 的双向
合成流覆盖原生握手、控制帧、事件及取消，不能替代真实 TLS 或代理兼容验收。

## 帧与错误语义

- 网络连接与 Engine.IO/默认 namespace 握手分别有 20 秒上限。只有有效 open 后的默认
  namespace ACK 才产生 Connected；更早的内容事件忽略。
- open 读取非空、最多 512 字符的临时连接标识，绝不传入 App。心跳读取毫秒字段，缺省
  25 秒间隔/20 秒超时；字段存在但非法、非正或超过每项 300 秒的客户端上限则连接失败。
- EIO 4 响应服务端 ping，并在 interval+timeout 内收不到 ping 时断开；EIO 3 按协议历史
  的客户端 ping 方向发送并等待 pong。仅控制帧可写，不发送聊天、已读或输入状态事件。
- 支持 WebSocket 分片及严格 UTF-8，单帧合计最多 1 MiB；复合文本帧按分隔符处理。内容
  帧只变为 ContentChanged，不解释或记录载荷。关闭、协议错误、超时与无效编码转为降级。
- 首先尝试 EIO 4，未连接时尝试 3；记住本订阅成功版本。重试按 1/2/4…30 秒退避，连接
  成功后重置；取消立即退出，不将认证或信任失败当作已连接。
- 事件枚举队列最多 8 项，仅存枚举；页面按 250 毫秒合并内容变化。事件到达已有回读期间
  时，先等待该回读再做一次新读取，不并发读、不丢掉晚于旧快照的变化提示。
- 连接正常时每 30 秒校准，不可用时保留每 5 秒轮询。枚举未实现、结束或抛错不阻断列表、
  手动刷新和收发；旧代次取消后的事件不能改变重启后的页面或另一个 NAS。


## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。

源码核对：`apple/Apps/DsmMac/Sources/ChatWorkspaceModel.swift` 的 `syncWorkspaceChat` 与 `windows/src/LanStash.App/Features/Chat/ChatWorkspaceSession.cs`。此生命周期说明不提升网络实机证据。
