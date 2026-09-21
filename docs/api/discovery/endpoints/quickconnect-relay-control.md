# QuickConnect 控制面与区域转介

稳定端点组：`quickconnect-relay-control`。既有中继基线继续以兼容索引记录为准，本页补充 Windows 登录故障的区域转介处理。

## 请求与响应

内部接口 `POST /Serv.php`，命令 `get_server_info`，协议请求版本 1，服务为既有 `mainapp_https`。请求不携带 NAS 登录凭据。成功响应包含 `errno=0` 与既有 `server`、`service`、`smartdns`、`env` 字段。

全球入口也可能返回非零 `errno` 和 `sites: string[]`。2026-09-16 只读观察为 `errno=4` / `suberrno=0`，并不表示 ID 不存在；继续查询白名单区域入口可获得在线结果。官方前端同样将 sites 加入待查询列表并去重。字段缺失时不猜测区域主机。

## 安全与失败语义

- 仅接受 DNS 标签合法、以 `.quickconnect.to` / `.quickconnect.cn` 结尾的主机，不允许 URI、端口、路径、凭据或相似域名。
- 固定 HTTPS 和 `/Serv.php`，全部控制请求沿用系统证书信任。总计最多 8 个唯一控制入口，受单次超时、取消和 1 MiB 响应限制。
- 成功在线响应没有直连候选时，保留 `QuickConnectDirectUnavailable` 给既有中继流程；不继续用其他区域的错误覆盖在线结果。
- 中继发现使用同一个转介查询流程；后续中继官方域名、证书、`ezid` 身份核对和登录前探测门禁不变。
- 未找到成功结果时保留既有错误处理；危险业务写入口没有变化。

## 证据与五端影响

[客户端环境记录](../environments/2026-09-16-quickconnect-client-observation.md)仅确认未认证控制面行为，不新增 DSM build 兼容结论。官方静态来源：[QuickConnect 客户端脚本](https://quickconnect.to/connect_lib.da3fae9c5d057ef58d3a.bundle.js)。

| 平台 | 影响与本轮处置 |
| --- | --- |
| Windows | 实现 sites 转介、信任范围、去重和请求上限；新增模拟 HTTP 回归 |
| macOS | 只读检查发现现有解析器也未处理 sites；用户已有成功连接不代表所有控制响应均覆盖。本轮不修改 |
| iOS | 使用共享 Apple 网络解析器，需另行补同类适配；本轮不修改 |
| iPadOS | 与 iOS 相同，本轮不修改 |
| Android | 记录同类控制面影响，本轮不修改源码 |

没有新增 endpoint、参数、凭据存储或业务写权限；补充既有响应的可选 sites 字段处理。未知目标域名仍不会被访问。
