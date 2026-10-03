# QuickConnect 控制面与区域转介

稳定端点组：`quickconnect-relay-control`。既有中继基线继续以兼容索引记录为准，本页记录五端登录的区域转介处理。

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
| Windows | 既有 sites 转介、信任范围、去重和请求上限及模拟 HTTP 回归作为参考；本轮未改源码、未重跑 Windows 测试 |
| macOS | 2026-10-03 已在共享 `apple/Packages/DsmNetwork/Sources/DsmQuickConnectResolver.swift` 接入既有 sites 语义；保留原生登录与中继流程，共享网络及 macOS 回归通过；真实区域连接待验 |
| iOS | 复用同一 Apple 解析器，属于已有核心登录能力；触控交互与前台取消不变，共享层自动化与通用模拟器构建通过，真机待验 |
| iPadOS | 与 iOS 范围一致，不新增桌面能力；共享层自动化与通用模拟器构建通过，真机待验 |
| Android | 2026-10-03 已修复 `android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/network/DsmQuickConnectResolver.kt`；沿用协程取消、既有登录与中继，增量编译及 16 项聚焦测试通过；真机待验 |

没有新增 endpoint、参数、凭据存储或业务写权限；补充既有响应的可选 sites 字段处理。未知目标域名仍不会被访问。

## 2026-10-03 修复边界与验证账本

- 修复前基线：Windows `DsmQuickConnectResolver.QueryServerInfoAsync` 与 `QuickConnectReferralTests`，以及上述 2026-09-16 只读观察；Apple、Android 原先固定全球入口循环未消费 sites。
- 用户结果：全球入口要求区域转介时继续查询；在线但无直连地址时进入既有中继流程。macOS、iPhone、iPad、Android 沿用各自登录交互，不新增控件或文案。
- 安全级别：认证前的高风险网络边界；请求不包含 NAS 凭据，固定官方 HTTPS 主机和路径，保留请求数量、响应大小、取消、系统信任及中继身份核对。
- 单一修改范围：本轮只修改 Apple/Android 解析器、对应网络回归及本端点/兼容索引/平台矩阵；Windows 源码、App UI、安全存储和其他审查项为非目标，`relay_dn` 不在范围内。
- 实施顺序：解析器共享区域查询 → 两端合成回归 → 独立差异与恶意输入复核 → Apple/macOS 回归、移动模拟器构建与 Android 聚焦测试 → 更新实际验证结果。
- 集成与只读对抗复核：核对 macOS `LoginViewModel`、移动 `MobileAppModel+Session` 和 Android `DsmConnectionResolver` 仍将无直连结果转入中继；两端回归覆盖官方多级转介、大小写去重、全球入口循环、8 入口上限、缺少 sites、网络失败回退、取消、非法域/URL/空 DNS 标签、非字符串转介及中继身份不匹配停止。控制请求字段与认证头断言确认没有新增凭据发送；未改 TLS 或身份核对策略。
- `PENDING_USER_VALIDATION`：需 macOS、iPhone/iPad 或 Android 客户端与受控 QuickConnect NAS；分别从日常网络和外部网络输入 ID 连接，覆盖全球入口直接成功、区域转介后直连和无直连后的中继。预期能到达登录/正常连接，取消不继续查询，证书或身份异常停止连接。只回传客户端/系统版本、网络类别、步骤和脱敏错误；不回传 ID、主机、账号、会话或原始响应。自动化不提升真实 NAS 证据等级。

### 本机验证（2026-10-03）

- `swift test --package-path apple --jobs 2 --filter 'DsmQuickConnectResolverTests|QuickConnectReferralTests|ConnectionFlowTests|DsmTransportSecurityTests'`：56 项 XCTest，1 项既有真实 QuickConnect 用例因未提供测试 ID 跳过，0 失败；包含新增的 12 项区域转介测试。
- `swift test --package-path apple --jobs 2`：2349 项 XCTest，163 项按既有性能/真实环境/合成 UI 条件跳过，0 失败；另 12 项 Swift Testing 通过。包含 macOS App 与 File Provider 共享层回归，不代表正式签名或真实挂载通过。
- `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug -jobs 2 CODE_SIGNING_ALLOWED=NO build`：iPhone/iPad 通用模拟器应用构建成功，覆盖 arm64 与 x86_64；本轮未运行移动设备上的 UI 测试。
- 使用本机现有 Android SDK，在 Android 目录执行 `./gradlew :app:testDebugUnitTest --tests '*DsmQuickConnect*' --offline --max-workers=2 --no-parallel`：增量编译成功，12 项新增转介测试与 4 项既有解析测试全部通过；未运行完整 Android JVM、Release/R8、仪器或 lint 门禁。
- `python3 tools/localization/check_localization.py`、`python3 tools/codex/check_documentation.py`、`python3 tools/codex/check_android_structure_debt.py`、`python3 tools/codex/generate_android_quality_baseline.py --check` 均通过。
- `python3 -m json.tool contracts/private-api/compatibility.json`、`python3 tools/contract-validation/validate_fixtures.py`、`python3 tools/request-contract/validate_contracts.py` 均通过：29 组脱敏样本、47 项私有 API 文档引用、158 个请求样本及 1 个写结果示例。没有新增真实响应样本。
