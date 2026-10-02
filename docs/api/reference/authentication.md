# 认证、会话与连接

分类：`SYNO.API.Info`、`SYNO.API.Auth` 为官方接口；QuickConnect 解析与桌面权限摘要属于内部适配。先遵循[通用标准](common.md)。

## 操作与原始字段

| 用户结果 / 领域入口 | API、方法与版本 | 请求 | 原始响应 / 领域结果 |
| --- | --- | --- | --- |
| 发现能力：`AuthRepository.discover` | `SYNO.API.Info` v1 `query` | `query:String`；无会话 | API 名称 → `path/minVersion/maxVersion/requestFormat`；映射 `CapabilitySet` |
| 登录：`login` | `SYNO.API.Auth.login`，已支持区间 3…6 与 NAS 取交集 | `account:String`、`passwd:String`、`session="FileStation"`、`format="sid"`；v6 加 `enable_syno_token="yes"`；非空 OTP 加 `otp_code` | `sid:String` 必须非空；可选 `synotoken/did`；`is_portal_port` 按当前解析规则映射 `AuthSession` |
| 退出：`logout` | `SYNO.API.Auth.logout`，同会话能力版本 | `session="FileStation"`，会话按通用标准发送 | 远端失败也清除本机该 profile 的会话；失败仍返回调用方 |
| 恢复本机会话：`restoreSession` | 无独立 NAS API | profile ID | 只恢复符合当前传输版本的安全存储记录；后续请求仍可能要求重新认证 |
| 获取可用模块 | `SYNO.Core.Desktop.Initdata` v1 `get_user_service`，内部 | GET，`launch_app="null"`；会话仅请求头 | 解析当前账号的套件使用权，未知不作允许；管理员身份不代替具体模块授权 |

登录不得自动重试 OTP，也不得把认证失败转成保存了错误凭据的“离线成功”。密码是否记住、是否自动登录是两个用户选择；OTP 仅在内存。

## QuickConnect

`DsmQuickConnectResolver` 先解析直连候选，失败后才请求中继。控制入口使用 `Serv.php` 的 `get_server_info` / `request_tunnel`，这些不是第三方公开稳定 API。

- 控制请求不携带 NAS 登录凭据、文件内容或会话。
- 候选主机、端口、HTTPS 和域名按既有适配器规则校验；使用前核对 NAS 身份。
- 中继必须通过系统证书信任，不以自签名确认绕过。
- 失败允许输入实际 NAS 地址；解析结果不覆盖用户保存的 QuickConnect ID。
- 详细命令字段、域名限制和版本证据只维护于[中继控制记录](../discovery/endpoints/quickconnect-relay-control.md)。

## 跨端不变量

profile、账号、会话、证书及任务上下文不可串用。登录成功后切换 profile 不能让迟到请求写入新的工作区。恢复会话不等于登录永久有效；退出、撤销权限、证书变化均须阻断旧上下文。

macOS 主应用使用受保护的本地存储；File Provider 仅在用户启用挂载后获得必要会话，密码不进入共享会话存储。其他端使用自身安全存储和生命周期，不照搬 Keychain group 或目录结构。

## 实现与验证入口

- [认证服务](../../../apple/Packages/DsmNetwork/Sources/DsmAuthenticationService.swift)、[认证 Repository](../../../apple/Packages/DsmNetwork/Sources/DsmAuthRepository.swift)、[领域模型](../../../apple/Packages/DsmCore/Sources/Authentication.swift)。
- [能力发现](../../../apple/Packages/DsmNetwork/Sources/DsmCapabilityDiscovery.swift)、[QuickConnect](../../../apple/Packages/DsmNetwork/Sources/DsmQuickConnectResolver.swift)、[桌面权限解析](../../../apple/Packages/DsmNetwork/Sources/DsmDesktopAppPrivileges.swift)。
- [权限摘要证据](../discovery/endpoints/dsm-desktop-app-privileges.md)、[网络与认证测试目录](../../../apple/Packages/DsmNetwork/Tests/)、[macOS 测试目录](../../../apple/Apps/DsmMac/Tests/)。

首次移植至少验证：OTP 错误、过期会话、不同 NAS 同名账号、模块无权限、证书变更、中继身份错误、取消后迟到结果和退出清理。源码/合成通过不能替代目标端安全存储与真实 NAS 验收。
