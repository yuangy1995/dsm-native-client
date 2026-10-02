<!-- doc-role: release-readiness -->
<!-- last-reviewed: 2026-10-02 -->

# macOS 候选版本就绪与安全验收

> 更新日期：2026-10-02
> 结论：`PENDING_USER_VALIDATION`。项目已有共享层、模拟器与 macOS 临时签名构建证据；历史版本已有正式签名发布及部分用户反馈；新候选和未覆盖场景仍须独立验收。

本报告只汇总当前可重跑的自动化、构建和只读对抗复核。它不包含 Developer ID 凭据、
notarization 凭据、会话、设备标识、NAS 信息、真实路径或用户数据，也不把无签名构建或
模拟器结果表述为设备、Finder 或发布验证。

## 自动化证据的使用方式

共享层、macOS 主 App 与 iPhone/iPad 模拟器已有构建/回归记录，精确提交、命令、跳过项和包见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。每个新候选仍须运行受影响门禁；本次文档整理没有重新执行 App 构建，也不把历史证据标为当前包已验收。

## 只读对抗复核

| 边界 | 复核证据 | 结论 |
| --- | --- | --- |
| File Provider 与 App Group | `DesktopCloudDriveAvailability` 只有嵌入 Extension 与共享容器同时可用才开放；缺任一项即关闭入口。 | 无签名构建不会假装具备系统集成能力。 |
| 认证、会话与跨 NAS | `DesktopDriveSessionBridge` 以 profile 标识保存和清理最小必要会话；映射事务测试覆盖会话发布、回滚、恢复和最后映射清理。 | 未观察到跨 profile 合并会话或绕过证书确认的路径；真实 Keychain 行为仍待验收。 |
| 后台、取消与恢复 | `DesktopCloudDriveManager` 对每个映射保留离线任务所有权，取消后通过既有回滚与状态机处理；测试覆盖取消请求、固定范围回滚失败和重连失败。 | 代码级取消语义保持，不能推断 Finder 或系统网络传输已经停止。 |
| 危险写与结果确认 | NAS、文件、下载、容器和虚拟机路径继续通过能力、确认、权限、重复提交和回读结果建模；未确认结果不会被映射为成功。 | 未验证风险继续受实际能力、权限、确认与结果核对保护；具体开放策略以各功能当前授权和记录为准。 |
| 私有 API | 私有 API 记录要求新 DSM 或套件版本默认关闭内部写，并禁止在断线、超时或取消后自动重放。 | 本轮没有连接 DSM、读取真实响应或触发任何写请求。 |

这只是只读代码和测试复核；它不是安全审计、渗透测试或真实系统的行为验证。

## `PENDING_USER_VALIDATION` 清单

| 前置条件 | 用户操作 | 预期结果 | 允许回传的脱敏信息 |
| --- | --- | --- | --- |
| Developer ID Application 证书与候选包 | 按[桌面云盘发布与升级验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)生成正式签名候选包。 | 主 App 与 Extension 的签名身份一致。 | 成功/失败、macOS 大版本和架构类别、通俗错误摘要。 |
| 受控 notarization 凭据 | 对候选 DMG 完成公证、票据装订和 Gatekeeper 检查。 | 干净测试用户可安装并启动候选包。 | 用例 ID、成功/失败、错误类别；不得回传凭据、Team ID 全值或日志正文。 |
| 专用 Mac、专用 NAS 账号与可丢弃数据 | 按[正式签名验收执行矩阵](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)验证 Finder、File Provider、App Group、共享会话、取消、恢复、升级与回退。 | 映射创建、浏览、暂停、恢复和移除均收敛，危险写只在明确授权后回读确认。 | 用例 ID、最终状态、连接/证书/缓存卷类别、清理状态与脱敏失败摘要。 |
| iPhone 与 iPad 设备 | 分别验证登录、系统选择器、网络切换、VoiceOver、动态文字、键盘和宽屏交互。 | 对应设备上的移动核心与受限能力符合平台范围。 | 设备类别、系统大版本、用例 ID、成功/失败和可复现的脱敏步骤。 |

若出现凭据暴露、签名或 Extension 身份不一致、映射可能影响非测试数据、无法安全清理、
未知系统状态或危险写结果无法回读，立即停止相关验收并保持不发布。

## 新候选发布出口

历史已通过范围见验证记录；针对当前候选新增或尚未覆盖的签名、系统集成、真实 NAS、升级回退和清理场景：

- 不把尚未完成的新候选验收表述为通过；任何新发布仍需明确授权及对应发布门禁；
- 不把无签名构建、模拟器或合成测试升级为 `DEVICE_VERIFIED` 或 `RELEASE_READY`；
- 未验证内部写、File Provider 与真实系统集成继续保持关闭、只读或能力门保护；
- 使用[发布与手工验收历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)保存可复用的
  脱敏结论，不复制临时日志、测试数量或 CI 标识。

## 相关材料

- [macOS 桌面云盘发布与升级验收](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [macOS 桌面云盘正式签名验收执行矩阵](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)
- [验证等级](VERIFICATION_LEVELS_ZH.md)
- [平台功能矩阵](../progress/PLATFORM_MATRIX.md)

## 已实施的安全整改与兼容决策

| 编号 | macOS 证据路径 | 目标语义与安全级别 | 基线核验 | 本轮实现与自动化 | 验证等级 / 明确非目标 |
| --- | --- | --- | --- | --- | --- |
| DATA-001 | `apple/Packages/DsmNetwork/Sources/DsmFileRepository.swift`、`DsmTransport.swift`、`AtomicFilePromotion.swift` | 下载失败、取消或替换失败时，已存在的本地目标内容不得被修改；高（数据完整性） | 已确认：替换前会截断或删除目标文件。 | 已实施：下载、分片和最终目标均在同目录暂存；完成并同步落盘后仅以原子提升替换。替换失败时不触碰旧目标。`AtomicFilePromotionTests` 与 `DsmFileRepositoryTests` 覆盖替换失败和中断。 | 自动化已通过；掉电/文件系统崩溃窗口仍为 `PENDING_USER_VALIDATION`。 |
| SEC-001 | `apple/Packages/DsmNetwork/Sources/LocalFileSecureStore.swift` | 主密钥仅存应用私有 Keychain；Keychain 或迁移失败必须安全失败；高（凭据） | 已确认：`master.key` 位于应用容器，失败时使用可预测回退。 | 已实施：应用私有 Keychain 原子 load-or-create、无固定回退；旧 `master.key` 只作为一次性兼容迁移输入，密钥一致且删除旧副本后才可用。初始化和保存都会收紧既有安全目录/数据文件权限，密文损坏继续上抛。`LocalFileSecureStoreTests` 覆盖迁移、冲突、不可用、损坏和权限收紧。 | Keychain 访问控制与锁屏/重启行为仍为 `PENDING_USER_VALIDATION`。 |
| AUTH-001 | `apple/Packages/DsmNetwork/Sources/SharedKeychainSessionStore.swift` | 共享最小会话更新不能因新写入失败丢失旧会话；高（认证） | 已确认：保存流程为先删后加，迁移失败会被进程内标记抑制。 | 已实施：`SecItemUpdate` 优先、未找到才新增、并发重复项时重试更新；迁移在全部写入/删除完成后才标记，失败保留可重试资格。`SharedKeychainSessionStoreTests` 覆盖更新、失败、竞争与重试。 | Keychain 跨 App/Extension 实机互通仍为 `PENDING_USER_VALIDATION`。 |
| NET-001 | `apple/Packages/DsmNetwork/Sources/DsmCertificateTrust.swift`、`DsmTransport.swift` | TLS 失败只能归属产生该失败的 URLSession task；高（认证/证书） | 已确认：全局 `pendingFailure` 可被并发请求覆盖。 | 已实施：以 task identifier 保存、消费和清理 TLS 失败；数据、下载和 WebSocket 都按自身 task 读取。`DsmTransportSecurityTests` 覆盖两任务隔离。 | 真实证书挑战生命周期仍为 `PENDING_USER_VALIDATION`。 |
| SEC-002 | `DsmRequest.swift`、`DsmFileRepository.swift`、`DsmTransport.swift`、`MediaStreamRedirectPolicy.swift` | 会话秘密不出现在 URL；跨源重定向不得带认证信息；高（凭据） | 已确认：GET 与上传 URL 写入 `_sid`/Token 字段。 | 已实施：GET 与上传 URL 只保留业务字段，认证走 Cookie/请求头或既有 multipart 正文；同源 HTTPS 重定向剥离敏感查询，跨源、换端口或降级 HTTP 一律取消。统一 Redactor 覆盖敏感查询、认证 Header 和 `Location` 中的敏感查询，媒体预览使用同一语义。聚焦请求、文件和媒体测试覆盖。 | 旧 DSM 对 Header 认证的兼容性需真实 NAS 验证。 |
| NET-P2 | `apple/Packages/DsmNetwork/Sources/DsmTransport.swift`、`DsmQuickConnectResolver.swift` | 非下载响应有确定上限，并在无 `Content-Length` 时流式中止；中（资源耗尽） | 已确认：`data(for:)` 与上传响应无限累计。 | 已实施：一般传输默认 8 MiB 的声明长度预检与累计分块上限，QuickConnect 控制响应使用 1 MiB 流式累计上限；超限取消或立即终止本次读取并映射为安全错误。文件下载流不受该 JSON/控制响应上限影响。`DsmTransportSecurityTests` 与 `DsmQuickConnectResolverTests` 覆盖声明长度、分块和真实 `URLSession` 路径。 | 仅覆盖客户端接收边界，不改变下载文件大小能力。 |
| DATA-002 | `apple/Packages/DsmNetwork/Sources/DsmFileRepository.swift`、`DsmTransport.swift` | 分段下载和跨 NAS 分段读取只能拼接同一远端内容版本；任何 checkpoint、范围、总长、分段长度或校验器不一致时不得覆盖原有最终文件；高（数据完整性） | 已确认：`.part` 只按路径/大小区分，未绑定 ETag/Last-Modified；206 的 `Content-Range` 与实际长度未严格校验。 | 已实施：同目录 sidecar 以摘要身份、长度和强 ETag/标准 Last-Modified 绑定 checkpoint；恢复请求发送 `If-Range`；每个 206 严格验证起止、总长、实际分段长度与完整校验器连续性。缺失/损坏 sidecar、ETag 改变、416、错误范围或 If-Range 返回 200 都丢弃旧 checkpoint 并从零开始或只采用完整新正文。跨 NAS 流式复制复用相同 Range/If-Range/校验器门禁。`DsmFileRepositoryTests` 覆盖同路径同大小 ETag 改变、下载中变化、错误起始/总长、头范围正确但实体长度不符、200、416、sidecar 缺失/损坏、最终哈希不变和跨 NAS 两段读取。 | 自动化已通过；真实 DSM 的 Download API 是否始终返回强 ETag 或标准 Last-Modified 仍为 `PENDING_USER_VALIDATION`。无可用内容校验器时不会建立或续用断点。 |
| TLS-002 | `apple/Packages/DsmNetwork/Sources/DsmCertificateTrust.swift`、`DsmTransport.swift`、`DsmChatRealtimeClient.swift` | session 级 server-trust challenge 没有 task ID 时仍须在同一 session/origin 的在途任务中返回结构化错误；取消和跨 host 不得串扰；高（认证/证书） | 已确认：session 级回调传入 `nil`，原存储器直接忽略该失败。 | 已实施：保留 task 专属失败，并新增按 session 内**实际** host:port/generation 登记的失败集合；挑战发生时只标记已登记且同 origin 的任务，任务取消会立即退出候选集，后注册任务不能消费旧失败。普通数据/下载任务和 WebSocket 都显式登记。`DsmTransportSecurityTests` 覆盖无 task ID、并发 host 隔离、取消与挑战后新任务。 | 本地合成单元测试已通过；真实 URLSession TLS 回调时序及正式自签名/换证书行为仍为 `PENDING_USER_VALIDATION`。所有未通过信任挑战继续取消，保持 fail-closed。 |
| FP-001 | `apple/Apps/DsmMac/FileProviderExtension/ProviderEnumerator.swift`、`ProviderRuntime.swift`、`DesktopCloudDriveProvider.swift`、`DesktopDriveChangeJournal.swift` | 只读映射能持久记录远程目录快照，基于版本化 anchor 分页返回更新/删除；高（文件新鲜度） | 已确认：固定 `v1` anchor 且直接结束变化枚举。 | 已实施：App Group 快照中的有限 journal、带 mapping/container 摘要与 generation/revision 的锚点、更新/删除/分页、裁剪/损坏/缺口/旧 generation 的 `syncAnchorExpired` 恢复。扫描遵循前进检查与页面上限；映射删除同步清理日志。`DesktopCloudDriveTests`、`ProviderRuntimeTests` 覆盖配置快照重新打开、Extension 重启模拟、分页和枚举器入口。 | 不实现 NAS 写入，不把自动化枚举表述为 Finder 真机结果。 |
| FP-002 | `apple/Packages/DsmCore/Sources/DesktopCloudDriveProvider.swift`、`apple/Apps/DsmMac/FileProviderExtension/ProviderRuntime.swift` | 完整远端扫描只能在其观察到的 generation/revision 仍为当前值时提交；慢扫描不得倒退 snapshot 或产生虚假 updated/deleted；高（文件新鲜度） | 已确认：文件锁只保护写入互斥，不能证明锁外扫描仍基于最新快照。 | 已实施：扫描前读取 journal revision，提交时在同一跨进程文件锁内执行 generation/revision CAS；不匹配抛出 `staleChangeJournal`，Runtime 丢弃旧结果并重扫一次，持续竞争则安全失败且不发出旧事件。`DesktopCloudDriveTests` 使用 A 旧且慢、B 新且快的确定性门闩回归测试，验证最终日志保留 B。 | 自动化已通过；Finder 多进程/Extension 生命周期下的信号调度仍为 `PENDING_USER_VALIDATION`。 |
| FP-003 | `apple/Apps/DsmMac/FileProviderExtension/ProviderRuntime.swift` | working set 仅服务已物化、已固定或近期受跟踪项目；根目录 journal 与 working set journal 必须分离；中（File Provider 语义与性能） | 已确认：`.workingSet` 与 `.rootContainer` 共用根目录完整扫描和同一 journal。 | 已实施：working set 仅对已固定路径和缓存条目执行有界（最多 500 项）`getInfo`，不调用根目录列表或递归扫描；根与 working set 使用独立 container journal/anchor。`ProviderRuntimeTests` 验证工作集不读取根目录、只读取受跟踪路径且锚点隔离。 | `PENDING_USER_VALIDATION`：需正式签名 App、Finder 和受控 NAS 验证 working-set 枚举/信号、固定/释放和 Extension 重启后的系统调度；当前不宣称 Finder 实机通过。 |
| REL-001 | `.github/workflows/apple-build.yml`、`macos-release-verification.yml`、`tools/release/verify_macos_distribution.sh`、`verify_macos_unsigned_ci_artifact.sh` | 日常 CI 工具链可复现；发布门禁明确区分 unsigned CI 与签名/公证验收；高（发布） | 已确认：`macos-latest` 与 Homebrew `xcodegen` 均未锁定。 | 已实施：固定 `macos-15`、Xcode 16.4 路径、XcodeGen 2.46.0 与 SHA-256、不可变 Actions SHA；CI 对临时签名 App/DMG 与来源提交执行门禁。手动发布工作流需受控 `macos-release` 环境和 Secrets，执行签名、公证、装订与严格验证。两类门禁均挂载 DMG、逐项比对完整 App bundle；正式门禁还校验来源提交。 | Developer ID、公证、装订、Gatekeeper、安装升级仍为 `PENDING_USER_VALIDATION`。 |
| REL-002 | `.github/workflows/macos-release-verification.yml`、`apple/Apps/DsmMac/package.sh`、`notarize.sh` | 本轮必须取得一次可复核的 Developer ID、App/Extension entitlement、公证、装订、Gatekeeper 和正式 DMG 安装/启动 GitHub 证据；高（发布） | 工作流已经存在，但基线没有成功运行记录。 | 已在 PR #3 上以 `workflow_dispatch` 实际运行 [32565997780](https://github.com/yuangy1995/dsm-native-client/actions/runs/32565997780)：锁定 Xcode/XcodeGen 与共享包测试均成功，随后在发布凭据检查停止；不会在仓库、日志或交付中写入证书、公证密码或身份材料。 | `PENDING_USER_VALIDATION`：仓库与 `macos-release` Environment 的只读 Secret 列表均为空，日志确认缺少 `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`；该 fail-fast 工作流还要求 Developer ID 证书密码、签名身份、Apple ID、App 专用密码与 Team ID。未配置前不能取得签名、公证、装订、Gatekeeper 或安装/启动证据，也不得合并。 |

## SEC-002 五端影响与契约决策

`file-station.upload.synthetic-overwrite` 的共享合成 Fixture 仍记录旧的 `query` 认证位置。
它是 Android 尚未迁移的现状证据，不是 macOS 发布允许 URL 携带凭据的例外。本轮不修改
该 Fixture，以免把未完成的跨端迁移伪装为已完成；Apple 测试会在保留 API、业务参数和
multipart 认证断言的同时，明确断言 URL 中没有 `_sid` 或 Token。

| 平台 | 当前事实 | 本轮结论 |
| --- | --- | --- |
| macOS | 共享 Apple `DsmNetwork` 的文件读取/上传请求不再把会话或 Token 写入 URL；上传仍使用 Cookie、Header 和既有 multipart 字段。 | 已实施并由 Apple 聚焦测试覆盖；真实 DSM 兼容性待验证。 |
| iPhone / iPad | 复用同一 Apple 网络包，源码行为随共享修复收敛。 | 本轮未运行移动构建或真机；不得把 macOS 测试表述为移动端验收。 |
| Android | `DsmApi.kt` 的 File Station 上传当前仍在 URL 放入会话和 Token，且其测试明确断言该行为。 | 不在 macOS 整改范围，需单独获批的跨端契约切片处理。 |
| Windows | `DsmApiClient.UploadFileAsync` 的上传 URI 当前不含会话或 Token，认证使用 Cookie、Header 和 multipart 字段。 | 本轮只读核实，未修改 Windows 代码或声称其发布验证。 |

后续只有在 Android 迁移、五端测试与共享 Fixture 同步更新后，才可恢复“认证位置完全一致”的
全端结论。该差异不改变 DSM API 名称、方法、业务参数或公开客户端签名。

## FP-001 持久化兼容性决策

FP-001 必须有跨 Extension 重启可读取的变更日志，因而需要在现有 App Group 配置快照中
添加**可选**的 journal 字段及版本化 anchor。该变更是本轮唯一必要的持久化结构扩展：

- 迁移：旧快照缺少该字段时视为没有基线，首次变化枚举执行安全的完整重新枚举并建立新快照。
- 兼容：字段为可选；旧版本可忽略未知字段，新版本可读取旧快照，不重写映射、会话或缓存内容。
- 回滚：回退代码会忽略 journal；映射删除时同步移除其 journal。无法解码或过期 anchor 时不猜测增量，改为要求 File Provider 完整重新枚举。
- 安全：journal 仅保存已有映射的匿名 item identifier、路径元数据与版本信息，不保存密码、SID、Token、Cookie、主机地址或文件内容。


## 安全整改待用户验证

以下项目不能由当前工作树代替。用户应在受控测试环境完成，且只回传脱敏的“通过/失败、用例 ID、错误类别和影响范围”。

| 用例 | 前置条件与步骤 | 预期结果 | 影响范围 |
| --- | --- | --- | --- |
| SEC-001-V | 使用正式签名 App，在锁屏/重启后分别恢复本地会话与已记住密码。 | Keychain 可用时恢复；不可用时给出可恢复错误，不使用固定密钥。 | 本地会话与可选密码。 |
| AUTH-001-V | 创建 Finder 映射后重启主 App 与 Extension，并模拟短暂 Keychain 不可用后重试。 | 旧会话不会因保存失败丢失；后续迁移可重试。 | 主 App 与 File Provider 会话。 |
| NET-001-V | 两个不同受控 HTTPS 端点并发触发证书失败，并取消其中一个请求。 | 每个提示只显示所属端点的证书信息，取消不消费另一请求失败。 | 登录、文件与传输网络请求。 |
| SEC-002-V | 以受控旧/新 DSM 测试下载、上传和同源/跨源重定向。 | Header 认证正常；跨源重定向不提交认证字段；诊断无秘密。 | 文件读写认证兼容性。 |
| DATA-001-V | 对已有文件模拟取消、空间不足、权限错误和替换前中断。 | 失败后旧文件内容不变，临时文件可安全清理或续传。 | 本地下载目标。 |
| DATA-002-V | 在受控 NAS 上对同一路径同大小文件完成中断、替换、416 与无强 ETag/Last-Modified 的下载复验。 | 校验器连续时仅续传同一内容版本；失效时不混合旧分片，原有最终文件仅在完整新文件成功后替换。 | 本地下载目标与跨 NAS 复制。 |
| TLS-002-V | 两个受控 HTTPS origin 并发触发 session 级证书失败，并取消其中一个请求；另测 WebSocket。 | 同 origin 的仍在途请求收到自身结构化错误；取消、异 host 与后注册请求不消费它；所有失败仍被取消。 | 登录、文件、聊天和传输网络请求。 |
| FP-001-V | 使用正式签名 App 和 Finder，验证远程创建、改名、删除、修改、Extension 重启、断网重连与升级。 | Finder 收到正确更新/删除；失效 anchor 能完整恢复；不产生远程写入。 | 只读桌面云盘映射。 |
| FP-002-V | 以正式签名 App 同时触发同一映射目录的慢/快刷新，并在中间改变受控 NAS 项目。 | 慢扫描不会让 Finder 收到倒退更新、虚假删除或重新出现；最新扫描获胜或系统收到安全重枚举错误。 | File Provider journal 与 Finder 视图。 |
| FP-003-V | 在受控 Finder 映射中验证已打开、已固定、已释放和未访问项目的 working set 枚举/变化信号。 | working set 不对完整 NAS 根目录做无条件扫描，且根目录与 working-set anchor 不串扰。 | File Provider 性能与系统枚举语义。 |
| REL-001-V | 在受控 Apple 发布环境完成 Developer ID、公证、装订、Gatekeeper、升级与回退矩阵。 | 发布脚本完整通过，升级不静默破坏登录、映射或缓存状态。 | macOS 公开 Beta / 正式分发。 |
| REL-002-V | 仅在 GitHub `macos-release` Environment 配置六项发布 Secret 后，重新运行 `macOS Release Verification`，并回传 run URL 与脱敏的失败类别（如有）。 | Developer ID 签名、主 App/扩展 entitlement、公证、装订、Gatekeeper 与正式 DMG 安装/启动均成功。 | 正式 macOS 分发门禁。 |
